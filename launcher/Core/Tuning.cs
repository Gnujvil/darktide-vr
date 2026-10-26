using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Runtime.Serialization;

namespace DarktideVR.Launcher.Core
{
    // The graphics card and memory, which decide what VR can afford here.
    public sealed class PcHardware
    {
        public string GpuName { get; private set; }
        public long GpuMemoryBytes { get; private set; }
        public long RamBytes { get; private set; }
        public long FreeRamBytes { get; private set; }

        // What a tuning was made for: another card or more memory tunes again.
        public string Signature => $"{GpuName}|{GpuMemoryBytes >> 20}|{RamBytes >> 30}";

        public static PcHardware Detect()
        {
            var hardware = new PcHardware();
            try { hardware.ReadGpu(); }
            catch (Exception error) { Log.Warn("Couldn't read the graphics card: " + error.Message); }
            var memory = new MemoryStatusEx { Length = (uint)Marshal.SizeOf<MemoryStatusEx>() };
            if (GlobalMemoryStatusEx(ref memory))
            {
                hardware.RamBytes = (long)memory.TotalPhys;
                hardware.FreeRamBytes = (long)memory.AvailPhys;
            }
            return hardware;
        }

        // DXGI through its vtables, which avoids declaring every interface
        // method: IUnknown::Release is slot 2, IDXGIFactory1::EnumAdapters1
        // slot 12 and IDXGIAdapter1::GetDesc1 slot 10. The card with the most
        // dedicated memory wins; software adapters don't count.
        void ReadGpu()
        {
            var iid = new Guid("770aae78-f26f-4dba-a829-253c83d1b387");
            Marshal.ThrowExceptionForHR(CreateDXGIFactory1(ref iid, out var factory));
            try
            {
                var enumAdapters = Method<EnumAdapters1>(factory, 12);
                for (uint index = 0; enumAdapters(factory, index, out var adapter) == 0; index++)
                {
                    try
                    {
                        if (Method<GetDesc1>(adapter, 10)(adapter, out var desc) != 0) continue;
                        var dedicated = (long)desc.DedicatedVideoMemory.ToUInt64();
                        if ((desc.Flags & AdapterFlagSoftware) != 0 || dedicated <= GpuMemoryBytes) continue;
                        GpuName = desc.Description?.Trim();
                        GpuMemoryBytes = dedicated;
                    }
                    finally { Method<Release>(adapter, 2)(adapter); }
                }
            }
            finally { Method<Release>(factory, 2)(factory); }
        }

        static T Method<T>(IntPtr com, int slot) where T : Delegate =>
            Marshal.GetDelegateForFunctionPointer<T>(Marshal.ReadIntPtr(Marshal.ReadIntPtr(com), slot * IntPtr.Size));

        const uint AdapterFlagSoftware = 2;

        [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int EnumAdapters1(IntPtr self, uint index, out IntPtr adapter);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int GetDesc1(IntPtr self, out AdapterDesc1 desc);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate uint Release(IntPtr self);

        [DllImport("dxgi.dll")] static extern int CreateDXGIFactory1(ref Guid riid, out IntPtr factory);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool GlobalMemoryStatusEx(ref MemoryStatusEx status);

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct AdapterDesc1
        {
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Description;
            public uint VendorId, DeviceId, SubSysId, Revision;
            public UIntPtr DedicatedVideoMemory, DedicatedSystemMemory, SharedSystemMemory;
            public uint LuidLow;
            public int LuidHigh;
            public uint Flags;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct MemoryStatusEx
        {
            public uint Length, MemoryLoad;
            public ulong TotalPhys, AvailPhys, TotalPageFile, AvailPageFile, TotalVirtual, AvailVirtual, AvailExtendedVirtual;
        }
    }

    // How far VR is lowered on a card of a given size: the eye resolution and
    // the three menu settings that cost the most memory in stereo. Bimo's
    // RTX 4070 (12 GB) ran out of memory at SteamVR's 2528x2704 per eye with
    // extreme shadows, high reflections and extreme fog; 16 GB cards keep
    // everything. Nothing is ever raised.
    public sealed class TuningPlan
    {
        public string Size { get; private set; }
        // Pixels per eye the viewer keeps at most; 0: the runtime's resolution.
        public long EyePixelCap { get; private set; }
        public string EyeExtent { get; private set; }
        // Menu setting -> the highest choice it keeps.
        public Dictionary<string, string> Caps { get; } = new Dictionary<string, string>();
        public bool ChangesNothing => EyePixelCap == 0 && Caps.Count == 0;

        public static TuningPlan For(long gpuMemoryBytes)
        {
            var megabytes = gpuMemoryBytes >> 20;
            if (megabytes <= 0) return new TuningPlan { Size = "unknown" };
            if (megabytes >= 15000) return new TuningPlan { Size = "16 GB or more" };
            if (megabytes >= 11000) return Make("12 GB", 2112, 2304, "off", "high", "high");
            if (megabytes >= 7000) return Make("8 GB", 1824, 1984, "off", "medium", "high");
            return Make("6 GB or less", 1632, 1776, "off", "medium", "medium");
        }

        static TuningPlan Make(string size, int width, int height, string ssr, string light, string fog)
        {
            var plan = new TuningPlan { Size = size, EyePixelCap = (long)width * height, EyeExtent = $"{width}×{height}" };
            plan.Caps["ssr_quality"] = ssr;
            plan.Caps["light_quality"] = light;
            plan.Caps["volumetric_fog_quality"] = fog;
            return plan;
        }
    }

    // A menu choice the tuning lowered, kept so "Use my own settings" can put
    // it back.
    [DataContract]
    public sealed class TunedChange
    {
        [DataMember(Name = "key")] public string Key { get; set; }
        [DataMember(Name = "from")] public string From { get; set; }
        [DataMember(Name = "to")] public string To { get; set; }
    }

    // The game's own menu options (scripts/settings/options/render_settings),
    // lowest first, each with the render values the menu writes when it is
    // chosen. Lowering a choice writes exactly what the menu would.
    public static class GraphicsOptions
    {
        static readonly int[] Map2048 = { 2048, 2048 };

        static readonly Dictionary<string, (string Choice, Dictionary<string, object> Values)[]> options =
            new Dictionary<string, (string, Dictionary<string, object>)[]>
            {
                ["ssr_quality"] = new[]
                {
                    ("off", Ssr(false, false)),
                    ("medium", Ssr(true, false)),
                    ("high", Ssr(true, true)),
                },
                ["light_quality"] = new[]
                {
                    ("low", Light("\"low\"", "\"low\"", false, new[] { 4, 4 }, 512)),
                    ("medium", Light("\"low\"", "\"medium\"", true, Map2048, 1024)),
                    ("high", Light("\"high\"", "\"high\"", true, Map2048, 2048)),
                    ("extreme", Light("\"high\"", "\"high\"", true, Map2048, 4096)),
                },
                ["volumetric_fog_quality"] = new[]
                {
                    ("low", Fog(false, false, false, false, "0.875", 80, 64, 96)),
                    ("medium", Fog(true, true, false, true, "0.625", 96, 80, 128)),
                    ("high", Fog(true, true, false, true, "0", 128, 96, 160)),
                    ("extreme", Fog(true, true, true, true, "-0.875", 144, 112, 196)),
                },
            };

        // -1 when the setting or the choice isn't one of these.
        public static int Rank(string key, string choice) =>
            options.TryGetValue(key, out var list) ? Array.FindIndex(list, o => o.Choice == choice) : -1;

        public static IReadOnlyDictionary<string, object> Values(string key, string choice) =>
            options[key].First(o => o.Choice == choice).Values;

        static string Flag(bool value) => value ? "true" : "false";

        static Dictionary<string, object> Ssr(bool enabled, bool high) => new Dictionary<string, object>
        {
            ["ssr_enabled"] = Flag(enabled),
            ["ssr_high_quality"] = Flag(high),
        };

        static Dictionary<string, object> Light(string localFilter, string sunFilter, bool sun, int[] sunMap, int atlas) =>
            new Dictionary<string, object>
            {
                ["local_lights_max_dynamic_shadow_distance"] = "50",
                ["local_lights_max_non_shadow_casting_distance"] = "0",
                ["local_lights_max_static_shadow_distance"] = "100",
                ["local_lights_shadow_map_filter_quality"] = localFilter,
                ["local_lights_shadows_enabled"] = "true",
                ["static_sun_shadows"] = "true",
                ["sun_shadow_map_filter_quality"] = sunFilter,
                ["sun_shadows"] = Flag(sun),
                ["sun_shadow_map_size"] = sunMap,
                ["static_sun_shadow_map_size"] = Map2048,
                ["local_lights_shadow_atlas_size"] = new[] { atlas, atlas },
            };

        static Dictionary<string, object> Fog(bool shafts, bool highExtrapolation, bool volumetricShadows, bool localLights,
            string reprojection, int x, int y, int z) =>
            new Dictionary<string, object>
            {
                ["light_shafts_enabled"] = Flag(shafts),
                ["volumetric_extrapolation_high_quality"] = Flag(highExtrapolation),
                ["volumetric_extrapolation_volumetric_shadows"] = Flag(volumetricShadows),
                ["volumetric_lighting_local_lights"] = Flag(localLights),
                ["volumetric_reprojection_amount"] = reprojection,
                ["volumetric_volumes_enabled"] = "true",
                ["volumetric_data_size"] = new[] { x, y, z },
            };
    }

    // user_settings.config: one "name = {" block per section closed by "}",
    // "\tkey = value" lines, and arrays written one number per line between
    // "\tkey = [" and "\t]".
    public sealed class SettingsFile
    {
        readonly List<string> lines;
        readonly string newline;

        public SettingsFile(string text)
        {
            newline = text.Contains("\r\n") ? "\r\n" : "\n";
            lines = text.Replace("\r\n", "\n").Split('\n').ToList();
        }

        public override string ToString() => string.Join(newline, lines);

        // The header and closing lines of a top-level block, or -1.
        (int Header, int Close) Block(string name)
        {
            var header = lines.FindIndex(line => line == name + " = {");
            var close = header < 0 ? -1 : lines.FindIndex(header + 1, line => line == "}");
            return close < 0 ? (-1, -1) : (header, close);
        }

        public string Get(string block, string key)
        {
            var (header, close) = Block(block);
            var prefix = "\t" + key + " = ";
            for (var i = header + 1; header >= 0 && i < close; i++)
                if (lines[i].StartsWith(prefix, StringComparison.Ordinal))
                    return lines[i].Substring(prefix.Length).Trim().Trim('"');
            return null;
        }

        // A scalar as it is written ("true", "0.875", "\"high\"") or an int[].
        public void Set(string block, string key, object value)
        {
            var (header, close) = Block(block);
            if (header < 0) throw new InvalidDataException($"user_settings.config has no {block} block.");
            var replacement = value is int[] numbers
                ? new[] { $"\t{key} = [" }.Concat(numbers.Select(n => "\t\t" + n.ToString(CultureInfo.InvariantCulture))).Concat(new[] { "\t]" }).ToList()
                : new List<string> { $"\t{key} = {value}" };
            var prefix = "\t" + key + " = ";
            for (var i = header + 1; i < close; i++)
            {
                if (!lines[i].StartsWith(prefix, StringComparison.Ordinal)) continue;
                var last = i;
                if (lines[i].TrimEnd().EndsWith("["))
                {
                    last = lines.FindIndex(i + 1, line => line == "\t]");
                    if (last < 0 || last > close) throw new InvalidDataException($"user_settings.config: {key} has no end.");
                }
                lines.RemoveRange(i, last - i + 1);
                lines.InsertRange(i, replacement);
                return;
            }
            lines.InsertRange(close, replacement);
        }
    }

    public static class PcTuning
    {
        // Read by the viewer from beside the mod (src/xr/main.cpp).
        public const string CapFlagName = "darktidevr_eye_pixel_cap.flag";
        const string Master = "master_render_settings";

        // Lowers each menu choice above its cap to the cap. Returns what changed.
        public static List<TunedChange> Lower(SettingsFile settings, TuningPlan plan)
        {
            var changes = new List<TunedChange>();
            foreach (var cap in plan.Caps)
            {
                var current = settings.Get(Master, cap.Key);
                var have = GraphicsOptions.Rank(cap.Key, current);
                if (have < 0 || have <= GraphicsOptions.Rank(cap.Key, cap.Value)) continue;
                Choose(settings, cap.Key, cap.Value);
                changes.Add(new TunedChange { Key = cap.Key, From = current, To = cap.Value });
            }
            // As the menu does once any single setting is edited.
            var preset = settings.Get(Master, "graphics_quality");
            if (changes.Count > 0 && preset != null && preset != "custom")
            {
                settings.Set(Master, "graphics_quality", "\"custom\"");
                changes.Add(new TunedChange { Key = "graphics_quality", From = preset, To = "custom" });
            }
            return changes;
        }

        // Puts lowered choices back, except where the player changed them since.
        public static int Restore(SettingsFile settings, IEnumerable<TunedChange> changes)
        {
            var restored = 0;
            foreach (var change in changes)
            {
                if (settings.Get(Master, change.Key) != change.To) continue;
                if (change.Key == "graphics_quality") settings.Set(Master, change.Key, "\"" + change.From + "\"");
                else if (GraphicsOptions.Rank(change.Key, change.From) >= 0) Choose(settings, change.Key, change.From);
                else continue;
                restored++;
            }
            return restored;
        }

        static void Choose(SettingsFile settings, string key, string choice)
        {
            settings.Set(Master, key, "\"" + choice + "\"");
            foreach (var value in GraphicsOptions.Values(key, choice)) settings.Set("render_settings", value.Key, value.Value);
        }

        // Keeps the first "from" of a setting tuned more than once, so undoing
        // returns to the player's own choice.
        public static List<TunedChange> Merge(List<TunedChange> earlier, IEnumerable<TunedChange> later)
        {
            var merged = new List<TunedChange>(earlier ?? new List<TunedChange>());
            foreach (var change in later)
            {
                var known = merged.FirstOrDefault(c => c.Key == change.Key);
                if (known != null) known.To = change.To;
                else merged.Add(change);
            }
            return merged;
        }

        public static string Describe(TunedChange change)
        {
            switch (change.Key)
            {
                case "ssr_quality": return $"reflections {change.From} → {change.To}";
                case "light_quality": return $"shadows {change.From} → {change.To}";
                case "volumetric_fog_quality": return $"fog {change.From} → {change.To}";
                default: return null;
            }
        }
    }
}
