# T1838 acceptance: a STASHED pane stays stashed across an app restart, in
# the same place in the stash, sized to its real slot, with its session.
#
# THE CLAIM. T1827 brought stashing to Windows but the session manifest did
# not record it, so every stashed pane came back ON SCREEN after a restart.
# T1838 writes a per-leaf `stash_index` (0 = top of the stash, Mac's
# `stashIndex`) and the restore re-stashes the rebuilt panes in that order.
#
# Layout: P, then `+split right` -> s1, then `+split down` off s1 -> s2, so
# P | (s1 / s2). Stash s2, then s1: s1 is the top of the stash (index 0).
#
# Claims:
#   A) before the quit, the manifest records s1 at stash_index 0, s2 at 1, and
#      P with none
#   B) after a kill + relaunch (the agent keeps the sessions), +list --json
#      marks s1 and s2 stashed and P not, and only P's HWND is visible
#   C) each stashed pane's hidden HWND is sized to its REAL slot (the right
#      column split in two), not a placeholder: s1 and s2 share P's width and
#      their heights add up to P's (the c6826b79a case, at launch)
#   D) the relaunch rewrites the manifest with the SAME stash order (the
#      restored live state, read back), and every pane re-attached its
#      session - a stash round trip never ends one
#   E) the stashed pane is LIVE after the restart, and +restore puts s1 back
#      on screen in its slot
#
# -NegativeControl inverts claim B to "s1 is on screen after the restart" -
# the answer a manifest without the stash gives - and MUST fail.
#
# Hermetic: per-run LOCALAPPDATA, per-run agent binary override, a private IPC
# pipe suffix, and it only ever kills ghoztty processes launched from this
# repo's zig-out. Runs on the BACKGROUND test desktop.
#
#   powershell -NoProfile -File test\win32\stash-restore.ps1
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
$root = Join-Path $env:TEMP "ghoztty-stash-restore-$PID"

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

$appArgs = @('--config-default-files=false')

function Start-App {
    # persistence: on (default) - the first launch records the manifest in a
    # throwaway $env:LOCALAPPDATA and the relaunch restores it; that restore IS
    # the claim, so the flag would erase the fixture.
    $app = Start-OnTestDesktop -Exe $exe -Arguments $appArgs
    if ((Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow') -eq [IntPtr]::Zero) {
        Write-TestAssertedNothing -Reason 'the app never opened a GhozttyWindow'
    }
    return $app
}

# ---- live state (+list --json) -----------------------------------------------

# Every leaf object in `+list --json`: anything carrying both `id` and `pid`.
function Get-Leaves {
    $raw = (& $exe +list --json 2>$null | Out-String).Trim()
    if (-not $raw) { return , @() }
    $out = New-Object System.Collections.ArrayList
    $walk = $null
    $walk = {
        param($o)
        if ($null -eq $o) { return }
        if ($o -is [System.Array]) { foreach ($x in $o) { & $walk $x }; return }
        if ($o -is [System.Management.Automation.PSCustomObject]) {
            $names = @($o.PSObject.Properties.Name)
            if (($names -contains 'id') -and ($names -contains 'pid')) { [void]$out.Add($o) }
            foreach ($p in $o.PSObject.Properties) { & $walk $p.Value }
        }
    }
    try { & $walk ($raw | ConvertFrom-Json) } catch { return , @() }
    return , $out.ToArray()
}
function Get-LeafById($leaves, [string]$id) {
    foreach ($l in $leaves) { if ([string]$l.id -eq $id) { return $l } }
    return $null
}
function Test-LeafStashed($leaf) {
    return ($null -ne $leaf) -and ($leaf.PSObject.Properties.Name -contains 'stashed') -and ($leaf.stashed -eq $true)
}
function Wait-Leaves([scriptblock]$pred, [int]$timeoutSec = 30) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    do {
        $ls = Get-Leaves
        if (& $pred $ls) { return $ls }
        Start-Sleep -Milliseconds 400
    } while ((Get-Date) -lt $deadline)
    return (Get-Leaves)
}

function Get-Panes([IntPtr]$top) { @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal') }

# ---- manifest ----------------------------------------------------------------

function Manifest-Path { return (Join-Path $tmp 'ghoztty\session-layout-debug.json') }

# pane id -> { Session, Stash } for every leaf, or $null when unreadable.
function Read-ManifestPanes {
    $p = Manifest-Path
    if (-not (Test-Path $p)) { return $null }
    try { $m = Get-Content $p -Raw | ConvertFrom-Json } catch { return $null }
    $map = @{}
    foreach ($w in @($m.windows)) {
        foreach ($tab in @($w.tabs)) {
            foreach ($n in @($tab.nodes)) {
                if (-not $n.leaf -or -not $n.leaf.pane_id) { continue }
                $l = $n.leaf
                $si = if ($l.PSObject.Properties.Name -contains 'stash_index') { [int]$l.stash_index } else { -1 }
                $map[[string]$l.pane_id] = [pscustomobject]@{ Session = [string]$l.session_id; Stash = $si }
            }
        }
    }
    return $map
}

# Waits until the manifest records exactly `$want` (pane id -> stash index,
# -1 = on screen) with a session id on every listed pane.
function Wait-ManifestStash([hashtable]$want, [int]$timeoutSec = 30, [datetime]$after = [datetime]::MinValue) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    do {
        $p = Manifest-Path
        if ((Test-Path $p) -and (Get-Item $p).LastWriteTimeUtc -gt $after) {
            $m = Read-ManifestPanes
            if ($m -and $m.Count -eq $want.Count) {
                $ok = $true
                foreach ($k in $want.Keys) {
                    if (-not $m.ContainsKey($k) -or -not $m[$k].Session -or $m[$k].Stash -ne $want[$k]) { $ok = $false; break }
                }
                if ($ok) { return $m }
            }
        }
        Start-Sleep -Milliseconds 400
    } while ((Get-Date) -lt $deadline)
    return $null
}

# -----------------------------------------------------------------------------

$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN
$savedPipe = $env:GHOZTTY_PIPE_SUFFIX
$env:GHOZTTY_PIPE_SUFFIX = "-stashrestore$PID"

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
        Say 'NEGATIVE CONTROL: claim B is inverted to "s1 is on screen after the restart" - this run MUST fail'
    }

    # ---- setup: P | (s1 / s2), every pane on an agent session ---------------
    Say '== setup: P | (s1 / s2)'
    $app = Start-App
    Start-Sleep -Seconds 2
    & $exe +split --direction=right --name=s1 | Out-Null
    Start-Sleep -Milliseconds 900
    & $exe +split --pane=s1 --direction=down --name=s2 | Out-Null
    $l0 = Wait-Leaves { param($ls) $ls.Count -eq 3 -and @($ls | Where-Object { $_.name -eq 's2' }).Count -eq 1 } 30
    if ($l0.Count -ne 3) { Write-TestAssertedNothing -Reason "the three panes never came up (got $($l0.Count))" }
    $idS1 = [string](@($l0 | Where-Object { $_.name -eq 's1' })[0].id)
    $idS2 = [string](@($l0 | Where-Object { $_.name -eq 's2' })[0].id)
    $idP = [string](@($l0 | Where-Object { [string]$_.id -ne $idS1 -and [string]$_.id -ne $idS2 })[0].id)
    Assert ($idP -and $idS1 -and $idS2) "setup: three pane ids (P=$idP s1=$idS1 s2=$idS2)"

    $m0 = Wait-ManifestStash @{ $idP = -1; $idS1 = -1; $idS2 = -1 } 40
    if ($null -eq $m0) { Write-TestAssertedNothing -Reason 'the manifest never recorded the three panes with sessions' }

    # ---- stash s2, then s1: s1 is the top ------------------------------------
    Say '== stash s2, then s1'
    & $exe +stash --target=s2 | Out-Null
    Start-Sleep -Milliseconds 500
    & $exe +stash --target=s1 | Out-Null
    $ls = Wait-Leaves { param($ls) (Test-LeafStashed (Get-LeafById $ls $idS1)) -and (Test-LeafStashed (Get-LeafById $ls $idS2)) } 10
    Assert ((Test-LeafStashed (Get-LeafById $ls $idS1)) -and (Test-LeafStashed (Get-LeafById $ls $idS2))) `
        'setup: s1 and s2 are stashed before the quit'

    $want = @{ $idP = -1; $idS1 = 0; $idS2 = 1 }
    $mQuit = Wait-ManifestStash $want 30
    Assert ($null -ne $mQuit) 'A: the manifest records s1 at stash_index 0, s2 at 1, and P with none'
    if ($null -eq $mQuit) { Write-TestAssertedNothing -Reason 'the manifest never recorded the stash' }
    $sessions = @{}
    foreach ($id in @($idP, $idS1, $idS2)) { $sessions[$id] = $mQuit[$id].Session }
    $mtimeQuit = (Get-Item (Manifest-Path)).LastWriteTimeUtc

    # ---- restart ------------------------------------------------------------
    Say '== restart: kill the app (agent stays), relaunch'
    foreach ($r in $script:GhozttyTestDesktopLaunches) { if ($r.Pid -eq $app.Pid) { $r.Killed = $true } }
    Stop-AppOnly
    $app2 = Start-App
    $top = Wait-TestWindow -ProcessId $app2.Pid -Class 'GhozttyWindow'
    $lR = Wait-Leaves { param($ls) $ls.Count -eq 3 -and $null -ne (Get-LeafById $ls $idS1) -and $null -ne (Get-LeafById $ls $idS2) } 60
    Assert ($lR.Count -eq 3) "restart: all three panes came back (got $($lR.Count))"
    # The restore applies the stash once each tab is whole; give the first
    # layout pass a moment so the HWND reads below see its result.
    Start-Sleep -Milliseconds 1500
    $lR = Get-Leaves
    $s1 = Get-LeafById $lR $idS1; $s2 = Get-LeafById $lR $idS2; $pL = Get-LeafById $lR $idP
    if ($NegativeControl) {
        Assert (-not (Test-LeafStashed $s1)) 'NEGATIVE: s1 is on screen after the restart'
    } else {
        Assert (Test-LeafStashed $s1) 'B: +list --json marks s1 stashed after the restart'
    }
    Assert (Test-LeafStashed $s2) 'B: +list --json marks s2 stashed after the restart'
    Assert (-not (Test-LeafStashed $pL)) 'B: P is not stashed'

    $panes = @(Get-Panes $top)
    $vis = @($panes | Where-Object Visible)
    Assert ($vis.Count -eq 1) "B: exactly one pane HWND is visible (got $($vis.Count) of $($panes.Count))"
    $hidden = @($panes | Where-Object { -not $_.Visible })
    if ($vis.Count -eq 1 -and $hidden.Count -eq 2) {
        $pv = $vis[0]
        $h = @($hidden | Sort-Object Top)
        Say ("      P {0}x{1}; hidden {2}x{3} @y{4}, {5}x{6} @y{7}" -f $pv.Width, $pv.Height,
            $h[0].Width, $h[0].Height, $h[0].Top, $h[1].Width, $h[1].Height, $h[1].Top)
        # The full layout gives the right column half the window and splits it
        # top/bottom: the two stashed panes stack in it, as wide as each other,
        # with heights that add up to the column (P's height) less one band.
        Assert ([math]::Abs($h[0].Width - $h[1].Width) -le 2 -and $h[0].Width -gt 40) `
            'C: the stashed panes share their column''s width'
        Assert ($h[1].Top -gt $h[0].Top + 20) 'C: the stashed panes stack top / bottom, as their split lays them out'
        $sum = $h[0].Height + $h[1].Height
        Assert ($sum -le $pv.Height -and $sum -ge $pv.Height - 24) `
            "C: their heights add up to the column ($sum vs P $($pv.Height)), not a placeholder size"
    } else {
        Assert $false "C: two hidden + one visible pane HWNDs to measure (got $($hidden.Count) hidden)"
    }

    # The relaunch rewrites the manifest from the restored live state.
    $mR = Wait-ManifestStash $want 30 $mtimeQuit
    Assert ($null -ne $mR) 'D: the relaunch rewrote the manifest with the same stash order (s1 0, s2 1, P none)'
    if ($mR) {
        foreach ($id in @($idP, $idS1, $idS2)) {
            Assert ($mR[$id].Session -eq $sessions[$id]) "D: pane $id re-attached its session ($($sessions[$id]))"
        }
    }

    Assert (Test-PaneLive -Exe $exe -Target $idS2 -Tmp $root -Tag 'STASHED') `
        'E: the stashed pane s2 is LIVE after the restart'
    & $exe +restore --target=s1 | Out-Null
    Start-Sleep -Milliseconds 900
    $ls = Get-Leaves
    Assert (-not (Test-LeafStashed (Get-LeafById $ls $idS1))) 'E: +restore brings s1 back'
    $vis = @(Get-Panes $top | Where-Object Visible)
    Assert ($vis.Count -eq 2) "E: two panes on screen after the restore (got $($vis.Count))"
    if ($vis.Count -eq 2) {
        $v = @($vis | Sort-Object Left)
        Assert ($v[1].Left -gt $v[0].Left + 40 -and [math]::Abs($v[0].Height - $v[1].Height) -le 4) `
            'E: s1 came back into the right column beside P'
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
        update -Guard stash-restore -Repo $repo 2>&1 | ForEach-Object { Say "  $_" }
}

Say ''
Write-TestVerdict -Label 'T1838 STASH RESTORE' -Pass $script:pass -Fail $script:fail
