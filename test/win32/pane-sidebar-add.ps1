# T2323 acceptance: the pane sidebar's three + buttons (Mac 44aa923f0). In
# the all-windows scope of window A's expanded sidebar:
#
#   1. A window header's + raises that window and splits its focused pane in
#      the last direction split by hand - right, since nothing was split by
#      hand yet - and takes focus. A `+split --direction=down` in between
#      does NOT move that memory: the next + still splits right.
#   2. A project header's + opens a new window titled `<project>: new`, so it
#      lands in the group; a second click picks the first free `new-2`.
#   3. The header's + (left of the all-windows toggle) opens a new window
#      from A, untitled, and it takes focus.
#
# Layout: window A (renamed "zeta"), then wB "proj: one" (b1) and wC
# "proj: two" (c1). Geometry comes from the `pane sidebar outline` log line:
# heads, each head's + (`ha=`) and the header's + (`add=`), in the column's
# client coordinates. Which head is which is read from the groups line's
# `order=` (heads list the groups in that order, a project head before its
# first window).
#
# Runs on a BACKGROUND desktop (lib\TestDesktop.ps1) and never takes the
# user's foreground - asserted by the foreground watcher, not assumed.
# -NegativeControl clicks wB's header name beside its + in section 1, which
# raises rather than adds, so it MUST fail.
#
#   powershell -NoProfile -File test\win32\pane-sidebar-add.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [switch]$NegativeControl,
    [switch]$Interactive
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:passes = 0
$tmp = Join-Path $env:TEMP "ghoztty-t2323-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ } else { "  FAIL $name"; $script:failures++ }
}
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 't2323')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\ChromeGeometry.ps1')

$Cli = [System.IO.Path]::ChangeExtension($Exe, '.com')
if (-not (Test-Path $Cli)) { $Cli = $Exe }

function Invoke-Cli([string]$CliArgs) {
    cmd /c "`"$Cli`" $CliArgs > `"$tmp\out.txt`" 2> `"$tmp\err.txt`"" | Out-Null
    return $LASTEXITCODE
}
function Get-CliOut { (Get-Content "$tmp\out.txt" -Raw -ErrorAction SilentlyContinue) }
function Get-CliErr { (Get-Content "$tmp\err.txt" -Raw -ErrorAction SilentlyContinue) }

# How many panes `+list --json` reports: anything carrying both `id` and `pid`.
function Get-PaneCount {
    [void](Invoke-Cli '+list --json')
    $raw = Get-CliOut
    if ([string]::IsNullOrWhiteSpace($raw)) { return -1 }
    $script:paneCount = 0
    $walk = $null
    $walk = {
        param($o)
        if ($null -eq $o) { return }
        if ($o -is [System.Array]) { foreach ($x in $o) { & $walk $x }; return }
        if ($o -is [System.Management.Automation.PSCustomObject]) {
            $names = @($o.PSObject.Properties.Name)
            if (($names -contains 'id') -and ($names -contains 'pid')) { $script:paneCount++ }
            foreach ($p in $o.PSObject.Properties) { & $walk $p.Value }
        }
    }
    try { & $walk ($raw | ConvertFrom-Json) } catch { return -1 }
    return $script:paneCount
}
function Wait-Until([scriptblock]$Cond, [int]$Ms = 5000) {
    $deadline = (Get-Date).AddMilliseconds($Ms)
    do {
        if (& $Cond) { return $true }
        Start-Sleep -Milliseconds 200
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Get-Sidebar($top) { @(Get-TestChildWindows -Window $top -Class 'GhozttyPaneSidebar') | Select-Object -First 1 }
function Px([double]$Dip) { Get-TestChromeDip -Dip $Dip -Scale $script:scale }

function Get-LogCount { @(Get-Content $script:errlog -ErrorAction SilentlyContinue).Count }
# The LAST line matching $Pattern logged after line $Skip, waiting up to
# $Ms for one to appear (and a further 300 ms for later ones to settle).
function Wait-Log([string]$Pattern, [int]$Skip, [int]$Ms = 4000) {
    $deadline = (Get-Date).AddMilliseconds($Ms)
    $hit = $null
    do {
        Start-Sleep -Milliseconds 150
        $hit = @(Get-Content $script:errlog -ErrorAction SilentlyContinue | Select-Object -Skip $Skip | Where-Object { $_ -match $Pattern }) | Select-Object -Last 1
    } while (-not $hit -and (Get-Date) -lt $deadline)
    if ($hit) {
        Start-Sleep -Milliseconds 300
        $hit = @(Get-Content $script:errlog -ErrorAction SilentlyContinue | Select-Object -Skip $Skip | Where-Object { $_ -match $Pattern }) | Select-Object -Last 1
    }
    return $hit
}
function Test-LogSince([string]$Pattern, [int]$Skip) {
    return @(Get-Content $script:errlog -ErrorAction SilentlyContinue | Select-Object -Skip $Skip | Where-Object { $_ -match $Pattern }).Count -gt 0
}

function Read-Points([string]$Line, [string]$Key) {
    if ($Line -notmatch " $Key=(\S*)") { return @() }
    return @($Matches[1] -split ';' | Where-Object { $_ } | ForEach-Object { $xy = $_ -split ','; @{ X = [int]$xy[0]; Y = [int]$xy[1] } })
}
# Parse a `pane sidebar outline` line: heads (kind, group, center), each
# head's + and the header's +.
function Read-Outline([string]$Line) {
    if (-not $Line -or $Line -notmatch 'mode=(\w+) heads=(\S*) items=') { return $null }
    $o = @{ Mode = $Matches[1]; Heads = @() }
    foreach ($h in ($Matches[2] -split ';' | Where-Object { $_ })) {
        if ($h -match '^([PW])(\d+)@(-?\d+),(-?\d+)$') { $o.Heads += , @{ Kind = $Matches[1]; Group = [int]$Matches[2]; X = [int]$Matches[3]; Y = [int]$Matches[4] } }
    }
    $o.Ha = Read-Points $Line 'ha'
    $o.Add = @(Read-Points $Line 'add') | Select-Object -First 1
    $o.Scope = @(Read-Points $Line 'scope') | Select-Object -First 1
    return $o
}
function Get-Outline([int]$Skip) { Read-Outline (Wait-Log 'pane sidebar outline mode=expanded' $Skip) }
# The groups line's order, as an array of `project/worktree` or names.
function Get-Order([int]$Skip) {
    $g = Wait-Log 'pane sidebar all-windows groups=' $Skip
    if ($g -notmatch 'order=(.*)$') { return @() }
    return @($Matches[1] -split '\|')
}
# The head index of window group $Name (an `order=` entry), or -1.
function Find-WindowHead($o, [string[]]$Order, [string]$Name) {
    $gi = [array]::IndexOf($Order, $Name)
    if ($null -eq $o -or $gi -lt 0) { return -1 }
    for ($j = 0; $j -lt $o.Heads.Count; $j++) { if ($o.Heads[$j].Kind -eq 'W' -and $o.Heads[$j].Group -eq $gi) { return $j } }
    return -1
}
function Find-ProjectHead($o) {
    if ($null -eq $o) { return -1 }
    for ($j = 0; $j -lt $o.Heads.Count; $j++) { if ($o.Heads[$j].Kind -eq 'P') { return $j } }
    return -1
}
function ClickAt($top, $sb, $pt) {
    return Send-TestMouse -Window $top -Target ([IntPtr]$sb.Hwnd) -X ($sb.Left + $pt.X) -Y ($sb.Top + $pt.Y) -Action click
}
# The collapse/expand toggle (T2289) and the all-windows toggle (the panel
# header's trailing button), as pane-sidebar-all-windows.ps1 places them.
function Get-ToggleCenter($sb) {
    $margin = Px 12; $card = Px 44; $tile = Px 28
    $inset = [int][math]::Truncate(($card - $tile) / 2)
    return @{ X = $margin + $inset + [int]($tile / 2); Y = $margin + $inset + [int]($tile / 2) }
}
function Get-ScopeCenter($sb) {
    return @{ X = $sb.Width - (Px 4) - [int]((Px 28) / 2); Y = (Get-ToggleCenter $sb).Y }
}
function Get-AppWindowCount($app) { @(Get-TestWindows -ProcessId $app.Pid -Class 'GhozttyWindow' | Where-Object { $_.Visible }).Count }
function Set-AActive($top) {
    [void](Set-TestActiveWindow -Window $top)
    return (Wait-Until { (Get-TestActiveWindow -Window $top) -eq $top } 3000)
}

. (Join-Path $PSScriptRoot 'lib\Transcript.ps1')
$transcript = New-TestTranscript -Name 't2323'

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
    $app = Start-OnTestDesktop -Exe $Exe -StdErr $script:errlog -Arguments @('--session-persistence=false', '--macos-pane-style=flat')
    Start-Sleep -Seconds 3
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { "  SETUP FAIL: top window not found"; $script:failures++; return }
    Assert "window is NOT enumerable on the interactive desktop" (-not (Test-TestDesktopLeak -ProcessId $app.Pid))
    $dpi = Get-TestWindowDpi -Window $top
    if ($dpi -gt 0) { $script:scale = $dpi / 96.0 }
    "  (window dpi $dpi, scale $($script:scale))"
    [void](Set-TestWindowSize -Window $top -Width (Px 1100) -Height (Px 900))
    Start-Sleep -Milliseconds 600

    Assert "setup: window A renamed zeta ($(Get-CliErr))" ((Invoke-Cli "+rename --target=window-1 --title=zeta") -eq 0)
    Assert "setup: wB opened ($(Get-CliErr))" ((Invoke-Cli "+new-window --target=wB --name=b1 --title=`"proj: one`"") -eq 0)
    Start-Sleep -Milliseconds 1200
    Assert "setup: wC opened ($(Get-CliErr))" ((Invoke-Cli "+new-window --target=wC --name=c1 --title=`"proj: two`"") -eq 0)
    Start-Sleep -Milliseconds 1200

    $sb = Get-Sidebar $top
    Assert "A has a sidebar" ($null -ne $sb -and $sb.Visible)
    if ($null -eq $sb) { return }
    [void](ClickAt $top $sb (Get-ToggleCenter $sb))
    Start-Sleep -Milliseconds 700
    $sb = Get-Sidebar $top
    $mark = Get-LogCount
    [void](ClickAt $top $sb (Get-ScopeCenter $sb))
    Assert "the all-windows scope is on (log)" ($null -ne (Wait-Log 'pane sidebar scope all_windows=true' $mark))
    $order = Get-Order $mark
    Assert "three windows in name order, the lone window first (T2421): zeta | proj/one | proj/two ($($order -join '|'))" (($order -join '|') -eq 'zeta|proj/one|proj/two')
    $o = Get-Outline $mark
    Assert "the outline logs a + for every head, and the header's +" ($null -ne $o -and $o.Heads.Count -eq 4 -and $o.Ha.Count -eq 4 -and $null -ne $o.Add)
    if ($null -eq $o -or $o.Ha.Count -ne $o.Heads.Count -or $null -eq $o.Add) { return }
    $scope = $o.Scope
    Assert "the header's + sits left of the all-windows toggle, on its row ($($o.Add.X),$($o.Add.Y) vs $($scope.X),$($scope.Y))" ($o.Add.X -lt $scope.X -and [math]::Abs($o.Add.Y - $scope.Y) -le 1)

    "== 1: a window header's + splits that window's focused pane, the last manual way (right)"
    $before = Get-PaneCount
    Assert "setup: A is the active window" (Set-AActive $top)
    $k = Find-WindowHead $o $order 'proj/one'
    Assert "proj: one has a window head" ($k -ge 0)
    $mark = Get-LogCount
    if ($k -ge 0) {
        $pt = $o.Ha[$k]
        if ($NegativeControl) {
            "  NEGATIVE CONTROL: clicking proj: one's name beside its + - this run MUST fail"
            $pt = @{ X = $o.Ha[$k].X - (Px 40); Y = $o.Ha[$k].Y }
        }
        [void](ClickAt $top $sb $pt)
    }
    Assert "the + split by the remembered direction, right (log)" ($null -ne (Wait-Log 'pane sidebar add pane dir=right' $mark))
    Assert "...raising its window first (log)" (Test-LogSince 'pane sidebar raise window' $mark)
    Assert "one more pane in +list ($before -> ?)" (Wait-Until { (Get-PaneCount) -eq $before + 1 })
    Assert "A is no longer the active window: the + took focus" (Wait-Until { (Get-TestActiveWindow -Window $top) -ne $top } 3000)

    # A programmatic split never moves the memory (Mac: `+split` calls
    # `newSplit` directly).
    Assert "setup: a +split down in wB ($(Get-CliErr))" ((Invoke-Cli "+split --target=b1 --direction=down --name=b3") -eq 0)
    Start-Sleep -Milliseconds 800
    $before = Get-PaneCount
    Assert "setup: A is the active window again" (Set-AActive $top)
    $mark = Get-LogCount
    $o = Get-Outline 0
    $order = Get-Order 0
    $k = Find-WindowHead $o $order 'proj/one'
    if ($k -ge 0) { [void](ClickAt $top $sb $o.Ha[$k]) }
    Assert "after +split down, the + still splits right (log)" ($null -ne (Wait-Log 'pane sidebar add pane dir=right' $mark))
    Assert "...and never down (log)" (-not (Test-LogSince 'pane sidebar add pane dir=down' $mark))
    Assert "one more pane in +list" (Wait-Until { (Get-PaneCount) -eq $before + 1 })

    "== 2: a project header's + opens a window titled into the group"
    Assert "setup: A is the active window" (Set-AActive $top)
    $windows = Get-AppWindowCount $app
    $o = Get-Outline 0
    $k = Find-ProjectHead $o
    Assert "the project head is listed" ($k -ge 0)
    $mark = Get-LogCount
    if ($k -ge 0) { [void](ClickAt $top $sb $o.Ha[$k]) }
    Assert "a titled new window was opened (log)" ($null -ne (Wait-Log 'pane sidebar new window remote=false titled=true' $mark))
    Assert "one more window" (Wait-Until { (Get-AppWindowCount $app) -eq $windows + 1 })
    Assert "the + took focus: A is not active" (Wait-Until { (Get-TestActiveWindow -Window $top) -ne $top } 3000)
    $order = Get-Order $mark
    Assert "it is grouped as proj/new, first in the project ($($order -join '|'))" (($order -join '|') -eq 'zeta|proj/new|proj/one|proj/two')
    Assert "setup: A is the active window" (Set-AActive $top)
    $o = Get-Outline 0
    $k = Find-ProjectHead $o
    $mark = Get-LogCount
    if ($k -ge 0) { [void](ClickAt $top $sb $o.Ha[$k]) }
    $order = Get-Order $mark
    Assert "a second click picks the first free name, proj/new-2 ($($order -join '|'))" (($order -join '|') -eq 'zeta|proj/new|proj/new-2|proj/one|proj/two')

    "== 3: the header's + opens a new window from A, untitled, focused"
    Assert "setup: A is the active window" (Set-AActive $top)
    $windows = Get-AppWindowCount $app
    $o = Get-Outline 0
    $mark = Get-LogCount
    if ($null -ne $o.Add) { [void](ClickAt $top $sb $o.Add) }
    Assert "an untitled new window was opened (log)" ($null -ne (Wait-Log 'pane sidebar new window remote=false titled=false' $mark))
    Assert "one more window" (Wait-Until { (Get-AppWindowCount $app) -eq $windows + 1 })
    Assert "the + took focus: A is not active" (Wait-Until { (Get-TestActiveWindow -Window $top) -ne $top } 3000)
    Assert "the all-windows list grew to six" ($null -ne (Wait-Log 'pane sidebar all-windows groups=6 ' $mark))

    Assert "no crash" (-not ($app.Process -and $app.Process.HasExited))
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
if ($script:failures -gt 0 -and $script:errlog -and (Test-Path $script:errlog)) {
    $keep = Join-Path $env:TEMP 't2323-app-stderr.log'
    Copy-Item $script:errlog $keep -Force
    "  (app log kept: $keep)"
}
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

} 2>&1 | Tee-Object -FilePath $transcript

Complete-TestBody  # T1039: the run reached the end of its body

if ($script:failures -eq 0 -and -not $NegativeControl) {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard pane-sidebar-add -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

""
exit (Complete-TestTranscript -Name 't2323' -Path $transcript `
        -Label 'T2323 ACCEPTANCE' -Pass $script:passes -Fail $script:failures).Code
