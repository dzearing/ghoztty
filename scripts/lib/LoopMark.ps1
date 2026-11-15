# T2842: which window does go-loop-exec's claim mark when `+rename
# --target=<pane id>` cannot say?
#
# On 2026-11-08 a crash-recovery launch put the same pane id on two panes in two
# windows (fixed in the app, T2842), so the rename answered "ambiguous" - and
# the claim threw that answer away and printed "marked this window" anyway.
# Lane a then ran unmarked for 1h50m and both lanes' health read windows=0.
#
# The claim now checks the rename and, when it fails, falls back to marking the
# window BY ITS TARGET: the one window holding this pane, or - when several do -
# the one whose copy of the pane runs a shell that is an ancestor of this very
# process (the claim runs inside its own pane, so exactly one of them is).
# Anything it cannot decide is reported as MARK FAILED, never as marked.
#
#   Get-SelfAncestorPids                      the pids above $PID, CreationDate-guarded
#   Select-LoopMarkTarget -Windows -PaneId -Ancestors   pure: @{ Target; Why }
#
# Acceptance: section MK of test\win32\go-loop-guard.ps1.

function Get-SelfAncestorPids {
    # Walk ParentProcessId from this process up. Windows recycles pids and never
    # rewrites ParentProcessId, so a parent born AFTER its child is an impostor
    # holding a dead parent's pid: the walk stops there (T1867's rule).
    $rows = @{}
    try {
        foreach ($p in @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, CreationDate -ErrorAction Stop)) {
            $rows[[int]$p.ProcessId] = $p
        }
    } catch { return @() }
    $out = New-Object System.Collections.ArrayList
    $cur = $rows[[int]$PID]
    $guard = 0
    while ($null -ne $cur -and $guard -lt 64) {
        $guard++
        $parentPid = [int]$cur.ParentProcessId
        if ($parentPid -le 0) { break }
        $parent = $rows[$parentPid]
        if ($null -eq $parent) { break }
        if ($null -ne $parent.CreationDate -and $null -ne $cur.CreationDate -and
            $parent.CreationDate -gt $cur.CreationDate) { break }
        [void]$out.Add($parentPid)
        $cur = $parent
    }
    return @($out)
}

function Select-LoopMarkTarget {
    <#
        $Windows: objects with Target and Leaves (each leaf: id, pid).
        Returns @{ Target = '<window target>' or $null; Why = '<one line>' }.
    #>
    param(
        [object[]]$Windows,
        [string]$PaneId,
        [int[]]$Ancestors = @()
    )
    $holders = @()
    foreach ($w in @($Windows)) {
        if ($null -eq $w) { continue }
        $leaf = @($w.Leaves | Where-Object { $null -ne $_ -and [string]$_.id -eq $PaneId }) | Select-Object -First 1
        if ($null -ne $leaf) { $holders += [pscustomobject]@{ Window = $w; Leaf = $leaf } }
    }
    if ($holders.Count -eq 0) {
        return @{ Target = $null; Why = "no window holds pane $PaneId" }
    }
    if ($holders.Count -eq 1) {
        return @{ Target = [string]$holders[0].Window.Target; Why = 'the one window holding this pane' }
    }
    $mine = @($holders | Where-Object {
            $leafPid = 0
            [int]::TryParse([string]$_.Leaf.pid, [ref]$leafPid) | Out-Null
            $leafPid -gt 0 -and (@($Ancestors) -contains $leafPid)
        })
    if ($mine.Count -eq 1) {
        return @{
            Target = [string]$mine[0].Window.Target
            Why    = "pane id is on $($holders.Count) windows; this one runs this process's shell (pid $($mine[0].Leaf.pid))"
        }
    }
    return @{
        Target = $null
        Why    = "pane id is on $($holders.Count) windows and $($mine.Count) of them run this process's shell"
    }
}

# T2966: which window IS the loop, when the user has renamed it?
#
# On 2026-11-14 the user retitled both loop windows ('go loop: ghoztty 1/2').
# `+rename` rightly leaves a user's title alone, so the '[go-loop]' marker could
# not be put back - and every reader that asked the TITLE "are you the loop?"
# got no: go-loop-health read windows=0 / 'no [go-loop]-marked window' over a
# healthy loop, and the watchdog's re-entry would have opened a second window
# beside the renamed one. The marker is a label for people; the identity is the
# pane id the lock records, which a rename cannot touch. So a window is this
# lane's loop when its title carries the marker OR it holds the lock owner's
# pane. The user's name is never fought: nothing here renames anything.
#
#   Get-LoopWindowRole -Window -Marker -OwnerPane     pure: 'marked' | 'lock-owner' | ''
#   Test-UserRenamedRefusal -Text                     pure: did +rename refuse a user's title?
#   Get-LoopLockOwnerPane -LockPath                   the pane_id on the lock file, or ''
#
# Acceptance: section MR of test\win32\go-loop-guard.ps1.

function Get-LoopWindowRole {
    <#
        $Window: an object with Title and either Panes (pane id strings) or
        Leaves (objects with .id). Returns 'marked' when the title starts with
        $Marker, 'lock-owner' when it does not but the window holds $OwnerPane,
        and '' otherwise.
    #>
    param(
        [object]$Window,
        [string]$Marker,
        [string]$OwnerPane
    )
    if ($null -eq $Window) { return '' }
    $title = [string]$Window.Title
    if ($Marker -and $title.StartsWith($Marker, [StringComparison]::Ordinal)) { return 'marked' }
    if (-not $OwnerPane) { return '' }
    $ids = @()
    if ($Window.PSObject.Properties.Name -contains 'Panes') { $ids += @($Window.Panes | ForEach-Object { [string]$_ }) }
    if ($Window.PSObject.Properties.Name -contains 'Leaves') {
        $ids += @($Window.Leaves | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_.id })
    }
    foreach ($id in $ids) {
        if ($id -and [string]::Equals($id, $OwnerPane, [StringComparison]::OrdinalIgnoreCase)) { return 'lock-owner' }
    }
    return ''
}

function Test-UserRenamedRefusal {
    param([string]$Text)
    if (-not $Text) { return $false }
    return ($Text -match 'renamed by the user')
}

function Get-LoopLockOwnerPane {
    param([string]$LockPath)
    if (-not $LockPath -or -not (Test-Path -LiteralPath $LockPath)) { return '' }
    try {
        $j = Get-Content -LiteralPath $LockPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($j -and $j.pane_id) { return [string]$j.pane_id }
    } catch { }
    return ''
}
