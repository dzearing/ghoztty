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
#   H  stop leaves nothing behind
#
# Hermetic: its own state directory, its own scratch directory, its own mutex
# (derived from the state directory), and a FIXTURE command instead of a real
# lane - so the whole file runs in seconds and never touches the box's real
# soak, its ledger, or the repo's zig cache.
#
#   powershell -NoProfile -File test\win32\soak-daemon.ps1
param(
    [string]$Repo = 'D:\git\ghoztty'
)

$ErrorActionPreference = 'Continue'

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

function Daemon {
    param([string[]]$Argv)
    $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $daemon) + $Argv +
    @('-Repo', $Repo, '-StateDir', $stateDir, '-ScratchDir', $scratchDir, '-IgnorePids', $PID)
    # Stringified before Out-String: a merged stream carries ErrorRecords whose
    # rendered text depends on the host's width and formatting, and the audit is
    # right that a verdict must not (T883).
    $out = & powershell @all 2>&1 | ForEach-Object { "$_" } | Out-String
    return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
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

try {
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
    $r = Daemon @('run', '-MaxRounds', '2', '-FixtureCommand', 'exit 0',
        '-YieldPollSeconds', '1', '-IdleWaitSeconds', '1')
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
        '-YieldPollSeconds', '1', '-IdleWaitSeconds', '1')
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
    $r = Daemon @('run', '-MaxRounds', '1', '-FixtureCommand', 'exit 0', '-YieldPollSeconds', '1', '-IdleWaitSeconds', '1')
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

    Complete-TestBody  # T1039: the last statement of the body an unwind can skip
}
finally {
    # --- teardown ---------------------------------------------------------
    try { Daemon @('stop') | Out-Null } catch { }
    foreach ($s in $sleepers) { try { Stop-Process -Id $s.Id -Force -ErrorAction SilentlyContinue } catch { } }
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
