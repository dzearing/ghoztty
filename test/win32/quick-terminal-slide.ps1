# T2766 acceptance: the quick terminal's slide in and out is carried by DWM on
# a slider thread of its own (src\apprt\win32\QuickTerminalSlider.zig), not by
# a SetWindowPos per frame-clock tick on the UI thread - so a busy UI thread
# no longer freezes it halfway onto the screen.
#
# Mechanism: the quick terminal sits at its final rect CLOAKED for the length
# of the slide; a click-through host window (class GhozttyQuickSlide, owned by
# the slider thread) shows a live DWM thumbnail of it and moves the
# thumbnail once per composition. The slide's numbers are unit-tested in
# src\apprt\win32\quick_terminal_slide.zig.
#
# Three arms, each a fresh app:
#
#   DWM (GHOZTTY_DEBUG_QT_SLIDE_STALL_MS=900, a 0.3 s slide): the UI thread
#   is blocked for 900 ms the moment each slide starts. The slider still
#   finishes the slide in about its 300 ms - measured on the slider thread,
#   `slide landed ... ms=` - which a slide stepped on the UI thread cannot do,
#   and it composed frames doing it. After landing in: the quick terminal is
#   shown at the top of the work area, UNcloaked (it takes input again) and
#   the host is down. After landing out: hidden, uncloaked, host down.
#   REVERSE (no stall, a 1.2 s slide): mid-slide the host is up and the quick
#   terminal is CLOAKED (no input until it lands); a second toggle turns the
#   slide round (`reversed dir=out`), and it lands hidden, uncloaked, host
#   down, nothing fell back.
#   STEPPED (GHOZTTY_DEBUG_QT_SLIDE_STEPPED=1): the A/B control - no slide is
#   handed to the slider, no host window is ever made, and the quick terminal
#   still lands shown at the same place.
#
# NOT covered here: what the slide LOOKS like on screen. A background desktop
# is not composed by DWM for the screen (CopyFromScreen is dead there), so the
# thumbnail's pixels cannot be photographed; the on-screen film (advance, hold,
# stepped A/B through the stall seam) is T2809's, on the real desktop.
#
# Runs on a BACKGROUND desktop (lib\TestDesktop.ps1) and never takes the
# user's foreground - asserted by the foreground watcher, not assumed.
# -NegativeControl demands the slider finish no sooner than the stall, which a
# working slider beats - so it MUST fail.
#
#   powershell -NoProfile -File test\win32\quick-terminal-slide.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [switch]$NegativeControl,
    [switch]$Interactive
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:passes = 0
$tmp = Join-Path $env:TEMP "ghoztty-t2766-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ } else { "  FAIL $name"; $script:failures++ }
}
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 't2766')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

if (-not ('T2766Dwm' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class T2766Dwm {
    [DllImport("dwmapi.dll")]
    static extern int DwmGetWindowAttribute(IntPtr hwnd, int attr, out int value, int size);
    // DWMWA_CLOAKED = 14: non-zero while the window is cloaked (by us: DWM_CLOAKED_APP = 1).
    public static int Cloaked(IntPtr hwnd) {
        int v;
        int hr = DwmGetWindowAttribute(hwnd, 14, out v, 4);
        return hr < 0 ? -1 : v;
    }
}
'@
}

function Get-LogLines([string]$Pattern) { @(Get-Content $script:errlog -ErrorAction SilentlyContinue | Where-Object { $_ -match $Pattern }) }
function Wait-Log([string]$Pattern, [int]$Ms = 6000, [int]$Count = 1) {
    $deadline = (Get-Date).AddMilliseconds($Ms)
    do {
        $hits = @(Get-LogLines $Pattern)
        if ($hits.Count -ge $Count) { return $hits[$Count - 1] }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)
    return $null
}
function Set-Active([IntPtr]$top, [IntPtr]$pane) {
    Focus-TestWindow -Window $top -Child $pane | Out-Null
    for ($t = 0; $t -lt 20; $t++) {
        if ((Get-TestActiveWindow -Window $top) -eq [int64]$top) { return $true }
        Start-Sleep -Milliseconds 100
    }
    return $false
}
# The quick terminal: the GhozttyWindow that is not the one the app opened with.
function Find-QuickTerminal([int]$AppPid, [int64[]]$Before) {
    for ($t = 0; $t -lt 40; $t++) {
        foreach ($w in @(Get-TestWindows -ProcessId $AppPid -Class 'GhozttyWindow' -AllowHidden)) {
            if ($Before -notcontains [int64]$w.Hwnd) { return [IntPtr]$w.Hwnd }
        }
        Start-Sleep -Milliseconds 150
    }
    return [IntPtr]::Zero
}
function Get-SlideHosts([int]$AppPid) { @(Get-TestWindows -ProcessId $AppPid -Class 'GhozttyQuickSlide' -AllowHidden) }
function Test-AnyHostShown([int]$AppPid) { @(Get-SlideHosts $AppPid | Where-Object { $_.Visible }).Count -gt 0 }

. (Join-Path $PSScriptRoot 'lib\Transcript.ps1')
$transcript = New-TestTranscript -Name 't2766'

Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$launched = @()
$script:reachedEnd = $false
$seams = @('GHOZTTY_DEBUG_QT_SLIDE_STALL_MS', 'GHOZTTY_DEBUG_QT_SLIDE_STEPPED')
$stallMs = 900

& {
try {
    Assert-GhozttyPrivateEndpoint -Exe $Exe
    $work = Get-TestWorkArea
    foreach ($arm in @('dwm', 'reverse', 'stepped')) {
    "==== arm: $arm"
    [void](Stop-RepoGhoztty -Exe $Exe -AppOnly -SettleMs 500)
    Remove-Item ($seams | ForEach-Object { "env:$_" }) -ErrorAction SilentlyContinue
    if ($arm -eq 'dwm') { $env:GHOZTTY_DEBUG_QT_SLIDE_STALL_MS = "$stallMs" }
    if ($arm -eq 'stepped') { $env:GHOZTTY_DEBUG_QT_SLIDE_STEPPED = '1' }
    $script:errlog = Join-Path $tmp "app-stderr-$arm.log"
    $duration = if ($arm -eq 'reverse') { '1.2' } else { '0.3' }
    $app = Start-OnTestDesktop -Exe $Exe -StdErr $script:errlog -Arguments @(
        '--session-persistence=false',
        "--quick-terminal-animation-duration=$duration",
        '--quick-terminal-autohide=false',
        '--keybind=ctrl+shift+f10=toggle_quick_terminal')
    Start-Sleep -Seconds 3
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { "  SETUP FAIL: top window not found"; $script:failures++; return }
    Assert "[$arm] window is NOT enumerable on the interactive desktop" (-not (Test-TestDesktopLeak -ProcessId $app.Pid))
    $pane = Get-TestChildWindow -Window $top -Class 'GhozttyTerminal'
    $before = @(Get-TestWindows -ProcessId $app.Pid -Class 'GhozttyWindow' -AllowHidden | ForEach-Object { [int64]$_.Hwnd })
    $active = Set-Active $top $pane
    Assert "[$arm] setup: the main window is active to take the keybind" $active
    if (-not $active) { continue }

    "== toggle in"
    Send-TestKeys -Window $top -Target $pane -Key F10 -Modifiers ctrl, shift | Out-Null
    $qt = Find-QuickTerminal $app.Pid $before
    Assert "[$arm] the quick terminal window was made" ($qt -ne [IntPtr]::Zero)
    if ($qt -eq [IntPtr]::Zero) { continue }

    if ($arm -eq 'dwm') {
        $on = Wait-Log 'quick terminal slide on dwm dir=in gen=(\d+) ms=300 host='
        Assert "[dwm] the in slide went to the slider (log: $on)" ($null -ne $on)
        $stall = Wait-Log "quick terminal slide debug stall ms=$stallMs"
        Assert "[dwm] the UI thread was stalled as the slide started (log: $stall)" ($null -ne $stall)
        $landed = Wait-Log 'quick terminal slide landed dir=in frames=(\d+) ms=(\d+)'
        Assert "[dwm] the in slide landed (log: $landed)" ($null -ne $landed)
        $frames = -1; $ms = -1
        if ($landed -match 'frames=(\d+) ms=(\d+)') { $frames = [int]$Matches[1]; $ms = [int]$Matches[2] }
        Assert "[dwm] the slider composed frames through the stall (frames=$frames)" ($frames -ge 3)
        # The slide is 300 ms; the UI thread was blocked for 900. A slider that
        # needed the UI thread could not finish before the stall ended.
        $inside = if ($NegativeControl) { $ms -ge $stallMs } else { $ms -ge 250 -and $ms -lt ($stallMs - 200) }
        Assert "[dwm] ... and finished in about its 300 ms, inside the $stallMs ms stall (slider ms=$ms)" $inside
        Start-Sleep -Milliseconds 400
        $r = Get-TestWindowRect $qt
        Assert "[dwm] landed: the quick terminal is shown" (Test-TestWindowVisible $qt)
        Assert "[dwm] landed: ... at the top of the work area ($($r.Left),$($r.Top) vs $($work.Left),$($work.Top))" ($r.Left -eq $work.Left -and $r.Top -eq $work.Top)
        Assert "[dwm] landed: ... and uncloaked, so it takes input (cloaked=$([T2766Dwm]::Cloaked($qt)))" ([T2766Dwm]::Cloaked($qt) -eq 0)
        $hosts = @(Get-SlideHosts $app.Pid)
        Assert "[dwm] the slider's host window exists ($($hosts.Count))" ($hosts.Count -eq 1)
        Assert "[dwm] ... and is down once the slide landed" (-not (Test-AnyHostShown $app.Pid))

        "== toggle out"
        if (-not (Set-Active $top $pane)) { Assert "[dwm] setup: re-activate the main window" $false; continue }
        Send-TestKeys -Window $top -Target $pane -Key F10 -Modifiers ctrl, shift | Out-Null
        $out = Wait-Log 'quick terminal slide on dwm dir=out gen=(\d+)'
        Assert "[dwm] the out slide went to the slider (log: $out)" ($null -ne $out)
        $landedOut = Wait-Log 'quick terminal slide landed dir=out frames=(\d+) ms=(\d+)'
        Assert "[dwm] the out slide landed (log: $landedOut)" ($null -ne $landedOut)
        Start-Sleep -Milliseconds 400
        Assert "[dwm] out: the quick terminal is hidden" (-not (Test-TestWindowVisible $qt))
        Assert "[dwm] out: ... and uncloaked for its next show (cloaked=$([T2766Dwm]::Cloaked($qt)))" ([T2766Dwm]::Cloaked($qt) -eq 0)
        Assert "[dwm] out: the host is down" (-not (Test-AnyHostShown $app.Pid))
        Assert "[dwm] no slide fell back to the frame clock ($(@(Get-LogLines 'quick terminal slide could not').Count))" (@(Get-LogLines 'quick terminal slide could not|slider unavailable').Count -eq 0)
    } elseif ($arm -eq 'reverse') {
        $on = Wait-Log 'quick terminal slide on dwm dir=in gen=(\d+) ms=1200 '
        Assert "[reverse] the in slide went to the slider (log: $on)" ($null -ne $on)
        Start-Sleep -Milliseconds 300
        Assert "[reverse] mid-slide: the slider's host is up" (Test-AnyHostShown $app.Pid)
        Assert "[reverse] mid-slide: the quick terminal is cloaked, so it takes no input yet (cloaked=$([T2766Dwm]::Cloaked($qt)))" ([T2766Dwm]::Cloaked($qt) -gt 0)
        Assert "[reverse] mid-slide: it has not landed yet" (@(Get-LogLines 'quick terminal slide landed').Count -eq 0)
        Send-TestKeys -Window $top -Target $pane -Key F10 -Modifiers ctrl, shift | Out-Null
        $rev = Wait-Log 'quick terminal slide on dwm reversed dir=out gen=(\d+)'
        Assert "[reverse] the second toggle turned the slide round (log: $rev)" ($null -ne $rev)
        $landed = Wait-Log 'quick terminal slide landed dir=(in|out)'
        Assert "[reverse] ... and the one landing is the OUT slide (log: $landed)" ($null -ne $landed -and $landed -match 'dir=out')
        Start-Sleep -Milliseconds 500
        Assert "[reverse] the quick terminal ends hidden" (-not (Test-TestWindowVisible $qt))
        Assert "[reverse] ... and uncloaked (cloaked=$([T2766Dwm]::Cloaked($qt)))" ([T2766Dwm]::Cloaked($qt) -eq 0)
        Assert "[reverse] the host is down" (-not (Test-AnyHostShown $app.Pid))
        Assert "[reverse] no in slide ever landed" (@(Get-LogLines 'quick terminal slide landed dir=in').Count -eq 0)
        Assert "[reverse] no slide fell back to the frame clock" (@(Get-LogLines 'quick terminal slide could not|slider unavailable').Count -eq 0)
    } else {
        Start-Sleep -Milliseconds 1200
        Assert "[stepped] no slide went to the slider ($(@(Get-LogLines 'quick terminal slide on dwm').Count))" (@(Get-LogLines 'quick terminal slide on dwm').Count -eq 0)
        Assert "[stepped] no slider host window was ever made" (@(Get-SlideHosts $app.Pid).Count -eq 0)
        $r = Get-TestWindowRect $qt
        Assert "[stepped] the quick terminal still lands shown" (Test-TestWindowVisible $qt)
        Assert "[stepped] ... at the same place ($($r.Left),$($r.Top) vs $($work.Left),$($work.Top))" ($r.Left -eq $work.Left -and $r.Top -eq $work.Top)
        Assert "[stepped] ... and never cloaked (cloaked=$([T2766Dwm]::Cloaked($qt)))" ([T2766Dwm]::Cloaked($qt) -eq 0)
    }

    Assert "[$arm] no crash" (-not ($app.Process -and $app.Process.HasExited))
    $launched += $script:GhozttyTestDesktopPids
    }
    $script:reachedEnd = $true
} catch {
    "  FAIL body threw: $($_.Exception.Message)"
    $script:failures++
} finally {
    Remove-Item ($seams | ForEach-Object { "env:$_" }) -ErrorAction SilentlyContinue
    Remove-TestDesktop
    [void](Stop-RepoGhoztty -Exe $Exe -AppOnly -SettleMs 500)
}

Assert "the body ran to its last section" ($script:reachedEnd -eq $true)
$fgSeen = @(Stop-TestForegroundWatch)
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @($launched | Select-Object -Unique)
    Assert "the foreground watcher actually sampled (negative control)" ($fgSeen.Count -gt 0)
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert "no test-desktop app ever became foreground on the interactive desktop" ($leaked.Count -eq 0)
}
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

} 2>&1 | Tee-Object -FilePath $transcript

Complete-TestBody  # T1039: the run reached the end of its body

if ($script:failures -eq 0 -and -not $NegativeControl) {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard quick-terminal-slide -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

""
exit (Complete-TestTranscript -Name 't2766' -Path $transcript `
        -Label 'T2766 ACCEPTANCE' -Pass $script:passes -Fail $script:failures).Code
