<#
.SYNOPSIS
  The per-frame scorer for test\win32\divider-ghost.ps1 (T2441): what a
  composed frame of a REAL-POINTER divider drag must never show (T2418).

.DESCRIPTION
  T2418's report: dragging the divider beside the left pane to the right
  leaves stale copies of the bar behind it, and the widening pane does not
  repaint while the drag is in progress. Two visible classes:

    class 1  a GHOST bar: the mid row shows the drag-coloured bar more than
             once - a sliver of an old position left in the pane that grew
             over it - or one run wider than the bar (a SMEAR of two
             adjacent positions).
    class 2  a STALE STRIP: the columns the widening pane has just grown into
             still show what was there before - the old right pane's first
             column, its padding, the old bar - so the right pane's edge
             reads doubled.

  One DgScorer is armed per drag from two frames the harness photographs
  before the drag moves: the HOVER frame (pointer over the bar, no button)
  and the PRESSED frame (button down, nothing moved). From them it learns the
  hover and drag colours, where the bar starts (BarLeft..BarRight), and the
  STRIP ROWS: rows where the left pane is blank just left of the bar AND the
  zone right of the bar differs from that blank colour, so an unrepainted
  zone is distinguishable from a repainted one on that row. Per frame:

    Runs    drag-coloured runs on the mid line between Lo and Hi (gaps of up
            to MinGap px are one run). More than one is a GHOST frame.
    Widest  the widest of them. Over MaxW is a SMEAR frame.
    BarAt   where the RIGHTMOST run starts - the bar's live position (a
            ghost is always behind it, to the left, on a rightward drag).
    Hover   1 when the mid line has no drag-coloured run but a hover-coloured
            one: the button is up (before the press or after the release).
            Such a frame is not a drag frame and is never scored.
    Strip   on the strip rows, pixels in the grown zone - from BarRight + 1
            up to BarAt - Margin - that are not near the row's blank colour.
            Over StripSlack is a STALE STRIP frame. -1 when there is no bar
            to measure the zone against (that frame is GONE instead).

  A frame with neither a drag nor a hover run on the mid line is a GONE frame:
  the bar vanished mid-drag.

  Pure pixel arithmetic, so the harness proves every reading on frames whose
  truth is known, anywhere, with no app and no capture.
#>

function Import-DividerGhostScore {
    if ('DgScorer' -as [type]) { return }
    if (-not ('GfcFrame' -as [type])) { throw 'Import-DividerGhostScore: Import-FrameCapture first (it defines GfcFrame)' }
    $gfc = [GfcFrame].Assembly.Location
    Add-Type -ReferencedAssemblies $gfc -TypeDefinition @'
using System;
using System.Collections.Generic;
public sealed class DgScorer {
    public int Line, Lo, Hi;                  // the mid row, and the x range the bar can occupy
    public int Drag = -1, Hover = -1, Tol = 12, MinGap = 3, MaxW = 8;
    public int BarLeft, BarRight;             // the bar in the PRESSED frame
    public int Margin = 2, StripSlack = 2;
    public int[] StripRows = new int[0], StripColors = new int[0];

    public readonly List<long> Index = new List<long>();
    public readonly List<int> Runs = new List<int>();
    public readonly List<int> Widest = new List<int>();
    public readonly List<int> BarAt = new List<int>();
    public readonly List<int> HoverFrame = new List<int>();
    public readonly List<int> Strip = new List<int>();
    public readonly List<string> RunText = new List<string>();

    public static bool Near(int a, int b, int t) {
        return Math.Abs(((a >> 16) & 255) - ((b >> 16) & 255)) <= t
            && Math.Abs(((a >> 8) & 255) - ((b >> 8) & 255)) <= t
            && Math.Abs((a & 255) - (b & 255)) <= t;
    }

    // Runs of colour c along row y in [x0, x1): {start, end} inclusive pairs.
    public static List<int[]> RunsOf(GfcFrame f, int y, int x0, int x1, int c, int tol, int minGap) {
        var runs = new List<int[]>();
        if (c < 0 || y < 0 || y >= f.H) return runs;
        x0 = Math.Max(0, x0); x1 = Math.Min(f.W, x1);
        int start = -1, lastOn = -100;
        for (int x = x0; x < x1; x++) {
            if (!Near(f.Px[y * f.W + x], c, tol)) continue;
            if (start >= 0 && x - lastOn <= minGap) { lastOn = x; continue; }
            if (start >= 0) runs.Add(new int[] { start, lastOn });
            start = x; lastOn = x;
        }
        if (start >= 0) runs.Add(new int[] { start, lastOn });
        return runs;
    }

    // The run of colour c on row y that is nearest x (within reach px); null when none.
    public static int[] RunNear(GfcFrame f, int y, int x, int reach, int c, int tol) {
        int[] best = null; int bestD = int.MaxValue;
        foreach (var r in RunsOf(f, y, x - reach, x + reach + 1, c, tol, 1)) {
            int d = x < r[0] ? r[0] - x : (x > r[1] ? x - r[1] : 0);
            if (d < bestD) { bestD = d; best = r; }
        }
        return best;
    }

    // Choose up to maxRows strip rows in [top, bottom) from the PRESSED frame:
    // the left side [barLeft - leftSpan, barLeft - margin) is one colour (the
    // left pane is blank there), and the zone (barRight, barRight + travel]
    // holds at least one pixel that is NOT that colour, so a zone that was not
    // repainted reads differently from one that was. Rows within avoid px of
    // skipY are left out. Sets StripRows and StripColors; returns the count.
    public int PickStripRows(GfcFrame f, int top, int bottom, int travel, int leftSpan, int skipY, int avoid, int maxRows) {
        var rows = new List<int>(); var cols = new List<int>();
        top = Math.Max(0, top); bottom = Math.Min(f.H, bottom);
        int lx0 = Math.Max(0, BarLeft - leftSpan), lx1 = BarLeft - Margin;
        int zx0 = BarRight + 1, zx1 = Math.Min(f.W, BarRight + travel + 1);
        if (lx1 <= lx0 || zx1 <= zx0) { StripRows = new int[0]; StripColors = new int[0]; return 0; }
        var cand = new List<int[]>();
        for (int y = top; y < bottom; y++) {
            if (Math.Abs(y - skipY) <= avoid) continue;
            int refc = f.Px[y * f.W + (lx1 - 1)];
            bool blank = true;
            for (int x = lx0; x < lx1 && blank; x++) if (!Near(f.Px[y * f.W + x], refc, Tol)) blank = false;
            if (!blank) continue;
            int differ = 0;
            for (int x = zx0; x < zx1; x++) if (!Near(f.Px[y * f.W + x], refc, Tol)) differ++;
            if (differ == 0) continue;
            cand.Add(new int[] { y, refc });
        }
        if (cand.Count > 0) {
            int take = Math.Min(maxRows, cand.Count);
            for (int i = 0; i < take; i++) {
                var c = cand[(int)((long)i * cand.Count / take)];
                rows.Add(c[0]); cols.Add(c[1]);
            }
        }
        StripRows = rows.ToArray(); StripColors = cols.ToArray();
        return StripRows.Length;
    }

    public bool Score(GfcFrame f) {
        var runs = RunsOf(f, Line, Lo, Hi, Drag, Tol, MinGap);
        int widest = 0, at = -1;
        var sb = new System.Text.StringBuilder();
        foreach (var r in runs) {
            widest = Math.Max(widest, r[1] - r[0] + 1);
            at = r[0];                                  // the last (rightmost) run wins
            sb.Append(r[0]).Append('-').Append(r[1]).Append(' ');
        }
        int hover = 0;
        if (runs.Count == 0 && Hover >= 0 && RunsOf(f, Line, Lo, Hi, Hover, Tol, MinGap).Count > 0) hover = 1;
        int strip = -1;
        if (at >= 0) {
            strip = 0;
            int zx0 = Math.Max(0, BarRight + 1), zx1 = Math.Min(f.W, at - Margin);
            for (int i = 0; i < StripRows.Length; i++) {
                int y = StripRows[i];
                if (y < 0 || y >= f.H) continue;
                for (int x = zx0; x < zx1; x++) if (!Near(f.Px[y * f.W + x], StripColors[i], Tol)) strip++;
            }
        }
        lock (Index) {
            Index.Add(f.Index); Runs.Add(runs.Count); Widest.Add(widest); BarAt.Add(at);
            HoverFrame.Add(hover); Strip.Add(strip); RunText.Add(sb.ToString().Trim());
        }
        return true;
    }

    // A frame's verdict: "" when clean or not a drag frame, else the classes it shows.
    public string Verdict(int i) {
        if (HoverFrame[i] == 1) return "";
        if (Runs[i] == 0) return "GONE";
        var v = new List<string>();
        if (Runs[i] > 1) v.Add("GHOST");
        if (Widest[i] > MaxW) v.Add("SMEAR");
        if (Strip[i] > StripSlack) v.Add("STRIP");
        return string.Join("+", v.ToArray());
    }

    public void Clear() {
        Index.Clear(); Runs.Clear(); Widest.Clear(); BarAt.Clear(); HoverFrame.Clear(); Strip.Clear(); RunText.Clear();
    }

    public GfcScorer AsScorer() { return new GfcScorer(Score); }
}
'@
}

<#
The drag's summary over everything the scorer recorded: counts per class, the
frames that were scored (drag frames), the bar's travel, and a worst list
naming capture indexes. Pure; the harness asserts on it.
#>
function Get-DividerGhostSummary($Scorer, [int]$WorstMax = 12) {
    $n = $Scorer.Index.Count
    $c = @{ GHOST = 0; SMEAR = 0; STRIP = 0; GONE = 0 }
    $drag = 0; $hover = 0; $minAt = [int]::MaxValue; $maxAt = -1; $worst = @()
    for ($i = 0; $i -lt $n; $i++) {
        if ($Scorer.HoverFrame[$i] -eq 1) { $hover++; continue }
        $drag++
        $at = $Scorer.BarAt[$i]
        if ($at -ge 0) { $minAt = [math]::Min($minAt, $at); $maxAt = [math]::Max($maxAt, $at) }
        $v = $Scorer.Verdict($i)
        if (-not $v) { continue }
        foreach ($k in $v.Split('+')) { $c[$k]++ }
        if ($worst.Count -lt $WorstMax) { $worst += "#$($Scorer.Index[$i]) $v [$($Scorer.RunText[$i])] strip=$($Scorer.Strip[$i])" }
    }
    $travel = $(if ($maxAt -ge 0) { $maxAt - $Scorer.BarLeft } else { 0 })
    [pscustomobject]@{
        Frames = $n; DragFrames = $drag; HoverFrames = $hover
        Ghost = $c.GHOST; Smear = $c.SMEAR; Strip = $c.STRIP; Gone = $c.GONE
        Bad = @(for ($i = 0; $i -lt $n; $i++) { if ($Scorer.Verdict($i)) { $i } }).Count
        Travel = $travel; Worst = $worst
    }
}
