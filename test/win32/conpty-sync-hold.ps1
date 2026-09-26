# T1763 acceptance: a ConPTY child's clear-and-redraw never shows a blank frame.
#
#   powershell -NoProfile -File test\win32\conpty-sync-hold.ps1
#   powershell -NoProfile -File test\win32\conpty-sync-hold.ps1 -NegativeControl
#
# THE DEFECT. Resizing a pane that runs Claude Code flickered: the content
# cleared and then repainted. Claude Code answers a resize by erasing the
# screen and redrawing it inside a DEC 2026 synchronized-output bracket, which
# a terminal is meant to show as one frame. ConPTY does not deliver the bracket
# intact. Measured on this box (in-box conhost, every CreatePseudoConsole flag
# tried), one app frame leaves conhost as two pipe writes:
#
#   ESC[?2026h ESC[2J ESC[3J ESC[?2026l         <- the erase, bracket closed
#   ESC[?25l ESC[H <every row of the new frame>  <- conhost's paint, unbracketed
#
# so at the moment the bracket closed the screen was empty, and the renderer
# was free to present it. src/termio/conpty_sync_hold.zig now keeps such a
# bracket open until the paint has landed (output idle, or a hard cap).
#
# THE ORACLE. Sampling pixels for a sub-frame blank is a coin flip (see the
# header of resize-flicker.ps1 for the measurements), so the app states it
# instead. A debug build logs, for every erasing bracket from a ConPTY child,
# how many rows of the screen hold text at the moment the frame became
# showable:
#
#   conpty sync shown how=<close|idle|cap> text_rows=<n> held_ms=<ms>
#
# `how=close` is the unheld path (shown the instant the bracket closed);
# `idle`/`cap` are the hold releasing. `text_rows=0` IS the blank frame. That
# is deterministic rather than a race: conhost's paint follows the bracket in
# the stream, so at the close nothing of the new frame has been parsed yet.
#
# The stub child below redraws the way Ink does - BSU, ED2, ED3, home, rows,
# ESU - once at start and again on every width change, and the script drives
# width changes by resizing the window.
#
# Sections:
#   A  a local pane (session persistence off: the app owns the ConPTY)
#   B  an agent-backed pane (persistence on: ghoztty-agent owns the ConPTY and
#      the app parses its stream as a remote pane, flavour from the HELLO)
#
# -NegativeControl runs the same thing with GHOZTTY_CONPTY_SYNC_HOLD=0, which
# turns the hold off, and expects the blank frames back - the proof that the
# oracle can see the defect at all.
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe',
    [switch]$NegativeControl,
    [switch]$Interactive
)

# T351: shared kill helpers; drops an inherited $GHOZTTY_IPC_SOCKET.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
# T1511: the shared scorer; the dot-source arms the run.
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')

$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$script:pass = 0
$script:fail = 0
$script:skipped = 0

function Assert([bool]$cond, [string]$label) {
    if ($cond) { Write-Host "  PASS  $label"; $script:pass++ }
    else { Write-Host "  FAIL  $label" -ForegroundColor Red; $script:fail++ }
}

Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null
Assert (Test-Path $Exe) 'ghoztty exe exists in zig-out'
Assert (Test-Path $AgentExe) 'agent exe exists in zig-out'

$root = Join-Path $env:TEMP "ghoztty-t1763-synchold-$PID"
New-Item -ItemType Directory -Force $root | Out-Null
$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN
$savedHold = $env:GHOZTTY_CONPTY_SYNC_HOLD
if ($NegativeControl) { $env:GHOZTTY_CONPTY_SYNC_HOLD = '0' }
else { Remove-Item env:GHOZTTY_CONPTY_SYNC_HOLD -ErrorAction SilentlyContinue }
$env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe
[void](Set-GhozttyTestIsolation -Tag 't1763')

# The stub: an Ink-shaped full redraw, at start and on every width change. It
# names itself in its frames so a +read can tell it is the thing on screen.
$stub = Join-Path $root 'ink-stub.ps1'
@'
$e = [char]27
$n = 0
function Frame {
  $script:n++
  $w = [Console]::WindowWidth
  $body = ''
  for ($i = 1; $i -le 12; $i++) { $body += "INKSTUB frame $script:n row $i width $w`r`n" }
  [Console]::Write("$e[?2026h$e[2J$e[3J$e[H$body$e[?2026l")
}
Frame
$last = [Console]::WindowWidth
$deadline = (Get-Date).AddSeconds(90)
while ((Get-Date) -lt $deadline) {
  Start-Sleep -Milliseconds 15
  $w = [Console]::WindowWidth
  if ($w -ne $last) { $last = $w; Frame }
}
'@ | Set-Content -Path $stub -Encoding ASCII

function Get-Shown([string]$log) {
    $out = @()
    foreach ($l in @(Get-Content $log -ErrorAction SilentlyContinue)) {
        if ($l -match 'conpty sync shown how=(\w+) text_rows=(\d+) held_ms=(\d+)') {
            $out += [pscustomobject]@{ How = $Matches[1]; Rows = [int]$Matches[2]; HeldMs = [int]$Matches[3] }
        }
    }
    return , $out
}

function Get-StubParentName {
    $stubProc = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -like "*ink-stub.ps1*" }) | Select-Object -First 1
    if ($null -eq $stubProc) { return $null }
    # The first ghoztty process up the chain created the ConPTY. The agent runs
    # a --command through `cmd /c`, so the stub's direct parent can be cmd.exe.
    $cur = $stubProc
    for ($hop = 0; $hop -lt 4; $hop++) {
        $parent = Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$cur.ParentProcessId)"
        if ($null -eq $parent) { return $null }
        if ($parent.Name -like 'ghoztty*') {
            return [pscustomobject]@{ Name = $parent.Name; Path = $parent.ExecutablePath }
        }
        $cur = $parent
    }
    return $null
}

# One section: launch, let the stub draw, resize N times, read the oracle.
function Invoke-Section([string]$tag, [bool]$persist, [string]$expectParent) {
    $state = Join-Path $root "state-$tag"
    New-Item -ItemType Directory -Force (Join-Path $state 'ghoztty\local-agent-debug') | Out-Null
    $env:LOCALAPPDATA = $state
    $errlog = Join-Path $root "$tag-stderr.log"

    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)
    $persistFlag = if ($persist) { '--session-persistence=true' } else { '--session-persistence=false' }
    # persistence: stated per section - off for A (the app owns the ConPTY),
    # on for B (the agent owns it); each section gets its own LOCALAPPDATA, so
    # B never restores anything.
    $app = Start-OnTestDesktop -Exe $Exe -StdErr $errlog -Arguments @(
        '--config-default-files=false', $persistFlag,
        "--command=powershell.exe -NoProfile -ExecutionPolicy Bypass -File $stub")
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow' -TimeoutMs 20000
    Assert ($top -ne [IntPtr]::Zero) "$tag top-level window appeared"
    if ($top -eq [IntPtr]::Zero) { return $null }
    [void](Set-TestWindowPos -Window ([IntPtr]$top) -X 40 -Y 40 -Width 1000 -Height 700)

    # The stub's first frame is an erasing bracket too: wait for its line, so
    # the resizes below land on a stub that is up and drawing.
    $first = @()
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        $first = Get-Shown $errlog
        if ($first.Count -ge 1) { break }
        Start-Sleep -Milliseconds 300
    }
    Assert ($first.Count -ge 1) "$tag the oracle is live: the stub's first frame was logged ($($first.Count) line(s))"

    $parent = Get-StubParentName
    $parentName = if ($parent) { $parent.Name } else { '<none>' }
    Assert ($null -ne $parent -and $parent.Name -ieq $expectParent -and $parent.Path -like "$repo\zig-out\*") `
        "$tag the stub's ConPTY belongs to $expectParent from zig-out (saw $parentName)"

    $widths = @(1100, 900, 1200, 850, 1050, 950)
    foreach ($w in $widths) {
        [void](Set-TestWindowPos -Window ([IntPtr]$top) -X 40 -Y 40 -Width $w -Height 700)
        Start-Sleep -Milliseconds 700
    }
    # Poll for the lines to reach the redirected stderr.
    $shown = @()
    $want = 1 + $widths.Count
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline) {
        $shown = Get-Shown $errlog
        if ($shown.Count -ge $want) { break }
        Start-Sleep -Milliseconds 300
    }
    Assert (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) "$tag GUI never became visible on the interactive desktop"
    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)
    return , $shown
}

function Score-Section([string]$tag, $shown) {
    if ($null -eq $shown) { return }
    Assert ($shown.Count -ge 5) "$tag every resize produced an erasing redraw to judge ($($shown.Count) logged)"
    $blank = @($shown | Where-Object { $_.Rows -eq 0 })
    $summary = ($shown | ForEach-Object { "$($_.How)/$($_.Rows)/$($_.HeldMs)ms" }) -join ' '
    Write-Host "    shown (how/text_rows/held): $summary"
    if ($NegativeControl) {
        Assert ($blank.Count -gt 0) "$tag NEGATIVE CONTROL: with the hold off, blank frames are shown ($($blank.Count) of $($shown.Count))"
        return
    }
    Assert ($blank.Count -eq 0) "$tag no erasing redraw was ever shown blank ($($blank.Count) of $($shown.Count) blank)"
    $unheld = @($shown | Where-Object { $_.How -eq 'close' })
    Assert ($unheld.Count -eq 0) "$tag every erasing ConPTY bracket was held ($($unheld.Count) shown at the close)"
    $slow = @($shown | Where-Object { $_.HeldMs -gt 200 })
    Assert ($slow.Count -eq 0) "$tag no hold outlived its cap (+50ms timer slack) ($($slow.Count) over 200ms)"
}

$td = New-TestDesktop -Interactive:$Interactive
try {
    Assert-GhozttyPrivateEndpoint -Exe $Exe

    Write-Host '== A: local pane (the app owns the ConPTY)'
    $a = Invoke-Section 'A' $false 'ghoztty.exe'
    Score-Section 'A' $a

    Write-Host '== B: agent-backed pane (ghoztty-agent owns the ConPTY)'
    $b = Invoke-Section 'B' $true 'ghoztty-agent.exe'
    Score-Section 'B' $b

    Complete-TestBody  # T1039: the run reached the end of its body
}
finally {
    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)
    Remove-TestDesktop
    $env:LOCALAPPDATA = $savedLocalAppData
    if ($null -ne $savedAgentBin) { $env:GHOSTTY_LOCAL_AGENT_BIN = $savedAgentBin }
    else { Remove-Item env:GHOSTTY_LOCAL_AGENT_BIN -ErrorAction SilentlyContinue }
    if ($null -ne $savedHold) { $env:GHOZTTY_CONPTY_SYNC_HOLD = $savedHold }
    else { Remove-Item env:GHOZTTY_CONPTY_SYNC_HOLD -ErrorAction SilentlyContinue }
}

# --- stamp (T783) ----------------------------------------------------------
# Only a clean green run, never a negative control.
if ($script:fail -eq 0 -and $script:skipped -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard conpty-sync-hold -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Skipped $script:skipped
