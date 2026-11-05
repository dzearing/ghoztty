# T2704 acceptance: dropping a dragged pane ON A DIVIDER puts it in that gap,
# with a third of the divider's split, and the drop is previewed as that area
# with a seam down each side.
#
# THE DEFECT. Mac's drop table gained a row in 30d13ea14: a release within 10pt
# of the middle of a gap between two panes INSERTS the pane there, spanning the
# divider's length, the two sides each giving up their share. Windows resolved
# "inside the window but between panes" to nothing, so the same release did
# nothing at all.
#
# ORACLE. Geometry and IDENTITY, the rearrange-drag.ps1 pattern: the terminal
# panes are child HWNDs, so the order the same HANDLES end up in says where the
# pane went, their widths say how much of the space it took, and the preview is
# a real top-level window (`GhozttyDropHighlight`) whose rect is compared with
# the area the drop promises. The seams are real pixels: a WM_PRINTCLIENT
# capture of the preview, its edge column against its middle.
#
# Claims, one app run, three panes A | B | C side by side:
#   P) a pointer on the A|B divider previews the insert: a third of the grid
#      wide, the grid's height, straddling that divider
#   S) the preview is seamed: its left and right edge columns are a different
#      color from its middle
#   I) releasing there gives A | C | B - C (the dragged pane) between the two,
#      a third of the grid wide, and every pane window survived the move
#
# -NegativeControl inverts claim I to "C is still on the right" - the
# pre-T2704 behavior - and MUST fail.
#
# Runs on the BACKGROUND test desktop. Only touches ghoztty processes running
# from this repo's zig-out*.
#
#   powershell -NoProfile -File test\win32\rearrange-divider-drop.ps1
param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }
$env:GHOZTTY_PIPE_SUFFIX = "-rdiv$PID"
$errlog = Join-Path $env:TEMP 'ghoztty-rearrange-divider-stderr.log'

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

Stop-RepoInstances
Remove-Item (Get-GhozttySessionLayoutPath -Root $env:LOCALAPPDATA) -Force -ErrorAction SilentlyContinue
Remove-Item $errlog -ErrorAction SilentlyContinue

Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$app = $null

try {
    if ($NegativeControl) {
        Write-Host 'NEGATIVE CONTROL: claim I is inverted to "C is still on the right" - this run MUST fail'
    }

    $sp = @{
        Exe = $exe
        Arguments = @(
            '--config-default-files=false',
            # Flush flat panes, so the widths below are the slots' (T1831).
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
    Set-TestWindowSize -Window $top -Width 1500 -Height 900 | Out-Null
    Start-Sleep -Milliseconds 500
    for ($i = 0; $i -lt 2; $i++) {
        & $exe +split --direction=right | Out-Null
        Start-Sleep -Milliseconds 1000
    }
    # Measured 2026-11-04 the tree comes out (A | B) | C at A=B=1/4, C=1/2.
    # With C out, A | B is even; C then takes a third of the grid and A and B
    # give up the same share - and a third is NOT what C had, so the width
    # claim below tells the insert from a no-op. (A | (B | C) at 1/2,1/4,1/4
    # gives the same answer: A | B is even once C has left either way.)

    $dpi = Get-TestWindowDpi -Window $top
    $scale = $dpi / 96.0
    $band = Get-TestChromeDip -Dip 24 -Scale $scale

    $focused = [IntPtr](Get-TestFocusedWindow -Window $top)
    $r = Send-TestKeys -Window $top -Target $focused -Modifiers ctrl, shift -Key F9
    Start-Sleep -Milliseconds 1200
    Assert $r 'setup: ctrl+shift+f9 (toggle_rearrange_mode) delivered'

    $before = Get-PaneBoxes $top
    Assert ($before.Count -eq 3) "setup: three terminal panes side by side (got $($before.Count))"
    if ($before.Count -ne 3) { Write-TestAssertedNothing -Reason 'the splits never produced three panes' }
    Show-Boxes 'before' $before
    $a = $before[0]; $b = $before[1]; $c = $before[2]
    $sameRow = (Test-Near $a.Top $b.Top 2) -and (Test-Near $b.Top $c.Top 2)
    if (-not $sameRow) { Write-TestAssertedNothing -Reason 'the three panes are not one row' }

    $gridLeft = $a.Left
    $gridRight = $c.Right
    $gridW = $gridRight - $gridLeft
    # The middle of the A|B gap, halfway down: inside the divider's reach
    # (10 DIP), far from the window's edge band.
    $divX = [int](($a.Right + $b.Left) / 2)
    $divY = $a.Top + [int]($a.Height / 2)
    # C's header band, which is where a rearrange drag picks a pane up.
    $grabX = $c.Left + 60
    $grabY = $c.Top - [int]($band / 2)

    Assert (Send-TestMouse -Window $top -Target $top -X $grabX -Y $grabY -Action down) 'setup: press on C''s header delivered'
    Assert (Send-TestMouse -Window $top -Target $top -X ($grabX - 40) -Y ($grabY + 20) -Action move) 'setup: drag started'
    Start-Sleep -Milliseconds 200
    Assert (Send-TestMouse -Window $top -Target $top -X $divX -Y $divY -Action move) 'setup: move onto the A|B divider delivered'
    Start-Sleep -Milliseconds 500

    # --- Claim P: the insert is previewed where it will land ----------------
    $prev = Get-Preview $appPid
    Assert ($null -ne $prev) 'P: the divider drop is previewed'
    if ($prev) {
        Write-Host ("      preview: x={0} y={1} w={2} h={3}  (grid x={4} w={5}, divider at {6})" -f `
            $prev.Left, $prev.Top, $prev.Width, $prev.Height, $gridLeft, $gridW, $divX)
        # Mac: a third of the split's space, at (mid - left) * 2/3 from its
        # left. The divider's split here is A | (B | C) or (A | B) | C, whose
        # extent is either the whole grid or A+B - accept the area each would
        # give, and require it to straddle the divider either way.
        $spanAB = $b.Right - $a.Left
        $wantWide = [int]($gridW / 3)
        $wantNarrow = [int]($spanAB / 3)
        $okWidth = (Test-Near $prev.Width $wantWide 6) -or (Test-Near $prev.Width $wantNarrow 6)
        Assert $okWidth "P: the preview is a third of the divider's split wide (got $($prev.Width), want $wantWide or $wantNarrow)"
        Assert (($prev.Left -lt $divX) -and (($prev.Left + $prev.Width) -gt $divX)) 'P: the preview straddles the divider'
        Assert (Test-Near $prev.Top ($a.Top - $band) 3) 'P: the preview starts at the top of the panes'' slots (header included)'
        Assert (Test-Near ($prev.Top + $prev.Height) $a.Bottom 3) 'P: and runs the divider''s whole length'

        # --- Claim S: a seam down each side ---------------------------------
        $shot = Get-TestWindowPixels -Window $prev.Hwnd -Sync -AllowUniform
        try {
            $midY = $prev.Top + [int]($prev.Height / 2)
            $edgeL = Get-TestPixel -Shot $shot -X $prev.Left -Y $midY
            $edgeR = Get-TestPixel -Shot $shot -X ($prev.Left + $prev.Width - 1) -Y $midY
            $middle = Get-TestPixel -Shot $shot -X ($prev.Left + [int]($prev.Width / 2)) -Y $midY
            $fmt = { param($p) if ($null -eq $p) { '?' } else { '{0},{1},{2}' -f $p.R, $p.G, $p.B } }
            Write-Host ("      preview pixels: left={0} middle={1} right={2}" -f (& $fmt $edgeL), (& $fmt $middle), (& $fmt $edgeR))
            Assert (($null -ne $middle) -and ($null -ne $edgeL) -and ((& $fmt $edgeL) -ne (& $fmt $middle))) 'S: the left edge is a seam, not the fill'
            Assert (($null -ne $middle) -and ($null -ne $edgeR) -and ((& $fmt $edgeR) -ne (& $fmt $middle))) 'S: the right edge is a seam, not the fill'
        } finally {
            Close-TestWindowPixels $shot
        }
    }

    # --- Claim I: the release inserts C between A and B ---------------------
    Assert (Send-TestMouse -Window $top -Target $top -X $divX -Y $divY -Action up) 'I: release delivered'
    Start-Sleep -Milliseconds 1500
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'I: no crash on the drop'
    Assert ($null -eq (Get-Preview $appPid)) 'I: the preview goes away on release'

    $after = Get-PaneBoxes $top
    Show-Boxes 'after ' $after
    Assert ($after.Count -eq 3) "I: all three panes still visible (got $($after.Count))"
    if ($after.Count -eq 3) {
        if ($NegativeControl) {
            Assert ($after[2].Hwnd -eq $c.Hwnd) 'NEGATIVE: C is still on the right (pre-T2704 behavior)'
        } else {
            Assert ($after[0].Hwnd -eq $a.Hwnd) 'I: A is still first'
            Assert ($after[1].Hwnd -eq $c.Hwnd) 'I: the dragged pane C now sits between A and B'
            Assert ($after[2].Hwnd -eq $b.Hwnd) 'I: B is last'
        }
        $mid = $after[1]
        Assert (Test-Near $mid.Width ([int]($gridW / 3)) 10) `
            "I: C takes a third of the grid (got $($mid.Width), want ~$([int]($gridW / 3)))"
        Assert (Test-Near $after[0].Width $after[2].Width 10) `
            'I: and A and B each gave up the same share - they stay equal'
        Assert ((Test-Near $after[0].Top $after[1].Top 2) -and (Test-Near $after[1].Top $after[2].Top 2)) `
            'I: one row still - the pane went into the gap, not under a pane'
        $ids = @($before | ForEach-Object { $_.Hwnd } | Sort-Object)
        $idsAfter = @($after | ForEach-Object { $_.Hwnd } | Sort-Object)
        Assert (($ids -join ',') -eq ($idsAfter -join ',')) 'I: the same three pane windows survived - no pane was rebuilt'
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
        update -Guard rearrange-divider-drop -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Label 'T2704 REARRANGE DIVIDER DROP' -Pass $script:pass -Fail $script:fail
