# T2332 acceptance: what a pane sidebar SCROLL STEP costs on Windows, in the
# scenario Mac 321e61d7c measured - 40 windows, two panes each, a dozen busy
# panes, the all-windows list with every window unfolded. On the Mac a step
# cost 31-50 ms before that commit (the shimmer re-ran the whole sidebar
# update every frame) and ~8 ms after; at rest the main thread sat under 1%
# of a core. T1925 measured the busy sheen's frame cost here
# (pane-sidebar-motion-cost.ps1); this is the other two numbers.
#
# A wheel step here invalidates the whole column (the rows all move), so the
# step's cost is one full-column paint; since T2332 the first paint after a
# step times itself and logs `pane sidebar scroll paint us=N full=..`. What
# it checks:
#
#   1. Setup: N windows of two panes, the first window's sidebar expanded on
#      the all-windows scope, a search matching every window (a search
#      unfolds everything) so the list is every pane, and a dozen panes busy.
#   2. Ten wheel steps down and back: every step is painted, and the slowest
#      step's paint stays under Mac's PRE-fix 31 ms - in a Debug build, so a
#      release build has headroom on top. The median is reported beside Mac's
#      post-fix ~8 ms.
#   3. At rest with the dozen busy panes (the sheen is the compositor's since
#      T2801, and moves in the window in use only since T2909): the process's
#      CPU over a quiet stretch, reported as the measurement (whole process,
#      percent of one core) and bounded loosely - Mac's broken state was
#      86-99% of a core doing nothing.
#
# Runs on a BACKGROUND desktop (lib\TestDesktop.ps1) and never takes the
# user's foreground - asserted by the foreground watcher, not assumed.
# -NegativeControl asserts every step costs Mac's pre-fix 31 ms or more and
# MUST fail.
#
#   powershell -NoProfile -File test\win32\pane-sidebar-scroll-cost.ps1 [-Windows 40]
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [int]$Windows = 40,
    [switch]$NegativeControl,
    [switch]$Interactive
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:passes = 0
$tmp = Join-Path $env:TEMP "ghoztty-t2332-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ } else { "  FAIL $name"; $script:failures++ }
}
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 't2332')
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
function Px([double]$Dip) { Get-TestChromeDip -Dip $Dip -Scale $script:scale }

function Get-LogCount { @(Get-Content $script:errlog -ErrorAction SilentlyContinue).Count }
# The LAST line matching $Pattern logged after line $Skip, waiting up to $Ms
# for one to appear (and a further 300 ms for later ones to settle).
function Wait-Log([string]$Pattern, [int]$Skip, [int]$Ms = 4000) {
    $deadline = (Get-Date).AddMilliseconds($Ms)
    $hit = $null
    do {
        Start-Sleep -Milliseconds 150
        $hit = @(Get-Content $script:errlog -ErrorAction SilentlyContinue | Select-Object -Skip $Skip | Where-Object { $_ -match $Pattern }) | Select-Object -Last 1
    } while (-not $hit -and (Get-Date) -lt $deadline)
    if ($hit) {
        Start-Sleep -Milliseconds 300  # settle: let later lines of the same burst land, so the LAST match is read
        $hit = @(Get-Content $script:errlog -ErrorAction SilentlyContinue | Select-Object -Skip $Skip | Where-Object { $_ -match $Pattern }) | Select-Object -Last 1
    }
    return $hit
}
function ClickAt($top, $sb, $pt) {
    return Send-TestMouse -Window $top -Target ([IntPtr]$sb.Hwnd) -X ($sb.Left + $pt.X) -Y ($sb.Top + $pt.Y) -Action click
}
function WheelAt($top, $sb, $pt, [int]$Delta) {
    return Send-TestMouse -Window $top -Target ([IntPtr]$sb.Hwnd) -X ($sb.Left + $pt.X) -Y ($sb.Top + $pt.Y) -Action wheel -Delta $Delta
}
# The collapse/expand toggle and the all-windows toggle (T2289 header order),
# as pane-sidebar-scroll.ps1 places them.
function Get-ToggleCenter($sb) {
    $margin = Px 12; $card = Px 52; $tile = Px 28
    $inset = [int][math]::Truncate(($card - $tile) / 2)
    return @{ X = $margin + $inset + [int]($tile / 2); Y = $margin + $inset + [int]($tile / 2) }
}
function Get-ScopeCenter($sb) {
    return @{ X = $sb.Width - (Px 12) - (Px 4) - [int]((Px 28) / 2); Y = (Get-ToggleCenter $sb).Y }
}

# The app's CPU over $Ms, as percent of one core.
function Get-CpuPercent($proc, [int]$Ms = 3000) {
    if (-not $proc) { return $null }
    try {
        $proc.Refresh(); $a = $proc.TotalProcessorTime.TotalMilliseconds
        Start-Sleep -Milliseconds $Ms  # settle: the sampling window itself - CPU time is read across it
        $proc.Refresh(); $b = $proc.TotalProcessorTime.TotalMilliseconds
        return [math]::Round(($b - $a) * 100.0 / $Ms, 1)
    } catch { return $null }
}

. (Join-Path $PSScriptRoot 'lib\Transcript.ps1')
$transcript = New-TestTranscript -Name 't2332'

Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$launched = @()
$script:reachedEnd = $false
$script:scale = 1.0

& {
try {
    [void](Stop-RepoGhoztty -Exe $Exe -AppOnly -SettleMs 500)
    Assert-GhozttyPrivateEndpoint -Exe $Exe
    $script:errlog = Join-Path $tmp 'app-stderr.log'
    $script:app = Start-OnTestDesktop -Exe $Exe -StdErr $script:errlog -Arguments @('--session-persistence=false', '--macos-pane-style=flat')
    $top = Wait-TestWindow -ProcessId $script:app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { "  SETUP FAIL: top window not found"; $script:failures++; return }
    Assert "window is NOT enumerable on the interactive desktop" (-not (Test-TestDesktopLeak -ProcessId $script:app.Pid))
    $dpi = Get-TestWindowDpi -Window $top
    if ($dpi -gt 0) { $script:scale = $dpi / 96.0 }
    "  (window dpi $dpi, scale $($script:scale))"

    "== 1: $Windows windows of two panes, all windows unfolded, a dozen busy"
    Assert "setup: this window named 'proj0: w1' ($(Get-CliErr))" ((Invoke-Cli "+rename --target=window-1 --title=`"proj0: w1`"") -eq 0)
    Assert "setup: p1 split ($(Get-CliErr))" ((Invoke-Cli "+split --direction=right --name=p1") -eq 0)
    $made = 1
    for ($k = 2; $k -le $Windows; $k++) {
        $proj = $k % 8
        if ((Invoke-Cli "+new-window --target=w$k --name=a$k --shell=cmd.exe --title=`"proj${proj}: w$k`"") -ne 0) { continue }
        Start-Sleep -Milliseconds 250  # settle: pacing 80 pane spawns so the box is not flooded; a failed split is counted, not waited on
        if ((Invoke-Cli "+split --target=a$k --direction=right --name=b$k --shell=cmd.exe") -eq 0) { $made++ }
        Start-Sleep -Milliseconds 150  # settle: pacing the spawns, as above; the count is asserted after the loop
    }
    Assert "setup: $Windows windows of two panes ($made)" ($made -eq $Windows)
    $busy = @()
    for ($k = 2; $k -le 13 -and $k -le $Windows; $k++) {
        if ((Invoke-Cli "+set-state --target=b$k --state=busy") -eq 0) { $busy += "b$k" }
    }
    Assert "setup: a dozen panes busy ($($busy.Count))" ($busy.Count -eq [math]::Min(12, $Windows - 1))

    # Back to the first window, expanded, on the all-windows scope.
    [void](Set-TestWindowSize -Window $top -Width (Px 1100) -Height (Px 760))
    Assert "setup: the first window is the active one" (Set-TestActiveWindow -Window $top)
    Start-Sleep -Milliseconds 800  # settle: the resize relays out the column; every later step waits on a log line of its own
    $sb = Get-Sidebar $top
    Assert "setup: the window has a sidebar" ($null -ne $sb -and $sb.Visible)
    if ($null -eq $sb) { return }
    $mark = Get-LogCount
    [void](ClickAt $top $sb (Get-ToggleCenter $sb))
    Assert "setup: the panel expanded (log)" ($null -ne (Wait-Log 'pane sidebar rows mode=expanded' $mark 3000))
    $sb = Get-Sidebar $top
    $mark = Get-LogCount
    [void](ClickAt $top $sb (Get-ScopeCenter $sb))
    Assert "setup: the all-windows scope is on (log)" ($null -ne (Wait-Log 'pane sidebar scope all_windows=true' $mark 3000))
    $g = Wait-Log 'pane sidebar all-windows groups=' $mark 6000
    "  $g"
    Assert "setup: the list counts every window ($g)" ($g -match " windows=$Windows ")

    # A search unfolds every window: 'proj' matches them all.
    $line = Wait-Log 'pane sidebar outline mode=expanded.* search=' $mark 3000
    $sp = $null
    if ($line -match ' search=(-?\d+),(-?\d+) ') { $sp = @{ X = [int]$Matches[1]; Y = [int]$Matches[2] } }
    Assert "setup: the outline places the search field" ($null -ne $sp)
    $mark = Get-LogCount
    if ($sp) { [void](ClickAt $top $sb $sp) }
    Assert "setup: the search field took the keyboard (log)" ($null -ne (Wait-Log 'pane sidebar search focus=true' $mark 3000))
    $mark = Get-LogCount
    [void](Send-TestControlText -Control ([IntPtr]$sb.Hwnd) -Text 'proj')
    $g = Wait-Log 'pane sidebar all-windows groups=\d+ .*search=1 ' $mark 6000
    "  $g"
    $panes = if ($g -match ' panes=(\d+) ') { [int]$Matches[1] } else { 0 }
    Assert "setup: every pane is listed ($panes, want $(2 * $Windows))" ($panes -eq (2 * $Windows))
    $o = Wait-Log 'pane sidebar outline mode=expanded' $mark 3000
    $view = $null
    if ($o -match ' scroll=(-?\d+)/(-?\d+) view=(-?\d+),(-?\d+) ') { $view = @{ Max = [int]$Matches[2]; Top = [int]$Matches[3]; Bottom = [int]$Matches[4] } }
    Assert "setup: the list overflows the panel (max $(if ($view) { $view.Max }))" ($null -ne $view -and $view.Max -gt 0)
    if ($null -eq $view) { return }

    "== 2: a wheel step's paint, ten down and ten back"
    $mid = @{ X = [int]($sb.Width / 2); Y = [int](($view.Top + $view.Bottom) / 2) }
    $samples = @()
    foreach ($dir in @(-120, 120)) {
        for ($i = 0; $i -lt 10; $i++) {
            $mark = Get-LogCount
            [void](WheelAt $top $sb $mid $dir)
            $hit = Wait-Log 'pane sidebar scroll paint us=(\d+)' $mark 2000
            if ($hit -match 'us=(\d+) full=(\w+)') { $samples += , @{ Us = [int]$Matches[1]; Full = $Matches[2] } }
        }
    }
    $us = @($samples | ForEach-Object { $_.Us } | Sort-Object)
    $median = if ($us.Count) { $us[[int][math]::Floor($us.Count / 2)] } else { -1 }
    $max = if ($us.Count) { $us[$us.Count - 1] } else { -1 }
    "  steps painted=$($us.Count) median=$([math]::Round($median / 1000.0, 2)) ms max=$([math]::Round($max / 1000.0, 2)) ms (Debug build; Mac before 321e61d7c 31-50 ms, after ~8 ms)"
    "  all samples (us): $($us -join ' ')"
    Assert "every step was painted and timed ($($us.Count) of 20; a step at the end of the list does not move)" ($us.Count -ge 18)
    Assert "every step painted the whole column (the rows all move)" (@($samples | Where-Object { $_.Full -ne 'true' }).Count -eq 0)
    if ($NegativeControl) {
        Assert "NEGATIVE CONTROL: every step costs Mac's pre-fix 31 ms (min $([math]::Round($us[0] / 1000.0, 2)) ms)" ($us.Count -gt 0 -and $us[0] -ge 31000)
    } else {
        Assert "the slowest step stays under Mac's pre-fix 31 ms ($([math]::Round($max / 1000.0, 2)) ms)" ($max -ge 0 -and $max -lt 31000)
    }

    "== 3: at rest with a dozen busy panes (measurement)"
    Start-Sleep -Milliseconds 1500  # settle: the quiet stretch before the CPU sample IS the measurement's premise
    $idle = Get-CpuPercent $script:app.Process 4000
    "  cpu at rest: $idle% of one core (whole process: $(2 * $Windows) panes, $($busy.Count) busy; Mac before 321e61d7c 86-99%, after <1%)"
    Assert "at rest the app is far from a busy core ($idle%, want < 25)" ($null -ne $idle -and $idle -lt 25)

    Assert "no crash" (-not ($script:app.Process -and $script:app.Process.HasExited))
    $launched += $script:GhozttyTestDesktopPids
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
    $launched = @($launched | Select-Object -Unique)
    Assert "the foreground watcher actually sampled (negative control)" ($fgSeen.Count -gt 0)
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert "no test-desktop app ever became foreground on the interactive desktop" ($leaked.Count -eq 0)
}
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

} 2>&1 | Tee-Object -FilePath $transcript

Complete-TestBody  # T1039: the run reached the end of its body

if ($script:failures -eq 0 -and -not $NegativeControl) {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard pane-sidebar-scroll-cost -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

""
exit (Complete-TestTranscript -Name 't2332' -Path $transcript `
        -Label 'T2332 ACCEPTANCE' -Pass $script:passes -Fail $script:failures).Code
