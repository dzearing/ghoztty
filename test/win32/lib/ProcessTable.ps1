# T2024: the process table WITHOUT WMI, for acceptance scripts and their libs.
#
# THE DEFECT THIS CLOSES. `Get-CimInstance Win32_Process` is answered by the
# CIMWin32 provider host, another process, and an unbounded call waits as long as
# that host does. On 2026-10-16 the host stalled from about 11:17 to 11:41: every
# acceptance script running at the time sat in its own query, groups of finished
# scripts were scored together 50-90 s after their last line, and
# session-relaunch-notify's process-count assertion wrote its last line two
# seconds after the replacement host came up. A lookup that comes back late, or
# empty, reads as a product failure.
#
# THE RULE. Ask the kernel instead: one Toolhelp32 snapshot for pid / parent /
# image name, then per process OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION) +
# QueryFullProcessImageName + GetProcessTimes. Every one of those is a syscall
# against this process's own handle table; none of them can wait on the health
# of another process. Same rule the runner took in T2010
# (scripts\lib\AcceptanceParallel.ps1, ApProc / ApTree).
#
# `Get-OsProcess` hands back rows shaped like the Win32_Process fields the suite
# reads - ProcessId, ParentProcessId, Name, ExecutablePath, CreationDate - so a
# conversion is a one-word change at the call site. A process that cannot be
# opened (protected, or gone between the snapshot and the open) keeps its row
# with ExecutablePath and CreationDate $null, which is what WMI reports for it too.
#
# What it does NOT carry: CommandLine and the memory counters. A call site that
# needs those stays on WMI, BOUNDED, through `Get-BoundedCimProcess`, which
# throws 'WMI did not answer' rather than returning an empty list a script would
# score as "nothing is running". `test\win32\wmi-bound-audit.ps1` keeps an
# unbounded call from coming back into this directory.

if (-not ('GzProcTable' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class GzProcTable {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct PROCESSENTRY32W {
        public uint dwSize; public uint cntUsage; public uint th32ProcessID; public IntPtr th32DefaultHeapID;
        public uint th32ModuleID; public uint cntThreads; public uint th32ParentProcessID; public int pcPriClassBase;
        public uint dwFlags; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szExeFile;
    }
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint pid);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool Process32FirstW(IntPtr snap, ref PROCESSENTRY32W e);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool Process32NextW(IntPtr snap, ref PROCESSENTRY32W e);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool QueryFullProcessImageNameW(IntPtr h, int flags, StringBuilder name, ref int size);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetProcessTimes(IntPtr h, out long creation, out long exit, out long kernel, out long user);
    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr h);
    // ProcessCommandLineInformation (60): the target's command line as a
    // UNICODE_STRING header followed by its characters. Needs only
    // PROCESS_QUERY_LIMITED_INFORMATION (Windows 8.1+), so it reads the same set
    // of processes the image path does.
    [DllImport("ntdll.dll")]
    static extern int NtQueryInformationProcess(IntPtr h, int infoClass, IntPtr buf, int len, out int retLen);

    public class Row {
        public int Pid; public int ParentPid; public string Name;
        public string Path; public long CreatedFileTime; public string CommandLine;
    }

    static string ReadCommandLine(IntPtr h) {
        int len = 0;
        NtQueryInformationProcess(h, 60, IntPtr.Zero, 0, out len);
        if (len <= 0 || len > (1 << 20)) return null;
        IntPtr buf = Marshal.AllocHGlobal(len);
        try {
            int got;
            if (NtQueryInformationProcess(h, 60, buf, len, out got) != 0) return null;
            int bytes = (ushort)Marshal.ReadInt16(buf);          // UNICODE_STRING.Length
            IntPtr chars = Marshal.ReadIntPtr(buf, IntPtr.Size);  // .Buffer (after Length/MaximumLength + padding)
            if (bytes == 0 || chars == IntPtr.Zero) return "";
            return Marshal.PtrToStringUni(chars, bytes / 2);
        } finally { Marshal.FreeHGlobal(buf); }
    }

    // Every process alive at one snapshot. A non-empty nameFilter (image names,
    // e.g. "ghoztty.exe", any case) keeps only those, and skips the per-process
    // open for everything else - the common shape is "find my two images".
    // withCommandLine adds the command line, read from the same handle.
    public static List<Row> Snapshot(string[] nameFilter) { return Snapshot(nameFilter, false); }
    public static List<Row> Snapshot(string[] nameFilter, bool withCommandLine) {
        HashSet<string> want = null;
        if (nameFilter != null && nameFilter.Length > 0) {
            want = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (string n in nameFilter) if (!String.IsNullOrEmpty(n)) want.Add(n);
        }
        List<Row> rows = new List<Row>();
        IntPtr snap = CreateToolhelp32Snapshot(0x2, 0);  // TH32CS_SNAPPROCESS
        if (snap == IntPtr.Zero || snap == new IntPtr(-1))
            throw new InvalidOperationException("CreateToolhelp32Snapshot failed: " + Marshal.GetLastWin32Error());
        try {
            PROCESSENTRY32W e = new PROCESSENTRY32W();
            e.dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32W));
            if (!Process32FirstW(snap, ref e)) return rows;
            do {
                if (want != null && !want.Contains(e.szExeFile)) continue;
                Row r = new Row();
                r.Pid = (int)e.th32ProcessID;
                r.ParentPid = (int)e.th32ParentProcessID;
                r.Name = e.szExeFile;
                Fill(r, withCommandLine);
                rows.Add(r);
            } while (Process32NextW(snap, ref e));
        } finally { CloseHandle(snap); }
        return rows;
    }

    static void Fill(Row r, bool withCommandLine) {
        if (r.Pid <= 4) return;  // Idle / System: no image path to read
        IntPtr h = OpenProcess(0x1000, false, r.Pid);  // PROCESS_QUERY_LIMITED_INFORMATION
        if (h == IntPtr.Zero) return;
        try {
            StringBuilder sb = new StringBuilder(1024);
            int size = sb.Capacity;
            if (QueryFullProcessImageNameW(h, 0, sb, ref size)) r.Path = sb.ToString(0, size);
            long c, x, k, u;
            if (GetProcessTimes(h, out c, out x, out k, out u) && c > 0) r.CreatedFileTime = c;
            if (withCommandLine) r.CommandLine = ReadCommandLine(h);
        } finally { CloseHandle(h); }
    }
}
'@
}

function Get-OsProcess {
    <#
    .SYNOPSIS
    The live process table from the kernel, never WMI (T2024).

    .DESCRIPTION
    One row per process: ProcessId, ParentProcessId, Name, ExecutablePath,
    CreationDate (local [datetime], or $null when the process could not be
    opened). -Name keeps only those image names ('ghoztty.exe'; matched without
    regard to case, the way Win32_Process's Name filter matches). -CommandLine
    fills a CommandLine field too (left out by default: it is one more read per
    process, and most callers want only paths).

    The result UNROLLS (every call site wraps it in `@(...)`), so an empty table
    counts as zero rather than as one phantom row.
    #>
    param([string[]]$Name, [switch]$CommandLine)
    foreach ($r in [GzProcTable]::Snapshot($Name, [bool]$CommandLine)) {
        $created = $null
        if ($r.CreatedFileTime -gt 0) { $created = [datetime]::FromFileTime($r.CreatedFileTime) }
        $row = [ordered]@{
            ProcessId       = $r.Pid
            ParentProcessId = $r.ParentPid
            Name            = $r.Name
            ExecutablePath  = $r.Path
            CreationDate    = $created
        }
        if ($CommandLine) { $row.CommandLine = $r.CommandLine }
        [pscustomobject]$row
    }
}

# How long a bounded WMI query may wait before it is reported as unanswered.
# The 2026-10-16 stall lasted 24 minutes; a healthy Win32_Process query on this
# box answers in well under a second, so 20 s is generous to a loaded box and
# still short enough that a stall is named inside one script's budget.
$script:BoundedCimTimeoutSec = 20

function Get-BoundedCimProcess {
    <#
    .SYNOPSIS
    `Get-CimInstance Win32_Process`, bounded, for the fields the kernel table
    does not carry (CommandLine, PrivatePageCount, ...).

    .DESCRIPTION
    Throws "WMI did not answer within <n>s ..." when the provider host does not
    answer, instead of handing back an empty or partial list that the caller
    would score as a product state. Callers that can live without the data
    catch it and SAY so in their verdict; the rest let it fail the run, which is
    the honest answer.
    #>
    param(
        [string]$Filter,
        [string[]]$Property,
        [int]$TimeoutSec = $script:BoundedCimTimeoutSec
    )
    $cim = @{ ClassName = 'Win32_Process'; OperationTimeoutSec = $TimeoutSec; ErrorAction = 'Stop' }
    if ($Filter) { $cim.Filter = $Filter }
    if ($Property) { $cim.Property = $Property }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        Get-CimInstance @cim
    } catch {
        throw "WMI did not answer within ${TimeoutSec}s (Win32_Process$(if ($Filter) { " where $Filter" }); $([int]$sw.Elapsed.TotalSeconds)s elapsed): $($_.Exception.Message)"
    }
}
