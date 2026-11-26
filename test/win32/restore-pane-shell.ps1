# T3755 acceptance: a pane opened on a chosen shell comes back on THAT shell,
# in its own folder, when a relaunch has to open a fresh shell for it - not on
# the default shell.
#
# The report (user, 2026-11-25, T3735): panes can now be opened on a shell of
# your choice (--shell, the "... with Shell" palette rows, Restart Pane with
# Shell), but the session layout recorded only the folder. When the agent and
# its sessions were gone, every pane came back on the default shell.
#
#   A. Build: one window, three agent-backed panes - the startup pane on the
#      default shell, a `--shell=cmd.exe` window in folder X and a
#      `--shell=powershell.exe` window in folder Y. The manifest records the
#      two chosen shells on their leaves and none on the default one.
#   B. Kill the app AND this run's agent and delete sessions.json, so every
#      recorded session is positively gone and every pane must OPEN fresh.
#   C. Relaunch: the cmd pane is cmd in X (`%CD%` expands - PowerShell would
#      print it verbatim), the PowerShell pane is Windows PowerShell
#      (`$PSVersionTable.PSEdition` is Desktop) in Y, the log names exactly
#      those two leaves as reopening on their own shell, and the manifest
#      still records both shells (a second relaunch would do the same).
#   D. Negative control: the startup pane recorded no shell and is not named
#      by that log line - C's lines are caused by the recorded field.
#   W. a `--shell=wsl:<distro>` pane cd'd to /tmp comes back in that distro
#      at /tmp. Runs only when the default distro is ALREADY running (T1751's
#      scripts\lib\WslState.ps1 asks without starting anything) or with -Wsl;
#      otherwise it SKIPs naming why - nothing here may boot WSL (CLAUDE.md).
#
# Isolation: a private LOCALAPPDATA, IPC pipe suffix and agent lineage
# (lib\AgentLineage.ps1), so the agent this run kills is its own. Runs on a
# BACKGROUND desktop (lib\TestDesktop.ps1).
#
#   powershell -NoProfile -File test\win32\restore-pane-shell.ps1 [-Wsl -Distro Ubuntu]
param([string]$ExePath, [switch]$Interactive, [switch]$KeepState, [switch]$Wsl, [string]$Distro)

# T351: dot-sourced first - it drops an inherited $GHOZTTY_IPC_SOCKET.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }
$agentExe = Join-Path (Split-Path $exe -Parent) 'ghoztty-agent.exe'
$env:GHOZTTY_PIPE_SUFFIX = "-paneshell$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\AgentLineage.ps1')
[void](Set-GhozttyTestAgentLineage -Tag 'paneshell' -Quiet)
. (Join-Path $repo 'scripts\lib\WslState.ps1')

$script:pass = 0
$script:fail = 0
$script:skip = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

$fakeLocal = Join-Path $env:TEMP ("ghoztty-t3755-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $fakeLocal | Out-Null
$dirCmd = Join-Path $fakeLocal 'cmd-home'
$dirPs = Join-Path $fakeLocal 'ps-home'
New-Item -ItemType Directory -Force -Path $dirCmd, $dirPs | Out-Null
$manifest = Get-GhozttySessionLayoutPath -Root $fakeLocal
$agentDir = Get-GhozttyAgentStateDir -Root $fakeLocal -Exe $exe
$sessionsFile = Join-Path $agentDir 'sessions.json'

function Read-Text([string]$p) { if (Test-Path $p) { (Get-Content $p -Raw) } else { '' } }

function Read-Manifest {
    $t = Read-Text $manifest
    if (-not $t) { return $null }
    try { return ($t | ConvertFrom-Json) } catch { return $null }
}

# Every terminal leaf in the manifest, in order.
function Manifest-Leaves($m) {
    $out = @()
    foreach ($w in @($m.windows)) {
        foreach ($t in @($w.tabs)) {
            foreach ($n in @($t.nodes)) {
                if ($null -ne $n.leaf -and $n.leaf.kind -ne 'viewer') { $out += $n.leaf }
            }
        }
    }
    return , $out
}

function Leaf-WithShell($m, [string]$spec) {
    foreach ($l in (Manifest-Leaves $m)) { if ([string]$l.shell -eq $spec) { return $l } }
    return $null
}

function Wait-Manifest([scriptblock]$Pred, [int]$TimeoutSec = 15) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $m = $null
    while ((Get-Date) -lt $deadline) {
        $m = Read-Manifest
        if ($null -ne $m) { try { if (& $Pred $m) { return $m } } catch {} }
        Start-Sleep -Milliseconds 300
    }
    return $m
}

# The CLI on the test desktop, against this run's pipe.
function Ghoz([string[]]$GhozArgs, [int]$TimeoutSec = 20) {
    $saved = $env:LOCALAPPDATA
    $env:LOCALAPPDATA = $fakeLocal
    try { return Invoke-OnTestDesktop -Exe $exe -Arguments $GhozArgs -TimeoutSec $TimeoutSec }
    finally { $env:LOCALAPPDATA = $saved }
}

function Wait-LogLine([string]$Path, [string]$Pattern, [int]$TimeoutSec = 20) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if ((Test-Path $Path) -and (Select-String -Path $Path -Pattern $Pattern -Quiet)) { return $true }
        Start-Sleep -Milliseconds 400
    }
    return $false
}

function Count-LogLines([string]$Path, [string]$Pattern) {
    if (-not (Test-Path $Path)) { return 0 }
    return @(Select-String -Path $Path -Pattern $Pattern).Count
}

# Type a line into the pane `name` and wait for `pattern` on its screen.
function Probe([string]$Name, [string]$Line, [string]$Pattern, [int]$Tries = 25) {
    $sk = Ghoz @('+send-keys', "--target=$Name", $Line, '--enter')
    $rd = $null
    for ($i = 0; $i -lt $Tries; $i++) {
        Start-Sleep -Milliseconds 400
        $rd = Ghoz @('+read', "--name=$Name")
        if ($rd -and $rd.StdOut -match $Pattern) { return $true }
    }
    Write-Host "      send-keys: exit $($sk.ExitCode) $($sk.Output)"
    if ($rd) { Write-Host "      read: exit $($rd.ExitCode) tail: $((($rd.StdOut -split "`n") | Where-Object { $_.Trim() } | Select-Object -Last 6) -join ' | ')" }
    return $false
}

# The app AND this run's agent (Stop-RepoGhoztty narrows to our lineage).
function Kill-All { [void](Stop-RepoGhoztty -Exe $exe -SettleMs 500) }

function Launch([string]$Tag) {
    $err = Join-Path $fakeLocal "app-$Tag.err.txt"
    $savedLocal = $env:LOCALAPPDATA
    $savedBin = $env:GHOSTTY_LOCAL_AGENT_BIN
    $env:LOCALAPPDATA = $fakeLocal
    $env:GHOSTTY_LOCAL_AGENT_BIN = $agentExe
    try {
        $a = Start-OnTestDesktop -Exe $exe -Arguments @('--session-persistence=true') -StdErr $err
    } finally {
        $env:LOCALAPPDATA = $savedLocal
        $env:GHOSTTY_LOCAL_AGENT_BIN = $savedBin
    }
    # A GUI that dies at launch does so within its first seconds; watch for it
    # rather than sleeping blind (each later step waits on its own condition).
    $deadline = (Get-Date).AddSeconds(2)
    while ((Get-Date) -lt $deadline -and -not ($a.Process -and $a.Process.HasExited)) {
        Start-Sleep -Milliseconds 200
    }
    if ($a.Process -and $a.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $script:app = $a
    $script:errLog = $err
    $script:launched += $a.Pid
}

$reopenPattern = 'session-restore: leaf reopens on its own shell'

$script:launched = @()
Kill-All
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    # ---------------------------------------------------------------- A
    Write-Host ''
    Write-Host '--- A: a default pane, a cmd pane in X and a PowerShell pane in Y ---'
    Launch 'build'
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: top window not found'; exit 1 }
    $r = Ghoz @('+new-window', '--target=t3755cmd', '--shell=cmd.exe', "--working-directory=$dirCmd")
    Assert ($null -ne $r -and $r.ExitCode -eq 0) "A: +new-window --shell=cmd.exe answered (exit $($r.ExitCode))"
    $r = Ghoz @('+new-window', '--target=t3755ps', '--shell=powershell.exe', "--working-directory=$dirPs")
    Assert ($null -ne $r -and $r.ExitCode -eq 0) "A: +new-window --shell=powershell.exe answered (exit $($r.ExitCode))"
    # Positive control before any restore: the shells ARE what they were asked to be.
    Assert (Probe 't3755cmd' 'echo T3755CMD[%CD%]' ([regex]::Escape("T3755CMD[$dirCmd]"))) 'A: the cmd pane is cmd, in X (%CD% expanded)'
    Assert (Probe 't3755ps' 'echo "T3755PS[$($PSVersionTable.PSEdition)]"' 'T3755PS\[Desktop\]') 'A: the PowerShell pane is Windows PowerShell'

    $mA = Wait-Manifest {
        param($m)
        $ls = Manifest-Leaves $m
        ($ls.Count -eq 3) -and ($null -ne (Leaf-WithShell $m 'cmd.exe')) -and ($null -ne (Leaf-WithShell $m 'powershell.exe'))
    }
    $leavesA = if ($mA) { Manifest-Leaves $mA } else { @() }
    Assert ($leavesA.Count -eq 3) "A: the manifest records 3 terminal leaves (got $($leavesA.Count))"
    $cmdLeaf = if ($mA) { Leaf-WithShell $mA 'cmd.exe' } else { $null }
    $psLeaf = if ($mA) { Leaf-WithShell $mA 'powershell.exe' } else { $null }
    Assert ($null -ne $cmdLeaf) 'A: the cmd leaf records shell "cmd.exe"'
    Assert ($null -ne $psLeaf) 'A: the PowerShell leaf records shell "powershell.exe"'
    $bare = @($leavesA | Where-Object { -not $_.shell })
    Assert ($bare.Count -eq 1) "A: exactly one leaf (the startup pane, default shell) records no shell (got $($bare.Count))"
    if ($cmdLeaf) { Assert ([string]$cmdLeaf.working_directory -eq $dirCmd) "A: the cmd leaf records folder X (got '$($cmdLeaf.working_directory)')" }

    # ---------------------------------------------------------------- B
    Write-Host ''
    Write-Host '--- B: the app and the agent die, and the agent forgets every session ---'
    $manifestBefore = Read-Text $manifest
    Kill-All
    Assert (Test-Path $sessionsFile) "B: the agent had written sessions.json ($sessionsFile)"
    Remove-Item -Force $sessionsFile -ErrorAction SilentlyContinue
    Assert (-not (Test-Path $sessionsFile)) 'B: sessions.json removed, so every recorded session is gone'
    Assert ((Read-Text $manifest) -eq $manifestBefore) 'B: the layout manifest is untouched by the kill'

    # ---------------------------------------------------------------- C
    Write-Host ''
    Write-Host '--- C: relaunch reopens each pane on its own shell, in its own folder ---'
    Launch 'dead'
    Assert (Wait-LogLine $errLog "$reopenPattern cmd\.exe" 25) 'C: the log names the cmd leaf reopening on cmd.exe'
    Assert (Wait-LogLine $errLog "$reopenPattern powershell\.exe" 10) 'C: the log names the PowerShell leaf reopening on powershell.exe'
    Assert (Probe 't3755cmd' 'echo T3755CMD2[%CD%]' ([regex]::Escape("T3755CMD2[$dirCmd]"))) 'C: the restored cmd pane is cmd, in X'
    Assert (Probe 't3755ps' 'echo "T3755PS2[$($PSVersionTable.PSEdition)][$((Get-Location).Path)]"' ([regex]::Escape("T3755PS2[Desktop][$dirPs]"))) 'C: the restored PowerShell pane is Windows PowerShell, in Y'
    # Assigned first: an @() around `Manifest-Leaves` would nest its `, $out`.
    $mC = Wait-Manifest { param($m) $ls = Manifest-Leaves $m; ($null -ne (Leaf-WithShell $m 'cmd.exe')) -and ($null -ne (Leaf-WithShell $m 'powershell.exe')) -and ($ls.Count -eq 3) }
    Assert ($null -ne $mC -and $null -ne (Leaf-WithShell $mC 'cmd.exe') -and $null -ne (Leaf-WithShell $mC 'powershell.exe')) 'C: the restored panes still record their shells (the next relaunch does the same)'
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'C: no crash'

    # ---------------------------------------------------------------- D
    Write-Host ''
    Write-Host '--- D: negative control - the default pane reopens on no recorded shell ---'
    $named = Count-LogLines $errLog $reopenPattern
    Assert ($named -eq 2) "D: exactly the two chosen-shell leaves reopened on their own shell, not the default pane (got $named)"
    # Assigned first: `Manifest-Leaves` returns `, $out`, which a pipeline
    # would carry as ONE object (memory: PS5.1 null/comma traps).
    $leavesC = if ($mC) { Manifest-Leaves $mC } else { @() }
    $bareC = @($leavesC | Where-Object { -not $_.shell })
    Assert ($bareC.Count -eq 1) "D: the default pane still records no shell (got $($bareC.Count))"

    # ---------------------------------------------------------------- W
    Write-Host ''
    $wslState = Get-WslDefaultDistroState
    if (-not $Distro -and $wslState) { $Distro = $wslState.Name }
    if (-not $Wsl -and -not (Test-WslDefaultDistroRunning)) {
        $script:skip++
        Write-Host "SKIP  W: $(Get-WslSkipReason)"
    } elseif (-not $Distro) {
        $script:skip++
        Write-Host 'SKIP  W: no WSL distro on this box'
    } else {
        Write-Host "--- W: a wsl:$Distro pane at /tmp comes back in $Distro at /tmp ---"
        $r = Ghoz @('+new-window', '--target=t3755wsl', "--shell=wsl:$Distro")
        Assert ($null -ne $r -and $r.ExitCode -eq 0) "W: +new-window --shell=wsl:$Distro answered (exit $($r.ExitCode))"
        # cd, then report it the way shell integration would (OSC 7), since a
        # stock distro shell does not.
        # The OSC bytes go through --keys-file: text arguments interpret
        # backslash escapes, and the file is sent verbatim (docs/claude/cli.md).
        $osc = 'cd /tmp && printf ''\033]7;file://localhost/tmp\007'' && echo T3755W[$(pwd)]'
        $keys = Join-Path $fakeLocal 'wsl-cd.txt'
        [IO.File]::WriteAllText($keys, $osc, (New-Object Text.UTF8Encoding $false))
        $sk = Ghoz @('+send-keys', '--target=t3755wsl', "--keys-file=$keys", 'Enter')
        Assert ($null -ne $sk -and $sk.ExitCode -eq 0) "W: the cd line was sent (exit $($sk.ExitCode))"
        $inTmp = $false
        for ($i = 0; $i -lt 25 -and -not $inTmp; $i++) {
            Start-Sleep -Milliseconds 400
            $rd = Ghoz @('+read', '--name=t3755wsl')
            if ($rd -and $rd.StdOut -match 'T3755W\[/tmp\]') { $inTmp = $true }
        }
        Assert $inTmp 'W: the WSL pane is in /tmp'
        $mW = Wait-Manifest { param($m) $l = Leaf-WithShell $m "wsl:$Distro"; $null -ne $l -and $l.working_directory -eq '/tmp' }
        Assert ($null -ne $mW) "W: the manifest records shell wsl:$Distro at /tmp"
        Kill-All
        $mK = Read-Manifest
        $wslLeaf = if ($mK) { Leaf-WithShell $mK "wsl:$Distro" } else { $null }
        $wd = if ($wslLeaf) { [string]$wslLeaf.working_directory } else { '<no leaf>' }
        Assert ($wd -eq '/tmp') "W: after the kill the WSL leaf still records /tmp (got '$wd')"
        Remove-Item -Force $sessionsFile -ErrorAction SilentlyContinue
        Launch 'wsl'
        Assert (Wait-LogLine $errLog "$reopenPattern wsl:$Distro \(cwd=/tmp\)" 25) "W: the log names the WSL leaf reopening on wsl:$Distro at /tmp"
        Assert (Probe 't3755wsl' 'echo T3755W2[$(pwd)][$WSL_DISTRO_NAME]' ([regex]::Escape("T3755W2[/tmp][$Distro]")) 40) "W: the restored pane is in $Distro at /tmp"
    }
    Complete-TestBody
} finally {
    Remove-TestDesktop
    Kill-All
    if ($KeepState) { Write-Host "state kept: $fakeLocal" }
    else { Remove-Item -Recurse -Force $fakeLocal -ErrorAction SilentlyContinue }
}

$fgSeen = @(Stop-TestForegroundWatch)
Write-Host "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @($script:launched | Select-Object -Unique)
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'no test-desktop app ever became foreground on the interactive desktop'
}

# --- stamp (T783) -----------------------------------------------------------
# A green run stamps; the WSL arm's SKIP (WSL not already running) is the
# declared default, and the code it reaches is the same builder the cmd and
# PowerShell arms drive (`pane_restart.shellOverrides`).
if ($script:fail -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard restore-pane-shell -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Label 'T3755 RESTORE-PANE-SHELL' -Pass $script:pass -Fail $script:fail -Skipped ([int]$script:skip) -MinPass 18
