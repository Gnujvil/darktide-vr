using System;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using DarktideVR.Launcher.Core;

namespace DarktideVR.Launcher
{
    public enum RowState { Unknown, Ok, Warn, Error, Busy }

    public sealed class SetupRow : INotifyPropertyChanged
    {
        string detail, actionLabel;
        RowState state;
        bool actionEnabled = true;

        public string Key { get; set; }
        public string Title { get; set; }
        public string Detail { get => detail; set => Set(ref detail, value); }
        public RowState State { get => state; set => Set(ref state, value); }
        public string ActionLabel
        {
            get => actionLabel;
            set { Set(ref actionLabel, value); Changed(nameof(ActionVisibility)); }
        }
        public bool ActionEnabled { get => actionEnabled; set => Set(ref actionEnabled, value); }
        public Visibility ActionVisibility => string.IsNullOrEmpty(actionLabel) ? Visibility.Collapsed : Visibility.Visible;

        public void Show(RowState newState, string newDetail, string action = null)
        {
            State = newState;
            Detail = newDetail;
            ActionLabel = action;
        }

        public event PropertyChangedEventHandler PropertyChanged;
        void Set<T>(ref T field, T value, [CallerMemberName] string name = null)
        {
            field = value;
            Changed(name);
        }
        void Changed(string name) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }

    public partial class MainWindow : Window
    {
        readonly Engine engine;
        readonly SetupRow rowGame = new SetupRow { Key = "game", Title = Strings.RowGame };
        readonly SetupRow rowLoader = new SetupRow { Key = "loader", Title = Strings.RowModLoader };
        readonly SetupRow rowFramework = new SetupRow { Key = "framework", Title = Strings.RowFramework };
        readonly SetupRow rowMod = new SetupRow { Key = "mod", Title = Strings.RowMod };
        readonly SetupRow rowBuild = new SetupRow { Key = "build", Title = Strings.RowGameBuild };
        readonly SetupRow rowXr = new SetupRow { Key = "xr", Title = Strings.RowXr };
        readonly SetupRow rowTune = new SetupRow { Key = "tune", Title = Strings.RowTune };
        readonly SetupRow rowSteam = new SetupRow { Key = "steam", Title = Strings.RowSteam };
        readonly CancellationTokenSource closing = new CancellationTokenSource();
        Snapshot snapshot;
        string bannerAction;
        bool busy;

        public MainWindow(Options options)
        {
            InitializeComponent();
            engine = new Engine(options.Config);
            if (options.GameRoot != null)
            {
                try { engine.SetGameRoot(options.GameRoot); }
                catch (LauncherException error) { Log.Warn(error.Message); }
            }

            Title = TitleText.Text = Strings.WindowTitle;
            HeaderTitle.Text = Strings.AppTitle;
            TabSetup.Content = Strings.TabSetup;
            TabLog.Content = Strings.TabLog;
            OpenLogButton.Content = Strings.OpenLogFolder;
            SupportZipButton.Content = Strings.SupportZip;
            RefreshButton.Content = Strings.Refresh;
            UninstallButton.Content = Strings.Uninstall;
            TestBuildsBox.Content = Strings.TestBuilds;
            TestBuildsBox.IsChecked = engine.State.IncludePrereleases;
            PlayFlatButton.Content = Strings.PlayFlat;
            PlayVrButton.Content = Strings.PlayVr;
            BannerButton.Content = Strings.UpdateNow;

            RowList.ItemsSource = new ObservableCollection<SetupRow> { rowGame, rowLoader, rowFramework, rowMod, rowBuild, rowXr, rowTune, rowSteam };
            foreach (var row in (ObservableCollection<SetupRow>)RowList.ItemsSource) row.Show(RowState.Busy, Strings.Checking);

            LoadLogTail();
            Log.Line += line => Dispatcher.BeginInvoke(new Action(() => AppendLog(line)));
            Loaded += async (s, e) =>
            {
                // Steam and SteamVR start the fixed copy of the launcher; keep
                // it as new as this one.
                if (engine.SteamStatus().Any) StableCopy.Ensure();
                SetBusy(true, "Checking for updates…");
                string automaticUpdateError = null;
                try
                {
                    if (await engine.UpdateAutomaticallyAsync(true, null, closing.Token))
                    {
                        busy = false;
                        Application.Current.Shutdown();
                        return;
                    }
                }
                catch (Exception error)
                {
                    automaticUpdateError = error.Message;
                    Log.Warn("Automatic update deferred: " + error.Message);
                }
                finally { SetBusy(false, null); }
                await RefreshAsync(false, false);
                if (automaticUpdateError != null) StatusText.Text = Strings.Offline + automaticUpdateError;
            };
            Closing += (s, e) =>
            {
                if (busy && MessageBox.Show("The launcher is still working. Close anyway?", Strings.WindowTitle,
                        MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes)
                    e.Cancel = true;
                else closing.Cancel();
            };
        }

        // ---- refresh and render ----------------------------------------------

        async Task RefreshAsync(bool checkUpdates, bool keepStatus)
        {
            SetBusy(true, keepStatus ? null : Strings.Checking);
            string updateError = null;
            try
            {
                var inspect = engine.InspectAsync();
                var check = checkUpdates ? engine.CheckUpdatesAsync(closing.Token) : null;
                snapshot = await inspect;
                if (check != null)
                {
                    try { await check; }
                    catch (LauncherException error) { updateError = error.Message; }
                    catch (Exception error) { updateError = error.Message; Log.Error(error.ToString()); }
                }
                Render(updateError);
                if (!keepStatus) StatusText.Text = updateError != null ? Strings.Offline + updateError : Strings.Ready;
            }
            catch (Exception error)
            {
                Log.Error(error.ToString());
                StatusText.Text = error.Message;
            }
            finally
            {
                SetBusy(false, null);
            }
        }

        void Render(string updateError)
        {
            var s = snapshot;
            var available = engine.Available;
            var installed = s.InstalledVersion;

            HeaderVersions.Text = $"Mod {(s.ModInstalled ? installed ?? "installed" : "not installed")}  ·  Launcher {LauncherConfig.CurrentVersion}";
            NotesSeparator.Text = available != null ? "  ·  " : "";
            NotesText.Text = available != null ? Strings.ReleaseNotes : "";

            if (!s.GameFound)
            {
                rowGame.Show(RowState.Error, Strings.GameNotFound, Strings.Change);
                foreach (var row in new[] { rowLoader, rowFramework, rowMod, rowBuild }) row.Show(RowState.Unknown, "—");
            }
            else
            {
                rowGame.Show(s.DarktideRunning ? RowState.Warn : RowState.Ok, s.DarktideRunning ? Strings.GameRunning : s.GameRoot, Strings.Change);

                if (!s.ModLoaderPresent || !s.PatchToolPresent)
                    rowLoader.Show(RowState.Warn, Strings.ModLoaderMissing, available != null ? Strings.Install : null);
                else if (!s.ModsEnabled)
                    rowLoader.Show(RowState.Warn, Strings.ModLoaderOff, "Switch on");
                else
                    rowLoader.Show(RowState.Ok, Strings.ModLoaderOn);

                rowFramework.Show(s.FrameworkPresent ? RowState.Ok : RowState.Warn,
                    s.FrameworkPresent ? Strings.FrameworkOk : Strings.FrameworkMissing,
                    s.FrameworkPresent || available == null ? null : Strings.Install);

                if (s.VortexManagesMod)
                    rowMod.Show(RowState.Ok, $"{installed ?? "Installed"}. {Strings.ModVortex}");
                else if (!s.ModInstalled)
                    rowMod.Show(RowState.Warn, available != null ? $"{Strings.ModMissing} Newest: {available.Version}." : Strings.ModMissing,
                        available != null ? Strings.Install : null);
                else if (engine.ModUpdateAvailable(s))
                    rowMod.Show(RowState.Warn, $"{installed} installed; {available.Version} is available.", $"Update to {available.Version}");
                else
                    rowMod.Show(RowState.Ok, available != null ? $"{installed ?? "Installed"} (newest)." : $"{installed ?? "Installed"}.");

                if (!s.ModInstalled || s.Status == null)
                    rowBuild.Show(RowState.Unknown, s.DarktideRunning ? Strings.GameRunning : Strings.GameBuildUnknown);
                else if (!s.Status.Ok)
                    rowBuild.Show(RowState.Unknown, s.Status.Message ?? Strings.GameBuildUnknown);
                else if (s.GameBuildSupported)
                    rowBuild.Show(RowState.Ok, Strings.GameBuildOk + (s.VrModeOn ? " VR mode is on." : " VR mode is off."));
                else if (s.ExeState == "unsupported")
                    rowBuild.Show(RowState.Error, Strings.GameBuildUnsupported);
                else
                    rowBuild.Show(RowState.Error, $"The mod couldn't check the game ({s.ExeState}). Reinstall the mod.");
            }

            var xr = s.Xr;
            if (xr.Runtime == "None") rowXr.Show(RowState.Warn, Strings.XrNone);
            else if (!xr.ManifestExists) rowXr.Show(RowState.Error, $"{xr.DisplayName}: {Strings.XrManifestMissing}");
            else if (xr.ServiceName == null) rowXr.Show(RowState.Warn, $"{xr.DisplayName}. {Strings.XrUntested}");
            else if (xr.ServiceRunning) rowXr.Show(RowState.Ok, $"{xr.DisplayName}: {Strings.XrRunning}" + (xr.Tested ? "" : " " + Strings.XrUntested));
            else rowXr.Show(RowState.Warn, $"{xr.DisplayName} isn't running. {Strings.XrStart}");

            ShowTuning();

            var steam = engine.SteamStatus();
            var lastLaunch = steam.LastLaunch != null ? $" Last Steam launch: {steam.LastLaunch}." : "";
            if (!steam.SteamFound) rowSteam.Show(RowState.Unknown, Strings.SteamNotFound);
            else if (steam.Complete) rowSteam.Show(RowState.Ok, Strings.SteamOn + lastLaunch, Strings.Remove);
            else if (steam.Any)
                rowSteam.Show(RowState.Warn, Strings.SteamPartial + (steam.LaunchOption ? "the Steam launch option is set" : "the Steam launch option isn't set") +
                    "; " + (steam.Library ? "Darktide VR is in the SteamVR library." : "Darktide VR isn't in the SteamVR library yet.") + lastLaunch, Strings.SetUp);
            else rowSteam.Show(RowState.Unknown, Strings.SteamOff, s.GameFound ? Strings.SetUp : null);

            if (engine.LauncherUpdateAvailable)
                ShowBanner($"Launcher {available.Manifest.Launcher.Version} is available.", "launcher");
            else if (engine.ModUpdateAvailable(s) && !s.VortexManagesMod)
                ShowBanner($"Darktide VR {available.Version} is available.", "mod");
            else
                ShowBanner(null, null);
        }

        void ShowBanner(string text, string action)
        {
            bannerAction = action;
            Banner.Visibility = text == null ? Visibility.Collapsed : Visibility.Visible;
            BannerText.Text = text ?? "";
        }

        void SetBusy(bool value, string status)
        {
            busy = value;
            if (status != null) StatusText.Text = status;
            Progress.Visibility = value ? Visibility.Visible : Visibility.Hidden;
            Progress.IsIndeterminate = true;
            var s = snapshot;
            var canPlay = !value && s != null && s.GameFound && !s.DarktideRunning;
            PlayFlatButton.IsEnabled = canPlay;
            PlayVrButton.IsEnabled = canPlay && (s.ModInstalled || engine.Available != null);
            RefreshButton.IsEnabled = UninstallButton.IsEnabled = BannerButton.IsEnabled = TestBuildsBox.IsEnabled = !value;
            UninstallButton.IsEnabled = !value && s != null && s.GameFound && (s.ModInstalled || engine.State.OwnedFiles.Count > 0);
            foreach (var row in new[] { rowGame, rowLoader, rowFramework, rowMod, rowSteam }) row.ActionEnabled = !value;
        }

        // ---- running an operation ----------------------------------------------

        async Task RunAsync(string working, Func<IProgress<double>, IProgress<string>, Task<string>> work)
        {
            if (busy) return;
            SetBusy(true, working);
            var progress = new Progress<double>(v =>
            {
                Progress.IsIndeterminate = false;
                Progress.Value = Math.Max(0, Math.Min(100, v * 100));
            });
            var step = new Progress<string>(text =>
            {
                StatusText.Text = text;
                Progress.IsIndeterminate = true;
            });
            string done;
            try
            {
                done = await work(progress, step) ?? Strings.Ready;
            }
            catch (LauncherException error)
            {
                Log.Error(error.Message);
                done = error.Message;
                MessageBox.Show(this, error.Message, Strings.WindowTitle, MessageBoxButton.OK, MessageBoxImage.Warning);
            }
            catch (UnauthorizedAccessException error)
            {
                Log.Error(error.ToString());
                done = error.Message;
                if (MessageBox.Show(this, Strings.WriteRefused, Strings.WindowTitle, MessageBoxButton.YesNo, MessageBoxImage.Warning) == MessageBoxResult.Yes)
                {
                    RestartElevated();
                    return;
                }
            }
            catch (Exception error)
            {
                Log.Error(error.ToString());
                done = "Something went wrong: " + error.Message + " (details in the Log tab)";
                MessageBox.Show(this, done, Strings.WindowTitle, MessageBoxButton.OK, MessageBoxImage.Error);
            }
            SetBusy(false, null);
            await RefreshAsync(false, true);
            StatusText.Text = done;
        }

        void RestartElevated()
        {
            try
            {
                Process.Start(new ProcessStartInfo(Paths.ExePath, "--updated") { UseShellExecute = true, Verb = "runas" });
                busy = false;
                Application.Current.Shutdown();
            }
            catch (System.ComponentModel.Win32Exception)
            {
                // The UAC prompt was declined.
            }
        }

        // ---- buttons -------------------------------------------------------------

        async void PlayVr_Click(object sender, RoutedEventArgs e)
        {
            await RunAsync("Getting ready…", async (progress, step) =>
            {
                await engine.PlayAsync(true, true, step, progress, closing.Token);
                return Strings.LaunchedVr;
            });
        }

        async void PlayFlat_Click(object sender, RoutedEventArgs e)
        {
            await RunAsync("Getting ready…", async (progress, step) =>
            {
                await engine.PlayAsync(false, true, step, progress, closing.Token);
                return Strings.LaunchedFlat;
            });
        }

        void ShowTuning()
        {
            var hardware = engine.Hardware;
            var plan = engine.Tuning;
            var lowRam = hardware.FreeRamBytes > 0 && hardware.FreeRamBytes < Engine.FreeRamWarning
                ? " " + string.Format(Strings.TuneLowRam, Engine.Gigabytes(hardware.FreeRamBytes)) : "";
            var state = lowRam.Length > 0 ? RowState.Warn : RowState.Ok;
            var card = $"{hardware.GpuName} ({Engine.Gigabytes(hardware.GpuMemoryBytes)} GB)";
            if (hardware.GpuName == null) rowTune.Show(RowState.Unknown, Strings.TuneNoCard + lowRam);
            else if (!engine.TuningOn) rowTune.Show(RowState.Unknown, Strings.TuneOff + lowRam, Strings.TuneOn);
            else if (plan.ChangesNothing) rowTune.Show(state, $"{card}: {Strings.TuneNothing}" + lowRam);
            else
            {
                var lowered = engine.State.TunedChanges.Select(PcTuning.Describe).Where(d => d != null).ToList();
                var settings = !engine.Tuned ? Strings.TunePending
                    : lowered.Count == 0 ? Strings.TuneWithin
                    : "Lowered: " + string.Join(", ", lowered) + ".";
                rowTune.Show(state, $"{card}: VR renders at most about {plan.EyeExtent} per eye. {settings} {Strings.TuneFlatUntouched}" + lowRam,
                    Strings.TuneUseOwn);
            }
        }

        async void RowAction_Click(object sender, RoutedEventArgs e)
        {
            var row = (SetupRow)((Button)sender).Tag;
            switch (row.Key)
            {
                case "game":
                    PickGameFolder();
                    await RefreshAsync(false, false);
                    break;
                case "loader" when row.ActionLabel == "Switch on":
                    await RunAsync("Switching mods on…", async (p, s) =>
                    {
                        await Dependencies.EnableModsAsync(engine.GameRoot);
                        return "Mods are switched on.";
                    });
                    break;
                case "loader":
                case "framework":
                    await RunAsync("Installing the mod loader and mod framework…", async (p, s) =>
                        $"Installed {await engine.InstallDependenciesAsync(p, closing.Token)} file(s).");
                    break;
                case "mod":
                    await InstallModAsync();
                    break;
                case "tune":
                    var on = row.ActionLabel == Strings.TuneOn;
                    await RunAsync(Strings.Working, (p, s) => Task.Run(() => engine.SetVrTuning(on)));
                    break;
                case "steam" when row.ActionLabel == Strings.Remove:
                    await RunAsync("Removing the Steam setup…", (p, s) => Task.FromResult(engine.RemoveSteam()));
                    break;
                case "steam":
                    await RunAsync("Setting up Steam…", (p, s) => Task.FromResult(engine.SetUpSteam()));
                    if (!engine.SteamStatus().LaunchOption &&
                        MessageBox.Show(this, Strings.CopyLaunchOption, Strings.WindowTitle, MessageBoxButton.YesNo, MessageBoxImage.Question) == MessageBoxResult.Yes)
                        Clipboard.SetText(SteamLaunchOptions.Expected);
                    break;
            }
        }

        async Task InstallModAsync()
        {
            await RunAsync("Downloading Darktide VR…", async (p, s) =>
            {
                var note = await engine.InstallModAsync(p, closing.Token);
                if (note != null) MessageBox.Show(this, note, Strings.WindowTitle, MessageBoxButton.OK, MessageBoxImage.Warning);
                return $"Darktide VR {engine.Available?.Version} is installed.";
            });
        }

        void PickGameFolder()
        {
            using (var dialog = new System.Windows.Forms.FolderBrowserDialog
            {
                Description = "Pick the Darktide game folder (the one with \"binaries\" and \"bundle\" inside).",
                ShowNewFolderButton = false,
                SelectedPath = engine.GameRoot ?? GameLocator.SteamRoot() ?? "",
            })
            {
                if (dialog.ShowDialog() != System.Windows.Forms.DialogResult.OK) return;
                try { engine.SetGameRoot(dialog.SelectedPath); }
                catch (LauncherException error) { MessageBox.Show(this, error.Message, Strings.WindowTitle, MessageBoxButton.OK, MessageBoxImage.Warning); }
            }
        }

        async void Banner_Click(object sender, RoutedEventArgs e)
        {
            if (bannerAction == "mod")
            {
                await InstallModAsync();
                return;
            }
            if (bannerAction != "launcher") return;
            var restarting = false;
            await RunAsync("Updating the launcher…", async (p, s) =>
            {
                restarting = await engine.SelfUpdateAsync(true, p, closing.Token);
                return restarting ? "Restarting…" : null;
            });
            if (restarting)
            {
                busy = false;
                Application.Current.Shutdown();
            }
        }

        async void Uninstall_Click(object sender, RoutedEventArgs e)
        {
            var dialog = new UninstallWindow { Owner = this };
            if (dialog.ShowDialog() != true) return;
            await RunAsync("Uninstalling…", (p, s) => engine.UninstallAsync(dialog.RemoveModLoader, dialog.RemoveData));
        }

        async void Refresh_Click(object sender, RoutedEventArgs e) => await RefreshAsync(true, false);

        async void TestBuilds_Click(object sender, RoutedEventArgs e)
        {
            engine.SetIncludePrereleases(TestBuildsBox.IsChecked == true);
            await RefreshAsync(true, false);
        }

        void Notes_Click(object sender, RoutedEventArgs e)
        {
            var url = engine.Available?.Release.HtmlUrl;
            if (url != null && url.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
                Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
        }

        void Tab_Checked(object sender, RoutedEventArgs e)
        {
            if (SetupView == null) return;
            var log = TabLog.IsChecked == true;
            SetupView.Visibility = log ? Visibility.Collapsed : Visibility.Visible;
            LogView.Visibility = log ? Visibility.Visible : Visibility.Collapsed;
            if (log) LogBox.ScrollToEnd();
        }

        void OpenLog_Click(object sender, RoutedEventArgs e)
        {
            Directory.CreateDirectory(Paths.LauncherRoot);
            Process.Start(new ProcessStartInfo("explorer.exe", $"\"{Paths.LauncherRoot}\"") { UseShellExecute = true });
        }

        async void SupportZip_Click(object sender, RoutedEventArgs e)
        {
            string path = null;
            await RunAsync("Collecting logs…", async (p, s) =>
            {
                path = await engine.CreateSupportZipAsync();
                return $"Support zip saved to your Desktop: {Path.GetFileName(path)}. It holds logs only, no settings or passwords.";
            });
            if (path != null && File.Exists(path))
                Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{path}\"") { UseShellExecute = true });
        }

        void Minimize_Click(object sender, RoutedEventArgs e) => WindowState = WindowState.Minimized;
        void Close_Click(object sender, RoutedEventArgs e) => Close();

        // ---- log tab -------------------------------------------------------------

        void LoadLogTail()
        {
            try
            {
                if (!File.Exists(Paths.LogPath)) return;
                using (var stream = new FileStream(Paths.LogPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
                using (var reader = new StreamReader(stream))
                {
                    var lines = reader.ReadToEnd().Split('\n');
                    LogBox.Text = string.Join("\n", lines.Skip(Math.Max(0, lines.Length - 300))).TrimEnd() + "\n";
                }
            }
            catch { }
        }

        void AppendLog(string line)
        {
            LogBox.AppendText(line + "\n");
            if (LogBox.Text.Length > 400_000) LogBox.Text = LogBox.Text.Substring(LogBox.Text.Length - 300_000);
            if (LogView.Visibility == Visibility.Visible) LogBox.ScrollToEnd();
        }
    }
}
