# T3213 acceptance: blades a user folded by hand are still blades after the
# app quits the way the in-app updater quits it and relaunches SEVERAL windows,
# the folded one among the ones paced in behind the first, maximized.
#
# THE CLAIM. session-blades.ps1 (T3126) proves a collapse written into the
# manifest comes back in a one-window relaunch. The 1.55.3 update the user
# reported (T3208) differed from that in every dimension that suite never
# touches: the collapse was a real divider drag, the quit was the updater's
# (`applyStagedUpdate` -> PostQuitMessage -> `App.terminate` ->
# `syncSessionLayout(.fresh)`), and the relaunch restored THREE windows, the
# last-focused first and the rest paced in behind it, maximized. This script
# makes every one of those the way the user does:
#
#   setup) three windows: the startup window, `wb` (P | s1 | v, where v is a
#      VIEWER pane - a term|viewer row) and `wc`. `wb` is maximized with the
#      real WM_SYSCOMMAND, then `wc` is focused last, so a relaunch builds
#      `wc` first and paces `wb` in behind it
#      A fourth pane x is stashed first - the pane sidebar's minimize button
#      runs the same `Window.stashPane` as `+stash` - so the folded row's
#      saved leaf positions count a stashed pane too
#   A) a REAL divider drag (pointer down / move / up on the test desktop)
#      folds s1 and v into blades: one pane on show in `wb`
#   B) the collapse lands in the manifest (`pane_stack.rows`) within the save
#      debounce - by the app's own writer, nothing patched
#   C) the app quits through the SAME path the updater takes: the `quit`
#      binding action (`App.performAction(.quit)` sets `quit_requested` and
#      posts WM_QUIT exactly as `applyStagedUpdate` does) - not a window
#      close, which would end the window's sessions. The process exits on its
#      own and the manifest it leaves still carries the collapse
#   D) the relaunch brings all three windows back, `wb` paced (the log names
#      two paced windows) and maximized, and in `wb` x is still stashed, s1 and v are blades, P is
#      the pane on show and holds the caret, no blade holds it
#   E) still true a few seconds later, once the pacer has finished and the
#      maximized layout has settled (a late layout or a focus landing on a
#      blade would bring it back out)
#
# -NegativeControl skips the drag: claim D must then fail (every pane on
# show), proving the harness can tell a restored blade from no blade.
#
# Hermetic: per-run LOCALAPPDATA, per-run agent binary override, a private IPC
# pipe suffix, and it only ever kills ghoztty processes launched from this
# repo's zig-out. Runs on the BACKGROUND test desktop.
#
#   powershell -NoProfile -File test\win32\session-blades-update.ps1
param(
    [string]$ExePath,
    # The build the relaunch runs, when it is not the one that quit - the
    # update's own shape: one version saves, the next restores (T3213 ran the
    # 1.55.2 -> 1.55.3 pair this way).
    [string]$RelaunchExePath,
    [string]$AgentExe,
    # T3216: the restore runs BESIDE A LOCAL-AGENT HANDOFF, the one thing the
    # user's 1.55.3 update did that the plain run does not ("agent upgrade
    # check: stale, but the agent is replacing itself without losing any
    # session"). The agent runs from a renamed copy (`ghoztty-agent.exe.bak`,
    # the shape a delivery leaves), and a newer build lands under the canonical
    # name just before the relaunch, so the agent hands off while the relaunch
    # is restoring and pacing its windows. Same fixture as agent-handoff.ps1:
    # one tree cannot make two build stamps, so the handoff is FORCED.
    [switch]$AgentHandoff,
    [switch]$NegativeControl,
    [switch]$Interactive
)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }
$agent = Join-Path $repo 'zig-out\bin\ghoztty-agent.exe'
if ($AgentExe) { $agent = $AgentExe }

$script:pass = 0
$script:fail = 0
$root = Join-Path $env:TEMP "ghoztty-session-blades-update-$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\ChromeGeometry.ps1')

function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}
function Say($m) { Write-Host $m }

$agentDir = Join-Path $root 'agentdir'
$runningAgent = Join-Path $agentDir 'ghoztty-agent.exe.bak'
$canonicalAgent = Join-Path $agentDir 'ghoztty-agent.exe'

# The handoff arm's agents run from the per-run directory, so they are matched
# by ExecutablePath under it - never by name, which would reach the user's.
function Get-RunAgentProcs {
    $prefix = $agentDir.TrimEnd('\') + '\'
    # The per-session `--pty-host` holders (T905) run from the same image and
    # outlive a handoff by design; they are not agents.
    return @(Get-CimInstance Win32_Process -Filter "Name LIKE 'ghoztty-agent%'" -ErrorAction SilentlyContinue |
            Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -and
                [string]$_.CommandLine -notmatch '--pty-host' })
}

# The app still holds its stderr log open for writing.
function Read-SharedText([string]$path) {
    if (-not (Test-Path $path)) { return '' }
    try {
        $fs = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
        try { return (New-Object System.IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() }
    } catch { return '' }
}

function Stop-RepoInstances {
    [void](Stop-RepoGhoztty -Exe $exe -SettleMs 700)
    if ($RelaunchExePath) { [void](Stop-RepoGhoztty -Exe $RelaunchExePath -SettleMs 700) }
    if ($AgentHandoff) {
        foreach ($p in @(Get-RunAgentProcs)) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    }
}

# Persistence ON: the manifest restore path is the subject. The quit chord is
# bound to the `quit` action, the updater's own exit path; no confirmation, so
# the quit is never held by a dialog nobody on the test desktop can answer.
$quitKey = 'F9'
$appArgs = @('--config-default-files=false', '--session-persistence=true', '--macos-pane-style=flat',
    '--confirm-close-surface=false', "--keybind=ctrl+shift+f9=quit")

function Start-App([string]$StdErr, [string]$With = $exe) {
    $app = Start-OnTestDesktop -Exe $With -Arguments $appArgs -KeepWindowPlacement -StdErr $StdErr
    $t = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($t -eq [IntPtr]::Zero) { Write-TestAssertedNothing -Reason 'the app never opened a GhozttyWindow' }
    $script:app = $app
    return $t
}

function Get-AppWindows {
    return @(Get-TestWindows -ProcessId $script:app.Pid -Class 'GhozttyWindow' | Where-Object Visible)
}

function Get-TermPanes([IntPtr]$top) {
    return @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal')
}
function Get-VisiblePanes([IntPtr]$top) {
    return @(Get-TermPanes $top | Where-Object Visible | Sort-Object Left)
}

# The window holding the P | s1 | v row: the only one with two terminals.
function Find-BladeWindow([int]$timeoutSec = 30) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    do {
        foreach ($w in @(Get-AppWindows)) {
            $h = [IntPtr]$w.Hwnd
            if (@(Get-TermPanes $h).Count -ge 2) { return $h }
        }
        Start-Sleep -Milliseconds 400
    } while ((Get-Date) -lt $deadline)
    return [IntPtr]::Zero
}

function Wait-Shown([IntPtr]$top, [int]$n, [int]$timeoutSec = 20) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    do {
        $v = @(Get-VisiblePanes $top)
        if ($v.Count -eq $n) { return $v }
        Start-Sleep -Milliseconds 300
    } while ((Get-Date) -lt $deadline)
    return @(Get-VisiblePanes $top)
}

# `wb`'s leaves from `+list --json`, as Name / Viewer / Focused / Minimized.
function Get-BladeLeaves {
    $raw = (& $exe +list --json 2>$null) -join "`n"
    $out = New-Object System.Collections.ArrayList
    try { $doc = $raw | ConvertFrom-Json } catch { return }
    $walk = {
        param($node)
        if ($null -eq $node) { return }
        if ($node.type -eq 'leaf') {
            $t = $node.terminal
            [void]$out.Add([pscustomobject]@{
                    Name = [string]$t.name; Viewer = ($t.type -eq 'viewer')
                    Focused = [bool]$t.focused; Minimized = ($t.minimized -eq $true); Stashed = ($t.stashed -eq $true)
                })
        } else {
            & $walk $node.left
            & $walk $node.right
        }
    }
    $doc.data.windows | Where-Object { $_.target -eq 'wb' } | ForEach-Object { $_.tabs | ForEach-Object { & $walk $_.splits } }
    return $out.ToArray()
}

function Get-WindowCount {
    $raw = (& $exe +list --json 2>$null) -join "`n"
    try { return @(($raw | ConvertFrom-Json).data.windows).Count } catch { return 0 }
}

function Wait-BladeLeaves([int]$timeoutSec = 30) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    do {
        $leaves = @(Get-BladeLeaves)
        if ($leaves.Count -eq 4) { return $leaves }
        Start-Sleep -Milliseconds 400
    } while ((Get-Date) -lt $deadline)
    return @(Get-BladeLeaves)
}

function Format-Leaves($leaves) {
    return (($leaves | ForEach-Object { "$(if ($_.Name -and $_.Name -notmatch '^[0-9A-Fa-f-]{36}$') { $_.Name } elseif ($_.Viewer) { 'v' } else { 'P' })$(if ($_.Minimized) { '[min]' })$(if ($_.Stashed) { '[stash]' })$(if ($_.Focused) { '*' })" }) -join ' ')
}

# s1 and v blades, P on show with the caret.
function Assert-Blades([string]$claim, [IntPtr]$top) {
    $leaves = @(Wait-BladeLeaves)
    $shown = @(Wait-Shown $top 1 8)
    Say ("      wb +list: {0}; {1} terminal HWND(s) visible" -f (Format-Leaves $leaves), $shown.Count)
    Assert ($leaves.Count -eq 4) "${claim}: wb came back with its four panes, the stashed one included (got $($leaves.Count))"
    $x = @($leaves | Where-Object { $_.Name -eq 'x' })
    Assert ($x.Count -eq 1 -and $x[0].Stashed -and -not $x[0].Focused) "${claim}: x is still stashed - the pane sidebar's minimize survived too"
    $s1 = @($leaves | Where-Object { $_.Name -eq 's1' })
    $v = @($leaves | Where-Object Viewer)
    $p = @($leaves | Where-Object { -not $_.Viewer -and $_.Name -ne 's1' -and $_.Name -ne 'x' })
    Assert ($s1.Count -eq 1 -and $s1[0].Minimized) "${claim}: s1 (a terminal) is still a blade"
    Assert ($v.Count -eq 1 -and $v[0].Minimized) "${claim}: v (the viewer) is still a blade - the term|viewer row"
    Assert ($p.Count -eq 1 -and -not $p[0].Minimized) "${claim}: P is the pane on show"
    Assert ($p.Count -eq 1 -and $p[0].Focused) "${claim}: P holds the caret"
    Assert (@($leaves | Where-Object { $_.Minimized -and $_.Focused }).Count -eq 0) "${claim}: no blade holds the caret"
    Assert ($shown.Count -eq 1) "${claim}: exactly one terminal HWND is on show in wb (got $($shown.Count))"
}

function Read-Manifest { if (Test-Path $script:manifest) { [System.IO.File]::ReadAllText($script:manifest) } else { '' } }
# A collapsed row as the app writes it: a non-empty `rows` list.
$rowsRe = '"pane_stack"\s*:\s*\{\s*"rows"\s*:\s*\[\s*\{\s*"leaves"'

# -----------------------------------------------------------------------------

$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN
$savedPipe = $env:GHOZTTY_PIPE_SUFFIX
$env:GHOZTTY_PIPE_SUFFIX = "-bladesupd$PID"

Stop-RepoInstances
New-Item -ItemType Directory -Force $root | Out-Null
$tmp = Join-Path $root 'app'
New-Item -ItemType Directory -Force (Get-GhozttyAgentStateDir -Root $tmp) | Out-Null
$script:manifest = Get-GhozttySessionLayoutPath -Root $tmp
$env:LOCALAPPDATA = $tmp
$env:GHOSTTY_LOCAL_AGENT_BIN = $agent
$savedForce = $env:GHOZTTY_AGENT_HANDOFF_FORCE
$savedInterval = $env:GHOZTTY_AGENT_HANDOFF_INTERVAL_MS
$savedPace = $env:GHOZTTY_RESTORE_PACE_MS
if ($AgentHandoff) {
    # The canonical name is deliberately NOT there yet: it lands just before the
    # relaunch (D), so nothing hands off while the fold is being made.
    New-Item -ItemType Directory -Force $agentDir | Out-Null
    Copy-Item -LiteralPath $agent -Destination $runningAgent -Force
    Remove-Item -LiteralPath $canonicalAgent -Force -ErrorAction SilentlyContinue
    $env:GHOSTTY_LOCAL_AGENT_BIN = $runningAgent
    $env:GHOZTTY_AGENT_HANDOFF_FORCE = '1'
    $env:GHOZTTY_AGENT_HANDOFF_INTERVAL_MS = '1000'
    # Debug-build seam (T3216): 2.5 s between paced windows, so the handoff
    # (1 s supervisor tick) lands INSIDE the paced restore on every run rather
    # than racing a ~0.5 s window and missing it one run in two.
    $env:GHOZTTY_RESTORE_PACE_MS = '2500'
}
$doc = Join-Path $root 'blade-viewer.md'
Set-Content -Path $doc -Value "# blade viewer`n`nThe viewer pane of the T3213 row." -Encoding ascii

Reset-TestBody
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    Assert (Test-Path $exe) 'ghoztty exe exists in zig-out'
    Assert (Test-Path $agent) 'ghoztty-agent exe exists in zig-out'
    [void](Assert-GhozttyIsolatedBuild -Exe $exe)
    if ($NegativeControl) { Say 'NEGATIVE CONTROL: no drag, nothing folded - claim D MUST fail' }

    # ---- setup -----------------------------------------------------------------
    Say '== setup: the startup window, wb (P | s1 | v, maximized) and wc'
    $main = Start-App (Join-Path $root 'run1.stderr.txt')
    Start-Sleep -Milliseconds 800
    & $exe +new-window --target=wb | Out-Null
    $wb = Find-BladeWindow 3
    $deadline = (Get-Date).AddSeconds(15)
    while ($wb -eq [IntPtr]::Zero -and (Get-Date) -lt $deadline) {
        $wb = @(Get-AppWindows | Where-Object { [IntPtr]$_.Hwnd -ne $main } | ForEach-Object { [IntPtr]$_.Hwnd } | Select-Object -First 1)[0]
        if ($null -eq $wb) { $wb = [IntPtr]::Zero; Start-Sleep -Milliseconds 300 }
    }
    if ($wb -eq [IntPtr]::Zero) { Write-TestAssertedNothing -Reason 'the wb window never opened' }
    & $exe +split --target=wb --direction=right --name=s1 | Out-Null
    Start-Sleep -Milliseconds 800
    & $exe +split --pane=s1 --direction=right --name=v "--view=$doc" | Out-Null
    Start-Sleep -Milliseconds 1500
    # The pane sidebar's minimize button is the stash (`paneSidebarToggleStash`
    # -> `Window.stashPane`, the function `+stash` runs): a fourth pane, stashed
    # BEFORE the fold, so the collapsed row's saved leaf positions count a
    # stashed pane (`stackLeavesOf` lists the stash too).
    & $exe +split --pane=v --direction=right --name=x | Out-Null
    Start-Sleep -Milliseconds 1000
    & $exe +stash --target=x | Out-Null
    Start-Sleep -Milliseconds 1000
    [void](Send-TestSysCommand -Window $wb -Command maximize)
    Start-Sleep -Milliseconds 1200
    Assert (Test-TestWindowZoomed -Window $wb) 'setup: wb is maximized (the real WM_SYSCOMMAND)'
    $before = @(Wait-BladeLeaves)
    Say ("      wb +list before: {0}" -f (Format-Leaves $before))
    if ($before.Count -ne 4) { Write-TestAssertedNothing -Reason "wb never reported four panes (got $($before.Count))" }
    Assert (@($before | Where-Object { $_.Name -eq 'x' -and $_.Stashed }).Count -eq 1) 'setup: x is stashed'
    Assert (@($before | Where-Object Minimized).Count -eq 0) 'setup: all three fit side by side in the maximized wb - nothing minimized by want of room'
    & $exe +new-window --target=wc | Out-Null
    Start-Sleep -Milliseconds 1200
    & $exe +new-window --target=wc --focus | Out-Null
    Start-Sleep -Milliseconds 800
    $wins = @(Get-AppWindows)
    Assert ($wins.Count -eq 3) "setup: three windows on show (got $($wins.Count))"
    $wc = @($wins | Where-Object { [IntPtr]$_.Hwnd -ne $main -and [IntPtr]$_.Hwnd -ne $wb } | ForEach-Object { [IntPtr]$_.Hwnd })[0]

    # ---- A: a real divider drag folds s1 and v --------------------------------
    Say '== A: drag the P|s1 divider almost to the row''s end'
    $dpi = [int](Get-TestWindowDpi -Window $wb); if ($dpi -le 0) { $dpi = 96 }
    $scale = $dpi / 96.0
    $c2 = @(Wait-Shown $wb 2)
    if ($c2.Count -ne 2) { Write-TestAssertedNothing -Reason "wb's two terminals never came up on show (got $($c2.Count))" }
    $wr = Get-TestWindowRect -Window $wb
    # The grid is inset by the same margin on both sides.
    $gridRight = $wr.Right - ($c2[0].Left - $wr.Left)
    $x0 = [int](($c2[0].Right + $c2[1].Left) / 2)
    $y = [int](($c2[0].Top + $c2[0].Bottom) / 2)
    $xEnd = [int]($gridRight - (Get-TestChromeDip -Dip 100 -Scale $scale))
    Say ("      divider at x={0}, dragged to x={1} (grid right {2})" -f $x0, $xEnd, $gridRight)
    if (-not $NegativeControl) {
        [void](Send-TestMouse -Window $wb -Target $wb -X $x0 -Y $y -Action down -HoldMs 0)
        Start-Sleep -Milliseconds 150
        $steps = 10
        for ($i = 1; $i -le $steps; $i++) {
            $x = [int]($x0 + ($xEnd - $x0) * $i / $steps)
            [void](Send-TestMouse -Window $wb -Target $wb -X $x -Y $y -Action move -HoldMs 0)
            Start-Sleep -Milliseconds 60
        }
        Start-Sleep -Milliseconds 300
        [void](Send-TestMouse -Window $wb -Target $wb -X $xEnd -Y $y -Action up -HoldMs 0)
        Start-Sleep -Milliseconds 800
    }
    $a = @(Wait-Shown $wb 1 5)
    $aLeaves = @(Get-BladeLeaves)
    Say ("      after release: {0} terminal(s) on show; +list {1}" -f $a.Count, (Format-Leaves $aLeaves))
    if (-not $NegativeControl) {
        Assert ($a.Count -eq 1) "A: the drag folded s1 - one terminal on show in wb (got $($a.Count))"
        Assert (@($aLeaves | Where-Object Minimized).Count -eq 2) "A: s1 and v are blades (+list minimized; got $(@($aLeaves | Where-Object Minimized).Count))"
    }

    # ---- B: the app saved the collapse itself ---------------------------------
    Say '== B: the collapse lands in the manifest'
    $deadline = (Get-Date).AddSeconds(8)
    do {
        Start-Sleep -Milliseconds 300
        $text = Read-Manifest
    } while ($text -notmatch $rowsRe -and (Get-Date) -lt $deadline)
    if (-not $NegativeControl) {
        Assert ($text -match $rowsRe) 'B: the manifest gained a collapsed row (pane_stack.rows) within the save debounce'
    }
    Assert (([regex]::Matches($text, '"maximized"\s*:\s*true')).Count -ge 1) 'B: the manifest records wb maximized'

    # ---- C: the updater's quit ------------------------------------------------
    Say '== C: quit through the quit action (the updater''s exit path)'
    $proc = Get-Process -Id $script:app.Pid -ErrorAction SilentlyContinue
    $wcPane = @(Get-TermPanes $wc)[0]
    [void](Send-TestKeys -Window $wc -Target ([IntPtr]$wcPane.Hwnd) -Key $quitKey -Modifiers ctrl, shift)
    $exited = $false
    if ($proc) { $exited = $proc.WaitForExit(20000) }
    Assert $exited 'C: the app exited on its own after the quit action (no kill)'
    if (-not $exited) { Stop-Process -Id $script:app.Pid -Force -ErrorAction SilentlyContinue; Start-Sleep -Milliseconds 800 }
    $text = Read-Manifest
    Assert (([regex]::Matches($text, '"tabs"')).Count -eq 3) "C: the manifest the quit left holds three windows (got $(([regex]::Matches($text, '"tabs"')).Count))"
    if (-not $NegativeControl) {
        Assert ($text -match $rowsRe) 'C: ...and still carries the collapsed row'
    }
    Copy-Item $script:manifest (Join-Path $root 'manifest-after-quit.json') -ErrorAction SilentlyContinue

    # ---- D: the relaunch -------------------------------------------------------
    Say '== D: relaunch - three windows, wb paced in behind wc, maximized'
    $err2 = Join-Path $root 'run2.stderr.txt'
    $relaunch = if ($RelaunchExePath) { $RelaunchExePath } else { $exe }
    if ($RelaunchExePath) { [void](Assert-GhozttyIsolatedBuild -Exe $relaunch); Say "      relaunching with $relaunch" }
    $agentsBefore = @()
    if ($AgentHandoff) {
        # The sessions outlived the quit, so the agent that served them is still
        # running. The newer build lands just after the relaunch's lead window,
        # and its supervisor (1 s tick) hands off while the rest are paced in.
        $agentsBefore = @(Get-RunAgentProcs | ForEach-Object { [int]$_.ProcessId })
        Assert ($agentsBefore.Count -ge 1) "F0 premise: the agent from the renamed image outlived the quit (pids: $($agentsBefore -join ','))"
    }
    [void](Start-App $err2 $relaunch)
    if ($AgentHandoff) {
        # Landed only once the lead window is up: before the launch, the agent
        # could finish handing off before the app even dialed it, and the
        # restore would never meet the handoff at all. From here the paced
        # windows still have ~5 s to go (2 x GHOZTTY_RESTORE_PACE_MS).
        Copy-Item -LiteralPath $agent -Destination $canonicalAgent -Force
        Say "      newer agent build landed at the canonical name while the paced windows are still to come"
    }
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-WindowCount) -lt 3 -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 400 }
    Assert ((Get-WindowCount) -eq 3) "D: all three windows came back (got $(Get-WindowCount))"
    $wb2 = Find-BladeWindow
    if ($wb2 -eq [IntPtr]::Zero) { Write-TestAssertedNothing -Reason 'the relaunch never rebuilt wb' }
    Start-Sleep -Milliseconds 1500
    $paced = @(Select-String -Path $err2 -Pattern "paced window '" -ErrorAction SilentlyContinue)
    Assert ($paced.Count -eq 2) "D: the log names two paced windows - wb came in behind the first (got $($paced.Count))"
    Assert (Test-TestWindowZoomed -Window $wb2) 'D: wb came back maximized'
    Assert-Blades 'D' $wb2

    # ---- E: after the pacer and the maximized layout settle ----------------------
    Say '== E: a few seconds later'
    Start-Sleep -Seconds 4
    Assert-Blades 'E' $wb2

    if ($AgentHandoff) {
        # ---- F: the handoff really happened under that restore ---------------
        Say '== F: the agent handed off during the relaunch'
        $successor = $null
        $deadline = (Get-Date).AddSeconds(30)
        do {
            $successor = @(Get-RunAgentProcs | Where-Object { $agentsBefore -notcontains [int]$_.ProcessId -and $_.ExecutablePath -eq $canonicalAgent })[0]
            if ($successor) { break }
            Start-Sleep -Milliseconds 500
        } while ((Get-Date) -lt $deadline)
        Assert ($null -ne $successor) 'F1 a successor agent running the canonical (newer) binary took over'
        $oldAlive = @($agentsBefore | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
        Assert ($oldAlive.Count -eq 0) "F2 the predecessor agent retired (still alive: $($oldAlive -join ','))"
        $log2 = Read-SharedText $err2
        foreach ($m in @('agent upgrade check: [^\r\n]*', 'in-place recovery: [^\r\n]*', 'session-restore: the local agent [^\r\n]*', 'session-restore: restored \d+ window\(s\)')) {
            foreach ($hit in [regex]::Matches($log2, $m)) { Say "      log: $($hit.Value)" }
        }
        # The handoff has to have landed INSIDE the paced restore for this run
        # to test anything: otherwise it is the plain run with a late handoff.
        # Either line is the pacer meeting the handoff: 'dropped' when a tick
        # found the link down, 'is back' when the app's recovery re-dialed
        # between two ticks and the next one found a REPLACED link - the case
        # that, before T3216, ended the pacing on the spot.
        Assert ($log2 -match 'session-restore: the local agent link (dropped mid-restore|is back)') 'F4 premise: the agent link dropped while windows were still being paced in'
        Assert ($log2 -notmatch 'keeping \d+ window\(s\) for the next launch') 'F5 no window was left for the next launch'
        # The blades are judged once more AFTER the handoff is known to have
        # landed: a recovery rebuild that runs late would undo them here.
        Start-Sleep -Seconds 3
        Assert ((Get-WindowCount) -eq 3) "F3 all three windows are still there after the handoff (got $(Get-WindowCount))"
        Assert-Blades 'F' $wb2
    }
    Complete-TestBody
} catch {
    $script:fail++
    Say "FAIL  script terminated: $($_.Exception.Message)"
    Say "      at $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())"
} finally {
    Say '== cleanup'
    foreach ($r in @($script:GhozttyTestDesktopLaunches)) { if ($r) { $r.Killed = $true } }
    Remove-TestDesktop
    Stop-RepoInstances
    $env:LOCALAPPDATA = $savedLocalAppData
    if ($null -ne $savedAgentBin) { $env:GHOSTTY_LOCAL_AGENT_BIN = $savedAgentBin }
    else { Remove-Item env:GHOSTTY_LOCAL_AGENT_BIN -ErrorAction SilentlyContinue }
    if ($null -ne $savedForce) { $env:GHOZTTY_AGENT_HANDOFF_FORCE = $savedForce }
    else { Remove-Item env:GHOZTTY_AGENT_HANDOFF_FORCE -ErrorAction SilentlyContinue }
    if ($null -ne $savedInterval) { $env:GHOZTTY_AGENT_HANDOFF_INTERVAL_MS = $savedInterval }
    else { Remove-Item env:GHOZTTY_AGENT_HANDOFF_INTERVAL_MS -ErrorAction SilentlyContinue }
    if ($null -ne $savedPace) { $env:GHOZTTY_RESTORE_PACE_MS = $savedPace }
    else { Remove-Item env:GHOZTTY_RESTORE_PACE_MS -ErrorAction SilentlyContinue }
    $env:GHOZTTY_PIPE_SUFFIX = $savedPipe
    if ($script:fail -eq 0) { Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue }
    else { Say "artifacts preserved at $root" }
}

$fgSeen = @(Stop-TestForegroundWatch)
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @(Get-TestLaunchedPids)
    Assert ($fgSeen.Count -gt 0) 'Z1 the foreground watcher actually sampled (negative control)'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'Z2 no test-desktop app ever became foreground on the interactive desktop'
}

if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard session-blades-update -Repo $repo 2>&1 | ForEach-Object { Say "  $_" }
}

Say ''
# The handoff arm adds F0-F5 and a third Assert-Blades (8 claims): 14 more.
$minPass = if ($AgentHandoff) { 48 } else { 34 }
Write-TestVerdict -Label 'T3213 SESSION BLADES UPDATE' -Pass $script:pass -Fail $script:fail -MinPass $minPass
