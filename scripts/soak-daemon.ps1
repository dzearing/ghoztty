<#
.SYNOPSIS
    Accumulate T443 soak runs in the box's IDLE time, and get out of the way
    the moment a turn needs the machine. T841.

.DESCRIPTION
    T443 is starved of RUNS, not of instruments. A turn can afford about five
    lane runs, the signal shows up in roughly a fifth of runs on the days it
    shows up at all, and the scarce resource is turns - not wall clock. The box
    is idle whenever a turn is thinking and completely idle whenever the loop is
    between tasks.

    So this runs the soak there. A per-user scheduled task ticks every few
    minutes; a tick starts the daemon if it is not already up; the daemon runs
    one soak round after another and appends every outcome to a ledger that
    outlives the process. Nothing about it is a turn's problem, and nothing
    about it costs a turn a minute - with one requirement that is the whole
    design:

    IT MUST NEVER BE THE THING THAT WEDGES A TURN. Two independent mechanisms:

      1. ISOLATION. The measured round is a `zig build` over its OWN local
         cache, global cache and prefix, exactly the way `test-binary-soak.ps1
         -LoadKind build` composes its load workers. A second `zig build` in
         this repo shares the lane's cache manifest locks and can stall the very
         lane a turn is timing (T401), and a wedged lane is not a data point.
      2. YIELD. Before every round, and every -YieldPollSeconds DURING a round,
         the daemon asks whether the box has foreground work on it. If it does,
         the round's whole process tree dies immediately, the round is recorded
         as `yielded`, and the daemon waits. Yielding costs a data point;
         holding the box costs a turn.

    WHAT COUNTS AS THE BOX BEING BUSY:

      - `soak-daemon.ps1 pause` was run and not resumed (explicit, and what a
        turn should reach for if it wants the machine to itself for a while).
      - A live process whose command line names foreground work: floor-lane.ps1,
        suite-run.ps1, anything under test\win32\, or a `zig build`. Our own
        descendants are excluded by the marker every one of them carries (the
        soak scratch directory name appears in the child's arguments and in the
        zig cache paths underneath it), so the daemon never mistakes itself for
        a turn.

    WHAT IT LEAVES BEHIND. `ledger.jsonl` gets one line per round - timestamp,
    lane, outcome, seconds, the lane log path, and the crash line when there is
    one - and `state.json` carries the running totals. A crash is caught the way
    a foreground crash is caught, because the round IS the foreground
    instrument: `test-binary-soak.ps1` in build-runner mode, with crash-catch
    armed, so an occurrence yields a dump and the panic text naming the victim
    test. The turn-facing command is one line:

        powershell -NoProfile -File scripts\soak-daemon.ps1 status

.PARAMETER Command
    status     what has accumulated, and whether the daemon is up (default)
    start      launch the daemon in the background if it is not already running
    stop       stop the daemon and kill any round in flight
    pause      leave the daemon up but stop it taking the box
    resume     clear a pause
    tick       what the scheduled task runs: start unless stopped or running
    run        the daemon body itself, in this process (what `start` launches)
    install    register the per-user scheduled task that keeps it alive
    uninstall  remove the task, and stop the daemon
    busy       whether the box is wanted by something else right now, and by
               what: `IDLE` and exit 0, or `BUSY <reason>` and exit 3. The
               daemon's own answer, asked out loud - which is both how a turn
               finds out why nothing is accumulating and how the yield rule is
               testable without waiting for a lane
    dry-run    print the lane command a round would run, per lane, and do
               nothing. What `-LoadDryRun` is to test-binary-soak.ps1: a way to
               check the cache isolation before spending an hour on it

.PARAMETER Lanes
    Which lanes to rotate through, in order. By default the two T443 victims -
    the agent test binary and the `none` lane, where the freetype-victim
    occurrences have landed - plus the two ReleaseSafe lanes (T846).

    The ReleaseSafe pair is here because idle time is the only place its cost
    fits: ~9-11 minutes a run from a cold optimize-mode cache, against ~3m for
    the whole Debug floor, which is why it is not a per-turn gate. It is not a
    dilution of the T443 hunt either - a ReleaseSafe round runs the SAME tests
    with the same crash instrumentation, and it additionally traps the
    undefined behavior Debug's allocator and frame reuse quietly provide for
    (T477 found two such defects at once behind 26 green Debug runs, one of them
    in shipping renderer code).

    The installed tick task does not pass this parameter, so the default IS the
    standing rotation. Changing what is covered on this box means changing the
    default, not remembering a flag.

.PARAMETER FixtureCommand
    Test hook. Makes a round run this command line instead of a real lane, so
    the yield path, the ledger and the crash classification can be exercised in
    seconds rather than in the minutes a lane costs. It must carry the soak
    marker in its text (see -Marker) or the daemon will see its own fixture as
    foreground work.

.PARAMETER MaxRounds
    Stop after this many rounds. 0 (the default) means run until stopped, which
    is what the scheduled task wants and what a test never does.

.OUTPUTS
    `status` prints one line plus the last few rounds:

        SOAK state=running rounds=41 crash=1 yielded=6 error=0 since=<iso> last=pass

    Exit 0 for every verb that did what it was asked. Exit 1 when a verb could
    not do its job (a stop that could not kill, an install that failed).

.EXAMPLE
    powershell -NoProfile -File scripts\soak-daemon.ps1 install
.EXAMPLE
    powershell -NoProfile -File scripts\soak-daemon.ps1 status
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('status', 'start', 'stop', 'pause', 'resume', 'tick', 'run', 'install', 'uninstall', 'busy', 'dry-run')]
    [string]$Command = 'status',
    [string]$Repo = 'D:\git\ghoztty',
    # A comma-separated list, not a string[]: this value crosses a process
    # boundary every time `start` launches `run`, and `powershell -File` hands a
    # script its arguments as literal strings, so an array parameter arrives as
    # one element that fails its own ValidateSet (T200's lesson, in the small).
    [string]$Lanes = 'agent,none,none-releasesafe,win32-releasesafe',
    [string]$StateDir = '',
    [string]$ScratchDir = '',
    [string]$Marker = '',
    [ValidateRange(1, 120)][int]$YieldPollSeconds = 5,
    [ValidateRange(60, 7200)][int]$RoundTimeoutSeconds = 2400,
    [ValidateRange(1, 600)][int]$IdleWaitSeconds = 30,
    [ValidateRange(0, 100000)][int]$MaxRounds = 0,
    # Give up after this many seconds of a continuously busy box (0 = wait for
    # ever, which is what the scheduled task wants: the tick restarts a daemon
    # that gave up, so neither choice loses runs).
    [ValidateRange(0, 86400)][int]$QuitAfterBusySeconds = 0,
    [ValidateRange(1, 1440)][int]$TickMinutes = 10,
    [string]$FixtureCommand = '',
    # Process ids that are NOT foreground work, comma-separated. One caller
    # needs this and it is the acceptance harness: it runs as
    # `powershell -File test\win32\soak-daemon.ps1`, which is a command line the
    # yield rule is right to read as a turn using the box - so without a way to
    # say "that one is me", the rule could only be tested by disabling it.
    [string]$IgnorePids = '',
    [string]$Reason = ''
)

$ErrorActionPreference = 'Continue'

$LaneList = @($Lanes -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
foreach ($l in $LaneList) {
    if ($l -notin @('agent', 'none', 'win32', 'none-releasesafe', 'win32-releasesafe')) {
        Write-Host "soak-daemon: unknown lane '$l' (agent|none|win32|none-releasesafe|win32-releasesafe)."
        exit 2
    }
}
if ($LaneList.Count -eq 0) { $LaneList = @('agent', 'none', 'none-releasesafe', 'win32-releasesafe') }

$IgnoreList = @($IgnorePids -split ',' | ForEach-Object { $_.Trim() } |
    Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ })

# --------------------------------------------------------------- locations
#
# The scratch directory's NAME is the marker: it appears in the soak child's
# arguments and in every zig cache path underneath it, so a single substring
# test on a command line answers "is this process mine?" for the whole family.
# It lives on the repo's drive because zig 0.15.2 asserts on a cache path whose
# drive differs from the build's cwd (T243).
if (-not $StateDir) {
    $local = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $env:TEMP 'ghoztty-local' }
    $StateDir = Join-Path $local 'ghoztty\soak-daemon'
}
if (-not $ScratchDir) {
    $qual = Split-Path -Qualifier $Repo -ErrorAction SilentlyContinue
    $root = if ($qual) { $qual + '\' } else { $env:TEMP }
    $ScratchDir = Join-Path $root 'ghoztty-idle-soak'
}
if (-not $Marker) { $Marker = Split-Path -Leaf $ScratchDir }

$StatePath = Join-Path $StateDir 'state.json'
$LedgerPath = Join-Path $StateDir 'ledger.jsonl'
$PausePath = Join-Path $StateDir 'pause.flag'
$StopPath = Join-Path $StateDir 'stop.flag'
$LogPath = Join-Path $StateDir 'daemon.log'
# Round scripts and their logs live under the SCRATCH directory, not the state
# directory, because that path carries the marker: a round launched as
# `powershell -File <scratch>\rounds\round-x.ps1` is recognisable as ours from
# its command line alone, and so is everything it spawns.
$RoundDir = Join-Path $ScratchDir 'rounds'

# One daemon per state directory: the real one and a test's one must not see
# each other's mutex, or an acceptance run would report the box's daemon as
# its own and never start.
$MutexName = 'Global\GhozttySoakDaemon-' + ([System.BitConverter]::ToString(
        [System.Security.Cryptography.MD5]::Create().ComputeHash(
            [System.Text.Encoding]::UTF8.GetBytes($StateDir.ToLowerInvariant()))) -replace '-', '').Substring(0, 12)

function Ensure-Dirs {
    foreach ($d in @($StateDir, $RoundDir)) {
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    }
}

function Log {
    param([string]$Text)
    Ensure-Dirs
    $line = ('{0} {1}' -f (Get-Date).ToString('o'), $Text)
    try { Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 } catch { }
    Write-Host $line
}

# ------------------------------------------------------------- daemon state

function Read-State {
    if (-not (Test-Path -LiteralPath $StatePath)) {
        return [pscustomobject]@{
            since = $null; rounds = 0; pass = 0; fail = 0; crash = 0
            yielded = 0; error = 0; stall = 0; last = ''; lastRun = $null; pid = 0
        }
    }
    try { return (Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json) }
    catch { return [pscustomobject]@{ since = $null; rounds = 0; pass = 0; fail = 0; crash = 0; yielded = 0; error = 0; stall = 0; last = 'unreadable'; lastRun = $null; pid = 0 } }
}

function Write-State {
    param($State)
    Ensure-Dirs
    ($State | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $StatePath -Encoding UTF8
}

function Add-LedgerEntry {
    param($Entry)
    Ensure-Dirs
    ($Entry | ConvertTo-Json -Depth 4 -Compress) | Add-Content -LiteralPath $LedgerPath -Encoding UTF8
}

function Test-DaemonRunning {
    # The mutex, not the process list: a `status` shell also has the script name
    # on its command line, and would count itself.
    $m = New-Object System.Threading.Mutex($false, $MutexName)
    try {
        if ($m.WaitOne(0)) { $m.ReleaseMutex(); return $false }
        return $true
    } finally { $m.Dispose() }
}

function Get-DaemonProcs {
    return @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.CommandLine -and $_.CommandLine -like '*soak-daemon.ps1*' -and
            $_.CommandLine -like '*run*' -and $_.ProcessId -ne $PID -and
            $_.CommandLine -like ('*' + $StateDir + '*')
        })
}

# ---------------------------------------------------------------- the yield

# Why the box is busy, or $null when it is not. The daemon asks this before
# every round and every poll interval inside one.
function Get-BoxBusyReason {
    param([int[]]$OwnPids = @())
    if (Test-Path -LiteralPath $PausePath) {
        $why = ''
        try { $why = (Get-Content -LiteralPath $PausePath -Raw).Trim() } catch { }
        if (-not $why) { $why = 'paused' }
        return "paused: $why"
    }
    if (Test-Path -LiteralPath $StopPath) { return 'stop requested' }

    $patterns = @('floor-lane.ps1', 'suite-run.ps1', '\test\win32\', 'zig build', 'zig.exe build')
    $procs = @(Get-CimInstance Win32_Process `
            -Filter "Name='powershell.exe' OR Name='pwsh.exe' OR Name='zig.exe'" -ErrorAction SilentlyContinue)
    foreach ($p in $procs) {
        if (-not $p.CommandLine) { continue }
        if ($p.ProcessId -eq $PID) { continue }
        if ($OwnPids -contains $p.ProcessId) { continue }
        if ($IgnoreList -contains $p.ProcessId) { continue }
        # Ours, at any depth: every descendant carries the scratch name.
        if ($p.CommandLine -like ('*' + $Marker + '*')) { continue }
        if ($p.CommandLine -like '*soak-daemon.ps1*') { continue }
        foreach ($pat in $patterns) {
            if ($p.CommandLine -like ('*' + $pat + '*')) {
                return ('foreground work: pid {0} {1}' -f $p.ProcessId, $pat)
            }
        }
    }
    return $null
}

# Root first, then descendants, over a fresh snapshot each pass - the ordering
# test-binary-soak.ps1 documents (T858): kill the parent before its children or
# the loop above them spawns a replacement inside the teardown window.
function Stop-Tree {
    param([int]$Id)
    try { Stop-Process -Id $Id -Force -ErrorAction SilentlyContinue } catch { }
    for ($pass = 0; $pass -lt 4; $pass++) {
        $snap = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
        $family = @($Id)
        $grew = $true
        while ($grew) {
            $grew = $false
            foreach ($p in $snap) {
                if ($family -contains $p.ParentProcessId -and -not ($family -contains $p.ProcessId)) {
                    $family += $p.ProcessId; $grew = $true
                }
            }
        }
        $alive = @($family | Where-Object { $_ -ne $PID })
        if ($alive.Count -le 1) { break }
        foreach ($id in $alive) {
            try { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue } catch { }
        }
        Start-Sleep -Milliseconds 300
    }
}

# ----------------------------------------------------------------- a round

# The command a round measures. An isolated `zig build` lane, composed the way
# test-binary-soak.ps1's build load workers are: private local cache (where the
# manifest locks live - the hazard), shared global cache (a content-addressed
# package store that is already populated, so the round compiles OUR source
# instead of rebuilding freetype every time).
function Get-RoundSeed {
    # A fresh build-runner seed per round, in the same shape the build runner
    # prints on a failing command line, so a red round is replayable verbatim:
    # `floor-lane.ps1 -Lane <lane> -Seed <seed>`.
    return ('0x{0:x8}' -f (Get-Random -Minimum 1 -Maximum ([int]::MaxValue)))
}

function Get-RoundLaneCommand {
    param([string]$Lane)
    # One cache PER LANE. The lanes alternate, and a shared cache would make
    # every round rebuild what the previous round evicted - an hour of idle time
    # spent compiling instead of running the tests the soak exists to run.
    $cache = Join-Path $ScratchDir ($Lane + '\zig-cache')
    $prefix = Join-Path $ScratchDir ($Lane + '\zig-out')
    $glob = if ($env:ZIG_GLOBAL_CACHE_DIR) { $env:ZIG_GLOBAL_CACHE_DIR }
    else {
        $q = Split-Path -Qualifier $Repo -ErrorAction SilentlyContinue
        if ($q) { Join-Path ($q + '\') 'zig-global-cache' } else { '' }
    }
    $target = switch ($Lane) {
        'agent' { 'zig build test-agent' }
        'none' { 'zig build test -Dapp-runtime=none' }
        'win32' { 'zig build test -Dapp-runtime=win32' }
        # The two test lanes compiled the way real builds are compiled (T846).
        # This is where the ReleaseSafe suite gets its STANDING cadence: it costs
        # ~9-11 minutes a run from a cold optimize-mode cache, which is too much
        # to spend on every turn and exactly what idle time is for. The crash
        # class it finds depends on the order the tests run in, so a round takes
        # a fresh random seed and the ledger keeps it - a red round nobody can
        # re-run is not a data point.
        'none-releasesafe' { 'zig build test -Dapp-runtime=none -Dtest-optimize=ReleaseSafe --seed ' + (Get-RoundSeed) }
        'win32-releasesafe' { 'zig build test -Dapp-runtime=win32 -Dtest-optimize=ReleaseSafe --seed ' + (Get-RoundSeed) }
        default { 'zig build test -Dapp-runtime=none' }
    }
    $cmd = $target + ' --cache-dir "' + $cache + '" --prefix "' + $prefix + '"'
    if ($glob) { $cmd += ' --global-cache-dir "' + $glob + '"' }
    return $cmd
}

# One round: launch it, watch it, and kill it the moment the box is wanted.
# Returns the ledger entry.
function Invoke-Round {
    param([string]$Lane, [int]$Index)

    Ensure-Dirs
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $log = Join-Path $RoundDir ("round-{0}-{1}.log" -f $stamp, $Lane)
    $runner = Join-Path $RoundDir ("round-{0}-{1}.ps1" -f $stamp, $Lane)
    $soak = Join-Path $PSScriptRoot 'test-binary-soak.ps1'
    $outDir = Join-Path $ScratchDir 'soak-out'

    # Written to a FILE and launched with -File rather than assembled as a
    # -Command one-liner: the lane command carries quoted paths, and re-quoting
    # those through Start-Process's argument joining is the exact trap this repo
    # has paid for repeatedly (T200).
    $q = { param($s) "'" + ($s -replace "'", "''") + "'" }
    if ($FixtureCommand) { $body = @($FixtureCommand) }
    else {
        $body = @(
            ('Set-Location -LiteralPath ' + (& $q $Repo)),
            ('& ' + (& $q $soak) +
                ' -LaneCommand ' + (& $q (Get-RoundLaneCommand -Lane $Lane)) +
                ' -Runs 1 -Label ' + (& $q ('idle-soak-' + $Lane)) +
                ' -OutDir ' + (& $q $outDir) + ' -Repo ' + (& $q $Repo)),
            'exit $LASTEXITCODE')
    }
    Set-Content -LiteralPath $runner -Value $body -Encoding UTF8

    $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $runner + '"'))

    $started = Get-Date
    $proc = $null
    try {
        $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argv -PassThru -WindowStyle Hidden `
            -RedirectStandardOutput $log -RedirectStandardError ($log + '.err')
    }
    catch {
        return [pscustomobject]@{
            ts = $started.ToString('o'); lane = $Lane; outcome = 'error'; seconds = 0
            log = $log; detail = ("could not launch: " + $_.Exception.Message)
        }
    }
    # Cache the handle before the child can exit, or .ExitCode reads empty
    # (the PS 5.1 trap this repo has paid for more than once).
    $null = $proc.Handle

    $deadline = $started.AddSeconds($RoundTimeoutSeconds)
    $outcome = ''
    $detail = ''
    while ($true) {
        if ($proc.HasExited) { break }
        Start-Sleep -Seconds $YieldPollSeconds
        $proc.Refresh()
        if ($proc.HasExited) { break }
        $busy = Get-BoxBusyReason -OwnPids @($proc.Id)
        if ($busy) {
            Stop-Tree -Id $proc.Id
            $outcome = 'yielded'; $detail = $busy
            break
        }
        if ((Get-Date) -gt $deadline) {
            Stop-Tree -Id $proc.Id
            $outcome = 'stall'; $detail = ("no verdict in {0}s" -f $RoundTimeoutSeconds)
            break
        }
    }
    $seconds = [int]((Get-Date) - $started).TotalSeconds

    if (-not $outcome) {
        $code = 99
        try { $proc.WaitForExit(15000) | Out-Null; $code = $proc.ExitCode } catch { }
        # test-binary-soak.ps1: 0 = no crash, 1 = at least one crash, 2 = could
        # not run. A fixture command carries its own exit code and is read the
        # same way, which is what makes the classification testable in seconds.
        switch ($code) {
            0 { $outcome = 'pass' }
            1 { $outcome = 'crash' }
            2 { $outcome = 'error'; $detail = 'soak could not run' }
            default { $outcome = 'error'; $detail = "exit $code" }
        }
        if ($outcome -eq 'crash') {
            $hit = @(Select-String -LiteralPath $log -ErrorAction SilentlyContinue `
                    -Pattern 'CRASH\s', 'Segmentation fault', 'access violation', 'panic:' | Select-Object -First 1)
            if ($hit.Count -ge 1) { $detail = $hit[0].Line.Trim() }
        }
    }

    return [pscustomobject]@{
        ts = $started.ToString('o'); lane = $Lane; outcome = $outcome
        seconds = $seconds; log = $log; detail = $detail
    }
}

# ------------------------------------------------------------------- verbs

function Invoke-Start {
    if (Test-DaemonRunning) { Log 'daemon already running'; return 0 }
    Remove-Item -LiteralPath $StopPath -Force -ErrorAction SilentlyContinue
    Ensure-Dirs
    # Start-Process JOINS -ArgumentList with spaces and quotes nothing, so any
    # value with a space in it (a path, a fixture command) arrives as several
    # arguments and the daemon dies on an unknown parameter - silently, because
    # it died in a hidden window. Quote here, once.
    $qa = { param($v) $t = [string]$v; if ($t -match '\s') { '"' + $t + '"' } else { $t } }
    $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (& $qa $PSCommandPath), 'run',
        '-Repo', (& $qa $Repo), '-StateDir', (& $qa $StateDir), '-ScratchDir', (& $qa $ScratchDir),
        '-Lanes', ($LaneList -join ','), '-YieldPollSeconds', $YieldPollSeconds,
        '-RoundTimeoutSeconds', $RoundTimeoutSeconds, '-IdleWaitSeconds', $IdleWaitSeconds)
    if ($MaxRounds -gt 0) { $argv += @('-MaxRounds', $MaxRounds) }
    if ($QuitAfterBusySeconds -gt 0) { $argv += @('-QuitAfterBusySeconds', $QuitAfterBusySeconds) }
    if ($FixtureCommand) { $argv += @('-FixtureCommand', (& $qa $FixtureCommand)) }
    if ($IgnorePids) { $argv += @('-IgnorePids', $IgnorePids) }
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argv -WindowStyle Hidden | Out-Null
    Log 'daemon started'
    return 0
}

function Invoke-Stop {
    Ensure-Dirs
    Set-Content -LiteralPath $StopPath -Value ((Get-Date).ToString('o') + ' ' + $Reason) -Encoding UTF8
    $procs = @(Get-DaemonProcs)
    foreach ($p in $procs) { Stop-Tree -Id $p.ProcessId }
    # The stop flag is a request, not the state: clear it once nothing is left,
    # so the next tick is free to start a daemon again.
    for ($i = 0; $i -lt 20; $i++) {
        if (-not (Test-DaemonRunning)) { break }
        Start-Sleep -Milliseconds 500
    }
    $still = Test-DaemonRunning
    Remove-Item -LiteralPath $StopPath -Force -ErrorAction SilentlyContinue
    if ($still) { Log 'WARNING: a daemon is still holding the mutex'; return 1 }
    Log ('daemon stopped (' + $procs.Count + ' process(es))')
    return 0
}

function Invoke-Status {
    $s = Read-State
    $state = if (Test-DaemonRunning) {
        if (Test-Path -LiteralPath $PausePath) { 'paused' } else { 'running' }
    }
    else { 'stopped' }
    $since = if ($s.since) { $s.since } else { 'never' }
    Write-Host ('SOAK state={0} rounds={1} pass={2} crash={3} fail={4} yielded={5} stall={6} error={7} since={8} last={9}' -f
        $state, $s.rounds, $s.pass, $s.crash, $s.fail, $s.yielded, $s.stall, $s.error, $since, ($(if ($s.last) { $s.last } else { 'none' })))
    Write-Host ("  ledger: $LedgerPath")
    if (Test-Path -LiteralPath $LedgerPath) {
        $tail = @(Get-Content -LiteralPath $LedgerPath -Tail 5 -ErrorAction SilentlyContinue)
        foreach ($line in $tail) {
            try {
                $e = $line | ConvertFrom-Json
                Write-Host ('  {0}  {1,-6} {2,-8} {3,4}s  {4}' -f $e.ts, $e.lane, $e.outcome, $e.seconds, $e.detail)
            }
            catch { Write-Host "  $line" }
        }
    }
    if ($s.crash -gt 0) {
        Write-Host '  CRASH DATA POINT(S) recorded - append them to T443 ARMED-WATCH LOG and unblock it.'
    }
    return 0
}

function Invoke-Run {
    $m = New-Object System.Threading.Mutex($false, $MutexName)
    if (-not $m.WaitOne(0)) { Log 'another daemon holds the mutex; exiting'; return 0 }
    try {
        Ensure-Dirs
        $state = Read-State
        if (-not $state.since) { $state.since = (Get-Date).ToString('o') }
        $state.pid = $PID
        Write-State $state
        Log ("daemon up (pid $PID, lanes " + ($LaneList -join ',') + ", scratch $ScratchDir)")

        $index = 0
        $busySince = $null
        while ($true) {
            if (Test-Path -LiteralPath $StopPath) { Log 'stop requested'; break }
            if ($MaxRounds -gt 0 -and $index -ge $MaxRounds) { Log 'round budget spent'; break }

            $busy = Get-BoxBusyReason
            if ($busy) {
                if (-not $busySince) { $busySince = Get-Date }
                if ($QuitAfterBusySeconds -gt 0 -and
                    ((Get-Date) - $busySince).TotalSeconds -ge $QuitAfterBusySeconds) {
                    Log ("box busy for {0}s ({1}); standing down, the tick will start a fresh daemon" -f
                        $QuitAfterBusySeconds, $busy)
                    break
                }
                Start-Sleep -Seconds $IdleWaitSeconds
                continue
            }
            $busySince = $null

            $lane = $LaneList[$index % $LaneList.Count]
            $entry = Invoke-Round -Lane $lane -Index $index
            $index++

            Add-LedgerEntry $entry
            $state = Read-State
            $state.rounds = [int]$state.rounds + 1
            switch ($entry.outcome) {
                'pass' { $state.pass = [int]$state.pass + 1 }
                'crash' { $state.crash = [int]$state.crash + 1 }
                'fail' { $state.fail = [int]$state.fail + 1 }
                'yielded' { $state.yielded = [int]$state.yielded + 1 }
                'stall' { $state.stall = [int]$state.stall + 1 }
                default { $state.error = [int]$state.error + 1 }
            }
            $state.last = $entry.outcome
            $state.lastRun = $entry.ts
            if (-not $state.since) { $state.since = $entry.ts }
            $state.pid = $PID
            Write-State $state
            Log ("round {0} lane={1} outcome={2} {3}s {4}" -f $index, $entry.lane, $entry.outcome, $entry.seconds, $entry.detail)

            if ($entry.outcome -eq 'yielded') { Start-Sleep -Seconds $IdleWaitSeconds }
        }
        $state = Read-State
        $state.pid = 0
        Write-State $state
        Log 'daemon down'
        return 0
    }
    finally {
        try { $m.ReleaseMutex() } catch { }
        $m.Dispose()
    }
}

# The scheduled task's entry point. It must be instant and it must be a no-op
# in every state but "down and wanted".
function Invoke-Tick {
    if (Test-Path -LiteralPath $StopPath) { Write-Host 'tick: stop flag set; not starting'; return 0 }
    if (Test-DaemonRunning) { Write-Host 'tick: already running'; return 0 }
    return (Invoke-Start)
}

function Invoke-Install {
    Ensure-Dirs
    # wscript on a generated launcher, not powershell.exe: a scheduled task
    # firing powershell gets a console before -WindowStyle can hide it, and with
    # Windows Terminal as the default terminal application that console is a
    # real window that takes focus (T1192).
    $vbs = Join-Path $StateDir 'soak-tick.vbs'
    $cmd = ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File ""{0}"" tick -Repo ""{1}"" -StateDir ""{2}"" -ScratchDir ""{3}""' -f
        $PSCommandPath, $Repo, $StateDir, $ScratchDir)
    @(
        "' GENERATED by scripts\soak-daemon.ps1 install (T841) - do not edit.",
        'Option Explicit',
        'Dim shell',
        'Set shell = CreateObject("WScript.Shell")',
        ('shell.Run "' + $cmd + '", 0, False')
    ) | Set-Content -LiteralPath $vbs -Encoding ASCII

    $tr = 'wscript.exe "' + $vbs + '"'
    & schtasks /create /tn 'GhozttySoakDaemon' /tr $tr /sc MINUTE /mo $TickMinutes /f *> $null
    if ($LASTEXITCODE -ne 0) { Log 'WARNING: could not register the tick task'; return 1 }
    Log ("installed tick task GhozttySoakDaemon (every ${TickMinutes}m) -> $vbs")
    return (Invoke-Tick)
}

function Invoke-Uninstall {
    & schtasks /delete /tn 'GhozttySoakDaemon' /f *> $null
    $rc = Invoke-Stop
    Log 'uninstalled tick task GhozttySoakDaemon'
    return $rc
}

switch ($Command) {
    'status' { exit (Invoke-Status) }
    'busy' {
        $why = Get-BoxBusyReason
        if ($why) { Write-Host "BUSY $why"; exit 3 }
        Write-Host 'IDLE'
        exit 0
    }
    'dry-run' {
        Write-Host ("scratch: $ScratchDir  (marker '$Marker')")
        foreach ($l in $LaneList) { Write-Host ("  {0}: {1}" -f $l, (Get-RoundLaneCommand -Lane $l)) }
        exit 0
    }
    'start' { exit (Invoke-Start) }
    'stop' { exit (Invoke-Stop) }
    'pause' {
        Ensure-Dirs
        Set-Content -LiteralPath $PausePath -Value ((Get-Date).ToString('o') + ' ' + $Reason) -Encoding UTF8
        Log ('paused' + $(if ($Reason) { ": $Reason" } else { '' }))
        exit 0
    }
    'resume' {
        Remove-Item -LiteralPath $PausePath -Force -ErrorAction SilentlyContinue
        Log 'resumed'
        exit 0
    }
    'tick' { exit (Invoke-Tick) }
    'run' { exit (Invoke-Run) }
    'install' { exit (Invoke-Install) }
    'uninstall' { exit (Invoke-Uninstall) }
}
