# T2669: does an idle Ghoztty grow without bound because the NVIDIA GL driver
# strands 64 KB (nvoglv64!DllMain, DLL_THREAD_ATTACH -> VirtualAlloc, T2644)
# for every thread the process EVER creates - OS thread-pool workers included?
#
# One fresh app on the hidden test desktop (test\win32\lib\TestDesktop.ps1),
# release-sandbox isolated (private app pipe, agent lineage and LOCALAPPDATA),
# never the user's install. Two idle spans:
#   terminal  1 window, 1 cmd pane, nothing typed, for -Minutes
#   viewer    the same window plus a markdown viewer split beside it, for
#             -ViewerMinutes (0 skips it)
# Every -SampleMs the app is read for private bytes and its thread list. A
# thread is NEW when its (tid, create time) pair has not been seen before, so
# a recycled tid is still counted; a thread born and gone between two samples
# is not seen at all, so threads_created is a LOWER BOUND. Each new thread is
# named by the module its Win32 start address falls in (ntdll = an OS
# thread-pool worker, ghoztty = ours) so growth can be attributed.
#
# Verdict per span: private-bytes slope (MB/h, least squares over the span
# after a -SettleMinutes warm-up), threads created per hour, and the slope the
# driver cost alone would predict (threads/h x 64 KB). FLAT when the slope is
# within -FlatMBPerHour; otherwise GROWING (or SHRINKING - the working set
# trimming back after startup), with the thread sources listed.
#
# USAGE
#   powershell -NoProfile -File scripts\idle-thread-growth.ps1                # 60 + 30 min, release
#   powershell -NoProfile -File scripts\idle-thread-growth.ps1 -Minutes 2 -ViewerMinutes 1 -SettleMinutes 0
#   powershell -NoProfile -File scripts\idle-thread-growth.ps1 -SelfTest       # the detector's positive control
# Writes temp\idle-thread-growth-<stamp>.json and prints IDLE GROWTH lines.
param(
    [ValidateSet('Debug', 'Release')][string]$Build = 'Release',
    [double]$Minutes = 60,
    [double]$ViewerMinutes = 30,
    [double]$SettleMinutes = 5,
    [int]$SampleMs = 1000,
    [double]$FlatMBPerHour = 1.0,
    [string]$Out,
    [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$lib = Join-Path $repo 'test\win32\lib'
. (Join-Path $lib 'CleanSlate.ps1')
. (Join-Path $lib 'Isolation.ps1')
. (Join-Path $lib 'TestDesktop.ps1')

$isRelease = $Build -eq 'Release'
$exe = Join-Path $repo $(if ($isRelease) { 'zig-out-release\bin\ghoztty.exe' } else { 'zig-out\bin\ghoztty.exe' })
if (-not (Test-Path $exe)) {
    Write-Host "IDLE GROWTH: $exe is missing. Build it with:"
    if ($isRelease) { Write-Host '  zig build -Dapp-runtime=win32 -Doptimize=ReleaseFast -Dtarget=x86_64-windows-gnu -Dstrip=false --prefix zig-out-release' }
    else { Write-Host '  zig build -Dapp-runtime=win32 -Doptimize=Debug' }
    exit 2
}
$cli = Join-Path (Split-Path $exe -Parent) 'ghoztty.com'
if (-not (Test-Path $cli)) { $cli = $exe }
if (-not $Out) { $Out = Join-Path $repo ("temp\idle-thread-growth-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss')) }
New-Item -ItemType Directory -Force (Split-Path $Out -Parent) | Out-Null

if (-not ('IdleThreads' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class IdleThreads {
    [DllImport("kernel32.dll")] static extern IntPtr OpenThread(uint access, bool inherit, uint tid);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll")] static extern bool GetThreadTimes(IntPtr h, out long create, out long exit, out long kernel, out long user);
    [DllImport("ntdll.dll")] static extern int NtQueryInformationThread(IntPtr h, int cls, out IntPtr info, int len, IntPtr ret);
    // { createTime, win32StartAddress } for a thread; null when it cannot be opened.
    public static long[] Identity(uint tid) {
        IntPtr h = OpenThread(0x0800 /* QUERY_LIMITED_INFORMATION */ | 0x0040 /* QUERY_INFORMATION */, false, tid);
        if (h == IntPtr.Zero) h = OpenThread(0x0800, false, tid);
        if (h == IntPtr.Zero) return null;
        try {
            long c, e, k, u;
            if (!GetThreadTimes(h, out c, out e, out k, out u)) return null;
            IntPtr start;
            long addr = 0;
            if (NtQueryInformationThread(h, 9 /* ThreadQuerySetWin32StartAddress */, out start, IntPtr.Size, IntPtr.Zero) == 0) addr = start.ToInt64();
            return new long[] { c, addr };
        } finally { CloseHandle(h); }
    }
}
'@
}

function Get-ModuleMap([int]$ProcessId) {
    $m = @()
    try {
        foreach ($mod in (Get-Process -Id $ProcessId).Modules) {
            $m += [pscustomobject]@{ Name = $mod.ModuleName; Base = $mod.BaseAddress.ToInt64(); End = $mod.BaseAddress.ToInt64() + $mod.ModuleMemorySize }
        }
    } catch {}
    return $m
}
function Resolve-Module([long]$Addr) {
    if ($Addr -eq 0) { return '?' }
    foreach ($x in $script:modMap) { if ($Addr -ge $x.Base -and $Addr -lt $x.End) { return $x.Name } }
    # A module loaded since the map was taken: refresh once and retry.
    $script:modMap = Get-ModuleMap $script:appPid
    foreach ($x in $script:modMap) { if ($Addr -ge $x.Base -and $Addr -lt $x.End) { return $x.Name } }
    return 'unmapped'
}
function Get-Slope([double[]]$X, [double[]]$Y) {
    $n = $X.Count
    if ($n -lt 3) { return $null }
    $mx = ($X | Measure-Object -Average).Average; $my = ($Y | Measure-Object -Average).Average
    $num = 0.0; $den = 0.0
    for ($i = 0; $i -lt $n; $i++) { $num += ($X[$i] - $mx) * ($Y[$i] - $my); $den += ($X[$i] - $mx) * ($X[$i] - $mx) }
    if ($den -eq 0) { return $null }
    return $num / $den
}

# One idle span: sample until $Span minutes pass, return the summary.
function Measure-Span([string]$Label, [double]$Span) {
    Write-Host ("[{0}] {1}: {2} min idle, sampling every {3} ms" -f (Get-Date -Format 'HH:mm:ss'), $Label, $Span, $SampleMs)
    $start = Get-Date
    $end = $start.AddMinutes($Span)
    $rows = New-Object System.Collections.Generic.List[object]
    $created = 0; $bySource = @{}; $lastMin = -1
    while ((Get-Date) -lt $end) {
        $p = Get-Process -Id $script:appPid -ErrorAction SilentlyContinue
        if (-not $p) { throw "the app (pid $script:appPid) exited during the $Label span" }
        $t = ((Get-Date) - $start).TotalMinutes
        foreach ($th in $p.Threads) {
            $id = [IdleThreads]::Identity([uint32]$th.Id)
            if ($null -eq $id) { continue }
            $key = "$($th.Id):$($id[0])"
            if ($script:seen.ContainsKey($key)) { continue }
            $script:seen[$key] = $true
            if (-not $script:baselined) { continue }
            $created++
            $src = Resolve-Module $id[1]
            if ($bySource.ContainsKey($src)) { $bySource[$src]++ } else { $bySource[$src] = 1 }
        }
        $rows.Add([pscustomobject]@{ t_min = [math]::Round($t, 3); private_mb = [math]::Round($p.PrivateMemorySize64 / 1MB, 3); threads = $p.Threads.Count; created = $created })
        $m = [int][math]::Floor($t)
        if ($m -ne $lastMin -and $m % 5 -eq 0) {
            $lastMin = $m
            Write-Host ("  {0,5:N1} min  private {1,8:N2} MB  threads {2,3}  created {3}" -f $t, ($p.PrivateMemorySize64 / 1MB), $p.Threads.Count, $created)
        }
        Start-Sleep -Milliseconds $SampleMs
    }
    $fit = @($rows | Where-Object { $_.t_min -ge [math]::Min($SettleMinutes, $Span / 2) })
    $slope = Get-Slope ([double[]]@($fit | ForEach-Object { $_.t_min })) ([double[]]@($fit | ForEach-Object { $_.private_mb }))
    $mbh = if ($null -eq $slope) { $null } else { [math]::Round($slope * 60, 3) }
    $tph = [math]::Round($created / ($Span / 60.0), 1)
    $pred = [math]::Round($tph * 64 / 1024, 3)
    $verdict = if ($null -eq $mbh) { 'UNKNOWN' } elseif ([math]::Abs($mbh) -le $FlatMBPerHour) { 'FLAT' } elseif ($mbh -lt 0) { 'SHRINKING' } else { 'GROWING' }
    $srcText = (($bySource.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' ')
    if (-not $srcText) { $srcText = 'none' }
    Write-Host ("IDLE GROWTH {0} {1}: private {2} -> {3} MB, slope {4} MB/h after {5} min, threads created {6} ({7}/h, driver cost alone {8} MB/h), sources: {9}" -f `
        $Label, $verdict, $rows[0].private_mb, $rows[$rows.Count - 1].private_mb, $mbh, $SettleMinutes, $created, $tph, $pred, $srcText)
    $script:baselined = $true
    # Keep the JSON small: one row per ~30 s.
    $step = [math]::Max(1, [int](30000 / $SampleMs))
    $kept = for ($i = 0; $i -lt $rows.Count; $i += $step) { $rows[$i] }
    return [ordered]@{
        label = $Label; minutes = $Span; verdict = $verdict
        private_mb_start = $rows[0].private_mb; private_mb_end = $rows[$rows.Count - 1].private_mb
        slope_mb_per_hour = $mbh; threads_created = $created; threads_created_per_hour = $tph
        predicted_driver_mb_per_hour = $pred; sources = $bySource; samples = @($kept)
    }
}

# Positive control: a child that starts one 3 s thread every 2 s must read as
# ~15 created threads over 30 s. Without it, "0 created" could mean a blind
# detector rather than a quiet app.
if ($SelfTest) {
    # -EncodedCommand: Start-Process does not quote -ArgumentList elements.
    # The threads are started from C#: a scriptblock run on a bare thread has no
    # runspace and takes the whole process down.
    $body = 'Add-Type -TypeDefinition ''public static class Spin { public static void Go() { new System.Threading.Thread(() => System.Threading.Thread.Sleep(3000)).Start(); } }''; for ($i = 0; $i -lt 40; $i++) { [Spin]::Go(); Start-Sleep -Seconds 2 }'
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($body))
    $child = Start-Process powershell.exe -PassThru -WindowStyle Hidden -ArgumentList @('-NoProfile', '-EncodedCommand', $enc)
    try {
        Start-Sleep -Seconds 3
        $script:appPid = $child.Id
        $script:modMap = Get-ModuleMap $child.Id
        $script:seen = @{}
        foreach ($th in (Get-Process -Id $child.Id).Threads) { $id = [IdleThreads]::Identity([uint32]$th.Id); if ($id) { $script:seen["$($th.Id):$($id[0])"] = $true } }
        $script:baselined = $true
        $s = Measure-Span 'selftest' 0.5
    } finally { Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue }
    if ($s.threads_created -ge 12) { Write-Host "SELFTEST PASS: $($s.threads_created) threads seen created (want >= 12 of ~15)"; exit 0 }
    Write-Host "SELFTEST FAIL: only $($s.threads_created) threads seen created (want >= 12 of ~15)"; exit 1
}

[void](Set-GhozttyTestIsolation -Tag 'idlegr' -ReleaseSandbox -Quiet)
$work = Join-Path $env:TEMP "ghoztty-idlegr-$PID"
New-Item -ItemType Directory -Force $work | Out-Null
$result = [ordered]@{
    schema = 'ghoztty-idle-thread-growth/1'; task = 'T2669'; generated = (Get-Date).ToString('o')
    exe = $exe; build = $Build
    version = ((& $cli +version 2>$null | Select-Object -First 1 | ForEach-Object { "$_" }) -join ' ').Trim()
    gpu = ((Get-CimInstance Win32_VideoController | ForEach-Object { "$($_.Name) $($_.DriverVersion)" }) -join '; ')
    method = "fresh app on the hidden test desktop, release-sandbox isolation, persistence off; Get-Process every $SampleMs ms: PrivateMemorySize64 and the thread list; a new (tid, create time) pair is a created thread (lower bound: threads shorter than one sample are missed), named by the module holding its Win32 start address; slope = least squares over each span after $SettleMinutes min"
    spans = @()
}
$failed = $false
[void](Stop-RepoGhoztty -Exe $exe -SettleMs 500 -ScopeToLineage)
Start-TestForegroundWatch
$td = New-TestDesktop
try {
    $err = Join-Path $work 'app.err'
    $app = Start-OnTestDesktop -Exe $exe -StdErr $err -AllowReleaseBuild:$isRelease -Arguments @('--config-default-files=false', '--confirm-close-surface=false', '--session-persistence=false')
    $script:appPid = $app.Pid
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow' -TimeoutMs 30000
    if ($top -eq [IntPtr]::Zero) { throw "the app window never appeared (stderr: $err)" }
    [void](Set-TestWindowPos -Window ([IntPtr]$top) -X 20 -Y 20 -Width 1400 -Height 900)
    Start-Sleep -Seconds 10
    $script:modMap = Get-ModuleMap $app.Pid
    $script:seen = @{}; $script:baselined = $false
    # Baseline pass: the threads alive now are startup's, not idle's.
    foreach ($th in (Get-Process -Id $app.Pid).Threads) {
        $id = [IdleThreads]::Identity([uint32]$th.Id)
        if ($id) { $script:seen["$($th.Id):$($id[0])"] = $true }
    }
    $script:baselined = $true
    $result.spans += , (Measure-Span 'terminal' $Minutes)

    if ($ViewerMinutes -gt 0) {
        $doc = Join-Path $work 'doc.md'
        [IO.File]::WriteAllText($doc, "# Idle viewer`n`n" + ((1..40 | ForEach-Object { "## Section $_`n`nParagraph $_ with **bold** and ``code``.`n" }) -join "`n"))
        # The first leaf pane: an object carrying both id and pid (perf-baseline's walk).
        $acc = New-Object System.Collections.ArrayList
        $walk = $null
        $walk = {
            param($o)
            if ($null -eq $o) { return }
            if ($o -is [System.Array]) { foreach ($x in $o) { & $walk $x }; return }
            if ($o -is [System.Management.Automation.PSCustomObject]) {
                $names = @($o.PSObject.Properties.Name)
                if (($names -contains 'id') -and ($names -contains 'pid')) { [void]$acc.Add($o) }
                foreach ($q in $o.PSObject.Properties) { & $walk $q.Value }
            }
        }
        & $walk ((@(& $cli '+list' '--json' 2>$null) -join "`n") | ConvertFrom-Json)
        if ($acc.Count -lt 1) { throw '+list --json named no pane to split the viewer from' }
        $anchor = $acc[0].id
        $o = @(& $cli '+split' "--target=$anchor" '--name=idlegrview' '--direction=right' "--view=$doc" 2>&1 | ForEach-Object { "$_" }) -join ' '
        if ($LASTEXITCODE -ne 0) { throw "+split of the viewer failed: $o" }
        # Let WebView2 come up, then baseline again so its startup threads are not idle's.
        Start-Sleep -Seconds 20
        $script:modMap = Get-ModuleMap $app.Pid
        foreach ($th in (Get-Process -Id $app.Pid).Threads) {
            $id = [IdleThreads]::Identity([uint32]$th.Id)
            if ($id) { $script:seen["$($th.Id):$($id[0])"] = $true }
        }
        $result.spans += , (Measure-Span 'viewer' $ViewerMinutes)
    }
} catch {
    $failed = $true
    $result.error = "$_"
    Write-Host "IDLE GROWTH ERROR: $_"
} finally {
    [void](Stop-RepoGhoztty -Exe $exe -SettleMs 500 -ScopeToLineage)
    Remove-TestDesktop
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
$fgSeen = @(Stop-TestForegroundWatch)
$leaked = @(Get-TestLaunchedPids | Where-Object { $fgSeen -contains $_ })
if ($leaked.Count) { $failed = $true; $result.foreground_leak = "test-desktop pids reached the interactive foreground: $($leaked -join ',')" }
$result | ConvertTo-Json -Depth 8 | Set-Content -Path $Out -Encoding ascii
Write-Host "IDLE GROWTH written: $Out$(if ($failed) { ' - WITH ERRORS' })"
exit $(if ($failed) { 1 } else { 0 })
