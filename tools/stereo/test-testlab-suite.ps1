[CmdletBinding()]
param(
    [string] $GameRoot='C:/Program Files (x86)/Steam/steamapps/common/Warhammer 40,000 DARKTIDE',
    [string] $OutputPath,
    [ValidateSet('raw','auto','knife','sword','axe','hammer')][string] $WeightProfile='raw',
    [ValidateSet('stock','physical')][string] $AttackMode='stock',
    [ValidateRange(.25,4)][double] $DurationScale=1,
    [ValidateRange(1,10)][int] $Repetitions=1,
    [switch] $TwoHand,
    [switch] $Heavy,
    [switch] $Trajectory,
    [switch] $Defense,
    [switch] $PushFollowup,
    [switch] $SupportOnly,
    [ValidateRange(5,60)][int] $CaseTimeoutSeconds=15
)
$ErrorActionPreference='Stop'
if ($AttackMode -eq 'physical' -and $WeightProfile -eq 'raw') {
    throw 'Select a native inertia profile for physical attacks; raw is the stock-window baseline.'
}
$send=Join-Path $PSScriptRoot 'send-testlab-command.ps1'
$modRoot=Join-Path $GameRoot 'mods/darktide_testlab'
if (-not $OutputPath) {
    $OutputPath=Join-Path $PSScriptRoot "../../artifacts/testlab-suite-$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')).json"
}
$cases=@(
    @{name='miss';scenario='whiff.tsv';expect_hit=$false;expect_sweeps=$true},
    @{name='idle';scenario='idle.tsv';expect_hit=$false;expect_sweeps=$false},
    @{name='hit';scenario='horizontal.tsv';expect_hit=$true;expect_sweeps=$true}
)
if ($AttackMode -eq 'physical') {
    $cases=@($cases[0],$cases[1],@{name='jiggle';scenario='jiggle.tsv';expect_hit=$false;expect_sweeps=$false},$cases[2])
}
if ($TwoHand) {
    if ($AttackMode -ne 'physical' -or $WeightProfile -eq 'raw') { throw 'Two-hand suite requires physical mode and a native inertia profile' }
    $cases+=@{name='two_hand';scenario='two_hand.tsv';expect_hit=$true;expect_sweeps=$true}
}
if ($Heavy -or $Defense -or $PushFollowup -or $SupportOnly) {
    if ($AttackMode -ne 'physical' -or $WeightProfile -eq 'raw') { throw 'Combat action cases require physical mode and a native inertia profile' }
    if ($Heavy) { $cases+=@{name='heavy';scenario='heavy.tsv';expect_hit=$true;expect_sweeps=$true} }
    if ($Defense) { $cases+=@{name='guard_push';scenario='guard_push.tsv';expect_hit=$false;expect_sweeps=$false} }
    if ($PushFollowup) { $cases+=@{name='push_followup';scenario='push_followup.tsv';breed='chaos_ogryn_gunner';expect_hit=$true;expect_sweeps=$true} }
    if ($SupportOnly) { $cases+=@{name='support_only';scenario='support_only.tsv';expect_hit=$true;expect_sweeps=$true} }
}
if ($Trajectory) {
    if ($AttackMode -ne 'physical') { throw 'Trajectory cases require physical mode' }
    foreach ($name in @('horizontal_mirrored','horizontal_up','horizontal_down','heavy_mirrored','heavy_up','heavy_down')) {
        $cases+=@{name=$name;scenario="$name.tsv";expect_hit=$true;expect_sweeps=$true}
    }
}
$results=[Collections.Generic.List[object]]::new()
function Send-Lab([string] $Command,[string] $Arguments='') {
    $receipt=& $send -Command $Command -Arguments $Arguments -GameRoot $GameRoot
    if (-not $receipt -or $receipt -notmatch '^([a-f0-9]+)\taccepted\t') { throw "Missing accepted receipt: $receipt" }
    return $Matches[1]
}
function Wait-LabResult([string] $Request) {
    $deadline=[DateTime]::UtcNow.AddSeconds($CaseTimeoutSeconds)
    $path=Join-Path $modRoot 'results.tsv'
    while ([DateTime]::UtcNow -lt $deadline) {
        if (Test-Path -LiteralPath $path) {
            foreach ($line in Get-Content -LiteralPath $path) {
                $fields=$line -split "`t",4
                if ($fields.Count -lt 4 -or $fields[1] -ne $Request) { continue }
                if ($fields[2] -eq 'result') {
                    if ($fields[3] -notmatch '(?:^| )outcome=complete(?: |$)' -or
                            $fields[3] -notmatch '(?:^| )health_valid=true(?: |$)') {
                        throw "Run $Request did not complete with valid final health: $($fields[3])"
                    }
                    $metrics=@{}
                    foreach ($entry in $fields[3] -split ' ') {
                        if ($entry -match '^([a-z_]+)=(-?[\d.]+)$') {
                            $metrics[$Matches[1]]=[double]::Parse($Matches[2],[Globalization.CultureInfo]::InvariantCulture)
                        }
                    }
                    foreach ($required in @('sweeps','hits','before','after','health_delta','native_damage','visual_samples')) {
                        if (-not $metrics.ContainsKey($required)) { throw "Incomplete result: $required" }
                    }
                    return $metrics
                }
                if ($fields[2] -in @('error','stop')) { throw "Run $Request ended without a result: $($fields[3])" }
            }
        }
        Start-Sleep -Milliseconds 100
    }
    throw "No terminal result for run $Request"
}
try {
    for ($repetition=1; $repetition -le $Repetitions; $repetition++) {
    foreach ($case in $cases) {
        [void](Send-Lab 'reset')
        # A poxwalker is knocked beyond the programmed follow-up's reach by
        # native push. Retain that whiff as evidence; use a heavier native
        # target to verify the follow-up's real contact/damage path.
        $breed=if ($case.ContainsKey('breed')) {$case.breed} else {'chaos_poxwalker'}
        [void](Send-Lab 'spawn' "$breed 1.5")
        $scaleText=$DurationScale.ToString('R',[Globalization.CultureInfo]::InvariantCulture)
        $caseMode=if ($case.name -like 'heavy*') {'physical-heavy'} else {$AttackMode}
        $arguments="$($case.scenario) $WeightProfile $caseMode $scaleText"
        $request=Send-Lab 'run' $arguments
        $metrics=Wait-LabResult $request
        $pass=if ($case.expect_hit) {
            $metrics.hits -gt 0 -and $metrics.native_damage -gt 0 -and $metrics.health_delta -gt 0
        } else { $metrics.hits -eq 0 -and $metrics.native_damage -eq 0 -and $metrics.health_delta -eq 0 }
        $pass=$pass -and $metrics.visual_samples -gt 0 -and (($metrics.sweeps -gt 0) -eq $case.expect_sweeps)
        if ($AttackMode -eq 'physical') {
            $expected=if ($case.expect_sweeps) {1} else {0}
            $pass=$pass -and $metrics.ContainsKey('strokes') -and $metrics.strokes -eq $expected
        }
        if ($case.name -in @('two_hand','support_only')) {
            $pass=$pass -and $metrics.support_frames -gt 0 -and $metrics.mass_min -eq $metrics.mass_max
        }
        $evidence=@{}
        if ($Trajectory -and $case.expect_sweeps) {
            $rows=@(Get-Content -LiteralPath (Join-Path $modRoot 'results.tsv') | Where-Object { ($_ -split "`t",4)[1] -eq $request })
            $evidence.selection=@($rows | Where-Object { ($_ -split "`t",4)[2] -eq 'trajectory_selected' })
            $evidence.context=@($rows | Where-Object { ($_ -split "`t",4)[2] -eq 'physical_context' })
            $evidence.native_damage=@($rows | Where-Object { ($_ -split "`t",4)[2] -eq 'native_damage' })
            $evidence.rejected=@($rows | Where-Object { ($_ -split "`t",4)[2] -eq 'trajectory_rejected' })
            $pass=$pass -and $evidence.selection.Count -eq 1 -and $evidence.rejected.Count -eq 0
        }
        if ($case.name -like 'heavy*' -or $case.name -in @('guard_push','push_followup','support_only')) {
            $lines=@(Get-Content -LiteralPath (Join-Path $modRoot 'results.tsv') | Where-Object { ($_ -split "`t",4)[1] -eq $request })
            $text=$lines -join "`n"
            if ($case.name -like 'heavy*') {
                $evidence.heavy_context=$text -match 'physical_context[\t][^\r\n]*accepted=true[^\r\n]*action=action_heavy_'
                $evidence.charge_start=$text -match '[\t]charge_start[\t]'
                $pass=$pass -and $evidence.heavy_context -and $evidence.charge_start
            } elseif ($case.name -eq 'support_only') {
                $evidence.support_intent=$text -match '[\t]stroke[\t][^\r\n]*intent_hand=support'
                $pass=$pass -and $evidence.support_intent
            } elseif ($case.name -eq 'push_followup') {
                $evidence.follow_context=$text -match 'physical_context[\t][^\r\n]*accepted=true[^\r\n]*action=action_pushfollow'
                $evidence.native_push=$text -match 'native_state[\t]action=action_push '
                $evidence.push_requests=@($lines | Where-Object {($_ -split "`t",4)[2] -eq 'push_requested'}).Count
                $pass=$pass -and $evidence.follow_context -and $evidence.native_push -and $evidence.push_requests -eq 1
            } else {
                $evidence.native_block=$text -match 'native_state[\t]action=action_block '
                $evidence.native_push=$text -match 'native_state[\t]action=action_push '
                $evidence.push_requests=@($lines | Where-Object {($_ -split "`t",4)[2] -eq 'push_requested'}).Count
                $stamina=@([regex]::Matches($text,'stamina=([0-9.]+)') | ForEach-Object {
                    [double]::Parse($_.Groups[1].Value,[Globalization.CultureInfo]::InvariantCulture)
                })
                $evidence.stamina_min=if ($stamina.Count) {($stamina | Measure-Object -Minimum).Minimum} else {-1}
                $evidence.stamina_max=if ($stamina.Count) {($stamina | Measure-Object -Maximum).Maximum} else {-1}
                # Push can have native damage depending on the weapon. Record it;
                # require native action/stamina evidence and zero melee strokes.
                $pass=$metrics.visual_samples -gt 0 -and $metrics.sweeps -eq 0 -and $metrics.strokes -eq 0 -and
                    $evidence.native_block -and $evidence.native_push -and $evidence.push_requests -eq 1 -and
                    $evidence.stamina_min -ge 0 -and $evidence.stamina_min -lt $evidence.stamina_max
            }
        }
        $results.Add([ordered]@{case=$case.name;repetition=$repetition;scenario=$case.scenario;request=$request;pass=$pass;metrics=$metrics;evidence=$evidence})
        if (-not $pass) { throw "Live case $($case.name) failed" }
    }
    }
} finally {
    $completed=$results.Count -eq $cases.Count*$Repetitions -and @($results | Where-Object {-not $_.pass}).Count -eq 0
    $folder=Split-Path ([IO.Path]::GetFullPath($OutputPath)) -Parent
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    [ordered]@{schema=1;captured_utc=[DateTime]::UtcNow.ToString('o');profile=$WeightProfile;attack_mode=$AttackMode;duration_scale=$DurationScale;repetitions=$Repetitions;pass=$completed;cases=$results.ToArray()} |
        ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding utf8
    try { [void](Send-Lab 'stop'); [void](Send-Lab 'reset') } catch { Write-Warning "Test cleanup failed: $_" }
}
Write-Output "testlab_live_suite=pass report=$([IO.Path]::GetFullPath($OutputPath))"
