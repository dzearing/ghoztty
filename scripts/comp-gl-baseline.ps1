# T2734: what the SAME glide costs on today's path, for T2360 criterion 3
# ("CPU cost per glide no worse than today's Mesa/WARP path").
#
# The composition spike (scripts\comp-spike.ps1) prices its glide in its own
# process; this prices the app's. It launches the debug ghoztty.exe on the
# background test desktop (never the user's), opens a second pane, sets the
# sidebar column glide and the grid's slide to the spike's 300 ms, and clicks
# the sidebar's collapse/expand toggle -Glides times, one per 750 ms (the
# spike's 300 ms glide + 450 ms gap). It reads the app's process CPU around
# that, and around an equally long stretch with no clicks (the idle floor), and
# prints one line per GL path:
#
#   GLBASE path=<mesa-warp|hardware> glides=24 glide_cpu_ms=.. idle_cpu_ms=..
#          per_glide_ms=.. landed=.. frames=.. steps=..
#
# per_glide_ms = (glide_cpu - idle_cpu) / glides. landed/frames/steps are the
# app's own `column glide done` lines: a glide that painted nothing would
# price as free, so the frame count is what says the number is real.
#
#   mesa-warp  GHOZTTY_GL_FORCE_VERSION=1.1 + GALLIUM_DRIVER=d3d12 +
#              LIBGL_ALWAYS_SOFTWARE=1: the bundled Mesa on WARP, which is what a
#              Remote Desktop session or a GPU-less machine runs today (T1950).
#   hardware   the same build on the GPU's own OpenGL.
#
# Off the input desktop DWM composes nothing, so this is the app's own CPU
# only, with no cadence: the spike's live oracle owns cadence. Not composing
# can only make today's path CHEAPER here than on a real desktop, so a
# compositor number that beats it beats the real one.
#
# TODAY'S MESA PATH HAS NO GLIDE. A software renderer turns in-window motion
# off (App.refreshLowPower -> clientAreaAnimationsEnabled, T1951), so under
# mesa-warp the toggle SNAPS: `landed=0`, and per_glide_ms is the price of one
# instant relayout + repaint, not of a glide. That is still the number to beat
# (it is what such a machine runs today); the hardware row is the animated one.
#
# -ReleaseSandbox runs a release build (-Exe, e.g. a ReleaseFast
# `--prefix zig-out-perf`) under all three isolating knobs (lib\Isolation.ps1):
# a Debug build's own loops inflate the app's CPU many times over, and the
# spike's compositor path does next to nothing in-process either way.
#
#   powershell -NoProfile -File scripts\comp-gl-baseline.ps1
#   powershell -NoProfile -File scripts\comp-gl-baseline.ps1 -ReleaseSandbox -Exe zig-out-perf\bin\ghoztty.exe
#   powershell -NoProfile -File scripts\comp-gl-baseline.ps1 -Paths mesa-warp -Glides 48
param(
    [string]$Exe = (Join-Path (Split-Path -Parent $PSScriptRoot) 'zig-out\bin\ghoztty.exe'),
    [string]$Paths = 'mesa-warp,hardware',
    [int]$Glides = 24,
    [int]$GlideMs = 300,
    [int]$GapMs = 450,
    [switch]$ReleaseSandbox
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
if (-not [IO.Path]::IsPathRooted($Exe)) { $Exe = Join-Path $repo $Exe }
$Exe = [IO.Path]::GetFullPath($Exe)
$lib = Join-Path $repo 'test\win32\lib'
. (Join-Path $lib 'CleanSlate.ps1')
. (Join-Path $lib 'Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 't2734' -Quiet -ReleaseSandbox:$ReleaseSandbox)
. (Join-Path $lib 'TestDesktop.ps1')
. (Join-Path $lib 'ChromeGeometry.ps1')
if (-not (Test-Path $Exe)) { Write-Host "comp-gl-baseline: $Exe is missing - build -Doptimize=Debug first"; exit 2 }
$cli = [IO.Path]::ChangeExtension($Exe, '.com')
if (-not (Test-Path $cli)) { $cli = $Exe }
$tmp = Join-Path $env:TEMP "ghoztty-t2734-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

$saved = @{}
$knobs = 'GHOZTTY_GL_FORCE_VERSION', 'GALLIUM_DRIVER', 'LIBGL_ALWAYS_SOFTWARE', 'GHOZTTY_SIDEBAR_COLUMN_MS', 'GHOZTTY_STACK_SLIDE_MS'
foreach ($k in $knobs) { $saved[$k] = [Environment]::GetEnvironmentVariable($k) }
function Set-Knob([string]$Name, $Value) { [Environment]::SetEnvironmentVariable($Name, $Value) }

function Get-CpuMs([int]$ProcessId) {
    $p = Get-Process -Id $ProcessId -ErrorAction Stop
    $p.Refresh()
    return $p.TotalProcessorTime.TotalMilliseconds
}

function Measure-Path([string]$Path) {
    Set-Knob 'GHOZTTY_SIDEBAR_COLUMN_MS' "$GlideMs"
    Set-Knob 'GHOZTTY_STACK_SLIDE_MS' "$GlideMs"
    if ($Path -eq 'mesa-warp') {
        Set-Knob 'GHOZTTY_GL_FORCE_VERSION' '1.1'; Set-Knob 'GALLIUM_DRIVER' 'd3d12'; Set-Knob 'LIBGL_ALWAYS_SOFTWARE' '1'
    } else {
        foreach ($k in 'GHOZTTY_GL_FORCE_VERSION', 'GALLIUM_DRIVER', 'LIBGL_ALWAYS_SOFTWARE') { Set-Knob $k $null }
    }
    [void](Stop-RepoGhoztty -Exe $Exe -AppOnly -SettleMs 500)
    $errlog = Join-Path $tmp "app-$Path.log"
    $app = Start-OnTestDesktop -Exe $Exe -StdErr $errlog -AllowReleaseBuild:$ReleaseSandbox -Arguments @('--session-persistence=false', '--macos-pane-style=flat', '--config-default-files=false')
    try {
        Start-Sleep -Seconds 3
        $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
        if ($top -eq [IntPtr]::Zero) { return "GLBASE path=$Path FAILED: no top window" }
        $scale = 1.0
        $dpi = Get-TestWindowDpi -Window $top
        if ($dpi -gt 0) { $scale = $dpi / 96.0 }
        $px = { param([double]$d) Get-TestChromeDip -Dip $d -Scale $scale }
        [void](Set-TestWindowSize -Window $top -Width (& $px 1100) -Height (& $px 700))
        Start-Sleep -Milliseconds 600
        cmd /c "`"$cli`" +split --direction=right --name=s1 > `"$tmp\out.txt`" 2> `"$tmp\err.txt`"" | Out-Null
        Start-Sleep -Milliseconds 1500
        $sb = @(Get-TestChildWindows -Window $top -Class 'GhozttyPaneSidebar') | Select-Object -First 1
        if ($null -eq $sb) { return "GLBASE path=$Path FAILED: no pane sidebar" }
        # The collapse/expand toggle (T2289), in the rail and the panel alike.
        $margin = & $px 12; $card = & $px 52; $tile = & $px 28
        $inset = [int][math]::Truncate(($card - $tile) / 2)
        $tx = $sb.Left + $margin + $inset + [int]($tile / 2)
        $ty = $sb.Top + $margin + $inset + [int]($tile / 2)
        $step = $GlideMs + $GapMs

        # Idle floor: the same stretch, nothing clicked.
        $c0 = Get-CpuMs $app.Pid
        Start-Sleep -Milliseconds ($Glides * $step)
        $idle = (Get-CpuMs $app.Pid) - $c0

        $mark = @(Get-Content $errlog -ErrorAction SilentlyContinue).Count
        $c0 = Get-CpuMs $app.Pid
        $sw = [Diagnostics.Stopwatch]::StartNew()
        for ($i = 0; $i -lt $Glides; $i++) {
            [void](Send-TestMouse -Window $top -Target ([IntPtr]$sb.Hwnd) -X $tx -Y $ty -Action click -HoldMs 10)
            $due = ($i + 1) * $step
            $left = $due - $sw.ElapsedMilliseconds
            if ($left -gt 0) { Start-Sleep -Milliseconds $left }
        }
        $glide = (Get-CpuMs $app.Pid) - $c0
        Start-Sleep -Milliseconds 300
        $done = @(Get-Content $errlog -ErrorAction SilentlyContinue | Select-Object -Skip $mark | Where-Object { $_ -match 'column glide done .*frames=(\d+) steps=(\d+)' })
        $frames = 0; $steps = 0
        foreach ($l in $done) { if ($l -match 'frames=(\d+) steps=(\d+)') { $frames += [int]$Matches[1]; $steps += [int]$Matches[2] } }
        # The row is only about the path it names if that renderer took. The
        # GL-version force is a DEBUG-ONLY seam (OpenGL.zig forcedVersion), so
        # a release build under mesa-warp quietly runs on the GPU: refuse it.
        $all = @(Get-Content $errlog -ErrorAction SilentlyContinue)
        $software = @($all | Where-Object { $_ -match 'low-power rendering on: renderer=.* is software' }).Count -gt 0
        $rline = @($all | Where-Object { $_ -match 'loaded OpenGL|low-power rendering on: renderer=' } | Select-Object -Last 1)
        $r = if ($rline.Count -gt 0) { " renderer_line=`"$(($rline[0] -replace '\s+', ' ').Trim())`"" } else { '' }
        if ($Path -eq 'mesa-warp' -and -not $software) { return "GLBASE path=$Path FAILED: the software renderer never took (a release build ignores the forcing seam)$r" }
        if ($Path -eq 'hardware' -and $software) { return "GLBASE path=$Path FAILED: the app came up on a software renderer$r" }
        $per = ($glide - $idle) / [Math]::Max(1, $Glides)
        return ('GLBASE path={0} glides={1} glide_cpu_ms={2:N1} idle_cpu_ms={3:N1} per_glide_ms={4:N2} landed={5} frames={6} steps={7}{8}' -f $Path, $Glides, $glide, $idle, $per, $done.Count, $frames, $steps, $r)
    } finally {
        [void](Stop-RepoGhoztty -Exe $Exe -AppOnly -SettleMs 500)
    }
}

$td = New-TestDesktop
$rc = 0
try {
    foreach ($p in ($Paths -split ',')) {
        $p = $p.Trim()
        if ($p -notin 'mesa-warp', 'hardware') { Write-Host "comp-gl-baseline: unknown path '$p'"; $rc = 2; continue }
        $line = Measure-Path $p
        Write-Host $line
        # mesa-warp snaps by design (see the header); a hardware row that
        # landed nothing measured nothing.
        if ($line -match 'FAILED' -or ($p -eq 'hardware' -and $line -match ' landed=0 ')) { $rc = 1 }
    }
} finally {
    Remove-TestDesktop
    foreach ($k in $knobs) { Set-Knob $k $saved[$k] }
}
Write-Host "comp-gl-baseline: done (exit $rc); app logs in $tmp"
exit $rc
