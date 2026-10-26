# T2186 acceptance: folding panes by dragging a divider SLIDES, as on Mac,
# instead of jumping in one step.
#
# THE CLAIM. Before T2186 a drag that folded a pane (T2124) went like this:
# the folding pane vanished on the spot, and the panes left on show held
# their old size for the whole slide and then snapped to the new one - a
# 490 -> 1000 px jump in one frame at the slide's end, with a gap of desk in
# between. Now (Mac `PaneStageView`; since T2268 its a81db68f9 follower):
#   - the folding pane slides to its tucked place at the stack's edge and is
#     hidden only when the slide is over
#   - a drag's slide is a resize slide: the panes on show pass through every
#     width between the old layout and the new one
#   - the pane windows are stacked in the layout's paint order, so the
#     folding pane slides UNDER the run, never across it
#
# Layout: P | s1 | s2 across a 1125 DIP window (T2295: five pane minimums of
# 225 DIP, the shape the old 1500 had at 300), the stack-collapse-drag.ps1
# shape. The root divider is dragged right past the fold point and HELD, with
# the slide stretched to 2 s (`GHOZTTY_STACK_SLIDE_MS`) so the sampler sees it
# in motion.
#
# Claims:
#   F1) s2, the folding pane, is on show and seen at 2+ positions strictly
#       between where it was and where it tucks: it slides away
#   F2) P's width is seen at 2+ widths strictly between its old and new ones,
#       and no one sample-to-sample step covers more than 60% of the change:
#       it grows through the slide, no single jump
#   F3) while both are on show mid-slide, s1 is above s2 in the window
#       z-order (the run is painted over the card tucking away)
#   F4) at rest the layout is the T2124 answer: two on show, s2 hidden
#   F5) dragging back unfolds s2 the same way: seen on show at 2+ positions
#       strictly between its tucked place and its slot
#   F6) at no sampled moment of the fold or the unfold does any popup the app
#       shows reach outside the window (T2227). The folding pane slides out to
#       its held rect past the window's right edge; the pane child is clipped
#       by the window, but its popups (the unfocused dim wash, painted in the
#       background colour) are not, and the user saw that wash bleed out over
#       the desktop mid-slide. P is focused first so s2 carries the wash.
#   F7) the dragged divider's accent bar stays over the gutter as it is
#       DRAWN (T2270; Mac `PaneStageView.shownGutter`): mid-glide it is seen
#       off its laid-out gutter at 2+ places, trailing the hand - short of the
#       laid-out gutter while P grows into the fold, past it while P shrinks
#       back on the unfold. Read from the debug build's `gutter bar gliding`
#       oracle line.
#   F8) the folding card NARROWS into its strip (T2287; Mac a81db68f9): mid-
#       glide s2's window is cut to its card (its window region), and that
#       card is seen at 2+ widths well short of s2's full width - not a
#       full-size card that slides off and vanishes at the end
#   F9) unfolding, s2's card widens out of its strip the same way: seen cut
#       to 2+ partial widths on its way back
#   F10) as s2's card narrows, the strip's face fades in over it (T2288; Mac
#       a81db68f9 `PaneCardView.collapse`): the face popup is seen on show,
#       at 2+ alphas strictly between none and all of it, rising - so the
#       content fades out as the title fades in. Read from the debug build's
#       `strip face alpha=` oracle line.
#   F11) unfolding, the face fades back out the same way: 2+ partial alphas,
#       falling
#   F12) at rest - folded, and unfolded again - no face is on show: the
#       window's own strip takes over, and a card on show wears none
#   F13) the face IS the strip's band (flat style): photographed mid-glide
#       through WM_PRINTCLIENT, its commonest pixel is the band the oracle
#       logged and covers most of it - not the pane's colour, not a hole
#
# -NegativeControl sets the slide to 0 ms (an instant re-layout, the answer
# before any slide) and keeps F1/F2/F7/F8/F10 as written: they MUST fail.
#
# Hermetic: per-run LOCALAPPDATA, per-run agent binary override, a private IPC
# pipe suffix, and it only ever kills ghoztty processes launched from this
# repo's zig-out. Runs on the BACKGROUND test desktop.
#
#   powershell -NoProfile -File test\win32\stack-fold-slide.ps1
param(
    [string]$ExePath,
    [string]$AgentExe,
    [switch]$NegativeControl,
    [ValidateSet('flat', 'elevated')][string]$PaneStyle = 'flat',
    [switch]$Interactive
)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }
$agent = Join-Path $repo 'zig-out\bin\ghoztty-agent.exe'
if ($AgentExe) { $agent = $AgentExe }

$script:pass = 0
$script:fail = 0
$root = Join-Path $env:TEMP "ghoztty-stack-fold-slide-$PID"
$script:errlog = Join-Path $root 'app-stderr.log'
$slideMs = if ($NegativeControl) { 0 } else { 2000 }

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\ChromeGeometry.ps1')

function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}
function Say($m) { Write-Host $m }

function Stop-RepoInstances { [void](Stop-RepoGhoztty -Exe $exe -SettleMs 700) }

$appArgs = @('--config-default-files=false', '--session-persistence=false', "--macos-pane-style=$PaneStyle")

function Start-App {
    $app = Start-OnTestDesktop -Exe $exe -Arguments $appArgs -StdErr $script:errlog
    if ((Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow') -eq [IntPtr]::Zero) {
        Write-TestAssertedNothing -Reason 'the app never opened a GhozttyWindow'
    }
    return $app
}

# Every pane window, in the order the system enumerates children (z-order,
# top first), each tagged with that index.
function Get-Panes([IntPtr]$top) {
    $i = 0
    return @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal' | ForEach-Object {
        $_ | Add-Member -NotePropertyName Z -NotePropertyValue $i -PassThru
        $i++
    })
}
function Get-VisiblePanes([IntPtr]$top) {
    return @(Get-Panes $top | Where-Object Visible | Sort-Object Left)
}
function Wait-Shown([IntPtr]$top, [int]$n, [int]$timeoutSec = 20) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    do {
        $v = @(Get-VisiblePanes $top)
        if ($v.Count -eq $n) { return $v }
        Start-Sleep -Milliseconds 300
    } while ((Get-Date) -lt $deadline)
    return @(Get-VisiblePanes $top)
}
function Format-Cols($cols) {
    return (($cols | Sort-Object Left | ForEach-Object { "$($_.Left)-$($_.Right)$(if (-not $_.Visible) { '(hidden)' })" }) -join ' | ')
}

# Move the held pointer to screen x in a few quick steps.
function Move-To([IntPtr]$top, [int]$fromX, [int]$toX, [int]$y) {
    $steps = 6
    for ($i = 1; $i -le $steps; $i++) {
        $x = [int]($fromX + ($toX - $fromX) * $i / $steps)
        [void](Send-TestMouse -Window $top -Target $top -X $x -Y $y -Action move -HoldMs 0)
        Start-Sleep -Milliseconds 30
    }
}

# T2227: every visible top-level the app shows other than the window itself
# that reaches outside the window's rect - a pane popup the window does not
# clip. One line each, for the failure message.
function Get-StrayPopups([int]$procId, [IntPtr]$top) {
    $w = Get-TestWindowRect -Window $top
    return @(Get-TestWindows -ProcessId $procId -Class '*' | Where-Object {
            $_.Visible -and $_.Hwnd -ne [int64]$top -and $_.Width -gt 0 -and $_.Height -gt 0 -and
            ($_.Left -lt $w.Left -or $_.Top -lt $w.Top -or $_.Right -gt $w.Right -or $_.Bottom -gt $w.Bottom)
        } | ForEach-Object { "$($_.Class) $($_.Left)-$($_.Right)" })
}

# How much of a pane window shows across its middle (T2287): its window
# region, probed every 4 px; the whole width when it has no region.
function Get-ShownWidth($pane) {
    $pts = New-Object System.Collections.Generic.List[int]
    $y = [int]($pane.Height / 2)
    for ($x = 2; $x -lt $pane.Width; $x += 4) { $pts.Add($x); $pts.Add($y) }
    if ($pts.Count -eq 0) { return 0 }
    $hits = Get-TestWindowRegionHits -Window ([IntPtr]$pane.Hwnd) -Points $pts.ToArray()
    if ($null -eq $hits) { return $pane.Width }
    return 4 * @($hits | Where-Object { $_ }).Count
}

# Sample every pane window (and any stray popup) for $ms milliseconds, with
# how much of $script:watchPane shows when it is on show.
function Get-Samples([IntPtr]$top, [int]$ms) {
    $out = New-Object System.Collections.Generic.List[object]
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $ms) {
        $panes = @(Get-Panes $top)
        $w = $null
        $q = Find-Pane $panes $script:watchPane
        if ($null -ne $q -and $q.Visible) { $w = [pscustomobject]@{ Width = $q.Width; Shown = (Get-ShownWidth $q) } }
        $faces = @(Get-TestWindows -ProcessId $script:appPid -Class 'GhozttyStripFace' | Where-Object Visible)
        # One photograph of the face mid-glide (F13); it may hide under us.
        if ($null -eq $script:faceShot -and $faces.Count -gt 0) {
            try { $script:faceShot = Get-TestWindowPixels -Window ([IntPtr]$faces[0].Hwnd) -Sync -AllowUniform -UniformTimeoutMs 0 } catch { }
        }
        $out.Add([pscustomobject]@{ Ms = $sw.ElapsedMilliseconds; Panes = $panes; Stray = @(Get-StrayPopups $script:appPid $top); Watch = $w; Faces = $faces.Count })
        Start-Sleep -Milliseconds 15
    }
    return $out
}
# The distinct partial widths $samples saw the watched pane cut to: shown,
# and narrower than 80% of its window.
function Get-PartialWidths($samples) {
    return @($samples | Where-Object { $null -ne $_.Watch -and $_.Watch.Shown -gt 0 -and $_.Watch.Shown -lt 0.8 * $_.Watch.Width } |
            ForEach-Object { $_.Watch.Shown } | Sort-Object -Unique)
}
# The `gutter bar gliding at X,Y laid out at X,Y` oracle lines (T2270) from
# line $from of the app's stderr on: each as drawn x and laid-out x.
function Get-GlidingBar([int]$from) {
    $lines = @(Get-Content -Path $script:errlog -ErrorAction SilentlyContinue)
    $out = @()
    for ($i = $from; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match 'gutter bar gliding at (-?\d+),(-?\d+) laid out at (-?\d+),(-?\d+)') {
            $out += [pscustomobject]@{ Shown = [int]$Matches[1]; Laid = [int]$Matches[3] }
        }
    }
    return $out
}
# The `strip face alpha=N band=RRGGBB` oracle lines (T2288) from line $from
# to line $to of the app's stderr: each as its alpha and band.
function Get-FaceAlphas([int]$from, [int]$to) {
    $lines = @(Get-Content -Path $script:errlog -ErrorAction SilentlyContinue)
    $out = @()
    for ($i = $from; $i -lt [math]::Min($to, $lines.Count); $i++) {
        if ($lines[$i] -match 'strip face alpha=(\d+) band=([0-9a-f]{6})') {
            $out += [pscustomobject]@{ Alpha = [int]$Matches[1]; Band = $Matches[2] }
        }
    }
    return $out
}
# The commonest colour of a capture (as RRGGBB) and its share of a sample grid.
function Get-TopColor($shot) {
    $hist = @{}
    $n = 0
    $sx = [math]::Max(1, [int]($shot.Width / 24))
    $sy = [math]::Max(1, [int]($shot.Height / 24))
    # pixel-region: the capture is the strip face popup alone, so the whole of it is the subject
    for ($y = 0; $y -lt $shot.Height; $y += $sy) {
        for ($x = 0; $x -lt $shot.Width; $x += $sx) {
            $c = '{0:x6}' -f ($shot.Bitmap.GetPixel($x, $y).ToArgb() -band 0xFFFFFF)
            $n++
            if ($hist.ContainsKey($c)) { $hist[$c]++ } else { $hist[$c] = 1 }
        }
    }
    $topKey = $null
    foreach ($k in $hist.Keys) { if ($null -eq $topKey -or $hist[$k] -gt $hist[$topKey]) { $topKey = $k } }
    return [pscustomobject]@{ Color = $topKey; Share = if ($n -gt 0) { $hist[$topKey] / $n } else { 0 } }
}
function Get-LogLength { return @(Get-Content -Path $script:errlog -ErrorAction SilentlyContinue).Count }
function Find-Pane($panes, [int64]$hwnd) {
    $m = @($panes | Where-Object { $_.Hwnd -eq $hwnd })
    if ($m.Count -eq 1) { return $m[0] }
    return $null
}
# The distinct Left edges of pane $hwnd, on show, strictly between $a and $b.
function Get-Between($samples, [int64]$hwnd, [int]$a, [int]$b) {
    $lo = [math]::Min($a, $b)
    $hi = [math]::Max($a, $b)
    $seen = @{}
    foreach ($s in $samples) {
        $q = Find-Pane $s.Panes $hwnd
        if ($null -eq $q -or -not $q.Visible) { continue }
        if ($q.Left -gt $lo -and $q.Left -lt $hi) { $seen[[int]$q.Left] = $true }
    }
    return @($seen.Keys | Sort-Object)
}

# -----------------------------------------------------------------------------

$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN
$savedPipe = $env:GHOZTTY_PIPE_SUFFIX
$savedSlide = $env:GHOZTTY_STACK_SLIDE_MS
$env:GHOZTTY_PIPE_SUFFIX = "-foldslide$PID"
$env:GHOZTTY_STACK_SLIDE_MS = "$slideMs"

Stop-RepoInstances
New-Item -ItemType Directory -Force $root | Out-Null
$tmp = Join-Path $root 'app'
New-Item -ItemType Directory -Force (Get-GhozttyAgentStateDir -Root $tmp) | Out-Null
$env:LOCALAPPDATA = $tmp
$env:GHOSTTY_LOCAL_AGENT_BIN = $agent

Reset-TestBody
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$script:faceShot = $null

try {
    Assert (Test-Path $exe) 'ghoztty exe exists in zig-out'
    Assert (Test-Path $agent) 'ghoztty-agent exe exists in zig-out'
    [void](Assert-GhozttyIsolatedBuild -Exe $exe)
    if ($NegativeControl) {
        Say 'NEGATIVE CONTROL: the slide is 0 ms (an instant re-layout) - F1/F2 MUST fail'
    }

    # ---- setup: P | s1 | s2 ----------------------------------------------------
    # T2295: the row is sized from the pane minimum (225 DIP since T2284), so
    # P | s1 | s2 fits and the drag below folds s2 where it says it does.
    $minDip = 225
    $winDip = 5 * $minDip
    Say "== setup: P | s1 | s2, $winDip DIP wide, slide $slideMs ms"
    $app = Start-App
    $script:appPid = [int]$app.Pid
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    Start-Sleep -Milliseconds 800
    $dpi = [int](Get-TestWindowDpi -Window $top)
    if ($dpi -le 0) { $dpi = 96 }
    $scale = $dpi / 96.0
    [void](Set-TestWindowPos -Window $top -X 0 -Y 0 -Width (Get-TestChromeDip -Dip $winDip -Scale $scale) -Height (Get-TestChromeDip -Dip 700 -Scale $scale))
    Start-Sleep -Seconds 2
    & $exe +split --direction=right --name=s1 | Out-Null
    Start-Sleep -Milliseconds 800
    & $exe +split --pane=s1 --direction=right --name=s2 | Out-Null
    $c3 = @(Wait-Shown $top 3)
    if ($c3.Count -ne 3) { Write-TestAssertedNothing -Reason "three columns never came up (got $($c3.Count))" }
    Start-Sleep -Milliseconds 800
    $c3 = @(Get-VisiblePanes $top)
    $hP = $c3[0].Hwnd
    $hS1 = $c3[1].Hwnd
    $hS2 = $c3[2].Hwnd
    $script:watchPane = [int64]$hS2
    $pW0 = $c3[0].Width
    $s2Left0 = $c3[2].Left
    Say ("      dpi {0}; columns: {1}" -f $dpi, (Format-Cols $c3))

    $gridLeft = $c3[0].Left
    $gridW = $c3[2].Right - $c3[0].Left
    $x0 = [int](($c3[0].Right + $c3[1].Left) / 2)
    $y = [int](($c3[0].Top + $c3[0].Bottom) / 2)
    # 1000/1500 is past the fold point; 850/1500 is short of it, where the
    # drag has only resized. Since T2263 (Mac a81db68f9) the fold point is where
    # s1 and s2 stop fitting at their minimums: the row less two minimums and
    # a gutter, ~891/1500 of it in the flat style - no 48 DIP past it any
    # more, so the old 900/1500 approach had already started the fold.
    # Derived from the minimum rather than as fractions of the row (T2295):
    # the row starts after the sidebar, a fixed width the fractions ignore.
    $gutter = $c3[1].Left - $c3[0].Right
    $foldAt = $c3[2].Right - 2 * (Get-TestChromeDip -Dip $minDip -Scale $scale) - $gutter
    $xFold = [int]($foldAt + (Get-TestChromeDip -Dip 100 -Scale $scale))
    $xNear = [int]($foldAt - (Get-TestChromeDip -Dip 40 -Scale $scale))
    Say ("      fold point ~{0} px; approach to {1}, fold at {2}" -f $foldAt, $xNear, $xFold)

    # Focus P, so s2 - the pane that folds - is an unfocused pane and carries
    # the dim wash whose bleed T2227 is about.
    [void](Send-TestMouse -Window $top -Target $top -X ([int](($c3[0].Left + $c3[0].Right) / 2)) -Y $y -Action click)
    Start-Sleep -Milliseconds 600
    $washes = @(Get-TestWindows -ProcessId $app.Pid -Class 'GhozttyDimOverlay' | Where-Object Visible)
    Say ("      P focused; {0} dim wash(es) on show" -f $washes.Count)
    # Glass panes never dim (T2281, Mac 9da9618f8): there F6 still checks
    # every popup, but has no wash to check.
    if ($PaneStyle -eq 'flat') {
        Assert ($washes.Count -ge 2) "F6 precondition: with P focused, s1 and s2 carry the dim wash ($($washes.Count) on show)"
    } else {
        Assert ($washes.Count -eq 0) "F6 precondition: glass panes carry no dim wash (T2281) ($($washes.Count) on show)"
    }

    # ---- the fold, held, sampled ---------------------------------------------
    Say '== drag the root divider up to the fold point, then over it in one move, and hold'
    [void](Send-TestMouse -Window $top -Target $top -X $x0 -Y $y -Action down -HoldMs 0)
    Start-Sleep -Milliseconds 150
    Move-To $top $x0 $xNear $y
    Start-Sleep -Milliseconds 400
    # The baseline is the layout the hand made before the fold: what moves
    # after this is the fold's doing.
    $near = @(Get-VisiblePanes $top)
    if ($near.Count -ne 3) { Write-TestAssertedNothing -Reason "the approach already folded ($($near.Count) on show at 850/1500)" }
    # Three on show is not enough: a fold already under way still shows s2
    # mid-slide, on its way past the grid's right edge.
    if ($near[2].Right -gt $c3[2].Right + 2) { Write-TestAssertedNothing -Reason "the approach already started the fold (s2 at $($near[2].Left)-$($near[2].Right), grid ends at $($c3[2].Right))" }
    $pW0 = (Find-Pane $near $hP).Width
    $s2Left0 = (Find-Pane $near $hS2).Left
    Say ("      short of the fold: {0}" -f (Format-Cols $near))
    $logFold = Get-LogLength
    [void](Send-TestMouse -Window $top -Target $top -X $xFold -Y $y -Action move -HoldMs 0)
    $fold = @(Get-Samples $top ($slideMs + 1000))
    $logBack = Get-LogLength
    $rest = @(Get-Panes $top)
    $pEnd = Find-Pane $rest $hP
    $s2End = Find-Pane $rest $hS2
    Say ("      {0} samples; at rest: {1}" -f $fold.Count, (Format-Cols $rest))

    # F1: s2 slides away.
    $s2Tuck = if ($s2End) { $s2End.Left } else { $s2Left0 }
    $s2Between = @(Get-Between $fold $hS2 $s2Left0 $s2Tuck)
    Say ("      s2 {0} -> {1}; on show between: {2}" -f $s2Left0, $s2Tuck, ($s2Between -join ', '))
    Assert ([math]::Abs($s2Tuck - $s2Left0) -gt (Get-TestChromeDip -Dip 40 -Scale $scale)) "F1: s2 tucks a real distance away ($s2Left0 -> $s2Tuck px)"
    Assert ($s2Between.Count -ge 2) "F1: s2 is seen on show at $($s2Between.Count) positions on its way to the edge (need 2+): it slides away, it does not vanish"

    # F2: P grows through the slide.
    $pW1 = if ($pEnd) { $pEnd.Width } else { $pW0 }
    $widths = New-Object System.Collections.Generic.List[int]
    $widths.Add($pW0)
    foreach ($s in $fold) {
        $q = Find-Pane $s.Panes $hP
        if ($null -ne $q -and $q.Visible -and $q.Width -ne $widths[$widths.Count - 1]) { $widths.Add($q.Width) }
    }
    $lo = [math]::Min($pW0, $pW1)
    $hi = [math]::Max($pW0, $pW1)
    $mid = @($widths | Where-Object { $_ -gt $lo -and $_ -lt $hi } | Sort-Object -Unique)
    $bigStep = 0
    for ($i = 1; $i -lt $widths.Count; $i++) { $bigStep = [math]::Max($bigStep, [math]::Abs($widths[$i] - $widths[$i - 1])) }
    $span = [math]::Max(1, $hi - $lo)
    Say ("      P width {0} -> {1}; path: {2}" -f $pW0, $pW1, ($widths -join ' > '))
    Assert ($span -gt (Get-TestChromeDip -Dip 100 -Scale $scale)) "F2: P grows a real amount ($pW0 -> $pW1 px)"
    Assert ($mid.Count -ge 2) "F2: P is seen at $($mid.Count) widths on the way (need 2+): it grows through the slide"
    Assert ($bigStep -le 0.6 * $span) "F2: no single step covers most of the change (largest $bigStep of $span px)"

    # F3: the run over the card tucking away.
    $both = 0
    $s1Above = 0
    foreach ($s in $fold) {
        $a = Find-Pane $s.Panes $hS1
        $b = Find-Pane $s.Panes $hS2
        if ($null -eq $a -or $null -eq $b -or -not $a.Visible -or -not $b.Visible) { continue }
        if ($b.Left -le $s2Left0 -or $b.Left -ge $s2Tuck) { continue }
        $both++
        if ($a.Z -lt $b.Z) { $s1Above++ }
    }
    if ($NegativeControl) {
        Say "      (negative control: $both mid-slide samples)"
    } else {
        Assert ($both -ge 1 -and $s1Above -eq $both) "F3: mid-slide, s1 is above s2 in the z-order ($s1Above of $both samples)"
    }

    # F6: nothing the app shows bleeds out of the window mid-fold.
    $strayFold = @($fold | Where-Object { $_.Stray.Count -gt 0 })
    $firstFold = if ($strayFold.Count -gt 0) { "at $($strayFold[0].Ms) ms: $($strayFold[0].Stray -join ' | ')" } else { '' }
    Assert ($strayFold.Count -eq 0) "F6: no popup reaches outside the window during the fold ($($strayFold.Count) of $($fold.Count) samples) $firstFold"

    # F7: the bar follows P's edge as it is drawn, short of the hand.
    $barFold = @(Get-GlidingBar $logFold | Where-Object { $_.Shown -lt $_.Laid })
    $barFoldAt = @($barFold | ForEach-Object Shown | Sort-Object -Unique)
    Say ("      bar drawn short of its gutter at: {0}" -f ($barFoldAt -join ', '))
    Assert ($barFoldAt.Count -ge 2) "F7: folding, the dragged bar is drawn at $($barFoldAt.Count) places short of its laid-out gutter (need 2+): it stays with the gliding card"

    # F8: the folding card narrows into its strip (T2287).
    $narrow = @(Get-PartialWidths $fold)
    Say ("      s2 cut to its narrowing card at: {0} px" -f ($narrow -join ', '))
    Assert ($narrow.Count -ge 2) "F8: folding, s2 is seen cut to $($narrow.Count) partial widths (need 2+): its card narrows into the strip, it does not slide off full size"

    # F10: the strip's face fades in over the narrowing card (T2288).
    $fadeIn = @(Get-FaceAlphas $logFold $logBack)
    $inMid = @($fadeIn | Where-Object { $_.Alpha -gt 0 -and $_.Alpha -lt 255 } | ForEach-Object Alpha | Sort-Object -Unique)
    $faceSeen = @($fold | Where-Object { $_.Faces -gt 0 }).Count
    Say ("      face alphas folding: {0}; face on show in {1} of {2} samples" -f (($fadeIn | ForEach-Object Alpha) -join ' > '), $faceSeen, $fold.Count)
    Assert ($faceSeen -ge 1) "F10: folding, the strip's face is seen on show over s2's card ($faceSeen samples)"
    Assert ($inMid.Count -ge 2) "F10: folding, the face is drawn at $($inMid.Count) partial alphas (need 2+): the title fades in as the content fades out"
    if ($fadeIn.Count -ge 2) {
        Assert ($fadeIn[-1].Alpha -gt $fadeIn[0].Alpha) "F10: folding, the face's alpha rises ($($fadeIn[0].Alpha) -> $($fadeIn[-1].Alpha))"
    }
    $facesFolded = @(Get-TestWindows -ProcessId $app.Pid -Class 'GhozttyStripFace' | Where-Object Visible).Count
    Assert ($facesFolded -eq 0) "F12: folded and at rest, no face is on show ($facesFolded): the window's strip has taken over"

    # F4: the T2124 layout at rest.
    $shown = @($rest | Where-Object Visible)
    Assert ($shown.Count -eq 2) "F4: at rest two panes are on show (got $($shown.Count))"
    Assert ($null -ne $s2End -and -not $s2End.Visible) 'F4: s2 is hidden once its slide is over'

    # ---- the unfold, still held, sampled ---------------------------------------
    Say '== drag back to the start, still held'
    # One move, as the fold: stepped, the unfold began mid-steps and most of
    # its widening was over before the sampler started (T2287's F9).
    [void](Send-TestMouse -Window $top -Target $top -X $x0 -Y $y -Action move -HoldMs 0)
    $back = @(Get-Samples $top ($slideMs + 1000))
    $logEnd = Get-LogLength
    $facesAtRest = @(Get-TestWindows -ProcessId $app.Pid -Class 'GhozttyStripFace' | Where-Object Visible).Count
    $again = @(Get-Panes $top)
    $s2Back = Find-Pane $again $hS2
    $s2Home = if ($s2Back) { $s2Back.Left } else { $s2Tuck }
    $s2Coming = @(Get-Between $back $hS2 $s2Tuck $s2Home)
    Say ("      s2 {0} -> {1}; on show between: {2}; at rest: {3}" -f $s2Tuck, $s2Home, ($s2Coming -join ', '), (Format-Cols $again))
    $widen = @(Get-PartialWidths $back)
    Say ("      s2 cut to its widening card at: {0} px" -f ($widen -join ', '))
    if (-not $NegativeControl) {
        Assert ($s2Coming.Count -ge 2) "F5: unfolding, s2 is seen at $($s2Coming.Count) positions on its way back (need 2+)"
        Assert ($widen.Count -ge 2) "F9: unfolding, s2 is seen cut to $($widen.Count) partial widths (need 2+): its card widens out of the strip"
    }
    $barBack = @(Get-GlidingBar $logBack | Where-Object { $_.Shown -gt $_.Laid })
    $barBackAt = @($barBack | ForEach-Object Shown | Sort-Object -Unique)
    Say ("      bar drawn past its gutter at: {0}" -f ($barBackAt -join ', '))
    if (-not $NegativeControl) {
        Assert ($barBackAt.Count -ge 2) "F7: unfolding, the dragged bar is drawn at $($barBackAt.Count) places past its laid-out gutter (need 2+)"
    }
    # F11: the face fades back out as the card widens.
    $fadeOut = @(Get-FaceAlphas $logBack $logEnd)
    $outMid = @($fadeOut | Where-Object { $_.Alpha -gt 0 -and $_.Alpha -lt 255 } | ForEach-Object Alpha | Sort-Object -Unique)
    Say ("      face alphas unfolding: {0}" -f (($fadeOut | ForEach-Object Alpha) -join ' > '))
    if (-not $NegativeControl) {
        Assert ($outMid.Count -ge 2) "F11: unfolding, the face is drawn at $($outMid.Count) partial alphas (need 2+): the title fades out as the content comes back"
        if ($fadeOut.Count -ge 2) {
            Assert ($fadeOut[-1].Alpha -lt $fadeOut[0].Alpha) "F11: unfolding, the face's alpha falls ($($fadeOut[0].Alpha) -> $($fadeOut[-1].Alpha))"
        }
    }
    Assert ($facesAtRest -eq 0) "F12: unfolded and at rest, no face is on show ($facesAtRest)"

    # F13: the face's pixels are the strip's band (flat: one solid band).
    if ($PaneStyle -eq 'flat' -and -not $NegativeControl) {
        $bands = @(@($fadeIn) + @($fadeOut) | ForEach-Object Band | Sort-Object -Unique)
        if ($null -eq $script:faceShot) {
            Assert $false 'F13: the face was photographed mid-glide (no capture landed)'
        } else {
            $tc = Get-TopColor $script:faceShot
            Say ("      face photo {0}x{1}: top colour {2} ({3:p0}); logged bands {4}" -f $script:faceShot.Width, $script:faceShot.Height, $tc.Color, $tc.Share, ($bands -join ', '))
            Assert ($bands -contains $tc.Color) "F13: the face's commonest pixel $($tc.Color) is the strip band the face logged ($($bands -join ', '))"
            Assert ($tc.Share -ge 0.6) "F13: the band covers most of the face ($([math]::Round($tc.Share * 100))%)"
            Close-TestWindowPixels -Shot $script:faceShot
        }
    }

    $strayBack = @($back | Where-Object { $_.Stray.Count -gt 0 })
    $firstBack = if ($strayBack.Count -gt 0) { "at $($strayBack[0].Ms) ms: $($strayBack[0].Stray -join ' | ')" } else { '' }
    Assert ($strayBack.Count -eq 0) "F6: no popup reaches outside the window during the unfold ($($strayBack.Count) of $($back.Count) samples) $firstBack"

    Assert (@($again | Where-Object Visible).Count -eq 3) "F5: all the way back, three on show ($(@($again | Where-Object Visible).Count))"
    [void](Send-TestMouse -Window $top -Target $top -X $x0 -Y $y -Action up -HoldMs 0)
    Start-Sleep -Milliseconds 400

    Complete-TestBody
} catch {
    $script:fail++
    Say "FAIL  script terminated: $($_.Exception.Message)"
    Say "      at $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())"
} finally {
    Say '== cleanup'
    foreach ($r in @($script:GhozttyTestDesktopLaunches)) { if ($r) { $r.Killed = $true } }
    Remove-TestDesktop
    Stop-RepoInstances
    $env:LOCALAPPDATA = $savedLocalAppData
    if ($null -ne $savedAgentBin) { $env:GHOSTTY_LOCAL_AGENT_BIN = $savedAgentBin }
    else { Remove-Item env:GHOSTTY_LOCAL_AGENT_BIN -ErrorAction SilentlyContinue }
    $env:GHOZTTY_PIPE_SUFFIX = $savedPipe
    if ($null -ne $savedSlide) { $env:GHOZTTY_STACK_SLIDE_MS = $savedSlide }
    else { Remove-Item env:GHOZTTY_STACK_SLIDE_MS -ErrorAction SilentlyContinue }
    if ($script:fail -eq 0) { Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue }
    else { Say "artifacts preserved at $root" }
}

$fgSeen = @(Stop-TestForegroundWatch)
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @(Get-TestLaunchedPids)
    Assert ($fgSeen.Count -gt 0) 'Z1 the foreground watcher actually sampled (negative control)'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'Z2 no test-desktop app ever became foreground on the interactive desktop'
}

if ($script:fail -eq 0 -and -not $NegativeControl -and $PaneStyle -eq 'flat') {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard stack-fold-slide -Repo $repo 2>&1 | ForEach-Object { Say "  $_" }
}

Say ''
Write-TestVerdict -Label 'T2186 STACK FOLD SLIDE' -Pass $script:pass -Fail $script:fail
