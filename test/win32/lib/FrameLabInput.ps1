# FrameLabInput (T2384) - drive the pointer along a scripted path at 1 kHz,
# every point stamped on QPC. The input half of the T2373 frame lab.
#
# THE GAP THIS EXISTS FOR. FrameCapture.ps1 (T2382) stamps every composed frame
# with the refresh slot it was shown in, on QPC. To turn "the edge reached x at
# refresh r" into input-to-photon lag, reversal checks and jitter, the lab needs
# the other end of the same ruler: WHEN the pointer reached x. A drag played by
# a PowerShell loop with Start-Sleep moves at whatever rate the scheduler
# allows (15.6 ms quanta by default) and records nothing, so its "lag" would
# measure the driver, not the app.
#
# THE MECHANICS:
#
#   Paths are built, not improvised. GliPathBuilder turns MoveTo / Press /
#     Hold / Line / Release into one sample per tick at RateHz (1000 by
#     default). Every sample has a planned offset on the QPC clock; a Line's
#     endpoint is exact and its intermediate points are rounded from the
#     straight line, so a back-and-forth path never steps against its own
#     direction (the reversal check depends on that).
#   A high-resolution waitable timer (CREATE_WAITABLE_TIMER_HIGH_RESOLUTION),
#     then a short spin to the exact tick. The timer sleeps the thread for
#     the bulk of each millisecond instead of burning a core; the spin takes
#     the last ~300 us, which the timer alone overshoots. Boxes without the
#     flag (pre-1803) fall back to an ordinary timer under timeBeginPeriod(1).
#   Every point is stamped AFTER SendInput returns (SentQpc) beside its
#     PlannedQpc, so lateness is measured, never assumed. A point more than one
#     period late is counted (Late), not hidden.
#   SendInput with MOUSEEVENTF_ABSOLUTE | VIRTUALDESK on a per-monitor-DPI-
#     aware thread, so path coordinates are PHYSICAL pixels - the same space
#     FrameCapture's rects are in. The normalisation is ceil(x * 65536 / w),
#     which floor-decodes back to exactly x for every pixel (section B).
#
# THE SAFETY RULES (this moves the user's real pointer):
#
#   - Nothing is injected while somebody is using the box: Invoke-FrameLabInput
#     asks lib\UserPresence.ps1 first and returns Skipped with the reason.
#     -DryRun (time the loop, send nothing) and a caller-supplied sink are the
#     only ways past the gate, and neither touches the input stream.
#   - The user taking the mouse back ends the run at once. Before each send
#     the player reads the cursor; if it is more than TolerancePx from every
#     one of the last 16 points it sent, on two checks in a row (the raw input
#     thread can lag a point behind under load), the run aborts with
#     AbortReason = user-input.
#   - A pressed button is ALWAYS released: on abort, on an exception, and on a
#     path that ends with the button down.
#
# The player talks to an IGliSink, so the same loop runs against
# GliRecordingSink in the acceptance harness: every send recorded, and a
# simulated user who moves the cursor at a chosen point. That is how the abort
# and the release are proved without touching the real pointer.
#
# input-desktop-helper: (T2384) the `SendInput` below IS the lab's input - real
# pointer motion through the modal size loop, timed on QPC; it is gated on
# lib\UserPresence.ps1 and never runs in its own harness (a recording sink does).
#
# INPUT DESKTOP ONLY when it injects. SendInput reaches only the input desktop,
# so a caller that injects is an input-desktop exception (lib\TestDesktop.ps1).
# This file opens no window.
#
# Acceptance: test\win32\frame-lab-input.ps1.
# ASCII-only by design (PS 5.1 on this box mangles non-ASCII on rewrite).

$script:FrameLabInputSource = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;

public static class GliFlags {
    public const int Down = 1;  // left button down after moving to the point
    public const int Up = 2;    // left button up after moving to the point
}

public struct GliSample {
    public long OffsetTicks;    // planned QPC offset from the run's start
    public int X, Y;            // physical pixels, virtual-desktop coordinates
    public int Flags;
}

public struct GliStamp {
    public int Index;
    public long PlannedQpc, SentQpc;
    public int X, Y, Flags;
}

public interface IGliSink {
    // Move to (x, y) and apply flags. False = the send did not go through.
    bool Send(int x, int y, int flags);
    bool TryGetCursor(out int x, out int y);
}

public static class GliClock {
    [DllImport("kernel32.dll")] static extern bool QueryPerformanceCounter(out long v);
    [DllImport("kernel32.dll")] static extern bool QueryPerformanceFrequency(out long v);
    public static readonly long Frequency;
    static GliClock() { long f; QueryPerformanceFrequency(out f); Frequency = f; }
    public static long Now() { long v; QueryPerformanceCounter(out v); return v; }
    public static long Ticks(double ms) { return (long)Math.Round(ms * Frequency / 1000.0); }
}

public sealed class GliPathBuilder {
    readonly List<GliSample> samples = new List<GliSample>();
    readonly double rateHz;
    int x, y;
    bool placed;
    public GliPathBuilder(double rateHz) {
        if (rateHz <= 0 || rateHz > 8000) throw new ArgumentOutOfRangeException("rateHz");
        this.rateHz = rateHz;
    }
    public double RateHz { get { return rateHz; } }
    public int Count { get { return samples.Count; } }
    long OffsetOf(int i) { return (long)Math.Round(i * GliClock.Frequency / rateHz); }
    void Emit(int px, int py, int flags) {
        samples.Add(new GliSample { OffsetTicks = OffsetOf(samples.Count), X = px, Y = py, Flags = flags });
        x = px; y = py; placed = true;
    }
    void RequirePlaced(string what) {
        if (!placed) throw new InvalidOperationException(what + " before MoveTo: the path has no position yet");
    }
    public GliPathBuilder MoveTo(int px, int py) { Emit(px, py, 0); return this; }
    public GliPathBuilder Press() { RequirePlaced("Press"); Emit(x, y, GliFlags.Down); return this; }
    public GliPathBuilder Release() { RequirePlaced("Release"); Emit(x, y, GliFlags.Up); return this; }
    // Stay put for ms (one sample per tick, so the cursor keeps reporting).
    public GliPathBuilder Hold(double ms) {
        RequirePlaced("Hold");
        int n = (int)Math.Round(ms * rateHz / 1000.0);
        for (int i = 0; i < n; i++) Emit(x, y, 0);
        return this;
    }
    // Straight line to (px, py) over ms: sample k of n sits at k/n of the way,
    // so the endpoint is exact and the path is monotonic along each axis.
    public GliPathBuilder Line(int px, int py, double ms) {
        RequirePlaced("Line");
        int n = Math.Max(1, (int)Math.Round(ms * rateHz / 1000.0));
        int x0 = x, y0 = y;
        for (int k = 1; k <= n; k++) {
            double t = (double)k / n;
            Emit((int)Math.Round(x0 + (px - x0) * t), (int)Math.Round(y0 + (py - y0) * t), 0);
        }
        return this;
    }
    // Back and forth between the current point and (px, py), legs times, each
    // leg taking ms: the user's "janks back and forth" drag.
    public GliPathBuilder Shuttle(int px, int py, int legs, double ms) {
        RequirePlaced("Shuttle");
        int ax = x, ay = y;
        for (int l = 0; l < legs; l++) {
            if (l % 2 == 0) Line(px, py, ms); else Line(ax, ay, ms);
        }
        return this;
    }
    public GliSample[] Build() { return samples.ToArray(); }
}

public sealed class GliResult {
    public GliStamp[] Stamps;
    public int Planned;
    public int Sent;
    public bool DryRun;
    public bool Aborted;
    public string AbortReason = "";
    public int AbortIndex = -1;
    public bool ButtonReleased;      // the player had to send a release itself
    public bool HighResolutionTimer;
    public long PeriodTicks;
    public double LatenessP50Us, LatenessP95Us, LatenessMaxUs;
    public int Late;                 // points sent more than one period late
    public double AchievedHz;
    public string Error = "";
    public override string ToString() {
        return string.Format("planned={0} sent={1} dry={2} aborted={3}{4} late={5} p50={6:F0}us p95={7:F0}us max={8:F0}us hz={9:F1} hrt={10}{11}",
            Planned, Sent, DryRun, Aborted, Aborted ? "(" + AbortReason + "@" + AbortIndex + ")" : "",
            Late, LatenessP50Us, LatenessP95Us, LatenessMaxUs, AchievedHz, HighResolutionTimer,
            Error.Length > 0 ? " error=" + Error : "");
    }
}

// The real sink: SendInput, absolute, virtual desktop, physical pixels. Must
// be used from a per-monitor-DPI-aware thread (GliPlayer sets that up).
public sealed class GliSendInputSink : IGliSink {
    [StructLayout(LayoutKind.Sequential)]
    struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr extra; }
    [StructLayout(LayoutKind.Sequential)]
    struct INPUT { public uint type; public MOUSEINPUT mi; public int pad0, pad1; }
    [StructLayout(LayoutKind.Sequential)]
    struct POINT { public int X, Y; }
    [DllImport("user32.dll", SetLastError = true)] static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [DllImport("user32.dll")] static extern int GetSystemMetrics(int i);
    [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
    const uint MOVE = 0x0001, LEFTDOWN = 0x0002, LEFTUP = 0x0004, VIRTUALDESK = 0x4000, ABSOLUTE = 0x8000;

    int left, top, width, height;
    public void Refresh() {
        left = GetSystemMetrics(76); top = GetSystemMetrics(77);      // SM_X/YVIRTUALSCREEN
        width = GetSystemMetrics(78); height = GetSystemMetrics(79);  // SM_CX/CYVIRTUALSCREEN
    }
    public int Left { get { return left; } }
    public int Top { get { return top; } }
    public int Width { get { return width; } }
    public int Height { get { return height; } }

    public bool Send(int x, int y, int flags) {
        var list = new INPUT[(flags & GliFlags.Down) != 0 || (flags & GliFlags.Up) != 0 ? 2 : 1];
        list[0].type = 0;
        list[0].mi.dx = GliMath.Normalize(x - left, width);
        list[0].mi.dy = GliMath.Normalize(y - top, height);
        list[0].mi.dwFlags = MOVE | ABSOLUTE | VIRTUALDESK;
        if (list.Length == 2) {
            list[1] = list[0];
            list[1].mi.dwFlags = ((flags & GliFlags.Down) != 0 ? LEFTDOWN : LEFTUP) | ABSOLUTE | VIRTUALDESK;
        }
        return SendInput((uint)list.Length, list, Marshal.SizeOf(typeof(INPUT))) == (uint)list.Length;
    }
    public bool TryGetCursor(out int x, out int y) {
        POINT p; bool ok = GetCursorPos(out p); x = p.X; y = p.Y; return ok;
    }
}

// The test sink: records every send; from send index UserMovesAt on, the
// cursor reports (UserX, UserY) as if a person had taken the mouse.
public sealed class GliRecordingSink : IGliSink {
    public readonly List<GliSample> Sends = new List<GliSample>();
    public int UserMovesAt = -1;
    public int UserX, UserY;
    public int LagSends;             // the cursor reports the point this many sends back
    public bool Send(int x, int y, int flags) {
        Sends.Add(new GliSample { X = x, Y = y, Flags = flags });
        return true;
    }
    public bool TryGetCursor(out int x, out int y) {
        if (UserMovesAt >= 0 && Sends.Count >= UserMovesAt) { x = UserX; y = UserY; return true; }
        if (Sends.Count == 0) { x = 0; y = 0; return false; }
        var s = Sends[Math.Max(0, Sends.Count - 1 - LagSends)];
        x = s.X; y = s.Y; return true;
    }
}

public static class GliMath {
    // ceil(v * 65536 / extent): floor(n * extent / 65536) decodes back to v
    // for every v in [0, extent), and n stays <= 65535.
    public static int Normalize(int v, int extent) {
        if (extent <= 1) return 0;
        long n = ((long)v * 65536 + extent - 1) / extent;
        if (n < 0) n = 0;
        if (n > 65535) n = 65535;
        return (int)n;
    }
    public static int Denormalize(int n, int extent) { return (int)(((long)n * extent) >> 16); }

    // Diverged = the cursor is farther than tol from every recent sent point.
    public static bool Diverged(int cx, int cy, IList<GliSample> recent, int tol) {
        if (recent.Count == 0) return false;
        long t2 = (long)tol * tol;
        foreach (var s in recent) {
            long dx = cx - s.X, dy = cy - s.Y;
            if (dx * dx + dy * dy <= t2) return false;
        }
        return true;
    }

    public static double Percentile(double[] sorted, double p) {
        if (sorted.Length == 0) return 0;
        int i = (int)Math.Ceiling(p * sorted.Length) - 1;
        return sorted[Math.Max(0, Math.Min(sorted.Length - 1, i))];
    }
}

public static class GliPlayer {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateWaitableTimerExW(IntPtr attrs, string name, uint flags, uint access);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetWaitableTimer(IntPtr t, ref long due, int period, IntPtr cb, IntPtr arg, bool resume);
    [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("winmm.dll")] static extern uint timeBeginPeriod(uint ms);
    [DllImport("winmm.dll")] static extern uint timeEndPeriod(uint ms);
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr ctx);
    const uint HIGH_RESOLUTION = 0x2, TIMER_ALL_ACCESS = 0x1F0003;
    const int RecentWindow = 16;

    // Play the path on a dedicated high-priority thread and wait for it.
    // sink == null with dryRun: time the loop, send nothing.
    public static GliResult Play(GliSample[] path, IGliSink sink, bool dryRun, int tolerancePx, bool abortOnUserInput) {
        if (path == null) throw new ArgumentNullException("path");
        if (!dryRun && sink == null) throw new ArgumentException("a live run needs a sink");
        var r = new GliResult { Planned = path.Length, DryRun = dryRun };
        var th = new Thread(() => {
            try { Run(path, dryRun ? null : sink, tolerancePx, abortOnUserInput, r); }
            catch (Exception e) { r.Error = e.GetType().Name + ": " + e.Message; }
        });
        th.Priority = ThreadPriority.Highest;
        th.IsBackground = true;
        th.Start();
        th.Join();
        return r;
    }

    static void Run(GliSample[] path, IGliSink sink, int tol, bool abortOnUser, GliResult r) {
        try { SetThreadDpiAwarenessContext(new IntPtr(-4)); } catch { }  // PER_MONITOR_AWARE_V2
        var real = sink as GliSendInputSink;
        if (real != null) real.Refresh();

        IntPtr timer = CreateWaitableTimerExW(IntPtr.Zero, null, HIGH_RESOLUTION, TIMER_ALL_ACCESS);
        bool hrt = timer != IntPtr.Zero;
        bool period = false;
        if (!hrt) { timer = CreateWaitableTimerExW(IntPtr.Zero, null, 0, TIMER_ALL_ACCESS); timeBeginPeriod(1); period = true; }
        r.HighResolutionTimer = hrt;
        long F = GliClock.Frequency;
        long spin = GliClock.Ticks(0.3);
        r.PeriodTicks = path.Length > 1 ? path[1].OffsetTicks - path[0].OffsetTicks : GliClock.Ticks(1);

        var stamps = new List<GliStamp>(path.Length);
        var recent = new List<GliSample>(RecentWindow);
        bool down = false;
        int strikes = 0;
        int lastX = 0, lastY = 0;
        try {
            long start = GliClock.Now() + GliClock.Ticks(2);
            for (int i = 0; i < path.Length; i++) {
                var s = path[i];
                long target = start + s.OffsetTicks;
                long remain = target - GliClock.Now();
                if (remain > spin && timer != IntPtr.Zero) {
                    long due = -((remain - spin) * 10000000L / F);  // relative, 100 ns units
                    if (due < 0 && SetWaitableTimer(timer, ref due, 0, IntPtr.Zero, IntPtr.Zero, false))
                        WaitForSingleObject(timer, 1000);
                }
                while (GliClock.Now() < target) { }

                if (sink != null && abortOnUser && recent.Count > 0) {
                    int cx, cy;
                    if (sink.TryGetCursor(out cx, out cy) && GliMath.Diverged(cx, cy, recent, tol)) {
                        if (++strikes >= 2) {
                            r.Aborted = true; r.AbortReason = "user-input"; r.AbortIndex = i;
                            break;
                        }
                    } else strikes = 0;
                }
                if (sink != null) {
                    if (!sink.Send(s.X, s.Y, s.Flags)) {
                        r.Aborted = true; r.AbortReason = "send-failed"; r.AbortIndex = i;
                        break;
                    }
                    if ((s.Flags & GliFlags.Down) != 0) down = true;
                    if ((s.Flags & GliFlags.Up) != 0) down = false;
                    if (recent.Count == RecentWindow) recent.RemoveAt(0);
                    recent.Add(s);
                }
                long sent = GliClock.Now();
                stamps.Add(new GliStamp { Index = i, PlannedQpc = target, SentQpc = sent, X = s.X, Y = s.Y, Flags = s.Flags });
                lastX = s.X; lastY = s.Y;
            }
        } finally {
            if (down && sink != null) {
                // Release where the cursor IS on an abort, so the release does
                // not drag the user's pointer back to the path.
                int ux = lastX, uy = lastY, cx, cy;
                if (r.Aborted && sink.TryGetCursor(out cx, out cy)) { ux = cx; uy = cy; }
                sink.Send(ux, uy, GliFlags.Up);
                r.ButtonReleased = true;
            }
            if (timer != IntPtr.Zero) CloseHandle(timer);
            if (period) timeEndPeriod(1);
            r.Stamps = stamps.ToArray();
            r.Sent = sink != null ? stamps.Count : 0;
            Summarise(r, F);
        }
    }

    static void Summarise(GliResult r, long F) {
        int n = r.Stamps.Length;
        if (n == 0) return;
        var late = new double[n];
        for (int i = 0; i < n; i++) late[i] = (r.Stamps[i].SentQpc - r.Stamps[i].PlannedQpc) * 1e6 / F;
        double periodUs = r.PeriodTicks * 1e6 / F;
        int over = 0;
        foreach (var l in late) if (l > periodUs) over++;
        r.Late = over;
        Array.Sort(late);
        r.LatenessP50Us = GliMath.Percentile(late, 0.50);
        r.LatenessP95Us = GliMath.Percentile(late, 0.95);
        r.LatenessMaxUs = late[n - 1];
        if (n > 1) {
            double span = (r.Stamps[n - 1].SentQpc - r.Stamps[0].SentQpc) / (double)F;
            r.AchievedHz = span > 0 ? (n - 1) / span : 0;
        }
    }
}
'@

function Import-FrameLabInput {
    if (-not ('GliPlayer' -as [type])) {
        Add-Type -TypeDefinition $script:FrameLabInputSource -Language CSharp
    }
}

<# A path builder at RateHz samples a second (1000 = the lab's 1 kHz). #>
function New-FrameLabPath([double]$RateHz = 1000) {
    Import-FrameLabInput
    return New-Object GliPathBuilder $RateHz
}

<#
The pure gate. Injection is allowed only when nobody is present; a dry run or
a caller-supplied sink never touches the input stream, so the gate passes them.
Returns { Allowed, Reason }.
#>
function Resolve-FrameLabInputGate {
    param($Presence, [switch]$DryRun, [switch]$CustomSink)
    if ($DryRun) { return [pscustomobject]@{ Allowed = $true; Reason = 'dry run: nothing is sent' } }
    if ($CustomSink) { return [pscustomobject]@{ Allowed = $true; Reason = 'caller sink: the real input stream is not touched' } }
    if ($null -eq $Presence) { return [pscustomobject]@{ Allowed = $false; Reason = 'no presence answer: never inject blind' } }
    if ($Presence.Present) {
        return [pscustomobject]@{ Allowed = $false; Reason = "somebody is using this box: $($Presence.Reason)" }
    }
    return [pscustomobject]@{ Allowed = $true; Reason = "nobody present: $($Presence.Reason)" }
}

<#
Play a path. Live by default (SendInput on the input desktop, gated on
lib\UserPresence.ps1); -DryRun times the loop and sends nothing; -Sink plays
into a caller's IGliSink (the harness's GliRecordingSink).

Returns the GliResult with two extra properties: Skipped (bool) and
SkipReason. A skipped run sent nothing.
#>
function Invoke-FrameLabInput {
    param(
        [Parameter(Mandatory)] [GliSample[]]$Path,
        [switch]$DryRun,
        $Sink = $null,
        [int]$TolerancePx = 3,
        [switch]$NoAbortOnUserInput,
        $Presence = $null
    )
    Import-FrameLabInput
    if (-not $DryRun -and -not $Sink -and $null -eq $Presence) {
        if (-not (Get-Command Get-UserPresence -ErrorAction SilentlyContinue)) {
            . (Join-Path $PSScriptRoot 'UserPresence.ps1')
        }
        $Presence = Get-UserPresence
    }
    $gate = Resolve-FrameLabInputGate -Presence $Presence -DryRun:$DryRun -CustomSink:([bool]$Sink)
    if (-not $gate.Allowed) {
        $r = New-Object GliResult
        $r.Planned = $Path.Length
        $r.Stamps = @()
        $r | Add-Member -NotePropertyName Skipped -NotePropertyValue $true
        $r | Add-Member -NotePropertyName SkipReason -NotePropertyValue $gate.Reason
        return $r
    }
    $useSink = if ($DryRun) { $null } elseif ($Sink) { $Sink } else { New-Object GliSendInputSink }
    $r = [GliPlayer]::Play($Path, $useSink, [bool]$DryRun, $TolerancePx, -not $NoAbortOnUserInput)
    $r | Add-Member -NotePropertyName Skipped -NotePropertyValue $false
    $r | Add-Member -NotePropertyName SkipReason -NotePropertyValue ''
    return $r
}

<#
The stamps as plain objects for a stamp JSON (T2390): times in microseconds
from the first planned point, plus the absolute QPC of that origin so the
report can line them up with FrameCapture's frame slots.
#>
function ConvertTo-FrameLabInputStamps($Result) {
    $F = [GliClock]::Frequency
    if (-not $Result.Stamps -or $Result.Stamps.Length -eq 0) { return @() }
    $origin = $Result.Stamps[0].PlannedQpc
    foreach ($s in $Result.Stamps) {
        [pscustomobject]@{
            i = $s.Index
            plannedUs = [math]::Round(($s.PlannedQpc - $origin) * 1e6 / $F, 1)
            sentUs = [math]::Round(($s.SentQpc - $origin) * 1e6 / $F, 1)
            x = $s.X; y = $s.Y; flags = $s.Flags
            originQpc = $origin
        }
    }
}
