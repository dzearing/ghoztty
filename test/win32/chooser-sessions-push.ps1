# The machine chooser's PUSHED session roster, and the window rename that
# reaches its rows (tracker T710).
#
# WHAT CHANGED. The chooser's session list was a photograph: fetched when a
# machine is selected and never again. Start a session somewhere else, finish
# one, close one, and the list kept saying what was true at selection time until
# the user clicked away and back. The agent has pushed the roster on every change
# since Mac's bf318f55b (opcodes 0x7c/0x7d, gated on the `sessions_push`
# capability); Windows never subscribed. It does now, and the same change makes a
# renamed WINDOW show its name on the row - the ladder read the pane's
# shell-derived title alone, so a rename looked like it did nothing here.
#
# WHAT IS ASSERTED
#   A  setup control: a real agent with a real session, the chooser open on the
#      local machine, and its roster loaded
#   B  the app SUBSCRIBED to the pushed roster on the local agent's warm
#      connection
#   C  a session created while the chooser is OPEN AND UNTOUCHED reaches the
#      list: a push lands, it is adopted (`pushed=1`), and the listed count
#      grows - with no selection change, no keystroke and no refetch, which is
#      precisely what the old chooser could not do
#   D  the pushed roster agrees with an INDEPENDENT source: `+sessions --json`,
#      which dials the agent directly and does not go through the app at all
#   E  a session ENDING is pushed too, and the list shrinks by itself
#   F  a renamed window reaches the row: after `+rename --title`, the row bound
#      to that window's pane is named after the WINDOW, not the shell
#   G  the negative control, and the one that makes B..E mean anything:
#      GHOSTTY_AGENT_SUPPRESS_CAPS=sessions_push makes this same agent advertise
#      like one too old to serve the stream. The app must then say it has no
#      pushed roster, take ZERO pushes, and still load a roster the ordinary way
#      - the capability gate degrading to "not live" rather than to a wedge, an
#      empty list, or an opcode an older agent would treat as fatal framing.
#
# WHY LOG LINES ARE THE ORACLE. The roster is owner-drawn on the dialog's own
# surface: there is no HWND to read a row back from, so what ARRIVED and what is
# LISTED are said out loud (`SessionRosterProbe.onRoster`,
# `SessionRoster.adoptPushed`, `SessionRoster.logListed`) and cross-checked
# against `+sessions --json`. The rename is only ever visible in that listing
# line: the agent never learns a window was renamed, so the pushed bytes are
# identical and only the rendered NAME differs.
#
# T211/T217: runs on a BACKGROUND Win32 desktop and never takes the user's
# foreground. T248: the repo's agent and app are killed at setup so the fixture
# is built fresh rather than measuring the previous run's sessions.
#
#   powershell -NoProfile -File test\win32\chooser-sessions-push.ps1
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

$env:GHOZTTY_PIPE_SUFFIX = "-t710$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')

$script:pass = 0
$script:fail = 0
$script:skipped = 0
function Assert($cond, $name) {
    if ($cond) { Write-Host "  PASS $name"; $script:pass++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:fail++ }
}

function Stop-RepoProcesses {
    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 500)
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

function Get-LastMatch($path, $pattern) {
    if (-not (Test-Path $path)) { return $null }
    $m = @(Select-String -Path $path -Pattern $pattern -ErrorAction SilentlyContinue)
    if ($m.Count -eq 0) { return $null }
    return $m[-1].Line
}

# The count in the newest `chooser roster: listing N session(s)` line, or -1.
function Get-ListedCount($path) {
    $line = Get-LastMatch $path 'chooser roster: listing \d+ session'
    if (-not $line) { return -1 }
    if ($line -match 'listing (\d+) session') { return [int]$Matches[1] }
    return -1
}

# Wait until the listed count reaches $want (it only ever settles there once the
# push has been adopted AND re-listed), then hand it back.
function Wait-ListedCount($path, $want, $timeoutMs) {
    $waited = 0
    while ($waited -lt $timeoutMs) {
        if ((Get-ListedCount $path) -eq $want) { return $true }
        Start-Sleep -Milliseconds 250
        $waited += 250
    }
    return $false
}

# The names of the rows the app says it holds open, newest listing first.
function Get-OpenRowNames($path) {
    $out = @()
    if (-not (Test-Path $path)) { return $out }
    $m = @(Select-String -Path $path -Pattern 'chooser roster: open row id=' -ErrorAction SilentlyContinue)
    foreach ($x in $m) {
        if ($x.Line -match 'open row id=(\S+) name=(.*)$') {
            $out += , @{ Id = $Matches[1]; Name = $Matches[2].Trim() }
        }
    }
    return $out
}

# Launch the app on the test desktop and open the chooser on the local machine.
# `$suppress` makes the agent advertise like one too old to push (G).
function Start-Fixture($errlog, $suppress) {
    Stop-RepoProcesses
    Reset-AgentState
    if ($suppress) { $env:GHOSTTY_AGENT_SUPPRESS_CAPS = 'sessions_push' }
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

$errlog = Join-Path $env:TEMP "ghoztty-t710-stderr-$PID.log"
$errlog2 = Join-Path $env:TEMP "ghoztty-t710-stderr2-$PID.log"
Remove-Item $errlog, $errlog2 -ErrorAction SilentlyContinue

Write-Host 'T710 chooser pushed session roster'
Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null
New-TestDesktop | Out-Null
$savedSuppress = $env:GHOSTTY_AGENT_SUPPRESS_CAPS

try {
    # --- A: the fixture ----------------------------------------------------
    Write-Host ''
    Write-Host '1. a real agent, one session, and the chooser open on this machine'
    $g = Start-Fixture $errlog $false
    if (-not $g) { Write-TestAssertedNothing -Reason 'the GUI died at launch' -Skipped $script:skipped }
    Assert ($g.Chooser -ne [IntPtr]::Zero) 'A ctrl+shift+n opens the chooser'
    if ($g.Chooser -eq [IntPtr]::Zero) { Write-TestAssertedNothing -Reason 'no chooser window' -Skipped $script:skipped }

    Assert (Wait-LogCount $errlog 'chooser roster: loaded \d+ session' 1 8000) `
        'A the roster loaded from the local agent'
    $listed0 = Get-ListedCount $errlog
    Assert ($listed0 -ge 1) "A the list starts with the window's own session ($listed0)"

    # --- B: the subscription ----------------------------------------------
    Write-Host ''
    Write-Host '2. the subscription'
    Assert (Wait-LogCount $errlog 'chooser roster: subscribed to the pushed roster' 1 8000) `
        'B the chooser subscribed to the agent''s pushed roster'
    # Subscribing sends one immediately, so a subscriber starts from truth
    # rather than waiting for the first change.
    Assert (Wait-LogCount $errlog 'chooser roster: pushed \d+ session' 1 8000) `
        'B the agent pushed a roster as soon as the subscription was live'

    # --- C: a change reaches the OPEN, UNTOUCHED chooser -------------------
    Write-Host ''
    Write-Host '3. a new session, with nobody touching the chooser'
    $pushesBefore = Count-LogLines $errlog 'chooser roster: pushed \d+ session'
    # A new pane is a new agent session. The CLI does this from outside the
    # dialog entirely - no keystroke reaches the chooser, and no selection moves.
    & $Exe +split --direction=right --name=t710pane 2>$null | Out-Null
    Assert (Wait-LogCount $errlog 'chooser roster: pushed \d+ session' ($pushesBefore + 1) 10000) `
        'C the agent pushed the change'
    Assert (Wait-LogCount $errlog 'chooser roster: loaded \d+ session\(s\) target=local device=- pushed=1' 1 10000) `
        'C the chooser adopted a PUSHED roster (not a refetch)'
    $grew = Wait-ListedCount $errlog ($listed0 + 1) 10000
    $listed1 = Get-ListedCount $errlog
    Assert $grew "C the list grew by itself ($listed0 -> $listed1)"

    # --- D: against an independent source ----------------------------------
    $sessions = @(Get-Sessions)
    $alive = @($sessions | Where-Object { $_.alive })
    Assert ($alive.Count -eq $listed1) `
        "D the list agrees with +sessions --json ($listed1 listed, $($alive.Count) alive)"

    # --- E: an ending session is pushed too --------------------------------
    Write-Host ''
    Write-Host '4. a session ending'
    $pushesBefore2 = Count-LogLines $errlog 'chooser roster: pushed \d+ session'
    & $Exe +close --target=t710pane 2>$null | Out-Null
    $shrankPush = Wait-LogCount $errlog 'chooser roster: pushed \d+ session' ($pushesBefore2 + 1) 12000
    Assert $shrankPush 'E the agent pushed the session ending'
    $shrank = Wait-ListedCount $errlog $listed0 12000
    $listed2 = Get-ListedCount $errlog
    Assert $shrank "E the list shrank by itself ($listed1 -> $listed2)"

    # --- F: a renamed window reaches its row -------------------------------
    Write-Host ''
    Write-Host '5. a renamed window'
    # A window of its own, so the rename is a statement about a window whose
    # pane holds exactly one session. One token, no spaces: PowerShell 5.1 cannot
    # put generated text on a native command line intact (T279).
    $newTitle = 'T710renamed'
    & $Exe +new-window --target=t710win 2>$null | Out-Null
    Start-Sleep -Seconds 2
    & $Exe +rename --target=t710win --title=$newTitle 2>$null | Out-Null
    Start-Sleep -Milliseconds 500
    # The agent never learns about a rename, so nothing pushes on its own: the
    # NAME is re-resolved whenever the list is re-stated. Make a roster change to
    # provoke one - which is also the shape a user sees, since the list they are
    # looking at is live.
    $pushesBefore3 = Count-LogLines $errlog 'chooser roster: pushed \d+ session'
    & $Exe +split --direction=down --name=t710pane2 2>$null | Out-Null
    [void](Wait-LogCount $errlog 'chooser roster: pushed \d+ session' ($pushesBefore3 + 1) 10000)
    Start-Sleep -Milliseconds 750

    $rows = @(Get-OpenRowNames $errlog)
    $named = @($rows | Where-Object { $_.Name -like "$newTitle*" })
    Assert ($rows.Count -ge 1) "F the app named the rows it holds open ($($rows.Count) lines)"
    Assert ($named.Count -ge 1) `
        "F a row bound to the renamed window shows the WINDOW's name (last: $(if ($rows.Count) { $rows[-1].Name } else { '<none>' }))"

    Assert (Test-TestWindowResponsive -Window $g.Chooser) 'F the chooser''s message loop is not wedged'

    # --- G: the capability gate (negative control) -------------------------
    Write-Host ''
    Write-Host '6. an agent that cannot push gets no stream, and still works'
    $g2 = Start-Fixture $errlog2 $true
    if (-not $g2) {
        Write-Host 'SKIP G: the GUI died at launch under the suppressed-capability agent'
        $script:skipped++
    }
    elseif ($g2.Chooser -eq [IntPtr]::Zero) {
        Write-Host 'SKIP G: the chooser did not open under the suppressed-capability agent'
        $script:skipped++
    }
    else {
        Assert (Wait-LogCount $errlog2 'chooser roster: loaded \d+ session' 1 8000) `
            'G the roster still loads against the older agent'
        Assert (Wait-LogCount $errlog2 'chooser roster: no pushed roster from this agent' 1 8000) `
            'G the app says this agent cannot push'
        # Give the (absent) stream the same wall clock C measured a push in, so
        # "zero" is a measurement and not an early read.
        & $Exe +split --direction=right --name=t710gpane 2>$null | Out-Null
        Start-Sleep -Seconds 8
        Assert ((Count-LogLines $errlog2 'chooser roster: pushed \d+ session') -eq 0) `
            'G no roster was ever pushed'
        Assert (-not ($g2.App.Process -and $g2.App.Process.HasExited)) `
            'G the app survived the skew'
        Assert (Test-TestWindowResponsive -Window $g2.Chooser) `
            'G the chooser is still answering (the gate degrades, it does not wedge)'
    }
    Complete-TestBody  # T1039: the run reached the end of its body
} finally {
    Stop-RepoProcesses
    Remove-TestDesktop
    if ($null -eq $savedSuppress) {
        Remove-Item 'env:GHOSTTY_AGENT_SUPPRESS_CAPS' -ErrorAction SilentlyContinue
    }
    else { $env:GHOSTTY_AGENT_SUPPRESS_CAPS = $savedSuppress }
}

Write-Host ''
# T884: the `chooser-roster-push` row had a stamp but no way to earn one - a
# green run of this harness re-stamps the covered files now, so the guard's
# CURRENT means "somebody ran this" rather than "somebody stamped it by hand".
# Red leaves the stamp alone, and so does a run that skipped an arm.
if ($script:fail -eq 0 -and $script:skipped -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard chooser-roster-push -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-TestVerdict -Pass $script:pass -Fail $script:fail -Skipped $script:skipped
