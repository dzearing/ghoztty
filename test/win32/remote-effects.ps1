# T1951 acceptance: in a Remote Desktop session Ghoztty turns its expensive
# visual effects off by itself, and turns them back on when the session
# returns to the console - live, with no restart.
#
# The session is faked through the test seam: GHOZTTY_TEST_REMOTE_SESSION_FILE
# names a file whose first byte answers "is this session remote?" ('1' yes)
# in place of GetSystemMetrics(SM_REMOTESESSION). The seam is re-read on every
# check, so a flip is: rewrite the file, then post WM_WTSSESSION_CHANGE to the
# top-level window (the app's own message window, where Windows sends the real
# one, cannot be found from another desktop; Window.zig forwards it).
#
# What is asserted, and how:
#
#   REMOTE AT LAUNCH. With the seam saying remote and a split open, the panes
#   are FLAT (no margin, no rounded-card window region - so no glass and no
#   focus glow, which only exist on cards) and no GhozttyDimOverlay window is
#   visible over the unfocused pane (unfocused-split-opacity swapped to 1).
#
#   LIVE BACK TO THE CONSOLE. Seam to '0' + the session message: the same
#   window re-lays out as elevated cards and the unfocused pane gets its dim
#   overlay back.
#
#   LIVE BACK TO REMOTE. And again the other way, on the same window.
#
#   CONSOLE AT LAUNCH (control). Seam '0' at launch: the full elevated style.
#
#   THE USER WINS. Seam '1' with `--macos-pane-glass=true` on the command
#   line: the panes stay elevated (glass needs the elevated style), while the
#   defaults nobody set (the dim) are still swapped.
#
# Cursor blink and blur are covered by the unit tests in
# src/config/remote_effects.zig (no external probe can read them).
#
# Runs on a background desktop (test/win32/lib/TestDesktop.ps1): nothing here
# takes the user's foreground, which is asserted at the end.
#
# -NegativeControl inverts the remote-at-launch flat assertion and MUST fail.
#
#   powershell -NoProfile -File test\win32\remote-effects.ps1
param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }

$env:GHOZTTY_PIPE_SUFFIX = "-remotefx$PID"
$seam = Join-Path $env:TEMP "ghoztty-remote-effects-$PID.seam"
$env:GHOZTTY_TEST_REMOTE_SESSION_FILE = $seam

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

if (-not ('RemoteFxPost' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class RemoteFxPost {
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint msg, IntPtr wp, IntPtr lp);
}
'@
}
$WM_WTSSESSION_CHANGE = 0x02B1
$WTS_CONSOLE_CONNECT = 1
$WTS_REMOTE_CONNECT = 3

$script:pass = 0
$script:fail = 0
$script:skipped = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Kill-RepoInstances {
    [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
}

function Set-Seam([string]$value) {
    [System.IO.File]::WriteAllText($seam, $value)
}

function Get-Panes([IntPtr]$top) {
    @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal' | Where-Object Visible)
}

function Get-VisibleOverlays([int]$procId) {
    @(Get-TestWindows -ProcessId $procId -Class 'GhozttyDimOverlay' | Where-Object Visible)
}

# Zig's @round is half-away-from-zero; .NET's default is banker's.
function Round-Away([double]$v) { [int][math]::Round($v, [MidpointRounding]::AwayFromZero) }
# pane_elevation.zig mirrored: the margin/gap and the rim inset.
function Get-MarginPx([double]$scale) { [math]::Max((Round-Away (10.0 * $scale)), 1) }
function Get-InsetPx([double]$scale) { [math]::Max([int][math]::Ceiling(0.5 * $scale), 1) }

# The window's style as the outside world can see it: how far the bottom pane
# sits inside the client's right edge, and whether it has a card region.
function Get-Style([IntPtr]$top, [double]$scale) {
    $panes = @(Get-Panes $top)
    if ($panes.Count -eq 0) { return $null }
    $p = $panes | Sort-Object Top | Select-Object -Last 1
    $cs = Get-TestWindowRect -Window $top -Client
    $pw = $p.Right - $p.Left; $ph = $p.Bottom - $p.Top
    $hits = Get-TestWindowRegionHits -Window ([IntPtr]$p.Hwnd) -Points @(0, 0, [int]($pw / 2), [int]($ph / 2))
    $m = Get-MarginPx $scale
    $i = Get-InsetPx $scale
    $rightGap = [int]($cs.Right - $p.Right)
    [pscustomobject]@{
        RightGap = $rightGap
        HasRegion = ($null -ne $hits)
        Elevated = ($rightGap -eq $m + $i) -and ($null -ne $hits)
        Flat = ($rightGap -eq 0) -and ($null -eq $hits)
    }
}

function Wait-Style([IntPtr]$top, [double]$scale, [string]$want) {
    $s = $null
    for ($t = 0; $t -lt 30; $t++) {
        $s = Get-Style $top $scale
        if ($null -ne $s -and $s.$want) { return $s }
        Start-Sleep -Milliseconds 200
    }
    return $s
}

function Wait-OverlayCount([int]$procId, [int]$want) {
    $n = -1
    for ($t = 0; $t -lt 30; $t++) {
        $n = @(Get-VisibleOverlays $procId).Count
        if ($n -eq $want) { return $n }
        Start-Sleep -Milliseconds 200
    }
    return $n
}

function Start-Gui([string]$label, [string[]]$extraArgs) {
    Kill-RepoInstances
    # persistence: off - every caller passes $common (--session-persistence=false);
    # a restored layout would seed panes whose style this script did not make.
    $app = Start-OnTestDesktop -Exe $exe -Arguments $extraArgs
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host "SETUP FAIL ($label): GUI died at launch"; exit 1 }
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { Write-Host "SETUP FAIL ($label): top window not found"; exit 1 }
    Assert (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) "$label window is NOT enumerable on the interactive desktop"
    & $exe +split --direction=down | Out-Null
    Start-Sleep -Milliseconds 900
    $panes = @(Get-Panes $top)
    Assert ($panes.Count -eq 2) "$label setup: split down gives 2 visible panes (saw $($panes.Count))"
    if ($panes.Count -ne 2) { Stop-Process -Id $app.Pid -Force -ErrorAction SilentlyContinue; exit 1 }
    $scale = (Get-TestWindowDpi -Window $top) / 96.0
    [pscustomobject]@{ App = $app; Top = $top; Scale = $scale }
}

function Send-SessionChange([IntPtr]$top, [int]$code) {
    [void][RemoteFxPost]::PostMessageW($top, [uint32]$WM_WTSSESSION_CHANGE, [IntPtr]$code, [IntPtr]::Zero)
}

Kill-RepoInstances
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$launched = @()
$common = @('--config-default-files=false', '--background=#000000', '--session-persistence=false')

try {

# ---------------------------------------------------------------------------
# Run 1: remote at launch, then live to the console and back.
# ---------------------------------------------------------------------------
Set-Seam '1'
$g = Start-Gui 'remote' $common
$launched += $script:GhozttyTestDesktopPids
$s = Get-Style $g.Top $g.Scale
Write-Host "      remote: right-gap=$($s.RightGap) region=$($s.HasRegion)"
if ($NegativeControl) {
    Write-Host 'NEGATIVE CONTROL: asserting the remote launch is elevated - this run MUST fail'
    Assert $s.Elevated 'remote: the panes are elevated cards (negative control)'
} else {
    Assert $s.Flat 'remote: the panes come up flat (no margin, no card region: no glass, no glow)'
}
$n = Wait-OverlayCount $g.App.Pid 0
Assert ($n -eq 0) "remote: no dim overlay over the unfocused pane (saw $n)"

Set-Seam '0'
Send-SessionChange $g.Top $WTS_CONSOLE_CONNECT
$s = Wait-Style $g.Top $g.Scale 'Elevated'
Write-Host "      console: right-gap=$($s.RightGap) region=$($s.HasRegion)"
Assert $s.Elevated 'back on the console: the same window re-lays out as elevated cards, live'
$n = Wait-OverlayCount $g.App.Pid 1
Assert ($n -eq 1) "back on the console: the unfocused pane is dimmed again (saw $n overlays)"

Set-Seam '1'
Send-SessionChange $g.Top $WTS_REMOTE_CONNECT
$s = Wait-Style $g.Top $g.Scale 'Flat'
Assert $s.Flat 'remote again: the same window goes flat, live'
$n = Wait-OverlayCount $g.App.Pid 0
Assert ($n -eq 0) "remote again: the dim overlay is gone (saw $n)"
Assert (-not ($g.App.Process -and $g.App.Process.HasExited)) 'remote run: no crash across three switches'
Stop-Process -Id $g.App.Pid -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# Run 2 (control): console at launch keeps the full style.
# ---------------------------------------------------------------------------
Set-Seam '0'
$g = Start-Gui 'console' $common
$launched += $script:GhozttyTestDesktopPids
$s = Get-Style $g.Top $g.Scale
Write-Host "      console launch: right-gap=$($s.RightGap) region=$($s.HasRegion)"
Assert $s.Elevated 'console launch: the panes are elevated cards'
$n = Wait-OverlayCount $g.App.Pid 1
Assert ($n -eq 1) "console launch: the unfocused pane is dimmed (saw $n overlays)"
Stop-Process -Id $g.App.Pid -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# Run 3: a value the user set by name wins in a remote session.
# ---------------------------------------------------------------------------
Set-Seam '1'
$g = Start-Gui 'user-glass' ($common + @('--macos-pane-glass=true'))
$launched += $script:GhozttyTestDesktopPids
$s = Get-Style $g.Top $g.Scale
Write-Host "      user glass: right-gap=$($s.RightGap) region=$($s.HasRegion)"
Assert $s.Elevated 'user set macos-pane-glass = true: the panes stay elevated (glass kept) over Remote Desktop'
$n = Wait-OverlayCount $g.App.Pid 0
Assert ($n -eq 0) "user glass: the dim nobody set is still off (saw $n overlays)"
Stop-Process -Id $g.App.Pid -Force -ErrorAction SilentlyContinue

} catch {
    $script:fail++
    Write-Host "FAIL  the run terminated: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "      at $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())"
} finally {
    Remove-TestDesktop
    Kill-RepoInstances
    Remove-Item $seam -ErrorAction SilentlyContinue
    Remove-Item Env:\GHOZTTY_TEST_REMOTE_SESSION_FILE -ErrorAction SilentlyContinue
}

$fgSeen = @(Stop-TestForegroundWatch)
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @($launched | Select-Object -Unique)
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'no test-desktop app ever became foreground on the interactive desktop'
}

Complete-TestBody
if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard remote-effects -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Skipped $script:skipped -Label 'REMOTE EFFECTS ACCEPTANCE'
