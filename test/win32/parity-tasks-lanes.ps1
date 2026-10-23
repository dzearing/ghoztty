# parity-tasks lane acceptance (tracker T1981): two loop LANES - two go.md
# loops, each in its own git worktree - must never claim the same task and
# never mint the same new task id. Both used to decide from their own copy of
# the task files, so both took the head of the queue and both minted the same
# next id (T1937 item 7: ids collided twice on 2026-10-14). The shared ledger
# in scripts\lib\LoopLedger.ps1 is the fix; this proves it, and proves the
# assertions go red without it.
#
# Each lane gets its OWN scratch task dir (a copy of one fixture), because in
# reality each worktree has its own copy of the files; the lanes are told apart
# by GHOZTTY_LOOP_LANE=a / b, and every run points GHOZTTY_LOOP_LEDGER at a
# private ledger under %TEMP%.
#
# Sections:
#   A. Claim race: two `next -Claim` processes released by one gate at the
#      same instant, one per lane, against identical queues. They claim
#      DIFFERENT tasks, every iteration, and the loser names the winner.
#   B. Negative control: the same race with GHOZTTY_LOOP_LEDGER=off hands both
#      lanes the SAME task (deterministic: identical copies collide by
#      construction), and writes no ledger.
#   C. Id race: two simultaneous `new` calls get different ids; with the
#      ledger off they collide. A later `new` allocates past the ledger's
#      high-water mark even when its own files stop lower.
#   D. Resume protection: lane a claims T1; lane b's copy shows T1
#      in-progress (as after a pull). Lane b's plain `next` reports it HELD and
#      writes nothing; its `next -Claim` does not RESUME T1 and claims other
#      work. Once lane a's claim has aged past the TTL, lane b DOES resume it.
#   F. Finished, not yet arrived (T2033): `set-status done` RESERVES the task
#      to the finishing lane; the other lane's `next -Claim` (its copy still
#      todo) skips it and says FINISHED IN OTHER LANE; the reservation ends
#      when that lane reads the close, or a TTL after the push; unpushed it is
#      kept alive. Negative control: release-at-done hands the task out.
#   E. Bookkeeping: `set-status todo` releases the claim; `set-status
#      in-progress` on another lane's task warns and does not steal it; `note`
#      is a heartbeat; `ledger` prints it read-only; a corrupt ledger is backed
#      up and recovered with a warning; a held mutex is a bounded, named wait
#      that claims nothing; a -TaskDir run with no GHOZTTY_LOOP_LEDGER never
#      writes the default ledger.
#   G. Lane-scoped tasks (T2175): a task carrying `lane: "a"` is never handed
#      to lane b, fresh or as a resume, and the skip is named; lane a gets it;
#      without the field lane b does (negative control); a lane that is not
#      one letter is a validate failure.
#
# Hermetic: fixtures, ledger and gate files live under $env:TEMP; the real task
# dir and the real ledger (%LOCALAPPDATA%\ghoztty\loop-ledger.json) are never
# touched. No GUI, no foreground grab - safe on any desktop.
#
#   powershell -NoProfile -File test\win32\parity-tasks-lanes.ps1
param(
    [string]$Repo = 'D:\git\ghoztty',
    [int]$Iterations = 4
)

$ErrorActionPreference = 'Continue'

# The shared scorer; dot-sourcing it ARMS the run (T1039).
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
# The library under test, for its mutex name and time parsing - the harness
# holds the real lock in section E rather than imitating it.
. (Join-Path $Repo 'scripts\lib\LoopLedger.ps1')

$script:failures = 0
$script:passes = 0

$taskScript = Join-Path $Repo 'scripts\parity-tasks.ps1'
$work = Join-Path $env:TEMP "ghoztty-parity-lanes-$PID"
$dirA = Join-Path $work 'lane-a'
$dirB = Join-Path $work 'lane-b'
$ledger = Join-Path $work 'loop-ledger.json'
$wrapper = Join-Path $work 'race-child.ps1'

function Assert($name, $cond, $Detail = $null) {
    if ($cond) { "  PASS $name"; $script:passes++ } else { "  FAIL $name"; $script:failures++; if ($Detail) { ($Detail -split "`r?`n") | ForEach-Object { "        | $_" } } }
}

# Run with a set of env vars applied for the child only, then restored.
# $null as a value REMOVES the variable for the child.
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

# One parity-tasks.ps1 call as lane $Lane against $Dir; returns @{ Code; Out }.
function Task-Run {
    param([string[]]$CmdArgs, [string]$Dir, [string]$Lane, [hashtable]$Extra = @{})
    $vars = @{ GHOZTTY_LOOP_LANE = $Lane; GHOZTTY_LOOP_LEDGER = $ledger }
    foreach ($k in $Extra.Keys) { $vars[$k] = $Extra[$k] }
    $res = Invoke-WithEnv $vars {
        $o = & powershell -NoProfile -ExecutionPolicy Bypass -File $taskScript @CmdArgs -TaskDir $Dir 2>&1 |
            ForEach-Object { $_.ToString() } | Out-String
        @{ Code = $LASTEXITCODE; Out = $o }
    }
    return $res
}

function New-FixtureTask {
    param([string]$Dir, [string]$Id, [string]$Status = 'todo', [switch]$WithLog, [string]$Lane)
    $lines = @(
        '---'
        "id: $Id"
        ("title: " + (ConvertTo-Json "lane fixture $Id" -Compress))
        'deps: []'
        ('status: ' + (ConvertTo-Json $Status -Compress))
        'commits: []'
        'priority: "P1"'
    )
    if ($Lane) { $lines += ('lane: ' + (ConvertTo-Json $Lane -Compress)) }
    $lines += @(
        '---'
        ''
        "# $Id - lane fixture"
        ''
    )
    if ($WithLog) { $lines += @('## Progress log', '', '- 2026-10-15 10:00: claimed; work starting.', '') }
    [System.IO.File]::WriteAllText((Join-Path $Dir "$Id.md"), ($lines -join "`n"), (New-Object System.Text.UTF8Encoding $false))
}

# Both lanes start from the same three todos - the shape two worktrees on the
# same commit are in.
function Reset-Lanes {
    param([switch]$KeepLedger)
    foreach ($d in @($dirA, $dirB)) {
        if (Test-Path $d) { Remove-Item -Recurse -Force $d }
        New-Item -ItemType Directory -Force $d | Out-Null
        foreach ($i in 1..3) { New-FixtureTask -Dir $d -Id "T$i" }
    }
    if (-not $KeepLedger) { Remove-LedgerFile }
}

function Remove-LedgerFile {
    Get-ChildItem -Path $work -Filter 'loop-ledger.json*' -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

function Read-LedgerJson {
    if (-not (Test-Path $ledger)) { return $null }
    try { return ([System.IO.File]::ReadAllText($ledger) | ConvertFrom-Json) } catch { return $null }
}

function Get-ClaimLane {
    param([string]$Id)
    if (-not $Id) { return $null }
    $j = Read-LedgerJson
    if ($null -eq $j -or $null -eq $j.claims) { return $null }
    $c = $j.claims.PSObject.Properties[$Id]
    if ($null -eq $c) { return $null }
    return [string]$c.Value.lane
}

# Move a claim's heartbeat into the past, the way a lane that died leaves it.
function Set-ClaimTouchedAgo {
    param([string]$Id, [double]$Minutes)
    $j = Read-LedgerJson
    $iso = (Get-Date).ToUniversalTime().AddMinutes(-$Minutes).ToString('o')
    $j.claims.PSObject.Properties[$Id].Value.touched = $iso
    [System.IO.File]::WriteAllText($ledger, ($j | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding $false))
    return $iso
}

function Get-FileStatus {
    param([string]$Dir, [string]$Id)
    $t = [System.IO.File]::ReadAllText((Join-Path $Dir "$Id.md"))
    if ($t -match '(?m)^status:\s*"?([^"\r\n]*)"?') { return $Matches[1] }
    return ''
}

# The race child: opens the gate, says it is ready, blocks until the parent
# releases both lanes at once, then runs the verb IN-PROCESS (no second
# powershell start-up between the gate and the work, which would spread the
# two lanes apart by hundreds of milliseconds).
$wrapperText = @'
param([string]$Gate, [string]$Ready, [string]$Script, [string]$Out, [string]$Verb, [string]$TaskDir)
$ErrorActionPreference = 'Continue'
$ev = [System.Threading.EventWaitHandle]::OpenExisting($Gate)
[System.IO.File]::WriteAllText($Ready, 'ready')
$null = $ev.WaitOne(60000)
$splat = @{ Command = $Verb; TaskDir = $TaskDir }
if ($Verb -eq 'next') { $splat['Claim'] = $true }
if ($Verb -eq 'new') { $splat['Title'] = 'lane race filing'; $splat['NoSimilarCheck'] = $true }
$text = ''
try { $text = (& $Script @splat *>&1 | ForEach-Object { $_.ToString() } | Out-String) }
catch { $text += "THREW: " + $_.Exception.Message }
[System.IO.File]::WriteAllText($Out, $text + "`nEXIT=$LASTEXITCODE`n")
'@

# Release lane a (in $dirA) and lane b (in $dirB) at the same instant.
# Returns @{ a = <output>; b = <output> }.
function Invoke-LaneRace {
    param([string]$Verb, [string]$Tag, [string]$LedgerValue)
    $gate = "Local\ghoztty-lanes-gate-$PID-$Tag"
    $ev = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, $gate)
    $procs = @{}
    $files = @{}
    try {
        foreach ($lane in @('a', 'b')) {
            $dir = if ($lane -eq 'a') { $dirA } else { $dirB }
            $out = Join-Path $work "race-$Tag-$lane.out"
            $ready = Join-Path $work "race-$Tag-$lane.ready"
            Remove-Item -Force $out, $ready -ErrorAction SilentlyContinue
            $files[$lane] = @{ Out = $out; Ready = $ready }
            $p = Invoke-WithEnv @{ GHOZTTY_LOOP_LANE = $lane; GHOZTTY_LOOP_LEDGER = $LedgerValue } {
                Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -PassThru -ArgumentList @(
                    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $wrapper,
                    '-Gate', $gate, '-Ready', $ready, '-Script', $taskScript,
                    '-Out', $out, '-Verb', $Verb, '-TaskDir', $dir)
            }
            $null = $p.Handle   # T197: cache the handle before anything waits
            $procs[$lane] = $p
        }
        $deadline = (Get-Date).AddSeconds(60)
        while ((Get-Date) -lt $deadline -and -not ((Test-Path $files.a.Ready) -and (Test-Path $files.b.Ready))) {
            Start-Sleep -Milliseconds 50
        }
        $null = $ev.Set()
        foreach ($lane in @('a', 'b')) {
            if (-not $procs[$lane].WaitForExit(90000)) {
                Stop-Process -Id $procs[$lane].Id -Force -ErrorAction SilentlyContinue
            }
        }
    }
    finally { $ev.Dispose() }
    $res = @{}
    foreach ($lane in @('a', 'b')) {
        $res[$lane] = if (Test-Path $files[$lane].Out) { [System.IO.File]::ReadAllText($files[$lane].Out) } else { '(no output)' }
    }
    return $res
}

function Get-Claimed([string]$Text) {
    if ($Text -match 'CLAIMED: (T\d+)') { return $Matches[1] }
    return $null
}
function Get-Created([string]$Text) {
    if ($Text -match 'created (T\d+)') { return $Matches[1] }
    return $null
}

$savedLedgerEnv = $env:GHOZTTY_LOOP_LEDGER
$savedLaneEnv = $env:GHOZTTY_LOOP_LANE
$savedTtlEnv = $env:GHOZTTY_LOOP_LEDGER_TTL_MIN
$env:GHOZTTY_LOOP_LEDGER_TTL_MIN = $null

try {
    if (Test-Path $work) { Remove-Item -Recurse -Force $work }
    New-Item -ItemType Directory -Force $work | Out-Null
    [System.IO.File]::WriteAllText($wrapper, $wrapperText, (New-Object System.Text.UTF8Encoding $false))

    # --- A. claim race ----------------------------------------------------------
    'A. two lanes released at the same instant claim different tasks'
    $distinct = 0
    $loserNamed = 0
    $bothLaneClaims = 0
    for ($i = 1; $i -le $Iterations; $i++) {
        Reset-Lanes
        $r = Invoke-LaneRace -Verb 'next' -Tag "claim$i" -LedgerValue $ledger
        $ca = Get-Claimed $r.a
        $cb = Get-Claimed $r.b
        "    iter $i : lane a -> $ca, lane b -> $cb"
        if ($ca -and $cb -and $ca -ne $cb) { $distinct++ }
        else { "      lane a output:`n$($r.a)`n      lane b output:`n$($r.b)" }
        # Whoever got T1 second must say who has it.
        $loser = if ($ca -eq 'T1') { 'b' } else { 'a' }
        $winner = if ($loser -eq 'a') { 'b' } else { 'a' }
        if ($r[$loser] -match "HELD BY OTHER LANE: T1 \(lane $winner\)") { $loserNamed++ }
        if ((Get-ClaimLane $ca) -eq 'a' -and (Get-ClaimLane $cb) -eq 'b') { $bothLaneClaims++ }
    }
    Assert "A1 every iteration ($Iterations) handed the two lanes DIFFERENT tasks" ($distinct -eq $Iterations)
    Assert 'A2 the lane that lost T1 named the winning lane (HELD BY OTHER LANE)' ($loserNamed -eq $Iterations)
    Assert 'A3 the ledger records each claim under the lane that made it' ($bothLaneClaims -eq $Iterations)

    # --- B. negative control: the same race with the ledger off -----------------
    ""
    'B. negative control: GHOZTTY_LOOP_LEDGER=off collides'
    $same = 0
    for ($i = 1; $i -le 2; $i++) {
        Reset-Lanes
        $r = Invoke-LaneRace -Verb 'next' -Tag "off$i" -LedgerValue 'off'
        $ca = Get-Claimed $r.a
        $cb = Get-Claimed $r.b
        "    iter $i : lane a -> $ca, lane b -> $cb"
        if ($ca -and $ca -eq $cb) { $same++ }
    }
    Assert 'B1 without the ledger both lanes claim the SAME task (the A1 assertion can go red)' ($same -ge 1)
    Assert 'B2 with the ledger off no ledger file is written' (-not (Test-Path $ledger))

    # --- C. id race ----------------------------------------------------------------
    ""
    'C. two simultaneous `new` calls get different ids'
    $distinctIds = 0
    for ($i = 1; $i -le $Iterations; $i++) {
        Reset-Lanes
        $r = Invoke-LaneRace -Verb 'new' -Tag "new$i" -LedgerValue $ledger
        $na = Get-Created $r.a
        $nb = Get-Created $r.b
        "    iter $i : lane a -> $na, lane b -> $nb"
        if ($na -and $nb -and $na -ne $nb) { $distinctIds++ }
        else { "      lane a output:`n$($r.a)`n      lane b output:`n$($r.b)" }
    }
    Assert "C1 every iteration ($Iterations) minted two DIFFERENT ids" ($distinctIds -eq $Iterations)
    $j = Read-LedgerJson
    Assert 'C2 the ledger high-water mark is the larger of the two (T5)' ($null -ne $j -and [int]$j.maxId -eq 5)

    # A lane whose own files stop at T3 still allocates past the mark.
    $r = Task-Run @('new', '-Title', 'after the race', '-NoSimilarCheck') $dirA 'a'
    Assert 'C3 a later `new` allocates past the ledger mark, not past its own files (T6)' ($r.Out -match 'created T6\b')

    Reset-Lanes
    $r = Invoke-LaneRace -Verb 'new' -Tag 'newoff' -LedgerValue 'off'
    $na = Get-Created $r.a
    $nb = Get-Created $r.b
    "    ledger off : lane a -> $na, lane b -> $nb"
    Assert 'C4 negative control: with the ledger off both lanes mint the SAME id' ($na -and $na -eq $nb)

    # --- D. resume protection ------------------------------------------------------
    ""
    'D. another live lane''s in-progress task is not stale'
    Reset-Lanes
    $r = Task-Run @('next', '-Claim') $dirA 'a'
    Assert 'D1 lane a claims T1' ($r.Out -match 'CLAIMED: T1\b' -and (Get-ClaimLane 'T1') -eq 'a')
    # Lane b's copy after a pull: T1 is in-progress there too.
    New-FixtureTask -Dir $dirB -Id 'T1' -Status 'in-progress' -WithLog

    $before = [System.IO.File]::ReadAllText($ledger)
    $r = Task-Run @('next') $dirB 'b'
    Assert 'D2 plain next names T1 as held by lane a' ($r.Out -match 'HELD BY OTHER LANE: T1 \(lane a\)')
    Assert 'D3 plain next does not call T1 in flight, and offers T2' ($r.Out -notmatch 'IN FLIGHT: .*T1' -and $r.Out -match 'NEXT: T2\b')
    Assert 'D4 plain next writes neither the ledger nor the file' (
        [System.IO.File]::ReadAllText($ledger) -eq $before -and (Get-FileStatus $dirB 'T2') -eq 'todo')

    $r = Task-Run @('next', '-Claim') $dirB 'b'
    Assert 'D5 lane b does NOT resume T1' ($r.Out -notmatch 'RESUME: T1\b')
    Assert 'D6 lane b claims T2 instead' ($r.Out -match 'CLAIMED: T2\b' -and (Get-ClaimLane 'T2') -eq 'b')
    Assert 'D7 T1 still belongs to lane a' ((Get-ClaimLane 'T1') -eq 'a')

    # Lane a dies: its heartbeat stops and the claim ages past the TTL
    # (default 60 min since T1984; well past it, so a TTL retune does not silently
    # turn this into "still live").
    $null = Set-ClaimTouchedAgo -Id 'T1' -Minutes 600
    $r = Task-Run @('ledger') $dirB 'b'
    Assert 'D8 `ledger` shows the aged claim as EXPIRED' ($r.Out -match 'T1\s+EXPIRED\s+lane=a') $r.Out
    $r = Task-Run @('next', '-Claim') $dirB 'b'
    Assert 'D9 after the TTL lane b DOES resume T1' ($r.Out -match 'RESUME: T1\b') $r.Out
    Assert 'D10 and the ledger now gives T1 to lane b' ((Get-ClaimLane 'T1') -eq 'b')

    # The TTL is a knob, not a constant: a tiny TTL expires a fresh claim too.
    Reset-Lanes
    $null = Task-Run @('next', '-Claim') $dirA 'a'
    New-FixtureTask -Dir $dirB -Id 'T1' -Status 'in-progress' -WithLog
    Start-Sleep -Milliseconds 300
    $r = Task-Run @('next', '-Claim') $dirB 'b' @{ GHOZTTY_LOOP_LEDGER_TTL_MIN = '0.001' }
    Assert 'D11 GHOZTTY_LOOP_LEDGER_TTL_MIN shortens the TTL (lane b resumes a claim older than it)' ($r.Out -match 'RESUME: T1\b') $r.Out

    # --- E. bookkeeping ------------------------------------------------------------
    ""
    'E. status, heartbeat, ledger view, recovery, lock'
    Reset-Lanes
    $null = Task-Run @('next', '-Claim') $dirA 'a'        # a: T1
    $null = Task-Run @('next', '-Claim') $dirB 'b'        # b: T2 (T1 held)
    Assert 'E1 setup: a holds T1, b holds T2' ((Get-ClaimLane 'T1') -eq 'a' -and (Get-ClaimLane 'T2') -eq 'b')

    # T2033: done is a reservation now, not a release (section F proves it).
    $r = Task-Run @('set-status', 'T1', '-Status', 'todo') $dirA 'a'
    Assert 'E2 set-status todo (an abandonment) releases the claim' ($r.Out -match "released this lane's claim on T1" -and $null -eq (Get-ClaimLane 'T1'))

    $r = Task-Run @('set-status', 'T2', '-Status', 'in-progress') $dirA 'a'
    Assert 'E3 set-status in-progress on another lane''s task warns, exits 0, and does not steal it' (
        $r.Code -eq 0 -and $r.Out -match 'WARNING: HELD BY OTHER LANE: T2 \(lane b\)' -and (Get-ClaimLane 'T2') -eq 'b')
    $r = Task-Run @('set-status', 'T2', '-Status', 'todo') $dirA 'a'
    Assert 'E4 only the holder releases: lane a setting T2 todo leaves lane b''s claim' ((Get-ClaimLane 'T2') -eq 'b')

    $old = Set-ClaimTouchedAgo -Id 'T2' -Minutes 10
    $r = Task-Run @('note', 'T2', '-Text', 'heartbeat') $dirB 'b'
    $j = Read-LedgerJson
    $touched = ConvertTo-LedgerTime $j.claims.T2.touched
    Assert 'E5 a note from the holding lane refreshes the heartbeat' (
        $null -ne $touched -and $touched -gt (ConvertTo-LedgerTime $old).AddMinutes(5))

    $r = Task-Run @('set-status', 'T3', '-Status', 'in-progress') $dirB 'b'
    Assert 'E6 set-status in-progress records a claim for this lane' ((Get-ClaimLane 'T3') -eq 'b')

    $r = Task-Run @('ledger') $dirA 'a'
    Assert 'E7 `ledger` prints the high-water mark and each live claim with its lane' (
        $r.Out -match 'maxId:\s+T\d+' -and $r.Out -match 'T2\s+live\s+lane=b' -and $r.Out -match 'this lane:\s+a')
    $r = Task-Run @('ledger') $dirA 'a' @{ GHOZTTY_LOOP_LEDGER = 'off' }
    Assert 'E8 `ledger` says LEDGER OFF under the kill switch' ($r.Out -match 'LEDGER OFF')

    # A corrupt ledger is backed up and replaced, never a wedge.
    Reset-Lanes
    [System.IO.File]::WriteAllText($ledger, '{ this is not "json', (New-Object System.Text.UTF8Encoding $false))
    $r = Task-Run @('next', '-Claim') $dirA 'a'
    Assert 'E9 a corrupt ledger is recovered with a warning and the claim still lands' (
        $r.Code -eq 0 -and $r.Out -match 'LEDGER RECOVERED' -and $r.Out -match 'CLAIMED: T1\b' -and (Get-ClaimLane 'T1') -eq 'a')
    Assert 'E10 the corrupt file was backed up beside the ledger' (
        @(Get-ChildItem -Path $work -Filter 'loop-ledger.json.corrupt-*').Count -ge 1)

    # A held lock is a bounded wait with a named reason, and claims nothing.
    $m = New-Object System.Threading.Mutex($false, (Get-LedgerMutexName -Path $ledger))
    $null = $m.WaitOne()
    try {
        $r = Task-Run @('next', '-Claim') $dirB 'b' @{ GHOZTTY_LOOP_LEDGER_WAIT_SEC = '1' }
    }
    finally { $m.ReleaseMutex(); $m.Dispose() }
    Assert 'E11 a held ledger lock fails the claim after a bounded wait, naming the mutex' (
        $r.Code -ne 0 -and $r.Out -match 'waited 1s for mutex')
    Assert 'E12 and nothing was claimed' ($r.Out -notmatch 'CLAIMED:' -and (Get-FileStatus $dirB 'T2') -eq 'todo')

    # A fixture run that names no ledger must not write the default one: point
    # LOCALAPPDATA at scratch so the assertion cannot touch the real ledger.
    $fakeLocal = Join-Path $work 'localappdata'
    New-Item -ItemType Directory -Force $fakeLocal | Out-Null
    Reset-Lanes
    $r = Task-Run @('next', '-Claim') $dirA 'a' @{ GHOZTTY_LOOP_LEDGER = $null; LOCALAPPDATA = $fakeLocal }
    Assert 'E13 a -TaskDir run with no GHOZTTY_LOOP_LEDGER claims without writing the default ledger' (
        $r.Out -match 'CLAIMED: T1\b' -and -not (Test-Path (Join-Path $fakeLocal 'ghoztty\loop-ledger.json')))

    # --- F. finished but not yet pushed (T2033) ------------------------------------
    # 2026-10-16: lane B set T2012 done at 18:59, its push landed 19:00:31, and
    # lane A's `next -Claim` at 18:59 got T2012 - the claim had been released at
    # set-status, and lane A's worktree still read the task as todo.
    ""
    'F. a task finished in one lane is not handed to the other before it arrives'
    Reset-Lanes
    $null = Task-Run @('next', '-Claim') $dirB 'b'        # b: T1
    $r = Task-Run @('set-status', 'T1', '-Status', 'done') $dirB 'b'
    $j = Read-LedgerJson
    Assert 'F1 set-status done keeps the task reserved to the finishing lane' (
        $r.Out -match 'T1 stays reserved' -and (Get-ClaimLane 'T1') -eq 'b' -and [string]$j.claims.T1.closed -eq 'done') $r.Out
    $r = Task-Run @('next', '-Claim') $dirA 'a'           # a's copy still says todo
    Assert 'F2 the other lane (its copy still todo) does NOT get it, and says why' (
        $r.Out -notmatch 'NEXT: T1\b' -and $r.Out -match 'FINISHED IN OTHER LANE: T1 \(lane b, done' -and $r.Out -match 'CLAIMED: T2\b') $r.Out
    $r = Task-Run @('ledger') $dirA 'a'
    Assert 'F3 `ledger` shows the reservation' ($r.Out -match 'T1\s+live\s+lane=b\s+reserved\(done') $r.Out
    # Caught up: lane a pulls, so its copy reads done; its next ends the
    # reservation and nothing is left behind.
    New-FixtureTask -Dir $dirA -Id 'T1' -Status 'done'
    $r = Task-Run @('next') $dirA 'a'
    Assert 'F5 once the other lane reads the close, its next clears the reservation' (
        $r.Out -match 'T1 reservation cleared: this lane already reads it done' -and $null -eq (Get-ClaimLane 'T1')) $r.Out

    # Reopen: the finishing lane taking it back drops the reservation shape.
    Reset-Lanes
    $null = Task-Run @('next', '-Claim') $dirB 'b'
    $null = Task-Run @('set-status', 'T1', '-Status', 'done') $dirB 'b'
    $null = Task-Run @('set-status', 'T1', '-Status', 'in-progress') $dirB 'b'
    $j = Read-LedgerJson
    Assert 'F6 re-opening a closed task makes it an ordinary claim again' (
        (Get-ClaimLane 'T1') -eq 'b' -and -not $j.claims.T1.closed)

    # Pushed: lane b's task dir is a git worktree with an upstream. Before the
    # push the reservation is refreshed (the work has not left the box); after
    # it, pushedAt is stamped, and a TTL later the reservation ends even though
    # lane a never pulled - nothing stays stuck.
    Reset-Lanes
    $bare = Join-Path $work 'origin.git'
    $gitOk = $true
    $eapF = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        & git init -q --bare $bare 2>&1 | Out-Null
        & git -C $dirB init -q 2>&1 | Out-Null
        & git -C $dirB -c user.name=t -c user.email=t@t add -A 2>&1 | Out-Null
        & git -C $dirB -c user.name=t -c user.email=t@t commit -q -m fixture 2>&1 | Out-Null
        & git -C $dirB remote add origin $bare 2>&1 | Out-Null
        & git -C $dirB push -q -u origin HEAD 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { $gitOk = $false }
    }
    finally { $ErrorActionPreference = $eapF }
    Assert 'F7 setup: lane b''s fixture is a git tree with an upstream' $gitOk
    $null = Task-Run @('next', '-Claim') $dirB 'b'
    $null = Task-Run @('set-status', 'T1', '-Status', 'done') $dirB 'b'
    $old = Set-ClaimTouchedAgo -Id 'T1' -Minutes 10
    $r = Task-Run @('next', '-Claim') $dirA 'a'
    $j = Read-LedgerJson
    Assert 'F8 unpushed: the other lane skips it and the reservation''s heartbeat is refreshed' (
        $r.Out -match 'FINISHED IN OTHER LANE: T1\b' -and (ConvertTo-LedgerTime $j.claims.T1.touched) -gt (ConvertTo-LedgerTime $old).AddMinutes(5) -and -not $j.claims.T1.pushedAt) $r.Out
    $eapF = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        & git -C $dirB -c user.name=t -c user.email=t@t commit -q -am 'T1 done' 2>&1 | Out-Null
        & git -C $dirB push -q 2>&1 | Out-Null
    }
    finally { $ErrorActionPreference = $eapF }
    $r = Task-Run @('next') $dirA 'a'
    $j = Read-LedgerJson
    Assert 'F9 pushed: pushedAt is stamped and the other lane (not yet pulled) still skips it' (
        $r.Out -match 'T1 reservation: the close is on the upstream' -and $j.claims.T1.pushedAt -and $r.Out -match 'FINISHED IN OTHER LANE: T1\b') $r.Out
    $j.claims.T1.pushedAt = (Get-Date).ToUniversalTime().AddMinutes(-61).ToString('o')
    [System.IO.File]::WriteAllText($ledger, ($j | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding $false))
    $r = Task-Run @('next') $dirA 'a'
    Assert 'F10 a TTL after the push the reservation ends on its own' (
        $r.Out -match 'T1 reservation cleared: pushed more than a TTL ago' -and $null -eq (Get-ClaimLane 'T1')) $r.Out

    # Negative control: the T1981 release-at-done hands the finished task to
    # the other lane, so F2 can go red.
    Reset-Lanes
    $null = Task-Run @('next', '-Claim') $dirB 'b'
    $null = Task-Run @('set-status', 'T1', '-Status', 'done') $dirB 'b' @{ GHOZTTY_LOOP_LEDGER_NO_RESERVE = '1' }
    $r = Task-Run @('next', '-Claim') $dirA 'a'
    Assert 'F11 negative control: with release-at-done the other lane IS handed the finished task' ($r.Out -match 'NEXT: T1\b') $r.Out

    "G. Lane-scoped tasks (T2175)"
    # T1 is a lane-a-only task (a delivery): lane b must never be handed it,
    # by a fresh claim or by a resume, and must say why it skipped it.
    Reset-Lanes
    foreach ($d in @($dirA, $dirB)) { New-FixtureTask -Dir $d -Id 'T1' -Lane 'a' }
    $r = Task-Run @('next', '-Claim') $dirB 'b'
    Assert 'G1 lane b skips a lane-a task, says so, and claims the next one' (
        $r.Out -match 'NEXT: T2\b' -and $r.Out -match 'Skipped 1 todo\(s\) for another lane \(this lane=b\): T1\(lane a\)' -and
        (Get-FileStatus $dirB 'T1') -eq 'todo') $r.Out
    $r = Task-Run @('next', '-Claim') $dirA 'a'
    Assert 'G2 lane a is handed its own lane-a task' ($r.Out -match 'NEXT: T1\b') $r.Out
    Reset-Lanes
    New-FixtureTask -Dir $dirB -Id 'T1' -Lane 'a' -Status 'in-progress' -WithLog
    $r = Task-Run @('next', '-Claim') $dirB 'b'
    Assert 'G3 lane b does not RESUME a stale lane-a task' ($r.Out -notmatch 'RESUME: T1\b' -and $r.Out -match 'NEXT: T2\b') $r.Out
    # Negative control: the same todo with no lane field IS handed to lane b,
    # so G1 is the field's doing and can go red.
    Reset-Lanes
    $r = Task-Run @('next', '-Claim') $dirB 'b'
    Assert 'G4 negative control: without lane: the task goes to lane b' ($r.Out -match 'NEXT: T1\b') $r.Out
    Reset-Lanes
    New-FixtureTask -Dir $dirA -Id 'T3' -Lane 'lane-a'
    $r = Task-Run @('validate') $dirA 'a'
    Assert 'G5 validate names a lane that is not one letter' ($r.Out -match "ODD LANE: T3 = 'lane-a'") $r.Out
    Complete-TestBody
}
finally {
    $env:GHOZTTY_LOOP_LEDGER = $savedLedgerEnv
    $env:GHOZTTY_LOOP_LANE = $savedLaneEnv
    $env:GHOZTTY_LOOP_LEDGER_TTL_MIN = $savedTtlEnv
    if (Test-Path $work) { Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue }
}

# --- stamp (T783) ----------------------------------------------------------------
if ($script:failures -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard parity-tasks-lanes -Repo $Repo 2>&1 | ForEach-Object { Write-Host "  $_" }
}

""
Write-TestVerdict -Pass $script:passes -Fail $script:failures
