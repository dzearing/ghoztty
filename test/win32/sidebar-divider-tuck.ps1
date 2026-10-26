# T2277 acceptance: a divider pushed left past every pane it has tucked into
# strips tucks the expanded pane sidebar into its rail, and dragged back in the
# same drag brings it out (Mac 075d787d1 `sidebarAwareRow`).
#
# THE CLAIM. In a row spanning the grid the sidebar is the row's first item:
# once the panes before the gutter are strips, pushing on by the panel's give
# (`pane_sidebar.dividerTuckGiveDip`) collapses the panel to the rail, and the
# row measures the room it gained. Back past that point (plus the hysteresis)
# it expands again, all within one drag. A nudge never touches the sidebar.
#
# Layout: P | s1 | s2 in a wide window, flat style, the sidebar expanded by
# its header toggle.
#
# Claims:
#   A) the toggle expanded the sidebar to the panel (wider than the rail)
#   B) a nudge of the P|s1 divider leaves the panel expanded and logs no
#      divider-drag cause
#   C) the divider dragged to the window's left edge tucks the panel into the
#      76 DIP rail, logged `expanded=false cause=divider drag`
#   D) still held, dragged back to where it began: the panel comes out again,
#      logged `expanded=true cause=divider drag back`, and let go there the
#      three panes are all on show
#
# -NegativeControl inverts claim C to "the sidebar stayed expanded" - the
# answer the pre-T2277 build gives - and MUST fail.
#
# Hermetic: per-run LOCALAPPDATA, a private IPC pipe suffix, persistence off,
# and it only ever kills ghoztty processes launched from this repo's zig-out.
# Runs on the BACKGROUND test desktop.
#
#   powershell -NoProfile -File test\win32\sidebar-divider-tuck.ps1
param(
    [string]$ExePath,
    [switch]$NegativeControl,
    [switch]$Interactive
)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }

$script:pass = 0
$script:fail = 0
$root = Join-Path $env:TEMP "ghoztty-sidebar-divider-tuck-$PID"

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

$script:scale = 1.0
function Px([double]$Dip) { Get-TestChromeDip -Dip $Dip -Scale $script:scale }

function Get-VisiblePanes([IntPtr]$top) {
    return @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal' | Where-Object Visible | Sort-Object Left)
}
function Get-Sidebar([IntPtr]$top) { @(Get-TestChildWindows -Window $top -Class 'GhozttyPaneSidebar') | Select-Object -First 1 }
function Wait-Columns([IntPtr]$top, [int]$n, [int]$timeoutSec = 20) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    do {
        $v = @(Get-VisiblePanes $top)
        if ($v.Count -eq $n) { return $v }
        Start-Sleep -Milliseconds 300
    } while ((Get-Date) -lt $deadline)
    return @(Get-VisiblePanes $top)
}
function Get-NewLog([int]$Skip) { @(Get-Content $script:errlog -ErrorAction SilentlyContinue | Select-Object -Skip $Skip) }
function Get-LogCount { @(Get-Content $script:errlog -ErrorAction SilentlyContinue).Count }
function Test-IsRail($sb) { $null -ne $sb -and [math]::Abs($sb.Width - (Px 76)) -le 1 }

# -----------------------------------------------------------------------------

$savedLocalAppData = $env:LOCALAPPDATA
$savedPipe = $env:GHOZTTY_PIPE_SUFFIX
$env:GHOZTTY_PIPE_SUFFIX = "-sbtuck$PID"

Stop-RepoInstances
New-Item -ItemType Directory -Force $root | Out-Null
$tmp = Join-Path $root 'app'
New-Item -ItemType Directory -Force $tmp | Out-Null
$env:LOCALAPPDATA = $tmp
$script:errlog = Join-Path $root 'app-stderr.log'

Reset-TestBody
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    Assert (Test-Path $exe) 'ghoztty exe exists in zig-out'
    [void](Assert-GhozttyIsolatedBuild -Exe $exe)
    if ($NegativeControl) {
        Say 'NEGATIVE CONTROL: claim C is inverted to "the sidebar stayed expanded" - this run MUST fail'
    }

    # ---- setup: P | s1 | s2, sidebar expanded --------------------------------
    Say '== setup: P | s1 | s2'
    $app = Start-OnTestDesktop -Exe $exe -StdErr $script:errlog -Arguments @('--config-default-files=false', '--session-persistence=false', '--macos-pane-style=flat')
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { Write-TestAssertedNothing -Reason 'the app never opened a GhozttyWindow' }
    $dpi = [int](Get-TestWindowDpi -Window $top)
    if ($dpi -le 0) { $dpi = 96 }
    $script:scale = $dpi / 96.0
    # Room for the panel and three panes at their minimums, in DIP.
    [void](Set-TestWindowPos -Window $top -X 0 -Y 0 -Width (Get-TestChromeDip -Dip 1500 -Scale $script:scale) -Height (Get-TestChromeDip -Dip 700 -Scale $script:scale))
    Start-Sleep -Seconds 2
    & $exe +split --direction=right --name=s1 | Out-Null
    Start-Sleep -Milliseconds 800
    & $exe +split --pane=s1 --direction=right --name=s2 | Out-Null
    $c3 = @(Wait-Columns $top 3)
    if ($c3.Count -ne 3) { Write-TestAssertedNothing -Reason "three columns never came up (got $($c3.Count))" }

    # ---- A: expand by the header toggle --------------------------------------
    Say '== A: expand the sidebar'
    $sb = Get-Sidebar $top
    if ($null -eq $sb) { Write-TestAssertedNothing -Reason 'no GhozttyPaneSidebar child' }
    if (Test-IsRail $sb) {
        # The toggle: centered in the rail card, the card's inset below its top
        # (pane-sidebar.ps1 Get-ToggleCenter).
        $margin = Px 12; $card = Px 52; $tile = Px 28
        $inset = [int][math]::Truncate(($card - $tile) / 2)
        $pt = @{ X = $sb.Left + $margin + $inset + [int]($tile / 2); Y = $sb.Top + $margin + $inset + [int]($tile / 2) }
        [void](Send-TestMouse -Window $top -Target ([IntPtr]$sb.Hwnd) -X $pt.X -Y $pt.Y -Action click)
        Start-Sleep -Milliseconds 900
    }
    $sb = Get-Sidebar $top
    $panelW = $sb.Width
    Assert ((-not (Test-IsRail $sb)) -and $panelW -gt (Px 150)) "A: the sidebar is the expanded panel ($panelW px, the rail is $(Px 76))"
    if (Test-IsRail $sb) { Write-TestAssertedNothing -Reason 'the sidebar never expanded' }
    Start-Sleep -Milliseconds 500
    $c3 = @(Get-VisiblePanes $top)
    Say ("      sidebar {0}..{1}; columns: {2}" -f $sb.Left, $sb.Right, (($c3 | ForEach-Object { "$($_.Left)-$($_.Right)" }) -join ' | '))

    $x0 = [int](($c3[0].Right + $c3[1].Left) / 2)
    $y = [int](($c3[0].Top + $c3[0].Bottom) / 2)

    # ---- B: a nudge ----------------------------------------------------------
    Say '== B: nudge the P|s1 divider'
    $before = Get-LogCount
    [void](Send-TestMouse -Window $top -Target $top -X $x0 -Y $y -Action down -HoldMs 0)
    Start-Sleep -Milliseconds 120
    foreach ($dx in 15, 30, 45, 60) {
        [void](Send-TestMouse -Window $top -Target $top -X ($x0 - $dx) -Y $y -Action move -HoldMs 0)
        Start-Sleep -Milliseconds 80
    }
    [void](Send-TestMouse -Window $top -Target $top -X $x0 -Y $y -Action move -HoldMs 0)
    Start-Sleep -Milliseconds 80
    [void](Send-TestMouse -Window $top -Target $top -X $x0 -Y $y -Action up -HoldMs 0)
    Start-Sleep -Milliseconds 500
    $new = Get-NewLog $before
    $sb = Get-Sidebar $top
    Assert (-not (Test-IsRail $sb)) "B: after a nudge the panel is still expanded ($($sb.Width) px)"
    Assert (@($new | Where-Object { $_ -match 'cause=divider drag' }).Count -eq 0) 'B: ...and nothing logged a divider-drag collapse'
    $c3 = @(Wait-Columns $top 3 5)
    $x0 = [int](($c3[0].Right + $c3[1].Left) / 2)

    # ---- C / D: to the window's edge, and back, in one drag -----------------
    Say '== C: drag the P|s1 divider to the window''s left edge'
    $client = Get-TestWindowRect -Window $top -Client
    $before = Get-LogCount
    [void](Send-TestMouse -Window $top -Target $top -X $x0 -Y $y -Action down -HoldMs 0)
    Start-Sleep -Milliseconds 120
    $edge = $client.Left + 2
    $tuckedAt = $null
    $x = $x0
    while ($x -gt $edge) {
        $x = [math]::Max($edge, $x - 40)
        [void](Send-TestMouse -Window $top -Target $top -X $x -Y $y -Action move -HoldMs 0)
        Start-Sleep -Milliseconds 60
        if ($null -eq $tuckedAt -and (Test-IsRail (Get-Sidebar $top))) { $tuckedAt = $x }
    }
    Start-Sleep -Milliseconds 400
    $sb = Get-Sidebar $top
    $new = Get-NewLog $before
    Say ("      tucked at screen x={0} (sidebar now {1} px)" -f $tuckedAt, $sb.Width)
    if ($NegativeControl) {
        Assert (-not (Test-IsRail $sb)) 'NEGATIVE: the sidebar stayed expanded at the window''s edge'
    } else {
        Assert (Test-IsRail $sb) "C: at the window's edge the panel tucked into the 76 DIP rail ($($sb.Width) px)"
        Assert (@($new | Where-Object { $_ -match 'pane sidebar expanded=false cause=divider drag\s*$' }).Count -eq 1) 'C: ...once, logged with its cause (divider drag)'
        Assert ($null -ne $tuckedAt -and $tuckedAt -lt $x0 - (Px 100)) "C: ...only once pushed well past the nudge (at x=$tuckedAt, began at $x0)"
    }

    Say '== D: back where it began, still held'
    $before = Get-LogCount
    while ($x -lt $x0) {
        $x = [math]::Min($x0, $x + 40)
        [void](Send-TestMouse -Window $top -Target $top -X $x -Y $y -Action move -HoldMs 0)
        Start-Sleep -Milliseconds 60
    }
    Start-Sleep -Milliseconds 400
    $sb = Get-Sidebar $top
    $new = Get-NewLog $before
    Assert (-not (Test-IsRail $sb) -and [math]::Abs($sb.Width - $panelW) -le 1) "D: dragged back, the panel came out at its width ($($sb.Width) vs $panelW px)"
    Assert (@($new | Where-Object { $_ -match 'pane sidebar expanded=true cause=divider drag back' }).Count -eq 1) 'D: ...logged with its cause (divider drag back)'
    [void](Send-TestMouse -Window $top -Target $top -X $x0 -Y $y -Action up -HoldMs 0)
    Start-Sleep -Milliseconds 600
    $c3b = @(Wait-Columns $top 3 5)
    Assert ($c3b.Count -eq 3) "D: let go where it began, all three panes are on show (got $($c3b.Count))"

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

if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard sidebar-divider-tuck -Repo $repo 2>&1 | ForEach-Object { Say "  $_" }
}

Say ''
Write-TestVerdict -Label 'T2277 SIDEBAR DIVIDER TUCK' -Pass $script:pass -Fail $script:fail
