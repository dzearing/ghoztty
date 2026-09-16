# T778 acceptance: a COMPOSITED window capture - the parent's GDI chrome with
# every pane's rendered glass in its own rect - off the background test desktop.
#
# WHAT IS BEING PROVED, and why it needs proving. Route 0 (`capture-pane`, T275)
# hands out ONE pane's pixels and by construction says nothing about anything
# outside that pane. So the claim with no oracle at all was the strip of PARENT
# between two panes: `PrintWindow` of the parent keeps every intermediate
# divider line a drag ever painted (measured 2026-07-31: 3 drags -> 13 runs),
# because the GL child never overpaints the parent's backing store in that
# render. `split-divider.ps1` had to retire its cross-pane stale-line scan over
# it (T228) and argue the point from geometry instead.
#
# `lib\WindowComposite.ps1` composes the two: parent capture, then each pane's
# own capture drawn over its own rect, using the placement the capture response
# now reports (`x`/`y`/`client_width`/`client_height`). The result is what the
# screen would show - a stale line UNDER a pane is covered exactly as a pane
# covers it on screen, and one in the parent-visible gap survives.
#
# THE LOAD-BEARING ORACLE IS SECTION 2, and it is deliberately not "the
# composite has many colors". The fixture is an image whose expected content is
# KNOWN: two panes with DIFFERENT tints either side of a green divider band. The
# composite must report pane A's tint at pane A's centre, pane B's tint at pane
# B's centre, and the divider's green in the gap between them. A composite that
# is mis-placed, scaled, swapped, or simply the parent capture with nothing
# composed in cannot get all three right - and section 3 pins the last of those
# by measuring the same pixel on the RAW parent capture, where it is the flat
# fill the CAPTURE LIMIT describes.
#
# Section 4 is the assertion T228 retired and T734 is waiting on: a full
# scanline ACROSS both panes, after three drags, crosses the divider color
# exactly ONCE. It is scored on the composite only; the raw parent's count is
# printed beside it as the measurement that says why (it is the number T228
# recorded, and it is why this file exists).
#
# -NegativeControl expects pane B's centre to carry pane A's tint, which MUST
# fail: that is the answer a mis-composed capture gives, so a green negative
# control means section 2 discriminates nothing.
#
# Runs on the BACKGROUND test desktop and never takes the user's foreground.
# Only touches ghoztty processes running from this repo's zig-out*.
#   powershell -NoProfile -File test\win32\window-composite.ps1
param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }
# Isolated endpoint: every oracle here is an IPC probe or a capture taken
# through one, so both ends address THIS run's instance and nothing else.
$env:GHOZTTY_PIPE_SUFFIX = "-compositetest$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\PaneCapture.ps1')
. (Join-Path $PSScriptRoot 'lib\WindowComposite.ps1')
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

function Kill-RepoInstances {
    [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
}

# True if r,g,b is within tolerance of the target. Captures come off a GL
# surface, so an exact match is not something to insist on (PaneCapture.ps1's
# Test-PaneColorNear says the same thing about the same pixels).
function Near([object]$px, [int]$r, [int]$g, [int]$b, [int]$tol = 24) {
    if ($null -eq $px) { return $false }
    return ([math]::Abs([int]$px.R - $r) -le $tol -and
            [math]::Abs([int]$px.G - $g) -le $tol -and
            [math]::Abs([int]$px.B - $b) -le $tol)
}

function Show([object]$px) {
    if ($null -eq $px) { return 'off-capture' }
    return "$($px.R),$($px.G),$($px.B)"
}

# Runs of divider-colored pixels down a column of a shot, in SCREEN
# coordinates - the cross-pane scan itself. One run is a healthy band; more
# than one is a stale line that survived somewhere along the line.
function Count-DividerRuns($shot, [int]$x, [int]$y0, [int]$y1) {
    $runs = 0; $inRun = $false
    for ($y = $y0; $y -le $y1; $y++) {
        $px = Get-TestPixel -Shot $shot -X $x -Y $y
        if (Near $px 0 255 0 40) {
            if (-not $inRun) { $runs++; $inRun = $true }
        } else { $inRun = $false }
    }
    return $runs
}

# A posted divider drag, the same mechanism split-divider.ps1 uses: the band
# click lands on the TOP-LEVEL window because the pane answers HTTRANSPARENT,
# and updateDividerDrag reads its coordinates out of the WM_MOUSEMOVE lparam
# rather than consulting the cursor - so a posted drag is the input it would
# have got.
function Invoke-DividerDrag([IntPtr]$Top, [int]$X0, [int]$Y0, [int]$X1, [int]$Y1) {
    [void](Send-TestMouse -Window $Top -Target $Top -X $X0 -Y $Y0 -Action down)
    $steps = 8
    for ($i = 1; $i -le $steps; $i++) {
        $x = [int]($X0 + ($X1 - $X0) * $i / $steps)
        $y = [int]($Y0 + ($Y1 - $Y0) * $i / $steps)
        [void](Send-TestMouse -Window $Top -Target $Top -X $x -Y $y -Action move)
    }
    [void](Send-TestMouse -Window $Top -Target $Top -X $X1 -Y $Y1 -Action up)
    Start-Sleep -Milliseconds 250
}

Kill-RepoInstances
Remove-Item "$env:LOCALAPPDATA\ghoztty\session-layout-debug.json" -Force -ErrorAction SilentlyContinue

Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$appPid = 0

try {

# A green divider over a dark window, one split down the middle, and a
# DIFFERENT tint per pane - the known image section 2 scores against.
# --unfocused-split-opacity=1 so the unfocused pane's tint is the tint and not
# a dimmed version of it.
$app = Start-OnTestDesktop -Exe $exe -Arguments @(
    '--config-default-files=false', '--session-persistence=false',
    '--background=#101014', '--unfocused-split-opacity=1',
    '--split-divider-color=00ff00')
$appPid = [int]$app.Pid
Start-Sleep -Seconds 3
if ($app.Process -and $app.Process.HasExited) {
    Write-TestAssertedNothing -Reason 'GUI died at launch' -Label 'window-composite'
}
$launchTop = Wait-TestWindow -ProcessId $appPid -Class 'GhozttyWindow'
if ($launchTop -eq [IntPtr]::Zero) {
    Write-TestAssertedNothing -Reason 'launch window never appeared' -Label 'window-composite'
}
Assert (-not (Test-TestDesktopLeak -ProcessId $appPid)) `
    'GUI is NOT enumerable on the interactive desktop'

& $exe +new-window --target=compw --color=`#204080 | Out-Null
Start-Sleep -Milliseconds 1200
& $exe +split --target=compw --direction=down --name=compB --color=`#802040 | Out-Null
Start-Sleep -Milliseconds 1200

# `+list --json` window ids ARE the decimal HWND (asserted in pane-capture.ps1
# section 5), so the window the registry describes and the window the harness
# holds a handle to are the same object - which is also what lets the composite
# enumerate this window's panes.
$top = [IntPtr]::Zero
for ($t = 0; $t -lt 25; $t++) {
    $json = (& $exe +list --json 2>$null | Out-String).Trim()
    $w = if ($json) { ($json | ConvertFrom-Json).data.windows | Where-Object { $_.target -eq 'compw' } | Select-Object -First 1 } else { $null }
    if ($w -and $w.id) { $top = [IntPtr][int64]$w.id; break }
    Start-Sleep -Milliseconds 300
}
if ($top -eq [IntPtr]::Zero) {
    Write-TestAssertedNothing -Reason 'the two-pane fixture window never appeared' -Label 'window-composite' -Skipped $script:skipped
}

# --- 1. The mechanism: a composite comes back, with both panes in it -------
$targets = Get-TestWindowPaneTargets -Window $top -Exe $exe
Assert (@($targets).Count -eq 2) "the window's two terminal panes are enumerable ($($targets -join ', '))"

$shot = $null
for ($t = 0; $t -lt 25; $t++) {
    $shot = Get-TestWindowComposite -Window $top -Exe $exe
    if ($shot) { break }
    Start-Sleep -Milliseconds 300
}
Assert ($null -ne $shot) "a composite comes back for a two-pane window ($(Get-LastCompositeError))"
if ($null -eq $shot) {
    Write-TestVerdict -Pass $script:pass -Fail ($script:fail + 1) -Skipped $script:skipped -Label 'window-composite'
}

Assert ($shot.Panes.Count -eq 2) "both panes were composed in ($($shot.Panes.Count))"
Assert ($shot.Bitmap.Width -eq $shot.Width -and $shot.Bitmap.Height -eq $shot.Height) `
    "the composite is the window's own size ($($shot.Bitmap.Width)x$($shot.Bitmap.Height))"

# The two panes, in layout order down the window.
$pa = $shot.Panes | Sort-Object Top | Select-Object -First 1
$pb = $shot.Panes | Sort-Object Top | Select-Object -Last 1
Assert ($pa.Top -lt $pb.Top -and $pa.Left -eq $pb.Left -and $pa.Width -eq $pb.Width) `
    "the placements describe a vertical split (A $($pa.Left),$($pa.Top) $($pa.Width)x$($pa.Height); B $($pb.Left),$($pb.Top) $($pb.Width)x$($pb.Height))"

function Centre($p) { return @([int]($p.Left + $p.Width / 2), [int]($p.Top + $p.Height / 2)) }
$ca = Centre $pa
$cb = Centre $pb
$pxA = Get-TestPixel -Shot $shot -X $ca[0] -Y $ca[1]
$pxB = Get-TestPixel -Shot $shot -X $cb[0] -Y $cb[1]

# --- 2. THE KNOWN IMAGE: each pane's glass is in its own rect --------------
# Mis-placed, scaled, swapped or simply not composed at all - none of those can
# produce both of these answers.
Assert (Near $pxA 0x20 0x40 0x80) "pane A's tint #204080 is at pane A's centre (got $(Show $pxA))"
if ($NegativeControl) {
    # MUST fail: exactly the answer a mis-composed capture gives.
    Assert (Near $pxB 0x20 0x40 0x80) `
        "NEGATIVE CONTROL: pane A's tint is at pane B's centre (got $(Show $pxB))"
} else {
    Assert (Near $pxB 0x80 0x20 0x40) "pane B's tint #802040 is at pane B's centre (got $(Show $pxB))"
}

# The divider's own pixels are the PARENT's paint, and they survive the pane
# blits because the panes do not reach into the gap.
$gapY = [int](($pa.Top + $pa.Height + $pb.Top) / 2)
$gapPx = Get-TestPixel -Shot $shot -X $ca[0] -Y $gapY
Assert (Near $gapPx 0 255 0 40) `
    "the divider band survives composition in the gap between the panes (got $(Show $gapPx))"

# --- 3. The composite is NOT just the parent capture -----------------------
# The same pixel on the raw PrintWindow is the flat fill the CAPTURE LIMIT
# describes, which is the whole reason a composite had to exist.
$raw = Get-TestWindowPixels -Window $top -Sync -AllowUniform
try {
    $rawA = Get-TestPixel -Shot $raw -X $ca[0] -Y $ca[1]
    Assert (-not (Near $rawA 0x20 0x40 0x80)) `
        "the RAW parent capture does not carry pane A's glass (got $(Show $rawA)) - the composite added it"
} finally { Close-TestWindowPixels $raw }

# --- 4. The cross-pane stale-line scan, restored (T228 -> T734) ------------
# Three drags, each landing somewhere new. Every one of them leaves its old
# line in the parent's backing store; on screen each is covered by a pane, and
# in the composite each is covered by that pane's glass in exactly the same way.
$bandX = [int]($pa.Left + $pa.Width / 2)
foreach ($delta in 60, -40, 70) {
    $cur = Get-TestWindowComposite -Window $top -Exe $exe
    if ($null -eq $cur) { break }
    $ua = $cur.Panes | Sort-Object Top | Select-Object -First 1
    $ub = $cur.Panes | Sort-Object Top | Select-Object -Last 1
    $lineY = [int](($ua.Top + $ua.Height + $ub.Top) / 2)
    Close-TestWindowComposite $cur
    Invoke-DividerDrag -Top $top -X0 $bandX -Y0 $lineY -X1 $bandX -Y1 ($lineY + $delta)
    Start-Sleep -Milliseconds 300
}
Start-Sleep -Milliseconds 400

Close-TestWindowComposite $shot
$shot = Get-TestWindowComposite -Window $top -Exe $exe
if ($null -eq $shot) {
    Write-Host "SKIP  cross-pane scan: no composite after the drags ($(Get-LastCompositeError))"
    $script:skipped++
} else {
    $pa = $shot.Panes | Sort-Object Top | Select-Object -First 1
    $pb = $shot.Panes | Sort-Object Top | Select-Object -Last 1
    # A full scanline DOWN the window, across both panes and the gap between
    # them - the scan T228 could not keep.
    $x = [int]($pa.Left + $pa.Width / 2)
    $y0 = $pa.Top + 2
    $y1 = $pb.Top + $pb.Height - 2
    $runs = Count-DividerRuns $shot $x $y0 $y1
    Assert ($runs -eq 1) `
        "ONE divider band on a scanline across BOTH panes after 3 drags (runs $runs, y $y0..$y1)"

    # The measurement that says why this needed a composite, printed rather
    # than scored: the same scan on the raw parent capture is the number T228
    # recorded, and it is a property of a HEALTHY build.
    $raw2 = Get-TestWindowPixels -Window $top -Sync -AllowUniform
    try {
        $rawRuns = Count-DividerRuns $raw2 $x $y0 $y1
        Write-Host "  MEASURED the same scan on the RAW parent capture: $rawRuns run(s) - stale lines the panes cover on screen"
    } finally { Close-TestWindowPixels $raw2 }
}

# --- 5. Every failure names a different state ------------------------------
$bogus = Get-TestWindowComposite -Window $top -Targets @('nosuchpane')
Assert ($null -eq $bogus -and (Get-LastCompositeError) -like "*not found in registry*") `
    "a pane that cannot be captured refuses the composite (got '$(Get-LastCompositeError)')"

$noargs = Get-TestWindowComposite -Window $top
Assert ($null -eq $noargs -and (Get-LastCompositeError) -like '*-Targets*') `
    "a composite with nothing to enumerate with says so (got '$(Get-LastCompositeError)')"

# --- 6. The placement the composite relies on comes from the app ----------
# Not restated in PowerShell: the capture response carries it, and it agrees
# with the pane window the harness can see.
$paneWin = @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal' | Where-Object Visible | Sort-Object Top)
if ($paneWin.Count -ne 2 -or $null -eq $shot) {
    Write-Host 'SKIP  placement cross-check: the fixture is not two visible panes'
    $script:skipped++
} else {
    $pa = $shot.Panes | Sort-Object Top | Select-Object -First 1
    Assert ([math]::Abs($pa.Left - $paneWin[0].Left) -le 1 -and [math]::Abs($pa.Top - $paneWin[0].Top) -le 1 -and
            [math]::Abs($pa.Width - $paneWin[0].Width) -le 1 -and [math]::Abs($pa.Height - $paneWin[0].Height) -le 1) `
        ("the reported placement is the pane window's own rect " +
         "(app $($pa.Left),$($pa.Top) $($pa.Width)x$($pa.Height); window $($paneWin[0].Left),$($paneWin[0].Top) $($paneWin[0].Width)x$($paneWin[0].Height))")
}

if ($shot) { Close-TestWindowComposite $shot }

# --- 7. The run never took the user's foreground ---------------------------
$fgSeen = @(Stop-TestForegroundWatch)
$leaked = @(Get-TestLaunchedPids | Where-Object { $fgSeen -contains $_ })
Assert ($leaked.Count -eq 0) "the user's foreground was never taken ($($leaked -join ', '))"
Complete-TestBody  # T1039: the run reached the end of its body

} finally {
    # Remove-TestDesktop kills what the harness launched AND records that the
    # kill was deliberate, so a force-killed fixture is not reported as a crash
    # (a bare Stop-Process here reads as `CRASHED - 0xFFFFFFFF` in the
    # postmortem, which is the teardown's own exit code - T1574).
    if ($td) { Remove-TestDesktop $td }
    Kill-RepoInstances
}

# A green run stamps the covered files (T783), so `guard-due.ps1` can answer
# "has this harness been run against the code as it now stands?" for the
# composite seam - the placement in `ipc_capture.zig` and the two libs that
# read it. Red leaves the stamp alone: red stays due. The negative control is
# red BY DESIGN and stamps nothing either way.
if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard window-composite -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-TestVerdict -Pass $script:pass -Fail $script:fail -Skipped $script:skipped -Label 'window-composite'
