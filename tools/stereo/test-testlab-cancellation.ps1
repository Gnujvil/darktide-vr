[CmdletBinding()]
param(
    [string] $GameRoot='C:/Program Files (x86)/Steam/steamapps/common/Warhammer 40,000 DARKTIDE',
    [Parameter(Mandatory)][string] $OutputPath
)
$ErrorActionPreference='Stop'
$send=Join-Path $PSScriptRoot 'send-testlab-command.ps1'
$log=Join-Path $GameRoot 'mods/darktide_testlab/results.tsv'
$results=[Collections.Generic.List[object]]::new()
function Send-Lab([string] $Command,[string] $Arguments='') {
    $receipt=& $send -Command $Command -Arguments $Arguments -GameRoot $GameRoot
    if ($receipt -notmatch '^([a-f0-9]+)\taccepted\t') {throw "Missing accepted receipt: $receipt"}
    return $Matches[1]
}
function Lines-For([string] $Request) {
    return @(Get-Content -LiteralPath $log | Where-Object {($_ -split "`t",3)[1] -eq $Request})
}
try {
    foreach($command in @('stop','recenter','reload')) {
        [void](Send-Lab 'reset')
        [void](Send-Lab 'spawn' 'chaos_poxwalker 1.5')
        $request=Send-Lab 'run' 'whiff.tsv hammer physical'
        $deadline=[DateTime]::UtcNow.AddSeconds(5)
        $context=$null
        do {
            $context=Lines-For $request | Where-Object {$_ -match "`tphysical_context`taccepted=true"} | Select-Object -First 1
            if($context) {break}
            Start-Sleep -Milliseconds 20
        } while([DateTime]::UtcNow -lt $deadline)
        if(-not $context) {throw "No native physical context for $command cancellation"}
        [void](Send-Lab $command)
        # Past the authored damage-window deadline: a leftover action must
        # neither hit the front target nor survive removal of the Lua hooks.
        Start-Sleep -Milliseconds 650
        $statusRequest=Send-Lab 'status'
        $lines=Lines-For $request
        $status=Lines-For $statusRequest | Select-Object -Last 1
        $cancel=$lines | Where-Object {$_ -match "`tnative_cancel`taction=none$"} | Select-Object -Last 1
        $errors=@($lines | Where-Object {$_ -match "`t(native_cancel_error|native_finish_error|restore_error|error)`t"})
        $expectedHealth=if($command -eq 'reload') {'0'} else {'187\.5'}
        $pass=$null -ne $cancel -and $errors.Count -eq 0 -and $status -match "health=$expectedHealth(?:\D|$)" -and $status -match 'action=none$'
        if($command -eq 'recenter') {
            $reset=$lines | Where-Object {$_ -match "`treference_reset`tsource=synthetic debt_remaining=([\d.]+)"} | Select-Object -Last 1
            $pass=$pass -and $reset -and [double]::Parse(($reset -split 'debt_remaining=')[1],[Globalization.CultureInfo]::InvariantCulture) -gt 0
        }
        $results.Add([ordered]@{case=$command;request=$request;pass=[bool]$pass;context=$context;cancel=$cancel;status=$status;errors=$errors})
        if(-not $pass) {throw "Native cancellation case $command failed"}
    }
} finally {
    [void](New-Item -ItemType Directory -Path (Split-Path ([IO.Path]::GetFullPath($OutputPath))) -Force)
    [ordered]@{schema=1;captured_utc=[DateTime]::UtcNow.ToString('o');pass=$results.Count -eq 3 -and @($results | Where-Object {-not $_.pass}).Count -eq 0;cases=$results.ToArray()} |
        ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $OutputPath
    try {[void](Send-Lab 'stop'); [void](Send-Lab 'reset')} catch {Write-Warning "Cancellation cleanup failed: $_"}
}
Write-Output "testlab_cancellation=pass report=$([IO.Path]::GetFullPath($OutputPath))"
