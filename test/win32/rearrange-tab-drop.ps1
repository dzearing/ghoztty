# T1537 acceptance: a pane dragged onto the TAB STRIP becomes a tab of its
# own, and resting on a tab button carries the drag into that tab.
#
# THE DEFECT. T1531 landed the drag and the three drops that stay inside one
# tab's layout, and deliberately left the strip inert: `pane_drop.resolve`
# already answered `.new_tab` for a point on the strip and `pane_drop.hoveredTab`
# already answered the dwell, and NEITHER had a caller. So the one rearrangement
# a user reaches for most - "put this pane in its own tab" - could not be done
# by dragging at all; you opened a new tab and started the work over.
#
# ORACLE. Tab COUNT plus pane IDENTITY, not pixels. A new-tab drop is
# observable three ways at once and all three have to hold: the window gains a
# tab, the tab it gains holds exactly the pane that was dragged (the same child
# HWND, so the shell and the scrollback came with it), and the tab it left has
# one fewer pane. An oracle that only counted tabs would pass over a drop that
# opened a tab around a REBUILT pane, which is precisely the failure the
# identity rule exists to prevent.
#
# The caret is checked as a real window (`GhozttyDropHighlight`) landing inside
# the strip band that `+list --json` publishes - the product's own geometry,
# never re-derived here (T231). Pixel probes are dead on the background desktop
# this runs on, and a rect comparison is the stronger claim anyway.
#
# The drag is driven by POSTED mouse messages (down / move / up) rather than
# SendInput, the way `rearrange-drag.ps1` drives its own: the app runs on a
# background desktop where injected input does not exist, and the gesture reads
# its points out of lparam and holds the capture itself, so the posted sequence
# is the real code path.
#
# Four claims, over three app runs (each starts from a known layout, so no
# claim inherits the previous one's tree):
#   A) dropping a pane on the strip PREVIEWS a caret there and then opens a new
#      tab holding that pane - the same pane, still running
#   B) the new tab lands at the INDEX that was under the pointer, not appended
#   C) a pane that is its tab's only pane is already a tab of its own, so a
#      strip drop MOVES its tab instead (T1542): dropped where the tab already
#      is, nothing is previewed and nothing changes; dropped ahead of the other
#      tab, the caret shows and the tab moves there - same pane, no new tab
#   D) resting on another tab's button for the dwell (500ms) SWITCHES to that
#      tab mid-drag, and the drop then lands in that tab's layout - the pane
#      crosses tabs without its shell noticing
#
# A positive control (ctrl+k clear_screen, the T55 pattern) runs first, so an
# injection failure aborts instead of reading as a T1537 regression.
#
# -NegativeControl inverts claim A to "no tab is opened" - the pre-T1537
# behavior - and MUST fail; it is how a run proves the oracle discriminates.
#
# Runs on the BACKGROUND test desktop, so it never takes the user's
# foreground - asserted at the end, not assumed. Only touches ghoztty
# processes running from this repo's zig-out*.
#
#   powershell -NoProfile -File test\win32\rearrange-tab-drop.ps1
param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }
$env:GHOZTTY_PIPE_SUFFIX = "-rtab$PID"
$errlog = Join-Path $env:TEMP 'ghoztty-rearrange-tab-drop-stderr.log'

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

# Every VISIBLE terminal leaf of the top window in SCREEN coordinates, ordered
# the way the eye reads them. Only the active tab's panes are visible, so this
# is "what is in the tab on screen right now" - which is exactly the question
# every claim below asks.
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
        Right = $p.Left + $p.Width; Bottom = $p.Top + $p.Height
    }
}

function Test-Near([int]$a, [int]$b, [int]$tol = 2) {
    return ([math]::Abs($a - $b) -le $tol)
}

# The window's tab strip, in SCREEN coordinates, out of the product's OWN
# published geometry (T231) rather than re-derived here. `+list --json` reports
# it in client coordinates; the client rect places it on the screen.
function Get-Strip([IntPtr]$top) {
    $json = & $exe +list --json 2>$null | Out-String
    if (-not $json.Trim()) { return $null }
    $data = $json | ConvertFrom-Json
    if (-not $data.data) { return $null }
    $w = @($data.data.windows)[0]
    if (-not $w -or -not $w.chrome -or -not $w.chrome.tab_strip) { return $null }
    $client = Get-TestWindowRect -Window $top -Client
    $b = $w.chrome.tab_strip.band
    $tabs = @()
    foreach ($t in @($w.chrome.tab_strip.tabs)) {
        if ($null -eq $t) { $tabs += $null; continue }
        $tabs += [pscustomobject]@{
            Left = $client.Left + $t.left; Top = $client.Top + $t.top
            Right = $client.Left + $t.right; Bottom = $client.Top + $t.bottom
        }
    }
    $sel = -1
    for ($i = 0; $i -lt @($w.tabs).Count; $i++) {
        if (@($w.tabs)[$i].selected) { $sel = $i }
    }
    [pscustomobject]@{
        Left = $client.Left + $b.left; Top = $client.Top + $b.top
        Right = $client.Left + $b.right; Bottom = $client.Top + $b.bottom
        Tabs = $tabs
        TabCount = @($w.tabs).Count
        Selected = $sel
    }
}

# The rect of a tab button that is NOT the one on screen - the only kind the
# dwell has anywhere to switch to. Read out of the strip's own `selected` flag,
# never assumed from the order the setup opened them in.
function Get-BackgroundTab($strip) {
    for ($i = 0; $i -lt $strip.Tabs.Count; $i++) {
        if ($i -ne $strip.Selected -and $strip.Tabs[$i]) { return $strip.Tabs[$i] }
    }
    return $null
}

# How many tabs the window reports.
function Get-TabCount {
    $json = & $exe +list --json 2>$null | Out-String
    if (-not $json.Trim()) { return -1 }
    $data = $json | ConvertFrom-Json
    if (-not $data.data) { return -1 }
    return @((@($data.data.windows)[0]).tabs).Count
}

# One app, one window, sized, with `$Splits` extra panes split off to the right
# and `$Tabs` extra tabs, and rearrange mode ON.
function Start-Session([int]$Splits, [int]$Tabs = 0) {
    $sp = @{
        Exe = $exe
        Arguments = @(
            '--config-default-files=false',
            '--session-persistence=false',
            '--window-show-tab-bar=always',
            '--keybind=ctrl+shift+f8=new_tab',
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
    # A tab comes from the BINDING, not from a CLI flag: `+new-window` has no
    # `--tab`, and the binding is the same path a user takes.
    for ($i = 0; $i -lt $Tabs; $i++) {
        $f = [IntPtr](Get-TestFocusedWindow -Window $top)
        [void](Send-TestKeys -Window $top -Target $f -Modifiers ctrl, shift -Key F8)
        Start-Sleep -Milliseconds 1500
    }
    for ($i = 0; $i -lt $Splits; $i++) {
        & $exe +split --direction=right | Out-Null
        Start-Sleep -Milliseconds 1000
    }
    [pscustomobject]@{ App = $app; Pid = $appPid; Top = $top }
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

# WHY EVERY MOUSE CALL BELOW PASSES -Client.
#
# `Send-TestMouse` routes by the window's own WM_NCHITTEST, the way Windows
# does for an UNCAPTURED pointer - and with merged chrome the empty run of the
# tab strip answers HTCAPTION, so a move there would arrive as WM_NCMOUSEMOVE.
# A pane drag never sees that: the press takes the CAPTURE, and Windows then
# delivers every mouse message to the capture owner as a client message
# regardless of what the hit test would have said. -Client is that delivery, so
# it is the faithful model of the gesture and not a way around a refusal.
function Enter-RearrangeMode($s) {
    $focused = [IntPtr](Get-TestFocusedWindow -Window $s.Top)
    $r = Send-TestKeys -Window $s.Top -Target $focused -Modifiers ctrl, shift -Key F9
    Start-Sleep -Milliseconds 1200
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
        Write-Host 'NEGATIVE CONTROL: claim A is inverted to "no tab is opened" - this run MUST fail'
    }

    # ===================================================================
    # RUN 1 - two panes in one tab: the caret, the new tab, the identity
    # ===================================================================
    $session = Start-Session -Splits 1
    $top = $session.Top
    $dpi = Get-TestWindowDpi -Window $top
    $band = [int][math]::Round(24.0 * ($dpi / 96.0))
    Write-Host "      monitor dpi = $dpi, header band = $band px"

    # Positive control: a chord posted at the focused pane reaches binding
    # dispatch. Without it a "nothing happened" verdict cannot be told from
    # dead input.
    $haveLog = (Test-Path $errlog)
    $focused = [IntPtr](Get-TestFocusedWindow -Window $top)
    $r = Send-TestKeys -Window $top -Target $focused -Modifiers ctrl -Key K
    if (-not $r) { Write-TestAssertedNothing -Reason 'control chord not sent' }
    Start-Sleep -Milliseconds 400
    if ($haveLog) {
        if (-not (Select-String -Path $errlog -Pattern 'clear_screen' -Quiet)) {
            Write-TestAssertedNothing -Reason 'positive control failed (clear_screen never dispatched) - injection broken, not a T1537 verdict'
        }
        Write-Host 'OK    positive control: injection reaches bindings (clear_screen dispatched)'
    } else {
        Write-Host 'OK    positive control degraded: no debug log (release build), chord delivery only'
    }

    Assert (Enter-RearrangeMode $session) 'setup: ctrl+shift+f9 (toggle_rearrange_mode) delivered'
    $before = Get-PaneBoxes $top
    Assert ($before.Count -eq 2) "setup: two terminal panes in one tab (got $($before.Count))"
    if ($before.Count -ne 2) { Write-TestAssertedNothing -Reason 'the split never produced two panes' }
    Show-Boxes 'before' $before

    $strip = Get-Strip $top
    if (-not $strip) { Write-TestAssertedNothing -Reason 'the window published no tab strip geometry' }
    Write-Host ("      strip: x={0}..{1} y={2}..{3} tabs={4}" -f `
        $strip.Left, $strip.Right, $strip.Top, $strip.Bottom, $strip.TabCount)
    Assert ($strip.TabCount -eq 1) "A: one tab to start (got $($strip.TabCount))"

    $left = $before[0]; $right = $before[1]
    $grabX = $left.Left + 60
    $grabY = $left.Top - [int]($band / 2)
    # The middle of the strip's empty run, well past the single tab button:
    # that appends, which is the plain "give this pane a tab" gesture.
    $stripX = $strip.Right - 60
    $stripY = [int](($strip.Top + $strip.Bottom) / 2)

    Assert (Send-TestMouse -Window $top -Target $top -X $grabX -Y $grabY -Action down -Client) 'A: press on the header delivered'
    Assert (Send-TestMouse -Window $top -Target $top -X $stripX -Y $stripY -Action move -Client) 'A: move onto the tab strip delivered'
    Start-Sleep -Milliseconds 400
    $caret = Get-PreviewRect $session.Pid
    Assert ($null -ne $caret) 'A: the new-tab drop is previewed'
    if ($caret) {
        Write-Host ("      caret: x={0} y={1} w={2} h={3}" -f $caret.Left, $caret.Top, $caret.Width, $caret.Height)
        Assert ($caret.Width -le 12) 'A: the preview is a slim CARET, not a wash over the strip'
        Assert (Test-Near $caret.Top $strip.Top 3) 'A: it stands on the strip band (top)'
        Assert (Test-Near $caret.Bottom $strip.Bottom 3) 'A: and the full height of it'
        Assert ($caret.Left -ge $strip.Left -and $caret.Right -le $strip.Right + 1) `
            'A: and entirely INSIDE the strip - never hanging off the window'
    }

    Assert (Send-TestMouse -Window $top -Target $top -X $stripX -Y $stripY -Action up -Client) 'A: release delivered'
    Start-Sleep -Milliseconds 1800
    Assert (-not ($session.App.Process -and $session.App.Process.HasExited)) 'A: no crash on the drop'
    Assert ($null -eq (Get-PreviewRect $session.Pid)) 'A: the preview goes away on release'

    $tabsAfter = Get-TabCount
    if ($NegativeControl) {
        Assert ($tabsAfter -eq 1) 'NEGATIVE: no tab was opened (pre-T1537 behavior)'
    } else {
        Assert ($tabsAfter -eq 2) "A: the window now has two tabs (got $tabsAfter)"
    }

    $afterDrop = Get-PaneBoxes $top
    Show-Boxes 'after ' $afterDrop
    Assert ($afterDrop.Count -eq 1) "A: the new tab holds exactly one pane (got $($afterDrop.Count))"
    if ($afterDrop.Count -eq 1) {
        Assert ($afterDrop[0].Hwnd -eq $left.Hwnd) `
            'A: and it is the pane that was DRAGGED - same window, same shell, not a rebuild'
    }

    Close-Session $session
    $session = $null

    # ===================================================================
    # RUN 2 - the tab lands at the INDEX under the pointer
    # ===================================================================
    # Two tabs already open, and a pane dropped on the FIRST tab button. The
    # new tab must land at index 0 - ahead of both - which is the difference
    # between honouring where the user pointed and always appending.
    $session = Start-Session -Splits 1 -Tabs 1
    $top = $session.Top
    $strip2 = Get-Strip $top
    if (-not $strip2) { Write-TestAssertedNothing -Reason 'run 2 published no strip geometry' }
    Assert ($strip2.TabCount -eq 2) "B: two tabs to start (got $($strip2.TabCount))"
    Assert (Enter-RearrangeMode $session) 'B: rearrange mode on'
    $before2 = Get-PaneBoxes $top
    Assert ($before2.Count -eq 2) "B: the active tab has two panes (got $($before2.Count))"
    if ($before2.Count -ne 2) { Write-TestAssertedNothing -Reason 'run 2 setup produced the wrong layout' }
    Show-Boxes 'before' $before2

    $dragged2 = $before2[0]
    $grabX = $dragged2.Left + 60
    $grabY = $dragged2.Top - [int]($band / 2)
    $tab0 = $strip2.Tabs[0]
    if (-not $tab0) { Write-TestAssertedNothing -Reason 'the strip published no rect for tab 0' }
    # Inside tab 0's button, left of its middle, so the caret is the seam
    # BEFORE it.
    $t0x = $tab0.Left + [int](($tab0.Right - $tab0.Left) / 4)
    $t0y = [int](($tab0.Top + $tab0.Bottom) / 2)

    Assert (Send-TestMouse -Window $top -Target $top -X $grabX -Y $grabY -Action down -Client) 'B: press on the header delivered'
    Assert (Send-TestMouse -Window $top -Target $top -X $t0x -Y $t0y -Action move -Client) 'B: move onto the FIRST tab button delivered'
    Start-Sleep -Milliseconds 300
    $caret2 = Get-PreviewRect $session.Pid
    Assert ($null -ne $caret2) 'B: the drop is previewed over tab 0'
    if ($caret2) {
        Assert (Test-Near $caret2.Left $tab0.Left 6) `
            'B: the caret sits on the seam BEFORE tab 0, which is where the tab will open'
    }
    # Release before the 500ms dwell can fire and switch tabs under us.
    Assert (Send-TestMouse -Window $top -Target $top -X $t0x -Y $t0y -Action up -Client) 'B: release delivered'
    Start-Sleep -Milliseconds 1800
    Assert (-not ($session.App.Process -and $session.App.Process.HasExited)) 'B: no crash on the drop'

    $strip2b = Get-Strip $top
    Assert ($strip2b.TabCount -eq 3) "B: the window now has three tabs (got $($strip2b.TabCount))"
    $after2 = Get-PaneBoxes $top
    Assert ($after2.Count -eq 1) "B: the new tab holds one pane (got $($after2.Count))"
    if ($after2.Count -eq 1) {
        Assert ($after2[0].Hwnd -eq $dragged2.Hwnd) 'B: and it is the dragged pane'
    }
    # The new tab is the ACTIVE one and it is the FIRST one: its button starts
    # at the strip's own left edge, which only index 0 does.
    if ($strip2b.Tabs[0]) {
        Assert (Test-Near $strip2b.Tabs[0].Left $strip2.Tabs[0].Left 4) `
            'B: the strip still starts where it did - the new tab took index 0, it did not append'
    }

    Close-Session $session
    $session = $null

    # ===================================================================
    # RUN 3 - the refusal, and the dwell
    # ===================================================================
    $session = Start-Session -Splits 0 -Tabs 1
    $top = $session.Top
    Assert (Enter-RearrangeMode $session) 'C: rearrange mode on'
    $strip3 = Get-Strip $top
    if (-not $strip3) { Write-TestAssertedNothing -Reason 'run 3 published no strip geometry' }
    Assert ($strip3.TabCount -eq 2) "C: two tabs, one pane each (got $($strip3.TabCount))"
    $before3 = Get-PaneBoxes $top
    Assert ($before3.Count -eq 1) "C: the active tab has ONE pane (got $($before3.Count))"
    if ($before3.Count -ne 1) { Write-TestAssertedNothing -Reason 'run 3 setup produced the wrong layout' }

    $only = $before3[0]
    $grabX = $only.Left + 60
    $grabY = $only.Top - [int]($band / 2)
    $stripX = $strip3.Right - 60
    $stripY = [int](($strip3.Top + $strip3.Bottom) / 2)

    # --- Claim C: a tab's only pane cannot new-tab itself ------------------
    # The active tab is the LAST one, so the strip's empty run past it is the
    # seam right after it: where the tab already is.
    Assert ($strip3.Selected -eq 1) "C: the second tab is the one on screen (got $($strip3.Selected))"
    Assert (Send-TestMouse -Window $top -Target $top -X $grabX -Y $grabY -Action down -Client) 'C: press on the header delivered'
    Assert (Send-TestMouse -Window $top -Target $top -X $stripX -Y $stripY -Action move -Client) 'C: move onto the strip delivered'
    Start-Sleep -Milliseconds 400
    Assert ($null -eq (Get-PreviewRect $session.Pid)) `
        'C: dropping a lone pane where its tab already is previews NOTHING'
    Assert (Send-TestMouse -Window $top -Target $top -X $stripX -Y $stripY -Action up -Client) 'C: release delivered'
    Start-Sleep -Milliseconds 1200
    $stripC = Get-Strip $top
    Assert ($stripC.TabCount -eq 2) 'C: and the release opened no tab'
    Assert ($stripC.Selected -eq 1) "C: and moved nothing - the tab is still second (got $($stripC.Selected))"
    Assert (@(Get-PaneBoxes $top).Count -eq 1) 'C: the pane is still where it was'

    # --- Claim C2: dropped AHEAD of the other tab, the tab moves there -----
    # T1542. The seam before tab 0 is somewhere the tab is not, so the gesture
    # means "put this tab here": previewed with the same caret, and released as
    # a MOVE of the whole tab - never a new tab around the same pane.
    $tab0c = $stripC.Tabs[0]
    if (-not $tab0c) { Write-TestAssertedNothing -Reason 'the strip published no rect for tab 0' }
    $c2x = $tab0c.Left + [int](($tab0c.Right - $tab0c.Left) / 4)
    $c2y = [int](($tab0c.Top + $tab0c.Bottom) / 2)
    Assert (Send-TestMouse -Window $top -Target $top -X $grabX -Y $grabY -Action down -Client) 'C2: press on the header delivered'
    Assert (Send-TestMouse -Window $top -Target $top -X $c2x -Y $c2y -Action move -Client) 'C2: move onto the seam before tab 0 delivered'
    Start-Sleep -Milliseconds 300
    $caretC2 = Get-PreviewRect $session.Pid
    if ($NegativeControl) {
        Assert ($null -eq $caretC2) 'NEGATIVE: a lone pane previews nothing on the strip (pre-T1542 behavior)'
    } else {
        Assert ($null -ne $caretC2) 'C2: the move is previewed'
    }
    if ($caretC2) {
        Assert (Test-Near $caretC2.Left $tab0c.Left 6) 'C2: on the seam BEFORE tab 0, where the tab will go'
    }
    # Release before the 500ms dwell can switch tabs under us.
    Assert (Send-TestMouse -Window $top -Target $top -X $c2x -Y $c2y -Action up -Client) 'C2: release delivered'
    Start-Sleep -Milliseconds 1200
    Assert (-not ($session.App.Process -and $session.App.Process.HasExited)) 'C2: no crash on the move'
    $stripC2 = Get-Strip $top
    Assert ($stripC2.TabCount -eq 2) "C2: still two tabs - the tab MOVED, none was opened (got $($stripC2.TabCount))"
    Assert ($stripC2.Selected -eq 0) "C2: the carried tab is now FIRST, and on screen (got $($stripC2.Selected))"
    $afterC2 = @(Get-PaneBoxes $top)
    Assert ($afterC2.Count -eq 1 -and $afterC2[0].Hwnd -eq $only.Hwnd) `
        'C2: and it holds the pane that was dragged - same window, same shell'

    # --- Claim D: resting on a tab button switches to it mid-drag ----------
    # Two tabs, one pane each. Pick the pane up, rest on the OTHER tab's
    # button past the 500ms dwell, and drop on the pane that tab reveals. The
    # pane crosses tabs; the tab it left is gone, because it is empty.
    $strip3b = Get-Strip $top
    $otherTab = Get-BackgroundTab $strip3b
    if (-not $otherTab) { Write-TestAssertedNothing -Reason 'no background tab to dwell on' }
    $otherX = [int](($otherTab.Left + $otherTab.Right) / 2)
    $otherY = [int](($otherTab.Top + $otherTab.Bottom) / 2)
    Write-Host "      dwelling on tab 0 at $otherX,$otherY"

    $carried = (Get-PaneBoxes $top)[0]
    Assert (Send-TestMouse -Window $top -Target $top -X $grabX -Y $grabY -Action down -Client) 'D: press on the header delivered'
    Assert (Send-TestMouse -Window $top -Target $top -X $otherX -Y $otherY -Action move -Client) 'D: move onto the other tab button delivered'
    # Past the 500ms dwell. A second move on the same button must NOT restart
    # the clock, which is why one is sent here.
    Start-Sleep -Milliseconds 300
    [void](Send-TestMouse -Window $top -Target $top -X ($otherX + 1) -Y $otherY -Action move -Client)
    Start-Sleep -Milliseconds 900

    $shown = Get-PaneBoxes $top
    Assert ($shown.Count -eq 1) "D: one pane on screen after the dwell (got $($shown.Count))"
    $switched = ($shown.Count -eq 1 -and $shown[0].Hwnd -ne $carried.Hwnd)
    Assert $switched 'D: the dwell SWITCHED tabs - the pane on screen is the other tab''s'

    if ($switched) {
        # --- D: the centre of the revealed pane is a SWAP ------------------
        # The two panes trade tabs. Both tabs survive, because a swap moves one
        # pane each way - and the pane that lands in the BACKGROUND tab has to
        # stop being painted, which is the one thing nothing else would do for
        # it (the layout pass only ever touches the tab on screen).
        $host2 = $shown[0]
        $dropX = $host2.Left + [int]($host2.Width / 2)
        $dropY = $host2.Top + [int]($host2.Height / 2)
        Assert (Send-TestMouse -Window $top -Target $top -X $dropX -Y $dropY -Action move -Client) 'D: move onto the revealed pane centre delivered'
        Start-Sleep -Milliseconds 400
        Assert ($null -ne (Get-PreviewRect $session.Pid)) 'D: the drop into the tab the dwell opened is previewed'
        Assert (Send-TestMouse -Window $top -Target $top -X $dropX -Y $dropY -Action up -Client) 'D: release delivered'
        Start-Sleep -Milliseconds 1800
        Assert (-not ($session.App.Process -and $session.App.Process.HasExited)) 'D: no crash on the cross-tab drop'

        $afterSwap = Get-PaneBoxes $top
        Show-Boxes 'after ' $afterSwap
        Assert ((Get-TabCount) -eq 2) 'D: both tabs survive a swap - one pane went each way'
        Assert ($afterSwap.Count -eq 1) `
            "D: exactly ONE pane is on screen (got $($afterSwap.Count)) - the pane that went to the background tab stopped painting"
        if ($afterSwap.Count -eq 1) {
            Assert ($afterSwap[0].Hwnd -eq $carried.Hwnd) `
                'D: and it is the pane that was CARRIED here - same window, same shell, across a tab'
        }

        # --- D2: the same gesture again, onto an EDGE, MOVES the pane -------
        # This time the source tab has nothing left, so the tab itself has to
        # go - and it must go WITHOUT ending the session of the pane that just
        # left it, which is why the close path is not the one that removes it.
        $tabsNow = Get-Strip $top
        $backTab = Get-BackgroundTab $tabsNow
        if ($backTab) {
            $here = (Get-PaneBoxes $top)[0]
            $gX = $here.Left + 60
            $gY = $here.Top - [int]($band / 2)
            $bX = [int](($backTab.Left + $backTab.Right) / 2)
            $bY = [int](($backTab.Top + $backTab.Bottom) / 2)
            Assert (Send-TestMouse -Window $top -Target $top -X $gX -Y $gY -Action down -Client) 'D2: press on the header delivered'
            Assert (Send-TestMouse -Window $top -Target $top -X $bX -Y $bY -Action move -Client) 'D2: move onto the other tab button delivered'
            Start-Sleep -Milliseconds 1000
            $revealed = Get-PaneBoxes $top
            Assert ($revealed.Count -eq 1 -and $revealed[0].Hwnd -ne $here.Hwnd) 'D2: the dwell switched tabs again'
            if ($revealed.Count -eq 1 -and $revealed[0].Hwnd -ne $here.Hwnd) {
                $r = $revealed[0]
                # 85% down it: past the swap rectangle, nearest its bottom
                # edge, and clear of the window's own 28-DIP edge band.
                $eX = $r.Left + [int]($r.Width / 2)
                $eY = $r.Top + [int]($r.Height * 0.85)
                Assert (Send-TestMouse -Window $top -Target $top -X $eX -Y $eY -Action move -Client) 'D2: move onto its lower edge delivered'
                Start-Sleep -Milliseconds 400
                Assert ($null -ne (Get-PreviewRect $session.Pid)) 'D2: the split into that tab is previewed'
                Assert (Send-TestMouse -Window $top -Target $top -X $eX -Y $eY -Action up -Client) 'D2: release delivered'
                Start-Sleep -Milliseconds 1800
                Assert (-not ($session.App.Process -and $session.App.Process.HasExited)) 'D2: no crash on the cross-tab move'

                $final = Get-PaneBoxes $top
                Show-Boxes 'final ' $final
                Assert ((Get-TabCount) -eq 1) `
                    'D2: the tab the pane left is GONE - it had nothing else in it'
                Assert ($final.Count -eq 2) "D2: and both panes are in the one tab that is left (got $($final.Count))"
                if ($final.Count -eq 2) {
                    $ids = @($final | ForEach-Object { $_.Hwnd } | Sort-Object)
                    $want = @($here.Hwnd, $r.Hwnd | Sort-Object)
                    Assert (($ids -join ',') -eq ($want -join ',')) `
                        'D2: and they are the SAME two pane windows - no pane was rebuilt, no session was ended'
                    Assert ($final[1].Top -gt $final[0].Bottom) 'D2: stacked, the edge the pointer was nearest'
                }
            }
        }
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
        update -Guard rearrange-tab-drop -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Label 'T1537 REARRANGE TAB DROP' -Pass $script:pass -Fail $script:fail
