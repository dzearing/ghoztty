# Auto-launch working-directory fidelity (tracker T132).
#
# The loop-killer this covers: `upgrade-ghoztty-windows.ps1` killed the app and
# the agent, then relaunched with
#   +new-window --target=main --working-directory=D:\git\ghoztty --command="claude ... --continue"
# and the pane came up in C:\Windows\System32 - the DETACHED LAUNCHER's cwd - so
# `--continue` had no session there and Claude Code stopped on its trust prompt
# with nobody to answer. The loop was dead 7h20m.
#
# Two defects, both proven on the box before the fix:
#
#   1. `+new-window` with no running instance auto-launches the exe with NO
#      working directory, so the new instance inherits the CLI's cwd, and so does
#      everything it starts - the startup window, every `working-directory =
#      inherit` pane, and the session-persistence AGENT it spawns.
#   2. The agent never recorded `OPEN.cwd` on the session, so it was never written
#      to sessions.json and `handleRelaunch` passed a null cwd. A session that
#      outlived its agent (reboot, agent upgrade - exactly what the upgrade script
#      does) respawned in the AGENT's cwd instead of its own.
#
# Sections:
#   A  auto-launch honors --working-directory: the IPC pane's REPORTED and ACTUAL
#      cwd are the requested directory, launched from C:\Windows\System32.
#   B  the auto-launched INSTANCE opened exactly ONE window (T2162 - before it,
#      a blank startup window `window-1` sat beside the requested one), and it
#      was started with the requested directory and `--initial-window=false`.
#      Until T2162 B's oracle was that startup window's shell cwd; the window no
#      longer exists, so B reads the launched command line instead.
#   C  the recorded cwd survives an AGENT restart: kill app AND agent, relaunch
#      the app from System32, and the auto-RELAUNCHed pane comes back in the
#      recorded directory. (Defect 2's oracle: before the fix it landed wherever
#      the relaunching process was - System32.)
#   D  +list reports the recorded cwd across an APP-only restart (T166).
#   E  `--initial-window=false` with NOTHING asking for a window still opens one
#      once the grace period ends (T2162) - the app never sits invisible.
#
# Non-interactive; asserts and exits nonzero on any failure. Fully hermetic: a
# per-run $env:LOCALAPPDATA + per-run GHOSTTY_LOCAL_AGENT_BIN, and it ONLY ever
# kills ghoztty / ghoztty-agent processes launched from the repo zig-out (never
# the user's real release instance, which uses a different agent lineage, state
# dir, and IPC pipe).
#
#   powershell -NoProfile -File test\win32\auto-launch-cwd.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe'
)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

# T1240: the GUI launches ON THE TEST DESKTOP, not on the user's. A window
# arrives on the desktop of whoever started the process, so this script used to
# put one across whatever the user was reading. The launch's WORKING DIRECTORY,
# which is what the script measures, is passed through unchanged.
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$ErrorActionPreference = 'Continue'
$script:failures = 0
$root = Join-Path $env:TEMP "ghoztty-auto-launch-cwd-$PID"

# The directory the caller ASKS for, and the one the launcher SITS in. They must
# differ, and the launcher's must be one nothing would ever pick on purpose -
# that is what makes a leak visible instead of accidentally correct.
$workDir = Join-Path $root 'workdir'
$launcherDir = 'C:\Windows\System32'

function Assert($name, $cond) {
    if ($cond) { "  PASS $name" } else { "  FAIL $name"; $script:failures++ }
}
function AssertEq($name, $expected, $actual) {
    if ($expected -eq $actual) { "  PASS $name" }
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
    return @(Get-CimInstance Win32_Process -Filter "Name='$name'" |
        Where-Object { $_.CommandLine -like '*zig-out*' }).Count
}

# Run a zig-out ghoztty +command FROM $fromDir with a hard timeout; output -> $out.
# The working directory is the whole point here, so it is an explicit parameter
# rather than "whatever the harness happens to be sitting in".
function Run-CliFrom($fromDir, $argsLine, $out, $timeoutSec = 20) {
    $p = Start-Process -FilePath cmd.exe -WindowStyle Hidden -PassThru `
        -WorkingDirectory $fromDir `
        -ArgumentList "/c `"`"$Exe`" $argsLine > `"$out`" 2>&1`""
    $null = $p.Handle   # before any wait, or ExitCode reads empty (lib\ExitCodeAudit.ps1)
    if (-not $p.WaitForExit($timeoutSec * 1000)) {
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        return $null
    }
    return $p.ExitCode
}
# Ordinary CLI call; the launcher directory does not matter for these.
function Run-Cli($argsLine, $out, $timeoutSec = 20) {
    return (Run-CliFrom $launcherDir $argsLine $out $timeoutSec)
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
function Get-Tree($tmp, $tag) {
    $code = Run-Cli '+list --json' "$tmp\list-$tag.json" 20
    if ($code -ne 0) { return $null }
    try { return (Out-Text "$tmp\list-$tag.json" | ConvertFrom-Json) } catch { return $null }
}
function Windows-Of($tree) {
    if ($null -eq $tree) { return @() }
    if ($null -ne $tree.data) { return @($tree.data.windows) }
    return @($tree.windows)
}
# The first pane of the window registered as $target (or $null).
function Pane-In($tree, $target) {
    foreach ($w in (Windows-Of $tree)) {
        if ($w.target -ne $target) { continue }
        foreach ($t in @($w.tabs)) {
            $leaf = Find-Leaf $t.splits
            if ($null -ne $leaf) { return $leaf }
        }
    }
    return $null
}
function Wait-WindowCount($tmp, $tag, $target, $timeoutSec = 40) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $tree = $null
    while ((Get-Date) -lt $deadline) {
        $tree = Get-Tree $tmp $tag
        if (@(Windows-Of $tree).Count -ge $target) { return $tree }
        Start-Sleep -Milliseconds 700
    }
    return $tree
}
# Poll +list until the named pane REPORTS the expected working directory
# (T166): the attach RPC and the pwd_change it queues land moments after the
# window itself appears, so a single snapshot can catch the pre-attach seed.
function Wait-PaneWd($tmp, $tag, $target, $expected, $timeoutSec = 30) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $pane = $null
    $n = 0
    while ((Get-Date) -lt $deadline) {
        $pane = Pane-In (Get-Tree $tmp "$tag$n") $target
        if ($null -ne $pane -and (Norm $pane.working_directory) -eq (Norm $expected)) { return $pane }
        $n++
        Start-Sleep -Milliseconds 800
    }
    return $pane
}

# ---- "where is this pane REALLY?" ------------------------------------------
# +list reports the cwd the app THINKS a pane has. That is the number the bug
# report was about, but it is not proof: ask the shell itself. `cd` with no
# argument prints the current directory in cmd.exe. Compared case-insensitively
# and trailing-separator-insensitively.
function Norm($p) {
    if ($null -eq $p) { return '' }
    return ($p.Trim().TrimEnd('\').ToLowerInvariant())
}
function Shell-Cwd($tmp, $tag, $target, $timeoutSec = 25) {
    Run-Cli "+send-keys --target=$target cd Enter" "$tmp\cd-$tag.txt" 15 | Out-Null
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 800
        Run-Cli "+read --name=$target --lines=40" "$tmp\read-$tag.txt" 15 | Out-Null
        $lines = @((Out-Text "$tmp\read-$tag.txt") -split "`r?`n" |
            ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
        # The echoed reply to `cd`: the LAST line that looks like a bare absolute
        # path (a prompt line ends in '>' and so never matches).
        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            if ($lines[$i] -match '^[A-Za-z]:\\[^>]*$') { return $lines[$i] }
        }
    }
    return ''
}

# One hermetic GUI launch FROM $fromDir (section C relaunches the app itself
# from the launcher directory, which is where the old bug's cwd came from).
function Launch-From($tmp, $fromDir) {
    New-Item -ItemType Directory -Force (Get-GhozttyAgentStateDir -Root $tmp) | Out-Null
    $env:LOCALAPPDATA = $tmp
    $env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe
    # persistence: on (default), into a throwaway $env:LOCALAPPDATA - the agent under test is spawned from there, and there is no shared manifest to restore.
    [void](Start-OnTestDesktop -Exe $Exe -WorkingDirectory $fromDir)
}

$td = New-TestDesktop

Stop-TestProcs
New-Item -ItemType Directory -Force $root | Out-Null
New-Item -ItemType Directory -Force $workDir | Out-Null
$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN

Assert "agent binary exists in zig-out" (Test-Path $AgentExe)
Assert "ghoztty exe exists in zig-out" (Test-Path $Exe)

$tmp = Join-Path $root 'state'
New-Item -ItemType Directory -Force (Get-GhozttyAgentStateDir -Root $tmp) | Out-Null
$env:LOCALAPPDATA = $tmp
$env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe

# T441: a private IPC endpoint. The LOCALAPPDATA redirect above does not cover
# it — the endpoint a CLI dials comes from the pane's baked
# `$GHOZTTY_IPC_SOCKET` unless a suffix outranks it, so without this the
# +new-window calls below land in the user's installed release.
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 'autocwd')
Assert-GhozttyPrivateEndpoint -Exe $Exe

# ============================================================================
"== A: auto-launch honors --working-directory"
# ============================================================================
Assert "A0 no zig-out instance is running (the auto-launch precondition)" `
    ((Count-TestProcs 'ghoztty.exe') -eq 0)

# THE repro shape: run from System32, ask for $workDir. No instance is running,
# so this spawns one and re-sends the request to it.
$codeA = Run-CliFrom $launcherDir "+new-window --target=alc --working-directory=$workDir" `
    "$tmp\new-window.txt" 60
Assert "A1 +new-window auto-launched an instance and succeeded (exit 0)" ($codeA -eq 0)

$treeA = Wait-WindowCount $tmp 'a' 1 40
Assert "A2 the requested window exists" (@(Windows-Of $treeA).Count -ge 1)
Assert-GhozttyIsolated -Exe $Exe

$paneA = Pane-In $treeA 'alc'
Assert "A3 the requested window is registered as 'alc'" ($null -ne $paneA)
AssertEq "A4 +list reports the requested working directory" (Norm $workDir) (Norm $paneA.working_directory)

$shellA = Shell-Cwd $tmp 'a' 'alc' 30
AssertEq "A5 the SHELL is actually in the requested directory" (Norm $workDir) (Norm $shellA)
Assert "A6 the shell is not in the launcher's directory" ((Norm $shellA) -ne (Norm $launcherDir))

# ============================================================================
"== B: the auto-launched INSTANCE started in the requested directory"
# ============================================================================
# T2162: the instance was launched to serve this request, so the request's
# window is the ONLY one. Wait past the deferred startup window's grace period
# (5s, `startup_window.zig`) before counting: a fallback that fired anyway would
# show up as a second window here.
Start-Sleep -Seconds 7
$treeB = Get-Tree $tmp 'b'
AssertEq "B1 exactly one window after the cold auto-launch (no stray window-1)" 1 `
    @(Windows-Of $treeB).Count
Assert "B2 that one window is the requested 'alc'" ($null -ne (Pane-In $treeB 'alc'))

# The launched instance itself: started in the requested directory (T132's
# `--working-directory`, which also reaches the agent it spawns) and told not to
# open a window of its own. CLI processes carry a `+verb`; the app does not.
$exeNorm = Norm $Exe
$launched = @(Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
    Where-Object { (Norm $_.ExecutablePath) -eq $exeNorm -and $_.CommandLine -notmatch ' \+' })
AssertEq "B3 one auto-launched instance is running" 1 $launched.Count
$cmdB = if ($launched.Count -ge 1) { [string]$launched[0].CommandLine } else { '' }
Assert "B4 it was launched with --initial-window=false" ($cmdB -match '--initial-window=false')
Assert "B5 it was launched with the requested --working-directory" `
    ($cmdB.ToLowerInvariant().Contains(('--working-directory=' + $workDir).ToLowerInvariant()))

# ============================================================================
"== C: the recorded cwd survives an AGENT restart (RELAUNCH lands there)"
# ============================================================================
# Kill the app AND the agent - the upgrade script's exact move, since it swaps
# both binaries. The agent's children die with it; its on-disk state survives, so
# the next launch re-materializes each session as a relaunchable tombstone and
# `session-relaunch = rerun` respawns it. The respawn must use the RECORDED cwd.
Assert "C0 an agent is running before the kill" ((Count-TestProcs 'ghoztty-agent.exe') -ge 1)
Stop-TestProcs
Assert "C1 app and agent are both stopped" `
    (((Count-TestProcs 'ghoztty.exe') -eq 0) -and ((Count-TestProcs 'ghoztty-agent.exe') -eq 0))

# Relaunch FROM System32: a fresh agent spawns as this app's child and inherits
# that cwd, so a session with no recorded cwd respawns there. That is the trap.
Launch-From $tmp $launcherDir
$treeC = Wait-WindowCount $tmp 'c' 1 60
Assert "C2 restore rebuilt the windows after the agent restart" (@(Windows-Of $treeC).Count -ge 1)

$paneC = Pane-In $treeC 'alc'
Assert "C3 the named window came back" ($null -ne $paneC)

$shellC = Shell-Cwd $tmp 'c' 'alc' 45
AssertEq "C4 the RELAUNCHed shell is in the recorded directory" (Norm $workDir) (Norm $shellC)
Assert "C5 the RELAUNCHed shell did NOT land in the relaunching process's directory" `
    ((Norm $shellC) -ne (Norm $launcherDir))

# The reboot floor on disk is what carried it across: sessions.json must record
# the cwd, or the next restart repeats the bug.
$sessionsJson = Join-Path (Get-GhozttyAgentStateDir -Root $tmp) 'sessions.json'
$recorded = @()
if (Test-Path $sessionsJson) {
    try {
        $j = Get-Content $sessionsJson -Raw | ConvertFrom-Json
        $recorded = @($j.sessions | Where-Object { (Norm $_.cwd) -eq (Norm $workDir) })
    } catch {}
}
Assert "C6 sessions.json records the working directory for the reboot floor" ($recorded.Count -ge 1)

# T166: what the shell proved in C4, `+list --json` must also REPORT — the
# relaunch notice pane runs a fresh shell in the recorded directory, and the
# app now threads that recorded cwd into the pane it reports.
$paneC7 = Wait-PaneWd $tmp 'c7-' 'alc' $workDir 30
AssertEq "C7 +list reports the recorded directory (relaunch path)" `
    (Norm $workDir) (Norm $paneC7.working_directory)

# ============================================================================
"== D: +list reports the recorded cwd across an APP-only restart (T166)"
# ============================================================================
# Kill the app but LEAVE the agent: the sessions stay alive and the relaunch
# re-ATTACHes to them. Before T166 every re-attached pane reported the
# config-resolved default (the user profile dir) - the initTerminal seed -
# while `+sessions --json` knew the real answer; now the ATTACHED reply's cwd
# is threaded into the pane. The pid must survive too: same process, new app.
$paneD0 = Wait-PaneWd $tmp 'd0-' 'alc' $workDir 10
Assert "D0 pane reports a live pid before the app restart" `
    ($null -ne $paneD0 -and [int]$paneD0.pid -gt 0)

# T351: the shared, path-exact kill (lib\CleanSlate.ps1). -AppOnly is the point
# of this step - D1 below asserts the agent SURVIVED - and exact-exe is what the
# '*zig-out*' filter got wrong: it also matched a detached instance running from
# zig-out-release (T53b).
[void](Stop-RepoGhoztty -Exe $Exe -AppOnly -SettleMs 1500)
Assert "D1 the agent survived the app kill" ((Count-TestProcs 'ghoztty-agent.exe') -ge 1)

Launch-From $tmp $launcherDir
$treeD = Wait-WindowCount $tmp 'd' 1 60
Assert "D2 restore rebuilt the windows after the app restart" (@(Windows-Of $treeD).Count -ge 1)

$paneD = Wait-PaneWd $tmp 'd3-' 'alc' $workDir 30
Assert "D3 the named window came back" ($null -ne $paneD)
AssertEq "D4 +list reports the recorded directory after re-ATTACH" `
    (Norm $workDir) (Norm $paneD.working_directory)
Assert "D5 the shell pid survived the re-attach (same process)" `
    ($null -ne $paneD -and [int]$paneD.pid -eq [int]$paneD0.pid -and [int]$paneD.pid -gt 0)

# ============================================================================
"== E: initial-window=false with no request still opens a window (T2162)"
# ============================================================================
# A fresh state dir, so there is no manifest to restore: the deferred startup
# window is the only thing that can put a window on screen.
Stop-TestProcs
$tmpE = Join-Path $root 'state-e'
New-Item -ItemType Directory -Force (Get-GhozttyAgentStateDir -Root $tmpE) | Out-Null
$env:LOCALAPPDATA = $tmpE
# persistence: on (default), into a fresh throwaway $env:LOCALAPPDATA - no manifest, so restore opens nothing and the grace timer is the only source of a window.
[void](Start-OnTestDesktop -Exe $Exe -Arguments @('--initial-window=false') -WorkingDirectory $workDir)
Start-Sleep -Seconds 2
$treeE0 = Get-Tree $tmpE 'e0'
Assert "E1 the app answers +list during the grace period" ($null -ne $treeE0)
AssertEq "E2 no window yet inside the grace period" 0 @(Windows-Of $treeE0).Count
$treeE = Wait-WindowCount $tmpE 'e' 1 30
AssertEq "E3 the deferred startup window opened once the grace period ended" 1 `
    @(Windows-Of $treeE).Count

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

""
if ($script:failures -eq 0) { "ALL PASS"; exit 0 } else { "$($script:failures) FAILURE(S)"; exit 1 }
