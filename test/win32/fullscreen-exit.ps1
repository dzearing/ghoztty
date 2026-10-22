# T2011 acceptance: a full-screen window always shows the way out.
#
# User report (2026-10-16, over Remote Desktop): "the chrome of the app
# completely disappears (the part with the X and the max/min buttons). tab
# just leaves. i can't figure out how to get it back." That was full screen,
# entered with ctrl+enter, with nothing on screen to say how to leave.
#
# What this proves, on the BACKGROUND test desktop (lib\TestDesktop.ps1), so
# it never takes the user's foreground (asserted at the end):
#
#   A. F11 enters full screen (the Windows convention): the caption and frame
#      bits are gone and the window covers the monitor.
#   B. The entry notice: an "Exit full screen" chip (class
#      GhozttyFullscreenExit, owned by the window) is up at once, top-RIGHT,
#      at the read-only badge's computed inset.
#   C. After the notice expires, a pointer away from the top hides the chip,
#      a pointer at the top edge shows it, and moving well down hides it
#      again. The pointer is POSTED (WM_APP+41, debug only): the test desktop
#      has no cursor to move.
#   D. Clicking the chip leaves full screen with the frame and the exact
#      rect restored.
#   E. ctrl+enter does NOT toggle (T2161, D99): it reaches the shell, and F11
#      still does.
#   F. A MAXIMIZED window comes back maximized, with its normal rect intact.
#   G. WM_DISPLAYCHANGE while full screen re-covers the monitor. While
#      maximized it leaves the caption alone.
#   H. Every entry and exit is logged with its trigger.
#
# CAPTURE LIMIT, named: the chip paints through UpdateLayeredWindow, so
# PrintWindow cannot render it. Its colors and contrast floors are asserted
# in `fullscreen_exit.zig`'s unit tests instead.
#
# Only touches ghoztty processes running from this repo's zig-out*.
param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }
$env:GHOZTTY_PIPE_SUFFIX = "-fstest$PID"
$errlog = Join-Path $env:TEMP 'ghoztty-fullscreen-exit-stderr.log'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\PaneLiveness.ps1')

$script:pass = 0
$script:fail = 0
$script:negReached = $false

function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Stop-RepoInstances { [void](Stop-RepoGhoztty -Exe $exe -SettleMs 800) }

function Px([double]$dip, [double]$scale) {
    return [int][math]::Round($dip * $scale, [System.MidpointRounding]::AwayFromZero)
}

$WS_CAPTION = 0x00C00000
$WS_THICKFRAME = 0x00040000
$WM_APP_TEST_FULLSCREEN_POINTER = 0x8000 + 41
$WM_DISPLAYCHANGE = 0x007E

function Test-Framed([IntPtr]$h) {
    $style = [int64](Get-TestWindowStyle -Window $h)
    return (($style -band $WS_CAPTION) -eq $WS_CAPTION) -and (($style -band $WS_THICKFRAME) -ne 0)
}

function Get-Chips([int]$procId) {
    return @(Get-TestWindows -ProcessId $procId -Class 'GhozttyFullscreenExit' | Where-Object Visible)
}

function Wait-Chips([int]$procId, [int]$want, [int]$tries = 30) {
    for ($t = 0; $t -lt $tries; $t++) {
        $c = @(Get-Chips $procId)
        if ($c.Count -eq $want) { return $c }
        Start-Sleep -Milliseconds 100
    }
    return @(Get-Chips $procId)
}

function Wait-Framed([IntPtr]$h, [bool]$want) {
    for ($t = 0; $t -lt 30; $t++) {
        if ((Test-Framed $h) -eq $want) { return $true }
        Start-Sleep -Milliseconds 100
    }
    return $false
}

function Set-Pointer([IntPtr]$h, [int]$x, [int]$y) {
    [void](Invoke-TestMessage -Window $h -Message $WM_APP_TEST_FULLSCREEN_POINTER `
        -WParam ([IntPtr]$x) -LParam ([IntPtr]$y))
}

function Get-LogCount([string]$pattern) {
    if (-not (Test-Path $errlog)) { return 0 }
    return @(Select-String -Path $errlog -Pattern $pattern -SimpleMatch).Count
}

function Covers($r, $wa) {
    return ($r.Left -le $wa.Left) -and ($r.Top -le $wa.Top) -and
           ($r.Right -ge $wa.Right) -and ($r.Bottom -ge $wa.Bottom)
}

Stop-RepoInstances
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$launched = @()
$app = $null

try {
    if ($NegativeControl) {
        Write-Host 'NEGATIVE CONTROL: section B asserts the chip at a DELIBERATELY WRONG inset - this run MUST fail'
    }
    Remove-Item $errlog -ErrorAction SilentlyContinue
    $sp = @{
        Exe       = $exe
        Arguments = @('--session-persistence=false', '--background=#101014')
        StdErr    = $errlog
    }
    $app = Start-OnTestDesktop @sp
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $launched += $script:GhozttyTestDesktopPids
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: top window not found'; exit 1 }
    Assert (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) 'window is NOT enumerable on the interactive desktop'

    $dpi = Get-TestWindowDpi -Window $top
    if (-not $dpi -or $dpi -le 0) { $dpi = 96 }
    $scale = [double]$dpi / 96.0
    $wantGap = (Px 8 $scale) - ((Px 4 $scale) + (Px 2 $scale))
    $wa = Get-TestWorkArea
    Write-Host "INFO  dpi=$dpi scale=$scale chip gap=$wantGap work area=$($wa.Left),$($wa.Top),$($wa.Right),$($wa.Bottom)"

    $panes = @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal')
    if ($panes.Count -lt 1) { Write-Host 'SETUP FAIL: no pane'; exit 1 }
    $pane = [IntPtr]$panes[0].Hwnd

    # Not full screen yet: framed, and no chip.
    Assert (Test-Framed $top) 'setup: the window starts framed'
    Assert ((@(Get-Chips $app.Pid)).Count -eq 0) 'setup: no exit chip before full screen'
    $r0 = Get-TestWindowRect -Window $top

    # -----------------------------------------------------------------------
    # A. F11 enters full screen.
    # -----------------------------------------------------------------------
    $enter0 = Get-LogCount 'fullscreen enter trigger=action'
    Assert (Send-TestKeys -Window $top -Target $pane -Key F11) 'A: F11 delivered'
    Assert (Wait-Framed $top $false) 'A: F11 dropped the caption and frame (full screen)'
    $rf = Get-TestWindowRect -Window $top
    Assert (Covers $rf $wa) "A: the window covers the monitor ($($rf.Left),$($rf.Top),$($rf.Right),$($rf.Bottom))"

    # -----------------------------------------------------------------------
    # B. The entry notice is up at once, top-right, at the badge inset.
    # -----------------------------------------------------------------------
    $chips = @(Wait-Chips $app.Pid 1)
    Assert ($chips.Count -eq 1) "B: the exit chip shows on entry ($($chips.Count))"
    if ($chips.Count -eq 1) {
        $c = $chips[0]
        $script:negReached = $true
        $want = if ($NegativeControl) { $wantGap + 5 } else { $wantGap }
        Assert (($rf.Right - $c.Right) -eq $want) "B: chip is $want px from the right edge (got $($rf.Right - $c.Right))"
        Assert (($c.Top - $rf.Top) -eq $want) "B: chip is $want px from the top edge (got $($c.Top - $rf.Top))"
        Assert (($c.Right - $c.Left) -lt [int](($rf.Right - $rf.Left) / 2)) 'B: the chip is a corner chip, not a band'
        $owner = Get-TestWindowOwner -Window ([IntPtr]$c.Hwnd)
        Assert ([int64]$owner -eq [int64]$top) 'B: the chip is owned by the full-screen window (so it stays above it)'
        $ex = [int64](Get-TestWindowStyle -Window ([IntPtr]$c.Hwnd) -ExStyle)
        Assert (($ex -band 0x80000) -ne 0) 'B: chip is WS_EX_LAYERED'
        Assert (($ex -band 0x8000000) -ne 0) 'B: chip is WS_EX_NOACTIVATE'
        Assert (($ex -band 0x20) -eq 0) 'B: chip is NOT click-through'
    }

    # -----------------------------------------------------------------------
    # C. After the notice, the top edge reveals the chip.
    # -----------------------------------------------------------------------
    $midX = [int](($rf.Left + $rf.Right) / 2)
    Set-Pointer $top $midX ([int]($rf.Top + 400))
    Start-Sleep -Milliseconds 4600
    Set-Pointer $top $midX ([int]($rf.Top + 400))
    Assert ((@(Wait-Chips $app.Pid 0)).Count -eq 0) 'C: the notice expired with the pointer away: chip hidden'
    Set-Pointer $top $midX $rf.Top
    Assert ((@(Wait-Chips $app.Pid 1)).Count -eq 1) 'C: pointer at the top edge reveals the chip'
    Set-Pointer $top $midX ([int]($rf.Top + (Px 30 $scale)))
    Assert ((@(Wait-Chips $app.Pid 1 5)).Count -eq 1) 'C: the chip holds while the pointer heads down toward it'
    Set-Pointer $top $midX ([int]($rf.Top + 400))
    Assert ((@(Wait-Chips $app.Pid 0)).Count -eq 0) 'C: pointer well below hides the chip again'

    # -----------------------------------------------------------------------
    # D. Clicking the chip leaves full screen and restores the frame.
    # -----------------------------------------------------------------------
    Set-Pointer $top $midX $rf.Top
    $chips = @(Wait-Chips $app.Pid 1)
    if ($chips.Count -eq 1) {
        $c = $chips[0]
        $cx = [int](($c.Left + $c.Right) / 2); $cy = [int](($c.Top + $c.Bottom) / 2)
        Assert (Send-TestMouse -Window $top -Target ([IntPtr]$c.Hwnd) -X $cx -Y $cy -Button left -Action click) 'D: click delivered to the chip'
        Assert (Wait-Framed $top $true) 'D: clicking the chip restored the caption and frame'
        $r1 = Get-TestWindowRect -Window $top
        Assert (($r1.Left -eq $r0.Left) -and ($r1.Top -eq $r0.Top) -and ($r1.Right -eq $r0.Right) -and ($r1.Bottom -eq $r0.Bottom)) `
            "D: the window is back at its exact rect ($($r1.Left),$($r1.Top),$($r1.Right),$($r1.Bottom) vs $($r0.Left),$($r0.Top),$($r0.Right),$($r0.Bottom))"
        Assert ((@(Wait-Chips $app.Pid 0)).Count -eq 0) 'D: the chip is gone once framed'
    } else {
        Assert $false 'D: no chip to click'
    }

    # -----------------------------------------------------------------------
    # E. ctrl+enter is the PROGRAM's key (T2161, D99): it leaves the window
    #    framed and reaches the program. The pane runs a key reporter (a named
    #    window, because +read needs a name) that prints every key it reads
    #    with its modifiers, the way Claude Code reads them; the oracle is the
    #    reporter's line for Enter WITH Control. cmd.exe cannot be the oracle:
    #    its line editor ignores ctrl+enter in any console, so "the echo ran"
    #    could never pass.
    # -----------------------------------------------------------------------
    $fsEnter0 = Get-LogCount 'fullscreen enter'
    $ceName = "fsce$PID"
    $ceOut = Join-Path $env:TEMP "fullscreen-exit-ce-$PID.txt"
    $ceScript = Join-Path $env:TEMP "fullscreen-exit-keys-$PID.ps1"
    Set-Content -Path $ceScript -Encoding ASCII -Value @(
        'Write-Host "KEYREPORTER READY"'
        'while ($true) { $k = [Console]::ReadKey($true); Write-Host ("KEYSEEN " + $k.Key + "+" + ($k.Modifiers -replace ", ", "+")) }'
    )
    $before = @(Get-TestWindows -ProcessId $app.Pid -Class 'GhozttyWindow' | ForEach-Object { [int64]$_.Hwnd })
    [void](Invoke-LivenessCli $exe "+new-window --target=$ceName `"--command=powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ceScript`"" $ceOut 15)
    $ceTop = [IntPtr]::Zero
    for ($t = 0; $t -lt 50 -and $ceTop -eq [IntPtr]::Zero; $t++) {
        $new = @(Get-TestWindows -ProcessId $app.Pid -Class 'GhozttyWindow' |
            Where-Object { $before -notcontains [int64]$_.Hwnd })
        if ($new.Count -ge 1) { $ceTop = [IntPtr]$new[0].Hwnd } else { Start-Sleep -Milliseconds 100 }
    }
    Assert ($ceTop -ne [IntPtr]::Zero) 'E: setup: the named key-reporter window opened'
    if ($ceTop -ne [IntPtr]::Zero) {
        $cePanes = @(Get-TestChildWindows -Window $ceTop -Class 'GhozttyTerminal')
        $cePane = if ($cePanes.Count -ge 1) { [IntPtr]$cePanes[0].Hwnd } else { [IntPtr]::Zero }
        function Read-Ce {
            if ((Invoke-LivenessCli $exe "+read --name=$ceName --lines=200" $ceOut 12) -ne 0) { return '' }
            try { return [string](Get-Content $ceOut -Raw) } catch { return '' }
        }
        $txt = ''
        for ($t = 0; $t -lt 30 -and $txt -notmatch 'KEYREPORTER READY'; $t++) {
            $txt = Read-Ce; if ($txt -notmatch 'KEYREPORTER READY') { Start-Sleep -Milliseconds 300 }
        }
        Assert ($txt -match 'KEYREPORTER READY') 'E: setup: the key reporter is reading keys'
        Assert (Send-TestKeys -Window $ceTop -Target $cePane -Key Enter -Modifiers ctrl) 'E: ctrl+enter delivered'
        Start-Sleep -Milliseconds 800
        Assert (Test-Framed $ceTop) 'E: ctrl+enter did NOT enter full screen'
        Assert ((Get-LogCount 'fullscreen enter') -eq $fsEnter0) 'E: no full-screen entry was logged'
        # Positive control on the oracle: a plain Enter must be reported too,
        # and WITHOUT Control - so the Control line is not the reporter's
        # default.
        Assert (Send-TestKeys -Window $ceTop -Target $cePane -Key Enter) 'E: control: plain enter delivered'
        $seen = $false; $plain = $false
        for ($t = 0; $t -lt 20 -and -not ($seen -and $plain); $t++) {
            $txt = Read-Ce
            $seen = $txt -match 'KEYSEEN Enter\+[A-Za-z+]*Control'
            $plain = $txt -match 'KEYSEEN Enter\+0'
            if (-not ($seen -and $plain)) { Start-Sleep -Milliseconds 400 }
        }
        if (-not ($seen -and $plain)) {
            Write-Host "INFO  E: last +read output: $(($txt).Trim() -replace '\s+', ' ')"
        }
        $ctlLabel = 'E: the program received ctrl+enter (KEYSEEN Enter+Control)'
        if ($NegativeControl) { $seen = -not $seen; $ctlLabel += ' [NEGATED]' }
        Assert $seen $ctlLabel
        Assert $plain 'E: control: the program saw a plain enter WITHOUT Control'
        Assert (Send-TestKeys -Window $ceTop -Target $cePane -Key F11) 'E: F11 still delivered in that window'
        Assert (Wait-Framed $ceTop $false) 'E: F11 still enters full screen there'
        Assert (Send-TestKeys -Window $ceTop -Target $cePane -Key F11) 'E: F11 delivered to leave'
        Assert (Wait-Framed $ceTop $true) 'E: F11 left full screen'
    }
    Remove-Item $ceOut, $ceScript -ErrorAction SilentlyContinue

    # -----------------------------------------------------------------------
    # F. Maximized in, maximized out, normal rect intact.
    # -----------------------------------------------------------------------
    $n0 = Get-TestWindowNormalRect -Window $top
    [void](Send-TestSysCommand -Window $top -Command maximize)
    Start-Sleep -Milliseconds 600
    Assert (Test-TestWindowZoomed -Window $top) 'F: setup: window maximized'
    $rm = Get-TestWindowRect -Window $top
    Assert (Send-TestKeys -Window $top -Target $pane -Key F11) 'F: F11 delivered while maximized'
    Assert (Wait-Framed $top $false) 'F: entered full screen from maximized'

    # G (full-screen half): a display change re-covers the monitor.
    $refit0 = Get-LogCount 'fullscreen refit on display change'
    [void](Invoke-TestMessage -Window $top -Message $WM_DISPLAYCHANGE -WParam ([IntPtr]32) -LParam ([IntPtr]0))
    Start-Sleep -Milliseconds 400
    Assert ((Get-LogCount 'fullscreen refit on display change') -gt $refit0) 'G: WM_DISPLAYCHANGE while full screen re-fits the window'
    Assert (Covers (Get-TestWindowRect -Window $top) $wa) 'G: still covering the monitor after the display change'

    Assert (Send-TestKeys -Window $top -Target $pane -Key F11) 'F: F11 delivered to leave'
    Assert (Wait-Framed $top $true) 'F: left full screen'
    Start-Sleep -Milliseconds 300
    Assert (Test-TestWindowZoomed -Window $top) 'F: the window came back MAXIMIZED'
    $rm2 = Get-TestWindowRect -Window $top
    Assert (($rm2.Left -eq $rm.Left) -and ($rm2.Top -eq $rm.Top) -and ($rm2.Right -eq $rm.Right) -and ($rm2.Bottom -eq $rm.Bottom)) 'F: at the maximized rect it had'
    $n1 = Get-TestWindowNormalRect -Window $top
    Assert (($n1.Left -eq $n0.Left) -and ($n1.Top -eq $n0.Top) -and ($n1.Width -eq $n0.Width) -and ($n1.Height -eq $n0.Height)) `
        'F: and it still un-maximizes to its old normal rect'

    # G (maximized half): a display change never strips the caption.
    [void](Invoke-TestMessage -Window $top -Message $WM_DISPLAYCHANGE -WParam ([IntPtr]32) -LParam ([IntPtr]0))
    Start-Sleep -Milliseconds 400
    Assert (Test-Framed $top) 'G: WM_DISPLAYCHANGE while maximized leaves the caption in place'
    Assert ((@(Get-Chips $app.Pid)).Count -eq 0) 'G: and puts up no chip'

    # -----------------------------------------------------------------------
    # H. The log names every trigger.
    # -----------------------------------------------------------------------
    Assert ((Get-LogCount 'fullscreen enter trigger=action') -ge ($enter0 + 3)) `
        "H: every keyboard entry is logged as trigger=action ($(Get-LogCount 'fullscreen enter trigger=action'))"
    Assert ((Get-LogCount 'fullscreen exit trigger=exit_button') -eq 1) 'H: the chip click is logged as trigger=exit_button'
    Assert ((Get-LogCount 'fullscreen exit trigger=action') -ge 2) 'H: keyboard exits are logged as trigger=action'

    Assert (-not ($app.Process -and $app.Process.HasExited)) 'no crash'
} catch {
    Write-Host "ERROR $_" -ForegroundColor Red
    $script:fail++
} finally {
    if ($app) { Stop-Process -Id $app.Pid -Force -ErrorAction SilentlyContinue }
    Remove-TestDesktop
    Stop-RepoInstances
}

$fgSeen = @(Stop-TestForegroundWatch)
Write-Host "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @($launched | Select-Object -Unique)
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) "no test-desktop app ever became foreground on the interactive desktop (saw $($leaked -join ','))"
}

if ($NegativeControl -and -not $script:negReached) {
    Assert $false 'NEGATIVE CONTROL never reached its inverted assertion'
}

Complete-TestBody
if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard fullscreen-exit -Repo $repo 2>&1 | ForEach-Object { Write-Host "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Label 'FULLSCREEN EXIT ACCEPTANCE'
