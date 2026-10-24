[CmdletBinding()]
param(
    [string] $GameRoot='C:/Program Files (x86)/Steam/steamapps/common/Warhammer 40,000 DARKTIDE',
    [string] $OutputPath,
    [ValidateSet('control','continuous','switch','special','heavy','release')][string[]] $Cases=@('control','continuous','switch','special','heavy','release'),
    # gesture: contact presses (the mission default); gesture-swing: a press on every stroke.
    [ValidateSet('gesture','gesture-swing')][string] $SwingMode='gesture',
    [ValidateSet('auto','knife','sword','axe','hammer')][string] $WeightProfile='auto',
    # Any game breed name; the testlab refuses unknown ones and, without
    # -Force, ones whose unit this Psykhanium has not loaded.
    [ValidatePattern('^[a-z0-9_]+$')][string] $Breed='chaos_poxwalker',
    [ValidateRange(.8,4)][double] $Distance=1.5,
    # Hold each target at its spawn pose, immortal and unstaggerable, so every
    # swing of a case has something in reach (the testlab's anchored spawn).
    [switch] $Anchored,
    [switch] $Force,
    [ValidateRange(10,90)][int] $CaseTimeoutSeconds=30,
    # Throw when any case misses its expectation (default: report only).
    [switch] $Strict
)
# Runs the headset failure cases on the desktop testlab (Psykhanium, melee
# weapon wielded, testlab-desktop-session.ps1 Launch) and reads each run's
# damage ledger. Scenarios: tools/stereo/generate-testlab-scenarios.py.
$ErrorActionPreference='Stop'
$send=Join-Path $PSScriptRoot 'send-testlab-command.ps1'
$modRoot=Join-Path $GameRoot 'mods/darktide_testlab'
$resultsPath=Join-Path $modRoot 'results.tsv'
if (-not $OutputPath) {
    $OutputPath=Join-Path $PSScriptRoot "../../artifacts/testlab-failure-cases-$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')).json"
}
$definitions=[ordered]@{
    control=@{scenario='touch_repeat.tsv';mode=$SwingMode;expect='every press damages (1.15 s pauses: the control)'}
    continuous=@{scenario='touch_continuous.tsv';mode=$SwingMode;expect='every press damages'}
    switch=@{scenario='touch_switch_continuous.tsv';mode=$SwingMode;switch=$true;expect='every press damages, right after a weapon switch'}
    special=@{scenario='touch_special_continuous.tsv';mode=$SwingMode;expect='every press damages after the special'}
    heavy=@{scenario='touch_heavy_release.tsv';mode='gesture-heavy';expect='every press answered, 3 damaging heavy attacks'}
    release=@{scenario='touch_trigger_release.tsv';mode='gesture-heavy';expect='every let-go answered by an attack, no attack after a cancel, the 2 swings damage'}
}
function Send-Lab([string] $Command,[string] $Arguments='') {
    $receipt=& $send -Command $Command -Arguments $Arguments -GameRoot $GameRoot
    if (-not $receipt -or $receipt -notmatch '^([a-f0-9]+)\taccepted\t') { throw "Missing accepted receipt: $receipt" }
    return $Matches[1]
}
function Get-LabRows([string] $Request) {
    if (-not (Test-Path -LiteralPath $resultsPath)) { return @() }
    @(foreach ($line in [IO.File]::ReadAllLines($resultsPath)) {
        $fields=$line -split "`t",4
        if ($fields.Count -eq 4 -and $fields[1] -eq $Request) { [pscustomobject]@{kind=$fields[2];detail=$fields[3]} }
    })
}
function Wait-LabRow([string] $Request,[string[]] $Kinds,[int] $Seconds) {
    $deadline=[DateTime]::UtcNow.AddSeconds($Seconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $row=@(Get-LabRows $Request | Where-Object { $_.kind -in $Kinds }) | Select-Object -First 1
        if ($row) { return $row }
        Start-Sleep -Milliseconds 100
    }
    return $null
}
function ConvertFrom-Pairs([string] $Text) {
    $out=[ordered]@{}
    foreach ($pair in $Text -split ' ') {
        if ($pair -match '^([a-z_]+)=(-?[\d.]+)$') {
            $out[$Matches[1]]=[double]::Parse($Matches[2],[Globalization.CultureInfo]::InvariantCulture)
        } elseif ($pair -match '^([a-z_]+)=(.*)$') { $out[$Matches[1]]=$Matches[2] }
    }
    $out
}
function Test-Expectation([string] $Name,$Summary) {
    if (-not $Summary) { return $false }
    switch ($Name) {
        # The trigger is the attack button (22 October): a let-go fires the charge.
        'heavy' { return $Summary.heavy -ge 3 -and $Summary.presses_no_attack -eq 0 -and $Summary.attacks_damaged -ge 3 }
        'release' { return $Summary.presses_no_attack -eq 0 -and $Summary.cancelled_attacked -eq 0 -and
            $Summary.presses_damaged -ge 2 }
        default {
            # A press on every stroke also presses on misses: report only.
            if ($SwingMode -eq 'gesture-swing') { return $Summary.presses -gt 0 }
            return $Summary.presses -gt 0 -and $Summary.presses_no_damage -eq 0
        }
    }
}
$results=[Collections.Generic.List[object]]::new()
try {
    foreach ($name in $Cases) {
        $case=$definitions[$name]
        [void](Send-Lab 'stop')
        [void](Send-Lab 'reset')
        $spawnFlags=@();if($Anchored){$spawnFlags+='anchored'};if($Force){$spawnFlags+='force'}
        [void](Send-Lab 'spawn' (("$Breed {0} "+($spawnFlags -join ' ')) -f $Distance.ToString('R',[Globalization.CultureInfo]::InvariantCulture)).Trim())
        $prelude=[ordered]@{}
        if ($case.switch) {
            # A run aborts on any wielded-slot change: switch away and back, then run at once.
            $away=Send-Lab 'wield' 'secondary'
            $row=Wait-LabRow $away @('wield_complete','wield_timeout') 5
            $prelude.away=if ($row) {"$($row.kind) $($row.detail)"} else {'unobserved'}
            Start-Sleep -Milliseconds 1200
            [void](Send-Lab 'wield' 'primary')
        }
        $request=$null
        $runArguments="$($case.scenario) $WeightProfile $($case.mode)"
        for ($attempt=1; -not $request; $attempt++) {
            try { $request=Send-Lab 'run' $runArguments }
            catch {
                # Straight after a wield press the slot may not have changed yet.
                if (-not $case.switch -or $attempt -ge 10) { throw }
                Start-Sleep -Milliseconds 100
            }
        }
        $prelude.run_attempts=$attempt-1
        $terminal=Wait-LabRow $request @('result') $CaseTimeoutSeconds
        if (-not $terminal) { throw "No result for $name run $request" }
        $rows=Get-LabRows $request
        $summaryRow=@($rows | Where-Object kind -eq 'damage_summary') | Select-Object -Last 1
        $summary=if ($summaryRow) { ConvertFrom-Pairs $summaryRow.detail } else { $null }
        $metrics=ConvertFrom-Pairs $terminal.detail
        $counts=[ordered]@{}
        foreach ($kind in @('stroke','gesture_armed','gesture_contact','gesture_whiff','charge_start','charge_cancel','interrupt','damage_hit')) {
            $counts[$kind]=@($rows | Where-Object kind -eq $kind).Count
        }
        $ok=Test-Expectation $name $summary
        $results.Add([ordered]@{case=$name;scenario=$case.scenario;mode=$case.mode;request=$request;expectation=$case.expect;ok=$ok;
            outcome=$metrics.outcome;reason=$metrics.reason;summary=$summary;counts=$counts;prelude=$prelude})
        Write-Output ("{0,-10} ok={1,-5} presses={2} damaged={3} no_attack={4} empty={5} cancelled={6}/{7} attacks={8} unpressed={9} strokes={10} request={11}" -f
            $name,$ok,$summary.presses,$summary.presses_damaged,$summary.presses_no_attack,$summary.presses_attack_no_damage,
            $summary.cancelled,$summary.cancelled_attacked,$summary.attacks,$summary.attacks_unpressed,$counts.stroke,$request)
    }
} finally {
    $folder=Split-Path ([IO.Path]::GetFullPath($OutputPath)) -Parent
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    [ordered]@{schema=1;captured_utc=[DateTime]::UtcNow.ToString('o');swing_mode=$SwingMode;profile=$WeightProfile;breed=$Breed;anchored=[bool]$Anchored;
        distance=$Distance;cases=$results.ToArray()} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $OutputPath -Encoding utf8
    try { [void](Send-Lab 'stop'); [void](Send-Lab 'reset') } catch { Write-Warning "Test cleanup failed: $_" }
}
$missed=@($results | Where-Object { -not $_.ok })
Write-Output "testlab_failure_cases=$(if ($missed.Count) {'expectations_missed'} else {'pass'}) missed=$($missed.Count) report=$([IO.Path]::GetFullPath($OutputPath))"
if ($Strict -and $missed.Count) { throw "Expectations missed: $(($missed | ForEach-Object case) -join ', ')" }
