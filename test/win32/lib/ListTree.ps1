# ListTree.ps1 - read pane ids out of `ghoztty +list --json` (T1561).
#
# A tab in +list --json has NO `panes` array. Its layout is a binary TREE under
# `splits`:
#
#   {"type":"leaf","terminal":{"id":"B74C8F26-...", ...}}
#   {"type":"split","left":<node>,"right":<node>, ...}
#
# float-on-top.ps1 read `.tabs[0].panes[0].id`, got $null on every run, and
# quietly fell back to a window name for months. Walk the tree here instead of
# writing another private copy of the walk; a copy is how the wrong shape
# spread in the first place.
#
# Pure functions over the parsed JSON - no process, no pipe. Exercised by
# test\win32\list-tree.ps1.

# Every leaf's `terminal` object under a splits node, left before right (the
# on-screen reading order). A null node, or a node of no known type, yields
# nothing rather than throwing.
function Get-GhozttyListLeaves {
    param($Node)
    $acc = New-Object System.Collections.ArrayList
    $stack = New-Object System.Collections.Stack
    if ($null -ne $Node) { $stack.Push($Node) }
    while ($stack.Count -gt 0) {
        $n = $stack.Pop()
        if ($null -eq $n) { continue }
        if ([string]$n.type -eq 'leaf') {
            if ($null -ne $n.terminal) { [void]$acc.Add($n.terminal) }
        } elseif ([string]$n.type -eq 'split') {
            # Push right first so left pops first.
            if ($null -ne $n.right) { $stack.Push($n.right) }
            if ($null -ne $n.left) { $stack.Push($n.left) }
        }
    }
    return , $acc.ToArray()
}

# The first pane id of a parsed +list --json answer, with the reason when there
# is none. Returns @{ Id = '<id>' or $null; Reason = '<why not>' or $null }.
#   -WindowIndex  which window (default the first listed)
# The tab chosen is the selected one, else the first.
function Get-GhozttyFirstPaneId {
    param($List, [int]$WindowIndex = 0)
    if ($null -eq $List) { return @{ Id = $null; Reason = 'no +list --json answer' } }
    if ($List.PSObject.Properties['success'] -and -not $List.success) {
        return @{ Id = $null; Reason = '+list --json answered success=false' }
    }
    $windows = @($List.data.windows | ForEach-Object { $_ })
    if ($windows.Count -le $WindowIndex) {
        return @{ Id = $null; Reason = "+list --json lists $($windows.Count) window(s), wanted index $WindowIndex" }
    }
    $tabs = @($windows[$WindowIndex].tabs | ForEach-Object { $_ })
    if ($tabs.Count -eq 0) { return @{ Id = $null; Reason = 'the window lists no tabs' } }
    $tab = @($tabs | Where-Object { $_.selected })[0]
    if ($null -eq $tab) { $tab = $tabs[0] }
    if ($null -eq $tab.splits) { return @{ Id = $null; Reason = "the tab has no 'splits' tree" } }
    $leaves = Get-GhozttyListLeaves $tab.splits
    if ($leaves.Count -eq 0) { return @{ Id = $null; Reason = "the tab's 'splits' tree holds no leaf" } }
    $id = [string]$leaves[0].id
    if (-not $id) { return @{ Id = $null; Reason = 'the first leaf carries no terminal id' } }
    return @{ Id = $id; Reason = $null }
}

# Which window of a parsed +list --json answer holds pane `$PaneId` (T1641).
# Every tab of every window is searched, not only the selected one, so the
# caller also learns whether the pane is on show (`TabSelected`).
#
# Returns @{ Window = <the window record> or $null; WindowId = '<its id>';
#            Target = '<its target name>'; TabIndex = <int>; TabSelected = <bool>;
#            Reason = '<why not>' or $null }.
#
# An id that no tab holds answers NOTHING - never the first window - because
# "the click landed in some window" is the guess this exists to retire. Two
# windows both claiming the id is reported too, rather than picking one.
#
# `WindowId` is the window's +list id, which in `separate` window mode IS its
# HWND (IpcHandlers.zig `listId`) and in single-window mode is not; the
# process-facing wrapper `Get-TestWindowForPane` (lib\TestDesktop.ps1) is what
# proves an id is a live top-level of the app before anybody aims at it.
function Get-GhozttyWindowForPane {
    param($List, [string]$PaneId)
    $miss = @{ Window = $null; WindowId = $null; Target = $null; TabIndex = -1; TabSelected = $false; Reason = $null }
    if (-not $PaneId) { $miss.Reason = 'no pane id given'; return $miss }
    if ($null -eq $List) { $miss.Reason = 'no +list --json answer'; return $miss }
    if ($List.PSObject.Properties['success'] -and -not $List.success) {
        $miss.Reason = '+list --json answered success=false'; return $miss
    }
    $windows = @($List.data.windows | ForEach-Object { $_ })
    $hits = New-Object System.Collections.ArrayList
    foreach ($w in $windows) {
        $tabs = @($w.tabs | ForEach-Object { $_ })
        for ($i = 0; $i -lt $tabs.Count; $i++) {
            foreach ($leaf in (Get-GhozttyListLeaves $tabs[$i].splits)) {
                if ([string]$leaf.id -eq $PaneId) {
                    [void]$hits.Add(@{ Window = $w; TabIndex = $i; TabSelected = [bool]$tabs[$i].selected })
                }
            }
        }
    }
    if ($hits.Count -eq 0) {
        $miss.Reason = "no tab of the $($windows.Count) listed window(s) holds pane $PaneId"
        return $miss
    }
    if ($hits.Count -gt 1) {
        $ids = ($hits | ForEach-Object { [string]$_.Window.id }) -join ','
        $miss.Reason = "pane $PaneId is listed $($hits.Count) times (windows $ids) - refusing to pick one"
        return $miss
    }
    $h = $hits[0]
    return @{
        Window = $h.Window; WindowId = [string]$h.Window.id; Target = [string]$h.Window.target
        TabIndex = $h.TabIndex; TabSelected = $h.TabSelected; Reason = $null
    }
}

# The HWND of the window holding pane `$PaneId`, proven against `$Tops` - the
# app's live top-level windows as the caller enumerated them (int64 handles)
# (T1641). Same return as Get-GhozttyWindowForPane plus `Hwnd` (int64, 0 when
# there is none).
#
# The proof is membership, not a cast: a window id that is not one of the
# app's own top-levels answers 0 with the reason. That covers a window closed
# between the two reads, and single-window mode, whose +list id names a
# workspace rather than an HWND.
function Resolve-GhozttyPaneHwnd {
    param($List, [string]$PaneId, [int64[]]$Tops = @())
    $r = Get-GhozttyWindowForPane -List $List -PaneId $PaneId
    $r.Hwnd = [int64]0
    if ($r.Reason) { return $r }
    $id = [int64]0
    if (-not [int64]::TryParse($r.WindowId, [ref]$id) -or $id -eq 0) {
        $r.Reason = "window id '$($r.WindowId)' is not a number"
        return $r
    }
    if (@($Tops | Where-Object { [int64]$_ -eq $id }).Count -eq 0) {
        $r.Reason = ("window id $id (target '$($r.Target)') is not one of the app's $(@($Tops).Count) top-level " +
            "window(s) - closed since the listing, or a single-window-mode workspace id, which is not an HWND")
        return $r
    }
    $r.Hwnd = $id
    return $r
}
