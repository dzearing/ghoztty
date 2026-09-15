# A split opens where ITS parent is, on the plain-ConPTY path too (T760).
#
# The defect, measured before the fix. With `session-persistence = off` there is
# no agent, so `Window.buildRemoteInherit` declines and nothing on the local path
# supplied a working directory for the new pane. The answer then came from the
# shared core - `apprt/surface.zig` `newConfig` reads `app.focusedSurface()`,
# which is an app-GLOBAL value - so a `+split` aimed at a pane in a window that
# does NOT hold focus opened in whatever window DID. Both legs were affected:
#
#   * IPC. `IpcHandlers.handleSplit`'s final `else` (no remote, no local agent)
#     builds a baton with `.working_directory = args.working_directory`, which
#     is null for a bare `+split`; `newSplitAt` only filled a null cwd when the
#     split parent was a VIEWER (T538), so a terminal parent fell through.
#   * The keybind. No baton at all, `buildRemoteInherit` null, viewer cwd null -
#     nothing armed.
#
# The persistence-ON path never had the hole: `buildRemoteInherit` asks the
# split PARENT over the agent's GET_CWD (T68/T515). So the two backends
# disagreed about what a split inherits, which is the real defect this pins
# down: the parent pane is the right answer for both, and section D asserts
# them against the SAME fixture so a future change cannot fix one and move the
# other.
#
# Sections:
#   A  setup control, persistence OFF. Window `near` opens in the near
#      directory, window `far` opens in the far one and is the LAST window
#      opened, so it is the one holding focus. Both are read back from
#      `+list --json` before anything is asserted - if the control does not
#      hold, the teeth in B mean nothing.
#   B  THE DEFECT. `+split --pane=<near's pane>` with no `--working-directory`
#      lands in the near directory and NOT in the far one. Before the fix this
#      assertion read `far`.
#   C  an explicit `--working-directory` still wins over the parent's cwd, and
#      a plain in-window keybind split (ctrl+d) still lands in its parent's
#      directory - the two things the fix must not have moved.
#   D  the same cross-window `+split`, with session persistence ON. The agent
#      path answered this correctly before the fix; asserting it here is what
#      makes "the two backends agree" a measured claim rather than a comment.
#
# `-NegativeControl` inverts B's assertion to the pre-fix expectation (the split
# lands in the FAR directory), so a green run is only evidence because the
# script can be made to go red.
#
#   powershell -NoProfile -File test\win32\split-inherit-cwd.ps1
#
# Runs on a background Win32 desktop (test/win32/lib/TestDesktop.ps1) and
# asserts at the end that it never took the user's foreground. Only touches
# ghoztty processes running from this repo's zig-out.
param([string]$ExePath, [switch]$NegativeControl)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }

# Isolate the IPC endpoint (inherited through CreateProcessW), so every
# `+verb` below reaches THIS instance and never the user's terminal.
$env:GHOZTTY_PIPE_SUFFIX = "-t760$PID"

. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
Assert-GhozttyIsolatedBuild -Exe $exe | Out-Null
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$errlog = Join-Path $env:TEMP "ghoztty-t760-stderr-$PID.log"
Remove-Item $errlog -ErrorAction SilentlyContinue

$tmp = Join-Path $env:TEMP "ghoztty-t760-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null
$near = Join-Path $tmp 't760-near'
$far = Join-Path $tmp 't760-far'
$elsewhere = Join-Path $tmp 't760-elsewhere'
foreach ($d in @($near, $far, $elsewhere)) { New-Item -ItemType Directory -Force $d | Out-Null }

# Run-unique window targets: a leftover `t760near` from an earlier run would be
# FOCUSED rather than recreated, and would answer with its own old directory.
$nearTarget = "t760near$PID"
$farTarget = "t760far$PID"

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

# The WHOLE reset, not just a kill (T248/T194). `+new-window --target=X` is
# idempotent by design, the agent outlives the app, and both the restore
# manifest and the agent's layout-blob store bring a named window back - so a
# private kill leaves last run's `t760near` alive and this run's
# `--working-directory` is never applied to it. Section D's second launch is
# exactly that shape and went red on it once before this was a reset.
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

# Path compare that tolerates separator and case differences: `+list` reports
# the cwd as the shell sees it.
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
    # `@(...)` AROUND the whole if, not inside each branch: PS 5.1 unrolls a
    # one-element array on its way out of an `if` expression, and `.Count` on
    # the bare PSCustomObject that lands is $null (T794).
    return @(if ($null -ne $tree.data) { $tree.data.windows } else { $tree.windows })
}

# Every terminal leaf of the window whose target is $target.
function Get-WindowLeaves([string]$target) {
    $w = @(Get-Windows | Where-Object { $_.target -eq $target })
    if ($w.Count -lt 1) { return @() }
    $out = @()
    foreach ($tab in @($w[0].tabs)) { $out += @(Leaves-Of $tab.splits) }
    return @($out)
}

# A window's pane count, polled until it reaches $want (a split lands
# asynchronously - the IPC reply returns before the pane has joined the tree).
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

# A leaf's reported working directory, polled until it answers $want or the
# clock runs out. `+list` seeds the pwd cache from termio a moment after the
# pane exists, so the first read after a split can legitimately be empty - a
# wait on the CLOCK, never on a try count (T738).
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

# The one pane of $target that is NOT in $known.
function New-LeafOf([string]$target, $known) {
    foreach ($leaf in @(Get-WindowLeaves $target)) {
        if ($known -notcontains $leaf.id) { return $leaf }
    }
    return $null
}

# Open the two-window fixture and return the near window's first pane. Shared
# by the persistence-OFF and persistence-ON runs so both measure the same
# arrangement: `near` opened first, `far` opened LAST and therefore focused.
function Open-Fixture {
    $r = Run-CliArgs @('+new-window', "--target=$nearTarget", "--working-directory=$near")
    if ($r.Code -ne 0) { return $null }
    Start-Sleep -Seconds 3
    $r = Run-CliArgs @('+new-window', "--target=$farTarget", "--working-directory=$far")
    if ($r.Code -ne 0) { return $null }
    Start-Sleep -Seconds 3
    $nearLeaves = @(Wait-PaneCount $nearTarget 1)
    if ($nearLeaves.Count -lt 1) { return $null }
    return $nearLeaves[0]
}

Write-Host 'T760 a split opens where its parent is (plain ConPTY path)'
if ($NegativeControl) {
    Write-Host 'NEGATIVE CONTROL: section B is inverted to the pre-fix expectation; this run MUST fail.'
}
Reset-RepoState
Start-TestForegroundWatch
New-TestDesktop | Out-Null

$script:app = $null
try {
    # --- A: persistence OFF, two windows, the FAR one holding focus --------
    # `--session-persistence=false` is the whole point of the run: it is the
    # configuration in which `buildRemoteInherit` declines and the local path
    # has to answer for itself.
    $script:app = Start-OnTestDesktop -Exe $exe `
        -Arguments @('--session-persistence=false') -StdErr $errlog
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: top window not found'; exit 1 }

    $parent = Open-Fixture
    if ($null -eq $parent) { Write-Host 'SETUP FAIL: could not open the two-window fixture'; exit 1 }

    $nearCwd = Wait-LeafCwd $nearTarget $parent.id $near
    Assert (Test-SameDir $nearCwd $near) "control: the near window's pane is in the near directory (got '$nearCwd')"

    $farLeaves = @(Wait-PaneCount $farTarget 1)
    $farCwd = ''
    if ($farLeaves.Count -ge 1) { $farCwd = Wait-LeafCwd $farTarget $farLeaves[0].id $far }
    Assert (Test-SameDir $farCwd $far) "control: the far window's pane is in the far directory (got '$farCwd')"
    Assert (-not (Test-SameDir $near $far)) 'control: the two directories are genuinely different'

    # --- B: the defect -----------------------------------------------------
    $known = @(@(Get-WindowLeaves $nearTarget) | ForEach-Object { $_.id })
    $r = Run-CliArgs @('+split', "--pane=$($parent.id)")
    Assert ($r.Code -eq 0) "+split against the non-focused window exits 0 (got '$($r.Code)')"
    $leaves = @(Wait-PaneCount $nearTarget 2)
    Assert ($leaves.Count -ge 2) "the split pane joined the near window (count $($leaves.Count))"
    $split = New-LeafOf $nearTarget $known
    $splitCwd = ''
    if ($null -ne $split) { $splitCwd = Wait-LeafCwd $nearTarget $split.id $near }
    if ($NegativeControl) {
        Assert (Test-SameDir $splitCwd $far) "NEGATIVE CONTROL: the split lands in the FAR directory (got '$splitCwd')"
    } else {
        Assert (Test-SameDir $splitCwd $near) "the split opened in ITS parent's directory (got '$splitCwd')"
    }
    Assert (-not (Test-SameDir $splitCwd $far)) "and NOT in the focused window's directory (got '$splitCwd')"

    # --- C: what must not have moved ---------------------------------------
    $known = @(@(Get-WindowLeaves $nearTarget) | ForEach-Object { $_.id })
    $r = Run-CliArgs @('+split', "--pane=$($parent.id)", "--working-directory=$elsewhere")
    Assert ($r.Code -eq 0) "+split with an explicit --working-directory exits 0 (got '$($r.Code)')"
    [void](Wait-PaneCount $nearTarget 3)
    $wdSplit = New-LeafOf $nearTarget $known
    $wdCwd = ''
    if ($null -ne $wdSplit) { $wdCwd = Wait-LeafCwd $nearTarget $wdSplit.id $elsewhere }
    Assert (Test-SameDir $wdCwd $elsewhere) "an explicit --working-directory still beats the parent's cwd (got '$wdCwd')"
    Assert (-not (Test-SameDir $wdCwd $near)) 'and does not fall back to the parent it was told to override'

    # The keybind leg. ctrl+d is `new_split = right` on Windows (Config.zig).
    # It splits the FOCUSED pane, so it cannot reproduce B's cross-window
    # shape - what it proves is that the fix did not move the ordinary case.
    $farWin = [IntPtr]::Zero
    foreach ($w in @(Get-Windows | Where-Object { $_.target -eq $farTarget })) { $farWin = [IntPtr][int64]$w.id }
    Assert ($farWin -ne [IntPtr]::Zero) 'found the far window HWND for the keybind leg'
    if ($farWin -ne [IntPtr]::Zero) {
        Focus-TestWindow -Window $farWin | Out-Null
        Start-Sleep -Milliseconds 800
        $active = [IntPtr](Get-TestFocusedWindow -Window $farWin)
        Assert ((Get-TestWindowClass -Window $active) -eq 'GhozttyTerminal') 'the far window forwarded focus to a terminal surface'
        $knownFar = @(@(Get-WindowLeaves $farTarget) | ForEach-Object { $_.id })
        Assert (Send-TestKeys -Window $farWin -Target $active -Modifiers ctrl -Key D) 'ctrl+d injected'
        [void](Wait-PaneCount $farTarget 2)
        $kbSplit = New-LeafOf $farTarget $knownFar
        $kbCwd = ''
        if ($null -ne $kbSplit) { $kbCwd = Wait-LeafCwd $farTarget $kbSplit.id $far }
        Assert (Test-SameDir $kbCwd $far) "a plain in-window keybind split still lands in its parent's directory (got '$kbCwd')"
    }

    # --- D: the same question of the AGENT path ----------------------------
    # A second launch, session persistence ON (the default), so every pane is
    # agent-backed and `buildRemoteInherit` is the one answering. The claim
    # "the two backends agree" is only a claim if both are measured against
    # the same fixture.
    Reset-RepoState
    Remove-Item $errlog -ErrorAction SilentlyContinue
    # persistence: on (the default) - this section's subject is the agent path.
    $script:app = Start-OnTestDesktop -Exe $exe -StdErr $errlog
    Start-Sleep -Seconds 4
    if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at the persistence-ON launch'; exit 1 }
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: persistence-ON top window not found'; exit 1 }

    $parentOn = Open-Fixture
    Assert ($null -ne $parentOn) 'the two-window fixture came up with persistence ON'
    if ($null -ne $parentOn) {
        $onNearCwd = Wait-LeafCwd $nearTarget $parentOn.id $near
        Assert (Test-SameDir $onNearCwd $near) "control: the agent-backed near pane is in the near directory (got '$onNearCwd')"
        $knownOn = @(@(Get-WindowLeaves $nearTarget) | ForEach-Object { $_.id })
        $r = Run-CliArgs @('+split', "--pane=$($parentOn.id)")
        Assert ($r.Code -eq 0) "agent-backed +split exits 0 (got '$($r.Code)')"
        [void](Wait-PaneCount $nearTarget 2)
        $onSplit = New-LeafOf $nearTarget $knownOn
        $onCwd = ''
        if ($null -ne $onSplit) { $onCwd = Wait-LeafCwd $nearTarget $onSplit.id $near }
        Assert (Test-SameDir $onCwd $near) "the agent-backed split also opened in ITS parent's directory (got '$onCwd')"
        Assert (-not (Test-SameDir $onCwd $far)) 'and also not in the focused window (the two backends agree)'
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
Complete-TestBody  # T1039: before the stamp, which is a child process reading this run's state
if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard split-inherit-cwd -Repo $repo 2>&1 | ForEach-Object { Write-Host "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Label 'split-inherit-cwd' -MinPass 16
