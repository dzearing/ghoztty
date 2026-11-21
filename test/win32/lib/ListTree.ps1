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
