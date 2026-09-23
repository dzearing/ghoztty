# T1686 acceptance: the app never just stops - every ending leaves a reason.
#
# THE DEFECT. On 2026-09-20 every Ghoztty window on the box disappeared at
# once. No dialog, no Application Error record, and nothing in ghoztty.log
# after the last routine line. The cause (Windows Update tearing out the
# NVIDIA display driver under a live OpenGL context) was found only because
# the renderer happened to log three warnings in the second before it died
# and the SYSTEM event log happened to name nvlddmkm at that same second.
# Two unrelated logs lining up is not a diagnostic path anyone can use twice.
#
# THE FIX, and what this script guards (src/apprt/win32/exit_reason.zig plus
# the pure text half in src/os/exit_ledger.zig): a per-launch ledger at
# %LOCALAPPDATA%\ghoztty\exit-log[-debug].txt. Every launch appends `start`,
# every deliberate quit appends `exit reason=...`, an unhandled exception
# appends `crash code=...`, and - the case nothing inside a dying process can
# ever witness - the NEXT launch appends `unrecorded-exit` naming the run
# whose entry was left open.
#
# ORACLE, and why it is three cases. "A line appeared" is green for the wrong
# reason if the ledger simply names every run it has ever seen, so the cases
# are built to disagree with each other:
#
#   A) quit    -> start THEN exit reason=user-quit for that pid, and the next
#                 launch says nothing about it.
#   B) killed  -> start with no terminal record; the NEXT launch appends
#                 unrecorded-exit prev_pid=<the killed pid>.
#   C) alive   -> a launch alongside a STILL-RUNNING app must NOT accuse it.
#                 This is B's negative control: without the liveness check
#                 every second window would report the first as vanished.
#
# A and C are what keep B from being a ledger that cries wolf.
#
# Only touches the DEBUG ledger (exit-log-debug.txt), which no release build
# and therefore no installed Ghoztty ever writes or reads, and only stops
# ghoztty processes running from this repo's zig-out.
param([string]$ExePath, [switch]$Interactive)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }
# Isolate the IPC endpoint (inherited through CreateProcessW) so a launch can
# never find - or forward to - the user's instance. Case C launches a SECOND
# app on purpose and gives it a suffix of its own, so it becomes its own
# process instead of joining the first as a single instance; case D does the
# opposite on purpose and reuses the first app's suffix.
$baseSuffix = "-t1686exit$PID"
$env:GHOZTTY_PIPE_SUFFIX = $baseSuffix

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

$ledger = Join-Path $env:LOCALAPPDATA 'ghoztty\exit-log-debug.txt'

# Every ledger line for one pid, oldest first. Parsing here rather than
# grepping for a substring so a line that merely MENTIONS the pid in some
# other field can never be mistaken for a record about it.
function Get-LedgerRecords([int]$Pid_) {
    if (-not (Test-Path $ledger)) { return @() }
    $out = @()
    foreach ($line in (Get-Content $ledger)) {
        $t = $line.Trim()
        if (-not $t) { continue }
        $parts = $t -split '\s+'
        if ($parts.Count -lt 3) { continue }
        if ($parts[1] -ne "pid=$Pid_") { continue }
        if ($parts[2] -notlike 'event=*') { continue }
        $out += [pscustomobject]@{
            Ts     = $parts[0]
            Event  = $parts[2].Substring('event='.Length)
            Detail = if ($parts.Count -gt 3) { ($parts[3..($parts.Count - 1)] -join ' ') } else { '' }
        }
    }
    # Plain return, and every caller wraps in @(). `return , $out` looks like
    # the fix for the 1-record unroll trap but is its own trap: @() around it
    # yields ONE element that is the whole array, so .Count is always 1 and
    # `$x[0].Detail` member-enumerates every record - which is how the first
    # draft of this script passed assertions it never actually checked.
    return $out
}

# Wait for `pid` to have written its `start` line. The ledger is opened
# during App.init, so a launch that has a window has certainly written it;
# polling keeps the assertion off a fixed sleep all the same.
function Wait-LedgerStart([int]$Pid_, [int]$TimeoutSec = 10) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $r = @(Get-LedgerRecords -Pid_ $Pid_)
        if ($r.Count -gt 0) { return $true }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

$appArgs = @('--config-default-files=false', '--session-persistence=false',
    '--confirm-close-surface=false', '--quit-after-last-window-closed=true')

function Start-App([string]$Label, [string]$Suffix = $baseSuffix) {
    $env:GHOZTTY_PIPE_SUFFIX = $Suffix
    Clear-DebugSessionLayout | Out-Null
    # confirm-close-surface=false: case A closes the window to get a QUIT, and
    # the close confirmation (a live shell in the pane) would otherwise leave
    # the app sitting on a modal dialog, which reads as "never exited".
    # quit-after-last-window-closed=true: on Windows the default is false, so
    # the last window closing is not by itself an app exit.
    $app = Start-OnTestDesktop -Exe $exe -Arguments $appArgs
    Start-Sleep -Seconds 2
    if ($app.Process -and $app.Process.HasExited) {
        Write-Host "SETUP FAIL: GUI died at launch ($Label)"; exit 1
    }
    $top = Wait-TestWindow -ProcessId ([int]$app.Pid) -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) {
        Write-Host "SETUP FAIL: top window not found ($Label)"; exit 1
    }
    return [pscustomobject]@{ Pid = [int]$app.Pid; Window = $top }
}

Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    Reset-GhozttyTestState -Exe $exe | Out-Null
    # Start from an empty ledger so "no record for that pid" means what it
    # says and cannot be satisfied by a stale line from an earlier run.
    Remove-Item $ledger -Force -ErrorAction SilentlyContinue
    Assert (-not (Test-Path $ledger)) 'setup: the debug ledger starts absent'

    # ---------------------------------------------------------------
    # A) a deliberate quit closes its own entry
    # ---------------------------------------------------------------
    $a = Start-App 'case A'
    Assert (Wait-LedgerStart -Pid_ $a.Pid) "A: launch wrote a start record (pid $($a.Pid))"
    Assert (Test-Path $ledger) 'A: the ledger exists once an app has run'

    $startRec = @(Get-LedgerRecords -Pid_ $a.Pid)
    Assert ($startRec.Count -ge 1 -and $startRec[0].Event -eq 'start') `
        'A: the first record for the pid is `start`'
    Assert ($startRec[0].Detail -like '*build=*' -and $startRec[0].Detail -like '*mode=*') `
        "A: the start record names the build and mode ($($startRec[0].Detail))"

    Send-TestWindowClose -Window $a.Window | Out-Null
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-Process -Id $a.Pid -ErrorAction SilentlyContinue)) { break }
        Start-Sleep -Milliseconds 250
    }
    Assert (-not (Get-Process -Id $a.Pid -ErrorAction SilentlyContinue)) `
        'A: the app actually exited when its last window closed'

    $aRecs = @(Get-LedgerRecords -Pid_ $a.Pid)
    $aExit = @($aRecs | Where-Object { $_.Event -eq 'exit' })
    Assert ($aExit.Count -eq 1) "A: exactly one exit record ($($aExit.Count))"
    Assert ($aExit.Count -eq 1 -and $aExit[0].Detail -eq 'reason=user-quit') `
        "A: the exit names the reason (got '$(if ($aExit.Count) { $aExit[0].Detail })')"

    # ---------------------------------------------------------------
    # B) killed from outside - the NEXT launch is the witness
    # ---------------------------------------------------------------
    $b = Start-App 'case B'
    Assert (Wait-LedgerStart -Pid_ $b.Pid) "B: launch wrote a start record (pid $($b.Pid))"
    Stop-Process -Id $b.Pid -Force
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-Process -Id $b.Pid -ErrorAction SilentlyContinue)) { break }
        Start-Sleep -Milliseconds 200
    }
    Assert (-not (Get-Process -Id $b.Pid -ErrorAction SilentlyContinue)) `
        'B: the app was killed outright'

    $bRecs = @(Get-LedgerRecords -Pid_ $b.Pid)
    Assert (@($bRecs | Where-Object { $_.Event -in @('exit', 'crash') }).Count -eq 0) `
        'B: a killed process writes nothing itself - the entry is left open'

    # The whole point of the card: this is the launch that must speak for the
    # one that could not.
    $c = Start-App 'case B witness'
    Assert (Wait-LedgerStart -Pid_ $c.Pid) "B: the next launch started (pid $($c.Pid))"
    $cRecs = @(Get-LedgerRecords -Pid_ $c.Pid)
    $accuse = @($cRecs | Where-Object { $_.Event -eq 'unrecorded-exit' })
    Assert ($accuse.Count -eq 1) `
        "B: the next launch recorded exactly one unrecorded-exit ($($accuse.Count))"
    Assert ($accuse.Count -eq 1 -and $accuse[0].Detail -like "prev_pid=$($b.Pid)*") `
        "B: it names the killed run (got '$(if ($accuse.Count) { $accuse[0].Detail })')"
    Assert ($accuse.Count -eq 1 -and $accuse[0].Detail -like '*prev_start=2*') `
        'B: and when that run had started'

    # And it must not accuse the CLEANLY quit run from case A, whose entry was
    # closed - otherwise every launch would report an ending forever.
    Assert ($accuse.Count -ne 1 -or $accuse[0].Detail -notlike "prev_pid=$($a.Pid)*") `
        'B: the cleanly quit run is not reported as vanished'

    # ---------------------------------------------------------------
    # C) negative control - a LIVE app is not a vanished one
    # ---------------------------------------------------------------
    # `c` is still running with an open entry. A second launch alongside it
    # must stay silent about it: an open entry plus a live pid is an app that
    # simply has not finished yet.
    $d = Start-App 'case C' -Suffix "$baseSuffix-c"
    Assert (Wait-LedgerStart -Pid_ $d.Pid) "C: the second app started (pid $($d.Pid))"
    Assert (($null -ne (Get-Process -Id $c.Pid -ErrorAction SilentlyContinue))) `
        'C: the first app is still running'
    $dAccuse = @(Get-LedgerRecords -Pid_ $d.Pid | Where-Object { $_.Event -eq 'unrecorded-exit' })
    Assert (@($dAccuse | Where-Object { $_.Detail -like "prev_pid=$($c.Pid)*" }).Count -eq 0) `
        'C: a running app is NOT reported as having vanished'

    # ---------------------------------------------------------------
    # D) a launch that FORWARDS to a running instance closes its own entry
    # ---------------------------------------------------------------
    # A second click on the shortcut starts a process that hands its window
    # request to the running app and exits by design. It opened a ledger
    # entry on the way in, so without a closing record every such click
    # would be reported by the next launch as an app that vanished.
    $env:GHOZTTY_PIPE_SUFFIX = $baseSuffix
    $fwd = Start-OnTestDesktop -Exe $exe -Arguments $appArgs
    $fwdPid = [int]$fwd.Pid
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-Process -Id $fwdPid -ErrorAction SilentlyContinue)) { break }
        Start-Sleep -Milliseconds 200
    }
    Assert (-not (Get-Process -Id $fwdPid -ErrorAction SilentlyContinue)) `
        "D: the second launch handed off and exited (pid $fwdPid)"
    $fRecs = @(Get-LedgerRecords -Pid_ $fwdPid)
    Assert (@($fRecs | Where-Object { $_.Event -eq 'start' }).Count -eq 1) `
        'D: the forwarding launch wrote its start record'
    $fExit = @($fRecs | Where-Object { $_.Event -eq 'exit' })
    Assert ($fExit.Count -eq 1 -and $fExit[0].Detail -eq 'reason=forwarded') `
        "D: and closed it as forwarded (got '$(if ($fExit.Count) { $fExit[0].Detail })')"

    # The next launch must not accuse the forwarder.
    $e = Start-App 'case D witness' -Suffix "$baseSuffix-d"
    Assert (Wait-LedgerStart -Pid_ $e.Pid) "D: a later launch started (pid $($e.Pid))"
    $eAccuse = @(Get-LedgerRecords -Pid_ $e.Pid | Where-Object { $_.Event -eq 'unrecorded-exit' })
    Assert (@($eAccuse | Where-Object { $_.Detail -like "prev_pid=$fwdPid*" }).Count -eq 0) `
        'D: a forwarded launch is NOT reported as having vanished'
    Complete-TestBody
}
finally {
    Reset-GhozttyTestState -Exe $exe | Out-Null
    Remove-TestDesktop
}

$fgSeen = @(Stop-TestForegroundWatch)
$leaked = @(Get-TestLaunchedPids | Where-Object { $fgSeen -contains $_ })
Assert ($leaked.Count -eq 0) `
    'no test-desktop app ever became foreground on the interactive desktop'

# --- stamp (T783) ----------------------------------------------------------
if ($script:fail -eq 0 -and (Test-TestBodyComplete)) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot '..\..\scripts\guard-due.ps1') `
        update -Guard exit-reason -Repo (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path 2>&1 |
        ForEach-Object { Write-Host "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Label 'exit-reason' -MinPass 25
