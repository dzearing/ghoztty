# T2324 acceptance: this window's pane sidebar list is held by the window's
# own header (Mac e94a9737e), in the single-window scope:
#
#   1. On the rail the header is its + alone, in a slot the header's exact
#      height: the rows line logs `radd=` and no head, and a click there
#      splits the focused pane the last manual way (right) - one more pane.
#   2. Expanded, the list starts with this window's header (`heads=W0@...`,
#      with its chevron, hover x and hover +), the rail's slot is gone, and
#      every grid pane's row is at the height its rail tile was: collapsing
#      or expanding moves no icon.
#   3. The header's hover + splits the same way - one more pane.
#   4. The header's chevron folds the panes away (no rows logged) and a
#      second click brings them back.
#   4b. T2350 (Mac 32bc9a6b5): titled `proj: wt1`, beside a `proj: wt2`, the
#      list puts the group's header (`P0@`, `pcount=2`) above the window's
#      own; its chevron folds the group to that header alone and back, and
#      its hover + opens a window in the group (`pcount=3`).
#   5. The header's hover x closes this window - and only it, inside its
#      group (a second window keeps the app alive to say so).
#
# Geometry comes from the `pane sidebar rows` log line, in the column's
# client coordinates. Runs on a BACKGROUND desktop (lib\TestDesktop.ps1) and
# never takes the user's foreground - asserted by the foreground watcher, not
# assumed. -NegativeControl clicks the header's name instead of its + in
# section 3, which folds rather than adds, so it MUST fail.
#
#   powershell -NoProfile -File test\win32\pane-sidebar-this-window.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [switch]$NegativeControl,
    [switch]$Interactive
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:passes = 0
$tmp = Join-Path $env:TEMP "ghoztty-t2324-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ } else { "  FAIL $name"; $script:failures++ }
}
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 't2324')
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
    return @($Matches[1] -split ';' | Where-Object { $_ -and $_ -ne '-' } | ForEach-Object { $xy = $_ -split ','; @{ X = [int]$xy[0]; Y = [int]$xy[1] } })
}
# Parse a `pane sidebar rows` line: mode, heads, items (section, center), the
# header's chevron / x / +, and the rail's + (`$null` when `radd=-`).
function Read-Rows([string]$Line) {
    if (-not $Line -or $Line -notmatch 'pane sidebar rows mode=(\w+) heads=(\S*) items=(\S*)') { return $null }
    $r = @{ Mode = $Matches[1]; Heads = @(); Items = @() }
    $heads = $Matches[2]; $items = $Matches[3]
    foreach ($h in ($heads -split ';' | Where-Object { $_ })) {
        if ($h -match '^W(\d+)@(-?\d+),(-?\d+)$') { $r.Heads += , @{ X = [int]$Matches[2]; Y = [int]$Matches[3] } }
    }
    foreach ($it in ($items -split ';' | Where-Object { $_ })) {
        if ($it -match '^g\d+([gs])@(-?\d+),(-?\d+)#') { $r.Items += , @{ Sec = $Matches[1]; X = [int]$Matches[2]; Y = [int]$Matches[3] } }
    }
    $r.Chev = @(Read-Points $Line 'chev') | Select-Object -First 1
    $r.Hx = @(Read-Points $Line 'hx') | Select-Object -First 1
    $r.Ha = @(Read-Points $Line 'ha') | Select-Object -First 1
    $r.Radd = @(Read-Points $Line 'radd') | Select-Object -First 1
    # T2340: the header's window icon, and whether it is drawn selected.
    $r.HIcon = @(Read-Points $Line 'hicon') | Select-Object -First 1
    $r.HSel = $null
    if ($Line -match ' hsel=(\d*)') { $r.HSel = $Matches[1] }
    return $r
}
function Get-Rows([string]$Mode, [int]$Skip) { Read-Rows (Wait-Log "pane sidebar rows mode=$Mode " $Skip) }
function ClickAt($top, $sb, $pt) {
    return Send-TestMouse -Window $top -Target ([IntPtr]$sb.Hwnd) -X ($sb.Left + $pt.X) -Y ($sb.Top + $pt.Y) -Action click
}
# Point at a spot first, so a hover-only button is up when the click lands.
function HoverClickAt($top, $sb, $pt) {
    [void](Send-TestMouse -Window $top -Target ([IntPtr]$sb.Hwnd) -X ($sb.Left + $pt.X) -Y ($sb.Top + $pt.Y) -Action move)
    Start-Sleep -Milliseconds 250
    return ClickAt $top $sb $pt
}
# The grid items' centers' Y, in list order.
function Get-GridYs($r) { @($r.Items | Where-Object { $_.Sec -eq 'g' } | ForEach-Object { $_.Y }) }
function Get-AppWindowCount($app) { @(Get-TestWindows -ProcessId $app.Pid -Class 'GhozttyWindow' | Where-Object { $_.Visible }).Count }
function Set-AActive($top) {
    [void](Set-TestActiveWindow -Window $top)
    return (Wait-Until { (Get-TestActiveWindow -Window $top) -eq $top } 3000)
}

. (Join-Path $PSScriptRoot 'lib\Transcript.ps1')
$transcript = New-TestTranscript -Name 't2324'

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
    Assert "setup: window A renamed alpha ($(Get-CliErr))" ((Invoke-Cli "+rename --target=window-1 --title=alpha") -eq 0)
    $sb = Get-Sidebar $top
    Assert "A has a sidebar" ($null -ne $sb -and $sb.Visible)
    if ($null -eq $sb) { return }

    "== 1: on the rail the header is its + alone, and it splits right"
    $rail = Get-Rows 'mini' 0
    Assert "the rail logs its rows" ($null -ne $rail)
    if ($null -eq $rail) { return }
    Assert "the rail has no header row, only its + slot ($($rail.Heads.Count) heads, radd=$($rail.Radd.X),$($rail.Radd.Y))" ($rail.Heads.Count -eq 0 -and $null -ne $rail.Radd)
    $firstTile = @(Get-GridYs $rail)[0]
    Assert "the + sits above the first tile ($($rail.Radd.Y) < $firstTile)" ($null -ne $rail.Radd -and $rail.Radd.Y -lt $firstTile)
    $before = Get-PaneCount
    Assert "setup: A is the active window" (Set-AActive $top)
    $mark = Get-LogCount
    if ($null -ne $rail.Radd) { [void](ClickAt $top $sb $rail.Radd) }
    Assert "the rail's + split by the remembered direction, right (log)" ($null -ne (Wait-Log 'pane sidebar add pane dir=right' $mark))
    Assert "one more pane in +list ($before -> ?)" (Wait-Until { (Get-PaneCount) -eq $before + 1 })
    $rail = Get-Rows 'mini' $mark
    Assert "the rail now lists two grid tiles" ($null -ne $rail -and @(Get-GridYs $rail).Count -eq 2)

    "== 2: expanded, the list starts with this window's header; no icon moved"
    $mark = Get-LogCount
    $tg = Wait-Log 'pane sidebar rows mode=mini .* toggle=(\d+),(\d+)' 0
    if ($tg -match ' toggle=(\d+),(\d+)') { [void](ClickAt $top $sb @{ X = [int]$Matches[1]; Y = [int]$Matches[2] }) }
    Start-Sleep -Milliseconds 700
    $sb = Get-Sidebar $top
    $panel = Get-Rows 'expanded' $mark
    Assert "the panel logs its rows" ($null -ne $panel)
    if ($null -eq $panel) { return }
    Assert "one header heads the list (heads=$($panel.Heads.Count))" ($panel.Heads.Count -eq 1)
    Assert "...with a chevron, a hover x and a hover +" ($null -ne $panel.Chev -and $null -ne $panel.Hx -and $null -ne $panel.Ha)
    Assert "the rail's + slot is gone (radd=-)" ($null -eq $panel.Radd)
    $railYs = @(Get-GridYs $rail); $panelYs = @(Get-GridYs $panel)
    Assert "the header is above the first row ($($panel.Heads[0].Y) < $($panelYs[0]))" ($panel.Heads.Count -eq 1 -and $panel.Heads[0].Y -lt $panelYs[0])
    $same = ($railYs.Count -eq $panelYs.Count) -and ($railYs.Count -gt 0)
    for ($i = 0; $same -and $i -lt $railYs.Count; $i++) { if ([math]::Abs($railYs[$i] - $panelYs[$i]) -gt 1) { $same = $false } }
    Assert "every grid row is at its rail tile's height: rail $($railYs -join ',') vs panel $($panelYs -join ',')" $same
    Assert "the rail's + is level with the header ($($rail.Radd.Y) vs $($panel.Heads[0].Y))" ($null -ne $rail.Radd -and [math]::Abs($rail.Radd.Y - $panel.Heads[0].Y) -le 1)
    # T2340 (Mac 28f6cde09, c4dbe30be): the header carries a window icon
    # after its chevron, is one row's height, and is not selected while open.
    Assert "the header carries a window icon after its chevron (T2340)" ($null -ne $panel.HIcon -and $null -ne $panel.Chev -and $panel.HIcon.X -gt $panel.Chev.X -and [math]::Abs($panel.HIcon.Y - $panel.Chev.Y) -le 1)
    if ($panelYs.Count -ge 2) {
        $pitch = $panelYs[1] - $panelYs[0]
        $headPitch = $panelYs[0] - $panel.Heads[0].Y
        Assert "the header is one row's height: header->row $headPitch vs row->row $pitch (T2340)" ([math]::Abs($headPitch - $pitch) -le 1)
    } else { Assert "setup: at least two grid rows to measure the pitch ($($panelYs.Count))" $false }
    Assert "open, the header is not drawn selected (hsel=$($panel.HSel))" ($panel.HSel -eq '0')

    "== 3: the header's hover + splits right too"
    $before = Get-PaneCount
    Assert "setup: A is the active window" (Set-AActive $top)
    $mark = Get-LogCount
    $pt = $panel.Ha
    if ($NegativeControl) {
        "  NEGATIVE CONTROL: clicking the header's name instead of its + - this run MUST fail"
        $pt = @{ X = $panel.Chev.X + (Px 30); Y = $panel.Chev.Y }
    }
    [void](HoverClickAt $top $sb $pt)
    Assert "the header's + split right (log)" ($null -ne (Wait-Log 'pane sidebar add pane dir=right' $mark))
    Assert "one more pane in +list ($before -> ?)" (Wait-Until { (Get-PaneCount) -eq $before + 1 })
    $panel = Get-Rows 'expanded' $mark
    Assert "the panel lists three grid rows" ($null -ne $panel -and @(Get-GridYs $panel).Count -eq 3)
    if ($null -eq $panel) { return }

    "== 4: the chevron folds the panes away and back"
    $mark = Get-LogCount
    [void](ClickAt $top $sb $panel.Chev)
    Assert "it folded (log)" ($null -ne (Wait-Log 'pane sidebar fold$' $mark))
    $folded = Get-Rows 'expanded' $mark
    Assert "folded: the header stays, no row is listed ($(@($folded.Items).Count) items)" ($null -ne $folded -and $folded.Heads.Count -eq 1 -and @($folded.Items).Count -eq 0)
    Assert "folded: the header takes the selection, its pane being inside the fold (hsel=$($folded.HSel), T2340)" ($null -ne $folded -and $folded.HSel -eq '1')
    $mark = Get-LogCount
    if ($null -ne $folded) { [void](ClickAt $top $sb $folded.Chev) }
    Assert "it unfolded (log)" ($null -ne (Wait-Log 'pane sidebar unfold$' $mark))
    $open = Get-Rows 'expanded' $mark
    Assert "unfolded: the three rows are back" ($null -ne $open -and @(Get-GridYs $open).Count -eq 3)
    Assert "unfolded: the rows hold the selection again, not the header (hsel=$($open.HSel))" ($null -ne $open -and $open.HSel -eq '0')

    "== 4b: a '<project>: <name>' window's list sits under its group's header (T2350, Mac 32bc9a6b5)"
    Assert "setup: wB opened to keep the app up ($(Get-CliErr))" ((Invoke-Cli "+new-window --target=wB --name=b1") -eq 0)
    Assert "setup: wC opened ($(Get-CliErr))" ((Invoke-Cli "+new-window --target=wC --name=c1") -eq 0)
    Start-Sleep -Milliseconds 1200
    Assert "setup: wC titled proj: wt2 ($(Get-CliErr))" ((Invoke-Cli "+rename --target=wC --title=`"proj: wt2`"") -eq 0)
    Assert "setup: A is the active window" (Set-AActive $top)
    $mark = Get-LogCount
    Assert "setup: A titled proj: wt1 ($(Get-CliErr))" ((Invoke-Cli "+rename --target=window-1 --title=`"proj: wt1`"") -eq 0)
    $gl = Wait-Log 'pane sidebar rows mode=expanded heads=P0@.* pcount=2' $mark 6000
    $grouped = Read-Rows $gl
    Assert "the group's header heads A's list, above A's own (heads: $(if ($gl -match ' heads=(\S*)') { $Matches[1] }))" ($null -ne $gl -and $gl -match ' heads=P0@-?\d+,(-?\d+);W0@-?\d+,(-?\d+);' -and [int]$Matches[1] -lt [int]$Matches[2])
    Assert "...counting the whole group: two windows (pcount=2)" ($null -ne $gl)
    $pchev = @(Read-Points $gl 'pchev') | Select-Object -First 1
    $pha = @(Read-Points $gl 'pha') | Select-Object -First 1
    Assert "...with its own chevron, + and x (pchev/pha/phx logged)" ($null -ne $pchev -and $null -ne $pha -and @(Read-Points $gl 'phx').Count -eq 1)
    Assert "A's own header and its three rows stay under it" ($null -ne $grouped -and $grouped.Heads.Count -eq 1 -and @(Get-GridYs $grouped).Count -eq 3)
    if ($null -eq $pchev -or $null -eq $grouped) { return }
    $mark = Get-LogCount
    [void](ClickAt $top $sb $pchev)
    Assert "the group's chevron folded it (log)" ($null -ne (Wait-Log 'pane sidebar fold$' $mark))
    $pf = Wait-Log 'pane sidebar rows mode=expanded ' $mark
    Assert "folded: the group's header alone - no window header, no rows ($pf)" ($null -ne $pf -and $pf -match ' heads=P0@-?\d+,-?\d+; items= ' -and $pf -match ' tray=-')
    $mark = Get-LogCount
    [void](ClickAt $top $sb $pchev)
    Assert "a second click unfolded it (log)" ($null -ne (Wait-Log 'pane sidebar unfold$' $mark))
    $back = Read-Rows (Wait-Log 'pane sidebar rows mode=expanded heads=P0@' $mark)
    Assert "unfolded: A's header and three rows are back" ($null -ne $back -and $back.Heads.Count -eq 1 -and @(Get-GridYs $back).Count -eq 3)
    $windows = Get-AppWindowCount $app
    Assert "setup: A is the active window" (Set-AActive $top)
    $mark = Get-LogCount
    [void](HoverClickAt $top $sb $pha)
    Assert "the group's + opened a window in the group ($windows -> ?)" (Wait-Until { (Get-AppWindowCount $app) -eq $windows + 1 } 6000)
    Assert "...and A's group header now counts three (pcount=3)" ($null -ne (Wait-Log 'pane sidebar rows mode=expanded heads=P0@.* pcount=3' $mark 6000))

    "== 5: the header's hover x closes this window"
    Start-Sleep -Milliseconds 600
    $windows = Get-AppWindowCount $app
    Assert "setup: A is the active window" (Set-AActive $top)
    $panel = Get-Rows 'expanded' 0
    $mark = Get-LogCount
    if ($null -ne $panel -and $null -ne $panel.Hx) { [void](HoverClickAt $top $sb $panel.Hx) }
    Assert "a window close was asked for (log)" ($null -ne (Wait-Log 'pane sidebar close window windows=1' $mark))
    Assert "one window fewer ($windows -> ?)" (Wait-Until { (Get-AppWindowCount $app) -eq $windows - 1 })

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
    $keep = Join-Path $env:TEMP 't2324-app-stderr.log'
    Copy-Item $script:errlog $keep -Force
    "  (app log kept: $keep)"
}
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

} 2>&1 | Tee-Object -FilePath $transcript

Complete-TestBody  # T1039: the run reached the end of its body

if ($script:failures -eq 0 -and -not $NegativeControl) {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard pane-sidebar-this-window -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

""
exit (Complete-TestTranscript -Name 't2324' -Path $transcript `
        -Label 'T2324 ACCEPTANCE' -Pass $script:passes -Fail $script:failures).Code
