<#
.SYNOPSIS
  Acceptance test for scripts\lib\LaneLeak.ps1 and floor-lane.ps1's
  leaked-test-binary reporting (T837).

.DESCRIPTION
  The agent lane was measured leaving its test binaries alive 25 minutes past
  `LANE agent PASS`, and nothing in the floor wrapper looked for them. The
  behavior under test is therefore three things, in this order: a leak is
  COUNTED on every run (so a recurrence is measured, not rediscovered by
  accident), a leak is EXPLAINED with a stack before anything kills it, and
  only then is it swept.

  Everything runs against a FIXTURE that deliberately outlives its lane: a
  private copy of waitfor.exe, blocking on a signal that never arrives -- a
  process with a name of our choosing, no CPU, and no relationship to any real
  test binary. Nothing here can touch a real agent test process: arms 1-7 pass
  the fixture's own name as the only exe name, and the end-to-end arm passes it
  to floor-lane.ps1 via -ExtraTestExeNames.

  Arms 1-3 are the identity rules (name match, pre-existing pids excluded,
  created-before-the-lane excluded), 4-5 the reporting, 6 the real cdb stack
  (SKIPped, loudly, when no cdb is installed), 7 the sweep, 8 the empty case,
  9 end-to-end through floor-lane.ps1 -Command, 10 the parse/wiring arm.

  Arms 15-16 are T982's half: the watchdog must survive its OWN sampling. An
  empty process-tree sample unrolls to $null in PS 5.1, and binding that null
  used to abort the entire floor run mid-lane -- so arm 15 drives the shipped
  Get-ProcessTree with samples that find nothing, and arm 16 injects a fault
  into the watchdog loop and requires the lane to still end with a verdict, a
  summary line, a non-zero exit, and no build tree left running.

  Arms 11-14 are T933's half: a test binary launched BY a test binary is the
  code under test spawning its own image (in a test build, `selfExePath` is the
  test runner), and the wrapper must both NAME that and stop counting its CPU
  as lane progress. Arm 14 stages exactly that shape -- a nested fixture
  spinning while the lane itself does nothing -- and requires the verdict to be
  WEDGED, which is what the detector answered wrongly for as long as any CPU in
  the tree counted.

  Arms 17-18 are T1648's half: two runs of the same lane share the test-binary
  NAME and the clock, so name-plus-clock cannot tell them apart -- and since the
  idle soak daemon (T841) overlaps a turn on purpose, a round reaped a turn's
  ghostty-test.exe and the turn's lane died at exit 255 with nothing printed.
  Arm 17 stages that exact collision with live processes carrying the real
  shared name out of two different cache roots, and requires the UNSCOPED rule
  to still report the foreign one (the negative control: the bug is reproducible
  against the old rule) while the scoped rule reports only its own. Arm 18 runs
  it end to end through floor-lane.ps1 -Command.

  Prints a single ALL PASS / N FAILURE(S) line, like every other script here.

  ASCII-only by design (PS 5.1 on this box mangles non-ASCII on rewrite).
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $RepoRoot 'scripts\lib\LaneLeak.ps1')
. (Join-Path $RepoRoot 'scripts\lib\CrashCatch.ps1')   # Get-CdbPath

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:Failures = 0
$script:Skipped = 0
$script:Passes = 0
function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    if ($Ok) { Write-Host ("PASS  {0}" -f $Name); $script:Passes++ }
    else {
        Write-Host ("FAIL  {0}{1}" -f $Name, $(if ($Detail) { " - $Detail" } else { '' }))
        $script:Failures++
    }
}

$Sandbox = Join-Path $env:TEMP ("lane-leak-test-{0}" -f $PID)
if (Test-Path $Sandbox) { Remove-Item $Sandbox -Recurse -Force }
New-Item -ItemType Directory -Path $Sandbox -Force | Out-Null

# The fixture: waitfor.exe under a name of our own, blocking on a signal that
# is never sent. Blocked, burning no CPU -- the exact shape of the wedged
# binaries T837 recorded.
$FixtureName = 'ghoztty-leaktest-fixture.exe'
$Fixture = Join-Path $Sandbox $FixtureName
Copy-Item -LiteralPath "$env:SystemRoot\System32\waitfor.exe" -Destination $Fixture -Force
$Started = @()

function Start-Fixture {
    param([string]$Signal)
    $p = Start-Process -FilePath $Fixture -ArgumentList '/t', '600', $Signal `
        -PassThru -WindowStyle Hidden
    $null = $p.Handle
    $script:Started += $p
    # Win32_Process must be able to see it before an arm asks about it.
    for ($i = 0; $i -lt 50; $i++) {
        if (Get-CimInstance Win32_Process -Filter "ProcessId=$($p.Id)" -ErrorAction SilentlyContinue) { break }
        Start-Sleep -Milliseconds 100
    }
    return $p
}

try {
    # -- 1: a live fixture is found by name
    $before = Get-Date
    $fx1 = Start-Fixture -Signal 'GhozttyLaneLeakArm1'
    $seen = @(Get-LaneTestProcess -ExeNames @($FixtureName))
    Check 'a running test binary is found by name' `
        (@($seen | Where-Object { $_.ProcessId -eq $fx1.Id }).Count -eq 1) "found $($seen.Count)"
    $one = @($seen | Where-Object { $_.ProcessId -eq $fx1.Id })[0]
    Check 'the report carries a start time and a cpu number' `
        ($null -ne $one.CreationDate -and $null -ne $one.CpuSeconds) `
        "creation=$($one.CreationDate) cpu=$($one.CpuSeconds)"

    # -- 2: a pid that was already running when the lane started is NEVER a leak
    $leaks = @(Get-LeakedLaneProcess -ExeNames @($FixtureName) -ExcludePids @($fx1.Id) -Since $before)
    Check 'a pre-existing pid is excluded' `
        (@($leaks | Where-Object { $_.ProcessId -eq $fx1.Id }).Count -eq 0) "got $($leaks.Count)"

    # -- 3: a process created BEFORE the lane started is not this lane's leak
    $leaks = @(Get-LeakedLaneProcess -ExeNames @($FixtureName) -Since (Get-Date).AddMinutes(5))
    Check 'a process created before the lane is excluded' `
        (@($leaks | Where-Object { $_.ProcessId -eq $fx1.Id }).Count -eq 0) "got $($leaks.Count)"

    # -- 4: the leak itself -- new since the lane started, not on the exclude list
    $leaks = @(Get-LeakedLaneProcess -ExeNames @($FixtureName) -ExcludePids @() -Since $before)
    Check 'a binary that outlived its lane is reported as a leak' `
        (@($leaks | Where-Object { $_.ProcessId -eq $fx1.Id }).Count -eq 1) "got $($leaks.Count)"

    # -- 5: reporting is loud, and -NoKill leaves the process alone
    $mine = @($leaks | Where-Object { $_.ProcessId -eq $fx1.Id })
    # Stringified before Out-String (T883): `6>&1` puts InformationRecords on
    # the pipeline and Out-String FORMATS them to the host's width, so a
    # `LANE LEAK:` line long enough to wrap fails a -match on a host the author
    # never ran. ToString() keeps the message whole everywhere.
    $out = Invoke-LaneLeakSweep -Leaked $mine -NoStack -NoKill 6>&1 |
        ForEach-Object { $_.ToString() } | Out-String
    Check 'the leak prints a LANE LEAK line naming pid and cpu' `
        ($out -match 'LANE LEAK:' -and $out -match "pid=$($fx1.Id)" -and $out -match 'cpu=') $out
    Check '-NoKill leaves the process running' `
        ($null -ne (Get-Process -Id $fx1.Id -ErrorAction SilentlyContinue)) 'fixture died under -NoKill'

    # -- 6: the stack, taken non-invasively, BEFORE anything is killed
    $cdb = Get-CdbPath
    if (-not $cdb) {
        Write-Host 'SKIP  no cdb.exe installed, so the stack arm cannot run'
        $script:Skipped++
    }
    else {
        $stack = Get-LeakedProcessStack -ProcessId $fx1.Id -CdbPath $cdb -OutDir $Sandbox -TimeoutSeconds 90
        Check 'a stack is captured for the leaked process' ($null -ne $stack) 'no transcript'
        if ($stack) {
            $body = Get-Content -LiteralPath $stack -Raw
            Check 'the stack names threads' ($body -match '(?m)^\s*#?\s*\d+\s+Id:') 'no thread header'
        }
        Check 'the non-invasive attach left the process alive' `
            ($null -ne (Get-Process -Id $fx1.Id -ErrorAction SilentlyContinue)) 'the attach killed it'
    }

    # -- 7: the sweep reaps it, and says so
    $out = Invoke-LaneLeakSweep -Leaked $mine -NoStack 6>&1 |
        ForEach-Object { $_.ToString() } | Out-String
    Start-Sleep -Milliseconds 500
    Check 'the sweep reaps the leaked process' `
        ($null -eq (Get-Process -Id $fx1.Id -ErrorAction SilentlyContinue)) 'fixture survived the sweep'
    Check 'the sweep says it swept' ($out -match 'swept') $out

    # -- 8: no leaks is a quiet zero, not a crash or a phantom count
    $r = Invoke-LaneLeakSweep -Leaked @() -NoStack
    Check 'an empty leak set counts zero' ($r.Found -eq 0 -and $r.Swept -eq 0) "found=$($r.Found)"

    # -- 9: end to end. A lane that exits clean while its "test binary" keeps
    #       running must still report the leak on its own LANE line, and reap it.
    $sig = 'GhozttyLaneLeakArm9'
    # No quotes anywhere in this command string: it travels PowerShell ->
    # floor-lane.ps1 -> cmd.exe, and an embedded quote is re-tokenized on the
    # first hop (the argument arrived as a positional `/b` and bound to -Lane).
    # The sandbox path has no spaces, so none are needed. `start /b` returns
    # immediately, which is what makes the fixture outlive the lane.
    $cmd = "start /b $Fixture /t 600 $sig"
    $laneOut = & powershell -NoProfile -File (Join-Path $RepoRoot 'scripts\floor-lane.ps1') `
        -Command $cmd -ExtraTestExeNames $FixtureName -NoCatch -SampleSeconds 2 2>&1 |
            ForEach-Object { $_.ToString() } | Out-String
    Check 'the lane still passes' ($laneOut -match 'LANE command PASS') $laneOut
    Check 'the LANE line counts the leaked test binary' `
        ($laneOut -match 'leaked test binaries: 1') $laneOut
    Check 'the lane names the leak it found' ($laneOut -match "LANE LEAK: $FixtureName") $laneOut
    Start-Sleep -Milliseconds 500
    Check 'the lane reaped the leak' `
        (@(Get-LaneTestProcess -ExeNames @($FixtureName)).Count -eq 0) 'fixture still running after the lane'

    # -- 11: a test binary UNDER a test binary is a self-spawn, and so is
    #        everything beneath it. The build runner launches each test binary
    #        directly, so this shape only ever means the code under test
    #        launched its own image (T933).
    $tree = @(
        [pscustomobject]@{ ProcessId = 100; ParentProcessId = 1; Name = 'cmd.exe' },
        [pscustomobject]@{ ProcessId = 101; ParentProcessId = 100; Name = 'zig.exe' },
        [pscustomobject]@{ ProcessId = 102; ParentProcessId = 101; Name = $FixtureName },
        [pscustomobject]@{ ProcessId = 103; ParentProcessId = 102; Name = $FixtureName },
        [pscustomobject]@{ ProcessId = 104; ParentProcessId = 103; Name = 'msedgewebview2.exe' },
        [pscustomobject]@{ ProcessId = 105; ParentProcessId = 102; Name = 'cmd.exe' }
    )
    $nested = @(Get-SelfSpawnedTestPids -Tree $tree -ExeNames @($FixtureName))
    Check 'a test binary launched by a test binary is a self-spawn' `
        ($nested -contains 103) "got [$($nested -join ',')]"
    Check "the self-spawn's own children count as its CPU too" `
        ($nested -contains 104) "got [$($nested -join ',')]"
    Check 'the test binary the BUILD RUNNER launched is not a self-spawn' `
        (-not ($nested -contains 102)) "got [$($nested -join ',')]"
    Check 'an unrelated child of the real test binary is left alone' `
        (-not ($nested -contains 105)) "got [$($nested -join ',')]"
    $none = @(Get-SelfSpawnedTestPids -Tree @($tree[0], $tree[1], $tree[2]) -ExeNames @($FixtureName))
    Check 'a tree with no self-spawn answers empty' ($none.Count -eq 0) "got $($none.Count)"
    $empty = @(Get-SelfSpawnedTestPids -Tree @() -ExeNames @($FixtureName))
    Check 'an empty tree answers empty' ($empty.Count -eq 0) "got $($empty.Count)"

    # -- 12: which command line means which launcher. This is the line that
    #        turns "it leaked again" into "the code under test spawned itself".
    Check 'the build runner is recognized by --listen=-' `
        (Test-BuildRunnerCommandLine -CommandLine 'x.exe --cache-dir=. --seed=0x1 --listen=-') ''
    Check 'a self-spawn command line is not the build runner' `
        (-not (Test-BuildRunnerCommandLine -CommandLine 'x.exe --pty-host --spec y.json')) ''
    Check 'an unreadable command line does not accuse' `
        (Test-BuildRunnerCommandLine -CommandLine '') ''

    # -- 13: the sweep NAMES a self-spawn when it reports one, so the cause is
    #        on the same line as the leak.
    $selfLeak = @([pscustomobject]@{
            ProcessId       = 424242
            ParentProcessId = 4
            Name            = $FixtureName
            ExecutablePath  = $Fixture
            CommandLine     = "$Fixture --pty-host --spec nope.json"
            CreationDate    = (Get-Date)
            CpuSeconds      = 12.5
        })
    $out = Invoke-LaneLeakSweep -Leaked $selfLeak -NoStack -NoKill 6>&1 |
        ForEach-Object { $_.ToString() } | Out-String
    Check 'the report prints the command line the leak was launched with' `
        ($out -match [regex]::Escape('--pty-host')) $out
    Check 'the report names a self-spawn as one' ($out -match 'SELF-SPAWN') $out

    # -- 14: the stall detector is NOT fooled by a self-spawned copy burning a
    #        core. The staged lane makes no progress of its own while a nested
    #        fixture spins; before T933 that CPU read as work and the lane ran
    #        to completion, so this arm fails on a regression rather than on a
    #        timing accident (the burner outlives the stall window by design).
    $Spinner = Join-Path $Sandbox 'ghoztty-leakspin-fixture.exe'
    Copy-Item -LiteralPath (Join-Path $PSHOME 'powershell.exe') -Destination $Spinner -Force
    $stallCmd = Join-Path $Sandbox 'stall.cmd'
    # A (the parent) is launched by cmd, so it is NOT a self-spawn; B is
    # launched by A, which is exactly the shape under test. Only B burns CPU.
    $burn = "`$e=(Get-Date).AddSeconds(60); while((Get-Date) -lt `$e){ `$null = 1 }"
    @(
        '@echo off',
        ('start /b "" "{0}" -NoProfile -Command "Start-Process -FilePath ''{0}'' -ArgumentList ''-NoProfile'',''-Command'',''{1}'' -WindowStyle Hidden; Start-Sleep -Seconds 60"' -f $Spinner, $burn),
        ('"{0}" /t 60 GhozttyStallArm14' -f $Fixture)
    ) | Set-Content -LiteralPath $stallCmd -Encoding ASCII
    $laneOut = & powershell -NoProfile -File (Join-Path $RepoRoot 'scripts\floor-lane.ps1') `
        -Command $stallCmd -ExtraTestExeNames 'ghoztty-leakspin-fixture.exe' -NoCatch `
        -SampleSeconds 2 -StallSeconds 12 2>&1 |
        ForEach-Object { $_.ToString() } | Out-String
    Check 'a lane whose only CPU is a self-spawned copy is reported WEDGED' `
        ($laneOut -match 'LANE command STALL') $laneOut
    Check 'the lane says whose CPU it stopped counting' `
        ($laneOut -match 'LANE SELF-SPAWN:') $laneOut
    foreach ($sp in @(Get-LaneTestProcess -ExeNames @('ghoztty-leakspin-fixture.exe'))) {
        try { Stop-Process -Id $sp.ProcessId -Force -ErrorAction Stop } catch {}
    }

    # -- 15: a sample that found NOTHING is an empty tree, never a crash (T982).
    #        Get-ProcessTree legitimately comes back empty -- the root exited
    #        between the HasExited check and the CIM query, or the query itself
    #        returned nothing on a loaded box -- and a PS 5.1 function unrolls
    #        that to $null on the way out. Bound to a Mandatory parameter, that
    #        null aborted the whole -Lane all run mid-lane with a binding
    #        exception: no verdict, no summary, and the lanes behind it skipped.
    #        The real function is lifted out of floor-lane.ps1 by the parser, so
    #        this arm exercises the shipped code rather than a copy of it.
    $laneScript = Join-Path $RepoRoot 'scripts\floor-lane.ps1'
    $laneAst = [System.Management.Automation.Language.Parser]::ParseFile($laneScript, [ref]$null, [ref]$null)
    $treeFn = @($laneAst.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $n.Name -eq 'Get-ProcessTree'
            }, $true))
    Check 'floor-lane defines Get-ProcessTree once' ($treeFn.Count -eq 1) "found $($treeFn.Count)"
    if ($treeFn.Count -eq 1) {
        . ([scriptblock]::Create($treeFn[0].Extent.Text))
        # 999999 is not a live pid, so nothing in the snapshot roots the walk.
        $rawTree = Get-ProcessTree -RootPid 999999 -Snapshot @()
        Check 'a sample that matches no process is an empty tree' `
            (@($rawTree).Count -eq 0) "got $(@($rawTree).Count)"
        # ...and the CIM query itself failing (-ErrorAction SilentlyContinue
        # leaves $snapshot null) must read the same way.
        $nullSnap = Get-ProcessTree -RootPid 999999 -Snapshot $null
        Check 'a snapshot that could not be taken is an empty tree' `
            (@($nullSnap).Count -eq 0) "got $(@($nullSnap).Count)"

        $bound = $true
        $ids = @()
        try { $ids = @(Get-SelfSpawnedTestPids -Tree $rawTree -ExeNames @($FixtureName)) }
        catch { $bound = $false; $script:LastBindError = $_.Exception.Message }
        Check 'the empty sample can be handed straight to the self-spawn check' `
            ($bound -and $ids.Count -eq 0) "bound=$bound err=$($script:LastBindError)"
    }
    $r = Invoke-LaneLeakSweep -Leaked $null -NoStack
    Check 'a null leak set counts zero, not one phantom leak' `
        ($r.Found -eq 0 -and $r.Swept -eq 0) "found=$($r.Found)"

    # -- 16: whatever goes wrong inside the watchdog, the lane still ENDS with a
    #        verdict (T982). Before this, an unexpected error escaped Invoke-Lane
    #        under $ErrorActionPreference='Stop' and took the run with it, which
    #        is indistinguishable from "the floor was never run" and leaves the
    #        lane's build tree running under a pid nobody tracks. The fault is
    #        injected because the real ones are rare races.
    $env:GHOZTTY_FLOOR_LANE_FAULT = 'arm16'
    $faultExit = -1
    try {
        $faultOut = & powershell -NoProfile -File $laneScript `
            -Command "$Fixture /t 60 GhozttyFaultArm16" -NoCatch -SampleSeconds 2 2>&1 |
            ForEach-Object { $_.ToString() } | Out-String
        $faultExit = $LASTEXITCODE
    }
    finally { Remove-Item Env:\GHOZTTY_FLOOR_LANE_FAULT -ErrorAction SilentlyContinue }
    Check 'an unexpected watchdog error names itself' ($faultOut -match 'WATCHDOG ERROR') $faultOut
    Check 'the lane it happened in is charged FAIL' ($faultOut -match 'LANE command FAIL') $faultOut
    Check 'the run still reaches its summary line' ($faultOut -match 'FLOOR SUMMARY') $faultOut
    Check 'the run exits non-zero, so the gate cannot read as green' ($faultExit -ne 0) "exit=$faultExit"
    Start-Sleep -Milliseconds 500
    Check 'the failed lane took its process tree with it' `
        (@(Get-LaneTestProcess -ExeNames @($FixtureName)).Count -eq 0) 'fixture outlived the watchdog error'

    # -- 17: T1648. A concurrent run's test binary is NOT this run's leak.
    #        The identity rules up to arm 4 are name + clock, and two runs of
    #        the same lane share both -- which is how a soak round reaped a
    #        turn's ghostty-test.exe on 2026-09-18 and left it dead at exit 255
    #        with nothing printed. The separator is the BUILD ROOT.
    Check 'an explicit --cache-dir is the run''s root' `
        (@(Get-LaneBuildRoot -Command 'zig build test --cache-dir D:\soak\none\zig-cache --prefix D:\soak\none\zig-out' `
                -RepoPath 'D:\git\ghoztty') -contains 'D:\soak\none\zig-cache') ''
    Check 'the repo is NOT a root once the command names its own cache' `
        (-not (@(Get-LaneBuildRoot -Command 'zig build test --cache-dir D:\soak\none\zig-cache' `
                    -RepoPath 'D:\git\ghoztty') -contains 'D:\git\ghoztty')) ''
    Check 'a quoted cache path is read whole' `
        (@(Get-LaneBuildRoot -Command 'zig build test --cache-dir "D:\soak dir\zig-cache"' -RepoPath 'D:\r') `
            -contains 'D:\soak dir\zig-cache') ''
    Check 'a lane with no explicit cache builds under the repo' `
        (@(Get-LaneBuildRoot -Command 'set ZIG_GLOBAL_CACHE_DIR=D:\zig-global-cache && zig build test' `
                -RepoPath 'D:\git\ghoztty') -contains 'D:\git\ghoztty') ''
    Check 'the SHARED global cache is never a root' `
        (-not (@(Get-LaneBuildRoot -Command 'zig build test --cache-dir D:\soak\c --global-cache-dir D:\zig-global-cache' `
                    -RepoPath 'D:\r') -contains 'D:\zig-global-cache')) ''
    Check 'a sibling directory is not inside the root' `
        (-not (Test-PathUnderRoot -Path 'D:\zig-out2\x.exe' -Roots @('D:\zig-out'))) ''
    Check 'a file under the root is inside it' `
        (Test-PathUnderRoot -Path 'D:\zig-out\o\ab\x.exe' -Roots @('D:\zig-out')) ''

    # The negative control, live: a real process carrying the SHARED name,
    # running out of a cache root this lane never built into.
    $ForeignDir = Join-Path $Sandbox 'foreign-cache'
    $MineDir = Join-Path $Sandbox 'mine-cache'
    New-Item -ItemType Directory -Path $ForeignDir -Force | Out-Null
    New-Item -ItemType Directory -Path $MineDir -Force | Out-Null
    $SharedName = 'ghostty-test.exe'
    $ForeignExe = Join-Path $ForeignDir $SharedName
    $MineExe = Join-Path $MineDir $SharedName
    Copy-Item -LiteralPath "$env:SystemRoot\System32\waitfor.exe" -Destination $ForeignExe -Force
    Copy-Item -LiteralPath "$env:SystemRoot\System32\waitfor.exe" -Destination $MineExe -Force

    $t17 = Get-Date
    # persistence: not a terminal launch - these are copies of waitfor.exe wearing
    # the test-binary name, so there is no session state and no flag to pass.
    $fgn = Start-Process -FilePath $ForeignExe -ArgumentList '/t', '600', 'GhozttyLaneLeakArm17F' `
        -PassThru -WindowStyle Hidden -RedirectStandardError (Join-Path $Sandbox 'arm17-foreign.err')
    $null = $fgn.Handle
    $script:Started += $fgn
    # persistence: as above - a renamed waitfor.exe, not the terminal.
    $own = Start-Process -FilePath $MineExe -ArgumentList '/t', '600', 'GhozttyLaneLeakArm17M' `
        -PassThru -WindowStyle Hidden -RedirectStandardError (Join-Path $Sandbox 'arm17-mine.err')
    $null = $own.Handle
    $script:Started += $own
    for ($i = 0; $i -lt 50; $i++) {
        $seen = @(Get-LaneTestProcess -ExeNames @($SharedName) |
            Where-Object { $_.ProcessId -eq $fgn.Id -or $_.ProcessId -eq $own.Id })
        if ($seen.Count -eq 2) { break }
        Start-Sleep -Milliseconds 100
    }

    # Unscoped -- the rule as it stood before T1648 -- reports BOTH. This is the
    # arm that proves the control reproduces the cross-kill rather than testing
    # a condition that could never happen.
    $unscoped = @(Get-LeakedLaneProcess -ExeNames @($SharedName) -Since $t17)
    Check 'without build-root scoping, the foreign binary IS reported (the T1648 bug)' `
        (@($unscoped | Where-Object { $_.ProcessId -eq $fgn.Id }).Count -eq 1) "got $($unscoped.Count)"

    $scopedLeaks = @(Get-LeakedLaneProcess -ExeNames @($SharedName) -Since $t17 `
            -Roots @($MineDir) -ScopedNames @($SharedName))
    Check 'a test binary from another run''s cache is not this lane''s leak' `
        (@($scopedLeaks | Where-Object { $_.ProcessId -eq $fgn.Id }).Count -eq 0) `
        "got [$(@($scopedLeaks | ForEach-Object { $_.ProcessId }) -join ',')]"
    Check 'this run''s own leak is still reported' `
        (@($scopedLeaks | Where-Object { $_.ProcessId -eq $own.Id }).Count -eq 1) `
        "got [$(@($scopedLeaks | ForEach-Object { $_.ProcessId }) -join ',')]"

    # A fixture name the caller passed in (-ExtraTestExeNames) is private to
    # that harness and lives wherever the harness put it, so scoping must not
    # reach it -- or arm 9's count would go to zero for the wrong reason.
    $fixtureCand = @([pscustomobject]@{
            ProcessId = 4242; Name = $FixtureName; ExecutablePath = $Fixture
            CreationDate = (Get-Date); CpuSeconds = 0.0; CommandLine = ''
        })
    $splitFx = Split-LaneLeakByRoot -Candidates $fixtureCand -Roots @($MineDir) -Names @($SharedName)
    Check 'a caller-named fixture is never scoped out by build root' `
        (@($splitFx.Mine).Count -eq 1 -and @($splitFx.Foreign).Count -eq 0) `
        "mine=$(@($splitFx.Mine).Count) foreign=$(@($splitFx.Foreign).Count)"

    # -- 18: end to end. A lane whose command names its own cache must leave a
    #        foreign test binary ALIVE, say so, and count zero leaks.
    $arm18 = Join-Path $Sandbox 'arm18.cmd'
    @(
        '@echo off',
        ('start /b "" "{0}" /t 600 GhozttyLaneLeakArm18' -f $ForeignExe)
    ) | Set-Content -LiteralPath $arm18 -Encoding ASCII
    $cmd18 = "$arm18 --cache-dir $MineDir"
    $laneOut = & powershell -NoProfile -File (Join-Path $RepoRoot 'scripts\floor-lane.ps1') `
        -Command $cmd18 -NoCatch -SampleSeconds 2 2>&1 |
        ForEach-Object { $_.ToString() } | Out-String
    Start-Sleep -Milliseconds 500
    Check 'the lane leaves the other run''s test binary running' `
        (@(Get-LaneTestProcess -ExeNames @($SharedName) |
            Where-Object { $_.ExecutablePath -eq $ForeignExe }).Count -ge 1) $laneOut
    Check 'the lane says which process it deliberately left alone' `
        ($laneOut -match 'LANE LEAK IGNORED') $laneOut
    Check 'and counts no leak of its own' ($laneOut -match 'leaked test binaries: 0') $laneOut
    foreach ($p in @(Get-LaneTestProcess -ExeNames @($SharedName) |
            Where-Object { $_.ExecutablePath -eq $ForeignExe -or $_.ExecutablePath -eq $MineExe })) {
        try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop } catch {}
    }

    # -- 10: floor-lane.ps1 parses, and its wiring is the wiring described above
    $tokens = $null; $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $RepoRoot 'scripts\floor-lane.ps1'), [ref]$tokens, [ref]$errors)
    Check 'floor-lane.ps1 parses' ($errors.Count -eq 0) "$($errors.Count) parse error(s)"
    $src = Get-Content (Join-Path $RepoRoot 'scripts\floor-lane.ps1') -Raw
    Check 'floor-lane dot-sources LaneLeak.ps1' ($src -match 'LaneLeak\.ps1') ''
    Check 'floor-lane snapshots pre-existing test binaries' ($src -match 'preTestPids') ''
    Check 'floor-lane reports the count on every lane line' `
        ($src -match 'leaked test binaries: \$leakedTests') ''
    Check 'floor-lane asks which pids are self-spawned' ($src -match 'Get-SelfSpawnedTestPids') ''
    Check 'floor-lane keeps their CPU out of the progress signal' `
        ($src -match 'Get-TreeCpu -Tree \$tree -IgnorePids') ''
    Check 'floor-lane wraps the tree sample so an empty one cannot become null' `
        ($src -match '\$tree = @\(Get-ProcessTree') ''
    Check 'floor-lane cannot leave its watchdog loop without a verdict' `
        ($src -match 'WATCHDOG ERROR') ''
    Check 'floor-lane asks where THIS run builds' ($src -match 'Get-LaneBuildRoot -Command') ''
    Check 'floor-lane scopes its leak set by that root' `
        ($src -match 'Split-LaneLeakByRoot -Candidates \$leakCandidates') ''
    Check 'floor-lane scopes only the shared test-binary names' `
        ($src -match '-Names \$script:CRASHDIAG_TEST_EXES') ''
    Complete-TestBody  # T1039: the run reached the end of its body
}
finally {
    foreach ($p in $Started) {
        try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch {}
    }
    # Anything the end-to-end arm started, whatever its pid.
    foreach ($p in @(Get-LaneTestProcess -ExeNames @($FixtureName, 'ghoztty-leakspin-fixture.exe'))) {
        try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop } catch {}
    }
    # Arm 17/18 run copies carrying the REAL test-binary name, so they are
    # matched by their path under this run's sandbox and never by name alone:
    # a real lane's ghostty-test.exe must not be touched by a cleanup.
    foreach ($p in @(Get-LaneTestProcess -ExeNames @('ghostty-test.exe'))) {
        if (-not $p.ExecutablePath) { continue }
        if (-not $p.ExecutablePath.StartsWith($Sandbox, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop } catch {}
    }
    Start-Sleep -Milliseconds 300
    if (Test-Path $Sandbox) { Remove-Item $Sandbox -Recurse -Force -ErrorAction SilentlyContinue }
}

# A clean green run stamps the covered files (T783) so scripts\guard-due.ps1 can
# answer "has this harness been run against the sweep library as it now stands?".
# Added by T883: the `lane-leak-sweep` row has existed since T837 but nothing
# here ever wrote its stamp, so the row could only be satisfied by hand and read
# as permanently due after any edit. Red leaves the stamp alone, and so does a
# run that SKIPPED the stack arm - a box with no cdb never looked at the half it
# would be vouching for.
if ($script:Failures -eq 0 -and $script:Skipped -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot 'scripts\guard-due.ps1') `
        update -Guard lane-leak-sweep -Repo $RepoRoot 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:Passes -Fail $script:Failures -Skipped $script:Skipped
