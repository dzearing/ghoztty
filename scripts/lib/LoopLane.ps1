# LoopLane.ps1 - which loop LANE a worktree is, and the names that follow (T1984).
#
# Two go.md loops can run on this box at once, each in its own git worktree
# (T1937; `seat` already means win/mac in the tracker, so a parallel loop is a
# LANE). The lock, the stop flag and the watchdog's state file already live
# under each worktree's own temp\, so those were per-lane for free. What was
# not:
#
#   - the watchdog's single-instance mutex (Global\GhozttyGoLoopWatchdog): lane
#     B's watchdog found lane A's holding it and exited, so lane B had no
#     supervisor at all;
#   - its HKCU Run entry and revive task (one name, so installing lane B's
#     replaced lane A's);
#   - its log and resume shim in %TEMP%;
#   - the `+new-window --target=main` it re-enters through: named targets are
#     focused, not recreated, so lane B's recovery would have focused lane A's
#     window and reported success;
#   - the `[go-loop]` window marker: `claim` closes every OTHER marked window as
#     a duplicate, so lane B's claim would have closed lane A.
#
# Lane A keeps every historical name byte for byte (suffix ''), so a box with
# one lane behaves exactly as it did before this file existed and nothing that
# is already installed has to be re-registered. Lane <x> appends '-<x>'.
#
# And two things are single-owner by design: PUBLISHING (the daily release tag)
# and DELIVERING (the dev install, the Desktop portable, the share). Two lanes
# doing either would race each other's tags and swap each other's binaries, so
# lane A owns both and every other lane refuses - see Assert-LoopLaneOwnsDelivery.
#
# How a worktree's lane is decided, first match wins:
#   1. GHOZTTY_LOOP_LANE, when it is a single letter (a harness pins a lane this
#      way; LoopLedger.ps1 reads the same variable as a free-form lane NAME, and
#      any longer value is left to it and ignored here);
#   2. the MAIN worktree (its git dir is the common dir) is lane 'a';
#   3. a linked worktree whose directory ends in '-<letter>' (D:\git\ghoztty-b)
#      is that letter;
#   4. any other linked worktree is 'b'.
# A path that is not a git checkout at all is lane 'a', so a fixture or a
# parallel-runner mirror (a junction tree whose .git is the main one's) keeps
# the single-lane behavior.
#
# ASCII only and PS 5.1 compatible. Functions only, no side effects at load.

function Get-LoopLaneId {
    param([string]$Repo)
    $named = ([string]$env:GHOZTTY_LOOP_LANE).Trim().ToLowerInvariant()
    if ($named -match '^[a-z]$') { return $named }
    if (-not $Repo) { $Repo = (Get-Location).Path }
    $gitDir = $null; $common = $null
    $eap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # --path-format=absolute for BOTH, so git resolves them the same way.
        # --absolute-git-dir follows a junction while a relative --git-common-dir
        # does not: a parallel-runner mirror (whose .git is a junction to the
        # main one) then compared D:\git\ghoztty\.git with <mirror>\.git, read
        # as a linked worktree, and refused to deliver as lane b.
        $out = @(& git -C $Repo rev-parse --path-format=absolute --git-dir --git-common-dir 2>$null)
        if ($LASTEXITCODE -eq 0 -and $out.Count -ge 2) { $gitDir = [string]$out[0]; $common = [string]$out[1] }
    } catch { }
    finally { $ErrorActionPreference = $eap }
    if (-not $gitDir -or -not $common) { return 'a' }
    try {
        if (-not [System.IO.Path]::IsPathRooted($common)) { $common = Join-Path $Repo $common }
        $g = [System.IO.Path]::GetFullPath($gitDir.Replace('/', '\')).TrimEnd('\')
        $c = [System.IO.Path]::GetFullPath($common.Replace('/', '\')).TrimEnd('\')
    } catch { return 'a' }
    if ([string]::Equals($g, $c, [StringComparison]::OrdinalIgnoreCase)) { return 'a' }
    return (Get-LoopLaneIdFromPath -Path $Repo)
}

# Rules 3 and 4 alone, for a path already known to be a linked worktree.
function Get-LoopLaneIdFromPath {
    param([string]$Path)
    $leaf = Split-Path -Leaf ([string]$Path).TrimEnd('\', '/')
    if ($leaf -match '-([a-z])$') {
        $x = $Matches[1].ToLowerInvariant()
        if ($x -ne 'a') { return $x }
    }
    return 'b'
}

# '' for lane A (every historical name unchanged), '-<x>' otherwise.
function Get-LoopLaneSuffix {
    param([string]$Lane)
    if (-not $Lane -or $Lane -eq 'a') { return '' }
    return "-$Lane"
}

# The execution-window marker. Lane A's is the historical '[go-loop]'; lane B's
# is '[go-loop b]', which deliberately does NOT start with '[go-loop]' - the
# claim's duplicate test is a StartsWith, so a shared prefix would make each
# lane close the other.
function Get-LoopLaneMarker {
    param([string]$Lane)
    if (-not $Lane -or $Lane -eq 'a') { return '[go-loop]' }
    return "[go-loop $Lane]"
}

function Get-LoopLaneWatchdogMutex {
    param([string]$Lane)
    return ('Global\GhozttyGoLoopWatchdog' + (Get-LoopLaneSuffix $Lane))
}

# The HKCU Run value AND the revive scheduled task share this name.
function Get-LoopLaneTaskName {
    param([string]$Lane)
    return ('GhozttyGoLoopWatchdog' + (Get-LoopLaneSuffix $Lane))
}

function Get-LoopLaneWatchdogLog {
    param([string]$Lane)
    return (Join-Path $env:TEMP ('ghoztty-go-loop-watchdog' + (Get-LoopLaneSuffix $Lane) + '.log'))
}

function Get-LoopLaneResumeShim {
    param([string]$Lane)
    return (Join-Path $env:TEMP ('ghoztty-go-loop-resume' + (Get-LoopLaneSuffix $Lane) + '.cmd'))
}

# The named window a re-entry opens. Lane A keeps 'main'.
function Get-LoopLaneWindowTarget {
    param([string]$Lane)
    return ('main' + (Get-LoopLaneSuffix $Lane))
}

# Lane A alone publishes and delivers.
function Test-LoopLaneOwnsDelivery {
    param([string]$Lane)
    return (-not $Lane -or $Lane -eq 'a')
}

# The one refusal every publish/deliver entry point makes. Returns $true when
# the caller may carry on; otherwise writes ONE line that starts with
# 'LANE REFUSED' (the acceptance script greps for it), naming the lane, what was
# refused and who owns it, and returns $false. The caller picks its own exit
# code: a publish refusal is a SKIP (exit 0, so step 6.5 never stalls a lane-B
# turn), a delivery refusal is an error.
function Assert-LoopLaneOwnsDelivery {
    param([string]$Repo, [string]$What)
    $lane = Get-LoopLaneId -Repo $Repo
    if (Test-LoopLaneOwnsDelivery $lane) { return $true }
    # Write-Host, not the pipeline: the caller branches on the return value, and
    # an output line would turn it into a (truthy) array.
    Write-Host ("LANE REFUSED lane $lane does not $What - publishing and delivery belong to lane a " +
        "(the main worktree) alone, so two lanes never race a release tag or swap each other's binaries (T1984)")
    return $false
}

# Every loop lane on the box, as objects { Id, Root, LockPath, StatePath,
# StopPath, Self }. A lane is a worktree of this repository that has ever run
# the loop (its temp\ holds a lock or the lock's history), plus the asking
# worktree itself - so a ship-feature worktree that never ran go.md is not
# reported as a lane. Sorted by lane id.
function Get-LoopLanes {
    param([string]$Repo)
    if (-not $Repo) { $Repo = (Get-Location).Path }
    $self = ''
    try { $self = [System.IO.Path]::GetFullPath($Repo).TrimEnd('\') } catch { $self = $Repo }
    $roots = New-Object System.Collections.ArrayList
    $eap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        foreach ($line in @(& git -C $Repo worktree list --porcelain 2>$null)) {
            if ([string]$line -match '^worktree (.+)$') {
                $p = $Matches[1].Trim().Replace('/', '\')
                try { $p = [System.IO.Path]::GetFullPath($p).TrimEnd('\') } catch { }
                [void]$roots.Add($p)
            }
        }
    } catch { }
    finally { $ErrorActionPreference = $eap }
    if ($roots.Count -eq 0) { [void]$roots.Add($self) }
    $main = [string]$roots[0]   # porcelain lists the main worktree first
    $out = @()
    $seen = @{}
    foreach ($r in $roots) {
        $temp = Join-Path $r 'temp'
        $isSelf = [string]::Equals($r, $self, [StringComparison]::OrdinalIgnoreCase)
        $ran = (Test-Path -LiteralPath (Join-Path $temp 'go-loop.lock.json')) -or
               (Test-Path -LiteralPath (Join-Path $temp 'go-loop-history.jsonl'))
        if (-not $ran -and -not $isSelf) { continue }
        $id = if ([string]::Equals($r, $main, [StringComparison]::OrdinalIgnoreCase)) { 'a' } else { Get-LoopLaneIdFromPath -Path $r }
        if ($isSelf) { $id = Get-LoopLaneId -Repo $r }
        if ($seen.ContainsKey($id)) { continue }
        $seen[$id] = $true
        $out += [pscustomobject]@{
            Id        = $id
            Root      = $r
            LockPath  = (Join-Path $temp 'go-loop.lock.json')
            StatePath = (Join-Path $temp 'go-loop.watchdog.json')
            StopPath  = (Join-Path $temp 'go-loop.stop.json')
            Self      = $isSelf
        }
    }
    return @($out | Sort-Object Id)
}

# Is lane $Lane's watchdog alive? Asked of its single-instance mutex, the same
# question go-loop-watchdog.ps1 -Status asks of its own.
function Test-LoopLaneWatchdogRunning {
    param([string]$Lane)
    $m = $null
    try {
        $m = New-Object System.Threading.Mutex($false, (Get-LoopLaneWatchdogMutex $Lane))
        if ($m.WaitOne(0)) { $m.ReleaseMutex(); return $false }
        return $true
    } catch [System.Threading.AbandonedMutexException] {
        try { $m.ReleaseMutex() } catch { }
        return $false
    } catch { return $false }
    finally { if ($m) { $m.Dispose() } }
}
