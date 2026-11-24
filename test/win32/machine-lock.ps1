# machine-lock acceptance (tracker T1982): two loop lanes share one box, so a
# script that measures time and the harness-floor sweep take box-wide locks
# (scripts\lib\MachineLock.ps1). This proves the waiting is real, bounded and
# printed, that a script without the marker never waits, and that the
# assertions go red with the lock switched off.
#
# Sections:
#   A. Uncontended: a fixture that declares the timing marker and loads
#      CleanSlate.ps1 (the hook every timing script goes through) takes the
#      lock at once and runs its body.
#   B. Bounded wait: with the lock held by this harness, the same fixture
#      prints a WAIT line naming the holder, then TIMEOUT, then ASSERTED
#      NOTHING, exits 2, and never runs its body.
#   C. Wait then go: the holder lets go a few seconds in; the fixture says it
#      acquired AFTER a wait and runs its body.
#   D. A fixture WITHOUT the marker, lock held: runs at once, prints no lock
#      line at all.
#   E. Negative control: GHOZTTY_TIMING_LOCK=0 on the marked fixture while the
#      lock is held runs the body with no wait - B's assertions fail red
#      without the lock, so B is measuring the lock.
#   F. A holder that dies without releasing does not wedge the next one.
#   G. Floor lock: `floor-lane.ps1 -Lane harness` (planted command) takes the
#      floor lock and tells the child it holds it; held by someone else, it
#      prints WAIT and TIMEOUT and runs the sweep anyway.
#   H. Every timing-marked script reaches the hook.
#   I. The per-WORKTREE test-run lock (T1658): free reads as nothing in flight;
#      held, another process sees TEST RUN IN FLIGHT with the holder's logs; a
#      run inside the holder's run is nested and never waits; acceptance-
#      parallel and floor-lane outside it wait, then refuse (exit 5 / FLOOR NOT
#      GREEN) with nothing launched; I8 is the negative control (same
#      contention, owner inherited, runs green); a dead holder never reads as
#      in flight; the claim asks the same question. Section I runs with any
#      inherited GHOZTTY_TESTRUN_OWNER cleared, so inside a real sweep the
#      harness still HOLDS the scoped lock (I0), and a copy of this script
#      started under I5's ap-run fixture refuses at once (I11) - T3409, the
#      2026-11-22 57-level recursion.
#
# Hermetic: every mutex name is suffixed by GHOZTTY_MACHINE_LOCK_SCOPE and the
# holder files live under $env:TEMP, so no real lane's lock is ever touched. No
# GUI, no foreground grab - safe on any desktop.
#
#   powershell -NoProfile -File test\win32\machine-lock.ps1
param(
    [string]$Repo = (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent)
)

$ErrorActionPreference = 'Continue'

# T3409 depth guard. Section I's I5 fixture (ap-run.ps1) really runs
# acceptance-parallel against THIS script, and is only safe because the test-run
# lock refuses it. If that refusal ever regresses, the inner copy would reach
# section I again and recurse without end (2026-11-22: 57 levels, 210
# processes). The fixture marks its children, so a copy started under it stops
# here, before it launches anything; I5 then reads red instead of the box
# filling with processes.
if ($env:GHOZTTY_MACHINE_LOCK_UNDER_APRUN) {
    Write-Host "MACHINE-LOCK RECURSION REFUSED: started under machine-lock.ps1's own ap-run fixture (pid $env:GHOZTTY_MACHINE_LOCK_UNDER_APRUN); a nested copy never runs"
    Write-Host 'ASSERTED NOTHING (recursion guard, T3409)'
    exit 2
}

# The shared scorer; dot-sourcing it ARMS the run (T1039).
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:failures = 0
$script:passes = 0

$work = Join-Path $env:TEMP "ghoztty-machine-lock-$PID"
New-Item -ItemType Directory -Force $work | Out-Null
$env:GHOZTTY_MACHINE_LOCK_SCOPE = "test-$PID"
$env:GHOZTTY_MACHINE_LOCK_DIR = Join-Path $work 'locks'
$env:GHOZTTY_LOOP_LANE = 'harness-lane'
Remove-Item Env:GHOZTTY_TIMING_LOCK -ErrorAction SilentlyContinue

# The library under test, loaded AFTER the scope is set so this harness holds
# the same (scoped) mutex its children wait on.
. (Join-Path $Repo 'scripts\lib\MachineLock.ps1')

function Assert($name, $cond, $Detail = $null) {
    if ($cond) { "  PASS $name"; $script:passes++ } else { "  FAIL $name"; $script:failures++; if ($Detail) { ($Detail -split "`r?`n") | ForEach-Object { "        | $_" } } }
}

# Fixtures. The marker is assembled so this file does not itself declare it.
$marker = '# @' + 'timing-sensitive - fixture for test\win32\machine-lock.ps1'
$cleanSlate = Join-Path $Repo 'test\win32\lib\CleanSlate.ps1'
$timed = Join-Path $work 'timed.ps1'
$plain = Join-Path $work 'plain.ps1'
$dier = Join-Path $work 'dier.ps1'
$body = @"
. '$cleanSlate'
Write-Host 'BODY RAN'
exit 0
"@
[IO.File]::WriteAllText($timed, "$marker`r`n$body")
[IO.File]::WriteAllText($plain, "# an ordinary fixture`r`n$body")
[IO.File]::WriteAllText($dier, ". '$(Join-Path $Repo 'scripts\lib\MachineLock.ps1')'`r`n`$l = Enter-MachineLock -Kind timing -Label dier.ps1`r`nWrite-Host 'DIER HOLDS'`r`nexit 0")

# Run a fixture to completion; returns @{ Code; Out; Seconds }.
function Run-Fixture {
    param([string]$Path, [hashtable]$Vars = @{})
    $saved = @{}
    foreach ($k in $Vars.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $Vars[$k]) }
    try {
        $t0 = Get-Date
        $o = & powershell -NoProfile -ExecutionPolicy Bypass -File $Path 2>&1 | ForEach-Object { $_.ToString() } | Out-String
        $code = $LASTEXITCODE
        return [pscustomobject]@{ Code = $code; Out = $o; Seconds = ((Get-Date) - $t0).TotalSeconds }
    }
    finally { foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) } }
}

try {
    Reset-TestBody

    # ---- A. uncontended
    "A. uncontended"
    $r = Run-Fixture $timed
    Assert 'A1 a marked fixture takes the timing lock at once' ($r.Out -match 'TIMING LOCK acquired: Global\\GhozttyTimingTest-test-') $r.Out
    Assert 'A2 and runs its body, exit 0' ($r.Out -match 'BODY RAN' -and $r.Code -eq 0) $r.Out
    $h = Format-MachineLockHolder (Read-MachineLockHolder -Kind timing)
    Assert 'A3 the holder file it leaves on exit reads as stale, not as a live holder' ($h -match 'timed\.ps1' -and $h -match 'pid is gone') $h

    # ---- B. bounded wait, timeout
    "B. bounded wait"
    $held = Enter-MachineLock -Kind timing -Label 'harness-holder'
    try {
        $r = Run-Fixture $timed @{ GHOZTTY_TIMING_LOCK_WAIT_MIN = '0.05' }
    } finally { Exit-MachineLock $held }
    Assert 'B1 the wait is announced and names the holder and its lane' ($r.Out -match 'TIMING LOCK WAIT: .*held by harness-holder \(lane harness-lane, pid \d+') $r.Out
    Assert 'B2 the wait is bounded: TIMEOUT within the configured 3s (+ start-up)' ($r.Out -match 'TIMING LOCK TIMEOUT after \d+s' -and $r.Seconds -lt 30) $r.Out
    Assert 'B3 a timed-out timing run is ASSERTED NOTHING, exit 2' ($r.Out -match 'ASSERTED NOTHING \(timing lock' -and $r.Code -eq 2) $r.Out
    Assert 'B4 and its body never ran' ($r.Out -notmatch 'BODY RAN') $r.Out

    # ---- C. wait, then acquire when the holder lets go
    "C. wait then go"
    $held = Enter-MachineLock -Kind timing -Label 'harness-holder'
    $outFile = Join-Path $work 'c.out'
    $env:GHOZTTY_TIMING_LOCK_WAIT_MIN = '1'
    try {
        $p = Start-Process powershell -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$timed`"") `
            -RedirectStandardOutput $outFile -NoNewWindow -PassThru
        $null = $p.Handle
        # Release only once the child has said it is waiting.
        $deadline = (Get-Date).AddSeconds(30)
        while ((Get-Date) -lt $deadline -and -not ((Test-Path $outFile) -and ((Get-Content $outFile -Raw) -match 'TIMING LOCK WAIT'))) { Start-Sleep -Milliseconds 200 }
        Start-Sleep -Seconds 2
    } finally {
        Exit-MachineLock $held
        Remove-Item Env:GHOZTTY_TIMING_LOCK_WAIT_MIN -ErrorAction SilentlyContinue
    }
    $null = $p.WaitForExit(60000)
    $cOut = if (Test-Path $outFile) { Get-Content $outFile -Raw } else { '' }
    Assert 'C1 the waiter announced its wait' ($cOut -match 'TIMING LOCK WAIT') $cOut
    Assert 'C2 and acquired AFTER a wait once the holder let go' ($cOut -match 'TIMING LOCK acquired after ([2-9]|\d\d+)s') $cOut
    Assert 'C3 and ran its body, exit 0' ($cOut -match 'BODY RAN' -and $p.ExitCode -eq 0) $cOut

    # ---- D. a script without the marker never waits
    "D. unmarked"
    $held = Enter-MachineLock -Kind timing -Label 'harness-holder'
    try { $r = Run-Fixture $plain @{ GHOZTTY_TIMING_LOCK_WAIT_MIN = '0.5' } } finally { Exit-MachineLock $held }
    Assert 'D1 an unmarked fixture runs its body while the lock is held' ($r.Out -match 'BODY RAN' -and $r.Code -eq 0) $r.Out
    Assert 'D2 and prints no lock line at all' ($r.Out -notmatch 'TIMING LOCK') $r.Out
    Assert 'D3 and did not wait out the 30s bound' ($r.Seconds -lt 25) ("{0:N1}s" -f $r.Seconds)

    # ---- E. negative control
    "E. negative control (lock off)"
    $held = Enter-MachineLock -Kind timing -Label 'harness-holder'
    try { $r = Run-Fixture $timed @{ GHOZTTY_TIMING_LOCK_WAIT_MIN = '0.05'; GHOZTTY_TIMING_LOCK = '0' } } finally { Exit-MachineLock $held }
    Assert 'E1 with the lock off, B1 would be red: no WAIT line' ($r.Out -notmatch 'TIMING LOCK WAIT') $r.Out
    Assert 'E2 and B3/B4 would be red: the body runs, exit 0' ($r.Out -match 'BODY RAN' -and $r.Code -eq 0) $r.Out

    # ---- F. a dead holder does not wedge the lock
    "F. abandoned"
    $r1 = Run-Fixture $dier
    $r = Run-Fixture $timed @{ GHOZTTY_TIMING_LOCK_WAIT_MIN = '0.05' }
    Assert 'F1 a holder exited without releasing' ($r1.Out -match 'DIER HOLDS') $r1.Out
    Assert 'F2 the next marked run takes the lock and runs' ($r.Out -match 'TIMING LOCK acquired' -and $r.Out -match 'BODY RAN' -and $r.Code -eq 0) $r.Out
    Assert 'F3 and it never timed out on the dead holder' ($r.Out -notmatch 'TIMEOUT') $r.Out

    # ---- G. floor lock in floor-lane.ps1
    "G. floor lock"
    $floor = Join-Path $Repo 'scripts\floor-lane.ps1'
    $fake = @{ harness = 'if "%GHOZTTY_FLOOR_LOCK_HELD%"=="1" (exit /b 0) else (exit /b 1)' } | ConvertTo-Json -Compress
    $runFloor = {
        param([hashtable]$Vars)
        $Vars['GHOZTTY_FLOOR_LANE_FAKE'] = $fake
        $saved = @{}
        foreach ($k in $Vars.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $Vars[$k]) }
        try {
            $o = & powershell -NoProfile -ExecutionPolicy Bypass -File $floor -Lane harness -StallSeconds 15 -NoCatch -NoSoloConfirm 2>&1 |
                ForEach-Object { $_.ToString() } | Out-String
            return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $o }
        } finally { foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) } }
    }
    $r = & $runFloor @{}
    Assert 'G1 an uncontended harness lane takes the floor lock' ($r.Out -match 'FLOOR LOCK acquired: Global\\GhozttyHarnessFloor-test-') $r.Out
    Assert 'G2 and the sweep it runs is told the lock is held (planted lane PASS)' ($r.Code -eq 0) $r.Out
    $held = Enter-MachineLock -Kind floor -Label 'harness-floor-holder'
    try { $r = & $runFloor @{ GHOZTTY_FLOOR_LOCK_WAIT_MIN = '0.05' } } finally { Exit-MachineLock $held }
    Assert 'G3 held elsewhere: the wait is announced, naming the holder' ($r.Out -match 'FLOOR LOCK WAIT: .*held by harness-floor-holder') $r.Out
    Assert 'G4 bounded: TIMEOUT, then the sweep runs anyway and says so' ($r.Out -match 'FLOOR LOCK TIMEOUT' -and $r.Out -match 'running the sweep anyway') $r.Out
    Assert 'G5 the sweep still ran and passed (a timeout is slower, not red)' ($r.Code -eq 0) $r.Out

    # ---- H. every marked script actually reaches the hook
    # The lock is taken by CleanSlate.ps1, so a timing script that never loads
    # it would declare the marker and still run beside the other lane's build.
    "H. coverage"
    $markerRx = '(?m)^[ \t]*#[ \t]*@timing-sensitive\b'
    $marked = @(Get-ChildItem (Join-Path $Repo 'test\win32') -Filter *.ps1 -File |
            Where-Object { [IO.File]::ReadAllText($_.FullName) -match $markerRx })
    $unhooked = @($marked | Where-Object { [IO.File]::ReadAllText($_.FullName) -notmatch 'lib\\CleanSlate\.ps1|MachineLock\.ps1' } |
            ForEach-Object { $_.Name })
    Assert ("H1 the timing marker is in use ({0} scripts)" -f $marked.Count) ($marked.Count -ge 5)
    Assert 'H2 every marked script loads CleanSlate.ps1 (or MachineLock.ps1), so it takes the lock' ($unhooked.Count -eq 0) ($unhooked -join "`n")
    # Teeth for H2: a planted marked script with no hook is caught by the same rule.
    $planted = "$marker`r`nWrite-Host 'no hook here'"
    Assert 'H3 negative control: a marked script with no hook fails the H2 rule' (
        $planted -match $markerRx -and $planted -notmatch 'lib\\CleanSlate\.ps1|MachineLock\.ps1')

    # ---- I. the per-worktree test-run lock (T1658)
    # A batch a previous turn backgrounded and then reset away from kept
    # running, and the next turn's own runs overlapped it. The runners now
    # wait on a per-worktree lock, nested runs pass through, and the claim
    # names a live holder.
    "I. test-run lock"
    # T3409: inside an acceptance sweep this process inherits the sweep's
    # GHOZTTY_TESTRUN_OWNER, so the holder acquisitions below would be NESTED
    # and take no mutex - and then I5's ap-run finds the lock free and really
    # runs. Section I is about this harness HOLDING the (scoped) lock, so it
    # runs as if outside any run; the outer owner is restored at the end.
    $script:outerTestRunOwner = $env:GHOZTTY_TESTRUN_OWNER
    Remove-Item Env:GHOZTTY_TESTRUN_OWNER -ErrorAction SilentlyContinue
    $mlLib = Join-Path $Repo 'scripts\lib\MachineLock.ps1'
    $probe = Join-Path $work 'inflight.ps1'
    [IO.File]::WriteAllText($probe, ". '$mlLib'`r`n`$f = Get-TestRunInFlight -Repo '$Repo'`r`nif (`$f) { Write-Host ('INFLIGHT ' + `$f.Text) } else { Write-Host 'FREE' }`r`nexit 0")
    $nest = Join-Path $work 'nest.ps1'
    [IO.File]::WriteAllText($nest, ". '$mlLib'`r`n`$l = Enter-MachineLock -Kind testrun -Repo '$Repo' -Label nest.ps1`r`nWrite-Host ('ACQUIRED=' + `$l.Acquired + ' NESTED=' + `$l.Nested)`r`nexit 0")
    $testRunDier = Join-Path $work 'testrun-dier.ps1'
    [IO.File]::WriteAllText($testRunDier, ". '$mlLib'`r`n`$l = Enter-MachineLock -Kind testrun -Repo '$Repo' -Label testrun-dier.ps1`r`nWrite-Host 'DIER HOLDS'`r`nexit 0")
    $apRun = Join-Path $work 'ap-run.ps1'
    [IO.File]::WriteAllText($apRun, "`$env:GHOZTTY_MACHINE_LOCK_UNDER_APRUN = [string]`$PID`r`n& powershell -NoProfile -ExecutionPolicy Bypass -File '$(Join-Path $Repo 'scripts\acceptance-parallel.ps1')' run -Scripts machine-lock.ps1`r`nexit `$LASTEXITCODE")
    # A child that is NOT inside this harness's run: no inherited owner.
    $outside = @{ GHOZTTY_TESTRUN_OWNER = $null; GHOZTTY_TESTRUN_LOCK_WAIT_MIN = '0.05' }

    $r = Run-Fixture $probe
    Assert 'I1 a free test-run lock reads as nothing in flight' ($r.Out -match 'FREE') $r.Out

    $held = Enter-MachineLock -Kind testrun -Repo $Repo -Label 'harness-testrun-holder' -Detail 'logs C:\fixture-logs'
    Assert 'I0 the harness really holds the scoped test-run lock (not nested in an outer sweep, T3409)' (
        $held.Acquired -and -not $held.Nested -and $null -ne $held.Mutex)
    try {
        $rIn = Run-Fixture $probe
        $rNest = Run-Fixture $nest @{ GHOZTTY_TESTRUN_LOCK_WAIT_MIN = '0.05' }
        $rOut = Run-Fixture $nest $outside
        $rAp = Run-Fixture $apRun $outside
    } finally { Exit-MachineLock $held }
    Assert 'I2 held: another process sees it IN FLIGHT, naming the holder and where its logs land' (
        $rIn.Out -match 'INFLIGHT harness-testrun-holder \(lane harness-lane, pid \d+, since [^,]+, logs C:\\fixture-logs\)') $rIn.Out
    Assert 'I5a the I5 fixture never ran a nested copy of this harness (no recursion, T3409)' (
        $rAp.Out -notmatch 'MACHINE-LOCK RECURSION REFUSED') $rAp.Out
    Assert 'I3 a run inside the holder''s run (inherited owner) is nested: acquired at once, no wait' (
        $rNest.Out -match 'nested inside pid' -and $rNest.Out -match 'ACQUIRED=True NESTED=True' -and $rNest.Out -notmatch 'WAIT') $rNest.Out
    Assert 'I4 a run outside it waits, naming the holder, and gives up bounded' (
        $rOut.Out -match 'TEST RUN LOCK WAIT: .*held by harness-testrun-holder' -and $rOut.Out -match 'TEST RUN LOCK TIMEOUT' -and $rOut.Out -match 'ACQUIRED=False') $rOut.Out
    Assert 'I5 acceptance-parallel outside the holder''s run: TEST RUN BUSY, exit 5, nothing started' (
        $rAp.Out -match 'TEST RUN LOCK WAIT' -and $rAp.Out -match 'TEST RUN BUSY' -and $rAp.Code -eq 5 -and
        $rAp.Out -notmatch 'ACCEPTANCE (due|run):' -and $rAp.Out -notmatch 'build (fresh|stale)') $rAp.Out

    # floor-lane, through the same planted harness lane section G uses.
    $runFloorTr = {
        param([hashtable]$Vars)
        $Vars['GHOZTTY_FLOOR_LANE_FAKE'] = (@{ harness = 'cmd /c exit 0' } | ConvertTo-Json -Compress)
        $saved = @{}
        foreach ($k in $Vars.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $Vars[$k]) }
        try {
            $o = & powershell -NoProfile -ExecutionPolicy Bypass -File $floor -Lane harness -StallSeconds 15 -NoCatch -NoSoloConfirm 2>&1 |
                ForEach-Object { $_.ToString() } | Out-String
            return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $o }
        } finally { foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) } }
    }
    $r = & $runFloorTr @{ GHOZTTY_TESTRUN_OWNER = $null }
    Assert 'I6 an uncontended floor-lane takes this worktree''s test-run lock and runs' (
        $r.Out -match 'TEST RUN LOCK acquired: Global\\GhozttyTestRun-[a-z0-9_]+-test-' -and $r.Code -eq 0) $r.Out
    $held = Enter-MachineLock -Kind testrun -Repo $Repo -Label 'harness-testrun-holder'
    try { $r = & $runFloorTr @{ GHOZTTY_TESTRUN_OWNER = $null; GHOZTTY_TESTRUN_LOCK_WAIT_MIN = '0.05' } } finally { Exit-MachineLock $held }
    Assert 'I7 held elsewhere: floor-lane waits, then refuses - TEST RUN BUSY, FLOOR NOT GREEN, exit 1, no lane launched' (
        $r.Out -match 'TEST RUN LOCK WAIT' -and $r.Out -match 'TEST RUN BUSY' -and $r.Out -match 'FLOOR NOT GREEN' -and
        $r.Code -eq 1 -and $r.Out -notmatch 'FLOOR LOCK acquired') $r.Out
    # Negative control for I7: the same contention with the owner inherited is nested and runs.
    $held = Enter-MachineLock -Kind testrun -Repo $Repo -Label 'harness-testrun-holder'
    try { $r = & $runFloorTr @{ GHOZTTY_TESTRUN_LOCK_WAIT_MIN = '0.05' } } finally { Exit-MachineLock $held }
    Assert 'I8 negative control: the same contention from INSIDE the holder''s run passes through and runs green' (
        $r.Out -match 'nested inside pid' -and $r.Out -notmatch 'TEST RUN BUSY' -and $r.Code -eq 0) $r.Out

    # T2151: a direct harness-floor.ps1 run (the command the claim prints for a
    # due floor) holds the same lock, and a hand-run acceptance script warns
    # when one is live. -Include with no match ends harness-floor right after
    # the lock, so nothing is swept.
    $hf = Join-Path $Repo 'scripts\harness-floor.ps1'
    $hfProbe = Join-Path $work 'hf-probe.ps1'
    [IO.File]::WriteAllText($hfProbe, "& powershell -NoProfile -ExecutionPolicy Bypass -File '$hf' -Include 'no-such-audit-t2151'`r`nexit `$LASTEXITCODE")
    $r = Run-Fixture $hfProbe $outside
    Assert 'I12 an uncontended harness-floor.ps1 takes this worktree''s test-run lock' (
        $r.Out -match 'TEST RUN LOCK acquired: Global\\GhozttyTestRun-[a-z0-9_]+-test-' -and $r.Out -match 'nothing in the floor set matches') $r.Out
    $held = Enter-MachineLock -Kind testrun -Repo $Repo -Label 'harness-testrun-holder' -Detail 'logs C:\fixture-logs'
    try {
        $rHfOut = Run-Fixture $hfProbe $outside
        $rHfIn = Run-Fixture $hfProbe @{ GHOZTTY_TESTRUN_LOCK_WAIT_MIN = '0.05' }
        $rCsOut = Run-Fixture $plain $outside
        $rCsIn = Run-Fixture $plain
    } finally { Exit-MachineLock $held }
    Assert 'I13 held elsewhere: harness-floor.ps1 waits, then refuses - TEST RUN BUSY, exit 1, nothing selected or swept' (
        $rHfOut.Out -match 'TEST RUN LOCK WAIT: .*held by harness-testrun-holder' -and $rHfOut.Out -match 'TEST RUN BUSY' -and
        $rHfOut.Code -eq 1 -and $rHfOut.Out -notmatch 'nothing in the floor set matches') $rHfOut.Out
    Assert 'I14 negative control: the same harness-floor.ps1 inside the holder''s run is nested and goes on' (
        $rHfIn.Out -match 'nested inside pid' -and $rHfIn.Out -notmatch 'TEST RUN BUSY' -and $rHfIn.Out -match 'nothing in the floor set matches') $rHfIn.Out
    Assert 'I15 a hand-run acceptance script beside a live run warns TEST RUN IN FLIGHT, naming the holder, and still runs' (
        $rCsOut.Out -match 'WARNING TEST RUN IN FLIGHT: harness-testrun-holder .*logs C:\\fixture-logs' -and
        $rCsOut.Out -match 'BODY RAN' -and $rCsOut.Code -eq 0 -and $rCsOut.Seconds -lt 25) $rCsOut.Out
    Assert 'I16 negative control: the same script inside the holder''s run says nothing' (
        $rCsIn.Out -notmatch 'TEST RUN IN FLIGHT' -and $rCsIn.Out -match 'BODY RAN') $rCsIn.Out
    $r = Run-Fixture $plain $outside
    Assert 'I17 with no run in flight the script says nothing' ($r.Out -notmatch 'TEST RUN IN FLIGHT' -and $r.Out -match 'BODY RAN') $r.Out

    $r1 = Run-Fixture $testRunDier $outside
    $r = Run-Fixture $probe
    Assert 'I9 a holder that died never reads as in flight (the mutex is asked, not the stale file)' (
        $r1.Out -match 'DIER HOLDS' -and $r.Out -match 'FREE') ($r1.Out + $r.Out)

    $execText = [IO.File]::ReadAllText((Join-Path $Repo 'scripts\go-loop-exec.ps1'))
    Assert 'I10 the loop''s claim asks the same question and prints TEST RUN IN FLIGHT' (
        $execText -match 'Get-TestRunInFlight -Repo \$Repo' -and $execText -match 'TEST RUN IN FLIGHT: ')

    # I11: the depth guard itself has teeth - a copy of this harness started
    # under the ap-run marker refuses before it launches anything.
    $r = Run-Fixture (Join-Path $Repo 'test\win32\machine-lock.ps1') @{ GHOZTTY_MACHINE_LOCK_UNDER_APRUN = '1' }
    Assert 'I11 a copy started under the ap-run fixture refuses at once: RECURSION REFUSED, exit 2, no section ran' (
        $r.Out -match 'MACHINE-LOCK RECURSION REFUSED' -and $r.Code -eq 2 -and $r.Out -notmatch '(?m)^A\. uncontended' -and $r.Seconds -lt 30) $r.Out

    Complete-TestBody
}
finally {
    if ($null -ne (Get-Variable -Name outerTestRunOwner -Scope Script -ErrorAction SilentlyContinue)) {
        if ($script:outerTestRunOwner) { $env:GHOZTTY_TESTRUN_OWNER = $script:outerTestRunOwner }
        else { Remove-Item Env:GHOZTTY_TESTRUN_OWNER -ErrorAction SilentlyContinue }
    }
    Remove-Item Env:GHOZTTY_MACHINE_LOCK_SCOPE, Env:GHOZTTY_MACHINE_LOCK_DIR, Env:GHOZTTY_LOOP_LANE -ErrorAction SilentlyContinue
    if (Test-Path $work) { Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue }
}

# --- stamp (T783) ----------------------------------------------------------------
if ($script:failures -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard machine-lock -Repo $Repo 2>&1 | ForEach-Object { Write-Host "  $_" }
}

""
Write-TestVerdict -Pass $script:passes -Fail $script:failures
