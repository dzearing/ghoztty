# T207 deliverable 1 - the spike that decides the shape of the whole task.
#
# Question: can the GUI acceptance scripts run on a SEPARATE Win32 desktop
# (CreateDesktopW), so they stop stealing the user's foreground?
#
# Three sub-questions, all answered here against a real ghoztty launch:
#   1. ISOLATION - does a window created on a background desktop stay off the
#      interactive desktop (never enumerable there, never foreground there)?
#   2. INPUT     - does SendInput from a thread bound to that desktop reach the
#      app? (asserted end-to-end: ctrl+shift+t must add a tab, read back over
#      IPC from the normal desktop.)
#   3. CAPTURE   - is anything COMPOSED there? DWM composes only the input
#      desktop, so the 6 pixel-probe scripts are the known risk. Three capture
#      paths are measured: BitBlt from the desktop DC (what
#      Graphics.CopyFromScreen does), PrintWindow(PW_RENDERFULLCONTENT), and
#      PrintWindow with no flags. Each is scored BY REGION - see below.
#
# The app is launched with --window-theme=light on purpose: a light window is
# bright, so "capture returned black" is unambiguous rather than a plausible
# dark-terminal reading.
#
# ANSWERS (isolation/input measured on box 2026-07-30; capture re-measured
# 2026-09-02 by T1115, which overturned the original reading - see below. The
# assertions encode them, so this script doubles as the regression test for the
# T211 harness):
#   isolation - total. Not enumerable on the interactive desktop, never
#               foreground there.
#   input     - SendInput is BLOCKED (0 events accepted, ACCESS_DENIED); a
#               background desktop is not the input desktop. Posted
#               WM_KEYDOWN works, and modifier chords work when the key state
#               is set on the input queue we share via AttachThreadInput.
#   capture   - CHANGED AGAIN 2026-11-24 (T2206): PrintWindow now returns the
#               chrome AND the terminal surface, composed - the shell banner and
#               prompt are legible in the capture, and typing changes it.
#               CopyFromScreen/BitBlt is still dead outright. The T1115 text
#               below is the 2026-09-02 state (surface flat), kept as history.
#
# ---- T2206: the surface is composed now, and why the oracle changed ----
#
# Run 20/20 red on 2026-10-24 (T1280): the surface no longer scored flat
# (distinct ~1000 where T1115 measured 2). Measured 2026-11-24 with the capture
# saved to a PNG: the surface region holds the window gradient (glass panes,
# T1833) AND the terminal's own text over it, so the surface really is
# captured, not just the gradient behind it. (--background-opacity=1 gave a
# byte-identical capture: that flag does not turn the glass off, so it was no
# lever for separating the two; the PNG was.) The flat-surface assertions
# encoded an answer that stopped being true; they are replaced by CAP-4's
# change oracle (diff the surface before/after posted keys), which a gradient,
# a flat fill or a stale bitmap cannot pass. The same run found the input
# assertions red for a different reason: since T3185 `+list`'s window `id` is
# not the hwnd (see PaneOf). The CAPTURE LIMIT in `lib\TestDesktop.ps1`
# (measured on the CHILD hwnd) is re-checked by its own follow-up task.
#
# ---- T1115: how the capture answer changed, and why the old one was wrong ----
#
# The correction itself is not new. `lib\TestDesktop.ps1` measured and wrote it
# down on 2026-07-30 ("REVISES T207's answer ... the spike's 'PrintWindow
# returns real content' was reading the tab strip it had enabled, not the
# terminal"), and the harness has been built on that ever since. What went
# unreconciled for a month is THIS FILE, which kept asserting the answer the
# library had already overturned. T1115 is that reconciliation, plus the
# measurement below of what the oracle was actually doing wrong.
#
# Until 2026-09-02 this script asserted "PrintWindow(PW_RENDERFULLCONTENT)
# returns real content" by scoring mean luminance over the WHOLE window and
# requiring it to be bright. That oracle cannot distinguish the two outcomes it
# exists to tell apart: the terminal surface is dark by design and fills most of
# the window, so a capture consisting of light chrome over a flat dark client
# area scores about the same as a capture of the whole thing. It read as a pass
# in July and as a fail later only because the chrome shrank relative to the
# surface - the underlying behavior never changed.
#
# Scored BY REGION on this box (2026-09-02, Debug zig-out, 984x639 window,
# GhozttyTerminal child at 9,160 782x431):
#
#   route                              chrome band        below chrome
#   ---------------------------------  -----------------  -----------------
#   BitBlt off the desktop DC          BitBlt returns FALSE - nothing at all
#   PrintWindow(PW_RENDERFULLCONTENT)  mean 79 dist 103   mean 41 dist 2
#   PrintWindow(flags=0)               mean ~80 dist ~100 mean ~40 dist ~2
#
# distinct==2 over the entire client area is a flat fill: the surface was never
# composed. The chrome reading is the positive control - the same bitmap, the
# same sampler, 103 distinct colors - so "the surface is flat" is a measurement
# and not a broken capture.
#
# The INTERACTIVE-desktop control (same build, same call - PrintWindow on the
# TOP-LEVEL window, then the child's rect sampled out of that bitmap - one-off
# probe run 2026-09-02 alongside this script, 800x600 window, GhozttyTerminal
# child at 9,40 782x551):
#
#   route                              chrome band        SURFACE rect
#   ---------------------------------  -----------------  -----------------
#   PrintWindow(PW_RENDERFULLCONTENT)  mean 203 dist 35   mean 45 dist 102
#   PrintWindow(flags=0)               mean 207 dist 55   mean 45 dist 102
#   BitBlt off the desktop DC          (whole window: mean 55 dist 406)
#
# So the SAME call over the SAME region returns 102 distinct colors on the
# interactive desktop and 1-2 on the background one. The flat surface is
# therefore DESKTOP-dependent, not an unconditional property of PrintWindow.
#
# HOW THAT SITS WITH `lib\TestDesktop.ps1`, WHICH IS THE SOURCE OF TRUTH HERE.
# That file's CAPTURE LIMIT and its general rule (T303: "PrintWindow sees GDI,
# not composition") already state the operative conclusion, and this spike does
# not overturn them - it had simply never been reconciled with them. Note the
# difference in what was measured, so the two are not read as contradicting:
# TestDesktop.ps1 measured PrintWindow on the GhozttyTerminal CHILD hwnd (1
# distinct color, and a black-vs-white --background reading the same), which is
# a different call from the top-level capture measured here. Both agree on the
# thing that matters: on a BACKGROUND desktop the terminal surface cannot be
# asserted, and Get-TestWindowPixels is right to throw on a uniform interior.
#
# THE DECISION THIS SPIKE PRODUCED on 2026-09-02, for T1100 and the
# pixel-probe scripts (the first bullet is what T2206 re-opens):
#
#   * A probe that asserts TERMINAL CONTENT pixels (glyph colors, cursor,
#     selection highlight, anything the renderer draws into the terminal
#     surface) CANNOT run on a background desktop. All three capture routes
#     were measured here; there is no fourth to go looking for.
#   * A probe that asserts CHROME pixels (title bar, tab strip, banner, the
#     window's own painted controls) CAN run there, via PrintWindow into a
#     memory DC. It just cannot use CopyFromScreen.
#   * Screenshotting the desktop as a whole is unavailable either way.
#   * For a terminal-content probe that must survive, do NOT invent a route
#     here: `lib\TestDesktop.ps1` carries the decided ladder (route 0 asks the
#     app for its own pixels over the debug `capture-pane` IPC action, then
#     three fallbacks, then interactive-by-design). Follow it there.
#
# This script is SAFE to run while the user is working - that is the entire
# point of it. It asserts that itself (P3/P4).
#
# Only touches ghoztty processes running from this repo's zig-out, and it
# talks to its own IPC endpoint via GHOZTTY_PIPE_SUFFIX so the user's real
# instance is never queried or disturbed.
param([string]$ExePath)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')   # T271/T1768: arms the run, so the stamp below is refused for a body that unwound or asserted nothing
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }
if (-not (Test-Path $exe)) { Write-Host "SETUP FAIL: no exe at $exe"; exit 1 }

# T1029: the build-mode + freshness pre-flight (lib\BuildMode.ps1, loaded by
# CleanSlate). This spike launches the app through its own CreateProcessW
# rather than Start-OnTestDesktop, so the helper's pre-flight never speaks for
# it - asked here, before the first launch.
Assert-GhozttyIsolatedBuild -Exe $exe | Out-Null

# T1794: this spike reaches the INPUT desktop too, so it never runs over a
# person using the box. Asked before anything is launched.
. (Join-Path $PSScriptRoot 'lib\UserPresence.ps1')
Assert-UserAbsent

# T1127: the teardown at the bottom is -AppOnly, and even the full one would
# miss the agent's `--pty-host` holders, which own the ConPTY and escape the
# job on purpose. Arm the build-scoped teardown so nothing from zig-out
# outlives the script - failure path included, which is this script's normal
# ending when the spike measures a regression.
. (Join-Path $PSScriptRoot 'lib\HarnessLeak.ps1')
Register-RepoBuildTeardown -Exe $exe | Out-Null

$env:GHOZTTY_PIPE_SUFFIX = "-desktopspike$PID"

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

# CAP-1's verdict (T2208). BitBlt off the desktop DC is DEAD when the call
# fails outright, or when the CHROME band it returns is uniform (<= 2 distinct
# colours) while PrintWindow's chrome band of the same window holds content
# (> 4) - the positive control that says the band was there to capture. It
# used to be "not (whole-window mean > 60 and distinct > 4)", and a WORKING
# capture fails that bar: the dark terminal surface fills most of the window,
# so the interactive-desktop BitBlt measured mean 55 / 406 distinct and would
# have been scored dead. A band that could not be measured (no surface child,
# no band) is no verdict, so it is NOT dead.
function Test-BitBltDead([bool]$Ok, [int]$ChromeDistinct, [int]$ControlChromeDistinct) {
    if (-not $Ok) { return $true }
    if ($ControlChromeDistinct -le 4) { return $false }
    return ($ChromeDistinct -ge 0 -and $ChromeDistinct -le 2)
}

# The verdict's own controls, before anything launches - pure arithmetic over
# readings this file records, so the oracle is shown able to say both answers
# on every run, not only the one a background desktop produces.
#  - 2026-09-02 background desktop: BitBlt returned FALSE.          -> dead
#  - a black (uncomposed) bitmap: chrome band 1 colour, control 103. -> dead
#  - 2026-09-02 interactive desktop: whole window mean 55 / 406
#    distinct; its chrome band carries the title bar and tab strip,
#    which PrintWindow read as 35 distinct over the same band.      -> LIVE
#  - no positive control (PrintWindow chrome flat too).             -> no verdict
Assert (Test-BitBltDead -Ok $false -ChromeDistinct -1 -ControlChromeDistinct 103) `
    "CAP-1 verdict control: a BitBlt that returns FALSE scores dead"
Assert (Test-BitBltDead -Ok $true -ChromeDistinct 1 -ControlChromeDistinct 103) `
    "CAP-1 verdict control: a uniform chrome band under a live control scores dead"
Assert (-not (Test-BitBltDead -Ok $true -ChromeDistinct 35 -ControlChromeDistinct 35)) `
    "CAP-1 verdict control: the interactive-desktop working capture (whole-window mean 55) scores LIVE"
Assert (-not (Test-BitBltDead -Ok $true -ChromeDistinct 1 -ControlChromeDistinct 1)) `
    "CAP-1 verdict control: with no positive control there is no dead verdict"
Assert (-not (Test-BitBltDead -Ok $true -ChromeDistinct -1 -ControlChromeDistinct 103)) `
    "CAP-1 verdict control: an unmeasured chrome band is no dead verdict"

Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Text;
using System.Threading;
using System.Runtime.InteropServices;

public class DeskSpike {
    // ---- desktop / process ----
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr CreateDesktopW(string name, IntPtr dev, IntPtr devmode, int flags, uint access, IntPtr sa);
    [DllImport("user32.dll", SetLastError = true)] public static extern bool SetThreadDesktop(IntPtr h);
    [DllImport("user32.dll", SetLastError = true)] public static extern bool CloseDesktop(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetThreadDesktop(uint tid);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct STARTUPINFO {
        public int cb; public string lpReserved; public string lpDesktop; public string lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow; public short cbReserved2; public IntPtr lpReserved2;
        public IntPtr hStdInput, hStdOutput, hStdError;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool CreateProcessW(string app, StringBuilder cmd, IntPtr pa, IntPtr ta,
        bool inherit, uint flags, IntPtr env, string cwd, ref STARTUPINFO si, out PROCESS_INFORMATION pi);

    // ---- windows ----
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("user32.dll", SetLastError = true)] public static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern IntPtr SetFocus(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetFocus();
    [DllImport("user32.dll")] public static extern IntPtr GetActiveWindow();
    [DllImport("user32.dll")] public static extern IntPtr SetActiveWindow(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool PostMessageW(IntPtr h, uint msg, IntPtr wp, IntPtr lp);
    [DllImport("user32.dll")] public static extern bool GetKeyboardState(byte[] s);
    [DllImport("user32.dll")] public static extern bool SetKeyboardState(byte[] s);

    // ---- gdi ----
    [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr h);
    [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr h, IntPtr hdc);
    [DllImport("gdi32.dll")] public static extern IntPtr CreateCompatibleDC(IntPtr hdc);
    [DllImport("gdi32.dll")] public static extern IntPtr CreateCompatibleBitmap(IntPtr hdc, int w, int h);
    [DllImport("gdi32.dll")] public static extern IntPtr SelectObject(IntPtr hdc, IntPtr o);
    [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr o);
    [DllImport("gdi32.dll")] public static extern bool DeleteDC(IntPtr hdc);
    [DllImport("gdi32.dll")] public static extern bool BitBlt(IntPtr d, int dx, int dy, int w, int h, IntPtr s, int sx, int sy, uint rop);
    [DllImport("gdi32.dll")] public static extern uint GetPixel(IntPtr hdc, int x, int y);

    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int left, top, right, bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public MOUSEKEYBD u; }
    [StructLayout(LayoutKind.Explicit, Size = 32)]
    public struct MOUSEKEYBD {
        [FieldOffset(0)] public int dx;
        [FieldOffset(4)] public int dy;
        [FieldOffset(8)] public uint mouseData;
        [FieldOffset(12)] public uint mouseFlags;
        [FieldOffset(16)] public uint time;
        [FieldOffset(24)] public IntPtr extra;
        [FieldOffset(0)] public ushort wVk;
        [FieldOffset(2)] public ushort wScan;
        [FieldOffset(4)] public uint kbFlags;
    }
    public delegate bool EnumProc(IntPtr h, IntPtr l);

    // ---- results, read back by the PowerShell assertions ----
    public static string Log = "";
    public static bool DesktopCreated = false;
    public static bool ThreadBound = false;
    public static bool ProcessStarted = false;
    public static int Pid = 0;
    public static bool WindowFoundOnTestDesktop = false;
    public static bool ForegroundTakenOnTestDesktop = false;
    public static int WinW = 0, WinH = 0;
    public static int BitBltMeanLum = -1;      // -1 = capture failed outright
    public static int BitBltDistinct = -1;
    // T2208: BitBlt scored by REGION as well. The whole-window mean above is
    // dominated by the dark terminal surface, so a WORKING capture reads under
    // any brightness bar (interactive desktop, 2026-09-02: mean 55). What tells
    // a dead capture from a live one is the CHROME band: uniform when nothing
    // was composed, many colours when it was.
    public static bool BitBltOk = false;
    public static int BitBltChromeMeanLum = -1;
    public static int BitBltChromeDistinct = -1;
    public static int PrintMeanLum = -1;
    public static int PrintDistinct = -1;
    // T1115: the whole-window mean above is dominated by the terminal surface,
    // which is dark by design, so it never answered the question it was asked.
    // These three sample the bitmap by REGION instead, plus the un-flagged
    // PrintWindow as an in-script negative control.
    public static int PrintSurfaceMeanLum = -1;   // the GhozttyTerminal child's rect
    public static int PrintSurfaceDistinct = -1;
    public static int PrintChromeMeanLum = -1;    // the band above that child
    public static int PrintChromeDistinct = -1;
    public static int PrintBelowMeanLum = -1;     // everything below the chrome band
    public static int PrintBelowDistinct = -1;
    public static int PrintPlainMeanLum = -1;     // PrintWindow(flags=0), no RENDERFULLCONTENT
    public static int PrintPlainDistinct = -1;
    public static bool PrintPlainOk = false;
    public static bool PrintFullOk = false;
    public static bool ChordSent = false;
    public static int SendInputAccepted = -1;
    public static int SendInputLastError = -1;
    // T2206: the surface oracle. Two PW_RENDERFULLCONTENT captures of the
    // whole window, one before the posted keys and one after they are reported
    // on screen, diffed pixel for pixel over the GhozttyTerminal rect. Static
    // paint (the window gradient behind glass panes, a flat fill) cannot change
    // between the two; only a composed surface can.
    public static int SurfX = -1, SurfY = -1, SurfW = -1, SurfH = -1;
    public static int SurfaceChangedPx = -1;   // -1 = a capture failed
    public static int ChromeChangedPx = -1;    // the band above the surface, informational
    // T1280: what the input assertions are scored on, all read back over IPC
    // for the window the keys were posted to (the one window on a clean slate,
    // T2206 - see PaneOf).
    public static long TopHwnd = 0;
    public static string Pane = null;
    public static bool PreHadToken = false;
    public static int KeysLandedMs = -1;
    public static int TabsBefore = -1, TabsAfter = -1, ChordLandedMs = -1;

    static void note(string s) { Log += s + "\n"; }

    // The CLI, aimed by the inherited GHOZTTY_PIPE_SUFFIX at this run's app.
    static string Cli(string exe, string args) {
        var psi = new System.Diagnostics.ProcessStartInfo(exe, args);
        psi.UseShellExecute = false; psi.CreateNoWindow = true;
        psi.RedirectStandardOutput = true; psi.RedirectStandardError = true;
        using (var p = System.Diagnostics.Process.Start(psi)) {
            var err = p.StandardError.ReadToEndAsync();
            string o = p.StandardOutput.ReadToEnd();
            p.WaitForExit(10000);
            return o;
        }
    }

    // The spike's window: its first tab's pane name, and its tab count (one
    // "splits" per tab). null unless +list reports EXACTLY ONE window.
    //
    // T2206: this used to find the window by `+list`'s `id` == its hwnd. Since
    // single-window mode (T3185) a workspace's `id` is the Window pointer, not
    // the hwnd, so the lookup never matched and every input assertion read
    // tabs=-1. +list carries no hwnd at all, so the window is identified by
    // being the only one: the run starts from a full reset, so a second window
    // (the 2026-09-02 shape T1280 guarded against) makes this null - a red,
    // never a wrong window answering. Every window object carries
    // `title_set_by_user` exactly once and no tab or pane does.
    static string PaneOf(string exe, long hwnd, out int tabs) {
        tabs = -1;
        string json = Cli(exe, "+list --json");
        if (System.Text.RegularExpressions.Regex.Matches(json, "\"title_set_by_user\":").Count != 1) return null;
        int at = json.IndexOf("\"windows\":[{\"id\":\"");
        if (at < 0) return null;
        int end = json.IndexOf(",\"chrome\":", at);
        string w = end < 0 ? json.Substring(at) : json.Substring(at, end - at);
        tabs = System.Text.RegularExpressions.Regex.Matches(w, "\"splits\":").Count;
        var m = System.Text.RegularExpressions.Regex.Match(w, "\"name\":\"([^\"]+)\"");
        return m.Success ? m.Groups[1].Value : null;
    }

    // Tabs across EVERY window +list reports (one "splits" per tab). The chord
    // below is scored on this: in single-window mode ctrl+shift+t opens a new
    // WORKSPACE, which +list reports as a second window (T3182, Mac `newTab`),
    // so the spike's own window keeps one tab and PaneOf stops answering.
    static int TotalTabs(string exe) {
        string json = Cli(exe, "+list --json");
        if (json.IndexOf("\"windows\":[") < 0) return -1;
        return System.Text.RegularExpressions.Regex.Matches(json, "\"splits\":").Count;
    }

    static void Key(ushort vk, bool up) {
        var i = new INPUT[1];
        i[0].type = 1; i[0].u.wVk = vk; i[0].u.kbFlags = up ? 2u : 0u;
        SendInput(1, i, Marshal.SizeOf(typeof(INPUT)));
    }

    // Returns how many events SendInput actually accepted (0 = blocked).
    static uint KeyChar(char c) {
        uint n = 0;
        var i = new INPUT[1];
        i[0].type = 1; i[0].u.wVk = (ushort)char.ToUpper(c); i[0].u.kbFlags = 0;
        n += SendInput(1, i, Marshal.SizeOf(typeof(INPUT)));
        i[0].u.kbFlags = 2;
        n += SendInput(1, i, Marshal.SizeOf(typeof(INPUT)));
        return n;
    }

    // Mean luminance + distinct-color count over a 4px grid of a memory DC.
    // A capture of a desktop that is not composed comes back uniformly black:
    // mean ~0 AND distinct == 1. Real window content is neither.
    static void Sample(IntPtr hdcMem, int w, int h, out int meanLum, out int distinct) {
        SampleRect(hdcMem, 0, 0, w, h, out meanLum, out distinct);
    }

    // T2206: a full-resolution PW_RENDERFULLCONTENT capture of `top` as packed
    // 0xRRGGBB, or null when PrintWindow fails.
    static int[] Snap(IntPtr top, int w, int h) {
        IntPtr hdcWin = GetDC(top);
        IntPtr mem = CreateCompatibleDC(hdcWin);
        IntPtr bmp = CreateCompatibleBitmap(hdcWin, w, h);
        IntPtr old = SelectObject(mem, bmp);
        bool ok = PrintWindow(top, mem, 2 /*PW_RENDERFULLCONTENT*/);
        SelectObject(mem, old);
        int[] px = null;
        if (ok) {
            using (var b = System.Drawing.Image.FromHbitmap(bmp)) {
                var data = b.LockBits(new System.Drawing.Rectangle(0, 0, w, h),
                    System.Drawing.Imaging.ImageLockMode.ReadOnly,
                    System.Drawing.Imaging.PixelFormat.Format32bppRgb);
                px = new int[w * h];
                for (int y = 0; y < h; y++) Marshal.Copy(IntPtr.Add(data.Scan0, y * data.Stride), px, y * w, w);
                b.UnlockBits(data);
            }
        }
        DeleteObject(bmp); DeleteDC(mem); ReleaseDC(top, hdcWin);
        return px;
    }

    // Pixels that differ between two Snap()s inside a rect; -1 when either is missing.
    static int Changed(int[] a, int[] b, int w, int x0, int y0, int rw, int rh) {
        if (a == null || b == null || rw <= 0 || rh <= 0) return -1;
        int n = 0;
        for (int y = y0; y < y0 + rh; y++)
            for (int x = x0; x < x0 + rw; x++) {
                int i = y * w + x;
                if (i >= 0 && i < a.Length && ((a[i] ^ b[i]) & 0xFFFFFF) != 0) n++;
            }
        return n;
    }

    // The same measurement over an arbitrary sub-rect of the bitmap, so the
    // terminal surface and the chrome band can be scored separately (T1115).
    static void SampleRect(IntPtr hdcMem, int x0, int y0, int w, int h, out int meanLum, out int distinct) {
        double sum = 0; int n = 0;
        var seen = new System.Collections.Generic.HashSet<uint>();
        for (int y = y0 + 2; y < y0 + h; y += 4) {
            for (int x = x0 + 2; x < x0 + w; x += 4) {
                uint c = GetPixel(hdcMem, x, y);
                if (c == 0xFFFFFFFF) continue; // CLR_INVALID
                uint r = c & 0xFF, g = (c >> 8) & 0xFF, b = (c >> 16) & 0xFF;
                sum += 0.2126 * r + 0.7152 * g + 0.0722 * b;
                n++;
                if (seen.Count < 4096) seen.Add(c);
            }
        }
        meanLum = (n == 0) ? -1 : (int)(sum / n);
        distinct = (n == 0) ? -1 : seen.Count;
    }

    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr p, EnumProc cb, IntPtr l);
    static IntPtr FindChildClass(IntPtr top, string cls) {
        IntPtr found = IntPtr.Zero;
        EnumChildWindows(top, (h, l) => {
            var sb = new StringBuilder(64);
            GetClassNameW(h, sb, 64);
            if (sb.ToString() == cls) { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    static IntPtr FindClassForPid(uint pid, string cls) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) => {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p == pid && IsWindowVisible(h)) {
                var sb = new StringBuilder(64);
                GetClassNameW(h, sb, 64);
                if (sb.ToString() == cls) { found = h; return false; }
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    // Runs the whole spike on a dedicated thread bound to the test desktop.
    // SetThreadDesktop fails on a thread that already owns windows or hooks,
    // which is exactly why this cannot run on the PowerShell host thread.
    public static void Run(string exe, string desktopName, string extraArgs, int settleMs) {
        var t = new Thread(() => Body(exe, desktopName, extraArgs, settleMs));
        t.SetApartmentState(ApartmentState.STA);
        t.Start();
        t.Join();
    }

    static void Body(string exe, string desktopName, string extraArgs, int settleMs) {
        IntPtr hDesk = IntPtr.Zero;
        try {
            SetProcessDPIAware();
            hDesk = CreateDesktopW(desktopName, IntPtr.Zero, IntPtr.Zero, 0, 0x10000000 /*GENERIC_ALL*/, IntPtr.Zero);
            if (hDesk == IntPtr.Zero) { note("CreateDesktopW failed: " + Marshal.GetLastWin32Error()); return; }
            DesktopCreated = true;

            if (!SetThreadDesktop(hDesk)) { note("SetThreadDesktop failed: " + Marshal.GetLastWin32Error()); return; }
            ThreadBound = true;

            var si = new STARTUPINFO();
            si.cb = Marshal.SizeOf(typeof(STARTUPINFO));
            si.lpDesktop = "WinSta0\\" + desktopName;
            PROCESS_INFORMATION pi;
            var cmd = new StringBuilder("\"" + exe + "\" " + extraArgs);
            if (!CreateProcessW(exe, cmd, IntPtr.Zero, IntPtr.Zero, false, 0x08000000 /*CREATE_NO_WINDOW*/, IntPtr.Zero, null, ref si, out pi)) {
                note("CreateProcessW failed: " + Marshal.GetLastWin32Error());
                return;
            }
            ProcessStarted = true;
            Pid = pi.dwProcessId;
            note("launched pid " + Pid + " on desktop " + si.lpDesktop);

            IntPtr top = IntPtr.Zero;
            for (int i = 0; i < 60 && top == IntPtr.Zero; i++) {
                Thread.Sleep(250);
                top = FindClassForPid((uint)Pid, "GhozttyWindow");
            }
            if (top == IntPtr.Zero) { note("GhozttyWindow never appeared on the test desktop"); return; }
            WindowFoundOnTestDesktop = true;
            Thread.Sleep(settleMs);

            RECT r;
            GetWindowRect(top, out r);
            WinW = r.right - r.left; WinH = r.bottom - r.top;
            note("window rect " + r.left + "," + r.top + " " + WinW + "x" + WinH);

            // --- foreground ON THE TEST DESKTOP. Each desktop keeps its own
            // foreground window, so this must succeed here without ever
            // touching the interactive one.
            // A background desktop is not the INPUT desktop, so it has no
            // foreground window: SetForegroundWindow fails and
            // GetForegroundWindow is 0. Focus still exists per input queue,
            // so the way in is AttachThreadInput onto the app's GUI thread
            // and then SetActiveWindow/SetFocus - after which SendInput from
            // this thread routes to that focus window.
            bool sfw = SetForegroundWindow(top);
            Thread.Sleep(200);
            IntPtr fg = GetForegroundWindow();
            ForegroundTakenOnTestDesktop = (fg == top);
            note("SetForegroundWindow=" + sfw + " GetForegroundWindow=" + fg + " top=" + top);

            uint appPid; uint appTid = GetWindowThreadProcessId(top, out appPid);
            uint myTid = GetCurrentThreadId();
            bool att = AttachThreadInput(myTid, appTid, true);
            SetActiveWindow(top);
            SetFocus(top);
            for (int i = 0; i < 40 && GetFocus() == IntPtr.Zero; i++) Thread.Sleep(50);
            note("AttachThreadInput=" + att + " GetFocus=" + GetFocus() + " GetActiveWindow=" + GetActiveWindow());
            TopHwnd = top.ToInt64();

            // --- capture path 1: BitBlt off the desktop DC (== CopyFromScreen)
            if (WinW > 0 && WinH > 0) {
                // The surface child's rect splits every capture into a chrome
                // band and the region below it (T1115); found first so the
                // BitBlt capture is scored by the same band (T2208).
                IntPtr surfEarly = FindChildClass(top, "GhozttyTerminal");
                RECT sr = new RECT();
                bool haveSurf = (surfEarly != IntPtr.Zero) && GetWindowRect(surfEarly, out sr);
                int bandH = haveSurf ? (sr.top - r.top) : -1;

                IntPtr hdcScreen = GetDC(IntPtr.Zero);
                IntPtr hdcMem = CreateCompatibleDC(hdcScreen);
                IntPtr hbmp = CreateCompatibleBitmap(hdcScreen, WinW, WinH);
                IntPtr old = SelectObject(hdcMem, hbmp);
                bool ok = BitBlt(hdcMem, 0, 0, WinW, WinH, hdcScreen, r.left, r.top, 0x00CC0020 /*SRCCOPY*/);
                note("BitBlt from desktop DC ok=" + ok);
                BitBltOk = ok;
                if (ok) {
                    int m, d; Sample(hdcMem, WinW, WinH, out m, out d); BitBltMeanLum = m; BitBltDistinct = d;
                    if (bandH > 8) {
                        int bcm, bcd; SampleRect(hdcMem, 0, 0, WinW, bandH, out bcm, out bcd);
                        BitBltChromeMeanLum = bcm; BitBltChromeDistinct = bcd;
                    }
                }
                SelectObject(hdcMem, old); DeleteObject(hbmp); DeleteDC(hdcMem); ReleaseDC(IntPtr.Zero, hdcScreen);

                // --- capture path 2: PrintWindow(PW_RENDERFULLCONTENT)
                //
                // Scored by REGION, not by overall brightness (T1115). The
                // terminal surface is dark by design and fills most of the
                // window, so a whole-window mean is dark whether or not the
                // client area was rendered - which is exactly the thing this
                // measurement has to tell apart. What discriminates is
                // UNIFORMITY: an uncomposed capture is one flat color.
                IntPtr hdcWin = GetDC(top);
                IntPtr hdcMem2 = CreateCompatibleDC(hdcWin);
                IntPtr hbmp2 = CreateCompatibleBitmap(hdcWin, WinW, WinH);
                IntPtr old2 = SelectObject(hdcMem2, hbmp2);
                bool pok = PrintWindow(top, hdcMem2, 2 /*PW_RENDERFULLCONTENT*/);
                PrintFullOk = pok;
                note("PrintWindow(PW_RENDERFULLCONTENT) ok=" + pok);
                if (pok) {
                    int m, d; Sample(hdcMem2, WinW, WinH, out m, out d); PrintMeanLum = m; PrintDistinct = d;
                    if (haveSurf) {
                        // child rect is in screen coords; the bitmap is window-relative.
                        int sx = sr.left - r.left, sy = sr.top - r.top;
                        int sw = sr.right - sr.left, sh = sr.bottom - sr.top;
                        note("GhozttyTerminal rect in window coords " + sx + "," + sy + " " + sw + "x" + sh);
                        SurfX = sx; SurfY = sy; SurfW = sw; SurfH = sh;
                        if (sw > 8 && sh > 8) {
                            int sm, sd; SampleRect(hdcMem2, sx, sy, sw, sh, out sm, out sd);
                            PrintSurfaceMeanLum = sm; PrintSurfaceDistinct = sd;
                        }
                        if (sy > 8) {
                            int cm, cd; SampleRect(hdcMem2, 0, 0, WinW, sy, out cm, out cd);
                            PrintChromeMeanLum = cm; PrintChromeDistinct = cd;
                            // Everything below the chrome, full width - so a
                            // flat reading cannot be blamed on the child rect
                            // being mapped a few pixels wrong.
                            int bm, bd; SampleRect(hdcMem2, 0, sy, WinW, WinH - sy, out bm, out bd);
                            PrintBelowMeanLum = bm; PrintBelowDistinct = bd;
                        }
                    }
                }
                SelectObject(hdcMem2, old2); DeleteObject(hbmp2); DeleteDC(hdcMem2);

                // --- capture path 3: PrintWindow with NO flags. This is the
                // negative control for the oracle above: without
                // PW_RENDERFULLCONTENT the DWM-rendered client area is not
                // redirected into the DC, so a working oracle must score this
                // one differently from path 2 on the very same window.
                IntPtr hdcMem3 = CreateCompatibleDC(hdcWin);
                IntPtr hbmp3 = CreateCompatibleBitmap(hdcWin, WinW, WinH);
                IntPtr old3 = SelectObject(hdcMem3, hbmp3);
                bool pok0 = PrintWindow(top, hdcMem3, 0);
                PrintPlainOk = pok0;
                note("PrintWindow(flags=0) ok=" + pok0);
                if (pok0) { int m, d; Sample(hdcMem3, WinW, WinH, out m, out d); PrintPlainMeanLum = m; PrintPlainDistinct = d; }
                SelectObject(hdcMem3, old3); DeleteObject(hbmp3); DeleteDC(hdcMem3);
                ReleaseDC(top, hdcWin);
            }

            IntPtr surf = FindChildClass(top, "GhozttyTerminal");
            note("GhozttyTerminal child: " + surf);
            IntPtr target = (surf != IntPtr.Zero) ? surf : top;

            // --- input path 1: SendInput, what all 36 driving scripts use.
            uint sent = 0;
            foreach (char c in "SPIKEA") { sent += KeyChar(c); }
            SendInputLastError = Marshal.GetLastWin32Error();
            SendInputAccepted = (int)sent;
            Thread.Sleep(400);
            note("SendInput events accepted: " + sent + " of 12 (last error " + SendInputLastError + ")");

            // T1280: every wait on the input path below is on something the
            // app reports over IPC, never a fixed sleep. The window is found
            // by its hwnd in +list (`id`), not as windows[0], so a second
            // window can never answer for the one the keys were posted to.
            string pane = null;
            for (int i = 0; i < 75; i++) {
                int tabs; pane = PaneOf(exe, top.ToInt64(), out tabs);
                if (pane != null && Cli(exe, "+read --name=" + pane + " --lines=10").Trim().Length > 0) { TabsBefore = tabs; break; }
                pane = null; Thread.Sleep(200);
            }
            Pane = pane;
            note("app answers for window " + top + ": pane=" + pane + " tabs=" + TabsBefore);
            if (pane != null) PreHadToken = Cli(exe, "+read --name=" + pane + " --lines=10").ToLower().Contains("spikeb");
            // T2206: the BEFORE half of the surface oracle, taken once the app
            // has answered (so the prompt is up) and before a key is posted.
            int[] snapBefore = (WinW > 0 && WinH > 0) ? Snap(top, WinW, WinH) : null;

            // --- input path 2: posted key messages. The terminal class skips
            // TranslateMessage (App.run) and calls ToUnicode itself, so a bare
            // WM_KEYDOWN is enough - posting WM_CHAR too would double every
            // character.
            foreach (char c in "SPIKEB") {
                PostMessageW(target, 0x0100 /*WM_KEYDOWN*/, (IntPtr)char.ToUpper(c), IntPtr.Zero);
                PostMessageW(target, 0x0101 /*WM_KEYUP*/, (IntPtr)char.ToUpper(c), IntPtr.Zero);
            }
            var clock = System.Diagnostics.Stopwatch.StartNew();
            for (int i = 0; i < 50 && pane != null; i++) {
                if (Cli(exe, "+read --name=" + pane + " --lines=10").ToLower().Contains("spikeb")) { KeysLandedMs = (int)clock.ElapsedMilliseconds; break; }
                Thread.Sleep(200);
            }
            note("posted keys landed after " + KeysLandedMs + "ms (-1 = not within 10s)");
            // T2206: the AFTER half. +read reports the text from the terminal
            // model, which runs ahead of the next frame, so give the renderer a
            // few frames before capturing what it drew.
            if (KeysLandedMs >= 0 && snapBefore != null) {
                Thread.Sleep(600);
                int[] snapAfter = Snap(top, WinW, WinH);
                SurfaceChangedPx = Changed(snapBefore, snapAfter, WinW, SurfX, SurfY, SurfW, SurfH);
                ChromeChangedPx = Changed(snapBefore, snapAfter, WinW, 0, 0, WinW, SurfY);
            }
            note("surface pixels changed by the posted keys: " + SurfaceChangedPx + " (chrome band: " + ChromeChangedPx + ")");

            // --- input path 3: a MODIFIER CHORD by the same route. Posted
            // messages do not move the key state that the app reads back for
            // modifiers, so set it explicitly - legal here because
            // AttachThreadInput has merged our input queue with the app's, and
            // on a background desktop no raw-input thread overwrites it.
            // The key state is held until the new tab is REPORTED: the app
            // reads it when it dequeues the 'T', so clearing it on a timer
            // (as this used to, 200ms later) races a busy app into a plain t.
            var ks = new byte[256];
            GetKeyboardState(ks);
            ks[0x11] = 0x80; ks[0xA2] = 0x80;   // VK_CONTROL, VK_LCONTROL
            ks[0x10] = 0x80; ks[0xA0] = 0x80;   // VK_SHIFT, VK_LSHIFT
            SetKeyboardState(ks);
            PostMessageW(target, 0x0100, (IntPtr)0x11, IntPtr.Zero);
            PostMessageW(target, 0x0100, (IntPtr)0x10, IntPtr.Zero);
            PostMessageW(target, 0x0100, (IntPtr)0x54, IntPtr.Zero); // 'T'
            clock.Restart();
            for (int i = 0; i < 50 && pane != null; i++) {
                int tabs = TotalTabs(exe);
                if (tabs > TabsBefore) { TabsAfter = tabs; ChordLandedMs = (int)clock.ElapsedMilliseconds; break; }
                Thread.Sleep(200);
            }
            PostMessageW(target, 0x0101, (IntPtr)0x54, IntPtr.Zero);
            PostMessageW(target, 0x0101, (IntPtr)0x10, IntPtr.Zero);
            PostMessageW(target, 0x0101, (IntPtr)0x11, IntPtr.Zero);
            ks[0x11] = 0; ks[0xA2] = 0; ks[0x10] = 0; ks[0xA0] = 0;
            SetKeyboardState(ks);
            ChordSent = true;
            if (TabsAfter < 0) TabsAfter = TotalTabs(exe);
            note("chord: tabs " + TabsBefore + " -> " + TabsAfter + " after " + ChordLandedMs + "ms (-1 = not within 10s); GetFocus=" + GetFocus());
            AttachThreadInput(myTid, appTid, false);
        } catch (Exception e) {
            note("EXCEPTION " + e.Message);
        } finally {
            // The desktop object lives until the last handle closes AND the
            // last window on it is destroyed; the process is killed by the
            // caller, so just drop our handle.
            if (hDesk != IntPtr.Zero) CloseDesktop(hDesk);
        }
    }

    // --- interactive-desktop side ---
    // A thread created here inherits the PROCESS desktop (the interactive
    // one) - only the spike thread is ever rebound - so this samples exactly
    // what the user is looking at while the spike runs.
    static volatile bool watchStop = false;
    static Thread watchThread = null;
    public static string ForegroundPidsSeen = "";
    public static void StartForegroundWatch() {
        watchStop = false;
        var seen = new System.Collections.Generic.HashSet<uint>();
        watchThread = new Thread(() => {
            while (!watchStop) {
                uint p; GetWindowThreadProcessId(GetForegroundWindow(), out p);
                lock (seen) { seen.Add(p); }
                Thread.Sleep(150);
            }
            var sb = new StringBuilder();
            lock (seen) { foreach (uint p in seen) sb.Append(p).Append(","); }
            ForegroundPidsSeen = sb.ToString();
        });
        watchThread.IsBackground = true;
        watchThread.Start();
    }
    public static void StopForegroundWatch() {
        watchStop = true;
        if (watchThread != null) watchThread.Join(2000);
    }

    public static bool AnyVisibleWindowForPid(uint pid) {
        bool any = false;
        EnumWindows((h, l) => {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p == pid && IsWindowVisible(h)) { any = true; return false; }
            return true;
        }, IntPtr.Zero);
        return any;
    }
    public static uint ForegroundPid() {
        uint p; GetWindowThreadProcessId(GetForegroundWindow(), out p); return p;
    }
}
'@

function Kill-SpikeInstances {
    # T351: the shared, path-exact kill (lib\CleanSlate.ps1). -AppOnly is the
    # point of this helper - the agent (and its PTYs) stay up - and exact-exe is
    # what the private copy's '*zig-out*' filter got wrong: that also matched a
    # detached instance running from zig-out-release (T53b).
    [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
}

# T1280: a FULL reset, not Kill-SpikeInstances. The -AppOnly kill left the
# debug session-layout manifest and the agent's layout store in place, so the
# launch below RESTORED whatever the previous script (or the previous spike)
# left: measured 2026-10-24, the tab count before the chord climbed 2 -> 11
# over successive runs, which made "the chord opened a tab" pass with no chord
# at all, and a restored second window could be the one +list reported as
# windows[0] - the shape of the 2026-09-02 red (no keys seen, tabs=1).
Reset-GhozttyTestState -Exe $exe | Out-Null

# Watch the INTERACTIVE desktop for the whole run: no ghoztty of ours may
# ever become foreground there. This is the user's actual complaint, asserted.
[DeskSpike]::StartForegroundWatch()

Write-Host "--- running spike on desktop 'ghoztty-spike' (the user's desktop must not flicker) ---"
# --cursor-style-blink=false (T2206): CAP-4 diffs the surface before/after the
# posted keys, and a blinking cursor changes it on its own (312 px with no key
# posted, measured 2026-11-24; 0 with blink off, 1030 with the keys).
[DeskSpike]::Run($exe, 'ghoztty-spike', '--window-theme=light --window-show-tab-bar=always --cursor-style-blink=false', 1500)

$spikePid = [DeskSpike]::Pid
Write-Host ([DeskSpike]::Log)

Assert ([DeskSpike]::DesktopCreated) "CreateDesktopW('ghoztty-spike') succeeded"
Assert ([DeskSpike]::ThreadBound) "SetThreadDesktop bound the harness thread to it"
Assert ([DeskSpike]::ProcessStarted) "ghoztty launched with STARTUPINFO.lpDesktop"
Assert ([DeskSpike]::WindowFoundOnTestDesktop) "GhozttyWindow is enumerable ON the test desktop"

# P1/P2: isolation. Enumerating from this thread (still on the interactive
# desktop) must not see it, and it must never have taken foreground here.
if ($spikePid -gt 0) {
    Assert (-not [DeskSpike]::AnyVisibleWindowForPid([uint32]$spikePid)) `
        "the window is NOT enumerable on the interactive desktop"
}

# P3: input reach. Everything below is read back over the spike's own IPC
# endpoint for the window the keys were POSTED to (T1280: by hwnd, never as
# windows[0]), from a run that started on a clean slate.
$pane = [DeskSpike]::Pane
$paneText = ''
try {
    if ($pane) { $paneText = (& $exe +read --name=$pane --lines=10 2>&1 |
        ForEach-Object { $_.ToString() } | Out-String) }
} catch { Write-Host "read error: $_" }
$sawSendInput = [bool]($paneText -match 'SPIKEA')
$si = [DeskSpike]::SendInputAccepted; $sierr = [DeskSpike]::SendInputLastError
$tabsBefore = [DeskSpike]::TabsBefore; $tabsAfter = [DeskSpike]::TabsAfter

# The clean slate, asserted: one fresh tab, and nothing of an earlier run's
# typing on it - otherwise the two input assertions below could pass on
# leftovers (they did, before T1280).
Assert ($pane -and $tabsBefore -eq 1 -and -not [DeskSpike]::PreHadToken) `
    "the app under test answers for the spike's window with one fresh tab (tabs=$tabsBefore, leftover token=$([DeskSpike]::PreHadToken))"
# INPUT-1: SendInput is BLOCKED on a non-input desktop. Asserted, not assumed:
# it is the single fact that decides the harness cannot just be relocated.
Assert ($si -eq 0 -and $sierr -eq 5 -and -not $sawSendInput) `
    "SendInput is blocked on a background desktop (accepted=$si, err=$sierr = ACCESS_DENIED)"
# INPUT-2: posted key messages DO reach the terminal there.
Assert ([DeskSpike]::KeysLandedMs -ge 0) `
    "posted WM_KEYDOWN reaches the terminal on a background desktop (landed after $([DeskSpike]::KeysLandedMs)ms)"
# INPUT-3: and a modifier chord survives the same route (key state set over
# the attached input queue). ctrl+shift+t must have opened exactly one tab -
# counted across every window, since in single-window mode it opens a new
# workspace (T2206; see TotalTabs).
Write-Host "tabs around the posted ctrl+shift+t: $tabsBefore -> $tabsAfter"
Assert ([DeskSpike]::ChordSent -and $tabsBefore -ge 1 -and $tabsAfter -eq ($tabsBefore + 1)) `
    "a posted ctrl+shift+t chord fires its keybind (tabs $tabsBefore -> $tabsAfter, want +1)"

# CAPTURE: the question the whole option was said to hang on.
$bl = [DeskSpike]::BitBltMeanLum; $bd = [DeskSpike]::BitBltDistinct
$pl = [DeskSpike]::PrintMeanLum;  $pd = [DeskSpike]::PrintDistinct
$sl = [DeskSpike]::PrintSurfaceMeanLum; $sd = [DeskSpike]::PrintSurfaceDistinct
$cl = [DeskSpike]::PrintChromeMeanLum;  $cd = [DeskSpike]::PrintChromeDistinct
$zl = [DeskSpike]::PrintPlainMeanLum;   $zd = [DeskSpike]::PrintPlainDistinct
Write-Host "CAPTURE  BitBlt(desktop DC): meanLum=$bl distinct=$bd"
Write-Host "CAPTURE  PrintWindow(FULLCONTENT): meanLum=$pl distinct=$pd"
Write-Host "CAPTURE    terminal surface region: meanLum=$sl distinct=$sd"
Write-Host "CAPTURE    chrome band region:      meanLum=$cl distinct=$cd"
$wl = [DeskSpike]::PrintBelowMeanLum;   $wd = [DeskSpike]::PrintBelowDistinct
Write-Host "CAPTURE    everything below chrome:  meanLum=$wl distinct=$wd"
Write-Host "CAPTURE  PrintWindow(flags=0):     meanLum=$zl distinct=$zd (negative control)"
$bok = [DeskSpike]::BitBltOk
$bcl = [DeskSpike]::BitBltChromeMeanLum; $bcd = [DeskSpike]::BitBltChromeDistinct
Write-Host "CAPTURE    BitBlt ok=$bok chrome band: meanLum=$bcl distinct=$bcd"
# CAP-1: CopyFromScreen/BitBlt is dead there - DWM composes only the input
# desktop, exactly as the task predicted. Recorded so it is not re-tried.
# Scored by the chrome band against PrintWindow's chrome band as the positive
# control (T2208; Test-BitBltDead above), never by a whole-window mean.
Assert (Test-BitBltDead -Ok $bok -ChromeDistinct $bcd -ControlChromeDistinct $cd) `
    "CopyFromScreen/BitBlt off the desktop DC is dead on a background desktop (ok=$bok, chrome distinct=$bcd vs PrintWindow chrome $cd)"

# CAP-2..5 (T1115) replace a single "PrintWindow returns real content" assertion
# that scored the WHOLE window on brightness. That oracle could not tell the two
# outcomes apart: a window whose chrome was captured over a flat client area
# scores the same as one captured whole, because the terminal surface is dark by
# design and fills most of the window. Scored by region, the answer is not the
# one the original ANSWERS block recorded - see the header.
Assert ([DeskSpike]::PrintFullOk) "PrintWindow(PW_RENDERFULLCONTENT) succeeds on a background desktop"
# CAP-3: the CHROME is captured faithfully. This is also the positive control
# for the sampler and the bitmap: if this were flat, CAP-4 would prove nothing.
Assert ($cd -gt 4) `
    "PrintWindow returns the window CHROME on a background desktop (meanLum=$cl, distinct=$cd)"
# CAP-4 (T2206): the terminal SURFACE now comes back COMPOSED. It used to be a
# flat fill (distinct 1-2, T1115) and was asserted flat; measured 2026-11-24 the
# capture holds the shell banner and prompt, legible. A distinct-colour count
# cannot be the oracle any more - glass panes (T1833) put the window gradient
# behind the surface, and a gradient alone scores hundreds of colours - so the
# oracle is CHANGE: the surface rect is diffed between a capture taken before
# the posted keys and one taken after +read reports them. A gradient, a flat
# fill or a stale bitmap all diff to 0; only a surface the renderer is drawing
# into changes. 50 px is well under one glyph run of "spikeb" at any DPI.
$scp = [DeskSpike]::SurfaceChangedPx; $ccp = [DeskSpike]::ChromeChangedPx
Write-Host "CAPTURE    surface px changed by the posted keys: $scp (chrome band: $ccp)"
Assert ([DeskSpike]::KeysLandedMs -ge 0 -and $scp -ge 50) `
    "the terminal SURFACE is composed on a background desktop: the posted keys change it in a PrintWindow capture ($scp px changed)"
# CAP-6: the un-flagged PrintWindow succeeds too. Its region scores are printed
# above for comparison; it is not part of the oracle.
Assert ([DeskSpike]::PrintPlainOk) `
    "PrintWindow(flags=0) also succeeds, so the flag is not what decides this (meanLum=$zl, distinct=$zd)"

if ($spikePid -gt 0) { Stop-Process -Id $spikePid -Force -ErrorAction SilentlyContinue }
Kill-SpikeInstances

# Drain the foreground watcher.
[DeskSpike]::StopForegroundWatch()
$fgSeen = @([DeskSpike]::ForegroundPidsSeen.Split(',') | Where-Object { $_ } | ForEach-Object { [int]$_ })
Write-Host "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if ($spikePid -gt 0) {
    Assert ($fgSeen.Count -gt 0) "the foreground watcher actually sampled (negative control)"
    Assert (-not ($fgSeen -contains [int]$spikePid)) `
        "the test-desktop app NEVER became foreground on the interactive desktop"
}

# The body's last statement (body-complete-audit D1): a throw above skips it,
# so the verdict reads DID NOT FINISH instead of green.
Complete-TestBody

Write-Host ''
# A clean green run stamps the covered files (T783/T1768); red, a skipped arm
# or an unwound body stays due. The row is ADVISORY (see scripts\guard-due.ps1),
# so this stamp is the only way it ever reads current. Continue: a stderr line
# from the native call through 2>&1 must not throw under Stop.
if ($script:fail -eq 0 -and (Test-TestBodyComplete)) {
    $ErrorActionPreference = 'Continue'
    $gdRepo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $gdRepo 'scripts\guard-due.ps1') `
        update -Guard test-desktop-spike -Repo $gdRepo 2>&1 | ForEach-Object { Write-Host "  $_" }
}
Write-TestVerdict -Label 'T207 TEST-DESKTOP SPIKE' -Pass $script:pass -Fail $script:fail
