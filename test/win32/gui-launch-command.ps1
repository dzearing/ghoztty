# GUI launch path: `ghoztty -e <args...>` and `ghoztty --command=...` (T104).
#
# The gap this covers: on Mac/Linux `ghostty -e cmd...` runs the command in the
# first window. On Windows the args were parsed into `initial-command` and then
# silently DROPPED - the pane came up on a plain default shell. `--command=` on
# the same launch path was dropped identically, and so was a `command` set in the
# user's config file.
#
# The cause was not the parser. Session persistence is ON by default on Windows,
# so every local pane's IO backend is the LOCAL AGENT, and the agent branch in
# `Surface.init` only forwarded a command when `wait-after-command` was set -
# which is a flag the APPRT sets when IT builds a command (the IPC / embedded
# `--command` paths), never something the app's own config sets. The launch
# path's command therefore matched nothing and was never sent in the OPEN.
# `Config._command-explicit` is the missing signal; see `Surface.init`.
#
# The oracle is the same in every section: read the pane back and look for the
# marker the launched command prints. A GUI that "opened a window" proves
# nothing - a window opens either way.
#
# Sections:
#   A  `-e <script> a b c` runs the command WITH ITS ARGUMENTS, with session
#      persistence at its default (on). Pre-fix: a bare shell prompt.
#   B  `--command=<script> a b` on the same launch path does the same.
#   C  a plain launch (no command asked for) still gets an interactive shell and
#      no command is forwarded to the agent - the default shell that
#      `Config.finalize` fills in must NOT be mistaken for an explicit request.
#   D  a launch command survives session restore (T406).
#   E  a SECOND launch against an already-running instance forwards its
#      `-e` command and `--working-directory` instead of dropping them (T487):
#      the AlreadyRunning arm used to forward a bare `new-window` with a null
#      payload, so the running instance opened an empty window and the command
#      vanished with exit 0 and no log line.
#   F  a command that is nothing but a BARE SHELL (`--command=powershell`, the
#      launch spelling of `command = powershell` in the config) runs that shell
#      UN-NESTED with shell integration (T514). Pre-fix the agent ran
#      `cmd /c powershell`: the user's shell nested under a hidden cmd.exe, the
#      integration argv rewrite dropped, and +list frozen on the wrapper's cwd.
#   G  the same is true of a bare shell with NO integration script (`wsl`) -
#      "did the user name their shell?" is a broader question than "which
#      integration script?", and T864 is the gap between them. Runs against a
#      stub named wsl.exe, never the real one (starting WSL boots a VM).
#   H  a shell chosen in Settings > Shell on a RUNNING app (T3734) reaches the
#      next new window, split and tab, with session persistence on AND off,
#      and survives a relaunch. Pre-fix, persistence on: every new pane still
#      ran cmd.exe, because the reload stored a clone of the config and
#      `Config.clone` dropped `_command-explicit`. `-Wsl` adds the real-WSL arm.
#   I  `--shell=wsl:<distro>` (T3735): a distro that is not installed is refused
#      by +new-window and +split, naming the installed ones, and opens nothing.
#      `-Wsl` adds the real arm: the pane runs `wsl.exe -d <distro> --cd ~`.
#   J  the shell list the pickers offer (T3750): cmd/PowerShell when found, Git
#      Bash when installed, one 'WSL: <distro>' per registered distro (no bare
#      WSL entry), read through `settings --op=shells`. A Git Bash pick (its
#      quoted path) reaches new panes with persistence on AND off - off, the
#      exec backend used to split the path at its space. `-Wsl` adds a distro
#      pick, which must run wsl.exe itself, not `cmd /c wsl.exe`.
#
# Non-interactive; asserts and exits nonzero on any failure. Hermetic: a per-run
# $env:LOCALAPPDATA + GHOSTTY_LOCAL_AGENT_BIN (so no real session-layout is
# restored over the window under test), and it ONLY ever kills ghoztty /
# ghoztty-agent processes launched from the repo zig-out.
#
#   powershell -NoProfile -File test\win32\gui-launch-command.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe',
    # Section H's WSL arm writes a bare `wsl.exe` through Settings and opens a
    # window on the REAL wsl.exe, which boots the WSL2 VM. CLAUDE.md: never
    # start WSL unasked, so it is opt-in and skipped with a reason otherwise.
    [switch]$Wsl
)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

# T1240: the GUI launches ON THE TEST DESKTOP, not on the user's. A window
# arrives on the desktop of whoever started the process, and this script starts
# eight of them - so it used to throw eight across whatever the user was
# reading. The CLI reads stay on `Run-Cli`: none of their verbs can create a
# process.
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$ErrorActionPreference = 'Continue'

# T1511: the shared scorer, and the dot-source is also what ARMS the run - a
# body that unwinds before `Complete-TestBody` may not print a pass, and the
# guard-stamping child below reads the same state and refuses to write.
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:failures = 0
$script:passes = 0
$script:skipped = 0
$root = Join-Path $env:TEMP "ghoztty-gui-launch-command-$PID"

function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ } else { "  FAIL $name"; $script:failures++ }
}
function AssertEq($name, $expected, $actual) {
    if ($expected -eq $actual) { "  PASS $name"; $script:passes++ }
    else { "  FAIL $name (expected '$expected', got '$actual')"; $script:failures++ }
}

# Kill ONLY zig-out ghoztty/agent processes (never the user's release build).
function Stop-TestProcs {
    # T351: one shared, path-exact kill (lib\CleanSlate.ps1) instead of a private
    # copy - the filter this replaced also matched a detached instance running from
    # zig-out-release (T53b), and every copy answered "does the agent go too" alone.
    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 900)
}
function Count-TestProcs($name) {
    # T3402: path-exact, like the kills above. The old '*zig-out*' filter also
    # counted the OTHER loop lane's apps on this box (and other workers'
    # mirrors), so D4/E3 read 1-2 strangers as this run's processes.
    $want = if ($name -ieq 'ghoztty-agent.exe') { $AgentExe } else { $Exe }
    $want = [System.IO.Path]::GetFullPath($want)
    return @(Get-CimInstance Win32_Process -Filter "Name='$name'" |
        Where-Object { $_.ExecutablePath -and ($_.ExecutablePath -ieq $want) }).Count
}
# Kill the APP but leave the agent running - the "quit/crash, then relaunch"
# shape section D needs, since the agent is what keeps the sessions alive for
# the next launch to re-attach to.
function Stop-TestApp {
    # T351: the shared, path-exact kill (lib\CleanSlate.ps1). -AppOnly is the
    # point of this helper - the agent (and its PTYs) stay up - and exact-exe is
    # what the private copy's '*zig-out*' filter got wrong: that also matched a
    # detached instance running from zig-out-release (T53b).
    [void](Stop-RepoGhoztty -Exe $Exe -AppOnly -SettleMs 900)
}

function Run-Cli($argsLine, $out, $timeoutSec = 20) {
    $p = Start-Process -FilePath cmd.exe -WindowStyle Hidden -PassThru `
        -ArgumentList "/c `"`"$Exe`" $argsLine > `"$out`" 2>&1`""
    $null = $p.Handle   # before any wait, or ExitCode reads empty (lib\ExitCodeAudit.ps1)
    if (-not $p.WaitForExit($timeoutSec * 1000)) {
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        return $null
    }
    return $p.ExitCode
}
function Out-Text($f) { if (Test-Path $f) { Get-Content $f -Raw } else { '' } }

# ---- +list helpers ---------------------------------------------------------
function Find-Leaf($node) {
    if ($null -eq $node) { return $null }
    if ($node.type -eq 'leaf') { return $node.terminal }
    if ($node.type -eq 'split') {
        $l = Find-Leaf $node.left
        if ($null -ne $l) { return $l }
        return (Find-Leaf $node.right)
    }
    return $null
}
function Windows-Of($tree) {
    if ($null -eq $tree) { return @() }
    if ($null -ne $tree.data) { return @($tree.data.windows) }
    return @($tree.windows)
}
# Every terminal leaf in one `+list --json` snapshot, flattened across windows
# and tabs. Section D needs the whole tree, not just the head of it: after a
# restoring launch the requested pane and the rebuilt ones are siblings and
# nothing promises which comes first.
function Leaves-Of-Node($node) {
    if ($null -eq $node) { return @() }
    if ($node.type -eq 'leaf') { return @($node.terminal) }
    if ($node.type -eq 'split') {
        return @(Leaves-Of-Node $node.left) + @(Leaves-Of-Node $node.right)
    }
    return @()
}
function Snapshot-Windows($tmp, $tag) {
    Run-Cli '+list --json' "$tmp\list-$tag.json" 20 | Out-Null
    $tree = $null
    try { $tree = (Out-Text "$tmp\list-$tag.json" | ConvertFrom-Json) } catch {}
    return @(Windows-Of $tree)
}
function Leaves-Of-Windows($windows) {
    $out = @()
    foreach ($w in @($windows)) {
        foreach ($t in @($w.tabs)) { $out += @(Leaves-Of-Node $t.splits) }
    }
    return $out
}

# The name of the first pane of the first window, or '' if there is none yet.
function First-Pane($tmp, $tag, $timeoutSec = 45) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        Run-Cli '+list --json' "$tmp\list-$tag.json" 20 | Out-Null
        $tree = $null
        try { $tree = (Out-Text "$tmp\list-$tag.json" | ConvertFrom-Json) } catch {}
        foreach ($w in (Windows-Of $tree)) {
            foreach ($t in @($w.tabs)) {
                $leaf = Find-Leaf $t.splits
                if ($null -ne $leaf) { return $leaf.name }
            }
        }
        Start-Sleep -Milliseconds 700
    }
    return ''
}
# Poll a pane's scrollback until $needle shows up (or we run out of patience).
# Polling, not one read: the command is spawned asynchronously by the agent and
# a single early read is how a working feature reads as broken.
function Wait-PaneText($tmp, $tag, $pane, $needle, $timeoutSec = 40) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $last = ''
    while ((Get-Date) -lt $deadline) {
        Run-Cli "+read --name=$pane --lines=60" "$tmp\read-$tag.txt" 15 | Out-Null
        $last = Out-Text "$tmp\read-$tag.txt"
        # Contains, never -like: the markers here carry `[` and `]`, which -like
        # reads as a wildcard CHARACTER CLASS. A malformed pattern throws, the
        # Assert around it never runs, and the script still prints ALL PASS -
        # green and empty, which is worse than a failure.
        if ([string]$last -ne '' -and ([string]$last).Contains($needle)) { return $last }
        Start-Sleep -Milliseconds 800
    }
    return $last
}
# Same idea across EVERY pane in the tree: returns the name of the first pane
# whose scrollback contains $needle, or '' if none does before the deadline.
function Wait-AnyPaneText($tmp, $tag, $needle, $timeoutSec = 60) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $i = 0
    while ((Get-Date) -lt $deadline) {
        foreach ($leaf in (Leaves-Of-Windows (Snapshot-Windows $tmp "$tag-$i"))) {
            if ([string]$leaf.name -eq '') { continue }
            Run-Cli "+read --name=$($leaf.name) --lines=60" "$tmp\read-$tag-$i.txt" 15 | Out-Null
            $t = [string](Out-Text "$tmp\read-$tag-$i.txt")
            if ($t -ne '' -and $t.Contains($needle)) { return $leaf.name }
        }
        $i++
        Start-Sleep -Milliseconds 900
    }
    return ''
}

# One hermetic GUI launch, on the test desktop (T1240). $launchArgs is an argv
# LIST: an element that must survive as one entry (a `--command=` with spaces)
# is quoted by the harness, so it no longer has to carry its own quotes - the
# trap that made an early T104 repro look like a parser bug is now the harness's
# job rather than each call site's.
function Launch($tmp, $launchArgs) {
    New-Item -ItemType Directory -Force (Get-GhozttyAgentStateDir -Root $tmp) | Out-Null
    $env:LOCALAPPDATA = $tmp
    $env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe
    # persistence: on (default), into a throwaway $env:LOCALAPPDATA - section D asserts a launch command and a RESTORE both happen.
    if ($null -eq $launchArgs) { $launchArgs = @() }
    [void](Start-OnTestDesktop -Exe $Exe -Arguments $launchArgs)
}

$td = New-TestDesktop

Stop-TestProcs
New-Item -ItemType Directory -Force $root | Out-Null
$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN

# T441: this run's own IPC endpoint, and the LOCALAPPDATA redirect in Launch()
# does not cover it — the endpoint a CLI dials comes from the pane's baked
# `$GHOZTTY_IPC_SOCKET` unless a suffix outranks it, so without this the +list
# and +read calls below answer from the user's installed release.
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 'guilaunch')
Assert-GhozttyPrivateEndpoint -Exe $Exe

Assert "ghoztty exe exists in zig-out" (Test-Path $Exe)
Assert "agent binary exists in zig-out" (Test-Path $AgentExe)

# The command under test: a script that echoes its own arguments and then stays
# alive, so the pane is still readable when we get there. It lives at a path with
# no spaces so the assertion is about argument PASSING, not about quoting a path.
$script = Join-Path $root 'marker.cmd'
@(
    '@echo off'
    'echo T104ARGS=[%1][%2][%3]'
    'pause'
) | Set-Content -Path $script -Encoding ASCII
Assert "the marker script path has no spaces" (-not ($script -like '* *'))

# ============================================================================
"== A: -e <command> <args...> runs in the first window (persistence default)"
# ============================================================================
$tmpA = Join-Path $root 'a'
Launch $tmpA @('-e', $script, 'alpha', 'beta')
$paneA = First-Pane $tmpA 'a' 60
Assert "A1 the launch opened a window with a pane" ($paneA -ne '')
Assert-GhozttyIsolated -Exe $Exe

$textA = [string](Wait-PaneText $tmpA 'a' $paneA 'T104ARGS=' 60)
Assert "A2 the -e command RAN (pre-fix: a bare shell prompt)" ($textA.Contains('T104ARGS='))
Assert "A3 its arguments arrived in order" ($textA.Contains('T104ARGS=[alpha][beta][]'))

# Session persistence is at its default here, so this pane's process belongs to
# the agent - that is precisely the backend that used to drop the command.
Assert "A4 the pane is agent-backed (the backend the command was dropped on)" `
    ((Count-TestProcs 'ghoztty-agent.exe') -ge 1)

Stop-TestProcs

# ============================================================================
"== B: --command=... on the same launch path"
# ============================================================================
# ONE argv entry with spaces in it - the harness quotes it (see Launch's note).
$tmpB = Join-Path $root 'b'
Launch $tmpB @("--command=$script gamma delta")
$paneB = First-Pane $tmpB 'b' 60
Assert "B1 the launch opened a window with a pane" ($paneB -ne '')

$textB = [string](Wait-PaneText $tmpB 'b' $paneB 'T104ARGS=' 60)
Assert "B2 the --command RAN (pre-fix: a bare shell prompt)" ($textB.Contains('T104ARGS='))
Assert "B3 its arguments arrived in order" ($textB.Contains('T104ARGS=[gamma][delta][]'))

Stop-TestProcs

# ============================================================================
"== C: a plain launch forwards NO command"
# ============================================================================
# `Config.finalize` fills `command` with the default shell when nothing asked for
# one, so after finalize the field is never null. Treating that as an explicit
# request would send the local shell path to the agent as a COMMAND - the wedge
# the explicit-only rule exists to prevent. The oracle is the agent's own record.
$tmpC = Join-Path $root 'c'
Launch $tmpC @()
$paneC = First-Pane $tmpC 'c' 60
Assert "C1 the plain launch opened a window with a pane" ($paneC -ne '')

# One token plus Enter - `+send-keys` concatenates its positional arguments, so a
# space-free marker needs no quoting through the cmd.exe wrapper. cmd echoes what
# is typed and then complains it is not a command; either way the marker reaching
# the scrollback proves a LIVE interactive shell rather than a finished command.
Run-Cli "+send-keys --target=$paneC T104INTERACTIVE Enter" "$tmpC\sk.txt" 15 | Out-Null
$textC = [string](Wait-PaneText $tmpC 'c' $paneC 'T104INTERACTIVE' 40)
Assert "C2 the pane is an interactive shell" ($textC.Contains('T104INTERACTIVE'))
Assert "C3 no command marker leaked into a plain launch" (-not $textC.Contains('T104ARGS='))

# The agent records the command it was OPENed with; a plain launch must have none.
Run-Cli '+sessions --json' "$tmpC\sessions.json" 20 | Out-Null
$rows = @()
try { $rows = @((Out-Text "$tmpC\sessions.json") | ConvertFrom-Json) } catch {}
$withCmd = @($rows | Where-Object { $null -ne $_.argv -and $_.argv -ne '' })
Assert "C4 the agent recorded NO command for the plain launch" ($withCmd.Count -eq 0)

Stop-TestProcs

# ============================================================================
"== D: a launch command survives session restore (T406)"
# ============================================================================
# The defect: session persistence is ON by default, so the SECOND launch of the
# day has a layout to rebuild - and launch-time restore rebuilt it and dropped
# the command entirely. Nothing was logged and the exit code was 0, so it read
# as "the T104 fix does not work" (it was reproduced twice that way before it
# was understood). Core `Surface.init` hands `initial-command` to whichever
# surface is `app.first`, and on a restoring launch that is a RESTORED pane -
# which ATTACHes to a session that already exists and has nowhere to run it.
#
# The rule: do BOTH. Restore what the user left behind AND open the window they
# just asked for. The requested window is created before restore so it is the
# one `app.first` names.
$tmpD = Join-Path $root 'd'

# --- launch 1: seed a session to come back to -------------------------------
Launch $tmpD @()
$paneD0 = First-Pane $tmpD 'd0' 60
Assert "D1 the seeding launch opened a window with a pane" ($paneD0 -ne '')
$leavesD0 = @(Leaves-Of-Windows (Snapshot-Windows $tmpD 'd0-ids'))
$seedId = if ($leavesD0.Count -ge 1) { [string]$leavesD0[0].id } else { '' }
Assert "D2 the seed pane reports a stable pane id" ($seedId -ne '')

# Kill the APP only. The agent keeps the PTY alive, which is exactly the state a
# quit (or a crash) leaves behind and what the next launch re-attaches to. The
# sleep is for the 250ms debounced layout capture to reach disk.
Start-Sleep -Seconds 3
Stop-TestApp
Assert "D3 the agent outlived the app" ((Count-TestProcs 'ghoztty-agent.exe') -ge 1)
AssertEq "D4 the app is gone" 0 (Count-TestProcs 'ghoztty.exe')

# --- launch 2: same state dir (so there IS a restore) AND a command ---------
Launch $tmpD @('-e', $script, 'omega', 'psi')
$cmdPane = Wait-AnyPaneText $tmpD 'd1' 'T104ARGS=[omega][psi][]' 90
Assert "D5 the -e command RAN despite the restore (pre-fix: silently dropped)" `
    ($cmdPane -ne '')

# The negative control: without this, D5 could pass simply because restore did
# nothing at all, which is not the case under test.
$winsD = @(Snapshot-Windows $tmpD 'd2')
Assert "D6 restore also rebuilt the previous window (>= 2 windows)" ($winsD.Count -ge 2)
$idsD = @(Leaves-Of-Windows $winsD | ForEach-Object { [string]$_.id })
Assert "D7 the seed pane came back with its own pane id" ($idsD -contains $seedId)
# T2842: and NOTHING ELSE came back. On 2026-11-08 a crash-recovery launch with
# `--initial-command` put up the command window AND a second window holding a
# bare shell under the SAME pane id, so every `--target=<id>` after it answered
# "ambiguous" and the go-loop could not mark its own window. D6 (>= 2) passes
# with that duplicate on screen; these two do not.
AssertEq "D8 exactly the seed window and the command window (T2842: no duplicate)" 2 $winsD.Count
$dupIds = @($idsD | Where-Object { $_ -ne '' } | Group-Object | Where-Object { $_.Count -gt 1 } |
    ForEach-Object { $_.Name })
Assert "D9 no pane id is issued to two panes (T2842; dup: $($dupIds -join ','))" ($dupIds.Count -eq 0)

Stop-TestProcs

# ============================================================================
"== E: a second launch forwards -e and --working-directory to the running instance (T487)"
# ============================================================================
# The AlreadyRunning arm in win32 App.init forwards `new-window` to whoever owns
# the IPC pipe. Pre-fix the payload was null: the second launch's parsed
# `initial-command` and working directory were thrown away, the running instance
# opened a PLAIN window, and the exit code was 0 - so E2/E4 fail without the fix
# while E1 (a window opened either way) passes, which is exactly the trap the
# header warns about.
$tmpE = Join-Path $root 'e'
$wdE = Join-Path $root 'wd487'
New-Item -ItemType Directory -Force $wdE | Out-Null

# A distinct marker script: echoes its args AND the directory it woke up in.
$scriptE = Join-Path $root 'marker487.cmd'
@(
    '@echo off'
    'echo T487ARGS=[%1][%2]'
    'echo T487CWD=[%CD%]'
    'pause'
) | Set-Content -Path $scriptE -Encoding ASCII

# --- launch 1: a plain instance that owns the pipe --------------------------
Launch $tmpE @()
$paneE0 = First-Pane $tmpE 'e0' 60
Assert "E1 the first launch opened a window with a pane" ($paneE0 -ne '')

# --- launch 2: same endpoint, WITH a command and a cwd ----------------------
# `--working-directory` must come BEFORE `-e`: the launch parser hands
# everything after `-e` to the command argv, exactly like the CLI verb.
Launch $tmpE @("--working-directory=$wdE", '-e', $scriptE, 'omega487', 'psi487')

$cmdPaneE = Wait-AnyPaneText $tmpE 'e1' 'T487ARGS=[omega487][psi487]' 90
Assert "E2 the -e command RAN in the running instance (pre-fix: dropped)" ($cmdPaneE -ne '')

# The forwarding process hands off and exits; only the first instance remains.
Start-Sleep -Milliseconds 1500
AssertEq "E3 the second launch process exited after forwarding" 1 (Count-TestProcs 'ghoztty.exe')

if ($cmdPaneE -ne '') {
    $textE = [string](Wait-PaneText $tmpE 'e2' $cmdPaneE 'T487CWD=' 40)
    Assert "E4 the launch's --working-directory reached the new pane" `
        ($textE.ToLower().Contains("t487cwd=[$($wdE.ToLower())]"))
} else {
    "  FAIL E4 the launch's --working-directory reached the new pane (no command pane to read)"
    $script:failures++
}

Stop-TestProcs

# ============================================================================
"== F: a bare-shell --command runs UN-NESTED with shell integration (T514)"
# ============================================================================
# `--command=powershell` is the launch spelling of `command = powershell` in
# the config file - same config key, same `_command-explicit` signal, same
# Surface.init path. A bare recognized shell is a shell CHOICE: it must travel
# as OPEN.shell (un-nested, integrated), not OPEN.command (`cmd /c powershell`).
$tmpF = Join-Path $root 'f'
$wdF = Join-Path $root 'wd514'
New-Item -ItemType Directory -Force $wdF | Out-Null

Launch $tmpF @('--command=powershell')
$paneF = First-Pane $tmpF 'f' 60
Assert "F1 the launch opened a window with a pane" ($paneF -ne '')

# The leaf's pid is the agent-reported shell process - the process the agent
# actually spawned. Pre-fix that was the cmd.exe wrapper; the user's shell ran
# nested one level below it. Poll: the pid arrives with the agent's OPENED.
$leafF = $null
$deadlineF = (Get-Date).AddSeconds(45)
while ((Get-Date) -lt $deadlineF) {
    $leaves = @(Leaves-Of-Windows (Snapshot-Windows $tmpF 'f-pid'))
    $leafF = @($leaves | Where-Object { [string]$_.name -eq $paneF })[0]
    if ($null -ne $leafF -and [int]$leafF.pid -gt 0) { break }
    Start-Sleep -Milliseconds 700
}
$shellProcF = $null
if ($null -ne $leafF -and [int]$leafF.pid -gt 0) {
    $shellProcF = Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$leafF.pid)"
}
AssertEq "F2 the pane's shell IS powershell (pre-fix: a nested cmd.exe wrapper)" `
    'powershell.exe' ([string]$shellProcF.Name)
Assert "F3 the shell's command line carries the integration rewrite (ghostty.ps1)" `
    ([string]$shellProcF.CommandLine -match '(?i)ghostty\.ps1')

# Integration-visible behavior: a cd inside the pane shows up in +list. The
# quoted token keeps `cd <path>` one argument through the cmd.exe wrapper.
Run-Cli "+send-keys --target=$paneF `"cd $wdF`" Enter" "$tmpF\sk.txt" 15 | Out-Null
$gotWdF = ''
$deadlineF = (Get-Date).AddSeconds(40)
while ((Get-Date) -lt $deadlineF) {
    $leaves = @(Leaves-Of-Windows (Snapshot-Windows $tmpF 'f-wd'))
    $l = @($leaves | Where-Object { [string]$_.name -eq $paneF })[0]
    if ($null -ne $l -and ([string]$l.working_directory).ToLower() -eq $wdF.ToLower()) {
        $gotWdF = [string]$l.working_directory
        break
    }
    Start-Sleep -Milliseconds 800
}
Assert "F4 +list follows an in-pane cd (pre-fix: frozen on the wrapper's cwd)" ($gotWdF -ne '')

Stop-TestProcs

# ============================================================================
"== G: a bare shell with NO integration is still un-nested (T864)"
# ============================================================================
# Section F's shells all have an integration script, and until T864 that was
# the whole test: `bareShellCommand` asked `detectShell`, which answers "which
# integration script?" rather than "did the user name their shell?". For `wsl`
# the answers differ - no script exists, but it is plainly a shell choice - so
# a bare `--command=wsl` fell through to OPEN.command and the agent ran
# `cmd /c wsl`: a hidden wrapper process per pane, `+list` naming the wrapper
# as the shell, and cwd tracking following the wrapper.
#
# The pane here runs a STUB named wsl.exe (a copy of cmd.exe in a private
# directory), never the real one: starting real WSL boots the WSL2 VM, which
# is the user's call and not a test's to make. The stub is exact for what this
# section asserts, because the whole routing decision is made from the NAME -
# `bare_shells_without_integration` in src/termio/shell_integration.zig
# matches on the basename, and nothing downstream of that looks at the binary.
# What the stub cannot cover (the real wsl actually starting a distro) is not
# a Ghoztty behavior.
#
# It is named by FULL PATH rather than put on $env:PATH, which was the first
# attempt and silently tested the wrong binary: CreateProcessW searches
# System32 BEFORE %PATH%, so nothing on PATH can ever shadow System32\wsl.exe
# and the section booted the real VM while reading green. G5 is what caught
# that and is what keeps it caught. Naming the full path also exercises the
# basename half of the match, which the bare spelling does not.
$stubG = Join-Path $root 'stubpath'
New-Item -ItemType Directory -Force $stubG | Out-Null
$stubWslG = Join-Path $stubG 'wsl.exe'
Copy-Item (Join-Path $env:SystemRoot 'System32\cmd.exe') $stubWslG -Force
Assert "G1 the wsl.exe stub exists and its path has no spaces" `
    ((Test-Path $stubWslG) -and -not ($stubWslG -like '* *'))

$tmpG = Join-Path $root 'g'
Launch $tmpG @("--command=$stubWslG")
$paneG = First-Pane $tmpG 'g' 60
Assert "G2 the launch opened a window with a pane" ($paneG -ne '')

# Same oracle as F2: the leaf pid IS the process the agent spawned. Pre-fix
# that was cmd.exe (the `cmd /c wsl` wrapper) with the shell one level below.
$leafG = $null
$deadlineG = (Get-Date).AddSeconds(45)
while ((Get-Date) -lt $deadlineG) {
    $leaves = @(Leaves-Of-Windows (Snapshot-Windows $tmpG 'g-pid'))
    $leafG = @($leaves | Where-Object { [string]$_.name -eq $paneG })[0]
    if ($null -ne $leafG -and [int]$leafG.pid -gt 0) { break }
    Start-Sleep -Milliseconds 700
}
$shellProcG = $null
if ($null -ne $leafG -and [int]$leafG.pid -gt 0) {
    $shellProcG = Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$leafG.pid)"
}
AssertEq "G3 the pane's shell IS wsl (pre-fix: a nested cmd.exe wrapper)" `
    'wsl.exe' ([string]$shellProcG.Name)
Assert "G4 and it was spawned as the shell, with no /c command tail" `
    (([string]$shellProcG.CommandLine) -notmatch '(?i)/c\s')
# Load-bearing, not belt-and-braces: if the private PATH did not reach the
# spawn, G3 passes against the REAL wsl.exe and this section quietly boots the
# WSL2 VM on every run. The stub's own path is the only thing that tells the
# two apart.
AssertEq "G5 and it was the STUB that ran, not the real WSL" `
    ($stubWslG.ToLower()) ([string]$shellProcG.ExecutablePath).ToLower()

Stop-TestProcs

# ============================================================================
"== H: a shell chosen in Settings on a running app reaches new panes (T3734)"
# ============================================================================
# The user's report: choose WSL in Settings > Shell, and every new window still
# opens cmd.exe. Sections A-G all set the command BEFORE launch; this one sets
# it the way the Settings window does, on an app that is already running, and
# reads each new pane's shell process (the leaf pid, as in F2/G3 - never a
# title). The write goes through the debug `settings` IPC action's `--op=shell`,
# which calls `SettingsWindow.chooseShell`, the function the Shell menu's pick
# calls. The shell is bare `powershell.exe`, exactly what the menu writes for
# Windows PowerShell, so the always-run arm proves the same route WSL takes
# without booting a VM.
#
# The root cause was in the shared core: the reload stored the new config via
# `Config.clone`, which copies Key fields only, so `_command-explicit` reset to
# false and the session-persistence agent path (default ON) fell back to the
# agent's own default shell. With persistence off the exec path never looks at
# the flag, which is why the off arm is the control: it was green pre-fix.
. (Join-Path $PSScriptRoot 'lib\PaneCapture.ps1')   # Invoke-GhozttyIpc

# The leaf pids in one snapshot, by pane name.
function Leaf-Pids($tmp, $tag) {
    $map = @{}
    foreach ($l in (Leaves-Of-Windows (Snapshot-Windows $tmp $tag))) {
        if ([string]$l.name -ne '') { $map[[string]$l.name] = [int]$l.pid }
    }
    return $map
}
# The process of the first pane NOT in $known, once it reports a pid.
function Wait-NewPaneShell($tmp, $tag, $known, $timeoutSec = 45) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $i = 0
    while ((Get-Date) -lt $deadline) {
        $m = Leaf-Pids $tmp "$tag-$i"
        foreach ($k in $m.Keys) {
            if ($known.ContainsKey($k) -or $m[$k] -le 0) { continue }
            $p = Get-CimInstance Win32_Process -Filter "ProcessId=$($m[$k])"
            if ($null -ne $p) { return [pscustomobject]@{ Name = $k; Proc = $p } }
        }
        $i++
        Start-Sleep -Milliseconds 700
    }
    return $null
}
function Shell-Name($found) { if ($null -eq $found) { return '(no new pane)' } return [string]$found.Proc.Name }

# One Settings-write run. $persist is the --session-persistence value, $shell
# what the Shell row is set to, $want the process name its panes must run.
function Run-SettingsShell($id, $persist, $shell, $want) {
    $tmp = Join-Path $root "h-$id"
    $xdg = Join-Path $tmp 'xdg'
    New-Item -ItemType Directory -Force (Join-Path $xdg 'ghostty') | Out-Null
    $cfg = Join-Path $xdg 'ghostty\config-debug.ghostty'
    [System.IO.File]::WriteAllText($cfg, "font-size = 13`n")
    New-Item -ItemType Directory -Force (Get-GhozttyAgentStateDir -Root $tmp) | Out-Null
    $env:LOCALAPPDATA = $tmp
    $env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe
    $env:XDG_CONFIG_HOME = $xdg
    $env:GHOZTTY_SETTINGS_BACKUP_DIR = Join-Path $tmp 'backups'
    $app = $null
    try {
        # F9 opens a tab: no CLI verb does, and a posted keybind works on the
        # background desktop (hidden-window-memory.ps1 section T).
        # persistence: both, from $persist - H runs this once on and once off, into a throwaway $env:LOCALAPPDATA.
        $app = Start-OnTestDesktop -Exe $Exe -Arguments @("--session-persistence=$persist", '--keybind=f9=new_tab')
    } finally {
        Remove-Item Env:XDG_CONFIG_HOME -ErrorAction SilentlyContinue
        Remove-Item Env:GHOZTTY_SETTINGS_BACKUP_DIR -ErrorAction SilentlyContinue
    }
    $first = First-Pane $tmp "h-$id" 60
    Assert "H$id.1 the app opened a window with a pane (persistence=$persist)" ($first -ne '')

    # The control: before any write, a new window is the default cmd.exe -
    # so the oracle below can tell the two shells apart.
    $known = Leaf-Pids $tmp "h-$id-k0"
    Run-Cli '+new-window' "$tmp\nw0.txt" 20 | Out-Null
    $pre = Wait-NewPaneShell $tmp "h-$id-pre" $known
    AssertEq "H$id.2 before the Settings write a new window runs the default shell" 'cmd.exe' (Shell-Name $pre)

    $s = Invoke-GhozttyIpc -Action 'settings' -Arguments @('--op=action')
    Assert "H$id.3 the Settings window opened" ($null -ne $s -and [bool]$s.success)
    $s = Invoke-GhozttyIpc -Action 'settings' -Arguments @('--op=shell', '--key=command', "--value=$shell")
    $text = if (Test-Path $cfg) { [System.IO.File]::ReadAllText($cfg) } else { '' }
    Assert "H$id.4 the Shell pick wrote command = $shell to the config" `
        ($null -ne $s -and [bool]$s.data.ok -and $text -match ('(?m)^command = (' + [regex]::Escape($shell) + '|"' + [regex]::Escape($shell) + '")\r?$'))
    # (The second form: the config reader strips one pair of surrounding
    # quotes, so a value that is itself quoted - Git Bash's spaced path,
    # T3750 - is written wrapped once more, and reads back as written.)

    $known = Leaf-Pids $tmp "h-$id-k1"
    Run-Cli '+new-window' "$tmp\nw1.txt" 20 | Out-Null
    $nw = Wait-NewPaneShell $tmp "h-$id-nw" $known
    AssertEq "H$id.5 a new window runs $want (persistence=$persist; pre-fix with persistence on: cmd.exe)" $want (Shell-Name $nw)

    $known = Leaf-Pids $tmp "h-$id-k2"
    Run-Cli "+split --target=$first --direction=right" "$tmp\sp.txt" 20 | Out-Null
    $sp = Wait-NewPaneShell $tmp "h-$id-sp" $known
    AssertEq "H$id.6 a new split runs $want (persistence=$persist)" $want (Shell-Name $sp)

    $known = Leaf-Pids $tmp "h-$id-k3"
    $tab = $null
    $top = if ($app) { Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow' } else { [IntPtr]::Zero }
    if ($top -ne [IntPtr]::Zero) {
        $vis = @(Get-TestChildWindows -Window ([IntPtr]$top) -Class 'GhozttyTerminal' | Where-Object Visible)
        if ($vis.Count -ge 1) {
            [void](Send-TestKeys -Window ([IntPtr]$top) -Target ([IntPtr]$vis[0].Hwnd) -Key F9)
            $tab = Wait-NewPaneShell $tmp "h-$id-tab" $known
        }
    }
    AssertEq "H$id.7 a new tab runs $want (persistence=$persist)" $want (Shell-Name $tab)
    # Not `return`: the asserts above write to the pipeline, which IS the
    # return value, so a returned path would arrive glued to every PASS line.
    $script:lastSettingsShellTmp = $tmp
}

Run-SettingsShell '1' 'true' 'powershell.exe' 'powershell.exe'
$tmpH1 = $script:lastSettingsShellTmp
# The relaunch: the written config read at launch, persistence on.
Stop-TestProcs
$xdgH1 = Join-Path $tmpH1 'xdg'
$tmpH1r = Join-Path $root 'h-1r'
New-Item -ItemType Directory -Force (Get-GhozttyAgentStateDir -Root $tmpH1r) | Out-Null
$env:LOCALAPPDATA = $tmpH1r
$env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe
$env:XDG_CONFIG_HOME = $xdgH1
# persistence: on (default) - the relaunch arm reads the written config the way a user's next launch does, into a throwaway $env:LOCALAPPDATA.
try { [void](Start-OnTestDesktop -Exe $Exe -Arguments @()) } finally { Remove-Item Env:XDG_CONFIG_HOME -ErrorAction SilentlyContinue }
$relaunch = Wait-NewPaneShell $tmpH1r 'h-1r' @{} 60
AssertEq "H1.8 after a relaunch the first window runs powershell.exe" 'powershell.exe' (Shell-Name $relaunch)
Stop-TestProcs

Run-SettingsShell '2' 'false' 'powershell.exe' 'powershell.exe'
Stop-TestProcs

# The real thing: bare wsl.exe as the menu writes it, resolved from System32
# by the spawn. Runs when asked (-Wsl, which may boot the VM) or when a distro
# is ALREADY running, so it starts nothing (T1751's gate; asking the distro
# table starts nothing either).
. (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'scripts\lib\WslState.ps1')
if ($Wsl -or (Test-WslDefaultDistroRunning)) {
    Run-SettingsShell '3' 'true' 'wsl.exe' 'wsl.exe'
    Stop-TestProcs
} else {
    $script:skipped++
    "  SKIP H3 the real-WSL arm - $(Get-WslSkipReason); pass -Wsl to run it (it boots the WSL2 VM)"
}

# ---- I: --shell=wsl:<distro> (T3735) ---------------------------------------
# A distro that is not installed is REFUSED, naming the installed ones, and
# nothing opens - read from the registry, so this arm starts no WSL. The real
# distro arm (the pane runs `wsl.exe -d <distro> --cd ~`) is gated like H3.
$tmpI = Join-Path $root 'i'
New-Item -ItemType Directory -Force (Get-GhozttyAgentStateDir -Root $tmpI) | Out-Null
$env:LOCALAPPDATA = $tmpI
$env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe
# persistence: on (default) - the agent-backed path is the one that carries OPEN.argv, into a throwaway $env:LOCALAPPDATA.
[void](Start-OnTestDesktop -Exe $Exe -Arguments @())
$firstI = First-Pane $tmpI 'i' 60
Assert "I.1 the app opened a window with a pane" ($firstI -ne '')
$knownI = Leaf-Pids $tmpI 'i-k0'
$rcI = Run-Cli '+new-window --shell=wsl:NoSuchDistroT3735' "$tmpI\nw.txt" 20
$outI = Out-Text "$tmpI\nw.txt"
Assert "I.2 +new-window --shell=wsl:<not installed> exits nonzero (got $rcI)" ($null -ne $rcI -and $rcI -ne 0)
Assert "I.3 the refusal says no such distro is installed (got: $($outI.Trim()))" ($outI -match 'no WSL distro')
$rcS = Run-Cli "+split --target=$firstI --direction=right --shell=wsl:NoSuchDistroT3735" "$tmpI\sp.txt" 20
Assert "I.4 +split --shell=wsl:<not installed> is refused too (got $rcS)" ($null -ne $rcS -and $rcS -ne 0 -and (Out-Text "$tmpI\sp.txt") -match 'no WSL distro')
$afterI = Leaf-Pids $tmpI 'i-k1'
AssertEq "I.5 neither refusal opened a pane" $knownI.Count $afterI.Count

if ($Wsl -or (Test-WslDefaultDistroRunning)) {
    $lxss = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
    $distro = @(Get-ChildItem $lxss -ErrorAction SilentlyContinue | ForEach-Object { (Get-ItemProperty $_.PSPath).DistributionName } |
        Where-Object { $_ -and $_ -notlike 'docker-desktop*' }) | Select-Object -First 1
    if ($distro) {
        $knownW = Leaf-Pids $tmpI 'i-k2'
        Run-Cli "+new-window --shell=wsl:$distro" "$tmpI\nww.txt" 30 | Out-Null
        $w = Wait-NewPaneShell $tmpI 'i-w' $knownW 60
        AssertEq "I.6 +new-window --shell=wsl:$distro runs wsl.exe" 'wsl.exe' (Shell-Name $w)
        $cl = if ($w) { [string]$w.Proc.CommandLine } else { '' }
        Assert "I.7 the pane runs that distro in its home: -d $distro --cd ~ (got: $cl)" `
            ($cl -match ('-d\s+"?' + [regex]::Escape($distro) + '"?\s+--cd\s+~'))
        # A folder the caller DID ask for replaces the ~ (the CLI's own cwd,
        # marked --cwd-implicit, never does - that is I.7).
        $knownW = Leaf-Pids $tmpI 'i-k3'
        Run-Cli "+new-window --shell=wsl:$distro --working-directory=$env:SystemRoot" "$tmpI\nww2.txt" 30 | Out-Null
        $w2 = Wait-NewPaneShell $tmpI 'i-w2' $knownW 60
        $cl2 = if ($w2) { [string]$w2.Proc.CommandLine } else { '' }
        Assert "I.8 an explicit --working-directory reaches wsl --cd (got: $cl2)" `
            ($cl2 -match ('--cd\s+"?' + [regex]::Escape($env:SystemRoot) + '"?'))
    } else {
        $script:skipped++
        "  SKIP I.6-I.7 the real-distro arm - no user distro is registered"
    }
} else {
    $script:skipped++
    "  SKIP I.6-I.7 the real-distro arm - $(Get-WslSkipReason); pass -Wsl to run it (it boots the WSL2 VM)"
}
Stop-TestProcs

# ---- J: the shell list the pickers offer (T3750) ---------------------------
# Settings > Shell (and the per-pane pickers after it) list the found common
# shells, Git Bash, and one 'WSL: <distro>' per installed distro. The list is
# read back through the debug `settings --op=shells` seam, which returns
# `SettingsWindow.installedShells` - the function the menu builds from - and
# is checked against the registry (so nothing here starts WSL) and the disk.
# Then a pick of each NEW kind is written the way the menu writes it and must
# reach the next window: Git Bash always (when installed), a distro under -Wsl.
$tmpJ = Join-Path $root 'j'
New-Item -ItemType Directory -Force (Get-GhozttyAgentStateDir -Root $tmpJ) | Out-Null
$env:LOCALAPPDATA = $tmpJ
$env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe
# persistence: on (default) - only the IPC seam is read here, into a throwaway $env:LOCALAPPDATA.
[void](Start-OnTestDesktop -Exe $Exe -Arguments @())
$firstJ = First-Pane $tmpJ 'j' 60
Assert "J.1 the app opened a window with a pane" ($firstJ -ne '')
$sj = Invoke-GhozttyIpc -Action 'settings' -Arguments @('--op=shells')
$shells = if ($null -ne $sj -and [bool]$sj.success) { @($sj.data.shells | ForEach-Object { $_ }) } else { @() }
Assert "J.2 --op=shells answered with a list (got $($shells.Count))" ($shells.Count -gt 0)
$labels = @($shells | ForEach-Object { [string]$_.label })
Assert "J.3 Command Prompt is offered" ($labels -contains 'Command Prompt (cmd.exe)')
Assert "J.4 the bare 'WSL (wsl.exe)' entry is gone - each distro is its own entry" (-not ($labels -contains 'WSL (wsl.exe)'))
# The app's LOCALAPPDATA is $tmpJ, so its per-user candidate is there.
$gitBash = @("$env:ProgramFiles\Git\bin\bash.exe", "${env:ProgramFiles(x86)}\Git\bin\bash.exe", "$tmpJ\Programs\Git\bin\bash.exe") |
    Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1
$gbEntry = @($shells | Where-Object { $_.label -eq 'Git Bash (bash.exe)' }) | Select-Object -First 1
if ($gitBash) {
    Assert "J.5 Git Bash is offered when installed ($gitBash)" ($null -ne $gbEntry -and $gbEntry.spec -eq $gitBash)
    $wantCmd = if ($gitBash -match '\s') { '"' + $gitBash + '"' } else { $gitBash }
    AssertEq "J.6 Git Bash's command form is its path, quoted when spaced" $wantCmd ([string]$gbEntry.command)
} else {
    Assert "J.5 Git Bash is not offered when it is not installed" ($null -eq $gbEntry)
}
$lxssJ = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
$distrosJ = @(Get-ChildItem $lxssJ -ErrorAction SilentlyContinue | ForEach-Object { (Get-ItemProperty $_.PSPath).DistributionName } |
    Where-Object { $_ -and $_ -notlike 'docker-desktop*' } | Sort-Object -Unique)
$wslEntries = @($shells | Where-Object { ([string]$_.label).StartsWith('WSL: ') })
AssertEq "J.7 one 'WSL: <distro>' entry per installed distro" $distrosJ.Count $wslEntries.Count
foreach ($d in $distrosJ) {
    $e = @($wslEntries | Where-Object { $_.label -eq "WSL: $d" }) | Select-Object -First 1
    Assert "J.8 WSL: $d writes 'wsl.exe -d $d --cd ~' and --shell form 'wsl:$d'" `
        ($null -ne $e -and $e.command -eq "wsl.exe -d $d --cd ~" -and $e.spec -eq "wsl:$d")
}
Stop-TestProcs

if ($gitBash) {
    # The quoted path is the form the exec backend used to split at the
    # space (persistence off: no pane at all); the agent path read it whole.
    $gbCmd = if ($gitBash -match '\s') { '"' + $gitBash + '"' } else { $gitBash }
    Run-SettingsShell 'J1' 'true' $gbCmd 'bash.exe'
    Stop-TestProcs
    Run-SettingsShell 'J2' 'false' $gbCmd 'bash.exe'
    Stop-TestProcs
} else {
    $script:skipped++
    "  SKIP J1-J2 the Git Bash pick - Git for Windows is not installed"
}

# A distro pick reaches the next window as wsl.exe itself - pre-fix the agent
# ran `cmd /c wsl.exe -d ...`, so the pane's process was cmd.exe.
if (($Wsl -or (Test-WslDefaultDistroRunning)) -and $distrosJ.Count -gt 0) {
    $dJ = $distrosJ[0]
    Run-SettingsShell 'J3' 'true' "wsl.exe -d $dJ --cd ~" 'wsl.exe'
    Stop-TestProcs
} else {
    $script:skipped++
    "  SKIP J3 the distro pick - $(if ($distrosJ.Count -eq 0) { 'no user distro is registered' } else { Get-WslSkipReason }); pass -Wsl to run it (it boots the WSL2 VM)"
}

# ---- teardown --------------------------------------------------------------
Stop-TestProcs
$env:LOCALAPPDATA = $savedLocalAppData
if ($null -eq $savedAgentBin) {
    Remove-Item Env:\GHOSTTY_LOCAL_AGENT_BIN -ErrorAction SilentlyContinue
} else {
    $env:GHOSTTY_LOCAL_AGENT_BIN = $savedAgentBin
}
Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
Remove-TestDesktop | Out-Null

# A green run stamps the covered files (T783) so guard-due can answer "has
# this harness been run as it now stands?". Red leaves the stamp alone.
Complete-TestBody  # T1039: before the stamp, a child process that reads this run's state
if ($script:failures -eq 0) {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard gui-launch-command -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

""
Write-TestVerdict -Pass $script:passes -Fail $script:failures -Skipped ([int]$script:skipped)
