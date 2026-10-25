# T2108 acceptance: the win32 grid places panes through the stacked-panes
# layout - a pane stops at 300 DIP, and a row that cannot fit even at that
# minimum shows a run of panes and tucks the rest.
#
# THE CLAIM. Until T2108 every split handed its two sides `ratio` and
# `1 - ratio` of its rect, whatever that came to, so a row of four could
# squeeze a terminal down to a handful of columns. The window now lays out
# through `pane_stack_layout` (`Window.stackGrid`):
#
# Layout: P, then `+split right` -> s1, then off s1 -> s2, then off s2 -> s3:
# P | (s1 | (s2 | s3)). Each split halves its side, so the ratios ask for
# 1/2, 1/4, 1/8, 1/8 of the row.
#
# Claims:
#   A) in a window 1500 DIP wide all four panes are on show side by side, and
#      EVERY one is at least 300 DIP wide - the 1/8 panes asked for ~185
#   B) in a window 900 DIP wide (four panes need 4 x 300 DIP) exactly two are
#      on show, each at least 300 DIP, without overlapping; the other two are
#      tucked - hidden, but still sized to a slot of at least 300 DIP, so
#      bringing one forward is a move rather than a terminal resize
#   C) widened back to 1500 DIP, the four come back at the widths of claim A:
#      the minimum never rewrote the ratios the user made
#   and at each of A, B and C, `+list` (T2103) marks exactly the tucked panes
#   minimized - none, two, none - in --json and in the text listing, and
#   never the focused pane
#
# -NegativeControl inverts claim A to "some pane is under 300 DIP" - the
# answer the per-split layout gave - and MUST fail.
#
# Hermetic: per-run LOCALAPPDATA, per-run agent binary override, a private IPC
# pipe suffix, and it only ever kills ghoztty processes launched from this
# repo's zig-out. Runs on the BACKGROUND test desktop.
#
#   powershell -NoProfile -File test\win32\pane-stack-grid.ps1
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
$root = Join-Path $env:TEMP "ghoztty-pane-stack-grid-$PID"

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

# Wait until exactly `$n` pane HWNDs are visible.
function Wait-Shown([IntPtr]$top, [int]$n, [int]$timeoutSec = 20) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    do {
        $v = @(Get-VisiblePanes $top)
        if ($v.Count -eq $n) { return $v }
        Start-Sleep -Milliseconds 300
    } while ((Get-Date) -lt $deadline)
    return @(Get-VisiblePanes $top)
}

# Every terminal leaf `+list --json` reports (T2103), as objects with Name,
# Focused and Minimized.
function Get-ListLeaves {
    $raw = (& $exe +list --json) -join "`n"
    $out = New-Object System.Collections.ArrayList
    try { $doc = $raw | ConvertFrom-Json } catch { return }
    $walk = {
        param($node)
        if ($null -eq $node) { return }
        if ($node.type -eq 'leaf') {
            $t = $node.terminal
            [void]$out.Add([pscustomobject]@{ Name = $t.name; Focused = [bool]$t.focused; Minimized = ($t.minimized -eq $true) })
        } else {
            & $walk $node.left
            & $walk $node.right
        }
    }
    $doc.data.windows | ForEach-Object { $_.tabs | ForEach-Object { & $walk $_.splits } }
    return $out.ToArray()
}

# `+list` must mark exactly the hidden panes minimized, never the focused one,
# and the text listing must say so as often as the JSON does (T2103).
function Assert-ListMinimized([string]$claim, [int]$expect) {
    $leaves = @(Get-ListLeaves)
    $min = @($leaves | Where-Object Minimized)
    Say ("      +list: {0}" -f (($leaves | ForEach-Object { "$($_.Name)$(if ($_.Minimized) { '[min]' })$(if ($_.Focused) { '*' })" }) -join ' '))
    Assert ($leaves.Count -eq 4) "${claim}: +list --json reports four panes (got $($leaves.Count))"
    Assert ($min.Count -eq $expect) "${claim}: +list --json marks $expect pane(s) minimized (got $($min.Count))"
    Assert (@($min | Where-Object Focused).Count -eq 0) "${claim}: the focused pane is never reported minimized"
    $text = @((& $exe +list) | Where-Object { $_ -match '\[minimized\]' })
    Assert ($text.Count -eq $expect) "${claim}: the text listing tags $expect line(s) [minimized] (got $($text.Count))"
}

function Format-Cols($cols) {
    return (($cols | ForEach-Object { "$($_.Left)-$($_.Right)$(if (-not $_.Visible) { '(hidden)' })" }) -join ' | ')
}

# Resize the window to `$dip` DIP wide and wait for the grid to settle on `$n`
# panes on show.
function Set-WidthDip([IntPtr]$top, [double]$dip, [int]$n) {
    [void](Set-TestWindowPos -Window $top -X 0 -Y 0 -Width (Get-TestChromeDip -Dip $dip -Scale $script:scale) -Height (Get-TestChromeDip -Dip 700 -Scale $script:scale))
    Start-Sleep -Milliseconds 800
    $v = @(Wait-Shown $top $n)
    Start-Sleep -Milliseconds 500
    return @(Get-VisiblePanes $top)
}

# -----------------------------------------------------------------------------

$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN
$savedPipe = $env:GHOZTTY_PIPE_SUFFIX
$env:GHOZTTY_PIPE_SUFFIX = "-stackgrid$PID"

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
        Say 'NEGATIVE CONTROL: claim A is inverted to "some pane is under 300 DIP" - this run MUST fail'
    }

    # ---- setup: P | (s1 | (s2 | s3)) -----------------------------------------
    Say '== setup: P | (s1 | (s2 | s3))'
    $app = Start-App
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    # A window read the moment it appears can still answer 96 before it has
    # taken its monitor's DPI (seen beside other workers: 96 read, 120 laid
    # out, so every width below came out 25% short). Wait for two readings
    # in a row to agree.
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
    $minPx = [int][math]::Floor(300 * $script:scale) - 2
    Say ("      dpi {0} (scale {1:N2}); 300 DIP = {2}px, asserted as >= {3}px" -f $dpi, $script:scale, (Get-TestChromeDip -Dip 300 -Scale $script:scale), $minPx)
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

    # ---- A: wide - four on show, none under the minimum ------------------------
    Say '== A: 1500 DIP wide'
    $wide = @(Set-WidthDip $top 1500 4)
    Say ("      panes: {0}" -f (Format-Cols (Get-Panes $top)))
    Assert ($wide.Count -eq 4) "A: four panes on show at 1500 DIP (got $($wide.Count))"
    $narrowest = if ($wide.Count -gt 0) { ($wide | Measure-Object -Property Width -Minimum).Minimum } else { 0 }
    if ($NegativeControl) {
        Assert ($narrowest -lt $minPx) "NEGATIVE: some pane is under 300 DIP (narrowest $narrowest px)"
    } else {
        Assert ($narrowest -ge $minPx) "A: every pane is at least 300 DIP wide (narrowest $narrowest px, floor $minPx px)"
    }
    $overlap = $false
    for ($i = 1; $i -lt $wide.Count; $i++) { if ($wide[$i].Left -lt $wide[$i - 1].Right) { $overlap = $true } }
    Assert (-not $overlap) 'A: the four panes sit side by side without overlapping'
    $wideWidths = @($wide | ForEach-Object { $_.Width })
    Assert-ListMinimized 'A' 0

    # ---- B: narrow - a run of two, the rest tucked -----------------------------
    Say '== B: 900 DIP wide'
    $narrow = @(Set-WidthDip $top 900 2)
    $all = @(Get-Panes $top)
    Say ("      panes: {0}" -f (Format-Cols $all))
    Assert ($all.Count -eq 4) "B: all four pane windows still exist (got $($all.Count))"
    Assert ($narrow.Count -eq 2) "B: exactly two panes on show at 900 DIP (got $($narrow.Count))"
    if ($narrow.Count -eq 2) {
        Assert ($narrow[0].Width -ge $minPx -and $narrow[1].Width -ge $minPx) `
            "B: both panes on show are at least 300 DIP ($($narrow[0].Width), $($narrow[1].Width) px)"
        Assert ($narrow[1].Left -ge $narrow[0].Right) 'B: the two panes on show do not overlap'
    }
    $tucked = @($all | Where-Object { -not $_.Visible })
    Assert ($tucked.Count -eq 2) "B: the other two are tucked (hidden) (got $($tucked.Count))"
    $smallTuck = @($tucked | Where-Object { $_.Width -lt $minPx })
    Assert ($tucked.Count -gt 0 -and $smallTuck.Count -eq 0) `
        ("B: every tucked pane keeps a slot of at least 300 DIP ({0} px)" -f (($tucked | ForEach-Object { $_.Width }) -join ', '))
    Assert-ListMinimized 'B' 2

    # ---- C: wide again - the layout the user made comes back -------------------
    Say '== C: back to 1500 DIP'
    $again = @(Set-WidthDip $top 1500 4)
    Say ("      panes: {0}" -f (Format-Cols (Get-Panes $top)))
    Assert ($again.Count -eq 4) "C: four panes on show again (got $($again.Count))"
    if ($again.Count -eq 4 -and $wideWidths.Count -eq 4) {
        $drift = 0
        for ($i = 0; $i -lt 4; $i++) { $drift = [math]::Max($drift, [math]::Abs($again[$i].Width - $wideWidths[$i])) }
        Assert ($drift -le 2) "C: every pane is back at its claim-A width (max drift $drift px)"
    }
    Assert-ListMinimized 'C' 0

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
        update -Guard pane-stack-grid -Repo $repo 2>&1 | ForEach-Object { Say "  $_" }
}

Say ''
Write-TestVerdict -Label 'T2108 PANE STACK GRID' -Pass $script:pass -Fail $script:fail
