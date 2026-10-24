using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Tasks;
using Microsoft.Win32;

namespace DarktideVR.Launcher.Core
{
    public static class XrRuntimes
    {
        public const string SteamVrFile = "steamxr_win64.json";
        public const string VirtualDesktopFile = "virtualdesktop-openxr.json";

        public static string Active() => GameLocator.ReadMachine(@"SOFTWARE\Khronos\OpenXR\1", "ActiveRuntime");

        // Runtimes register themselves under AvailableRuntimes; SteamVR's
        // manifest also sits in its install folder.
        public static string Find(string fileName)
        {
            using (var hive = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64))
            using (var key = hive.OpenSubKey(@"SOFTWARE\Khronos\OpenXR\1\AvailableRuntimes"))
            {
                var match = key?.GetValueNames().FirstOrDefault(n =>
                    string.Equals(Path.GetFileName(n), fileName, StringComparison.OrdinalIgnoreCase) && File.Exists(n));
                if (match != null) return match;
            }
            var active = Active();
            if (active != null && string.Equals(Path.GetFileName(active), fileName, StringComparison.OrdinalIgnoreCase) && File.Exists(active))
                return active;
            if (fileName == SteamVrFile)
            {
                var steam = GameLocator.SteamRoot();
                var path = steam == null ? null : Path.Combine(steam, "steamapps", "common", "SteamVR", SteamVrFile);
                if (path != null && File.Exists(path)) return path;
            }
            return null;
        }

        public static bool IsFile(string manifest, string fileName) =>
            manifest != null && string.Equals(Path.GetFileName(manifest), fileName, StringComparison.OrdinalIgnoreCase);

        public static bool Same(string a, string b) =>
            a != null && b != null && string.Equals(Path.GetFullPath(a), Path.GetFullPath(b), StringComparison.OrdinalIgnoreCase);

        public static bool SteamVrRunning() => Running("vrserver");
        public static bool VirtualDesktopRunning() => Running("VirtualDesktop.Streamer");

        static bool Running(string name)
        {
            var processes = Process.GetProcessesByName(name);
            foreach (var process in processes) process.Dispose();
            return processes.Length > 0;
        }
    }

    public sealed class ProbeResult
    {
        public bool Ok { get; set; }
        public string RuntimeName { get; set; }
        public string Detail { get; set; }
    }

    // "Is a headset there right now?" asked the way the game will ask it: an
    // OpenXR instance and xrGetSystem(HMD) through the mod's own loader. No
    // session is created, so nothing appears in the headset. Each probe runs
    // in a child process with a timeout, so a runtime that hangs or crashes
    // can't take the launcher with it.
    public static class XrProbe
    {
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern IntPtr LoadLibraryEx(string path, IntPtr file, uint flags);
        [DllImport("kernel32.dll", CharSet = CharSet.Ansi, BestFitMapping = false)]
        static extern IntPtr GetProcAddress(IntPtr module, string name);
        const uint LoadWithAlteredSearchPath = 0x8;

        [UnmanagedFunctionPointer(CallingConvention.Winapi)] delegate int CreateInstance(IntPtr createInfo, out ulong instance);
        [UnmanagedFunctionPointer(CallingConvention.Winapi)] delegate int GetInstanceProperties(ulong instance, IntPtr properties);
        [UnmanagedFunctionPointer(CallingConvention.Winapi)] delegate int GetSystem(ulong instance, IntPtr getInfo, out ulong systemId);
        [UnmanagedFunctionPointer(CallingConvention.Winapi)] delegate int DestroyInstance(ulong instance);

        // openxr.h: XR_TYPE_INSTANCE_CREATE_INFO 3, XR_TYPE_SYSTEM_GET_INFO 4,
        // XR_TYPE_INSTANCE_PROPERTIES 32, XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY 1.
        // x64 layouts: XrInstanceCreateInfo 328 bytes (applicationInfo at 24),
        // XrInstanceProperties 152 (runtimeName at 24), XrSystemGetInfo 24.
        public static int RunInProcess(string loaderPath, Action<string> output)
        {
            var module = LoadLibraryEx(loaderPath, IntPtr.Zero, LoadWithAlteredSearchPath);
            if (module == IntPtr.Zero)
            {
                output($"xr_probe=no-loader error={Marshal.GetLastWin32Error()}");
                return 1;
            }
            var create = Function<CreateInstance>(module, "xrCreateInstance");
            var properties = Function<GetInstanceProperties>(module, "xrGetInstanceProperties");
            var getSystem = Function<GetSystem>(module, "xrGetSystem");
            var destroy = Function<DestroyInstance>(module, "xrDestroyInstance");

            var info = Zeroed(328);
            var props = Zeroed(152);
            var systemInfo = Zeroed(24);
            try
            {
                Marshal.WriteInt32(info, 0, 3);
                WriteAnsi(info, 24, "DarktideVR launcher probe", 128);
                Marshal.WriteInt32(info, 24 + 128, 1);
                WriteAnsi(info, 24 + 132, "darktidevr", 128);
                Marshal.WriteInt32(info, 24 + 260, 1);
                Marshal.WriteInt64(info, 24 + 264, 1L << 48); // XR_MAKE_VERSION(1, 0, 0)
                var result = create(info, out var instance);
                if (result != 0)
                {
                    output($"xr_probe=no-instance result={result}");
                    return 1;
                }
                try
                {
                    Marshal.WriteInt32(props, 0, 32);
                    if (properties(instance, props) == 0) output($"xr_runtime_name={Marshal.PtrToStringAnsi(props + 24)}");
                    Marshal.WriteInt32(systemInfo, 0, 4);
                    Marshal.WriteInt32(systemInfo, 16, 1);
                    result = getSystem(instance, systemInfo, out _);
                    // XR_ERROR_FORM_FACTOR_UNAVAILABLE (-35): the runtime is
                    // up but no headset is connected.
                    output(result == 0 ? "xr_probe=ok" : $"xr_probe=no-headset result={result}");
                    return result == 0 ? 0 : 1;
                }
                finally
                {
                    destroy(instance);
                }
            }
            finally
            {
                Marshal.FreeHGlobal(info);
                Marshal.FreeHGlobal(props);
                Marshal.FreeHGlobal(systemInfo);
            }
        }

        public static async Task<ProbeResult> ProbeAsync(string loaderPath, string runtimeManifest, TimeSpan timeout)
        {
            var start = new ProcessStartInfo(Paths.ExePath, $"--cli xr-probe --loader \"{loaderPath}\"")
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            };
            start.EnvironmentVariables["XR_RUNTIME_JSON"] = runtimeManifest;
            return await Task.Run(() =>
            {
                using (var process = Process.Start(start))
                {
                    var output = process.StandardOutput.ReadToEndAsync();
                    process.StandardError.ReadToEndAsync();
                    if (!process.WaitForExit((int)timeout.TotalMilliseconds))
                    {
                        try { process.Kill(); } catch { }
                        return new ProbeResult { Detail = "timed out" };
                    }
                    var lines = output.Result.Split('\n').Select(l => l.Trim()).ToList();
                    string Value(string key) => lines.FirstOrDefault(l => l.StartsWith(key + "=", StringComparison.Ordinal))?.Substring(key.Length + 1);
                    return new ProbeResult
                    {
                        Ok = process.ExitCode == 0 && Value("xr_probe") == "ok",
                        RuntimeName = Value("xr_runtime_name"),
                        Detail = Value("xr_probe") ?? $"exit {process.ExitCode}",
                    };
                }
            });
        }

        static T Function<T>(IntPtr module, string name) where T : class
        {
            var address = GetProcAddress(module, name);
            if (address == IntPtr.Zero) throw new LauncherException($"The OpenXR loader has no {name}.");
            return Marshal.GetDelegateForFunctionPointer(address, typeof(T)) as T;
        }

        static IntPtr Zeroed(int size)
        {
            var memory = Marshal.AllocHGlobal(size);
            Marshal.Copy(new byte[size], 0, memory, size);
            return memory;
        }

        static void WriteAnsi(IntPtr memory, int offset, string text, int capacity)
        {
            var bytes = Encoding.ASCII.GetBytes(text);
            Marshal.Copy(bytes, 0, memory + offset, Math.Min(bytes.Length, capacity - 1));
        }
    }

    // A one-shot instruction for the next Steam launch, written by Play in VR
    // or Play flat (and the SteamVR library entry) just before they start the
    // game through Steam. It expires after a few minutes.
    public static class NextLaunch
    {
        static readonly TimeSpan Lifetime = TimeSpan.FromMinutes(3);
        static string FilePath => Path.Combine(Paths.LauncherRoot, "next-launch.txt");

        public static void Write(string mode, string runtimeManifest = null)
        {
            Directory.CreateDirectory(Paths.LauncherRoot);
            File.WriteAllLines(FilePath, new[] { mode, DateTime.UtcNow.ToString("o"), runtimeManifest ?? "" });
        }

        public static (string Mode, string Runtime) Take()
        {
            try
            {
                if (!File.Exists(FilePath)) return (null, null);
                var lines = File.ReadAllLines(FilePath);
                File.Delete(FilePath);
                if (lines.Length < 2 || !DateTime.TryParse(lines[1], null, System.Globalization.DateTimeStyles.RoundtripKind, out var written)) return (null, null);
                if (DateTime.UtcNow - written.ToUniversalTime() > Lifetime) return (null, null);
                var runtime = lines.Length > 2 && lines[2].Length > 0 ? lines[2] : null;
                return (lines[0], runtime);
            }
            catch (Exception error)
            {
                Log.Warn($"next-launch.txt unreadable: {error.Message}");
                return (null, null);
            }
        }
    }

    public sealed class LaunchDecision
    {
        public bool Vr { get; set; }
        // Set when the game must use a runtime other than the system default
        // (XR_RUNTIME_JSON for the game process).
        public string RuntimeManifest { get; set; }
        public string Reason { get; set; }

        public static LaunchDecision Flat(string reason) => new LaunchDecision { Reason = reason };
        public static LaunchDecision VrOn(string runtime, string reason) => new LaunchDecision { Vr = true, RuntimeManifest = runtime, Reason = reason };
    }

    public static class LaunchDecider
    {
        // VR when a headset answers through the player's default OpenXR
        // runtime, a running SteamVR (Steam Link, a Steam Frame, any SteamVR
        // headset) or a running Virtual Desktop; flat otherwise, as on a PC
        // with no headset streaming. SteamVR is only asked while it already
        // runs: asking would start it on a desktop launch.
        public static async Task<LaunchDecision> DecideAsync(string root, LauncherState state)
        {
            var (requested, requestedRuntime) = NextLaunch.Take();
            if (requested == "flat") return LaunchDecision.Flat("Play flat was chosen in the launcher");
            if (requested == "vr" && requestedRuntime != null) return LaunchDecision.VrOn(requestedRuntime, "VR was chosen from SteamVR");
            if (requested != "vr" && state.SteamLaunchMode == "flat") return LaunchDecision.Flat("the launcher is set to always start flat");
            // A choice of VR still asks which runtime has the headset; with
            // no answer it falls back to the default runtime.
            var forced = requested == "vr" ? "Play in VR was chosen" : state.SteamLaunchMode == "vr" ? "the launcher is set to always start in VR" : null;
            var decision = await ProbeAsync(root);
            if (decision.Vr || forced == null) return decision;
            return LaunchDecision.VrOn(null, $"{forced} ({decision.Reason}; using the default runtime)");
        }

        static async Task<LaunchDecision> ProbeAsync(string root)
        {

            var active = XrRuntimes.Active();
            var steamVrRunning = XrRuntimes.SteamVrRunning();
            var candidates = new List<string>();
            void Add(string manifest)
            {
                if (manifest != null && File.Exists(manifest) && !candidates.Any(c => XrRuntimes.Same(c, manifest))) candidates.Add(manifest);
            }
            if (active != null && (!XrRuntimes.IsFile(active, XrRuntimes.SteamVrFile) || steamVrRunning)) Add(active);
            if (steamVrRunning) Add(XrRuntimes.Find(XrRuntimes.SteamVrFile));
            if (XrRuntimes.VirtualDesktopRunning()) Add(XrRuntimes.Find(XrRuntimes.VirtualDesktopFile));
            if (candidates.Count == 0) return LaunchDecision.Flat("no VR runtime is running");

            var loader = Path.Combine(ModPackage.ModDirectory(root), "bin", "openxr_loader.dll");
            if (!File.Exists(loader))
                return steamVrRunning
                    ? LaunchDecision.VrOn(Override(XrRuntimes.Find(XrRuntimes.SteamVrFile), active), "SteamVR is running")
                    : LaunchDecision.Flat("the mod's OpenXR loader is missing");

            foreach (var manifest in candidates)
            {
                var probe = await XrProbe.ProbeAsync(loader, manifest, TimeSpan.FromSeconds(12));
                Log.Info($"Headset check through {manifest}: {probe.Detail}{(probe.RuntimeName != null ? $" ({probe.RuntimeName})" : "")}");
                if (probe.Ok) return LaunchDecision.VrOn(Override(manifest, active), $"a headset answered through {probe.RuntimeName ?? Path.GetFileNameWithoutExtension(manifest)}");
            }
            return LaunchDecision.Flat("no headset answered");
        }

        static string Override(string manifest, string active) => XrRuntimes.Same(manifest, active) ? null : manifest;
    }
}
