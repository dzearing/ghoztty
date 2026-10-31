# ChainFoldOracle (T2485) - the frame-by-frame oracle for a chain-fold drag.
#
# The user's report (2026-10-29): dragging a divider right across 5+ panes so
# three of them fold into blades one after another is janky - an already
# folded blade flickers while the next pane folds, the folding pane carries a
# light border that vanishes on the last frame, and things change colour on the
# final frame. T2485's close condition is four checks over EVERY composed frame
# of a release capture, and this is them, in one place, so the recorder's
# verdict and the synthetic proof in test\win32\chainfold.ps1 are the same code:
#
#   a. flash    - a band of the window that differs from BOTH neighbouring
#                 frames while those two agree is a blink, not motion
#                 (score = (d(p,c) + d(c,n)) / 2 - d(p,n), mean abs luminance
#                 per pixel). Also: a column that is pure black (max channel
#                 <= 6) on most rows is a hole nothing painted (A1/A2/D17).
#   b. novel    - a colour (4 bits a channel) covering a real area of a
#                 mid-drag frame that is in neither the first nor the last
#                 frame; and, with no tolerance at all, such a colour forming
#                 a LINE (a rim): the light border that exists only mid-tween.
#   c. final    - per band, each run of motion ends on a step no bigger than
#                 1.5x the run's median step: no jump or colour snap on the
#                 last frame (the margin is measured - see FinalRatio).
#   d. gaps     - no gap over 16.7 ms between composed frames while things
#                 move, on a capture that dropped nothing.
#
# Frames stream through ChainFoldScan one at a time (a release capture is ~500
# frames of 2000x1000), so only three are ever held. The scan works on any
# CfFrame: a PNG off disk (CfFrame.Load) or one painted in memory (the
# synthetic sections of the harness).
#
# Acceptance: test\win32\chainfold.ps1 (synthetic plants, both directions).

if (-not ('CfFrame' -as [type])) {
    Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public sealed class CfFrame {
    public int W, H;
    public byte[] Rgb;   // 3 bytes a pixel, row-major, R G B
    public CfFrame(int w, int h) { W = w; H = h; Rgb = new byte[w * h * 3]; }
    public static CfFrame Solid(int w, int h, int rgb) { var f = new CfFrame(w, h); f.Fill(0, 0, w, h, rgb); return f; }
    public CfFrame Clone() { var f = new CfFrame(W, H); Buffer.BlockCopy(Rgb, 0, f.Rgb, 0, Rgb.Length); return f; }
    public void Fill(int x, int y, int w, int h, int rgb) {
        byte r = (byte)(rgb >> 16), g = (byte)(rgb >> 8), b = (byte)rgb;
        int x1 = Math.Min(W, x + w), y1 = Math.Min(H, y + h);
        for (int yy = Math.Max(0, y); yy < y1; yy++)
            for (int xx = Math.Max(0, x); xx < x1; xx++) { int o = (yy * W + xx) * 3; Rgb[o] = r; Rgb[o + 1] = g; Rgb[o + 2] = b; }
    }
    public void Save(string path) {
        using (var bmp = new Bitmap(W, H, PixelFormat.Format24bppRgb)) {
            var d = bmp.LockBits(new Rectangle(0, 0, W, H), ImageLockMode.WriteOnly, PixelFormat.Format24bppRgb);
            try {
                var row = new byte[d.Stride];
                // pixel-region: writing the frame to a PNG copies every pixel; nothing is scored here
                for (int y = 0; y < H; y++) {
                    for (int x = 0; x < W; x++) { int o = (y * W + x) * 3; row[x * 3] = Rgb[o + 2]; row[x * 3 + 1] = Rgb[o + 1]; row[x * 3 + 2] = Rgb[o]; }
                    Marshal.Copy(row, 0, IntPtr.Add(d.Scan0, y * d.Stride), d.Stride);
                }
            } finally { bmp.UnlockBits(d); }
            bmp.Save(path, ImageFormat.Png);
        }
    }
    public static CfFrame Load(string path) {
        using (var bmp = new Bitmap(path)) {
            var f = new CfFrame(bmp.Width, bmp.Height);
            var d = bmp.LockBits(new Rectangle(0, 0, bmp.Width, bmp.Height), ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
            try {
                var row = new byte[d.Stride];
                for (int y = 0; y < f.H; y++) {
                    Marshal.Copy(IntPtr.Add(d.Scan0, y * d.Stride), row, 0, d.Stride);
                    for (int x = 0; x < f.W; x++) { int o = (y * f.W + x) * 3; f.Rgb[o] = row[x * 3 + 2]; f.Rgb[o + 1] = row[x * 3 + 1]; f.Rgb[o + 2] = row[x * 3]; }
                }
            } finally { bmp.UnlockBits(d); }
            return f;
        }
    }
}

public sealed class CfFinding {
    public string Kind; public int Frame; public int Band; public double Score; public string Detail;
    public override string ToString() { return string.Format("{0} f{1}{2} {3:0.0} {4}", Kind, Frame, Band >= 0 ? " band" + Band : "", Score, Detail); }
}

public sealed class ChainFoldScan {
    readonly int x0, y0, x1, y1, bands;
    public double FlashThreshold = 3.0;   // lum/px, flash.py's default
    public double BlackRowFraction = 0.6; // blackcols.py
    public int BlackMax = 6;
    public int NovelMinPixels = 400;      // a 2 px rim down a 900 px pane is 1800
    public bool NovelNear = true;         // see Novel()
    public double SteadyFraction = 0.5;   // see Novel(); the settle after the release is ~20% of the frames
    public double MotionNoise = 0.5;      // lum/px below which a band is still
    public int StillJoin = 2;             // still frames that do not end a run
    public int MinRun = 5;                // runs shorter than this have no median worth the name
    // A drag-driven run is linear, not an ease-out, and the band mean of
    // moving text swings frame to frame: on run39 (release, clean final
    // frames by eye) the worst last-step/median was 1.30 over 8 runs. So a
    // last step counts as a jump past 1.5x the run's median.
    public double FinalRatio = 1.5;

    readonly List<int> idx = new List<int>();
    readonly List<double[]> dPrev = new List<double[]>();  // d(i-1, i) per band
    readonly List<double[]> dSkip = new List<double[]>();  // d(i-1, i+1) per band, set when i+1 arrives
    readonly List<int[]> hist = new List<int[]>();
    public readonly List<CfFinding> Black = new List<CfFinding>();
    byte[] lumA, lumB;   // the two frames before the newest
    int count;

    public ChainFoldScan(int x0, int y0, int x1, int y1, int bands) { this.x0 = x0; this.y0 = y0; this.x1 = x1; this.y1 = y1; this.bands = bands; }
    public int Count { get { return count; } }

    int BandOf(int x) { return Math.Min(bands - 1, (x - x0) * bands / (x1 - x0)); }

    byte[] Lum(CfFrame f) {
        int w = x1 - x0, h = y1 - y0; var l = new byte[w * h];
        for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
            int o = ((y + y0) * f.W + x + x0) * 3;
            l[y * w + x] = (byte)((f.Rgb[o] * 299 + f.Rgb[o + 1] * 587 + f.Rgb[o + 2] * 114) / 1000);
        }
        return l;
    }
    double[] Diff(byte[] a, byte[] b) {
        int w = x1 - x0, h = y1 - y0; var s = new double[bands]; var n = new int[bands];
        // pixel-region: w/h are the caller's region (x0..x1, y0..y1), and each band is scored on its own
        for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) { int k = BandOf(x + x0); s[k] += Math.Abs(a[y * w + x] - b[y * w + x]); n[k]++; }
        for (int k = 0; k < bands; k++) s[k] = n[k] > 0 ? s[k] / n[k] : 0;
        return s;
    }

    public void Add(int frameIndex, CfFrame f) {
        if (f.W < x1 || f.H < y1) throw new ArgumentException(string.Format("frame {0} is {1}x{2}, the region needs {3}x{4}", frameIndex, f.W, f.H, x1, y1));
        var lum = Lum(f);
        idx.Add(frameIndex);
        dPrev.Add(lumB == null ? new double[bands] : Diff(lumB, lum));
        dSkip.Add(null);
        if (lumA != null) dSkip[count - 1] = Diff(lumA, lum);
        lumA = lumB; lumB = lum;
        // the colour histogram (4 bits a channel) and the black columns
        var hh = new int[4096];
        int h = y1 - y0; var blk = new int[x1 - x0];
        for (int y = y0; y < y1; y++) for (int x = x0; x < x1; x++) {
            int o = (y * f.W + x) * 3; int r = f.Rgb[o], g = f.Rgb[o + 1], b = f.Rgb[o + 2];
            hh[((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4)]++;
            if (r <= BlackMax && g <= BlackMax && b <= BlackMax) blk[x - x0]++;
        }
        hist.Add(hh);
        int s = -1;
        for (int x = 0; x <= blk.Length; x++) {
            bool on = x < blk.Length && blk[x] > BlackRowFraction * h;
            if (on && s < 0) s = x;
            if (!on && s >= 0) { Black.Add(new CfFinding { Kind = "black", Frame = frameIndex, Band = BandOf(s + x0), Score = x - s, Detail = string.Format("x{0}-{1}", s + x0, x - 1 + x0) }); s = -1; }
        }
        count++;
    }

    public List<CfFinding> Flashes() {
        var o = new List<CfFinding>();
        for (int i = 1; i + 1 < count; i++) for (int k = 0; k < bands; k++) {
            double pc = dPrev[i][k], cn = dPrev[i + 1][k], pn = dSkip[i][k];
            double sc = (pc + cn) / 2 - pn;
            if (sc > FlashThreshold) o.Add(new CfFinding { Kind = "flash", Frame = idx[i], Band = k, Score = sc, Detail = string.Format("p-c {0:0.0} c-n {1:0.0} p-n {2:0.0}", pc, cn, pn) });
        }
        return o;
    }

    // frames where any band moved more than the noise: what "while things
    // move" means for criterion d.
    public List<int> MotionFrames() {
        var o = new List<int>();
        for (int i = 1; i < count; i++) for (int k = 0; k < bands; k++) if (dPrev[i][k] > MotionNoise) { o.Add(idx[i]); break; }
        return o;
    }

    public List<CfFinding> Novel() {
        var o = new List<CfFinding>();
        if (count < 3) return o;
        int[] a = hist[0], z = hist[count - 1];
        // A colour on screen for most of the drag is the drag's own
        // affordance - the grabbed divider's accent (#A94DC1 on the default
        // theme, 5 px wide, riding the pointer from press to release) - not a
        // rim that exists only while one pane folds, which lasts that fold's
        // tween: 10-20 frames of a ~400-frame capture.
        var steady = new bool[4096];
        for (int q = 0; q < 4096; q++) {
            int on = 0;
            for (int i = 1; i + 1 < count; i++) if (hist[i][q] > 0) on++;
            steady[q] = on > SteadyFraction * (count - 2);
        }
        for (int i = 1; i + 1 < count; i++) {
            int best = -1, bestN = 0, total = 0;
            for (int q = 0; q < 4096; q++) {
                if (a[q] > 0 || z[q] > 0 || steady[q]) continue;
                // a quantum next to one the end states hold is antialiasing or a
                // tween blend, not a new colour: only a colour at least two
                // steps from both end states on some channel counts.
                if (NovelNear && NearKnown(q, a, z)) continue;
                total += hist[i][q];
                if (hist[i][q] > bestN) { bestN = hist[i][q]; best = q; }
            }
            if (total >= NovelMinPixels) o.Add(new CfFinding { Kind = "novel", Frame = idx[i], Band = -1, Score = total, Detail = string.Format("{0} px of colours in neither end state, most #{1:X1}{1:X1}{2:X1}{2:X1}{3:X1}{3:X1} ({4} px)", total, best >> 8, (best >> 4) & 15, best & 15, bestN) });
        }
        return o;
    }
    // Criterion b's sharper half: a RIM. The area check above forgives a
    // colour one step from an end state, because a pane's text crossfading
    // over the glass scatters blend colours everywhere (run38/run40: ~1000-2000
    // px of them per fold frame, by eye clean) - and that forgiveness is exactly
    // what would hide a light border next to white text. So a second pass asks
    // a different question with no forgiveness: does a colour neither end
    // state has (and the drag does not hold steady) form a LINE - an unbroken
    // run down a column or along a row for a tenth of the region? Scattered
    // blend pixels and text never do; a border down a pane does. Call PrepareRims after the first pass, then
    // Rim() on every frame again.
    bool[] rimQ, steadyQ;
    public double RimFraction = 0.1;
    public void PrepareRims() {
        rimQ = new bool[4096]; steadyQ = new bool[4096];
        if (count < 3) return;
        int[] a = hist[0], z = hist[count - 1];
        for (int q = 0; q < 4096; q++) {
            int on = 0;
            for (int i = 1; i + 1 < count; i++) if (hist[i][q] > 0) on++;
            rimQ[q] = a[q] == 0 && z[q] == 0 && on <= SteadyFraction * (count - 2);
            steadyQ[q] = a[q] == 0 && on > SteadyFraction * (count - 2);  // the end frame may still show it (run40)
        }
    }
    public List<CfFinding> Rim(int frameIndex, CfFrame f) {
        var o = new List<CfFinding>();
        if (rimQ == null) throw new InvalidOperationException("PrepareRims first");
        // The LONGEST UNBROKEN run of such pixels per column and per row, not
        // their count: a border is one unbroken line, while text breaks between
        // letters. run38-run40 each scored ~90 "rims" on a count - every one the
        // blade's vertical title (C:\Windows\...\powershell) drawn over the
        // folding face, 100-215 px of a column in glyph-sized pieces
        // (docs/design/t2485-chainfold/run40-rim-f143-152.png).
        int w = x1 - x0, h = y1 - y0; var col = new int[w]; var row = new int[h];
        var colRun = new int[w]; int rowRun = 0; var accent = new int[w];
        for (int y = y0; y < y1; y++) {
            rowRun = 0;
            for (int x = x0; x < x1; x++) {
                int p = (y * f.W + x) * 3;
                int qq = ((f.Rgb[p] >> 4) << 8) | ((f.Rgb[p + 1] >> 4) << 4) | (f.Rgb[p + 2] >> 4);
                if (steadyQ[qq]) accent[x - x0]++;
                if (rimQ[qq]) {
                    colRun[x - x0]++; rowRun++;
                    if (colRun[x - x0] > col[x - x0]) col[x - x0] = colRun[x - x0];
                    if (rowRun > row[y - y0]) row[y - y0] = rowRun;
                } else { colRun[x - x0] = 0; rowRun = 0; }
            }
        }
        // The grabbed divider's accent is steady (see Novel), but its
        // anti-aliased edge blends with the gradient under it and changes colour
        // as it moves (run40 f166-169: an 88 px line at x706, beside the accent
        // at x707-711). A line within 3 px of a steady accent column is that edge.
        for (int x = 0; x < w; x++) if (accent[x] >= RimFraction * h)
            for (int d = -3; d <= 3; d++) if (x + d >= 0 && x + d < w) col[x + d] = Math.Min(col[x + d], 0);
        Lines(o, frameIndex, col, RimFraction * h, "x", x0, true);
        Lines(o, frameIndex, row, RimFraction * w, "y", y0, false);
        return o;
    }
    void Lines(List<CfFinding> o, int frameIndex, int[] n, double min, string axis, int off, bool cols) {
        int s = -1, peak = 0;
        for (int i = 0; i <= n.Length; i++) {
            bool on = i < n.Length && n[i] >= min;
            if (on) { if (s < 0) { s = i; peak = 0; } peak = Math.Max(peak, n[i]); }
            if (!on && s >= 0) {
                o.Add(new CfFinding { Kind = "rim", Frame = frameIndex, Band = cols ? BandOf(s + off) : -1, Score = peak, Detail = string.Format("{0}{1}-{2} ({3} px at most)", axis, s + off, i - 1 + off, peak) });
                s = -1;
            }
        }
    }

    static bool NearKnown(int q, int[] a, int[] z) {
        int r = q >> 8, g = (q >> 4) & 15, b = q & 15;
        for (int dr = -1; dr <= 1; dr++) for (int dg = -1; dg <= 1; dg++) for (int db = -1; db <= 1; db++) {
            int rr = r + dr, gg = g + dg, bb = b + db;
            if (rr < 0 || gg < 0 || bb < 0 || rr > 15 || gg > 15 || bb > 15) continue;
            int n = (rr << 8) | (gg << 4) | bb;
            if (a[n] > 0 || z[n] > 0) return true;
        }
        return false;
    }

    public List<CfFinding> FinalSteps() {
        var o = new List<CfFinding>();
        for (int k = 0; k < bands; k++) {
            int i = 1;
            while (i < count) {
                if (dPrev[i][k] <= MotionNoise) { i++; continue; }
                var run = new List<int>(); int still = 0, j = i;
                for (; j < count; j++) {
                    if (dPrev[j][k] > MotionNoise) { run.Add(j); still = 0; }
                    else if (++still > StillJoin) break;
                }
                if (run.Count >= MinRun) {
                    var v = new List<double>(); foreach (int r in run) v.Add(dPrev[r][k]);
                    v.Sort(); double med = v[v.Count / 2];
                    double last = dPrev[run[run.Count - 1]][k];
                    if (last > FinalRatio * med) o.Add(new CfFinding { Kind = "final", Frame = idx[run[run.Count - 1]], Band = k, Score = last, Detail = string.Format("last step {0:0.0} > {4:0.0}x run median {1:0.0} over f{2}-f{3}", last, med, idx[run[0]], idx[run[run.Count - 1]], FinalRatio) });
                }
                i = j;
            }
        }
        return o;
    }
}
'@
}

function New-ChainFoldScan {
    <# The scan over one region of every frame: X0..X1, Y0..Y1 in frame pixels, cut into -Bands vertical bands. #>
    param([int]$X0, [int]$Y0, [int]$X1, [int]$Y1, [int]$Bands = 8)
    return [ChainFoldScan]::new($X0, $Y0, $X1, $Y1, $Bands)
}

function Get-ChainFoldGaps {
    <#
      Criterion d: while the pointer moves, how long the window went without a
      new picture. The capture delivers a frame every refresh whether or not
      the app drew (8.3 ms at 120 Hz on every run, stalls included), so a gap
      between DELIVERED frames can never fire; the gap that matters is between
      frames whose content changed. -Frames is the delivered list in order
      (Qpc, Scanned, Moved); a span with a frame missing from it (a queue drop,
      or a frame with no picture) cannot say whether the app was still, so it
      is counted as Blind rather than passed.
    #>
    param([object[]]$Frames, [long]$Frequency, [long]$FromQpc, [long]$ToQpc, [double]$RefreshHz = 120, [double]$LimitMs = 16.7)
    $period = $Frequency / $RefreshHz
    $gaps = @(); $blind = 0
    $last = $null; $prev = $null; $hole = $false
    foreach ($f in @($Frames | Where-Object { [long]$_.Qpc -ge $FromQpc -and [long]$_.Qpc -le $ToQpc } | Sort-Object { [long]$_.Qpc })) {
        $q = [long]$f.Qpc
        if ($null -ne $prev -and ($q - $prev) -gt 1.5 * $period) { $hole = $true }
        if (-not $f.Scanned) { $hole = $true }
        $prev = $q
        if (-not $f.Moved) { continue }
        if ($null -ne $last) {
            $ms = ($q - $last) * 1000.0 / $Frequency
            if ($ms -gt $LimitMs) {
                if ($hole) { $blind++ }
                else { $gaps += [pscustomobject]@{ Kind = 'gap'; AtMs = [math]::Round(($last - $FromQpc) * 1000.0 / $Frequency, 1); Ms = [math]::Round($ms, 1) } }
            }
        }
        $last = $q; $hole = $false
    }
    return [pscustomobject]@{ Gaps = $gaps; Blind = $blind }
}

function Invoke-ChainFoldOracle {
    <#
      Score a recorded run directory (geometry.json, timeline.json, frames\):
      every frame from the press to -SettleMs after the release, the region
      being the panes' row span across the whole window. Returns the four
      criteria's findings plus what was scored.
    #>
    param([Parameter(Mandatory = $true)][string]$RunDir, [int]$SettleMs = 600, [int]$Bands = 8)
    $geo = Get-Content -Raw (Join-Path $RunDir 'geometry.json') | ConvertFrom-Json
    $tl = Get-Content -Raw (Join-Path $RunDir 'timeline.json') | ConvertFrom-Json
    $F = [long]$tl.freq
    $press = @($tl.stamps | Where-Object { ([int]$_.flags -band 1) -ne 0 } | Select-Object -First 1)
    $rel = @($tl.stamps | Where-Object { ([int]$_.flags -band 2) -ne 0 } | Select-Object -First 1)
    if ($press.Count -eq 0 -or $rel.Count -eq 0) { throw "no press/release in $RunDir\timeline.json" }
    $from = [long]$press[0].qpc
    $to = [long]$rel[0].qpc + [long]($SettleMs * $F / 1000)
    $wx = [int]$geo.window[0]; $wy = [int]$geo.window[1]
    $p0 = @($geo.panes)[0]
    $y0 = [int]$p0.Y - $wy + 20; $y1 = [int]$p0.Y - $wy + [int]$p0.H - 20
    $frames = @($tl.timeline | ForEach-Object { $_ } | Where-Object { -not $_.sup -and [long]$_.qpc -ge $from -and [long]$_.qpc -le $to -and $_.png -and (Test-Path $_.png) })
    if ($frames.Count -lt 3) { throw "only $($frames.Count) frames between press and settle in $RunDir" }
    $first = [CfFrame]::Load($frames[0].png)
    $y1 = [math]::Min($y1, $first.H)
    $scan = New-ChainFoldScan -X0 0 -Y0 $y0 -X1 $first.W -Y1 $y1 -Bands $Bands
    foreach ($fr in $frames) { $scan.Add([int]$fr.i, [CfFrame]::Load($fr.png)) }
    $scan.PrepareRims()
    $rims = @(); foreach ($fr in $frames) { $rims += @($scan.Rim([int]$fr.i, [CfFrame]::Load($fr.png))) }
    # d is measured while the POINTER moves: after it stops the folds settle
    # and the window goes still, and that is the end of the drag, not a stall.
    $moves = @($tl.stamps | Where-Object { [long]$_.qpc -ge $from -and [long]$_.qpc -le [long]$rel[0].qpc })
    $mv0 = $from; $mv1 = $from
    for ($i = 1; $i -lt $moves.Count; $i++) {
        if ($moves[$i].x -ne $moves[$i - 1].x -or $moves[$i].y -ne $moves[$i - 1].y) {
            if ($mv0 -eq $from) { $mv0 = [long]$moves[$i].qpc }
            $mv1 = [long]$moves[$i].qpc
        }
    }
    $moved = @{}; foreach ($m in $scan.MotionFrames()) { $moved[[int]$m] = $true }
    $scanned = @{}; foreach ($fr in $frames) { $scanned[[int]$fr.i] = $true }
    $all = @($tl.timeline | ForEach-Object { $_ } | Where-Object { -not $_.sup } | ForEach-Object {
            [pscustomobject]@{ Qpc = [long]$_.qpc; Scanned = $scanned.ContainsKey([int]$_.i); Moved = $moved.ContainsKey([int]$_.i) } })
    $hz = $(if ($tl.stats.RefreshHz) { [double]$tl.stats.RefreshHz } else { 120 })
    $g = Get-ChainFoldGaps -Frames $all -Frequency $F -FromQpc $mv0 -ToQpc $mv1 -RefreshHz $hz
    return [pscustomobject]@{
        Frames  = $frames.Count
        FirstFrame = [int]$frames[0].i
        LastFrame = [int]$frames[-1].i
        Dropped = [int]$tl.stats.QueueDropped
        Flashes = @($scan.Flashes())
        Black   = @($scan.Black)
        Novel   = @($scan.Novel())
        Rims    = $rims
        Final   = @($scan.FinalSteps())
        Gaps    = @($g.Gaps)
        GapBlind = $g.Blind
    }
}
