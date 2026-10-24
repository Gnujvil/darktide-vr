# Shared helpers for the launcher's release signing key (ECDSA P-256).
# Dot-source it; Windows PowerShell 5.1 (.NET Framework 4.7+) is enough.
#
# Key files never belong in the repository. The default lives under
# %APPDATA%\DarktideVR-release and is protected with Windows DPAPI for the
# current user, so the file alone is useless on another account or machine.
# A password-protected backup (-ExportBackup on new-launcher-signing-key.ps1)
# is what survives a Windows reinstall: without the key, launchers already
# handed out can't accept new releases and friends must download a new exe.

Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Security

$script:LauncherKeyHeaderDpapi = 'darktidevr-launcher-key-dpapi-v1'
$script:LauncherKeyHeaderPlain = 'darktidevr-launcher-key-plain-v1'
$script:LauncherKeyHeaderBackup = 'darktidevr-launcher-key-backup-v1'

function Get-DefaultLauncherKeyPath {
    $regular = Join-Path $env:APPDATA 'DarktideVR-release\launcher-signing-key.dpapi'
    if (Test-Path -LiteralPath $regular -PathType Leaf) { return $regular }
    # A packaged Codex process virtualizes Roaming into its MSIX LocalCache.
    # The owner's ordinary PowerShell must find that same existing key rather
    # than generate a second identity that installed launchers would not trust.
    $packages = Join-Path $env:LOCALAPPDATA 'Packages'
    $cached = @(Get-ChildItem -LiteralPath $packages -Directory -Filter 'OpenAI.Codex_*' -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName 'LocalCache/Roaming/DarktideVR-release/launcher-signing-key.dpapi' } |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
    if ($cached.Count -eq 1) { return $cached[0] }
    if ($cached.Count -gt 1) { throw 'Multiple cached signing keys found; specify the existing key with -KeyFile.' }
    return $regular
}

# GitHub Actions injects this value only into the signing step. Keep it in
# memory; never write an unprotected release key into the checkout or logs.
function Read-LauncherKeyEnvironment([string] $Name) {
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) { throw "Signing environment variable is missing: $Name" }
    try {
        $material = $value | ConvertFrom-Json
        if ($material.curve -cne 'P-256') { throw 'curve' }
        foreach ($field in @('d', 'x', 'y')) {
            if ([Convert]::FromBase64String([string]$material.$field).Length -ne 32) { throw 'length' }
        }
        $ecdsa = New-LauncherEcdsa $material
        $ecdsa.Dispose()
        return $material
    } catch { throw "Invalid P-256 signing material in environment variable $Name" }
}

function New-LauncherKeyMaterial {
    $ecdsa = [Security.Cryptography.ECDsa]::Create([Security.Cryptography.ECCurve+NamedCurves]::nistP256)
    try {
        $p = $ecdsa.ExportParameters($true)
        return [ordered]@{
            curve = 'P-256'
            d = [Convert]::ToBase64String($p.D)
            x = [Convert]::ToBase64String($p.Q.X)
            y = [Convert]::ToBase64String($p.Q.Y)
        }
    } finally {
        $ecdsa.Dispose()
    }
}

function ConvertTo-LauncherPublicKeyLine($Material) {
    $xy = [byte[]]([Convert]::FromBase64String($Material.x) + [Convert]::FromBase64String($Material.y))
    return [Convert]::ToBase64String($xy)
}

function Write-LauncherKeyFile([string] $Path, $Material, [switch] $Unprotected) {
    $json = [Text.Encoding]::UTF8.GetBytes(($Material | ConvertTo-Json -Compress))
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    if ($Unprotected) {
        $text = $script:LauncherKeyHeaderPlain + "`n" + [Convert]::ToBase64String($json)
    } else {
        $protected = [Security.Cryptography.ProtectedData]::Protect($json, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
        $text = $script:LauncherKeyHeaderDpapi + "`n" + [Convert]::ToBase64String($protected)
    }
    [IO.File]::WriteAllText($Path, $text + "`n", [Text.UTF8Encoding]::new($false))
}

function Get-PasswordKey([Security.SecureString] $Password, [byte[]] $Salt) {
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password))
    $derive = New-Object Security.Cryptography.Rfc2898DeriveBytes -ArgumentList $plain, $Salt, 300000, ([Security.Cryptography.HashAlgorithmName]::SHA256)
    try { return $derive.GetBytes(64) } finally { $derive.Dispose() }
}

# AES-256-CBC with an HMAC-SHA256 over salt, IV and ciphertext.
function Write-LauncherKeyBackup([string] $Path, $Material, [Security.SecureString] $Password) {
    $json = [Text.Encoding]::UTF8.GetBytes(($Material | ConvertTo-Json -Compress))
    $salt = New-Object byte[] 16; $iv = New-Object byte[] 16
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create(); $rng.GetBytes($salt); $rng.GetBytes($iv); $rng.Dispose()
    $keys = Get-PasswordKey $Password $salt
    $aes = [Security.Cryptography.Aes]::Create(); $aes.Key = $keys[0..31]; $aes.IV = $iv
    $cipher = $aes.CreateEncryptor().TransformFinalBlock($json, 0, $json.Length); $aes.Dispose()
    $hmac = New-Object Security.Cryptography.HMACSHA256 -ArgumentList (,[byte[]]$keys[32..63])
    $tag = $hmac.ComputeHash([byte[]]($salt + $iv + $cipher)); $hmac.Dispose()
    $text = $script:LauncherKeyHeaderBackup + "`n" + (([Convert]::ToBase64String($salt), [Convert]::ToBase64String($iv), [Convert]::ToBase64String($cipher), [Convert]::ToBase64String($tag)) -join "`n")
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [IO.File]::WriteAllText($Path, $text + "`n", [Text.UTF8Encoding]::new($false))
}

function Read-LauncherKeyFile([string] $Path, [Security.SecureString] $Password) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Launcher signing key not found: $Path (create one with tools/release/new-launcher-signing-key.ps1)"
    }
    $lines = @(Get-Content -LiteralPath $Path | Where-Object { $_.Trim() })
    switch ($lines[0].Trim()) {
        $script:LauncherKeyHeaderDpapi {
            $json = [Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($lines[1]), $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
        }
        $script:LauncherKeyHeaderPlain {
            Write-Warning "Signing with an unprotected key file ($Path). That is for tests only."
            $json = [Convert]::FromBase64String($lines[1])
        }
        $script:LauncherKeyHeaderBackup {
            if (-not $Password) { $Password = Read-Host -AsSecureString "Password for $Path" }
            $salt = [Convert]::FromBase64String($lines[1]); $iv = [Convert]::FromBase64String($lines[2])
            $cipher = [Convert]::FromBase64String($lines[3]); $tag = [Convert]::FromBase64String($lines[4])
            $keys = Get-PasswordKey $Password $salt
            $hmac = New-Object Security.Cryptography.HMACSHA256 -ArgumentList (,[byte[]]$keys[32..63])
            $expected = $hmac.ComputeHash([byte[]]($salt + $iv + $cipher)); $hmac.Dispose()
            if ([Convert]::ToBase64String($expected) -ne [Convert]::ToBase64String($tag)) { throw 'Wrong password, or the backup is damaged.' }
            $aes = [Security.Cryptography.Aes]::Create(); $aes.Key = $keys[0..31]; $aes.IV = $iv
            $json = $aes.CreateDecryptor().TransformFinalBlock($cipher, 0, $cipher.Length); $aes.Dispose()
        }
        default { throw "Not a launcher signing key file: $Path" }
    }
    $material = [Text.Encoding]::UTF8.GetString($json) | ConvertFrom-Json
    if ($material.curve -ne 'P-256') { throw "Unsupported key curve in $Path" }
    return $material
}

function New-LauncherEcdsa($Material, [switch] $PublicOnly) {
    $p = New-Object Security.Cryptography.ECParameters
    $p.Curve = [Security.Cryptography.ECCurve+NamedCurves]::nistP256
    $q = New-Object Security.Cryptography.ECPoint
    $q.X = [Convert]::FromBase64String($Material.x)
    $q.Y = [Convert]::FromBase64String($Material.y)
    $p.Q = $q
    if (-not $PublicOnly) { $p.D = [Convert]::FromBase64String($Material.d) }
    return [Security.Cryptography.ECDsa]::Create($p)
}

# Base64 of the 64-byte r||s signature over the exact bytes.
function New-LauncherSignature([byte[]] $Data, $Material) {
    $ecdsa = New-LauncherEcdsa $Material
    try { return [Convert]::ToBase64String($ecdsa.SignData($Data, [Security.Cryptography.HashAlgorithmName]::SHA256)) }
    finally { $ecdsa.Dispose() }
}

function Test-LauncherSignature([byte[]] $Data, [string] $Signature, [string] $PublicKeyLine) {
    $xy = [Convert]::FromBase64String($PublicKeyLine)
    $material = @{ x = [Convert]::ToBase64String($xy[0..31]); y = [Convert]::ToBase64String($xy[32..63]) }
    $ecdsa = New-LauncherEcdsa $material -PublicOnly
    try { return $ecdsa.VerifyData($Data, [Convert]::FromBase64String($Signature.Trim()), [Security.Cryptography.HashAlgorithmName]::SHA256) }
    finally { $ecdsa.Dispose() }
}
