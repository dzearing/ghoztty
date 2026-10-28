# FrameCapture (T2382) - photograph every frame DWM composes over a rect of the
# screen, timestamp it on QPC, score it on a worker, and say how many composed
# frames the photographs missed. The capture half of the T2373 frame lab.
#
# THE GAP THIS EXISTS FOR. The resize harnesses judge what the app SAYS it drew
# (T2373's Summary). FrameScore.ps1 (T2381) judges what a frame SHOWS; this file
# is what hands it the frames. It has to be honest about two things a casual
# screen grab is not: it must see every composed frame (polling the screen at
# ~10 ms catches a one-frame flash almost never, resize-flicker.ps1's header),
# and when it does NOT see one it must say so, because a measurement that drops
# frames and scores the rest reads green over exactly the frames that bled.
#
# THE MECHANICS (decided in T2373, built here):
#
#   Windows.Graphics.Capture, MONITOR capture, cropped to a rect. Window
#     capture would miss our owned layered popups (scrollbar, dim, bell border,
#     banner), which is bleed class B5; cropping the monitor keeps everything
#     DWM put in that rect. Borderless (IsBorderRequired = false) and no cursor:
#     a yellow border or a pointer inside the crop would be scored as garbage.
#   A free-threaded frame pool sized for the monitor's refresh rate
#     (Get-FrameCaptureBuffers): FrameArrived fires on a pool thread, which
#     copies the crop into a staging texture, reads it back, releases the
#     frame at once and queues the pixels. Nothing slow runs on that thread.
#   The ~60 fps cap lifted: WGC delivers at most ~60 frames a second unless
#     MinUpdateInterval says otherwise (167 frames in 3 s on this 120 Hz box
#     before it was set).
#   QPC timestamps. Each frame carries SystemRelativeTime, converted from
#     100 ns units back to QPC ticks so it sits on the same clock as
#     QueryPerformanceCounter and SendInput timestamps (T2384). Measured here,
#     it is the REFRESH the composition targeted - an exact multiple of the
#     refresh period - not the moment of the present, so it is the frame's
#     display slot. Two frames can share a slot (DWM composed twice for one
#     refresh); the earlier is marked Superseded, since only the later can have
#     been on screen.
#   Online scoring on ONE worker thread with a bounded queue (a byte budget,
#     not a frame count). The scorer is a delegate (GfcScorer) so this file
#     knows nothing of scenes: true = failing. Failing frames and a
#     deterministic sample (every SampleEvery-th frame, 100 = 1%) are written
#     as PNG; every other frame's pixels are dropped once scored, so a long run
#     fits in memory. A frame that does not fit the queue is DROPPED AND
#     COUNTED (QueueDropped) - never silently skipped.
#   Two frame accountants, because the obvious one disturbs what it counts:
#   - SLOT ACCOUNTING on every run (GfcSlots): while a capture is running, DWM
#     composes every refresh even on a static screen (measured: 0 presents in
#     2 s with duplication alone, ~110/s once a capture started), so a refresh
#     with no frame is a refresh nobody got a new frame on. Stats.SlotGaps.
#   - DXGI DESKTOP DUPLICATION on the same monitor (-Duplication), as an
#     ACCOUNTING RUN rather than a passenger: every AcquireNextFrame that
#     carries a present reports LastPresentTime and AccumulatedFrames (> 1 =
#     presents duplication only saw as a count), and GfcAccounting.Compare
#     pairs them with the capture's frames to say exactly which composed frames
#     the capture skipped. It is OFF by default because running it beside a
#     capture made DWM miss about one refresh in six here (50 of 308 steps
#     were two refreshes, against 0-14 of ~360 without it) and delayed each
#     frame's arrival by ~5 ms. So: measure smoothness on capture-only runs;
#     prove the capture's completeness for a cell with a duplication run.
#
# INPUT DESKTOP ONLY. DWM composes only the input desktop, so a session reads
# the user's real screen. This file opens no window and injects nothing; a
# caller that does either is an input-desktop exception (lib\TestDesktop.ps1)
# and gates on lib\UserPresence.ps1 first.
#
# Coordinates are PHYSICAL pixels (Get-FrameCaptureWindowRect reads a window's
# rect per-monitor-DPI-aware via DWMWA_EXTENDED_FRAME_BOUNDS). powershell.exe
# is DPI-unaware, so a plain GetWindowRect would hand back a scaled rect.
#
# WHY csc AND NOT Add-Type: the WinRT projection needs the Windows *.winmd
# metadata as references, and Add-Type tries to LOAD each reference as an
# assembly, which a winmd is not (0x80131047). csc.exe from the framework
# directory compiles against them fine; the dll is cached in %TEMP% by source
# hash, so it compiles once per change.
#
# Acceptance: test\win32\frame-capture.ps1.
# ASCII-only by design (PS 5.1 on this box mangles non-ASCII on rewrite).

$script:FrameCaptureSource = @'
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Threading;
using Windows.Graphics.Capture;
using Windows.Graphics.DirectX;
using Windows.Graphics.DirectX.Direct3D11;

public delegate bool GfcScorer(GfcFrame frame);

// One captured frame, cropped. Px is 0xAARRGGBB per pixel (the B8G8R8A8 layout
// read as little-endian ints - the same layout FsFrame uses). Qpc is DWM's
// composition time on the QPC clock; ArrivalQpc is when FrameArrived saw it.
public sealed class GfcFrame {
    public long Index;
    public long Qpc, ArrivalQpc;
    public int W, H;
    public int[] Px;
    public int ContentW, ContentH;
}

public sealed class GfcFrameMeta {
    public long Index, Qpc, ArrivalQpc;
    public bool Failing, Sampled;
    // A later frame carries the same refresh stamp: DWM composed twice for one
    // refresh, and only the later one can have been on screen.
    public bool Superseded;
    public string Png;
    public override string ToString() {
        return string.Format("#{0} qpc={1} fail={2} sample={3}", Index, Qpc, Failing, Sampled);
    }
}

public sealed class GfcOptions {
    public IntPtr Monitor;
    public int X, Y, W, H;              // crop rect, physical screen coordinates
    public int Buffers = 0;             // 0 = sized from the refresh rate
    public long QueueBytes = 512L * 1024 * 1024;
    public int SampleEvery = 100;       // 0 = no sample
    public string PngDir;               // null = no PNGs
    public int KeepFrames = 0;          // keep this many frames' pixels (tests)
    // OFF by default: duplication beside a capture made DWM miss ~1 refresh
    // in 6 here (see the header), so it is an accounting run, not a passenger.
    public bool Duplication = false;
    public bool DuplicationOnly;        // count presents without capturing
    public GfcScorer Scorer;
    // The WGC-drop positive control (T2392): hold the frame handler, frame
    // still in hand, for StallMs on frame StallAtFrame. With Buffers = 1 the
    // pool has nothing to compose into meanwhile, so WGC must drop presents
    // and the accounting run must name them. -1 = never.
    public long StallAtFrame = -1;
    public int StallMs = 0;
}

public sealed class GfcStats {
    public long Captured, Scored, Failing, Sampled, PngWritten, QueueDropped, MaxQueue;
    public long PoolRecreated, ScorerErrors, FrameErrors;
    public long DdaAcquires, DdaPresents, DdaComposed, DdaPointerOnly, DdaTimeouts, DdaAccessLost;
    public bool BorderlessApplied, CursorDisabled, MinUpdateIntervalSet;
    public int RefreshHz, Buffers, QueueCap;
    public long StartQpc, StopQpc, QpcFrequency;
    public long SlotGaps, SameSlot;     // refreshes with no frame; frames sharing a refresh
    public long StallQpc0, StallQpc1;   // the planted handler stall, when one ran (T2392)
    public string BorderNote = "", DdaNote = "";
    public List<string> Errors = new List<string>();
}

// What the capture missed, from the two timelines.
public sealed class GfcAccount {
    public int Captured;        // capture frames inside the window
    public int DdaPresents;     // duplication acquisitions that carried a present
    public long DdaComposed;    // presents counted by duplication (sum of AccumulatedFrames)
    public int Matched;         // duplication presents a capture frame carries
    public int Unmatched;       // duplication presents NO capture frame carries: skipped
    public long Hidden;         // presents duplication only counted (AccumulatedFrames - 1)
    public long Skipped;        // composed frames the capture never delivered (net, see Compare)
    public int CaptureOnly;     // capture frames the first pass could not pair
    public int Rescued;         // unpaired/hidden presents a nearby capture-only frame carried
    public long OffsetTicks;    // capture stamp minus present stamp, as paired
    public List<long> UnmatchedQpc = new List<long>();
    public List<long> CaptureOnlyQpc = new List<long>();
    public override string ToString() {
        return string.Format("captured={0} dda_presents={1} dda_composed={2} matched={3} unmatched={4} hidden={5} capture_only={6} rescued={7} skipped={8} offset_ticks={9}",
            Captured, DdaPresents, DdaComposed, Matched, Unmatched, Hidden, CaptureOnly, Rescued, Skipped, OffsetTicks);
    }
}

public static class GfcAccounting {
    // Two QPC timelines of the same compositions, stamped at DIFFERENT moments
    // (measured on this box, 120 Hz): a capture frame's SystemRelativeTime
    // sits exactly on the vsync grid, while duplication's LastPresentTime is
    // the present itself, jittering a few ms off that grid. So a present is
    // not matched by equal stamps. First the constant offset between the two
    // is estimated (median over presents of nearest-capture minus present,
    // unless offset is given), then each present is CARRIED by the nearest
    // unused capture frame within tol of present+offset - tol is half a
    // refresh, one slot. Presents outside [t0, t1] are ignored.
    //
    // Skipped = the unpaired and hidden presents that no leftover capture
    // frame could carry (the rescue pass below), and UnmatchedQpc names WHICH
    // presents went missing.
    public static GfcAccount Compare(long[] capture, long[] ddaPresent, int[] ddaAccum, long t0, long t1, long tol) {
        return Compare(capture, ddaPresent, ddaAccum, t0, t1, tol, long.MinValue);
    }

    // tol is three quarters of a refresh by convention, so the period is
    // recovered from it when the caller does not pass one.
    public static GfcAccount Compare(long[] capture, long[] ddaPresent, int[] ddaAccum, long t0, long t1, long tol, long offset) {
        return Compare(capture, ddaPresent, ddaAccum, t0, t1, tol, offset, tol * 4 / 3);
    }

    public static GfcAccount Compare(long[] capture, long[] ddaPresent, int[] ddaAccum, long t0, long t1, long tol, long offset, long period) {
        GfcAccount a = new GfcAccount();
        List<long> cap = new List<long>();
        foreach (long c in capture) if (c >= t0 && c <= t1) cap.Add(c);
        cap.Sort();
        a.Captured = cap.Count;
        List<int> idx = new List<int>();
        for (int i = 0; i < ddaPresent.Length; i++) if (ddaPresent[i] >= t0 && ddaPresent[i] <= t1) idx.Add(i);
        idx.Sort(delegate(int x, int y) { return ddaPresent[x].CompareTo(ddaPresent[y]); });

        if (offset == long.MinValue) {
            List<long> deltas = new List<long>();
            foreach (int i in idx) {
                long t = ddaPresent[i], best = long.MaxValue;
                int k = cap.BinarySearch(t); if (k < 0) k = ~k;
                for (int q = Math.Max(0, k - 1); q <= Math.Min(cap.Count - 1, k); q++)
                    if (Math.Abs(cap[q] - t) < Math.Abs(best)) best = cap[q] - t;
                if (best != long.MaxValue) deltas.Add(best);
            }
            deltas.Sort();
            offset = deltas.Count > 0 ? deltas[deltas.Count / 2] : 0;
        }
        a.OffsetTicks = offset;

        // Order-preserving first fit: both lists are the same compositions in
        // the same order, so a present is carried by the first capture frame
        // after the last pairing that lies within tol of it. Nearest-neighbour
        // pairing cascaded on present jitter here (46 false skips in 311
        // frames whose counts agreed exactly).
        int j = 0;
        foreach (int i in idx) {
            long t = ddaPresent[i] + offset;
            int acc = (ddaAccum != null && i < ddaAccum.Length) ? Math.Max(1, ddaAccum[i]) : 1;
            a.DdaPresents++;
            a.DdaComposed += acc;
            a.Hidden += acc - 1;
            while (j < cap.Count && cap[j] < t - tol) { a.CaptureOnly++; a.CaptureOnlyQpc.Add(cap[j]); j++; }
            if (j < cap.Count && cap[j] <= t + tol) { a.Matched++; j++; }
            else { a.Unmatched++; a.UnmatchedQpc.Add(ddaPresent[i]); }
        }
        for (int k = j; k < cap.Count; k++) { a.CaptureOnly++; a.CaptureOnlyQpc.Add(cap[k]); }

        // Rescue pass. A capture-only frame is a composition the capture DID
        // deliver that the first pass could not pair - the frame for a hidden
        // present (duplication saw it only as a count, up to acc-1 refreshes
        // before the present it reported), the other half of a pairing swap,
        // or a second composition in one refresh. Live runs here read
        // unmatched 1, hidden 2, capture-only 3 with nothing missed. So each
        // outstanding demand (an unpaired present, a hidden present) takes the
        // nearest unused capture-only frame within 1.5 refreshes; what is left
        // is Skipped. No count floor: a same-slot duplicate makes the capture
        // count exceed the composed count, and a floor then swallowed a real
        // skip.
        List<long> demand = new List<long>();
        foreach (long u in a.UnmatchedQpc) demand.Add(u + offset);
        foreach (int i in idx) {
            int acc = (ddaAccum != null && i < ddaAccum.Length) ? Math.Max(1, ddaAccum[i]) : 1;
            for (int h = 1; h < acc; h++) demand.Add(ddaPresent[i] + offset - h * period);
        }
        demand.Sort();
        List<long> spare = new List<long>(a.CaptureOnlyQpc);
        bool[] taken = new bool[spare.Count];
        long win = period + period / 2;
        long left = 0;
        foreach (long d in demand) {
            int best = -1; long bestD = long.MaxValue;
            for (int k = 0; k < spare.Count; k++) {
                if (taken[k]) continue;
                long dd = Math.Abs(spare[k] - d);
                if (dd <= win && dd < bestD) { bestD = dd; best = k; }
            }
            if (best >= 0) { taken[best] = true; a.Rescued++; } else left++;
        }
        a.Skipped = left;
        return a;
    }
}

public static class GfcSlots {
    // A measured run's own completeness, from its refresh stamps alone (no
    // duplication, which perturbs the cadence). While a capture runs DWM
    // composes every refresh even on a static screen (measured: 0 presents in
    // 2 s without a capture, ~110/s with one), so a refresh with no frame is a
    // refresh nobody got a new frame on - DWM missed it, or the capture did.
    // Gaps = refreshes skipped between consecutive frames; SameSlot = frames
    // whose stamp equals the previous one, which marks that previous frame
    // superseded. Stamps must be in delivery order.
    public static void Count(long[] qpc, long period, bool[] superseded, out long gaps, out long same) {
        gaps = 0; same = 0;
        for (int i = 1; i < qpc.Length; i++) {
            long n = (long)Math.Round((double)(qpc[i] - qpc[i - 1]) / period);
            if (n <= 0) { same++; if (superseded != null) superseded[i - 1] = true; }
            else gaps += n - 1;
        }
    }
}

public static class GfcGeometry {
    // The crop box inside a monitor texture: the request rect (screen
    // coordinates) intersected with the monitor rect, in texture coordinates.
    // Returns false when they do not overlap.
    public static bool Crop(int monX, int monY, int monW, int monH, int x, int y, int w, int h, out int bx, out int by, out int bw, out int bh) {
        int x0 = Math.Max(x, monX), y0 = Math.Max(y, monY);
        int x1 = Math.Min(x + w, monX + monW), y1 = Math.Min(y + h, monY + monH);
        bx = x0 - monX; by = y0 - monY; bw = x1 - x0; bh = y1 - y0;
        if (bw <= 0 || bh <= 0) { bx = by = bw = bh = 0; return false; }
        return true;
    }

    // Pool buffers for a refresh rate: enough to cover ~50 ms of composition
    // while a readback is in flight, never fewer than 3 nor more than 12.
    public static int BuffersFor(int hz) {
        if (hz <= 0) hz = 60;
        return Math.Max(3, Math.Min(12, (hz + 19) / 20));
    }

    // Frames that fit a byte budget, never fewer than 8.
    public static int QueueCapFor(long bytes, int w, int h) {
        long per = Math.Max(1L, (long)w * h * 4);
        return (int)Math.Max(8L, Math.Min(100000L, bytes / per));
    }

    public static bool SampleHit(long index, int every) {
        return every > 0 && index % every == 0;
    }
}

// Scorers the acceptance script plants: they make the worker's bookkeeping
// observable without a scene. A real lab run passes a FrameScore bridge.
public static class GfcTestScorers {
    public static GfcScorer EveryNth(int n) { return delegate(GfcFrame f) { return n > 0 && f.Index % n == 0; }; }
    public static GfcScorer Slow(int ms) { return delegate(GfcFrame f) { Thread.Sleep(ms); return false; }; }
    public static GfcScorer ThrowsOn(long index) {
        return delegate(GfcFrame f) { if (f.Index == index) throw new InvalidOperationException("planted scorer fault"); return false; };
    }
}

public static class GfcClock {
    [DllImport("kernel32.dll")] static extern bool QueryPerformanceCounter(out long v);
    [DllImport("kernel32.dll")] static extern bool QueryPerformanceFrequency(out long v);
    static long freq;
    public static long Frequency { get { if (freq == 0) QueryPerformanceFrequency(out freq); return freq; } }
    public static long Now() { long v; QueryPerformanceCounter(out v); return v; }
    // SystemRelativeTime (100 ns units of the QPC clock) back to QPC ticks.
    public static long FromHundredNs(long ticks) {
        long f = Frequency;
        return (long)((decimal)ticks * f / 10000000m);
    }
    public static double Ms(long qpc, long origin) { return (qpc - origin) * 1000.0 / Frequency; }
}

public static class GfcNative {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct MONITORINFOEX { public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szDevice; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra; public int dmFields;
        public int dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
        public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public short dmLogPixels; public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
        public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
    }
    [DllImport("user32.dll")] public static extern IntPtr MonitorFromRect(ref RECT r, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool GetMonitorInfo(IntPtr mon, ref MONITORINFOEX mi);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool EnumDisplaySettings(string dev, int mode, ref DEVMODE dm);
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr ctx);
    [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr hwnd, int attr, out RECT r, int size);

    public static RECT MonitorRect(IntPtr mon, out string device) {
        MONITORINFOEX mi = new MONITORINFOEX(); mi.cbSize = Marshal.SizeOf(typeof(MONITORINFOEX));
        IntPtr old = SetThreadDpiAwarenessContext(new IntPtr(-4));
        try { GetMonitorInfo(mon, ref mi); } finally { if (old != IntPtr.Zero) SetThreadDpiAwarenessContext(old); }
        device = mi.szDevice; return mi.rcMonitor;
    }
    public static int RefreshHz(string device) {
        DEVMODE dm = new DEVMODE(); dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
        return EnumDisplaySettings(device, -1, ref dm) ? dm.dmDisplayFrequency : 0;
    }
    public static IntPtr MonitorFor(int x, int y, int w, int h) {
        RECT r; r.Left = x; r.Top = y; r.Right = x + w; r.Bottom = y + h;
        IntPtr old = SetThreadDpiAwarenessContext(new IntPtr(-4));
        try { return MonitorFromRect(ref r, 2); } finally { if (old != IntPtr.Zero) SetThreadDpiAwarenessContext(old); }
    }
    // A window's visible rect (no invisible resize borders), physical pixels.
    public static int[] WindowRect(IntPtr hwnd) {
        RECT r;
        IntPtr old = SetThreadDpiAwarenessContext(new IntPtr(-4));
        try { if (DwmGetWindowAttribute(hwnd, 9, out r, 16) != 0) return null; }
        finally { if (old != IntPtr.Zero) SetThreadDpiAwarenessContext(old); }
        return new int[] { r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top };
    }
}

// Raw D3D11 / DXGI through their vtables (indices checked against the mingw
// headers: Device.CreateTexture2D 5, GetImmediateContext 40; Context.Map 14,
// Unmap 15, CopySubresourceRegion 46; Factory1.EnumAdapters1 12;
// Adapter.EnumOutputs 7; Output.GetDesc 7; Output1.DuplicateOutput 22;
// Duplication.AcquireNextFrame 8, ReleaseFrame 14).
public static class GfcD3D {
    [StructLayout(LayoutKind.Sequential)] public struct TEX2D { public uint Width, Height, MipLevels, ArraySize, Format, SampleCount, SampleQuality, Usage, BindFlags, CPUAccessFlags, MiscFlags; }
    [StructLayout(LayoutKind.Sequential)] public struct MAPPED { public IntPtr pData; public uint RowPitch, DepthPitch; }
    [StructLayout(LayoutKind.Sequential)] public struct BOX { public uint left, top, front, right, bottom, back; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct OUTDESC { [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName; public GfcNative.RECT Desktop; public int Attached; public int Rotation; public IntPtr Monitor; }
    [StructLayout(LayoutKind.Sequential)]
    public struct DUPINFO { public long LastPresentTime, LastMouseUpdateTime; public uint AccumulatedFrames; public int RectsCoalesced, ProtectedMasked; public int PtrX, PtrY, PtrVisible; public uint MetaSize, ShapeSize; }

    [DllImport("d3d11.dll")] public static extern int D3D11CreateDevice(IntPtr adapter, int driverType, IntPtr software, uint flags, IntPtr levels, uint nLevels, uint sdk, out IntPtr device, out int level, out IntPtr ctx);
    [DllImport("d3d11.dll")] public static extern int CreateDirect3D11DeviceFromDXGIDevice(IntPtr dxgiDevice, out IntPtr inspectable);
    [DllImport("dxgi.dll")] public static extern int CreateDXGIFactory1(ref Guid iid, out IntPtr factory);

    public static readonly Guid IID_IDXGIDevice = new Guid("54ec77fa-1377-44e6-8c32-88fd5f44c84c");
    public static readonly Guid IID_ID3D11Texture2D = new Guid("6f15aaf2-d208-4e89-9ab4-489535d34f9c");
    public static readonly Guid IID_IDXGIFactory1 = new Guid("770aae78-f26f-4dba-a829-253c83d1b387");
    public static readonly Guid IID_IDXGIOutput1 = new Guid("00cddea8-939b-4b83-a340-a685226666cc");

    delegate int CreateTex2D(IntPtr self, ref TEX2D d, IntPtr init, out IntPtr tex);
    delegate void GetCtx(IntPtr self, out IntPtr ctx);
    delegate int MapFn(IntPtr self, IntPtr res, uint sub, int type, uint flags, out MAPPED m);
    delegate void UnmapFn(IntPtr self, IntPtr res, uint sub);
    delegate void CopyRegion(IntPtr self, IntPtr dst, uint dsub, uint x, uint y, uint z, IntPtr src, uint ssub, ref BOX box);
    delegate int EnumAdapters1Fn(IntPtr self, uint i, out IntPtr adapter);
    delegate int EnumOutputsFn(IntPtr self, uint i, out IntPtr output);
    delegate int OutDescFn(IntPtr self, out OUTDESC d);
    delegate int DuplicateFn(IntPtr self, IntPtr device, out IntPtr dup);
    delegate int AcquireFn(IntPtr self, uint ms, out DUPINFO info, out IntPtr res);
    delegate int ReleaseFrameFn(IntPtr self);

    static T Fn<T>(IntPtr com, int slot) where T : class {
        IntPtr vt = Marshal.ReadIntPtr(com);
        return Marshal.GetDelegateForFunctionPointer(Marshal.ReadIntPtr(vt, slot * IntPtr.Size), typeof(T)) as T;
    }

    public static IntPtr CreateDevice(IntPtr adapter) {
        IntPtr dev, ctx; int level;
        // BGRA support (0x20); an explicit adapter needs driver type UNKNOWN (0).
        int hr = D3D11CreateDevice(adapter, adapter == IntPtr.Zero ? 1 : 0, IntPtr.Zero, 0x20, IntPtr.Zero, 0, 7, out dev, out level, out ctx);
        if (hr < 0) throw new COMException("D3D11CreateDevice", hr);
        if (ctx != IntPtr.Zero) Marshal.Release(ctx);
        return dev;
    }
    public static IntPtr Context(IntPtr dev) { IntPtr c; Fn<GetCtx>(dev, 40)(dev, out c); return c; }
    public static IntPtr Staging(IntPtr dev, int w, int h) {
        TEX2D d = new TEX2D(); d.Width = (uint)w; d.Height = (uint)h; d.MipLevels = 1; d.ArraySize = 1;
        d.Format = 87; d.SampleCount = 1; d.Usage = 3; d.CPUAccessFlags = 0x20000;
        IntPtr t; int hr = Fn<CreateTex2D>(dev, 5)(dev, ref d, IntPtr.Zero, out t);
        if (hr < 0) throw new COMException("CreateTexture2D(staging)", hr);
        return t;
    }
    public static void CopyBox(IntPtr ctx, IntPtr dst, IntPtr src, int x, int y, int w, int h) {
        BOX b; b.left = (uint)x; b.top = (uint)y; b.front = 0; b.right = (uint)(x + w); b.bottom = (uint)(y + h); b.back = 1;
        Fn<CopyRegion>(ctx, 46)(ctx, dst, 0, 0, 0, 0, src, 0, ref b);
    }
    public static void ReadInto(IntPtr ctx, IntPtr staging, int w, int h, int[] px) {
        MAPPED m; int hr = Fn<MapFn>(ctx, 14)(ctx, staging, 0, 1, 0, out m);
        if (hr < 0) throw new COMException("Map(staging)", hr);
        try {
            for (int r = 0; r < h; r++)
                Marshal.Copy(new IntPtr(m.pData.ToInt64() + (long)r * m.RowPitch), px, r * w, w);
        } finally { Fn<UnmapFn>(ctx, 15)(ctx, staging, 0); }
    }

    // The adapter + output that drive a monitor, for duplication.
    public static bool FindOutput(IntPtr monitor, out IntPtr adapter, out IntPtr output1) {
        adapter = IntPtr.Zero; output1 = IntPtr.Zero;
        Guid fid = IID_IDXGIFactory1; IntPtr fac;
        if (CreateDXGIFactory1(ref fid, out fac) < 0) return false;
        try {
            for (uint a = 0; ; a++) {
                IntPtr ad; if (Fn<EnumAdapters1Fn>(fac, 12)(fac, a, out ad) < 0) break;
                for (uint o = 0; ; o++) {
                    IntPtr op; if (Fn<EnumOutputsFn>(ad, 7)(ad, o, out op) < 0) break;
                    OUTDESC d; Fn<OutDescFn>(op, 7)(op, out d);
                    if (d.Monitor == monitor) {
                        Guid g = IID_IDXGIOutput1; IntPtr o1;
                        int hr = Marshal.QueryInterface(op, ref g, out o1);
                        Marshal.Release(op);
                        if (hr < 0) { Marshal.Release(ad); return false; }
                        adapter = ad; output1 = o1; return true;
                    }
                    Marshal.Release(op);
                }
                Marshal.Release(ad);
            }
        } finally { Marshal.Release(fac); }
        return false;
    }
    public static int Duplicate(IntPtr output1, IntPtr dev, out IntPtr dup) { return Fn<DuplicateFn>(output1, 22)(output1, dev, out dup); }
    public static int Acquire(IntPtr dup, uint ms, out DUPINFO info, out IntPtr res) { return Fn<AcquireFn>(dup, 8)(dup, ms, out info, out res); }
    public static int ReleaseFrame(IntPtr dup) { return Fn<ReleaseFrameFn>(dup, 14)(dup); }
}

[ComImport, Guid("3628E81B-3CAC-4C60-B7F4-23CE0E0C3356"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IGraphicsCaptureItemInterop {
    IntPtr CreateForWindow([In] IntPtr window, [In] ref Guid iid);
    IntPtr CreateForMonitor([In] IntPtr monitor, [In] ref Guid iid);
}

[ComImport, Guid("A9B3D012-3DF2-4EE3-B8D1-8695F457D3C1"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IDirect3DDxgiInterfaceAccess {
    IntPtr GetInterface([In] ref Guid iid);
}

public sealed class GfcSession : IDisposable {
    readonly GfcOptions opt;
    public readonly GfcStats Stats = new GfcStats();
    public readonly List<GfcFrameMeta> Timeline = new List<GfcFrameMeta>();
    public readonly List<GfcFrame> Kept = new List<GfcFrame>();
    public readonly List<long> DdaPresentQpc = new List<long>();
    public readonly List<int> DdaAccum = new List<int>();

    IntPtr dev, ctx, staging;
    IDirect3DDevice rtDevice;
    GraphicsCaptureItem item;
    Direct3D11CaptureFramePool pool;
    GraphicsCaptureSession session;
    int bx, by, bw, bh, contentW, contentH;
    long index;
    readonly object gpu = new object();
    BlockingCollection<GfcFrame> queue;
    Thread worker, ddaThread;
    volatile bool stopping;
    ManualResetEvent ddaReady = new ManualResetEvent(false);

    static readonly Guid IID_IGraphicsCaptureItem = new Guid("79C3F95B-31F7-4EC2-A464-632EF5D30760");

    public GfcSession(GfcOptions o) { opt = o; }

    public static bool Supported() { return GraphicsCaptureSession.IsSupported(); }

    public void Start() {
        Stats.QpcFrequency = GfcClock.Frequency;
        IntPtr mon = opt.Monitor != IntPtr.Zero ? opt.Monitor : GfcNative.MonitorFor(opt.X, opt.Y, opt.W, opt.H);
        string devName; GfcNative.RECT mr = GfcNative.MonitorRect(mon, out devName);
        Stats.RefreshHz = GfcNative.RefreshHz(devName);
        if (!GfcGeometry.Crop(mr.Left, mr.Top, mr.Right - mr.Left, mr.Bottom - mr.Top, opt.X, opt.Y, opt.W, opt.H, out bx, out by, out bw, out bh))
            throw new InvalidOperationException("the crop rect is not on the monitor that holds it");
        Stats.Buffers = opt.Buffers > 0 ? opt.Buffers : GfcGeometry.BuffersFor(Stats.RefreshHz);
        Stats.QueueCap = GfcGeometry.QueueCapFor(opt.QueueBytes, bw, bh);
        queue = new BlockingCollection<GfcFrame>(new ConcurrentQueue<GfcFrame>());
        if (!string.IsNullOrEmpty(opt.PngDir)) Directory.CreateDirectory(opt.PngDir);

        IntPtr adapter = IntPtr.Zero, output1 = IntPtr.Zero;
        bool haveOut = GfcD3D.FindOutput(mon, out adapter, out output1);
        dev = GfcD3D.CreateDevice(haveOut ? adapter : IntPtr.Zero);
        ctx = GfcD3D.Context(dev);
        staging = GfcD3D.Staging(dev, bw, bh);

        Guid g = GfcD3D.IID_IDXGIDevice; IntPtr dxgi;
        Marshal.ThrowExceptionForHR(Marshal.QueryInterface(dev, ref g, out dxgi));
        IntPtr insp;
        try { Marshal.ThrowExceptionForHR(GfcD3D.CreateDirect3D11DeviceFromDXGIDevice(dxgi, out insp)); }
        finally { Marshal.Release(dxgi); }
        rtDevice = (IDirect3DDevice)Marshal.GetObjectForIUnknown(insp);
        Marshal.Release(insp);

        IGraphicsCaptureItemInterop interop = (IGraphicsCaptureItemInterop)WindowsRuntimeMarshal.GetActivationFactory(typeof(GraphicsCaptureItem));
        Guid gi = IID_IGraphicsCaptureItem;
        IntPtr ip = interop.CreateForMonitor(mon, ref gi);
        item = (GraphicsCaptureItem)Marshal.GetObjectForIUnknown(ip);
        Marshal.Release(ip);
        contentW = item.Size.Width; contentH = item.Size.Height;

        pool = Direct3D11CaptureFramePool.CreateFreeThreaded(rtDevice, DirectXPixelFormat.B8G8R8A8UIntNormalized, Stats.Buffers, item.Size);
        pool.FrameArrived += OnFrame;
        session = pool.CreateCaptureSession(item);
        try { session.IsCursorCaptureEnabled = false; Stats.CursorDisabled = true; } catch (Exception e) { Stats.Errors.Add("cursor: " + e.Message); }
        try { session.IsBorderRequired = false; Stats.BorderlessApplied = !session.IsBorderRequired; }
        catch (Exception e) { Stats.BorderNote = e.GetType().Name + ": " + e.Message; }
        // WGC delivers at most ~60 fps unless told otherwise: on a 120 Hz
        // monitor the first run here captured 167 frames in 3 s while
        // duplication counted 345 presents. MinUpdateInterval (Windows 11
        // 24H2+) lifts the cap; reflection so the source still compiles against
        // older metadata, where the cap stays and the cross-check reports it.
        try {
            System.Reflection.PropertyInfo mui = typeof(GraphicsCaptureSession).GetProperty("MinUpdateInterval");
            if (mui != null) { mui.SetValue(session, TimeSpan.FromTicks(10000), null); Stats.MinUpdateIntervalSet = true; }
            else Stats.Errors.Add("MinUpdateInterval: not in this Windows' metadata; capture is capped near 60 fps");
        } catch (Exception e) { Stats.Errors.Add("MinUpdateInterval: " + e.Message); }

        worker = new Thread(Work); worker.IsBackground = true; worker.Name = "gfc-score"; worker.Start();
        if (opt.Duplication) {
            if (haveOut) {
                IntPtr a2 = adapter, o2 = output1;
                ddaThread = new Thread(delegate() { Duplicate(a2, o2); });
                ddaThread.IsBackground = true; ddaThread.Name = "gfc-dda"; ddaThread.Start();
                ddaReady.WaitOne(3000);
            } else { Stats.DdaNote = "no DXGI output drives this monitor"; }
        } else {
            if (output1 != IntPtr.Zero) Marshal.Release(output1);
        }
        if (adapter != IntPtr.Zero && !opt.Duplication) Marshal.Release(adapter);

        Stats.StartQpc = GfcClock.Now();
        if (!opt.DuplicationOnly) session.StartCapture();
    }

    // Runs on a pool thread. Nothing may throw out of here (an unhandled
    // exception on a pool thread ends the process), and every frame that
    // arrives is either queued or counted as dropped.
    void OnFrame(Direct3D11CaptureFramePool sender, object args) {
        long arrival = GfcClock.Now();
        try {
            using (Direct3D11CaptureFrame f = sender.TryGetNextFrame()) {
                if (f == null) return;
                long qpc = GfcClock.FromHundredNs(f.SystemRelativeTime.Ticks);
                int cw = f.ContentSize.Width, ch = f.ContentSize.Height;
                GfcFrame fr = new GfcFrame();
                fr.Qpc = qpc; fr.ArrivalQpc = arrival; fr.W = bw; fr.H = bh; fr.ContentW = cw; fr.ContentH = ch;
                lock (gpu) {
                    if (!Admit(fr)) return;
                    IDirect3DDxgiInterfaceAccess acc = (IDirect3DDxgiInterfaceAccess)(object)f.Surface;
                    Guid tg = GfcD3D.IID_ID3D11Texture2D;
                    IntPtr tex = acc.GetInterface(ref tg);
                    try {
                        GfcD3D.CopyBox(ctx, staging, tex, bx, by, bw, bh);
                        fr.Px = new int[bw * bh];
                        GfcD3D.ReadInto(ctx, staging, bw, bh, fr.Px);
                    } finally { Marshal.Release(tex); }
                    Enqueue(fr);
                }
                if (opt.StallAtFrame >= 0 && fr.Index == opt.StallAtFrame && opt.StallMs > 0) {
                    Stats.StallQpc0 = GfcClock.Now();
                    Thread.Sleep(opt.StallMs);
                    Stats.StallQpc1 = GfcClock.Now();
                }
                if (cw != contentW || ch != contentH) {
                    contentW = cw; contentH = ch; Stats.PoolRecreated++;
                    sender.Recreate(rtDevice, DirectXPixelFormat.B8G8R8A8UIntNormalized, Stats.Buffers, f.ContentSize);
                }
            }
        } catch (Exception e) {
            lock (Stats.Errors) { Stats.FrameErrors++; if (Stats.Errors.Count < 20) Stats.Errors.Add("frame: " + e.Message); }
        }
    }

    // Under the gpu lock: number the frame and count it, or count it dropped
    // when the scoring queue is full or the session is stopping.
    bool Admit(GfcFrame fr) {
        if (stopping) return false;
        fr.Index = index++;
        Stats.Captured++;
        if (queue.Count >= Stats.QueueCap) { Stats.QueueDropped++; return false; }
        return true;
    }

    void Enqueue(GfcFrame fr) {
        queue.Add(fr);
        long q = queue.Count; if (q > Stats.MaxQueue) Stats.MaxQueue = q;
    }

    // The scoring half without a capture: the acceptance script feeds frames
    // through the same admission, queue and worker a capture uses, so the
    // bookkeeping (drops, sampling, PNGs, scorer faults) is proved without
    // reading the screen.
    public void StartWorkerOnly(int w, int h) {
        Stats.QpcFrequency = GfcClock.Frequency;
        bw = w; bh = h;
        Stats.QueueCap = GfcGeometry.QueueCapFor(opt.QueueBytes, bw, bh);
        queue = new BlockingCollection<GfcFrame>(new ConcurrentQueue<GfcFrame>());
        if (!string.IsNullOrEmpty(opt.PngDir)) Directory.CreateDirectory(opt.PngDir);
        worker = new Thread(Work); worker.IsBackground = true; worker.Name = "gfc-score"; worker.Start();
        Stats.StartQpc = GfcClock.Now();
    }

    public bool Feed(int[] px, long qpc) {
        GfcFrame fr = new GfcFrame();
        fr.Qpc = qpc; fr.ArrivalQpc = GfcClock.Now(); fr.W = bw; fr.H = bh;
        lock (gpu) {
            if (!Admit(fr)) return false;
            fr.Px = (int[])px.Clone();
            Enqueue(fr);
        }
        return true;
    }

    void Work() {
        foreach (GfcFrame f in queue.GetConsumingEnumerable()) {
            bool failing = false;
            if (opt.Scorer != null) {
                try { failing = opt.Scorer(f); }
                catch (Exception e) { Stats.ScorerErrors++; if (Stats.Errors.Count < 20) Stats.Errors.Add("scorer: " + e.Message); failing = true; }
            }
            bool sampled = GfcGeometry.SampleHit(f.Index, opt.SampleEvery);
            GfcFrameMeta m = new GfcFrameMeta();
            m.Index = f.Index; m.Qpc = f.Qpc; m.ArrivalQpc = f.ArrivalQpc; m.Failing = failing; m.Sampled = sampled;
            if ((failing || sampled) && !string.IsNullOrEmpty(opt.PngDir)) {
                try { m.Png = WritePng(f, Path.Combine(opt.PngDir, string.Format("f{0:D6}-{1}.png", f.Index, failing ? "fail" : "sample"))); Stats.PngWritten++; }
                catch (Exception e) { if (Stats.Errors.Count < 20) Stats.Errors.Add("png: " + e.Message); }
            }
            lock (Timeline) {
                Timeline.Add(m);
                Stats.Scored++; if (failing) Stats.Failing++; if (sampled) Stats.Sampled++;
                if (Kept.Count < opt.KeepFrames) Kept.Add(f); else f.Px = null;
            }
        }
    }

    public static string WritePng(GfcFrame f, string path) {
        using (Bitmap b = new Bitmap(f.W, f.H, PixelFormat.Format32bppRgb)) {
            BitmapData d = b.LockBits(new Rectangle(0, 0, f.W, f.H), ImageLockMode.WriteOnly, PixelFormat.Format32bppRgb);
            try {
                for (int r = 0; r < f.H; r++) Marshal.Copy(f.Px, r * f.W, new IntPtr(d.Scan0.ToInt64() + (long)r * d.Stride), f.W);
            } finally { b.UnlockBits(d); }
            b.Save(path, ImageFormat.Png);
        }
        return path;
    }

    void Duplicate(IntPtr adapter, IntPtr output1) {
        IntPtr ddev = IntPtr.Zero, dup = IntPtr.Zero;
        try {
            ddev = GfcD3D.CreateDevice(adapter);
            int hr = GfcD3D.Duplicate(output1, ddev, out dup);
            if (hr < 0) { Stats.DdaNote = string.Format("DuplicateOutput 0x{0:X8}", hr); return; }
            ddaReady.Set();
            while (!stopping) {
                GfcD3D.DUPINFO info; IntPtr res;
                hr = GfcD3D.Acquire(dup, 50, out info, out res);
                if (hr == unchecked((int)0x887A0027)) { Stats.DdaTimeouts++; continue; }
                if (hr == unchecked((int)0x887A0026)) {
                    // Access lost (mode change, secure desktop): re-duplicate.
                    Stats.DdaAccessLost++;
                    Marshal.Release(dup); dup = IntPtr.Zero;
                    Thread.Sleep(20);
                    if (GfcD3D.Duplicate(output1, ddev, out dup) < 0) { dup = IntPtr.Zero; Stats.DdaNote = "access lost and not regained"; return; }
                    continue;
                }
                if (hr < 0) { Stats.DdaNote = string.Format("AcquireNextFrame 0x{0:X8}", hr); return; }
                Stats.DdaAcquires++;
                if (info.LastPresentTime != 0) {
                    lock (DdaPresentQpc) { DdaPresentQpc.Add(info.LastPresentTime); DdaAccum.Add((int)Math.Max(1, info.AccumulatedFrames)); }
                    Stats.DdaPresents++; Stats.DdaComposed += Math.Max(1, info.AccumulatedFrames);
                } else Stats.DdaPointerOnly++;
                if (res != IntPtr.Zero) Marshal.Release(res);
                GfcD3D.ReleaseFrame(dup);
            }
        } catch (Exception e) {
            Stats.DdaNote = "duplication: " + e.Message;
        } finally {
            ddaReady.Set();
            if (dup != IntPtr.Zero) Marshal.Release(dup);
            if (ddev != IntPtr.Zero) Marshal.Release(ddev);
            Marshal.Release(output1); Marshal.Release(adapter);
        }
    }

    // Stop capturing, drain the scorer, and return the stats. Frames composed
    // after this call are not counted on either side.
    public GfcStats Stop() {
        if (stopping) return Stats;
        Stats.StopQpc = GfcClock.Now();
        stopping = true;
        try { if (session != null) session.Dispose(); } catch (Exception e) { Stats.Errors.Add("session: " + e.Message); }
        lock (gpu) { }
        if (queue != null) queue.CompleteAdding();
        if (worker != null) worker.Join();
        if (ddaThread != null) ddaThread.Join(2000);
        if (Stats.RefreshHz > 0) {
            lock (Timeline) {
                long[] q = new long[Timeline.Count];
                for (int i = 0; i < q.Length; i++) q[i] = Timeline[i].Qpc;
                bool[] sup = new bool[q.Length];
                GfcSlots.Count(q, GfcClock.Frequency / Stats.RefreshHz, sup, out Stats.SlotGaps, out Stats.SameSlot);
                for (int i = 0; i < sup.Length; i++) Timeline[i].Superseded = sup[i];
            }
        }
        return Stats;
    }

    // Pairs on ArrivalQpc, not Qpc. Measured here at 120 Hz: SystemRelativeTime
    // is the vsync slot DWM targeted (an exact 8.333 ms grid), while the
    // compositions themselves landed ~9 ms apart and drifted against that grid
    // by up to a whole refresh before snapping back - so slot stamps and
    // present stamps disagree by a varying amount. FrameArrived fired a steady
    // ~1.2 ms before duplication's LastPresentTime for every frame, so the
    // arrival is what lines up with a present. Qpc stays the frame's display
    // slot, which is what the motion metrics want.
    public GfcAccount Account(double tolMs) {
        long[] cap; lock (Timeline) { cap = new long[Timeline.Count]; for (int i = 0; i < cap.Length; i++) cap[i] = Timeline[i].ArrivalQpc; }
        long[] dp; int[] da;
        lock (DdaPresentQpc) { dp = DdaPresentQpc.ToArray(); da = DdaAccum.ToArray(); }
        // tolMs <= 0: three quarters of a refresh. Half a refresh left 3-4
        // false skips per 320 frames here (an arrival delayed past the slot
        // edge); order-preserving pairing keeps a really missing frame
        // unmatched at 0.75, because the next present is a full period on.
        if (tolMs <= 0) tolMs = 750.0 / (Stats.RefreshHz > 0 ? Stats.RefreshHz : 60);
        long tol = (long)(tolMs * GfcClock.Frequency / 1000.0);
        // Queue-dropped frames are not in the timeline, so they read as skipped
        // here too - correctly: nobody scored them. Stats.QueueDropped says
        // which side of the engine lost them.
        long period = GfcClock.Frequency / (Stats.RefreshHz > 0 ? Stats.RefreshHz : 60);
        return GfcAccounting.Compare(cap, dp, da, Stats.StartQpc, Stats.StopQpc, tol, long.MinValue, period);
    }

    public void Dispose() {
        Stop();
        try { if (pool != null) pool.Dispose(); } catch { }
        if (staging != IntPtr.Zero) { Marshal.Release(staging); staging = IntPtr.Zero; }
        if (ctx != IntPtr.Zero) { Marshal.Release(ctx); ctx = IntPtr.Zero; }
        if (dev != IntPtr.Zero) { Marshal.Release(dev); dev = IntPtr.Zero; }
    }
}
'@

# Compile once per source change; the dll lives in %TEMP% keyed by the hash.
function Import-FrameCapture {
    if ('GfcSession' -as [type]) { return }
    Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hash = -join ($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($script:FrameCaptureSource))[0..7] | ForEach-Object { $_.ToString('x2') })
    $dir = Join-Path $env:TEMP 'ghoztty-framecapture'
    $dll = Join-Path $dir "gfc-$hash.dll"
    if (-not (Test-Path $dll)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $src = Join-Path $dir "gfc-$hash.cs"
        [System.IO.File]::WriteAllText($src, $script:FrameCaptureSource, (New-Object System.Text.UTF8Encoding $false))
        $fw = [System.Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()
        $wm = Join-Path $env:SystemRoot 'System32\WinMetadata'
        $csc = Join-Path $fw 'csc.exe'
        $tmp = "$dll.$PID.tmp"
        $out = & $csc /nologo /target:library /optimize+ "/out:$tmp" `
            "/r:$(Join-Path $wm 'Windows.Foundation.winmd')" "/r:$(Join-Path $wm 'Windows.Graphics.winmd')" `
            "/r:$(Join-Path $fw 'System.Runtime.WindowsRuntime.dll')" "/r:$(Join-Path $fw 'System.Runtime.dll')" `
            "/r:$(Join-Path $fw 'System.Runtime.InteropServices.WindowsRuntime.dll')" `
            "/r:$(Join-Path $fw 'System.Drawing.dll')" $src 2>&1
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $tmp)) {
            throw "FrameCapture: csc failed ($LASTEXITCODE): $($out -join ' | ')"
        }
        Move-Item -Force $tmp $dll
    }
    [System.Reflection.Assembly]::LoadFrom($dll) | Out-Null
}

# A window's visible rect in physical pixels: x, y, w, h (null if not a window).
function Get-FrameCaptureWindowRect([IntPtr]$Hwnd) {
    Import-FrameCapture
    return [GfcNative]::WindowRect($Hwnd)
}

# Start capturing the screen rect X,Y,W,H. -Scorer is a GfcScorer (C# - it runs
# on the worker thread, where a PowerShell scriptblock has no runspace).
function Start-FrameCapture {
    param(
        [Parameter(Mandatory = $true)][int]$X, [Parameter(Mandatory = $true)][int]$Y,
        [Parameter(Mandatory = $true)][int]$W, [Parameter(Mandatory = $true)][int]$H,
        [string]$PngDir, [int]$SampleEvery = 100, [int]$KeepFrames = 0,
        [long]$QueueBytes = 512MB, [int]$Buffers = 0, [switch]$Duplication,
        $Scorer, [long]$StallAtFrame = -1, [int]$StallMs = 0
    )
    Import-FrameCapture
    $o = New-FrameCaptureOptions -PngDir $PngDir -SampleEvery $SampleEvery -KeepFrames $KeepFrames -QueueBytes $QueueBytes -Scorer $Scorer
    $o.X = $X; $o.Y = $Y; $o.W = $W; $o.H = $H
    $o.Buffers = $Buffers; $o.Duplication = [bool]$Duplication
    $o.StallAtFrame = $StallAtFrame; $o.StallMs = $StallMs
    $s = New-Object GfcSession $o
    $s.Start()
    return $s
}

function New-FrameCaptureOptions {
    param([string]$PngDir, [int]$SampleEvery = 100, [int]$KeepFrames = 0, [long]$QueueBytes = 512MB, $Scorer)
    Import-FrameCapture
    $o = New-Object GfcOptions
    $o.PngDir = $PngDir; $o.SampleEvery = $SampleEvery; $o.KeepFrames = $KeepFrames; $o.QueueBytes = $QueueBytes
    if ($Scorer) { $o.Scorer = $Scorer }
    return $o
}

# The scoring worker alone, fed by the caller (GfcSession.Feed) - no capture.
function Start-FrameCaptureWorker {
    param([Parameter(Mandatory = $true)][int]$W, [Parameter(Mandatory = $true)][int]$H,
        [string]$PngDir, [int]$SampleEvery = 100, [int]$KeepFrames = 0, [long]$QueueBytes = 512MB, $Scorer)
    $o = New-FrameCaptureOptions -PngDir $PngDir -SampleEvery $SampleEvery -KeepFrames $KeepFrames -QueueBytes $QueueBytes -Scorer $Scorer
    $s = New-Object GfcSession $o
    $s.StartWorkerOnly($W, $H)
    return $s
}

# Stop, drain, and account: Stats plus what the capture skipped. -TolMs is how
# close a capture frame's stamp must be to an (offset-corrected) duplication
# present to carry it; 0 = half a refresh period.
function Stop-FrameCapture {
    param([Parameter(Mandatory = $true)]$Session, [double]$TolMs = 0)
    $stats = $Session.Stop()
    $acct = $Session.Account($TolMs)
    return [pscustomobject]@{ Stats = $stats; Account = $acct; Timeline = $Session.Timeline; Kept = $Session.Kept }
}
