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

# T2500: which KINDS of kernel handle a process holds, so a handle-count leak
# names its type (Event, Thread, Section, File, ...) instead of a bare number.
# One SystemExtendedHandleInformation snapshot, filtered by pid; type names
# from ObjectTypesInformation. Nothing is opened or duplicated.
if (-not ('WcmHandles' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class WcmHandles {
    [DllImport("ntdll.dll")] static extern int NtQuerySystemInformation(int cls, IntPtr buf, int len, out int ret);
    [DllImport("ntdll.dll")] static extern int NtQueryObject(IntPtr h, int cls, IntPtr buf, int len, out int ret);
    static Dictionary<int, string> names;
    static IntPtr Query(Func<IntPtr, int, int> call) {
        int len = 1 << 20;
        for (int tries = 0; tries < 8; tries++) {
            IntPtr buf = Marshal.AllocHGlobal(len);
            int st = call(buf, len);
            if (st == 0) return buf;
            Marshal.FreeHGlobal(buf);
            if ((uint)st != 0xC0000004u) return IntPtr.Zero; // not LENGTH_MISMATCH
            len *= 2;
        }
        return IntPtr.Zero;
    }
    static Dictionary<int, string> TypeNames() {
        if (names != null) return names;
        var d = new Dictionary<int, string>();
        int ret = 0;
        IntPtr buf = Query((b, l) => NtQueryObject(IntPtr.Zero, 3, b, l, out ret));
        if (buf == IntPtr.Zero) return d;
        try {
            int n = Marshal.ReadInt32(buf);
            long p = buf.ToInt64() + IntPtr.Size;
            for (int i = 0; i < n; i++) {
                ushort slen = (ushort)Marshal.ReadInt16(new IntPtr(p));
                ushort smax = (ushort)Marshal.ReadInt16(new IntPtr(p + 2));
                IntPtr sbuf = Marshal.ReadIntPtr(new IntPtr(p + 8));
                int idx = Marshal.ReadByte(new IntPtr(p + 0x5a));
                d[idx] = Marshal.PtrToStringUni(sbuf, slen / 2);
                p += 0x68 + smax;
                p = (p + IntPtr.Size - 1) & ~((long)IntPtr.Size - 1);
            }
        } finally { Marshal.FreeHGlobal(buf); }
        names = d;
        return d;
    }
    public static Dictionary<string, int> Census(int pid) {
        var counts = new Dictionary<string, int>();
        var tn = TypeNames();
        int ret = 0;
        IntPtr buf = Query((b, l) => NtQuerySystemInformation(64, b, l, out ret));
        if (buf == IntPtr.Zero) return counts;
        try {
            long n = Marshal.ReadIntPtr(buf).ToInt64();
            long p = buf.ToInt64() + 2 * IntPtr.Size;
            int stride = 3 * IntPtr.Size + 16;
            for (long i = 0; i < n; i++, p += stride) {
                long owner = Marshal.ReadIntPtr(new IntPtr(p + IntPtr.Size)).ToInt64();
                if (owner != pid) continue;
                int ti = (ushort)Marshal.ReadInt16(new IntPtr(p + 3 * IntPtr.Size + 6));
                string name;
                if (!tn.TryGetValue(ti, out name)) name = "type" + ti;
                int c;
                counts.TryGetValue(name, out c);
                counts[name] = c + 1;
            }
        } finally { Marshal.FreeHGlobal(buf); }
        return counts;
    }
}
'@
}

# Handle counts by type for one process, as a hashtable name -> count.
function Get-HandleTypes([int]$ProcessId) {
    $h = @{}
    foreach ($kv in [WcmHandles]::Census($ProcessId).GetEnumerator()) { $h[$kv.Key] = $kv.Value }
    return $h
}

# "Event +12, Thread -1" - only the types whose count moved, biggest first.
function Format-HandleDelta([hashtable]$Before, [hashtable]$After) {
    $keys = @($Before.Keys) + @($After.Keys) | Sort-Object -Unique
    $rows = foreach ($k in $keys) {
        $d = [int]$After[$k] - [int]$Before[$k]
        if ($d -ne 0) { [pscustomobject]@{ Name = $k; Delta = $d } }
    }
    $parts = @($rows | Sort-Object { -[math]::Abs($_.Delta) } | ForEach-Object { '{0} {1:+0;-0}' -f $_.Name, $_.Delta })
    if ($parts.Count -eq 0) { return '(no change)' }
    return $parts -join ', '
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
