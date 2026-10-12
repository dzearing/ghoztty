# T1830 acceptance: every pane - terminal or viewer - shows a grab handle at
# its top edge while the pointer is in the pane's top band, and dragging that
# handle moves the pane exactly as dragging a rearrange-mode header does.
#
# THE GAP. Mac shows a hover grab handle on every pane (597a193cc, a235110ff):
# translucent while the pointer is in the top fifth of the pane, solid while
# the handle is grabbed. Windows could only move a pane from its rearrange-mode
# header, so a pane could not be dragged without first entering a mode, and a
# viewer pane - which Mac gives the same handle - effectively never.
#
# ORACLE. Geometry, a published state, and pane IDENTITY - no pixels:
#   * the handle is a real top-level window (`GhozttyPaneGrabHandle`), so "is
#     it up, and over which pane" is a rect comparison against the pane's own
#     child window;
#   * hinted vs engaged is published as the window property `GhozttyGrabState`
#     (0 hidden, 1 hinted, 2 engaged), the `GhozttyDragCursor` pattern - the
#     background desktop cannot read a layered window's pixels back;
#   * a drag is scored by which pane HWND holds which slot afterwards, and that
#     the same HWNDs survived (a move that rebuilt a pane would look right and
#     kill its shell).
#
# Input is POSTED (move / down / up), like every GUI script here: the app runs
# on a background desktop where injected input does not exist. That is the
# real code path for this feature - the handle takes its point from the
# message and only lets a sampled cursor override it when the cursor MOVED.
#
# Claims:
#   A) a move into a terminal pane's top band reveals the handle, hinted,
#      centered on that pane's top edge
#   B) a move into the middle of the pane hides it again
#   C) a move into the OTHER pane's band moves it there
#   D) a press on the handle engages it; a release without travel moves
#      nothing (a click on the handle is a click)
#   E) press, drag onto the other pane's center, release: the panes SWAP, and
#      the drag asked for the move pointer while it was live
#   F) rearrange mode suppresses the handle (the header is the grip there)
#   G) a VIEWER pane gets the handle too (pointer on its nav bar), and dragging
#      it swaps it with a terminal
#
# -NegativeControl inverts claim A to "no handle appears" - the pre-T1830
# behavior - and MUST fail; it is how a run proves the oracle discriminates.
#
# Runs on the BACKGROUND test desktop, so it never takes the user's
# foreground - asserted at the end, not assumed. Only touches ghoztty
# processes running from this repo's zig-out*.
#
#   powershell -NoProfile -File test\win32\pane-grab-handle.ps1
param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }
$env:GHOZTTY_PIPE_SUFFIX = "-pgh$PID"
$errlog = Join-Path $env:TEMP 'ghoztty-pane-grab-handle-stderr.log'

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

if (-not ('GrabHandleProp' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class GrabHandleProp {
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr GetPropW(IntPtr hWnd, string lpString);
}
"@
}
$IDC_SIZEALL = 32646

# Every pane leaf of the top window (terminals and viewers), in SCREEN
# coordinates, in reading order. Unary comma: PS unrolls a returned array.
function Get-PaneBoxes([IntPtr]$top) {
    $all = @(@(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal') +
        @(Get-TestChildWindows -Window $top -Class 'GhozttyViewer') |
        Where-Object Visible | ForEach-Object {
            [pscustomobject]@{
                Hwnd = [int64]$_.Hwnd
                Kind = $_.Class
                Left = $_.Left; Top = $_.Top
                Width = $_.Width; Height = $_.Height
                Right = $_.Left + $_.Width; Bottom = $_.Top + $_.Height
            }
        })
    return , @($all | Sort-Object Top, Left)
}

function Show-Boxes([string]$label, $boxes) {
    foreach ($b in $boxes) {
        Write-Host ("      {0}: {1} hwnd={2} x={3} y={4} w={5} h={6}" -f `
            $label, $b.Kind, $b.Hwnd, $b.Left, $b.Top, $b.Width, $b.Height)
    }
}

# The handle window: its rect when visible, and its published state.
function Get-Handle([int]$AppPid) {
    $w = @(Get-TestWindows -ProcessId $AppPid -Class 'GhozttyPaneGrabHandle')
    if ($w.Count -eq 0) { return $null }
    $h = $w[0]
    [pscustomobject]@{
        Hwnd = [IntPtr]$h.Hwnd
        Visible = [bool]$h.Visible
        Left = $h.Left; Top = $h.Top; Width = $h.Width; Height = $h.Height
        State = [int64][GrabHandleProp]::GetPropW([IntPtr]$h.Hwnd, 'GhozttyGrabState')
    }
}

function Get-DragCursorProp([IntPtr]$top) {
    return [int64][GrabHandleProp]::GetPropW($top, 'GhozttyDragCursor')
}

function Test-Near([int]$a, [int]$b, [int]$tol = 2) {
    return ([math]::Abs($a - $b) -le $tol)
}

# Is the handle up, hinted or engaged, centered on $pane's top edge?
function Test-HandleOn($h, $pane) {
    if (-not $h -or -not $h.Visible -or $h.State -eq 0) { return $false }
    $mid = $pane.Left + [int]($pane.Width / 2)
    return (Test-Near ($h.Left + [int]($h.Width / 2)) $mid) -and (Test-Near $h.Top $pane.Top)
}

function Move-To($s, [IntPtr]$target, [int]$x, [int]$y) {
    $r = Send-TestMouse -Window $s.Top -Target $target -X $x -Y $y -Action move
    Start-Sleep -Milliseconds 300
    return $r
}

function Start-Session([int]$Splits, [string]$View) {
    $sp = @{
        Exe = $exe
        Arguments = @(
            '--config-default-files=false',
            # Flush flat panes: the pane's child window IS its slot.
            '--macos-pane-style=flat',
            '--session-persistence=false',
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
    if ($View) {
        & $exe +split --direction=right "--view=$View" | Out-Null
        Start-Sleep -Seconds 3
    }
    [pscustomobject]@{ App = $app; Pid = $appPid; Top = $top }
}

function Close-Session($s) {
    if ($s) {
        foreach ($r in $script:GhozttyTestDesktopLaunches) {
            if ($r.Pid -eq $s.Pid) { $r.Killed = $true }
        }
    }
    Stop-RepoInstances
}

Stop-RepoInstances
Remove-Item "$env:LOCALAPPDATA\ghoztty\session-layout-debug.json" -Force -ErrorAction SilentlyContinue
Remove-Item $errlog -ErrorAction SilentlyContinue

$docDir = Join-Path $env:TEMP "ghoztty-pane-grab-handle-$PID"
New-Item -ItemType Directory -Force -Path $docDir | Out-Null
$doc = Join-Path $docDir 'grab.md'
Set-Content -Path $doc -Value "# grab`n`nA viewer pane with a grab handle.`n" -Encoding utf8

Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$session = $null

try {
    if ($NegativeControl) {
        Write-Host 'NEGATIVE CONTROL: claim A is inverted to "no handle appears" - this run MUST fail'
    }

    # ===================================================================
    # RUN 1 - two terminals side by side
    # ===================================================================
    $session = Start-Session -Splits 1
    $top = $session.Top
    $dpi = Get-TestWindowDpi -Window $top
    $scale = $dpi / 96.0
    $before = Get-PaneBoxes $top
    Show-Boxes 'before' $before
    if ($before.Count -ne 2) { Write-TestAssertedNothing -Reason "the split never produced two panes (got $($before.Count))" }
    $left = $before[0]; $right = $before[1]

    # Positive control: the window is answering input at all - a move into
    # the middle of a pane is delivered. Without it "no handle" cannot be told
    # from dead input.
    Assert (Move-To $session ([IntPtr]$left.Hwnd) ($left.Left + 100) ($left.Top + [int]($left.Height / 2))) `
        'control: a move over the left pane is delivered'

    # --- A: the band reveals the handle, hinted, on that pane --------------
    Assert (Move-To $session ([IntPtr]$left.Hwnd) ($left.Left + 100) ($left.Top + [int](10 * $scale))) `
        'A: move into the left pane''s top band delivered'
    $h = Get-Handle $session.Pid
    if ($h) { Write-Host ("      handle: visible={0} state={1} x={2} y={3} w={4} h={5}" -f $h.Visible, $h.State, $h.Left, $h.Top, $h.Width, $h.Height) }
    if ($NegativeControl) {
        Assert (-not (Test-HandleOn $h $left)) 'NEGATIVE: no handle appears (pre-T1830 behavior)'
    } else {
        Assert (Test-HandleOn $h $left) 'A: the handle is up, centered on the left pane''s top edge'
        Assert ($h -and $h.State -eq 1) "A: and it is HINTED, not engaged (state=$($h.State))"
        Assert ($h -and (Test-Near $h.Width ([int][math]::Round(80 * $scale)))) 'A: the hit box is 80 DIP wide'
    }

    # --- B: the middle of the pane is not the band -------------------------
    [void](Move-To $session ([IntPtr]$left.Hwnd) ($left.Left + 100) ($left.Top + [int]($left.Height / 2)))
    $h = Get-Handle $session.Pid
    Assert (-not $h -or -not $h.Visible -or $h.State -eq 0) 'B: leaving the band hides the handle'

    # --- C: the other pane's band moves it there ----------------------------
    Assert (Move-To $session ([IntPtr]$right.Hwnd) ($right.Left + 100) ($right.Top + [int](10 * $scale))) `
        'C: move into the right pane''s band delivered'
    $h = Get-Handle $session.Pid
    Assert (Test-HandleOn $h $right) 'C: the handle moved to the right pane''s top edge'

    # --- D: a press engages; a click moves nothing --------------------------
    [void](Move-To $session ([IntPtr]$left.Hwnd) ($left.Left + 100) ($left.Top + [int](10 * $scale)))
    $h = Get-Handle $session.Pid
    if (-not (Test-HandleOn $h $left)) { Write-TestAssertedNothing -Reason 'the handle is not on the left pane to press' }
    $hx = $h.Left + [int]($h.Width / 2)
    $hy = $h.Top + [int]($h.Height / 2)
    Assert (Send-TestMouse -Window $top -Target $h.Hwnd -X $hx -Y $hy -Action down) 'D: press on the handle delivered'
    Start-Sleep -Milliseconds 300
    $h2 = Get-Handle $session.Pid
    Assert ($h2 -and $h2.State -eq 2) "D: the pressed handle is ENGAGED (state=$($h2.State))"
    Assert ((Get-DragCursorProp $top) -eq 0) 'D: a press that has not travelled is not yet a drag'
    Assert (Send-TestMouse -Window $top -Target $top -X $hx -Y $hy -Action up) 'D: release delivered'
    Start-Sleep -Milliseconds 800
    $afterClick = Get-PaneBoxes $top
    Assert (($afterClick.Count -eq 2) -and ($afterClick[0].Hwnd -eq $left.Hwnd) -and ($afterClick[1].Hwnd -eq $right.Hwnd)) `
        'D: a click on the handle moved nothing'

    # --- E: drag the handle onto the other pane's center: SWAP --------------
    [void](Move-To $session ([IntPtr]$left.Hwnd) ($left.Left + 100) ($left.Top + [int](10 * $scale)))
    $h = Get-Handle $session.Pid
    $hx = $h.Left + [int]($h.Width / 2)
    $hy = $h.Top + [int]($h.Height / 2)
    $swapX = $right.Left + [int]($right.Width / 2)
    $swapY = $right.Top + [int]($right.Height / 2)
    Assert (Send-TestMouse -Window $top -Target $h.Hwnd -X $hx -Y $hy -Action down) 'E: press on the handle delivered'
    Assert (Send-TestMouse -Window $top -Target $top -X $swapX -Y $swapY -Action move) 'E: drag onto the right pane''s center delivered'
    Start-Sleep -Milliseconds 400
    $cur = Get-DragCursorProp $top
    Assert ($cur -eq $IDC_SIZEALL) "E: the live drag asks for the move pointer (got $cur)"
    $hMid = Get-Handle $session.Pid
    Assert ($hMid -and $hMid.State -eq 2 -and (Test-HandleOn $hMid $left)) `
        'E: mid-drag the handle stays ENGAGED on the pane being carried'
    $prev = @(Get-TestWindows -ProcessId $session.Pid -Class 'GhozttyDropHighlight' | Where-Object Visible)
    Assert ($prev.Count -gt 0) 'E: the drop is previewed while the button is down'
    Assert (Send-TestMouse -Window $top -Target $top -X $swapX -Y $swapY -Action up) 'E: release delivered'
    Start-Sleep -Milliseconds 1500
    Assert (-not ($session.App.Process -and $session.App.Process.HasExited)) 'E: no crash on the drop'
    $afterSwap = Get-PaneBoxes $top
    Show-Boxes 'after ' $afterSwap
    Assert ($afterSwap.Count -eq 2) "E: both panes still visible (got $($afterSwap.Count))"
    if ($afterSwap.Count -eq 2) {
        Assert ($afterSwap[0].Hwnd -eq $right.Hwnd) 'E: the right pane now holds the left slot'
        Assert ($afterSwap[1].Hwnd -eq $left.Hwnd) 'E: the dragged pane now holds the right slot'
    }
    Assert ((Get-DragCursorProp $top) -eq 0) 'E: the release took the drag pointer away'

    # --- F: rearrange mode has its own grip ---------------------------------
    $focused = [IntPtr](Get-TestFocusedWindow -Window $top)
    Assert (Send-TestKeys -Window $top -Target $focused -Modifiers ctrl, shift -Key F9) 'F: rearrange mode toggled on'
    Start-Sleep -Milliseconds 1200
    $inMode = Get-PaneBoxes $top
    if ($inMode.Count -ge 1) {
        $p = $inMode[0]
        [void](Move-To $session ([IntPtr]$p.Hwnd) ($p.Left + 100) ($p.Top + [int](10 * $scale)))
        $h = Get-Handle $session.Pid
        Assert (-not $h -or -not $h.Visible -or $h.State -eq 0) 'F: in rearrange mode the band shows no handle'
    }

    Close-Session $session
    $session = $null

    # ===================================================================
    # RUN 2 - a terminal and a VIEWER
    # ===================================================================
    $session = Start-Session -Splits 0 -View $doc
    $top = $session.Top
    $before2 = Get-PaneBoxes $top
    Show-Boxes 'before' $before2
    $viewer = @($before2 | Where-Object { $_.Kind -eq 'GhozttyViewer' })
    $term = @($before2 | Where-Object { $_.Kind -eq 'GhozttyTerminal' })
    if ($viewer.Count -ne 1 -or $term.Count -ne 1) {
        Write-TestAssertedNothing -Reason "run 2 is not one terminal + one viewer (got $($term.Count) + $($viewer.Count))"
    }
    $viewer = $viewer[0]; $term = $term[0]
    $nav = @(Get-TestChildWindows -Window $top -Class 'GhozttyViewerNav' | Where-Object Visible)
    if ($nav.Count -eq 0) { Write-TestAssertedNothing -Reason 'the viewer has no nav bar to move over' }
    $nav = $nav[0]

    Assert (Move-To $session ([IntPtr]$nav.Hwnd) ($nav.Left + 40) ($nav.Top + [int]($nav.Height / 2))) `
        'G: move over the viewer''s nav bar delivered'
    $h = Get-Handle $session.Pid
    if ($h) { Write-Host ("      handle: visible={0} state={1} x={2} y={3}" -f $h.Visible, $h.State, $h.Left, $h.Top) }
    Assert (Test-HandleOn $h $viewer) 'G: the viewer pane shows the handle at its top edge'

    if (Test-HandleOn $h $viewer) {
        $hx = $h.Left + [int]($h.Width / 2)
        $hy = $h.Top + [int]($h.Height / 2)
        $swapX = $term.Left + [int]($term.Width / 2)
        $swapY = $term.Top + [int]($term.Height / 2)
        Assert (Send-TestMouse -Window $top -Target $h.Hwnd -X $hx -Y $hy -Action down) 'G: press on the viewer''s handle delivered'
        Assert (Send-TestMouse -Window $top -Target $top -X $swapX -Y $swapY -Action move) 'G: drag onto the terminal''s center delivered'
        Start-Sleep -Milliseconds 400
        Assert (Send-TestMouse -Window $top -Target $top -X $swapX -Y $swapY -Action up) 'G: release delivered'
        Start-Sleep -Milliseconds 1500
        $after2 = Get-PaneBoxes $top
        Show-Boxes 'after ' $after2
        Assert (($after2.Count -eq 2) -and ($after2[0].Hwnd -eq $viewer.Hwnd) -and ($after2[1].Hwnd -eq $term.Hwnd)) `
            'G: the viewer and the terminal swapped places, both the same panes'
    }

    Complete-TestBody  # T1039: the run reached the end of its body
} finally {
    if ($td) { Remove-TestDesktop -Desktop $td }
    Stop-RepoInstances
    Remove-Item -Recurse -Force $docDir -ErrorAction SilentlyContinue
}

$fgSeen = @(Stop-TestForegroundWatch)
Write-Host "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
$launched = @(Get-TestLaunchedPids)
$leaked = @($fgSeen | Where-Object { $launched -contains $_ })
Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
Assert ($leaked.Count -eq 0) 'no test-desktop app ever became foreground on the interactive desktop'

# A clean green run stamps the covered files (T783). Never under
# -NegativeControl: that run is red on purpose.
if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard pane-grab-handle -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Label 'T1830 PANE GRAB HANDLE' -Pass $script:pass -Fail $script:fail
