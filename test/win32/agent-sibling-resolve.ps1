# T1619 acceptance: the app finds ghoztty-agent.exe BESIDE ITS OWN EXE when
# nothing tells it where the agent is - the branch every delivered build takes.
#
# The gap: every other acceptance script that starts the agent names it through
# GHOSTTY_LOCAL_AGENT_BIN, so `LocalAgent.agentBinary`'s default branch (the
# sibling of our own exe, src\apprt\win32\LocalAgent.zig) had never once run
# under test. An install that delivered the agent but resolved it wrong would
# have passed every harness here and opened every pane without persistence.
#
# Both arms run with the override REMOVED from the environment, and are scored by
# outcome - which process is running, whether the pane answers - never by trusting
# the app's own log alone:
#
#   B (first, on purpose): a lone copy of ghoztty.exe in a directory with NO
#      agent beside it. The pane must still come up and answer (the documented
#      plain-shell fallback), promptly, with no agent process started for this
#      run's lineage, and the app must SAY why ("local agent binary not found at
#      <that directory>\ghoztty-agent.exe"). Run before A so no agent of this
#      lineage exists yet for the app to dial instead of spawning.
#   A: zig-out's ghoztty.exe, whose sibling is zig-out's ghoztty-agent.exe. The
#      agent this run's lineage spawns must be THAT file (ExecutablePath), the
#      pane must answer, and `+sessions` must list the pane's session - i.e. the
#      persistence path is live, not merely an agent that happens to be running.
#
# Hermetic: a per-run LOCALAPPDATA, agent lineage and IPC pipe suffix, run on a
# BACKGROUND Win32 desktop; the arm-B copy lives under the repo's temp\ so the
# path-exact kill (lib\CleanSlate.ps1) is allowed to reach it.
#
#   powershell -NoProfile -File test\win32\agent-sibling-resolve.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe',
    [switch]$Interactive
)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
$instance = Set-GhozttyTestAgentLineage -Tag 'sibling' -Quiet

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:passes = 0
$root = Join-Path $env:TEMP "ghoztty-sibling-resolve-$PID"
# The arm-B copy must sit under the repo: Stop-RepoGhoztty refuses anything else.
$loneDir = Join-Path $script:CleanSlateRepo "temp\t1619-lone-$PID"
$loneExe = Join-Path $loneDir 'ghoztty.exe'

. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

function Assert($name, $cond) {
    if ($cond) { Write-Host "  PASS $name"; $script:passes++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:failures++ }
}
function Say($m) { Write-Host $m }

function Stop-TestProcs {
    [void](Stop-RepoGhoztty -Exe $Exe -ScopeToLineage -SettleMs 700)
    if (Test-Path $loneExe) { [void](Stop-RepoGhoztty -Exe $loneExe -ScopeToLineage -SettleMs 700) }
}

function Run-CliArgs($cli, $argv, $out, $timeoutSec = 15) {
    # persistence: on (default) - the agent under test only owns sessions when persistence is on.
    $p = Start-Process -FilePath $cli -WindowStyle Hidden -PassThru `
        -ArgumentList $argv -RedirectStandardOutput $out -RedirectStandardError "$out.err"
    # Cache the handle BEFORE the process can exit, or ExitCode reads empty.
    $null = $p.Handle
    if (-not $p.WaitForExit($timeoutSec * 1000)) {
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        return $null
    }
    $p.WaitForExit()
    return $p.ExitCode
}
function Out-Text($f) { if (Test-Path $f) { Get-Content $f -Raw } else { '' } }

function Get-List($cli, $tag) {
    Run-CliArgs $cli @('+list', '--json') "$tmp\list-$tag.json" 12 | Out-Null
    try { return (Out-Text "$tmp\list-$tag.json" | ConvertFrom-Json) } catch { return $null }
}
function Leaves-Of($node) {
    if ($null -eq $node) { return @() }
    if ($node.type -eq 'leaf') { return @($node.terminal) }
    if ($node.type -eq 'split') { return @(Leaves-Of $node.left) + @(Leaves-Of $node.right) }
    return @()
}
function All-Leaves($tree) {
    $acc = @()
    if ($null -eq $tree) { return , $acc }
    $wins = if ($null -ne $tree.data) { @($tree.data.windows) } else { @($tree.windows) }
    foreach ($w in $wins) { foreach ($t in @($w.tabs)) { $acc += Leaves-Of $t.splits } }
    return , $acc
}
function Wait-FirstLeaf($cli, $tag, $timeoutSec) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $leaves = All-Leaves (Get-List $cli $tag)
        if ($leaves.Count -ge 1) { return $leaves[0] }
        Start-Sleep -Milliseconds 500
    }
    return $null
}
function Leaf-Id($leaf) {
    if ($null -eq $leaf) { return $null }
    if ($leaf.id) { return "$($leaf.id)" }
    return "$($leaf.name)"
}

# THE liveness oracle: type a unique marker and read it back TWICE - once as the
# echoed input, once as the command's output. One copy is keystrokes landing in a
# dead pane's line editor.
function Test-PaneResponsive($cli, $id, $tag, $timeoutSec = 40) {
    $marker = "T1619x$($tag)x$(Get-Random -Maximum 999999)"
    Run-CliArgs $cli @('+send-keys', "--target=$id", 'echo', 'Space', $marker, 'Enter') `
        "$tmp\keys-$tag.txt" 12 | Out-Null
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        Run-CliArgs $cli @('+read', "--name=$id", '--lines=60') "$tmp\read-$tag.txt" 12 | Out-Null
        $txt = ((Out-Text "$tmp\read-$tag.txt") -replace "`0", '') -replace '\s', ''
        if (([regex]::Matches($txt, [regex]::Escape($marker))).Count -ge 2) { return $true }
        Start-Sleep -Milliseconds 700
    }
    return $false
}

# Agent processes started for THIS run's lineage (its command line carries the
# lineage-qualified state dir and pipe), whatever file they were started from.
function Get-LineageAgents {
    return @(Get-CimInstance Win32_Process -Filter "Name='ghoztty-agent.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -like "*$instance*" })
}

function Reset-State($arm) {
    $script:tmp = Join-Path $root "run-$arm"
    New-Item -ItemType Directory -Force $script:tmp | Out-Null
    $env:LOCALAPPDATA = $script:tmp
}

function Start-App($exePath, $arm) {
    $script:AppLog = Join-Path $tmp "applog-$arm.err.txt"
    # persistence: on (default) - the subject IS the persistence agent's resolution.
    $app = Start-OnTestDesktop -Exe $exePath -Arguments @() -StdErr $script:AppLog
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow' -TimeoutMs 40000
    if ($top -eq [IntPtr]::Zero) { return 0 }
    return [int]$app.Pid
}

# ============================================================================
# Setup
# ============================================================================
$null = Assert-GhozttyIsolatedBuild -Exe $Exe

$saved = @{
    lad  = $env:LOCALAPPDATA
    bin  = $env:GHOSTTY_LOCAL_AGENT_BIN
    pipe = $env:GHOZTTY_PIPE_SUFFIX
}
Stop-TestProcs
$tmp = Join-Path $root 'run'
New-Item -ItemType Directory -Force $tmp | Out-Null
# THE condition under test: no override anywhere in what the app inherits.
Remove-Item Env:GHOSTTY_LOCAL_AGENT_BIN -ErrorAction SilentlyContinue
$env:GHOZTTY_PIPE_SUFFIX = "-sibling$PID"

Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {

Assert "setup: ghoztty exe exists in zig-out" (Test-Path $Exe)
Assert "setup: its sibling agent exists in zig-out" (Test-Path $AgentExe)
Assert "setup: GHOSTTY_LOCAL_AGENT_BIN is unset for everything launched" `
    ([string]::IsNullOrEmpty($env:GHOSTTY_LOCAL_AGENT_BIN))
Assert "setup: this run has its own agent lineage" (-not [string]::IsNullOrEmpty($instance))

New-Item -ItemType Directory -Force $loneDir | Out-Null
Copy-Item $Exe $loneDir
$missingAgent = Join-Path $loneDir 'ghoztty-agent.exe'
Assert "setup: the lone copy has no agent beside it" `
    ((Test-Path $loneExe) -and -not (Test-Path $missingAgent))
Assert "setup: no agent of this lineage is running yet" (@(Get-LineageAgents).Count -eq 0)

# ============================================================================
Say "== B: no agent beside the exe - the pane falls back and the app says why"
# ============================================================================
Reset-State 'lone'
$sw = [Diagnostics.Stopwatch]::StartNew()
$bPid = Start-App $loneExe 'lone'
Assert "B the GUI came up" ($bPid -ne 0)
if ($bPid -ne 0) {
    $leaf = Wait-FirstLeaf $loneExe 'b' 30
    $id = Leaf-Id $leaf
    Assert "B the window has a pane" (-not [string]::IsNullOrEmpty($id))
    if ($id) {
        Assert "B the pane answers (plain-shell fallback)" (Test-PaneResponsive $loneExe $id 'b')
        $ms = [int]$sw.Elapsed.TotalMilliseconds
        Say "   (launch to answering pane: $ms ms)"
        # The fallback is a fast refusal (no spawn is attempted), so a missing
        # agent must never cost the agent spawn deadline on top of the launch.
        Assert "B it did not hang on the missing agent (< 45 s, got $ms ms)" ($ms -lt 45000)
    }
    Assert "B no agent was started for this lineage" (@(Get-LineageAgents).Count -eq 0)
    # The app's stderr reaches the file through a redirect, so give the line a
    # moment to land rather than reading the file once.
    $named = $null
    $deadline = (Get-Date).AddSeconds(10)
    do {
        $m = [regex]::Match((Out-Text $script:AppLog), 'local agent binary not found at (\S+)')
        if ($m.Success) { $named = $m.Groups[1].Value.Trim(); break }
        Start-Sleep -Milliseconds 300
    } while ((Get-Date) -lt $deadline)
    Assert "B the app reports the missing agent" ($null -ne $named)
    # Scored on THIS run's directory leaf, not the full string: a parallel worker
    # runs from a mirror whose root the app may spell differently (casing, a
    # junction resolved) than the harness does.
    $wantTail = '\' + (Split-Path -Leaf $loneDir) + '\ghoztty-agent.exe'
    Assert "B it names the sibling of the exe it ran from (...$wantTail)" `
        ($null -ne $named -and $named.EndsWith($wantTail, [StringComparison]::OrdinalIgnoreCase))
    if ($null -eq $named) {
        Say "   app log tail:"; ((Out-Text $script:AppLog) -split "`n" | Select-Object -Last 15) | ForEach-Object { Say "     $_" }
    } elseif (-not $named.EndsWith($wantTail, [StringComparison]::OrdinalIgnoreCase)) {
        Say "   the app named: $named (harness expected $missingAgent)"
    }
}
Stop-TestProcs

# ============================================================================
Say "== A: the agent beside zig-out's exe is the one spawned, and it owns the pane"
# ============================================================================
Reset-State 'zigout'
$aPid = Start-App $Exe 'zigout'
Assert "A the GUI came up" ($aPid -ne 0)
if ($aPid -ne 0) {
    $leaf = Wait-FirstLeaf $Exe 'a' 40
    $id = Leaf-Id $leaf
    Assert "A the window has a pane" (-not [string]::IsNullOrEmpty($id))
    if ($id) {
        Assert "A the pane answers" (Test-PaneResponsive $Exe $id 'a')
    }
    # Every lineage process counts for the path check (the daemon AND the
    # per-pane ConPTY holders it starts from its own image), but only the
    # daemon - the one with a listen pipe - is the agent the app spawned.
    $agents = @(Get-LineageAgents)
    $daemons = @($agents | Where-Object { $_.CommandLine -like '*--listen-pipe=*' })
    Assert "A exactly one agent daemon runs for this lineage (got $($daemons.Count))" ($daemons.Count -eq 1)
    $want = (Resolve-Path $AgentExe).Path
    $paths = @($agents | ForEach-Object { "$($_.ExecutablePath)" })
    Assert "A it was started from the exe's sibling ($want)" `
        ($agents.Count -ge 1 -and ($paths | Where-Object { $_ -ieq $want }).Count -eq $agents.Count)
    if ($agents.Count -ge 1 -and ($paths | Where-Object { $_ -ine $want })) {
        Say "   agent paths seen: $($paths -join '; ')"
    }
    # The persistence path is live: the agent owns a session for the pane.
    $sessOut = "$tmp\sessions-a.json"
    $code = Run-CliArgs $Exe @('+sessions', '--json') $sessOut 15
    $sessText = Out-Text $sessOut
    $sess = $null
    try { $sess = $sessText | ConvertFrom-Json } catch { $sess = $null }
    $rows = @()
    if ($null -ne $sess) {
        if ($null -ne $sess.sessions) { $rows = @($sess.sessions | ForEach-Object { $_ }) }
        elseif ($sess -is [array]) { $rows = @($sess | ForEach-Object { $_ }) }
    }
    Assert "A +sessions answers (exit $code)" ($code -eq 0)
    Assert "A +sessions lists the pane's session (got $($rows.Count))" ($rows.Count -ge 1)
    if ($rows.Count -lt 1) { Say "   +sessions said: $($sessText.Trim())" }
}

Complete-TestBody
} finally {
    Stop-TestProcs
    $fgSeen = @(Stop-TestForegroundWatch)
    if ($td) { Remove-TestDesktop $td }
    $env:LOCALAPPDATA = $saved.lad
    $env:GHOSTTY_LOCAL_AGENT_BIN = $saved.bin
    $env:GHOZTTY_PIPE_SUFFIX = $saved.pipe
    Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $loneDir -ErrorAction SilentlyContinue
}
$leaked = @(Get-TestLaunchedPids | Where-Object { $fgSeen -contains $_ })
Assert "no test-desktop app ever became foreground" ($leaked.Count -eq 0)

# --- stamp (T783) -------------------------------------------------------------
# Only from the bottom of a clean run: a red arm, or a run that died before
# here, leaves the agent-sibling-resolve guard DUE.
if ($script:failures -eq 0) {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard agent-sibling-resolve -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

""
Write-TestVerdict -Pass $script:passes -Fail $script:failures
