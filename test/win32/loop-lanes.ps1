# Loop-lane acceptance (tracker T1984): two go.md loops - two LANES, each in its
# own git worktree (T1937) - each get their own supervisor, window marker and
# names; health and the dashboard show both lanes; stopping one lane does not
# stop the other; and lane B never publishes and never delivers.
#
# The fixture is a REAL git repository with a REAL linked worktree whose
# directory ends in '-b', both carrying a copy of scripts\ - so every script
# under test derives its lane from where it lives, exactly as it will in
# D:\git\ghoztty-b, instead of being told.
#
# Sections:
#   A. Lane derivation: the main worktree is a, '<name>-b' is b, '<name>-c' is
#      c, any other linked worktree is b, a non-git directory is a, and
#      GHOZTTY_LOOP_LANE=<letter> wins.
#   B. Names: lane a keeps every historical name byte for byte; lane b's are
#      all different, and its window marker is not a prefix match for lane a's
#      (the claim's duplicate test is a StartsWith).
#   C. Refusals from lane b: daily-publish SKIPs (exit 0) with LANE REFUSED and
#      writes no watermark; publish-windows-tag, upgrade-ghoztty-windows,
#      launch-upgrade and deliver-windows-build each refuse with LANE REFUSED
#      before doing anything. Negative controls: the same daily-publish run
#      pinned to lane a (GHOZTTY_LOOP_LANE=a) does NOT refuse, and lane b's
#      read-only modes (-Status, publish -DryRun) are not refused.
#   D. Supervisors: the watchdog's -Status names its lane's mutex and task; a
#      lane-q watchdog daemon starts while the real lane-a watchdog holds its
#      mutex. Negative control: one forced onto lane a's mutex name exits as
#      "another go-loop watchdog is running" - the single-name world, where a
#      second lane had no supervisor at all.
#   E. Overview: with lane b stopped, lane a's health run lists both lanes with
#      lane b 'stopped' and its claimed task, and does not itself read stopped;
#      the dashboard's lanes field says the same. Negative control: with lane b
#      never having run the loop, neither lists a lane b.
#   F. The morning block (go.md steps 0.5-0.7) has one owner (T2115): lane b
#      and lane c refuse with LANE REFUSED (exit 3) while lane a holds the
#      loop; lane a owns it; lane b takes it when lane a is free or stopped.
#      Negative control: the lane-b run pinned to lane a is not refused.
#
# Hermetic: the fixture, its ledger and every log/state file live under
# $env:TEMP. The real lock, ledger, watermark and installs are never written.
# No window is opened and nothing takes focus (the watchdog daemons run hidden
# with -DryRun and a stop flag, so they decide nothing and type nothing).
#
#   powershell -NoProfile -File test\win32\loop-lanes.ps1
param(
    [string]$Repo = 'D:\git\ghoztty'
)

$ErrorActionPreference = 'Continue'

# The shared scorer; dot-sourcing it ARMS the run (T1039).
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:failures = 0
$script:passes = 0

function Assert($name, $cond, $Detail = $null) {
    if ($cond) { "  PASS $name"; $script:passes++ } else { "  FAIL $name"; $script:failures++; if ($Detail) { ($Detail -split "`r?`n") | ForEach-Object { "        | $_" } } }
}

# Run with a set of env vars applied for the child only, then restored. $null
# as a value REMOVES the variable for the child.
function Invoke-WithEnv {
    param([hashtable]$Vars, [scriptblock]$Body)
    $saved = @{}
    foreach ($k in $Vars.Keys) {
        $saved[$k] = [Environment]::GetEnvironmentVariable($k)
        [Environment]::SetEnvironmentVariable($k, $Vars[$k])
    }
    try { & $Body }
    finally { foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) } }
}

# One script from a fixture lane; returns @{ Code; Out }.
function Lane-Run {
    param([string]$Root, [string]$Script, [string[]]$CmdArgs = @(), [hashtable]$Vars = @{})
    $path = Join-Path $Root "scripts\$Script"
    $res = Invoke-WithEnv $Vars {
        $o = & powershell -NoProfile -ExecutionPolicy Bypass -File $path @CmdArgs 2>&1 |
            ForEach-Object { $_.ToString() } | Out-String
        @{ Code = $LASTEXITCODE; Out = $o }
    }
    return $res
}

function Git-Quiet {
    param([string]$Dir, [string[]]$GitArgs)
    $eap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $o = & git -C $Dir @GitArgs 2>&1 | ForEach-Object { $_.ToString() } | Out-String }
    finally { $ErrorActionPreference = $eap }
    return @{ Code = $LASTEXITCODE; Out = $o }
}

$work = Join-Path $env:TEMP "ghoztty-loop-lanes-$PID"
$mainRoot = Join-Path $work 'fix'
$laneB = Join-Path $work 'fix-b'
$laneC = Join-Path $work 'fix-c'
$laneOther = Join-Path $work 'fix-feature'
$plain = Join-Path $work 'not-git'
$ledger = Join-Path $work 'loop-ledger.json'
$savedLane = $env:GHOZTTY_LOOP_LANE
$dogs = New-Object System.Collections.ArrayList

Reset-TestBody
try {
    # GHOZTTY_LOOP_LANE is the override under test; an inherited value would
    # pin every fixture to one lane and turn section A into a tautology.
    $env:GHOZTTY_LOOP_LANE = $null
    New-Item -ItemType Directory -Force $mainRoot, $plain | Out-Null
    # A copy of scripts\ in a one-commit repository. Robocopy, not Copy-Item:
    # it is the copy that never follows a junction.
    & robocopy (Join-Path $Repo 'scripts') (Join-Path $mainRoot 'scripts') /E /NFL /NDL /NJH /NJS /NP /R:1 /W:1 | Out-Null
    New-Item -ItemType Directory -Force (Join-Path $mainRoot 'temp') | Out-Null
    Set-Content -LiteralPath (Join-Path $mainRoot '.gitignore') -Value 'temp/' -Encoding ascii
    $null = Git-Quiet $mainRoot @('init', '-q', '-b', 'main')
    $null = Git-Quiet $mainRoot @('add', '-A')
    $c = Git-Quiet $mainRoot @('-c', 'user.name=lanes', '-c', 'user.email=lanes@example.invalid', 'commit', '-q', '-m', 'fixture')
    foreach ($wt in @(@($laneB, 'lane-b'), @($laneC, 'lane-c'), @($laneOther, 'lane-x'))) {
        $null = Git-Quiet $mainRoot @('worktree', 'add', '-q', '-b', $wt[1], $wt[0])
        New-Item -ItemType Directory -Force (Join-Path $wt[0] 'temp') | Out-Null
    }
    $ready = (Test-Path (Join-Path $laneB 'scripts\lib\LoopLane.ps1')) -and (Test-Path (Join-Path $laneC 'scripts'))
    Assert 'setup: a fixture repo with three linked worktrees, each carrying scripts\' $ready $c.Out
    if (-not $ready) { throw 'fixture setup failed' }

    . (Join-Path $mainRoot 'scripts\lib\LoopLane.ps1')

    # --- A. derivation ---------------------------------------------------------
    "A. lane derivation"
    Assert 'A1 the main worktree is lane a' ((Get-LoopLaneId -Repo $mainRoot) -eq 'a')
    Assert 'A2 a linked worktree named <x>-b is lane b' ((Get-LoopLaneId -Repo $laneB) -eq 'b')
    Assert 'A3 a linked worktree named <x>-c is lane c' ((Get-LoopLaneId -Repo $laneC) -eq 'c')
    Assert 'A4 any other linked worktree is lane b' ((Get-LoopLaneId -Repo $laneOther) -eq 'b')
    Assert 'A5 a directory that is not a git checkout is lane a' ((Get-LoopLaneId -Repo $plain) -eq 'a')
    $pinned = Invoke-WithEnv @{ GHOZTTY_LOOP_LANE = 'C' } { Get-LoopLaneId -Repo $mainRoot }
    Assert 'A6 GHOZTTY_LOOP_LANE=<letter> wins over the worktree' ($pinned -eq 'c')
    $named = Invoke-WithEnv @{ GHOZTTY_LOOP_LANE = 'harness-lane' } { Get-LoopLaneId -Repo $laneB }
    Assert 'A7 a longer GHOZTTY_LOOP_LANE (a ledger lane NAME) is ignored here' ($named -eq 'b')
    # The parallel runner's worker mirror: a directory whose .git is a JUNCTION
    # to the main repo's. It is lane a - reading it as a linked worktree made
    # every pooled delivery harness refuse as lane b. The junction is removed
    # with rmdir right here, never left for Remove-Item -Recurse, which would
    # follow it into the fixture's real .git.
    $mirror = Join-Path $work 'mirror-b'
    New-Item -ItemType Directory -Force $mirror | Out-Null
    & cmd /c mklink /J "$mirror\.git" "$mainRoot\.git" | Out-Null
    try { $mirrorLane = Get-LoopLaneId -Repo $mirror }
    finally { & cmd /c rmdir "$mirror\.git" | Out-Null }
    Assert 'A8 a junction mirror of the main worktree is lane a, whatever its name' ($mirrorLane -eq 'a')

    # --- B. names --------------------------------------------------------------
    "B. names"
    Assert 'B1 lane a keeps the historical mutex' ((Get-LoopLaneWatchdogMutex 'a') -ceq 'Global\GhozttyGoLoopWatchdog')
    Assert 'B2 lane a keeps the historical Run entry / revive task name' ((Get-LoopLaneTaskName 'a') -ceq 'GhozttyGoLoopWatchdog')
    Assert 'B3 lane a keeps the historical marker and window target' (
        (Get-LoopLaneMarker 'a') -ceq '[go-loop]' -and (Get-LoopLaneWindowTarget 'a') -ceq 'main')
    Assert 'B4 lane a keeps the historical log and shim paths' (
        (Get-LoopLaneWatchdogLog 'a') -eq (Join-Path $env:TEMP 'ghoztty-go-loop-watchdog.log') -and
        (Get-LoopLaneResumeShim 'a') -eq (Join-Path $env:TEMP 'ghoztty-go-loop-resume.cmd'))
    $namesA = @((Get-LoopLaneWatchdogMutex 'a'), (Get-LoopLaneTaskName 'a'), (Get-LoopLaneMarker 'a'),
        (Get-LoopLaneWindowTarget 'a'), (Get-LoopLaneWatchdogLog 'a'), (Get-LoopLaneResumeShim 'a'))
    $namesB = @((Get-LoopLaneWatchdogMutex 'b'), (Get-LoopLaneTaskName 'b'), (Get-LoopLaneMarker 'b'),
        (Get-LoopLaneWindowTarget 'b'), (Get-LoopLaneWatchdogLog 'b'), (Get-LoopLaneResumeShim 'b'))
    $same = @(0..($namesA.Count - 1) | Where-Object { $namesA[$_] -eq $namesB[$_] })
    Assert 'B5 every lane-b name differs from lane a''s' ($same.Count -eq 0) ($namesB -join "`n")
    Assert 'B6 neither marker is a StartsWith match for the other' (
        -not ('[go-loop b] ghoztty parity'.StartsWith((Get-LoopLaneMarker 'a'))) -and
        -not ('[go-loop] ghoztty parity'.StartsWith((Get-LoopLaneMarker 'b'))))
    Assert 'B7 only lane a owns delivery' ((Test-LoopLaneOwnsDelivery 'a') -and -not (Test-LoopLaneOwnsDelivery 'b'))

    # --- C. refusals -----------------------------------------------------------
    "C. lane b never publishes or delivers"
    $wm = Join-Path $work 'daily-publish'
    $rq = Join-Path $work 'daily-publish-request'
    $pubArgs = @('-WatermarkPath', $wm, '-RequestPath', $rq, '-Now', '2026-10-15T18:00:00')
    $r = Lane-Run $laneB 'daily-publish.ps1' $pubArgs
    Assert 'C1 daily-publish in lane b is a SKIP (exit 0) that says LANE REFUSED' (
        $r.Code -eq 0 -and $r.Out -match 'LANE REFUSED lane b does not publish' -and $r.Out -match 'SKIP: this lane does not publish') $r.Out
    Assert 'C2 and it wrote no watermark' (-not (Test-Path -LiteralPath $wm))
    $r = Lane-Run $laneB 'daily-publish.ps1' (@('-Check') + $pubArgs)
    Assert 'C3 daily-publish -Check in lane b refuses too (exit 0)' ($r.Code -eq 0 -and $r.Out -match 'LANE REFUSED') $r.Out
    $r = Lane-Run $laneB 'daily-publish.ps1' (@('-Check') + $pubArgs) @{ GHOZTTY_LOOP_LANE = 'a' }
    Assert 'C4 negative control: the same -Check pinned to lane a is not refused and reaches the decision' (
        $r.Out -notmatch 'LANE REFUSED' -and $r.Out -match 'CHECK ONLY|SKIP: due|NOT DUE|not due') $r.Out
    $r = Lane-Run $laneB 'daily-publish.ps1' (@('-Status') + $pubArgs)
    Assert 'C5 daily-publish -Status stays open to lane b' ($r.Code -eq 0 -and $r.Out -notmatch 'LANE REFUSED') $r.Out
    $r = Lane-Run $laneB 'daily-publish.ps1' (@('-Request', '-Reason', 'lane b fixture') + $pubArgs)
    Assert 'C6 daily-publish -Request stays open to lane b (lane a honours it)' (
        $r.Code -eq 0 -and $r.Out -notmatch 'LANE REFUSED' -and (Test-Path -LiteralPath $rq)) $r.Out
    $r = Lane-Run $laneB 'publish-windows-tag.ps1' @('-Version', '9.9.9')
    Assert 'C7 publish-windows-tag in lane b refuses (exit 1)' ($r.Code -eq 1 -and $r.Out -match 'LANE REFUSED lane b does not push release tags') $r.Out
    $r = Lane-Run $laneB 'publish-windows-tag.ps1' @('-Version', '9.9.9', '-DryRun')
    Assert 'C8 publish-windows-tag -DryRun is not refused in lane b' ($r.Out -notmatch 'LANE REFUSED') $r.Out
    $installDir = Join-Path $work 'dev-install'
    $r = Lane-Run $laneB 'upgrade-ghoztty-windows.ps1' @('-InstallDir', $installDir)
    Assert 'C9 upgrade-ghoztty-windows in lane b refuses (exit 6) before touching the install' (
        $r.Code -eq 6 -and $r.Out -match 'LANE REFUSED lane b does not swap the dev install' -and -not (Test-Path $installDir)) $r.Out
    $r = Lane-Run $laneB 'launch-upgrade.ps1' @('-Prompt', 'fixture')
    Assert 'C10 launch-upgrade in lane b refuses (exit 6) before building' ($r.Code -eq 6 -and $r.Out -match 'LANE REFUSED lane b does not launch a delivery') $r.Out
    $r = Lane-Run $laneB 'deliver-windows-build.ps1' @()
    Assert 'C11 deliver-windows-build in lane b refuses (exit 6)' ($r.Code -eq 6 -and $r.Out -match 'LANE REFUSED lane b does not deliver') $r.Out

    # --- D. supervisors --------------------------------------------------------
    "D. one supervisor per lane"
    $r = Lane-Run $laneB 'go-loop-watchdog.ps1' @('-Status', '-StatePath', (Join-Path $work 'b-state.json'))
    Assert 'D1 lane b''s watchdog -Status names lane b''s mutex and task' (
        $r.Out -match 'lane:\s+b \(mutex Global\\GhozttyGoLoopWatchdog-b, task GhozttyGoLoopWatchdog-b') $r.Out
    $r = Lane-Run $mainRoot 'go-loop-watchdog.ps1' @('-Status', '-StatePath', (Join-Path $work 'a-state.json'))
    Assert 'D2 lane a''s names the historical ones' (
        $r.Out -match 'lane:\s+a \(mutex Global\\GhozttyGoLoopWatchdog, task GhozttyGoLoopWatchdog,') $r.Out

    # A daemon per lane: hidden, -DryRun, with a stop flag so every tick is
    # 'stopped' and nothing is decided or typed. Lane q, not b, so a real lane B
    # supervisor on this box never meets the fixture's mutex.
    . (Join-Path $mainRoot 'scripts\loop-session.ps1')
    $stopFile = Join-Path $work 'fixture-stop.json'
    $null = Set-LoopStop -Path $stopFile -Reason 'loop-lanes fixture'
    function Start-FixtureDog([string]$Root, [string]$Tag, [hashtable]$Vars, [string[]]$Extra = @()) {
        $log = Join-Path $work "dog-$Tag.log"
        $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File',
            (Join-Path $Root 'scripts\go-loop-watchdog.ps1'), '-DryRun', '-PollSeconds', '60',
            '-LogPath', $log, '-StopPath', $stopFile, '-StatePath', (Join-Path $work "dog-$Tag.json"),
            '-LockPath', (Join-Path $work "dog-$Tag.lock.json")) + $Extra
        $p = Invoke-WithEnv $Vars { Start-Process powershell -ArgumentList $a -WindowStyle Hidden -PassThru }
        [void]$dogs.Add($p)
        $deadline = (Get-Date).AddSeconds(45)
        while ((Get-Date) -lt $deadline) {
            $t = if (Test-Path $log) { Get-Content $log -Raw } else { '' }
            if ($t -match 'watchdog start lane=|another go-loop watchdog is running') { return $t }
            Start-Sleep -Milliseconds 500
        }
        return $(if (Test-Path $log) { Get-Content $log -Raw } else { '' })
    }
    $realA = Test-LoopLaneWatchdogRunning 'a'
    $t = Start-FixtureDog $laneB 'q' @{ GHOZTTY_LOOP_LANE = 'q' }
    Assert 'D3 a second lane''s watchdog starts beside lane a''s, on its own mutex' (
        $t -match 'watchdog start lane=q .*mutex=Global\\GhozttyGoLoopWatchdog-q' -and
        $t -notmatch 'another go-loop watchdog') $t
    Assert 'D4 and its mutex is held while it runs' (Test-LoopLaneWatchdogRunning 'q')
    if ($realA) {
        $t = Start-FixtureDog $laneB 'forced-a' @{ GHOZTTY_LOOP_LANE = 'q' } @('-MutexName', 'Global\GhozttyGoLoopWatchdog')
        Assert 'D5 negative control: on lane a''s single name, the second supervisor exits' (
            $t -match 'another go-loop watchdog is running') $t
    } else {
        "  NOTE D5 skipped: no lane-a watchdog is running on this box to hold the shared name"
    }

    # --- E. overview -----------------------------------------------------------
    "E. health and the dashboard show both lanes"
    $ledgerJson = @{ version = 1; maxId = 9
        claims = @{ T9 = @{ lane = $laneB.ToLowerInvariant(); root = $laneB; pid = 1
                at = (Get-Date).ToUniversalTime().ToString('o'); touched = (Get-Date).ToUniversalTime().ToString('o') } } } |
        ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText($ledger, $ledgerJson, (New-Object Text.UTF8Encoding($false)))
    $healthArgs = @('-Json', '-NoPaneProbe', '-LockPath', (Join-Path $mainRoot 'temp\go-loop.lock.json'),
        '-Port', '1', '-GhozttyExe', (Join-Path $work 'no-such-ghoztty.exe'))
    $vars = @{ GHOZTTY_LOOP_LEDGER = $ledger }

    $r = Lane-Run $mainRoot 'go-loop-health.ps1' $healthArgs $vars
    $h = $null; try { $h = $r.Out | ConvertFrom-Json } catch { }
    Assert 'E1 negative control: before lane b runs the loop, health lists lane a alone' (
        $h -and @($h.lanes).Count -eq 1 -and @($h.lanes)[0].id -eq 'a') $r.Out

    # Lane b "has run the loop" (a lock history) and is stopped by request.
    Set-Content -LiteralPath (Join-Path $laneB 'temp\go-loop-history.jsonl') -Value '{"action":"release"}' -Encoding ascii
    $null = Set-LoopStop -Path (Join-Path $laneB 'temp\go-loop.stop.json') -Reason 'stop lane b only'
    $r = Lane-Run $mainRoot 'go-loop-health.ps1' $healthArgs $vars
    $h = $null; try { $h = $r.Out | ConvertFrom-Json } catch { }
    $lb = if ($h) { @($h.lanes) | Where-Object { $_.id -eq 'b' } } else { $null }
    Assert 'E2 health in lane a lists both lanes' ($h -and (((@($h.lanes) | ForEach-Object { $_.id }) -join ',') -eq 'a,b')) $r.Out
    Assert 'E3 lane b reads stopped and carries its ledger claim' ($lb -and $lb.state -eq 'stopped' -and @($lb.tasks) -contains 'T9') $r.Out
    Assert 'E4 stopping lane b does not stop lane a' ($h -and $h.verdict -ne 'stopped' -and $r.Code -ne 3 -and -not $h.stopped) $r.Out
    $r = Lane-Run $laneB 'go-loop-health.ps1' @('-Json', '-NoPaneProbe', '-LockPath', (Join-Path $laneB 'temp\go-loop.lock.json'),
        '-Port', '1', '-GhozttyExe', (Join-Path $work 'no-such-ghoztty.exe')) $vars
    $hb = $null; try { $hb = $r.Out | ConvertFrom-Json } catch { }
    Assert 'E5 while lane b''s own health reads stopped (exit 3)' ($hb -and $hb.verdict -eq 'stopped' -and $r.Code -eq 3 -and $hb.lane -eq 'b') $r.Out

    $node = Get-Command node -ErrorAction SilentlyContinue
    if ($node) {
        $dj = Invoke-WithEnv $vars { & node (Join-Path $mainRoot 'scripts\task-dashboard.js') --loop 2>$null | Out-String }
        $d = $null; try { $d = $dj | ConvertFrom-Json } catch { }
        $db = if ($d) { @($d.lanes) | Where-Object { $_.id -eq 'b' } } else { $null }
        Assert 'E6 the dashboard lists both lanes, lane b stopped with its task' (
            $d -and @($d.lanes).Count -eq 2 -and $db -and $db.stopped -and @($db.tasks) -contains 'T9' -and
            -not (@($d.lanes) | Where-Object { $_.id -eq 'a' }).stopped) $dj
    } else {
        Assert 'E6 node is on PATH for the dashboard check' $false
    }

    # --- F. the morning block has one owner (T2115) ------------------------------
    "F. only one lane writes the morning digest, triage, intake and ideas"
    $r = Lane-Run $laneB 'morning-owner.ps1' @()
    Assert 'F1 with lane a never having run the loop, lane b takes the block (exit 0)' (
        $r.Code -eq 0 -and $r.Out -match 'MORNING OWNER lane b - lane a is absent') $r.Out
    # Lane a is running the loop: a held lock whose owner is THIS process, so the
    # liveness probe (pid + name + start time) answers alive.
    $me = Get-Process -Id $PID
    $now = (Get-Date).ToString('o')
    $lockA = @{ claude_pid = $PID; claude_name = $me.ProcessName; claude_start = $me.StartTime.ToString('o')
        heartbeat = $now; acquired_at = $now; pane_id = 'fixture-pane' } | ConvertTo-Json
    [IO.File]::WriteAllText((Join-Path $mainRoot 'temp\go-loop.lock.json'), $lockA, (New-Object Text.UTF8Encoding($false)))
    $r = Lane-Run $laneB 'morning-owner.ps1' @()
    Assert 'F2 while lane a holds the loop, lane b refuses with LANE REFUSED (exit 3)' (
        $r.Code -eq 3 -and $r.Out -match 'LANE REFUSED lane b does not write the morning block') $r.Out
    $r = Lane-Run $laneC 'morning-owner.ps1' @()
    Assert 'F3 and so does lane c' ($r.Code -eq 3 -and $r.Out -match 'LANE REFUSED lane c') $r.Out
    $r = Lane-Run $mainRoot 'morning-owner.ps1' @()
    Assert 'F4 lane a itself owns the block (exit 0)' ($r.Code -eq 0 -and $r.Out -match 'MORNING OWNER lane a' -and $r.Out -notmatch 'LANE REFUSED') $r.Out
    $r = Lane-Run $laneB 'morning-owner.ps1' @() @{ GHOZTTY_LOOP_LANE = 'a' }
    Assert 'F5 negative control: the same lane-b run pinned to lane a is not refused' (
        $r.Code -eq 0 -and $r.Out -notmatch 'LANE REFUSED') $r.Out
    $null = Set-LoopStop -Path (Join-Path $mainRoot 'temp\go-loop.stop.json') -Reason 'stop lane a only'
    $r = Lane-Run $laneB 'morning-owner.ps1' @()
    Assert 'F6 with lane a stopped by request, lane b takes the block so the morning read still happens' (
        $r.Code -eq 0 -and $r.Out -match 'MORNING OWNER lane b - lane a is stopped') $r.Out
    Complete-TestBody
}
finally {
    foreach ($p in $dogs) { try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch { } }
    $env:GHOZTTY_LOOP_LANE = $savedLane
    if (Test-Path $work) {
        Start-Sleep -Milliseconds 500
        Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
    }
}

# --- stamp (T783) ----------------------------------------------------------------
if ($script:failures -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard loop-lanes -Repo $Repo 2>&1 | ForEach-Object { Write-Host "  $_" }
}

""
Write-TestVerdict -Pass $script:passes -Fail $script:failures
