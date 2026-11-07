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
#   6. The composition path (T2748): a second launch with the panes presenting
#      through their composition swap chains - the default once T2514 flips
#      it. There the banner, dim wash, scrollbar and bell border are child
#      visuals of the pane window's own composition target (T2467/T2491/
#      T2559), not popups, so they cannot outlive the pane window on screen:
#      what is asserted is that the three banners go up as visuals with no
#      overlay popup anywhere, and that +close c2 / +close cw hide the pane
#      windows that carry them by the time +close answers. Sections 1-5 pin
#      GHOZTTY_COMP_PRESENT=0: they are the popup path, which still serves
#      viewer panes, the opt-out and machines with no GL/D3D interop.
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
    # Sections 1-5 are the popup path; explicit, so the default flip (T2514)
    # does not change what they mean.
    $env:GHOZTTY_COMP_PRESENT = '0'
    try { $app = Start-OnTestDesktop -Exe $exe -Arguments @('--session-persistence=false', '--undo-timeout=20s', '--macos-pane-glass=false') }
    finally { Remove-Item env:GHOZTTY_COMP_PRESENT -ErrorAction SilentlyContinue }
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
    & $exe +split --pane=c2 --direction=right --name=c3 | Out-Null
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

    if (-not $NegativeControl) {
        # --- 6. the composition path: the overlays are the pane's visuals ----
        Stop-RepoInstances
        $log6 = Join-Path $env:TEMP "ghoztty-close-overlays-comp-$PID.log"
        Remove-Item $log6 -ErrorAction SilentlyContinue
        $env:GHOZTTY_COMP_PRESENT = '1'
        try { $app = Start-OnTestDesktop -Exe $exe -StdErr $log6 -Arguments @('--session-persistence=false', '--undo-timeout=20s', '--macos-pane-glass=false') }
        finally { Remove-Item env:GHOZTTY_COMP_PRESENT -ErrorAction SilentlyContinue }
        Start-Sleep -Seconds 3
        $appPid = $app.Pid
        if ((Wait-TestWindow -ProcessId $appPid -Class 'GhozttyWindow') -eq [IntPtr]::Zero) { throw 'comp setup: no GhozttyWindow' }
        & $exe +new-window --target=cw | Out-Null
        $cw = $null
        for ($t = 0; $t -lt 25 -and -not $cw; $t++) { $cw = Get-Win 'cw'; if (-not $cw) { Start-Sleep -Milliseconds 200 } }
        if (-not $cw) { throw 'comp setup: cw window not registered' }
        foreach ($w in @(Get-TestWindows -ProcessId $appPid -Class 'GhozttyWindow')) {
            $dpi = Get-TestWindowDpi -Window ([IntPtr]$w.Hwnd)
            $scale = if ($dpi -gt 0) { $dpi / 96.0 } else { 1.0 }
            [void](Set-TestWindowSize -Window ([IntPtr]$w.Hwnd) -Width ([int][math]::Round(1300 * $scale, [MidpointRounding]::AwayFromZero)) -Height ([int][math]::Round(700 * $scale, [MidpointRounding]::AwayFromZero)))
        }
        & $exe +split --target=cw --direction=right --name=c2 | Out-Null
        & $exe +split --pane=c2 --direction=right --name=c3 | Out-Null
        & $exe +set-banner --target=cw 'left pane' | Out-Null
        & $exe +set-banner --target=c2 "c2 pane\nsecond line\nthird line" | Out-Null
        & $exe +set-banner --target=c3 "c3 pane\nsecond line" | Out-Null
        $three = Wait-Until { @(Get-Content $log6 -ErrorAction SilentlyContinue | Where-Object { $_ -match 'banner shown as visual' }).Count -ge 3 } 8000
        Assert ([bool](Select-String -Path $log6 -Pattern 'pane presents through a composition swap chain' -Quiet)) 'comp: the panes present through the composition chain (log)'
        Assert $three "comp: the three banners went up as visuals (log)"
        # Every overlay is a visual here except the unfocused panes' dim wash:
        # over a banner pane it stays the popup on this path too (it has to
        # cover the band - comp-present.ps1 F4), so section 2's rule still
        # applies to it and is asserted for c2's below.
        $pop = @(@(Get-OverlayPopups $appPid) | Where-Object { $_.Visible -and $_.Class -ne 'GhozttyDimOverlay' })
        Assert ($pop.Count -eq 0) "comp: no overlay popup but the banner panes' dim washes is on screen ($(($pop | ForEach-Object { $_.Class }) -join ','))"
        # cw is the top-level holding three panes. Which one is c2 comes from
        # the split tree's left-to-right leaf order, never from a position
        # guess. c3 is split off with --pane=c2: --target=c2 would name c2's
        # WINDOW and split its active pane (cw - CLI splits open in the
        # background), which is the documented contract on both platforms
        # and built cw|c3|c2 here twice (T2753, docs/claude/cli.md +split).
        $cwTop = $null; $panes = @()
        foreach ($w in @(Get-TestWindows -ProcessId $appPid -Class 'GhozttyWindow')) {
            $kids = @(Get-TestChildWindows -Window ([IntPtr]$w.Hwnd) -Class 'GhozttyTerminal' | Where-Object Visible | Sort-Object Left)
            if ($kids.Count -eq 3) { $cwTop = [IntPtr]$w.Hwnd; $panes = $kids }
        }
        $script:leafNames = @()
        function Add-Leaves($node) {
            if ($null -eq $node) { return }
            if ($node.type -eq 'leaf') { $script:leafNames += $node.terminal.name; return }
            Add-Leaves $node.left; Add-Leaves $node.right
        }
        $cwNow = Get-Win 'cw'
        if ($cwNow) { Add-Leaves $cwNow.tabs[0].splits }
        $c2i = [array]::IndexOf([string[]]$script:leafNames, 'c2')
        Assert ($null -ne $cwTop -and $script:leafNames.Count -eq 3 -and $c2i -ge 0) "comp: setup: cw shows three panes side by side, c2 among them (leaves: $($script:leafNames -join ','))"
        # The window's own first pane carries no name (+list shows its id), so
        # the order is: that pane, then c2, then c3.
        Assert ($script:leafNames.Count -eq 3 -and $script:leafNames[0] -notin @('c2', 'c3') -and $script:leafNames[1] -eq 'c2' -and $script:leafNames[2] -eq 'c3') "comp: setup: --pane=c2 put c3 beside c2, leaf order <cw's pane>,c2,c3 (leaves: $($script:leafNames -join ','))"
        if ($null -ne $cwTop -and $script:leafNames.Count -eq 3 -and $c2i -ge 0) {
            $c2 = $panes[$c2i]
            $c2h = [int64]$c2.Hwnd
            $c2Dims = @(@(Get-OverlayPopups $appPid) | Where-Object {
                $_.Visible -and $_.Class -eq 'GhozttyDimOverlay' -and ((($_.Left + $_.Right) / 2) -ge $c2.Left) -and ((($_.Left + $_.Right) / 2) -lt $c2.Right) })
            $paneVisible = { param($h) @(Get-TestChildWindows -Window $cwTop -Class 'GhozttyTerminal' | Where-Object { $_.Hwnd -eq $h -and $_.Visible }).Count -gt 0 }
            & $exe +close --target=c2 | Out-Null
            Assert (-not (& $paneVisible $c2h)) "comp: c2's pane window - its banner, scrollbar and bell visuals with it - is hidden by the time +close answered"
            $stillDim = @($c2Dims | Where-Object { Test-HwndVisible $appPid $_.Hwnd })
            Assert ($stillDim.Count -eq 0) "comp: c2's dim wash popup is hidden by then too ($($c2Dims.Count) before, $($stillDim.Count) still visible)"
            Start-Sleep -Milliseconds 1000
            Assert (-not (& $paneVisible $c2h)) 'comp: and still hidden 1 s later'
            $stillDim = @($c2Dims | Where-Object { Test-HwndVisible $appPid $_.Hwnd })
            $pop = @(@(Get-OverlayPopups $appPid) | Where-Object { $_.Visible -and $_.Class -ne 'GhozttyDimOverlay' })
            Assert ($stillDim.Count -eq 0 -and $pop.Count -eq 0) "comp: c2's wash stayed hidden and no other overlay popup appeared over the gap ($(($pop | ForEach-Object { $_.Class }) -join ','))"
            & $exe +close --target=cw | Out-Null
            $goneW = Wait-Until { @(Get-TestWindows -ProcessId $appPid -Class 'GhozttyWindow' | Where-Object { [int64]$_.Hwnd -eq $cwTop.ToInt64() }).Count -eq 0 } 300
            Assert $goneW 'comp: +close the cw window: the window carrying the other two banners leaves the screen at once'
        }
        Assert (-not ($app.Process -and $app.Process.HasExited)) 'comp: GUI process alive'
        Remove-Item $log6 -ErrorAction SilentlyContinue
    }
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
