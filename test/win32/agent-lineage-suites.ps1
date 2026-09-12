# T691 acceptance: an acceptance run cleans up after ITSELF, not after the box.
#
# WHAT THIS MEASURES
#
# T167 gave a sandbox its own agent lineage; nothing spent it. Every
# persistence-touching script here still opened by killing every ghoztty and
# ghoztty-agent running out of the repo - which is somebody else's agent (the
# dev install's, and on this box the go-loop's own panes), and which is also why
# two acceptance scripts could never run at the same time. T691 narrows that
# kill to "the processes THIS run owns" and converts the suites onto it.
#
# ARMS:
#
#   A  the naming, pure. A run-unique lineage inside the 24-char cap, the state
#      dir it implies, and the ownership predicate - including the prefix trap
#      that would make `local-agent-debug\` read as `local-agent-debug-sbx1\`.
#   B  the REFUSALS. A scoped kill that cannot scope both halves must throw, not
#      quietly widen back to the blunt one: a guarantee the suite is built on
#      has to fail loudly when it is not available.
#   C  the bystander. A debug agent that is NOT ours - standing in for the one
#      holding the loop's panes - is still running, and still holding its
#      session, after a scoped reset has run against it.
#   D  the capability that did not exist. Two converted persistence suites run
#      CONCURRENTLY and both report ALL PASS.
#
# -TeethCheck is C's self-test: it runs the same reset UNSCOPED, which is the
# world before this change, and C2 must then go RED. A check that has only ever
# been observed saying "fine" is indistinguishable from one that cannot say
# anything else - and this arm has already earned its keep: it is what caught
# the scoped kill silently matching nothing (a `, @()` return unrolling into a
# caller-started pipeline), which every other arm had scored as a pass.
#
# C3 stays green under -TeethCheck and is not weaker for it: the old kill took
# the bystander's PROCESS, not its files. What protects its files is the
# lineage-aware naming, whose teeth are A9/A10 here and the `layoutPath` unit
# test in src\apprt\win32\session_layout.zig.
#
# Considerate by construction: it only ever kills processes it started (by pid),
# and the whole point of the feature is that it needs to kill nothing else.
#
#   powershell -NoProfile -File test\win32\agent-lineage-suites.ps1
#   powershell -NoProfile -File test\win32\agent-lineage-suites.ps1 -TeethCheck
#   powershell -NoProfile -File test\win32\agent-lineage-suites.ps1 -SkipSuites
# suite-timeout-sec 900
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe',
    # C's teeth: reset UNSCOPED and require the bystander assertions to fail.
    [switch]$TeethCheck,
    # Skip D, which spends two real suite runs (minutes). For a quick pass over
    # the mechanism while iterating on it; a green run that skipped D has NOT
    # discharged the concurrency claim, and says so.
    [switch]$SkipSuites
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:passes = 0
$script:skipped = 0
$root = Join-Path $env:TEMP "ghoztty-t691-$PID"

. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\HarnessLeak.ps1')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\AgentLineage.ps1')

function Assert($name, $cond) {
    if ($cond) { Write-Host "  PASS $name"; $script:passes++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:failures++ }
}
function Say($m) { Write-Host $m }

# isolation: this script drives no app IPC endpoint of its own - arms A and B
# are pure, C starts a headless agent by path, and D shells out to two scripts
# that each isolate themselves. A suffix is set anyway so that anything which
# DOES reach the CLI cannot inherit the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 'lineagesuites' -Quiet)

Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null

# Every process this script starts, so cleanup is by pid. Killing by name, or by
# "*zig-out*", would take the loop's own agent with it - the exact rudeness this
# feature exists to make unnecessary.
$script:mine = New-Object System.Collections.Generic.List[int]

# T1127: a `--pty-host` holder escapes its agent's job on purpose, so it is
# neither in $script:mine nor a child of anything that is. Scope the backstop to
# the build under test.
Register-RepoBuildTeardown -Exe $Exe | Out-Null

New-Item -ItemType Directory -Force $root | Out-Null
$savedLad = $env:LOCALAPPDATA
$savedInst = $env:GHOZTTY_AGENT_INSTANCE

try {
    # ============================================================================
    "== A: the naming, pure"
    # ============================================================================

    $n1 = New-GhozttyAgentLineageName -Tag 'sessopen'
    Assert "A1 a lineage name is inside the 24-char cap" ($n1.Length -le 24 -and $n1.Length -gt 0)
    Assert "A2 it is run-unique (carries this pid)" ($n1 -like "*-$PID")
    $long = New-GhozttyAgentLineageName -Tag ('x' * 60)
    Assert "A3 an over-long tag is trimmed, never the pid - two runs stay distinct" `
        ($long.Length -le 24 -and $long -like "*-$PID")
    # The Zig side REJECTS an over-long value rather than truncating it, because
    # truncation would merge two sandboxes into one lineage. Composing inside the
    # cap here is what keeps a long tag from reading as "no lineage at all".
    Assert "A4 a hostile tag cannot smuggle a path separator" `
        ((New-GhozttyAgentLineageName -Tag 'a\b/c:d') -notmatch '[\\/:]')

    $dirNone = Get-GhozttyAgentStateDir -Root 'C:\r' -NoLineage
    Assert "A5 no lineage reproduces the legacy state dir" ($dirNone -eq 'C:\r\ghoztty\local-agent-debug')
    $dirOne = Get-GhozttyAgentStateDir -Root 'C:\r' -Instance 'sbx1'
    Assert "A6 a lineage names its own state dir" ($dirOne -eq 'C:\r\ghoztty\local-agent-debug-sbx1')

    # The two command lines a lineage owns, as the agent and the holder actually
    # spell them (LocalAgent.agentCommandLine, pty_host_spec.tempPath).
    $agentCmd = '"C:\z\ghoztty-agent.exe" "--listen-pipe=\\.\pipe\x" "--port-file=C:\r\ghoztty\local-agent-debug-sbx1\port.json" "--sessions-file=C:\r\ghoztty\local-agent-debug-sbx1\sessions.json"'
    $holderCmd = '"C:\z\ghoztty-agent.exe" --pty-host --spec "C:\t\ghoztty-ptyhost-sbx1-0123456789abcdef.json"'
    $foreignAgent = '"C:\z\ghoztty-agent.exe" "--listen-pipe=\\.\pipe\x" "--port-file=C:\r\ghoztty\local-agent-debug\port.json" "--sessions-file=C:\r\ghoztty\local-agent-debug\sessions.json"'
    $foreignHolder = '"C:\z\ghoztty-agent.exe" --pty-host --spec "C:\t\ghoztty-ptyhost-0123456789abcdef.json"'

    Assert "A7 our agent is recognised as ours" (Test-GhozttyAgentLineageOwned -CommandLine $agentCmd -Instance 'sbx1')
    Assert "A8 our pty holder is recognised as ours" (Test-GhozttyAgentLineageOwned -CommandLine $holderCmd -Instance 'sbx1')
    # The prefix trap, both directions. Without the trailing separator on the agent
    # marker, the box's own `local-agent-debug\` would read as a prefix match and a
    # scoped kill would be the blunt kill wearing a scope.
    Assert "A9 the box's own unsuffixed agent is NOT ours" (-not (Test-GhozttyAgentLineageOwned -CommandLine $foreignAgent -Instance 'sbx1'))
    Assert "A10 the box's own unsuffixed holder is NOT ours" (-not (Test-GhozttyAgentLineageOwned -CommandLine $foreignHolder -Instance 'sbx1'))
    Assert "A11 a lineage is not a prefix of a longer one" (-not (Test-GhozttyAgentLineageOwned -CommandLine $agentCmd -Instance 'sbx'))
    Assert "A12 another sandbox's agent is NOT ours" (-not (Test-GhozttyAgentLineageOwned -CommandLine $agentCmd -Instance 'sbx2'))

    # ============================================================================
    "== B: a scoped kill that cannot scope REFUSES"
    # ============================================================================

    function Test-Throws($block) {
        try { & $block | Out-Null; return $false } catch { return $true }
    }

    $env:GHOZTTY_AGENT_INSTANCE = $null
    Remove-Item env:GHOZTTY_AGENT_INSTANCE -ErrorAction SilentlyContinue
    Assert "B1 -ScopeToLineage with no lineage minted throws" `
        (Test-Throws { Stop-RepoGhoztty -Exe $Exe -ScopeToLineage -SettleMs 0 -TimeoutMs 500 })

    $env:GHOZTTY_AGENT_INSTANCE = "t691b-$PID"
    # Shadow the launch-record lookup to the "script does not use the harness" answer
    # ($null), which is the state the refusal exists for. Restored immediately.
    function Get-TestLaunchRecords { }
    Remove-Item function:Get-TestLaunchRecords
    Assert "B2 -ScopeToLineage without launch records throws for the app half" `
        (Test-Throws { Stop-RepoGhoztty -Exe $Exe -ScopeToLineage -SettleMs 0 -TimeoutMs 500 })
    . (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
    Assert "B3 -AgentOnly needs no launch records (nothing of ours to spare)" `
        (-not (Test-Throws { Stop-RepoGhoztty -Exe $Exe -ScopeToLineage -AgentOnly -SettleMs 0 -TimeoutMs 2000 }))
    Remove-Item env:GHOZTTY_AGENT_INSTANCE -ErrorAction SilentlyContinue

    # ============================================================================
    "== C: the bystander agent survives a scoped reset"
    # ============================================================================

    # The stand-in for the agent holding the loop's own panes: a debug-lineage agent
    # this script started, with NO instance suffix - i.e. exactly the lineage every
    # unconverted suite used to kill on sight.
    $byRoot = Join-Path $root 'bystander'
    $byDir = Join-Path $byRoot 'ghoztty\local-agent-debug'
    New-Item -ItemType Directory -Force $byDir | Out-Null
    $byPort = Join-Path $byDir 'port.json'
    $bySess = Join-Path $byDir 'sessions.json'
    $byPipe = "\\.\pipe\ghoztty-t691-bystander-$PID"

    $prevInst = $env:GHOZTTY_AGENT_INSTANCE
    $prevLad = $env:LOCALAPPDATA
    Remove-Item env:GHOZTTY_AGENT_INSTANCE -ErrorAction SilentlyContinue
    $env:LOCALAPPDATA = $byRoot
    # persistence: not applicable - a headless agent, started by path, opens no window.
    $by = Start-Process -FilePath $AgentExe -PassThru -WindowStyle Hidden `
        -ArgumentList "--listen-pipe=$byPipe", "--port-file=$byPort", "--sessions-file=$bySess", '--headless'
    # Cache the handle BEFORE the child can exit, or ExitCode reads back empty and a
    # refused agent scores as a running one (the box's Start-Process trap).
    $null = $by.Handle
    if ($null -eq $prevInst) { Remove-Item env:GHOZTTY_AGENT_INSTANCE -ErrorAction SilentlyContinue }
    else { $env:GHOZTTY_AGENT_INSTANCE = $prevInst }
    $env:LOCALAPPDATA = $prevLad
    $script:mine.Add([int]$by.Id)

    $deadline = (Get-Date).AddSeconds(12)
    while ((Get-Date) -lt $deadline -and -not (Test-Path $byPort)) { Start-Sleep -Milliseconds 250 }
    $byUp = (Test-Path $byPort) -and -not $by.HasExited
    Assert "C1 a bystander debug agent is up and published its port file" $byUp

    if (-not $byUp) {
        Say "  SKIP C2/C3: no bystander to be spared (it never came up)"
        $script:skipped += 2
    } else {
        # Now do what a converted suite does at its start: mint a lineage of our own
        # and reset. Under -TeethCheck the reset is the UNSCOPED one instead, which
        # is the pre-T691 world and must take the bystander down with it.
        [void](Set-GhozttyTestAgentLineage -Tag 'lineagec' -Quiet)
        if ($TeethCheck) {
            Say "  [teeth] resetting UNSCOPED - the pre-T691 kill. C2 must go red."
            [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 400)
        } else {
            [void](Stop-RepoGhoztty -Exe $Exe -ScopeToLineage -SettleMs 400)
        }

        $by.Refresh()
        Assert "C2 the bystander agent is still running after our reset" (-not $by.HasExited)
        # Still HOLDING, not merely alive: its state files are the sessions it owns,
        # and a reset that deleted them would have taken its panes without taking it.
        Assert "C3 the bystander's own state is untouched" ((Test-Path $byPort) -and (Test-Path $byDir))
        Remove-Item env:GHOZTTY_AGENT_INSTANCE -ErrorAction SilentlyContinue
    }

    # ============================================================================
    "== D: two converted persistence suites run CONCURRENTLY"
    # ============================================================================

    if ($SkipSuites) {
        Say "  SKIP D: -SkipSuites. The concurrency claim is NOT discharged by this run."
        $script:skipped += 3
    } else {
        $suites = @('session-open.ps1', 'session-close.ps1')
        $jobs = @()
        foreach ($s in $suites) {
            $path = Join-Path $PSScriptRoot $s
            $log = Join-Path $root ($s -replace '\.ps1$', '.log')
            # persistence: each suite isolates itself - its own pipe suffix, its own
            # LOCALAPPDATA and, since T691, its own agent lineage. That is precisely
            # what is under test here, so they are deliberately started together.
            $p = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Hidden `
                -ArgumentList '-NoProfile', '-File', $path `
                -RedirectStandardOutput $log -RedirectStandardError "$log.err"
            $null = $p.Handle
            $jobs += [pscustomobject]@{ Name = $s; Proc = $p; Log = $log }
        }

        foreach ($j in $jobs) {
            if (-not $j.Proc.WaitForExit(600 * 1000)) {
                Stop-Process -Id $j.Proc.Id -Force -ErrorAction SilentlyContinue
            } else { $j.Proc.WaitForExit() }
        }

        foreach ($j in $jobs) {
            $text = if (Test-Path $j.Log) { Get-Content $j.Log -Raw } else { '' }
            $last = ''
            if ($text) {
                $lines = @($text -split "`r?`n" | Where-Object { $_.Trim() -ne '' })
                if ($lines.Count -gt 0) { $last = $lines[-1].Trim() }
            }
            # The verdict is read off the script's own last line, not off its exit
            # code: a GUI-subsystem child's exit code reads back empty often enough
            # that the box notes warn against gating on it.
            Assert "D1 $($j.Name) reports ALL PASS while the other suite was running" ($last -like 'ALL PASS*')
            if ($last -notlike 'ALL PASS*') { Say "      last line: $last" ; Say "      log: $($j.Log)" }
        }

        # And the point of it: neither run took the other down. A suite that was
        # killed mid-way does not print a verdict at all, so D1 already covers that
        # - this names it, because "they interfered" is what a reader wants told.
        $bothGreen = @($jobs | Where-Object {
                $t = if (Test-Path $_.Log) { Get-Content $_.Log -Raw } else { '' }
                $t -match '(?m)^ALL PASS'
            }).Count
        Assert "D2 BOTH concurrent suites finished green (the capability T691 adds)" ($bothGreen -eq $suites.Count)
    }

    # T1039: the LAST statement of the try body. Reaching it is what says every
    # section above actually ran, rather than that nothing had failed yet when
    # the body unwound.
    Complete-TestBody
} finally {
    # Cleanup - by pid, never by name. Killing by name, or by "*zig-out*", would
    # take the loop's own agent with it, which is the rudeness this whole task
    # exists to end.
    foreach ($id in $script:mine) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
    if ($null -eq $savedInst) { Remove-Item env:GHOZTTY_AGENT_INSTANCE -ErrorAction SilentlyContinue }
    else { $env:GHOZTTY_AGENT_INSTANCE = $savedInst }
    $env:LOCALAPPDATA = $savedLad
    Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
}

# --- stamp (T783) -----------------------------------------------------------
# A run that SKIPPED D has not discharged the concurrency claim, so it must not
# clear the guard either - the stamp says "this harness has answered its
# question over this code", and a -SkipSuites run has answered three quarters
# of it.
if ($script:failures -eq 0 -and -not $SkipSuites -and -not $TeethCheck) {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard agent-lineage-suites -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:passes -Fail $script:failures -Skipped $script:skipped -Unit 'checks'
