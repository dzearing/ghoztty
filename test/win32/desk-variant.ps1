# T1832 acceptance: a window's OWN gradient (Mac `PaneDeskVariant`, main
# fe3f7c8da / a516200d2 / 5ba797c8c / a34653b2a / b4a3216cc).
#
# In the elevated pane style, `+new-window --color=random` and a window opened
# BY HAND (the New Window action) get their own random gradient desk instead of
# the shared ocean, and the terminals keep their theme colour. Programmatic
# windows keep the ocean. The seed persists with the layout, so a restored
# window comes back with the same gradient. In the flat style `random` is the
# old terminal tint.
#
# Claims, and the oracle for each:
#
#   A) OCEAN STAYS THE DEFAULT. The startup window and a plain `+new-window`
#      paint the same desk pixels (all four windows are sized alike first, so
#      the gradient is sampled at the same place) and the manifest records no
#      `desk_variant` for either.
#   B) `--color=random` IS A GRADIENT. Each such window records a non-zero
#      seed, the two seeds differ, its desk pixels differ from the ocean's, and
#      `+list --json` shows NO `background_tint` on its pane - the terminal
#      kept its theme.
#   C) BY HAND. The New Window action (a chord) opens a window that records a
#      seed of its own and does not paint the ocean.
#   D) RESTORE. Kill the app (the agent keeps the sessions), relaunch: each
#      variant window comes back with the SAME seed in the rewritten manifest
#      and the SAME desk pixels it had before.
#   E) FLAT. With `macos-pane-style = flat`, `--color=random` tints the
#      terminal (`background_tint` present) and records no seed.
#
# Desk pixels are read from a PrintWindow of the top-level window (the parent's
# own paint): the right margin halfway down the pane, and the bottom margin
# under the pane's centre - both pure desk on every window.
#
# Hermetic: per-run LOCALAPPDATA, per-run agent binary override, a private IPC
# pipe suffix; it only ever kills ghoztty processes launched from this repo's
# zig-out. Runs on the BACKGROUND test desktop.
#
# -NegativeControl inverts claim B's pixel check to "the random window paints
# the ocean" and MUST fail.
#
#   powershell -NoProfile -File test\win32\desk-variant.ps1
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
$script:skipped = 0
$root = Join-Path $env:TEMP "ghoztty-desk-variant-$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}
function Say($m) { Write-Host $m }

function Stop-RepoInstances { [void](Stop-RepoGhoztty -Exe $exe -SettleMs 700) }
function Stop-AppOnly { [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 900) }

# The same arguments on every launch: the relaunch reads the manifest the first
# launch wrote, and the chord is the user's own New Window action.
$appArgs = @(
    '--config-default-files=false',
    '--background=#000000',
    '--unfocused-split-opacity=1',
    '--keybind=ctrl+shift+f9=new_window')

function Start-App([string[]]$extra = @()) {
    # persistence: on (default) - the first launch records the manifest in a
    # throwaway $env:LOCALAPPDATA and the relaunch restores it; that restore IS
    # claim D, so the flag would erase the fixture.
    $app = Start-OnTestDesktop -Exe $exe -Arguments ($appArgs + $extra)
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

function Get-FirstLeaf($node) {
    if ($null -eq $node) { return $null }
    if ($node.type -eq 'leaf') { return $node.terminal }
    $l = Get-FirstLeaf $node.left
    if ($l) { return $l }
    return Get-FirstLeaf $node.right
}

# One row per live window: { Hwnd, Target, Tint (first pane's background_tint) }.
function Get-LiveWindows {
    $data = Get-Data
    if (-not $data) { return , @() }
    $rows = @()
    foreach ($w in @($data.windows)) {
        $leaf = $null
        foreach ($t in @($w.tabs)) { if (-not $leaf) { $leaf = Get-FirstLeaf $t.splits } }
        $rows += [pscustomobject]@{
            Hwnd = [int64]$w.id; Target = [string]$w.target
            Tint = if ($leaf) { $leaf.background_tint } else { $null }
        }
    }
    return , $rows
}

function Get-LiveWindow($rows, [string]$target) {
    foreach ($r in $rows) { if ($r.Target -eq $target) { return $r } }
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

# The seed the manifest records for a window by its id (the IPC name), as a
# string - a seed past Int64 would lose digits as a number - or '' for none.
function Get-ManifestSeed($m, [string]$id) {
    if (-not $m) { return $null }
    foreach ($w in @($m.windows)) {
        if ([string]$w.id -eq $id) {
            if ($null -eq $w.desk_variant) { return '' }
            return [string]$w.desk_variant
        }
    }
    return $null
}

# Every window id that records a seed, with the seed as text.
function Get-Seeds($m) {
    $out = @{}
    if (-not $m) { return $out }
    foreach ($w in @($m.windows)) {
        if ($null -ne $w.desk_variant) { $out[[string]$w.id] = [string]$w.desk_variant }
    }
    return $out
}

function Wait-Manifest([scriptblock]$pred, [int]$timeoutSec = 20) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    do {
        $m = Read-Manifest
        if ($m -and (& $pred $m)) { return $m }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    return (Read-Manifest)
}

# ---- desk pixels -------------------------------------------------------------

# Two desk pixels of a top-level window: the right margin halfway down its
# (single) pane, and the bottom margin under the pane's centre.
function Get-DeskProbe([IntPtr]$top) {
    $panes = @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal' | Where-Object Visible)
    if ($panes.Count -lt 1) { return $null }
    $p = $panes[0]
    $cs = Get-TestWindowRect -Window $top -Client
    $shot = Get-TestWindowPixels -Window $top -Sync
    try {
        if ((Get-TestDistinctColors -Shot $shot) -lt 4) { return $null }
        $rx = [int](($p.Right + $cs.Right) / 2)
        $ry = [int](($p.Top + $p.Bottom) / 2)
        $bx = [int](($p.Left + $p.Right) / 2)
        $by = [int](($p.Bottom + $cs.Bottom) / 2)
        $a = Get-TestPixel -Shot $shot -X $rx -Y $ry
        $b = Get-TestPixel -Shot $shot -X $bx -Y $by
        if ($null -eq $a -or $null -eq $b) { return $null }
        return [pscustomobject]@{
            R = @([int]$a.R, [int]$a.G, [int]$a.B)
            B = @([int]$b.R, [int]$b.G, [int]$b.B)
        }
    } finally { Close-TestWindowPixels $shot }
}

# Total channel distance across both probe points.
function Get-ProbeDistance($x, $y) {
    if ($null -eq $x -or $null -eq $y) { return -1 }
    $d = 0
    for ($k = 0; $k -lt 3; $k++) {
        $d += [math]::Abs($x.R[$k] - $y.R[$k]) + [math]::Abs($x.B[$k] - $y.B[$k])
    }
    return $d
}

function Format-Probe($p) {
    if ($null -eq $p) { return '(no capture)' }
    return "right=($($p.R -join ',')) bottom=($($p.B -join ','))"
}

# -----------------------------------------------------------------------------

$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN
$savedPipe = $env:GHOZTTY_PIPE_SUFFIX
$env:GHOZTTY_PIPE_SUFFIX = "-deskvar$PID"

Stop-RepoInstances
New-Item -ItemType Directory -Force $root | Out-Null
$tmp = Join-Path $root 'app'
New-Item -ItemType Directory -Force (Join-Path $tmp 'ghoztty\local-agent-debug') | Out-Null
$env:LOCALAPPDATA = $tmp
$env:GHOSTTY_LOCAL_AGENT_BIN = $agent

Reset-TestBody
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

# Every window gets the same frame, side by side, so a gradient is sampled at
# the same place in each.
$winW = 760; $winH = 480
function Place([IntPtr]$h, [int]$slot) {
    $x = 10 + ($slot % 3) * ($winW + 10)
    $y = 10 + [math]::Floor($slot / 3) * ($winH + 10)
    [void](Set-TestWindowPos -Window $h -X $x -Y $y -Width $winW -Height $winH)
}

try {
    Assert (Test-Path $exe) 'ghoztty exe exists in zig-out'
    Assert (Test-Path $agent) 'ghoztty-agent exe exists in zig-out'
    [void](Assert-GhozttyIsolatedBuild -Exe $exe)
    if ($NegativeControl) {
        Say 'NEGATIVE CONTROL: claim B is inverted to "the random window paints the ocean" - this run MUST fail'
    }

    # ---- A/B: the startup window, a plain window, two random ones ------------
    Say '== setup: window-1 (startup), plain, rand1, rand2'
    # persistence: on (default) - a throwaway $env:LOCALAPPDATA with no manifest
    # yet, and the relaunch below restores exactly what this launch records.
    $app = Start-App
    Start-Sleep -Seconds 2
    & $exe +new-window --target=plain | Out-Null
    & $exe +new-window --target=rand1 --color=random | Out-Null
    & $exe +new-window --target=rand2 --color=random | Out-Null
    $names = @('window-1', 'plain', 'rand1', 'rand2')
    $live = Wait-Live {
        param($rows)
        return (@($names | Where-Object { -not (Get-LiveWindow $rows $_) }).Count -eq 0)
    } 45
    $missing = @($names | Where-Object { -not (Get-LiveWindow $live $_) })
    if ($missing.Count -gt 0) {
        Write-TestAssertedNothing -Reason "windows never came up: $($missing -join ', ')"
    }
    $hwnd = @{}
    for ($k = 0; $k -lt $names.Count; $k++) {
        $hwnd[$names[$k]] = [IntPtr](Get-LiveWindow $live $names[$k]).Hwnd
        Place $hwnd[$names[$k]] $k
    }
    Start-Sleep -Milliseconds 1200

    $probe = @{}
    foreach ($n in $names) {
        $probe[$n] = Get-DeskProbe $hwnd[$n]
        Say "      $n desk: $(Format-Probe $probe[$n])"
    }
    if (@($names | Where-Object { $null -eq $probe[$_] }).Count -gt 0) {
        $script:skipped++; Say 'SKIP  desk pixel probes: an empty capture'
    } else {
        $dOcean = Get-ProbeDistance $probe['window-1'] $probe['plain']
        Say "      ocean vs ocean distance = $dOcean"
        Assert ($dOcean -le 6) 'A: the startup window and a plain +new-window paint the same ocean desk'
        foreach ($n in @('rand1', 'rand2')) {
            $d = Get-ProbeDistance $probe[$n] $probe['window-1']
            Say "      $n vs ocean distance = $d"
            if ($NegativeControl) {
                Assert ($d -le 6) "NEGATIVE: $n paints the ocean desk"
            } else {
                Assert ($d -gt 24) "B: $n paints its own gradient, not the ocean"
            }
        }
    }

    foreach ($n in @('rand1', 'rand2')) {
        $row = Get-LiveWindow $live $n
        Assert ($row -and -not $row.Tint) "B: $n's terminal kept its theme colour (no background_tint; saw '$($row.Tint)')"
    }

    $m = Wait-Manifest {
        param($mf)
        (Get-ManifestSeed $mf 'rand1') -and (Get-ManifestSeed $mf 'rand2') -and
        ($null -ne (Get-ManifestSeed $mf 'plain'))
    }
    $seeds = Get-Seeds $m
    Say "      manifest: $(@($m.windows).Count) windows; seeds: $(($seeds.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' ')"
    Assert (@($m.windows).Count -eq 4) "A: the manifest records all four windows (got $(@($m.windows).Count))"
    Assert ((Get-ManifestSeed $m 'plain') -eq '') 'A: a plain +new-window records no desk variant'
    Assert ($seeds.Count -eq 2) "A: only the two random windows record a seed - the startup window does not (got $($seeds.Count))"
    Assert ($seeds['rand1'] -and $seeds['rand1'] -ne '0') 'B: rand1 records a non-zero seed'
    Assert ($seeds['rand2'] -and $seeds['rand2'] -ne '0') 'B: rand2 records a non-zero seed'
    Assert ($seeds['rand1'] -ne $seeds['rand2']) 'B: the two random windows have different seeds'

    # ---- C: a window opened by hand -------------------------------------------
    Say '== by hand: the New Window action on window-1'
    $before = @(Get-TestWindows -ProcessId $app.Pid | ForEach-Object { $_.Hwnd })
    $pane1 = @(Get-TestChildWindows -Window $hwnd['window-1'] -Class 'GhozttyTerminal' | Where-Object Visible)[0]
    Assert (Send-TestKeys -Window $hwnd['window-1'] -Target ([IntPtr]$pane1.Hwnd) -Modifiers ctrl, shift -Key F9) 'C: chord delivered'
    $handTop = [IntPtr]::Zero
    for ($t = 0; $t -lt 40 -and $handTop -eq [IntPtr]::Zero; $t++) {
        Start-Sleep -Milliseconds 250
        foreach ($w in @(Get-TestWindows -ProcessId $app.Pid)) {
            if ($before -notcontains $w.Hwnd) { $handTop = [IntPtr]$w.Hwnd }
        }
    }
    Assert ($handTop -ne [IntPtr]::Zero) 'C: the New Window action opened a window'
    if ($handTop -ne [IntPtr]::Zero) {
        Place $handTop 4
        Start-Sleep -Milliseconds 1200
        $ph = Get-DeskProbe $handTop
        Say "      by-hand desk: $(Format-Probe $ph)"
        if ($null -eq $ph) {
            $script:skipped++; Say 'SKIP  by-hand desk probe: empty capture'
        } else {
            $d = Get-ProbeDistance $ph $probe['window-1']
            Say "      by-hand vs ocean distance = $d"
            Assert ($d -gt 24) 'C: the by-hand window paints its own gradient, not the ocean'
        }
        # The by-hand window is auto-named, so it is found by elimination: a
        # third seed, under a window id that is neither random window's.
        $m = Wait-Manifest { param($mf) (Get-Seeds $mf).Count -ge 3 }
        $s3 = Get-Seeds $m
        $extra = @($s3.Keys | Where-Object { $_ -ne 'rand1' -and $_ -ne 'rand2' })
        Say "      seeds now: $(($s3.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' ')"
        Assert ($extra.Count -eq 1 -and $s3[$extra[0]] -ne '0') "C: the by-hand window records a seed of its own ($($extra -join ','))"
        Assert ($extra.Count -eq 1 -and $s3[$extra[0]] -ne $s3['rand1'] -and $s3[$extra[0]] -ne $s3['rand2']) 'C: and it differs from both random windows'
    }

    # ---- D: restore ----------------------------------------------------------
    Say '== restart: kill the app (agent stays), relaunch'
    $seedsBefore = Get-Seeds (Read-Manifest)
    foreach ($r in $script:GhozttyTestDesktopLaunches) { if ($r.Pid -eq $app.Pid) { $r.Killed = $true } }
    Stop-AppOnly
    $restartAt = (Get-Date).ToUniversalTime()
    $app2 = Start-App
    $liveR = Wait-Live {
        param($rows)
        return ((Get-LiveWindow $rows 'rand1') -and (Get-LiveWindow $rows 'rand2'))
    } 60
    foreach ($n in @('rand1', 'rand2')) {
        $row = Get-LiveWindow $liveR $n
        Assert ($null -ne $row) "D: $n came back"
        if (-not $row) { continue }
        $h2 = [IntPtr]$row.Hwnd
        # Its restored frame should already be the one it had; place it anyway
        # so a frame-restore regression cannot read as a gradient change.
        Place $h2 ([array]::IndexOf($names, $n))
        Start-Sleep -Milliseconds 1200
        $p2 = Get-DeskProbe $h2
        Say "      $n desk after restore: $(Format-Probe $p2)"
        if ($null -eq $p2) {
            $script:skipped++; Say "SKIP  $n restored desk probe: empty capture"
        } elseif ($null -ne $probe[$n]) {
            $d = Get-ProbeDistance $p2 $probe[$n]
            Say "      $n before vs after distance = $d"
            Assert ($d -le 6) "D: $n came back with the same gradient"
        }
    }
    $mR = Wait-Manifest {
        param($mf)
        (Get-ManifestSeed $mf 'rand1') -and (Get-ManifestSeed $mf 'rand2') -and
        ((Get-Item (Manifest-Path)).LastWriteTimeUtc -gt $restartAt)
    } 30
    $seedsAfter = Get-Seeds $mR
    foreach ($n in @('rand1', 'rand2')) {
        Assert ($seedsAfter[$n] -and $seedsAfter[$n] -eq $seedsBefore[$n]) "D: the rewritten manifest keeps $n's seed ($($seedsBefore[$n]) -> $($seedsAfter[$n]))"
    }
    foreach ($r in $script:GhozttyTestDesktopLaunches) { if ($r.Pid -eq $app2.Pid) { $r.Killed = $true } }
    Stop-RepoInstances

    # ---- E: flat --------------------------------------------------------------
    Say '== flat: --color=random is the old terminal tint'
    Remove-Item (Manifest-Path) -ErrorAction SilentlyContinue
    $app3 = Start-App @('--macos-pane-style=flat')
    Start-Sleep -Seconds 2
    & $exe +new-window --target=flatrand --color=random | Out-Null
    $liveF = Wait-Live { param($rows) [bool](Get-LiveWindow $rows 'flatrand') } 30
    $row = Get-LiveWindow $liveF 'flatrand'
    Assert ($row -and $row.Tint) "E: flat --color=random tints the terminal (background_tint '$($row.Tint)')"
    $mF = Wait-Manifest { param($mf) $null -ne (Get-ManifestSeed $mf 'flatrand') }
    Assert ((Get-ManifestSeed $mF 'flatrand') -eq '') 'E: and records no desk variant'
    foreach ($r in $script:GhozttyTestDesktopLaunches) { if ($r.Pid -eq $app3.Pid) { $r.Killed = $true } }

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
        update -Guard desk-variant -Repo $repo 2>&1 | ForEach-Object { Say "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Skipped $script:skipped -Label 'DESK VARIANT ACCEPTANCE'
