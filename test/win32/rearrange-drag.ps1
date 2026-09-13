# T1531 acceptance: dragging a pane header MOVES the pane inside its own
# window, and the drop is previewed before the button comes up.
#
# THE DEFECT. T1530 gave every pane a header while rearrange mode is on, but
# the band does nothing: a press on it is claimed and dropped on the floor, so
# the mode still cannot rearrange anything. T1528 resolved a drag point to a
# drop and T1529 taught the split tree to move and swap leaves; T1531 is the
# gesture that joins them - capture on press, a live highlight over the rect
# the pane would land in, and the tree mutation on release.
#
# ORACLE. Geometry and IDENTITY, not pixels. Every terminal pane is a child
# HWND, so a move is observable twice over: the SLOTS the children occupy
# change, and the same HANDLES still occupy them. That second half is the one
# that matters - a rearrange that rebuilt the pane would leave the layout
# looking right and the user's shell dead, which is exactly the failure T1529's
# identity rule exists to prevent, and a slot-only oracle would pass over it.
#
# The preview is checked the same way: it is a real top-level window
# (`GhozttyDropHighlight`), so "was the drop previewed, and over the right
# rect" is a rect comparison against the pane the pointer was over, not a
# screenshot. Screen probes are dead on the background desktop anyway.
#
# The drag is driven by POSTED mouse messages (down / move / up) rather than
# SendInput, for the same reason every other GUI script here is: the app runs
# on a background desktop where injected input does not exist. That is not a
# weaker gesture for this feature - the drag reads its points out of lparam and
# holds the capture itself, so the posted sequence is the real code path.
#
# Five claims, over three app runs (each run starts from a known layout, so no
# claim inherits the previous one's tree):
#   B) a press that does not travel is a CLICK: nothing moves
#   D) Escape mid-drag cancels: the preview goes and nothing moves
#   A) dropping on a pane's CENTER swaps the two panes, both still alive
#   C) dropping on a pane's lower edge puts the dragged pane BELOW it
#   E) dropping in the window's bottom edge band spans the pane across the
#      whole window - which is what makes a top-level drop different from
#      splitting the pane that happens to be there (three panes, so the two
#      answers have different widths)
#
# A positive control (ctrl+k clear_screen, the T55 pattern) runs first, so an
# injection failure aborts instead of reading as a T1531 regression.
#
# -NegativeControl inverts claim A to "the panes do not swap" - the pre-T1531
# behavior - and MUST fail; it is how a run proves the oracle discriminates.
#
# Runs on the BACKGROUND test desktop, so it never takes the user's
# foreground - asserted at the end, not assumed. Only touches ghoztty
# processes running from this repo's zig-out*.
#
#   powershell -NoProfile -File test\win32\rearrange-drag.ps1
param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }
$env:GHOZTTY_PIPE_SUFFIX = "-rdrg$PID"
$errlog = Join-Path $env:TEMP 'ghoztty-rearrange-drag-stderr.log'

. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
Assert-GhozttyIsolatedBuild -Exe $exe | Out-Null
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Stop-RepoInstances {
    [void](Stop-RepoGhoztty -Exe $exe -SettleMs 800)
}

# Every terminal leaf of the top window in SCREEN coordinates, ordered the way
# the eye reads them (top row first, then left to right), so index 0 is the
# same slot in every sample. The HWND rides along: it is what makes an
# identity claim possible at all.
#
# Unary comma on the return: PowerShell unrolls an array on return, so a
# one-element result would arrive as a scalar whose .Count is $null.
function Get-PaneBoxes([IntPtr]$top) {
    $all = @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal' |
        Where-Object Visible | ForEach-Object {
            [pscustomobject]@{
                Hwnd = [int64]$_.Hwnd
                Left = $_.Left; Top = $_.Top
                Width = $_.Width; Height = $_.Height
                Right = $_.Left + $_.Width; Bottom = $_.Top + $_.Height
            }
        })
    return , @($all | Sort-Object Top, Left)
}

function Show-Boxes([string]$label, $boxes) {
    foreach ($b in $boxes) {
        Write-Host ("      {0}: hwnd={1} x={2} y={3} w={4} h={5}" -f `
            $label, $b.Hwnd, $b.Left, $b.Top, $b.Width, $b.Height)
    }
}

# The visible drop preview's screen rect, or $null when none is up.
function Get-PreviewRect([int]$AppPid) {
    $w = @(Get-TestWindows -ProcessId $AppPid -Class 'GhozttyDropHighlight' | Where-Object Visible)
    if ($w.Count -eq 0) { return $null }
    $p = $w[0]
    [pscustomobject]@{
        Left = $p.Left; Top = $p.Top; Width = $p.Width; Height = $p.Height
    }
}

function Test-Near([int]$a, [int]$b, [int]$tol = 2) {
    return ([math]::Abs($a - $b) -le $tol)
}

# One app, one window, sized, with `$Splits` extra panes split off to the
# right, and rearrange mode ON. Every claim starts from one of these so no
# claim inherits the tree the previous one left.
function Start-Session([int]$Splits) {
    $sp = @{
        Exe = $exe
        Arguments = @(
            '--config-default-files=false',
            '--session-persistence=false',
            '--window-show-tab-bar=always',
            '--keybind=ctrl+shift+f9=toggle_rearrange_mode')
    }
    if (-not $ExePath) { $sp.StdErr = $errlog }
    $app = Start-OnTestDesktop @sp
    $appPid = [int]$app.Pid
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) {
        Write-TestAssertedNothing -Reason 'GUI died at launch'
    }
    $top = Wait-TestWindow -ProcessId $appPid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) {
        Write-TestAssertedNothing -Reason 'top window not found'
    }
    Set-TestWindowSize -Window $top -Width 1400 -Height 900 | Out-Null
    Start-Sleep -Milliseconds 500
    for ($i = 0; $i -lt $Splits; $i++) {
        & $exe +split --direction=right | Out-Null
        Start-Sleep -Milliseconds 1000
    }
    [pscustomobject]@{ App = $app; Pid = $appPid; Top = $top }
}

# End a run's app DELIBERATELY.
#
# The postmortem reporter (T527) treats any launch that is gone and was not
# marked `Killed` as a crash, and only `Remove-TestDesktop` does that marking -
# it is written for a script that launches once. This script launches three
# times on purpose, so each run marks its own app before stopping it. Without
# this the log ends with two `CRASHED - 0xFFFFFFFF` reports for apps that were
# shut down exactly as intended, which is worse than noise: it is a false crash
# report in a green run.
function Close-Session($s) {
    if ($s) {
        foreach ($r in $script:GhozttyTestDesktopLaunches) {
            if ($r.Pid -eq $s.Pid) { $r.Killed = $true }
        }
    }
    Stop-RepoInstances
}

function Enter-RearrangeMode($s) {
    $focused = [IntPtr](Get-TestFocusedWindow -Window $s.Top)
    $r = Send-TestKeys -Window $s.Top -Target $focused -Modifiers ctrl, shift -Key F9
    Start-Sleep -Milliseconds 1200
    return $r
}

function Send-Escape($s) {
    $focused = [IntPtr](Get-TestFocusedWindow -Window $s.Top)
    $r = Send-TestKeys -Window $s.Top -Target $focused -Key Escape
    Start-Sleep -Milliseconds 1000
    return $r
}

Stop-RepoInstances
Remove-Item "$env:LOCALAPPDATA\ghoztty\session-layout-debug.json" -Force -ErrorAction SilentlyContinue
Remove-Item $errlog -ErrorAction SilentlyContinue

Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$session = $null

try {
    if ($NegativeControl) {
        Write-Host 'NEGATIVE CONTROL: claim A is inverted to "the panes do not swap" - this run MUST fail'
    }

    # ===================================================================
    # RUN 1 - two panes side by side: the click, the cancel, and the swap
    # ===================================================================
    $session = Start-Session -Splits 1
    $top = $session.Top
    $dpi = Get-TestWindowDpi -Window $top
    $band = [int][math]::Round(24.0 * ($dpi / 96.0))
    Write-Host "      monitor dpi = $dpi, header band = $band px"

    # Positive control: a chord posted at the focused pane reaches binding
    # dispatch. Without this a "nothing moved" verdict cannot be told from
    # dead input.
    $haveLog = (Test-Path $errlog)
    $focused = [IntPtr](Get-TestFocusedWindow -Window $top)
    $r = Send-TestKeys -Window $top -Target $focused -Modifiers ctrl -Key K
    if (-not $r) { Write-TestAssertedNothing -Reason 'control chord not sent' }
    Start-Sleep -Milliseconds 400
    if ($haveLog) {
        if (-not (Select-String -Path $errlog -Pattern 'clear_screen' -Quiet)) {
            Write-TestAssertedNothing -Reason 'positive control failed (clear_screen never dispatched) - injection broken, not a T1531 verdict'
        }
        Write-Host 'OK    positive control: injection reaches bindings (clear_screen dispatched)'
    } else {
        Write-Host 'OK    positive control degraded: no debug log (release build), chord delivery only'
    }

    Assert (Enter-RearrangeMode $session) 'setup: ctrl+shift+f9 (toggle_rearrange_mode) delivered'
    $before = Get-PaneBoxes $top
    Assert ($before.Count -eq 2) "setup: two terminal panes (got $($before.Count))"
    if ($before.Count -ne 2) { Write-TestAssertedNothing -Reason 'the split never produced two panes' }
    Show-Boxes 'before' $before

    $left = $before[0]; $right = $before[1]
    # The grab point: inside the LEFT pane's header band, which sits directly
    # above the pane's own window.
    $grabX = $left.Left + 60
    $grabY = $left.Top - [int]($band / 2)
    # The centre of the right pane - `pane_drop`'s swap zone.
    $swapX = $right.Left + [int]($right.Width / 2)
    $swapY = $right.Top + [int]($right.Height / 2)

    # --- Claim B: a press that never travels is a click ---------------------
    Assert (Send-TestMouse -Window $top -Target $top -X $grabX -Y $grabY -Action down) 'B: press on the header delivered'
    Start-Sleep -Milliseconds 200
    Assert ($null -eq (Get-PreviewRect $session.Pid)) 'B: a press alone previews nothing'
    Assert (Send-TestMouse -Window $top -Target $top -X $grabX -Y $grabY -Action up) 'B: release delivered'
    Start-Sleep -Milliseconds 800
    $afterClick = Get-PaneBoxes $top
    $clickMoved = $false
    for ($i = 0; $i -lt 2; $i++) {
        if ($afterClick[$i].Hwnd -ne $before[$i].Hwnd) { $clickMoved = $true }
        if ($afterClick[$i].Left -ne $before[$i].Left) { $clickMoved = $true }
    }
    Assert (-not $clickMoved) 'B: a click on the header moved nothing'

    # --- Claim D: Escape mid-drag cancels -----------------------------------
    Assert (Send-TestMouse -Window $top -Target $top -X $grabX -Y $grabY -Action down) 'D: press on the header delivered'
    Assert (Send-TestMouse -Window $top -Target $top -X $swapX -Y $swapY -Action move) 'D: move onto the other pane delivered'
    Start-Sleep -Milliseconds 400
    Assert ($null -ne (Get-PreviewRect $session.Pid)) 'D: the drop is previewed while the button is down'
    Assert (Send-Escape $session) 'D: Escape delivered'
    Assert ($null -eq (Get-PreviewRect $session.Pid)) 'D: Escape took the preview away'
    [void](Send-TestMouse -Window $top -Target $top -X $swapX -Y $swapY -Action up)
    Start-Sleep -Milliseconds 800
    $afterCancel = Get-PaneBoxes $top
    $cancelMoved = $false
    for ($i = 0; $i -lt 2; $i++) {
        if ($afterCancel[$i].Hwnd -ne $before[$i].Hwnd) { $cancelMoved = $true }
    }
    Assert (-not $cancelMoved) 'D: a cancelled drag moved nothing'

    # --- Claim A: the centre of a pane SWAPS the two ------------------------
    Assert (Enter-RearrangeMode $session) 'A: back into rearrange mode'
    Assert (Send-TestMouse -Window $top -Target $top -X $grabX -Y $grabY -Action down) 'A: press on the header delivered'
    Assert (Send-TestMouse -Window $top -Target $top -X $swapX -Y $swapY -Action move) 'A: move onto the other pane centre delivered'
    Start-Sleep -Milliseconds 400
    $prev = Get-PreviewRect $session.Pid
    Assert ($null -ne $prev) 'A: the swap is previewed'
    if ($prev) {
        Write-Host ("      preview: x={0} y={1} w={2} h={3}" -f $prev.Left, $prev.Top, $prev.Width, $prev.Height)
        # A swap previews the WHOLE pane it would trade with - the pane's slot,
        # which is the pane window plus the header band above it.
        Assert (Test-Near $prev.Left $right.Left) 'A: the preview sits on the target pane (left edge)'
        Assert (Test-Near $prev.Top ($right.Top - $band)) 'A: the preview covers the target pane INCLUDING its header'
        Assert (Test-Near $prev.Width $right.Width) 'A: the preview is the target pane wide'
        Assert (Test-Near $prev.Height ($right.Height + $band)) 'A: the preview is the target pane tall'
    }
    Assert (Send-TestMouse -Window $top -Target $top -X $swapX -Y $swapY -Action up) 'A: release delivered'
    Start-Sleep -Milliseconds 1500
    Assert (-not ($session.App.Process -and $session.App.Process.HasExited)) 'A: no crash on the drop'
    Assert ($null -eq (Get-PreviewRect $session.Pid)) 'A: the preview goes away on release'

    $afterSwap = Get-PaneBoxes $top
    Show-Boxes 'after ' $afterSwap
    Assert ($afterSwap.Count -eq 2) "A: both panes still visible (got $($afterSwap.Count))"
    if ($afterSwap.Count -ne 2) { Write-TestAssertedNothing -Reason 'a pane vanished over the drop' }
    if ($NegativeControl) {
        Assert ($afterSwap[0].Hwnd -eq $before[0].Hwnd) `
            'NEGATIVE: the panes did NOT swap (pre-T1531 behavior)'
    } else {
        Assert ($afterSwap[0].Hwnd -eq $before[1].Hwnd) `
            'A: the pane that was on the right now holds the left slot'
        Assert ($afterSwap[1].Hwnd -eq $before[0].Hwnd) `
            'A: the dragged pane now holds the right slot'
    }
    # Identity: the same two windows, not two new ones. A rearrange that
    # rebuilt the panes would pass every rect claim above and kill both shells.
    $beforeIds = @($before | ForEach-Object { $_.Hwnd } | Sort-Object)
    $afterIds = @($afterSwap | ForEach-Object { $_.Hwnd } | Sort-Object)
    Assert (($beforeIds -join ',') -eq ($afterIds -join ',')) `
        'A: the same pane windows survived the move - no pane was rebuilt'
    # The slots themselves did not move: a swap exchanges occupants, it does
    # not reshape the tree.
    Assert ((Test-Near $afterSwap[0].Left $before[0].Left) -and (Test-Near $afterSwap[0].Width $before[0].Width)) `
        'A: the slots are unchanged - the panes traded places inside them'

    Close-Session $session
    $session = $null

    # ===================================================================
    # RUN 2 - two panes: an edge drop SPLITS the pane under the pointer
    # ===================================================================
    $session = Start-Session -Splits 1
    $top = $session.Top
    Assert (Enter-RearrangeMode $session) 'C: rearrange mode on'
    $before2 = Get-PaneBoxes $top
    Assert ($before2.Count -eq 2) "C: two panes to start (got $($before2.Count))"
    if ($before2.Count -ne 2) { Write-TestAssertedNothing -Reason 'run 2 setup produced the wrong layout' }
    Show-Boxes 'before' $before2
    $l2 = $before2[0]; $r2 = $before2[1]

    $grabX = $l2.Left + 60
    $grabY = $l2.Top - [int]($band / 2)
    # 80% down the right pane: past the swap rectangle, nearest the pane's
    # bottom edge, and far enough from the window's own bottom that the
    # top-level edge band (28 DIP) does not claim the point instead.
    $dropX = $r2.Left + [int]($r2.Width / 2)
    $dropY = $r2.Top + [int]($r2.Height * 0.8)

    Assert (Send-TestMouse -Window $top -Target $top -X $grabX -Y $grabY -Action down) 'C: press on the header delivered'
    Assert (Send-TestMouse -Window $top -Target $top -X $dropX -Y $dropY -Action move) 'C: move onto the lower edge delivered'
    Start-Sleep -Milliseconds 400
    $prev2 = Get-PreviewRect $session.Pid
    Assert ($null -ne $prev2) 'C: the split is previewed'
    if ($prev2) {
        Write-Host ("      preview: x={0} y={1} w={2} h={3}" -f $prev2.Left, $prev2.Top, $prev2.Width, $prev2.Height)
        $slotH = $r2.Height + $band
        Assert (Test-Near $prev2.Height ([int]($slotH / 2)) 3) `
            'C: the preview is HALF the target pane tall - the half the pane will take'
        Assert (Test-Near $prev2.Width $r2.Width) 'C: and the target pane wide'
        Assert (Test-Near ($prev2.Top + $prev2.Height) $r2.Bottom 3) `
            'C: and it is the BOTTOM half, which is the edge the pointer was nearest'
    }
    Assert (Send-TestMouse -Window $top -Target $top -X $dropX -Y $dropY -Action up) 'C: release delivered'
    Start-Sleep -Milliseconds 1500
    Assert (-not ($session.App.Process -and $session.App.Process.HasExited)) 'C: no crash on the drop'

    $after2 = Get-PaneBoxes $top
    Show-Boxes 'after ' $after2
    Assert ($after2.Count -eq 2) "C: both panes still visible (got $($after2.Count))"
    if ($after2.Count -eq 2) {
        Assert ($after2[0].Hwnd -eq $r2.Hwnd) 'C: the pane that stayed is on top'
        Assert ($after2[1].Hwnd -eq $l2.Hwnd) 'C: the dragged pane landed BELOW it'
        Assert (Test-Near $after2[0].Width $after2[1].Width 4) `
            'C: they are stacked, not side by side - the same width'
        Assert ($after2[1].Top -gt $after2[0].Bottom) 'C: and genuinely one above the other'
    }

    Close-Session $session
    $session = $null

    # ===================================================================
    # RUN 3 - three panes: the window edge band spans the WHOLE window
    # ===================================================================
    # Three panes is what makes this claim mean anything: with two, "split the
    # pane on its bottom edge" and "put it down the bottom of the window"
    # produce the same picture. With three they do not - a top-level drop is
    # full width, a pane split is a quarter of it.
    $session = Start-Session -Splits 2
    $top = $session.Top
    Assert (Enter-RearrangeMode $session) 'E: rearrange mode on'
    $before3 = Get-PaneBoxes $top
    Assert ($before3.Count -eq 3) "E: three panes to start (got $($before3.Count))"
    if ($before3.Count -ne 3) { Write-TestAssertedNothing -Reason 'run 3 setup produced the wrong layout' }
    Show-Boxes 'before' $before3

    $client = Get-TestWindowRect -Window $top -Client
    $first = $before3[0]
    $grabX = $first.Left + 60
    $grabY = $first.Top - [int]($band / 2)
    # Inside the window's bottom edge band (28 DIP).
    $edgeX = $client.Left + [int](($client.Right - $client.Left) / 2)
    $edgeY = $client.Bottom - 8

    Assert (Send-TestMouse -Window $top -Target $top -X $grabX -Y $grabY -Action down) 'E: press on the header delivered'
    Assert (Send-TestMouse -Window $top -Target $top -X $edgeX -Y $edgeY -Action move) 'E: move into the window edge band delivered'
    Start-Sleep -Milliseconds 400
    $prev3 = Get-PreviewRect $session.Pid
    Assert ($null -ne $prev3) 'E: the top-level drop is previewed'
    if ($prev3) {
        Write-Host ("      preview: x={0} y={1} w={2} h={3}" -f $prev3.Left, $prev3.Top, $prev3.Width, $prev3.Height)
        Assert (Test-Near $prev3.Width ($client.Right - $client.Left) 4) `
            'E: the preview spans the WHOLE window width - not one pane of it'
    }
    Assert (Send-TestMouse -Window $top -Target $top -X $edgeX -Y $edgeY -Action up) 'E: release delivered'
    Start-Sleep -Milliseconds 1500
    Assert (-not ($session.App.Process -and $session.App.Process.HasExited)) 'E: no crash on the drop'

    $after3 = Get-PaneBoxes $top
    Show-Boxes 'after ' $after3
    Assert ($after3.Count -eq 3) "E: all three panes still visible (got $($after3.Count))"
    if ($after3.Count -eq 3) {
        # Reading order puts the two survivors on the top row and the dragged
        # pane last, across the bottom.
        $bottom = $after3[2]
        Assert ($bottom.Hwnd -eq $first.Hwnd) 'E: the dragged pane is the one across the bottom'
        Assert (Test-Near $bottom.Width ($client.Right - $client.Left) 6) `
            'E: and it spans the whole window, which a pane split never would'
        Assert ($after3[0].Top -lt $bottom.Top -and $after3[1].Top -lt $bottom.Top) `
            'E: the other two share the row above it'
        $ids3 = @($before3 | ForEach-Object { $_.Hwnd } | Sort-Object)
        $ids3after = @($after3 | ForEach-Object { $_.Hwnd } | Sort-Object)
        Assert (($ids3 -join ',') -eq ($ids3after -join ',')) `
            'E: the same three pane windows survived - no pane was rebuilt'
    }

    Complete-TestBody  # T1039: the run reached the end of its body
} finally {
    if ($td) { Remove-TestDesktop -Desktop $td }
    Stop-RepoInstances
}

$fgSeen = @(Stop-TestForegroundWatch)
Write-Host "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
$launched = @(Get-TestLaunchedPids)
$leaked = @($fgSeen | Where-Object { $launched -contains $_ })
Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
Assert ($leaked.Count -eq 0) 'no test-desktop app ever became foreground on the interactive desktop'

# A clean green run stamps the covered files (T783) so scripts\guard-due.ps1 can
# answer "has this been checked against the code as it now stands?". Never
# under -NegativeControl: that run is red on purpose.
if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard rearrange-drag -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Label 'T1531 REARRANGE PANE DRAG' -Pass $script:pass -Fail $script:fail
