<#
.SYNOPSIS
  Acceptance test for test\win32\lib\FrameCapture.ps1 (T2382) - the capture
  half of the T2373 frame lab.

.DESCRIPTION
  The lab is only as honest as its frame count: a capture that drops frames and
  scores the rest reads green over exactly the frames that bled. So the engine
  is proved in two halves.

  Pure logic (runs anywhere, no screen read):

    A. geometry - the crop of a request rect inside a monitor texture (inside,
       clamped at an edge, a monitor left of the primary, no overlap), pool
       buffers per refresh rate, the queue's byte budget, the 1% sample, and
       the SystemRelativeTime -> QPC conversion;
    B. frame accounting on synthetic timelines shaped like this box's real
       ones (capture arrivals ~1.2 ms before each present, presents jittering
       against a drifting composition clock): 1:1 reads 0 skipped; planted
       skips - scattered and back-to-back - are found exactly, by count AND by
       which presents; AccumulatedFrames > 1 counts as hidden; presents
       outside the window are ignored; timelines on unrelated clocks still
       report the count difference as a floor; extra capture frames are not
       skips;
    C. the scoring worker, fed synthetic frames through the same admission and
       queue a capture uses: failing frames + the deterministic sample are
       written as PNG and read back pixel-exact, a scorer fault is counted and
       treated as failing, a full queue DROPS AND COUNTS (captured = scored +
       dropped, always), and only KeepFrames frames keep their pixels.

  Live (the user's real screen - DWM composes only the input desktop):

    D. a 3 s monitor capture cropped to a rect: borderless, no cursor, the
       60 fps cap lifted, frame size = the crop, every stamp on the vsync grid,
       strictly increasing, and the Desktop Duplication cross-check finds the
       capture missed at most 1% of composed frames;
    E. the positive control: one handler stall of 100 ms with a single pool
       buffer forces WGC to drop what DWM composes meanwhile, and the
       cross-check must report those presents as skipped, inside the stall.

  D and E read the screen, so they ask lib\UserPresence.ps1 first and SKIP
  while somebody is using the box. They open no window and inject no input.
  They also need the screen to be composing (something animating, e.g. this
  loop's own pane); a screen too static to measure is a named SKIP, not a pass.

  ASCII-only by design (PS 5.1 on this box mangles non-ASCII on rewrite).

  powershell -NoProfile -File test\win32\frame-capture.ps1
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
. (Join-Path $PSScriptRoot 'lib\UserPresence.ps1')
. (Join-Path $PSScriptRoot 'lib\FrameCapture.ps1')

$runDir = Join-Path $env:TEMP ("gfc-accept-{0}" -f $PID)

try {
    Import-FrameCapture
    $F = [GfcClock]::Frequency
    function Ticks([double]$ms) { [long]($ms * $F / 1000.0) }

    # ---- A. geometry -------------------------------------------------------
    'A. geometry'
    $bx = 0; $by = 0; $bw = 0; $bh = 0
    $ok = [GfcGeometry]::Crop(0, 0, 2560, 1440, 100, 200, 800, 600, [ref]$bx, [ref]$by, [ref]$bw, [ref]$bh)
    Assert 'A1 a rect inside the monitor crops to itself' ($ok -and $bx -eq 100 -and $by -eq 200 -and $bw -eq 800 -and $bh -eq 600) "$bx,$by,$bw,$bh"
    $ok = [GfcGeometry]::Crop(0, 0, 2560, 1440, 2200, 1300, 800, 600, [ref]$bx, [ref]$by, [ref]$bw, [ref]$bh)
    Assert 'A2 a rect over the right/bottom edge is clamped to the monitor' ($ok -and $bx -eq 2200 -and $by -eq 1300 -and $bw -eq 360 -and $bh -eq 140) "$bx,$by,$bw,$bh"
    $ok = [GfcGeometry]::Crop(-1920, 0, 1920, 1080, -1000, 50, 400, 300, [ref]$bx, [ref]$by, [ref]$bw, [ref]$bh)
    Assert 'A3 a monitor left of the primary: screen coords become texture coords' ($ok -and $bx -eq 920 -and $by -eq 50 -and $bw -eq 400 -and $bh -eq 300) "$bx,$by,$bw,$bh"
    $ok = [GfcGeometry]::Crop(0, 0, 1920, 1080, 3000, 0, 100, 100, [ref]$bx, [ref]$by, [ref]$bw, [ref]$bh)
    Assert 'A4 a rect on another monitor does not crop' (-not $ok -and $bw -eq 0)
    $buf = @(0, 60, 120, 144, 240, 500 | ForEach-Object { [GfcGeometry]::BuffersFor($_) })
    Assert 'A5 pool buffers: 3 at 60 Hz (and unknown), 6 at 120, 8 at 144, 12 at 240 and above' (($buf -join ',') -eq '3,3,6,8,12,12') ($buf -join ',')
    Assert 'A6 queue cap is the byte budget over the frame size, never below 8' `
        ([GfcGeometry]::QueueCapFor(512MB, 1600, 1000) -eq 83 -and [GfcGeometry]::QueueCapFor(1MB, 1600, 1000) -eq 8) `
        "$([GfcGeometry]::QueueCapFor(512MB, 1600, 1000)) $([GfcGeometry]::QueueCapFor(1MB, 1600, 1000))"
    $hits = @(0..399 | Where-Object { [GfcGeometry]::SampleHit($_, 100) })
    Assert 'A7 the 1% sample is every 100th frame, deterministic; 0 = none' `
        (($hits -join ',') -eq '0,100,200,300' -and -not [GfcGeometry]::SampleHit(0, 0)) ($hits -join ',')
    # 100 ns ticks back to QPC: exact when QPC runs at 10 MHz (this box), and
    # within a tick otherwise.
    $q = [GfcClock]::FromHundredNs(123456789)
    $back = [long][math]::Round($q * 1e7 / $F)
    Assert 'A8 SystemRelativeTime (100 ns) converts onto the QPC clock' ([math]::Abs($back - 123456789) -le [math]::Ceiling(1e7 / $F)) "q=$q back=$back f=$F"
    # Refresh stamps 0,1,2,4,4,7,8,8,9 (in periods): a 1-refresh gap, a
    # 2-refresh gap, and two same-slot pairs whose earlier frame is superseded.
    $P = Ticks 8.3333
    $st9 = [long[]]@(0, 1, 2, 4, 4, 7, 8, 8, 9 | ForEach-Object { [long]($_ * $P) + 7 })
    $sup = New-Object bool[] 9; $g = [long]0; $sm = [long]0
    [GfcSlots]::Count($st9, $P, $sup, [ref]$g, [ref]$sm)
    $supAt = @(0..8 | Where-Object { $sup[$_] })
    Assert 'A9 slot accounting: 3 refreshes with no frame, 2 same-slot frames, the earlier of each pair superseded' `
        ($g -eq 3 -and $sm -eq 2 -and ($supAt -join ',') -eq '3,6') "gaps=$g same=$sm superseded=$($supAt -join ',')"

    # ---- B. accounting -----------------------------------------------------
    'B. frame accounting'
    # A composition clock like this box's: presents ~9 ms apart with 1 ms of
    # jitter, each capture arrival 1.2 ms before its present with up to
    # 0.6 ms of its own jitter. Seeded, so a red run reproduces.
    function New-Timeline([int]$N, [int]$Seed) {
        $rng = New-Object System.Random $Seed
        $pres = New-Object System.Collections.Generic.List[long]
        $cap = New-Object System.Collections.Generic.List[long]
        $t = 1000.0
        for ($i = 0; $i -lt $N; $i++) {
            $t += 8.333 + $rng.NextDouble() * 2.0
            $pres.Add((Ticks $t))
            $cap.Add((Ticks ($t - 1.2 + ($rng.NextDouble() - 0.5) * 1.2)))
        }
        return @{ P = $pres; C = $cap }
    }
    $tol = Ticks 6.25
    $T0 = Ticks 0; $T1 = Ticks 100000
    $tl = New-Timeline 400 7
    $a = [GfcAccounting]::Compare($tl.C.ToArray(), $tl.P.ToArray(), $null, $T0, $T1, $tol)
    Assert 'B1 one capture per present (jittered, offset): 0 skipped, all 400 matched' ($a.Skipped -eq 0 -and $a.Matched -eq 400 -and $a.CaptureOnly -eq 0) "$a"
    Assert 'B2 the offset is learned from the data (~ -1.2 ms)' ([math]::Abs($a.OffsetTicks - (Ticks -1.2)) -le (Ticks 0.4)) "offset=$($a.OffsetTicks)"

    $planted = @(17, 90, 91, 250, 399)
    $c2 = New-Object System.Collections.Generic.List[long]
    for ($i = 0; $i -lt 400; $i++) { if ($planted -notcontains $i) { $c2.Add($tl.C[$i]) } }
    $a = [GfcAccounting]::Compare($c2.ToArray(), $tl.P.ToArray(), $null, $T0, $T1, $tol)
    $want = @($planted | ForEach-Object { $tl.P[$_] })
    $got = @($a.UnmatchedQpc)
    Assert 'B3 five planted skips (scattered, back-to-back, last) found exactly' ($a.Skipped -eq 5 -and $a.Unmatched -eq 5 -and $a.CaptureOnly -eq 0) "$a"
    Assert 'B4 and the presents named are the planted ones' (($got -join ',') -eq ($want -join ',')) "got=$($got -join ',') want=$($want -join ',')"

    $acc = [int[]](@(1) * 400); $acc[50] = 3; $acc[51] = 2
    $a = [GfcAccounting]::Compare($tl.C.ToArray(), $tl.P.ToArray(), $acc, $T0, $T1, $tol)
    Assert 'B5 AccumulatedFrames > 1 counts as hidden presents, and as skipped' ($a.Hidden -eq 3 -and $a.DdaComposed -eq 403 -and $a.Skipped -eq 3) "$a"

    $mid0 = $tl.P[100]; $mid1 = $tl.P[199]
    $a = [GfcAccounting]::Compare($tl.C.ToArray(), $tl.P.ToArray(), $null, $mid0 - (Ticks 2), $mid1 + (Ticks 0.5), $tol)
    Assert 'B6 presents outside the window are not counted' ($a.DdaPresents -eq 100 -and $a.Skipped -eq 0) "$a"

    # Unrelated clocks: the capture timeline shifted by 37.3 s. With a forced
    # offset of 0 nothing pairs, nothing is rescued, and every present reads
    # skipped - a wrong clock is loud, never a quiet zero.
    $shift = Ticks 37300
    $c3 = @($c2 | ForEach-Object { $_ + $shift })
    $a = [GfcAccounting]::Compare([long[]]$c3, $tl.P.ToArray(), $null, $T0, [long]::MaxValue, $tol, 0)
    Assert 'B7 on unrelated clocks nothing pairs and every present reads skipped' ($a.Matched -eq 0 -and $a.Rescued -eq 0 -and $a.Skipped -eq 400) "$a"

    $c4 = New-Object System.Collections.Generic.List[long]
    foreach ($x in $tl.C) { $c4.Add($x) }
    $c4.Add((Ticks 999999)); $c4.Add($tl.C[200] + (Ticks 4.5))
    $a = [GfcAccounting]::Compare($c4.ToArray(), $tl.P.ToArray(), $null, $T0, [long]::MaxValue, $tol)
    Assert 'B8 capture frames duplication never reported are capture-only, not skips' ($a.Skipped -eq 0 -and $a.CaptureOnly -eq 2) "$a"

    # The rescue pass, both ways. A present duplication only COUNTED (acc 2)
    # whose frame the capture did deliver, one refresh earlier, is carried; a
    # spare capture frame (a second composition in one refresh) far from a
    # real skip must NOT carry it.
    $cR = New-Object System.Collections.Generic.List[long]
    foreach ($x in $tl.C) { $cR.Add($x) }
    $cR.Add($tl.C[300] - (Ticks 8.6))
    $accR = [int[]](@(1) * 400); $accR[300] = 2
    $a = [GfcAccounting]::Compare($cR.ToArray(), $tl.P.ToArray(), $accR, $T0, $T1, $tol)
    Assert 'B9 a hidden present whose frame the capture delivered is rescued, not skipped' ($a.Hidden -eq 1 -and $a.Rescued -eq 1 -and $a.Skipped -eq 0) "$a"
    $cS = New-Object System.Collections.Generic.List[long]
    for ($i = 0; $i -lt 400; $i++) { if ($i -ne 120) { $cS.Add($tl.C[$i]) } }
    $cS.Add($tl.C[200] + (Ticks 2))
    $a = [GfcAccounting]::Compare($cS.ToArray(), $tl.P.ToArray(), $null, $T0, $T1, $tol)
    Assert 'B10 a spare frame 80 refreshes away does not hide a real skip (counts are equal, skipped is still 1)' `
        ($a.Captured -eq 400 -and $a.Skipped -eq 1 -and @($a.UnmatchedQpc)[0] -eq $tl.P[120]) "$a"

    # ---- C. the scoring worker ---------------------------------------------
    'C. scoring worker'
    $W = 40; $H = 30
    $pngDir = Join-Path $runDir 'c'
    $s = Start-FrameCaptureWorker -W $W -H $H -PngDir $pngDir -SampleEvery 100 -KeepFrames 2 -Scorer ([GfcTestScorers]::EveryNth(25))
    for ($i = 0; $i -lt 250; $i++) {
        $px = New-Object int[] ($W * $H)
        for ($k = 0; $k -lt $px.Length; $k++) { $px[$k] = (($i * 7 + $k) * 2654435) -band 0xFFFFFF }
        if ($i -eq 125) { $px125 = $px }
        [void]$s.Feed($px, [long]$i * 83333)
    }
    $st = $s.Stop()
    $pngs = @(Get-ChildItem -Path $pngDir -Filter *.png | Sort-Object Name)
    Assert 'C1 250 frames scored; every 25th failing (10), the 1% sample hit 3' ($st.Scored -eq 250 -and $st.Failing -eq 10 -and $st.Sampled -eq 3) "scored=$($st.Scored) failing=$($st.Failing) sampled=$($st.Sampled)"
    Assert 'C2 one PNG per failing-or-sampled frame (10: the samples 0/100/200 are also failing)' ($st.PngWritten -eq 10 -and $pngs.Count -eq 10) "written=$($st.PngWritten) files=$($pngs.Count)"
    $f125 = Join-Path $pngDir 'f000125-fail.png'
    $same = $false
    if (Test-Path $f125) {
        $bmp = New-Object System.Drawing.Bitmap $f125
        try {
            $same = $true
            foreach ($pt in @(@(0, 0), @(39, 0), @(17, 13), @(39, 29))) {
                $want = $px125[$pt[1] * $W + $pt[0]] -band 0xFFFFFF
                $have = $bmp.GetPixel($pt[0], $pt[1]).ToArgb() -band 0xFFFFFF
                if ($want -ne $have) { $same = $false }
            }
        } finally { $bmp.Dispose() }
    }
    Assert 'C3 a failing frame''s PNG reads back pixel-exact' $same $f125
    Assert 'C4 KeepFrames=2 keeps two frames'' pixels and releases the rest' `
        ($s.Kept.Count -eq 2 -and $s.Kept[0].Px.Length -eq ($W * $H) -and @($s.Timeline).Count -eq 250) "kept=$($s.Kept.Count)"
    $s.Dispose()

    $s = Start-FrameCaptureWorker -W $W -H $H -SampleEvery 0 -Scorer ([GfcTestScorers]::ThrowsOn(7))
    for ($i = 0; $i -lt 20; $i++) { [void]$s.Feed((New-Object int[] ($W * $H)), $i) }
    $st = $s.Stop(); $s.Dispose()
    $m7 = @($s.Timeline | Where-Object { $_.Index -eq 7 })
    Assert 'C5 a scorer fault is counted and the frame is treated as failing' ($st.ScorerErrors -eq 1 -and $st.Failing -eq 1 -and $m7.Count -eq 1 -and $m7[0].Failing) "errors=$($st.ScorerErrors) failing=$($st.Failing)"

    # 1 KB budget -> the floor of 8 queued frames; a 20 ms scorer cannot keep
    # up with 100 frames fed at once, so most are dropped - and every one of
    # them is counted.
    $s = Start-FrameCaptureWorker -W $W -H $H -SampleEvery 0 -QueueBytes 1KB -Scorer ([GfcTestScorers]::Slow(20))
    $admitted = 0
    for ($i = 0; $i -lt 100; $i++) { if ($s.Feed((New-Object int[] ($W * $H)), $i)) { $admitted++ } }
    $st = $s.Stop(); $s.Dispose()
    Assert 'C6 a full queue drops frames and counts every one: captured = scored + dropped' `
        ($st.QueueCap -eq 8 -and $st.QueueDropped -gt 50 -and $st.Captured -eq 100 -and ($st.Scored + $st.QueueDropped) -eq 100 -and $st.Scored -eq $admitted -and $st.MaxQueue -le 8) `
        "cap=$($st.QueueCap) dropped=$($st.QueueDropped) scored=$($st.Scored) admitted=$admitted maxq=$($st.MaxQueue)"

    # ---- D/E. live capture -------------------------------------------------
    'D. live capture (the input desktop)'
    $presence = Get-UserPresence
    $live = $true
    if ($presence.Present) {
        "  SKIP D/E: somebody is using this box ($($presence.Reason)); the live capture never reads the screen under the user"
        $script:skipped += 2; $live = $false
    } elseif (-not [GfcSession]::Supported()) {
        "  SKIP D/E: Windows.Graphics.Capture is not supported on this box"
        $script:skipped += 2; $live = $false
    }

    if ($live) {
        $dPng = Join-Path $runDir 'd'
        # The measured-run shape: capture only, no duplication beside it.
        $s = Start-FrameCapture -X 0 -Y 0 -W 640 -H 480 -PngDir $dPng -SampleEvery 100 -KeepFrames 1
        Start-Sleep -Seconds 3
        $r = Stop-FrameCapture -Session $s
        $st = $r.Stats
        $span = [math]::Max(1, $st.Captured - $st.SameSlot + $st.SlotGaps)
        "    hz=$($st.RefreshHz) buffers=$($st.Buffers) captured=$($st.Captured) slot_gaps=$($st.SlotGaps) same_slot=$($st.SameSlot) dropped=$($st.QueueDropped) png=$($st.PngWritten)"
        if ($st.Errors.Count) { "    notes: $($st.Errors -join ' | ')" }
        $period = 1000.0 / [math]::Max(1, $st.RefreshHz)
        Assert 'D1 the capture is borderless and leaves the cursor out' ($st.BorderlessApplied -and $st.CursorDisabled) "border=$($st.BorderlessApplied) note=$($st.BorderNote) cursorOff=$($st.CursorDisabled)"
        Assert 'D2 the 60 fps cap is lifted (MinUpdateInterval set), and no duplication ran beside the measured run' `
            ($st.MinUpdateIntervalSet -and $st.DdaAcquires -eq 0) "mui=$($st.MinUpdateIntervalSet) dda=$($st.DdaAcquires) $($st.Errors -join ' | ')"
        $k = $r.Kept
        Assert 'D3 frames are the crop: 640x480 pixels, and the 1% sample was written' `
            ($k.Count -eq 1 -and $k[0].W -eq 640 -and $k[0].H -eq 480 -and $k[0].Px.Length -eq 640 * 480 -and $st.PngWritten -ge 1) "kept=$($k.Count) png=$($st.PngWritten)"
        $tlq = @($r.Timeline | ForEach-Object { $_.Qpc })
        $bad = 0; $offGrid = 0
        for ($i = 1; $i -lt $tlq.Count; $i++) {
            $d = ($tlq[$i] - $tlq[$i - 1]) * 1000.0 / $F
            if ($d -lt 0) { $bad++ }
            $n = [math]::Round($d / $period)
            if ([math]::Abs($d - $n * $period) -gt 0.2) { $offGrid++ }
        }
        Assert 'D4 stamps never go backwards, and every step is a whole number of refreshes (they are display slots)' ($bad -eq 0 -and $offGrid -eq 0 -and $tlq.Count -gt 30) "backwards=$bad offgrid=$offGrid of $($tlq.Count)"
        $supN = @($r.Timeline | Where-Object { $_.Superseded }).Count
        Assert 'D5 a static screen still composes every refresh while captured, and the capture keeps up: <= 5% of refreshes without a frame, none dropped' `
            ($st.Captured -ge 2 * $st.RefreshHz -and $st.SlotGaps -le 0.05 * $span -and $st.QueueDropped -eq 0 -and $supN -eq $st.SameSlot) `
            "captured=$($st.Captured) gaps=$($st.SlotGaps) of $span same=$($st.SameSlot) superseded=$supN dropped=$($st.QueueDropped)"
        $gapRateAlone = $st.SlotGaps / $span
    }

    if ($live) {
        'E. accounting run: Desktop Duplication beside the capture'
        $s = Start-FrameCapture -X 0 -Y 0 -W 320 -H 240 -SampleEvery 0 -Duplication
        Start-Sleep -Seconds 3
        $r = Stop-FrameCapture -Session $s
        $st = $r.Stats; $a = $r.Account
        $span = [math]::Max(1, $st.Captured - $st.SameSlot + $st.SlotGaps)
        "    captured=$($st.Captured) dda_composed=$($st.DdaComposed) slot_gaps=$($st.SlotGaps) | $a"
        Assert 'E1 duplication ran beside the capture and counted presents' ($st.DdaAcquires -gt 0 -and -not $st.DdaNote -and $a.DdaComposed -ge 2 * $st.RefreshHz) "acquires=$($st.DdaAcquires) composed=$($a.DdaComposed) note=$($st.DdaNote)"
        $limit = [math]::Max(1, [math]::Floor($a.DdaComposed * 0.01))
        Assert "E2 the capture missed at most 1% of the frames DWM composed (<= $limit)" ($a.Skipped -le $limit -and $st.QueueDropped -eq 0) "$a"

        # The positive control, on the REAL timelines (their real jitter):
        # remove five capture frames - two of them back-to-back - and the
        # cross-check must find exactly five more skips, naming presents the
        # removed frames carried.
        $arr = @($r.Timeline | Where-Object { $_.ArrivalQpc -ge $st.StartQpc } | ForEach-Object { $_.ArrivalQpc })
        $n = $arr.Count
        # Remove frames only from CLEAN stretches - no baseline anomaly (an
        # unpaired present, a capture-only frame, a hidden present) within
        # three refreshes - so the control measures the planted skips and not
        # their interaction with a swap the baseline already had.
        $P3 = Ticks (3000.0 / $st.RefreshHz)
        $anom = New-Object System.Collections.Generic.List[long]
        foreach ($u in $a.UnmatchedQpc) { $anom.Add($u + $a.OffsetTicks) }
        foreach ($c in $a.CaptureOnlyQpc) { $anom.Add($c) }
        $dp = $s.DdaPresentQpc.ToArray(); $da = $s.DdaAccum.ToArray()
        for ($i = 0; $i -lt $dp.Length; $i++) { if ($da[$i] -gt 1) { $anom.Add($dp[$i] + $a.OffsetTicks) } }
        $clean = @(for ($i = 3; $i -lt $n - 3; $i++) {
            $t = $arr[$i]; $hit = $false
            foreach ($x in $anom) { if ([math]::Abs($x - $t) -le $P3) { $hit = $true; break } }
            if (-not $hit) { $i }
        })
        function Near-Clean([int]$target, [int[]]$pool, [int[]]$avoid) {
            $best = -1
            foreach ($c in $pool) { if ($avoid -contains $c) { continue }; if ($best -lt 0 -or [math]::Abs($c - $target) -lt [math]::Abs($best - $target)) { $best = $c } }
            return $best
        }
        $pairAt = Near-Clean ([int]($n * 0.4)) @($clean | Where-Object { $clean -contains ($_ + 1) }) @()
        $drop = @($pairAt, ($pairAt + 1))
        # (Not $f: variables are case-insensitive, and $F is the QPC frequency.)
        foreach ($frac in 0.2, 0.6, 0.8) { $drop += Near-Clean ([int]($n * $frac)) $clean @($drop | ForEach-Object { $_ - 1; $_; $_ + 1 }) }
        $kept = New-Object System.Collections.Generic.List[long]
        for ($i = 0; $i -lt $n; $i++) { if ($drop -notcontains $i) { $kept.Add($arr[$i]) } }
        $tolT = Ticks (750.0 / $st.RefreshHz)
        $b = [GfcAccounting]::Compare($kept.ToArray(), $s.DdaPresentQpc.ToArray(), $s.DdaAccum.ToArray(), $st.StartQpc, $st.StopQpc, $tolT, $a.OffsetTicks)
        # Located within two refreshes: next to a pairing swap or a hidden
        # present, order-preserving pairing can name the neighbouring present
        # (seen live: 4 of 5 within one slot, the fifth one present along).
        $near = 0
        $locT = Ticks (2000.0 / $st.RefreshHz)
        foreach ($i in $drop) {
            $hit = @($b.UnmatchedQpc | Where-Object { [math]::Abs($_ + $a.OffsetTicks - $arr[$i]) -le $locT })
            if ($hit.Count -ge 1) { $near++ }
        }
        Assert 'E3 positive control: five capture frames removed from the live timeline are five more skips, each within two refreshes of a removed frame' `
            ($b.Skipped -eq $a.Skipped + 5 -and $near -eq 5) "baseline=$($a.Skipped) planted=$($b.Skipped) located=$near of 5 | $b"

        # The reason duplication is an accounting run and not a passenger: the
        # share of refreshes with no frame, alone and with duplication beside.
        $gapRateDda = $st.SlotGaps / $span
        "    measurement: refreshes without a frame - capture alone {0:P1}, with duplication beside it {1:P1}" -f $gapRateAlone, $gapRateDda
    }

    Complete-TestBody
}
finally {
    foreach ($v in @('s')) { $o = Get-Variable -Name $v -ValueOnly -ErrorAction SilentlyContinue; if ($o -is [IDisposable]) { try { $o.Dispose() } catch { } } }
    if (Test-Path $runDir) { Remove-Item -Recurse -Force -LiteralPath $runDir -ErrorAction SilentlyContinue }
}

# A green run stamps the covered files (T783); red or skipped stays due.
if ($script:failures -eq 0 -and $script:skipped -eq 0) {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard frame-capture -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

''
Write-TestVerdict -Label 'T2382 FRAME-CAPTURE' -Pass $script:passes -Fail $script:failures -Skipped $script:skipped
