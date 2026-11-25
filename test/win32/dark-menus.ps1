# T79 acceptance: context menus (TrackPopupMenuEx) must match the app
# theme. Pre-fix, both the terminal surface menu and the tab-bar menu drew
# with the classic LIGHT menu palette even on dark chrome.
#
# The fix routes `window-theme` through the undocumented uxtheme ordinals
# (SetPreferredAppMode #135 + FlushMenuThemes #136) at app init / config
# reload / WM_SETTINGCHANGE.
#
# Two GUI launches assert both directions:
#   run 1: --window-theme=dark  -> both menus render DARK  (avg lum < 90)
#   run 2: --window-theme=light -> both menus render LIGHT (avg lum > 160)
#
# Menus are found as visible '#32768' (menu-class) windows in the GUI's pid,
# opened by right-clicks - the surface menu via a click in the pane, the
# tab-bar menu via a click in the tab strip (window-show-tab-bar=always keeps
# it visible with one tab). The menu window is captured and its interior
# averaged. A menu that never appears is a SETUP FAIL (injection broken), not
# a theme verdict.
#
# T216: migrated onto the BACKGROUND test desktop (test/win32/lib/TestDesktop.ps1),
# so it never takes the user's foreground - asserted here, not assumed. This is
# the worked example for the mouse half of the migration, and it settled the
# two questions T212 could not answer from the keyboard spike:
#
#   * TrackPopupMenuEx DOES run on a background desktop. The menu appears,
#     paints, and dismisses on a posted Escape.
#   * PrintWindow reads a '#32768' menu with real content - menus are
#     GDI-painted chrome, which is exactly the half of the CAPTURE LIMIT that
#     survives (the OpenGL terminal surface is the half that does not).
#
# Clicks are POSTED (SendInput is refused off the input desktop), so they must
# name the window that would really have received them: the pane child for the
# surface menu, the top-level window for the tab strip. Menu keys go through
# Send-TestControlKey, which posts without touching focus - Send-TestKeys would
# SetFocus first and dismiss the menu it was meant to drive.
#
# -NegativeControl inverts run 1's expectation and MUST fail; it is how a run
# proves the brightness assertions still discriminate.
#
# Only touches ghoztty processes running from this repo's zig-out*.
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
$env:GHOZTTY_PIPE_SUFFIX = "-darkmenutest$PID"

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

# Right-click at a screen point, wait for a '#32768' menu window in $gpid,
# average its interior brightness, Escape it closed. Returns -1 if no menu
# appeared. $target is the hwnd the click is POSTED to (posted messages skip
# hit testing, so it has to be named explicitly).
function Measure-Menu([int]$gpid, [IntPtr]$top, [IntPtr]$target, [int]$sx, [int]$sy) {
    [void](Send-TestMouse -Window $top -Target $target -X $sx -Y $sy -Button right -Action click)
    $menu = Wait-TestPopupMenu -ProcessId $gpid -TimeoutMs 4000
    if ($menu -eq [IntPtr]::Zero) { return -1 }

    # Poll until the menu has actually PAINTED. A capture taken mid-paint comes
    # back solid black, and "solid black" satisfies the dark assertion below
    # for entirely the wrong reason - measured at 350ms in T216, where the same
    # menu read 0/1 color then and 52/53 colors a moment later. Requiring real
    # content is what keeps a dark verdict from being a capture-timing artifact.
    $b = -1
    for ($t = 0; $t -lt 20; $t++) {
        Start-Sleep -Milliseconds 150
        # Torn on purpose (T944): '#32768' is user32's popup-menu class, not
        # ours. We owner-draw the items, but the window and its WndProc belong
        # to Windows, which never answers WM_PRINTCLIENT for it - a -Sync
        # capture comes back as the untouched sentinel. The distinct-colors
        # gate above the brightness read is what keeps the torn frame honest.
        $shot = Get-TestWindowPixels -Window $menu -TornReason 'user32 popup menu (#32768): the WndProc is not ours and does not answer WM_PRINTCLIENT'
        try {
            $colors = Get-TestDistinctColors -Shot $shot -Whole
            if ($colors -ge 8) {
                # Default rect = the whole capture, inset 8px to skip the shadow
                # and the rounded border - the same inset the pre-migration
                # screen-grab used.
                $b = Get-TestBrightness -Shot $shot -Whole
                break
            }
        } finally {
            Close-TestWindowPixels $shot
        }
    }
    [void](Send-TestControlKey -Control $menu -Key Escape)
    Start-Sleep -Milliseconds 400
    return $b
}

function Run-Case([string]$label, [string]$themeArg, [bool]$expectDark) {
    Kill-RepoInstances
    # --session-persistence=false: each launch would otherwise write a layout
    # manifest that the next one restores (T131).
    $app = Start-OnTestDesktop -Exe $exe -Arguments @(
        '--session-persistence=false', $themeArg, '--window-show-tab-bar=always'
    )
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host "SETUP FAIL ($label): GUI died at launch"; exit 1 }
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { Write-Host "SETUP FAIL ($label): top window not found"; exit 1 }
    $surface = Get-TestChildWindow -Window $top -Class 'GhozttyTerminal'
    if ($surface -eq [IntPtr]::Zero) { Write-Host "SETUP FAIL ($label): surface not found"; exit 1 }

    Assert (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) `
        "$label window is NOT enumerable on the interactive desktop"

    if (-not (Focus-TestWindow -Window $top -Child $surface)) {
        Write-Host "SETUP FAIL ($label): could not focus the GUI"; Stop-Process -Id $app.Pid -Force; exit 1
    }

    # --- Surface context menu: right-click the middle of the pane. The click
    # is posted to the PANE, which is where a real one would land.
    $sr = Get-TestWindowRect -Window $surface
    $b = Measure-Menu $app.Pid $top $surface `
        ([int](($sr.Left + $sr.Right) / 2)) ([int](($sr.Top + $sr.Bottom) / 2))
    if ($b -lt 0) {
        Write-Host "SETUP FAIL ($label): surface menu never appeared or never painted (injection/capture broken, not a theme verdict)"
        Stop-Process -Id $app.Pid -Force; exit 1
    }
    if ($expectDark) { Assert ($b -lt 90) "$label surface menu is dark (avg $b < 90)" }
    else { Assert ($b -gt 160) "$label surface menu is light (avg $b > 160)" }

    # --- Tab-bar context menu: right-click inside the tab strip, which the
    # top-level window paints and handles (Window.zig WM_RBUTTONUP), so the
    # click is posted THERE. The bar is at the top of the client area (always
    # visible via config).
    # T1768: the click lands on the middle of the first TAB, asked of the
    # strip's own geometry. The literal it replaces, (60, 12) client px, was the
    # tab strip's top-left before the strip merged into the caption row (T205)
    # and moved to the pane sidebar's edge (T1900); there it is caption band,
    # which opens no menu, and the run read SETUP FAIL for a theme it never
    # reached.
    # The rect is the one the app PUBLISHES (T231), as tab-color.ps1 asks it,
    # and the right-click is retried as there: the first click after the
    # surface menu's Escape can land while that menu loop is still unwinding.
    $cr = Get-TestWindowRect -Window $top -Client
    $tabs = @((Get-TestStripRegions -Window $top -Exe $exe).Tabs | Where-Object { $null -ne $_ })
    if ($tabs.Count -lt 1) {
        Write-Host "SETUP FAIL ($label): the strip published no tab to right-click"
        Stop-Process -Id $app.Pid -Force; exit 1
    }
    $tabX = [int]($cr.Left + $tabs[0].CenterX)
    $tabY = [int]($cr.Top + $tabs[0].CenterY)
    $b = -1
    for ($try = 0; $try -lt 3 -and $b -lt 0; $try++) {
        $b = Measure-Menu $app.Pid $top $top $tabX $tabY
    }
    if ($b -lt 0) {
        Write-Host "SETUP FAIL ($label): tab-bar menu never appeared or never painted (injection/capture broken, not a theme verdict)"
        Stop-Process -Id $app.Pid -Force; exit 1
    }
    if ($expectDark) { Assert ($b -lt 90) "$label tab-bar menu is dark (avg $b < 90)" }
    else { Assert ($b -gt 160) "$label tab-bar menu is light (avg $b > 160)" }

    Assert (-not ($app.Process -and $app.Process.HasExited)) "$label no crash"
    Stop-Process -Id $app.Pid -Force -ErrorAction SilentlyContinue
}

Kill-RepoInstances

# Watch the user's desktop for the whole run: nothing we launch may ever take
# foreground there. That is the complaint the test desktop exists to fix.
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$launched = @()

try {
    # -NegativeControl flips run 1 to assert the DARK-themed menus are light,
    # so a passing run would mean the brightness probe reads everything.
    $run1Dark = -not $NegativeControl
    if ($NegativeControl) { Write-Host 'NEGATIVE CONTROL: run 1 asserts the dark-theme menus are LIGHT - this run MUST fail' }
    Run-Case 'dark' '--window-theme=dark' $run1Dark
    $launched += $script:GhozttyTestDesktopPids
    Run-Case 'light' '--window-theme=light' $false
    $launched += $script:GhozttyTestDesktopPids
    # The try's last statement (body-complete-audit D1): an unwind above skips
    # it, so the verdict reads DID NOT FINISH instead of green.
    Complete-TestBody
} finally {
    Remove-TestDesktop
    Kill-RepoInstances
}

$fgSeen = @(Stop-TestForegroundWatch)
Write-Host "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @($launched | Select-Object -Unique)
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) "no test-desktop app ever became foreground on the interactive desktop"
}

Write-Host ''
if ($script:fail -eq 0 -and -not $NegativeControl) {
    # A clean green run stamps the covered files (T783/T1768); red stays due.
    # Continue: under Stop, a stderr line from the native call through 2>&1
    # would throw in PowerShell 5.1.
    $ErrorActionPreference = 'Continue'
    $gdRepo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $gdRepo 'scripts\guard-due.ps1') `
        update -Guard dark-menus -Repo $gdRepo 2>&1 | ForEach-Object { "  $_" }
}
Write-TestVerdict -Label 'T79 DARK MENUS' -Pass $script:pass -Fail $script:fail
