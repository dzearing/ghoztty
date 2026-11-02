# @timing-sensitive
# T2474 acceptance: a minimized window gives back its panes' render targets,
# and every pane comes back drawn when the window is shown again.
#
# WHY. Mac 1bc34a8d7 shrinks an occluded surface's swap-chain render targets
# to 1x1 (docs/reference/memory.md on main): nothing draws while nobody can
# see the window, yet every pane held window-sized GPU buffers. The shared
# hook (`releaseHiddenTargets`, src/renderer/generic.zig) was Metal-only,
# because OpenGL re-presents its last target on a frame with nothing new to
# draw - freeing it there would put garbage on screen. On Windows each pane's
# offscreen target is a renderbuffer rounded up to 256 px steps (T2577): a
# 1400x900 window split four ways holds four ~768x512 targets, ~6 MB, and a
# maximized 4K pane alone ~35 MB.
#
# The Windows translation frees the targets only when the WINDOW is hidden
# (minimized, cloaked, covered - `Window.applyOcclusion` and WM_SIZE
# SIZE_MINIMIZED), never when a pane is merely behind another tab: hero mode
# reads background tabs' targets for its carousel. And a released renderer
# redraws in full on its first frame back, instead of re-presenting a target
# that is gone.
#
# HOW. One window, four terminal panes, each showing text. Sample GPU memory
# shown, minimized and restored, -Cycles times, and capture every pane through
# the debug `capture-pane` IPC action after each restore (it reads the pane's
# last presented target, so a pane that never redrew reads as no frame at
# all, and one that redrew blank reads as a single colour).
#
#   A1  minimizing gives back at least half of what the four targets hold
#   A2  restoring takes it back (the panes really are drawing again)
#   A3  every pane, after every restore, captures at its own size with text
#   A4  no growth across the cycles (the last restored sample vs the first)
#   A5  the release and the redraw are in the log (the mechanism, not a
#       coincidence of the driver trimming memory)
#   C1  a window fully covered by another releases its pane's targets too
#   C2  and redraws in full once uncovered
#
# Memory is DEDICATED GPU memory, where the driver keeps a renderbuffer; the
# bar is a third of the computed storage, because the driver does not hand a
# freed renderbuffer back byte for byte (measured 2026-11-02 on this box:
# four panes in a 1400x900 window, ~6 MB of storage, 5.0 MB back on every
# minimize and 5.0 MB re-taken on restore, flat over four cycles).
#
# -NegativeControl leaves the window on screen where each cycle would have
# minimized it: A1 and A5 MUST go red, which is the proof this meter can see
# the release at all.
#
# Only touches ghoztty processes running from this repo's zig-out*.
#   powershell -NoProfile -File test\win32\hidden-window-memory.ps1
param([string]$ExePath, [int]$Cycles = 4, [switch]$NegativeControl, [switch]$Interactive)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }

$env:GHOZTTY_PIPE_SUFFIX = "-hidwinmem$PID"
$errlog = Join-Path $env:TEMP "ghoztty-hidden-window-memory-$PID.log"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\ProcessMemory.ps1')
. (Join-Path $PSScriptRoot 'lib\PaneCapture.ps1')

$script:pass = 0
$script:fail = 0
$script:skipped = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Invoke-Verb([string[]]$VerbArgs) {
    $out = @(& $exe @VerbArgs 2>&1 | ForEach-Object { "$_" }) -join "`n"
    return [pscustomobject]@{ Code = $LASTEXITCODE; Text = $out.Trim() }
}

# Lines in the app's log that match, counted (the log is the app's stderr).
function Get-LogCount([string]$Pattern) {
    if (-not (Test-Path $errlog)) { return 0 }
    return @(Select-String -Path $errlog -Pattern $Pattern -SimpleMatch -ErrorAction SilentlyContinue).Count
}

# The bytes one pane's offscreen target holds: RGBA8, each side rounded up to
# the 256 px storage step (`Target.capacityFor`, T2577).
function Get-TargetBytes([int]$W, [int]$H) {
    $cw = [math]::Ceiling([math]::Max($W, 1) / 256) * 256
    $ch = [math]::Ceiling([math]::Max($H, 1) / 256) * 256
    return [double]($cw * $ch * 4)
}

$panes = @('hwm1', 'hwm2', 'hwm3', 'hwm4')

# Capture every pane; returns one row per pane (size + colour count, or the
# reason the capture failed).
function Get-PaneShots {
    $rows = @()
    foreach ($p in $panes) {
        $shot = Get-TestPaneCapture -Target $p
        if (-not $shot) {
            $rows += [pscustomobject]@{ Pane = $p; Ok = $false; W = 0; H = 0; Colors = 0; Why = (Get-LastPaneCaptureError) }
            continue
        }
        $n = Get-TestPaneColorCount -Shot $shot
        $rows += [pscustomobject]@{ Pane = $p; Ok = $true; W = $shot.Width; H = $shot.Height; Colors = $n; Why = '' }
        Close-TestPaneCapture $shot
    }
    return $rows
}

[void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
Start-TestForegroundWatch
[void](New-TestDesktop -Interactive:$Interactive)

try {
    $launchArgs = @('--config-default-files=false', '--session-persistence=false', '--confirm-close-surface=false')
    $app = Start-OnTestDesktop -Exe $exe -StdErr $errlog -Arguments $launchArgs
    $appPid = $app.Pid
    Assert (-not (Test-TestDesktopLeak -ProcessId $appPid)) 'GUI is NOT enumerable on the interactive desktop'
    $top = Wait-TestWindow -ProcessId $appPid -Class 'GhozttyWindow' -TimeoutMs 20000
    if ($top -eq [IntPtr]::Zero) { throw 'no window appeared' }
    $anchor = $top
    Start-Sleep -Seconds 2

    # The measured window is a SECOND one, so the anchor stays on screen the
    # whole run: the release must be scoped to the window that was hidden.
    $r = Invoke-Verb @('+new-window', '--target=hwmwin', "--name=$($panes[0])")
    $top = [IntPtr]::Zero
    $deadline = (Get-Date).AddSeconds(20)
    while ($top -eq [IntPtr]::Zero -and (Get-Date) -lt $deadline) {
        foreach ($w in @(Get-TestWindows -ProcessId $appPid -Class 'GhozttyWindow')) {
            if ([int64]$w.Hwnd -ne [int64]$anchor) { $top = [IntPtr][int64]$w.Hwnd }
        }
        if ($top -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 250 }
    }
    if ($top -eq [IntPtr]::Zero) { throw "the measured window did not open ($($r.Text))" }
    # Side by side, never overlapping: a measured window that covers the
    # anchor makes the anchor's pane release and re-create ITS target on every
    # minimize and restore, which is the covered case (section C) muddying
    # the minimize numbers.
    $wa = Get-TestWorkArea
    $mw = [math]::Min(1400, [int]($wa.Width * 0.7))
    $mh = [math]::Min(900, $wa.Height - 40)
    [void](Set-TestWindowPos -Window $top -X ($wa.Left + 10) -Y ($wa.Top + 10) -Width $mw -Height $mh)
    $aw = [math]::Min(420, $wa.Width - $mw - 40)
    $ax = $wa.Left + $mw + 30
    [void](Set-TestWindowPos -Window $anchor -X $ax -Y ($wa.Top + 10) -Width $aw -Height 300)
    Start-Sleep -Seconds 1
    $r = Invoke-Verb @('+split', "--target=$($panes[0])", "--name=$($panes[1])", '--direction=right')
    if ($r.Code -ne 0) { throw "+split 2 failed: $($r.Text)" }
    $r = Invoke-Verb @('+split', "--target=$($panes[0])", "--name=$($panes[2])", '--direction=down')
    if ($r.Code -ne 0) { throw "+split 3 failed: $($r.Text)" }
    $r = Invoke-Verb @('+split', "--target=$($panes[1])", "--name=$($panes[3])", '--direction=down')
    if ($r.Code -ne 0) { throw "+split 4 failed: $($r.Text)" }
    foreach ($p in $panes) {
        [void](Invoke-Verb @('+send-keys', "--target=$p", "echo hidden-window-memory $p`r"))
    }
    Start-Sleep -Seconds 3

    $gpuReadable = $null -ne (Get-GpuBytes $appPid)
    Write-Host "GPU process-memory counters readable: $gpuReadable"

    $before = Get-PaneShots
    $expect = 0.0
    foreach ($b in $before) {
        Write-Host ("  pane {0}: {1}x{2}, {3} colours {4}" -f $b.Pane, $b.W, $b.H, $b.Colors, $b.Why)
        if ($b.Ok) { $expect += Get-TargetBytes $b.W $b.H }
    }
    Assert (@($before | Where-Object { $_.Ok -and $_.Colors -gt 2 }).Count -eq $panes.Count) 'all four panes draw text before the first minimize'
    $expectMB = [math]::Round($expect / 1MB, 1)
    Write-Host "four targets hold about $expectMB MB"

    $releasedBefore = Get-LogCount 'released hidden render targets'
    $redrawBefore = Get-LogCount 'redrawing after a hidden release'
    $rows = @()
    $shotsOk = $true
    $shotWhy = ''
    for ($i = 1; $i -le $Cycles; $i++) {
        $shown = Wait-Settled $appPid "shown $i"
        if ($NegativeControl) {
            Start-Sleep -Seconds 3
        } else {
            [void](Send-TestSysCommand -Window ([IntPtr]$top) -Command minimize)
            Start-Sleep -Seconds 3
        }
        $hidden = Wait-Settled $appPid "minimized $i"
        if (-not $NegativeControl) {
            [void](Send-TestSysCommand -Window ([IntPtr]$top) -Command restore)
        }
        Start-Sleep -Seconds 3
        $restored = Wait-Settled $appPid "restored $i"
        $rows += $shown, $hidden, $restored
        foreach ($s in (Get-PaneShots)) {
            $want = $before | Where-Object { $_.Pane -eq $s.Pane }
            if (-not $s.Ok -or $s.Colors -le 2 -or $s.W -ne $want.W -or $s.H -ne $want.H) {
                $shotsOk = $false
                $shotWhy = "cycle ${i} pane $($s.Pane): ok=$($s.Ok) $($s.W)x$($s.H) colours=$($s.Colors) $($s.Why)"
            }
        }
    }
    $rows | Format-Table Label, GpuDedMB, GpuShMB, PrivMB, Threads -AutoSize | Out-String | Write-Host

    # Dedicated memory, where the driver puts a renderbuffer. Shared memory
    # moves on its own across a minimize/restore with or without the release
    # (T2637), so it is reported above and not scored.
    if ($gpuReadable) {
        $drops = @(); $backs = @()
        for ($k = 0; $k -lt $rows.Count; $k += 3) {
            $drops += [double]$rows[$k].GpuDedMB - [double]$rows[$k + 1].GpuDedMB
            $backs += [double]$rows[$k + 2].GpuDedMB - [double]$rows[$k + 1].GpuDedMB
        }
        $minDrop = ($drops | Measure-Object -Minimum).Minimum
        $minBack = ($backs | Measure-Object -Minimum).Minimum
        $bar = [math]::Round($expectMB / 3, 1)
        Assert ($minDrop -ge $bar) "A1 every minimize gives back at least a third of the ~$expectMB MB the targets hold (smallest drop $([math]::Round($minDrop,1)) MB, bar $bar)"
        Assert ($minBack -ge $bar) "A2 every restore takes it back (smallest regain $([math]::Round($minBack,1)) MB, bar $bar)"
        $first = [double]$rows[2].GpuDedMB
        $last = [double]$rows[-1].GpuDedMB
        Assert (($last - $first) -le [math]::Max(1.0, $bar)) "A4 no dedicated GPU growth across $Cycles cycles (first restored $first MB, last $last MB)"
    } else {
        $script:skipped++
        Write-Host 'SKIP  A1/A2/A4: the GPU Process Memory counters are not readable on this box'
    }
    Assert $shotsOk "A3 every pane captures at its own size with text after every restore $shotWhy"
    $released = (Get-LogCount 'released hidden render targets') - $releasedBefore
    $redrawn = (Get-LogCount 'redrawing after a hidden release') - $redrawBefore
    Assert ($released -ge $panes.Count * $Cycles) "A5 every pane released its targets on every minimize ($released of $($panes.Count * $Cycles) log lines)"
    Assert ($redrawn -ge $panes.Count * $Cycles) "A5 every pane redrew in full on every restore ($redrawn of $($panes.Count * $Cycles) log lines)"

    # ---- C: a window covered by another gives its targets back too --------
    # The visibility poll (T1951) reads the anchor as hidden once the measured
    # window covers every pixel of it; uncovered, it draws again.
    if (-not $NegativeControl) {
        $relC = Get-LogCount 'released hidden render targets'
        $drwC = Get-LogCount 'redrawing after a hidden release'
        [void](Set-TestWindowPos -Window $anchor -X ($wa.Left + 60) -Y ($wa.Top + 60) -Width 300 -Height 200)
        Start-Sleep -Seconds 3
        $relC2 = Get-LogCount 'released hidden render targets'
        Assert ($relC2 -gt $relC) "C1 a window fully covered by another releases its pane's targets ($($relC2 - $relC) log lines)"
        [void](Set-TestWindowPos -Window $anchor -X $ax -Y ($wa.Top + 10) -Width $aw -Height 300)
        Start-Sleep -Seconds 3
        $drwC2 = Get-LogCount 'redrawing after a hidden release'
        Assert ($drwC2 -gt $drwC) "C2 uncovered, it redraws in full ($($drwC2 - $drwC) log lines)"
    }

    $crashed = (Test-Path $errlog) -and (Select-String -Path $errlog -Pattern 'Segmentation fault|panic' -Quiet)
    Assert (-not $crashed) 'B1 no segfault or panic in the app log'
    Assert (-not (Test-TestDesktopLeak -ProcessId $appPid)) 'B2 GUI never became visible on the interactive desktop'
} catch {
    $script:fail++
    Write-Host "FAIL  aborted: $($_.Exception.Message)" -ForegroundColor Red
} finally {
    [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
    Remove-TestDesktop
}

$fgSeen = @(Stop-TestForegroundWatch)
$leaked = @(Get-TestLaunchedPids | Where-Object { $fgSeen -contains $_ })
Assert ($leaked.Count -eq 0) "no test-desktop app ever became foreground on the interactive desktop (saw $($leaked -join ','))"

if ($NegativeControl) {
    if ($script:fail -gt 0) { Write-Host "NEGATIVE CONTROL OK: $($script:fail) assert(s) went red with the window left on screen"; exit 0 }
    Write-Host 'NEGATIVE CONTROL FAILED: nothing went red with the window left on screen' -ForegroundColor Red
    exit 1
}
# A green run stamps the covered files (T783); a short run, or one that could
# not read the GPU counters, answers a narrower question than the guard asks.
if ($script:fail -eq 0 -and $script:skipped -eq 0 -and $Cycles -ge 4) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard hidden-window-memory -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}
if ($script:fail -eq 0) { Write-Host "ALL PASS ($($script:pass) passed, $($script:skipped) skipped)"; exit 0 }
Write-Host "$($script:fail) FAILURE(S) ($($script:pass) passed)"
exit 1
