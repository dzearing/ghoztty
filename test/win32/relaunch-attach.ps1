# T3252 acceptance: quit Ghoztty completely, open it again, and EVERY pane comes
# back attached - never "error starting IO thread: error.ConnectionClosed" /
# "error.Timeout", never a "the background terminal service ..." failure notice.
#
# In the user's terms (2026-11-19): "on windows, i close ghoztty completely.
# reopen it" - and some panes came back as an error instead of their shell.
# session-reattach.ps1 already proves the same-agent restore for three panes and
# reads one of them; this script is about the claim the user's report broke:
# ALL of them, at a size where the restore's attaches queue up behind each other
# (the T3254 shape), and while the session service is itself mid-update.
#
# Sections:
#   A. Six panes over two windows. Kill ONLY the app (the detached agent keeps
#      every shell), relaunch, and require: both windows and all six panes back,
#      the SAME six sessions alive (ATTACH, not a re-OPEN), no pane showing an
#      IO-thread error or a bring-up failure notice, every named pane LIVE
#      (typed into, answers), and no `bring-up <phase> got no answer` /
#      `error in io thread` line in the app's log.
#   B. The same quit + relaunch while an agent HANDOFF is in flight (T907: a
#      newer build lands, the running agent spawns it and stands down). The
#      relaunch is started the moment the successor process exists, so the
#      restore's attaches race the swap. Required: the handoff completes, every
#      pane comes back attached to its own session (same ids), shows no error,
#      answers input, and the log carries no transport failure. A retry the app
#      makes on its own is allowed; a pane left showing the error is not.
#
# `-NegativeControl` inverts the "no error text" arms (A6, B8) so a run that
# scores this build as SHOWING the error is available on demand; those arms -
# and nothing else - go red.
#
# Hermetic: a per-run $env:LOCALAPPDATA, a private IPC endpoint and agent
# instance (lib\Isolation), a per-run COPY of the agent under test, and only
# processes whose ExecutablePath is that copy - or the exe under test - are ever
# stopped. Everything runs on the background test desktop (T1238); nothing in it
# needs the input desktop.
#
#   powershell -NoProfile -File test\win32\relaunch-attach.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe',
    [switch]$NegativeControl
)

# CleanSlate first: it drops an inherited $GHOZTTY_IPC_SOCKET (a test never
# wants the caller pane's endpoint) and brings the state-path helpers.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:passes = 0
$script:failures = 0
$script:skipped = 0

function Assert([string]$name, [bool]$cond) {
    if ($cond) { Write-Host "  PASS $name"; $script:passes++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:failures++ }
}
function Say($m) { Write-Host $m }

if (-not (Test-Path $Exe)) {
    Write-TestAssertedNothing -Label 'RELAUNCH-ATTACH' -Reason "exe not found: $Exe (build with: zig build -Dapp-runtime=win32 -Doptimize=Debug)"
}
if (-not (Test-Path $AgentExe)) {
    Write-TestAssertedNothing -Label 'RELAUNCH-ATTACH' -Reason "agent not found: $AgentExe (build with: zig build agent -Doptimize=Debug)"
}

. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null
. (Join-Path $PSScriptRoot 'lib\PaneLiveness.ps1')

$root = Join-Path $env:TEMP "ghoztty-relaunch-attach-$PID"
$tmp = Join-Path $root 'run'
$agentDir = Join-Path $root 'agentdir'

$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN
$savedHolderFlag = $env:GHOZTTY_AGENT_PTY_HOLDER
$savedForce = $env:GHOZTTY_AGENT_HANDOFF_FORCE
$savedInterval = $env:GHOZTTY_AGENT_HANDOFF_INTERVAL_MS

# What a pane must never show after a relaunch. Matched whitespace-stripped,
# because +read hands back wrapped rows. The last one is the shared opening of
# every bring-up failure notice (attach_failed_notice / open_failed_notice), so
# the T3252 replacement text counts as a failure here too: it is the truthful
# version of the error, not its absence.
$ErrorPhrases = @(
    'errorstartingIOthread',
    'error.ConnectionClosed',
    'error.Timeout',
    'exhaustingasystemresource',
    'Thebackgroundterminalservice'
)

# --- process helpers: ONLY the binaries under test ---------------------------
function Get-RunAgentProcs {
    return , @(Get-CimInstance Win32_Process -Filter "Name LIKE 'ghoztty-agent%'" |
        Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($agentDir, 'OrdinalIgnoreCase') })
}
function Get-TestApps {
    return , @(Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.ExecutablePath -eq $Exe })
}
function Get-TestAgents {
    return , @((Get-RunAgentProcs) | Where-Object { $_.CommandLine -notmatch '--pty-host' })
}
function Test-Alive([int]$procId) {
    if ($procId -le 0) { return $false }
    return $null -ne (Get-Process -Id $procId -ErrorAction SilentlyContinue)
}
function Stop-AppOnly {
    foreach ($p in (Get-TestApps)) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline -and (Get-TestApps).Count -gt 0) { Start-Sleep -Milliseconds 200 }
    Start-Sleep -Milliseconds 500
}
function Stop-Everything {
    Stop-AppOnly
    foreach ($p in (Get-RunAgentProcs)) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 700
}

# --- CLI plumbing (on the test desktop; the harness captures both handles) ----
function Run-Cli([string]$argsLine, [string]$out, [int]$timeoutSec = 15) {
    $argv = @($argsLine -split '\s+' | Where-Object { $_ -ne '' })
    $r = Invoke-OnTestDesktop -Exe $Exe -Arguments $argv -TimeoutSec $timeoutSec
    $text = if ($null -ne $r.Output) { $r.Output } else { '' }
    [System.IO.File]::WriteAllText($out, $text)
    if ($r.TimedOut) { return $null }
    return $r.ExitCode
}
function Out-Text([string]$f) { if (Test-Path $f) { return (Get-Content $f -Raw) } return '' }

function Leaves-Of($node) {
    if ($null -eq $node) { return @() }
    if ($node.type -eq 'leaf') { return @($node.terminal) }
    if ($node.type -eq 'split') { return @(Leaves-Of $node.left) + @(Leaves-Of $node.right) }
    return @()
}
function Windows-Of($tree) {
    if ($null -eq $tree) { return @() }
    if ($null -ne $tree.data) { return @($tree.data.windows) }
    return @($tree.windows)
}
function All-Leaves($tree) {
    $acc = @()
    foreach ($w in (Windows-Of $tree)) { foreach ($t in @($w.tabs)) { $acc += Leaves-Of $t.splits } }
    return , $acc
}
function Get-Tree([string]$tag) {
    $rc = Run-Cli '+list --json' "$tmp\list-$tag.json" 12
    if ($rc -ne 0) { return $null }
    try { return ((Out-Text "$tmp\list-$tag.json") | ConvertFrom-Json) } catch { return $null }
}
function Get-Sessions([string]$tag) {
    $code = Run-Cli '+sessions --json' "$tmp\sess-$tag.json" 12
    if ($code -ne 0) { return @() }
    try { $rows = (Out-Text "$tmp\sess-$tag.json") | ConvertFrom-Json } catch { return @() }
    if ($null -eq $rows) { return @() }
    return @($rows)
}
function Alive-Ids($rows) {
    return , @($rows | Where-Object { $_.alive -eq $true } | ForEach-Object { [string]$_.id })
}

# Poll +list until $want windows / $leaves panes exist and every leaf carries a
# session id. Returns the last leaf array read (possibly short).
function Wait-Layout([string]$tag, [int]$want, [int]$leaves, [int]$timeoutSec = 60) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $last = @()
    while ((Get-Date) -lt $deadline) {
        $tree = Get-Tree $tag
        $last = All-Leaves $tree
        if (@(Windows-Of $tree).Count -eq $want -and $last.Count -eq $leaves -and
            @($last | Where-Object { -not $_.session_id }).Count -eq 0) { return , $last }
        Start-Sleep -Milliseconds 700
    }
    return , $last
}

# Whitespace-stripped +read of one pane (by name, or by id when it has none).
function Read-Pane($leaf, [string]$tag) {
    $sel = if ($leaf.name) { "--name=$($leaf.name)" } else { "--pane=$($leaf.id)" }
    $rc = Run-Cli "+read $sel --lines=400" "$tmp\read-$tag.txt" 12
    if ($rc -ne 0) { return $null }
    return ((Out-Text "$tmp\read-$tag.txt") -replace "`0", '' -replace '\s', '')
}
# The error phrases a pane shows, or @() when it is clean. $null text (the read
# itself failed) is reported as 'unreadable' - an unreadable pane is not clean.
function Find-ErrorText($text) {
    if ($null -eq $text) { return @('unreadable') }
    return , @($ErrorPhrases | Where-Object { $text.IndexOf($_, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
}
# Every pane's error phrases after a restore, re-read for a settle window so a
# pane that paints the error a beat after attaching is still caught; returns a
# hashtable label -> phrases for the dirty ones.
function Get-DirtyPanes($leaves, [string]$tag, [int]$settleSec = 12) {
    $dirty = @{}
    $deadline = (Get-Date).AddSeconds($settleSec)
    $pass = 0
    do {
        $pass++
        foreach ($lf in $leaves) {
            $label = if ($lf.name) { [string]$lf.name } else { "id:$($lf.id)" }
            $hits = Find-ErrorText (Read-Pane $lf "$tag-$pass-$label")
            if ($hits.Count -gt 0) { $dirty[$label] = ($hits -join ',') }
        }
        if ($dirty.Count -gt 0) { break }
        Start-Sleep -Seconds 3
    } while ((Get-Date) -lt $deadline)
    return $dirty
}
# Transport-failure lines in everything the app logged for this state dir.
function Find-TransportLogLines([string]$state, [string[]]$extra) {
    $files = @()
    $logDir = Join-Path $state 'ghoztty'
    if (Test-Path $logDir) { $files += @(Get-ChildItem -LiteralPath $logDir -Filter '*.log' -File | ForEach-Object { $_.FullName }) }
    foreach ($e in $extra) { if ($e -and (Test-Path $e)) { $files += $e } }
    $hits = @()
    foreach ($f in $files) {
        $hits += @(Select-String -LiteralPath $f -Pattern 'got no answer|error in io thread' -ErrorAction SilentlyContinue |
            ForEach-Object { $_.Line.Trim() })
    }
    return , @($hits)
}
function Test-PaneLiveRetry([string]$target, [string]$tag, [int]$attempts = 4, [int]$perAttemptSec = 20) {
    for ($i = 1; $i -le $attempts; $i++) {
        if (Test-PaneLive -Exe $Exe -Target $target -Tmp $tmp -Tag "$tag$i" -TimeoutSec $perAttemptSec) { return $true }
    }
    return $false
}

# Launch with a state dir of its own; wait for IPC + the first pane. Returns the
# app pid (0 on failure).
# persistence: on (default) - a relaunch re-attaching every pane is the subject.
function Start-App([string]$state, [string]$title, [string]$stderr, [int]$timeoutSec = 60) {
    $env:LOCALAPPDATA = $state
    $launchArgs = @('--window-width=100', '--window-height=30')
    if ($title) { $launchArgs = @("--title=$title") + $launchArgs }
    # persistence: on (default) - the relaunch has to RESTORE what the first launch left.
    if ($stderr) { [void](Start-OnTestDesktop -Exe $Exe -Arguments $launchArgs -StdErr $stderr) }
    # persistence: on (default) - same launch, no stderr capture.
    else { [void](Start-OnTestDesktop -Exe $Exe -Arguments $launchArgs) }
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $app = Get-TestApps
        if ($app.Count -ge 1) {
            $rc = Run-Cli '+list --json' "$tmp\list-boot.json" 10
            if ($rc -eq 0 -and (Out-Text "$tmp\list-boot.json") -match '\S') { return [int]$app[0].ProcessId }
        }
        Start-Sleep -Milliseconds 600
    }
    return 0
}

# Build the multi-pane layout off the startup pane: names $prefix1..$prefix3 in
# window 1, then a second window ($prefix-w) holding $prefix4/$prefix5 (+ more
# when $extra asks). Returns nothing; the caller waits on Wait-Layout.
function Build-Layout([string]$prefix, [string]$tag) {
    $first = $null
    foreach ($lf in (All-Leaves (Get-Tree "$tag-boot"))) { if (-not $first) { $first = $lf.id } }
    if ($first) { Run-Cli "+split --pane=$first --name=${prefix}1 --direction=right" "$tmp\$tag-s1.txt" 25 | Out-Null }
    Run-Cli "+split --pane=${prefix}1 --name=${prefix}2 --direction=down" "$tmp\$tag-s2.txt" 25 | Out-Null
    Run-Cli "+split --pane=${prefix}2 --name=${prefix}3 --direction=right" "$tmp\$tag-s3.txt" 25 | Out-Null
    Run-Cli "+new-window --target=${prefix}w --name=${prefix}4" "$tmp\$tag-w2.txt" 25 | Out-Null
    Run-Cli "+split --target=${prefix}4 --name=${prefix}5 --direction=right" "$tmp\$tag-s5.txt" 25 | Out-Null
}

# The manifest must hold the whole layout before the abrupt kill, or the
# relaunch restores a stale subset and every arm below measures the wrong thing.
function Wait-ManifestSids([string]$state, [int]$want, [int]$timeoutSec = 15) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $p = Get-GhozttySessionLayoutPath -Root $state
        if (Test-Path $p) {
            $raw = Out-Text $p
            $n = ([regex]::Matches($raw, '"session_id":"[^"]+"')).Count
            if ($n -ge $want) { return $n }
        }
        Start-Sleep -Milliseconds 400
    }
    return 0
}

try {
    New-Item -ItemType Directory -Force $tmp | Out-Null
    New-Item -ItemType Directory -Force $agentDir | Out-Null
    $env:LOCALAPPDATA = Join-Path $root 'state-boot'
    New-Item -ItemType Directory -Force $env:LOCALAPPDATA | Out-Null
    Remove-Item env:GHOZTTY_AGENT_PTY_HOLDER -ErrorAction SilentlyContinue
    Remove-Item env:GHOZTTY_AGENT_HANDOFF_FORCE -ErrorAction SilentlyContinue
    Remove-Item env:GHOZTTY_AGENT_HANDOFF_INTERVAL_MS -ErrorAction SilentlyContinue

    . (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
    [void](Set-GhozttyTestIsolation -Tag 'rlat3252')
    Assert-GhozttyPrivateEndpoint -Exe $Exe

    . (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
    $td = New-TestDesktop

    # ========================================================================
    Say "== A: six panes, two windows - full quit, relaunch, every pane attaches"
    # ========================================================================
    $agentA = Join-Path $agentDir 'a\ghoztty-agent.exe'
    New-Item -ItemType Directory -Force (Split-Path $agentA) | Out-Null
    Copy-Item -LiteralPath $AgentExe -Destination $agentA -Force
    $env:GHOSTTY_LOCAL_AGENT_BIN = $agentA
    $stateA = Join-Path $root 'state-a'
    New-Item -ItemType Directory -Force (Get-GhozttyAgentStateDir -Root $stateA) | Out-Null

    $appA = Start-App $stateA 't3252a' "$tmp\a-launch-err.txt"
    Assert 'A1 premise: the app is up and answering IPC' ($appA -gt 0)
    if ($appA -le 0) { Write-TestVerdict -Label 'RELAUNCH-ATTACH' -Pass $script:passes -Fail $script:failures -Skipped $script:skipped }
    Assert-GhozttyIsolated -Exe $Exe

    Build-Layout 'ra' 'a'
    $leavesA = Wait-Layout 'a-pre' 2 6 60
    Assert "A2 premise: two windows / six agent-backed panes before the quit (got $($leavesA.Count))" ($leavesA.Count -eq 6)
    $sidsA = @($leavesA | ForEach-Object { [string]$_.session_id } | Sort-Object -Unique)
    Assert 'A3 premise: six DISTINCT sessions' ($sidsA.Count -eq 6)
    Assert 'A3b premise: the manifest holds all six before the quit' ((Wait-ManifestSids $stateA 6 15) -ge 6)

    Stop-AppOnly
    $aliveA = Alive-Ids (Get-Sessions 'a-down')
    Assert 'A4 premise: the agent kept all six shells while the app was gone' (
        @($sidsA | Where-Object { $aliveA -contains $_ }).Count -eq 6)

    $errA = "$tmp\a-relaunch-err.txt"
    $appA2 = Start-App $stateA $null $errA 60
    Assert 'A5 the relaunched app answers IPC' ($appA2 -gt 0)
    $leavesA2 = Wait-Layout 'a-post' 2 6 60
    $sidsA2 = @($leavesA2 | ForEach-Object { [string]$_.session_id } | Sort-Object -Unique)
    Assert "A5b both windows and all six panes came back (got $($leavesA2.Count))" ($leavesA2.Count -eq 6)
    Assert 'A5c each pane is attached to the SAME session it had (ATTACH, not a fresh OPEN)' (
        $sidsA2.Count -eq 6 -and @($sidsA | Where-Object { $sidsA2 -contains $_ }).Count -eq 6)

    $dirtyA = Get-DirtyPanes $leavesA2 'a'
    $dirtyText = ($dirtyA.GetEnumerator() | ForEach-Object { "$($_.Key)=[$($_.Value)]" }) -join ' '
    if ($NegativeControl) {
        Say 'NEGATIVE CONTROL: asserting a restored pane SHOWS the bring-up error - this arm MUST fail'
        Assert "A6 a restored pane shows the IO-thread error (inverted) $dirtyText" ($dirtyA.Count -gt 0)
    } else {
        Assert "A6 no restored pane shows an IO-thread error or bring-up failure notice $dirtyText" ($dirtyA.Count -eq 0)
    }
    foreach ($n in 1..5) {
        Assert "A7.$n restored pane ra$n is LIVE: input reaches the shell and output returns" (
            Test-PaneLiveRetry "ra$n" "A$n")
    }
    $logA = Find-TransportLogLines $stateA @($errA)
    Assert "A8 the app logged no transport failure on bring-up ($($logA.Count): $(($logA | Select-Object -First 2) -join ' | '))" ($logA.Count -eq 0)

    Stop-Everything

    # ========================================================================
    Say "== B: full quit, relaunch WHILE the session service hands off to a newer build"
    # ========================================================================
    $dirB = Join-Path $agentDir 'b'
    New-Item -ItemType Directory -Force $dirB | Out-Null
    $runningB = Join-Path $dirB 'ghoztty-agent.exe.bak'
    $canonicalB = Join-Path $dirB 'ghoztty-agent.exe'
    Copy-Item -LiteralPath $AgentExe -Destination $runningB -Force
    Remove-Item -LiteralPath $canonicalB -Force -ErrorAction SilentlyContinue
    $env:GHOSTTY_LOCAL_AGENT_BIN = $runningB
    # One tree cannot produce two build stamps, so the handoff is forced (as in
    # agent-handoff.ps1); a fast supervisor tick puts it inside the relaunch.
    $env:GHOZTTY_AGENT_HANDOFF_FORCE = '1'
    $env:GHOZTTY_AGENT_HANDOFF_INTERVAL_MS = '1000'
    $stateB = Join-Path $root 'state-b'
    New-Item -ItemType Directory -Force (Get-GhozttyAgentStateDir -Root $stateB) | Out-Null

    $appB = Start-App $stateB 't3252b' "$tmp\b-launch-err.txt"
    Assert 'B1 premise: the app is up and answering IPC' ($appB -gt 0)
    if ($appB -le 0) { Write-TestVerdict -Label 'RELAUNCH-ATTACH' -Pass $script:passes -Fail $script:failures -Skipped $script:skipped }
    Build-Layout 'rb' 'b'
    $leavesB = Wait-Layout 'b-pre' 2 6 60
    $sidsB = @($leavesB | ForEach-Object { [string]$_.session_id } | Sort-Object -Unique)
    Assert "B2 premise: six agent-backed panes before the quit (got $($leavesB.Count))" ($leavesB.Count -eq 6 -and $sidsB.Count -eq 6)
    Assert 'B2b premise: the manifest holds all six before the quit' ((Wait-ManifestSids $stateB 6 15) -ge 6)
    $oldAgents = @((Get-TestAgents) | Where-Object { [string]$_.ExecutablePath -eq $runningB })
    Assert 'B3 premise: the serving agent runs the RENAMED image (a handoff target can land)' ($oldAgents.Count -ge 1)
    $oldPid = if ($oldAgents.Count -ge 1) { [int]$oldAgents[0].ProcessId } else { 0 }

    Stop-AppOnly
    # The newer build lands; relaunch the moment the successor process exists.
    Copy-Item -LiteralPath $AgentExe -Destination $canonicalB -Force
    $successor = $null
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        $successor = @((Get-TestAgents) | Where-Object { [string]$_.ExecutablePath -eq $canonicalB }) | Select-Object -First 1
        if ($null -ne $successor) { break }
        Start-Sleep -Milliseconds 50
    }
    $errB = "$tmp\b-relaunch-err.txt"
    $oldAliveAtLaunch = Test-Alive $oldPid
    $appB2 = Start-App $stateB $null $errB 60
    Assert 'B4 premise: the handoff had started when the app relaunched (successor spawned)' ($null -ne $successor)
    Say "  (predecessor still alive at relaunch: $oldAliveAtLaunch)"
    Assert 'B5 the relaunched app answers IPC' ($appB2 -gt 0)

    $deadline = (Get-Date).AddSeconds(45)
    while ((Get-Date) -lt $deadline -and (Test-Alive $oldPid)) { Start-Sleep -Milliseconds 500 }
    $newServing = @((Get-TestAgents) | Where-Object { [string]$_.ExecutablePath -eq $canonicalB })
    Assert 'B6 the handoff completed: the predecessor is gone, the newer build serves' (
        -not (Test-Alive $oldPid) -and $newServing.Count -ge 1)

    # A handoff drops the link and the app rebuilds its agent-backed leaves after
    # a settle window, so give the layout the longer wait.
    $leavesB2 = Wait-Layout 'b-post' 2 6 90
    $sidsB2 = @($leavesB2 | ForEach-Object { [string]$_.session_id } | Sort-Object -Unique)
    Assert "B7 both windows and all six panes came back (got $($leavesB2.Count))" ($leavesB2.Count -eq 6)
    Assert 'B7b each pane is attached to the SAME session it had' (
        $sidsB2.Count -eq 6 -and @($sidsB | Where-Object { $sidsB2 -contains $_ }).Count -eq 6)
    $dirtyB = Get-DirtyPanes $leavesB2 'b' 15
    $dirtyText = ($dirtyB.GetEnumerator() | ForEach-Object { "$($_.Key)=[$($_.Value)]" }) -join ' '
    if ($NegativeControl) {
        Assert "B8 a restored pane shows the IO-thread error (inverted) $dirtyText" ($dirtyB.Count -gt 0)
    } else {
        Assert "B8 no restored pane shows an IO-thread error or bring-up failure notice $dirtyText" ($dirtyB.Count -eq 0)
    }
    foreach ($n in 1..5) {
        Assert "B9.$n restored pane rb$n is LIVE across the handoff" (Test-PaneLiveRetry "rb$n" "B$n")
    }
    $logB = Find-TransportLogLines $stateB @($errB)
    Assert "B10 the app logged no transport failure on bring-up ($($logB.Count): $(($logB | Select-Object -First 2) -join ' | '))" ($logB.Count -eq 0)

    Complete-TestBody
} finally {
    Stop-Everything
    Remove-TestDesktop | Out-Null
    $env:LOCALAPPDATA = $savedLocalAppData
    if ($null -ne $savedAgentBin) { $env:GHOSTTY_LOCAL_AGENT_BIN = $savedAgentBin }
    else { Remove-Item env:GHOSTTY_LOCAL_AGENT_BIN -ErrorAction SilentlyContinue }
    if ($null -ne $savedHolderFlag) { $env:GHOZTTY_AGENT_PTY_HOLDER = $savedHolderFlag }
    else { Remove-Item env:GHOZTTY_AGENT_PTY_HOLDER -ErrorAction SilentlyContinue }
    if ($null -ne $savedForce) { $env:GHOZTTY_AGENT_HANDOFF_FORCE = $savedForce }
    else { Remove-Item env:GHOZTTY_AGENT_HANDOFF_FORCE -ErrorAction SilentlyContinue }
    if ($null -ne $savedInterval) { $env:GHOZTTY_AGENT_HANDOFF_INTERVAL_MS = $savedInterval }
    else { Remove-Item env:GHOZTTY_AGENT_HANDOFF_INTERVAL_MS -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

# --- stamp (T783) -----------------------------------------------------------
if ($script:failures -eq 0 -and -not $NegativeControl) {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard relaunch-attach -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-TestVerdict -Label 'RELAUNCH-ATTACH' -Pass $script:passes -Fail $script:failures -Skipped $script:skipped
