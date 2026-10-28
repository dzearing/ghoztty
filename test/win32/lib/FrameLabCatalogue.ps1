# FrameLabCatalogue (T2389) - WHAT the T2373 frame lab drives, over WHICH
# matrix, and the per-cell run protocol that turns one capture into a verdict.
#
# The lab's other parts each answer one question: FrameLabInput (T2384) plays a
# path at 1 kHz on QPC, FrameCapture (T2382) photographs every composed frame on
# the same clock, FrameScore (T2381) calls each frame clean or bleeding and
# measures the motion, FrameLabCard (T2383) makes the scene scoreable. None of
# them says which gestures to make, against what layouts, or in what order the
# runs go. That is this file, and it is pure: no window, no screen, no input.
#
# THE CATALOGUE (Get-FrameLabInteractions). Every interaction T2373 names is
# listed, and each is one of:
#
#   pointer  a gesture: Get-FrameLabGesture builds its GliSample path from the
#            scene's geometry (physical pixels), names the edge whose motion is
#            measured and the window of the path in which motion is due
#   trigger  fired by a click, a key chord or an IPC verb, not a pointer path
#            (blade glide, banner, hero, tab switch, split/close, the maximize
#            button). Get-FrameLabTrigger (lib\FrameLabTrigger.ps1, T2391)
#            builds its plan from the scene's geometry, and every fire is
#            stamped on the capture's QPC clock
#
# Every pointer gesture that moves an edge is a SHUTTLE with an even number of
# legs: out and back, the user's "janks back and forth", which is also what the
# reversal check needs - and it leaves the window where it started, so the
# accounting run replays the very same path against the very same geometry.
#
# THE MATRIX (Get-FrameLabMatrix): interaction x panes (1/4/9) x theme (flat/
# elevated/glass) x DPI (100/150/200) x sidebar (expanded/rail/hidden) x UI
# stall (0/50/500 ms). Refresh rate and monitor layout are the box's, not
# knobs: a cell records them when it runs. An interaction that cannot apply to
# a layout (a divider drag with one pane, a sidebar-edge drag with no sidebar)
# is pruned; a cell that applies but cannot be driven yet carries Blocked with
# the reason, and is still listed.
#
# THE PROTOCOL (Invoke-FrameLabCell), from T2384's 2026-10-27 23:50 entry:
#
#   1. presence first - nothing launches while somebody is using the box
#   2. a CAPTURE-ONLY measurement run: Desktop Duplication beside a capture
#      made DWM miss 5-16% of refreshes, so the run that is scored has none
#   3. drop Superseded frames (a later frame shares the refresh slot, so only
#      the later one was ever on screen) before anything is scored
#   4. a SEPARATE -Duplication accounting run of the same path, whose only job
#      is to say how many composed frames the capture missed; a cell whose
#      accounting is missing or names skipped frames is `incomplete`, never a
#      quietly smaller pass
#   5. SlotGaps (refreshes nobody got a frame on) reported beside AdvanceRate
#
# A trigger cell runs the same protocol with Fire in place of Play: the plan
# is fired once for the measurement and once more for the accounting.
#
# The live pieces (launching the scene, the C# scorer bridge, SendInput) come
# in through -Driver, so the whole protocol is proved here with fakes and the
# live driver is the input-desktop exception's business (T2392).
#
# Acceptance: test\win32\frame-lab-catalogue.ps1.
# ASCII-only by design (PS 5.1 on this box mangles non-ASCII on rewrite).

Set-StrictMode -Off

if (-not (Get-Command New-FrameLabPath -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'FrameLabInput.ps1')
}
if (-not (Get-Command Get-FrameLabTrigger -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'FrameLabTrigger.ps1')
}

$script:FrameLabMatrixAxes = [ordered]@{
    Panes   = @(1, 4, 9)
    Theme   = @('flat', 'elevated', 'glass')
    Dpi     = @(100, 150, 200)
    Sidebar = @('expanded', 'rail', 'hidden')
    StallMs = @(0, 50, 500)
}

# The UI-stall knob T2373 names comes from T2360; until it exists a stalled
# cell is listed and blocked rather than run as if it had stalled.
$script:FrameLabStallKnob = $null

<#
The catalogue. Name, Kind (pointer|trigger), Track (the edge measured: an axis
plus what it is), Needs (layout conditions) and, for a trigger, Driver - the
task that built the thing that fires it (lib\FrameLabTrigger.ps1).
#>
function Get-FrameLabInteractions {
    @(
        [pscustomobject]@{ Name = 'frame-right';     Kind = 'pointer'; Axis = 'x';    Track = 'window-right';  Needs = @();          Driver = '' }
        [pscustomobject]@{ Name = 'frame-bottom';    Kind = 'pointer'; Axis = 'y';    Track = 'window-bottom'; Needs = @();          Driver = '' }
        [pscustomobject]@{ Name = 'frame-corner';    Kind = 'pointer'; Axis = 'xy';   Track = 'window-right';  Needs = @();          Driver = '' }
        [pscustomobject]@{ Name = 'caption-dblclick'; Kind = 'pointer'; Axis = 'none'; Track = '';             Needs = @();          Driver = '' }
        [pscustomobject]@{ Name = 'aero-snap';       Kind = 'pointer'; Axis = 'none'; Track = '';              Needs = @();          Driver = '' }
        [pscustomobject]@{ Name = 'divider';         Kind = 'pointer'; Axis = 'x';    Track = 'divider';       Needs = @('split');   Driver = '' }
        [pscustomobject]@{ Name = 'sidebar-edge';    Kind = 'pointer'; Axis = 'x';    Track = 'sidebar-edge';  Needs = @('sidebar'); Driver = '' }
        [pscustomobject]@{ Name = 'maximize-button'; Kind = 'trigger'; Axis = 'none'; Track = '';              Needs = @();          Driver = 'T2391' }
        [pscustomobject]@{ Name = 'blade-glide';     Kind = 'trigger'; Axis = 'x';    Track = 'sidebar-edge';  Needs = @('sidebar'); Driver = 'T2391' }
        [pscustomobject]@{ Name = 'banner';          Kind = 'trigger'; Axis = 'y';    Track = 'pane-top';      Needs = @();          Driver = 'T2391' }
        [pscustomobject]@{ Name = 'hero';            Kind = 'trigger'; Axis = 'none'; Track = '';              Needs = @();          Driver = 'T2391' }
        [pscustomobject]@{ Name = 'tab-switch';      Kind = 'trigger'; Axis = 'none'; Track = '';              Needs = @();          Driver = 'T2391' }
        [pscustomobject]@{ Name = 'split-close';     Kind = 'trigger'; Axis = 'none'; Track = '';              Needs = @();          Driver = 'T2391' }
    )
}

function Test-FrameLabApplies($Interaction, [int]$Panes, [string]$Sidebar) {
    foreach ($n in $Interaction.Needs) {
        if ($n -eq 'split' -and $Panes -lt 2) { return $false }
        if ($n -eq 'sidebar' -and $Sidebar -eq 'hidden') { return $false }
    }
    return $true
}

<#
The matrix. Each axis can be narrowed (-Panes 4, -Theme flat ...); -Interaction
takes names. Every cell has a stable Id, its knob values, and Blocked: '' when
it can run today, else why not.
#>
function Get-FrameLabMatrix {
    param(
        [string[]]$Interaction,
        [int[]]$Panes = $script:FrameLabMatrixAxes.Panes,
        [string[]]$Theme = $script:FrameLabMatrixAxes.Theme,
        [int[]]$Dpi = $script:FrameLabMatrixAxes.Dpi,
        [string[]]$Sidebar = $script:FrameLabMatrixAxes.Sidebar,
        [int[]]$StallMs = $script:FrameLabMatrixAxes.StallMs
    )
    $all = Get-FrameLabInteractions
    if ($Interaction) {
        $unknown = @($Interaction | Where-Object { $_ -notin $all.Name })
        if ($unknown.Count) { throw "Get-FrameLabMatrix: unknown interaction(s): $($unknown -join ', ')" }
        $all = @($all | Where-Object { $_.Name -in $Interaction })
    }
    foreach ($i in $all) {
        foreach ($p in $Panes) {
            foreach ($sb in $Sidebar) {
                if (-not (Test-FrameLabApplies $i $p $sb)) { continue }
                foreach ($t in $Theme) {
                    foreach ($d in $Dpi) {
                        foreach ($s in $StallMs) {
                            $blocked = @()
                            if ($s -gt 0 -and -not $script:FrameLabStallKnob) { $blocked += 'UI-stall knob not built (T2360)' }
                            [pscustomobject]@{
                                Id          = '{0}/p{1}/{2}/dpi{3}/sb-{4}/stall{5}' -f $i.Name, $p, $t, $d, $sb, $s
                                Interaction = $i.Name
                                Kind        = $i.Kind
                                Panes       = $p
                                Theme       = $t
                                Dpi         = $d
                                Sidebar     = $sb
                                StallMs     = $s
                                Blocked     = ($blocked -join '; ')
                            }
                        }
                    }
                }
            }
        }
    }
}

<#
A pointer gesture from the scene's geometry (all physical pixels):

  Window   @{ X; Y; W; H }        the window's visible rect
  Monitor  @{ X; Y; W; H }        the work area it may grow into
  Caption  y of a caption point clear of the tab strip and the buttons, and
           CaptionX for x (defaults to the window's middle)
  Divider  @{ X; Y0; Y1 }         a vertical divider (a split scene)
  Sidebar  @{ EdgeX; Y0; Y1 }     the sidebar's draggable edge
  Inset    how far inside an edge the resize hit zone is grabbed (default 3)

-Amplitude is how far each leg moves (px), -Legs (even) how many, -LegMs how
long each takes. Returns Path, Axis, Track, GrabOffset (pointer minus edge at
the press), MotionStartMs/MotionEndMs (where in the path motion is due),
CaptureRect (the window rect grown to the gesture's reach, clipped to the
monitor) and Expect (what the motion means for the edge).
#>
function Get-FrameLabGesture {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]$Geometry,
        [int]$Amplitude = 240,
        [int]$Legs = 4,
        [double]$LegMs = 600,
        [double]$SettleMs = 150,
        [double]$RateHz = 1000
    )
    if ($Legs -lt 2 -or $Legs % 2) { throw "Get-FrameLabGesture: -Legs must be even and >= 2 (it must end where it started), got $Legs" }
    $w = $Geometry.Window; $m = $Geometry.Monitor
    $inset = $(if ($Geometry.Inset) { [int]$Geometry.Inset } else { 3 })
    $b = New-FrameLabPath $RateHz
    $axis = 'none'; $track = ''; $grab = 0
    $reach = @{ X = $w.X; Y = $w.Y; R = $w.X + $w.W; B = $w.Y + $w.H }
    $motionStart = -1; $motionEnd = -1
    $msPer = 1000.0 / $RateHz

    # The motion window is the shuttle's samples: first leg sample to last.
    $shuttleAt = -1; $shuttleEnd = -1
    switch ($Name) {
        'frame-right' {
            $gx = $w.X + $w.W - 1 - $inset; $gy = $w.Y + [int]($w.H / 2)
            $axis = 'x'; $track = 'window-right'; $grab = $gx - ($w.X + $w.W)
            [void]$b.MoveTo($gx, $gy).Hold($SettleMs).Press().Hold($SettleMs)
            $shuttleAt = $b.Count; [void]$b.Shuttle($gx + $Amplitude, $gy, $Legs, $LegMs); $shuttleEnd = $b.Count - 1
            $reach.R += $Amplitude
        }
        'frame-bottom' {
            $gx = $w.X + [int]($w.W / 2); $gy = $w.Y + $w.H - 1 - $inset
            $axis = 'y'; $track = 'window-bottom'; $grab = $gy - ($w.Y + $w.H)
            [void]$b.MoveTo($gx, $gy).Hold($SettleMs).Press().Hold($SettleMs)
            $shuttleAt = $b.Count; [void]$b.Shuttle($gx, $gy + $Amplitude, $Legs, $LegMs); $shuttleEnd = $b.Count - 1
            $reach.B += $Amplitude
        }
        'frame-corner' {
            $gx = $w.X + $w.W - 1 - $inset; $gy = $w.Y + $w.H - 1 - $inset
            $axis = 'xy'; $track = 'window-right'; $grab = $gx - ($w.X + $w.W)
            [void]$b.MoveTo($gx, $gy).Hold($SettleMs).Press().Hold($SettleMs)
            $shuttleAt = $b.Count; [void]$b.Shuttle($gx + $Amplitude, $gy + $Amplitude, $Legs, $LegMs); $shuttleEnd = $b.Count - 1
            $reach.R += $Amplitude; $reach.B += $Amplitude
        }
        'divider' {
            $d = $Geometry.Divider
            if (-not $d) { throw 'Get-FrameLabGesture: divider needs Geometry.Divider (a split scene)' }
            $gx = [int]$d.X; $gy = [int](($d.Y0 + $d.Y1) / 2)
            $axis = 'x'; $track = 'divider'; $grab = 0
            [void]$b.MoveTo($gx, $gy).Hold($SettleMs).Press().Hold($SettleMs)
            # Toward the nearer window edge would squeeze a pane to its minimum
            # and stop the edge mid-leg; move into the bigger side instead.
            $dir = $(if (($w.X + $w.W - $gx) -ge ($gx - $w.X)) { 1 } else { -1 })
            $shuttleAt = $b.Count; [void]$b.Shuttle($gx + $dir * $Amplitude, $gy, $Legs, $LegMs); $shuttleEnd = $b.Count - 1
        }
        'sidebar-edge' {
            $s = $Geometry.Sidebar
            if (-not $s) { throw 'Get-FrameLabGesture: sidebar-edge needs Geometry.Sidebar (a scene with a sidebar)' }
            $gx = [int]$s.EdgeX; $gy = [int](($s.Y0 + $s.Y1) / 2)
            $axis = 'x'; $track = 'sidebar-edge'; $grab = 0
            [void]$b.MoveTo($gx, $gy).Hold($SettleMs).Press().Hold($SettleMs)
            $shuttleAt = $b.Count; [void]$b.Shuttle($gx + $Amplitude, $gy, $Legs, $LegMs); $shuttleEnd = $b.Count - 1
        }
        'caption-dblclick' {
            # Maximize, settle, restore: two double-clicks. Scored for bleed
            # only - the window jumps, nothing moves at a measurable speed.
            $cx = $(if ($Geometry.CaptionX) { [int]$Geometry.CaptionX } else { $w.X + [int]($w.W / 2) })
            $cy = [int]$Geometry.Caption
            [void]$b.MoveTo($cx, $cy).Hold($SettleMs)
            foreach ($k in 1..2) {
                [void]$b.Press().Hold(30).Release().Hold(60).Press().Hold(30).Release().Hold(700)
            }
            $reach = @{ X = $m.X; Y = $m.Y; R = $m.X + $m.W; B = $m.Y + $m.H }
        }
        'aero-snap' {
            # Drag the caption to the work area's left edge (snap left), hold
            # for the snap, and drag back off it (unsnap). Bleed only.
            $cx = $(if ($Geometry.CaptionX) { [int]$Geometry.CaptionX } else { $w.X + [int]($w.W / 2) })
            $cy = [int]$Geometry.Caption
            [void]$b.MoveTo($cx, $cy).Hold($SettleMs).Press().Hold($SettleMs)
            [void]$b.Line($m.X, $cy, $LegMs).Hold(700).Line($cx, $cy, $LegMs).Hold($SettleMs)
            $reach = @{ X = $m.X; Y = $m.Y; R = $m.X + $m.W; B = $m.Y + $m.H }
        }
        default {
            $known = Get-FrameLabInteractions | Where-Object { $_.Name -eq $Name }
            if ($known -and $known.Kind -eq 'trigger') { throw "Get-FrameLabGesture: $Name is a trigger, not a pointer gesture (Get-FrameLabTrigger plans it; driver: $($known.Driver))" }
            throw "Get-FrameLabGesture: unknown interaction '$Name'"
        }
    }
    if ($axis -ne 'none') {
        $motionStart = $shuttleAt * $msPer
        $motionEnd = $shuttleEnd * $msPer
        [void]$b.Hold($SettleMs)
    }
    [void]$b.Release()

    $x0 = [math]::Max($m.X, $reach.X); $y0 = [math]::Max($m.Y, $reach.Y)
    $x1 = [math]::Min($m.X + $m.W, $reach.R); $y1 = [math]::Min($m.Y + $m.H, $reach.B)
    [pscustomobject]@{
        Name          = $Name
        Path          = $b.Build()
        Axis          = $axis
        Track         = $track
        GrabOffset    = $grab
        MotionStartMs = $motionStart
        MotionEndMs   = $motionEnd
        Amplitude     = $(if ($axis -eq 'none') { 0 } else { $Amplitude })
        Legs          = $Legs
        CaptureRect   = [pscustomobject]@{ X = $x0; Y = $y0; W = $x1 - $x0; H = $y1 - $y0 }
    }
}

<# The frames that are scored: Superseded ones were never on screen. #>
function Select-FrameLabScoredFrames($Timeline) {
    , @($Timeline | Where-Object { -not $_.Superseded })
}

<#
One cell's verdict, from what the runs produced. Pure.

  skipped     nothing was sent (presence gate) - not a result
  aborted     the user took the pointer back mid-run - not a result
  fail        any bleed frame, or a missed smoothness target
  incomplete  clean, but the accounting run is missing or says the capture
              skipped composed frames - a pass over frames nobody saw is not
              a pass
  pass        clean and every composed frame accounted for

A fail outranks incomplete: missing frames can only hide more findings.
#>
function Resolve-FrameLabCellVerdict {
    param(
        $Input1,
        [int]$BleedFrames = 0,
        [string[]]$MotionMisses = @(),
        $Account = $null,
        [long]$SlotGaps = 0
    )
    $reasons = @()
    if ($null -eq $Input1 -or $Input1.Skipped) {
        $why = $(if ($Input1) { $Input1.SkipReason } else { 'no input result' })
        return [pscustomobject]@{ Verdict = 'skipped'; Reasons = @($why); SlotGaps = $SlotGaps }
    }
    if ($Input1.Aborted) {
        return [pscustomobject]@{ Verdict = 'aborted'; Reasons = @("input aborted: $($Input1.AbortReason)"); SlotGaps = $SlotGaps }
    }
    if ($BleedFrames -gt 0) { $reasons += "$BleedFrames bleed frame(s)" }
    $reasons += @($MotionMisses | Where-Object { $_ })
    if ($reasons.Count) { return [pscustomobject]@{ Verdict = 'fail'; Reasons = $reasons; SlotGaps = $SlotGaps } }
    if ($null -eq $Account) {
        return [pscustomobject]@{ Verdict = 'incomplete'; Reasons = @('no accounting run: frame completeness unproven'); SlotGaps = $SlotGaps }
    }
    if ($Account.Skipped -gt 0) {
        return [pscustomobject]@{ Verdict = 'incomplete'; Reasons = @("the accounting run says the capture skipped $($Account.Skipped) composed frame(s)"); SlotGaps = $SlotGaps }
    }
    return [pscustomobject]@{ Verdict = 'pass'; Reasons = @(); SlotGaps = $SlotGaps }
}

<#
Run one matrix cell through the protocol in this file's header. -Driver is a
hashtable of scriptblocks - the live pieces:

  Presence      { }                   -> a lib\UserPresence.ps1 answer
  Launch        { param($Cell) }      -> @{ Geometry; Close = { } }
  StartCapture  { param($Rect, [bool]$Duplication) } -> a session
  StopCapture   { param($Session) }   -> @{ Stats; Account; Timeline }
  Play          { param($Path) }      -> a GliResult (Skipped/Aborted)   pointer cells
  Fire          { param($Plan) }      -> an Invoke-FrameLabTrigger result trigger cells
  Score         { param($Capture, $Frames, $Gesture, $Played) }
                -> @{ BleedFrames; Motion; MotionMisses }

Returns the cell, its gesture summary, both runs' numbers and the verdict.
#>
function Invoke-FrameLabCell {
    param(
        [Parameter(Mandatory = $true)]$Cell,
        [Parameter(Mandatory = $true)][hashtable]$Driver,
        [hashtable]$GestureArgs = @{}
    )
    $trigger = $Cell.Kind -eq 'trigger'
    $act = $(if ($trigger) { 'Fire' } else { 'Play' })
    foreach ($k in 'Presence', 'Launch', 'StartCapture', 'StopCapture', $act, 'Score') {
        if (-not $Driver.ContainsKey($k)) { throw "Invoke-FrameLabCell: driver has no $k" }
    }
    $out = [ordered]@{ Id = $Cell.Id; Cell = $Cell; Gesture = $null; Measure = $null; Accounting = $null; Score = $null; Verdict = $null }
    if ($Cell.Blocked) {
        $out.Verdict = [pscustomobject]@{ Verdict = 'blocked'; Reasons = @($Cell.Blocked); SlotGaps = 0 }
        return [pscustomobject]$out
    }
    $presence = & $Driver.Presence
    if ($null -eq $presence -or $presence.Present) {
        $why = $(if ($presence) { "somebody is using this box: $($presence.Reason)" } else { 'no presence answer: never run blind' })
        $out.Verdict = [pscustomobject]@{ Verdict = 'skipped'; Reasons = @($why); SlotGaps = 0 }
        return [pscustomobject]$out
    }
    $scene = & $Driver.Launch $Cell
    try {
        if ($trigger) {
            $g = Get-FrameLabTrigger -Name $Cell.Interaction -Geometry $scene.Geometry @GestureArgs
            $out.Gesture = [pscustomobject]@{ Steps = @($g.Steps).Count; Axis = $g.Axis; Track = $g.Track; CaptureRect = $g.CaptureRect }
            $run = { & $Driver.Fire $g }
        } else {
            $g = Get-FrameLabGesture -Name $Cell.Interaction -Geometry $scene.Geometry @GestureArgs
            $out.Gesture = [pscustomobject]@{ Points = $g.Path.Length; Axis = $g.Axis; Track = $g.Track; CaptureRect = $g.CaptureRect }
            $run = { & $Driver.Play $g.Path }
        }

        # Measurement: capture only.
        $s = & $Driver.StartCapture $g.CaptureRect $false
        $in1 = & $run
        $m = & $Driver.StopCapture $s
        $frames = Select-FrameLabScoredFrames $m.Timeline
        $out.Measure = [pscustomobject]@{
            Input = $in1; Stats = $m.Stats
            Frames = @($m.Timeline).Count; Scored = $frames.Count
            Superseded = @($m.Timeline).Count - $frames.Count
        }
        if ($in1.Skipped -or $in1.Aborted) {
            $out.Verdict = Resolve-FrameLabCellVerdict -Input1 $in1 -SlotGaps $m.Stats.SlotGaps
            return [pscustomobject]$out
        }
        $sc = & $Driver.Score $m $frames $g $in1
        $out.Score = $sc

        # Accounting: the same path again, with Desktop Duplication counting.
        $s2 = & $Driver.StartCapture $g.CaptureRect $true
        $in2 = & $run
        $a = & $Driver.StopCapture $s2
        $acct = $(if ($in2.Skipped -or $in2.Aborted) { $null } else { $a.Account })
        $out.Accounting = [pscustomobject]@{ Input = $in2; Account = $acct }

        $out.Verdict = Resolve-FrameLabCellVerdict -Input1 $in1 -BleedFrames ([int]$sc.BleedFrames) `
            -MotionMisses @($sc.MotionMisses) -Account $acct -SlotGaps $m.Stats.SlotGaps
    } finally {
        if ($scene.Close) { & $scene.Close }
    }
    return [pscustomobject]$out
}
