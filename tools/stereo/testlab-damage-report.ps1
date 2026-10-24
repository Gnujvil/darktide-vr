[CmdletBinding()]
param(
    # A run's request id (the id send-testlab-command.ps1 printed); default: the newest run with a damage summary.
    [string] $Request,
    [string] $GameRoot='C:/Program Files (x86)/Steam/steamapps/common/Warhammer 40,000 DARKTIDE',
    # A results.tsv to read instead of the installed testlab's (for example a copied artifact).
    [string] $ResultsPath,
    [switch] $Hits,
    [switch] $AsJson
)
# Read-only: prints one run's damage ledger from results.tsv. Rows are
# "<clock>\t<request>\t<kind>\t<key=value ...>"; see damage_ledger.lua.
$ErrorActionPreference='Stop'
if (-not $ResultsPath) { $ResultsPath=Join-Path $GameRoot 'mods/darktide_testlab/results.tsv' }
if (-not (Test-Path -LiteralPath $ResultsPath)) { throw "No results file: $ResultsPath" }
$rows=foreach ($line in [IO.File]::ReadAllLines($ResultsPath)) {
    $fields=$line -split "`t",4
    if ($fields.Count -eq 4 -and $fields[2] -like 'damage_*') {
        [pscustomobject]@{request=$fields[1];kind=$fields[2];detail=$fields[3]}
    }
}
if (-not $Request) {
    $last=@($rows | Where-Object kind -eq 'damage_summary') | Select-Object -Last 1
    if (-not $last) { throw 'No run in this results file has a damage summary yet' }
    $Request=$last.request
}
$run=@($rows | Where-Object request -eq $Request)
if (-not $run.Count) { throw "Run $Request has no damage ledger rows" }
function ConvertFrom-Pairs([string] $Text) {
    $out=[ordered]@{}
    foreach ($pair in $Text -split ' ') {
        if ($pair -match '^([a-z_]+)=(.*)$') { $out[$Matches[1]]=$Matches[2] }
    }
    [pscustomobject]$out
}
$summary=@($run | Where-Object kind -eq 'damage_summary' | ForEach-Object { ConvertFrom-Pairs $_.detail }) | Select-Object -Last 1
$presses=@($run | Where-Object kind -eq 'damage_press' | ForEach-Object { ConvertFrom-Pairs $_.detail })
$attacks=@($run | Where-Object kind -eq 'damage_attack' | ForEach-Object { ConvertFrom-Pairs $_.detail })
$hitRows=@($run | Where-Object kind -eq 'damage_hit' | ForEach-Object { ConvertFrom-Pairs $_.detail })
if ($AsJson) {
    [ordered]@{request=$Request;summary=$summary;presses=$presses;attacks=$attacks;hits=$hitRows} | ConvertTo-Json -Depth 4
    return
}
Write-Output "run $Request"
if ($summary) {
    Write-Output ("presses {0} (light {1}, heavy {2}, scripted {3}); cancelled charges {4} ({5} still attacked); specials {6}; pushes {7}" -f
        $summary.presses,$summary.light,$summary.heavy,$summary.scripted,$summary.cancelled,$summary.cancelled_attacked,$summary.specials,$summary.pushes)
    Write-Output ("attacks {0}: {1} from a press, {2} unpressed, {3} damaged" -f
        $summary.attacks,$summary.attacks_pressed,$summary.attacks_unpressed,$summary.attacks_damaged)
    Write-Output ("hits {0}: {1} damaging, {2} head, {3} weakspot, {4} critical, {5} kills, damage {6}; {7} hits with no attack running" -f
        $summary.hits,$summary.damaging_hits,$summary.head_hits,$summary.weakspot_hits,$summary.critical_hits,$summary.kills,$summary.damage,$summary.orphan_hits)
    Write-Output ("presses with no damage {0}: {1} started no attack, {2} attacked but damaged nothing" -f
        $summary.presses_no_damage,$summary.presses_no_attack,$summary.presses_attack_no_damage)
} else { Write-Output 'no damage_summary row (the run has not ended)' }
$presses | Format-Table press,t,kind,released,attack,action,hits,damage,kills,outcome -AutoSize | Out-String -Width 200 | Write-Output
$attacks | Format-Table attack,t,action,kind,press,press_kind,hits,damaging_hits,head_hits,damage,kills,finished -AutoSize | Out-String -Width 200 | Write-Output
if ($Hits) { $hitRows | Format-Table hit,t,attack,action,target,breed,zone,damage,result,weakspot,critical -AutoSize | Out-String -Width 200 | Write-Output }
