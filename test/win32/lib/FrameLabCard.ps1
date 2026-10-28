# FrameLabCard (T2383) - the deterministic scene the T2373 frame lab photographs.
#
# WHY A SCENE. The lab's scorer (FrameScore.ps1, T2381) can only call a pixel
# wrong if it knows what the pixel should have been. A real shell prompt does
# not give it that: text antialiases into a hundred colours, and a prompt that
# is short leaves most of the pane looking exactly like the window background a
# bleeding frame would show. So every pane in a lab run runs THIS card instead,
# and every pixel it puts on screen is one of three colours unique to its pane:
#
#   Bg      the whole grid
#   Ring    a one-cell border around the grid's edge - the scorer finds it from
#           each side of the pane, so a frame showing content too small (inset
#           ring) or too big (ring missing) is a stale size (B2), and a ring of
#           the wrong thickness is a stretch (B3)
#   Glyph   a large ID digit at a FIXED place and size, which only DWM scaling
#           an old frame can change (B3)
#
# All three are drawn as cell BACKGROUNDS (spaces under SGR 48;2), never as
# text, so no pixel of them is antialiased: the ring is exactly cell-sharp and
# the glyph's bounding box is exactly its cells. The one thing a pane shows
# that the card does not draw is the theme's padding around the grid, which a
# scene lists as the region's Extra colour.
#
# Busy mode (-Busy) fills the rows below the glyph with text that changes every
# tick, so the renderer has real work during a drag - the renderer-busy case:
# every tick re-shapes and re-rasterises a screenful of glyphs. That text is
# drawn in the Bg colour ON Bg, so it costs the renderer exactly what visible
# text costs and adds not one pixel outside the palette. It was the ring colour
# first, and a real capture showed why not: the renderer blends glyph edges in
# linear light, so an antialiased pixel lies on a CURVE between the two colours
# rather than on the straight sRGB line the scorer's B6 blend rule accepts, and
# 14,000 pixels of honest text read as garbage. It stays a cell clear of the
# ring on both sides all the same.
#
# THE CONTRACT WITH THE SCORER is New-FrameLabCardRegion: given where the pane
# is in the frame, its grid and its cell size, it returns the FsRegion the
# card's pixels must match. The layout rule (Get-FrameLabCardCell) is the same
# function the card draws with, so the scene cannot drift from the drawing.
#
# The palette is nine (Bg, Ring, Glyph) triples on a 4-level channel grid
# (0x20/0x60/0xA0/0xE0). Every colour is at least 64 from every other one on
# some channel, from the magenta the lab's erase control plants (T2383's
# lab_plant.zig), and from black, white and the usual dark theme backgrounds.
# frame-lab-card.ps1 proves all of that, plus that no antialiasing blend inside
# a card passes near magenta, rather than trusting this comment.
#
# ASCII-only by design (PS 5.1 on this box mangles non-ASCII on rewrite).

Set-StrictMode -Off

$script:FrameLabEsc = [string][char]27

# Index 1..9 -> Bg, Ring, Glyph (0xRRGGBB).
$script:FrameLabCardPalette = @(
    @(0x2060A0, 0xE02020, 0xE020A0),
    @(0x20A060, 0xE02060, 0xE060E0),
    @(0xA06020, 0x2020E0, 0x20A0E0),
    @(0x6020A0, 0x20E020, 0x20E0A0),
    @(0xA0A020, 0x2060E0, 0x20E0E0),
    @(0x20A0A0, 0xE06020, 0xE060A0),
    @(0xA02060, 0x20E060, 0x60E0E0),
    @(0x60A020, 0x6020E0, 0x60A0E0),
    @(0x6060A0, 0x60E020, 0x60E0A0)
)

# The colours the card must never use: the erase control's magenta, and the
# colours a pane commonly shows when it is NOT drawing (black, white, the
# usual dark theme backgrounds). A lab scene lists its own Flash colours too.
$script:FrameLabCardForbidden = @(0xFF00FF, 0x000000, 0xFFFFFF, 0x282C34, 0x1E1E1E, 0x0C0C0C, 0xCCCCCC)

# 3x5 digits, '#' = glyph cell. Every digit fills its whole 3x5 box, so the
# glyph's bounding box is the same size whatever the pane's id is.
$script:FrameLabDigits = @{
    '0' = @('###', '#.#', '#.#', '#.#', '###')
    '1' = @('.#.', '##.', '.#.', '.#.', '###')
    '2' = @('###', '..#', '###', '#..', '###')
    '3' = @('###', '..#', '###', '..#', '###')
    '4' = @('#.#', '#.#', '###', '..#', '..#')
    '5' = @('###', '#..', '###', '..#', '###')
    '6' = @('###', '#..', '###', '#.#', '###')
    '7' = @('###', '..#', '..#', '..#', '..#')
    '8' = @('###', '#.#', '###', '#.#', '###')
    '9' = @('###', '#.#', '###', '..#', '###')
}

# Where the glyph sits: two rows below the top ring, three columns in from the
# left one (a cell of Bg between it and the ring on both sides).
$script:FrameLabGlyphRow = 2
$script:FrameLabGlyphCol = 3

function Get-FrameLabCardColors {
    param([Parameter(Mandatory = $true)][ValidateRange(1, 9)][int]$Index)
    $t = $script:FrameLabCardPalette[$Index - 1]
    return [pscustomobject]@{ Bg = [int]$t[0]; Ring = [int]$t[1]; Glyph = [int]$t[2] }
}

# The glyph's scale for a grid: the requested one, shrunk until the glyph fits
# with a cell of Bg on every side inside the ring, 0 when even scale 1 does not
# fit (no glyph). A digit cell is (2*scale) columns by (scale) rows, which is
# roughly square on a terminal's 1:2 cells.
function Get-FrameLabGlyphScale {
    param([int]$Cols, [int]$Rows, [int]$Scale = 2)
    for ($s = $Scale; $s -ge 1; $s--) {
        $needCols = $script:FrameLabGlyphCol + 3 * 2 * $s + 2
        $needRows = $script:FrameLabGlyphRow + 5 * $s + 2
        if ($Cols -ge $needCols -and $Rows -ge $needRows) { return $s }
    }
    return 0
}

# What the card draws at one cell: 'R' ring, 'G' glyph, 'B' Bg.
function Get-FrameLabCardCell {
    param([int]$Row, [int]$Col, [int]$Cols, [int]$Rows, [string[]]$Mask, [int]$Scale)
    if ($Row -eq 0 -or $Col -eq 0 -or $Row -eq $Rows - 1 -or $Col -eq $Cols - 1) { return 'R' }
    if ($Scale -gt 0 -and $Mask) {
        $gr = $Row - $script:FrameLabGlyphRow
        $gc = $Col - $script:FrameLabGlyphCol
        if ($gr -ge 0 -and $gc -ge 0) {
            $mr = [math]::Floor($gr / $Scale)
            $mc = [math]::Floor($gc / (2 * $Scale))
            if ($mr -lt 5 -and $mc -lt 3 -and $Mask[$mr][$mc] -eq '#') { return 'G' }
        }
    }
    return 'B'
}

function ConvertTo-FrameLabSgrBg([int]$Rgb) {
    return "$($script:FrameLabEsc)[48;2;$(($Rgb -shr 16) -band 255);$(($Rgb -shr 8) -band 255);$($Rgb -band 255)m"
}

# The rows busy mode writes text into: below the glyph (or from row 2 when
# there is none), stopping a row short of the bottom ring. Empty when there is
# no room.
function Get-FrameLabBusyRows {
    param([int]$Rows, [int]$GlyphScale)
    $first = if ($GlyphScale -gt 0) { $script:FrameLabGlyphRow + 5 * $GlyphScale + 1 } else { 2 }
    $last = $Rows - 3
    if ($last -lt $first) { return @() }
    return @($first..$last)
}

<#
The card for one grid, as one VT string: synchronized-output bracketed, cursor
hidden, autowrap off (so writing the bottom-right cell cannot scroll the
screen), every row addressed absolutely. -Busy -Tick n adds that tick's text.
#>
function Format-FrameLabCard {
    param(
        [Parameter(Mandatory = $true)][int]$Cols,
        [Parameter(Mandatory = $true)][int]$Rows,
        [Parameter(Mandatory = $true)][ValidateRange(1, 9)][int]$Index,
        [int]$Scale = 2,
        [switch]$Busy,
        [int]$Tick = 0
    )
    $e = $script:FrameLabEsc
    $c = Get-FrameLabCardColors -Index $Index
    $scale = Get-FrameLabGlyphScale -Cols $Cols -Rows $Rows -Scale $Scale
    $mask = $script:FrameLabDigits[[string]$Index]
    $sgr = @{ R = (ConvertTo-FrameLabSgrBg $c.Ring); G = (ConvertTo-FrameLabSgrBg $c.Glyph); B = (ConvertTo-FrameLabSgrBg $c.Bg) }
    $busyRows = @{}
    if ($Busy -and $Cols -ge 6) { foreach ($r in (Get-FrameLabBusyRows -Rows $Rows -GlyphScale $scale)) { $busyRows[$r] = $true } }
    $fgText = "$e[38;2;$(($c.Bg -shr 16) -band 255);$(($c.Bg -shr 8) -band 255);$($c.Bg -band 255)m"
    $text = 'lab busy 0123456789 abcdefghijklmnopqrstuvwxyz ABCDEFGHIJKLMNOPQRSTUVWXYZ '

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("$e[?2026h$e[?25l$e[?7l$e[0m")
    for ($r = 0; $r -lt $Rows; $r++) {
        [void]$sb.Append("$e[$($r + 1);1H")
        if ($busyRows.ContainsKey($r)) {
            # Ring, a cell of Bg, the text, a cell of Bg, ring.
            $inner = $Cols - 4
            $off = (($Tick * 7) + ($r * 13)) % $text.Length
            $line = ''
            while ($line.Length -lt $inner + $off) { $line += $text }
            $line = $line.Substring($off, $inner)
            [void]$sb.Append($sgr.R + ' ' + $sgr.B + ' ' + $fgText + $line + "$e[39m" + ' ' + $sgr.R + ' ')
            continue
        }
        # Rows built from runs, not cell by cell: the card repaints on every
        # resize of a drag, and a card slow to repaint is a stale frame the
        # lab would blame on the app. Get-FrameLabCardCell is the rule this
        # must equal; frame-lab-card.ps1 checks it cell by cell.
        if ($r -eq 0 -or $r -eq $Rows - 1) {
            [void]$sb.Append($sgr.R + (' ' * $Cols))
            continue
        }
        $gr = $r - $script:FrameLabGlyphRow
        if ($scale -gt 0 -and $gr -ge 0 -and $gr -lt 5 * $scale) {
            $mrow = $mask[[math]::Floor($gr / $scale)]
            [void]$sb.Append($sgr.R + ' ' + $sgr.B + (' ' * ($script:FrameLabGlyphCol - 1)))
            for ($mc = 0; $mc -lt 3; $mc++) {
                $k = if ($mrow[$mc] -eq '#') { 'G' } else { 'B' }
                [void]$sb.Append($sgr[$k] + (' ' * (2 * $scale)))
            }
            $rest = $Cols - 1 - ($script:FrameLabGlyphCol + 6 * $scale)
            [void]$sb.Append($sgr.B + (' ' * $rest) + $sgr.R + ' ')
            continue
        }
        [void]$sb.Append($sgr.R + ' ' + $sgr.B + (' ' * ($Cols - 2)) + $sgr.R + ' ')
    }
    [void]$sb.Append("$e[0m$e[?2026l")
    return $sb.ToString()
}

<#
The scorer's view of one card (an FsRegion; FrameScore.ps1 must be loaded).

  -Card      the pane's content rect in frame coordinates (an FsBox)
  -Cols/-Rows the grid the card drew for
  -CellW/-CellH the cell size in pixels
  -PadLeft/-PadTop where the grid starts inside the card (the theme padding)
  -Extra     other colours legitimately in the card - the theme background
             showing in the padding, mostly

The right/bottom slack is whatever the grid leaves of the card: a pane whose
size is not a whole number of cells has up to a cell of padding there.
#>
function New-FrameLabCardRegion {
    param(
        [Parameter(Mandatory = $true)]$Card,
        [Parameter(Mandatory = $true)][ValidateRange(1, 9)][int]$Index,
        [Parameter(Mandatory = $true)][int]$Cols,
        [Parameter(Mandatory = $true)][int]$Rows,
        [Parameter(Mandatory = $true)][int]$CellW,
        [Parameter(Mandatory = $true)][int]$CellH,
        [int]$PadLeft = 0,
        [int]$PadTop = 0,
        [int]$Scale = 2,
        [int[]]$Extra = @(),
        [string]$Name
    )
    $c = Get-FrameLabCardColors -Index $Index
    $scale = Get-FrameLabGlyphScale -Cols $Cols -Rows $Rows -Scale $Scale
    $r = New-Object FsRegion
    $r.Name = $(if ($Name) { $Name } else { "card$Index" })
    $r.Card = $Card
    $r.Bg = $c.Bg; $r.Ring = $c.Ring; $r.Glyph = $c.Glyph
    $r.Extra = [int[]]$Extra
    $r.RingW = $CellW; $r.RingH = $CellH
    $r.Slack = [int[]]@(
        $PadLeft,
        $PadTop,
        [math]::Max(0, $Card.W - $PadLeft - $Cols * $CellW),
        [math]::Max(0, $Card.H - $PadTop - $Rows * $CellH)
    )
    if ($scale -gt 0) {
        $r.GlyphW = 3 * 2 * $scale * $CellW
        $r.GlyphH = 5 * $scale * $CellH
    } else {
        $r.Glyph = -1
    }
    return $r
}
