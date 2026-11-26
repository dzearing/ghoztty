# A starting folder per shell (T3770): `shell-working-directory = <shell>=<folder>`.
#
# Before this, every Windows shell started in the one global
# `working-directory` and every WSL shell in `~`, with no way to give one shell
# its own folder. The key names a folder per shell; a pane opened on that shell
# with no folder of its own (nothing explicit, nothing inherited from a pane of
# the same family) starts there. A WSL shell's folder rides `wsl.exe --cd`, a
# Windows shell's is its process cwd. Settings > Terminal > Shell lists the
# values and checks each as it is typed.
#
# WSL is never started (CLAUDE.md): the "WSL" shell is a copy of cmd.exe named
# wsl.exe - the family and the matching are read off the program's NAME - and
# the folder it was handed is read off its command line (`--cd <folder>`). The
# "Windows" shell is the same bytes named notwsl.exe. No folder here holds
# `/c`, `/k` or `/r`: cmd finds those switches INSIDE a token (T3754's trap).
#
# Sections (both run once with session persistence OFF - plain ConPTY panes -
# and again with it ON - agent panes, the other spawn path):
#   A  the startup window, on the Windows stub as the default shell, starts in
#      that shell's own folder and NOT in the global `working-directory`.
#      Before T3770 it read the global folder.
#   B  a WSL split of a Windows pane (nothing to inherit across families)
#      starts at the WSL shell's folder: `--cd /home/n3770/wip`, where it used
#      to be `--cd ~`.
#   C  what must not move: an explicit `--working-directory` wins for both
#      families (a Linux one for WSL, an explicit `~` included), and a split
#      of a Windows pane still inherits that pane's folder.
#   D  (persistence OFF only) Settings: typing a value that cannot work shows
#      the row's problem before Enter, Enter refuses it with the file
#      untouched, and a good value is written.
#
# -NegativeControl starts the app WITHOUT the per-shell lines and keeps A's
# assertion, so A must go red: the proof that A can tell the two apart.
#
#   powershell -NoProfile -File test\win32\shell-starting-folder.ps1
#
# Runs on a background Win32 desktop (test/win32/lib/TestDesktop.ps1) and
# asserts at the end that it never took the user's foreground. Only touches
# ghoztty processes running from this repo's zig-out.
param([string]$ExePath, [switch]$NegativeControl)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }

$env:GHOZTTY_PIPE_SUFFIX = "-t3770$PID"

. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
Assert-GhozttyIsolatedBuild -Exe $exe | Out-Null
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\PaneCapture.ps1')   # Invoke-GhozttyIpc
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$errlog = Join-Path $env:TEMP "ghoztty-t3770-stderr-$PID.log"
$tmp = Join-Path $env:TEMP "ghoztty-t3770-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null
$global = Join-Path $tmp 'global'
$start = Join-Path $tmp 'start'
$near = Join-Path $tmp 'near'
$elsewhere = Join-Path $tmp 'elsewhere'
foreach ($d in @($global, $start, $near, $elsewhere)) { New-Item -ItemType Directory -Force $d | Out-Null }

$stubDir = Join-Path $tmp 'stub'
New-Item -ItemType Directory -Force $stubDir | Out-Null
$stubWsl = Join-Path $stubDir 'wsl.exe'
$stubWin = Join-Path $stubDir 'notwsl.exe'
Copy-Item (Join-Path $env:SystemRoot 'System32\cmd.exe') $stubWsl -Force
Copy-Item (Join-Path $env:SystemRoot 'System32\cmd.exe') $stubWin -Force

$wslFolder = '/home/n3770/wip'

# This dev build's own config, in a temp XDG home: the stub as the default
# shell, a global folder, and (unless the negative control) one folder per shell.
$cfgHome = Join-Path $tmp 'xdg'
$cfgDir = Join-Path $cfgHome 'ghostty'
$cfgFile = Join-Path $cfgDir 'config-debug.ghostty'
New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null
function Write-Config {
    $lines = @(
        "command = $stubWin",
        "working-directory = $global"
    )
    if (-not $NegativeControl) {
        $lines += "shell-working-directory = wsl=$wslFolder"
        $lines += "shell-working-directory = notwsl.exe=$start"
    }
    [System.IO.File]::WriteAllText($cfgFile, (($lines -join "`n") + "`n"))
}
function Read-Config {
    if (-not (Test-Path $cfgFile)) { return '' }
    return [System.IO.File]::ReadAllText($cfgFile)
}

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Reset-RepoState {
    [void](Reset-GhozttyTestState -Exe $exe -SettleMs 900)
}

function Run-CliArgs($argv, [int]$timeoutSec = 20) {
    $r = Invoke-OnTestDesktop -Exe $exe -Arguments $argv -TimeoutSec $timeoutSec
    return [pscustomobject]@{
        Code = $(if ($r.TimedOut) { $null } else { $r.ExitCode })
        Text = $(if ($null -ne $r.Output) { $r.Output } else { '' })
    }
}

function Test-SameDir([string]$a, [string]$b) {
    if (-not $a -or -not $b) { return $false }
    return ($a.Replace('/', '\').TrimEnd('\')) -ieq ($b.Replace('/', '\').TrimEnd('\'))
}

function Leaves-Of($node) {
    if ($null -eq $node) { return @() }
    if ($node.type -eq 'leaf') { return @($node.terminal) }
    if ($node.type -eq 'split') { return @(Leaves-Of $node.left) + @(Leaves-Of $node.right) }
    return @()
}

function Get-Windows {
    $list = Run-CliArgs @('+list', '--json')
    if ($list.Code -ne 0) { return @() }
    $tree = $null
    try { $tree = $list.Text | ConvertFrom-Json } catch { return @() }
    return @(if ($null -ne $tree.data) { $tree.data.windows } else { $tree.windows })
}

function Get-LeavesOf($w) {
    $out = @()
    foreach ($tab in @($w.tabs)) { $out += @(Leaves-Of $tab.splits) }
    return @($out)
}

function Get-WindowLeaves([string]$target) {
    $w = @(Get-Windows | Where-Object { $_.target -eq $target })
    if ($w.Count -lt 1) { return @() }
    return @(Get-LeavesOf $w[0])
}

# Every leaf of every window, for the startup window (it has no target).
function Get-AllLeaves {
    $out = @()
    foreach ($w in @(Get-Windows)) { $out += @(Get-LeavesOf $w) }
    return @($out)
}

function Wait-AnyLeafCwd([string]$want, [int]$TimeoutMs = 15000) {
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    $seen = ''
    while ((Get-Date) -lt $deadline) {
        $all = @(Get-AllLeaves)
        foreach ($leaf in $all) { if (Test-SameDir $leaf.working_directory $want) { return $leaf.working_directory } }
        if ($all.Count -gt 0) { $seen = (@($all | ForEach-Object { $_.working_directory }) -join ' | ') }
        Start-Sleep -Milliseconds 250
    }
    return $seen
}

function Wait-PaneCount([string]$target, [int]$want, [int]$TimeoutMs = 15000) {
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    $leaves = @()
    while ((Get-Date) -lt $deadline) {
        $leaves = @(Get-WindowLeaves $target)
        if ($leaves.Count -ge $want) { return $leaves }
        Start-Sleep -Milliseconds 250
    }
    return $leaves
}

function Wait-LeafCwd([string]$target, [string]$paneId, [string]$want, [int]$TimeoutMs = 15000) {
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    $cwd = ''
    while ((Get-Date) -lt $deadline) {
        foreach ($leaf in @(Get-WindowLeaves $target)) {
            if ($leaf.id -eq $paneId) { $cwd = $leaf.working_directory }
        }
        if (Test-SameDir $cwd $want) { return $cwd }
        Start-Sleep -Milliseconds 250
    }
    return $cwd
}

function New-LeafOf([string]$target, $known) {
    foreach ($leaf in @(Get-WindowLeaves $target)) {
        if ($known -notcontains $leaf.id) { return $leaf }
    }
    return $null
}

# The command lines of the processes the app started from one stub.
function Get-StubCommandLines([string]$stub) {
    return @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath -and ($_.ExecutablePath -ieq $stub) } |
        ForEach-Object { $_.CommandLine })
}
function Wait-StubCommandLine([string]$stub, [string]$pattern, [int]$TimeoutMs = 15000) {
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        $hit = @(Get-StubCommandLines $stub | Where-Object { $_ -like $pattern })
        if ($hit.Count -gt 0) { return $hit[0] }
        Start-Sleep -Milliseconds 250
    }
    return $null
}

function Start-App([bool]$persistence) {
    Write-Config
    Remove-Item $errlog -ErrorAction SilentlyContinue
    $env:XDG_CONFIG_HOME = $cfgHome
    $env:GHOZTTY_SETTINGS_BACKUP_DIR = (Join-Path $tmp 'backups')
    try {
        $a = @()
        if (-not $persistence) { $a += '--session-persistence=false' }
        $script:app = Start-OnTestDesktop -Exe $exe -Arguments $a -StdErr $errlog
    } finally {
        Remove-Item Env:XDG_CONFIG_HOME -ErrorAction SilentlyContinue
        Remove-Item Env:GHOZTTY_SETTINGS_BACKUP_DIR -ErrorAction SilentlyContinue
    }
    if (-not $script:app -or ($script:app.Process -and $script:app.Process.HasExited)) { return $false }
    $top = Wait-TestWindow -ProcessId $script:app.Pid -Class 'GhozttyWindow'
    return ($top -ne [IntPtr]::Zero)
}

function Run-Sections([string]$tag, [bool]$persistence) {
    # --- A: the startup window starts in its shell's own folder -----------
    $got = Wait-AnyLeafCwd $start
    Assert (Test-SameDir $got $start) "A[$tag]: the startup window, on the Windows stub, starts in that shell's folder (got '$got')"
    Assert (-not (Test-SameDir $got $global)) "A[$tag]: and not in the global working-directory"
    if ($NegativeControl) { return }

    # A window on the Windows stub, explicitly in `near` (the fixture for B/C).
    $winTarget = "t3770win$tag$PID"
    $r = Run-CliArgs @('+new-window', "--target=$winTarget", "--shell=$stubWin", "--working-directory=$near")
    Assert ($r.Code -eq 0) "C[$tag]: +new-window --shell=<windows stub> --working-directory=near exits 0 (got '$($r.Code)' $($r.Text))"
    $leaves = @(Wait-PaneCount $winTarget 1)
    if ($leaves.Count -lt 1) { Assert $false "C[$tag]: the Windows-stub window has a pane"; return }
    $winPane = $leaves[0].id
    $cwd = Wait-LeafCwd $winTarget $winPane $near
    Assert (Test-SameDir $cwd $near) "C[$tag]: an explicit --working-directory beats the shell's own folder (got '$cwd')"

    # C: a split of that Windows pane still inherits its folder.
    $known = @(@(Get-WindowLeaves $winTarget) | ForEach-Object { $_.id })
    $r = Run-CliArgs @('+split', "--pane=$winPane", "--shell=$stubWin")
    [void](Wait-PaneCount $winTarget 2)
    $s = New-LeafOf $winTarget $known
    $sCwd = ''
    if ($null -ne $s) { $sCwd = Wait-LeafCwd $winTarget $s.id $near }
    Assert (Test-SameDir $sCwd $near) "C[$tag]: a Windows split of a Windows pane still inherits its folder, not the shell's own (got '$sCwd')"

    # --- B: a WSL split of the Windows pane: nothing crosses families ------
    $r = Run-CliArgs @('+split', "--pane=$winPane", "--shell=$stubWsl")
    Assert ($r.Code -eq 0) "B[$tag]: +split --shell=<wsl stub> of a Windows pane exits 0 (got '$($r.Code)')"
    $hit = Wait-StubCommandLine $stubWsl "*--cd $wslFolder*"
    $seen = (@(Get-StubCommandLines $stubWsl) | ForEach-Object { ($_ -split 'stub\\')[-1] }) -join ' | '
    Assert ($null -ne $hit) "B[$tag]: the WSL split started at the WSL shell's own folder, --cd $wslFolder (stub processes: $seen)"

    # --- C: an explicit folder wins for WSL too, `~` included --------------
    $r = Run-CliArgs @('+new-window', "--target=t3770ask$tag$PID", "--shell=$stubWsl", '--working-directory=/home/n3770/asked')
    Assert ($r.Code -eq 0) "C[$tag]: +new-window --shell=<wsl stub> --working-directory=/home/... exits 0 (got '$($r.Code)' $($r.Text))"
    $hit = Wait-StubCommandLine $stubWsl '*--cd /home/n3770/asked*'
    Assert ($null -ne $hit) "C[$tag]: an explicit Linux folder beats the WSL shell's own (got '$hit')"
    $before = @(Get-StubCommandLines $stubWsl | Where-Object { $_ -like '*--cd ~*' }).Count
    $r = Run-CliArgs @('+new-window', "--target=t3770home$tag$PID", "--shell=$stubWsl", '--working-directory=~')
    Assert ($r.Code -eq 0) "C[$tag]: +new-window --shell=<wsl stub> --working-directory=~ exits 0 (got '$($r.Code)' $($r.Text))"
    $deadline = (Get-Date).AddSeconds(15)
    $after = $before
    while ((Get-Date) -lt $deadline -and $after -le $before) {
        Start-Sleep -Milliseconds 250
        $after = @(Get-StubCommandLines $stubWsl | Where-Object { $_ -like '*--cd ~*' }).Count
    }
    $seen = (@(Get-StubCommandLines $stubWsl) | ForEach-Object { ($_ -split 'stub\\')[-1] }) -join ' | '
    Assert ($after -gt $before) "C[$tag]: an explicit ~ is kept, not replaced by the shell's own folder (stub processes: $seen)"
}

Write-Host 'T3770 a starting folder per shell'
if ($NegativeControl) {
    Write-Host 'NEGATIVE CONTROL: the app starts WITHOUT shell-working-directory; section A MUST fail.'
}
Reset-RepoState
Start-TestForegroundWatch
New-TestDesktop | Out-Null

$script:app = $null
try {
    # ================= persistence OFF: plain ConPTY panes ================
    if (-not (Start-App $false)) { Write-TestAssertedNothing -Reason 'GUI did not come up (persistence off)' -Label 'shell-starting-folder'; exit 1 }
    Run-Sections 'off' $false

    if (-not $NegativeControl) {
        # --- D: Settings checks a value as it is typed ---------------------
        $s = Invoke-GhozttyIpc -Action 'settings' -Arguments @('--op=open')
        Assert ($null -ne $s -and $s.success) 'D: the Settings window opens'
        $cfgBefore = Read-Config

        $t = Invoke-GhozttyIpc -Action 'settings' -Arguments @('--op=typing', '--page=terminal', '--key=shell-working-directory', "--value=wsl:Ubuntu=C:\src")
        $row = $null
        foreach ($rr in @($t.data.rows)) { if ([string]$rr.key -eq 'shell-working-directory') { $row = $rr } }
        Assert ($null -ne $t -and $t.success -and ($t.data.editing -eq 'shell-working-directory')) "D: typing leaves the field open (editing '$($t.data.editing)')"
        Assert ($null -ne $row -and $row.problem) "D: a Windows folder for a WSL shell shows a problem as it is typed (problem '$($row.problem)')"

        $t = Invoke-GhozttyIpc -Action 'settings' -Arguments @('--op=typing', '--page=terminal', '--key=shell-working-directory', "--value=wsl:Ubuntu=~/src")
        $row = $null
        foreach ($rr in @($t.data.rows)) { if ([string]$rr.key -eq 'shell-working-directory') { $row = $rr } }
        Assert ($null -ne $row -and -not $row.problem) "D: fixing it to a Linux folder clears the problem before Enter (problem '$($row.problem)')"

        $bad = Join-Path $tmp 'no-such-folder'
        $a = Invoke-GhozttyIpc -Action 'settings' -Arguments @('--op=list-add', '--key=shell-working-directory', "--value=pwsh.exe=$bad")
        Assert ($null -ne $a -and -not $a.data.ok) "D: Enter refuses a Windows folder that does not exist (ok '$($a.data.ok)')"
        Assert ((Read-Config) -eq $cfgBefore) 'D: and the config file is untouched'

        $a = Invoke-GhozttyIpc -Action 'settings' -Arguments @('--op=list-add', '--key=shell-working-directory', "--value=pwsh.exe=$elsewhere")
        Assert ($null -ne $a -and $a.data.ok) "D: a good value is accepted (ok '$($a.data.ok)')"
        $cfgAfter = Read-Config
        Assert ($cfgAfter -match [regex]::Escape("shell-working-directory = pwsh.exe=$elsewhere")) 'D: and written to the config file as one more line'
        Assert ($cfgAfter -match [regex]::Escape("shell-working-directory = wsl=$wslFolder")) 'D: next to the values already there'
        [void](Invoke-GhozttyIpc -Action 'settings' -Arguments @('--op=close'))

        # ================= persistence ON: agent panes ====================
        Reset-RepoState
        if (-not (Start-App $true)) { Write-TestAssertedNothing -Reason 'GUI did not come up (persistence on)' -Label 'shell-starting-folder'; exit 1 }
        Run-Sections 'on' $true
    }

    Assert (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) 'the run never took the interactive desktop'
} catch {
    Write-Host "FAIL  harness error: $_" -ForegroundColor Red
    $script:fail++
} finally {
    Reset-RepoState
    Remove-TestDesktop
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

$fgSeen = @(Stop-TestForegroundWatch)
Write-Host "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if ($env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @(Get-TestLaunchedPids)
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) "no test-desktop app ever became foreground on the interactive desktop (saw $($leaked -join ','))"
}

# --- stamp (T783) ----------------------------------------------------------
Complete-TestBody
if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard shell-starting-folder -Repo $repo 2>&1 | ForEach-Object { Write-Host "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Label 'shell-starting-folder' -MinPass 30
