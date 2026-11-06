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
    // Moving text saturates the band mean: glyph strokes are 1-2 px wide, so
    // a 3 px step scores as high as a 12 px one and a correct in-between
    // frame can read as a flash (live 20261031-230739 f82: pane 2 placed
    // 415 -> 418 -> 427, the text shifted +3/+9 with ~0 residual, raw score
    // 3.7). Such a candidate is forgiven only when BOTH hold: its neighbours
    // plainly disagree (p-n above AgreeFraction of the smaller step - a real
    // blink, the D19 a->b->a shake included, has p-n near 0), and the best
    // horizontal shift of each pair explains the middle frame (the
    // compensated score is under FlashThreshold). Every catalogued defect on
    // run1/51/57/61/65 and 20261031-003706 survives; the one a shift hides
    // (run65 f248, a black strip on a moving pane) is the black check's.
    public double AgreeFraction = 0.5;
    public int MaxShift = 64;             // px a band may travel between p and n
    readonly Dictionary<long, string> forgiven = new Dictionary<long, string>();

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
        if (lumA != null) {
            dSkip[count - 1] = Diff(lumA, lum);
            Compensate(count - 1, lumA, lumB, lum);
        }
        lumA = lumB; lumB = lum;
        if (count == 0) firstFrame = f; lastFrame = f;   // the end states, per pixel (see Rim)
        if (DetectOverlay) FindOverlay(frameIndex, f);
        // the colour histogram (4 bits a channel) and the black columns
        var hh = new int[4096];
        int h = y1 - y0; var blk = new int[x1 - x0];
        for (int y = y0; y < y1; y++) for (int x = x0; x < x1; x++) {
            int o = (y * f.W + x) * 3; int r = f.Rgb[o], g = f.Rgb[o + 1], b = f.Rgb[o + 2];
            if (!InOverlay(x, y)) hh[((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4)]++;
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

    // A GPU overlay's toast is not the app's (T2535: run48/run49 f82-f100, the
    // NVIDIA "Press Alt+Z" toast over pane 6, read as 15000 px of novel colour
    // #447700). It is recognised by its brand bar: an unbroken vertical run of
    // saturated green at least OverlayBarMin px tall and at most OverlayBarMaxW
    // px wide, which terminal text never forms (glyphs break between lines) and
    // a green pane background does not either (too wide). The toast is the
    // bar's height, from the bar rightward across the dark panel and its grey
    // text to the first OverlayStop px of anything else (or the region's edge,
    // which is where these toasts are anchored). The rect is sticky - the union
    // of every frame's - so the toast's fade-out stays excluded too, and only
    // the colour checks (novel, rim) skip it: a black hole or a blink there is
    // still scored.
    public bool DetectOverlay = true;
    public int OverlayBarMin = 60, OverlayBarMaxW = 16, OverlayStop = 8;
    bool hasOverlay; int ox0, oy0, ox1, oy1;
    public readonly List<CfFinding> Overlays = new List<CfFinding>();
    public bool InOverlay(int x, int y) { return hasOverlay && x >= ox0 && x < ox1 && y >= oy0 && y < oy1; }
    static bool BrandGreen(int r, int g, int b) { return g >= 0x60 && g - r >= 0x20 && g - b >= 0x50; }
    static bool PanelPixel(int r, int g, int b) {
        int mx = Math.Max(r, Math.Max(g, b)), mn = Math.Min(r, Math.Min(g, b));
        return mx <= 0x14 || mx - mn <= 8 || BrandGreen(r, g, b) || (g > r && g > b && b <= 0x30);
    }
    void FindOverlay(int frameIndex, CfFrame f) {
        int w = x1 - x0; var run = new int[w]; var best = new int[w]; var top = new int[w]; var bot = new int[w];
        for (int y = y0; y < y1; y++) for (int x = x0; x < x1; x++) {
            int o = (y * f.W + x) * 3, i = x - x0;
            if (BrandGreen(f.Rgb[o], f.Rgb[o + 1], f.Rgb[o + 2])) {
                run[i]++;
                if (run[i] > best[i]) { best[i] = run[i]; bot[i] = y; top[i] = y - run[i] + 1; }
            } else run[i] = 0;
        }
        int s = -1;
        for (int i = 0; i <= w; i++) {
            bool on = i < w && best[i] >= OverlayBarMin;
            if (on && s < 0) s = i;
            if (on || s < 0) continue;
            int e = i;   // bar columns s..e-1
            if (e - s <= OverlayBarMaxW) {
                int bt = int.MaxValue, bb = -1;
                for (int k = s; k < e; k++) { bt = Math.Min(bt, top[k]); bb = Math.Max(bb, bot[k]); }
                int ym = (bt + bb) / 2, right = x1, foreign = 0;
                for (int x = e + x0; x < x1; x++) {
                    int o = (ym * f.W + x) * 3;
                    if (PanelPixel(f.Rgb[o], f.Rgb[o + 1], f.Rgb[o + 2])) foreign = 0;
                    else if (++foreign >= OverlayStop) { right = x - OverlayStop + 1; break; }
                }
                int rx0 = Math.Max(x0, s + x0 - 2), ry0 = Math.Max(y0, bt - 2), rx1 = Math.Min(x1, right + 2), ry1 = Math.Min(y1, bb + 3);
                if (!hasOverlay) { ox0 = rx0; oy0 = ry0; ox1 = rx1; oy1 = ry1; hasOverlay = true; }
                else { ox0 = Math.Min(ox0, rx0); oy0 = Math.Min(oy0, ry0); ox1 = Math.Max(ox1, rx1); oy1 = Math.Max(oy1, ry1); }
                Overlays.Add(new CfFinding { Kind = "overlay", Frame = frameIndex, Band = -1, Score = (rx1 - rx0) * (ry1 - ry0), Detail = string.Format("x{0}-{1} y{2}-{3}", rx0, rx1 - 1, ry0, ry1 - 1) });
            }
            s = -1;
        }
    }

    // the least mean abs difference of band k between a and b over every
    // horizontal shift of b up to MaxShift (rows every other one)
    double BestShift(byte[] a, byte[] b, int k) {
        int w = x1 - x0, h = y1 - y0;
        int bx0 = k * w / bands, bx1 = (k + 1) * w / bands;
        double best = double.MaxValue;
        for (int s = -MaxShift; s <= MaxShift; s++) {
            int lo = Math.Max(bx0, -s), hi = Math.Min(bx1, w - s);
            if (hi - lo < (bx1 - bx0) / 2) continue;
            long sum = 0;
            for (int y = 0; y < h; y += 2) { int r = y * w; for (int x = lo; x < hi; x++) sum += Math.Abs(a[r + x] - b[r + x + s]); }
            double d = (double)sum / (((h + 1) / 2) * (double)(hi - lo));
            if (d < best) best = d;
        }
        return best;
    }

    void Compensate(int i, byte[] p, byte[] c, byte[] n) {
        if (i < 1) return;
        for (int k = 0; k < bands; k++) {
            double pc = dPrev[i][k], cn = dPrev[i + 1][k], pn = dSkip[i][k];
            if ((pc + cn) / 2 - pn <= FlashThreshold || pn <= AgreeFraction * Math.Min(pc, cn)) continue;
            double pcC = BestShift(p, c, k), cnC = BestShift(c, n, k), pnC = BestShift(p, n, k);
            double scC = (pcC + cnC) / 2 - pnC;
            if (scC <= FlashThreshold) forgiven[(long)i * 1000 + k] = string.Format("shifted p-c {0:0.0} c-n {1:0.0} p-n {2:0.0}", pcC, cnC, pnC);
        }
    }

    // raw candidates that motion explains (see AgreeFraction)
    public List<CfFinding> Explained() {
        var o = new List<CfFinding>();
        foreach (var kv in forgiven) o.Add(new CfFinding { Kind = "moved", Frame = idx[(int)(kv.Key / 1000)], Band = (int)(kv.Key % 1000), Score = 0, Detail = kv.Value });
        return o;
    }

    public List<CfFinding> Flashes() {
        var o = new List<CfFinding>();
        for (int i = 1; i + 1 < count; i++) for (int k = 0; k < bands; k++) {
            double pc = dPrev[i][k], cn = dPrev[i + 1][k], pn = dSkip[i][k];
            double sc = (pc + cn) / 2 - pn;
            if (sc > FlashThreshold && !forgiven.ContainsKey((long)i * 1000 + k)) o.Add(new CfFinding { Kind = "flash", Frame = idx[i], Band = k, Score = sc, Detail = string.Format("p-c {0:0.0} c-n {1:0.0} p-n {2:0.0}", pc, cn, pn) });
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
                // steps from both end states on some channel counts. The drag's
                // steady colours count as known too: run48 f90 drew the grabbed
                // divider #AA44BB for one frame against its #A94DC1 (455 px, one
                // step on blue), an accent blend rather than a new colour, and it
                // was novel only because that run's press frame had no accent yet.
                if (NovelNear && NearKnown(q, a, z, steady)) continue;
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
            // Steady through the drag and missing from at least ONE end: the end
            // frame may still show the accent (run40), and so may the press frame,
            // when the divider was already lit under the pointer before the button
            // went down (T2535: run49's 93 "rims" were the accent's anti-aliased
            // edge, x1708 beside the accent at x1709-1713, because the press frame
            // held the accent and this used to demand a[q] == 0). A colour in BOTH
            // ends is the background, and must not switch the edge exclusion on
            // for every column.
            steadyQ[q] = (a[q] == 0 || z[q] == 0) && on > SteadyFraction * (count - 2);
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
                if (rimQ[qq] && !InOverlay(x, y) && !Blend(f, p)) {
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
        // A pure-black hole is a line of a colour neither end state has, so it
        // reads as a rim as well; it is the black check's finding (run49: all
        // 32 full-height "rims" were its 32 black strips), not a second defect.
        foreach (var b in Black) {
            if (b.Frame != frameIndex) continue;
            int bx0 = int.Parse(b.Detail.Substring(1, b.Detail.IndexOf('-') - 1)), bx1 = int.Parse(b.Detail.Substring(b.Detail.IndexOf('-') + 1));
            for (int x = Math.Max(x0, bx0); x <= Math.Min(x1 - 1, bx1); x++) col[x - x0] = 0;
        }
        Lines(o, frameIndex, col, RimFraction * h, "x", x0, true);
        Lines(o, frameIndex, row, RimFraction * w, "y", y0, false);
        return o;
    }
    // A pixel whose colour lies between ITS OWN first and last colour (within
    // a quantum, per channel) is that pixel crossfading from one end state to
    // the other, not a border: run49 f322-f325, a blade fading in after the
    // release (x3030: 1E393C at the press, 5B6E70 mid-fade, 65797B at rest),
    // made 8 px wide "rims" 522-762 px tall. A light border is far outside the
    // dark span it is drawn over, so it is never forgiven here.
    CfFrame firstFrame, lastFrame;
    public int BlendSlack = 16;
    bool Blend(CfFrame f, int p) {
        if (firstFrame == null || lastFrame == null || firstFrame.W != f.W || lastFrame.W != f.W) return false;
        for (int c = 0; c < 3; c++) {
            int a = firstFrame.Rgb[p + c], z = lastFrame.Rgb[p + c], v = f.Rgb[p + c];
            if (v < Math.Min(a, z) - BlendSlack || v > Math.Max(a, z) + BlendSlack) return false;
        }
        return true;
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

    static bool NearKnown(int q, int[] a, int[] z, bool[] steady) {
        int r = q >> 8, g = (q >> 4) & 15, b = q & 15;
        for (int dr = -1; dr <= 1; dr++) for (int dg = -1; dg <= 1; dg++) for (int db = -1; db <= 1; db++) {
            int rr = r + dr, gg = g + dg, bb = b + db;
            if (rr < 0 || gg < 0 || bb < 0 || rr > 15 || gg > 15 || bb > 15) continue;
            int n = (rr << 8) | (gg << 4) | bb;
            if (a[n] > 0 || z[n] > 0 || steady[n]) return true;
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
      or a frame with no picture) cannot by itself say whether the app was
      still, so it is settled by evidence or counted as Blind (T2535 - at a
      near-full-monitor size WGC hands over a frame every 2-3 refreshes, and
      every such span used to go blind):

        - the capture's own still frames: a scanned frame that did not move
          shows the picture unchanged since the last change, so a span whose
          last still frame is already over -LimitMs past that change is a gap
          of at least that long, whatever the missing frames held (Source
          'screen');
        - the app's own account (-AppQpc, the layout batches' end stamps from
          the ring trace): when the batches from the one that drew the last
          change through the span never leave more than -LimitMs between them,
          the app kept producing and the capture merely did not hand those
          pictures over (Resolved); a wider batch interval is a gap (Source
          'app'). It is the app's word, not the screen's, so it is used only
          where the capture cannot see.

      Anything else stays Blind.
    #>
    param([object[]]$Frames, [long]$Frequency, [long]$FromQpc, [long]$ToQpc, [double]$RefreshHz = 120, [double]$LimitMs = 16.7, [long[]]$AppQpc = @())
    $period = $Frequency / $RefreshHz
    $limitTicks = $LimitMs * $Frequency / 1000.0
    $app = @($AppQpc | Sort-Object)
    $gaps = @(); $blind = 0; $resolved = 0
    $last = $null; $prev = $null; $hole = $false; $still = $null
    foreach ($f in @($Frames | Where-Object { [long]$_.Qpc -ge $FromQpc -and [long]$_.Qpc -le $ToQpc } | Sort-Object { [long]$_.Qpc })) {
        $q = [long]$f.Qpc
        if ($null -ne $prev -and ($q - $prev) -gt 1.5 * $period) { $hole = $true }
        if (-not $f.Scanned) { $hole = $true }
        $prev = $q
        if (-not $f.Moved) { if ($f.Scanned) { $still = $q }; continue }
        if ($null -ne $last) {
            $ms = ($q - $last) * 1000.0 / $Frequency
            $at = [math]::Round(($last - $FromQpc) * 1000.0 / $Frequency, 1)
            if ($ms -gt $LimitMs) {
                if (-not $hole) { $gaps += [pscustomobject]@{ Kind = 'gap'; Source = 'screen'; AtMs = $at; Ms = [math]::Round($ms, 1) } }
                elseif ($null -ne $still -and ($still - $last) -gt $limitTicks) {
                    $gaps += [pscustomobject]@{ Kind = 'gap'; Source = 'screen'; AtMs = $at; Ms = [math]::Round(($still - $last) * 1000.0 / $Frequency, 1) }
                } else {
                    # the batch that drew the picture at $last, then every one up to the picture at $q
                    $before = @($app | Where-Object { $_ -le $last })
                    $after = @($app | Where-Object { $_ -gt $last -and $_ -le $q })
                    if ($before.Count -eq 0 -or $after.Count -eq 0) { $blind++ }
                    else {
                        $pts = @($before[-1]) + $after
                        $worst = 0
                        for ($i = 1; $i -lt $pts.Count; $i++) { $worst = [math]::Max($worst, $pts[$i] - $pts[$i - 1]) }
                        if ($worst -gt $limitTicks) { $gaps += [pscustomobject]@{ Kind = 'gap'; Source = 'app'; AtMs = $at; Ms = [math]::Round($worst * 1000.0 / $Frequency, 1) } }
                        else { $resolved++ }
                    }
                }
            }
        }
        $last = $q; $hole = $false; $still = $null
    }
    return [pscustomobject]@{ Gaps = $gaps; Blind = $blind; Resolved = $resolved }
}

function Get-ChainFoldAppStamps {
    <# The app's layout batches' end stamps (QPC) from a GHOZTTY_STACK_TRACE=ring log ("stack trace batch qpc=N end=M"); empty when there is no log. #>
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return , ([long[]]@()) }
    $o = New-Object System.Collections.Generic.List[long]
    foreach ($m in (Select-String -LiteralPath $Path -Pattern 'stack trace batch qpc=\d+ end=(\d+)')) { $o.Add([long]$m.Matches[0].Groups[1].Value) }
    return , ([long[]]$o.ToArray())
}

function Invoke-ChainFoldOracle {
    <#
      Score a recorded run directory (geometry.json, timeline.json, frames\):
      every frame from the press to -SettleMs after the release, the region
      being the panes' row span across the whole window. Returns the four
      criteria's findings plus what was scored. -TraceLog is the app's
      GHOZTTY_STACK_TRACE=ring log (default: app.log in the run directory, else
      <RunDir>-stderr.log beside it); criterion d reads its layout batches
      where the capture is blind (see Get-ChainFoldGaps).
    #>
    param([Parameter(Mandatory = $true)][string]$RunDir, [int]$SettleMs = 600, [int]$Bands = 8, [string]$TraceLog = '')
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
    if (-not $TraceLog) {
        $TraceLog = @((Join-Path $RunDir 'app.log'), ($RunDir.TrimEnd([char]92, [char]47) + '-stderr.log')) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    }
    $appQpc = Get-ChainFoldAppStamps -Path $TraceLog
    $g = Get-ChainFoldGaps -Frames $all -Frequency $F -FromQpc $mv0 -ToQpc $mv1 -RefreshHz $hz -AppQpc $appQpc
    return [pscustomobject]@{
        Frames  = $frames.Count
        FirstFrame = [int]$frames[0].i
        LastFrame = [int]$frames[-1].i
        Dropped = [int]$tl.stats.QueueDropped
        Flashes = @($scan.Flashes())
        Explained = @($scan.Explained())
        Black   = @($scan.Black)
        Novel   = @($scan.Novel())
        Rims    = $rims
        Final   = @($scan.FinalSteps())
        Gaps    = @($g.Gaps)
        GapBlind = $g.Blind
        GapResolved = $g.Resolved
        AppBatches = $appQpc.Count
        Overlays = @($scan.Overlays)
    }
}
