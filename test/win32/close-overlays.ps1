# T2012 acceptance: a pane's overlay popups leave the screen WITH the pane.
#
# The user's report: "when i have multiple panes open each with a banner,
# closing one causes its banner to linger for about 5 second before it
# disappears." A closed pane is parked for `undo-timeout` (T1825; default
# 5 s) and, before T2012, parking hid only the pane's own window. The banner,
# dim wash and scrollbar are separate popups OWNED by it, hiding an owner does
# not hide what it owns, and the parked pane is out of the tree the overlay
# passes walk - so they stood over the neighbour until the undo expired.
#
# Sections:
#   1. Three panes side by side (cw | c2 | c3), each with a banner: three
#      banner popups are on screen, one glued above each pane.
#   2. +close c2: every popup that sat in c2's slot (banner, dim, scrollbar,
#      and any other Ghoztty overlay class) is hidden by the time +close has
#      answered, and still hidden 1 s later. Two banners remain visible.
#   3. ctrl+shift+z is not needed for this - but undo is the reason the pane is
#      alive, so the run also proves +close parked it rather than destroying
#      it (the banner HWND still exists, hidden), which is what makes section 2
#      the T2012 shape and not a plain teardown.
#   4. +stash c3: its banner is hidden at once too (stash keeps the pane in the
#      tree; this pins that path so a refactor cannot regress it).
#   5. +close the whole cw window (parked for undo, since the launch window is
#      still open): both of its banners leave the screen at once.
#
# -NegativeControl runs the section-2 oracle BEFORE the close, when c2's banner
# is legitimately visible, so it MUST fail: the proof that the oracle can see a
# visible popup at all.
#
# Runs on a BACKGROUND desktop (lib\TestDesktop.ps1) and never takes the
# user's foreground - asserted by the foreground watcher, not assumed.
#
#   powershell -NoProfile -File test\win32\close-overlays.ps1
param(
    [string]$ExePath,
    [switch]$NegativeControl,
    [switch]$Interactive
)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }

$env:GHOZTTY_PIPE_SUFFIX = "-t2012test$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:pass = 0
$script:fail = 0
$script:skipped = 0
$script:negReached = $false

function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Stop-RepoInstances {
    [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
}

function Get-Win($target) {
    $json = (& $exe +list --json 2>$null | Out-String).Trim()
    if (-not $json) { return $null }
    $data = ($json | ConvertFrom-Json).data
    foreach ($w in $data.windows) {
        if ($w.target -eq $target) { return $w }
    }
    return $null
}

# Every overlay popup class a pane can own (Surface.overlay_fields, plus the
# link preview, which has no class of its own worth matching).
$overlayClasses = @(
    'GhozttyBannerOverlay', 'GhozttyDimOverlay', 'GhozttyScrollbar',
    'GhozttyBellBorder', 'GhozttyReadonlyBadge', 'GhozttyKeyState'
)

# Every overlay popup of this process, hidden ones included.
function Get-OverlayPopups([int]$procId) {
    $out = New-Object System.Collections.ArrayList
    foreach ($c in $overlayClasses) {
        foreach ($w in @(Get-TestWindows -ProcessId $procId -Class $c -AllowHidden)) { [void]$out.Add($w) }
    }
    return $out.ToArray()
}

function Get-VisibleBanners([int]$procId) {
    return @(Get-TestWindows -ProcessId $procId -Class 'GhozttyBannerOverlay' | Sort-Object Left)
}

# The VISIBLE overlay popups whose horizontal centre falls inside [$left,$right)
# and which start no higher than $top (the pane's banner top). The vertical bound
# matters: the app's launch window is another top-level whose popups can share
# c2's x-range.
function Get-PopupsInColumn([int]$procId, [int]$left, [int]$right, [int]$top) {
    return @(@(Get-OverlayPopups $procId) | Where-Object {
        $_.Visible -and ($_.Top -ge $top) -and ((($_.Left + $_.Right) / 2) -ge $left) -and ((($_.Left + $_.Right) / 2) -lt $right)
    })
}

function Test-HwndVisible([int]$procId, [int64]$hwnd) {
    foreach ($w in @(Get-OverlayPopups $procId)) { if ($w.Hwnd -eq $hwnd) { return $w.Visible } }
    return $false
}
function Test-HwndExists([int]$procId, [int64]$hwnd) {
    foreach ($w in @(Get-OverlayPopups $procId)) { if ($w.Hwnd -eq $hwnd) { return $true } }
    return $false
}

function Wait-Until([scriptblock]$Probe, [int]$Ms = 6000) {
    $deadline = (Get-Date).AddMilliseconds($Ms)
    do {
        if (& $Probe) { return $true }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)
    return $false
}

Stop-RepoInstances
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    # Persistence off: a blank layout every run. A long undo window, so a
    # banner that only goes away at expiry cannot pass by luck.
    $app = Start-OnTestDesktop -Exe $exe -Arguments @('--session-persistence=false', '--undo-timeout=20s', '--macos-pane-glass=false')
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $appPid = $app.Pid
    if ((Wait-TestWindow -ProcessId $appPid -Class 'GhozttyWindow') -eq [IntPtr]::Zero) {
        Write-Host 'SETUP FAIL: no GhozttyWindow'; exit 1
    }
    Assert (-not (Test-TestDesktopLeak -ProcessId $appPid)) 'GUI is NOT enumerable on the interactive desktop'

    & $exe +new-window --target=cw | Out-Null
    $cw = $null
    for ($t = 0; $t -lt 25 -and -not $cw; $t++) { $cw = Get-Win 'cw'; if (-not $cw) { Start-Sleep -Milliseconds 200 } }
    if (-not $cw) { Write-Host 'SETUP FAIL: cw window not registered'; exit 1 }
    # Wide enough for three panes side by side at the stacked-panes minimum
    # (T2108: 300 DIP each). The default window is narrower than that, so the
    # row stacked c3 into a strip and its banner never showed: "saw 2" was a
    # pane folded away, not a banner lost (T1122's turn; T2139 is the twin).
    foreach ($w in @(Get-TestWindows -ProcessId $appPid -Class 'GhozttyWindow')) {
        $dpi = Get-TestWindowDpi -Window ([IntPtr]$w.Hwnd)
        $scale = if ($dpi -gt 0) { $dpi / 96.0 } else { 1.0 }
        [void](Set-TestWindowSize -Window ([IntPtr]$w.Hwnd) -Width ([int][math]::Round(1300 * $scale, [MidpointRounding]::AwayFromZero)) -Height ([int][math]::Round(700 * $scale, [MidpointRounding]::AwayFromZero)))
    }
    & $exe +split --target=cw --direction=right --name=c2 | Out-Null
    & $exe +split --target=c2 --direction=right --name=c3 | Out-Null
    & $exe +set-banner --target=cw 'left pane' | Out-Null
    # Three lines, so c2's banner is the TALLEST: that, not a left-to-right
    # guess, is how the run knows which popups are c2's.
    & $exe +set-banner --target=c2 "c2 pane\nsecond line\nthird line" | Out-Null
    & $exe +set-banner --target=c3 "c3 pane\nsecond line" | Out-Null

    # --- 1. three banners, one per pane ---------------------------------------
    $ok = Wait-Until { $b = @(Get-VisibleBanners $appPid | Sort-Object Height); ($b.Count -eq 3) -and ($b[0].Height -lt $b[1].Height) -and ($b[1].Height -lt $b[2].Height) }
    $banners = @(Get-VisibleBanners $appPid)
    Assert $ok "three banner popups on screen before the close (saw $($banners.Count))"
    if ($banners.Count -ne 3) { throw 'setup: three banners never appeared' }
    $mid = @($banners | Sort-Object Height)[-1]
    Assert ($mid.Height -gt @($banners | Sort-Object Height)[0].Height) "c2's three-line banner is the tallest ($($mid.Height) px)"
    # c2's column is its banner's span: the banner covers the pane's width.
    $colL = $mid.Left
    $colR = $mid.Right
    $c2Popups = @(Get-PopupsInColumn $appPid $colL $colR $mid.Top)
    $classes = ($c2Popups | ForEach-Object { $_.Class } | Sort-Object -Unique) -join ','
    $classes = @($c2Popups | ForEach-Object { $_.Class } | Sort-Object -Unique)
    $want = @('GhozttyBannerOverlay', 'GhozttyDimOverlay', 'GhozttyScrollbar')
    $missing = @($want | Where-Object { $classes -notcontains $_ })
    Assert ($missing.Count -eq 0) "c2 has a banner, a dim wash and a scrollbar on screen ($($classes -join ','); missing: $($missing -join ','))"

    if ($NegativeControl) {
        # The section-2 oracle, asked while c2 is still open: MUST fail.
        $script:negReached = $true
        $still = @($c2Popups | Where-Object { Test-HwndVisible $appPid $_.Hwnd })
        Assert ($still.Count -eq 0) "NEGATIVE CONTROL: c2's popups read hidden while c2 is open ($($still.Count) visible)"
    } else {
        # --- 2. +close c2: its popups go with it -----------------------------
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        & $exe +close --target=c2 | Out-Null
        $closeMs = $sw.ElapsedMilliseconds
        $still = @($c2Popups | Where-Object { Test-HwndVisible $appPid $_.Hwnd })
        $probeMs = $sw.ElapsedMilliseconds
        Assert ($still.Count -eq 0) "every c2 popup is hidden by the time +close answered ($closeMs ms; probed at $probeMs ms; still visible: $(($still | ForEach-Object { $_.Class }) -join ','))"
        Start-Sleep -Milliseconds 1000
        $still = @($c2Popups | Where-Object { Test-HwndVisible $appPid $_.Hwnd })
        Assert ($still.Count -eq 0) "and still hidden 1 s later ($($still.Count) visible)"
        $after = @(Get-VisibleBanners $appPid)
        Assert ($after.Count -eq 2) "two banners remain on screen (saw $($after.Count))"
        Assert (@($after | Where-Object { $_.Hwnd -eq $mid.Hwnd }).Count -eq 0) "the visible banners are not c2's"

        # --- 3. the pane was PARKED, not torn down ---------------------------
        Assert (Test-HwndExists $appPid $mid.Hwnd) "c2's banner HWND still exists (parked for undo, hidden) - the T2012 shape"

        # --- 4. +stash c3: same answer, for every popup ----------------------
        # c3's two-line banner is the taller of the two left.
        $c3Banner = @(Get-VisibleBanners $appPid | Sort-Object Height)[-1]
        $c3Popups = @(Get-PopupsInColumn $appPid $c3Banner.Left $c3Banner.Right $c3Banner.Top)
        $c3Bar = @($c3Popups | Where-Object { $_.Class -eq 'GhozttyScrollbar' }) | Select-Object -First 1
        Assert ($null -ne $c3Bar) "c3's scrollbar is on screen before the stash ($(($c3Popups | ForEach-Object { $_.Class }) -join ','))"
        & $exe +stash --target=c3 | Out-Null
        $hidden = Wait-Until { @($c3Popups | Where-Object { Test-HwndVisible $appPid $_.Hwnd }).Count -eq 0 } 300
        $still = @($c3Popups | Where-Object { Test-HwndVisible $appPid $_.Hwnd })
        Assert $hidden "+stash c3: every c3 popup leaves the screen at once (still visible: $(($still | ForEach-Object { $_.Class }) -join ','))"
        & $exe +restore --target=c3 | Out-Null
        $back = Wait-Until { Test-HwndVisible $appPid $c3Banner.Hwnd } 3000
        Assert $back "+restore c3: its banner comes back with it"
        if ($c3Bar) {
            $barBack = Wait-Until { Test-HwndVisible $appPid $c3Bar.Hwnd } 3000
            Assert $barBack "+restore c3: its scrollbar comes back with it"
        }

        # --- 5. +close the whole cw window: its panes' popups go with it -----
        # The launch window is still open, so the close PARKS cw for undo:
        # the window is hidden, and hiding a top-level does not hide the
        # popups its panes own. Every banner on screen now is cw's (the
        # launch window has none).
        $cwBanners = @(Get-VisibleBanners $appPid)
        Assert ($cwBanners.Count -eq 2) "setup: cw shows two banners before its window closes (saw $($cwBanners.Count))"
        & $exe +close --target=cw | Out-Null
        $goneW = Wait-Until { @($cwBanners | Where-Object { Test-HwndVisible $appPid $_.Hwnd }).Count -eq 0 } 300
        Assert $goneW "+close the cw window: every banner it showed leaves the screen at once"
        Assert (@($cwBanners | Where-Object { Test-HwndExists $appPid $_.Hwnd }).Count -eq $cwBanners.Count) "cw was parked for undo, not torn down (its banner HWNDs still exist)"
    }

    Assert (-not ($app.Process -and $app.Process.HasExited)) 'GUI process alive after all scenarios'
    Assert (-not (Test-TestDesktopLeak -ProcessId $appPid)) 'GUI never became visible on the interactive desktop'
} catch {
    $script:fail++
    Write-Host "FAIL  the run terminated: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "      at $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())"
} finally {
    Remove-TestDesktop
    Stop-RepoInstances
}

$fgSeen = @(Stop-TestForegroundWatch)
$leaked = @(Get-TestLaunchedPids | Where-Object { $fgSeen -contains $_ })
Assert ($leaked.Count -eq 0) "no test-desktop app ever became foreground on the interactive desktop (saw $($leaked -join ','))"

if ($NegativeControl -and -not $script:negReached) {
    Assert $false 'NEGATIVE CONTROL never reached its inverted assertion'
}

Complete-TestBody  # T1039: the last statement of the body an unwind can skip

# --- stamp (T783) ------------------------------------------------------------
if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard close-overlays -Repo $repo 2>&1 | ForEach-Object { Write-Host "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Skipped $script:skipped
