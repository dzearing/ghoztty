# T78 acceptance: window-title-font-family drives the tab bar font.
#
# The DWM caption of a standard-frame window always draws with the system
# caption font, so on Windows this config applies where the app renders
# titles itself: the owner-drawn tab bar (createTabFont in Window.zig).
#
# Oracle: a per-column "lit pixel" signature of the tab-bar strip (tab title
# text + the "+" new-tab glyph, all drawn with tab_font). A different font
# family produces a different glyph raster; the same family reproduces the
# same raster (owner-drawn into a mem DC, so rendering is window-relative
# and deterministic).
#
#   1. Launch A (default font, --window-show-tab-bar=always so a single tab
#      shows the bar) -> bar visible (positive control), signature non-empty.
#   2. Launch B (--window-title-font-family="Times New Roman") -> signature
#      differs from A (the config changes the tab bar raster).
#   3. Launch C (same family, but via --config-file) -> signature matches B
#      (negative control + the config-file path works).
#   4. Edit the config file back to Segoe UI + ctrl+shift+comma reload ->
#      signature changes live without a relaunch (onConfigChange path).
#   5. (T1591, debug builds) the reload's own logged update region covers the
#      tab bar band. Step 4 alone cannot fail on a reload that never asks for
#      the repaint, because the PrintWindow capture repaints the strip itself;
#      this is the T252/T765 second oracle that can.
#
# T218: migrated onto the BACKGROUND test desktop (test/win32/lib/TestDesktop.ps1),
# so it never takes the user's foreground - asserted here, not assumed. Three
# mechanism swaps, all forced by the desktop:
#
#   * The signature is read from a PrintWindow capture instead of a screen-DC
#     GetPixel sweep (the SYNCHRONOUS one since T941, so the window draws the
#     frame itself). The tab bar is GDI-painted CHROME, which is the
#     half of the CAPTURE LIMIT that survives on a background desktop (the
#     OpenGL terminal surface is the half that does not) - so this probe
#     migrates as-is, and Get-TestDistinctColors guards every signature against
#     scoring a mid-paint flat fill.
#   * The reload chord goes through Send-TestKeys (posted, focus set in a
#     shared input queue) instead of SendInput behind a foreground grab.
#   * The cursor parking is GONE, and deliberately: it existed so tab hover
#     chrome could not pollute the sample, and a background desktop has no
#     pointer over the window at all. SetCursorPos there is also a no-op the
#     app cannot read back (T216).
#
# -NegativeControl inverts assertion 2 (asserts Times New Roman reproduces the
# DEFAULT raster) and MUST fail; it is how a run proves the signature actually
# discriminates fonts rather than reading noise.
#
# Only touches ghoztty processes from this repo's zig-out.
param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')   # T271/T1768: arms the run, so the stamp below is refused for a body that unwound or asserted nothing
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }
$env:GHOZTTY_PIPE_SUFFIX = "-titlefonttest$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Kill-RepoInstances {
    # T351: one shared, path-exact kill (lib\CleanSlate.ps1) instead of a private
    # copy - the filter this replaced also matched a detached instance running from
    # zig-out-release (T53b), and every copy answered "does the agent go too" alone.
    [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
}

# Launch the GUI onto the test desktop with the given extra args and measure
# the geometry the signature is sampled from. The tab bar is up (always + 1
# tab). Returns $null if the launch died or never showed a window.
function Launch-Gui([string[]]$extraArgs, [string]$errPath) {
    # --session-persistence=false: each launch would otherwise write a layout
    # manifest that the next one restores (T131).
    $args_ = @(
        '--config-default-files=false', '--background=#000000',
        '--window-show-tab-bar=always', '--session-persistence=false',
        # T1591: a fixed title, so the strip's text is the same string in
        # every capture. Unpinned, the shell retitles the tab some time after
        # launch, and a capture on either side of that scored a 1012-column
        # diff between two launches of the SAME font.
        '--title=Ghoztty font probe'
    ) + $extraArgs
    $sp = @{ Exe = $exe; Arguments = $args_ }
    if ($errPath) { Remove-Item $errPath -ErrorAction SilentlyContinue; $sp.StdErr = $errPath }
    $app = Start-OnTestDesktop @sp
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { return $null }
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { Stop-Process -Id $app.Pid -Force -ErrorAction SilentlyContinue; return $null }
    $pane = Get-TestChildWindow -Window $top -Class 'GhozttyTerminal'
    if ($pane -eq [IntPtr]::Zero) { Stop-Process -Id $app.Pid -Force -ErrorAction SilentlyContinue; return $null }
    $pr = Get-TestWindowRect -Window $pane
    $cr = Get-TestWindowRect -Window $top -Client
    [pscustomobject]@{
        App = $app; Top = $top; Surface = $pane
        ClientLeft = $cr.Left; ClientTop = $cr.Top; BarH = ($pr.Top - $cr.Top)
    }
}

# Per-column count of "lit" (text-colored) pixels in a screen rect of a
# PrintWindow capture: R+G+B > 300 against the dark bar. Screen coordinates in,
# window-relative reads out - the bitmap is addressed directly rather than
# through Get-TestPixel because this is thousands of samples per signature.
function Get-ColSig($shot, [int]$x0, [int]$x1, [int]$y0, [int]$y1, [int]$step) {
    $cols = New-Object System.Collections.Generic.List[int]
    for ($x = $x0; $x -le $x1; $x += $step) {
        $lx = $x - $shot.Left
        if ($lx -lt 0 -or $lx -ge $shot.Width) { $cols.Add(0); continue }
        $lit = 0
        for ($y = $y0; $y -le $y1; $y++) {
            $ly = $y - $shot.Top
            if ($ly -lt 0 -or $ly -ge $shot.Height) { continue }
            $c = $shot.Bitmap.GetPixel($lx, $ly)
            if (($c.R + $c.G + $c.B) -gt 300) { $lit++ }
        }
        $cols.Add($lit)
    }
    return $cols.ToArray()
}

# Signature across the single tab (title text region) + the "+" button.
# 1 tab: tabW = clamp(clientW-..., 60s, 200s) = 200s on any normal window.
# barH is 40 DIP since T232 (4 + 4 + 28 + 4), and the strip's text pad is 8.
#
# The capture is retried until it holds real content: an empty capture scores a
# perfectly stable all-zero signature that would make every "same raster"
# assertion pass for the wrong reason (the T216 lesson). Under -Sync (T941) the
# window paints on demand, so what the retry covers is a window whose chrome is
# not built yet rather than a frame photographed mid-paint.
function Get-Signature($g) {
    $scale = $g.BarH / 40.0
    $tabW = Get-TestChromeDip -Dip 200 -Scale $scale
    $plusW = (Get-TestChromeDip -Dip 8 -Scale $scale) + (Get-TestChromeDip -Dip 28 -Scale $scale)
    # T1591: the sample starts at the tab, past the strip's leading slot
    # (~54 DIP, measured 2026-11-20). That slot sometimes draws a light panel
    # with an icon and title text (T3293) and sometimes does
    # not, which scored a ~1000-column diff between two launches of one font.
    $lead = Get-TestChromeDip -Dip 56 -Scale $scale
    $x0 = $g.ClientLeft + $lead + (Get-TestChromeDip -Dip 8 -Scale $scale)    # text pad
    $x1 = $g.ClientLeft + $lead + $tabW + $plusW - 2           # through the + glyph
    $y0 = $g.ClientTop + 4
    $y1 = $g.ClientTop + $g.BarH - 5                   # skip accent-stripe rows
    for ($t = 0; $t -lt 20; $t++) {
        $shot = Get-TestWindowPixels -Window $g.Top -Sync
        try {
            if ((Get-TestDistinctColors -Shot $shot) -ge 8) {
                return (Get-ColSig $shot ([int]$x0) ([int]$x1) ([int]$y0) ([int]$y1) 2)
            }
        } finally { Close-TestWindowPixels $shot }
        Start-Sleep -Milliseconds 150
    }
    return @()
}

function Sig-Diff([int[]]$a, [int[]]$b) {
    $n = [math]::Min($a.Count, $b.Count)
    $d = 0
    for ($i = 0; $i -lt $n; $i++) { $d += [math]::Abs($a[$i] - $b[$i]) }
    $d + [math]::Abs($a.Count - $b.Count) * 10
}

Kill-RepoInstances

# Watch the user's desktop for the whole run: nothing we launch may ever take
# foreground there. That is the complaint the test desktop exists to fix.
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$conf = Join-Path $env:TEMP 'ghoztty-titlefont-test.conf'
if ($NegativeControl) {
    Write-Host 'NEGATIVE CONTROL: asserts Times New Roman reproduces the DEFAULT raster - this run MUST fail'
}

try {
    # -----------------------------------------------------------------------
    # Launch A: default font
    # -----------------------------------------------------------------------
    $a = Launch-Gui @()
    if ($null -eq $a) { Write-Host 'SETUP FAIL: launch A died'; exit 1 }
    Assert (-not (Test-TestDesktopLeak -ProcessId $a.App.Pid)) `
        'launch A is NOT enumerable on the interactive desktop'
    Assert ($a.BarH -ge 20 -and $a.BarH -le 80) "positive control: tab bar visible with 1 tab + always (barH=$($a.BarH))"
    $sigA = Get-Signature $a
    $litA = ($sigA | Measure-Object -Sum).Sum
    Assert ($litA -gt 20) "default font: tab bar draws text (lit=$litA)"
    Stop-Process -Id $a.App.Pid -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500

    # -----------------------------------------------------------------------
    # Launch B: Times New Roman via CLI
    # -----------------------------------------------------------------------
    $b = Launch-Gui @('--window-title-font-family=Times New Roman')
    if ($null -eq $b) { Write-Host 'SETUP FAIL: launch B died'; exit 1 }
    Assert ($b.BarH -eq $a.BarH) "bar height unchanged by font family (barH=$($b.BarH))"
    $sigB = Get-Signature $b
    $dAB = Sig-Diff $sigA $sigB
    if ($NegativeControl) {
        Assert ($dAB -le 15) "NEGATIVE CONTROL: font family leaves the raster alone (diff A-vs-B=$dAB)"
    } else {
        Assert ($dAB -ge 25) "font family changes the tab bar raster (diff A-vs-B=$dAB)"
    }
    Stop-Process -Id $b.App.Pid -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500

    # -----------------------------------------------------------------------
    # Launch C: same family via --config-file, then live reload back to Segoe UI
    # -----------------------------------------------------------------------
    Set-Content -Path $conf -Value 'window-title-font-family = Times New Roman' -Encoding ascii
    $errC = Join-Path $env:TEMP "ghoztty-titlefont-stderr-$PID.log"
    $c = Launch-Gui @("--config-file=$conf") $errC
    if ($null -eq $c) { Write-Host 'SETUP FAIL: launch C died'; exit 1 }
    $sigC = Get-Signature $c
    $dBC = Sig-Diff $sigB $sigC
    Assert ($dBC -le 15) "same family reproduces the raster / config-file path works (diff B-vs-C=$dBC)"

    Set-Content -Path $conf -Value 'window-title-font-family = Segoe UI' -Encoding ascii
    # T1591: dropped before the chord so the log oracle below can only read
    # THIS reload's line.
    if (Test-Path $errC) { Clear-Content $errC -ErrorAction SilentlyContinue }
    if (-not (Focus-TestWindow -Window $c.Top -Child $c.Surface)) {
        Write-Host 'SETUP FAIL: could not focus launch C'; exit 1
    }
    $r = Send-TestKeys -Window $c.Top -Target $c.Surface -Modifiers ctrl, shift -Key comma
    Assert $r "reload chord injected (ctrl+shift+comma)"
    $reloaded = $false
    $dCD = 0
    $sigD = @()
    for ($t = 0; $t -lt 15; $t++) {
        Start-Sleep -Milliseconds 300
        $sigD = Get-Signature $c
        $dCD = Sig-Diff $sigC $sigD
        if ($dCD -ge 25) { $reloaded = $true; break }
    }
    Assert $reloaded "config reload re-fonts the tab bar live (diff C-vs-D=$dCD)"

    # T1591: the LIVE half's second oracle. The raster diff above cannot fail
    # on a reload that forgets to repaint the strip: the capture is a
    # PrintWindow, which repaints the whole client from current state before it
    # photographs it, so it does the invalidate the product left out. What a
    # user on a real desktop depends on is that the reload ASKED for the
    # repaint, which the reload logs as a count of invalidateTabBar calls it
    # made (Window.onConfigChange). The window's update region cannot stand in
    # for it: under the default elevated pane style the reload also repaints
    # the desk, and that rect already touches the strip - measured, it is the
    # whole client with the strip's invalidate deleted. Debug builds only:
    # log.debug is compiled out of a release build, where the raster half
    # alone stands.
    $mode = Get-GhozttyBuildMode -Exe $exe
    if ($mode -eq 'Debug') {
        $askLog = @()
        for ($t = 0; $t -lt 10 -and $askLog.Count -eq 0; $t++) {
            $askLog = @(Select-String -Path $errC `
                    -Pattern 'config reload tab bar repaints asked=(\d+) visible=(\w+)' `
                    -ErrorAction SilentlyContinue)
            if ($askLog.Count -eq 0) { Start-Sleep -Milliseconds 200 }
        }
        if ($askLog.Count -eq 0) {
            Assert $false "the reload reported its tab bar repaints (log line missing from $errC)"
        } else {
            $m = $askLog[-1].Matches[0].Groups
            $asked = [int]$m[1].Value; $vis = $m[2].Value
            # In-band control: the same line proves the reload ran with a strip
            # to repaint, so asked=0 cannot be read as "nothing was showing".
            Assert ($vis -eq 'true') "in-band control: the reload saw the strip visible (visible=$vis)"
            Assert ($asked -gt 0) "the reload itself asked for the tab bar repaint (invalidateTabBar x$asked)"
        }
    } else {
        Write-Host "OK    log oracle degraded: build mode '$mode' has no debug log, raster half only"
    }

    if ($reloaded) {
        $dAD = Sig-Diff $sigA $sigD
        Assert ($dAD -le 15) "reloaded Segoe UI matches the default raster (diff A-vs-D=$dAD)"
    }

    Assert (-not ($c.App.Process -and $c.App.Process.HasExited)) 'no crash'
    # The try's last statement (body-complete-audit D1): an unwind above skips
    # it, so the verdict reads DID NOT FINISH instead of green.
    Complete-TestBody
} finally {
    Remove-TestDesktop
    Kill-RepoInstances
    Remove-Item $conf -ErrorAction SilentlyContinue
    if ($errC) { Remove-Item $errC -ErrorAction SilentlyContinue }
}

$fgSeen = @(Stop-TestForegroundWatch)
Write-Host "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @(Get-TestLaunchedPids)
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'no test-desktop app ever became foreground on the interactive desktop'
}

Write-Host ''
if ($script:fail -eq 0 -and -not $NegativeControl) {
    # A clean green run stamps the covered files (T783/T1768); red stays due.
    # Continue: under Stop, a stderr line from the native call through 2>&1
    # would throw in PowerShell 5.1.
    $ErrorActionPreference = 'Continue'
    $gdRepo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $gdRepo 'scripts\guard-due.ps1') `
        update -Guard title-font -Repo $gdRepo 2>&1 | ForEach-Object { "  $_" }
}
Write-TestVerdict -Label 'T78 TITLE FONT' -Pass $script:pass -Fail $script:fail
