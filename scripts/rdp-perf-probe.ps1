# rdp-perf-probe.ps1 - what Ghoztty costs inside THIS Windows session (T1950).
#
# Run it inside the Remote Desktop / Windows App / Cloud PC session where
# typing feels slow, then paste the report it writes (path printed at the end)
# into the issue. It is standalone: copy this one file to the remote machine,
# no repo needed.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File rdp-perf-probe.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File rdp-perf-probe.ps1 -Measure
#
# WHY. The 2026-10-14 report ("typing in ghoztty is so so slow" over Windows
# App; 15 cores and 2.5 GB with 24 panes) was answered from inference: no GPU,
# Mesa d3d12 on WARP, every frame rasterized on the CPU and then encoded for
# the wire. T1951 shipped low-power rendering on that theory and measured it on
# a console box with the software path FORCED. Nothing had ever measured the
# real session. This script is the instrument.
#
# WHAT IT DOES. Two parts.
#
#   1. Snapshot (always, read-only). The session (SM_REMOTESESSION, the
#      client), the display adapters, and every running ghoztty.exe: version,
#      the GL / D3D modules it has loaded (system opengl32 vs the bundled Mesa,
#      WARP), CPU in cores over -Seconds, busy threads (the WARP pool shows up
#      as a crowd of threads at ~10% each), memory, windows and panes, and the
#      renderer's own log lines ("loaded OpenGL ... renderer=", "low-power
#      rendering ..."). Nothing is launched and nothing is changed.
#
#   2. -Measure (opt-in). Starts a SEPARATE Ghoztty instance with its own pipe,
#      agent name and LOCALAPPDATA, so it cannot touch your windows or
#      sessions, with GHOZTTY_PERF=1 so it logs its frame rate. One window runs
#      a spinner (the shape of Claude Code's status animation) and a second,
#      focused window runs cmd. It measures, once with low-power rendering
#      pinned OFF and once on AUTO (what you normally get):
#        - fps, swap_avg_us and swap_max_ms per pane (the present cost)
#        - the instance's CPU in cores
#        - echo latency: a key sent to the cmd pane until it is on screen in
#          the terminal's buffer (median / p95). This is the server half of a
#          keystroke - it does not include the RDP encode and the trip to your
#          client, which only your eyes measure.
#      Two windows open for about a minute (they may take focus), then the
#      instance is closed. Only that instance's processes are stopped.
#
# Parameters:
#   -Exe <path>      ghoztty.exe to probe (default: the installed one, then PATH)
#   -Seconds <n>     sampling window per measurement (default 10)
#   -Measure         run part 2
#   -Modes <list>    low-power modes for part 2 (default off,auto)
#   -Out <path>      report path (default %TEMP%\ghoztty-rdp-probe-<time>.md)
#   -TestDesktop     (repo use) run part 2 on a background desktop through
#                    test\win32\lib\TestDesktop.ps1, so validation on a dev
#                    box never takes the user's foreground
#
# Exit 0 = report written. Exit 1 = no ghoztty.exe could be found.
# ASCII only (PowerShell 5.1 reads BOM-less files as ANSI).

param(
    [string]$Exe,
    [int]$Seconds = 10,
    [switch]$Measure,
    [string[]]$Modes = @('off', 'auto'),
    [string]$Out,
    [switch]$TestDesktop
)

$ErrorActionPreference = 'Stop'

# --- locate the app ---------------------------------------------------------
if (-not $Exe) {
    $installed = Join-Path $env:LOCALAPPDATA 'Programs\Ghoztty\ghoztty.exe'
    if (Test-Path $installed) { $Exe = $installed }
    else {
        $cmd = Get-Command ghoztty.exe -ErrorAction SilentlyContinue
        if ($cmd) { $Exe = $cmd.Source }
    }
}
if (-not $Exe -or -not (Test-Path $Exe)) {
    Write-Host 'rdp-perf-probe: no ghoztty.exe found (pass -Exe <path>)'
    exit 1
}
$Exe = (Resolve-Path $Exe).Path
# The console twin answers CLI verbs without a pipe; a GUI exe needs one.
$cli = [IO.Path]::ChangeExtension($Exe, '.com')
if (-not (Test-Path $cli)) { $cli = $Exe }
if (-not $Out) { $Out = Join-Path $env:TEMP ("ghoztty-rdp-probe-" + (Get-Date).ToString('yyyyMMdd-HHmmss') + '.md') }

$report = New-Object System.Collections.Generic.List[string]
function Add([string]$line) { $report.Add($line); Write-Host $line }

function Invoke-Cli([string[]]$a) {
    try { return (& $cli @a 2>&1 | Out-String).Trim() } catch { return "(failed: $($_.Exception.Message))" }
}

Add-Type -Namespace RdpProbe -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
[DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr hwnd);
[DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr hwnd, IntPtr dc);
[DllImport("gdi32.dll")] public static extern int GetDeviceCaps(IntPtr dc, int index);
'@

# CPU of a process over a window, in cores, plus how many threads were busy.
function Measure-ProcessCpu([int]$procId, [int]$secs) {
    $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
    if (-not $p) { return $null }
    $t0 = @{}
    foreach ($t in $p.Threads) { try { $t0[$t.Id] = $t.TotalProcessorTime.TotalMilliseconds } catch {} }
    $cpu0 = $p.TotalProcessorTime.TotalMilliseconds
    $w0 = [Diagnostics.Stopwatch]::StartNew()
    Start-Sleep -Seconds $secs
    $p.Refresh()
    if ($p.HasExited) { return $null }
    $wall = $w0.Elapsed.TotalMilliseconds
    $busy = @()
    foreach ($t in $p.Threads) {
        try {
            if ($t0.ContainsKey($t.Id)) {
                $share = ($t.TotalProcessorTime.TotalMilliseconds - $t0[$t.Id]) / $wall
                if ($share -ge 0.05) { $busy += $share }
            }
        } catch {}
    }
    $busy = @($busy | Sort-Object -Descending)
    [pscustomobject]@{
        Cores    = [math]::Round(($p.TotalProcessorTime.TotalMilliseconds - $cpu0) / $wall, 2)
        Threads  = $p.Threads.Count
        Busy     = $busy.Count
        BusyTop  = (($busy | Select-Object -First 6 | ForEach-Object { '{0:P0}' -f $_ }) -join ' ')
        WsMB     = [math]::Round($p.WorkingSet64 / 1MB)
        PrivMB   = [math]::Round($p.PrivateMemorySize64 / 1MB)
    }
}

$glPattern = '^(opengl32|libgallium_wgl|libglapi|d3d12|d3d12core|d3d10warp|dxil|dxgi|nvoglv64|atio6axx|ig.*icd64)\.dll$'
function Get-GlModules([int]$procId) {
    try {
        $p = Get-Process -Id $procId
        return @($p.Modules | Where-Object { $_.ModuleName -match $glPattern } | ForEach-Object {
            $f = $_.FileName
            # The fallback ships as <install>\gl\opengl32.dll (Mesa, T1251).
            if ($f -match '\\gl\\opengl32\.dll$') { "$f (bundled Mesa)" }
            elseif ($f -match '(?i)\\system32\\opengl32\.dll$') { "$f (system)" }
            else { $f }
        } | Sort-Object -Unique)
    } catch { return @("(modules unreadable: $($_.Exception.Message))") }
}

# Panes in one tab's split tree (`+list --json`: leaf | split with left/right).
function Get-LeafCount($node) {
    if (-not $node) { return 0 }
    if ($node.type -eq 'leaf') { return 1 }
    return (Get-LeafCount $node.left) + (Get-LeafCount $node.right)
}

function Read-Shared([string]$path) {
    if (-not (Test-Path $path)) { return '' }
    $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
    try { return (New-Object IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() }
}

# ---------------------------------------------------------------------------
# Part 1: snapshot
# ---------------------------------------------------------------------------
Add "# Ghoztty Remote Desktop probe"
Add ""
Add "Taken $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz')) on $env:COMPUTERNAME by rdp-perf-probe.ps1 (T1950)."
Add ""
Add "## Session"
Add ""
$remote = [RdpProbe.Native]::GetSystemMetrics(0x1000)   # SM_REMOTESESSION
$dc = [RdpProbe.Native]::GetDC([IntPtr]::Zero)
$dpi = [RdpProbe.Native]::GetDeviceCaps($dc, 88)        # LOGPIXELSX
[void][RdpProbe.Native]::ReleaseDC([IntPtr]::Zero, $dc)
$os = Get-CimInstance Win32_OperatingSystem
Add "- remote session: $(if ($remote -ne 0) { 'YES (SM_REMOTESESSION)' } else { 'no (console)' }); SESSIONNAME=$env:SESSIONNAME; CLIENTNAME=$env:CLIENTNAME"
Add "- OS: $($os.Caption) build $($os.BuildNumber); logical CPUs: $([Environment]::ProcessorCount); RAM: $([math]::Round($os.TotalVisibleMemorySize / 1MB, 1)) GB"
Add "- screen: $([RdpProbe.Native]::GetSystemMetrics(78))x$([RdpProbe.Native]::GetSystemMetrics(79)) virtual, $([RdpProbe.Native]::GetSystemMetrics(80)) monitor(s), $dpi dpi"
foreach ($v in @(Get-CimInstance Win32_VideoController)) {
    Add "- display adapter: $($v.Name) (driver $($v.DriverVersion), $($v.CurrentHorizontalResolution)x$($v.CurrentVerticalResolution))"
}
Add ""
Add "## Probed build"
Add ""
Add "- exe: $Exe"
Add "- version: $(((Invoke-Cli @('+version')) -split "`n")[0].Trim())"
Add ""
Add "## Running Ghoztty"
Add ""
$procs = @(Get-CimInstance Win32_Process -Filter "Name = 'ghoztty.exe'")
if ($procs.Count -eq 0) { Add "- no ghoztty.exe is running" }
foreach ($pr in $procs) {
    $pid0 = [int]$pr.ProcessId
    Add "### pid $pid0"
    Add ""
    Add "- path: $($pr.ExecutablePath)"
    $m = Measure-ProcessCpu $pid0 $Seconds
    if ($m) {
        Add "- CPU over $Seconds s: **$($m.Cores) cores**; threads $($m.Threads), busy (>=5%) $($m.Busy): $($m.BusyTop)"
        Add "- memory: working set $($m.WsMB) MB, private $($m.PrivMB) MB"
    } else { Add "- exited while sampling" }
    foreach ($g in (Get-GlModules $pid0)) { Add "- GL/D3D module: $g" }
}
if ($procs.Count -gt 0) {
    $listJson = Invoke-Cli @('+list', '--json')
    try {
        $wins = @(($listJson | ConvertFrom-Json).data.windows)
        $panes = 0
        foreach ($w in $wins) { foreach ($t in @($w.tabs)) { $panes += Get-LeafCount $t.splits } }
        Add "- windows: $($wins.Count), panes: $panes (from +list --json on the default pipe)"
    } catch { Add "- +list --json did not answer as JSON: $(($listJson -split "`n")[0])" }
}
Add ""
Add "## Renderer log lines"
Add ""
$userLog = Join-Path $env:LOCALAPPDATA 'ghoztty\ghoztty.log'
$lines = @((Read-Shared $userLog) -split "`n" | Where-Object { $_ -match 'loaded OpenGL|low-power|falling back|opengl32' } | Select-Object -Last 8)
if ($lines.Count -eq 0) { Add "- none in $userLog (the build may predate them, or the log rotated since launch)" }
foreach ($l in $lines) { Add "    $($l.Trim())" }
Add ""

# ---------------------------------------------------------------------------
# Part 2: a measured, isolated instance
# ---------------------------------------------------------------------------
if ($Measure) {
    if ($TestDesktop) {
        $lib = Join-Path $PSScriptRoot '..\test\win32\lib\TestDesktop.ps1'
        . (Resolve-Path $lib).Path
        [void](New-TestDesktop)
    }
    $tag = "rdpprobe$PID"
    $sandbox = Join-Path $env:TEMP "ghoztty-$tag"
    [void](New-Item -ItemType Directory -Force -Path $sandbox)
    $spin = Join-Path $sandbox 'spin.ps1'
    [IO.File]::WriteAllText($spin, @'
$c = '|/-\'
$i = 0
while ($true) { [Console]::Write("`r" + $c[$i % 4] + ' working ' + (Get-Date).ToString('HH:mm:ss.fff') + '   '); $i++; Start-Sleep -Milliseconds 80 }
'@)
    $saved = @{}
    foreach ($k in 'GHOZTTY_PIPE_SUFFIX', 'GHOZTTY_AGENT_INSTANCE', 'LOCALAPPDATA', 'GHOZTTY_PERF', 'GHOZTTY_LOW_POWER') {
        $saved[$k] = [Environment]::GetEnvironmentVariable($k)
    }
    $realLocal = $env:LOCALAPPDATA
    $env:GHOZTTY_PIPE_SUFFIX = "-$tag"
    $env:GHOZTTY_AGENT_INSTANCE = $tag
    $env:LOCALAPPDATA = $sandbox
    $env:GHOZTTY_PERF = '1'

    Add "## Measured instance (-Measure)"
    Add ""
    Add "Isolated: pipe suffix -$tag, agent instance $tag, LOCALAPPDATA $sandbox, session persistence off. A spinner window (80 ms frames) and a focused cmd window; $Seconds s per measurement."
    Add ""
    Add "| low-power | CPU cores | busy threads | spinner fps | cmd fps | swap_avg_us (max of panes) | swap_max_ms | echo median ms | echo p95 ms | samples | +read alone ms |"
    Add "|---|---|---|---|---|---|---|---|---|---|---|"
    $results = @()
    try {
        foreach ($mode in $Modes) {
            $env:GHOZTTY_LOW_POWER = $mode
            $errLog = Join-Path $sandbox "stderr-$mode.log"
            $launchArgs = @('--session-persistence=false', "--command=powershell -NoProfile -ExecutionPolicy Bypass -File `"$spin`"")
            if ($TestDesktop) {
                $app = Start-OnTestDesktop -Exe $Exe -Arguments $launchArgs
                $appPid = [int]$app.Pid
                $errLog = @($script:GhozttyTestDesktopLaunches | Where-Object { $_.Pid -eq $appPid })[0].StdErr
            } else {
                $p = Start-Process -FilePath $Exe -ArgumentList $launchArgs -PassThru -RedirectStandardError $errLog
                $appPid = $p.Id
            }
            # Wait for the instance's pipe to answer.
            $up = $false
            for ($t = 0; $t -lt 60 -and -not $up; $t++) {
                Start-Sleep -Milliseconds 250
                $up = ((Invoke-Cli @('+list', '--json')) -match '"success":\s*true')
            }
            if (-not $up) { Add "| $mode | (instance did not answer on its pipe) | | | | | | | | | |"; continue }
            $before = @()
            if ($TestDesktop) { $before = @(Get-TestWindows -ProcessId $appPid -Class 'GhozttyWindow' | ForEach-Object { [int64]$_.Hwnd }) }
            [void](Invoke-Cli @('+new-window', "--target=$tag-echo", '--name=probe-echo', '--command=cmd.exe', '--focus'))
            Start-Sleep -Seconds 3
            if ($TestDesktop) {
                # A background desktop has no foreground, so --focus cannot land
                # there: give the NEW window the keyboard by hand.
                $top = @(Get-TestWindows -ProcessId $appPid -Class 'GhozttyWindow' | Where-Object { $before -notcontains [int64]$_.Hwnd })[0]
                if ($top) {
                    [void](Set-TestActiveWindow -Window ([IntPtr]$top.Hwnd))
                    $pane = @(Get-TestChildWindows -Window ([IntPtr]$top.Hwnd) -Class 'GhozttyTerminal')[0]
                    if ($pane) { [void](Focus-TestWindow -Window ([IntPtr]$top.Hwnd) -Child ([IntPtr]$pane.Hwnd)) }
                }
            }
            # The cost of one +read on its own: the echo figure below cannot
            # resolve anything finer than this.
            $floor = @()
            for ($i = 0; $i -lt 5; $i++) {
                $sw = [Diagnostics.Stopwatch]::StartNew()
                [void](Invoke-Cli @('+read', '--name=probe-echo', '--lines=5'))
                $floor += $sw.Elapsed.TotalMilliseconds
            }
            $floorMed = [math]::Round(@($floor | Sort-Object)[2], 1)
            # Echo latency: a unique token sent to the cmd pane, until +read shows it.
            $echo = @()
            for ($i = 0; $i -lt 12; $i++) {
                $token = "q$i" + (Get-Random -Maximum 99999)
                $sw = [Diagnostics.Stopwatch]::StartNew()
                [void](Invoke-Cli @('+send-keys', '--target=probe-echo', '--enter', $token))
                $seen = $false
                while (-not $seen -and $sw.ElapsedMilliseconds -lt 3000) {
                    $seen = ((Invoke-Cli @('+read', '--name=probe-echo', '--lines=5')) -match $token)
                    if (-not $seen) { Start-Sleep -Milliseconds 5 }
                }
                if ($seen) { $echo += $sw.Elapsed.TotalMilliseconds }
                Start-Sleep -Milliseconds 150
            }
            # Present cost and CPU under the spinner, after the echo traffic settles.
            # A debug build logs to stderr, a release build to its ghoztty.log.
            $logs = @($errLog, (Join-Path $sandbox 'ghoztty\ghoztty.log'))
            $from = @($logs | ForEach-Object { (Read-Shared $_).Length })
            $m = Measure-ProcessCpu $appPid $Seconds
            $tail = ''
            for ($li = 0; $li -lt $logs.Count; $li++) {
                $txt = Read-Shared $logs[$li]
                $tail += $txt.Substring([math]::Min($from[$li], $txt.Length))
            }
            $rows = @([regex]::Matches($tail, 'perf pane=(\S+) fps=(\d+) max_gap_ms=(\d+) swap_max_ms=(\d+) swap_avg_us=(\d+)') | ForEach-Object {
                [pscustomobject]@{ Pane = $_.Groups[1].Value; Fps = [int]$_.Groups[2].Value; SwapMax = [int]$_.Groups[4].Value; SwapAvg = [int]$_.Groups[5].Value }
            })
            $byPane = @($rows | Group-Object Pane | ForEach-Object {
                [pscustomobject]@{ Fps = [math]::Round(($_.Group | Measure-Object Fps -Average).Average, 1); SwapAvg = [int]($_.Group | Measure-Object SwapAvg -Average).Average; SwapMax = [int]($_.Group | Measure-Object SwapMax -Maximum).Maximum }
            } | Sort-Object Fps -Descending)
            $sorted = @($echo | Sort-Object)
            $med = if ($sorted.Count) { [math]::Round($sorted[[int][math]::Floor(($sorted.Count - 1) / 2)], 1) } else { 'n/a' }
            $p95 = if ($sorted.Count) { [math]::Round($sorted[[int][math]::Ceiling(0.95 * $sorted.Count) - 1], 1) } else { 'n/a' }
            # The spinner is the pane that kept presenting; the cmd pane is idle under it.
            $spinFps = if ($byPane.Count -ge 1) { $byPane[0].Fps } else { 'n/a' }
            $cmdFps = if ($byPane.Count -ge 2) { $byPane[1].Fps } else { '0' }
            $swapAvg = if ($byPane.Count) { ($byPane | Measure-Object SwapAvg -Maximum).Maximum } else { 'n/a' }
            $swapMax = if ($byPane.Count) { ($byPane | Measure-Object SwapMax -Maximum).Maximum } else { 'n/a' }
            $cores = if ($m) { $m.Cores } else { 'n/a' }
            $busyN = if ($m) { $m.Busy } else { 'n/a' }
            Add "| $mode | $cores | $busyN | $spinFps | $cmdFps | $swapAvg | $swapMax | $med | $p95 | $($sorted.Count)/12 | $floorMed |"
            $results += [pscustomobject]@{ Mode = $mode; Cores = $cores; SpinFps = $spinFps; EchoMed = $med; Samples = $sorted.Count; PerfRows = $rows.Count }
            $gl = @((($logs | ForEach-Object { Read-Shared $_ }) -join "`n") -split "`n" | Where-Object { $_ -match 'loaded OpenGL|low-power rendering' } | Select-Object -First 3)
            foreach ($l in $gl) { Add "    [$mode] $($l.Trim())" }
            Add "    [$mode] instance pid $appPid"

            # Stop only this instance (and any child of it), never by name. On a
            # test desktop, tell its teardown this corpse is ours, not a crash.
            if ($TestDesktop) { @($script:GhozttyTestDesktopLaunches | Where-Object { $_.Pid -eq $appPid }) | ForEach-Object { $_.Killed = $true } }
            $kids = @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $appPid" | ForEach-Object { [int]$_.ProcessId })
            Stop-Process -Id $appPid -Force -ErrorAction SilentlyContinue
            foreach ($k in $kids) { Stop-Process -Id $k -Force -ErrorAction SilentlyContinue }
            Start-Sleep -Seconds 1
        }
    } finally {
        foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
        if ($TestDesktop) { Remove-TestDesktop }
    }
    Add ""
    Add "echo = a key sent with +send-keys to the cmd pane until +read shows it in the terminal buffer: the server half of a keystroke, without the RDP encode or the trip to the client."
    Add ""
    $script:ProbeResults = $results
}

$env:LOCALAPPDATA = if ($realLocal) { $realLocal } else { $env:LOCALAPPDATA }
[IO.File]::WriteAllLines($Out, $report)
Write-Host ""
Write-Host "REPORT $Out"
exit 0
