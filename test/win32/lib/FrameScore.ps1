# FrameScore (T2381) - what one composed frame shows the user, and how a run of
# them moved. The scoring half of the T2373 frame lab.
#
# THE GAP THIS EXISTS FOR. resize-flicker.ps1, drag-perf.ps1 and frame-clock.ps1
# judge the app by what it SAYS it did (`surface erase ... fill=`, `window
# resize ... sync=`, frame-clock interval lines). Those can all be green while
# the user still watches the window bleed, because they prove our decisions,
# not our pixels (user, 2026-10-27: "i specifically do not want to see bleeding
# during resize of the window or resizing panes"). The lab captures every frame
# DWM composed (T2382) of a deterministic scene (T2383) while a scripted drag
# runs (T2384); THIS file is the part that says what each frame got wrong and
# how smooth the motion was. It is pure logic so it can be proved on frames
# with planted defects, anywhere, before it is ever trusted with a real one.
#
# THE SCENE. Every pixel the user should see is classifiable, because each pane
# runs a test card: a pane-unique background, a 1-cell border ring in a second
# unique colour, a large ID glyph in a third. A scene lists, per region:
#
#   Card     the rect the pane occupies in the frame (frame coordinates)
#   Bg/Ring/Glyph   the card's three colours (-1 = not present: a plain chrome
#            region such as a tab strip carries only Bg + Extra)
#   Extra    other colours legitimately inside it (theme padding, cursor)
#   RingW/RingH     expected ring thickness on the left/right and top/bottom
#            sides - one cell wide and one cell tall, which differ
#   Slack    allowed ring inset from each card edge, L T R B (a grid that does
#            not divide the card leaves up to a cell of padding right/bottom)
#   GlyphW/GlyphH   the ID glyph's expected size (0 = do not check)
#   Radius   rounded card corners; only the pixels OUTSIDE the arc (plus a 1px
#            anti-alias band) are excused, never a blanket edge exclusion
#
# plus scene-wide Flash colours (the desk, the window's background brush, the
# magenta of the positive-control erase) and Elements (a divider, a scrollbar,
# a dim overlay) with a colour, a search box and where they ought to be.
#
# THE CLASSES (T2373's table), each found by a different measurement so one
# defect cannot hide behind another's tolerance:
#
#   B1 background flash   a Flash colour inside a card
#   B2 stale size         the ring is not flush with its card: inset by more
#                         than Slack+PosTol on some side (content too small),
#                         or missing on a side (content too big, cut off)
#   B3 stretch            ring thickness or glyph size differs from the scene
#                         by more than PosTol - DWM scaling an old frame
#   B4 chrome tear        an Element of class B4 (divider, strip, sidebar edge)
#                         is not where the same frame's panes say it must be
#   B5 overlay lag        an Element of class B5 (layered popup) is off its rect
#   B6 garbage            a colour that is neither the region's palette, nor a
#                         Flash colour, nor an anti-alias BLEND of two palette
#                         colours - black, uninitialised, torn pixels
#
# B6's blend rule is what lets the scorer read anti-aliased glyphs and rounded
# edges without a mask: a pixel on the RGB segment between two palette colours
# (within Tol) is a blend, anything off every segment is garbage.
#
# THE MOTION METRICS (same capture, no second run). Input is the tracked edge
# position per frame with the frame's timestamp, the display refresh period,
# the motion window, and optionally the injected pointer path:
#
#   AdvanceRate   share of DUE refreshes that showed new motion (a refresh is
#                 due while the edge has not reached the pointer target; with
#                 no pointer, every refresh in the window is due). 39 fps on
#                 120 Hz reads about 0.33; T2373's target is >= 0.98
#   Stalls        runs of 2+ due refreshes in a row that showed no motion;
#                 LongestStall is the longest run of any length (target <= 1)
#   Step*         displacement per advancing refresh - its spread is the jitter
#                 of a constant-speed drag
#   MaxCurveDev   for a glide, max |position - expected| at display time
#   LagP50/LagP95 input-to-photon lag in refreshes: from the pointer last being
#                 at a position to the frame that shows the edge there
#                 (target p95 <= 2 at 120 Hz)
#   Reversals     refreshes where the edge moved AGAINST the direction of the
#                 pointer target - the user's "janks back and forth". A lagging
#                 edge catching up after the pointer turns is not one: it is
#                 still moving toward where the pointer is.
#
# Acceptance: test\win32\frame-score.ps1 (no app, no window - runs anywhere).
# ASCII-only by design (PS 5.1 on this box mangles non-ASCII on rewrite).

Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue

$script:FrameScoreSource = @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public struct FsBox {
    public int X0, Y0, X1, Y1;   // X1/Y1 exclusive
    public FsBox(int x0, int y0, int x1, int y1) { X0 = x0; Y0 = y0; X1 = x1; Y1 = y1; }
    public bool IsEmpty { get { return X1 <= X0 || Y1 <= Y0; } }
    public int W { get { return X1 - X0; } }
    public int H { get { return Y1 - Y0; } }
    public override string ToString() {
        return IsEmpty ? "empty" : string.Format("{0},{1}-{2},{3}", X0, Y0, X1, Y1);
    }
}

// Pixels as 0xRRGGBB; alpha is dropped, since DWM's output is opaque.
public sealed class FsFrame {
    public int W, H;
    public int[] Px;
    public FsFrame(int w, int h) { W = w; H = h; Px = new int[w * h]; }
    public int At(int x, int y) { return Px[y * W + x] & 0xFFFFFF; }
    public void Set(int x, int y, int c) { if (x >= 0 && y >= 0 && x < W && y < H) Px[y * W + x] = c & 0xFFFFFF; }
    public void Fill(FsBox b, int c) {
        int x0 = Math.Max(0, b.X0), y0 = Math.Max(0, b.Y0), x1 = Math.Min(W, b.X1), y1 = Math.Min(H, b.Y1);
        for (int y = y0; y < y1; y++) for (int x = x0; x < x1; x++) Px[y * W + x] = c & 0xFFFFFF;
    }
    public static FsFrame FromBitmap(Bitmap bmp, int x, int y, int w, int h) {
        FsFrame f = new FsFrame(w, h);
        BitmapData d = bmp.LockBits(new Rectangle(x, y, w, h), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        try {
            int[] row = new int[w];
            for (int r = 0; r < h; r++) {
                Marshal.Copy(new IntPtr(d.Scan0.ToInt64() + (long)r * d.Stride), row, 0, w);
                for (int i = 0; i < w; i++) f.Px[r * w + i] = row[i] & 0xFFFFFF;
            }
        } finally { bmp.UnlockBits(d); }
        return f;
    }
}

public sealed class FsRegion {
    public string Name = "";
    public FsBox Card;
    public int Bg = -1, Ring = -1, Glyph = -1;
    public int[] Extra = new int[0];
    public int RingW, RingH;
    public int[] Slack = new int[4];
    public int GlyphW, GlyphH;
    public int Radius;
}

public sealed class FsElement {
    public string Name = "", Cls = "B4";
    public int Color;
    public FsBox Search, Expect;
}

public sealed class FsScene {
    public List<FsRegion> Regions = new List<FsRegion>();
    public List<FsElement> Elements = new List<FsElement>();
    public int[] Flash = new int[0];
    public int Tol = 8;       // colour tolerance, max per-channel difference
    public int PosTol = 1;    // geometry tolerance, px
}

public sealed class FsFinding {
    public string Cls, Target, Detail;
    public int Pixels;
    public FsBox At;
    public override string ToString() {
        return string.Format("{0} {1}: {2}{3}", Cls, Target, Detail, Pixels > 0 ? " (" + Pixels + " px at " + At + ")" : "");
    }
}

public sealed class FsResult {
    public List<FsFinding> Findings = new List<FsFinding>();
    public Dictionary<string, FsBox> Rings = new Dictionary<string, FsBox>();
    public Dictionary<string, FsBox> Located = new Dictionary<string, FsBox>();
    public int Count(string cls) {
        int n = 0;
        foreach (FsFinding f in Findings) if (f.Cls == cls) n++;
        return n;
    }
    public string Classes() {
        List<string> s = new List<string>();
        foreach (FsFinding f in Findings) if (!s.Contains(f.Cls)) s.Add(f.Cls);
        s.Sort();
        return s.Count == 0 ? "none" : string.Join(",", s.ToArray());
    }
}

public static class GhozttyFrameScore {
    public static bool Near(int a, int b, int tol) {
        return Math.Abs(((a >> 16) & 255) - ((b >> 16) & 255)) <= tol
            && Math.Abs(((a >> 8) & 255) - ((b >> 8) & 255)) <= tol
            && Math.Abs((a & 255) - (b & 255)) <= tol;
    }

    static bool NearAny(int c, List<int> set, int tol) {
        foreach (int s in set) if (Near(c, s, tol)) return true;
        return false;
    }

    // Is c within tol of some point on the RGB segment a..b? That is what an
    // anti-aliased edge between two palette colours looks like.
    public static bool OnBlend(int c, int a, int b, int tol) {
        double ar = (a >> 16) & 255, ag = (a >> 8) & 255, ab = a & 255;
        double dr = ((b >> 16) & 255) - ar, dg = ((b >> 8) & 255) - ag, db = (b & 255) - ab;
        double cr = (c >> 16) & 255, cg = (c >> 8) & 255, cb = c & 255;
        double len2 = dr * dr + dg * dg + db * db;
        double t = len2 == 0 ? 0 : ((cr - ar) * dr + (cg - ag) * dg + (cb - ab) * db) / len2;
        if (t < 0) t = 0; if (t > 1) t = 1;
        return Math.Abs(cr - (ar + t * dr)) <= tol && Math.Abs(cg - (ag + t * dg)) <= tol && Math.Abs(cb - (ab + t * db)) <= tol;
    }

    static bool OnAnyBlend(int c, List<int> set, int tol) {
        for (int i = 0; i < set.Count; i++)
            for (int j = i + 1; j < set.Count; j++)
                if (OnBlend(c, set[i], set[j], tol)) return true;
        return false;
    }

    // Outside a rounded card's corner arc (with a 1px anti-alias band)?
    static bool InCornerMask(FsRegion r, int x, int y) {
        int rad = r.Radius;
        if (rad <= 0) return false;
        int cx, cy;
        if (x < r.Card.X0 + rad) cx = r.Card.X0 + rad; else if (x >= r.Card.X1 - rad) cx = r.Card.X1 - 1 - rad; else return false;
        if (y < r.Card.Y0 + rad) cy = r.Card.Y0 + rad; else if (y >= r.Card.Y1 - rad) cy = r.Card.Y1 - 1 - rad; else return false;
        double dx = x - cx, dy = y - cy, lim = rad - 1;
        return dx * dx + dy * dy > lim * lim;
    }

    static FsBox Clip(FsBox b, FsFrame f) {
        return new FsBox(Math.Max(0, b.X0), Math.Max(0, b.Y0), Math.Min(f.W, b.X1), Math.Min(f.H, b.Y1));
    }

    static void Grow(ref FsBox b, ref bool any, int x, int y) {
        if (!any) { b = new FsBox(x, y, x + 1, y + 1); any = true; return; }
        if (x < b.X0) b.X0 = x; if (y < b.Y0) b.Y0 = y;
        if (x + 1 > b.X1) b.X1 = x + 1; if (y + 1 > b.Y1) b.Y1 = y + 1;
    }

    static void Add(FsResult res, string cls, string target, string detail, int px, FsBox at) {
        FsFinding f = new FsFinding();
        f.Cls = cls; f.Target = target; f.Detail = detail; f.Pixels = px; f.At = at;
        res.Findings.Add(f);
    }

    public static FsResult Score(FsFrame f, FsScene s) {
        FsResult res = new FsResult();
        List<int> flash = new List<int>(s.Flash);
        foreach (FsRegion r in s.Regions) ScoreRegion(f, s, r, flash, res);
        foreach (FsElement e in s.Elements) ScoreElement(f, s, e, res);
        return res;
    }

    static void ScoreRegion(FsFrame f, FsScene s, FsRegion r, List<int> flash, FsResult res) {
        List<int> pal = new List<int>();
        if (r.Bg >= 0) pal.Add(r.Bg);
        if (r.Ring >= 0) pal.Add(r.Ring);
        if (r.Glyph >= 0) pal.Add(r.Glyph);
        pal.AddRange(r.Extra);
        FsBox c = Clip(r.Card, f);
        if (c.IsEmpty) { Add(res, "B2", r.Name, "card is off the frame", 0, r.Card); return; }

        // B1 + B6 over every pixel; one verdict per distinct colour, cached.
        Dictionary<int, int> kind = new Dictionary<int, int>();  // 0 ok, 1 flash, 2 garbage
        int nFlash = 0, nJunk = 0; FsBox bFlash = new FsBox(), bJunk = new FsBox(); bool aF = false, aJ = false;
        bool anyGlyph = false; FsBox bGlyph = new FsBox();
        // A card is long runs of one colour, so the previous pixel's verdict is
        // the common answer; it keeps a full frame inside one 120 Hz refresh
        // on the live scorer's worker (T2394).
        int lastPx = -1, lastK = 0; bool lastG = false;
        for (int y = c.Y0; y < c.Y1; y++) {
            for (int x = c.X0; x < c.X1; x++) {
                if (InCornerMask(r, x, y)) continue;
                int px = f.At(x, y);
                int k; bool g;
                if (px == lastPx) { k = lastK; g = lastG; }
                else {
                    if (!kind.TryGetValue(px, out k)) {
                        if (NearAny(px, pal, s.Tol)) k = 0;
                        else if (NearAny(px, flash, s.Tol)) k = 1;
                        else if (OnAnyBlend(px, pal, s.Tol)) k = 0;
                        else k = 2;
                        kind[px] = k;
                    }
                    g = r.Glyph >= 0 && Near(px, r.Glyph, s.Tol);
                    lastPx = px; lastK = k; lastG = g;
                }
                if (k == 1) { nFlash++; Grow(ref bFlash, ref aF, x, y); }
                else if (k == 2) { nJunk++; Grow(ref bJunk, ref aJ, x, y); }
                if (g) Grow(ref bGlyph, ref anyGlyph, x, y);
            }
        }
        if (nFlash > 0) Add(res, "B1", r.Name, "background colour inside the card", nFlash, bFlash);
        if (nJunk > 0) Add(res, "B6", r.Name, "colour outside the scene palette and its blends", nJunk, bJunk);

        if (r.Ring >= 0) ScoreRing(f, s, r, c, res);

        if (r.Glyph >= 0 && r.GlyphW > 0) {
            if (!anyGlyph) Add(res, "B3", r.Name, "ID glyph not found", 0, c);
            else if (Math.Abs(bGlyph.W - r.GlyphW) > s.PosTol || Math.Abs(bGlyph.H - r.GlyphH) > s.PosTol)
                Add(res, "B3", r.Name, string.Format("ID glyph {0}x{1}, expected {2}x{3}", bGlyph.W, bGlyph.H, r.GlyphW, r.GlyphH), 0, bGlyph);
        }
    }

    // Scan inward from each card edge along three lines (1/4, 1/2, 3/4) for the
    // first ring pixel. Its distance from the edge is the inset (B2); the run of
    // ring pixels from there is the side's thickness (B3).
    static void ScoreRing(FsFrame f, FsScene s, FsRegion r, FsBox c, FsResult res) {
        string[] side = { "left", "top", "right", "bottom" };
        int[] inset = new int[4];
        bool ringOk = true;
        for (int sd = 0; sd < 4; sd++) {
            bool vertical = sd == 0 || sd == 2;            // left/right sides scan along rows
            int along0 = vertical ? c.Y0 : c.X0, alongLen = vertical ? c.H : c.W;
            int depth = (vertical ? c.W : c.H) / 2;
            int expectTh = vertical ? r.RingW : r.RingH;
            int worstInset = -1, missing = 0, badTh = 0, thSeen = 0;
            for (int q = 1; q <= 3; q++) {
                int a = along0 + alongLen * q / 4;
                int found = -1, th = 0;
                for (int i = 0; i < depth; i++) {
                    int x, y; Probe(c, sd, a, i, out x, out y);
                    if (Near(f.At(x, y), r.Ring, s.Tol)) { found = i; break; }
                }
                if (found < 0) { missing++; continue; }
                for (int i = found; i < depth; i++) {
                    int x, y; Probe(c, sd, a, i, out x, out y);
                    if (!Near(f.At(x, y), r.Ring, s.Tol)) break;
                    th++;
                }
                if (q == 2) inset[sd] = found;
                if (found > worstInset) worstInset = found;
                if (expectTh > 0 && Math.Abs(th - expectTh) > s.PosTol) { badTh++; thSeen = th; }
            }
            if (missing > 0) {
                Add(res, "B2", r.Name, string.Format("ring missing on the {0} side at {1} of 3 lines (content cut off or not drawn)", side[sd], missing), 0, c);
                ringOk = false;
            } else if (worstInset > r.Slack[sd] + s.PosTol) {
                Add(res, "B2", r.Name, string.Format("ring inset {0}px from the {1} edge (slack {2})", worstInset, side[sd], r.Slack[sd]), 0, c);
            }
            if (badTh > 0)
                Add(res, "B3", r.Name, string.Format("{0} ring {1}px thick, expected {2}", side[sd], thSeen, expectTh), 0, c);
        }
        if (ringOk) res.Rings[r.Name] = new FsBox(c.X0 + inset[0], c.Y0 + inset[1], c.X1 - inset[2], c.Y1 - inset[3]);
    }

    static void Probe(FsBox c, int sd, int a, int i, out int x, out int y) {
        if (sd == 0) { x = c.X0 + i; y = a; }
        else if (sd == 1) { x = a; y = c.Y0 + i; }
        else if (sd == 2) { x = c.X1 - 1 - i; y = a; }
        else { x = a; y = c.Y1 - 1 - i; }
    }

    static void ScoreElement(FsFrame f, FsScene s, FsElement e, FsResult res) {
        FsBox c = Clip(e.Search, f);
        FsBox b = new FsBox(); bool any = false; int n = 0;
        for (int y = c.Y0; y < c.Y1; y++)
            for (int x = c.X0; x < c.X1; x++)
                if (Near(f.At(x, y), e.Color, s.Tol)) { n++; Grow(ref b, ref any, x, y); }
        if (!any) { Add(res, e.Cls, e.Name, "not found in its search box " + e.Search, 0, e.Search); return; }
        res.Located[e.Name] = b;
        int d0 = b.X0 - e.Expect.X0, d1 = b.Y0 - e.Expect.Y0, d2 = b.X1 - e.Expect.X1, d3 = b.Y1 - e.Expect.Y1;
        int worst = Math.Max(Math.Max(Math.Abs(d0), Math.Abs(d1)), Math.Max(Math.Abs(d2), Math.Abs(d3)));
        if (worst > s.PosTol)
            Add(res, e.Cls, e.Name, string.Format("at {0}, expected {1} (edges off by {2},{3},{4},{5})", b, e.Expect, d0, d1, d2, d3), n, b);
    }
}

public sealed class FsMotion {
    public int Slots, Due, Advanced, Unlocated;
    public double AdvanceRate;
    public int Stalls, LongestStall;
    public double StepMean, StepStd, StepMin, StepMax;
    public double MaxCurveDev = double.NaN;
    public double LagP50 = double.NaN, LagP95 = double.NaN;
    public int LagSamples;
    public int Reversals;
    public override string ToString() {
        return string.Format("slots={0} due={1} advanced={2} rate={3:0.000} stalls={4} longest={5} step={6:0.##}+-{7:0.##} [{8:0.##},{9:0.##}] curve={10:0.##} lag p50={11:0.##} p95={12:0.##} (n={13}) reversals={14} unlocated={15}",
            Slots, Due, Advanced, AdvanceRate, Stalls, LongestStall, StepMean, StepStd, StepMin, StepMax, MaxCurveDev, LagP50, LagP95, LagSamples, Reversals, Unlocated);
    }
}

public static class GhozttyMotionScore {
    // Pointer target at time tm: the injected path, interpolated, plus the grab
    // offset between the pointer and the edge it drags.
    static double Target(double[] pt, double[] pp, double off, double tm) {
        if (tm <= pt[0]) return pp[0] + off;
        for (int j = 0; j + 1 < pt.Length; j++)
            if (tm <= pt[j + 1]) {
                double span = pt[j + 1] - pt[j];
                double u = span <= 0 ? 1 : (tm - pt[j]) / span;
                return pp[j] + u * (pp[j + 1] - pp[j]) + off;
            }
        return pp[pp.Length - 1] + off;
    }

    // Latest time <= tk at which the pointer target was at p, or NaN.
    static double LastAt(double[] pt, double[] pp, double off, double p, double tk) {
        double best = double.NaN;
        for (int j = 0; j + 1 < pt.Length && pt[j] <= tk; j++) {
            double a = pp[j] + off - p, b = pp[j + 1] + off - p;
            if (a == 0) { best = pt[j]; continue; }
            if (a * b <= 0) {
                double u = a / (a - b);
                double tm = pt[j] + u * (pt[j + 1] - pt[j]);
                if (tm <= tk) best = tm;
            }
        }
        return best;
    }

    static double Pct(List<double> v, double q) {
        v.Sort();
        int i = (int)Math.Ceiling(q * v.Count) - 1;
        if (i < 0) i = 0; if (i >= v.Count) i = v.Count - 1;
        return v[i];
    }

    public static FsMotion Measure(double[] t, double[] pos, double periodMs, double t0, double t1,
                                   double[] pt, double[] pp, double offset, double[] expected) {
        FsMotion m = new FsMotion();
        bool ptr = pt != null && pp != null && pt.Length > 1 && pt.Length == pp.Length;
        int n = (int)Math.Round((t1 - t0) / periodMs);
        m.Slots = n;
        double[] sp = new double[n + 1], st = new double[n + 1];
        for (int k = 0; k <= n; k++) { sp[k] = double.NaN; st[k] = double.NaN; }
        for (int i = 0; i < t.Length; i++) {
            if (double.IsNaN(pos[i])) { m.Unlocated++; continue; }
            int k = (int)Math.Round((t[i] - t0) / periodMs);
            if (k < 0) k = 0;
            if (k > n) continue;
            sp[k] = pos[i]; st[k] = t[i];   // the last frame in a refresh is what it showed
        }
        int first = 0;
        while (first <= n && double.IsNaN(sp[first])) first++;
        if (first > n) return m;

        // Pass 1: the refreshes that showed new motion.
        List<int> advK = new List<int>();
        List<double> advD = new List<double>(), advT = new List<double>(), prevPos = new List<double>();
        double prev = sp[first], prevT = double.IsNaN(st[first]) ? t0 : st[first];
        List<double> prevTs = new List<double>();
        for (int k = first + 1; k <= n; k++) {
            if (double.IsNaN(sp[k]) || Math.Abs(sp[k] - prev) <= 0.5) continue;
            advK.Add(k); advD.Add(sp[k] - prev); advT.Add(st[k]); prevPos.Add(prev); prevTs.Add(prevT);
            prev = sp[k]; prevT = st[k];
        }
        bool pointerMoved = ptr && Math.Abs(pp[pp.Length - 1] - pp[0]) > 0.5;
        if (advK.Count == 0) {
            // Nothing moved. With a pointer that did, every refresh was a stall.
            if (pointerMoved) { m.Due = n - first; m.LongestStall = m.Due; m.Stalls = m.Due >= 2 ? 1 : 0; m.AdvanceRate = 0; }
            else m.AdvanceRate = 1.0;
            return m;
        }

        // Input-to-photon lag per advancing frame; its median is what "due" and
        // "reversal" are judged against, so the drag's own latency (the edge
        // starting late, catching up after the pointer pauses or turns) is lag,
        // reported once, and never also a stall or a jank.
        List<double> lags = new List<double>();
        if (ptr)
            for (int i = 0; i < advK.Count; i++) {
                double tp = LastAt(pt, pp, offset, prevPos[i] + advD[i], advT[i]);
                if (!double.IsNaN(tp)) lags.Add((advT[i] - tp) / periodMs);
            }
        m.LagSamples = lags.Count;
        double lagMs = 0;
        if (lags.Count > 0) { m.LagP50 = Pct(lags, 0.50); m.LagP95 = Pct(lags, 0.95); lagMs = m.LagP50 * periodMs; }

        // Pass 2: due refreshes run from the first advance to the last - or to
        // the window's end when the edge never reached the pointer's final spot,
        // since a stuck edge is the longest stall of all.
        int kA = advK[0], kB = advK[advK.Count - 1];
        if (ptr && Math.Abs(pp[pp.Length - 1] + offset - (prevPos[advK.Count - 1] + advD[advK.Count - 1])) > 0.5) kB = n;
        int ai = 0, run = 0;
        double shown = prevPos[0];
        for (int k = kA; k <= kB; k++) {
            bool adv = ai < advK.Count && advK[ai] == k;
            bool due = adv || !ptr || Math.Abs(Target(pt, pp, offset, t0 + k * periodMs - lagMs) - shown) > 0.5;
            if (due) {
                m.Due++;
                if (adv) { m.Advanced++; if (run >= 2) m.Stalls++; if (run > m.LongestStall) m.LongestStall = run; run = 0; }
                else run++;
            }
            if (adv) { shown = prevPos[ai] + advD[ai]; ai++; }
        }
        if (run >= 2) m.Stalls++;
        if (run > m.LongestStall) m.LongestStall = run;
        m.AdvanceRate = m.Due == 0 ? 1.0 : (double)m.Advanced / m.Due;

        // Reversals: a step against the direction the pointer moved over the
        // same interval, shifted back by the lag. Without a pointer, against the
        // run's overall direction.
        double overall = Math.Sign(prevPos[advK.Count - 1] + advD[advK.Count - 1] - prevPos[0]);
        List<double> steps = new List<double>();
        for (int i = 0; i < advK.Count; i++) {
            double d = advD[i];
            steps.Add(Math.Abs(d));
            double want = overall;
            if (ptr) {
                double pd = Target(pt, pp, offset, advT[i] - lagMs) - Target(pt, pp, offset, prevTs[i] - lagMs);
                want = Math.Abs(pd) > 0.5 ? Math.Sign(pd) : 0;
            }
            if (Math.Abs(d) > 1 && want != 0 && Math.Sign(d) != want) m.Reversals++;
        }
        if (steps.Count > 0) {
            double sum = 0, mn = double.MaxValue, mx = 0;
            foreach (double d in steps) { sum += d; if (d < mn) mn = d; if (d > mx) mx = d; }
            m.StepMean = sum / steps.Count; m.StepMin = mn; m.StepMax = mx;
            double v = 0; foreach (double d in steps) v += (d - m.StepMean) * (d - m.StepMean);
            m.StepStd = Math.Sqrt(v / steps.Count);
        }
        if (expected != null) {
            double dev = 0;
            for (int i = 0; i < t.Length && i < expected.Length; i++)
                if (!double.IsNaN(pos[i]) && !double.IsNaN(expected[i])) dev = Math.Max(dev, Math.Abs(pos[i] - expected[i]));
            m.MaxCurveDev = dev;
        }
        return m;
    }
}
'@

# Compiled to a dll in %TEMP% keyed by the source hash, not in memory (T2394):
# the live scene scorer (FrameLabScene.ps1) is C# that builds FsScenes on
# FrameCapture's worker, and an in-memory assembly cannot be referenced by a
# later compile. Path to the dll (once loaded) is $script:FrameScoreDll.
function Import-FrameScore {
    if ('GhozttyFrameScore' -as [type]) {
        $script:FrameScoreDll = [GhozttyFrameScore].Assembly.Location
        return
    }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hash = -join ($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($script:FrameScoreSource))[0..7] | ForEach-Object { $_.ToString('x2') })
    $dir = Join-Path $env:TEMP 'ghoztty-framescore'
    $dll = Join-Path $dir "fs-$hash.dll"
    if (-not (Test-Path $dll)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $src = Join-Path $dir "fs-$hash.cs"
        [System.IO.File]::WriteAllText($src, $script:FrameScoreSource, (New-Object System.Text.UTF8Encoding $false))
        $fw = [System.Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()
        $tmp = "$dll.$PID.tmp"
        $out = & (Join-Path $fw 'csc.exe') /nologo /target:library /optimize+ "/out:$tmp" `
            "/r:$(Join-Path $fw 'System.Drawing.dll')" $src 2>&1
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $tmp)) {
            throw "FrameScore: csc failed ($LASTEXITCODE): $($out -join ' | ')"
        }
        # A second process can win the race and already have the dll loaded
        # (so locked); its copy is the same source, so keep it.
        try { Move-Item -Force $tmp $dll -ErrorAction Stop }
        catch { if (-not (Test-Path $dll)) { throw }; Remove-Item $tmp -ErrorAction SilentlyContinue }
    }
    [System.Reflection.Assembly]::LoadFrom($dll) | Out-Null
    $script:FrameScoreDll = $dll
}
Import-FrameScore

# A capture (System.Drawing.Bitmap) as a scoring frame; -Box crops it to the
# window rect in bitmap coordinates (x, y, w, h).
function ConvertTo-ScoreFrame {
    param([Parameter(Mandatory = $true)][System.Drawing.Bitmap]$Bitmap, [int[]]$Box)
    if (-not $Box) { $Box = @(0, 0, $Bitmap.Width, $Bitmap.Height) }
    return [FsFrame]::FromBitmap($Bitmap, $Box[0], $Box[1], $Box[2], $Box[3])
}

function New-ScoreBox([int]$X0, [int]$Y0, [int]$X1, [int]$Y1) {
    return New-Object FsBox $X0, $Y0, $X1, $Y1
}

# One frame's bleed findings (FsResult: .Findings, .Count('B2'), .Classes(),
# .Rings[name], .Located[name]).
function Measure-FrameBleed {
    param([Parameter(Mandatory = $true)][FsFrame]$Frame, [Parameter(Mandatory = $true)][FsScene]$Scene)
    return [GhozttyFrameScore]::Score($Frame, $Scene)
}

# Motion metrics for one interaction. -Time and -Position are per captured
# frame (ms on the capture clock; NaN position = edge not located). -PointerTime
# / -PointerPosition are the injected path on the SAME clock.
function Measure-FrameMotion {
    param(
        [Parameter(Mandatory = $true)][double[]]$Time,
        [Parameter(Mandatory = $true)][double[]]$Position,
        [Parameter(Mandatory = $true)][double]$PeriodMs,
        [Parameter(Mandatory = $true)][double]$Start,
        [Parameter(Mandatory = $true)][double]$End,
        [double[]]$PointerTime,
        [double[]]$PointerPosition,
        [double]$GrabOffset = 0,
        [double[]]$Expected
    )
    return [GhozttyMotionScore]::Measure($Time, $Position, $PeriodMs, $Start, $End,
        $PointerTime, $PointerPosition, $GrabOffset, $Expected)
}

# T2373's smoothness targets. Returns the list of misses (empty = met).
function Test-FrameMotionTargets {
    param(
        [Parameter(Mandatory = $true)][FsMotion]$Motion,
        [double]$MinAdvanceRate = 0.98,
        [int]$MaxStall = 1,
        [double]$MaxLagP95 = 2,
        [int]$MaxReversals = 0
    )
    $miss = @()
    if ($Motion.AdvanceRate -lt $MinAdvanceRate) { $miss += ('advance rate {0:0.000} < {1}' -f $Motion.AdvanceRate, $MinAdvanceRate) }
    if ($Motion.LongestStall -gt $MaxStall) { $miss += ('longest stall {0} refreshes > {1}' -f $Motion.LongestStall, $MaxStall) }
    # 0.01 of a refresh of slack: a lag of exactly the target is computed from
    # millisecond timestamps and lands a rounding error either side of it.
    if (-not [double]::IsNaN($Motion.LagP95) -and $Motion.LagP95 -gt $MaxLagP95 + 0.01) { $miss += ('lag p95 {0:0.##} refreshes > {1}' -f $Motion.LagP95, $MaxLagP95) }
    if ($Motion.Reversals -gt $MaxReversals) { $miss += ('{0} reversal(s) > {1}' -f $Motion.Reversals, $MaxReversals) }
    return , $miss
}
