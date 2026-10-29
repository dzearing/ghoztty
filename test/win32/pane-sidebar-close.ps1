# T2298 acceptance: closing windows and project groups from the pane
# sidebar's all-windows scope (Mac 345be6b02, 7e4646bb5, 9c2ab5521). Every
# close from the sidebar asks nothing, takes no focus and ends what it
# closes: another window's row x, a window header's x, a project header's x,
# and this window's own header x - a window closing itself from its own
# sidebar.
#
# Layout: window A (P + s1, renamed "zeta"), then wB "proj: one" (b1 + b2),
# wC "proj: two" (c1) and wD "lone" (d1). In A's sidebar, with the scope on:
#
#   1. Another window's row has an x now: clicking it on one of wB's panes -
#      made busy first, so a confirmation would show - closes that pane with
#      no dialog, through the sidebar's close, and A stays the active window
#      (no raise).
#   2. A window header's x (lone, busy) closes that window: no dialog, parked
#      for undo, A still active, three windows left in the list.
#   3. The project header's x closes BOTH of its windows in one go, as one
#      batch, and A stays active.
#   4. A's own header x closes A itself from its own sidebar (on the next
#      loop turn): A is parked for undo and hidden; another window (wE, opened
#      for this) is untouched and the app lives on.
#
# Geometry comes from the `pane sidebar outline` log line: heads, items, each
# head's chevron (`chev=`) and each head's x (`hx=`), in the column's client
# coordinates. A row's x is in the same column as the heads' (unit-tested in
# pane_sidebar.zig), so its center is hx's X at the row's Y.
#
# Runs on a BACKGROUND desktop (lib\TestDesktop.ps1) and never takes the
# user's foreground - asserted by the foreground watcher, not assumed.
# -NegativeControl clicks the header's name beside the x in section 2, which
# raises rather than closes, so it MUST fail.
#
#   powershell -NoProfile -File test\win32\pane-sidebar-close.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [switch]$NegativeControl,
    [switch]$Interactive
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:passes = 0
$tmp = Join-Path $env:TEMP "ghoztty-t2298-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ } else { "  FAIL $name"; $script:failures++ }
}
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 't2298')
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

# Every pane name in `+list --json`: anything carrying both `id` and `pid`.
function Get-PaneNames {
    [void](Invoke-Cli '+list --json')
    $raw = Get-CliOut
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    $out = New-Object System.Collections.ArrayList
    $walk = $null
    $walk = {
        param($o)
        if ($null -eq $o) { return }
        if ($o -is [System.Array]) { foreach ($x in $o) { & $walk $x }; return }
        if ($o -is [System.Management.Automation.PSCustomObject]) {
            $names = @($o.PSObject.Properties.Name)
            if (($names -contains 'id') -and ($names -contains 'pid')) { [void]$out.Add([string]$o.name) }
            foreach ($p in $o.PSObject.Properties) { & $walk $p.Value }
        }
    }
    try { & $walk ($raw | ConvertFrom-Json) } catch { return @() }
    return $out.ToArray()
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
# Parse a `pane sidebar outline` line: heads (kind, group, center), items
# (group, section, center), and each head's chevron and x.
function Read-Outline([string]$Line) {
    if (-not $Line -or $Line -notmatch 'mode=(\w+) heads=(\S*) items=(\S*) ') { return $null }
    $o = @{ Mode = $Matches[1]; Heads = @(); Items = @() }
    $headsRaw = $Matches[2]; $itemsRaw = $Matches[3]
    foreach ($h in ($headsRaw -split ';' | Where-Object { $_ })) {
        if ($h -match '^([PW])(\d+)@(-?\d+),(-?\d+)$') { $o.Heads += , @{ Kind = $Matches[1]; Group = [int]$Matches[2]; X = [int]$Matches[3]; Y = [int]$Matches[4] } }
    }
    foreach ($i in ($itemsRaw -split ';' | Where-Object { $_ })) {
        if ($i -match '^g(\d+)([gs])@(-?\d+),(-?\d+)$') { $o.Items += , @{ Group = [int]$Matches[1]; Sec = $Matches[2]; X = [int]$Matches[3]; Y = [int]$Matches[4] } }
    }
    $o.Chev = Read-Points $Line 'chev'
    $o.Hx = Read-Points $Line 'hx'
    return $o
}
function Get-Outline([int]$Skip) { Read-Outline (Wait-Log 'pane sidebar outline mode=expanded' $Skip) }
# The index into Heads of head $Kind for group $Group, or -1.
function Find-Head($o, [string]$Kind, [int]$Group) {
    if ($null -eq $o) { return -1 }
    for ($j = 0; $j -lt $o.Heads.Count; $j++) { if ($o.Heads[$j].Kind -eq $Kind -and $o.Heads[$j].Group -eq $Group) { return $j } }
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
function Test-NoConfirm($app) {
    Start-Sleep -Milliseconds 500
    return (Get-TestWindow -ProcessId $app.Pid -Class 'GhozttyConfirmDialog') -eq [IntPtr]::Zero
}

. (Join-Path $PSScriptRoot 'lib\Transcript.ps1')
$transcript = New-TestTranscript -Name 't2298'

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

    [void](Invoke-Cli "+split --direction=right --name=s1")
    Start-Sleep -Milliseconds 700
    Assert "setup: window A renamed zeta ($(Get-CliErr))" ((Invoke-Cli "+rename --target=window-1 --title=zeta") -eq 0)
    Assert "setup: wB opened ($(Get-CliErr))" ((Invoke-Cli "+new-window --target=wB --name=b1 --title=`"proj: one`"") -eq 0)
    Start-Sleep -Milliseconds 1200
    Assert "setup: b2 split in wB ($(Get-CliErr))" ((Invoke-Cli "+split --target=b1 --direction=right --name=b2") -eq 0)
    Start-Sleep -Milliseconds 700
    Assert "setup: wC opened ($(Get-CliErr))" ((Invoke-Cli "+new-window --target=wC --name=c1 --title=`"proj: two`"") -eq 0)
    Start-Sleep -Milliseconds 1200
    Assert "setup: wD opened ($(Get-CliErr))" ((Invoke-Cli "+new-window --target=wD --name=d1 --title=lone") -eq 0)
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
    $g = Wait-Log 'pane sidebar all-windows groups=' $mark
    "  $g"
    Assert "four windows in name order, the lone windows first (T2421): lone | zeta | proj/one | proj/two" ($g -match 'groups=4 .*order=lone\|zeta\|proj/one\|proj/two$')
    $o = Get-Outline $mark
    Assert "the outline logs a chevron and an x for every head" ($null -ne $o -and $o.Heads.Count -eq 5 -and $o.Chev.Count -eq 5 -and $o.Hx.Count -eq 5)
    if ($null -eq $o -or $o.Hx.Count -ne $o.Heads.Count) { return }
    # Every head's x is in one column, level with its chevron (Mac 7e4646bb5).
    $col = @($o.Hx | ForEach-Object { $_.X } | Select-Object -Unique)
    Assert "the heads' x share one column ($($col -join ','))" ($col.Count -eq 1)
    $level = $true
    for ($j = 0; $j -lt $o.Heads.Count; $j++) { if ([math]::Abs($o.Hx[$j].Y - $o.Chev[$j].Y) -gt 1) { $level = $false } }
    Assert "each head's x is level with its chevron" $level
    $xcol = $o.Hx[0].X

    "== 1: another window's row x closes that pane, asks nothing, raises nothing"
    # Unfold proj: one (group 2) by its chevron, which never raises it.
    $k = Find-Head $o 'W' 2
    $mark = Get-LogCount
    if ($k -ge 0) { [void](ClickAt $top $sb $o.Chev[$k]) }
    $o = Get-Outline $mark
    $bRows = @($o.Items | Where-Object Group -eq 2)
    Assert "proj: one unfolded: its two rows show" ($bRows.Count -eq 2)
    [void](Invoke-Cli "+send-keys --target=b1 `"ping -n 120 127.0.0.1`" Enter")
    [void](Invoke-Cli "+send-keys --target=b2 `"ping -n 120 127.0.0.1`" Enter")
    Start-Sleep -Milliseconds 1200
    # A busy row grows a second line: read the rows again once it has.
    $o = Get-Outline 0
    $bRows = @($o.Items | Where-Object Group -eq 2)
    [void](Set-TestActiveWindow -Window $top)
    Assert "setup: A is the active window" (Wait-Until { (Get-TestActiveWindow -Window $top) -eq $top } 3000)
    $mark = Get-LogCount
    if ($bRows.Count -eq 2) { [void](ClickAt $top $sb @{ X = $xcol; Y = $bRows[1].Y }) }
    Assert "it went through the sidebar's close, for another window (log)" ($null -ne (Wait-Log 'pane sidebar close pane \(x\) own_window=false' $mark))
    Assert "one of wB's panes is gone, the other stays" (Wait-Until { $n = @(Get-PaneNames); (@($n | Where-Object { $_ -in 'b1', 'b2' }).Count -eq 1) })
    Assert "no confirmation dialog came up" (Test-NoConfirm $app)
    Assert "wB was not raised (log)" (-not (Test-LogSince 'pane sidebar raise window' $mark))
    Assert "A is still the active window" ((Get-TestActiveWindow -Window $top) -eq $top)

    "== 2: a window header's x closes that window, asks nothing, raises nothing"
    [void](Invoke-Cli "+send-keys --target=d1 `"ping -n 120 127.0.0.1`" Enter")
    Start-Sleep -Milliseconds 1200
    [void](Set-TestActiveWindow -Window $top)
    Assert "setup: A is the active window" (Wait-Until { (Get-TestActiveWindow -Window $top) -eq $top } 3000)
    $o = Get-Outline 0
    $k = Find-Head $o 'W' 0
    $mark = Get-LogCount
    if ($k -ge 0) {
        $pt = $o.Hx[$k]
        if ($NegativeControl) {
            "  NEGATIVE CONTROL: clicking lone's name beside its x - this run MUST fail"
            $pt = @{ X = $o.Hx[$k].X - (Px 40); Y = $o.Hx[$k].Y }
        }
        [void](ClickAt $top $sb $pt)
    }
    Assert "the header x closed one window (log)" ($null -ne (Wait-Log 'pane sidebar close window windows=1' $mark))
    Assert "...on the next loop turn, unconfirmed (log)" ($null -ne (Wait-Log 'sidebar quiet close tabs=1' $mark))
    Assert "d1 is gone from +list" (Wait-Until { -not (@(Get-PaneNames) -contains 'd1') })
    Assert "no confirmation dialog came up" (Test-NoConfirm $app)
    Assert "it was parked for undo (log)" (Test-LogSince 'parked closed window for undo' $mark)
    Assert "A is still the active window" ((Get-TestActiveWindow -Window $top) -eq $top)
    Assert "three windows left in the list" ($null -ne (Wait-Log 'pane sidebar all-windows groups=3 .*order=zeta\|proj/one\|proj/two$' $mark))

    "== 3: the project header's x closes every window in it"
    [void](Invoke-Cli "+send-keys --target=c1 `"ping -n 120 127.0.0.1`" Enter")
    Start-Sleep -Milliseconds 1200
    [void](Set-TestActiveWindow -Window $top)
    Assert "setup: A is the active window" (Wait-Until { (Get-TestActiveWindow -Window $top) -eq $top } 3000)
    $o = Get-Outline 0
    $k = -1
    if ($null -ne $o) { for ($j = 0; $j -lt $o.Heads.Count; $j++) { if ($o.Heads[$j].Kind -eq 'P') { $k = $j } } }
    Assert "the project head is listed" ($k -ge 0)
    $mark = Get-LogCount
    if ($k -ge 0) { [void](ClickAt $top $sb $o.Hx[$k]) }
    Assert "the project x closed its two windows (log)" ($null -ne (Wait-Log 'pane sidebar close project windows=2' $mark))
    Assert "...as one batch (log)" ($null -ne (Wait-Log 'sidebar quiet close tabs=2' $mark))
    Assert "wB's and wC's panes are gone from +list" (Wait-Until { $n = @(Get-PaneNames); (@($n | Where-Object { $_ -in 'b1', 'b2', 'c1' }).Count -eq 0) })
    Assert "no confirmation dialog came up" (Test-NoConfirm $app)
    Assert "A is still the active window" ((Get-TestActiveWindow -Window $top) -eq $top)
    Assert "only zeta is left in the list" ($null -ne (Wait-Log 'pane sidebar all-windows groups=1 .*order=zeta$' $mark))

    "== 4: A's own header x closes A from its own sidebar"
    Assert "setup: wE opened ($(Get-CliErr))" ((Invoke-Cli "+new-window --target=wE --name=e1 --title=other") -eq 0)
    Start-Sleep -Milliseconds 1200
    $mark = Get-LogCount
    [void](Set-TestActiveWindow -Window $top)
    Start-Sleep -Milliseconds 400
    $o = Get-Outline 0
    $k = -1
    if ($null -ne $o) { for ($j = 0; $j -lt $o.Heads.Count; $j++) { if ($o.Heads[$j].Kind -eq 'W') { $k = $j } } }
    # zeta sorts after other: the last window head.
    $mark = Get-LogCount
    if ($k -ge 0) { [void](ClickAt $top $sb $o.Hx[$k]) }
    Assert "A's x closed A (log)" ($null -ne (Wait-Log 'pane sidebar close window windows=1' $mark))
    Assert "A was parked for undo (log)" ($null -ne (Wait-Log 'parked closed window for undo' $mark))
    Assert "A's panes are gone from +list, e1 stays" (Wait-Until { $n = @(Get-PaneNames); ($n -contains 'e1') -and -not ($n -contains 's1') })
    "  (+list names now: $((@(Get-PaneNames)) -join ','))"
    Assert "A is hidden" (Wait-Until { -not (Test-TestWindowVisible -Window $top) })
    Assert "no confirmation dialog came up" (Test-NoConfirm $app)

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
    $keep = Join-Path $env:TEMP 't2298-app-stderr.log'
    Copy-Item $script:errlog $keep -Force
    "  (app log kept: $keep)"
}
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

} 2>&1 | Tee-Object -FilePath $transcript

Complete-TestBody  # T1039: the run reached the end of its body

if ($script:failures -eq 0 -and -not $NegativeControl) {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard pane-sidebar-close -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

""
exit (Complete-TestTranscript -Name 't2298' -Path $transcript `
        -Label 'T2298 ACCEPTANCE' -Pass $script:passes -Fail $script:failures).Code
