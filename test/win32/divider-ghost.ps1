<#
.SYNOPSIS
  T2441 acceptance - a REAL-POINTER divider drag shows the bar once per frame
  and the widening pane painted out to it: no ghost bar left behind, no stale
  strip where the old right pane's first column reads doubled (T2418).

.DESCRIPTION
  The committed form of the T2418 probe, which lived only in lane B's ignored
  temp\t2418 (ghost-probe.ps1 / ghost-probe-all.ps1). Its two lessons are
  built in: the scorer knows the HOVER colour, so the frames before the press
  and after the release are not read as a vanished bar; and the doubled
  column (class 2) has an automatic oracle, the STRIP reading, instead of a
  montage someone has to look at.

  Without -Live it proves the SCORER (lib\DividerGhostScore.ps1) on frames
  whose truth is known, so a live verdict means what it says:

    A. a clean rightward drag - the bar one run per frame, the grown zone
       repainted - scores nothing, and the bar's travel is measured;
    B. each planted defect is counted by its own reading and by no other: a
       ghost sliver of the old bar (GHOST), two adjacent positions fused into
       one wide run (SMEAR), the old right pane's first column left in the
       grown zone (STRIP), and a frame with no bar at all (GONE);
    C. the hover frames: a frame whose mid row carries the HOVER colour and
       no drag colour (button up) is never scored, so a pre-press or
       post-release frame is not a GONE frame;
    D. strip-row selection from the pressed frame: rows where the left pane is
       not blank, rows where the zone already equals the blank colour (where a
       stale zone could not be told apart), and the band around the mid row
       are all left out;
    E. the summary: counts per class, drag vs hover frames, and a worst list
       naming capture indexes.

  -Live drives the REAL pointer (SendInput at 1 kHz through
  lib\FrameLabInput.ps1) over the debug build's divider between two terminal
  panes and photographs every frame DWM composes (lib\FrameCapture.ps1, WGC,
  cursor capture off). The right pane is filled with text so its first column
  is visible; the dim wash is off (unfocused-split-opacity = 1) so the grown
  zone has one right colour. The drag is played in three parts: hover (learn
  the hover colour), press (learn the drag colour, the bar and the strip
  rows), then the rightward line, a hold and the release, scored. Asserts:

    L0 the window, the split and the right pane's text are up;
    L1 the pressed frame shows the bar and at least 2 strip rows were found;
    L2 every input sample was sent, nothing aborted (a person moving the
       mouse aborts the play - that is a SKIP, never a pass);
    La no GHOST frame;   Lb no SMEAR frame;
    Lc no STRIP frame;   Ld no GONE frame;
    Le the drag happened: the bar travelled at least half the planned
       distance and at least 20 drag frames were scored.

  -Control stale arms the frame lab's planted defect
  (GHOZTTY_LAB_PLANT=stale@8: each pane presents its 8th resize frame at its
  OLD size, src\apprt\win32\lab_plant.zig) and turns La-Lc around: the app
  must log `lab plant fired kind=stale`, and at least one frame must score
  GHOST, SMEAR or STRIP. A scorer that misses a planted stale present cannot
  be trusted to have seen no real one.

  -Live photographs and injects on the input desktop, so it is an
  @input-desktop-exception script and is opt-in only (idle-is-not-absent):
  it runs only when lib\UserPresence.ps1 reads nobody at the box (SKIP ALL
  otherwise), and never in a sweep. A green synthetic run stamps the
  `divider-ghost` guard; a green -Live run with no control stamps the
  advisory `divider-ghost-live` one; nothing else stamps.

  ASCII-only by design (PS 5.1 on this box mangles non-ASCII on rewrite).

  powershell -NoProfile -File test\win32\divider-ghost.ps1
  powershell -NoProfile -File test\win32\divider-ghost.ps1 -Live
  powershell -NoProfile -File test\win32\divider-ghost.ps1 -Live -Control stale
#>
[CmdletBinding()]
param(
    [switch]$Live,
    [ValidateSet('none', 'stale')][string]$Control = 'none',
    [string]$Exe = '',
    [int]$TravelDip = 240,
    [int]$DragMs = 480,
    # Keep the unfocused pane's dim wash (the user's scene). Never stamps:
    # a lagging wash is its own defect class (the lab's B5), not this one.
    [switch]$Dim
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
. (Join-Path $PSScriptRoot 'lib\DividerGhostScore.ps1')
Import-DividerGhostScore
# T2645's occluded-display reading (FrameClock's own log line), shared by every
# harness that photographs the app (T2650): a run on an asleep or locked
# display is SKIPPED, never scored.
. (Join-Path $PSScriptRoot 'lib\OccludedDisplay.ps1')

# ---- the synthetic world ----------------------------------------------------
# 200x120. Left pane x0-79 (blank, colour LeftBg), the bar x80-83, right pane
# x84-199 whose first column is a glyph column at x86-88 on the text rows
# (y >= 40, every other 4-row band). Mid row y60. A rightward drag moves the
# bar by Step px a frame; a clean frame repaints the left pane out to it.
$W = 200; $H = 120
$LeftBg = 0x2A3A50; $RightBg = 0x2A3A50; $Glyph = 0xC8C8C8; $DragC = 0xB95BD0; $HoverC = 0x684482
$Bar0 = 80; $BarW = 4; $Mid = 60
function Test-GlyphRow([int]$y) { return ($y -ge 40 -and (($y - 40) % 8) -lt 4) }
function New-DragFrame([long]$Index, [int]$BarX, [int]$BarColor = $DragC) {
    $f = New-Object GfcFrame
    $f.Index = $Index; $f.W = $W; $f.H = $H; $f.Px = New-Object int[] ($W * $H)
    $rx = $BarX + $BarW
    for ($y = 0; $y -lt $H; $y++) {
        $g = Test-GlyphRow $y
        for ($x = 0; $x -lt $W; $x++) {
            $c = $(if ($x -lt $BarX) { $LeftBg } elseif ($x -lt $rx) { $BarColor } else { $RightBg })
            if ($g -and $x -ge $rx + 2 -and $x -lt $rx + 5) { $c = $Glyph }
            $f.Px[$y * $W + $x] = $c
        }
    }
    return $f
}
function Set-SynthRect($f, [int]$Left, [int]$Top, [int]$RW, [int]$RH, [int]$Color) {
    for ($y = $Top; $y -lt $Top + $RH; $y++) { for ($x = $Left; $x -lt $Left + $RW; $x++) { $f.Px[$y * $f.W + $x] = $Color } }
}
# A scorer armed exactly the way the live path arms one, from synthetic
# hover and pressed frames.
function New-SynthScorer([int]$Travel = 60) {
    $s = New-Object DgScorer
    $s.Line = $Mid; $s.Lo = $Bar0 - 20; $s.Hi = $Bar0 + $BarW + $Travel + 20
    $s.Drag = $DragC; $s.Hover = $HoverC; $s.MaxW = $BarW + 2
    $s.BarLeft = $Bar0; $s.BarRight = $Bar0 + $BarW - 1
    $pressed = New-DragFrame 0 $Bar0
    [void]$s.PickStripRows($pressed, 10, $H - 4, $Travel, 40, $Mid, 4, 8)
    return $s
}

try {
if (-not $Live) {
    # ---- A. a clean drag --------------------------------------------------
    ''
    'A. a clean rightward drag scores nothing'
    $s = New-SynthScorer
    Assert 'A1 the pressed frame yields strip rows (blank left, glyphs in the zone)' ($s.StripRows.Length -ge 2) "rows=$($s.StripRows -join ',')"
    for ($k = 0; $k -le 15; $k++) { [void]$s.Score((New-DragFrame (100 + $k) ($Bar0 + 4 * $k))) }
    $sum = Get-DividerGhostSummary $s
    Assert 'A2 fifteen moved frames, no bad frame' ($sum.Bad -eq 0 -and $sum.DragFrames -eq 16) "bad=$($sum.Bad) drag=$($sum.DragFrames) worst=$($sum.Worst -join ' ; ')"
    Assert 'A3 the travel is read from where the bar started' ($sum.Travel -eq 60) "travel=$($sum.Travel)"
    Assert 'A4 a clean frame has strip 0 and one run' ($s.Strip[5] -eq 0 -and $s.Runs[5] -eq 1) "strip=$($s.Strip[5]) runs=$($s.Runs[5])"

    # ---- B. each planted defect, by its own reading -----------------------
    ''
    'B. each planted defect is counted by its own reading and by no other'
    # B1 GHOST: bar at +40, a 2 px sliver of the old bar at +20 on the mid row only.
    $s = New-SynthScorer
    $f = New-DragFrame 201 ($Bar0 + 40)
    Set-SynthRect $f ($Bar0 + 20) ($Mid - 1) 2 3 $DragC
    [void]$s.Score($f)
    Assert 'B1 a ghost sliver of the old bar is GHOST' ($s.Verdict(0) -eq 'GHOST') "verdict=$($s.Verdict(0)) runs=[$($s.RunText[0])] strip=$($s.Strip[0])"
    # B2 SMEAR: two adjacent positions fused, one run 2x wide.
    $s = New-SynthScorer
    $f = New-DragFrame 202 ($Bar0 + 40)
    Set-SynthRect $f ($Bar0 + 36) 0 4 $H $DragC
    [void]$s.Score($f)
    Assert 'B2 two fused positions are SMEAR (one run, too wide)' ($s.Verdict(0) -eq 'SMEAR') "verdict=$($s.Verdict(0)) runs=[$($s.RunText[0])] widest=$($s.Widest[0])"
    # B3 STRIP: the widening pane did not repaint - the old right pane (its
    # bg and first glyph column) still stands in the grown zone. The bar at
    # +40 alone; x84..118 still holds the pressed frame's right side.
    $s = New-SynthScorer
    $old = New-DragFrame 0 $Bar0
    $f = New-DragFrame 203 ($Bar0 + 40)
    for ($y = 0; $y -lt $H; $y++) { for ($x = $Bar0 + $BarW; $x -lt $Bar0 + 40; $x++) { $f.Px[$y * $W + $x] = $old.Px[$y * $W + $x] } }
    [void]$s.Score($f)
    Assert 'B3 the old first column left in the grown zone is STRIP' ($s.Verdict(0) -eq 'STRIP') "verdict=$($s.Verdict(0)) strip=$($s.Strip[0]) runs=[$($s.RunText[0])]"
    # B3b the same doubled column against a grown zone that WAS repainted
    # except for one stale glyph column: still STRIP (one glyph is enough).
    $s = New-SynthScorer
    $f = New-DragFrame 204 ($Bar0 + 40)
    foreach ($y in 0..($H - 1)) { if (Test-GlyphRow $y) { Set-SynthRect $f ($Bar0 + $BarW + 2) $y 3 1 $Glyph } }
    [void]$s.Score($f)
    Assert 'B3b one stale glyph column in a repainted zone is STRIP' ($s.Verdict(0) -eq 'STRIP') "verdict=$($s.Verdict(0)) strip=$($s.Strip[0])"
    # B4 GONE: no bar of either colour on the mid row.
    $s = New-SynthScorer
    $f = New-DragFrame 205 ($Bar0 + 40) $LeftBg
    [void]$s.Score($f)
    Assert 'B4 a frame with no bar is GONE (and nothing else)' ($s.Verdict(0) -eq 'GONE' -and $s.Strip[0] -eq -1) "verdict=$($s.Verdict(0)) strip=$($s.Strip[0])"
    # B5 a ghost bar standing in the zone on EVERY row is GHOST and STRIP at once:
    # the strip rows see it too - one defect, two honest readings.
    $s = New-SynthScorer
    $f = New-DragFrame 206 ($Bar0 + 40)
    Set-SynthRect $f ($Bar0 + 20) 0 2 $H $DragC
    [void]$s.Score($f)
    Assert 'B5 a full-height ghost bar is GHOST+STRIP' ($s.Verdict(0) -eq 'GHOST+STRIP') "verdict=$($s.Verdict(0))"
    # B6 slack: a 1 px antialias seam beside the bar is not a STRIP.
    $s = New-SynthScorer
    $f = New-DragFrame 207 ($Bar0 + 40)
    $f.Px[$s.StripRows[0] * $W + ($Bar0 + 40 - 3)] = 0x3A4A60
    [void]$s.Score($f)
    Assert 'B6 a single off pixel stays under StripSlack' ($s.Verdict(0) -eq '' -and $s.Strip[0] -eq 1) "verdict=$($s.Verdict(0)) strip=$($s.Strip[0])"

    # ---- C. hover frames ---------------------------------------------------
    ''
    'C. a button-up frame (hover colour) is never scored'
    $s = New-SynthScorer
    [void]$s.Score((New-DragFrame 300 $Bar0 $HoverC))
    [void]$s.Score((New-DragFrame 301 ($Bar0 + 8)))
    [void]$s.Score((New-DragFrame 302 ($Bar0 + 60) $HoverC))
    $sum = Get-DividerGhostSummary $s
    Assert 'C1 the pre-press and post-release hover frames are hover, not GONE' ($s.HoverFrame[0] -eq 1 -and $s.HoverFrame[2] -eq 1 -and $sum.Gone -eq 0) "hover=$($s.HoverFrame -join ',') gone=$($sum.Gone)"
    Assert 'C2 only the drag frame is scored' ($sum.DragFrames -eq 1 -and $sum.HoverFrames -eq 2 -and $sum.Bad -eq 0) "drag=$($sum.DragFrames) hover=$($sum.HoverFrames) bad=$($sum.Bad)"
    $s.Hover = -1; $s.Clear()
    [void]$s.Score((New-DragFrame 303 $Bar0 $HoverC))
    Assert 'C3 with no hover colour learnt, the same frame IS GONE (the probe''s no-bar=BAD)' ($s.Verdict(0) -eq 'GONE') "verdict=$($s.Verdict(0))"

    # ---- D. strip-row selection -------------------------------------------
    ''
    'D. strip rows: blank left, distinguishable zone, clear of the mid row'
    $s = New-SynthScorer
    $rows = @($s.StripRows)
    Assert 'D1 every strip row is a glyph row (the zone differs there)' (@($rows | Where-Object { -not (Test-GlyphRow $_) }).Count -eq 0) "rows=$($rows -join ',')"
    Assert 'D2 no strip row within 4 px of the mid row' (@($rows | Where-Object { [math]::Abs($_ - $Mid) -le 4 }).Count -eq 0) "rows=$($rows -join ',')"
    $p = New-DragFrame 0 $Bar0
    foreach ($y in 40..43) { Set-SynthRect $p 50 $y 3 1 $Glyph }
    $s2 = New-SynthScorer
    [void]$s2.PickStripRows($p, 10, $H - 4, 60, 40, $Mid, 4, 40)
    Assert 'D3 a row where the left pane has text is left out' (@($s2.StripRows | Where-Object { $_ -ge 40 -and $_ -le 43 }).Count -eq 0) "rows=$($s2.StripRows -join ',')"
    $blank = New-Object GfcFrame
    $blank.Index = 0; $blank.W = $W; $blank.H = $H; $blank.Px = New-Object int[] ($W * $H)
    for ($i = 0; $i -lt $blank.Px.Length; $i++) { $blank.Px[$i] = $LeftBg }
    Set-SynthRect $blank $Bar0 0 $BarW $H $DragC
    $s3 = New-SynthScorer
    Assert 'D4 a zone that already equals the blank colour yields no strip row' ($s3.PickStripRows($blank, 10, $H - 4, 60, 40, $Mid, 4, 8) -eq 0) "rows=$($s3.StripRows -join ',')"
    Assert 'D5 the row colours are the left pane''s blank colour' (@($s.StripColors | Where-Object { $_ -ne $LeftBg }).Count -eq 0) "colours=$(($s.StripColors | ForEach-Object { '{0:X6}' -f $_ }) -join ',')"
    $r = [DgScorer]::RunNear($p, $Mid, $Bar0 + 1, 20, $DragC, 12)
    Assert 'D6 RunNear finds the pressed bar at its true extent' ($r -and $r[0] -eq $Bar0 -and $r[1] -eq ($Bar0 + $BarW - 1)) "run=$($r -join '-')"

    # ---- E. the summary -----------------------------------------------------
    ''
    'E. the summary counts per class and names capture indexes'
    $s = New-SynthScorer
    [void]$s.Score((New-DragFrame 500 ($Bar0 + 4)))
    $f = New-DragFrame 501 ($Bar0 + 40); Set-SynthRect $f ($Bar0 + 20) ($Mid - 1) 2 3 $DragC; [void]$s.Score($f)
    [void]$s.Score((New-DragFrame 502 ($Bar0 + 44) $LeftBg))
    [void]$s.Score((New-DragFrame 503 ($Bar0 + 48) $HoverC))
    $sum = Get-DividerGhostSummary $s
    Assert 'E1 one GHOST, one GONE, one hover, two bad' ($sum.Ghost -eq 1 -and $sum.Gone -eq 1 -and $sum.HoverFrames -eq 1 -and $sum.Bad -eq 2) "ghost=$($sum.Ghost) gone=$($sum.Gone) hover=$($sum.HoverFrames) bad=$($sum.Bad)"
    Assert 'E2 the worst list names capture indexes 501 and 502' (($sum.Worst -join ' ') -match '#501 GHOST' -and ($sum.Worst -join ' ') -match '#502 GONE') "worst=$($sum.Worst -join ' ; ')"
} else {
    # ---- L. the real app, the real pointer ----------------------------------
    # Injects and photographs on the input desktop: nobody may be at the box.
    . (Join-Path $PSScriptRoot 'lib\UserPresence.ps1')
    Assert-UserAbsent
    . (Join-Path $PSScriptRoot 'lib\FrameLabInput.ps1')
    Import-FrameLabInput
    Start-FrameLabPresenceClock
    . (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
    . (Join-Path $PSScriptRoot 'lib\ChromeGeometry.ps1')
    [void](Set-GhozttyTestIsolation -Tag 'dvghost' -Quiet)
    if (-not $Exe) { $Exe = Join-Path $repo 'zig-out\bin\ghoztty.exe' }
    if (-not (Test-Path $Exe)) { throw "no app at $Exe" }
    # T350: a release-lineage exe would drive the user's own endpoints.
    . (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
    Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $out = Join-Path $repo "temp\divider-ghost\$stamp-$Control"
    $null = New-Item -ItemType Directory -Force -Path $out
    "L. live: control=$Control exe=$Exe out=$out"
    $conf = Join-Path $out 'config'
    $cfg = "background = #2a3a50`nconfirm-close-surface = false`ncommand = cmd.exe`n"
    if (-not $Dim) { $cfg += "unfocused-split-opacity = 1`n" }
    [IO.File]::WriteAllText($conf, $cfg)
    $prof = Join-Path $out 'profile'; $null = New-Item -ItemType Directory -Force (Join-Path $prof 'ghoztty')
    $errlog = Join-Path $out 'app-stderr.log'
    $saved = @{ LOCALAPPDATA = $env:LOCALAPPDATA; GHOZTTY_LAB_PLANT = $env:GHOZTTY_LAB_PLANT }
    $env:LOCALAPPDATA = $prof; $env:GHOZTTY_NO_STARTUP_ESCAPE = '1'; $env:GHOZTTY_CLAUDE_SETUP = '0'
    $env:GHOZTTY_LAB_PLANT = $(if ($Control -eq 'stale') { 'stale@8' } else { $null })
    try { $proc = Start-Process -FilePath $Exe -ArgumentList @('--config-default-files=false', '--session-persistence=false', "--config-file=$conf") -PassThru -RedirectStandardError $errlog }
    finally { $env:LOCALAPPDATA = $saved.LOCALAPPDATA; $env:GHOZTTY_LAB_PLANT = $saved.GHOZTTY_LAB_PLANT }
    $held = $false
    $dx = 0; $dy = 0
    try {
        $top = [IntPtr]::Zero
        for ($i = 0; $i -lt 100 -and $top -eq [IntPtr]::Zero; $i++) { Start-Sleep -Milliseconds 200; $top = [GflWin]::FindTop($proc.Id, 'GhozttyWindow') }
        if ($top -eq [IntPtr]::Zero) { throw 'L0: the window never appeared' }
        $scale = [GflWin]::WindowDpi($top) / 96.0
        $wa = [GflWin]::WorkArea($top)
        $ww = [math]::Min((Get-TestChromeDip 1300 $scale), $wa[2] - (Get-TestChromeDip 160 $scale))
        $wh = [math]::Min((Get-TestChromeDip 800 $scale), $wa[3] - (Get-TestChromeDip 120 $scale))
        [void][GflWin]::Place($top, $wa[0] + (Get-TestChromeDip 80 $scale), $wa[1] + (Get-TestChromeDip 60 $scale), $ww, $wh)
        Start-Sleep -Seconds 2
        $first = Get-FrameLabFirstPaneId $Exe $top
        $problems = @()
        if (-not $first) { $problems += '+list named no first pane' } else {
            $r = Invoke-FrameLabCli $Exe @('+split', "--target=$($first.PaneId)", '--direction=right', '--name=right')
            if ($r -match '(?i)error|unknown|not found') { $problems += "+split: $r" }
            Start-Sleep -Milliseconds 800
            # Fill the right pane so its first column is on every row the strip reads.
            $r = Invoke-FrameLabCli $Exe @('+send-keys', '--target=right', 'for /L %i in (1,1,120) do @echo ########################################', 'Enter')
            if ($r -match '(?i)error|unknown|not found') { $problems += "+send-keys: $r" }
        }
        Start-Sleep -Seconds 3
        $fr = [GflWin]::Frame($top)
        $panes = @([GflWin]::Children($top, 'GhozttyTerminal') | ForEach-Object { ConvertFrom-FrameLabChildRect $_ } | Sort-Object X)
        if ($panes.Count -ne 2) { $problems += "expected 2 terminal panes, found $($panes.Count)" }
        Assert 'L0 the window, the split and the right pane''s text are up' ($problems.Count -eq 0) ($problems -join ' | ')
        if ($problems.Count) { throw 'L0 failed' }
        $l = $panes[0]; $rp = $panes[1]
        $dx = [int](($l.X + $l.W + $rp.X) / 2); $dy = [int]($l.Y + $l.H / 2)
        $travel = [int][math]::Min((Get-TestChromeDip $TravelDip $scale), 0.4 * $rp.W)
        $ox = $fr[0]; $oy = $fr[1]

        # Part 1: hover over the bar, photograph it.
        $p1 = (New-FrameLabPath).MoveTo($dx, $dy).Hold(400).Build()
        $res1 = Invoke-FrameLabInput -Path $p1 -Presence (Get-FrameLabPresence)
        Set-FrameLabOwnInput
        if ($res1.Skipped) { "  SKIP L1-Le: $($res1.SkipReason)"; $script:skipped++; throw 'skipped' }
        $sh = Start-FrameCapture -X $fr[0] -Y $fr[1] -W $fr[2] -H $fr[3] -SampleEvery 0 -KeepFrames 1
        Start-Sleep -Milliseconds 300
        $rh = Stop-FrameCapture -Session $sh; $sh.Dispose()
        $hoverF = $rh.Kept[0]
        # Part 2: press, photograph the pressed bar.
        $p2 = (New-FrameLabPath).MoveTo($dx, $dy).Press().Hold(300).Build()
        $res2 = Invoke-FrameLabInput -Path $p2 -Presence (Get-FrameLabPresence)
        Set-FrameLabOwnInput
        if ($res2.Skipped) { "  SKIP L1-Le: $($res2.SkipReason)"; $script:skipped++; throw 'skipped' }
        $held = $true
        $sp = Start-FrameCapture -X $fr[0] -Y $fr[1] -W $fr[2] -H $fr[3] -SampleEvery 0 -KeepFrames 1
        Start-Sleep -Milliseconds 300
        $rpr = Stop-FrameCapture -Session $sp; $sp.Dispose()
        $pressF = $rpr.Kept[0]
        [void][GfcSession]::WritePng($hoverF, (Join-Path $out 'hover.png'))
        [void][GfcSession]::WritePng($pressF, (Join-Path $out 'pressed.png'))

        $sc = New-Object DgScorer
        $sc.Line = $dy - $oy
        $bx = $dx - $ox
        $dragC = $pressF.Px[$sc.Line * $pressF.W + $bx]
        $hoverC = $hoverF.Px[$sc.Line * $hoverF.W + $bx]
        $bar = [DgScorer]::RunNear($pressF, $sc.Line, $bx, (Get-TestChromeDip 8 $scale), $dragC, 12)
        $sc.Drag = $dragC
        $sc.Hover = $(if ([DgScorer]::Near($hoverC, $dragC, 12)) { -1 } else { $hoverC })
        if ($bar) {
            $sc.BarLeft = $bar[0]; $sc.BarRight = $bar[1]
            $sc.MaxW = ($bar[1] - $bar[0] + 1) + (Get-TestChromeDip 2 $scale)
            $sc.Lo = $bar[0] - (Get-TestChromeDip 40 $scale); $sc.Hi = $bar[1] + $travel + (Get-TestChromeDip 40 $scale)
            $nRows = $sc.PickStripRows($pressF, $l.Y - $oy + [int](0.3 * $l.H), $l.Y - $oy + [int](0.92 * $l.H), $travel, (Get-TestChromeDip 120 $scale), $sc.Line, (Get-TestChromeDip 6 $scale), 12)
        } else { $nRows = 0 }
        Assert 'L1 the pressed frame shows the bar and at least 2 strip rows' ($bar -and $nRows -ge 2) ("drag={0:X6} hover={1:X6} bar={2} rows={3}" -f $dragC, $hoverC, ($bar -join '-'), ($sc.StripRows -join ','))
        if (-not $bar -or $nRows -lt 2) { throw 'L1 failed' }
        "  drag colour {0:X6}, hover {1:X6}, bar {2}-{3}, maxw {4}, travel {5}, strip rows {6}" -f $dragC, $hoverC, $sc.BarLeft, $sc.BarRight, $sc.MaxW, $travel, ($sc.StripRows -join ',')

        # Part 3: the drag itself, scored frame by frame.
        $png = Join-Path $out 'frames'; $null = New-Item -ItemType Directory -Force $png
        $p3 = (New-FrameLabPath).MoveTo($dx, $dy).Line($dx + $travel, $dy, $DragMs).Hold(400).Release().Hold(150).Build()
        $s = Start-FrameCapture -X $fr[0] -Y $fr[1] -W $fr[2] -H $fr[3] -SampleEvery 0 -PngDir $png -Scorer $sc.AsScorer()
        Start-Sleep -Milliseconds 200
        $res3 = Invoke-FrameLabInput -Path $p3 -Presence (Get-FrameLabPresence)
        Set-FrameLabOwnInput
        if (-not $res3.Skipped -and -not $res3.Aborted) { $held = $false }
        Start-Sleep -Milliseconds 200
        $cap = Stop-FrameCapture -Session $s; $s.Dispose()
        if ($res3.Skipped) { "  SKIP L2-Le: $($res3.SkipReason)"; $script:skipped++; throw 'skipped' }
        if ($res3.Aborted) { "  SKIP L2-Le: the play aborted (somebody moved the mouse): sent $($res3.Sent) of $($res3.Planned)"; $script:skipped++; throw 'skipped' }
        Assert 'L2 every input sample was sent' ($res3.Sent -eq $res3.Planned) "sent=$($res3.Sent) planned=$($res3.Planned) late=$($res3.Late)"
        $sum = Get-DividerGhostSummary $sc
        "  captured=$($cap.Stats.Captured) scored=$($sum.Frames) drag=$($sum.DragFrames) hover=$($sum.HoverFrames) ghost=$($sum.Ghost) smear=$($sum.Smear) strip=$($sum.Strip) gone=$($sum.Gone) travel=$($sum.Travel) png=$($cap.Stats.PngWritten)"
        if ($sum.Worst.Count) { "  worst: $($sum.Worst -join ' ; ')" }
        $worst = $sum.Worst -join ' ; '
        $occl = Get-OccludedDisplaySkip -LogPath $errlog -What 'La-Le'
        if ($occl) { $occl; $script:skipped++; throw 'skipped' }
        if ($Control -eq 'none') {
            Assert 'La no GHOST frame (the old bar left behind)' ($sum.Ghost -eq 0) $worst
            Assert 'Lb no SMEAR frame (two positions fused)' ($sum.Smear -eq 0) $worst
            Assert 'Lc no STRIP frame (the grown zone not repainted: a doubled column)' ($sum.Strip -eq 0) $worst
        } else {
            Start-Sleep -Milliseconds 300
            $fired = @(Get-Content $errlog -ErrorAction SilentlyContinue | Where-Object { $_ -match 'lab plant fired kind=stale' })
            Assert 'Lx the stale plant fired in the app' ($fired.Count -gt 0) "stderr: $errlog"
            Assert 'Lx the planted stale present was caught (GHOST, SMEAR or STRIP)' (($sum.Ghost + $sum.Smear + $sum.Strip) -gt 0) "fired=$($fired.Count) $worst"
        }
        Assert 'Ld no GONE frame (the bar vanished mid-drag)' ($sum.Gone -eq 0) $worst
        Assert 'Le the drag happened (half the travel, 20+ drag frames)' ($sum.Travel -ge [int]($travel / 2) -and $sum.DragFrames -ge 20) "travel=$($sum.Travel) of $travel drag=$($sum.DragFrames)"
    } catch {
        if ($_.Exception.Message -notmatch '^(skipped|L0 failed|L1 failed)$') { Assert 'L the live run completed' $false $_.Exception.Message }
    } finally {
        # Never leave the button down on the user's desktop.
        if ($held) { try { [void](Invoke-FrameLabInput -Path ((New-FrameLabPath).MoveTo($dx, $dy).Release().Build()) -Presence ([pscustomobject]@{ Present = $false; Reason = 'releasing our own press'; Forced = $false })) } catch { } }
        try { Stop-Process -Id $proc.Id -Force } catch { }
    }
}
    Complete-TestBody
}
finally { }

# T783: a green synthetic run stamps the scorer's guard; a green live run with
# no control, on the default build and scene, stamps the advisory live guard.
if ($script:failures -eq 0 -and $script:skipped -eq 0) {
    if (-not $Live) {
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
            update -Guard divider-ghost -Repo $repo 2>&1 | ForEach-Object { "  $_" }
    } elseif ($Control -eq 'none' -and -not $Dim -and -not $PSBoundParameters.ContainsKey('Exe')) {
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
            update -Guard divider-ghost-live -Repo $repo 2>&1 | ForEach-Object { "  $_" }
    }
}

''
Write-TestVerdict -Label 'T2441 DIVIDER GHOST' -Pass $script:passes -Fail $script:failures -Skipped $script:skipped
