<#
.SYNOPSIS
  The T2373 frame lab's live driver (T2392): the two live probes the lab's
  numbers rest on, run on the user's real screen when nobody is using it.

.DESCRIPTION
  Every other frame-lab harness proves its piece against fakes, because the
  real thing moves the user's pointer and reads the user's screen. Two claims
  can only be proved live, and the lab's verdicts are worth nothing until both
  have been:

    the pointer goes where the path says. FrameLabInput (T2384) encodes each
      physical-pixel point as ceil(v * 65536 / extent) and its section B
      proves that decodes back exactly - against its own model of the decoder.
      The decoder that matters is the one in Windows. So: send points, read
      GetCursorPos (physical, on a per-monitor-aware thread) and require the
      same point back, every one.
    a capture that misses frames SAYS so. FrameCapture's accounting run is the
      only thing standing between a dropped frame and a quietly smaller pass.
      Its own control (frame-capture.ps1 E3) removes frames from a recorded
      timeline; this one makes WGC itself drop them - the frame handler held
      for 100 ms with a single pool buffer, so DWM has nowhere to compose -
      and the accounting must name the dropped presents, inside the stall,
      and the cell verdict must read `incomplete`.

  Sections:

    A. pure (runs anywhere): the cursor-check sink against a recording sink -
       exact reads, a lagging raw-input thread, a user taking the mouse (the
       negative control) - and the drop-control decision on constructed
       numbers, including one where the accounting saw nothing;
    B. live: cursor calibration (every monitor's corners, edges and centre,
       each point sent alone and read back exactly), then a move-only shuttle
       played at 1 kHz through the same sink the lab uses, every read checked
       against the points sent. Move-only: nothing is launched, so a press
       would click whatever the user left on screen. The cursor is put back;
    C. live: the WGC-drop positive control.

  B and C need nobody at the box: Assert-UserAbsent ends the run as SKIP ALL
  otherwise, after A. -PureOnly stops after A.

  NOT YET HERE (filed from T2392): launching the card scene per matrix cell,
  the per-frame live scorer, and Invoke-FrameLabCell end to end with the
  results JSON and HTML report.

  ASCII-only by design (PS 5.1 on this box mangles non-ASCII on rewrite).

  powershell -NoProfile -File test\win32\frame-lab.ps1 [-PureOnly]
#>
[CmdletBinding()]
param([switch]$PureOnly)

$ErrorActionPreference = 'Stop'

$script:passes = 0
$script:failures = 0
$script:skipped = 0
function Assert($name, $cond, $detail = '') {
    if ($cond) {
        "  PASS $name"
        $script:passes++
    } else {
        "  FAIL $name$(if ($detail) { " -- $detail" })"
        $script:failures++
    }
}

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\UserPresence.ps1')
. (Join-Path $PSScriptRoot 'lib\FrameLabCatalogue.ps1')
. (Join-Path $PSScriptRoot 'lib\FrameCapture.ps1')

# FrameLabInput compiles in memory, so nothing can reference its assembly: the
# types below are compiled WITH its source, before anything imports it (which
# then finds GliPlayer and does nothing). Its source carries the usings.
if (-not ('GflCursorCheckSink' -as [type])) {
if ('GliPlayer' -as [type]) { throw 'frame-lab: FrameLabInput was imported before the check sink could be compiled with it' }
Add-Type -TypeDefinition ($script:FrameLabInputSource + @'

// Wraps the sink the lab plays into and, after every send, reads the cursor
// back. A read equal to the point just sent is Exact; equal to one of the last
// Window points sent is Lagged (the raw input thread runs a point or two
// behind under load); anything else is a Mismatch - the decoder put the
// pointer somewhere the path never asked for, or a person moved it.
public sealed class GflCursorCheckSink : IGliSink {
    readonly IGliSink inner;
    readonly List<int> rx = new List<int>(), ry = new List<int>();
    bool refreshed;
    public int Window = 16;
    public int Sends, Reads, Exact, Lagged, Mismatch, ReadFailed;
    public readonly List<string> Misses = new List<string>();
    public GflCursorCheckSink(IGliSink inner) { this.inner = inner; }
    public bool Send(int x, int y, int flags) {
        // GliPlayer refreshes a bare GliSendInputSink on its per-monitor-aware
        // thread; wrapped, it cannot see one, so do it here on that thread.
        var real = inner as GliSendInputSink;
        if (real != null && !refreshed) { real.Refresh(); refreshed = true; }
        bool ok = inner.Send(x, y, flags);
        Sends++;
        rx.Add(x); ry.Add(y);
        if (rx.Count > Window) { rx.RemoveAt(0); ry.RemoveAt(0); }
        int cx, cy;
        if (!inner.TryGetCursor(out cx, out cy)) { ReadFailed++; return ok; }
        Reads++;
        if (cx == x && cy == y) { Exact++; return ok; }
        for (int i = rx.Count - 2; i >= 0; i--) {
            if (rx[i] == cx && ry[i] == cy) { Lagged++; return ok; }
        }
        Mismatch++;
        if (Misses.Count < 10) Misses.Add(string.Format("sent {0},{1} read {2},{3}", x, y, cx, cy));
        return ok;
    }
    public bool TryGetCursor(out int x, out int y) { return inner.TryGetCursor(out x, out y); }
    public override string ToString() {
        return string.Format("sends={0} reads={1} exact={2} lagged={3} mismatch={4} read_failed={5}{6}",
            Sends, Reads, Exact, Lagged, Mismatch, ReadFailed,
            Misses.Count > 0 ? " first: " + string.Join("; ", Misses) : "");
    }
}

public sealed class GflCalPoint {
    public int X, Y, ReadX, ReadY;
    public bool Ok;
    public double Ms;
    public override string ToString() { return string.Format("{0},{1}->{2},{3}{4}", X, Y, ReadX, ReadY, Ok ? "" : " MISS"); }
}

// Each point sent ALONE (SendInput, absolute over the virtual desktop, the
// lab's own GliMath.Normalize), then GetCursorPos polled until it reads that
// point or TimeoutMs passes. Runs on a per-monitor-aware thread, so every
// coordinate here is physical. The cursor is put back where it was.
public static class GflCalibrate {
    [StructLayout(LayoutKind.Sequential)]
    struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr extra; }
    [StructLayout(LayoutKind.Sequential)]
    struct INPUT { public uint type; public MOUSEINPUT mi; public int pad0, pad1; }
    [StructLayout(LayoutKind.Sequential)]
    struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)]
    struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)]
    struct MONITORINFO { public uint cbSize; public RECT rcMonitor, rcWork; public uint dwFlags; }
    delegate bool MonitorEnumProc(IntPtr m, IntPtr dc, ref RECT r, IntPtr data);
    [DllImport("user32.dll")] static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] static extern int GetSystemMetrics(int i);
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr c);
    [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr dc, IntPtr clip, MonitorEnumProc cb, IntPtr data);
    [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr m, ref MONITORINFO mi);
    const uint MOVE = 0x0001, VIRTUALDESK = 0x4000, ABSOLUTE = 0x8000;

    static int vl, vt, vw, vh;
    static bool MoveTo(int x, int y) {
        var a = new INPUT[1];
        a[0].mi.dx = GliMath.Normalize(x - vl, vw);
        a[0].mi.dy = GliMath.Normalize(y - vt, vh);
        a[0].mi.dwFlags = MOVE | ABSOLUTE | VIRTUALDESK;
        return SendInput(1, a, Marshal.SizeOf(typeof(INPUT))) == 1;
    }

    // Every monitor's four corners, the middle of each edge and its centre,
    // plus one point a pixel in from each corner.
    static List<int[]> Points() {
        var pts = new List<int[]>();
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, delegate(IntPtr m, IntPtr dc, ref RECT r, IntPtr d) {
            var mi = new MONITORINFO(); mi.cbSize = (uint)Marshal.SizeOf(typeof(MONITORINFO));
            if (!GetMonitorInfo(m, ref mi)) return true;
            int l = mi.rcMonitor.L, t = mi.rcMonitor.T, rr = mi.rcMonitor.R - 1, b = mi.rcMonitor.B - 1;
            int cx = (l + rr) / 2, cy = (t + b) / 2;
            foreach (var p in new int[][] {
                new[] { l, t }, new[] { rr, t }, new[] { l, b }, new[] { rr, b },
                new[] { cx, t }, new[] { cx, b }, new[] { l, cy }, new[] { rr, cy }, new[] { cx, cy },
                new[] { l + 1, t + 1 }, new[] { rr - 1, t + 1 }, new[] { l + 1, b - 1 }, new[] { rr - 1, b - 1 } })
                pts.Add(p);
            return true;
        }, IntPtr.Zero);
        return pts;
    }

    public static GflCalPoint[] Run(int timeoutMs) {
        GflCalPoint[] result = null;
        Exception err = null;
        var th = new Thread(() => {
            try {
                SetThreadDpiAwarenessContext(new IntPtr(-4));  // PER_MONITOR_AWARE_V2
                vl = GetSystemMetrics(76); vt = GetSystemMetrics(77);
                vw = GetSystemMetrics(78); vh = GetSystemMetrics(79);
                POINT home; GetCursorPos(out home);
                var list = new List<GflCalPoint>();
                try {
                    foreach (var p in Points()) {
                        var c = new GflCalPoint { X = p[0], Y = p[1] };
                        var t0 = DateTime.UtcNow;
                        MoveTo(c.X, c.Y);
                        POINT q = new POINT();
                        do {
                            GetCursorPos(out q);
                            if (q.X == c.X && q.Y == c.Y) { c.Ok = true; break; }
                            Thread.Sleep(1);
                        } while ((DateTime.UtcNow - t0).TotalMilliseconds < timeoutMs);
                        c.ReadX = q.X; c.ReadY = q.Y;
                        c.Ms = (DateTime.UtcNow - t0).TotalMilliseconds;
                        list.Add(c);
                    }
                } finally { MoveTo(home.X, home.Y); }
                result = list.ToArray();
            } catch (Exception e) { err = e; }
        });
        th.IsBackground = true;
        th.Start();
        th.Join();
        if (err != null) throw err;
        return result;
    }
}
'@)
}
Import-FrameLabInput
Import-FrameCapture

<#
The WGC-drop control's decision, pure. From the stalled accounting run: the
stall must have run, the accounting must name skipped presents, enough of them
to cover the stall (MinSkipped), at least one of the named ones inside the
stall window (plus one refresh of slack either side), and the protocol's own
verdict for that cell - clean frames, this account - must be `incomplete`.
Returns { Ok; Reasons; Verdict; InStall }.
#>
function Resolve-FrameLabDropControl {
    param(
        [Parameter(Mandatory = $true)]$Stats,
        $Account,
        [int]$MinSkipped = 3
    )
    $reasons = @()
    $played = [pscustomobject]@{ Skipped = $false; Aborted = $false }
    $v = Resolve-FrameLabCellVerdict -Input1 $played -BleedFrames 0 -Account $Account -SlotGaps $Stats.SlotGaps
    if ($Stats.StallQpc1 -le $Stats.StallQpc0 -or $Stats.StallQpc0 -le 0) { $reasons += 'the planted stall never ran (frame StallAtFrame never arrived?)' }
    $inStall = 0
    if ($null -eq $Account) {
        $reasons += 'no accounting: the drop cannot be named'
    } else {
        if ($Account.Skipped -lt $MinSkipped) { $reasons += "the accounting names $($Account.Skipped) skipped frame(s), fewer than the $MinSkipped the stall must cost" }
        $hz = [math]::Max(1, $Stats.RefreshHz)
        $slack = [long]($Stats.QpcFrequency / $hz)
        foreach ($q in @($Account.UnmatchedQpc)) {
            if ($q -ge $Stats.StallQpc0 - $slack -and $q -le $Stats.StallQpc1 + $slack) { $inStall++ }
        }
        if ($Account.Skipped -gt 0 -and $inStall -eq 0) { $reasons += 'no named skipped present falls inside the stall: the accounting is counting something else' }
    }
    if ($v.Verdict -ne 'incomplete') { $reasons += "the cell verdict reads '$($v.Verdict)', not 'incomplete'" }
    [pscustomobject]@{ Ok = ($reasons.Count -eq 0); Reasons = $reasons; Verdict = $v; InStall = $inStall }
}

# A move-only shuttle across the middle of the primary monitor's work area:
# no press, so nothing on the user's screen is clicked.
function New-FrameLabMoveOnlyPath([int]$X, [int]$Y, [int]$Amplitude = 300) {
    $b = New-FrameLabPath 1000
    [void]$b.MoveTo($X, $Y).Hold(100).Shuttle($X + $Amplitude, $Y, 4, 400).Hold(100)
    return $b.Build()
}

try {
    # ---- A. pure -----------------------------------------------------------
    'A. the cursor-check sink and the drop-control decision (no screen, no input)'
    $path = New-FrameLabMoveOnlyPath 100 100 200

    $rec = New-Object GliRecordingSink
    $chk = New-Object GflCursorCheckSink $rec
    $r = Invoke-FrameLabInput -Path $path -Sink $chk
    Assert 'A1 a cursor that follows every send reads Exact on every send' (
        -not $r.Aborted -and $chk.Sends -eq $path.Length -and $chk.Exact -eq $chk.Sends -and $chk.Mismatch -eq 0) "$chk | $r"

    $rec = New-Object GliRecordingSink; $rec.LagSends = 2
    $chk = New-Object GflCursorCheckSink $rec
    $r = Invoke-FrameLabInput -Path $path -Sink $chk
    Assert 'A2 a raw-input thread two points behind reads Lagged, never Mismatch' (
        -not $r.Aborted -and $chk.Lagged -gt 0 -and $chk.Mismatch -eq 0) "$chk | $r"

    $rec = New-Object GliRecordingSink; $rec.UserMovesAt = 400; $rec.UserX = 5000; $rec.UserY = 5000
    $chk = New-Object GflCursorCheckSink $rec
    $r = Invoke-FrameLabInput -Path $path -Sink $chk -NoAbortOnUserInput
    Assert 'A3 negative control: a cursor the path never sent reads Mismatch, and says where' (
        $chk.Mismatch -gt 0 -and $chk.Misses.Count -gt 0 -and $chk.Misses[0] -match 'read 5000,5000') "$chk"

    $F = [GfcClock]::Frequency
    function New-DropStats([long]$s0, [long]$s1) {
        $st = New-Object GfcStats
        $st.RefreshHz = 120; $st.QpcFrequency = $F; $st.StallQpc0 = $s0; $st.StallQpc1 = $s1
        return $st
    }
    function New-DropAccount([long]$skipped, [long[]]$qpc) {
        $a = New-Object GfcAccount
        $a.Skipped = $skipped
        foreach ($q in $qpc) { $a.UnmatchedQpc.Add($q) }
        return $a
    }
    $s0 = 10 * $F; $s1 = $s0 + [long](0.1 * $F)
    $inside = @(1..10 | ForEach-Object { $s0 + [long]($_ * $F / 120) })
    $d = Resolve-FrameLabDropControl -Stats (New-DropStats $s0 $s1) -Account (New-DropAccount 10 $inside)
    Assert 'A4 ten skipped presents inside the stall: the control holds and the cell reads incomplete' (
        $d.Ok -and $d.Verdict.Verdict -eq 'incomplete' -and $d.InStall -eq 10 -and ($d.Verdict.Reasons -join ' ') -match 'skipped 10') "$($d.Reasons -join '; ') | $($d.Verdict.Reasons -join '; ')"

    $d = Resolve-FrameLabDropControl -Stats (New-DropStats $s0 $s1) -Account (New-DropAccount 0 @())
    Assert 'A5 an accounting that saw no drop fails the control, and the cell would have read pass' (
        -not $d.Ok -and $d.Verdict.Verdict -eq 'pass') "$($d.Reasons -join '; ')"

    $outside = @(1..5 | ForEach-Object { $s1 + [long](0.5 * $F) + $_ })
    $d = Resolve-FrameLabDropControl -Stats (New-DropStats $s0 $s1) -Account (New-DropAccount 5 $outside)
    Assert 'A6 skips counted nowhere near the stall fail the control' (
        -not $d.Ok -and ($d.Reasons -join ' ') -match 'inside the stall') "$($d.Reasons -join '; ')"

    $d = Resolve-FrameLabDropControl -Stats (New-DropStats 0 0) -Account (New-DropAccount 10 $inside)
    Assert 'A7 a stall that never ran fails the control' (-not $d.Ok -and ($d.Reasons -join ' ') -match 'never ran') "$($d.Reasons -join '; ')"

    if ($PureOnly) {
        ''
        '  SKIP B/C (live) by -PureOnly'
        $script:skipped += 2
    } else {
        # Everything below moves the user's pointer or reads their screen.
        Assert-UserAbsent

        # ---- B. the pointer goes where the path says ------------------------
        ''
        'B. cursor calibration and a 1 kHz move-only shuttle (the input desktop)'
        $cal = [GflCalibrate]::Run(250)
        $miss = @($cal | Where-Object { -not $_.Ok })
        Assert "B1 every calibration point ($($cal.Count), every monitor's corners, edges and centre) reads back exactly from GetCursorPos" (
            $cal.Count -ge 13 -and $miss.Count -eq 0) "misses: $(($miss | Select-Object -First 6) -join ' ')"
        '    calibration: {0} point(s), slowest read {1:F1} ms' -f $cal.Count, (($cal | Measure-Object -Property Ms -Maximum).Maximum)

        $c =$cal | Select-Object -Index 8  # the first monitor's centre
        $chk = New-Object GflCursorCheckSink (New-Object GliSendInputSink)
        $lpath = New-FrameLabMoveOnlyPath ($c.X - 150) $c.Y 300
        $r = Invoke-FrameLabInput -Path $lpath -Sink $chk
        "    play: $r"
        "    reads: $chk"
        Assert 'B2 the 1 kHz shuttle ran to the end without the user taking the pointer' (-not $r.Aborted -and $r.Sent -eq $lpath.Length) "$r"
        Assert 'B3 every cursor read during the shuttle is a point the path sent (exact or a point behind), none elsewhere' (
            $chk.Reads -gt 0 -and $chk.Mismatch -eq 0 -and $chk.ReadFailed -eq 0) "$chk"

        # ---- C. the WGC-drop positive control --------------------------------
        ''
        'C. the WGC-drop positive control: one pool buffer, the handler held 100 ms'
        if (-not [GfcSession]::Supported()) {
            '  SKIP C: Windows.Graphics.Capture is not supported on this box'
            $script:skipped++
        } else {
            $s = Start-FrameCapture -X $c.X -Y $c.Y -W 320 -H 240 -SampleEvery 0 -Buffers 1 -Duplication -StallAtFrame 60 -StallMs 100
            Start-Sleep -Seconds 2
            $res = Stop-FrameCapture -Session $s
            $st = $res.Stats
            "    stats: hz=$($st.RefreshHz) buffers=$($st.Buffers) captured=$($st.Captured) slot_gaps=$($st.SlotGaps) stall_ms={0:F1} dda_note=$($st.DdaNote)" -f (($st.StallQpc1 - $st.StallQpc0) * 1000.0 / [math]::Max(1, $st.QpcFrequency))
            "    account: $($res.Account)"
            Assert 'C1 duplication counted presents beside the stalled capture' ($st.DdaAcquires -gt 0 -and -not $st.DdaNote) "acquires=$($st.DdaAcquires) note=$($st.DdaNote)"
            $minSkip = [math]::Max(3, [int]($st.RefreshHz * 0.1 / 2))
            $d = Resolve-FrameLabDropControl -Stats $st -Account $res.Account -MinSkipped $minSkip
            Assert "C2 the accounting names the presents WGC dropped during the stall (>= $minSkip, inside it) and the cell reads incomplete" $d.Ok (
                "$($d.Reasons -join '; ') | in_stall=$($d.InStall) verdict=$($d.Verdict.Verdict): $($d.Verdict.Reasons -join '; ')")
            "    verdict: $($d.Verdict.Verdict) - $($d.Verdict.Reasons -join '; ') (named inside the stall: $($d.InStall))"
            if ($s -is [IDisposable]) { $s.Dispose() }
        }
    }

    Complete-TestBody
}
finally {
    foreach ($v in @('s')) { $o = Get-Variable -Name $v -ValueOnly -ErrorAction SilentlyContinue; if ($o -is [IDisposable]) { try { $o.Dispose() } catch { } } }
}

# A green run stamps the covered files (T783); red or skipped stays due.
if ($script:failures -eq 0 -and $script:skipped -eq 0) {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard frame-lab -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

''
Write-TestVerdict -Label 'T2392 FRAME-LAB' -Pass $script:passes -Fail $script:failures -Skipped $script:skipped
