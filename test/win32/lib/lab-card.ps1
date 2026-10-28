# T2383 fixture: the frame lab's test card, run INSIDE a pane.
#
# Draws FrameLabCard.ps1's card for pane -Index at whatever size the pane is,
# and redraws it the moment that size changes - so during a drag the pane
# always holds the card for its CURRENT grid, and any frame that shows a card
# of the wrong size is the app's doing, not the fixture's. -Busy also redraws
# every tick with changing text, so the renderer has work while it resizes.
#
# -Out (optional): after every redraw at a new size, the file holds one line
#
#     <cols> <rows> <glyph-scale> <redraws>
#
# written atomically (temp + rename), which is what a driver builds the scene
# from (New-FrameLabCardRegion takes cols/rows) and how it knows the card has
# caught up with a resize.
#
# Holds the pane until it is killed.
param(
    [Parameter(Mandatory = $true)][ValidateRange(1, 9)][int]$Index,
    [int]$Scale = 2,
    [switch]$Busy,
    [ValidateRange(1, 1000)][int]$Hz = 120,
    [string]$Out
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'FrameLabCard.ps1')

$stdout = [Console]::OpenStandardOutput()
$enc = [System.Text.Encoding]::ASCII
function Write-Raw([string]$s) {
    # One write per card, straight to the stream: no line translation, no
    # per-line flush, so the terminal sees the whole card in one burst.
    $b = $enc.GetBytes($s)
    $stdout.Write($b, 0, $b.Length)
    $stdout.Flush()
}

$last = ''
$redraws = 0
$tick = 0
$period = [math]::Max(1, [int](1000 / $Hz))
while ($true) {
    $w = [Console]::WindowWidth
    $h = [Console]::WindowHeight
    $key = "$w $h"
    $resized = $key -ne $last
    if (($resized -or $Busy) -and $w -ge 3 -and $h -ge 3) {
        Write-Raw (Format-FrameLabCard -Cols $w -Rows $h -Index $Index -Scale $Scale -Busy:$Busy -Tick $tick)
        $redraws++
        $tick++
        if ($resized) {
            $last = $key
            if ($Out) {
                $s = Get-FrameLabGlyphScale -Cols $w -Rows $h -Scale $Scale
                $tmp = "$Out.tmp"
                [System.IO.File]::WriteAllText($tmp, "$w $h $s $redraws")
                Move-Item -LiteralPath $tmp -Destination $Out -Force
            }
        }
    }
    Start-Sleep -Milliseconds $(if ($Busy) { $period } else { 5 })
}
