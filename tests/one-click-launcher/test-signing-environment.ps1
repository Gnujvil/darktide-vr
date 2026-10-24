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
    $scratch = Join-Path ([IO.Path]::GetTempPath()) ('darktidevr-key-location-' + [Guid]::NewGuid().ToString('N'))
    $savedRoaming = $env:APPDATA
    $savedLocal = $env:LOCALAPPDATA
    $cachedDirectory = Join-Path $scratch 'Packages/OpenAI.Codex_fixture/LocalCache/Roaming/DarktideVR-release'
    $regularDirectory = Join-Path $scratch 'Roaming/DarktideVR-release'
    try {
        $env:APPDATA = Join-Path $scratch 'Roaming'
        $env:LOCALAPPDATA = $scratch
        [IO.Directory]::CreateDirectory($cachedDirectory) | Out-Null
        $cachedKey = Join-Path $cachedDirectory 'launcher-signing-key.dpapi'
        [IO.File]::WriteAllText($cachedKey, 'location fixture; no private material')
        if ((Get-DefaultLauncherKeyPath) -ne $cachedKey) { throw 'Packaged-app key was not found from normal PowerShell.' }
        [IO.Directory]::CreateDirectory($regularDirectory) | Out-Null
        $regularKey = Join-Path $regularDirectory 'launcher-signing-key.dpapi'
        [IO.File]::WriteAllText($regularKey, 'location fixture; no private material')
        if ((Get-DefaultLauncherKeyPath) -ne $regularKey) { throw 'Existing normal Roaming key must take precedence.' }
    } finally {
        $env:APPDATA = $savedRoaming
        $env:LOCALAPPDATA = $savedLocal
        # Delete only the two fixture files, then remove empty owned parents.
        foreach ($file in @((Join-Path $cachedDirectory 'launcher-signing-key.dpapi'),
                            (Join-Path $regularDirectory 'launcher-signing-key.dpapi'))) {
            if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
        }
        $directories = @(Get-ChildItem -LiteralPath $scratch -Directory -Recurse | Sort-Object { $_.FullName.Length } -Descending)
        foreach ($directory in $directories) { [IO.Directory]::Delete($directory.FullName, $false) }
        [IO.Directory]::Delete($scratch, $false)
    }
    Write-Output 'signing_environment=pass valid_signature tamper_refused malformed_refused missing_refused msix_key_location regular_key_precedence'
} finally { [Environment]::SetEnvironmentVariable($name, $previous) }
