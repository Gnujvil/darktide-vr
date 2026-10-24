using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Threading.Tasks;

namespace DarktideVR.Launcher.Core
{
    public static class ModPackage
    {
        public const string ModName = "darktidevr";
        const string ArchivePrefix = "mods/darktidevr/";

        public static string ModDirectory(string root) => Path.Combine(root, "mods", ModName);
        static string Staging(string root) => Path.Combine(root, "mods", ".darktidevr-update");
        static string Previous(string root) => Path.Combine(root, "mods", ".darktidevr-previous");

        public static PackageManifest ReadInstalled(string root)
        {
            var path = Path.Combine(ModDirectory(root), "package-manifest.json");
            if (!File.Exists(path)) return null;
            try { return Json.Parse<PackageManifest>(File.ReadAllText(path)); }
            catch (Exception error)
            {
                Log.Warn($"Installed package-manifest.json unreadable: {error.Message}");
                return null;
            }
        }

        public static bool Installed(string root) => File.Exists(Path.Combine(ModDirectory(root), "darktidevr-mode.ps1"));

        // Unpacks a release zip next to the mod folder (same volume, so the
        // swap is a rename), checks every file against the package's own
        // manifest, then swaps it in. A failure leaves the installed version.
        public static void Install(string root, byte[] zipBytes)
        {
            var staging = Staging(root);
            Files.DeleteDirectory(staging);
            Directory.CreateDirectory(staging);
            try
            {
                Extract(zipBytes, staging);
                Verify(staging);
                Swap(root, staging);
            }
            finally
            {
                try { Files.DeleteDirectory(staging); }
                catch (Exception error) { Log.Warn($"Couldn't remove {staging}: {error.Message}"); }
            }
        }

        static void Extract(byte[] zipBytes, string staging)
        {
            using (var zip = new ZipArchive(new MemoryStream(zipBytes), ZipArchiveMode.Read))
            {
                foreach (var entry in zip.Entries)
                {
                    // Release zips are written with backslash separators.
                    var name = entry.FullName.Replace('\\', '/');
                    if (name.EndsWith("/")) continue;
                    if (!name.StartsWith(ArchivePrefix, StringComparison.OrdinalIgnoreCase))
                        throw new LauncherException($"The mod package contains a file outside mods\\{ModName} ({entry.FullName}); it was not installed.");
                    var target = Files.ResolveInside(staging, name.Substring(ArchivePrefix.Length));
                    Directory.CreateDirectory(Path.GetDirectoryName(target));
                    entry.ExtractToFile(target, true);
                }
            }
        }

        static void Verify(string staging)
        {
            var manifestPath = Path.Combine(staging, "package-manifest.json");
            if (!File.Exists(manifestPath)) throw new LauncherException("The mod package has no package-manifest.json; it was not installed.");
            var manifest = Json.Parse<PackageManifest>(File.ReadAllText(manifestPath));
            if (manifest?.Files == null || manifest.Files.Count == 0) throw new LauncherException("The mod package's manifest lists no files; it was not installed.");
            var listed = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "package-manifest.json" };
            foreach (var file in manifest.Files)
            {
                var relative = file.Path.Replace('\\', '/');
                if (!relative.StartsWith(ArchivePrefix, StringComparison.OrdinalIgnoreCase))
                    throw new LauncherException($"The mod package's manifest names a file outside the mod ({file.Path}).");
                relative = relative.Substring(ArchivePrefix.Length);
                listed.Add(relative.Replace('/', '\\'));
                var path = Files.ResolveInside(staging, relative);
                if (!File.Exists(path) || new FileInfo(path).Length != file.Bytes || !Hash.Same(Hash.Sha256File(path), file.Sha256))
                    throw new LauncherException($"A file in the mod package doesn't match its manifest ({relative}); it was not installed.");
            }
            var root = staging.TrimEnd('\\') + "\\";
            foreach (var path in Directory.EnumerateFiles(staging, "*", SearchOption.AllDirectories))
            {
                var relative = path.Substring(root.Length);
                if (!listed.Contains(relative))
                    throw new LauncherException($"The mod package contains a file its manifest doesn't list ({relative}); it was not installed.");
            }
        }

        static void Swap(string root, string staging)
        {
            var mod = ModDirectory(root);
            var previous = Previous(root);
            Files.DeleteDirectory(previous);
            var hadPrevious = Directory.Exists(mod);
            if (hadPrevious) Files.MoveDirectory(mod, previous);
            try
            {
                Files.MoveDirectory(staging, mod);
            }
            catch
            {
                if (hadPrevious && !Directory.Exists(mod)) Files.MoveDirectory(previous, mod);
                throw;
            }
            try { Files.DeleteDirectory(previous); }
            catch (Exception error) { Log.Warn($"The previous mod version stays at {previous}: {error.Message}"); }
        }

        public static void Remove(string root)
        {
            Files.DeleteDirectory(ModDirectory(root));
            Files.DeleteDirectory(Previous(root));
            Files.DeleteDirectory(Staging(root));
        }

        // The files flat mode needs (the script, the patch tool that restores
        // the executable, and the proxy it recognises as ours), unpacked from
        // the cached release zip into a scratch mod folder.
        public static string ExtractRecoveryScript(byte[] zipBytes)
        {
            var scratch = Path.Combine(Path.GetTempPath(), "darktidevr-recovery-" + Guid.NewGuid().ToString("N").Substring(0, 8));
            var modRoot = Path.Combine(scratch, "mods", ModName);
            var needed = new[] { "darktidevr-mode.ps1", "tools/set-skinner-assert-patch.ps1", "bin/d3d12.dll" };
            using (var zip = new ZipArchive(new MemoryStream(zipBytes), ZipArchiveMode.Read))
            {
                foreach (var entry in zip.Entries)
                {
                    var name = entry.FullName.Replace('\\', '/');
                    if (!name.StartsWith(ArchivePrefix, StringComparison.OrdinalIgnoreCase)) continue;
                    var relative = name.Substring(ArchivePrefix.Length);
                    if (!needed.Contains(relative, StringComparer.OrdinalIgnoreCase)) continue;
                    var target = Files.ResolveInside(modRoot, relative);
                    Directory.CreateDirectory(Path.GetDirectoryName(target));
                    entry.ExtractToFile(target, true);
                }
            }
            var script = Path.Combine(modRoot, "darktidevr-mode.ps1");
            if (!File.Exists(script)) throw new LauncherException("The cached mod package has no darktidevr-mode.ps1.");
            return script;
        }
    }

    public sealed class ModeResult
    {
        public bool Ok { get; set; }
        public string Output { get; set; }
        public string Message { get; set; }
        public Dictionary<string, string> Status { get; } = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

        public string Get(string key) => Status.TryGetValue(key, out var value) ? value : null;
    }

    // Runs the shipped mods\darktidevr\darktidevr-mode.ps1 (the same script the
    // mod's batch menu runs). Each release carries its own copy, with the game
    // builds it can patch, so the launcher never needs those details.
    public static class ModeScript
    {
        public static string Path(string root) => System.IO.Path.Combine(ModPackage.ModDirectory(root), "darktidevr-mode.ps1");

        public static Task<ModeResult> RunAsync(string root, string mode) => RunScriptAsync(Path(root), root, mode);

        public static async Task<ModeResult> RunScriptAsync(string script, string root, string mode)
        {
            var powershell = System.IO.Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe");
            // A trailing backslash would escape the closing quote.
            var arguments = $"-NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"{script}\" -Mode {mode} -GameRoot \"{root.TrimEnd('\\')}\"";
            var run = await Processes.RunAsync(powershell, arguments, root);
            var result = new ModeResult { Ok = run.ExitCode == 0, Output = (run.Output + run.Error).Trim() };
            foreach (var line in run.Output.Split('\n').Select(l => l.Trim()))
            {
                var equals = line.IndexOf('=');
                if (equals > 0 && line.Substring(0, equals).All(c => char.IsLetterOrDigit(c) || c == '_'))
                    result.Status[line.Substring(0, equals)] = line.Substring(equals + 1);
            }
            // A thrown error's first stderr line is the script's own sentence.
            result.Message = run.Error.Split('\n').Select(l => l.Trim()).FirstOrDefault(l => l.Length > 0)
                ?? run.Output.Split('\n').Select(l => l.Trim()).LastOrDefault(l => l.Length > 0 && !l.Contains("="));
            Log.Info($"mode {mode}: exit {run.ExitCode}\n{result.Output}");
            return result;
        }
    }
}
