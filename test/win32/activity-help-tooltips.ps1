# The Activity Monitor control bar's HOVER HELP (tracker T1634).
#
# WHAT CHANGED. Mac's Activity Monitor puts `.help()` text on the control-bar
# rows a reader is most likely to mistrust - the "List truncated" badge, the
# "Show all" filter and the process count - and on the Kill / New Process
# buttons beside them. The win32 panel said none of it, so a filtered count and
# a truncated table read as plain facts. The panel now carries Mac's words on
# ONE native comctl32 tooltip (help_tooltip.zig, shared with the machine
# chooser):
#
#   painted on the panel (a track tool the panel places by hand)
#     - the count      "Showing N Ghoztty-spawned of M total processes." while
#                      the spawned-only filter is on, else "N processes"
#     - the badge      "The agent capped the process table; some rows are not
#                      shown." (unit-tested in activity_help.zig: a local table
#                      never reaches the 512-row cap, so this run can only show
#                      that an ABSENT badge says nothing - section E)
#   real child controls (a subclass tool comctl32 shows itself)
#     - Show all       "When off, show only processes Ghoztty started (the
#                      agent and its descendants)."
#     - New Process    "Start a new process on Local"
#     - Kill           "Terminate <name>" for one row, "Terminate N selected
#                      processes" for several
#
# WHAT IS ASSERTED
#   A  setup: a Local panel opens with its controls
#   B  the count, hovered, derives its tip with Mac's words - the spawned-only
#      sentence first, then the plain count once Show all is on; and a hover
#      whose show delay is allowed to elapse SHOWS it
#   C  each control, entered, derives its tip; Kill's words follow the selection
#      (one row named, two rows counted)
#   D  the one tooltip control carries a tool per control it explained: the
#      track tool plus Show all, New Process and Kill
#   E  NEGATIVE CONTROLS. Leaving a surface for nothing DROPS its tip (scored on
#      order), and points with no help derive nothing: the empty badge slot
#      beside the checkbox, and the empty band under the table's rows. Without
#      E, B would pass equally well against a tip that fires anywhere on the
#      control bar.
#   F  THE PROCESS TABLE'S CELLS (T1548; Mac :1082-1142). Walking across one
#      row, only Name, Window / Pane and Path answer, in that order, and the
#      %CPU / Memory columns between them say nothing. Path says the whole
#      path; Name says the full command (the same string, for one PID); Window
#      / Pane says the pane's detail - Mac's Window / Pane / Pane position /
#      Directory lines, with "Shell PID:" where Mac says "TTY:". The next row
#      down is a new tip with its own PID; the pane tip, allowed its delay, is
#      SHOWN; and with Show all on, a row no pane started says "Not started by
#      a Ghoztty pane." Cell lines carry `pid=<n>` and write the detail's
#      newlines as a literal \n.
#
# WHY A LOG LINE IS AN ORACLE. Hover TIMING cannot be observed on the background
# test desktop: no real cursor rests anywhere, so TrackMouseEvent posts a leave
# within a frame of every posted move (T233). The app says what it derived at
# HOVER time (`activity help tooltip target=<kind> text=<text>`), and this
# script scores the words. B's "shown" check posts the move and the delay's
# timer back to back (Send-TestRawMessagePair, T1417) so the leave cannot land
# between them, and retries because that narrows the race rather than closing
# it.
#
# WHERE THE COUNT IS. Found, not derived (the T257 lesson): the count's words are
# right-aligned just left of New Process, so the script walks leftwards from
# that button's edge along the checkbox's row until the app says the pointer is
# on the count.
#
# Isolation: the IPC endpoint is keyed on $PID and persistence is off (T248).
# T211/T217: runs on a BACKGROUND desktop and never takes the user's foreground.
# Nothing here ever presses Kill - it is only hovered.
#
#   powershell -NoProfile -File test\win32\activity-help-tooltips.ps1
#
# Only touches ghoztty processes running from this repo's zig-out.
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    # T2074 negative control: plant a probe that DOES derive a tip into E, which
    # must then go red. Never stamps (the run is red by construction).
    [switch]$PlantTooltip
)

# T351: the shared reset/kill helpers. Dot-sourced HERE, ahead of any isolation
# setup, because it drops an inherited $GHOZTTY_IPC_SOCKET.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not (Test-Path $Exe)) { $Exe = Join-Path $repo 'zig-out\bin\ghoztty.exe' }

$env:GHOZTTY_PIPE_SUFFIX = "-t1634$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')

$WM_MOUSEMOVE = 0x0200
$WM_SETCURSOR = 0x0020
$WM_TIMER = 0x0113
$WM_LBUTTONDOWN = 0x0201
$WM_LBUTTONUP = 0x0202
$MK_LBUTTON = 0x0001
$MK_CONTROL = 0x0008
$HTCLIENT = 1
$TTM_GETTOOLCOUNT = 0x040D   # WM_USER + 13
$HELP_TIMER_ID = 2           # activity_hover.TIMER_ID

$script:pass = 0
$script:fail = 0
$script:skipped = 0
function Assert($cond, $name) {
    if ($cond) { Write-Host "  PASS $name"; $script:pass++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:fail++ }
}
function Skip($name) {
    Write-Host "  SKIP $name" -ForegroundColor Yellow
    $script:skipped++
}

$tmp = Join-Path $env:TEMP "ghoztty-t1634-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null
$errlog = Join-Path $tmp 'stderr.log'

function Get-LastLineNo($pattern) {
    if (-not (Test-Path $errlog)) { return 0 }
    $m = @(Select-String -Path $errlog -Pattern $pattern -ErrorAction SilentlyContinue)
    if ($m.Count -eq 0) { return 0 }
    return $m[-1].LineNumber
}

function Wait-LogCount($pattern, $want, $timeoutMs) {
    $waited = 0
    while ($waited -lt $timeoutMs) {
        if (Test-Path $errlog) {
            if (@(Select-String -Path $errlog -Pattern $pattern -ErrorAction SilentlyContinue).Count -ge $want) { return $true }
        }
        Start-Sleep -Milliseconds 250
        $waited += 250
    }
    return $false
}

# The text of the NEWEST help line for $target, waiting for one newer than line
# $afterLine. $null when none arrives.
function Wait-HelpText($target, $afterLine, $timeoutMs = 6000) {
    $pattern = "activity help tooltip target=$target text=(.*)$"
    $waited = 0
    while ($waited -lt $timeoutMs) {
        if (Test-Path $errlog) {
            $m = @(Select-String -Path $errlog -Pattern $pattern -Encoding UTF8 -ErrorAction SilentlyContinue)
            if ($m.Count -gt 0 -and $m[-1].LineNumber -gt $afterLine) {
                if ($m[-1].Line -match $pattern) { return $Matches[1] }
            }
        }
        Start-Sleep -Milliseconds 250
        $waited += 250
    }
    return $null
}

# After the pointer left $target: the last "dropped" line for it is newer than
# the last hover line for it.
function Wait-HelpDropped($target, $timeoutMs = 6000) {
    $dropAt = 0
    $hoverAt = 0
    $waited = 0
    while ($waited -lt $timeoutMs) {
        $dropAt = Get-LastLineNo "activity help tooltip dropped target=$target$"
        $hoverAt = Get-LastLineNo "activity help tooltip target=$target text="
        if ($hoverAt -gt 0 -and $dropAt -gt $hoverAt) { return $true }
        Start-Sleep -Milliseconds 250
        $waited += 250
    }
    Write-Host "    (drop at line $dropAt, last hover at line $hoverAt)"
    return $false
}

function Pack-Point([int]$x, [int]$y) {
    return [IntPtr]((($y -band 0xFFFF) -shl 16) -bor ($x -band 0xFFFF))
}

function Move-Pointer([IntPtr]$window, [int]$x, [int]$y, [int]$settleMs = 300) {
    [void](Send-TestRawMessage -Window $window -Message $WM_MOUSEMOVE -LParam (Pack-Point $x $y))
    Start-Sleep -Milliseconds $settleMs
}

# Enter a real child control: WM_SETCURSOR at the control, naming itself. Its
# DefWindowProc forwards the message to the panel - the real pointer's path.
function Enter-Control($ctl) {
    $h = [IntPtr]$ctl.Hwnd
    $lp = [IntPtr](($WM_MOUSEMOVE -shl 16) -bor $HTCLIENT)
    [void](Send-TestRawMessage -Window $h -Message $WM_SETCURSOR -WParam $h -LParam $lp)
    Start-Sleep -Milliseconds 300
}

# The panel names ITSELF in WM_SETCURSOR when the pointer leaves a child.
function Leave-ToPanel([IntPtr]$panel) {
    $lp = [IntPtr](($WM_MOUSEMOVE -shl 16) -bor $HTCLIENT)
    [void](Send-TestRawMessage -Window $panel -Message $WM_SETCURSOR -WParam $panel -LParam $lp)
    Start-Sleep -Milliseconds 300
}

function Click-Posted([IntPtr]$panel, [int]$x, [int]$y, [int]$mods) {
    [void](Send-TestRawMessage -Window $panel -Message $WM_LBUTTONDOWN -WParam ([IntPtr]($MK_LBUTTON -bor $mods)) -LParam (Pack-Point $x $y))
    [void](Send-TestRawMessage -Window $panel -Message $WM_LBUTTONUP -WParam ([IntPtr]$mods) -LParam (Pack-Point $x $y))
    Start-Sleep -Milliseconds 500
}

function Get-PanelState {
    if (-not (Test-Path $errlog)) { return $null }
    $pat = 'activity monitor: source=(\S+) total=(\d+) shown=(\d+) needle="([^"]*)" show_all=(\w+) sort=(\w+)/(\w+) selected=(\d+)'
    $m = @(Select-String -Path $errlog -Pattern $pat) | Select-Object -Last 1
    if (-not $m) { return $null }
    $g = $m.Matches[0].Groups
    return [pscustomobject]@{ Total = [int]$g[2].Value; Shown = [int]$g[3].Value; ShowAll = ($g[5].Value -eq 'true'); Selected = [int]$g[8].Value }
}

function Wait-Selected([int]$want, [int]$timeoutMs = 6000) {
    $waited = 0
    while ($waited -lt $timeoutMs) {
        $st = Get-PanelState
        if ($st -and $st.Selected -eq $want) { return $true }
        Start-Sleep -Milliseconds 250
        $waited += 250
    }
    return $false
}

Write-Host 'T1634 Activity Monitor control-bar hover help'
Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null
New-TestDesktop | Out-Null

try {
    # --- A: the fixture ----------------------------------------------------
    Write-Host ''
    Write-Host '1. a Local Activity Monitor panel'
    [void](Reset-GhozttyTestState -Exe $Exe -SettleMs 500)
    $app = Start-OnTestDesktop -Exe $Exe -Arguments @('--session-persistence=false') -StdErr $errlog
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) {
        Write-TestAssertedNothing -Reason 'the GUI died at launch' -Skipped $script:skipped
    }
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { Write-TestAssertedNothing -Reason 'no GhozttyWindow' -Skipped $script:skipped }
    $surface = Get-TestChildWindow -Window $top -Class 'GhozttyTerminal'

    $panel = [IntPtr]::Zero
    foreach ($try in 1..3) {
        if (Send-TestKeys -Window $top -Target $surface -Modifiers ctrl, shift -Key P) {
            $popup = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyCommandPalette' -TimeoutMs 5000
            if ($popup -ne [IntPtr]::Zero) {
                $edit = Find-TestWindowEx -Parent $popup -Class 'EDIT'
                if ($edit -ne [IntPtr]::Zero) {
                    Send-TestControlText -Control $edit -Text 'ACTIVITY MONITOR' | Out-Null
                    [void](Send-TestControlKey -Control $edit -Key Enter)
                    $panel = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyActivityMonitor' -TimeoutMs 8000
                }
            }
        }
        if ($panel -ne [IntPtr]::Zero) { break }
        Start-Sleep -Milliseconds 500
    }
    Assert ($panel -ne [IntPtr]::Zero) 'A the palette opens a GhozttyActivityMonitor panel'
    if ($panel -eq [IntPtr]::Zero) { Write-TestAssertedNothing -Reason 'no Activity Monitor panel' -Skipped $script:skipped }

    Assert (Wait-LogCount 'activity monitor: source=Local total=' 1 10000) 'A the panel logged its first table state'
    $buttons = @(Get-TestChildWindows -Window $panel -Class 'Button')
    $showAll = $buttons | Where-Object { (Get-TestControlText -Control ([IntPtr]$_.Hwnd)) -eq 'Show all' } | Select-Object -First 1
    $newProc = $buttons | Where-Object { (Get-TestControlText -Control ([IntPtr]$_.Hwnd)) -like 'New Process*' } | Select-Object -First 1
    $kill = $buttons | Where-Object { (Get-TestControlText -Control ([IntPtr]$_.Hwnd)) -like 'Kill*' } | Select-Object -First 1
    Assert ($null -ne $showAll) 'A the Show all checkbox exists'
    Assert ($null -ne $newProc) 'A the New Process button exists'
    Assert ($null -ne $kill) 'A the Kill button exists (hidden until a row is selected)'
    if (-not ($showAll -and $newProc -and $kill)) { Write-TestAssertedNothing -Reason 'control bar incomplete' -Skipped $script:skipped }

    # T2074: SETTLE before E. E is the script's first hover, so nothing this
    # script did can still be in flight when it starts (the 2026-10-18 red was
    # first blamed on a late line from an earlier hover; there is none). What
    # CAN still move is the panel itself: its layout settling after the palette
    # closes (a probe placed from a stale rect lands on the count or a row), and
    # a move Windows synthesizes as the panel appears. Under a four-wide sweep
    # both arrive late. So: re-read the geometry until two reads 500 ms apart
    # agree, then wait for the tooltip log to go quiet, and only then probe.
    $geoKey = ''
    $geoWaited = 0
    while ($true) {
        $client = Get-TestWindowRect -Window $panel -Client
        $sa = Get-TestWindowRect -Window ([IntPtr]$showAll.Hwnd)
        $np = Get-TestWindowRect -Window ([IntPtr]$newProc.Hwnd)
        $key = "$($client.Left),$($client.Top),$($client.Width),$($client.Height)|$($sa.Left),$($sa.Top),$($sa.Right),$($sa.Bottom)|$($np.Left),$($np.Top)"
        if ($key -eq $geoKey -or $geoWaited -ge 8000) { break }
        $geoKey = $key
        Start-Sleep -Milliseconds 500
        $geoWaited += 500
    }
    $rowY = [int](($sa.Top + $sa.Bottom) / 2) - $client.Top
    $saRight = $sa.Right - $client.Left
    $npLeft = $np.Left - $client.Left

    # Quiet: no tooltip line of any kind for a full second (capped at 8 s).
    $quietWaited = 0
    $lastSeen = Get-LastLineNo 'activity help tooltip'
    $quietFor = 0
    while ($quietFor -lt 1000 -and $quietWaited -lt 8000) {
        Start-Sleep -Milliseconds 250
        $quietWaited += 250
        $now = Get-LastLineNo 'activity help tooltip'
        if ($now -ne $lastSeen) { $lastSeen = $now; $quietFor = 0 } else { $quietFor += 250 }
    }

    # --- E: the empty badge slot and the table say nothing -----------------
    Write-Host ''
    Write-Host '2. points with no help derive nothing'
    # Each probe is scored on its OWN window, and a red names the probe, the
    # point and the target the app derived - so a future red says what it saw
    # instead of a bare count (the 2026-10-18 red could not be diagnosed).
    $strays = New-Object System.Collections.Generic.List[string]
    function Test-NoHelpAt([string]$probe, [int]$x, [int]$y, [int]$settleMs = 300) {
        $b = Get-LastLineNo 'activity help tooltip target='
        Move-Pointer $panel $x $y $settleMs
        @(Select-String -Path $errlog -Pattern 'activity help tooltip target=(\S+)' -ErrorAction SilentlyContinue) |
            Where-Object { $_.LineNumber -gt $b } |
            ForEach-Object { $strays.Add("$probe at ($x,$y): $($_.Line -replace '^.*activity help tooltip ','')") }
    }
    # Just right of the checkbox is the badge slot, empty on a local table.
    Test-NoHelpAt 'badge slot' ($saRight + 6) $rowY
    Test-NoHelpAt 'badge slot' ($saRight + 20) $rowY
    if ($PlantTooltip) {
        # Negative control: a probe that DOES derive a tip (the count's words,
        # found by walking left from New Process as B does) must turn E red.
        for ($x = $npLeft - 2; $x -gt $saRight + 20; $x -= 3) {
            $n = $strays.Count
            Test-NoHelpAt 'PLANTED count' $x $rowY 60
            if ($strays.Count -gt $n) { break }
        }
    }
    # The table, well below the control bar, in the empty band under its rows.
    Test-NoHelpAt 'empty table band' ([int]($client.Width / 2)) ([int]($client.Height * 3 / 4)) 800
    # T2078: the badge slot is empty only while the table FITS. Beside other
    # workers the box's process count can cross the 512-row cap between the
    # panel's refreshes, and then the badge is really there and its tip is
    # correct. Decide from the panel's own state lines (one per refresh, so they
    # cover the probes): a badge tip while any of them said truncated=true is
    # the premise failing, not the control, and is SKIPPED loudly. Every other
    # stray - and every badge tip on a table that never truncated - still fails.
    $truncatedSeen = [bool](Select-String -Path $errlog -Pattern 'activity monitor: source=Local .*truncated=true' -Quiet -ErrorAction SilentlyContinue)
    if ($truncatedSeen) {
        $badgeStrays = @($strays | Where-Object { $_ -match ': target=badge ' })
        foreach ($s in $badgeStrays) { [void]$strays.Remove($s); Write-Host "    (E excused, table truncated for real: $s)" }
        if ($badgeStrays.Count -gt 0) {
            Skip 'E the badge slot: this box crossed the 512-process cap during the probes, so the badge was really shown - no negative control for the slot here'
        }
    }
    foreach ($s in $strays) { Write-Host "    (E derived: $s)" }
    Assert ($strays.Count -eq 0) `
        "E the empty badge slot and the table derive no tooltip (client=$($client.Width)x$($client.Height) rowY=$rowY saRight=$saRight; settle $geoWaited ms, quiet after $quietWaited ms)"
    if ($PlantTooltip) {
        Write-Host ''
        Write-Host "PLANT: E scored $($strays.Count) derived line(s) with a real tooltip planted - it must be red"
    }

    # --- F: the process table's cells (T1548) ------------------------------
    Write-Host ''
    Write-Host '2b. the table''s Name, Window / Pane and Path cells explain themselves'
    # Find the first row: walk DOWN the Name column (about a quarter of the way
    # across at the default widths: PID 60, Name 200 of 700 DIP) until the app
    # says the pointer is on a name cell. Found, not derived (T257).
    $nameX = [int]($client.Width / 4)
    $cellY = -1
    $before = Get-LastLineNo 'activity help tooltip target='
    for ($y = $rowY + 8; $y -lt $client.Height - 4; $y += 4) {
        Move-Pointer $panel $nameX $y 60
        if ((Get-LastLineNo 'activity help tooltip target=name pid=') -gt $before) { $cellY = $y + 4; break }
    }
    Assert ($cellY -ge 0) "F walking down the Name column finds a row (y=$cellY)"

    # Walk ACROSS that row, recording which cell each x answers as. Only the
    # columns Mac gives a .help() may answer: name, pane, path - never PID,
    # Memory or %CPU, so the walk must also cross x that answer nothing.
    # The table sorts by %CPU, so a refresh mid-walk can move rows: everything
    # compared across cells is keyed on the PID each line names.
    $seen = New-Object System.Collections.ArrayList
    $texts = @{}
    $pids = @{}
    $byPid = @{}
    $silentAfterName = $false
    $lastNo = Get-LastLineNo 'activity help tooltip target='
    for ($x = 2; $x -lt $client.Width - 2; $x += 6) {
        # Off the table between steps, so every x is a fresh hover.
        Move-Pointer $panel $x ($rowY + 2) 30
        $lastNo = Get-LastLineNo 'activity help tooltip target='
        Move-Pointer $panel $x $cellY 60
        $no = Get-LastLineNo 'activity help tooltip target='
        if ($no -le $lastNo) {
            if ($seen.Count -gt 0 -and $seen[-1] -eq 'name') { $silentAfterName = $true }
            continue
        }
        $line = (Get-Content $errlog -Encoding UTF8 -TotalCount $no)[-1]
        if ($line -match 'activity help tooltip target=(\w+) pid=(\d+) text=(.*)$') {
            $k = $Matches[1]
            if ($seen.Count -eq 0 -or $seen[-1] -ne $k) { [void]$seen.Add($k) }
            $texts[$k] = $Matches[3]
            $pids[$k] = $Matches[2]
            $byPid["$k|$($Matches[2])"] = $Matches[3]
        } elseif ($line -match 'activity help tooltip target=(\S+) text=') {
            [void]$seen.Add("other:$($Matches[1])")
        }
    }
    Assert (($seen -join ',') -ceq 'name,pane,path') "F across one row the cells answer in column order name, pane, path (got '$($seen -join ',')')"
    Assert $silentAfterName 'F the %CPU and Memory columns between Name and Window / Pane answer nothing'
    Assert ($texts['path'] -match '^[A-Za-z]:\\.+\.exe$') "F the Path cell says the whole path (got '$($texts['path'])')"
    $pathPid = $pids['path']
    $nameSame = $byPid["name|$pathPid"]
    if ($null -eq $nameSame) {
        # The row the walk ended on moved before its Name cell was crossed:
        # re-hover that row's Name cell is not possible without its y, so
        # compare the newest pair the walk DID see for one PID.
        foreach ($key in @($byPid.Keys)) {
            if ($key -like 'name|*') {
                $p = $key.Substring(5)
                if ($byPid.ContainsKey("path|$p")) { $pathPid = $p; $nameSame = $byPid[$key]; break }
            }
        }
    }
    Assert (($null -ne $nameSame) -and ($nameSame -ceq $byPid["path|$pathPid"])) `
        "F the Name cell says the full command, as Mac's does (pid $pathPid, got '$nameSame')"
    # Find the Window / Pane column's x on that row.
    $paneX = -1
    for ($x = 2; $x -lt $client.Width - 2; $x += 6) {
        Move-Pointer $panel $x ($rowY + 2) 20
        $b = Get-LastLineNo 'activity help tooltip target=pane pid='
        Move-Pointer $panel $x $cellY 40
        if ((Get-LastLineNo 'activity help tooltip target=pane pid=') -gt $b) { $paneX = $x + 6; break }
    }

    # Walk DOWN that column, one hover per step. The spawned-only table holds
    # this app and its pane's processes: the app's own row is no pane's ("Not
    # started by..."), while the shell under it is attributed and says Mac's
    # detail lines, with Shell PID where Mac says TTY. Each row is a NEW
    # surface: moving down the column re-hovers with that row's PID.
    $paneTexts = @{}
    Move-Pointer $panel $paneX ($rowY + 2) 60
    for ($y = $cellY - 4; $y -lt [Math]::Min($client.Height - 4, $cellY + 240); $y += 4) {
        $b = Get-LastLineNo 'activity help tooltip target=pane pid='
        Move-Pointer $panel $paneX $y 60
        $no = Get-LastLineNo 'activity help tooltip target=pane pid='
        if ($no -le $b) { continue }
        $line = (Get-Content $errlog -Encoding UTF8 -TotalCount $no)[-1]
        if ($line -match 'target=pane pid=(\d+) text=(.*)$') { $paneTexts[$Matches[1]] = $Matches[2] }
    }
    Assert ($paneTexts.Count -ge 2) "F moving down the Window / Pane column is a new tip per row ($($paneTexts.Count) PIDs: $(@($paneTexts.Keys) -join ','))"
    $detail = @($paneTexts.Values | Where-Object { $_ -cmatch '^Window: .+?(\\n(Tab|Pane|Pane position|Directory): .+?)*\\nShell PID: \d+$' }) | Select-Object -First 1
    Assert ($null -ne $detail) "F an attributed row's Window / Pane cell says the pane's detail (got '$detail')"
    if ($detail -match 'Shell PID: (\d+)$') {
        Assert ($paneTexts.ContainsKey($Matches[1])) "F the detail's Shell PID is a row in the table, attributed to its own pane ($($Matches[1]))"
    }

    # The pane tip, allowed its show delay, is SHOWN.
    $shown = $false
    foreach ($try in 1..6) {
        Move-Pointer $panel $paneX ($rowY + 2) 150
        $beforeShown = Get-LastLineNo 'activity help tooltip shown target=pane'
        [void](Send-TestRawMessagePair -Window $panel `
            -Message1 $WM_MOUSEMOVE -LParam1 (Pack-Point $paneX $cellY) `
            -Message2 $WM_TIMER -WParam2 ([IntPtr]$HELP_TIMER_ID))
        Start-Sleep -Milliseconds 400
        if ((Get-LastLineNo 'activity help tooltip shown target=pane') -gt $beforeShown) { $shown = $true; break }
    }
    Assert $shown "F a Window / Pane hover whose delay elapses SHOWS the tip (x=$paneX)"
    Move-Pointer $panel ([int]($client.Width / 2)) ([int]($client.Height * 3 / 4))
    Move-Pointer $panel $saRight $rowY

    # --- B: the count -------------------------------------------------------
    Write-Host ''
    Write-Host '3. the count explains itself'
    $before = Get-LastLineNo 'activity help tooltip target='
    $countX = -1
    for ($x = $npLeft - 2; $x -gt $saRight; $x -= 3) {
        Move-Pointer $panel $x $rowY 60
        if ((Get-LastLineNo 'activity help tooltip target=count text=') -gt $before) { $countX = $x; break }
    }
    Assert ($countX -ge 0) "B walking left from New Process finds the count's words (x=$countX)"
    $got = Wait-HelpText 'count' $before
    Assert ($got -cmatch '^Showing \d+ Ghoztty-spawned of \d+ total processes\.$') `
        "B the spawned-only count says Mac's sentence (got '$got')"

    # Its show delay, allowed to elapse: the tip is SHOWN.
    $shown = $false
    foreach ($try in 1..6) {
        $beforeShown = Get-LastLineNo 'activity help tooltip shown target=count'
        [void](Send-TestRawMessagePair -Window $panel `
            -Message1 $WM_MOUSEMOVE -LParam1 (Pack-Point $countX $rowY) `
            -Message2 $WM_TIMER -WParam2 ([IntPtr]$HELP_TIMER_ID))
        Start-Sleep -Milliseconds 400
        if ((Get-LastLineNo 'activity help tooltip shown target=count') -gt $beforeShown) { $shown = $true; break }
        # Off and back on, so the next pair is a fresh hover.
        Move-Pointer $panel ([int]($client.Width / 2)) ([int]($client.Height * 3 / 4)) 150
    }
    Assert $shown 'B a count hover whose delay elapses SHOWS the tip'

    # Off the count onto the table: dropped.
    Move-Pointer $panel $countX $rowY
    Move-Pointer $panel ([int]($client.Width / 2)) ([int]($client.Height * 3 / 4))
    Assert (Wait-HelpDropped 'count') 'E moving off the count drops its tooltip'

    # --- C: Show all and New Process ----------------------------------------
    Write-Host ''
    Write-Host '4. the controls explain themselves'
    $before = Get-LastLineNo 'activity help tooltip target='
    Enter-Control $showAll
    $got = Wait-HelpText 'show-all' $before
    Assert ($got -ceq 'When off, show only processes Ghoztty started (the agent and its descendants).') `
        "C Show all says Mac's words (got '$got')"
    Leave-ToPanel $panel
    Assert (Wait-HelpDropped 'show-all') 'E moving off Show all drops its tooltip'

    $before = Get-LastLineNo 'activity help tooltip target='
    Enter-Control $newProc
    $got = Wait-HelpText 'new-process' $before
    Assert ($got -ceq 'Start a new process on Local') "C New Process names the machine (got '$got')"
    Leave-ToPanel $panel
    Assert (Wait-HelpDropped 'new-process') 'E moving off New Process drops its tooltip'

    # --- B: the count once Show all is on -----------------------------------
    Send-TestControlClick -Control ([IntPtr]$showAll.Hwnd) | Out-Null
    $waited = 0
    while ($waited -lt 6000) { $st = Get-PanelState; if ($st -and $st.ShowAll) { break }; Start-Sleep -Milliseconds 250; $waited += 250 }
    Assert ($st -and $st.ShowAll) 'B Show all is on'
    Move-Pointer $panel ([int]($client.Width / 2)) ([int]($client.Height * 3 / 4))
    # The plain count is right-aligned in the same slot; walk to it again.
    $before = Get-LastLineNo 'activity help tooltip target='
    $got = $null
    for ($x = $npLeft - 2; $x -gt $saRight; $x -= 3) {
        Move-Pointer $panel $x $rowY 60
        if ((Get-LastLineNo 'activity help tooltip target=count text=') -gt $before) { $got = Wait-HelpText 'count' $before; break }
    }
    Assert ($got -cmatch '^\d+ processes$') "B with Show all on the count says just the count (got '$got')"

    # --- F: a row no pane started says so (Mac :1129) -----------------------
    # With Show all on, the table holds the whole box: walk down the Window /
    # Pane column until a row says it is not one of ours.
    $foreign = $null
    if ($paneX -ge 0) {
        for ($y = $cellY; $y -lt $client.Height - 4; $y += 5) {
            $b = Get-LastLineNo 'activity help tooltip target=pane pid='
            Move-Pointer $panel $paneX $y 50
            if ((Get-LastLineNo 'activity help tooltip target=pane pid=') -gt $b) {
                $t = Wait-HelpText 'pane pid=\d+' $b 1000
                if ($t -ceq 'Not started by a Ghoztty pane.') { $foreign = $t; break }
            }
        }
    }
    Assert ($null -ne $foreign) "F a row no Ghoztty pane started says Mac's sentence (got '$foreign')"
    Move-Pointer $panel $saRight $rowY

    # --- C: Kill follows the selection --------------------------------------
    Write-Host ''
    Write-Host '5. Kill names what it would terminate'
    Move-Pointer $panel ([int]($client.Width / 2)) ([int]($client.Height * 3 / 4))
    $rowAX = [int]($client.Width / 2)
    $rowAY = [int]($client.Height * 3 / 4)
    Click-Posted $panel $rowAX $rowAY 0
    Assert (Wait-Selected 1) 'C a posted click selects one row'
    $before = Get-LastLineNo 'activity help tooltip target='
    Enter-Control $kill
    $got = Wait-HelpText 'kill' $before
    Assert (($got -cmatch '^Terminate \S') -and ($got -cnotmatch 'selected processes$')) `
        "C Kill names the one selected process (got '$got')"
    Leave-ToPanel $panel

    # A second row, ctrl-clicked a few rows lower.
    Click-Posted $panel $rowAX ($rowAY + [int]($client.Height / 12)) $MK_CONTROL
    Assert (Wait-Selected 2) 'C a ctrl-click adds a second row'
    $before = Get-LastLineNo 'activity help tooltip target='
    Enter-Control $kill
    $got = Wait-HelpText 'kill' $before
    Assert ($got -ceq 'Terminate 2 selected processes') "C Kill counts two rows (got '$got')"
    Leave-ToPanel $panel
    Assert (Wait-HelpDropped 'kill') 'E moving off Kill drops its tooltip'

    # --- D: one tooltip control, a tool per control -------------------------
    Write-Host ''
    Write-Host '6. one native tooltip carries every control''s tool'
    $tips = @(Get-TestWindows -ProcessId $app.Pid -Class 'tooltips_class32' -AllowHidden)
    $counts = @($tips | ForEach-Object { [int](Invoke-TestMessage -Window ([IntPtr]$_.Hwnd) -Message $TTM_GETTOOLCOUNT) })
    $has = $false
    foreach ($c in $counts) { if ($c -eq 4) { $has = $true } }
    Assert ($tips.Count -ge 1) "D the app owns a native tooltip control ($($tips.Count) found)"
    Assert $has "D the panel's tooltip carries the track tool + Show all, New Process and Kill (tool counts: $($counts -join ','))"

    Assert (Test-TestWindowResponsive -Window $panel) 'the panel still answers after the whole drive'
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'the app survived the whole drive'
    Assert (-not (Select-String -Path $errlog -Pattern 'panic:' -Quiet)) 'no panic reached the app log'

    Complete-TestBody  # T1039: the run reached the end of its body
} finally {
    Remove-TestDesktop
    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 500)
}

# --- stamp (T783) -------------------------------------------------------------
# A tooltip that stopped appearing leaves nothing on screen to notice, and no
# floor lane opens the panel, so nothing else on the box would go red over it.
if ($script:fail -eq 0 -and $script:skipped -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard activity-help-tooltips -Repo $repo 2>&1 | ForEach-Object { Write-Host "  $($_.ToString())" }
}

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Skipped $script:skipped -MinPass 34
