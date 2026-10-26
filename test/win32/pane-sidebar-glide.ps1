# T2291 acceptance: collapsing or expanding the pane sidebar glides (Mac
# 543489bca). On Mac the grid's cards glide over from where they were, each
# terminal resized once after the motion, while the sidebar's width animates
# on the same curve and the rail and panel crossfade in it. It used to snap.
#
# Layout: the first pane P, then `+split right` -> s1, flat pane style, a
# window wide enough for the panel. Both motions are stretched so a sample can
# land mid-glide: the column to 2 s (`GHOZTTY_SIDEBAR_COLUMN_MS`), the grid's
# glide to about the same (`GHOZTTY_STACK_SLIDE_MS`). What it checks:
#
#   1. At rest: the 76 DIP rail, the grid right after it.
#   2. The toggle expands: part-way through, the column is wider than the rail
#      and narrower than the panel, and s1 is on its way over - right of where
#      it was, short of where it goes - at the width it had (its terminal is
#      not resized mid-glide). The log names both motions. Once over: the
#      panel's width, s1 at its new slot and new width.
#   3. The toggle collapses: the same in reverse - the column part-way between
#      panel and rail, s1 on its way back at the width it had.
#   4. ctrl+shift+s hides the sidebar: the grid still glides over (log), and
#      the column itself just goes - Mac's hidden mode has no column to animate.
#
# Runs on a BACKGROUND desktop (lib\TestDesktop.ps1) and never takes the
# user's foreground - asserted by the foreground watcher, not assumed.
# -NegativeControl runs with both motions at 0 ms (a snap) and MUST fail.
#
#   powershell -NoProfile -File test\win32\pane-sidebar-glide.ps1
# @timing-sensitive
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [switch]$NegativeControl,
    [switch]$Interactive
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:passes = 0
$tmp = Join-Path $env:TEMP "ghoztty-t2291-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ } else { "  FAIL $name"; $script:failures++ }
}
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 't2291')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\ChromeGeometry.ps1')

$Cli = [System.IO.Path]::ChangeExtension($Exe, '.com')
if (-not (Test-Path $Cli)) { $Cli = $Exe }

function Invoke-Cli([string]$CliArgs) {
    cmd /c "`"$Cli`" $CliArgs > `"$tmp\out.txt`" 2> `"$tmp\err.txt`"" | Out-Null
    return $LASTEXITCODE
}

function Get-Panes($top) { @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal') }
function Get-Sidebar($top) { @(Get-TestChildWindows -Window $top -Class 'GhozttyPaneSidebar') | Select-Object -First 1 }
function Get-Pane($top, $h) { Get-Panes $top | Where-Object { $_.Hwnd -eq $h } | Select-Object -First 1 }
function Px([double]$Dip) { Get-TestChromeDip -Dip $Dip -Scale $script:scale }
# The expanded column (T2290): the rail's card at the panel's width, in the
# rail's own 12 DIP insets (flat style).
function PanelColumn([double]$Dip) { (Px 12) + (Px $Dip) + (Px 12) }
# The collapse/expand toggle (T2289): the same pixels in both modes.
function Get-ToggleCenter($sb) {
    $margin = Px 12; $card = Px 52; $tile = Px 28
    $inset = [int][math]::Truncate(($card - $tile) / 2)
    return @{ X = $sb.Left + $margin + $inset + [int]($tile / 2); Y = $sb.Top + $margin + $inset + [int]($tile / 2) }
}
function Click($top, $target, $pt) {
    return Send-TestMouse -Window $top -Target ([IntPtr]$target) -X $pt.X -Y $pt.Y -Action click
}
function New-LogLines([int]$From) { @(Get-Content $errlog -ErrorAction SilentlyContinue | Select-Object -Skip $From) }
function Get-LogCount { @(Get-Content $errlog -ErrorAction SilentlyContinue).Count }

. (Join-Path $PSScriptRoot 'lib\Transcript.ps1')
$transcript = New-TestTranscript -Name 't2291'

$glideMs = if ($NegativeControl) { 0 } else { 2000 }
$savedColumn = $env:GHOZTTY_SIDEBAR_COLUMN_MS
$savedSlide = $env:GHOZTTY_STACK_SLIDE_MS
$env:GHOZTTY_SIDEBAR_COLUMN_MS = "$glideMs"
$env:GHOZTTY_STACK_SLIDE_MS = "$glideMs"

Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$launched = @()
$script:reachedEnd = $false
$script:scale = 1.0

& {
try {
    [void](Stop-RepoGhoztty -Exe $Exe -AppOnly -SettleMs 500)
    Assert-GhozttyPrivateEndpoint -Exe $Exe
    if ($NegativeControl) { "  NEGATIVE CONTROL: both motions at 0 ms (a snap) - this run MUST fail" }
    $errlog = Join-Path $tmp 'app-stderr.log'
    $app = Start-OnTestDesktop -Exe $Exe -StdErr $errlog -Arguments @('--session-persistence=false', '--macos-pane-style=flat')
    Start-Sleep -Seconds 3
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { "  SETUP FAIL: top window not found"; $script:failures++; return }
    Assert "window is NOT enumerable on the interactive desktop" (-not (Test-TestDesktopLeak -ProcessId $app.Pid))
    $dpi = Get-TestWindowDpi -Window $top
    if ($dpi -gt 0) { $script:scale = $dpi / 96.0 }
    "  (window dpi $dpi, scale $($script:scale))"
    [void](Set-TestWindowSize -Window $top -Width (Px 1100) -Height (Px 700))
    Start-Sleep -Milliseconds 600

    $hP = (@(Get-Panes $top))[0].Hwnd
    [void](Invoke-Cli "+split --direction=right --name=s1")
    Start-Sleep -Milliseconds 900
    $h1 = (@(Get-Panes $top) | Where-Object { $_.Hwnd -ne $hP } | Select-Object -First 1).Hwnd
    Assert "setup: two visible panes" ((@(Get-Panes $top | Where-Object Visible)).Count -eq 2 -and $h1)

    "== 1: at rest, the rail and the grid beside it"
    $sb = Get-Sidebar $top
    Assert "the sidebar is up" ($null -ne $sb -and $sb.Visible)
    if ($null -eq $sb) { return }
    $railW = $sb.Width
    $panelW = PanelColumn 240
    Assert "it is the 76 DIP rail ($railW)" ([math]::Abs($railW - (Px 76)) -le 1)
    $s1Rail = Get-Pane $top $h1
    "  s1 at rest: left=$($s1Rail.Left) width=$($s1Rail.Width)"

    "== 2: expanding glides"
    $mark = Get-LogCount
    Assert "toggle click delivered" (Click $top $sb.Hwnd (Get-ToggleCenter $sb))
    Start-Sleep -Milliseconds 350
    $midSb = Get-Sidebar $top
    $midS1 = Get-Pane $top $h1
    "  mid-glide: column=$($midSb.Width) s1 left=$($midS1.Left) width=$($midS1.Width)"
    Assert "part-way, the column is wider than the rail and narrower than the panel ($railW < $($midSb.Width) < $panelW)" ($midSb.Width -gt $railW + 1 -and $midSb.Width -lt $panelW - 1)
    Start-Sleep -Milliseconds 2600
    $new = New-LogLines $mark
    $sb = Get-Sidebar $top
    $s1Panel = Get-Pane $top $h1
    "  landed: column=$($sb.Width) s1 left=$($s1Panel.Left) width=$($s1Panel.Width)"
    Assert "s1 was on its way over: right of where it was, short of where it went ($($s1Rail.Left) < $($midS1.Left) < $($s1Panel.Left))" ($midS1.Left -gt $s1Rail.Left -and $midS1.Left -lt $s1Panel.Left)
    Assert "...at the width it had, its terminal not resized mid-glide ($($midS1.Width) vs $($s1Rail.Width))" ($midS1.Width -eq $s1Rail.Width)
    Assert "once over, the column is the panel ($($sb.Width) vs $panelW)" ([math]::Abs($sb.Width - $panelW) -le 1)
    Assert "...and s1 took its narrower slot ($($s1Panel.Width) < $($s1Rail.Width))" ($s1Panel.Width -lt $s1Rail.Width)
    Assert "the log names the column's glide (rail -> panel)" (@($new | Where-Object { $_ -match "pane sidebar column glide expanded from=$railW to=$panelW ms=$glideMs" }).Count -eq 1)
    Assert "...and the grid's (both cards)" (@($new | Where-Object { $_ -match 'pane grid glides for the sidebar column: cards=2' }).Count -ge 1)
    Assert "...and the column's landing" (@($new | Where-Object { $_ -match "pane sidebar column glide done width=$panelW" }).Count -eq 1)

    "== 3: collapsing glides back"
    $mark = Get-LogCount
    Assert "toggle click delivered" (Click $top $sb.Hwnd (Get-ToggleCenter $sb))
    Start-Sleep -Milliseconds 350
    $midSb = Get-Sidebar $top
    $midS1 = Get-Pane $top $h1
    "  mid-glide: column=$($midSb.Width) s1 left=$($midS1.Left) width=$($midS1.Width)"
    Assert "part-way, the column is narrower than the panel and wider than the rail ($railW < $($midSb.Width) < $panelW)" ($midSb.Width -gt $railW + 1 -and $midSb.Width -lt $panelW - 1)
    Start-Sleep -Milliseconds 2600
    $new = New-LogLines $mark
    $sb = Get-Sidebar $top
    $s1Back = Get-Pane $top $h1
    "  landed: column=$($sb.Width) s1 left=$($s1Back.Left) width=$($s1Back.Width)"
    Assert "s1 was on its way back: left of the panel's slot, right of the rail's ($($s1Back.Left) < $($midS1.Left) < $($s1Panel.Left))" ($midS1.Left -lt $s1Panel.Left -and $midS1.Left -gt $s1Back.Left)
    Assert "...at the width it had ($($midS1.Width) vs $($s1Panel.Width))" ($midS1.Width -eq $s1Panel.Width)
    Assert "once over, the rail again ($($sb.Width))" ([math]::Abs($sb.Width - $railW) -le 1)
    Assert "...and s1 back in its slot (left $($s1Back.Left) vs $($s1Rail.Left), width $($s1Back.Width) vs $($s1Rail.Width))" ($s1Back.Left -eq $s1Rail.Left -and $s1Back.Width -eq $s1Rail.Width)
    Assert "the log names the column's glide (panel -> rail)" (@($new | Where-Object { $_ -match "pane sidebar column glide mini from=$panelW to=$railW ms=$glideMs" }).Count -eq 1)
    Assert "...and the grid's" (@($new | Where-Object { $_ -match 'pane grid glides for the sidebar column: cards=2' }).Count -ge 1)

    "== 4: hiding glides the grid; the column just goes"
    $mark = Get-LogCount
    Assert "focus P for the chord" (Focus-TestWindow -Window $top -Child ([IntPtr]$hP))
    Assert "ctrl+shift+s delivered" (Send-TestKeys -Window $top -Target ([IntPtr]$hP) -Modifiers ctrl,shift -Key S)
    Start-Sleep -Milliseconds 2800
    $new = New-LogLines $mark
    $sb = Get-Sidebar $top
    Assert "the sidebar is hidden" ($null -eq $sb -or -not $sb.Visible)
    Assert "the grid glided over (log)" (@($new | Where-Object { $_ -match 'pane grid glides for the sidebar column: cards=2' }).Count -ge 1)
    Assert "...and no column glide ran (log)" (@($new | Where-Object { $_ -match 'pane sidebar column glide ' }).Count -eq 0)
    [void](Send-TestKeys -Window $top -Target ([IntPtr]$hP) -Modifiers ctrl,shift -Key S)
    Start-Sleep -Milliseconds 2800
    $sb = Get-Sidebar $top
    Assert "shown again, the rail" ($null -ne $sb -and $sb.Visible -and [math]::Abs($sb.Width - $railW) -le 1)
    $s1End = Get-Pane $top $h1
    Assert "...and s1 back in its slot (left $($s1End.Left) vs $($s1Rail.Left))" ($s1End.Left -eq $s1Rail.Left -and $s1End.Width -eq $s1Rail.Width)

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
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

} 2>&1 | Tee-Object -FilePath $transcript

if ($null -ne $savedColumn) { $env:GHOZTTY_SIDEBAR_COLUMN_MS = $savedColumn }
else { Remove-Item env:GHOZTTY_SIDEBAR_COLUMN_MS -ErrorAction SilentlyContinue }
if ($null -ne $savedSlide) { $env:GHOZTTY_STACK_SLIDE_MS = $savedSlide }
else { Remove-Item env:GHOZTTY_STACK_SLIDE_MS -ErrorAction SilentlyContinue }

Complete-TestBody  # T1039: the run reached the end of its body

if ($script:failures -eq 0 -and -not $NegativeControl) {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard pane-sidebar-glide -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

""
exit (Complete-TestTranscript -Name 't2291' -Path $transcript `
        -Label 'T2291 ACCEPTANCE' -Pass $script:passes -Fail $script:failures).Code
