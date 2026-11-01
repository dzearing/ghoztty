# Composition swap-chain presentation acceptance (tracker T2466, T2360 step 2).
#
# THE CHANGE: a terminal pane can present through a DXGI flip-model swap chain
# that is the content of a DirectComposition visual on the pane's window,
# instead of WGL SwapBuffers into the window's redirection bitmap
# (src/renderer/gl_comp_present.zig). It is opt-in while it is proven:
# GHOZTTY_COMP_PRESENT=1.
#
# THE CONTRACT this asserts:
#
#   A. With the knob on, every pane builds the chain (GL/D3D interop, swap
#      chain, DComp target on the pane window) and keeps presenting through it:
#      two panes, output, a resize, and no failure or fallback line. The panes
#      still draw text (capture-pane reads the renderer's own target).
#   B. A present that fails falls back to SwapBuffers for that pane, and the
#      pane keeps drawing - the debug-only seam
#      GHOZTTY_COMP_PRESENT_FAIL_AFTER=<n> fails the n+1th present.
#   C. A lost GL device on the composition path is rebuilt, and the rebuilt
#      context builds its chain again (T1690's seam).
#   D. Negative control: with the knob off, no pane touches the composition
#      path.
#   E. Overlays as child visuals (T2467): a pane on the chain publishes its
#      tree, and a BEL in it puts the bell border up as a child visual of the
#      pane - no GhozttyBellBorder popup is ever shown, a window move re-shows
#      nothing, and a key fades it out and takes it off. (The knob-off popup
#      path is bell-border.ps1.)
#   F. The unfocused-split dim as a child visual (T2491): the unfocused pane's
#      wash goes up as a visual with no GhozttyDimOverlay popup, a window move
#      and resize re-show nothing, and a banner sends it back to the popup
#      (it must cover the band above the pane window). Knob-off: split-dim.ps1.
#   G. The scrollbar as a child visual (T2492): the strip goes up as a visual
#      of the pane with no GhozttyScrollbar popup on screen, a window move
#      re-shows nothing, and hit testing stays on the pane window - a press
#      on the lit thumb starts a scrollbar drag that scrolls the viewport to
#      the top, while a click in the grid is the terminal's. (D3 is its
#      negative control: knob off, the strip is the popup.)
#   H. A banner pane's window spans its banner band (T2566): with the knob on
#      the pane window starts where the banner strip does (the strip is glued
#      over the window's top, not above it), the grid is the window less the
#      band, and that grid is exactly the window the knob-off layout gives the
#      same pane at the same size - so the rows match. Clearing the banner
#      gives the band back (H5). Negative control H6: knob off, the window
#      starts below the strip.
#
# NOT asserted here: the pixels DWM shows. This harness runs on a background
# desktop, which DWM never composes and Windows.Graphics.Capture refuses
# (T2463), so the on-screen picture of the swap chain - right way up, no tear,
# no blank frame - needs the input desktop and is T2466's follow-up.
#
#   powershell -NoProfile -File test\win32\comp-present.ps1

param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [switch]$Interactive
)

$ErrorActionPreference = 'Continue'
Set-StrictMode -Off

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\PaneCapture.ps1')
. (Join-Path $PSScriptRoot 'lib\HarnessLeak.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:passes = 0
$script:failures = 0
function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ }
    else { "  FAIL $name"; $script:failures++ }
}

if (-not (Test-Path $Exe)) { "SETUP FAIL: $Exe not found - build it first"; exit 2 }

$root = Join-Path $env:TEMP "ghoztty-comp-present-$PID"
$savedLocalAppData = $env:LOCALAPPDATA
$knobs = 'GHOZTTY_COMP_PRESENT', 'GHOZTTY_COMP_PRESENT_FAIL_AFTER', 'GHOZTTY_GL_SIMULATE_RESET_AFTER'
$saved = @{}
foreach ($k in $knobs) { $saved[$k] = [Environment]::GetEnvironmentVariable($k) }

function Set-Knobs($comp, $failAfter, $resetAfter) {
    $vals = @{ GHOZTTY_COMP_PRESENT = $comp; GHOZTTY_COMP_PRESENT_FAIL_AFTER = $failAfter; GHOZTTY_GL_SIMULATE_RESET_AFTER = $resetAfter }
    foreach ($k in $knobs) {
        if ($vals[$k]) { Set-Item "env:$k" $vals[$k] }
        else { Remove-Item "env:$k" -ErrorAction SilentlyContinue }
    }
}

[void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)
New-Item -ItemType Directory -Force $root | Out-Null

[void](Set-GhozttyTestIsolation -Tag 'comppres')
Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null

Register-RepoBuildTeardown -Exe $Exe | Out-Null
$td = New-TestDesktop -Interactive:$Interactive

function Get-Win($target) {
    $json = (& $Exe +list --json 2>$null | Out-String).Trim()
    if (-not $json) { return $null }
    try { $data = ($json | ConvertFrom-Json).data } catch { return $null }
    foreach ($w in $data.windows) { if ($w.target -eq $target) { return $w } }
    return $null
}

function Wait-Win($target) {
    for ($t = 0; $t -lt 50; $t++) {
        $w = Get-Win $target
        if ($w) { return $w }
        Start-Sleep -Milliseconds 200
    }
    return $null
}

function Read-Text($path) {
    if (Test-Path $path) { return [string](Get-Content $path -Raw -ErrorAction SilentlyContinue) }
    return ''
}

function Wait-Log($path, $pattern, $timeoutMs) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $timeoutMs) {
        if ((Read-Text $path) -match $pattern) { return $true }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

function Count-Log($path, $pattern) {
    return ([regex]::Matches((Read-Text $path), $pattern)).Count
}

function Wait-Capture($target) {
    for ($t = 0; $t -lt 40; $t++) {
        $shot = Get-TestPaneCapture -Target $target
        if ($shot) { return $shot }
        Start-Sleep -Milliseconds 250
    }
    return $null
}

# Text in the pane, read through the renderer's own target.
function Test-DrawsText($target) {
    $shot = Wait-Capture $target
    if (-not $shot) { return $false }
    $colors = Get-TestPaneColorCount -Shot $shot
    Close-TestPaneCapture $shot
    return ($colors -ge 8)
}

$onLine = 'pane presents through a composition swap chain'
$failLine = 'composition present failed'
$unavailLine = 'composition present unavailable'

function Start-Arm($name, [string[]]$Extra = @()) {
    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)
    $dir = Join-Path $root $name
    New-Item -ItemType Directory -Force $dir | Out-Null
    $env:LOCALAPPDATA = $dir
    $err = Join-Path $dir 'stderr.txt'
    $app = Start-OnTestDesktop -Exe $Exe -Arguments (@(
        '--config-default-files=false', '--session-persistence=false',
        "--title=t2466-$name") + $Extra) -StdErr $err
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow' -TimeoutMs 30000
    & $Exe +new-window "--target=comp$name" | Out-Null
    $win = Wait-Win "comp$name"
    return [pscustomobject]@{ App = $app; Err = $err; Top = $top; Win = $win; Target = "comp$name" }
}

function Test-Alive($arm) { return ($arm.App.Process -and -not $arm.App.Process.HasExited) }

try {
    # ========================================================================
    "== A: with the knob on, panes present through the composition swap chain"
    # ========================================================================
    Set-Knobs '1' $null $null
    $a = Start-Arm 'a'
    Assert "A0 the arm's window came up" ($a.Top -ne [IntPtr]::Zero -and $null -ne $a.Win)
    Assert "A1 the first pane built its chain" (Wait-Log $a.Err $onLine 15000)

    & $Exe +split "--target=$($a.Target)" '--direction=right' '--name=compa2' 2>$null | Out-Null
    $two = $false
    for ($t = 0; $t -lt 50 -and -not $two; $t++) {
        $two = (Count-Log $a.Err $onLine) -ge 2
        if (-not $two) { Start-Sleep -Milliseconds 200 }
    }
    Assert "A2 the split pane built its own chain ($(Count-Log $a.Err $onLine) lines)" $two

    for ($i = 0; $i -lt 3; $i++) {
        & $Exe +send-keys "--target=$($a.Target)" "echo comp-present-t2466-$i" Enter 2>$null | Out-Null
        & $Exe +send-keys '--target=compa2' "dir" Enter 2>$null | Out-Null
        Start-Sleep -Milliseconds 300
    }
    # A resize reaches ResizeBuffers and a new shared texture on both panes.
    if ($a.Top -ne [IntPtr]::Zero) {
        [void](Set-TestWindowSize -Window $a.Top -Width 1100 -Height 700)
        Start-Sleep -Milliseconds 600
        [void](Set-TestWindowSize -Window $a.Top -Width 800 -Height 520)
        Start-Sleep -Milliseconds 600
    }
    & $Exe +send-keys "--target=$($a.Target)" 'echo after-resize' Enter 2>$null | Out-Null
    Start-Sleep -Milliseconds 800

    Assert "A3 the app is still running" (Test-Alive $a)
    Assert "A4 no pane fell back or failed to build" `
        ((Count-Log $a.Err $failLine) -eq 0 -and (Count-Log $a.Err $unavailLine) -eq 0)
    Assert "A5 the first pane still draws text" (Test-DrawsText $a.Target)
    Assert "A6 the split pane still draws text" (Test-DrawsText 'compa2')
    Assert "A7 no OpenGL errors were raised" ((Read-Text $a.Err) -notmatch 'error\(opengl\)')
    Assert "A8 and no draw failed" ((Read-Text $a.Err) -notmatch 'error drawing err=')

    # ========================================================================
    "== B: a failed present falls back to SwapBuffers and the pane keeps drawing"
    # ========================================================================
    Set-Knobs '1' '5' $null
    $b = Start-Arm 'b'
    Assert "B0 the arm's window came up" ($b.Top -ne [IntPtr]::Zero -and $null -ne $b.Win)
    Assert "B1 the pane built its chain" (Wait-Log $b.Err $onLine 15000)
    for ($i = 0; $i -lt 4; $i++) {
        & $Exe +send-keys "--target=$($b.Target)" "echo fallback-$i" Enter 2>$null | Out-Null
        Start-Sleep -Milliseconds 250
    }
    Assert "B2 the simulated failure was reported as a fallback" `
        (Wait-Log $b.Err 'composition present failed \(error\.ComFailed\) at simulated' 15000)
    & $Exe +send-keys "--target=$($b.Target)" 'echo drawn-by-swapbuffers' Enter 2>$null | Out-Null
    Start-Sleep -Milliseconds 800
    Assert "B3 the app is still running" (Test-Alive $b)
    Assert "B4 the pane draws text after the fallback" (Test-DrawsText $b.Target)
    # The arm has two panes (its startup window and the +new-window one), and
    # each fails its own 6th present - so one line per pane, never one per
    # frame. Which of them reaches 6 frames first is timing (1 or 2 lines).
    $nb = Count-Log $b.Err $failLine
    Assert "B5 the fallback happened once per pane, not per frame ($nb lines)" ($nb -ge 1 -and $nb -le 2)

    # ========================================================================
    "== C: a lost device on the composition path rebuilds its chain"
    # ========================================================================
    Set-Knobs '1' $null '20'
    $c = Start-Arm 'c'
    Assert "C0 the arm's window came up" ($c.Top -ne [IntPtr]::Zero -and $null -ne $c.Win)
    for ($i = 0; $i -lt 8; $i++) {
        & $Exe +send-keys "--target=$($c.Target)" "echo lost-$i" Enter 2>$null | Out-Null
        Start-Sleep -Milliseconds 200
    }
    Assert "C1 the simulated loss was detected" (Wait-Log $c.Err 'graphics device lost \(simulated' 20000)
    Assert "C2 the device was rebuilt" (Wait-Log $c.Err 'graphics device rebuilt after' 20000)
    & $Exe +send-keys "--target=$($c.Target)" 'echo after-rebuild' Enter 2>$null | Out-Null
    $again = $false
    for ($t = 0; $t -lt 50 -and -not $again; $t++) {
        $again = (Count-Log $c.Err $onLine) -ge 2
        if (-not $again) { Start-Sleep -Milliseconds 200 }
    }
    Assert "C3 the rebuilt context built its chain again" $again
    Assert "C4 the app is still running" (Test-Alive $c)
    Assert "C5 the rebuilt pane draws text" (Test-DrawsText $c.Target)
    Assert "C6 nothing fell back" ((Count-Log $c.Err $failLine) -eq 0)

    # ========================================================================
    "== D: negative control - with the knob off, nothing takes the new path"
    # ========================================================================
    Set-Knobs $null $null $null
    $d = Start-Arm 'd'
    Assert "D0 the arm's window came up" ($d.Top -ne [IntPtr]::Zero -and $null -ne $d.Win)
    & $Exe +send-keys "--target=$($d.Target)" 'echo plain-wgl' Enter 2>$null | Out-Null
    Start-Sleep -Milliseconds 1200
    Assert "D1 the pane draws text" (Test-DrawsText $d.Target)
    $text = Read-Text $d.Err
    Assert "D2 and no composition line was logged" `
        ($text -notmatch $onLine -and $text -notmatch $failLine -and $text -notmatch $unavailLine)
    $dBars = @(Get-TestWindows -ProcessId $d.App.Pid -Class 'GhozttyScrollbar')
    Assert "D3 the knob-off scrollbar is its popup ($($dBars.Count) visible, no visual line)" `
        ($dBars.Count -ge 1 -and $text -notmatch 'scrollbar path visual=true')

    # ========================================================================
    "== E: the bell border is a child visual of the pane, not a popup (T2467)"
    # ========================================================================
    Set-Knobs '1' $null $null
    $e = Start-Arm 'e' @('--command=powershell.exe -NoLogo', '--bell-features=border,title')
    Assert "E0 the arm's window came up" ($e.Top -ne [IntPtr]::Zero -and $null -ne $e.Win)
    Assert "E1 the pane published its overlay tree" (Wait-Log $e.Err 'pane overlay tree published' 15000)
    & $Exe +split "--target=$($e.Target)" '--direction=right' '--name=compe2' '--shell=powershell' 2>$null | Out-Null
    $two = $false
    for ($t = 0; $t -lt 50 -and -not $two; $t++) {
        $two = (Count-Log $e.Err 'pane overlay tree published') -ge 2
        if (-not $two) { Start-Sleep -Milliseconds 200 }
    }
    Assert "E2 the split pane published its tree too" $two
    $shown = $false
    for ($i = 0; $i -lt 6 -and -not $shown; $i++) {
        # The pane's powershell evaluates [char]7 and echoes the BEL.
        & $Exe +send-keys '--target=compe2' '[char]7' Enter 2>$null | Out-Null
        $shown = Wait-Log $e.Err 'bell border shown as visual px=\d+' 2500
    }
    Assert "E3 a BEL put the bell border up as a visual (log)" $shown
    Assert "E4 the fade-in finished at full opacity (log)" (Wait-Log $e.Err 'bell border fade done alpha=255' 3000)
    # T2469: the visual path declares the whole fade to the compositor once
    # and never steps it on the UI thread.
    Assert "E4a the fade-in was declared to the compositor (log)" (Wait-Log $e.Err 'bell border fade on compositor from=0 to=255' 500)
    Assert "E4b ... and took no UI-thread steps (log)" (Wait-Log $e.Err 'bell border fade done alpha=255 ms=\d+ compositor=true ui_steps=0' 500)
    # The split went into the arm's +new-window window, not the startup one:
    # the window to move and key into is the one holding both panes.
    $eTop = [IntPtr]::Zero
    foreach ($w in @(Get-TestWindows -ProcessId $e.App.Pid -Class 'GhozttyWindow')) {
        $n = @(Get-TestChildWindows -Window ([IntPtr]$w.Hwnd) -Class 'GhozttyTerminal' | Where-Object Visible).Count
        if ($n -ge 2) { $eTop = [IntPtr]$w.Hwnd }
    }
    Assert "E5a found the two-pane window" ($eTop -ne [IntPtr]::Zero)
    $borders = @(Get-TestWindows -ProcessId $e.App.Pid -Class 'GhozttyBellBorder')
    Assert "E5 no bell border popup is visible ($($borders.Count))" ($borders.Count -eq 0)
    $wr = Get-TestWindowRect -Window $eTop
    [void](Set-TestWindowPos -Window $eTop -X ($wr.Left + 70) -Y ($wr.Top + 40))
    Start-Sleep -Milliseconds 800
    $borders = @(Get-TestWindows -ProcessId $e.App.Pid -Class 'GhozttyBellBorder')
    Assert "E6 after a window move still no popup, and the frame was never re-shown" `
        ($borders.Count -eq 0 -and (Count-Log $e.Err 'bell border shown') -eq 1)
    $pane = @(Get-TestChildWindows -Window $eTop -Class 'GhozttyTerminal' | Where-Object Visible | Sort-Object Left, Top)[1]
    if ($pane) { [void](Send-TestControlKey -Control ([IntPtr]$pane.Hwnd) -Key 'Right') }
    $off = (Wait-Log $e.Err 'bell border hidden visual=true' 4000) -and (Wait-Log $e.Err 'bell border fade done alpha=0' 500)
    Assert "E7 a key in the pane faded the frame out and took it off (log)" $off
    Assert "E7a the fade-out ran on the compositor too, no UI-thread steps (log)" `
        (Wait-Log $e.Err 'bell border fade done alpha=0 ms=\d+ compositor=true ui_steps=0' 500)
    if (-not $off) {
        "    pane=$(if ($pane) { $pane.Hwnd } else { '<none>' }); bell lines:"
        (Read-Text $e.Err) -split "`n" | Where-Object { $_ -match 'bell|overlay' } | Select-Object -Last 12 | ForEach-Object { "      $_" }
    }
    Assert "E8 the app is still running, nothing fell back" ((Test-Alive $e) -and (Count-Log $e.Err $failLine) -eq 0)
    Assert "E9 the rung pane still draws text" (Test-DrawsText 'compe2')

    # ========================================================================
    "== F: the unfocused dim is a child visual of the pane, not a popup (T2491)"
    # ========================================================================
    Set-Knobs '1' $null $null
    # A solid pane: a glass one (the default) never dims (T2281).
    $f = Start-Arm 'f' @('--macos-pane-glass=false')
    Assert "F0 the arm's window came up" ($f.Top -ne [IntPtr]::Zero -and $null -ne $f.Win)
    & $Exe +split "--target=$($f.Target)" '--direction=right' '--name=compf2' 2>$null | Out-Null
    $dimUp = Wait-Log $f.Err 'dim overlay shown as visual alpha=\d+' 15000
    Assert "F1 the unfocused pane's dim went up as a visual (log)" $dimUp
    if (-not $dimUp) {
        "    dim lines:"
        (Read-Text $f.Err) -split "`n" | Where-Object { $_ -match 'dim|overlay tree|composition' } | Select-Object -Last 12 | ForEach-Object { "      $_" }
    }
    $fTop = [IntPtr]::Zero
    foreach ($w in @(Get-TestWindows -ProcessId $f.App.Pid -Class 'GhozttyWindow')) {
        $n = @(Get-TestChildWindows -Window ([IntPtr]$w.Hwnd) -Class 'GhozttyTerminal' | Where-Object Visible).Count
        if ($n -ge 2) { $fTop = [IntPtr]$w.Hwnd }
    }
    Assert "F2a found the two-pane window" ($fTop -ne [IntPtr]::Zero)
    $washes = @(Get-TestWindows -ProcessId $f.App.Pid -Class 'GhozttyDimOverlay')
    Assert "F2 no dim popup is visible ($($washes.Count))" ($washes.Count -eq 0)
    $shownBefore = Count-Log $f.Err 'dim overlay shown as visual'
    $wr = Get-TestWindowRect -Window $fTop
    [void](Set-TestWindowPos -Window $fTop -X ($wr.Left + 60) -Y ($wr.Top + 30))
    Start-Sleep -Milliseconds 500
    [void](Set-TestWindowSize -Window $fTop -Width 1000 -Height 640)
    Start-Sleep -Milliseconds 800
    $washes = @(Get-TestWindows -ProcessId $f.App.Pid -Class 'GhozttyDimOverlay')
    $shownAfter = Count-Log $f.Err 'dim overlay shown as visual'
    Assert "F3 a move and a resize show no popup and re-show nothing ($shownBefore -> $shownAfter, $($washes.Count) popups)" `
        ($washes.Count -eq 0 -and $shownAfter -eq $shownBefore)
    # A banner sends the dimmed pane's wash back to the popup: it has to reach
    # up over the band, outside the pane window (T2308). Both panes carry one,
    # so whichever is unfocused is the one asserted.
    & $Exe +set-banner "--target=$($f.Target)" 'banner over the dim' 2>$null | Out-Null
    & $Exe +set-banner '--target=compf2' 'banner over the dim' 2>$null | Out-Null
    $popup = $false
    for ($t = 0; $t -lt 25 -and -not $popup; $t++) {
        $popup = @(Get-TestWindows -ProcessId $f.App.Pid -Class 'GhozttyDimOverlay').Count -eq 1
        if (-not $popup) { Start-Sleep -Milliseconds 200 }
    }
    Assert "F4 with a banner the wash is the popup again (log + one visible popup)" `
        ($popup -and (Count-Log $f.Err 'dim overlay path visual=false') -ge 1)
    Assert "F5 the app is still running, nothing fell back" ((Test-Alive $f) -and (Count-Log $f.Err $failLine) -eq 0)
    Assert "F6 the dimmed panes still draw text" ((Test-DrawsText $f.Target) -and (Test-DrawsText 'compf2'))

    # ========================================================================
    "== G: the scrollbar is a child visual of the pane, not a popup (T2492)"
    # ========================================================================
    Set-Knobs '1' $null $null
    $g = Start-Arm 'g' @('--command=powershell.exe -NoLogo')
    Assert "G0 the arm's window came up" ($g.Top -ne [IntPtr]::Zero -and $null -ne $g.Win)
    & $Exe +split "--target=$($g.Target)" '--direction=right' '--name=compg2' '--shell=powershell' 2>$null | Out-Null
    # Three panes: the startup window's, the +new-window one and its split.
    $three = $false
    for ($t = 0; $t -lt 50 -and -not $three; $t++) {
        $three = (Count-Log $g.Err 'scrollbar shown as visual') -ge 3
        if (-not $three) { Start-Sleep -Milliseconds 200 }
    }
    Assert "G1 every pane's scrollbar went up as a visual ($(Count-Log $g.Err 'scrollbar shown as visual') lines)" $three
    $gTop = [IntPtr]::Zero
    foreach ($w in @(Get-TestWindows -ProcessId $g.App.Pid -Class 'GhozttyWindow')) {
        $n = @(Get-TestChildWindows -Window ([IntPtr]$w.Hwnd) -Class 'GhozttyTerminal' | Where-Object Visible).Count
        if ($n -ge 2) { $gTop = [IntPtr]$w.Hwnd }
    }
    Assert "G2a found the two-pane window" ($gTop -ne [IntPtr]::Zero)
    $bars = @(Get-TestWindows -ProcessId $g.App.Pid -Class 'GhozttyScrollbar')
    Assert "G2 no scrollbar popup is visible ($($bars.Count))" ($bars.Count -eq 0)
    # Scrollback in the right pane: powershell prints the range, one per row.
    & $Exe +send-keys '--target=compg2' '1..400' Enter 2>$null | Out-Null
    Start-Sleep -Milliseconds 1500
    $shownBefore = Count-Log $g.Err 'scrollbar shown as visual'
    if ($gTop -ne [IntPtr]::Zero) {
        $wr = Get-TestWindowRect -Window $gTop
        [void](Set-TestWindowPos -Window $gTop -X ($wr.Left + 50) -Y ($wr.Top + 30))
        Start-Sleep -Milliseconds 800
    }
    $bars = @(Get-TestWindows -ProcessId $g.App.Pid -Class 'GhozttyScrollbar')
    $shownAfter = Count-Log $g.Err 'scrollbar shown as visual'
    Assert "G3 a move shows no popup and re-shows nothing ($shownBefore -> $shownAfter, $($bars.Count) popups)" `
        ($bars.Count -eq 0 -and $shownAfter -eq $shownBefore)
    # The thumb sits at the bottom of the strip (the view follows the output)
    # and is lit for a second after output, so each try prints, then presses
    # it on the PANE window and drags it to the top.
    $pane = $null
    if ($gTop -ne [IntPtr]::Zero) {
        $pane = @(Get-TestChildWindows -Window $gTop -Class 'GhozttyTerminal' | Where-Object Visible | Sort-Object Left, Top)[1]
    }
    $dragged = $false
    for ($i = 0; $i -lt 4 -and $pane -and -not $dragged; $i++) {
        & $Exe +send-keys '--target=compg2' '1..60' Enter 2>$null | Out-Null
        Start-Sleep -Milliseconds 350
        $x = $pane.Right - 3
        [void](Send-TestMouse -Window $gTop -Target ([IntPtr]$pane.Hwnd) -X $x -Y ($pane.Bottom - 4) -Action down -Client)
        [void](Send-TestMouse -Window $gTop -Target ([IntPtr]$pane.Hwnd) -X $x -Y ($pane.Top + ($pane.Height / 2)) -Action move -Client)
        [void](Send-TestMouse -Window $gTop -Target ([IntPtr]$pane.Hwnd) -X $x -Y ($pane.Top - 200) -Action move -Client)
        [void](Send-TestMouse -Window $gTop -Target ([IntPtr]$pane.Hwnd) -X $x -Y ($pane.Top - 200) -Action up -Client)
        $dragged = Wait-Log $g.Err 'scrollbar drag end visual=true offset=0\b' 1500
    }
    Assert "G4 a press on the thumb, on the pane window, dragged the view to the top (log)" $dragged
    if (-not $dragged) {
        "    scrollbar lines:"
        (Read-Text $g.Err) -split "`n" | Where-Object { $_ -match 'scrollbar|overlay tree' } | Select-Object -Last 12 | ForEach-Object { "      $_" }
    }
    $starts = Count-Log $g.Err 'scrollbar drag start'
    if ($pane) {
        [void](Send-TestMouse -Window $gTop -Target ([IntPtr]$pane.Hwnd) -X ($pane.Left + 40) -Y ($pane.Top + 40) -Client)
        Start-Sleep -Milliseconds 400
    }
    Assert "G5 a click in the grid is the terminal's, not a scrollbar drag" ($pane -and (Count-Log $g.Err 'scrollbar drag start') -eq $starts)
    Assert "G6 the app is still running, nothing fell back" ((Test-Alive $g) -and (Count-Log $g.Err $failLine) -eq 0)
    Assert "G7 the scrolled pane still draws text" (Test-DrawsText 'compg2')

    # ========================================================================
    "== H: a banner pane's window spans its band; the grid is the same (T2566)"
    # ========================================================================
    $bandLine = 'pane grid band=(\d+) client=(\d+)x(\d+) grid=(\d+)'
    # One arm per knob, same window size and banner; returns the pane rect,
    # the strip's rect and the arm's log.
    function Measure-BannerArm($name, $comp) {
        Set-Knobs $comp $null $null
        $arm = Start-Arm $name
        # Every window of the arm at one size, so the two arms compare.
        foreach ($w in @(Get-TestWindows -ProcessId $arm.App.Pid -Class 'GhozttyWindow')) {
            [void](Set-TestWindowSize -Window ([IntPtr]$w.Hwnd) -Width 900 -Height 620)
        }
        Start-Sleep -Milliseconds 600
        & $Exe +set-banner "--target=$($arm.Target)" 'band spans the window' 2>$null | Out-Null
        $pane = $null; $strip = $null
        for ($t = 0; $t -lt 30 -and -not $strip; $t++) {
            Start-Sleep -Milliseconds 200
            foreach ($tw in @(Get-TestWindows -ProcessId $arm.App.Pid -Class 'GhozttyWindow')) {
                foreach ($p in @(Get-TestChildWindows -Window ([IntPtr]$tw.Hwnd) -Class 'GhozttyTerminal' | Where-Object Visible)) {
                    foreach ($o in @(Get-TestWindows -ProcessId $arm.App.Pid -Class 'GhozttyBannerOverlay' | Where-Object Visible)) {
                        if ([math]::Abs($o.Left - $p.Left) -le 2 -and ([math]::Abs($o.Top - $p.Top) -le 2 -or [math]::Abs($o.Bottom - $p.Top) -le 2)) {
                            $pane = $p; $strip = $o
                        }
                    }
                }
            }
        }
        Start-Sleep -Milliseconds 600
        return [pscustomobject]@{ Arm = $arm; Pane = $pane; Strip = $strip }
    }
    $h = Measure-BannerArm 'h' '1'
    Assert "H0 the knob-on arm has a banner pane" ($null -ne $h.Pane -and $null -ne $h.Strip)
    Assert "H1 the strip is glued over the pane window's top, not above it" `
        ($h.Pane -and [math]::Abs($h.Strip.Top - $h.Pane.Top) -le 2)
    $last = [regex]::Matches((Read-Text $h.Arm.Err), $bandLine) | Select-Object -Last 1
    $hBand = if ($last) { [int]$last.Groups[1].Value } else { -1 }
    $hClient = if ($last) { [int]$last.Groups[3].Value } else { -1 }
    $hGrid = if ($last) { [int]$last.Groups[4].Value } else { -1 }
    Assert "H2 the grid is the window less the band (band=$hBand client=$hClient grid=$hGrid pane=$($h.Pane.Height))" `
        ($last -and $hGrid -eq ($hClient - $hBand) -and $h.Pane -and $hClient -eq $h.Pane.Height)
    Assert "H3 the band is the strip's height (band=$hBand strip=$($h.Strip.Height))" `
        ($h.Strip -and [math]::Abs($hBand - $h.Strip.Height) -le 1)
    Assert "H4 the app is still running, nothing fell back, the pane still draws" `
        ((Test-Alive $h.Arm) -and (Count-Log $h.Arm.Err $failLine) -eq 0 -and (Test-DrawsText $h.Arm.Target))
    & $Exe +set-banner "--target=$($h.Arm.Target)" --clear 2>$null | Out-Null
    $back = (Wait-Log $h.Arm.Err 'pane grid band settled band=0\b' 5000)
    $p5 = $null
    if ($back) {
        Start-Sleep -Milliseconds 400
        foreach ($tw in @(Get-TestWindows -ProcessId $h.Arm.App.Pid -Class 'GhozttyWindow')) {
            foreach ($p in @(Get-TestChildWindows -Window ([IntPtr]$tw.Hwnd) -Class 'GhozttyTerminal' | Where-Object Visible)) {
                if ([math]::Abs($p.Left - $h.Pane.Left) -le 2 -and [math]::Abs($p.Top - $h.Pane.Top) -le 2) { $p5 = $p }
            }
        }
    }
    Assert "H5 clearing the banner gives the band back to the grid, the window unmoved (log + pane at the same rect)" `
        ($back -and $p5 -and $p5.Height -eq $h.Pane.Height)
    $h0 = Measure-BannerArm 'h0' $null
    Assert "H6 negative control: knob off, the pane window starts below the strip" `
        ($h0.Pane -and $h0.Strip -and [math]::Abs($h0.Strip.Bottom - $h0.Pane.Top) -le 2)
    Assert "H7 the knob-off window is the knob-on grid: same rows (off=$($h0.Pane.Height) on=$hGrid)" `
        ($h0.Pane -and $hGrid -gt 0 -and $h0.Pane.Height -eq $hGrid)
    Assert "H8 knob off never carves a band" ((Count-Log $h0.Arm.Err 'pane grid band=') -eq 0)

    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)

    # LAST statement of the top-level try (T1039).
    Complete-TestBody
} finally {
    foreach ($k in $knobs) {
        if ($saved[$k]) { Set-Item "env:$k" $saved[$k] }
        else { Remove-Item "env:$k" -ErrorAction SilentlyContinue }
    }
    $env:LOCALAPPDATA = $savedLocalAppData
    Remove-TestDesktop
    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)
    Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
}

# --- stamp (T783) ----------------------------------------------------------
if ($script:failures -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot '..\..\scripts\guard-due.ps1') `
        update -Guard comp-present -Repo (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path 2>&1 |
        ForEach-Object { Write-Host "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:passes -Fail $script:failures -Label 'comp-present' -MinPass 66
