using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace DarktideVR.Launcher.Core
{
    public sealed class LauncherConfig
    {
        public const int SteamAppId = 1361210;

        public string Repo { get; set; } = "Gnujvil/darktide-vr";
        public string ApiBase { get; set; } = "https://api.github.com";
        public string CodeloadBase { get; set; } = "https://codeload.github.com";

        public static string CurrentVersion
        {
            get
            {
                var assembly = Assembly.GetExecutingAssembly();
                var informational = assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion;
                return string.IsNullOrEmpty(informational) ? assembly.GetName().Version.ToString(3) : informational;
            }
        }
    }

    public sealed class Net
    {
        readonly HttpClient http;

        public Net()
        {
            ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12 | (SecurityProtocolType)12288; // TLS 1.3
            http = new HttpClient(new HttpClientHandler
            {
                AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate,
            })
            { Timeout = TimeSpan.FromMinutes(15) };
            http.DefaultRequestHeaders.UserAgent.ParseAdd("DarktideVR-Launcher/" + LauncherConfig.CurrentVersion);
        }

        public async Task<string> GetApiAsync(string url, CancellationToken cancel)
        {
            RequireAllowed(url);
            using (var request = new HttpRequestMessage(HttpMethod.Get, url))
            {
                request.Headers.Accept.ParseAdd("application/vnd.github+json");
                request.Headers.Add("X-GitHub-Api-Version", "2022-11-28");
                using (var response = await Send(request, cancel))
                {
                    if ((int)response.StatusCode == 403 || (int)response.StatusCode == 429)
                    {
                        if (response.Headers.TryGetValues("X-RateLimit-Remaining", out var remaining) && remaining.FirstOrDefault() == "0")
                            throw new NetworkException("GitHub allows 60 update checks an hour from one address, and that limit is used up. Try again in an hour.");
                    }
                    if (!response.IsSuccessStatusCode)
                        throw new NetworkException($"GitHub answered {(int)response.StatusCode} {response.ReasonPhrase} for {url}.");
                    return await response.Content.ReadAsStringAsync();
                }
            }
        }

        // The whole body in memory, refused past maxBytes; when sha256 is given
        // the bytes must match it.
        public async Task<byte[]> DownloadAsync(string url, long maxBytes, string sha256, IProgress<double> progress, CancellationToken cancel)
        {
            RequireAllowed(url);
            using (var request = new HttpRequestMessage(HttpMethod.Get, url))
            using (var response = await Send(request, cancel, HttpCompletionOption.ResponseHeadersRead))
            {
                if (!response.IsSuccessStatusCode)
                    throw new NetworkException($"The download failed: {(int)response.StatusCode} {response.ReasonPhrase} ({url}).");
                var total = response.Content.Headers.ContentLength ?? 0;
                if (total > maxBytes) throw new LauncherException($"The download is larger than expected and was refused ({url}).");
                using (var stream = await response.Content.ReadAsStreamAsync())
                using (var buffer = new MemoryStream())
                {
                    var chunk = new byte[81920];
                    int read;
                    while ((read = await stream.ReadAsync(chunk, 0, chunk.Length, cancel)) > 0)
                    {
                        buffer.Write(chunk, 0, read);
                        if (buffer.Length > maxBytes) throw new LauncherException($"The download is larger than expected and was refused ({url}).");
                        if (total > 0) progress?.Report((double)buffer.Length / total);
                    }
                    var bytes = buffer.ToArray();
                    if (sha256 != null && !Hash.Same(Hash.Sha256(bytes), sha256))
                        throw new LauncherException($"A download did not match its published checksum and was discarded ({Path.GetFileName(new Uri(url).AbsolutePath)}). Try again; if it keeps happening, tell the mod author.");
                    return bytes;
                }
            }
        }

        async Task<HttpResponseMessage> Send(HttpRequestMessage request, CancellationToken cancel, HttpCompletionOption option = HttpCompletionOption.ResponseContentRead)
        {
            try
            {
                return await http.SendAsync(request, option, cancel);
            }
            catch (HttpRequestException error)
            {
                throw new NetworkException("Couldn't reach GitHub. Check your internet connection and try again.", error);
            }
            catch (TaskCanceledException error) when (!cancel.IsCancellationRequested)
            {
                throw new NetworkException("GitHub didn't answer in time. Check your internet connection and try again.", error);
            }
        }

        // HTTPS only; plain HTTP is accepted for the loopback test server.
        public static void RequireAllowed(string url)
        {
            if (!Uri.TryCreate(url, UriKind.Absolute, out var uri)) throw new LauncherException($"Not a web address: {url}");
            if (uri.Scheme == Uri.UriSchemeHttps) return;
            if (uri.Scheme == Uri.UriSchemeHttp && uri.IsLoopback) return;
            throw new LauncherException($"Only HTTPS downloads are allowed: {url}");
        }
    }

    // Release manifests are signed with ECDSA P-256 (SHA-256, 64-byte r||s,
    // base64). The public keys are embedded at build time from
    // launcher/release-signing-key.pub: one base64 X||Y per line.
    public static class ReleaseSignature
    {
        static List<byte[]> keys;

        public static IReadOnlyList<byte[]> TrustedKeys => keys ?? (keys = LoadKeys());

        public static bool HasKeys => TrustedKeys.Count > 0;

        public static bool Verify(byte[] data, string signatureText)
        {
            byte[] signature;
            try { signature = Convert.FromBase64String((signatureText ?? "").Trim()); }
            catch (FormatException) { return false; }
            if (signature.Length != 64) return false;
            foreach (var key in TrustedKeys)
            {
                using (var ecdsa = ECDsa.Create(PublicKey(key)))
                    if (ecdsa.VerifyData(data, signature, HashAlgorithmName.SHA256)) return true;
            }
            return false;
        }

        static ECParameters PublicKey(byte[] xy) => new ECParameters
        {
            Curve = ECCurve.NamedCurves.nistP256,
            Q = new ECPoint { X = xy.Take(32).ToArray(), Y = xy.Skip(32).ToArray() },
        };

        static List<byte[]> LoadKeys()
        {
            var result = new List<byte[]>();
            using (var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("release-signing-key.pub"))
            {
                if (stream == null) return result;
                using (var reader = new StreamReader(stream, Encoding.ASCII))
                {
                    string line;
                    while ((line = reader.ReadLine()) != null)
                    {
                        line = line.Trim();
                        if (line.Length == 0 || line.StartsWith("#")) continue;
                        var key = Convert.FromBase64String(line);
                        if (key.Length != 64) throw new InvalidDataException("A release key must be 64 bytes (P-256 X||Y).");
                        result.Add(key);
                    }
                }
            }
            return result;
        }
    }

    public sealed class AvailableRelease
    {
        public GitHubRelease Release { get; set; }
        public ReleaseManifest Manifest { get; set; }
        public GitHubAsset ModAsset { get; set; }
        public GitHubAsset LauncherAsset { get; set; }
        public string Version => Manifest.Version;
    }

    public sealed class UpdateCheck
    {
        public AvailableRelease Best { get; set; }
        public int ReleasesSeen { get; set; }
        public List<string> Skipped { get; } = new List<string>();
    }

    public sealed class ReleaseFeed
    {
        const long ManifestLimit = 1024 * 1024;
        readonly LauncherConfig config;
        readonly Net net;

        public ReleaseFeed(LauncherConfig config, Net net)
        {
            this.config = config;
            this.net = net;
        }

        // The newest release with a manifest signed by a trusted key. Never
        // the raw branch: only what the maintainer built, tested and signed.
        public async Task<UpdateCheck> CheckAsync(bool includePrereleases, CancellationToken cancel)
        {
            if (!ReleaseSignature.HasKeys)
                throw new LauncherException("This launcher build has no release key, so it can't trust any update.");
            var url = $"{config.ApiBase.TrimEnd('/')}/repos/{config.Repo}/releases?per_page=30";
            var releases = Json.Parse<List<GitHubRelease>>(await net.GetApiAsync(url, cancel)) ?? new List<GitHubRelease>();
            var check = new UpdateCheck { ReleasesSeen = releases.Count };
            var candidates = new List<AvailableRelease>();
            NetworkException networkError = null;
            foreach (var release in releases)
            {
                if (release.Draft) continue;
                if (release.Prerelease && !includePrereleases)
                {
                    check.Skipped.Add($"{release.TagName}: test build (pre-release)");
                    continue;
                }
                try
                {
                    var available = await ReadRelease(release, cancel);
                    if (available != null) candidates.Add(available);
                    else check.Skipped.Add($"{release.TagName}: no launcher manifest (published before the launcher)");
                }
                catch (LauncherException error)
                {
                    check.Skipped.Add($"{release.TagName}: {error.Message}");
                    Log.Warn($"Release {release.TagName} refused: {error.Message}");
                    if (error is NetworkException network && networkError == null) networkError = network;
                }
            }
            check.Best = candidates
                .OrderByDescending(c => ReleaseVersion.Parse(c.Version))
                .FirstOrDefault();
            // Nothing usable because downloads failed is a connection problem
            // to report, not "no release".
            if (check.Best == null && networkError != null) throw networkError;
            return check;
        }

        async Task<AvailableRelease> ReadRelease(GitHubRelease release, CancellationToken cancel)
        {
            var assets = release.Assets ?? new List<GitHubAsset>();
            var manifestAsset = Find(assets, ReleaseManifest.FileName);
            var signatureAsset = Find(assets, ReleaseManifest.SignatureFileName);
            if (manifestAsset == null || signatureAsset == null) return null;

            var manifestBytes = await net.DownloadAsync(manifestAsset.DownloadUrl, ManifestLimit, DigestHex(manifestAsset), null, cancel);
            var signatureBytes = await net.DownloadAsync(signatureAsset.DownloadUrl, 4096, DigestHex(signatureAsset), null, cancel);
            if (!ReleaseSignature.Verify(manifestBytes, Encoding.ASCII.GetString(signatureBytes)))
                throw new LauncherException("its signature is not from the mod author's key");

            ReleaseManifest manifest;
            try { manifest = Json.Parse<ReleaseManifest>(manifestBytes); }
            catch (Exception error) { throw new LauncherException("its manifest could not be read", error); }
            if (manifest.Schema != 1 || manifest.ManifestKind != ReleaseManifest.Kind)
                throw new LauncherException($"manifest schema {manifest.Schema} needs a newer launcher");
            // A signed manifest is valid only on its own tag: an older release
            // re-uploaded under a new tag is refused.
            if (!string.Equals(manifest.Tag, release.TagName, StringComparison.Ordinal))
                throw new LauncherException($"its manifest belongs to {manifest.Tag}");
            if (!ReleaseVersion.TryParse(manifest.Version, out _))
                throw new LauncherException($"its version {manifest.Version} can't be read");

            var available = new AvailableRelease { Release = release, Manifest = manifest };
            available.ModAsset = CheckAsset(assets, manifest.Mod, "mod package");
            if (manifest.Launcher != null) available.LauncherAsset = CheckAsset(assets, manifest.Launcher, "launcher");
            CheckDependency(manifest.ModLoader, "mod loader");
            CheckDependency(manifest.ModFramework, "mod framework");
            return available;
        }

        static GitHubAsset CheckAsset(List<GitHubAsset> assets, ReleaseFile file, string what)
        {
            if (file == null || string.IsNullOrEmpty(file.Asset) || !Hash.IsSha256(file.Sha256))
                throw new LauncherException($"its manifest has no valid {what} entry");
            var asset = Find(assets, file.Asset);
            if (asset == null) throw new LauncherException($"its {what} ({file.Asset}) is missing");
            if (asset.Size != file.Size) throw new LauncherException($"its {what} has the wrong size");
            var digest = DigestHex(asset);
            if (digest != null && !Hash.Same(digest, file.Sha256))
                throw new LauncherException($"its {what} doesn't match the signed checksum");
            return asset;
        }

        static void CheckDependency(Dependency dependency, string what)
        {
            if (dependency == null) throw new LauncherException($"its manifest doesn't pin the {what}");
            if (string.IsNullOrEmpty(dependency.Repo) || dependency.Commit == null || dependency.Commit.Length != 40 ||
                dependency.Files == null || dependency.Files.Count == 0 ||
                dependency.Files.Any(f => !Hash.IsSha256(f.Sha256) || string.IsNullOrEmpty(f.Source) || string.IsNullOrEmpty(f.Target)))
                throw new LauncherException($"its {what} entry is incomplete");
        }

        static GitHubAsset Find(List<GitHubAsset> assets, string name) =>
            assets.FirstOrDefault(a => string.Equals(a.Name, name, StringComparison.Ordinal));

        // GitHub's own checksum of an uploaded asset, when it reports one.
        static string DigestHex(GitHubAsset asset)
        {
            var digest = asset.Digest;
            if (string.IsNullOrEmpty(digest) || !digest.StartsWith("sha256:", StringComparison.OrdinalIgnoreCase)) return null;
            var hex = digest.Substring(7);
            return Hash.IsSha256(hex) ? hex : null;
        }

        public static string AssetDigest(GitHubAsset asset) => DigestHex(asset);
    }
}
