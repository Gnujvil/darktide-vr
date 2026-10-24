[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Prepare','Launch','Restore','Inspect')][string] $Action,
    [string] $GameRoot='C:/Program Files (x86)/Steam/steamapps/common/Warhammer 40,000 DARKTIDE',
    [string] $SessionPath,
    [string] $Character='',
    [switch] $EmptyRange,
    [switch] $WaitForExit
)
$ErrorActionPreference='Stop'
$repoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$gameRootPath=[IO.Path]::GetFullPath($GameRoot)
$exe=Join-Path $gameRootPath 'binaries/Darktide.exe'
$settings=Join-Path $env:APPDATA 'Fatshark/Darktide/user_settings.config'
$loadOrder=Join-Path $gameRootPath 'mods/mod_load_order.txt'
function Assert-Closed {
    $running=@(Get-Process Darktide -ErrorAction SilentlyContinue | Where-Object {$_.Path -ieq $exe})
    if ($running.Count) { throw 'Close this Darktide installation before preparing or restoring its test profile.' }
}
if ($Character -match '[\r\n\t]') { throw 'Character name must fit on one line' }
if (-not $SessionPath) {
    if ($Action -notin @('Prepare','Launch')) { throw 'Specify the session receipt to inspect or restore' }
    $SessionPath=Join-Path $repoRoot "artifacts/testlab-sessions/$([guid]::NewGuid().ToString('N'))/session.json"
}
$SessionPath=[IO.Path]::GetFullPath($SessionPath)
$folder=Split-Path $SessionPath -Parent
if ($Action -eq 'Inspect') { Get-Content -LiteralPath $SessionPath -Raw; return }
function Save-Receipt($Receipt) {
    $pending="$SessionPath.pending"
    $Receipt | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $pending -Encoding utf8
    Move-Item -LiteralPath $pending -Destination $SessionPath -Force
}
function Restore-Profile {
    Assert-Closed
    $receipt=Get-Content -LiteralPath $SessionPath -Raw | ConvertFrom-Json
    if ($receipt.game_root -ine $gameRootPath) { throw 'Receipt belongs to a different game installation' }
    if ($receipt.restored) { return }
    Copy-Item -LiteralPath (Join-Path $folder 'user_settings.config') -Destination $settings -Force
    Copy-Item -LiteralPath (Join-Path $folder 'mod_load_order.txt') -Destination $loadOrder -Force
    $receipt.restored=$true
    Save-Receipt $receipt
}
if ($Action -eq 'Restore') { Restore-Profile; Write-Output "testlab_profile=restored receipt=$SessionPath"; return }
Assert-Closed
if (Test-Path -LiteralPath $SessionPath) { throw 'Use a fresh session receipt; an existing backup must not be replaced' }
if (-not (Test-Path -LiteralPath $exe)) { throw 'Darktide is not installed' }
$modSource=Join-Path $repoRoot 'mods/darktide_testlab'
$chunks=@(Get-ChildItem -LiteralPath $modSource -Filter '*.lua' -Recurse -File | ForEach-Object FullName)
$chunks+=Join-Path $modSource 'darktide_testlab.mod'
$canonical=@('darktidevr_melee_inertia.lua','darktidevr_melee_pose.lua','darktidevr_melee_strokes.lua',
    'darktidevr_melee_action_bridge.lua','darktidevr_melee_timing.lua','darktidevr_melee_volume.lua','darktidevr_melee_sweep_plan.lua',
    'darktidevr_melee_runtime.lua','darktidevr_melee_defense.lua','darktidevr_melee_weapons.lua','darktidevr_melee_tether.lua','darktidevr_melee_grip.lua',
    # The stock gesture route (run ... gesture) loads these three.
    'darktidevr_melee_contact.lua','darktidevr_melee_probe.lua','darktidevr_melee_gesture_aim.lua',
    # Data only: per-weapon sight and two-hand grip tables, reported by rangedsweep.
    'darktidevr_gun_sights.lua','darktidevr_two_hand_support.lua')
foreach($name in $canonical) { $chunks+=Join-Path $repoRoot "mods/darktidevr/scripts/mods/darktidevr/$name" }
& (Join-Path $repoRoot 'tools/lua/test-lua-syntax.ps1') -SourcePaths $chunks
$nativeRoot=Join-Path $repoRoot 'build/melee-inertia'
$native=Join-Path $nativeRoot 'darktidevr_melee_inertia.dll'
$buildStamp=Join-Path $nativeRoot 'build.json'
$rebuild=-not (Test-Path -LiteralPath $native) -or -not (Test-Path -LiteralPath $buildStamp)
if (-not $rebuild) {
    $stamp=Get-Content -LiteralPath $buildStamp -Raw | ConvertFrom-Json
    $rebuild=$stamp.abi -ne 4 -or $stamp.library_hash -ne (Get-FileHash -LiteralPath $native).Hash
    foreach($source in $stamp.sources.PSObject.Properties) {
        if ($source.Value -ne (Get-FileHash -LiteralPath (Join-Path $repoRoot $source.Name)).Hash) { $rebuild=$true }
    }
}
if ($rebuild) { & (Join-Path $repoRoot 'tools/stereo/build-melee-inertia.ps1') }
New-Item -ItemType Directory -Path $folder -Force | Out-Null
Copy-Item -LiteralPath $settings -Destination (Join-Path $folder 'user_settings.config')
Copy-Item -LiteralPath $loadOrder -Destination (Join-Path $folder 'mod_load_order.txt')
$receipt=[ordered]@{schema=1;created_utc=[DateTime]::UtcNow.ToString('o');game_root=$gameRootPath;
    restored=$false;process_id=$null;process_started_utc=$null;character=$Character}
Save-Receipt $receipt
try {
    $installed=Join-Path $gameRootPath 'mods/darktide_testlab'
    New-Item -ItemType Directory -Path $installed -Force | Out-Null
    Get-ChildItem -LiteralPath $modSource | Copy-Item -Destination $installed -Recurse -Force
    $luaRoot=Join-Path $installed 'scripts/mods/darktide_testlab'
    foreach($name in $canonical) {
        $alias=$name.Replace('darktidevr_','')
        Copy-Item -LiteralPath (Join-Path $repoRoot "mods/darktidevr/scripts/mods/darktidevr/$name") -Destination (Join-Path $luaRoot $alias) -Force
    }
    $bin=Join-Path $installed 'bin'; New-Item -ItemType Directory -Path $bin -Force | Out-Null
    Copy-Item -LiteralPath $native -Destination $bin -Force
    Copy-Item -LiteralPath (Join-Path $nativeRoot 'HEFT-LICENSE.txt') -Destination $bin -Force
    # A light desktop game for this session only (the receipt restores the
    # user's file): 1280x720 window, no ray tracing/DXR, AO, volumetrics or
    # upscaler, small shadow maps, quarter-resolution textures.
    $light=& {
        . (Join-Path $repoRoot 'tools/stereo/testlab-light-settings.ps1')
        Convert-TestlabLightSettings -Text (Get-Content -LiteralPath $settings -Raw) -Level light -Resolution 1280x720 `
            -NoUpscaler -DeveloperMode -Windowed
    }
    $text=[regex]::Replace($light.Text,'(?m)^(\s*vsync\s*=\s*)true','${1}false')
    [IO.File]::WriteAllText($settings,$text)
    [IO.File]::WriteAllText($loadOrder,"creature_spawner`ndarktide_testlab`n")
    & (Join-Path $gameRootPath 'tools/dtkit-patch.exe') --patch (Join-Path $gameRootPath 'bundle')
    if ($LASTEXITCODE) { throw 'Mod-loader patch failed' }
    $request=[guid]::NewGuid().ToString('N')
    $entryArguments=if ($EmptyRange) {"$Character --empty-range"} else {$Character}
    [IO.File]::WriteAllText((Join-Path $installed 'command.txt'),"$request enter $entryArguments`n")
    if ($Action -eq 'Prepare') { Write-Output "testlab_profile=prepared receipt=$SessionPath"; return }
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.FileName=$exe; $start.WorkingDirectory=Split-Path $exe -Parent; $start.UseShellExecute=$false
    foreach ($argument in @('-eac-untrusted','--bundle-dir','../bundle','--ini','settings')) { $start.ArgumentList.Add($argument) }
    $start.Environment['SteamAppId']='1361210'; $start.Environment['SteamGameId']='1361210'
    $game=[Diagnostics.Process]::Start($start)
    $receipt.process_id=$game.Id; $receipt.process_started_utc=$game.StartTime.ToUniversalTime().ToString('o')
    Save-Receipt $receipt
    Write-Output "testlab_process=$($game.Id) receipt=$SessionPath"
    if ($WaitForExit) {
        try { $game.WaitForExit() } finally { Restore-Profile }
        Write-Output 'testlab_profile=restored'
    }
} catch {
    $failure=$_
    try { Restore-Profile } catch { Write-Warning "Profile restore still required using receipt $SessionPath : $_" }
    throw $failure
}
