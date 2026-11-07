<#
.SYNOPSIS
  The per-frame scorer for test\win32\divider-flicker.ps1 (T2476): what a
  composed frame of a divider drag must never show.

.DESCRIPTION
  One DfScorer is armed per drag, from the PRESSED frame (button down, bar in
  its drag colour, nothing moved yet), and handed to Start-FrameCapture as
  its scorer. Per frame it records four readings:

    Dark    near-black pixels (all channels under Level) anywhere in the
            frame. Over DarkThreshold (the pressed frame's count + slack) is
            a DARK frame: a strip something grew and nothing painted (T2400's
            banner region order and its ULW present).
    BarRun  accent-coloured pixels on the MID line, the row (or column, for a
            horizontal divider) through the panes across the divider, between
            Lo and Hi. Zero is a BAR-GONE frame: the old gutter was flooded
            with flat background before the new bands painted (T2400's
            gutter clear; GHOZTTY_CLEAR_WHOLE_GUTTERS restores it). BarAt is
            where the run starts, which is also the proof the drag moved.
    Bite    for a vertical divider with a banner beside it: accent pixels on
            the mid line whose column is NOT accent on a banner row, summed
            over BannerLines. Over BiteBase (the pressed frame's own count)
            is a BITTEN frame: a banner still at its old rect covering the
            bar just painted (T2414; GHOZTTY_OVERLAYS_AFTER_BANDS restores it).
    Kind    what a frame over BiteBase actually shows (T2647). Three shapes
            put a mid-line accent column over a non-accent banner row, and
            only the first is a banner bite:
              1 BITE  the banner strip stands over the bar: no banner row
                      carries a bar-wide accent run of its own;
              2 TORN  every banner row carries the bar whole (a run at least
                      the mid run's width less 2 px) but at a different x
                      from the mid row's, by 2 px or more: the bar's banner
                      segment reached the screen a frame apart from the rest
                      (T2648);
              3 GHOST the mid line has TWO accent runs (each 2 px or wider,
                      2 px or more apart): a sliver of the old bar left in
                      the terminal that grew over it (T2651).
            GHOST is tested first: its two runs make the mid width
            meaningless for the TORN test. 0 is a frame that is not bitten.
    Edges   for a viewer beside a vertical divider: on each of EdgeRows, the
            first x at or after EdgeX0 whose colour is near that row's colour
            - the address bar's left edge and the page's. Their offset moving
            by more than 2 px is the page landing in a different compositor
            frame from the GDI chrome. REPORTED, never failed, until T2360.

  Pure pixel arithmetic, so section A of the harness proves it on frames whose
  truth is known, anywhere, with no app and no capture.
#>

function Import-DividerFlickerScore {
    if ('DfScorer' -as [type]) { return }
    if (-not ('GfcFrame' -as [type])) { throw 'Import-DividerFlickerScore: Import-FrameCapture first (it defines GfcFrame)' }
    $gfc = [GfcFrame].Assembly.Location
    Add-Type -ReferencedAssemblies $gfc -TypeDefinition @'
using System;
using System.Collections.Generic;
public sealed class DfScorer {
    public int Level = 14, DarkThreshold = int.MaxValue;
    public bool Transposed;              // true: a horizontal divider, the mid line is a column
    public int Line, Lo, Hi;             // the mid line, and the range along it the bar can occupy
    public int Accent, Tol = 12;
    public int[] BannerLines = new int[0];
    public int BiteBase;
    public int[] EdgeRows = new int[0], EdgeColors = new int[0];
    public int EdgeX0, EdgeX1, EdgeTol = 10;

    public readonly List<long> Index = new List<long>();
    public readonly List<int> Dark = new List<int>();
    public readonly List<int> BarRun = new List<int>();
    public readonly List<int> BarAt = new List<int>();
    public readonly List<int> Bite = new List<int>();
    public readonly List<int> Kind = new List<int>();
    public readonly List<int[]> Edges = new List<int[]>();
    public const int KindNone = 0, KindBite = 1, KindTorn = 2, KindGhost = 3;

    public static bool Near(int a, int b, int t) {
        return Math.Abs(((a >> 16) & 255) - ((b >> 16) & 255)) <= t
            && Math.Abs(((a >> 8) & 255) - ((b >> 8) & 255)) <= t
            && Math.Abs((a & 255) - (b & 255)) <= t;
    }
    public static int CountDark(GfcFrame f, int level) {
        int n = 0; var p = f.Px;
        for (int i = 0; i < p.Length; i++) {
            int c = p[i];
            if (((c >> 16) & 255) < level && ((c >> 8) & 255) < level && (c & 255) < level) n++;
        }
        return n;
    }
    // The pixel `along` the mid line (x for a vertical divider, y for a
    // horizontal one); `line` replaces the mid line, for the banner rows.
    int At(GfcFrame f, int along, int line) {
        return Transposed ? f.Px[along * f.W + line] : f.Px[line * f.W + along];
    }
    int Extent(GfcFrame f) { return Transposed ? f.H : f.W; }
    int Depth(GfcFrame f) { return Transposed ? f.W : f.H; }

    // The accent runs along `line` within [Lo, Hi): {start, width} pairs, a
    // run ending at the first non-accent pixel. Runs under 2 px are noise
    // (an anti-aliased edge) and are dropped.
    List<int[]> Runs(GfcFrame f, int line) {
        var runs = new List<int[]>();
        int lo = Math.Max(0, Lo), hi = Math.Min(Extent(f), Hi), start = -1;
        for (int a = lo; a <= hi; a++) {
            bool acc = a < hi && Near(At(f, a, line), Accent, Tol);
            if (acc && start < 0) start = a;
            if (!acc && start >= 0) { if (a - start >= 2) runs.Add(new int[] { start, a - start }); start = -1; }
        }
        return runs;
    }
    // A bitten frame's shape (Kind above); `at`/`run` are the mid line's.
    int Classify(GfcFrame f, int at, int run) {
        var mid = Runs(f, Line);
        if (mid.Count >= 2) {
            for (int i = 1; i < mid.Count; i++)
                if (mid[i][0] - (mid[i - 1][0] + mid[i - 1][1]) >= 2) return KindGhost;
        }
        int need = Math.Max(2, run - 2), seen = 0;
        foreach (int y in BannerLines) {
            if (y < 0 || y >= f.H) continue;
            bool torn = false;
            foreach (var r in Runs(f, y)) if (r[1] >= need && Math.Abs(r[0] - at) >= 2) { torn = true; break; }
            if (!torn) return KindBite;
            seen++;
        }
        return seen > 0 ? KindTorn : KindBite;
    }

    // {dark, run, at, bite, kind}
    public int[] Read(GfcFrame f) {
        int dark = CountDark(f, Level), run = 0, at = -1, bite = 0, kind = KindNone;
        if (Line >= 0 && Line < Depth(f)) {
            int lo = Math.Max(0, Lo), hi = Math.Min(Extent(f), Hi);
            for (int a = lo; a < hi; a++) {
                if (!Near(At(f, a, Line), Accent, Tol)) continue;
                if (at < 0) at = a;
                run++;
                if (Transposed) continue;
                foreach (int y in BannerLines) if (y >= 0 && y < f.H && !Near(f.Px[y * f.W + a], Accent, Tol)) bite++;
            }
            if (!Transposed && bite > BiteBase && at >= 0) kind = Classify(f, at, run);
        }
        return new int[] { dark, run, at, bite, kind };
    }
    public int[] EdgesOf(GfcFrame f) {
        var e = new int[EdgeRows.Length];
        for (int r = 0; r < EdgeRows.Length; r++) {
            e[r] = -1;
            int y = EdgeRows[r]; if (y < 0 || y >= f.H) continue;
            for (int x = Math.Max(0, EdgeX0); x < Math.Min(f.W, EdgeX1); x++)
                if (Near(f.Px[y * f.W + x], EdgeColors[r], EdgeTol)) { e[r] = x; break; }
        }
        return e;
    }
    public bool Score(GfcFrame f) {
        var r = Read(f);
        var e = EdgesOf(f);
        lock (Index) { Index.Add(f.Index); Dark.Add(r[0]); BarRun.Add(r[1]); BarAt.Add(r[2]); Bite.Add(r[3]); Kind.Add(r[4]); Edges.Add(e); }
        return r[0] > DarkThreshold || r[1] == 0 || r[3] > BiteBase;
    }
    public GfcScorer AsScorer() { return new GfcScorer(Score); }
    public void Clear() { lock (Index) { Index.Clear(); Dark.Clear(); BarRun.Clear(); BarAt.Clear(); Bite.Clear(); Kind.Clear(); Edges.Clear(); } }
}
'@
}

<#
The drag's counts from an armed, scored DfScorer. A frame is counted once per
defect, and a bitten frame under exactly one of Bitten / Torn / Ghost (T2647); `Worst` names the first few offenders by capture index so a red line
points at the PNGs. EdgeMismatch is $null when no edge rows were armed, and
EdgeLost counts frames where either edge was not found at all.
#>
function Get-DividerFlickerCounts {
    param([Parameter(Mandatory = $true)]$Scorer, [int]$Worst = 12)
    $n = $Scorer.Index.Count
    $dark = New-Object System.Collections.ArrayList
    $gone = New-Object System.Collections.ArrayList
    $bit = New-Object System.Collections.ArrayList
    $torn = New-Object System.Collections.ArrayList
    $ghost = New-Object System.Collections.ArrayList
    $ats = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $n; $i++) {
        $ix = $Scorer.Index[$i]
        if ($Scorer.Dark[$i] -gt $Scorer.DarkThreshold) { [void]$dark.Add("#$ix=$($Scorer.Dark[$i])") }
        if ($Scorer.BarRun[$i] -eq 0) { [void]$gone.Add("#$ix") }
        if ($Scorer.Bite[$i] -gt $Scorer.BiteBase) {
            # T2647: a bitten frame is counted under the ONE shape it shows.
            switch ($Scorer.Kind[$i]) {
                ([DfScorer]::KindTorn) { [void]$torn.Add("#$ix=$($Scorer.Bite[$i])") }
                ([DfScorer]::KindGhost) { [void]$ghost.Add("#$ix=$($Scorer.Bite[$i])") }
                default { [void]$bit.Add("#$ix=$($Scorer.Bite[$i])") }
            }
        }
        if ($Scorer.BarAt[$i] -ge 0) { [void]$ats.Add($Scorer.BarAt[$i]) }
    }
    $mis = $null; $lost = 0; $misWorst = @()
    if ($Scorer.EdgeRows.Length -ge 2) {
        $mis = 0; $off0 = $null
        for ($i = 0; $i -lt $n; $i++) {
            $e = $Scorer.Edges[$i]
            if ($e[0] -lt 0 -or $e[1] -lt 0) { $lost++; continue }
            if ($null -eq $off0) { $off0 = $e[0] - $e[1] }
            if ([math]::Abs(($e[0] - $e[1]) - $off0) -gt 2) {
                $mis++
                if ($misWorst.Count -lt $Worst) { $misWorst += "#$($Scorer.Index[$i]):nav=$($e[0]),page=$($e[1])" }
            }
        }
    }
    $travel = 0
    if ($ats.Count) { $m = $ats | Measure-Object -Minimum -Maximum; $travel = [int]($m.Maximum - $m.Minimum) }
    [pscustomobject]@{
        Frames        = $n
        DarkFrames    = $dark.Count
        DarkWorst     = @($dark | Select-Object -First $Worst)
        DarkMax       = $(if ($n) { [int](($Scorer.Dark | Measure-Object -Maximum).Maximum) } else { 0 })
        BarGoneFrames = $gone.Count
        BarGoneWorst  = @($gone | Select-Object -First $Worst)
        BittenFrames  = $bit.Count
        BittenWorst   = @($bit | Select-Object -First $Worst)
        TornFrames    = $torn.Count
        TornWorst     = @($torn | Select-Object -First $Worst)
        GhostFrames   = $ghost.Count
        GhostWorst    = @($ghost | Select-Object -First $Worst)
        Travel        = $travel
        EdgeMismatch  = $mis
        EdgeLost      = $lost
        EdgeWorst     = $misWorst
    }
}

# T2645's occluded-display reading moved to lib\OccludedDisplay.ps1 (T2650),
# shared by every harness that photographs the real app.
