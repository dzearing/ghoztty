# Every new pane gets its OWN fresh shell, and every closed pane's shell is
# really gone (T3820).
#
# The user's report on 1.56.36, WSL as the default shell: "every time i open a
# new pane, it is REUSING THE OLD WSL PROCESS". Their own acceptance test is
# this script's shape: open a pane, echo, close it, open another, echo, close
# it, three times over; at the end only the original pane may be running, and
# every closed pane's process must be stopped and its memory freed.
#
# Every earlier WSL test stubs wsl.exe with a renamed cmd.exe, which is why a
# shell-sharing defect could ship: -Wsl runs the REAL wsl.exe.
#
# Sections (both arms run the same body):
#   A  baseline: the original pane P0 answers its own probe (shell pid, and on
#      WSL the Linux bash pid), and the run records the app's and the agent's
#      private bytes and handle counts.
#   B  -Rounds rounds (default 6, the user's three and three more for the
#      memory check); each opens a pane three ways - an IPC split of P0, a new
#      tab (ctrl+shift+t), a new window (+new-window) - and for every new pane
#      asserts: a fresh prompt whose scrollback holds no earlier PROBE marker,
#      a shell pid (Windows child, and Linux $$ on WSL) and an agent session id
#      that no earlier pane had, and its own marker read back from THIS pane
#      only. Then it closes the pane.
#   C  closes: odd rounds wait past undo-timeout before the next pane, even
#      rounds open the next pane WITHIN it (a new pane is never an undo).
#      Past the timeout every closed pane's processes (wsl.exe, and the Linux
#      bash on WSL) are gone and its agent session is ended.
#   D  window reuse (T2597) is on and at least one new pane took a parked
#      window - the log line proves it, so reuse is exercised, not assumed.
#   E  the end state: only the original panes are left; the app's and agent's
#      private bytes / handles are recorded against A, and the last two rounds
#      on a warm app must not grow them (a leak keeps growing; see T3822 for
#      the high water); then P0 is force-closed and none of this run's shells
#      or sessions survive.
#
# Arms. Without -Wsl the shell is powershell.exe (the normal floor runs this
# arm). With -Wsl it is `wsl.exe -d <distro> --cd ~`: opt-in only, because it
# needs WSL running - never run it from the floor, a sweep or the loop unasked.
#
# -NegativeControl probes P0 a second time as if it were a new pane, so the
# "a pid no earlier pane had" assertion MUST go red: proof the script can.
#
#   powershell -NoProfile -File test\win32\wsl-pane-lifecycle.ps1
#   powershell -NoProfile -File test\win32\wsl-pane-lifecycle.ps1 -Wsl [-Distro Ubuntu]
#
# Runs on a background Win32 desktop (test/win32/lib/TestDesktop.ps1) and
# asserts at the end that it never took the user's foreground. Only touches
# ghoztty processes running from this repo's zig-out.
param([string]$ExePath, [switch]$Wsl, [string]$Distro = 'Ubuntu', [int]$Rounds = 6, [switch]$NegativeControl)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }
$agentExe = Join-Path (Split-Path $exe -Parent) 'ghoztty-agent.exe'

$env:GHOZTTY_PIPE_SUFFIX = "-t3820$PID"

. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
Assert-GhozttyIsolatedBuild -Exe $exe | Out-Null
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$errlog = Join-Path $env:TEMP "ghoztty-t3820-stderr-$PID.log"
Remove-Item $errlog -ErrorAction SilentlyContinue

$script:pass = 0
$script:fail = 0
$script:firstFail = ''
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else {
        $script:fail++
        if (-not $script:firstFail) { $script:firstFail = $label }
        Write-Host "FAIL  $label" -ForegroundColor Red
    }
}

$arm = if ($Wsl) { 'wsl' } else { 'powershell' }
$command = if ($Wsl) { "wsl.exe -d $Distro --cd ~" } else { 'powershell.exe -NoLogo -NoProfile' }
$undoSec = 5   # Config.zig `undo-timeout` default
$pastUndoSec = $undoSec + 4

function Invoke-Gz($argv, [int]$timeoutSec = 25) {
    $r = Invoke-OnTestDesktop -Exe $exe -Arguments $argv -TimeoutSec $timeoutSec
    return [pscustomobject]@{
        Code = $(if ($r.TimedOut) { $null } else { $r.ExitCode })
        Text = $(if ($null -ne $r.Output) { "$($r.Output)" } else { '' })
    }
}

function Get-GzWindows {
    $l = Invoke-Gz @('+list', '--json')
    if ($l.Code -ne 0) { return @() }
    $j = $null
    try { $j = $l.Text | ConvertFrom-Json } catch { return @() }
    return @(if ($null -ne $j.data) { $j.data.windows } else { $j.windows })
}

function Get-TreeLeaves($node) {
    if ($null -eq $node) { return @() }
    if ($node.type -eq 'leaf') { return @($node.terminal) }
    if ($node.type -eq 'split') { return @(Get-TreeLeaves $node.left) + @(Get-TreeLeaves $node.right) }
    return @()
}

# Every terminal pane of every window: id, window, child pid, agent session.
function Get-AllPanes {
    $out = @()
    foreach ($w in @(Get-GzWindows)) {
        foreach ($tab in @($w.tabs)) {
            foreach ($leaf in @(Get-TreeLeaves $tab.splits)) {
                if ($null -eq $leaf) { continue }
                $out += [pscustomobject]@{ Window = $w.id; Target = $w.target; Id = $leaf.id; ChildPid = $leaf.pid; Session = $leaf.session_id }
            }
        }
    }
    return @($out)
}

# The ids of the agent sessions that are still alive.
function Get-LiveSessionIds {
    $r = Invoke-Gz @('+sessions', '--json')
    $rows = $null
    try { $rows = $r.Text | ConvertFrom-Json } catch { return @() }
    $ids = @()
    foreach ($s in @($rows | ForEach-Object { $_ })) {
        if ($null -eq $s) { continue }
        $alive = $s.alive
        if ($null -eq $alive -and $s.state) { $alive = ($s.state -eq 'alive') }
        if ($alive) { $ids += "$($s.id)" }
    }
    return @($ids)
}

# A pid is the SAME process only while its start time matches the one seen
# when the pane opened: Windows hands a freed pid to the next process within
# seconds, and a closed pane's pid already came back as a later pane's shell
# once (2026-11-26, C3 of the powershell arm) - which read as "still alive".
$script:pidStart = @{}
function Register-WinPid([int]$procId) {
    $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
    if ($p) { try { $script:pidStart["$procId"] = $p.StartTime } catch { } }
}
function Test-WinPidAlive([int]$procId) {
    if ($procId -le 0) { return $false }
    $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
    if ($null -eq $p) { return $false }
    if ($script:pidStart.ContainsKey("$procId")) {
        $started = $null
        try { $started = $p.StartTime } catch { }
        if ($null -ne $started -and $started -ne $script:pidStart["$procId"]) { return $false }
    }
    return $true
}

function Test-LinuxPidAlive([int]$procId) {
    if (-not $Wsl -or $procId -le 0) { return $false }
    $o = & wsl.exe -d $Distro -e sh -c "test -d /proc/$procId && echo ALIVE || echo GONE" 2>$null
    return ("$o" -match 'ALIVE')
}

# Wait for the pane's prompt, then print its marker and the shell's pid and
# read both back from THIS pane. Returns the shell pid (0 when it never
# answered) and every PROBE marker the pane held before it was asked.
function Invoke-Probe([string]$paneId, [string]$mark) {
    $deadline = (Get-Date).AddSeconds(40)
    $before = ''
    while ((Get-Date) -lt $deadline) {
        $before = (Invoke-Gz @('+read', "--name=$paneId", '--lines=200')).Text
        if ($before -match '[\$#>] *\r?\n?\s*$') { break }
        Start-Sleep -Milliseconds 600
    }
    # No quotes and no spaces in the probe: the CLI hop through CreateProcess
    # drops inner quotes, so a quoted PowerShell echo arrived mangled.
    $line = if ($Wsl) { "echo PROBE-${mark}:pid=`$`$\n" } else { "echo PROBE-${mark}:pid=`$PID\n" }
    [void](Invoke-Gz @('+send-keys', "--target=$paneId", $line))
    $shellPid = 0
    $deadline = (Get-Date).AddSeconds(25)
    while ((Get-Date) -lt $deadline) {
        $t = (Invoke-Gz @('+read', "--name=$paneId", '--lines=200')).Text
        $m = [regex]::Match($t, "PROBE-${mark}:pid=(\d+)")
        if ($m.Success) { $shellPid = [int]$m.Groups[1].Value; break }
        Start-Sleep -Milliseconds 500
    }
    $prior = @([regex]::Matches($before, 'PROBE-([A-Za-z0-9]+):pid=') | ForEach-Object { $_.Groups[1].Value })
    return [pscustomobject]@{ ShellPid = $shellPid; Prior = $prior }
}

function Wait-NewPane($known, [int]$timeoutSec = 20) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $new = @(Get-AllPanes | Where-Object { $known -notcontains $_.Id -and $_.ChildPid })
        if ($new.Count -gt 0) { return $new[0] }
        Start-Sleep -Milliseconds 400
    }
    return $null
}

function Get-RepoProcStats {
    $app = @(Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" | Where-Object { $_.ExecutablePath -ieq $exe })
    $agents = @(Get-CimInstance Win32_Process -Filter "Name='ghoztty-agent.exe'" |
        Where-Object { $_.ExecutablePath -ieq $agentExe -and $_.CommandLine -notmatch '--pty-host' })
    $sum = { param($rows) $b = 0; $h = 0; foreach ($r in $rows) { $p = Get-Process -Id $r.ProcessId -ErrorAction SilentlyContinue; if ($p) { $b += $p.PrivateMemorySize64; $h += $p.HandleCount } }; @($b, $h) }
    $a = & $sum $app
    $g = & $sum $agents
    return [pscustomobject]@{ AppBytes = $a[0]; AppHandles = $a[1]; AgentBytes = $g[0]; AgentHandles = $g[1] }
}

Write-Host "T3820 every new pane gets its own fresh shell; closed panes are really gone (arm: $arm)"
if ($NegativeControl) { Write-Host 'NEGATIVE CONTROL: P0 is probed again as if it were a new pane; this run MUST fail.' }
if ($Wsl) {
    $distros = (& wsl.exe -l -q 2>$null) -replace "`0", ''
    if (-not (@($distros) | Where-Object { $_.Trim() -eq $Distro })) {
        Write-TestAssertedNothing -Reason "no WSL distro named '$Distro' (wsl -l -q: $(@($distros) -join ','))" -Label 'wsl-pane-lifecycle'
    }
}

[void](Reset-GhozttyTestState -Exe $exe -SettleMs 900)
Start-TestForegroundWatch
New-TestDesktop | Out-Null

$script:app = $null
$seenShell = @{}   # shell pid -> pane that owned it
$seenChild = @{}   # Windows child pid -> pane
$seenSession = @{} # agent session -> pane
$closed = @()      # panes closed so far: Id, ChildPid, ShellPid, Session
$opened = 0
$roundStats = @{}
try {
    # persistence: on (default) - the user's setup: every pane is an agent session, and section C asserts each closed one ends.
    $script:app = Start-OnTestDesktop -Exe $exe -Arguments @("--command=$command") -StdErr $errlog
    [void](Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow')
    if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }

    # --- A: baseline ------------------------------------------------------
    $r = Invoke-Gz @('+new-window', '--target=t3820w0', '--name=t3820p0')
    Assert ($r.Code -eq 0) "A: the original window opens (got '$($r.Code)')"
    $p0 = $null
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline -and $null -eq $p0) {
        $p0 = @(Get-AllPanes | Where-Object { $_.Target -eq 't3820w0' -and $_.ChildPid })[0]
        if ($null -eq $p0) { Start-Sleep -Milliseconds 400 }
    }
    if ($null -eq $p0) { Write-TestAssertedNothing -Reason 'the original pane never appeared in +list' -Label 'wsl-pane-lifecycle' }
    $probe0 = Invoke-Probe $p0.Id 'p0'
    Assert ($probe0.ShellPid -gt 0) "A: P0 answers its own probe (shell pid $($probe0.ShellPid))"
    $seenShell["$($probe0.ShellPid)"] = $p0.Id
    $seenChild["$($p0.ChildPid)"] = $p0.Id
    Register-WinPid ([int]$p0.ChildPid)
    if ($p0.Session) { $seenSession["$($p0.Session)"] = $p0.Id }
    $baselinePanes = @(Get-AllPanes | ForEach-Object { $_.Id })
    Start-Sleep -Seconds 2  # settle: let P0's start-up allocations land before the baseline sample
    $base = Get-RepoProcStats
    Write-Host ("A: baseline app {0:N1} MB / {1} handles, agent {2:N1} MB / {3} handles" -f ($base.AppBytes / 1MB), $base.AppHandles, ($base.AgentBytes / 1MB), $base.AgentHandles)
    $p0Win = [IntPtr][int64]$p0.Window

    # --- B/C: three rounds of open -> probe -> close ------------------------
    for ($round = 1; $round -le $Rounds; $round++) {
        $withinUndo = ($round % 2 -eq 0)
        foreach ($how in @('split', 'tab', 'window')) {
            $mark = "r$round$how"
            $known = @(Get-AllPanes | ForEach-Object { $_.Id })
            switch ($how) {
                'split' { $r = Invoke-Gz @('+split', "--pane=$($p0.Id)"); $ok = ($r.Code -eq 0) }
                'tab' {
                    Focus-TestWindow -Window $p0Win | Out-Null
                    $active = [IntPtr](Wait-TestFocusedWindow -Window $p0Win -Class 'GhozttyTerminal')
                    $ok = Send-TestKeys -Window $p0Win -Target $active -Modifiers ctrl, shift -Key T
                }
                'window' { $r = Invoke-Gz @('+new-window', "--target=t3820w$mark"); $ok = ($r.Code -eq 0) }
            }
            Assert $ok "B${round}: the $how gesture was delivered"
            $np = Wait-NewPane $known
            Assert ($null -ne $np) "B${round}: a new $how pane appeared"
            if ($null -eq $np) { continue }
            $opened++
            $realNew = $np
            if ($NegativeControl -and $round -eq 1 -and $how -eq 'split') { $np = $p0 }
            $probe = Invoke-Probe $np.Id $mark
            Assert ($probe.ShellPid -gt 0) "B${round}: the new $how pane answers its own probe (shell pid $($probe.ShellPid))"
            Assert ($probe.Prior.Count -eq 0) "B${round}: the new $how pane's scrollback holds no earlier marker (found '$($probe.Prior -join ',')')"
            Assert (-not $seenShell.ContainsKey("$($probe.ShellPid)")) "B${round}: the $how pane's shell pid $($probe.ShellPid) is new (earlier owner '$($seenShell["$($probe.ShellPid)"])')"
            Assert (-not $seenChild.ContainsKey("$($np.ChildPid)")) "B${round}: the $how pane's process $($np.ChildPid) is new"
            if ($np.Session) {
                Assert (-not $seenSession.ContainsKey("$($np.Session)")) "B${round}: the $how pane's agent session $($np.Session) is new"
                $seenSession["$($np.Session)"] = $np.Id
            }
            $seenShell["$($probe.ShellPid)"] = $np.Id
            $seenChild["$($np.ChildPid)"] = $np.Id
            Register-WinPid ([int]$np.ChildPid)
            # Its marker is in THIS pane only.
            $elsewhere = @()
            foreach ($other in @(Get-AllPanes | Where-Object { $_.Id -ne $np.Id })) {
                $t = (Invoke-Gz @('+read', "--name=$($other.Id)", '--lines=200')).Text
                if ($t -match "PROBE-${mark}:pid=") { $elsewhere += $other.Id }
            }
            Assert ($elsewhere.Count -eq 0) "B${round}: the $how pane's marker appears in no other pane (found in '$($elsewhere -join ',')')"

            # Close the pane that really opened (the negative control probed P0
            # in its place; closing P0 would take the rest of the run with it).
            $r = Invoke-Gz @('+close', "--target=$($realNew.Id)")
            Assert ($r.Code -eq 0) "C${round}: the $how pane closes (got '$($r.Code)')"
            $closed += [pscustomobject]@{ Id = $realNew.Id; ChildPid = [int]$realNew.ChildPid; ShellPid = $(if ($realNew -eq $np) { $probe.ShellPid } else { 0 }); Session = $realNew.Session; What = "$mark" }
            if ($withinUndo) { Start-Sleep -Milliseconds 600 } else { Start-Sleep -Seconds $pastUndoSec }
        }
        if ($withinUndo) { Start-Sleep -Seconds $pastUndoSec }
        # Past the timeout now, whichever way this round closed: every pane
        # closed so far is gone.
        $live = @(Get-LiveSessionIds)
        foreach ($c in $closed) {
            $deadline = (Get-Date).AddSeconds(10)
            while ((Get-Date) -lt $deadline -and (Test-WinPidAlive $c.ChildPid)) { Start-Sleep -Milliseconds 400 }
            Assert (-not (Test-WinPidAlive $c.ChildPid)) "C${round}: closed $($c.What)'s process $($c.ChildPid) is gone"
            if ($Wsl) { Assert (-not (Test-LinuxPidAlive $c.ShellPid)) "C${round}: closed $($c.What)'s Linux bash $($c.ShellPid) is gone" }
            if ($c.Session) { Assert ($live -notcontains "$($c.Session)") "C${round}: closed $($c.What)'s agent session is ended" }
        }

        Start-Sleep -Seconds 2  # settle: let the last close's teardown and frees land before sampling private bytes
        $roundStats[$round] = Get-RepoProcStats
        Write-Host ("C${round}: after the round app {0:N1} MB / {1} handles, agent {2:N1} MB / {3} handles" -f ($roundStats[$round].AppBytes / 1MB), $roundStats[$round].AppHandles, ($roundStats[$round].AgentBytes / 1MB), $roundStats[$round].AgentHandles)
    }
    Assert ($opened -eq 3 * $Rounds) "B: all $(3 * $Rounds) panes opened (got $opened)"

    # --- D: window reuse was exercised ------------------------------------
    $reused = @(Select-String -Path $errlog -SimpleMatch -Pattern 'terminal pane reuses a parked window' -ErrorAction SilentlyContinue).Count
    Assert ($reused -ge 1) "D: at least one new pane took a parked window (reuse lines: $reused)"

    # --- E: end state -------------------------------------------------------
    $now = @(Get-AllPanes | ForEach-Object { $_.Id })
    $extra = @($now | Where-Object { $baselinePanes -notcontains $_ })
    Assert ($extra.Count -eq 0 -and $now.Count -eq $baselinePanes.Count) "E: only the original panes are left ($($now.Count) of $($baselinePanes.Count); extra '$($extra -join ',')')"
    Start-Sleep -Seconds 2  # settle: let the last close's teardown and frees land before sampling private bytes
    $end = Get-RepoProcStats
    $dAppMB = ($end.AppBytes - $base.AppBytes) / 1MB
    $dAgentMB = ($end.AgentBytes - $base.AgentBytes) / 1MB
    $dAppH = $end.AppHandles - $base.AppHandles
    $dAgentH = $end.AgentHandles - $base.AgentHandles
    Write-Host ("E: end app {0:N1} MB / {1} handles (delta {2:N1} MB / {3}), agent {4:N1} MB / {5} handles (delta {6:N1} MB / {7})" -f ($end.AppBytes / 1MB), $end.AppHandles, $dAppMB, $dAppH, ($end.AgentBytes / 1MB), $end.AgentHandles, $dAgentMB, $dAgentH)
    # The A -> end delta above is RECORDED, not asserted. The app climbs for
    # the first rounds and then holds still (2026-11-26, Debug, real WSL:
    # 247.6 MB at A, then 287.9 / 351.1 / 362.9 / 375.7 / 376.6 / 375.9 /
    # 375.5 MB after rounds 1-7; handles flat after round 2): high water, not
    # a per-pane leak - T3822 owns giving that memory back. What a LEAK looks
    # like is growth that keeps coming, so the assertion is on the last two
    # rounds, on a warm app: their six panes must leave the numbers where they
    # were. Tolerance per pane: 4 MB / 40 handles in the app, 2 MB / 20 handles
    # in the agent (T2692's GPU residue is 1.4 MB a pane).
    $warm = $roundStats[$Rounds - 2]
    $hot = $roundStats[$Rounds]
    if ($null -ne $warm -and $null -ne $hot) {
        $gAppMB = ($hot.AppBytes - $warm.AppBytes) / 1MB
        $gAppH = $hot.AppHandles - $warm.AppHandles
        $gAgentMB = ($hot.AgentBytes - $warm.AgentBytes) / 1MB
        $gAgentH = $hot.AgentHandles - $warm.AgentHandles
        Assert ($gAppMB -lt 24) ("E: the last two rounds' six panes on a warm app grow its private bytes by under 24 MB (grew {0:N1} MB)" -f $gAppMB)
        Assert ($gAppH -lt 240) "E: and its handle count by under 240 (grew $gAppH)"
        Assert ($gAgentMB -lt 12) ("E: the agent's private bytes by under 12 MB (grew {0:N1} MB)" -f $gAgentMB)
        Assert ($gAgentH -lt 120) "E: and the agent's handle count by under 120 (grew $gAgentH)"
    } else {
        Assert $false 'E: the per-round memory samples were taken'
    }

    $r = Invoke-Gz @('+close', '--target=t3820p0', '--force')
    Assert ($r.Code -eq 0) "E: P0 force-closes (got '$($r.Code)')"
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline -and (Test-WinPidAlive ([int]$p0.ChildPid))) { Start-Sleep -Milliseconds 400 }
    Assert (-not (Test-WinPidAlive ([int]$p0.ChildPid))) "E: P0's process $($p0.ChildPid) is gone"
    if ($Wsl) { Assert (-not (Test-LinuxPidAlive $probe0.ShellPid)) "E: P0's Linux bash $($probe0.ShellPid) is gone" }
    $live = @(Get-LiveSessionIds)
    $survivors = @($seenSession.Keys | Where-Object { $live -contains $_ })
    Assert ($survivors.Count -eq 0) "E: none of this run's agent sessions is still alive (survivors '$($survivors -join ',')')"

    Assert (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) 'the run never took the interactive desktop'
} catch {
    Write-Host "FAIL  harness error: $_" -ForegroundColor Red
    $script:fail++
    if (-not $script:firstFail) { $script:firstFail = "harness error: $_" }
} finally {
    [void](Reset-GhozttyTestState -Exe $exe -SettleMs 900)
    Remove-TestDesktop
}

$fgSeen = @(Stop-TestForegroundWatch)
Write-Host "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if ($env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @(Get-TestLaunchedPids)
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) "no test-desktop app ever became foreground on the interactive desktop (saw $($leaked -join ','))"
}

$label = if ($Wsl) { 'WSL LIFECYCLE' } else { 'SHELL LIFECYCLE' }
if ($script:fail -eq 0) { Write-Host "${label}: ALL PASS" } else { Write-Host "${label}: FAIL at '$($script:firstFail)'" }

Complete-TestBody
if ($script:fail -eq 0 -and -not $NegativeControl -and -not $Wsl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard wsl-pane-lifecycle -Repo $repo 2>&1 | ForEach-Object { Write-Host "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Label "wsl-pane-lifecycle ($arm)" -MinPass 60
