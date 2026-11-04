<#
.SYNOPSIS
  T2476 acceptance - a divider drag never flashes: no black strip, no frame
  where the dragged bar is gone, no banner biting a block out of it - with a
  banner set and an HTML viewer in the layout, at 1, 4 and 9 panes, for both
  divider orientations.

.DESCRIPTION
  The regression guard for the P0 user report T2400 ("dragging a divider
  flashes black areas") and its sibling T2414 (the banner ate a block of the
  pink bar on every step). Each of their fixes was proven only by a probe in
  an ignored temp folder; this is those probes made permanent.

  Without -Live it proves the SCORER (lib\DividerFlickerScore.ps1) on frames
  whose truth is known, so a live verdict means what it says:

    A. a clean frame - two panes, a banner, an accent bar running through the
       banner rows - scores nothing;
    B. each planted defect is counted by its own reading and by no other: a
       black strip, a bar flooded with background on the mid row, a banner
       painted over the bar on its rows, and the same bar-gone check on a
       horizontal divider (where the bite reading does not apply);
    C. the address-bar-vs-page edge reading: a page shifted against its nav by
       one drag step is one mismatched frame, a lost edge is counted apart;
    D. the counts: travel is read from where the bar starts, and the worst
       lists name capture indexes;
    E. the occluded-display gate (T2645): an app log carrying FrameClock's
       0xC01E0006 (STATUS_GRAPHICS_PRESENT_OCCLUDED) clock failure is found,
       even while the app holds the log open, and the line it matches is
       still the one FrameClock.zig writes.

  A live cell whose app logged that line ran on a display that was asleep or
  locked: its terminal never presented, so it photographs black with a strip
  wherever it grows. Such a cell is SKIPPED by name, never scored - on
  2026-11-02 that state read as a ~250-dark-frame regression in every cell.

  -Live photographs the REAL app with WGC (lib\FrameCapture.ps1) during a
  POSTED drag - no injected input, the window never activated - for every cell
  of the matrix: panes 1 (a terminal and a viewer), 4 and 9 (a grid whose
  bottom-right pane is the viewer), times a vertical divider (the viewer's
  left edge) and a horizontal one (its top edge). The pane across the divider
  and the first pane carry a banner. Per cell, over every composed frame:

    La no DARK frame (near-black pixels over the pressed frame's count + 300);
    Lb no BAR-GONE frame (the accent bar absent from the mid line);
    Lc no BITTEN frame, vertical cells (a banner row not accent where the
       mid row is, beyond the pressed frame's own count) whose shape is a
       banner over the bar; a TORN bar (banner rows a step behind, T2648)
       and a GHOST of the old bar (T2651) are counted apart and REPORTED
       until those tasks close (T2647; B5-B7 prove the split);
    Ld the drag happened: the bar travelled at least half the planned
       amplitude, and at least 20 frames were scored;
    and the nav-vs-page edge mismatch is REPORTED, not failed, until T2360
    (on the GDI stack the page leads every GDI pixel by 1-2 compositor
    frames per drag tick: T2400's 2026-10-29 log).

  -Control turns the matching assertion around - the defect MUST be seen in
  at least one cell where it can appear - so each scored defect has a
  negative control:

    -Control gutters  GHOZTTY_CLEAR_WHOLE_GUTTERS=1 (pre-T2400 gutter clear)
                      -> BAR-GONE frames
    -Control bite     GHOZTTY_OVERLAYS_AFTER_BANDS=1 (pre-T2414 popup order)
                      -> BITTEN frames
    -Control banner   -Exe of a build with BannerOverlay.T2400_NEUTERED=true
                      (SLWA banner resize) -> DARK frames

  -Live captures the input desktop, so it is an @input-desktop-exception
  script: it runs only when lib\UserPresence.ps1 reads nobody at the box
  (SKIP ALL otherwise) and never in a sweep. A green synthetic run stamps the
  `divider-flicker` guard; a green full-matrix -Live run with no control
  stamps the advisory `divider-flicker-live` one; nothing else stamps.

  ASCII-only by design (PS 5.1 on this box mangles non-ASCII on rewrite).

  powershell -NoProfile -File test\win32\divider-flicker.ps1
  powershell -NoProfile -File test\win32\divider-flicker.ps1 -Live [-Panes 4] [-Orientation vertical]
  powershell -NoProfile -File test\win32\divider-flicker.ps1 -Live -Control gutters
#>
[CmdletBinding()]
param(
    [switch]$Live,
    [ValidateSet('none', 'gutters', 'bite', 'banner')][string]$Control = 'none',
    [string]$Exe = '',
    [int[]]$Panes = @(1, 4, 9),
    [ValidateSet('vertical', 'horizontal')][string[]]$Orientation = @('vertical', 'horizontal'),
    [int]$Ticks = 60,
    [int]$TickMs = 8,
    # T2414's own scene: the far pane is a terminal (with its own banner), not
    # a viewer. Never stamps.
    [switch]$NoViewer
)

# T351: drops an inherited $GHOZTTY_IPC_SOCKET before anything else runs.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

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
. (Join-Path $PSScriptRoot 'lib\FrameLabDriver.ps1')
Import-FrameLabDriver
Import-FrameCapture
. (Join-Path $PSScriptRoot 'lib\DividerFlickerScore.ps1')
Import-DividerFlickerScore

# ---- the synthetic world ----------------------------------------------------
# 200x120. Left pane x0-97, right pane x104-199, the accent bar x98-103 the
# full height. A banner band y8-20 on the left pane; the bar runs through it.
$W = 200; $H = 120
$Bg = 0x2A3A50; $PaneL = 0x283040; $PaneR = 0x303844; $Banner = 0x405868; $Accent = 0xE05090
$Nav = 0xD0D0D8; $Page = 0xE8E0C0
function New-SynthFrame([long]$Index) {
    $f = New-Object GfcFrame
    $f.Index = $Index; $f.W = $W; $f.H = $H; $f.Px = New-Object int[] ($W * $H)
    for ($y = 0; $y -lt $H; $y++) {
        for ($x = 0; $x -lt $W; $x++) {
            $c = $(if ($x -lt 98) { $PaneL } elseif ($x -lt 104) { $Accent } else { $PaneR })
            if ($x -lt 98 -and $y -ge 8 -and $y -lt 20) { $c = $Banner }
            $f.Px[$y * $W + $x] = $c
        }
    }
    return $f
}
function Set-SynthRect($f, [int]$Left, [int]$Top, [int]$RW, [int]$RH, [int]$Color) {
    for ($y = $Top; $y -lt $Top + $RH; $y++) { for ($x = $Left; $x -lt $Left + $RW; $x++) { $f.Px[$y * $f.W + $x] = $Color } }
}
function New-SynthScorer([switch]$Transposed) {
    $s = New-Object DfScorer
    $s.Accent = $Accent; $s.Transposed = [bool]$Transposed
    $s.Line = 60; $s.Lo = 60; $s.Hi = 140
    if (-not $Transposed) { $s.BannerLines = [int[]]@(10, 16) }
    $base = New-SynthFrame 0
    $s.DarkThreshold = [DfScorer]::CountDark($base, $s.Level) + 300
    $s.BiteBase = ($s.Read($base))[3]
    return $s
}

try {
    if (-not $Live) {
        # ---- A. a clean frame scores nothing ----------------------------------
        'A. a clean frame: two panes, a banner, the bar running through it'
        $s = New-SynthScorer
        $r = $s.Read((New-SynthFrame 1))
        Assert 'A1 no dark pixel, a 6 px bar on the mid row starting at x98, no bite' (
            $r[0] -eq 0 -and $r[1] -eq 6 -and $r[2] -eq 98 -and $r[3] -eq 0) "read=$($r -join ',')"
        [void]$s.Score((New-SynthFrame 1))
        $c = Get-DividerFlickerCounts -Scorer $s
        Assert 'A2 its counts are all zero and no edge reading was armed' (
            $c.Frames -eq 1 -and $c.DarkFrames -eq 0 -and $c.BarGoneFrames -eq 0 -and $c.BittenFrames -eq 0 -and $null -eq $c.EdgeMismatch) ($c | ConvertTo-Json -Compress)

        # ---- B. each plant, counted by its own reading only -------------------
        ''
        'B. planted defects: each counted by its own reading and by no other'
        $s = New-SynthScorer
        $f = New-SynthFrame 2; Set-SynthRect $f 110 40 40 20 0x000000; [void]$s.Score($f)
        $f = New-SynthFrame 3; Set-SynthRect $f 110 40 10 10 0x000000; [void]$s.Score($f)
        $c = Get-DividerFlickerCounts -Scorer $s
        Assert 'B1 an 800 px black strip is one DARK frame (#2); a 100 px speck under the slack is not' (
            $c.DarkFrames -eq 1 -and $c.DarkWorst[0] -eq '#2=800' -and $c.BarGoneFrames -eq 0 -and $c.BittenFrames -eq 0) ($c | ConvertTo-Json -Compress)
        $s = New-SynthScorer
        $f = New-SynthFrame 4; Set-SynthRect $f 98 0 6 $H $Bg; [void]$s.Score($f)
        $c = Get-DividerFlickerCounts -Scorer $s
        Assert 'B2 the bar flooded with flat background is one BAR-GONE frame and not a bite or a dark frame' (
            $c.BarGoneFrames -eq 1 -and $c.BarGoneWorst[0] -eq '#4' -and $c.BittenFrames -eq 0 -and $c.DarkFrames -eq 0) ($c | ConvertTo-Json -Compress)
        $s = New-SynthScorer
        $f = New-SynthFrame 5; Set-SynthRect $f 98 8 6 12 $Banner; [void]$s.Score($f)
        $c = Get-DividerFlickerCounts -Scorer $s
        Assert 'B3 a banner painted over the bar on its rows is one BITTEN frame (6 px x 2 rows) with the bar still present, and neither torn nor a ghost' (
            $c.BittenFrames -eq 1 -and $c.BittenWorst[0] -eq '#5=12' -and $c.BarGoneFrames -eq 0 -and $c.TornFrames -eq 0 -and $c.GhostFrames -eq 0) ($c | ConvertTo-Json -Compress)
        # T2647: the two shapes that satisfy the bite reading without a banner
        # over the bar. TORN (T2648): below the banner the bar has stepped to
        # x104, on the banner rows it is still whole at x98.
        $s = New-SynthScorer
        $f = New-SynthFrame 8
        Set-SynthRect $f 98 0 6 8 $PaneL; Set-SynthRect $f 98 20 6 ($H - 20) $PaneL
        Set-SynthRect $f 104 0 6 8 $Accent; Set-SynthRect $f 104 20 6 ($H - 20) $Accent
        [void]$s.Score($f)
        $c = Get-DividerFlickerCounts -Scorer $s
        Assert 'B5 the bar a step behind on the banner rows (whole at x98, x104 below) is one TORN frame and not a bite or a ghost' (
            $c.TornFrames -eq 1 -and $c.TornWorst[0] -eq '#8=12' -and $c.BittenFrames -eq 0 -and $c.GhostFrames -eq 0 -and $c.BarGoneFrames -eq 0) ($c | ConvertTo-Json -Compress)
        # GHOST (T2651): the bar is at x104 everywhere, the left banner has
        # grown over x98-103, and below it the grown terminal still shows a
        # 2 px sliver of the old bar at x98-99.
        $s = New-SynthScorer
        $f = New-SynthFrame 9
        Set-SynthRect $f 100 0 4 $H $PaneL; Set-SynthRect $f 98 8 6 12 $Banner
        Set-SynthRect $f 104 0 6 $H $Accent
        [void]$s.Score($f)
        $c = Get-DividerFlickerCounts -Scorer $s
        Assert 'B6 a 2 px sliver of the old bar beside the moved bar, below a right banner row, is one GHOST frame and not a bite or torn' (
            $c.GhostFrames -eq 1 -and $c.GhostWorst[0] -eq '#9=4' -and $c.BittenFrames -eq 0 -and $c.TornFrames -eq 0) ($c | ConvertTo-Json -Compress)
        # Discrimination edges: a banner row that keeps only a 3 px stub of the
        # bar at the old x is a bite (the strip covers most of it), and a torn
        # shape on ONE banner row of two is a bite too.
        $s = New-SynthScorer
        $f = New-SynthFrame 10; Set-SynthRect $f 98 8 6 12 $Banner; Set-SynthRect $f 98 8 3 12 $Accent; [void]$s.Score($f)
        $f = New-SynthFrame 11
        Set-SynthRect $f 98 0 6 8 $PaneL; Set-SynthRect $f 98 13 6 ($H - 13) $PaneL
        Set-SynthRect $f 104 0 6 8 $Accent; Set-SynthRect $f 104 13 6 ($H - 13) $Accent
        [void]$s.Score($f)
        $c = Get-DividerFlickerCounts -Scorer $s
        Assert 'B7 a 3 px stub of the bar, and a tear on only one banner row, are both BITES' (
            $c.BittenFrames -eq 2 -and $c.TornFrames -eq 0 -and $c.GhostFrames -eq 0) ($c | ConvertTo-Json -Compress)
        # A horizontal divider: transpose the world by reading the mid line as
        # a column. The bar is rows 98-103 across the full width.
        $t = New-SynthScorer -Transposed
        $f = New-Object GfcFrame; $f.Index = 6; $f.W = $H; $f.H = $W; $f.Px = New-Object int[] ($W * $H)
        for ($y = 0; $y -lt $W; $y++) { for ($x = 0; $x -lt $H; $x++) { $f.Px[$y * $H + $x] = $(if ($y -ge 98 -and $y -lt 104) { $Accent } else { $PaneL }) } }
        $r = $t.Read($f)
        $g = New-Object GfcFrame; $g.Index = 7; $g.W = $H; $g.H = $W; $g.Px = [int[]]$f.Px.Clone()
        for ($y = 98; $y -lt 104; $y++) { for ($x = 0; $x -lt $H; $x++) { $g.Px[$y * $H + $x] = $Bg } }
        [void]$t.Score($f); [void]$t.Score($g)
        $c = Get-DividerFlickerCounts -Scorer $t
        Assert 'B4 a horizontal divider: the bar is read down the column (6 px from y98), and flooding it is one BAR-GONE frame (#7)' (
            $r[1] -eq 6 -and $r[2] -eq 98 -and $c.BarGoneFrames -eq 1 -and $c.BarGoneWorst[0] -eq '#7' -and $c.BittenFrames -eq 0) "read=$($r -join ',') $($c | ConvertTo-Json -Compress)"

        # ---- C. the nav-vs-page edge reading ------------------------------------
        ''
        'C. the address bar and the page: their offset is watched, not their position'
        $s = New-SynthScorer
        $s.EdgeRows = [int[]]@(30, 80); $s.EdgeColors = [int[]]@($Nav, $Page); $s.EdgeX0 = 100; $s.EdgeX1 = 200
        $edge = { param([long]$ix, [int]$navX, [int]$pageX)
            $f = New-SynthFrame $ix
            if ($navX -ge 0) { Set-SynthRect $f $navX 26 (200 - $navX) 8 $Nav }
            if ($pageX -ge 0) { Set-SynthRect $f $pageX 40 (200 - $pageX) 60 $Page }
            [void]$s.Score($f) }
        & $edge 10 120 120; & $edge 11 126 126; & $edge 12 132 126; & $edge 13 138 138; & $edge 14 -1 144
        $c = Get-DividerFlickerCounts -Scorer $s
        Assert 'C1 moving together is no mismatch; the page one 6 px step behind its nav is one (#12); a lost nav is counted apart' (
            $c.EdgeMismatch -eq 1 -and $c.EdgeWorst[0] -eq '#12:nav=132,page=126' -and $c.EdgeLost -eq 1) ($c | ConvertTo-Json -Compress)

        # ---- D. travel and the worst lists ------------------------------------
        ''
        'D. the counts: the drag is proven by how far the bar travelled'
        $s = New-SynthScorer
        foreach ($k in 0..4) {
            $f = New-SynthFrame (20 + $k)
            Set-SynthRect $f 98 0 6 $H $PaneL
            Set-SynthRect $f (98 + 6 * $k) 0 6 $H $Accent
            [void]$s.Score($f)
        }
        $c = Get-DividerFlickerCounts -Scorer $s
        Assert 'D1 a bar stepping 6 px on each of five frames travelled 24 px, and nothing else was counted' (
            $c.Travel -eq 24 -and $c.Frames -eq 5 -and $c.DarkFrames + $c.BarGoneFrames + $c.BittenFrames + $c.TornFrames + $c.GhostFrames -eq 0) ($c | ConvertTo-Json -Compress)
        $s.Clear()
        Assert 'D2 Clear empties every reading, so one scorer can arm a second drag' ($s.Index.Count -eq 0 -and $s.Edges.Count -eq 0)

        # ---- E. the occluded-display gate (T2645) -------------------------------
        ''
        'E. a run the compositor called occluded is named, never scored'
        $tmp = Join-Path ([IO.Path]::GetTempPath()) "dvflick-occl-$PID"
        $null = New-Item -ItemType Directory -Force -Path $tmp
        try {
            $lit = Join-Path $tmp 'lit.log'; $dim = Join-Path $tmp 'dim.log'
            [IO.File]::WriteAllText($lit, "info: ghoztty build optimize=Debug`nwarning(config): no default shell found, will default to using cmd`n")
            [IO.File]::WriteAllText($dim, "info: ghoztty build optimize=Debug`nwarning(frame_clock): compositor clock wait failed (c01e0006); falling back to a timer`n")
            Assert 'E1 a lit run reads not-occluded; a missing log reads not-occluded' (
                $null -eq (Get-DividerFlickerOccluded -LogPath $lit) -and $null -eq (Get-DividerFlickerOccluded -LogPath (Join-Path $tmp 'none.log')))
            # The app holds its stderr open while the harness reads it.
            $hold = [IO.File]::Open($dim, 'Open', 'ReadWrite', 'ReadWrite')
            try { $got = Get-DividerFlickerOccluded -LogPath $dim } finally { $hold.Dispose() }
            Assert 'E2 the 0xC01E0006 clock failure is found, in a log the app still holds open' ($got -match 'c01e0006') "got=$got"
            # The gate matches the app's own words: a reworded log line would
            # silently score occluded runs again.
            $fc = [IO.File]::ReadAllText((Join-Path $repo 'src\apprt\win32\FrameClock.zig'))
            Assert 'E3 FrameClock.zig still logs the line the gate matches' ($fc.Contains('"compositor clock wait failed ({x}); falling back to a timer"'))
        } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    } else {
        # ---- L. the real app, photographed --------------------------------------
        # Captures the input desktop: nobody may be at the box.
        . (Join-Path $PSScriptRoot 'lib\UserPresence.ps1')
        Assert-UserAbsent
        . (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
        . (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
        . (Join-Path $PSScriptRoot 'lib\ChromeGeometry.ps1')
        [void](Set-GhozttyTestIsolation -Tag 'dvflick' -Quiet)
        if (-not $Exe) { $Exe = Join-Path $repo 'zig-out\bin\ghoztty.exe' }
        if (-not (Test-Path $Exe)) { throw "no app at $Exe" }
        # T350: a release-lineage exe would drive the user's own endpoints.
        . (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
        Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null
        if ($Control -eq 'banner' -and -not $PSBoundParameters.ContainsKey('Exe')) {
            throw '-Control banner needs -Exe <a build with BannerOverlay.T2400_NEUTERED = true>; the default zig-out build ships it false'
        }
        $knob = @{ none = $null; gutters = 'GHOZTTY_CLEAR_WHOLE_GUTTERS'; bite = 'GHOZTTY_OVERLAYS_AFTER_BANDS'; banner = $null }[$Control]
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $outRoot = Join-Path $repo "temp\divider-flicker\$stamp-$Control"
        $null = New-Item -ItemType Directory -Force -Path $outRoot
        $html = Join-Path $outRoot 'page.html'
        [IO.File]::WriteAllText($html, '<!doctype html><html><body style="background:#e8e0c0;color:#806020;font:20px sans-serif"><h1>viewer</h1><p>T2476 divider-flicker page</p></body></html>')
        "L. live: control=$Control exe=$Exe out=$outRoot"
        $seen = @{ dark = 0; gone = 0; bite = 0; biteCells = 0; occluded = 0; lit = 0 }
        # The input desktop's handle, for the POSTED mouse messages only.
        [void](New-TestDesktop -Interactive)

        foreach ($n in $Panes) {
            foreach ($o in $Orientation) {
                $cell = "$n-pane $o"
                ''
                "  -- $cell"
                $out = Join-Path $outRoot "$n-$o"
                $null = New-Item -ItemType Directory -Force -Path $out
                $conf = Join-Path $out 'config'
                [IO.File]::WriteAllText($conf, "background = #2a3a50`nconfirm-close-surface = false`n")
                $prof = Join-Path $out 'profile'; $null = New-Item -ItemType Directory -Force (Join-Path $prof 'ghoztty')
                $errlog = Join-Path $out 'app-stderr.log'
                $savedLad = $env:LOCALAPPDATA; $savedKnob = $(if ($knob) { [Environment]::GetEnvironmentVariable($knob) } else { $null })
                $env:LOCALAPPDATA = $prof; $env:GHOZTTY_NO_STARTUP_ESCAPE = '1'
                if ($knob) { [Environment]::SetEnvironmentVariable($knob, '1') }
                try { $proc = Start-Process -FilePath $Exe -ArgumentList @('--config-default-files=false', '--session-persistence=false', "--config-file=$conf") -PassThru -RedirectStandardError $errlog }
                finally {
                    $env:LOCALAPPDATA = $savedLad
                    if ($knob) { [Environment]::SetEnvironmentVariable($knob, $savedKnob) }
                }
                try {
                    $top = [IntPtr]::Zero
                    for ($i = 0; $i -lt 100 -and $top -eq [IntPtr]::Zero; $i++) { Start-Sleep -Milliseconds 200; $top = [GflWin]::FindTop($proc.Id, 'GhozttyWindow') }
                    if ($top -eq [IntPtr]::Zero) { Assert "L0 $cell the window appeared" $false; continue }
                    $scale = [GflWin]::WindowDpi($top) / 96.0
                    $wa = [GflWin]::WorkArea($top)
                    $ww = [math]::Min((Get-TestChromeDip 1500 $scale), $wa[2] - (Get-TestChromeDip 160 $scale))
                    $wh = [math]::Min((Get-TestChromeDip 900 $scale), $wa[3] - (Get-TestChromeDip 120 $scale))
                    [void][GflWin]::Place($top, $wa[0] + (Get-TestChromeDip 80 $scale), $wa[1] + (Get-TestChromeDip 60 $scale), $ww, $wh)
                    Start-Sleep -Seconds 2
                    $first = Get-FrameLabFirstPaneId $Exe $top
                    if (-not $first) { Assert "L0 $cell +list named the first pane" $false; continue }
                    $problems = @()
                    $across = $first.PaneId
                    if ($n -eq 1) {
                        $dir = $(if ($o -eq 'vertical') { 'right' } else { 'down' })
                        $argv = @('+split', "--target=$($first.PaneId)", "--direction=$dir", '--name=view')
                        if (-not $NoViewer) { $argv += "--view=$html" }
                        $r = Invoke-FrameLabCli $Exe $argv
                        if ($r -match '(?i)error|unknown|not found') { $problems += "+split view: $r" }
                        $far = 'view'
                    } else {
                        $plan = Get-FrameLabGridPlan $n
                        foreach ($sp in $plan.Splits) {
                            $from = $(if ($sp.From -eq 'p1') { $first.PaneId } else { $sp.From })
                            $argv = @('+split', "--target=$from", "--direction=$($sp.Direction)", "--name=$($sp.Name)")
                            if ($sp.Index -eq $n -and -not $NoViewer) { $argv += "--view=$html" }
                            $r = Invoke-FrameLabCli $Exe $argv
                            if ($r -match '(?i)error|unknown|not found') { $problems += "+split $($sp.Name): $r" }
                            Start-Sleep -Milliseconds 250
                        }
                        $json = $plan.Layout.Replace('"p1"', '"' + $first.PaneId + '"')
                        $r = Invoke-FrameLabCli $Exe @('+rearrange', "--target=$($first.PaneId)", ('--layout=' + $json.Replace('"', '\"')))
                        if ($r -match '(?i)error|unknown|not found|invalid') { $problems += "+rearrange: $r" }
                        # The pane across the dragged divider from the viewer (pN):
                        # left of it for a vertical divider, above it for a horizontal.
                        $k = $plan.K
                        $across = $(if ($o -eq 'vertical') { "p$($n - 1)" } else { "p$($n - $k)" })
                        $far = "p$n"
                    }
                    if ($NoViewer) {
                        $r = Invoke-FrameLabCli $Exe @('+set-banner', "--target=$far", '**Far pane** a banner on the other side of the bar')
                        if ($r -match '(?i)error|unknown|not found') { $problems += "+set-banner ${far}: $r" }
                    }
                    $r = Invoke-FrameLabCli $Exe @('+set-banner', "--target=$($first.PaneId)", '**Build status** all green - a banner to watch during the drag')
                    if ($r -match '(?i)error|unknown|not found') { $problems += "+set-banner p1: $r" }
                    if ($across -ne $first.PaneId) {
                        $r = Invoke-FrameLabCli $Exe @('+set-banner', "--target=$across", '**Across the divider** a second banner beside the bar')
                        if ($r -match '(?i)error|unknown|not found') { $problems += "+set-banner ${across}: $r" }
                    }
                    Assert "L0 $cell the layout was built (splits, viewer, banners)" ($problems.Count -eq 0) ($problems -join ' | ')
                    if ($problems.Count) { continue }
                    Start-Sleep -Seconds 3

                    $fr = [GflWin]::Frame($top)
                    $terms = @([GflWin]::Children($top, 'GhozttyTerminal') | ForEach-Object { ConvertFrom-FrameLabChildRect $_ })
                    $view = @([GflWin]::Children($top, 'GhozttyViewer') | ForEach-Object { ConvertFrom-FrameLabChildRect $_ })[0]
                    $nav = @([GflWin]::Children($top, 'GhozttyViewerNav') | ForEach-Object { ConvertFrom-FrameLabChildRect $_ })[0]
                    if ($NoViewer) {
                        # The far pane stands where the viewer would: bottom-right.
                        $sorted = @($terms | Sort-Object { $_.X + $_.W + $_.Y + $_.H } -Descending)
                        $view = $sorted[0]; $terms = @($sorted | Select-Object -Skip 1); $nav = $null
                    }
                    # A grid's bottom-right pane IS the viewer; one pane gets a viewer beside it.
                    $wantTerms = $(if ($n -eq 1) { 1 } else { $n - 1 })
                    if (-not $view -or $terms.Count -ne $wantTerms) { Assert "L0 $cell found $wantTerms terminal(s) and the viewer" $false "terms=$($terms.Count) viewer=$([bool]$view)"; continue }
                    $vTop = $(if ($nav) { [math]::Min($view.Y, $nav.Y) } else { $view.Y })
                    # The neighbour across the divider: the nearest terminal on the
                    # far side that overlaps the viewer's middle.
                    if ($o -eq 'vertical') {
                        $my = [int]($vTop + ($view.Y + $view.H - $vTop) / 2)
                        $nb = @($terms | Where-Object { $_.X + $_.W -le $view.X + 2 -and $_.Y -le $my -and $_.Y + $_.H -ge $my } | Sort-Object { $_.X + $_.W } -Descending)[0]
                        if (-not $nb) { Assert "L0 $cell a terminal sits left of the viewer" $false; continue }
                        $px = [int](($nb.X + $nb.W + $view.X) / 2); $py = [int]($nb.Y + $nb.H / 2)
                        $room = [math]::Min($nb.W, $view.W)
                    } else {
                        $mx = [int]($view.X + $view.W / 2)
                        $nb = @($terms | Where-Object { $_.Y + $_.H -le $vTop + 2 -and $_.X -le $mx -and $_.X + $_.W -ge $mx } | Sort-Object { $_.Y + $_.H } -Descending)[0]
                        if (-not $nb) { Assert "L0 $cell a terminal sits above the viewer" $false; continue }
                        $px = $mx; $py = [int](($nb.Y + $nb.H + $vTop) / 2)
                        $room = [math]::Min($nb.H, $view.Y + $view.H - $vTop)
                    }
                    # Into the viewer by at most 35% of the smaller neighbour, so no
                    # pane reaches its minimum and folds (that is chainfold.ps1's).
                    $amp = [int][math]::Min(180 * $scale, 0.35 * $room)
                    $step = [math]::Max(1, [int]($amp / ($Ticks / 2)))
                    $amp = $step * [int]($Ticks / 2)

                    # click-coord: $px/$py are midpoints of GflWin child rects (GetWindowRect, screen space) via ConvertFrom-FrameLabChildRect
                    [void](Send-TestMouse -Window $top -Target $top -X $px -Y $py -Action down -HoldMs 0)
                    Start-Sleep -Milliseconds 300
                    $s0 = Start-FrameCapture -X $fr[0] -Y $fr[1] -W $fr[2] -H $fr[3] -SampleEvery 0 -KeepFrames 1
                    Start-Sleep -Milliseconds 300
                    $r0 = Stop-FrameCapture -Session $s0; $s0.Dispose()
                    $k0 = $r0.Kept[0]
                    [void][GfcSession]::WritePng($k0, (Join-Path $out 'pressed.png'))
                    $sc = New-Object DfScorer
                    $lx = $px - $fr[0]; $ly = $py - $fr[1]
                    $sc.Transposed = ($o -eq 'horizontal')
                    $sc.Line = $(if ($sc.Transposed) { $lx } else { $ly })
                    $c0 = $(if ($sc.Transposed) { $ly } else { $lx })
                    $sc.Lo = $c0 - (Get-TestChromeDip 12 $scale); $sc.Hi = $c0 + $amp + (Get-TestChromeDip 12 $scale)
                    $sc.Accent = $k0.Px[$ly * $k0.W + $lx] -band 0xFFFFFF
                    $sc.DarkThreshold = [DfScorer]::CountDark($k0, $sc.Level) + 300
                    if (-not $sc.Transposed) {
                        # The banner rows of the pane across the divider: just above its terminal.
                        $t0 = $nb.Y - $fr[1]
                        $sc.BannerLines = [int[]]@(($t0 - (Get-TestChromeDip 6 $scale)), ($t0 - (Get-TestChromeDip 16 $scale)))
                        if ($nav) {
                            $ny = $nav.Y + (Get-TestChromeDip 4 $scale) - $fr[1]
                            $pyy = [int](($nav.Y + $nav.H + $view.Y + $view.H) / 2) - $fr[1]
                            $vx = $view.X - $fr[0]
                            $sc.EdgeRows = [int[]]@($ny, $pyy)
                            $sc.EdgeColors = [int[]]@(($k0.Px[$ny * $k0.W + $vx + 30] -band 0xFFFFFF), ($k0.Px[$pyy * $k0.W + $vx + 30] -band 0xFFFFFF))
                            $sc.EdgeX0 = [math]::Max(0, $vx - 80); $sc.EdgeX1 = $vx + $amp + 80
                        }
                    }
                    $pr = $sc.Read($k0)
                    $sc.BiteBase = $pr[3]
                    $bg = 0x2A3A50
                    "  pressed: accent {0:X6} at ({1},{2}), bar run {3} from {4}, dark {5}, bite base {6}, amp {7} px in {8} px steps" -f $sc.Accent, $lx, $ly, $pr[1], $pr[2], $pr[0], $pr[3], $amp, $step
                    Assert "L0 $cell the pressed bar is seen on the mid line in a colour that is not the background" (
                        $pr[1] -gt 0 -and -not [DfScorer]::Near($sc.Accent, $bg, 12)) ("run=$($pr[1]) accent={0:X6}" -f $sc.Accent)

                    $png = Join-Path $out 'frames'; $null = New-Item -ItemType Directory -Force $png
                    $s = Start-FrameCapture -X $fr[0] -Y $fr[1] -W $fr[2] -H $fr[3] -SampleEvery 0 -PngDir $png -Scorer $sc.AsScorer()
                    Start-Sleep -Milliseconds 300
                    for ($t = 1; $t -le $Ticks; $t++) {
                        $off = $(if ($t -le $Ticks / 2) { $t } else { $Ticks - $t }) * $step
                        $mvx = $px; $mvy = $py
                        if ($o -eq 'vertical') { $mvx += $off } else { $mvy += $off }
                        # click-coord: the pressed screen point ($px/$py, child-rect midpoints) plus a pixel offset
                        [void](Send-TestMouse -Window $top -Target $top -X $mvx -Y $mvy -Action move -HoldMs 0)
                        Start-Sleep -Milliseconds $TickMs
                    }
                    Start-Sleep -Milliseconds 200
                    $res = Stop-FrameCapture -Session $s; $s.Dispose()
                    # click-coord: the pressed screen point again, released
                    [void](Send-TestMouse -Window $top -Target $top -X $px -Y $py -Action up -HoldMs 0)
                    $c = Get-DividerFlickerCounts -Scorer $sc
                    $edge = $(if ($null -eq $c.EdgeMismatch) { 'n/a' } else { "$($c.EdgeMismatch) mismatched >2px, $($c.EdgeLost) lost; first: $($c.EdgeWorst -join ' ')" })
                    "  captured=$($res.Stats.Captured) scored=$($c.Frames) travel=$($c.Travel)px dark=$($c.DarkFrames) (max $($c.DarkMax), threshold $($sc.DarkThreshold)) bar-gone=$($c.BarGoneFrames) bitten=$($c.BittenFrames) torn=$($c.TornFrames) ghost=$($c.GhostFrames) png=$($res.Stats.PngWritten)"
                    "  nav vs page (reported until T2360): $edge"
                    if (-not $sc.Transposed) {
                        # T2647: shapes the bite reading also sees, reported apart
                        # (not failed) while T2648 / T2651 own them.
                        "  torn bar (reported until T2648): $($c.TornFrames); first: $($c.TornWorst -join ' ')"
                        "  ghost bar (reported until T2651): $($c.GhostFrames); first: $($c.GhostWorst -join ' ')"
                    }
                    $seen.dark += $c.DarkFrames; $seen.gone += $c.BarGoneFrames
                    if (-not $sc.Transposed -and $sc.BannerLines.Length) { $seen.bite += $c.BittenFrames; $seen.biteCells++ }

                    # T2645: a display the compositor called occluded (asleep,
                    # locked) shows a terminal that never presented - every pixel
                    # verdict of this cell would be about the box, not the app.
                    $occl = Get-DividerFlickerOccluded -LogPath $errlog
                    if ($occl) {
                        "  SKIP La/Lb/Lc/Ld ${cell}: the display was occluded while the app ran (asleep or locked), so these frames say nothing about a drag -- $occl"
                        $script:skipped++; $seen.occluded++
                        continue
                    }
                    $seen.lit++
                    Assert "Ld $cell the drag happened: $($c.Frames) frames scored, the bar travelled $($c.Travel) of $amp px" (
                        $c.Frames -ge 20 -and $c.Travel -ge [int]($amp / 2)) ''
                    if ($Control -ne 'banner') {
                        Assert "La $cell no DARK frame" ($c.DarkFrames -eq 0) ($c.DarkWorst -join ' ')
                    }
                    if ($Control -ne 'gutters') {
                        Assert "Lb $cell no BAR-GONE frame" ($c.BarGoneFrames -eq 0) ($c.BarGoneWorst -join ' ')
                    }
                    if ($Control -ne 'bite' -and -not $sc.Transposed) {
                        Assert "Lc $cell no BITTEN frame" ($c.BittenFrames -eq 0) ($c.BittenWorst -join ' ')
                    }
                } finally {
                    try { Stop-Process -Id $proc.Id -Force } catch { }
                }
            }
        }

        # The negative control: its defect must be seen somewhere it can appear.
        ''
        if ($Control -ne 'none' -and $seen.lit -eq 0) {
            "  SKIP Lx: every cell ran on an occluded display, so the control's defect could not be photographed"
            $script:skipped++
        } else { switch ($Control) {
            'gutters' { Assert 'Lx the whole-gutter clear (GHOZTTY_CLEAR_WHOLE_GUTTERS) is seen: BAR-GONE frames' ($seen.gone -gt 0) "bar-gone=$($seen.gone)" }
            'bite' {
                if ($seen.biteCells -eq 0) { "  SKIP Lx: no vertical cell with a banner ran, so the bite cannot appear"; $script:skipped++ }
                else { Assert 'Lx the popups placed after the bands (GHOZTTY_OVERLAYS_AFTER_BANDS) are seen: BITTEN frames' ($seen.bite -gt 0) "bitten=$($seen.bite) over $($seen.biteCells) cell(s)" }
            }
            'banner' { Assert 'Lx the SLWA banner resize (T2400_NEUTERED build) is seen: DARK frames' ($seen.dark -gt 0) "dark=$($seen.dark)" }
        } }
    }

    Complete-TestBody
}
finally { }

# T783: a green synthetic run stamps the scorer's guard; a green FULL-matrix
# live run with no control stamps the advisory live guard. Red, skipped, a
# control or a partial matrix stays due.
if ($script:failures -eq 0 -and $script:skipped -eq 0) {
    if (-not $Live) {
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
            update -Guard divider-flicker -Repo $repo 2>&1 | ForEach-Object { "  $_" }
    } elseif ($Control -eq 'none' -and -not $NoViewer -and @($Panes).Count -eq 3 -and @($Orientation).Count -eq 2 -and -not $PSBoundParameters.ContainsKey('Exe')) {
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
            update -Guard divider-flicker-live -Repo $repo 2>&1 | ForEach-Object { "  $_" }
    }
}

''
Write-TestVerdict -Label 'T2476 DIVIDER FLICKER' -Pass $script:passes -Fail $script:failures -Skipped $script:skipped
