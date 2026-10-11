# T1831 acceptance: the elevated pane style (Mac `macos-pane-style`, main
# 91ba7c08c / fe3f7c8da) - every pane is a raised rounded card on the "ocean"
# desk, with ONE spacing (10 DIP) for the window margin and the pane gap, and
# the gap is still the divider.
#
# What is asserted, and how:
#
#   GEOMETRY. The pane child sits margin + rim-inset inside the content area's
#   right and bottom edges (the left edge belongs to the pane sidebar's column
#   and the top to the chrome, so those two are not where the margin is
#   measured), and two panes split down are gap + 2 x rim-inset apart.
#
#   THE DESK. A PrintWindow of the top-level window (the parent's own paint;
#   the OpenGL panes come back as a flat fill) reads the right margin and the
#   middle of the gap as the ocean desk on this dark theme: a dark blue-teal,
#   blue above red, never the black terminal and never a divider gray.
#
#   THE CARD SHAPE. The window manager says which points of the pane's child
#   window it paints through (`Get-TestWindowRegionHits`): the square corner is
#   cut away, the centre is not. Flat panes have no region at all.
#
#   THE DIVIDER. A posted drag that starts in the middle of the gap moves the
#   split - the gap is the grab band, edge to edge.
#
#   FLAT. `--macos-pane-style=flat` is the classic geometry byte for byte: no
#   margin, the 2 DIP band, no region.
#
#   LIVE RELOAD. A config file flipped from flat to elevated and reloaded
#   (ctrl+shift+,) re-lays the open window out as cards, as on Mac.
#
# Runs on a background desktop (test/win32/lib/TestDesktop.ps1): nothing here
# takes the user's foreground, which is asserted at the end.
#
# -NegativeControl inverts the elevated-margin assertion and MUST fail.
#
#   powershell -NoProfile -File test\win32\pane-elevation.ps1
param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }

$env:GHOZTTY_PIPE_SUFFIX = "-elevtest$PID"
$conf = Join-Path $env:TEMP "ghoztty-pane-elevation-$PID.conf"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:pass = 0
$script:fail = 0
$script:skipped = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Kill-RepoInstances {
    [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
}

function Get-Panes([IntPtr]$top) {
    @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal' | Where-Object Visible)
}

# Zig's @round is half-away-from-zero; .NET's default is banker's.
function Round-Away([double]$v) { [int][math]::Round($v, [MidpointRounding]::AwayFromZero) }

# pane_elevation.zig mirrored: the margin/gap, and the rim inset.
function Get-MarginPx([double]$scale) { [math]::Max((Round-Away (10.0 * $scale)), 1) }
function Get-InsetPx([double]$scale) { [math]::Max([int][math]::Ceiling(0.5 * $scale), 1) }
# split_geometry.bandPx: the flat band.
function Get-BandPx([double]$scale) { [math]::Max((Round-Away (2.0 * $scale)), 2) }

# The ocean desk on a dark theme: dark, blue above red, and neither the black
# terminal nor a neutral divider gray.
function Test-DeskPixel($c) {
    if ($null -eq $c) { return $false }
    $sum = $c.R + $c.G + $c.B
    return ($c.B -gt $c.R + 12) -and ($sum -gt 45) -and ($sum -lt 3 * 140)
}

function Start-Gui([string]$label, [string[]]$extraArgs, [switch]$Split) {
    Kill-RepoInstances
    # persistence: off - every caller passes $common (--session-persistence=false);
    # a restored layout would seed panes whose geometry this script did not make.
    $app = Start-OnTestDesktop -Exe $exe -Arguments $extraArgs
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host "SETUP FAIL ($label): GUI died at launch"; exit 1 }
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { Write-Host "SETUP FAIL ($label): top window not found"; exit 1 }
    Assert (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) "$label window is NOT enumerable on the interactive desktop"
    if ($Split) {
        & $exe +split --direction=down | Out-Null
        Start-Sleep -Milliseconds 900
    }
    $panes = @(Get-Panes $top)
    $want = if ($Split) { 2 } else { 1 }
    Assert ($panes.Count -eq $want) "$label setup: $want visible pane(s) (saw $($panes.Count))"
    if ($panes.Count -ne $want) { Stop-Process -Id $app.Pid -Force -ErrorAction SilentlyContinue; exit 1 }
    $scale = (Get-TestWindowDpi -Window $top) / 96.0
    [pscustomobject]@{ App = $app; Top = $top; Panes = $panes; Scale = $scale }
}

# The client rect in SCREEN coordinates (Get-TestChildWindows reports screen).
function Get-ClientScreen([IntPtr]$top) {
    Get-TestWindowRect -Window $top -Client
}

Kill-RepoInstances
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$launched = @()
$common = @('--config-default-files=false', '--background=#000000',
    '--unfocused-split-opacity=1', '--session-persistence=false')

try {

# ---------------------------------------------------------------------------
# Run 1: the default style is elevated.
# ---------------------------------------------------------------------------
$g = Start-Gui 'elevated' $common
$launched += $script:GhozttyTestDesktopPids
$top = $g.Top
$m = Get-MarginPx $g.Scale
$i = Get-InsetPx $g.Scale
$p = $g.Panes[0]
$cs = Get-ClientScreen $top
$rightGap = [int]($cs.Right - $p.Right)
$bottomGap = [int]($cs.Bottom - $p.Bottom)
Write-Host "      scale=$($g.Scale) margin=$m inset=$i pane=($($p.Left),$($p.Top),$($p.Right),$($p.Bottom)) right-gap=$rightGap bottom-gap=$bottomGap"
if ($NegativeControl) {
    Write-Host 'NEGATIVE CONTROL: asserting the pane runs to the window edge - this run MUST fail'
    Assert ($rightGap -eq 0) 'elevated: the pane runs edge to edge (negative control)'
} else {
    Assert ($rightGap -eq $m + $i) "elevated: the pane sits margin+rim ($($m + $i)px) inside the right edge"
}
Assert ($bottomGap -eq $m + $i) "elevated: the pane sits margin+rim ($($m + $i)px) inside the bottom edge"

# The card shape: the child window's square corners are cut away.
$pw = $p.Right - $p.Left; $ph = $p.Bottom - $p.Top
$hits = Get-TestWindowRegionHits -Window ([IntPtr]$p.Hwnd) -Points @(0, 0, ($pw - 1), ($ph - 1), [int]($pw / 2), [int]($ph / 2))
Assert ($null -ne $hits) 'elevated: the pane child has a window region (rounded card)'
if ($null -ne $hits) {
    Assert ((-not $hits[0]) -and (-not $hits[1])) 'elevated: the top-left and bottom-right corners are cut away'
    Assert $hits[2] 'elevated: the pane centre is inside the region'
}

# The desk: the right margin, halfway down the pane.
$shot = Get-TestWindowPixels -Window $top -Sync
try {
    $distinct = Get-TestDistinctColors -Shot $shot
    if ($distinct -lt 4) {
        $script:skipped++; Write-Host "SKIP  elevated desk probe: empty capture ($distinct colors)"
    } else {
        $mx = [int]($p.Right + [math]::Floor(($m + $i) / 2))
        $my = [int](($p.Top + $p.Bottom) / 2)
        $c = Get-TestPixel -Shot $shot -X $mx -Y $my
        Write-Host "      right-margin pixel ($mx,$my) = $($c.R),$($c.G),$($c.B)"
        Assert (Test-DeskPixel $c) 'elevated: the right margin is the ocean desk'
    }
} finally { Close-TestWindowPixels $shot }

# Split it: two cards, gap + 2 x rim apart, the gap is the desk and the divider.
& $exe +split --direction=down | Out-Null
Start-Sleep -Milliseconds 900
$panes = @(Get-Panes $top)
Assert ($panes.Count -eq 2) 'elevated: split down gives 2 visible panes'
if ($panes.Count -eq 2) {
    $A = $panes | Sort-Object Top | Select-Object -First 1
    $B = $panes | Sort-Object Top | Select-Object -Last 1
    $gap = [int]($B.Top - $A.Bottom)
    Write-Host "      pane gap = $gap (expected $($m + 2 * $i))"
    Assert ($gap -eq $m + 2 * $i) 'elevated: the panes are one spacing (+ both rims) apart'
    Assert ($A.Left -eq $B.Left -and $A.Right -eq $B.Right) 'elevated: both cards share their left and right edges'

    $shot = Get-TestWindowPixels -Window $top -Sync
    try {
        $gx = [int](($A.Left + $A.Right) / 2)
        $gy = [int](($A.Bottom + $B.Top) / 2)
        $c = Get-TestPixel -Shot $shot -X $gx -Y $gy
        Write-Host "      mid-gap pixel ($gx,$gy) = $($c.R),$($c.G),$($c.B)"
        if ((Get-TestDistinctColors -Shot $shot) -lt 4) {
            $script:skipped++; Write-Host 'SKIP  gap probe: empty capture'
        } else {
            Assert (Test-DeskPixel $c) 'elevated: the gap between the cards is the desk, not a divider line'
        }
    } finally { Close-TestWindowPixels $shot }

    # The gap is the grab band: a drag from its middle moves the split.
    $h0 = $A.Bottom - $A.Top
    $gx = [int](($A.Left + $A.Right) / 2)
    $gy = [int](($A.Bottom + $B.Top) / 2)
    [void](Send-TestMouse -Window $top -Target $top -X $gx -Y $gy -Action down)
    for ($k = 1; $k -le 8; $k++) {
        [void](Send-TestMouse -Window $top -Target $top -X $gx -Y ($gy + 8 * $k) -Action move)
    }
    [void](Send-TestMouse -Window $top -Target $top -X $gx -Y ($gy + 64) -Action up)
    Start-Sleep -Milliseconds 400
    $A2 = Get-Panes $top | Sort-Object Top | Select-Object -First 1
    $grew = ($A2.Bottom - $A2.Top) - $h0
    Write-Host "      drag from mid-gap: top pane grew $grew px (asked 64)"
    Assert ([math]::Abs($grew - 64) -le 6) 'elevated: a drag from the middle of the gap moves the divider'
}
Assert (-not ($g.App.Process -and $g.App.Process.HasExited)) 'elevated: no crash'
Stop-Process -Id $g.App.Pid -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# Run 2: flat is the classic geometry, unchanged.
# ---------------------------------------------------------------------------
$g = Start-Gui 'flat' ($common + '--macos-pane-style=flat') -Split
$launched += $script:GhozttyTestDesktopPids
$top = $g.Top
$A = $g.Panes | Sort-Object Top | Select-Object -First 1
$B = $g.Panes | Sort-Object Top | Select-Object -Last 1
$cs = Get-ClientScreen $top
$band = Get-BandPx $g.Scale
Assert ([int]($cs.Right - $A.Right) -eq 0) 'flat: the pane runs to the right edge'
Assert ([int]($B.Top - $A.Bottom) -eq $band) "flat: the panes are the classic ${band}px band apart"
$hits = Get-TestWindowRegionHits -Window ([IntPtr]$A.Hwnd) -Points @(0, 0)
Assert ($null -eq $hits) 'flat: the pane child has no window region'
Stop-Process -Id $g.App.Pid -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# Run 3: a live reload flips an open window from flat to elevated.
# ---------------------------------------------------------------------------
Set-Content -Path $conf -Value 'macos-pane-style = flat' -Encoding Ascii
$g = Start-Gui 'reload' ($common + "--config-file=$conf") -Split
$launched += $script:GhozttyTestDesktopPids
$top = $g.Top
$m = Get-MarginPx $g.Scale
$i = Get-InsetPx $g.Scale
$cs = Get-ClientScreen $top
$A = $g.Panes | Sort-Object Top | Select-Object -First 1
Assert ([int]($cs.Right - $A.Right) -eq 0) 'reload: flat before the reload'
Set-Content -Path $conf -Value 'macos-pane-style = elevated' -Encoding Ascii
Assert (Send-TestKeys -Window $top -Target ([IntPtr]$A.Hwnd) -Modifiers ctrl, shift -Key comma) 'reload: chord delivered'
$flipped = $false
for ($t = 0; $t -lt 25; $t++) {
    Start-Sleep -Milliseconds 200
    $A = Get-Panes $top | Sort-Object Top | Select-Object -First 1
    if ($A -and [int]($cs.Right - $A.Right) -eq $m + $i) { $flipped = $true; break }
}
Assert $flipped 'reload: the open window re-laid out as elevated cards'
Assert (-not ($g.App.Process -and $g.App.Process.HasExited)) 'reload: no crash'
Stop-Process -Id $g.App.Pid -Force -ErrorAction SilentlyContinue

} catch {
    $script:fail++
    Write-Host "FAIL  the run terminated: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "      at $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())"
} finally {
    Remove-TestDesktop
    Kill-RepoInstances
    Remove-Item $conf -ErrorAction SilentlyContinue
}

$fgSeen = @(Stop-TestForegroundWatch)
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @($launched | Select-Object -Unique)
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'no test-desktop app ever became foreground on the interactive desktop'
}

Complete-TestBody
if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard pane-elevation -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Skipped $script:skipped -Label 'PANE ELEVATION ACCEPTANCE'
