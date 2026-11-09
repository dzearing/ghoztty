# T2802 acceptance: the pane sidebar's list transitions - the scope slide
# (this window <-> all windows) and a group's fold - run on the column's own
# composition tree (T2765) instead of being composed from three DIBs on every
# TIMER_XFADE tick (src\apprt\win32\pane_sidebar_transition_comp.zig).
#
# Layout: P, then `+split right` -> s1, the sidebar expanded.
#
# Two arms, each a fresh app:
#
#   COMP (no knob): the scope switch goes on the compositor
#   (`pane sidebar transition scope on compositor layers=3`), the tree is
#   built for it (`composition tree up for=list-transition`), and the slide
#   lands with `compositor=true ui_steps=0` - no frame of it was composed on
#   the UI thread, so a busy UI thread cannot freeze it. A fold of this
#   window's header and the unfold after it do the same, and neither lands
#   early. The switch back slides on the compositor too.
#   STEPPED (GHOZTTY_DEBUG_SIDEBAR_TRANSITION_STEPPED=1): the same clicks step
#   every transition on the frame clock as before (`compositor=false
#   ui_steps=<n>` with n > 0) - the A/B arm that shows the oracle can tell
#   who moved it.
#
# NOT covered here: what the layers LOOK like mid-motion - a background
# desktop cannot be photographed (CopyFromScreen is dead there) and
# WM_PRINTCLIENT returns the window's GDI pixels, not its composition tree.
# That the masked layers over the material reproduce the stepped compose is
# unit-tested (`a masked list over its material reproduces the stepped
# compose`, win32 + none lanes).
#
# Runs on a BACKGROUND desktop (lib\TestDesktop.ps1) and never takes the
# user's foreground - asserted by the foreground watcher, not assumed.
# -NegativeControl expects the COMP arm's slide to be stepped and MUST fail.
#
#   powershell -NoProfile -File test\win32\sidebar-transition-comp.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [switch]$NegativeControl,
    [switch]$Interactive
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:passes = 0
$tmp = Join-Path $env:TEMP "ghoztty-t2802-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ } else { "  FAIL $name"; $script:failures++ }
}
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 't2802')
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
# The LAST line matching $Pattern logged after line $Skip, waiting up to $Ms.
function Wait-Log([string]$Pattern, [int]$Skip, [int]$Ms = 4000) {
    $deadline = (Get-Date).AddMilliseconds($Ms)
    $hit = $null
    do {
        Start-Sleep -Milliseconds 150
        $hit = @(Get-Content $script:errlog -ErrorAction SilentlyContinue | Select-Object -Skip $Skip | Where-Object { $_ -match $Pattern }) | Select-Object -Last 1
    } while (-not $hit -and (Get-Date) -lt $deadline)
    return $hit
}
function Count-Log([string]$Pattern, [int]$Skip) {
    @(Get-Content $script:errlog -ErrorAction SilentlyContinue | Select-Object -Skip $Skip | Where-Object { $_ -match $Pattern }).Count
}
# The heads of a `pane sidebar outline` line, in client coordinates.
function Read-Heads([string]$Line) {
    $heads = @()
    if (-not $Line -or $Line -notmatch ' heads=(\S*)') { return $heads }
    foreach ($h in ($Matches[1] -split ';' | Where-Object { $_ })) {
        if ($h -match '^([PWU])(\d+)@(-?\d+),(-?\d+)$') { $heads += , @{ Kind = $Matches[1]; Group = [int]$Matches[2]; X = [int]$Matches[3]; Y = [int]$Matches[4] } }
    }
    return $heads
}
function ClickAt($top, $sb, $pt) {
    return Send-TestMouse -Window $top -Target ([IntPtr]$sb.Hwnd) -X ($sb.Left + $pt.X) -Y ($sb.Top + $pt.Y) -Action click
}
# The collapse/expand toggle and the all-windows toggle (T2289 header order;
# the same geometry pane-sidebar-all-windows.ps1 clicks).
function Get-ToggleCenter($sb) {
    $margin = Px 12; $card = Px 52; $tile = Px 28
    $inset = [int][math]::Truncate(($card - $tile) / 2)
    return @{ X = $margin + $inset + [int]($tile / 2); Y = $margin + $inset + [int]($tile / 2) }
}
function Get-ScopeCenter($sb) {
    return @{ X = $sb.Width - (Px 4) - [int]((Px 28) / 2); Y = (Get-ToggleCenter $sb).Y }
}

# One transition: run $Action, then read who moved it. Returns the start,
# the compositor hand-over, and the done line's verdict.
function Measure-Transition([string]$Kind, [scriptblock]$Action) {
    $mark = Get-LogCount
    & $Action
    $start = Wait-Log "pane sidebar transition $Kind surface=rail ms=\d+" $mark 2500
    $done = Wait-Log 'pane sidebar transition done surface=rail compositor=(true|false) ui_steps=(\d+)' $mark 2500
    $mover = $null
    if ($done -match 'compositor=(true|false) ui_steps=(\d+)') { $mover = "compositor=$($Matches[1]) ui_steps=$($Matches[2])" }
    return @{
        Started  = ($null -ne $start)
        OnComp   = ($null -ne (Wait-Log "pane sidebar transition $Kind on compositor layers=3 band=\d+x\d+ " $mark 200))
        Mover    = $mover
        Landed   = (Count-Log 'transition fold lands' $mark)
        Lost     = (Count-Log 'left the compositor' $mark)
        Failed   = (Count-Log 'could not go on the compositor' $mark)
    }
}

. (Join-Path $PSScriptRoot 'lib\Transcript.ps1')
$transcript = New-TestTranscript -Name 't2802'

Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$launched = @()
$script:reachedEnd = $false
$script:scale = 1.0
$knob = 'GHOZTTY_DEBUG_SIDEBAR_TRANSITION_STEPPED'

& {
try {
    Assert-GhozttyPrivateEndpoint -Exe $Exe
    foreach ($arm in @('comp', 'stepped')) {
    "==== arm: $arm"
    [void](Stop-RepoGhoztty -Exe $Exe -AppOnly -SettleMs 500)
    Remove-Item "env:$knob" -ErrorAction SilentlyContinue
    # Set by its literal name: seam-audit.ps1 finds a seam's arm by that spelling.
    if ($arm -eq 'stepped') { $env:GHOZTTY_DEBUG_SIDEBAR_TRANSITION_STEPPED = '1' }
    $script:errlog = Join-Path $tmp "app-stderr-$arm.log"
    $app = Start-OnTestDesktop -Exe $Exe -StdErr $script:errlog -Arguments @('--session-persistence=false', '--macos-pane-style=flat')
    Start-Sleep -Seconds 3
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { "  SETUP FAIL: top window not found"; $script:failures++; return }
    Assert "[$arm] window is NOT enumerable on the interactive desktop" (-not (Test-TestDesktopLeak -ProcessId $app.Pid))
    $dpi = Get-TestWindowDpi -Window $top
    if ($dpi -gt 0) { $script:scale = $dpi / 96.0 }
    [void](Set-TestWindowSize -Window $top -Width (Px 1100) -Height (Px 900))
    Start-Sleep -Milliseconds 600
    Assert "[$arm] setup: +split s1 exit 0 ($(Get-CliErr))" ((Invoke-Cli "+split --direction=right --name=s1") -eq 0)
    Start-Sleep -Milliseconds 1500
    $sb = Get-Sidebar $top
    Assert "[$arm] setup: the sidebar is on show" ($null -ne $sb -and $sb.Visible)
    if ($null -eq $sb -or -not $sb.Visible) { return }
    [void](ClickAt $top $sb (Get-ToggleCenter $sb))
    # T2290: expanded is the 240 DIP card in the rail's 12 DIP insets.
    $panelW = (Px 12) + (Px 240) + (Px 12)
    $deadline = (Get-Date).AddMilliseconds(3000)
    do {
        Start-Sleep -Milliseconds 150
        $sb = Get-Sidebar $top
    } while (($null -eq $sb -or [math]::Abs($sb.Width - $panelW) -gt 1) -and (Get-Date) -lt $deadline)
    $exp = ($null -ne $sb -and [math]::Abs($sb.Width - $panelW) -le 1)
    Assert "[$arm] setup: the sidebar expanded ($($sb.Width) vs $panelW)" $exp
    Start-Sleep -Milliseconds 500
    if (-not $exp) { return }

    "== the scope switch slides to all windows"
    $s1 = Measure-Transition 'scope' { [void](ClickAt $top $sb (Get-ScopeCenter $sb)) }
    Assert "[$arm] the switch slid (log)" $s1.Started
    Assert "[$arm] ...and landed on its own ($($s1.Mover))" ($null -ne $s1.Mover)
    if ($arm -eq 'comp') {
        $want = if ($NegativeControl) { 'compositor=false' } else { 'compositor=true ui_steps=0' }
        if ($NegativeControl) { "  NEGATIVE CONTROL: the comp arm's slide is expected stepped - this run MUST fail" }
        Assert "[comp] the slide was handed to the compositor whole (log)" $s1.OnComp
        Assert "[comp] ...and the UI thread composed none of its frames ($($s1.Mover))" ($s1.Mover -like "$want*")
        Assert "[comp] the tree was built for it (log)" ($null -ne (Wait-Log 'pane sidebar composition tree up for=list-transition adapter=(hardware|warp) build=1 ' 0 500))
        Assert "[comp] no hand-over failed and the tree was not lost ($($s1.Failed) failed, $($s1.Lost) lost)" ($s1.Failed -eq 0 -and $s1.Lost -eq 0)
    } else {
        Assert "[stepped] the knob kept it off the compositor (log)" ((-not $s1.OnComp) -and ($null -ne (Wait-Log 'pane sidebar transition scope stepped: the stepped knob is set' 0 300)))
        Assert "[stepped] ...and the UI thread composed its frames ($($s1.Mover))" ($s1.Mover -match '^compositor=false ui_steps=[1-9]\d*$')
    }
    Start-Sleep -Milliseconds 500

    "== this window's header folds its panes, and unfolds them"
    $heads = Read-Heads (Wait-Log 'pane sidebar outline mode=expanded .*heads=\S*W\d' 0 1500)
    $w = $heads | Where-Object { $_.Kind -eq 'W' } | Select-Object -First 1
    Assert "[$arm] setup: this window has a header in the all-windows list" ($null -ne $w)
    if ($null -eq $w) { return }
    foreach ($step in @('fold', 'unfold')) {
        $f = Measure-Transition 'fold' { [void](ClickAt $top $sb @{ X = $w.X; Y = $w.Y }) }
        Assert "[$arm] the $step animated (log)" $f.Started
        Assert "[$arm] ...and finished in place, not landing early ($($f.Mover), $($f.Landed) landed)" ($null -ne $f.Mover -and $f.Landed -eq 0)
        if ($arm -eq 'comp') {
            Assert "[comp] the $step went on the compositor whole, the UI thread composed none of it ($($f.Mover))" ($f.OnComp -and $f.Mover -eq 'compositor=true ui_steps=0')
        } else {
            Assert "[stepped] the $step was stepped on the UI thread ($($f.Mover))" ((-not $f.OnComp) -and $f.Mover -match '^compositor=false ui_steps=[1-9]\d*$')
        }
        Start-Sleep -Milliseconds 500
    }

    "== the switch back slides too"
    $s2 = Measure-Transition 'scope' { [void](ClickAt $top $sb (Get-ScopeCenter $sb)) }
    Assert "[$arm] the switch back slid and landed ($($s2.Mover))" ($s2.Started -and $null -ne $s2.Mover)
    if ($arm -eq 'comp') {
        Assert "[comp] ...on the compositor, with no UI-thread frame ($($s2.Mover))" ($s2.OnComp -and $s2.Mover -eq 'compositor=true ui_steps=0')
        Assert "[comp] one tree served every transition ($(Count-Log 'pane sidebar composition tree up' 0) built)" ((Count-Log 'pane sidebar composition tree up' 0) -eq 1)
    } else {
        Assert "[stepped] ...stepped ($($s2.Mover))" ($s2.Mover -match '^compositor=false ui_steps=[1-9]\d*$')
        Assert "[stepped] and no tree was ever built for it ($(Count-Log 'pane sidebar composition tree up' 0))" ((Count-Log 'pane sidebar composition tree up' 0) -eq 0)
    }

    Assert "[$arm] no crash" (-not ($app.Process -and $app.Process.HasExited))
    $launched += $script:GhozttyTestDesktopPids
    }
    $script:reachedEnd = $true
} catch {
    "  FAIL body threw: $($_.Exception.Message)"
    $script:failures++
} finally {
    Remove-Item "env:$knob" -ErrorAction SilentlyContinue
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
        update -Guard sidebar-transition-comp -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

""
exit (Complete-TestTranscript -Name 't2802' -Path $transcript `
        -Label 'T2802 ACCEPTANCE' -Pass $script:passes -Fail $script:failures).Code
