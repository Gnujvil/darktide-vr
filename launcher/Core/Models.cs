using System.Collections.Generic;
using System.Runtime.Serialization;

namespace DarktideVR.Launcher.Core
{
    // GitHub REST: GET /repos/{owner}/{repo}/releases (fields the launcher reads).
    [DataContract]
    public sealed class GitHubRelease
    {
        [DataMember(Name = "tag_name")] public string TagName { get; set; }
        [DataMember(Name = "name")] public string Name { get; set; }
        [DataMember(Name = "draft")] public bool Draft { get; set; }
        [DataMember(Name = "prerelease")] public bool Prerelease { get; set; }
        [DataMember(Name = "published_at")] public string PublishedAt { get; set; }
        [DataMember(Name = "html_url")] public string HtmlUrl { get; set; }
        [DataMember(Name = "assets")] public List<GitHubAsset> Assets { get; set; }
    }

    [DataContract]
    public sealed class GitHubAsset
    {
        [DataMember(Name = "name")] public string Name { get; set; }
        [DataMember(Name = "size")] public long Size { get; set; }
        [DataMember(Name = "browser_download_url")] public string DownloadUrl { get; set; }
        // "sha256:<hex>", computed by GitHub at upload.
        [DataMember(Name = "digest")] public string Digest { get; set; }
    }

    // darktidevr-release.json: written and signed by
    // tools/release/new-launcher-release-manifest.ps1, uploaded beside the
    // mod zip and the launcher exe.
    [DataContract]
    public sealed class ReleaseManifest
    {
        public const string FileName = "darktidevr-release.json";
        public const string SignatureFileName = "darktidevr-release.json.sig";
        public const string Kind = "darktidevr-release";

        [DataMember(Name = "schema")] public int Schema { get; set; }
        [DataMember(Name = "kind")] public string ManifestKind { get; set; }
        [DataMember(Name = "version")] public string Version { get; set; }
        [DataMember(Name = "tag")] public string Tag { get; set; }
        [DataMember(Name = "created_utc")] public string CreatedUtc { get; set; }
        [DataMember(Name = "notes")] public string Notes { get; set; }
        [DataMember(Name = "mod")] public ReleaseFile Mod { get; set; }
        [DataMember(Name = "launcher")] public ReleaseFile Launcher { get; set; }
        [DataMember(Name = "min_launcher_version")] public string MinLauncherVersion { get; set; }
        [DataMember(Name = "mod_loader")] public Dependency ModLoader { get; set; }
        [DataMember(Name = "mod_framework")] public Dependency ModFramework { get; set; }
    }

    [DataContract]
    public sealed class ReleaseFile
    {
        [DataMember(Name = "asset")] public string Asset { get; set; }
        [DataMember(Name = "size")] public long Size { get; set; }
        [DataMember(Name = "sha256")] public string Sha256 { get; set; }
        [DataMember(Name = "version", EmitDefaultValue = false)] public string Version { get; set; }
    }

    // A dependency fetched from its own GitHub repository at a pinned commit;
    // every file it installs is listed with its hash.
    [DataContract]
    public sealed class Dependency
    {
        [DataMember(Name = "name")] public string Name { get; set; }
        [DataMember(Name = "repo")] public string Repo { get; set; }
        [DataMember(Name = "commit")] public string Commit { get; set; }
        [DataMember(Name = "files")] public List<DependencyFile> Files { get; set; }
    }

    [DataContract]
    public sealed class DependencyFile
    {
        // Path inside the repository archive, below its top folder.
        [DataMember(Name = "source")] public string Source { get; set; }
        // Path below the game folder.
        [DataMember(Name = "target")] public string Target { get; set; }
        [DataMember(Name = "sha256")] public string Sha256 { get; set; }
        // Written only when missing and never removed (the player's mod list).
        [DataMember(Name = "preserve", EmitDefaultValue = false)] public bool Preserve { get; set; }
    }

    // mods/darktidevr/package-manifest.json inside every release zip.
    [DataContract]
    public sealed class PackageManifest
    {
        [DataMember(Name = "release_version")] public string ReleaseVersion { get; set; }
        [DataMember(Name = "source_revision")] public string SourceRevision { get; set; }
        [DataMember(Name = "files")] public List<PackageFile> Files { get; set; }
    }

    [DataContract]
    public sealed class PackageFile
    {
        [DataMember(Name = "path")] public string Path { get; set; }
        [DataMember(Name = "bytes")] public long Bytes { get; set; }
        [DataMember(Name = "sha256")] public string Sha256 { get; set; }
    }

    // Vortex's record of what it deployed into the game folder.
    [DataContract]
    public sealed class VortexDeployment
    {
        [DataMember(Name = "files")] public List<VortexFile> Files { get; set; }
    }

    [DataContract]
    public sealed class VortexFile
    {
        [DataMember(Name = "relPath")] public string RelPath { get; set; }
    }

    [DataContract]
    public sealed class LauncherState
    {
        [DataMember(Name = "game_root")] public string GameRoot { get; set; }
        [DataMember(Name = "include_prereleases")] public bool IncludePrereleases { get; set; }
        [DataMember(Name = "installed_tag")] public string InstalledTag { get; set; }
        [DataMember(Name = "installed_mod_sha256")] public string InstalledModSha256 { get; set; }
        // Files the launcher wrote for the mod loader and framework, so
        // uninstall removes exactly those.
        [DataMember(Name = "owned_files")] public List<OwnedFile> OwnedFiles { get; set; } = new List<OwnedFile>();
        // Steam launches through the launcher: auto (VR when a headset
        // answers), vr or flat.
        [DataMember(Name = "steam_launch_mode")] public string SteamLaunchMode { get; set; }
        // Darktide's launch options before the launcher added its own.
        [DataMember(Name = "previous_launch_options")] public string PreviousLaunchOptions { get; set; }
        [DataMember(Name = "last_launch")] public string LastLaunch { get; set; }
        // "off" once the player chose their own VR settings; otherwise VR is
        // sized to this PC (Tuning.cs), once per graphics card and memory.
        [DataMember(Name = "vr_tuning")] public string VrTuning { get; set; }
        [DataMember(Name = "tuned_signature")] public string TunedSignature { get; set; }
        [DataMember(Name = "tuned_changes")] public List<TunedChange> TunedChanges { get; set; } = new List<TunedChange>();
    }

    [DataContract]
    public sealed class OwnedFile
    {
        [DataMember(Name = "path")] public string Path { get; set; }
        [DataMember(Name = "sha256")] public string Sha256 { get; set; }
    }
}
