# @timing-sensitive - its bursts are defined by the gap between steps, so it runs with nothing beside it (scripts/acceptance-parallel.ps1, T1960).
# T2986 acceptance: a burst of window-size changes OUTSIDE the modal size loop
# (SetWindowPos from a script or tiling tool, no WM_ENTERSIZEMOVE) paints the
# pane desk on the edge drag's canvas, instead of rendering a whole new desk on
# every step.
#
# THE DEFECT (PA-W02, audit T2960): the canvas (T2577) was armed only from
# WM_ENTERSIZEMOVE, so every other resize step re-rendered the gradient,
# recreated the compose bitmap and composed the whole desk - ~4 ms a step.
#
# THE ORACLE. Under GHOZTTY_PERF the app prints, once a burst goes quiet:
#
#   size burst steps=.. desk_renders=.. settled_desk=WxH area=WxH
#
# desk_renders is how many times the desk was rendered from the moment the
# burst armed to its settle (before the settle's own repaint), and
# settled_desk is the desk the settle repaint laid out.
#
# THE ARMS, one instance each, two terminals side by side:
#   canvas    the shipped path
#   nocanvas  GHOZTTY_DESK_NO_CANVAS (the T2577 A/B control): every step lays
#             the desk out for the window, as before T2986 - the negative
#             control that proves the counter can see a render per step.
#
# WHAT IS ASSERTED:
#   A. a single resize (a maximize-shaped one-step change) arms nothing: no
#      burst line is printed for it.
#   B. each arm's growing and shrinking burst printed its line, with most of
#      the steps posted.
#   C. canvas: a growing burst renders the desk at most a few times (the
#      canvas grows with headroom), a shrinking burst at most once; nocanvas
#      renders it on most steps (the oracle is live).
#   D. canvas: the settle lays the desk out for the window exactly
#      (settled_desk == area), so the gradient lands as a non-burst resize
#      would have laid it out.
#
# -NegativeControl swaps the arms' expectations: C must go red.
#
# Runs on the BACKGROUND test desktop (lib\TestDesktop.ps1) - no foreground
# stolen. Only touches ghoztty processes running from this repo's zig-out.
#   powershell -NoProfile -File test\win32\size-burst-canvas.ps1
param(
    [string]$ExePath,
    [int]$Steps = 30,
    [int]$StepPx = 12,
    [int]$StepMs = 30,
    [switch]$NegativeControl,
    [switch]$Interactive
)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }
$env:GHOZTTY_PIPE_SUFFIX = "-sizeburst$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
Assert-GhozttyIsolatedBuild -Exe $exe | Out-Null

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$outDir = Join-Path $env:TEMP "ghoztty-size-burst\$stamp-$PID"
New-Item -ItemType Directory -Force $outDir | Out-Null
$report = Join-Path $outDir 'report.txt'

$script:pass = 0
$script:fail = 0
$script:skipped = 0
function Rep([string]$m) { $m | Tee-Object -FilePath $report -Append | Write-Host }
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Rep "PASS  $label" }
    else { $script:fail++; $host.UI.WriteErrorLine("FAIL  $label"); "FAIL  $label" | Out-File -Append $report }
}

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Threading;
public static class SizeBurst {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll", SetLastError = true)] static extern IntPtr OpenDesktop(string name, uint flags, bool inherit, uint access);
    [DllImport("user32.dll")] static extern bool SetThreadDesktop(IntPtr d);
    [DllImport("user32.dll")] static extern bool CloseDesktop(IntPtr d);
    // `steps` SetWindowPos calls `stepMs` apart, `dw` px each on the width -
    // and NO WM_ENTERSIZEMOVE. Returns the ms until the last step landed, or
    // -1 when it never did.
    public static long Burst(string desk, IntPtr h, int steps, int dw, int stepMs) {
        long result = -2;
        var t = new Thread(delegate() {
            IntPtr d = OpenDesktop(desk, 0, false, 0x01FF);
            if (d == IntPtr.Zero || !SetThreadDesktop(d)) { result = -3; return; }
            try {
                const uint NOZ = 0x0004, NOACT = 0x0010, NOMOVE = 0x0002, ASYNC = 0x4000;
                RECT r; GetWindowRect(h, out r);
                int w = r.R - r.L, hh = r.B - r.T;
                var sw = System.Diagnostics.Stopwatch.StartNew();
                for (int i = 1; i <= steps; i++) {
                    SetWindowPos(h, IntPtr.Zero, 0, 0, w + dw * i, hh, NOZ | NOACT | NOMOVE | ASYNC);
                    long due = (long)i * stepMs;
                    while (sw.ElapsedMilliseconds < due) Thread.Sleep(1);
                }
                result = -1;
                while (sw.ElapsedMilliseconds < 20000) {
                    RECT n; GetWindowRect(h, out n);
                    if (n.R - n.L == w + dw * steps) { result = sw.ElapsedMilliseconds; break; }
                    Thread.Sleep(1);
                }
            } finally { CloseDesktop(d); }
        });
        t.Start();
        t.Join();
        return result;
    }
}
'@

function Kill-RepoInstances { [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500) }

function Get-BurstSamples([string]$log) {
    if (-not (Test-Path $log)) { return @() }
    $out = @()
    foreach ($l in @(Get-Content $log -ErrorAction SilentlyContinue)) {
        if ($l -match 'size burst steps=(\d+) desk_renders=(\d+) settled_desk=(\d+)x(\d+) area=(\d+)x(\d+)') {
            $out += [pscustomobject]@{
                Steps = [int]$Matches[1]; Renders = [int]$Matches[2]
                DeskW = [int]$Matches[3]; DeskH = [int]$Matches[4]
                AreaW = [int]$Matches[5]; AreaH = [int]$Matches[6]
            }
        }
    }
    return @($out)
}

# One burst; the line it printed once it went quiet, or $null.
function Invoke-Burst([IntPtr]$top, [string]$log, [int]$dw, [int]$n) {
    $before = @(Get-BurstSamples $log).Count
    $wall = [SizeBurst]::Burst($script:deskName, $top, $n, $dw, $StepMs)
    for ($t = 0; $t -lt 20; $t++) {
        Start-Sleep -Milliseconds 250
        $all = @(Get-BurstSamples $log)
        if ($all.Count -gt $before) {
            $s = $all[$all.Count - 1]
            Add-Member -InputObject $s -NotePropertyName WallMs -NotePropertyValue $wall -Force
            return $s
        }
    }
    return $null
}

function Measure-Arm([string]$arm) {
    $log = Join-Path $outDir "$arm-stderr.log"
    Kill-RepoInstances
    $env:GHOZTTY_PERF = '1'
    if ($arm -eq 'nocanvas') { $env:GHOZTTY_DESK_NO_CANVAS = '1' }
    else { Remove-Item env:GHOZTTY_DESK_NO_CANVAS -ErrorAction SilentlyContinue }
    $res = @{ log = $log }
    $app = Start-OnTestDesktop -Exe $exe -StdErr $log -Arguments @(
        '--config-default-files=false', '--background=#101014', '--session-persistence=false')
    try {
        $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow' -TimeoutMs 20000
        if ($top -eq [IntPtr]::Zero) { throw "no window for $arm" }
        $top = [IntPtr]$top
        [void](Set-TestWindowPos -Window $top -X 40 -Y 40 -Width 900 -Height 700)
        Start-Sleep -Milliseconds 800
        & $exe +split --direction=right 2>&1 | Out-Null
        for ($t = 0; $t -lt 60; $t++) {
            if (@(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal' | Where-Object Visible).Count -ge 2) { break }
            Start-Sleep -Milliseconds 250
        }
        Start-Sleep -Milliseconds 800
        # A. one step, then a second well past the burst window: no burst.
        $n0 = @(Get-BurstSamples $log).Count
        [void](Set-TestWindowPos -Window $top -X 40 -Y 40 -Width 1000 -Height 700)
        Start-Sleep -Milliseconds 700
        [void](Set-TestWindowPos -Window $top -X 40 -Y 40 -Width 900 -Height 700)
        Start-Sleep -Milliseconds 700
        $res.single = @(Get-BurstSamples $log).Count - $n0
        $res.grow = Invoke-Burst $top $log $StepPx $Steps
        Start-Sleep -Milliseconds 500
        $res.shrink = Invoke-Burst $top $log (-$StepPx) $Steps
    } finally {
        Kill-RepoInstances
        Remove-Item env:GHOZTTY_DESK_NO_CANVAS -ErrorAction SilentlyContinue
    }
    return $res
}

$td = New-TestDesktop -Interactive:$Interactive
$script:deskName = $td.Name
$all = @{}
try {
    Rep "T2986 size burst canvas, $stamp"
    Rep "  exe: $exe"
    Rep "  $Steps SetWindowPos steps of $StepPx px, $StepMs ms apart, no WM_ENTERSIZEMOVE"
    Rep ''
    foreach ($arm in 'canvas', 'nocanvas') {
        $r = Measure-Arm $arm
        $all[$arm] = $r
        Rep ("  {0,-9} single-step bursts={1}" -f $arm, $r.single)
        foreach ($dir in 'grow', 'shrink') {
            $s = $r[$dir]
            if ($null -eq $s) { Rep ("  {0,-9} {1,-6} NO SAMPLE" -f $arm, $dir); continue }
            Rep ("  {0,-9} {1,-6} steps={2,-3} desk_renders={3,-3} settled_desk={4}x{5} area={6}x{7} wall={8} ms" -f
                $arm, $dir, $s.Steps, $s.Renders, $s.DeskW, $s.DeskH, $s.AreaW, $s.AreaH, $s.WallMs)
        }
    }
    Rep ''
    foreach ($arm in 'canvas', 'nocanvas') {
        Assert ($all[$arm].single -eq 0) "A. $arm a lone resize arms no burst ($($all[$arm].single) burst lines)"
        foreach ($dir in 'grow', 'shrink') {
            $s = $all[$arm][$dir]
            Assert ($null -ne $s -and $s.Steps -ge [int]($Steps / 2)) "B. $arm $dir burst printed its line with most of its $Steps steps ($(if ($s) { $s.Steps } else { 'none' }))"
        }
    }
    $c = $all['canvas']; $n = $all['nocanvas']
    $growMax = 4; $shrinkMax = 1
    if ($NegativeControl) { $growMax = -1; $shrinkMax = -1 }
    if ($c.grow -and $c.shrink -and $n.grow -and $n.shrink) {
        Assert ($c.grow.Renders -le $growMax) "C. canvas a growing burst rendered the desk $($c.grow.Renders) times over $($c.grow.Steps) steps (at most $growMax)"
        Assert ($c.shrink.Renders -le $shrinkMax) "C. canvas a shrinking burst rendered the desk $($c.shrink.Renders) times over $($c.shrink.Steps) steps (at most $shrinkMax)"
        foreach ($dir in 'grow', 'shrink') {
            $s = $n[$dir]
            Assert ($s.Renders -ge [int]($s.Steps / 2)) "C. nocanvas (oracle live) a $dir burst rendered the desk $($s.Renders) times over $($s.Steps) steps"
        }
        foreach ($dir in 'grow', 'shrink') {
            $s = $c[$dir]
            Assert ($s.DeskW -eq $s.AreaW -and $s.DeskH -eq $s.AreaH) "D. canvas the $dir settle laid the desk out for the window ($($s.DeskW)x$($s.DeskH) for $($s.AreaW)x$($s.AreaH))"
        }
    } else {
        Assert $false 'C/D. every arm has both bursts'
    }
    Rep ''
    Rep "report: $report"
    Complete-TestBody
}
finally {
    Kill-RepoInstances
    Remove-TestDesktop
    Remove-Item env:GHOZTTY_PERF -ErrorAction SilentlyContinue
}

if ($script:fail -eq 0 -and $script:skipped -eq 0 -and -not $NegativeControl -and (Test-TestBodyComplete)) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard size-burst-canvas -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Skipped $script:skipped
