# T1798 acceptance: a session-persistence pane whose shell exits is seen to
# exit - the session is tombstoned, the pane says so, and typing into it does
# not hit a dead session.
#
# WHAT THE USER SAW (on the Mac, main c6619717b)
#
# A pane whose shell ended could be left showing its last output forever: it
# took no input, never said "process exited", and the agent logged
# `pty input write failed` for every key. The agent's only reap check was the
# pty reader's EOF nudge, which usually fired before the exit was collectable.
# The fix is shared agent code: a per-tick sweep of every alive session
# (`SessionStore.reapExited`).
#
# WHY WINDOWS NEEDS ITS OWN PROOF
#
# ConPTY never gives the reader an EOF when the shell exits - conhost keeps the
# output pipe open until the pseudoconsole is closed - so on Windows there is
# no nudge at all, and the sweep plus the holder's exit poller are the whole
# mechanism. Both ask the shell's process HANDLE (`WaitForSingleObject(h, 0)`);
# the unit test `PtyChild (Windows): a ConPTY shell that exits on its own is
# reapable by tryWait alone (T1798)` pins that, and this script measures the
# user-visible outcome end to end, through the holder, for:
#
#   A. Windows PowerShell, `exit` typed at its prompt (pwsh 7 when installed).
#   B. cmd, `exit` typed at its prompt.
#   C. cmd, a DELAYED exit (`ping -n 3 ... & exit`) - nothing typed at the
#      moment the shell actually ends.
#   D. cmd, `exit` while a background `start /b ping` it launched still shares
#      the pseudoconsole - the Windows shape of the c6619717b "guarantee"
#      case: the console stays alive, the shell does not.
#
# For each: the agent stops reporting the session as running within a bound,
# `+sessions` still lists it as a tombstone (alive:false), the pane shows the
# exited notice, and keys sent afterwards leave it a tombstone with the app
# and agent still answering.
#
# Hermetic: a per-run $env:LOCALAPPDATA and XDG config, a private IPC endpoint
# (lib\Isolation), GHOSTTY_LOCAL_AGENT_BIN pinned to the agent under test, the
# GUI and every CLI call on a background test desktop, and only processes whose
# ExecutablePath is the exe/agent under test are ever stopped.
#
#   powershell -NoProfile -File test\win32\session-shell-exit.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe'
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:passes = 0
$script:failures = 0

function Assert([string]$name, [bool]$cond) {
    if ($cond) { Write-Host "  PASS $name"; $script:passes++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:failures++ }
}
function Say($m) { Write-Host $m }

# The bound on "the session stopped running". The mechanism answers in about a
# second (holder poller 200 ms + one reaper tick); each roster read through the
# test desktop costs a few hundred ms more. 8 s separates "seen to exit" from
# "never seen" on a loaded box without hiding a regression to the old
# 10 s vanished-child sweep.
$ExitBoundSec = 8

if (-not (Test-Path $Exe)) {
    Write-TestAssertedNothing -Label 'SESSION-SHELL-EXIT' -Reason "exe not found: $Exe (build with: zig build -Dapp-runtime=win32 -Doptimize=Debug)"
}
if (-not (Test-Path $AgentExe)) {
    Write-TestAssertedNothing -Label 'SESSION-SHELL-EXIT' -Reason "agent not found: $AgentExe (build with: zig build agent -Doptimize=Debug)"
}

. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null

# --- process helpers: ONLY ever the binaries under test ----------------------
function Get-TestApps {
    return (Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.ExecutablePath -eq $Exe })
}
function Get-TestAgentProcs {
    return (Get-CimInstance Win32_Process -Filter "Name='ghoztty-agent.exe'" |
        Where-Object { $_.ExecutablePath -eq $AgentExe })
}
function Stop-Everything {
    foreach ($p in (Get-TestApps)) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    foreach ($p in (Get-TestAgentProcs | Where-Object { $_.CommandLine -notmatch '--pty-host' })) {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Milliseconds 700
    foreach ($p in (Get-TestAgentProcs | Where-Object { $_.CommandLine -match '--pty-host' })) {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Milliseconds 400
}

# --- CLI plumbing (on the test desktop; see session-vanished.ps1) ------------
function Run-Cli([string]$argsLine, [string]$out, [int]$timeoutSec = 15) {
    $argv = @($argsLine -split '\s+' | Where-Object { $_ -ne '' })
    return Run-CliArgs $argv $out $timeoutSec
}
function Run-CliArgs([string[]]$argv, [string]$out, [int]$timeoutSec = 15) {
    $r = Invoke-OnTestDesktop -Exe $Exe -Arguments $argv -TimeoutSec $timeoutSec
    $text = if ($null -ne $r.Output) { $r.Output } else { '' }
    [System.IO.File]::WriteAllText($out, $text)
    if ($r.TimedOut) { return $null }
    return $r.ExitCode
}
function Out-Text([string]$f) { if (Test-Path $f) { return (Get-Content $f -Raw) } return '' }

function Get-Sessions([string]$tag) {
    $code = Run-Cli '+sessions --json' "$tmp\sess-$tag.json" 15
    if ($code -ne 0) { return @() }
    try { $rows = (Out-Text "$tmp\sess-$tag.json") | ConvertFrom-Json } catch { return @() }
    if ($null -eq $rows) { return @() }
    return @($rows)
}
# The roster row for one session, or $null when it is not listed.
function Get-SessionRow([string]$sessionId, [string]$tag) {
    foreach ($r in (Get-Sessions $tag)) {
        if ([string]$r.id -eq $sessionId) { return $r }
    }
    return $null
}
function Read-PaneText([string]$target, [string]$tag, [int]$lines = 60) {
    $rc = Run-Cli "+read --name=$target --lines=$lines" "$tmp\read-$tag.txt" 15
    if ($rc -ne 0) { return '' }
    return ((Out-Text "$tmp\read-$tag.txt") -replace "`0", '')
}
function Wait-PaneHas([string]$target, [string]$tag, [string]$needle, [int]$timeoutSec) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $i = 0
    while ((Get-Date) -lt $deadline) {
        $t = (Read-PaneText $target "$tag$i") -replace '\s', ''
        if ($t -match [regex]::Escape(($needle -replace '\s', ''))) { return $true }
        $i++
        Start-Sleep -Milliseconds 500
    }
    return $false
}
function Leaves-Of($node) {
    if ($null -eq $node) { return @() }
    if ($node.type -eq 'leaf') { return @($node.terminal) }
    if ($node.type -eq 'split') { return @(Leaves-Of $node.left) + @(Leaves-Of $node.right) }
    return @()
}
function All-Leaves($tree) {
    $acc = @()
    $wins = if ($null -eq $tree) { @() } elseif ($null -ne $tree.data) { @($tree.data.windows) } else { @($tree.windows) }
    foreach ($w in $wins) {
        foreach ($t in @($w.tabs)) { $acc += Leaves-Of $t.splits }
    }
    return , $acc
}
function Get-Tree([string]$tag) {
    $rc = Run-Cli '+list --json' "$tmp\list-$tag.json" 12
    if ($rc -ne 0) { return $null }
    try { return ((Out-Text "$tmp\list-$tag.json") | ConvertFrom-Json) } catch { return $null }
}
# persistence: on (default) - the subject IS a persistence pane; every call runs
# inside this script's per-run $env:LOCALAPPDATA, so there is no manifest to
# restore from.
function Start-TestApp([string]$title, [int]$timeoutSec = 45) {
    [void](Start-OnTestDesktop -Exe $Exe -Arguments @(
        "--title=$title", '--window-width=100', '--window-height=30'))
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $rc = Run-Cli '+list --json' "$tmp\list-up-$title.json" 10
        if ($rc -eq 0 -and (Out-Text "$tmp\list-up-$title.json") -match '\S') {
            $app = @(Get-TestApps | Where-Object { $_.CommandLine -like "*$title*" })
            if ($app.Count -ge 1) { return [int]$app[0].ProcessId }
        }
        Start-Sleep -Milliseconds 600
    }
    return 0
}
function Wait-NamedLeaf([string]$paneName, [string]$tag, [int]$timeoutSec = 45) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $i = 0
    while ((Get-Date) -lt $deadline) {
        $lv = @((All-Leaves (Get-Tree "$tag$i")) | Where-Object { $_.name -eq $paneName })
        if ($lv.Count -eq 1 -and $lv[0].session_id) { return $lv[0] }
        $i++
        Start-Sleep -Milliseconds 700
    }
    return $null
}
function Wait-ShellPid([string]$sessionId, [string]$tag, [int]$timeoutSec = 45) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $i = 0
    while ((Get-Date) -lt $deadline) {
        $r = Get-SessionRow $sessionId "$tag$i"
        if ($null -ne $r -and $r.alive -eq $true -and [int]$r.pid -gt 0) { return [int]$r.pid }
        $i++
        Start-Sleep -Milliseconds 600
    }
    return 0
}
# A running process named `$name` anywhere under `$rootPid`. The session's
# reported pid is not necessarily the process a typed command runs in (on this
# box each shell carries an inner cmd.exe), so this walks the whole subtree.
function Find-Descendant([int]$rootPid, [string]$name) {
    $all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    $frontier = @($rootPid)
    $seen = @{}
    while ($frontier.Count -gt 0) {
        $next = @()
        foreach ($p in $all) {
            if ($frontier -contains [int]$p.ParentProcessId -and -not $seen.ContainsKey([int]$p.ProcessId)) {
                $seen[[int]$p.ProcessId] = $true
                if ($p.Name -eq $name) { return $p }
                $next += [int]$p.ProcessId
            }
        }
        $frontier = $next
    }
    return $null
}

# One case: open a named pane in `$shell`, prove it is live, end its shell
# with `$exitKeys`, and measure the outcomes.
#
# -Grandchild first types `$GrandchildKeys` - a background process that shares
# the pseudoconsole - and proves it is running under the session before the
# shell is told to exit, so the exit has to be seen while the console is still
# held open. (What happens to that process afterwards is the kill-on-close
# job's business, not this script's: the agent ends it with the session.)
function Test-ShellExit {
    param(
        [string]$Label, [string]$Pane, [string]$Shell, [string[]]$ExitKeys,
        [string]$WarmCmd, [int]$ExpectRunningForSec = 0,
        [switch]$Grandchild, [string[]]$GrandchildKeys = @()
    )
    Say "== ${Label}: $Shell, exit via '$($ExitKeys -join ' ')'"
    $firstId = $null
    foreach ($lf in (All-Leaves (Get-Tree "$Pane-0"))) { if (-not $firstId) { $firstId = $lf.id } }
    Run-CliArgs @('+split', "--pane=$firstId", "--name=$Pane", "--shell=$Shell", '--direction=right') "$tmp\split-$Pane.txt" 20 | Out-Null
    $leaf = Wait-NamedLeaf $Pane "$Pane-a"
    Assert "$Label.1 the pane exists and is agent-backed (it carries a session id)" ($null -ne $leaf)
    if ($null -eq $leaf) { return }
    $sid = [string]$leaf.session_id
    $shellPid = Wait-ShellPid $sid "$Pane-b"
    Assert "$Label.2 the agent roster reports a live shell pid" ($shellPid -gt 0)
    $warm = "T1798WARM$Label$PID" + 'Z'
    Run-CliArgs @('+send-keys', "--target=$Pane", $WarmCmd, 'Space', $warm, 'Enter') "$tmp\warm-$Pane.txt" 12 | Out-Null
    Assert "$Label.3 premise: the pane is LIVE (the shell echoed a typed marker)" (Wait-PaneHas $Pane "$Pane-w" $warm 30)

    if ($Grandchild) {
        Run-CliArgs (@('+send-keys', "--target=$Pane") + $GrandchildKeys + @('Enter')) "$tmp\gc-$Pane.txt" 12 | Out-Null
        $gc = $null
        $gcDeadline = (Get-Date).AddSeconds(10)
        while ((Get-Date) -lt $gcDeadline -and $null -eq $gc) {
            $gc = Find-Descendant $shellPid 'PING.EXE'
            if ($null -eq $gc) { Start-Sleep -Milliseconds 200 }
        }
        Assert "$Label.4a premise: a background ping shares the session's console" ($null -ne $gc)
    }

    $sent = Get-Date
    Run-CliArgs (@('+send-keys', "--target=$Pane") + $ExitKeys + @('Enter')) "$tmp\exit-$Pane.txt" 12 | Out-Null

    if ($ExpectRunningForSec -gt 0) {
        # The delayed exit: still running while the ping counts.
        Assert "$Label.4b premise: the session is still running while its delayed exit counts down" (
            [bool](Get-SessionRow $sid "$Pane-r").alive)
    }

    $row = $null
    $deadline = $sent.AddSeconds($ExitBoundSec + $ExpectRunningForSec)
    $i = 0
    $gone = $null
    while ((Get-Date) -lt $deadline) {
        $row = Get-SessionRow $sid "$Pane-x$i"
        if ($null -eq $row -or -not [bool]$row.alive) { $gone = Get-Date; break }
        $i++
        Start-Sleep -Milliseconds 200
    }
    $took = if ($gone) { [int](($gone - $sent).TotalMilliseconds) } else { -1 }
    Say "    session stopped running after ${took} ms (bound $(($ExitBoundSec + $ExpectRunningForSec) * 1000) ms)"
    Assert "$Label.5 the agent stopped reporting the session as running within the bound" ($null -ne $gone)
    Assert "$Label.6 +sessions still lists it, as a tombstone (alive:false)" (
        $null -ne $row -and -not [bool]$row.alive)

    Assert "$Label.7 the pane shows the exited notice" (Wait-PaneHas $Pane "$Pane-n" 'Process exited' 15)

    # Keys after the exit. The Mac symptom was every key logging `pty input
    # write failed` into a session still marked alive. Here the agent writes a
    # DATA frame to the child only while the session is alive
    # (`Server.handleInboundData`), so a tombstone cannot be typed into; what is
    # measurable from outside is that the keys change nothing - the session
    # stays a tombstone (it was not revived or re-spawned by input) and the app
    # and agent are both still answering. A debug build logs to stderr only, so
    # there is no log file here to search for the line itself.
    Run-CliArgs @('+send-keys', "--target=$Pane", 'abc', 'Enter') "$tmp\after-$Pane.txt" 12 | Out-Null
    Start-Sleep -Milliseconds 1500
    $row2 = Get-SessionRow $sid "$Pane-y"
    Assert "$Label.8 keys sent after the exit leave it a tombstone, and the agent still answers" (
        $null -ne $row2 -and -not [bool]$row2.alive)
    Assert "$Label.9 the app still answers IPC after keys into the exited pane" ($null -ne (Get-Tree "$Pane-z"))
}

$root = Join-Path $env:TEMP "ghoztty-session-shell-exit-$PID"
$tmp = Join-Path $root 'run'
$savedLocalAppData = $env:LOCALAPPDATA
$savedXdg = $env:XDG_CONFIG_HOME
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN
$savedHolderFlag = $env:GHOZTTY_AGENT_PTY_HOLDER

try {
    Stop-Everything
    New-Item -ItemType Directory -Force $tmp | Out-Null
    $env:LOCALAPPDATA = $tmp
    $env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe
    # Holder-backed spawning is the default since T909, and it is the path the
    # user runs; clear an inherited opt-out.
    Remove-Item env:GHOZTTY_AGENT_PTY_HOLDER -ErrorAction SilentlyContinue

    # wait-after-command keeps an exited pane open with its notice, so the pane
    # can be read (and typed into) after its shell is gone.
    $cfgDir = Join-Path $tmp 'xdg\ghostty'
    New-Item -ItemType Directory -Force $cfgDir | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $cfgDir 'config'), "wait-after-command = true`n")
    $env:XDG_CONFIG_HOME = Join-Path $tmp 'xdg'

    . (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
    [void](Set-GhozttyTestIsolation -Tag 'shellexit1798')
    Assert-GhozttyPrivateEndpoint -Exe $Exe

    . (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
    $td = New-TestDesktop

    $appPid = Start-TestApp 't1798-exit'
    Assert 'premise: the app is up and answering IPC' ($appPid -gt 0)
    if ($appPid -le 0) {
        Write-TestVerdict -Label 'SESSION-SHELL-EXIT' -Pass $script:passes -Fail $script:failures
    }
    Assert-GhozttyIsolated -Exe $Exe

    $ps = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    if (-not $ps) { $ps = 'powershell.exe' }
    Test-ShellExit -Label 'A' -Pane 't1798a' -Shell $ps -WarmCmd 'echo' -ExitKeys @('exit')
    Test-ShellExit -Label 'B' -Pane 't1798b' -Shell 'cmd.exe' -WarmCmd 'echo' -ExitKeys @('exit')
    Test-ShellExit -Label 'C' -Pane 't1798c' -Shell 'cmd.exe' -WarmCmd 'echo' `
        -ExitKeys @('ping', 'Space', '-n', 'Space', '4', 'Space', '127.0.0.1', 'Space', '>nul', 'Space', '&', 'Space', 'exit') `
        -ExpectRunningForSec 3
    Test-ShellExit -Label 'D' -Pane 't1798d' -Shell 'cmd.exe' -WarmCmd 'echo' `
        -Grandchild -GrandchildKeys @('start', 'Space', '/b', 'Space', 'ping', 'Space', '-n', 'Space', '30', 'Space', '127.0.0.1', 'Space', '>nul') `
        -ExitKeys @('exit')

    Complete-TestBody
} finally {
    Stop-Everything
    Remove-TestDesktop | Out-Null
    $env:LOCALAPPDATA = $savedLocalAppData
    if ($null -ne $savedXdg) { $env:XDG_CONFIG_HOME = $savedXdg } else { Remove-Item env:XDG_CONFIG_HOME -ErrorAction SilentlyContinue }
    if ($null -ne $savedAgentBin) { $env:GHOSTTY_LOCAL_AGENT_BIN = $savedAgentBin }
    else { Remove-Item env:GHOSTTY_LOCAL_AGENT_BIN -ErrorAction SilentlyContinue }
    if ($null -ne $savedHolderFlag) { $env:GHOZTTY_AGENT_PTY_HOLDER = $savedHolderFlag }
    else { Remove-Item env:GHOZTTY_AGENT_PTY_HOLDER -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

# --- stamp (T783) -----------------------------------------------------------
if ($script:failures -eq 0) {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard session-shell-exit -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-TestVerdict -Label 'SESSION-SHELL-EXIT' -Pass $script:passes -Fail $script:failures
