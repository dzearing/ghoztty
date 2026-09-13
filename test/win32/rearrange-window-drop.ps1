# T1538 acceptance: a pane dragged into ANOTHER Ghoztty window lands there and
# keeps running, and the header's pop-out button takes a pane out into a window
# of its own.
#
# THE DEFECT. T1531 landed the drag and the drops that stay inside one window;
# T1537 added the tab strip. Everything past the window's own edge was inert:
# `pane_drop.resolve` already answered for a SET of windows and the win32
# frontend only ever handed it one, so the pane could not leave the window it
# was born in. The pop-out button had been drawn since T1530 and did nothing,
# because nothing under `src/apprt/win32/` had ever called `SetParent`.
#
# ORACLE. Child-window MEMBERSHIP plus HWND identity, never pixels. A
# relocation is observable three ways at once and all three have to hold: the
# destination window gains a child terminal window, that child is the SAME HWND
# that was under the source window a moment ago (so the process, the scrollback
# and the agent session came with it - a rebuilt pane would be a new handle),
# and the source loses it. An oracle that counted panes would pass over a
# "move" that closed one shell and started another, which is the exact failure
# the whole task exists to prevent.
#
# The drag is driven by POSTED mouse messages (down / move / up), the way
# `rearrange-drag.ps1` and `rearrange-tab-drop.ps1` drive theirs: the app runs
# on a background desktop where injected input does not exist, and the gesture
# reads its points out of lparam and holds the capture itself, so the posted
# sequence IS the real code path. Every point is computed in SCREEN space and
# then expressed in the SOURCE window's client coordinates, because that is
# what a captured pointer delivers - Windows sends every message to the capture
# owner as a client message no matter which window the pointer is over, and a
# point over another window is simply out of range. That out-of-range client
# point is the whole mechanism under test, not a way around one.
#
# Four claims, over three app runs (each starts from a known pair of windows,
# so no claim inherits the previous one's layout):
#   A) dragging a pane onto another window's pane PREVIEWS the drop over that
#      window, and releasing moves the pane there - same HWND, still running
#   B) the window the pane left keeps its remaining panes and stays open
#   C) a window whose LAST pane is dragged into another window CLOSES, without
#      taking the pane (or its session) with it
#   D) the pop-out button on a pane header opens a NEW window holding that
#      pane - again the same HWND
#
# A positive control (ctrl+k clear_screen, the T55 pattern) runs first, so an
# injection failure aborts instead of reading as a T1538 regression.
#
# -NegativeControl inverts claim A to "the pane does not move" - the pre-T1538
# behavior - and MUST fail; it is how a run proves the oracle discriminates.
#
# Runs on the BACKGROUND test desktop, so it never takes the user's
# foreground - asserted at the end, not assumed. Only touches ghoztty
# processes running from this repo's zig-out*.
#
#   powershell -NoProfile -File test\win32\rearrange-window-drop.ps1
param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }
$env:GHOZTTY_PIPE_SUFFIX = "-rwin$PID"
$errlog = Join-Path $env:TEMP 'ghoztty-rearrange-window-drop-stderr.log'

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

# Every VISIBLE terminal leaf under one top-level window, in SCREEN
# coordinates, ordered the way the eye reads them.
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

# NEVER wrap a unary-comma return in @(): the wrapper enumerates ONE level and
# hands back a one-element array holding the inner array, whose `.Hwnd` is an
# Object[] and compares equal to nothing. Assign it bare, the way
# rearrange-tab-drop.ps1 does.
function Test-HasPane([IntPtr]$top, [int64]$hwnd) {
    $boxes = Get-PaneBoxes $top
    foreach ($b in $boxes) { if ($b.Hwnd -eq $hwnd) { return $true } }
    return $false
}

# The visible drop preview's screen rect, or $null when none is up.
function Get-PreviewRect([int]$AppPid) {
    $w = @(Get-TestWindows -ProcessId $AppPid -Class 'GhozttyDropHighlight' | Where-Object Visible)
    if ($w.Count -eq 0) { return $null }
    $p = $w[0]
    [pscustomobject]@{
        Left = $p.Left; Top = $p.Top; Width = $p.Width; Height = $p.Height
        Right = $p.Left + $p.Width; Bottom = $p.Top + $p.Height
    }
}

# Every top-level Ghoztty window of the app, as { Hwnd, Left, Top, ... }.
function Get-AppWindows([int]$AppPid) {
    return , @(Get-TestWindows -ProcessId $AppPid -Class 'GhozttyWindow' | Where-Object Visible)
}

# One app with ONE window, sized, with `$Splits` extra panes split off to the
# right. The second window is opened by the caller so it can tell the two
# apart by the handles that appear.
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
    Set-TestWindowPos -Window $top -X 40 -Y 40 -Width 900 -Height 760 | Out-Null
    Start-Sleep -Milliseconds 500
    for ($i = 0; $i -lt $Splits; $i++) {
        & $exe +split --direction=right | Out-Null
        Start-Sleep -Milliseconds 1000
    }
    [pscustomobject]@{ App = $app; Pid = $appPid; Top = $top }
}

# A SECOND top-level window, placed clear of the first so no point is ambiguous
# between them. Returns its HWND - identified as the handle that was not there
# before, never assumed from enumeration order.
function Add-Window($s, [int]$X, [int]$Y) {
    # Assigned, never piped: `Get-AppWindows` returns a unary-comma array so a
    # one-window answer keeps its .Count, and a pipeline unrolls exactly one
    # level - which would hand the loop the whole array as a single item.
    $wasThere = Get-AppWindows $s.Pid
    $before = @($wasThere | ForEach-Object { [int64]$_.Hwnd })
    & $exe +new-window | Out-Null
    Start-Sleep -Milliseconds 2000
    $after = Get-AppWindows $s.Pid
    $new = @($after | Where-Object { $before -notcontains [int64]$_.Hwnd })
    if ($new.Count -ne 1) {
        Write-TestAssertedNothing -Reason "+new-window produced $($new.Count) new windows"
    }
    $h = [IntPtr][int64]$new[0].Hwnd
    Set-TestWindowPos -Window $h -X $X -Y $Y -Width 900 -Height 760 | Out-Null
    Start-Sleep -Milliseconds 700
    return $h
}

# End a run's app DELIBERATELY (T527): the postmortem reporter treats a launch
# that is gone and unmarked as a crash, and this script launches three times.
function Close-Session($s) {
    if ($s) {
        foreach ($r in $script:GhozttyTestDesktopLaunches) {
            if ($r.Pid -eq $s.Pid) { $r.Killed = $true }
        }
    }
    Stop-RepoInstances
}

# WHY EVERY MOUSE CALL BELOW PASSES -Client AND TARGETS THE SOURCE WINDOW.
#
# The press takes the CAPTURE, and Windows then delivers every mouse message to
# the capture owner as a client message regardless of which window the pointer
# is over - including points outside that window entirely, which arrive as
# client coordinates past its edges. That is exactly what a drag into another
# window is, so posting to the source window in its own client space is the
# faithful model of the gesture rather than a way around a refusal. Without
# -Client the harness would route by WM_NCHITTEST and a point over the other
# window's chrome would arrive as a non-client message the drag never sees.
# Points go in as SCREEN coordinates - `Send-TestMouse` converts them against
# the target itself, which for a point over ANOTHER window yields exactly the
# out-of-range client coordinates a captured pointer delivers.
function Move-Drag([IntPtr]$source, [int]$ScreenX, [int]$ScreenY, [string]$Action) {
    return Send-TestMouse -Window $source -Target $source -X $ScreenX -Y $ScreenY -Action $Action -Client
}

# Two top-level windows on ONE gui thread share an input queue, so the keyboard
# is thread-wide: `Set-TestActiveWindow` is the only thing that moves it between
# them off the input desktop (Focus-TestWindow moves it WITHIN a window). Every
# chord below has to land in the window it is aimed at, so this runs first and
# is asserted rather than assumed.
function Select-Window([IntPtr]$top) {
    $ok = Set-TestActiveWindow -Window $top
    Start-Sleep -Milliseconds 400
    return $ok
}

function Enter-RearrangeMode([IntPtr]$top) {
    if (-not (Select-Window $top)) { return $false }
    $focused = [IntPtr](Get-TestFocusedWindow -Window $top)
    $r = Send-TestKeys -Window $top -Target $focused -Modifiers ctrl, shift -Key F9
    Start-Sleep -Milliseconds 1200
    return $r
}

Stop-RepoInstances
Remove-Item "$env:LOCALAPPDATA\ghoztty\session-layout-debug.json" -Force -ErrorAction SilentlyContinue
Remove-Item $errlog -ErrorAction SilentlyContinue

Reset-TestBody  # T1039: an early exit must not read as a pass
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$session = $null

try {
    if ($NegativeControl) {
        Write-Host 'NEGATIVE CONTROL: claim A is inverted to "the pane does not move" - this run MUST fail'
    }

    # ===================================================================
    # RUN 1 - two windows: the preview over the other one, the move, and
    #         what the source window is left holding
    # ===================================================================
    $session = Start-Session -Splits 1
    $a = $session.Top
    $b = Add-Window $session 1000 40
    $dpi = Get-TestWindowDpi -Window $a
    $scale = $dpi / 96.0
    # The header band and the window edge band are re-derived from the DPI the
    # way rearrange-tab-drop.ps1 derives its band: they are layout constants
    # (24dip, 28dip) and the product publishes no rect for either.
    $band = [int][math]::Round(24.0 * $scale)
    $edge = [int][math]::Round(28.0 * $scale)
    Write-Host "      monitor dpi = $dpi, header band = $band px, edge band = $edge px"

    # Positive control: a chord posted at the focused pane reaches binding
    # dispatch. Without it a "nothing happened" verdict cannot be told from
    # dead input.
    $haveLog = (Test-Path $errlog)
    Assert (Select-Window $a) 'setup: the keyboard is in the source window'
    $focused = [IntPtr](Get-TestFocusedWindow -Window $a)
    $r = Send-TestKeys -Window $a -Target $focused -Modifiers ctrl -Key K
    if (-not $r) { Write-TestAssertedNothing -Reason 'control chord not sent' }
    Start-Sleep -Milliseconds 400
    if ($haveLog) {
        if (-not (Select-String -Path $errlog -Pattern 'clear_screen' -Quiet)) {
            Write-TestAssertedNothing -Reason 'positive control failed (clear_screen never dispatched) - injection broken, not a T1538 verdict'
        }
        Write-Host 'OK    positive control: injection reaches bindings (clear_screen dispatched)'
    } else {
        Write-Host 'OK    positive control degraded: no debug log (release build), chord delivery only'
    }

    Assert (Enter-RearrangeMode $a) 'setup: ctrl+shift+f9 (toggle_rearrange_mode) delivered to the source window'
    $srcBefore = Get-PaneBoxes $a
    $dstBefore = Get-PaneBoxes $b
    Assert ($srcBefore.Count -eq 2) "setup: the source window has two panes (got $($srcBefore.Count))"
    Assert ($dstBefore.Count -eq 1) "setup: the destination window has one (got $($dstBefore.Count))"
    if ($srcBefore.Count -ne 2 -or $dstBefore.Count -ne 1) {
        Write-TestAssertedNothing -Reason 'the two windows did not come up with the layout every claim below reads'
    }
    Show-Boxes 'source' $srcBefore
    Show-Boxes 'dest  ' $dstBefore

    $dragged = $srcBefore[0]
    $target = $dstBefore[0]
    $grabX = $dragged.Left + 60
    $grabY = $dragged.Top - [int]($band / 2)
    # Well inside the destination pane's RIGHT edge zone: past the swap
    # rectangle in the middle, and clear of the window edge band that would
    # mean "span the whole side" instead.
    $dropX = $target.Right - ($edge + 40)
    $dropY = [int](($target.Top + $target.Bottom) / 2)

    Assert (Move-Drag $a $grabX $grabY 'down') 'A: press on the source pane header delivered'
    Assert (Move-Drag $a $dropX $dropY 'move') 'A: move onto the other window delivered'
    Start-Sleep -Milliseconds 500
    $preview = Get-PreviewRect $session.Pid
    Assert ($null -ne $preview) 'A: the drop into the other window is previewed'
    if ($preview) {
        Write-Host ("      preview: x={0} y={1} w={2} h={3}" -f $preview.Left, $preview.Top, $preview.Width, $preview.Height)
        $dst = Get-TestWindowRect -Window $b
        Assert ($preview.Left -ge $dst.Left - 2 -and $preview.Right -le $dst.Right + 2) `
            'A: the preview stands over the DESTINATION window, not the one being dragged from'
        Assert ($preview.Width -lt $target.Width) `
            'A: and it is the half-pane the drop would take, not a wash over the whole pane'
    }

    Assert (Move-Drag $a $dropX $dropY 'up') 'A: release delivered'
    Start-Sleep -Milliseconds 2000
    Assert (-not ($session.App.Process -and $session.App.Process.HasExited)) 'A: no crash on the drop'
    Assert ($null -eq (Get-PreviewRect $session.Pid)) 'A: the preview goes away on release'

    $srcAfter = Get-PaneBoxes $a
    $dstAfter = Get-PaneBoxes $b
    Show-Boxes 'source' $srcAfter
    Show-Boxes 'dest  ' $dstAfter

    if ($NegativeControl) {
        Assert (Test-HasPane $a $dragged.Hwnd) 'NEGATIVE: the pane never left its window (pre-T1538 behavior)'
    } else {
        Assert (Test-HasPane $b $dragged.Hwnd) `
            'A: the pane is now a child of the OTHER window - and it is the SAME window handle, so its shell came with it'
        Assert (-not (Test-HasPane $a $dragged.Hwnd)) 'A: and it is gone from the window it left'
    }
    Assert ($dstAfter.Count -eq 2) "A: the destination window now shows two panes (got $($dstAfter.Count))"

    # Claim B: what the source is left holding.
    Assert ($srcAfter.Count -eq 1) "B: the source window kept its other pane (got $($srcAfter.Count))"
    if ($srcAfter.Count -eq 1) {
        Assert ($srcAfter[0].Hwnd -eq $srcBefore[1].Hwnd) 'B: and it is the pane that was not dragged'
        Assert ($srcAfter[0].Width -gt $dragged.Width) 'B: which has grown into the space the other one left'
    }
    $openNow = Get-AppWindows $session.Pid
    Assert ($openNow.Count -eq 2) "B: both windows are still open (got $($openNow.Count))"

    Close-Session $session
    $session = $null

    # ===================================================================
    # RUN 2 - a window whose LAST pane is dragged away closes behind it
    # ===================================================================
    $session = Start-Session -Splits 0
    $a = $session.Top
    $b = Add-Window $session 1000 40
    Assert (Enter-RearrangeMode $a) 'C: rearrange mode on in the one-pane window'
    $srcBefore = Get-PaneBoxes $a
    $dstBefore = Get-PaneBoxes $b
    Assert ($srcBefore.Count -eq 1 -and $dstBefore.Count -eq 1) 'C: setup: one pane in each window'
    if ($srcBefore.Count -ne 1 -or $dstBefore.Count -ne 1) {
        Write-TestAssertedNothing -Reason 'the one-pane pair never came up'
    }

    $dragged = $srcBefore[0]
    $target = $dstBefore[0]
    $grabX = $dragged.Left + 60
    $grabY = $dragged.Top - [int]($band / 2)
    $dropX = $target.Right - ($edge + 40)
    $dropY = [int](($target.Top + $target.Bottom) / 2)

    Assert (Move-Drag $a $grabX $grabY 'down') 'C: press delivered'
    Assert (Move-Drag $a $dropX $dropY 'move') 'C: move onto the other window delivered'
    Start-Sleep -Milliseconds 400
    Assert (Move-Drag $a $dropX $dropY 'up') 'C: release delivered'
    Start-Sleep -Milliseconds 2500

    Assert (-not ($session.App.Process -and $session.App.Process.HasExited)) 'C: the app is still running'
    Assert (Test-HasPane $b $dragged.Hwnd) 'C: the pane arrived in the other window, still the same handle'
    $wins = Get-AppWindows $session.Pid
    Assert ($wins.Count -eq 1) "C: the window it emptied has closed (windows now $($wins.Count))"
    if ($wins.Count -ge 1) {
        Assert ([int64]$wins[0].Hwnd -eq [int64]$b) 'C: and the window still standing is the destination'
    }

    Close-Session $session
    $session = $null

    # ===================================================================
    # RUN 3 - the pop-out button takes a pane into a window of its own
    # ===================================================================
    $session = Start-Session -Splits 1
    $a = $session.Top
    Assert (Enter-RearrangeMode $a) 'D: rearrange mode on'
    $before = Get-PaneBoxes $a
    Assert ($before.Count -eq 2) "D: setup: two panes (got $($before.Count))"
    if ($before.Count -ne 2) { Write-TestAssertedNothing -Reason 'the split never produced two panes' }
    $popped = $before[1]

    # The pop-out button sits at the right end of the header band, one pad in
    # (8dip) with a 20dip hit box - `rearrange_header.layout`. Re-derived here
    # for the same reason the band is: the product publishes no rect for it.
    $btnX = $popped.Right - [int][math]::Round(18.0 * $scale)
    $btnY = $popped.Top - [int]($band / 2)
    $winsBefore = (Get-AppWindows $session.Pid).Count


    Assert (Move-Drag $a $btnX $btnY 'down') 'D: press on the pop-out button delivered'
    Assert (Move-Drag $a $btnX $btnY 'up') 'D: release delivered'
    Start-Sleep -Milliseconds 2500

    Assert (-not ($session.App.Process -and $session.App.Process.HasExited)) 'D: no crash on the pop-out'
    $winsAfter = Get-AppWindows $session.Pid
    Assert ($winsAfter.Count -eq $winsBefore + 1) `
        "D: a new window opened (before $winsBefore, after $($winsAfter.Count))"
    $opened = @($winsAfter | Where-Object { [int64]$_.Hwnd -ne [int64]$a })
    if ($opened.Count -ge 1) {
        $new = [IntPtr][int64]$opened[0].Hwnd
        Assert (Test-HasPane $new $popped.Hwnd) `
            'D: and it holds the pane that was popped out - the same handle, so the shell came with it'
        Assert (-not (Test-HasPane $a $popped.Hwnd)) 'D: which has left the window it came from'
    }
    $left = Get-PaneBoxes $a
    Assert ($left.Count -eq 1) "D: the original window kept its other pane (got $($left.Count))"

    Close-Session $session
    $session = $null

    Complete-TestBody  # T1039: the run reached the end of its body
} finally {
    if ($session) { Close-Session $session }
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
        update -Guard rearrange-window-drop -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Label 'T1538 REARRANGE WINDOW DROP' -Pass $script:pass -Fail $script:fail
