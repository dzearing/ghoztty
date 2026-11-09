# @timing-sensitive - it films a slide frame by frame; beside other workers the
# slide's frames thin out and it reads red (T2521 sweep, 2026-10-30: red at
# width 4, green alone).
# T2186 acceptance: folding panes by dragging a divider SLIDES, as on Mac,
# instead of jumping in one step.
#
# THE CLAIM. Before T2186 a drag that folded a pane (T2124) went like this:
# the folding pane vanished on the spot, and the panes left on show held
# their old size for the whole slide and then snapped to the new one - a
# 490 -> 1000 px jump in one frame at the slide's end, with a gap of desk in
# between. Now (Mac `PaneStageView`; since T2268 its a81db68f9 follower):
#   - the folding pane slides to its tucked place at the stack's edge and is
#     hidden only when the slide is over
#   - a drag's slide is a resize slide: the panes on show pass through every
#     width between the old layout and the new one
#   - the pane windows are stacked in the layout's paint order, so the
#     folding pane slides UNDER the run, never across it
#
# Layout: P | s1 | s2 across a 1125 DIP window (T2295: five pane minimums of
# 225 DIP, the shape the old 1500 had at 300), the stack-collapse-drag.ps1
# shape. The root divider is dragged right past the fold point and HELD, with
# the slide stretched to 2 s (`GHOZTTY_STACK_SLIDE_MS`) so the sampler sees it
# in motion.
#
# Claims:
#   F1) s2, the folding pane, is on show and seen at 2+ positions strictly
#       between where it was and where it tucks: it slides away
#   F2) P's width is seen at 2+ widths strictly between its old and new ones,
#       and no one sample-to-sample step covers more than 60% of the change:
#       it grows through the slide, no single jump
#   F3) while both are on show mid-slide, s1 is above s2 in the window
#       z-order (the run is painted over the card tucking away)
#   F4) at rest the layout is the T2124 answer: two on show, s2 hidden
#   F5) dragging back unfolds s2 the same way: seen on show at 2+ positions
#       strictly between its tucked place and its slot
#   F6) at no sampled moment of the fold or the unfold does any popup the app
#       shows reach outside the window (T2227). The folding pane slides out to
#       its held rect past the window's right edge; the pane child is clipped
#       by the window, but its popups (the unfocused dim wash, painted in the
#       background colour) are not, and the user saw that wash bleed out over
#       the desktop mid-slide. P is focused first so s2 carries the wash.
#   F7) the dragged divider's accent bar stays over the gutter as it is
#       DRAWN (T2270; Mac `PaneStageView.shownGutter`): mid-glide it is seen
#       off its laid-out gutter at 2+ places, trailing the hand - short of the
#       laid-out gutter while P grows into the fold, past it while P shrinks
#       back on the unfold. Read from the debug build's `gutter bar gliding`
#       oracle line.
#   F8) the folding card NARROWS into its strip (T2287; Mac a81db68f9): mid-
#       glide s2's window is cut to its card (its window region), and that
#       card is seen at 2+ widths well short of s2's full width - not a
#       full-size card that slides off and vanishes at the end
#   F9) unfolding, s2's card widens out of its strip the same way: seen cut
#       to 2+ partial widths on its way back
#   F10) as s2's card narrows, the strip's face fades in over it (T2288; Mac
#       a81db68f9 `PaneCardView.collapse`): the face popup is seen on show,
#       at 2+ alphas strictly between none and all of it, rising - so the
#       content fades out as the title fades in. Read from the debug build's
#       `strip face alpha=` oracle line.
#   F11) unfolding, the face fades back out the same way: 2+ partial alphas,
#       falling
#   F12) at rest - folded, and unfolded again - no face is on show: the
#       window's own strip takes over, and a card on show wears none
#   F13) the face IS the strip's band (flat style): photographed mid-glide
#       through WM_PRINTCLIENT, its commonest pixel is the band the oracle
#       logged and covers most of it - not the pane's colour, not a hole.
#       A pure-black photo is retaken (up to 5 times, then scored): the system
#       answers PrintWindow for the layered popup from its own surface, never
#       the app's WM_PRINT, and under load hands back an untouched bitmap -
#       this row's intermittent red (T2752/T2836)
#   F14) folding re-cuts s2 to its narrowing card on 2+ frames and redraws it
#       on at most one, its first (T2415): a cut that only shrinks shows no
#       pixel of the pane that was not on show already, and a redraw per frame
#       was a GL repaint per frame of the glide. Unfolding, the cut grows and
#       IS redrawn. Read from the debug build's `stack cut redraw=` line.
#
#   F16) carried (T2457): the folding card is drawn by its face alone, from
#       the pane's last frame - the live window is off show on every carried
#       frame after the first, and the content's strength (the
#       `stack fold carried` oracle) only ever falls. F1/F3/F8/F10 read the
#       carried card where the live window used to be sampled.
#
#   F19) s2's banner comes out WITH its card (T2661, user report 2026-11-03:
#       "the banner still doesn't paint while expanding and only shows up when
#       done"): while s2's live window is off show mid-unfold, its banner is
#       on show in 2+ samples, cut to 2+ distinct partial widths (the debug
#       build's `banner cut span` oracle line) - not hidden until the glide
#       lands - and it never reaches outside the window (F6, region-aware).
#       On the composition path (GHOZTTY_COMP_PRESENT) the banner at rest is
#       a visual in s2's own tree, hidden with s2's window; the opening glide
#       puts it on its popup instead and the landing takes it back (T2749),
#       read from the app's `banner path visual=` line.
#   F17) opening carried (T2458): unfolding, s2's pane is placed at its new
#       size while hidden and its card is drawn by its face alone - the live
#       window is off show on every frame, the card shows no content until the
#       frame drawn at the new size has landed, and that frame does land mid-
#       glide; the content's strength only ever rises; the terminal is resized
#       0 times from the first frame of the motion to the frame it lands on,
#       where it is a live pane again. Read from the debug build's `stack
#       unfold carried` and `stack unfold landed` oracle lines. F5/F9/F11 read
#       the carried card where the live window used to be sampled.
#
#   F18) held under the hand (T2459): while the fold the drag started glides,
#       the panes that stay open keep their grid - every resize decided
#       `held` - and take their size once the motion settles: at most 3
#       `resize applied` lines over the whole fold, where every glide frame
#       used to reflow P.
#
#   F15) -SlowFrames (T2442): Mac's own glide (45 ms), every tick stepped as
#       if 80 ms had passed - the frame time the user's window had under a
#       drag. Folding, the face is still drawn at 2+ partial alphas and no
#       frame raises it more than a third of the way plus rounding (92):
#       uncapped, one frame crossed the whole fade and the content showed at
#       full strength until the card was in its strip. Only setup, the fold
#       and F15 run in this mode; it stamps its own guard row.
#
# -NegativeControl sets the slide to 0 ms (an instant re-layout, the answer
# before any slide) and keeps F1/F2/F7/F8/F10/F14 as written: they MUST fail.
#
# -Tree (T2777) runs the app in the composition pane tree
# (GHOZTTY_COMP_PRESENT + GHOZTTY_COMP_CHROME + GHOZTTY_COMP_PANE_TREE). The
# face is then a picture in the window's own tree, not the GhozttyStripFace
# popup, so F10/F12/F13 read it from the app's `strip face visual
# shown|hidden` lines and require that the popup is NEVER on show: F10 the
# visual went up mid-fold, F12 it is down at rest, F13 no frame of the run
# fell back to the popup. The face's pixels in a window capture are the
# on-screen oracle's to score (the background desktop is never composed).
# Its negative control is GHOZTTY_FACE_COMP=0 set by the caller, which keeps
# the face on its popup: F10 and F13 MUST fail.
#
# Hermetic: per-run LOCALAPPDATA, per-run agent binary override, a private IPC
# pipe suffix, and it only ever kills ghoztty processes launched from this
# repo's zig-out. Runs on the BACKGROUND test desktop.
#
#   powershell -NoProfile -File test\win32\stack-fold-slide.ps1
param(
    [string]$ExePath,
    [string]$AgentExe,
    [switch]$NegativeControl,
    [switch]$SlowFrames,
    [switch]$Tree,
    [ValidateSet('flat', 'elevated')][string]$PaneStyle = 'flat',
    [switch]$Interactive
)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }
$agent = Join-Path $repo 'zig-out\bin\ghoztty-agent.exe'
if ($AgentExe) { $agent = $AgentExe }

$script:pass = 0
$script:fail = 0
$root = Join-Path $env:TEMP "ghoztty-stack-fold-slide-$PID"
$script:errlog = Join-Path $root 'app-stderr.log'
$slideMs = if ($NegativeControl) { 0 } elseif ($SlowFrames) { 380 } else { 2000 }

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\ChromeGeometry.ps1')

function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}
function Say($m) { Write-Host $m }

function Stop-RepoInstances { [void](Stop-RepoGhoztty -Exe $exe -SettleMs 700) }

$appArgs = @('--config-default-files=false', '--session-persistence=false', "--macos-pane-style=$PaneStyle")

function Start-App {
    $app = Start-OnTestDesktop -Exe $exe -Arguments $appArgs -StdErr $script:errlog
    if ((Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow') -eq [IntPtr]::Zero) {
        Write-TestAssertedNothing -Reason 'the app never opened a GhozttyWindow'
    }
    return $app
}

# Every pane window, in the order the system enumerates children (z-order,
# top first), each tagged with that index.
function Get-Panes([IntPtr]$top) {
    $i = 0
    return @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal' | ForEach-Object {
        $_ | Add-Member -NotePropertyName Z -NotePropertyValue $i -PassThru
        $i++
    })
}
function Get-VisiblePanes([IntPtr]$top) {
    return @(Get-Panes $top | Where-Object Visible | Sort-Object Left)
}
function Wait-Shown([IntPtr]$top, [int]$n, [int]$timeoutSec = 20) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    do {
        $v = @(Get-VisiblePanes $top)
        if ($v.Count -eq $n) { return $v }
        Start-Sleep -Milliseconds 300
    } while ((Get-Date) -lt $deadline)
    return @(Get-VisiblePanes $top)
}
function Format-Cols($cols) {
    return (($cols | Sort-Object Left | ForEach-Object { "$($_.Left)-$($_.Right)$(if (-not $_.Visible) { '(hidden)' })" }) -join ' | ')
}

# Move the held pointer to screen x in a few quick steps.
function Move-To([IntPtr]$top, [int]$fromX, [int]$toX, [int]$y) {
    $steps = 6
    for ($i = 1; $i -le $steps; $i++) {
        $x = [int]($fromX + ($toX - $fromX) * $i / $steps)
        [void](Send-TestMouse -Window $top -Target $top -X $x -Y $y -Action move -HoldMs 0)
        Start-Sleep -Milliseconds 30
    }
}

# T2227: every visible top-level the app shows other than the window itself
# that reaches outside the window's rect - a pane popup the window does not
# clip. One line each, for the failure message. A popup cut by its own window
# region (T2661: a banner cut to its opening card) is stray only where the
# region still shows: its overhang is probed along its middle row.
function Get-StrayPopups([int]$procId, [IntPtr]$top) {
    $w = Get-TestWindowRect -Window $top
    return @(Get-TestWindows -ProcessId $procId -Class '*' | Where-Object {
            $_.Visible -and $_.Hwnd -ne [int64]$top -and $_.Width -gt 0 -and $_.Height -gt 0 -and
            ($_.Left -lt $w.Left -or $_.Top -lt $w.Top -or $_.Right -gt $w.Right -or $_.Bottom -gt $w.Bottom) -and
            (Test-OverhangShows $_ $w)
        } | ForEach-Object { "$($_.Class) $($_.Left)-$($_.Right)" })
}
function Test-OverhangShows($p, $w) {
    # Vertical overhang is not probed: only the columns a slide pushes out.
    if ($p.Top -lt $w.Top -or $p.Bottom -gt $w.Bottom) { return $true }
    $pts = New-Object System.Collections.Generic.List[int]
    $y = [int]($p.Height / 2)
    for ($x = 0; $x -lt $p.Width; $x += 2) {
        $sx = $p.Left + $x
        if ($sx -lt $w.Left -or $sx -ge $w.Right) { $pts.Add($x); $pts.Add($y) }
    }
    if ($pts.Count -eq 0) { return $false }
    $hits = Get-TestWindowRegionHits -Window ([IntPtr]$p.Hwnd) -Points $pts.ToArray()
    if ($null -eq $hits) { return $true }
    if (@($hits | Where-Object { $_ }).Count -eq 0) { return $false }
    # A gliding popup moves and re-cuts every frame: a region read after the
    # rect it is probed against may belong to the next frame's place (cut
    # wider, moved left). Only a popup that stood still across the probe is
    # a finding; a real bleed stands still on the next sample too.
    $again = Get-TestWindowRect -Window ([IntPtr]$p.Hwnd)
    return ($null -ne $again -and $again.Left -eq $p.Left -and $again.Right -eq $p.Right)
}

# How much of a pane window shows across its middle (T2287): its window
# region, probed every 4 px; the whole width when it has no region.
function Get-ShownWidth($pane) {
    $pts = New-Object System.Collections.Generic.List[int]
    $y = [int]($pane.Height / 2)
    for ($x = 2; $x -lt $pane.Width; $x += 4) { $pts.Add($x); $pts.Add($y) }
    if ($pts.Count -eq 0) { return 0 }
    $hits = Get-TestWindowRegionHits -Window ([IntPtr]$pane.Hwnd) -Points $pts.ToArray()
    if ($null -eq $hits) { return $pane.Width }
    return 4 * @($hits | Where-Object { $_ }).Count
}

# Sample every pane window (and any stray popup) for $ms milliseconds, with
# how much of $script:watchPane shows when it is on show.
function Get-Samples([IntPtr]$top, [int]$ms) {
    $out = New-Object System.Collections.Generic.List[object]
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $ms) {
        $panes = @(Get-Panes $top)
        $w = $null
        $q = Find-Pane $panes $script:watchPane
        if ($null -ne $q -and $q.Visible) { $w = [pscustomobject]@{ Width = $q.Width; Shown = (Get-ShownWidth $q) } }
        $faces = @(Get-TestWindows -ProcessId $script:appPid -Class 'GhozttyStripFace' | Where-Object Visible)
        # s2's banner (F19, T2661): on show, and how much of it its region shows.
        $bn = $null
        # On the composition path the popup is made only when the unfold
        # first needs it (T2749), so any banner popup on show is s2's - the
        # only pane wearing one.
        $bw = @(Get-TestWindows -ProcessId $script:appPid -Class 'GhozttyBannerOverlay' | Where-Object { $_.Visible -and ($_.Hwnd -eq $script:watchBanner -or $script:bannerPath -eq 'visual') })
        if ($bw.Count -eq 1) { $bn = [pscustomobject]@{ Left = $bw[0].Left; Width = $bw[0].Width; Shown = (Get-ShownWidth $bw[0]) } }
        # One photograph of the face mid-glide (F13); it may hide under us.
        # The face is an UpdateLayeredWindow popup, and the system answers
        # PrintWindow for it from the layered surface itself - the app's
        # WM_PRINT is never sent (T2836: a receipt there logged 0 times in 9
        # runs). Under box load that answer is sometimes the capture's own
        # untouched bitmap, pure 000000 (T2752's intermittent red). The face
        # is never drawn pure black, so such a photo is retaken on a later
        # sample - at most $faceRetakes times, after which the black photo is
        # kept and scored: a face that really draws nothing still fails F13.
        if ($null -eq $script:faceShot -and $faces.Count -gt 0) {
            $shot = $null
            try { $shot = Get-TestWindowPixels -Window ([IntPtr]$faces[0].Hwnd) -Sync -AllowUniform -UniformTimeoutMs 0 } catch { }
            if ($null -ne $shot) {
                $tc0 = Get-TopColor $shot
                if ($tc0.Color -eq '000000' -and $tc0.Share -ge 0.99 -and $script:faceShotsEmpty -lt $faceRetakes) {
                    $script:faceShotsEmpty++
                    Close-TestWindowPixels -Shot $shot
                } else {
                    $script:faceShot = $shot
                }
            }
        }
        $out.Add([pscustomobject]@{ Ms = $sw.ElapsedMilliseconds; Panes = $panes; Stray = @(Get-StrayPopups $script:appPid $top); Watch = $w; Faces = $faces.Count; Banner = $bn })
        Start-Sleep -Milliseconds 15
    }
    return $out
}
# The distinct partial widths $samples saw the watched pane cut to: shown,
# and narrower than 80% of its window.
function Get-PartialWidths($samples) {
    return @($samples | Where-Object { $null -ne $_.Watch -and $_.Watch.Shown -gt 0 -and $_.Watch.Shown -lt 0.8 * $_.Watch.Width } |
            ForEach-Object { $_.Watch.Shown } | Sort-Object -Unique)
}
# The `gutter bar gliding at X,Y laid out at X,Y` oracle lines (T2270) from
# line $from of the app's stderr on: each as drawn x and laid-out x.
function Get-GlidingBar([int]$from) {
    $lines = @(Get-Content -Path $script:errlog -ErrorAction SilentlyContinue)
    $out = @()
    for ($i = $from; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match 'gutter bar gliding at (-?\d+),(-?\d+) laid out at (-?\d+),(-?\d+)') {
            $out += [pscustomobject]@{ Shown = [int]$Matches[1]; Laid = [int]$Matches[3] }
        }
    }
    return $out
}
# The face's visual in the window's tree (T2777, -Tree) from line $from to
# line $to: how often it went up, came down, or failed back to the popup.
function Get-FaceVisual([int]$from, [int]$to) {
    $lines = @(Get-Content -Path $script:errlog -ErrorAction SilentlyContinue)
    $o = [pscustomobject]@{ Shown = 0; Hidden = 0; Failed = 0 }
    for ($i = $from; $i -lt [math]::Min($to, $lines.Count); $i++) {
        if ($lines[$i] -match 'strip face visual shown') { $o.Shown++ }
        elseif ($lines[$i] -match 'strip face visual hidden') { $o.Hidden++ }
        elseif ($lines[$i] -match 'strip face visual failed|strip face moved to its popup') { $o.Failed++ }
    }
    return $o
}
# The `strip face alpha=N band=RRGGBB` oracle lines (T2288) from line $from
# to line $to of the app's stderr: each as its alpha and band.
function Get-FaceAlphas([int]$from, [int]$to) {
    $lines = @(Get-Content -Path $script:errlog -ErrorAction SilentlyContinue)
    $out = @()
    for ($i = $from; $i -lt [math]::Min($to, $lines.Count); $i++) {
        if ($lines[$i] -match 'strip face alpha=(\d+) band=([0-9a-f]{6})') {
            $out += [pscustomobject]@{ Alpha = [int]$Matches[1]; Band = $Matches[2] }
        }
    }
    return $out
}
# The `stack fold carried content_alpha=N card=L,W live=0|1` oracle lines
# (T2457) from line $from to line $to: each frame of a fold whose card carries
# its pane's last frame, the content's strength, where the card is drawn, and
# whether the live pane window was still on show after the frame.
function Get-Carried([int]$from, [int]$to) {
    $lines = @(Get-Content -Path $script:errlog -ErrorAction SilentlyContinue)
    $out = @()
    for ($i = $from; $i -lt [math]::Min($to, $lines.Count); $i++) {
        if ($lines[$i] -match 'stack fold carried content_alpha=(\d+) card=(-?\d+),(\d+) live=(\d)') {
            $out += [pscustomobject]@{ Alpha = [int]$Matches[1]; Left = [int]$Matches[2]; Width = [int]$Matches[3]; Live = [int]$Matches[4] }
        }
    }
    return $out
}
# The `stack unfold carried content_alpha=N card=L,W live=0|1 frame=0|1
# resizes=N` oracle lines (T2458) from line $from to line $to: each frame of
# a card opening out of its strip, drawn by its face from the frame its pane
# drew at its new size while hidden.
function Get-Opening([int]$from, [int]$to) {
    $lines = @(Get-Content -Path $script:errlog -ErrorAction SilentlyContinue)
    $out = @()
    for ($i = $from; $i -lt [math]::Min($to, $lines.Count); $i++) {
        if ($lines[$i] -match 'stack unfold carried content_alpha=(\d+) card=(-?\d+),(\d+) live=(\d) frame=(\d) resizes=(\d+)') {
            $out += [pscustomobject]@{ Alpha = [int]$Matches[1]; Left = [int]$Matches[2]; Width = [int]$Matches[3]; Live = [int]$Matches[4]; Frame = [int]$Matches[5]; Resizes = [int]$Matches[6] }
        }
    }
    return $out
}
# The `banner cut span left=L right=R width=W` oracle lines (T2661) from line
# $from to line $to: a banner shown cut to its pane's card.
function Get-BannerCuts([int]$from, [int]$to) {
    $lines = @(Get-Content -Path $script:errlog -ErrorAction SilentlyContinue)
    $out = @()
    for ($i = $from; $i -lt [math]::Min($to, $lines.Count); $i++) {
        if ($lines[$i] -match 'banner cut span left=(-?\d+) right=(-?\d+) width=(\d+)') {
            $out += [pscustomobject]@{ Left = [int]$Matches[1]; Right = [int]$Matches[2]; Width = [int]$Matches[3] }
        }
    }
    return $out
}
# The path s2's banner last took (T2749): 'visual' when the composition
# present draws it inside the pane (T2559, the default once T2514 flips),
# 'popup' when it is the GhozttyBannerOverlay window, $null before any line.
# The app logs `banner path visual=true|false` whenever it switches.
function Get-BannerPath([int]$to = [int]::MaxValue) {
    $lines = @(Get-Content -Path $script:errlog -ErrorAction SilentlyContinue)
    $path = $null
    for ($i = 0; $i -lt [math]::Min($to, $lines.Count); $i++) {
        if ($lines[$i] -match 'banner path visual=(true|false)') { $path = if ($Matches[1] -eq 'true') { 'visual' } else { 'popup' } }
    }
    return $path
}
# How many log lines match $pattern from line $from on (T2749).
function Get-LogMatches([string]$pattern, [int]$from = 0) {
    $lines = @(Get-Content -Path $script:errlog -ErrorAction SilentlyContinue)
    $n = 0
    for ($i = $from; $i -lt $lines.Count; $i++) { if ($lines[$i] -match $pattern) { $n++ } }
    return $n
}
# The `stack unfold landed resizes=N live=0|1` oracle lines (T2458) from line
# $from to line $to.
function Get-Landed([int]$from, [int]$to) {
    $lines = @(Get-Content -Path $script:errlog -ErrorAction SilentlyContinue)
    $out = @()
    for ($i = $from; $i -lt [math]::Min($to, $lines.Count); $i++) {
        if ($lines[$i] -match 'stack unfold landed resizes=(\d+) live=(\d)') {
            $out += [pscustomobject]@{ Resizes = [int]$Matches[1]; Live = [int]$Matches[2] }
        }
    }
    return $out
}
# The `stack cut redraw=N width=W` oracle lines (T2415) from line $from to
# line $to of the app's stderr: each mid-slide cut, and whether it redrew.
function Get-CutRedraws([int]$from, [int]$to) {
    $lines = @(Get-Content -Path $script:errlog -ErrorAction SilentlyContinue)
    $out = @()
    for ($i = $from; $i -lt [math]::Min($to, $lines.Count); $i++) {
        if ($lines[$i] -match 'stack cut redraw=(\d) width=(\d+)') {
            $out += [pscustomobject]@{ Redraw = [int]$Matches[1]; Width = [int]$Matches[2] }
        }
    }
    return $out
}
# The commonest colour of a capture (as RRGGBB) and its share of a sample grid.
function Get-TopColor($shot) {
    $hist = @{}
    $n = 0
    $sx = [math]::Max(1, [int]($shot.Width / 24))
    $sy = [math]::Max(1, [int]($shot.Height / 24))
    # pixel-region: the capture is the strip face popup alone, so the whole of it is the subject
    for ($y = 0; $y -lt $shot.Height; $y += $sy) {
        for ($x = 0; $x -lt $shot.Width; $x += $sx) {
            $c = '{0:x6}' -f ($shot.Bitmap.GetPixel($x, $y).ToArgb() -band 0xFFFFFF)
            $n++
            if ($hist.ContainsKey($c)) { $hist[$c]++ } else { $hist[$c] = 1 }
        }
    }
    $topKey = $null
    foreach ($k in $hist.Keys) { if ($null -eq $topKey -or $hist[$k] -gt $hist[$topKey]) { $topKey = $k } }
    return [pscustomobject]@{ Color = $topKey; Share = if ($n -gt 0) { $hist[$topKey] / $n } else { 0 } }
}
function Get-LogLength { return @(Get-Content -Path $script:errlog -ErrorAction SilentlyContinue).Count }
function Find-Pane($panes, [int64]$hwnd) {
    $m = @($panes | Where-Object { $_.Hwnd -eq $hwnd })
    if ($m.Count -eq 1) { return $m[0] }
    return $null
}
# The distinct Left edges of pane $hwnd, on show, strictly between $a and $b.
function Get-Between($samples, [int64]$hwnd, [int]$a, [int]$b) {
    $lo = [math]::Min($a, $b)
    $hi = [math]::Max($a, $b)
    $seen = @{}
    foreach ($s in $samples) {
        $q = Find-Pane $s.Panes $hwnd
        if ($null -eq $q -or -not $q.Visible) { continue }
        if ($q.Left -gt $lo -and $q.Left -lt $hi) { $seen[[int]$q.Left] = $true }
    }
    return @($seen.Keys | Sort-Object)
}

# -----------------------------------------------------------------------------

$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN
$savedPipe = $env:GHOZTTY_PIPE_SUFFIX
$savedSlide = $env:GHOZTTY_STACK_SLIDE_MS
$env:GHOZTTY_PIPE_SUFFIX = "-foldslide$PID"
$env:GHOZTTY_STACK_SLIDE_MS = "$slideMs"
# -Tree (T2777): the composition pane tree, restored on the way out.
$treeKnobs = @('GHOZTTY_COMP_PRESENT', 'GHOZTTY_COMP_CHROME', 'GHOZTTY_COMP_PANE_TREE')
$savedTree = @{}
foreach ($k in $treeKnobs) { $savedTree[$k] = [Environment]::GetEnvironmentVariable($k) }
if ($Tree) { foreach ($k in $treeKnobs) { [Environment]::SetEnvironmentVariable($k, '1') } }
$savedDt = $env:GHOZTTY_STACK_SLIDE_DT_MS
if ($SlowFrames) { $env:GHOZTTY_STACK_SLIDE_DT_MS = '80' }

Stop-RepoInstances
New-Item -ItemType Directory -Force $root | Out-Null
$tmp = Join-Path $root 'app'
New-Item -ItemType Directory -Force (Get-GhozttyAgentStateDir -Root $tmp) | Out-Null
$env:LOCALAPPDATA = $tmp
$env:GHOSTTY_LOCAL_AGENT_BIN = $agent

Reset-TestBody
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$script:faceShot = $null
$script:faceShotsEmpty = 0
$faceRetakes = 5

try {
    Assert (Test-Path $exe) 'ghoztty exe exists in zig-out'
    Assert (Test-Path $agent) 'ghoztty-agent exe exists in zig-out'
    [void](Assert-GhozttyIsolatedBuild -Exe $exe)
    if ($NegativeControl) {
        Say 'NEGATIVE CONTROL: the slide is 0 ms (an instant re-layout) - F1/F2 MUST fail'
    }

    # ---- setup: P | s1 | s2 ----------------------------------------------------
    # T2295: the row is sized from the pane minimum (225 DIP since T2284), so
    # P | s1 | s2 fits and the drag below folds s2 where it says it does.
    $minDip = 225
    $winDip = 5 * $minDip
    Say "== setup: P | s1 | s2, $winDip DIP wide, slide $slideMs ms"
    $app = Start-App
    $script:appPid = [int]$app.Pid
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    Start-Sleep -Milliseconds 800
    $dpi = [int](Get-TestWindowDpi -Window $top)
    if ($dpi -le 0) { $dpi = 96 }
    $scale = $dpi / 96.0
    [void](Set-TestWindowPos -Window $top -X 0 -Y 0 -Width (Get-TestChromeDip -Dip $winDip -Scale $scale) -Height (Get-TestChromeDip -Dip 700 -Scale $scale))
    Start-Sleep -Seconds 2
    & $exe +split --direction=right --name=s1 | Out-Null
    Start-Sleep -Milliseconds 800
    & $exe +split --pane=s1 --direction=right --name=s2 | Out-Null
    # F19 (T2661): s2, the pane that folds and comes back, wears a banner.
    & $exe +set-banner --target=s2 "**T2661** - this banner comes back with its card" | Out-Null
    $c3 = @(Wait-Shown $top 3)
    if ($c3.Count -ne 3) { Write-TestAssertedNothing -Reason "three columns never came up (got $($c3.Count))" }
    Start-Sleep -Milliseconds 800
    $c3 = @(Get-VisiblePanes $top)
    $hP = $c3[0].Hwnd
    $hS1 = $c3[1].Hwnd
    $hS2 = $c3[2].Hwnd
    $script:watchPane = [int64]$hS2
    # On the composition path (T2559) the banner at rest is a visual inside
    # s2 and its popup sits hidden; the popup is still the window the unfold
    # puts on show over the carried card (T2749), so it is the one watched.
    $script:bannerPath = Get-BannerPath
    $bannerAll = @(Get-TestWindows -ProcessId $app.Pid -Class 'GhozttyBannerOverlay')
    $bannerWins = @($bannerAll | Where-Object Visible)
    if ($script:bannerPath -eq 'visual') {
        $script:watchBanner = [int64]0
        Assert ($bannerWins.Count -eq 0) "F19 precondition: s2's banner is on show before the fold, as a visual in its pane (path=visual, $($bannerWins.Count) popups on show)"
    } else {
        $script:watchBanner = if ($bannerWins.Count -eq 1) { [int64]$bannerWins[0].Hwnd } else { [int64]0 }
        Assert ($bannerWins.Count -eq 1) "F19 precondition: s2's banner is on show before the fold ($($bannerWins.Count) banner popups, path=$($script:bannerPath))"
    }
    Say ("      banner path at rest: {0}" -f $script:bannerPath)
    $pW0 = $c3[0].Width
    $s2Left0 = $c3[2].Left
    Say ("      dpi {0}; columns: {1}" -f $dpi, (Format-Cols $c3))

    $gridLeft = $c3[0].Left
    $gridW = $c3[2].Right - $c3[0].Left
    $x0 = [int](($c3[0].Right + $c3[1].Left) / 2)
    $y = [int](($c3[0].Top + $c3[0].Bottom) / 2)
    # 1000/1500 is past the fold point; 850/1500 is short of it, where the
    # drag has only resized. Since T2263 (Mac a81db68f9) the fold point is where
    # s1 and s2 stop fitting at their minimums: the row less two minimums and
    # a gutter, ~891/1500 of it in the flat style - no 48 DIP past it any
    # more, so the old 900/1500 approach had already started the fold.
    # Derived from the minimum rather than as fractions of the row (T2295):
    # the row starts after the sidebar, a fixed width the fractions ignore.
    $gutter = $c3[1].Left - $c3[0].Right
    $foldAt = $c3[2].Right - 2 * (Get-TestChromeDip -Dip $minDip -Scale $scale) - $gutter
    $xFold = [int]($foldAt + (Get-TestChromeDip -Dip 100 -Scale $scale))
    $xNear = [int]($foldAt - (Get-TestChromeDip -Dip 40 -Scale $scale))
    Say ("      fold point ~{0} px; approach to {1}, fold at {2}" -f $foldAt, $xNear, $xFold)

    # Focus P, so s2 - the pane that folds - is an unfocused pane and carries
    # the dim wash whose bleed T2227 is about.
    [void](Send-TestMouse -Window $top -Target $top -X ([int](($c3[0].Left + $c3[0].Right) / 2)) -Y $y -Action click)
    Start-Sleep -Milliseconds 600
    $washes = @(Get-TestWindows -ProcessId $app.Pid -Class 'GhozttyDimOverlay' | Where-Object Visible)
    # On the composition path the wash is a visual in its pane (T2491), read
    # from the app's transition lines: shown less hidden is the washes up now.
    # (s2 wears a banner, whose band keeps its wash on the popup.)
    $visualWashes = [math]::Max(0, (Get-LogMatches 'dim overlay shown as visual') - (Get-LogMatches 'dim overlay hidden visual=true'))
    Say ("      P focused; {0} dim wash popup(s) on show, {1} shown as a visual" -f $washes.Count, $visualWashes)
    # Glass panes never dim (T2281, Mac 9da9618f8): there F6 still checks
    # every popup, but has no wash to check.
    if ($PaneStyle -eq 'flat') {
        Assert (($washes.Count + $visualWashes) -ge 2) "F6 precondition: with P focused, s1 and s2 carry the dim wash ($($washes.Count) popups + $visualWashes visuals on show)"
    } else {
        Assert (($washes.Count + $visualWashes) -eq 0) "F6 precondition: glass panes carry no dim wash (T2281) ($($washes.Count) popups + $visualWashes visuals on show)"
    }

    # ---- the fold, held, sampled ---------------------------------------------
    Say '== drag the root divider up to the fold point, then over it in one move, and hold'
    [void](Send-TestMouse -Window $top -Target $top -X $x0 -Y $y -Action down -HoldMs 0)
    Start-Sleep -Milliseconds 150
    Move-To $top $x0 $xNear $y
    Start-Sleep -Milliseconds 400
    # The baseline is the layout the hand made before the fold: what moves
    # after this is the fold's doing.
    $near = @(Get-VisiblePanes $top)
    if ($near.Count -ne 3) { Write-TestAssertedNothing -Reason "the approach already folded ($($near.Count) on show at 850/1500)" }
    # Three on show is not enough: a fold already under way still shows s2
    # mid-slide, on its way past the grid's right edge.
    if ($near[2].Right -gt $c3[2].Right + 2) { Write-TestAssertedNothing -Reason "the approach already started the fold (s2 at $($near[2].Left)-$($near[2].Right), grid ends at $($c3[2].Right))" }
    $pW0 = (Find-Pane $near $hP).Width
    $s2Left0 = (Find-Pane $near $hS2).Left
    Say ("      short of the fold: {0}" -f (Format-Cols $near))
    $logFold = Get-LogLength
    [void](Send-TestMouse -Window $top -Target $top -X $xFold -Y $y -Action move -HoldMs 0)
    $fold = @(Get-Samples $top ($slideMs + 1000))
    $logBack = Get-LogLength
    $rest = @(Get-Panes $top)
    $pEnd = Find-Pane $rest $hP
    $s2End = Find-Pane $rest $hS2
    Say ("      {0} samples; at rest: {1}" -f $fold.Count, (Format-Cols $rest))

    if ($SlowFrames) {
        # F15: slow frames still fade (T2442).
        $slow = @(Get-FaceAlphas $logFold $logBack)
        $slowMid = @($slow | Where-Object { $_.Alpha -gt 0 -and $_.Alpha -lt 255 } | ForEach-Object Alpha | Sort-Object -Unique)
        $jump = 0
        $prev = 0
        foreach ($f in $slow) { $jump = [math]::Max($jump, $f.Alpha - $prev); $prev = $f.Alpha }
        Say ("      face alphas folding at 80 ms frames: {0}" -f (($slow | ForEach-Object Alpha) -join ' > '))
        # Carried (T2457), the face is opaque and the fade is the content's
        # strength: it must still never rise. Live, the T2442 cap holds.
        $slowCarried = @(Get-Carried $logFold $logBack)
        if ($slowCarried.Count -ge 2) {
            $slowRise = 0
            for ($i = 1; $i -lt $slowCarried.Count; $i++) { $slowRise = [math]::Max($slowRise, $slowCarried[$i].Alpha - $slowCarried[$i - 1].Alpha) }
            Say ("      carried content folding at 80 ms frames: {0}" -f (($slowCarried | ForEach-Object Alpha) -join ' > '))
            Assert ($slowRise -eq 0) "F15: at 80 ms frames the carried content's strength never rises ($($slowCarried.Count) frames, largest rise $slowRise)"
        } else {
            Assert ($slowMid.Count -ge 2) "F15: at 80 ms frames the face is drawn at $($slowMid.Count) partial alphas (need 2+): the fade is not crossed in one frame"
            Assert ($slow.Count -ge 2 -and $jump -le 92) "F15: at 80 ms frames no frame raises the face more than a third of the fade (85) and rounding (largest rise $jump of 255)"
        }
        [void](Send-TestMouse -Window $top -Target $top -X $x0 -Y $y -Action up -HoldMs 0)
        Start-Sleep -Milliseconds 400
    } else {

        # F1: s2 slides away.
        $s2Tuck = if ($s2End) { $s2End.Left } else { $s2Left0 }
        $s2Between = @(Get-Between $fold $hS2 $s2Left0 $s2Tuck)
        Say ("      s2 {0} -> {1}; on show between: {2}" -f $s2Left0, $s2Tuck, ($s2Between -join ', '))
        Assert ([math]::Abs($s2Tuck - $s2Left0) -gt (Get-TestChromeDip -Dip 40 -Scale $scale)) "F1: s2 tucks a real distance away ($s2Left0 -> $s2Tuck px)"
        # Carried (T2457), s2's card is its face, drawn where the oracle says.
        $carried = @(Get-Carried $logFold $logBack)
        $lo1 = [math]::Min($s2Left0, $s2Tuck)
        $hi1 = [math]::Max($s2Left0, $s2Tuck)
        $carriedAt = @($carried | Where-Object { $_.Left -gt $lo1 -and $_.Left -lt $hi1 } | ForEach-Object Left)
        $s2Seen = @(@($s2Between) + $carriedAt | Sort-Object -Unique)
        Assert ($s2Seen.Count -ge 2) "F1: s2's card is seen at $($s2Seen.Count) positions on its way to the edge (need 2+; $($s2Between.Count) live, $($carriedAt.Count) carried): it slides away, it does not vanish"

        # F2: P grows through the slide.
        $pW1 = if ($pEnd) { $pEnd.Width } else { $pW0 }
        $widths = New-Object System.Collections.Generic.List[int]
        $widths.Add($pW0)
        foreach ($s in $fold) {
            $q = Find-Pane $s.Panes $hP
            if ($null -ne $q -and $q.Visible -and $q.Width -ne $widths[$widths.Count - 1]) { $widths.Add($q.Width) }
        }
        $lo = [math]::Min($pW0, $pW1)
        $hi = [math]::Max($pW0, $pW1)
        $mid = @($widths | Where-Object { $_ -gt $lo -and $_ -lt $hi } | Sort-Object -Unique)
        $bigStep = 0
        for ($i = 1; $i -lt $widths.Count; $i++) { $bigStep = [math]::Max($bigStep, [math]::Abs($widths[$i] - $widths[$i - 1])) }
        $span = [math]::Max(1, $hi - $lo)
        Say ("      P width {0} -> {1}; path: {2}" -f $pW0, $pW1, ($widths -join ' > '))
        Assert ($span -gt (Get-TestChromeDip -Dip 100 -Scale $scale)) "F2: P grows a real amount ($pW0 -> $pW1 px)"
        Assert ($mid.Count -ge 2) "F2: P is seen at $($mid.Count) widths on the way (need 2+): it grows through the slide"
        Assert ($bigStep -le 0.6 * $span) "F2: no single step covers most of the change (largest $bigStep of $span px)"

        # F3: the run over the card tucking away.
        $both = 0
        $s1Above = 0
        foreach ($s in $fold) {
            $a = Find-Pane $s.Panes $hS1
            $b = Find-Pane $s.Panes $hS2
            if ($null -eq $a -or $null -eq $b -or -not $a.Visible -or -not $b.Visible) { continue }
            if ($b.Left -le $s2Left0 -or $b.Left -ge $s2Tuck) { continue }
            $both++
            if ($a.Z -lt $b.Z) { $s1Above++ }
        }
        if ($NegativeControl) {
            Say "      (negative control: $both mid-slide samples)"
        } else {
            # Carried (T2457), s2's live window is hidden for the fold and
            # never sampled above s1; where both are on show, s1 is above.
            Assert (($both -ge 1 -or $carried.Count -ge 2) -and $s1Above -eq $both) "F3: mid-slide, s1 is above s2 in the z-order ($s1Above of $both samples with both on show; s2 carried on $($carried.Count) frames)"
        }

        # F6: nothing the app shows bleeds out of the window mid-fold.
        $strayFold = @($fold | Where-Object { $_.Stray.Count -gt 0 })
        $firstFold = if ($strayFold.Count -gt 0) { "at $($strayFold[0].Ms) ms: $($strayFold[0].Stray -join ' | ')" } else { '' }
        Assert ($strayFold.Count -eq 0) "F6: no popup reaches outside the window during the fold ($($strayFold.Count) of $($fold.Count) samples) $firstFold"

        # F7: the bar follows P's edge as it is drawn, short of the hand.
        $barFold = @(Get-GlidingBar $logFold | Where-Object { $_.Shown -lt $_.Laid })
        $barFoldAt = @($barFold | ForEach-Object Shown | Sort-Object -Unique)
        Say ("      bar drawn short of its gutter at: {0}" -f ($barFoldAt -join ', '))
        Assert ($barFoldAt.Count -ge 2) "F7: folding, the dragged bar is drawn at $($barFoldAt.Count) places short of its laid-out gutter (need 2+): it stays with the gliding card"

        # F8: the folding card narrows into its strip (T2287).
        $narrow = @(Get-PartialWidths $fold)
        $s2Near = Find-Pane $near $hS2
        $s2Full = if ($s2Near) { $s2Near.Width } else { 0 }
        $carriedNarrow = @($carried | Where-Object { $_.Width -lt 0.8 * $s2Full } | ForEach-Object Width | Sort-Object -Unique)
        Say ("      s2 cut to its narrowing card at: {0} px; carried at {1} px" -f ($narrow -join ', '), ($carriedNarrow -join ', '))
        Assert (($narrow.Count + $carriedNarrow.Count) -ge 2) "F8: folding, s2's card is seen at $($narrow.Count + $carriedNarrow.Count) partial widths (need 2+): its card narrows into the strip, it does not slide off full size"

        # F10: the strip's face fades in over the narrowing card (T2288).
        $fadeIn = @(Get-FaceAlphas $logFold $logBack)
        $inMid = @($fadeIn | Where-Object { $_.Alpha -gt 0 -and $_.Alpha -lt 255 } | ForEach-Object Alpha | Sort-Object -Unique)
        $faceSeen = @($fold | Where-Object { $_.Faces -gt 0 }).Count
        Say ("      face alphas folding: {0}; face on show in {1} of {2} samples" -f (($fadeIn | ForEach-Object Alpha) -join ' > '), $faceSeen, $fold.Count)
        if ($Tree) {
            $fv = Get-FaceVisual $logFold $logBack
            Say ("      face visual folding: shown {0}, hidden {1}, failed {2}; popup on show in {3} samples" -f $fv.Shown, $fv.Hidden, $fv.Failed, $faceSeen)
            Assert ($fv.Shown -ge 1 -and $faceSeen -eq 0) "F10: folding, the strip's face goes up in the window's tree ($($fv.Shown) times), never on its popup ($faceSeen samples)"
        } else {
            Assert ($faceSeen -ge 1) "F10: folding, the strip's face is seen on show over s2's card ($faceSeen samples)"
        }
        # T2457: the card carries its content, so the fade is the CONTENT's
        # strength, falling over the tween - never rising, which is the flash.
        $cMid = @($carried | Where-Object { $_.Alpha -gt 0 -and $_.Alpha -lt 255 } | ForEach-Object Alpha | Sort-Object -Unique)
        $rise = 0
        for ($i = 1; $i -lt $carried.Count; $i++) { $rise = [math]::Max($rise, $carried[$i].Alpha - $carried[$i - 1].Alpha) }
        Say ("      carried content folding: {0}" -f (($carried | ForEach-Object Alpha) -join ' > '))
        Assert ($inMid.Count + $cMid.Count -ge 2) "F10: folding, the content is drawn at $($cMid.Count) partial strengths carried ($($inMid.Count) partial face alphas live) (need 2+): the title fades in as the content fades out"
        Assert ($carried.Count -ge 2 -and $rise -eq 0) "F10: folding, the carried content's strength never rises ($($carried.Count) frames, largest rise $rise)"
        # F16 (T2457): carried, the live pane is hidden - one picture per card.
        $liveAfter = @($carried | Select-Object -Skip 1 | Where-Object { $_.Live -eq 1 }).Count
        Assert ($carried.Count -ge 2 -and $liveAfter -eq 0) "F16: folding, s2's live window is off show on every carried frame after the first ($liveAfter of $([math]::Max(0, $carried.Count - 1)))"
        # F14: the shrinking cut is set without a redraw after the first (T2415).
        if ($PaneStyle -eq 'flat') {
            $cutsIn = @(Get-CutRedraws $logFold $logBack)
            $redrawsIn = @($cutsIn | Where-Object { $_.Redraw -eq 1 }).Count
            Say ("      cuts folding: {0} ({1} redrawn)" -f (($cutsIn | ForEach-Object { '{0}{1}' -f $_.Width, $(if ($_.Redraw) { '*' } else { '' }) }) -join ' > '), $redrawsIn)
            Assert ($cutsIn.Count -ge 2) "F14: folding, s2 is re-cut on $($cutsIn.Count) frames (need 2+)"
            Assert ($redrawsIn -le 1) "F14: folding, s2's shrinking cut is redrawn on $redrawsIn frames (at most 1, the first): a cut that only shrinks has nothing to repaint"
        }
        # F18 (T2459): the panes that stay open hold their grid while the fold
        # the hand started glides - P widens on every frame of it (F2) - and
        # take their size once the motion has settled, not once per frame.
        $foldLines = @(Get-Content -Path $script:errlog -ErrorAction SilentlyContinue | Select-Object -Skip $logFold -First ([math]::Max(0, $logBack - $logFold)))
        $heldIn = @($foldLines | Where-Object { $_ -match 'resize pace=held' }).Count
        $appliedIn = @($foldLines | Where-Object { $_ -match 'resize applied cols=' }).Count
        Say ("      terminal resizes folding: {0} held, {1} applied" -f $heldIn, $appliedIn)
        Assert ($heldIn -ge 2) "F18: folding under the hand, the open panes' resizes are held ($heldIn held)"
        Assert ($appliedIn -le 3) "F18: folding under the hand, the terminals take their size about once a pane, not once a frame ($appliedIn applied over $heldIn resizes, bound 3)"
        $facesFolded = @(Get-TestWindows -ProcessId $app.Pid -Class 'GhozttyStripFace' | Where-Object Visible).Count
        Assert ($facesFolded -eq 0) "F12: folded and at rest, no face is on show ($facesFolded): the window's strip has taken over"
        if ($Tree) {
            $fvRest = Get-FaceVisual 0 (Get-LogLength)
            Assert ($fvRest.Shown -ge 1 -and $fvRest.Shown -eq $fvRest.Hidden) "F12: folded and at rest, the face's visual is down too (up $($fvRest.Shown), down $($fvRest.Hidden))"
        }

        # F4: the T2124 layout at rest.
        $shown = @($rest | Where-Object Visible)
        Assert ($shown.Count -eq 2) "F4: at rest two panes are on show (got $($shown.Count))"
        Assert ($null -ne $s2End -and -not $s2End.Visible) 'F4: s2 is hidden once its slide is over'

        # ---- the unfold, still held, sampled ---------------------------------------
        Say '== drag back to the start, still held'
        # One move, as the fold: stepped, the unfold began mid-steps and most of
        # its widening was over before the sampler started (T2287's F9).
        [void](Send-TestMouse -Window $top -Target $top -X $x0 -Y $y -Action move -HoldMs 0)
        $back = @(Get-Samples $top ($slideMs + 1000))
        $logEnd = Get-LogLength
        $facesAtRest = @(Get-TestWindows -ProcessId $app.Pid -Class 'GhozttyStripFace' | Where-Object Visible).Count
        $again = @(Get-Panes $top)
        $s2Back = Find-Pane $again $hS2
        $s2Home = if ($s2Back) { $s2Back.Left } else { $s2Tuck }
        $s2Coming = @(Get-Between $back $hS2 $s2Tuck $s2Home)
        Say ("      s2 {0} -> {1}; on show between: {2}; at rest: {3}" -f $s2Tuck, $s2Home, ($s2Coming -join ', '), (Format-Cols $again))
        $widen = @(Get-PartialWidths $back)
        Say ("      s2 cut to its widening card at: {0} px" -f ($widen -join ', '))
        # Carried (T2458), s2's opening card is its face, drawn where the
        # oracle says, its pane hidden at its new size.
        $opening = @(Get-Opening $logBack $logEnd)
        $landed = @(Get-Landed $logBack $logEnd)
        $s2Full = if ($s2Back) { $s2Back.Width } else { 0 }
        $lo5 = [math]::Min($s2Tuck, $s2Home)
        $hi5 = [math]::Max($s2Tuck, $s2Home)
        $openAt = @($opening | Where-Object { $_.Left -gt $lo5 -and $_.Left -lt $hi5 } | ForEach-Object Left)
        $openWide = @($opening | Where-Object { $_.Width -lt 0.8 * $s2Full } | ForEach-Object Width | Sort-Object -Unique)
        $s2ComingAll = @(@($s2Coming) + $openAt | Sort-Object -Unique)
        Say ("      opening carried: {0}" -f (($opening | ForEach-Object { '{0}@{1}{2}' -f $_.Alpha, $_.Width, $(if ($_.Frame) { '' } else { '-' }) }) -join ' > '))
        if (-not $NegativeControl) {
            Assert ($s2ComingAll.Count -ge 2) "F5: unfolding, s2's card is seen at $($s2ComingAll.Count) positions on its way back (need 2+; $($s2Coming.Count) live, $($openAt.Count) carried)"
            Assert (($widen.Count + $openWide.Count) -ge 2) "F9: unfolding, s2's card is seen at $($widen.Count + $openWide.Count) partial widths (need 2+; $($widen.Count) cut live, $($openWide.Count) carried): its card widens out of the strip"
            # F17 (T2458): presized while hidden, carried, never resized on the way.
            $openLive = @($opening | Where-Object { $_.Live -eq 1 }).Count
            $early = @($opening | Where-Object { $_.Frame -eq 0 -and $_.Alpha -gt 0 }).Count
            $withFrame = @($opening | Where-Object { $_.Frame -eq 1 }).Count
            $openFall = 0
            for ($i = 1; $i -lt $opening.Count; $i++) { $openFall = [math]::Max($openFall, $opening[$i - 1].Alpha - $opening[$i].Alpha) }
            $openResized = @($opening | Where-Object { $_.Resizes -ne 0 }).Count
            Assert ($opening.Count -ge 2 -and $openLive -eq 0) "F17: unfolding, s2's live window is off show on every carried frame ($openLive of $($opening.Count))"
            Assert ($early -eq 0) "F17: unfolding, no content is drawn before the frame at the new size has landed ($early frames)"
            Assert ($withFrame -ge 1) "F17: unfolding, the frame drawn at the new size lands mid-glide ($withFrame of $($opening.Count) frames carry it)"
            Assert ($opening.Count -ge 2 -and $openFall -eq 0) "F17: unfolding, the carried content's strength never falls ($($opening.Count) frames, largest fall $openFall)"
            Assert ($openResized -eq 0) "F17: unfolding, s2's terminal is resized 0 times once the motion has started ($openResized frames saw a resize)"
            $land = if ($landed.Count -gt 0) { $landed[-1] } else { $null }
            $landSays = if ($land) { "resizes=$($land.Resizes) live=$($land.Live)" } else { 'no landed line' }
            Assert ($null -ne $land -and $land.Resizes -eq 0 -and $land.Live -eq 1) "F17: unfolding, s2 lands a live pane with 0 resizes since the motion started ($landSays)"
            # F19 (T2661): the banner comes out with the card, cut to it.
            $hiddenWithBanner = @($back | Where-Object {
                    $q = Find-Pane $_.Panes $hS2
                    $null -ne $q -and -not $q.Visible -and $null -ne $_.Banner -and $_.Banner.Shown -gt 0
                })
            $cutSpans = @(Get-BannerCuts $logBack $logEnd)
            $cutWidths = @($cutSpans | ForEach-Object { $_.Right - $_.Left } | Where-Object { $_ -lt 0.8 * $s2Full } | Sort-Object -Unique)
            Say ("      banner mid-unfold: on show over the carried card in {0} sample(s); cut to: {1} px" -f $hiddenWithBanner.Count, ($cutWidths -join ', '))
            Assert ($hiddenWithBanner.Count -ge 2) "F19: unfolding, s2's banner is on show in $($hiddenWithBanner.Count) samples while its live window is off show (need 2+): it comes out with the card"
            Assert ($cutWidths.Count -ge 2) "F19: unfolding, s2's banner is cut to $($cutWidths.Count) partial widths (need 2+): it widens with the card"
            $bannerHome = @(Get-TestWindows -ProcessId $app.Pid -Class 'GhozttyBannerOverlay' | Where-Object { $_.Visible -and ($_.Hwnd -eq $script:watchBanner -or $script:bannerPath -eq 'visual') }).Count
            if ($script:bannerPath -eq 'visual') {
                # Landed, the pane shows again and the banner goes back into
                # its tree (T2749): the path line says so and the popup is down.
                $restPath = Get-BannerPath
                Assert ($restPath -eq 'visual' -and $bannerHome -eq 0) "F19: unfolded, s2's banner is back on show at rest as a visual in its pane (path=$restPath, popup on show $bannerHome)"
            } else {
                Assert ($bannerHome -eq 1) "F19: unfolded, s2's banner is on show at rest ($bannerHome)"
            }
        }
        $barBack = @(Get-GlidingBar $logBack | Where-Object { $_.Shown -gt $_.Laid })
        $barBackAt = @($barBack | ForEach-Object Shown | Sort-Object -Unique)
        Say ("      bar drawn past its gutter at: {0}" -f ($barBackAt -join ', '))
        if (-not $NegativeControl) {
            Assert ($barBackAt.Count -ge 2) "F7: unfolding, the dragged bar is drawn at $($barBackAt.Count) places past its laid-out gutter (need 2+)"
        }
        # F11: the face fades back out as the card widens.
        $fadeOut = @(Get-FaceAlphas $logBack $logEnd)
        $outMid = @($fadeOut | Where-Object { $_.Alpha -gt 0 -and $_.Alpha -lt 255 } | ForEach-Object Alpha | Sort-Object -Unique)
        Say ("      face alphas unfolding: {0}" -f (($fadeOut | ForEach-Object Alpha) -join ' > '))
        if (-not $NegativeControl) {
            # Carried (T2458), the face is opaque and the fade is the content's
            # strength coming up; live, the face's alpha falls.
            $oMid = @($opening | Where-Object { $_.Alpha -gt 0 -and $_.Alpha -lt 255 } | ForEach-Object Alpha | Sort-Object -Unique)
            if ($opening.Count -ge 2) {
                Assert ($oMid.Count -ge 2) "F11: unfolding, the carried content is drawn at $($oMid.Count) partial strengths (need 2+): the content fades in as the title fades out"
                Assert ($opening[-1].Alpha -gt $opening[0].Alpha) "F11: unfolding, the carried content's strength rises ($($opening[0].Alpha) -> $($opening[-1].Alpha))"
            } else {
                Assert ($outMid.Count -ge 2) "F11: unfolding, the face is drawn at $($outMid.Count) partial alphas (need 2+): the title fades out as the content comes back"
                if ($fadeOut.Count -ge 2) {
                    Assert ($fadeOut[-1].Alpha -lt $fadeOut[0].Alpha) "F11: unfolding, the face's alpha falls ($($fadeOut[0].Alpha) -> $($fadeOut[-1].Alpha))"
                }
            }
        }
        Assert ($facesAtRest -eq 0) "F12: unfolded and at rest, no face is on show ($facesAtRest)"
        if ($Tree) {
            $fvEnd = Get-FaceVisual 0 (Get-LogLength)
            Assert ($fvEnd.Shown -ge 2 -and $fvEnd.Shown -eq $fvEnd.Hidden) "F12: unfolded and at rest, the face's visual is down too (up $($fvEnd.Shown), down $($fvEnd.Hidden))"
        }
        # F14: a growing cut is redrawn - the pixels it gives back were never drawn.
        # Carried (T2458) the opening pane is hidden: no pixel of it shows, so
        # there is nothing a redraw could owe.
        if ($PaneStyle -eq 'flat' -and -not $NegativeControl -and $opening.Count -lt 2) {
            $cutsOut = @(Get-CutRedraws $logBack $logEnd)
            $redrawsOut = @($cutsOut | Where-Object { $_.Redraw -eq 1 }).Count
            Say ("      cuts unfolding: {0} of {1} redrawn" -f $redrawsOut, $cutsOut.Count)
            Assert ($redrawsOut -ge 2) "F14: unfolding, s2's growing cut is redrawn on $redrawsOut frames (need 2+)"
        }

        # F13: the face's pixels are the strip's band (flat: one solid band).
        if ($Tree -and -not $NegativeControl) {
            # The face is the visual: no frame of the run may fall back to the
            # popup, and the popup is never photographed because it is never up.
            $fvAll = Get-FaceVisual 0 (Get-LogLength)
            $popupShown = Get-LogMatches 'strip face shown alpha='
            Assert ($fvAll.Failed -eq 0 -and $popupShown -eq 0 -and $null -eq $script:faceShot) "F13: every face frame was a picture in the window's tree ($($fvAll.Failed) fell back, the popup shown $popupShown times)"
        } elseif ($PaneStyle -eq 'flat' -and -not $NegativeControl) {
            $bands = @(@($fadeIn) + @($fadeOut) | ForEach-Object Band | Sort-Object -Unique)
            if ($null -eq $script:faceShot) {
                Assert $false "F13: the face was photographed mid-glide (no capture landed; $($script:faceShotsEmpty) untouched black photo(s) retaken)"
            } else {
                $tc = Get-TopColor $script:faceShot
                Say ("      face photo {0}x{1}: top colour {2} ({3:p0}); {4} untouched black photo(s) retaken; logged bands {5}" -f $script:faceShot.Width, $script:faceShot.Height, $tc.Color, $tc.Share, $script:faceShotsEmpty, ($bands -join ', '))
                Assert ($bands -contains $tc.Color) "F13: the face's commonest pixel $($tc.Color) is the strip band the face logged ($($bands -join ', '))"
                Assert ($tc.Share -ge 0.6) "F13: the band covers most of the face ($([math]::Round($tc.Share * 100))%)"
                Close-TestWindowPixels -Shot $script:faceShot
            }
        }

        $strayBack = @($back | Where-Object { $_.Stray.Count -gt 0 })
        $firstBack = if ($strayBack.Count -gt 0) { "at $($strayBack[0].Ms) ms: $($strayBack[0].Stray -join ' | ')" } else { '' }
        Assert ($strayBack.Count -eq 0) "F6: no popup reaches outside the window during the unfold ($($strayBack.Count) of $($back.Count) samples) $firstBack"

        Assert (@($again | Where-Object Visible).Count -eq 3) "F5: all the way back, three on show ($(@($again | Where-Object Visible).Count))"
        [void](Send-TestMouse -Window $top -Target $top -X $x0 -Y $y -Action up -HoldMs 0)
        Start-Sleep -Milliseconds 400

    }
    Complete-TestBody
} catch {
    $script:fail++
    Say "FAIL  script terminated: $($_.Exception.Message)"
    Say "      at $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())"
} finally {
    Say '== cleanup'
    foreach ($r in @($script:GhozttyTestDesktopLaunches)) { if ($r) { $r.Killed = $true } }
    Remove-TestDesktop
    Stop-RepoInstances
    $env:LOCALAPPDATA = $savedLocalAppData
    if ($null -ne $savedAgentBin) { $env:GHOSTTY_LOCAL_AGENT_BIN = $savedAgentBin }
    else { Remove-Item env:GHOSTTY_LOCAL_AGENT_BIN -ErrorAction SilentlyContinue }
    $env:GHOZTTY_PIPE_SUFFIX = $savedPipe
    foreach ($k in $treeKnobs) { [Environment]::SetEnvironmentVariable($k, $savedTree[$k]) }
    if ($null -ne $savedSlide) { $env:GHOZTTY_STACK_SLIDE_MS = $savedSlide }
    else { Remove-Item env:GHOZTTY_STACK_SLIDE_MS -ErrorAction SilentlyContinue }
    if ($null -ne $savedDt) { $env:GHOZTTY_STACK_SLIDE_DT_MS = $savedDt }
    else { Remove-Item env:GHOZTTY_STACK_SLIDE_DT_MS -ErrorAction SilentlyContinue }
    if ($script:fail -eq 0) { Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue }
    else { Say "artifacts preserved at $root" }
}

$fgSeen = @(Stop-TestForegroundWatch)
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @(Get-TestLaunchedPids)
    Assert ($fgSeen.Count -gt 0) 'Z1 the foreground watcher actually sampled (negative control)'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'Z2 no test-desktop app ever became foreground on the interactive desktop'
}

if ($script:fail -eq 0 -and -not $NegativeControl -and $PaneStyle -eq 'flat') {
    # Each mode stamps its own row (T2442).
    if ($SlowFrames) {
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
            update -Guard stack-fold-slide-slow -Repo $repo 2>&1 | ForEach-Object { Say "  $_" }
    } else {
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
            update -Guard stack-fold-slide -Repo $repo 2>&1 | ForEach-Object { Say "  $_" }
    }
}

Say ''
Write-TestVerdict -Label 'T2186 STACK FOLD SLIDE' -Pass $script:pass -Fail $script:fail
