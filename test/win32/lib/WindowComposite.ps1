# WindowComposite.ps1 - a picture of a WHOLE WINDOW off the background test
# desktop: the parent's GDI chrome with every pane's rendered glass sitting in
# its own rect (T778).
#
# WHY THIS EXISTS. Route 0 (`lib\PaneCapture.ps1`, T275) asks the app for ONE
# pane's pixels, which answers "what is this pane showing" exactly and, by
# construction, nothing about anything outside that pane. The claim left with
# no oracle at all is the one between two panes: the divider band is painted by
# the PARENT, and a `PrintWindow` of the parent keeps every intermediate line a
# drag ever painted (measured 2026-07-31: 3 drags -> 13 runs) because the GL
# child never overpaints the parent's backing store in that render. So
# `split-divider.ps1` had to retire its cross-pane stale-line scan (T228) and
# argue the same point from geometry instead - a real argument, but not a pixel
# measurement.
#
# A composite is what makes it a measurement again: draw the parent capture,
# then draw each pane's own capture over its own rect, and the result is what
# the screen would show. A stale line UNDER a pane is covered by that pane's
# glass exactly as it is on screen; one left in the parent-visible gap survives.
#
# WHERE THE COMPOSITION HAPPENS, and why here rather than in the app. The app
# side is the only one that could get z-order and clipping right without
# restating the layout - but it does not have to restate anything: the panes of
# a split TILE, so "each pane's glass over its own rect" is the whole of the
# composition, and the one fact the harness could not know - where each pane
# IS - is now reported by the capture itself (`x`/`y`/`client_width`/
# `client_height`, T778). That keeps a second image-composition path out of the
# product, keeps the IPC shape a capture rather than a screenshot service, and
# leaves the composite where the assertions that read it live.
#
# WHAT IT DOES NOT COVER, stated so nothing mistakes it for a screenshot:
#
#   * Anything drawn OVER the glass by a window that is not the parent - the
#     banner overlay, the key-state pill, a modal - is its own top-level window
#     and is not in either capture. A probe about chrome-over-glass still has
#     to capture that window.
#   * The parent's own paint UNDER a pane is deliberately hidden, which is the
#     point. A test that wants to see it wants the raw PrintWindow, not this.
#   * A pane whose renderer has never presented a frame has no capture, so the
#     composite REFUSES rather than leaving the parent's flat fill showing
#     through where glass belongs. A hole is indistinguishable from stale
#     paint, and scoring one as the other is the failure this whole file
#     exists to avoid.

Set-StrictMode -Off
Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue

$script:LastCompositeError = $null

# The reason the last Get-TestWindowComposite returned $null.
function Get-LastCompositeError { return $script:LastCompositeError }

<#
The terminal panes of a top-level window, as IPC target names, read from
`+list --json`.

`+list`'s window `id` IS the decimal HWND (asserted in pane-capture.ps1
section 5), so the window the harness holds a handle to and the window the
registry describes are the same object without any correlation heuristic.

Viewer leaves are dropped: they have no renderer and `capture-pane` refuses
them by name, which is a fixture mistake rather than a product failure.
#>
function Get-TestWindowPaneTargets {
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Window,
        [Parameter(Mandatory = $true)][string]$Exe
    )
    $json = (& $Exe +list --json 2>$null | Out-String).Trim()
    if (-not $json) { return @() }
    try { $data = ($json | ConvertFrom-Json).data } catch { return @() }
    $want = [int64]$Window
    foreach ($w in $data.windows) {
        if ([int64]$w.id -ne $want) { continue }
        $tab = $w.tabs | Where-Object { $_.selected } | Select-Object -First 1
        if (-not $tab) { $tab = $w.tabs | Select-Object -First 1 }
        if (-not $tab) { return @() }
        $out = New-Object System.Collections.Generic.List[string]
        Add-CompositeLeaf $tab.splits $out
        return @($out.ToArray())
    }
    return @()
}

# Depth-first walk of a `+list --json` split tree, collecting terminal leaf
# names. Recursive because the tree is: a split's children are nodes of the
# same shape, and a two-pane layout is only the shallowest case of it. The node
# shape is `src/apprt/ipc/list.zig`'s writeNode - a tagged `type` of "leaf"
# (with `terminal`) or "split" (with `left`/`right`).
function Add-CompositeLeaf($node, $out) {
    if ($null -eq $node) { return }
    if ($node.type -eq 'leaf') {
        $leaf = $node.terminal
        if (-not $leaf) { return }
        # A viewer leaf has no renderer, and capture-pane refuses it by name.
        if ($leaf.type -eq 'viewer') { return }
        $name = if ($leaf.name) { $leaf.name } else { $leaf.id }
        if ($name) { $out.Add([string]$name) }
        return
    }
    if ($node.type -eq 'split') {
        Add-CompositeLeaf $node.left $out
        Add-CompositeLeaf $node.right $out
    }
}

<#
A composited capture of $Window: the parent's PrintWindow with each pane's
own capture drawn over its own rect.

Returns a shot in Get-TestWindowPixels' shape - { Bitmap, Width, Height, Left,
Top } in SCREEN coordinates - so Get-TestPixel, Get-TestBrightness and every
strip helper already written against a window capture read it unchanged. Plus
`Panes`, the placements that were composed in, for an assertion label.

$null on failure with the reason in Get-LastCompositeError. Every failure here
is a fixture or product state a caller must be able to tell apart: no panes
listed, a pane that would not capture, a build with no placement in its capture
response.

-Targets overrides the enumeration (for a fixture that knows its own names);
-Exe is required otherwise.
#>
function Get-TestWindowComposite {
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Window,
        [string]$Exe,
        [string[]]$Targets,
        $Desktop
    )
    $script:LastCompositeError = $null

    if (-not $Targets -or $Targets.Count -eq 0) {
        if (-not $Exe) {
            $script:LastCompositeError = 'neither -Targets nor -Exe was given'
            return $null
        }
        $Targets = Get-TestWindowPaneTargets -Window $Window -Exe $Exe
    }
    if (-not $Targets -or @($Targets).Count -eq 0) {
        $script:LastCompositeError = 'the window listed no terminal panes'
        return $null
    }

    # -Sync for the reason T845 gave the hover capture one: the
    # PW_RENDERFULLCONTENT copy is a DWM copy and can predate the paint it is
    # supposed to be a picture of. A composite is read for a one-pixel-wide
    # band, so a frame-late parent is not a rounding error here.
    # -AllowUniform because the parent legitimately CAN be one color: off the
    # background desktop its chrome may be a flat fill and every pixel that
    # matters is about to be drawn over it by the panes.
    $parent = Get-TestWindowPixels -Window $Window -Sync -AllowUniform -Desktop $Desktop
    $canvas = $null
    $g = $null
    $placed = New-Object System.Collections.Generic.List[object]
    try {
        $canvas = New-Object System.Drawing.Bitmap($parent.Width, $parent.Height,
            [System.Drawing.Imaging.PixelFormat]::Format32bppRgb)
        $g = [System.Drawing.Graphics]::FromImage($canvas)
        # Nothing here wants resampling: a capture is taken at the pane's own
        # size, so every blit is 1:1 and a smoothing filter would invent
        # in-between colors along exactly the band edges being measured.
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
        $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
        $g.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
        $g.DrawImage($parent.Bitmap, 0, 0, $parent.Width, $parent.Height)

        foreach ($t in $Targets) {
            $shot = Get-TestPaneCapture -Target $t
            if ($null -eq $shot) {
                $script:LastCompositeError = "pane '$t' did not capture: $(Get-LastPaneCaptureError)"
                return $null
            }
            try {
                if ($null -eq $shot.ScreenX -or $null -eq $shot.ClientWidth) {
                    $script:LastCompositeError = (
                        "pane '$t' reported no placement - this build's capture-pane " +
                        'predates T778, so there is nothing to say WHERE its glass belongs')
                    return $null
                }
                if ($shot.ClientWidth -le 0 -or $shot.ClientHeight -le 0) {
                    $script:LastCompositeError = "pane '$t' has a $($shot.ClientWidth)x$($shot.ClientHeight) content area"
                    return $null
                }
                $g.DrawImage($shot.Bitmap,
                    ($shot.ScreenX - $parent.Left), ($shot.ScreenY - $parent.Top),
                    $shot.ClientWidth, $shot.ClientHeight)
                $placed.Add([pscustomobject]@{
                    Target = $t
                    Left = $shot.ScreenX; Top = $shot.ScreenY
                    Width = $shot.ClientWidth; Height = $shot.ClientHeight
                })
            } finally {
                Close-TestPaneCapture $shot
            }
        }

        $out = [pscustomobject]@{
            Bitmap = $canvas
            Width  = $parent.Width
            Height = $parent.Height
            Left   = $parent.Left
            Top    = $parent.Top
            Panes  = @($placed.ToArray())
        }
        $canvas = $null   # ownership passes to the caller
        return $out
    } finally {
        if ($g) { $g.Dispose() }
        if ($canvas) { $canvas.Dispose() }
        Close-TestWindowPixels $parent
    }
}

function Close-TestWindowComposite {
    param($Shot)
    if ($Shot -and $Shot.Bitmap) { $Shot.Bitmap.Dispose() }
}
