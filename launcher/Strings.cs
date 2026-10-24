namespace DarktideVR.Launcher
{
    // Every sentence the player reads, in one place, so a translation is a
    // copy of this file.
    public static class Strings
    {
        public const string AppTitle = "Darktide VR";
        public const string WindowTitle = "Darktide VR Launcher";

        public const string PlayVr = "Play in VR";
        public const string PlayFlat = "Play flat";
        public const string Refresh = "Refresh";
        public const string Uninstall = "Uninstall…";
        public const string Change = "Change…";
        public const string Install = "Install";
        public const string UpdateNow = "Update now";
        public const string TestBuilds = "Include test builds";
        public const string TabSetup = "Setup";
        public const string TabLog = "Log";
        public const string OpenLogFolder = "Open log folder";
        public const string SupportZip = "Create support zip";
        public const string ReleaseNotes = "Release notes";

        public const string Checking = "Checking…";
        public const string Ready = "Ready.";
        public const string Working = "Working…";

        public const string RowGame = "Darktide";
        public const string RowModLoader = "Mod loader";
        public const string RowFramework = "Mod framework";
        public const string RowMod = "Darktide VR mod";
        public const string RowGameBuild = "Game version";
        public const string RowXr = "VR runtime";

        public const string GameNotFound = "Not found. Pick the game folder (the one with \"binaries\" and \"bundle\" inside).";
        public const string ModLoaderMissing = "Not installed. Installed for you when you press Play in VR.";
        public const string ModLoaderOff = "Installed, but a game update switched mods off. Switched back on when you press Play.";
        public const string ModLoaderOn = "Installed and switched on.";
        public const string FrameworkMissing = "Not installed. Installed for you when you press Play in VR.";
        public const string FrameworkOk = "Installed.";
        public const string ModMissing = "Not installed. Installed for you when you press Play in VR.";
        public const string ModVortex = "Managed by Vortex: update it there.";
        public const string GameBuildUnknown = "Checked once the mod is installed.";
        public const string GameBuildOk = "Supported.";
        public const string GameBuildUnsupported =
            "Darktide was updated, and VR support for this version isn't out yet. Play flat still works. " +
            "The launcher checks for a fix each time it starts.";
        public const string GameRunning = "Darktide is running. Close it to change anything.";

        public const string XrNone = "No OpenXR runtime is set. Start Virtual Desktop (set to VDXR) or SteamVR before you play.";
        public const string XrManifestMissing = "The OpenXR runtime file is missing. Reinstall or repair your VR software.";
        public const string XrStart = "Start it before you press Play in VR.";
        public const string XrRunning = "Running.";
        public const string XrUntested = "This runtime hasn't been tested with Darktide VR; it may still work.";

        public const string RowSteam = "Start from Steam and VR headsets";
        public const string SteamNotFound = "Steam wasn't found.";
        public const string SteamOff =
            "Not set up. Starts Darktide in VR from Steam whenever a headset is connected (Steam Link, SteamVR, " +
            "Virtual Desktop) and flat otherwise, and adds it to your SteamVR library.";
        public const string SteamOn =
            "Darktide starts in VR from Steam when a headset is connected, flat otherwise, and is in your SteamVR library.";
        public const string SteamPartial = "Partly set up: ";
        public const string SetUp = "Set up";
        public const string Remove = "Remove";
        public const string CopyLaunchOption = "Copy Darktide's launch option to the clipboard, to paste in Steam yourself?";

        public const string NoRelease = "No release is available to the launcher yet.";
        public const string Offline = "Couldn't check for updates: ";

        public const string LaunchedVr =
            "Steam is starting Darktide. Press Play in the Darktide launcher; the headset takes over once the game window is up.";
        public const string LaunchedFlat = "Steam is starting Darktide in flat mode.";

        public const string UninstallTitle = "Uninstall Darktide VR";
        public const string UninstallBody =
            "This switches VR mode off (original game executable back, the mod's d3d12.dll removed, the mod taken out of " +
            "the load order) and deletes mods\\darktidevr. Your other mods aren't touched.";
        public const string UninstallModLoader = "Also remove the mod loader and framework, if this launcher installed them";
        public const string UninstallData = "Also delete the launcher's data and the mod's settings backups";
        public const string UninstallConfirm = "Uninstall";
        public const string Cancel = "Cancel";

        public const string AlreadyRunning = "The Darktide VR launcher is already open.";
        public const string WriteRefused =
            "Windows didn't allow changes in the game folder. Restart the launcher as administrator and try again?";
    }
}
