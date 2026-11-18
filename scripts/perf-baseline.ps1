# T2958 (step 1 of the T2957 performance audit): a repeatable baseline of what
# the Windows port costs - CPU idle and busy, memory and handle growth over a
# pane/tab open-close cycle, GPU memory and engine time, and the agent on its
# own - written as JSON with the METHOD beside every number, so a re-audit is
# a rerun and a diff rather than hand work.
#
# WHERE IT RUNS. Only on the hidden test desktop (test\win32\lib\TestDesktop.ps1),
# never the user's, and only against builds in this repo: zig-out (Debug) and
# zig-out-release (ReleaseFast, built by the command printed when it is
# missing). Every run takes all the isolating knobs (Set-GhozttyTestIsolation
# -ReleaseSandbox: private app pipe, private agent lineage, private
# LOCALAPPDATA) - for the Debug build too, so the agent measured is this run's
# and no other harness's. The installed Ghoztty is never touched.
#
# WHAT IT MEASURES (each phase is one fresh app):
#   idle    1 window, 1 pane at a cmd prompt, 10 s settle, then -IdleSeconds:
#           app CPU (% of one core), context switches/s (the wakeup rate,
#           summed over the app's threads from SystemProcessInformation), and
#           GPU engine utilisation. The wakeups are then split by thread
#           (T2989): the top 10 threads and every switch grouped by the
#           module the thread started in plus its name, and a census of the
#           kernel handle types, window classes and thread groups it holds.
#   busy   a pane that `type`s a generated -BusyMB file: wall time, app CPU
#           seconds and % of one core, GPU engine %; then -ResizeSeconds of
#           window resizes, same counters. The busy app runs under
#           GHOZTTY_PERF=1 and busy.perf is its own counter lines over the
#           span (T3059: pty reads and batches per second, bytes per batch,
#           queue_render, renderer wakeups, fps), with busy CPU and context
#           switches split by thread as for idle.
#   cycle   private bytes, working set, kernel/GDI/USER handles, threads, GPU
#           dedicated+shared memory and descendant processes: at start, after
#           10 panes over 3 tabs, after closing them all - twice, so the
#           first-cycle one-time costs (atlases, arenas) are separated from
#           what each cycle leaves behind. The residue is broken down by
#           kind (T2989): kernel handles by type, windows by class, threads
#           by group, and the USER objects that are not windows.
#           Then (T3005) warm-up cycles until two in a row are quiet, a
#           per-cycle SLOPE over -SettledCycles more (fill vs leak), a
#           closed-and-idle sample, a committed-memory split by owner
#           (heap / GPU write-combined pool / other, VirtualQueryEx), and on
#           Debug the DebugAllocator's leak report at a clean quit.
#           -AppEnv NAME=VALUE sets app env for A/B runs.
#   viewer  (T3033) one terminal plus three viewers split beside it - a
#           markdown file, git-status: on a scratch repo, a static page from a
#           loopback listener. open: the WebView2 tree (every msedgewebview2.exe
#           under the app, by --type= role) process count and private bytes,
#           app private bytes and GDI/USER growth, CPU over
#           -ViewerVisibleSeconds shown; hidden: a new tab over them, CPU and
#           private bytes over -ViewerHiddenSeconds; after_close: every viewer
#           closed, the tree every 10 s for -ViewerCloseSeconds (residual) and
#           the app's leak against before the first viewer.
#   agent   session persistence on: ghoztty-agent.exe idle CPU and wakeups,
#           private bytes per hosted session, and its handles/threads across
#           -AttachCycles app kill (detach) / relaunch (re-attach) cycles.
#
# A metric the box cannot read is null with a reason, never a guess.
#
# USAGE
#   powershell -NoProfile -File scripts\perf-baseline.ps1                       # both builds -> temp\perf-baseline-<stamp>.json
#   powershell -NoProfile -File scripts\perf-baseline.ps1 -Build Debug -Out x.json
#   powershell -NoProfile -File scripts\perf-baseline.ps1 -Compare a.json,b.json  # repeatability / regression diff
#
# -Compare exits 0 when every metric of b is within the stated tolerance of a,
# 1 otherwise, and prints one row per metric. The tolerances are in
# $script:Tolerance below and are written into every JSON it emits.
param(
    [ValidateSet('Both', 'Debug', 'Release')][string]$Build = 'Both',
    [string]$Out,
    [int]$IdleSeconds = 60,
    [int]$BusyMB = 64,
    # ascii: 108-char ASCII lines (a handful of glyphs, warm atlas after the
    # first screen). cjk: every CJK unified ideograph in turn, so nearly every
    # cell is a glyph the atlas has not seen - the font-atlas upload load
    # (T2973). The cjk file is written UTF-8 and typed under `chcp 65001`.
    [ValidateSet('ascii', 'cjk')][string]$BusyText = 'ascii',
    [int]$ResizeSeconds = 8,
    [int]$AgentSessions = 4,
    [int]$AttachCycles = 3,
    # T3033: the viewer phase's three spans - shown and idle, in a background
    # tab, and after closing every viewer (the residual WebView2 tree).
    [int]$ViewerVisibleSeconds = 60,
    [int]$ViewerHiddenSeconds = 60,
    [int]$ViewerCloseSeconds = 90,
    # all | idle | busy | cycle | viewer | agent, comma-separated or as an array
    [string[]]$Phase = @('all'),
    # The cycle phase's panes: mixed (3 tabs holding 4+3+3, the baseline
    # shape), tabs (10 tabs of one pane), splits (one tab of 10) or one (a
    # single split, 2 panes). An A/B knob for a residue that may follow tabs,
    # panes, or only the first pane ever opened (T2976).
    [ValidateSet('mixed', 'tabs', 'splits', 'one')][string]$CycleShape = 'mixed',
    # T3005: after the two classic cycles, keep cycling until two in a row
    # each grow private bytes and GPU memory by <= -SettleBudgetMB (cap
    # -CycleMaxWarmup), then measure -SettledCycles more and report the
    # per-cycle SLOPE: ~0 is bounded fill, a steady climb is a leak.
    # -SettledCycles 0 is the old two-cycle phase.
    [int]$SettledCycles = 5,
    [int]$CycleMaxWarmup = 8,
    [double]$SettleBudgetMB = 2.0,
    # A closed-and-idle sample this long after the last cycle: does what the
    # cycles left get trimmed back while nothing happens?
    [int]$CycleIdleSeconds = 30,
    # NAME=VALUE pairs set in the app's environment, for A/B runs
    # (GHOZTTY_COMP_PRESENT=0 and friends). Recorded in the JSON.
    [string[]]$AppEnv = @(),
    # T3016: the busy pane goes through the session agent (persistence on), so
    # its output crosses the app's agent connection - the path whose per-frame
    # cost the data-lane fix removed. Off keeps the classic local-pty number.
    [switch]$BusyPersistence,
    # T3159: with -BusyPersistence, run scripts\cpu-sample.ps1 over every
    # ghoztty-agent.exe of this build (daemon + the busy pane's holder) for
    # the busy span and write its report here. Sampling suspends the agent's
    # threads ~500 times a second, so a sampled run's wall time is not a
    # baseline number - leave it off for those.
    [string]$SampleAgent,
    [string[]]$Compare,
    # T3111: measure this ghoztty.exe instead of the build's zig-out folder -
    # an A/B against an older commit built into its own prefix. Only with
    # -Build Debug or -Build Release, and it must be a zig-out* build tree.
    [string]$Exe,
    # T3111: check the CPU-time reader against Get-Process and exit.
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$Phase = @($Phase | ForEach-Object { "$_" -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$bad = @($Phase | Where-Object { @('all', 'idle', 'busy', 'cycle', 'viewer', 'agent') -notcontains $_ })
if ($bad.Count) { Write-Host "unknown -Phase: $($bad -join ',')"; exit 2 }
$AppEnv = @($AppEnv | ForEach-Object { "$_" -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$appEnvMap = [ordered]@{}
foreach ($kv in $AppEnv) {
    if ($kv -notmatch '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') { Write-Host "bad -AppEnv entry (want NAME=VALUE): $kv"; exit 2 }
    $appEnvMap[$Matches[1]] = $Matches[2]
}
$repo = Split-Path $PSScriptRoot -Parent
$lib = Join-Path $repo 'test\win32\lib'

# Relative tolerance and absolute floor per metric family: b is within when
# |b - a| <= max(abs, rel * |a|). Wide on CPU and GPU engine time (scheduler
# and DWM noise), tight on handle and object counts.
$script:Tolerance = [ordered]@{
    cpu_pct       = @{ rel = 0.50; abs = 0.5;  note = 'percent of one core' }
    # T3111: an idle app runs at a few tenths of a percent, so the 0.5 floor
    # above let 0.03% -> 0.21% (7x) pass as "within tolerance". The idle floor
    # is two clock ticks over the 60 s span (2 x 15.6 ms / 60 s = 0.052%).
    idle_cpu_pct  = @{ rel = 0.50; abs = 0.05; note = 'idle percent of one core: floor of two clock ticks over 60 s' }
    wakeups       = @{ rel = 0.35; abs = 20;   note = 'context switches per second' }
    seconds       = @{ rel = 0.30; abs = 0.5;  note = 'wall or CPU seconds' }
    mb            = @{ rel = 0.15; abs = 5;    note = 'megabytes' }
    delta_mb      = @{ rel = 0.50; abs = 15;   note = 'megabytes left behind by an open/close cycle: a difference of two readings, so it carries the noise of both (run1 27.3 vs run2 36.1 MB on 2026-11-14)' }
    gpu_mb        = @{ rel = 0.20; abs = 5;    note = 'GPU megabytes' }
    gpu_pct       = @{ rel = 0.75; abs = 3;    note = 'GPU engine percent' }
    handles       = @{ rel = 0.10; abs = 30;   note = 'kernel handles' }
    objects       = @{ rel = 0.10; abs = 10;   note = 'GDI or USER objects' }
    threads       = @{ rel = 0.15; abs = 3;    note = 'threads' }
    count         = @{ rel = 0.00; abs = 1;    note = 'process or session counts' }
    perf_rate     = @{ rel = 0.35; abs = 5;    note = 'the app''s GHOZTTY_PERF counters (reads, batches, renders, wakeups, fps per second; bytes per batch): rates set by the scheduler as much as by the code, so the wakeups tolerance' }
}

# ---------------------------------------------------------------- compare
function Get-MetricFamily([string]$Path) {
    $leaf = ($Path -split '\.')[-1]
    # T3059: the app's own GHOZTTY_PERF counters. Window counts follow the
    # span's wall time and are not a metric.
    if ($Path -match '\.perf\.windows\.' -or $leaf -match '_gap_') { return $null }
    if ($Path -match '\.perf\.') { return 'perf_rate' }
    if ($Path -match '\.leak\.'-and $leaf -match '_mb$' -and $leaf -notmatch 'gpu') { return 'delta_mb' }
    # T3111: idle CPU (the app's idle phase, the agent's idle_cpu_pct) has its
    # own small floor; busy and resize CPU keep the wide one.
    if ($leaf -match '^(idle_)?cpu.*pct$' -and ($Path -match '\.idle\.' -or $leaf -like 'idle_*')) { return 'idle_cpu_pct' }
    switch -regex ($leaf) {
        'gpu.*_mb$' { return 'gpu_mb' }
        'gpu.*pct'  { return 'gpu_pct' }
        '^cpu.*pct$' { return 'cpu_pct' }
        'wakeups'   { return 'wakeups' }
        '_s$|seconds' { return 'seconds' }
        '_mb$'      { return 'mb' }
        'handles'   { return 'handles' }
        'gdi|user'  { return 'objects' }
        'threads'   { return 'threads' }
        'procs|sessions|attached' { return 'count' }
        default     { return $null }
    }
}

# Flatten every numeric leaf under "builds" into path -> value.
function Get-Leaves([object]$Node, [string]$Prefix, [hashtable]$Acc) {
    if ($null -eq $Node) { return }
    if ($Node -is [System.Management.Automation.PSCustomObject]) {
        foreach ($p in $Node.PSObject.Properties) {
            if ($p.Name -eq 'method' -or $p.Name -eq 'reason') { continue }
            Get-Leaves $p.Value ($(if ($Prefix) { "$Prefix.$($p.Name)" } else { $p.Name })) $Acc
        }
        return
    }
    if ($Node -is [double] -or $Node -is [int] -or $Node -is [long] -or $Node -is [decimal]) { $Acc[$Prefix] = [double]$Node }
}

if ($Compare) {
    # Under -File a comma list arrives as ONE string.
    $Compare = @($Compare | ForEach-Object { "$_" -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($Compare.Count -ne 2) { Write-Host 'usage: -Compare <a.json>,<b.json>'; exit 2 }
    $a = Get-Content -Raw $Compare[0] | ConvertFrom-Json
    $b = Get-Content -Raw $Compare[1] | ConvertFrom-Json
    $la = @{}; $lb = @{}
    Get-Leaves $a.builds '' $la
    Get-Leaves $b.builds '' $lb
    $bad = 0; $rows = 0
    foreach ($k in ($la.Keys | Sort-Object)) {
        $fam = Get-MetricFamily $k
        if (-not $fam) { continue }
        if (-not $lb.ContainsKey($k)) { Write-Host ("MISSING  {0}" -f $k); $bad++; continue }
        $t = $script:Tolerance[$fam]
        $va = $la[$k]; $vb = $lb[$k]
        $lim = [math]::Max($t.abs, $t.rel * [math]::Abs($va))
        $ok = [math]::Abs($vb - $va) -le $lim
        $rows++
        if (-not $ok) { $bad++ }
        Write-Host ("{0,-6} {1,-58} {2,12:N2} {3,12:N2}  (+-{4:N2} {5})" -f $(if ($ok) { 'ok' } else { 'OUT' }), $k, $va, $vb, $lim, $fam)
    }
    Write-Host ''
    if ($bad -eq 0) { Write-Host "COMPARE WITHIN TOLERANCE ($rows metrics)"; exit 0 }
    Write-Host "COMPARE OUT OF TOLERANCE: $bad of $rows metrics"
    exit 1
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if (-not $Out) { $Out = Join-Path $repo "temp\perf-baseline-$stamp.json" }
$Out = [IO.Path]::GetFullPath($Out)
New-Item -ItemType Directory -Force (Split-Path $Out -Parent) | Out-Null
$commit = (& git -C $repo rev-parse --short HEAD 2>$null)

# ---------------------------------------------------------------- both
# Each build runs in its own child process: isolation is process-wide env
# (pipe suffix, agent lineage, LOCALAPPDATA), so one process per build is the
# only way the two cannot share anything.
if ($Build -eq 'Both' -and $Exe) { Write-Host 'PERF BASELINE: -Exe needs -Build Debug or -Build Release'; exit 2 }
if ($Build -eq 'Both' -and -not $SelfTest) {
    $parts = [ordered]@{}
    $exit = 0
    foreach ($b in @('Debug', 'Release')) {
        $part = Join-Path $env:TEMP "perf-baseline-$b-$PID.json"
        $childArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-Build', $b, '-Out', $part,
            '-IdleSeconds', $IdleSeconds, '-BusyMB', $BusyMB, '-BusyText', $BusyText, '-ResizeSeconds', $ResizeSeconds,
            '-AgentSessions', $AgentSessions, '-AttachCycles', $AttachCycles, '-Phase', ($Phase -join ','),
            '-CycleShape', $CycleShape, '-SettledCycles', $SettledCycles, '-CycleMaxWarmup', $CycleMaxWarmup,
            '-SettleBudgetMB', $SettleBudgetMB, '-CycleIdleSeconds', $CycleIdleSeconds,
            '-ViewerVisibleSeconds', $ViewerVisibleSeconds, '-ViewerHiddenSeconds', $ViewerHiddenSeconds, '-ViewerCloseSeconds', $ViewerCloseSeconds)
        if ($AppEnv.Count) { $childArgs += @('-AppEnv', ($AppEnv -join ',')) }
        if ($BusyPersistence) { $childArgs += '-BusyPersistence' }
        if ($SampleAgent) { $childArgs += @('-SampleAgent', ([IO.Path]::ChangeExtension([IO.Path]::GetFullPath($SampleAgent), ".$($b.ToLower()).json"))) }
        Write-Host "== $b build"
        & powershell @childArgs
        if ($LASTEXITCODE -ne 0) { $exit = 1 }
        if (Test-Path $part) {
            $parts[$b.ToLower()] = (Get-Content -Raw $part | ConvertFrom-Json).builds.($b.ToLower())
            Remove-Item $part -ErrorAction SilentlyContinue
        } else {
            $parts[$b.ToLower()] = [pscustomobject]@{ error = "the $b run wrote no result (exit $LASTEXITCODE)" }
        }
    }
    $doc = [ordered]@{
        schema    = 'ghoztty-perf-baseline/1'
        task      = 'T2958'
        generated = (Get-Date).ToString('o')
        commit    = $commit
        machine   = [ordered]@{
            cpu   = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name
            cores = [Environment]::ProcessorCount
            ram_gb = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
            gpu   = ((Get-CimInstance Win32_VideoController | ForEach-Object { $_.Name }) -join '; ')
            os    = (Get-CimInstance Win32_OperatingSystem).Version
        }
        parameters = [ordered]@{ idle_seconds = $IdleSeconds; busy_mb = $BusyMB; busy_text = $BusyText; resize_seconds = $ResizeSeconds; agent_sessions = $AgentSessions; attach_cycles = $AttachCycles; cycle_shape = $CycleShape; settled_cycles = $SettledCycles; cycle_max_warmup = $CycleMaxWarmup; settle_budget_mb = $SettleBudgetMB; cycle_idle_seconds = $CycleIdleSeconds; viewer_visible_seconds = $ViewerVisibleSeconds; viewer_hidden_seconds = $ViewerHiddenSeconds; viewer_close_seconds = $ViewerCloseSeconds; app_env = $appEnvMap }
        tolerance = $script:Tolerance
        builds    = $parts
    }
    $doc | ConvertTo-Json -Depth 12 | Set-Content -Path $Out -Encoding ascii
    Write-Host ''
    Write-Host "PERF BASELINE written: $Out"
    exit $exit
}

# ---------------------------------------------------------------- one build
. (Join-Path $lib 'CleanSlate.ps1')
. (Join-Path $lib 'Isolation.ps1')
. (Join-Path $lib 'TestDesktop.ps1')
. (Join-Path $lib 'ProcessMemory.ps1')
. (Join-Path $lib 'JobTeardown.ps1')

$isRelease = $Build -eq 'Release'

if (-not ('PerfSnap' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class PerfSnap {
    [DllImport("ntdll.dll")] static extern int NtQuerySystemInformation(int cls, IntPtr buf, int len, out int ret);
    // SystemProcessInformation (class 5), x64 layout: the process record is
    // 0x100 bytes (NumberOfThreads at 0x04, CycleTime at 0x18, CreateTime at
    // 0x20, UserTime at 0x28, KernelTime at 0x30, UniqueProcessId at 0x50),
    // followed by NumberOfThreads SYSTEM_THREAD_INFORMATION records of 0x50
    // bytes, ContextSwitches at 0x40.
    //
    // T3111: until 2026-11-15 this read 0x20 + 0x28 as "user + kernel". 0x20
    // is CreateTime, a constant, so every cpu_pct in baselines 1-3 was USER
    // time only - kernel time was never counted. Verified against
    // Get-Process (StartTime / UserProcessorTime / PrivilegedProcessorTime).
    // Returns { user+kernel, contextSwitches, threads, user, kernel, cycles }.
    public static long[] Read(int pid) {
        int len = 4 << 20;
        for (int tries = 0; tries < 6; tries++) {
            IntPtr buf = Marshal.AllocHGlobal(len);
            try {
                int ret;
                int st = NtQuerySystemInformation(5, buf, len, out ret);
                if ((uint)st == 0xC0000004u) { len *= 2; continue; }
                if (st != 0) return null;
                long p = buf.ToInt64();
                while (true) {
                    int next = Marshal.ReadInt32(new IntPtr(p));
                    long id = Marshal.ReadIntPtr(new IntPtr(p + 0x50)).ToInt64();
                    if (id == pid) {
                        int n = Marshal.ReadInt32(new IntPtr(p + 4));
                        long cycles = Marshal.ReadInt64(new IntPtr(p + 0x18));
                        long user = Marshal.ReadInt64(new IntPtr(p + 0x28));
                        long kern = Marshal.ReadInt64(new IntPtr(p + 0x30));
                        long cs = 0;
                        for (int i = 0; i < n; i++) cs += (uint)Marshal.ReadInt32(new IntPtr(p + 0x100 + i * 0x50 + 0x40));
                        return new long[] { user + kern, cs, n, user, kern, cycles };
                    }
                    if (next == 0) return null;
                    p += next;
                }
            } finally { Marshal.FreeHGlobal(buf); }
        }
        return null;
    }

    // T2989: the same snapshot, per thread - flattened [tid, contextSwitches]
    // pairs - so a wakeup rate can be split by the thread that woke. Thread id
    // is CLIENT_ID.UniqueThread at 0x30 of each 0x50-byte thread record.
    public static long[] Threads(int pid) {
        int len = 4 << 20;
        for (int tries = 0; tries < 6; tries++) {
            IntPtr buf = Marshal.AllocHGlobal(len);
            try {
                int ret;
                int st = NtQuerySystemInformation(5, buf, len, out ret);
                if ((uint)st == 0xC0000004u) { len *= 2; continue; }
                if (st != 0) return null;
                long p = buf.ToInt64();
                while (true) {
                    int next = Marshal.ReadInt32(new IntPtr(p));
                    long id = Marshal.ReadIntPtr(new IntPtr(p + 0x50)).ToInt64();
                    if (id == pid) {
                        int n = Marshal.ReadInt32(new IntPtr(p + 4));
                        var o = new long[n * 2];
                        for (int i = 0; i < n; i++) {
                            long t = p + 0x100 + i * 0x50;
                            o[i * 2] = Marshal.ReadIntPtr(new IntPtr(t + 0x30)).ToInt64();
                            o[i * 2 + 1] = (uint)Marshal.ReadInt32(new IntPtr(t + 0x40));
                        }
                        return o;
                    }
                    if (next == 0) return null;
                    p += next;
                }
            } finally { Marshal.FreeHGlobal(buf); }
        }
        return null;
    }

    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenThread(uint access, bool inherit, uint tid);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll")] static extern int GetThreadDescription(IntPtr h, out IntPtr desc);
    [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr p);
    [DllImport("ntdll.dll")] static extern int NtQueryInformationThread(IntPtr h, int cls, out IntPtr info, int len, IntPtr ret);
    [DllImport("kernel32.dll")] static extern bool QueryThreadCycleTime(IntPtr h, out ulong cycles);
    [DllImport("ntdll.dll")] static extern int NtQueryTimerResolution(out uint min, out uint max, out uint cur);
    // T3111: the current system clock interval in 100 ns units (156250 is
    // the default 15.6 ms; 10000 is a 1 ms timeBeginPeriod), -1 unread.
    public static long TimerResolution100ns() {
        uint mn, mx, cur;
        return NtQueryTimerResolution(out mn, out mx, out cur) == 0 ? (long)cur : -1;
    }
    // T3111: a live thread's exact cycle count (QueryThreadCycleTime), -1
    // when it cannot be opened. Unlike UserTime/KernelTime, which the clock
    // tick charges in whole 15.6 ms quanta to whatever thread it interrupts,
    // this counts every cycle the thread ran, so a thread that wakes 60
    // times a second for microseconds is measured, not sampled.
    public static long Cycles(uint tid) {
        IntPtr h = OpenThread(0x0800, false, tid); // QUERY_LIMITED_INFORMATION
        if (h == IntPtr.Zero) return -1;
        try {
            ulong c;
            return QueryThreadCycleTime(h, out c) ? (long)c : -1;
        } finally { CloseHandle(h); }
    }
    // A live thread's name (SetThreadDescription; "" when it has none) and
    // its Win32 start address (ThreadQuerySetWin32StartAddress, class 9) -
    // the function the creator passed, not RtlUserThreadStart. Null when the
    // thread has already exited.
    public static object[] Describe(uint tid) {
        IntPtr h = OpenThread(0x0040 | 0x0800, false, tid); // QUERY_INFORMATION | QUERY_LIMITED_INFORMATION
        if (h == IntPtr.Zero) return null;
        try {
            string name = "";
            IntPtr d;
            if (GetThreadDescription(h, out d) >= 0 && d != IntPtr.Zero) {
                name = Marshal.PtrToStringUni(d) ?? "";
                LocalFree(d);
            }
            IntPtr start;
            long addr = NtQueryInformationThread(h, 9, out start, IntPtr.Size, IntPtr.Zero) == 0 ? start.ToInt64() : 0;
            return new object[] { name, addr };
        } finally { CloseHandle(h); }
    }
}
'@
}

# T3111: -SelfTest checks the SystemProcessInformation reader against
# Get-Process for THIS process - the offsets once read CreateTime as kernel
# time and nothing noticed for three baselines. No app, no desktop.
if ($SelfTest) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $tmp = [IO.Path]::GetTempFileName()
    while ($sw.ElapsedMilliseconds -lt 1500) { [void][IO.File]::GetAttributes($tmp); $x = 0; for ($k = 0; $k -lt 2000; $k++) { $x += $k } }
    Remove-Item $tmp
    $me = Get-Process -Id $PID
    $r = [PerfSnap]::Read($PID)
    $me.Refresh()
    $u = $me.UserProcessorTime.Ticks; $k = $me.PrivilegedProcessorTime.Ticks
    $tick = 156250
    $okU = [math]::Abs($r[3] - $u) -le 2 * $tick
    $okK = [math]::Abs($r[4] - $k) -le 2 * $tick
    $okSum = $r[0] -eq ($r[3] + $r[4])
    $okCy = $r[5] -gt 0
    Write-Host ("SELFTEST user   reader={0} get-process={1} {2}" -f $r[3], $u, $(if ($okU) { 'ok' } else { 'MISMATCH' }))
    Write-Host ("SELFTEST kernel reader={0} get-process={1} {2}" -f $r[4], $k, $(if ($okK) { 'ok' } else { 'MISMATCH' }))
    Write-Host ("SELFTEST total  reader={0} = user+kernel {1}" -f $r[0], $(if ($okSum) { 'ok' } else { 'MISMATCH' }))
    Write-Host ("SELFTEST cycles reader={0} {1}" -f $r[5], $(if ($okCy) { 'ok' } else { 'MISSING' }))
    $tr = [PerfSnap]::TimerResolution100ns()
    Write-Host ("SELFTEST timer  {0} ms" -f $(if ($tr -gt 0) { $tr / 1e4 } else { 'unread' }))
    if ($okU -and $okK -and $okSum -and $okCy -and $k -gt 0) { Write-Host 'SELFTEST PASS'; exit 0 }
    Write-Host 'SELFTEST FAIL'; exit 1
}

$exe = Join-Path $repo $(if ($isRelease) { 'zig-out-release\bin\ghoztty.exe' } else { 'zig-out\bin\ghoztty.exe' })
if ($Exe) {
    $exe = [IO.Path]::GetFullPath($Exe)
    # Never the user's install (CLAUDE.md non-negotiable): only a build tree.
    if ($exe -notmatch '\\zig-out[^\\]*\\bin\\ghoztty\.exe$') {
        Write-Host "PERF BASELINE: -Exe must be a zig-out*\bin\ghoztty.exe build tree, not $exe"
        exit 2
    }
}
if (-not (Test-Path $exe)) {
    Write-Host "PERF BASELINE: $exe is missing. Build it with:"
    if ($isRelease) { Write-Host '  zig build -Dapp-runtime=win32 -Doptimize=ReleaseFast -Dtarget=x86_64-windows-gnu -Dstrip=false --prefix zig-out-release' }
    else { Write-Host '  zig build -Dapp-runtime=win32 -Doptimize=Debug' }
    exit 2
}
[void](Set-GhozttyTestIsolation -Tag 'perfb' -ReleaseSandbox -Quiet)
# Inherited by every app this run starts.
foreach ($k in $appEnvMap.Keys) { Set-Item -Path "env:$k" -Value $appEnvMap[$k] }
$work = Join-Path $env:TEMP "ghoztty-perfb-$PID"
New-Item -ItemType Directory -Force $work | Out-Null

# T2989: every window a process owns on the test desktop - top-levels (hidden
# included), their children, and message-only windows - counted by class and
# kind. Windows are the one USER object type that can be enumerated, so a USER
# count that moves while this census does not is menus, icons, cursors, hooks
# or accelerator tables. Runs on a fresh thread bound to the desktop: window
# enumeration is scoped to the calling thread's desktop, and SetThreadDesktop
# refuses a thread that already owns windows (the PowerShell host's does).
if (-not ('PerfWindows' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
public static class PerfWindows {
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern IntPtr OpenDesktopW(string name, uint flags, bool inherit, uint access);
    [DllImport("user32.dll")] static extern bool CloseDesktop(IntPtr h);
    [DllImport("user32.dll", SetLastError = true)] static extern bool SetThreadDesktop(IntPtr h);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr parent, EnumProc f, IntPtr l);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindowExW(IntPtr parent, IntPtr after, string cls, string title);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder sb, int max);

    static string Cls(IntPtr h) { var sb = new StringBuilder(256); GetClassNameW(h, sb, 256); return sb.ToString(); }
    static void Add(Dictionary<string, int> d, string k) { int c; d.TryGetValue(k, out c); d[k] = c + 1; }

    // "kind:class" -> count, kind one of top / child / msg. Null on failure,
    // with the reason in Error.
    public static string Error = "";
    public static Dictionary<string, int> Census(string desktop, uint pid) {
        Dictionary<string, int> result = null;
        string err = "";
        var t = new Thread(delegate() {
            IntPtr hd = IntPtr.Zero;
            if (!string.IsNullOrEmpty(desktop)) {
                hd = OpenDesktopW(desktop, 0, false, 0x0001 | 0x0040); // READOBJECTS | ENUMERATE
                if (hd == IntPtr.Zero) { err = "OpenDesktop(" + desktop + ") failed: " + Marshal.GetLastWin32Error(); return; }
                if (!SetThreadDesktop(hd)) { err = "SetThreadDesktop failed: " + Marshal.GetLastWin32Error(); CloseDesktop(hd); return; }
            }
            try {
                var d = new Dictionary<string, int>();
                var tops = new List<IntPtr>();
                EnumWindows(delegate(IntPtr h, IntPtr l) {
                    uint p; GetWindowThreadProcessId(h, out p);
                    if (p == pid) tops.Add(h);
                    return true;
                }, IntPtr.Zero);
                foreach (var h in tops) {
                    Add(d, "top:" + Cls(h));
                    EnumChildWindows(h, delegate(IntPtr c, IntPtr l) { Add(d, "child:" + Cls(c)); return true; }, IntPtr.Zero);
                }
                IntPtr m = IntPtr.Zero;
                for (int guard = 0; guard < 100000; guard++) {
                    m = FindWindowExW(new IntPtr(-3), m, null, null);
                    if (m == IntPtr.Zero) break;
                    uint p; GetWindowThreadProcessId(m, out p);
                    if (p == pid) Add(d, "msg:" + Cls(m));
                }
                result = d;
            } finally { if (hd != IntPtr.Zero) CloseDesktop(hd); }
        });
        t.Start();
        if (!t.Join(15000)) { Error = "window census timed out"; return null; }
        Error = err;
        return result;
    }
}
'@
}

# T3005: where the app's committed memory lives, by owner, read from outside
# with VirtualQueryEx - no debugger, no injected thread. Every committed
# region is put in one class:
#   heap          MEM_PRIVATE inside an allocation that starts with an NT heap
#                 segment (0xffeeffee) or segment-heap (0xddeeddee) signature
#                 at +0x10 - the NT heaps, LFH included. A heap's large blocks
#                 (VirtualAlloc'd past the heap threshold) carry no signature
#                 and land in private_rw.
#   writecombine  MEM_PRIVATE with PAGE_WRITECOMBINE: the GPU driver's upload
#                 pool (T2782's census).
#   uncached      MEM_PRIVATE with PAGE_NOCACHE.
#   stack         MEM_PRIVATE in an allocation that holds a PAGE_GUARD region.
#   private_rw    every other MEM_PRIVATE region (Zig's page allocator - the
#                 whole Debug DebugAllocator - driver arenas, heap large blocks).
#   mapped        MEM_MAPPED (sections, including GPU shared allocations).
#   image         MEM_IMAGE.
if (-not ('PerfRegions' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class PerfRegions {
    [StructLayout(LayoutKind.Sequential)]
    struct MBI { public IntPtr BaseAddress; public IntPtr AllocationBase; public uint AllocationProtect; public ushort PartitionId; public IntPtr RegionSize; public uint State; public uint Protect; public uint Type; }
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll")] static extern IntPtr VirtualQueryEx(IntPtr p, IntPtr addr, out MBI mbi, IntPtr len);
    [DllImport("kernel32.dll")] static extern bool ReadProcessMemory(IntPtr p, IntPtr addr, byte[] buf, IntPtr len, out IntPtr read);

    public static string Error = "";
    // class -> committed bytes, plus "regions:<class>" -> region count.
    public static Dictionary<string, long> Census(int pid) {
        Error = "";
        IntPtr h = OpenProcess(0x0400 | 0x0010, false, pid); // QUERY_INFORMATION | VM_READ
        if (h == IntPtr.Zero) { Error = "OpenProcess failed: " + Marshal.GetLastWin32Error(); return null; }
        try {
            var regions = new List<MBI>();
            var guarded = new HashSet<long>();
            long addr = 0;
            int size = Marshal.SizeOf(typeof(MBI));
            while (true) {
                MBI m;
                if (VirtualQueryEx(h, new IntPtr(addr), out m, new IntPtr(size)) == IntPtr.Zero) break;
                long rs = m.RegionSize.ToInt64();
                if (rs <= 0) break;
                if (m.State == 0x1000) {
                    regions.Add(m);
                    if ((m.Protect & 0x100) != 0) guarded.Add(m.AllocationBase.ToInt64());
                }
                addr = m.BaseAddress.ToInt64() + rs;
                if (addr <= 0) break;
            }
            var heapBase = new Dictionary<long, bool>();
            var d = new Dictionary<string, long>();
            string[] all = { "heap", "writecombine", "uncached", "stack", "private_rw", "mapped", "image" };
            foreach (var k in all) { d[k] = 0; d["regions:" + k] = 0; }
            byte[] buf = new byte[0x18];
            foreach (var m in regions) {
                string cls;
                long ab = m.AllocationBase.ToInt64();
                if (m.Type == 0x1000000) cls = "image";
                else if (m.Type == 0x40000) cls = "mapped";
                else if ((m.Protect & 0x400) != 0) cls = "writecombine";
                else if ((m.Protect & 0x200) != 0) cls = "uncached";
                else if (guarded.Contains(ab)) cls = "stack";
                else {
                    bool isHeap;
                    if (!heapBase.TryGetValue(ab, out isHeap)) {
                        IntPtr got;
                        isHeap = false;
                        if (ReadProcessMemory(h, new IntPtr(ab), buf, new IntPtr(buf.Length), out got) && got.ToInt64() == buf.Length) {
                            uint sig = BitConverter.ToUInt32(buf, 0x10);
                            isHeap = sig == 0xffeeffeeu || sig == 0xddeeddeeu;
                        }
                        heapBase[ab] = isHeap;
                    }
                    cls = isHeap ? "heap" : "private_rw";
                }
                d[cls] += m.RegionSize.ToInt64();
                d["regions:" + cls] += 1;
            }
            return d;
        } finally { CloseHandle(h); }
    }

    // T3130: the private_rw class split by ALLOCATION (one VirtualAlloc
    // reservation), so a residue can be named by shape. Per allocation base:
    // reserved bytes, committed bytes, and a kind -
    //   heap_large  first qword points into an NT heap: a HEAP_VIRTUAL_ALLOC
    //               block (malloc above the heap threshold), its LIST_ENTRY.
    //   exact       the whole reservation is committed: what Zig's
    //               page_allocator (and any VirtualAlloc(COMMIT|RESERVE)) makes.
    //   arena       part of the reservation is only reserved: a grow-in-place
    //               arena (GL driver pools, std.heap.ArenaAllocator never is).
    // Returns base -> {reserve, commit, kind} as a flat long[3] (kind 0/1/2).
    public static Dictionary<long, long[]> Allocs(int pid) {
        Error = "";
        IntPtr h = OpenProcess(0x0400 | 0x0010, false, pid);
        if (h == IntPtr.Zero) { Error = "OpenProcess failed: " + Marshal.GetLastWin32Error(); return null; }
        try {
            var info = new Dictionary<long, long[]>(); // base -> reserve, commit, flags(1=guard,2=nonprivate,4=wc/nc,8=heap)
            long addr = 0;
            int size = Marshal.SizeOf(typeof(MBI));
            while (true) {
                MBI m;
                if (VirtualQueryEx(h, new IntPtr(addr), out m, new IntPtr(size)) == IntPtr.Zero) break;
                long rs = m.RegionSize.ToInt64();
                if (rs <= 0) break;
                if (m.State != 0x10000) {
                    long ab = m.AllocationBase.ToInt64();
                    long[] e;
                    if (!info.TryGetValue(ab, out e)) { e = new long[4]; info[ab] = e; }
                    e[0] += rs;
                    if (m.State == 0x1000) {
                        e[1] += rs;
                        if ((m.Protect & 0x100) != 0) e[3] |= 1;
                        if ((m.Protect & 0x600) != 0) e[3] |= 4;
                    }
                    if (m.Type != 0x20000) e[3] |= 2;
                }
                addr = m.BaseAddress.ToInt64() + rs;
                if (addr <= 0) break;
            }
            byte[] buf = new byte[0x18];
            var heaps = new List<long[]>(); // [base, end]
            foreach (var kv in info) {
                if ((kv.Value[3] & 7) != 0 || kv.Value[1] == 0) continue;
                IntPtr got;
                if (ReadProcessMemory(h, new IntPtr(kv.Key), buf, new IntPtr(buf.Length), out got) && got.ToInt64() == buf.Length) {
                    uint sig = BitConverter.ToUInt32(buf, 0x10);
                    if (sig == 0xffeeffeeu || sig == 0xddeeddeeu) { kv.Value[3] |= 8; heaps.Add(new long[] { kv.Key, kv.Key + kv.Value[0] }); }
                }
            }
            var outp = new Dictionary<long, long[]>();
            foreach (var kv in info) {
                long[] e = kv.Value;
                if ((e[3] & 15) != 0 || e[1] == 0) continue; // private_rw only
                long kind = e[1] == e[0] ? 1 : 2;
                IntPtr got;
                if (ReadProcessMemory(h, new IntPtr(kv.Key), buf, new IntPtr(buf.Length), out got) && got.ToInt64() == buf.Length) {
                    long flink = BitConverter.ToInt64(buf, 0);
                    foreach (var hp in heaps) if (flink >= hp[0] && flink < hp[1]) { kind = 0; break; }
                }
                outp[kv.Key] = new long[] { e[0], e[1], kind };
            }
            return outp;
        } finally { CloseHandle(h); }
    }
}
'@
}
# T3130: the private_rw allocations, by base. Kept raw so two samples diff.
function Get-AllocCensus([int]$ProcessId) {
    $d = [PerfRegions]::Allocs($ProcessId)
    if ($null -eq $d) { return @{ error = [PerfRegions]::Error } }
    return $d
}
$script:AllocKinds = @('heap_large', 'exact', 'arena')
function Get-AllocBucket([long]$Bytes) {
    if ($Bytes -lt 64KB) { return 'lt64k' }
    if ($Bytes -lt 1MB) { return '64k-1m' }
    if ($Bytes -lt 4MB) { return '1m-4m' }
    if ($Bytes -lt 16MB) { return '4m-16m' }
    if ($Bytes -lt 64MB) { return '16m-64m' }
    return 'ge64m'
}
# What B holds in private_rw that A did not: new allocations whole, grown
# ones by their growth. Summed by kind and by committed-size bucket, plus the
# 15 biggest, so "290 MB of private_rw" becomes "N exact 1-4 MB allocations".
function Get-AllocDelta($A, $B) {
    if ($A -is [hashtable] -or $B -is [hashtable]) { return [ordered]@{ error = 'an allocation census failed' } }
    $byKind = [ordered]@{}; foreach ($k in $script:AllocKinds) { $byKind[$k] = [ordered]@{ mb = 0.0; count = 0 } }
    $byBucket = [ordered]@{}
    foreach ($bk in 'lt64k', '64k-1m', '1m-4m', '4m-16m', '16m-64m', 'ge64m') { $byBucket[$bk] = [ordered]@{ mb = 0.0; count = 0 } }
    $rows = New-Object System.Collections.Generic.List[object]
    $gone = 0.0
    foreach ($base in @($B.Keys)) {
        $e = $B[$base]
        $was = if ($A.ContainsKey($base)) { [long]$A[$base][1] } else { 0 }
        $grew = [long]$e[1] - $was
        if ($grew -le 0) { continue }
        $kind = $script:AllocKinds[[int]$e[2]]
        $bucket = Get-AllocBucket ([long]$e[1])
        $byKind[$kind].mb += $grew / 1MB; $byKind[$kind].count++
        $byBucket[$bucket].mb += $grew / 1MB; $byBucket[$bucket].count++
        $rows.Add([pscustomobject]@{ base = ('0x{0:x}' -f [long]$base); kind = $kind; reserve_mb = [math]::Round($e[0] / 1MB, 2); commit_mb = [math]::Round($e[1] / 1MB, 2); grew_mb = [math]::Round($grew / 1MB, 2); new = ($was -eq 0) })
    }
    foreach ($base in @($A.Keys)) { if (-not $B.ContainsKey($base)) { $gone += [long]$A[$base][1] / 1MB } }
    foreach ($k in @($byKind.Keys)) { $byKind[$k].mb = [math]::Round($byKind[$k].mb, 1) }
    foreach ($k in @($byBucket.Keys)) { $byBucket[$k].mb = [math]::Round($byBucket[$k].mb, 1) }
    # Same-size allocations, most bytes first: N copies of one size is one owner's shape.
    $sizes = @($rows | Where-Object { $_.new } | Group-Object commit_mb | ForEach-Object { [pscustomobject]@{ commit_mb = [double]$_.Name; count = $_.Count; total_mb = [math]::Round([double]$_.Name * $_.Count, 1); kinds = (@($_.Group | ForEach-Object kind | Sort-Object -Unique) -join '+') } } | Sort-Object total_mb -Descending | Select-Object -First 12)
    return [ordered]@{
        grew_mb = [math]::Round((($rows | Measure-Object grew_mb -Sum).Sum), 1)
        released_mb = [math]::Round($gone, 1)
        by_kind = $byKind
        by_bucket = $byBucket
        by_size = $sizes
        top = @($rows | Sort-Object grew_mb -Descending | Select-Object -First 15)
    }
}
function Get-RegionCensus([int]$ProcessId) {
    $d = [PerfRegions]::Census($ProcessId)
    if ($null -eq $d) { return [ordered]@{ error = [PerfRegions]::Error } }
    $o = [ordered]@{}
    foreach ($k in 'heap', 'writecombine', 'uncached', 'stack', 'private_rw', 'mapped', 'image') {
        $o["${k}_mb"] = [math]::Round($d[$k] / 1MB, 1)
    }
    $o.private_total_mb = [math]::Round(($d['heap'] + $d['writecombine'] + $d['uncached'] + $d['stack'] + $d['private_rw']) / 1MB, 1)
    $o.regions = [ordered]@{}
    foreach ($k in 'heap', 'writecombine', 'uncached', 'stack', 'private_rw', 'mapped', 'image') { $o.regions[$k] = $d["regions:$k"] }
    return $o
}
function Get-RegionDelta($A, $B) {
    if ($A.Contains('error') -or $B.Contains('error')) { return [ordered]@{ error = 'a region census failed' } }
    $o = [ordered]@{}
    foreach ($k in @($A.Keys)) { if ($k -like '*_mb') { $o[$k] = [math]::Round($B[$k] - $A[$k], 1) } }
    return $o
}
# Least-squares slope of a series against its index: the per-cycle growth.
function Get-Slope([double[]]$Y) {
    $n = $Y.Count
    if ($n -lt 2) { return $null }
    $mx = ($n - 1) / 2.0
    $my = ($Y | Measure-Object -Average).Average
    $num = 0.0; $den = 0.0
    for ($i = 0; $i -lt $n; $i++) { $num += ($i - $mx) * ($Y[$i] - $my); $den += ($i - $mx) * ($i - $mx) }
    return [math]::Round($num / $den, 2)
}

$cores = [Environment]::ProcessorCount
function Get-Snap([int]$ProcessId) {
    $r = [PerfSnap]::Read($ProcessId)
    if ($null -eq $r) { return $null }
    return [pscustomobject]@{ Cpu100ns = $r[0]; Ctx = $r[1]; Threads = $r[2]; User100ns = $r[3]; Kernel100ns = $r[4]; Cycles = $r[5]; At = [Diagnostics.Stopwatch]::GetTimestamp() }
}
# T3111: the cycle counter runs at the invariant TSC rate, which is the
# processor's nominal clock; cycles / this = seconds of one core.
$script:cycleHz = 1e6 * [double]((Get-CimInstance Win32_Processor | Select-Object -First 1).MaxClockSpeed)
# CPU % of ONE core, CPU seconds and context switches/s between two snaps.
# cpu_pct is user + kernel time, which Windows charges in whole clock ticks
# (15.6 ms; one tick over a 60 s idle span is 0.026%), so a small idle number
# is a COUNT of ticks that landed on the app, not a measurement of its work.
# cpu_cycle_pct is the same quantity from the exact cycle counter (T3111).
function Get-Rate($A, $B) {
    if ($null -eq $A -or $null -eq $B) { return $null }
    $sec = ($B.At - $A.At) / [double][Diagnostics.Stopwatch]::Frequency
    $cpu = ($B.Cpu100ns - $A.Cpu100ns) / 1e7
    $o = [ordered]@{
        wall_s  = [math]::Round($sec, 2)
        cpu_s   = [math]::Round($cpu, 3)
        cpu_pct = [math]::Round(100.0 * $cpu / $sec, 2)
        cpu_user_pct = [math]::Round(100.0 * (($B.User100ns - $A.User100ns) / 1e7) / $sec, 2)
        cpu_kernel_pct = [math]::Round(100.0 * (($B.Kernel100ns - $A.Kernel100ns) / 1e7) / $sec, 2)
        cpu_ticks = [math]::Round(($B.Cpu100ns - $A.Cpu100ns) / 156250.0, 1)
        cpu_cycle_pct = $null
        mcycles_per_s = $null
        wakeups_per_s = [math]::Round(($B.Ctx - $A.Ctx) / $sec, 1)
    }
    if ($script:cycleHz -gt 0 -and $B.Cycles -ge $A.Cycles) {
        $cy = [double]($B.Cycles - $A.Cycles)
        $o.cpu_cycle_pct = [math]::Round(100.0 * $cy / $script:cycleHz / $sec, 3)
        $o.mcycles_per_s = [math]::Round($cy / 1e6 / $sec, 2)
    }
    return [pscustomobject]$o
}

# ---------------------------------------------------------------- attribution (T2989)
# tid -> context switches, from one snapshot. $null when unreadable.
function Get-ThreadCtx([int]$ProcessId) {
    $r = [PerfSnap]::Threads($ProcessId)
    if ($null -eq $r) { return $null }
    $h = @{}
    for ($i = 0; $i -lt $r.Length; $i += 2) { $h[[long]$r[$i]] = [long]$r[$i + 1] }
    return $h
}
# T3111: tid -> exact cycle count for every thread in a Get-ThreadCtx table
# (threads that cannot be opened are left out).
function Get-ThreadCycles([hashtable]$Ctx) {
    if ($null -eq $Ctx) { return $null }
    $h = @{}
    foreach ($tid in $Ctx.Keys) { $c = [PerfSnap]::Cycles([uint32]$tid); if ($c -ge 0) { $h[$tid] = $c } }
    return $h
}

# "module+0xoffset" for an address in $ProcessId, from its loaded-module list.
# The exe's entry point rides along as $script:mainEntry: the main (UI)
# thread is the one whose Win32 start address is it, and it carries no name.
function Get-ModuleMap([int]$ProcessId) {
    try {
        $p = Get-Process -Id $ProcessId -ErrorAction Stop
        $script:mainEntry = $p.MainModule.EntryPointAddress.ToInt64()
        return @($p.Modules | ForEach-Object {
                [pscustomobject]@{ Base = $_.BaseAddress.ToInt64(); End = $_.BaseAddress.ToInt64() + $_.ModuleMemorySize; Name = $_.ModuleName }
            })
    } catch { return @() }
}
function Resolve-Address([long]$Addr, $Map) {
    if ($Addr -eq 0) { return $null }
    foreach ($m in $Map) { if ($Addr -ge $m.Base -and $Addr -lt $m.End) { return ('{0}+0x{1:x}' -f $m.Name, ($Addr - $m.Base)) } }
    return ('0x{0:x}' -f $Addr)
}

# One thread's identity: its name when it has one, else where it started.
# Name and start are both read while the thread is alive, so call this while
# the app still runs.
function Get-ThreadIdentity([long]$Tid, $Map) {
    $d = [PerfSnap]::Describe([uint32]$Tid)
    if ($null -eq $d) { return [pscustomobject]@{ Name = ''; Start = $null; Module = '(exited)' } }
    $start = Resolve-Address ([long]$d[1]) $Map
    $mod = if ($start) { ($start -split '\+')[0] } else { '(unknown)' }
    $name = [string]$d[0]
    if (-not $name -and $script:mainEntry -and [long]$d[1] -eq $script:mainEntry) { $name = 'main' }
    return [pscustomobject]@{ Name = $name; Start = $start; Module = $mod }
}

# Which threads the context switches between two Get-ThreadCtx snapshots
# belong to: the top $Top threads, and every switch grouped by the module the
# thread started in (named threads keep their own name as the group, since
# the apprt's renderer/io threads all start inside ghoztty.exe).
function Get-WakeupAttribution([int]$ProcessId, [hashtable]$Before, [hashtable]$After, [double]$Seconds, [int]$Top = 10, [hashtable]$CyBefore = $null, [hashtable]$CyAfter = $null) {
    if ($null -eq $Before -or $null -eq $After -or $Seconds -le 0) { return $null }
    $map = Get-ModuleMap $ProcessId
    $haveCy = $null -ne $CyBefore -and $null -ne $CyAfter
    $rows = foreach ($tid in $After.Keys) {
        $was = if ($Before.ContainsKey($tid)) { $Before[$tid] } else { 0 }
        $d = $After[$tid] - $was
        # T3111: cycles spent by the thread over the span; $null when unread.
        $mc = $null
        if ($haveCy -and $CyAfter.ContainsKey($tid)) {
            $c0 = if ($CyBefore.ContainsKey($tid)) { $CyBefore[$tid] } else { 0 }
            $mc = [math]::Round(($CyAfter[$tid] - $c0) / 1e6 / $Seconds, 3)
        }
        if ($d -le 0 -and -not ($mc -gt 0)) { continue }
        $id = Get-ThreadIdentity $tid $map
        [pscustomobject]@{
            tid = [long]$tid
            name = $id.Name
            start = $id.Start
            group = $(if ($id.Name) { "$($id.Module) [$($id.Name)]" } else { $id.Module })
            new = -not $Before.ContainsKey($tid)
            wakeups_per_s = [math]::Round([math]::Max($d, 0) / $Seconds, 2)
            mcycles_per_s = $mc
        }
    }
    $rows = @($rows)
    $total = ($rows | Measure-Object -Property wakeups_per_s -Sum).Sum
    $groups = @($rows | Group-Object group | ForEach-Object {
            $g = [ordered]@{
                group = $_.Name
                threads = $_.Count
                wakeups_per_s = [math]::Round((($_.Group | Measure-Object -Property wakeups_per_s -Sum).Sum), 2)
            }
            if ($haveCy) { $g.mcycles_per_s = [math]::Round((($_.Group | Where-Object { $null -ne $_.mcycles_per_s } | Measure-Object -Property mcycles_per_s -Sum).Sum), 3) }
            [pscustomobject]$g
        } | Sort-Object wakeups_per_s -Descending)
    $o = [ordered]@{
        method = "per-thread ContextSwitches (SystemProcessInformation) at both ends of the span; a thread's group is its start module (NtQueryInformationThread Win32StartAddress against the process's module list) plus its SetThreadDescription name; threads that exited inside the span are not counted" + $(if ($haveCy) { '; mcycles_per_s is QueryThreadCycleTime at both ends (exact, not tick-sampled; T3111)' } else { '' })
        threads_seen = $After.Count
        threads_exited = @($Before.Keys | Where-Object { -not $After.ContainsKey($_) }).Count
        attributed_wakeups_per_s = [math]::Round([double]$total, 1)
        top_threads = @($rows | Sort-Object wakeups_per_s -Descending | Select-Object -First $Top)
        by_group = $groups
    }
    if ($haveCy) {
        $o.attributed_mcycles_per_s = [math]::Round([double](($rows | Where-Object { $null -ne $_.mcycles_per_s } | Measure-Object -Property mcycles_per_s -Sum).Sum), 2)
        $o.top_threads_by_cycles = @($rows | Where-Object { $null -ne $_.mcycles_per_s } | Sort-Object mcycles_per_s -Descending | Select-Object -First $Top)
        $o.by_group_cycles = @($groups | Sort-Object mcycles_per_s -Descending)
    }
    return $o
}

# Everything census-able a process holds: kernel handles by type (WcmHandles,
# lib\ProcessMemory.ps1), windows by kind and class (PerfWindows), threads by
# group (name or start module). A hashtable of three hashtables.
function Get-ObjectCensus([int]$ProcessId) {
    $win = [PerfWindows]::Census($script:testDesktopName, [uint32]$ProcessId)
    $w = @{}
    if ($win) { foreach ($kv in $win.GetEnumerator()) { $w[$kv.Key] = $kv.Value } }
    $map = Get-ModuleMap $ProcessId
    $t = @{}
    $ctx = Get-ThreadCtx $ProcessId
    if ($ctx) {
        foreach ($tid in $ctx.Keys) {
            $id = Get-ThreadIdentity $tid $map
            $k = if ($id.Name) { "$($id.Module) [$($id.Name)]" } else { $id.Module }
            $t[$k] = 1 + [int]$t[$k]
        }
    }
    $p = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    $user = if ($p) { [int][WcmDrv]::GetGuiResources($p.Handle, 1) } else { $null }
    $gdi = if ($p) { [int][WcmDrv]::GetGuiResources($p.Handle, 0) } else { $null }
    return @{ handles = (Get-HandleTypes $ProcessId); windows = $w; threads = $t; user = $user; gdi = $gdi; windowError = [PerfWindows]::Error }
}

# [{ name, delta }] for every key whose count moved, biggest move first.
function Get-CountDelta([hashtable]$Before, [hashtable]$After) {
    $keys = @(@($Before.Keys) + @($After.Keys) | Sort-Object -Unique)
    return @(foreach ($k in $keys) {
            $d = [int]$After[$k] - [int]$Before[$k]
            if ($d -ne 0) { [pscustomobject]@{ name = $k; delta = $d } }
        }) | Sort-Object { -[math]::Abs($_.delta) }, name
}

# What moved between two Get-ObjectCensus results, for the JSON.
function Format-CensusDelta($A, $B) {
    if ($null -eq $A -or $null -eq $B) { return $null }
    $wa = 0; foreach ($v in $A.windows.Values) { $wa += $v }
    $wb = 0; foreach ($v in $B.windows.Values) { $wb += $v }
    $o = [ordered]@{
        handle_types = @(Get-CountDelta $A.handles $B.handles)
        windows = @(Get-CountDelta $A.windows $B.windows)
        threads = @(Get-CountDelta $A.threads $B.threads)
        window_count_delta = $wb - $wa
        user_object_delta = $(if ($null -ne $A.user -and $null -ne $B.user) { $B.user - $A.user } else { $null })
        gdi_object_delta = $(if ($null -ne $A.gdi -and $null -ne $B.gdi) { $B.gdi - $A.gdi } else { $null })
    }
    # USER objects that are not windows: menus, icons, cursors, hooks,
    # accelerator tables, DWP structures - not enumerable from outside.
    if ($null -ne $o.user_object_delta) { $o.user_non_window_delta = $o.user_object_delta - $o.window_count_delta }
    if ($B.windowError) { $o.window_reason = $B.windowError }
    return $o
}

# Totals of one census, for a reader who wants the composition not the delta.
function Format-CensusTotals($C) {
    if ($null -eq $C) { return $null }
    $wc = 0; foreach ($v in $C.windows.Values) { $wc += $v }
    return [ordered]@{
        user = $C.user
        windows = $wc
        window_classes = @($C.windows.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { [pscustomobject]@{ name = $_.Key; count = $_.Value } })
        handle_types = @($C.handles.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { [pscustomobject]@{ name = $_.Key; count = $_.Value } })
        thread_groups = @($C.threads.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { [pscustomobject]@{ name = $_.Key; count = $_.Value } })
    }
}

# GPU engine utilisation charged to a pid, sampled once a second in a
# background job so the foreground can drive a workload meanwhile.
function Start-GpuSampler([int]$ProcessId, [int]$Seconds) {
    # One Get-Counter call per sample, so every sample is already emitted when
    # Stop-Job ends a sampler early (a single -MaxSamples call emits nothing
    # until it has them all).
    Start-Job -ArgumentList $ProcessId, $Seconds -ScriptBlock {
        param($procId, $n)
        for ($i = 0; $i -lt $n; $i++) {
            try {
                $set = Get-Counter -Counter "\GPU Engine(pid_${procId}_*)\Utilization Percentage" -SampleInterval 1 -MaxSamples 1 -ErrorAction Stop
                $tot = 0.0
                foreach ($c in $set.CounterSamples) { $tot += $c.CookedValue }
                [pscustomobject]@{ Sum = $tot }
            } catch { [pscustomobject]@{ Error = "$_" } }
        }
    }
}
function Stop-GpuSampler($Job) {
    [void](Wait-Job $Job -Timeout 120)
    $rows = @(Receive-Job $Job -ErrorAction SilentlyContinue)
    Remove-Job $Job -Force -ErrorAction SilentlyContinue
    $err = @($rows | Where-Object { $_.PSObject.Properties.Name -contains 'Error' })
    $ok = @($rows | Where-Object { $_.PSObject.Properties.Name -contains 'Sum' })
    if ($ok.Count -eq 0) {
        $why = if ($err.Count) { $err[0].Error } else { 'no samples' }
        return [pscustomobject]@{ gpu_engine_pct = $null; gpu_engine_peak_pct = $null; reason = "GPU Engine counters unreadable: $why" }
    }
    $avg = ($ok | Measure-Object -Property Sum -Average).Average
    $peak = ($ok | Measure-Object -Property Sum -Maximum).Maximum
    return [pscustomobject]@{ gpu_engine_pct = [math]::Round($avg, 2); gpu_engine_peak_pct = [math]::Round($peak, 2); samples = $ok.Count }
}

# Verbs go through the console twin when there is one: a release ghoztty.exe is
# a GUI-subsystem binary.
$cli = Join-Path (Split-Path $exe -Parent) 'ghoztty.com'
if (-not (Test-Path $cli)) { $cli = $exe }
function Invoke-Verb([string[]]$VerbArgs) {
    $o = @(& $cli @VerbArgs 2>&1 | ForEach-Object { "$_" }) -join "`n"
    return [pscustomobject]@{ Code = $LASTEXITCODE; Text = $o.Trim() }
}
# Every leaf pane in `+list --json` (objects carrying id + pid). Unrolled.
function Get-PaneLeaves {
    $r = Invoke-Verb @('+list', '--json')
    if ($r.Code -ne 0 -or [string]::IsNullOrWhiteSpace($r.Text)) { return @() }
    $acc = New-Object System.Collections.ArrayList
    $walk = $null
    $walk = {
        param($o)
        if ($null -eq $o) { return }
        if ($o -is [System.Array]) { foreach ($x in $o) { & $walk $x }; return }
        if ($o -is [System.Management.Automation.PSCustomObject]) {
            $names = @($o.PSObject.Properties.Name)
            if (($names -contains 'id') -and ($names -contains 'pid')) { [void]$acc.Add($o) }
            foreach ($p in $o.PSObject.Properties) { & $walk $p.Value }
        }
    }
    try { & $walk ($r.Text | ConvertFrom-Json) } catch { return @() }
    return $acc.ToArray()
}
function Wait-PaneCount([int]$Want, [int]$TimeoutSec = 20) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do { if (@(Get-PaneLeaves).Count -eq $Want) { return $true }; Start-Sleep -Milliseconds 250 } while ((Get-Date) -lt $deadline)
    return $false
}

function Format-Sample($S) {
    return [ordered]@{
        private_mb  = $S.PrivMB
        working_set_mb = $S.WsMB
        handles     = $S.Handles
        gdi         = $S.Gdi
        user        = $S.User
        threads     = $S.Threads
        gpu_dedicated_mb = $S.GpuDedMB
        gpu_shared_mb    = $S.GpuShMB
        child_procs = $S.Procs
        child_private_mb = $S.ProcMB
    }
}
function Get-FullSample([int]$ProcessId, [string]$Label, [switch]$Settle) {
    $s = if ($Settle) { Wait-Settled $ProcessId $Label } else { Get-Sample $ProcessId $Label }
    $ws = (Get-Process -Id $ProcessId).WorkingSet64
    $s | Add-Member -NotePropertyName WsMB -NotePropertyValue ([math]::Round($ws / 1MB, 1))
    return $s
}

$launchBase = @('--config-default-files=false', '--confirm-close-surface=false', '--undo-timeout=1s')
$script:app = $null
function Start-App([bool]$Persist, [string[]]$Extra = @()) {
    $err = Join-Path $work ("app-{0}.err" -f ([guid]::NewGuid().ToString('N').Substring(0, 6)))
    $a = $launchBase + @("--session-persistence=$($Persist.ToString().ToLower())") + $Extra
    $script:app = Start-OnTestDesktop -Exe $exe -StdErr $err -Arguments $a -AllowReleaseBuild:$isRelease
    $script:appErr = $err
    $top = Wait-TestWindow -ProcessId $script:app.Pid -Class 'GhozttyWindow' -TimeoutMs 30000
    if ($top -eq [IntPtr]::Zero) { throw "the app window never appeared (stderr: $err)" }
    [void](Set-TestWindowPos -Window ([IntPtr]$top) -X 20 -Y 20 -Width 1400 -Height 900)
    $deadline = (Get-Date).AddSeconds(20)
    do { if (@(Get-PaneLeaves).Count -ge 1) { break }; Start-Sleep -Milliseconds 300 } while ((Get-Date) -lt $deadline)
    return [pscustomobject]@{ Pid = $script:app.Pid; Top = [IntPtr]$top }
}
function Stop-App { [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500) }

# T3059 (PA-C02): where the app's GHOZTTY_PERF lines land. A Debug exe is a
# console app and logs to the stderr Start-App redirects; a release exe is
# GUI-subsystem and appends to %LOCALAPPDATA%\ghoztty\ghoztty.log, which the
# -ReleaseSandbox isolation points at this run's private profile.
function Get-AppLogPath {
    if ($isRelease) { return (Join-Path $env:LOCALAPPDATA 'ghoztty\ghoztty.log') }
    return $script:appErr
}
function Get-FileLength([string]$Path) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return 0L }
    return (Get-Item -LiteralPath $Path).Length
}
# The text appended to $Path since byte $Offset (shared read: the app still
# holds the file open).
function Read-FileFrom([string]$Path, [long]$Offset) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return '' }
    $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite,Delete')
    try {
        if ($Offset -gt $fs.Length) { $Offset = 0 }
        [void]$fs.Seek($Offset, 'Begin')
        $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)
        return $sr.ReadToEnd()
    } finally { $fs.Close() }
}

# T3059 (PA-C02): the app's own GHOZTTY_PERF counters over a span, parsed from
# the log text it wrote during that span. Every counter line is a rate over a
# window of >= 1 s, emitted only while its thread is doing work, so:
#   pty / agent_feed - only the busy pane produces output; mean over windows
#   queue_render     - per stream handler (target=); the busiest target's mean;
#                      notifies_per_s on the same line (T3061) is the wakeups
#                      actually posted after coalescing (null before T3061)
#   fps              - per pane (pane=); the pane with the most windows
#   wakeups          - per renderer thread, unlabelled; the MEDIAN, so the
#                      idle anchor pane's occasional window does not drag it
# bytes_per_batch is total bytes over total batches across the pty windows.
function Get-PerfCounters([string]$Text) {
    $lines = @(($Text -split "`r?`n") | Where-Object { $_ -match '\bperf ' })
    $mean = { param($xs) if (@($xs).Count) { [math]::Round((@($xs) | Measure-Object -Average).Average, 1) } else { $null } }
    $median = {
        param($xs)
        $s = @(@($xs) | Sort-Object)
        if (-not $s.Count) { return $null }
        if ($s.Count % 2) { return [double]$s[[int][math]::Floor($s.Count / 2)] }
        return [math]::Round(([double]$s[$s.Count / 2 - 1] + [double]$s[$s.Count / 2]) / 2, 1)
    }
    $pty = @(foreach ($l in $lines) {
            if ($l -match 'perf pty reads_per_s=(\d+) batches_per_s=(\d+) kb_per_s=(\d+)') {
                [pscustomobject]@{ reads = [double]$Matches[1]; batches = [double]$Matches[2]; kb = [double]$Matches[3] }
            }
        })
    $feed = @(foreach ($l in $lines) {
            if ($l -match 'perf agent_feed kb_per_s=(\d+) slices_per_s=(\d+) feeds_per_s=(\d+) parse_ms_per_s=(\d+) lock_ms_per_s=(\d+) work_ms_per_s=(\d+) yield_ms_per_s=(\d+)') {
                [pscustomobject]@{ kb = [double]$Matches[1]; slices = [double]$Matches[2]; feeds = [double]$Matches[3]; parse = [double]$Matches[4]; lock = [double]$Matches[5]; work = [double]$Matches[6]; yield = [double]$Matches[7] }
            }
        })
    $qr = @(foreach ($l in $lines) {
            # notifies_per_s (T3061): the wakeups actually posted after coalescing;
            # absent from a pre-T3061 build, which posted one per request.
            if ($l -match 'perf queue_render_per_s=(\d+) target=(\S+)(?: notifies_per_s=(\d+))?') { [pscustomobject]@{ v = [double]$Matches[1]; k = $Matches[2]; n = $(if ($Matches[3]) { [double]$Matches[3] } else { $null }) } }
        })
    $fps = @(foreach ($l in $lines) {
            if ($l -match 'perf pane=(\S+) fps=(\d+) max_gap_ms=(\d+)') { [pscustomobject]@{ k = $Matches[1]; v = [double]$Matches[2]; gap = [double]$Matches[3] } }
        })
    $wk = @(foreach ($l in $lines) { if ($l -match 'perf wakeups_per_s=(\d+)') { [double]$Matches[1] } })

    $qrTop = @($qr | Group-Object k | Sort-Object { ($_.Group | Measure-Object v -Sum).Sum } -Descending | Select-Object -First 1)
    $fpsTop = @($fps | Group-Object k | Sort-Object Count -Descending | Select-Object -First 1)
    $batchSum = ($pty | Measure-Object batches -Sum).Sum
    $o = [ordered]@{
        method = 'GHOZTTY_PERF=1 in the app''s environment; the app''s own 1 s counter lines written over the busy span (Debug: stderr; release: the sandbox ghoztty.log) - pty reader (termio/Exec.zig), agent_feed (termio/Remote.zig, persistence on), queue_render (termio/stream_handler.zig), renderer wakeups (renderer/Thread.zig), fps (renderer/OpenGL.zig). Rates are the mean over the windows the busy pane produced; wakeups is the median over all renderer threads'' windows; bytes_per_batch is total bytes / total batches'
        windows = [ordered]@{ pty = $pty.Count; agent_feed = $feed.Count; queue_render = $qr.Count; fps = $fps.Count; wakeups = $wk.Count }
        reads_per_s = & $mean ($pty | ForEach-Object { $_.reads })
        batches_per_s = & $mean ($pty | ForEach-Object { $_.batches })
        pty_kb_per_s = & $mean ($pty | ForEach-Object { $_.kb })
        bytes_per_batch = $(if ($batchSum -gt 0) { [math]::Round((($pty | Measure-Object kb -Sum).Sum * 1024) / $batchSum, 0) } else { $null })
        queue_render_per_s = $(if ($qrTop.Count) { & $mean ($qrTop[0].Group | ForEach-Object { $_.v }) } else { $null })
        render_notifies_per_s = $(if ($qrTop.Count -and @($qrTop[0].Group | Where-Object { $null -ne $_.n }).Count) { & $mean ($qrTop[0].Group | Where-Object { $null -ne $_.n } | ForEach-Object { $_.n }) } else { $null })
        renderer_wakeups_per_s = & $median $wk
        fps = $(if ($fpsTop.Count) { & $mean ($fpsTop[0].Group | ForEach-Object { $_.v }) } else { $null })
        fps_max_gap_ms = $(if ($fpsTop.Count) { ($fpsTop[0].Group | Measure-Object gap -Maximum).Maximum } else { $null })
    }
    if ($feed.Count) {
        $o.agent_feed = [ordered]@{
            kb_per_s = & $mean ($feed | ForEach-Object { $_.kb })
            slices_per_s = & $mean ($feed | ForEach-Object { $_.slices })
            feeds_per_s = & $mean ($feed | ForEach-Object { $_.feeds })
            parse_ms_per_s = & $mean ($feed | ForEach-Object { $_.parse })
            lock_ms_per_s = & $mean ($feed | ForEach-Object { $_.lock })
            work_ms_per_s = & $mean ($feed | ForEach-Object { $_.work })
            yield_ms_per_s = & $mean ($feed | ForEach-Object { $_.yield })
        }
    }
    if (-not $lines.Count) { $o.reason = 'no GHOZTTY_PERF line was logged over the span' }
    return $o
}
function Get-AgentInfo {
    $r = Invoke-Verb @('+sessions', '--agent', '--json')
    try { return ($r.Text | ConvertFrom-Json) } catch { return $null }
}
function Get-SessionRows {
    $r = Invoke-Verb @('+sessions', '--json')
    if ($r.Code -ne 0 -or [string]::IsNullOrWhiteSpace($r.Text)) { return @() }
    try { $j = $r.Text | ConvertFrom-Json } catch { return @() }
    return @($j | ForEach-Object { $_ })
}
# A cold sandbox has no agent and the first app gives up on it after ~2 s, so
# bring one app up purely to start the agent; apps started after it find it
# running. Returns the agent pid (T3016: shared by the agent phase and
# -BusyPersistence).
function Start-SandboxAgent {
    [void](Start-App $true)
    $agentPid = $null
    $deadline = (Get-Date).AddSeconds(40)
    do {
        Start-Sleep -Milliseconds 500
        $info = Get-AgentInfo
        if ($info -and $info.agent_pid) { $agentPid = [int]$info.agent_pid }
    } while (-not $agentPid -and (Get-Date) -lt $deadline)
    if (-not $agentPid) { throw 'no agent came up for the sandbox lineage' }
    Stop-App
    Start-Sleep -Seconds 2
    return $agentPid
}

# T3033: the WebView2 tree this app spawned - every msedgewebview2.exe whose
# parent chain reaches the app (one environment per app, so its browser is the
# app's child and the renderer, GPU and utility processes are the browser's)
# - with each process's role from the --type= switch on its command line (the
# browser process has none).
function Get-WebViewTree([int]$ProcessId) {
    $desc = Get-Descendants $ProcessId
    $wv = @($desc | Where-Object { "$($_.Name)" -ieq 'msedgewebview2.exe' })
    $cmd = @{}
    if ($wv.Count) {
        $filter = (@($wv | ForEach-Object { "ProcessId=$([int]$_.ProcessId)" })) -join ' OR '
        foreach ($p in @(Get-CimInstance Win32_Process -Filter $filter -Property ProcessId, CommandLine -ErrorAction SilentlyContinue)) {
            $cmd[[int]$p.ProcessId] = "$($p.CommandLine)"
        }
    }
    $rows = New-Object System.Collections.ArrayList
    foreach ($d in $wv) {
        $role = 'browser'
        if ("$($cmd[[int]$d.ProcessId])" -match '--type=([A-Za-z0-9-]+)') { $role = $Matches[1] }
        [void]$rows.Add([pscustomobject]@{ Pid = [int]$d.ProcessId; Role = $role; PrivMB = [double]$d.PrivatePageCount / 1MB })
    }
    return $rows.ToArray()
}
# CPU (100 ns) of each pid now; a pid that has exited is absent.
function Get-PidCpu([int[]]$Pids) {
    $o = @{}
    # A $null from an empty tree casts to pid 0, the System Idle Process.
    foreach ($p in $Pids) { if ($p -le 0) { continue }; $r = [PerfSnap]::Read($p); if ($null -ne $r) { $o[$p] = $r[0] } }
    return $o
}
# One tree as JSON numbers: process count, renderer count, private MB, and the
# per-role breakdown (an array, so -Compare does not score it).
function Format-WebViewTree($Tree) {
    # An empty tree arrives as $null (a function's empty array unrolls to
    # nothing), and @($null) is one element - drop it.
    $tree = @($Tree | Where-Object { $null -ne $_ })
    $priv = 0.0; foreach ($t in $tree) { $priv += $t.PrivMB }
    return [ordered]@{
        procs = $tree.Count
        renderer_procs = @($tree | Where-Object { $_.Role -eq 'renderer' }).Count
        private_mb = [math]::Round($priv, 1)
        roles = @($tree | Group-Object Role | Sort-Object Name | ForEach-Object {
                $m = 0.0; foreach ($x in $_.Group) { $m += $x.PrivMB }
                [pscustomobject]@{ role = $_.Name; procs = $_.Count; private_mb = [math]::Round($m, 1) } })
    }
}
# CPU % of one core charged to a WebView2 tree between two Get-PidCpu reads:
# a process alive at both ends counts its delta, one born inside the span its
# whole lifetime (all of which fell inside it); one that exited inside the
# span is lost, and the count of those is returned beside the figure.
function Get-TreeCpuPct([hashtable]$Before, [hashtable]$After, [double]$Seconds) {
    $cpu = 0.0
    foreach ($p in $After.Keys) {
        if ($Before.ContainsKey($p)) { $cpu += ($After[$p] - $Before[$p]) / 1e7 } else { $cpu += $After[$p] / 1e7 }
    }
    $lost = @($Before.Keys | Where-Object { -not $After.ContainsKey($_) }).Count
    return [pscustomobject]@{ cpu_pct = [math]::Round(100.0 * $cpu / $Seconds, 2); cpu_s = [math]::Round($cpu, 3); exited_in_span = $lost }
}
# The app process alone (no descendants), for the viewer phase's blocks.
function Format-AppSample($S) {
    return [ordered]@{ private_mb = $S.PrivMB; gdi = $S.Gdi; user = $S.User; handles = $S.Handles; threads = $S.Threads }
}
# Viewer windows under the top window: [total, visible-with-size].
function Get-ViewerWindowCount([IntPtr]$Top) {
    $all = @(Get-TestChildWindows -Window $Top -Class 'GhozttyViewer')
    $vis = @($all | Where-Object { $_.Visible -and $_.Width -gt 0 -and $_.Height -gt 0 })
    return @($all.Count, $vis.Count)
}

$result = [ordered]@{
    exe = $exe
    build = $Build
    version = ((& $cli +version 2>$null | ForEach-Object { "$_" }) -join ' ').Trim()
}
$want = if ($Phase -contains 'all') { @('idle', 'busy', 'cycle', 'viewer', 'agent') } else { $Phase }
$failed = $false

[void](Stop-RepoGhoztty -Exe $exe -SettleMs 500 -ScopeToLineage)
Start-TestForegroundWatch
$td = New-TestDesktop
$script:testDesktopName = if ($td.Interactive) { '' } else { $td.Name }
try {
    # ------------------------------------------------------------ idle
    if ($want -contains 'idle') {
        Write-Host "[$Build] idle: 1 window, 1 pane, $IdleSeconds s"
        try {
            $a = Start-App $false
            Start-Sleep -Seconds 10
            $job = Start-GpuSampler $a.Pid ([math]::Min($IdleSeconds, 30))
            $t0 = Get-ThreadCtx $a.Pid
            $c0 = Get-ThreadCycles $t0
            $s0 = Get-Snap $a.Pid
            $tr0 = [PerfSnap]::TimerResolution100ns()
            Start-Sleep -Seconds $IdleSeconds
            $s1 = Get-Snap $a.Pid
            $tr1 = [PerfSnap]::TimerResolution100ns()
            $t1 = Get-ThreadCtx $a.Pid
            $c1 = Get-ThreadCycles $t1
            $gpu = Stop-GpuSampler $job
            $r = Get-Rate $s0 $s1
            $result.idle = [ordered]@{
                method = "1 window 1400x900, 1 cmd pane at its prompt, persistence off; 10 s settle, then CPU time and summed thread context switches (NtQuerySystemInformation class 5) over $IdleSeconds s; GPU Engine(pid_*) utilisation summed over engines, 1 s samples, first 30 s. cpu_pct is user+kernel tick-charged time (baselines 1-3: user only); cpu_cycle_pct is the exact cycle count at the nominal $([math]::Round($script:cycleHz / 1e6)) MHz (T3111)"
                cpu_pct = $r.cpu_pct
                cpu_user_pct = $r.cpu_user_pct
                cpu_kernel_pct = $r.cpu_kernel_pct
                cpu_ticks = $r.cpu_ticks
                cpu_cycle_pct = $r.cpu_cycle_pct
                mcycles_per_s = $r.mcycles_per_s
                # The system clock interval at both ends (ms): another
                # process's timeBeginPeriod changes how often the app's
                # timers can fire, which no number of ours would show.
                timer_resolution_ms = @($(if ($tr0 -gt 0) { [math]::Round($tr0 / 1e4, 3) } else { $null }), $(if ($tr1 -gt 0) { [math]::Round($tr1 / 1e4, 3) } else { $null }))
                wakeups_per_s = $r.wakeups_per_s
                threads = $s1.Threads
                gpu_engine_pct = $gpu.gpu_engine_pct
                gpu_engine_peak_pct = $gpu.gpu_engine_peak_pct
            }
            if ($gpu.reason) { $result.idle.gpu_reason = $gpu.reason }
            $result.idle.wakeup_attribution = Get-WakeupAttribution $a.Pid $t0 $t1 $r.wall_s -CyBefore $c0 -CyAfter $c1
            $result.idle.memory = Format-Sample (Get-FullSample $a.Pid 'idle')
            $result.idle.objects = Format-CensusTotals (Get-ObjectCensus $a.Pid)
        } catch { $failed = $true; $result.idle = [ordered]@{ error = "$_" } }
        finally { Stop-App }
    }

    # ------------------------------------------------------------ busy
    if ($want -contains 'busy') {
        Write-Host "[$Build] busy: type a $BusyMB MB file, then $ResizeSeconds s of resizes"
        try {
            $big = Join-Path $work "big-$BusyText.txt"
            if (-not (Test-Path $big)) {
                if ($BusyText -eq 'cjk') {
                    # U+4E00..U+9FFF, 40 ideographs (80 columns) per line, the
                    # whole block once per chunk, so each pass walks every glyph.
                    $sb = New-Object Text.StringBuilder
                    $col = 0
                    for ($cp = 0x4E00; $cp -le 0x9FFF; $cp++) {
                        [void]$sb.Append([char]$cp)
                        $col++
                        if ($col -eq 40) { [void]$sb.Append("`r`n"); $col = 0 }
                    }
                    [void]$sb.Append("`r`n")
                    $chunk = (New-Object Text.UTF8Encoding($false)).GetBytes($sb.ToString())
                } else {
                    $line = ('0123456789abcdefghijklmnopqrstuvwxyz' * 3) + "`r`n"
                    $chunk = [Text.Encoding]::ASCII.GetBytes(($line * 4096))
                }
                $fs = [IO.File]::Create($big)
                try { while ($fs.Length -lt $BusyMB * 1MB) { $fs.Write($chunk, 0, $chunk.Length) } } finally { $fs.Close() }
            }
            $typeCmd = if ($BusyText -eq 'cjk') { "chcp 65001 >nul & type `"$big`"" } else { "type `"$big`"" }
            $marker = Join-Path $work 'busy.done'
            Remove-Item $marker -ErrorAction SilentlyContinue
            $agentExe = Join-Path (Split-Path $exe) 'ghoztty-agent.exe'
            # Every ghoztty-agent.exe of THIS build (the daemon and its
            # per-session holders): pid -> snap.
            function Get-AgentFamilySnaps {
                $m = @{}
                foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='ghoztty-agent.exe'" -ErrorAction SilentlyContinue)) {
                    if ($p.ExecutablePath -and ([IO.Path]::GetFullPath($p.ExecutablePath) -ieq [IO.Path]::GetFullPath($agentExe))) {
                        $sn = Get-Snap ([int]$p.ProcessId)
                        if ($sn) { $m[[int]$p.ProcessId] = $sn }
                    }
                }
                return $m
            }
            if ($BusyPersistence) { [void](Start-SandboxAgent) }
            # T3059: the busy app alone runs under GHOZTTY_PERF (an -AppEnv
            # value wins), so the other phases measure the build as shipped.
            $perfWas = $env:GHOZTTY_PERF
            if (-not $perfWas) { $env:GHOZTTY_PERF = '1' }
            try { $a = Start-App ([bool]$BusyPersistence) } finally { $env:GHOZTTY_PERF = $perfWas }
            Start-Sleep -Seconds 6
            $anchor = @(Get-PaneLeaves)[0].id
            $job = Start-GpuSampler $a.Pid 120
            $f0 = if ($BusyPersistence) { Get-AgentFamilySnaps } else { @{} }
            $perfLog = Get-AppLogPath
            $perfOff = Get-FileLength $perfLog
            $t0 = Get-ThreadCtx $a.Pid
            $c0 = Get-ThreadCycles $t0
            $s0 = Get-Snap $a.Pid
            $sampler = $null
            if ($SampleAgent -and $BusyPersistence) {
                $sampleOut = [IO.Path]::GetFullPath($SampleAgent)
                $sampleLog = [IO.Path]::ChangeExtension($sampleOut, '.txt')
                $sampler = Start-Process powershell -WindowStyle Hidden -PassThru -RedirectStandardOutput $sampleLog -ArgumentList @(
                    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $PSScriptRoot 'cpu-sample.ps1')`"",
                    '-ImagePath', "`"$agentExe`"", '-StopFile', "`"$marker`"", '-Seconds', '600', '-Top', '25',
                    '-Out', "`"$sampleOut`"", '-Folded', "`"$([IO.Path]::ChangeExtension($sampleOut, '.folded'))`"")
                $null = $sampler.Handle
                Start-Sleep -Seconds 3   # Add-Type compile + first scan, before the flood starts
            }
            $r = Invoke-Verb @('+split', "--target=$anchor", '--name=perfbusy', '--direction=right', "--command=$typeCmd & echo done> `"$marker`"")
            if ($r.Code -ne 0) { throw "+split for the busy pane failed: $($r.Text)" }
            $deadline = (Get-Date).AddSeconds(600)
            while (-not (Test-Path $marker) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
            $s1 = Get-Snap $a.Pid
            $t1 = Get-ThreadCtx $a.Pid
            $c1 = Get-ThreadCycles $t1
            $f1 = if ($BusyPersistence) { Get-AgentFamilySnaps } else { @{} }
            if ($sampler) {
                if (-not $sampler.WaitForExit(60000)) { try { $sampler.Kill() } catch { } }
                $result.agent_sample = [ordered]@{ report = $sampleOut; log = $sampleLog; note = 'cpu-sample.ps1 ran over the busy span: this run''s busy wall/cpu are perturbed by the sampling' }
            }
            # The last counter window closes up to a second after the output
            # stops; give it that second before reading the log back.
            Start-Sleep -Milliseconds 1500
            $perfText = Read-FileFrom $perfLog $perfOff
            Stop-Job $job -ErrorAction SilentlyContinue
            $gpu = Stop-GpuSampler $job
            if (-not (Test-Path $marker)) { throw 'the busy pane never finished its output within 600 s' }
            $rb = Get-Rate $s0 $s1
            $agentBusy = $null
            if ($BusyPersistence) {
                # A process alive at both ends counts its delta; one born during
                # the span (the busy pane's holder) counts its whole lifetime,
                # all of which fell inside the span.
                $daemonS = 0.0; $holderS = 0.0; $n = 0
                foreach ($procId in $f1.Keys) {
                    $end = $f1[$procId]
                    $cpu = if ($f0.ContainsKey($procId)) { ($end.Cpu100ns - $f0[$procId].Cpu100ns) / 1e7 } else { $end.Cpu100ns / 1e7 }
                    if ($f0.ContainsKey($procId)) { $daemonS += $cpu } else { $holderS += $cpu }
                    $n++
                }
                $agentBusy = [ordered]@{
                    method = 'every ghoztty-agent.exe of this build (daemon + per-session holders): CPU delta over the busy span for a process alive at both ends, whole-lifetime CPU for one born inside it (the busy pane''s holder)'
                    processes = $n
                    agent_cpu_s = [math]::Round($daemonS + $holderS, 3)
                    existing_cpu_s = [math]::Round($daemonS, 3)
                    new_holder_cpu_s = [math]::Round($holderS, 3)
                }
            }
            $result.busy = [ordered]@{
                method = "+split a cmd pane running ``type`` of a $BusyMB MB file ($(if ($BusyText -eq 'cjk') { '40-ideograph UTF-8 lines walking U+4E00..U+9FFF' } else { '108-char ASCII lines' })) then writing a marker; wall time from the split to the marker, app CPU over the same span; GPU Engine(pid_*) summed, 1 s samples"
                output_mb = $BusyMB
                persistence = [bool]$BusyPersistence
                wall_s = $rb.wall_s
                cpu_s = $rb.cpu_s
                cpu_pct = $rb.cpu_pct
                wakeups_per_s = $rb.wakeups_per_s
                gpu_engine_pct = $gpu.gpu_engine_pct
                gpu_engine_peak_pct = $gpu.gpu_engine_peak_pct
            }
            if ($gpu.reason) { $result.busy.gpu_reason = $gpu.reason }
            if ($agentBusy) { $result.busy.agent = $agentBusy }
            # T3059 (PA-C02): what the busy CPU was spent on - the app's own
            # reader/renderer counters, and CPU and context switches by thread.
            $result.busy.perf = Get-PerfCounters $perfText
            $result.busy.wakeup_attribution = Get-WakeupAttribution $a.Pid $t0 $t1 $rb.wall_s -CyBefore $c0 -CyAfter $c1
            Start-Sleep -Seconds 3

            $job = Start-GpuSampler $a.Pid $ResizeSeconds
            $s0 = Get-Snap $a.Pid
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $i = 0
            while ($sw.Elapsed.TotalSeconds -lt $ResizeSeconds) {
                $w = 900 + (($i * 37) % 600); $h = 600 + (($i * 23) % 350)
                [void](Set-TestWindowPos -Window $a.Top -X 20 -Y 20 -Width $w -Height $h)
                Start-Sleep -Milliseconds 50
                $i++
            }
            $s1 = Get-Snap $a.Pid
            $gpu = Stop-GpuSampler $job
            $rr = Get-Rate $s0 $s1
            $result.resize = [ordered]@{
                method = "SetWindowPos to a new size every 50 ms for $ResizeSeconds s (2 panes open, one holding the busy output); app CPU and GPU Engine over the span"
                resizes = $i
                cpu_pct = $rr.cpu_pct
                wakeups_per_s = $rr.wakeups_per_s
                gpu_engine_pct = $gpu.gpu_engine_pct
                gpu_engine_peak_pct = $gpu.gpu_engine_peak_pct
            }
            if ($gpu.reason) { $result.resize.gpu_reason = $gpu.reason }
        } catch { $failed = $true; $result.busy = [ordered]@{ error = "$_" } }
        finally { Stop-App }
    }

    # ------------------------------------------------------------ cycle
    if ($want -contains 'cycle') {
        $shape = @(switch ($CycleShape) { 'tabs' { @(0) * 10 } 'splits' { @(9) } 'one' { @(1) } default { @(3, 2, 2) } })
        $paneTotal = $shape.Count + ($shape | Measure-Object -Sum).Sum
        Write-Host "[$Build] cycle: $paneTotal panes over $($shape.Count) tab(s) ($CycleShape), closed, twice"
        try {
            # quit-after-last-window-closed only acts at the very end: Windows
            # defaults it off, and the DebugAllocator reports at exit (T3005).
            $a = Start-App $false @('--quit-after-last-window-closed=true')
            Start-Sleep -Seconds 5
            $orig = @(Get-PaneLeaves)[0].id
            $start = Get-FullSample $a.Pid 'start' -Settle
            $census = @(Get-ObjectCensus $a.Pid)
            $regions = [ordered]@{ start = Get-RegionCensus $a.Pid }
            $allocs = @{ start = Get-AllocCensus $a.Pid }
            $cycles = @()
            # One open/close cycle; returns its open and closed samples.
            function Invoke-PaneCycle([int]$c) {
                $made = New-Object System.Collections.ArrayList
                # More tabs (ctrl+shift+t on the live pane), then splits; the
                # mixed shape's tabs hold 4 + 3 + 3 panes.
                $tabAnchors = @($orig)
                for ($t = 1; $t -lt $shape.Count; $t++) {
                    $ids = @(Get-PaneLeaves | ForEach-Object { $_.id })
                    $panes = @(Get-TestChildWindows -Window $a.Top -Class 'GhozttyTerminal' | Where-Object { $_.Visible -and $_.Width -gt 0 })
                    if ($panes.Count -lt 1) { throw 'no visible terminal pane to open a tab from' }
                    $hw = [IntPtr][int64]$panes[0].Hwnd
                    $f = Focus-TestWindow -Window $a.Top -Child $hw
                    $k = Send-TestKeys -Window $a.Top -Target $hw -Modifiers ctrl, shift -Key T
                    if (-not ($f -and $k)) { throw "ctrl+shift+t was not delivered (focus=$f keys=$k)" }
                    $new = $null
                    $deadline = (Get-Date).AddSeconds(20)
                    do { Start-Sleep -Milliseconds 300; $new = @(Get-PaneLeaves | Where-Object { $ids -notcontains $_.id }) | Select-Object -First 1 } while ($null -eq $new -and (Get-Date) -lt $deadline)
                    if ($null -eq $new) { throw 'ctrl+shift+t opened no listed pane' }
                    [void]$made.Add($new.id)
                    $tabAnchors += $new.id
                }
                $plan = $shape
                for ($ti = 0; $ti -lt $plan.Count; $ti++) {
                    $target = $tabAnchors[$ti]
                    for ($j = 0; $j -lt $plan[$ti]; $j++) {
                        $nm = "pb$c$ti$j"
                        $dir = if ($j % 2 -eq 0) { 'right' } else { 'down' }
                        $r = Invoke-Verb @('+split', "--target=$target", "--name=$nm", "--direction=$dir")
                        if ($r.Code -ne 0) { throw "+split $nm failed: $($r.Text)" }
                        [void]$made.Add($nm)
                        $target = $nm
                    }
                }
                if (-not (Wait-PaneCount $paneTotal 30)) { throw "expected $paneTotal panes, +list shows $(@(Get-PaneLeaves).Count)" }
                Start-Sleep -Seconds 4
                $open = Get-FullSample $a.Pid "open $c" -Settle
                if ($c -eq 1) { $allocs.open1 = Get-AllocCensus $a.Pid }
                for ($m = $made.Count - 1; $m -ge 0; $m--) {
                    $r = Invoke-Verb @('+close', "--target=$($made[$m])")
                    if ($r.Code -ne 0) { throw "+close $($made[$m]) failed: $($r.Text)" }
                }
                if (-not (Wait-PaneCount 1 30)) { throw "panes did not close back to 1 ($(@(Get-PaneLeaves).Count) left)" }
                Start-Sleep -Seconds 3
                $closed = Get-FullSample $a.Pid "closed $c" -Settle
                return [pscustomobject]@{ Open = $open; Closed = $closed }
            }
            foreach ($c in 1, 2) {
                $cy = Invoke-PaneCycle $c
                $census += Get-ObjectCensus $a.Pid
                if ($c -eq 1) { $regions.cycle1_closed = Get-RegionCensus $a.Pid; $allocs.cycle1_closed = Get-AllocCensus $a.Pid }
                $cycles +=[ordered]@{ open = (Format-Sample $cy.Open); closed = (Format-Sample $cy.Closed) }
            }

            # T3005: the two cycles above sit inside the GPU driver's
            # upload-pool fill (T2782), so their difference cannot tell fill
            # from leak. Warm up until two cycles in a row are quiet, then
            # take a slope over -SettledCycles more.
            $settle = $null
            if ($SettledCycles -gt 0) {
                $prev = $cy.Closed
                $quiet = 0; $warm = 0
                $gpuSum = { param($s) if ($null -eq $s.GpuDedMB) { 0.0 } else { $s.GpuDedMB + $s.GpuShMB } }
                $warmRows = @()
                while ($quiet -lt 2 -and $warm -lt $CycleMaxWarmup) {
                    $warm++
                    $cy = Invoke-PaneCycle (2 + $warm)
                    $dP = $cy.Closed.PrivMB - $prev.PrivMB
                    $dG = (& $gpuSum $cy.Closed) - (& $gpuSum $prev)
                    $warmRows += [ordered]@{ private_mb = [math]::Round($dP, 1); gpu_mb = [math]::Round($dG, 1) }
                    if ($dP -le $SettleBudgetMB -and $dG -le $SettleBudgetMB) { $quiet++ } else { $quiet = 0 }
                    $prev = $cy.Closed
                }
                $settledOk = $quiet -ge 2
                Write-Host "[$Build] cycle: $warm warm-up cycle(s) after the first two, $(if ($settledOk) { 'settled' } else { "NEVER settled (cap $CycleMaxWarmup) - measuring anyway" }); $SettledCycles measured"
                $series = @($prev)
                $regions.settle_start = Get-RegionCensus $a.Pid
                for ($m = 1; $m -le $SettledCycles; $m++) {
                    $cy = Invoke-PaneCycle (2 + $warm + $m)
                    $series += $cy.Closed
                }
                $slopeOf = { param($sel) Get-Slope ([double[]]@($series | ForEach-Object { [double](& $sel $_) })) }
                $settle = [ordered]@{
                    method = "after cycles 1-2, warm-up cycles until two in a row each grow private bytes and GPU dedicated+shared memory by <= $SettleBudgetMB MB (cap $CycleMaxWarmup), then $SettledCycles measured cycles; slope = least-squares growth per cycle of the settled closed samples (the last warm-up closed sample plus each measured one). ~0 after settling = bounded fill; a steady positive slope = a leak"
                    warmup_cycles = $warm
                    settled = $settledOk
                    measured_cycles = $SettledCycles
                    warmup_deltas = $warmRows
                    closed_private_mb = @($series | ForEach-Object { $_.PrivMB })
                    closed_gpu_shared_mb = @($series | ForEach-Object { $_.GpuShMB })
                }
                $settleSlopes = [ordered]@{
                    settled_private_mb_per_cycle = & $slopeOf { param($s) $s.PrivMB }
                    settled_working_set_mb_per_cycle = & $slopeOf { param($s) $s.WsMB }
                    settled_handles_per_cycle = & $slopeOf { param($s) $s.Handles }
                    settled_gdi_per_cycle = & $slopeOf { param($s) $s.Gdi }
                    settled_user_per_cycle = & $slopeOf { param($s) $s.User }
                    settled_threads_per_cycle = & $slopeOf { param($s) $s.Threads }
                    settled_gpu_dedicated_mb_per_cycle = $(if ($null -ne $prev.GpuDedMB) { & $slopeOf { param($s) $s.GpuDedMB } } else { $null })
                    settled_gpu_shared_mb_per_cycle = $(if ($null -ne $prev.GpuShMB) { & $slopeOf { param($s) $s.GpuShMB } } else { $null })
                }
            }
            $regions.last_closed = Get-RegionCensus $a.Pid
            $lastClosed = $cy.Closed

            # Closed and idle: does anything the cycles left get trimmed back?
            $idleSample = $null
            if ($CycleIdleSeconds -gt 0) {
                Start-Sleep -Seconds $CycleIdleSeconds
                $idleSample = Get-FullSample $a.Pid 'closed idle' -Settle
                $regions.closed_idle = Get-RegionCensus $a.Pid
            }
            $first = Format-Sample $start
            $result.cycle = [ordered]@{
                method = 'one window, persistence off, cmd panes: settled sample (lib\ProcessMemory.ps1 Get-Sample + working set) at start, with 10 panes open over 3 tabs (ctrl+shift+t x2, then +split 3/2/2), and after +close of every added pane plus the 1 s undo window; cycles 1 and 2 as cycle1/cycle2, then the settle block (T3005) when -SettledCycles > 0. GPU memory is the GPU Process Memory counter set summed over adapters.'
                shape = $CycleShape
                panes = $paneTotal
                start = $first
                cycle1 = $cycles[0]
                cycle2 = $cycles[1]
                leak = [ordered]@{
                    first_cycle_private_mb = [math]::Round($cycles[0].closed.private_mb - $first.private_mb, 1)
                    second_cycle_private_mb = [math]::Round($cycles[1].closed.private_mb - $cycles[0].closed.private_mb, 1)
                    second_cycle_handles = $cycles[1].closed.handles - $cycles[0].closed.handles
                    second_cycle_gdi = $cycles[1].closed.gdi - $cycles[0].closed.gdi
                    second_cycle_user = $cycles[1].closed.user - $cycles[0].closed.user
                    second_cycle_threads = $cycles[1].closed.threads - $cycles[0].closed.threads
                    second_cycle_gpu_dedicated_mb = $(if ($null -ne $first.gpu_dedicated_mb) { [math]::Round($cycles[1].closed.gpu_dedicated_mb - $cycles[0].closed.gpu_dedicated_mb, 1) } else { $null })
                }
            }
            # T2989: what each cycle left, by kind - kernel handle type,
            # window class, thread group - and the USER objects that are not
            # windows at all.
            $result.cycle.residue = [ordered]@{
                method = 'object census (handle types: SystemExtendedHandleInformation + ObjectTypesInformation; windows: top-level, child and message-only windows of the pid on the test desktop, by class; threads: by start module and name) at start and after each cycle closed; user_non_window_delta = GetGuiResources(USER) delta minus window-count delta'
                first_cycle = Format-CensusDelta $census[0] $census[1]
                second_cycle = Format-CensusDelta $census[1] $census[2]
                at_start = Format-CensusTotals $census[0]
            }
            if ($settle) {
                foreach ($k in $settleSlopes.Keys) { $result.cycle.leak[$k] = $settleSlopes[$k] }
                $result.cycle.settle = $settle
            }
            $result.cycle.last_closed = Format-Sample $lastClosed
            if ($idleSample) {
                $result.cycle.closed_idle = Format-Sample $idleSample
                $result.cycle.closed_idle.after_seconds = $CycleIdleSeconds
            }
            # T3005: the committed-memory split by owner (heap vs the GPU
            # driver's write-combined pool vs everything else), so a residue
            # is attributed instead of guessed at.
            $regions.method = 'VirtualQueryEx walk of every committed region, classed: heap = MEM_PRIVATE in an allocation whose base carries the NT heap segment (0xffeeffee) or segment heap (0xddeeddee) signature at +0x10; writecombine = MEM_PRIVATE with PAGE_WRITECOMBINE (the GPU driver upload pool); uncached = PAGE_NOCACHE; stack = an allocation holding a PAGE_GUARD region; private_rw = every other MEM_PRIVATE region (Zig page allocator incl. the Debug DebugAllocator, driver arenas, heap large blocks); mapped = MEM_MAPPED; image = MEM_IMAGE. Taken at start, after cycle 1 closed, at the settle start, after the last cycle closed, and closed-and-idle'
            $regions.first_cycle = Get-RegionDelta $regions.start $regions.cycle1_closed
            if ($regions.Contains('settle_start')) { $regions.settled = Get-RegionDelta $regions.settle_start $regions.last_closed }
            if ($regions.Contains('closed_idle')) { $regions.idle = Get-RegionDelta $regions.last_closed $regions.closed_idle }
            # T3130: private_rw by allocation - what the first cycle grew, and what 10 open panes hold.
            if ($allocs.Contains('cycle1_closed')) {
                $regions.private_rw_allocs = [ordered]@{
                    method = 'T3130: VirtualQueryEx walk grouped by AllocationBase, private_rw allocations only; kind heap_large = first qword points into an NT heap (a HEAP_VIRTUAL_ALLOC block), exact = the whole reservation committed (Zig page_allocator shape), arena = part of the reservation only reserved (grow-in-place pools, e.g. GL driver arenas). first_cycle = start -> cycle 1 closed; open1 = start -> 10 panes open in cycle 1. New allocations count whole, grown ones by their growth'
                    first_cycle = Get-AllocDelta $allocs.start $allocs.cycle1_closed
                }
                if ($allocs.Contains('open1')) { $regions.private_rw_allocs.open1 = Get-AllocDelta $allocs.start $allocs.open1 }
            }
            $result.cycle.regions = $regions
            if ($null -eq $first.gpu_dedicated_mb) { $result.cycle.gpu_reason = 'GPU Process Memory counters unreadable on this box' }

            # T3005: a Debug build's DebugAllocator reports every allocation
            # still live at exit on stderr (global.zig GlobalState.deinit), so
            # quit the app the way a user does and read what it names.
            if (-not $isRelease) {
                $gpa = [ordered]@{ method = 'Debug build only: WM_SYSCOMMAND SC_CLOSE to the window after the last cycle (confirm-close off, persistence off, quit-after-last-window-closed on), wait up to 30 s for the process to exit, then count DebugAllocator leak lines ("leaked") on its stderr. Allocations live at exit, not per-cycle growth; read with the slope' }
                $errPath = $script:appErr
                [void](Send-TestSysCommand -Window $a.Top -Command close)
                $p = Get-Process -Id $a.Pid -ErrorAction SilentlyContinue
                $gpa.exited = if ($p) { $p.WaitForExit(30000) } else { $true }
                $lines = @()
                if ($errPath -and (Test-Path $errPath)) {
                    # Plain strings: Get-Content's carry PSProvider note
                    # properties, which ConvertTo-Json -Depth 12 walks until it
                    # runs out of memory.
                    $lines = @(Get-Content $errPath -ErrorAction SilentlyContinue | Where-Object { $_ -match 'leaked' } | ForEach-Object { [string]$_ })
                    # The work dir is removed at the end; keep the full report
                    # (stack traces included) beside the JSON.
                    $keep = [IO.Path]::ChangeExtension($Out, '.debug-stderr.txt')
                    Copy-Item $errPath $keep -Force
                    $gpa.stderr = $keep
                }
                else { $gpa.reason = 'no stderr capture for the app' }
                $gpa.leak_lines = $lines.Count
                $gpa.first_lines = @($lines | Select-Object -First 5)
                if (-not $gpa.exited) { $gpa.reason = 'the app did not exit within 30 s of SC_CLOSE, so the allocator never reported' }
                $result.cycle.gpa_leak_report = $gpa
            }
        } catch { $failed = $true; $result.cycle = [ordered]@{ error = "$_" } }
        finally { Stop-App }
    }

    # ------------------------------------------------------------ viewer
    # T3033 (PA-V01): until this phase nothing in the baseline opened a viewer,
    # so every viewer cost in audit-1 (V-findings.md) was an estimate.
    if ($want -contains 'viewer') {
        Write-Host "[$Build] viewer: markdown + git-status: + website; ${ViewerVisibleSeconds} s shown, ${ViewerHiddenSeconds} s in a background tab, ${ViewerCloseSeconds} s after closing"
        $srvJob = $null
        $srvPidFile = Join-Path $work 'viewer-server.pid'
        try {
            $vdir = Join-Path $work 'viewer'
            $vrepo = Join-Path $vdir 'repo'
            New-Item -ItemType Directory -Force $vrepo | Out-Null
            # The markdown: 60 sections with headings, emphasis, code, links
            # and lists - a contents card's worth, about 12 KB.
            $doc = Join-Path $vdir 'doc.md'
            $sections = 1..60 | ForEach-Object { "## Section $_`n`nParagraph $_ with **bold**, ``code`` and a [link](https://example.invalid/$_).`n`n- item a`n- item b`n" }
            [IO.File]::WriteAllText($doc, "# Perf viewer`n`n$($sections -join "`n")")
            # The git-status: repository: two committed files, one modified,
            # one untracked - a staged-free working tree with both kinds.
            [IO.File]::WriteAllText((Join-Path $vrepo 'a.txt'), (1..200 | ForEach-Object { "line $_" }) -join "`n")
            [IO.File]::WriteAllText((Join-Path $vrepo 'b.txt'), "b`n")
            # git's stderr (a CRLF warning) is a terminating NativeCommandError
            # under this script's Stop preference in PS 5.1, so Continue here.
            $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
            try {
                foreach ($g in @(@('init', '-q'), @('config', 'core.autocrlf', 'false'), @('config', 'user.email', 'perf@example.invalid'), @('config', 'user.name', 'perf'), @('add', '-A'), @('commit', '-q', '-m', 'base'))) {
                    & git.exe -C $vrepo @g 2>&1 | Out-Null
                }
            } finally { $ErrorActionPreference = $eap }
            if (-not (& git.exe -C $vrepo rev-parse --short HEAD 2>$null)) { throw "the git-status: scratch repository could not be created in $vrepo" }
            [IO.File]::WriteAllText((Join-Path $vrepo 'a.txt'), (1..200 | ForEach-Object { if ($_ % 20 -eq 0) { "changed $_" } else { "line $_" } }) -join "`n")
            [IO.File]::WriteAllText((Join-Path $vrepo 'c.txt'), "untracked`n")

            # The website: a static page from a loopback listener in a
            # background job (not a descendant of the app, so it is never in
            # the measured tree). Pending() polling, not a blocking Accept, and
            # its pid on disk, so teardown is bounded (lib\JobTeardown.ps1).
            $portFile = Join-Path $vdir 'port.txt'
            $srvJob = Start-Job -ArgumentList $srvPidFile, $portFile -ScriptBlock {
                param($pidFile, $portFile)
                [IO.File]::WriteAllText($pidFile, "$PID")
                $paras = (1..120 | ForEach-Object { "<p>Paragraph $_ of a static page served for the perf baseline viewer phase.</p>" }) -join ''
                $html = '<!doctype html><html><head><meta charset="utf-8"><title>perf viewer site</title></head><body style="font-family:sans-serif"><h1>Perf viewer site</h1>' + $paras + '</body></html>'
                $body = [Text.Encoding]::UTF8.GetBytes($html)
                $l = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
                $l.Start()
                [IO.File]::WriteAllText($portFile, "$($l.LocalEndpoint.Port)")
                while ($true) {
                    if (-not $l.Pending()) { Start-Sleep -Milliseconds 50; continue }
                    $c = $l.AcceptTcpClient()
                    try {
                        $s = $c.GetStream()
                        $s.ReadTimeout = 2000
                        $buf = New-Object byte[] 8192
                        [void]$s.Read($buf, 0, $buf.Length)
                        $hdr = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: text/html; charset=utf-8`r`nContent-Length: $($body.Length)`r`nCache-Control: no-store`r`nConnection: close`r`n`r`n")
                        $s.Write($hdr, 0, $hdr.Length)
                        $s.Write($body, 0, $body.Length)
                        $s.Flush()
                    } catch { } finally { $c.Close() }
                }
            }
            $deadline = (Get-Date).AddSeconds(30)
            while (-not (Test-Path $portFile) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }
            $port = "$(Get-Content $portFile -Raw -ErrorAction SilentlyContinue)".Trim()
            if ($port -notmatch '^\d+$') { throw 'the loopback site never reported a port' }

            $a = Start-App $false
            Start-Sleep -Seconds 5
            $orig = @(Get-PaneLeaves)[0].id
            $baseApp = Get-FullSample $a.Pid 'viewer base' -Settle
            $baseTree = Get-WebViewTree $a.Pid

            # --- open: three viewers beside the one terminal, all in tab 1
            $splits = @(
                @('+split', "--target=$orig", '--name=pvmd', '--direction=right', "--view=$doc"),
                @('+split', '--target=pvmd', '--name=pvgs', '--direction=down', "--working-directory=$vrepo", '--view=git-status:'),
                @('+split', "--target=$orig", '--name=pvweb', '--direction=down', "--view=http://127.0.0.1:$port/")
            )
            $sw = [Diagnostics.Stopwatch]::StartNew()
            foreach ($sa in $splits) {
                $r = Invoke-Verb $sa
                if ($r.Code -ne 0) { throw "$($sa[2]): +split --view failed: $($r.Text)" }
            }
            if (-not (Wait-PaneCount 4 30)) { throw "expected 4 panes (1 terminal + 3 viewers), +list shows $(@(Get-PaneLeaves).Count)" }
            $deadline = (Get-Date).AddSeconds(30)
            do { $vc = Get-ViewerWindowCount $a.Top; if ($vc[1] -ge 3) { break }; Start-Sleep -Milliseconds 250 } while ((Get-Date) -lt $deadline)
            if ($vc[1] -lt 3) { throw "only $($vc[1]) of 3 viewer windows became visible ($($vc[0]) exist)" }
            # The tree is up when its process count holds for 3 s running
            # (renderers start after the controllers, the site one after its
            # navigation), capped at 45 s.
            $stable = 0; $prevN = -1; $deadline = (Get-Date).AddSeconds(45)
            do {
                Start-Sleep -Seconds 1
                $n = @(Get-WebViewTree $a.Pid).Count
                if ($n -gt 0 -and $n -eq $prevN) { $stable++ } else { $stable = 0 }
                $prevN = $n
            } while ($stable -lt 3 -and (Get-Date) -lt $deadline)
            $treeUpS = [math]::Round($sw.Elapsed.TotalSeconds, 1)
            Start-Sleep -Seconds 5
            $openApp = Get-FullSample $a.Pid 'viewer open' -Settle
            $openTree = Get-WebViewTree $a.Pid
            $wvReason = $null
            if (@($openTree | Where-Object { $null -ne $_ }).Count -eq 0) {
                $wvReason = 'no msedgewebview2.exe process descends from the app with 3 viewers shown - WebView2 discovery failed on this desktop, so every webview figure in this phase is empty, not zero'
            }
            # CPU while shown and idle - after 15 s more, so the span does not
            # catch the pages' first layout and the first git-status: listing
            # (the first two Debug runs read 1.87 and 3.49% app CPU without it).
            Start-Sleep -Seconds 15
            $c0 = Get-PidCpu @($openTree | ForEach-Object { $_.Pid })
            $s0 = Get-Snap $a.Pid
            Start-Sleep -Seconds $ViewerVisibleSeconds
            $s1 = Get-Snap $a.Pid
            $c1 = Get-PidCpu @(Get-WebViewTree $a.Pid | ForEach-Object { $_.Pid })
            $openRate = Get-Rate $s0 $s1
            $openWv = Get-TreeCpuPct $c0 $c1 $openRate.wall_s
            $openWvBlock = Format-WebViewTree $openTree
            $openWvBlock.cpu_pct = $openWv.cpu_pct
            $openWvBlock.exited_in_span = $openWv.exited_in_span
            $result.viewer = [ordered]@{
                method = "one app (persistence off, 1 cmd pane); three viewers +split beside it in tab 1: a 60-section markdown file, git-status: on a scratch repo (1 modified, 1 untracked), and a static 120-paragraph page from a loopback listener. The WebView2 tree is every msedgewebview2.exe descending from the app, role from --type=; app figures are the app process alone"
                base = [ordered]@{
                    method = 'before any viewer: app settled, WebView2 tree (expected empty: the environment is created on the first viewer)'
                    app = Format-AppSample $baseApp
                    webview = Format-WebViewTree $baseTree
                }
                open = [ordered]@{
                    method = "3 viewers shown: the tree counted once its process count held for 3 s (cap 45 s) plus 5 s, app settled; then 15 s more and CPU over $ViewerVisibleSeconds s shown and idle (app: user+kernel; webview: per-process user+kernel, a process born in the span counted whole). growth = app minus base"
                    viewers = 3
                    tree_up_s = $treeUpS
                    app = Format-AppSample $openApp
                    growth = [ordered]@{ private_mb = [math]::Round($openApp.PrivMB - $baseApp.PrivMB, 1); gdi = $openApp.Gdi - $baseApp.Gdi; user = $openApp.User - $baseApp.User; handles = $openApp.Handles - $baseApp.Handles; threads = $openApp.Threads - $baseApp.Threads }
                    webview = $openWvBlock
                }
            }
            $result.viewer.open.app.cpu_pct = $openRate.cpu_pct
            $result.viewer.open.app.wakeups_per_s = $openRate.wakeups_per_s
            if ($wvReason) { $result.viewer.webview_reason = $wvReason }

            # --- hidden: a new tab over them (ctrl+shift+t on the terminal),
            # so all three viewers sit in a background tab.
            $ids = @(Get-PaneLeaves | ForEach-Object { $_.id })
            $panes = @(Get-TestChildWindows -Window $a.Top -Class 'GhozttyTerminal' | Where-Object { $_.Visible -and $_.Width -gt 0 })
            if ($panes.Count -lt 1) { throw 'no visible terminal pane to open the covering tab from' }
            $hw = [IntPtr][int64]$panes[0].Hwnd
            $f = Focus-TestWindow -Window $a.Top -Child $hw
            $k = Send-TestKeys -Window $a.Top -Target $hw -Modifiers ctrl, shift -Key T
            if (-not ($f -and $k)) { throw "ctrl+shift+t was not delivered (focus=$f keys=$k)" }
            $tabPane = $null
            $deadline = (Get-Date).AddSeconds(20)
            do { Start-Sleep -Milliseconds 300; $tabPane = @(Get-PaneLeaves | Where-Object { $ids -notcontains $_.id }) | Select-Object -First 1 } while ($null -eq $tabPane -and (Get-Date) -lt $deadline)
            if ($null -eq $tabPane) { throw 'ctrl+shift+t opened no listed pane' }
            Start-Sleep -Seconds 5
            $vcHidden = Get-ViewerWindowCount $a.Top
            $hTree0 = Get-WebViewTree $a.Pid
            $c0 = Get-PidCpu @($hTree0 | ForEach-Object { $_.Pid })
            $s0 = Get-Snap $a.Pid
            Start-Sleep -Seconds $ViewerHiddenSeconds
            $s1 = Get-Snap $a.Pid
            $hTree1 = Get-WebViewTree $a.Pid
            $c1 = Get-PidCpu @($hTree1 | ForEach-Object { $_.Pid })
            $hiddenApp = Get-FullSample $a.Pid 'viewer hidden'
            $hRate = Get-Rate $s0 $s1
            $hWv = Get-TreeCpuPct $c0 $c1 $hRate.wall_s
            $hWvBlock = Format-WebViewTree $hTree1
            $hWvBlock.cpu_pct = $hWv.cpu_pct
            $hWvBlock.exited_in_span = $hWv.exited_in_span
            $hWvBlock.private_mb_change = [math]::Round($hWvBlock.private_mb - $openWvBlock.private_mb, 1)
            $result.viewer.hidden = [ordered]@{
                method = "ctrl+shift+t on the terminal opens tab 2 over the viewers' tab; 5 s, then CPU over $ViewerHiddenSeconds s (as in open) and the tree and app sampled at its end. viewer_windows_visible must be 0 (the viewers really are hidden); private_mb_change = tree now minus tree when open"
                seconds = $ViewerHiddenSeconds
                viewer_windows_visible = $vcHidden[1]
                app = Format-AppSample $hiddenApp
                webview = $hWvBlock
            }
            $result.viewer.hidden.app.cpu_pct = $hRate.cpu_pct
            $result.viewer.hidden.app.wakeups_per_s = $hRate.wakeups_per_s
            if ($vcHidden[1] -gt 0) { $result.viewer.hidden.reason = "$($vcHidden[1]) viewer window(s) still visible after the covering tab opened: the hidden figures are not of hidden viewers" }

            # --- after_close: close every viewer and the covering tab, then
            # watch the tree for the residual (PA-V02: the browser tree is
            # expected to stay up for the app's life).
            foreach ($t in @("$($tabPane.id)", 'pvweb', 'pvgs', 'pvmd')) {
                $r = Invoke-Verb @('+close', "--target=$t")
                if ($r.Code -ne 0) { throw "+close $t failed: $($r.Text)" }
            }
            if (-not (Wait-PaneCount 1 30)) { throw "panes did not close back to 1 ($(@(Get-PaneLeaves).Count) left)" }
            $closeSw = [Diagnostics.Stopwatch]::StartNew()
            $series = New-Object System.Collections.ArrayList
            $step = 10
            for ($t = $step; $t -le $ViewerCloseSeconds; $t += $step) {
                while ($closeSw.Elapsed.TotalSeconds -lt $t) { Start-Sleep -Milliseconds 200 }
                $tr = Format-WebViewTree (Get-WebViewTree $a.Pid)
                [void]$series.Add([pscustomobject]@{ t_s = $t; procs = $tr.procs; renderer_procs = $tr.renderer_procs; private_mb = $tr.private_mb })
            }
            $closeTree = Get-WebViewTree $a.Pid
            $closeApp = Get-FullSample $a.Pid 'viewer closed' -Settle
            $result.viewer.after_close = [ordered]@{
                method = "+close the covering tab and all three viewers (to 1 pane), then the tree every 10 s for $ViewerCloseSeconds s (series) and the residual tree and settled app at the end. leak = app at the end minus base (before any viewer); it includes what the covering tab's terminal pane left behind"
                seconds = $ViewerCloseSeconds
                app = Format-AppSample $closeApp
                leak = [ordered]@{ private_mb = [math]::Round($closeApp.PrivMB - $baseApp.PrivMB, 1); gdi = $closeApp.Gdi - $baseApp.Gdi; user = $closeApp.User - $baseApp.User; handles = $closeApp.Handles - $baseApp.Handles; threads = $closeApp.Threads - $baseApp.Threads }
                webview = Format-WebViewTree $closeTree
                series = $series.ToArray()
            }
            Write-Host ("  viewer: open tree {0} procs / {1} MB (app +{2} MB, +{3} GDI, +{4} USER); hidden {5}% CPU tree / {6}% app; after close {7} procs / {8} MB left" -f `
                $openWvBlock.procs, $openWvBlock.private_mb, $result.viewer.open.growth.private_mb, $result.viewer.open.growth.gdi, $result.viewer.open.growth.user, `
                $hWvBlock.cpu_pct, $hRate.cpu_pct, $result.viewer.after_close.webview.procs, $result.viewer.after_close.webview.private_mb)
        } catch { $failed = $true; $result.viewer = [ordered]@{ error = "$_"; partial = $result.viewer } }
        finally {
            Stop-App
            if ($srvJob) { [void](Stop-JobBounded -Job $srvJob -PidFile $srvPidFile -Label 'viewer loopback site') }
        }
    }

    # ------------------------------------------------------------ agent
    if ($want -contains 'agent') {
        Write-Host "[$Build] agent: $AgentSessions sessions, $AttachCycles detach/attach cycles"
        try {
            # A cold sandbox has no agent and the first app gives up on it after
            # ~2 s, so bring one app up purely to start the agent, then measure
            # in apps that find it running.
            $agentPid = Start-SandboxAgent
            $a = Start-App $true
            Start-Sleep -Seconds 6
            $base = Get-FullSample $agentPid 'agent base' -Settle
            $sessBase = @(Get-SessionRows).Count

            $s0 = Get-Snap $agentPid
            Start-Sleep -Seconds 30
            $s1 = Get-Snap $agentPid
            $idle = Get-Rate $s0 $s1

            $anchor = @(Get-PaneLeaves)[0].id
            $target = $anchor
            for ($n = 1; $n -le $AgentSessions; $n++) {
                $nm = "pbag$n"
                $r = Invoke-Verb @('+split', "--target=$target", "--name=$nm", "--direction=$(if ($n % 2) { 'right' } else { 'down' })")
                if ($r.Code -ne 0) { throw "+split $nm failed: $($r.Text)" }
                $target = $nm
            }
            Start-Sleep -Seconds 6
            $more = Get-FullSample $agentPid 'agent +sessions' -Settle
            $sessMore = @(Get-SessionRows).Count
            $added = $sessMore - $sessBase
            $perSession = if ($added -gt 0) { [math]::Round(($more.PrivMB - $base.PrivMB) / $added, 2) } else { $null }
            $perSessionChild = if ($added -gt 0) { [math]::Round(($more.ProcMB - $base.ProcMB) / $added, 2) } else { $null }

            $att = @()
            for ($c = 1; $c -le $AttachCycles; $c++) {
                Stop-App
                Start-Sleep -Seconds 3
                $det = Get-FullSample $agentPid "detached $c" -Settle
                $detAttached = @(Get-SessionRows | Where-Object { $_.attached }).Count
                $a = Start-App $true
                Start-Sleep -Seconds 8
                $re = Get-FullSample $agentPid "attached $c" -Settle
                $reAttached = @(Get-SessionRows | Where-Object { $_.attached }).Count
                # The app's own side of the same re-attach (T3016): its threads
                # (the agent connection's reader threads among them) and its
                # private bytes once every restored pane's replay has landed.
                $appRe = Get-FullSample $a.Pid "app attached $c" -Settle
                $att += [ordered]@{
                    detached = [ordered]@{ handles = $det.Handles; threads = $det.Threads; private_mb = $det.PrivMB; attached_sessions = $detAttached }
                    attached = [ordered]@{ handles = $re.Handles; threads = $re.Threads; private_mb = $re.PrivMB; attached_sessions = $reAttached }
                    app = [ordered]@{ threads = $appRe.Threads; private_mb = $appRe.PrivMB; handles = $appRe.Handles }
                }
            }
            $result.agent = [ordered]@{
                method = "persistence on; agent started by a throwaway app, then measured: idle = 30 s CPU and context switches with 1 attached session; per-session = (private bytes, and its ConPTY/shell descendants' private bytes) delta after $AgentSessions +split panes divided by the +sessions --json delta; attach/detach = app killed (sessions stay pinned) then relaunched (restore re-attaches), $AttachCycles times, settled agent sample after each"
                idle_cpu_pct = $idle.cpu_pct
                idle_cpu_cycle_pct = $idle.cpu_cycle_pct
                idle_wakeups_per_s = $idle.wakeups_per_s
                base = Format-Sample $base
                sessions_base = $sessBase
                sessions_after = $sessMore
                per_session_private_mb = $perSession
                per_session_child_private_mb = $perSessionChild
                attach_cycles = $att
                attach_cycle_handle_growth = $(if ($att.Count -ge 2) { $att[-1].attached.handles - $att[0].attached.handles } else { $null })
                attach_cycle_thread_growth = $(if ($att.Count -ge 2) { $att[-1].attached.threads - $att[0].attached.threads } else { $null })
            }
            if ($null -eq $perSession) { $result.agent.per_session_reason = "+sessions --json showed no added sessions ($sessBase -> $sessMore): the panes did not go through the agent" }
        } catch { $failed = $true; $result.agent = [ordered]@{ error = "$_" } }
        finally { Stop-App }
    }
} finally {
    [void](Stop-RepoGhoztty -Exe $exe -SettleMs 500 -ScopeToLineage)
    Remove-TestDesktop
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
$fgSeen = @(Stop-TestForegroundWatch)
$leaked = @(Get-TestLaunchedPids | Where-Object { $fgSeen -contains $_ })
if ($leaked.Count) { $failed = $true; $result.foreground_leak = "test-desktop pids reached the interactive foreground: $($leaked -join ',')" }

$doc = [ordered]@{
    schema = 'ghoztty-perf-baseline/1'
    task = 'T2958'
    generated = (Get-Date).ToString('o')
    commit = $commit
    parameters = [ordered]@{ cycle_shape = $CycleShape; settled_cycles = $SettledCycles; cycle_max_warmup = $CycleMaxWarmup; settle_budget_mb = $SettleBudgetMB; cycle_idle_seconds = $CycleIdleSeconds; viewer_visible_seconds = $ViewerVisibleSeconds; viewer_hidden_seconds = $ViewerHiddenSeconds; viewer_close_seconds = $ViewerCloseSeconds; app_env = $appEnvMap }
    tolerance = $script:Tolerance
    builds = [ordered]@{ ($Build.ToLower()) = $result }
}
$doc | ConvertTo-Json -Depth 12 | Set-Content -Path $Out -Encoding ascii
Write-Host "PERF BASELINE ($Build) written: $Out$(if ($failed) { ' - WITH ERRORS, read the error fields' })"
exit $(if ($failed) { 1 } else { 0 })
