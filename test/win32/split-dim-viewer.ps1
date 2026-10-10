# T1809 acceptance: a VIEWER pane NEVER gets the unfocused-split dim overlay,
# and focus moving into a viewer still moves the dim onto the terminal.
#
# History: T380 gave viewer panes the T74 overlay. The user then reported an
# HTML pane that dimmed and never undimmed, and directed that viewer panes
# never dim at all (2026-10-10) - which is also Mac's behavior. The stranding
# cause: a click into the web content hands focus to WebView2's own child
# window, so the viewer's host never saw WM_SETFOCUS, never became the tab's
# active pane, and kept its dim while the user worked in it. T1809 removed the
# viewer dim and subscribed WebView2's GotFocus so the active pane follows
# that click.
#
# One GUI launch, defaults pinned (--background=#101014 -> alpha 77, fill
# 16,16,20 - the same numbers split-dim.ps1 run 1 asserts for terminals). In
# EVERY step, no GhozttyDimOverlay window (visible or hidden) may cover the
# viewer, and at most one overlay window may exist (the terminal's):
#
#   1. +split --view=<md>: the new viewer pane is focused, so the TERMINAL is
#      dimmed (positive control: the dim machinery is alive).
#   2. Focus the terminal: NO visible overlay (the viewer does not dim).
#   2b. goto_split into the viewer: the terminal dims again; a posted click on
#      the terminal clears it.
#   2c. Focus put STRAIGHT into Chromium's input window (the click path that
#      skips the host's WM_SETFOCUS): the terminal must dim, which only
#      happens if the viewer became the active pane through GotFocus.
#   3. Resize: still nothing over the viewer; the terminal overlay re-glues.
#   4. Zoom/unzoom and 5. a tab switch: nothing over the viewer, ever.
#
# Oracles are window enumeration (rects, visibility) plus, for the terminal
# overlay, GetLayeredWindowAttributes and the overlay's own painted fill - see
# split-dim.ps1's header for why there is no composited screen to probe here.
#
# The focus flips are posted clicks/chords (Send-TestMouse/Send-TestKeys): the
# terminal surface's WM_LBUTTONDOWN handler defers SetFocus itself (App.zig),
# so this works on the background test desktop where real input does not
# exist. -NegativeControl inverts the step-2 assertion to prove the oracle can
# fail.
#
# Only touches ghoztty processes running from this repo's zig-out*.
param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }
# Always isolate the IPC endpoint: the app inherits this env through
# CreateProcessW and so does every `& $exe +...` below, so the user's own
# instance is never queried or disturbed.
$env:GHOZTTY_PIPE_SUFFIX = "-dimviewtest$PID"
$errlog = Join-Path $env:TEMP 'ghoztty-split-dim-viewer-stderr.log'

. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
Assert-GhozttyIsolatedBuild -Exe $exe | Out-Null
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$script:pass = 0
$script:fail = 0
$script:negReached = $false

function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

# The AGENT too (T248): +new-window/+split are idempotent against a PERSISTED
# session, and killing ghoztty.exe does not remove one.
function Stop-RepoInstances {
    # T351: one shared, path-exact kill (lib\CleanSlate.ps1) instead of a private
    # copy - the filter this replaced also matched a detached instance running from
    # zig-out-release (T53b), and every copy answered "does the agent go too" alone.
    [void](Stop-RepoGhoztty -Exe $exe -SettleMs 800)
}

function Rects-Match($a, $b, [int]$slack = 2) {
    ([math]::Abs($a.Left - $b.Left) -le $slack) -and
    ([math]::Abs($a.Top - $b.Top) -le $slack) -and
    ([math]::Abs($a.Right - $b.Right) -le $slack) -and
    ([math]::Abs($a.Bottom - $b.Bottom) -le $slack)
}

function Get-Overlays([int]$procId) {
    return @(Get-TestWindows -ProcessId $procId -Class 'GhozttyDimOverlay')
}

# Poll until exactly one visible overlay covers $pane (T48 defers focus, so
# the flip lands asynchronously). The rect is re-read each poll, so this also
# serves the resize step.
function Wait-OverlayOverHwnd([int]$procId, [IntPtr]$paneHwnd) {
    for ($t = 0; $t -lt 25; $t++) {
        $rect = Get-TestWindowRect -Window $paneHwnd
        $ov = @(Get-Overlays $procId | Where-Object Visible)
        if ($ov.Count -eq 1 -and $rect -and (Rects-Match $ov[0] $rect)) { return $ov }
        Start-Sleep -Milliseconds 100
    }
    $rect = Get-TestWindowRect -Window $paneHwnd
    if ($rect) { Write-Host "DEBUG wait timeout: want pane $($rect.Left),$($rect.Top),$($rect.Right),$($rect.Bottom)" }
    Get-Overlays $procId | ForEach-Object {
        Write-Host "DEBUG raw overlay: $($_.Hwnd) vis=$($_.Visible) $($_.Left),$($_.Top),$($_.Right),$($_.Bottom)"
    }
    return @(Get-Overlays $procId | Where-Object Visible)
}

function Wait-NoOverlays([int]$procId) {
    for ($t = 0; $t -lt 25; $t++) {
        $ov = @(Get-Overlays $procId | Where-Object Visible)
        if ($ov.Count -eq 0) { return $ov }
        Start-Sleep -Milliseconds 100
    }
    return @(Get-Overlays $procId | Where-Object Visible)
}

# The T1809 invariant, checked against EVERY overlay window the process owns,
# hidden ones included: none may cover the viewer, and a viewer never owns
# one, so there is at most one in the whole process (the terminal's).
function Assert-ViewerNeverDimmed([string]$when) {
    $all = @(Get-Overlays $app.Pid)
    $vr = Get-TestWindowRect -Window $viewH
    $over = @($all | Where-Object { $vr -and (Rects-Match $_ $vr) })
    Assert ($over.Count -eq 0) "${when}: no dim overlay window covers the viewer ($($over.Count))"
    Assert ($all.Count -le 1) "${when}: at most one overlay window exists, the terminal's ($($all.Count))"
}

# The overlay's OWN painted fill, as "r,g,b" (split-dim.ps1's migrated oracle,
# synchronous since T943 - the overlay is layered, which is the shape T835's
# torn capture was measured on; a capture taken before its first paint throws
# and is retried rather than scored). -AllowUniform for the same reason it
# carries there (T1283): a solid-fill overlay is one colour by design, T303's
# refusal reads that as an empty capture, and what keeps the probe honest
# without it is that the assertion pins an exact colour a dead capture cannot
# produce.
function Get-OverlayFill($overlay) {
    $h = [IntPtr]$overlay.Hwnd
    for ($t = 0; $t -lt 10; $t++) {
        $shot = $null
        try {
            $shot = Get-TestWindowPixels -Window $h -Sync -AllowUniform
            $cx = [int](($overlay.Left + $overlay.Right) / 2)
            $cy = [int](($overlay.Top + $overlay.Bottom) / 2)
            $c = Get-TestPixel -Shot $shot -X $cx -Y $cy
            if (-not $c) { return $null }
            return "$($c.R),$($c.G),$($c.B)"
        } catch {
            if ($t -eq 9) {
                Write-Host "DEBUG overlay capture failed: $_"
                return $null
            }
            Start-Sleep -Milliseconds 150
        } finally {
            if ($shot) { Close-TestWindowPixels -Shot $shot }
        }
    }
    return $null
}

Stop-RepoInstances

# Watch the user's desktop for the whole run: nothing we launch may ever take
# foreground there (T211, asserted).
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$launched = @()

# The viewed document. Content is irrelevant to the overlay; a real md file
# keeps the pane on the file-mode path with zero network.
$md = Join-Path $env:TEMP 'ghoztty-dim-viewer.md'
Set-Content -Path $md -Value "# Dim overlay fixture`n`nsome text`n" -Encoding ascii

try {
    if ($NegativeControl) {
        Write-Host 'NEGATIVE CONTROL: step 2 asserts the VIEWER is dimmed after the terminal is focused - this run MUST fail'
    }

    Remove-Item $errlog -ErrorAction SilentlyContinue
    $sp = @{ Exe = $exe; Arguments = @('--session-persistence=false', '--background=#101014') }
    if (-not $ExePath) { $sp.StdErr = $errlog }
    $app = Start-OnTestDesktop @sp
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: top window not found'; exit 1 }
    $launched += $script:GhozttyTestDesktopPids

    Assert (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) `
        'window is NOT enumerable on the interactive desktop'

    # --focus: CLI splits open in the background since T1797, and step 1
    # needs the viewer to be the focused pane.
    & $exe +split --direction=down "--view=$md" --focus | Out-Null
    Start-Sleep -Milliseconds 800
    $terms = @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal')
    $views = @(Get-TestChildWindows -Window $top -Class 'GhozttyViewer')
    Assert ($terms.Count -eq 1 -and $views.Count -eq 1) `
        "setup: one terminal + one viewer pane (got $($terms.Count)/$($views.Count))"
    if ($terms.Count -ne 1 -or $views.Count -ne 1) {
        Stop-Process -Id $app.Pid -Force -ErrorAction SilentlyContinue; exit 1
    }
    $term = $terms[0]; $view = $views[0]
    $termH = [IntPtr]$term.Hwnd; $viewH = [IntPtr]$view.Hwnd

    # -----------------------------------------------------------------------
    # 1. The viewer is the focused pane after its split (insertPaneAsSplit
    #    makes it the active pane synchronously): the ONE overlay is over the
    #    terminal. MUST run before any Send-TestKeys - the harness delivers
    #    chords via AttachThreadInput+SetFocus on its target, which is itself
    #    a focus flip.
    # -----------------------------------------------------------------------
    $ov = @(Wait-OverlayOverHwnd $app.Pid $termH)
    Assert ($ov.Count -eq 1) "viewer focused: exactly one visible overlay ($($ov.Count))"
    if ($ov.Count -eq 1) {
        Assert (Rects-Match $ov[0] $term) 'viewer focused: overlay covers the TERMINAL pane (positive control)'
        $la = Get-TestLayeredAttrs -Window ([IntPtr]$ov[0].Hwnd)
        Assert ($la.Ok -and $la.Alpha -eq 77) "terminal overlay: layered alpha is 77 = (1-0.7)*255 (got $($la.Alpha))"
        $fill = Get-OverlayFill $ov[0]
        Assert ($fill -eq '16,16,20') "terminal overlay paints the background color #101014 (got $fill)"
    }
    Assert-ViewerNeverDimmed 'viewer focused'

    # Positive control: a chord posted at the terminal reaches binding dispatch
    # (debug log only) - the zoom/tab steps below depend on it. Side effect,
    # relied on by step 2: delivering it focuses the TERMINAL.
    $r = Send-TestKeys -Window $top -Target $termH -Modifiers ctrl -Key K
    if (-not $r) { Write-Host 'ABORT: control chord not sent'; Stop-Process -Id $app.Pid -Force -ErrorAction SilentlyContinue; exit 1 }
    Start-Sleep -Milliseconds 300
    if (Test-Path $errlog) {
        if (-not (Select-String -Path $errlog -Pattern 'clear_screen' -Quiet)) {
            Write-Host 'ABORT: positive control failed (clear_screen never dispatched) - injection broken, not a T1809 verdict'
            Stop-Process -Id $app.Pid -Force -ErrorAction SilentlyContinue; exit 1
        }
        Write-Host 'OK    positive control: injection reaches bindings (clear_screen dispatched)'
    } else {
        Write-Host 'OK    positive control degraded: no debug log (release build), chord delivery only'
    }

    # -----------------------------------------------------------------------
    # 2. The terminal now has focus: its overlay is gone and the viewer did
    #    NOT take one (the T380 behavior T1809 removes).
    # -----------------------------------------------------------------------
    $ov = @(Wait-NoOverlays $app.Pid)
    $script:negReached = $true
    if ($NegativeControl) {
        Assert ($ov.Count -eq 1 -and (Rects-Match $ov[0] $view)) `
            'NEGATIVE: the viewer is dimmed after the terminal took focus'
    } else {
        Assert ($ov.Count -eq 0) "terminal focused: no visible overlay - the viewer never dims ($($ov.Count))"
        Assert-ViewerNeverDimmed 'terminal focused'
    }

    # -----------------------------------------------------------------------
    # 2b. goto_split down (at the terminal) hands focus to the VIEWER through
    #     the T48 deferred-SetFocus path: the terminal dims. Then a posted
    #     click on the terminal clears it, and nothing lands on the viewer.
    # -----------------------------------------------------------------------
    $r = Send-TestKeys -Window $top -Target $termH -Modifiers ctrl,alt -Key Down
    Assert $r 'goto-down chord delivered'
    $ov = @(Wait-OverlayOverHwnd $app.Pid $termH)
    Assert ($ov.Count -eq 1 -and (Rects-Match $ov[0] $term)) `
        'goto_split into the viewer: the terminal dims'
    Assert-ViewerNeverDimmed 'goto_split into the viewer'

    $cx = [int](($term.Left + $term.Right) / 2)
    $cy = [int](($term.Top + $term.Bottom) / 2)
    $r = Send-TestMouse -Window $top -Target $termH -X $cx -Y $cy
    Assert $r 'terminal click delivered'
    $ov = @(Wait-NoOverlays $app.Pid)
    Assert ($ov.Count -eq 0) "terminal clicked: no visible overlay ($($ov.Count))"
    Assert-ViewerNeverDimmed 'terminal clicked'

    # -----------------------------------------------------------------------
    # 2c. Focus straight into the page - what a click on web content does.
    #     The host never sees WM_SETFOCUS on this path; only WebView2's
    #     GotFocus says it happened. If the viewer became the active pane the
    #     terminal dims; before T1809 the terminal stayed lit and the viewer
    #     stayed dimmed.
    # -----------------------------------------------------------------------
    $chrome = [IntPtr]::Zero
    for ($t = 0; $t -lt 50 -and $chrome -eq [IntPtr]::Zero; $t++) {
        $kids = @(Get-TestChildWindows -Window $viewH -Class '*')
        $widget = @($kids | Where-Object { $_.Class -eq 'Chrome_RenderWidgetHostHWND' })
        if ($widget.Count -lt 1) { $widget = @($kids | Where-Object { $_.Class -eq 'Chrome_WidgetWin_1' }) }
        if ($widget.Count -ge 1) { $chrome = [IntPtr][int64]$widget[0].Hwnd }
        else { Start-Sleep -Milliseconds 200 }
    }
    Assert ($chrome -ne [IntPtr]::Zero) 'the viewer Chromium input window is up'
    if ($chrome -ne [IntPtr]::Zero) {
        $vr = Get-TestWindowRect -Window $viewH
        $vx = [int](($vr.Left + $vr.Right) / 2)
        $vy = [int](($vr.Top + $vr.Bottom) / 2)
        $r = Send-TestMouse -Window $top -Target $chrome -X $vx -Y $vy
        Write-Host "DEBUG click into Chromium ($chrome $((Get-TestWindowClass -Window $chrome))) returned $r"
        $ov = @(Wait-OverlayOverHwnd $app.Pid $termH)
        Assert ($ov.Count -eq 1 -and (Rects-Match $ov[0] $term)) `
            'focus straight into the page: the viewer becomes the active pane and the terminal dims (GotFocus)'
        Assert-ViewerNeverDimmed 'focus straight into the page'
        # Hand the keyboard back to the terminal for the steps below.
        $r = Send-TestMouse -Window $top -Target $termH -X $cx -Y $cy
        $ov = @(Wait-NoOverlays $app.Pid)
        Assert ($ov.Count -eq 0) "terminal clicked after the page: no visible overlay ($($ov.Count))"
    }

    # -----------------------------------------------------------------------
    # 3. Resize: nothing over the viewer; with the viewer focused, the
    #    terminal's overlay re-glues to the terminal's new rect.
    # -----------------------------------------------------------------------
    $topRect = Get-TestWindowRect -Window $top
    $newW = ($topRect.Right - $topRect.Left) - 120
    $newH = ($topRect.Bottom - $topRect.Top) - 80
    Set-TestWindowSize -Window $top -Width $newW -Height $newH | Out-Null
    $ov = @(Wait-NoOverlays $app.Pid)
    Assert ($ov.Count -eq 0) "resize, terminal focused: no visible overlay ($($ov.Count))"
    Assert-ViewerNeverDimmed 'resize'
    $r = Send-TestKeys -Window $top -Target $termH -Modifiers ctrl,alt -Key Down
    Assert $r 'goto-down chord delivered after resize'
    $ov = @(Wait-OverlayOverHwnd $app.Pid $termH)
    Assert ($ov.Count -eq 1 -and (Rects-Match $ov[0] (Get-TestWindowRect -Window $termH))) `
        'resize, viewer focused: terminal overlay re-glued to the terminal rect'
    Assert-ViewerNeverDimmed 'resize, viewer focused'
    $term = Get-TestWindowRect -Window $termH
    $cx = [int](($term.Left + $term.Right) / 2)
    $cy = [int](($term.Top + $term.Bottom) / 2)
    $r = Send-TestMouse -Window $top -Target $termH -X $cx -Y $cy
    $ov = @(Wait-NoOverlays $app.Pid)
    Assert ($ov.Count -eq 0) "terminal clicked after resize: no visible overlay ($($ov.Count))"

    # -----------------------------------------------------------------------
    # 4. Zoom the (focused) terminal and unzoom: nothing over the viewer.
    # -----------------------------------------------------------------------
    $r = Send-TestKeys -Window $top -Target $termH -Modifiers ctrl,shift -Key Enter
    Assert $r 'zoom chord delivered'
    $ov = @(Wait-NoOverlays $app.Pid)
    Assert ($ov.Count -eq 0) "zoomed: no visible overlay ($($ov.Count))"
    $r = Send-TestKeys -Window $top -Target $termH -Modifiers ctrl,shift -Key Enter
    Assert $r 'unzoom chord delivered'
    Start-Sleep -Milliseconds 500
    $ov = @(Wait-NoOverlays $app.Pid)
    Assert ($ov.Count -eq 0) "unzoomed, terminal focused: no visible overlay ($($ov.Count))"
    Assert-ViewerNeverDimmed 'unzoom'

    # -----------------------------------------------------------------------
    # 5. Tab switch away and back: nothing over the viewer.
    # -----------------------------------------------------------------------
    $r = Send-TestKeys -Window $top -Target $termH -Modifiers ctrl -Key T
    Assert $r 'new-tab chord delivered'
    $ov = @(Wait-NoOverlays $app.Pid)
    Assert ($ov.Count -eq 0) "tab 2 active: no visible overlay ($($ov.Count))"
    $t2 = @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal' | Where-Object Visible)
    if ($t2.Count -ge 1) {
        $r = Send-TestKeys -Window $top -Target ([IntPtr]$t2[0].Hwnd) -Modifiers ctrl -Key '1'
        Assert $r 'goto-tab-1 chord delivered'
        Start-Sleep -Milliseconds 500
        Assert-ViewerNeverDimmed 'tab 1 active again'
    } else {
        Assert $false 'tab 2 terminal pane found for the return chord'
    }

    Assert (-not ($app.Process -and $app.Process.HasExited)) 'no crash'
    Stop-Process -Id $app.Pid -Force -ErrorAction SilentlyContinue
} finally {
    Remove-TestDesktop
    Stop-RepoInstances
    Remove-Item $md -ErrorAction SilentlyContinue
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

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILED / $script:pass passed" -ForegroundColor Red; exit 1 }
