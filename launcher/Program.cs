using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using DarktideVR.Launcher.Core;

namespace DarktideVR.Launcher
{
    public sealed class Options
    {
        public string Command { get; set; }            // --cli <command>; null opens the window
        public string GameRoot { get; set; }
        public bool Launch { get; set; }
        public bool NoRestart { get; set; }
        public bool RemoveModLoader { get; set; }
        public bool RemoveData { get; set; }
        public bool? IncludePrereleases { get; set; }
        public bool Updated { get; set; }
        // Steam's launch option: everything after --steam-launch is the game command.
        public string[] SteamLaunchCommand { get; set; }
        // The SteamVR library tile.
        public bool VrLaunch { get; set; }
        public string Loader { get; set; }
        public string SteamLaunchMode { get; set; }
        public LauncherConfig Config { get; } = new LauncherConfig();

        // --api-base and --codeload-base exist for the loopback test server;
        // releases are trusted by signature, never by where they came from.
        public static Options Parse(string[] args)
        {
            var options = new Options();
            var queue = new Queue<string>(args);
            string Next(string name) => queue.Count > 0 ? queue.Dequeue() : throw new ArgumentException($"{name} needs a value");
            while (queue.Count > 0)
            {
                var arg = queue.Dequeue();
                switch (arg)
                {
                    case "--cli": options.Command = Next(arg); break;
                    case "--game-root": options.GameRoot = Next(arg); break;
                    case "--api-base": options.Config.ApiBase = Checked(Next(arg)); break;
                    case "--codeload-base": options.Config.CodeloadBase = Checked(Next(arg)); break;
                    case "--repo": options.Config.Repo = Next(arg); break;
                    case "--launch": options.Launch = true; break;
                    case "--no-restart": options.NoRestart = true; break;
                    case "--remove-mod-loader": options.RemoveModLoader = true; break;
                    case "--remove-data": options.RemoveData = true; break;
                    case "--include-prereleases": options.IncludePrereleases = true; break;
                    case "--stable-only": options.IncludePrereleases = false; break;
                    case "--updated": options.Updated = true; break;
                    case "--steam-launch":
                        options.SteamLaunchCommand = queue.ToArray();
                        queue.Clear();
                        break;
                    case "--vr-launch": options.VrLaunch = true; break;
                    case "--loader": options.Loader = Next(arg); break;
                    case "--steam-launch-mode": options.SteamLaunchMode = Next(arg); break;
                    case "--steam-root":
                        GameLocator.SteamRootOverride = System.IO.Path.GetFullPath(Next(arg));
                        SteamProcesses.ChecksDisabled = true;
                        break;
                    default: throw new ArgumentException($"Unknown argument: {arg}");
                }
            }
            return options;
        }

        static string Checked(string url)
        {
            Net.RequireAllowed(url);
            return url;
        }
    }

    public static class Program
    {
        [STAThread]
        public static int Main(string[] args)
        {
            Options options;
            try { options = Options.Parse(args); }
            catch (Exception error)
            {
                Cli.WriteError(error.Message);
                return 2;
            }

            // Started by Steam or SteamVR, or a headset probe: no window and no
            // single-instance wait (the window may be open and holding it).
            if (options.SteamLaunchCommand != null || options.VrLaunch || options.Command == "xr-probe")
            {
                try
                {
                    if (options.Command == "xr-probe") return Cli.Run(options);
                    return Task.Run(async () =>
                    {
                        var engine = new Engine(options.Config);
                        try
                        {
                            if (await engine.UpdateAutomaticallyAsync(false, null, CancellationToken.None))
                                return await SelfUpdater.RunReplacementAsync(args);
                        }
                        catch (Exception error) { Log.Warn("Automatic update deferred: " + error.Message); }
                        return options.VrLaunch
                            ? await SteamLaunch.VrLaunchAsync(options.Config)
                            : await SteamLaunch.RunAsync(options.SteamLaunchCommand, options.Config);
                    }).GetAwaiter().GetResult();
                }
                catch (Exception error)
                {
                    Log.Error("Launch from Steam failed: " + error);
                    return 1;
                }
            }

            // One launcher at a time: two would fight over the game folder.
            // A freshly self-updated copy waits for its predecessor to exit.
            using (var mutex = new Mutex(false, @"Local\DarktideVR.Launcher"))
            {
                var owned = false;
                try
                {
                    try { owned = mutex.WaitOne(options.Updated || options.Command != null ? TimeSpan.FromSeconds(30) : TimeSpan.Zero); }
                    catch (AbandonedMutexException) { owned = true; }
                    if (!owned)
                    {
                        if (options.Command != null)
                        {
                            Cli.WriteError(Strings.AlreadyRunning);
                            return 3;
                        }
                        System.Windows.MessageBox.Show(Strings.AlreadyRunning, Strings.WindowTitle);
                        return 3;
                    }
                    SelfUpdater.CleanupOld(wait: options.Command != null);
                    if (options.Command != null) return Cli.Run(options);

                    var app = new App();
                    app.InitializeComponent();
                    return app.Run(new MainWindow(options));
                }
                finally
                {
                    if (owned) mutex.ReleaseMutex();
                }
            }
        }
    }
}
