# T1183 acceptance: an image opens as a PICTURE, fitted, not as source text.
#
# What is asserted:
#
#   - `--view=<file>.png` (and .jpg/.gif/.webp/.svg) enters image mode: the
#     picture is FETCHED through the pane's own origin, with an image MIME
#     type, which a syntax-highlighted source view never does.
#   - the pane fits it on open: a picture larger than the pane opens below
#     100%, and `zoom` equals `fit` exactly.
#   - best-fit NEVER upscales: a 16x16 icon in a full-size pane opens at 100%,
#     not blown up to fill it.
#   - 100% is one image pixel per DEVICE pixel: the CSS scale the pane pushes
#     is `zoom / dpr`, at whatever scale factor the display reports.
#   - a vector (.svg) is measured as a vector, where 100% is the drawing's own
#     size rather than a pixel count.
#   - `+list --json` reports the pane the way it reports every other viewer
#     mode: type `viewer`, `url` the file's own path.
#   - `+reload` re-fetches the bytes (the revision moves), which is what makes
#     a re-exported screenshot appear.
#   - a corrupt/undecodable image gets the pane's own error card naming the
#     file, rather than a blank matte.
#   - a `.txt` control in the same run produces NONE of it.
#   - ctrl+C (and ctrl+Insert) at an image pane copies the PICTURE (T1872):
#     the size is read back off the clipboard, a PNG file is published
#     verbatim as the "PNG" format, and a text pane keeps the page's own copy.
#     A phone photo with an EXIF orientation copies upright, the way the
#     pane shows it (T1910).
#   - formats Chromium cannot draw are decoded by the pane (T1234): a .tiff is
#     served as WIC-decoded pixels and drawn at its real size, an .icns as its
#     largest embedded PNG, and a HEIC nothing can decode gets the card that
#     names the HEIF Image Extensions only on a box that lacks them.
#
# ORACLE, and why it is the log. This runs on the background test desktop,
# where CopyFromScreen and SendInput are dead (T233), so nothing out here can
# see a rendered picture. The pane states what it decided instead:
#
#     viewer image pane=<id> event=<e> natural=WxH viewport=WxH dpr=D kind=K
#         zoom=Z fit=F fitting=B scale=S
#     viewer image served pane=<id> rev=<n> bytes=<n> mime=<type>
#
# The first is emitted by `applyImageMessage`, the only place a zoom is
# decided; the second by `serveImage`, the only place the file's bytes reach
# the page. Neither line can be produced by any other path, and a source view
# produces neither.
#
#   - the GESTURES (T1233, section L): a double-click toggles fit and 100%, a
#     ctrl+wheel notch zooms in and out, ctrl+= / ctrl+0 zoom the picture, and
#     each zoom keeps the pixel under the pointer under it. A plain wheel pans
#     and a sub-step ctrl+wheel decides nothing - the controls.
#
# How a gesture gets in. SendInput is dead on this desktop, so section L
# drives the page over the DevTools protocol (lib\WebViewCdp.ps1):
# `Input.dispatchMouseEvent` enters the renderer's own input pipeline, so the
# page's listeners see a real `dblclick` / ctrl `wheel`, and everything from
# there on is the product. The arithmetic that DECIDES each zoom -
# `Geometry.doubleClickZoom`, `.stepped`, `.clamp` - is asserted exhaustively
# in the none lane (`src\apprt\win32\viewer_image.zig`); this proves the
# gesture reaches it and the answer reaches the picture. Not reached: the OS
# half (a touchpad driver turning a pinch into ctrl+wheel), which no harness
# on this box can produce.
#
# -NegativeControl inverts the two load-time assertions in section B and MUST
# fail with exactly TWO failures, so a run that scores anything else is
# measuring something other than the fit.
#
# Only touches ghoztty processes running from this repo's zig-out*.
#
#   powershell -NoProfile -File test\win32\viewer-image.ps1
param(
    [string]$ExePath,
    [switch]$NegativeControl,
    [switch]$Interactive
)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }
if (-not (Test-Path $exe)) { Write-Host "SETUP FAIL: no exe at $exe"; exit 1 }

# Endpoint isolation: a run must never reach the user's own instance.
$env:GHOZTTY_PIPE_SUFFIX = "-vimg$PID"

. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
Assert-GhozttyIsolatedBuild -Exe $exe | Out-Null
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
# T1233: the DevTools driver for section L, armed before the launch below - the
# runtime reads the switch when the app's browser process starts.
. (Join-Path $PSScriptRoot 'lib\FreePort.ps1')
. (Join-Path $PSScriptRoot 'lib\WebViewCdp.ps1')
$cdpPort = Enable-WebViewCdp
# T1511: the shared scorer, and the dot-source is also what ARMS the run - a
# body that unwinds before `Complete-TestBody` may not print a pass, and the
# guard-stamping child below reads the same state and refuses to write.
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:pass = 0
$script:fail = 0
$script:skipped = 0

function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Stop-RepoInstances {
    [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
}

function Invoke-Verb([string[]]$VerbArgs) {
    $out = (& $exe @VerbArgs 2>&1 | ForEach-Object { $_.ToString() } | Out-String)
    return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
}

function Get-Data {
    $json = (& $exe +list --json 2>$null | Out-String).Trim()
    if (-not $json) { return $null }
    return ($json | ConvertFrom-Json).data
}

function Get-Leaves($node) {
    if ($node.type -eq 'leaf') { return @($node.terminal) }
    return @(Get-Leaves $node.left) + @(Get-Leaves $node.right)
}

function Get-Win($target) {
    $data = Get-Data
    if (-not $data) { return $null }
    foreach ($w in $data.windows) { if ($w.target -eq $target) { return $w } }
    return $null
}

function Wait-Win($target) {
    for ($t = 0; $t -lt 25; $t++) {
        $w = Get-Win $target
        if ($w) { return $w }
        Start-Sleep -Milliseconds 200
    }
    return $null
}

function Get-OnlyPane($target) {
    $w = Get-Win $target
    if (-not $w) { return $null }
    $leaves = @(Get-Leaves $w.tabs[0].splits)
    if ($leaves.Count -ne 1) { return $null }
    return $leaves[0]
}

# Every image decision this pane has reported, oldest first.
function Get-ImageStates($errlog, $paneId) {
    if (-not (Test-Path $errlog) -or -not $paneId) { return @() }
    $out = @()
    $re = "viewer image pane=$([regex]::Escape($paneId)) event=(\S+) natural=(\S+)x(\S+) " +
          "viewport=(\S+)x(\S+) dpr=(\S+) kind=(\S+) zoom=(\S+) fit=(\S+) fitting=(\S+) scale=(\S+)"
    foreach ($line in (Get-Content $errlog -ErrorAction SilentlyContinue)) {
        if ($line -match $re) {
            $out += [pscustomobject]@{
                Event    = $Matches[1]
                NatW     = [double]$Matches[2]
                NatH     = [double]$Matches[3]
                ViewW    = [double]$Matches[4]
                ViewH    = [double]$Matches[5]
                Dpr      = [double]$Matches[6]
                Kind     = $Matches[7]
                Zoom     = [double]$Matches[8]
                Fit      = [double]$Matches[9]
                Fitting  = ($Matches[10] -eq 'true')
                Scale    = [double]$Matches[11]
            }
        }
    }
    return $out
}

# The pane's first `loaded` decision - the open, before anything could resize
# it. Waited for, because the picture has to decode in the browser first.
function Wait-Loaded($errlog, $paneId) {
    for ($t = 0; $t -lt 80; $t++) {
        $hit = @(Get-ImageStates $errlog $paneId | Where-Object { $_.Event -eq 'loaded' })
        if ($hit.Count -gt 0) { return $hit[0] }
        Start-Sleep -Milliseconds 250
    }
    return $null
}

function Get-ImageServed($errlog, $paneId) {
    if (-not (Test-Path $errlog) -or -not $paneId) { return @() }
    $out = @()
    foreach ($line in (Get-Content $errlog -ErrorAction SilentlyContinue)) {
        if ($line -match "viewer image served pane=$([regex]::Escape($paneId)) rev=(\d+) bytes=(\d+) mime=(\S+)(?: route=(\S+))?") {
            $out += [pscustomobject]@{ Rev = [int]$Matches[1]; Bytes = [int]$Matches[2]; Mime = $Matches[3]; Route = $Matches[4] }
        }
    }
    return $out
}

function Wait-ImageServed($errlog, $paneId, [int]$AtLeast = 1) {
    for ($t = 0; $t -lt 80; $t++) {
        $n = @(Get-ImageServed $errlog $paneId)
        if ($n.Count -ge $AtLeast) { return $n }
        Start-Sleep -Milliseconds 250
    }
    return @(Get-ImageServed $errlog $paneId)
}

function Near([double]$a, [double]$b, [double]$tol = 0.002) {
    return ([Math]::Abs($a - $b) -le $tol)
}

# Open a viewer in a NEW top-level window and return the window, its
# viewer host and the Chromium input child the chord is posted at.
function Open-ViewerTop([string]$target, [string]$path) {
    $before = @(Get-TestWindows -ProcessId $appPid | ForEach-Object { $_.Hwnd })
    $rr = Invoke-Verb @('+new-window', "--target=$target", "--view=$path")
    $top = [IntPtr]::Zero; $chrome = [IntPtr]::Zero; $viewHost = [IntPtr]::Zero
    for ($t = 0; $t -lt 50 -and $chrome -eq [IntPtr]::Zero; $t++) {
        $new = @(Get-TestWindows -ProcessId $appPid | Where-Object { $before -notcontains $_.Hwnd })
        if ($new.Count -ge 1) {
            $top = [IntPtr]$new[0].Hwnd
            foreach ($h in @(Get-TestChildWindows -Window $top -Class 'GhozttyViewer')) {
                $widget = @(Get-TestChildWindows -Window ([IntPtr][int64]$h.Hwnd) -Class '*' |
                    Where-Object { $_.Class -eq 'Chrome_WidgetWin_1' })
                if ($widget.Count -ge 1) {
                    $chrome = [IntPtr][int64]$widget[0].Hwnd
                    $viewHost = [IntPtr][int64]$h.Hwnd
                }
            }
        }
        if ($chrome -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 200 }
    }
    $lf = Get-OnlyPane $target
    return [pscustomobject]@{
        Code = $rr.Code; Top = $top; Chrome = $chrome; Host = $viewHost
        Pane = if ($lf) { $lf.id } else { $null }
    }
}
# --- the pictures under test -----------------------------------------------
$dir = Join-Path $env:TEMP ('ghoztty-t1183-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $dir | Out-Null

Add-Type -AssemblyName System.Drawing

# A picture far larger than any pane on this box, so best-fit MUST shrink it.
$bigPath = Join-Path $dir 'big.png'
$big = New-Object System.Drawing.Bitmap 4000, 3000
try {
    $g = [System.Drawing.Graphics]::FromImage($big)
    $g.Clear([System.Drawing.Color]::CornflowerBlue)
    $g.Dispose()
    $big.Save($bigPath, [System.Drawing.Imaging.ImageFormat]::Png)
} finally { $big.Dispose() }

# Section L's own picture (T1233), with a name no other pane carries, because
# the DevTools page is found by the <img>'s alt text.
$gesturePath = Join-Path $dir 'gesture.png'
$gesture = New-Object System.Drawing.Bitmap 4000, 3000
try {
    $g = [System.Drawing.Graphics]::FromImage($gesture)
    $g.Clear([System.Drawing.Color]::SlateGray)
    $g.Dispose()
    $gesture.Save($gesturePath, [System.Drawing.Imaging.ImageFormat]::Png)
} finally { $gesture.Dispose() }

# A 16x16 icon: smaller than any pane, so fit would be an enormous upscale -
# and must not be.
$iconPath = Join-Path $dir 'icon.png'
$icon = New-Object System.Drawing.Bitmap 16, 16
try {
    $g = [System.Drawing.Graphics]::FromImage($icon)
    $g.Clear([System.Drawing.Color]::Firebrick)
    $g.Dispose()
    $icon.Save($iconPath, [System.Drawing.Imaging.ImageFormat]::Png)
} finally { $icon.Dispose() }

# A JPEG, because the extension table is a table and one entry proves nothing.
$jpgPath = Join-Path $dir 'shot.jpg'
$jpg = New-Object System.Drawing.Bitmap 800, 400
try {
    $g = [System.Drawing.Graphics]::FromImage($jpg)
    $g.Clear([System.Drawing.Color]::SeaGreen)
    $g.Dispose()
    $jpg.Save($jpgPath, [System.Drawing.Imaging.ImageFormat]::Jpeg)
} finally { $jpg.Dispose() }

# A phone photo (T1910): stored 800x400 in sensor order with EXIF Orientation
# 6, so it is SHOWN 400x800. PropertyItem has no public constructor; an
# uninitialised one is how System.Drawing is handed a new tag.
$phonePath = Join-Path $dir 'phone.jpg'
$phone = New-Object System.Drawing.Bitmap 800, 400
try {
    $g = [System.Drawing.Graphics]::FromImage($phone)
    $g.Clear([System.Drawing.Color]::DarkOrange)
    $g.Dispose()
    $tag = [System.Runtime.Serialization.FormatterServices]::GetUninitializedObject([System.Drawing.Imaging.PropertyItem])
    $tag.Id = 0x0112; $tag.Type = 3; $tag.Len = 2; $tag.Value = [byte[]](6, 0)
    $phone.SetPropertyItem($tag)
    $phone.Save($phonePath, [System.Drawing.Imaging.ImageFormat]::Jpeg)
} finally { $phone.Dispose() }

# Vector art with an intrinsic size, which is what makes 100% mean something
# different for it.
$svgPath = Join-Path $dir 'logo.svg'
Set-Content -LiteralPath $svgPath -Encoding UTF8 -Value @'
<svg xmlns="http://www.w3.org/2000/svg" width="240" height="120" viewBox="0 0 240 120">
  <rect width="240" height="120" fill="#4477cc"/>
</svg>
'@

# A `.png` that is not one: the error-card path.
$corruptPath = Join-Path $dir 'broken.png'
Set-Content -LiteralPath $corruptPath -Value 'this is not a picture' -Encoding ASCII

# T1234: formats Chromium has no decoder for, which the pane decodes itself.
# A TIFF (WIC's built-in codec), served to the page as decoded pixels.
$tiffPath = Join-Path $dir 'scan.tiff'
$tif = New-Object System.Drawing.Bitmap 640, 480
try {
    $g = [System.Drawing.Graphics]::FromImage($tif)
    $g.Clear([System.Drawing.Color]::SlateBlue)
    $g.Dispose()
    $tif.Save($tiffPath, [System.Drawing.Imaging.ImageFormat]::Tiff)
} finally { $tif.Dispose() }

# An .icns holding a 32px and a 128px PNG (in that order) behind an RLE entry
# that is not a PNG: the pane must show the 128px one.
function Get-PngBytes([int]$size) {
    $bmp = New-Object System.Drawing.Bitmap $size, $size
    $ms = New-Object System.IO.MemoryStream
    try {
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.Clear([System.Drawing.Color]::Goldenrod)
        $g.Dispose()
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        return , $ms.ToArray()
    } finally { $bmp.Dispose(); $ms.Dispose() }
}
function Get-BigEndian([int]$n) {
    # Each element parenthesised: the comma binds tighter than -band.
    return [byte[]]@((($n -shr 24) -band 0xFF), (($n -shr 16) -band 0xFF), (($n -shr 8) -band 0xFF), ($n -band 0xFF))
}
function Get-IcnsEntry([string]$kind, [byte[]]$data) {
    return [byte[]]([Text.Encoding]::ASCII.GetBytes($kind) + (Get-BigEndian ($data.Length + 8)) + $data)
}
$icnsBody = [byte[]]((Get-IcnsEntry 'is32' ([Text.Encoding]::ASCII.GetBytes('rle-bitmap'))) +
    (Get-IcnsEntry 'ic05' (Get-PngBytes 32)) + (Get-IcnsEntry 'ic07' (Get-PngBytes 128)))
$icnsPath = Join-Path $dir 'app.icns'
[IO.File]::WriteAllBytes($icnsPath,
    [byte[]]([Text.Encoding]::ASCII.GetBytes('icns') + (Get-BigEndian ($icnsBody.Length + 8)) + $icnsBody))

# A HEIC container no codec can decode: a real `ftyp heic` box and garbage
# after it. Which card it gets depends on whether this box has the HEIF Image
# Extensions - the oracle reads that rather than assuming it.
$heicPath = Join-Path $dir 'phone.heic'
[IO.File]::WriteAllBytes($heicPath, [byte[]](
    [byte[]](0, 0, 0, 24) + [Text.Encoding]::ASCII.GetBytes('ftypheic') + [byte[]](0, 0, 0, 0) +
    [Text.Encoding]::ASCII.GetBytes('mif1heic') + [Text.Encoding]::ASCII.GetBytes('not really a photo')))
$heifInstalled = [bool](Get-AppxPackage -Name 'Microsoft.HEIFImageExtension' -ErrorAction SilentlyContinue)

# The control: a text file in the same directory, opened in the same run.
$txtPath = Join-Path $dir 'notes.txt'
Set-Content -LiteralPath $txtPath -Value 'T1183 control: plain text' -Encoding UTF8

Stop-RepoInstances
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    $errlog = Join-Path $env:TEMP 'ghoztty-viewer-image-stderr.log'
    Remove-Item $errlog -ErrorAction SilentlyContinue
    $app = Start-OnTestDesktop -Exe $exe -StdErr $errlog -Arguments @('--session-persistence=false')
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $appPid = $app.Pid
    if ((Wait-TestWindow -ProcessId $appPid -Class 'GhozttyWindow') -eq [IntPtr]::Zero) {
        Write-Host 'SETUP FAIL: no GhozttyWindow'; exit 1
    }

    # --- A. a .png opens as a picture, and its bytes are fetched -------------
    $r = Invoke-Verb @('+new-window', '--target=t1183big', "--view=$bigPath")
    Assert ($r.Code -eq 0) "+new-window --view=<file>.png exits 0 (got $($r.Code))"
    Assert ($null -ne (Wait-Win 't1183big')) 'the image viewer window exists'
    $leaf = Get-OnlyPane 't1183big'
    $bigPane = if ($leaf) { $leaf.id } else { $null }
    Assert ($null -ne $bigPane) 'the image viewer window has exactly one pane'

    # PS5.1: a function's array return unrolls, so a one-element result has a
    # $null .Count until it is re-wrapped. Every call site here re-wraps.
    $served = @(Wait-ImageServed $errlog $bigPane)
    Assert ($served.Count -ge 1) 'the picture was fetched through the pane origin, not rendered as text'
    Assert ($served.Count -ge 1 -and $served[0].Mime -eq 'image/png') `
        "...with an image MIME type (got '$(if ($served.Count) { $served[0].Mime } else { '-' })')"

    # --- B. it opens FITTED, below 100% -------------------------------------
    $st = Wait-Loaded $errlog $bigPane
    Assert ($null -ne $st) 'the pane decided a zoom for the picture'
    Assert ($st -and $st.NatW -eq 4000 -and $st.NatH -eq 3000) `
        "the pane measured the picture's real size (got $(if ($st) { "$($st.NatW)x$($st.NatH)" } else { '-' }))"
    Assert ($st -and $st.Kind -eq 'raster') 'a PNG is measured as raster art'

    $fitted = ($st -and $st.Fitting -and (Near $st.Zoom $st.Fit))
    $shrunk = ($st -and $st.Zoom -lt 1 -and $st.Zoom -gt 0)
    if ($NegativeControl) {
        Write-Host 'NEGATIVE CONTROL: asserting the picture does NOT open fitted - this run MUST fail'
        Assert (-not $fitted) 'B: a fresh picture opens at best-fit (negative control)'
        Assert (-not $shrunk) 'B: a picture larger than the pane opens below 100% (negative control)'
    } else {
        Assert $fitted 'B: a fresh picture opens at best-fit'
        Assert $shrunk "B: a picture larger than the pane opens below 100% (zoom=$(if ($st) { $st.Zoom } else { '-' }))"
    }

    # The fit is the CONSTRAINING axis of the pane it actually got, recomputed
    # here from the numbers the pane reported rather than from a guess.
    if ($st -and $st.ViewW -gt 0 -and $st.ViewH -gt 0) {
        $unit = 1 / [Math]::Max($st.Dpr, 1)
        $want = [Math]::Min(
            $st.ViewW / ($st.NatW * $unit),
            $st.ViewH / ($st.NatH * $unit))
        if ($want -gt 1) { $want = 1 }
        Assert (Near $st.Fit $want) `
            "B: fit is the constraining axis of this pane (reported $($st.Fit), recomputed $([Math]::Round($want, 4)))"
    } else {
        $script:skipped++
        Write-Host 'SKIP  B: the pane reported no viewport to recompute the fit against'
    }

    # 100% means one image pixel per DEVICE pixel, so the CSS scale the pane
    # pushes is the zoom divided by the display's scale factor. This is the
    # whole definition, measured at whatever dpr this box actually has.
    if ($st) {
        Assert (Near $st.Scale ($st.Zoom / [Math]::Max($st.Dpr, 1))) `
            "B: the pushed scale is zoom/dpr - one image pixel per device pixel at 100% (dpr=$($st.Dpr))"
    }

    # --- C. best-fit never upscales ------------------------------------------
    $r = Invoke-Verb @('+new-window', '--target=t1183icon', "--view=$iconPath")
    Assert ($r.Code -eq 0) "+new-window --view=<icon>.png exits 0 (got $($r.Code))"
    Assert ($null -ne (Wait-Win 't1183icon')) 'the icon window exists'
    $iconLeaf = Get-OnlyPane 't1183icon'
    $iconPane = if ($iconLeaf) { $iconLeaf.id } else { $null }
    $ist = Wait-Loaded $errlog $iconPane
    Assert ($null -ne $ist) 'the icon pane decided a zoom'
    Assert ($ist -and $ist.NatW -eq 16 -and $ist.NatH -eq 16) 'the icon was measured at 16x16'
    Assert ($ist -and (Near $ist.Fit 1)) `
        "C: a 16px icon in a full-size pane fits at 100%, not blown up (fit=$(if ($ist) { $ist.Fit } else { '-' }))"
    Assert ($ist -and (Near $ist.Zoom 1)) 'C: ...and that is the zoom it opens at'

    # --- D. the rest of the extension table ---------------------------------
    $r = Invoke-Verb @('+new-window', '--target=t1183jpg', "--view=$jpgPath")
    Assert ($r.Code -eq 0) "+new-window --view=<file>.jpg exits 0 (got $($r.Code))"
    $jpgLeaf = Get-OnlyPane 't1183jpg'
    $jpgPane = if ($jpgLeaf) { $jpgLeaf.id } else { $null }
    $jserved = @(Wait-ImageServed $errlog $jpgPane)
    Assert ($jserved.Count -ge 1 -and $jserved[0].Mime -eq 'image/jpeg') `
        "D: a .jpg is served as image/jpeg (got '$(if ($jserved.Count) { $jserved[0].Mime } else { '-' })')"
    $jst = Wait-Loaded $errlog $jpgPane
    Assert ($jst -and $jst.NatW -eq 800 -and $jst.NatH -eq 400) 'D: and it is measured at its real size'

    # --- E. a vector is measured as one --------------------------------------
    $r = Invoke-Verb @('+new-window', '--target=t1183svg', "--view=$svgPath")
    Assert ($r.Code -eq 0) "+new-window --view=<file>.svg exits 0 (got $($r.Code))"
    $svgLeaf = Get-OnlyPane 't1183svg'
    $svgPane = if ($svgLeaf) { $svgLeaf.id } else { $null }
    $sserved = @(Wait-ImageServed $errlog $svgPane)
    Assert ($sserved.Count -ge 1 -and $sserved[0].Mime -eq 'image/svg+xml') `
        "E: an .svg is a picture, served as image/svg+xml (got '$(if ($sserved.Count) { $sserved[0].Mime } else { '-' })')"
    $sst = Wait-Loaded $errlog $svgPane
    Assert ($sst -and $sst.Kind -eq 'vector') `
        "E: ...and is measured as vector art, where 100% is its own size (kind=$(if ($sst) { $sst.Kind } else { '-' }))"
    if ($sst) {
        Assert (Near $sst.Scale $sst.Zoom) 'E: a vector''s scale is its zoom - no device-pixel term'
    }

    # --- F. +list --json reports it like any other viewer --------------------
    $leaf = Get-OnlyPane 't1183big'
    Assert ($leaf -and $leaf.type -eq 'viewer') "F: +list --json calls the pane a viewer (got '$($leaf.type)')"
    Assert ($leaf -and $leaf.url -eq $bigPath) `
        "F: ...and reports the file's own path (got '$($leaf.url)')"

    # --- G. +reload re-fetches the bytes -------------------------------------
    $before = @(Get-ImageServed $errlog $bigPane).Count
    $r = Invoke-Verb @('+reload', "--target=$bigPane")
    Assert ($r.Code -eq 0) "+reload against an image pane exits 0 (got $($r.Code))"
    $after = @(Wait-ImageServed $errlog $bigPane -AtLeast ($before + 1)).Count
    Assert ($after -gt $before) `
        "G: +reload re-fetched the picture (served $before time(s), then $after)"
    $revs = @(Get-ImageServed $errlog $bigPane | ForEach-Object { $_.Rev })
    Assert ($revs.Count -ge 2 -and $revs[-1] -gt $revs[0]) `
        'G: ...under a new revision, which is what makes the browser go back to disk'

    # --- H. an undecodable picture gets the pane's own card ------------------
    $r = Invoke-Verb @('+new-window', '--target=t1183bad', "--view=$corruptPath")
    Assert ($r.Code -eq 0) "+new-window --view=<corrupt>.png exits 0 (got $($r.Code))"
    Assert ($null -ne (Wait-Win 't1183bad')) 'the corrupt-image window exists'
    $carded = $false
    for ($t = 0; $t -lt 60; $t++) {
        $txt = (Get-Content $errlog -ErrorAction SilentlyContinue | Out-String)
        if ($txt -match ('viewer file error: Cannot display this image \(' + [regex]::Escape($corruptPath) + '\)')) {
            $carded = $true; break
        }
        Start-Sleep -Milliseconds 250
    }
    Assert $carded 'H: the error card names the picture that could not be displayed'

    # --- I. the control: a text file is still text ---------------------------
    $r = Invoke-Verb @('+new-window', '--target=t1183txt', "--view=$txtPath")
    Assert ($r.Code -eq 0) "+new-window --view=<file>.txt exits 0 (got $($r.Code))"
    Assert ($null -ne (Wait-Win 't1183txt')) 'the control window exists'
    $txtLeaf = Get-OnlyPane 't1183txt'
    $txtPane = if ($txtLeaf) { $txtLeaf.id } else { $null }
    Start-Sleep -Seconds 2
    Assert (@(Get-ImageServed $errlog $txtPane).Count -eq 0) `
        'I: a .txt pane never fetched a picture'
    Assert (@(Get-ImageStates $errlog $txtPane).Count -eq 0) `
        'I: ...and never decided an image zoom'

    # --- L. what Chromium cannot draw, the pane decodes itself (T1234) -------
    # Mac shows a TIFF, an .icns and an iPhone HEIC through ImageIO. A WebView2
    # page has no decoder for any of them, so the pane hands it pixels instead.
    $r = Invoke-Verb @('+new-window', '--target=t1234tif', "--view=$tiffPath")
    Assert ($r.Code -eq 0) "+new-window --view=<file>.tiff exits 0 (got $($r.Code))"
    $tifLeaf = Get-OnlyPane 't1234tif'
    $tifPane = if ($tifLeaf) { $tifLeaf.id } else { $null }
    $tserved = @(Wait-ImageServed $errlog $tifPane)
    Assert ($tserved.Count -ge 1 -and $tserved[0].Route -eq 'wic' -and $tserved[0].Mime -eq 'image/bmp') `
        "L1: a .tiff is decoded on the host and served as pixels (got route='$(if ($tserved.Count) { $tserved[0].Route } else { '-' })' mime='$(if ($tserved.Count) { $tserved[0].Mime } else { '-' })')"
    $tst = Wait-Loaded $errlog $tifPane
    Assert ($tst -and $tst.NatW -eq 640 -and $tst.NatH -eq 480) `
        "L1: ...and the page DREW it, at its real 640x480 (page reports $(if ($tst) { "$($tst.NatW)x$($tst.NatH)" } else { 'nothing - no picture' }))"

    $r = Invoke-Verb @('+new-window', '--target=t1234icns', "--view=$icnsPath")
    Assert ($r.Code -eq 0) "+new-window --view=<file>.icns exits 0 (got $($r.Code))"
    $icnsLeaf = Get-OnlyPane 't1234icns'
    $icnsPane = if ($icnsLeaf) { $icnsLeaf.id } else { $null }
    $cserved = @(Wait-ImageServed $errlog $icnsPane)
    Assert ($cserved.Count -ge 1 -and $cserved[0].Route -eq 'icns' -and $cserved[0].Mime -eq 'image/png') `
        "L2: an .icns is served as its embedded PNG (got route='$(if ($cserved.Count) { $cserved[0].Route } else { '-' })' mime='$(if ($cserved.Count) { $cserved[0].Mime } else { '-' })')"
    $cst = Wait-Loaded $errlog $icnsPane
    Assert ($cst -and $cst.NatW -eq 128 -and $cst.NatH -eq 128) `
        "L2: ...the LARGEST one, 128x128, drawn by the page (page reports $(if ($cst) { "$($cst.NatW)x$($cst.NatH)" } else { 'nothing - no picture' }))"

    $r = Invoke-Verb @('+new-window', '--target=t1234heic', "--view=$heicPath")
    Assert ($r.Code -eq 0) "+new-window --view=<file>.heic exits 0 (got $($r.Code))"
    $wantTitle = if ($heifInstalled) { 'Cannot display this image' } else { 'Windows needs the HEIF Image Extensions to show this image' }
    $heicCard = $null
    for ($t = 0; $t -lt 60 -and -not $heicCard; $t++) {
        $m = Select-String -Path $errlog -Pattern ('viewer file error: (.+) \(' + [regex]::Escape($heicPath) + '\)') |
            Select-Object -Last 1
        if ($m) { $heicCard = $m.Matches[0].Groups[1].Value } else { Start-Sleep -Milliseconds 250 }
    }
    Assert ($heicCard -eq $wantTitle) `
        "L3: an undecodable .heic gets the card for THIS box (HEIF extension installed=$heifInstalled): want '$wantTitle', got '$heicCard'"

    # --- K. ctrl+C at an image pane copies the PICTURE (T1872) ---------------
    # Mac's image pane answers Cmd-C with the image itself; before T1872 the
    # Windows page had nothing selected and copied nothing. Each press is
    # preceded by a SENTINEL text on the clipboard, so a pass cannot come from
    # an earlier copy, and the user's own clipboard is put back afterwards
    # (the test desktop shares the window station's clipboard with them).
    #
    # Two oracles, because either alone can lie: the pane's own log line says
    # the copy RAN and what it chose, and the clipboard read back says it
    # LANDED - through .NET's reader, which takes CF_DIB, so it also proves the
    # system synthesised a DIB from the CF_DIBV5 the pane wrote.
    if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
        $script:skipped++
        Write-Host 'SKIP  K: the clipboard API needs an STA thread and this host is MTA'
    } else {
        Add-Type -AssemblyName System.Windows.Forms
        $savedText = $null; $savedImg = $null
        try {
            if ([Windows.Forms.Clipboard]::ContainsText()) { $savedText = [Windows.Forms.Clipboard]::GetText() }
            elseif ([Windows.Forms.Clipboard]::ContainsImage()) { $savedImg = [Windows.Forms.Clipboard]::GetImage() }
        } catch { }

        function Set-Sentinel([string]$s) {
            for ($t = 0; $t -lt 10; $t++) {
                try { [Windows.Forms.Clipboard]::SetText($s); return } catch { Start-Sleep -Milliseconds 100 }
            }
        }
        function Get-ClipShape {
            for ($t = 0; $t -lt 10; $t++) {
                try {
                    $o = [Windows.Forms.Clipboard]::GetDataObject()
                    $img = [Windows.Forms.Clipboard]::GetImage()
                    $txt = if ([Windows.Forms.Clipboard]::ContainsText()) { [Windows.Forms.Clipboard]::GetText() } else { '' }
                    $shape = [pscustomobject]@{
                        W       = if ($img) { $img.Width } else { 0 }
                        H       = if ($img) { $img.Height } else { 0 }
                        HasPng  = ($o -and (@($o.GetFormats()) -contains 'PNG'))
                        Text    = $txt
                    }
                    if ($img) { $img.Dispose() }
                    return $shape
                } catch { Start-Sleep -Milliseconds 100 }
            }
            return [pscustomobject]@{ W = 0; H = 0; HasPng = $false; Text = '' }
        }
        function Get-CopyLines($paneId) {
            if (-not $paneId -or -not (Test-Path $errlog)) { return @() }
            return @(Select-String -Path $errlog -Pattern ('viewer image copy pane=' + [regex]::Escape($paneId) + ' ') |
                ForEach-Object { $_.Line })
        }
        function Send-Copy($v, [string]$key = 'C') {
            Focus-TestWindow -Window $v.Top -Child $v.Host | Out-Null
            Start-Sleep -Milliseconds 400
            Send-TestViewerChord -Window $v.Top -Target $v.Chrome -Key $key -Modifiers ctrl | Out-Null
        }
        function Wait-CopyLine($paneId, [int]$AtLeast = 1) {
            for ($t = 0; $t -lt 40; $t++) {
                $l = @(Get-CopyLines $paneId)
                if ($l.Count -ge $AtLeast) { return $l[-1] }
                Start-Sleep -Milliseconds 250
            }
            return $null
        }

        try {
            # K1. a PNG: the picture lands, and the "PNG" format is the file itself.
            $kp = Open-ViewerTop 't1872png' $bigPath
            Assert ($kp.Code -eq 0 -and $kp.Chrome -ne [IntPtr]::Zero) 'K: the PNG pane opened in its own window with a Chromium child'
            [void](Wait-Loaded $errlog $kp.Pane)
            Set-Sentinel 't1872-sentinel-1'
            Send-Copy $kp
            $line = Wait-CopyLine $kp.Pane
            $pngLen = (Get-Item $bigPath).Length
            Assert ($line -match 'ok=true size=4000x3000 png=verbatim png_bytes=(\d+)' -and [int64]$Matches[1] -eq $pngLen) `
                "K1: ctrl+C copied the 4000x3000 PNG, publishing the file's own $pngLen bytes as PNG (log: '$line')"
            $clip = Get-ClipShape
            Assert ($clip.W -eq 4000 -and $clip.H -eq 3000) `
                "K1: the clipboard now holds a 4000x3000 picture (read back $($clip.W)x$($clip.H))"
            Assert $clip.HasPng 'K1: ...with a PNG format alongside the bitmap'
            Assert ($clip.Text -ne 't1872-sentinel-1') 'K1: ...and the sentinel text is gone'

            # K2. a JPEG: opaque and not a PNG, so the bitmap alone.
            $kj = Open-ViewerTop 't1872jpg' $jpgPath
            [void](Wait-Loaded $errlog $kj.Pane)
            Set-Sentinel 't1872-sentinel-2'
            Send-Copy $kj
            $line = Wait-CopyLine $kj.Pane
            Assert ($line -match 'ok=true size=800x400 png=none') "K2: ctrl+C copied the 800x400 JPEG as a bitmap (log: '$line')"
            $clip = Get-ClipShape
            Assert ($clip.W -eq 800 -and $clip.H -eq 400) "K2: the clipboard holds an 800x400 picture (read back $($clip.W)x$($clip.H))"
            Assert (-not $clip.HasPng) 'K2: ...and no PNG re-encode of an opaque photo'

            # K3. ctrl+Insert is the same copy.
            Set-Sentinel 't1872-sentinel-3'
            Send-Copy $kj 'Insert'
            $line = Wait-CopyLine $kj.Pane 2
            Assert ($null -ne $line) 'K3: ctrl+Insert at an image pane copies too'

            # K5. a phone photo (T1910): the pane shows it upright, so the copy
            # is upright too - 400x800, not the 800x400 it is stored as.
            $kr = Open-ViewerTop 't1910phone' $phonePath
            $loaded = Wait-Loaded $errlog $kr.Pane
            Assert ($loaded -and $loaded.NatW -eq 400 -and $loaded.NatH -eq 800) `
                "K5: the pane shows the phone photo upright, 400x800 (page reports $($loaded.NatW)x$($loaded.NatH))"
            Set-Sentinel 't1910-sentinel-5'
            Send-Copy $kr
            $line = Wait-CopyLine $kr.Pane
            Assert ($line -match 'ok=true size=400x800 ') "K5: ctrl+C copied it upright, 400x800 (log: '$line')"
            $clip = Get-ClipShape
            Assert ($clip.W -eq 400 -and $clip.H -eq 800) "K5: the clipboard holds a 400x800 picture (read back $($clip.W)x$($clip.H))"

            # K4. the control: a TEXT pane keeps the page's own copy. Select all,
            # copy, and the file's text lands - with no image copy logged.
            $kt = Open-ViewerTop 't1872txt' $txtPath
            Start-Sleep -Seconds 2
            Set-Sentinel 't1872-sentinel-4'
            Focus-TestWindow -Window $kt.Top -Child $kt.Host | Out-Null
            Start-Sleep -Milliseconds 400
            Send-TestViewerChord -Window $kt.Top -Target $kt.Chrome -Key 'A' -Modifiers ctrl | Out-Null
            Start-Sleep -Milliseconds 400
            Send-TestViewerChord -Window $kt.Top -Target $kt.Chrome -Key 'C' -Modifiers ctrl | Out-Null
            $got = ''
            for ($t = 0; $t -lt 20; $t++) {
                $got = (Get-ClipShape).Text
                if ($got -match 'T1183 control') { break }
                Start-Sleep -Milliseconds 250
            }
            Assert ($got -match 'T1183 control') "K4: ctrl+C in a text pane is still the page's own copy (clipboard: '$got')"
            Assert (@(Get-CopyLines $kt.Pane).Count -eq 0) 'K4: ...and the image copy never ran there'
        } finally {
            try {
                if ($null -ne $savedText) { [Windows.Forms.Clipboard]::SetText($savedText) }
                elseif ($null -ne $savedImg) { [Windows.Forms.Clipboard]::SetImage($savedImg) }
                else { [Windows.Forms.Clipboard]::Clear() }
            } catch { }
        }
    }

    # --- L. the GESTURES, delivered into the page (T1233) --------------------
    # SendInput is dead on this desktop (T233), but the DevTools protocol's
    # Input.dispatchMouseEvent is delivered by the browser into the renderer's
    # own input pipeline: hit-testing, the click counter that turns two clicks
    # into a `dblclick`, and a `wheel` carrying ctrlKey all happen there, and
    # the page's listeners cannot tell it from a mouse. So this drives
    # everything from the listener on - image.js's handler, the anchor, the
    # message to native, `applyImageMessage`, and the scale pushed back - and
    # reads the pane's own `event=` line plus the page's geometry back.
    $gw = Open-ViewerTop 't1233gest' $gesturePath
    $gPane = $gw.Pane
    Assert ($gw.Code -eq 0 -and $gPane) 'L: the gesture pane opened'
    $g0 = Wait-Loaded $errlog $gPane
    Assert ($null -ne $g0 -and $g0.Fitting) 'L: ...fitted, which is where a double-click starts from'

    $gc = $null
    try {
        # The page whose picture is gesture.png. Every pane is a target on the
        # one port, so the probe keys on the <img> rather than on a URL.
        $probe = "(function(){var i=document.querySelector('img.viewer-image');" +
            "return !!i && i.alt==='gesture.png';})()"
        $deadline = (Get-Date).AddSeconds(15)
        while (-not $gc -and (Get-Date) -lt $deadline) {
            foreach ($t in @(Get-CdpTargets -Port $cdpPort)) {
                $c = $null
                try {
                    $c = Connect-Cdp -WebSocketUrl $t.webSocketDebuggerUrl
                    if ((Invoke-CdpEval $c $probe) -eq $true) { $gc = $c; break }
                } catch {}
                Close-Cdp $c
            }
            if (-not $gc) { Start-Sleep -Milliseconds 250 }
        }
        Assert ($null -ne $gc) "L: the gesture pane's page answered on the DevTools port ($cdpPort)"
        if (-not $gc) { throw 'no DevTools session on the gesture pane' }

        # Where the picture sits, in the stage's frame (which is the client
        # frame: the stage is fixed to the page's edges).
        $geoJs = "(function(){var s=document.querySelector('.viewer-image-stage');" +
            "var i=document.querySelector('img.viewer-image');var b=s.getBoundingClientRect();" +
            "var r=i.getBoundingClientRect();return JSON.stringify({sx:b.left,sy:b.top," +
            "vw:s.clientWidth,vh:s.clientHeight,sl:s.scrollLeft,st:s.scrollTop," +
            "il:r.left,it:r.top,iw:r.width,ih:r.height});})()"
        function Get-GestureGeo { return ([string](Invoke-CdpEval $gc $geoJs) | ConvertFrom-Json) }
        # The fraction of the picture under a client point - what a zoom
        # anchored at that point must leave under it.
        function Get-Under($geo, [double]$x, [double]$y) {
            return [pscustomobject]@{ U = ($x - $geo.il) / $geo.iw; V = ($y - $geo.it) / $geo.ih }
        }
        function Get-EventCount([string]$ev) {
            return @(Get-ImageStates $errlog $gPane | Where-Object { $_.Event -eq $ev }).Count
        }
        # The next `$ev` decision after `$before` of them, once the page has
        # also APPLIED it (the <img> box is natural * scale) - or $null.
        function Wait-Gesture([string]$ev, [int]$before) {
            for ($t = 0; $t -lt 40; $t++) {
                $hit = @(Get-ImageStates $errlog $gPane | Where-Object { $_.Event -eq $ev })
                if ($hit.Count -gt $before) {
                    $d = $hit[-1]
                    $geo = Get-GestureGeo
                    if ([Math]::Abs($geo.iw - $d.NatW * $d.Scale) -le 1) {
                        return [pscustomobject]@{ State = $d; Geo = $geo }
                    }
                }
                Start-Sleep -Milliseconds 125
            }
            return $null
        }
        function Send-Mouse([string]$type, [double]$x, [double]$y, [int]$clicks) {
            [void](Invoke-Cdp $gc 'Input.dispatchMouseEvent' @{
                type = $type; x = $x; y = $y; button = 'left'; buttons = 1; clickCount = $clicks })
        }
        function Send-DoubleClick([double]$x, [double]$y) {
            [void](Invoke-Cdp $gc 'Input.dispatchMouseEvent' @{ type = 'mouseMoved'; x = $x; y = $y })
            Send-Mouse 'mousePressed' $x $y 1; Send-Mouse 'mouseReleased' $x $y 1
            Send-Mouse 'mousePressed' $x $y 2; Send-Mouse 'mouseReleased' $x $y 2
        }
        function Send-Wheel([double]$x, [double]$y, [double]$dy, [switch]$Ctrl) {
            [void](Invoke-Cdp $gc 'Input.dispatchMouseEvent' @{
                type = 'mouseWheel'; x = $x; y = $y; deltaX = 0; deltaY = $dy
                modifiers = $(if ($Ctrl) { 2 } else { 0 }) })
        }
        # One image pixel of slack, as a fraction of the picture.
        $slackU = 1.5 / 4000; $slackV = 1.5 / 3000

        # L1. double-click a point off-centre: fit -> 100%, anchored there.
        $geo = Get-GestureGeo
        $px = $geo.sx + $geo.vw * 0.3; $py = $geo.sy + $geo.vh * 0.35
        $under = Get-Under $geo $px $py
        $n = Get-EventCount 'toggle'
        Send-DoubleClick $px $py
        $r1 = Wait-Gesture 'toggle' $n
        Assert ($null -ne $r1) 'L1: a double-click reached the pane as event=toggle, and the page applied it'
        if ($r1) {
            Assert ((Near $r1.State.Zoom 1) -and -not $r1.State.Fitting) `
                "L1: ...toggling a fitted picture to 100% (zoom=$($r1.State.Zoom) fitting=$($r1.State.Fitting))"
            $after = Get-Under $r1.Geo $px $py
            Assert ([Math]::Abs($after.U - $under.U) -le $slackU -and [Math]::Abs($after.V - $under.V) -le $slackV) `
                ("L1: ...and the pixel under the pointer stayed under it " +
                 "(before $([Math]::Round($under.U,4)),$([Math]::Round($under.V,4)) after $([Math]::Round($after.U,4)),$([Math]::Round($after.V,4)))")
        }

        # L2. one ctrl+wheel notch toward the user: zoom in, anchored.
        $geo = Get-GestureGeo
        $px = $geo.sx + $geo.vw * 0.6; $py = $geo.sy + $geo.vh * 0.4
        $under = Get-Under $geo $px $py
        $prevZoom = if ($r1) { $r1.State.Zoom } else { 1 }
        $n = Get-EventCount 'zoom_in'
        Send-Wheel $px $py -120 -Ctrl
        $r2 = Wait-Gesture 'zoom_in' $n
        Assert ($null -ne $r2) 'L2: a ctrl+wheel notch reached the pane as event=zoom_in, and the page applied it'
        if ($r2) {
            Assert ($r2.State.Zoom -gt $prevZoom) "L2: ...zooming in ($prevZoom -> $($r2.State.Zoom))"
            $after = Get-Under $r2.Geo $px $py
            Assert ([Math]::Abs($after.U - $under.U) -le $slackU -and [Math]::Abs($after.V - $under.V) -le $slackV) `
                ("L2: ...and the pixel under the pointer stayed under it " +
                 "(before $([Math]::Round($under.U,4)),$([Math]::Round($under.V,4)) after $([Math]::Round($after.U,4)),$([Math]::Round($after.V,4)))")
            $prevZoom = $r2.State.Zoom
        }

        # L3. the controls: a PLAIN wheel pans and decides no zoom, and a
        # ctrl+wheel nudge below one step's travel decides none either. These
        # are what make L1/L2 evidence: the oracle can see a gesture NOT zoom.
        $before = @(Get-ImageStates $errlog $gPane).Count
        $geo = Get-GestureGeo
        Send-Wheel $px $py 120
        Send-Wheel $px $py -10 -Ctrl
        Start-Sleep -Milliseconds 1500
        $geo2 = Get-GestureGeo
        Assert (@(Get-ImageStates $errlog $gPane).Count -eq $before) `
            'L3: a plain wheel and a sub-step ctrl+wheel decide no zoom'
        Assert ($geo2.st -gt $geo.st) "L3: ...and the plain wheel panned the picture (scrollTop $($geo.st) -> $($geo2.st))"

        # L4. a notch away from the user zooms back out (the -10 above is
        # still banked, so this proves the bank does not swallow a real step).
        $n = Get-EventCount 'zoom_out'
        Send-Wheel $px $py 120 -Ctrl
        $r4 = Wait-Gesture 'zoom_out' $n
        Assert ($null -ne $r4 -and $r4.State.Zoom -lt $prevZoom) `
            "L4: a ctrl+wheel notch away zooms out ($prevZoom -> $(if ($r4) { $r4.State.Zoom } else { '-' }))"

        # L5. the keyboard chords take the same road (imageZoomChord ->
        # window.__viewer.imageZoom -> report): ctrl+= in, ctrl+0 back to 100%.
        Focus-TestWindow -Window $gw.Top -Child $gw.Host | Out-Null
        Start-Sleep -Milliseconds 400
        $n = Get-EventCount 'zoom_in'
        Send-TestViewerChord -Window $gw.Top -Target $gw.Chrome -Key 'bb' -Modifiers ctrl | Out-Null
        $r5 = Wait-Gesture 'zoom_in' $n
        Assert ($null -ne $r5) 'L5: ctrl+= at an image pane zooms the PICTURE (event=zoom_in)'
        $n = Get-EventCount 'reset'
        Send-TestViewerChord -Window $gw.Top -Target $gw.Chrome -Key '0' -Modifiers ctrl | Out-Null
        $r6 = Wait-Gesture 'reset' $n
        Assert ($r6 -and (Near $r6.State.Zoom 1)) `
            "L5: ctrl+0 resets the picture to 100% (zoom=$(if ($r6) { $r6.State.Zoom } else { '-' }))"

        # L6. a second double-click goes back to best-fit.
        $geo = Get-GestureGeo
        $n = Get-EventCount 'toggle'
        Send-DoubleClick ($geo.sx + $geo.vw / 2) ($geo.sy + $geo.vh / 2)
        $r7 = Wait-Gesture 'toggle' $n
        Assert ($r7 -and $r7.State.Fitting -and (Near $r7.State.Zoom $r7.State.Fit)) `
            "L6: a second double-click returns to best-fit (zoom=$(if ($r7) { $r7.State.Zoom } else { '-' }))"

        # L7. and the toggle still toggles after the round trip: a best-fit
        # measured while the zoomed picture had scrollbars up is a fit the
        # pane no longer has, and a third double-click would only nudge it.
        $n = Get-EventCount 'toggle'
        Send-DoubleClick ($geo.sx + $geo.vw / 2) ($geo.sy + $geo.vh / 2)
        $r8 = Wait-Gesture 'toggle' $n
        Assert ($r8 -and (Near $r8.State.Zoom 1) -and -not $r8.State.Fitting) `
            "L7: a third double-click goes to 100% again (zoom=$(if ($r8) { $r8.State.Zoom } else { '-' }))"
        Assert ($r1 -and $r7 -and (Near $r7.State.Fit $g0.Fit)) `
            "L7: ...and best-fit is the same number at load and after a zoom (load $($g0.Fit), after $(if ($r7) { $r7.State.Fit } else { '-' }))"
    } finally {
        Close-Cdp $gc
    }

    # --- J. the app survived all of it ---------------------------------------
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'GUI process alive after all scenarios'
    Assert (-not (Test-TestDesktopLeak -ProcessId $appPid)) 'GUI never became visible on the interactive desktop'
} catch {
    # T1511: the foreground-leak check below is part of this run too, so this
    # try cannot END in `Complete-TestBody`. It SCORES its own throw instead -
    # the other half of the same rule: an unwind here can no longer reach a
    # green verdict.
    $script:fail++
    Write-Host "FAIL  the run terminated: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "      at $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())"
} finally {
    Remove-TestDesktop
    Stop-RepoInstances
    Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
}

$fgSeen = @(Stop-TestForegroundWatch)
$leaked = @(Get-TestLaunchedPids | Where-Object { $fgSeen -contains $_ })
Assert ($leaked.Count -eq 0) "no test-desktop app ever became foreground on the interactive desktop (saw $($leaked -join ','))"

Complete-TestBody  # T1039: the last statement of the body an unwind can skip

# A green run stamps the covered files (T783) so guard-due can answer "has this
# harness been run against the code as it now stands?". Red leaves the stamp
# alone: red stays due. A negative-control run is red by construction, so it
# never stamps.
if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard viewer-image -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Skipped $script:skipped
