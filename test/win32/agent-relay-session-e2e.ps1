# T887 acceptance: a session opened over the RELAY lands in the same store the
# LOCAL PIPE serves.
#
#   powershell -NoProfile -File test\win32\agent-relay-session-e2e.ps1
#
# WHAT THIS PROVES, AND WHY IT NEEDED A NEW HARNESS
#
# T546 consolidated the two daemons: the session agent that serves the local
# pipe now also raises the relay uplink, IN-PROCESS, over the SAME
# `SessionStore`. That is the keystone of the one-installer arc - install on two
# machines and the terminals you left running on one are the terminals you find
# from the other - and its whole claim is "one store, two transports".
#
# `agent-sharing-uplink.ps1` proved the DIAL half: sharing.json on produces a
# real `GET /v1/agent/control` carrying the relay.env bearer token, sharing.json
# off parks it. Its loopback listener answers 404, though, so nothing had ever
# travelled DOWN that channel. The claim that matters - that a session opened
# over the relay is the same object the local pipe enumerates - rested entirely
# on reading `serveControl` -> `RelayWorker` -> `serveOne(store)`.
#
# So this run drives the payload half, end to end, with no mocking below the
# agent's own front door:
#
#   lib\FakeAgentRelay.ps1  the agent-side relay: upgrades the agent's control
#                           dial, sends {"type":"open","session":ID} down it when
#                           a client arrives, upgrades the answering data dial,
#                           and bridges the pair as a byte pipe.
#   remote-test-client.exe  a real protocol client, arriving through the relay:
#                           OPENs a session, prints the AGENT-MINTED id, holds it,
#                           then DETACHes (the session survives).
#   ghoztty.com +sessions   the real CLI, asking the LOCAL PIPE what it has.
#
# The claim is proved when those last two name the same session id, and that id
# is in the `sessions.json` the local store persists to.
#
# Section 7 (T1430) reuses the same fake relay for the explicit daemon mode,
# `ghoztty-agent --relay=<base>`: a pending revocation armed beside relay.env
# parks the control link, the agent POSTs the de-enroll itself, and clearing
# the record brings the link back with nothing but the agent's own revocation
# watcher to resume it (its owns_resume branch, which the --listen-pipe
# harness in agent-sharing-uplink.ps1 section 5 never takes).
#
# Hermetic: GHOZTTY_AGENT_INSTANCE forks the single-instance guard AND the
# lineage the CLI derives its port.json path from, LOCALAPPDATA is private, the
# pipe name is test-unique, GHOSTTY_RELAY_ENV points the credential lookup at a
# scratch file, and every process this script starts is killed by pid. Nothing
# reaches the user's agent or the user's sessions.
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe',
    [string]$ClientExe = 'D:\git\ghoztty\zig-out\bin\remote-test-client.exe'
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\FakeAgentRelay.ps1')

$script:passes = 0
$script:failures = 0
function Assert($name, $cond) {
    if ($cond) { Write-Host "  PASS $name"; $script:passes++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:failures++ }
}
function Say($m) { Write-Host $m }

if (-not (Test-Path $Exe)) {
    Write-TestAssertedNothing -Label 'T887 RELAY SESSION E2E' -Reason "exe not found: $Exe (build with: zig build -Dapp-runtime=win32 -Doptimize=Debug)"
}
if (-not (Test-Path $AgentExe)) {
    Write-TestAssertedNothing -Label 'T887 RELAY SESSION E2E' -Reason "agent not found: $AgentExe (build with: zig build -Dapp-runtime=win32 -Doptimize=Debug)"
}
# T359: this one is an on-demand build target, so a tree that only ever ran the
# normal build does not have it - and skipping the whole e2e for a binary we can
# produce in seconds asserts nothing for no reason. Build it, and only skip if
# that fails.
. (Join-Path $PSScriptRoot 'lib\TestClient.ps1')
$ClientExe = Resolve-RemoteTestClient -ClientExe $ClientExe
if (-not $ClientExe) {
    Write-TestAssertedNothing -Label 'T887 RELAY SESSION E2E' -Reason "client not found and could not be built (build with: $(Get-RemoteTestClientBuildCommand))"
}

# A release zig-out would derive the USER's agent pipe and state dir, so the
# whole run would drive their live sessions (lib\BuildMode.ps1's subject).
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
$buildMode = Assert-GhozttyIsolatedBuild -Exe $Exe
$stateRelease = -not (Test-GhozttyIsolatedBuildMode -Mode $buildMode)
. (Join-Path $PSScriptRoot 'lib\AgentLineage.ps1')

# T1127: the finally below stops the agents this run started, and a
# `--pty-host` holder survives that by design - it owns the ConPTY, escapes the
# job, and is not a child of the agent that asked for it. This run left one
# behind on every ALL PASS. Scoped to the directory of the build under test.
. (Join-Path $PSScriptRoot 'lib\HarnessLeak.ps1')
Register-RepoBuildTeardown -Exe $Exe | Out-Null

# The console twin: an explicit-path `ghoztty.exe` is a GUI-subsystem binary and
# writes nothing to a redirect file (the .com stub is what carries stdout).
$CliExe = [System.IO.Path]::ChangeExtension($Exe, '.com')
if (-not (Test-Path $CliExe)) { $CliExe = $Exe }

$root = Join-Path $env:TEMP "ghoztty-t887-$PID"
Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $root | Out-Null
$lad = Join-Path $root 'lad'
$lineage = "t887$PID"                       # <= agent_lineage.max_len (24)
$agentDir = Join-Path $lad ('ghoztty\' + (Get-GhozttyAgentStateDirLeaf -Instance $lineage -ReleaseLineage:$stateRelease))
New-Item -ItemType Directory -Force $agentDir | Out-Null
$portFile = Join-Path $agentDir 'port.json'
$sessFile = Join-Path $agentDir 'sessions.json'
$sharingFile = Join-Path $agentDir 'sharing.json'
$relayEnv = Join-Path $root 'relay.env'
$relayLog = Join-Path $root 'relay.log'
$relayPorts = Join-Path $root 'relay-ports.txt'
$pipe = "\\.\pipe\ghoztty-agent-t887-$PID"
$token = "tok-t887-$PID"

$savedInst = Get-GhozttyAgentLineage
$savedRelayEnv = $env:GHOSTTY_RELAY_ENV
$savedLad = $env:LOCALAPPDATA
$savedPipeSuffix = $env:GHOZTTY_PIPE_SUFFIX
$savedDeviceToken = $env:GHOSTTY_DEVICE_TOKEN
$script:relayAgentPid = $null

# The only CLI verb here is `+sessions`, which resolves the AGENT endpoint (the
# GHOZTTY_AGENT_INSTANCE lineage and private LOCALAPPDATA set below are what
# isolate that) and never touches the app's IPC pipe. The app-side suffix is claimed anyway: it costs
# nothing, it is what the tree-wide sweep looks for, and it means a later edit
# that reaches for `+list` or `+new-window` from here lands on a private
# endpoint instead of the terminal the user is sitting in.
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
Set-GhozttyTestIsolation -Tag 't887' | Out-Null

# Read a file a live process may hold open for writing (Start-Process redirect
# targets): plain ReadAllText throws a sharing violation there.
function Read-Shared($file) {
    if (-not (Test-Path $file)) { return '' }
    try {
        $fs = [System.IO.FileStream]::new($file, [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $sr = New-Object System.IO.StreamReader($fs)
            return $sr.ReadToEnd()
        } finally { $fs.Dispose() }
    } catch { return '' }
}

function Wait-ForText($file, $pattern, $timeoutSec) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        if ((Read-Shared $file) -match $pattern) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

# Only ever this run's agents: matched on the test-unique command line, so the
# user's installed agent (holding their live sessions) is out of reach.
function Get-TestAgents {
    return , @(Get-CimInstance Win32_Process -Filter "Name='ghoztty-agent.exe'" |
        Where-Object { $_.CommandLine -like "*t887-$PID*" })
}
function Stop-TestAgents {
    foreach ($p in (Get-TestAgents)) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    # Section 7's `--relay` daemon carries no test-unique argument (relay mode
    # takes none), so it is tracked by the pid this run started it with.
    if ($script:relayAgentPid) {
        Stop-Process -Id $script:relayAgentPid -Force -ErrorAction SilentlyContinue
        $script:relayAgentPid = $null
    }
    Start-Sleep -Milliseconds 400
}

# How many relay.log lines match $pattern (a regex): the log is append-only, so
# a count that grows is a new event and never an old line read twice.
function Get-RelayLogCount($pattern) {
    return @((Read-Shared $relayLog) -split "`n" | Where-Object { $_ -match $pattern }).Count
}

# `+sessions --json` against THIS lineage's agent, over the local pipe. Returns
# @{ Code; Rows } - Rows is an array of parsed session objects (empty on an empty
# roster or a failed run).
# persistence: a CLI invocation - it opens no window, so there is nothing to restore.
function Get-LocalSessions($tag) {
    $out = Join-Path $root "sessions-$tag.json"
    $err = "$out.err"
    $p = Start-Process -FilePath $CliExe -WindowStyle Hidden -PassThru `
        -ArgumentList '+sessions', '--json' -RedirectStandardOutput $out -RedirectStandardError $err
    $null = $p.Handle   # cache before any wait, or ExitCode reads empty
    $code = $null
    if ($p.WaitForExit(25000)) { $p.WaitForExit(); $code = $p.ExitCode }
    else { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    $text = (Read-Shared $out) -replace "`0", ''
    # `@(ConvertFrom-Json '[]')` is 1, not 0, in PS 5.1: the empty array arrives
    # as ONE pipeline item and `@()` wraps it rather than unrolling it. Filtering
    # on the row shape is the version that counts an empty roster as empty.
    $rows = @()
    if ($text.Trim().Length -gt 0) {
        $parsed = $null
        try { $parsed = ConvertFrom-Json $text } catch { $parsed = $null }
        if ($null -ne $parsed) {
            $rows = @($parsed | Where-Object { $null -ne $_ -and $null -ne $_.PSObject.Properties['id'] })
        }
    }
    return @{ Code = $code; Rows = $rows; Text = $text; Err = (Read-Shared $err) }
}

$relayJob = $null
$agent = $null
$client = $null
try {
    Say '== 0: the fake relay (agent-side) comes up'
    Stop-TestAgents
    $relayJob = Start-FakeAgentRelay -PortFile $relayPorts -LogPath $relayLog -PendingTimeoutSec 8
    $ports = Get-FakeAgentRelayPorts -PortFile $relayPorts
    Assert 'fake relay bound both listeners' ($null -ne $ports)
    if ($null -eq $ports) {
        Stop-FakeAgentRelay $relayJob
        Write-TestVerdict -Label 'T887 RELAY SESSION E2E' -Pass $script:passes -Fail ($script:failures + 1)
    }
    Say "   relay origin 127.0.0.1:$($ports.Relay), entry 127.0.0.1:$($ports.Entry)"

    # http:// maps to plaintext ws:// - the loopback-test rule ws_client shares.
    Set-Content -Path $relayEnv -Value "RELAY_BASE=http://127.0.0.1:$($ports.Relay)`nDEVICE_TOKEN=$token" -Encoding ascii
    # Sharing ON before the agent starts: the startup path, so nothing in this
    # run depends on the hot toggle T546's harness already covers.
    Set-Content -Path $sharingFile -Value '{"version":1,"enabled":true}' -Encoding ascii

    $env:GHOZTTY_AGENT_INSTANCE = $lineage
    $env:GHOSTTY_RELAY_ENV = $relayEnv
    $env:LOCALAPPDATA = $lad

    Say '== 1: the agent raises the uplink and the relay UPGRADES it'
    $agentOut = Join-Path $root 'agent.out'
    $agentErr = Join-Path $root 'agent.err'
    # T1036: the agent answers for its own endpoints before it is launched.
    Assert-GhozttyIsolatedAgent -Exe $AgentExe | Out-Null
    $agent = Start-Process -FilePath $AgentExe -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $agentOut -RedirectStandardError $agentErr `
        -ArgumentList "--listen-pipe=$pipe", "--port-file=$portFile", "--sessions-file=$sessFile", '--headless'
    $null = $agent.Handle
    Assert 'agent published its port.json' (Wait-ForText $portFile 'pipe' 20)
    Assert 'control channel upgraded at the relay' (Wait-ForText $relayLog 'CONTROL up' 25)
    Assert 'control dial carried the relay.env bearer token' ((Read-Shared $relayLog) -match "CONTROL up auth=Bearer $token")

    Say '== 2: baseline - the local pipe serves an EMPTY roster'
    $base = Get-LocalSessions 'base'
    Assert "+sessions reached the local agent (exit 0, got '$($base.Code)')" ($base.Code -eq 0)
    Assert 'roster starts empty' ($base.Rows.Count -eq 0)

    Say '== 3: a client arrives through the relay and OPENs a session'
    $clientOut = Join-Path $root 'client.out'
    $clientErr = Join-Path $root 'client.err'
    $client = Start-Process -FilePath $ClientExe -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $clientOut -RedirectStandardError $clientErr `
        -ArgumentList '127.0.0.1', "$($ports.Entry)", '--hold=25'
    $null = $client.Handle
    Assert 'relay sent the open command down the control channel' (Wait-ForText $relayLog 'OPEN sent session=e2e-1' 20)
    Assert 'agent answered with a data dial for that session' (Wait-ForText $relayLog 'DATA up session=e2e-1' 25)
    # --hold prints the AGENT-MINTED session id on stdout once OPENED lands.
    Assert 'remote client got a session id back' (Wait-ForText $clientOut '\S{4,}' 30)
    $relaySession = ((Read-Shared $clientOut) -split "`n" | Where-Object { $_.Trim().Length -gt 0 } | Select-Object -First 1)
    if ($null -ne $relaySession) { $relaySession = $relaySession.Trim() }
    Say "   session opened over the relay: $relaySession"

    Say '== 4: THE CLAIM - the local pipe serves that same session'
    $live = Get-LocalSessions 'live'
    $ids = @($live.Rows | ForEach-Object { $_.id })
    Assert "+sessions over the LOCAL PIPE lists the relay-opened id ($($ids -join ','))" ($ids -contains $relaySession)
    Assert 'the on-disk sessions.json carries the same id' ((Read-Shared $sessFile) -match [regex]::Escape($relaySession))

    Say '== 5: the session survives the remote client detaching'
    if ($client.WaitForExit(45000)) { $client.WaitForExit() }
    Assert "remote client detached cleanly (exit 0, got '$($client.ExitCode)')" ($client.ExitCode -eq 0)
    $after = Get-LocalSessions 'after'
    $idsAfter = @($after.Rows | ForEach-Object { $_.id })
    Assert 'the session is still there after the detach' ($idsAfter -contains $relaySession)

    Say '== 6: negative control - with sharing OFF nothing new can arrive'
    Set-Content -Path $sharingFile -Value '{"version":1,"enabled":false}' -Encoding ascii
    Assert 'agent announced the park' (Wait-ForText $agentErr 'sharing disabled; parking' 25)
    Assert 'the relay saw the control link go down' (Wait-ForText $relayLog 'CONTROL down' 20)
    $probe = $null
    try {
        $probe = [System.Net.Sockets.TcpClient]::new('127.0.0.1', $ports.Entry)
        Start-Sleep -Seconds 2
    } catch {} finally { if ($null -ne $probe) { try { $probe.Close() } catch {} } }
    Assert 'an entry client is refused while sharing is off' (Wait-ForText $relayLog 'ENTRY refused' 15)
    $neg = Get-LocalSessions 'neg'
    $idsNeg = @($neg.Rows | ForEach-Object { $_.id })
    Assert "no second session appeared (roster is $($idsNeg.Count))" ($idsNeg.Count -eq 1 -and $idsNeg -contains $relaySession)
    Assert 'the agent survived the whole run' (-not $agent.HasExited)

    Say '== 7: a --relay daemon parks for a pending revocation and RESUMES ITSELF (T1430)'
    # agent-sharing-uplink.ps1 section 5 proves the revocation park under the
    # SharingUplink reconciler (--listen-pipe, how the app runs the agent).
    # The explicit daemon mode, `--relay=<base>`, constructs the same watcher
    # with owns_resume = true: nothing else writes the desired link state
    # there, so when the record clears it is the WATCHER's own
    # LinkControl.reconnect that brings the machine back. No harness had ever
    # executed that branch; the failure it would hide is a machine that comes
    # back from a sign-out and then never comes back online.
    Stop-TestAgents
    # The token must come from relay.env (the hot-reload source), never an
    # inherited GHOSTTY_DEVICE_TOKEN.
    Remove-Item env:GHOSTTY_DEVICE_TOKEN -ErrorAction SilentlyContinue
    $relayBase = "http://127.0.0.1:$($ports.Relay)"
    $upBefore = Get-RelayLogCount "CONTROL up auth=Bearer $token"
    $rOut = Join-Path $root 'relay-agent.out'
    $rErr = Join-Path $root 'relay-agent.err'
    Assert-GhozttyIsolatedAgent -Exe $AgentExe | Out-Null
    $relayAgent = Start-Process -FilePath $AgentExe -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $rOut -RedirectStandardError $rErr `
        -ArgumentList "--relay=$relayBase", '--headless'
    $null = $relayAgent.Handle
    $script:relayAgentPid = $relayAgent.Id
    Assert 'the --relay daemon started in relay mode' (Wait-ForText $rOut 'relay mode, control=' 20)
    # Section 1's dial already logged a CONTROL up; wait for a NEW one, from
    # this process (section 6 parked the --listen-pipe agent, which is stopped).
    $deadline = (Get-Date).AddSeconds(25)
    while ((Get-Date) -lt $deadline -and (Get-RelayLogCount "CONTROL up auth=Bearer $token") -le $upBefore) { Start-Sleep -Milliseconds 250 }
    Assert 'the --relay daemon raised its control link with the relay.env token' ((Get-RelayLogCount "CONTROL up auth=Bearer $token") -gt $upBefore)

    # Arm exactly what a forced sign-out writes, beside relay.env.
    $pendingFile = Join-Path $root 'pending-revoke.json'
    $rec = '{"relay_base":"' + $relayBase + '","device_token":"' + $token + '","account_email":"t1430@example.com","armed_at":1}'
    $downBefore = Get-RelayLogCount 'CONTROL down'
    Set-Content -Path $pendingFile -Value $rec -Encoding ascii
    Assert 'the --relay daemon announces the park' (Wait-ForText $rErr 'taking the relay uplink down' 15)
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline -and (Get-RelayLogCount 'CONTROL down') -le $downBefore) { Start-Sleep -Milliseconds 250 }
    Assert 'the relay saw the control link go down' ((Get-RelayLogCount 'CONTROL down') -gt $downBefore)
    # The completion is attempted by THIS agent, with no app running. The fake
    # relay answers 404 - no definite answer - so the record stays armed.
    Assert 'the --relay daemon attempted the de-enroll itself' (Wait-ForText $relayLog 'REQ POST /v1/agent/deenroll' 25)
    Assert 'the pending record survives a relay that gave no answer' (Test-Path $pendingFile)
    $heldUps = Get-RelayLogCount 'CONTROL up auth='
    Start-Sleep -Seconds 10   # two watcher ticks and well past the 3s base backoff
    Assert 'no control link comes back while the revocation is owed' ((Get-RelayLogCount 'CONTROL up auth=') -eq $heldUps)

    # Sign back in on this machine: the record clears and relay.env stays.
    # Nothing but the watcher can resume the link in --relay mode.
    Remove-Item $pendingFile -ErrorAction SilentlyContinue
    Assert 'the --relay daemon announces the release' (Wait-ForText $rErr 'may come back up' 15)
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline -and (Get-RelayLogCount 'CONTROL up auth=') -le $heldUps) { Start-Sleep -Milliseconds 250 }
    Assert 'the control link comes back up with no other process reconciling it' ((Get-RelayLogCount 'CONTROL up auth=') -gt $heldUps)
    Assert 'the --relay daemon survived the park and the release' (-not $relayAgent.HasExited)
    Complete-TestBody  # T1039: the run reached the end of its body
} finally {
    if ($null -ne $client -and -not $client.HasExited) {
        Stop-Process -Id $client.Id -Force -ErrorAction SilentlyContinue
    }
    Stop-TestAgents
    Stop-FakeAgentRelay $relayJob
    Restore-GhozttyAgentLineage -Saved $savedInst
    if ($null -eq $savedRelayEnv) { Remove-Item env:GHOSTTY_RELAY_ENV -ErrorAction SilentlyContinue }
    else { $env:GHOSTTY_RELAY_ENV = $savedRelayEnv }
    if ($null -eq $savedPipeSuffix) { Remove-Item env:GHOZTTY_PIPE_SUFFIX -ErrorAction SilentlyContinue }
    else { $env:GHOZTTY_PIPE_SUFFIX = $savedPipeSuffix }
    if ($null -ne $savedDeviceToken) { $env:GHOSTTY_DEVICE_TOKEN = $savedDeviceToken }
    $env:LOCALAPPDATA = $savedLad
}

# A clean green run stamps the files this harness covers (T783) so
# `scripts\guard-due.ps1` can answer "has anybody run this against the code as it
# now stands?" for the uplink/control/worker path.
if ($script:failures -eq 0 -and $script:passes -ge 28) {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard agent-relay-session -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

# MinPass = the full-run assertion count: an exception past section N jumps to
# the finally block, and a truncated run must never score as ALL PASS.
Write-TestVerdict -Label 'T887 RELAY SESSION E2E' -Pass $script:passes -Fail $script:failures -MinPass 28
