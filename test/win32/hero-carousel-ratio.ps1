# hero-carousel-ratio.ps1 - T2590 acceptance: `macos-hero-carousel-ratio`.
#
# Mac 92ab0c9f1: the key (default 0.25, clamped 0.1-0.6) is the carousel's
# share each time hero mode turns on, until its divider is dragged in that
# window; from then on the dragged share stands. On Windows the per-window
# state is per TAB (a Windows tab is the Mac window's counterpart).
#
# Launched with --macos-hero-carousel-ratio=0.4, on the background test
# desktop (never the user's foreground):
#   A. hero on: the carousel is ~40% of the pane grid (the default would be
#      25%, so this is the config being honored, not the fixed default).
#   B. drag the divider 150px left, hero off, hero on: the DRAGGED width is
#      kept (not re-seeded from the config).
#   C. double-click the divider: back to the configured ~40%.
#   D. hero off, hero on: still ~40% - the reset handed the tab back to the
#      config key.
#
# -NegativeControl launches WITHOUT the key and requires section A to read
# 40%: it must go red (the default is 25%), proving the oracle can tell them
# apart.
param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }
$env:GHOZTTY_PIPE_SUFFIX = "-heroratio$PID"
$errlog = Join-Path $env:TEMP 'ghoztty-hero-carousel-ratio-stderr.log'
Remove-Item $errlog -ErrorAction SilentlyContinue

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Kill-RepoInstances { [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500) }

# Every GhozttyTerminal child (hidden ones included) in CLIENT coordinates.
# Unary comma: a one-element array would otherwise unroll to a scalar.
function Get-Panes([IntPtr]$top) {
    $c = Get-TestWindowRect -Window $top -Client
    return , @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal' | ForEach-Object {
        [pscustomobject]@{
            Hwnd = $_.Hwnd; Visible = $_.Visible
            Left = $_.Left - $c.Left; Top = $_.Top - $c.Top
            Right = $_.Right - $c.Left; Bottom = $_.Bottom - $c.Top
            Width = $_.Width; Height = $_.Height
        }
    })
}
function Get-Visible($panes) { return , @($panes | Where-Object Visible) }
function Get-ClientWidth([IntPtr]$top) { (Get-TestWindowRect -Window $top -Client).Width }
function To-Screen([IntPtr]$top, [int]$x, [int]$y) {
    $c = Get-TestWindowRect -Window $top -Client
    return @(($c.Left + $x), ($c.Top + $y))
}

# The single visible hero pane, or $null.
function Get-Hero([IntPtr]$top) {
    $v = Get-Visible (Get-Panes $top)
    if ($v.Count -eq 1) { return $v[0] }
    return $null
}

# Carousel share of the pane grid: everything right of the hero card.
function Get-CarouselShare([IntPtr]$top, $hero) {
    $cw = Get-ClientWidth $top
    return ($cw - $hero.Right) / [double]($cw - $script:GridLeft)
}

function Toggle-Hero([IntPtr]$top, [IntPtr]$target) {
    $ok = Send-TestKeys -Window $top -Target $target -Modifiers @('ctrl', 'shift') -Key 'Space'
    Start-Sleep -Milliseconds 900
    return $ok
}

# Where the divider can be grabbed: just right of the hero pane (in the band).
function Get-DividerX($hero) { return $hero.Right + 3 }

$want = 0.4
$tol = 0.05

Kill-RepoInstances
Remove-Item (Get-GhozttySessionLayoutPath -Root $env:LOCALAPPDATA) -Force -ErrorAction SilentlyContinue
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$launched = @()

try {
    $appArgs = @('--config-default-files=false', '--session-persistence=false')
    if (-not $NegativeControl) { $appArgs += "--macos-hero-carousel-ratio=$want" }
    $app = Start-OnTestDesktop -Exe $exe -StdErr $errlog -Arguments $appArgs
    $gpid = [int]$app.Pid
    $launched += $gpid
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $top = Wait-TestWindow -ProcessId $gpid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: top window not found'; exit 1 }
    Set-TestWindowSize -Window $top -Width 1400 -Height 900 | Out-Null
    Start-Sleep -Milliseconds 500
    Assert (-not (Test-TestDesktopLeak -ProcessId $gpid)) 'GUI is NOT enumerable on the interactive desktop'

    & $exe +split --direction=down --name=ratiob | Out-Null
    Start-Sleep -Milliseconds 1200
    $pair = Get-Panes $top
    if ($pair.Count -ne 2) { Write-Host "SETUP FAIL: expected 2 panes, got $($pair.Count)"; exit 1 }
    $leaf0 = ($pair | Sort-Object Top, Left | Select-Object -First 1)
    $leaf0Hwnd = [IntPtr]$leaf0.Hwnd
    $script:GridLeft = [int](@($pair | ForEach-Object { $_.Left }) | Measure-Object -Minimum).Minimum

    # --- A: hero on starts at the configured share --------------------------
    Assert (Toggle-Hero $top $leaf0Hwnd) 'A: hero toggle chord delivered'
    $heroA = Get-Hero $top
    Assert ($null -ne $heroA) 'A: hero mode on (exactly one visible pane)'
    if ($null -eq $heroA) { Write-Host 'ABORT: hero never turned on'; exit 1 }
    $shareA = Get-CarouselShare $top $heroA
    Assert ([math]::Abs($shareA - $want) -lt $tol) `
        ("A: the carousel starts at macos-hero-carousel-ratio ({0:P0}; got {1:P1}, default would be 25%)" -f $want, $shareA)
    if (-not $NegativeControl) {
    # --- B: a dragged divider survives hero off/on --------------------------
    $midY = [int](($heroA.Top + $heroA.Bottom) / 2)
    $divX = Get-DividerX $heroA
    $sDown = To-Screen $top $divX $midY
    $sMove = To-Screen $top ($divX + 150) $midY
    [void](Send-TestMouse -Window $top -Target $top -X $sDown[0] -Y $sDown[1] -Action down)
    Start-Sleep -Milliseconds 60
    [void](Send-TestMouse -Window $top -Target $top -X $sMove[0] -Y $sMove[1] -Action move)
    Start-Sleep -Milliseconds 150
    [void](Send-TestMouse -Window $top -Target $top -X $sMove[0] -Y $sMove[1] -Action move)
    Start-Sleep -Milliseconds 120
    [void](Send-TestMouse -Window $top -Target $top -X $sMove[0] -Y $sMove[1] -Action up)
    Start-Sleep -Milliseconds 500
    $heroB = Get-Hero $top
    Assert ($null -ne $heroB -and $heroB.Width -ge ($heroA.Width + 100)) `
        "B: the divider drag widened the hero ($($heroA.Width) -> $(if ($heroB) { $heroB.Width }))"
    if ($null -eq $heroB) { Write-Host 'ABORT: hero lost after drag'; exit 1 }
    $draggedW = $heroB.Width

    Assert (Toggle-Hero $top ([IntPtr]$heroB.Hwnd)) 'B: hero off chord delivered'
    Assert ((Get-Visible (Get-Panes $top)).Count -eq 2) 'B: hero off restores both panes'
    Assert (Toggle-Hero $top $leaf0Hwnd) 'B: hero on again chord delivered'
    $heroB2 = Get-Hero $top
    Assert ($null -ne $heroB2 -and [math]::Abs($heroB2.Width - $draggedW) -le 2) `
        "B: hero on again keeps the DRAGGED width, not the configured one ($draggedW -> $(if ($heroB2) { $heroB2.Width }))"
    if ($null -eq $heroB2) { Write-Host 'ABORT: hero did not come back on'; exit 1 }

    # --- C: double-click the divider returns to the configured share --------
    $sDbl = To-Screen $top (Get-DividerX $heroB2) $midY
    [void](Send-TestMouse -Window $top -Target $top -X $sDbl[0] -Y $sDbl[1] -Action doubleclick)
    Start-Sleep -Milliseconds 500
    $heroC = Get-Hero $top
    $shareC = if ($heroC) { Get-CarouselShare $top $heroC } else { -1 }
    Assert ([math]::Abs($shareC - $want) -lt $tol) `
        ("C: double-clicking the divider resets to the configured share ({0:P0}; got {1:P1})" -f $want, $shareC)

    # --- D: after the reset, the config key leads again ---------------------
    if ($null -ne $heroC) {
        Assert (Toggle-Hero $top ([IntPtr]$heroC.Hwnd)) 'D: hero off chord delivered'
        Assert (Toggle-Hero $top $leaf0Hwnd) 'D: hero on chord delivered'
        $heroD = Get-Hero $top
        $shareD = if ($heroD) { Get-CarouselShare $top $heroD } else { -1 }
        Assert ([math]::Abs($shareD - $want) -lt $tol) `
            ("D: after the reset, hero on starts at the configured share again ({0:P1})" -f $shareD)
    }
    }
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'no crash through the run'
} finally {
    Remove-TestDesktop
    Kill-RepoInstances
}

$fgSeen = @(Stop-TestForegroundWatch)
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @(@($launched) + @(Get-TestLaunchedPids) | Select-Object -Unique)
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'no test-desktop app ever became foreground on the interactive desktop'
}

# A clean green run stamps the covered files (T783) so scripts\guard-due.ps1 can
# answer "has this been checked against the code as it now stands?". Never
# under -NegativeControl: that run is red on purpose.
if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard hero-carousel-ratio -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILED / $script:pass passed" -ForegroundColor Red; exit 1 }
