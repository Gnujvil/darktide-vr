[CmdletBinding()]
param(
    [string] $Version = '0.1.0',

    # The release public key the launcher will trust. A player build must
    # embed the real one (launcher\release-signing-key.pub).
    [string] $PublicKeyFile,

    [string] $OutputDirectory,

    [switch] $AllowNoKey
)

# Builds DarktideVR-Launcher.exe (a single exe; .NET Framework 4.8 is part of
# Windows 10 1903+ and Windows 11) and prints its size and SHA-256.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$project = Join-Path $repoRoot 'launcher\DarktideVR.Launcher.csproj'
if (-not $PublicKeyFile) { $PublicKeyFile = Join-Path $repoRoot 'launcher\release-signing-key.pub' }
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repoRoot 'artifacts\launcher' }
if (-not (Test-Path -LiteralPath $PublicKeyFile -PathType Leaf)) {
    if (-not $AllowNoKey) { throw "No release public key at $PublicKeyFile. Create one with tools/release/new-launcher-signing-key.ps1, or pass -AllowNoKey for a build that trusts no update." }
    $PublicKeyFile = Join-Path $env:TEMP 'darktidevr-no-key.pub'
    Set-Content -LiteralPath $PublicKeyFile -Value '# no key' -Encoding ascii
}
$PublicKeyFile = (Resolve-Path -LiteralPath $PublicKeyFile).Path

$dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
if (-not $dotnet) { throw 'The .NET SDK (dotnet) is required to build the launcher.' }

& $dotnet.Source build $project -c Release --no-incremental -nologo -v minimal "-p:Version=$Version" "-p:ReleasePublicKeyFile=$PublicKeyFile"
if ($LASTEXITCODE -ne 0) { throw "dotnet build failed ($LASTEXITCODE)." }

$built = Join-Path $repoRoot 'launcher\bin\Release\net48\DarktideVR-Launcher.exe'
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$output = Join-Path $OutputDirectory 'DarktideVR-Launcher.exe'
Copy-Item -LiteralPath $built -Destination $output -Force
$hash = (Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Output "launcher=$output"
Write-Output "version=$Version"
Write-Output "bytes=$((Get-Item -LiteralPath $output).Length)"
Write-Output "sha256=$hash"
