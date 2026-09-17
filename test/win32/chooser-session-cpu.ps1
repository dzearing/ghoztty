# The machine chooser's per-session CPU meter (tracker T462).
#
# WHAT CHANGED. The agent has always measured each session's whole process tree
# and PUSHED the numbers (`session_cpu`, 0x79-0x7b); the Mac chooser has always
# drawn them. Windows never subscribed, so its session rows carried no meter and
# there was no way to tell the build chewing a core from the five shells sitting
# at a prompt. The chooser now subscribes on the selected machine's warm
# connection and each row carries a bar + a number.
#
# WHAT IS ASSERTED
#   A  setup control: a real agent with two real sessions - one PINNED (an
#      infinite PowerShell loop) and one idle shell - and the chooser open on
#      the local machine with its roster loaded
#   B  the app SUBSCRIBED, and the stream is live: at least three pushed frames
#      land, which is more than the one a subscription-and-then-silence would
#      produce (the FIRST frame of any stream is a baseline with no delta behind
#      it, so every reading in it is 0 - that is why one frame proves nothing)
#   C  the interval in the frames is the AGENT's, inside the range its own
#      throttle can produce (500..10000ms). The UI must read what it is given
#      rather than assume what it asked for, which is what keeps a throttled
#      stream distinguishable from a stalled one.
#   D  the numbers are per-session and they are not the same number: the busy
#      session reads high and the idle one reads about zero, matched BY SESSION
#      ID against `+sessions --json` - an independent source that dials the
#      agent directly and does not go through the app at all
#   E  a meter is really PAINTED: an unbroken horizontal RUN of warm-tinted
#      pixels spans the meter column, which a pinned session's warn/danger-toned
#      bar produces and a grey card cannot
#   F  the negative control, and the one that makes E mean anything:
#      GHOSTTY_AGENT_SUPPRESS_CAPS=session_cpu makes this same agent advertise
#      like one too old to serve the stream. The app must then log that it has
#      no stream, push ZERO frames, and paint no bar in that band - the
#      capability gate degrading to "no meter" rather than to a wedge, a wrong
#      number, or a poll the agent never agreed to.
#   G  hovering a meter EXPLAINS it (T812): the tip names the units, so a
#      reading over 100 is not a mystery, and moving off the meter drops it.
#      Its own negative control rides F's suppressed-capability agent - no
#      column, no reading, and so no tooltip at all rather than one describing
#      a meter that is not on screen.
#   H  a stream that DIES takes the column with it (T813): with the chooser
#      open and nobody touching it, the agent is killed - the subscription dies
#      with its socket, and the app must notice unprompted and hide the meter
#      column instead of leaving the last readings on screen looking live. A
#      frozen number is read as a measurement, which is worse than nothing. What
#      may come BACK is then held to the same rule: a reading is only allowed to
#      arrive behind a subscription newer than the death, and when recovery does
#      dial a fresh agent the column returns with it.
#
# WHY A LOG LINE IS AN ORACLE. The roster is owner-drawn on the dialog's own
# surface: there is no HWND to read a meter back from, so what ARRIVED is said
# out loud by `SessionCpuProbe.onFrame` (rows, the agent's interval, and the
# readings) and cross-checked against `+sessions --json`. The pixels answer the
# separate question of whether anything was drawn, with F as their control.
#
# T211/T217: runs on a BACKGROUND Win32 desktop and never takes the user's
# foreground. T248: the repo's agent and app are killed at setup so the fixture
# is built fresh rather than measuring the previous run's sessions.
#
#   powershell -NoProfile -File test\win32\chooser-session-cpu.ps1
#
# Only touches ghoztty processes running from this repo's zig-out.
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe'
)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not (Test-Path $Exe)) { $Exe = Join-Path $repo 'zig-out\bin\ghoztty.exe' }

$env:GHOZTTY_PIPE_SUFFIX = "-t462$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')

$WM_MOUSEMOVE = 0x0200

$script:pass = 0
$script:fail = 0
$script:skipped = 0
function Assert($cond, $name) {
    if ($cond) { Write-Host "  PASS $name"; $script:pass++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:fail++ }
}

function Stop-RepoProcesses {
    # T351: one shared, path-exact kill (lib\CleanSlate.ps1) instead of a private
    # copy - the filter this replaced also matched a detached instance running from
    # zig-out-release (T53b), and every copy answered "does the agent go too" alone.
    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 500)
}

# The pinned loop is a real process spinning a real core. Killing the agent
# normally takes its sessions with it, but a leftover spinner would burn a core
# until the box is rebooted, so it is swept by its own marker rather than by
# name - `powershell.exe` is far too common a name to kill on.
function Stop-BusyLoops {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | ForEach-Object {
        if ($_.CommandLine -and $_.CommandLine.Contains('$t462=1')) {
            try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch {}
        }
    }
}

function Reset-AgentState {
    $dir = Join-Path $env:LOCALAPPDATA 'ghoztty\local-agent-debug'
    foreach ($f in @('sessions.json', 'port.json')) {
        Remove-Item (Join-Path $dir $f) -ErrorAction SilentlyContinue
    }
    Remove-Item (Join-Path $dir 'rings') -Recurse -Force -ErrorAction SilentlyContinue
}

# `ghoztty +verb > file` writes zero bytes from PowerShell (T245) - capture
# through a pipe instead.
function Get-Sessions {
    $out = (& $Exe +sessions --json 2>$null | Out-String)
    if (-not $out -or $out.Trim().Length -eq 0) { return @() }
    try { $j = $out | ConvertFrom-Json } catch { return @() }
    if ($null -eq $j) { return @() }
    return @($j)
}

function Count-LogLines($path, $pattern) {
    if (-not (Test-Path $path)) { return 0 }
    return @(Select-String -Path $path -Pattern $pattern -ErrorAction SilentlyContinue).Count
}

function Wait-LogCount($path, $pattern, $want, $timeoutMs) {
    $waited = 0
    while ($waited -lt $timeoutMs) {
        if ((Count-LogLines $path $pattern) -ge $want) { return $true }
        Start-Sleep -Milliseconds 250
        $waited += 250
    }
    return $false
}

function Get-LastFrame($path) {
    if (-not (Test-Path $path)) { return $null }
    $m = @(Select-String -Path $path -Pattern 'chooser cpu: frame rows=' -ErrorAction SilentlyContinue)
    if ($m.Count -eq 0) { return $null }
    return $m[-1].Line
}

# One frame line -> @{ Interval = <ms>; Readings = @{ id = pct } }.
function Parse-Frame($line) {
    $out = @{ Interval = -1; Readings = @{} }
    if (-not $line) { return $out }
    if ($line -match 'interval_ms=(\d+)') { $out.Interval = [int]$Matches[1] }
    if ($line -match '\[(.*)\]\s*$') {
        foreach ($tok in ($Matches[1] -split ' ')) {
            if ($tok -match '^([0-9a-fA-F]+)=(-?[0-9.]+)$') {
                $out.Readings[$Matches[1]] = [double]$Matches[2]
            }
        }
    }
    return $out
}

# The longest UNBROKEN horizontal run of warm-tinted pixels inside the meter
# column's band, in pixels. A pinned session's bar is a solid warn/danger-toned
# capsule spanning the whole 24 DIP column; the card behind it is grey.
#
# A run rather than a COUNT, and that is the whole point: ClearType renders glyph
# edges with coloured sub-pixel fringes, so "how many warm pixels are in this
# band" scores the session TITLE - which starts exactly there when no column is
# reserved - at 64 warm pixels and cannot tell it from a meter. A fringe is one
# or two pixels wide; a bar is two dozen.
function Get-MeterBarRun($shot, $client, $geo) {
    $best = 0
    for ($y = $geo.Top; $y -lt $geo.Bottom; $y += 2) {
        $run = 0
        for ($x = $geo.MeterLeft; $x -lt $geo.MeterRight; $x++) {
            $p = Get-TestPixel -Shot $shot -X ($client.Left + $x) -Y ($client.Top + $y)
            if ($p -and ([int]$p.R - [int]$p.B) -ge 40 -and ([int]$p.R - [int]$p.G) -ge 20) {
                $run++
                if ($run -gt $best) { $best = $run }
            }
            else { $run = 0 }
        }
    }
    return $best
}

function Pack-Point([int]$x, [int]$y) {
    return [IntPtr]((($y -band 0xFFFF) -shl 16) -bor ($x -band 0xFFFF))
}

# Park the pointer over a client point of the chooser by POSTING the dialog the
# WM_MOUSEMOVE it would have got. The roster's cards are painted on the dialog
# itself, so this is the same message the real pointer produces - and it is the
# only way to hover on the background test desktop, where SetCursorPos drives a
# cursor no window is under (T233).
function Move-ChooserPointer($chooser, [int]$x, [int]$y) {
    [void](Send-TestRawMessage -Window $chooser -Message $WM_MOUSEMOVE -LParam (Pack-Point $x $y))
    Start-Sleep -Milliseconds 300
}

# The line number of the last log line matching $pattern, or 0.
function Get-LastLineNo($path, $pattern) {
    if (-not (Test-Path $path)) { return 0 }
    $m = @(Select-String -Path $path -Pattern $pattern -ErrorAction SilentlyContinue)
    if ($m.Count -eq 0) { return 0 }
    return $m[-1].LineNumber
}

# The last tooltip text the app derived for a hovered meter, or $null.
function Get-LastTipText($path) {
    if (-not (Test-Path $path)) { return $null }
    $m = @(Select-String -Path $path -Pattern 'chooser cpu tooltip row=\d+ text=' -ErrorAction SilentlyContinue)
    if ($m.Count -eq 0) { return $null }
    if ($m[-1].Line -match 'chooser cpu tooltip row=\d+ text=(.*)$') { return $Matches[1] }
    return $null
}

# Launch the app on the test desktop with a pinned session and an idle one, open
# the chooser, and hand back everything the assertions need. `$suppress` makes
# the agent advertise like one too old to serve the stream (F).
function Start-Fixture($errlog, $suppress) {
    Stop-RepoProcesses
    Stop-BusyLoops
    Reset-AgentState
    if ($suppress) { $env:GHOSTTY_AGENT_SUPPRESS_CAPS = 'session_cpu' }
    else { Remove-Item 'env:GHOSTTY_AGENT_SUPPRESS_CAPS' -ErrorAction SilentlyContinue }

    $app = Start-OnTestDesktop -Exe $Exe `
        -Arguments @('--window-width=100', '--window-height=30', '--session-persistence=true') `
        -StdErr $errlog
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { return $null }
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { return $null }
    $surface = Get-TestChildWindow -Window $top -Class 'GhozttyTerminal'
    if ($surface -eq [IntPtr]::Zero) { return $null }

    # The busy pane: an infinite PowerShell loop, which pins ONE core, so the
    # meter's reading for it is ~100% (the tone the pixel scan looks for) while
    # the window's own idle shell stays at ~0. No embedded quotes - PowerShell
    # 5.1 cannot put a quoted argument on a native command line (T279).
    & $Exe +split --direction=right '--command=powershell -NoProfile -Command while($true){$t462=1}' 2>$null | Out-Null
    Start-Sleep -Seconds 3

    $chooser = [IntPtr]::Zero
    foreach ($try in 1..3) {
        if (Send-TestKeys -Window $top -Target $surface -Modifiers ctrl, shift -Key N) {
            $chooser = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyMachineChooser' -TimeoutMs 4000
        }
        if ($chooser -ne [IntPtr]::Zero) { break }
        Start-Sleep -Milliseconds 500
    }
    return @{ App = $app; Top = $top; Surface = $surface; Chooser = $chooser }
}

$errlog = Join-Path $env:TEMP "ghoztty-t462-stderr-$PID.log"
$errlog2 = Join-Path $env:TEMP "ghoztty-t462-stderr2-$PID.log"
Remove-Item $errlog, $errlog2 -ErrorAction SilentlyContinue

Write-Host 'T462 chooser per-session CPU meter'
Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null
New-TestDesktop | Out-Null
$savedSuppress = $env:GHOSTTY_AGENT_SUPPRESS_CAPS

try {
    # --- A: the fixture ----------------------------------------------------
    Write-Host ''
    Write-Host '1. a real agent, a pinned session and an idle one'
    $g = Start-Fixture $errlog $false
    if (-not $g) { Write-TestAssertedNothing -Reason 'the GUI died at launch' -Skipped $script:skipped }
    Assert ($g.Chooser -ne [IntPtr]::Zero) 'A ctrl+shift+n opens the chooser'
    if ($g.Chooser -eq [IntPtr]::Zero) { Write-TestAssertedNothing -Reason 'no chooser window' -Skipped $script:skipped }

    $sessions = @(Get-Sessions)
    Assert ($sessions.Count -ge 2) "A the agent has both sessions ($($sessions.Count))"
    Assert (Wait-LogCount $errlog 'chooser roster: loaded \d+ session' 1 8000) `
        'A the roster loaded from the local agent'

    $busyId = ''
    $idleId = ''
    foreach ($s in $sessions) {
        if ($s.argv -and ($s.argv -match 'while')) { $busyId = $s.id }
        elseif ($idleId -eq '') { $idleId = $s.id }
    }
    Assert ($busyId -ne '' -and $idleId -ne '') `
        "A the busy and idle sessions are identifiable (busy=$busyId idle=$idleId)"

    # --- B: the stream is live --------------------------------------------
    Write-Host ''
    Write-Host '2. the pushed stream'
    Assert (Wait-LogCount $errlog 'chooser cpu: subscribed' 1 8000) `
        'B the chooser subscribed to the agent''s session_cpu stream'
    # Three frames at the 2s hint: comfortably inside the wait, and past the
    # baseline frame whose readings are all 0 by construction.
    $gotFrames = Wait-LogCount $errlog 'chooser cpu: frame rows=' 3 25000
    $frames = Count-LogLines $errlog 'chooser cpu: frame rows='
    Assert $gotFrames "B at least three frames were pushed ($frames)"

    # --- C: the agent's own cadence ---------------------------------------
    $last = Parse-Frame (Get-LastFrame $errlog)
    Assert ($last.Interval -ge 500 -and $last.Interval -le 10000) `
        "C the frame carries the agent's chosen interval ($($last.Interval)ms)"

    # --- D: per-session numbers -------------------------------------------
    Write-Host ''
    Write-Host '3. the numbers are per session'
    $busyPct = if ($last.Readings.ContainsKey($busyId)) { $last.Readings[$busyId] } else { -1 }
    $idlePct = if ($last.Readings.ContainsKey($idleId)) { $last.Readings[$idleId] } else { -1 }
    Assert ($busyPct -ge 40) "D the pinned session reads busy ($busyPct%)"
    Assert ($idlePct -ge 0 -and $idlePct -lt 10) "D the idle session reads quiet ($idlePct%)"

    # --- E: it is painted --------------------------------------------------
    Write-Host ''
    Write-Host '4. the meter is drawn'
    $scale = (Get-TestWindowDpi -Window $g.Chooser) / 96.0
    $geo = Get-TestChooserRosterGeometry -Scale $scale
    $client = Get-TestWindowRect -Window $g.Chooser -Client
    $shot = Get-TestWindowPixels -Window $g.Chooser -Sync
    $meterRun = -1
    # Two thirds of the column: the pinned session's bar is full, and the slack
    # covers the capsule's rounded ends and one pixel of rounding at each edge.
    $wantRun = [int](($geo.MeterRight - $geo.MeterLeft) * 2 / 3)
    try {
        $distinct = Get-TestDistinctColors -Shot $shot
        Assert ($distinct -gt 3) "E the capture is a real frame, not a black mid-paint one ($distinct colors)"
        $meterRun = Get-MeterBarRun $shot $client $geo
        Assert ($meterRun -ge $wantRun) `
            "E a tinted meter bar spans the column ($meterRun px, wanted >= $wantRun)"
    } finally { Close-TestWindowPixels -Shot $shot }

    Assert (Test-TestWindowResponsive -Window $g.Chooser) 'E the chooser''s message loop is not wedged'

    # --- G: hovering a meter explains it (T812) ----------------------------
    Write-Host ''
    Write-Host '4b. the meter explains itself on hover'
    $meterX = $geo.MeterLeft + [int](($geo.MeterRight - $geo.MeterLeft) / 2)
    Move-ChooserPointer $g.Chooser $meterX $geo.CardY
    $derived = Wait-LogCount $errlog 'chooser cpu tooltip row=\d+ text=' 1 8000
    $tip = Get-LastTipText $errlog
    Assert ($derived -and $null -ne $tip) 'G hovering the first row''s meter derives a tooltip'
    # The whole point of the task: a number with no units. Asserted on the
    # WORDS, because "a tooltip appeared" would pass over an empty one.
    Assert ($tip -and $tip -match "^\d+% CPU across this session's whole process tree \(100% = one core\)\.") `
        "G the tip names the units a bare number lacks (tip: $tip)"
    # A throttled stream says so on a second line; an unthrottled one must NOT,
    # or the ordinary case reads as degraded. Which of the two this run gets is
    # the agent's call, so the assertion is on the pairing, not on the line.
    $throttled = ($last.Interval -gt 2000)
    $saysThrottled = ($tip -and $tip -match 'throttling itself under load')
    Assert ($throttled -eq $saysThrottled) `
        "G the throttling line matches the agent's actual cadence ($($last.Interval)ms, says=$saysThrottled)"

    # Off the meter, onto the card's leading padding: the tip is dropped rather
    # than left hanging over a row the pointer has left.
    #
    # Scored on ORDER, not on a count delta. A posted WM_MOUSEMOVE parks no real
    # pointer, so the desktop's own cursor keeps producing genuine moves off the
    # meter and the app drops the tip again on its own - which is the same
    # behavior, arriving unbidden. What is asserted is therefore the state the
    # sequence leaves behind: after the off-meter move the last thing the
    # tooltip said is that it went away, with no hover after it.
    Move-ChooserPointer $g.Chooser $meterX $geo.CardY
    [void](Wait-LogCount $errlog 'chooser cpu tooltip row=\d+ text=' 1 8000)
    Move-ChooserPointer $g.Chooser $geo.CardX $geo.CardY
    $dropAt = 0
    $hoverAt = 0
    $waited = 0
    while ($waited -lt 8000) {
        $dropAt = Get-LastLineNo $errlog 'chooser cpu tooltip dropped'
        $hoverAt = Get-LastLineNo $errlog 'chooser cpu tooltip row=\d+ text='
        if ($dropAt -gt $hoverAt) { break }
        Start-Sleep -Milliseconds 250
        $waited += 250
    }
    Assert ($dropAt -gt $hoverAt) `
        "G moving off the meter drops the tooltip (drop at line $dropAt, last hover at $hoverAt)"
    Assert (Test-TestWindowResponsive -Window $g.Chooser) `
        'G the chooser still answers after the hover'

    # --- H: a dead stream takes the column away (T813) ---------------------
    #
    # The meter follows the SELECTION, and the local machine has no selection
    # edge and no pool notification behind it: retire the agent's connection
    # under a live subscription and the frames simply stop while the column
    # stays, holding the last readings forever. A frozen number is read as a
    # measurement, which is worse than an empty column.
    #
    # Killing the agent is the cheapest way to produce exactly that state on a
    # real box. What is asserted is that the app NOTICES with nobody touching
    # the dialog: the column goes away on its own, and no frame lands after it.
    Write-Host ''
    Write-Host '4c. a stream that dies takes the meter away rather than freezing it'
    $framesBeforeKill = Count-LogLines $errlog 'chooser cpu: frame rows='
    $shownAt = Get-LastLineNo $errlog 'chooser cpu: meter column shown'
    $hiddenAt = Get-LastLineNo $errlog 'chooser cpu: meter column hidden'
    Assert ($framesBeforeKill -ge 3 -and $shownAt -gt $hiddenAt) `
        "H the meter is live before the kill ($framesBeforeKill frames, column shown)"

    [void](Stop-RepoGhoztty -Exe $Exe -AgentOnly -SettleMs 500)
    # The poll tick is 5s and the link takes its own moment to admit it is gone,
    # so this is generous on purpose - it is measuring that the app gets there
    # unprompted, not how fast.
    $hid = $false
    $waited = 0
    while ($waited -lt 30000) {
        $hiddenAt = Get-LastLineNo $errlog 'chooser cpu: meter column hidden'
        $shownAt = Get-LastLineNo $errlog 'chooser cpu: meter column shown'
        if ($hiddenAt -gt $shownAt) { $hid = $true; break }
        Start-Sleep -Milliseconds 500
        $waited += 500
    }
    Assert $hid `
        "H the column takes itself away when the stream dies (hidden at line $hiddenAt, last shown at $shownAt)"

    # And what comes back, if anything does, comes back HONESTLY. Recovery may
    # spawn a fresh agent under the open dialog, which is the behavior we want -
    # so this is not "no more frames ever". The invariant is that a reading may
    # only arrive behind a subscription that is NEWER than the death: a frame on
    # the dead one would be the frozen-meter bug wearing a timestamp.
    Start-Sleep -Seconds 12
    $subAt = Get-LastLineNo $errlog 'chooser cpu: subscribed'
    $frameAt = Get-LastLineNo $errlog 'chooser cpu: frame rows='
    $hiddenAt = Get-LastLineNo $errlog 'chooser cpu: meter column hidden'
    Assert ($frameAt -lt $hiddenAt -or $subAt -gt $hiddenAt) `
        "H a reading only ever arrives behind a live subscription (last frame line $frameAt, hidden $hiddenAt, last subscribe $subAt)"
    # And when it did recover, the column came back with it rather than staying
    # blank - the staleness rule un-stales itself, with no separate path.
    $shownAt = Get-LastLineNo $errlog 'chooser cpu: meter column shown'
    Assert ($subAt -lt $hiddenAt -or $shownAt -gt $hiddenAt) `
        "H a recovered stream brings the column back (subscribe $subAt, shown $shownAt, hidden $hiddenAt)"
    Assert (Test-TestWindowResponsive -Window $g.Chooser) `
        'H the chooser still answers with its agent gone'

    # --- F: the capability gate (negative control) -------------------------
    Write-Host ''
    Write-Host '5. an agent that cannot serve the stream gets no meter'
    $g2 = Start-Fixture $errlog2 $true
    if (-not $g2) {
        Write-Host 'SKIP F: the GUI died at launch under the suppressed-capability agent'
        $script:skipped++
    }
    elseif ($g2.Chooser -eq [IntPtr]::Zero) {
        Write-Host 'SKIP F: the chooser did not open under the suppressed-capability agent'
        $script:skipped++
    }
    else {
        Assert (Wait-LogCount $errlog2 'chooser roster: loaded \d+ session' 1 8000) `
            'F the roster still loads against the older agent'
        Assert (Wait-LogCount $errlog2 'chooser cpu: no per-session CPU stream' 1 8000) `
            'F the app says it has no stream from this agent'
        # Give the (absent) stream the same wall clock B measured three frames
        # in, so "zero" is a measurement and not an early read.
        Start-Sleep -Seconds 8
        Assert ((Count-LogLines $errlog2 'chooser cpu: frame rows=') -eq 0) `
            'F no frame was ever pushed'

        $scale2 = (Get-TestWindowDpi -Window $g2.Chooser) / 96.0
        $geo2 = Get-TestChooserRosterGeometry -Scale $scale2
        $client2 = Get-TestWindowRect -Window $g2.Chooser -Client
        $shot2 = Get-TestWindowPixels -Window $g2.Chooser -Sync
        try {
            $distinct2 = Get-TestDistinctColors -Shot $shot2
            Assert ($distinct2 -gt 3) "F the control capture is a real frame ($distinct2 colors)"
            $run2 = Get-MeterBarRun $shot2 $client2 $geo2
            # A couple of pixels is a ClearType fringe on the title, which now
            # starts where the column would have been; a bar is two dozen.
            Assert ($run2 -lt 6) `
                "F no bar is painted without the capability (longest run $run2 px, vs $meterRun with it)"
        } finally { Close-TestWindowPixels -Shot $shot2 }

        # G's negative control: no column, no reading, so hovering the band
        # where a meter WOULD be must derive no tooltip at all. Without this,
        # G would pass equally well against a tip that fires on any card.
        Move-ChooserPointer $g2.Chooser `
            ($geo2.MeterLeft + [int](($geo2.MeterRight - $geo2.MeterLeft) / 2)) $geo2.CardY
        # The positive side is waited for (the app's stderr reaches the file on
        # a flush, not on the message), so the absence gets the same clock -
        # otherwise "zero" would be a read taken before the write.
        Start-Sleep -Seconds 3
        Assert ((Count-LogLines $errlog2 'chooser cpu tooltip row=') -eq 0) `
            'G no tooltip is derived where no meter is painted'

        Assert (-not ($g2.App.Process -and $g2.App.Process.HasExited)) `
            'F the app survived the skew'
        Assert (Test-TestWindowResponsive -Window $g2.Chooser) `
            'F the chooser is still answering (the gate degrades, it does not wedge)'
    }
    Complete-TestBody  # T1039: the run reached the end of its body
} finally {
    Stop-RepoProcesses
    Stop-BusyLoops
    Remove-TestDesktop
    if ($null -eq $savedSuppress) {
        Remove-Item 'env:GHOSTTY_AGENT_SUPPRESS_CAPS' -ErrorAction SilentlyContinue
    }
    else { $env:GHOSTTY_AGENT_SUPPRESS_CAPS = $savedSuppress }
}

# --- stamp (T783/T813) ------------------------------------------------------
# A clean green run records the covered files so scripts\guard-due.ps1 can
# answer "has anyone run this harness against the code as it now stands?". The
# row exists because this feature's regressions are SILENT: a meter that has
# stopped updating looks exactly like one that has not, so nothing else on the
# box would go red over it. A skipped section does not stamp, and every path
# that proves nothing exits before here.
if ($script:fail -eq 0 -and $script:skipped -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard chooser-session-cpu -Repo $repo 2>&1 | ForEach-Object { Write-Host "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Skipped $script:skipped
