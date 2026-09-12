# A stop/resume cycle brings the loop back, and says so honestly (T1478).
#
# WHY THIS FILE EXISTS. On 2026-09-09 a controller stopped the loop, ran the
# lanes, and resumed it. The loop stayed down for seven minutes across three
# recovery commands, and EVERY ONE OF THEM REPORTED SUCCESS:
#
#   go-loop-exec.ps1 resume        -> "claim will take the loop again on the
#                                      next turn". Exit 0. But a stop makes the
#                                      loop's session PARK (go.md step 0: do not
#                                      pick a task, do not /reset-context), so it
#                                      is idle at its composer and there is no
#                                      next turn to claim anything.
#   go-loop-watchdog.ps1 -Once -Force
#                                  -> "no live loop pane, opening a new window
#                                      (state=free)" / "new-window exit=0".
#                                      Both halves false: the pane was alive and
#                                      merely idle, and `+new-window --target=main`
#                                      FOCUSED the window that already existed.
#   health                         -> DOWN state=free windows=0, throughout.
#
# The shape is "a step whose failure mode is nothing happens", and the reason it
# could not be caught from an exit code is that every code on the path answers a
# narrower question than the one that matters. So two things are asserted here:
#
#   1. the watchdog FINDS the parked pane (the lock is gone, but its ledger
#      remembers where it was) and types into it instead of opening a window,
#   2. the verdict is gated on the LOCK REACHING `held` - the loop's own signal
#      that a session ran go.md step 0 - not on a window operation's exit code.
#
# Section C is the negative control: the same staging with the ledger lookup
# switched off is exactly today's watchdog, and it must go red.
#
# Hermetic: its own lock, ledger, stop flag, watchdog state and task fixtures
# under a per-run temp dir, driving an isolated debug ghoztty. The repo's real
# temp\go-loop.lock.json and the user's windows are never touched.
#
#   powershell -NoProfile -File test\win32\go-loop-resume.ps1
param(
    [string]$Repo = 'D:\git\ghoztty',
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe'
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:skipped = 0
$script:asserted = 0
function Assert($name, $cond) {
    $script:asserted++
    if ($cond) { Write-Host "  PASS $name" } else { Write-Host "  FAIL $name"; $script:failures++ }
}
function Skip($name, $why) {
    $script:skipped++
    Write-Host "  SKIP $name - $why"
}

$root = Join-Path $env:TEMP "ghoztty-go-loop-resume-$PID"
$lock = Join-Path $root 'go-loop.lock.json'
$state = Join-Path $root 'go-loop.watchdog.json'
$stopFile = Join-Path $root 'go-loop.stop.json'
$taskDir = Join-Path $root 'tasks'
$log = Join-Path $root 'watchdog.log'
$lockScript = Join-Path $Repo 'scripts\go-loop-lock.ps1'
$dogScript = Join-Path $Repo 'scripts\go-loop-watchdog.ps1'
$execScript = Join-Path $Repo 'scripts\go-loop-exec.ps1'
New-Item -ItemType Directory -Force $root | Out-Null

. (Join-Path $Repo 'scripts\loop-session.ps1')        # New-LoopSendKeysText
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
# T441/T350: this run's own endpoint before any CLI call. This file opens and
# closes windows; inheriting the user's endpoint would do it to their terminal.
[void](Set-GhozttyTestIsolation -Tag 'gloopres')

function Ghoz($argList) {
    $out = & $Exe @argList 2>&1 | ForEach-Object { $_.ToString() } | Out-String
    return @{ Code = $LASTEXITCODE; Out = $out.Trim() }
}
function Lock-Run([string[]]$extra) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $lockScript,
        '-Repo', $Repo, '-LockPath', $lock) + $extra
    $out = (& powershell @argList 2>&1 | ForEach-Object { $_.ToString() } | Out-String).Trim()
    return @{ Code = $LASTEXITCODE; Out = $out }
}
function Dog-Run([string[]]$extra) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $dogScript,
        '-Repo', $Repo, '-LockPath', $lock, '-StatePath', $state, '-TaskDir', $taskDir,
        '-LogPath', $log, '-StopPath', $stopFile, '-GhozttyExe', $Exe,
        '-ClaudeCommand', 'echo', '-Once') + $extra
    $out = (& powershell @argList 2>&1 | ForEach-Object { $_.ToString() } | Out-String).Trim()
    return @{ Code = $LASTEXITCODE; Out = $out }
}
function Exec-Run([string[]]$extra) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $execScript,
        '-Repo', $Repo, '-LockPath', $lock, '-StopPath', $stopFile, '-GhozttyExe', $Exe) + $extra
    $out = (& powershell @argList 2>&1 | ForEach-Object { $_.ToString() } | Out-String).Trim()
    return @{ Code = $LASTEXITCODE; Out = $out }
}
function Find-Leaves($node, $acc) {
    if ($null -eq $node) { return }
    if ($node.type -eq 'leaf') { $acc.Add($node.terminal) | Out-Null; return }
    Find-Leaves $node.left $acc
    Find-Leaves $node.right $acc
}
function Get-WindowPane($target) {
    $r = Ghoz @('+list', '--json')
    if ($r.Code -ne 0) { return $null }
    try { $j = $r.Out | ConvertFrom-Json } catch { return $null }
    foreach ($w in $j.data.windows) {
        if ($w.target -ne $target) { continue }
        foreach ($t in $w.tabs) {
            $acc = New-Object System.Collections.ArrayList
            Find-Leaves $t.splits $acc
            if ($acc.Count -gt 0) { return $acc[0] }
        }
    }
    return $null
}
function New-TestWindow($target) {
    Ghoz @('+new-window', "--target=$target", "--working-directory=$Repo") | Out-Null
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 500
        $p = Get-WindowPane $target
        if ($p) { return $p }
    }
    return $null
}
$sleepers = @()
function Start-Sleeper {
    return Start-Process powershell -PassThru -WindowStyle Hidden `
        -ArgumentList '-NoProfile', '-Command', 'Start-Sleep -Seconds 900'
}

# One open task this seat could work, or the watchdog idles before it decides
# anything (a finished queue is not a stalled loop).
New-Item -ItemType Directory -Force $taskDir | Out-Null
@('---', 'id: T999', 'title: "fixture"', 'status: "todo"', 'seat: "win"', '---', '', '# T999') `
    -join "`r`n" | Out-File -FilePath (Join-Path $taskDir 'T999.md') -Encoding utf8

""
"A. a stop parks the loop, and the watchdog respects it"
$parked = Start-Sleeper; $sleepers += $parked
Lock-Run @('acquire', '-PaneId', 'PANE-STAGE', '-ClaudePid', $parked.Id) | Out-Null
$r = Exec-Run @('stop', '-Reason', 'running the lanes')
Assert 'A1 stop is recorded' ($r.Code -eq 0 -and $r.Out -match 'STOP REQUESTED')
$r = Dog-Run @('-DryRun')
Assert 'A2 the watchdog does nothing while a stop stands' ($r.Out -match 'ACTION stopped')

""
"B. the ledger remembers where the loop parked"
# Clearing the flag is the first thing `resume` does, and -NoRecover is that
# half on its own. Everything below is the state the controller was in after it:
# stop cleared, and nothing running.
$r = Exec-Run @('resume', '-NoRecover', '-StatePath', $state)
Assert 'B0 resume -NoRecover clears the flag and restarts nothing' `
    ($r.Code -eq 0 -and $r.Out -match 'stop request cleared' -and $r.Out -match 'nothing was restarted')
# What the parked session does at go.md step 0: release the lock and unmark its
# window. From here nothing in the tree points at that pane except the lock's
# own append-only ledger.
Lock-Run @('release', '-PaneId', 'PANE-STAGE', '-ClaudePid', $parked.Id, '-Force') | Out-Null
Assert 'B1 the lock file is gone, as after a stopped claim' (-not (Test-Path $lock))
$ledger = Join-Path $root 'go-loop-history.jsonl'
Assert 'B2 the ledger recorded the release with its pane' `
    ((Test-Path $ledger) -and ((Get-Content $ledger -Raw) -match 'PANE-STAGE'))
# A remembered pane that no longer exists must still open a window - and must
# say that is what happened, rather than the old blanket "no live loop pane".
$r = Dog-Run @('-DryRun', '-RearmMinutes', '0')
Assert 'B3 a remembered pane that is gone still opens a window' ($r.Out -match 'ACTION new-window')
Assert 'B4 and the log names it as closed rather than absent' `
    ($r.Out -match 'last pane=PANE-STAGE \(closed\)')
Assert 'B5 the old unconditional "no live loop pane" wording is gone' `
    ($r.Out -notmatch 'no live loop pane, opening')

""
"C/D. against a live GUI"
Reset-GhozttyTestState -Exe $Exe -SettleMs 800 | Out-Null
Assert-GhozttyPrivateEndpoint -Exe $Exe
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
$td = $null
try {
    $td = New-TestDesktop
    Start-OnTestDesktop -Exe $Exe -Arguments @('--session-persistence=false') -WorkingDirectory $Repo | Out-Null
} catch {
    "  NOTE test desktop unavailable ($_); falling back to the interactive desktop"
    $td = $null
    Start-Process $Exe -ArgumentList '--session-persistence=false' | Out-Null
}
$ready = $false
for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 500
    if ((Ghoz @('+list')).Code -eq 0) { $ready = $true; break }
}
Assert 'C0 the debug GUI is up' $ready
if ($ready) { Assert-GhozttyIsolated -Exe $Exe }

if (-not $ready) {
    Skip 'C/D the parked-pane arms' 'no debug GUI to stage a pane in'
} else {
    # The parked session: a stand-in Claude TUI that owns the bottom of the
    # screen, sits quiet, and - when something is finally typed at it - does what
    # a real session does with the go prompt, which is take the loop's lock. That
    # last part is what makes `held` a real end-to-end signal here rather than a
    # value this script wrote itself.
    $pane = New-TestWindow 'go-loop-parked'
    Assert 'C1 a stand-in loop window is open' ($null -ne $pane)
    if (-not $pane) {
        Skip 'C/D the parked-pane arms' 'could not open a stand-in window'
    } else {
        $owner = Start-Sleeper; $sleepers += $owner
        $fake = Join-Path $root 'parked-session.cmd'
        @(
            '@echo off',
            'echo   bypass permissions on (shift+tab to cycle)',
            'set /p line=',
            ('powershell -NoProfile -ExecutionPolicy Bypass -File "' + $lockScript + '"' +
             ' acquire -Repo "' + $Repo + '" -LockPath "' + $lock + '"' +
             ' -PaneId "' + $pane.id + '" -ClaudePid ' + $owner.Id),
            'ping -n 300 127.0.0.1 >nul'
        ) -join "`r`n" | Out-File -FilePath $fake -Encoding ascii
        $fk = New-LoopSendKeysText -Exe $Exe -Text $fake -Tag 'resume-parked'
        Ghoz (@('+send-keys', "--target=$($pane.id)") + $fk.Args + @('Enter')) | Out-Null
        if ($fk.File) { Remove-Item -LiteralPath $fk.File -ErrorAction SilentlyContinue }
        Start-Sleep -Seconds 3

        # Re-stage the ledger against the pane that now exists, and leave no lock
        # - the exact state the 2026-09-09 controller was looking at.
        Remove-Item $lock, $state -Force -ErrorAction SilentlyContinue
        Lock-Run @('acquire', '-PaneId', $pane.id, '-ClaudePid', $owner.Id) | Out-Null
        Lock-Run @('release', '-PaneId', $pane.id, '-ClaudePid', $owner.Id, '-Force') | Out-Null
        Assert 'C2 staged: a parked pane, no lock' `
            ((-not (Test-Path $lock)) -and $null -ne (Get-WindowPane 'go-loop-parked'))

        ""
        "C. negative control: without the ledger lookup this is today's watchdog"
        $r = Dog-Run @('-Force', '-RearmMinutes', '0', '-NoPaneHistory',
            '-WaitForHeldSeconds', '20', '-WindowTarget', 'go-loop-resume-nc',
            '-ResumePrompt', 'NEGATIVE-CONTROL')
        Assert 'C3 it opens a window instead of finding the parked session' ($r.Out -match 'ACTION new-window')
        Assert 'C4 and the held gate scores it red' ($r.Code -eq 5 -and $r.Out -match 'RECOVERY UNCONFIRMED')
        Ghoz @('+close', '--target=go-loop-resume-nc') | Out-Null
        Assert 'C5 the negative control left the loop down, as it did on the day' `
            (-not (Test-Path $lock))

        ""
        "D. resume brings the loop back with nothing typed by hand"
        Remove-Item $state -Force -ErrorAction SilentlyContinue
        $r = Exec-Run @('resume', '-StatePath', $state, '-HeldTimeoutSeconds', 90)
        Assert 'D1 resume reports the loop running again' ($r.Code -eq 0 -and $r.Out -match 'the loop is running again')
        Assert 'D2 it typed into the parked session rather than opening a window' `
            ($r.Out -match 'ACTION nudge' -and $r.Out -notmatch 'ACTION new-window')
        Assert 'D3 it named the pane it found in the ledger' ($r.Out -match "last pane $($pane.id) is still open")
        Assert 'D4 the verdict came from the lock, not from send-keys' ($r.Out -match 'RECOVERED: the lock reads held')
        $st = Lock-Run @('status', '-PaneId', $pane.id)
        Assert 'D5 the lock really is held by the parked pane' ($st.Out -match 'held ' -and $st.Out -match [regex]::Escape($pane.id))
        Assert 'D6 the stale "next turn will claim it" promise is gone' ($r.Out -notmatch 'on the next turn')

        ""
        "E. resume on a loop that is already running types nothing at it"
        # -Force skips the watchdog's own health gate, so without this check a
        # resume would nudge a session mid-task.
        $r = Exec-Run @('resume', '-StatePath', $state)
        Assert 'E1 it reports the loop is already running' ($r.Code -eq 0 -and $r.Out -match 'already running')
        Assert 'E2 and takes no action at all' ($r.Out -notmatch 'ACTION ')

        Ghoz @('+send-keys', "--target=$($pane.id)", 'C-c') | Out-Null
        Ghoz @('+close', '--target=go-loop-parked') | Out-Null
    }
}

# --- teardown -------------------------------------------------------------
foreach ($s in $sleepers) { Stop-Process -Id $s.Id -Force -ErrorAction SilentlyContinue }
Reset-GhozttyTestState -Exe $Exe -SettleMs 400 | Out-Null
if ($td) { try { Remove-TestDesktop } catch { } }
Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
Remove-Item (Join-Path $env:TEMP 'ghoztty-go-loop-resume.cmd') -Force -ErrorAction SilentlyContinue

# --- stamp (T783) ---------------------------------------------------------
# Only a CLEAN sweep stamps: a run that skipped the GUI arms proved none of the
# things this file exists to prove, and red must stay due.
if ($script:failures -eq 0) {
    if ($script:skipped -gt 0) {
        "  stamp NOT updated: $($script:skipped) section(s) skipped, so this run did not cover the whole harness"
    } else {
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
            update -Guard go-loop-resume -Repo $Repo 2>&1 | ForEach-Object { "  $_" }
    }
}

""
if ($script:failures -eq 0) {
    "ALL PASS ($($script:asserted) assertions$(if ($script:skipped) { ", $($script:skipped) SKIPPED" }))"
    exit 0
} else {
    "$($script:failures) FAILURE(S)"
    exit 1
}
