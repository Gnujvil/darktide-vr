function Get-ExistingGitHubRelease {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')][string] $Repo,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_.-]+$')][string] $Tag
    )
    # Redirect native stderr through ProcessStartInfo. Windows PowerShell turns
    # an expected "release not found" probe into a terminating NativeCommandError
    # when 2>$null is combined with ErrorActionPreference=Stop.
    $start = New-Object Diagnostics.ProcessStartInfo (Get-Command gh -ErrorAction Stop).Source
    $start.Arguments = "release view $Tag --repo $Repo --json isDraft,targetCommitish"
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($start)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(60000)) { $process.Kill(); throw 'GitHub release lookup timed out.' }
        $process.WaitForExit()
        if ($process.ExitCode -eq 0) { return ($stdout.Result | ConvertFrom-Json) }
        if ($stderr.Result -match 'release not found') { return $null }
        throw "GitHub release lookup failed: $($stderr.Result.Trim())"
    } finally { $process.Dispose() }
}
