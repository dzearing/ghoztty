# T145 acceptance: IN-PLACE local-agent crash recovery.
#
# The defect: when the local ghoztty-agent dies while the GUI stays up, every
# persistent pane is frozen — its PTY went with the agent and the app's shared
# connection is dead. Before T145 the panes stayed dead until the user quit and
# relaunched, which is the exact failure session persistence exists to prevent.
#
# Measured by OUTCOME, never by log scraping:
#
#   A: baseline — a 2-pane window, both panes agent-backed and RESPONSIVE
#      (a marker typed in and read back), with the app pid and shell pids
#      recorded.
#   B: kill ONLY the agent. The app process must still be the SAME pid and must
#      still answer IPC — that is what makes this "in place" rather than a
#      relaunch. This section also proves the trap is ARMED: with the agent
#      gone, the panes are genuinely broken before recovery is asserted.
#   C: recovery — within the settle window + re-dial, the window is back to 2
#      panes and BOTH ARE RESPONSIVE AGAIN (a fresh marker round-trips). The
#      shell pids are UNCHANGED: since T909 every session is holder-backed by
#      default, so the children outlive the agent and the replacement ADOPTS
#      them (T906) instead of relaunching. Until then the same assertion read
#      the other way round — new pids, because the shells died with the agent —
#      and the flip is the whole user-visible point of T705. What separates a
#      real rebuild from a pane that merely still exists is the surfaces the
#      rebuild closed (E7), never the pids.
#   D: the e65cfa4d5 lesson — recovery must not KILL the sessions it recovers.
#      The alive-session count is 2 after recovery AND still 2 after the
#      departing surfaces have had time to finish tearing down (their DETACH
#      must never have been a CLOSE).
#   E: topology is preserved, not flattened: still one window, one tab, a split
#      of exactly two leaves, and the pane's registered IPC name still resolves.
#   G: T195 - the other half of the policy, and the one that keeps recovery from
#      being destructive: a link BLIP must be a no-op. The agent is SUSPENDED
#      until the app says it has started its settle watch, then RESUMED well
#      inside the 5s window, and nothing may move - same terminal surfaces, same
#      children, same sessions, same responsive pane.
#   H: the negative control for G - the identical blip HELD past the window, which
#      must rebuild. One variable between the two sections: how long the link
#      stayed down.
#   I: T723 - the blip held past the RE-DIAL, so recovery ABORTS (a wedged agent
#      holds the single-instance guard and never completes a handshake), and then
#      the wedged agent is KILLED. Nothing but a retry can save those panes: the
#      settle watch never re-opens, because a link already in `reconnecting`
#      produces no further DOWN edge. They must come back with no app relaunch.
#   J: the same abort, ended by a RESUME instead of a kill - the softer half,
#      where a healed link is also an acceptable cure. The panes must be
#      responsive either way.
#   K: T764 - the OTHER pane, the one opened while the agent is wedged. It must
#      fall back to a plain exec pane and WORK, instead of inheriting the stuck
#      shared connection and opening frozen, and the window must still open
#      promptly rather than blocking on a handshake that never completes.
#
# The oracle for "did a rebuild run" is the number of terminal SURFACES the app
# closed inside the rebuild (its `surface closed` lines between `in-place
# recovery: re-dialed` and `in-place recovery: rebuilt`), not the child pids and
# - since T2876 - not the HWND set either: T2597's pane-window pool hands a
# departing pane's window to the next pane, so window identity no longer says
# whether a surface is fresh. Two closes is positive proof a rebuild ran; none in
# G's blip window is positive proof none did. Sections E7, H6 and I6 take that
# same measurement where a rebuild IS expected, which is what makes G's "nothing
# changed" a claim rather than a tautology.
#
# Fully hermetic: a per-run $env:LOCALAPPDATA and GHOSTTY_LOCAL_AGENT_BIN, and
# it ONLY ever kills ghoztty / ghoztty-agent processes launched from the repo
# zig-out with THIS run's state dir — never the user's real release instance.
#
#   powershell -NoProfile -File test\win32\agent-recovery.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe'
)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:passes = 0
$root = Join-Path $env:TEMP "ghoztty-agent-recovery-$PID"

function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ }
    else { "  FAIL $name"; $script:failures++ }
}

# Kill ONLY zig-out ghoztty/agent processes (never the user's release build).
function Stop-TestProcs {
    # T351: one shared, path-exact kill (lib\CleanSlate.ps1) instead of a private
    # copy - the filter this replaced also matched a detached instance running from
    # zig-out-release (T53b), and every copy answered "does the agent go too" alone.
    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 700)
}

# The agent processes belonging to THIS run (their command line names this
# run's state dir). Never the user's, never another test's.
function Get-RunAgents($tmp) {
    # Unary comma: PowerShell unwraps a 1-element array on return, and every
    # caller here does arithmetic on .Count.
    return , @(Get-CimInstance Win32_Process -Filter "Name='ghoztty-agent.exe'" |
        Where-Object { $_.CommandLine -like "*$tmp*" })
}
function Show-Agents($tmp, $tag) {
    "    [$tag] agents for this run:"
    foreach ($a in (Get-RunAgents $tmp)) { "      pid=$($a.ProcessId) $($a.CommandLine)" }
}

# T1238: every CLI call runs ON THE TEST DESKTOP, and the harness captures the
# child's stdout AND stderr to $out itself - which is what the old `cmd /c
# "... > file 2>&1"` wrapper was for (a GUI-subsystem exe writes nothing to a
# PowerShell redirect, T245).
function Run-Cli($argsLine, $out, $timeoutSec = 15) {
    $argv = @($argsLine -split '\s+' | Where-Object { $_ -ne '' })
    $r = Invoke-OnTestDesktop -Exe $Exe -Arguments $argv -TimeoutSec $timeoutSec
    $text = if ($null -ne $r.Output) { $r.Output } else { '' }
    [System.IO.File]::WriteAllText($out, $text)
    if ($r.TimedOut) { return $null }
    return $r.ExitCode
}

# Same, but the arguments are passed as a real ARRAY. The distinction outlived
# the `cmd /c` wrapper it was written against: an argument containing a space
# (`+send-keys ... "echo MARKER"`) must arrive as ONE argument, which is how the
# first run of this script reported a healthy pane as unresponsive.
function Run-CliArgs($argv, $out, $timeoutSec = 15) {
    # persistence: on (default) - the agent under test only owns sessions when persistence is on.
    $r = Invoke-OnTestDesktop -Exe $Exe -Arguments $argv -TimeoutSec $timeoutSec
    $text = if ($null -ne $r.Output) { $r.Output } else { '' }
    [System.IO.File]::WriteAllText($out, $text)
    if ($r.TimedOut) { return $null }
    return $r.ExitCode
}
function Out-Text($f) { if (Test-Path $f) { Get-Content $f -Raw } else { '' } }

function Get-List($tmp, $tag, $timeoutSec = 12) {
    $code = Run-Cli '+list --json' "$tmp\list-$tag.json" $timeoutSec
    if ($code -ne 0) { return $null }
    try { return (Out-Text "$tmp\list-$tag.json" | ConvertFrom-Json) } catch { return $null }
}
function Windows-Of($tree) {
    if ($null -eq $tree) { return , @() }
    if ($null -ne $tree.data) { return , @($tree.data.windows) }
    return , @($tree.windows)
}
function Leaves-Of($node) {
    if ($null -eq $node) { return @() }
    if ($node.type -eq 'leaf') { return @($node.terminal) }
    if ($node.type -eq 'split') { return @(Leaves-Of $node.left) + @(Leaves-Of $node.right) }
    return @()
}
# Every terminal leaf across every window/tab, in tree order.
function All-Leaves($tree) {
    $acc = @()
    foreach ($w in Windows-Of $tree) {
        foreach ($t in @($w.tabs)) { $acc += Leaves-Of $t.splits }
    }
    return , $acc
}
function Leaf-Count($tree) { return (All-Leaves $tree).Count }
# Terminal-only / viewer-only views of that list. A viewer leaf reports
# `"type": "viewer"` and none of the shell fields (no pid, no tty, no pwd).
#
# The `$all = ...` step is load-bearing: `All-Leaves` returns its list wrapped
# in a unary-comma array, and piping that function call DIRECTLY into
# Where-Object unrolls only the wrapper — so `$_` is the whole leaf array and
# `$_.type` member-enumerates into an array that is always truthy. Both filters
# then "matched", and every assertion below them passed vacuously. Assigning
# first unrolls the wrapper to the real list, which is what enumerates.
function Terminal-Leaves($tree) {
    $all = All-Leaves $tree
    return , @($all | Where-Object { $_.type -ne 'viewer' })
}
function Viewer-Leaves($tree) {
    $all = All-Leaves $tree
    return , @($all | Where-Object { $_.type -eq 'viewer' })
}

function Get-Sessions($tmp, $tag) {
    $code = Run-Cli '+sessions --json' "$tmp\sess-$tag.json" 12
    if ($code -ne 0) { return @() }
    try { $rows = Out-Text "$tmp\sess-$tag.json" | ConvertFrom-Json } catch { return @() }
    if ($null -eq $rows) { return @() }
    return @($rows)
}
function Alive-Rows($rows) { return @($rows | Where-Object { $_.alive -eq $true }) }
function Alive-Pids($rows) {
    return , @(Alive-Rows $rows | ForEach-Object { [int]$_.pid } | Sort-Object)
}
function Wait-AliveCount($tmp, $tag, $target, $timeoutSec = 20) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $rows = @()
    while ((Get-Date) -lt $deadline) {
        $rows = Get-Sessions $tmp $tag
        if ((Alive-Rows $rows).Count -eq $target) { return , $rows }
        Start-Sleep -Milliseconds 500
    }
    return , $rows
}

# THE liveness oracle for a pane: type a unique marker and read it back. A pane
# whose PTY is gone still EXISTS in +list — only a round-trip proves it works.
function Test-PaneResponsive($tmp, $target, $tag, $timeoutSec = 20) {
    $marker = "T145x$($tag)x$(Get-Random -Maximum 999999)"
    # The command is assembled from SPACE-FREE positional arguments plus the
    # `Space` key name. `+send-keys` concatenates its positionals, so this types
    # exactly `echo <marker>` — and nothing in the chain (PowerShell, the exe's
    # argv, cmd) ever sees a quoted argument to re-quote. A quoted `"echo M"`
    # reaches cmd WITH its quotes and dies as "not recognized as an internal or
    # external command", which is how the first run of this script scored a
    # working pane as broken.
    Run-CliArgs @('+send-keys', "--target=$target", 'echo', 'Space', $marker, 'Enter') `
        "$tmp\keys-$tag.txt" 12 | Out-Null
    # Deliberately NOT gated on send-keys' exit code: the marker coming back is
    # the oracle, and a stricter gate only adds a way for the harness to score
    # a working pane as broken.
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        # A wide line budget, because the wrap above means one MARKER costs one
        # line per character. At --lines=25 the marker fell off the top of the
        # window and the oracle reported a working pane as dead.
        $rc = Run-Cli "+read --name=$target --lines=300" "$tmp\read-$tag.txt" 12
        if ($rc -eq 0) {
            # The window is minimized, so a split pane can be a couple of
            # columns wide and the terminal WRAPS the echoed marker across
            # lines — it is really there, one character per row. Collapsing all
            # whitespace is what makes the oracle measure "did the shell run
            # it?" instead of "how wide is the pane?" (the marker is
            # deliberately space-free so this cannot create a false positive).
            $txt = (Out-Text "$tmp\read-$tag.txt") -replace "`0", '' -replace '\s', ''
            if ($txt -match [regex]::Escape($marker)) { return $true }
        }
        Start-Sleep -Milliseconds 600
    }
    return $false
}

# --- T195: suspend/resume a process, and enumerate the app's pane surfaces ---
#
# SUSPENDING is how a link BLIP is induced with no new test hook and no
# debugger: a frozen agent answers no heartbeats, so the app's transport FSM
# walks to `reconnecting` exactly as it does for a real drop
# (`remote/connection.zig` §5.1, 3 missed heartbeats at 3s), and a resume puts it
# back on the very next authentic packet.
#
# ENUMERATING is the outcome oracle. In-place recovery keeps the window HWND and
# replaces the surfaces inside it (`rebuildTabLeavesInPlace` ->
# `replaceTabLeaf`), so the tab's `GhozttyTerminal` child windows are a fresh set
# after a rebuild and the same set after a no-op.
#
# Child PIDS deliberately are NOT the oracle here, and that is a correction to
# the plan T195 was filed with. They cannot answer a SUSPEND: a frozen agent
# never loses a child, so a rebuild after a blip would re-ATTACH the very same
# pids and read as "nothing happened". Since T909 they cannot answer a KILL
# either - holder-backed sessions survive it and are adopted, so the pids are
# unchanged there too. The surface set separates the two cases under either
# stimulus, which is why it is the oracle and the pids are only evidence about
# the SHELLS.
if (-not ('GhozttyRecoveryNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class GhozttyRecoveryNative {
    [DllImport("ntdll.dll")] static extern int NtSuspendProcess(IntPtr h);
    [DllImport("ntdll.dll")] static extern int NtResumeProcess(IntPtr h);
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(int access, bool inherit, int pid);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool CloseHandle(IntPtr h);

    const int PROCESS_SUSPEND_RESUME = 0x0800;

    // 0 on success. -1 means the process could not be opened at all (gone, or
    // no PROCESS_SUSPEND_RESUME right), which is a different failure from a
    // suspend that was refused.
    public static int SetSuspended(int pid, bool suspended) {
        IntPtr h = OpenProcess(PROCESS_SUSPEND_RESUME, false, pid);
        if (h == IntPtr.Zero) return -1;
        int rc = suspended ? NtSuspendProcess(h) : NtResumeProcess(h);
        CloseHandle(h);
        return rc;
    }

}
'@
}

function Set-AgentSuspended($procId, [bool]$suspended) {
    return [GhozttyRecoveryNative]::SetSuspended([int]$procId, $suspended)
}

# Death is not instant, and it is least instant for a SUSPENDED target: the
# terminate is accepted immediately but the threads only unwind once they run
# again, so a process object (and a `Get-Process` hit) legitimately outlives the
# kill by a moment. Sampling once right after `Stop-Process` scored a killed
# agent as still running while every assertion after it - the rebuild, the fresh
# agent, the responsive pane - proved it was gone.
function Wait-ProcGone($procId, $timeoutSec = 20) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
        if ($null -eq $p -or $p.HasExited) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return $false
}
# Unary comma: every caller does arithmetic on .Count, and PowerShell unwraps a
# one-element array return into a scalar whose .Count is $null.
# T1238: enumerated on the TEST DESKTOP. The private EnumWindows below (still
# used for suspend/resume, which is desktop-agnostic) runs on the HOST's desktop
# and would return an EMPTY set once the app launches onto the test desktop -
# and an empty set compares equal to another empty set, so every "the surfaces
# were replaced" assertion would have passed without measuring anything.
#
# VISIBLE windows only (T2876). Since T2597 (`pane_pool.zig`) a departing pane's
# window is parked HIDDEN in its top-level and handed to the next pane built
# there, so after the first rebuild the hidden spares are still enumerable and a
# raw count read 4 where the tab holds 2 terminals. The parked spares are not
# panes; the visible set is.
function Get-TerminalSurfaces($procId) {
    $acc = @()
    foreach ($top in @(Get-TestWindows -ProcessId ([int]$procId) -Class '*' -AllowHidden)) {
        if ($top.Class -eq 'GhozttyTerminal' -and $top.Visible) { $acc += [int64]$top.Hwnd }
        foreach ($c in @(Get-TestChildWindows -Window ([IntPtr]$top.Hwnd) -Class 'GhozttyTerminal')) {
            if ($c.Visible) { $acc += [int64]$c.Hwnd }
        }
    }
    return , @($acc | Sort-Object)
}

# The visible surface count once a rebuild has settled. A sample taken the
# instant the rebuild finishes can still see the departing windows on their way
# out, so this polls for the count rather than reading it once.
function Wait-SurfaceCount($procId, $want, $timeoutSec = 25) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $now = Get-TerminalSurfaces $procId
    while ((Get-Date) -lt $deadline) {
        $now = Get-TerminalSurfaces $procId
        if ($now.Count -eq $want) { return , $now }
        Start-Sleep -Milliseconds 500
    }
    return , $now
}

# THE rebuild oracle (T2876, the same one T2865 gave agent-recovery-tabs.ps1).
# It used to be "the HWND set after is disjoint from the set before", which held
# only while a departing surface destroyed its window. Since T2597 the pool
# reuses that window for the next pane, so a CORRECT rebuild can land its fresh
# surfaces in the very HWNDs it just vacated and read as "nothing was rebuilt".
#
# Each departing surface logs `surface closed` from `Surface.deinit`, and the
# rebuild frees the old tree synchronously between `reconnectForRecovery`'s
# `in-place recovery: re-dialed` line and `in-place recovery: rebuilt`. So the
# count of `surface closed` lines inside that window is the number of terminal
# surfaces the rebuild replaced - 2 here (the viewer is no Surface, and section F
# shows it is spared). An ABORTED attempt never logs `re-dialed` (the line is
# written only once a dial succeeds), so the first window after the mark is the
# attempt that actually rebuilt.
#
# Returns -1 while there is no complete re-dialed..rebuilt window after $from.
function Get-RebuildCloses($from) {
    $t = Read-AppLog $from
    $iDial = $t.IndexOf('in-place recovery: re-dialed')
    if ($iDial -lt 0) { return -1 }
    $iDone = $t.IndexOf('in-place recovery: rebuilt', $iDial)
    if ($iDone -lt 0) { return -1 }
    return ([regex]::Matches($t.Substring($iDial, $iDone - $iDial), 'surface closed')).Count
}
function Wait-RebuildCloses($from, $timeoutSec = 45) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $n = Get-RebuildCloses $from
        if ($n -ge 0) { return $n }
        Start-Sleep -Milliseconds 250
    }
    return (Get-RebuildCloses $from)
}
# Printed beside a failed rebuild assertion: every surface the app owns (hidden
# pool spares included), and the log lines the oracle reads.
function Show-RebuildEvidence($procId, $from, $tag) {
    foreach ($top in @(Get-TestWindows -ProcessId ([int]$procId) -Class '*' -AllowHidden)) {
        foreach ($c in @(Get-TestChildWindows -Window ([IntPtr]$top.Hwnd) -Class 'GhozttyTerminal')) {
            "    [$tag] hwnd=$($c.Hwnd) visible=$($c.Visible)"
        }
    }
    foreach ($ln in ((Read-AppLog $from) -split "`r?`n")) {
        if ($ln -match 'recovery|surface closed') { "    [$tag] log: $ln" }
    }
}

# The app's stderr. A Debug build links the CONSOLE subsystem, so std.log lands
# there line by line (each line is flushed), which is what makes "has the settle
# watch started yet?" answerable without a fixed sleep. It is a TIMING signal,
# never an oracle - every assertion below is an outcome.
function Get-AppLogText {
    if (-not $appLog) { return '' }
    if (-not (Test-Path $appLog)) { return '' }
    $t = $null
    try { $t = Get-Content $appLog -Raw -ErrorAction Stop } catch { return '' }
    if ($null -eq $t) { return '' }
    return $t
}
function Get-AppLogLength { return (Get-AppLogText).Length }
function Read-AppLog($from) {
    $t = Get-AppLogText
    if ($from -ge $t.Length) { return '' }
    return $t.Substring($from)
}
# Only ever printed next to a FAILED wait on a log line. The waits are timing
# signals, so when one times out the useful question is "what did the app say
# instead", and the run dir is deleted on the way out - there is no log to go
# back to afterwards.
function Dump-AppLog($from, $tag) {
    "    [$tag] app log since the mark:"
    $t = Read-AppLog $from
    if (-not $t) { "      <empty>"; return }
    # Renderer/OpenGL chatter drowns everything at debug level, so this keeps
    # the lines that speak about the connection under test.
    ($t -split "`r?`n" |
        Where-Object { $_ -match 'agent|recovery|link|remote|persist' } |
        Select-Object -Last 30) | ForEach-Object { "      $_" }
}

Stop-TestProcs
New-Item -ItemType Directory -Force $root | Out-Null
$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN

Assert "agent binary exists in zig-out" (Test-Path $AgentExe)
Assert "ghoztty exe exists in zig-out" (Test-Path $Exe)

$tmp = Join-Path $root 'run'
New-Item -ItemType Directory -Force (Get-GhozttyAgentStateDir -Root $tmp) | Out-Null
$env:LOCALAPPDATA = $tmp
$env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe


# T441: a private IPC endpoint, and it is NOT covered by the LOCALAPPDATA
# redirect above. The endpoint a CLI dials comes from the pane's baked
# `$GHOZTTY_IPC_SOCKET` unless a suffix outranks it, so without this every
# Run-Cli below would answer from the user's installed release.
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 'agentrec')
Assert-GhozttyPrivateEndpoint -Exe $Exe

# T1238: the GUI and every CLI call below start on a background test desktop,
# so this script no longer throws a window across whatever the user is reading.
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
$td = New-TestDesktop

# ============================================================================
"== A: baseline - a 2-pane agent-backed window, both panes responsive"
# ============================================================================
# persistence: on (default) - the agent under test only owns sessions when persistence is on.
# stderr goes to a file so section G can tell WHEN the app entered its settle
# watch (a Debug build logs to stderr; see Get-AppLogText). Redirecting to a
# FILE, never a pipe: nothing here drains a pipe, and a full one would block the
# app's logger.
$appLog = Join-Path $tmp 'app.err'
[void](Start-OnTestDesktop -Exe $Exe -Arguments @('--title=t145-recovery') -StdErr $appLog)

$appProc = $null
$deadline = (Get-Date).AddSeconds(30)
while ((Get-Date) -lt $deadline) {
    $tree = Get-List $tmp 'a0' 10
    if ((Leaf-Count $tree) -ge 1) {
        $appProc = @(Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
            Where-Object { $_.CommandLine -like '*t145-recovery*' })[0]
        break
    }
    Start-Sleep -Milliseconds 500
}
Assert "A1 the GUI came up and answers +list" ($null -ne $appProc)
if ($null -eq $appProc) {
    "AGENT-RECOVERY: $script:failures FAILURE(S)"
    $env:LOCALAPPDATA = $savedLocalAppData
    exit 1
}
$appPid = [int]$appProc.ProcessId
Assert-GhozttyIsolated -Exe $Exe

# Name the first pane, then split it so the topology under test is a real tree.
$firstLeaf = (All-Leaves (Get-List $tmp 'a1' 10))[0]
Run-Cli "+split --pane=$($firstLeaf.id) --name=t145b --direction=right" "$tmp\split.txt" 15 | Out-Null

$treeA = $null
$deadline = (Get-Date).AddSeconds(20)
while ((Get-Date) -lt $deadline) {
    $treeA = Get-List $tmp 'a2' 10
    if ((Leaf-Count $treeA) -eq 2) { break }
    Start-Sleep -Milliseconds 500
}
Assert "A2 the window has exactly 2 panes" ((Leaf-Count $treeA) -eq 2)

# T399: put a VIEWER pane in the same tab. It rides no agent session, so the
# agent going down cannot have invalidated it — section F measures that recovery
# leaves it strictly alone.
$viewFile = Join-Path $tmp 'view.md'
Set-Content -Path $viewFile -Value "# t399`n`nviewer pane content." -Encoding utf8
Run-CliArgs @('+split', "--pane=$($firstLeaf.id)", '--direction=down',
    '--name=t399v', "--view=$viewFile") "$tmp\viewsplit.txt" 20 | Out-Null

$deadline = (Get-Date).AddSeconds(20)
while ((Get-Date) -lt $deadline) {
    $treeA = Get-List $tmp 'a2v' 10
    if ((Viewer-Leaves $treeA).Count -eq 1) { break }
    Start-Sleep -Milliseconds 500
}
$viewerA = (Viewer-Leaves $treeA)[0]
Assert "A2b a viewer pane joined the tab" ($null -ne $viewerA)
Assert "A2c the tab now holds 2 terminals and 1 viewer" (
    (Terminal-Leaves $treeA).Count -eq 2 -and (Viewer-Leaves $treeA).Count -eq 1)

$paneA = (Terminal-Leaves $treeA)[0]
$rowsA = Wait-AliveCount $tmp 'a' 2 25
Assert "A3 both panes are agent-backed (2 live sessions)" ((Alive-Rows $rowsA).Count -eq 2)
$pidsA = Alive-Pids $rowsA
Assert "A4 both live sessions report a real child pid" (@($pidsA | Where-Object { $_ -gt 0 }).Count -eq 2)

Assert "A5 the named pane is responsive before the crash" (Test-PaneResponsive $tmp 't145b' 'a' 25)

# The pane surfaces as they are BEFORE anything drops. Section E7 compares
# against this across the kill (they must all be new); section G compares its own
# baseline across a blip (they must all be the same).
$surfA = Get-TerminalSurfaces $appPid
if ($surfA.Count -ne 2) { "    [A6] terminal surfaces: $($surfA -join ',')" }
Assert "A6 the two terminal panes have two terminal surfaces" ($surfA.Count -eq 2)

# ============================================================================
"== B: kill ONLY the agent - the app survives with the SAME pid"
# ============================================================================
$agents = Get-RunAgents $tmp
if ($agents.Count -ne 1) { Show-Agents $tmp 'B' }
Assert "B1 exactly one agent belongs to this run" ($agents.Count -eq 1)
$agentPid = if ($agents.Count -ge 1) { [int]$agents[0].ProcessId } else { 0 }
# E7 reads the rebuild out of log text written from here on (T2876).
$logMarkB = Get-AppLogLength
foreach ($a in $agents) { Stop-Process -Id $a.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 800

Assert "B2 the agent process is gone" (
    $null -eq (Get-Process -Id $agentPid -ErrorAction SilentlyContinue))

$stillHere = Get-Process -Id $appPid -ErrorAction SilentlyContinue
Assert "B3 the APP is still alive with the same pid (in place, not a relaunch)" ($null -ne $stillHere)

# The trap must be ARMED: with the agent dead the panes' link is genuinely
# broken. If it were not, the section-C assertions would be vacuous.
#
# Measured from the app's own drop notice, no longer by typing into the pane
# (T1473): a dead agent now skips the 5s settle window, so recovery has
# usually finished inside the 4s a "pane does not answer" probe needed, and
# the probe read a recovered pane as an unarmed trap. The notice is the app
# saying the link went down; E7 (two surfaces closed by the rebuild) is the
# independent proof the panes were replaced rather than left alone.
$downB = $false
$deadline = (Get-Date).AddSeconds(15)
while ((Get-Date) -lt $deadline) {
    if ((Read-AppLog $logMarkB) -match 'shared local-agent link went down') { $downB = $true; break }
    Start-Sleep -Milliseconds 200
}
Assert "B4 the panes' link is BROKEN by the kill (trap armed)" $downB

# T1473: a dead process cannot heal its link, so the app must not sit out the
# settle window before recovering.
$waivedB = $false
$deadline = (Get-Date).AddSeconds(10)
while ((Get-Date) -lt $deadline) {
    if ((Read-AppLog $logMarkB) -match 'has exited; skipping the remaining') { $waivedB = $true; break }
    Start-Sleep -Milliseconds 200
}
if (-not $waivedB) { Dump-AppLog $logMarkB 'B5' }
Assert "B5 the app skipped the settle window for an agent that has EXITED" $waivedB

# ============================================================================
"== C: recovery - the panes come back on the SAME children, with no relaunch"
# ============================================================================
# Settle window (5s) + re-dial/spawn (<=2s) + agent restore + RELAUNCH.
$rowsC = Wait-AliveCount $tmp 'c' 2 45
Assert "C1 two sessions are alive again on the respawned agent" (
    (Alive-Rows $rowsC).Count -eq 2)

$newAgents = Get-RunAgents $tmp
Assert "C2 a fresh agent is running for this run" ($newAgents.Count -ge 1)
Assert "C3 it is NOT the process that was killed" (
    @($newAgents | Where-Object { [int]$_.ProcessId -eq $agentPid }).Count -eq 0)

$stillHere = Get-Process -Id $appPid -ErrorAction SilentlyContinue
Assert "C4 the app pid never changed across recovery" ($null -ne $stillHere)

# Since T909 holder-backed spawning is the DEFAULT, so the agent's death no
# longer reaches the shells: the replacement adopts the surviving holders
# (T906) and the user's running commands, cwd and scrollback come back with
# them. This assertion used to demand the opposite - two brand-new pids,
# because the children died with the agent - and flipping it is the whole
# user-visible payoff of T705. `+list`'s pid is the SHELL's on both paths
# (holder or not), so the two sides are comparable.
$pidsC = Alive-Pids $rowsC
$newPids = @($pidsC | Where-Object { $pidsA -notcontains $_ })
if ($newPids.Count -ne 0) { "    [C5] before=$($pidsA -join ',') after=$($pidsC -join ',')" }
Assert "C5 the shells SURVIVED the agent and were adopted (same pids, nothing relaunched)" (
    $newPids.Count -eq 0 -and (Alive-Rows $rowsC).Count -eq 2)

Assert "C6 the named pane is RESPONSIVE again - the actual defect" (
    Test-PaneResponsive $tmp 't145b' 'c' 30)

# ============================================================================
"== D: recovery must not kill the sessions it recovers (e65cfa4d5)"
# ============================================================================
# The departing surfaces tear down asynchronously. If any of them had been
# marked close-intent, its CLOSE would land AFTER the new panes attached and
# terminate a session a live pane is using. Waiting here is the point.
Start-Sleep -Seconds 6
$rowsD = Get-Sessions $tmp 'd'
Assert "D1 still exactly 2 live sessions after the old surfaces finished" (
    (Alive-Rows $rowsD).Count -eq 2)
Assert "D2 the pane still works after the teardown window" (
    Test-PaneResponsive $tmp 't145b' 'd' 20)

# ============================================================================
"== E: the topology was rebuilt, not flattened"
# ============================================================================
$treeE = Get-List $tmp 'e' 12
Assert "E1 still exactly one window" ((Windows-Of $treeE).Count -eq 1)
Assert "E2 still exactly 2 terminals in a split" ((Terminal-Leaves $treeE).Count -eq 2)
$tabsE = @((Windows-Of $treeE)[0].tabs)
Assert "E3 still exactly one tab" ($tabsE.Count -eq 1)
Assert "E4 the tab's root is a split, not a lone leaf" ($tabsE[0].splits.type -eq 'split')
# The IPC name survived: it is re-registered onto the rebuilt pane, so a target
# that worked before the crash still resolves after it.
$rcE = Run-Cli "+read --name=t145b --lines=1" "$tmp\read-e.txt" 12
Assert "E5 the pane's IPC name still resolves after the rebuild" ($rcE -eq 0)
# The stable pane id (T113) is PRESERVED across the rebuild, exactly as it is
# across a launch restore: the id is baked into the shell as $GHOZTTY_PANE_ID,
# so a recovery that minted a fresh one would leave every pane unable to name
# itself. (The first version of this script asserted the opposite — that a
# rebuilt pane is a "new" surface — which would have passed only on a build
# that broke the guarantee.)
$paneE = (Terminal-Leaves $treeE)[0]
Assert "E6 the rebuilt pane kept its stable pane id" ($paneE.id -eq $paneA.id)

# The CONTROL for section G, taken with G's own instrument: the rebuild closed
# both terminal surfaces (Get-RebuildCloses, T2876), which is what makes G's
# "no surface closed" a measurement of no-rebuild rather than of a blunt
# instrument.
$closedE = Wait-RebuildCloses $logMarkB 30
if ($closedE -ne 2) { Show-RebuildEvidence $appPid $logMarkB 'E7' }
Assert "E7 recovery REPLACED both terminal surfaces (closed inside the rebuild: $closedE, want 2; the control for G)" (
    $closedE -eq 2)
$surfE = Wait-SurfaceCount $appPid 2
Assert "E8 the rebuilt tab shows exactly 2 terminal surfaces (count=$($surfE.Count))" ($surfE.Count -eq 2)

# ============================================================================
"== F: T399 - the viewer pane was never touched by the recovery"
# ============================================================================
# A viewer holds no agent session, so a dropped agent link cannot have
# invalidated it. Recovery used to replace the tab's WHOLE tree, which destroyed
# the WebView2 host and re-opened the page — losing scroll position and in-page
# state for an event that had nothing to do with the pane.
#
# The pane id is the cheap observable, and it is a real one BECAUSE a re-created
# viewer draws a fresh random id (`ViewerPane.create`). Sections C and E already
# established that recovery genuinely ran and rebuilt the terminals on new
# children, so an untouched viewer here is a spared pane, not a skipped test.
$viewerE = (Viewer-Leaves $treeE)
Assert "F1 the viewer pane is still in the tab" ($viewerE.Count -eq 1)
Assert "F2 it kept its stable pane id - it was never re-created" (
    $viewerE.Count -eq 1 -and $viewerE[0].id -eq $viewerA.id)
Assert "F3 it still shows the file it was opened with" (
    $viewerE.Count -eq 1 -and $viewerE[0].url -like '*view.md')
# And it is a live viewer, not a husk: `+reload` is viewer-only (it rejects a
# terminal pane outright), so a clean exit means the pane is still a working
# viewer answering to the name it was registered under before the crash.
$rcF = Run-Cli "+reload --target=t399v" "$tmp\reload-f.txt" 12
Assert "F4 the viewer still answers +reload by its registered name" ($rcF -eq 0)

# ============================================================================
"== G: T195 - a link BLIP inside the settle window must change nothing"
# ============================================================================
# The destructive half of recovery is what sections B-E measure. THIS is the half
# that keeps it from being destructive: `agent_recovery.settle_ms` (5s) exists
# because Mac shipped in-place recovery without it and the 2026-07-21 incident
# (`e65cfa4d5`) had it fire on a link that healed 27ms later, destroying the
# sessions it had just re-attached. The policy is unit-tested in
# `agent_recovery.zig`; what is measured here is the WIRING - that a heal inside
# the window really does reach `link_recovered` and really does leave the panes
# alone.
$settleMs = 5000    # agent_recovery.settle_ms

$agentsG = Get-RunAgents $tmp
if ($agentsG.Count -ne 1) { Show-Agents $tmp 'G' }
Assert "G1 exactly one agent belongs to this run before the blip" ($agentsG.Count -eq 1)
$agentPidG = if ($agentsG.Count -ge 1) { [int]$agentsG[0].ProcessId } else { 0 }

$rowsG0 = Wait-AliveCount $tmp 'g0' 2 25
$pidsG0 = Alive-Pids $rowsG0
$surfG0 = Get-TerminalSurfaces $appPid
Assert "G2 two live sessions and two terminal surfaces before the blip" (
    (Alive-Rows $rowsG0).Count -eq 2 -and $surfG0.Count -eq 2)

# Everything after this point is judged against log text written from here on,
# so a line from the section-C recovery cannot be mistaken for a fresh one.
$logMark = Get-AppLogLength
Assert "G3 the agent was suspended" (
    $agentPidG -gt 0 -and (Set-AgentSuspended $agentPidG $true) -eq 0)

# Wait for the app's OBSERVABLE state, never a fixed sleep: reaching
# `reconnecting` takes 3 missed heartbeats 3s apart, and a fixed wait would race
# the very window under test. The log line is the timing signal - it is emitted
# as the settle window opens, so the resume below is timed from the window's own
# start rather than from the suspend.
$watchSeen = $false
$deadline = (Get-Date).AddSeconds(45)
while ((Get-Date) -lt $deadline) {
    if ((Read-AppLog $logMark) -match 'before deciding on in-place recovery') {
        $watchSeen = $true
        break
    }
    Start-Sleep -Milliseconds 100
}
$watchAt = Get-Date
# Resume unconditionally, including on the timeout path: a suspended agent left
# behind would poison every section after this one and outlive the script.
$resumeRc = Set-AgentSuspended $agentPidG $false
$blipMs = [int]((Get-Date) - $watchAt).TotalMilliseconds

Assert "G4 the app noticed the drop and opened its settle watch" $watchSeen
Assert "G5 the agent was resumed" ($resumeRc -eq 0)
if ($blipMs -ge 2000) { "    [G6] resume landed +${blipMs}ms into a ${settleMs}ms window" }
# The heal itself costs one PING/PONG round-trip after the resume, so the resume
# must land with room to spare inside the window rather than merely inside it.
Assert "G6 the resume landed early in the ${settleMs}ms settle window" ($blipMs -lt 2000)

# Past the window plus several poll ticks (`agent_recovery.poll_ms` = 250): if a
# verdict were going to trigger recovery, it has by now.
Start-Sleep -Seconds 8

$tailG = Read-AppLog $logMark
Assert "G7 the link healed on its own - the app says no recovery was needed" (
    $tailG -match 'link recovered on its own')
Assert "G8 no in-place recovery was triggered by the blip" (
    $tailG -notmatch 'recovering local windows in place')

# The outcome: a rebuild closes every terminal surface (E7 reads 2), so a blip
# window in which NO surface closed rebuilt nothing. This used to compare HWND
# sets, which T2597's pane-window pool made blind - a rebuild can now hand its
# fresh surfaces the very windows it vacated (T2876).
$closedG = ([regex]::Matches((Read-AppLog $logMark), 'surface closed')).Count
if ($closedG -ne 0) { Show-RebuildEvidence $appPid $logMark 'G9' }
Assert "G9 every terminal SURFACE survived the blip - nothing was rebuilt (surfaces closed: $closedG)" (
    $closedG -eq 0)
$surfG1 = Get-TerminalSurfaces $appPid
Assert "G9b the tab still shows 2 terminal surfaces (count=$($surfG1.Count))" ($surfG1.Count -eq 2)

$rowsG1 = Wait-AliveCount $tmp 'g1' 2 25
$pidsG1 = Alive-Pids $rowsG1
Assert "G10 still exactly 2 live sessions after the blip" ((Alive-Rows $rowsG1).Count -eq 2)
if ("$($pidsG1 -join ',')" -ne "$($pidsG0 -join ',')") {
    "    [G11] before=$($pidsG0 -join ',') after=$($pidsG1 -join ',')"
}
Assert "G11 the shells are the SAME children" (
    "$($pidsG1 -join ',')" -eq "$($pidsG0 -join ',')")
Assert "G12 the app pid never changed across the blip" (
    $null -ne (Get-Process -Id $appPid -ErrorAction SilentlyContinue))

# And the pane is a working pane, not a picture of one: a blip that left the
# panes intact but wedged would satisfy every assertion above it.
Assert "G13 the pane is still responsive after the blip" (
    Test-PaneResponsive $tmp 't145b' 'g' 30)

$treeG = Get-List $tmp 'g' 12
$viewerG = (Viewer-Leaves $treeG)
Assert "G14 the viewer pane is untouched by the blip" (
    $viewerG.Count -eq 1 -and $viewerG[0].id -eq $viewerA.id)
Assert "G15 the topology is unchanged: 2 terminals in one window" (
    (Windows-Of $treeG).Count -eq 1 -and (Terminal-Leaves $treeG).Count -eq 2)

# ============================================================================
"== H: the negative control - the SAME blip, held past the window, DOES rebuild"
# ============================================================================
# Section G is only a claim if the same stimulus can produce the other answer.
# So: suspend again, and this time hold it until the app has said it is
# recovering, then resume. Everything is identical to G except the duration,
# which is the one variable the settle window is a function of.
#
# The resume is triggered by the app's own decision rather than by a clock, for
# the same reason G's is: recovery re-dials, and an agent still frozen when that
# dial runs would make this measure a WEDGED agent instead of a late heal.
#
# And note what H does NOT get to assert: the children are the same pids here as
# in G. A suspended agent never loses a child, so a rebuild re-ATTACHes the very
# sessions it had - which is exactly why the surface set, and not the pid set, is
# the oracle for both sections.
$logMarkH = Get-AppLogLength
$surfH0 = Get-TerminalSurfaces $appPid
$pidsH0 = Alive-Pids (Get-Sessions $tmp 'h0')
Assert "H1 two terminal surfaces before the second blip" ($surfH0.Count -eq 2)
Assert "H2 the agent was suspended again" (
    (Set-AgentSuspended $agentPidG $true) -eq 0)

$recoverSeen = $false
$deadline = (Get-Date).AddSeconds(60)
while ((Get-Date) -lt $deadline) {
    if ((Read-AppLog $logMarkH) -match 'recovering local windows in place') {
        $recoverSeen = $true
        break
    }
    Start-Sleep -Milliseconds 100
}
$resumeRcH = Set-AgentSuspended $agentPidG $false
Assert "H3 the agent was resumed" ($resumeRcH -eq 0)
Assert "H4 a drop held past the window DID trigger in-place recovery" $recoverSeen

# Recovery re-dials, re-attaches and rebuilds; give it the same room section C
# gives it.
$rowsH = Wait-AliveCount $tmp 'h' 2 45
Assert "H5 two sessions are alive after the rebuild" ((Alive-Rows $rowsH).Count -eq 2)

$closedH = Wait-RebuildCloses $logMarkH 30
if ($closedH -ne 2) { Show-RebuildEvidence $appPid $logMarkH 'H6' }
Assert "H6 every terminal surface was REPLACED - G's instrument reads both ways (closed: $closedH, want 2)" (
    $closedH -eq 2)
$surfH1 = Wait-SurfaceCount $appPid 2
Assert "H6b the rebuilt tab shows exactly 2 terminal surfaces (count=$($surfH1.Count))" ($surfH1.Count -eq 2)

# The documented negative result, asserted so it cannot quietly stop being true:
# pids are blind to this rebuild.
$pidsH1 = Alive-Pids $rowsH
Assert "H7 the children are UNCHANGED across a real rebuild (pids cannot judge this)" (
    "$($pidsH1 -join ',')" -eq "$($pidsH0 -join ',')")

Assert "H8 the pane is responsive again after the rebuild" (
    Test-PaneResponsive $tmp 't145b' 'h' 30)
$treeH = Get-List $tmp 'h' 12
Assert "H9 the topology survived: one window, 2 terminals, the viewer intact" (
    (Windows-Of $treeH).Count -eq 1 -and (Terminal-Leaves $treeH).Count -eq 2 -and
    (Viewer-Leaves $treeH).Count -eq 1)

# ============================================================================
"== I: T723 - a wedge held past the RE-DIAL aborts recovery, and a retry saves it"
# ============================================================================
# Section H resumes the agent as soon as the app says it is recovering, so the
# re-dial always lands on a running agent. THIS section holds the suspend
# through the re-dial, which is the branch nothing had ever measured: the agent
# is alive (so its single-instance guard blocks a replacement) and its pipe
# accepts a connection the handshake never completes, so `findOrSpawn` spends
# its whole budget and `recoverLocalAgentInPlace` ABORTS.
#
# What made that abort terminal before T723: the settle watch only opens on a
# link DOWN EDGE, and `Connection` fires its observer only on a real state
# CHANGE. The link is already `reconnecting` by then and its only remaining
# transition is to `dead`, which needs a server-sent DETACHED frame - which a
# wedged (or killed) agent never sends. So no second edge ever arrived, nothing
# re-armed the watch, and the panes stayed frozen until the app was relaunched.
#
# This arm is the WORST case, and the one with no other cure at all: after the
# abort the wedged agent is KILLED while still frozen, so there is no healed link
# to fall back on. Its death produces no new down edge either (the link is
# already `reconnecting`, and a dead pipe only re-signals a transport error,
# which is not a state CHANGE), so the retry is the only thing that can bring
# these panes back.
#
# Order matters between this section and J: each arm must start on a
# freshly-healthy agent. A wedge held long enough for the agent's OWN
# single-instance guard to go stale (`single_instance.heartbeat_stale_after_ms`,
# 45s) lets the app's spawned challenger kill and replace the holder, at which
# point recovery succeeds on its first try and the abort under test never
# happens. Both arms reach their verdict ~15s into the wedge, well inside that,
# but only if the agent they suspend has been heartbeating normally - which is
# why the kill arm runs FIRST and hands J a brand-new agent, rather than J
# inheriting one this section has already frozen.
$logMarkI = Get-AppLogLength
$agentsI = Get-RunAgents $tmp
if ($agentsI.Count -ne 1) { Show-Agents $tmp 'I' }
Assert "I1 exactly one agent belongs to this run before the wedge" ($agentsI.Count -eq 1)
$agentPidI = if ($agentsI.Count -ge 1) { [int]$agentsI[0].ProcessId } else { 0 }

# Start the wedge on a FRESHLY WRITTEN heartbeat (T1473). The abort below needs
# recovery's challenger to YIELD, and it yields only while the wedged agent's
# heartbeat is younger than the 45s takeover age. Arriving here straight from
# H, that file is routinely ~20s old already (measured 17-22s), and the path
# to the challenger is ~9s down-detection + 5s settle + a 1.2s handshake + up
# to a 10s PIPE_BUSY wait whenever a background probe dial (the orphan check,
# the session roster) holds the suspended agent's only pipe instance. That sum
# crosses 45s, the challenger replaces the agent, and recovery SUCCEEDS - a red
# I3 that says nothing about T723 and that moves with how long A..H took. A
# beat written within the last ~2s keeps the whole path under the takeover age.
$hbFileI = Get-ChildItem (Join-Path $tmp 'ghoztty') -Filter '*.heartbeat' -ErrorAction SilentlyContinue |
    Select-Object -First 1
$hbFreshI = $false
if ($null -ne $hbFileI) {
    $hbStartI = $hbFileI.LastWriteTimeUtc
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline) {
        $hbNowI = (Get-Item $hbFileI.FullName -ErrorAction SilentlyContinue).LastWriteTimeUtc
        if ($null -ne $hbNowI -and $hbNowI -gt $hbStartI) { $hbFreshI = $true; break }
        Start-Sleep -Milliseconds 100
    }
}
Assert "I1b premise: the agent wrote a fresh heartbeat just before the wedge" $hbFreshI
Assert "I2 the agent was suspended" (
    $agentPidI -gt 0 -and (Set-AgentSuspended $agentPidI $true) -eq 0)

# Wait for the app's own verdict, never a clock: the settle window (5s) plus a
# find-or-spawn budget spent entirely on handshake timeouts is several seconds
# and depends on box load.
$abortSeen = $false
$deadline = (Get-Date).AddSeconds(90)
while ((Get-Date) -lt $deadline) {
    if ((Read-AppLog $logMarkI) -match 'in-place recovery ABORTED') { $abortSeen = $true; break }
    Start-Sleep -Milliseconds 200
}
if (-not $abortSeen) { Dump-AppLog $logMarkI 'I3' }
Assert "I3 a wedge held past the re-dial really does ABORT recovery" $abortSeen

# The fix, at the seam where the old build simply returned: an abort must leave a
# retry armed rather than nothing at all.
$armSeen = $false
$deadline = (Get-Date).AddSeconds(15)
while ((Get-Date) -lt $deadline) {
    if ((Read-AppLog $logMarkI) -match 'in-place recovery: retry 1/') { $armSeen = $true; break }
    Start-Sleep -Milliseconds 200
}
Assert "I4 the abort armed a retry instead of giving up silently" $armSeen

# Kill it while it is still frozen: TerminateProcess does not need the target to
# run, so the app never gets a healthy moment between the abort and the death.
# The children die with the agent (section B's finding), so the retry has to
# spawn a fresh agent and RELAUNCH the sessions - a full rebuild, not a
# re-attach, and nothing but the retry can start it.
if ($agentPidI -gt 0) {
    Stop-Process -Id $agentPidI -Force -ErrorAction SilentlyContinue
    # Let the corpse unwind. A terminated process whose threads are still frozen
    # keeps its process object, and leaving one behind would also leave this
    # run's single-instance guard held against the retry's spawn. The rc is
    # ignored on purpose: it is nonzero once the process is really gone, which is
    # the outcome being asked for.
    [void](Set-AgentSuspended $agentPidI $false)
}
Assert "I5 the wedged agent is gone" (Wait-ProcGone $agentPidI 20)

# The retry schedule is 2s/4s/8s/15s/30s/30s, and a spawn+dial+rebuild is
# seconds more, so this waits generously - but not so long that the schedule
# could have run out, or a pass would say nothing about the retry.
$closedI = Wait-RebuildCloses $logMarkI 90
if ($closedI -ne 2) { Show-RebuildEvidence $appPid $logMarkI 'I6' }
Assert "I6 a retry rebuilt every terminal surface with no app relaunch (closed: $closedI, want 2)" (
    $closedI -eq 2)
Assert "I7 the app pid never changed - this was recovery, not a relaunch" (
    $null -ne (Get-Process -Id $appPid -ErrorAction SilentlyContinue))

$agentsI1 = Get-RunAgents $tmp
if ($agentsI1.Count -ne 1) { Show-Agents $tmp 'I8' }
Assert "I8 a FRESH agent was spawned by the retry" (
    $agentsI1.Count -eq 1 -and [int]$agentsI1[0].ProcessId -ne $agentPidI)

$rowsI = Wait-AliveCount $tmp 'i' 2 60
Assert "I9 two sessions are alive again" ((Alive-Rows $rowsI).Count -eq 2)
Assert "I10 the pane is a WORKING pane, not a picture of one" (
    Test-PaneResponsive $tmp 't145b' 'i' 60)
$treeI = Get-List $tmp 'i' 12
Assert "I11 the topology survived: one window, 2 terminals, the viewer intact" (
    (Windows-Of $treeI).Count -eq 1 -and (Terminal-Leaves $treeI).Count -eq 2 -and
    (Viewer-Leaves $treeI).Count -eq 1)

# And the give-up notice must NOT be showing: it is for a recovery that ran out
# of retries, and this one succeeded. A pane wearing "your shell is frozen" over
# a working shell is its own defect.
$bannersI = @(Terminal-Leaves $treeI | Where-Object { $_.banner -like '*Session helper unreachable*' })
Assert "I12 no pane is left wearing the give-up banner after a successful retry" (
    $bannersI.Count -eq 0)

# ============================================================================
"== J: the same abort, but the wedge ENDS - the panes must come back either way"
# ============================================================================
# The literal shape T723 names: hold the suspend well past the re-dial timeout,
# then RESUME, and the panes must end up responsive. Softer than section I,
# because two different things can cure it and the user cannot tell them apart:
# the old link can heal on its own (the abort left the panes riding it - recovery
# retires a connection only when the re-dial SUCCEEDS), or a retry re-dials the
# revived agent and rebuilds. The assertion is the user's question - "does my
# pane work" - not which path answered it. Before T723 neither did.
$logMarkJ = Get-AppLogLength
$agentsJ = Get-RunAgents $tmp
Assert "J1 one agent belongs to this run before the wedge" ($agentsJ.Count -eq 1)
$agentPidJ = if ($agentsJ.Count -ge 1) { [int]$agentsJ[0].ProcessId } else { 0 }
Assert "J2 the agent was suspended" (
    $agentPidJ -gt 0 -and (Set-AgentSuspended $agentPidJ $true) -eq 0)

$abortSeenJ = $false
$deadline = (Get-Date).AddSeconds(90)
while ((Get-Date) -lt $deadline) {
    if ((Read-AppLog $logMarkJ) -match 'in-place recovery ABORTED') { $abortSeenJ = $true; break }
    Start-Sleep -Milliseconds 200
}
if (-not $abortSeenJ) { Dump-AppLog $logMarkJ 'J3' }
Assert "J3 the wedge aborted recovery again" $abortSeenJ

# Resume unconditionally, including on the timeout path above: a suspended agent
# left behind would outlive this script.
$resumeRcJ = Set-AgentSuspended $agentPidJ $false
Assert "J4 the agent was resumed" ($resumeRcJ -eq 0)

Assert "J5 the panes are responsive again after the wedge ended" (
    Test-PaneResponsive $tmp 't145b' 'j' 60)
Assert "J6 the app pid never changed" (
    $null -ne (Get-Process -Id $appPid -ErrorAction SilentlyContinue))
$treeJ = Get-List $tmp 'j' 12
Assert "J7 the topology survived: one window, 2 terminals, the viewer intact" (
    (Windows-Of $treeJ).Count -eq 1 -and (Terminal-Leaves $treeJ).Count -eq 2 -and
    (Viewer-Leaves $treeJ).Count -eq 1)

# ============================================================================
"== K: T764 - a pane opened DURING a wedge falls back to exec, it does not inherit the stuck link"
# ============================================================================
# Sections I and J are about the panes that already existed when the agent
# wedged. This one is about the pane the user opens WHILE it is wedged, which
# had no defence at all: `LocalAgent.sharedConnection`'s fast path handed back
# the cached connection whenever its state was not `dead`, and a wedged agent
# parks the link in `reconnecting` forever (`dead` needs a server-sent DETACHED
# frame it never sends). So every new window and split was wired to a link that
# answers nothing and opened FROZEN - the wedge spreading to panes that were
# never part of it, and the exact outcome the plain-exec fallback exists to
# prevent.
#
# The oracle is the user's question, not a log line: does the window I just
# opened work. A new window is opened with the agent suspended and the link
# confirmed down, and its pane must round-trip a typed marker. Without the fix
# that pane is agent-backed over a stalled connection and never echoes
# anything.
$logMarkK = Get-AppLogLength
$agentsK = Get-RunAgents $tmp
if ($agentsK.Count -ne 1) { Show-Agents $tmp 'K' }
Assert "K1 one agent belongs to this run before the wedge" ($agentsK.Count -eq 1)
$agentPidK = if ($agentsK.Count -ge 1) { [int]$agentsK[0].ProcessId } else { 0 }
Assert "K2 the agent was suspended" (
    $agentPidK -gt 0 -and (Set-AgentSuspended $agentPidK $true) -eq 0)

# Wait for the APP to have noticed - three missed heartbeats, ~9s - rather than
# a clock of our own. Opening the window before the FSM has walked to
# `reconnecting` would test the healthy path and pass either way.
$downSeen = $false
$deadline = (Get-Date).AddSeconds(60)
while ((Get-Date) -lt $deadline) {
    if ((Read-AppLog $logMarkK) -match 'shared local-agent link went down') { $downSeen = $true; break }
    Start-Sleep -Milliseconds 200
}
if (-not $downSeen) { Dump-AppLog $logMarkK 'K3' }
Assert "K3 the app sees the shared link as down" $downSeen

# Window creation must also stay BOUNDED here: the wedged agent still holds its
# single-instance guard and still accepts a connection whose handshake never
# completes, so a fall-through to a fresh find-or-spawn would burn the whole
# spawn deadline on the GUI thread with the new window blocked behind it. A
# timed-out CLI call returns $null from Run-CliArgs.
$swK = [System.Diagnostics.Stopwatch]::StartNew()
$rcK = Run-CliArgs @('+new-window', '--target=t764w', '--no-activate') "$tmp\newwin-k.txt" 30
$swK.Stop()
"    [K4] +new-window during the wedge: rc=$rcK in $([int]$swK.Elapsed.TotalSeconds)s"
Assert "K4 a new window can still be opened while the agent is wedged" ($rcK -eq 0)

$treeK = $null
$deadline = (Get-Date).AddSeconds(30)
while ((Get-Date) -lt $deadline) {
    $treeK = Get-List $tmp 'k' 12
    if ((Windows-Of $treeK).Count -eq 2) { break }
    Start-Sleep -Milliseconds 500
}
Assert "K5 the new window really exists" ((Windows-Of $treeK).Count -eq 2)

# THE assertion. An exec pane works with no agent at all; a pane handed the
# wedged connection is a picture of a terminal.
Assert "K6 the pane opened during the wedge is a WORKING pane" (
    Test-PaneResponsive $tmp 't764w' 'k' 60)

# And the app says WHY it fell back, so the same event is diagnosable from a
# log the user can send. Secondary to K6 on purpose: the log line is evidence,
# the round-trip is the verdict.
#
# Polled, like K3, not read once (T1071): `Get-AppLogText` answers '' when the
# read races the app's own write to the log, so a single read could miss a line
# that a dump a moment later printed in full - three red runs that way.
$k7Said = $false
$deadline = (Get-Date).AddSeconds(15)
while ((Get-Date) -lt $deadline) {
    if ((Read-AppLog $logMarkK) -match 'opening this surface without the agent') { $k7Said = $true; break }
    Start-Sleep -Milliseconds 500
}
Assert "K7 the app said it opened the surface without the agent" $k7Said
if (-not $k7Said) { Dump-AppLog $logMarkK 'K7' }

# Unwedge and leave the box the way J did: the original panes must still be
# fine, so the fallback cost nothing to the panes that were already there.
#
# "or already gone" is not slack: on a run where K6 FAILS, its 60s liveness
# timeout holds the wedge past the agent's own single-instance staleness window
# (45s), the app's challenger kills the frozen holder, and there is no longer a
# process to resume. What this assertion is for is that this script never leaves
# a SUSPENDED agent behind, and a corpse satisfies that as fully as a resume
# does. Measured: the teeth run scored exactly that, a third failure that said
# nothing about the defect.
$resumeRcK = Set-AgentSuspended $agentPidK $false
$agentGoneK = $null -eq (Get-Process -Id $agentPidK -ErrorAction SilentlyContinue)
Assert "K8 the wedged agent is resumed (or already gone)" (
    $resumeRcK -eq 0 -or $agentGoneK)
Assert "K9 the pre-existing panes are responsive again after the wedge ended" (
    Test-PaneResponsive $tmp 't145b' 'k2' 60)

# ============================================================================
"== L: T1473 - a window asked for the moment the agent DIES is persistent, and the agent comes back at once"
# ============================================================================
# K's mirror image. K's agent is WEDGED (alive, not answering), so a fresh pane
# must fall back to exec rather than block on it. L's agent is DEAD - the
# process is gone - and there the same fallback is the defect: before T1473 the
# window opened in the gap between the death and the end of the 5s settle
# window came up as a plain, silently non-persistent shell (in-place recovery
# only rebuilds windows that rode the agent, so it stayed that way for good),
# and on the unlucky timing no agent was spawned at all. A dead process cannot
# heal its link, so there is nothing to wait for: the app now recovers first
# and hands the new window the fresh agent.
#
# Teeth: L3's 4s bound is under the 5s settle window, so the pre-fix app - which
# spawned the replacement only on the settle's deciding tick - cannot meet it;
# and L4 is red on the pre-fix app every time, since the pane it opened carried
# no session id.
$logMarkL = Get-AppLogLength
$agentsL = Get-RunAgents $tmp
if ($agentsL.Count -ne 1) { Show-Agents $tmp 'L' }
Assert "L1 one agent belongs to this run before the kill" ($agentsL.Count -eq 1)
$agentPidL = if ($agentsL.Count -ge 1) { [int]$agentsL[0].ProcessId } else { 0 }
# Same settle K waited on is NOT waited on here: the request lands inside the
# gap on purpose.
$killedL = $false
if ($agentPidL -gt 0) {
    # WaitForExit on a handle taken BEFORE the kill, not Wait-ProcGone's 250ms
    # poll: every millisecond spent confirming the death is a millisecond the
    # app gets to notice it first, and L is about the request that beats it.
    $procL = Get-Process -Id $agentPidL -ErrorAction SilentlyContinue
    Stop-Process -Id $agentPidL -Force -ErrorAction SilentlyContinue
    $killedL = ($null -eq $procL) -or $procL.WaitForExit(10000)
}
Assert "L2 premise: the agent process is dead" $killedL
$swL = [System.Diagnostics.Stopwatch]::StartNew()
$rcL = Run-CliArgs @('+new-window', '--target=t1473w', '--no-activate') "$tmp\newwin-l.txt" 30

$freshL = 0
$deadline = (Get-Date).AddSeconds(4)
while ((Get-Date) -lt $deadline) {
    $f = @((Get-RunAgents $tmp) | Where-Object { [int]$_.ProcessId -ne $agentPidL })
    if ($f.Count -gt 0) { $freshL = [int]$f[0].ProcessId; break }
    Start-Sleep -Milliseconds 200
}
$swL.Stop()
"    [L3] +new-window rc=$rcL; fresh agent pid=$freshL at $([int]$swL.Elapsed.TotalMilliseconds)ms"
Assert "L3 a fresh agent is up within 4s of the death (inside the old 5s settle window)" ($freshL -gt 0)

$winL = $null
$deadline = (Get-Date).AddSeconds(20)
while ((Get-Date) -lt $deadline) {
    $treeL = Get-List $tmp 'l' 12
    # Assign first, then filter: piping `Windows-Of` straight into Where-Object
    # unrolls only its unary-comma wrapper (the trap the Terminal-Leaves comment
    # above describes) and `.target` then member-enumerates over every window.
    $allL = Windows-Of $treeL
    $winL = @($allL | Where-Object { $_.target -eq 't1473w' }) | Select-Object -First 1
    if ($null -ne $winL) { break }
    Start-Sleep -Milliseconds 500
}
$leavesL = @()
if ($null -ne $winL) { foreach ($t in @($winL.tabs)) { $leavesL += @(Leaves-Of $t.splits) } }
$sidL = @($leavesL | Where-Object { $_.session_id }).Count
"    [L4] t1473w leaves=$($leavesL.Count) with a session id=$sidL"
Assert "L4 the window opened in the gap is agent-backed (its pane has a session id)" (
    $leavesL.Count -ge 1 -and $sidL -eq $leavesL.Count)
if ($sidL -ne $leavesL.Count) { Dump-AppLog $logMarkL 'L4' }
Assert "L5 the window opened in the gap is a WORKING pane" (
    Test-PaneResponsive $tmp 't1473w' 'l' 60)
Assert "L6 the pre-existing panes came back on the fresh agent too" (
    Test-PaneResponsive $tmp 't145b' 'l2' 60)

# ============================================================================
Stop-TestProcs
Remove-TestDesktop | Out-Null
$env:LOCALAPPDATA = $savedLocalAppData
if ($null -ne $savedAgentBin) { $env:GHOSTTY_LOCAL_AGENT_BIN = $savedAgentBin }
else { Remove-Item env:GHOSTTY_LOCAL_AGENT_BIN -ErrorAction SilentlyContinue }Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue

# A green run stamps the covered files (T783/T2876). Red leaves the stamp alone.
if ($script:failures -eq 0) {
    $repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard agent-recovery -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

if ($script:failures -eq 0) { "AGENT-RECOVERY: ALL PASS ($script:passes)"; exit 0 }
"AGENT-RECOVERY: $script:failures FAILURE(S) / $script:passes passed"
exit 1
