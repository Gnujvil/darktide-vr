[CmdletBinding()]
param([string] $KeyFile, [string] $Repo = 'Gnujvil/darktide-vr')
# Run locally by the repository owner. The private value goes only to gh's
# standard input, then GitHub's encrypted Actions secret; never to the console.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'launcher-signing.ps1')
if ($Repo -cne 'Gnujvil/darktide-vr') { throw 'This setup is restricted to Gnujvil/darktide-vr.' }
if (-not $KeyFile) { $KeyFile = Get-DefaultLauncherKeyPath }
$material = Read-LauncherKeyFile $KeyFile
$public = ConvertTo-LauncherPublicKeyLine $material
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
if (-not ((Get-Content -LiteralPath (Join-Path $root 'launcher/release-signing-key.pub')) -contains $public)) {
    throw 'Private key does not match the public key embedded in the launcher.'
}
$gh = (Get-Command gh -ErrorAction Stop).Source
$start = New-Object Diagnostics.ProcessStartInfo $gh
$start.Arguments = "secret set DARKTIDEVR_RELEASE_SIGNING_KEY --repo $Repo"
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
$start.RedirectStandardInput = $true
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
$process = [Diagnostics.Process]::Start($start)
$stdout = $process.StandardOutput.ReadToEndAsync()
$stderr = $process.StandardError.ReadToEndAsync()
try {
    $process.StandardInput.Write(($material | ConvertTo-Json -Compress))
    $process.StandardInput.Close()
    $process.WaitForExit()
    if ($process.ExitCode) { throw "GitHub secret setup failed: $($stderr.Result)" }
    Write-Output 'Signing key stored as encrypted GitHub Actions secret DARKTIDEVR_RELEASE_SIGNING_KEY.'
} finally { $process.Dispose() }
