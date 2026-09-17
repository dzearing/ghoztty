# T742: opening the command palette or the search bar must not resize the
# terminal grid underneath it.
#
# THE DEFECT. `App.surfaceWndProc` serves three windows - the terminal child
# HWND, the search-bar popup and the command-palette popup - because all three
# store the same `*Surface` in their `GWLP_USERDATA`. T613 fixed the WM_DESTROY
# arm (a popup's destroy cleared `Surface.hwnd` and the process died); the rest
# of the switch went on treating every message as the terminal's. The one the
# user could see was WM_SIZE: `positionCommandPalette` / `positionSearchBar`
# call `MoveWindow(popup, ..., 1)`, DefWindowProc turns the resulting
# WM_WINDOWPOSCHANGED into a WM_SIZE on the POPUP, and the handler called
# `surface.handleResize(500, 450)` - the palette's pixel size. The grid reflowed
# and the PTY got that SIGWINCH, so the text the user was reading moved every
# time they opened the palette. The next real resize put it back, which is why
# it read as a flicker rather than a lasting wrong size.
#
# THE ORACLE IS THE PANE'S CHILD, not the app's own report: the claim is that
# the PTY was told a wrong size, so what has to be asked is the shell living on
# the other end of it. A generated `.cmd` shim prints
# `G<tag>=<cols>x<rows>` from `$Host.UI.RawUI.WindowSize` and `+read` reads it
# back out of the pane (the `+send-keys` shape rules that force a shim are
# written up in session-relaunch.ps1: adjacent text args concatenate, `\t`/`\n`
# are escapes, and `-NoProfile` would be parsed as send-keys' own flag).
#
# WHY THE MESSAGE IS INJECTED. Measured on box, `MoveWindow` to the size the
# popup ALREADY has does not produce a WM_SIZE - so the defect fires on the
# palette opens where the size differs (a DPI change moved `Surface.scale`
# between creation and positioning) and not on every one. A test that only
# opened the palette therefore passed against the broken build, which is the
# one thing an acceptance arm may not do. So each popup is sent the exact
# WM_SIZE that DefWindowProc delivers for its own rect, at its own HWND, while
# it is up: that is the arm under test, stated without depending on which
# opens happen to resize.
#
# WHY ARM A COMES FIRST. A probe that always reports the same numbers would
# pass everything below for free. A deliberately resizes the WINDOW and
# requires the reported grid to change, so the measurement is known to track
# the grid before anything is asserted not to move it.
#
# ARMS:
#   A. positive control - a real window resize DOES change the reported grid.
#   B. the palette, up, sent its own WM_SIZE: the grid does not move.
#   C. the search bar, same.
#   D. the pane's SCROLLBAR overlay survives both popup toggles - the
#      WM_SHOWWINDOW half of the same confusion, where SHOWING a popup ran
#      `setOwnerVisible` for the terminal's scrollbar and HIDING it hid the
#      scrollbar with it. Baselined before any popup opens, and counted by
#      OWNER so it is this pane's bar and not the other window's.
#   E. a WM_CHAR injected at the palette popup does not type into the terminal
#      underneath. Last, because anything that did arrive is left on the
#      shell's command line.
#
# T211/T217: runs on a BACKGROUND Win32 desktop and asserts at the end that it
# never took the user's foreground.
# Only touches ghoztty processes running from this repo's zig-out*.
param([string]$ExePath, [switch]$Interactive)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }
$errlog = Join-Path $env:TEMP 'ghoztty-palette-grid-stderr.log'
$env:GHOZTTY_PIPE_SUFFIX = "-palettegrid$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
# T1511: the shared scorer, and the dot-source is also what ARMS the run - a
# body that unwinds before `Complete-TestBody` may not print a pass, and the
# guard-stamping child below reads the same state and refuses to write.
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

# The shim directory: every path segment below has to survive `+send-keys`
# escape processing, so no segment may begin with t, n, r, e or a backslash.
$work = Join-Path $env:TEMP "ghoztty-palette-grid-$PID"
$shimdir = Join-Path $work 'probes'

$script:pass = 0
$script:fail = 0
$script:skipped = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}
function Skip([string]$label) { $script:skipped++; Write-Host "SKIP  $label" }

function Kill-RepoInstances {
    [void](Stop-RepoGhoztty -Exe $exe -SettleMs 500)
}

function Run-Cli([string]$argsLine, [string]$out, [int]$timeoutSec = 15) {
    $r = Invoke-OnTestDesktop -Exe $exe -Arguments ($argsLine -split ' ') `
        -TimeoutSec $timeoutSec -Desktop $script:td
    $text = if ($null -eq $r.Output) { '' } else { [string]$r.Output }
    Set-Content -LiteralPath $out -Value $text -Encoding UTF8
    if ($r.TimedOut) { return $null }
    return $r.ExitCode
}

function Out-Text([string]$f) { if (Test-Path $f) { Get-Content $f -Raw } else { '' } }

# Write the grid probe. One `.ps1` doing the reporting, one `.cmd` per tag so
# exactly one text word is ever sent to the pane.
function Write-GridProbe([string]$dir) {
    New-Item -ItemType Directory -Force $dir | Out-Null
    $probe = @'
param([string]$Tag)
$sz = $Host.UI.RawUI.WindowSize
Write-Host ("G" + $Tag + "=" + $sz.Width + "x" + $sz.Height)
'@
    Set-Content -Path (Join-Path $dir 'grid-probe.ps1') -Value $probe -Encoding ascii
}

# Ask the pane's shell for its console size. Returns "<cols>x<rows>", or '' if
# the answer never came back. $tag must be unique per call: a previous answer
# is still in the pane's scrollback and would be read as this one.
function Get-PaneGrid([string]$target, [string]$tag, [int]$timeoutSec = 30) {
    $shim = Join-Path $shimdir "g$tag.cmd"
    Set-Content -Path $shim -Encoding ascii `
        -Value "@powershell -NoProfile -ExecutionPolicy Bypass -File `"%~dp0grid-probe.ps1`" -Tag $tag"
    Run-Cli "+send-keys --target=$target $shim Enter" (Join-Path $work "send-$tag.txt") 12 | Out-Null
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        Run-Cli "+read --name=$target --lines=200" (Join-Path $work "read-$tag.txt") 10 | Out-Null
        $s = Out-Text (Join-Path $work "read-$tag.txt")
        # The echoed command line carries the tag but not an `=`, so the match
        # is anchored on the assignment the probe itself printed.
        $m = [regex]::Match($s, 'G' + [regex]::Escape($tag) + '=(\d+)x(\d+)')
        if ($m.Success) { return ($m.Groups[1].Value + 'x' + $m.Groups[2].Value) }
        Start-Sleep -Seconds 1
    }
    return ''
}

function Get-Tops { return @(Get-TestWindows -ProcessId $script:app.Pid -Class 'GhozttyWindow' | ForEach-Object { [IntPtr]$_.Hwnd }) }

# Open a named window and hand back its top HWND, by diffing the window set.
function New-NamedWindow([string]$name) {
    $before = Get-Tops
    Run-Cli "+new-window --target=$name" (Join-Path $work "new-$name.txt") 20 | Out-Null
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 400
        foreach ($h in Get-Tops) { if ($before -notcontains $h) { return $h } }
    }
    return [IntPtr]::Zero
}

# ctrl+shift+p and hand back the palette popup HWND. The popup uses the
# TERMINAL window class (it shares the surface wndproc - which is the whole
# point of this script), so that is what identifies it, and only the palette
# has an EDIT with no STATIC beside it.
function Open-Palette([IntPtr]$top, [IntPtr]$pane) {
    foreach ($try in 1..3) {
        if (-not (Send-TestKeys -Window $top -Target $pane -Modifiers ctrl, shift -Key P)) { continue }
        $popup = Wait-TestWindow -ProcessId $script:app.Pid -Class 'GhozttyCommandPalette' -TimeoutMs 5000
        if ($popup -ne [IntPtr]::Zero) { return $popup }
    }
    return [IntPtr]::Zero
}

# ctrl+shift+f opens the search bar. Since T1375 it has a class of its own, so
# the class identifies it; the count label is kept as a second check.
function Open-Search([IntPtr]$top, [IntPtr]$pane) {
    foreach ($try in 1..3) {
        if (-not (Send-TestKeys -Window $top -Target $pane -Modifiers ctrl, shift -Key F)) { continue }
        $popup = Wait-TestWindow -ProcessId $script:app.Pid -Class 'GhozttySearchBar' -TimeoutMs 5000
        if ($popup -eq [IntPtr]::Zero) { continue }
        if ((Find-TestWindowEx -Parent $popup -Class 'STATIC') -eq [IntPtr]::Zero) { continue }
        return $popup
    }
    return [IntPtr]::Zero
}

# Escape in the popup's own EDIT, which is where its focus lives.
function Close-Popup([IntPtr]$popup) {
    $edit = Find-TestWindowEx -Parent $popup -Class 'EDIT'
    if ($edit -ne [IntPtr]::Zero) { Send-TestControlKey -Control $edit -Key Escape | Out-Null }
    Start-Sleep -Milliseconds 700
}

# Visible scrollbar overlays owned by one WINDOW, as a count. Owner-scoped
# because the app has another window up and a whole-process count would hide
# this window's bar going dark behind the other one's staying lit. The owner is
# the top-level window and not the pane: a WS_POPUP created against a child
# HWND is owned by that child's top-level ancestor, which is Win32's rule and
# not a choice this test makes.
function Get-VisibleScrollbars([IntPtr]$owner) {
    $bars = @(Get-TestWindows -ProcessId $script:app.Pid -Class 'GhozttyScrollbar')
    return @($bars | Where-Object {
            $h = [IntPtr]$_.Hwnd
            (Test-TestWindowVisible -Window $h) -and
            ((Get-TestWindowOwner -Window $h) -eq $owner)
        }).Count
}

# The WM_SIZE DefWindowProc would deliver for this window's own rect: wparam
# SIZE_RESTORED, lparam the client size packed high-word height, low-word width.
function Send-OwnSize([IntPtr]$window) {
    $r = Get-TestWindowRect -Window $window -Client
    $w = [int]$r.Width
    $h = [int]$r.Height
    if ($w -le 0 -or $h -le 0) { return $false }
    $lp = [IntPtr](($h -band 0xFFFF) * 65536 + ($w -band 0xFFFF))
    [void](Invoke-TestMessage -Window $window -Message 0x0005 -WParam ([IntPtr]0) -LParam $lp)
    return $true
}

Kill-RepoInstances
Remove-Item $errlog -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $work | Out-Null
Write-GridProbe $shimdir
Start-TestForegroundWatch
$script:td = New-TestDesktop -Interactive:$Interactive

try {
    # persistence: explicitly OFF - a restored manifest would hand this run a
    # previous run's panes, and every arm measures one specific pane.
    $script:app = Start-OnTestDesktop -Exe $exe -Arguments @('--session-persistence=false') -StdErr $errlog
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $home1 = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($home1 -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: top window not found'; exit 1 }
    Assert (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) 'window is NOT enumerable on the interactive desktop'

    # A named window, so `+send-keys` / `+read` can address this pane by name
    # while the HWND helpers address the same window by handle.
    $top = New-NamedWindow 'pgs'
    if ($top -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: the named window never opened'; exit 1 }
    $pane = Get-TestChildWindow -Window $top -Class 'GhozttyTerminal'
    if ($pane -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: the named window has no pane'; exit 1 }

    # --- Setup control: the probe answers at all ----------------------------
    $base = Get-PaneGrid 'pgs' 'base'
    if ($base -eq '') {
        Write-Host 'ABORT: the grid probe never answered - the shell never ran it, not a verdict'
        exit 1
    }
    Write-Host "OK    setup control: the pane reports its grid ($base)"

    # --- A. positive control: a real resize moves the number ----------------
    Assert (Set-TestWindowSize -Window $top -Width -160 -Height -120 -Grow) 'A the window was resized'
    Start-Sleep -Milliseconds 1200
    $resized = Get-PaneGrid 'pgs' 'resized'
    Assert ($resized -ne '' -and $resized -ne $base) `
        "A the reported grid followed a real window resize ($base -> $resized)"
    if ($resized -eq '') {
        Write-Host 'ABORT: no post-resize reading; later arms have no baseline'
        exit 1
    }

    # --- D baseline: this pane's scrollbar, before any popup exists --------
    $barsBefore = Get-VisibleScrollbars $top

    # --- B. the palette ----------------------------------------------------
    $palette = Open-Palette $top $pane
    if ($palette -ne [IntPtr]::Zero) {
        $script:pass++; Write-Host 'PASS  B the palette opened'
        Assert (Send-OwnSize $palette) "B the palette was sent its own WM_SIZE"
        Start-Sleep -Milliseconds 500
        Close-Popup $palette
        $afterPalette = Get-PaneGrid 'pgs' 'palette'
        Assert ($afterPalette -eq $resized) `
            "B the grid is unchanged across a palette open/WM_SIZE/close ($resized -> $afterPalette)"
    } else {
        Skip 'B palette: ctrl+shift+p did not raise the palette popup'
        Skip 'B palette WM_SIZE (no palette to send it to)'
        Skip 'B palette grid comparison (no palette to open)'
    }

    # --- C. the search bar --------------------------------------------------
    $search = Open-Search $top $pane
    if ($search -ne [IntPtr]::Zero) {
        $script:pass++; Write-Host 'PASS  C the search bar opened'
        Assert (Send-OwnSize $search) "C the search bar was sent its own WM_SIZE"
        Start-Sleep -Milliseconds 500
        Close-Popup $search
        $afterSearch = Get-PaneGrid 'pgs' 'search'
        Assert ($afterSearch -eq $resized) `
            "C the grid is unchanged across a search-bar open/WM_SIZE/close ($resized -> $afterSearch)"
    } else {
        Skip 'C search bar: ctrl+shift+f did not raise the search popup'
        Skip 'C search-bar WM_SIZE (no search bar to send it to)'
        Skip 'C search-bar grid comparison (no search bar to open)'
    }

    # --- D. the scrollbar overlay -------------------------------------------
    if ($barsBefore -gt 0) {
        Assert ((Get-VisibleScrollbars $top) -eq $barsBefore) `
            "D the window's scrollbar overlay is still visible after both popup toggles ($barsBefore)"
    } else {
        Skip "D scrollbar visibility: this window had no visible scrollbar to begin with"
    }

    # --- E. an injected WM_CHAR at the palette does not type in the terminal -
    # Last arm: on a broken build the characters land on the shell's command
    # line, and nothing after this could read a clean probe.
    $palette2 = Open-Palette $top $pane
    if ($palette2 -ne [IntPtr]::Zero) {
        # 'ZQXJ' - four letters no prompt or path in this run contains, so a
        # match in the pane's text can only be the injection arriving.
        foreach ($ch in @(0x5A, 0x51, 0x58, 0x4A)) {
            [void](Invoke-TestMessage -Window $palette2 -Message 0x0102 -WParam ([IntPtr]$ch) -LParam ([IntPtr]1))
        }
        Start-Sleep -Milliseconds 500
        Close-Popup $palette2
        Run-Cli '+read --name=pgs --lines=200' (Join-Path $work 'read-char.txt') 10 | Out-Null
        $paneText = Out-Text (Join-Path $work 'read-char.txt')
        Assert ($paneText -notmatch 'ZQXJ') `
            'E a WM_CHAR injected at the palette popup did not reach the terminal'
    } else {
        Skip 'E injected WM_CHAR (the palette did not open a second time)'
    }

} catch {
    # A scoring catch, not a swallow: without it an unwind here would skip the
    # rest of the run and still reach a green verdict (body-complete-audit D1).
    Write-Host "FAIL  harness error: $_" -ForegroundColor Red
    $script:fail++
} finally {
    Run-Cli '+close --target=pgs' (Join-Path $work 'close.txt') 10 | Out-Null
    Remove-TestDesktop
    Kill-RepoInstances
}

$fgSeen = @(Stop-TestForegroundWatch)
Write-Host "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @(Get-TestLaunchedPids)
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'no test-desktop app ever became foreground on the interactive desktop'
}

Complete-TestBody  # T1039: the last statement of the body an unwind can skip

Write-Host ''
if ($script:fail -eq 0) {
    # A clean green run records the covered files so scripts\guard-due.ps1
    # can answer "has anyone run this harness against the code as it now
    # stands?" (T783). Red runs leave the stamp alone - red must stay due.
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard palette-grid-size -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Skipped $script:skipped -Label 'PALETTE GRID SIZE'
