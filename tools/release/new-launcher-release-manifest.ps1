[CmdletBinding()]
param(
    # The runtime package built by build-runtime-package.ps1.
    [Parameter(Mandatory)] [string] $ModZip,

    # The launcher built by build-launcher.ps1 with the release public key.
    [Parameter(Mandatory)] [string] $LauncherExe,

    # The GitHub release tag the files will be uploaded to, e.g. v0.3.0-alpha.3.
    [Parameter(Mandatory)] [string] $Tag,

    # Defaults to the package's release_version.
    [string] $Version,

    # Older launchers refuse this release until they update themselves.
    # Defaults to 0.1.0 (any launcher).
    [string] $MinLauncherVersion = '0.1.0',

    [string] $Notes = '',

    # Default: %APPDATA%\DarktideVR-release\launcher-signing-key.dpapi.
    [string] $KeyFile,

    [string] $SigningKeyEnvironmentVariable,

    [string] $PublicKeyFile,

    [string] $OutputDirectory,

    [string] $DependencyLock = (Join-Path $PSScriptRoot 'launcher-dependencies.psd1'),

    # Directory of already-downloaded dependency archives named
    # <owner>-<repo>-<commit>.zip (offline tests). Missing ones are downloaded.
    [string] $ArchiveDirectory,

    [string] $CodeloadBase = 'https://codeload.github.com',

    [string] $Repo = 'Gnujvil/darktide-vr'
)

# Writes darktidevr-release.json and its .sig beside copies of the mod zip and
# DarktideVR-Launcher.exe, verifies the signature, and prints the gh command
# that uploads them. It publishes nothing itself.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'launcher-signing.ps1')
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if (-not $KeyFile) { $KeyFile = Get-DefaultLauncherKeyPath }
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repoRoot "artifacts\launcher-release\$Tag" }
$ModZip = (Resolve-Path -LiteralPath $ModZip).Path
$LauncherExe = (Resolve-Path -LiteralPath $LauncherExe).Path

function Get-Sha256([byte[]] $Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes)) -replace '-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

# The package's own manifest gives the version and proves it is a package.
$zip = [IO.Compression.ZipFile]::OpenRead($ModZip)
try {
    $entry = $zip.Entries | Where-Object { ($_.FullName -replace '\\', '/') -eq 'mods/darktidevr/package-manifest.json' } | Select-Object -First 1
    if (-not $entry) { throw "$ModZip has no mods/darktidevr/package-manifest.json; build it with build-runtime-package.ps1." }
    $reader = New-Object IO.StreamReader($entry.Open())
    $package = $reader.ReadToEnd().TrimStart([char]0xFEFF) | ConvertFrom-Json
    $reader.Dispose()
} finally {
    $zip.Dispose()
}
if (-not $Version) { $Version = $package.release_version }
if (-not $Version) { throw 'The package has no release_version; pass -Version.' }
if ($package.release_version -and $package.release_version -ne $Version) {
    throw "The package says $($package.release_version), not $Version."
}

$launcherVersion = (Get-Item -LiteralPath $LauncherExe).VersionInfo.ProductVersion
if (-not $launcherVersion) { throw "Can't read the launcher version from $LauncherExe." }

# Pinned dependencies: every installed file with its hash.
function Get-DependencyArchive($Dependency) {
    $name = ($Dependency.Repo -replace '/', '-') + "-$($Dependency.Commit).zip"
    if ($ArchiveDirectory) {
        $local = Join-Path $ArchiveDirectory $name
        if (Test-Path -LiteralPath $local) { return [IO.File]::ReadAllBytes($local) }
    }
    $url = "$($CodeloadBase.TrimEnd('/'))/$($Dependency.Repo)/zip/$($Dependency.Commit)"
    Write-Verbose "Downloading $url"
    $client = New-Object Net.WebClient
    $client.Headers['User-Agent'] = 'darktidevr-release'
    try { return $client.DownloadData($url) } finally { $client.Dispose() }
}

function Get-DependencyEntry($Dependency) {
    $bytes = Get-DependencyArchive $Dependency
    $archive = New-Object IO.Compression.ZipArchive((New-Object IO.MemoryStream(,$bytes)), [IO.Compression.ZipArchiveMode]::Read)
    $contents = @{}
    try {
        foreach ($e in $archive.Entries) {
            $full = $e.FullName -replace '\\', '/'
            if ($full.EndsWith('/')) { continue }
            $slash = $full.IndexOf('/')
            if ($slash -lt 0) { continue }
            $stream = $e.Open(); $buffer = New-Object IO.MemoryStream
            $stream.CopyTo($buffer); $stream.Dispose()
            $contents[$full.Substring($slash + 1)] = $buffer.ToArray()
        }
    } finally {
        $archive.Dispose()
    }
    $files = New-Object System.Collections.Generic.List[object]
    foreach ($rule in $Dependency.Files) {
        $matched = @($contents.Keys | Where-Object {
            if ($rule.Source.EndsWith('/')) { $_.StartsWith($rule.Source, [StringComparison]::Ordinal) } else { $_ -ceq $rule.Source }
        } | Sort-Object)
        if ($matched.Count -eq 0) { throw "$($Dependency.Name)@$($Dependency.Commit): nothing matches $($rule.Source)" }
        foreach ($source in $matched) {
            $target = if ($rule.Source.EndsWith('/')) { $rule.Target + $source.Substring($rule.Source.Length) } else { $rule.Target }
            $file = [ordered]@{ source = $source; target = $target; sha256 = (Get-Sha256 $contents[$source]) }
            if ($rule.ContainsKey('Preserve') -and $rule.Preserve) { $file.preserve = $true }
            $files.Add($file)
        }
    }
    return [ordered]@{
        name = $Dependency.Name
        repo = $Dependency.Repo
        commit = $Dependency.Commit
        files = $files.ToArray()
    }
}

$lock = Import-PowerShellDataFile -LiteralPath $DependencyLock
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$modName = Split-Path -Leaf $ModZip
$modOut = Join-Path $OutputDirectory $modName
$launcherOut = Join-Path $OutputDirectory 'DarktideVR-Launcher.exe'
if ($modOut -ne $ModZip) { Copy-Item -LiteralPath $ModZip -Destination $modOut -Force }
if ($launcherOut -ne $LauncherExe) { Copy-Item -LiteralPath $LauncherExe -Destination $launcherOut -Force }
$modBytes = [IO.File]::ReadAllBytes($modOut)
$launcherBytes = [IO.File]::ReadAllBytes($launcherOut)

$manifest = [ordered]@{
    schema = 1
    kind = 'darktidevr-release'
    version = $Version
    tag = $Tag
    created_utc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    notes = $Notes
    mod = [ordered]@{ asset = $modName; size = $modBytes.Length; sha256 = (Get-Sha256 $modBytes) }
    launcher = [ordered]@{ asset = 'DarktideVR-Launcher.exe'; size = $launcherBytes.Length; sha256 = (Get-Sha256 $launcherBytes); version = $launcherVersion }
    min_launcher_version = $MinLauncherVersion
    mod_loader = Get-DependencyEntry $lock.ModLoader
    mod_framework = Get-DependencyEntry $lock.ModFramework
}
$json = ($manifest | ConvertTo-Json -Depth 8) -replace "`r`n", "`n"
$manifestBytes = [Text.UTF8Encoding]::new($false).GetBytes($json + "`n")
$manifestPath = Join-Path $OutputDirectory 'darktidevr-release.json'
[IO.File]::WriteAllBytes($manifestPath, $manifestBytes)

$material = if ($SigningKeyEnvironmentVariable) {
    Read-LauncherKeyEnvironment $SigningKeyEnvironmentVariable
} else { Read-LauncherKeyFile $KeyFile }
$signature = New-LauncherSignature $manifestBytes $material
$signaturePath = Join-Path $OutputDirectory 'darktidevr-release.json.sig'
[IO.File]::WriteAllText($signaturePath, $signature + "`n", [Text.Encoding]::ASCII)

$publicLine = ConvertTo-LauncherPublicKeyLine $material
if (-not (Test-LauncherSignature $manifestBytes $signature $publicLine)) { throw 'The signature does not verify; nothing to upload.' }
$embedded = if ($PublicKeyFile) { $PublicKeyFile } else { Join-Path $repoRoot 'launcher\release-signing-key.pub' }
if ((Test-Path -LiteralPath $embedded) -and -not ((Get-Content -LiteralPath $embedded) -contains $publicLine)) {
    throw "The signing key does not match launcher/release-signing-key.pub; refusing to publish an unusable update."
}

Write-Output "manifest=$manifestPath"
Write-Output "signature=$signaturePath"
Write-Output "mod=$modOut"
Write-Output "launcher=$launcherOut ($launcherVersion)"
Write-Output "version=$Version"
Write-Output 'Upload (after the release exists and the zip is attached):'
Write-Output "  gh release upload $Tag `"$manifestPath`" `"$signaturePath`" `"$launcherOut`" --repo $Repo"
