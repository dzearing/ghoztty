# T158/T1572 acceptance: `--session-persistence=false` actually stops a restore,
# and a launch without it actually restores - the live half of what used to be
# section C of persistence-flag.ps1.
#
#   powershell -NoProfile -File test\win32\persistence-restore.ps1
#
# WHY THIS IS ITS OWN SCRIPT (T1572). persistence-flag.ps1 is a member of the
# harness floor (scripts\lib\HarnessFloor.ps1), whose membership rule is that a
# member is a static sweep: no GUI, no app launch, no `zig build`. Its sweep and
# its sweep's teeth (sections A and B) meet that rule; this live control does
# not - it builds a two-pane window, kills the app and relaunches it twice. Left
# inside the floor it made the lane need a desktop and a fresh Debug build, and
# it was the floor's one recurring false red (T1572's progress log: four
# sweeps scored persistence-flag red on C2 and each went green alone). Its
# subject is the PRODUCT - does a relaunch restore, and does the flag stop it -
# so it is made standing the way every product script is: by its own row in
# scripts\guard-due.ps1, which goes due when the restore code changes.
#
# WHAT IS ASSERTED
#
#   C1  a two-pane window built under persistence is on disk before the kill
#   C2  a relaunch with no persistence flag RESTORES it, and the restored pane
#       is LIVE (input reaches its child), not a picture
#   C3  a relaunch WITH --session-persistence=false restores nothing - and C2
#       proved there was something to refuse, so a restore dead in both arms
#       cannot read as a correct refusal
#   Z   no test-desktop app ever took the user's foreground
#
# Hermetic: per-run LOCALAPPDATA, per-run agent binary override, a private IPC
# pipe suffix, and it only ever kills ghoztty processes launched from this
# repo's zig-out, in this run's own agent lineage. Runs on the BACKGROUND test
# desktop.
param(
    [string]$ExePath,
    [string]$AgentExe,
    [switch]$Interactive
)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

# T1494: this run's own AGENT lineage, minted ahead of the first reset, so the
# scoped kill below never takes another lane's or the dev install's agent.
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
[void](Set-GhozttyTestAgentLineage -Tag 'persrest')
$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }
$agent = Join-Path $repo 'zig-out\bin\ghoztty-agent.exe'
if ($AgentExe) { $agent = $AgentExe }

$script:pass = 0
$script:fail = 0
$root = Join-Path $env:TEMP "ghoztty-persistence-restore-$PID"
New-Item -ItemType Directory -Force $root | Out-Null

# T652: "attached is not alive" - the restored pane is proved by typing into
# it, not by finding it in a tree.
. (Join-Path $PSScriptRoot 'lib\PaneLiveness.ps1')
# T350: refuse a non-debug zig-out before anything is launched.
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
Assert-GhozttyIsolatedBuild -Exe $exe

# Write-Host, not the pipeline: a helper that asserts must never also return a
# value, or its return silently becomes an array (T217 batch 5).
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}
function Say($m) { Write-Host $m }

function Stop-RepoInstances {
    # T351: one shared, path-exact kill (lib\CleanSlate.ps1) instead of a private
    # copy - the filter this replaced also matched a detached instance running from
    # zig-out-release (T53b), and every copy answered "does the agent go too" alone.
    [void](Stop-RepoGhoztty -Exe $exe -ScopeToLineage -SettleMs 700)
}

# Kill ONLY the app: the detached agent keeps its PTYs, which is the scenario a
# restore comes out of (quit / crash / upgrade).
function Stop-AppOnly {
    # T351: one shared, path-exact kill (lib\CleanSlate.ps1) instead of a private
    # copy - the filter this replaced also matched a detached instance running from
    # zig-out-release (T53b), and every copy answered "does the agent go too" alone.
    [void](Stop-RepoGhoztty -Exe $exe -ScopeToLineage -AppOnly -SettleMs 900)
}

# A PIPE, not a `>` redirect: `ghoztty +verb > file` from PowerShell writes zero
# bytes (T245).
function Invoke-Verb([string[]]$VerbArgs) {
    $out = (& $exe @VerbArgs 2>&1 | ForEach-Object { $_.ToString() } | Out-String)
    return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
}

function Get-Windows {
    $json = (& $exe +list --json 2>$null | Out-String).Trim()
    if (-not $json) { return @() }
    try { $doc = $json | ConvertFrom-Json } catch { return @() }
    if (-not $doc.data) { return @() }
    return @($doc.data.windows)
}

function Count-Leaves($node) {
    if (-not $node) { return 0 }
    if ($node.type -eq 'leaf') { return 1 }
    return (Count-Leaves $node.left) + (Count-Leaves $node.right)
}

# Panes in the window whose target is $target, or -1 when no such window.
function Get-PaneCount($target) {
    foreach ($w in Get-Windows) {
        if ([string]$w.target -ne $target) { continue }
        $n = 0
        foreach ($t in @($w.tabs)) { $n += (Count-Leaves $t.splits) }
        return $n
    }
    return -1
}

# Leaves recorded for $target in the on-disk manifest, or -1 when the file does
# not exist / does not mention it. T1663: the manifest is what a relaunch
# restores FROM, so this is the only way to ask "has the layout actually been
# recorded yet" - `+list --json` answers about the live app, which is a
# different question and the one this script used to confuse it with.
function Get-PersistedLeafCount($target) {
    $path = Get-DebugSessionLayoutPath
    if (-not $path -or -not (Test-Path $path)) { return -1 }
    try { $doc = (Get-Content $path -Raw -ErrorAction Stop) | ConvertFrom-Json }
    catch { return -1 }   # a torn read of the atomic rewrite: not "absent", just not yet
    foreach ($w in @($doc.windows)) {
        if ([string]$w.ipc_name -ne $target) { continue }
        $n = 0
        foreach ($t in @($w.tabs)) {
            foreach ($node in @($t.nodes)) {
                if ($node.PSObject.Properties.Name -contains 'leaf') { $n++ }
            }
        }
        return $n
    }
    return -1
}

# T1663: the layout write is DEBOUNCED (App.zig LAYOUT_SYNC_DEBOUNCE_MS = 250)
# and every further mutation RESTARTS the timer, so `+new-window` immediately
# followed by `+split` can leave the app with nothing on disk at all. Killing
# it there - and the kill is TerminateProcess, so there is no shutdown flush -
# destroys the fixture the two relaunches below are measured against, and the
# failure surfaces as "restore is broken" rather than "nothing was ever saved".
# That is what made C2 red on 2026-09-19 against a product with no code change
# in range: a 300 ms poll racing a 250 ms debounce is a coin toss that the box's
# speed decides.
function Wait-Persisted($target, $leaves, $timeoutSec = 20) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $seen = -1
    while ((Get-Date) -lt $deadline) {
        $seen = Get-PersistedLeafCount $target
        if ($seen -eq $leaves) { return $seen }
        Start-Sleep -Milliseconds 200
    }
    return $seen
}

function Wait-PaneCount($target, $count, $timeoutSec = 45) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $seen = -1
    while ((Get-Date) -lt $deadline) {
        $seen = Get-PaneCount $target
        if ($seen -eq $count) { return $seen }
        Start-Sleep -Milliseconds 400
    }
    return $seen
}


# ---------------------------------------------------------------------------
# C: the class negative control, live
# ---------------------------------------------------------------------------
$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN
$savedPipe = $env:GHOZTTY_PIPE_SUFFIX
$env:GHOZTTY_PIPE_SUFFIX = "-t158flag$PID"

Stop-RepoInstances
$tmp = Join-Path $root 'app'
New-Item -ItemType Directory -Force (Get-GhozttyAgentStateDir -Root $tmp) | Out-Null
$env:LOCALAPPDATA = $tmp
$env:GHOSTTY_LOCAL_AGENT_BIN = $agent

Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    Assert (Test-Path $exe) 'C0 ghoztty exe exists in zig-out'
    Assert (Test-Path $agent) 'C0 ghoztty-agent exe exists in zig-out'

    Say '== C1: build a two-pane window under persistence'
    # persistence: on, EXPLICITLY - this arm is the fixture the two relaunches
    # below are measured against, so it must not depend on what the default
    # happens to be.
    $app = Start-OnTestDesktop -Exe $exe -Arguments @('--session-persistence=true') `
        -StdErr (Join-Path $root 'app1.err.txt')
    if ((Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow') -eq [IntPtr]::Zero) {
        Say 'SETUP FAIL: no GhozttyWindow'; exit 1
    }
    $r = Invoke-Verb @('+new-window', '--target=t158-pair')
    Assert ($r.Code -eq 0) "C1a +new-window --target=t158-pair exits 0 (got $($r.Code))"
    $r = Invoke-Verb @('+split', '--target=t158-pair', '--direction=right')
    Assert ($r.Code -eq 0) "C1b +split exits 0 (got $($r.Code))"
    $panes = Wait-PaneCount 't158-pair' 2
    Assert ($panes -eq 2) "C1c the fixture window has 2 panes (got $panes)"
    # T1663. The fixture is not built until it is on DISK: everything below
    # measures a relaunch, and a relaunch reads the manifest, not the window
    # that was on screen a moment ago. Asserted rather than slept, so a write
    # that stops happening fails HERE, naming the fixture, instead of three
    # assertions later as a restore that did nothing.
    $saved = Wait-Persisted 't158-pair' 2
    Assert ($saved -eq 2) `
        "C1d the fixture window is PERSISTED before the app is killed (2 leaves on disk, got $saved)"

    Say '== C2: relaunch WITHOUT the flag - the panes come back'
    Stop-AppOnly
    $env:LOCALAPPDATA = $tmp
    $env:GHOSTTY_LOCAL_AGENT_BIN = $agent
    # persistence: on (default) - this is the hazard being demonstrated.
    $restored = Start-OnTestDesktop -Exe $exe -StdErr (Join-Path $root 'app2.err.txt')
    if ((Wait-TestWindow -ProcessId $restored.Pid -Class 'GhozttyWindow') -eq [IntPtr]::Zero) {
        Say 'SETUP FAIL: relaunched app has no GhozttyWindow'
    }
    $back = Wait-PaneCount 't158-pair' 2 60
    $restoreWorked = ($back -eq 2)
    Assert $restoreWorked `
        "C2a a launch with no persistence flag RESTORES the previous run's window (2 panes, got $back)"
    # T652: attached is not alive. A restored pane that came back as a frozen
    # picture satisfies every assertion above, so type into it and require an
    # answer - otherwise C3 could be passing against a restore that never worked.
    Assert (Test-PaneLive -Exe $exe -Target 't158-pair' -Tmp $root -Tag 'T158') `
        'C2b the restored pane is LIVE: input reaches its child and output returns'

    Say '== C3: relaunch WITH --session-persistence=false - they do not'
    Stop-AppOnly
    $env:LOCALAPPDATA = $tmp
    $env:GHOSTTY_LOCAL_AGENT_BIN = $agent
    $clean = Start-OnTestDesktop -Exe $exe -Arguments @('--session-persistence=false') `
        -StdErr (Join-Path $root 'app3.err.txt')
    if ((Wait-TestWindow -ProcessId $clean.Pid -Class 'GhozttyWindow') -eq [IntPtr]::Zero) {
        Say 'SETUP FAIL: the non-persistent app has no GhozttyWindow'
    }
    # Give the restore the same wall-clock it had in C2 before concluding it did
    # not happen: an assertion that fires immediately would pass on a slow box
    # for the wrong reason.
    $late = Wait-PaneCount 't158-pair' 2 20
    # T1663: "nothing came back" is only evidence that the FLAG works if
    # something would have come back without it. C2 answers that, so it is part
    # of this assertion - otherwise a restore that is dead in both arms reads as
    # a correct refusal, which is exactly how a dead restore hid here for a day.
    Assert (($late -eq -1) -and $restoreWorked) `
        ("C3a --session-persistence=false restores nothing, and C2 proved there was " +
            "something to refuse (expected no t158-pair window, got $late pane(s); " +
            "C2 restored=$restoreWorked)")
    $wins = @(Get-Windows)
    Assert ($wins.Count -eq 1) `
        "C3b the non-persistent launch comes up with exactly its own window (got $($wins.Count))"

} catch {
    # T1511: the foreground-leak checks below run after this try, so the try
    # cannot END in `Complete-TestBody`. It SCORES its own throw instead.
    Assert $false "the run threw and did not finish its sections: $($_.Exception.Message)"
} finally {
    Say '== cleanup'
    Remove-TestDesktop
    Stop-RepoInstances
    $env:LOCALAPPDATA = $savedLocalAppData
    if ($null -ne $savedAgentBin) { $env:GHOSTTY_LOCAL_AGENT_BIN = $savedAgentBin }
    else { Remove-Item env:GHOSTTY_LOCAL_AGENT_BIN -ErrorAction SilentlyContinue }
    $env:GHOZTTY_PIPE_SUFFIX = $savedPipe
    if ($script:fail -eq 0) { Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue }
    else { Say "artifacts preserved at $root" }
}

$fgSeen = @(Stop-TestForegroundWatch)
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @(Get-TestLaunchedPids)
    Assert ($fgSeen.Count -gt 0) 'Z1 the foreground watcher actually sampled (negative control)'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'Z2 no test-desktop app ever became foreground on the interactive desktop'
}

# --- stamp (T783/T1572) ----------------------------------------------------
# A clean green run RECORDS the content of everything this covers, so
# scripts\guard-due.ps1 can answer "has anybody relaunched the app against the
# restore code as it now stands?". Red stays due: only a green run re-stamps.
Complete-TestBody  # T1039/T1511: before the stamp, which is a child process reading this run's state
if ($script:fail -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard persistence-restore -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Say ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Label 'PERSISTENCE-RESTORE'
