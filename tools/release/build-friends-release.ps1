[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+$')][string] $Version,
    [string] $OutputDirectory,
    [switch] $AllowDirtyCandidate
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $root 'artifacts/friends-release' }
$output = [IO.Path]::GetFullPath($OutputDirectory)
[IO.Directory]::CreateDirectory($output) | Out-Null
Push-Location $root
try {
    # The archive digest pins both the build compiler and the shipped runtime.
    $spec = Import-PowerShellDataFile tools/dependencies/dxc-runtime.psd1
    $archive = Join-Path $root ('build/dependencies/dxc-' + $spec.Version + '.zip')
    [IO.Directory]::CreateDirectory((Split-Path -Parent $archive)) | Out-Null
    if (-not (Test-Path -LiteralPath $archive)) {
        Invoke-WebRequest -UseBasicParsing -Uri $spec.ArchiveUrl -OutFile $archive
    }
    if ((Get-FileHash -LiteralPath $archive).Hash -ne $spec.ArchiveSHA256) { throw 'DXC archive digest mismatch.' }
    & tools/dependencies/get-dxc-runtime.ps1 -ArchivePath $archive
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $compiler = Join-Path $root 'build/dependencies/dxc-tools'
    [IO.Directory]::CreateDirectory($compiler) | Out-Null
    $zip = [IO.Compression.ZipFile]::OpenRead($archive)
    try {
        foreach ($name in @('dxc.exe', 'dxcompiler.dll', 'dxil.dll')) {
            $entry = $zip.GetEntry("bin/x64/$name")
            if (-not $entry) { throw "Pinned DXC archive lacks $name" }
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, (Join-Path $compiler $name), $true)
        }
    } finally { $zip.Dispose() }
    & tools/lua/build-luajit.ps1
    & tools/stereo/test-darktide-lua-source.ps1
    & cmake --preset windows-vs2022
    if ($LASTEXITCODE) { throw 'Native configure failed.' }
    $targets = @('darktidevr_native_capture', 'darktidevr_d3d12_bootstrap', 'darktidevr-xr-harness',
        'darktidevr-frame-delivery-tests', 'darktidevr-viewer-process-tests',
        'darktidevr-native-original-ring-tests', 'darktidevr-shared-head-pose-tests')
    & cmake --build build/windows-vs2022 --config Release --target @targets --parallel 2
    if ($LASTEXITCODE) { throw 'Native build failed.' }
    & ctest --test-dir build/windows-vs2022 -C Release --output-on-failure -R '^(frame_delivery|viewer_process_identity|native_original_ring|shared_head_pose)$'
    if ($LASTEXITCODE) { throw 'Frame-delivery regression checks failed.' }
    & tools/stereo/build-melee-inertia.ps1
    & tools/stereo/build-particle-horizon-lock.ps1 -DxcPath (Join-Path $compiler 'dxc.exe')
    & tests/one-click-launcher/test-signing-environment.ps1
    & tests/one-click-launcher/test-launcher-offline.ps1 -WorkRoot (Join-Path $output 'launcher-tests') -KeepWorkRoot -SkipRealGitHub *> (Join-Path $output 'launcher-tests.log')
    if ($LASTEXITCODE) { throw "Launcher checks failed; see $output/launcher-tests.log" }
    & tools/release/build-launcher.ps1 -Version $Version -OutputDirectory $output
    $packageOptions = @{ OutputDirectory = (Join-Path $output 'packages'); ReleaseVersion = $Version }
    if (-not $AllowDirtyCandidate) {
        $provenance = Join-Path $output 'component-provenance.json'
        & tools/release/record-component-provenance.ps1 -SkipBuild -OutputPath $provenance
        $packageOptions.ComponentProvenancePath = $provenance
        $packageOptions.RequireComponentProvenance = $true
    }
    $packageOutput = @(& tools/release/build-runtime-package.ps1 @packageOptions)
    $package = @($packageOutput | Where-Object { $_.PSObject.Properties.Name -contains 'Archive' })
    if ($package.Count -ne 1) { throw 'Expected exactly one verified runtime package.' }
    $package = $package[0]
    $package | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $output 'package.json') -Encoding UTF8
    Write-Output "friends_release_built=$output"
} finally { Pop-Location }
