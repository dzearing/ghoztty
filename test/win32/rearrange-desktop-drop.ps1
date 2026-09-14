# T1539 acceptance: a pane dragged out of its window and released over EMPTY
# DESKTOP becomes a window of its own, at the place the pointer let go.
#
# THE DEFECT THIS COVERS. `pane_drop.resolve` answers `.new_window{ point }`
# for a release over no Ghoztty window at all, and T1538's commit (5ac049210)
# landed the whole win32 half of it: `newWindowFrameAt` places the frame,
# `drop_highlight.forTarget` previews it, `commitPopOutDrop` creates an empty
# window at that frame and moves the live pane into it. What T1538 never
# validated was the GESTURE - its section D drives the pane header's pop-out
# BUTTON, which reaches `commitPopOutDrop` by a different route entirely and
# says nothing about the drag. So the path a user actually takes - pick the
# pane up, carry it off the window, let go over the desktop - had no test.
#
# ORACLE. Child-window MEMBERSHIP plus HWND identity plus the FRAME, never
# pixels of content. Four things have to hold together for this to be a move
# rather than a new shell dressed up as one: a top-level window that was not
# there appears, the dragged pane's terminal HWND is a child of it (the same
# handle, so the process, the scrollback and the agent session came with it),
# it is gone from the window it left, and the new window's frame is the rect
# the preview promised while the button was still down. A test that counted
# windows would pass over a drop that closed the shell and opened a fresh one,
# which is the failure the relocation primitive exists to prevent.
#
# AND THE PREVIEW IS HELD TO THE SAME STANDARD, because "the preview tells the
# truth about what releasing there will do" is a goal of the task and not a
# nicety: the rect drawn under the pointer is compared against the window that
# actually arrives, and the one-pane case asserts that NOTHING is previewed for
# a release the product deliberately refuses (`pane_relocate.popOutAllowed` -
# a window's last pane has nowhere to go, since that trade would close one
# window and open another around the very same pane).
#
# The drag is driven by POSTED mouse messages (down / move / up), the way
# `rearrange-window-drop.ps1` drives its cross-window drag and for the same
# reason: the app runs on a background desktop where injected input does not
# exist, and the gesture reads its points out of lparam and holds the capture
# itself, so the posted sequence IS the real code path. Every point goes in as
# SCREEN coordinates against the SOURCE window with -Client, because a captured
# pointer delivers client messages to the capture owner no matter where the
# pointer is - and a point over open desktop is simply far out of range. That
# out-of-range client point is the whole mechanism under test.
#
# Three claims, over two app runs (each starts from a known layout, so no claim
# inherits the previous one's):
#   E) carrying a pane off the window previews a NEW WINDOW at the release
#      point - the source window's own frame size, with the pointer inside it
#   F) releasing there opens that window holding the pane - the same HWND - at
#      the previewed frame, and the source window keeps what it still has
#   G) a window's LAST pane released over nothing previews nothing and does
#      nothing: no window opens, and the pane stays where it was
#
# A positive control (ctrl+k clear_screen, the T55 pattern) runs first, so an
# injection failure aborts instead of reading as a T1539 regression.
#
# -NegativeControl inverts claim F to "no new window appears" - the behavior of
# a build where the desktop drop is inert - and MUST fail; it is how a run
# proves the oracle discriminates.
#
# Runs on the BACKGROUND test desktop, so it never takes the user's
# foreground - asserted at the end, not assumed. Only touches ghoztty
# processes running from this repo's zig-out*.
#
#   powershell -NoProfile -File test\win32\rearrange-desktop-drop.ps1
param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }
$env:GHOZTTY_PIPE_SUFFIX = "-rdesk$PID"
$errlog = Join-Path $env:TEMP 'ghoztty-rearrange-desktop-drop-stderr.log'

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
# Object[] and compares equal to nothing. Assign it bare.
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

# Every top-level Ghoztty window of the app.
function Get-AppWindows([int]$AppPid) {
    return , @(Get-TestWindows -ProcessId $AppPid -Class 'GhozttyWindow' | Where-Object Visible)
}

function Test-RectNear($a, $b, [int]$Tol) {
    if ($null -eq $a -or $null -eq $b) { return $false }
    return ([math]::Abs($a.Left - $b.Left) -le $Tol -and
            [math]::Abs($a.Top - $b.Top) -le $Tol -and
            [math]::Abs($a.Right - $b.Right) -le $Tol -and
            [math]::Abs($a.Bottom - $b.Bottom) -le $Tol)
}

# One app with ONE window at a known frame, with `$Splits` extra panes split
# off to the right. Placed against the work area rather than at a fixed origin
# so the empty-desktop point below is computed from the same space.
function Start-Session([int]$Splits, $Work) {
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
    Set-TestWindowPos -Window $top -X ($Work.Left + 40) -Y ($Work.Top + 40) `
        -Width 900 -Height 700 | Out-Null
    Start-Sleep -Milliseconds 500
    for ($i = 0; $i -lt $Splits; $i++) {
        & $exe +split --direction=right | Out-Null
        Start-Sleep -Milliseconds 1000
    }
    [pscustomobject]@{ App = $app; Pid = $appPid; Top = $top }
}

# End a run's app DELIBERATELY (T527): the postmortem reporter treats a launch
# that is gone and unmarked as a crash, and this script launches twice.
function Close-Session($s) {
    if ($s) {
        foreach ($r in $script:GhozttyTestDesktopLaunches) {
            if ($r.Pid -eq $s.Pid) { $r.Killed = $true }
        }
    }
    Stop-RepoInstances
}

# See the header: -Client against the SOURCE window is what a captured pointer
# actually delivers, including for points far outside that window.
function Move-Drag([IntPtr]$source, [int]$ScreenX, [int]$ScreenY, [string]$Action) {
    return Send-TestMouse -Window $source -Target $source -X $ScreenX -Y $ScreenY -Action $Action -Client
}

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
        Write-Host 'NEGATIVE CONTROL: claim F is inverted to "no new window appears" - this run MUST fail'
    }

    $work = Get-TestWorkArea -Desktop $td
    Write-Host ("      work area: {0},{1} - {2},{3}" -f $work.Left, $work.Top, $work.Right, $work.Bottom)
    # The window is 900 wide at Work.Left+40, so the desktop is only usable for
    # this test if there is room to the RIGHT of it to let go over. Said out
    # loud rather than assumed: a narrow monitor must ABORT, not read as a
    # T1539 failure.
    if ($work.Width -lt 1500 -or $work.Height -lt 800) {
        Write-TestAssertedNothing -Reason "work area $($work.Width)x$($work.Height) has no empty desktop beside a 900x700 window"
    }
    # Empty desktop: clear of the window's right edge (Work.Left+940) with a
    # margin, and far enough from the bottom that the clamped frame still ends
    # up under the pointer.
    $dropX = $work.Right - 220
    $dropY = $work.Top + 340

    # ===================================================================
    # RUN 1 - two panes, one window: carry one off the window and let go
    # ===================================================================
    $session = Start-Session -Splits 1 -Work $work
    $a = $session.Top
    $dpi = Get-TestWindowDpi -Window $a
    $scale = $dpi / 96.0
    # The header band is a layout constant (24dip) the product publishes no
    # rect for - re-derived here the way rearrange-window-drop.ps1 derives it.
    $band = [int][math]::Round(24.0 * $scale)
    Write-Host "      monitor dpi = $dpi, header band = $band px"

    # Positive control: a chord posted at the focused pane reaches binding
    # dispatch. Without it a "nothing happened" verdict cannot be told from
    # dead input.
    $haveLog = (Test-Path $errlog)
    Assert (Select-Window $a) 'setup: the keyboard is in the window'
    $focused = [IntPtr](Get-TestFocusedWindow -Window $a)
    $r = Send-TestKeys -Window $a -Target $focused -Modifiers ctrl -Key K
    if (-not $r) { Write-TestAssertedNothing -Reason 'control chord not sent' }
    Start-Sleep -Milliseconds 400
    if ($haveLog) {
        if (-not (Select-String -Path $errlog -Pattern 'clear_screen' -Quiet)) {
            Write-TestAssertedNothing -Reason 'positive control failed (clear_screen never dispatched) - injection broken, not a T1539 verdict'
        }
        Write-Host 'OK    positive control: injection reaches bindings (clear_screen dispatched)'
    } else {
        Write-Host 'OK    positive control degraded: no debug log (release build), chord delivery only'
    }

    Assert (Enter-RearrangeMode $a) 'setup: ctrl+shift+f9 (toggle_rearrange_mode) delivered'
    $srcBefore = Get-PaneBoxes $a
    Assert ($srcBefore.Count -eq 2) "setup: the window has two panes (got $($srcBefore.Count))"
    if ($srcBefore.Count -ne 2) {
        Write-TestAssertedNothing -Reason 'the split never produced the two panes every claim below reads'
    }
    Show-Boxes 'source' $srcBefore
    $srcFrame = Get-TestWindowRect -Window $a
    $winsBefore = Get-AppWindows $session.Pid
    Assert ($winsBefore.Count -eq 1) "setup: exactly one window is open (got $($winsBefore.Count))"

    $dragged = $srcBefore[0]
    $grabX = $dragged.Left + 60
    $grabY = $dragged.Top - [int]($band / 2)

    Assert (Move-Drag $a $grabX $grabY 'down') 'E: press on the pane header delivered'
    Assert (Move-Drag $a $dropX $dropY 'move') 'E: move out over empty desktop delivered'
    Start-Sleep -Milliseconds 600
    $preview = Get-PreviewRect $session.Pid
    Assert ($null -ne $preview) 'E: a release over the desktop is previewed'
    if ($preview) {
        Write-Host ("      preview: x={0} y={1} w={2} h={3}" -f $preview.Left, $preview.Top, $preview.Width, $preview.Height)
        # The new window is deliberately the SIZE of the window the pane is
        # leaving (pane_relocate: a default size would reflow the pane the
        # instant it appeared), which also tells this preview apart from the
        # half-pane wash an in-window drop draws.
        Assert ([math]::Abs($preview.Width - ($srcFrame.Right - $srcFrame.Left)) -le 4 -and
                [math]::Abs($preview.Height - ($srcFrame.Bottom - $srcFrame.Top)) -le 4) `
            'E: and it is a whole WINDOW the size of the one being dragged from, not a pane-sized highlight'
        Assert ($dropX -ge $preview.Left -and $dropX -lt $preview.Right -and
                $dropY -ge $preview.Top -and $dropY -lt $preview.Bottom) `
            'E: standing under the point the pointer is at, so the window will arrive where the hand let go'
        Assert ($preview.Left -gt $srcFrame.Left) `
            'E: and away from the window it came out of, not back over it'
    }

    Assert (Move-Drag $a $dropX $dropY 'up') 'F: release over the desktop delivered'
    Start-Sleep -Milliseconds 2500
    Assert (-not ($session.App.Process -and $session.App.Process.HasExited)) 'F: no crash on the drop'
    Assert ($null -eq (Get-PreviewRect $session.Pid)) 'F: the preview goes away on release'

    $winsAfter = Get-AppWindows $session.Pid
    $opened = @($winsAfter | Where-Object { [int64]$_.Hwnd -ne [int64]$a })
    if ($NegativeControl) {
        Assert ($opened.Count -eq 0) 'NEGATIVE: the desktop drop opened no window (inert behavior)'
    } else {
        Assert ($opened.Count -eq 1) `
            "F: a window of its own opened (windows before 1, after $($winsAfter.Count))"
    }
    if ($opened.Count -ge 1) {
        $new = [IntPtr][int64]$opened[0].Hwnd
        Assert (Test-HasPane $new $dragged.Hwnd) `
            'F: and it holds the pane that was dragged - the SAME window handle, so its shell came with it'
        Assert (-not (Test-HasPane $a $dragged.Hwnd)) 'F: which is gone from the window it left'
        $newFrame = Get-TestWindowRect -Window $new
        Write-Host ("      new window: {0},{1} - {2},{3}" -f $newFrame.Left, $newFrame.Top, $newFrame.Right, $newFrame.Bottom)
        Assert (Test-RectNear $newFrame $preview 6) `
            'F: standing exactly where the preview promised it would - the preview told the truth'
    }

    $srcAfter = Get-PaneBoxes $a
    Show-Boxes 'source' $srcAfter
    Assert ($srcAfter.Count -eq 1) "F: the window it came out of kept its other pane (got $($srcAfter.Count))"
    if ($srcAfter.Count -eq 1) {
        Assert ($srcAfter[0].Hwnd -eq $srcBefore[1].Hwnd) 'F: and it is the pane that was not dragged'
        Assert ($srcAfter[0].Width -gt $dragged.Width) 'F: which has grown into the space the other one left'
    }

    Close-Session $session
    $session = $null

    # ===================================================================
    # RUN 2 - a window's LAST pane: the drop the product refuses
    # ===================================================================
    $session = Start-Session -Splits 0 -Work $work
    $a = $session.Top
    Assert (Enter-RearrangeMode $a) 'G: rearrange mode on in the one-pane window'
    $before = Get-PaneBoxes $a
    Assert ($before.Count -eq 1) "G: setup: one pane, one window (got $($before.Count))"
    if ($before.Count -ne 1) { Write-TestAssertedNothing -Reason 'the one-pane window never came up' }
    $only = $before[0]
    $grabX = $only.Left + 60
    $grabY = $only.Top - [int]($band / 2)

    Assert (Move-Drag $a $grabX $grabY 'down') 'G: press delivered'
    Assert (Move-Drag $a $dropX $dropY 'move') 'G: move out over empty desktop delivered'
    Start-Sleep -Milliseconds 600
    Assert ($null -eq (Get-PreviewRect $session.Pid)) `
        'G: nothing is previewed - the product will not trade this window for an identical one'
    Assert (Move-Drag $a $dropX $dropY 'up') 'G: release delivered'
    Start-Sleep -Milliseconds 2000

    Assert (-not ($session.App.Process -and $session.App.Process.HasExited)) 'G: the app is still running'
    $wins = Get-AppWindows $session.Pid
    Assert ($wins.Count -eq 1) "G: no window opened and none closed (windows now $($wins.Count))"
    Assert (Test-HasPane $a $only.Hwnd) 'G: and the pane is still in the window it started in'

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
        update -Guard rearrange-desktop-drop -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Label 'T1539 REARRANGE DESKTOP DROP' -Pass $script:pass -Fail $script:fail
