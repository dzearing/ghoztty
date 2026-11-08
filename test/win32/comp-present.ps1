# Composition swap-chain presentation acceptance (tracker T2466, T2360 step 2).
#
# THE CHANGE: a terminal pane can present through a DXGI flip-model swap chain
# that is the content of a DirectComposition visual on the pane's window,
# instead of WGL SwapBuffers into the window's redirection bitmap
# (src/renderer/gl_comp_present.zig). GHOZTTY_COMP_PRESENT=1 asks for it and
# =0 refuses it; with neither, `default_on` decides (on since T2514). Arms A
# and L run with NO knob, so they measure the default itself; the rest name
# theirs explicitly: "knob on" is 1, "knob off" is 0.
#
# THE CONTRACT this asserts:
#
#   A. With no knob set (the default since T2514), every pane builds the chain
#      (GL/D3D interop, swap chain, DComp target on the pane window) and keeps
#      presenting through it: two panes, output, a resize, and no failure or
#      fallback line. The panes still draw text (capture-pane reads the
#      renderer's own target).
#   B. A present that fails falls back to SwapBuffers for that pane, and the
#      pane keeps drawing - the debug-only seam
#      GHOZTTY_COMP_PRESENT_FAIL_AFTER=<n> fails the n+1th present.
#   C. A lost GL device on the composition path is rebuilt, and the rebuilt
#      context builds its chain again (T1690's seam).
#   D. The opt-out control (T2514): with GHOZTTY_COMP_PRESENT=0, no pane
#      touches the composition path, and the panes still draw (SwapBuffers).
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
#   I. On that banded pane, input measures from below the band (T2567): a
#      press and a drag-selection's end reach the core on the same cells as
#      the knob-off layout at the same screen points, the IME window and the
#      keyboard context menu sit exactly one band lower in the taller window
#      (the same screen point), and the menu is on screen where the log says.
#      I6 is the negative control: knob off, no input line carries a band.
#   J. On that banded pane, every overlay glued to the grid sits below the band
#      (T2568): the scrollbar, the bell border (both child visuals knob on, so
#      read from their log lines), the key-state pill, the read-only badge and
#      the unfocused dim (popups both ways) land on the same SCREEN rect as the
#      knob-off build's, while the pane window itself starts a band higher (J0,
#      so the comparison is not trivially equal). The search bar and command
#      palette are placed off the top-level window, not the pane, so the band
#      cannot reach them and they are not re-measured here. J7-J8: the banner
#      collapse glide (T2252) runs knob on as well, measured off the grid, and
#      lands the way the knob-off one does; knob on the copy is a visual at
#      the back of the pane's overlays, under the card's visual (J9, T2617).
#   K. The banner as a child visual of the pane (T2559): knob on, the card is
#      shown as a visual and no GhozttyBannerOverlay popup is ever visible, a
#      window move re-renders and re-shows nothing, and its input arrives on
#      the pane window: hovering a link lights it, a click on a single-line
#      card is the banner's (not a terminal press), a click on a multi-line
#      card toggles it, and a press in the grid is still the terminal's. K8
#      is the negative control: knob off, no card is ever a visual.
#   L. No interop, no knob (T2514): with the debug seam
#      GHOZTTY_COMP_PRESENT_SIMULATE_NO_INTEROP=1 standing in for Mesa, a
#      WARP-only GL or Remote Desktop, every pane logs `composition present
#      unavailable` at the interop stage, builds no chain, and draws through
#      SwapBuffers - a banner pane included, its strip a popup over the band.
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
$knobs = 'GHOZTTY_COMP_PRESENT', 'GHOZTTY_COMP_PRESENT_FAIL_AFTER', 'GHOZTTY_GL_SIMULATE_RESET_AFTER', 'GHOZTTY_COMP_PRESENT_SIMULATE_NO_INTEROP', 'GHOZTTY_PANE_GL_HELPER'
$saved = @{}
foreach ($k in $knobs) { $saved[$k] = [Environment]::GetEnvironmentVariable($k) }

function Set-Knobs($comp, $failAfter, $resetAfter) {
    $vals = @{ GHOZTTY_COMP_PRESENT = $comp; GHOZTTY_COMP_PRESENT_FAIL_AFTER = $failAfter; GHOZTTY_GL_SIMULATE_RESET_AFTER = $resetAfter }
    # Only the three it names: section L sets the no-interop seam around a call.
    foreach ($k in $vals.Keys) {
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
# T2788: a composition pane's GL context sits on a hidden helper, so its own
# window is never a GL drawable; a pane that falls back moves it back.
$helperLine = 'terminal pane context on a hidden helper'
$adoptLine = 'terminal pane context moved onto its own window for SwapBuffers'

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
    "== A: with no knob (the default since T2514), panes present through the composition swap chain"
    # ========================================================================
    Set-Knobs $null $null $null
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
        # argv-audit: output to draw, plain ASCII words with no quotes or metacharacters
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
    $nh = Count-Log $a.Err $helperLine
    Assert "A9 every pane's GL context is on a hidden helper, not its window (T2788: $nh of $(Count-Log $a.Err $onLine))" `
        ($nh -ge 2 -and $nh -eq (Count-Log $a.Err $onLine))

    # ========================================================================
    "== B: a failed present falls back to SwapBuffers and the pane keeps drawing"
    # ========================================================================
    Set-Knobs '1' '5' $null
    $b = Start-Arm 'b'
    Assert "B0 the arm's window came up" ($b.Top -ne [IntPtr]::Zero -and $null -ne $b.Win)
    Assert "B1 the pane built its chain" (Wait-Log $b.Err $onLine 15000)
    for ($i = 0; $i -lt 4; $i++) {
        # argv-audit: output to draw, plain ASCII words with no quotes or metacharacters
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
    # T2788: SwapBuffers needs the context on the pane's own window.
    $na = Count-Log $b.Err $adoptLine
    Assert "B6 each fallen-back pane moved its context onto its own window ($na of $nb)" ($na -eq $nb)
    Assert "B7 and no move failed" ((Read-Text $b.Err) -notmatch 'could not move the pane context')

    # ========================================================================
    "== C: a lost device on the composition path rebuilds its chain"
    # ========================================================================
    Set-Knobs '1' $null '20'
    $c = Start-Arm 'c'
    Assert "C0 the arm's window came up" ($c.Top -ne [IntPtr]::Zero -and $null -ne $c.Win)
    for ($i = 0; $i -lt 8; $i++) {
        # argv-audit: output to draw, plain ASCII words with no quotes or metacharacters
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
    "== D: the opt-out control - GHOZTTY_COMP_PRESENT=0 keeps every pane off the new path"
    # ========================================================================
    Set-Knobs '0' $null $null
    $d = Start-Arm 'd'
    Assert "D0 the arm's window came up" ($d.Top -ne [IntPtr]::Zero -and $null -ne $d.Win)
    & $Exe +send-keys "--target=$($d.Target)" 'echo plain-wgl' Enter 2>$null | Out-Null
    Start-Sleep -Milliseconds 1200
    Assert "D1 the pane draws text" (Test-DrawsText $d.Target)
    $text = Read-Text $d.Err
    Assert "D2 and no composition line was logged" `
        ($text -notmatch $onLine -and $text -notmatch $failLine -and $text -notmatch $unavailLine)
    Assert "D4 nor a helper context: a SwapBuffers pane draws on its own window (T2788)" ($text -notmatch $helperLine)
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
    $fAlive = Test-Alive $f
    $fFails = Count-Log $f.Err $failLine
    Assert "F5 the app is still running, nothing fell back (alive=$fAlive fallbacks=$fFails)" ($fAlive -and $fFails -eq 0)
    if (-not $fAlive -or $fFails -gt 0) {
        "    fallback/panic lines:"
        (Read-Text $f.Err) -split "`n" | Where-Object { $_ -match 'composition present|panic|error|banner path|banner shown' } | Select-Object -Last 12 | ForEach-Object { "      $_" }
    }
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
    # T2761: the output lit the thumb and the idle second faded it out again,
    # each as one ramp declared to the compositor, with no UI-thread steps.
    Assert "G1a the scrollbar's fade-in was declared to the compositor (log)" `
        (Wait-Log $g.Err 'scrollbar fade on compositor from=0 to=255 ms=128' 1500)
    Assert "G1b ... and ended without a UI-thread step (log)" `
        (Wait-Log $g.Err 'scrollbar fade done fade=255 ms=\d+ compositor=true ui_steps=0' 1500)
    Assert "G1c the idle fade-out ran on the compositor too (log)" `
        (Wait-Log $g.Err 'scrollbar fade done fade=0 ms=\d+ compositor=true ui_steps=0' 3000)
    Assert "G1d no visual-path fade was stepped ($(Count-Log $g.Err 'scrollbar fade done fade=\d+ ms=\d+ compositor=false') stepped)" `
        ((Count-Log $g.Err 'scrollbar fade done fade=\d+ ms=\d+ compositor=false') -eq 0)
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
    $visualLine = 'banner shown as visual w=(\d+) h=(\d+)'
    # One arm per knob, same window size and banner; returns the pane rect,
    # the strip's rect and the arm's log.
    function Measure-BannerArm($name, $comp, [string[]]$Extra = @()) {
        Set-Knobs $comp $null $null
        $arm = Start-Arm $name $Extra
        # Every window of the arm at one size, so the two arms compare.
        foreach ($w in @(Get-TestWindows -ProcessId $arm.App.Pid -Class 'GhozttyWindow')) {
            [void](Set-TestWindowSize -Window ([IntPtr]$w.Hwnd) -Width 900 -Height 620)
        }
        Start-Sleep -Milliseconds 600
        & $Exe +set-banner "--target=$($arm.Target)" 'band spans the window' 2>$null | Out-Null
        $pane = $null; $strip = $null; $paneTop = [IntPtr]::Zero
        for ($t = 0; $t -lt 30 -and -not $strip; $t++) {
            Start-Sleep -Milliseconds 200
            # Knob on, the card is a visual at the top of the pane (T2559):
            # its rect is the pane's top-left at the size the visual logged.
            $vis = if ($comp -ne '0') { [regex]::Matches((Read-Text $arm.Err), $visualLine) | Select-Object -Last 1 } else { $null }
            foreach ($tw in @(Get-TestWindows -ProcessId $arm.App.Pid -Class 'GhozttyWindow')) {
                foreach ($p in @(Get-TestChildWindows -Window ([IntPtr]$tw.Hwnd) -Class 'GhozttyTerminal' | Where-Object Visible)) {
                    if ($vis) {
                        $vw = [int]$vis.Groups[1].Value; $vh = [int]$vis.Groups[2].Value
                        $pane = $p; $paneTop = [IntPtr]$tw.Hwnd
                        $strip = [pscustomobject]@{ Hwnd = $p.Hwnd; Left = $p.Left; Top = $p.Top; Width = $vw; Height = $vh
                            Right = $p.Left + $vw; Bottom = $p.Top + $vh; Visual = $true }
                        continue
                    }
                    foreach ($o in @(Get-TestWindows -ProcessId $arm.App.Pid -Class 'GhozttyBannerOverlay' | Where-Object Visible)) {
                        if ([math]::Abs($o.Left - $p.Left) -le 2 -and ([math]::Abs($o.Top - $p.Top) -le 2 -or [math]::Abs($o.Bottom - $p.Top) -le 2)) {
                            $pane = $p; $strip = $o; $paneTop = [IntPtr]$tw.Hwnd
                        }
                    }
                }
            }
        }
        Start-Sleep -Milliseconds 600
        return [pscustomobject]@{ Arm = $arm; Pane = $pane; Strip = $strip; Top = $paneTop }
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
    $h0 = Measure-BannerArm 'h0' '0'
    Assert "H6 negative control: knob off, the pane window starts below the strip" `
        ($h0.Pane -and $h0.Strip -and [math]::Abs($h0.Strip.Bottom - $h0.Pane.Top) -le 2)
    Assert "H7 the knob-off window is the knob-on grid: same rows (off=$($h0.Pane.Height) on=$hGrid)" `
        ($h0.Pane -and $hGrid -gt 0 -and $h0.Pane.Height -eq $hGrid)
    Assert "H8 knob off never carves a band" ((Count-Log $h0.Arm.Err 'pane grid band=') -eq 0)

    # ========================================================================
    "== I: on a banded pane, input measures from below the band (T2567)"
    # ========================================================================
    # Each arm takes the same input at the same SCREEN points, measured off
    # the strip's bottom (the grid's top in both layouts), and the app logs
    # the cell the core resolved. Knob on, the window starts a band higher,
    # so only a band-aware decode lands on the knob-off cells.
    function Last-Match($path, $pattern) {
        return [regex]::Matches((Read-Text $path), $pattern) | Select-Object -Last 1
    }
    function Probe-Input($m) {
        $r = [ordered]@{ Press = $null; Release = $null; Ime = $null; Menu = $null; MenuRect = $null }
        if (-not $m.Pane -or -not $m.Strip -or $m.Top -eq [IntPtr]::Zero) { return [pscustomobject]$r }
        $hw = [IntPtr]$m.Pane.Hwnd
        $x1 = $m.Strip.Left + 60; $y1 = $m.Strip.Bottom + 25
        $x2 = $m.Strip.Left + 300; $y2 = $m.Strip.Bottom + 110
        # A press, a drag and a release: the selection's two ends.
        [void](Send-TestMouse -Window $m.Top -Target $hw -X $x1 -Y $y1 -Action down -Client)
        [void](Send-TestMouse -Window $m.Top -Target $hw -X $x2 -Y $y2 -Action move -Client)
        [void](Send-TestMouse -Window $m.Top -Target $hw -X $x2 -Y $y2 -Action up -Client)
        [void](Wait-Log $m.Arm.Err 'pane mouse left release cell=' 3000)
        $p = Last-Match $m.Arm.Err 'pane mouse left press cell=(-?\d+),(-?\d+)'
        $q = Last-Match $m.Arm.Err 'pane mouse left release cell=(-?\d+),(-?\d+)'
        if ($p) { $r.Press = "$($p.Groups[1].Value),$($p.Groups[2].Value)" }
        if ($q) { $r.Release = "$($q.Groups[1].Value),$($q.Groups[2].Value)" }
        # The IME window: a composition start positions it at the cursor.
        [void](Send-TestRawMessage -Window $hw -Message 0x010D)
        [void](Wait-Log $m.Arm.Err 'pane ime point=' 3000)
        [void](Send-TestRawMessage -Window $hw -Message 0x010E)
        $i = Last-Match $m.Arm.Err 'pane ime point=(-?\d+),(-?\d+)'
        if ($i) { $r.Ime = @([int]$i.Groups[1].Value, [int]$i.Groups[2].Value) }
        # The keyboard context menu (VK_APPS shape), at the grid's centre.
        [void](Send-TestRawMessage -Window $hw -Message 0x007B -WParam $hw -LParam ([IntPtr](-1)))
        $menu = Wait-TestPopupMenu -ProcessId $m.Arm.App.Pid -TimeoutMs 3000
        $k = Last-Match $m.Arm.Err 'pane keyboard menu client=(-?\d+),(-?\d+)'
        if ($k) { $r.Menu = @([int]$k.Groups[1].Value, [int]$k.Groups[2].Value) }
        if ($menu -ne [IntPtr]::Zero) {
            $r.MenuRect = Get-TestWindowRect -Window $menu
            [void](Invoke-TestMessage -Window $hw -Message 0x001F) # WM_CANCELMODE
            Start-Sleep -Milliseconds 300
        }
        return [pscustomobject]$r
    }
    $i1 = Measure-BannerArm 'i' '1'
    $iBandM = Last-Match $i1.Arm.Err $bandLine
    $iBand = if ($iBandM) { [int]$iBandM.Groups[1].Value } else { -1 }
    $on = Probe-Input $i1
    $iPane = $i1.Pane
    $i0 = Measure-BannerArm 'i0' '0'
    $off = Probe-Input $i0
    Assert "I0 both arms are banded panes, knob on carries a band (band=$iBand)" `
        ($i1.Pane -and $i0.Pane -and $iBand -gt 0)
    Assert "I1 a press lands on the knob-off cell (on=$($on.Press) off=$($off.Press))" `
        ($on.Press -and $on.Press -eq $off.Press)
    Assert "I2 a drag-selection's end lands on the knob-off cell (on=$($on.Release) off=$($off.Release))" `
        ($on.Release -and $on.Release -eq $off.Release -and $on.Release -ne $on.Press)
    Assert "I3 the IME window sits at the cursor: the knob-off point, a band lower in the taller window (on=$($on.Ime -join ',') off=$($off.Ime -join ','))" `
        ($on.Ime -and $off.Ime -and $on.Ime[0] -eq $off.Ime[0] -and $on.Ime[1] -eq ($off.Ime[1] + $iBand))
    Assert "I4 the keyboard menu opens at the grid's centre, not the window's (on=$($on.Menu -join ',') off=$($off.Menu -join ','))" `
        ($on.Menu -and $off.Menu -and $on.Menu[0] -eq $off.Menu[0] -and $on.Menu[1] -eq ($off.Menu[1] + $iBand))
    Assert "I5 the knob-on menu is on screen where the log says (menu=$($on.MenuRect.Left),$($on.MenuRect.Top) pane=$($iPane.Left),$($iPane.Top))" `
        ($on.MenuRect -and $on.Menu -and [math]::Abs($on.MenuRect.Left - ($iPane.Left + $on.Menu[0])) -le 2 -and [math]::Abs($on.MenuRect.Top - ($iPane.Top + $on.Menu[1])) -le 2)
    Assert "I6 negative control: knob off, every input line reports band=0" `
        ((Count-Log $i0.Arm.Err 'pane (mouse|ime|keyboard menu) [^\r\n]*band=[1-9]') -eq 0 -and (Count-Log $i0.Arm.Err 'pane mouse left press') -gt 0)

    # ========================================================================
    "== J: on a banded pane, the overlays sit below the band (T2568)"
    # ========================================================================
    $jExtra = @('--command=powershell.exe -NoLogo', '--bell-features=border,title', '--macos-pane-glass=false',
        '--keybind=f7=activate_key_table:outer', '--keybind=outer/f8=deactivate_key_table',
        '--keybind=ctrl+shift+o=toggle_readonly')
    # The first visible popup of $class over the pane, as a screen rect.
    function Find-Over($m, $class, $timeoutMs) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($sw.ElapsedMilliseconds -lt $timeoutMs) {
            foreach ($o in @(Get-TestWindows -ProcessId $m.Arm.App.Pid -Class $class)) {
                if ($o.Left -ge $m.Pane.Left - 2 -and $o.Right -le $m.Pane.Right + 2 -and
                    $o.Top -ge $m.Strip.Top - 2 -and $o.Bottom -le $m.Pane.Bottom + 2) { return $o }
            }
            Start-Sleep -Milliseconds 150
        }
        return $null
    }
    function Rect-Text($r) { if ($r) { "$($r.Left),$($r.Top) $($r.Width)x$($r.Height)" } else { 'none' } }
    function Same-Rect($a, $b) {
        return ($a -and $b -and [math]::Abs($a.Left - $b.Left) -le 1 -and [math]::Abs($a.Top - $b.Top) -le 1 -and
            [math]::Abs($a.Width - $b.Width) -le 1 -and [math]::Abs($a.Height - $b.Height) -le 1)
    }
    # A screen rect measured from the slot's top-left (the banner strip's),
    # which is where the two arms' windows can be compared: each arm's window
    # opens wherever the desktop puts it.
    function Rel($rect, $o) {
        if (-not $rect -or -not $o) { return $null }
        return [pscustomobject]@{ Left = $rect.Left - $o.Left; Top = $rect.Top - $o.Top; Width = $rect.Width; Height = $rect.Height }
    }
    # Every grid overlay of one arm, as slot-relative rects. $visual: the
    # knob-on arm, whose scrollbar and bell border are child visuals of the
    # pane and are read from their log lines (pane-local, so offset by the
    # pane's rect).
    function Probe-Overlays($m, $visual) {
        $r = [ordered]@{ Scroll = $null; Bell = $null; Pill = $null; Badge = $null; Dim = $null; PaneTop = $null; Glide = $null; GlideEnd = $null; GlideCopy = $null; Toggled = $false }
        if (-not $m.Pane -or -not $m.Strip -or $m.Top -eq [IntPtr]::Zero) { return [pscustomobject]$r }
        $hw = [IntPtr]$m.Pane.Hwnd
        $p = $m.Pane
        $slot = $m.Strip
        $r.PaneTop = $p.Top - $slot.Top
        & $Exe +send-keys "--target=$($m.Arm.Target)" '1..80' Enter 2>$null | Out-Null
        Start-Sleep -Milliseconds 900
        # Scrollbar: the strip's top, height and right edge.
        if ($visual) {
            $s = Last-Match $m.Arm.Err 'scrollbar visual at=(-?\d+),(-?\d+) size=(\d+)x(\d+) band=(\d+)'
            if ($s) {
                $r.Scroll = [pscustomobject]@{ Left = $p.Left + [int]$s.Groups[1].Value
                    Top = $p.Top + [int]$s.Groups[5].Value + [int]$s.Groups[2].Value
                    Width = [int]$s.Groups[3].Value; Height = [int]$s.Groups[4].Value }
            }
        } else { $r.Scroll = Find-Over $m 'GhozttyScrollbar' 1500 }
        # Bell border: a BEL in the pane.
        & $Exe +send-keys "--target=$($m.Arm.Target)" '[char]7' Enter 2>$null | Out-Null
        if ($visual) {
            [void](Wait-Log $m.Arm.Err 'bell border shown as visual px=\d+ size=\d+x\d+ top=' 3000)
            $b = Last-Match $m.Arm.Err 'bell border shown as visual px=\d+ size=(\d+)x(\d+) top=(-?\d+)'
            if ($b) {
                $r.Bell = [pscustomobject]@{ Left = $p.Left; Top = $p.Top + [int]$b.Groups[3].Value
                    Width = [int]$b.Groups[1].Value; Height = [int]$b.Groups[2].Value }
            }
        } else { $r.Bell = Find-Over $m 'GhozttyBellBorder' 3000 }
        # Key-state pill: into a key table and out again.
        [void](Send-TestKeys -Window $m.Top -Target $hw -Key f7)
        $r.Pill = Find-Over $m 'GhozttyKeyState' 3000
        [void](Send-TestKeys -Window $m.Top -Target $hw -Key f8)
        Start-Sleep -Milliseconds 300
        # The collapse glide (T2252): a four-line card, a click on its first
        # line, and the frozen copy's measurements off the oracle line.
        & $Exe +set-banner "--target=$($m.Arm.Target)" 'glide1\nglide2\nglide3\nglide4' 2>$null | Out-Null
        Start-Sleep -Milliseconds 900
        # Knob on, the card is a visual: the click goes to the pane window.
        $card = if ($visual) { $slot } else {
            @(Get-TestWindows -ProcessId $m.Arm.App.Pid -Class 'GhozttyBannerOverlay') |
                Where-Object { [math]::Abs($_.Left - $slot.Left) -le 2 } | Select-Object -First 1 }
        if ($card) {
            [void](Send-TestMouse -Window $m.Top -Target ([IntPtr]$card.Hwnd) -X ($card.Left + [int]($card.Width / 2)) -Y ($card.Top + [int]($slot.Height / 2)) -Client:$visual)
            [void](Wait-Log $m.Arm.Err 'banner collapse h=' 3000)
            $r.Toggled = (Count-Log $m.Arm.Err 'banner collapse from=') -gt 0
            [void](Wait-Log $m.Arm.Err 'banner glide end reason=' 3000)
            $gb = Last-Match $m.Arm.Err 'banner glide begin delta=(-?\d+) shift=(-?\d+) inset=(-?\d+)->(-?\d+) w=(\d+) h=(\d+)->(\d+)'
            $ge = Last-Match $m.Arm.Err 'banner glide end reason=([\w-]+)'
            if ($gb) { $r.Glide = "delta=$($gb.Groups[1].Value) inset=$($gb.Groups[3].Value)->$($gb.Groups[4].Value) w=$($gb.Groups[5].Value) h=$($gb.Groups[6].Value)->$($gb.Groups[7].Value)" }
            if ($ge) { $r.GlideEnd = $ge.Groups[1].Value }
            $gc = Last-Match $m.Arm.Err 'banner glide copy=(\w+)'
            if ($gc) { $r.GlideCopy = $gc.Groups[1].Value }
            # T2763: who moved the copy, and whether it was handed over whole.
            [void](Wait-Log $m.Arm.Err 'banner glide done compositor=' 1500)
            $gd = Last-Match $m.Arm.Err 'banner glide done compositor=(true|false) ui_steps=(\d+)'
            if ($gd) { $r.GlideMover = "compositor=$($gd.Groups[1].Value) ui_steps=$($gd.Groups[2].Value)" }
            $r.GlideDeclared = (Count-Log $m.Arm.Err 'banner glide on compositor delta=-?\d+ ms=180 skipped_ms=\d+') -gt 0
        }
        # Read-only badge.
        [void](Send-TestKeys -Window $m.Top -Target $hw -Modifiers ctrl, shift -Key O)
        $r.Badge = Find-Over $m 'GhozttyReadonlyBadge' 3000
        foreach ($k in 'Scroll', 'Bell', 'Pill', 'Badge') { $r[$k] = Rel $r[$k] $slot }
        # Dim: split, and band the new pane too (section F's shape), so
        # whichever is unfocused dims a banded pane; the wash is measured off
        # its own pane's strip.
        $two = "$($m.Arm.Target)2"
        & $Exe +split "--target=$($m.Arm.Target)" '--direction=right' "--name=$two" 2>$null | Out-Null
        Start-Sleep -Milliseconds 600
        & $Exe +set-banner "--target=$two" 'band spans the window' 2>$null | Out-Null
        $wash = $null
        for ($t = 0; $t -lt 25 -and -not $wash; $t++) {
            Start-Sleep -Milliseconds 200
            $wash = @(Get-TestWindows -ProcessId $m.Arm.App.Pid -Class 'GhozttyDimOverlay') | Select-Object -First 1
        }
        if ($wash) {
            Start-Sleep -Milliseconds 400
            $wash = @(Get-TestWindows -ProcessId $m.Arm.App.Pid -Class 'GhozttyDimOverlay') | Select-Object -First 1
            # The wash's own strip: the popup, or knob on (T2559) the top of
            # the spanning pane window the card is drawn into.
            $own = if ($visual) {
                foreach ($tw in @(Get-TestWindows -ProcessId $m.Arm.App.Pid -Class 'GhozttyWindow')) {
                    @(Get-TestChildWindows -Window ([IntPtr]$tw.Hwnd) -Class 'GhozttyTerminal' | Where-Object Visible) |
                        Where-Object { [math]::Abs($_.Left - $wash.Left) -le 2 }
                }
            } else {
                @(Get-TestWindows -ProcessId $m.Arm.App.Pid -Class 'GhozttyBannerOverlay') |
                    Where-Object { [math]::Abs($_.Left - $wash.Left) -le 2 }
            }
            $own = @($own) | Select-Object -First 1
            $r.Dim = Rel $wash $own
        }
        return [pscustomobject]$r
    }
    $j1 = Measure-BannerArm 'j' '1' $jExtra
    $jBandM = Last-Match $j1.Arm.Err $bandLine
    $jBand = if ($jBandM) { [int]$jBandM.Groups[1].Value } else { -1 }
    $jOn = Probe-Overlays $j1 $true
    $jOnAlive = (Test-Alive $j1.Arm) -and (Count-Log $j1.Arm.Err $failLine) -eq 0
    $jOnTail = if (-not $jOnAlive) {
        "alive=$(Test-Alive $j1.Arm) fallbacks=$(Count-Log $j1.Arm.Err $failLine)"
        (Read-Text $j1.Arm.Err) -split "`n" | Where-Object { $_ -match 'composition present|panic|error|banner path|banner shown' } | Select-Object -Last 12
    } else { @() }
    $j0 = Measure-BannerArm 'j0' '0' $jExtra
    $jOff = Probe-Overlays $j0 $false
    Assert "J0 knob on the pane window starts one band higher in its slot (band=$jBand on=$($jOn.PaneTop) off=$($jOff.PaneTop))" `
        ($null -ne $jOn.PaneTop -and $null -ne $jOff.PaneTop -and $jBand -gt 0 -and [math]::Abs($jOn.PaneTop) -le 2 -and [math]::Abs($jOff.PaneTop - $jBand) -le 2)
    Assert "J1 the scrollbar runs down the grid, as knob off (on=$(Rect-Text $jOn.Scroll) off=$(Rect-Text $jOff.Scroll))" `
        ($jOn.Scroll -and $jOff.Scroll -and [math]::Abs($jOn.Scroll.Top - $jOff.Scroll.Top) -le 1 -and
            [math]::Abs($jOn.Scroll.Height - $jOff.Scroll.Height) -le 1 -and
            [math]::Abs(($jOn.Scroll.Left + $jOn.Scroll.Width) - ($jOff.Scroll.Left + $jOff.Scroll.Width)) -le 1)
    Assert "J2 the bell border rings the grid, as knob off (on=$(Rect-Text $jOn.Bell) off=$(Rect-Text $jOff.Bell))" (Same-Rect $jOn.Bell $jOff.Bell)
    Assert "J3 the key-state pill sits where knob off has it (on=$(Rect-Text $jOn.Pill) off=$(Rect-Text $jOff.Pill))" (Same-Rect $jOn.Pill $jOff.Pill)
    Assert "J4 the read-only badge sits where knob off has it (on=$(Rect-Text $jOn.Badge) off=$(Rect-Text $jOff.Badge))" (Same-Rect $jOn.Badge $jOff.Badge)
    Assert "J5 the unfocused dim covers the pane and its band, as knob off (on=$(Rect-Text $jOn.Dim) off=$(Rect-Text $jOff.Dim))" (Same-Rect $jOn.Dim $jOff.Dim)
    Assert "J6 the knob-on app was still running, nothing fell back" $jOnAlive
    if (-not $jOnAlive) { "    fallback/panic lines:"; $jOnTail | ForEach-Object { "      $_" } }
    # Knob on the card is a visual inside the pane (T2559), so the frozen copy
    # is a visual too, at the back of the pane's overlays (T2617): the glide
    # measures exactly as knob off (J7), lands the same way (J8), and knob on
    # it is the visual copy that stands in, from a click on the card's visual
    # (J9). T2617_NEUTERED (BannerOverlay.zig) drops it and reddens J7/J9.
    Assert "J7 a collapse glides the frozen copy knob on too, measured as knob off (on=$($jOn.Glide) off=$($jOff.Glide))" `
        ($jOn.Glide -and $jOn.Glide -match '^delta=-?\d+ inset=\d+->\d+' -and $jOn.Glide -eq $jOff.Glide)
    Assert "J8 ... and it comes down because the grid redrew at its new size (on=$($jOn.GlideEnd) off=$($jOff.GlideEnd))" `
        ($jOn.GlideEnd -eq 'landed' -and $jOff.GlideEnd -eq 'landed')
    Assert "J9 knob on a click on the card's visual toggles it and the copy is a visual, knob off a popup (toggled=$($jOn.Toggled) on=$($jOn.GlideCopy) off=$($jOff.GlideCopy))" `
        ($jOn.Toggled -and $jOn.GlideCopy -eq 'visual' -and $jOff.GlideCopy -eq 'popup')
    # T2763: knob on, the visual copy's whole glide is declared to the
    # compositor once and DWM moves it - no tick of this thread steps it. Knob
    # off the popup copy is still stepped, as before. The A/B arm
    # GHOZTTY_DEBUG_BANNER_GLIDE_STEPPED=1 steps the visual copy and reddens
    # exactly J10/J11.
    Assert "J10 knob on the visual copy's glide was declared to the compositor (log)" ($jOn.GlideDeclared -eq $true)
    # (This collapse's travel is delta=0 - the grid's row shift cancels the
    # inset change - so knob off has nothing to step either; what tells the
    # arms apart is who owned the move.)
    Assert "J11 ... and no tick moved it on the UI thread, while knob off the popup stays on this thread (on=$($jOn.GlideMover) off=$($jOff.GlideMover))" `
        ($jOn.GlideMover -eq 'compositor=true ui_steps=0' -and $jOff.GlideMover -match '^compositor=false ui_steps=\d+$')

    # ========================================================================
    "== K: the banner is a child visual of the pane, hit-tested by the pane (T2559)"
    # ========================================================================
    $k = Measure-BannerArm 'k' '1'
    $kErr = $k.Arm.Err
    Assert "K0 the knob-on arm has a banner pane" ($null -ne $k.Pane -and $null -ne $k.Strip)
    Assert "K1 the card was shown as a visual (log)" ((Count-Log $kErr $visualLine) -ge 1)
    $kPop = @(Get-TestWindows -ProcessId $k.Arm.App.Pid -Class 'GhozttyBannerOverlay' | Where-Object Visible)
    Assert "K2 no banner popup is visible ($($kPop.Count))" ($kPop.Count -eq 0)
    $kShown = Count-Log $kErr $visualLine
    $kPresents = Count-Log $kErr 'banner present w='
    if ($k.Top -ne [IntPtr]::Zero) {
        $wr = Get-TestWindowRect -Window $k.Top
        [void](Set-TestWindowPos -Window $k.Top -X ($wr.Left + 60) -Y ($wr.Top + 30))
        Start-Sleep -Milliseconds 800
    }
    $kPop = @(Get-TestWindows -ProcessId $k.Arm.App.Pid -Class 'GhozttyBannerOverlay' | Where-Object Visible)
    Assert "K3 after a window move still no popup, the card was not re-shown and no popup frame was presented" `
        ($kPop.Count -eq 0 -and (Count-Log $kErr $visualLine) -eq $kShown -and (Count-Log $kErr 'banner present w=') -eq $kPresents)
    # Re-measure the pane after the move: the card is its top band.
    $kPane = $null
    if ($k.Top -ne [IntPtr]::Zero) {
        $kPane = @(Get-TestChildWindows -Window $k.Top -Class 'GhozttyTerminal' | Where-Object Visible) | Select-Object -First 1
    }
    $kh = if ($k.Strip) { $k.Strip.Height } else { 0 }
    # A link on the card: sweep a row through its first line until the pane
    # window reports the hover.
    & $Exe +set-banner "--target=$($k.Arm.Target)" '[hover me](https://example.invalid/t2559) and some text' 2>$null | Out-Null
    Start-Sleep -Milliseconds 700
    $hovered = $false
    if ($kPane -and $kh -gt 0) {
        $hw = [IntPtr]$kPane.Hwnd
        $y = $kPane.Top + [int]($kh / 2)
        for ($x = $kPane.Left + 8; $x -lt $kPane.Left + 240 -and -not $hovered; $x += 8) {
            [void](Send-TestMouse -Window $k.Top -Target $hw -X $x -Y $y -Action move -Client)
            Start-Sleep -Milliseconds 60
            $hovered = (Read-Text $kErr) -match 'banner link hover=true'
        }
        # Off the card again, into the grid.
        [void](Send-TestMouse -Window $k.Top -Target $hw -X ($kPane.Left + 60) -Y ($kPane.Top + $kh + 60) -Action move -Client)
    }
    Assert "K4 a link on the card lights under the pointer, through the pane window (log)" $hovered
    Assert "K4a ... and goes out when the pointer moves into the grid (log)" `
        ($hovered -and (Wait-Log $kErr 'banner link hover=false' 2000))
    # A single-line card: a click in its band (beside the link) is the
    # banner's - it focuses the pane - and never a terminal press.
    $presses = Count-Log $kErr 'pane mouse left press'
    if ($kPane -and $kh -gt 0) {
        [void](Send-TestMouse -Window $k.Top -Target ([IntPtr]$kPane.Hwnd) -X ($kPane.Right - 60) -Y ($kPane.Top + [int]($kh / 2)) -Client)
    }
    Assert "K5 a click on the card arrived on the pane window and was the banner's (log visual=true)" `
        (Wait-Log $kErr 'banner click x=\d+ y=\d+ visual=true' 3000)
    Assert "K5a ... and the terminal saw no press for it" ((Count-Log $kErr 'pane mouse left press') -eq $presses)
    # A multi-line card: the click toggles it, and the toggle re-renders the
    # visual every frame (no popup paints).
    & $Exe +set-banner "--target=$($k.Arm.Target)" 'one\ntwo\nthree\nfour' 2>$null | Out-Null
    Start-Sleep -Milliseconds 800
    $paints = Count-Log $kErr 'banner paint h='
    if ($kPane -and $kh -gt 0) {
        [void](Send-TestMouse -Window $k.Top -Target ([IntPtr]$kPane.Hwnd) -X ($kPane.Left + [int]($kPane.Width / 2)) -Y ($kPane.Top + 20) -Client)
    }
    $toggled = Wait-Log $kErr 'banner collapse from=' 3000
    Start-Sleep -Milliseconds 600
    Assert "K6 a click on a multi-line card's visual toggles it (log)" $toggled
    Assert "K6a ... and the card's frames were rendered for the visual ($((Count-Log $kErr 'banner paint h=') - $paints) paints), no popup shown" `
        ($toggled -and (Count-Log $kErr 'banner paint h=') -gt ($paints + 2) -and
            @(Get-TestWindows -ProcessId $k.Arm.App.Pid -Class 'GhozttyBannerOverlay' | Where-Object Visible).Count -eq 0)
    # A press in the grid is still the terminal's.
    $presses = Count-Log $kErr 'pane mouse left press'
    if ($kPane) {
        [void](Send-TestMouse -Window $k.Top -Target ([IntPtr]$kPane.Hwnd) -X ($kPane.Left + 80) -Y ($kPane.Bottom - 40) -Client)
    }
    Assert "K7 a click in the grid is the terminal's (log)" `
        ((Wait-Log $kErr 'pane mouse left press' 2000) -and (Count-Log $kErr 'pane mouse left press') -gt $presses)
    Assert "K7a the app is still running, nothing fell back" ((Test-Alive $k.Arm) -and (Count-Log $kErr $failLine) -eq 0)
    $k0 = Measure-BannerArm 'k0' '0'
    Assert "K8 negative control: knob off, the card is a popup and never a visual" `
        ($k0.Strip -and -not $k0.Strip.Visual -and (Count-Log $k0.Arm.Err $visualLine) -eq 0)

    # ========================================================================
    "== L: a machine with no GL/D3D interop falls back by default and draws (T2514)"
    # ========================================================================
    # Mesa, a WARP-only GL and Remote Desktop have no WGL_NV_DX_interop2. With
    # the path now the default, every pane there must say so once and present
    # with SwapBuffers - with a banner too, since the window still spans the
    # band (T2566: the grid lands below it, the strip popup covers it).
    $env:GHOZTTY_COMP_PRESENT_SIMULATE_NO_INTEROP = '1'
    try { $l = Measure-BannerArm 'l' $null }
    finally { Remove-Item env:GHOZTTY_COMP_PRESENT_SIMULATE_NO_INTEROP -ErrorAction SilentlyContinue }
    $lText = Read-Text $l.Arm.Err
    $lUnavail = Count-Log $l.Arm.Err 'composition present unavailable \(error\.NoInterop\) at wgl-interop'
    Assert "L1 every pane says the path is unavailable at the interop stage ($lUnavail lines)" ($lUnavail -ge 1)
    Assert "L2 and none built a chain or failed mid-life" `
        ($lText -notmatch $onLine -and (Count-Log $l.Arm.Err $failLine) -eq 0)
    Assert "L3 the app is still running and the pane draws text" ((Test-Alive $l.Arm) -and (Test-DrawsText $l.Arm.Target))
    Assert "L4 the banner is a popup glued over the pane window's top (strip=$($l.Strip.Top) pane=$($l.Pane.Top))" `
        ($l.Pane -and $l.Strip -and -not $l.Strip.Visual -and [math]::Abs($l.Strip.Top - $l.Pane.Top) -le 2)
    Assert "L5 no OpenGL error and no failed draw" `
        ($lText -notmatch 'error\(opengl\)' -and $lText -notmatch 'error drawing err=')

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
Write-TestVerdict -Pass $script:passes -Fail $script:failures -Label 'comp-present' -MinPass 87
