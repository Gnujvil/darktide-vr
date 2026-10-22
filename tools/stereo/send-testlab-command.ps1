[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('enter','spawn','attacker','group','run','threat','stop','status','buffs','inventory','weapon','reset','recenter','reload','quit','combat','aimcheck','particles','template')][string] $Command,
    [string] $Arguments='',
    [string] $GameRoot='C:/Program Files (x86)/Steam/steamapps/common/Warhammer 40,000 DARKTIDE',
    [ValidateRange(1,60)][int] $TimeoutSeconds=10
)
$ErrorActionPreference='Stop'
$modRoot=Join-Path $GameRoot 'mods/darktide_testlab'
if (-not (Test-Path -LiteralPath $modRoot)) { throw 'Testlab is not installed' }
if ($Arguments -match '[\r\n]') { throw 'Arguments must fit on one line' }
$requestId=[guid]::NewGuid().ToString('N')
$pending=Join-Path $modRoot "$requestId.pending"
$mailbox=Join-Path $modRoot 'command.txt'
[IO.File]::WriteAllText($pending,"$requestId $Command $Arguments`n")
# The Lua poll can briefly hold the previous mailbox open without delete
# sharing on Windows. Retry publishing the SAME id, never enqueue a second
# command after an ambiguous acknowledgement.
$publishDeadline=[DateTime]::UtcNow.AddSeconds(2)
while ($true) {
    try { Move-Item -LiteralPath $pending -Destination $mailbox -Force -ErrorAction Stop; break }
    catch {
        if (-not (Test-Path -LiteralPath $pending) -or [DateTime]::UtcNow -ge $publishDeadline) { throw }
        Start-Sleep -Milliseconds 50
    }
}
$deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
while ([DateTime]::UtcNow -lt $deadline) {
    $ack=Join-Path $modRoot 'ack.tsv'
    if (Test-Path -LiteralPath $ack) {
        $line=Get-Content -LiteralPath $ack -Raw
        if ($line.StartsWith("$requestId`t")) {
            Write-Output $line.Trim()
            if ($line -match "`terror`t") { throw 'Testlab rejected command' }
            return
        }
    }
    Start-Sleep -Milliseconds 100
}
throw "No acknowledgement for request $requestId; command may still be pending."
