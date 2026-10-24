[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $BuildDirectory,
    [Parameter(Mandatory)][ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+$')][string] $Version,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string] $Revision,
    [string] $Repo = 'Gnujvil/darktide-vr'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($Repo -cne 'Gnujvil/darktide-vr') { throw 'Automatic publication is restricted to Gnujvil/darktide-vr.' }
$build = (Resolve-Path -LiteralPath $BuildDirectory).Path
$package = Get-Content -LiteralPath (Join-Path $build 'package.json') -Raw | ConvertFrom-Json
# Artifact downloads have a different absolute root from the build job.
$archive = Join-Path $build ('packages/' + [IO.Path]::GetFileName($package.Archive))
if ((Get-FileHash -LiteralPath $archive).Hash -ine $package.SHA256) { throw 'Runtime archive changed after the verified build.' }
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead($archive)
try {
    $entry = @($zip.Entries | Where-Object { ($_.FullName -replace '\\','/') -eq 'mods/darktidevr/package-manifest.json' })
    if ($entry.Count -ne 1) { throw 'Runtime package manifest is missing or duplicated.' }
    $reader = New-Object IO.StreamReader($entry[0].Open())
    try { $identity = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
    if ($identity.release_version -ne $Version -or $identity.source_revision -ne $Revision -or
        $identity.source_dirty -ne $false -or $identity.binary_source_provenance -ne 'recorded_hash_matched_claims') {
        throw 'Only a clean, provenance-checked package from this workflow revision may be published.'
    }
} finally { $zip.Dispose() }
$release = Join-Path $build 'signed'
& (Join-Path $PSScriptRoot 'new-launcher-release-manifest.ps1') -ModZip $archive `
    -LauncherExe (Join-Path $build 'DarktideVR-Launcher.exe') -Tag "v$Version" `
    -Version $Version -MinLauncherVersion $Version -OutputDirectory $release `
    -Repo $Repo -SigningKeyEnvironmentVariable DARKTIDEVR_RELEASE_SIGNING_KEY `
    -Notes "Automatic main build $Revision. Includes the launcher, mod loader/framework setup, SteamVR/Virtual Desktop runtime selection, and signed automatic updates."
if (-not (Test-Path -LiteralPath (Join-Path $release 'darktidevr-release.json.sig'))) { throw 'Signed manifest was not produced.' }
$existing = & gh release view "v$Version" --repo $Repo --json isDraft,targetCommitish 2>$null
if ($LASTEXITCODE -eq 0) {
    $info = $existing | ConvertFrom-Json
    if ($info.targetCommitish -ne $Revision) { throw 'Existing release points at another revision.' }
    if (-not $info.isDraft) { Write-Output "release_already_published=v$Version"; return }
} else {
    & gh release create "v$Version" --repo $Repo --target $Revision --draft `
        --title "Darktide VR $Version" --notes "Built automatically from main at $Revision. Download DarktideVR-Launcher.exe once; future signed launcher and mod updates install automatically when the launcher starts."
    if ($LASTEXITCODE) { throw 'Could not create the draft release.' }
}
$assets = @(Get-ChildItem -LiteralPath $release -File | ForEach-Object FullName)
& gh release upload "v$Version" --repo $Repo @assets --clobber
if ($LASTEXITCODE) { throw 'Release upload failed; the draft remains hidden from launchers.' }
& gh release edit "v$Version" --repo $Repo --draft=false --latest
if ($LASTEXITCODE) { throw 'Could not publish the signed release.' }
Write-Output "release_published=https://github.com/$Repo/releases/tag/v$Version"
