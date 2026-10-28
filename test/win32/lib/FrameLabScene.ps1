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
    public string Kind = "";            // window-right | window-bottom | divider | sidebar-edge
    public bool Vertical = true;        // a vertical edge (an x), scanned along rows
    public int[] Lines = new int[0];    // the rows (Vertical) or columns scanned
    public int From, To;                // scan range along each line, From toward To, inclusive
    public int Color;
    public bool Until;                  // true: stop at the first pixel NOT near Color (a backdrop)
                                        // false: stop at the first pixel near it (a divider)
    public int Tol = 8;
    // Position is a pixel BOUNDARY: scanning upward it is the found pixel's
    // coordinate (where the thing starts); scanning downward it is one past it
    // (an exclusive right/bottom bound). So window-right scanned in from the
    // backdrop is the window's exclusive right, and a divider scanned from the
    // pane on its left is that pane's exclusive right.
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
}

public sealed class GfsRecord {
    public long Index, Qpc;
    public bool Failing;
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

    public static double Locate(FsFrame f, GfsEdge e) {
        var found = new List<int>();
        int step = e.To >= e.From ? 1 : -1;
        foreach (int line in e.Lines) {
            if (line < 0 || line >= (e.Vertical ? f.H : f.W)) continue;
            // A backdrop scan must cross some backdrop first: a window that has
            // grown past the capture rect has no edge in it to find.
            bool seen = false;
            for (int i = e.From; step > 0 ? i <= e.To : i >= e.To; i += step) {
                if (i < 0 || i >= (e.Vertical ? f.W : f.H)) continue;
                int px = e.Vertical ? f.At(i, line) : f.At(line, i);
                bool near = GhozttyFrameScore.Near(px, e.Color, e.Tol);
                if (e.Until && !seen) { if (near) seen = true; else break; }
                if (near != e.Until) { found.Add(step > 0 ? i : i + 1); break; }
            }
        }
        // A majority of the lines must agree there is an edge at all.
        if (found.Count * 2 <= e.Lines.Length) return double.NaN;
        found.Sort();
        return found[found.Count / 2];
    }

    public double[] LocateAll(FsFrame f) {
        var p = new double[Edges.Count];
        for (int i = 0; i < Edges.Count; i++) p[i] = Locate(f, Edges[i]);
        return p;
    }

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
    public bool PaneFor(GfsCard c, double[] pos, out FsBox pane, out string missing) {
        int[] v = new int[4];
        missing = null;
        for (int sd = 0; sd < 4; sd++) {
            string a = c.Anchor[sd];
            if (string.IsNullOrEmpty(a)) { v[sd] = c.Offset[sd]; continue; }
            int k = EdgeIndex(a);
            if (k < 0) throw new ArgumentException("card " + c.Name + " rides on an unknown edge '" + a + "'");
            if (double.IsNaN(pos[k])) { missing = a; pane = new FsBox(); return false; }
            v[sd] = (int)Math.Round(pos[k]) + c.Offset[sd];
        }
        pane = new FsBox(v[0], v[1], v[2], v[3]);
        return true;
    }

    public FsScene SceneFor(double[] pos, List<string> missing) {
        var s = new FsScene();
        s.Flash = Flash; s.Tol = Tol; s.PosTol = PosTol;
        foreach (var c in Cards) {
            FsBox pane; string miss;
            if (!PaneFor(c, pos, out pane, out miss)) { missing.Add(c.Name + " (" + miss + ")"); continue; }
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
        double[] pos = LocateAll(f);
        for (int i = 0; i < Edges.Count; i++)
            if (double.IsNaN(pos[i])) why.Add("edge " + Edges[i].Name + " not located on the still frame");
        foreach (var c in Cards) {
            if (c.Ring < 0) { why.Add("card " + c.Name + " has no ring to calibrate from"); continue; }
            bool any = false; int x0 = 0, y0 = 0, x1 = 0, y1 = 0;
            for (int y = 0; y < f.H; y++)
                for (int x = 0; x < f.W; x++)
                    if (GhozttyFrameScore.Near(f.At(x, y), c.Ring, Tol)) {
                        if (!any) { x0 = x; y0 = y; x1 = x + 1; y1 = y + 1; any = true; }
                        if (x < x0) x0 = x; if (y < y0) y0 = y;
                        if (x + 1 > x1) x1 = x + 1; if (y + 1 > y1) y1 = y + 1;
                    }
            if (!any) { why.Add("card " + c.Name + ": ring colour not on the still frame"); continue; }
            var ring = new FsBox(x0, y0, x1, y1);
            int my = (y0 + y1) / 2, mx = (x0 + x1) / 2;
            int th = 0; while (x0 + th < x1 && GhozttyFrameScore.Near(f.At(x0 + th, my), c.Ring, Tol)) th++;
            int tv = 0; while (y0 + tv < y1 && GhozttyFrameScore.Near(f.At(mx, y0 + tv), c.Ring, Tol)) tv++;
            c.CellW = th; c.CellH = tv;
            int l = x0, t = y0, r = x1, b = y1;
            while (l > 0 && IsExtra(c, f.At(l - 1, my))) l--;
            while (t > 0 && IsExtra(c, f.At(mx, t - 1))) t--;
            while (r < f.W && IsExtra(c, f.At(r, my))) r++;
            while (b < f.H && IsExtra(c, f.At(mx, b))) b++;
            c.Still = new FsBox(l, t, r, b);
            c.StillRing = ring;
            c.PadL = x0 - l; c.PadT = y0 - t;
            int[] side = { l, t, r, b };
            for (int sd = 0; sd < 4; sd++) {
                string a = c.Anchor[sd];
                if (string.IsNullOrEmpty(a)) { c.Offset[sd] = side[sd]; continue; }
                int k = EdgeIndex(a);
                if (k < 0) { why.Add("card " + c.Name + " rides on an unknown edge '" + a + "'"); continue; }
                if (double.IsNaN(pos[k])) continue;
                c.Offset[sd] = side[sd] - (int)Math.Round(pos[k]);
            }
            // The still frame must itself score clean against what was measured,
            // or the scene is wrong before the drag starts.
            FsRegion reg = RegionFor(c, c.Still);
            if (reg.Slack[2] >= c.CellW + PadR(c) + PosTol || reg.Slack[3] >= c.CellH + PadB(c) + PosTol)
                why.Add(string.Format("card {0}: padding right/bottom {1}/{2} is more than a cell plus the pad - the pads given do not match the app", c.Name, reg.Slack[2], reg.Slack[3]));
        }
        if (why.Count == 0) {
            var miss = new List<string>();
            FsResult res = GhozttyFrameScore.Score(f, SceneFor(pos, miss));
            foreach (var fd in res.Findings) why.Add("the still frame does not score clean: " + fd);
        }
        return why;
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
        rec.Edges = LocateAll(f);
        var missing = new List<string>();
        FsScene scene = SceneFor(rec.Edges, missing);
        FsResult res = GhozttyFrameScore.Score(f, scene);
        foreach (string m in missing) {
            var fd = new FsFinding();
            fd.Cls = "LOC"; fd.Target = m; fd.Detail = "an edge this card rides on was not located; the frame cannot be scored";
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
        [Parameter(Mandatory = $true)][ValidateSet('window-right', 'window-bottom', 'divider', 'sidebar-edge')][string]$Kind,
        [Parameter(Mandatory = $true)][int[]]$Lines,
        [Parameter(Mandatory = $true)][int]$From,
        [Parameter(Mandatory = $true)][int]$To,
        [Parameter(Mandatory = $true)][int]$Color,
        [switch]$Backdrop,
        [switch]$Vertical,
        [int]$Tol = 8
    )
    Import-FrameLabScene
    $e = New-Object GfsEdge
    $e.Name = $Name; $e.Kind = $Kind; $e.Lines = $Lines; $e.From = $From; $e.To = $To
    $e.Color = $Color; $e.Until = [bool]$Backdrop; $e.Vertical = [bool]$Vertical; $e.Tol = $Tol
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
