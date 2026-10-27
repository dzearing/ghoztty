# T2336 acceptance: the pane sidebar is ONE sidebar seen from every window
# (Mac b07b7fa0b / 9a1f14230, `PaneSidebarSharedState`). A change made in one
# window - collapse/expand, the panel's width, the all-windows scope, a fold,
# the search, hide/show - is in every other window's sidebar once that window
# is activated, and NOT before: only the window in use redraws as the change
# happens (Mac `isLive` / `catchUp`).
#
# Layout: window A ("alpha") and window B ("beta"), both wide enough for the
# panel. Every change is made in A while A is the active window; B is then
# checked UNCHANGED, activated (a real WM_ACTIVATE through the test desktop's
# input queue - lib\TestDesktop.ps1 `Set-TestActiveWindow`), and checked
# CAUGHT UP:
#
#   1. Expand: A's panel at 240 DIP; B still the rail; activated, B's panel.
#   2. Width: an edge drag widens A's panel to 300; B still 240; activated,
#      300.
#   3. Scope + an absolute fold: A turns all windows on (A open, B folded) and
#      unfolds B. Activated, B lists every window with NOTHING folded - the
#      folds are by window, not relative to the window looking (before T2336
#      B would open with its own group open and A folded).
#   4. Search: typed in A; activated, B's list is filtered by the same query.
#   5. Hide: ctrl+shift+s in A hides A's sidebar; B still shows; activated,
#      B's is hidden.
#
# Which window caught up comes from the `pane sidebar catch up window=<hwnd>`
# log lines (one process logs for both windows); sizes come from the
# sidebar child windows themselves.
#
# Runs on a BACKGROUND desktop (lib\TestDesktop.ps1) and never takes the
# user's foreground - asserted by the foreground watcher, not assumed.
# -NegativeControl never activates B after the expand, so B stays on the rail
# and the run MUST fail.
#
#   powershell -NoProfile -File test\win32\pane-sidebar-shared.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [switch]$NegativeControl,
    [switch]$Interactive
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:passes = 0
$tmp = Join-Path $env:TEMP "ghoztty-t2336-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ } else { "  FAIL $name"; $script:failures++ }
}
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 't2336')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\ChromeGeometry.ps1')

$Cli = [System.IO.Path]::ChangeExtension($Exe, '.com')
if (-not (Test-Path $Cli)) { $Cli = $Exe }

function Invoke-Cli([string]$CliArgs) {
    cmd /c "`"$Cli`" $CliArgs > `"$tmp\out.txt`" 2> `"$tmp\err.txt`"" | Out-Null
    return $LASTEXITCODE
}
function Get-CliErr { (Get-Content "$tmp\err.txt" -Raw -ErrorAction SilentlyContinue) }

function Get-Sidebar($top) { @(Get-TestChildWindows -Window $top -Class 'GhozttyPaneSidebar') | Select-Object -First 1 }
function Get-Panes($top) { @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal') }
function Px([double]$Dip) { Get-TestChromeDip -Dip $Dip -Scale $script:scale }
function Near([int]$A, [int]$B) { [math]::Abs($A - $B) -le 2 }
# T2290: an expanded column is the card at $Dip in the rail's 12 DIP insets;
# the 76 DIP rail is already a column width (flat style).
function Width-Is($top, [double]$Dip) {
    $sb = Get-Sidebar $top
    $want = if ($Dip -eq 76) { Px 76 } else { (Px 12) + (Px $Dip) + (Px 12) }
    return ($null -ne $sb -and $sb.Visible -and (Near $sb.Width $want))
}
function Is-Hidden($top) { $sb = Get-Sidebar $top; return ($null -eq $sb -or -not $sb.Visible) }
function Describe($top) {
    $sb = Get-Sidebar $top
    if ($null -eq $sb) { return '<none>' }
    return "visible=$($sb.Visible) width=$($sb.Width)"
}

function Get-LogCount { @(Get-Content $script:errlog -ErrorAction SilentlyContinue).Count }
function Wait-Log([string]$Pattern, [int]$Skip, [int]$Ms = 4000) {
    $deadline = (Get-Date).AddMilliseconds($Ms)
    $hit = $null
    do {
        Start-Sleep -Milliseconds 150
        $hit = @(Get-Content $script:errlog -ErrorAction SilentlyContinue | Select-Object -Skip $Skip | Where-Object { $_ -match $Pattern }) | Select-Object -Last 1
    } while (-not $hit -and (Get-Date) -lt $deadline)
    return $hit
}
function ClickAt($top, $sb, $pt) {
    return Send-TestMouse -Window $top -Target ([IntPtr]$sb.Hwnd) -X ($sb.Left + $pt.X) -Y ($sb.Top + $pt.Y) -Action click
}
# The collapse/expand toggle (pane-sidebar-all-windows.ps1's Get-ToggleCenter).
function Get-ToggleCenter($sb) {
    $margin = Px 12; $card = Px 52; $tile = Px 28
    $inset = [int][math]::Truncate(($card - $tile) / 2)
    return @{ X = $margin + $inset + [int]($tile / 2); Y = $margin + $inset + [int]($tile / 2) }
}
function Get-ScopeCenter($sb) {
    return @{ X = $sb.Width - (Px 4) - [int]((Px 28) / 2); Y = (Get-ToggleCenter $sb).Y }
}
function Invoke-EdgeDrag($top, $target, [int]$x0, [int]$y, [double[]]$steps) {
    $ok = Send-TestMouse -Window $top -Target ([IntPtr]$target) -X $x0 -Y $y -Action down
    $x = $x0
    foreach ($s in $steps) {
        $x = $x0 + (Px $s)
        [void](Send-TestMouse -Window $top -Target ([IntPtr]$target) -X $x -Y $y -Action move)
        Start-Sleep -Milliseconds 120
    }
    [void](Send-TestMouse -Window $top -Target ([IntPtr]$target) -X $x -Y $y -Action up)
    Start-Sleep -Milliseconds 500
    return $ok
}
# The newest `pane sidebar outline mode=expanded` line's chevrons and search
# field (pane-sidebar-all-windows.ps1 reads the same line).
function Read-OutlineLine([int]$Skip) { Wait-Log 'pane sidebar outline mode=expanded' $Skip 2000 }
# Activate $top for real. The log line count from just before is left in
# $script:mark (the function's output is its assertion line).
function Activate($top, [string]$Name) {
    $script:mark = Get-LogCount
    $ok = Set-TestActiveWindow -Window $top
    Start-Sleep -Milliseconds 700
    Assert "setup: $Name is the active window" $ok
}
function CatchUpLine($top, [int]$Skip, [string]$Kind) {
    $id = [int64]$top
    $pat = if ($Kind -eq 'window') { "pane sidebar catch up window=$id expanded=" } else { "pane sidebar catch up window=$id all_windows=" }
    return Wait-Log $pat $Skip 3000
}

. (Join-Path $PSScriptRoot 'lib\Transcript.ps1')
$transcript = New-TestTranscript -Name 't2336'

Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$script:reachedEnd = $false
$script:scale = 1.0

& {
try {
    [void](Stop-RepoGhoztty -Exe $Exe -AppOnly -SettleMs 500)
    Assert-GhozttyPrivateEndpoint -Exe $Exe
    # Fresh defaults: LOCALAPPDATA is this run's, so the shared flags start
    # from the rail whatever an earlier run left.
    $fakeLocal = Join-Path $tmp 'local'
    New-Item -ItemType Directory -Force -Path (Join-Path $fakeLocal 'ghoztty') | Out-Null
    $script:errlog = Join-Path $tmp 'app-stderr.log'
    $saved = $env:LOCALAPPDATA
    $env:LOCALAPPDATA = $fakeLocal
    try {
        $app = Start-OnTestDesktop -Exe $Exe -StdErr $script:errlog -Arguments @('--session-persistence=false', '--macos-pane-style=flat')
    } finally { $env:LOCALAPPDATA = $saved }
    Start-Sleep -Seconds 3
    $topA = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($topA -eq [IntPtr]::Zero) { "  SETUP FAIL: top window not found"; $script:failures++; return }
    Assert "window is NOT enumerable on the interactive desktop" (-not (Test-TestDesktopLeak -ProcessId $app.Pid))
    $dpi = Get-TestWindowDpi -Window $topA
    if ($dpi -gt 0) { $script:scale = $dpi / 96.0 }
    "  (window dpi $dpi, scale $($script:scale))"
    [void](Set-TestWindowSize -Window $topA -Width (Px 1100) -Height (Px 800))
    Assert "setup: window A titled alpha ($(Get-CliErr))" ((Invoke-Cli "+rename --target=window-1 --title=alpha") -eq 0)
    Assert "setup: window B opened ($(Get-CliErr))" ((Invoke-Cli "+new-window --target=wB --name=b1 --title=beta") -eq 0)
    Start-Sleep -Milliseconds 1500
    $topB = @(Get-TestWindows -ProcessId $app.Pid -Class 'GhozttyWindow' | Where-Object { [IntPtr]$_.Hwnd -ne $topA }) | Select-Object -First 1
    Assert "setup: window B found" ($null -ne $topB)
    if ($null -eq $topB) { return }
    $topB = [IntPtr]$topB.Hwnd
    [void](Set-TestWindowSize -Window $topB -Width (Px 1100) -Height (Px 800))
    Start-Sleep -Milliseconds 600
    Assert "setup: both open on the rail (A $(Describe $topA), B $(Describe $topB))" ((Width-Is $topA 76) -and (Width-Is $topB 76))

    "== 1: expand in A; B catches up when it is activated"
    Activate $topA 'A'
    $sb = Get-Sidebar $topA
    Assert "toggle click delivered" (ClickAt $topA $sb (Get-ToggleCenter $sb))
    Start-Sleep -Milliseconds 800
    Assert "A expanded: the 240 DIP panel ($(Describe $topA))" (Width-Is $topA 240)
    Assert "B, in the background, is untouched: still the rail ($(Describe $topB))" (Width-Is $topB 76)
    if ($NegativeControl) {
        "  NEGATIVE CONTROL: B is never activated - this run MUST fail"
        $mark = Get-LogCount
    } else {
        Activate $topB 'B'; $mark = $script:mark
    }
    Assert "B logged its catch-up: expanded" ($null -ne (CatchUpLine $topB $mark 'window') -and (CatchUpLine $topB $mark 'window') -match 'expanded=true hidden=false width=240')
    Assert "B now shows the 240 DIP panel ($(Describe $topB))" (Width-Is $topB 240)

    "== 2: the panel's width, dragged in A, reaches B on activation"
    Activate $topA 'A'
    $sb = Get-Sidebar $topA
    [void](Invoke-EdgeDrag $topA $sb.Hwnd ($sb.Right - 2) ($sb.Top + (Px 300)) @(30, 60))
    Assert "A's panel widened to 300 ($(Describe $topA))" (Width-Is $topA 300)
    Assert "B's is still 240 until activated ($(Describe $topB))" (Width-Is $topB 240)
    Activate $topB 'B'; $mark = $script:mark
    Assert "B caught up the width (log)" ((CatchUpLine $topB $mark 'window') -match 'width=300')
    Assert "B's panel is 300 ($(Describe $topB))" (Width-Is $topB 300)

    "== 3: all windows on in A, B unfolded there; B lists both, nothing folded"
    Activate $topA 'A'
    $sb = Get-Sidebar $topA
    $mark = Get-LogCount
    Assert "scope click delivered" (ClickAt $topA $sb (Get-ScopeCenter $sb))
    Assert "A's scope is on (log)" ($null -ne (Wait-Log 'pane sidebar scope all_windows=true' $mark))
    $g = Wait-Log 'pane sidebar all-windows groups=2 ' $mark
    Assert "A lists two windows, beta folded ($g)" ($g -match ' folded=1 ')
    # Unfold beta through its chevron (groups sort by name: alpha 0, beta 1).
    $line = Read-OutlineLine $mark
    $chev = @()
    if ($line -match ' chev=(\S*)') { $chev = @($Matches[1] -split ';' | Where-Object { $_ } | ForEach-Object { $xy = $_ -split ','; @{ X = [int]$xy[0]; Y = [int]$xy[1] } }) }
    Assert "A's outline logs two chevrons ($($chev.Count))" ($chev.Count -eq 2)
    if ($chev.Count -eq 2) {
        $mark = Get-LogCount
        [void](ClickAt $topA $sb $chev[1])
        Assert "the chevron unfolded beta in A (log)" ($null -ne (Wait-Log 'pane sidebar unfold' $mark 2000))
        Assert "A's list: nothing folded" ($null -ne (Wait-Log 'pane sidebar all-windows groups=2 .* folded=0 ' $mark))
    }
    Activate $topB 'B'; $mark = $script:mark
    $cu = CatchUpLine $topB $mark 'sidebar'
    "  $cu"
    Assert "B caught up the scope (log)" ($cu -match 'all_windows=true')
    Assert "...with both windows unfolded, by window not by viewer" ($cu -match 'unfolded=2 ')
    Assert "B's own list: two windows, nothing folded" ($null -ne (Wait-Log 'pane sidebar all-windows groups=2 .* folded=0 ' $mark))

    "== 4: a search typed in A filters B's list once B is activated"
    Activate $topA 'A'
    $sb = Get-Sidebar $topA
    $line = Read-OutlineLine 0
    $sp = $null
    if ($line -match ' search=(-?\d+),(-?\d+) nomatch=(\d)') { $sp = @{ X = [int]$Matches[1]; Y = [int]$Matches[2] } }
    Assert "A's outline logs the search field" ($null -ne $sp)
    $mark = Get-LogCount
    if ($sp) { [void](ClickAt $topA $sb $sp) }
    Assert "the field took the keyboard (log)" ($null -ne (Wait-Log 'pane sidebar search focus=true' $mark 3000))
    $mark = Get-LogCount
    [void](Send-TestControlText -Control ([IntPtr]$sb.Hwnd) -Text 'beta')
    Assert "A's list keeps only beta" ($null -ne (Wait-Log 'pane sidebar all-windows groups=1 .*search=1 .*order=beta$' $mark))
    Activate $topB 'B'; $mark = $script:mark
    $cu = CatchUpLine $topB $mark 'sidebar'
    Assert "B caught up the query (log: $cu)" ($cu -match 'search=4 ')
    Assert "B's list is filtered by it" ($null -ne (Wait-Log 'pane sidebar all-windows groups=1 .*search=1 .*order=beta$' $mark))

    "== 5: hide in A; B hides when activated"
    Activate $topA 'A'
    $pane = @(Get-Panes $topA) | Select-Object -First 1
    if ($pane) { [void](Focus-TestWindow -Window $topA -Child ([IntPtr]$pane.Hwnd)) }
    Assert "ctrl+shift+s delivered" ($null -ne $pane -and (Send-TestKeys -Window $topA -Target ([IntPtr]$pane.Hwnd) -Modifiers ctrl,shift -Key S))
    Start-Sleep -Milliseconds 700
    Assert "A's sidebar is hidden ($(Describe $topA))" (Is-Hidden $topA)
    Assert "B's still shows until activated ($(Describe $topB))" (-not (Is-Hidden $topB))
    Activate $topB 'B'; $mark = $script:mark
    Assert "B caught up hidden (log)" ((CatchUpLine $topB $mark 'window') -match 'hidden=true')
    Assert "B's sidebar is hidden ($(Describe $topB))" (Is-Hidden $topB)

    $script:reachedEnd = $true
} catch {
    "  FAIL body threw: $($_.Exception.Message)"
    $script:failures++
} finally {
    Remove-TestDesktop
    [void](Stop-RepoGhoztty -Exe $Exe -AppOnly -SettleMs 500)
}

Assert "the body ran to its last section" ($script:reachedEnd -eq $true)
$fgSeen = @(Stop-TestForegroundWatch)
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    Assert "the foreground watcher actually sampled (negative control)" ($fgSeen.Count -gt 0)
    Assert "no test-desktop app ever became foreground on the interactive desktop" (-not ($fgSeen -contains $app.Pid))
}
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

} 2>&1 | Tee-Object -FilePath $transcript

Complete-TestBody  # T1039: the run reached the end of its body

if ($script:failures -eq 0 -and -not $NegativeControl) {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard pane-sidebar-shared -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

""
exit (Complete-TestTranscript -Name 't2336' -Path $transcript `
        -Label 'T2336 ACCEPTANCE' -Pass $script:passes -Fail $script:failures).Code
