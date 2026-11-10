# T2863 acceptance: a press in a BACKGROUND window's pane sidebar that will
# raise ANOTHER window must not first bring the background window forward.
#
# The user report: after switching windows from the sidebar, the window they
# had switched AWAY from "rose on hover" over the one they had brought
# forward. The installed app's log showed every such rise was the press of a
# click on a header in that background window's sidebar: the press activates
# the window the sidebar sits in (WM_MOUSEACTIVATE, on the DOWN), and only the
# release raises the target. So the window the user was leaving came over
# the one in front for the length of the press. The fix answers
# WM_MOUSEACTIVATE with MA_NOACTIVATE for exactly the presses whose click
# raises another window.
#
# A posted click off the input desktop never brings WM_MOUSEACTIVATE, and a
# background desktop has no cursor to press with, so the decision is read
# through the sidebar's debug-only press probe (WM_APP+0x42): the same
# function the activation message calls, asked at a client point. What it
# checks, in window A's sidebar with the all-windows scope on:
#
#   1. Another window's header: the press leaves A behind (MA_NOACTIVATE).
#   2. A's own header, and the other window's fold chevron: A activates as
#      any click in it would (MA_ACTIVATE) - those act on A.
#   3. A's own pane row: activates. The other window's pane row: leaves A
#      behind.
#   4. Collapsed to the rail: the other window's tile leaves A behind; A's
#      own tile activates.
#   5. The click itself is unchanged: a posted click on the other window's
#      header still raises it (log).
#
# Runs on a BACKGROUND desktop (lib\TestDesktop.ps1) and never takes the
# user's foreground - asserted by the foreground watcher, not assumed.
# -NegativeControl expects the press on another window's header to ACTIVATE
# (the pre-fix answer) and MUST fail.
#
#   powershell -NoProfile -File test\win32\pane-sidebar-press-activate.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [switch]$NegativeControl,
    [switch]$Interactive
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:passes = 0
$tmp = Join-Path $env:TEMP "ghoztty-t2863-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ } else { "  FAIL $name"; $script:failures++ }
}
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 't2863')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\ChromeGeometry.ps1')
if (-not ('PressProbeSend' -as [type])) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class PressProbeSend {
    [DllImport("user32.dll")] public static extern IntPtr SendMessageW(IntPtr h, uint msg, IntPtr wp, IntPtr lp);
}
"@
}

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
# The LAST line matching $Pattern logged after line $Skip, waiting up to $Ms.
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

# A `pane sidebar outline` line: heads (W/P/U + group @ x,y), items
# (g<group><sec> @ x,y) and each head's chevron, in client coordinates.
function Read-Outline([string]$Line) {
    if (-not $Line -or $Line -notmatch 'mode=(\w+) heads=(\S*) items=(\S*) ') { return $null }
    $o = @{ Mode = $Matches[1]; Heads = @(); Items = @(); Chev = @() }
    $headsRaw = $Matches[2]; $itemsRaw = $Matches[3]
    foreach ($h in ($headsRaw -split ';' | Where-Object { $_ })) {
        if ($h -match '^([PWU])(\d+)@(-?\d+),(-?\d+)$') { $o.Heads += , @{ Kind = $Matches[1]; Group = [int]$Matches[2]; X = [int]$Matches[3]; Y = [int]$Matches[4] } }
    }
    foreach ($i in ($itemsRaw -split ';' | Where-Object { $_ })) {
        if ($i -match '^g(\d+)([gs])@(-?\d+),(-?\d+)$') { $o.Items += , @{ Group = [int]$Matches[1]; Sec = $Matches[2]; X = [int]$Matches[3]; Y = [int]$Matches[4] } }
    }
    if ($Line -match ' chev=(\S*)') { foreach ($c in ($Matches[1] -split ';' | Where-Object { $_ })) { $xy = $c -split ','; $o.Chev += , @{ X = [int]$xy[0]; Y = [int]$xy[1] } } }
    return $o
}
function HeadIndex($o, [int]$Group) {
    for ($k = 0; $k -lt $o.Heads.Count; $k++) { if ($o.Heads[$k].Kind -eq 'W' -and $o.Heads[$k].Group -eq $Group) { return $k } }
    return -1
}
function ClickAt($top, $sb, $pt) {
    return Send-TestMouse -Window $top -Target ([IntPtr]$sb.Hwnd) -X ($sb.Left + $pt.X) -Y ($sb.Top + $pt.Y) -Action click
}
# What WM_MOUSEACTIVATE would answer for a press at client $pt: 1 activate,
# 3 leave the window where it is, 0 a release build (no probe).
function Probe($sb, $pt) {
    $lp = [IntPtr](([int]$pt.Y -shl 16) -bor ([int]$pt.X -band 0xFFFF))
    return [int][PressProbeSend]::SendMessageW([IntPtr]$sb.Hwnd, [uint32](0x8000 + 0x42), [IntPtr]::Zero, $lp)
}
$MA_ACTIVATE = 1
$MA_NOACTIVATE = 3

function Get-ToggleCenter($sb) {
    $margin = Px 12; $card = Px 52; $tile = Px 28
    $inset = [int][math]::Truncate(($card - $tile) / 2)
    return @{ X = $margin + $inset + [int]($tile / 2); Y = $margin + $inset + [int]($tile / 2) }
}
function Get-ScopeCenter($sb) {
    return @{ X = $sb.Width - (Px 4) - [int]((Px 28) / 2); Y = (Get-ToggleCenter $sb).Y }
}

. (Join-Path $PSScriptRoot 'lib\Transcript.ps1')
$transcript = New-TestTranscript -Name 't2863'

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

    # Window A ("zeta", sorts last) and wB ("alpha", sorts first).
    Assert "setup: window A renamed zeta ($(Get-CliErr))" ((Invoke-Cli "+rename --target=window-1 --title=zeta") -eq 0)
    Assert "setup: wB opened ($(Get-CliErr))" ((Invoke-Cli "+new-window --target=wB --name=b1 --title=alpha") -eq 0)
    Start-Sleep -Milliseconds 1200
    Assert "setup: window A is the active window again" (Set-TestActiveWindow -Window $top)
    Start-Sleep -Milliseconds 400

    $sb = Get-Sidebar $top
    Assert "A has a sidebar" ($null -ne $sb -and $sb.Visible)
    if ($null -eq $sb) { return }
    [void](ClickAt $top $sb (Get-ToggleCenter $sb))
    Start-Sleep -Milliseconds 700
    $sb = Get-Sidebar $top
    $mark = Get-LogCount
    [void](ClickAt $top $sb (Get-ScopeCenter $sb))
    $groups = Wait-Log 'pane sidebar all-windows groups=' $mark
    "  $groups"
    Assert "setup: the all-windows scope lists alpha then zeta" ($groups -match 'order=alpha\|zeta$')
    $o = Read-Outline (Wait-Log 'pane sidebar outline mode=expanded' $mark)
    Assert "setup: the outline geometry was logged" ($null -ne $o)
    if ($null -eq $o) { return }
    $kB = HeadIndex $o 0
    $kA = HeadIndex $o 1
    Assert "setup: two window heads, alpha's and zeta's ($kB, $kA)" ($kB -ge 0 -and $kA -ge 0 -and $o.Chev.Count -eq $o.Heads.Count)
    if ($kB -lt 0 -or $kA -lt 0 -or $o.Chev.Count -ne $o.Heads.Count) { return }

    "== 1: a press on another window's header leaves this window behind"
    $r = Probe $sb $o.Heads[$kB]
    Assert "the press probe answers (a debug build): $r" ($r -ne 0)
    if ($NegativeControl) {
        "  NEGATIVE CONTROL: expecting the pre-fix answer (activate) - this run MUST fail"
        Assert "alpha's header press activates A (pre-fix): $r" ($r -eq $MA_ACTIVATE)
    } else {
        Assert "alpha's header press leaves A where it is (MA_NOACTIVATE): $r" ($r -eq $MA_NOACTIVATE)
    }

    "== 2: presses that act on this window activate it"
    $r = Probe $sb $o.Heads[$kA]
    Assert "zeta's own header press activates A: $r" ($r -eq $MA_ACTIVATE)
    $r = Probe $sb $o.Chev[$kB]
    Assert "alpha's fold chevron press activates A (it folds, raises nothing): $r" ($r -eq $MA_ACTIVATE)

    "== 3: rows - another window's leaves this one behind, this window's activates"
    # T2408 (Mac 7e2d0a9da): the scope opens with every window folded, this
    # one too - unfold zeta first (alpha sorts above it, so its chevron stays).
    $mark = Get-LogCount
    [void](ClickAt $top $sb $o.Chev[$kA])
    Assert "setup: zeta's chevron unfolded it (log)" ($null -ne (Wait-Log 'pane sidebar unfold' $mark 2000))
    $o = Read-Outline (Wait-Log 'pane sidebar outline mode=expanded' $mark)
    $own = if ($o) { $o.Items | Where-Object { $_.Group -eq 1 } | Select-Object -First 1 } else { $null }
    Assert "setup: zeta's row is listed" ($null -ne $own)
    if ($own) {
        $r = Probe $sb $own
        Assert "zeta's own row press activates A: $r" ($r -eq $MA_ACTIVATE)
    }
    $mark = Get-LogCount
    [void](ClickAt $top $sb $o.Chev[$kB])
    Assert "setup: alpha's chevron unfolded it (log)" ($null -ne (Wait-Log 'pane sidebar unfold' $mark 2000))
    $o = Read-Outline (Wait-Log 'pane sidebar outline mode=expanded' $mark)
    $other = if ($o) { $o.Items | Where-Object { $_.Group -eq 0 } | Select-Object -First 1 } else { $null }
    Assert "setup: alpha's row is listed" ($null -ne $other)
    if ($other) {
        $r = Probe $sb $other
        Assert "alpha's row press leaves A where it is: $r" ($r -eq $MA_NOACTIVATE)
    }

    "== 4: the rail - another window's tile leaves this one behind, this window's activates"
    $mark = Get-LogCount
    [void](ClickAt $top $sb (Get-ToggleCenter $sb))
    $railLine = Wait-Log 'pane sidebar outline mode=mini' $mark
    $o6 = Read-Outline $railLine
    $sb = Get-Sidebar $top
    $wsel = if ($railLine -match ' wsel=(\S+)') { $Matches[1] } else { $null }
    Assert "setup: two window tiles on the rail, this window's selected (wsel=$wsel)" ($null -ne $o6 -and $o6.Items.Count -eq 2 -and $null -ne $wsel -and $wsel -ne '-')
    if ($o6 -and $wsel) {
        $ownTile = $o6.Items | Where-Object { "g$($_.Group)" -eq $wsel } | Select-Object -First 1
        $otherTile = $o6.Items | Where-Object { "g$($_.Group)" -ne $wsel } | Select-Object -First 1
        if ($ownTile) { $r = Probe $sb $ownTile; Assert "zeta's own tile press activates A: $r" ($r -eq $MA_ACTIVATE) }
        if ($otherTile) { $r = Probe $sb $otherTile; Assert "alpha's tile press leaves A where it is: $r" ($r -eq $MA_NOACTIVATE) }
        Assert "setup: both tiles found" ($null -ne $ownTile -and $null -ne $otherTile)
    }
    [void](ClickAt $top $sb (Get-ToggleCenter $sb))
    Start-Sleep -Milliseconds 700
    $sb = Get-Sidebar $top

    "== 5: the click itself still raises the other window"
    $o = Read-Outline (Wait-Log 'pane sidebar outline mode=expanded' 0 1000)
    $k = if ($o) { HeadIndex $o 0 } else { -1 }
    $mark = Get-LogCount
    if ($k -ge 0) { [void](ClickAt $top $sb $o.Heads[$k]) }
    Assert "a click on alpha's header raises it (log)" ($null -ne (Wait-Log 'pane sidebar raise window' $mark 2000))

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

Complete-TestBody  # T1039: the run reached the end of its body

if ($script:failures -eq 0 -and -not $NegativeControl) {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard pane-sidebar-press-activate -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

""
exit (Complete-TestTranscript -Name 't2863' -Path $transcript `
        -Label 'T2863 ACCEPTANCE' -Pass $script:passes -Fail $script:failures).Code
