# T3752 acceptance: Restart Pane with Shell replaces a pane's shell IN PLACE.
#
# WHAT THE USER ASKED FOR (T3735, 2026-11-25)
#
# "i need something like a way to change a pane's shell, maybe through command
# palette?" - a pane whose shell is the wrong one should become the right one
# without closing it and rebuilding the layout around it. The pane keeps its
# id, its name and its place; only the shell inside it changes. When something
# other than the shell is running, it asks first, as a close would.
#
# The user's ways in are the pane context menu's "Restart Pane with Shell"
# submenu and the command palette's "Restart Pane with Shell: <shell>" rows.
# Both end in `pane_restart.restart`; this script drives that function through
# the debug-only `restart-pane` IPC seam (ipc_restart_pane.zig), because a
# test on the background desktop cannot open a context menu.
#
#   A. The list: the seam's choices name cmd.exe and powershell.exe (always on
#      this box), never a bare wsl.exe, and every WSL entry is wsl:<distro>.
#   B. An agent-backed pane (session persistence on, the default) restarted
#      from cmd to Windows PowerShell: same pane id, same name, same pane
#      count; a NEW session whose shell is powershell.exe; the old cmd process
#      gone; the new shell's $env:GHOZTTY_PANE_ID is the pane's id.
#   C. The close-confirm rule: with `ping -n 60` running in that pane, a probe
#      restart answers confirm_needed and leaves the pane (same session, ping
#      still running); a forced restart replaces it and the ping is gone.
#   D. A plain ConPTY pane (session-persistence = false) restarted from cmd to
#      Windows PowerShell: same id, new powershell.exe pid, old one gone.
#   E. Refusals: an unknown pane is an error and nothing changes.
#   W. (-Wsl only: CLAUDE.md says never start WSL unasked) a restart into the
#      first installed distro lands in its home: `pwd` reads the same as
#      `wsl -d <distro> -- sh -c 'cd ~ && pwd'`.
#
# Hermetic: per-run LOCALAPPDATA and XDG config, a private IPC endpoint
# (lib\Isolation), the agent under test pinned, the GUI and every CLI call on
# a background test desktop; only processes whose ExecutablePath is the
# exe/agent under test are ever stopped.
#
#   powershell -NoProfile -File test\win32\restart-pane.ps1 [-Wsl]
param(
    [string]$Exe = '',
    [string]$AgentExe = '',
    [switch]$Wsl,
    [switch]$NegativeControl
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $Exe) { $Exe = Join-Path $repoRoot 'zig-out\bin\ghoztty.exe' }
if (-not $AgentExe) { $AgentExe = Join-Path $repoRoot 'zig-out\bin\ghoztty-agent.exe' }

$script:passes = 0
$script:failures = 0
$script:skipped = 0

function Assert([string]$name, [bool]$cond) {
    if ($NegativeControl -and $name -like 'B.1 *') { $cond = -not $cond }
    if ($cond) { Write-Host "  PASS $name"; $script:passes++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:failures++ }
}
function Say($m) { Write-Host $m }

if (-not (Test-Path $Exe)) {
    Write-TestAssertedNothing -Label 'RESTART-PANE' -Reason "exe not found: $Exe (build with: zig build -Dapp-runtime=win32 -Doptimize=Debug)"
}
if (-not (Test-Path $AgentExe)) {
    Write-TestAssertedNothing -Label 'RESTART-PANE' -Reason "agent not found: $AgentExe (build with: zig build agent -Doptimize=Debug)"
}

. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null
. (Join-Path $PSScriptRoot 'lib\PaneCapture.ps1')   # Invoke-GhozttyIpc

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
    # settle: the agent's pty hosts outlive it briefly and are stopped second, as in session-shell-exit.ps1
    Start-Sleep -Milliseconds 700
    foreach ($p in (Get-TestAgentProcs | Where-Object { $_.CommandLine -match '--pty-host' })) {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    }
    # settle: let the killed processes release the private pipe before the next launch binds it
    Start-Sleep -Milliseconds 400
}

# --- CLI plumbing (on the test desktop) --------------------------------------
function Run-CliArgs([string[]]$argv, [string]$out, [int]$timeoutSec = 15) {
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
function All-Leaves($tree) {
    $acc = @()
    $wins = if ($null -eq $tree) { @() } elseif ($null -ne $tree.data) { @($tree.data.windows) } else { @($tree.windows) }
    foreach ($w in $wins) {
        foreach ($t in @($w.tabs)) { $acc += Leaves-Of $t.splits }
    }
    return , $acc
}
function Get-Tree([string]$tag) {
    $rc = Run-CliArgs @('+list', '--json') "$tmp\list-$tag.json" 12
    if ($rc -ne 0) { return $null }
    try { return ((Out-Text "$tmp\list-$tag.json") | ConvertFrom-Json) } catch { return $null }
}
function Get-Leaf([string]$name, [string]$tag) {
    $lv = @((All-Leaves (Get-Tree $tag)) | Where-Object { $_.name -eq $name })
    if ($lv.Count -eq 1) { return $lv[0] }
    return $null
}
# The named leaf once its shell pid is `$name`.exe (and, for an agent pane,
# once it carries a session id other than `$notSession`).
function Wait-LeafShell([string]$paneName, [string]$procName, [string]$tag, [string]$notSession = '', [int]$timeoutSec = 45) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $i = 0
    while ((Get-Date) -lt $deadline) {
        $lf = Get-Leaf $paneName "$tag$i"
        if ($null -ne $lf -and [int]$lf.pid -gt 0) {
            $p = Get-Process -Id ([int]$lf.pid) -ErrorAction SilentlyContinue
            $sidOk = (-not $notSession) -or ([string]$lf.session_id -and [string]$lf.session_id -ne $notSession)
            if ($null -ne $p -and $p.ProcessName -ieq $procName -and $sidOk) { return $lf }
        }
        $i++
        Start-Sleep -Milliseconds 600
    }
    return $null
}
function Read-PaneText([string]$target, [string]$tag, [int]$lines = 60) {
    $rc = Run-CliArgs @('+read', "--name=$target", "--lines=$lines") "$tmp\read-$tag.txt" 15
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
function Wait-Gone([int]$procId, [int]$timeoutSec = 15) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        if ($null -eq (Get-Process -Id $procId -ErrorAction SilentlyContinue)) { return $true }
        Start-Sleep -Milliseconds 300
    }
    return $false
}
function Restart-Pane([string]$pane, [string]$shell, [string]$mode = 'probe') {
    return Invoke-GhozttyIpc -Action 'restart-pane' -Arguments @('--op=restart', "--pane=$pane", "--shell=$shell", "--mode=$mode")
}
# persistence: on (default) for A-C and W - the agent-backed pane is the main
# subject; section D turns it off through the config file (session-persistence
# = false) to cover the plain ConPTY path. Every launch runs inside this
# script's per-run $env:LOCALAPPDATA, so there is no manifest to restore from.
function Start-TestApp([string]$title, [int]$timeoutSec = 45) {
    [void](Start-OnTestDesktop -Exe $Exe -Arguments @(
        "--title=$title", '--window-width=100', '--window-height=30'))
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $rc = Run-CliArgs @('+list', '--json') "$tmp\list-up-$title.json" 10
        if ($rc -eq 0 -and (Out-Text "$tmp\list-up-$title.json") -match '\S') {
            $app = @(Get-TestApps | Where-Object { $_.CommandLine -like "*$title*" })
            if ($app.Count -ge 1) { return [int]$app[0].ProcessId }
        }
        Start-Sleep -Milliseconds 600
    }
    return 0
}
function Open-NamedSplit([string]$name, [string]$shell, [string]$tag) {
    $firstId = $null
    foreach ($lf in (All-Leaves (Get-Tree "$tag-first"))) { if (-not $firstId) { $firstId = $lf.id } }
    Run-CliArgs @('+split', "--pane=$firstId", "--name=$name", "--shell=$shell", '--direction=right') "$tmp\split-$name.txt" 20 | Out-Null
}
function Write-Config([string]$body) {
    $cfgDir = Join-Path $tmp 'xdg\ghostty'
    New-Item -ItemType Directory -Force $cfgDir | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $cfgDir 'config'), $body)
    $env:XDG_CONFIG_HOME = Join-Path $tmp 'xdg'
}

$root = Join-Path $env:TEMP "ghoztty-restart-pane-$PID"
$tmp = Join-Path $root 'run'
$savedLocalAppData = $env:LOCALAPPDATA
$savedXdg = $env:XDG_CONFIG_HOME
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN

try {
    Stop-Everything
    New-Item -ItemType Directory -Force $tmp | Out-Null
    $env:LOCALAPPDATA = $tmp
    $env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe
    # Always ask on a busy pane, never on an idle one: the rule under test.
    Write-Config "confirm-close-surface = true`n"

    . (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
    [void](Set-GhozttyTestIsolation -Tag 'restart3752')
    Assert-GhozttyPrivateEndpoint -Exe $Exe

    . (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
    $td = New-TestDesktop

    $appPid = Start-TestApp 't3752-rp'
    Assert 'premise: the app is up and answering IPC' ($appPid -gt 0)
    if ($appPid -le 0) { Write-TestVerdict -Label 'RESTART-PANE' -Pass $script:passes -Fail $script:failures }
    Assert-GhozttyIsolated -Exe $Exe

    # --- A: the list -----------------------------------------------------------
    Say '== A: the shells a picker offers'
    $ch = Invoke-GhozttyIpc -Action 'restart-pane' -Arguments @('--op=choices')
    $specs = @(if ($ch -and $ch.success) { @($ch.data.choices) | ForEach-Object { [string]$_.spec } })
    Assert 'A.1 the seam answers with a list' ($specs.Count -gt 0)
    Assert 'A.2 cmd.exe is offered' ($specs -contains 'cmd.exe')
    Assert 'A.3 Windows PowerShell is offered' ($specs -contains 'powershell.exe')
    Assert 'A.4 no bare wsl.exe entry (a WSL entry names its distro)' (-not ($specs | Where-Object { $_ -ieq 'wsl.exe' -or $_ -ieq 'wsl' }))
    $wslSpecs = @($specs | Where-Object { $_ -like 'wsl:*' })
    $labels = @(if ($ch -and $ch.success) { @($ch.data.choices) | ForEach-Object { [string]$_.label } })
    Assert 'A.5 every WSL entry is labelled "WSL: <distro>"' (@($labels | Where-Object { $_ -like 'WSL*' -and $_ -notlike 'WSL: *' }).Count -eq 0)

    # --- B: agent-backed pane, cmd -> powershell -------------------------------
    Say '== B: an agent-backed pane restarted from cmd to Windows PowerShell'
    Open-NamedSplit 'rp-b' 'cmd.exe' 'b'
    $before = Wait-LeafShell 'rp-b' 'cmd' 'b-a'
    Assert 'B.0 premise: the named pane is up on cmd with a session' ($null -ne $before -and [string]$before.session_id)
    if ($null -ne $before) {
        $countBefore = (All-Leaves (Get-Tree 'b-cnt0')).Count
        $oldPid = [int]$before.pid
        $r = Restart-Pane ([string]$before.id) 'powershell.exe'
        Assert 'B.1 an idle pane restarts without asking (outcome restarted)' ($r -and $r.success -and $r.data.outcome -eq 'restarted')
        $after = Wait-LeafShell 'rp-b' 'powershell' 'b-b' ([string]$before.session_id)
        Assert 'B.2 the pane now runs powershell.exe in a NEW session' ($null -ne $after)
        if ($null -ne $after) {
            Assert 'B.3 it is the same pane: the id did not change' ([string]$after.id -eq [string]$before.id)
            Assert 'B.4 its name came with it' ([string]$after.name -eq 'rp-b')
            Assert 'B.5 the layout kept its pane count' ((All-Leaves (Get-Tree 'b-cnt1')).Count -eq $countBefore)
            Assert 'B.6 the old cmd shell is gone' (Wait-Gone $oldPid)
            $marker = 'T3752ID'
            Run-CliArgs @('+send-keys', '--target=rp-b', "echo $marker`$(`$env:GHOZTTY_PANE_ID)", 'Enter') "$tmp\b-keys.txt" 12 | Out-Null
            Assert 'B.7 the new shell carries the same GHOZTTY_PANE_ID' (Wait-PaneHas 'rp-b' 'b-id' ($marker + [string]$before.id) 30)
        }
    }

    # --- C: the close-confirm rule --------------------------------------------
    Say '== C: a pane running a program asks first'
    $cur = Get-Leaf 'rp-b' 'c-0'
    if ($null -ne $cur -and [int]$cur.pid -gt 0) {
        Run-CliArgs @('+send-keys', '--target=rp-b', 'ping -n 60 127.0.0.1', 'Enter') "$tmp\c-ping.txt" 12 | Out-Null
        $ping = $null
        $deadline = (Get-Date).AddSeconds(15)
        while ((Get-Date) -lt $deadline -and $null -eq $ping) {
            $ping = Find-Descendant ([int]$cur.pid) 'PING.EXE'
            if ($null -eq $ping) { Start-Sleep -Milliseconds 300 }
        }
        Assert 'C.0 premise: ping is running in the pane' ($null -ne $ping)
        if ($null -ne $ping) {
            $r = Restart-Pane ([string]$cur.id) 'cmd.exe' 'probe'
            Assert 'C.1 a busy pane answers confirm_needed instead of restarting' ($r -and $r.success -and $r.data.outcome -eq 'confirm_needed')
            # settle: C.2 asserts that NOTHING happens; a restart, had one been made, swaps the session within this window
            Start-Sleep -Milliseconds 800
            $still = Get-Leaf 'rp-b' 'c-1'
            Assert 'C.2 ...and is left as it was (same session, ping still running)' (
                $null -ne $still -and [string]$still.session_id -eq [string]$cur.session_id -and
                $null -ne (Get-Process -Id ([int]$ping.ProcessId) -ErrorAction SilentlyContinue))
            $r = Restart-Pane ([string]$cur.id) 'cmd.exe' 'force'
            Assert 'C.3 a confirmed (forced) restart replaces it' ($r -and $r.success -and $r.data.outcome -eq 'restarted')
            $after = Wait-LeafShell 'rp-b' 'cmd' 'c-2' ([string]$cur.session_id)
            Assert 'C.4 the pane is back on cmd, same id' ($null -ne $after -and [string]$after.id -eq [string]$cur.id)
            Assert 'C.5 the program that was running ended with the old session' (Wait-Gone ([int]$ping.ProcessId))
        }
    } else {
        Assert 'C.0 premise: pane rp-b still listed' $false
    }

    # --- E: refusals -------------------------------------------------------------
    Say '== E: refusals'
    $r = Restart-Pane 'no-such-pane-3752' 'cmd.exe'
    Assert 'E.1 an unknown pane is an error' ($r -and -not $r.success)
    $r = Invoke-GhozttyIpc -Action 'restart-pane' -Arguments @('--op=restart', '--pane=rp-b')
    Assert 'E.2 a restart without --shell is an error' ($r -and -not $r.success)

    # --- W: opt-in WSL arm -----------------------------------------------------
    if ($Wsl) {
        Say '== W: restart into a WSL distro (opt-in)'
        if ($wslSpecs.Count -eq 0) {
            Say '  SKIP W: no WSL distro installed'
            $script:skipped++
        } else {
            $spec = $wslSpecs[0]
            $distro = $spec.Substring(4)
            $distroHome = (& wsl.exe -d $distro -- sh -c 'cd ~ && pwd' 2>$null | Select-Object -First 1)
            $cur = Get-Leaf 'rp-b' 'w-0'
            $r = Restart-Pane ([string]$cur.id) $spec 'force'
            Assert "W.1 restart into $spec answers restarted" ($r -and $r.success -and $r.data.outcome -eq 'restarted')
            [void](Wait-LeafShell 'rp-b' 'wsl' 'w-1' ([string]$cur.session_id))
            Run-CliArgs @('+send-keys', '--target=rp-b', 'echo T3752W$(pwd)W', 'Enter') "$tmp\w-keys.txt" 12 | Out-Null
            Assert "W.2 the distro shell starts in its home ($distroHome)" (Wait-PaneHas 'rp-b' 'w-pwd' ("T3752W$($distroHome)W") 30)
        }
    } else {
        # skip-audit: W is an opt-in arm (CLAUDE.md: never start WSL unasked), not a section of the default run
        Say '  W not requested: the WSL arm is opt-in (-Wsl); nothing here starts WSL unasked'
    }

    # --- D: a plain ConPTY pane --------------------------------------------------
    Say '== D: a plain (no session persistence) pane'
    Stop-Everything
    Write-Config "confirm-close-surface = true`nsession-persistence = false`n"
    $appPid = Start-TestApp 't3752-rpd'
    Assert 'D.0 premise: the app is up without session persistence' ($appPid -gt 0)
    if ($appPid -gt 0) {
        Open-NamedSplit 'rp-d' 'cmd.exe' 'd'
        $before = Wait-LeafShell 'rp-d' 'cmd' 'd-a'
        Assert 'D.1 premise: the named pane is up on cmd, with no session' ($null -ne $before -and -not [string]$before.session_id)
        if ($null -ne $before) {
            $oldPid = [int]$before.pid
            $r = Restart-Pane ([string]$before.id) 'powershell.exe'
            Assert 'D.2 outcome restarted' ($r -and $r.success -and $r.data.outcome -eq 'restarted')
            $after = Wait-LeafShell 'rp-d' 'powershell' 'd-b'
            Assert 'D.3 the pane runs powershell.exe, same id' ($null -ne $after -and [string]$after.id -eq [string]$before.id)
            Assert 'D.4 the old cmd is gone' (Wait-Gone $oldPid)
        }
    }

    Complete-TestBody
} finally {
    Stop-Everything
    Remove-TestDesktop | Out-Null
    $env:LOCALAPPDATA = $savedLocalAppData
    if ($null -ne $savedXdg) { $env:XDG_CONFIG_HOME = $savedXdg } else { Remove-Item env:XDG_CONFIG_HOME -ErrorAction SilentlyContinue }
    if ($null -ne $savedAgentBin) { $env:GHOSTTY_LOCAL_AGENT_BIN = $savedAgentBin }
    else { Remove-Item env:GHOSTTY_LOCAL_AGENT_BIN -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

# --- stamp (T783) -----------------------------------------------------------
if ($script:failures -eq 0 -and -not $NegativeControl -and $script:skipped -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot 'scripts\guard-due.ps1') `
        update -Guard restart-pane -Repo $repoRoot 2>&1 | ForEach-Object { "  $_" }
}

Write-TestVerdict -Label 'RESTART-PANE' -Pass $script:passes -Fail $script:failures -Skipped $script:skipped
