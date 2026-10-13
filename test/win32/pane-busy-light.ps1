# T1899 acceptance: a pane's own progress light (Mac `SurfaceBusyBorder` /
# `SurfaceProgressBar`, main a5c0841be / 3ac40dc8b). A program in the pane
# reports progress with OSC 9;4 and the pane shows it, not only the taskbar.
#
# What is asserted, and how. The pane runs a tiny PowerShell emitter that
# re-sends whatever report a control file names every half second, so each
# phase is a real OSC 9;4 stream through the ConPTY. The light is window-owned
# paint - the card's 1px rim and the desk around it (busy_light.zig says why
# it is not inside the pane) - so a PrintWindow of the top-level window reads
# it, the way pane-elevation.ps1 reads the focus glow. Every probe is a LIFT:
# the same pixel's channel sum against its own value with no report, so the
# desk's gradient cancels out.
#
#   RING. Busy with no percentage (9;4;3): sampled for a little over one
#   2.4s turn, the rim at the right side's middle and at the bottom's middle
#   is each lit at some moment and dark at another - a light that MOVES, not
#   a lit border - and when the rim is lit the desk just outside it is lifted
#   too (the glow spills outward).
#
#   ERROR. 9;4;2 is the same ring in red: when lit, the rim gains more red
#   than blue.
#
#   BAR. 50% (9;4;1;50) lights the top rim a quarter of the way across and
#   leaves it dark three quarters across, steadily, and lights no side.
#
#   OFF. 9;4;0 puts every probe back within a second.
#
#   EXPIRY. A report that is not renewed goes dark after 15s, as on Mac.
#
# Runs on a background desktop (test/win32/lib/TestDesktop.ps1): nothing here
# takes the user's foreground, which is asserted at the end.
#
# -NegativeControl asserts the ring never lights the right side and MUST fail.
#
#   powershell -NoProfile -File test\win32\pane-busy-light.ps1
param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }

$env:GHOZTTY_PIPE_SUFFIX = "-busytest$PID"
$ctl = Join-Path $env:TEMP "ghoztty-busy-light-$PID.ctl"
$emit = Join-Path $env:TEMP "ghoztty-busy-light-$PID.ps1"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:pass = 0
$script:fail = 0
$script:skipped = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Kill-RepoInstances {
    [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
}

function Set-Report([string]$mode) {
    [System.IO.File]::WriteAllText($ctl, $mode)
}

# Zig's @round is half-away-from-zero; .NET's default is banker's.
function Round-Away([double]$v) { [int][math]::Round($v, [MidpointRounding]::AwayFromZero) }
# pane_elevation.zig mirrored: the rim inset.
function Get-InsetPx([double]$scale) { [math]::Max([int][math]::Ceiling(0.5 * $scale), 1) }

# The emitter: re-send the report the control file names every 500ms, and
# nothing at all for 'silent' (the expiry phase).
$emitBody = @'
param([string]$Ctl)
$esc = [char]27
$bel = [char]7
while ($true) {
    $m = ''
    try { $m = [System.IO.File]::ReadAllText($Ctl).Trim() } catch { }
    $seq = switch ($m) {
        'ring' { "$esc]9;4;3;$bel" }
        'err' { "$esc]9;4;2;$bel" }
        'bar50' { "$esc]9;4;1;50$bel" }
        'off' { "$esc]9;4;0;$bel" }
        default { '' }
    }
    if ($seq) { [Console]::Out.Write($seq); [Console]::Out.Flush() }
    Start-Sleep -Milliseconds 500
}
'@

Kill-RepoInstances
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$launched = @()

try {
    [System.IO.File]::WriteAllText($emit, $emitBody)
    Set-Report 'off'
    # persistence: off - the pane runs the emitter directly; a restored
    # layout would seed a pane this script did not make.
    $cmd = "--command=powershell.exe -NoProfile -ExecutionPolicy Bypass -File $emit $ctl"
    $app = Start-OnTestDesktop -Exe $exe -Arguments @('--config-default-files=false', '--background=#000000',
        '--session-persistence=false', $cmd)
    $launched += $script:GhozttyTestDesktopPids
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: top window not found'; exit 1 }
    Assert (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) 'window is NOT enumerable on the interactive desktop'
    $panes = @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal' | Where-Object Visible)
    Assert ($panes.Count -eq 1) "setup: one visible pane (saw $($panes.Count))"
    if ($panes.Count -ne 1) { exit 1 }
    $p = $panes[0]
    $scale = (Get-TestWindowDpi -Window $top) / 96.0
    $i = Get-InsetPx $scale
    # The card's last pixel on each side is its rim; one past it is the desk.
    $cardL = [int]$p.Left - $i; $cardT = [int]$p.Top - $i
    $cardR = [int]$p.Right + $i; $cardB = [int]$p.Bottom + $i
    $midX = [int](($cardL + $cardR) / 2); $midY = [int](($cardT + $cardB) / 2)
    $probes = [ordered]@{
        RightRim  = @(($cardR - 1), $midY)
        RightDesk = @($cardR, $midY)
        BottomRim = @($midX, ($cardB - 1))
        TopQuarter = @(($cardL + [int](($cardR - $cardL) / 4)), $cardT)
        TopThreeQuarter = @(($cardL + [int](3 * ($cardR - $cardL) / 4)), $cardT)
    }
    Write-Host "      scale=$scale inset=$i card=($cardL,$cardT,$cardR,$cardB)"

    function Read-Probes {
        $shot = Get-TestWindowPixels -Window $top -Sync
        try {
            if ((Get-TestDistinctColors -Shot $shot) -lt 4) { return $null }
            $out = [ordered]@{}
            foreach ($k in $probes.Keys) {
                $xy = $probes[$k]
                $out[$k] = Get-TestPixel -Shot $shot -X $xy[0] -Y $xy[1]
            }
            return $out
        } finally { Close-TestWindowPixels $shot }
    }
    function Get-Lift($now, $base, [string]$k) {
        if ($null -eq $now -or $null -eq $base -or $null -eq $now[$k] -or $null -eq $base[$k]) { return $null }
        return ($now[$k].R + $now[$k].G + $now[$k].B) - ($base[$k].R + $base[$k].G + $base[$k].B)
    }
    # Frames for a little over one turn.
    function Read-Turn([string]$label) {
        $frames = @()
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($sw.ElapsedMilliseconds -lt 3000) {
            $f = Read-Probes
            if ($null -ne $f) { $frames += , $f }
            Start-Sleep -Milliseconds 90
        }
        Write-Host "      $label`: $($frames.Count) frames over $($sw.ElapsedMilliseconds)ms"
        return , $frames
    }

    Start-Sleep -Milliseconds 800
    $base = Read-Probes
    if ($null -eq $base) {
        $script:skipped++
        Write-Host 'SKIP  every probe: the window capture came back empty'
    } else {
        foreach ($k in $base.Keys) { Write-Host "      base $k = $($base[$k].R),$($base[$k].G),$($base[$k].B)" }

        # RING ------------------------------------------------------------
        Set-Report 'ring'
        Start-Sleep -Milliseconds 1200
        $frames = Read-Turn 'ring'
        $right = @($frames | ForEach-Object { Get-Lift $_ $base 'RightRim' } | Where-Object { $null -ne $_ })
        $bottom = @($frames | ForEach-Object { Get-Lift $_ $base 'BottomRim' } | Where-Object { $null -ne $_ })
        $rmax = ($right | Measure-Object -Maximum).Maximum; $rmin = ($right | Measure-Object -Minimum).Minimum
        $bmax = ($bottom | Measure-Object -Maximum).Maximum; $bmin = ($bottom | Measure-Object -Minimum).Minimum
        Write-Host "      ring right rim lift min=$rmin max=$rmax; bottom rim lift min=$bmin max=$bmax"
        Assert ($frames.Count -ge 8) "ring: at least 8 frames sampled over the turn (saw $($frames.Count))"
        if ($NegativeControl) {
            Write-Host 'NEGATIVE CONTROL: asserting the ring never lights the right side - this run MUST fail'
            Assert ($rmax -lt 15) 'ring: the right side is never lit (negative control)'
        } else {
            Assert ($rmax -ge 60) "ring: the right side's rim is lit at some moment (max lift $rmax)"
        }
        Assert ($rmin -le 15) "ring: ...and dark at another - the light moves (min lift $rmin)"
        Assert (($bmax -ge 60) -and ($bmin -le 15)) "ring: the bottom's rim is lit and dark in turn too (min $bmin, max $bmax)"
        # The glow: in the frame where the right rim is brightest, the desk
        # just past it is lifted as well.
        $best = $null; $bestLift = -1
        foreach ($f in $frames) { $l = Get-Lift $f $base 'RightRim'; if ($null -ne $l -and $l -gt $bestLift) { $bestLift = $l; $best = $f } }
        $glow = if ($null -ne $best) { Get-Lift $best $base 'RightDesk' } else { $null }
        Assert (($null -ne $glow) -and ($glow -ge 12)) "ring: the glow spills onto the desk beside the lit rim (lift $glow)"

        # ERROR -----------------------------------------------------------
        Set-Report 'err'
        Start-Sleep -Milliseconds 1200
        $frames = Read-Turn 'error'
        $best = $null; $bestLift = -1
        foreach ($f in $frames) { $l = Get-Lift $f $base 'RightRim'; if ($null -ne $l -and $l -gt $bestLift) { $bestLift = $l; $best = $f } }
        if ($null -ne $best -and $bestLift -ge 40) {
            $dr = $best['RightRim'].R - $base['RightRim'].R
            $db = $best['RightRim'].B - $base['RightRim'].B
            Write-Host "      error rim at brightest: R +$dr, B +$db"
            Assert ($dr -ge $db + 30) 'error: the ring is red - the lit rim gains far more red than blue'
        } else {
            Assert $false "error: the ring lights the right side at some moment (max lift $bestLift)"
        }

        # BAR -------------------------------------------------------------
        Set-Report 'bar50'
        Start-Sleep -Milliseconds 1200
        $ok = 0; $seen = 0
        for ($t = 0; $t -lt 4; $t++) {
            $f = Read-Probes
            if ($null -eq $f) { continue }
            $seen++
            $q = Get-Lift $f $base 'TopQuarter'; $q3 = Get-Lift $f $base 'TopThreeQuarter'; $r = Get-Lift $f $base 'RightRim'
            Write-Host "      bar50 #$t top@25%=$q top@75%=$q3 right=$r"
            if ($q -ge 60 -and [math]::Abs($q3) -le 15 -and [math]::Abs($r) -le 15) { $ok++ }
            Start-Sleep -Milliseconds 400
        }
        Assert (($seen -ge 3) -and ($ok -eq $seen)) "bar: 50% lights the top a quarter across, not three quarters across, and no side - steadily ($ok of $seen frames)"

        # OFF -------------------------------------------------------------
        Set-Report 'off'
        Start-Sleep -Milliseconds 1000
        $f = Read-Probes
        $lifts = @($probes.Keys | ForEach-Object { Get-Lift $f $base $_ })
        Write-Host "      off lifts: $($lifts -join ', ')"
        Assert ((@($lifts | Where-Object { $null -eq $_ -or [math]::Abs($_) -gt 15 })).Count -eq 0) 'off: 9;4;0 puts every probe back within a second'

        # EXPIRY ----------------------------------------------------------
        Set-Report 'ring'
        Start-Sleep -Milliseconds 1500
        Set-Report 'silent'
        $lit = Read-Turn 'expiry: still within 15s'
        $stillLit = @($lit | ForEach-Object { Get-Lift $_ $base 'RightRim' } | Where-Object { $_ -ge 60 }).Count
        Assert ($stillLit -gt 0) "expiry: a report stays lit while it is fresh ($stillLit lit frames)"
        Start-Sleep -Seconds 14
        $dark = Read-Turn 'expiry: past 15s'
        $over = @($dark | ForEach-Object { Get-Lift $_ $base 'RightRim' } | Where-Object { $_ -gt 15 }).Count
        Assert (($dark.Count -ge 8) -and ($over -eq 0)) "expiry: a report not renewed for 15s goes dark ($over lit of $($dark.Count) frames)"
    }
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'no crash'
    Stop-Process -Id $app.Pid -Force -ErrorAction SilentlyContinue
} catch {
    $script:fail++
    Write-Host "FAIL  the run terminated: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "      at $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())"
} finally {
    Remove-TestDesktop
    Kill-RepoInstances
    Remove-Item $ctl, $emit -ErrorAction SilentlyContinue
}

$fgSeen = @(Stop-TestForegroundWatch)
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @($launched | Select-Object -Unique)
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'no test-desktop app ever became foreground on the interactive desktop'
}

Complete-TestBody
if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard pane-busy-light -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Skipped $script:skipped -Label 'PANE BUSY LIGHT ACCEPTANCE'
