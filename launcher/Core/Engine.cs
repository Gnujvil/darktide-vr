using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;

namespace DarktideVR.Launcher.Core
{
    public sealed class Snapshot
    {
        public string GameRoot { get; set; }
        public bool GameFound { get; set; }
        public bool DarktideRunning { get; set; }
        public bool ModLoaderPresent { get; set; }
        public bool PatchToolPresent { get; set; }
        public bool ModsEnabled { get; set; }
        public bool FrameworkPresent { get; set; }
        public bool ModInstalled { get; set; }
        public string InstalledVersion { get; set; }
        public bool VortexManagesMod { get; set; }
        public ModeResult Status { get; set; }
        public XrStatus Xr { get; set; }

        // original | patched | unsupported | patch-tool-missing (from the mode script)
        public string ExeState => Status?.Get("executable");
        public bool GameBuildSupported => ExeState == "original" || ExeState == "patched";
        // All three pieces: a developer install can rest with the proxy and
        // the load-order line in place but the executable pristine.
        public bool VrModeOn => Status != null && ExeState == "patched" && Status.Get("load_order") == "listed" &&
                                (Status.Get("d3d12_proxy") == "installed" || Status.Get("d3d12_proxy") == "outdated");
        public bool DependenciesReady => ModLoaderPresent && PatchToolPresent && FrameworkPresent;
    }

    public sealed class Engine
    {
        public LauncherConfig Config { get; }
        public LauncherState State { get; private set; }
        public UpdateCheck LastCheck { get; private set; }
        readonly Net net = new Net();
        readonly ReleaseFeed feed;
        readonly Dependencies dependencies;

        public Engine(LauncherConfig config)
        {
            Config = config;
            feed = new ReleaseFeed(config, net);
            dependencies = new Dependencies(config, net);
            State = LoadState();
        }

        public AvailableRelease Available => LastCheck?.Best;

        public bool ModUpdateAvailable(Snapshot snapshot) =>
            Available != null && snapshot.ModInstalled && ReleaseVersion.IsNewer(Available.Version, snapshot.InstalledVersion);

        public bool LauncherUpdateAvailable =>
            Available?.Manifest.Launcher?.Version != null && Available.LauncherAsset != null &&
            ReleaseVersion.IsNewer(Available.Manifest.Launcher.Version, LauncherConfig.CurrentVersion);

        // ---- state -------------------------------------------------------

        static LauncherState LoadState()
        {
            try
            {
                if (File.Exists(Paths.StatePath))
                {
                    var state = Json.Parse<LauncherState>(File.ReadAllText(Paths.StatePath));
                    if (state != null)
                    {
                        if (state.OwnedFiles == null) state.OwnedFiles = new List<OwnedFile>();
                        if (state.TunedChanges == null) state.TunedChanges = new List<TunedChange>();
                        return state;
                    }
                }
            }
            catch (Exception error) { Log.Warn($"state.json unreadable, starting fresh: {error.Message}"); }
            return new LauncherState();
        }

        public void SaveState()
        {
            Files.WriteWhole(Paths.StatePath, System.Text.Encoding.UTF8.GetBytes(Json.Write(State)));
        }

        // ---- the game folder ----------------------------------------------

        public string GameRoot => GameLocator.IsGameRoot(State.GameRoot) ? State.GameRoot : null;

        public string FindGame()
        {
            if (GameRoot != null) return GameRoot;
            var found = GameLocator.FindSteamInstalls().FirstOrDefault();
            if (found != null)
            {
                Log.Info($"Darktide found at {found}");
                State.GameRoot = found;
                SaveState();
            }
            return found;
        }

        public string SetGameRoot(string picked)
        {
            var root = GameLocator.Normalize(picked);
            if (root == null) throw new LauncherException("That folder isn't a Darktide install. Pick the folder that contains \"binaries\" and \"bundle\".");
            State.GameRoot = root;
            SaveState();
            Log.Info($"Game folder set to {root}");
            return root;
        }

        string RequireGame()
        {
            return GameRoot ?? FindGame() ?? throw new LauncherException("Darktide wasn't found. Use \"Change\" on the Darktide line to pick the game folder.");
        }

        static void RequireClosed(string root)
        {
            if (GameLocator.IsDarktideRunning(root)) throw new LauncherException("Darktide is running. Close it first.");
        }

        public async Task<Snapshot> InspectAsync()
        {
            hardware = null; // free memory changes between refreshes
            var snapshot = new Snapshot { GameRoot = GameRoot ?? FindGame(), Xr = XrRuntime.Detect() };
            snapshot.GameFound = snapshot.GameRoot != null;
            snapshot.DarktideRunning = GameLocator.IsDarktideRunning(snapshot.GameRoot);
            if (!snapshot.GameFound) return snapshot;
            var root = snapshot.GameRoot;
            snapshot.ModLoaderPresent = Dependencies.ModLoaderPresent(root);
            snapshot.PatchToolPresent = Dependencies.PatchToolPresent(root);
            snapshot.FrameworkPresent = Dependencies.FrameworkPresent(root);
            snapshot.ModsEnabled = await Task.Run(() => Dependencies.ModsEnabled(root));
            snapshot.ModInstalled = ModPackage.Installed(root);
            snapshot.InstalledVersion = ModPackage.ReadInstalled(root)?.ReleaseVersion;
            snapshot.VortexManagesMod = Vortex.ManagesMod(root, ModPackage.ModName);
            if (snapshot.ModInstalled && !snapshot.DarktideRunning)
                snapshot.Status = await ModeScript.RunAsync(root, "status");
            return snapshot;
        }

        // ---- updates -------------------------------------------------------

        public async Task<UpdateCheck> CheckUpdatesAsync(CancellationToken cancel)
        {
            LastCheck = await feed.CheckAsync(State.IncludePrereleases, cancel);
            Log.Info(LastCheck.Best == null
                ? $"No trusted release among {LastCheck.ReleasesSeen}: {string.Join("; ", LastCheck.Skipped)}"
                : $"Newest trusted release: {LastCheck.Best.Release.TagName} (mod {LastCheck.Best.Version}, launcher {LastCheck.Best.Manifest.Launcher?.Version})");
            return LastCheck;
        }

        async Task<AvailableRelease> RequireRelease(CancellationToken cancel)
        {
            if (Available == null) await CheckUpdatesAsync(cancel);
            return Available ?? throw new LauncherException("No release of Darktide VR is available to the launcher yet. Ask the mod author, or try again later.");
        }

        // Used by the window and Steam entry points. Never patch a running
        // game or take over an installation that Vortex manages.
        public async Task<bool> UpdateAutomaticallyAsync(bool restartLauncher,
            IProgress<double> progress, CancellationToken cancel)
        {
            using (var checkTimeout = CancellationTokenSource.CreateLinkedTokenSource(cancel))
            {
                checkTimeout.CancelAfter(TimeSpan.FromSeconds(20));
                await CheckUpdatesAsync(checkTimeout.Token);
            }
            if (LauncherUpdateAvailable)
            {
                Log.Info("Installing the signed launcher update automatically.");
                return await SelfUpdateAsync(restartLauncher, progress, cancel);
            }
            var snapshot = await InspectAsync();
            if (snapshot.ModInstalled && !snapshot.DarktideRunning &&
                !snapshot.VortexManagesMod && ModUpdateAvailable(snapshot))
            {
                Log.Info("Installing the signed Darktide VR update automatically.");
                var note = await InstallModAsync(progress, cancel);
                if (note != null) Log.Warn(note);
            }
            return false;
        }

        public async Task<int> InstallDependenciesAsync(IProgress<double> progress, CancellationToken cancel)
        {
            var root = RequireGame();
            RequireClosed(root);
            var release = await RequireRelease(cancel);
            var written = await dependencies.InstallAsync(root, release.Manifest.ModLoader, State, progress, cancel);
            written += await dependencies.InstallAsync(root, release.Manifest.ModFramework, State, progress, cancel);
            SaveState();
            return written;
        }

        // Installs or updates the mod folder to the newest trusted release.
        // Returns a note for the player when VR mode couldn't be reapplied.
        public async Task<string> InstallModAsync(IProgress<double> progress, CancellationToken cancel)
        {
            var root = RequireGame();
            RequireClosed(root);
            var release = await RequireRelease(cancel);
            if (ReleaseVersion.IsNewer(release.Manifest.MinLauncherVersion, LauncherConfig.CurrentVersion))
                throw new LauncherException($"Darktide VR {release.Version} needs launcher {release.Manifest.MinLauncherVersion} or newer. Update the launcher first.");
            if (Vortex.ManagesMod(root, ModPackage.ModName))
                throw new LauncherException("Darktide VR is managed by Vortex here. Update it in Vortex, or remove it from Vortex to let the launcher manage it.");

            var wasVr = false;
            if (ModPackage.Installed(root))
            {
                var status = await ModeScript.RunAsync(root, "status");
                wasVr = status.Get("load_order") == "listed" || status.Get("d3d12_proxy") == "installed" || status.Get("d3d12_proxy") == "outdated";
            }

            var zip = await GetModZip(release, progress, cancel);
            Log.Info($"Installing Darktide VR {release.Version} into {ModPackage.ModDirectory(root)}");
            await Task.Run(() => ModPackage.Install(root, zip));
            // Cached only once installed: the cache is what flat mode restores
            // with when the mod folder is gone, so it must be the package that
            // was actually installed.
            var cached = Path.Combine(Paths.CacheDirectory, release.Manifest.Mod.Sha256.ToLowerInvariant() + ".zip");
            if (!File.Exists(cached)) Files.WriteWhole(cached, zip);
            KeepOnlyCached(release.Manifest.Mod.Sha256);
            State.InstalledTag = release.Release.TagName;
            State.InstalledModSha256 = release.Manifest.Mod.Sha256.ToLowerInvariant();
            SaveState();

            if (!wasVr) return null;
            var vr = await ModeScript.RunAsync(root, "vr");
            // The new mod folder has no resolution cap yet.
            if (vr.Ok) TuneVr(root);
            return vr.Ok ? null : "The mod was updated, but VR mode couldn't be switched back on: " + vr.Message;
        }

        async Task<byte[]> GetModZip(AvailableRelease release, IProgress<double> progress, CancellationToken cancel)
        {
            var sha = release.Manifest.Mod.Sha256.ToLowerInvariant();
            var cached = Path.Combine(Paths.CacheDirectory, sha + ".zip");
            if (File.Exists(cached))
            {
                var bytes = File.ReadAllBytes(cached);
                if (Hash.Same(Hash.Sha256(bytes), sha)) return bytes;
            }
            return await net.DownloadAsync(release.ModAsset.DownloadUrl, release.Manifest.Mod.Size, sha, progress, cancel);
        }

        static void KeepOnlyCached(string sha)
        {
            if (!Directory.Exists(Paths.CacheDirectory)) return;
            foreach (var file in Directory.GetFiles(Paths.CacheDirectory, "*.zip"))
                if (!string.Equals(Path.GetFileNameWithoutExtension(file), sha, StringComparison.OrdinalIgnoreCase))
                    try { File.Delete(file); } catch { }
        }

        static byte[] CachedZip()
        {
            if (!Directory.Exists(Paths.CacheDirectory)) return null;
            var file = Directory.GetFiles(Paths.CacheDirectory, "*.zip").OrderByDescending(File.GetLastWriteTimeUtc).FirstOrDefault();
            return file == null ? null : File.ReadAllBytes(file);
        }

        // ---- play ------------------------------------------------------------

        // Gets everything ready and starts Darktide through Steam. VR: installs
        // what's missing, switches mods back on after a game update, then the
        // mod's VR mode. Flat: the mod's flat mode; other mods stay on.
        public async Task PlayAsync(bool vr, bool launch, IProgress<string> step, IProgress<double> progress, CancellationToken cancel)
        {
            var root = RequireGame();
            RequireClosed(root);
            if (vr)
            {
                if (!Dependencies.ModLoaderPresent(root) || !Dependencies.PatchToolPresent(root) || !Dependencies.FrameworkPresent(root))
                {
                    step?.Report("Installing the mod loader and mod framework…");
                    await InstallDependenciesAsync(progress, cancel);
                }
                if (!ModPackage.Installed(root))
                {
                    step?.Report("Installing Darktide VR…");
                    await InstallModAsync(progress, cancel);
                }
                step?.Report("Switching mods on…");
                await Dependencies.EnableModsAsync(root);
                step?.Report("Switching VR mode on…");
                var result = await ModeScript.RunAsync(root, "vr");
                if (!result.Ok)
                {
                    var status = await ModeScript.RunAsync(root, "status");
                    if (status.Get("executable") == "unsupported")
                        throw new LauncherException(Strings.GameBuildUnsupported);
                    throw new LauncherException("VR mode couldn't be switched on: " + result.Message);
                }
                TuneVr(root);
            }
            else
            {
                step?.Report("Switching VR mode off…");
                await RunFlatAsync(root);
                if (Dependencies.ModLoaderPresent(root) && Dependencies.PatchToolPresent(root))
                    await Dependencies.EnableModsAsync(root);
            }
            if (launch)
            {
                // With the launch option set, Steam runs the launcher again;
                // this tells it what was chosen here.
                if (SteamStatus().LaunchOption) NextLaunch.Write(vr ? "vr" : "flat");
                LaunchSteam();
            }
        }

        async Task RunFlatAsync(string root)
        {
            ModeResult result;
            if (ModPackage.Installed(root)) result = await ModeScript.RunAsync(root, "flat");
            else
            {
                // The mod folder is gone but a patched executable or our proxy
                // may remain: restore with the script from the cached package.
                var zip = CachedZip();
                if (zip == null) return;
                var script = ModPackage.ExtractRecoveryScript(zip);
                try { result = await ModeScript.RunScriptAsync(script, root, "flat"); }
                finally { TryDelete(Path.GetDirectoryName(Path.GetDirectoryName(Path.GetDirectoryName(script)))); }
            }
            if (!result.Ok) throw new LauncherException("Flat mode couldn't be switched on: " + result.Message);
        }

        public static void LaunchSteam()
        {
            Log.Info("Starting Darktide through Steam");
            Process.Start(new ProcessStartInfo($"steam://rungameid/{LauncherConfig.SteamAppId}") { UseShellExecute = true });
        }

        // ---- uninstall -------------------------------------------------------

        public async Task<string> UninstallAsync(bool removeModLoader, bool removeData)
        {
            var root = RequireGame();
            RequireClosed(root);
            var notes = new List<string>();
            // First, while it can still refuse cleanly: a launch option left
            // pointing at a removed launcher would stop Steam starting Darktide.
            if (SteamStatus().Any) notes.Add(RemoveSteam());
            await RunFlatAsync(root);
            if (Vortex.ManagesMod(root, ModPackage.ModName))
                notes.Add("VR mode is off. Darktide VR is managed by Vortex here, so remove it in Vortex.");
            else
            {
                ModPackage.Remove(root);
                notes.Add("Darktide VR is removed and the game is back to normal.");
            }
            if (removeModLoader)
            {
                if (State.OwnedFiles.Count == 0)
                    notes.Add("The mod loader and framework were not installed by this launcher, so they were left in place.");
                else
                {
                    await Dependencies.DisableModsAsync(root);
                    var removed = Dependencies.RemoveOwned(root, State);
                    notes.Add($"Removed the mod loader and framework files the launcher installed ({removed}).");
                }
            }
            State.InstalledTag = null;
            State.InstalledModSha256 = null;
            if (removeData)
            {
                // Logged first: the log lives in the folder being removed.
                notes.Add("Removed the launcher's data and the mod's settings backups.");
                Log.Info("Uninstall: " + string.Join(" ", notes));
                TryDelete(Paths.DataRoot);
            }
            else
            {
                SaveState();
                Log.Info("Uninstall: " + string.Join(" ", notes));
            }
            return string.Join(" ", notes);
        }

        static void TryDelete(string directory)
        {
            try { Files.DeleteDirectory(directory); }
            catch (Exception error) { Log.Warn($"Couldn't remove {directory}: {error.Message}"); }
        }

        // ---- the launcher itself ---------------------------------------------

        public async Task<bool> SelfUpdateAsync(bool restart, IProgress<double> progress, CancellationToken cancel)
        {
            if (!LauncherUpdateAvailable) return false;
            var file = Available.Manifest.Launcher;
            var bytes = await net.DownloadAsync(Available.LauncherAsset.DownloadUrl, file.Size, file.Sha256, progress, cancel);
            SelfUpdater.Apply(bytes, restart);
            return true;
        }

        public void SetIncludePrereleases(bool value)
        {
            State.IncludePrereleases = value;
            SaveState();
        }

        // ---- Steam and VR headsets ---------------------------------------------

        public sealed class SteamSetup
        {
            public bool SteamFound { get; set; }
            public bool LaunchOption { get; set; }
            public bool Library { get; set; }
            public string LastLaunch { get; set; }
            public bool Any => LaunchOption || Library;
            public bool Complete => LaunchOption && Library;
        }

        public SteamSetup SteamStatus()
        {
            var steam = GameLocator.SteamRoot();
            if (steam == null) return new SteamSetup();
            return new SteamSetup
            {
                SteamFound = true,
                LaunchOption = SafeCheck(() => SteamLaunchOptions.IsConfigured(steam)),
                Library = SafeCheck(() => SteamVrLibrary.IsRegistered(steam)),
                LastLaunch = State.LastLaunch,
            };
        }

        static bool SafeCheck(Func<bool> check)
        {
            try { return check(); }
            catch (Exception error)
            {
                Log.Warn("Steam settings unreadable: " + error.Message);
                return false;
            }
        }

        // Darktide starts through the launcher from Steam (VR when a headset
        // answers, flat otherwise) and is listed in the SteamVR library.
        public string SetUpSteam()
        {
            var root = RequireGame();
            var steam = GameLocator.SteamRoot() ?? throw new LauncherException("Steam wasn't found.");
            StableCopy.Ensure();
            if (!File.Exists(StableCopy.ExePath)) throw new LauncherException($"The launcher couldn't copy itself to {StableCopy.ExePath}.");
            var notes = new List<string>();
            try
            {
                SteamLaunchOptions.Set(steam, State);
                notes.Add("Steam now starts Darktide through the launcher: in VR when a headset is connected, flat otherwise.");
            }
            catch (LauncherException error) { notes.Add(error.Message); }
            finally { SaveState(); }
            var launchOption = SteamLaunchOptions.IsConfigured(steam);
            try
            {
                SteamVrLibrary.Register(steam, root, launchOption);
                notes.Add("Darktide VR is listed in your SteamVR library (Steam Link).");
            }
            catch (LauncherException error) { notes.Add(error.Message); }
            return string.Join(" ", notes);
        }

        public string RemoveSteam()
        {
            var steam = GameLocator.SteamRoot();
            if (steam == null) return "Steam wasn't found; nothing to remove.";
            SteamLaunchOptions.Remove(steam, State);
            SaveState();
            SteamVrLibrary.Unregister(steam);
            return "Darktide's Steam launch option and SteamVR library entry are removed.";
        }

        public void SetSteamLaunchMode(string mode)
        {
            if (mode != "auto" && mode != "vr" && mode != "flat") throw new LauncherException($"Unknown launch mode: {mode}");
            State.SteamLaunchMode = mode == "auto" ? null : mode;
            SaveState();
        }

        public void RecordLaunch(string what)
        {
            State.LastLaunch = $"{DateTime.Now:yyyy-MM-dd HH:mm} {what}";
            SaveState();
        }

        // ---- VR tuning ---------------------------------------------------------

        PcHardware hardware;
        public PcHardware Hardware => hardware ?? (hardware = PcHardware.Detect());
        public TuningPlan Tuning => TuningPlan.For(Hardware.GpuMemoryBytes);
        public bool TuningOn => State.VrTuning != "off";
        public bool Tuned => TuningOn && State.TunedSignature == Hardware.Signature;

        // Sizes VR to this PC right before the game starts in VR, and after a
        // mod update replaced the folder the resolution cap lives in. The
        // settings are lowered once per card, so what the player changes
        // afterwards stays. Never stops a launch: a failure changes nothing.
        public void TuneVr(string root)
        {
            try
            {
                var plan = Tuning;
                WriteEyePixelCap(root, TuningOn ? plan.EyePixelCap : 0);
                if (Hardware.FreeRamBytes > 0 && Hardware.FreeRamBytes < FreeRamWarning)
                    Log.Warn($"Only {Gigabytes(Hardware.FreeRamBytes)} GB of memory is free for VR.");
                if (Tuned || !TuningOn) return;
                // No VR settings yet: tuned once the game has written them.
                var path = VrSettingsPath();
                if (path == null) return;
                var settings = new SettingsFile(File.ReadAllText(path));
                var changes = PcTuning.Lower(settings, plan);
                if (changes.Count > 0) WriteSettings(path, settings);
                State.TunedChanges = PcTuning.Merge(State.TunedChanges, changes);
                State.TunedSignature = Hardware.Signature;
                SaveState();
                Log.Info($"VR tuned for {Hardware.GpuName} ({Gigabytes(Hardware.GpuMemoryBytes)} GB, {plan.Size} class): " +
                         (plan.EyePixelCap > 0 ? $"at most about {plan.EyeExtent} per eye" : "full resolution") +
                         (changes.Count > 0 ? "; " + string.Join(", ", changes.Select(PcTuning.Describe).Where(d => d != null)) : "; no settings needed lowering"));
            }
            catch (Exception error) { Log.Warn("VR tuning skipped: " + error.Message); }
        }

        // "Use my own settings" puts lowered settings back (unless the player
        // changed them since) and drops the resolution cap; on again tunes now.
        public string SetVrTuning(bool on)
        {
            var root = GameRoot;
            if (root != null) RequireClosed(root);
            if (on)
            {
                State.VrTuning = null;
                State.TunedSignature = null;
                SaveState();
                if (root != null) TuneVr(root);
                return "VR is tuned for this PC.";
            }
            var path = VrSettingsPath();
            if (path != null && State.TunedChanges.Count > 0)
            {
                var settings = new SettingsFile(File.ReadAllText(path));
                if (PcTuning.Restore(settings, State.TunedChanges) > 0) WriteSettings(path, settings);
            }
            State.VrTuning = "off";
            State.TunedSignature = null;
            State.TunedChanges = new List<TunedChange>();
            SaveState();
            if (root != null) WriteEyePixelCap(root, 0);
            Log.Info("VR tuning is off: the player's own settings and the headset's full resolution.");
            return "VR uses your own settings.";
        }

        public const long FreeRamWarning = 6L << 30;
        public static string Gigabytes(long bytes) => (bytes / (double)(1L << 30)).ToString("0.#", System.Globalization.CultureInfo.InvariantCulture);

        static void WriteEyePixelCap(string root, long cap)
        {
            if (!ModPackage.Installed(root)) return;
            var flag = Path.Combine(ModPackage.ModDirectory(root), PcTuning.CapFlagName);
            if (cap > 0) Files.WriteWhole(flag, System.Text.Encoding.ASCII.GetBytes(cap.ToString(System.Globalization.CultureInfo.InvariantCulture) + "\n"));
            else if (File.Exists(flag)) File.Delete(flag);
        }

        // The VR profile: the game's own file while VR mode is on, otherwise
        // the copy the mode switch keeps for it (darktidevr-mode.ps1).
        static string VrSettingsPath()
        {
            var marker = Path.Combine(Paths.DataRoot, "settings-profile.txt");
            var vrOn = File.Exists(marker) && File.ReadAllText(marker).Trim() == "vr";
            var path = vrOn
                ? Path.Combine(Paths.RoamingAppData, "Fatshark", "Darktide", "user_settings.config")
                : Path.Combine(Paths.DataRoot, "user_settings.vr.config");
            return File.Exists(path) ? path : null;
        }

        // A copy first, beside the mod's own settings backups but named so the
        // mode script never restores from it.
        static void WriteSettings(string path, SettingsFile settings)
        {
            var backups = Path.Combine(Paths.DataRoot, "settings-backups");
            Directory.CreateDirectory(backups);
            File.Copy(path, Path.Combine(backups, $"user_settings.before-tuning-{DateTime.Now:yyyyMMdd-HHmmss}.config"), true);
            Files.WriteWhole(path, System.Text.Encoding.UTF8.GetBytes(settings.ToString()));
        }

        // ---- support -----------------------------------------------------------

        public async Task<string> CreateSupportZipAsync()
        {
            var snapshot = await InspectAsync();
            var desktop = Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);
            var path = Path.Combine(desktop, $"DarktideVR-support-{DateTime.Now:yyyyMMdd-HHmmss}.zip");
            using (var zip = ZipFile.Open(path, ZipArchiveMode.Create))
            {
                var summary = new System.Text.StringBuilder();
                summary.AppendLine($"launcher={LauncherConfig.CurrentVersion}");
                summary.AppendLine($"windows={Environment.OSVersion.VersionString}");
                summary.AppendLine($"game_root={snapshot.GameRoot}");
                summary.AppendLine($"mod_loader={snapshot.ModLoaderPresent} mods_enabled={snapshot.ModsEnabled} framework={snapshot.FrameworkPresent}");
                summary.AppendLine($"mod_installed={snapshot.ModInstalled} version={snapshot.InstalledVersion} vortex={snapshot.VortexManagesMod}");
                summary.AppendLine($"xr={snapshot.Xr.DisplayName} manifest={snapshot.Xr.ManifestPath} service_running={snapshot.Xr.ServiceRunning}");
                summary.AppendLine($"gpu={Hardware.GpuName} gpu_memory_mb={Hardware.GpuMemoryBytes >> 20} ram_gb={Gigabytes(Hardware.RamBytes)} free_ram_gb={Gigabytes(Hardware.FreeRamBytes)}");
                summary.AppendLine($"vr_tuning={(TuningOn ? "on" : "off")} tuned={Tuned} eye_pixel_cap={(TuningOn ? Tuning.EyePixelCap : 0)} lowered=" +
                                   string.Join(",", State.TunedChanges.Select(c => $"{c.Key}:{c.From}->{c.To}")));
                summary.AppendLine();
                summary.AppendLine(snapshot.Status?.Output ?? "(mode script not run)");
                var entry = zip.CreateEntry("summary.txt");
                using (var writer = new StreamWriter(entry.Open())) writer.Write(summary.ToString());
                AddIfExists(zip, Paths.LogPath, "launcher.log");
                AddIfExists(zip, Paths.LogPath + ".1", "launcher.log.1");
                // The viewer's logs and the game's console logs, newest first;
                // no settings files.
                AddNewest(zip, Paths.DataRoot, "viewer-*.log", 3, "viewer");
                AddNewest(zip, Path.Combine(Paths.RoamingAppData, "Fatshark", "Darktide", "console_logs"), "*.log", 2, "console_logs");
                // SteamVR's own logs: which app it gave the headset and what
                // its compositor showed.
                var steam = GameLocator.SteamRoot();
                if (steam != null)
                    foreach (var name in new[] { "vrserver.txt", "vrserver.previous.txt", "vrcompositor.txt", "vrcompositor.previous.txt" })
                        AddIfExists(zip, Path.Combine(steam, "logs", name), "steamvr/" + name);
            }
            Log.Info($"Support zip written: {path}");
            return path;
        }

        static void AddIfExists(ZipArchive zip, string path, string name)
        {
            if (!File.Exists(path)) return;
            using (var source = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            using (var target = zip.CreateEntry(name).Open())
                source.CopyTo(target);
        }

        static void AddNewest(ZipArchive zip, string directory, string pattern, int count, string folder)
        {
            if (!Directory.Exists(directory)) return;
            foreach (var file in new DirectoryInfo(directory).GetFiles(pattern).OrderByDescending(f => f.LastWriteTimeUtc).Take(count))
                AddIfExists(zip, file.FullName, folder + "/" + file.Name);
        }
    }

    public static class SelfUpdater
    {
        public static async Task<int> RunReplacementAsync(string[] arguments)
        {
            var command = "--updated " + string.Join(" ", arguments.Select(QuoteArgument));
            using (var replacement = Process.Start(new ProcessStartInfo(Paths.ExePath, command) { UseShellExecute = false }))
            {
                await Task.Run(() => replacement.WaitForExit());
                return replacement.ExitCode;
            }
        }

        static string QuoteArgument(string argument)
        {
            var result = new System.Text.StringBuilder("\"");
            var slashes = 0;
            foreach (var character in argument)
            {
                if (character == '\\') { slashes++; continue; }
                if (character == '"') result.Append('\\', slashes * 2 + 1);
                else result.Append('\\', slashes);
                slashes = 0;
                result.Append(character);
            }
            result.Append('\\', slashes * 2).Append('"');
            return result.ToString();
        }

        static string OldExePath => Path.Combine(Path.GetDirectoryName(Paths.ExePath), Path.GetFileNameWithoutExtension(Paths.ExePath) + ".old.exe");

        // The previous process may still be exiting; retry briefly. The window
        // does it in the background; a command-line run, which may exit within
        // a second, waits for it.
        public static void CleanupOld(bool wait = false)
        {
            var old = OldExePath;
            if (!File.Exists(old)) return;
            if (wait) DeleteOld(old, 10);
            else Task.Run(() => DeleteOld(old, 20));
        }

        static void DeleteOld(string old, int attempts)
        {
            for (var attempt = 0; attempt < attempts; attempt++)
            {
                try
                {
                    File.Delete(old);
                    Log.Info("Removed the previous launcher version.");
                    return;
                }
                catch { System.Threading.Thread.Sleep(500); }
            }
            Log.Warn($"Couldn't remove {old}; it is retried at the next start.");
        }

        // A running exe can be renamed but not overwritten: rename it aside,
        // put the verified new exe in its place, start it.
        public static void Apply(byte[] bytes, bool restart)
        {
            var exe = Paths.ExePath;
            var old = OldExePath;
            var download = exe + ".download";
            try
            {
                File.WriteAllBytes(download, bytes);
                if (File.Exists(old)) File.Delete(old);
                File.Move(exe, old);
            }
            catch (UnauthorizedAccessException error)
            {
                throw new LauncherException($"Windows didn't allow replacing the launcher in {Path.GetDirectoryName(exe)}. Move DarktideVR-Launcher.exe to your Desktop or Downloads folder and try again.", error);
            }
            try
            {
                File.Move(download, exe);
            }
            catch
            {
                File.Move(old, exe);
                throw;
            }
            Log.Info($"Launcher replaced; previous version kept as {old} until the next start.");
            if (restart) Process.Start(new ProcessStartInfo(exe, "--updated") { UseShellExecute = false });
        }
    }
}
