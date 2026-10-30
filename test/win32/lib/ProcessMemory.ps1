# What one ghoztty process is holding right now, for the leak meters
# (T2473 window-close-memory.ps1, T2494 pane-close-memory.ps1).
#
# Get-Sample reads, for the app process: private bytes, kernel handles, GDI
# and USER objects, threads, and GPU dedicated + shared memory (the "GPU
# Process Memory" counter set); and for every DESCENDANT of it (pane shells,
# conhost/OpenConsole, the WebView2 browser and its renderers) their count and
# private bytes - a pane whose shell or viewer process outlived it leaks there
# and not in the app. Both meters share this so they cannot measure two
# different things under one name.
#
# Dot-source it; it defines functions and one Add-Type, nothing else.

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
