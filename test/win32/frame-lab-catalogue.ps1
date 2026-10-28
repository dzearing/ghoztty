<#
.SYNOPSIS
  Acceptance test for test\win32\lib\FrameLabCatalogue.ps1 (T2389) - what the
  T2373 frame lab drives, over which matrix, and the per-cell run protocol.

.DESCRIPTION
  The catalogue and the protocol decide what a lab verdict MEANS, so they are
  proved here against fakes, without a window, a screen or the pointer:

    A. the catalogue - every interaction T2373 names is listed, pointer or
       trigger, and every trigger names the task that builds its driver;
    B. pointer gestures - each starts at its grab point ON the edge it moves
       (inside the resize zone, the divider, the sidebar edge), presses, ends
       released at the point it started (even legs, so the accounting run
       replays the same geometry), never steps against its leg's direction,
       stays inside the monitor, and puts its motion window over the shuttle;
       the capture rect covers the gesture's reach and is clipped to the
       monitor; odd legs, a missing divider and a trigger are refused;
    C. the matrix - the full product minus what cannot apply (a divider with
       one pane, a sidebar edge with no sidebar), unique ids, filters, and
       nothing that cannot run dropped quietly: triggers and stalled cells are
       listed and Blocked with the reason;
    D. the protocol against a recording fake driver - presence first and a
       present user launches nothing; a capture-only measurement run, THEN a
       separate -Duplication accounting run of the identical path; Superseded
       frames never reach the scorer; the scene closes even when the scorer
       throws; an aborted measurement skips the accounting run;
    E. the verdict - bleed or a missed motion target fails; clean with no
       accounting, or with accounting that names skipped frames, is
       incomplete (and a fail outranks it); SlotGaps rides beside it.

  The live run (input desktop, idle box) is T2392's input-desktop exception.
  ASCII-only by design (PS 5.1 on this box mangles non-ASCII on rewrite).

  powershell -NoProfile -File test\win32\frame-lab-catalogue.ps1
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
. (Join-Path $PSScriptRoot 'lib\FrameLabCatalogue.ps1')

# A 1200x800 window at (400, 200) on a 2560x1400 work area, split once, with a
# sidebar edge 260 px in.
$geo = @{
    Window  = @{ X = 400; Y = 200; W = 1200; H = 800 }
    Monitor = @{ X = 0; Y = 0; W = 2560; H = 1400 }
    Caption = 215
    Divider = @{ X = 1100; Y0 = 260; Y1 = 990 }
    Sidebar = @{ EdgeX = 660; Y0 = 260; Y1 = 990 }
}

function Test-LegsMonotonic($Path, [string]$Axis) {
    # Within every run of motion, consecutive steps never change sign except
    # at a turn, and a turn never steps back the way it came within a leg.
    $prev = 0
    $steps = @()
    for ($i = 1; $i -lt $Path.Length; $i++) {
        $d = $(if ($Axis -eq 'y') { $Path[$i].Y - $Path[$i - 1].Y } else { $Path[$i].X - $Path[$i - 1].X })
        if ($d -ne 0) { $steps += [math]::Sign($d) }
    }
    # A leg is a maximal run of one sign; the number of sign flips must be
    # legs - 1, so no leg ever contains a backwards step.
    $flips = 0
    for ($i = 1; $i -lt $steps.Count; $i++) { if ($steps[$i] -ne $steps[$i - 1]) { $flips++ } }
    return $flips
}

try {
    # ---- A. catalogue ----------------------------------------------------------
    'A. catalogue'
    $cat = @(Get-FrameLabInteractions)
    $names = $cat.Name
    $want = 'frame-right', 'frame-bottom', 'frame-corner', 'caption-dblclick', 'aero-snap', 'divider',
        'sidebar-edge', 'maximize-button', 'blade-glide', 'banner', 'hero', 'tab-switch', 'split-close'
    Assert 'A1 every T2373 interaction is catalogued (frame/corner, maximize/snap/caption, divider, sidebar, blade, banner, hero, tab, split/close)' `
        (@($want | Where-Object { $_ -notin $names }).Count -eq 0) "missing: $(@($want | Where-Object { $_ -notin $names }) -join ',')"
    Assert 'A2 names are unique' ((@($names | Select-Object -Unique)).Count -eq $names.Count)
    Assert 'A3 every trigger names the task that builds its driver' `
        (@($cat | Where-Object { $_.Kind -eq 'trigger' -and $_.Driver -notmatch '^T\d+$' }).Count -eq 0)
    Assert 'A4 every pointer interaction builds a gesture' `
        (@($cat | Where-Object { $_.Kind -eq 'pointer' } | Where-Object {
            try { $null = Get-FrameLabGesture -Name $_.Name -Geometry $geo; $false } catch { $true } }).Count -eq 0)

    # ---- B. gestures -----------------------------------------------------------
    'B. pointer gestures'
    $right = Get-FrameLabGesture -Name frame-right -Geometry $geo -Amplitude 200 -Legs 4 -LegMs 500
    $p = $right.Path
    $edge = 400 + 1200
    Assert 'B1 frame-right grabs inside the resize zone of the right edge, mid-height' `
        ($p[0].X -lt $edge -and $p[0].X -ge $edge - 8 -and $p[0].Y -eq 600) "grab=($($p[0].X),$($p[0].Y))"
    $down = @($p | Where-Object { $_.Flags -eq [GliFlags]::Down })
    $up = @($p | Where-Object { $_.Flags -eq [GliFlags]::Up })
    Assert 'B2 one press, one release, the release last and at the grab point (even legs return)' `
        ($down.Count -eq 1 -and $up.Count -eq 1 -and $p[-1].Flags -eq [GliFlags]::Up -and $p[-1].X -eq $p[0].X -and $p[-1].Y -eq $p[0].Y)
    Assert 'B3 four legs = three turns, no backwards step inside a leg' ((Test-LegsMonotonic $p 'x') -eq 3)
    Assert 'B4 the reach is the amplitude: max x = grab + 200' (($p | Measure-Object X -Maximum).Maximum -eq $p[0].X + 200)
    $legPts = 500
    Assert 'B5 the motion window spans the shuttle exactly (4 legs x 500 ms at 1 kHz)' `
        ([math]::Abs(($right.MotionEndMs - $right.MotionStartMs) - (4 * $legPts - 1)) -le 1 -and $right.MotionStartMs -gt 0) `
        "start=$($right.MotionStartMs) end=$($right.MotionEndMs)"
    Assert 'B6 axis/track/grab offset: x, window-right, pointer 4 px inside the edge' `
        ($right.Axis -eq 'x' -and $right.Track -eq 'window-right' -and $right.GrabOffset -eq -4) "grab=$($right.GrabOffset)"
    Assert 'B7 capture rect covers the window grown by the amplitude' `
        ($right.CaptureRect.X -eq 400 -and $right.CaptureRect.W -eq 1400 -and $right.CaptureRect.H -eq 800)

    $bot = Get-FrameLabGesture -Name frame-bottom -Geometry $geo -Amplitude 1000
    Assert 'B8 a reach past the work area is clipped to the monitor' ($bot.CaptureRect.Y + $bot.CaptureRect.H -eq 1400) "rect=$($bot.CaptureRect)"
    Assert 'B9 frame-bottom moves y only' ((@($bot.Path | Select-Object -ExpandProperty X -Unique)).Count -eq 1 -and (Test-LegsMonotonic $bot.Path 'y') -eq 3)

    $cor = Get-FrameLabGesture -Name frame-corner -Geometry $geo
    Assert 'B10 frame-corner grabs inside the bottom-right corner and moves both axes' `
        ($cor.Path[0].X -ge $edge - 8 -and $cor.Path[0].Y -ge 1000 - 8 -and $cor.Path[0].Y -lt 1000 -and
         ($cor.Path | Measure-Object Y -Maximum).Maximum -gt $cor.Path[0].Y -and $cor.Axis -eq 'xy')

    $div = Get-FrameLabGesture -Name divider -Geometry $geo -Amplitude 150
    Assert 'B11 divider grabs ON the divider and moves into the bigger side (left here)' `
        ($div.Path[0].X -eq 1100 -and ($div.Path | Measure-Object X -Minimum).Minimum -eq 950 -and ($div.Path | Measure-Object X -Maximum).Maximum -eq 1100)
    $sbg = Get-FrameLabGesture -Name sidebar-edge -Geometry $geo
    Assert 'B12 sidebar-edge grabs on the sidebar edge' ($sbg.Path[0].X -eq 660 -and $sbg.Track -eq 'sidebar-edge')

    $dbl = Get-FrameLabGesture -Name caption-dblclick -Geometry $geo
    Assert 'B13 caption-dblclick: four clicks on the caption, never moving, bleed-only' `
        (@($dbl.Path | Where-Object { $_.Flags -eq [GliFlags]::Down }).Count -eq 4 -and
         (@($dbl.Path | Where-Object { $_.Y -ne 215 })).Count -eq 0 -and $dbl.Axis -eq 'none' -and $dbl.CaptureRect.W -eq 2560)
    $snap = Get-FrameLabGesture -Name aero-snap -Geometry $geo
    Assert 'B14 aero-snap drags the caption to the work area left edge and back' `
        (($snap.Path | Measure-Object X -Minimum).Minimum -eq 0 -and $snap.Path[-1].X -eq $snap.Path[0].X)

    $all = @()
    foreach ($n in @($cat | Where-Object { $_.Kind -eq 'pointer' }).Name) { $all += (Get-FrameLabGesture -Name $n -Geometry $geo).Path }
    Assert 'B15 no gesture leaves the monitor' (@($all | Where-Object { $_.X -lt 0 -or $_.X -ge 2560 -or $_.Y -lt 0 -or $_.Y -ge 1400 }).Count -eq 0)

    $e1 = try { $null = Get-FrameLabGesture -Name frame-right -Geometry $geo -Legs 3; '' } catch { $_.Exception.Message }
    Assert 'B16 odd legs refused (the path would not end where it started)' ($e1 -match 'even')
    $g2 = @{ Window = $geo.Window; Monitor = $geo.Monitor; Caption = 215 }
    $e2 = try { $null = Get-FrameLabGesture -Name divider -Geometry $g2; '' } catch { $_.Exception.Message }
    Assert 'B17 a divider gesture on a scene with no divider is refused' ($e2 -match 'Divider')
    $e3 = try { $null = Get-FrameLabGesture -Name banner -Geometry $geo; '' } catch { $_.Exception.Message }
    Assert 'B18 a trigger is not a pointer gesture, and says whose driver it is' ($e3 -match 'trigger' -and $e3 -match 'T2391')

    # ---- C. matrix -------------------------------------------------------------
    'C. matrix'
    $mx = @(Get-FrameLabMatrix)
    # 3 themes x 3 DPI x 3 stalls = 27 per (interaction, panes, sidebar).
    # No needs: 10 interactions x 3 panes x 3 sidebars; divider: 2 panes x 3;
    # sidebar-edge and blade-glide: 3 panes x 2 sidebars.
    $plain = @($cat | Where-Object { $_.Needs.Count -eq 0 }).Count
    $expect = 27 * ($plain * 9 + 2 * 3 + 2 * (3 * 2))
    Assert "C1 full matrix = the product minus what cannot apply ($expect cells)" ($mx.Count -eq $expect) "n=$($mx.Count)"
    Assert 'C2 ids are unique' ((@($mx.Id | Select-Object -Unique)).Count -eq $mx.Count)
    Assert 'C3 no divider cell with one pane, no sidebar-edge cell with the sidebar hidden' `
        (@($mx | Where-Object { ($_.Interaction -eq 'divider' -and $_.Panes -eq 1) -or ($_.Interaction -eq 'sidebar-edge' -and $_.Sidebar -eq 'hidden') }).Count -eq 0)
    Assert 'C4 every trigger cell is listed, Blocked with its driver task' `
        (@($mx | Where-Object { $_.Kind -eq 'trigger' -and $_.Blocked -notmatch 'T2391' }).Count -eq 0 -and @($mx | Where-Object { $_.Kind -eq 'trigger' }).Count -gt 0)
    Assert 'C5 every stalled cell is listed, Blocked until the knob exists' `
        (@($mx | Where-Object { $_.StallMs -gt 0 -and $_.Blocked -notmatch 'T2360' }).Count -eq 0)
    $runnable = @($mx | Where-Object { -not $_.Blocked })
    Assert 'C6 runnable today = pointer cells at stall 0' `
        ($runnable.Count -gt 0 -and @($runnable | Where-Object { $_.Kind -ne 'pointer' -or $_.StallMs -ne 0 }).Count -eq 0)
    $one = @(Get-FrameLabMatrix -Interaction divider -Panes 4 -Theme flat -Dpi 150 -Sidebar rail -StallMs 0)
    Assert 'C7 filters narrow to one cell with a readable id' `
        ($one.Count -eq 1 -and $one[0].Id -eq 'divider/p4/flat/dpi150/sb-rail/stall0' -and -not $one[0].Blocked) "$($one.Id)"
    $e4 = try { $null = Get-FrameLabMatrix -Interaction nope; '' } catch { $_.Exception.Message }
    Assert 'C8 an unknown interaction name is refused, not an empty matrix' ($e4 -match 'unknown')

    # ---- D. protocol -----------------------------------------------------------
    'D. protocol (fake driver)'
    function New-FakeDriver([hashtable]$Opt = @{}) {
        $log = New-Object System.Collections.ArrayList
        # GetNewClosure sees locals, not this script's scope: copy the scene in.
        $scene = $geo
        $d = @{ Log = $log }
        $d.Presence = { if ($Opt.Present) { [pscustomobject]@{ Present = $true; Reason = 'input 2s ago' } } else { [pscustomobject]@{ Present = $false; Reason = 'idle 900s' } } }.GetNewClosure()
        # A closure made inside a closure captures locals only, so the inner
        # Close needs its own local copy of the log.
        $d.Launch = {
            param($Cell)
            [void]$log.Add("launch $($Cell.Id)")
            $l = $log
            @{ Geometry = $scene; Close = { [void]$l.Add('close') }.GetNewClosure() }
        }.GetNewClosure()
        $d.StartCapture = { param($Rect, $Dup) [void]$log.Add("start dup=$Dup w=$($Rect.W)"); @{ Dup = $Dup } }.GetNewClosure()
        $d.Play = {
            param($Path)
            [void]$log.Add("play n=$($Path.Length) first=$($Path[0].X),$($Path[0].Y)")
            $abort = $Opt.AbortFirst -and @($log | Where-Object { $_ -like 'play*' }).Count -eq 1
            [pscustomobject]@{ Skipped = $false; SkipReason = ''; Aborted = [bool]$abort; AbortReason = $(if ($abort) { 'user-input' } else { '' }) }
        }.GetNewClosure()
        $d.StopCapture = {
            param($S)
            [void]$log.Add("stop dup=$($S.Dup)")
            $tl = @(
                [pscustomobject]@{ Index = 0; Superseded = $false }
                [pscustomobject]@{ Index = 1; Superseded = $true }
                [pscustomobject]@{ Index = 2; Superseded = $false }
            )
            @{ Stats = [pscustomobject]@{ SlotGaps = 3 }; Account = $(if ($S.Dup) { [pscustomobject]@{ Skipped = [long]$Opt.Skipped } } else { $null }); Timeline = $tl }
        }.GetNewClosure()
        $d.Score = {
            param($Cap, $Frames, $G, $Played)
            [void]$log.Add("score frames=$(@($Frames.Index) -join ',')")
            if ($Opt.ScoreThrows) { throw 'scorer blew up' }
            @{ BleedFrames = [int]$Opt.Bleed; MotionMisses = @($Opt.Misses | Where-Object { $_ }) }
        }.GetNewClosure()
        return $d
    }
    $cell = (Get-FrameLabMatrix -Interaction frame-right -Panes 1 -Theme flat -Dpi 100 -Sidebar hidden -StallMs 0)

    $d = New-FakeDriver @{ Present = $true }
    $r = Invoke-FrameLabCell -Cell $cell -Driver $d
    Assert 'D1 a present user: skipped, and nothing launched or played' ($r.Verdict.Verdict -eq 'skipped' -and $d.Log.Count -eq 0 -and $r.Verdict.Reasons[0] -match 'input 2s ago')

    $d = New-FakeDriver @{}
    $r = Invoke-FrameLabCell -Cell $cell -Driver $d
    $order = @($d.Log | ForEach-Object { ($_ -split ' ')[0] + $(if ($_ -match 'dup=(\w+)') { ':' + $Matches[1] } else { '' }) })
    Assert 'D2 order: launch, capture-only measure, score, duplication accounting, close' `
        (($order -join ' ') -eq 'launch start:False play stop:False score start:True play stop:True close') ($order -join ' ')
    $plays = @($d.Log | Where-Object { $_ -like 'play*' })
    Assert 'D3 the accounting run replays the identical path' ($plays.Count -eq 2 -and $plays[0] -eq $plays[1]) ($plays -join ' | ')
    Assert 'D4 Superseded frames never reach the scorer (frames 0,2 of 0,1,2)' (@($d.Log | Where-Object { $_ -eq 'score frames=0,2' }).Count -eq 1)
    Assert 'D5 a clean cell with clean accounting passes, SlotGaps carried, superseded counted' `
        ($r.Verdict.Verdict -eq 'pass' -and $r.Verdict.SlotGaps -eq 3 -and $r.Measure.Superseded -eq 1 -and $r.Measure.Scored -eq 2)

    $d = New-FakeDriver @{ ScoreThrows = $true }
    $threw = try { $null = Invoke-FrameLabCell -Cell $cell -Driver $d; $false } catch { $true }
    Assert 'D6 the scene closes even when the scorer throws (and the throw is not swallowed)' ($threw -and $d.Log[-1] -eq 'close')

    $d = New-FakeDriver @{ AbortFirst = $true }
    $r = Invoke-FrameLabCell -Cell $cell -Driver $d
    Assert 'D7 an aborted measurement is aborted, not scored, and runs no accounting' `
        ($r.Verdict.Verdict -eq 'aborted' -and @($d.Log | Where-Object { $_ -like 'score*' -or $_ -like 'start dup=True*' }).Count -eq 0 -and $d.Log[-1] -eq 'close')

    $blk = (Get-FrameLabMatrix -Interaction banner -Panes 1 -Theme flat -Dpi 100 -Sidebar hidden -StallMs 0)
    $d = New-FakeDriver @{}
    $r = Invoke-FrameLabCell -Cell $blk -Driver $d
    Assert 'D8 a blocked cell reports blocked with its reason and touches nothing' ($r.Verdict.Verdict -eq 'blocked' -and $r.Verdict.Reasons[0] -match 'T2391' -and $d.Log.Count -eq 0)

    $d = New-FakeDriver @{ Skipped = 5 }
    $r = Invoke-FrameLabCell -Cell $cell -Driver $d
    Assert 'D9 accounting that names skipped frames makes a clean cell incomplete' ($r.Verdict.Verdict -eq 'incomplete' -and $r.Verdict.Reasons[0] -match '5 composed')
    $e5 = try { $null = Invoke-FrameLabCell -Cell $cell -Driver @{ Presence = {} }; '' } catch { $_.Exception.Message }
    Assert 'D10 a driver missing a piece is refused up front' ($e5 -match 'driver has no')

    # ---- E. verdict ------------------------------------------------------------
    'E. verdict'
    $ok = [pscustomobject]@{ Skipped = $false; Aborted = $false }
    $clean = [pscustomobject]@{ Skipped = 0 }
    Assert 'E1 bleed fails' ((Resolve-FrameLabCellVerdict -Input1 $ok -BleedFrames 2 -Account $clean).Verdict -eq 'fail')
    Assert 'E2 a missed motion target fails, the miss named' `
        (($v = Resolve-FrameLabCellVerdict -Input1 $ok -MotionMisses @('longest stall 3 refreshes > 1') -Account $clean).Verdict -eq 'fail' -and $v.Reasons[0] -match 'stall')
    Assert 'E3 clean with no accounting is incomplete' ((Resolve-FrameLabCellVerdict -Input1 $ok).Verdict -eq 'incomplete')
    Assert 'E4 a fail outranks incomplete (missing frames only hide more)' `
        ((Resolve-FrameLabCellVerdict -Input1 $ok -BleedFrames 1 -Account ([pscustomobject]@{ Skipped = 9 })).Verdict -eq 'fail')
    Assert 'E5 clean and fully accounted passes; SlotGaps beside it' `
        (($v = Resolve-FrameLabCellVerdict -Input1 $ok -Account $clean -SlotGaps 7).Verdict -eq 'pass' -and $v.SlotGaps -eq 7)
    Assert 'E6 a skipped input is skipped with its reason' `
        (($v = Resolve-FrameLabCellVerdict -Input1 ([pscustomobject]@{ Skipped = $true; SkipReason = 'somebody is using this box' })).Verdict -eq 'skipped' -and $v.Reasons[0] -match 'somebody')
    Assert 'E7 negative control: an empty miss list is not a fail' `
        ((Resolve-FrameLabCellVerdict -Input1 $ok -MotionMisses @('') -Account $clean).Verdict -eq 'pass')

    Complete-TestBody
}
catch {
    "  FAIL unexpected: $($_.Exception.Message) at $($_.InvocationInfo.PositionMessage) $($_.ScriptStackTrace)"
    $script:failures++
}

# A green run stamps the covered files (T783); red or skipped stays due.
if ($script:failures -eq 0 -and $script:skipped -eq 0) {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard frame-lab-catalogue -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

''
Write-TestVerdict -Label 'T2389 FRAME-LAB-CATALOGUE' -Pass $script:passes -Fail $script:failures -Skipped $script:skipped
