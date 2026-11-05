# T2703 acceptance: a pane dragged by its grab handle carries a small card of
# itself under the pointer - background, title strip, content - from the
# drag's first move, the way Mac does since 30d13ea14 (`PaneDragGhost`).
#
# THE GAP. Before T2703 nothing followed the pointer on Windows during a pane
# drag: only the drop highlight moved, so the user could not see what they
# were carrying once the pointer left the pane.
#
# ORACLE. The card is a real top-level window (`GhozttyPaneDragGhost`), so
# "is it up, where, how big" is a rect comparison against the pointer the
# script posted and the pane being carried. Its PIXELS are photographed with
# the synchronous PrintWindow (WM_PRINT): the window answers it from the very
# pixels it committed, because a layered window has no surface to read back
# on the background desktop. The pane's own picture arriving is read from the
# app's debug log (`content=true`), since the GL terminal surface itself
# cannot be photographed off the input desktop (TestDesktop.ps1, CAPTURE
# LIMIT) - the card's body is the place that picture is seen.
#
# Claims:
#   A) a grab-handle drag of a terminal shows the card from the first move:
#      horizontally centred on the pointer, the pointer inside its title
#      strip (so the card hangs BELOW the pointer), sized to the pane's shape
#      and never past 220x150 DIP (+10 DIP shadow margin all round)
#   B) the card follows the next move by exactly the pointer's travel
#   C) its pixels: the title strip is the background tinted toward the ink,
#      the body is the pane's background, the strip carries text, and the
#      image corner is empty (a rounded card with a shadow, not a rectangle)
#   D) the pane's picture arrives and the card is redrawn with it
#   E) the card is gone after the drop
#   F) a drag cancelled with Escape takes the card away too
#   G) a VIEWER pane's drag carries a card as well
#
# -NegativeControl inverts claim A to "no card appears" - the pre-T2703
# behaviour - and MUST fail.
#
# Runs on the BACKGROUND test desktop and never takes the user's foreground -
# asserted at the end. Only touches ghoztty processes running from this
# repo's zig-out*.
#
#   powershell -NoProfile -File test\win32\pane-drag-ghost.ps1
param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }
$env:GHOZTTY_PIPE_SUFFIX = "-pdg$PID"
$errlog = Join-Path $env:TEMP "ghoztty-pane-drag-ghost-stderr-$PID.log"

. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
Assert-GhozttyIsolatedBuild -Exe $exe | Out-Null
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Stop-RepoInstances {
    [void](Stop-RepoGhoztty -Exe $exe -SettleMs 800)
}

# The pane background the card must carry, and the strip it tints to (the
# ink on a dark card is white; the strip is 10% of the way to it).
$BG = @(0x20, 0x30, 0x40)
$STRIP = @(
    [int][math]::Round($BG[0] + (255 - $BG[0]) * 0.10),
    [int][math]::Round($BG[1] + (255 - $BG[1]) * 0.10),
    [int][math]::Round($BG[2] + (255 - $BG[2]) * 0.10))

function Get-PaneBoxes([IntPtr]$top) {
    $all = @(@(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal') +
        @(Get-TestChildWindows -Window $top -Class 'GhozttyViewer') |
        Where-Object Visible | ForEach-Object {
            [pscustomobject]@{
                Hwnd = [int64]$_.Hwnd
                Kind = $_.Class
                Left = $_.Left; Top = $_.Top
                Width = $_.Width; Height = $_.Height
            }
        })
    return , @($all | Sort-Object Top, Left)
}

function Get-Handle([int]$AppPid) {
    $w = @(Get-TestWindows -ProcessId $AppPid -Class 'GhozttyPaneGrabHandle' | Where-Object Visible)
    if ($w.Count -eq 0) { return $null }
    return $w[0]
}

function Get-Ghost([int]$AppPid) {
    $w = @(Get-TestWindows -ProcessId $AppPid -Class 'GhozttyPaneDragGhost' | Where-Object Visible)
    if ($w.Count -eq 0) { return $null }
    return $w[0]
}

function Test-Near([int]$a, [int]$b, [int]$tol = 2) {
    return ([math]::Abs($a - $b) -le $tol)
}

function Test-Rgb($c, [int[]]$want, [int]$tol = 8) {
    if (-not $c) { return $false }
    return (Test-Near $c.R $want[0] $tol) -and (Test-Near $c.G $want[1] $tol) -and (Test-Near $c.B $want[2] $tol)
}

# Zig's @round: halves away from zero (PowerShell's default is banker's,
# which reads 12.5 DIP of margin at 125% as 12 where the app draws 13).
function Round-Px([double]$v) { return [int][math]::Round($v, [MidpointRounding]::AwayFromZero) }
. (Join-Path $PSScriptRoot 'lib\ChromeGeometry.ps1')

# pane_drag_ghost.cardSize, restated: the pane's shape scaled to fit
# 220x150 DIP, never up, held to 120x72 DIP.
function Get-ExpectedCard([int]$pw, [int]$ph, [double]$scale) {
    $s = [math]::Min([math]::Min((220 * $scale) / $pw, (150 * $scale) / $ph), 1.0)
    $w = [math]::Max((Round-Px (120 * $scale)), (Round-Px ($pw * $s)))
    $h = [math]::Max((Round-Px (72 * $scale)), (Round-Px ($ph * $s)))
    return @($w, $h)
}

function Get-LogCount([string]$pattern) {
    if (-not (Test-Path $errlog)) { return 0 }
    return @(Select-String -Path $errlog -Pattern $pattern -ErrorAction SilentlyContinue).Count
}

function Wait-LogCount([string]$pattern, [int]$want, [int]$timeoutMs = 4000) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $timeoutMs) {
        if ((Get-LogCount $pattern) -ge $want) { return $true }
        Start-Sleep -Milliseconds 100
    }
    return ((Get-LogCount $pattern) -ge $want)
}

function Move-To($s, [IntPtr]$target, [int]$x, [int]$y) {
    $r = Send-TestMouse -Window $s.Top -Target $target -X $x -Y $y -Action move
    Start-Sleep -Milliseconds 300
    return $r
}

function Start-Session([int]$Splits, [string]$View) {
    $sp = @{
        Exe = $exe
        Arguments = @(
            '--config-default-files=false',
            '--macos-pane-style=flat',
            '--session-persistence=false',
            ('--background=#{0:x2}{1:x2}{2:x2}' -f $BG[0], $BG[1], $BG[2]))
        StdErr = $errlog
    }
    $app = Start-OnTestDesktop @sp
    $appPid = [int]$app.Pid
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) {
        Write-TestAssertedNothing -Reason 'GUI died at launch'
    }
    $top = Wait-TestWindow -ProcessId $appPid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) {
        Write-TestAssertedNothing -Reason 'top window not found'
    }
    Set-TestWindowSize -Window $top -Width 1400 -Height 900 | Out-Null
    Start-Sleep -Milliseconds 500
    for ($i = 0; $i -lt $Splits; $i++) {
        & $exe +split --direction=right | Out-Null
        Start-Sleep -Milliseconds 1000
    }
    if ($View) {
        & $exe +split --direction=right "--view=$View" | Out-Null
        Start-Sleep -Seconds 3
    }
    [pscustomobject]@{ App = $app; Pid = $appPid; Top = $top }
}

function Close-Session($s) {
    if ($s) {
        foreach ($r in $script:GhozttyTestDesktopLaunches) {
            if ($r.Pid -eq $s.Pid) { $r.Killed = $true }
        }
    }
    Stop-RepoInstances
}

# Press the grab handle of $pane and travel to ($x, $y): a live drag.
function Start-HandleDrag($s, $pane, [int]$x, [int]$y, [string]$label) {
    $dpi = Get-TestWindowDpi -Window $s.Top
    $scale = $dpi / 96.0
    [void](Move-To $s ([IntPtr]$pane.Hwnd) ($pane.Left + 100) ($pane.Top + (Get-TestChromeDip -Dip 10 -Scale $scale)))
    $h = Get-Handle $s.Pid
    if (-not $h) { Write-TestAssertedNothing -Reason "$label - no grab handle came up to press" }
    $hx = $h.Left + [int]($h.Width / 2)
    $hy = $h.Top + [int]($h.Height / 2)
    Assert (Send-TestMouse -Window $s.Top -Target ([IntPtr]$h.Hwnd) -X $hx -Y $hy -Action down) "${label}: press on the grab handle delivered"
    Assert (Send-TestMouse -Window $s.Top -Target $s.Top -X $x -Y $y -Action move) "${label}: first move past the threshold delivered"
    Start-Sleep -Milliseconds 300
}

Stop-RepoInstances
Remove-Item (Get-GhozttySessionLayoutPath -Root $env:LOCALAPPDATA) -Force -ErrorAction SilentlyContinue
Remove-Item $errlog -ErrorAction SilentlyContinue

$docDir = Join-Path $env:TEMP "ghoztty-pane-drag-ghost-$PID"
New-Item -ItemType Directory -Force -Path $docDir | Out-Null
$doc = Join-Path $docDir 'ghost.md'
Set-Content -Path $doc -Value "# ghost`n`nA viewer pane carried by its grab handle.`n" -Encoding utf8

Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$session = $null

try {
    if ($NegativeControl) {
        Write-Host 'NEGATIVE CONTROL: claim A is inverted to "no card appears" - this run MUST fail'
    }

    # ===================================================================
    # RUN 1 - two terminals side by side
    # ===================================================================
    $session = Start-Session -Splits 1
    $top = $session.Top
    $dpi = Get-TestWindowDpi -Window $top
    $scale = $dpi / 96.0
    $panes = Get-PaneBoxes $top
    if ($panes.Count -ne 2) { Write-TestAssertedNothing -Reason "the split never produced two panes (got $($panes.Count))" }
    $left = $panes[0]; $right = $panes[1]
    Write-Host ("      dpi={0} left pane {1}x{2}" -f $dpi, $left.Width, $left.Height)

    # Positive control: before any press there is no card - so a card later is
    # the drag's doing, not a window that was always there.
    Assert (-not (Get-Ghost $session.Pid)) 'control: no card before the drag'

    # --- A: the first move shows the card ----------------------------------
    $px = $left.Left + [int]($left.Width / 2)
    $py = $left.Top + [int]($left.Height / 2)
    Start-HandleDrag $session $left $px $py 'A'
    $g = Get-Ghost $session.Pid
    if ($g) { Write-Host ("      card window: x={0} y={1} w={2} h={3} (pointer {4},{5})" -f $g.Left, $g.Top, $g.Width, $g.Height, $px, $py) }
    $margin = Round-Px (10 * $scale)
    $title = Round-Px (18 * $scale)
    $exp = Get-ExpectedCard $left.Width $left.Height $scale
    if ($NegativeControl) {
        Assert (-not $g) 'NEGATIVE: no card follows the pointer (pre-T2703 behaviour)'
    } else {
        Assert ($null -ne $g) 'A: a card is up from the first move of the drag'
    }
    if ($g) {
        Assert (Test-Near ($g.Left + [int]($g.Width / 2)) $px) 'A: centred on the pointer horizontally'
        $stripTop = $g.Top + $margin
        Assert (($py -ge $stripTop) -and ($py -lt ($stripTop + $title))) 'A: the pointer holds the card by its title strip (the card hangs below it)'
        Assert ((Test-Near $g.Width ($exp[0] + 2 * $margin)) -and (Test-Near $g.Height ($exp[1] + 2 * $margin))) `
            ("A: sized to the pane's shape - card {0}x{1} expected {2}x{3}" -f ($g.Width - 2 * $margin), ($g.Height - 2 * $margin), $exp[0], $exp[1])
        Assert ((($g.Width - 2 * $margin) -le (Round-Px (220 * $scale))) -and (($g.Height - 2 * $margin) -le (Round-Px (150 * $scale)))) `
            'A: and never past 220x150 DIP'

        # --- B: it follows the pointer ------------------------------------
        $px2 = $px + 60; $py2 = $py + 40
        [void](Send-TestMouse -Window $top -Target $top -X $px2 -Y $py2 -Action move)
        Start-Sleep -Milliseconds 300
        $g2 = Get-Ghost $session.Pid
        Assert ($g2 -and (Test-Near ($g2.Left - $g.Left) 60 1) -and (Test-Near ($g2.Top - $g.Top) 40 1)) `
            ("B: the card moved with the pointer (dx={0} dy={1})" -f ($g2.Left - $g.Left), ($g2.Top - $g.Top))

        # --- D: the pane's picture arrives ---------------------------------
        Assert (Wait-LogCount 'pane drag ghost shown .* content=true' 1) 'D: the pane''s picture arrived and the card was redrawn with it'

        # --- C: the card's pixels ------------------------------------------
        $g3 = Get-Ghost $session.Pid
        $shot = Get-TestWindowPixels -Window ([IntPtr]$g3.Hwnd) -Sync -AllowUniform
        try {
            $cx = $g3.Left + [int]($g3.Width / 2)
            $stripC = Get-TestPixel -Shot $shot -X ($g3.Left + $margin + (Get-TestChromeDip -Dip 4 -Scale $scale)) -Y ($g3.Top + $margin + [int]($title / 2))
            Write-Host ("      strip pixel: {0}" -f $(if ($stripC) { "$($stripC.R),$($stripC.G),$($stripC.B)" } else { 'off' }))
            Assert (Test-Rgb $stripC $STRIP) ("C: the title strip is the background tinted toward the ink (want {0})" -f ($STRIP -join ','))
            # Text in the strip: more than two colours along its middle row.
            $seen = @{}
            for ($x = $g3.Left + $margin + 2; $x -lt $g3.Left + $g3.Width - $margin - 2; $x += 1) {
                $c = Get-TestPixel -Shot $shot -X $x -Y ($g3.Top + $margin + [int]($title / 2))
                if ($c) { $seen["$($c.R),$($c.G),$($c.B)"] = 1 }
            }
            Assert ($seen.Count -gt 2) "C: the title strip carries text ($($seen.Count) colours along it)"
            # The body's lower right: past any prompt, the terminal's own
            # background, which the card shows.
            $bodyC = Get-TestPixel -Shot $shot -X ($g3.Left + $g3.Width - $margin - (Get-TestChromeDip -Dip 12 -Scale $scale)) -Y ($g3.Top + $g3.Height - $margin - (Get-TestChromeDip -Dip 12 -Scale $scale))
            Write-Host ("      body pixel: {0}" -f $(if ($bodyC) { "$($bodyC.R),$($bodyC.G),$($bodyC.B)" } else { 'off' }))
            Assert (Test-Rgb $bodyC $BG) ("C: the body is the pane's background (want {0})" -f ($BG -join ','))
            $cornerC = Get-TestPixel -Shot $shot -X $g3.Left -Y $g3.Top
            Assert ($cornerC -and $cornerC.R -lt 8 -and $cornerC.G -lt 8 -and $cornerC.B -lt 8) 'C: the image corner is empty - a card with a margin, not a full rectangle'
            $cardCorner = Get-TestPixel -Shot $shot -X ($g3.Left + $margin) -Y ($g3.Top + $margin)
            Assert ($cardCorner -and -not (Test-Rgb $cardCorner $STRIP 3)) 'C: the card''s corner is rounded away'
        } finally { Close-TestWindowPixels -Shot $shot }
    }

    # --- E: the drop takes it away -------------------------------------
    $swapX = $right.Left + [int]($right.Width / 2)
    $swapY = $right.Top + [int]($right.Height / 2)
    [void](Send-TestMouse -Window $top -Target $top -X $swapX -Y $swapY -Action move)
    Start-Sleep -Milliseconds 300
    Assert (Send-TestMouse -Window $top -Target $top -X $swapX -Y $swapY -Action up) 'E: release delivered'
    Start-Sleep -Milliseconds 1200
    Assert (-not ($session.App.Process -and $session.App.Process.HasExited)) 'E: no crash on the drop'
    Assert (-not (Get-Ghost $session.Pid)) 'E: the card is gone after the drop'
    $after = Get-PaneBoxes $top
    Assert (($after.Count -eq 2) -and ($after[1].Hwnd -eq $left.Hwnd)) 'E: and the drop still moved the pane (the card changed nothing about it)'

    # --- F: Escape cancels, and takes it away ----------------------------
    $panes = Get-PaneBoxes $top
    $p0 = $panes[0]
    Start-HandleDrag $session $p0 ($p0.Left + [int]($p0.Width / 2)) ($p0.Top + [int]($p0.Height / 2)) 'F'
    $gF = Get-Ghost $session.Pid
    Assert ($null -ne $gF) 'F: the card is up for the second drag'
    $focused = [IntPtr](Get-TestFocusedWindow -Window $top)
    Assert (Send-TestKeys -Window $top -Target $focused -Key Escape) 'F: Escape delivered'
    Start-Sleep -Milliseconds 800
    Assert (-not (Get-Ghost $session.Pid)) 'F: a cancelled drag takes the card away'
    # Release the (now dead) button so the next run starts clean.
    [void](Send-TestMouse -Window $top -Target $top -X ($p0.Left + 50) -Y ($p0.Top + 50) -Action up)

    Close-Session $session
    $session = $null

    # ===================================================================
    # RUN 2 - a terminal and a VIEWER
    # ===================================================================
    $session = Start-Session -Splits 0 -View $doc
    $top = $session.Top
    $panes2 = Get-PaneBoxes $top
    $viewer = @($panes2 | Where-Object { $_.Kind -eq 'GhozttyViewer' })
    $term = @($panes2 | Where-Object { $_.Kind -eq 'GhozttyTerminal' })
    if ($viewer.Count -ne 1 -or $term.Count -ne 1) {
        Write-TestAssertedNothing -Reason "run 2 is not one terminal + one viewer (got $($term.Count) + $($viewer.Count))"
    }
    $viewer = $viewer[0]; $term = $term[0]
    $nav = @(Get-TestChildWindows -Window $top -Class 'GhozttyViewerNav' | Where-Object Visible)
    if ($nav.Count -eq 0) { Write-TestAssertedNothing -Reason 'the viewer has no nav bar to move over' }
    $nav = $nav[0]
    [void](Move-To $session ([IntPtr]$nav.Hwnd) ($nav.Left + 40) ($nav.Top + [int]($nav.Height / 2)))
    $h = Get-Handle $session.Pid
    if (-not $h) { Write-TestAssertedNothing -Reason 'the viewer showed no grab handle to press' }
    $hx = $h.Left + [int]($h.Width / 2)
    $hy = $h.Top + [int]($h.Height / 2)
    $tx = $term.Left + [int]($term.Width / 2)
    $ty = $term.Top + [int]($term.Height / 2)
    Assert (Send-TestMouse -Window $top -Target ([IntPtr]$h.Hwnd) -X $hx -Y $hy -Action down) 'G: press on the viewer''s grab handle delivered'
    Assert (Send-TestMouse -Window $top -Target $top -X $tx -Y $ty -Action move) 'G: drag onto the terminal delivered'
    Start-Sleep -Milliseconds 400
    $gV = Get-Ghost $session.Pid
    Assert ($null -ne $gV) 'G: a viewer pane''s drag carries a card too'
    if ($gV) { Assert (Test-Near ($gV.Left + [int]($gV.Width / 2)) $tx) 'G: centred on the pointer' }
    [void](Send-TestMouse -Window $top -Target $top -X $tx -Y $ty -Action up)
    Start-Sleep -Milliseconds 1000
    Assert (-not (Get-Ghost $session.Pid)) 'G: and it is gone after the drop'

    Complete-TestBody
} finally {
    if ($td) { Remove-TestDesktop -Desktop $td }
    Stop-RepoInstances
    Remove-Item -Recurse -Force $docDir -ErrorAction SilentlyContinue
}

$fgSeen = @(Stop-TestForegroundWatch)
Write-Host "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
$launched = @(Get-TestLaunchedPids)
$leaked = @($fgSeen | Where-Object { $launched -contains $_ })
Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
Assert ($leaked.Count -eq 0) 'no test-desktop app ever became foreground on the interactive desktop'

if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard pane-drag-ghost -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Label 'T2703 PANE DRAG GHOST' -Pass $script:pass -Fail $script:fail
