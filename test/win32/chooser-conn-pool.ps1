# One warm connection per remote machine, not one per roster fetch (T461).
#
# WHAT CHANGED. The chooser's detail pane used to dial the relay, run
# LIST_SESSIONS, and FREE the connection on every single roster fetch of a remote
# machine - so N refetches of one machine cost N WebSocket upgrades and N relay
# authentications, and there was nowhere to hang anything that has to keep
# listening. `App.machine_pool` now owns ONE connection per endpoint, the chooser
# holds a lease on the machine it is showing, and every fetch BORROWS that
# connection.
#
# THE ORACLE IS THE RELAY'S REQUEST LOG, not the app's own account of itself.
# `lib\FakeRelay.ps1` logs a line per `/v1/client/connect`, so the number of
# dials is counted on the far side of the wire by something that has no idea what
# the pool is. The app log supplies the other half of the pair - how many roster
# LOADS those dials served - because "one dial" is only good news if the fetches
# really happened. A run where the refetches silently did not fire would pass a
# dial count of 1 and prove nothing; C asserts both numbers.
#
# THE REFETCH DRIVER. Pressing Down while the LAST row is selected re-runs
# `refreshDetail` on the SAME machine (`clampSelection` clamps to the row it is
# already on), which is a `refresh_in_place` roster fetch. So the directory here
# lists exactly ONE device: the rows are [This PC, dev-remote], and every Down
# after the first is another fetch of dev-remote with no selection change.
#
# WHAT IS ASSERTED
#   A  setup control: the app lists our device, and one remote window is open
#      through the relay so the machine really has a session to list
#   B  selecting the device row loads its roster over a pooled connection
#   C  five more fetches of that machine cost ZERO further dials (and really
#      were five more fetches)
#   D  closing the chooser releases the last lease and drops the connection -
#      a browse must not leave a socket open to every machine clicked through
#   E  the control that makes C mean something: a SECOND chooser dials again,
#      and its roster loads. If the pool had simply stopped dialing, C would
#      still pass and E could not.
#   F  arrowing AWAY from the machine and back also re-dials (same policy as D,
#      measured while one chooser stays open)
#   G  T859: a pooled connection that DIED is condemned by the fetch that
#      discovered it, redialed at once, and the roster comes back on its own.
#      The relay drops the live bridge without touching the agent, so the
#      machine is fine and only the socket is gone - the state the pool used to
#      sit on until the heartbeat backoff eventually declared the link dead.
#   H  T1636: the same drop with NOBODY fetching. A dropped socket never
#      reaches `dead`, so only the pool's own sweep can find it; it must
#      replace the connection, and the pushed roster AND the CPU meter must
#      come back on the replacement - exactly one subscription each, and a
#      session started after the swap must still arrive as a push.
#
# T211/T217: runs on a BACKGROUND Win32 desktop and never takes the user's
# foreground. T248: the repo's agent and app are killed at setup and the app is
# launched with persistence off.
#
#   powershell -NoProfile -File test\win32\chooser-conn-pool.ps1
#
# Only touches ghoztty processes running from this repo's zig-out.
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [int]$AgentPort = 0,
    [int]$RelayPort = 0
)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\FreePort.ps1')
# T694: the port the OS just handed out, asserted free and printed, instead of a
# number this script and some other one both guessed.
$AgentPort = Resolve-TestPort -Name 'agent' -Port $AgentPort
$RelayPort = Resolve-TestPort -Name 'relay' -Port $RelayPort

$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not (Test-Path $Exe)) { $Exe = Join-Path $repo 'zig-out\bin\ghoztty.exe' }
$agentExe = Join-Path (Split-Path $Exe -Parent) 'ghoztty-agent.exe'

$env:GHOZTTY_PIPE_SUFFIX = "-t461$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\FakeRelay.ps1')
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
    # T351: one shared, path-exact kill (lib\CleanSlate.ps1) instead of a private
    # copy - the filter this replaced also matched a detached instance running from
    # zig-out-release (T53b), and every copy answered "does the agent go too" alone.
    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 500)
}

function Reset-AgentState {
    $dir = Join-Path $env:LOCALAPPDATA 'ghoztty\local-agent-debug'
    foreach ($f in @('sessions.json', 'port.json')) {
        Remove-Item (Join-Path $dir $f) -ErrorAction SilentlyContinue
    }
    Remove-Item (Join-Path $dir 'rings') -Recurse -Force -ErrorAction SilentlyContinue
}

function Count-LogLines($path, $pattern) {
    if (-not (Test-Path $path)) { return 0 }
    return @(Select-String -Path $path -Pattern $pattern -ErrorAction SilentlyContinue).Count
}

function Wait-LogCount($path, $pattern, $want, $timeoutMs) {
    $waited = 0
    while ($waited -lt $timeoutMs) {
        if ((Count-LogLines $path $pattern) -ge $want) { return $true }
        Start-Sleep -Milliseconds 200
        $waited += 200
    }
    return $false
}

function Count-RelayConnects($path, $device) {
    return @(Get-FakeRelayLog $path | Select-String "CONNECT device=$device").Count
}

# Wait until the relay's connect count STOPS moving, so a delta is measured
# against a settled number rather than against a dial still in flight.
function Wait-RelaySettled($path, $device, $quietMs = 1200) {
    $last = -1
    for ($i = 0; $i -lt 20; $i++) {
        $now = Count-RelayConnects $path $device
        if ($now -eq $last) { return $now }
        $last = $now
        Start-Sleep -Milliseconds $quietMs
    }
    return $last
}

$TOKEN = 'faketoken-t461'
$DEV = 'dev-remote'
# ONE device on purpose: it makes dev-remote the LAST row, which is what turns a
# repeated Down into a repeated fetch of the same machine (see the header).
$devicesJson = '{"devices":[' +
'{"id":"' + $DEV + '","name":"E2E-Remote","hostname":"remote.local","online":true}]}'

$errlog = Join-Path $env:TEMP "ghoztty-t461-stderr-$PID.log"
$relaylog = Join-Path $env:TEMP "ghoztty-t461-relay-$PID.log"
$agentlog = Join-Path $env:TEMP "ghoztty-t461-agent-$PID.log"
$dropFile = Join-Path $env:TEMP "ghoztty-t461-drop-$PID.flag"
$tmp = Join-Path $env:TEMP "ghoztty-t461-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null
Remove-Item $errlog, $relaylog, $dropFile -ErrorAction SilentlyContinue

Write-Host 'T461 machine connection pool - one dial per machine, not per fetch'
Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null
Stop-RepoProcesses
Reset-AgentState
New-TestDesktop | Out-Null

$script:agent = $null
$script:relay = $null
try {
    # --- The "other machine": a real agent on a TCP port -------------------
    if (-not (Test-Path $agentExe)) {
        Write-TestAssertedNothing -Reason "no agent binary at $agentExe"
    }
    $env:GHOSTTY_AGENT_LOCK = Join-Path $tmp 'agent.lock'
    $script:agent = Start-Process -FilePath $agentExe `
        -ArgumentList '--listen', "127.0.0.1:$AgentPort", '--headless' -PassThru -WindowStyle Hidden `
        -RedirectStandardError $agentlog
    $null = $script:agent.Handle
    Start-Sleep -Seconds 2
    if ($script:agent.HasExited) {
        Write-TestAssertedNothing -Reason 'the remote agent died at launch'
    }
    Write-Host "  OK   remote agent pid=$($script:agent.Id) on 127.0.0.1:$AgentPort"

    $script:relay = Start-FakeRelay -Port $RelayPort -AgentPort $AgentPort `
        -DevicesJson $devicesJson -LogPath $relaylog -DropBridgesFile $dropFile
    if (-not (Select-String -Path $relaylog -Pattern 'LISTEN' -Quiet)) {
        Write-TestAssertedNothing -Reason 'the fake relay never listened'
    }
    Write-Host "  OK   fake relay on 127.0.0.1:$RelayPort"

    # --- The app, signed in via the env token, on the test desktop ---------
    $env:GHOSTTY_RELAY_BASE = "http://127.0.0.1:$RelayPort"
    $env:GHOSTTY_RELAY_TOKEN = $TOKEN
    $env:GHOSTTY_ACCOUNT_STORE = (Join-Path $tmp 'account.dat')
    $app = Start-OnTestDesktop -Exe $Exe `
        -Arguments @('--window-width=100', '--window-height=30', '--session-persistence=false') `
        -StdErr $errlog
    foreach ($k in 'GHOSTTY_RELAY_BASE', 'GHOSTTY_RELAY_TOKEN', 'GHOSTTY_ACCOUNT_STORE') {
        Remove-Item "env:$k" -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) {
        Write-TestAssertedNothing -Reason 'the GUI died at launch'
    }
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { Write-TestAssertedNothing -Reason 'no top window' }
    $surface = Get-TestChildWindow -Window $top -Class 'GhozttyTerminal'
    if ($surface -eq [IntPtr]::Zero) { Write-TestAssertedNothing -Reason 'no pane' }

    # One remote window through the relay, so the machine has a session to list.
    cmd /c "`"$Exe`" +new-remote-window --relay=http://127.0.0.1:$RelayPort --device=$DEV --token=$TOKEN > `"$tmp\open.txt`" 2>&1"
    Start-Sleep -Seconds 3
    Assert ((Count-RelayConnects $relaylog $DEV) -ge 1) `
        'A a remote window opened through our relay (setup control)'

    # --- Open the chooser and select the machine ---------------------------
    Write-Host ''
    Write-Host '1. the device row loads its roster over a pooled connection'
    $chooser = [IntPtr]::Zero
    foreach ($try in 1..3) {
        if (Send-TestKeys -Window $top -Target $surface -Modifiers ctrl, shift -Key N) {
            $chooser = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyMachineChooser' -TimeoutMs 4000
        }
        if ($chooser -ne [IntPtr]::Zero) { break }
    }
    Assert ($chooser -ne [IntPtr]::Zero) 'ctrl+shift+n opens the chooser'
    if ($chooser -eq [IntPtr]::Zero) {
        Write-TestAssertedNothing -Reason 'the chooser never opened; nothing about the pool was measured'
    }
    # The row the rest of this run drives is OURS: the chooser fetched the
    # directory from our relay when it opened.
    Assert ((Get-FakeRelayLog $relaylog | Select-String '/v1/client/devices').Count -ge 1) `
        'A the chooser listed the device directory from our relay'

    $before = Wait-RelaySettled $relaylog $DEV
    Send-TestControlKey -Control $chooser -Key Down | Out-Null
    $loaded = Wait-LogCount $errlog "chooser roster: loaded \d+ session.*device=$DEV" 1 15000
    Assert $loaded 'B selecting the device row loads the remote roster'
    Assert ((Count-LogLines $errlog "machine pool: warm connection ready relay:.*\|$DEV") -eq 1) `
        'B the pool dialed it exactly once'

    # --- C: the whole point ------------------------------------------------
    Write-Host ''
    Write-Host '2. five more fetches of the same machine cost no further dials'
    $afterFirst = Wait-RelaySettled $relaylog $DEV
    Assert (($afterFirst - $before) -eq 1) `
        "B the roster's own dial is ONE connect (before=$before after=$afterFirst)"

    $loadsBefore = Count-LogLines $errlog "chooser roster: loaded \d+ session.*device=$DEV"
    foreach ($i in 1..5) {
        # Down at the LAST row clamps to itself: same machine, fresh fetch.
        Send-TestControlKey -Control $chooser -Key Down | Out-Null
        Start-Sleep -Milliseconds 700
    }
    $wantLoads = $loadsBefore + 5
    $gotLoads = Wait-LogCount $errlog "chooser roster: loaded \d+ session.*device=$DEV" $wantLoads 20000
    $loadsAfter = Count-LogLines $errlog "chooser roster: loaded \d+ session.*device=$DEV"
    # The control for C: the refetches really happened. Without this, "one dial"
    # would also be the verdict for a chooser that fetched nothing at all.
    Assert $gotLoads "C the five refetches really ran ($loadsBefore -> $loadsAfter loads)"
    $afterRefetch = Wait-RelaySettled $relaylog $DEV
    Assert (($afterRefetch - $afterFirst) -eq 0) `
        "C and they dialed the relay ZERO more times (still $afterRefetch connects)"
    Assert ((Count-LogLines $errlog "machine pool: warm connection ready relay:.*\|$DEV") -eq 1) `
        'C the pool still reports exactly one warm connection for it'

    # --- G: a pooled connection that died is replaced, not sat on (T859) ---
    Write-Host ''
    Write-Host '3. a dead pooled connection is condemned and redialed on the spot'
    # Drop the bridge the app's pooled connection rides. The agent is untouched,
    # so the machine still has its session to list - which is what makes the
    # recovery measurable: a roster that comes back could only have come back
    # over a NEW connection.
    New-Item -ItemType File -Path $dropFile -Force | Out-Null
    $dropped = $false
    for ($i = 0; $i -lt 40; $i++) {
        if (Count-LogLines $relaylog "BRIDGE dropped device=$DEV") { $dropped = $true; break }
        Start-Sleep -Milliseconds 250
    }
    Assert $dropped 'G the relay dropped the live bridge (fixture control)'
    $dialsBeforeHeal = Count-RelayConnects $relaylog $DEV
    $loadsBeforeHeal = Count-LogLines $errlog "chooser roster: loaded \d+ session.*device=$DEV"
    $poolDialsBeforeHeal = Count-LogLines $errlog "machine pool: dialing relay:.*\|$DEV"

    # One refetch over the dead connection. Its RPC is what discovers the death
    # (up to the roster's 5s RPC timeout), so everything after it is generous.
    Send-TestControlKey -Control $chooser -Key Down | Out-Null
    $condemned = Wait-LogCount $errlog 'chooser roster: the pooled connection was gone; redialing' 1 20000
    Assert $condemned 'G the fetch that failed over it condemned the connection'
    Assert ((Count-LogLines $errlog 'machine pool: a borrower proved the warm connection dead') -ge 1) `
        'G the pool agreed and dialed a fresh one'
    $healed = Wait-LogCount $errlog "chooser roster: loaded \d+ session.*device=$DEV" ($loadsBeforeHeal + 1) 25000
    Assert $healed 'G the roster came back by itself, with nobody clicking anything'
    $dialsAfterHeal = Wait-RelaySettled $relaylog $DEV
    # The independent half: the relay really saw a new socket for this device.
    # NOT an equality here, deliberately - the drop also kills the bridge the
    # remote WINDOW rides, and its own reconnect dials the same device through
    # the same relay, so the relay's count carries traffic this section is not
    # about. Which also means this assertion is a WITNESS, not the
    # discriminator: it passes at delta 1 against an unwired build (measured),
    # on that reconnect alone. The four assertions that go red there are the
    # condemn, the pool's dial, the roster coming back, and the count below.
    Assert (($dialsAfterHeal - $dialsBeforeHeal) -ge 1) `
        "G the relay saw the fresh socket (delta $($dialsAfterHeal - $dialsBeforeHeal))"
    # The exactly-one claim is made where it belongs: the POOL's dials for this
    # machine. One per proven-dead connection, never a storm - the roster's
    # single-shot flag and the pool's `ready`-only redial are both in this number.
    Assert ((Count-LogLines $errlog "machine pool: dialing relay:.*\|$DEV") -eq ($poolDialsBeforeHeal + 1)) `
        'G and the pool dialed exactly once to recover'
    Assert (Test-TestWindowResponsive -Window $chooser) `
        'G the chooser is not wedged - the retry dial never parked its worker'
    # --- H: a dropped socket nobody fetches over is still replaced (T1636) --
    Write-Host ''
    Write-Host '3b. a dropped pooled socket is replaced with NO fetch, and both streams come back'
    # G's recovery needs a fetch to discover the death. The pushed roster makes
    # fetches rare - the list is live, so nothing re-asks - and a dropped socket
    # sits in `reconnecting` forever (only a DETACHED frame reaches `dead`), so
    # before T1636 the pool never noticed and the pushed roster simply STOPPED,
    # with the last list still on screen. Here nobody presses anything: the
    # chooser's own poll has to find the corpse.
    $subRosterBefore = Count-LogLines $errlog 'chooser roster: subscribed to the pushed roster'
    $subCpuBefore = Count-LogLines $errlog 'chooser cpu: subscribed interval_hint='
    $poolDialsBeforeH = Count-LogLines $errlog "machine pool: dialing relay:.*\|$DEV"
    $sweptBefore = Count-LogLines $errlog 'machine pool: warm connection stayed \w+ for \d+ms'
    $droppedBefore = Count-LogLines $relaylog "BRIDGE dropped device=$DEV"
    # Both streams were live on the connection G installed - otherwise "they came
    # back" below would be measuring a subscription that was never there.
    Assert ($subRosterBefore -ge 1 -and $subCpuBefore -ge 1) `
        "H setup: the roster ($subRosterBefore) and the meter ($subCpuBefore) were subscribed before the drop"

    New-Item -ItemType File -Path $dropFile -Force | Out-Null
    $droppedH = $false
    for ($i = 0; $i -lt 40; $i++) {
        if ((Count-LogLines $relaylog "BRIDGE dropped device=$DEV") -gt $droppedBefore) { $droppedH = $true; break }
        Start-Sleep -Milliseconds 250
    }
    Assert $droppedH 'H the relay dropped the live bridge again (fixture control)'
    $pushesAtDrop = Count-LogLines $errlog 'chooser roster: pushed \d+ session'

    # Settle window (5s) + one poll tick (5s) + the dial: generous at 30s.
    $swept = Wait-LogCount $errlog 'machine pool: warm connection stayed \w+ for \d+ms' ($sweptBefore + 1) 30000
    Assert $swept 'H the pool condemned the connection that stayed down, with no fetch to prompt it'
    $resubbed = Wait-LogCount $errlog 'chooser roster: subscribed to the pushed roster' ($subRosterBefore + 1) 20000
    Assert $resubbed 'H the pushed roster was re-subscribed on the replacement connection'
    $firstPush = Wait-LogCount $errlog 'chooser roster: pushed \d+ session' ($pushesAtDrop + 1) 10000
    Assert $firstPush 'H and the agent pushed the roster over it'
    $cpuBack = Wait-LogCount $errlog 'chooser cpu: subscribed interval_hint=' ($subCpuBefore + 1) 10000
    Assert $cpuBack 'H the CPU meter was re-subscribed on the same replacement'
    $cpuFramesAtResub = Count-LogLines $errlog 'chooser cpu: frame rows='
    $cpuFrame = Wait-LogCount $errlog 'chooser cpu: frame rows=' ($cpuFramesAtResub + 1) 15000
    Assert $cpuFrame 'H and CPU frames resumed without a selection change'

    # NOT asserted here: a session started on the machine after the swap
    # reaching the roster as a push. The agent only pushes a roster change to
    # the connection that MADE it, so a session opened by another client (a
    # second `+new-remote-window`, which dials its own socket) is never pushed
    # to the chooser's pooled connection - with or without a drop. That is
    # T1749, measured by this section's first draft; the stream's liveness here
    # is shown by the subscribe-time push and the CPU frames above instead.

    # Exactly once: one condemn, one pool dial, one subscription per stream -
    # measured after a further settle + tick, so a second sweep that fired on
    # the healthy replacement would have had time to show up here.
    Start-Sleep -Seconds 12
    Assert ((Count-LogLines $errlog 'machine pool: warm connection stayed \w+ for \d+ms') -eq ($sweptBefore + 1)) `
        'H exactly one condemn for one drop'
    Assert ((Count-LogLines $errlog "machine pool: dialing relay:.*\|$DEV") -eq ($poolDialsBeforeH + 1)) `
        'H the pool dialed exactly once to replace it'
    Assert ((Count-LogLines $errlog 'chooser roster: subscribed to the pushed roster') -eq ($subRosterBefore + 1)) `
        'H one roster subscription on the replacement - no duplicate stream'
    Assert ((Count-LogLines $errlog 'chooser cpu: subscribed interval_hint=') -eq ($subCpuBefore + 1)) `
        'H one CPU subscription on the replacement - no doubled frame rate'
    Assert (Test-TestWindowResponsive -Window $chooser) 'H the chooser is not wedged'

    # Re-baseline for the sections below, which measure deltas.
    $afterRefetch = Wait-RelaySettled $relaylog $DEV
    $loadsAfter = Count-LogLines $errlog "chooser roster: loaded \d+ session.*device=$DEV"

    # --- F: leaving the machine gives the socket back ----------------------
    Write-Host ''
    Write-Host '4. arrowing away and back re-dials (a browse holds one machine, not all of them)'
    Send-TestControlKey -Control $chooser -Key Up | Out-Null
    Start-Sleep -Milliseconds 800
    Assert ((Count-LogLines $errlog 'machine pool: last lease released') -ge 1) `
        'F moving off the machine released its lease'
    Send-TestControlKey -Control $chooser -Key Down | Out-Null
    $backLoads = Wait-LogCount $errlog "chooser roster: loaded \d+ session.*device=$DEV" ($loadsAfter + 1) 15000
    $afterBack = Wait-RelaySettled $relaylog $DEV
    Assert ($backLoads -and ($afterBack - $afterRefetch) -eq 1) `
        "F coming back dials once more and loads again (delta $($afterBack - $afterRefetch))"

    # --- D: the chooser closing takes the connection with it ---------------
    Write-Host ''
    Write-Host '5. closing the chooser drops the connection'
    $releasesBefore = Count-LogLines $errlog 'machine pool: last lease released'
    Send-TestControlKey -Control $chooser -Key Escape | Out-Null
    Start-Sleep -Milliseconds 800
    Assert (-not (Test-TestWindowExists -Window $chooser)) 'D Escape closed the chooser'
    Assert ((Count-LogLines $errlog 'machine pool: last lease released') -ge ($releasesBefore + 1)) `
        'D closing it released the last lease and dropped the connection'

    # --- E: the control that makes C a result rather than a silence --------
    Write-Host ''
    Write-Host '6. a second chooser dials again - the pool did not just stop dialing'
    $chooser2 = [IntPtr]::Zero
    foreach ($try in 1..3) {
        if (Send-TestKeys -Window $top -Target $surface -Modifiers ctrl, shift -Key N) {
            $chooser2 = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyMachineChooser' -TimeoutMs 4000
        }
        if ($chooser2 -ne [IntPtr]::Zero) { break }
    }
    Assert ($chooser2 -ne [IntPtr]::Zero) 'E the chooser opens a second time'
    if ($chooser2 -ne [IntPtr]::Zero) {
        $loads2Before = Count-LogLines $errlog "chooser roster: loaded \d+ session.*device=$DEV"
        Send-TestControlKey -Control $chooser2 -Key Down | Out-Null
        $reload = Wait-LogCount $errlog "chooser roster: loaded \d+ session.*device=$DEV" ($loads2Before + 1) 15000
        $afterSecond = Wait-RelaySettled $relaylog $DEV
        Assert $reload 'E the second chooser loads the roster again'
        Assert (($afterSecond - $afterBack) -eq 1) `
            "E and it really re-dialed (delta $($afterSecond - $afterBack))"
        Assert (Test-TestWindowResponsive -Window $chooser2) 'E the chooser''s message loop is not wedged'
        Send-TestControlKey -Control $chooser2 -Key Escape | Out-Null
        Start-Sleep -Milliseconds 500
    }

    Assert (-not ($app.Process -and $app.Process.HasExited)) 'the app survived the whole run'
    Assert (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) 'the run never took the user''s foreground'
    Complete-TestBody  # T1039: the run reached the end of its body
} finally {
    Stop-FakeRelay $script:relay
    if ($null -ne $script:agent) {
        Stop-Process -Id $script:agent.Id -Force -ErrorAction SilentlyContinue
    }
    Stop-RepoProcesses
    Remove-TestDesktop
    Remove-Item 'env:GHOSTTY_AGENT_LOCK' -ErrorAction SilentlyContinue
    Remove-Item $dropFile -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Skipped $script:skipped
