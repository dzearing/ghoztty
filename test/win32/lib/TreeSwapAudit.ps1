# TreeSwapAudit (T1358) - find the places a window's split tree is released
# while the window still holds it.
#
# THE RULE (T1356, and the comments at the three sites that already obeyed it):
#
#     A tree in a `tab_trees` slot is taken OFF the window before it is freed.
#     Swap the new tree in (or remove the slot) first, release the old one
#     second.
#
# WHY IT MATTERS. Freeing a tree tears down its panes, and a viewer pane's
# teardown closes its WebView2 controller, which PUMPS MESSAGES. Anything
# dispatched in that pump - a WM_SETFOCUS, and the dim-overlay sweep its arm
# runs - walks `tab_trees`. If the slot still names the tree being freed, that
# walk dereferences freed panes and the whole process dies
# (STATUS_FATAL_USER_CALLBACK_EXCEPTION, 2026-09-05). Three sites did it the
# wrong way round and `cleanupAllSurfaces` freed in place; nothing checked, so
# the next site added would get it right or wrong by luck.
#
# THE SHAPES, as this file reads them (one function at a time, line by line):
#
#     var old = self.tab_trees[t];      // a BINDING to slot `self.tab_trees[t]`
#     self.tab_trees[t] = new_tree;     // DETACHES it (any assignment to the slot)
#     old.deinit();                     // fine: released after the detach
#
#     var tree = self.tab_trees[idx];
#     self.removeTabSlot(idx);          // also DETACHES: the slot is gone
#     tree.deinit();
#
#     for (self.tab_trees[0..n]) |*slot| {
#         var tree = slot.*;            // a binding through a pointer capture
#         slot.* = .empty;              // detaches through the pointer
#         tree.deinit();
#     }
#
# What is reported:
#
#     released-while-installed  a binding's `.deinit()` before any detach of
#                               its slot (the pre-T1356 order)
#     in-place                  `.deinit()` on the slot itself, or on a pointer
#                               to it (`&x.tab_trees[i]`, a `|*tree|` capture)
#     copy-of-installed         `.deinit()` on a by-value `|tree|` capture of
#                               the array - a copy of a tree that stays
#                               installed, which nothing can ever detach
#
# A `defer`/`errdefer` release is judged at the end of the function instead of
# on its own line, since that is when it runs.
#
# WAIVER: `// tree-swap-audit: <reason>` on the release line or the line above
# it. A bare marker with no reason waives nothing.
#
# Deliberately a source scan rather than a parse: Zig has no AST tool on this
# box, and the three historical violations all have the one-line shape above.
# The harness proves the scan recognises the real sites (section D) so a quiet
# result cannot be a scan that matched nothing.

$script:TsaSlot = '(?<recv>[A-Za-z_][\w\.]*)\.tab_trees\[(?<idx>[^\]]+)\]'

function Get-TreeSwapHardKinds {
    return @('released-while-installed', 'in-place', 'copy-of-installed')
}

# The code part of a line: everything before a `//` that is not inside a
# string literal, with string contents blanked so text inside a literal can
# never read as a slot assignment. Zig has no block comments, so this is the
# whole job.
function Get-TsaCode([string]$Line) {
    $sb = New-Object System.Text.StringBuilder
    $inStr = $false
    for ($i = 0; $i -lt $Line.Length; $i++) {
        $c = $Line[$i]
        if ($inStr) {
            if ($c -eq '\') { [void]$sb.Append('  '); $i++; continue }
            if ($c -eq '"') { $inStr = $false; [void]$sb.Append($c) }
            else { [void]$sb.Append(' ') }
            continue
        }
        if ($c -eq '"') { $inStr = $true; [void]$sb.Append($c); continue }
        if ($c -eq '/' -and $i + 1 -lt $Line.Length -and $Line[$i + 1] -eq '/') { break }
        [void]$sb.Append($c)
    }
    return $sb.ToString()
}

function Get-TsaSlotKey([string]$Recv, [string]$Idx) {
    return ($Recv + '.tab_trees[' + ($Idx -replace '\s', '') + ']')
}

function Test-TsaWaived([string[]]$Lines, [int]$i) {
    foreach ($j in @($i, ($i - 1))) {
        if ($j -lt 0) { continue }
        if ($Lines[$j] -match '//\s*tree-swap-audit:\s*(\S.*)?$') {
            if ($Matches[1] -and $Matches[1].Trim().Length -gt 0) { return $true }
        }
    }
    return $false
}

# Every release site in one file. Each result carries Kind: one of the hard
# kinds above, or `ok` for a release this scan checked and found in order
# (returned only with -IncludeClean, which is how the harness proves the scan
# saw the real sites).
function Get-TreeSwapFindings {
    param([Parameter(Mandatory)][string]$Path, [switch]$IncludeClean)

    $lines = @(Get-Content -LiteralPath $Path -Encoding UTF8)
    $out = New-Object System.Collections.ArrayList

    $fn = '<top>'
    $binds = @{}    # name -> @{ Slot; Copy; Detached }
    $ptrs = @{}     # name -> slot key
    $pending = New-Object System.Collections.ArrayList   # deferred releases

    $emit = {
        param($Kind, $LineNo, $Name, $Slot)
        if ($Kind -eq 'ok' -and -not $IncludeClean) { return }
        [void]$out.Add([pscustomobject]@{
                Path = $Path; Line = $LineNo; Function = $fn
                Kind = $Kind; Name = $Name; Slot = $Slot
            })
    }
    $flush = {
        foreach ($p in $pending) {
            $b = $binds[$p.Name]
            $kind = if ($b -and -not $b.Detached) { 'released-while-installed' } else { 'ok' }
            if ($p.Waived -and $kind -ne 'ok') { continue }
            & $emit $kind $p.Line $p.Name $p.Slot
        }
        $pending.Clear()
    }

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $code = Get-TsaCode $lines[$i]
        if ($code -match '^\s*(pub\s+)?(inline\s+)?fn\s+(?<n>\w+)') {
            & $flush
            $fn = $Matches['n']
            $binds = @{}
            $ptrs = @{}
            continue
        }
        if ($code -notmatch '\S') { continue }

        # Pointer to a slot: `const p = &x.tab_trees[i];`
        if ($code -match ('(var|const)\s+(?<n>\w+)\s*=\s*&' + $script:TsaSlot + '\s*;')) {
            $ptrs[$Matches['n']] = Get-TsaSlotKey $Matches['recv'] $Matches['idx']
        }
        # Value binding to a slot: `var old = x.tab_trees[i];`
        elseif ($code -match ('(var|const)\s+(?<n>\w+)\s*(:[^=]+)?=\s*' + $script:TsaSlot + '\s*;')) {
            $binds[$Matches['n']] = @{
                Slot = (Get-TsaSlotKey $Matches['recv'] $Matches['idx']); Copy = $false; Detached = $false
            }
        }
        # Value binding through a pointer: `var tree = slot.*;`
        elseif ($code -match '(var|const)\s+(?<n>\w+)\s*(:[^=]+)?=\s*(?<p>\w+)\.\*\s*;' -and
            $ptrs.ContainsKey($Matches['p'])) {
            $binds[$Matches['n']] = @{ Slot = $ptrs[$Matches['p']]; Copy = $false; Detached = $false }
        }

        # Loop captures over the array: `for (x.tab_trees[a..b]) |*slot|` / `|tree|`
        if ($code -match ('for\s*\(\s*' + $script:TsaSlot + '\s*\)\s*\|\s*(?<star>\*?)\s*(?<n>\w+)\s*[|,]')) {
            $key = $Matches['recv'] + '.tab_trees[*]'
            if ($Matches['star']) { $ptrs[$Matches['n']] = $key }
            else { $binds[$Matches['n']] = @{ Slot = $key; Copy = $true; Detached = $false } }
        }

        # Detaches. An assignment to the slot (not `==`), through a pointer to
        # it, or removing the slot outright.
        $detached = New-Object System.Collections.ArrayList
        foreach ($m in [regex]::Matches($code, ($script:TsaSlot + '\s*=(?!=)'))) {
            [void]$detached.Add((Get-TsaSlotKey $m.Groups['recv'].Value $m.Groups['idx'].Value))
        }
        foreach ($m in [regex]::Matches($code, '(?<p>\w+)\.\*\s*=(?!=)')) {
            if ($ptrs.ContainsKey($m.Groups['p'].Value)) { [void]$detached.Add($ptrs[$m.Groups['p'].Value]) }
        }
        foreach ($m in [regex]::Matches($code, '(?<recv>[A-Za-z_][\w\.]*)\.removeTabSlot\(\s*(?<idx>[^)]+)\)')) {
            [void]$detached.Add((Get-TsaSlotKey $m.Groups['recv'].Value $m.Groups['idx'].Value))
        }
        if ($detached.Count -gt 0) {
            foreach ($b in $binds.Values) {
                if ($detached -contains $b.Slot) { $b.Detached = $true }
            }
        }

        # Releases.
        foreach ($m in [regex]::Matches($code, '(?<x>[A-Za-z_][\w\.]*(\[[^\]]+\])?)\.deinit\(\)')) {
            $x = $m.Groups['x'].Value
            $isDefer = $code -match '^\s*(err)?defer\b'
            $waived = Test-TsaWaived $lines $i
            $lineNo = $i + 1
            $kind = $null; $slot = $null

            if ($x -match ('^' + $script:TsaSlot + '$')) {
                $kind = 'in-place'; $slot = Get-TsaSlotKey $Matches['recv'] $Matches['idx']
            } elseif ($ptrs.ContainsKey($x)) {
                $kind = 'in-place'; $slot = $ptrs[$x]
            } elseif ($binds.ContainsKey($x)) {
                $b = $binds[$x]; $slot = $b.Slot
                if ($b.Copy) { $kind = 'copy-of-installed' }
                elseif ($isDefer) {
                    [void]$pending.Add([pscustomobject]@{ Name = $x; Line = $lineNo; Slot = $slot; Waived = $waived })
                    continue
                } elseif (-not $b.Detached) { $kind = 'released-while-installed' }
                else { $kind = 'ok' }
            } else {
                continue   # not a tree that came out of a slot
            }
            if ($waived -and $kind -ne 'ok') { continue }
            & $emit $kind $lineNo $x $slot
        }
    }
    & $flush
    return @($out)
}

# Every `.zig` file under a root (the win32 frontend is the one that owns
# `tab_trees`; a root is a parameter so the harness can sweep a planted copy).
function Get-TreeSwapSweep {
    param([Parameter(Mandatory)][string]$Root, [switch]$IncludeClean)
    $all = New-Object System.Collections.ArrayList
    foreach ($f in @(Get-ChildItem -LiteralPath $Root -Filter *.zig -File -Recurse)) {
        foreach ($r in @(Get-TreeSwapFindings -Path $f.FullName -IncludeClean:$IncludeClean)) {
            [void]$all.Add($r)
        }
    }
    return @($all)
}
