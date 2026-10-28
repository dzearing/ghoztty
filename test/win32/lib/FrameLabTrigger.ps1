# FrameLabTrigger (T2391) - the T2373 frame lab's TRIGGER interactions: the
# ones a pointer path cannot play, fired by a click, a key chord or an IPC verb,
# with every fire stamped on QPC beside FrameCapture's frame slots.
#
# THE GAP THIS EXISTS FOR. FrameLabCatalogue (T2389) lists six interactions as
# triggers - maximize-button, blade-glide, banner, hero, tab-switch,
# split-close - and until this file every one of their matrix cells read
# `Blocked: no driver yet`. The pointer driver (FrameLabInput) plays a dense
# path at 1 kHz; a trigger is a handful of discrete acts, and what the scorer
# needs from each is not a path but WHEN it fired, on the clock the frames are
# stamped on (FrameCapture's GfcFrame.Qpc is QueryPerformanceCounter, and so
# is GliClock - the same counter, so the numbers are directly comparable).
#
# THE PLAN (Get-FrameLabTrigger) is pure, built from the scene's geometry:
#
#   maximize-button  click the caption's maximize button, settle, click the
#                    restore button in the same place. Bleed only.
#   blade-glide      click the sidebar's collapse/expand toggle, settle, click
#                    it again. Tracks the sidebar edge, and carries the glide
#                    each click starts: from the edge where it was to the edge
#                    in the other mode, over 240 ms on Mac's timingCurve(0.2,
#                    0.8, 0.2, 1) - the constants in pane_sidebar_transition.zig,
#                    which the harness reads back so the two cannot drift.
#   banner           `+set-banner` on the scene's pane, settle, `+set-banner
#                    --clear`. Tracks the pane top (the banner pushes it down).
#   hero             ctrl+shift+space in, settle, ctrl+shift+space out. Bleed.
#   tab-switch       ctrl+tab, settle, ctrl+shift+tab (the scene opens a second
#                    tab; with one, the chord has nothing to switch to). Bleed.
#   split-close      `+split --direction=right --name=<n>`, settle, `+close`
#                    of the same name. Bleed.
#
# Every trigger runs out and back, like every pointer shuttle, so the scene is
# where it started and the accounting run replays the same thing.
#
# THE PLAYER (Invoke-FrameLabTrigger) waits each step's planned offset and
# calls the sink. Each step is stamped StartQpc (just before the act) and
# DoneQpc (when the sink returned), and its FireQpc is the moment the app can
# first have acted on it:
#
#   click / keys  DoneQpc - SendInput has queued the input when it returns
#   ipc           StartQpc - the app may act before the CLI process returns,
#                 so the fire is bounded by Start..Done and Start is the
#                 earliest; Done - Start is recorded (FireSpreadUs) so a slow
#                 CLI shows rather than being folded into "app lag"
#
# THE SAFETY RULES are FrameLabInput's: nothing is sent while somebody is using
# the box (lib\UserPresence.ps1, the same gate); a caller sink or -DryRun are
# the only ways past it. Between steps the live sink asks whether input has
# arrived that it did not send (GetLastInputInfo past its own last send) and
# the run aborts with AbortReason = user-input.
#
# input-desktop-helper: (T2391) the keyboard SendInput below fires the lab's key-chord triggers (hero, tab switch); clicks reuse FrameLabInput's sink. Gated on lib\UserPresence.ps1 and never run by its own harness (a recording sink is).
#
# INPUT DESKTOP ONLY when it injects - the caller is an input-desktop exception
# (T2392). This file opens no window.
#
# Acceptance: test\win32\frame-lab-catalogue.ps1 (sections F-H).
# ASCII-only by design (PS 5.1 on this box mangles non-ASCII on rewrite).

Set-StrictMode -Off

if (-not (Get-Command New-FrameLabPath -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'FrameLabInput.ps1')
}

# pane_sidebar_transition.zig: column_ms and Mac's curve. The harness reads the
# zig constants back and fails if these drift.
$script:FrameLabBladeGlideMs = 240
$script:FrameLabBladeCurve = @(0.2, 0.8, 0.2, 1.0)

$script:FrameLabTriggerKeySource = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class GltKeys {
    [StructLayout(LayoutKind.Sequential)]
    struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr extra; }
    [StructLayout(LayoutKind.Sequential)]
    // KEYBDINPUT is 8 bytes short of MOUSEINPUT, the union's largest member:
    // two ints make sizeof(INPUT) 40 on x64 (28 on x86). Three made it 48 and
    // SendInput refused every chord with ERROR_INVALID_PARAMETER (T2395).
    struct INPUT { public uint type; public KEYBDINPUT ki; public int pad0, pad1; }
    public static int InputBytes { get { return Marshal.SizeOf(typeof(INPUT)); } }
    [StructLayout(LayoutKind.Sequential)]
    struct LASTINPUTINFO { public uint cbSize, dwTime; }
    [DllImport("user32.dll", SetLastError = true)] static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO p);
    const uint KEYUP = 0x0002;

    // Press every vk in order, release in reverse: one chord.
    public static bool Chord(ushort[] vks) {
        var list = new INPUT[vks.Length * 2];
        for (int i = 0; i < vks.Length; i++) {
            list[i].type = 1; list[i].ki.wVk = vks[i];
            var j = list.Length - 1 - i;
            list[j].type = 1; list[j].ki.wVk = vks[i]; list[j].ki.dwFlags = KEYUP;
        }
        return SendInput((uint)list.Length, list, Marshal.SizeOf(typeof(INPUT))) == (uint)list.Length;
    }

    // GetTickCount of the last input the session saw, injected or not.
    public static uint LastInputTick() {
        var p = new LASTINPUTINFO(); p.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
        return GetLastInputInfo(ref p) ? p.dwTime : 0;
    }
}
'@

function Import-FrameLabTrigger {
    Import-FrameLabInput
    if (-not ('GltKeys' -as [type])) {
        Add-Type -TypeDefinition $script:FrameLabTriggerKeySource -Language CSharp
    }
}

<#
A chord ('ctrl+shift+space') as virtual-key codes, modifiers first. Pure;
throws on a name it does not know rather than sending half a chord.
#>
function ConvertTo-FrameLabChord([string]$Chord) {
    $map = @{
        ctrl = 0x11; control = 0x11; shift = 0x10; alt = 0x12; win = 0x5B
        space = 0x20; tab = 0x09; enter = 0x0D; escape = 0x1B; esc = 0x1B
        left = 0x25; up = 0x26; right = 0x27; down = 0x28
    }
    $vks = @()
    foreach ($part in ($Chord.ToLowerInvariant() -split '\+')) {
        if ($map.ContainsKey($part)) { $vks += $map[$part] }
        elseif ($part -match '^[a-z0-9]$') { $vks += [int][char]$part.ToUpperInvariant() }
        elseif ($part -match '^f([1-9]|1[0-2])$') { $vks += 0x6F + [int]$Matches[1] }
        else { throw "ConvertTo-FrameLabChord: unknown key '$part' in '$Chord'" }
    }
    return , ([uint16[]]$vks)
}

<#
Mac's timing curve: the cubic bezier (0,0) (x1,y1) (x2,y2) (1,1) read as y at
x = t, bisected exactly the way pane_sidebar_transition.zig's ease() does.
#>
function Get-FrameLabEase([double]$T, [double[]]$Curve = $script:FrameLabBladeCurve) {
    if ($T -le 0) { return 0.0 }
    if ($T -ge 1) { return 1.0 }
    $x1 = $Curve[0]; $y1 = $Curve[1]; $x2 = $Curve[2]; $y2 = $Curve[3]
    $lo = 0.0; $hi = 1.0; $s = $T
    for ($i = 0; $i -lt 40; $i++) {
        $s = ($lo + $hi) / 2
        $u = 1 - $s
        $x = 3 * $u * $u * $s * $x1 + 3 * $u * $s * $s * $x2 + $s * $s * $s
        if ($x -lt $T) { $lo = $s } else { $hi = $s }
    }
    $u = 1 - $s
    return 3 * $u * $u * $s * $y1 + 3 * $u * $s * $s * $y2 + $s * $s * $s
}

<#
A trigger plan from the scene's geometry (physical pixels):

  Window / Monitor   as for a gesture
  MaximizeButton     @{ X; Y }  the caption's maximize button (maximize-button)
  Sidebar            @{ EdgeX; OtherEdgeX; Toggle = @{ X; Y } }  the edge now,
                     the edge in the other mode, the toggle (blade-glide)
  Target             the scene pane's name for IPC (banner, split-close)

Returns Name, Steps (Action click|keys|ipc, the act's X/Y, Chord or Args,
AtMs from the run's start, Label), Axis, Track, CaptureRect, Glides (one per
step that starts a glide: Step, FromPx, ToPx, Ms, Curve - empty for the rest)
and DurationMs (the last step plus the settle).
#>
function Get-FrameLabTrigger {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]$Geometry,
        [double]$SettleMs = 700,
        [double]$LeadMs = 150,
        [string]$BannerText = 'frame lab banner',
        [string]$SplitName = 'framelab-split'
    )
    $w = $Geometry.Window; $m = $Geometry.Monitor
    $steps = New-Object System.Collections.ArrayList
    $glides = New-Object System.Collections.ArrayList
    $axis = 'none'; $track = ''
    $rect = [pscustomobject]@{ X = $w.X; Y = $w.Y; W = $w.W; H = $w.H }
    $at1 = $LeadMs; $at2 = $LeadMs + $SettleMs
    function Step($Action, $AtMs, $Label, $X = 0, $Y = 0, $Chord = '', [string[]]$CliArgs = @()) {
        [void]$steps.Add([pscustomobject]@{ Action = $Action; AtMs = [double]$AtMs; Label = $Label; X = [int]$X; Y = [int]$Y; Chord = $Chord; Args = $CliArgs })
    }
    function NeedTarget {
        if (-not $Geometry.Target) { throw "Get-FrameLabTrigger: $Name needs Geometry.Target (the scene pane's name, for IPC)" }
        return [string]$Geometry.Target
    }
    switch ($Name) {
        'maximize-button' {
            $b = $Geometry.MaximizeButton
            if (-not $b) { throw 'Get-FrameLabTrigger: maximize-button needs Geometry.MaximizeButton (the caption button, located from the chrome)' }
            # Maximized, the restore button sits where the maximize button
            # was only if the window's top-right is the work area's - so the
            # second click is aimed at the maximized window's button.
            $rx = $m.X + $m.W - ($w.X + $w.W - $b.X); $ry = $m.Y + ($b.Y - $w.Y)
            Step click $at1 'maximize' $b.X $b.Y
            Step click $at2 'restore' $rx $ry
            $rect = [pscustomobject]@{ X = $m.X; Y = $m.Y; W = $m.W; H = $m.H }
        }
        'blade-glide' {
            $s = $Geometry.Sidebar
            if (-not $s -or -not $s.Toggle -or $null -eq $s.OtherEdgeX) {
                throw 'Get-FrameLabTrigger: blade-glide needs Geometry.Sidebar with EdgeX, OtherEdgeX and Toggle (a scene with a sidebar)'
            }
            $axis = 'x'; $track = 'sidebar-edge'
            Step click $at1 'toggle out' $s.Toggle.X $s.Toggle.Y
            Step click $at2 'toggle back' $s.Toggle.X $s.Toggle.Y
            [void]$glides.Add([pscustomobject]@{ Step = 0; FromPx = [double]$s.EdgeX; ToPx = [double]$s.OtherEdgeX; Ms = [double]$script:FrameLabBladeGlideMs; Curve = $script:FrameLabBladeCurve })
            [void]$glides.Add([pscustomobject]@{ Step = 1; FromPx = [double]$s.OtherEdgeX; ToPx = [double]$s.EdgeX; Ms = [double]$script:FrameLabBladeGlideMs; Curve = $script:FrameLabBladeCurve })
        }
        'banner' {
            $t = NeedTarget
            $axis = 'y'; $track = 'pane-top'
            Step ipc $at1 'banner on' -CliArgs @('+set-banner', "--target=$t", $BannerText)
            Step ipc $at2 'banner off' -CliArgs @('+set-banner', "--target=$t", '--clear')
        }
        'hero' {
            Step keys $at1 'hero in' -Chord 'ctrl+shift+space'
            Step keys $at2 'hero out' -Chord 'ctrl+shift+space'
        }
        'tab-switch' {
            Step keys $at1 'next tab' -Chord 'ctrl+tab'
            Step keys $at2 'previous tab' -Chord 'ctrl+shift+tab'
        }
        'split-close' {
            $t = NeedTarget
            Step ipc $at1 'split' -CliArgs @('+split', '--direction=right', "--target=$t", "--name=$SplitName")
            Step ipc $at2 'close' -CliArgs @('+close', "--target=$SplitName")
        }
        default {
            $known = Get-FrameLabInteractions | Where-Object { $_.Name -eq $Name }
            if ($known -and $known.Kind -eq 'pointer') { throw "Get-FrameLabTrigger: $Name is a pointer gesture, not a trigger (Get-FrameLabGesture builds it)" }
            throw "Get-FrameLabTrigger: unknown interaction '$Name'"
        }
    }
    [pscustomobject]@{
        Name        = $Name
        Steps       = @($steps)
        Axis        = $axis
        Track       = $track
        CaptureRect = $rect
        Glides      = @($glides)
        DurationMs  = $at2 + $SettleMs
    }
}

<#
Play a trigger plan. -Sink is a hashtable of scriptblocks, each returning
$true when the act went through:

  Click  { param($X, $Y) }      Keys { param($Chord) }      Ipc { param([string[]]$Args) }
  UserActive { }  (optional)    $true = input arrived that the sink did not send

No -Sink is the live sink (New-FrameLabTriggerSink), gated on presence like
Invoke-FrameLabInput. Returns Skipped/SkipReason, Aborted/AbortReason/
AbortIndex, Stamps (one per step that ran: Index, Action, Label, PlannedQpc,
StartQpc, DoneQpc, FireQpc, FireSpreadUs, Ok), OriginQpc and Frequency.
#>
function Invoke-FrameLabTrigger {
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [hashtable]$Sink = $null,
        [switch]$DryRun,
        $Presence = $null,
        [string]$Cli = ''
    )
    Import-FrameLabTrigger
    $F = [GliClock]::Frequency
    $out = [ordered]@{
        Name = $Plan.Name; Skipped = $false; SkipReason = ''; Aborted = $false; AbortReason = ''; AbortIndex = -1
        Stamps = @(); OriginQpc = 0L; Frequency = $F; DryRun = [bool]$DryRun
    }
    if (-not $DryRun -and -not $Sink -and $null -eq $Presence) {
        if (-not (Get-Command Get-UserPresence -ErrorAction SilentlyContinue)) {
            . (Join-Path $PSScriptRoot 'UserPresence.ps1')
        }
        $Presence = Get-UserPresence
    }
    $gate = Resolve-FrameLabInputGate -Presence $Presence -DryRun:$DryRun -CustomSink:([bool]$Sink)
    if (-not $gate.Allowed) {
        $out.Skipped = $true; $out.SkipReason = $gate.Reason
        return [pscustomobject]$out
    }
    if (-not $Sink -and -not $DryRun) { $Sink = New-FrameLabTriggerSink -Cli $Cli }

    $stamps = New-Object System.Collections.ArrayList
    $origin = [GliClock]::Now() + [GliClock]::Ticks(2)
    $out.OriginQpc = $origin
    for ($i = 0; $i -lt $Plan.Steps.Count; $i++) {
        $s = $Plan.Steps[$i]
        $target = $origin + [GliClock]::Ticks($s.AtMs)
        # Sleep the bulk, spin the last 2 ms: a trigger is one act, not a
        # 1 kHz stream, so the stamp - not the wait - is what has to be exact.
        while ($true) {
            $remainMs = ($target - [GliClock]::Now()) * 1000.0 / $F
            if ($remainMs -le 0) { break }
            if ($remainMs -gt 3) { Start-Sleep -Milliseconds ([int]($remainMs - 2)) }
        }
        if ($Sink -and $Sink.UserActive -and (& $Sink.UserActive)) {
            $out.Aborted = $true; $out.AbortReason = 'user-input'; $out.AbortIndex = $i
            break
        }
        $start = [GliClock]::Now()
        $ok = $true
        if ($Sink) {
            $ok = [bool]$(switch ($s.Action) {
                'click' { & $Sink.Click $s.X $s.Y }
                'keys'  { & $Sink.Keys $s.Chord }
                'ipc'   { & $Sink.Ipc $s.Args }
                default { throw "Invoke-FrameLabTrigger: unknown action '$($s.Action)'" }
            })
        }
        $done = [GliClock]::Now()
        $fire = $(if ($s.Action -eq 'ipc') { $start } else { $done })
        [void]$stamps.Add([pscustomobject]@{
            Index = $i; Action = $s.Action; Label = $s.Label
            PlannedQpc = $target; StartQpc = $start; DoneQpc = $done; FireQpc = $fire
            FireSpreadUs = [math]::Round(($done - $start) * 1e6 / $F, 1); Ok = $ok
        })
        if (-not $ok) {
            $out.Aborted = $true; $out.AbortReason = 'send-failed'; $out.AbortIndex = $i
            break
        }
    }
    $out.Stamps = @($stamps)
    return [pscustomobject]$out
}

<#
The live sink: clicks through FrameLabInput's SendInput sink (absolute,
physical pixels), chords through GltKeys, IPC through the CLI at -Cli.
UserActive compares the session's last-input tick with this sink's own last
send: anything later is somebody else's hand.
#>
function New-FrameLabTriggerSink {
    param([string]$Cli = '')
    Import-FrameLabTrigger
    $mouse = New-Object GliSendInputSink
    $state = @{ LastSend = [GltKeys]::LastInputTick() }
    $cliPath = $Cli
    @{
        Click = {
            param($X, $Y)
            $mouse.Refresh()
            $ok = $mouse.Send($X, $Y, 0) -and $mouse.Send($X, $Y, [GliFlags]::Down) -and $mouse.Send($X, $Y, [GliFlags]::Up)
            $state.LastSend = [GltKeys]::LastInputTick()
            $ok
        }.GetNewClosure()
        Keys = {
            param($Chord)
            $ok = [GltKeys]::Chord((ConvertTo-FrameLabChord $Chord))
            $state.LastSend = [GltKeys]::LastInputTick()
            $ok
        }.GetNewClosure()
        Ipc = {
            param([string[]]$CliArgs)
            if (-not $cliPath) { throw 'New-FrameLabTriggerSink: an ipc trigger needs -Cli (the scene build''s ghoztty.com)' }
            & $cliPath @CliArgs *> $null
            $LASTEXITCODE -eq 0
        }.GetNewClosure()
        UserActive = {
            # 50 ms of slack: the tick our own send produced can land a little
            # after SendInput returns.
            [GltKeys]::LastInputTick() -gt ($state.LastSend + 50)
        }.GetNewClosure()
    }
}

<#
The fire stamps as plain objects for a stamp JSON (T2390), in the same shape
as ConvertTo-FrameLabInputStamps: microseconds from the run's origin plus the
absolute QPC origin, so the report lines them up with the frame slots.
#>
function ConvertTo-FrameLabTriggerStamps($Result) {
    $F = $Result.Frequency
    foreach ($s in @($Result.Stamps)) {
        [pscustomobject]@{
            i = $s.Index; action = $s.Action; label = $s.Label
            plannedUs = [math]::Round(($s.PlannedQpc - $Result.OriginQpc) * 1e6 / $F, 1)
            fireUs = [math]::Round(($s.FireQpc - $Result.OriginQpc) * 1e6 / $F, 1)
            spreadUs = $s.FireSpreadUs; ok = $s.Ok
            originQpc = $Result.OriginQpc
        }
    }
}

<#
The Measure-FrameMotion arguments for a trigger cell, from the frames' QPC
stamps and the tracked edge's position in each. Time is ms from the first
fire; the motion window runs from the first fire to the last fire plus its
glide (or the settle, for a trigger with no glide). For a plan with glides,
Expected is the edge each frame SHOULD show: before the first fire the first
glide's start, then each glide from its own fire on, eased on its curve -
which is how blade-glide hands its ease curve to the scorer.

Returns a hashtable to splat: Measure-FrameMotion @args.
#>
function Get-FrameLabTriggerMotionArgs {
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)]$Fired,
        [Parameter(Mandatory = $true)][long[]]$FrameQpc,
        [Parameter(Mandatory = $true)][double[]]$Position,
        [Parameter(Mandatory = $true)][double]$PeriodMs,
        [double]$SettleMs = 700
    )
    if ($Plan.Axis -eq 'none') { throw "Get-FrameLabTriggerMotionArgs: $($Plan.Name) tracks nothing (bleed only)" }
    if ($FrameQpc.Length -ne $Position.Length) { throw 'Get-FrameLabTriggerMotionArgs: one position per frame' }
    $stamps = @($Fired.Stamps)
    if ($stamps.Count -lt $Plan.Steps.Count) { throw "Get-FrameLabTriggerMotionArgs: $($stamps.Count) of $($Plan.Steps.Count) steps fired; an incomplete run is not scored" }
    $F = [double]$Fired.Frequency
    $t0 = $stamps[0].FireQpc
    $time = [double[]]@($FrameQpc | ForEach-Object { ($_ - $t0) * 1000.0 / $F })
    $fireMs = @($stamps | ForEach-Object { ($_.FireQpc - $t0) * 1000.0 / $F })
    $lastGlide = @($Plan.Glides | Where-Object { $_.Step -eq $stamps.Count - 1 })
    $tail = $(if ($lastGlide.Count) { $lastGlide[0].Ms } else { $SettleMs })
    $a = @{
        Time = $time; Position = $Position; PeriodMs = $PeriodMs
        Start = 0.0; End = $fireMs[-1] + $tail
    }
    if (@($Plan.Glides).Count) {
        $glides = @($Plan.Glides | Sort-Object Step)
        $exp = New-Object double[] $time.Length
        for ($k = 0; $k -lt $time.Length; $k++) {
            $t = $time[$k]
            $v = $glides[0].FromPx
            foreach ($g in $glides) {
                $at = $fireMs[$g.Step]
                if ($t -lt $at) { break }
                $v = $g.FromPx + ($g.ToPx - $g.FromPx) * (Get-FrameLabEase (($t - $at) / $g.Ms) $g.Curve)
            }
            $exp[$k] = $v
        }
        $a.Expected = $exp
    }
    return $a
}
