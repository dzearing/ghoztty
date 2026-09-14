# Activity Monitor "Window / Pane" column acceptance (T709).
#
# Mac's activity monitor labels every process row with the Ghoztty pane that
# spawned it (ab79f37c4) and assigns those labels per window as a GROUP so two
# panes cannot render the same string (2964c8859). The win32 panel had neither:
# twenty agent sessions rendered as twenty identical rows - Claude Code reports
# its version string as its accounting name - with nothing on screen saying
# which pane to go and close.
#
# The ARITHMETIC is unit-tested in the `none` lane (`activity_panes.zig`): the
# two attribution passes, the ppid cycle, the missing parent, the group naming
# rule and the label fallbacks. What only the RUNNING APP can answer, and what
# this script asserts:
#
#   A. attribution runs against the LIVE window list at all - the panel's own
#      state line carries `panes=N attributed=M` with both above zero, which is
#      only reachable if the collector really walked `App.windows` and really
#      read each surface's shell pid;
#   B. the label is the WINDOW's name: `+rename --title=` renames it and the
#      panel's pane line says so on the next poll. The label chain is pure and
#      unit-tested; that it is fed the window the user actually renamed is not;
#   C. two panes in one tab get DISTINCT labels. This is the 2964c8859 defect
#      reproduced against real siblings: both shells report the same cwd as
#      their title, so the title cannot separate them and the positional
#      fallback is what must appear. A unit test can only assert the rule on
#      titles it invented; this asserts it on the titles two real shells report;
#   D. a process started INSIDE a pane is attributed to it - `attributed` rises
#      when a `ping` is started in the pane and falls when it is stopped. That
#      is the second pass walking a real ppid chain, which no pure test can
#      claim: the chain is built by Windows, not by the fixture;
#   E. the column is really in the panel and is reachable: the header cursor
#      walks onto a column the panel NAMES `pane`, and Space sorts the table by
#      it (`sort=pane/asc`).
#
# NOT asserted here, on purpose: that the spawned-only filter now rides on
# attribution (`Filter.any_attributed`). This run launches with
# `--session-persistence=false`, so every pane shell is a child of the app and
# the root BFS covers the same rows - the two halves are indistinguishable from
# outside. The case that separates them is session-persistence ON, where the
# shells hang off `ghoztty-agent` instead; it is unit-tested
# (`markSpawned: an attributed row is spawned even with no path to the root`)
# and left out of here rather than claimed by a run that cannot see it.
#
# ALSO NOT asserted here: the per-core %CPU change (the same task's other half).
# It is one pure function with one call site - `activity_rows.formatCpu`, read
# only by the painter - and the cell is GDI text with nothing to read back, so
# the claim is made where it can be checked: the `formatCpu` unit test pins the
# exact 18-core reading the divide used to destroy.
#
# ORACLE. Two log lines the panel emits, both derivations of the same state the
# painter walks rather than restatements of the assertions:
#
#   activity monitor: source=Local total=312 shown=7 ... panes=2 attributed=5
#   activity monitor: panes source=Local n=2 [31160]="t709 > pane 1" ...
#
# The second is written only when the pane SET changes, which is also what makes
# B and C readable: a line appearing is itself the evidence that something moved.
#
# CONTROLS. A positive control (ctrl+shift+p opening the palette) runs first, so
# a broken injection aborts instead of reading as a T709 regression.
# `-NegativeControl` inverts C - the two pane labels are asserted to be the SAME
# string, which is exactly the defect - and that run MUST fail.
#
# T211/T217: runs on a BACKGROUND Win32 desktop and asserts at the end that it
# never took the user's foreground.
#
#   powershell -NoProfile -File test\win32\activity-pane-column.ps1
#
# Only touches ghoztty processes running from this repo's zig-out.
param([string]$ExePath, [switch]$NegativeControl)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }

# Isolate the IPC endpoint (inherited through CreateProcessW).
$env:GHOZTTY_PIPE_SUFFIX = "-t709$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$errlog = Join-Path $env:TEMP "ghoztty-t709-stderr-$PID.log"
Remove-Item $errlog -ErrorAction SilentlyContinue

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Stop-RepoProcesses {
    [void](Stop-RepoGhoztty -Exe $exe -SettleMs 500)
}

function Run-CliArgs($argv, [int]$timeoutSec = 15) {
    $r = Invoke-OnTestDesktop -Exe $exe -Arguments $argv -TimeoutSec $timeoutSec
    return [pscustomobject]@{
        Code = $(if ($r.TimedOut) { $null } else { $r.ExitCode })
        Text = $(if ($null -ne $r.Output) { $r.Output } else { '' })
    }
}

# The panel's most recent state line. `Panes`/`Attributed` are the T709 fields;
# they are matched as their own group so an older line (a build without them)
# reads as $null rather than as zero.
function Get-PanelState {
    if (-not (Test-Path $errlog)) { return $null }
    $pat = 'activity monitor: source=(\S+) total=(\d+) shown=(\d+) needle="([^"]*)" show_all=(\w+) sort=(\w+)/(\w+) selected=(\d+) root=(-?\d+) panes=(\d+) attributed=(\d+)'
    $m = @(Select-String -Path $errlog -Pattern $pat) | Select-Object -Last 1
    if (-not $m) { return $null }
    $g = $m.Matches[0].Groups
    return [pscustomobject]@{
        Shown      = [int]$g[3].Value
        Needle     = $g[4].Value
        ShowAll    = ($g[5].Value -eq 'true')
        SortKey    = $g[6].Value
        SortDir    = $g[7].Value
        Panes      = [int]$g[10].Value
        Attributed = [int]$g[11].Value
    }
}

function Count-PanelLines {
    if (-not (Test-Path $errlog)) { return 0 }
    return @(Select-String -Path $errlog -Pattern 'activity monitor: source=').Count
}

# Wait for a state line newer than $since, then return it.
function Wait-PanelState([int]$since, [int]$TimeoutMs = 9000) {
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        if ((Count-PanelLines) -gt $since) { return Get-PanelState }
        Start-Sleep -Milliseconds 200
    }
    return Get-PanelState
}

# Wait until a state line satisfies $Test, or give up and return the last one.
# The table is LIVE: a process reaches it on the first poll AFTER it exists, so
# the state line right after an action can still predate the action.
function Wait-PanelWhere([scriptblock]$Test, [int]$TimeoutMs = 15000) {
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    $st = $null
    while ((Get-Date) -lt $deadline) {
        $st = Get-PanelState
        if ($st -and (& $Test $st)) { return $st }
        Start-Sleep -Milliseconds 250
    }
    return $st
}

# Every pane label from the panel's most recent `panes` line, in order.
function Get-PaneLabels {
    if (-not (Test-Path $errlog)) { return @() }
    $m = @(Select-String -Path $errlog -Pattern 'activity monitor: panes source=\S+ n=(\d+)(.*)$') |
        Select-Object -Last 1
    if (-not $m) { return @() }
    $rest = $m.Matches[0].Groups[2].Value
    $out = @()
    foreach ($lm in [regex]::Matches($rest, '\[(-?\d+)\]="([^"]*)"')) {
        $out += , [pscustomobject]@{ Pid = [int64]$lm.Groups[1].Value; Label = $lm.Groups[2].Value }
    }
    return , $out
}

function Count-PaneLines {
    if (-not (Test-Path $errlog)) { return 0 }
    return @(Select-String -Path $errlog -Pattern 'activity monitor: panes source=').Count
}

# Wait for a NEW `panes` line (the set changed), then return its labels.
function Wait-PaneLabels([int]$since, [int]$TimeoutMs = 15000) {
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        if ((Count-PaneLines) -gt $since) { return Get-PaneLabels }
        Start-Sleep -Milliseconds 250
    }
    return Get-PaneLabels
}

function Get-HeaderCursor {
    if (-not (Test-Path $errlog)) { return $null }
    $m = @(Select-String -Path $errlog -Pattern 'activity monitor: header cursor (\w+)') | Select-Object -Last 1
    if (-not $m) { return $null }
    return $m.Matches[0].Groups[1].Value
}

function Leaves-Of($node) {
    if ($null -eq $node) { return @() }
    if ($node.type -eq 'leaf') { return @($node.terminal) }
    if ($node.type -eq 'split') { return @(Leaves-Of $node.left) + @(Leaves-Of $node.right) }
    return @()
}

Write-Host 'T709 activity monitor Window / Pane column'
if ($NegativeControl) { Write-Host 'NEGATIVE CONTROL: section C is inverted; this run MUST fail.' }
Stop-RepoProcesses
New-TestDesktop | Out-Null

$script:app = $null
try {
    $script:app = Start-OnTestDesktop -Exe $exe `
        -Arguments @('--session-persistence=false') -StdErr $errlog
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: top window not found'; exit 1 }
    $pane = Get-TestChildWindow -Window $top -Class 'GhozttyTerminal'
    if ($pane -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: no pane'; exit 1 }

    # The window's IPC name, so `+rename` and `+split` address THIS window
    # rather than guessing at `window-1`.
    $list = Run-CliArgs @('+list', '--json') 20
    if ($list.Code -ne 0) { Write-Host "SETUP FAIL: +list exit $($list.Code)"; exit 1 }
    $tree = $list.Text | ConvertFrom-Json
    # `@(...)` AROUND the whole if, not inside each branch: PS 5.1 unrolls a
    # one-element array on its way out of an `if` expression, and `.Count` on the
    # bare PSCustomObject that lands is $null - which compares less than 1 and
    # reads as "no windows" against a perfectly good reply.
    $windows = @(if ($null -ne $tree.data) { $tree.data.windows } else { $tree.windows })
    if ($windows.Count -lt 1) { Write-Host 'SETUP FAIL: +list reported no windows'; exit 1 }
    $winId = $windows[0].target
    # `+list --json` names a tab's tree `splits`.
    $leaf0 = @(Leaves-Of $windows[0].tabs[0].splits)[0]
    if ($null -eq $leaf0) { Write-Host 'SETUP FAIL: +list reported no pane'; exit 1 }
    Write-Host "  window=$winId pane=$($leaf0.id) shell pid=$($leaf0.pid)"

    # --- positive control + the panel ------------------------------------
    $popup = [IntPtr]::Zero
    foreach ($try in 1..3) {
        if (-not (Send-TestKeys -Window $top -Target $pane -Modifiers ctrl, shift -Key P)) { continue }
        $popup = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyTerminal' -TimeoutMs 5000
        if ($popup -ne [IntPtr]::Zero) { break }
    }
    if ($popup -eq [IntPtr]::Zero) {
        Write-Host 'ABORT: positive control failed (palette never opened) - injection broken, not a T709 verdict'
        exit 1
    }
    $pedit = Find-TestWindowEx -Parent $popup -Class 'EDIT'
    if ($pedit -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: palette edit not found'; exit 1 }
    Send-TestControlText -Control $pedit -Text 'ACTIVITY MONITOR' | Out-Null
    Send-TestControlKey -Control $pedit -Key Enter | Out-Null
    Start-Sleep -Milliseconds 900

    $panel = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyActivityMonitor' -TimeoutMs 8000
    Assert ($panel -ne [IntPtr]::Zero) 'the Activity Monitor panel opened'
    if ($panel -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: no panel'; exit 1 }
    $filterEdit = Find-TestWindowEx -Parent $panel -Class 'EDIT'
    if ($filterEdit -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: no filter field'; exit 1 }

    Write-Host ''
    Write-Host 'A. attribution runs against the live window list'
    $st = Wait-PanelState 0
    Assert ($null -ne $st) 'the panel logged a state line carrying panes= and attributed='
    if ($null -eq $st) { throw 'no state line to read' }
    Assert ($st.Shown -ge 1) "the table populated (shown=$($st.Shown))"
    Assert ($st.Panes -ge 1) "the live window list produced at least one attributing pane (panes=$($st.Panes))"
    Assert ($st.Attributed -ge 1) "at least one row was attributed to a pane (attributed=$($st.Attributed))"

    $labels = Get-PaneLabels
    Assert ($labels.Count -ge 1) "the panel NAMED its panes ($($labels.Count) named)"
    if ($labels.Count -ge 1) {
        Assert ($labels[0].Pid -eq [int64]$leaf0.pid) `
            "the named pane carries the shell pid +list reports ($($labels[0].Pid) vs $($leaf0.pid))"
        Assert ($labels[0].Label.Length -gt 0) "the label is not empty (`"$($labels[0].Label)`")"
    }

    Write-Host ''
    Write-Host 'B. the label is the window the user renamed'
    $sincePanes = Count-PaneLines
    $rn = Run-CliArgs @('+rename', "--target=$winId", '--title=t709win') 20
    Assert ($rn.Code -eq 0) "+rename pinned the window title (exit $($rn.Code))"
    $labels = Wait-PaneLabels $sincePanes
    Assert ($labels.Count -ge 1) 'the panel re-named its panes after the rename'
    if ($labels.Count -ge 1) {
        Assert ($labels[0].Label -eq 't709win') `
            "the pane label follows the window's pinned title (`"$($labels[0].Label)`")"
    }

    Write-Host ''
    Write-Host 'C. two panes in one tab get DISTINCT labels'
    $sincePanes = Count-PaneLines
    $sp = Run-CliArgs @('+split', "--pane=$($leaf0.id)", '--direction=right') 25
    Assert ($sp.Code -eq 0) "+split created a second pane (exit $($sp.Code))"
    $labels = Wait-PaneLabels $sincePanes
    Assert ($labels.Count -eq 2) "the panel sees both panes (n=$($labels.Count))"
    if ($labels.Count -eq 2) {
        $a = $labels[0].Label
        $b = $labels[1].Label
        Write-Host "  labels: `"$a`" / `"$b`""
        if ($NegativeControl) {
            # The 2964c8859 defect, asserted as if it were correct. This must fail.
            Assert ($a -eq $b) "NEGATIVE: the two panes render the SAME label (`"$a`")"
        } else {
            Assert ($a -ne $b) "the two panes render different labels (`"$a`" vs `"$b`")"
        }
        Assert ($a.StartsWith('t709win')) "both labels are rooted in the window's name (`"$a`")"
        Assert ($b.StartsWith('t709win')) "both labels are rooted in the window's name (`"$b`")"
        Assert (($labels[0].Pid -ne $labels[1].Pid) -and $labels[1].Pid -gt 0) `
            "each pane carries its own shell pid ($($labels[0].Pid) / $($labels[1].Pid))"
    }

    Write-Host ''
    Write-Host 'D. a process started inside a pane is attributed to it'
    # Narrow the table to `ping` first, so the row count is a claim about the
    # throwaway and not about the box. `ping -n 600 127.0.0.1` is a loopback
    # throwaway with no child process of its own - nothing the box needs.
    $before = Count-PanelLines
    Set-TestControlText -Control $filterEdit -Text 'ping' | Out-Null
    $st = Wait-PanelState $before
    Assert ($null -ne $st -and $st.Shown -eq 0) `
        "nothing named ping is in the ghoztty tree yet (shown=$(if ($st) { $st.Shown } else { 'none' }))"
    $baseline = if ($st) { $st.Attributed } else { 0 }

    $sk = Run-CliArgs @('+send-keys', "--target=$($leaf0.id)",
        'ping', 'Space', '-n', 'Space', '600', 'Space', '127.0.0.1', 'Enter') 20
    Assert ($sk.Code -eq 0) "+send-keys started the throwaway in the pane (exit $($sk.Code))"

    $st = Wait-PanelWhere { param($s) $s.Shown -ge 1 -and $s.Attributed -gt $baseline } 20000
    Assert ($null -ne $st -and $st.Shown -ge 1) `
        "the pane's child reached the table (shown=$(if ($st) { $st.Shown } else { 'none' }))"
    Assert ($null -ne $st -and $st.Attributed -gt $baseline) `
        "attribution walked the ppid chain to it (attributed $baseline -> $(if ($st) { $st.Attributed } else { '?' }))"
    $peak = if ($st) { $st.Attributed } else { 0 }

    # And it goes away again: an attribution that only ever counts up would pass
    # the assertion above on a leak.
    # `C-c`, the notation `+send-keys` actually parses (`src/cli/send_keys.zig`
    # :194) - `ctrl+c` is not a chord it knows and arrives as five characters of
    # text, which stops nothing.
    $sk = Run-CliArgs @('+send-keys', "--target=$($leaf0.id)", 'C-c') 20
    Assert ($sk.Code -eq 0) "+send-keys sent C-c to the pane (exit $($sk.Code))"
    $st = Wait-PanelWhere { param($s) $s.Shown -eq 0 } 20000
    Assert ($null -ne $st -and $st.Shown -eq 0) `
        "stopping it takes the row away again (shown=$(if ($st) { $st.Shown } else { 'none' }))"
    Assert ($null -ne $st -and $st.Attributed -lt $peak) `
        "and the attributed count falls with it ($peak -> $(if ($st) { $st.Attributed } else { '?' }))"

    Write-Host ''
    Write-Host 'E. the column is in the panel and the keyboard reaches it'
    $before = Count-PanelLines
    Set-TestControlText -Control $filterEdit -Text '' | Out-Null
    Wait-PanelState $before | Out-Null

    # Onto the table: Tab walks filter -> Show all -> New Process... -> table
    # (Kill is hidden with no selection). Then Right walks the header cursor.
    foreach ($i in 1..3) { Send-TestKeys -Window $panel -Key Tab | Out-Null; Start-Sleep -Milliseconds 120 }
    $seen = @()
    foreach ($i in 1..6) {
        Send-TestKeys -Window $panel -Key Right | Out-Null
        Start-Sleep -Milliseconds 180
        $c = Get-HeaderCursor
        if ($c) { $seen += $c }
        if ($c -eq 'pane') { break }
    }
    Assert ($seen -contains 'pane') "the header cursor reaches a column the panel names 'pane' (saw: $($seen -join ' '))"

    $before = Count-PanelLines
    Send-TestKeys -Window $panel -Key Space | Out-Null
    $st = Wait-PanelWhere { param($s) $s.SortKey -eq 'pane' } 8000
    Assert ($null -ne $st -and $st.SortKey -eq 'pane') `
        "Space on that column sorts the table by it (sort=$(if ($st) { "$($st.SortKey)/$($st.SortDir)" } else { 'none' }))"

    Assert (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) 'the run never took the interactive desktop'
} catch {
    Write-Host "FAIL  harness error: $_" -ForegroundColor Red
    $script:fail++
} finally {
    Stop-RepoProcesses
    Remove-TestDesktop
}

# --- stamp (T783) ----------------------------------------------------------
Complete-TestBody  # T1039: before the stamp, which is a child process reading this run's state
if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard activity-pane-column -Repo $repo 2>&1 | ForEach-Object { Write-Host "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Label 'activity-pane-column' -MinPass 18
