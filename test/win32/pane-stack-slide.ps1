# T2102 + T2105 acceptance: when a stack's run changes, the cards on show GLIDE to
# their new slots (Mac's carousel slide, 86b7e3410), and no terminal is
# resized mid-slide.
#
# THE CLAIM. Before T2102 a click on a tucked pane's strip (T2109) re-laid the
# row out in one step: the cards jumped. `Window.planStackSlide` now sees the
# run change and moves each card on show from where it was to its new slot on
# Mac's curve (`pane_stack_slide.ease`), a frame at a time; a card that keeps
# its size is only ever MOVED, so its window gets no WM_SIZE and its ConPTY is
# never resized, and a card whose size changes holds its old size until the
# slide ends and then resizes once.
#
# Layout: P | (s1 | (s2 | s3)) at 900 DIP, the T2108 shape: two on show, two
# tucked. The slide is stretched to 2 s (`GHOZTTY_STACK_SLIDE_MS`) so the
# sampler sees it in motion.
#
# Claims:
#   S1) after a click on a tucked pane's strip, that pane's window is seen at
#       two or more distinct positions strictly between where it started and
#       where it settles - it slid, it did not jump
#   S2) no pane window changes size more than once over the whole slide (the
#       pane window's client size is what its ConPTY is sized from)
#   S3) it settles on show with focus, two on show (the T2109 result still
#       holds at the end of the motion)
#   S4) T2105 (Mac 89848fd59): a pane that tucks away keeps the size it last
#       had on show - shrinking the window from four on show to two leaves
#       each tucked pane's window at its four-up size, while the panes on
#       show (the positive control) do resize
#   S5) T2105: a window resize with panes tucked resizes the panes on show
#       (control) and none of the tucked ones
#   S6) T2227: at no sampled moment of the strip-click slide does any popup
#       the app shows (the unfocused dim wash, a scrollbar) reach outside the
#       window - the window clips a card sliding past its edge, nothing clips
#       the card's popups
#
# -NegativeControl sets the slide to 0 ms (an instant re-layout, the answer
# before T2102) and keeps S1 as written: it MUST fail.
#
# Hermetic: per-run LOCALAPPDATA, per-run agent binary override, a private IPC
# pipe suffix, and it only ever kills ghoztty processes launched from this
# repo's zig-out. Runs on the BACKGROUND test desktop.
#
#   powershell -NoProfile -File test\win32\pane-stack-slide.ps1
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
$root = Join-Path $env:TEMP "ghoztty-pane-stack-slide-$PID"
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
# T2227: every visible top-level the app shows other than the window itself
# that reaches outside the window's rect. One line each, for the message.
function Get-StrayPopups([int]$procId, [IntPtr]$top) {
    $w = Get-TestWindowRect -Window $top
    return @(Get-TestWindows -ProcessId $procId -Class '*' | Where-Object {
            $_.Visible -and $_.Hwnd -ne [int64]$top -and $_.Width -gt 0 -and $_.Height -gt 0 -and
            ($_.Left -lt $w.Left -or $_.Top -lt $w.Top -or $_.Right -gt $w.Right -or $_.Bottom -gt $w.Bottom)
        } | ForEach-Object { "$($_.Class) $($_.Left)-$($_.Right)" })
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

# -----------------------------------------------------------------------------

$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN
$savedPipe = $env:GHOZTTY_PIPE_SUFFIX
$savedSlide = $env:GHOZTTY_STACK_SLIDE_MS
$env:GHOZTTY_PIPE_SUFFIX = "-stackslide$PID"
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

try {
    Assert (Test-Path $exe) 'ghoztty exe exists in zig-out'
    Assert (Test-Path $agent) 'ghoztty-agent exe exists in zig-out'
    [void](Assert-GhozttyIsolatedBuild -Exe $exe)
    if ($NegativeControl) {
        Say 'NEGATIVE CONTROL: the slide is 0 ms (an instant re-layout) - S1 MUST fail'
    }

    # ---- setup: P | (s1 | (s2 | s3)) at 900 DIP -------------------------------
    Say "== setup: P | (s1 | (s2 | s3)), 900 DIP wide, slide $slideMs ms"
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
    # A scripted split keeps the caret where it was and is FEATURED until the
    # next change of focus (T2257, Mac 71da9a680): it comes on show ahead of
    # the focused pane where the row has no room. This layout is about the
    # focus history, so the focus moves away and back, as a click would.
    $listed = ((& $exe +list --json 2>$null) -join "`n") | ConvertFrom-Json
    $node = @($listed.data.windows[0].tabs | Where-Object { $_.selected })[0].splits
    while ($null -ne $node -and $node.type -ne 'leaf') { $node = $node.left }
    $firstPane = if ($null -ne $node) { [string]$node.terminal.id } else { '' }
    if (-not $firstPane) { Write-TestAssertedNothing -Reason '+list named no first pane to give the focus back to' }
    $link = 'ghoztty-debug://focus/s1'; & $exe $link 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    $link = "ghoztty-debug://focus/$firstPane"; & $exe $link 2>&1 | Out-Null
    Start-Sleep -Milliseconds 800
    $names = @($null, 's1', 's2', 's3')
    Start-Sleep -Milliseconds 600
    $fourUp = @{}
    foreach ($q in @(Get-Panes $top)) { $fourUp[[string]$q.Hwnd] = "$($q.Right - $q.Left)x$($q.Bottom - $q.Top)" }
    [void](Set-TestWindowPos -Window $top -X 0 -Y 0 -Width (Get-TestChromeDip -Dip 900 -Scale $script:scale) -Height (Get-TestChromeDip -Dip 700 -Scale $script:scale))
    Start-Sleep -Milliseconds 800
    # The window resize itself must not slide; let anything it started end.
    $shown = @(Wait-Shown $top 2)
    Start-Sleep -Milliseconds ([math]::Max(600, $slideMs + 300))
    $all = @(Get-Panes $top)
    Say ("      dpi {0}; panes: {1}" -f $dpi, (Format-Cols $all))
    if ($shown.Count -ne 2 -or $all.Count -ne 4) { Write-TestAssertedNothing -Reason "the 900 DIP row never settled on two on show of four (got $($shown.Count) of $($all.Count))" }
    $tucked = @()
    for ($i = 0; $i -lt $all.Count; $i++) {
        if (-not $all[$i].Visible -and $names[$i]) { $tucked += [pscustomobject]@{ Pane = $all[$i]; Name = $names[$i] } }
    }
    if ($tucked.Count -eq 0) { Write-TestAssertedNothing -Reason 'no named pane was tucked' }

    # ---- S4: a pane tucks away at the size it had on show (T2105) ----------
    $heldOk = $true
    foreach ($q in $all) {
        $was = $fourUp[[string]$q.Hwnd]
        $is = "$($q.Right - $q.Left)x$($q.Bottom - $q.Top)"
        Say ("      pane {0} ({1}): four-up {2}, now {3}" -f $q.Hwnd, $(if ($q.Visible) { 'on show' } else { 'tucked' }), $was, $is)
        if (-not $q.Visible -and $is -ne $was) { $heldOk = $false }
    }
    $shownMoved = @($all | Where-Object { $_.Visible -and $fourUp[[string]$_.Hwnd] -ne "$($_.Right - $_.Left)x$($_.Bottom - $_.Top)" }).Count
    Assert ($shownMoved -ge 1) "S4: control - the narrower row resized the panes on show ($shownMoved of 2)"
    Assert $heldOk 'S4: every tucked pane kept the size it last had on show'
    # The tucked pane furthest from the run travels furthest.
    $t = $tucked[-1]
    $p = $t.Pane
    $startLeft = $p.Left

    # ---- the click, then sample every pane until the motion is over ----------
    Say "== click $($t.Name)'s strip and watch"
    $minStrip = [int][math]::Floor(8 * $script:scale)
    $sx = $p.Left + [int]($minStrip / 2)
    $sy = $p.Top + [int](($p.Bottom - $p.Top) / 2)
    [void](Send-TestMouse -Window $top -X $sx -Y $sy)
    $samples = New-Object System.Collections.Generic.List[object]
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt ($slideMs + 1200)) {
        $snap = @(Get-Panes $top)
        $samples.Add([pscustomobject]@{ Ms = $sw.ElapsedMilliseconds; Panes = $snap; Stray = @(Get-StrayPopups ([int]$app.Pid) $top) })
        Start-Sleep -Milliseconds 15
    }
    Start-Sleep -Milliseconds 300
    $after = @(Get-Panes $top)
    $me = @($after | Where-Object { $_.Hwnd -eq $p.Hwnd })
    $endLeft = if ($me.Count -eq 1) { $me[0].Left } else { $startLeft }
    Say ("      {0} samples; {1} went {2} -> {3}; settled: {4}" -f $samples.Count, $t.Name, $startLeft, $endLeft, (Format-Cols $after))

    # ---- S1: it slid --------------------------------------------------------
    $lo = [math]::Min($startLeft, $endLeft)
    $hi = [math]::Max($startLeft, $endLeft)
    $between = @{}
    foreach ($s in $samples) {
        foreach ($q in $s.Panes) {
            if ($q.Hwnd -ne $p.Hwnd -or -not $q.Visible) { continue }
            if ($q.Left -gt $lo -and $q.Left -lt $hi) { $between[[int]$q.Left] = $true }
        }
    }
    Say ("      positions strictly between: {0}" -f (($between.Keys | Sort-Object) -join ', '))
    Assert ($hi - $lo -gt (Get-TestChromeDip -Dip 40 -Scale $script:scale)) "S1: $($t.Name) moves a real distance ($lo..$hi px)"
    Assert ($between.Count -ge 2) "S1: $($t.Name) is seen at $($between.Count) positions on the way (need 2+): it slides, it does not jump"

    # ---- S6: nothing bleeds out of the window mid-slide (T2227) -------------
    $stray = @($samples | Where-Object { $_.Stray.Count -gt 0 })
    $first = if ($stray.Count -gt 0) { "at $($stray[0].Ms) ms: $($stray[0].Stray -join ' | ')" } else { '' }
    Assert ($stray.Count -eq 0) "S6: no popup reaches outside the window during the slide ($($stray.Count) of $($samples.Count) samples) $first"

    # ---- S2: one resize at most per pane ------------------------------------
    $hwnds = @($all | ForEach-Object { $_.Hwnd })
    $worst = 0
    foreach ($h in $hwnds) {
        $changes = 0
        $last = $null
        foreach ($s in $samples) {
            $q = @($s.Panes | Where-Object { $_.Hwnd -eq $h })
            if ($q.Count -ne 1 -or -not $q[0].Visible) { continue }
            $size = "$($q[0].Right - $q[0].Left)x$($q[0].Bottom - $q[0].Top)"
            if ($null -ne $last -and $size -ne $last) {
                $changes++
                Say ("      pane {0}: {1} -> {2} at {3} ms" -f $h, $last, $size, $s.Ms)
            }
            $last = $size
        }
        if ($changes -gt $worst) { $worst = $changes }
    }
    Assert ($worst -le 1) "S2: no pane window changed size more than once during the slide (worst $worst)"

    # ---- S3: the T2109 result at rest ---------------------------------------
    Assert ($me.Count -eq 1 -and $me[0].Visible) "S3: the clicked pane ($($t.Name)) is on show"
    Assert (@($after | Where-Object Visible).Count -eq 2) "S3: still two on show ($(@($after | Where-Object Visible).Count))"
    $focused = Focused-Pane-Name
    Assert ($focused -eq $t.Name) "S3: the clicked pane has focus (+list says '$focused')"

    # ---- S5: a window resize never resizes a tucked pane (T2105) ------------
    Say '== resize the window to 820 DIP with two tucked'
    $pre = @{}
    foreach ($q in $after) { $pre[[string]$q.Hwnd] = "$($q.Right - $q.Left)x$($q.Bottom - $q.Top)" }
    [void](Set-TestWindowPos -Window $top -X 0 -Y 0 -Width (Get-TestChromeDip -Dip 820 -Scale $script:scale) -Height (Get-TestChromeDip -Dip 640 -Scale $script:scale))
    Start-Sleep -Milliseconds ([math]::Max(800, $slideMs + 300))
    $resized = @(Get-Panes $top)
    $tuckedNow = @($resized | Where-Object { -not $_.Visible })
    $tuckedSame = @($tuckedNow | Where-Object { $pre[[string]$_.Hwnd] -eq "$($_.Right - $_.Left)x$($_.Bottom - $_.Top)" }).Count
    $shownChanged = @($resized | Where-Object { $_.Visible -and $pre[[string]$_.Hwnd] -ne "$($_.Right - $_.Left)x$($_.Bottom - $_.Top)" }).Count
    Say ("      after the resize: {0}" -f (Format-Cols $resized))
    Assert ($tuckedNow.Count -eq 2) "S5: still two tucked ($($tuckedNow.Count))"
    Assert ($shownChanged -ge 1) "S5: control - the resize resized the panes on show ($shownChanged)"
    Assert ($tuckedNow.Count -gt 0 -and $tuckedSame -eq $tuckedNow.Count) "S5: no tucked pane was resized ($tuckedSame of $($tuckedNow.Count) unchanged)"

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
        update -Guard pane-stack-slide -Repo $repo 2>&1 | ForEach-Object { Say "  $_" }
}

Say ''
Write-TestVerdict -Label 'T2102 PANE STACK SLIDE' -Pass $script:pass -Fail $script:fail
