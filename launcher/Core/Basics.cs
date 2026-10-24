using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.Serialization;
using System.Runtime.Serialization.Json;
using System.Security.Cryptography;
using System.Text;

namespace DarktideVR.Launcher.Core
{
    // A failure the player can act on; Message is shown as written.
    public class LauncherException : Exception
    {
        public LauncherException(string message, Exception inner = null) : base(message, inner) { }
    }

    // GitHub couldn't be reached or refused a request; worth retrying.
    public sealed class NetworkException : LauncherException
    {
        public NetworkException(string message, Exception inner = null) : base(message, inner) { }
    }

    public static class Paths
    {
        // The environment variable first: tests point LOCALAPPDATA at a scratch
        // folder, and the mode script the launcher runs reads the same variable.
        public static string LocalAppData => FromEnvironment("LOCALAPPDATA", Environment.SpecialFolder.LocalApplicationData);
        public static string RoamingAppData => FromEnvironment("APPDATA", Environment.SpecialFolder.ApplicationData);

        // Shared with darktidevr-mode.ps1 (pristine executable, settings profiles).
        public static string DataRoot => Path.Combine(LocalAppData, "DarktideVR");
        public static string LauncherRoot => Path.Combine(DataRoot, "launcher");
        public static string CacheDirectory => Path.Combine(LauncherRoot, "cache");
        public static string LogPath => Path.Combine(LauncherRoot, "launcher.log");
        public static string StatePath => Path.Combine(LauncherRoot, "state.json");

        public static string ExePath => Assembly.GetExecutingAssembly().Location;

        static string FromEnvironment(string name, Environment.SpecialFolder fallback)
        {
            var value = Environment.GetEnvironmentVariable(name);
            return string.IsNullOrEmpty(value) ? Environment.GetFolderPath(fallback) : value;
        }
    }

    public static class Log
    {
        static readonly object Gate = new object();
        public static event Action<string> Line;

        public static void Info(string message) => Write("info", message);
        public static void Warn(string message) => Write("warn", message);
        public static void Error(string message) => Write("error", message);

        static void Write(string level, string message)
        {
            var line = $"{DateTime.Now:yyyy-MM-dd HH:mm:ss} [{level}] {message}";
            lock (Gate)
            {
                try
                {
                    Directory.CreateDirectory(Paths.LauncherRoot);
                    var info = new FileInfo(Paths.LogPath);
                    // Keep one previous log; a player's support zip needs only recent runs.
                    if (info.Exists && info.Length > 2 * 1024 * 1024)
                    {
                        File.Copy(Paths.LogPath, Paths.LogPath + ".1", true);
                        File.Delete(Paths.LogPath);
                    }
                    File.AppendAllText(Paths.LogPath, line + Environment.NewLine, Encoding.UTF8);
                }
                catch { } // logging never stops an operation
            }
            Line?.Invoke(line);
        }
    }

    public static class Json
    {
        static readonly DataContractJsonSerializerSettings Settings = new DataContractJsonSerializerSettings
        {
            UseSimpleDictionaryFormat = true,
        };

        public static T Parse<T>(string text)
        {
            if (text == null) throw new ArgumentNullException(nameof(text));
            text = text.TrimStart('﻿');
            using (var stream = new MemoryStream(Encoding.UTF8.GetBytes(text)))
                return (T)new DataContractJsonSerializer(typeof(T), Settings).ReadObject(stream);
        }

        public static T Parse<T>(byte[] utf8) => Parse<T>(Encoding.UTF8.GetString(utf8));

        public static string Write<T>(T value)
        {
            using (var stream = new MemoryStream())
            {
                using (var writer = JsonReaderWriterFactory.CreateJsonWriter(stream, new UTF8Encoding(false), false, true, "  "))
                    new DataContractJsonSerializer(typeof(T), Settings).WriteObject(writer, value);
                return Encoding.UTF8.GetString(stream.ToArray());
            }
        }
    }

    public static class Hash
    {
        public static string Sha256(byte[] bytes)
        {
            using (var sha = SHA256.Create())
                return ToHex(sha.ComputeHash(bytes));
        }

        public static string Sha256File(string path)
        {
            using (var sha = SHA256.Create())
            using (var stream = File.OpenRead(path))
                return ToHex(sha.ComputeHash(stream));
        }

        public static bool IsSha256(string value) =>
            value != null && value.Length == 64 && value.All(Uri.IsHexDigit);

        public static bool Same(string a, string b) => string.Equals(a, b, StringComparison.OrdinalIgnoreCase);

        static string ToHex(byte[] bytes)
        {
            var text = new StringBuilder(bytes.Length * 2);
            foreach (var b in bytes) text.Append(b.ToString("x2", CultureInfo.InvariantCulture));
            return text.ToString();
        }
    }

    // Release versions as the project writes them: 0.3.0-alpha.2, with an
    // optional leading v. Prerelease parts compare as SemVer does.
    public sealed class ReleaseVersion : IComparable<ReleaseVersion>
    {
        readonly int[] core;
        readonly string[] prerelease;
        public string Text { get; }

        ReleaseVersion(string text, int[] core, string[] prerelease)
        {
            Text = text;
            this.core = core;
            this.prerelease = prerelease;
        }

        public static ReleaseVersion Parse(string text)
        {
            if (!TryParse(text, out var version)) throw new FormatException($"Not a release version: {text}");
            return version;
        }

        public static bool TryParse(string text, out ReleaseVersion version)
        {
            version = null;
            if (string.IsNullOrWhiteSpace(text)) return false;
            var trimmed = text.Trim();
            if (trimmed.StartsWith("v", StringComparison.OrdinalIgnoreCase)) trimmed = trimmed.Substring(1);
            var plus = trimmed.IndexOf('+');
            if (plus >= 0) trimmed = trimmed.Substring(0, plus);
            var dash = trimmed.IndexOf('-');
            var corePart = dash >= 0 ? trimmed.Substring(0, dash) : trimmed;
            var pre = dash >= 0 ? trimmed.Substring(dash + 1).Split('.') : new string[0];
            var pieces = corePart.Split('.');
            if (pieces.Length < 2 || pieces.Length > 4) return false;
            var numbers = new int[4];
            for (var i = 0; i < pieces.Length; i++)
                if (!int.TryParse(pieces[i], NumberStyles.None, CultureInfo.InvariantCulture, out numbers[i])) return false;
            if (pre.Any(p => p.Length == 0)) return false;
            version = new ReleaseVersion(trimmed, numbers, pre);
            return true;
        }

        public int CompareTo(ReleaseVersion other)
        {
            if (other == null) return 1;
            for (var i = 0; i < core.Length; i++)
            {
                var c = core[i].CompareTo(other.core[i]);
                if (c != 0) return c;
            }
            // A release ranks above any of its prereleases.
            if (prerelease.Length == 0 || other.prerelease.Length == 0)
                return other.prerelease.Length.CompareTo(prerelease.Length);
            for (var i = 0; i < Math.Min(prerelease.Length, other.prerelease.Length); i++)
            {
                var a = prerelease[i];
                var b = other.prerelease[i];
                var aNumeric = int.TryParse(a, NumberStyles.None, CultureInfo.InvariantCulture, out var an);
                var bNumeric = int.TryParse(b, NumberStyles.None, CultureInfo.InvariantCulture, out var bn);
                int c;
                if (aNumeric && bNumeric) c = an.CompareTo(bn);
                else if (aNumeric) c = -1;
                else if (bNumeric) c = 1;
                else c = string.CompareOrdinal(a, b);
                if (c != 0) return c;
            }
            return prerelease.Length.CompareTo(other.prerelease.Length);
        }

        public static bool IsNewer(string candidate, string current) =>
            TryParse(candidate, out var a) && (!TryParse(current, out var b) || a.CompareTo(b) > 0);

        public override string ToString() => Text;
    }

    public static class Files
    {
        // Written beside the destination and renamed over it, so an
        // interruption leaves the old file or the new one, never part of one.
        public static void WriteWhole(string path, byte[] bytes)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path));
            var partial = path + ".partial";
            File.WriteAllBytes(partial, bytes);
            if (File.Exists(path)) File.Replace(partial, path, null);
            else File.Move(partial, path);
        }

        public static void MoveDirectory(string from, string to)
        {
            Retry(() => Directory.Move(from, to), $"move {from} to {to}");
        }

        public static void DeleteDirectory(string path)
        {
            if (!Directory.Exists(path)) return;
            Retry(() =>
            {
                foreach (var file in Directory.EnumerateFiles(path, "*", SearchOption.AllDirectories))
                    File.SetAttributes(file, FileAttributes.Normal);
                Directory.Delete(path, true);
            }, $"delete {path}");
        }

        // Antivirus scanners and Explorer briefly hold freshly written files.
        public static void Retry(Action action, string what)
        {
            for (var attempt = 1; ; attempt++)
            {
                try
                {
                    action();
                    return;
                }
                catch (IOException) when (attempt < 10) { }
                catch (UnauthorizedAccessException) when (attempt < 3) { }
                System.Threading.Thread.Sleep(300 * attempt);
                Log.Info($"Retrying: {what} (attempt {attempt + 1})");
            }
        }

        // A relative path from an archive or manifest, checked so it can only
        // name a file inside root.
        public static string ResolveInside(string root, string relative)
        {
            if (string.IsNullOrEmpty(relative)) throw new LauncherException("An empty path in the download was refused.");
            var normal = relative.Replace('/', '\\');
            if (normal.StartsWith("\\") || normal.Contains(":") || Path.IsPathRooted(normal))
                throw new LauncherException($"A path outside the game folder was refused: {relative}");
            foreach (var segment in normal.Split('\\'))
                if (segment.Length == 0 || segment == "." || segment == "..")
                    throw new LauncherException($"An unsafe path was refused: {relative}");
            var rootFull = Path.GetFullPath(root).TrimEnd('\\') + "\\";
            var full = Path.GetFullPath(Path.Combine(rootFull, normal));
            if (!full.StartsWith(rootFull, StringComparison.OrdinalIgnoreCase))
                throw new LauncherException($"A path outside the game folder was refused: {relative}");
            return full;
        }

        public static void RemoveEmptyParents(string file, string stopAt)
        {
            var stop = Path.GetFullPath(stopAt).TrimEnd('\\');
            var directory = Path.GetDirectoryName(Path.GetFullPath(file));
            while (directory != null && directory.Length > stop.Length &&
                   directory.StartsWith(stop + "\\", StringComparison.OrdinalIgnoreCase))
            {
                if (!Directory.Exists(directory) || Directory.EnumerateFileSystemEntries(directory).Any()) return;
                Directory.Delete(directory);
                directory = Path.GetDirectoryName(directory);
            }
        }
    }
}
