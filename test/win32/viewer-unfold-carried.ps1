# @timing-sensitive - it reads an unfold frame by frame from the app's oracle
# lines; beside other workers the glide's frames thin out (the stack-fold-slide
# precedent, T2521).
# T2635 acceptance: a VIEWER pane opening out of its strip carries the frame
# its page draws at its new size, the way a terminal does (T2458), instead of
# the live WebView2 under a face fading on its own clock.
#
# THE CLAIM. T2460 carried a FOLDING viewer's frame, but the opening path was
# terminal-only: `armGlideSnaps` keyed the opening carry on a terminal surface
# and `PaneView.glideSnapRequestExact` answered false for a viewer, so a
# markdown/HTML/website/diff pane clicked out of its strip opened at its old
# size as its live page under a fading face, and was resized at the end. Now
# the viewer opens presized and hidden, its page keeps rendering under the
# hidden host, it is captured once the page has laid out at the new size (an
# older capture is dropped), and the card is drawn from that one picture.
#
# Layout: P | s1 | s2 across a 1125 DIP window, s2 a markdown viewer. The root
# divider is dragged past the fold point and released, so s2 folds into its
# strip; then the strip is clicked. The slide is stretched to 2 s
# (`GHOZTTY_STACK_SLIDE_MS`).
#
# Claims, after the click on s2's strip:
#   W1) opening, the viewer s2 is asked for its frame and it lands: the debug
#       build's `stack unfold carries its frame hwnd=<s2> ... kind=viewer` line
#   W2) that frame is the page, not a failed capture (`colors=` 2+), at s2's
#       slot size - the size it lands at, not the strip's or a hero tile's
#   W3) the card is carried on 2+ frames (`stack unfold carried`): the live
#       viewer window is off show on every one, no content shows before the
#       frame at the new size lands and it does land, the content's strength
#       never falls, and the viewer is resized 0 times from the first frame of
#       the motion on
#   W4) s2 lands a live pane, resized 0 times since the motion started
#       (`stack unfold landed resizes=0 live=1`)
#   W5) settled: three on show, s2 among them
#
# -NegativeControl sets GHOZTTY_TEST_VIEWER_OPEN_LIVE (debug builds only): the
# viewer opens the way it did before T2635, as its live page - W1 and W3 MUST
# fail.
#
# Hermetic: per-run LOCALAPPDATA, per-run agent binary override, a private IPC
# pipe suffix, and it only ever kills ghoztty processes launched from this
# repo's zig-out. Runs on the BACKGROUND test desktop.
#
#   powershell -NoProfile -File test\win32\viewer-unfold-carried.ps1
param(
    [string]$ExePath,
    [string]$AgentExe,
    [switch]$NegativeControl,
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
$root = Join-Path $env:TEMP "ghoztty-viewer-unfold-carried-$PID"
$script:errlog = Join-Path $root 'app-stderr.log'
$slideMs = 2000

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

$appArgs = @('--config-default-files=false', '--session-persistence=false', '--macos-pane-style=flat')

# Every pane window - terminals and viewers - sorted left to right.
function Get-Panes([IntPtr]$top) {
    $t = @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal')
    $v = @(Get-TestChildWindows -Window $top -Class 'GhozttyViewer')
    return @(@($t) + @($v) | Sort-Object Left)
}
function Get-VisiblePanes([IntPtr]$top) {
    return @(Get-Panes $top | Where-Object Visible)
}
function Wait-Shown([IntPtr]$top, [int]$n, [int]$timeoutSec = 30) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    do {
        $v = @(Get-VisiblePanes $top)
        if ($v.Count -eq $n) { return $v }
        Start-Sleep -Milliseconds 300
    } while ((Get-Date) -lt $deadline)
    return @(Get-VisiblePanes $top)
}
function Format-Cols($cols) {
    return (($cols | ForEach-Object { "$($_.Class):$($_.Left)-$($_.Right)$(if (-not $_.Visible) { '(hidden)' })" }) -join ' | ')
}
function Find-Pane($panes, [int64]$hwnd) {
    $m = @($panes | Where-Object { $_.Hwnd -eq $hwnd })
    if ($m.Count -eq 1) { return $m[0] }
    return $null
}
function Get-LogLines([int]$from) {
    $lines = @(Get-Content -Path $script:errlog -ErrorAction SilentlyContinue)
    if ($from -ge $lines.Count) { return @() }
    return @($lines[$from..($lines.Count - 1)])
}
function Get-LogLength { return @(Get-Content -Path $script:errlog -ErrorAction SilentlyContinue).Count }

# The `stack unfold carries its frame hwnd=H size=WxH kind=K colors=N` lines.
function Get-CarriesFrame([int]$from) {
    return @(Get-LogLines $from | ForEach-Object {
            if ($_ -match 'stack unfold carries its frame hwnd=([0-9a-f]+) size=(\d+)x(\d+) kind=(\w+) colors=(\d+)') {
                [pscustomobject]@{ Hwnd = [Convert]::ToInt64($Matches[1], 16); W = [int]$Matches[2]; H = [int]$Matches[3]; Kind = $Matches[4]; Colors = [int]$Matches[5] }
            }
        })
}
# The `stack unfold carried content_alpha=N card=L,W live=0|1 frame=0|1
# resizes=N` oracle lines (T2458).
function Get-Opening([int]$from) {
    return @(Get-LogLines $from | ForEach-Object {
            if ($_ -match 'stack unfold carried content_alpha=(\d+) card=(-?\d+),(\d+) live=(\d) frame=(\d) resizes=(\d+)') {
                [pscustomobject]@{ Alpha = [int]$Matches[1]; Left = [int]$Matches[2]; Width = [int]$Matches[3]; Live = [int]$Matches[4]; Frame = [int]$Matches[5]; Resizes = [int]$Matches[6] }
            }
        })
}
# The `stack unfold landed resizes=N live=0|1` oracle lines (T2458).
function Get-Landed([int]$from) {
    return @(Get-LogLines $from | ForEach-Object {
            if ($_ -match 'stack unfold landed resizes=(\d+) live=(\d)') {
                [pscustomobject]@{ Resizes = [int]$Matches[1]; Live = [int]$Matches[2] }
            }
        })
}

# -----------------------------------------------------------------------------

$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN
$savedPipe = $env:GHOZTTY_PIPE_SUFFIX
$savedSlide = $env:GHOZTTY_STACK_SLIDE_MS
$savedLive = $env:GHOZTTY_TEST_VIEWER_OPEN_LIVE
$env:GHOZTTY_PIPE_SUFFIX = "-viewerunfold$PID"
$env:GHOZTTY_STACK_SLIDE_MS = "$slideMs"
if ($NegativeControl) { $env:GHOZTTY_TEST_VIEWER_OPEN_LIVE = '1' }
else { Remove-Item env:GHOZTTY_TEST_VIEWER_OPEN_LIVE -ErrorAction SilentlyContinue }

Stop-RepoInstances
New-Item -ItemType Directory -Force $root | Out-Null
$tmp = Join-Path $root 'app'
New-Item -ItemType Directory -Force (Get-GhozttyAgentStateDir -Root $tmp) | Out-Null
$env:LOCALAPPDATA = $tmp
$env:GHOSTTY_LOCAL_AGENT_BIN = $agent

# A page with text on a ground, a heading and a code block: several colours.
$mdFile = Join-Path $root 'unfold-page.md'
$md = @('# Opening viewer', '', 'A paragraph of body text so the page has ink on its ground.', '',
    '## A second heading', '', '```', 'const x = 42;', '```', '', '- one', '- two', '- three')
[IO.File]::WriteAllText($mdFile, ($md -join "`n"))

Reset-TestBody
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    Assert (Test-Path $exe) 'ghoztty exe exists in zig-out'
    Assert (Test-Path $agent) 'ghoztty-agent exe exists in zig-out'
    [void](Assert-GhozttyIsolatedBuild -Exe $exe)
    if ($NegativeControl) {
        Say 'NEGATIVE CONTROL: the viewer opens as its live page (GHOZTTY_TEST_VIEWER_OPEN_LIVE) - W1 and W3 MUST fail'
    }

    # ---- setup: P | s1 | s2(viewer) -----------------------------------------
    $minDip = 225
    $winDip = 5 * $minDip
    Say "== setup: P | s1 | s2 (markdown viewer), $winDip DIP wide, slide $slideMs ms"
    $app = Start-OnTestDesktop -Exe $exe -Arguments $appArgs -StdErr $script:errlog
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { Write-TestAssertedNothing -Reason 'the app never opened a GhozttyWindow' }
    $script:appPid = [int]$app.Pid
    # settle: the window's first layout pass, before its DPI is read and it is moved
    Start-Sleep -Milliseconds 800
    $dpi = [int](Get-TestWindowDpi -Window $top)
    if ($dpi -le 0) { $dpi = 96 }
    $scale = $dpi / 96.0
    [void](Set-TestWindowPos -Window $top -X 0 -Y 0 -Width (Get-TestChromeDip -Dip $winDip -Scale $scale) -Height (Get-TestChromeDip -Dip 700 -Scale $scale))
    # settle: the resize's relayout lands before the first split reads the width
    Start-Sleep -Seconds 2
    & $exe +split --direction=right --name=s1 | Out-Null
    $c2 = @(Wait-Shown $top 2)
    if ($c2.Count -ne 2) { Write-TestAssertedNothing -Reason "s1 never came up beside P (got $($c2.Count): $(Format-Cols $c2))" }
    $out = & $exe +split --pane=s1 --direction=right "--view=$mdFile" --name=s2 2>&1
    if ($LASTEXITCODE -ne 0) { Write-TestAssertedNothing -Reason "+split --view exited $LASTEXITCODE ($out)" }
    $c3 = @(Wait-Shown $top 3)
    if ($c3.Count -ne 3) { Write-TestAssertedNothing -Reason "three columns never came up (got $($c3.Count): $(Format-Cols $c3))" }
    # settle: the page loads and paints - a capture answers only once it has, and the page reports no load event to the log
    Start-Sleep -Seconds 4
    $c3 = @(Get-VisiblePanes $top)
    if ($c3[2].Class -ne 'GhozttyViewer') { Write-TestAssertedNothing -Reason "the rightmost pane is not the viewer ($(Format-Cols $c3))" }
    $hS2 = $c3[2].Hwnd
    Say ("      dpi {0}; columns: {1}" -f $dpi, (Format-Cols $c3))

    $x0 = [int](($c3[0].Right + $c3[1].Left) / 2)
    $y = [int](($c3[0].Top + $c3[0].Bottom) / 2)
    $gutter = $c3[1].Left - $c3[0].Right
    $foldAt = $c3[2].Right - 2 * (Get-TestChromeDip -Dip $minDip -Scale $scale) - $gutter
    $xFold = [int]($foldAt + (Get-TestChromeDip -Dip 100 -Scale $scale))

    # ---- fold s2 into its strip ---------------------------------------------
    Say '== fold s2: drag the root divider past the fold point and release'
    [void](Send-TestMouse -Window $top -Target $top -X $x0 -Y $y -Action down -HoldMs 0)
    # settle: the press is a drag's start, paced like a hand, not a handshake
    Start-Sleep -Milliseconds 150
    for ($i = 1; $i -le 6; $i++) {
        [void](Send-TestMouse -Window $top -Target $top -X ([int]($x0 + ($xFold - $x0) * $i / 6)) -Y $y -Action move -HoldMs 0)
        Start-Sleep -Milliseconds 60
    }
    # settle: the pointer rests past the fold point before the release, as a hand does
    Start-Sleep -Milliseconds 400
    [void](Send-TestMouse -Window $top -Target $top -X $xFold -Y $y -Action up -HoldMs 0)
    $foldDeadline = (Get-Date).AddMilliseconds($slideMs + 10000)
    do {
        Start-Sleep -Milliseconds 200
        $folded = @(Get-Panes $top)
        $s2Folded = Find-Pane $folded $hS2
    } while ((Get-Date) -lt $foldDeadline -and ($null -eq $s2Folded -or $s2Folded.Visible -or @($folded | Where-Object Visible).Count -ne 2))
    # settle: the fold's slide finishes its last frames after s2 hides
    Start-Sleep -Milliseconds ($slideMs + 300)
    $folded = @(Get-Panes $top)
    $s2Folded = Find-Pane $folded $hS2
    Say ("      folded: {0}" -f (Format-Cols $folded))
    if ($null -eq $s2Folded -or $s2Folded.Visible -or @($folded | Where-Object Visible).Count -ne 2) {
        Write-TestAssertedNothing -Reason 's2 never folded into a strip (two on show, s2 hidden)'
    }

    # ---- the click on s2's strip --------------------------------------------
    Say '== click s2''s strip and let it open'
    $minStrip = [int][math]::Floor(8 * $scale)
    $logClick = Get-LogLength
    [void](Send-TestMouse -Window $top -X ($s2Folded.Left + [int]($minStrip / 2)) -Y $y)
    # The negative control never logs a landed line, so the deadline ends it.
    $landDeadline = (Get-Date).AddMilliseconds($slideMs + 8000)
    do {
        Start-Sleep -Milliseconds 200
    } while ((Get-Date) -lt $landDeadline -and @(Get-Landed $logClick).Count -eq 0)
    # settle: the live pane's first paint after the landed line
    Start-Sleep -Milliseconds 300
    $after = @(Get-Panes $top)
    $s2After = Find-Pane $after $hS2
    Say ("      settled: {0}" -f (Format-Cols $after))

    # W1/W2: the viewer's frame at its new size landed.
    $frames = @(Get-CarriesFrame $logClick | Where-Object { $_.Hwnd -eq [int64]$hS2 })
    $fr = if ($frames.Count -gt 0) { $frames[0] } else { $null }
    $frSays = if ($fr) { "kind=$($fr.Kind) $($fr.W)x$($fr.H) colors=$($fr.Colors)" } else { 'no line' }
    $landW = if ($s2After) { $s2After.Width } else { 0 }
    $landH = if ($s2After) { $s2After.Height } else { 0 }
    Say ("      s2 frame: {0}; s2 landed {1}x{2}" -f $frSays, $landW, $landH)
    Assert ($null -ne $fr -and $fr.Kind -eq 'viewer') "W1: opening, the viewer s2 is asked for its frame and the frame lands ($frSays)"
    Assert ($null -ne $fr -and $fr.Colors -ge 2) "W2: the carried frame is the page, not a failed capture: $(if ($fr) { $fr.Colors } else { 0 }) colours in its sample (need 2+)"
    Assert ($null -ne $fr -and [math]::Abs($fr.W - $landW) -le 2 -and [math]::Abs($fr.H - $landH) -le 2) "W2: the carried frame is s2's slot size ($frSays vs landed ${landW}x${landH})"

    # W3: carried on 2+ frames, hidden, no early content, strength rising, never resized.
    $opening = @(Get-Opening $logClick)
    Say ("      opening carried: {0}" -f (($opening | ForEach-Object { '{0}@{1}{2}{3}' -f $_.Alpha, $_.Width, $(if ($_.Frame) { '' } else { '-' }), $(if ($_.Live) { '*' } else { '' }) }) -join ' > '))
    $openLive = @($opening | Where-Object { $_.Live -eq 1 }).Count
    $early = @($opening | Where-Object { $_.Frame -eq 0 -and $_.Alpha -gt 0 }).Count
    $withFrame = @($opening | Where-Object { $_.Frame -eq 1 }).Count
    $openFall = 0
    for ($i = 1; $i -lt $opening.Count; $i++) { $openFall = [math]::Max($openFall, $opening[$i - 1].Alpha - $opening[$i].Alpha) }
    $openResized = @($opening | Where-Object { $_.Resizes -ne 0 }).Count
    Assert ($opening.Count -ge 2) "W3: opening, s2's card is carried on $($opening.Count) frames (need 2+)"
    Assert ($opening.Count -ge 2 -and $openLive -eq 0) "W3: the live viewer window is off show on every carried frame ($openLive of $($opening.Count))"
    Assert ($opening.Count -ge 2 -and $early -eq 0 -and $withFrame -ge 1) "W3: no content before the frame at the new size lands ($early early), and it lands ($withFrame frames carry it)"
    Assert ($opening.Count -ge 2 -and $openFall -eq 0) "W3: the carried content's strength never falls (largest fall $openFall)"
    Assert ($opening.Count -ge 2 -and $openResized -eq 0) "W3: the viewer is resized 0 times once the motion has started ($openResized frames saw a resize)"

    # W4: landed live, never resized on the way.
    $landed = @(Get-Landed $logClick)
    $land = if ($landed.Count -gt 0) { $landed[-1] } else { $null }
    $landSays = if ($land) { "resizes=$($land.Resizes) live=$($land.Live)" } else { 'no landed line' }
    Assert ($null -ne $land -and $land.Resizes -eq 0 -and $land.Live -eq 1) "W4: s2 lands a live pane with 0 resizes since the motion started ($landSays)"

    # W5: settled.
    Assert (@($after | Where-Object Visible).Count -eq 3 -and $null -ne $s2After -and $s2After.Visible) "W5: three on show after the unfold, the viewer s2 among them ($(Format-Cols $after))"

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
    if ($null -ne $savedLive) { $env:GHOZTTY_TEST_VIEWER_OPEN_LIVE = $savedLive }
    else { Remove-Item env:GHOZTTY_TEST_VIEWER_OPEN_LIVE -ErrorAction SilentlyContinue }
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

if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard viewer-unfold-carried -Repo $repo 2>&1 | ForEach-Object { Say "  $_" }
}

Say ''
Write-TestVerdict -Label 'T2635 VIEWER UNFOLD CARRIED' -Pass $script:pass -Fail $script:fail
