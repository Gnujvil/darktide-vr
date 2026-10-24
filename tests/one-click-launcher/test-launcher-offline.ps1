[CmdletBinding()]
param(
    # Scratch folder for the fake game, the mock GitHub and the isolated
    # LOCALAPPDATA/APPDATA. Deleted afterwards unless -KeepWorkRoot.
    [string] $WorkRoot = (Join-Path $env:TEMP ('dvr-launcher-e2e-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))),

    # Downloads kept between runs: the 0.3.0-alpha.2 package (the base for the
    # test packages) and the pinned Mod Loader / Mod Framework archives.
    [string] $CacheRoot,

    [switch] $KeepWorkRoot,

    # Skip the read-only check against the real GitHub API (one request).
    [switch] $SkipRealGitHub,

    # Also ask the real OpenXR runtimes whether a headset is connected (an
    # instance, no session). Off by default; never while playing.
    [switch] $ProbeRealRuntimes
)

# End-to-end test of the one-click launcher with no headset, no game launch and
# nothing outside $WorkRoot touched:
#   - a fake game folder (synthetic Darktide.exe and bundle_database.data);
#   - a mock GitHub API on 127.0.0.1 (Python's http.server over static files);
#   - test packages built from the published 0.3.0-alpha.2 zip, whose patch
#     tool gains a build entry for the synthetic executable;
#   - launchers 0.1.0 and 0.2.0 built with a throwaway signing key;
#   - every launcher run with LOCALAPPDATA and APPDATA redirected, because the
#     mod's mode script keeps the pristine executable and settings there.
# The shipped mode script refuses to switch while any Darktide.exe runs, so
# with the game open the scenarios that need it are reported as skipped.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Below the game and anything else interactive; children inherit it.
(Get-Process -Id $PID).PriorityClass = 'Idle'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if (-not $CacheRoot) { $CacheRoot = Join-Path $repoRoot 'artifacts\test-cache\launcher' }
New-Item -ItemType Directory -Path $WorkRoot, $CacheRoot -Force | Out-Null
$script:Work = (Resolve-Path $WorkRoot).Path
$script:Www = Join-Path $script:Work 'www'
$script:Game = Join-Path $script:Work 'game'
$script:LocalAppData = Join-Path $script:Work 'appdata\local'
$script:RoamingAppData = Join-Path $script:Work 'appdata\roaming'
New-Item -ItemType Directory -Path $script:Www, $script:LocalAppData, $script:RoamingAppData -Force | Out-Null

$script:Passed = 0
$script:Failed = New-Object System.Collections.Generic.List[string]
$script:Skipped = New-Object System.Collections.Generic.List[string]

function Check([string] $Name, [bool] $Ok, [string] $Detail = '') {
    if ($Ok) {
        $script:Passed++
        Write-Host "PASS $Name"
    } else {
        $script:Failed.Add($Name)
        Write-Host "FAIL $Name $Detail" -ForegroundColor Red
    }
}

function Skip([string] $Name, [string] $Why) {
    $script:Skipped.Add("$Name ($Why)")
    Write-Host "SKIP $Name ($Why)" -ForegroundColor Yellow
}

function Get-Sha256([string] $Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }

function Get-TreeHashes([string] $Root) {
    $result = @{}
    if (-not (Test-Path -LiteralPath $Root)) { return $result }
    foreach ($file in Get-ChildItem -LiteralPath $Root -Recurse -File -Force) {
        $result[$file.FullName.Substring($Root.Length + 1)] = Get-Sha256 $file.FullName
    }
    return $result
}

function ConvertTo-ArgumentText([string] $Value) {
    if ($Value -match '[\s"]') { return '"' + $Value.Replace('"', '\"') + '"' }
    return $Value
}

# Runs the launcher's command-line mode against the mock and the isolated
# profile; returns exit code, output, key=value pairs and skipped= lines.
function Invoke-Launcher {
    param([string] $Exe, [string[]] $Arguments, [switch] $RealGitHub)
    $all = New-Object System.Collections.Generic.List[string]
    if (-not $RealGitHub) {
        $all.AddRange([string[]]@('--api-base', $script:ApiBase, '--codeload-base', "$script:ApiBase/codeload", '--repo', 'test/darktide-vr'))
    }
    $all.AddRange([string[]]$Arguments)
    $start = New-Object Diagnostics.ProcessStartInfo $Exe
    $start.Arguments = ($all | ForEach-Object { ConvertTo-ArgumentText $_ }) -join ' '
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.EnvironmentVariables['LOCALAPPDATA'] = $script:LocalAppData
    $start.EnvironmentVariables['APPDATA'] = $script:RoamingAppData
    $process = [Diagnostics.Process]::Start($start)
    $out = $process.StandardOutput.ReadToEndAsync()
    $err = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(600000)) { $process.Kill(); throw "The launcher timed out: $($start.Arguments)" }
    $process.WaitForExit()
    $values = @{}
    $skipped = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($out.Result -split "`r?`n")) {
        if ($line -match '^([a-z0-9_]+)=(.*)$') {
            if ($Matches[1] -eq 'skipped') { $skipped.Add($Matches[2]) } else { $values[$Matches[1]] = $Matches[2] }
        }
    }
    $result = [pscustomobject]@{
        ExitCode = $process.ExitCode; Output = $out.Result; Error = $err.Result; Values = $values; Skipped = $skipped
    }
    Write-Verbose "launcher $($start.Arguments)`n$($result.Output)$($result.Error)"
    return $result
}

function Value($Result, [string] $Key) {
    if ($Result.Values.ContainsKey($Key)) { return $Result.Values[$Key] }
    return $null
}

# The installed mod's version, read from its package manifest.
function ModVersion {
    $path = Join-Path $script:Game 'mods\darktidevr\package-manifest.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).release_version
}

# ---- downloads (cached) ------------------------------------------------------

function Get-BasePackage {
    $release = Invoke-RestMethod -UseBasicParsing 'https://api.github.com/repos/Brobert-in-aus/darktide-vr/releases/tags/v0.3.0-alpha.2'
    $asset = @($release.assets | Where-Object { $_.name -like 'darktidevr-*.zip' })[0]
    $path = Join-Path $CacheRoot $asset.name
    if (-not (Test-Path -LiteralPath $path)) {
        Invoke-WebRequest -UseBasicParsing -Uri $asset.browser_download_url -OutFile $path
    }
    $expected = ($asset.digest -replace '^sha256:', '').ToLowerInvariant()
    Check 'real GitHub: alpha.2 package matches its published digest' ((Get-Sha256 $path) -eq $expected) $asset.digest
    return $path
}

function Get-DependencyArchives {
    $lock = Import-PowerShellDataFile (Join-Path $repoRoot 'tools\release\launcher-dependencies.psd1')
    foreach ($dependency in @($lock.ModLoader, $lock.ModFramework)) {
        $name = ($dependency.Repo -replace '/', '-') + "-$($dependency.Commit).zip"
        $path = Join-Path $CacheRoot $name
        if (-not (Test-Path -LiteralPath $path)) {
            Invoke-WebRequest -UseBasicParsing -Uri "https://codeload.github.com/$($dependency.Repo)/zip/$($dependency.Commit)" -OutFile $path
        }
        # Served by the mock at the codeload path the launcher builds.
        $served = Join-Path $script:Www ("codeload\" + ($dependency.Repo -replace '/', '\') + "\zip\$($dependency.Commit)")
        New-Item -ItemType Directory -Path (Split-Path -Parent $served) -Force | Out-Null
        Copy-Item -LiteralPath $path -Destination $served -Force
    }
}

# ---- fixtures ------------------------------------------------------------------

$script:ExeOffsets = @(0x1000, 0x1100)

function New-SyntheticExe([string] $Path, [int] $Seed) {
    $bytes = New-Object byte[] (2MB)
    (New-Object Random $Seed).NextBytes($bytes)
    foreach ($offset in $script:ExeOffsets) { $bytes[$offset] = 0x75 }
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [IO.File]::WriteAllBytes($Path, $bytes)
}

# dtkit-patch looks for these 8 bytes and splices its patch over the 84 after.
function New-SyntheticBundleDatabase([string] $Path) {
    $bytes = New-Object byte[] (256KB)
    $marker = [byte[]](0xA3, 0x3A, 0x4A, 0xA4, 0xAF, 0x26, 0xA6, 0x9B)
    [Array]::Copy($marker, 0, $bytes, 0x2000, $marker.Length)
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [IO.File]::WriteAllBytes($Path, $bytes)
}

function Write-TextKeepingEncoding([string] $Path, [string] $Text) {
    $raw = [IO.File]::ReadAllBytes($Path)
    $bom = $raw.Length -ge 3 -and $raw[0] -eq 0xEF -and $raw[1] -eq 0xBB -and $raw[2] -eq 0xBF
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($bom)))
}

# A release package like the real one (backslash entry names), with the
# synthetic executable added to its patch tool and its manifest rewritten.
function New-TestPackage {
    param([string] $Version, [string[]] $ExtraEntries = @(), [switch] $LeaveManifest)
    $stage = Join-Path $script:Work "stage\$Version"
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
    $zip = [IO.Compression.ZipFile]::OpenRead($script:BaseZip)
    try {
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName -replace '\\', '/'
            if ($name.EndsWith('/')) { continue }
            $target = Join-Path $stage ($name -replace '/', '\')
            New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
        }
    } finally { $zip.Dispose() }
    $mod = Join-Path $stage 'mods\darktidevr'

    $tool = Join-Path $mod 'tools\set-skinner-assert-patch.ps1'
    $text = [IO.File]::ReadAllText($tool)
    if ($text.IndexOf('$builds = @(') -lt 0) { throw 'The patch tool no longer has a $builds table.' }
    $offsets = ($script:ExeOffsets | ForEach-Object { '0x{0:x}' -f $_ }) -join ', '
    $text = $text.Replace('$builds = @(', "`$builds = @(`r`n    @{ Name = 'launcher-test'`r`n       Sha256 = '$script:ExeSha'`r`n       Offsets = @($offsets) },")
    Write-TextKeepingEncoding $tool $text

    Add-Content -LiteralPath (Join-Path $mod 'README.txt') -Value "launcher test package $Version"

    if (-not $LeaveManifest) {
        $manifestPath = Join-Path $mod 'package-manifest.json'
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $manifest.release_version = $Version
        foreach ($file in $manifest.files) {
            $path = Join-Path $stage ($file.path -replace '/', '\')
            $file.bytes = (Get-Item -LiteralPath $path).Length
            $file.sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        }
        Set-Content -LiteralPath $manifestPath -Value ($manifest | ConvertTo-Json -Depth 50) -Encoding UTF8
    }

    $out = Join-Path $script:Work "packages\darktidevr-$Version-test.zip"
    New-Item -ItemType Directory -Path (Split-Path -Parent $out) -Force | Out-Null
    $stream = [IO.File]::Open($out, [IO.FileMode]::Create)
    $archive = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($file in Get-ChildItem -LiteralPath $stage -Recurse -File) {
            [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $file.FullName, $file.FullName.Substring($stage.Length + 1)) | Out-Null
        }
        foreach ($extra in $ExtraEntries) {
            $writer = New-Object IO.StreamWriter($archive.CreateEntry($extra).Open())
            $writer.Write('not part of the package')
            $writer.Dispose()
        }
    } finally {
        $archive.Dispose()
        $stream.Dispose()
    }
    return $out
}

function New-TestRelease {
    param([string] $Tag, [string] $Package, [string] $Launcher, [string] $KeyFile = $script:KeyFile,
          [string] $ManifestTag, [string] $MinLauncher = '0.1.0')
    if (-not $ManifestTag) { $ManifestTag = $Tag }
    $directory = Join-Path $script:Www "dl\$Tag"
    if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
    $arguments = @{
        ModZip = $Package; LauncherExe = $Launcher; Tag = $ManifestTag; KeyFile = $KeyFile
        OutputDirectory = $directory; ArchiveDirectory = $CacheRoot; MinLauncherVersion = $MinLauncher
        PublicKeyFile = [IO.Path]::ChangeExtension($KeyFile, '.pub')
        Repo = 'test/darktide-vr'
    }
    & (Join-Path $repoRoot 'tools\release\new-launcher-release-manifest.ps1') @arguments 3>$null | Out-Null
    return $directory
}

# Writes the mock's GET /repos/test/darktide-vr/releases, newest first.
function Publish-Releases([object[]] $Releases, [string] $DownloadBase = $script:ApiBase) {
    $list = New-Object System.Collections.Generic.List[object]
    $minute = 0
    foreach ($release in $Releases) {
        $directory = Join-Path $script:Www "dl\$($release.Tag)"
        $assets = @(foreach ($file in Get-ChildItem -LiteralPath $directory -File) {
            $asset = [ordered]@{
                name = $file.Name; size = $file.Length
                browser_download_url = "$DownloadBase/dl/$($release.Tag)/$($file.Name)"
            }
            if (-not ($release.ContainsKey('NoDigest') -and $release.NoDigest)) { $asset.digest = 'sha256:' + (Get-Sha256 $file.FullName) }
            [pscustomobject]$asset
        })
        $list.Insert(0, [pscustomobject][ordered]@{
            tag_name = $release.Tag; name = $release.Tag; draft = $false
            prerelease = ($release.ContainsKey('Prerelease') -and [bool]$release.Prerelease)
            published_at = (Get-Date).ToUniversalTime().AddMinutes($minute).ToString('yyyy-MM-ddTHH:mm:ssZ')
            html_url = "https://example.invalid/$($release.Tag)"
            assets = $assets
        })
        $minute++
    }
    $path = Join-Path $script:Www 'repos\test\darktide-vr\releases'
    New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
    [IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $list.ToArray() -Depth 6), (New-Object Text.UTF8Encoding($false)))
}

function Start-MockServer {
    $python = Get-Command python -ErrorAction SilentlyContinue
    if (-not $python) { throw 'Python 3 is needed for the mock GitHub server (python on PATH).' }
    $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $listener.Start(); $port = $listener.LocalEndpoint.Port; $listener.Stop()
    $start = New-Object Diagnostics.ProcessStartInfo $python.Source
    $start.Arguments = "-I -m http.server $port --bind 127.0.0.1 --directory `"$script:Www`""
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $script:Server = [Diagnostics.Process]::Start($start)
    $script:ApiBase = "http://127.0.0.1:$port"
    for ($attempt = 0; $attempt -lt 50; $attempt++) {
        try {
            Invoke-WebRequest -UseBasicParsing "$script:ApiBase/" -TimeoutSec 2 | Out-Null
            return
        } catch { Start-Sleep -Milliseconds 200 }
    }
    throw 'The mock server did not start.'
}

# ---- run -----------------------------------------------------------------------

$gameOpen = [bool](Get-Process Darktide -ErrorAction SilentlyContinue)
if ($gameOpen) { Write-Host 'Darktide is running: scenarios that need the mod''s mode script are skipped.' -ForegroundColor Yellow }

try {
    Start-MockServer
    $script:BaseZip = Get-BasePackage
    Get-DependencyArchives

    # Signing keys: the trusted test key and a stranger's.
    $keys = Join-Path $script:Work 'keys'
    $script:KeyFile = Join-Path $keys 'test.key'
    $strangerKey = Join-Path $keys 'stranger.key'
    $newKey = Join-Path $repoRoot 'tools\release\new-launcher-signing-key.ps1'
    & $newKey -KeyFile $script:KeyFile -PublicKeyFile (Join-Path $keys 'test.pub') -Unprotected | Out-Null
    & $newKey -KeyFile $strangerKey -PublicKeyFile (Join-Path $keys 'stranger.pub') -Unprotected | Out-Null

    # Launchers 0.1.0 and 0.2.0 trusting the test key.
    $build = Join-Path $repoRoot 'tools\release\build-launcher.ps1'
    & $build -Version 0.1.0 -PublicKeyFile (Join-Path $keys 'test.pub') -OutputDirectory (Join-Path $script:Work 'launcher-0.1.0') | Out-Null
    & $build -Version 0.2.0 -PublicKeyFile (Join-Path $keys 'test.pub') -OutputDirectory (Join-Path $script:Work 'launcher-0.2.0') | Out-Null
    $L1 = Join-Path $script:Work 'launcher-0.1.0\DarktideVR-Launcher.exe'
    $L2 = Join-Path $script:Work 'launcher-0.2.0\DarktideVR-Launcher.exe'

    # The fake game.
    $exe = Join-Path $script:Game 'binaries\Darktide.exe'
    $database = Join-Path $script:Game 'bundle\bundle_database.data'
    New-SyntheticExe $exe 1361210
    New-SyntheticBundleDatabase $database
    $script:ExeSha = Get-Sha256 $exe
    $originalDatabase = Get-Sha256 $database
    $initialTree = Get-TreeHashes $script:Game
    $gameArgs = @('--game-root', $script:Game)

    # Packages and releases.
    $P1 = New-TestPackage '9.9.0-test.1'
    $P2 = New-TestPackage '9.9.0-test.2'
    New-TestRelease 'v9.9.0-test.1' $P1 $L1 | Out-Null
    New-TestRelease 'v9.9.0-test.2' $P2 $L2 | Out-Null
    $R1 = @{ Tag = 'v9.9.0-test.1' }
    $R2pre = @{ Tag = 'v9.9.0-test.2'; Prerelease = $true }

    # -- basics
    $r = Invoke-Launcher $L1 @('--cli', 'version')
    Check 'version: 0.1.0 with one trusted key' ((Value $r 'version') -eq '0.1.0' -and (Value $r 'trusted_keys') -eq '1') $r.Output
    $r = Invoke-Launcher $L1 @('--cli', 'selftest')
    Check 'selftest passes' ($r.ExitCode -eq 0 -and (Value $r 'selftest') -eq 'pass') $r.Output

    $r = Invoke-Launcher $L1 (@('--cli', 'status') + $gameArgs)
    Check 'status: fresh game has nothing installed' ((Value $r 'game_root') -eq $script:Game -and (Value $r 'mod_loader') -eq 'false' -and
        (Value $r 'framework') -eq 'false' -and (Value $r 'mod_installed') -eq 'false') "$($r.Output)$($r.Error)"

    # -- update feed: stable only, then test builds
    Publish-Releases @($R1, $R2pre)
    $r = Invoke-Launcher $L1 (@('--cli', 'check') + $gameArgs)
    Check 'check: newest stable release offered' ((Value $r 'available_mod') -eq '9.9.0-test.1' -and (Value $r 'launcher_update') -eq 'false') "$($r.Output)$($r.Error)"
    Check 'check: pre-release held back by default' (@($r.Skipped | Where-Object { $_ -like 'v9.9.0-test.2: test build*' }).Count -eq 1) ($r.Skipped -join '; ')

    # The API answers but the downloads can't be reached (nothing listens on
    # port 9): reported as a connection problem, not as "no release".
    Publish-Releases @($R1, $R2pre) -DownloadBase 'http://127.0.0.1:9'
    $r = Invoke-Launcher $L1 (@('--cli', 'check') + $gameArgs)
    Check 'check: failed downloads reported as a connection problem' ($r.ExitCode -eq 1 -and $r.Error -match "Couldn't reach GitHub") "$($r.Output)$($r.Error)"
    Publish-Releases @($R1, $R2pre)

    # -- install the pieces (the game folder only; no mode switch)
    $r = Invoke-Launcher $L1 (@('--cli', 'install-deps') + $gameArgs)
    Check 'install-deps: mod loader and framework installed from the pinned archives' ($r.ExitCode -eq 0 -and [int](Value $r 'files_written') -gt 10 -and
        (Test-Path (Join-Path $script:Game 'binaries\mod_loader')) -and (Test-Path (Join-Path $script:Game 'mods\dmf\dmf.mod')) -and
        (Test-Path (Join-Path $script:Game 'tools\dtkit-patch.exe'))) "$($r.Output)$($r.Error)"
    $state = Get-Content -Raw (Join-Path $script:LocalAppData 'DarktideVR\launcher\state.json') | ConvertFrom-Json
    Check 'install-deps: files recorded as launcher-owned; mod list not owned' (@($state.owned_files).Count -gt 10 -and
        -not (@($state.owned_files | Where-Object { $_.path -eq 'mods/mod_load_order.txt' }).Count)) ''
    Check 'isolation: launcher state lives in the scratch profile' ($state.game_root -eq $script:Game) ''

    $r = Invoke-Launcher $L1 (@('--cli', 'install-mod') + $gameArgs)
    Check 'install-mod: 9.9.0-test.1 installed' ($r.ExitCode -eq 0 -and (Value $r 'installed') -eq 'v9.9.0-test.1' -and
        (Test-Path (Join-Path $script:Game 'mods\darktidevr\darktidevr-mode.ps1'))) "$($r.Output)$($r.Error)"
    Check 'install-mod: no staging or previous folder left' (-not (Test-Path (Join-Path $script:Game 'mods\.darktidevr-update')) -and
        -not (Test-Path (Join-Path $script:Game 'mods\.darktidevr-previous'))) ''

    # -- VR and flat through the mod's own mode script
    if ($gameOpen) {
        Skip 'vr/flat, bundle re-patch' 'Darktide is running'
    } else {
        $r = Invoke-Launcher $L1 (@('--cli', 'vr') + $gameArgs)
        Check 'vr: exit 0' ($r.ExitCode -eq 0) "$($r.Output)$($r.Error)"
        Check 'vr: mods switched on, executable patched, proxy installed, mod listed' ((Value $r 'mods_enabled') -eq 'true' -and
            (Value $r 'executable') -eq 'patched' -and (Value $r 'd3d12_proxy') -eq 'installed' -and (Value $r 'load_order') -eq 'listed' -and
            (Value $r 'vr_mode') -eq 'true') $r.Output
        $bytes = [IO.File]::ReadAllBytes($exe)
        Check 'vr: exactly the two bytes became jmp' ($bytes[0x1000] -eq 0xEB -and $bytes[0x1100] -eq 0xEB) ''
        Check 'vr: pristine executable kept in the scratch profile' (Test-Path (Join-Path $script:LocalAppData 'DarktideVR\Darktide.exe.pre-skinner-assert-patch')) ''
        Check 'vr: proxy is the mod''s d3d12.dll' ((Get-Sha256 (Join-Path $script:Game 'binaries\d3d12.dll')) -eq (Get-Sha256 (Join-Path $script:Game 'mods\darktidevr\bin\d3d12.dll'))) ''

        $r = Invoke-Launcher $L1 (@('--cli', 'flat') + $gameArgs)
        Check 'flat: original executable, proxy gone, mod unlisted, mods still on' ($r.ExitCode -eq 0 -and (Value $r 'executable') -eq 'original' -and
            (Get-Sha256 $exe) -eq $script:ExeSha -and (Value $r 'd3d12_proxy') -eq 'absent' -and (Value $r 'load_order') -eq 'absent' -and
            (Value $r 'mods_enabled') -eq 'true') "$($r.Output)$($r.Error)"

        # A game update replaces bundle_database.data and switches mods off.
        Remove-Item -LiteralPath "$database.bak" -Force -ErrorAction SilentlyContinue
        New-SyntheticBundleDatabase $database
        $r = Invoke-Launcher $L1 (@('--cli', 'status') + $gameArgs)
        Check 'game update: mods reported off' ((Value $r 'mods_enabled') -eq 'false') $r.Output
        $r = Invoke-Launcher $L1 (@('--cli', 'vr') + $gameArgs)
        Check 'game update: Play in VR switches mods back on and VR on' ($r.ExitCode -eq 0 -and (Value $r 'mods_enabled') -eq 'true' -and
            (Value $r 'vr_mode') -eq 'true') "$($r.Output)$($r.Error)"
    }

    # -- test builds and the update to 9.9.0-test.2
    $r = Invoke-Launcher $L1 (@('--cli', 'check', '--include-prereleases') + $gameArgs)
    Check 'check: test build offered once opted in, with a launcher update' ((Value $r 'available_mod') -eq '9.9.0-test.2' -and
        (Value $r 'launcher_update') -eq 'true') "$($r.Output)$($r.Error)"
    $r = Invoke-Launcher $L1 (@('--cli', 'install-mod') + $gameArgs)
    Check 'update: 9.9.0-test.2 installed over test.1' ($r.ExitCode -eq 0 -and (Value $r 'installed') -eq 'v9.9.0-test.2' -and
        (Get-Content -Raw (Join-Path $script:Game 'mods\darktidevr\README.txt')) -match 'launcher test package 9\.9\.0-test\.2') "$($r.Output)$($r.Error)"
    if (-not $gameOpen) {
        $r = Invoke-Launcher $L1 (@('--cli', 'status') + $gameArgs)
        Check 'update: VR mode reapplied with the new proxy' ((Value $r 'mod_version') -eq '9.9.0-test.2' -and (Value $r 'vr_mode') -eq 'true') $r.Output
    }

    # -- the launcher updates itself
    $friend = Join-Path $script:Work 'friend'
    New-Item -ItemType Directory -Path $friend -Force | Out-Null
    $friendExe = Join-Path $friend 'DarktideVR-Launcher.exe'
    Copy-Item -LiteralPath $L1 -Destination $friendExe -Force
    $r = Invoke-Launcher $friendExe (@('--cli', 'self-update', '--no-restart') + $gameArgs)
    Check 'self-update: replaced by 0.2.0' ($r.ExitCode -eq 0 -and (Value $r 'self_updated') -eq 'true' -and
        (Get-Item -LiteralPath $friendExe).VersionInfo.ProductVersion -eq '0.2.0' -and (Get-Sha256 $friendExe) -eq (Get-Sha256 $L2)) "$($r.Output)$($r.Error)"
    Check 'self-update: previous exe set aside' (Test-Path (Join-Path $friend 'DarktideVR-Launcher.old.exe')) ''
    $r = Invoke-Launcher $friendExe @('--cli', 'version')
    Check 'self-update: new exe runs and removes the old one' ((Value $r 'version') -eq '0.2.0' -and
        -not (Test-Path (Join-Path $friend 'DarktideVR-Launcher.old.exe'))) $r.Output

    # -- refusals
    $automaticFriend = Join-Path $script:Work 'automatic-friend'
    New-Item -ItemType Directory -Path $automaticFriend -Force | Out-Null
    $automaticExe = Join-Path $automaticFriend 'DarktideVR-Launcher.exe'
    Copy-Item -LiteralPath $L1 -Destination $automaticExe
    $r = Invoke-Launcher $automaticExe (@('--cli', 'auto-update', '--no-restart') + $gameArgs)
    Check 'automatic update: old launcher replaces itself without an Update click' ($r.ExitCode -eq 0 -and
        (Value $r 'self_updated') -eq 'true' -and (Get-Sha256 $automaticExe) -eq (Get-Sha256 $L2)) "$($r.Output)$($r.Error)"
    if (-not $gameOpen) {
        Publish-Releases @($R1)
        $r = Invoke-Launcher $L2 (@('--cli', 'install-mod') + $gameArgs)
        Publish-Releases @($R1, $R2pre)
        $r = Invoke-Launcher $L2 (@('--cli', 'auto-update', '--no-restart') + $gameArgs)
        Check 'automatic update: installed mod advances without an Update click' ($r.ExitCode -eq 0 -and
            (ModVersion) -eq '9.9.0-test.2' -and (Value $r 'self_updated') -eq 'false') "$($r.Output)$($r.Error)"
    }

    # -- refusals
    $P3 = New-TestPackage '9.9.0-test.3'
    New-TestRelease 'v9.9.0-test.3' $P3 $L2 -KeyFile $strangerKey | Out-Null
    Publish-Releases @($R1, $R2pre, @{ Tag = 'v9.9.0-test.3' })
    $r = Invoke-Launcher $L1 (@('--cli', 'check') + $gameArgs)
    Check 'refuse: release signed by another key' ((Value $r 'available_mod') -eq '9.9.0-test.2' -and
        @($r.Skipped | Where-Object { $_ -like 'v9.9.0-test.3: its signature*' }).Count -eq 1) ($r.Skipped -join '; ')

    $P4 = New-TestPackage '9.9.0-test.4'
    $R4dir = New-TestRelease 'v9.9.0-test.4' $P4 $L2
    $tampered = Join-Path $R4dir (Split-Path -Leaf $P4)
    $bytes = [IO.File]::ReadAllBytes($tampered); $middle = [int][Math]::Floor($bytes.Length / 2)
    $bytes[$middle] = $bytes[$middle] -bxor 0xFF
    [IO.File]::WriteAllBytes($tampered, $bytes)
    Publish-Releases @($R1, $R2pre, @{ Tag = 'v9.9.0-test.4' })
    $r = Invoke-Launcher $L1 (@('--cli', 'check') + $gameArgs)
    Check 'refuse: GitHub digest differs from the signed checksum' ((Value $r 'available_mod') -eq '9.9.0-test.2' -and
        @($r.Skipped | Where-Object { $_ -like '*signed checksum*' }).Count -eq 1) ($r.Skipped -join '; ')
    Publish-Releases @($R1, $R2pre, @{ Tag = 'v9.9.0-test.4'; NoDigest = $true })
    $r = Invoke-Launcher $L1 (@('--cli', 'install-mod') + $gameArgs)
    Check 'refuse: tampered download discarded, test.2 stays' ($r.ExitCode -eq 1 -and $r.Error -match 'did not match its published checksum' -and
        (ModVersion) -eq '9.9.0-test.2') "$($r.Output)$($r.Error)"

    $P5 = New-TestPackage '9.9.0-test.5' -ExtraEntries @('mods\darktidevr\..\..\binaries\evil.dll')
    New-TestRelease 'v9.9.0-test.5' $P5 $L2 | Out-Null
    Publish-Releases @($R2pre, @{ Tag = 'v9.9.0-test.5' })
    $r = Invoke-Launcher $L1 (@('--cli', 'install-mod') + $gameArgs)
    Check 'refuse: archive path escaping the mod folder' ($r.ExitCode -eq 1 -and $r.Error -match 'unsafe path' -and
        -not (Test-Path (Join-Path $script:Game 'binaries\evil.dll')) -and (ModVersion) -eq '9.9.0-test.2') "$($r.Output)$($r.Error)"

    $P6 = New-TestPackage '9.9.0-test.6' -ExtraEntries @('mods\darktidevr\unlisted.txt')
    New-TestRelease 'v9.9.0-test.6' $P6 $L2 | Out-Null
    Publish-Releases @($R2pre, @{ Tag = 'v9.9.0-test.6' })
    $r = Invoke-Launcher $L1 (@('--cli', 'install-mod') + $gameArgs)
    Check 'refuse: file the package manifest does not list' ($r.ExitCode -eq 1 -and $r.Error -match "doesn't list" -and
        (ModVersion) -eq '9.9.0-test.2') "$($r.Output)$($r.Error)"

    New-TestRelease 'v9.9.0-test.7' $P2 $L2 -ManifestTag 'v9.9.0-test.2' | Out-Null
    Publish-Releases @($R1, @{ Tag = 'v9.9.0-test.7' })
    $r = Invoke-Launcher $L1 (@('--cli', 'check', '--stable-only') + $gameArgs)
    Check 'refuse: signed manifest re-uploaded under another tag' ((Value $r 'available_mod') -eq '9.9.0-test.1' -and
        @($r.Skipped | Where-Object { $_ -like 'v9.9.0-test.7: its manifest belongs to v9.9.0-test.2*' }).Count -eq 1) ($r.Skipped -join '; ')

    $P8 = New-TestPackage '9.9.0-test.8'
    New-TestRelease 'v9.9.0-test.8' $P8 $L2 -MinLauncher '9.0.0' | Out-Null
    Publish-Releases @($R1, @{ Tag = 'v9.9.0-test.8' })
    $r = Invoke-Launcher $L1 (@('--cli', 'install-mod') + $gameArgs)
    Check 'refuse: release needing a newer launcher' ($r.ExitCode -eq 1 -and $r.Error -match 'needs launcher 9\.0\.0' -and
        (ModVersion) -eq '9.9.0-test.2') "$($r.Output)$($r.Error)"

    Publish-Releases @($R1, $R2pre)
    $vortex = Join-Path $script:Game 'vortex.deployment.json'
    Set-Content -LiteralPath $vortex -Value '{"instance":"x","files":[{"relPath":"mods\\darktidevr\\darktidevr.mod","source":"Darktide VR"}]}' -Encoding UTF8
    $r = Invoke-Launcher $L1 (@('--cli', 'install-mod', '--include-prereleases') + $gameArgs)
    Check 'refuse: mod folder managed by Vortex' ($r.ExitCode -eq 1 -and $r.Error -match 'Vortex') "$($r.Output)$($r.Error)"
    $r = Invoke-Launcher $L1 (@('--cli', 'status') + $gameArgs)
    Check 'status: Vortex ownership reported' ((Value $r 'vortex_manages_mod') -eq 'true') $r.Output
    Remove-Item -LiteralPath $vortex -Force

    # -- Steam integration, against a fake Steam folder
    $steam = Join-Path $script:Work 'steam'
    $steamArgs = @('--steam-root', $steam) + $gameArgs
    $id64 = '76561198000000001'; $id3 = '39734273'
    New-Item -ItemType Directory -Path (Join-Path $steam 'config'), (Join-Path $steam "userdata\$id3\config"),
        (Join-Path $steam 'appcache\librarycache\1361210\0a1b') -Force | Out-Null
    $steamManifest = Join-Path $steam 'config\steamapps.vrmanifest'
    Set-Content -LiteralPath $steamManifest -Value '{"source":"steam","applications":[]}' -Encoding ascii
    $appConfig = Join-Path $steam 'config\appconfig.json'
    [IO.File]::WriteAllText($appConfig, "{`n   `"manifest_paths`" : [ `"$($steamManifest.Replace('\', '\\'))`" ]`n}`n")
    [IO.File]::WriteAllText((Join-Path $steam 'config\loginusers.vdf'), "`"users`"`n{`n`t`"$id64`"`n`t{`n`t`t`"AccountName`"`t`t`"friend`"`n`t`t`"MostRecent`"`t`t`"1`"`n`t}`n}`n")
    [IO.File]::WriteAllBytes((Join-Path $steam 'appcache\librarycache\1361210\0a1b\library_header.jpg'), [byte[]](1, 2, 3))
    $localConfig = Join-Path $steam "userdata\$id3\config\localconfig.vdf"
    function Write-LocalConfig([string] $DarktideBlock) {
        $text = "`"UserLocalConfigStore`"`n{`n`t`"Software`"`n`t{`n`t`t`"Valve`"`n`t`t{`n`t`t`t`"Steam`"`n`t`t`t{`n`t`t`t`t`"apps`"`n`t`t`t`t{`n" +
                "`t`t`t`t`t`"553850`"`n`t`t`t`t`t{`n`t`t`t`t`t`t`"LaunchOptions`"`t`t`"-novid`"`n`t`t`t`t`t}`n" +
                "`t`t`t`t`t`"1361210`"`n`t`t`t`t`t{`n`t`t`t`t`t`t`"LastPlayed`"`t`t`"1792842002`"`n$DarktideBlock`t`t`t`t`t}`n" +
                "`t`t`t`t}`n`t`t`t}`n`t`t}`n`t}`n}`n"
        [IO.File]::WriteAllText($localConfig, $text, (New-Object Text.UTF8Encoding($false)))
        Remove-Item -LiteralPath "$localConfig.darktidevr-backup" -ErrorAction SilentlyContinue
        return $text
    }
    $stableExe = Join-Path $script:LocalAppData 'DarktideVR\launcher\app\DarktideVR-Launcher.exe'
    $expectedOption = "`"$stableExe`" --steam-launch %command%"
    $escapedOption = '"' + $expectedOption.Replace('\', '\\').Replace('"', '\"') + '"'

    $original = Write-LocalConfig ''
    $r = Invoke-Launcher $L1 (@('--cli', 'steam-setup') + $steamArgs)
    Check 'steam: set up both the launch option and the SteamVR library entry' ($r.ExitCode -eq 0 -and (Value $r 'steam_launch_option') -eq 'true' -and
        (Value $r 'steamvr_library') -eq 'true') "$($r.Output)$($r.Error)"
    $text = [IO.File]::ReadAllText($localConfig)
    Check 'steam: launch option written escaped, other apps untouched' ($text.Contains("`"LaunchOptions`"`t`t$escapedOption") -and
        $text.Contains("`"LaunchOptions`"`t`t`"-novid`"") -and $text.Length -gt $original.Length) $text
    Check 'steam: localconfig backed up first' ([IO.File]::ReadAllText("$localConfig.darktidevr-backup") -eq $original) ''
    Check 'steam: launcher copied to the fixed location' ((Test-Path $stableExe) -and (Get-Item $stableExe).VersionInfo.ProductVersion -eq '0.1.0') ''
    $config = Get-Content -Raw $appConfig | ConvertFrom-Json
    $vrManifestPath = Join-Path $script:LocalAppData 'DarktideVR\launcher\app\darktidevr.vrmanifest'
    Check 'steamvr: our manifest added beside Steam''s' (@($config.manifest_paths).Count -eq 2 -and @($config.manifest_paths) -contains $steamManifest -and
        @($config.manifest_paths) -contains $vrManifestPath) (Get-Content -Raw $appConfig)
    $vrManifest = Get-Content -Raw $vrManifestPath | ConvertFrom-Json
    $app = $vrManifest.applications[0]
    Check 'steamvr: tile runs the launcher with --vr-launch, with the game''s art' ($app.app_key -eq 'darktidevr.launcher.darktide' -and $app.launch_type -eq 'binary' -and
        $app.binary_path_windows -eq $stableExe -and $app.arguments -eq '--vr-launch' -and $app.strings.en_us.name -like '*Darktide VR' -and (Test-Path $app.image_path)) (Get-Content -Raw $vrManifestPath)

    $r = Invoke-Launcher $L1 (@('--cli', 'steam-remove') + $steamArgs)
    Check 'steam: remove puts localconfig back byte for byte' ($r.ExitCode -eq 0 -and [IO.File]::ReadAllText($localConfig) -eq $original) "$($r.Output)$($r.Error)"
    $config = Get-Content -Raw $appConfig | ConvertFrom-Json
    Check 'steamvr: remove leaves only Steam''s manifest' ((@($config.manifest_paths) -join '|') -eq $steamManifest -and -not (Test-Path $vrManifestPath)) (Get-Content -Raw $appConfig)

    $original = Write-LocalConfig "`t`t`t`t`t`t`"LaunchOptions`"`t`t`"-dx12 -window`"`n"
    $r = Invoke-Launcher $L1 (@('--cli', 'steam-setup') + $steamArgs)
    $text = [IO.File]::ReadAllText($localConfig)
    $withFlags = '"' + ($expectedOption + ' -dx12 -window').Replace('\', '\\').Replace('"', '\"') + '"'
    Check 'steam: existing launch options kept after %command%' ($r.ExitCode -eq 0 -and $text.Contains($withFlags)) $text
    $r = Invoke-Launcher $L1 (@('--cli', 'steam-setup') + $steamArgs)
    Check 'steam: setting up twice changes nothing' ([IO.File]::ReadAllText($localConfig) -eq $text) ''
    $r = Invoke-Launcher $L1 (@('--cli', 'steam-remove') + $steamArgs)
    Check 'steam: remove restores the previous launch options exactly' ([IO.File]::ReadAllText($localConfig) -eq $original) [IO.File]::ReadAllText($localConfig)

    $original = Write-LocalConfig "`t`t`t`t`t`t`"LaunchOptions`"`t`t`"other.exe %command%`"`n"
    $r = Invoke-Launcher $L1 (@('--cli', 'steam-setup') + $steamArgs)
    Check 'steam: another wrapper in the launch options is not overwritten' ($r.ExitCode -eq 0 -and (Value $r 'steam_launch_option') -eq 'false' -and
        [IO.File]::ReadAllText($localConfig) -eq $original -and (Value $r 'result') -match 'already has a launch option') "$($r.Output)$($r.Error)"
    $app = (Get-Content -Raw $vrManifestPath | ConvertFrom-Json).applications[0]
    Check 'steamvr: without the launch option the tile runs the launcher with --vr-launch' ($app.launch_type -eq 'binary' -and
        $app.binary_path_windows -eq $stableExe -and $app.arguments -eq '--vr-launch') (Get-Content -Raw $vrManifestPath)
    Invoke-Launcher $L1 (@('--cli', 'steam-remove') + $steamArgs) | Out-Null

    # The launch decision without asking any runtime.
    $marker = Join-Path $script:LocalAppData 'DarktideVR\launcher\next-launch.txt'
    $r = Invoke-Launcher $L1 (@('--cli', 'decide', '--steam-launch-mode', 'flat') + $gameArgs)
    Check 'decide: "always flat" needs no headset check' ((Value $r 'decision') -eq 'flat') "$($r.Output)$($r.Error)"
    Set-Content -LiteralPath $marker -Value @('vr', [DateTime]::UtcNow.AddMinutes(-10).ToString('o'), 'C:\runtimes\steamxr_win64.json')
    $r = Invoke-Launcher $L1 (@('--cli', 'decide') + $gameArgs)
    Check 'decide: an old instruction has expired' ((Value $r 'decision') -eq 'flat' -and -not (Test-Path $marker)) $r.Output
    Set-Content -LiteralPath $marker -Value @('vr', [DateTime]::UtcNow.ToString('o'), 'C:\runtimes\steamxr_win64.json')
    $r = Invoke-Launcher $L1 (@('--cli', 'decide') + $gameArgs)
    Check 'decide: VR chosen from SteamVR uses SteamVR''s runtime' ((Value $r 'decision') -eq 'vr' -and (Value $r 'runtime_override') -eq 'C:\runtimes\steamxr_win64.json') $r.Output
    Set-Content -LiteralPath $marker -Value @('flat', [DateTime]::UtcNow.ToString('o'), '')
    $r = Invoke-Launcher $L1 (@('--cli', 'decide') + $gameArgs)
    Check 'decide: Play flat in the launcher wins' ((Value $r 'decision') -eq 'flat' -and (Value $r 'reason') -match 'Play flat') $r.Output
    Check 'decide: the instruction is used once' (-not (Test-Path $marker)) ''
    Invoke-Launcher $L1 (@('--cli', 'status', '--steam-launch-mode', 'auto') + $gameArgs) | Out-Null

    # What Steam runs: the game command passes through intact and the game
    # always starts, even when getting ready fails.
    $fakeGame = Join-Path $script:Work 'fake-game.ps1'
    $fakeOut = Join-Path $script:Work 'fake-game.txt'
    Set-Content -LiteralPath $fakeGame -Value "param([Parameter(ValueFromRemainingArguments)] `$rest)`n@(`$rest.Count) + `$rest + @(`"runtime=`$env:XR_RUNTIME_JSON`") | Set-Content -LiteralPath '$fakeOut'" -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $script:LocalAppData 'DarktideVR\launcher\next-launch.txt') -Value @('flat', [DateTime]::UtcNow.ToString('o'), '')
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $start = New-Object Diagnostics.ProcessStartInfo $L1
    $start.Arguments = '--steam-launch ' + (@($powershell, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $fakeGame, 'two words', 'quote"inside', 'C:\trailing dir\') |
        ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"' } else { $_ } }) -join ' '
    $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $start.EnvironmentVariables['LOCALAPPDATA'] = $script:LocalAppData
    $start.EnvironmentVariables['APPDATA'] = $script:RoamingAppData
    $process = [Diagnostics.Process]::Start($start)
    $exited = $process.WaitForExit(120000)
    $lines = if (Test-Path $fakeOut) { @(Get-Content -LiteralPath $fakeOut) } else { @() }
    Check 'steam launch: the game command starts with its arguments intact' ($exited -and $lines.Count -ge 4 -and $lines[0] -eq '3' -and
        $lines[1] -eq 'two words' -and $lines[2] -eq 'quote"inside' -and $lines[3] -eq 'C:\trailing dir\') ($lines -join ' | ')
    $state = Get-Content -Raw (Join-Path $script:LocalAppData 'DarktideVR\launcher\state.json') | ConvertFrom-Json
    Check 'steam launch: the choice is recorded for the window' ($state.last_launch -match 'flat') "$($state.last_launch)"

    # -- game updates, recovery and uninstall (mode script)
    if ($gameOpen) {
        Skip 'unsupported game build, recovery flat, uninstall' 'Darktide is running'
    } else {
        New-SyntheticExe $exe 2
        $r = Invoke-Launcher $L1 (@('--cli', 'status') + $gameArgs)
        Check 'game update: new executable reported unsupported' ((Value $r 'executable') -eq 'unsupported') $r.Output
        $r = Invoke-Launcher $L1 (@('--cli', 'vr') + $gameArgs)
        Check 'game update: Play in VR explains the wait' ($r.ExitCode -eq 1 -and $r.Error -match 'Darktide was updated') "$($r.Output)$($r.Error)"
        $r = Invoke-Launcher $L1 (@('--cli', 'flat') + $gameArgs)
        Check 'game update: Play flat still works and removes the proxy' ($r.ExitCode -eq 0 -and (Value $r 'd3d12_proxy') -eq 'absent' -and
            (Value $r 'load_order') -eq 'absent') "$($r.Output)$($r.Error)"
        New-SyntheticExe $exe 1361210

        # Steam launch in VR: VR mode switched on and the chosen runtime
        # handed to the game.
        Remove-Item -LiteralPath $fakeOut -ErrorAction SilentlyContinue
        Set-Content -LiteralPath $marker -Value @('vr', [DateTime]::UtcNow.ToString('o'), 'C:\runtimes\steamxr_win64.json')
        $process = [Diagnostics.Process]::Start($start)
        $exited = $process.WaitForExit(120000)
        $lines = if (Test-Path $fakeOut) { @(Get-Content -LiteralPath $fakeOut) } else { @() }
        $r = Invoke-Launcher $L1 (@('--cli', 'status') + $gameArgs)
        Check 'steam launch: VR mode on before the game starts' ($exited -and (Value $r 'vr_mode') -eq 'true' -and (Value $r 'executable') -eq 'patched') $r.Output
        Check 'steam launch: the game gets the chosen runtime' ($lines -contains 'runtime=C:\runtimes\steamxr_win64.json') ($lines -join ' | ')

        if ($ProbeRealRuntimes) {
            # Creates an OpenXR instance on the real runtimes (no session).
            $r = Invoke-Launcher $L1 (@('--cli', 'decide') + $gameArgs)
            Check 'decide: real runtimes answer one way or the other' ($r.ExitCode -eq 0 -and (Value $r 'decision') -in @('vr', 'flat')) "$($r.Output)$($r.Error)"
            Write-Host "     real headset check: $(Value $r 'decision') because $(Value $r 'reason')"
        } else {
            Skip 'real headset check' 'pass -ProbeRealRuntimes'
        }

        $r = Invoke-Launcher $L1 (@('--cli', 'vr') + $gameArgs)
        Remove-Item -LiteralPath (Join-Path $script:Game 'mods\darktidevr') -Recurse -Force
        $r = Invoke-Launcher $L1 (@('--cli', 'flat') + $gameArgs)
        Check 'recovery: flat restores from the cached package after the mod folder was deleted' ($r.ExitCode -eq 0 -and
            (Get-Sha256 $exe) -eq $script:ExeSha -and -not (Test-Path (Join-Path $script:Game 'binaries\d3d12.dll')) -and
            -not ((Get-Content (Join-Path $script:Game 'mods\mod_load_order.txt')) -contains 'darktidevr')) "$($r.Output)$($r.Error)"

        $r = Invoke-Launcher $L1 (@('--cli', 'vr') + $gameArgs)
        Check 'uninstall setup: VR on again (mod reinstalled)' ($r.ExitCode -eq 0 -and (Value $r 'vr_mode') -eq 'true') "$($r.Output)$($r.Error)"
        $r = Invoke-Launcher $L1 (@('--cli', 'uninstall', '--remove-mod-loader', '--remove-data') + $gameArgs)
        $after = Get-TreeHashes $script:Game
        $extra = @($after.Keys | Where-Object { -not $initialTree.ContainsKey($_) })
        $changed = @($initialTree.Keys | Where-Object { $after[$_] -ne $initialTree[$_] })
        Check 'uninstall: game folder back as it was, apart from the mod list' ($r.ExitCode -eq 0 -and $changed.Count -eq 0 -and
            ($extra -join ',') -eq 'mods\mod_load_order.txt') "exit=$($r.ExitCode) changed=$($changed -join ',') extra=$($extra -join ',') $($r.Error)"
        Check 'uninstall: launcher data removed' (-not (Test-Path (Join-Path $script:LocalAppData 'DarktideVR'))) ''
    }

    # -- the real GitHub API, read only: the launcher's own repository has no
    # release signed with this test key (and old ones carry no manifest).
    if ($SkipRealGitHub) {
        Skip 'real GitHub check' '-SkipRealGitHub'
    } else {
        $r = Invoke-Launcher $L1 @('--cli', 'check', '--game-root', $script:Game) -RealGitHub
        Check 'real GitHub: the launcher''s repository answers, nothing trusted by a test key' ($r.ExitCode -eq 0 -and
            (Value $r 'releases_seen') -ne $null -and (Value $r 'available') -eq 'none') "$($r.Output)$($r.Error)"
    }
} finally {
    if ($script:Server -and -not $script:Server.HasExited) { $script:Server.Kill() }
    if (-not $KeepWorkRoot) {
        Remove-Item -LiteralPath $script:Work -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        Write-Host "Work folder kept: $script:Work"
    }
}

Write-Host ''
Write-Host "passed=$script:Passed failed=$($script:Failed.Count) skipped=$($script:Skipped.Count)"
foreach ($name in $script:Failed) { Write-Host "  failed: $name" -ForegroundColor Red }
foreach ($name in $script:Skipped) { Write-Host "  skipped: $name" -ForegroundColor Yellow }
if ($script:Failed.Count -gt 0) { exit 1 }
exit 0
