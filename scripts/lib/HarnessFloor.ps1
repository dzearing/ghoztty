# HarnessFloor (T725) - the standing set of harness audits, in one place.
#
# THE GAP THIS CLOSES. `test\win32\` holds a family of scripts whose subject is
# not the product but the HARNESS: does every acceptance script score itself,
# exit the code its verdict implies, say out loud when it skipped something,
# isolate its endpoints, capture what the app said on the way out. Each one was
# written by the turn that had just been burned by the trap it checks, and each
# one then ran only when somebody remembered it. The P1-P3 floor is the
# PRODUCT's floor; there was no harness floor, so a new acceptance script met
# these rules one red run at a time - and an audit could go red and stay red
# with nobody the wiser. It had: `skip-visibility.ps1` was red on 2026-09-14
# with 13 unlisted violators, against a pending list naming 2 (T1123).
#
# WHAT IS IN THE SET, AND WHAT IS NOT. Every member is a STATIC SWEEP over the
# suite's own source or a pure-logic check of a shared gate: no GUI, no app
# launch, no `zig build`. That is what makes the set runnable as one lane in
# minutes rather than an afternoon, and it is the line to hold when adding a
# row. `test-filter-guard.ps1` is the deliberate exclusion - it drives real
# `zig build` runs, which is the zig lanes' job and is a cold-cache wait the
# other 20-odd members do not have.
#
# THE PENDING RATCHET. An audit that is red TODAY for a reason somebody has
# already filed is listed in $HARNESS_FLOOR_PENDING against the task that
# converts it. A pending audit is run, reported and does NOT fail the floor; an
# audit that is NOT listed and goes red DOES. The list may only shrink: an entry
# whose audit has gone green is a STALE exception and fails the floor, which is
# what stops a baseline from outliving the work it was a baseline for. Same
# shape as `$SkipAuditPending` in test\win32\lib\SkipAudit.ps1, for the same
# reason.
#
# Consumers: scripts\harness-floor.ps1 (the runner), scripts\floor-lane.ps1
# (`-Lane harness`), test\win32\harness-floor.ps1 (the acceptance harness).

Set-StrictMode -Off

# Each row: the script under test\win32\, and one line saying what property of
# the harness it holds. The Why is not decoration - it is what a turn reads when
# the row goes red and it has to decide whether the audit or the code is wrong.
#
# Tier (T1958): a row with no Tier runs in every sweep, the per-turn scoped one
# included. `daily` rows run only in a FULL sweep - the daily one from the
# digest step, or any sweep a shared-file edit forces - plus any scoped sweep
# in which their own script changed. The two daily rows are the cross-suite
# audits that cost ~11 minutes between them and had 0 reds in 41 runs
# (T1955's measurement); the accepted risk is that a script edit waits up to a
# day for them, never longer, because a scoped sweep refuses to stand in for a
# full one older than a day.
#
# Owns (T1958): files outside test\win32\ that only this member reads, so an
# edit there selects this member instead of forcing a full sweep.
$script:HARNESS_FLOOR_AUDITS = @(
    [pscustomobject]@{ Name = 'harness-exitcode-audit.ps1'; Why = 'a script exits the code its verdict implies (T197)' }
    [pscustomobject]@{ Name = 'verdict-exit-audit.ps1'; Why = 'a scorer cannot fall through without printing a verdict' }
    [pscustomobject]@{ Name = 'asserted-nothing.ps1'; Why = 'a run that proved nothing is not a pass (T271)' }
    [pscustomobject]@{ Name = 'body-complete-audit.ps1'; Why = 'a body that unwound early is not a pass' }
    [pscustomobject]@{ Name = 'skip-visibility.ps1'; Why = 'a skipped section is named in the verdict, never hidden by ALL PASS' }
    [pscustomobject]@{ Name = 'count-or-zero.ps1'; Why = 'an assertion count is a real count, not a zero dressed as one (T617)' }
    [pscustomobject]@{ Name = 'unroll-count-audit.ps1'; Why = 'a count is wrapped at the point of use, so a one-element return cannot make it vacuous (T794)' }
    [pscustomobject]@{ Name = 'dip-rounding-audit.ps1'; Why = 'a DIP length is converted the way the app rounds it, so a 112.5% screen measures the pixel the app drew (T1020)' }
    [pscustomobject]@{ Name = 'seam-audit.ps1'; Why = 'an env seam a script sets is classified, so the state it hides is armed, a named gap, or knowingly out of reach (T796)' }
    [pscustomobject]@{ Name = 'isolation-meta.ps1'; Why = 'a script drives its own endpoints, never the user terminal''s' }
    [pscustomobject]@{ Name = 'build-mode-guard.ps1'; Why = 'a run refuses a release-lineage build before it launches anything (T350)' }
    [pscustomobject]@{ Name = 'launch-preflight-audit.ps1'; Why = 'no script launches the app without asking what build it is (T1033)' }
    [pscustomobject]@{ Name = 'cleanslate-audit.ps1'; Why = 'shared state is cleared per script, so order cannot decide a verdict' }
    [pscustomobject]@{ Name = 'persistence-flag.ps1'; Why = 'a script states its persistence intent rather than inheriting one (T158)' }
    [pscustomobject]@{ Name = 'stderr-capture-audit.ps1'; Why = 'stderr is captured rather than thrown away (T883)' }
    [pscustomobject]@{ Name = 'stderr-launch-capture.ps1'; Why = 'every launch keeps what the app said on its way out (T689)' }
    [pscustomobject]@{ Name = 'command-resolve-audit.ps1'; Why = 'a command a script depends on resolves, or the run says so'; Tier = 'daily' }
    [pscustomobject]@{ Name = 'argv-hazard-audit.ps1'; Why = 'free text reaches the CLI intact rather than shredded by PS 5.1 argv (T782)' }
    [pscustomobject]@{ Name = 'test-reach-audit.ps1'; Why = 'an assertion reaches the code it claims to measure'; Tier = 'daily' }
    [pscustomobject]@{ Name = 'neuter-audit.ps1'; Why = 'a negative control has a live consumer, a shipped-value pin and a claim (T788)' }
    [pscustomobject]@{ Name = 'desktop-launch-audit.ps1'; Why = 'a GUI script launches on the test desktop, not the user''s' }
    [pscustomobject]@{ Name = 'printclient-audit.ps1'; Why = 'every painting window answers the screenshot path the tests read' }
    [pscustomobject]@{ Name = 'thread-join-audit.ps1'; Why = 'a thread a test starts is joined, so a leak is not scored green' }
    [pscustomobject]@{ Name = 'test-wait-oracle.ps1'; Why = 'a wait is bounded by the wall clock, never by a count of spins (T831)' }
    [pscustomobject]@{ Name = 'foreground-audit.ps1'; Why = 'a script states what it does to the foreground window (T272/T276)' }
    [pscustomobject]@{ Name = 'caller-anchor.ps1'; Why = 'a shared helper is anchored to the caller that is actually under test' }
    [pscustomobject]@{ Name = 'control-char-scan.ps1'; Why = 'no script carries a control character that breaks it on another box' }
    [pscustomobject]@{ Name = 'build-fresh-guard.ps1'; Why = 'a run measures the build it thinks it measures, not a stale one' }
    [pscustomobject]@{ Name = 'job-teardown.ps1'; Why = 'a job object a test creates is torn down with its processes (T1517)' }
    [pscustomobject]@{ Name = 'vt-escape-scan.ps1'; Why = 'no script writes ``e for ESC, which under 5.1 is the letter e (T740)'; Owns = @('scripts\vt-escape-scan.ps1') }
)

# name -> the task id that converts it. RED TODAY AND TRACKED, never a permanent
# allowlist: see the ratchet note at the top.
$script:HARNESS_FLOOR_PENDING = @{
    # 13 scripts skip a section without the verdict line naming a skip count.
    'skip-visibility.ps1' = 'T1123'
    # C5: eight scripts stamp a guard from a body that may have unwound, against
    # a ratchet ceiling of six.
    'asserted-nothing.ps1' = 'T1568'
}

function Get-HarnessFloorAudits { return @($script:HARNESS_FLOOR_AUDITS) }

# 'daily' or 'turn' (the default for a row that names none).
function Get-HarnessFloorTier($Audit) {
    if ($Audit -and $Audit.Tier) { return [string]$Audit.Tier }
    return 'turn'
}

function Get-HarnessFloorPending { return $script:HARNESS_FLOOR_PENDING }

<#
.SYNOPSIS
Score a harness-floor run: which rows are red, which are excused, which
exceptions have gone stale.

.DESCRIPTION
Kept apart from the runner so the scoring can be tested against synthetic rows
without running 20 audits - a gate whose teeth have never been observed is
indistinguishable from a gate that has none (T1133).

-Rows are the suite-run summary rows: an object per audit carrying `Name` and
`Verdict` (`pass` / `skip` / `fail` / `stall` / `nothing` / `error`).

A `skip` is NOT red: the box could not answer that audit's question, and
scoring it red would make the floor's colour a property of the desktop rather
than of the suite (the T1100 rule, same as suite-run's).
#>
function Get-HarnessFloorVerdict {
    param(
        [object[]]$Rows,
        [object[]]$Audits,
        [hashtable]$Pending,
        # The suite-run output dir the rows' `Log` names are relative to. When
        # given, a red row carries its own FAIL lines and log path (T1734).
        [string]$LogDir
    )

    if (-not $Audits) { $Audits = Get-HarnessFloorAudits }
    if ($null -eq $Pending) { $Pending = Get-HarnessFloorPending }

    $byName = @{}
    foreach ($r in @($Rows)) { if ($r -and $r.Name) { $byName[[string]$r.Name] = $r } }

    $red = New-Object System.Collections.ArrayList
    $excused = New-Object System.Collections.ArrayList
    $stale = New-Object System.Collections.ArrayList
    $missing = New-Object System.Collections.ArrayList
    $skipped = New-Object System.Collections.ArrayList
    $passed = New-Object System.Collections.ArrayList

    foreach ($a in @($Audits)) {
        $name = [string]$a.Name
        if (-not $byName.ContainsKey($name)) { [void]$missing.Add($name); continue }
        $v = [string]$byName[$name].Verdict
        $isPending = $Pending.ContainsKey($name)
        if ($v -eq 'pass') {
            [void]$passed.Add($name)
            # An exception that no longer violates must LEAVE the list, or the
            # list is an allowlist rather than a ratchet.
            if ($isPending) { [void]$stale.Add($name) }
            continue
        }
        if ($v -eq 'skip') { [void]$skipped.Add($name); continue }
        $why = Get-HarnessFloorRowDetail -Row $byName[$name] -LogDir $LogDir
        if ($isPending) {
            [void]$excused.Add([pscustomobject]@{
                    Name = $name; Verdict = $v; Task = $Pending[$name]
                    Fails = $why.Fails; LogPath = $why.LogPath; Alone = $why.Alone
                })
        }
        else {
            [void]$red.Add([pscustomobject]@{
                    Name = $name; Verdict = $v
                    Fails = $why.Fails; LogPath = $why.LogPath; Alone = $why.Alone
                })
        }
    }

    # A pending entry naming an audit that is not in the set at all is a dead
    # exception: it excuses nothing and hides that nobody is running the audit.
    $auditNames = @(@($Audits) | ForEach-Object { [string]$_.Name })
    $orphan = @(@($Pending.Keys) | Where-Object { $auditNames -notcontains $_ })

    $ok = ($red.Count -eq 0 -and $stale.Count -eq 0 -and $missing.Count -eq 0 -and $orphan.Count -eq 0)
    return [pscustomobject]@{
        Ok       = $ok
        Red      = @($red)
        Excused  = @($excused)
        Stale    = @($stale)
        Missing  = @($missing)
        Orphan   = @($orphan)
        Skipped  = @($skipped)
        Passed   = @($passed)
        Total    = @($Audits).Count
    }
}

<#
.SYNOPSIS
Why one red row is red: its FAIL lines, its log's full path, and how it did alone.

.DESCRIPTION
T1734. suite-run keeps every audit's transcript, but the floor's verdict named
only the audit - so a member red in the sweep and green alone was reported as
"1 FAILURE(S)" twice running with the failing assertion unread in a log the
summary never pointed at. `Fails` is the first few `FAIL` lines of that
transcript (the assertion and its message), `LogPath` is where the rest is, and
`Alone` is suite-run's re-run-red-alone answer, which is what tells a
load-dependent red from a real one. Every field degrades to empty rather than
throwing: a missing log is itself visible as a red row with no detail.
#>
function Get-HarnessFloorRowDetail {
    param(
        $Row,
        [string]$LogDir,
        [int]$MaxFails = 3
    )
    $fails = @()
    $logPath = $null
    if ($Row -and $Row.Log -and $LogDir) {
        $candidate = Join-Path $LogDir ([string]$Row.Log)
        if (Test-Path -LiteralPath $candidate) {
            $logPath = $candidate
            $fails = @(Get-Content -LiteralPath $candidate -ErrorAction SilentlyContinue |
                    Where-Object { $_ -match '^\s*FAIL\s' } |
                    Select-Object -First $MaxFails |
                    ForEach-Object { $_.Trim() })
        }
    }
    # A script that refused before asserting anything (a stale build, a missing
    # prerequisite) has no FAIL line; its last line is then the only reason.
    if ($fails.Count -eq 0 -and $Row -and $Row.Line) { $fails = @(([string]$Row.Line).Trim()) }
    $alone = $null
    if ($Row -and $Row.Alone) { $alone = [string]$Row.Alone }
    return [pscustomobject]@{ Fails = @($fails); LogPath = $logPath; Alone = $alone }
}

<#
.SYNOPSIS
The lines a harness-floor verdict prints, verdict line last.
#>
function Format-HarnessFloorVerdict {
    param([Parameter(Mandatory)]$Verdict)

    $out = New-Object System.Collections.ArrayList
    # The why under each red row (T1734): its FAIL lines, whether it passed
    # alone, and where the full transcript is.
    $detail = {
        param($r)
        foreach ($f in @($r.Fails)) { if ($f) { [void]$out.Add("            $f") } }
        if ($r.Alone) { [void]$out.Add("            alone: $($r.Alone)") }
        if ($r.LogPath) { [void]$out.Add("            log: $($r.LogPath)") }
    }
    foreach ($r in @($Verdict.Red)) {
        [void]$out.Add("  RED       $($r.Name) ($($r.Verdict))")
        & $detail $r
    }
    foreach ($e in @($Verdict.Excused)) {
        [void]$out.Add("  PENDING   $($e.Name) ($($e.Verdict)) - tracked by $($e.Task)")
        & $detail $e
    }
    foreach ($s in @($Verdict.Stale)) {
        [void]$out.Add("  STALE     $s is green now - drop it from `$HARNESS_FLOOR_PENDING")
    }
    foreach ($m in @($Verdict.Missing)) {
        [void]$out.Add("  NOT RUN   $m is in the floor set but the run produced no row for it")
    }
    foreach ($o in @($Verdict.Orphan)) {
        [void]$out.Add("  ORPHAN    $o is excused but is not in the floor set - it excuses nothing")
    }
    foreach ($s in @($Verdict.Skipped)) {
        [void]$out.Add("  SKIPPED   $s - this box could not answer it")
    }

    $pendNote = if (@($Verdict.Excused).Count -gt 0) { ", $(@($Verdict.Excused).Count) PENDING" } else { '' }
    $skipNote = if (@($Verdict.Skipped).Count -gt 0) { ", $(@($Verdict.Skipped).Count) SKIPPED" } else { '' }
    if ($Verdict.Ok) {
        [void]$out.Add("HARNESS FLOOR: ALL PASS ($($Verdict.Total) audits$pendNote$skipNote)")
    }
    else {
        $n = @($Verdict.Red).Count + @($Verdict.Stale).Count + @($Verdict.Missing).Count + @($Verdict.Orphan).Count
        [void]$out.Add("HARNESS FLOOR: $n FAILURE(S) of $($Verdict.Total) audits$pendNote$skipNote")
    }
    return @($out)
}

# ---------------------------------------------------------------- completion
#
# T1955. A full sweep is 16-25 minutes, and until this a one-line fix to ONE red
# member forced a whole new sweep before the floor would stamp - on 2026-10-14
# that was 23 floor runs for about 15 closes, ~20 minutes on half the turns. The
# rule now: a full run that was red ONLY because of named member rows, followed
# by a green narrowed re-run that covers every one of those rows, COMPLETES the
# full run and stamps the floor. Nothing gets weaker in the part that matters -
# every member still had to go green, and the red ones went green AFTER the fix.
#
# What it refuses, and why each is a refusal rather than a judgement call:
#   * no full-run record, or the last full run was green  - nothing to complete;
#   * the full run was red for a STRUCTURAL reason (stale exception, a member
#     with no row, an orphan) - those are fixed in the floor set itself, and a
#     narrowed run cannot see them;
#   * the record is already consumed - one full run completes once, or a stream
#     of single-audit re-runs could keep a floor current for a day of edits no
#     full sweep has read;
#   * the record is older than -MaxAgeHours - it describes a different turn;
#   * a SHARED file changed since (test\win32\lib\, the floor runner and set,
#     suite-run) - every member loads or obeys those, so a change there can turn
#     any member red and only a full sweep can say it did not;
#   * the re-run does not cover every red row, or is not itself green.
#
# Edits to top-level test scripts between the two runs are ALLOWED and listed:
# that is the fix itself. A fix that breaks a different member is caught by the
# next full sweep, which the next test-script edit makes due.

function Get-HarnessFloorRecordPath([string]$Repo) {
    return (Join-Path $Repo 'temp\harness-floor\last-full.json')
}

# Repo-relative path -> SHA256 for every file the floor's guard row watches,
# plus suite-run (which every member runs under). Cheap: a few hundred small
# files.
function Get-HarnessFloorFingerprint([string]$Repo) {
    $globs = @(
        'test\win32\*.ps1',
        'test\win32\lib\*.ps1',
        'scripts\harness-floor.ps1',
        'scripts\lib\HarnessFloor.ps1',
        'scripts\vt-escape-scan.ps1',
        'scripts\suite-run.ps1'
    )
    $map = @{}
    foreach ($g in $globs) {
        foreach ($f in @(Get-ChildItem -Path (Join-Path $Repo $g) -File -ErrorAction SilentlyContinue)) {
            $rel = $f.FullName.Substring($Repo.TrimEnd('\').Length + 1)
            $map[$rel] = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
        }
    }
    return $map
}

# A shared file is anything in the fingerprint that is not a top-level
# test\win32\<name>.ps1: libraries, the runner, the set, suite-run.
function Test-HarnessFloorSharedPath([string]$Rel) {
    return -not ($Rel -match '^test\\win32\\[^\\]+\.ps1$')
}

function New-HarnessFloorRecord {
    param(
        [Parameter(Mandatory)]$Verdict,
        [hashtable]$Fingerprint,
        [string]$Head,
        [datetime]$FinishedAt = (Get-Date),
        # T1958: 'full' or 'scoped'. Completing a scoped sweep advances the
        # verified fingerprint but is never a full sweep, so the daily clock
        # does not move.
        [ValidateSet('full', 'scoped')][string]$Kind = 'full'
    )
    $structural = (@($Verdict.Stale).Count + @($Verdict.Missing).Count + @($Verdict.Orphan).Count) -gt 0
    return [pscustomobject]@{
        schema      = 'ghoztty-harness-floor-record/1'
        kind        = $Kind
        finishedAt  = $FinishedAt.ToString('o')
        head        = $Head
        ok          = [bool]$Verdict.Ok
        red         = @(@($Verdict.Red) | ForEach-Object { [string]$_.Name })
        structural  = $structural
        consumed    = $false
        fingerprint = $Fingerprint
    }
}

function Read-HarnessFloorRecord([string]$Path) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json) } catch { return $null }
}

function Write-HarnessFloorRecord([string]$Path, $Record) {
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    ($Record | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $Path -Encoding UTF8
}

# Fingerprint as stored (a PSCustomObject after a JSON round trip) or live (a
# hashtable) -> hashtable.
function ConvertTo-HarnessFloorMap($fp) {
    if ($null -eq $fp) { return @{} }
    if ($fp -is [hashtable]) { return $fp }
    $m = @{}
    foreach ($p in $fp.PSObject.Properties) { $m[$p.Name] = [string]$p.Value }
    return $m
}

<#
.SYNOPSIS
May this green narrowed re-run complete the last red full run? Pure: no I/O.

.OUTPUTS
{ Ok; Reason; Red (the rows it completes); Changed (top-level scripts edited
in between - the fix) }
#>
function Test-HarnessFloorCompletion {
    param(
        $Record,
        [string[]]$Selected,
        [Parameter(Mandatory)]$Verdict,
        [hashtable]$Fingerprint,
        [datetime]$Now = (Get-Date),
        [double]$MaxAgeHours = 4
    )
    $no = { param($why) [pscustomobject]@{ Ok = $false; Reason = $why; Red = @(); Changed = @() } }

    if (-not $Verdict.Ok) { return (& $no 'this re-run is not green') }
    if ($null -eq $Record) { return (& $no 'no full run is recorded on this box') }
    if ($Record.ok) { return (& $no 'the last full run was already green') }
    if ($Record.structural) {
        return (& $no 'the last full run was red for a structural reason (stale, missing or orphan) - only a full run can clear that')
    }
    if ($Record.consumed) { return (& $no 'the last full run has already been completed once') }
    $red = @(@($Record.red) | Where-Object { $_ })
    if ($red.Count -eq 0) { return (& $no 'the last full run recorded no red row to complete') }

    $finished = [datetime]::MinValue
    if (-not [datetime]::TryParse([string]$Record.finishedAt, [ref]$finished)) {
        return (& $no 'the full-run record has no readable finish time')
    }
    $age = ($Now - $finished).TotalHours
    if ($age -gt $MaxAgeHours) {
        return (& $no ('the last full run is {0:N1}h old (limit {1}h)' -f $age, $MaxAgeHours))
    }

    $uncovered = @($red | Where-Object { @($Selected) -notcontains $_ })
    if ($uncovered.Count -gt 0) {
        return (& $no ('this re-run does not cover every red row: missing ' + ($uncovered -join ', ')))
    }

    $thenMap = ConvertTo-HarnessFloorMap $Record.fingerprint
    $liveMap = ConvertTo-HarnessFloorMap $Fingerprint
    $changed = New-Object System.Collections.ArrayList
    foreach ($k in @(@($thenMap.Keys) + @($liveMap.Keys) | Sort-Object -Unique)) {
        if ($thenMap[$k] -ne $liveMap[$k]) { [void]$changed.Add($k) }
    }
    $shared = @($changed | Where-Object { Test-HarnessFloorSharedPath $_ })
    if ($shared.Count -gt 0) {
        return (& $no ('a shared file changed since the full run, so every member must re-run: ' + ($shared -join ', ')))
    }
    return [pscustomobject]@{ Ok = $true; Reason = 'completes the last full run'; Red = $red; Changed = @($changed) }
}

# ---------------------------------------------------------------- scope
#
# T1958. A full sweep is ~24 minutes, and until this any edit under test\win32\
# paid all of it on the turn that made the edit. The per-turn sweep is now
# SCOPED against the last state the floor verified green:
#
#   * VERIFIED is temp\harness-floor\verified.json: when the last green FULL
#     sweep finished (`fullAt`), and the fingerprint of every file the floor
#     reads as the last green sweep - full or scoped - saw it. A green full
#     sweep (or a completed one) resets both; a green scoped sweep advances the
#     fingerprint only.
#   * A scoped sweep runs every turn-tier member plus any member whose own
#     script (or Owns file) changed since the verified fingerprint. Every turn
#     member sweeps every script, so that is exactly the set that covers a
#     script edit; the daily members wait for the daily sweep.
#   * It is a FULL sweep instead whenever skipping the daily members could hide
#     a red that no later run would catch: nothing verified on this box, the
#     last green full sweep older than -MaxFullAgeHours (the daily sweep did not
#     happen), or a shared file changed (test\win32\lib\, the runner, the set,
#     suite-run) - every member loads or obeys those.
#   * Nothing changed since the verified fingerprint is CURRENT: no run at all.

function Get-HarnessFloorVerifiedPath([string]$Repo) {
    return (Join-Path $Repo 'temp\harness-floor\verified.json')
}

function New-HarnessFloorVerified {
    param(
        [Parameter(Mandatory)][datetime]$FullAt,
        [hashtable]$Fingerprint,
        [string]$Head
    )
    return [pscustomobject]@{
        schema      = 'ghoztty-harness-floor-verified/1'
        fullAt      = $FullAt.ToString('o')
        verifiedAt  = (Get-Date).ToString('o')
        head        = $Head
        fingerprint = $Fingerprint
    }
}

# Which member a changed path belongs to, or $null: test\win32\<Name> for every
# member, plus each member's Owns list.
function Get-HarnessFloorOwner([string]$Rel, [object[]]$Audits) {
    foreach ($a in @($Audits)) {
        if ($Rel -ieq ('test\win32\' + [string]$a.Name)) { return [string]$a.Name }
        foreach ($o in @($a.Owns)) { if ($o -and $Rel -ieq [string]$o) { return [string]$a.Name } }
    }
    return $null
}

<#
.SYNOPSIS
What the per-turn sweep must run, against what the floor last verified. Pure.

.OUTPUTS
{ Mode = 'full' | 'scoped' | 'current'; Reason; Selected (member names, in set
order); Changed (paths that differ from the verified fingerprint) }
#>
function Get-HarnessFloorScope {
    param(
        $Verified,
        [hashtable]$Fingerprint,
        [object[]]$Audits,
        [datetime]$Now = (Get-Date),
        [double]$MaxFullAgeHours = 26
    )
    if (-not $Audits) { $Audits = Get-HarnessFloorAudits }
    $all = @(@($Audits) | ForEach-Object { [string]$_.Name })
    $full = { param($why, $changed) [pscustomobject]@{ Mode = 'full'; Reason = $why; Selected = $all; Changed = @($changed) } }

    if ($null -eq $Verified) { return (& $full 'no green full sweep is recorded on this box' @()) }
    $fullAt = [datetime]::MinValue
    if (-not [datetime]::TryParse([string]$Verified.fullAt, [ref]$fullAt)) {
        return (& $full 'the verified record has no readable full-sweep time' @())
    }
    $age = ($Now - $fullAt).TotalHours
    if ($age -gt $MaxFullAgeHours) {
        return (& $full ('the last green full sweep is {0:N1}h old (limit {1}h) - the daily sweep is due' -f $age, $MaxFullAgeHours) @())
    }

    $thenMap = ConvertTo-HarnessFloorMap $Verified.fingerprint
    $liveMap = ConvertTo-HarnessFloorMap $Fingerprint
    $changed = New-Object System.Collections.ArrayList
    foreach ($k in @(@($thenMap.Keys) + @($liveMap.Keys) | Sort-Object -Unique)) {
        if ($thenMap[$k] -ne $liveMap[$k]) { [void]$changed.Add($k) }
    }
    if ($changed.Count -eq 0) {
        return [pscustomobject]@{ Mode = 'current'; Reason = 'nothing the floor reads changed since it was last verified green'; Selected = @(); Changed = @() }
    }

    $owners = @{}
    $shared = New-Object System.Collections.ArrayList
    foreach ($c in $changed) {
        $o = Get-HarnessFloorOwner $c $Audits
        if ($o) { $owners[$o] = $true; continue }
        if (Test-HarnessFloorSharedPath $c) { [void]$shared.Add($c) }
    }
    if ($shared.Count -gt 0) {
        return (& $full ('a shared file changed, so every member must run: ' + ($shared -join ', ')) $changed)
    }
    $selected = @(@($Audits) | Where-Object {
            (Get-HarnessFloorTier $_) -ne 'daily' -or $owners.ContainsKey([string]$_.Name)
        } | ForEach-Object { [string]$_.Name })
    $skipped = @($all | Where-Object { $selected -notcontains $_ })
    $why = if ($skipped.Count -gt 0) { 'daily members wait for the daily sweep: ' + ($skipped -join ', ') } else { 'every member is selected' }
    return [pscustomobject]@{ Mode = 'scoped'; Reason = $why; Selected = $selected; Changed = @($changed) }
}

# T1969: the changed top-level scripts a SCOPED sweep hands its members
# (through test\win32\lib\HarnessScope.ps1's environment variable), so the
# heavy ones read only those. Empty for any other mode - a full sweep reads
# everything. An Owns file (scripts\vt-escape-scan.ps1) is not a test script
# and only its own member reads it, so it is not on the list.
function Get-HarnessFloorOnlyList($Scope) {
    if ($null -eq $Scope -or [string]$Scope.Mode -ne 'scoped') { return @() }
    return @(@($Scope.Changed) | Where-Object { [string]$_ -match '^test\\win32\\[^\\]+\.ps1$' })
}
