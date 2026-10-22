[CmdletBinding()]
param(
    [string] $GameRoot='C:/Program Files (x86)/Steam/steamapps/common/Warhammer 40,000 DARKTIDE',
    [Parameter(Mandatory)][string] $OutputPath
)
$ErrorActionPreference='Stop'
$send=Join-Path $PSScriptRoot 'send-testlab-command.ps1'
$resultsPath=Join-Path $GameRoot 'mods/darktide_testlab/results.tsv'
$cases=[Collections.Generic.List[object]]::new()
$failure=$null
function Send-Lab([string] $Verb,[string] $Arguments='') {
    $receipt=& $send -Command $Verb -Arguments $Arguments -GameRoot $GameRoot
    if ($receipt -notmatch '^([a-f0-9]+)\taccepted\t') { throw "Missing accepted receipt: $receipt" }
    return $Matches[1]
}
function Rows([string] $Id) {
    return @(Get-Content -LiteralPath $resultsPath | Where-Object {($_ -split "`t",4)[1] -eq $Id})
}
function Wait-Terminal([string] $Id) {
    $deadline=[DateTime]::UtcNow.AddSeconds(18)
    while ([DateTime]::UtcNow -lt $deadline) {
        $rows=Rows $Id
        if (@($rows | Where-Object {($_ -split "`t",4)[2] -eq 'result'}).Count) { return $rows }
        Start-Sleep -Milliseconds 100
    }
    throw "No terminal result: $Id"
}
function Metric([string] $Row,[string] $Key) {
    if ($Row -match "(?:^|\s)$Key=([^\s]+)") { return $Matches[1] }
    return $null
}
try {
    [void](Send-Lab 'reset')
    [void](Send-Lab 'group' 'chaos_poxwalker 3 1.5 0.45')
    $request=Send-Lab 'run' 'horizontal.tsv auto physical'
    $rows=Wait-Terminal $request
    $targets=@($rows | Where-Object {($_ -split "`t",4)[2] -eq 'target_result'})
    $damaged=@($targets | Where-Object {
        (Metric $_ 'health_valid') -eq 'true' -and [double](Metric $_ 'health_delta') -gt 0
    }).Count
    $cases.Add([ordered]@{case='owned_group_cleave';request=$request;targets=$targets.Count;damaged_targets=$damaged;
        multi_target_damage_observed=($damaged -ge 2);rows=$rows})
    foreach ($scenario in @('incoming_idle.tsv','guard_hold.tsv')) {
        $entry=[ordered]@{case=$scenario;request=$null;threat_request=$null;error=$null;rows=@();threat_rows=@()}
        try {
            [void](Send-Lab 'reset')
            [void](Send-Lab 'attacker' '1.5')
            $entry.request=Send-Lab 'run' "$scenario auto physical"
            Start-Sleep -Milliseconds 500
            $entry.threat_request=Send-Lab 'threat' '6'
            $entry.rows=Wait-Terminal $entry.request
            $entry.threat_rows=Rows $entry.threat_request
        } catch {
            $entry.error=$_.Exception.Message
            if ($entry.request) { $entry.rows=Rows $entry.request }
        } finally {
            [void](Send-Lab 'stop')
            if ($entry.threat_request) { $entry.threat_rows=Rows $entry.threat_request }
        }
        $summary=@($entry.rows | Where-Object {($_ -split "`t",4)[2] -eq 'incoming_result'}) | Select-Object -Last 1
        $entry.incoming_attacks=if ($summary) {Metric $summary 'attacks'} else {$null}
        $entry.blocked=if ($summary) {Metric $summary 'blocked'} else {$null}
        $entry.health_delta=if ($summary) {Metric $summary 'health_delta'} else {$null}
        $entry.toughness_delta=if ($summary) {Metric $summary 'toughness_delta'} else {$null}
        $entry.restored=@($entry.threat_rows | Where-Object {($_ -split "`t",4)[2] -eq 'threat_restored'}).Count -eq 1
        $cases.Add($entry)
    }
} catch {
    $failure=$_.Exception.Message
    throw
} finally {
    try { [void](Send-Lab 'stop');[void](Send-Lab 'reset') } catch { Write-Warning "Final cleanup not acknowledged: $_" }
    $folder=Split-Path ([IO.Path]::GetFullPath($OutputPath)) -Parent
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    [ordered]@{schema=1;created_utc=[DateTime]::UtcNow.ToString('o');failure=$failure;cases=@($cases.ToArray());
        note='Observed outcomes only; queued proc callbacks are not proof of every buff effect. No synthesized damage.'} |
        ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $OutputPath -Encoding utf8
}
Write-Output "combat_observation_report=$OutputPath"
