# T1813: run a test lane on a BACKGROUND desktop, so the windows its tests
# open can never reach the user's screen.
#
# Measured 2026-10-10 with a fullscreen game in front: one `floor-lane -Lane
# win32` run put 12 visible top-level windows (GhozttyBannerOverlay and two
# that were gone before their class could be read) on the input desktop, all
# owned by ghostty-test.exe. The banner tests show their owner with
# SW_SHOWNOACTIVATE, so they take no focus - but a window shown that way is
# still on the user's screen. Every turn runs that lane, and the idle soak
# daemon runs the same tests in ReleaseSafe, so this was the remaining route
# from automation to the user's screen (T1795's directive: never pull focus
# from the user).
#
# The fix is structural rather than per-test: the lane's ROOT process is
# created with STARTUPINFO.lpDesktop naming a desktop of our own, and a child
# created with a null lpDesktop inherits its parent's desktop - so zig, the
# build runner, every test binary and every window a test opens land there
# with no test having to know. That is the same mechanism lib\TestDesktop.ps1
# uses for the acceptance scripts; this is the headless half (no input
# simulation, no capture), so it carries none of that file's weight.
#
# Two functions:
#
#   Start-LaneProcess -CommandLine <cmd>   launch on the lane desktop; returns a
#                                          System.Diagnostics.Process with its
#                                          handle already cached (so ExitCode
#                                          survives the child's exit - the PS
#                                          5.1 trap) and .LaneDesktop set to
#                                          the desktop it landed on.
#   Get-LaneInputDesktopWindow -ProcessId  visible top-level windows those pids
#                                          own on the INPUT desktop (or on a
#                                          named desktop, for the harness).
#                                          Non-empty means a lane reached the
#                                          user's screen.
#
# If the desktop cannot be created, Start-LaneProcess FALLS BACK to the old
# hidden launch and says so loudly: a lane that cannot run at all costs more
# than one that runs where it always used to, and the sampled check below is
# still there to turn a window on the user's screen into a red lane.

if (-not ('GhozttyLaneDesktop' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

public class GhozttyLaneDesktop {
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr CreateDesktopW(string name, IntPtr dev, IntPtr devmode, int flags, uint access, IntPtr sa);
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr OpenDesktopW(string name, int flags, bool inherit, uint access);
    [DllImport("user32.dll", SetLastError = true)]
    static extern IntPtr OpenInputDesktop(int flags, bool inherit, uint access);
    [DllImport("user32.dll", SetLastError = true)]
    static extern bool CloseDesktop(IntPtr h);
    delegate bool EnumProc(IntPtr hwnd, IntPtr lp);
    [DllImport("user32.dll", SetLastError = true)]
    static extern bool EnumDesktopWindows(IntPtr desk, EnumProc fn, IntPtr lp);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int GetClassNameW(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool GetUserObjectInformationW(IntPtr h, int index, StringBuilder sb, int len, out int needed);
    [DllImport("user32.dll")] static extern IntPtr GetThreadDesktop(uint threadId);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct STARTUPINFO {
        public int cb; public string lpReserved; public string lpDesktop; public string lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CreateProcessW(string app, StringBuilder cmd, IntPtr pa, IntPtr ta, bool inherit,
        uint flags, IntPtr env, string cwd, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
    [DllImport("kernel32.dll")] static extern uint ResumeThread(IntPtr h);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll")] static extern bool TerminateProcess(IntPtr h, uint code);

    const uint GENERIC_ALL = 0x10000000;
    const uint DESKTOP_READOBJECTS = 0x0001;
    const uint DESKTOP_ENUMERATE = 0x0040;
    const uint CREATE_SUSPENDED = 0x00000004;
    const uint CREATE_NO_WINDOW = 0x08000000;
    const int UOI_NAME = 2;

    // One handle per name, held for the life of the process that made it. A
    // desktop is destroyed when its last handle closes AND nothing runs on it;
    // holding ours means a soak daemon that launches round after round reuses
    // one desktop rather than minting a new one per round.
    static readonly Dictionary<string, IntPtr> held = new Dictionary<string, IntPtr>();
    public static string LastError;

    public static bool Ensure(string name) {
        lock (held) {
            if (held.ContainsKey(name)) return true;
            IntPtr h = CreateDesktopW(name, IntPtr.Zero, IntPtr.Zero, 0, GENERIC_ALL, IntPtr.Zero);
            if (h == IntPtr.Zero) { LastError = "CreateDesktopW failed: " + Marshal.GetLastWin32Error(); return false; }
            held[name] = h;
            return true;
        }
    }

    // Created SUSPENDED and adopted before it runs: Process.GetProcessById on
    // a child that has already exited throws, and a lane command can fail in
    // milliseconds (a bad flag). Suspended, it cannot exit before the Process
    // object holds its handle - after which ExitCode is readable forever.
    public static Process Start(string commandLine, string cwd, string desktop) {
        if (!Ensure(desktop)) return null;
        STARTUPINFO si = new STARTUPINFO();
        si.cb = Marshal.SizeOf(typeof(STARTUPINFO));
        si.lpDesktop = "WinSta0\\" + desktop;
        PROCESS_INFORMATION pi;
        StringBuilder cmd = new StringBuilder(commandLine);
        if (!CreateProcessW(null, cmd, IntPtr.Zero, IntPtr.Zero, false,
                CREATE_SUSPENDED | CREATE_NO_WINDOW, IntPtr.Zero,
                String.IsNullOrEmpty(cwd) ? null : cwd, ref si, out pi)) {
            LastError = "CreateProcessW failed: " + Marshal.GetLastWin32Error();
            return null;
        }
        Process p = null;
        try {
            p = Process.GetProcessById(pi.dwProcessId);
            IntPtr unused = p.Handle;
        } catch (Exception e) {
            LastError = "adopt failed: " + e.Message;
            TerminateProcess(pi.hProcess, 1);
            CloseHandle(pi.hThread); CloseHandle(pi.hProcess);
            return null;
        }
        ResumeThread(pi.hThread);
        CloseHandle(pi.hThread); CloseHandle(pi.hProcess);
        return p;
    }

    // The desktop the CALLING thread is on - which, for a process started by
    // Start above, is the lane desktop. The harness asks a lane command to
    // print this, so "where did the lane run" is measured from inside it.
    public static string CurrentDesktopName() {
        IntPtr h = GetThreadDesktop(GetCurrentThreadId());
        if (h == IntPtr.Zero) return "";
        StringBuilder sb = new StringBuilder(256);
        int needed;
        if (!GetUserObjectInformationW(h, UOI_NAME, sb, sb.Capacity * 2, out needed)) return "";
        return sb.ToString();
    }

    // Visible top-level windows owned by any of the pids on a desktop: the
    // input desktop when desktopName is null/empty, else the named one (the
    // harness plants a window on a desktop of its own, so the detector can be
    // proven without putting anything on the user's screen).
    public static string[] VisibleWindows(int[] pids, string desktopName) {
        IntPtr desk = String.IsNullOrEmpty(desktopName)
            ? OpenInputDesktop(0, false, DESKTOP_READOBJECTS | DESKTOP_ENUMERATE)
            : OpenDesktopW(desktopName, 0, false, DESKTOP_READOBJECTS | DESKTOP_ENUMERATE);
        if (desk == IntPtr.Zero) {
            LastError = "open desktop failed: " + Marshal.GetLastWin32Error();
            return null;
        }
        HashSet<uint> want = new HashSet<uint>();
        foreach (int p in pids) want.Add((uint)p);
        List<string> found = new List<string>();
        try {
            EnumDesktopWindows(desk, delegate(IntPtr hwnd, IntPtr lp) {
                if (!IsWindowVisible(hwnd)) return true;
                uint pid;
                GetWindowThreadProcessId(hwnd, out pid);
                if (!want.Contains(pid)) return true;
                StringBuilder cls = new StringBuilder(256);
                GetClassNameW(hwnd, cls, cls.Capacity);
                found.Add(String.Format("hwnd=0x{0:X} pid={1} class={2}", hwnd.ToInt64(), pid, cls));
                return true;
            }, IntPtr.Zero);
        } finally { CloseDesktop(desk); }
        return found.ToArray();
    }
}
'@
}

# One desktop for every lane this user runs. A fixed name rather than a
# per-run one: lanes run one at a time (T401), and a stable name is what a
# person debugging a lane can find again.
$script:LaneDesktopName = 'GhozttyLaneDesktop'

function Start-LaneProcess {
    param(
        [Parameter(Mandatory)][string]$CommandLine,
        [string]$WorkingDirectory,
        [string]$DesktopName = $script:LaneDesktopName
    )
    $p = [GhozttyLaneDesktop]::Start($CommandLine, $WorkingDirectory, $DesktopName)
    if ($p) {
        $p | Add-Member -NotePropertyName LaneDesktop -NotePropertyValue $DesktopName -Force
        return $p
    }
    # The fallback is LOUD and it is the old behavior exactly: a hidden window
    # on the input desktop. The sampled window check still runs over it.
    Write-Host "  LANE DESKTOP UNAVAILABLE ($([GhozttyLaneDesktop]::LastError)) - running on the input desktop; test windows may reach the user's screen"
    $exe, $rest = Split-LaneCommandLine $CommandLine
    $sp = @{ FilePath = $exe; PassThru = $true; WindowStyle = 'Hidden' }
    if ($rest) { $sp.ArgumentList = $rest }
    if ($WorkingDirectory) { $sp.WorkingDirectory = $WorkingDirectory }
    $p = Start-Process @sp
    $null = $p.Handle
    $p | Add-Member -NotePropertyName LaneDesktop -NotePropertyValue '' -Force
    return $p
}

# "exe" rest  ->  exe, rest. Only for the fallback, which hands Start-Process
# the remainder as ONE string (it does not quote array elements - T200).
function Split-LaneCommandLine([string]$CommandLine) {
    $s = $CommandLine.Trim()
    if ($s.StartsWith('"')) {
        $end = $s.IndexOf('"', 1)
        return @($s.Substring(1, $end - 1), $s.Substring($end + 1).Trim())
    }
    $sp = $s.IndexOf(' ')
    if ($sp -lt 0) { return @($s, '') }
    return @($s.Substring(0, $sp), $s.Substring($sp + 1).Trim())
}

# Visible top-level windows the given pids own on the input desktop (or on
# -DesktopName), as an object rather than a bare array: an empty array unrolls
# to $null on the way out of a function (PS 5.1), and "could not look" - a
# locked workstation answers ACCESS_DENIED for the input desktop - must not
# read as "nothing there". .Looked false = could not look; .Windows = lines.
function Get-LaneInputDesktopWindow {
    param([int[]]$ProcessId, [string]$DesktopName)
    if (-not $ProcessId -or $ProcessId.Count -eq 0) {
        return [pscustomobject]@{ Looked = $true; Windows = [string[]]@(); Error = '' }
    }
    $r = [GhozttyLaneDesktop]::VisibleWindows([int[]]$ProcessId, $DesktopName)
    if ($null -eq $r) {
        return [pscustomobject]@{ Looked = $false; Windows = [string[]]@(); Error = [GhozttyLaneDesktop]::LastError }
    }
    return [pscustomobject]@{ Looked = $true; Windows = [string[]]$r; Error = '' }
}
