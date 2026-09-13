# JobTeardown (T1517) - stopping a background job in BOUNDED time.
#
# WHY THIS EXISTS, measured. `test\win32\relay-account.ps1` reached its last
# assertion, entered its top-level `finally`, and never came out: 25+ minutes
# with the output file frozen and the powershell process at 4.64 seconds of CPU
# - blocked, not slow. It had to be killed, so a run that had done all of its
# work reported no verdict and no exit code, and on this box it held the
# per-user pipe against every script queued behind it. A harness that can wedge
# in cleanup is worse than a red one.
#
# THE MECHANISM. `Stop-Job` asks the child to stop and then WAITS for it to
# reach `Stopped`. A job whose loop is parked inside a synchronous .NET call -
# `TcpListener.AcceptTcpClient()` is the one here - never reaches a point where
# the stop request can be serviced, so `Stop-Job` blocks forever. Reproduced
# directly: a job running `while ($true) { $l.AcceptTcpClient() }` is still
# inside `Stop-Job` 90 seconds later, while the identical job written as
# `Pending()` + `Start-Sleep` polling stops in under a second.
#
# THE RULE:
#
#     Teardown gets a deadline. Past it, it says so and returns - never
#     "eventually", which is indistinguishable from never.
#
# Two halves, and both are needed:
#
#   1. The job records its own PID as its first statement, so the harness can
#      END it with `Stop-Process` - a call that is bounded and certain no
#      matter what the job is parked in. `Stop-Job` cannot promise that.
#   2. The wait for it to die is capped. If the job is somehow still Running
#      after the cap, we print one line naming it and carry on, because the
#      remaining teardown and the run's own verdict are worth more than a
#      tidy job table.
#
# `Remove-Job -Force` is only ever called on a job that is no longer Running:
# on a live one it stops the job first, which is the blocking call again.
#
# Acceptance: test\win32\job-teardown.ps1.

Set-StrictMode -Off

# Kill a background job and reap it, in at most $TimeoutSec seconds.
# Returns $true when the job is gone, $false when the deadline was hit (and
# says so on stdout - a silent give-up is the same lie as a hang).
function Stop-JobBounded {
    param(
        $Job,
        # Where the job wrote its own $PID as its first statement. Without it
        # there is no bounded way to end a job parked in a blocking call, so a
        # missing pid file is reported rather than papered over.
        [string]$PidFile = '',
        [int]$TimeoutSec = 10,
        [string]$Label = 'job'
    )
    if ($null -eq $Job) { return $true }

    $childPid = 0
    if ($PidFile -and (Test-Path $PidFile)) {
        $raw = @(Get-Content $PidFile -ErrorAction SilentlyContinue)
        if ($raw.Count -gt 0 -and "$($raw[0])".Trim() -match '^\d+$') { $childPid = [int]"$($raw[0])".Trim() }
    }
    if ($childPid -gt 0) {
        Stop-Process -Id $childPid -Force -ErrorAction SilentlyContinue
    } elseif ($Job.State -eq 'Running') {
        # No pid, no certain kill - and `Stop-Job` is the very call that can
        # own this thread forever, so it is NOT the fallback. Say what was left
        # behind and let the run finish; a leaked listener costs a port, a hung
        # teardown costs the verdict.
        Write-Host "  teardown: no pid recorded for $Label - cannot end it in bounded time, leaving it"
        return $false
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline -and $Job.State -eq 'Running') { Start-Sleep -Milliseconds 100 }

    if ($Job.State -eq 'Running') {
        Write-Host "  teardown gave up on $Label after ${TimeoutSec}s (still Running) - leaving it and carrying on"
        return $false
    }
    Remove-Job $Job -Force -ErrorAction SilentlyContinue
    return $true
}
