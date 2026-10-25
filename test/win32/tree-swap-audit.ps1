<#
.SYNOPSIS
    T1358 acceptance - a window's split tree is taken off the window before it
    is freed, at every site that replaces or removes one.

.DESCRIPTION
    THE DEFECT (T1356): `Window.zig` freed a tab's OLD split tree while the
    window still held it, at three swap sites, and `cleanupAllSurfaces` freed
    in place. A viewer pane's teardown pumps messages (WebView2's controller
    Close), a focus message dispatched in that pump walked `tab_trees`, and the
    whole process died on closing a window. T1356 fixed the four sites by hand;
    the rule lived on only as a comment, so the next site added would get it
    right or wrong by luck. This run is the rule, machine-checked
    (`lib\TreeSwapAudit.ps1` holds the analyzer and the shapes it reads).

    Its first sweep found a fifth site T1356 missed: `closeTabByIndex` freed
    the closing tab's tree and only THEN removed the slot. T1358 fixed it in
    the same commit as this harness.

    Four sections:

      A. The analyzer against fixtures, BOTH directions: each shape the rule
         allows yields nothing, each violating shape is named by kind, and the
         waiver needs a reason.

      B. The win32 frontend as it stands is CLEAN - every `.zig` file under
         `src\apprt\win32`, no baseline, no exceptions.

      C. The teeth, on the REAL history (T1133): `Window.zig` as it stood
         before T1356 (`8acd84127^`) is read back out of git and must be
         reported at all three swap sites, at `cleanupAllSurfaces`, and at
         `closeTabByIndex`. A gate nobody has watched fail is not a gate.

      D. The scan is not passing because it recognises nothing: it must find
         the release sites it is meant to judge in `Window.zig` (all in order)
         and the named functions among them.

    One ALL PASS / N FAILURE(S) line last, per the house convention.

.NOTES
    # persistence: launches no GUI - this reads source files (and one historical
    # blob through `git show`), it does not build or run anything.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
$Repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\TreeSwapAudit.ps1')

$script:pass = 0
$script:fail = 0
function Assert([string]$name, [bool]$cond) {
    if ($cond) { Write-Host "  PASS $name"; $script:pass++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:fail++ }
}
function AssertEq([string]$name, $expected, $actual) {
    if ($expected -eq $actual) { Write-Host "  PASS $name"; $script:pass++ }
    else {
        Write-Host "  FAIL $name (expected '$expected', got '$actual')" -ForegroundColor Red
        $script:fail++
    }
}

$tmp = Join-Path $env:TEMP "ghoztty-t1358-$PID"
if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force $tmp | Out-Null

function Get-Fixture([string]$Body, [string]$Tag, [switch]$IncludeClean) {
    $f = Join-Path $tmp "$Tag.zig"
    [System.IO.File]::WriteAllText($f, ($Body -replace "`r`n", "`n"))
    return @(Get-TreeSwapFindings -Path $f -IncludeClean:$IncludeClean)
}
function Get-Kinds($Findings) {
    return (@($Findings | ForEach-Object { $_.Kind }) -join ',')
}

# ===========================================================================
Write-Host ''
Write-Host '== A: the analyzer against fixtures'
# ===========================================================================

$fixtures = [ordered]@{
    # --- shapes the rule allows -------------------------------------------
    'swap-then-release' = @{ Expect = ''; Body = @'
fn equalizeSplits(self: *Window) void {
    const new_tree = self.tab_trees[tab].equalize(alloc) catch return;
    var old_tree = self.tab_trees[tab];
    self.tab_trees[tab] = new_tree;
    old_tree.deinit();
}
'@ }
    'two slots, both swapped first' = @{ Expect = ''; Body = @'
fn commitCrossWindowDrop(self: *Window, dest: *Window) void {
    var old_src = self.tab_trees[source_tab];
    var old_dst = dest.tab_trees[dest_tab];
    self.tab_trees[source_tab] = new_src;
    dest.tab_trees[dest_tab] = new_dst;
    old_src.deinit();
    old_dst.deinit();
}
'@ }
    'slot removed, then released' = @{ Expect = ''; Body = @'
fn closeTabByIndex(self: *Window, idx: usize) void {
    var tree = self.tab_trees[idx];
    self.removeTabSlot(idx);
    tree.deinit();
}
'@ }
    'detach through a pointer capture' = @{ Expect = ''; Body = @'
fn cleanupAllSurfaces(self: *Window) void {
    for (self.tab_trees[0..count]) |*slot| {
        var tree = slot.*;
        slot.* = .empty;
        tree.deinit();
    }
}
'@ }
    'deferred release after the swap' = @{ Expect = ''; Body = @'
fn swapIt(self: *Window) void {
    var old_tree = self.tab_trees[tab];
    defer old_tree.deinit();
    self.tab_trees[tab] = new_tree;
}
'@ }
    'a NEW tree freed on error is not a slot tree' = @{ Expect = ''; Body = @'
fn replaceTabRoot(self: *Window) !void {
    var tree = try SplitTree(PaneView).init(alloc, view);
    errdefer tree.deinit();
    var old_tree = self.tab_trees[tab_index];
    self.tab_trees[tab_index] = tree;
    old_tree.deinit();
}
'@ }
    'a comparison is not a detach, a comment is not code' = @{ Expect = 'released-while-installed'; Body = @'
fn notASwap(self: *Window) void {
    var old_tree = self.tab_trees[tab];
    if (self.tab_trees[tab] == other) return;
    // self.tab_trees[tab] = new_tree;
    const url = "http://x//self.tab_trees[tab] = y";
    old_tree.deinit();
}
'@ }
    # --- violating shapes ---------------------------------------------------
    'release-then-swap (pre-T1356)' = @{ Expect = 'released-while-installed'; Body = @'
fn insertPaneAsSplit(self: *Window) void {
    var old_tree = self.tab_trees[tab];
    old_tree.deinit();
    self.tab_trees[tab] = new_tree;
}
'@ }
    'release-then-remove (pre-T1358)' = @{ Expect = 'released-while-installed'; Body = @'
fn closeTabByIndex(self: *Window, idx: usize) void {
    var tree = self.tab_trees[idx];
    tree.deinit();
    self.removeTabSlot(idx);
}
'@ }
    'one of two slots backwards' = @{ Expect = 'released-while-installed'; Body = @'
fn commitCrossTabDrop(self: *Window) void {
    var old_src = self.tab_trees[source_tab];
    var old_dst = self.tab_trees[dest_tab];
    self.tab_trees[source_tab] = new_src;
    old_src.deinit();
    old_dst.deinit();
    self.tab_trees[dest_tab] = new_dst;
}
'@ }
    'swapping a DIFFERENT slot does not detach this one' = @{ Expect = 'released-while-installed'; Body = @'
fn wrongSlot(self: *Window) void {
    var old_tree = self.tab_trees[a];
    self.tab_trees[b] = new_tree;
    old_tree.deinit();
}
'@ }
    'in place through a pointer capture (pre-T1356)' = @{ Expect = 'in-place'; Body = @'
fn cleanupAllSurfaces(self: *Window) void {
    for (self.tab_trees[0..self.tab_count]) |*tree| {
        tree.deinit();
        tree.* = .empty;
    }
}
'@ }
    'in place on the slot itself' = @{ Expect = 'in-place'; Body = @'
fn freeIt(self: *Window) void {
    self.tab_trees[tab].deinit();
}
'@ }
    'in place through a pointer alias' = @{ Expect = 'in-place'; Body = @'
fn freeIt(window: *Window) void {
    const tree = &window.tab_trees[t];
    tree.deinit();
}
'@ }
    'a by-value capture is a copy of an installed tree' = @{ Expect = 'copy-of-installed'; Body = @'
fn freeAll(self: *Window) void {
    for (self.tab_trees[0..self.tab_count]) |tree| {
        var t = tree;
        tree.deinit();
        _ = t;
    }
}
'@ }
    'deferred release with no swap at all' = @{ Expect = 'released-while-installed'; Body = @'
fn leakish(self: *Window) void {
    var old_tree = self.tab_trees[tab];
    defer old_tree.deinit();
    doSomething();
}
'@ }
    'binding does not leak into the next function' = @{ Expect = ''; Body = @'
fn first(self: *Window) void {
    var tree = self.tab_trees[0];
    _ = tree;
}
fn second(alloc: Allocator) void {
    var tree = try SplitTree(PaneView).init(alloc, view);
    tree.deinit();
}
'@ }
    # --- the waiver ------------------------------------------------------------
    'a waiver with a reason waives' = @{ Expect = ''; Body = @'
fn waived(self: *Window) void {
    var old_tree = self.tab_trees[tab];
    // tree-swap-audit: the window is already unreachable here, nothing pumps
    old_tree.deinit();
    self.tab_trees[tab] = new_tree;
}
'@ }
    'a bare waiver waives nothing' = @{ Expect = 'released-while-installed'; Body = @'
fn bare(self: *Window) void {
    var old_tree = self.tab_trees[tab];
    old_tree.deinit(); // tree-swap-audit:
    self.tab_trees[tab] = new_tree;
}
'@ }
}

$n = 0
foreach ($name in $fixtures.Keys) {
    $n++
    $fx = $fixtures[$name]
    $got = Get-Kinds (Get-Fixture -Body $fx.Body -Tag "a$n")
    AssertEq "A$n $name" $fx.Expect $got
}

# The scan must also SEE the allowed shapes rather than skip them: every
# allowed fixture with a slot release reports it as checked-and-in-order.
$seen = @(Get-Fixture -Body $fixtures['two slots, both swapped first'].Body -Tag 'a-clean' -IncludeClean)
AssertEq "A$($n + 1) an allowed two-slot swap is SEEN as two in-order releases" 'ok,ok' (Get-Kinds $seen)

# ===========================================================================
Write-Host ''
Write-Host '== B: the win32 frontend as it stands'
# ===========================================================================

$win32Root = Join-Path $Repo 'src\apprt\win32'
$sweep = @(Get-TreeSwapSweep -Root $win32Root -IncludeClean)
$bad = @($sweep | Where-Object { $_.Kind -ne 'ok' })
AssertEq 'B1 no tree is released while the window still holds it' 0 $bad.Count
foreach ($x in $bad) {
    $rel = $x.Path.Substring($Repo.Length).TrimStart('\')
    Write-Host "      $($rel):$($x.Line) $($x.Function) $($x.Kind) ($($x.Name) <- $($x.Slot))"
}

# ===========================================================================
Write-Host ''
Write-Host '== C: the teeth - Window.zig before T1356, read back out of git'
# ===========================================================================

$preSha = '8acd84127^'
$preFile = Join-Path $tmp 'Window-pre-T1356.zig'
$blob = (& git -C $Repo show "$($preSha):src/apprt/win32/Window.zig" 2>$null | Out-String)
Assert 'C0 the pre-T1356 Window.zig was read out of history' ($LASTEXITCODE -eq 0 -and $blob.Length -gt 100000)
[System.IO.File]::WriteAllText($preFile, $blob)
$pre = @(Get-TreeSwapFindings -Path $preFile)
$preFns = @($pre | ForEach-Object { "$($_.Function):$($_.Kind)" })
foreach ($want in @(
        'closeSplitPane:released-while-installed',
        'insertPaneAsSplit:released-while-installed',
        'equalizeSplits:released-while-installed',
        'cleanupAllSurfaces:in-place',
        'closeTabByIndex:released-while-installed')) {
    Assert "C the pre-T1356 file is reported at $want" ($preFns -contains $want)
}
AssertEq 'C and nowhere else (the sites that already obeyed the rule stay quiet)' 5 $pre.Count
foreach ($x in $pre) { Write-Host "      pre-T1356 :$($x.Line) $($x.Function) $($x.Kind)" }

# ===========================================================================
Write-Host ''
Write-Host '== D: the scan saw the sites it judges'
# ===========================================================================

$win = @($sweep | Where-Object { $_.Path -like '*\Window.zig' })
Assert "D1 Window.zig: at least 15 release sites recognised ($($win.Count))" ($win.Count -ge 15)
$winFns = @($win | ForEach-Object { $_.Function })
foreach ($f in @('replaceTabRoot', 'replaceTabLeaf', 'closeSplitPane', 'insertPaneAsSplit',
        'swapSplit', 'equalizeSplits', 'cleanupAllSurfaces', 'closeTabByIndex')) {
    Assert "D the sweep judged $f" ($winFns -contains $f)
}
$kinds = @($sweep | ForEach-Object { $_.Kind } | Sort-Object -Unique)
Assert "D every result is a declared kind ($($kinds -join ', '))" (
    @($kinds | Where-Object { $_ -ne 'ok' -and (Get-TreeSwapHardKinds) -notcontains $_ }).Count -eq 0)

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

Complete-TestBody  # T1039: the run reached the end of its body

# --- stamp (T783) ----------------------------------------------------------
if ($script:fail -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard tree-swap -Repo $Repo 2>&1 |
        ForEach-Object { Write-Host "  $($_.ToString())" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Label 'TREE SWAP AUDIT' -MinPass 30
