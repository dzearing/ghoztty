# @timing-sensitive - it judges resize pacing against the wall clock, so it runs with nothing beside it (scripts/acceptance-parallel.ps1, T1960).
# T2251 acceptance: at a shell prompt a resize reflows the prompt AS IT
# HAPPENS and never shows it blank; a running program still debounces.
#
# THE CHANGE (Mac a81db68f9, shared core, merged by T2249). Until it, every
# resize waited out the termio thread's trailing debounce (100 ms quiet, 350 ms
# cap - T1835, resize-debounce.ps1), so a divider drag over a prompt reflowed
# the prompt a handful of times, late. Now the IO thread asks
# `Termio.resizePace()` per resize:
#
#   now          - the cursor is at a shell prompt on the primary screen
#                  (OSC 133 marks): apply at once;
#   after_redraw - the last resize cleared the prompt and the shell has not
#                  redrawn it yet: poll every 4 ms, apply once it has;
#   debounce     - a program is running: the old trailing debounce.
#
# And the renderer HOLDS the last frame while a cleared prompt waits for its
# redraw (`Terminal.flags.awaiting_prompt_redraw`), releasing it once the
# shell's output has gone quiet for 15 ms AND the cursor's line shows text
# again - or, if the redraw never comes, at termio's 250 ms cap, which draws
# whatever is there, a blank prompt included.
#
# WHY WINDOWS NEEDS ITS OWN PROOF. Three things sit between that logic and the
# shell here that Mac does not have: ConPTY, which reflows and repaints the
# whole viewport itself on a resize (so the "redraw" is ConPTY's, and arrives
# inside its own erasing brackets - T1763's hold); the session agent, which
# puts a pipe round trip between the resize and the repaint; and the prompt
# marks, which on Windows come from our injected pwsh/cmd integrations (T1757)
# through ConPTY's OSC passthrough. If the marks never arrive the pane silently
# keeps the old debounce; if the repaint is slower than the cap the user sees
# the blank prompt the change exists to remove.
#
# THE ORACLE is the app stating its decisions on the debug build's stderr:
#   `resize pace=<now|after_redraw|debounce>`     each resize, as decided
#   `resize applied cols=.. rows=..`              each resize the terminal took
#   `prompt redraw released by=redraw`            a held frame released by the
#                                                 shell's redraw (the good end)
#   `prompt redraw released by=cap`               released by the 250 ms cap:
#                                                 the blank prompt was drawn
#
# THE CMD WRINKLE, found by this script. conhost's post-resize paint walks the
# viewport row by row, and its first row break ends cmd's input region (`133;I`
# runs to the end of the line, T1757). So in a cmd pane the cursor reads as
# output at an idle prompt and Mac's check put every resize after the first on
# the debounce. On a ConPTY child the PACE also accepts the cursor sitting on
# the prompt's own row (`Termio.conptyPromptRow`); nothing was cleared there,
# so nothing is held. PowerShell's `133;B` keeps the input open through the
# paint and takes Mac's path unchanged.
#
# WHAT IS ASSERTED, per section - cmd and Windows PowerShell, each with the app
# owning the ConPTY and with the session agent owning it:
#   1. the oracle is live and the pane is at a marked prompt: a drag over it
#      decides `now`/`after_redraw` - never `debounce` for PowerShell, mostly
#      not for cmd (see Score-Storm) - and a pane whose marks never arrived
#      scores every resize `debounce` and fails here, loudly;
#   2. LIVE: a divider drag over the prompt is applied far more often than the
#      debounce could - more than  floor(drag_seconds / 0.35) + 2  times per
#      pane, the bound resize-debounce.ps1 holds a running program to;
#   3. NEVER BLANK: no held frame was released by the cap, and for PowerShell
#      at least one was released by the redraw (so "no cap" is not vacuous);
#   4. the same for a window-edge resize storm;
#   5. the prompt, and a line of output above it, are still on screen
#      afterwards (`+read`);
#   6. CONTROL: with a program running in the pane, the same drag decides
#      `debounce` and is applied no more than the bound - the oracle can tell
#      a prompt from a program, and the old pacing still holds for programs.
#
# Runs on the BACKGROUND test desktop (lib\TestDesktop.ps1): posted mouse
# messages and SetWindowPos only, no foreground taken.
#
# -NegativeControl inverts 2's bound and MUST fail.
#
#   powershell -NoProfile -File test\win32\prompt-reflow.ps1
param(
    [string]$Exe,
    [string]$AgentExe,
    [int]$Moves = 40,
    [int]$MoveMs = 25,
    [switch]$NegativeControl,
    [switch]$Interactive
)

# T351: shared kill helpers; drops an inherited $GHOZTTY_IPC_SOCKET.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')

$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not $Exe) { $Exe = Join-Path $repo 'zig-out\bin\ghoztty.exe' }
if (-not $AgentExe) { $AgentExe = Join-Path $repo 'zig-out\bin\ghoztty-agent.exe' }
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

$root = Join-Path $env:TEMP "ghoztty-t2251-reflow-$PID"
New-Item -ItemType Directory -Force $root | Out-Null
$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN
$env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe
[void](Set-GhozttyTestIsolation -Tag 't2251')

# Every pacing line in the log, oldest first, each with its line number so a
# section can take only what came after a mark.
function Get-Pacing([string]$log) {
    $out = @()
    $n = 0
    foreach ($l in @(Get-Content $log -ErrorAction SilentlyContinue)) {
        $n++
        if ($l -match 'resize pace=(\w+)') {
            $out += [pscustomobject]@{ Line = $n; Kind = 'pace'; Value = $Matches[1] }
        } elseif ($l -match 'resize applied cols=(\d+) rows=(\d+)') {
            $out += [pscustomobject]@{ Line = $n; Kind = 'applied'; Value = "$($Matches[1])x$($Matches[2])" }
        } elseif ($l -match 'prompt redraw released by=(\w+)') {
            $out += [pscustomobject]@{ Line = $n; Kind = 'released'; Value = $Matches[1] }
        }
    }
    return , $out
}

function Get-LogMark([string]$log) {
    return @(Get-Content $log -ErrorAction SilentlyContinue).Count
}

# The pacing lines after $mark, once the log has stopped growing (stderr
# reaches the file when the app's buffer flushes, and the cap fires 250 ms
# after the last resize).
function Get-PacingSince([string]$log, [int]$mark) {
    $last = -1
    for ($t = 0; $t -lt 20; $t++) {
        Start-Sleep -Milliseconds 300
        $now = Get-LogMark $log
        if ($now -eq $last) { break }
        $last = $now
    }
    return , @((Get-Pacing $log) | Where-Object { $_.Line -gt $mark })
}

function Get-VisiblePanes([IntPtr]$top) {
    return @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal' | Where-Object Visible)
}

function Get-DividerPoint([IntPtr]$top) {
    $sorted = @(Get-VisiblePanes $top | Sort-Object Left)
    if ($sorted.Count -lt 2) { return $null }
    return [pscustomobject]@{
        X = [int](($sorted[0].Right + $sorted[1].Left) / 2)
        Y = [int](($sorted[0].Top + $sorted[0].Bottom) / 2)
    }
}

# One divider drag of $moves moves, $step px each. Returns the drag seconds.
function Invoke-DividerDrag([IntPtr]$top, [int]$moves, [int]$step, [int]$sleepMs) {
    $pt = Get-DividerPoint $top
    if ($null -eq $pt) { return -1 }
    [void](Send-TestMouse -Window $top -Target $top -X $pt.X -Y $pt.Y -Action down -HoldMs 0)
    Start-Sleep -Milliseconds 60
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    for ($i = 1; $i -le $moves; $i++) {
        [void](Send-TestMouse -Window $top -Target $top -X ($pt.X + $i * $step) -Y $pt.Y -Action move -HoldMs 0)
        if ($sleepMs -gt 0) { Start-Sleep -Milliseconds $sleepMs }
    }
    $sw.Stop()
    [void](Send-TestMouse -Window $top -Target $top -X ($pt.X + $moves * $step) -Y $pt.Y -Action up -HoldMs 0)
    return $sw.Elapsed.TotalSeconds
}

function Read-Pane([string]$name) {
    return (& $Exe +read "--name=$name" --lines=40 2>$null | Out-String)
}

# A prompt is on screen: PowerShell's `PS C:\...>` or cmd's `C:\...>`.
function Test-PromptShown([string]$text) {
    return [bool]($text -match '(?m)^(PS )?[A-Za-z]:\\[^\r\n]*>\s*$')
}

function Wait-Prompt([string]$name, [int]$timeoutSec = 30) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-PromptShown (Read-Pane $name)) { return $true }
        Start-Sleep -Milliseconds 400
    }
    return $false
}

# $holds: whether the shell's prompt is one a resize clears and holds a frame
# for. PowerShell's is (`133;B`: the cursor stays in its input); cmd's is not
# once conhost has painted (`133;I` ends at the first row break - see
# `Termio.conptyPromptRow`), so a cmd pane is paced live with nothing held.
function Score-Storm([string]$tag, [string]$what, $lines, [double]$secs, [bool]$atPrompt, [bool]$holds) {
    $paces = @($lines | Where-Object Kind -eq 'pace')
    $applied = @($lines | Where-Object Kind -eq 'applied')
    $byRedraw = @($lines | Where-Object { $_.Kind -eq 'released' -and $_.Value -eq 'redraw' })
    $byCap = @($lines | Where-Object { $_.Kind -eq 'released' -and $_.Value -eq 'cap' })
    $debounced = @($paces | Where-Object Value -eq 'debounce')
    # Per pane, and both panes resize on every step of either storm.
    $allowed = ([int][math]::Floor($secs / 0.35) + 2) * 2
    $mix = ($paces | Group-Object Value | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ' '
    Write-Host ("    {0}: {1:N0}ms, {2} resize(s) decided [{3}], {4} applied (debounce bound {5}), released redraw={6} cap={7}" -f `
            $what, ($secs * 1000), $paces.Count, $mix, $applied.Count, $allowed, $byRedraw.Count, $byCap.Count)

    Assert ($paces.Count -ge 1) "$tag $what the oracle is live ($($paces.Count) pacing decision(s) logged)"
    if ($atPrompt) {
        # A frame-holding prompt is never debounced. cmd's is paced on its
        # prompt row, and a resize that lands while conhost's paint has the
        # cursor elsewhere on screen finds no prompt there and takes the
        # debounce - the next one applies it at once, so the pace stays live.
        if ($holds) {
            Assert ($debounced.Count -eq 0) "$tag $what over a prompt never decides debounce ($($debounced.Count) of $($paces.Count))"
        } else {
            Assert ($debounced.Count * 2 -lt $paces.Count) "$tag $what over a prompt is mostly decided live ($($debounced.Count) of $($paces.Count) debounced)"
        }
        $live = ($applied.Count -gt $allowed)
        if ($NegativeControl) { $live = -not $live }
        Assert $live "$tag $what over a prompt is applied live: $($applied.Count) resizes, more than the debounce's $allowed"
        Assert ($byCap.Count -eq 0) "$tag $what never shows the prompt blank: no held frame released by the 250ms cap ($($byCap.Count))"
        if ($holds) {
            Assert ($byRedraw.Count -ge 1) "$tag $what held the last frame and released it on the redraw ($($byRedraw.Count) time(s))"
        }
    } else {
        Assert ($debounced.Count -ge 1 -and $debounced.Count -eq $paces.Count) `
            "$tag $what with a program running decides debounce every time ($($debounced.Count) of $($paces.Count))"
        Assert ($applied.Count -ge 1 -and $applied.Count -le $allowed) `
            "$tag $what with a program running is still debounced: $($applied.Count) applied, bound $allowed"
    }
}

function Invoke-Section([string]$tag, [bool]$persist, [string]$shell, [bool]$holds) {
    $state = Join-Path $root "state-$tag"
    New-Item -ItemType Directory -Force (Get-GhozttyAgentStateDir -Root $state) | Out-Null
    $env:LOCALAPPDATA = $state
    $errlog = Join-Path $root "$tag-stderr.log"

    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)
    # Persistence stated per section: off for A (the app owns the ConPTY), on
    # for B (the agent owns it); each section has its own LOCALAPPDATA, so B
    # never restores anything.
    $persistFlag = if ($persist) { '--session-persistence=true' } else { '--session-persistence=false' }
    $app = Start-OnTestDesktop -Exe $Exe -StdErr $errlog -Arguments @(
        '--config-default-files=false', $persistFlag, "--command=$shell")
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow' -TimeoutMs 20000
    Assert ($top -ne [IntPtr]::Zero) "$tag top-level window appeared"
    if ($top -eq [IntPtr]::Zero) { return }
    $top = [IntPtr]$top
    [void](Set-TestWindowPos -Window $top -X 40 -Y 40 -Width 1400 -Height 900)
    Start-Sleep -Milliseconds 800

    & $Exe +split --direction=right --name=reflow-right 2>&1 | Out-Null
    for ($t = 0; $t -lt 40 -and @(Get-VisiblePanes $top).Count -lt 2; $t++) { Start-Sleep -Milliseconds 250 }
    Assert (@(Get-VisiblePanes $top).Count -eq 2) "$tag split produced 2 panes"
    $prompt = Wait-Prompt 'reflow-right'
    Assert $prompt "$tag the new pane reached its shell prompt"
    if (-not $prompt) { return }
    Start-Sleep -Milliseconds 1500   # let the left pane's shell settle at its prompt too

    # A line of output above the prompt, which no resize may take with it.
    & $Exe +send-keys --target=reflow-right "echo T2251-MARK`n" 2>&1 | Out-Null
    $marked = $false
    for ($t = 0; $t -lt 20 -and -not $marked; $t++) {
        Start-Sleep -Milliseconds 300
        $text = Read-Pane 'reflow-right'
        $marked = ($text -match '(?m)^T2251-MARK\s*$') -and (Test-PromptShown $text)
    }
    Assert $marked "$tag the marker line printed and the shell is back at its prompt"
    Start-Sleep -Milliseconds 800

    # ---- 1-3. divider drag over the prompt ------------------------------
    $mark = Get-LogMark $errlog
    $secs = Invoke-DividerDrag $top $Moves -8 0
    Score-Storm $tag 'divider drag' (Get-PacingSince $errlog $mark) $secs $true $holds

    # ---- 4. window-edge resize storm over the prompt --------------------
    $mark = Get-LogMark $errlog
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    for ($k = 1; $k -le $Moves; $k++) {
        [void](Set-TestWindowPos -Window $top -X 40 -Y 40 -Width (1400 - $k * 8) -Height 900)
        Start-Sleep -Milliseconds $MoveMs
    }
    $sw.Stop()
    Score-Storm $tag 'window resize' (Get-PacingSince $errlog $mark) $sw.Elapsed.TotalSeconds $true $holds

    # ---- 5. the prompt is still there -----------------------------------
    $after = Read-Pane 'reflow-right'
    Assert (Test-PromptShown $after) "$tag the prompt is on screen after the resizes"
    Assert ($after -match '(?m)^T2251-MARK\s*$') "$tag the output above the prompt survived the resizes"

    # ---- 6. control: a running program still debounces ------------------
    # Every pane, so every resize the drag makes lands on a running program:
    # the leaf ids out of `+list --json` (the first pane has no name).
    # ping runs the same in cmd and PowerShell, and prints a row a second.
    $loop = 'ping -n 60 127.0.0.1'
    $listJson = (& $Exe +list --json 2>$null | Out-String)
    $ids = @([regex]::Matches($listJson, '"id"\s*:\s*"([0-9A-Fa-f-]{36})"') |
        ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    Assert ($ids.Count -ge 2) "$tag +list --json names both panes ($($ids.Count) pane id(s))"
    foreach ($id in $ids) { & $Exe +send-keys "--target=$id" "$loop`n" 2>&1 | Out-Null }
    Start-Sleep -Milliseconds 1500
    $mark = Get-LogMark $errlog
    $secs = Invoke-DividerDrag $top $Moves 8 0
    Score-Storm $tag 'control drag' (Get-PacingSince $errlog $mark) $secs $false $false

    Assert (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) "$tag GUI never became visible on the interactive desktop"
    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)
}

$td = New-TestDesktop -Interactive:$Interactive
try {
    Assert-GhozttyPrivateEndpoint -Exe $Exe

    Write-Host '== A: cmd, local pane (the app owns the ConPTY)'
    Invoke-Section 'A' $false 'cmd.exe' $false

    Write-Host '== B: Windows PowerShell, local pane'
    Invoke-Section 'B' $false 'powershell.exe' $true

    Write-Host '== C: cmd, agent-backed pane (ghoztty-agent owns the ConPTY)'
    Invoke-Section 'C' $true 'cmd.exe' $false

    Write-Host '== D: Windows PowerShell, agent-backed pane'
    Invoke-Section 'D' $true 'powershell.exe' $true

    Complete-TestBody  # T1039: the run reached the end of its body
}
finally {
    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)
    Remove-TestDesktop
    $env:LOCALAPPDATA = $savedLocalAppData
    if ($null -ne $savedAgentBin) { $env:GHOSTTY_LOCAL_AGENT_BIN = $savedAgentBin }
    else { Remove-Item env:GHOSTTY_LOCAL_AGENT_BIN -ErrorAction SilentlyContinue }
}

# --- stamp (T783) ----------------------------------------------------------
# Only a clean green run, never a negative control.
if ($script:fail -eq 0 -and $script:skipped -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard prompt-reflow -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Skipped $script:skipped
