# UserPresence (T1794) - is a person using this box right now?
#
# THE DEFECT THIS EXISTS FOR. The declared input-desktop exceptions in
# lib\TestDesktop.ps1 (translucent-window, background-blur, rdp-session, ...)
# can only run on the user's real screen. `Assert-TestDesktopCapability
# -Interactive` asked whether that screen COULD be used and never whether
# somebody WAS using it. On 2026-09-27 two of them ran over the user's
# fullscreen game: their windows drew on top of it, took its keystrokes, and
# the captures measured the game instead of the terminal. A run that disrupts
# the user and measures the wrong thing is worse than no run.
#
# So before anything is started on the input desktop, a script asks this
# predicate, and when somebody is present it SKIPS with the reason named. It
# never waits for the user to leave and never fails: the user being at their
# own machine is not a defect.
#
# THE SIGNALS (any one means present):
#
#   recent input     GetLastInputInfo: keyboard or mouse input within the last
#                    GHOZTTY_TEST_PRESENCE_IDLE_SECONDS (default 300). It does
#                    NOT see a gamepad, which is why the next two exist.
#   busy shell state SHQueryUserNotificationState - the shell's own "do not
#                    disturb this user" answer: a fullscreen app (BUSY), an
#                    exclusive Direct3D game (RUNNING_D3D_FULL_SCREEN),
#                    presentation mode, or a fullscreen store app (APP).
#   fullscreen fg    The foreground window covers its whole monitor and is not
#                    the desktop shell. A borderless-windowed game reports none
#                    of the shell states above, and this catches it.
#
# A foreground window owned by a process from THIS repo (a zig-out test build
# left maximized by an earlier script) is not a person, so it does not count
# for the two fullscreen signals. Exclusive D3D and presentation mode still do.
#
# THE DEMONSTRATION THAT IT CAN FIRE, AND THE CONTROL THAT IT DOES NOT ALWAYS.
# `GHOZTTY_TEST_FORCE_USER_PRESENCE=present|absent` overrides the probe.
# `present` drives the skip path without needing a person or a fullscreen
# window; `absent` is the negative control that shows the gate is not a blanket
# skip. test-desktop-harness.ps1's presence section is the only thing that
# may set it. `Resolve-UserPresence` is the pure decision, so every signal is
# exercised against constructed inputs there too, without touching the screen.
#
# Deliberately sets no StrictMode: dot-sourced INTO suite scripts.

if (-not ('GhozttyUserPresence' -as [type])) {
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public class GhozttyUserPresence {
    [StructLayout(LayoutKind.Sequential)]
    struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)]
    struct MONITORINFO { public uint cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags; }

    [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO lii);
    [DllImport("kernel32.dll")] static extern uint GetTickCount();
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr h, uint flags);
    [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr m, ref MONITORINFO mi);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder sb, int max);
    [DllImport("shell32.dll")] static extern int SHQueryUserNotificationState(out int state);

    // Milliseconds since the last keyboard/mouse input in this session.
    // Unsigned subtraction, so the 49.7-day tick wrap reads correctly.
    public static long IdleMs() {
        LASTINPUTINFO lii = new LASTINPUTINFO();
        lii.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
        if (!GetLastInputInfo(ref lii)) return -1;
        return (long)unchecked(GetTickCount() - lii.dwTime);
    }

    // QUERY_USER_NOTIFICATION_STATE, or 0 when the call fails.
    public static int NotificationState() {
        int s;
        return SHQueryUserNotificationState(out s) == 0 ? s : 0;
    }

    public static IntPtr Foreground() { return GetForegroundWindow(); }

    public static uint WindowPid(IntPtr h) { uint pid; GetWindowThreadProcessId(h, out pid); return pid; }

    public static string WindowClass(IntPtr h) {
        StringBuilder sb = new StringBuilder(256);
        GetClassName(h, sb, sb.Capacity);
        return sb.ToString();
    }

    // Does the window cover the whole of the monitor it is on?
    public static bool CoversMonitor(IntPtr h) {
        RECT r;
        if (h == IntPtr.Zero || !GetWindowRect(h, out r)) return false;
        IntPtr mon = MonitorFromWindow(h, 2 /* MONITOR_DEFAULTTONEAREST */);
        MONITORINFO mi = new MONITORINFO();
        mi.cbSize = (uint)Marshal.SizeOf(typeof(MONITORINFO));
        if (mon == IntPtr.Zero || !GetMonitorInfo(mon, ref mi)) return false;
        return r.Left <= mi.rcMonitor.Left && r.Top <= mi.rcMonitor.Top &&
               r.Right >= mi.rcMonitor.Right && r.Bottom >= mi.rcMonitor.Bottom;
    }
}
'@
}

# Window classes that cover a monitor without being an app in use: the
# desktop itself and the taskbar.
$script:GhozttyPresenceShellClasses = @('Progman', 'WorkerW', 'Shell_TrayWnd', 'Shell_SecondaryTrayWnd')

function Get-UserPresenceIdleThreshold {
    $raw = $env:GHOZTTY_TEST_PRESENCE_IDLE_SECONDS
    $n = 0
    if ($raw -and [int]::TryParse($raw, [ref]$n) -and $n -ge 0) { return $n }
    return 300
}

<#
The pure decision. Every input is a plain value, so the harness can construct
each case without a person, a game, or a window.

  -IdleSeconds        seconds since the last input (negative = unknown)
  -IdleThreshold      input newer than this many seconds means present
  -NotificationState  SHQueryUserNotificationState value (0 = unknown)
  -ForegroundFullscreen  the foreground window covers its monitor and is not the shell
  -ForegroundOurs     the foreground window belongs to a process from this repo

Returns { Present, Reason }.
#>
function Resolve-UserPresence {
    param(
        [double]$IdleSeconds = -1,
        [int]$IdleThreshold = 300,
        [int]$NotificationState = 0,
        [bool]$ForegroundFullscreen = $false,
        [bool]$ForegroundOurs = $false,
        [string]$ForegroundDescription = ''
    )
    $mk = { param($p, $r) [pscustomobject]@{ Present = $p; Reason = $r } }

    # Exclusive D3D and presentation mode are about the session, not one
    # window, so they count even when our own window is in front.
    switch ($NotificationState) {
        3 { return & $mk $true 'a fullscreen Direct3D app (a game) owns the display' }
        4 { return & $mk $true 'the box is in presentation mode' }
    }
    if (-not $ForegroundOurs) {
        switch ($NotificationState) {
            2 { return & $mk $true 'the shell reports a fullscreen app in use' }
            7 { return & $mk $true 'the shell reports a fullscreen store app in use' }
        }
        if ($ForegroundFullscreen) {
            $what = if ($ForegroundDescription) { " ($ForegroundDescription)" } else { '' }
            return & $mk $true "the foreground window covers its whole monitor$what"
        }
    }
    if ($IdleSeconds -ge 0 -and $IdleSeconds -lt $IdleThreshold) {
        return & $mk $true ("keyboard/mouse input {0:N0}s ago (threshold {1}s)" -f $IdleSeconds, $IdleThreshold)
    }
    $idleText = if ($IdleSeconds -ge 0) { '{0:N0}s' -f $IdleSeconds } else { 'unknown' }
    return & $mk $false "no recent input (idle $idleText), no fullscreen app in the foreground"
}

# The repo root, so a test build in the foreground is recognised as ours.
$script:GhozttyPresenceRepo = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent

<#
Probe the box and decide. Honours GHOZTTY_TEST_FORCE_USER_PRESENCE.
Returns { Present, Reason, Forced }.
#>
function Get-UserPresence {
    $forced = $env:GHOZTTY_TEST_FORCE_USER_PRESENCE
    if ($forced -eq 'present') {
        return [pscustomobject]@{ Present = $true; Reason = 'forced present by GHOZTTY_TEST_FORCE_USER_PRESENCE'; Forced = $true }
    }
    if ($forced -eq 'absent') {
        return [pscustomobject]@{ Present = $false; Reason = 'forced absent by GHOZTTY_TEST_FORCE_USER_PRESENCE'; Forced = $true }
    }

    $idleMs = [GhozttyUserPresence]::IdleMs()
    $idle = if ($idleMs -ge 0) { $idleMs / 1000.0 } else { -1 }
    $quns = [GhozttyUserPresence]::NotificationState()

    $fg = [GhozttyUserPresence]::Foreground()
    $full = $false; $ours = $false; $desc = ''
    if ($fg -ne [IntPtr]::Zero) {
        $cls = [GhozttyUserPresence]::WindowClass($fg)
        $fgPid = [GhozttyUserPresence]::WindowPid($fg)
        $path = $null; $name = ''
        try {
            $proc = Get-Process -Id $fgPid -ErrorAction Stop
            $name = $proc.ProcessName
            $path = $proc.Path
        } catch { }
        if ($path -and $script:GhozttyPresenceRepo -and
            $path.StartsWith($script:GhozttyPresenceRepo, [StringComparison]::OrdinalIgnoreCase)) {
            $ours = $true
        }
        if ($script:GhozttyPresenceShellClasses -notcontains $cls) {
            $full = [GhozttyUserPresence]::CoversMonitor($fg)
        }
        $desc = "$name, class $cls"
    }

    $r = Resolve-UserPresence -IdleSeconds $idle -IdleThreshold (Get-UserPresenceIdleThreshold) `
        -NotificationState $quns -ForegroundFullscreen $full -ForegroundOurs $ours -ForegroundDescription $desc
    return [pscustomobject]@{ Present = $r.Present; Reason = $r.Reason; Forced = $false }
}

<#
The gate. Call it before ANYTHING is started on the input desktop. Silent
when nobody is present; otherwise prints the suite's SKIP ALL shape (scored
as a skip by scripts\suite-run.ps1) and exits 0.
#>
function Assert-UserAbsent {
    $p = Get-UserPresence
    if ($p.Present) {
        Write-Host "SKIP ALL: user-absent is not available here - somebody is using this box: $($p.Reason). Input-desktop tests never run over the user."
        exit 0
    }
}
