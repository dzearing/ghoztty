# @timing-sensitive - it reads a fold frame by frame from the app's oracle
# lines; beside other workers the glide's frames thin out (the stack-fold-slide
# precedent, T2521).
# T2460 acceptance: a VIEWER pane folding into its strip carries its page's
# last frame through the fold, the way a terminal does (T2457), instead of the
# live WebView2 under a face fading on its own clock.
#
# THE CLAIM. Before T2460 `PaneView.glideSnapRequest` answered false for a
# viewer, so a markdown/HTML/website/diff pane that folded kept its live
# window on show under the strip's face for the whole glide - two things moving
# on two clocks, the desync the user reported for terminals. Now the viewer is
# asked for its page's frame (`CapturePreview` at the pane's full size), the
# card is drawn from that one picture, and the live window is hidden under it.
#
# Layout: P | s1 | s2 across a 1125 DIP window, s2 a markdown viewer - the
# stack-fold-slide.ps1 shape. The root divider is dragged right past the fold
# point and HELD, the slide stretched to 2 s (`GHOZTTY_STACK_SLIDE_MS`).
#
# Claims:
#   V1) the fold asks s2 - the viewer - for its frame and the frame lands: the
#       debug build's `stack fold carries its frame hwnd=<s2> ... kind=viewer`
#       line is logged during the fold
#   V2) that frame is the page, not a failed capture: its colour sample holds
#       2+ colours (`colors=`), and it is s2's size, not a hero tile's
#   V3) the card is carried on 2+ frames, the live viewer window is off show on
#       every carried frame after the first, and the content's strength only
#       ever falls (the `stack fold carried` oracle)
#   V4) at rest: s2 is hidden and no face is on show
#   V5) dragged back, s2 is a live viewer on show again: three panes on show
#
# -NegativeControl sets the slide to 0 ms (an instant re-layout, no glide to
# carry anything through): V3 MUST fail. V1/V2 still pass there - the fold
# asks for the frame before the instant re-layout ends it - so their negative
# is the code before T2460, where a viewer was never asked (no `kind=viewer`
# line could be logged).
#
# Hermetic: per-run LOCALAPPDATA, per-run agent binary override, a private IPC
# pipe suffix, and it only ever kills ghoztty processes launched from this
# repo's zig-out. Runs on the BACKGROUND test desktop.
#
#   powershell -NoProfile -File test\win32\viewer-fold-carried.ps1
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
$root = Join-Path $env:TEMP "ghoztty-viewer-fold-carried-$PID"
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
function Get-LogLines([int]$from, [int]$to) {
    $lines = @(Get-Content -Path $script:errlog -ErrorAction SilentlyContinue)
    if ($to -gt $lines.Count) { $to = $lines.Count }
    if ($from -ge $to) { return @() }
    return @($lines[$from..($to - 1)])
}
function Get-LogLength { return @(Get-Content -Path $script:errlog -ErrorAction SilentlyContinue).Count }

# The `stack fold carries its frame hwnd=H size=WxH kind=K colors=N` lines.
function Get-CarriesFrame([int]$from, [int]$to) {
    return @(Get-LogLines $from $to | ForEach-Object {
            if ($_ -match 'stack fold carries its frame hwnd=([0-9a-f]+) size=(\d+)x(\d+) kind=(\w+) colors=(\d+)') {
                [pscustomobject]@{ Hwnd = [Convert]::ToInt64($Matches[1], 16); W = [int]$Matches[2]; H = [int]$Matches[3]; Kind = $Matches[4]; Colors = [int]$Matches[5] }
            }
        })
}
# The `stack fold carried content_alpha=N card=L,W live=0|1` lines (T2457).
function Get-Carried([int]$from, [int]$to) {
    return @(Get-LogLines $from $to | ForEach-Object {
            if ($_ -match 'stack fold carried content_alpha=(\d+) card=(-?\d+),(\d+) live=(\d)') {
                [pscustomobject]@{ Alpha = [int]$Matches[1]; Left = [int]$Matches[2]; Width = [int]$Matches[3]; Live = [int]$Matches[4] }
            }
        })
}

# -----------------------------------------------------------------------------

$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN
$savedPipe = $env:GHOZTTY_PIPE_SUFFIX
$savedSlide = $env:GHOZTTY_STACK_SLIDE_MS
$env:GHOZTTY_PIPE_SUFFIX = "-viewerfold$PID"
$env:GHOZTTY_STACK_SLIDE_MS = "$slideMs"

Stop-RepoInstances
New-Item -ItemType Directory -Force $root | Out-Null
$tmp = Join-Path $root 'app'
New-Item -ItemType Directory -Force (Get-GhozttyAgentStateDir -Root $tmp) | Out-Null
$env:LOCALAPPDATA = $tmp
$env:GHOSTTY_LOCAL_AGENT_BIN = $agent

# A page with text on a ground, a heading and a code block: several colours.
$mdFile = Join-Path $root 'fold-page.md'
$md = @('# Folding viewer', '', 'A paragraph of body text so the page has ink on its ground.', '',
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
        Say 'NEGATIVE CONTROL: the slide is 0 ms (an instant re-layout) - V3 MUST fail'
    }

    # ---- setup: P | s1 | s2(viewer) -----------------------------------------
    $minDip = 225
    $winDip = 5 * $minDip
    Say "== setup: P | s1 | s2 (markdown viewer), $winDip DIP wide, slide $slideMs ms"
    $app = Start-OnTestDesktop -Exe $exe -Arguments $appArgs -StdErr $script:errlog
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { Write-TestAssertedNothing -Reason 'the app never opened a GhozttyWindow' }
    $script:appPid = [int]$app.Pid
    Start-Sleep -Milliseconds 800
    $dpi = [int](Get-TestWindowDpi -Window $top)
    if ($dpi -le 0) { $dpi = 96 }
    $scale = $dpi / 96.0
    [void](Set-TestWindowPos -Window $top -X 0 -Y 0 -Width (Get-TestChromeDip -Dip $winDip -Scale $scale) -Height (Get-TestChromeDip -Dip 700 -Scale $scale))
    Start-Sleep -Seconds 2
    & $exe +split --direction=right --name=s1 | Out-Null
    Start-Sleep -Milliseconds 800
    $out = & $exe +split --pane=s1 --direction=right "--view=$mdFile" --name=s2 2>&1
    if ($LASTEXITCODE -ne 0) { Write-TestAssertedNothing -Reason "+split --view exited $LASTEXITCODE ($out)" }
    $c3 = @(Wait-Shown $top 3)
    if ($c3.Count -ne 3) { Write-TestAssertedNothing -Reason "three columns never came up (got $($c3.Count): $(Format-Cols $c3))" }
    # Give the page time to load and paint: a capture answers only once it has.
    Start-Sleep -Seconds 4
    $c3 = @(Get-VisiblePanes $top)
    if ($c3[2].Class -ne 'GhozttyViewer') { Write-TestAssertedNothing -Reason "the rightmost pane is not the viewer ($(Format-Cols $c3))" }
    $hP = $c3[0].Hwnd
    $hS2 = $c3[2].Hwnd
    Say ("      dpi {0}; columns: {1}" -f $dpi, (Format-Cols $c3))

    $x0 = [int](($c3[0].Right + $c3[1].Left) / 2)
    $y = [int](($c3[0].Top + $c3[0].Bottom) / 2)
    $gutter = $c3[1].Left - $c3[0].Right
    $foldAt = $c3[2].Right - 2 * (Get-TestChromeDip -Dip $minDip -Scale $scale) - $gutter
    $xFold = [int]($foldAt + (Get-TestChromeDip -Dip 100 -Scale $scale))
    $xNear = [int]($foldAt - (Get-TestChromeDip -Dip 40 -Scale $scale))
    Say ("      fold point ~{0} px; approach to {1}, fold at {2}" -f $foldAt, $xNear, $xFold)

    # ---- the fold, held ------------------------------------------------------
    Say '== drag the root divider up to the fold point, then over it in one move, and hold'
    [void](Send-TestMouse -Window $top -Target $top -X $x0 -Y $y -Action down -HoldMs 0)
    Start-Sleep -Milliseconds 150
    $steps = 6
    for ($i = 1; $i -le $steps; $i++) {
        [void](Send-TestMouse -Window $top -Target $top -X ([int]($x0 + ($xNear - $x0) * $i / $steps)) -Y $y -Action move -HoldMs 0)
        Start-Sleep -Milliseconds 30
    }
    Start-Sleep -Milliseconds 600
    $near = @(Get-VisiblePanes $top)
    if ($near.Count -ne 3) { Write-TestAssertedNothing -Reason "the approach already folded ($($near.Count) on show)" }
    $s2Near = Find-Pane $near $hS2
    if ($null -eq $s2Near) { Write-TestAssertedNothing -Reason 'the viewer is not on show short of the fold' }
    Say ("      short of the fold: {0}" -f (Format-Cols $near))
    $logFold = Get-LogLength
    [void](Send-TestMouse -Window $top -Target $top -X $xFold -Y $y -Action move -HoldMs 0)
    Start-Sleep -Milliseconds ($slideMs + 1200)
    $logBack = Get-LogLength
    $rest = @(Get-Panes $top)
    $s2End = Find-Pane $rest $hS2
    $facesFolded = @(Get-TestWindows -ProcessId $app.Pid -Class 'GhozttyStripFace' | Where-Object Visible).Count
    Say ("      at rest: {0}" -f (Format-Cols $rest))

    # V1/V2: the viewer's frame landed, and it is the page at the pane's size.
    $frames = @(Get-CarriesFrame $logFold $logBack | Where-Object { $_.Hwnd -eq [int64]$hS2 })
    $fr = if ($frames.Count -gt 0) { $frames[0] } else { $null }
    $frSays = if ($fr) { "kind=$($fr.Kind) $($fr.W)x$($fr.H) colors=$($fr.Colors)" } else { 'no line' }
    Say ("      s2 frame: {0}; s2 window short of the fold {1}x{2}" -f $frSays, $s2Near.Width, $s2Near.Height)
    Assert ($null -ne $fr -and $fr.Kind -eq 'viewer') "V1: folding, the viewer s2 is asked for its frame and the frame lands ($frSays)"
    Assert ($null -ne $fr -and $fr.Colors -ge 2) "V2: the carried frame is the page, not a failed capture: $(if ($fr) { $fr.Colors } else { 0 }) colours in its sample (need 2+)"
    $slack = [math]::Max(4, [int](0.1 * $s2Near.Width))
    Assert ($null -ne $fr -and [math]::Abs($fr.W - $s2Near.Width) -le $slack -and [math]::Abs($fr.H - $s2Near.Height) -le 4) "V2: the carried frame is s2's size ($frSays vs $($s2Near.Width)x$($s2Near.Height), slack $slack px wide)"

    # V3: carried on 2+ frames, the live window hidden, the strength falling.
    $carried = @(Get-Carried $logFold $logBack)
    $rise = 0
    for ($i = 1; $i -lt $carried.Count; $i++) { $rise = [math]::Max($rise, $carried[$i].Alpha - $carried[$i - 1].Alpha) }
    $liveAfter = @($carried | Select-Object -Skip 1 | Where-Object { $_.Live -eq 1 }).Count
    Say ("      carried content folding: {0}" -f (($carried | ForEach-Object { '{0}{1}' -f $_.Alpha, $(if ($_.Live) { '*' } else { '' }) }) -join ' > '))
    Assert ($carried.Count -ge 2) "V3: folding, s2's card is carried on $($carried.Count) frames (need 2+)"
    Assert ($carried.Count -ge 2 -and $liveAfter -eq 0) "V3: folding, the live viewer window is off show on every carried frame after the first ($liveAfter of $([math]::Max(0, $carried.Count - 1)))"
    Assert ($carried.Count -ge 2 -and $rise -eq 0) "V3: folding, the carried content's strength never rises ($($carried.Count) frames, largest rise $rise)"

    # V4: folded and at rest.
    Assert ($null -ne $s2End -and -not $s2End.Visible) 'V4: folded and at rest, the viewer s2 is hidden'
    Assert ($facesFolded -eq 0) "V4: folded and at rest, no face is on show ($facesFolded)"

    # V5: back, the viewer is live again.
    Say '== drag back to the start, still held, then let go'
    [void](Send-TestMouse -Window $top -Target $top -X $x0 -Y $y -Action move -HoldMs 0)
    Start-Sleep -Milliseconds ($slideMs + 1200)
    [void](Send-TestMouse -Window $top -Target $top -X $x0 -Y $y -Action up -HoldMs 0)
    Start-Sleep -Milliseconds 600
    $again = @(Get-Panes $top)
    $s2Again = Find-Pane $again $hS2
    Say ("      back: {0}" -f (Format-Cols $again))
    Assert (@($again | Where-Object Visible).Count -eq 3 -and $null -ne $s2Again -and $s2Again.Visible) "V5: all the way back, three on show and the viewer s2 among them ($(Format-Cols $again))"

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

if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard viewer-fold-carried -Repo $repo 2>&1 | ForEach-Object { Say "  $_" }
}

Say ''
Write-TestVerdict -Label 'T2460 VIEWER FOLD CARRIED' -Pass $script:pass -Fail $script:fail
