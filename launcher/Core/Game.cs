using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32;

namespace DarktideVR.Launcher.Core
{
    public static class GameLocator
    {
        public static bool IsGameRoot(string path) =>
            !string.IsNullOrEmpty(path) &&
            File.Exists(Path.Combine(path, "binaries", "Darktide.exe")) &&
            Directory.Exists(Path.Combine(path, "bundle"));

        // A folder the player picked may be the game folder or one inside it.
        public static string Normalize(string picked)
        {
            for (var directory = picked; !string.IsNullOrEmpty(directory); directory = Path.GetDirectoryName(directory))
                if (IsGameRoot(directory)) return Path.GetFullPath(directory).TrimEnd('\\');
            return null;
        }

        // Steam installs, in library order: registry -> libraryfolders.vdf ->
        // appmanifest_1361210.acf installdir.
        public static List<string> FindSteamInstalls()
        {
            var found = new List<string>();
            foreach (var library in SteamLibraries())
            {
                var manifest = Path.Combine(library, "steamapps", $"appmanifest_{LauncherConfig.SteamAppId}.acf");
                if (!File.Exists(manifest)) continue;
                var match = Regex.Match(SafeRead(manifest), "\"installdir\"\\s+\"([^\"]+)\"", RegexOptions.IgnoreCase);
                if (!match.Success) continue;
                var root = Path.Combine(library, "steamapps", "common", match.Groups[1].Value);
                if (IsGameRoot(root) && !found.Contains(root, StringComparer.OrdinalIgnoreCase)) found.Add(root);
            }
            return found;
        }

        // --steam-root: a fake Steam folder for tests.
        public static string SteamRootOverride { get; set; }

        public static string SteamRoot()
        {
            if (SteamRootOverride != null) return SteamRootOverride;
            var candidates = new[]
            {
                Registry.GetValue(@"HKEY_CURRENT_USER\Software\Valve\Steam", "SteamPath", null) as string,
                ReadMachine(@"SOFTWARE\WOW6432Node\Valve\Steam", "InstallPath"),
                ReadMachine(@"SOFTWARE\Valve\Steam", "InstallPath"),
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), "Steam"),
            };
            foreach (var candidate in candidates)
                if (!string.IsNullOrEmpty(candidate) && Directory.Exists(candidate))
                    return Path.GetFullPath(candidate.Replace('/', '\\'));
            return null;
        }

        static IEnumerable<string> SteamLibraries()
        {
            var steam = SteamRoot();
            if (steam == null) yield break;
            yield return steam;
            var vdf = Path.Combine(steam, "steamapps", "libraryfolders.vdf");
            if (!File.Exists(vdf)) yield break;
            foreach (Match match in Regex.Matches(SafeRead(vdf), "\"path\"\\s+\"([^\"]+)\"", RegexOptions.IgnoreCase))
            {
                var path = match.Groups[1].Value.Replace(@"\\", @"\");
                if (Directory.Exists(path) && !string.Equals(Path.GetFullPath(path).TrimEnd('\\'), steam.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase))
                    yield return path;
            }
        }

        public static string ReadMachine(string key, string value)
        {
            using (var hive = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64))
            using (var sub = hive.OpenSubKey(key))
                return sub?.GetValue(value) as string;
        }

        static string SafeRead(string path)
        {
            try { return File.ReadAllText(path); } catch { return ""; }
        }

        public static bool IsDarktideRunning() => Process.GetProcessesByName("Darktide").Length > 0;

        // Darktide started from this install. A process whose path can't be
        // read counts as running: refusing is the safe answer.
        public static bool IsDarktideRunning(string root)
        {
            if (string.IsNullOrEmpty(root)) return IsDarktideRunning();
            var prefix = Path.GetFullPath(root).TrimEnd('\\') + "\\";
            foreach (var process in Process.GetProcessesByName("Darktide"))
            {
                try
                {
                    var path = process.MainModule?.FileName;
                    if (path == null || path.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) return true;
                }
                catch { return true; }
                finally { process.Dispose(); }
            }
            return false;
        }
    }

    // The Darktide Mod Loader and Mod Framework, downloaded from their own
    // repositories at the commits a release pins (the loader has no licence
    // file, so it is fetched, never redistributed).
    public sealed class Dependencies
    {
        public const string BundlePatchTag = "patch_999";
        readonly LauncherConfig config;
        readonly Net net;

        public Dependencies(LauncherConfig config, Net net)
        {
            this.config = config;
            this.net = net;
        }

        public static bool ModLoaderPresent(string root) =>
            File.Exists(Path.Combine(root, "binaries", "mod_loader")) &&
            File.Exists(Path.Combine(root, "bundle", "9ba626afa44a3aa3.patch_999")) &&
            File.Exists(Path.Combine(root, "mods", "base", "mod_manager.lua")) &&
            File.Exists(Path.Combine(root, "mods", "mod_load_order.txt"));

        public static bool PatchToolPresent(string root) => File.Exists(PatchTool(root));

        public static bool FrameworkPresent(string root) => File.Exists(Path.Combine(root, "mods", "dmf", "dmf.mod"));

        static string PatchTool(string root) => Path.Combine(root, "tools", "dtkit-patch.exe");

        // Mods load only while the game's bundle database carries the loader's
        // patch; every game update or file verification removes it.
        public static bool ModsEnabled(string root)
        {
            var database = Path.Combine(root, "bundle", "bundle_database.data");
            if (!File.Exists(database)) return false;
            var bytes = File.ReadAllBytes(database);
            var tag = Encoding.ASCII.GetBytes(BundlePatchTag);
            return IndexOf(bytes, tag) >= 0;
        }

        public static async Task EnableModsAsync(string root)
        {
            if (ModsEnabled(root)) return;
            if (!PatchToolPresent(root)) throw new LauncherException("The mod loader's patch tool (tools\\dtkit-patch.exe) is missing. Reinstall the mod loader from the Setup list.");
            var result = await Processes.RunAsync(PatchTool(root), $"--patch \"{Path.Combine(root, "bundle")}\"", root);
            Log.Info($"dtkit-patch --patch: exit {result.ExitCode} {result.Output.Trim()} {result.Error.Trim()}");
            if (!ModsEnabled(root))
                throw new LauncherException("Switching mods on failed (dtkit-patch). " + FirstLine(result.Error, result.Output));
        }

        public static async Task DisableModsAsync(string root)
        {
            if (!ModsEnabled(root) || !PatchToolPresent(root)) return;
            var result = await Processes.RunAsync(PatchTool(root), $"--unpatch \"{Path.Combine(root, "bundle")}\"", root);
            Log.Info($"dtkit-patch --unpatch: exit {result.ExitCode} {result.Error.Trim()}");
            if (ModsEnabled(root))
                throw new LauncherException("Switching mods off failed (dtkit-patch). " + FirstLine(result.Error, result.Output) +
                    " Steam's \"Verify integrity of game files\" also switches them off.");
        }

        // Installs each pinned file that is missing, and updates files this
        // launcher installed earlier that nobody has changed since. Files that
        // came from Nexus, Vortex or the player are never overwritten.
        public async Task<int> InstallAsync(string root, Dependency dependency, LauncherState state, IProgress<double> progress, CancellationToken cancel)
        {
            var work = new List<(DependencyFile File, string Path)>();
            foreach (var file in dependency.Files)
            {
                var path = Files.ResolveInside(root, file.Target);
                if (!File.Exists(path)) { work.Add((file, path)); continue; }
                if (file.Preserve) continue;
                var current = Hash.Sha256File(path);
                if (Hash.Same(current, file.Sha256)) continue;
                var owned = state.OwnedFiles.FirstOrDefault(o => string.Equals(o.Path, file.Target, StringComparison.OrdinalIgnoreCase));
                if (owned != null && Hash.Same(owned.Sha256, current)) work.Add((file, path));
            }
            if (work.Count == 0) return 0;

            Log.Info($"{dependency.Name}: installing {work.Count} file(s) from {dependency.Repo}@{dependency.Commit}");
            var url = $"{config.CodeloadBase.TrimEnd('/')}/{dependency.Repo}/zip/{dependency.Commit}";
            // Archives generated on the fly have no stable checksum of their
            // own; each file inside is checked instead.
            var archive = await net.DownloadAsync(url, 64L * 1024 * 1024, null, progress, cancel);
            var entries = new Dictionary<string, byte[]>(StringComparer.Ordinal);
            using (var zip = new ZipArchive(new MemoryStream(archive), ZipArchiveMode.Read))
            {
                foreach (var entry in zip.Entries)
                {
                    var name = entry.FullName.Replace('\\', '/');
                    var slash = name.IndexOf('/');
                    if (slash < 0 || name.EndsWith("/")) continue;
                    var inner = name.Substring(slash + 1);
                    if (!work.Any(w => w.File.Source == inner)) continue;
                    using (var stream = entry.Open())
                    using (var buffer = new MemoryStream())
                    {
                        stream.CopyTo(buffer);
                        entries[inner] = buffer.ToArray();
                    }
                }
            }
            foreach (var (file, _) in work)
            {
                if (!entries.TryGetValue(file.Source, out var bytes))
                    throw new LauncherException($"The {dependency.Name} download is missing {file.Source}.");
                if (!Hash.Same(Hash.Sha256(bytes), file.Sha256))
                    throw new LauncherException($"The {dependency.Name} download doesn't match the pinned version ({file.Source}); nothing was installed.");
            }
            foreach (var (file, path) in work)
            {
                Files.WriteWhole(path, entries[file.Source]);
                if (file.Preserve) continue;
                state.OwnedFiles.RemoveAll(o => string.Equals(o.Path, file.Target, StringComparison.OrdinalIgnoreCase));
                state.OwnedFiles.Add(new OwnedFile { Path = file.Target, Sha256 = file.Sha256.ToLowerInvariant() });
            }
            return work.Count;
        }

        // Removes the launcher's own files that are still as it wrote them.
        public static int RemoveOwned(string root, LauncherState state)
        {
            var removed = 0;
            foreach (var owned in state.OwnedFiles.ToList())
            {
                var path = Files.ResolveInside(root, owned.Path);
                if (File.Exists(path) && Hash.Same(Hash.Sha256File(path), owned.Sha256))
                {
                    File.Delete(path);
                    Files.RemoveEmptyParents(path, root);
                    removed++;
                }
                state.OwnedFiles.Remove(owned);
            }
            return removed;
        }

        static string FirstLine(params string[] texts) =>
            texts.SelectMany(t => (t ?? "").Split('\n')).Select(l => l.Trim()).FirstOrDefault(l => l.Length > 0) ?? "";

        static int IndexOf(byte[] haystack, byte[] needle)
        {
            for (var i = 0; i <= haystack.Length - needle.Length; i++)
            {
                var match = true;
                for (var j = 0; j < needle.Length; j++)
                    if (haystack[i + j] != needle[j]) { match = false; break; }
                if (match) return i;
            }
            return -1;
        }
    }

    public static class Vortex
    {
        // Vortex deploys mods as hard links and records them here; a mod folder
        // it manages is left to Vortex, or its next deploy would fight ours.
        public static bool ManagesMod(string root, string modName)
        {
            var path = Path.Combine(root, "vortex.deployment.json");
            if (!File.Exists(path)) return false;
            try
            {
                var deployment = Json.Parse<VortexDeployment>(File.ReadAllText(path));
                var prefix = $"mods\\{modName}\\";
                return deployment?.Files?.Any(f => f.RelPath != null &&
                    f.RelPath.Replace('/', '\\').StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) == true;
            }
            catch (Exception error)
            {
                Log.Warn($"vortex.deployment.json unreadable: {error.Message}");
                return false;
            }
        }
    }

    public sealed class XrStatus
    {
        public string Runtime { get; set; }        // VDXR, SteamVR, Other, None
        public string DisplayName { get; set; }
        public string ManifestPath { get; set; }
        public bool ManifestExists { get; set; }
        public string ServiceName { get; set; }
        public bool ServiceRunning { get; set; }
        public bool Tested => Runtime == "VDXR";
    }

    public static class XrRuntime
    {
        // The OpenXR loader's choice: XR_RUNTIME_JSON, else HKLM ActiveRuntime.
        // The classification is the developer preflight's (xr-readiness.ps1).
        public static XrStatus Detect()
        {
            var manifest = Environment.GetEnvironmentVariable("XR_RUNTIME_JSON");
            if (string.IsNullOrEmpty(manifest))
                manifest = GameLocator.ReadMachine(@"SOFTWARE\Khronos\OpenXR\1", "ActiveRuntime");
            var status = new XrStatus { ManifestPath = manifest };
            if (string.IsNullOrEmpty(manifest))
            {
                status.Runtime = "None";
                status.DisplayName = "No OpenXR runtime is set";
                return status;
            }
            status.ManifestExists = File.Exists(manifest);
            var file = Path.GetFileName(manifest).ToLowerInvariant();
            switch (file)
            {
                case "virtualdesktop-openxr.json":
                    status.Runtime = "VDXR";
                    status.DisplayName = "Virtual Desktop (VDXR)";
                    status.ServiceName = "VirtualDesktop.Streamer";
                    break;
                case "steamxr_win64.json":
                    status.Runtime = "SteamVR";
                    status.DisplayName = "SteamVR";
                    status.ServiceName = "vrserver";
                    break;
                case "oculus_openxr_64.json":
                    status.Runtime = "Other";
                    status.DisplayName = "Meta Quest Link (untested)";
                    break;
                default:
                    status.Runtime = "Other";
                    status.DisplayName = $"{Path.GetFileNameWithoutExtension(manifest)} (untested)";
                    break;
            }
            if (status.ServiceName != null)
                status.ServiceRunning = Process.GetProcessesByName(status.ServiceName).Length > 0;
            return status;
        }
    }

    public sealed class ProcessResult
    {
        public int ExitCode { get; set; }
        public string Output { get; set; } = "";
        public string Error { get; set; } = "";
    }

    public static class Processes
    {
        public static Task<ProcessResult> RunAsync(string file, string arguments, string workingDirectory)
        {
            return Task.Run(() =>
            {
                var start = new ProcessStartInfo(file, arguments)
                {
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    WorkingDirectory = workingDirectory,
                    StandardOutputEncoding = Encoding.UTF8,
                    StandardErrorEncoding = Encoding.UTF8,
                };
                using (var process = Process.Start(start))
                {
                    var output = process.StandardOutput.ReadToEndAsync();
                    var error = process.StandardError.ReadToEndAsync();
                    process.WaitForExit();
                    return new ProcessResult { ExitCode = process.ExitCode, Output = output.Result, Error = error.Result };
                }
            });
        }
    }
}
