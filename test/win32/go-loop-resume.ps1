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
# Section F (T1482) is the other side of finding that pane: the WINDOW is the
# user's, so before typing the watchdog reads whose session is in it (Claude
# Code's per-pid session record -> that session's transcript) and refuses a
# pane whose last typed prompt is not the loop's, with the loop's own session
# and an unreadable one as its negative controls.
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

# T1511: the shared scorer, and the dot-source is also what ARMS the run - a
# body that unwinds before `Complete-TestBody` may not print a pass, and the
# guard-stamping child below reads the same state and refuses to write.
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:failures = 0
$script:skipped = 0
$script:asserted = 0
$script:passes = 0
function Assert($name, $cond) {
    $script:asserted++
    if ($cond) { Write-Host "  PASS $name"; $script:passes++ } else { Write-Host "  FAIL $name"; $script:failures++ }
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
function Dog-Run([string[]]$extra, [string]$exeOverride) {
    # -File binds each named parameter once, so the exe is chosen HERE rather
    # than appended by a caller (T849: one arm needs a stand-in ghoztty).
    #
    # NOT named $exe: PowerShell variable names are case-INSENSITIVE, so a
    # parameter called $exe IS the script's $Exe inside this function, and
    # `if (-not $exe) { $exe = $Exe }` quietly assigns the empty default to
    # itself. Every caller then drove a ghoztty whose path was '', which reads
    # as "no app" and silently changed three verdicts.
    $useExe = if ($exeOverride) { $exeOverride } else { $Exe }
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $dogScript,
        '-Repo', $Repo, '-LockPath', $lock, '-StatePath', $state, '-TaskDir', $taskDir,
        '-LogPath', $log, '-StopPath', $stopFile, '-GhozttyExe', $useExe,
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
#
# Which KIND of window depends on whether an app is answering (T849): with an
# instance up the watchdog asks it for one, with none it launches the app. This
# section is about the ledger, not about that fork, so it pins the app-is-up
# side with a stand-in that answers `+list` with an empty window list - "an app
# is running and the remembered pane is not in it", which is the state B is
# about. Driving the repo exe instead read the answer off whether a debug GUI
# happened to be up, which this harness never starts.
$fakeAppUp = Join-Path $root 'fake-ghoztty-app-up.cmd'
@('@echo off', 'echo {"data":{"windows":[]}}', 'exit /b 0') -join "`r`n" |
    Out-File -FilePath $fakeAppUp -Encoding ascii
$r = Dog-Run @('-DryRun', '-RearmMinutes', '0') $fakeAppUp
Assert 'B3 a remembered pane that is gone still opens a window' ($r.Out -match 'ACTION new-window')
Assert 'B4 and the log names it as closed rather than absent' `
    ($r.Out -match 'last pane=PANE-STAGE \(closed\)')
Assert 'B5 the old unconditional "no live loop pane" wording is gone' `
    ($r.Out -notmatch 'no live loop pane, opening')

""
"F. a pane the user has taken over is never typed into (T1482)"
# The pane is the loop's by RECORD (lock or ledger); the session in it may not
# be. The verdict reads Claude Code's own records - the pid's session file and
# that session's transcript - so these arms stage both as fixtures.
. (Join-Path $Repo 'scripts\lib\LoopPaneSession.ps1')
$loopPrompt = 'Before starting any task, run /reset-context read go.md and go'
$v = Get-LoopSessionVerdict -Prompts @($loopPrompt, 'help me write a cover letter') -Claimed $true
Assert "F1 the user's own prompt last reads foreign, claim or no claim ($($v.Verdict))" ($v.Verdict -eq 'foreign')
$v = Get-LoopSessionVerdict -Prompts @($loopPrompt) -Claimed $true
Assert "F2 a claimed session whose last prompt is the loop's reads loop ($($v.Verdict))" ($v.Verdict -eq 'loop')
$v = Get-LoopSessionVerdict -Prompts @('read go.md and go') -Claimed $false
Assert "F3 a turn that died before its claim still reads loop ($($v.Verdict))" ($v.Verdict -eq 'loop')
$v = Get-LoopSessionVerdict -Prompts @() -Claimed $false
Assert "F4 no prompt at all reads unknown ($($v.Verdict))" ($v.Verdict -eq 'unknown')
$v = Get-LoopSessionVerdict -Prompts @('<command-name>/clear</command-name>', '[Request interrupted by user]', '<system-reminder>x</system-reminder>') -Claimed $true
Assert "F5 slash commands, reminders and interrupt markers are not typed prompts ($($v.Verdict))" ($v.Verdict -eq 'unknown')
$v = Get-LoopSessionVerdict -Prompts @($loopPrompt, '<bash-input>git status</bash-input>') -Claimed $true
Assert "F6 a !command typed at the composer is a person ($($v.Verdict))" ($v.Verdict -eq 'foreign')
$contLoop = Join-Path $root 'reset-context-cont-111.txt'
$contUser = Join-Path $root 'reset-context-cont-222.txt'
'read go.md and go' | Out-File -FilePath $contLoop -Encoding ascii
'now refactor the parser' | Out-File -FilePath $contUser -Encoding ascii
$ptr = { param($p) "Read $p - it contains your instructions for this session. Follow them." }
$v = Get-LoopSessionVerdict -Prompts @((& $ptr $contLoop)) -Claimed $false
Assert "F7 a continuation pointer whose file says go.md is the loop's ($($v.Verdict))" ($v.Verdict -eq 'loop')
$v = Get-LoopSessionVerdict -Prompts @((& $ptr $contUser)) -Claimed $true
Assert "F8 a continuation pointer to the user's own text is foreign ($($v.Verdict))" ($v.Verdict -eq 'foreign')
$gone = Join-Path $root 'reset-context-cont-333.txt'
$v1 = Get-LoopSessionVerdict -Prompts @((& $ptr $gone)) -Claimed $false
$v2 = Get-LoopSessionVerdict -Prompts @((& $ptr $gone)) -Claimed $true
Assert "F9 a pointer whose file is gone decides on the claim ($($v1.Verdict)/$($v2.Verdict))" `
    ($v1.Verdict -eq 'unknown' -and $v2.Verdict -eq 'loop')

# Transcript fixtures, in the shape Claude Code writes them.
$fxSessions = Join-Path $root 'claude-sessions'
$fxProjects = Join-Path $root 'claude-projects'
$fxProjDir = Join-Path $fxProjects 'D--fx'
New-Item -ItemType Directory -Force $fxSessions, $fxProjDir | Out-Null
function FxLine($content) {
    return (@{ type = 'user'; message = @{ role = 'user'; content = $content } } | ConvertTo-Json -Depth 8 -Compress)
}
$fxClear = FxLine '<command-name>/clear</command-name>'
$fxNudge = FxLine $loopPrompt
$fxClaim = FxLine @(@{ tool_use_id = 'toolu_1'; type = 'tool_result'; content = 'PRIMARY 2026-11-14T03:45:50 ACQUIRED pane=0D5B924D-9CC2-4F21-9EA2-0200782DDCEA pid=1 turn=2' })
$fxMine = FxLine 'help me write a cover letter'
# A session that merely READ the lock script's source carries the claim's
# wording with no GUID; that is not a claim.
$fxReadSrc = FxLine @(@{ tool_use_id = 'toolu_2'; type = 'tool_result'; content = 'Emit $check ("ACQUIRED pane=$($new.pane_id) pid=..." STOPPED by request at $($stop.requested_at)' })
$fxCmd = '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"PowerShell","input":{"command":"powershell -NoProfile -File scripts\\go-loop-exec.ps1 claim *> $env:TEMP\\c.txt"}}]}}'
@($fxClear, $fxNudge, $fxClaim, $fxMine) | Out-File -FilePath (Join-Path $fxProjDir 'fx-foreign.jsonl') -Encoding utf8
@($fxClear, $fxNudge, $fxClaim) | Out-File -FilePath (Join-Path $fxProjDir 'fx-loop.jsonl') -Encoding utf8
@($fxClear, (FxLine 'what does go.md say about digests?'), $fxReadSrc) | Out-File -FilePath (Join-Path $fxProjDir 'fx-readsrc.jsonl') -Encoding utf8
@($fxNudge, $fxCmd, $fxMine) | Out-File -FilePath (Join-Path $fxProjDir 'fx-cmd.jsonl') -Encoding utf8
$t = Read-LoopTranscriptPrompts -Path (Join-Path $fxProjDir 'fx-foreign.jsonl')
Assert "F10 tool results are not prompts, and the claim's output is seen ($($t.Prompts.Count) prompts, claimed=$($t.Claimed))" `
    ($t.Ok -and $t.Prompts.Count -eq 3 -and $t.Claimed)
$t = Read-LoopTranscriptPrompts -Path (Join-Path $fxProjDir 'fx-readsrc.jsonl')
Assert "F11 reading the claim's SOURCE is not a claim (claimed=$($t.Claimed))" ($t.Ok -and -not $t.Claimed)
$t = Read-LoopTranscriptPrompts -Path (Join-Path $fxProjDir 'fx-cmd.jsonl')
Assert "F12 a claim whose output went to a file is seen by its command (claimed=$($t.Claimed))" ($t.Ok -and $t.Claimed)

# The pid record: a session file for a pid now held by a DIFFERENT process
# describes somebody else.
$fxOwner = Start-Sleeper; $sleepers += $fxOwner
function Set-FxSession($sid, [string]$procStart) {
    $rec = [ordered]@{ pid = $fxOwner.Id; sessionId = $sid; cwd = 'D:\fx' }
    if ($procStart) { $rec.procStart = $procStart }
    ($rec | ConvertTo-Json -Compress) | Out-File -FilePath (Join-Path $fxSessions "$($fxOwner.Id).json") -Encoding ascii
}
Set-FxSession 'fx-foreign' '1'
$v = Get-LoopPidSessionVerdict -ClaudePid $fxOwner.Id -SessionsDir $fxSessions -ProjectsRoot $fxProjects
Assert "F13 a session record from an earlier process with this pid is not believed ($($v.Verdict))" `
    ($v.Verdict -eq 'unknown' -and $v.Why -match 'earlier process')
$born = (Get-Process -Id $fxOwner.Id).StartTime.ToFileTimeUtc()
Set-FxSession 'fx-foreign' ([string]$born)
$v = Get-LoopPidSessionVerdict -ClaudePid $fxOwner.Id -SessionsDir $fxSessions -ProjectsRoot $fxProjects
Assert "F14 the live process's own record leads to its transcript ($($v.Verdict))" ($v.Verdict -eq 'foreign')

# The watchdog acts on it. A stand-in app that lists the lock's pane (shell pid
# unknown, so the lock's claude pid is the one asked about), a stale lock owned
# by a live process, and the session record pointing at each fixture in turn.
$fakeAppPane = Join-Path $root 'fake-ghoztty-pane.cmd'
@('@echo off',
  'echo {"data":{"windows":[{"id":1,"target":"window-1","title":"[go-loop] fx","tabs":[{"splits":{"type":"leaf","terminal":{"id":"PANE-FX","name":"PANE-FX","pid":0}}}]}]}}',
  'exit /b 0') -join "`r`n" | Out-File -FilePath $fakeAppPane -Encoding ascii
Remove-Item $lock, $state -Force -ErrorAction SilentlyContinue
Lock-Run @('acquire', '-PaneId', 'PANE-FX', '-ClaudePid', $fxOwner.Id) | Out-Null
$fxDog = @('-DryRun', '-Force', '-RearmMinutes', '0', '-ProbeGapSeconds', '1',
    '-ClaudeSessionsDir', $fxSessions, '-ClaudeProjectsRoot', $fxProjects)
Set-FxSession 'fx-foreign'
$r = Dog-Run $fxDog $fakeAppPane
Assert 'F15 a taken-over pane is not nudged: the watchdog opens a window instead' `
    ($r.Out -match 'ACTION new-window' -and $r.Out -notmatch 'ACTION nudge')
Assert 'F16 and says whose session it found there' `
    ($r.Out -match "NOT THE LOOP'S: pane PANE-FX" -and $r.Out -match 'cover letter')
Assert "F17 the re-entry line names the pane as no longer the loop's, not as closed" `
    ($r.Out -match "lock pane=PANE-FX \(no longer the loop's\)")
# Negative controls: the same staging with the LOOP's session in the pane, and
# with no session record at all, must still nudge - or F15 measured nothing.
Set-FxSession 'fx-loop'
$r = Dog-Run $fxDog $fakeAppPane
Assert 'F18 control: the loop''s own session in the pane is still nudged' `
    ($r.Out -match 'ACTION nudge' -and $r.Out -match 'session=loop')
Remove-Item (Join-Path $fxSessions "$($fxOwner.Id).json") -Force
$r = Dog-Run $fxDog $fakeAppPane
Assert 'F19 control: a session that cannot be read keeps the old behaviour (nudge)' `
    ($r.Out -match 'ACTION nudge' -and $r.Out -match 'session=unknown')
Remove-Item $lock, $state -Force -ErrorAction SilentlyContinue

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
    # T689: the fallback keeps the app's stderr the same way the test-desktop
    # path does - this is the branch that runs when something is already wrong.
    Start-Process $Exe -ArgumentList '--session-persistence=false' `
        -RedirectStandardError (Join-Path $root 'app-fallback.err.txt') | Out-Null
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
Complete-TestBody  # T1039: before the stamp, a child process that reads this run's state
if ($script:failures -eq 0) {
    if ($script:skipped -gt 0) {
        "  stamp NOT updated: $($script:skipped) section(s) skipped, so this run did not cover the whole harness"
    } else {
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
            update -Guard go-loop-resume -Repo $Repo 2>&1 | ForEach-Object { "  $_" }
    }
}

""
Write-TestVerdict -Pass $script:passes -Fail $script:failures -Skipped $script:skipped
