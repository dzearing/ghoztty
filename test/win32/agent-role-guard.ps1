# T1967 acceptance: the agent's single-instance guard is per ROLE on Windows, a
# takeover never crosses roles, the agent's private variables never reach a
# pane shell, and `--relay --exit-on-revoke` exits once the relay has rejected
# the device credential.
#
#   powershell -NoProfile -File test\win32\agent-role-guard.ps1
#
# WHY. main 40c63c90b made the daemon guard per role (relay / listen /
# listen-unix; the Windows session agent is listen-pipe) and made a takeover
# (`--force-replace`, a stale heartbeat) kill only a holder whose role is
# CONFIRMED equal. The danger it closes: a shell spawned by the session agent
# used to inherit that agent's GHOSTTY_AGENT_HEARTBEAT, so a `--relay
# --force-replace` started from a pane read the SESSION agent's heartbeat as its
# rival and would have killed the process that owns every live pane. The same
# commit stops the agent leaking GHOSTTY_AGENT_LOCK / _HEARTBEAT /
# _NO_SELFUPDATE and GHOSTTY_DEVICE_TOKEN (a relay credential) into the shells
# it spawns. The shared code reached this branch with T1902; until this script
# nothing had shown any of it on a Windows box (single_instance.zig said so).
#
# Sections:
#   A  a session agent and a relay agent run side by side; a second session
#      agent is still refused (exit 183), so "side by side" is not "no guard".
#   B  the inherited-variable takeover: a `--relay --force-replace` whose
#      GHOSTTY_AGENT_HEARTBEAT names the SESSION agent's heartbeat yields (183,
#      "different kind of agent") and kills nobody. Positive control: the same
#      launch WITHOUT the override replaces the relay holder, so --force-replace
#      demonstrably kills when the role matches.
#   C  a pane shell's environment carries none of the agent-private variables,
#      on BOTH spawn paths (the holder-backed default and the in-process
#      ConPTY child, GHOZTTY_AGENT_PTY_HOLDER=0), while an ordinary variable
#      set the same way does arrive (the control that the dump is the agent's).
#   D  `--exit-on-revoke` exits 0 after consecutive 401 control dials; the same
#      relay without the flag is still redialing at the same point (control).
#
# isolation: none - this script never dials the app IPC endpoint. It drives
# agents it starts itself on pipes it names, with LOCALAPPDATA and
# GHOZTTY_AGENT_INSTANCE redirected below, so every guard name, heartbeat and
# state file is this run's own and the user's agents are unreachable by
# construction. The relay agents dial a loopback listener this script runs.
param(
    [string]$AgentExe = (Join-Path $PSScriptRoot '..\..\zig-out\bin\ghoztty-agent.exe'),
    [string]$ClientExe = (Join-Path $PSScriptRoot '..\..\zig-out\bin\remote-test-client.exe')
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')  # T1036: Assert-GhozttyIsolatedAgent
. (Join-Path $PSScriptRoot 'lib\AgentLineage.ps1')
. (Join-Path $PSScriptRoot 'lib\TestClient.ps1')
$ClientExe = Resolve-RemoteTestClient -ClientExe $ClientExe

$script:passes = 0
$script:failures = 0
function Assert([string]$name, [bool]$cond) {
    if ($cond) { Write-Host "  PASS $name"; $script:passes++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:failures++ }
}
function Say($m) { Write-Host $m }

if (-not (Test-Path $AgentExe)) {
    Write-TestAssertedNothing -Label 'AGENT-ROLE-GUARD' `
        -Reason "agent not found: $AgentExe (build with: zig build agent -Doptimize=Debug)"
}
if (-not ($ClientExe -and (Test-Path $ClientExe))) {
    Write-TestAssertedNothing -Label 'AGENT-ROLE-GUARD' `
        -Reason "remote-test-client not found ($(Get-RemoteTestClientBuildCommand))"
}
$AgentExe = (Resolve-Path $AgentExe).Path

# The variables pty_child.PtySpawner.agent_private_env strips. Read from the
# source, so a name added there is asserted here without an edit.
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$privateVars = @()
$ptySrc = Join-Path $repo 'src\remote\agent\pty_child.zig'
if (Test-Path $ptySrc) {
    $m = [regex]::Match((Get-Content $ptySrc -Raw), 'agent_private_env\s*=\s*\[_\]\[\]const u8\{([^}]*)\}')
    if ($m.Success) {
        $privateVars = @([regex]::Matches($m.Groups[1].Value, '"([A-Z_]+)"') | ForEach-Object { $_.Groups[1].Value })
    }
}
Say "== private variables under test: $($privateVars -join ', ')"
if (@($privateVars).Count -eq 0) {
    Write-TestAssertedNothing -Label 'AGENT-ROLE-GUARD' `
        -Reason 'could not read agent_private_env from src\remote\agent\pty_child.zig'
}

$savedLocalAppData = $env:LOCALAPPDATA
$savedInstance = Get-GhozttyAgentLineage
$inst = 't1967' + ([guid]::NewGuid().ToString('N').Substring(0, 8))
$root = Join-Path $env:TEMP "ghoztty-t1967-$inst"
$started = New-Object System.Collections.ArrayList
$relayJob = $null
$secret = "t1967-secret-$inst"

# Start an agent with extra environment variables set only for that launch.
# Returns the Process (handle cached - the T351 ExitCode trap).
function Start-Agent([string]$tag, [string[]]$agentArgs, [hashtable]$extraEnv) {
    $saved = @{}
    foreach ($k in $extraEnv.Keys) {
        $saved[$k] = [Environment]::GetEnvironmentVariable($k, 'Process')
        [Environment]::SetEnvironmentVariable($k, [string]$extraEnv[$k], 'Process')
    }
    try {
        # T1036: the agent answers for its own endpoints before it is launched.
        Assert-GhozttyIsolatedAgent -Exe $AgentExe | Out-Null
        $p = Start-Process -FilePath $AgentExe -PassThru -WindowStyle Hidden `
            -ArgumentList $agentArgs `
            -RedirectStandardOutput (Join-Path $root "$tag.out.txt") `
            -RedirectStandardError (Join-Path $root "$tag.err.txt")
    } finally {
        foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k], 'Process') }
    }
    $null = $p.Handle
    [void]$started.Add($p)
    return $p
}

function Get-AgentErr([string]$tag) {
    $f = Join-Path $root "$tag.err.txt"
    if (Test-Path $f) { return [string](Get-Content $f -Raw) }
    return ''
}

# Wait (wall clock) for a file whose content matches a pattern.
function Wait-FileMatch([string]$path, [string]$pattern, [int]$timeoutMs) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $timeoutMs) {
        if (Test-Path $path) {
            $t = [string](Get-Content $path -Raw -ErrorAction SilentlyContinue)
            if ($t -match $pattern) { return $true }
        }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

# The heartbeat a daemon of a role writes under the redirected LOCALAPPDATA.
function Find-Heartbeat([string]$role, [int]$agentPid, [int]$timeoutMs) {
    $dir = Join-Path $root 'ghoztty'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $timeoutMs) {
        foreach ($f in @(Get-ChildItem -Path $dir -Filter '*.heartbeat' -ErrorAction SilentlyContinue)) {
            $t = [string](Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue)
            if ($t -match "^$agentPid\r?\nrole=$role\r?\n") { return $f.FullName }
        }
        Start-Sleep -Milliseconds 200
    }
    return $null
}

function Wait-Exit($p, [int]$timeoutMs) {
    if ($null -eq $p) { return $false }
    return $p.WaitForExit($timeoutMs)
}

# Dump a session's environment through the agent on $pipe; returns a hashtable
# of NAME -> value ($null when the dump never arrived).
function Get-SessionEnv([string]$tag, [string]$pipe) {
    $envFile = Join-Path $root "$tag.env.txt"
    $c = Start-Process -FilePath $ClientExe -PassThru -WindowStyle Hidden `
        -ArgumentList "--pipe=$pipe --exec `"set > $envFile`" --timeout 4" `
        -RedirectStandardOutput (Join-Path $root "$tag.client.out") `
        -RedirectStandardError (Join-Path $root "$tag.client.err")
    $null = $c.Handle
    if (-not $c.WaitForExit(30000)) { Stop-Process -Id $c.Id -Force -ErrorAction SilentlyContinue }
    if (-not (Wait-FileMatch $envFile '(?im)^path=' 6000)) { return $null }
    $vars = @{}
    foreach ($line in (Get-Content $envFile)) {
        $i = $line.IndexOf('=')
        if ($i -gt 0) { $vars[$line.Substring(0, $i).ToUpperInvariant()] = $line.Substring($i + 1) }
    }
    return $vars
}

function Stop-Started {
    foreach ($p in $started) {
        if ($null -ne $p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    }
}

try {
    New-Item -ItemType Directory -Force $root | Out-Null
    New-Item -ItemType Directory -Force (Join-Path $root 'ghoztty') | Out-Null
    $env:LOCALAPPDATA = $root
    $env:GHOZTTY_AGENT_INSTANCE = $inst
    $stateDir = Get-GhozttyAgentStateDir -Root $root -Instance $inst
    New-Item -ItemType Directory -Force $stateDir | Out-Null

    # ---------------------------------------------------------------------
    # The loopback "relay": every request is answered 401, which is what a
    # revoked device credential gets. Its log counts the dials.
    $portFile = Join-Path $root 'relay.port'
    $relayLog = Join-Path $root 'relay.log'
    $relayJob = Start-Job -ScriptBlock {
        param($portFile, $logPath)
        $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
        $l.Start()
        Set-Content -Path $portFile -Value ([string]$l.LocalEndpoint.Port) -Encoding ascii
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($sw.Elapsed.TotalSeconds -lt 300) {
            if (-not $l.Pending()) { Start-Sleep -Milliseconds 50; continue }
            $c = $l.AcceptTcpClient()
            try {
                $s = $c.GetStream()
                $s.ReadTimeout = 3000
                $buf = New-Object byte[] 8192
                $req = ''
                while ($req -notmatch "`r`n`r`n") {
                    $n = $s.Read($buf, 0, $buf.Length)
                    if ($n -le 0) { break }
                    $req += [Text.Encoding]::ASCII.GetString($buf, 0, $n)
                }
                $first = ($req -split "`r`n")[0]
                Add-Content -Path $logPath -Value "401 $first" -Encoding ascii
                $resp = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 401 Unauthorized`r`nContent-Length: 7`r`nConnection: close`r`n`r`nrevoked")
                $s.Write($resp, 0, $resp.Length)
                $s.Flush()
            } catch {
            } finally { $c.Close() }
        }
        $l.Stop()
    } -ArgumentList $portFile, $relayLog
    $null = Wait-FileMatch $portFile '^\d+' 15000
    $relayPort = 0
    if (Test-Path $portFile) { $relayPort = [int]((Get-Content $portFile -Raw).Trim()) }
    $relayUrl = "http://127.0.0.1:$relayPort"
    Say "  401 relay at $relayUrl"
    $relayEnv = @{ GHOSTTY_DEVICE_TOKEN = $secret; GHOSTTY_AGENT_NO_SELFUPDATE = '1' }

    # ---------------------------------------------------------------------
    Say '== A: a session agent and a relay agent run side by side'
    # ---------------------------------------------------------------------
    # The session agent carries EVERY private variable, exactly as one launched
    # by a supervisor that sets them would - section C reads them back out of
    # its shells, and section B points a relay at the heartbeat it names.
    $sessHb = Join-Path $root 'session.heartbeat'
    $sessPipe = '\\.\pipe\ghoztty-agent-' + $inst
    $sessEnv = @{
        GHOSTTY_AGENT_HEARTBEAT = $sessHb
        GHOSTTY_AGENT_LOCK = (Join-Path $root 'session.lock')
        GHOSTTY_AGENT_NO_SELFUPDATE = '1'
        GHOSTTY_DEVICE_TOKEN = $secret
        GHOZTTY_T1967_KEEP = "kept-$inst"
    }
    foreach ($v in $privateVars) { if (-not $sessEnv.ContainsKey($v)) { $sessEnv[$v] = "leak-$inst" } }
    $sessArgs = @("--listen-pipe=$sessPipe", "--port-file=$(Join-Path $stateDir 'port.json')",
        "--sessions-file=$(Join-Path $stateDir 'sessions.json')", '--headless')
    $sess = Start-Agent 'session' $sessArgs $sessEnv
    Assert 'A1 the session agent wrote its heartbeat as role listen-pipe' (
        Wait-FileMatch $sessHb "^$($sess.Id)\r?\nrole=listen-pipe" 15000)

    $relay1 = Start-Agent 'relay1' @("--relay=$relayUrl", '--headless') $relayEnv
    $relay1Hb = Find-Heartbeat 'relay' $relay1.Id 15000
    Assert 'A2 the relay agent took its own guard and wrote a role=relay heartbeat' ($null -ne $relay1Hb)
    Assert 'A3 the relay agent is running beside the session agent' (-not $relay1.HasExited)
    Assert 'A4 the session agent is still running beside the relay agent' (-not $sess.HasExited)

    # Control: same role still excludes - a second session agent is refused.
    $sess2 = Start-Agent 'session2' @("--listen-pipe=$sessPipe-dup", '--headless') @{ GHOSTTY_AGENT_HEARTBEAT = $sessHb }
    $sess2Exited = Wait-Exit $sess2 15000
    Assert 'A5 control: a second session agent is refused (exit 183)' ($sess2Exited -and $sess2.ExitCode -eq 183)

    # ---------------------------------------------------------------------
    Say '== B: a relay takeover that inherited the session agent''s heartbeat kills nobody'
    # ---------------------------------------------------------------------
    $relayEnvInherited = @{ GHOSTTY_AGENT_HEARTBEAT = $sessHb }
    foreach ($k in $relayEnv.Keys) { $relayEnvInherited[$k] = $relayEnv[$k] }
    $relay2 = Start-Agent 'relay2' @("--relay=$relayUrl", '--headless', '--force-replace') $relayEnvInherited
    $relay2Exited = Wait-Exit $relay2 20000
    Assert 'B1 the challenger yielded with exit 183' ($relay2Exited -and $relay2.ExitCode -eq 183)
    Assert 'B2 it said the guard is held by a different kind of agent' (
        (Get-AgentErr 'relay2') -match 'held by a different kind of agent')
    Assert 'B3 the session agent that owns the panes is still running' (-not $sess.HasExited)
    Assert 'B4 the relay holder was not killed either' (-not $relay1.HasExited)

    # Positive control: without the inherited override the same launch DOES
    # replace the relay holder - force-replace has teeth when roles match.
    $relay3 = Start-Agent 'relay3' @("--relay=$relayUrl", '--headless', '--force-replace') $relayEnv
    $relay1Gone = Wait-Exit $relay1 20000
    Assert 'B5 control: --force-replace replaced the same-role relay holder' $relay1Gone
    $relay3Hb = Find-Heartbeat 'relay' $relay3.Id 15000
    Assert 'B6 control: the replacement holds the relay guard' ($null -ne $relay3Hb -and -not $relay3.HasExited)
    Assert 'B7 the session agent survived the same-role takeover beside it' (-not $sess.HasExited)

    # ---------------------------------------------------------------------
    Say '== C: a pane shell never sees the agent''s private variables'
    # ---------------------------------------------------------------------
    $holderVars = Get-SessionEnv 'c-holder' $sessPipe
    Assert 'C1 the holder-backed session dumped its environment' ($null -ne $holderVars)
    if ($null -ne $holderVars) {
        Assert 'C2 control: an ordinary variable set on the agent reached the shell' (
            $holderVars['GHOZTTY_T1967_KEEP'] -eq "kept-$inst")
        foreach ($v in $privateVars) {
            Assert "C3 holder-backed shell has no $v" (-not $holderVars.ContainsKey($v))
        }
        $leaked = @($holderVars.Values | Where-Object { $_ -like "*$secret*" })
        Assert 'C4 the device token value appears nowhere in the holder-backed shell' ($leaked.Count -eq 0)
    }

    # The in-process ConPTY child (the fallback path) - a fresh session agent,
    # since two of that role cannot run at once.
    Stop-Started
    $null = Wait-Exit $sess 10000
    $inprocEnv = @{}
    foreach ($k in $sessEnv.Keys) { $inprocEnv[$k] = $sessEnv[$k] }
    $inprocEnv['GHOZTTY_AGENT_PTY_HOLDER'] = '0'
    $inprocEnv['GHOSTTY_AGENT_HEARTBEAT'] = (Join-Path $root 'session-inproc.heartbeat')
    $inprocPipe = "$sessPipe-inproc"
    $sessIn = Start-Agent 'session-inproc' @("--listen-pipe=$inprocPipe", '--headless') $inprocEnv
    $null = Wait-FileMatch (Join-Path $root 'session-inproc.heartbeat') "^$($sessIn.Id)" 15000
    $inVars = Get-SessionEnv 'c-inproc' $inprocPipe
    Assert 'C5 the in-process session dumped its environment' ($null -ne $inVars)
    if ($null -ne $inVars) {
        Assert 'C6 control: the ordinary variable reached the in-process shell' (
            $inVars['GHOZTTY_T1967_KEEP'] -eq "kept-$inst")
        foreach ($v in $privateVars) {
            Assert "C7 in-process shell has no $v" (-not $inVars.ContainsKey($v))
        }
        $leakedIn = @($inVars.Values | Where-Object { $_ -like "*$secret*" })
        Assert 'C8 the device token value appears nowhere in the in-process shell' ($leakedIn.Count -eq 0)
    }
    Stop-Started

    # ---------------------------------------------------------------------
    Say '== D: --exit-on-revoke leaves once the relay rejects the credential'
    # ---------------------------------------------------------------------
    $dialsBefore = 0
    if (Test-Path $relayLog) { $dialsBefore = @(Get-Content $relayLog).Count }
    $revoke = Start-Agent 'revoke' @("--relay=$relayUrl", '--headless', '--exit-on-revoke') $relayEnv
    $revokeExited = Wait-Exit $revoke 45000
    Assert 'D1 the --exit-on-revoke relay exited on its own' $revokeExited
    Assert 'D2 ...with exit code 0 (a supervisor does not restart it)' ($revokeExited -and $revoke.ExitCode -eq 0)
    Assert 'D3 ...and said the credential was revoked' ((Get-AgentErr 'revoke') -match 'revoked; exiting \(--exit-on-revoke\)')
    $dialsRevoke = 0
    if (Test-Path $relayLog) { $dialsRevoke = @(Get-Content $relayLog).Count - $dialsBefore }
    Assert "D4 it took at least two rejected dials ($dialsRevoke)" ($dialsRevoke -ge 2)

    # Control: the same relay without the flag keeps redialing past that point.
    $dialsMark = 0
    if (Test-Path $relayLog) { $dialsMark = @(Get-Content $relayLog).Count }
    $stay = Start-Agent 'stay' @("--relay=$relayUrl", '--headless') $relayEnv
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $stayDials = 0
    while ($sw.Elapsed.TotalSeconds -lt 45) {
        if ($stay.HasExited) { break }
        if (Test-Path $relayLog) { $stayDials = @(Get-Content $relayLog).Count - $dialsMark }
        if ($stayDials -ge 3) { break }
        Start-Sleep -Milliseconds 250
    }
    Assert "D5 control: without the flag the relay was rejected $stayDials times" ($stayDials -ge 3)
    Assert 'D6 control: ...and is still running, redialing' (-not $stay.HasExited)
    Stop-Started

    Complete-TestBody  # T1039: the run reached the end of its body
} finally {
    Stop-Started
    if ($null -ne $relayJob) {
        Stop-Job -Job $relayJob -ErrorAction SilentlyContinue
        Remove-Job -Job $relayJob -Force -ErrorAction SilentlyContinue
    }
    $env:LOCALAPPDATA = $savedLocalAppData
    Restore-GhozttyAgentLineage -Saved $savedInstance
    Start-Sleep -Milliseconds 300
    Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
}

# --- stamp (T783) -----------------------------------------------------------
if ($script:failures -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard agent-role-guard -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-TestVerdict -Label 'AGENT-ROLE-GUARD' -Pass $script:passes -Fail $script:failures
