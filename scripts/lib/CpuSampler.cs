// CpuSampler - a user-mode sampling CPU profiler for another process (T3159).
//
// Why it exists: a kernel ETW trace (wpr -start CPU) needs an elevated shell,
// and the loop never has one. This needs only the access any same-user
// process already grants: suspend a thread, read its registers, walk its
// stack with dbghelp, resume it.
//
// How a sample is taken (oncpu mode, the default): every tick, each thread's
// cycle counter (QueryThreadCycleTime) is read twice, ~30 us apart. The
// counter of a thread that is on a CPU right now - user or kernel mode -
// advances live between the two reads; a blocked thread's does not. Only
// on-CPU threads are suspended and walked, and each walk counts one tick, so
// a function's share of a process's samples is its share of that process's
// on-CPU time. (Measured: a spinning thread moved in 200 of 200 windows, its
// 24 idle siblings in 0.)
//
// cycles mode (the first design, kept for comparison): every thread whose
// counter moved since the last tick is walked wherever it stands and charged
// those cycles. It is biased on purpose-built relay code: a thread that runs
// a 40 us burst per chunk and then blocks is nearly always caught parked, so
// its bursts are charged to the wait (T3159's first profile read 85% "wait"
// for exactly that reason).
//
// Driven by scripts\cpu-sample.ps1; loaded with Add-Type.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public class CpuSampleThread
{
    public int Tid;
    public string Name = "";
    public double Cycles;
    public int Samples;
}

public class CpuSampleProcess
{
    public int Pid;
    public string Image = "";
    public double FirstSeenMs;
    public double LastSeenMs;
    public bool Exited;
    public double CpuSeconds;        // process CPU from first sight to last sight
    public double Cycles;            // thread cycles observed (all hot ticks)
    public double WalkedCycles;      // of those, the ones charged to a walked stack
    public int Samples;
    public int WalkFailures;
    public Dictionary<string, double> Self = new Dictionary<string, double>();
    public Dictionary<string, double> Inclusive = new Dictionary<string, double>();
    public Dictionary<string, double> Lines = new Dictionary<string, double>();
    public Dictionary<string, double> Folded = new Dictionary<string, double>();
    public Dictionary<int, CpuSampleThread> Threads = new Dictionary<int, CpuSampleThread>();
}

public static class CpuSampler
{
    const uint PROCESS_QUERY_INFORMATION = 0x0400, PROCESS_VM_READ = 0x0010, SYNCHRONIZE = 0x00100000;
    const uint THREAD_SUSPEND_RESUME = 0x0002, THREAD_GET_CONTEXT = 0x0008, THREAD_QUERY_INFORMATION = 0x0040;
    const uint CONTEXT_FULL_AMD64 = 0x0010000B;
    const uint IMAGE_FILE_MACHINE_AMD64 = 0x8664;

    [DllImport("kernel32", SetLastError = true)] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32", SetLastError = true)] static extern IntPtr OpenThread(uint access, bool inherit, int tid);
    [DllImport("kernel32")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32")] static extern uint SuspendThread(IntPtr h);
    [DllImport("kernel32")] static extern uint ResumeThread(IntPtr h);
    [DllImport("kernel32", SetLastError = true)] static extern bool GetThreadContext(IntPtr h, IntPtr ctx);
    [DllImport("kernel32")] static extern bool QueryThreadCycleTime(IntPtr h, out ulong cycles);
    [DllImport("kernel32")] static extern bool GetProcessTimes(IntPtr h, out long c, out long e, out long k, out long u);
    [DllImport("kernel32")] static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32", CharSet = CharSet.Unicode)] static extern int GetThreadDescription(IntPtr h, out IntPtr desc);
    [DllImport("kernel32")] static extern IntPtr LocalFree(IntPtr p);
    [DllImport("kernel32", CharSet = CharSet.Unicode)] static extern IntPtr LoadLibraryW(string n);
    [DllImport("kernel32", CharSet = CharSet.Ansi)] static extern IntPtr GetProcAddress(IntPtr m, string name);
    [DllImport("winmm")] static extern uint timeBeginPeriod(uint ms);
    [DllImport("winmm")] static extern uint timeEndPeriod(uint ms);
    [DllImport("psapi", CharSet = CharSet.Unicode)] static extern uint GetModuleBaseNameW(IntPtr hp, IntPtr hm, StringBuilder sb, int n);

    [DllImport("dbghelp", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool SymInitializeW(IntPtr h, string path, bool invade);
    [DllImport("dbghelp")] static extern uint SymSetOptions(uint o);
    [DllImport("dbghelp")] static extern bool SymCleanup(IntPtr h);
    [DllImport("dbghelp")] static extern bool SymRefreshModuleList(IntPtr h);
    [DllImport("dbghelp", SetLastError = true)] static extern bool StackWalk64(uint machine, IntPtr hp, IntPtr ht, IntPtr frame, IntPtr ctx, IntPtr readMem, IntPtr ftab, IntPtr modbase, IntPtr xlat);
    [DllImport("dbghelp", CharSet = CharSet.Unicode)] static extern bool SymFromAddrW(IntPtr h, ulong addr, out ulong disp, IntPtr sym);
    [DllImport("dbghelp", CharSet = CharSet.Unicode)] static extern bool SymGetLineFromAddrW64(IntPtr h, ulong addr, out uint disp, IntPtr line);
    [DllImport("dbghelp")] static extern ulong SymGetModuleBase64(IntPtr h, ulong addr);

    class Thr { public int Tid; public IntPtr H; public ulong Last; public CpuSampleThread Rep; }
    class Proc
    {
        public IntPtr H; public CpuSampleProcess Rep; public Dictionary<int, Thr> Thr = new Dictionary<int, Thr>();
        public Dictionary<ulong, string> Sym = new Dictionary<ulong, string>();
        public Dictionary<ulong, string> Line = new Dictionary<ulong, string>();
        public Dictionary<ulong, string> Mod = new Dictionary<ulong, string>();
        public long Cpu0; public long CpuLast; public double LastModRefreshMs = -1e9;
    }

    static IntPtr ftab, modbase, symBuf, lineBuf, frameBuf, ctxRaw, ctx;

    static long CpuOf(IntPtr h)
    {
        long c, e, k, u;
        return GetProcessTimes(h, out c, out e, out k, out u) ? k + u : 0;
    }

    static string ModName(Proc p, ulong addr)
    {
        ulong b = SymGetModuleBase64(p.H, addr);
        if (b == 0) return "?";
        string n;
        if (p.Mod.TryGetValue(b, out n)) return n;
        var sb = new StringBuilder(260);
        n = GetModuleBaseNameW(p.H, (IntPtr)(long)b, sb, 260) > 0 ? sb.ToString() : ("0x" + b.ToString("x"));
        if (n.EndsWith(".dll", StringComparison.OrdinalIgnoreCase) || n.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) n = n.Substring(0, n.Length - 4);
        p.Mod[b] = n;
        return n;
    }

    static string Resolve(Proc p, ulong addr, double nowMs)
    {
        string s;
        if (p.Sym.TryGetValue(addr, out s)) return s;
        Marshal.WriteInt32(symBuf, 0, 88);       // SYMBOL_INFOW.SizeOfStruct
        Marshal.WriteInt32(symBuf, 80, 512);     // MaxNameLen
        ulong disp;
        bool ok = SymFromAddrW(p.H, addr, out disp, symBuf);
        if (!ok && nowMs - p.LastModRefreshMs > 1000)
        {
            // A module loaded after SymInitialize (a lazily loaded DLL).
            SymRefreshModuleList(p.H);
            p.LastModRefreshMs = nowMs;
            ok = SymFromAddrW(p.H, addr, out disp, symBuf);
        }
        string mod = ModName(p, addr);
        if (ok)
        {
            int len = Marshal.ReadInt32(symBuf, 76); // NameLen
            s = mod + "!" + Marshal.PtrToStringUni(new IntPtr(symBuf.ToInt64() + 84), Math.Min(len, 512));
        }
        else
        {
            ulong b = SymGetModuleBase64(p.H, addr);
            s = b != 0 ? mod + "+0x" + (addr - b).ToString("x") : "0x" + addr.ToString("x");
        }
        p.Sym[addr] = s;
        return s;
    }

    static string ResolveLine(Proc p, ulong addr)
    {
        string s;
        if (p.Line.TryGetValue(addr, out s)) return s;
        Marshal.WriteInt32(lineBuf, 0, 40);      // IMAGEHLP_LINEW64.SizeOfStruct
        uint disp;
        s = null;
        if (SymGetLineFromAddrW64(p.H, addr, out disp, lineBuf))
        {
            int ln = Marshal.ReadInt32(lineBuf, 16);
            IntPtr fn = Marshal.ReadIntPtr(lineBuf, 24);
            string f = fn == IntPtr.Zero ? "?" : Marshal.PtrToStringUni(fn);
            s = f + ":" + ln;
        }
        p.Line[addr] = s;
        return s;
    }

    static bool Matches(int pid, string imagePath, out IntPtr h)
    {
        h = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ | SYNCHRONIZE, false, pid);
        if (h == IntPtr.Zero) return false;
        if (string.IsNullOrEmpty(imagePath)) return true;
        try
        {
            var p = Process.GetProcessById(pid);
            string f = p.MainModule.FileName;
            if (string.Equals(Path.GetFullPath(f), Path.GetFullPath(imagePath), StringComparison.OrdinalIgnoreCase)) return true;
        }
        catch { }
        CloseHandle(h);
        h = IntPtr.Zero;
        return false;
    }

    // Sample every process whose image is `imagePath` (re-scanned every 250 ms,
    // so a process born during the run - a session holder - is picked up), or
    // exactly `pids` when imagePath is empty. Stops after durationMs, or once
    // stopFile exists.
    public static List<CpuSampleProcess> Run(string imagePath, int[] pids, int durationMs, int intervalMs, string stopFile, string symPath, int maxFrames)
    {
        return Run(imagePath, pids, durationMs, intervalMs, stopFile, symPath, maxFrames, true);
    }

    public static List<CpuSampleProcess> Run(string imagePath, int[] pids, int durationMs, int intervalMs, string stopFile, string symPath, int maxFrames, bool onCpu)
    {
        IntPtr dbg = LoadLibraryW("dbghelp.dll");
        ftab = GetProcAddress(dbg, "SymFunctionTableAccess64");
        modbase = GetProcAddress(dbg, "SymGetModuleBase64");
        symBuf = Marshal.AllocHGlobal(88 + 1040);
        lineBuf = Marshal.AllocHGlobal(64);
        frameBuf = Marshal.AllocHGlobal(512);
        ctxRaw = Marshal.AllocHGlobal(1232 + 32);
        ctx = new IntPtr((ctxRaw.ToInt64() + 15) & ~15L);
        SymSetOptions(0x2 | 0x4 | 0x10 | 0x200 | 0x80000); // UNDNAME|DEFERRED_LOADS|LOAD_LINES|FAIL_CRITICAL_ERRORS|NO_PROMPTS

        var procs = new Dictionary<int, Proc>();
        var done = new List<CpuSampleProcess>();
        // Never ourselves: suspending the sampling thread would hang the run.
        var ignored = new HashSet<int> { Process.GetCurrentProcess().Id };
        string exeName = string.IsNullOrEmpty(imagePath) ? null : Path.GetFileNameWithoutExtension(imagePath);
        var sw = Stopwatch.StartNew();
        double nextScan = 0;
        var pcs = new ulong[Math.Max(4, maxFrames)];
        timeBeginPeriod(1);
        try
        {
            while (sw.ElapsedMilliseconds < durationMs && (string.IsNullOrEmpty(stopFile) || !File.Exists(stopFile)))
            {
                double now = sw.Elapsed.TotalMilliseconds;
                if (now >= nextScan)
                {
                    nextScan = now + 250;
                    var cand = new List<int>();
                    if (exeName != null) foreach (var pr in Process.GetProcessesByName(exeName)) cand.Add(pr.Id);
                    else if (pids != null) cand.AddRange(pids);
                    foreach (int pid in cand)
                    {
                        if (procs.ContainsKey(pid) || ignored.Contains(pid)) continue;
                        IntPtr h;
                        if (!Matches(pid, imagePath, out h)) { ignored.Add(pid); continue; }
                        string path = symPath ?? "";
                        if (!SymInitializeW(h, path, true)) { CloseHandle(h); ignored.Add(pid); continue; }
                        var p = new Proc { H = h, Rep = new CpuSampleProcess { Pid = pid, FirstSeenMs = now } };
                        try { p.Rep.Image = Process.GetProcessById(pid).MainModule.FileName; } catch { }
                        p.Cpu0 = p.CpuLast = CpuOf(h);
                        p.LastModRefreshMs = now;
                        procs[pid] = p;
                    }
                    // Threads: open the new ones; a thread's first reading is
                    // its baseline, so cycles spent before we saw it are not
                    // charged to anything.
                    foreach (var p in procs.Values)
                    {
                        if (p.Rep.Exited) continue;
                        if (WaitForSingleObject(p.H, 0) == 0) { p.Rep.Exited = true; continue; }
                        p.CpuLast = CpuOf(p.H);
                        p.Rep.LastSeenMs = now;
                        Process pr;
                        try { pr = Process.GetProcessById(p.Rep.Pid); } catch { continue; }
                        foreach (ProcessThread t in pr.Threads)
                        {
                            if (p.Thr.ContainsKey(t.Id)) continue;
                            IntPtr th = OpenThread(THREAD_SUSPEND_RESUME | THREAD_GET_CONTEXT | THREAD_QUERY_INFORMATION, false, t.Id);
                            if (th == IntPtr.Zero) continue;
                            ulong c0; QueryThreadCycleTime(th, out c0);
                            var rep = new CpuSampleThread { Tid = t.Id };
                            IntPtr d;
                            if (GetThreadDescription(th, out d) >= 0 && d != IntPtr.Zero) { rep.Name = Marshal.PtrToStringUni(d) ?? ""; LocalFree(d); }
                            p.Thr[t.Id] = new Thr { Tid = t.Id, H = th, Last = c0, Rep = rep };
                            p.Rep.Threads[t.Id] = rep;
                        }
                    }
                }

                // Pass 1: which threads consumed anything since the last tick.
                var hot = new List<KeyValuePair<Proc, Thr>>();
                var delta = new List<double>();
                foreach (var p in procs.Values)
                {
                    if (p.Rep.Exited) continue;
                    foreach (var t in p.Thr.Values)
                    {
                        ulong c;
                        if (!QueryThreadCycleTime(t.H, out c)) continue;
                        if (c <= t.Last) continue;
                        double d = c - t.Last;
                        t.Last = c;
                        p.Rep.Cycles += d;
                        t.Rep.Cycles += d;
                        hot.Add(new KeyValuePair<Proc, Thr>(p, t));
                        delta.Add(d);
                    }
                }
                // Pass 2 (oncpu): of those, which are on a CPU right now.
                var probe = new ulong[hot.Count];
                if (onCpu && hot.Count > 0)
                {
                    for (int i = 0; i < hot.Count; i++) QueryThreadCycleTime(hot[i].Value.H, out probe[i]);
                    var spin = Stopwatch.StartNew();
                    while (spin.Elapsed.TotalMilliseconds < 0.03) { }
                }
                for (int hi = 0; hi < hot.Count; hi++)
                {
                    var p = hot[hi].Key;
                    var t = hot[hi].Value;
                    double w;
                    if (onCpu)
                    {
                        ulong c2;
                        if (!QueryThreadCycleTime(t.H, out c2) || c2 <= probe[hi]) continue;
                        t.Last = c2;
                        w = 1;
                    }
                    else
                    {
                        w = delta[hi];
                    }
                    {
                        int n = 0;
                        if (SuspendThread(t.H) != 0xFFFFFFFF)
                        {
                            try
                            {
                                Marshal.WriteInt32(ctx, 0x30, (int)CONTEXT_FULL_AMD64);
                                if (GetThreadContext(t.H, ctx))
                                {
                                    for (int i = 0; i < 512; i += 8) Marshal.WriteInt64(frameBuf, i, 0);
                                    Marshal.WriteInt64(frameBuf, 0, Marshal.ReadInt64(ctx, 0xF8));  // AddrPC  <- Rip
                                    Marshal.WriteInt32(frameBuf, 12, 3);
                                    Marshal.WriteInt64(frameBuf, 32, Marshal.ReadInt64(ctx, 0xA0)); // AddrFrame <- Rbp
                                    Marshal.WriteInt32(frameBuf, 44, 3);
                                    Marshal.WriteInt64(frameBuf, 48, Marshal.ReadInt64(ctx, 0x98)); // AddrStack <- Rsp
                                    Marshal.WriteInt32(frameBuf, 60, 3);
                                    while (n < pcs.Length && StackWalk64(IMAGE_FILE_MACHINE_AMD64, p.H, t.H, frameBuf, ctx, IntPtr.Zero, ftab, modbase, IntPtr.Zero))
                                    {
                                        ulong pc = (ulong)Marshal.ReadInt64(frameBuf, 0);
                                        if (pc == 0) break;
                                        pcs[n++] = pc;
                                    }
                                }
                            }
                            finally { ResumeThread(t.H); }
                        }
                        if (n == 0) { p.Rep.WalkFailures++; continue; }
                        p.Rep.Samples++;
                        t.Rep.Samples++;
                        p.Rep.WalkedCycles += w;
                        string leaf = Resolve(p, pcs[0], now);
                        Add(p.Rep.Self, leaf, w);
                        string ln = ResolveLine(p, pcs[0]);
                        if (ln != null) Add(p.Rep.Lines, leaf + " @ " + ln, w);
                        var seen = new HashSet<string>();
                        var sb = new StringBuilder();
                        string tn = t.Rep.Name.Length > 0 ? t.Rep.Name : "thread";
                        sb.Append(tn.Replace(';', '_'));
                        for (int i = n - 1; i >= 0; i--)
                        {
                            // A return address points after the call; step back
                            // one byte so it resolves inside the caller's call.
                            string f = Resolve(p, i == 0 ? pcs[i] : pcs[i] - 1, now);
                            if (seen.Add(f)) Add(p.Rep.Inclusive, f, w);
                            sb.Append(';').Append(f.Replace(';', '_').Replace(' ', '_'));
                        }
                        Add(p.Rep.Folded, sb.ToString(), w);
                    }
                }
                Thread.Sleep(intervalMs);
            }
        }
        finally
        {
            timeEndPeriod(1);
            foreach (var p in procs.Values)
            {
                if (!p.Rep.Exited) { p.CpuLast = CpuOf(p.H); p.Rep.LastSeenMs = sw.Elapsed.TotalMilliseconds; }
                p.Rep.CpuSeconds = (p.CpuLast - p.Cpu0) / 1e7;
                foreach (var t in p.Thr.Values) CloseHandle(t.H);
                SymCleanup(p.H);
                CloseHandle(p.H);
                done.Add(p.Rep);
            }
        }
        return done;
    }

    static void Add(Dictionary<string, double> d, string k, double w)
    {
        double v;
        d[k] = d.TryGetValue(k, out v) ? v + w : w;
    }
}
