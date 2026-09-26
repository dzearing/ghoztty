# Standalone-install adoption acceptance (T549): a consolidated local agent
# that finds a standalone 'Ghoztty Agent' install adopts it - sharing marked
# on, the standalone agent stopped only once idle, the uninstall run under the
# deny-terminate shield, and the contested Run-key value restored.
#
#   powershell -NoProfile -File test\win32\agent-adopt.ps1
#
# Covers: debug gating (no adoption without BOTH env overrides); the full
# adoption flow against a fake install dir + fake uninstall command (sharing
# marked, busy standalone left alone, idle standalone terminated, uninstall
# invoked exactly once, the shield refusing a Stop-Process against the
# adopting agent mid-uninstall, the deleted Run value restored, adoption.json
# done); the done short-circuit on restart; and the GHOSTTY_ADOPT_DISABLE
# kill switch.
#
# Section R (T890) is the other half: a read-only read-back of the REAL
# adoption on this box - standalone install dir gone, no product left under the
# agent UpgradeCode, the GhozttyAgent Run entry app-owned and relay-free, the
# sharing decision recorded. It asserts only where the adoption marker says it
# completed, and it never calls msiexec.
#
# Hermetic: GHOZTTY_AGENT_INSTANCE forks the single-instance guard, the state
# dir + fake install dir live under $env:TEMP (no spaces - the uninstall
# override is a raw CreateProcessW line), GHOSTTY_RELAY_ENV points at a
# nonexistent scratch path so the marked-on sharing uplink can never dial the
# real relay, and the Run value name is PID-scoped so the real GhozttyAgent
# entry is never touched. The "standalone agent" is a copied powershell.exe
# renamed ghoztty-agent.exe whose cmd child simulates a live session (the
# busy walk ignores ConPTY plumbing precisely so console stand-ins work).
param(
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe'
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
$script:passes = 0
$script:failures = 0

function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ } else { "  FAIL $name"; $script:failures++ }
}

# --- R: the REAL install on this box, read back (T890) -----------------------
# Sections 0-4 below prove the flow against a fake install dir and a fake
# uninstall command, which is the only way to exercise it repeatably. What they
# cannot say is whether the real adoption ever fired on a machine that actually
# carried the standalone 'Ghoztty Agent' MSI - the flow only runs when a RELEASE
# agent with the code starts, which the lazy-upgrade contract defers to a
# deliberate delivery. This section is that read-back, and it is pure
# observation: it opens no process, writes nothing, and NEVER calls msiexec (the
# 26.7.502 ghost product on this box must stay untouched - see T549's CAUTION).
#
# It asserts only on a box whose adoption marker says the adoption COMPLETED;
# anywhere else (a machine that never had the standalone install, or one where
# it is still pending) the retirement invariants are not yet owed, so the
# section skips with its reason and the fixture sections carry the run.
$script:realSkipped = 0
$agentUpgradeCode = '{7143BA66-FD7B-4D45-8555-E946D2141912}'
$appUpgradeCode   = '{5EB02044-7F06-498B-B7A9-7EFD65486CFB}'

function Get-RelatedProducts([string]$upgradeCode) {
    # MsiEnumRelatedProducts through the Installer COM object: a read-only
    # query, the same one adopt.zig's relatedProducts() makes.
    #
    # Returns an OBJECT carrying the count, never a bare array: `return ,@()`
    # scores as one element at an `@(...)` call site (lib\UnrollCount.ps1), and
    # that trap turned "no agent product is registered" into a FAIL here the
    # first time this section ran.
    $codes = New-Object System.Collections.Generic.List[string]
    $inst = New-Object -ComObject WindowsInstaller.Installer
    try { $list = $inst.GetType().InvokeMember('RelatedProducts', 'GetProperty', $null, $inst, @($upgradeCode)) }
    catch { $list = $null }
    if ($null -ne $list) {
        $n = $list.GetType().InvokeMember('Count', 'GetProperty', $null, $list, $null)
        for ($k = 0; $k -lt $n; $k++) {
            $codes.Add([string]$list.GetType().InvokeMember('Item', 'GetProperty', $null, $list, @($k)))
        }
    }
    return [pscustomobject]@{ Count = $codes.Count; Codes = ($codes -join ',') }
}

"== R: the real standalone install on this box is retired (T890)"
$realStateDir   = Join-Path $env:LOCALAPPDATA 'ghoztty\local-agent'
$realAdoptFile  = Join-Path $realStateDir 'adoption.json'
$realSharing    = Join-Path $realStateDir 'sharing.json'
$standaloneDir  = Join-Path $env:LOCALAPPDATA 'Programs\Ghoztty Agent'
$appInstallDir  = Join-Path $env:LOCALAPPDATA 'Programs\Ghoztty'
$realAdopt      = if (Test-Path -LiteralPath $realAdoptFile) { Get-Content -LiteralPath $realAdoptFile -Raw } else { '' }

if ($realAdopt -notmatch '"done"\s*:\s*true') {
    # skip-audit: the retirement invariants are only owed on a box that adopted
    "  SKIP R: this box has no completed adoption marker ($realAdoptFile) - nothing was adopted here"
    $script:realSkipped = 1
} else {
    Assert 'R1 the standalone install dir is gone' (-not (Test-Path -LiteralPath $standaloneDir))

    # Positive control first: the enumeration must be able to FIND a product, or
    # "no agent product" would be the same answer as "this query never works".
    $appProducts = Get-RelatedProducts $appUpgradeCode
    Assert 'R2a the MSI query works (the app product is found by its UpgradeCode)' ($appProducts.Count -ge 1)
    $agentProducts = Get-RelatedProducts $agentUpgradeCode
    if ($agentProducts.Count -gt 0) { "  (agent UpgradeCode still resolves to: $($agentProducts.Codes))" }
    Assert 'R2b no product is registered under the agent UpgradeCode' ($agentProducts.Count -eq 0)

    $runValue = (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' `
        -Name 'GhozttyAgent' -ErrorAction SilentlyContinue).GhozttyAgent
    Assert 'R3a the GhozttyAgent Run entry survived the uninstall' (-not [string]::IsNullOrWhiteSpace($runValue))
    Assert 'R3b it points at the app-managed agent, not the retired install' (
        $runValue -and $runValue -like "*$appInstallDir\ghoztty-agent.exe*" -and $runValue -notlike '*Ghoztty Agent*')
    Assert 'R3c it no longer carries the standalone relay flag' ($runValue -and $runValue -notmatch '--relay')

    Assert 'R4 the adoption marker records the sharing decision' ($realAdopt -match '"sharing_marked"\s*:\s*true')
    # Sharing continuity has two legal outcomes: marked ON (the box was serving),
    # or an explicit pre-existing opt-out, which adoption respects rather than
    # overriding. Either is fine; an unreadable/absent file is not.
    $sharingText = if (Test-Path -LiteralPath $realSharing) { Get-Content -LiteralPath $realSharing -Raw } else { '' }
    Assert 'R5 sharing.json is present and states a decision' ($sharingText -match '"enabled"\s*:\s*(true|false)')
    if ($sharingText -match '"enabled"\s*:\s*false') {
        "  NOTE R5: sharing reads disabled - the opt-out branch (adopt.zig respects an existing no)"
    }

    # cleanslate-exempt: reads the process table, kills nothing
    $stillRunning = @(Get-CimInstance Win32_Process -Filter "Name='ghoztty-agent.exe'" |
        Where-Object { $_.ExecutablePath -and $_.ExecutablePath -like "$standaloneDir*" })
    Assert 'R6 no agent is running out of the retired install' ($stillRunning.Count -eq 0)
}

$tmp = Join-Path $env:TEMP "ghoztty-t549-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null
$stateDir = Join-Path $tmp 'agent-state'
New-Item -ItemType Directory -Force $stateDir | Out-Null
$fakeDir = Join-Path $tmp 'standalone'
$portFile = Join-Path $stateDir 'port.json'
$sessFile = Join-Path $stateDir 'sessions.json'
$sharingFile = Join-Path $stateDir 'sharing.json'
$adoptFile = Join-Path $stateDir 'adoption.json'
$uninstLog = Join-Path $tmp 'uninstall.log'
$fakeUninstall = Join-Path $tmp 'fake-uninstall.cmd'
$pipe = "\\.\pipe\ghoztty-agent-t549-$PID"
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$runValueName = "GhozttyAgentT549-$PID"
$preRunValue = '"C:\app\ghoztty-agent.exe" "--listen-pipe=app-t549"'

if (-not (Test-Path $AgentExe)) {
    # Section R above needs no build, so its score is real and is kept; only
    # the fixture sections are skipped.
    "SKIP whole run: $AgentExe not built (zig build agent first)"
    Write-TestVerdict -Label 'T549 AGENT ADOPT' -Pass $script:passes -Fail $script:failures `
        -Skipped (1 + $script:realSkipped)
}

function Stop-TestProcs {
    # T351: deliberately NOT the shared Stop-RepoGhoztty. This script's subject is
    # a FAKE agent - a renamed powershell.exe under a `ghoztty-t549*` directory,
    # plus the real one launched with a `t549` listen-pipe - so what has to die is
    # picked out by those run markers, not by the exe path the shared kill matches.
    # cleanslate-exempt: picks this run's FAKE agents out by their t549 markers
    Get-CimInstance Win32_Process -Filter "Name='ghoztty-agent.exe'" |
        Where-Object { ($_.CommandLine -like '*t549*') -or ($_.ExecutablePath -like '*ghoztty-t549*') } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 300
}

function Start-TestAgent($outFile, $errFile) {
    $p = Start-Process -FilePath $AgentExe -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile `
        -ArgumentList "--listen-pipe=$pipe", "--port-file=$portFile", "--sessions-file=$sessFile", '--headless'
    $null = $p.Handle   # cache before any wait, or ExitCode reads empty (lib\ExitCodeAudit.ps1)
    return $p
}

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
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function New-FakeStandalone {
    New-Item -ItemType Directory -Force $fakeDir | Out-Null
    Copy-Item "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        (Join-Path $fakeDir 'ghoztty-agent.exe') -Force
}

"== 0: fake standalone install + pre-seeded app-owned Run value"
Stop-TestProcs
New-FakeStandalone
Set-ItemProperty -Path $runKey -Name $runValueName -Value $preRunValue
Assert 'fake install dir exists' (Test-Path (Join-Path $fakeDir 'ghoztty-agent.exe'))

$env:GHOZTTY_AGENT_INSTANCE = "t549$PID"
$env:GHOSTTY_RELAY_ENV = Join-Path $tmp 'no-such-relay.env'
$env:GHOSTTY_ADOPT_INSTALL_DIR = $fakeDir
$env:GHOSTTY_ADOPT_RUNKEY_NAME = $runValueName
$env:GHOSTTY_ADOPT_INTERVAL_MS = '1000'
try {
    "== 1: debug gate - install dir override alone is NOT enough to adopt"
    # No GHOSTTY_ADOPT_UNINSTALL_CMD: a debug agent must refuse to act.
    $a1 = Start-TestAgent "$tmp\a1.out" "$tmp\a1.err"
    Assert 'gated agent came up' (Wait-ForText $portFile 'pipe' 15)
    Start-Sleep -Seconds 3
    Assert 'no adoption without both overrides' ((Read-Shared "$tmp\a1.err") -notmatch 'adoption')
    Assert 'sharing.json untouched by the gated agent' (-not (Test-Path $sharingFile))
    Stop-TestProcs

    "== 2: adoption - sharing marked, idle-stop honored, shielded uninstall, Run value restored"
    # The fake standalone: busy for ~10s (a cmd 'session' pinging), then idle
    # (only its conhost left, which the busy walk must ignore).
    $fake = Start-Process -FilePath (Join-Path $fakeDir 'ghoztty-agent.exe') -PassThru -WindowStyle Hidden `
        -ArgumentList '-NoProfile', '-Command', "& cmd /d /c 'ping -n 10 127.0.0.1 > nul'; Start-Sleep 600"
    $null = $fake.Handle
    Start-Sleep -Seconds 2
    $fakeKids = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($fake.Id)" |
        Where-Object { $_.Name -ne 'conhost.exe' })
    Assert 'positive control: fake standalone has a live session child' ($fakeKids.Count -ge 1)

    Remove-Item $portFile -ErrorAction SilentlyContinue
    $env:GHOSTTY_ADOPT_UNINSTALL_CMD = "$env:SystemRoot\System32\cmd.exe /d /c $fakeUninstall"
    $a2 = Start-TestAgent "$tmp\a2.out" "$tmp\a2.err"
    # The fake uninstall: records the run, tries to kill the adopting agent
    # (the shield must refuse it - this is exactly what the MSI's KillAgentCA
    # does), deletes the Run value and the install dir like the real MSI.
    @(
        '@echo off',
        "echo ran >> $uninstLog",
        "powershell -NoProfile -Command `"try { Stop-Process -Id $($a2.Id) -Force -ErrorAction Stop; 'kill-ok' } catch { 'kill-denied' }`" >> $uninstLog",
        "reg delete HKCU\Software\Microsoft\Windows\CurrentVersion\Run /v $runValueName /f > nul 2>&1",
        "rmdir /s /q $fakeDir",
        'exit /b 0'
    ) | Set-Content -Path $fakeUninstall -Encoding ascii

    Assert 'adopting agent came up' (Wait-ForText $portFile 'pipe' 15)
    Assert 'adoption announced' (Wait-ForText "$tmp\a2.err" 'adopting \(T549\)' 15)
    Assert 'sharing marked enabled' (Wait-ForText "$tmp\a2.err" 'sharing marked enabled' 15)
    Assert 'sharing.json says enabled' ((Read-Shared $sharingFile) -match '"enabled":true')
    Assert 'busy standalone put adoption into waiting' (Wait-ForText "$tmp\a2.err" 'waiting for idle' 20)
    Assert 'standalone NOT stopped while busy' (-not $fake.HasExited)

    # The cmd 'session' drains (~10s), then 3 idle polls at 1s land the stop.
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline -and -not $fake.HasExited) { Start-Sleep -Milliseconds 500 }
    Assert 'idle standalone was stopped' $fake.HasExited
    Assert 'stop was announced' (Wait-ForText "$tmp\a2.err" 'idle; stopped it' 10)

    Assert 'uninstall override ran' (Wait-ForText $uninstLog 'ran' 30)
    Assert 'adoption completed' (Wait-ForText "$tmp\a2.err" 'adoption complete' 30)
    Assert 'uninstall ran exactly once' (([regex]::Matches((Read-Shared $uninstLog), 'ran')).Count -eq 1)
    Assert 'shield refused the mid-uninstall kill' ((Read-Shared $uninstLog) -match 'kill-denied')
    Assert 'adopting agent survived its own uninstall step' (-not $a2.HasExited)
    Assert 'fake install dir removed by the uninstall' (-not (Test-Path $fakeDir))
    $restored = (Get-ItemProperty -Path $runKey -Name $runValueName -ErrorAction SilentlyContinue).$runValueName
    Assert 'deleted Run value was restored verbatim' ($restored -eq $preRunValue)
    Assert 'restore was announced' ((Read-Shared "$tmp\a2.err") -match 'restored the')
    Assert 'adoption.json records done' ((Read-Shared $adoptFile) -match '"done":true')
    Stop-TestProcs

    "== 3: restart - done short-circuits, no second adoption"
    Remove-Item $portFile -ErrorAction SilentlyContinue
    $a3 = Start-TestAgent "$tmp\a3.out" "$tmp\a3.err"
    Assert 'post-adoption agent came up' (Wait-ForText $portFile 'pipe' 15)
    Start-Sleep -Seconds 3
    Assert 'no re-adoption after done' ((Read-Shared "$tmp\a3.err") -notmatch 'adopting')
    Stop-TestProcs

    "== 4: kill switch - GHOSTTY_ADOPT_DISABLE=1 stops everything"
    Remove-Item $adoptFile -ErrorAction SilentlyContinue
    Remove-Item $portFile -ErrorAction SilentlyContinue
    New-FakeStandalone
    $env:GHOSTTY_ADOPT_DISABLE = '1'
    $a4 = Start-TestAgent "$tmp\a4.out" "$tmp\a4.err"
    Assert 'disabled agent came up' (Wait-ForText $portFile 'pipe' 15)
    Start-Sleep -Seconds 3
    Assert 'kill switch suppresses adoption' ((Read-Shared "$tmp\a4.err") -notmatch 'adoption|adopting')
    Complete-TestBody  # T1039: the run reached the end of its body
} finally {
    Stop-TestProcs
    Remove-ItemProperty -Path $runKey -Name $runValueName -ErrorAction SilentlyContinue
    foreach ($n in 'GHOZTTY_AGENT_INSTANCE','GHOSTTY_RELAY_ENV','GHOSTTY_ADOPT_INSTALL_DIR',
                   'GHOSTTY_ADOPT_RUNKEY_NAME','GHOSTTY_ADOPT_INTERVAL_MS',
                   'GHOSTTY_ADOPT_UNINSTALL_CMD','GHOSTTY_ADOPT_DISABLE') {
        Remove-Item "env:$n" -ErrorAction SilentlyContinue
    }
}

# --- stamp (T783) -----------------------------------------------------------
# This harness had a guard row from the start and no way to satisfy it: the row
# went DUE the moment anything it covers moved, and nothing here ever wrote a
# stamp, so it stayed DUE through every green run. A row that can only ever be
# due is worse than no row - it is the constant red that teaches the next turn
# to pass -NoGuardDue (found while working T1042).
#
# And only a run that looked at everything vouches for everything (T981): a run
# whose section R skipped never read the real retirement back, so it scores but
# does not stamp. This box adopted on 2026-08-31, so R asserts here.
if ($script:failures -eq 0 -and $script:realSkipped -eq 0) {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard agent-adopt -Repo $repo 2>&1 | ForEach-Object { "  $_" }
} elseif ($script:failures -eq 0) {
    "  not stamped: section R skipped, so this run does not vouch for the retirement read-back"
}

# MinPass = the full-run assertion count: an abort mid-run must never score a
# truncated run as ALL PASS. 26 fixture assertions + section R's 9, which are
# owed only on a box that actually adopted (hence the -realSkipped subtraction:
# a machine that never carried the standalone install still has a floor).
Write-TestVerdict -Label 'T549 AGENT ADOPT' -Pass $script:passes -Fail $script:failures `
    -Skipped $script:realSkipped -MinPass (35 - (9 * $script:realSkipped))
