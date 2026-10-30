# @timing-sensitive
# T2473 acceptance: closing a window gives back everything the window held.
#
# WHY. Mac 1bc34a8d7 found every closed window kept its panes alive through a
# retain cycle - about 100 MB a window, unbounded, for six releases - and wrote
# the invariant down (docs/reference/memory.md on main, "A closed window frees
# every pane in it": renderer + IO threads, GPU render targets, the child
# process / agent session, and for a viewer its browser process). Windows has
# no ARC to get wrong in that way, but nothing here had ever MEASURED the
# invariant either, and a per-window leak is invisible to every other
# harness: they each open a window or two and quit.
#
# HOW. One app, one anchor window that stays open for the whole run (so the
# app is never at zero windows and nothing is measured across a quit). Each
# CYCLE opens a second window, splits it, adds a markdown viewer pane, lets it
# render, and closes the whole window with `+close`. Two warm-up cycles pay
# the one-time costs (font atlases, the WebView2 environment, shader
# compilation, allocator arenas), then a BASELINE is sampled, then -Cycles
# more, then the END sample. What is asserted is the per-cycle growth,
# (end - baseline) / cycles, against a budget that is a small fraction of what
# one open window actually costs - which this script also measures (the PEAK
# sample, taken with the cycle's window open), so a reader can see both the
# size of a window and how much of it a close left behind.
#
# What is sampled, per process:
#   * the app: private bytes, handle count, GDI and USER objects, threads,
#     GPU dedicated + shared memory (the "GPU Process Memory" counter set);
#   * every DESCENDANT of the app (pane shells, conhost/OpenConsole, the
#     WebView2 browser and its renderers): their count and their private
#     bytes, since a pane whose shell or viewer process outlived its window
#     leaks there and not in the app.
#
# Session persistence is OFF: an agent-backed pane's close is the agent's
# business (T2489 covers the agent side), and with it off the shell is the
# app's own child, so a retained ConPTY shows up as a descendant here.
#
# WHAT IT FOUND (2026-10-29, HEAD 9a289d01a): red on A1/A3 - every closed
# window keeps 4 GDI objects and ~4-8 MB, the desk's DC+DIB pairs that
# `Window.onDestroy` never frees (T2498) - and on A8 - a closed terminal pane
# keeps a window-sized GPU buffer, ~3 MB a window at the default size (T2499).
# The guard is acked to T2498 until both close.
#
# -NegativeControl leaves every measured window OPEN instead of closing it.
# The budget asserts MUST go red: it is the proof that this meter can see a
# retained window at all.
#
# -Report samples after every cycle, not only at the midpoint.
#
# -Shape narrows what a cycle builds, for bisecting a red run: `single` (one
# terminal), `split` (two terminals), `viewer` (a terminal and a viewer);
# `full`, the default and the verdict, is both splits. -AppArgs appends app
# flags (e.g. `--undo-timeout=0`), and -Resize resizes each cycle's window
# before closing it, and -CloseSplitFirst closes the terminal split on its
# own (and waits out its undo) before the window, for the same purpose.
#
# Only touches ghoztty processes running from this repo's zig-out*.
#   powershell -NoProfile -File test\win32\window-close-memory.ps1
param([string]$ExePath, [ValidateSet('full', 'single', 'split', 'viewer')][string]$Shape = 'full', [int]$Cycles = 10, [int]$Warmup = 2, [string[]]$AppArgs = @(), [switch]$Resize, [switch]$CloseSplitFirst, [switch]$NegativeControl, [switch]$Interactive, [switch]$Report)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }

$env:GHOZTTY_PIPE_SUFFIX = "-winclosemem$PID"
$errlog = Join-Path $env:TEMP "ghoztty-window-close-memory-$PID.log"
$tmp = Join-Path $env:TEMP "ghoztty-t2473-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$script:pass = 0
$script:fail = 0
$script:skipped = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

if (-not ('WcmDrv' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class WcmDrv {
    [DllImport("user32.dll")] public static extern uint GetGuiResources(IntPtr hProcess, uint uiFlags);
}
'@
}

# Every process whose parent chain reaches $RootPid (the root itself excluded).
function Get-Descendants([int]$RootPid) {
    $all = @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name, PrivatePageCount)
    $kids = @{}
    foreach ($p in $all) {
        $pp = [int]$p.ParentProcessId
        if (-not $kids.ContainsKey($pp)) { $kids[$pp] = New-Object System.Collections.ArrayList }
        [void]$kids[$pp].Add($p)
    }
    $out = New-Object System.Collections.ArrayList
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue($RootPid)
    while ($queue.Count -gt 0) {
        $cur = [int]$queue.Dequeue()
        if (-not $kids.ContainsKey($cur)) { continue }
        foreach ($c in $kids[$cur]) {
            # A recycled pid can name a process older than its "parent"; the
            # chain only ever walks down, and the app's own pid is never a child.
            if ([int]$c.ProcessId -eq $RootPid) { continue }
            [void]$out.Add($c)
            $queue.Enqueue([int]$c.ProcessId)
        }
    }
    return , $out.ToArray()
}

# GPU memory charged to one process, in bytes: the sum over every adapter
# instance of the "GPU Process Memory" set. $null when the counter set is not
# readable (no WDDM 2 driver, counters disabled) - the GPU asserts then SKIP.
function Get-GpuBytes([int]$ProcessId) {
    try {
        $s = Get-Counter -Counter @(
            "\GPU Process Memory(pid_${ProcessId}_*)\Dedicated Usage",
            "\GPU Process Memory(pid_${ProcessId}_*)\Shared Usage") -ErrorAction Stop
    } catch { return $null }
    $ded = 0.0; $sh = 0.0
    foreach ($c in $s.CounterSamples) {
        if ($c.Path -like '*dedicated usage') { $ded += $c.CookedValue } else { $sh += $c.CookedValue }
    }
    return [pscustomobject]@{ Dedicated = $ded; Shared = $sh }
}

function Get-Sample([int]$ProcessId, [string]$Label) {
    $p = Get-Process -Id $ProcessId -ErrorAction Stop
    $p.Refresh()
    $desc = Get-Descendants $ProcessId
    $descPriv = 0.0
    foreach ($d in $desc) { $descPriv += [double]$d.PrivatePageCount }
    $gpu = Get-GpuBytes $ProcessId
    return [pscustomobject]@{
        Label    = $Label
        PrivMB   = [math]::Round($p.PrivateMemorySize64 / 1MB, 1)
        Handles  = $p.HandleCount
        Gdi      = [int][WcmDrv]::GetGuiResources($p.Handle, 0)
        User     = [int][WcmDrv]::GetGuiResources($p.Handle, 1)
        Threads  = $p.Threads.Count
        GpuDedMB = $(if ($gpu) { [math]::Round($gpu.Dedicated / 1MB, 1) } else { $null })
        GpuShMB  = $(if ($gpu) { [math]::Round($gpu.Shared / 1MB, 1) } else { $null })
        Procs    = $desc.Count
        ProcMB   = [math]::Round($descPriv / 1MB, 1)
        ProcNames = (($desc | ForEach-Object { $_.Name } | Sort-Object) -join ',')
    }
}

# Hidden windows count: with `undo-timeout` (5s by default) a closed window is
# PARKED - hidden, every pane intact - until the undo expires, and only then
# torn down. A visible-only count reads a parked window as gone and samples
# memory the close has not been given the chance to free yet.
function Get-TopCount([int]$ProcessId) {
    return @(Get-TestWindows -ProcessId $ProcessId -Class 'GhozttyWindow' -AllowHidden).Count
}

function Wait-TopCount([int]$ProcessId, [int]$Want, [int]$TimeoutSec = 20) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        if ((Get-TopCount $ProcessId) -eq $Want) { return $true }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    return $false
}

# A viewer is "up" once a GhozttyViewer child of non-zero size exists under
# the named top window - the WebView2 controller is created for it by then.
function Wait-Viewer([int]$ProcessId, [int]$TimeoutSec = 20) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        foreach ($w in @(Get-TestWindows -ProcessId $ProcessId -Class 'GhozttyWindow')) {
            foreach ($h in @(Get-TestChildWindows -Window ([IntPtr][int64]$w.Hwnd) -Class 'GhozttyViewer')) {
                if ($h.Width -gt 0 -and $h.Height -gt 0) { return $true }
            }
        }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    return $false
}

# After a close: wait for the descendant count and the thread count to stop
# moving (pane shells exiting, renderer/IO threads joining, the WebView2
# renderer going away), bounded. Returns the settled sample.
function Wait-Settled([int]$ProcessId, [string]$Label, [int]$TimeoutSec = 30) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $prev = $null
    $stable = 0
    do {
        Start-Sleep -Milliseconds 1000
        $s = Get-Sample $ProcessId $Label
        if ($prev -and $s.Procs -eq $prev.Procs -and $s.Threads -eq $prev.Threads -and $s.Handles -eq $prev.Handles) {
            $stable++
            if ($stable -ge 2) { return $s }
        } else { $stable = 0 }
        $prev = $s
    } while ((Get-Date) -lt $deadline)
    return $prev
}

function Invoke-Verb([string[]]$VerbArgs) {
    $out = @(& $exe @VerbArgs 2>&1 | ForEach-Object { "$_" }) -join "`n"
    return [pscustomobject]@{ Code = $LASTEXITCODE; Text = $out.Trim() }
}

$doc = Join-Path $tmp 'doc.md'
$body = (1..40 | ForEach-Object { "## Section $_`n`nSome text under section $_, with a [link](https://example.invalid/$_).`n" }) -join "`n"
Set-Content -Path $doc -Value "# Memory probe`n`n$body" -Encoding utf8

# One cycle: a window with a terminal, a terminal split and a viewer split.
# Returns the PEAK sample (taken while the window is open) when asked.
function Invoke-Cycle([int]$ProcessId, [string]$Name, [bool]$Close, [bool]$SamplePeak) {
    $r = Invoke-Verb @('+new-window', "--target=$Name", "--name=${Name}a")
    if (-not (Wait-TopCount $ProcessId 2 -TimeoutSec 20) -and $Close) {
        throw "cycle ${Name}: the window did not open ($($r.Text))"
    }
    if ($Shape -eq 'full' -or $Shape -eq 'split') {
        $r = Invoke-Verb @('+split', "--target=${Name}a", "--name=${Name}b", '--direction=right')
        if ($r.Code -ne 0) { throw "cycle ${Name}: +split failed: $($r.Text)" }
    }
    if ($Shape -eq 'full' -or $Shape -eq 'viewer') {
        $r = Invoke-Verb @('+split', "--target=${Name}a", "--name=${Name}c", '--direction=down', "--view=$doc")
        if ($r.Code -ne 0) { throw "cycle ${Name}: +split --view failed: $($r.Text)" }
        if (-not (Wait-Viewer $ProcessId)) { throw "cycle ${Name}: the viewer pane never appeared" }
    }
    # Let both terminals start their shells and the viewer render its page, so
    # the window being closed is a window that was fully built.
    Start-Sleep -Milliseconds 2500
    if ($Resize) {
        foreach ($w in @(Get-TestWindows -ProcessId $ProcessId -Class 'GhozttyWindow')) {
            if ([int64]$w.Hwnd -eq [int64]$script:anchor) { continue }
            [void](Set-TestWindowPos -Window ([IntPtr][int64]$w.Hwnd) -X 80 -Y 80 -Width 700 -Height 500)
        }
        Start-Sleep -Milliseconds 1000
    }
    $peak = $null
    if ($SamplePeak) { $peak = Get-Sample $ProcessId "peak $Name" }
    if ($Close -and $CloseSplitFirst -and ($Shape -eq 'full' -or $Shape -eq 'split')) {
        [void](Invoke-Verb @('+close', "--target=${Name}b"))
        Start-Sleep -Milliseconds 7000
    }
    if ($Close) {
        $r = Invoke-Verb @('+close', "--target=$Name")
        if (-not (Wait-TopCount $ProcessId 1 -TimeoutSec 20)) { throw "cycle ${Name}: the window did not close ($($r.Text))" }
    }
    return $peak
}

[void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$app = $null
$samples = New-Object System.Collections.ArrayList

try {
    $launchArgs = @('--config-default-files=false', '--session-persistence=false', '--confirm-close-surface=false') + $AppArgs
    $app = Start-OnTestDesktop -Exe $exe -StdErr $errlog -Arguments $launchArgs
    $appPid = $app.Pid
    Assert (-not (Test-TestDesktopLeak -ProcessId $appPid)) 'GUI is NOT enumerable on the interactive desktop'
    $anchor = Wait-TestWindow -ProcessId $appPid -Class 'GhozttyWindow' -TimeoutMs 20000
    $script:anchor = $anchor
    Assert ($anchor -ne [IntPtr]::Zero) 'the anchor window appeared'
    if ($anchor -eq [IntPtr]::Zero) { throw 'no anchor window' }
    [void](Set-TestWindowPos -Window ([IntPtr]$anchor) -X 40 -Y 40 -Width 1000 -Height 700)
    Start-Sleep -Seconds 2

    $gpuReadable = $null -ne (Get-GpuBytes $appPid)
    Write-Host "GPU process-memory counters readable: $gpuReadable"

    # ---- warm-up: pay every one-time cost before the baseline ------------
    for ($i = 1; $i -le $Warmup; $i++) {
        [void](Invoke-Cycle $appPid "wcmw$i" $true $false)
    }
    $base = Wait-Settled $appPid 'baseline'
    [void]$samples.Add($base)

    # ---- measured cycles ---------------------------------------------------
    $peak = $null
    for ($i = 1; $i -le $Cycles; $i++) {
        $close = -not $NegativeControl
        $pk = Invoke-Cycle $appPid "wcm$i" $close ($i -eq 1)
        if ($pk) { $peak = $pk; [void]$samples.Add($pk) }
        if ($Report -or $i -eq [int]($Cycles / 2)) {
            [void]$samples.Add((Wait-Settled $appPid "after $i"))
        }
    }
    $end = Wait-Settled $appPid 'end'
    [void]$samples.Add($end)

    Write-Host ''
    $samples | Format-Table Label, PrivMB, Handles, Gdi, User, Threads, GpuDedMB, GpuShMB, Procs, ProcMB -AutoSize | Out-String -Width 200 | Write-Host
    Write-Host "baseline descendants: $($base.ProcNames)"
    Write-Host "end      descendants: $($end.ProcNames)"
    Write-Host ''

    # ---- what one open window costs (context for the budgets) ------------
    $winPriv = $peak.PrivMB - $base.PrivMB
    $winHandles = $peak.Handles - $base.Handles
    $winProcs = $peak.Procs - $base.Procs
    Write-Host ("one open window costs: +{0} MB private, +{1} handles, +{2} GDI, +{3} USER, +{4} threads, +{5} processes ({6} MB)" -f `
        $winPriv, $winHandles, ($peak.Gdi - $base.Gdi), ($peak.User - $base.User), ($peak.Threads - $base.Threads), $winProcs, ($peak.ProcMB - $base.ProcMB))
    if ($gpuReadable) {
        Write-Host ("                       +{0} MB GPU dedicated, +{1} MB GPU shared" -f ($peak.GpuDedMB - $base.GpuDedMB), ($peak.GpuShMB - $base.GpuShMB))
    }

    # ---- the verdict: per-cycle growth against a budget ------------------
    $n = [double]$Cycles
    $perPriv = ($end.PrivMB - $base.PrivMB) / $n
    $perHandles = ($end.Handles - $base.Handles) / $n
    $perGdi = ($end.Gdi - $base.Gdi) / $n
    $perUser = ($end.User - $base.User) / $n
    $perThreads = ($end.Threads - $base.Threads) / $n
    $perProcMB = ($end.ProcMB - $base.ProcMB) / $n
    Write-Host ("per closed window left behind: {0:N2} MB private, {1:N1} handles, {2:N1} GDI, {3:N1} USER, {4:N1} threads, {5} processes, {6:N2} MB in descendants" -f `
        $perPriv, $perHandles, $perGdi, $perUser, $perThreads, ($end.Procs - $base.Procs), $perProcMB)
    Write-Host ''

    # Budgets. A window here costs tens of MB and hundreds of handles; what a
    # close may leave behind is allocator slack, never a pane. 1 MB of private
    # bytes a window over ten cycles is 10 MB of drift - a leaked pane is many
    # times that on its own.
    Assert ($perPriv -le 1.0) ("A1 private bytes per closed window <= 1 MB (left {0:N2} MB a window)" -f $perPriv)
    Assert ($perHandles -le 5) ("A2 kernel handles per closed window <= 5 (left {0:N1})" -f $perHandles)
    Assert ($perGdi -le 1) ("A3 GDI objects per closed window <= 1 (left {0:N1})" -f $perGdi)
    Assert ($perUser -le 1) ("A4 USER objects per closed window <= 1 (left {0:N1})" -f $perUser)
    Assert ($perThreads -le 0.5) ("A5 threads per closed window <= 0.5 - every renderer/IO thread joined (left {0:N1})" -f $perThreads)
    Assert ($end.Procs -le $base.Procs) "A6 no child process outlives its window (descendants $($base.Procs) -> $($end.Procs))"
    Assert ($perProcMB -le 1.0) ("A7 descendant private bytes per closed window <= 1 MB (left {0:N2} MB)" -f $perProcMB)
    if ($gpuReadable) {
        $perGpu = (($end.GpuDedMB + $end.GpuShMB) - ($base.GpuDedMB + $base.GpuShMB)) / $n
        Assert ($perGpu -le 1.0) ("A8 GPU memory per closed window <= 1 MB - every swap chain released (left {0:N2} MB)" -f $perGpu)
    } else {
        $script:skipped++
        Write-Host 'SKIP  A8 GPU memory: the GPU Process Memory counters are not readable on this box'
    }

    $alive = Get-Process -Id $appPid -ErrorAction SilentlyContinue
    Assert ($null -ne $alive) 'B1 the app survived every open/close cycle'
    Assert (-not (Test-TestDesktopLeak -ProcessId $appPid)) 'B2 GUI never became visible on the interactive desktop'
}
finally {
    [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
    Remove-TestDesktop
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

$fgSeen = @(Stop-TestForegroundWatch)
$leaked = @(Get-TestLaunchedPids | Where-Object { $fgSeen -contains $_ })
Assert ($leaked.Count -eq 0) "no test-desktop app ever became foreground on the interactive desktop (saw $($leaked -join ','))"

# A green run stamps the covered files (T783). Only the verdict shape stamps:
# a bisect run (-Shape, -Resize, -CloseSplitFirst, -AppArgs) or a short one
# answers a narrower question than the guard asks.
$verdictShape = ($Shape -eq 'full' -and -not $Resize -and -not $CloseSplitFirst -and $AppArgs.Count -eq 0 -and $Cycles -ge 10)
if ($script:fail -eq 0 -and -not $NegativeControl -and $verdictShape) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard window-close-memory -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions$(if ($script:skipped) { ", $script:skipped SKIPPED" }))" -ForegroundColor Green }
else { Write-Host "$script:fail FAILURE(S) ($script:pass passed)" -ForegroundColor Red }
exit $(if ($script:fail -eq 0) { 0 } else { 1 })
