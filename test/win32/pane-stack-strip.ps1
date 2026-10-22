# T2109 acceptance: a pane tucked into a stack shows as a titled strip, the
# strip is named by the pane's banner title (live on +set-banner), and a click
# on the strip brings that pane on show and focuses it.
#
# THE CLAIM. T2108 made a row that cannot fit at 300 DIP a pane show a run and
# TUCK the rest - hidden, with nothing painted where they were. The window now
# paints each tucked pane's strip (`Window.paintStackStrips`, Mac
# `PaneStackTabView`): the pane's own background darkened (Mac's 35% toward
# black at 82% on a dark theme, `pane_stack_strip.stripRgb`) down the card's
# leading edge, with the pane's name along it - the banner's title first
# (`pane_sidebar.paneLabel`, T2085).
#
# Layout: P | (s1 | (s2 | s3)) at 900 DIP wide, the T2108 shape: two on show,
# two tucked.
#
# Claims:
#   D1) every tucked pane's leading edge is painted in the strip colour the
#       default background (#282c34) gives, a band at least 8 DIP wide
#   D2) the strip's label follows the banner title: a long `## ...` title set
#       with +set-banner runs further down the strip than a short one
#   D3) a click on a tucked pane's strip brings that pane on show (its window
#       visible), keeps two on show, and focuses it (+list --json)
#   D4) T2120: a strip pressed and dragged over the middle of a card on show
#       does nothing - same tree order, same focus (a press that travelled is
#       not the D3 click)
#   D5) T2120: a strip dropped in a gap between two other items of its row
#       moves the pane there (tree order from +list), same HWND
#   D6) T2120: a strip dropped at the screen's right edge opens a window of
#       its own over the right half of the work area, holding that pane
#
# -NegativeControl inverts D1 to "the leading edge is NOT the strip colour" -
# the answer before T2109, when nothing was painted there - and MUST fail.
#
# Hermetic: per-run LOCALAPPDATA, per-run agent binary override, a private IPC
# pipe suffix, and it only ever kills ghoztty processes launched from this
# repo's zig-out. Runs on the BACKGROUND test desktop.
#
#   powershell -NoProfile -File test\win32\pane-stack-strip.ps1
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
$root = Join-Path $env:TEMP "ghoztty-pane-stack-strip-$PID"

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
    $app = Start-OnTestDesktop -Exe $exe -Arguments $appArgs
    if ((Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow') -eq [IntPtr]::Zero) {
        Write-TestAssertedNothing -Reason 'the app never opened a GhozttyWindow'
    }
    return $app
}

function Get-Panes([IntPtr]$top) {
    return @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal' | Sort-Object Left)
}
function Get-VisiblePanes([IntPtr]$top) {
    return @(Get-Panes $top | Where-Object Visible)
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
    return (($cols | ForEach-Object { "$($_.Left)-$($_.Right)$(if (-not $_.Visible) { '(hidden)' })" }) -join ' | ')
}

function List-Json { (& $exe +list --json 2>$null | Out-String) | ConvertFrom-Json }
function Walk-Focused($node) {
    if ($null -eq $node) { return $null }
    if ($node.type -eq 'leaf') {
        if ($node.terminal.focused) { return $node.terminal.name }
        return $null
    }
    $l = Walk-Focused $node.left
    if ($null -ne $l) { return $l }
    return Walk-Focused $node.right
}
function Focused-Pane-Name {
    $j = List-Json
    foreach ($tab in @($j.data.windows[0].tabs | ForEach-Object { $_ })) {
        if (-not $tab.selected) { continue }
        return (Walk-Focused $tab.splits)
    }
    return $null
}

# Mac's strip over a pane of background `bg`, as `pane_stack_strip.stripRgb`
# resolves it: 35% toward black (dark theme), laid at 82% over the pane.
function Get-ExpectedStrip([int[]]$bg) {
    return @($bg | ForEach-Object {
        $base = [math]::Round($_ * 0.65)
        [int][math]::Round($_ * 0.18 + $base * 0.82)
    })
}
function Test-Near($c, [int[]]$rgb, [int]$tol = 4) {
    if ($null -eq $c) { return $false }
    return ([math]::Abs($c.R - $rgb[0]) -le $tol -and [math]::Abs($c.G - $rgb[1]) -le $tol -and [math]::Abs($c.B - $rgb[2]) -le $tol)
}

function Get-Shot([IntPtr]$top) { return Get-TestWindowPixels -Window $top -Sync }

# The strip of tucked pane `$p` in `$shot`: its width along a row near the top
# of the card (above where any label is), and the strip colour there.
function Measure-Strip($shot, $p) {
    $y = $p.Top + 4
    $c0 = Get-TestPixel -Shot $shot -X ($p.Left + 2) -Y $y
    $w = 0
    if ($null -ne $c0) {
        $rgb = @([int]$c0.R, [int]$c0.G, [int]$c0.B)
        for ($x = $p.Left; $x -lt $p.Right; $x++) {
            if (-not (Test-Near (Get-TestPixel -Shot $shot -X $x -Y $y) $rgb 6)) { break }
            $w++
        }
    }
    return [pscustomobject]@{ Color = $c0; Width = $w }
}

# How far down the strip its label runs: the rows (first to last) holding a
# pixel well away from the strip colour, within the strip's band.
function Measure-Ink($shot, $p, [int]$width, [int[]]$strip) {
    $first = -1; $last = -1
    for ($y = $p.Top; $y -lt $p.Bottom; $y++) {
        for ($x = $p.Left + 1; $x -lt ($p.Left + $width - 1); $x++) {
            $c = Get-TestPixel -Shot $shot -X $x -Y $y
            if ($null -eq $c) { continue }
            $d = [math]::Abs($c.R - $strip[0]) + [math]::Abs($c.G - $strip[1]) + [math]::Abs($c.B - $strip[2])
            if ($d -gt 90) {
                if ($first -lt 0) { $first = $y }
                $last = $y
                break
            }
        }
    }
    if ($first -lt 0) { return 0 }
    return $last - $first + 1
}

# The row's items as a strip drag sees them (T2120, `Window.bladeGeometry`),
# in tree order: a pane on show is its card, a tucked one its strip. Lead and
# Trail are the item's left and right edges, in screen pixels.
function Get-StripRow([IntPtr]$top, $nameOf) {
    $panes = @(Get-Panes $top)
    $shot = Get-Shot $top
    try {
        $order = Get-LeafOrder
        $out = @()
        foreach ($n in $order) {
            $p = @($panes | Where-Object { $nameOf[$_.Hwnd] -eq $n })[0]
            if ($null -eq $p) { continue }
            $w = if ($p.Visible) { $p.Right - $p.Left } else { (Measure-Strip $shot $p).Width }
            $out += [pscustomobject]@{
                Name = $n; Hwnd = $p.Hwnd; Visible = $p.Visible
                Left = $p.Left; Top = $p.Top; Right = $p.Right; Bottom = $p.Bottom
                StripW = $w; Lead = $p.Left; Trail = $p.Left + $w
            }
        }
        return $out
    } finally { Close-TestWindowPixels -Shot $shot }
}

# The selected tab's panes in tree order, by name ('P' for the first one).
function Get-LeafOrder {
    $j = List-Json
    foreach ($tab in @($j.data.windows[0].tabs | ForEach-Object { $_ })) {
        if (-not $tab.selected) { continue }
        $acc = New-Object System.Collections.ArrayList
        Add-Leaves $tab.splits $acc
        return @($acc)
    }
    return @()
}
function Add-Leaves($node, $acc) {
    if ($null -eq $node) { return }
    if ($node.type -eq 'leaf') {
        # The first pane was never named, so +list names it by its id.
        $n = [string]$node.terminal.name
        [void]$acc.Add($(if ($n -in @('s1', 's2', 's3')) { $n } else { 'P' }))
        return
    }
    Add-Leaves $node.left $acc
    Add-Leaves $node.right $acc
}

# Press at (x0, y0), travel in steps to (x1, y1), release there.
function Drag-Strip([IntPtr]$top, [int]$x0, [int]$y0, [int]$x1, [int]$y1) {
    [void](Send-TestMouse -Window $top -Target $top -X $x0 -Y $y0 -Action down -HoldMs 0)
    Start-Sleep -Milliseconds 120
    for ($s = 1; $s -le 8; $s++) {
        $x = [int]($x0 + ($x1 - $x0) * $s / 8)
        $y = [int]($y0 + ($y1 - $y0) * $s / 8)
        [void](Send-TestMouse -Window $top -Target $top -X $x -Y $y -Action move -HoldMs 0)
        Start-Sleep -Milliseconds 60
    }
    Start-Sleep -Milliseconds 150
    [void](Send-TestMouse -Window $top -Target $top -X $x1 -Y $y1 -Action up -HoldMs 0)
    Start-Sleep -Milliseconds 900
}

# -----------------------------------------------------------------------------

$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN
$savedPipe = $env:GHOZTTY_PIPE_SUFFIX
$env:GHOZTTY_PIPE_SUFFIX = "-stackstrip$PID"

Stop-RepoInstances
New-Item -ItemType Directory -Force $root | Out-Null
$tmp = Join-Path $root 'app'
New-Item -ItemType Directory -Force (Get-GhozttyAgentStateDir -Root $tmp) | Out-Null
$env:LOCALAPPDATA = $tmp
$env:GHOSTTY_LOCAL_AGENT_BIN = $agent

Reset-TestBody
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    Assert (Test-Path $exe) 'ghoztty exe exists in zig-out'
    Assert (Test-Path $agent) 'ghoztty-agent exe exists in zig-out'
    [void](Assert-GhozttyIsolatedBuild -Exe $exe)
    if ($NegativeControl) {
        Say 'NEGATIVE CONTROL: D1 is inverted to "the leading edge is NOT the strip colour" - this run MUST fail'
    }

    # ---- setup: P | (s1 | (s2 | s3)) at 900 DIP -------------------------------
    Say '== setup: P | (s1 | (s2 | s3)), 900 DIP wide'
    $app = Start-App
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    # Two DPI readings in a row must agree (pane-stack-grid.ps1's reason).
    Start-Sleep -Milliseconds 800
    $dpi = [int](Get-TestWindowDpi -Window $top)
    for ($i = 0; $i -lt 10; $i++) {
        Start-Sleep -Milliseconds 400
        $again = [int](Get-TestWindowDpi -Window $top)
        if ($again -eq $dpi) { break }
        $dpi = $again
    }
    if ($dpi -le 0) { $dpi = 96 }
    $script:scale = $dpi / 96.0
    [void](Set-TestWindowPos -Window $top -X 0 -Y 0 -Width (Get-TestChromeDip -Dip 1500 -Scale $script:scale) -Height (Get-TestChromeDip -Dip 700 -Scale $script:scale))
    Start-Sleep -Seconds 2
    & $exe +split --direction=right --name=s1 | Out-Null
    Start-Sleep -Milliseconds 800
    & $exe +split --pane=s1 --direction=right --name=s2 | Out-Null
    Start-Sleep -Milliseconds 800
    & $exe +split --pane=s2 --direction=right --name=s3 | Out-Null
    $c4 = @(Wait-Shown $top 4)
    if ($c4.Count -ne 4) { Write-TestAssertedNothing -Reason "four panes never came up on show (got $($c4.Count))" }
    # Tree order is left to right, and a tucked card keeps its slot's place.
    $names = @($null, 's1', 's2', 's3')
    # Off the screen's edges: a strip dragged within 12 DIP of one tiles to it
    # (D6), which D4 and D5 must not do by accident.
    [void](Set-TestWindowPos -Window $top -X 200 -Y 60 -Width (Get-TestChromeDip -Dip 900 -Scale $script:scale) -Height (Get-TestChromeDip -Dip 700 -Scale $script:scale))
    Start-Sleep -Milliseconds 800
    $shown = @(Wait-Shown $top 2)
    Start-Sleep -Milliseconds 600
    $all = @(Get-Panes $top)
    Say ("      dpi {0}; panes: {1}" -f $dpi, (Format-Cols $all))
    if ($shown.Count -ne 2 -or $all.Count -ne 4) { Write-TestAssertedNothing -Reason "the 900 DIP row never settled on two on show of four (got $($shown.Count) of $($all.Count))" }
    $tucked = @()
    for ($i = 0; $i -lt $all.Count; $i++) {
        if (-not $all[$i].Visible) { $tucked += [pscustomobject]@{ Pane = $all[$i]; Name = $names[$i] } }
    }

    # ---- D1: every tucked pane shows its strip ---------------------------------
    Say '== D1: strips painted'
    $expected = Get-ExpectedStrip @(0x28, 0x2c, 0x34)
    $minW = [int][math]::Floor(8 * $script:scale)
    $shot = Get-Shot $top
    $strips = @{}
    try {
        foreach ($t in $tucked) {
            $m = Measure-Strip $shot $t.Pane
            $strips[$t.Pane.Hwnd] = $m
            $got = if ($m.Color) { 'rgb({0},{1},{2})' -f $m.Color.R, $m.Color.G, $m.Color.B } else { 'off-capture' }
            $isStrip = Test-Near $m.Color $expected
            if ($NegativeControl) {
                Assert (-not $isStrip) "NEGATIVE: tucked pane at x=$($t.Pane.Left) is NOT the strip colour ($got)"
            } else {
                Assert $isStrip ("D1: tucked pane at x={0} shows the strip colour rgb({1}) (got {2})" -f $t.Pane.Left, ($expected -join ','), $got)
            }
            Assert ($m.Width -ge $minW) "D1: its strip is at least 8 DIP wide ($($m.Width) px, floor $minW px)"
        }
    } finally { Close-TestWindowPixels -Shot $shot }

    # ---- D2: the label follows the banner title --------------------------------
    Say '== D2: strip label from +set-banner'
    $named = @($tucked | Where-Object Name)
    if ($named.Count -eq 0) { Write-TestAssertedNothing -Reason 'no named pane was tucked' }
    $t = $named[0]
    $sw = $strips[$t.Pane.Hwnd].Width
    & $exe +set-banner --target=$($t.Name) '## Ab' 2>&1 | Out-Null
    Start-Sleep -Milliseconds 900
    $shot = Get-Shot $top
    try { $shortInk = Measure-Ink $shot $t.Pane $sw $expected } finally { Close-TestWindowPixels -Shot $shot }
    & $exe +set-banner --target=$($t.Name) '## Abcdefghijklmnopqrstuvwxyz banner title' 2>&1 | Out-Null
    Start-Sleep -Milliseconds 900
    $shot = Get-Shot $top
    try { $longInk = Measure-Ink $shot $t.Pane $sw $expected } finally { Close-TestWindowPixels -Shot $shot }
    Say "      $($t.Name): ink runs $shortInk px for '## Ab', $longInk px for the long title"
    Assert ($shortInk -gt 0) "D2: the short banner title is drawn on $($t.Name)'s strip ($shortInk px)"
    Assert ($longInk -gt ($shortInk + (Get-TestChromeDip -Dip 40 -Scale $script:scale))) "D2: the long banner title runs further down the strip ($longInk px vs $shortInk px)"

    # ---- D3: a click on the strip brings the pane on show ----------------------
    Say '== D3: strip click'
    $p = $t.Pane
    $sx = $p.Left + [int]($sw / 2)
    $sy = $p.Top + [int](($p.Bottom - $p.Top) / 2)
    [void](Send-TestMouse -Window $top -X $sx -Y $sy)
    Start-Sleep -Milliseconds 900
    $after = @(Get-Panes $top)
    Say ("      panes: {0}" -f (Format-Cols $after))
    $me = @($after | Where-Object { $_.Hwnd -eq $p.Hwnd })
    Assert ($me.Count -eq 1 -and $me[0].Visible) "D3: the clicked pane ($($t.Name)) is on show"
    Assert (@($after | Where-Object Visible).Count -eq 2) "D3: still two on show ($(@($after | Where-Object Visible).Count))"
    $focused = Focused-Pane-Name
    Assert ($focused -eq $t.Name) "D3: the clicked pane has focus (+list says '$focused')"

    # ---- D4-D6: a strip is a drag source (T2120) -------------------------------
    # Every pane keeps its HWND across a rearrange, so the HWND names it; the
    # tree order is read back from +list.
    $nameOf = @{}
    for ($i = 0; $i -lt $all.Count; $i++) { $nameOf[$all[$i].Hwnd] = if ($names[$i]) { $names[$i] } else { 'P' } }
    $rows = Get-StripRow $top $nameOf
    $d = @($rows | Where-Object { -not $_.Visible })[0]
    if ($null -eq $d) { Write-TestAssertedNothing -Reason 'no pane was tucked after D3' }
    $order0 = Get-LeafOrder
    $focus0 = Focused-Pane-Name
    $midY = $d.Top + [int](($d.Bottom - $d.Top) / 2)
    $px = $d.Left + [int]($d.StripW / 2)
    Say ("      row: {0}; dragging {1}'s strip; tree {2}" -f (($rows | ForEach-Object { "$($_.Name)[$($_.Lead)-$($_.Trail)]" }) -join ' '), $d.Name, ($order0 -join ','))

    Say '== D4: a strip dropped over the middle of a card does nothing'
    $card = @($rows | Where-Object Visible)[0]
    Drag-Strip $top $px $midY ($card.Left + [int](($card.Right - $card.Left) / 2)) $midY
    $order4 = Get-LeafOrder
    Assert (($order4 -join ',') -eq ($order0 -join ',')) "D4: the tree order is unchanged ($($order4 -join ','))"
    Assert (@(Get-Panes $top).Count -eq 4) "D4: still four panes ($(@(Get-Panes $top).Count))"
    $focus4 = Focused-Pane-Name
    Assert ($focus4 -eq $focus0) "D4: a press that travelled is not a click - focus stays on '$focus0' ('$focus4')"

    Say '== D5: a strip dropped in a gap of its row moves there'
    # The slots are the gaps between the OTHER items, plus the two ends; the
    # one where the strip already is changes nothing. Take an inner gap that
    # is not that one.
    $others = @($rows | Where-Object { $_.Hwnd -ne $d.Hwnd })
    $own = [array]::IndexOf(@($rows | ForEach-Object { $_.Hwnd }), $d.Hwnd)
    $k = if ($own -ne 1) { 1 } else { 2 }
    $gapX = [int](($others[$k - 1].Left + $others[$k - 1].StripW + $others[$k].Left) / 2)
    $expect = @($others[0..($k - 1)] | ForEach-Object { $_.Name }) + @($d.Name) + @($others[$k..($others.Count - 1)] | ForEach-Object { $_.Name })
    Say ("      drop at x={0} (between {1} and {2}); expect {3}" -f $gapX, $others[$k - 1].Name, $others[$k].Name, ($expect -join ','))
    Drag-Strip $top $px $midY $gapX $midY
    $order5 = Get-LeafOrder
    Assert (($order5 -join ',') -eq ($expect -join ',')) "D5: $($d.Name) moved between $($others[$k - 1].Name) and $($others[$k].Name) (tree $($order5 -join ','))"
    $after5 = @(Get-Panes $top)
    Assert ($after5.Count -eq 4 -and @($after5 | Where-Object { $_.Hwnd -eq $d.Hwnd }).Count -eq 1) "D5: the same four panes, $($d.Name) still its own window ($($after5.Count))"

    Say '== D6: a strip dropped at a screen edge tiles a window of its own'
    $rows = Get-StripRow $top $nameOf
    $d = @($rows | Where-Object { -not $_.Visible })[0]
    if ($null -eq $d) { Write-TestAssertedNothing -Reason 'no pane was tucked after D5' }
    $wa = Get-TestWorkArea
    $midY = $d.Top + [int](($d.Bottom - $d.Top) / 2)
    Drag-Strip $top ($d.Left + [int]($d.StripW / 2)) $midY ($wa.Right - 3) $midY
    $deadline = (Get-Date).AddSeconds(8)
    do {
        $tops = @(Get-TestWindows -ProcessId $app.Pid -Class 'GhozttyWindow')
        if ($tops.Count -ge 2) { break }
        Start-Sleep -Milliseconds 300
    } while ((Get-Date) -lt $deadline)
    Assert ($tops.Count -eq 2) "D6: a second window opened ($($tops.Count))"
    $new = @($tops | Where-Object { $_.Hwnd -ne [int64]$top })[0]
    if ($new) {
        $half = $wa.Left + [int]($wa.Width / 2)
        Say ("      new window {0}-{1}; work area {2}-{3}" -f $new.Left, $new.Right, $wa.Left, $wa.Right)
        $tol = Get-TestChromeDip -Dip 12 -Scale $script:scale
        Assert ([math]::Abs($new.Left - $half) -le $tol -and [math]::Abs($new.Right - $wa.Right) -le $tol) "D6: it covers the right half of the screen ($($new.Left)-$($new.Right) vs $half-$($wa.Right))"
        $moved = @(Get-TestChildWindows -Window ([IntPtr]$new.Hwnd) -Class 'GhozttyTerminal')
        Assert ($moved.Count -eq 1 -and $moved[0].Hwnd -eq $d.Hwnd) "D6: it holds the dragged pane $($d.Name), the same window ($($moved.Count))"
        Assert (@(Get-Panes $top).Count -eq 3) "D6: three panes stay behind ($(@(Get-Panes $top).Count))"
    }

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
        update -Guard pane-stack-strip -Repo $repo 2>&1 | ForEach-Object { Say "  $_" }
}

Say ''
Write-TestVerdict -Label 'T2109 PANE STACK STRIP' -Pass $script:pass -Fail $script:fail
