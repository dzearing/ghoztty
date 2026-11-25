# @timing-sensitive
# T3740 acceptance: the 50th window is as fast as the 2nd.
#
# WHY. User report 2026-11-25: "when i spawn 50 windows shit gets SLOW". No
# harness here had ever opened more than a handful of top-level windows, so a
# cost that grows with the window COUNT - a per-window timer, a broadcast loop
# that touches every window, a renderer ticking behind a covered window - was
# invisible to all of them: each one opens a window or two and quits.
#
# HOW. One app on the test desktop. Windows are opened one at a time with
# `+new-window` up to -Count; at each checkpoint in -Checkpoints the run
# measures, with every window so far still open:
#   * open-next  - wall time of the next `+new-window` until its top-level
#                  window exists (median of the last few opens);
#   * echo       - `+send-keys "echo <marker>"` to the newest pane until
#                  `+read` shows the marker's output: keystroke to glyph, with
#                  the CLI's own process-spawn cost in it (constant, so it
#                  cancels in the ratio against the 1-window baseline);
#   * ui lag     - SendMessage(WM_NULL) round-trips to the FIRST window: how
#                  long the UI thread takes to get to a message (median, max);
#   * ipc        - `+list` round-trip;
#   * idle CPU   - the app's CPU over -IdleSec with nobody typing, as a share
#                  of one core, and the same for every descendant;
#   * memory     - private bytes, GPU, threads, handles, GDI/USER.
# The verdict compares each checkpoint against the 1-window baseline.
#
# -Shape split makes every window a 2-way split. -Persistence runs with
# session persistence ON (agent-backed panes, the user's normal setting).
# -Busy keeps every pane but the first printing a line every ~80 ms (the
# load a window of Claude Code spinners is), and measures echo in the idle
# first pane. -MeasureOnly prints the table and asserts nothing.
#
# Section C stacks every window on one rectangle and starts the spinner load in
# all but the first pane: covered windows must draw nothing (C1 <= one core),
# and typing in the quiet pane stays fast (C2).
#
# WHAT IT FOUND (2026-11-25, T3740): idle windows scale flat (50 windows: open
# 85 ms vs 54, echo 29 vs 31, 5.9% CPU); memory is linear, ~55 MB private +
# ~22 MB GPU a window (T3762); covered busy windows are stopped (54% of a core
# at 50). The cliff is VISIBLE busy panes: cascaded, each draws ~50 fps and
# costs ~37% of a core (renderer + GPU-driver thread), 50 windows ~11 cores on
# release (T3761, which promotes -Busy into the verdict when it lands).
#
# Only touches ghoztty processes running from this repo's zig-out*.
#   powershell -NoProfile -File test\win32\window-count-scale.ps1
param(
    [string]$ExePath,
    [int]$Count = 50,
    [string]$Checkpoints = '2,10,25,50',
    [ValidateSet('single', 'split')][string]$Shape = 'single',
    [int]$IdleSec = 5,
    [string]$Shell = 'cmd',
    [string[]]$AppArgs = @(),
    [switch]$Persistence,
    [switch]$Busy,
    [ValidateSet('cascade', 'stack')][string]$Layout = 'cascade',
    [switch]$ReleaseSandbox,
    [switch]$MeasureOnly,
    [switch]$Interactive,
    [switch]$NegativeControl
)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }

$env:GHOZTTY_PIPE_SUFFIX = "-wincount$PID"
if ($ReleaseSandbox) {
    . (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
    Set-GhozttyTestIsolation -Tag 'wincount' -ReleaseSandbox
    # All three knobs are held, so the release opt-in is a checked one (T1158).
    $env:GHOZTTY_TEST_ALLOW_RELEASE = '1'
}
$errlog = Join-Path $env:TEMP "ghoztty-window-count-scale-$PID.log"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\ProcessMemory.ps1')

$script:pass = 0
$script:fail = 0
$script:skipped = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Invoke-Verb([string[]]$VerbArgs) {
    # A verb's stderr is part of its answer; under Stop it would throw instead.
    $ErrorActionPreference = 'Continue'
    $out = @(& $exe @VerbArgs 2>&1 | ForEach-Object { "$_" }) -join "`n"
    return [pscustomobject]@{ Code = $LASTEXITCODE; Text = $out.Trim() }
}

function Get-TopCount([int]$ProcessId) {
    return @(Get-TestWindows -ProcessId $ProcessId -Class 'GhozttyWindow' -AllowHidden).Count
}

function Get-Median([double[]]$Values) {
    if ($Values.Count -eq 0) { return $null }
    $s = @($Values | Sort-Object)
    return $s[[int][math]::Floor(($s.Count - 1) / 2)]
}

# A pane that keeps drawing, the way a Claude Code spinner does: a line about
# every 60-100 ms, forever (the ping to a TEST-NET address is the sleep).
function Start-BusyPane([string]$Pane) {
    $loop = 'for /l %i in (0,0,1) do @(echo %random% %random% %random% %time% & ping -n 1 -w 100 192.0.2.1 >nul)'
    [void](Invoke-Verb @('+send-keys', "--target=$Pane", "$loop\n"))
}

# Opens window number $N and returns the wall-clock ms until it exists.
function Open-Window([int]$ProcessId, [int]$N) {
    $want = (Get-TopCount $ProcessId) + 1
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-Verb @('+new-window', "--target=wcs$N", "--name=wcs${N}a")
    if ($r.Code -ne 0) { throw "window ${N}: +new-window failed: $($r.Text)" }
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-TopCount $ProcessId) -lt $want) {
        if ((Get-Date) -gt $deadline) { throw "window ${N}: never appeared" }
        Start-Sleep -Milliseconds 10
    }
    $ms = $sw.Elapsed.TotalMilliseconds
    if ($Layout -eq 'stack') {
        # Every window on the same rectangle, the newest on top: the shape of a
        # user's pile of same-size windows, where all but the front one are
        # covered and should draw nothing.
        foreach ($w in @(Get-TestWindows -ProcessId $ProcessId -Class 'GhozttyWindow')) {
            [void](Set-TestWindowPos -Window ([IntPtr][int64]$w.Hwnd) -X 40 -Y 40 -Width 1000 -Height 700)
        }
    }
    if ($Shape -eq 'split') {
        $r = Invoke-Verb @('+split', "--target=wcs${N}a", "--name=wcs${N}b", '--direction=right')
        if ($r.Code -ne 0) { throw "window ${N}: +split failed: $($r.Text)" }
    }
    # Window 1 stays idle - it is the probe.
    if ($Busy -and $N -gt 1) { Start-BusyPane "wcs${N}a" }
    return $ms
}

# Keystroke to glyph: the marker is typed as `echo <a><b>` and the pane is
# polled for the concatenation `<a><b>` on its own, which only the command's
# OUTPUT contains (the echoed command line has a space between them).
function Measure-Echo([string]$Pane) {
    $a = 'mk' + (Get-Random -Maximum 99999)
    $b = 'zz' + (Get-Random -Maximum 99999)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-Verb @('+send-keys', "--target=$Pane", "echo $a$b\n")
    if ($r.Code -ne 0) { return $null }
    $deadline = (Get-Date).AddSeconds(20)
    do {
        $t = (Invoke-Verb @('+read', "--name=$Pane", '--lines=6')).Text
        foreach ($line in ($t -split "`n")) {
            if ($line.Trim() -eq "$a$b") { return $sw.Elapsed.TotalMilliseconds }
        }
    } while ((Get-Date) -lt $deadline)
    return $null
}

function Measure-UiLag([IntPtr]$Hwnd, [int]$Samples = 30) {
    $v = New-Object System.Collections.Generic.List[double]
    for ($i = 0; $i -lt $Samples; $i++) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        [void](Invoke-TestMessage -Window $Hwnd -Message 0)
        $v.Add($sw.Elapsed.TotalMilliseconds)
        Start-Sleep -Milliseconds 15
    }
    return [pscustomobject]@{ Median = (Get-Median $v.ToArray()); Max = ($v | Measure-Object -Maximum).Maximum }
}

function Measure-Ipc([int]$Samples = 5) {
    $v = @()
    for ($i = 0; $i -lt $Samples; $i++) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        [void](Invoke-Verb @('+list'))
        $v += $sw.Elapsed.TotalMilliseconds
    }
    return (Get-Median $v)
}

# Idle CPU as a share of ONE core, the app and its descendants separately.
function Measure-IdleCpu([int]$ProcessId, [int]$Seconds) {
    $p = Get-Process -Id $ProcessId
    $desc0 = @{}
    foreach ($d in (Get-Descendants $ProcessId)) {
        $dp = Get-Process -Id $d.ProcessId -ErrorAction SilentlyContinue
        if ($dp) { try { $desc0[$d.ProcessId] = $dp.TotalProcessorTime.TotalMilliseconds } catch {} }
    }
    $p.Refresh(); $app0 = $p.TotalProcessorTime.TotalMilliseconds
    Start-Sleep -Seconds $Seconds  # settle: this IS the measurement window the CPU is summed over
    $p.Refresh(); $app1 = $p.TotalProcessorTime.TotalMilliseconds
    $descMs = 0.0
    foreach ($k in $desc0.Keys) {
        $dp = Get-Process -Id $k -ErrorAction SilentlyContinue
        if ($dp) { try { $descMs += $dp.TotalProcessorTime.TotalMilliseconds - $desc0[$k] } catch {} }
    }
    $wall = $Seconds * 1000.0
    return [pscustomobject]@{
        AppPct  = [math]::Round(100.0 * ($app1 - $app0) / $wall, 1)
        DescPct = [math]::Round(100.0 * $descMs / $wall, 1)
    }
}

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class WcsThr {
    [DllImport("kernel32.dll", SetLastError = true)] public static extern IntPtr OpenThread(uint access, bool inherit, uint id);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll")] public static extern int GetThreadDescription(IntPtr h, out IntPtr desc);
    [DllImport("kernel32.dll")] public static extern IntPtr LocalFree(IntPtr p);
    public static string Name(uint id) {
        IntPtr h = OpenThread(0x0800, false, id);
        if (h == IntPtr.Zero) return "?";
        try {
            IntPtr p;
            if (GetThreadDescription(h, out p) < 0 || p == IntPtr.Zero) return "?";
            string s = Marshal.PtrToStringUni(p);
            LocalFree(p);
            return string.IsNullOrEmpty(s) ? "(unnamed)" : s;
        } finally { CloseHandle(h); }
    }
}
'@

# Where the app's CPU goes: every thread's CPU over $Seconds, summed by the
# thread's name (`renderer`, `io`, `io-reader`, ...; the UI thread is the
# unnamed one that owns the windows). Returns "name=pct%(count)" busiest first.
function Measure-ThreadCensus([int]$ProcessId, [int]$Seconds) {
    $p = Get-Process -Id $ProcessId
    $t0 = @{}
    foreach ($t in $p.Threads) { try { $t0[$t.Id] = $t.TotalProcessorTime.TotalMilliseconds } catch {} }
    Start-Sleep -Seconds $Seconds  # settle: this IS the measurement window the census is summed over
    $p = Get-Process -Id $ProcessId
    $by = @{}
    $cnt = @{}
    foreach ($t in $p.Threads) {
        $ms = 0.0
        try { $ms = $t.TotalProcessorTime.TotalMilliseconds } catch { continue }
        if ($t0.ContainsKey($t.Id)) { $ms -= $t0[$t.Id] }
        $name = [WcsThr]::Name([uint32]$t.Id)
        # The UI thread is the process's first; unnamed others (the GPU
        # driver's, the thread pool's) are told apart by the busiest one.
        if ($t.Id -eq $p.Threads[0].Id) { $name = 'UI' }
        elseif ($name -eq '(unnamed)' -and $ms -gt 0.05 * $Seconds * 1000.0) { $name = "unnamed#$($t.Id)" }
        $by[$name] = [double]$by[$name] + $ms
        $cnt[$name] = [int]$cnt[$name] + 1
    }
    $wall = $Seconds * 1000.0
    return (($by.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 6 | ForEach-Object {
        "{0}={1:N0}%({2})" -f $_.Key, (100.0 * $_.Value / $wall), $cnt[$_.Key]
    }) -join ' ')
}

[void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$rows = New-Object System.Collections.ArrayList
$openTimes = New-Object System.Collections.Generic.List[double]

try {
    $persist = if ($Persistence) { 'true' } else { 'false' }
    $launchArgs = @('--config-default-files=false', "--session-persistence=$persist", '--confirm-close-surface=false')
    if ($Shell) { $launchArgs += "--command=$Shell" }
    $launchArgs += $AppArgs
    # persistence: stated in $launchArgs above (--session-persistence=$persist, off unless -Persistence)
    $app = Start-OnTestDesktop -Exe $exe -StdErr $errlog -Arguments $launchArgs
    $appPid = $app.Pid
    $appPath = (Get-CimInstance Win32_Process -Filter "ProcessId=$appPid" -ErrorAction SilentlyContinue).ExecutablePath
    Write-Host "app under test: pid $appPid $appPath"
    $first = Wait-TestWindow -ProcessId $appPid -Class 'GhozttyWindow' -TimeoutMs 20000
    if ($first -eq [IntPtr]::Zero) { throw 'no first window' }
    Start-Sleep -Seconds 2  # settle: the first window's shell starts before window 1 is timed

    # The launch window is window 1; it is not CLI-named, so open a named
    # window 1 as the measured pane and close nothing: N counts every window.
    $n = 1
    $openTimes.Add((Open-Window $appPid 1))
    $n = 2
    $cps = @($Checkpoints -split ',' | ForEach-Object { [int]$_ } | Where-Object { $_ -le $Count } | Sort-Object -Unique)
    $last = 'wcs1a'
    $probe = 'wcs1a'
    foreach ($cp in $cps) {
        while ((Get-TopCount $appPid) -lt $cp) {
            $openTimes.Add((Open-Window $appPid $n))
            if (-not $Busy) { $last = "wcs${n}a" }
            $n++
        }
        Start-Sleep -Seconds 3  # settle: the newest shells reach their prompt before anything is measured
        $open = @($openTimes | Select-Object -Last 5)
        $echo = @()
        for ($e = 0; $e -lt 3; $e++) { $x = Measure-Echo $last; if ($null -ne $x) { $echo += $x } }
        $ui = Measure-UiLag $first
        $ipc = Measure-Ipc
        $cpu = Measure-IdleCpu $appPid $IdleSec
        $s = Get-Sample $appPid "N=$cp"
        $row = [pscustomobject]@{
            N = (Get-TopCount $appPid); OpenMs = [math]::Round((Get-Median $open), 0)
            EchoMs = $(if ($echo.Count) { [math]::Round((Get-Median $echo), 0) } else { $null })
            UiMedMs = [math]::Round($ui.Median, 2); UiMaxMs = [math]::Round($ui.Max, 1)
            IpcMs = [math]::Round($ipc, 0); AppCpu = $cpu.AppPct; DescCpu = $cpu.DescPct
            PrivMB = $s.PrivMB; GpuMB = $(if ($null -ne $s.GpuDedMB) { $s.GpuDedMB + $s.GpuShMB } else { $null })
            Threads = $s.Threads; Handles = $s.Handles; Gdi = $s.Gdi; User = $s.User; Procs = $s.Procs
        }
        [void]$rows.Add($row)
        Write-Host ("N={0,-3} threads: {1}" -f $row.N, (Measure-ThreadCensus $appPid $IdleSec))
        Write-Host ("N={0,-3} open={1}ms echo={2}ms ui={3}/{4}ms ipc={5}ms cpu app={6}% desc={7}% priv={8}MB gpu={9}MB thr={10}" -f `
            $row.N, $row.OpenMs, $row.EchoMs, $row.UiMedMs, $row.UiMaxMs, $row.IpcMs, $row.AppCpu, $row.DescCpu, $row.PrivMB, $row.GpuMB, $row.Threads)
    }

    Write-Host ''
    $rows | Format-Table -AutoSize | Out-String -Width 220 | Write-Host

    # ---- A: what the Nth window costs against the first checkpoint --------
    # Budgets are ratios against this run's own baseline plus a small floor,
    # so a slow box moves both ends together. Measured 2026-11-25 (Debug, 50
    # idle windows): open 53 -> 98 ms, echo 28 -> 32 ms, ui 0.67 -> 0.37 ms.
    $b0 = $rows[0]
    $bN = $rows[$rows.Count - 1]
    if (-not $MeasureOnly -and -not $Busy -and $rows.Count -ge 2) {
        Assert ($bN.OpenMs -le 3 * $b0.OpenMs + 50) ("A1 opening window {0} takes <= 3x window {1}'s + 50 ms ({2} vs {3} ms)" -f $bN.N, $b0.N, $bN.OpenMs, $b0.OpenMs)
        Assert ($null -ne $bN.EchoMs -and $bN.EchoMs -le 2 * $b0.EchoMs + 50) ("A2 keystroke to glyph with {0} windows <= 2x with {1} + 50 ms ({2} vs {3} ms)" -f $bN.N, $b0.N, $bN.EchoMs, $b0.EchoMs)
        Assert ($bN.UiMedMs -le 5) ("A3 the UI thread answers a message in <= 5 ms (median) with {0} windows ({1} ms)" -f $bN.N, $bN.UiMedMs)
        Assert ($bN.AppCpu -le 10) ("A4 {0} idle windows cost <= 10% of a core ({1}%)" -f $bN.N, $bN.AppCpu)
    }

    # ---- C: covered windows draw nothing, however many there are ---------
    # Every window onto the same rectangle (the newest in front), then every
    # pane but the first prints like a spinner. Only the front window can be
    # seen, so the occlusion poll (T1951) must stop every other renderer:
    # measured 2026-11-25 at 25 windows, 27% of a core stacked against 394%
    # cascaded. -NegativeControl leaves them cascaded, where each one shows a
    # strip and draws, so C1 MUST go red.
    if (-not $MeasureOnly -and -not $Busy) {
        if (-not $NegativeControl) {
            foreach ($w in @(Get-TestWindows -ProcessId $appPid -Class 'GhozttyWindow')) {
                [void](Set-TestWindowPos -Window ([IntPtr][int64]$w.Hwnd) -X 40 -Y 40 -Width 1000 -Height 700)
            }
        }
        for ($i = 2; $i -lt $n; $i++) { Start-BusyPane "wcs${i}a" }
        Start-Sleep -Seconds 4  # settle: the spinner loops start and the occlusion poll sees the stack
        $cpuC = Measure-IdleCpu $appPid $IdleSec
        Write-Host ("C  {0} windows, {1} printing: app {2}% desc {3}%  threads: {4}" -f (Get-TopCount $appPid), ($n - 2), $cpuC.AppPct, $cpuC.DescPct, (Measure-ThreadCensus $appPid $IdleSec))
        Assert ($cpuC.AppPct -le 100) ("C1 {0} stacked windows with busy panes cost <= one core: covered ones draw nothing ({1}%)" -f (Get-TopCount $appPid), $cpuC.AppPct)
        $echoC = Measure-Echo 'wcs1a'
        Assert ($null -ne $echoC -and $echoC -le 2 * $b0.EchoMs + 100) ("C2 keystroke to glyph in a quiet pane while {0} others print <= 2x baseline + 100 ms ({1} ms)" -f ($n - 2), $echoC)
    }

    $alive = Get-Process -Id $appPid -ErrorAction SilentlyContinue
    Assert ($null -ne $alive) 'B1 the app survived opening every window'
    Assert (-not (Test-TestDesktopLeak -ProcessId $appPid)) 'B2 GUI never became visible on the interactive desktop'
}
catch {
    Assert $false "the run threw and failed to finish its sections: $($_.Exception.Message)"
}
finally {
    [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
    Remove-TestDesktop
}

$fgSeen = @(Stop-TestForegroundWatch)
$leaked = @(Get-TestLaunchedPids | Where-Object { $fgSeen -contains $_ })
Assert ($leaked.Count -eq 0) "no test-desktop app ever became foreground on the interactive desktop (saw $($leaked -join ','))"

Complete-TestBody

# Only the verdict shape stamps (T783): the default count, idle, cascaded.
$verdictShape = ($Count -ge 50 -and -not $Busy -and -not $MeasureOnly -and $Layout -eq 'cascade' -and $Shape -eq 'single' -and $AppArgs.Count -eq 0 -and -not $ExePath)
if ($script:fail -eq 0 -and -not $NegativeControl -and $verdictShape) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard window-count-scale -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Skipped $script:skipped -Label 'WINDOW-COUNT-SCALE'
