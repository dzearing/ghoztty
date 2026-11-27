# Acceptance for T2630: under a held divider drag, a terminal pane that is a
# PLAIN child (no layer of its own, GHOZTTY_PANE_LAYER=0) gets the strips its
# last frame does not cover filled with background, the same as a layered pane.
#
# Before T2630 the fill in Surface.handleResize was gated on `own_layer`, so on
# the escape-hatch path a pane grown by a drag showed whatever its top-level's
# redirection surface held there (a neighbour's stale pixels, the desk) until
# the drag settled and the held grid was released - which, since T2623, is the
# settle and not the next tick.
#
# THE ORACLE. The strip is on screen for less than a frame and the terminal
# surface does not come back from PrintWindow off the input desktop, so the
# pixels are not photographed (the reason resize-flicker.ps1 gives at length).
# The debug build states the decision instead: every fill logs
# `pane strip fill layered=<bool> strips=<n>`. This script reads that line out
# of stderr.
#
#   A. GHOZTTY_PANE_LAYER=0: the panes really are plain children (no
#      WS_EX_LAYERED), a posted divider drag grows the left pane, and at least
#      one `layered=false` fill is logged during it. That is the defect.
#   B. Positive control, default layering: the same drag logs `layered=true`
#      fills, so the oracle is alive on the path that always had the fill and
#      section A's answer is not a quirk of this script.
#
# -NegativeControl inverts A's fill assertion and MUST fail.
#
# Runs on the BACKGROUND test desktop (lib\TestDesktop.ps1); never takes the
# user's foreground. Only touches ghoztty processes running from this repo's
# zig-out*.
#   powershell -NoProfile -File test\win32\plain-child-strip-fill.ps1
param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }

$env:GHOZTTY_PIPE_SUFFIX = "-stripfill$PID"
# Both runs are on the WGL window path, where a pane presents into its own
# window: the composition swap chain (the default since T2515) places the held
# frame itself and never takes this fill, layered or not.
$env:GHOZTTY_COMP_PRESENT = '0'
$errBase = Join-Path $env:TEMP "ghoztty-strip-fill-$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\NativeTolerant.ps1')
Assert-GhozttyIsolatedBuild -Exe $exe | Out-Null

$WS_EX_LAYERED = 0x80000

$script:pass = 0
$script:fail = 0
$script:skipped = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Kill-RepoInstances { [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500) }

function Get-VisiblePanes([IntPtr]$top) {
    return @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal' | Where-Object Visible)
}

# Every `pane strip fill` line in the log, as @{ Layered; Strips }.
function Get-StripFills([string]$log) {
    $out = @()
    if (-not (Test-Path $log)) { return $out }
    foreach ($l in @(Get-Content $log -ErrorAction SilentlyContinue)) {
        if ($l -match 'pane strip fill layered=(\w+) strips=(\d+)') {
            $out += [pscustomobject]@{ Layered = ($Matches[1] -eq 'true'); Strips = [int]$Matches[2] }
        }
    }
    # Not `return , $out`: wrapped in @() at the call site that counts as one
    # element even when empty (the PS5.1 trap), and the drag's lines vanish.
    return $out
}

# Launch, split, drag the divider right by 120px in 10 posted steps. Returns
# @{ Moved; Panes; Layered; Fills } with Fills being the lines logged by the drag.
function Invoke-DragRun([string]$label, [string]$errlog) {
    Kill-RepoInstances
    Remove-Item $errlog -ErrorAction SilentlyContinue
    $app = Start-OnTestDesktop -Exe $exe -StdErr $errlog -Arguments @(
        '--config-default-files=false', '--background=#101014', '--session-persistence=false')
    $appPid = $app.Pid
    Assert (-not (Test-TestDesktopLeak -ProcessId $appPid)) "${label}: GUI is NOT enumerable on the interactive desktop"
    $top = Wait-TestWindow -ProcessId $appPid -Class 'GhozttyWindow' -TimeoutMs 20000
    Assert ($top -ne [IntPtr]::Zero) "${label}: top-level window appeared"
    if ($top -eq [IntPtr]::Zero) { throw 'no window' }
    [void](Set-TestWindowPos -Window ([IntPtr]$top) -X 40 -Y 40 -Width 1200 -Height 820)
    Start-Sleep -Milliseconds 800 # settle: the resize's relayout and first paint land before the split
    Invoke-Tolerant { & $exe +split --direction=right 2>&1 | Out-Null }
    $panes = @()
    for ($t = 0; $t -lt 40 -and $panes.Count -ne 2; $t++) {
        Start-Sleep -Milliseconds 100
        $panes = @(Get-VisiblePanes ([IntPtr]$top))
    }
    # settle: the new pane's shell presents a first frame - the fill needs a presented size to measure from
    Start-Sleep -Milliseconds 1500
    $panes = @(Get-VisiblePanes ([IntPtr]$top))
    Assert ($panes.Count -eq 2) "${label}: split produced 2 panes (saw $($panes.Count))"
    if ($panes.Count -ne 2) { throw 'no split' }
    $layered = @($panes | Where-Object {
        ((Get-TestWindowStyle -Window ([IntPtr]$_.Hwnd) -ExStyle) -band $WS_EX_LAYERED) -ne 0 }).Count

    $before = @(Get-StripFills $errlog).Count
    $sorted = @($panes | Sort-Object Left)
    $startX = [int](($sorted[0].Right + $sorted[1].Left) / 2)
    $startY = [int](($sorted[0].Top + $sorted[0].Bottom) / 2)
    $widthBefore = $sorted[0].Right - $sorted[0].Left
    $moved = $false
    [void](Send-TestMouse -Window ([IntPtr]$top) -Target ([IntPtr]$top) -X $startX -Y $startY -Action down -HoldMs 0)
    Start-Sleep -Milliseconds 150 # settle: a held press before the first move, the way a hand drags
    for ($i = 1; $i -le 10; $i++) {
        [void](Send-TestMouse -Window ([IntPtr]$top) -Target ([IntPtr]$top) `
            -X ($startX + ($i * 12)) -Y $startY -Action move -HoldMs 0)
        Start-Sleep -Milliseconds 60
        $left = @(Get-VisiblePanes ([IntPtr]$top) | Sort-Object Left)[0]
        if (($left.Right - $left.Left) -ne $widthBefore) { $moved = $true }
    }
    [void](Send-TestMouse -Window ([IntPtr]$top) -Target ([IntPtr]$top) -X ($startX + 120) -Y $startY -Action up -HoldMs 0)
    # The debug log reaches the redirected stderr when the app's buffer flushes.
    $fills = @()
    for ($t = 0; $t -lt 20; $t++) {
        Start-Sleep -Milliseconds 250
        $all = @(Get-StripFills $errlog)
        $fills = @($all | Select-Object -Skip $before)
        if ($fills.Count -gt 0) { break }
    }
    Assert (-not (Test-TestDesktopLeak -ProcessId $appPid)) "${label}: GUI never became visible on the interactive desktop"
    Kill-RepoInstances
    return [pscustomobject]@{ Moved = $moved; Panes = $panes.Count; Layered = $layered; Fills = $fills; Log = $errlog }
}

$td = New-TestDesktop -Interactive:$Interactive
try {
    # ---- A. plain children (the escape hatch) ---------------------------
    $env:GHOZTTY_PANE_LAYER = '0'
    $a = Invoke-DragRun 'plain' "$errBase-plain.log"
    Assert $a.Moved 'plain: the posted drag grabbed the divider (the left pane resized)'
    Assert ($a.Layered -eq 0) "plain: GHOZTTY_PANE_LAYER=0 made every pane a plain child ($($a.Layered) of $($a.Panes) layered)"
    $plainFills = @($a.Fills | Where-Object { -not $_.Layered -and $_.Strips -gt 0 })
    $ok = ($plainFills.Count -gt 0)
    if ($NegativeControl) { $ok = -not $ok }
    Assert $ok ("plain: the drag filled the grown pane's uncovered strips on the plain-child path " +
        "($($plainFills.Count) fill(s) layered=false of $($a.Fills.Count) logged)")

    # ---- B. positive control: the layered default -----------------------
    Remove-Item env:GHOZTTY_PANE_LAYER -ErrorAction SilentlyContinue
    $b = Invoke-DragRun 'layered' "$errBase-layered.log"
    Assert $b.Moved 'layered: the posted drag grabbed the divider (the left pane resized)'
    if ($b.Layered -ne $b.Panes) {
        # A box whose default is not the layered pane (presenter or
        # composition path on by default) has no own-layer control to run.
        $script:skipped++
        Write-Host "SKIP  layered: the default panes are not layered here ($($b.Layered) of $($b.Panes)) - no positive control" -ForegroundColor Yellow
    } else {
        $layFills = @($b.Fills | Where-Object { $_.Layered -and $_.Strips -gt 0 })
        Assert ($layFills.Count -gt 0) ("layered: the oracle is live on the path that always had the fill " +
            "($($layFills.Count) fill(s) layered=true)")
    }
    Complete-TestBody
}
finally {
    Remove-Item env:GHOZTTY_PANE_LAYER -ErrorAction SilentlyContinue
    Remove-Item env:GHOZTTY_COMP_PRESENT -ErrorAction SilentlyContinue
    Kill-RepoInstances
    Remove-TestDesktop
}

if ($script:fail -eq 0 -and $script:skipped -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard plain-child-strip-fill -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Skipped $script:skipped
