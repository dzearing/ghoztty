# T2705 acceptance: a drop target that would leave the dragged pane where it
# already is does not react - no preview, and a release there changes nothing -
# and the previews that DO show say what they do: a swap is the pane's center
# box with a swap glyph, a split is half the pane with one seam where the new
# divider runs.
#
# THE DEFECT. Mac (30d13ea14, `PaneMoveCoordinator.wouldLeaveInPlace`) makes
# each split, divider and window-edge move on a copy of the tree and compares
# layouts; a spot whose move changes nothing has no target. Windows treated only
# the dragged pane itself as a no-op, so in A | B, dragging A, B's left side, the
# divider and the window's left edge all lit up as if a release there would do
# something. Its swap preview washed the whole pane, and a split's half-pane fill
# did not say which axis was being cut.
#
# ORACLE. The rearrange-drag.ps1 pattern: the preview is a real top-level window
# (`GhozttyDropHighlight`), so "no preview" is "no visible window of that
# class", and its rect is compared with the pane it previews; the terminal panes
# are child HWNDs, so their order and widths after a release say whether
# anything moved. Seam and glyph are real pixels: a WM_PRINTCLIENT capture of
# the preview.
#
# Claims, one app run, two panes A | B side by side, dragging A by its header:
#   Q) quiet: over B's left side, over the A|B divider, and in the window's left
#      edge band there is no preview
#   S) control: over B's right side there IS a preview - B's right half - with
#      a seam down its left edge (the new divider) and none down its right
#   W) over B's center the preview is the center box, not the whole pane, with
#      glyph pixels inside it that are neither the fill nor the frame
#   R) a release on B's left side changes nothing: same panes, same order,
#      same widths
#
# -NegativeControl inverts the first claim Q to "B's left side IS previewed" -
# the pre-T2705 behavior - and MUST fail.
#
# Runs on the BACKGROUND test desktop. Only touches ghoztty processes running
# from this repo's zig-out*.
#
#   powershell -NoProfile -File test\win32\rearrange-noop-drop.ps1
param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }
$env:GHOZTTY_PIPE_SUFFIX = "-rnoop$PID"
$errlog = Join-Path $env:TEMP 'ghoztty-rearrange-noop-stderr.log'

. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
Assert-GhozttyIsolatedBuild -Exe $exe | Out-Null
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\ChromeGeometry.ps1')

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Stop-RepoInstances {
    [void](Stop-RepoGhoztty -Exe $exe -SettleMs 800)
}

# Every terminal leaf of the top window in SCREEN coordinates, left to right.
# Unary comma on the return: a one-element result would otherwise unroll.
function Get-PaneBoxes([IntPtr]$top) {
    $all = @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal' |
        Where-Object Visible | ForEach-Object {
            [pscustomobject]@{
                Hwnd = [int64]$_.Hwnd
                Left = $_.Left; Top = $_.Top
                Width = $_.Width; Height = $_.Height
                Right = $_.Left + $_.Width; Bottom = $_.Top + $_.Height
            }
        })
    return , @($all | Sort-Object Left, Top)
}

function Show-Boxes([string]$label, $boxes) {
    foreach ($b in $boxes) {
        Write-Host ("      {0}: hwnd={1} x={2} y={3} w={4} h={5}" -f `
            $label, $b.Hwnd, $b.Left, $b.Top, $b.Width, $b.Height)
    }
}

# The visible drop preview, or $null when none is up.
function Get-Preview([int]$AppPid) {
    $w = @(Get-TestWindows -ProcessId $AppPid -Class 'GhozttyDropHighlight' | Where-Object Visible)
    if ($w.Count -eq 0) { return $null }
    $p = $w[0]
    [pscustomobject]@{
        Hwnd = [IntPtr][int64]$p.Hwnd
        Left = $p.Left; Top = $p.Top; Width = $p.Width; Height = $p.Height
    }
}

function Test-Near([int]$a, [int]$b, [int]$tol = 2) {
    return ([math]::Abs($a - $b) -le $tol)
}

function Format-Px($p) {
    if ($null -eq $p) { return '?' }
    return ('{0},{1},{2}' -f $p.R, $p.G, $p.B)
}

# Move the held drag to (x, y) and return the preview it shows, if any.
function Get-PreviewAt([IntPtr]$top, [int]$AppPid, [int]$x, [int]$y, [string]$label) {
    Assert (Send-TestMouse -Window $top -Target $top -X $x -Y $y -Action move) "$($label): move delivered"
    Start-Sleep -Milliseconds 450
    $p = Get-Preview $AppPid
    if ($p) {
        Write-Host ("      {0}: preview x={1} y={2} w={3} h={4}" -f $label, $p.Left, $p.Top, $p.Width, $p.Height)
    } else {
        Write-Host ("      {0}: no preview" -f $label)
    }
    return $p
}

Stop-RepoInstances
Remove-Item (Get-GhozttySessionLayoutPath -Root $env:LOCALAPPDATA) -Force -ErrorAction SilentlyContinue
Remove-Item $errlog -ErrorAction SilentlyContinue

Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$app = $null

try {
    if ($NegativeControl) {
        Write-Host 'NEGATIVE CONTROL: the first quiet claim is inverted to "B''s left side IS previewed" - this run MUST fail'
    }

    $sp = @{
        Exe = $exe
        Arguments = @(
            '--config-default-files=false',
            '--macos-pane-style=flat',
            '--session-persistence=false',
            '--window-show-tab-bar=always',
            '--keybind=ctrl+shift+f9=toggle_rearrange_mode')
    }
    if (-not $ExePath) { $sp.StdErr = $errlog }
    $app = Start-OnTestDesktop @sp
    $appPid = [int]$app.Pid
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-TestAssertedNothing -Reason 'GUI died at launch' }
    $top = Wait-TestWindow -ProcessId $appPid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { Write-TestAssertedNothing -Reason 'top window not found' }
    Set-TestWindowSize -Window $top -Width 1400 -Height 900 | Out-Null
    Start-Sleep -Milliseconds 500
    & $exe +split --direction=right | Out-Null
    Start-Sleep -Milliseconds 1000

    $dpi = Get-TestWindowDpi -Window $top
    $scale = $dpi / 96.0
    $band = Get-TestChromeDip -Dip 24 -Scale $scale

    $focused = [IntPtr](Get-TestFocusedWindow -Window $top)
    $r = Send-TestKeys -Window $top -Target $focused -Modifiers ctrl, shift -Key F9
    Start-Sleep -Milliseconds 1200
    Assert $r 'setup: ctrl+shift+f9 (toggle_rearrange_mode) delivered'

    $before = Get-PaneBoxes $top
    Assert ($before.Count -eq 2) "setup: two terminal panes side by side (got $($before.Count))"
    if ($before.Count -ne 2) { Write-TestAssertedNothing -Reason 'the split never produced two panes' }
    Show-Boxes 'before' $before
    $a = $before[0]; $b = $before[1]
    if (-not (Test-Near $a.Top $b.Top 2)) { Write-TestAssertedNothing -Reason 'the two panes are not one row' }

    $midY = $b.Top + [int]($b.Height / 2)
    # B's slot is its window plus the header band above it.
    $slotTop = $b.Top - $band
    $slotH = $b.Height + $band
    $slotMidY = $slotTop + [int]($slotH / 2)
    # Well inside B's left and right triangles, clear of the divider's 10 DIP
    # reach and of the swap box.
    $bLeftX = $b.Left + [int]($b.Width * 0.08) + (Get-TestChromeDip -Dip 12 -Scale $scale)
    $bRightX = $b.Right - [int]($b.Width * 0.08)
    $bCenterX = $b.Left + [int]($b.Width / 2)
    $divX = [int](($a.Right + $b.Left) / 2)
    # Inside the 28 DIP edge band on the left, halfway down.
    $edgeX = $a.Left + (Get-TestChromeDip -Dip 8 -Scale $scale)
    # A's header band, where a rearrange drag picks a pane up.
    $grabX = $a.Left + 60
    $grabY = $a.Top - [int]($band / 2)

    Assert (Send-TestMouse -Window $top -Target $top -X $grabX -Y $grabY -Action down) 'setup: press on A''s header delivered'
    Assert (Send-TestMouse -Window $top -Target $top -X ($grabX + 40) -Y ($grabY + 20) -Action move) 'setup: drag started'
    Start-Sleep -Milliseconds 200

    # --- Claim Q: the spots that would leave A where it is are quiet ---------
    $q1 = Get-PreviewAt $top $appPid $bLeftX $midY 'Q1 B left side'
    if ($NegativeControl) {
        Assert ($null -ne $q1) 'NEGATIVE: B''s left side is previewed (pre-T2705 behavior)'
    } else {
        Assert ($null -eq $q1) 'Q: B''s left side - where A already is - shows no preview'
    }
    $q2 = Get-PreviewAt $top $appPid $divX $midY 'Q2 divider'
    Assert ($null -eq $q2) 'Q: the A|B divider shows no preview'
    $q3 = Get-PreviewAt $top $appPid $edgeX $midY 'Q3 left edge'
    Assert ($null -eq $q3) 'Q: the window''s left edge band shows no preview'

    # --- Claim S: a real split is previewed, with one seam -------------------
    $s = Get-PreviewAt $top $appPid $bRightX $midY 'S B right side'
    Assert ($null -ne $s) 'S: B''s right side - a real move - IS previewed (positive control)'
    if ($s) {
        $halfW = [int]($b.Width / 2)
        Assert (Test-Near ($s.Left + $s.Width) $b.Right 3) 'S: the preview is the right half of B (right edge)'
        Assert (Test-Near $s.Width $halfW 4) "S: the preview is half of B wide (got $($s.Width), want ~$halfW)"
        $shot = Get-TestWindowPixels -Window $s.Hwnd -Sync -AllowUniform
        try {
            $py = $s.Top + [int]($s.Height / 2)
            $edgeL = Get-TestPixel -Shot $shot -X $s.Left -Y $py
            $edgeR = Get-TestPixel -Shot $shot -X ($s.Left + $s.Width - 1) -Y $py
            $middle = Get-TestPixel -Shot $shot -X ($s.Left + [int]($s.Width / 2)) -Y $py
            Write-Host ("      split pixels: left={0} middle={1} right={2}" -f (Format-Px $edgeL), (Format-Px $middle), (Format-Px $edgeR))
            Assert (($null -ne $middle) -and ($null -ne $edgeL) -and ((Format-Px $edgeL) -ne (Format-Px $middle))) 'S: its left edge - where the new divider runs - is a seam'
            Assert (($null -ne $middle) -and ($null -ne $edgeR) -and ((Format-Px $edgeR) -eq (Format-Px $middle))) 'S: its right edge is plain fill - one seam, not a frame'
        } finally {
            Close-TestWindowPixels $shot
        }
    }

    # --- Claim W: a swap is the center box, with a glyph ---------------------
    $w = Get-PreviewAt $top $appPid $bCenterX $midY 'W B center'
    Assert ($null -ne $w) 'W: B''s center is previewed'
    if ($w) {
        $cx = $w.Left + $w.Width / 2
        $cy = $w.Top + $w.Height / 2
        Assert (Test-Near $cx ($b.Left + $b.Width / 2) 3) 'W: the swap box is centred across B'
        Assert (Test-Near $cy $slotMidY 3) 'W: the swap box is centred down B''s slot'
        Assert (($w.Width -lt $b.Width * 0.7) -and ($w.Height -lt $b.Height * 0.7)) 'W: the swap box is B''s center, not the whole of it'
        $shot = Get-TestWindowPixels -Window $w.Hwnd -Sync -AllowUniform
        try {
            $frame = [math]::Max(1, (Get-TestChromeDip -Dip 3 -Scale $scale))
            $fill = Get-TestPixel -Shot $shot -X ($w.Left + $frame + 4) -Y ($w.Top + $frame + 4)
            $border = Get-TestPixel -Shot $shot -X $w.Left -Y ([int]$cy)
            $glyph = 0
            $reach = Get-TestChromeDip -Dip 12 -Scale $scale
            for ($yy = [int]$cy - $reach; $yy -le [int]$cy + $reach; $yy += 1) {
                for ($xx = [int]$cx - $reach; $xx -le [int]$cx + $reach; $xx += 1) {
                    $p = Get-TestPixel -Shot $shot -X $xx -Y $yy
                    if ($null -ne $p -and (Format-Px $p) -ne (Format-Px $fill)) { $glyph++ }
                }
            }
            Write-Host ("      swap pixels: fill={0} border={1} glyph-pixels={2}" -f (Format-Px $fill), (Format-Px $border), $glyph)
            Assert ((Format-Px $border) -ne (Format-Px $fill)) 'W: the swap box is framed'
            Assert ($glyph -ge 10) "W: a glyph is drawn in the middle of the box (got $glyph pixels off the fill)"
        } finally {
            Close-TestWindowPixels $shot
        }
    }

    # --- Claim R: a release on a quiet spot changes nothing ------------------
    [void](Get-PreviewAt $top $appPid $bLeftX $midY 'R B left side')
    Assert (Send-TestMouse -Window $top -Target $top -X $bLeftX -Y $midY -Action up) 'R: release delivered'
    Start-Sleep -Milliseconds 1500
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'R: no crash on the release'
    Assert ($null -eq (Get-Preview $appPid)) 'R: no preview after the release'
    $after = Get-PaneBoxes $top
    Show-Boxes 'after ' $after
    Assert ($after.Count -eq 2) "R: both panes still visible (got $($after.Count))"
    if ($after.Count -eq 2) {
        Assert (($after[0].Hwnd -eq $a.Hwnd) -and ($after[1].Hwnd -eq $b.Hwnd)) 'R: A is still left of B'
        Assert ((Test-Near $after[0].Width $a.Width 2) -and (Test-Near $after[1].Width $b.Width 2)) 'R: and neither pane changed size'
    }

    Complete-TestBody
} finally {
    if ($td) { Remove-TestDesktop -Desktop $td }
    Stop-RepoInstances
}

$fgSeen = @(Stop-TestForegroundWatch)
Write-Host "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
$launched = @(Get-TestLaunchedPids)
$leaked = @($fgSeen | Where-Object { $launched -contains $_ })
Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
Assert ($leaked.Count -eq 0) 'no test-desktop app ever became foreground on the interactive desktop'

if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard rearrange-noop-drop -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Label 'T2705 REARRANGE NO-OP DROP' -Pass $script:pass -Fail $script:fail
