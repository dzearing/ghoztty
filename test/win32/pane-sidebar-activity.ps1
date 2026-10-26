#   5. A bell on a STASHED pane leaves a dot: s1 stashed, a BEL printed in
# T1843 acceptance: the pane sidebar's activity marks on Windows, as Mac
# draws them (PaneSidebarRow.swift `busySheen`, PaneSidebarAnimationLayers
# `PaneSidebarTileSheenLayer`; the row's accessories). Since T2280 (Mac
# 2924ea5cc) a question has NO mark in the sidebar at all - no row chip, no
# tile disc, no breathing ring. Since T2279 (Mac 75dc046e3, 919fba868) busy
# is a sheen across the row's pill, the same on a rail tile, and a progress
# report counts as busy.
#
# Layout: the first pane P, then `+split right --shell=powershell` -> s1 (a
# known shell, so section 5 can make it print a BEL). What it checks:
#
#   1. Busy sheens: `+set-state busy` on s1 starts the sidebar's motion
#      clock (log `motion on surface=rail busy=1`) and the rail really moves -
#      fourteen synchronous WM_PRINTCLIENT frames ~175 ms apart (more than
#      the sheen's 2s period) are not all the same picture. There is no busy
#      dot; the moving band IS the signal.
#   2. Idle again, the clock stops itself (log `motion off`) and the rail
#      holds still: consecutive frames are identical.
#   2b. A progress report alone (OSC 9;4;3 printed by s1's shell, the state
#      left idle) is work too, as it is what lights the pane's border: the
#      tally counts it busy, the rail moves, and 9;4;0 stops it again.
#   3. A question in the RAIL draws nothing: no clock starts, and the rail
#      is the SAME picture it was before the question - no corner disc.
#   4. A question in the expanded PANEL draws nothing either: no clock, no
#      chip, and the panel is the same picture with the question as without.
#   4b. A busy row in the expanded panel sheens the same way, and once it
#      is idle and faded out the panel is the quiet picture again.
#   5. A bell on a STASHED pane leaves a dot: s1 stashed, a BEL printed in
#      it, the tally says bell=1 and the panel picture changed. Then
#      `+restore --focus` looks at it - the bell clears on focus, as Mac's
#      does - and stashing it again brings no dot back.
#
# NOT covered here: the reduced-motion arm ("Animation effects" off). That
# switch is SPI_SETCLIENTAREAANIMATION, which is SYSTEM-WIDE - flipping it
# would change the user's own desktop under them. The gate is one call
# (`Marks.moving(motion)`), unit-tested in pane_sidebar_motion.zig.
#
# Runs on a BACKGROUND desktop (lib\TestDesktop.ps1) and never takes the
# user's foreground - asserted by the foreground watcher, not assumed.
# -NegativeControl expects the busy frames to be IDENTICAL and MUST fail.
#
#   powershell -NoProfile -File test\win32\pane-sidebar-activity.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [switch]$NegativeControl,
    [switch]$Interactive
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:passes = 0
$tmp = Join-Path $env:TEMP "ghoztty-t1843-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ } else { "  FAIL $name"; $script:failures++ }
}
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 't1843')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
Add-Type -AssemblyName System.Drawing

$Cli = [System.IO.Path]::ChangeExtension($Exe, '.com')
if (-not (Test-Path $Cli)) { $Cli = $Exe }

function Invoke-Cli([string]$CliArgs) {
    cmd /c "`"$Cli`" $CliArgs > `"$tmp\out.txt`" 2> `"$tmp\err.txt`"" | Out-Null
    return $LASTEXITCODE
}
function Get-CliErr { (Get-Content "$tmp\err.txt" -Raw -ErrorAction SilentlyContinue) }

function Get-Panes($top) { @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal') }
function Get-Sidebar($top) { @(Get-TestChildWindows -Window $top -Class 'GhozttyPaneSidebar') | Select-Object -First 1 }
function Px([double]$Dip) { [int][math]::Round($Dip * $script:scale) }

# The rail's pin, from pane_sidebar.zig's numbers (layoutMini), as
# pane-sidebar.ps1 computes it.
function Get-RailPinCenter($sb) {
    $margin = Px 12; $card = Px 52; $tile = Px 28
    $inset = [int][math]::Truncate(($card - $tile) / 2)
    return @{ X = $sb.Left + $margin + $inset + [int]($tile / 2); Y = $sb.Top + $margin + $inset + [int]($tile / 2) }
}

# One synchronous frame of the sidebar, as an MD5 of its pixels.
function Get-FrameHash($sb) {
    try {
        $shot = Get-TestWindowPixels -Window ([IntPtr]$sb.Hwnd) -Sync
        $ms = New-Object System.IO.MemoryStream
        $shot.Bitmap.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        Close-TestWindowPixels -Shot $shot
        $md5 = [System.Security.Cryptography.MD5]::Create()
        return [BitConverter]::ToString($md5.ComputeHash($ms.ToArray()))
    } catch {
        "  capture failed: $($_.Exception.Message)" | Out-Host
        return $null
    }
}
function Get-Frames($sb, [int]$Count = 8, [int]$GapMs = 175) {
    $out = @()
    for ($i = 0; $i -lt $Count; $i++) {
        $out += (Get-FrameHash $sb)
        Start-Sleep -Milliseconds $GapMs
    }
    return , $out
}
function Get-Distinct($frames) { @($frames | Where-Object { $_ } | Select-Object -Unique).Count }

# Log lines written after line $From, waiting up to $Ms for one matching $Pattern.
function Wait-Log([int]$From, [string]$Pattern, [int]$Ms = 4000) {
    $deadline = (Get-Date).AddMilliseconds($Ms)
    do {
        $hit = @(Get-Content $script:errlog -ErrorAction SilentlyContinue | Select-Object -Skip $From) |
            Where-Object { $_ -match $Pattern } | Select-Object -First 1
        if ($hit) { return $hit }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)
    return $null
}
function Get-LogCount { @(Get-Content $script:errlog -ErrorAction SilentlyContinue).Count }

. (Join-Path $PSScriptRoot 'lib\Transcript.ps1')
$transcript = New-TestTranscript -Name 't1843'

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
    # Wide enough for the pinned panel (>= 720 DIP) in section 4.
    [void](Set-TestWindowSize -Window $top -Width (Px 1100) -Height (Px 700))
    Start-Sleep -Milliseconds 600

    Assert "setup: +split s1 (powershell) exit 0 ($(Get-CliErr))" ((Invoke-Cli "+split --direction=right --name=s1 --shell=powershell") -eq 0)
    Start-Sleep -Milliseconds 1500
    Assert "setup: two visible panes" ((@(Get-Panes $top | Where-Object Visible)).Count -eq 2)
    $sb = Get-Sidebar $top
    Assert "setup: the rail is up" ($null -ne $sb -and $sb.Visible -and [math]::Abs($sb.Width - (Px 76)) -le 1)

    "== 1: a busy pane's tile sheens in the rail"
    $mark = Get-LogCount
    Assert "+set-state busy exit 0" ((Invoke-Cli "+set-state --target=s1 --state=busy") -eq 0)
    $tally = Wait-Log $mark 'pane sidebar marks busy=1 bell=0'
    "  $tally"
    Assert "the roster counts one busy pane (log)" ($null -ne $tally)
    $on = Wait-Log $mark 'pane sidebar motion on surface=rail busy=1'
    "  $on"
    Assert "the motion clock started for it (log)" ($null -ne $on)
    # T2279: the sheen sweeps for 0.8s of every 2s and rests off the pill
    # between, so the frames span more than one whole period.
    $frames = Get-Frames $sb 14 175
    $distinct = Get-Distinct $frames
    "  ($distinct distinct of $($frames.Count) frames)"
    if ($NegativeControl) {
        Assert "NEGATIVE CONTROL: the busy rail holds still" ($distinct -le 1)
    } else {
        Assert "the rail moves while busy ($distinct distinct frames, want >= 3)" ($distinct -ge 3)
    }

    "== 2: idle again, the clock stops and the rail holds still"
    $mark = Get-LogCount
    Assert "+set-state idle exit 0" ((Invoke-Cli "+set-state --target=s1 --state=idle") -eq 0)
    $off = Wait-Log $mark 'pane sidebar motion off surface=rail'
    "  $off"
    Assert "the motion clock stopped itself (log)" ($null -ne $off)
    $frames = Get-Frames $sb 4 200
    Assert "an idle rail is one picture ($(Get-Distinct $frames) distinct)" ((Get-Distinct $frames) -eq 1)

    "== 2b: a progress report alone is work too - the tile sheens while it lights the border (T2279)"
    # Mac 919fba868: busy is the activity state OR a progress report on
    # screen (OSC 9;4), what animates the pane's border. s1 stays idle; only
    # the program inside it reports progress.
    $osc = Join-Path $tmp 'osc-on.txt'
    [System.IO.File]::WriteAllText($osc, "[Console]::Out.Write([char]27 + ']9;4;3;' + [char]7)")
    $mark = Get-LogCount
    Assert "+send-keys (OSC 9;4;3 from s1's shell) exit 0 ($(Get-CliErr))" ((Invoke-Cli "+send-keys --target=s1 `"--keys-file=$osc`" Enter") -eq 0)
    $tally = Wait-Log $mark 'pane sidebar marks busy=1 bell=0' 6000
    "  $tally"
    Assert "a report in force counts the pane busy (log)" ($null -ne $tally)
    Assert "the motion clock started for it (log)" ($null -ne (Wait-Log $mark 'pane sidebar motion on surface=rail busy=1'))
    $frames = Get-Frames $sb 14 175
    Assert "the rail moves while the report is in force ($(Get-Distinct $frames) distinct, want >= 3)" ((Get-Distinct $frames) -ge 3)
    $off = Join-Path $tmp 'osc-off.txt'
    [System.IO.File]::WriteAllText($off, "[Console]::Out.Write([char]27 + ']9;4;0;' + [char]7)")
    $mark = Get-LogCount
    Assert "+send-keys (OSC 9;4;0) exit 0 ($(Get-CliErr))" ((Invoke-Cli "+send-keys --target=s1 `"--keys-file=$off`" Enter") -eq 0)
    Assert "the report removed, the pane is not busy (log)" ($null -ne (Wait-Log $mark 'pane sidebar marks busy=0 bell=0' 6000))
    Assert "and the clock stopped itself (log)" ($null -ne (Wait-Log $mark 'pane sidebar motion off surface=rail' 6000))
    Start-Sleep -Milliseconds 400
    # Any paints the shell's own echo caused are over by now.
    $frames = Get-Frames $sb 4 200
    Assert "the rail holds still again ($(Get-Distinct $frames) distinct)" ((Get-Distinct $frames) -eq 1)

    "== 3: a question in the rail draws nothing (T2280)"
    $before = Get-FrameHash $sb
    $mark = Get-LogCount
    Assert "+set-state needs_input exit 0" ((Invoke-Cli "+set-state --target=s1 --state=needs_input") -eq 0)
    Start-Sleep -Milliseconds 800
    $frames = Get-Frames $sb 4 300
    $started = Wait-Log $mark 'pane sidebar motion on' 200
    Assert "no clock for a question" ($null -eq $started)
    Assert "the rail holds still ($(Get-Distinct $frames) distinct)" ((Get-Distinct $frames) -eq 1)
    Assert "the rail is the same picture it was before the question (no corner disc)" ($null -ne $before -and $frames[0] -eq $before)

    "== 4: in the expanded panel a question draws nothing either"
    [void](Send-TestMouse -Window $top -Target ([IntPtr]$sb.Hwnd) -X (Get-RailPinCenter $sb).X -Y (Get-RailPinCenter $sb).Y -Action click)
    Start-Sleep -Milliseconds 700
    $sb = Get-Sidebar $top
    # T2290: the rail's card at 240 DIP, in the rail's 12 DIP insets (flat).
    $panelW = (Px 12) + (Px 240) + (Px 12)
    Assert "expanded: the 240 DIP card in its insets ($($sb.Width) vs $panelW)" ([math]::Abs($sb.Width - $panelW) -le 1)
    $mark = Get-LogCount
    $asking = Get-Frames $sb 4 300
    Assert "no clock while it asks (log)" ($null -eq (Wait-Log $mark 'pane sidebar motion on' 200))
    Assert "the panel holds still while it asks ($(Get-Distinct $asking) distinct)" ((Get-Distinct $asking) -eq 1)
    Assert "no question chip was painted (log)" ($null -eq (Wait-Log 0 'pane sidebar question chip' 100))
    [void](Invoke-Cli "+set-state --target=s1 --state=idle")
    Start-Sleep -Milliseconds 800
    $quiet = Get-FrameHash $sb
    if ($NegativeControl) {
        Assert "NEGATIVE CONTROL: the question changed the panel" ($asking[0] -ne $quiet)
    } else {
        Assert "the panel is the same picture with the question as without" ($null -ne $quiet -and $asking[0] -eq $quiet)
    }

    "== 4b: the same sheen crosses a busy row in the expanded panel (T2279)"
    $mark = Get-LogCount
    Assert "+set-state busy exit 0" ((Invoke-Cli "+set-state --target=s1 --state=busy") -eq 0)
    Assert "the panel's motion clock started (log)" ($null -ne (Wait-Log $mark 'pane sidebar motion on surface=rail busy=1'))
    $frames = Get-Frames $sb 14 175
    Assert "the busy row moves in the panel ($(Get-Distinct $frames) distinct, want >= 3)" ((Get-Distinct $frames) -ge 3)
    $mark = Get-LogCount
    [void](Invoke-Cli "+set-state --target=s1 --state=idle")
    Assert "idle, the panel's clock stopped (log)" ($null -ne (Wait-Log $mark 'pane sidebar motion off surface=rail'))
    Start-Sleep -Milliseconds 300
    $after = Get-FrameHash $sb
    Assert "faded out, the row is the quiet picture again" ($null -ne $after -and $after -eq $quiet)

    "== 5: a bell on a stashed pane leaves a dot until the pane is looked at"
    Assert "+stash s1 exit 0 ($(Get-CliErr))" ((Invoke-Cli "+stash --target=s1") -eq 0)
    Start-Sleep -Milliseconds 600
    $before = Get-FrameHash $sb
    $mark = Get-LogCount
    $bell = $null
    for ($try = 0; $try -lt 4 -and -not $bell; $try++) {
        [void](Invoke-Cli "+send-keys --target=s1 `"[char]7`" Enter")
        $bell = Wait-Log $mark 'pane sidebar marks busy=0 bell=1' 2500
    }
    "  $bell"
    Assert "the BEL left a bell mark on the stashed row (log)" ($null -ne $bell)
    Start-Sleep -Milliseconds 300
    $after = Get-FrameHash $sb
    Assert "the panel picture changed when the dot appeared" ($null -ne $before -and $null -ne $after -and $before -ne $after)
    $frames = Get-Frames $sb 3 200
    Assert "a bell dot holds still ($(Get-Distinct $frames) distinct)" ((Get-Distinct $frames) -eq 1)

    $mark = Get-LogCount
    Assert "+restore --focus s1 exit 0 ($(Get-CliErr))" ((Invoke-Cli "+restore --target=s1 --focus") -eq 0)
    Assert "restored, the row is no longer a stashed one (bell=0 in the tally)" ($null -ne (Wait-Log $mark 'bell=0'))
    Start-Sleep -Milliseconds 500
    $mark = Get-LogCount
    Assert "+stash s1 again exit 0" ((Invoke-Cli "+stash --target=s1") -eq 0)
    $again = Wait-Log $mark 'bell=1' 1500
    Assert "looked at, its bell cleared: stashed again, no dot ($again)" ($null -eq $again)

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
        update -Guard pane-sidebar-activity -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

""
exit (Complete-TestTranscript -Name 't1843' -Path $transcript `
        -Label 'T1843 ACCEPTANCE' -Pass $script:passes -Fail $script:failures).Code
