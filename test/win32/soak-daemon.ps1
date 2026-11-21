# The idle-time T443 soak accumulates runs, and gets off the box the moment a
# turn wants it (T841).
#
# WHY THIS FILE EXISTS. The soak daemon's whole licence to exist is that it is
# INTERRUPTIBLE. A background process that runs lanes on this box is one bad
# poll away from being the thing that wedges a turn's lane (T401), and "it
# yields" is exactly the kind of claim that is true on the day it is written and
# quietly false three edits later. So the yield is demonstrated here rather than
# asserted in a comment: a round is put in flight, the box is made busy two
# different ways, and the round's process tree is required to be DEAD - with the
# foreground process it yielded to untouched.
#
# Sections:
#   A  status on a fresh state directory: honest zeros, exit 0
#   B  rounds accumulate into the ledger and the totals, unattended
#   C  a crashed round is recorded as a crash and surfaces the T443 prompt
#   D  an explicit `pause` kills the round in flight (yield, recorded)
#   E  foreground work on the box does the same, and is NOT killed itself
#   F  the daemon does not yield to ITSELF (the marker), or it would never run
#   G  the measured lane is cache-isolated from the repo (the T401 rule)
#   I  a round never reaps a test binary it did not build (T1648)
#   U  a person using the box makes it busy (T1795)
#   L  a round runs on the lane desktop, never the user's (T1813)
#   H  stop leaves nothing behind, and stays stopped across a tick (T1795)
#
# Hermetic: its own state directory, its own scratch directory, its own mutex
# (derived from the state directory), and a FIXTURE command instead of a real
# lane - so the whole file runs in seconds and never touches the box's real
# soak, its ledger, or the repo's zig cache.
#
#   powershell -NoProfile -File test\win32\soak-daemon.ps1
#
# AMBIENT WORK (T1650). This file runs on a box where other things are working:
# the PRODUCTION soak daemon's own rounds, the other lane's floor, a sibling
# acceptance worker. Every one of those is foreground work by the very rule
# under test, so until T1650 any of them turned "the box reads idle" red and
# left the round-running sections waiting for an idle box that never came. The
# harness now asks the daemon's own rule - from a state directory nobody
# pauses, with nobody present, its own stand-ins excluded - what work on the
# box is NOT its own, and hands each such process family to the daemon under
# test as -IgnoreTrees. Section N keeps that honest: a stand-in shaped like the
# production daemon's round (and spawning a child mid-run, the way a lane
# spawns zig.exe) lives through the WHOLE file, so every run is measured under
# the T1650 condition rather than only the runs that happen to meet it.
# -NegativeControl turns the exclusion off and must score red.
param(
    [string]$Repo = 'D:\git\ghoztty',
    [switch]$NegativeControl
)

$ErrorActionPreference = 'Continue'

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:failures = 0
$script:skipped = 0
$script:asserted = 0
$script:passes = 0
$script:lastOut = ''
# A red line names WHY (T1650): the evidence is the daemon's last answer unless
# the assertion supplies its own, and without it a red D6 read as one bare word.
function Assert($name, $cond, $detail = $null) {
    $script:asserted++
    if ($cond) { Write-Host "  PASS $name"; $script:passes++; return }
    Write-Host "  FAIL $name"
    $script:failures++
    $why = if ($null -ne $detail) { [string]$detail } else { 'last daemon output: ' + [string]$script:lastOut }
    foreach ($l in @(($why.Trim() -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First 8)) {
        Write-Host "       $l"
    }
}
function Skip($name, $why) {
    $script:skipped++
    Write-Host "  SKIP $name - $why"
}

$daemon = Join-Path $Repo 'scripts\soak-daemon.ps1'
$stateDir = Join-Path $env:TEMP "ghoztty-soak-daemon-test-$PID"
# The scratch directory must sit on the repo's drive (the real one holds zig
# caches), and its NAME is the marker the daemon recognises itself by.
$qual = Split-Path -Qualifier $Repo
$scratchDir = Join-Path ($qual + '\') "ghoztty-idle-soak-test-$PID"
$marker = Split-Path -Leaf $scratchDir
$ledger = Join-Path $stateDir 'ledger.jsonl'
$statePath = Join-Path $stateDir 'state.json'
$sleepers = @()
# The harness's DELIBERATE stand-ins: processes it starts on purpose so the
# rule has something to see. Never ambient, whatever they look like.
$script:deliberate = @()
# Roots of process families on the box that are foreground work and are not
# this harness's (T1650); handed to every daemon call as -IgnoreTrees.
$script:ambientRoots = @()
$probeStateDir = Join-Path $stateDir 'ambient-probe'

function Invoke-DaemonRaw {
    param([string[]]$Argv)
    # Stringified before Out-String: a merged stream carries ErrorRecords whose
    # rendered text depends on the host's width and formatting, and the audit is
    # right that a verdict must not (T883).
    $out = & powershell @(@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $daemon) + $Argv) 2>&1 |
        ForEach-Object { "$_" } | Out-String
    return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
}

# Every ancestor of this process, oldest-checked: a parent counts only if it
# was born before its child, so a reused pid cannot adopt a stranger (T1867).
function Get-OwnAncestry {
    param($Snapshot)
    $byPid = @{}
    foreach ($p in @($Snapshot)) { $byPid[[int]$p.ProcessId] = $p }
    $set = @{ [int]$PID = $true }
    $cur = $byPid[[int]$PID]
    while ($null -ne $cur) {
        $par = $byPid[[int]$cur.ParentProcessId]
        if ($null -eq $par -or $set.ContainsKey([int]$par.ProcessId)) { break }
        if ($null -ne $par.CreationDate -and $null -ne $cur.CreationDate -and
            [datetime]$par.CreationDate -gt [datetime]$cur.CreationDate) { break }
        $set[[int]$par.ProcessId] = $true
        $cur = $par
    }
    return $set
}

# The biggest family holding $Id that holds none of this harness: climb from
# $Id while the parent is not one of our own ancestors. A sibling acceptance
# worker, the other lane's floor, the production daemon - each comes back as
# its own top, so the work it spawns NEXT is excluded too.
function Get-AmbientRoot {
    param([int]$Id)
    $snap = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    $own = Get-OwnAncestry -Snapshot $snap
    $byPid = @{}
    foreach ($p in $snap) { $byPid[[int]$p.ProcessId] = $p }
    $cur = $byPid[$Id]
    if ($null -eq $cur) { return $Id }
    while ($true) {
        $par = $byPid[[int]$cur.ParentProcessId]
        if ($null -eq $par -or $own.ContainsKey([int]$par.ProcessId)) { break }
        if ($null -ne $par.CreationDate -and $null -ne $cur.CreationDate -and
            [datetime]$par.CreationDate -gt [datetime]$cur.CreationDate) { break }
        $cur = $par
    }
    return [int]$cur.ProcessId
}

# Ask the daemon's OWN rule what foreground work is on the box that this
# harness did not start: a state directory nobody pauses, nobody present, our
# stand-ins and everything already found excluded. Each answer is climbed to
# its family's root and excluded in turn until the rule reads idle.
function Update-AmbientWork {
    if ($NegativeControl) { return }
    $prior = $env:GHOZTTY_TEST_FORCE_USER_PRESENCE
    $env:GHOZTTY_TEST_FORCE_USER_PRESENCE = 'absent'
    try {
        for ($i = 0; $i -lt 16; $i++) {
            $ign = @([int]$PID) + @($script:deliberate | ForEach-Object { [int]$_.Id })
            $argv = @('busy', '-Repo', $Repo, '-StateDir', $probeStateDir, '-ScratchDir', $scratchDir,
                '-IgnorePids', ($ign -join ','))
            if ($script:ambientRoots.Count -gt 0) { $argv += @('-IgnoreTrees', ($script:ambientRoots -join ',')) }
            $r = Invoke-DaemonRaw $argv
            if ($r.Out -notmatch 'foreground work: pid (\d+)') { return }
            $hit = [int]$Matches[1]
            $root = Get-AmbientRoot -Id $hit
            if ($script:ambientRoots -contains $root) { return }  # cannot exclude it further; let the check say so
            $script:ambientRoots += $root
            Write-Host ("  (ambient: pid {0} is foreground work that is not this harness's - its family under pid {1} is excluded)" -f $hit, $root)
        }
    }
    finally {
        if ($null -eq $prior) { Remove-Item Env:GHOZTTY_TEST_FORCE_USER_PRESENCE -ErrorAction SilentlyContinue }
        else { $env:GHOZTTY_TEST_FORCE_USER_PRESENCE = $prior }
    }
}

function Daemon {
    param([string[]]$Argv)
    $verb = if ($Argv.Count -gt 0) { $Argv[0] } else { '' }
    # A round-running verb waits for an idle box, so the exclusion is brought up
    # to date BEFORE it rather than discovered by a run that never starts.
    if ($verb -in @('run', 'start', 'tick')) { Update-AmbientWork }
    for ($try = 0; $try -lt 3; $try++) {
        $all = $Argv + @('-Repo', $Repo, '-StateDir', $stateDir, '-ScratchDir', $scratchDir, '-IgnorePids', $PID)
        if ($script:ambientRoots.Count -gt 0) { $all += @('-IgnoreTrees', ($script:ambientRoots -join ',')) }
        $r = Invoke-DaemonRaw $all
        $script:lastOut = $r.Out
        # `busy` naming a process that is none of our stand-ins is ambient work
        # that arrived since the last refresh: exclude it and ask again.
        if ($verb -ne 'busy' -or $r.Out -notmatch 'foreground work: pid (\d+)') { break }
        $hit = [int]$Matches[1]
        if (@($script:deliberate | Where-Object { $_.Id -eq $hit }).Count -gt 0) { break }
        $n = $script:ambientRoots.Count
        Update-AmbientWork
        if ($script:ambientRoots.Count -eq $n) { break }
    }
    return $r
}

function Read-Ledger {
    if (-not (Test-Path -LiteralPath $ledger)) { return @() }
    return @(Get-Content -LiteralPath $ledger -ErrorAction SilentlyContinue |
        Where-Object { $_ } | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } })
}

# A process that LOOKS like foreground work to the detector, without being any:
# the command line is what the daemon reads, so a sleeper whose arguments name
# floor-lane.ps1 is the real input to the real rule.
function Start-Sleeper {
    param([string]$Tag, [int]$Seconds = 60)
    # Quoted as ONE argument by hand: Start-Process joins -ArgumentList with
    # spaces and quotes nothing, so an unquoted command splits and the sleeper
    # dies instantly - which would make every assertion below vacuously pass.
    $p = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command',
        ('"Start-Sleep -Seconds ' + $Seconds + ' # ' + $Tag + '"'))
    $null = $p.Handle
    $script:sleepers += $p
    $script:deliberate += $p
    return $p
}

function Wait-For {
    param([scriptblock]$Cond, [int]$TimeoutSec = 30)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (& $Cond) { return $true }
        Start-Sleep -Milliseconds 400
    }
    return (& $Cond)
}

New-Item -ItemType Directory -Force $stateDir | Out-Null

# The daemon also yields to a PERSON at the box (T1795), and this script runs
# while somebody may be using it. Every section but U pins the predicate to
# `absent` so the rules they test are measured on their own; the daemon
# processes `Daemon` starts inherit it. Section U drives `present`.
$priorPresence = $env:GHOZTTY_TEST_FORCE_USER_PRESENCE
$env:GHOZTTY_TEST_FORCE_USER_PRESENCE = 'absent'

. (Join-Path $Repo 'scripts\lib\ProcessFamily.ps1')
$ambientStandIn = $null

try {
    ""
    "N. work on the box that is not this harness's never scores it red (T1650)"
    # Whatever is really running first, so N1 below can name the stand-in alone.
    Update-AmbientWork
    # The stand-in is the 2026-09-18 shape: a powershell whose command line names
    # floor-lane.ps1 and the PRODUCTION scratch directory (not ours), and which
    # spawns a `zig build`-shaped child a few seconds in - after the harness has
    # excluded it - the way a lane spawns a fresh zig.exe every few seconds.
    New-Item -ItemType Directory -Force $probeStateDir | Out-Null
    $ambientScript = Join-Path $stateDir 'ambient-standin.ps1'
    Set-Content -LiteralPath $ambientScript -Encoding ASCII -Value @(
        'param([string]$Tag)',
        'Start-Sleep -Seconds 4',
        "Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile','-Command','""Start-Sleep -Seconds 900 # zig build test T1650-ambient-child""'",
        'Start-Sleep -Seconds 900')
    $realScratch = Join-Path ($qual + '\') 'ghoztty-idle-soak'
    $ambientStandIn = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ambientScript,
        '-Tag', ('"floor-lane.ps1 -Lane none --cache-dir ' + $realScratch + '\none\zig-cache"'))
    $null = $ambientStandIn.Handle
    Start-Sleep -Milliseconds 1500
    $ign = @([int]$PID) + @($script:deliberate | ForEach-Object { [int]$_.Id })
    $argv = @('busy', '-Repo', $Repo, '-StateDir', $probeStateDir, '-ScratchDir', $scratchDir, '-IgnorePids', ($ign -join ','))
    if ($script:ambientRoots.Count -gt 0) { $argv += @('-IgnoreTrees', ($script:ambientRoots -join ',')) }
    $env:GHOZTTY_TEST_FORCE_USER_PRESENCE = 'absent'
    $r = Invoke-DaemonRaw $argv
    Assert 'N1 control: the rule itself reads the stand-in as foreground work' (
        $r.Code -eq 3 -and $r.Out -match ('foreground work: pid ' + $ambientStandIn.Id + ' ')) $r.Out
    Update-AmbientWork
    Assert 'N2 the harness finds it and excludes its family' ($script:ambientRoots -contains $ambientStandIn.Id) (
        'ambient roots: ' + ($script:ambientRoots -join ','))
    $child = $null
    $born = Wait-For {
        $script:ambChild = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($ambientStandIn.Id)" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -like '*T1650-ambient-child*' })
        $script:ambChild.Count -gt 0
    } 20
    if ($born) { $child = $script:ambChild[0] }
    Assert 'N3 the stand-in spawned its zig-shaped child after it was excluded' $born
    $argv = @('busy', '-Repo', $Repo, '-StateDir', $stateDir, '-ScratchDir', $scratchDir, '-IgnorePids', $PID)
    if ($script:ambientRoots.Count -gt 0) { $argv += @('-IgnoreTrees', ($script:ambientRoots -join ',')) }
    # Raw, NOT through Daemon: its retry would exclude the child as a new root
    # and hide a tree rule that missed it.
    $r = Invoke-DaemonRaw $argv
    Assert 'N4 a descendant born after the exclusion is excluded with its root (-IgnoreTrees)' (
        $r.Code -eq 0 -and $r.Out -match 'IDLE') $r.Out

    ""
    "A. status on a fresh state directory"
    $r = Daemon @('status')
    Assert 'A1 exit 0' ($r.Code -eq 0)
    Assert 'A2 it reports a stopped daemon with honest zeros' ($r.Out -match 'state=stopped' -and $r.Out -match 'rounds=0')
    Assert 'A3 it names the ledger a turn would read' ($r.Out -match 'ledger:')

    ""
    "B. rounds accumulate unattended"
    # `run` in this process's foreground with a round budget: the same body the
    # background daemon runs, bounded so a test can wait on it.
    # Every round-running call below is bounded (-QuitAfterBusySeconds): work
    # the exclusion did not see must cost a red line that says `box busy`, not a
    # run that waits for an idle box until the runner kills it (T1650).
    $r = Daemon @('run', '-MaxRounds', '2', '-FixtureCommand', 'exit 0',
        '-YieldPollSeconds', '1', '-IdleWaitSeconds', '1', '-QuitAfterBusySeconds', '90')
    $rows = @(Read-Ledger)
    Assert 'B1 two rounds ran' ($rows.Count -eq 2)
    Assert 'B2 both were scored pass' (@($rows | Where-Object { $_.outcome -eq 'pass' }).Count -eq 2)
    Assert 'B3 the lanes rotate' ($rows[0].lane -ne $rows[1].lane)
    $r = Daemon @('status')
    Assert 'B4 status carries the running total' ($r.Out -match 'rounds=2' -and $r.Out -match 'pass=2')
    Assert 'B5 and the last rounds, so one command is enough' ($r.Out -match 'pass')

    ""
    "C. a crashed round is recorded as a crash"
    # test-binary-soak.ps1 exits 1 when a run crashed; the daemon reads that
    # code, so a fixture exiting 1 is the same input the real instrument gives.
    $r = Daemon @('run', '-MaxRounds', '1', '-FixtureCommand', 'exit 1',
        '-YieldPollSeconds', '1', '-IdleWaitSeconds', '1', '-QuitAfterBusySeconds', '90')
    $rows = @(Read-Ledger)
    Assert 'C1 the round is scored crash' ($rows[-1].outcome -eq 'crash')
    Assert 'C2 the round log is named, so the evidence is findable' ([bool]$rows[-1].log)
    $r = Daemon @('status')
    Assert 'C3 status counts it' ($r.Out -match 'crash=1')
    Assert 'C4 and tells the reader what to do with it' ($r.Out -match 'T443')

    ""
    "D. an explicit pause kills the round in flight"
    $r = Daemon @('start', '-MaxRounds', '1', '-FixtureCommand', "Start-Sleep -Seconds 120",
        '-YieldPollSeconds', '1', '-IdleWaitSeconds', '1')
    $before = @(Read-Ledger).Count
    $inFlight = Wait-For {
        @(Get-ChildItem -Path (Join-Path $scratchDir 'rounds') -Filter '*.ps1' -ErrorAction SilentlyContinue).Count -gt 0
    } 25
    if (-not $inFlight) { Skip 'D the round never started' 'no round script appeared' }
    else {
        Start-Sleep -Seconds 2
        $r = Daemon @('pause', '-Reason', 'acceptance test wants the box')
        Assert 'D1 pause exits 0' ($r.Code -eq 0)
        $yielded = Wait-For { @(Read-Ledger | Where-Object { $_.outcome -eq 'yielded' }).Count -ge 1 } 30
        Assert 'D2 the round in flight was recorded as yielded' $yielded
        $row = @(Read-Ledger | Where-Object { $_.outcome -eq 'yielded' })[-1]
        Assert 'D3 the reason names the pause' ($null -ne $row -and $row.detail -match 'paused')
        Assert 'D4 it yielded in seconds, not at the round timeout' ($null -ne $row -and $row.seconds -lt 60)
        $r = Daemon @('busy')
        Assert 'D5 `busy` says so out loud, and exits nonzero' ($r.Code -eq 3 -and $r.Out -match 'BUSY')
        $r = Daemon @('resume')
        Assert 'D6 resume clears it' ($r.Code -eq 0 -and (Daemon @('busy')).Code -eq 0)
    }
    Daemon @('stop') | Out-Null

    ""
    "E. foreground work on the box does the same, and survives it"
    $sleeper = Start-Sleeper -Tag 'floor-lane.ps1 -Lane all' -Seconds 90
    Assert 'E0 the stand-in foreground process is alive (or nothing below means anything)' (
        (Wait-For { -not $sleeper.HasExited } 5))
    $r = Daemon @('busy')
    Assert 'E1 the detector sees foreground work' ($r.Code -eq 3 -and $r.Out -match 'floor-lane')
    $before = @(Read-Ledger).Count
    $r = Daemon @('run', '-MaxRounds', '1', '-FixtureCommand', 'exit 0',
        '-YieldPollSeconds', '1', '-IdleWaitSeconds', '1', '-QuitAfterBusySeconds', '5')
    Assert 'E2 no round was started while the box was busy' (@(Read-Ledger).Count -eq $before)
    Assert 'E2b and it said why it stood down' ($r.Out -match 'box busy')
    Assert 'E3 and the foreground process was never touched' (-not $sleeper.HasExited)
    Stop-Process -Id $sleeper.Id -Force -ErrorAction SilentlyContinue
    $freed = Wait-For { (Daemon @('busy')).Code -eq 0 } 20
    Assert 'E4 the box reads idle again once it goes away' $freed

    ""
    "F. the daemon does not yield to ITSELF"
    # The marker is what stops the yield rule from eating its own tail: a round
    # IS a `zig build`, so without it the daemon would see itself, yield, and
    # accumulate nothing forever - green on every check and useless.
    $self = Start-Sleeper -Tag ("zig build test --cache-dir $scratchDir\agent\zig-cache") -Seconds 30
    $r = Daemon @('busy')
    Assert 'F1 a process carrying the marker is not foreground work' ($r.Code -eq 0 -and $r.Out -match 'IDLE')
    $before = @(Read-Ledger).Count
    $r = Daemon @('run', '-MaxRounds', '1', '-FixtureCommand', 'exit 0', '-YieldPollSeconds', '1', '-IdleWaitSeconds', '1',
        '-QuitAfterBusySeconds', '90')
    Assert 'F2 so a round still runs beside it' (@(Read-Ledger).Count -eq $before + 1)
    Stop-Process -Id $self.Id -Force -ErrorAction SilentlyContinue

    ""
    "G. the measured lane is cache-isolated from the repo"
    $r = Daemon @('dry-run')
    Assert 'G1 it names a private local cache under the scratch dir' ($r.Out -match [regex]::Escape($scratchDir))
    Assert 'G2 each lane gets its own cache and prefix' (
        $r.Out -match '--cache-dir' -and $r.Out -match '--prefix')
    Assert 'G3 nothing points at the repo working tree' ($r.Out -notmatch ([regex]::Escape($Repo) + '\\.?zig-cache'))
    Assert 'G4 the build-runner shape is kept (a zig build, not a bare exe)' ($r.Out -match 'zig build')

    ""
    "I. a round never reaps a test binary it did not build (T1648)"
    # The round's lane ends in floor-lane's leak sweep, whose old rule was "a
    # process carrying one of the lane's test-binary names that was not running
    # when this lane started". Two concurrent runs share that name and that
    # clock, and the daemon overlaps a turn BY DESIGN - so on 2026-09-18 a round
    # took a stack of a turn's ghostty-test.exe and killed it, and the turn's
    # lane died at a bare exit 255. What separates them is where each one BUILDS.
    . (Join-Path $Repo 'scripts\lib\LaneLeak.ps1')
    $dry = (Daemon @('dry-run')).Out
    $roundCmd = ''
    foreach ($l in ($dry -split "`r?`n")) { if ($l -match 'zig build') { $roundCmd = $l; break } }
    if (-not $roundCmd) { Skip 'I the dry-run named no lane command' 'nothing matched "zig build"' }
    else {
        $roots = @(Get-LaneBuildRoot -Command $roundCmd -RepoPath $Repo)
        Assert 'I1 the round builds under its own scratch directory' (
            @($roots | Where-Object { $_ -like ($scratchDir + '*') }).Count -gt 0)
        Assert 'I2 and claims nothing in the repo working tree' (
            @($roots | Where-Object { $_ -eq $Repo }).Count -eq 0)

        # A live process carrying the REAL shared name, out of a cache root this
        # round never built into: the exact 2026-09-18 collision.
        $foreignDir = Join-Path $stateDir 'foreign-cache'
        New-Item -ItemType Directory -Force $foreignDir | Out-Null
        $foreignExe = Join-Path $foreignDir 'ghostty-test.exe'
        Copy-Item -LiteralPath "$env:SystemRoot\System32\waitfor.exe" -Destination $foreignExe -Force
        $fp = Start-Process -FilePath $foreignExe -ArgumentList '/t', '120', 'GhozttySoakForeign' `
            -PassThru -WindowStyle Hidden
        $null = $fp.Handle
        $script:sleepers += $fp
        $cand = @(Get-LaneTestProcess -ExeNames @('ghostty-test.exe') |
            Where-Object { $_.ProcessId -eq $fp.Id })
        Assert 'I3 the stand-in foreign test binary is running' ($cand.Count -eq 1)
        $split = Split-LaneLeakByRoot -Candidates $cand -Roots $roots -Names @('ghostty-test.exe')
        Assert 'I4 a round classifies it as somebody else''s, not its leak' (
            @($split.Foreign).Count -eq 1 -and @($split.Mine).Count -eq 0)

        # ...and the YIELD path, which is where the kill actually happened: the
        # round is torn down mid-flight and the foreign binary must be untouched.
        Daemon @('start', '-MaxRounds', '1', '-FixtureCommand', "Start-Sleep -Seconds 120",
            '-YieldPollSeconds', '1', '-IdleWaitSeconds', '1') | Out-Null
        $inFlight = Wait-For {
            @(Get-ChildItem -Path (Join-Path $scratchDir 'rounds') -Filter '*.ps1' -ErrorAction SilentlyContinue).Count -gt 0
        } 25
        if (-not $inFlight) { Skip 'I5 the round never started' 'no round script appeared' }
        else {
            Start-Sleep -Seconds 2
            Daemon @('pause', '-Reason', 'T1648 acceptance: yield with a foreign test binary running') | Out-Null
            $yielded = Wait-For { @(Read-Ledger | Where-Object { $_.outcome -eq 'yielded' }).Count -ge 2 } 30
            Assert 'I5 the round yielded' $yielded
            Assert 'I6 and the foreign test binary is still running' (-not $fp.HasExited)
            Daemon @('resume') | Out-Null
        }
        Daemon @('stop') | Out-Null
        Stop-Process -Id $fp.Id -Force -ErrorAction SilentlyContinue
    }

    ""
    "U. a PERSON at the box is busy too (T1795)"
    # 2026-09-27: a round ran while the user played a fullscreen game, because
    # the rule above yields to foreground WORK and a game is not work. The
    # predicate is lib\UserPresence.ps1 (T1794); `present` stands in for the
    # person without needing one, and every section above is its control.
    $env:GHOZTTY_TEST_FORCE_USER_PRESENCE = 'present'
    try {
        $r = Daemon @('busy')
        Assert 'U1 `busy` reads a present user as busy, and exits nonzero' ($r.Code -eq 3 -and $r.Out -match 'BUSY user present')
        Assert 'U2 and names why' ($r.Out -match 'GHOZTTY_TEST_FORCE_USER_PRESENCE')
        $before = @(Read-Ledger).Count
        $r = Daemon @('run', '-MaxRounds', '1', '-FixtureCommand', 'exit 0',
            '-YieldPollSeconds', '1', '-IdleWaitSeconds', '1', '-QuitAfterBusySeconds', '3')
        Assert 'U3 no round starts while somebody is using the box' (@(Read-Ledger).Count -eq $before)
        Assert 'U4 and it said so when it stood down' ($r.Out -match 'box busy' -and $r.Out -match 'user present')
    }
    finally { $env:GHOZTTY_TEST_FORCE_USER_PRESENCE = 'absent' }
    $r = Daemon @('busy')
    Assert 'U5 control: the same box with nobody at it reads IDLE' ($r.Code -eq 0 -and $r.Out -match 'IDLE')

    ""
    "L. a round runs on the lane desktop, never the user's (T1813)"
    # The win32-releasesafe round runs tests that show windows; the round's
    # runner asks which desktop it is on, from inside, and exits by the answer.
    # The control is the same probe from THIS process, which is on the input
    # desktop - so the probe can say no.
    $probe = Join-Path $stateDir 'desktop-probe.ps1'
    $laneLib = Join-Path $Repo 'scripts\lib\LaneDesktop.ps1'
    Set-Content -LiteralPath $probe -Encoding ASCII -Value @(
        (". '" + $laneLib + "'"),
        "if ([GhozttyLaneDesktop]::CurrentDesktopName() -eq 'GhozttyLaneDesktop') { exit 0 } else { exit 1 }")
    & powershell -NoProfile -ExecutionPolicy Bypass -File $probe
    Assert 'L1 control: the probe says no on the input desktop' ($LASTEXITCODE -eq 1)
    $before = @(Read-Ledger).Count
    $r = Daemon @('run', '-MaxRounds', '1', '-FixtureCommand', ("& '" + $probe + "'; exit `$LASTEXITCODE"),
        '-YieldPollSeconds', '1', '-IdleWaitSeconds', '1', '-QuitAfterBusySeconds', '90')
    $rows = @(Read-Ledger)
    Assert 'L2 the round ran and its probe found the lane desktop' ($rows.Count -eq $before + 1 -and $rows[-1].outcome -eq 'pass')
    Assert 'L3 and the daemon did not fall back to the input desktop' ($r.Out -notmatch 'INPUT desktop')

    ""
    "H. stop leaves nothing behind"
    $r = Daemon @('start', '-FixtureCommand', "Start-Sleep -Seconds 120", '-YieldPollSeconds', '1')
    $up = Wait-For { (Daemon @('status')).Out -match 'state=running' } 20
    Assert 'H1 the daemon came up' $up
    $r = Daemon @('stop')
    Assert 'H2 stop exits 0' ($r.Code -eq 0)
    $down = Wait-For { (Daemon @('status')).Out -match 'state=stopped' } 20
    Assert 'H3 the daemon is gone' $down
    $left = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -like ('*' + $marker + '*') })
    Assert 'H4 no round process survived it' ($left.Count -eq 0)
    # T1795: on 2026-09-27 `stop` was run and the next tick restarted the
    # daemon, which then ran rounds under the user's game for two weeks.
    $r = Daemon @('tick', '-FixtureCommand', "Start-Sleep -Seconds 120", '-YieldPollSeconds', '1')
    Assert 'H5 a tick after `stop` does NOT bring the daemon back' ($r.Out -match 'stopped by request')
    Start-Sleep -Seconds 3
    $r = Daemon @('status')
    Assert 'H6 and status says it was stopped on purpose' ($r.Out -match 'state=stopped-by-request')
    $r = Daemon @('start', '-MaxRounds', '1', '-FixtureCommand', 'exit 0', '-YieldPollSeconds', '1', '-IdleWaitSeconds', '1')
    Assert 'H7 an explicit start is what undoes it' ((Daemon @('status')).Out -notmatch 'stopped-by-request')
    Daemon @('stop') | Out-Null

    Complete-TestBody  # T1039: the last statement of the body an unwind can skip
}
finally {
    # --- teardown ---------------------------------------------------------
    try { Daemon @('stop') | Out-Null } catch { }
    if ($null -eq $priorPresence) { Remove-Item Env:GHOZTTY_TEST_FORCE_USER_PRESENCE -ErrorAction SilentlyContinue }
    else { $env:GHOZTTY_TEST_FORCE_USER_PRESENCE = $priorPresence }
    foreach ($s in $sleepers) { try { Stop-Process -Id $s.Id -Force -ErrorAction SilentlyContinue } catch { } }
    # The ambient stand-in and the child it spawned (T1650), root first.
    if ($null -ne $ambientStandIn) { try { $null = Stop-ProcessFamily -Id $ambientStandIn.Id } catch { } }
    Remove-Item -Recurse -Force $stateDir -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $scratchDir -ErrorAction SilentlyContinue
}

# --- stamp (T783) ---------------------------------------------------------
if ($script:failures -eq 0) {
    if ($script:skipped -gt 0) {
        "  stamp NOT updated: $($script:skipped) section(s) skipped, so this run did not cover the whole harness"
    }
    else {
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
            update -Guard soak-daemon -Repo $Repo 2>&1 | ForEach-Object { "  $_" }
    }
}

""
Write-TestVerdict -Pass $script:passes -Fail $script:failures -Skipped $script:skipped
