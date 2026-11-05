# FrameLabScene (T2394) - the T2373 frame lab's LIVE scorer: what each frame of
# a resize should have shown, worked out from where the window and its
# dividers actually are in that frame, and scored against it.
#
# THE GAP THIS EXISTS FOR. FrameScore (T2381) scores a frame against a FIXED
# scene, and FrameLabCard's New-FrameLabCardRegion builds one card's region
# from a rect the caller already knows. During a live drag every card moves
# every frame, so the scene has to be inferred per frame - and it must NOT be
# inferred from the cards themselves. A stale-size frame (B2) is exactly one
# whose content disagrees with where its pane is; a scene read off the content
# would agree with it and call the frame clean.
#
# THE MODEL. Two halves, measured once and applied per frame:
#
#   Edges (GfsEdge)   the lines that move: window-right / window-bottom (found
#                     by scanning in from a solid BACKDROP behind the window
#                     until the backdrop stops), a divider or the sidebar's
#                     edge (scanning for its own colour). Each is located on
#                     several scan lines and the median taken, so one planted
#                     defect on one line cannot move it. Never the card's
#                     colours: nothing about a card can move an edge.
#   Cards (GfsCard)   each pane's test card: its colours, cell size and theme
#                     padding, and for each side (L T R B) the edge it rides
#                     on plus a fixed offset - or a fixed coordinate.
#
# Calibrate() measures the cards on a STILL frame at launch, where the card is
# settled and so may be read: the ring's bounding box, the padding around it,
# the cell size from the ring's thickness, and every side's offset from its
# edge. After that each frame's card rect is edge + offset, its grid is what
# the app computes for that rect (floor((W - pads) / cell)), and the FsScene
# for the frame is built the way New-FrameLabCardRegion builds it.
#
# PER FRAME the scorer records: failing or not, the tracked edges' positions
# (for Measure-FrameMotion), how long the scoring took, and - for a failing
# frame only - its FsFindings. A frame on which an anchoring edge cannot be
# located is FAILING with an 'LOC' finding: a frame whose geometry cannot be
# read is not a frame that can be passed.
#
# It is a GfcScorer (AsScorer()) so it runs on FrameCapture's worker thread.
# Compiled with csc against FrameScore's and FrameCapture's dlls, cached in
# %TEMP% by source + reference hash (the same shape as both of those).
#
# Acceptance: test\win32\frame-lab-scene.ps1 (no app, no window).
# ASCII-only by design (PS 5.1 on this box mangles non-ASCII on rewrite).

. (Join-Path $PSScriptRoot 'FrameScore.ps1')
. (Join-Path $PSScriptRoot 'FrameCapture.ps1')
. (Join-Path $PSScriptRoot 'FrameLabCard.ps1')

$script:FrameLabSceneSource = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;

// One edge that moves during an interaction.
public sealed class GfsEdge {
    public string Name = "";
    public string Kind = "";            // window-left | window-top | window-right | window-bottom | divider | sidebar-edge
    public bool Vertical = true;        // a vertical edge (an x), scanned along rows
    public int[] Lines = new int[0];    // the rows (Vertical) or columns scanned
    public int From, To;                // scan range along each line, From toward To, inclusive
    public int Color;
    public bool Until;                  // true: stop at the first pixel NOT near Color (a backdrop)
                                        // false: stop at the first pixel near it (a divider)
    public int Tol = 8;
    // T2398. Open: a backdrop edge whose scan starts on the work area's own
    // boundary. A line whose first pixel is already the window (no backdrop at
    // all) puts the edge AT that boundary instead of not finding it - a
    // maximized or snapped window fills the work area and has no backdrop
    // beyond it. Without Open such a line finds nothing (T2397's rule).
    public bool Open;
    // CarryX / CarryY: EARLIER edges whose displacement from where Calibrate
    // found them moves this edge's scan - x coordinates by CarryX's, y by
    // CarryY's (a vertical edge's From/To are x, its Lines y). So a divider
    // carried by window-left/window-top is still scanned from inside its pane
    // after the whole window has moved. CarryX2 / CarryY2 name the FAR edge on
    // the same axis (window-right / window-bottom): with both located the map
    // is affine - x' = X' + (x - X) * (X2' - X') / (X2 - X) - so a scan that
    // started inside a pane of a ratio split is still inside it after the
    // window has been resized as well as moved (a maximize, a snap).
    public string CarryX, CarryY, CarryX2, CarryY2;
    // Position is a pixel BOUNDARY: scanning upward it is the found pixel's
    // coordinate (where the thing starts); scanning downward it is one past it
    // (an exclusive right/bottom bound). So window-right scanned in from the
    // backdrop is the window's exclusive right, and a divider scanned from the
    // pane on its left is that pane's exclusive right.
}

// x' = To + (x - From) * Scale: where a carried scan coordinate lands (T2398).
public struct GfsMap {
    public readonly double From, To, Scale;
    public GfsMap(double from, double to, double scale) { From = from; To = to; Scale = scale; }
    public static readonly GfsMap Identity = new GfsMap(0, 0, 1);
    public int Apply(int x) { return (int)Math.Round(To + (x - From) * Scale); }
}

// One pane's test card, and which edge each of its sides rides on.
public sealed class GfsCard {
    public string Name = "";
    public int Bg = -1, Ring = -1, Glyph = -1;
    public int[] Extra = new int[0];
    public int CellW, CellH;
    public int PadL, PadT, PadR = -1, PadB = -1;   // -1: same as the opposite side
    public int Scale = 2, Radius;
    public string[] Anchor = new string[4];       // L T R B: an edge name, or null = fixed
    public int[] Offset = new int[4];             // side = edge + Offset (fixed: the coordinate)
    public FsBox Still;                           // the pane as Calibrate measured it
    public FsBox StillRing;
    // T2398: the same offsets measured on a MAXIMIZED still frame. A maximized
    // window has no border, and its caption need not be the restored one's
    // height, so a maximized frame's panes sit at other offsets from the edges.
    public int[] OffsetMax = new int[4];
    public FsBox StillMax;
}

public sealed class GfsRecord {
    public long Index, Qpc;
    public bool Failing;
    public bool Maximized;              // every Open edge sat on its boundary (T2398)
    public double[] Edges;              // per GfsSceneScorer.Edges, NaN = not located
    public FsFinding[] Findings;        // failing frames only
    public double Ms;                   // scoring time
    public string Classes() {
        if (Findings == null || Findings.Length == 0) return "none";
        var s = new List<string>();
        foreach (var f in Findings) if (!s.Contains(f.Cls)) s.Add(f.Cls);
        s.Sort();
        return string.Join(",", s.ToArray());
    }
}

public sealed class GfsSceneScorer {
    public readonly List<GfsEdge> Edges = new List<GfsEdge>();
    public readonly List<GfsCard> Cards = new List<GfsCard>();
    public readonly List<FsElement> Elements = new List<FsElement>();   // static elements
    public int[] Flash = new int[0];
    public int Tol = 8, PosTol = 1;
    public int GlyphRow = 2, GlyphCol = 3;      // FrameLabCard's layout constants
    public long Scored, FailingCount, UnlocatedCount, Errors;
    readonly object gate = new object();
    readonly List<GfsRecord> records = new List<GfsRecord>();

    public GfsRecord[] Records { get { lock (gate) return records.ToArray(); } }

    public int EdgeIndex(string name) {
        for (int i = 0; i < Edges.Count; i++) if (Edges[i].Name == name) return i;
        return -1;
    }

    // ---- locating edges ----------------------------------------------------

    public static double Locate(FsFrame f, GfsEdge e) { bool open; return Locate(f, e, GfsMap.Identity, GfsMap.Identity, out open); }

    // mx/my: where the carrying edges have taken x and y (CarryX[2] /
    // CarryY[2]). open: a majority of the lines met no backdrop and an Open
    // edge put the edge on its boundary.
    public static double Locate(FsFrame f, GfsEdge e, GfsMap mx, GfsMap my, out bool open) {
        open = false;
        var found = new List<int>();
        GfsMap along = e.Vertical ? mx : my, across = e.Vertical ? my : mx;
        int from = along.Apply(e.From), to = along.Apply(e.To);
        int step = to >= from ? 1 : -1;
        int opened = 0;
        foreach (int line0 in e.Lines) {
            int line = across.Apply(line0);
            if (line < 0 || line >= (e.Vertical ? f.H : f.W)) continue;
            // A backdrop scan must cross some backdrop first: a window that has
            // grown past the capture rect has no edge in it to find - unless
            // the edge is Open, when the window starting on the very first
            // pixel IS the edge, on the boundary.
            bool seen = false, first = true;
            for (int i = from; step > 0 ? i <= to : i >= to; i += step) {
                if (i < 0 || i >= (e.Vertical ? f.W : f.H)) continue;
                int px = e.Vertical ? f.At(i, line) : f.At(line, i);
                bool near = GhozttyFrameScore.Near(px, e.Color, e.Tol);
                if (e.Until && !seen) {
                    if (near) seen = true;
                    else {
                        if (e.Open && first) { found.Add(step > 0 ? i : i + 1); opened++; }
                        break;
                    }
                }
                first = false;
                if (near != e.Until) { found.Add(step > 0 ? i : i + 1); break; }
            }
        }
        // A majority of the lines must agree there is an edge at all.
        if (found.Count * 2 <= e.Lines.Length) return double.NaN;
        open = opened * 2 > e.Lines.Length;
        found.Sort();
        return found[found.Count / 2];
    }

    public double[] LocateAll(FsFrame f) { bool[] open; return LocateAll(f, out open); }

    // Every edge in list order, each carried by the earlier edges it names
    // (their displacement from StillPos, the still frame's positions; before
    // Calibrate there is none). An edge whose carrier was not located is not
    // located either.
    public double[] LocateAll(FsFrame f, out bool[] open) {
        var p = new double[Edges.Count];
        open = new bool[Edges.Count];
        for (int i = 0; i < Edges.Count; i++) {
            GfsMap mx, my;
            if (!Carry(Edges[i].CarryX, Edges[i].CarryX2, i, p, out mx) || !Carry(Edges[i].CarryY, Edges[i].CarryY2, i, p, out my)) { p[i] = double.NaN; continue; }
            bool o;
            p[i] = Locate(f, Edges[i], mx, my, out o);
            open[i] = o;
        }
        return p;
    }

    public double[] StillPos;           // the still frame's edge positions, set by Calibrate

    // The map one axis's carriers give: identity before Calibrate or with no
    // carrier; a translation by the near edge's displacement; affine over the
    // near and far edges when both are named and located. False: a carrier
    // was not located (or is not an earlier edge), so neither is this edge.
    bool Carry(string near, string far, int i, double[] p, out GfsMap m) {
        m = GfsMap.Identity;
        if (string.IsNullOrEmpty(near) || StillPos == null) return true;
        int k = EdgeIndex(near);
        if (k < 0 || k >= i || double.IsNaN(p[k]) || double.IsNaN(StillPos[k])) return false;
        double scale = 1.0;
        if (!string.IsNullOrEmpty(far)) {
            int k2 = EdgeIndex(far);
            if (k2 < 0 || k2 >= i || double.IsNaN(p[k2]) || double.IsNaN(StillPos[k2])) return false;
            double span = StillPos[k2] - StillPos[k];
            if (span > 0) scale = (p[k2] - p[k]) / span;
        }
        m = new GfsMap(StillPos[k], p[k], scale);
        return true;
    }

    // A frame whose every Open edge sat on its boundary shows the window
    // maximized (it fills the work area on all four sides). A snapped window
    // keeps a side with backdrop beyond it, so it is not.
    public bool IsMaximized(bool[] open) {
        bool any = false;
        for (int i = 0; i < Edges.Count; i++) {
            if (!Edges[i].Open) continue;
            if (!open[i]) return false;
            any = true;
        }
        return any;
    }

    public bool MaxCalibrated;          // CalibrateMaximized succeeded

    // ---- the card layout (FrameLabCard's rules, in C#) ---------------------

    public int GlyphScale(int cols, int rows, int scale) {
        for (int s = scale; s >= 1; s--)
            if (cols >= GlyphCol + 3 * 2 * s + 2 && rows >= GlyphRow + 5 * s + 2) return s;
        return 0;
    }

    static int PadR(GfsCard c) { return c.PadR >= 0 ? c.PadR : c.PadL; }
    static int PadB(GfsCard c) { return c.PadB >= 0 ? c.PadB : c.PadT; }

    // The FsRegion a card must match when its pane is `pane`: what
    // New-FrameLabCardRegion builds for the grid the app derives from the rect.
    public FsRegion RegionFor(GfsCard c, FsBox pane) {
        var r = new FsRegion();
        r.Name = c.Name; r.Card = pane; r.Bg = c.Bg; r.Ring = c.Ring; r.Glyph = c.Glyph;
        r.Extra = c.Extra; r.Radius = c.Radius;
        if (c.Ring < 0 || c.CellW <= 0 || c.CellH <= 0) { r.Glyph = -1; return r; }
        int cols = Math.Max(0, (pane.W - c.PadL - PadR(c)) / c.CellW);
        int rows = Math.Max(0, (pane.H - c.PadT - PadB(c)) / c.CellH);
        r.RingW = c.CellW; r.RingH = c.CellH;
        r.Slack = new int[] { c.PadL, c.PadT, Math.Max(0, pane.W - c.PadL - cols * c.CellW), Math.Max(0, pane.H - c.PadT - rows * c.CellH) };
        int s = GlyphScale(cols, rows, c.Scale);
        if (s > 0 && c.Glyph >= 0) { r.GlyphW = 3 * 2 * s * c.CellW; r.GlyphH = 5 * s * c.CellH; }
        else r.Glyph = -1;
        return r;
    }

    // Where the card's pane is, given the frame's edge positions; false (and
    // the missing edge's name) when an anchoring edge was not located.
    public bool PaneFor(GfsCard c, double[] pos, out FsBox pane, out string missing) { return PaneFor(c, pos, false, out pane, out missing); }

    public bool PaneFor(GfsCard c, double[] pos, bool max, out FsBox pane, out string missing) {
        int[] v = new int[4];
        int[] off = max ? c.OffsetMax : c.Offset;
        missing = null;
        for (int sd = 0; sd < 4; sd++) {
            string a = c.Anchor[sd];
            if (string.IsNullOrEmpty(a)) { v[sd] = off[sd]; continue; }
            int k = EdgeIndex(a);
            if (k < 0) throw new ArgumentException("card " + c.Name + " rides on an unknown edge '" + a + "'");
            if (double.IsNaN(pos[k])) { missing = a; pane = new FsBox(); return false; }
            v[sd] = (int)Math.Round(pos[k]) + off[sd];
        }
        pane = new FsBox(v[0], v[1], v[2], v[3]);
        return true;
    }

    public FsScene SceneFor(double[] pos, List<string> missing) { return SceneFor(pos, missing, false); }

    public FsScene SceneFor(double[] pos, List<string> missing, bool max) {
        var s = new FsScene();
        s.Flash = Flash; s.Tol = Tol; s.PosTol = PosTol;
        foreach (var c in Cards) {
            FsBox pane; string miss;
            if (!PaneFor(c, pos, max, out pane, out miss)) { missing.Add(c.Name + " (" + miss + ")"); continue; }
            s.Regions.Add(RegionFor(c, pane));
        }
        s.Elements.AddRange(Elements);
        return s;
    }

    // ---- calibration on a still frame ----------------------------------------

    // Measures every card on a settled frame: the ring's bounding box, the
    // padding around it (grown outward through the card's Extra colours), the
    // cell size from the ring's left and top thickness, and each side's offset
    // from the edge it rides on. Returns the reasons it could not, if any.
    public List<string> Calibrate(FsFrame f) {
        var why = new List<string>();
        StillPos = null; MaxCalibrated = false;
        for (int i = 0; i < Edges.Count; i++)
            foreach (string cn in new string[] { Edges[i].CarryX, Edges[i].CarryY, Edges[i].CarryX2, Edges[i].CarryY2 }) {
                if (string.IsNullOrEmpty(cn)) continue;
                int k = EdgeIndex(cn);
                if (k < 0 || k >= i) why.Add("edge " + Edges[i].Name + " is carried by '" + cn + "', which is not an earlier edge");
            }
        double[] pos = LocateAll(f);
        for (int i = 0; i < Edges.Count; i++)
            if (double.IsNaN(pos[i])) why.Add("edge " + Edges[i].Name + " not located on the still frame");
        foreach (var c in Cards) {
            FsBox ring, box; int th, tv;
            if (!MeasureCard(f, c, "the still frame", why, out ring, out box, out th, out tv)) continue;
            c.CellW = th; c.CellH = tv;
            c.Still = box;
            c.StillRing = ring;
            c.PadL = ring.X0 - box.X0; c.PadT = ring.Y0 - box.Y0;
            SetOffsets(c, box, pos, c.Offset, why);
            // The still frame must itself score clean against what was measured,
            // or the scene is wrong before the drag starts.
            FsRegion reg = RegionFor(c, c.Still);
            if (reg.Slack[2] >= c.CellW + PadR(c) + PosTol || reg.Slack[3] >= c.CellH + PadB(c) + PosTol)
                why.Add(string.Format("card {0}: padding right/bottom {1}/{2} is more than a cell plus the pad - the pads given do not match the app", c.Name, reg.Slack[2], reg.Slack[3]));
        }
        StillPos = pos;
        if (why.Count == 0) {
            var miss = new List<string>();
            FsResult res = GhozttyFrameScore.Score(f, SceneFor(pos, miss));
            foreach (var fd in res.Findings) why.Add("the still frame does not score clean: " + fd);
        }
        return why;
    }

    // T2398: the same measurement on a still frame of the window MAXIMIZED,
    // after Calibrate. Every Open edge must sit on its boundary there (or the
    // frame is not of a maximized window), the cell size and padding must be
    // the restored ones, and the frame must score clean against the offsets
    // it yields. Until this succeeds a maximized frame cannot be scored.
    public List<string> CalibrateMaximized(FsFrame f) {
        var why = new List<string>();
        MaxCalibrated = false;
        if (StillPos == null) { why.Add("calibrate the restored still frame before the maximized one"); return why; }
        bool[] open;
        double[] pos = LocateAll(f, out open);
        for (int i = 0; i < Edges.Count; i++)
            if (double.IsNaN(pos[i])) why.Add("edge " + Edges[i].Name + " not located on the maximized still frame");
        if (why.Count == 0 && !IsMaximized(open)) {
            var shut = new List<string>();
            for (int i = 0; i < Edges.Count; i++) if (Edges[i].Open && !open[i]) shut.Add(Edges[i].Name);
            why.Add("the maximized still frame does not show a maximized window: backdrop beyond " + (shut.Count > 0 ? string.Join(", ", shut.ToArray()) : "(no Open edge in this scene)"));
            return why;
        }
        foreach (var c in Cards) {
            FsBox ring, box; int th, tv;
            if (!MeasureCard(f, c, "the maximized still frame", why, out ring, out box, out th, out tv)) continue;
            if (th != c.CellW || tv != c.CellH)
                why.Add(string.Format("card {0}: the maximized still frame's cell is {1}x{2}, the restored one's {3}x{4}", c.Name, th, tv, c.CellW, c.CellH));
            if (ring.X0 - box.X0 != c.PadL || ring.Y0 - box.Y0 != c.PadT)
                why.Add(string.Format("card {0}: the maximized still frame's padding is {1}/{2}, the restored one's {3}/{4}", c.Name, ring.X0 - box.X0, ring.Y0 - box.Y0, c.PadL, c.PadT));
            c.StillMax = box;
            SetOffsets(c, box, pos, c.OffsetMax, why);
        }
        if (why.Count == 0) {
            var miss = new List<string>();
            FsResult res = GhozttyFrameScore.Score(f, SceneFor(pos, miss, true));
            foreach (var fd in res.Findings) why.Add("the maximized still frame does not score clean: " + fd);
            foreach (var m in miss) why.Add("the maximized still frame: no pane for " + m);
        }
        MaxCalibrated = why.Count == 0;
        return why;
    }

    // A card on a settled frame: its ring's bounding box, the cell size from
    // the ring's left and top thickness, and the pane grown outward from the
    // ring through the card's Extra colours (its padding).
    bool MeasureCard(FsFrame f, GfsCard c, string what, List<string> why, out FsBox ring, out FsBox box, out int th, out int tv) {
        ring = new FsBox(); box = new FsBox(); th = 0; tv = 0;
        if (c.Ring < 0) { why.Add("card " + c.Name + " has no ring to calibrate from"); return false; }
        bool any = false; int x0 = 0, y0 = 0, x1 = 0, y1 = 0;
        for (int y = 0; y < f.H; y++)
            for (int x = 0; x < f.W; x++)
                if (GhozttyFrameScore.Near(f.At(x, y), c.Ring, Tol)) {
                    if (!any) { x0 = x; y0 = y; x1 = x + 1; y1 = y + 1; any = true; }
                    if (x < x0) x0 = x; if (y < y0) y0 = y;
                    if (x + 1 > x1) x1 = x + 1; if (y + 1 > y1) y1 = y + 1;
                }
        if (!any) { why.Add("card " + c.Name + ": ring colour not on " + what); return false; }
        ring = new FsBox(x0, y0, x1, y1);
        int my = (y0 + y1) / 2, mx = (x0 + x1) / 2;
        while (x0 + th < x1 && GhozttyFrameScore.Near(f.At(x0 + th, my), c.Ring, Tol)) th++;
        while (y0 + tv < y1 && GhozttyFrameScore.Near(f.At(mx, y0 + tv), c.Ring, Tol)) tv++;
        int l = x0, t = y0, r = x1, b = y1;
        while (l > 0 && IsExtra(c, f.At(l - 1, my))) l--;
        while (t > 0 && IsExtra(c, f.At(mx, t - 1))) t--;
        while (r < f.W && IsExtra(c, f.At(r, my))) r++;
        while (b < f.H && IsExtra(c, f.At(mx, b))) b++;
        box = new FsBox(l, t, r, b);
        return true;
    }

    // Each side's offset from the edge it rides on (a fixed side: its coordinate).
    void SetOffsets(GfsCard c, FsBox box, double[] pos, int[] off, List<string> why) {
        int[] side = { box.X0, box.Y0, box.X1, box.Y1 };
        for (int sd = 0; sd < 4; sd++) {
            string a = c.Anchor[sd];
            if (string.IsNullOrEmpty(a)) { off[sd] = side[sd]; continue; }
            int k = EdgeIndex(a);
            if (k < 0) { why.Add("card " + c.Name + " rides on an unknown edge '" + a + "'"); continue; }
            if (double.IsNaN(pos[k])) continue;
            off[sd] = side[sd] - (int)Math.Round(pos[k]);
        }
    }

    static bool IsExtra(GfsCard c, int px) {
        foreach (int e in c.Extra) if (GhozttyFrameScore.Near(px, e, 8)) return true;
        return false;
    }

    // ---- scoring -----------------------------------------------------------

    public GfsRecord ScoreFrame(FsFrame f, long index, long qpc) {
        var sw = Stopwatch.StartNew();
        var rec = new GfsRecord();
        rec.Index = index; rec.Qpc = qpc;
        bool[] open;
        rec.Edges = LocateAll(f, out open);
        rec.Maximized = IsMaximized(open);
        var missing = new List<string>();
        FsScene scene = SceneFor(rec.Edges, missing, rec.Maximized && MaxCalibrated);
        FsResult res = GhozttyFrameScore.Score(f, scene);
        foreach (string m in missing) {
            var fd = new FsFinding();
            fd.Cls = "LOC"; fd.Target = m; fd.Detail = "an edge this card rides on was not located; the frame cannot be scored";
            res.Findings.Add(fd);
        }
        if (rec.Maximized && !MaxCalibrated) {
            var fd = new FsFinding();
            fd.Cls = "LOC"; fd.Target = "window";
            fd.Detail = "the window is maximized on this frame and no maximized still frame was calibrated; the frame cannot be scored";
            res.Findings.Add(fd);
        }
        rec.Failing = res.Findings.Count > 0;
        if (rec.Failing) rec.Findings = res.Findings.ToArray();
        sw.Stop();
        rec.Ms = sw.Elapsed.TotalMilliseconds;
        lock (gate) {
            records.Add(rec);
            Scored++;
            if (rec.Failing) FailingCount++;
            if (missing.Count > 0) UnlocatedCount++;
        }
        return rec;
    }

    // The GfcScorer FrameCapture's worker calls: the frame's pixels are
    // wrapped, not copied (both are 0x..RRGGBB ints; FsFrame masks alpha).
    public bool Score(GfcFrame g) {
        try {
            var f = new FsFrame(0, 0);
            f.W = g.W; f.H = g.H; f.Px = g.Px;
            return ScoreFrame(f, g.Index, g.Qpc).Failing;
        } catch {
            lock (gate) Errors++;
            throw;
        }
    }

    public GfcScorer AsScorer() { return new GfcScorer(Score); }

    // One tracked edge's position per scored frame, in record order.
    public double[] Series(string edge) {
        int k = EdgeIndex(edge);
        if (k < 0) throw new ArgumentException("no edge '" + edge + "'");
        var rs = Records;
        var o = new double[rs.Length];
        for (int i = 0; i < rs.Length; i++) o[i] = rs[i].Edges[k];
        return o;
    }
}
'@

function Import-FrameLabScene {
    if ('GfsSceneScorer' -as [type]) { return }
    Import-FrameScore
    Import-FrameCapture
    $gfc = [GfcFrame].Assembly.Location
    $fs = $script:FrameScoreDll
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $key = $script:FrameLabSceneSource + "|" + [IO.Path]::GetFileName($fs) + "|" + [IO.Path]::GetFileName($gfc)
    $hash = -join ($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($key))[0..7] | ForEach-Object { $_.ToString('x2') })
    $dir = Join-Path $env:TEMP 'ghoztty-framescore'
    $dll = Join-Path $dir "gfs-$hash.dll"
    if (-not (Test-Path $dll)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $src = Join-Path $dir "gfs-$hash.cs"
        [System.IO.File]::WriteAllText($src, $script:FrameLabSceneSource, (New-Object System.Text.UTF8Encoding $false))
        $fw = [System.Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()
        $tmp = "$dll.$PID.tmp"
        $out = & (Join-Path $fw 'csc.exe') /nologo /target:library /optimize+ "/out:$tmp" `
            "/r:$fs" "/r:$gfc" "/r:$(Join-Path $fw 'System.Drawing.dll')" $src 2>&1
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $tmp)) {
            throw "FrameLabScene: csc failed ($LASTEXITCODE): $($out -join ' | ')"
        }
        try { Move-Item -Force $tmp $dll -ErrorAction Stop }
        catch { if (-not (Test-Path $dll)) { throw }; Remove-Item $tmp -ErrorAction SilentlyContinue }
    }
    [System.Reflection.Assembly]::LoadFrom($dll) | Out-Null
}

<#
An edge the scorer tracks. -Backdrop: scan from -From toward -To until the
pixel stops being -Color (a window edge, scanned in from the solid backdrop
behind it). Otherwise stop at the first pixel that IS -Color (a divider, the
sidebar's edge). -Vertical: the edge is an x and -Lines are rows; else a y
scanned along columns.
#>
function New-FrameLabSceneEdge {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet('window-left', 'window-top', 'window-right', 'window-bottom', 'divider', 'sidebar-edge')][string]$Kind,
        [Parameter(Mandatory = $true)][int[]]$Lines,
        [Parameter(Mandatory = $true)][int]$From,
        [Parameter(Mandatory = $true)][int]$To,
        [Parameter(Mandatory = $true)][int]$Color,
        [switch]$Backdrop,
        [switch]$Vertical,
        # T2398: -Open (a backdrop edge on the work area's boundary - see GfsEdge)
        # and the earlier edges whose displacement carries this one's scan.
        [switch]$Open,
        [string]$CarryX,
        [string]$CarryY,
        [string]$CarryX2,
        [string]$CarryY2,
        [int]$Tol = 8
    )
    Import-FrameLabScene
    if ($Open -and -not $Backdrop) { throw "New-FrameLabSceneEdge: -Open is for a backdrop edge ($Name)" }
    $e = New-Object GfsEdge
    $e.Name = $Name; $e.Kind = $Kind; $e.Lines = $Lines; $e.From = $From; $e.To = $To
    $e.Color = $Color; $e.Until = [bool]$Backdrop; $e.Vertical = [bool]$Vertical; $e.Tol = $Tol
    $e.Open = [bool]$Open
    if ($CarryX) { $e.CarryX = $CarryX }
    if ($CarryY) { $e.CarryY = $CarryY }
    if ($CarryX2) { if (-not $CarryX) { throw "New-FrameLabSceneEdge: -CarryX2 needs -CarryX ($Name)" }; $e.CarryX2 = $CarryX2 }
    if ($CarryY2) { if (-not $CarryY) { throw "New-FrameLabSceneEdge: -CarryY2 needs -CarryY ($Name)" }; $e.CarryY2 = $CarryY2 }
    return $e
}

<#
A pane's card for the scorer. -Index picks FrameLabCard's palette; -Anchor is
four edge names (L T R B), '' for a side that does not move. Cell size,
padding and offsets are measured by the scorer's Calibrate() on a still frame;
-PadRight/-PadBottom say how much of the right/bottom gap is the theme's
padding (default: the same as left/top, as Ghostty's window-padding is).
#>
function New-FrameLabSceneCard {
    param(
        [Parameter(Mandatory = $true)][ValidateRange(1, 9)][int]$Index,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string[]]$Anchor,
        [int[]]$Extra = @(),
        [int]$PadRight = -1,
        [int]$PadBottom = -1,
        [int]$Scale = 2,
        [string]$Name
    )
    Import-FrameLabScene
    if ($Anchor.Count -ne 4) { throw 'New-FrameLabSceneCard: -Anchor is four edge names (L T R B), empty for a fixed side' }
    $colors = Get-FrameLabCardColors -Index $Index
    $c = New-Object GfsCard
    $c.Name = $(if ($Name) { $Name } else { "card$Index" })
    $c.Bg = $colors.Bg; $c.Ring = $colors.Ring; $c.Glyph = $colors.Glyph
    $c.Extra = [int[]]$Extra
    $c.PadR = $PadRight; $c.PadB = $PadBottom; $c.Scale = $Scale
    $c.Anchor = [string[]]@($Anchor | ForEach-Object { if ($_) { $_ } else { $null } })
    return $c
}

# A scorer over these edges and cards, calibrated on -Still (an FsFrame).
# Throws with every reason when the still frame cannot be read or does not
# score clean against what was measured.
function New-FrameLabSceneScorer {
    param(
        [Parameter(Mandatory = $true)][object[]]$Edges,
        [Parameter(Mandatory = $true)][object[]]$Cards,
        [Parameter(Mandatory = $true)]$Still,
        [int[]]$Flash = @(),
        [object[]]$Elements = @(),
        [int]$Tol = 8,
        [int]$PosTol = 1
    )
    Import-FrameLabScene
    $s = New-Object GfsSceneScorer
    foreach ($e in $Edges) { $s.Edges.Add($e) }
    foreach ($c in $Cards) { $s.Cards.Add($c) }
    foreach ($el in $Elements) { $s.Elements.Add($el) }
    $s.Flash = [int[]]$Flash; $s.Tol = $Tol; $s.PosTol = $PosTol
    $s.GlyphRow = $script:FrameLabGlyphRow; $s.GlyphCol = $script:FrameLabGlyphCol
    $why = $s.Calibrate($Still)
    if ($why.Count -gt 0) { throw "FrameLabScene: calibration failed: $($why -join '; ')" }
    return $s
}

# What Measure-FrameMotion takes for one tracked edge: Time (ms on the capture
# clock, from -StartQpc) and Position per scored frame.
function Get-FrameLabSceneMotion {
    param(
        [Parameter(Mandatory = $true)]$Scorer,
        [Parameter(Mandatory = $true)][string]$Edge,
        [Parameter(Mandatory = $true)][long]$QpcFrequency,
        [long]$StartQpc = 0
    )
    $recs = $Scorer.Records
    $t = New-Object double[] $recs.Length
    for ($i = 0; $i -lt $recs.Length; $i++) { $t[$i] = ($recs[$i].Qpc - $StartQpc) * 1000.0 / $QpcFrequency }
    return [pscustomobject]@{ Time = $t; Position = $Scorer.Series($Edge) }
}
