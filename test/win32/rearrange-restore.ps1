# T1544 acceptance: a pane moved into ANOTHER window comes back in THAT window
# after the app restarts - with its session - and a window the move emptied
# does not come back at all.
#
# THE CLAIM. T1538 made panes movable between windows, and every commit path
# (`commitCrossWindowDrop`, `commitCrossWindowNewTab`, `commitPopOutDrop`) marks
# the layout dirty, so the manifest is re-pushed with the new shape. That is the
# mechanism being right by construction; nothing had measured it. This script
# does, end to end: move, let the manifest settle, kill the app (the agent keeps
# the sessions), relaunch, and read back where every pane landed.
#
# ORACLE. Pane ids, not handles. A restart rebuilds every HWND, so the identity
# that crosses it is the pane id (`+list --json` terminal `id`, the manifest
# leaf's `pane_id`) and the agent session id the manifest records beside it.
# Three reads have to agree after the relaunch:
#   - LIVE grouping: `+list --json` puts each pane id under the window it was
#     moved into, and there are exactly as many windows as before the quit;
#   - the rewritten MANIFEST keys each window by the same cross-run uuid and
#     records the same session id per pane, so the pane re-ATTACHED rather than
#     starting a new shell;
#   - the moved panes are LIVE (lib\PaneLiveness.ps1): input reaches the child
#     and output comes back, so the restore is not a picture of a session.
#
# Claims:
#   A) a pane dragged from `window-1` into `dest` is restored under `dest`
#   B) `lone`, whose only pane was dragged into `dest`, closed - and neither its
#      window nor its uuid comes back after the restart
#   C) a pane popped out of `dest` into a window of its own comes back as its own
#      window, holding that pane, at the frame it had when the app quit
#   D) every pane that moved re-attached its original agent session and is live
#
# -NegativeControl inverts claim A to "the pane is restored where it STARTED" -
# the answer a manifest that ignored the move would give - and MUST fail.
#
# The drags are POSTED mouse messages to the source window in its own client
# coordinates, exactly as `rearrange-window-drop.ps1` drives them (see its
# header for why a captured pointer makes that the real code path).
#
# Hermetic: per-run LOCALAPPDATA, per-run agent binary override, a private IPC
# pipe suffix, and it only ever kills ghoztty processes launched from this
# repo's zig-out. Runs on the BACKGROUND test desktop.
#
#   powershell -NoProfile -File test\win32\rearrange-restore.ps1
param(
    [string]$ExePath,
    [string]$AgentExe,
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
$root = Join-Path $env:TEMP "ghoztty-rearrange-restore-$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\PaneLiveness.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}
function Say($m) { Write-Host $m }

function Stop-RepoInstances { [void](Stop-RepoGhoztty -Exe $exe -SettleMs 700) }
function Stop-AppOnly { [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 900) }

# The same arguments on every launch: the relaunch has to read the manifest the
# first launch wrote, and the keybind is how rearrange mode is entered.
$appArgs = @(
    '--config-default-files=false',
    '--window-show-tab-bar=always',
    '--keybind=ctrl+shift+f9=toggle_rearrange_mode')

function Start-App {
    # persistence: on (default) - the first launch records the manifest in a
    # throwaway $env:LOCALAPPDATA and the relaunch restores it; that restore IS
    # the claim, so the flag would erase the fixture.
    $app =Start-OnTestDesktop -Exe $exe -Arguments $appArgs
    if ((Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow') -eq [IntPtr]::Zero) {
        Write-TestAssertedNothing -Reason 'the app never opened a GhozttyWindow'
    }
    return $app
}

# ---- live topology (+list --json) -------------------------------------------

function Get-Data {
    $json = (& $exe +list --json 2>$null | Out-String).Trim()
    if (-not $json) { return $null }
    try { return ($json | ConvertFrom-Json).data } catch { return $null }
}

function Get-LeafIds($node) {
    if ($null -eq $node) { return @() }
    if ($node.type -eq 'leaf') { return @([string]$node.terminal.id) }
    return @(Get-LeafIds $node.left) + @(Get-LeafIds $node.right)
}

# One row per live window: { Hwnd, Target, Panes = pane ids across all tabs }.
function Get-LiveWindows {
    $data = Get-Data
    if (-not $data) { return , @() }
    $rows = @()
    foreach ($w in @($data.windows)) {
        $ids = @()
        foreach ($t in @($w.tabs)) { $ids += @(Get-LeafIds $t.splits) }
        $rows += [pscustomobject]@{
            Hwnd = [int64]$w.id; Target = [string]$w.target
            Panes = @($ids | Where-Object { $_ } | Sort-Object)
        }
    }
    return , $rows
}

function Get-LiveWindow($rows, [string]$target) {
    foreach ($r in $rows) { if ($r.Target -eq $target) { return $r } }
    return $null
}

# The window a pane id is under right now, or $null.
function Find-PaneWindow($rows, [string]$paneId) {
    foreach ($r in $rows) { if ($r.Panes -contains $paneId) { return $r } }
    return $null
}

function Wait-Live([scriptblock]$pred, [int]$timeoutSec = 30) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    do {
        $rows = Get-LiveWindows
        if (& $pred $rows) { return $rows }
        Start-Sleep -Milliseconds 400
    } while ((Get-Date) -lt $deadline)
    return (Get-LiveWindows)
}

# ---- manifest ----------------------------------------------------------------

function Manifest-Path { return (Join-Path $tmp 'ghoztty\session-layout-debug.json') }

function Read-Manifest {
    $p = Manifest-Path
    if (-not (Test-Path $p)) { return $null }
    try { return (Get-Content $p -Raw | ConvertFrom-Json) } catch { return $null }
}

function Manifest-Leaves($w) {
    $out = @()
    foreach ($tab in @($w.tabs)) {
        foreach ($n in @($tab.nodes)) { if ($n.leaf) { $out += @($n.leaf) } }
    }
    return $out
}

# pane id -> { Uuid, Session, Frame } for every leaf in the manifest.
function Get-ManifestPanes($m) {
    $map = @{}
    if ($null -eq $m) { return $map }
    foreach ($w in @($m.windows)) {
        foreach ($l in @(Manifest-Leaves $w)) {
            if (-not $l.pane_id) { continue }
            $map[[string]$l.pane_id] = [pscustomobject]@{
                Uuid = [string]$w.uuid; Session = [string]$l.session_id; Frame = $w.frame
            }
        }
    }
    return $map
}

# Waits until the manifest groups the given pane ids the way `$want` says
# (hashtable: group label -> pane ids that must share one window uuid) and every
# listed pane has a session id. Returns the manifest, or $null on timeout.
function Wait-ManifestGrouping([hashtable]$want, [int]$windowCount, [int]$timeoutSec = 30) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    do {
        $m = Read-Manifest
        if ($null -ne $m -and @($m.windows).Count -eq $windowCount) {
            $panes = Get-ManifestPanes $m
            $ok = $true
            $uuids = @()
            foreach ($k in $want.Keys) {
                $u = @($want[$k] | ForEach-Object {
                    if ($panes.ContainsKey($_) -and $panes[$_].Session) { $panes[$_].Uuid } else { '<missing>' }
                } | Sort-Object -Unique)
                if ($u.Count -ne 1 -or $u[0] -eq '<missing>') { $ok = $false; break }
                $uuids += $u[0]
            }
            if ($ok -and @($uuids | Sort-Object -Unique).Count -eq $want.Count) { return $m }
        }
        Start-Sleep -Milliseconds 400
    } while ((Get-Date) -lt $deadline)
    return $null
}

# ---- the gesture (see rearrange-window-drop.ps1) -----------------------------

function Get-PaneBoxes([IntPtr]$top) {
    $all = @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal' |
        Where-Object Visible | ForEach-Object {
            [pscustomobject]@{
                Hwnd = [int64]$_.Hwnd; Left = $_.Left; Top = $_.Top
                Width = $_.Width; Height = $_.Height
                Right = $_.Left + $_.Width; Bottom = $_.Top + $_.Height
            }
        })
    return , @($all | Sort-Object Top, Left)
}

function Move-Drag([IntPtr]$source, [int]$ScreenX, [int]$ScreenY, [string]$Action) {
    return Send-TestMouse -Window $source -Target $source -X $ScreenX -Y $ScreenY -Action $Action -Client
}

function Enter-RearrangeMode([IntPtr]$top) {
    if (-not (Set-TestActiveWindow -Window $top)) { return $false }
    Start-Sleep -Milliseconds 400
    $focused = [IntPtr](Get-TestFocusedWindow -Window $top)
    $r = Send-TestKeys -Window $top -Target $focused -Modifiers ctrl, shift -Key F9
    Start-Sleep -Milliseconds 1200
    return $r
}

# Drag the pane box `$dragged` (in window `$src`) onto the right edge zone of
# box `$target` in another window, and release.
function Invoke-CrossDrop([IntPtr]$src, $dragged, $target) {
    $grabX = $dragged.Left + 60
    $grabY = $dragged.Top - [int]($script:band / 2)
    $dropX = $target.Right - ($script:edge + 40)
    $dropY = [int](($target.Top + $target.Bottom) / 2)
    $ok = (Move-Drag $src $grabX $grabY 'down')
    $ok = (Move-Drag $src $dropX $dropY 'move') -and $ok
    Start-Sleep -Milliseconds 500
    $ok = (Move-Drag $src $dropX $dropY 'up') -and $ok
    Start-Sleep -Milliseconds 2500
    return $ok
}

# -----------------------------------------------------------------------------

$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN
$savedPipe = $env:GHOZTTY_PIPE_SUFFIX
$env:GHOZTTY_PIPE_SUFFIX = "-rrestore$PID"

Stop-RepoInstances
New-Item -ItemType Directory -Force $root | Out-Null
$tmp = Join-Path $root 'app'
New-Item -ItemType Directory -Force (Join-Path $tmp 'ghoztty\local-agent-debug') | Out-Null
$env:LOCALAPPDATA = $tmp
$env:GHOSTTY_LOCAL_AGENT_BIN = $agent

Reset-TestBody
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    Assert (Test-Path $exe) 'ghoztty exe exists in zig-out'
    Assert (Test-Path $agent) 'ghoztty-agent exe exists in zig-out'
    [void](Assert-GhozttyIsolatedBuild -Exe $exe)
    if ($NegativeControl) {
        Say 'NEGATIVE CONTROL: claim A is inverted to "restored where it started" - this run MUST fail'
    }

    # ---- setup: three windows, four panes, all with agent sessions ----------
    Say '== setup: window-1 (two panes), dest, lone'
    # persistence: on (default) - a throwaway $env:LOCALAPPDATA with no manifest
    # yet, and the relaunch below restores exactly what this launch records.
    $app = Start-App
    Start-Sleep -Seconds 2
    & $exe +split --direction=right --target=window-1 | Out-Null
    Start-Sleep -Milliseconds 1000
    & $exe +new-window --target=dest | Out-Null
    & $exe +new-window --target=lone | Out-Null

    $live0 = Wait-Live {
        param($rows)
        $w1 = Get-LiveWindow $rows 'window-1'; $d = Get-LiveWindow $rows 'dest'; $l = Get-LiveWindow $rows 'lone'
        return ($w1 -and $d -and $l -and $w1.Panes.Count -eq 2 -and $d.Panes.Count -eq 1 -and $l.Panes.Count -eq 1)
    } 45
    $w1 = Get-LiveWindow $live0 'window-1'; $d0 = Get-LiveWindow $live0 'dest'; $l0 = Get-LiveWindow $live0 'lone'
    if (-not ($w1 -and $d0 -and $l0 -and $w1.Panes.Count -eq 2 -and $d0.Panes.Count -eq 1 -and $l0.Panes.Count -eq 1)) {
        Write-TestAssertedNothing -Reason 'the three windows never came up as window-1(2) / dest(1) / lone(1)'
    }
    $hW1 = [IntPtr]$w1.Hwnd; $hDest = [IntPtr]$d0.Hwnd; $hLone = [IntPtr]$l0.Hwnd
    # Clear of each other, so no drop point is ambiguous between two windows.
    Set-TestWindowPos -Window $hW1 -X 10 -Y 10 -Width 820 -Height 520 | Out-Null
    Set-TestWindowPos -Window $hDest -X 850 -Y 10 -Width 1000 -Height 1000 | Out-Null
    Set-TestWindowPos -Window $hLone -X 10 -Y 560 -Width 820 -Height 460 | Out-Null
    Start-Sleep -Milliseconds 800

    $destOwn = $d0.Panes[0]
    $lonePane = $l0.Panes[0]
    $m0 = Wait-ManifestGrouping @{ w1 = $w1.Panes; dest = @($destOwn); lone = @($lonePane) } 3 40
    Assert ($null -ne $m0) 'setup: the manifest records three windows, every pane with an agent session'
    if ($null -eq $m0) { Write-TestAssertedNothing -Reason 'the manifest never recorded the starting layout' }
    $p0 = Get-ManifestPanes $m0
    $loneUuid = $p0[$lonePane].Uuid
    $w1Uuid = $p0[$w1.Panes[0]].Uuid

    $dpi = Get-TestWindowDpi -Window $hW1
    $scale = $dpi / 96.0
    $script:band = [int][math]::Round(24.0 * $scale)
    $script:edge = [int][math]::Round(28.0 * $scale)
    Say "      monitor dpi = $dpi, header band = $($script:band) px, edge band = $($script:edge) px"

    # ---- move 1: window-1's first pane into dest -----------------------------
    Say '== move 1: a pane from window-1 into dest'
    Assert (Enter-RearrangeMode $hW1) 'setup: rearrange mode on in window-1'
    $src = Get-PaneBoxes $hW1
    $dst = Get-PaneBoxes $hDest
    if ($src.Count -ne 2 -or $dst.Count -ne 1) {
        Write-TestAssertedNothing -Reason "window-1/dest never showed 2/1 panes (got $($src.Count)/$($dst.Count))"
    }
    Assert (Invoke-CrossDrop $hW1 $src[0] $dst[0]) 'move 1: drag delivered'
    $live1 = Wait-Live {
        param($rows)
        $d = Get-LiveWindow $rows 'dest'
        return ($d -and $d.Panes.Count -eq 2)
    } 10
    $d1 = Get-LiveWindow $live1 'dest'
    $moved1 = @($d1.Panes | Where-Object { $_ -ne $destOwn })
    Assert ($moved1.Count -eq 1 -and $w1.Panes -contains $moved1[0]) `
        "move 1: dest now holds one of window-1's panes (dest: $($d1.Panes -join ', '))"
    if ($moved1.Count -ne 1) { Write-TestAssertedNothing -Reason 'move 1 did not land - nothing below would measure a restore' }
    $moved1 = $moved1[0]
    $kept1 = @($w1.Panes | Where-Object { $_ -ne $moved1 })[0]

    # ---- move 2: lone's only pane into dest; lone closes ---------------------
    Say '== move 2: lone''s only pane into dest'
    Assert (Enter-RearrangeMode $hLone) 'setup: rearrange mode on in lone'
    $src = Get-PaneBoxes $hLone
    $dst = Get-PaneBoxes $hDest
    if ($src.Count -ne 1 -or $dst.Count -lt 1) { Write-TestAssertedNothing -Reason 'lone/dest boxes missing before move 2' }
    $loneHwndPane = $src[0].Hwnd
    Assert (Invoke-CrossDrop $hLone $src[0] $dst[0]) 'move 2: drag delivered'
    $live2 = Wait-Live {
        param($rows)
        $d = Get-LiveWindow $rows 'dest'
        return ($d -and $d.Panes -contains $lonePane -and -not (Get-LiveWindow $rows 'lone'))
    } 10
    $d2 = Get-LiveWindow $live2 'dest'
    Assert ($d2 -and $d2.Panes -contains $lonePane) 'move 2: dest now holds lone''s pane'
    Assert ($null -eq (Get-LiveWindow $live2 'lone')) 'move 2: lone closed once its last pane left'

    # ---- pop-out: lone's pane (now in dest) into a window of its own ---------
    Say '== pop-out: lone''s pane out of dest into its own window'
    Assert (Enter-RearrangeMode $hDest) 'setup: rearrange mode on in dest'
    $boxes = Get-PaneBoxes $hDest
    $popBox = @($boxes | Where-Object { $_.Hwnd -eq $loneHwndPane })
    if ($popBox.Count -ne 1) { Write-TestAssertedNothing -Reason 'lone''s pane handle is not among dest''s boxes' }
    $popBox = $popBox[0]
    # The pop-out button: right end of the header band, 8dip pad, 20dip hit box
    # (`rearrange_header.layout`), as in rearrange-window-drop.ps1 claim D.
    $btnX = $popBox.Right - [int][math]::Round(18.0 * $scale)
    $btnY = $popBox.Top - [int]($script:band / 2)
    [void](Move-Drag $hDest $btnX $btnY 'down')
    [void](Move-Drag $hDest $btnX $btnY 'up')
    $live3 = Wait-Live {
        param($rows)
        $w = Find-PaneWindow $rows $lonePane
        return ($w -and $w.Hwnd -ne [int64]$hDest -and $w.Panes.Count -eq 1)
    } 10
    $popped = Find-PaneWindow $live3 $lonePane
    Assert ($popped -and $popped.Hwnd -ne [int64]$hDest -and $popped.Panes.Count -eq 1) `
        'pop-out: lone''s pane is alone in a new window'
    if (-not $popped -or $popped.Hwnd -eq [int64]$hDest) { Write-TestAssertedNothing -Reason 'the pop-out never produced a window' }
    $hPop = [IntPtr]$popped.Hwnd
    # A frame nobody else has, so "at its own frame" cannot be satisfied by a
    # cascade default landing in the same place by accident.
    Set-TestWindowPos -Window $hPop -X 333 -Y 222 -Width 777 -Height 555 | Out-Null
    Start-Sleep -Milliseconds 800
    $popRect = Get-TestWindowRect -Window $hPop

    # ---- the manifest settles on the moved shape -----------------------------
    $wantGroups = @{ w1 = @($kept1); dest = @($destOwn, $moved1); pop = @($lonePane) }
    $mQuit = Wait-ManifestGrouping $wantGroups 3 30
    Assert ($null -ne $mQuit) 'before quit: the manifest records the moved shape (window-1 / dest+moved / popped)'
    if ($null -eq $mQuit) { Write-TestAssertedNothing -Reason 'the manifest never caught up with the moves' }
    $pQuit = Get-ManifestPanes $mQuit
    Assert (@($mQuit.windows | Where-Object { [string]$_.uuid -eq $loneUuid }).Count -eq 0) `
        'before quit: lone''s uuid has left the manifest'
    $popUuid = $pQuit[$lonePane].Uuid
    $destUuid = $pQuit[$destOwn].Uuid
    Assert ($popUuid -ne $loneUuid) 'before quit: the popped window is a NEW window, not lone reborn'
    $sessions = @{}
    foreach ($id in @($kept1, $destOwn, $moved1, $lonePane)) { $sessions[$id] = $pQuit[$id].Session }
    foreach ($id in @($moved1, $lonePane)) {
        Assert ($sessions[$id] -eq $p0[$id].Session) "before quit: moved pane $id kept its agent session through the move"
    }
    $mtimeQuit = (Get-Item (Manifest-Path)).LastWriteTimeUtc

    # ---- restart ------------------------------------------------------------
    Say '== restart: kill the app (agent stays), relaunch'
    foreach ($r in $script:GhozttyTestDesktopLaunches) { if ($r.Pid -eq $app.Pid) { $r.Killed = $true } }
    Stop-AppOnly
    $app2 = Start-App
    $allPanes = @($kept1, $destOwn, $moved1, $lonePane)
    $liveR = Wait-Live {
        param($rows)
        return (@($allPanes | Where-Object { -not (Find-PaneWindow $rows $_) }).Count -eq 0)
    } 60
    $missing = @($allPanes | Where-Object { -not (Find-PaneWindow $liveR $_) })
    Assert ($missing.Count -eq 0) "restart: every pane came back (missing: $($missing -join ', '))"

    $wMoved = Find-PaneWindow $liveR $moved1
    $wDest = Find-PaneWindow $liveR $destOwn
    $wKept = Find-PaneWindow $liveR $kept1
    if ($NegativeControl) {
        Assert ($wMoved -and $wKept -and $wMoved.Hwnd -eq $wKept.Hwnd) `
            'NEGATIVE: the moved pane is restored beside the pane it STARTED with'
    } else {
        Assert ($wMoved -and $wDest -and $wMoved.Hwnd -eq $wDest.Hwnd) `
            'A: the pane moved into dest is restored under dest'
        Assert ($wMoved -and $wKept -and $wMoved.Hwnd -ne $wKept.Hwnd) `
            'A: and NOT back beside the pane it started with'
    }
    Assert ($wKept -and $wKept.Panes.Count -eq 1) "A: window-1 comes back holding just its remaining pane (got $(if ($wKept) { $wKept.Panes.Count } else { 'none' }))"

    # Window count settles after the restore's own startup window is put away.
    Start-Sleep -Seconds 3
    $liveR = Get-LiveWindows
    Assert ($liveR.Count -eq 3) "B: exactly three windows came back - lone did not return empty (got $($liveR.Count): $(($liveR | ForEach-Object { "$($_.Target)[$($_.Panes.Count)]" }) -join ', '))"
    $empties = @($liveR | Where-Object { $_.Panes.Count -eq 0 })
    Assert ($empties.Count -eq 0) 'B: no window came back empty'
    Assert ($null -eq (Get-LiveWindow $liveR 'lone')) 'B: no window answers to lone'

    $wPop = Find-PaneWindow $liveR $lonePane
    Assert ($wPop -and $wPop.Panes.Count -eq 1) 'C: the popped-out pane is restored alone in its own window'
    if ($wPop) {
        $r = Get-TestWindowRect -Window ([IntPtr]$wPop.Hwnd)
        $dx = [math]::Abs($r.Left - $popRect.Left) + [math]::Abs($r.Top - $popRect.Top)
        $dw = [math]::Abs($r.Width - $popRect.Width) + [math]::Abs($r.Height - $popRect.Height)
        Say ("      popped frame before quit x={0} y={1} w={2} h={3}; after x={4} y={5} w={6} h={7}" -f `
            $popRect.Left, $popRect.Top, $popRect.Width, $popRect.Height, $r.Left, $r.Top, $r.Width, $r.Height)
        Assert ($dx -le 4 -and $dw -le 4) 'C: at the frame it had when the app quit'
    }

    # The relaunch rewrites the manifest from the restored topology; that
    # rewrite is the restore's own record of which uuid holds which session.
    $deadline = (Get-Date).AddSeconds(30)
    $mR = $null
    do {
        if ((Get-Item (Manifest-Path)).LastWriteTimeUtc -gt $mtimeQuit) {
            $mR = Wait-ManifestGrouping $wantGroups 3 2
            if ($mR) { break }
        }
        Start-Sleep -Milliseconds 400
    } while ((Get-Date) -lt $deadline)
    Assert ($null -ne $mR) 'D: the relaunch rewrote the manifest with the same grouping'
    if ($mR) {
        $pR = Get-ManifestPanes $mR
        Assert ($pR[$moved1].Uuid -eq $destUuid) 'D: the moved pane is under dest''s cross-run uuid'
        Assert ($pR[$lonePane].Uuid -eq $popUuid) 'D: the popped pane is under the popped window''s uuid'
        Assert ($pR[$kept1].Uuid -eq $w1Uuid) 'D: window-1 kept its uuid'
        foreach ($id in $allPanes) {
            Assert ($pR[$id].Session -eq $sessions[$id]) "D: pane $id re-attached its session ($($sessions[$id]))"
        }
    }
    Assert (Test-PaneLive -Exe $exe -Target $moved1 -Tmp $root -Tag 'MOVED') `
        'D: the pane moved into dest is LIVE after the restart'
    Assert (Test-PaneLive -Exe $exe -Target $lonePane -Tmp $root -Tag 'POPPED') `
        'D: the popped-out pane is LIVE after the restart'

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
        update -Guard rearrange-restore -Repo $repo 2>&1 | ForEach-Object { Say "  $_" }
}

Say ''
Write-TestVerdict -Label 'T1544 REARRANGE RESTORE' -Pass $script:pass -Fail $script:fail
