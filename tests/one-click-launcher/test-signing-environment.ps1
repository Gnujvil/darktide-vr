Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../../tools/release/launcher-signing.ps1')
$name = 'DARKTIDEVR_TEST_SIGNING_KEY'
$previous = [Environment]::GetEnvironmentVariable($name)
try {
    $material = New-LauncherKeyMaterial
    [Environment]::SetEnvironmentVariable($name, ($material | ConvertTo-Json -Compress))
    $loaded = Read-LauncherKeyEnvironment $name
    $data = [Text.Encoding]::UTF8.GetBytes('friends release signing fixture')
    $signature = New-LauncherSignature $data $loaded
    $public = ConvertTo-LauncherPublicKeyLine $material
    if (-not (Test-LauncherSignature $data $signature $public)) { throw 'Environment-key signature did not verify.' }
    if (Test-LauncherSignature ([byte[]](1,2,3)) $signature $public) { throw 'Tampered manifest was accepted.' }
    [Environment]::SetEnvironmentVariable($name, '{"curve":"P-256","d":"invalid"}')
    $refused = $false
    try { Read-LauncherKeyEnvironment $name | Out-Null } catch { $refused = $true }
    if (-not $refused) { throw 'Malformed signing key was accepted.' }
    [Environment]::SetEnvironmentVariable($name, $null)
    $refused = $false
    try { Read-LauncherKeyEnvironment $name | Out-Null } catch { $refused = $true }
    if (-not $refused) { throw 'Missing signing key was accepted.' }
    Write-Output 'signing_environment=pass valid_signature tamper_refused malformed_refused missing_refused'
} finally { [Environment]::SetEnvironmentVariable($name, $previous) }
