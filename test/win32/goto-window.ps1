# T3132 acceptance: ctrl+alt+page_up/page_down is the previous/next WINDOW,
# walking the pane sidebar's all-windows list and wrapping, and in hero mode
# it still steps the carousel instead.
#
# WHY THIS SCRIPT EXISTS. Mac 997b26535 made Cmd-Shift-Up/Down `goto_window`
# previous/next, walking "the windows in the pane sidebar's all-windows order
# ... wrapping; hero mode still takes the chord for its panes". On Windows
# that chord's mirror is ctrl+alt+page_up/page_down (T1725), and the win32
# `goto_window` arm was a bare `return true` - the action did nothing at all.
# T3132 binds the chord to `goto_window` on Windows and makes
# `App.gotoWindow` walk `PaneSidebar.allWindowsOrder` (every tab of every
# window, in the list's order), with `Window.heroStep` taking it first in
# hero mode.
#
# THE ORACLES.
#   - ACTIVATION: the active HWND of the app's GUI thread
#     (Get-TestActiveWindow). A background desktop has no foreground window,
#     so this is what "the window came forward" is measured by.
#   - THE DEBUG LOG: `goto_window <dir>: <from> -> <to> of <n>` once per
#     press that went somewhere, `heroSelect req=...` once per hero step.
#     `of <n>` is the number of stops the list had at that instant, which is
#     what proves a tab counts as one.
#
# ARMS.
#   A  three windows: three presses of next visit all three, none twice, and
#      the third lands back on the first (wrap); the log steps one along.
#   B  previous undoes next: one press back lands on the window before.
#   C  a second tab is one more stop: the list grows to 4.
#   D  hero mode: the chord steps the carousel (a heroSelect line), logs no
#      goto_window, and leaves the active window where it was.
#   E  T3134 (Mac 5558742c6): tabs that share a name list in the order they
#      OPENED. A window titled `~` gets two more tabs (three namesakes); the
#      newest's place in the list is read from the log, then move_tab drags
#      it to the front of the strip and its place is read again. It must not
#      move: by strip position (the old tie-break) it jumped two places up.
#
# -NegativeControl inverts arm A's wrap claim to "the walk did NOT come back
# to the first window", which must fail on a healthy build.
#
# Runs on the background test desktop. Only touches ghoztty processes running
# from this repo's zig-out*.
param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE,
# ahead of any isolation setup, because it drops an inherited
# $GHOZTTY_IPC_SOCKET - a test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }
$env:GHOZTTY_PIPE_SUFFIX = "-gotowintest$PID"
$errlog = Join-Path $env:TEMP "ghoztty-goto-window-stderr-$PID.log"
Remove-Item $errlog -Force -ErrorAction SilentlyContinue

. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
Assert-GhozttyIsolatedBuild -Exe $exe | Out-Null
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$script:pass = 0
$script:fail = 0
$script:skipped = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Stop-RepoInstances { [void](Stop-RepoGhoztty -Exe $exe -SettleMs 800) }

$gwPattern = 'goto_window (next|previous): (\d+) -> (\d+) of (\d+)'
$hsPattern = 'heroSelect req=(-?\d+) clamped=(\d+) cur=(\d+) n=(\d+)'

# Every match of $pattern in the app log, as match objects, streamed to the
# pipeline: every caller wraps the call in @(). NOT `return , $array` - under
# @() that is ONE element (the whole array), so `-Skip`/`.Count` read 0 or 1
# whatever the log holds (the first run of this script lost four claims to
# it; memory: ps51-null-and-comma-traps).
function Get-LogMatches([string]$pattern) {
    if (-not (Test-Path $errlog)) { return }
    foreach ($m in @(Select-String -Path $errlog -Pattern $pattern -AllMatches)) {
        foreach ($g in $m.Matches) { $g }
    }
}
function Get-LogCount([string]$pattern) { return @(Get-LogMatches $pattern).Count }

function Get-Tops { return @(Get-TestWindows -ProcessId $appPid | Sort-Object Hwnd) }

# The first visible terminal of a top-level window: where a chord is aimed.
function Get-FocusLeaf([int64]$top) {
    $v = @(Get-TestChildWindows -Window ([IntPtr]$top) -Class 'GhozttyTerminal' | Where-Object Visible)
    if ($v.Count -eq 0) { return [IntPtr]::Zero }
    return [IntPtr]$v[0].Hwnd
}

function Get-Active([int64]$anyTop) { return [int64](Get-TestActiveWindow -Window ([IntPtr]$anyTop)) }

# The active window settles to something other than $from, or the timeout.
function Wait-ActiveChange([int64]$anyTop, [int64]$from, [int]$timeoutMs = 4000) {
    $deadline = [Environment]::TickCount + $timeoutMs
    while ([Environment]::TickCount -lt $deadline) {
        $a = Get-Active $anyTop
        if ($a -ne 0 -and $a -ne $from) { return $a }
        Start-Sleep -Milliseconds 150
    }
    return (Get-Active $anyTop)
}

# One window chord at the active window. Returns the active window after it.
function Send-WindowChord([int64]$anyTop, [string]$key) {
    $from = Get-Active $anyTop
    $leaf = Get-FocusLeaf $from
    [void](Send-TestKeys -Window ([IntPtr]$from) -Target $leaf -Modifiers ctrl, alt -Key $key)
    $to = Wait-ActiveChange $anyTop $from
    Start-Sleep -Milliseconds 300
    return $to
}

Stop-RepoInstances
Remove-Item (Get-GhozttySessionLayoutPath -Root $env:LOCALAPPDATA) -Force -ErrorAction SilentlyContinue

Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$appA = $null
$appPid = 0

try {
    if ($NegativeControl) {
        Write-Host 'NEGATIVE CONTROL: arm A is inverted to "the walk did NOT wrap" - this run MUST fail'
    }

    $sp = @{ Exe = $exe; Arguments = @('--config-default-files=false', '--session-persistence=false') }
    if (-not $ExePath) { $sp.StdErr = $errlog }
    $appA = Start-OnTestDesktop @sp
    $appPid = [int]$appA.Pid
    Start-Sleep -Seconds 3
    if ($appA.Process -and $appA.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $top1 = Wait-TestWindow -ProcessId $appPid -Class 'GhozttyWindow'
    if ($top1 -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: top window not found'; exit 1 }
    Assert (-not (Test-TestDesktopLeak -ProcessId $appPid)) 'GUI is NOT enumerable on the interactive desktop'
    if (-not (Test-Path $errlog)) { Write-Host 'SETUP FAIL: no debug log - this script needs a Debug build'; exit 1 }

    # --- S: three windows ----------------------------------------------------
    foreach ($name in @('gw_b', 'gw_c')) {
        & $exe +new-window --name=$name | Out-Null
        Start-Sleep -Milliseconds 1500
    }
    $tops = @(Get-Tops)
    Assert ($tops.Count -eq 3) "setup: three top-level windows (got $($tops.Count))"
    if ($tops.Count -ne 3) { Write-Host 'ABORT: 3-window fixture not built'; exit 1 }
    $anyTop = [int64]$tops[0].Hwnd
    $all = @($tops | ForEach-Object { [int64]$_.Hwnd })
    $start = Get-Active $anyTop
    Assert ($all -contains $start) "setup: one of the three windows is active ($start)"
    if ($all -notcontains $start) { Write-Host 'ABORT: no active window to start from'; exit 1 }

    # POSITIVE CONTROL: a chord posted at a terminal reaches binding dispatch,
    # so a dead chord below cannot be blamed on injection (T157's lesson).
    [void](Send-TestKeys -Window ([IntPtr]$start) -Target (Get-FocusLeaf $start) -Modifiers ctrl -Key K)
    Start-Sleep -Milliseconds 500
    if (-not (Select-String -Path $errlog -Pattern 'clear_screen' -Quiet)) {
        Write-Host 'ABORT: positive control failed (clear_screen never dispatched) - injection is broken, not goto_window'
        exit 1
    }
    Write-Host 'OK    CONTROL: injection reaches bindings (clear_screen dispatched)'

    # --- A: next walks all three and wraps -----------------------------------
    $gw0 = Get-LogCount $gwPattern
    $seen = New-Object System.Collections.Generic.List[int64]
    $seen.Add($start)
    for ($i = 0; $i -lt 3; $i++) { $seen.Add((Send-WindowChord $anyTop 'PageDown')) }
    $firstTwo = @($seen[0], $seen[1], $seen[2] | Sort-Object -Unique)
    Assert ($firstTwo.Count -eq 3 -and @($firstTwo | Where-Object { $all -notcontains $_ }).Count -eq 0) `
        "A: two presses of next visit the other two windows, none twice ($($seen -join ' > '))"
    $wrapped = ($seen[3] -eq $seen[0])
    if ($NegativeControl) {
        Assert (-not $wrapped) 'A: the third press of next does NOT come back to the first window'
    } else {
        Assert $wrapped "A: the third press of next wraps back to the first window ($($seen[3]) == $($seen[0]))"
    }
    $lines = @(Get-LogMatches $gwPattern | Select-Object -Skip $gw0)
    Assert ($lines.Count -eq 3) "A: one goto_window line per press (got $($lines.Count))"
    $oneAlong = $true
    foreach ($m in $lines) {
        $from = [int]$m.Groups[2].Value; $to = [int]$m.Groups[3].Value; $n = [int]$m.Groups[4].Value
        if ($m.Groups[1].Value -ne 'next' -or $n -ne 3 -or $to -ne (($from + 1) % $n)) { $oneAlong = $false }
    }
    Assert $oneAlong 'A: each line steps one along a 3-stop list, wrapping (to == (from+1) mod 3)'

    # --- B: previous undoes next ---------------------------------------------
    $here = Get-Active $anyTop
    $ahead = Send-WindowChord $anyTop 'PageDown'
    $back = Send-WindowChord $anyTop 'PageUp'
    Assert ($ahead -ne $here -and $back -eq $here) "B: previous after next lands back where it was ($here > $ahead > $back)"
    $prev = @(Get-LogMatches $gwPattern | Select-Object -Last 1)
    Assert ($prev.Count -eq 1 -and $prev[0].Groups[1].Value -eq 'previous') 'B: the last line is a previous step'

    # --- C: a second tab is one more stop ------------------------------------
    $tabWin = Get-Active $anyTop
    [void](Send-TestKeys -Window ([IntPtr]$tabWin) -Target (Get-FocusLeaf $tabWin) -Modifiers ctrl, shift -Key T)
    Start-Sleep -Milliseconds 1500
    $c0 = Get-LogCount $gwPattern
    [void](Send-WindowChord $anyTop 'PageDown')
    $cl = @(Get-LogMatches $gwPattern | Select-Object -Skip $c0)
    Assert ($cl.Count -eq 1 -and [int]$cl[0].Groups[4].Value -eq 4) `
        "C: with a second tab the list has 4 stops (line: $(if ($cl.Count) { $cl[0].Value } else { 'none' }))"
    Assert (@(Get-Tops).Count -eq 3) 'C: still three windows - the new tab is a tab, not a window'

    # --- E: namesakes keep the order they opened (T3134) ---------------------
    # Its list position is the `from` of the next goto_window line; the
    # previous press puts the selection back. Same-window tab hops do not
    # change the active HWND, so this waits on the log, not on activation.
    function Get-ListPlace([int64]$win) {
        $k0 = Get-LogCount $gwPattern
        [void](Send-TestKeys -Window ([IntPtr]$win) -Target (Get-FocusLeaf $win) -Modifiers ctrl, alt -Key PageDown)
        $deadline = [Environment]::TickCount + 4000
        while ((Get-LogCount $gwPattern) -le $k0 -and [Environment]::TickCount -lt $deadline) { Start-Sleep -Milliseconds 100 }
        $m = @(Get-LogMatches $gwPattern | Select-Object -Skip $k0)
        Start-Sleep -Milliseconds 400
        $back = Get-Active $anyTop
        [void](Send-TestKeys -Window ([IntPtr]$back) -Target (Get-FocusLeaf $back) -Modifiers ctrl, alt -Key PageUp)
        $deadline = [Environment]::TickCount + 4000
        while ((Get-LogCount $gwPattern) -le ($k0 + 1) -and [Environment]::TickCount -lt $deadline) { Start-Sleep -Milliseconds 100 }
        Start-Sleep -Milliseconds 400
        if ($m.Count -lt 1) { return -1 }
        return [int]$m[0].Groups[2].Value
    }
    & $exe +new-window --name=gw_e --title=~ | Out-Null
    Start-Sleep -Milliseconds 1500
    $eTop = @(Get-Tops | Where-Object { $all -notcontains [int64]$_.Hwnd })
    Assert ($eTop.Count -eq 1) "E: setup - a fourth window titled ~ (got $($eTop.Count) new)"
    if ($eTop.Count -eq 1) {
        $eWin = [int64]$eTop[0].Hwnd
        for ($i = 0; $i -lt 2; $i++) {
            [void](Send-TestKeys -Window ([IntPtr]$eWin) -Target (Get-FocusLeaf $eWin) -Modifiers ctrl, shift -Key T)
            Start-Sleep -Milliseconds 1500
        }
        Assert ((Get-Active $anyTop) -eq $eWin) 'E: setup - the ~ window is active with its newest tab'
        $before = Get-ListPlace $eWin
        for ($i = 0; $i -lt 2; $i++) {
            [void](Send-TestKeys -Window ([IntPtr]$eWin) -Target (Get-FocusLeaf $eWin) -Modifiers ctrl, shift -Key PageUp)
            Start-Sleep -Milliseconds 500
        }
        $mt = @(Select-String -Path $errlog -Pattern 'move_tab' -AllMatches).Count
        Assert ($mt -ge 2) "E: setup - move_tab dispatched twice (log lines: $mt)"
        $after = Get-ListPlace $eWin
        Assert ($before -ge 2) "E: the newest of three namesakes is listed after the other two (place $before)"
        Assert ($before -ge 0 -and $after -eq $before) `
            "E: dragging it to the front of the strip does not move it in the list (place $before -> $after)"
    }

    # --- D: hero mode keeps the chord for its panes --------------------------
    $heroWin = Get-Active $anyTop
    [void](Send-TestKeys -Window ([IntPtr]$heroWin) -Target (Get-FocusLeaf $heroWin) -Modifiers ctrl, shift -Key D)
    Start-Sleep -Milliseconds 1200
    $splitLeaf = Get-FocusLeaf $heroWin
    $panes = @(Get-TestChildWindows -Window ([IntPtr]$heroWin) -Class 'GhozttyTerminal' | Where-Object Visible).Count
    Assert ($panes -ge 2) "D: setup - a split gives the window two panes (got $panes)"
    [void](Send-TestKeys -Window ([IntPtr]$heroWin) -Target $splitLeaf -Modifiers ctrl, shift -Key Space)
    Start-Sleep -Milliseconds 1200
    $visibleInHero = @(Get-TestChildWindows -Window ([IntPtr]$heroWin) -Class 'GhozttyTerminal' | Where-Object Visible).Count
    Assert ($visibleInHero -eq 1) "D: setup - hero mode is on (one visible pane, got $visibleInHero)"
    $d0 = Get-LogCount $gwPattern
    $h0 = Get-LogCount $hsPattern
    [void](Send-TestKeys -Window ([IntPtr]$heroWin) -Target (Get-FocusLeaf $heroWin) -Modifiers ctrl, alt -Key PageDown)
    Start-Sleep -Milliseconds 1200
    Assert ((Get-LogCount $hsPattern) -eq ($h0 + 1)) 'D: the chord stepped the hero carousel (one heroSelect line)'
    Assert ((Get-LogCount $gwPattern) -eq $d0) 'D: and logged no goto_window step'
    Assert ((Get-Active $anyTop) -eq $heroWin) 'D: the active window did not change'

    Assert (-not ($appA.Process -and $appA.Process.HasExited)) 'no crash across the walk'
}
finally {
    if ($appPid -ne 0) { Stop-Process -Id $appPid -Force -ErrorAction SilentlyContinue }
    Stop-RepoInstances
    Remove-TestDesktop -Desktop $td
}

$fgSeen = @(Stop-TestForegroundWatch)
$launched = @(Get-TestLaunchedPids)
$leaked = @($fgSeen | Where-Object { $launched -contains $_ })
Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
Assert ($leaked.Count -eq 0) 'no test-desktop app ever became foreground on the interactive desktop'

# A clean green run stamps this harness's guard row (scripts\guard-due.ps1).
if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard goto-window -Repo $repo 2>&1 | ForEach-Object { Write-Host "  $_" }
}

Write-Host ''
if ($script:fail -gt 0) {
    Write-Host "$($script:fail) FAILURE(S) ($($script:pass) assertions passed)"
    exit 1
} else {
    Write-Host "ALL PASS ($($script:pass) assertions)"
    exit 0
}
