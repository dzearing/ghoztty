# Machine-chooser SESSION ROSTER acceptance (tracker T318).
#
# The Ctrl+Shift+N chooser's detail pane now lists the selected machine's live
# agent sessions - a liveness dot, the label ladder, activity/status badges,
# cwd + command sublines and a Kill button (Mac's `detailSessions`,
# MachineChooserView.swift:544/:608-730). This script drives that end to end
# against a REAL local agent with REAL sessions:
#
#   1. the roster loads OFF the GUI thread and lands: the app logs
#      "chooser roster: loaded N session(s)", and N equals what
#      `ghoztty +sessions --json` reports from the same agent;
#   2. cards are actually PAINTED - the first card's fill is measurably
#      lighter than the dialog background it sits on;
#   3. Kill ends the session: clicking the first card's Kill button opens the
#      destructive confirmation, approving it logs the close, the agent
#      confirms it, and `+sessions` stops listing that id;
#   3b/3c. only what THIS viewer can act on is offered (T1791, Mac's
#      `actionable`): a just-closed pane's session is not a row, and a second
#      app on the same agent lists none of the sessions the first one holds,
#      while its own pane stays listed and its count capsule equals the rows.
#
# WHY A LOG LINE IS THE ORACLE. The roster is owner-drawn on the dialog's own
# surface - there are no HWNDs to read back with WM_GETTEXT, so "what did it
# load" cannot be measured the way a control's caption can. The count is said
# out loud by the app (SessionRoster.adopt) and cross-checked against an
# INDEPENDENT source (`+sessions`, which dials the agent directly and does not
# go through the app at all). The pixels answer the separate question of
# whether anything was drawn.
#
# NEGATIVE CONTROL (run 2, mandatory - a pixel probe with no negative control
# is a probe of the background): with the agent killed the roster resolves to
# `failed`, and the same probe point must come back AT the dialog background.
# Without this, "the card is lighter than the background" would pass against a
# chooser that painted no roster at all as long as some other chrome happened
# to sit there.
#
# T248: the repo's agent AND its app are killed at setup, so the fixture is
# built fresh every run instead of measuring the previous run's sessions.
# T267: the script sets its own window size rather than inheriting whatever
# the last GUI script left in window_placement-debug.
#
#   powershell -NoProfile -File test\win32\chooser-sessions.ps1
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
$agentExe = Join-Path (Split-Path $Exe -Parent) 'ghoztty-agent.exe'

# Isolate the IPC endpoint (inherited through CreateProcessW).
$env:GHOZTTY_PIPE_SUFFIX = "-t318$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$script:pass = 0
$script:fail = 0

function Assert($cond, $name) {
    if ($cond) { Write-Host "  PASS $name"; $script:pass++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:fail++ }
}

# Kill only what this repo built. The installed release (and ITS agent, which
# owns the user's real terminal) is never touched.
function Stop-RepoProcesses {
    # T351: one shared, path-exact kill (lib\CleanSlate.ps1) instead of a private
    # copy - the filter this replaced also matched a detached instance running from
    # zig-out-release (T53b), and every copy answered "does the agent go too" alone.
    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 500)
}

# The DEBUG agent's own state dir (never the installed release's): dropping
# sessions.json between runs is what makes the fixture deterministic. Without
# it the agent rematerializes every previous run's sessions as relaunchable
# tombstones - which are legitimately connectable, so they show up as roster
# rows and the count under test becomes "however many times this script has
# ever run".
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
    # PS5.1 unrolls a one-element array on return, so wrap before counting.
    return @($j)
}

# Round HALF AWAY FROM ZERO, the way Zig's `@round` does. [math]::Round() is
# BANKER'S rounding and the two disagree at 112.5% - the latent DPI bug T257
# found in four copies of the tab-strip datum.
function Px([double]$dip, [double]$scale) { return [int][math]::Floor($dip * $scale + 0.5) }

# The chooser's session region and the first card's Kill button. Hoisted into
# `lib\ChromeGeometry.ps1` in T319, the moment a SECOND script needed to click
# the same Kill button - one datum, one implementation (T257).
function Get-RosterGeometry([double]$s) { return Get-TestChooserRosterGeometry -Scale $s }

function Launch-Gui($errlog, [string[]]$extra) {
    $args = @('--window-width=100', '--window-height=30') + $extra
    $app = Start-OnTestDesktop -Exe $Exe -Arguments $args -StdErr $errlog
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { return $null }
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { return $null }
    $surface = Get-TestChildWindow -Window $top -Class 'GhozttyTerminal'
    if ($surface -eq [IntPtr]::Zero) { return $null }
    return @{ App = $app; Pid = $app.Pid; Top = $top; Surface = $surface }
}

# Wait for the Nth occurrence of a pattern. A refetch logs the SAME line the
# first fetch did, so "the line is present" proves nothing about the second one
# - the count is the only thing that distinguishes them.
function Wait-LogCount($path, $pattern, $want, $timeoutMs) {
    $waited = 0
    while ($waited -lt $timeoutMs) {
        if (Test-Path $path) {
            $m = @(Select-String -Path $path -Pattern $pattern -ErrorAction SilentlyContinue)
            if ($m.Count -ge $want) { return $m[$want - 1].Line }
        }
        Start-Sleep -Milliseconds 200
        $waited += 200
    }
    return $null
}

function Wait-LogLine($path, $pattern, $timeoutMs) {
    $waited = 0
    while ($waited -lt $timeoutMs) {
        if (Test-Path $path) {
            $m = Select-String -Path $path -Pattern $pattern -ErrorAction SilentlyContinue
            if ($m) { return $m[-1].Line }
        }
        Start-Sleep -Milliseconds 200
        $waited += 200
    }
    return $null
}

Write-Host 'T318 chooser session roster'
Stop-RepoProcesses
Reset-AgentState
New-TestDesktop | Out-Null

$errlog = Join-Path $env:TEMP "ghoztty-t318-stderr-$PID.log"
$errlog2 = Join-Path $env:TEMP "ghoztty-t318-stderr2-$PID.log"
Remove-Item $errlog, $errlog2 -ErrorAction SilentlyContinue

try {
    # --- Run 1: a real agent with real sessions ----------------------------
    Write-Host ''
    Write-Host '1. roster loads from the local agent'
    $g = Launch-Gui $errlog @('--session-persistence=true')
    if (-not $g) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }

    # A second pane, so the roster has more than one row to lay out.
    & $Exe +split --direction=right 2>$null | Out-Null
    Start-Sleep -Seconds 2

    $before = @(Get-Sessions)
    Assert ($before.Count -ge 1) "the agent has sessions to list (found $($before.Count))"
    if ($before.Count -lt 1) { Write-Host 'SETUP FAIL: no agent sessions'; exit 1 }

    $chooser = [IntPtr]::Zero
    if (Send-TestKeys -Window $g.Top -Target $g.Surface -Modifiers ctrl, shift -Key N) {
        $chooser = Wait-TestWindow -ProcessId $g.Pid -Class 'GhozttyMachineChooser' -TimeoutMs 4000
    }
    Assert ($chooser -ne [IntPtr]::Zero) 'ctrl+shift+n opens the chooser'
    if ($chooser -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: no chooser'; exit 1 }

    $line = Wait-LogLine $errlog 'chooser roster: loaded (\d+) session' 6000
    Assert ($null -ne $line) 'the roster fetch landed on the GUI thread'
    $loaded = -1
    if ($line -match 'loaded (\d+) session') { $loaded = [int]$Matches[1] }
    Assert ($loaded -eq $before.Count) `
        "the roster count matches the agent's own ($loaded vs $($before.Count))"

    # --- Cards are painted ------------------------------------------------
    Write-Host ''
    Write-Host '2. the cards are painted'
    $scale = (Get-TestWindowDpi -Window $chooser) / 96.0
    $geo = Get-RosterGeometry $scale
    $rect = Get-TestWindowRect -Window $chooser
    # Client origin: the dialog is WS_CAPTION, so the client top is below the
    # frame. Capture and address in SCREEN coordinates via the capture's own
    # origin plus the client offset the layout is expressed in.
    $shot = Get-TestWindowPixels -Window $chooser -Sync
    try {
        $distinct = Get-TestDistinctColors -Shot $shot
        Assert ($distinct -gt 3) "the capture is a real frame, not a black mid-paint one ($distinct colors)"

        $client = Get-TestWindowRect -Window $chooser -Client
        $cardPx = Get-TestPixel -Shot $shot -X ($client.Left + $geo.CardX) -Y ($client.Top + $geo.CardY)
        $bgPx = Get-TestPixel -Shot $shot -X ($client.Left + $geo.Left) -Y ($client.Top + $geo.Bottom - 2)
        $script:cardLum = if ($cardPx) { [int]$cardPx.R } else { -1 }
        $script:bgLum = if ($bgPx) { [int]$bgPx.R } else { -1 }
        Assert ($script:cardLum -gt $script:bgLum) `
            "the first card's fill is lighter than the pane behind it ($($script:cardLum) vs $($script:bgLum))"

        # Green on the first card's title line: the liveness dot is drawn in
        # the `good` tone, so a live card MUST show some. This is the positive
        # control for the scan below; run 2 (no cards at all) is its negative.
        $green = 0
        for ($x = $geo.Left; $x -lt $geo.Right; $x += 2) {
            $p = Get-TestPixel -Shot $shot -X ($client.Left + $x) -Y ($client.Top + $geo.CardY)
            if ($p -and $p.G -gt ($p.R + 20) -and $p.G -gt ($p.B + 20)) { $green++ }
        }
        $script:greenRun1 = $green
        Assert ($green -gt 0) "the live card's green liveness dot is seen, so the scan works ($green px)"

        # No `open` chip (T1760). Every session in this fixture IS open in one
        # of the app's own panes, and Mac dropped that chip because the row's
        # Show button already says so. It used to sit right after the label,
        # in the name column - from the column's own left edge to well clear of
        # the Show button, whose width comes from text metrics (T256). The
        # label ink is never green there, so any green in this band is a chip.
        $bandLeft = $geo.NameHeaderX
        $bandRight = $geo.ActionX - (Get-TestChromeDip 90 $scale)
        $chip = 0
        for ($x = $bandLeft; $x -lt $bandRight; $x += 2) {
            $p = Get-TestPixel -Shot $shot -X ($client.Left + $x) -Y ($client.Top + $geo.CardY)
            if ($p -and $p.G -gt ($p.R + 20) -and $p.G -gt ($p.B + 20)) { $chip++ }
        }
        Assert ($bandRight -gt $bandLeft + 40) "the name band is wide enough to hold a chip ($bandLeft..$bandRight)"
        Assert ($chip -eq 0) "no green open chip is painted after the label (T1760; $chip px)"
    } finally { Close-TestWindowPixels -Shot $shot }

    # The same fact from the painter's own badge run, row by row (T1760): an
    # open row wears no chip at all - neither `open` nor `attached`.
    $rowLines = @(Select-String -Path $errlog -Pattern 'chooser roster: row id=(\S+) open=(\w+) badges=(.*)$' -ErrorAction SilentlyContinue)
    $openRows = @($rowLines | Where-Object { $_.Matches[0].Groups[2].Value -eq 'true' })
    Assert ($openRows.Count -ge 1) "the roster names its open rows' badges ($($openRows.Count) line(s))"
    # Only the openness chips are asserted absent: a shell still starting up
    # can legitimately read `busy`, which is an exception worth its chip.
    $chipped = @($openRows | Where-Object { $_.Matches[0].Groups[3].Value -match '(^|,)(open|attached)(,|$)' })
    Assert ($chipped.Count -eq 0) `
        "no open row wears an open or attached chip ($(@($chipped | ForEach-Object { $_.Matches[0].Groups[3].Value }) -join '; '))"

    # --- Kill --------------------------------------------------------------
    Write-Host ''
    Write-Host '3. Kill ends the session'
    # Send-TestMouse takes SCREEN coordinates (it SetCursorPos'es them and then
    # ScreenToClient's for the posted lparam), so the client-space geometry is
    # offset by the client origin here rather than passed raw.
    $cr = Get-TestWindowRect -Window $chooser -Client
    # How many roster loads have landed BEFORE the kill. The refetch is the
    # next one after this, not "the second one ever": since the agent pushes
    # its roster, a pushed load can arrive between the first fetch and the kill
    # and still read the pre-kill count (T1760 found the assertion reading it).
    $loadsBeforeKill = @(Select-String -Path $errlog -Pattern 'chooser roster: loaded \d+ session' -ErrorAction SilentlyContinue).Count
    Send-TestMouse -Window $chooser -X ($cr.Left + $geo.KillX) -Y ($cr.Top + $geo.KillY) `
        -Button left -Action click | Out-Null
    $confirm = Wait-TestWindow -ProcessId $g.Pid -Class 'GhozttyConfirmDialog' -TimeoutMs 3000
    Assert ($confirm -ne [IntPtr]::Zero) "the Kill button opens a confirmation"

    if ($confirm -ne [IntPtr]::Zero) {
        # Tab then Enter: the dialog is destructive, so its DEFAULT button is
        # Cancel and a bare Enter must not approve it (T50 parity).
        Send-TestControlKey -Control $confirm -Key Tab | Out-Null
        Start-Sleep -Milliseconds 200
        Send-TestControlKey -Control $confirm -Key Enter | Out-Null

        $killLine = Wait-LogLine $errlog 'chooser roster: ending session id=' 4000
        Assert ($null -ne $killLine) 'approving the confirmation ends the session'
        $killedId = ''
        if ($killLine -match 'id=([0-9a-f]+)') { $killedId = $Matches[1] }

        # Three independent oracles: the agent's own answer, the refetch, and
        # `+sessions` from outside the app.
        #
        # `confirmed=` used to be unassertable here, and the reason written down
        # was wrong: the guess was that the agent's terminate+free outran the 5s
        # RPC budget. It does not - measured at ~30 ms (T96). The reply was
        # arriving and being DROPPED, because `close_session_result` was the one
        # A->C reply type with no arm in the client's control dispatch, so the
        # RPC always died on its timeout with `ok=false` over a session that had
        # in fact been killed. Assert it now: a re-broken dispatch would make
        # every Kill report failure again, and only this line would say so.
        $confirmLine = Wait-LogLine $errlog 'chooser roster: close session confirmed=' 8000
        Assert ($null -ne $confirmLine -and $confirmLine -match 'confirmed=true') `
            'the agent confirmed the close (T96)'
        $reload = Wait-LogCount $errlog 'chooser roster: loaded \d+ session' ($loadsBeforeKill + 1) 10000
        Assert ($null -ne $reload) 'the roster refetched itself after the kill'
        $reloaded = -1
        if ($reload -match 'loaded (\d+) session') { $reloaded = [int]$Matches[1] }
        Assert ($reloaded -eq ($before.Count - 1)) `
            "the refetched roster is one shorter ($reloaded vs $($before.Count - 1))"

        Start-Sleep -Seconds 1
        # @() at the CALL site: a PS5.1 function returning a one-element array
        # unrolls it, and a scalar's .Count is $null - which compares LESS THAN
        # anything and would pass this assertion for free.
        $after = @(Get-Sessions)
        Assert ($after.Count -lt $before.Count) `
            "the agent stopped listing it ($($before.Count) -> $($after.Count))"
        if ($killedId -ne '') {
            $stillThere = @($after | Where-Object { $_.id -eq $killedId })
            Assert ($stillThere.Count -eq 0) 'the killed id specifically is gone'
        }
    }

    # --- T1791: only what this viewer can act on is offered ---------------
    # Mac's `actionable` filter: a session the agent reports ATTACHED that no
    # pane of ours holds is not a row - a pane just closed (bound to us for the
    # close's undo window) or another viewer's. The roster is owner-drawn, so
    # the oracles are the roster's own lines, held against `+sessions` (which
    # dials the agent directly and never goes through the app).
    Write-Host ''
    Write-Host '3b. a just-closed pane is not offered as a Resume row (T1791)'
    $pre = @(Get-Sessions)
    & $Exe +split --direction=right 2>$null | Out-Null
    Start-Sleep -Seconds 2
    $post = @(Get-Sessions)
    $fresh = @($post | Where-Object { @($pre | ForEach-Object { $_.id }) -notcontains $_.id })
    Assert ($fresh.Count -eq 1) "the split opened exactly one new session ($($fresh.Count))"
    if ($fresh.Count -eq 1) {
        $closedId = $fresh[0].id
        $listPat = 'chooser roster: listing (\d+) session\(s\), (\d+) exited hidden, (\d+) held elsewhere hidden'
        & $Exe +close "--target=$($fresh[0].pane_id)" 2>$null | Out-Null
        # Straight after the close: is the agent still holding the session for
        # us (the undo window), or did the close end it outright? Either way it
        # must not be offered; the line says which case this run exercised.
        $mid = @(Get-Sessions | Where-Object { $_.id -eq $closedId })
        $lingered = ($mid.Count -eq 1 -and $mid[0].alive -and $mid[0].attached)
        Write-Host "  (closed session $closedId lingering attached: $lingered)"
        # Reopen the chooser: a fresh open fetches, and the fetch says what it
        # lists. Escape first - the dialog is modeless, and a second chord on an
        # open one only focuses it.
        $listsBefore = @(Select-String -Path $errlog -Pattern $listPat -ErrorAction SilentlyContinue).Count
        Send-TestControlKey -Control $chooser -Key Escape | Out-Null
        Start-Sleep -Milliseconds 500
        $surf = Get-TestChildWindow -Window $g.Top -Class 'GhozttyTerminal'
        $chooser = [IntPtr]::Zero
        if (Send-TestKeys -Window $g.Top -Target $surf -Modifiers ctrl, shift -Key N) {
            $chooser = Wait-TestWindow -ProcessId $g.Pid -Class 'GhozttyMachineChooser' -TimeoutMs 4000
        }
        Assert ($chooser -ne [IntPtr]::Zero) 'the chooser reopens after the close'
        $lst = Wait-LogCount $errlog $listPat ($listsBefore + 1) 6000
        Assert ($null -ne $lst) 'the reopened roster says what it lists'
        if ($lst) {
            $rowsNow = @(Select-String -Path $errlog -Pattern "chooser roster: row id=$closedId " -ErrorAction SilentlyContinue)
            # Only rows logged AFTER the reopen count: the split's own row was
            # (correctly) listed open before the close.
            $lstIdx = (@(Select-String -Path $errlog -Pattern $listPat))[$listsBefore].LineNumber
            $late = @($rowsNow | Where-Object { $_.LineNumber -gt $lstIdx })
            Assert ($late.Count -eq 0) "the closed pane's session is not listed ($($late.Count) row line(s))"
            if ($lingered -and $lst -match $listPat) {
                Assert ([int]$Matches[3] -ge 1) "the lingering session is counted as held, not listed ($($Matches[3]))"
            }
        }
    }

    Write-Host ''
    Write-Host '3c. another viewer''s sessions are not offered; the count agrees (T1791)'
    # A SECOND app on the same debug agent: its own pane is ours to Show, and
    # every session app 1 holds is attached to someone else from where it sits.
    $held = @(Get-Sessions | Where-Object { $_.alive -and $_.attached })
    Assert ($held.Count -ge 1) "app 1 holds attached sessions to hide ($($held.Count))"
    $errlog3b = Join-Path $env:TEMP "ghoztty-t318-stderr3b-$PID.log"
    Remove-Item $errlog3b -ErrorAction SilentlyContinue
    $savedSuffix = $env:GHOZTTY_PIPE_SUFFIX
    $env:GHOZTTY_PIPE_SUFFIX = "-t1791$PID"
    try {
        $g3 = Launch-Gui $errlog3b @('--session-persistence=true')
    } finally { $env:GHOZTTY_PIPE_SUFFIX = $savedSuffix }
    Assert ($null -ne $g3) 'a second viewer launches on the same agent'
    if ($g3) {
        $chooser3 = [IntPtr]::Zero
        if (Send-TestKeys -Window $g3.Top -Target $g3.Surface -Modifiers ctrl, shift -Key N) {
            $chooser3 = Wait-TestWindow -ProcessId $g3.Pid -Class 'GhozttyMachineChooser' -TimeoutMs 4000
        }
        Assert ($chooser3 -ne [IntPtr]::Zero) "the second viewer's chooser opens"
        $lst3 = Wait-LogLine $errlog3b 'chooser roster: listing (\d+) session\(s\), (\d+) exited hidden, (\d+) held elsewhere hidden' 6000
        Assert ($null -ne $lst3) "the second viewer's roster says what it lists"
        if ($lst3 -and $lst3 -match 'listing (\d+) session\(s\), (\d+) exited hidden, (\d+) held elsewhere hidden') {
            $listed3 = [int]$Matches[1]; $heldHidden = [int]$Matches[3]
            Assert ($heldHidden -ge $held.Count) `
                "every session app 1 holds is hidden from app 2 ($heldHidden hidden vs $($held.Count) held)"
            $rows3 = @(Select-String -Path $errlog3b -Pattern 'chooser roster: row id=(\S+) open=(\w+) ' -ErrorAction SilentlyContinue)
            $leaked = @($rows3 | Where-Object { @($held | ForEach-Object { $_.id }) -contains $_.Matches[0].Groups[1].Value })
            Assert ($leaked.Count -eq 0) "no row names a session app 1 holds ($($leaked.Count))"
            # Positive control: the filter is not simply emptying the list -
            # app 2's own pane is listed, open, ready to Show.
            $own = @($rows3 | Where-Object { $_.Matches[0].Groups[2].Value -eq 'true' })
            Assert ($own.Count -ge 1) "app 2's own pane is still listed as open ($($own.Count))"
            $cnt = Wait-LogLine $errlog3b 'chooser row count key=local count=(\d+)' 3000
            $capsule = -1
            if ($cnt -match 'count=(\d+)') { $capsule = [int]$Matches[1] }
            Assert ($capsule -eq $listed3) "the machine row's count equals the rows listed ($capsule vs $listed3)"
        }
    }

    # --- Run 2: the negative control --------------------------------------
    Write-Host ''
    Write-Host '4. negative control: no agent, no cards'
    Stop-RepoProcesses
    Reset-AgentState
    $g2 = Launch-Gui $errlog2 @('--session-persistence=false')
    if (-not $g2) { Write-Host 'SETUP FAIL: GUI died at launch (run 2)'; exit 1 }
    $chooser2 = [IntPtr]::Zero
    if (Send-TestKeys -Window $g2.Top -Target $g2.Surface -Modifiers ctrl, shift -Key N) {
        $chooser2 = Wait-TestWindow -ProcessId $g2.Pid -Class 'GhozttyMachineChooser' -TimeoutMs 4000
    }
    Assert ($chooser2 -ne [IntPtr]::Zero) 'the chooser opens with no agent running'
    if ($chooser2 -ne [IntPtr]::Zero) {
        Start-Sleep -Seconds 3
        $shot2 = Get-TestWindowPixels -Window $chooser2 -Sync
        try {
            $client2 = Get-TestWindowRect -Window $chooser2 -Client
            $px2 = Get-TestPixel -Shot $shot2 -X ($client2.Left + $geo.CardX) -Y ($client2.Top + $geo.CardY)
            $lum2 = if ($px2) { [int]$px2.R } else { -1 }
            Assert ($lum2 -lt $script:cardLum) `
                "no card is drawn where run 1 had one ($lum2 vs $($script:cardLum))"
            $green2 = 0
            for ($x = $geo.Left; $x -lt $geo.Right; $x += 2) {
                $p = Get-TestPixel -Shot $shot2 -X ($client2.Left + $x) -Y ($client2.Top + $geo.CardY)
                if ($p -and $p.G -gt ($p.R + 20) -and $p.G -gt ($p.B + 20)) { $green2++ }
            }
            Assert ($green2 -eq 0) `
                "and no badge either, so the green scan discriminates ($green2 vs $($script:greenRun1))"
        } finally { Close-TestWindowPixels -Shot $shot2 }
    }
} finally {
    Stop-RepoProcesses
    Remove-TestDesktop
}

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass)" -ForegroundColor Green; exit 0 }
Write-Host "$script:fail FAILURE(S) ($script:pass passed)" -ForegroundColor Red
exit 1
