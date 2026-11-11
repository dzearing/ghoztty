# @timing-sensitive
# T2914 acceptance: a pane added to a window nobody can see starts hidden, and
# no pane of that window draws until the window shows.
#
# WHY. Mac 68a8344f0 starts a terminal added to a hidden window hidden
# (surfaceTreeDidChange -> updateSeen), so it never allocates render targets
# it will not draw into. On Windows every layout pass - and a +split is one -
# marked every pane of the window visible again, and the visibility poll
# (T1951, every 250 ms) hid them on its next tick: up to a quarter second of
# frames nobody saw, with the existing panes taking their released targets
# back (T2474) and giving them up again. `PaneView.setVisible` now holds a
# hidden window's panes, and a window shown by restore, activation or a
# close-undo re-asks at once instead of waiting for the poll.
#
# HOW. One anchor window and one measured window with a pane in it. The
# renderer logs 'redrawing after a hidden release' on the first frame a
# released pane draws again, which is exactly the frame a layout pass in a
# hidden window used to cause.
#
#   A1  minimized: a +split into the window redraws no pane while it stays
#       minimized (a guard: a minimized window's layout already bailed on its
#       0x0 client, so this held before T2914 too)
#   A2  and releases at most one target (the new pane's own) - the existing
#       pane is not handed its target back to give it up again
#   A3  restored: the new pane draws, with the text sent to it while hidden
#   A4  and the restore redraws (the positive control: the meter sees redraws)
#   B0  covered by a window of EXACTLY its frame, the window counts as hidden
#       (Mac's AppKit pitfall in 68a8344f0; ours unions the cover rects)
#   B1  covered: a +split redraws no pane while it stays covered (THE
#       defect: with the hold disabled - `occlusion.paneShows` returning
#       `wanted` - B1 read 2 redraw lines and B2 3 releases, 2026-11-11)
#   B2  and releases at most the new pane's target
#   B3  uncovered: the new pane draws, with its text
#   B4  and the reveal redraws (positive control)
#   X1  no segfault or panic; X2 the GUI never reached the interactive desktop
#
# Only touches ghoztty processes running from this repo's zig-out*.
#   powershell -NoProfile -File test\win32\hidden-new-pane.ps1
param([string]$ExePath, [switch]$Interactive)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }

$env:GHOZTTY_PIPE_SUFFIX = "-hidnewpane$PID"
$errlog = Join-Path $env:TEMP "ghoztty-hidden-new-pane-$PID.log"
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\PaneCapture.ps1')

$script:pass = 0
$script:fail = 0
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

$REL = 'released hidden render targets'
$DRW = 'redrawing after a hidden release'

# Does the pane draw text? A capture with more than two colours is text on a
# background; a pane that never drew captures as nothing or as one colour.
function Test-PaneDraws([string]$Pane, [int]$TimeoutSec = 8) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $why = ''
    do {
        $shot = Get-TestPaneCapture -Target $Pane
        if ($shot) {
            $n = Get-TestPaneColorCount -Shot $shot
            Close-TestPaneCapture $shot
            if ($n -gt 2) { return [pscustomobject]@{ Ok = $true; Why = "$n colours" } }
            $why = "$n colours"
        } else {
            $why = Get-LastPaneCaptureError
        }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    return [pscustomobject]@{ Ok = $false; Why = $why }
}

# Split a pane off $Anchor while its window is hidden, send it text, and
# return what the log says happened meanwhile.
function Invoke-HiddenSplit([string]$Anchor, [string]$Name, [string]$Dir) {
    $rel0 = Get-LogCount $REL
    $drw0 = Get-LogCount $DRW
    $r = Invoke-Verb @('+split', "--pane=$Anchor", "--name=$Name", "--direction=$Dir")
    if ($r.Code -ne 0) { throw "+split $Name failed: $($r.Text)" }
    [void](Invoke-Verb @('+send-keys', "--target=$Name", "echo hidden-new-pane $Name`r"))
    # Many visibility polls (250 ms each), and time for a shell to start.
    Start-Sleep -Seconds 3
    return [pscustomobject]@{
        Released = (Get-LogCount $REL) - $rel0
        Redrawn  = (Get-LogCount $DRW) - $drw0
    }
}

[void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
Start-TestForegroundWatch
[void](New-TestDesktop -Interactive:$Interactive)

try {
    $launchArgs = @('--config-default-files=false', '--session-persistence=false', '--confirm-close-surface=false')
    $app = Start-OnTestDesktop -Exe $exe -StdErr $errlog -Arguments $launchArgs
    $appPid = $app.Pid
    $anchor = Wait-TestWindow -ProcessId $appPid -Class 'GhozttyWindow' -TimeoutMs 20000
    if ($anchor -eq [IntPtr]::Zero) { throw 'no window appeared' }
    Start-Sleep -Seconds 2

    $r = Invoke-Verb @('+new-window', '--target=hnpwin', '--name=hnp1')
    $top = [IntPtr]::Zero
    $deadline = (Get-Date).AddSeconds(20)
    while ($top -eq [IntPtr]::Zero -and (Get-Date) -lt $deadline) {
        foreach ($w in @(Get-TestWindows -ProcessId $appPid -Class 'GhozttyWindow')) {
            if ([int64]$w.Hwnd -ne [int64]$anchor) { $top = [IntPtr][int64]$w.Hwnd }
        }
        if ($top -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 250 }
    }
    if ($top -eq [IntPtr]::Zero) { throw "the measured window did not open ($($r.Text))" }
    # Side by side, never overlapping, so only the section's own hiding hides.
    $wa = Get-TestWorkArea
    $mw = [math]::Min(1100, [int]($wa.Width * 0.6))
    # Tall enough that a pane split down is never tucked by the stacked
    # layout (a tucked pane draws nothing, hidden window or not).
    $mh = $wa.Height - 40
    Write-Host "  work area $($wa.Width)x$($wa.Height), measured window ${mw}x$mh"
    [void](Set-TestWindowPos -Window $top -X ($wa.Left + 10) -Y ($wa.Top + 10) -Width $mw -Height $mh)
    $ax = $wa.Left + $mw + 30
    $aw = [math]::Min(420, $wa.Width - $mw - 40)
    [void](Set-TestWindowPos -Window $anchor -X $ax -Y ($wa.Top + 10) -Width $aw -Height 300)
    [void](Invoke-Verb @('+send-keys', '--target=hnp1', "echo hidden-new-pane hnp1`r"))
    Start-Sleep -Seconds 3
    $d = Test-PaneDraws 'hnp1'
    if (-not $d.Ok) { throw "setup: the measured window's first pane does not draw ($($d.Why))" }

    # ---- A: minimized --------------------------------------------------------
    Write-Host '== A: a +split into a minimized window'
    [void](Send-TestSysCommand -Window $top -Command minimize)
    Start-Sleep -Seconds 2
    $a = Invoke-HiddenSplit 'hnp1' 'hnp2' 'right'
    Write-Host "  while minimized: released=$($a.Released) redrawn=$($a.Redrawn)"
    Assert ($a.Redrawn -eq 0) "A1 minimized: the split redraws no pane ($($a.Redrawn) redraw lines)"
    Assert ($a.Released -le 1) "A2 and releases at most the new pane's target ($($a.Released) release lines)"
    $drwA = Get-LogCount $DRW
    [void](Send-TestSysCommand -Window $top -Command restore)
    $d = Test-PaneDraws 'hnp2'
    Assert $d.Ok "A3 restored: the new pane draws its text ($($d.Why))"
    Assert ((Get-LogCount $DRW) -gt $drwA) "A4 the restore redraws (positive control: $((Get-LogCount $DRW) - $drwA) lines)"

    # ---- B: covered by a window of exactly its frame -------------------------
    Write-Host '== B: a +split into a window covered by one of exactly its frame'
    $rel0 = Get-LogCount $REL
    # --focus: a window opened with it is the top of the z-order, so it covers.
    $r = Invoke-Verb @('+new-window', '--target=hnpcov', '--name=hnpc', '--focus')
    if ($r.Code -ne 0) { throw "the covering window did not open: $($r.Text)" }
    $cov = [IntPtr]::Zero
    $deadline = (Get-Date).AddSeconds(20)
    while ($cov -eq [IntPtr]::Zero -and (Get-Date) -lt $deadline) {
        foreach ($w in @(Get-TestWindows -ProcessId $appPid -Class 'GhozttyWindow')) {
            if ([int64]$w.Hwnd -ne [int64]$anchor -and [int64]$w.Hwnd -ne [int64]$top) { $cov = [IntPtr][int64]$w.Hwnd }
        }
        if ($cov -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 250 }
    }
    if ($cov -eq [IntPtr]::Zero) { throw 'the covering window did not appear' }
    $m = @(Get-TestWindows -ProcessId $appPid -Class 'GhozttyWindow') | Where-Object { [int64]$_.Hwnd -eq [int64]$top } | Select-Object -First 1
    [void](Set-TestWindowPos -Window $cov -X $m.Left -Y $m.Top -Width $m.Width -Height $m.Height)
    Start-Sleep -Seconds 2
    $c = @(Get-TestWindows -ProcessId $appPid -Class 'GhozttyWindow') | Where-Object { [int64]$_.Hwnd -eq [int64]$cov } | Select-Object -First 1
    Write-Host "  measured $($m.Left),$($m.Top)-$($m.Right),$($m.Bottom)  cover $($c.Left),$($c.Top)-$($c.Right),$($c.Bottom)"
    Write-Host ("  z: cover={0} measured={1}" -f (Get-TestZIndex -Window $cov), (Get-TestZIndex -Window $top))
    $exact = ($c.Left -eq $m.Left -and $c.Top -eq $m.Top -and $c.Right -eq $m.Right -and $c.Bottom -eq $m.Bottom)
    $covRel = (Get-LogCount $REL) - $rel0
    Assert ($exact -and $covRel -ge 2) "B0 a window behind one of exactly its frame counts as hidden (exact=$exact, $covRel release lines for its 2 panes)"
    $b = Invoke-HiddenSplit 'hnp1' 'hnp3' 'down'
    Write-Host "  while covered: released=$($b.Released) redrawn=$($b.Redrawn)"
    Assert ($b.Redrawn -eq 0) "B1 covered: the split redraws no pane ($($b.Redrawn) redraw lines)"
    Assert ($b.Released -le 1) "B2 and releases at most the new pane's target ($($b.Released) release lines)"
    $drwB = Get-LogCount $DRW
    [void](Set-TestWindowPos -Window $cov -X $ax -Y ($wa.Top + 330) -Width $aw -Height 200)
    # Uncovering sends the window nothing: the visibility poll (250 ms) is
    # what reveals it, and a capture asked of a pane still hidden is never
    # answered. Give the poll a few ticks first.
    Start-Sleep -Seconds 1
    $d = Test-PaneDraws 'hnp3'
    Assert $d.Ok "B3 uncovered: the new pane draws its text ($($d.Why))"
    if (-not $d.Ok) {
        foreach ($p in 'hnp1', 'hnp2') { Write-Host "  diag $p draws: $((Test-PaneDraws $p 3).Why)" }
        Write-Host "  diag list: $((Invoke-Verb @('+list', '--json')).Text)"
    }
    Assert ((Get-LogCount $DRW) -gt $drwB) "B4 the reveal redraws (positive control: $((Get-LogCount $DRW) - $drwB) lines)"

    $crashed = (Test-Path $errlog) -and (Select-String -Path $errlog -Pattern 'Segmentation fault|panic' -Quiet)
    Assert (-not $crashed) 'X1 no segfault or panic in the app log'
    Assert (-not (Test-TestDesktopLeak -ProcessId $appPid)) 'X2 GUI never became visible on the interactive desktop'
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

if ($script:fail -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard hidden-new-pane -Repo $repo 2>&1 | ForEach-Object { "  $_" }
    Write-Host "ALL PASS ($($script:pass) passed)"
    exit 0
}
Write-Host "$($script:fail) FAILURE(S) ($($script:pass) passed)"
exit 1
