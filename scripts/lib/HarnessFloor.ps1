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
$script:HARNESS_FLOOR_AUDITS = @(
    [pscustomobject]@{ Name = 'harness-exitcode-audit.ps1'; Why = 'a script exits the code its verdict implies (T197)' }
    [pscustomobject]@{ Name = 'verdict-exit-audit.ps1'; Why = 'a scorer cannot fall through without printing a verdict' }
    [pscustomobject]@{ Name = 'asserted-nothing.ps1'; Why = 'a run that proved nothing is not a pass (T271)' }
    [pscustomobject]@{ Name = 'body-complete-audit.ps1'; Why = 'a body that unwound early is not a pass' }
    [pscustomobject]@{ Name = 'skip-visibility.ps1'; Why = 'a skipped section is named in the verdict, never hidden by ALL PASS' }
    [pscustomobject]@{ Name = 'count-or-zero.ps1'; Why = 'an assertion count is a real count, not a zero dressed as one (T617)' }
    [pscustomobject]@{ Name = 'isolation-meta.ps1'; Why = 'a script drives its own endpoints, never the user terminal''s' }
    [pscustomobject]@{ Name = 'build-mode-guard.ps1'; Why = 'a run refuses a release-lineage build before it launches anything (T350)' }
    [pscustomobject]@{ Name = 'launch-preflight-audit.ps1'; Why = 'no script launches the app without asking what build it is (T1033)' }
    [pscustomobject]@{ Name = 'cleanslate-audit.ps1'; Why = 'shared state is cleared per script, so order cannot decide a verdict' }
    [pscustomobject]@{ Name = 'persistence-flag.ps1'; Why = 'a script states its persistence intent rather than inheriting one (T158)' }
    [pscustomobject]@{ Name = 'stderr-capture-audit.ps1'; Why = 'stderr is captured rather than thrown away (T883)' }
    [pscustomobject]@{ Name = 'stderr-launch-capture.ps1'; Why = 'every launch keeps what the app said on its way out (T689)' }
    [pscustomobject]@{ Name = 'command-resolve-audit.ps1'; Why = 'a command a script depends on resolves, or the run says so' }
    [pscustomobject]@{ Name = 'argv-hazard-audit.ps1'; Why = 'free text reaches the CLI intact rather than shredded by PS 5.1 argv (T782)' }
    [pscustomobject]@{ Name = 'test-reach-audit.ps1'; Why = 'an assertion reaches the code it claims to measure' }
    [pscustomobject]@{ Name = 'desktop-launch-audit.ps1'; Why = 'a GUI script launches on the test desktop, not the user''s' }
    [pscustomobject]@{ Name = 'printclient-audit.ps1'; Why = 'every painting window answers the screenshot path the tests read' }
    [pscustomobject]@{ Name = 'thread-join-audit.ps1'; Why = 'a thread a test starts is joined, so a leak is not scored green' }
    [pscustomobject]@{ Name = 'foreground-audit.ps1'; Why = 'a script states what it does to the foreground window (T272/T276)' }
    [pscustomobject]@{ Name = 'caller-anchor.ps1'; Why = 'a shared helper is anchored to the caller that is actually under test' }
    [pscustomobject]@{ Name = 'control-char-scan.ps1'; Why = 'no script carries a control character that breaks it on another box' }
    [pscustomobject]@{ Name = 'build-fresh-guard.ps1'; Why = 'a run measures the build it thinks it measures, not a stale one' }
    [pscustomobject]@{ Name = 'job-teardown.ps1'; Why = 'a job object a test creates is torn down with its processes (T1517)' }
    [pscustomobject]@{ Name = 'vt-escape-scan.ps1'; Why = 'no script writes ``e for ESC, which under 5.1 is the letter e (T740)' }
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
        [hashtable]$Pending
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
        if ($isPending) {
            [void]$excused.Add([pscustomobject]@{ Name = $name; Verdict = $v; Task = $Pending[$name] })
        }
        else {
            [void]$red.Add([pscustomobject]@{ Name = $name; Verdict = $v })
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
The lines a harness-floor verdict prints, verdict line last.
#>
function Format-HarnessFloorVerdict {
    param([Parameter(Mandatory)]$Verdict)

    $out = New-Object System.Collections.ArrayList
    foreach ($r in @($Verdict.Red)) {
        [void]$out.Add("  RED       $($r.Name) ($($r.Verdict))")
    }
    foreach ($e in @($Verdict.Excused)) {
        [void]$out.Add("  PENDING   $($e.Name) ($($e.Verdict)) - tracked by $($e.Task)")
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
