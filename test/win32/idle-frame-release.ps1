# @timing-sensitive
# T3103 acceptance: a pane on screen that stops drawing gives back its render
# target and font-atlas copies after 3 s, keeps showing its picture, and draws
# in full again on the next keystroke.
#
# WHY. Mac 8b0de569b: a pane that is sitting still kept full-size render
# targets and copies of both font atlases for frames it was not drawing; only
# hidden surfaces gave their targets back (T2474/T2975 on Windows). After 3 s
# without a real draw the frames now release both (Mac: IOSurface 337 -> 143 MB
# on 21 idle panes). The shared hook is `releaseIdleFrames` in
# src/renderer/generic.zig; on Windows OpenGL opts in through
# `releaseIdleTargetsNow` (src/renderer/OpenGL.zig). Nothing is presented by
# the release, so the window keeps showing its last frame; the next frame -
# even one with nothing new - draws in full rather than re-presenting a target
# that is gone.
#
# HOW. One window, four cmd panes. Each cycle every pane prints a line a
# second for ~8 s (drawing, so it must KEEP its target), then sits still.
#
#   N1  no pane releases while it is printing once a second
#   I1  every pane releases within a few seconds of going still (log line,
#       naming what it gave back: the T3103 frame-memory readout)
#   A1  dedicated GPU memory drops from printing to still by at least a third
#       of what the four targets hold
#   I2  the first keystroke into a released pane redraws it in full, before
#       anything else asks it to draw
#   I3  after every idle release every pane captures at its own size with
#       text (capture-pane reads a frame drawn for it - the hero-mode path)
#   H1  a pane released idle, then minimized and restored, redraws and
#       captures with text (the hidden release finds nothing left to free)
#   B1  no panic; B2/B3 nothing leaks to the interactive desktop
#
# The on-screen picture between the release and the next frame cannot be read
# from the background desktop (PrintWindow of a GL child is a flat fill, see
# lib\PaneCapture.ps1), so "not blanked" is held by the mechanism: I2 and I3
# prove no frame presents a released target, and the release itself presents
# nothing.
#
# -NegativeControl runs with GHOZTTY_IDLE_FRAME_RELEASE=0: I1 and A1 MUST go
# red, the proof this meter can see the release at all.
#
# Only touches ghoztty processes running from this repo's zig-out*.
#   powershell -NoProfile -File test\win32\idle-frame-release.ps1
param([string]$ExePath, [int]$Cycles = 3, [switch]$NegativeControl, [switch]$Interactive)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }

$env:GHOZTTY_PIPE_SUFFIX = "-idlefr$PID"
if ($NegativeControl) { $env:GHOZTTY_IDLE_FRAME_RELEASE = '0' } else { Remove-Item Env:GHOZTTY_IDLE_FRAME_RELEASE -ErrorAction SilentlyContinue }
$errlog = Join-Path $env:TEMP "ghoztty-idle-frame-release-$PID.log"

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

function Get-LogLines([string]$Pattern) {
    if (-not (Test-Path $errlog)) { return @() }
    return @(Select-String -Path $errlog -Pattern $Pattern -SimpleMatch -ErrorAction SilentlyContinue)
}
function Get-LogCount([string]$Pattern) { return @(Get-LogLines $Pattern).Count }

# RGBA8, each side rounded up to the 256 px storage step (T2577).
function Get-TargetBytes([int]$W, [int]$H) {
    $cw = [math]::Ceiling([math]::Max($W, 1) / 256) * 256
    $ch = [math]::Ceiling([math]::Max($H, 1) / 256) * 256
    return [double]($cw * $ch * 4)
}

function Get-DedMB([int]$ProcessId) {
    $g = Get-GpuBytes $ProcessId
    if (-not $g) { return $null }
    return [math]::Round($g.Dedicated / 1MB, 1)
}

$panes = @('ifr1', 'ifr2', 'ifr3', 'ifr4')
$relPat = 'released idle render targets'
$drwPat = 'redrawing after an idle release'

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

function Test-Shots($Shots, $Want, [ref]$Why) {
    foreach ($s in $Shots) {
        $w = $Want | Where-Object { $_.Pane -eq $s.Pane }
        if (-not $s.Ok -or $s.Colors -le 2 -or $s.W -ne $w.W -or $s.H -ne $w.H) {
            $Why.Value = "pane $($s.Pane): ok=$($s.Ok) $($s.W)x$($s.H) colours=$($s.Colors) $($s.Why)"
            return $false
        }
    }
    return $true
}

# One line a second for ~8 s in every pane (cmd has no sleep; ping waits).
function Start-Printing {
    foreach ($p in $panes) {
        [void](Invoke-Verb @('+send-keys', "--target=$p", "for /l %i in (1,1,8) do @(echo idle-frame-release $p tick %i & ping -n 2 127.0.0.1 >nul)`r"))
    }
}

[void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
Start-TestForegroundWatch
[void](New-TestDesktop -Interactive:$Interactive)

try {
    $launchArgs = @('--config-default-files=false', '--session-persistence=false', '--confirm-close-surface=false',
        '--command=cmd.exe')
    $app = Start-OnTestDesktop -Exe $exe -StdErr $errlog -Arguments $launchArgs
    $appPid = $app.Pid
    Assert (-not (Test-TestDesktopLeak -ProcessId $appPid)) 'B2 GUI is NOT enumerable on the interactive desktop'
    $anchor = Wait-TestWindow -ProcessId $appPid -Class 'GhozttyWindow' -TimeoutMs 20000
    if ($anchor -eq [IntPtr]::Zero) { throw 'no window appeared' }
    Start-Sleep -Seconds 2

    $r = Invoke-Verb @('+new-window', '--target=ifrwin', "--name=$($panes[0])")
    $top = [IntPtr]::Zero
    $deadline = (Get-Date).AddSeconds(20)
    while ($top -eq [IntPtr]::Zero -and (Get-Date) -lt $deadline) {
        foreach ($w in @(Get-TestWindows -ProcessId $appPid -Class 'GhozttyWindow')) {
            if ([int64]$w.Hwnd -ne [int64]$anchor) { $top = [IntPtr][int64]$w.Hwnd }
        }
        if ($top -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 250 }
    }
    if ($top -eq [IntPtr]::Zero) { throw "the measured window did not open ($($r.Text))" }
    $wa = Get-TestWorkArea
    $mw = [math]::Min(1400, [int]($wa.Width * 0.7))
    $mh = [math]::Min(900, $wa.Height - 40)
    [void](Set-TestWindowPos -Window $top -X ($wa.Left + 10) -Y ($wa.Top + 10) -Width $mw -Height $mh)
    $aw = [math]::Min(420, $wa.Width - $mw - 40)
    [void](Set-TestWindowPos -Window $anchor -X ($wa.Left + $mw + 30) -Y ($wa.Top + 10) -Width $aw -Height 300)
    Start-Sleep -Seconds 1
    $r = Invoke-Verb @('+split', "--target=$($panes[0])", "--name=$($panes[1])", '--direction=right')
    if ($r.Code -ne 0) { throw "+split 2 failed: $($r.Text)" }
    $r = Invoke-Verb @('+split', "--target=$($panes[0])", "--name=$($panes[2])", '--direction=down')
    if ($r.Code -ne 0) { throw "+split 3 failed: $($r.Text)" }
    $r = Invoke-Verb @('+split', "--target=$($panes[1])", "--name=$($panes[3])", '--direction=down')
    if ($r.Code -ne 0) { throw "+split 4 failed: $($r.Text)" }
    foreach ($p in $panes) {
        [void](Invoke-Verb @('+send-keys', "--target=$p", "echo idle-frame-release $p`r"))
    }
    Start-Sleep -Seconds 2

    $gpuReadable = $null -ne (Get-GpuBytes $appPid)
    Write-Host "GPU process-memory counters readable: $gpuReadable"

    $before = Get-PaneShots
    $expect = 0.0
    foreach ($b in $before) {
        Write-Host ("  pane {0}: {1}x{2}, {3} colours {4}" -f $b.Pane, $b.W, $b.H, $b.Colors, $b.Why)
        if ($b.Ok) { $expect += Get-TargetBytes $b.W $b.H }
    }
    Assert (@($before | Where-Object { $_.Ok -and $_.Colors -gt 2 }).Count -eq $panes.Count) 'all four panes draw text at the start'
    $expectMB = [math]::Round($expect / 1MB, 1)
    Write-Host "four targets hold about $expectMB MB"

    $n1Ok = $true; $n1Why = ''
    $i1Ok = $true; $i1Why = ''
    $i3Ok = $true; $i3Why = ''
    $drops = @()
    for ($i = 1; $i -le $Cycles; $i++) {
        Start-Printing
        Start-Sleep -Seconds 1
        $relStart = Get-LogCount $relPat
        Start-Sleep -Seconds 3
        $active = Get-DedMB $appPid
        $relActive = (Get-LogCount $relPat) - $relStart
        if ($relActive -gt 0) { $n1Ok = $false; $n1Why = "cycle ${i}: $relActive release(s) while printing" }
        # The loop ends ~8 s in; 3 s of stillness after that releases.
        Start-Sleep -Seconds 11
        $idle = Get-DedMB $appPid
        $rel = (Get-LogCount $relPat) - $relStart
        if ($rel -lt $panes.Count) { $i1Ok = $false; $i1Why = "cycle ${i}: $rel of $($panes.Count) panes released" }
        Write-Host ("  cycle {0}: dedicated GPU printing {1} MB -> still {2} MB, {3} idle release line(s)" -f $i, $active, $idle, $rel)
        if ($null -ne $active -and $null -ne $idle) { $drops += ($active - $idle) }
        $why = ''
        if (-not (Test-Shots (Get-PaneShots) $before ([ref]$why))) { $i3Ok = $false; $i3Why = "cycle ${i} $why" }
    }
    Assert $n1Ok "N1 no pane releases while it prints once a second $n1Why"
    Assert $i1Ok "I1 every pane releases within seconds of going still $i1Why"
    $readout = @(Get-LogLines $relPat | Select-Object -Last 1)
    if ($readout.Count -gt 0) { Write-Host "  readout: $($readout[0].Line.Trim())" }
    if ($gpuReadable -and $drops.Count -eq $Cycles) {
        $minDrop = ($drops | Measure-Object -Minimum).Minimum
        $bar = [math]::Round($expectMB / 3, 1)
        Assert ($minDrop -ge $bar) "A1 every still spell gives back at least a third of the ~$expectMB MB the targets hold (smallest drop $([math]::Round($minDrop,1)) MB, bar $bar)"
    } else {
        $script:skipped++
        Write-Host 'SKIP  A1: the GPU Process Memory counters are not readable on this box'
    }
    Assert $i3Ok "I3 every pane captures at its own size with text after every idle release $i3Why"

    # ---- I2: the first keystroke into a released pane redraws it ----------
    Start-Sleep -Seconds 5
    $drw0 = Get-LogCount $drwPat
    [void](Invoke-Verb @('+send-keys', "--target=$($panes[0])", "echo woke`r"))
    Start-Sleep -Seconds 2
    $drw1 = Get-LogCount $drwPat
    Assert ($drw1 -gt $drw0) "I2 the first keystroke after an idle release redraws the pane in full ($($drw1 - $drw0) log line(s))"

    # ---- H: released idle, then hidden and shown again --------------------
    if (-not $NegativeControl) {
        Start-Sleep -Seconds 5
        [void](Send-TestSysCommand -Window ([IntPtr]$top) -Command minimize)
        Start-Sleep -Seconds 3
        [void](Send-TestSysCommand -Window ([IntPtr]$top) -Command restore)
        Start-Sleep -Seconds 3
        $why = ''
        $hOk = Test-Shots (Get-PaneShots) $before ([ref]$why)
        Assert $hOk "H1 released idle, minimized and restored, every pane captures with text $why"
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
    Remove-Item Env:GHOZTTY_IDLE_FRAME_RELEASE -ErrorAction SilentlyContinue
}

$fgSeen = @(Stop-TestForegroundWatch)
$leaked = @(Get-TestLaunchedPids | Where-Object { $fgSeen -contains $_ })
Assert ($leaked.Count -eq 0) "B3 no test-desktop app ever became foreground on the interactive desktop (saw $($leaked -join ','))"

if ($NegativeControl) {
    if ($script:fail -gt 0) { Write-Host "NEGATIVE CONTROL OK: $($script:fail) assert(s) went red with the idle release off"; exit 0 }
    Write-Host 'NEGATIVE CONTROL FAILED: nothing went red with the idle release off' -ForegroundColor Red
    exit 1
}
if ($script:fail -eq 0 -and $script:skipped -eq 0 -and $Cycles -ge 3) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard idle-frame-release -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}
if ($script:fail -eq 0) { Write-Host "ALL PASS ($($script:pass) passed, $($script:skipped) skipped)"; exit 0 }
Write-Host "$($script:fail) FAILURE(S) ($($script:pass) passed)"
exit 1
