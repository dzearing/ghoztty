# T2670 acceptance: a pane's frame is laid out from the top of the FRAME, not
# from the top of its GL storage.
#
# WHAT BROKE. Since T2577 a Win32 render target keeps storage rounded up to a
# 256 px bucket and draws the frame in its bottom-left w x h. Two fragment
# shaders found their pixel with `layout(origin_upper_left)`, which counts from
# the top of the WHOLE storage, so in any pane whose height is not a multiple of
# 256 they were shifted up by (storage - height) px:
#   - bg_image.f: a glass pane's desk slice slid up and left a flat band of plain
#     background along the pane's bottom (the user's report: a gray strip under
#     the terminal after folding blades - the fold changed the pane's height);
#   - cell_bg.f: every cell's background colour sat that far above its text.
#
# THE ORACLES read the pane's own render target through the debug capture-pane
# IPC (lib\PaneCapture.ps1), which reads exactly the bottom-left w x h the
# presenter shows, so this runs off-desktop:
#   1. a glass pane's bottom rows are NOT the plain background (the band), and
#   2. a full-width red cell-background row printed on grid row 0 shows at the
#      top of the frame at its full cell height (shifted, it is clipped away).
# Section 0 sizes the window so the pane's storage gap is large enough that
# the shifted picture is unmistakable; a gap under 32 px is reported, not
# scored, because it could not tell the two pictures apart.
#
# -NegativeControl asserts the BROKEN picture, which must fail on a fixed build
# (and passes on a build from before the fix: that is how the oracles were shown
# to be red before the fix, 2026-11-04).
#
# Runs on the BACKGROUND test desktop and never takes the user's foreground.
# Only touches ghoztty processes running from this repo's zig-out*.
param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive, [string]$SaveShot)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }
$env:GHOZTTY_PIPE_SUFFIX = "-glassorigin$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\PaneCapture.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')

[void](Assert-GhozttyIsolatedBuild -Exe $exe)

$script:pass = 0
$script:fail = 0
$script:skipped = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

# The plain background the band shows, and the cell colour section 2 prints.
$bgR = 0x28; $bgG = 0x2c; $bgB = 0x34
function Test-Near($c, [int]$r, [int]$g, [int]$b, [int]$tol = 6) {
    return ([math]::Abs($c.R - $r) -le $tol -and [math]::Abs($c.G - $g) -le $tol -and [math]::Abs($c.B - $b) -le $tol)
}
function Test-Red($c) { return ($c.R -ge 150 -and $c.G -le 80 -and $c.B -le 80) }

function Get-Win($target) {
    $json = (& $exe +list --json 2>$null | Out-String).Trim()
    if (-not $json) { return $null }
    $data = ($json | ConvertFrom-Json).data
    foreach ($w in $data.windows) { if ($w.target -eq $target) { return $w } }
    return $null
}
function Wait-Win($target) {
    for ($t = 0; $t -lt 30; $t++) {
        $w = Get-Win $target
        if ($w) { return $w }
        Start-Sleep -Milliseconds 200
    }
    return $null
}
function Wait-Capture($target) {
    for ($t = 0; $t -lt 25; $t++) {
        $shot = Get-TestPaneCapture -Target $target
        if ($shot) { return $shot }
        Start-Sleep -Milliseconds 200
    }
    return $null
}
# The 256 px bucket Target.capacityFor rounds storage up to (T2577).
function Get-StorageGap([int]$h) { return ([math]::Ceiling($h / 256.0) * 256) - $h }

[void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
Remove-Item (Get-GhozttySessionLayoutPath -Root $env:LOCALAPPDATA) -Force -ErrorAction SilentlyContinue

Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$appPid = 0

try {

$app = Start-OnTestDesktop -Exe $exe -Arguments @(
    '--config-default-files=false', '--session-persistence=false',
    '--background=#282c34', '--macos-pane-style=elevated', '--macos-pane-glass=true')
$appPid = [int]$app.Pid
Start-Sleep -Seconds 3
if ($app.Process -and $app.Process.HasExited) {
    Write-TestAssertedNothing -Reason 'GUI died at launch' -Label 'glass-frame-origin'
}
$launchTop = Wait-TestWindow -ProcessId $appPid -Class 'GhozttyWindow'
if ($launchTop -eq [IntPtr]::Zero) {
    Write-TestAssertedNothing -Reason 'launch window never appeared' -Label 'glass-frame-origin'
}
Assert (-not (Test-TestDesktopLeak -ProcessId $appPid)) 'GUI is NOT enumerable on the interactive desktop'

# A pane whose row 0 is one full-width red cell-background row, and nothing
# else that draws a background. The shell then sleeps, so the frame holds.
$printer = Join-Path $env:TEMP "ghoztty-glass-origin-$PID.ps1"
[IO.File]::WriteAllText($printer, @'
$e = [char]27
[Console]::Write("$e[2J$e[H")
$w = $Host.UI.RawUI.WindowSize.Width
[Console]::Write("$e[48;2;255;0;0m" + (' ' * $w) + "$e[0m")
[Console]::Write("$e[3;1H")
Start-Sleep -Seconds 600
'@)
& $exe +new-window --target=glassA -e powershell -NoProfile -ExecutionPolicy Bypass -File $printer | Out-Null
$win = Wait-Win 'glassA'
if (-not $win) {
    Write-TestAssertedNothing -Reason 'window glassA never registered' -Label 'glass-frame-origin'
}
$top = [IntPtr][int64]$win.id

# --- 0. Size the window so the storage gap is wide ------------------------
# A gap under 32 px could not tell the shifted picture from the right one, so
# the height is stepped until the gap is wide (at most a few tries).
$shot = $null
$gap = 0
foreach ($hh in @(700, 760, 820, 640, 900)) {
    [void](Set-TestWindowPos -Window $top -X 40 -Y 40 -Width 900 -Height $hh)
    Start-Sleep -Milliseconds 1500
    if ($shot) { Close-TestPaneCapture $shot }
    $shot = Wait-Capture 'glassA'
    if (-not $shot) { break }
    $gap = Get-StorageGap $shot.Height
    if ($gap -ge 32) { break }
}
if (-not $shot) {
    Write-TestAssertedNothing -Reason "no capture of glassA ($(Get-LastPaneCaptureError))" -Label 'glass-frame-origin'
}
Write-Host ("INFO  pane {0}x{1}, storage gap {2} px" -f $shot.Width, $shot.Height, $gap)
if ($gap -lt 32) {
    Write-Host "SKIP  no window height left a storage gap of 32 px or more; the oracles cannot discriminate"
    $script:skipped++
} else {
    $bmp = $shot.Bitmap
    $w = $shot.Width; $h = $shot.Height
    # -SaveShot keeps the capture for a human to look at.
    if ($SaveShot) { $bmp.Save($SaveShot) }

    # --- 1. The glass reaches the bottom: no plain-background band --------
    # Right-hand column, clear of any text. Count the rows up from the bottom
    # that are exactly the plain background: the broken frame has ~gap of them.
    $x = [int]($w * 0.9)
    $flat = 0
    for ($y = $h - 1; $y -ge 0; $y--) {
        if (Test-Near $bmp.GetPixel($x, $y) $bgR $bgG $bgB 2) { $flat++ } else { break }
    }
    $mid = $bmp.GetPixel($x, [int]($h / 2))
    Assert (-not (Test-Near $mid $bgR $bgG $bgB 2)) `
        ("the glass is not the plain background mid-pane (mid #{0:x2}{1:x2}{2:x2}) - the oracle below can see glass" -f $mid.R, $mid.G, $mid.B)
    if ($NegativeControl) {
        Assert ($flat -ge ($gap - 8)) "NEGATIVE CONTROL: a ~$gap px plain band at the pane's bottom ($flat px)"
    } else {
        Assert ($flat -le 4) "no plain-background band at the glass pane's bottom ($flat px flat, storage gap $gap)"
    }

    # --- 2. Cell backgrounds sit on their rows ----------------------------
    # Row 0 is red. Find the red run in a column clear of the cursor and
    # measure it: fixed, it starts at the top padding and is a whole cell tall;
    # shifted up by the gap it is clipped at the frame's top (or gone).
    $cx = [int]($w * 0.5)
    $redTop = -1; $redRows = 0
    for ($y = 0; $y -lt [math]::Min($h, 200); $y++) {
        if (Test-Red $bmp.GetPixel($cx, $y)) {
            if ($redTop -lt 0) { $redTop = $y }
            $redRows++
        } elseif ($redTop -ge 0) { break }
    }
    Write-Host "INFO  red row: top $redTop, $redRows px tall"
    if ($NegativeControl) {
        Assert ($redTop -le 0 -and $redRows -lt 14) "NEGATIVE CONTROL: the red row is clipped at the frame's top (top $redTop, $redRows px)"
    } else {
        Assert ($redRows -ge 14) "the red cell-background row is a whole cell tall ($redRows px, needs >= 14)"
        Assert ($redTop -gt 0) "the red row starts below the frame's top edge (y=$redTop), not clipped by it"
    }
}
if ($shot) { Close-TestPaneCapture $shot }

# --- 3. The run never took the user's foreground ---------------------------
$fgSeen = @(Stop-TestForegroundWatch)
$leaked = @(Get-TestLaunchedPids | Where-Object { $fgSeen -contains $_ })
Assert ($leaked.Count -eq 0) "the user's foreground was never taken ($($leaked -join ', '))"
Complete-TestBody

} finally {
    if ($appPid) { Stop-Process -Id $appPid -Force -ErrorAction SilentlyContinue }
    [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
    if ($td) { Remove-TestDesktop $td }
    Remove-Item (Join-Path $env:TEMP "ghoztty-glass-origin-$PID.ps1") -ErrorAction SilentlyContinue
}

# Only a clean run of the shipped build stamps the guard: not the negative
# control, not a run whose oracles were skipped, not another build's exe.
if ($script:fail -eq 0 -and $script:skipped -eq 0 -and -not $NegativeControl -and -not $ExePath) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard glass-frame-origin -Repo $repo 2>&1 | ForEach-Object { Write-Host "  $_" }
}

Write-TestVerdict -Pass $script:pass -Fail $script:fail -Skipped $script:skipped -Label 'glass-frame-origin'
