[CmdletBinding()]
param(
    # Where the private key goes. Default: %APPDATA%\DarktideVR-release,
    # DPAPI-protected for this Windows user. Never inside the repository.
    [string] $KeyFile,

    # The public half, embedded into player builds of the launcher.
    [string] $PublicKeyFile,

    # Also write a password-protected copy (keep it off this machine, e.g. in
    # a password manager): without the key, launchers already handed out
    # can't accept new releases.
    [string] $ExportBackup,

    # Instead of creating a key, restore one from such a backup.
    [string] $ImportBackup,

    # Plain key file for automated tests; never for real releases.
    [switch] $Unprotected,

    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'launcher-signing.ps1')

if (-not $KeyFile) { $KeyFile = Get-DefaultLauncherKeyPath }
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if (-not $PublicKeyFile) { $PublicKeyFile = Join-Path $repoRoot 'launcher/release-signing-key.pub' }
if ([IO.Path]::GetFullPath($KeyFile).StartsWith($repoRoot, [StringComparison]::OrdinalIgnoreCase) -and -not $Unprotected) {
    throw "Refusing to write a private key inside the repository: $KeyFile"
}
if ((Test-Path -LiteralPath $KeyFile) -and -not $Force) {
    throw "A key already exists at $KeyFile. Replacing it would lock out every launcher already handed out; pass -Force only if that is intended."
}

if ($ImportBackup) {
    $material = Read-LauncherKeyFile $ImportBackup
} else {
    $material = New-LauncherKeyMaterial
}
Write-LauncherKeyFile $KeyFile $material -Unprotected:$Unprotected
$publicLine = ConvertTo-LauncherPublicKeyLine $material
$publicText = "# Darktide VR launcher release key (ECDSA P-256, base64 X||Y). Public; safe to commit.`n$publicLine`n"
New-Item -ItemType Directory -Path (Split-Path -Parent $PublicKeyFile) -Force | Out-Null
[IO.File]::WriteAllText($PublicKeyFile, $publicText, [Text.UTF8Encoding]::new($false))

if ($ExportBackup) {
    $password = Read-Host -AsSecureString 'Backup password'
    $again = Read-Host -AsSecureString 'Repeat it'
    $a = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($password))
    $b = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($again))
    if ($a -ne $b) { throw 'The passwords differ; no backup written.' }
    Write-LauncherKeyBackup $ExportBackup $material $password
    Write-Output "backup=$ExportBackup"
}

Write-Output "private_key=$KeyFile"
Write-Output "public_key_file=$PublicKeyFile"
Write-Output "public_key=$publicLine"
