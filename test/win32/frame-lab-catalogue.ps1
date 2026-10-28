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
       incomplete (and a fail outranks it); SlotGaps rides beside it;
    F. trigger plans (T2391) - every trigger builds a plan of the act its
       interaction names (the maximize button clicked and the restore button
       clicked, the sidebar toggle twice, +set-banner on then --clear,
       ctrl+shift+space twice, ctrl+tab then ctrl+shift+tab, +split then
       +close of the same name), out and back; blade-glide carries two glides
       on the sidebar edge; missing geometry and pointer names are refused;
       chords parse to virtual keys and an unknown key is refused;
    G. the trigger player against a recording sink - every step fired in
       order, each stamped on the QPC clock (inside readings taken around the
       run, never before its planned time, Start <= Fire <= Done with the
       fire at Done for input and at Start for IPC); a present user fires
       nothing; the user's hand aborts between steps; a failed send stops it;
       trigger cells run the protocol with Fire, twice, and never Play;
    H. the glide's Expected - the ease is pane_sidebar_transition.zig's curve
       and duration (read back from the source, so they cannot drift), the
       motion args put each frame's expected edge on it from each fire, and
       Measure-FrameMotion scores a frame-perfect glide as on the curve and a
       snap as far off it.

  The live run (input desktop, idle box) is T2392's input-desktop exception.
  ASCII-only by design (PS 5.1 on this box mangles non-ASCII on rewrite).

  powershell -NoProfile -File test\win32\frame-lab-catalogue.ps1
#>
# isolation: none - the CLI verbs here (set-banner, split, close) are trigger-plan fixtures compared as text and played into a recording sink; this script launches no ghoztty and runs no CLI
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
. (Join-Path $PSScriptRoot 'lib\FrameScore.ps1')

# A 1200x800 window at (400, 200) on a 2560x1400 work area, split once, with a
# sidebar edge 260 px in (114 px collapsed to the rail), its toggle, the
# caption's maximize button and a named pane for IPC.
$geo = @{
    Window  = @{ X = 400; Y = 200; W = 1200; H = 800 }
    Monitor = @{ X = 0; Y = 0; W = 2560; H = 1400 }
    Caption = 215
    Divider = @{ X = 1100; Y0 = 260; Y1 = 990 }
    Sidebar = @{ EdgeX = 660; OtherEdgeX = 514; Y0 = 260; Y1 = 990; Toggle = @{ X = 440; Y = 280 } }
    MaximizeButton = @{ X = 1530; Y = 215 }
    Target  = 'lab'
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
    Assert 'C4 no cell reads "no driver yet": every trigger cell is listed and runs at stall 0 (T2391)' `
        (@($mx | Where-Object { $_.Blocked -match 'no driver' }).Count -eq 0 -and
         @($mx | Where-Object { $_.Kind -eq 'trigger' -and $_.StallMs -eq 0 -and -not $_.Blocked }).Count -eq @($mx | Where-Object { $_.Kind -eq 'trigger' -and $_.StallMs -eq 0 }).Count -and
         @($mx | Where-Object { $_.Kind -eq 'trigger' }).Count -gt 0)
    Assert 'C5 every stalled cell is listed, Blocked until the knob exists' `
        (@($mx | Where-Object { $_.StallMs -gt 0 -and $_.Blocked -notmatch 'T2360' }).Count -eq 0)
    $runnable = @($mx | Where-Object { -not $_.Blocked })
    Assert 'C6 runnable today = pointer and trigger cells at stall 0' `
        ($runnable.Count -gt 0 -and @($runnable | Where-Object { $_.StallMs -ne 0 }).Count -eq 0 -and
         @($runnable | Where-Object { $_.Kind -eq 'trigger' }).Count -gt 0)
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

    $blk = (Get-FrameLabMatrix -Interaction frame-right -Panes 1 -Theme flat -Dpi 100 -Sidebar hidden -StallMs 50)
    $d = New-FakeDriver @{}
    $r = Invoke-FrameLabCell -Cell $blk -Driver $d
    Assert 'D8 a blocked cell reports blocked with its reason and touches nothing' ($r.Verdict.Verdict -eq 'blocked' -and $r.Verdict.Reasons[0] -match 'T2360' -and $d.Log.Count -eq 0)

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

    # ---- F. trigger plans (T2391) ----------------------------------------------
    'F. trigger plans'
    $trig = @($cat | Where-Object { $_.Kind -eq 'trigger' })
    $plans = @{}
    foreach ($t in $trig) { $plans[$t.Name] = Get-FrameLabTrigger -Name $t.Name -Geometry $geo -SettleMs 500 -LeadMs 100 }
    Assert 'F1 every trigger builds a plan of two steps, out and back, in time order' `
        (@($trig | Where-Object { $p = $plans[$_.Name]; -not $p -or @($p.Steps).Count -ne 2 -or $p.Steps[1].AtMs -le $p.Steps[0].AtMs }).Count -eq 0 -and $trig.Count -eq 6)
    $mx1 = $plans['maximize-button']
    Assert 'F2 maximize-button clicks the maximize button, then the restore button where the maximized window puts it, over the whole monitor' `
        ($mx1.Steps[0].Action -eq 'click' -and $mx1.Steps[0].X -eq 1530 -and $mx1.Steps[0].Y -eq 215 -and
         $mx1.Steps[1].X -eq 2560 - (1600 - 1530) -and $mx1.Steps[1].Y -eq 15 -and $mx1.CaptureRect.W -eq 2560 -and $mx1.Axis -eq 'none') `
        "restore=($($mx1.Steps[1].X),$($mx1.Steps[1].Y))"
    $bg = $plans['blade-glide']
    Assert 'F3 blade-glide clicks the sidebar toggle twice and tracks the sidebar edge' `
        (@($bg.Steps | Where-Object { $_.Action -eq 'click' -and $_.X -eq 440 -and $_.Y -eq 280 }).Count -eq 2 -and $bg.Axis -eq 'x' -and $bg.Track -eq 'sidebar-edge')
    Assert 'F4 blade-glide carries a glide per click: edge -> other mode -> back, 240 ms each' `
        (@($bg.Glides).Count -eq 2 -and $bg.Glides[0].FromPx -eq 660 -and $bg.Glides[0].ToPx -eq 514 -and
         $bg.Glides[1].FromPx -eq 514 -and $bg.Glides[1].ToPx -eq 660 -and @($bg.Glides | Where-Object { $_.Ms -ne 240 }).Count -eq 0)
    $bn = $plans['banner']
    Assert 'F5 banner: +set-banner on the scene pane, then --clear; tracks the pane top' `
        ($bn.Steps[0].Action -eq 'ipc' -and ($bn.Steps[0].Args -join ' ') -match '^\+set-banner --target=lab \S' -and
         ($bn.Steps[1].Args -join ' ') -eq '+set-banner --target=lab --clear' -and $bn.Axis -eq 'y' -and $bn.Track -eq 'pane-top')
    Assert 'F6 hero: ctrl+shift+space in and out' (@($plans['hero'].Steps | Where-Object { $_.Action -eq 'keys' -and $_.Chord -eq 'ctrl+shift+space' }).Count -eq 2)
    $ts = $plans['tab-switch']
    Assert 'F7 tab-switch: ctrl+tab, then ctrl+shift+tab back' ($ts.Steps[0].Chord -eq 'ctrl+tab' -and $ts.Steps[1].Chord -eq 'ctrl+shift+tab')
    $sc1 = $plans['split-close']
    Assert 'F8 split-close: +split right of the scene pane under a name, then +close of that name' `
        (($sc1.Steps[0].Args -join ' ') -eq '+split --direction=right --target=lab --name=framelab-split' -and ($sc1.Steps[1].Args -join ' ') -eq '+close --target=framelab-split')
    Assert 'F9 bleed-only triggers track nothing and carry no glide' `
        (@('maximize-button', 'hero', 'tab-switch', 'split-close' | Where-Object { $plans[$_].Axis -ne 'none' -or @($plans[$_].Glides).Count }).Count -eq 0)
    Assert 'F10 the run lasts the last step plus its settle' ($plans['hero'].DurationMs -eq 100 + 500 + 500)
    $e6 = try { $null = Get-FrameLabTrigger -Name blade-glide -Geometry @{ Window = $geo.Window; Monitor = $geo.Monitor; Sidebar = @{ EdgeX = 660 } }; '' } catch { $_.Exception.Message }
    Assert 'F11 blade-glide without the other edge or the toggle is refused' ($e6 -match 'OtherEdgeX')
    $e7 = try { $null = Get-FrameLabTrigger -Name banner -Geometry @{ Window = $geo.Window; Monitor = $geo.Monitor }; '' } catch { $_.Exception.Message }
    Assert 'F12 an IPC trigger with no target pane is refused' ($e7 -match 'Target')
    $e8 = try { $null = Get-FrameLabTrigger -Name divider -Geometry $geo; '' } catch { $_.Exception.Message }
    Assert 'F13 a pointer gesture is not a trigger' ($e8 -match 'pointer gesture')
    $vk = ConvertTo-FrameLabChord 'ctrl+shift+space'
    Assert 'F14 chords parse to virtual keys, modifiers first' (($vk -join ',') -eq '17,16,32') ($vk -join ',')
    Assert 'F15 letters, F-keys and tab parse' (((ConvertTo-FrameLabChord 'ctrl+shift+s') -join ',') -eq '17,16,83' -and ((ConvertTo-FrameLabChord 'f11') -join ',') -eq '122' -and ((ConvertTo-FrameLabChord 'ctrl+tab') -join ',') -eq '17,9')
    $e9 = try { $null = ConvertTo-FrameLabChord 'ctrl+banana'; '' } catch { $_.Exception.Message }
    Assert 'F16 an unknown key is refused, not half a chord' ($e9 -match 'banana')

    # ---- G. trigger player (recording sink) ------------------------------------
    'G. trigger player'
    function New-RecordingTriggerSink([hashtable]$Opt = @{}) {
        $acts = New-Object System.Collections.ArrayList
        $sink = @{ Acts = $acts }
        $sink.Click = { param($X, $Y) [void]$acts.Add([pscustomobject]@{ What = "click $X,$Y"; Qpc = [GliClock]::Now() }); Start-Sleep -Milliseconds 3; -not $Opt.FailClick }.GetNewClosure()
        $sink.Keys = { param($Chord) [void]$acts.Add([pscustomobject]@{ What = "keys $Chord"; Qpc = [GliClock]::Now() }); $true }.GetNewClosure()
        $sink.Ipc = { param([string[]]$A) [void]$acts.Add([pscustomobject]@{ What = "ipc $($A -join ' ')"; Qpc = [GliClock]::Now() }); Start-Sleep -Milliseconds 20; $true }.GetNewClosure()
        $sink.UserActive = { $Opt.UserAfter -and $acts.Count -ge $Opt.UserAfter }.GetNewClosure()
        return $sink
    }
    $rs = New-RecordingTriggerSink
    $before = [GliClock]::Now()
    $fr = Invoke-FrameLabTrigger -Plan $bn -Sink $rs
    $after = [GliClock]::Now()
    Assert 'G1 a recording sink is past the gate, and every step fires in order' `
        (-not $fr.Skipped -and -not $fr.Aborted -and @($fr.Stamps).Count -eq 2 -and ($rs.Acts.What -join '|') -eq (($bn.Steps | ForEach-Object { "ipc $($_.Args -join ' ')" }) -join '|')) `
        ($rs.Acts.What -join '|')
    $st = @($fr.Stamps)
    Assert 'G2 fire stamps are on the QPC clock: inside readings taken around the run, never before their planned time' `
        (@($st | Where-Object { $_.FireQpc -lt $before -or $_.FireQpc -gt $after -or $_.StartQpc -lt $_.PlannedQpc }).Count -eq 0 -and $fr.Frequency -eq [GliClock]::Frequency)
    $gapMs = ($st[1].PlannedQpc - $st[0].PlannedQpc) * 1000.0 / $fr.Frequency
    Assert 'G3 the steps are planned SettleMs apart, from the origin plus the lead' `
        ([math]::Abs($gapMs - 500) -lt 0.01 -and [math]::Abs(($st[0].PlannedQpc - $fr.OriginQpc) * 1000.0 / $fr.Frequency - 100) -lt 0.01) "gap=$gapMs"
    Assert 'G4 an IPC fire is its start (the app can act before the CLI returns), and its spread is recorded' `
        (@($st | Where-Object { $_.FireQpc -ne $_.StartQpc -or $_.DoneQpc -lt $_.StartQpc -or $_.FireSpreadUs -lt 15000 }).Count -eq 0) "spread=$($st.FireSpreadUs -join ',')"
    Assert 'G5 the sink saw each act between the step''s Start and Done' `
        ($rs.Acts[0].Qpc -ge $st[0].StartQpc -and $rs.Acts[0].Qpc -le $st[0].DoneQpc -and $rs.Acts[1].Qpc -ge $st[1].StartQpc -and $rs.Acts[1].Qpc -le $st[1].DoneQpc)
    $rs = New-RecordingTriggerSink
    $fc = Invoke-FrameLabTrigger -Plan $bg -Sink $rs
    Assert 'G6 a click fire is when the input call returned (Done), never its start' `
        (@($fc.Stamps | Where-Object { $_.FireQpc -ne $_.DoneQpc -or $_.DoneQpc -le $_.StartQpc }).Count -eq 0 -and ($rs.Acts.What -join '|') -eq 'click 440,280|click 440,280')
    $fp = Invoke-FrameLabTrigger -Plan $bg -Presence ([pscustomobject]@{ Present = $true; Reason = 'input 1s ago' })
    Assert 'G7 a present user: skipped with the reason, nothing fired' ($fp.Skipped -and $fp.SkipReason -match 'input 1s ago' -and @($fp.Stamps).Count -eq 0)
    $fn = Invoke-FrameLabTrigger -Plan $bg -Presence $null -Sink $null -DryRun
    Assert 'G8 a dry run times the steps and sends nothing' (-not $fn.Skipped -and @($fn.Stamps).Count -eq 2 -and $fn.DryRun)
    $rs = New-RecordingTriggerSink @{ UserAfter = 1 }
    $fu = Invoke-FrameLabTrigger -Plan $bg -Sink $rs
    Assert 'G9 the user''s hand between steps aborts the run before the next act' ($fu.Aborted -and $fu.AbortReason -eq 'user-input' -and $fu.AbortIndex -eq 1 -and $rs.Acts.Count -eq 1)
    $rs = New-RecordingTriggerSink @{ FailClick = $true }
    $ff = Invoke-FrameLabTrigger -Plan $bg -Sink $rs
    Assert 'G10 a failed send stops the run there' ($ff.Aborted -and $ff.AbortReason -eq 'send-failed' -and $ff.AbortIndex -eq 0 -and $rs.Acts.Count -eq 1)
    $js = @(ConvertTo-FrameLabTriggerStamps $fr)
    Assert 'G11 stamp JSON: fire microseconds from the origin, with the origin QPC beside them' `
        ($js.Count -eq 2 -and $js[0].originQpc -eq $fr.OriginQpc -and $js[0].fireUs -ge 100000 -and $js[1].fireUs -ge 600000 -and $js[0].label -eq 'banner on')

    # A trigger cell through the protocol: Fire twice (measure, account), never Play.
    $tcell = (Get-FrameLabMatrix -Interaction blade-glide -Panes 1 -Theme flat -Dpi 100 -Sidebar expanded -StallMs 0)
    $d = New-FakeDriver @{}
    $fired = New-Object System.Collections.ArrayList
    $d.Fire = { param($Plan) [void]$fired.Add($Plan); [void]$d.Log.Add("fire $($Plan.Name) n=$(@($Plan.Steps).Count)"); [pscustomobject]@{ Skipped = $false; Aborted = $false; Stamps = @() } }.GetNewClosure()
    $d.Remove('Play')
    $r = Invoke-FrameLabCell -Cell $tcell -Driver $d
    $order = @($d.Log | ForEach-Object { ($_ -split ' ')[0] + $(if ($_ -match 'dup=(\w+)') { ':' + $Matches[1] } else { '' }) })
    Assert 'G12 a trigger cell runs: launch, measure (Fire), score, account (Fire again), close - no Play needed' `
        (($order -join ' ') -eq 'launch start:False fire stop:False score start:True fire stop:True close' -and $r.Verdict.Verdict -eq 'pass') ($order -join ' ')
    Assert 'G13 both runs fire the same plan, built from the scene geometry' `
        ($fired.Count -eq 2 -and [object]::ReferenceEquals($fired[0], $fired[1]) -and $fired[0].Name -eq 'blade-glide' -and $r.Gesture.Track -eq 'sidebar-edge')
    $d2 = New-FakeDriver @{}
    $e10 = try { $null = Invoke-FrameLabCell -Cell $tcell -Driver $d2; '' } catch { $_.Exception.Message }
    Assert 'G14 a trigger cell with a driver that cannot Fire is refused up front' ($e10 -match 'driver has no Fire')

    # ---- H. the glide's Expected -----------------------------------------------
    'H. glide expected'
    $zig = Get-Content -Raw (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'src\apprt\win32\pane_sidebar_transition.zig')
    $zMs = $(if ($zig -match 'pub const column_ms: u64 = (\d+);') { [int]$Matches[1] } else { -1 })
    $zCurve = $(if ($zig -match 'const curve = \[4\]f64\{ ([\d.]+), ([\d.]+), ([\d.]+), ([\d.]+) \};') { @([double]$Matches[1], [double]$Matches[2], [double]$Matches[3], [double]$Matches[4]) } else { @() })
    Assert 'H1 the glide is the app''s: column_ms and the timing curve read back from pane_sidebar_transition.zig' `
        ($zMs -eq $bg.Glides[0].Ms -and ($zCurve -join ',') -eq ($bg.Glides[0].Curve -join ',')) "zig ms=$zMs curve=$($zCurve -join ',')"
    $e25 = Get-FrameLabEase 0.25; $e50 = Get-FrameLabEase 0.5
    Assert 'H2 the ease is 0 at the start, 1 at the end, monotone, and a strong ease-out' `
        ((Get-FrameLabEase 0) -eq 0 -and (Get-FrameLabEase 1) -eq 1 -and $e25 -gt 0.6 -and $e50 -gt $e25 -and $e50 -lt 1 -and
         @(0..19 | Where-Object { (Get-FrameLabEase (($_ + 1) / 20)) -lt (Get-FrameLabEase ($_ / 20)) }).Count -eq 0) "e(.25)=$e25 e(.5)=$e50"

    # A synthetic run at 120 Hz: fires at 100 ms and 600 ms after the origin,
    # frames every refresh from 0 to 1100 ms, on the QPC clock.
    $F = [GliClock]::Frequency
    $o = [long]1000000000
    $fake = [pscustomobject]@{ Frequency = $F; Stamps = @(
        [pscustomobject]@{ FireQpc = $o + [long](0.100 * $F) }
        [pscustomobject]@{ FireQpc = $o + [long](0.600 * $F) }) }
    $period = 1000.0 / 120
    $n = [int](1100 / $period)
    $fq = [long[]]@(0..($n - 1) | ForEach-Object { $o + [long](($_ * $period / 1000.0) * $F) })
    $none = [double[]]@(0..($n - 1) | ForEach-Object { 0.0 })
    $ma = Get-FrameLabTriggerMotionArgs -Plan $bg -Fired $fake -FrameQpc $fq -Position $none -PeriodMs $period
    $ex = $ma.Expected
    $tAt = { param($ms) $k = 0; for ($i = 0; $i -lt $ma.Time.Length; $i++) { if ($ma.Time[$i] -le $ms) { $k = $i } }; $k }
    Assert 'H3 times are ms from the first fire, on the frames'' QPC' ([math]::Abs($ma.Time[0] + 100) -lt 0.01 -and $ma.Start -eq 0 -and [math]::Abs($ma.End - (500 + 240)) -lt 0.01) "t0=$($ma.Time[0]) end=$($ma.End)"
    Assert 'H4 expected: the edge before the first fire, eased toward the other mode after it, settled by 240 ms' `
        ($ex[(& $tAt -50)] -eq 660 -and $ex[(& $tAt 60)] -lt 660 -and $ex[(& $tAt 60)] -gt 514 -and [math]::Abs($ex[(& $tAt 300)] - 514) -lt 0.01)
    Assert 'H5 the second fire glides it back from where the first left it' `
        ([math]::Abs($ex[(& $tAt 499)] - 514) -lt 0.01 -and $ex[(& $tAt 560)] -gt 514 -and [math]::Abs($ex[(& $tAt 800)] - 660) -lt 0.01)
    $k60 = & $tAt 60
    Assert 'H6 each expected value is the curve at that frame''s time since its fire' `
        ([math]::Abs($ex[$k60] - (660 + (514 - 660) * (Get-FrameLabEase ($ma.Time[$k60] / 240)))) -lt 1e-9)
    $ma.Position = [double[]]@($ex | ForEach-Object { [math]::Round($_) })
    $good = Measure-FrameMotion @ma
    Assert 'H7 Measure-FrameMotion scores a frame-perfect glide as on the curve (dev <= 0.5 px)' ($good.MaxCurveDev -le 0.5) "$good"
    $ma.Position = [double[]]@(0..($n - 1) | ForEach-Object { if ($ma.Time[$_] -lt 0) { 660 } elseif ($ma.Time[$_] -lt 500) { 514 } else { 660 } })
    $snap = Measure-FrameMotion @ma
    Assert 'H8 negative control: a snap is scored far off the curve (> 50 px)' ($snap.MaxCurveDev -gt 50) "$snap"
    $e11 = try { $null = Get-FrameLabTriggerMotionArgs -Plan $plans['hero'] -Fired $fake -FrameQpc $fq -Position $none -PeriodMs $period; '' } catch { $_.Exception.Message }
    Assert 'H9 a bleed-only trigger has no motion to measure' ($e11 -match 'bleed only')
    $half = [pscustomobject]@{ Frequency = $F; Stamps = @($fake.Stamps[0]) }
    $e12 = try { $null = Get-FrameLabTriggerMotionArgs -Plan $bg -Fired $half -FrameQpc $fq -Position $none -PeriodMs $period; '' } catch { $_.Exception.Message }
    Assert 'H10 a run that did not fire every step is not scored' ($e12 -match 'incomplete')
    $bm = Get-FrameLabTriggerMotionArgs -Plan $bn -Fired $fake -FrameQpc $fq -Position $none -PeriodMs $period -SettleMs 400
    Assert 'H11 a tracked trigger with no glide: no Expected, window to the last fire plus the settle' (-not $bm.ContainsKey('Expected') -and [math]::Abs($bm.End - 900) -lt 0.01)

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
Write-TestVerdict -Label 'T2389/T2391 FRAME-LAB-CATALOGUE' -Pass $script:passes -Fail $script:failures -Skipped $script:skipped
