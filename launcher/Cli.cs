using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using DarktideVR.Launcher.Core;

namespace DarktideVR.Launcher
{
    // The same operations as the window, without it, printing key=value lines:
    //   DarktideVR-Launcher.exe --cli <command> [--game-root <folder>] [options]
    // Commands: version, status, check, install-deps, install-mod, vr, flat,
    // uninstall, self-update, auto-update, support-zip, selftest. Exit code 0 is success,
    // 1 a refusal or failure (message on stderr), 2 a usage error.
    public static class Cli
    {
        [DllImport("kernel32.dll")] static extern bool AttachConsole(int processId);
        [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int handle);

        static bool consoleReady;

        // A GUI-subsystem exe has no console: attach to the caller's when its
        // output isn't already redirected.
        static void EnsureConsole()
        {
            if (consoleReady) return;
            consoleReady = true;
            var handle = GetStdHandle(-11);
            if (handle == IntPtr.Zero || handle == new IntPtr(-1)) AttachConsole(-1);
        }

        static void Out(string line)
        {
            EnsureConsole();
            Console.Out.WriteLine(line);
            Console.Out.Flush();
        }

        public static void WriteError(string message)
        {
            EnsureConsole();
            Console.Error.WriteLine("error: " + message);
            Console.Error.Flush();
        }

        public static int Run(Options options)
        {
            try
            {
                return Task.Run(() => RunAsync(options)).GetAwaiter().GetResult();
            }
            catch (LauncherException error)
            {
                Log.Error(error.Message);
                WriteError(error.Message);
                return 1;
            }
            catch (Exception error)
            {
                Log.Error(error.ToString());
                WriteError(error.GetType().Name + ": " + error.Message);
                return 1;
            }
        }

        static async Task<int> RunAsync(Options options)
        {
            Log.Info($"CLI {options.Command} (launcher {LauncherConfig.CurrentVersion})");
            if (options.Command == "version")
            {
                Out($"version={LauncherConfig.CurrentVersion}");
                Out($"trusted_keys={ReleaseSignature.TrustedKeys.Count}");
                return 0;
            }
            if (options.Command == "selftest") return SelfTest.Run(Out);
            if (options.Command == "xr-probe")
            {
                if (options.Loader == null) throw new LauncherException("xr-probe needs --loader <openxr_loader.dll>.");
                return XrProbe.RunInProcess(options.Loader, Out);
            }

            var engine = new Engine(options.Config);
            if (options.GameRoot != null) engine.SetGameRoot(options.GameRoot);
            if (options.IncludePrereleases.HasValue) engine.SetIncludePrereleases(options.IncludePrereleases.Value);
            if (options.SteamLaunchMode != null) engine.SetSteamLaunchMode(options.SteamLaunchMode);
            var cancel = CancellationToken.None;

            switch (options.Command)
            {
                case "status":
                    PrintSnapshot(await engine.InspectAsync());
                    return 0;
                case "check":
                    var check = await engine.CheckUpdatesAsync(cancel);
                    Out($"releases_seen={check.ReleasesSeen}");
                    foreach (var skipped in check.Skipped) Out($"skipped={skipped}");
                    if (check.Best == null)
                    {
                        Out("available=none");
                        return 0;
                    }
                    Out($"available_tag={check.Best.Release.TagName}");
                    Out($"available_mod={check.Best.Version}");
                    Out($"available_launcher={check.Best.Manifest.Launcher?.Version}");
                    Out($"launcher_update={engine.LauncherUpdateAvailable.ToString().ToLowerInvariant()}");
                    return 0;
                case "install-deps":
                    Out($"files_written={await engine.InstallDependenciesAsync(null, cancel)}");
                    return 0;
                case "install-mod":
                    var note = await engine.InstallModAsync(null, cancel);
                    Out($"installed={engine.State.InstalledTag}");
                    if (note != null) Out($"note={note}");
                    return 0;
                case "vr":
                case "flat":
                    await engine.PlayAsync(options.Command == "vr", options.Launch, new Progress<string>(s => Log.Info(s)), null, cancel);
                    PrintSnapshot(await engine.InspectAsync());
                    return 0;
                case "uninstall":
                    Out($"result={await engine.UninstallAsync(options.RemoveModLoader, options.RemoveData)}");
                    return 0;
                case "self-update":
                    await engine.CheckUpdatesAsync(cancel);
                    var updated = await engine.SelfUpdateAsync(!options.NoRestart, null, cancel);
                    Out($"self_updated={updated.ToString().ToLowerInvariant()}");
                    return 0;
                case "support-zip":
                    Out($"support_zip={await engine.CreateSupportZipAsync()}");
                    return 0;
                case "auto-update":
                    var replaced = await engine.UpdateAutomaticallyAsync(!options.NoRestart, null, cancel);
                    Out($"self_updated={replaced.ToString().ToLowerInvariant()}");
                    Out($"installed={engine.State.InstalledTag}");
                    return 0;
                case "steam-setup":
                    Out($"result={engine.SetUpSteam()}");
                    PrintSteam(engine);
                    return 0;
                case "steam-remove":
                    Out($"result={engine.RemoveSteam()}");
                    PrintSteam(engine);
                    return 0;
                case "steam-status":
                    PrintSteam(engine);
                    return 0;
                case "tuning":
                    var hardware = engine.Hardware;
                    var plan = engine.Tuning;
                    Out($"gpu={hardware.GpuName}");
                    Out($"gpu_memory_mb={hardware.GpuMemoryBytes >> 20}");
                    Out($"ram_gb={Engine.Gigabytes(hardware.RamBytes)}");
                    Out($"free_ram_gb={Engine.Gigabytes(hardware.FreeRamBytes)}");
                    Out($"tuning={(engine.TuningOn ? "on" : "off")}");
                    Out($"tuning_class={plan.Size}");
                    Out($"eye_pixel_cap={plan.EyePixelCap}");
                    foreach (var cap in plan.Caps) Out($"cap={cap.Key}:{cap.Value}");
                    Out($"tuned={Flag(engine.Tuned)}");
                    foreach (var change in engine.State.TunedChanges) Out($"lowered={change.Key}:{change.From}->{change.To}");
                    return 0;
                case "decide":
                    var root = engine.GameRoot ?? engine.FindGame() ?? throw new LauncherException("Darktide wasn't found.");
                    var decision = await LaunchDecider.DecideAsync(root, engine.State);
                    Out($"decision={(decision.Vr ? "vr" : "flat")}");
                    Out($"reason={decision.Reason}");
                    Out($"runtime_override={decision.RuntimeManifest}");
                    return 0;
                default:
                    WriteError($"Unknown command: {options.Command}");
                    return 2;
            }
        }

        static void PrintSnapshot(Snapshot s)
        {
            Out($"game_root={s.GameRoot}");
            Out($"darktide_running={Flag(s.DarktideRunning)}");
            Out($"mod_loader={Flag(s.ModLoaderPresent)}");
            Out($"patch_tool={Flag(s.PatchToolPresent)}");
            Out($"mods_enabled={Flag(s.ModsEnabled)}");
            Out($"framework={Flag(s.FrameworkPresent)}");
            Out($"mod_installed={Flag(s.ModInstalled)}");
            Out($"mod_version={s.InstalledVersion}");
            Out($"vortex_manages_mod={Flag(s.VortexManagesMod)}");
            Out($"executable={s.ExeState}");
            Out($"d3d12_proxy={s.Status?.Get("d3d12_proxy")}");
            Out($"load_order={s.Status?.Get("load_order")}");
            Out($"vr_mode={Flag(s.VrModeOn)}");
            Out($"xr_runtime={s.Xr.Runtime}");
            Out($"xr_service_running={Flag(s.Xr.ServiceRunning)}");
        }

        static void PrintSteam(Engine engine)
        {
            var steam = engine.SteamStatus();
            Out($"steam_found={Flag(steam.SteamFound)}");
            Out($"steam_launch_option={Flag(steam.LaunchOption)}");
            Out($"steamvr_library={Flag(steam.Library)}");
            Out($"stable_copy={StableCopy.ExePath}");
            Out($"launch_option_text={SteamLaunchOptions.Expected}");
            Out($"last_launch={steam.LastLaunch}");
        }

        static string Flag(bool value) => value ? "true" : "false";
    }

    // Pure checks of the pieces most likely to hurt a player if wrong.
    public static class SelfTest
    {
        public static int Run(Action<string> output)
        {
            var failures = new List<string>();
            void Check(string name, bool ok)
            {
                output($"{(ok ? "pass" : "FAIL")} {name}");
                if (!ok) failures.Add(name);
            }
            bool Throws(Action action)
            {
                try { action(); return false; }
                catch (LauncherException) { return true; }
            }

            Check("version: release above its prerelease", ReleaseVersion.IsNewer("0.3.0", "0.3.0-alpha.2"));
            Check("version: alpha.10 above alpha.2", ReleaseVersion.IsNewer("0.3.0-alpha.10", "0.3.0-alpha.2"));
            Check("version: beta above alpha", ReleaseVersion.IsNewer("0.3.0-beta.1", "0.3.0-alpha.9"));
            Check("version: v prefix", !ReleaseVersion.IsNewer("v0.3.0-alpha.2", "0.3.0-alpha.2"));
            Check("version: older is not newer", !ReleaseVersion.IsNewer("0.2.9", "0.3.0-alpha.1"));
            Check("version: garbage is never newer", !ReleaseVersion.IsNewer("latest", "0.1.0"));

            var root = Path.Combine(Path.GetTempPath(), "dvr-selftest");
            Check("path: plain file inside", Files.ResolveInside(root, "mods/dmf/dmf.mod").StartsWith(root, StringComparison.OrdinalIgnoreCase));
            Check("path: parent escape refused", Throws(() => Files.ResolveInside(root, "../evil.dll")));
            Check("path: nested escape refused", Throws(() => Files.ResolveInside(root, "mods/../../evil.dll")));
            Check("path: rooted refused", Throws(() => Files.ResolveInside(root, @"C:\Windows\evil.dll")));
            Check("path: leading slash refused", Throws(() => Files.ResolveInside(root, "/evil.dll")));
            Check("path: alternate stream refused", Throws(() => Files.ResolveInside(root, "file.txt:stream")));

            Check("signature: garbage refused", !ReleaseSignature.Verify(new byte[] { 1, 2, 3 }, Convert.ToBase64String(new byte[64])));
            Check("signature: wrong length refused", !ReleaseSignature.Verify(new byte[] { 1 }, "AAAA"));
            Check("signature: not base64 refused", !ReleaseSignature.Verify(new byte[] { 1 }, "***"));

            var releases = Json.Parse<List<GitHubRelease>>(
                "[{\"tag_name\":\"v1\",\"draft\":false,\"prerelease\":true,\"assets\":[{\"name\":\"a.zip\",\"size\":5," +
                "\"browser_download_url\":\"https://x/a.zip\",\"digest\":\"sha256:00\",\"uploader\":{\"login\":\"x\"}}],\"extra\":[1,2]}]");
            Check("json: GitHub release parsed, unknown fields ignored", releases.Count == 1 && releases[0].Prerelease && releases[0].Assets[0].Size == 5);
            var bom = Json.Parse<PackageManifest>("\uFEFF{\"release_version\":\"0.3.0-alpha.2\",\"files\":[]}");
            Check("json: byte-order mark tolerated", bom.ReleaseVersion == "0.3.0-alpha.2");

            var vdfText = "\"UserLocalConfigStore\"\n{\n\t\"Software\"\n\t{\n\t\t\"apps\"\n\t\t{\n\t\t\t\"1361210\"\n\t\t\t{\n" +
                          "\t\t\t\t\"LaunchOptions\"\t\t\"\\\"C:\\\\a b\\\\x.exe\\\" %command%\"\n\t\t\t}\n\t\t}\n\t}\n}\n";
            var vdf = Vdf.Parse(vdfText);
            var option = vdf[0].Children[0].Children[0].Children[0].Children[0];
            Check("vdf: escaped value read", option.Value == "\"C:\\a b\\x.exe\" %command%");
            Check("vdf: value span is the quoted token", vdfText.Substring(option.ValueStart, option.ValueEnd - option.ValueStart) == Vdf.Quote(option.Value));
            Check("vdf: block depth", option.Depth == 4);
            Check("args: plain", SteamLaunch.QuoteArgument("-dx12") == "-dx12");
            Check("args: spaces quoted", SteamLaunch.QuoteArgument(@"C:\Program Files\x.exe") == "\"C:\\Program Files\\x.exe\"");
            Check("args: trailing backslash doubled", SteamLaunch.QuoteArgument(@"C:\a b\") == "\"C:\\a b\\\\\"");
            Check("args: inner quote escaped", SteamLaunch.QuoteArgument("a\"b") == "\"a\\\"b\"");

            const long Mb = 1L << 20;
            Check("tuning: 16 GB cards keep everything", TuningPlan.For(16376 * Mb).ChangesNothing);
            Check("tuning: an unread card changes nothing", TuningPlan.For(0).ChangesNothing);
            var twelve = TuningPlan.For(12011 * Mb);
            Check("tuning: 12 GB caps the eye at 2112x2304 and reflections off", twelve.EyePixelCap == 2112L * 2304 &&
                twelve.Caps["ssr_quality"] == "off" && twelve.Caps["light_quality"] == "high" && twelve.Caps["volumetric_fog_quality"] == "high");
            Check("tuning: 8 GB lowers shadows to medium", TuningPlan.For(8019 * Mb).Caps["light_quality"] == "medium");

            // Bimo's VR profile in the game's layout, with Windows line ends.
            string Settings(string preset) => string.Join("\r\n",
                "master_render_settings = {", $"\tgraphics_quality = \"{preset}\"", "\tlight_quality = \"extreme\"",
                "\tssr_quality = \"high\"", "\ttexture_quality = \"high\"", "\tvolumetric_fog_quality = \"extreme\"", "}",
                "render_settings = {", "\tlocal_lights_shadow_atlas_size = [", "\t\t4096", "\t\t4096", "\t]", "\tssr_enabled = true",
                "\tssr_high_quality = true", "\tvolumetric_data_size = [", "\t\t144", "\t\t112", "\t\t196", "\t]",
                "\tvolumetric_reprojection_amount = -0.875", "}", "mods_settings = {", "}", "");
            var bimo = new SettingsFile(Settings("custom"));
            var lowered = PcTuning.Lower(bimo, twelve);
            var text = bimo.ToString();
            Check("tuning: the three settings lowered as the menu would", lowered.Count == 3 &&
                bimo.Get("master_render_settings", "ssr_quality") == "off" && bimo.Get("render_settings", "ssr_enabled") == "false" &&
                text.Contains("\tlocal_lights_shadow_atlas_size = [\r\n\t\t2048\r\n\t\t2048\r\n\t]") &&
                text.Contains("\tvolumetric_data_size = [\r\n\t\t128\r\n\t\t96\r\n\t\t160\r\n\t]") &&
                bimo.Get("render_settings", "volumetric_reprojection_amount") == "0");
            Check("tuning: other settings and line ends kept", bimo.Get("master_render_settings", "texture_quality") == "high" &&
                text.Replace("\r\n", "").IndexOf('\n') < 0 && text.Contains("\tvolumetric_volumes_enabled = true\r\n}\r\nmods_settings = {"));
            Check("tuning: lowering twice changes nothing more", PcTuning.Lower(bimo, twelve).Count == 0 && bimo.ToString() == text);
            bimo.Set("master_render_settings", "light_quality", "\"medium\"");
            Check("tuning: undo restores, except what the player changed since", PcTuning.Restore(bimo, lowered) == 2 &&
                bimo.Get("master_render_settings", "ssr_quality") == "high" && bimo.Get("render_settings", "ssr_high_quality") == "true" &&
                bimo.Get("master_render_settings", "volumetric_fog_quality") == "extreme" &&
                bimo.ToString().Contains("\tvolumetric_data_size = [\r\n\t\t144\r\n\t\t112\r\n\t\t196\r\n\t]") &&
                bimo.Get("master_render_settings", "light_quality") == "medium");
            var preset = new SettingsFile(Settings("high"));
            var presetChanges = PcTuning.Lower(preset, twelve);
            Check("tuning: a preset becomes custom, and comes back", preset.Get("master_render_settings", "graphics_quality") == "custom" &&
                PcTuning.Restore(preset, presetChanges) == 4 && preset.Get("master_render_settings", "graphics_quality") == "high");
            var merged = PcTuning.Merge(new List<TunedChange> { new TunedChange { Key = "light_quality", From = "extreme", To = "high" } },
                new[] { new TunedChange { Key = "light_quality", From = "high", To = "medium" } });
            Check("tuning: tuning again keeps the player's first choice to undo to", merged.Count == 1 && merged[0].From == "extreme" && merged[0].To == "medium");

            output(failures.Count == 0 ? "selftest=pass" : $"selftest=FAIL ({failures.Count})");
            return failures.Count == 0 ? 0 : 1;
        }
    }
}
