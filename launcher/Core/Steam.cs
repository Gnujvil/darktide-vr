using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using Microsoft.Win32;

namespace DarktideVR.Launcher.Core
{
    // Steam's launch option and SteamVR's library point at one fixed copy of
    // the launcher, so a friend can keep (or lose) the downloaded exe anywhere.
    public static class StableCopy
    {
        public static string Directory => Path.Combine(Paths.LauncherRoot, "app");
        public static string ExePath => Path.Combine(Directory, "DarktideVR-Launcher.exe");

        public static bool IsSelf => string.Equals(Path.GetFullPath(Paths.ExePath), Path.GetFullPath(ExePath), StringComparison.OrdinalIgnoreCase);

        // Copies this exe there when it is missing or older. A copy that is
        // running (Steam launched the game through it) is left for next time.
        public static void Ensure()
        {
            if (IsSelf) return;
            if (File.Exists(ExePath))
            {
                var installed = FileVersionInfo.GetVersionInfo(ExePath).ProductVersion;
                if (!ReleaseVersion.IsNewer(LauncherConfig.CurrentVersion, installed)) return;
            }
            try
            {
                Files.WriteWhole(ExePath, File.ReadAllBytes(Paths.ExePath));
                Log.Info($"Launcher {LauncherConfig.CurrentVersion} copied to {ExePath}");
            }
            catch (IOException error) { Log.Warn($"The launcher copy at {ExePath} is in use; it is refreshed next time: {error.Message}"); }
        }
    }

    public static class SteamProcesses
    {
        // Set by --steam-root (tests with a fake Steam folder): the real
        // Steam and SteamVR don't write to that folder.
        public static bool ChecksDisabled { get; set; }

        public static bool SteamRunning => !ChecksDisabled && Any("steam");
        public static bool SteamVrRunning => !ChecksDisabled && (Any("vrserver") || Any("vrmonitor") || Any("vrcompositor") || Any("vrdashboard"));

        static bool Any(string name)
        {
            var processes = Process.GetProcessesByName(name);
            foreach (var process in processes) process.Dispose();
            return processes.Length > 0;
        }
    }

    // A "Darktide VR" tile in SteamVR's library (what Steam Link and SteamVR
    // headsets show), via a .vrmanifest listed in Steam\config\appconfig.json
    // like other tools register theirs. SteamVR rewrites appconfig.json, so it
    // must be closed while the launcher edits it.
    public static class SteamVrLibrary
    {
        public const string AppKey = "darktidevr.launcher.darktide";
        public static string ManifestPath => Path.Combine(StableCopy.Directory, "darktidevr.vrmanifest");
        static string AppConfig(string steam) => Path.Combine(steam, "config", "appconfig.json");

        public static bool IsRegistered(string steam) =>
            File.Exists(ManifestPath) && ManifestPaths(ReadConfig(steam)).Any(p => SamePath(p, ManifestPath));

        // The tile runs the launcher with --vr-launch, which records "VR,
        // through SteamVR" for the Steam launch it starts: a launch from
        // SteamVR's library must use SteamVR even when Virtual Desktop (the
        // usual default runtime) is also connected. Without the Steam launch
        // option it switches to VR itself first.
        public static void Register(string steam, string gameRoot, bool launchOptionSet)
        {
            if (SteamProcesses.SteamVrRunning) throw new LauncherException("Close SteamVR first, then press Set up again, so Darktide VR can be added to the SteamVR library.");
            var art = CopyArt(steam);
            var app = new Dictionary<string, object>
            {
                ["app_key"] = AppKey,
                ["strings"] = new Dictionary<string, object>
                {
                    ["en_us"] = new Dictionary<string, object>
                    {
                        ["name"] = "Warhammer 40,000: Darktide VR",
                        ["description"] = "Darktide with the Darktide VR mod",
                    },
                },
            };
            app["launch_type"] = "binary";
            app["binary_path_windows"] = StableCopy.ExePath;
            app["arguments"] = "--vr-launch";
            if (art.Header != null) app["image_path"] = art.Header;
            if (art.Capsule != null) app["image_path_capsule"] = art.Capsule;
            var manifest = new Dictionary<string, object>
            {
                ["source"] = "darktidevr",
                ["applications"] = new object[] { app },
            };
            Files.WriteWhole(ManifestPath, new UTF8Encoding(false).GetBytes(new JavaScriptSerializer().Serialize(manifest)));

            var config = ReadConfig(steam);
            var paths = ManifestPaths(config);
            if (!paths.Any(p => SamePath(p, ManifestPath)))
            {
                paths.Add(ManifestPath);
                config["manifest_paths"] = paths.ToArray();
                WriteConfig(steam, config);
            }
            Log.Info($"SteamVR library entry registered ({(launchOptionSet ? "with" : "without")} the Steam launch option): {ManifestPath}");
        }

        public static void Unregister(string steam)
        {
            var config = ReadConfig(steam);
            var paths = ManifestPaths(config);
            if (paths.Any(p => SamePath(p, ManifestPath)))
            {
                if (SteamProcesses.SteamVrRunning) throw new LauncherException("Close SteamVR first, so Darktide VR can be removed from the SteamVR library.");
                config["manifest_paths"] = paths.Where(p => !SamePath(p, ManifestPath)).ToArray();
                WriteConfig(steam, config);
            }
            foreach (var file in new[] { ManifestPath, Path.Combine(StableCopy.Directory, "library_header.jpg"), Path.Combine(StableCopy.Directory, "library_capsule.jpg") })
                if (File.Exists(file)) File.Delete(file);
            Log.Info("SteamVR library entry removed.");
        }

        // Darktide's own library art from Steam's cache, for the player's own
        // SteamVR library.
        static (string Header, string Capsule) CopyArt(string steam)
        {
            string Copy(string name)
            {
                var cache = Path.Combine(steam, "appcache", "librarycache", LauncherConfig.SteamAppId.ToString());
                if (!System.IO.Directory.Exists(cache)) return null;
                var source = new DirectoryInfo(cache).GetFiles(name, SearchOption.AllDirectories).OrderByDescending(f => f.LastWriteTimeUtc).FirstOrDefault();
                if (source == null) return null;
                var target = Path.Combine(StableCopy.Directory, name);
                System.IO.Directory.CreateDirectory(StableCopy.Directory);
                source.CopyTo(target, true);
                return target;
            }
            return (Copy("library_header.jpg") ?? Copy("header.jpg"), Copy("library_capsule.jpg"));
        }

        static Dictionary<string, object> ReadConfig(string steam)
        {
            var path = AppConfig(steam);
            if (!File.Exists(path)) return new Dictionary<string, object>();
            return new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(File.ReadAllText(path)) ?? new Dictionary<string, object>();
        }

        static void WriteConfig(string steam, Dictionary<string, object> config)
        {
            var path = AppConfig(steam);
            if (File.Exists(path) && !File.Exists(path + ".darktidevr-backup")) File.Copy(path, path + ".darktidevr-backup");
            Files.WriteWhole(path, new UTF8Encoding(false).GetBytes(new JavaScriptSerializer().Serialize(config)));
        }

        static List<string> ManifestPaths(Dictionary<string, object> config) =>
            config.TryGetValue("manifest_paths", out var value) && value is IEnumerable list && !(value is string)
                ? list.Cast<object>().Select(o => o as string).Where(s => s != null).ToList()
                : new List<string>();

        static bool SamePath(string a, string b) => string.Equals(a.Replace('/', '\\'), b.Replace('/', '\\'), StringComparison.OrdinalIgnoreCase);
    }

    // Darktide's launch option in Steam (userdata\<id>\config\localconfig.vdf,
    // UserLocalConfigStore/Software/Valve/Steam/apps/1361210/LaunchOptions):
    //   "<launcher>" --steam-launch %command%
    // Steam then runs the launcher, which picks VR or flat and starts the game.
    // Steam rewrites the file when it exits, so it must be closed meanwhile.
    public static class SteamLaunchOptions
    {
        public static string Expected => $"\"{StableCopy.ExePath}\" --steam-launch %command%";

        public static string LocalConfig(string steam)
        {
            var userdata = Path.Combine(steam, "userdata");
            if (!Directory.Exists(userdata)) return null;
            var candidates = new List<string>();
            var active = Registry.GetValue(@"HKEY_CURRENT_USER\Software\Valve\Steam\ActiveProcess", "ActiveUser", 0);
            if (active is int id && id != 0) candidates.Add(id.ToString());
            var loginUsers = Path.Combine(steam, "config", "loginusers.vdf");
            if (File.Exists(loginUsers))
            {
                foreach (var user in Vdf.Parse(File.ReadAllText(loginUsers)).FirstOrDefault()?.Children ?? new List<Vdf.Node>())
                {
                    var mostRecent = user.Children?.FirstOrDefault(c => string.Equals(c.Key, "MostRecent", StringComparison.OrdinalIgnoreCase))?.Value;
                    if (mostRecent == "1" && ulong.TryParse(user.Key, out var id64) && id64 > 76561197960265728UL)
                        candidates.Add((id64 - 76561197960265728UL).ToString());
                }
            }
            var folders = Directory.GetDirectories(userdata).Select(Path.GetFileName).Where(n => n.All(char.IsDigit) && n != "0").ToList();
            if (folders.Count == 1) candidates.Add(folders[0]);
            foreach (var candidate in candidates)
            {
                var path = Path.Combine(userdata, candidate, "config", "localconfig.vdf");
                if (File.Exists(path)) return path;
            }
            return null;
        }

        public static string Read(string steam)
        {
            var path = LocalConfig(steam);
            if (path == null) return null;
            var app = FindApp(Vdf.Parse(File.ReadAllText(path)));
            return app?.Children?.FirstOrDefault(IsLaunchOptions)?.Value;
        }

        public static bool IsConfigured(string steam) => Read(steam)?.Contains("--steam-launch") == true;

        public static void Set(string steam, LauncherState state)
        {
            var path = LocalConfig(steam) ?? throw new LauncherException("Steam's settings for your account weren't found. " + ManualHint);
            if (SteamProcesses.SteamRunning) throw new LauncherException("Close Steam first (Steam menu > Exit), then press Set up again. " + ManualHint);
            var text = File.ReadAllText(path);
            var nodes = Vdf.Parse(text);
            var app = FindApp(nodes);
            var current = app?.Children?.FirstOrDefault(IsLaunchOptions);
            string value;
            if (current != null && current.Value.Contains("--steam-launch"))
            {
                value = Expected + TrailingFlags(current.Value);
            }
            else
            {
                if (current != null && current.Value.Contains("%command%"))
                    throw new LauncherException($"Darktide already has a launch option that wraps the game ({current.Value}). Remove it in Steam, then press Set up again.");
                state.PreviousLaunchOptions = current?.Value;
                value = Expected + (string.IsNullOrWhiteSpace(current?.Value) ? "" : " " + current.Value.Trim());
            }

            string updated;
            if (current != null)
                updated = text.Substring(0, current.ValueStart) + Vdf.Quote(value) + text.Substring(current.ValueEnd);
            else if (app != null)
                updated = text.Insert(app.OpenBrace + 1, "\n" + Indent(app.Depth + 1) + "\"LaunchOptions\"\t\t" + Vdf.Quote(value));
            else
            {
                var apps = FindApps(nodes) ?? throw new LauncherException("Steam's settings file has an unexpected layout. " + ManualHint);
                var indent = Indent(apps.Depth + 1);
                updated = text.Insert(apps.OpenBrace + 1, $"\n{indent}\"{LauncherConfig.SteamAppId}\"\n{indent}{{\n{indent}\t\"LaunchOptions\"\t\t{Vdf.Quote(value)}\n{indent}}}");
            }
            Backup(path);
            Files.WriteWhole(path, new UTF8Encoding(false).GetBytes(updated));
            Log.Info($"Steam launch option set: {value}");
        }

        // Puts back what the player had before (or nothing).
        public static void Remove(string steam, LauncherState state)
        {
            var path = LocalConfig(steam);
            if (path == null) return;
            var text = File.ReadAllText(path);
            var current = FindApp(Vdf.Parse(text))?.Children?.FirstOrDefault(IsLaunchOptions);
            if (current == null || !current.Value.Contains("--steam-launch")) return;
            if (SteamProcesses.SteamRunning) throw new LauncherException("Close Steam first (Steam menu > Exit), so the launcher can remove Darktide's launch option.");
            var previous = state.PreviousLaunchOptions ?? "";
            string updated;
            if (previous.Length > 0)
                updated = text.Substring(0, current.ValueStart) + Vdf.Quote(previous) + text.Substring(current.ValueEnd);
            else
            {
                var lineStart = text.LastIndexOf('\n', current.KeyStart);
                updated = text.Remove(lineStart, current.ValueEnd - lineStart);
            }
            Backup(path);
            Files.WriteWhole(path, new UTF8Encoding(false).GetBytes(updated));
            state.PreviousLaunchOptions = null;
            Log.Info(previous.Length > 0 ? $"Steam launch option restored to: {previous}" : "Steam launch option removed.");
        }

        public static string ManualHint =>
            $"Or do it by hand: in Steam, right-click Darktide > Properties > Launch options, and paste: {Expected}";

        static string TrailingFlags(string value)
        {
            var index = value.IndexOf("%command%", StringComparison.Ordinal);
            return index < 0 ? "" : value.Substring(index + "%command%".Length);
        }

        static void Backup(string path)
        {
            if (!File.Exists(path + ".darktidevr-backup")) File.Copy(path, path + ".darktidevr-backup");
        }

        static string Indent(int depth) => new string('\t', depth);

        static bool IsLaunchOptions(Vdf.Node node) => node.Value != null && string.Equals(node.Key, "LaunchOptions", StringComparison.OrdinalIgnoreCase);

        static Vdf.Node FindApps(List<Vdf.Node> nodes)
        {
            var node = Child(nodes, "UserLocalConfigStore");
            foreach (var key in new[] { "Software", "Valve", "Steam", "apps" })
                node = node == null ? null : Child(node.Children, key);
            return node;
        }

        static Vdf.Node FindApp(List<Vdf.Node> nodes) => Child(FindApps(nodes)?.Children, LauncherConfig.SteamAppId.ToString());

        static Vdf.Node Child(List<Vdf.Node> nodes, string key) =>
            nodes?.FirstOrDefault(n => n.Children != null && string.Equals(n.Key, key, StringComparison.OrdinalIgnoreCase));
    }

    // Valve's text KeyValues, parsed with positions so one value can be
    // changed without rewriting the rest of the file.
    public static class Vdf
    {
        public sealed class Node
        {
            public string Key { get; set; }
            public int KeyStart { get; set; }
            public string Value { get; set; }          // null for a block
            public int ValueStart { get; set; }        // the value token, quotes included
            public int ValueEnd { get; set; }
            public List<Node> Children { get; set; }   // null for a value
            public int OpenBrace { get; set; }
            public int Depth { get; set; }
        }

        public static List<Node> Parse(string text)
        {
            var index = 0;
            return ParseBlock(text, ref index, 0, false);
        }

        public static string Quote(string value) => "\"" + value.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"";

        static List<Node> ParseBlock(string text, ref int index, int depth, bool nested)
        {
            var nodes = new List<Node>();
            while (true)
            {
                SkipSpace(text, ref index);
                if (index >= text.Length)
                {
                    if (nested) throw new FormatException("Unclosed block in VDF.");
                    return nodes;
                }
                if (text[index] == '}')
                {
                    if (!nested) throw new FormatException($"Unexpected }} at {index} in VDF.");
                    index++;
                    return nodes;
                }
                var keyStart = index;
                var key = ReadToken(text, ref index);
                SkipSpace(text, ref index);
                if (index < text.Length && text[index] == '{')
                {
                    var node = new Node { Key = key, KeyStart = keyStart, OpenBrace = index, Depth = depth };
                    index++;
                    node.Children = ParseBlock(text, ref index, depth + 1, true);
                    nodes.Add(node);
                }
                else
                {
                    var valueStart = index;
                    var value = ReadToken(text, ref index);
                    nodes.Add(new Node { Key = key, KeyStart = keyStart, Value = value, ValueStart = valueStart, ValueEnd = index, Depth = depth });
                    // An optional [$CONDITION] after a value.
                    SkipInlineSpace(text, ref index);
                    if (index < text.Length && text[index] == '[')
                        while (index < text.Length && text[index] != ']') index++;
                    if (index < text.Length && text[index] == ']') index++;
                }
            }
        }

        static string ReadToken(string text, ref int index)
        {
            if (index >= text.Length) throw new FormatException("Unexpected end of VDF.");
            var builder = new StringBuilder();
            if (text[index] == '"')
            {
                index++;
                while (index < text.Length && text[index] != '"')
                {
                    if (text[index] == '\\' && index + 1 < text.Length)
                    {
                        var next = text[index + 1];
                        builder.Append(next == 'n' ? '\n' : next == 't' ? '\t' : next);
                        index += 2;
                        continue;
                    }
                    builder.Append(text[index++]);
                }
                if (index >= text.Length) throw new FormatException("Unclosed string in VDF.");
                index++;
                return builder.ToString();
            }
            while (index < text.Length && !char.IsWhiteSpace(text[index]) && text[index] != '{' && text[index] != '}' && text[index] != '"')
                builder.Append(text[index++]);
            if (builder.Length == 0) throw new FormatException($"Unexpected character at {index} in VDF.");
            return builder.ToString();
        }

        static void SkipSpace(string text, ref int index)
        {
            while (index < text.Length)
            {
                if (char.IsWhiteSpace(text[index])) index++;
                else if (text[index] == '/' && index + 1 < text.Length && text[index + 1] == '/')
                    while (index < text.Length && text[index] != '\n') index++;
                else return;
            }
        }

        static void SkipInlineSpace(string text, ref int index)
        {
            while (index < text.Length && (text[index] == ' ' || text[index] == '\t')) index++;
        }
    }

    // What Steam runs when the launch option is set. It never stops the game
    // from starting: if getting ready fails, Darktide starts as it is.
    public static class SteamLaunch
    {
        public static async Task<int> RunAsync(string[] command, LauncherConfig config)
        {
            if (command.Length == 0)
            {
                Log.Error("Steam launch without a game command; the launch option needs %command%.");
                return 2;
            }
            Log.Info($"Steam launch: {string.Join(" ", command)}");
            var engine = new Engine(config);
            var root = engine.GameRoot ?? GameLocator.Normalize(Path.GetDirectoryName(Path.GetFullPath(command[0])));
            string runtime = null;
            try
            {
                if (root != null && ModPackage.Installed(root))
                {
                    var decision = await LaunchDecider.DecideAsync(root, engine.State);
                    Log.Info($"Steam launch: {(decision.Vr ? "VR" : "flat")}, because {decision.Reason}" +
                             (decision.RuntimeManifest != null ? $"; runtime {decision.RuntimeManifest}" : ""));
                    runtime = await ApplyAsync(root, decision, engine);
                }
                else Log.Info("Steam launch: Darktide VR isn't installed; starting the game unchanged.");
            }
            catch (Exception error)
            {
                Log.Error("Steam launch: getting ready failed; starting the game anyway. " + error);
            }
            return await StartAndWaitAsync(command, runtime, root);
        }

        static async Task<string> ApplyAsync(string root, LaunchDecision decision, Engine engine)
        {
            if (Dependencies.ModLoaderPresent(root) && Dependencies.PatchToolPresent(root)) await Dependencies.EnableModsAsync(root);
            if (decision.Vr)
            {
                var vr = await ModeScript.RunAsync(root, "vr");
                if (vr.Ok)
                {
                    engine.TuneVr(root);
                    engine.RecordLaunch($"VR ({decision.Reason})");
                    return decision.RuntimeManifest;
                }
                Log.Warn("Steam launch: VR mode couldn't be switched on (" + vr.Message + "); starting flat.");
                engine.RecordLaunch($"flat: VR couldn't be switched on ({vr.Message})");
            }
            else engine.RecordLaunch($"flat ({decision.Reason})");
            var flat = await ModeScript.RunAsync(root, "flat");
            if (!flat.Ok) Log.Warn("Steam launch: flat mode couldn't be switched on: " + flat.Message);
            return null;
        }

        static async Task<int> StartAndWaitAsync(string[] command, string runtime, string root)
        {
            var start = new ProcessStartInfo(command[0], string.Join(" ", command.Skip(1).Select(QuoteArgument)))
            {
                UseShellExecute = false,
                WorkingDirectory = Path.GetDirectoryName(Path.GetFullPath(command[0])),
            };
            if (runtime != null) start.EnvironmentVariables["XR_RUNTIME_JSON"] = runtime;
            using (var process = Process.Start(start))
            {
                await Task.Run(() => process.WaitForExit());
                // Darktide outlives its launcher window; staying until it
                // exits keeps it shown as running in Steam.
                while (root != null && GameLocator.IsDarktideRunning(root)) await Task.Delay(5000);
                return process.ExitCode;
            }
        }

        // Windows command-line quoting (CommandLineToArgvW rules).
        public static string QuoteArgument(string argument)
        {
            if (argument.Length > 0 && argument.IndexOfAny(new[] { ' ', '\t', '"' }) < 0) return argument;
            var builder = new StringBuilder("\"");
            var backslashes = 0;
            foreach (var c in argument)
            {
                if (c == '\\') { backslashes++; continue; }
                if (c == '"') { builder.Append('\\', backslashes * 2 + 1); builder.Append('"'); }
                else { builder.Append('\\', backslashes); builder.Append(c); }
                backslashes = 0;
            }
            builder.Append('\\', backslashes * 2);
            builder.Append('"');
            return builder.ToString();
        }

        // The SteamVR library tile when the launch option isn't set: switch
        // to VR here (with the runtime the player is in), then start Darktide
        // through Steam.
        public static async Task<int> VrLaunchAsync(LauncherConfig config)
        {
            var engine = new Engine(config);
            var root = engine.GameRoot ?? engine.FindGame();
            string runtime = null;
            if (XrRuntimes.SteamVrRunning() && !XrRuntimes.IsFile(XrRuntimes.Active(), XrRuntimes.SteamVrFile))
                runtime = XrRuntimes.Find(XrRuntimes.SteamVrFile);
            NextLaunch.Write("vr", runtime);
            try
            {
                if (root != null && ModPackage.Installed(root) && !SteamLaunchOptions.IsConfigured(GameLocator.SteamRoot() ?? ""))
                {
                    if (Dependencies.ModLoaderPresent(root) && Dependencies.PatchToolPresent(root)) await Dependencies.EnableModsAsync(root);
                    var vr = await ModeScript.RunAsync(root, "vr");
                    if (vr.Ok) engine.TuneVr(root);
                    else Log.Warn("SteamVR library launch: VR mode couldn't be switched on: " + vr.Message);
                    if (runtime != null)
                        Log.Warn("SteamVR library launch: without the Steam launch option the game uses the default OpenXR runtime, not SteamVR. Set up Steam in the launcher to fix this.");
                }
            }
            catch (Exception error) { Log.Error("SteamVR library launch: " + error); }
            Engine.LaunchSteam();
            return 0;
        }
    }
}
