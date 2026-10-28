# @timing-sensitive - section E measures a 1 kHz timer loop's lateness, so it runs with nothing beside it (scripts/acceptance-parallel.ps1, T1960).
<#
.SYNOPSIS
  Acceptance test for test\win32\lib\FrameLabInput.ps1 (T2384) - the input
  half of the T2373 frame lab.

.DESCRIPTION
  Input-to-photon lag, reversal checks and jitter are only as true as the
  pointer timeline they are measured against. So the driver is proved here
  without ever touching the real pointer:

    A. paths - one sample per tick at the planned QPC offset, a Line's
       endpoint exact and every step in the line's own direction, Shuttle's
       legs alternating without a backwards step, Hold/Press/Release placed
       where asked, and a path with no position refused;
    B. the absolute-coordinate normalisation - every pixel of every common
       virtual-desktop width round-trips exactly, nothing exceeds 65535, and
       an off-desktop coordinate clamps;
    C. the presence gate - injection refused while somebody is present or the
       presence answer is missing; a dry run and a caller sink pass; and a
       skipped Invoke sends nothing;
    D. the player against GliRecordingSink: the whole path sent in order with
       its flags; a path that ends with the button down is released by the
       player; a simulated user taking the mouse aborts the run (user-input)
       on the second divergent check and releases the button WHERE THE USER
       PUT THE CURSOR; a cursor lagging a few points behind is not a user
       (negative control); -NoAbortOnUserInput plays through;
    E. the timer, live but injecting nothing: a 2000-point dry run at 1 kHz on
       the high-resolution waitable timer, every point stamped, never early,
       p95 lateness under 500 us, under 1% of points a period late, and the
       achieved rate within 2% of 1000 Hz.

  The driver's first injected run on the input desktop belongs to T2389 (the
  interaction catalogue), which is an input-desktop exception. This harness
  opens no window, reads no screen and sends no input, so it runs anywhere.

  ASCII-only by design (PS 5.1 on this box mangles non-ASCII on rewrite).

  powershell -NoProfile -File test\win32\frame-lab-input.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$script:passes = 0
$script:failures = 0
$script:skipped = 0
function Assert($name, $cond, $detail = '') {
    if ($cond) {
        "  PASS $name"
        $script:passes++
    } else {
        "  FAIL $name$(if ($detail) { " -- $detail" })"
        $script:failures++
    }
}

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\FrameLabInput.ps1')

try {
    Import-FrameLabInput
    $F = [GliClock]::Frequency

    # ---- A. paths ------------------------------------------------------------
    'A. paths'
    $p = (New-FrameLabPath 1000).MoveTo(100, 200).Press().Line(300, 250, 100).Hold(20).Release().Build()
    Assert 'A1 one sample per tick: MoveTo + Press + 100 line + 20 hold + Release = 123' ($p.Length -eq 123) "n=$($p.Length)"
    $offOk = $true
    for ($i = 0; $i -lt $p.Length; $i++) {
        if ($p[$i].OffsetTicks -ne [long][math]::Round($i * $F / 1000.0)) { $offOk = $false; break }
    }
    Assert 'A2 every sample sits at round(i * F / rate) on the QPC clock' $offOk
    Assert 'A3 Press is a Down at the MoveTo point; Release an Up at the line end' `
        ($p[1].Flags -eq [GliFlags]::Down -and $p[1].X -eq 100 -and $p[1].Y -eq 200 -and
         $p[122].Flags -eq [GliFlags]::Up -and $p[122].X -eq 300 -and $p[122].Y -eq 250)
    Assert 'A4 the line endpoint is exact and the hold stays on it' `
        ($p[101].X -eq 300 -and $p[101].Y -eq 250 -and @($p[102..121] | Where-Object { $_.X -ne 300 -or $_.Y -ne 250 }).Count -eq 0)
    $mono = $true
    for ($i = 2; $i -le 101; $i++) { if ($p[$i].X -lt $p[$i - 1].X -or $p[$i].Y -lt $p[$i - 1].Y) { $mono = $false } }
    Assert 'A5 every line step moves in the line''s own direction' $mono
    Assert 'A6 only Press and Release carry flags' (@($p | Where-Object { $_.Flags -ne 0 }).Count -eq 2)

    $s = (New-FrameLabPath 1000).MoveTo(500, 300).Shuttle(700, 300, 4, 50).Build()
    $dirOk = $true; $legEnds = @()
    for ($l = 0; $l -lt 4; $l++) {
        $sign = if ($l % 2 -eq 0) { 1 } else { -1 }
        $a = 1 + $l * 50; $b = $a + 49
        for ($i = $a; $i -le $b; $i++) { if (($s[$i].X - $s[$i - 1].X) * $sign -lt 0) { $dirOk = $false } }
        $legEnds += $s[$b].X
    }
    Assert 'A7 Shuttle: four 50 ms legs, alternating, ends at 700/500/700/500' `
        ($s.Length -eq 201 -and ($legEnds -join ',') -eq '700,500,700,500') "n=$($s.Length) ends=$($legEnds -join ',')"
    Assert 'A8 Shuttle never steps against its leg''s direction (the reversal check''s premise)' $dirOk

    $h = (New-FrameLabPath 500).MoveTo(0, 0).Hold(10).Build()
    Assert 'A9 rate is honoured: 10 ms hold at 500 Hz = 5 samples, 2 ms apart' `
        ($h.Length -eq 6 -and $h[5].OffsetTicks -eq [long][math]::Round(5 * $F / 500.0))
    $threw = $false
    try { [void](New-FrameLabPath 1000).Press() } catch { $threw = $true }
    Assert 'A10 Press before MoveTo is refused (a path with no position)' $threw
    $threw = $false
    try { [void](New-Object GliPathBuilder 0) } catch { $threw = $true }
    Assert 'A11 a zero rate is refused' $threw

    # ---- B. normalisation ----------------------------------------------------
    'B. absolute-coordinate normalisation'
    $bad = @()
    foreach ($w in 1366, 1920, 2560, 3440, 3840, 5120, 7680, 11520) {
        for ($v = 0; $v -lt $w; $v++) {
            $n = [GliMath]::Normalize($v, $w)
            if ($n -gt 65535 -or [GliMath]::Denormalize($n, $w) -ne $v) { $bad += "w=$w v=$v n=$n"; break }
        }
    }
    Assert 'B1 every pixel of eight virtual-desktop widths round-trips exactly, never above 65535' ($bad.Count -eq 0) ($bad -join '; ')
    Assert 'B2 off-desktop coordinates clamp to 0 and 65535' `
        ([GliMath]::Normalize(-50, 1920) -eq 0 -and [GliMath]::Normalize(5000, 1920) -eq 65535)

    # ---- C. the presence gate ------------------------------------------------
    'C. presence gate'
    $present = [pscustomobject]@{ Present = $true; Reason = 'keyboard/mouse input 3s ago' }
    $absent = [pscustomobject]@{ Present = $false; Reason = 'no recent input' }
    $g1 = Resolve-FrameLabInputGate -Presence $present
    $g2 = Resolve-FrameLabInputGate -Presence $absent
    $g3 = Resolve-FrameLabInputGate -Presence $null
    $g4 = Resolve-FrameLabInputGate -Presence $present -DryRun
    $g5 = Resolve-FrameLabInputGate -Presence $present -CustomSink
    Assert 'C1 present -> refused, with the reason named' (-not $g1.Allowed -and $g1.Reason -match 'input 3s ago') $g1.Reason
    Assert 'C2 absent -> allowed (the gate is not a blanket skip)' $g2.Allowed
    Assert 'C3 no presence answer -> refused (never inject blind)' (-not $g3.Allowed)
    Assert 'C4 a dry run and a caller sink pass even while present (neither sends input)' ($g4.Allowed -and $g5.Allowed)
    $r = Invoke-FrameLabInput -Path $p -Presence $present
    Assert 'C5 a refused live Invoke is Skipped, sends nothing and names why' `
        ($r.Skipped -and $r.Sent -eq 0 -and $r.Stamps.Length -eq 0 -and $r.SkipReason -match 'somebody') "$r skip=$($r.SkipReason)"

    # ---- D. the player against a recording sink --------------------------------
    'D. player'
    $sink = New-Object GliRecordingSink
    $r = Invoke-FrameLabInput -Path $p -Sink $sink
    $same = $sink.Sends.Count -eq $p.Length
    if ($same) { for ($i = 0; $i -lt $p.Length; $i++) { if ($sink.Sends[$i].X -ne $p[$i].X -or $sink.Sends[$i].Y -ne $p[$i].Y -or $sink.Sends[$i].Flags -ne $p[$i].Flags) { $same = $false; break } } }
    Assert 'D1 the whole path is sent in order with its flags, and nothing more' ($same -and -not $r.Aborted -and -not $r.ButtonReleased) "$r sends=$($sink.Sends.Count)"
    $ord = $true
    for ($i = 1; $i -lt $r.Stamps.Length; $i++) { if ($r.Stamps[$i].SentQpc -lt $r.Stamps[$i - 1].SentQpc -or $r.Stamps[$i].SentQpc -lt $r.Stamps[$i].PlannedQpc) { $ord = $false } }
    Assert 'D2 one stamp per point, in order, none sent before its planned tick' ($r.Stamps.Length -eq $p.Length -and $r.Sent -eq $p.Length -and $ord)

    $open = (New-FrameLabPath 1000).MoveTo(10, 10).Press().Line(60, 10, 50).Build()
    $sink = New-Object GliRecordingSink
    $r = Invoke-FrameLabInput -Path $open -Sink $sink
    $last = $sink.Sends[$sink.Sends.Count - 1]
    Assert 'D3 a path that ends with the button down is released by the player, at its last point' `
        ($r.ButtonReleased -and $sink.Sends.Count -eq $open.Length + 1 -and $last.Flags -eq [GliFlags]::Up -and $last.X -eq 60) "$r"

    $drag = (New-FrameLabPath 1000).MoveTo(100, 100).Press().Line(400, 100, 300).Release().Build()
    $sink = New-Object GliRecordingSink
    $sink.UserMovesAt = 120; $sink.UserX = 900; $sink.UserY = 700
    $r = Invoke-FrameLabInput -Path $drag -Sink $sink
    $last = $sink.Sends[$sink.Sends.Count - 1]
    Assert 'D4 a user taking the mouse aborts on the second divergent check (user-input @121)' `
        ($r.Aborted -and $r.AbortReason -eq 'user-input' -and $r.AbortIndex -eq 121 -and $r.Stamps.Length -eq 121) "$r"
    Assert 'D5 ...and the held button is released where the USER put the cursor, not dragged back' `
        ($r.ButtonReleased -and $last.Flags -eq [GliFlags]::Up -and $last.X -eq 900 -and $last.Y -eq 700 -and $sink.Sends.Count -eq 122) "last=($($last.X),$($last.Y),$($last.Flags)) sends=$($sink.Sends.Count)"

    $sink = New-Object GliRecordingSink
    $sink.LagSends = 4
    $r = Invoke-FrameLabInput -Path $drag -Sink $sink
    Assert 'D6 negative control: a cursor four points behind the driver is not a user (no abort)' (-not $r.Aborted -and $r.Sent -eq $drag.Length) "$r"

    $sink = New-Object GliRecordingSink
    $sink.UserMovesAt = 50; $sink.UserX = 5; $sink.UserY = 5
    $r = Invoke-FrameLabInput -Path $drag -Sink $sink -NoAbortOnUserInput
    Assert 'D7 -NoAbortOnUserInput plays the whole path through' (-not $r.Aborted -and $r.Sent -eq $drag.Length) "$r"

    # ---- E. the timer --------------------------------------------------------
    'E. 1 kHz timer (dry run: nothing sent)'
    $dry = (New-FrameLabPath 1000).MoveTo(0, 0).Hold(1999).Build()
    $r = Invoke-FrameLabInput -Path $dry -DryRun
    "    measurement: $r"
    $never = @($r.Stamps | Where-Object { $_.SentQpc -lt $_.PlannedQpc }).Count -eq 0
    Assert 'E1 dry run sends nothing, stamps all 2000 points, none early' ($r.Sent -eq 0 -and $r.Stamps.Length -eq 2000 -and $never -and -not $r.Error) "$r"
    Assert 'E2 the high-resolution waitable timer is in use' $r.HighResolutionTimer
    Assert 'E3 p95 lateness < 500 us' ($r.LatenessP95Us -lt 500) "$r"
    Assert 'E4 under 1% of points more than one period late' ($r.Late -lt 20) "$r"
    Assert 'E5 achieved rate within 2% of 1000 Hz' ([math]::Abs($r.AchievedHz - 1000) -lt 20) "$r"
    $js = @(ConvertTo-FrameLabInputStamps $r)
    Assert 'E6 stamps export: first at 0 us, the 1000th planned at 999000 us, origin QPC carried' `
        ($js.Count -eq 2000 -and $js[0].plannedUs -eq 0 -and [math]::Abs($js[999].plannedUs - 999000) -le 1 -and $js[0].originQpc -eq $r.Stamps[0].PlannedQpc)

    Complete-TestBody
}
catch {
    "  FAIL unexpected: $($_.Exception.Message) at $($_.InvocationInfo.PositionMessage)"
    $script:failures++
}

# A green run stamps the covered files (T783); red or skipped stays due.
if ($script:failures -eq 0 -and $script:skipped -eq 0) {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard frame-lab-input -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

''
Write-TestVerdict -Label 'T2384 FRAME-LAB-INPUT' -Pass $script:passes -Fail $script:failures -Skipped $script:skipped
