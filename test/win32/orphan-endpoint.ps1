# T2892 acceptance: a launch whose forward goes UNANSWERED takes the endpoint
# over once its owner is gone, instead of exiting behind it.
#
# The live case (2026-11-10): the installed release crashed, Windows relaunched
# it (T2839), and the relaunch found the pipe still held by the crashed process
# - alive under Windows Error Reporting while the dump was written. It
# forwarded its window into a process that would never answer, logged
# forward-failed and exited. No terminal for 42 minutes.
#
# A FAKE OWNER stands in for the dying instance: a separate process that
# creates the endpoint's pipe instances and never reads or answers on them,
# exactly what a suspended / dying server looks like from the client side (a
# connect succeeds, the reply never comes).
#
#   O1. DYING owner (holds the pipe a few seconds, then exits): the launch stays
#       alive, logs that the forward went unanswered and NAMES the owner's pid
#       (read off the pipe itself), then takes the endpoint over once the owner
#       is gone - its own window exists and `+list` is answered by it.
#   O2. HUNG owner (never exits), with the wait shortened by the debug seam
#       GHOZTTY_ORPHAN_WAIT_MS: the launch gives up and exits, logging that the
#       endpoint never came free, and the exit ledger says forward-unanswered.
#   O3. HEALTHY owner (a real app): a second launch forwards and exits exactly
#       as before - ledger reason=forwarded, and no takeover was attempted.
#
# -NegativeControl runs O1 with a zero wait, which is the pre-fix behavior
# (give up at once): O1 must then score red, proving the arm can fail.
#
# House rules (T218): background desktop only, never the user's foreground,
# path-exact process handling (only this repo's zig-out ghoztty), private pipe
# suffix and LOCALAPPDATA, session persistence off (no agent needed).
#
#   powershell -NoProfile -File test\win32\orphan-endpoint.ps1
param(
    [string]$Exe,
    [switch]$NegativeControl,
    [switch]$Interactive
)
$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not $Exe) { $Exe = Join-Path $repo 'zig-out\bin\ghoztty.exe' }

# Isolate the IPC endpoint before any CLI call.
$suffix = "-t2892o$PID"
$env:GHOZTTY_PIPE_SUFFIX = $suffix
$pipeName = "ghoztty$suffix-$env:USERNAME"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

$root = Join-Path $env:TEMP "ghoztty-orphan-endpoint-$PID"
New-Item -ItemType Directory -Force $root | Out-Null
$savedLocalAppData = $env:LOCALAPPDATA
$savedTimeout = $env:GHOZTTY_IPC_TIMEOUT_MS
$savedWait = $env:GHOZTTY_ORPHAN_WAIT_MS
$savedPrompt = $env:GHOZTTY_HANDOFF_PROMPT
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Stop-TestProcs { [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 700) }

function Out-Text($f) { if (Test-Path $f) { Get-Content $f -Raw } else { '' } }

function Wait-PidGone([int]$procId, [int]$timeoutSec = 20) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        if ($null -eq (Get-Process -Id $procId -ErrorAction SilentlyContinue)) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

function Wait-LogLine([string]$file, [string]$pattern, [int]$timeoutSec = 10) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $hit = Select-String -LiteralPath $file -Pattern $pattern -ErrorAction SilentlyContinue | Select-Object -Last 1
        if ($hit) { return $hit.Line }
        Start-Sleep -Milliseconds 250
    }
    return $null
}

function Ledger-Reason([int]$procId) {
    $f = Join-Path $env:LOCALAPPDATA 'ghoztty\exit-log-debug.txt'
    $hit = Select-String -LiteralPath $f -Pattern "pid=$procId event=exit reason=(\S+)" -ErrorAction SilentlyContinue | Select-Object -Last 1
    if ($hit) { return $hit.Matches[0].Groups[1].Value }
    return ''
}

# The fake owner: creates eight instances of the endpoint pipe and never reads,
# writes or disconnects. HoldMs < 0 holds until killed.
$ownerScript = Join-Path $root 'fake-owner.ps1'
@'
param([string]$Name, [int]$HoldMs, [string]$Ready)
$servers = @()
for ($i = 0; $i -lt 8; $i++) {
    $servers += New-Object System.IO.Pipes.NamedPipeServerStream($Name,
        [System.IO.Pipes.PipeDirection]::InOut, 8,
        [System.IO.Pipes.PipeTransmissionMode]::Byte,
        [System.IO.Pipes.PipeOptions]::Asynchronous)
}
Set-Content -LiteralPath $Ready -Value $PID -Encoding ascii
if ($HoldMs -lt 0) { while ($true) { Start-Sleep -Seconds 1 } }
Start-Sleep -Milliseconds $HoldMs
'@ | Set-Content -LiteralPath $ownerScript -Encoding ascii

function Start-FakeOwner([int]$holdMs, [string]$tag) {
    $ready = Join-Path $root "owner-$tag.ready"
    Remove-Item -LiteralPath $ready -ErrorAction SilentlyContinue
    $o = Start-OnTestDesktop -Exe $psExe -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', $ownerScript, '-Name', $pipeName, '-HoldMs', "$holdMs", '-Ready', $ready) `
        -StdErr (Join-Path $root "owner-$tag.err.txt")
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline -and -not (Test-Path $ready)) { Start-Sleep -Milliseconds 100 }
    if (-not (Test-Path $ready)) { throw "fake owner $tag never created the pipe" }
    return [int]$o.Pid
}

function Launch-App([string]$tag) {
    $err = Join-Path $root "app-$tag.err.txt"
    $a = Start-OnTestDesktop -Exe $Exe -Arguments @('--session-persistence=false', "--title=t2892$tag") -StdErr $err
    return @{ Pid = [int]$a.Pid; Err = $err }
}

Stop-TestProcs
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$ownerPids = New-Object System.Collections.ArrayList

try {
    $env:LOCALAPPDATA = $root
    # A frozen owner holds a connection for the whole exchange timeout; keep
    # each one short so the arms measure the takeover, not the 30s default.
    $env:GHOZTTY_IPC_TIMEOUT_MS = '1500'
    Remove-Item Env:\GHOZTTY_HANDOFF_PROMPT -ErrorAction SilentlyContinue

    # ---- O1: a dying owner -------------------------------------------------
    Write-Host '== O1: owner holds the pipe without answering, then exits'
    if ($NegativeControl) { $env:GHOZTTY_ORPHAN_WAIT_MS = '0' } else { Remove-Item Env:\GHOZTTY_ORPHAN_WAIT_MS -ErrorAction SilentlyContinue }
    $owner = Start-FakeOwner 6000 'o1'
    [void]$ownerPids.Add($owner)
    $a = Launch-App 'o1'
    $line = Wait-LogLine $a.Err 'forward unanswered: the endpoint.s owner' 15
    Assert ($null -ne $line) 'O1 the launch logged that its forward went unanswered'
    Assert ($line -match "pid=$owner\b") "O1 the log names the pipe's real owner (pid=$owner), read off the pipe"
    Assert (Wait-PidGone $owner 20) 'O1 (setup) the fake owner exited'
    $took = Wait-LogLine $a.Err 'endpoint came free; this launch is now the app' 15
    Assert ($null -ne $took) 'O1 the launch took the endpoint over once the owner was gone'
    Assert ($null -ne (Get-Process -Id $a.Pid -ErrorAction SilentlyContinue)) 'O1 the launch is still running (it did not exit behind the owner)'
    $win = Wait-TestWindow -ProcessId $a.Pid -TimeoutMs 15000
    Assert ($null -ne $win -and [int64]$win -ne 0) 'O1 the launch has a window of its own'
    $list = (& $Exe +list --json 2>$null | Out-String)
    Assert ($list -match 't2892o1') 'O1 +list on the endpoint is answered by the launch (its window is listed)'
    Stop-TestProcs

    # ---- O2: a hung owner --------------------------------------------------
    Write-Host '== O2: owner holds the pipe without answering and never exits'
    $env:GHOZTTY_ORPHAN_WAIT_MS = '3000'
    $owner2 = Start-FakeOwner -1 'o2'
    [void]$ownerPids.Add($owner2)
    $b = Launch-App 'o2'
    Assert (Wait-PidGone $b.Pid 30) 'O2 the launch gave up and exited (a hung owner is not waited on forever)'
    Assert ($null -ne (Wait-LogLine $b.Err 'endpoint never came free' 5)) 'O2 the give-up was logged'
    Assert ((Ledger-Reason $b.Pid) -eq 'forward-unanswered') "O2 the exit ledger says forward-unanswered (got '$(Ledger-Reason $b.Pid)')"
    Stop-Process -Id $owner2 -Force -ErrorAction SilentlyContinue
    [void](Wait-PidGone $owner2 10)
    Remove-Item Env:\GHOZTTY_ORPHAN_WAIT_MS -ErrorAction SilentlyContinue

    # ---- O3: a healthy owner -----------------------------------------------
    Write-Host '== O3: a real app owns the endpoint; a second launch forwards as before'
    $env:GHOZTTY_IPC_TIMEOUT_MS = '15000'
    $env:GHOZTTY_HANDOFF_PROMPT = 'join'
    $first = Launch-App 'o3a'
    $deadline = (Get-Date).AddSeconds(30); $up = $false
    while ((Get-Date) -lt $deadline) {
        if ((& $Exe +list --json 2>$null | Out-String) -match 't2892o3a') { $up = $true; break }
        Start-Sleep -Milliseconds 500
    }
    Assert $up 'O3 (setup) the first app is up and answering'
    $second = Launch-App 'o3b'
    Assert (Wait-PidGone $second.Pid 30) 'O3 the second launch exited after forwarding'
    Assert ((Ledger-Reason $second.Pid) -eq 'forwarded') "O3 the exit ledger says forwarded (got '$(Ledger-Reason $second.Pid)')"
    Assert (-not ((Out-Text $second.Err) -match 'forward unanswered')) 'O3 no takeover was attempted against a healthy owner'
    Assert ($null -ne (Get-Process -Id $first.Pid -ErrorAction SilentlyContinue)) 'O3 the first app is untouched'
} catch {
    $script:fail++
    Write-Host "FAIL  script terminated: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "      at $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())"
} finally {
    foreach ($o in $ownerPids) { Stop-Process -Id $o -Force -ErrorAction SilentlyContinue }
    Remove-TestDesktop
    Stop-TestProcs
    $env:LOCALAPPDATA = $savedLocalAppData
    if ($null -ne $savedTimeout) { $env:GHOZTTY_IPC_TIMEOUT_MS = $savedTimeout } else { Remove-Item Env:\GHOZTTY_IPC_TIMEOUT_MS -ErrorAction SilentlyContinue }
    if ($null -ne $savedWait) { $env:GHOZTTY_ORPHAN_WAIT_MS = $savedWait } else { Remove-Item Env:\GHOZTTY_ORPHAN_WAIT_MS -ErrorAction SilentlyContinue }
    if ($null -ne $savedPrompt) { $env:GHOZTTY_HANDOFF_PROMPT = $savedPrompt } else { Remove-Item Env:\GHOZTTY_HANDOFF_PROMPT -ErrorAction SilentlyContinue }
}

$fgSeen = @(Stop-TestForegroundWatch)
Write-Host "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @(Get-TestLaunchedPids)
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'no process of this run ever became foreground on the interactive desktop'
}

Complete-TestBody

Write-Host ''
if ($NegativeControl) {
    Write-Host "NEGATIVE CONTROL: O1 ran with a zero wait (the pre-fix give-up); it must score red."
    Write-TestVerdict -Pass $script:pass -Fail $script:fail -Label 'ORPHAN ENDPOINT (negative control)'
    exit
}
if ($script:fail -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard orphan-endpoint -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Label 'ORPHAN ENDPOINT'
