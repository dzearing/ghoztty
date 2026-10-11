# T1835 acceptance: a divider drag or a window resize reaches the program in
# the pane as a HANDFUL of resizes, not one per mouse move - and the last size
# always arrives. Also: no "cols x rows" size overlay pops up by default.
#
# THE REPORT (Mac 733b03e58): every resize that reaches a program is, for a
# full-screen TUI like Claude Code, a clear-and-repaint. Applied every 25 ms, a
# 600 ms divider drag was ~35 repaints - the flicker. The shared termio thread
# (src/termio/Thread.zig, `Coalesce`) now applies resizes on a trailing
# debounce: 100 ms of quiet, never held longer than 350 ms. And
# `resize-overlay` now defaults to `never` (src/config/Config.zig). Both are
# shared core and reached this branch with the T1826 merge; this script is
# the Windows proof, the twin of Mac's
# `PaneSidebarWindowTests.aDragDoesNotStormTheProgramWithResizes`.
#
# THE ORACLE is the program, not the app. `lib\count-resizes.ps1` runs in the
# pane, asks the console for window input, and counts the
# WINDOW_BUFFER_SIZE_EVENTs conhost hands it - what a TUI on Windows repaints
# on, and therefore the thing whose count the user feels. It writes
# "<count> <cols>x<rows>" so the driver also knows the LAST size that landed.
#
# WHAT IS ASSERTED:
#   A. The counter counts single resizes (control): five window resizes half a
#      second apart arrive as five-ish events. Without A, B and C pass just as
#      well against a counter that cannot see resizes at all.
#   B. A posted divider drag (40 moves, a few ms apart) reaches the program as
#      at most  floor(drag_seconds / 0.35) + 2  resizes - Mac's own bound - and
#      at least one.
#   C. The same for a window-edge resize storm (40 SetWindowPos steps).
#   D. The final size is the TRUE final size: after B's storm the program holds
#      the same grid it gets when the divider is put at the same spot in ONE
#      move. Likewise for C against a single resize to the same width.
#   E. With the default config no size overlay appears during B/C; and with
#      `--resize-overlay=always` it does (so E's "none" is not a blind probe).
#
# Runs on the BACKGROUND test desktop (lib\TestDesktop.ps1), posted mouse
# messages and SetWindowPos only - no foreground taken.
#
# -NegativeControl inverts B's bound and MUST fail.
#
#   powershell -NoProfile -File test\win32\resize-debounce.ps1
param(
    [string]$ExePath,
    [int]$Moves = 40,
    [switch]$NegativeControl,
    [switch]$Interactive
)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }

$env:GHOZTTY_PIPE_SUFFIX = "-resizedeb$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
Assert-GhozttyIsolatedBuild -Exe $exe | Out-Null

$counter = Join-Path $PSScriptRoot 'lib\count-resizes.ps1'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$outDir = Join-Path $env:TEMP "ghoztty-resize-debounce\$stamp"
New-Item -ItemType Directory -Force $outDir | Out-Null

$script:pass = 0
$script:fail = 0
$script:skipped = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; $host.UI.WriteErrorLine("FAIL  $label") }
}

function Kill-RepoInstances { [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500) }

function Get-VisiblePanes([IntPtr]$top) {
    return @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal' | Where-Object Visible)
}

# { Count, Size } from the counter's file, or $null before it has started.
function Read-Counter([string]$file) {
    for ($t = 0; $t -lt 10; $t++) {
        try {
            $raw = [System.IO.File]::ReadAllText($file).Trim()
            if ($raw -match '^(\d+) (\d+x\d+)$') {
                return [pscustomobject]@{ Count = [int]$Matches[1]; Size = $Matches[2] }
            }
        } catch { }
        Start-Sleep -Milliseconds 20
    }
    return $null
}

# Wait until the counter has gone quiet for $quietMs (no new events), so a
# reading is the settled one, not a snapshot of a debounce still pending.
function Wait-CounterSettled([string]$file, [int]$quietMs = 1200, [int]$capMs = 8000) {
    $last = Read-Counter $file
    $quietSince = Get-Date
    $start = Get-Date
    while (((Get-Date) - $start).TotalMilliseconds -lt $capMs) {
        Start-Sleep -Milliseconds 100
        $now = Read-Counter $file
        if ($null -ne $now -and ($null -eq $last -or $now.Count -ne $last.Count)) {
            $last = $now; $quietSince = Get-Date
        }
        if (((Get-Date) - $quietSince).TotalMilliseconds -ge $quietMs) { break }
    }
    return $last
}

# Visible top-level STATIC popups of the app - the resize overlay's shape.
function Get-OverlayCount([int]$procId) {
    return @(Get-TestWindows -ProcessId $procId -Class 'Static' | Where-Object Visible).Count
}

# The root divider's screen point: the left pane's right edge.
function Get-DividerPoint([IntPtr]$top) {
    $sorted = @(Get-VisiblePanes $top | Sort-Object Left)
    if ($sorted.Count -lt 2) { return $null }
    return [pscustomobject]@{
        X = [int](($sorted[0].Right + $sorted[1].Left) / 2)
        Y = [int](($sorted[0].Top + $sorted[0].Bottom) / 2)
    }
}

function Get-RightPaneWidth([IntPtr]$top) {
    $p = @(Get-VisiblePanes $top | Sort-Object Left)
    return $p[$p.Count - 1].Width
}

# One divider drag of $moves moves, $step px each, monotonic. Returns the
# elapsed drag seconds. $sleepMs between moves; 0 moves = a single jump.
function Invoke-DividerDrag([IntPtr]$top, [int]$moves, [int]$step, [int]$sleepMs) {
    $pt = Get-DividerPoint $top
    if ($null -eq $pt) { return -1 }
    [void](Send-TestMouse -Window $top -Target $top -X $pt.X -Y $pt.Y -Action down -HoldMs 0)
    Start-Sleep -Milliseconds 60
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    for ($i = 1; $i -le $moves; $i++) {
        [void](Send-TestMouse -Window $top -Target $top -X ($pt.X + $i * $step) -Y $pt.Y -Action move -HoldMs 0)
        if ($sleepMs -gt 0) { Start-Sleep -Milliseconds $sleepMs }
    }
    $sw.Stop()
    [void](Send-TestMouse -Window $top -Target $top -X ($pt.X + $moves * $step) -Y $pt.Y -Action up -HoldMs 0)
    return $sw.Elapsed.TotalSeconds
}

function Invoke-DividerJump([IntPtr]$top, [int]$dx) {
    $pt = Get-DividerPoint $top
    if ($null -eq $pt) { return }
    [void](Send-TestMouse -Window $top -Target $top -X $pt.X -Y $pt.Y -Action down -HoldMs 0)
    Start-Sleep -Milliseconds 60
    [void](Send-TestMouse -Window $top -Target $top -X ($pt.X + $dx) -Y $pt.Y -Action move -HoldMs 0)
    Start-Sleep -Milliseconds 60
    [void](Send-TestMouse -Window $top -Target $top -X ($pt.X + $dx) -Y $pt.Y -Action up -HoldMs 0)
}

# Start an instance with a counter pane on the right. Returns @{ App; Top; File }.
function Start-CounterInstance([string]$name, [string[]]$extraArgs) {
    Kill-RepoInstances
    $log = Join-Path $outDir "$name-stderr.log"
    $file = Join-Path $outDir "$name-count.txt"
    $app = Start-OnTestDesktop -Exe $exe -StdErr $log -Arguments (@(
            '--config-default-files=false', '--session-persistence=false') + $extraArgs)
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow' -TimeoutMs 20000
    if ($top -eq [IntPtr]::Zero) { throw "no window for the $name instance" }
    [void](Set-TestWindowPos -Window ([IntPtr]$top) -X 40 -Y 40 -Width 1400 -Height 900)
    Start-Sleep -Milliseconds 800
    & $exe +split --direction=right -e powershell -NoProfile -ExecutionPolicy Bypass `
        -File $counter -Out $file 2>&1 | Out-Null
    for ($t = 0; $t -lt 80; $t++) {
        Start-Sleep -Milliseconds 250
        if (@(Get-VisiblePanes ([IntPtr]$top)).Count -ge 2 -and (Read-Counter $file)) { break }
    }
    if (-not (Read-Counter $file)) { throw "the resize counter never started in the $name instance" }
    [void](Wait-CounterSettled $file)
    return @{ App = $app; Top = [IntPtr]$top; File = $file }
}

$td = New-TestDesktop -Interactive:$Interactive
try {
    Write-Host "T1835 resize debounce, $stamp  exe: $exe"

    $i = Start-CounterInstance 'default' @()
    $top = $i.Top; $file = $i.File; $procId = $i.App.Pid

    # ---- A. control: the counter sees single resizes ----------------------
    $before = (Wait-CounterSettled $file).Count
    for ($k = 1; $k -le 5; $k++) {
        [void](Set-TestWindowPos -Window $top -X 40 -Y 40 -Width (1400 - $k * 80) -Height 900)
        Start-Sleep -Milliseconds 600
    }
    $a = Wait-CounterSettled $file
    $slow = $a.Count - $before
    Write-Host "  control: 5 resizes 600ms apart reached the program as $slow"
    Assert ($slow -ge 4) "the counter sees separate resizes as separate events (5 slow resizes -> $slow)"
    [void](Set-TestWindowPos -Window $top -X 40 -Y 40 -Width 1400 -Height 900)
    [void](Wait-CounterSettled $file)

    # ---- B. divider drag storm -------------------------------------------
    $overlaysSeen = 0
    $before = (Wait-CounterSettled $file).Count
    $widthBefore = Get-RightPaneWidth $top
    $secs = Invoke-DividerDrag $top $Moves -6 0
    $overlaysSeen += Get-OverlayCount $procId
    $b = Wait-CounterSettled $file
    $during = $b.Count - $before
    $allowed = [int][math]::Floor($secs / 0.35) + 2
    $stormWidth = Get-RightPaneWidth $top
    Write-Host ("  divider drag: {0} moves in {1:N0}ms, pane {2}->{3}px, reached the program as {4} resizes (allowed {5})" -f `
            $Moves, ($secs * 1000), $widthBefore, $stormWidth, $during, $allowed)
    Assert ($secs -gt 0 -and $stormWidth -ne $widthBefore) "the divider drag really moved the pane ($widthBefore -> $stormWidth px)"
    Assert ($during -ge 1) "the divider drag's final size reached the program ($during resizes)"
    # A drag whose moves arrive further apart than the 100 ms settle is not a
    # storm - each move legitimately settles - so the bound would be judging
    # the box's speed, not the debounce. Say so instead of failing on it.
    $perMoveMs = ($secs * 1000) / $Moves
    if ($perMoveMs -ge 90 -and -not $NegativeControl) {
        $script:skipped++
        Write-Host ("SKIP  divider storm bound: moves arrived {0:N0}ms apart, too slow to be a burst (needs < 90ms)" -f $perMoveMs)
    } else {
        $ok = ($during -le $allowed)
        if ($NegativeControl) { $ok = -not $ok }
        Assert $ok ("a {0:N0}ms divider drag reached the program as {1} resizes, not one per move (allowed {2}, moves {3}, {4:N0}ms apart)" -f `
                ($secs * 1000), $during, $allowed, $Moves, $perMoveMs)
    }

    # ---- D (divider). the storm's last size is the true size --------------
    $stormSize = $b.Size
    Invoke-DividerJump $top ($Moves * 6)   # back where it started
    [void](Wait-CounterSettled $file)
    Invoke-DividerJump $top (-$Moves * 6)  # one move to the storm's end point
    $j = Wait-CounterSettled $file
    $jumpWidth = Get-RightPaneWidth $top
    Write-Host "  divider end state: storm $stormSize at ${stormWidth}px, single move $($j.Size) at ${jumpWidth}px"
    if ($jumpWidth -eq $stormWidth) {
        Assert ($j.Size -eq $stormSize) "after the divider drag the program holds the true final size ($stormSize == $($j.Size))"
    } else {
        $script:skipped++
        Write-Host "SKIP  divider end-state compare: the single move landed at ${jumpWidth}px, not ${stormWidth}px"
    }

    # ---- C. window-edge resize storm --------------------------------------
    $before = (Wait-CounterSettled $file).Count
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    for ($k = 1; $k -le $Moves; $k++) {
        [void](Set-TestWindowPos -Window $top -X 40 -Y 40 -Width (1400 - $k * 8) -Height 900)
        Start-Sleep -Milliseconds 12
    }
    $sw.Stop()
    $overlaysSeen += Get-OverlayCount $procId
    $c = Wait-CounterSettled $file
    $during = $c.Count - $before
    $secs = $sw.Elapsed.TotalSeconds
    $allowed = [int][math]::Floor($secs / 0.35) + 2
    Write-Host ("  window resize: {0} steps in {1:N0}ms reached the program as {2} resizes (allowed {3})" -f `
            $Moves, ($secs * 1000), $during, $allowed)
    Assert ($during -ge 1) "the window resize's final size reached the program ($during resizes)"
    Assert ($during -le $allowed) ("a {0:N0}ms window resize reached the program as {1} resizes (allowed {2})" -f `
            ($secs * 1000), $during, $allowed)

    # ---- D (window). the storm's last size is the true size ---------------
    $stormSize = $c.Size
    $endWidth = 1400 - $Moves * 8
    [void](Set-TestWindowPos -Window $top -X 40 -Y 40 -Width 1400 -Height 900)
    [void](Wait-CounterSettled $file)
    [void](Set-TestWindowPos -Window $top -X 40 -Y 40 -Width $endWidth -Height 900)
    $j = Wait-CounterSettled $file
    Assert ($j.Size -eq $stormSize) "after the window resize the program holds the true final size ($stormSize == $($j.Size))"

    # ---- E. no size overlay by default -------------------------------------
    Assert ($overlaysSeen -eq 0) "no size overlay appeared during the drag or the resize with the default config ($overlaysSeen seen)"

    # ...and the probe can see one when it is asked for.
    $i2 = Start-CounterInstance 'always' @('--resize-overlay=always')
    [void](Set-TestWindowPos -Window $i2.Top -X 40 -Y 40 -Width 1200 -Height 900)
    Start-Sleep -Milliseconds 150
    $shown = Get-OverlayCount $i2.App.Pid
    Assert ($shown -ge 1) "with resize-overlay=always the same probe sees the overlay ($shown visible)"

    Complete-TestBody
}
finally {
    Kill-RepoInstances
    Remove-TestDesktop
}

# --- stamp (T783) ----------------------------------------------------------
if ($script:fail -eq 0 -and $script:skipped -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard resize-debounce -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Skipped $script:skipped
