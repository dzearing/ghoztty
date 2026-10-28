# FrameLabReport (T2390) - what a T2373 frame-lab run SAYS, in two forms: a
# results JSON a script can gate on, and an HTML page a person can read.
#
# Invoke-FrameLabCell (FrameLabCatalogue.ps1, T2389) returns one cell's runs
# and verdict as live objects (a GliResult, GfcStats, an FsMotion). None of
# that survives the PowerShell process, and none of it is readable at a glance.
# This file turns a run's cells into:
#
#   THE RESULTS JSON (New-FrameLabResults / Write-FrameLabResults). One record
#     per matrix cell: its knobs, its verdict and reasons, and EVERY metric -
#     bleed frames by class, the motion numbers, the input timing, the capture
#     counts, the accounting run - with SlotGaps written BESIDE AdvanceRate in
#     the same object, because a high advance rate over a capture with slot
#     gaps is a rate over frames nobody got (T2384, 2026-10-27 23:50). The
#     run's own verdict is derived from the cells, never passed in:
#
#       fail        any cell failed
#       incomplete  none failed, some cell's frames were not all accounted for
#       pass        at least one cell passed and none failed or was incomplete
#       no-result   nothing was measured (all blocked / skipped / aborted) -
#                   a lab that ran nothing has not passed
#
#     Test-FrameLabResults is the harness audit's reader: it re-derives the
#     verdict from the cells and refuses a file whose verdict disagrees, whose
#     cells carry an unknown verdict, or whose measured cells lack SlotGaps or
#     AdvanceRate. So a hand-edited or truncated results file cannot read green.
#
#   THE HTML REPORT (New-FrameLabReportHtml). Self-contained, one file: the
#     verdict and counts up top; per interaction, a chart of every measured
#     cell's advance rate against the 0.98 target and its longest stall against
#     the 1-refresh target, so a regression shows as a bar under the line; then
#     a filmstrip of the worst frames with each finding's box outlined in its
#     class colour. Frames are embedded (data: URIs), so the page can be shared
#     without the run's PNG folder.
#
# THE FILMSTRIP'S INPUT. FrameCapture's GfcScorer is a bool - it decides which
# frames are kept as PNG, not where they failed. So the per-frame findings come
# from the cell's Score result: the -Driver's Score block (T2392) returns, beside
# BleedFrames / Motion / MotionMisses, an optional Frames list:
#
#   Frames = @( @{ Index; Png; Findings = @( @{ Cls; Target; Detail; Pixels;
#                                               At = @{ X0; Y0; X1; Y1 } } ) } )
#
# with At in the PNG's own pixel coordinates (an FsFinding's At is already in
# frame coordinates, which is the crop the PNG holds). A cell with no Frames
# still reports every number; it just has nothing to show in the strip.
#
# Pure: no window, no screen, no input. Acceptance: test\win32\frame-lab-report.ps1.
# ASCII-only by design (PS 5.1 on this box mangles non-ASCII on rewrite).

Set-StrictMode -Off

$script:FrameLabResultsSchema = 'ghoztty-frame-lab-results/1'
$script:FrameLabCellVerdicts = @('pass', 'fail', 'incomplete', 'blocked', 'skipped', 'aborted')
$script:FrameLabBleedClasses = @('B1', 'B2', 'B3', 'B4', 'B5', 'B6')
# Worst first: what the strip ranks by when two frames have the same pixels.
$script:FrameLabClassRank = @{ B6 = 6; B1 = 5; B2 = 4; B3 = 3; B4 = 2; B5 = 1 }
$script:FrameLabClassColour = @{
    B1 = '#e5484d'; B2 = '#f76b15'; B3 = '#ffc53d'; B4 = '#46a758'; B5 = '#0090ff'; B6 = '#8e4ec6'
}

function Get-FrameLabNumber($v) {
    # NaN and infinities are not JSON; a metric that could not be measured is null.
    if ($null -eq $v) { return $null }
    $d = [double]$v
    if ([double]::IsNaN($d) -or [double]::IsInfinity($d)) { return $null }
    return $d
}

function Get-FrameLabFindingBox($At) {
    if ($null -eq $At) { return $null }
    return [ordered]@{ X0 = [int]$At.X0; Y0 = [int]$At.Y0; X1 = [int]$At.X1; Y1 = [int]$At.Y1 }
}

<#
One Invoke-FrameLabCell result as a plain record: everything the JSON carries
for that cell, with no live objects left in it.
#>
function ConvertTo-FrameLabCellRecord($Result) {
    $c = $Result.Cell
    $v = $Result.Verdict
    $rec = [ordered]@{
        Id          = $Result.Id
        Interaction = $c.Interaction
        Kind        = $c.Kind
        Panes       = $c.Panes
        Theme       = $c.Theme
        Dpi         = $c.Dpi
        Sidebar     = $c.Sidebar
        StallMs     = $c.StallMs
        Verdict     = $(if ($v) { [string]$v.Verdict } else { $null })
        Reasons     = @($(if ($v) { $v.Reasons | Where-Object { $_ } }))
        Measured    = $false
        Gesture     = $null
        Input       = $null
        Capture     = $null
        Bleed       = $null
        Motion      = $null
        Accounting  = $null
        Frames      = @()
    }
    if ($Result.Gesture) {
        $g = $Result.Gesture
        $rec.Gesture = [ordered]@{ Points = $g.Points; Axis = $g.Axis; Track = $g.Track; CaptureRect = $g.CaptureRect }
    }
    if ($Result.Measure) {
        $m = $Result.Measure
        $in = $m.Input
        if ($in) {
            $rec.Input = [ordered]@{
                Planned = $in.Planned; Sent = $in.Sent; Late = $in.Late
                LatenessP50Us = Get-FrameLabNumber $in.LatenessP50Us
                LatenessP95Us = Get-FrameLabNumber $in.LatenessP95Us
                LatenessMaxUs = Get-FrameLabNumber $in.LatenessMaxUs
                AchievedHz = Get-FrameLabNumber $in.AchievedHz
                HighResolutionTimer = [bool]$in.HighResolutionTimer
                Aborted = [bool]$in.Aborted; AbortReason = $in.AbortReason
            }
        }
        $st = $m.Stats
        $rec.Capture = [ordered]@{
            RefreshHz = $st.RefreshHz
            Frames = $m.Frames; Scored = $m.Scored; Superseded = $m.Superseded
            Captured = $st.Captured; Failing = $st.Failing; Sampled = $st.Sampled
            PngWritten = $st.PngWritten; QueueDropped = $st.QueueDropped
            SlotGaps = $st.SlotGaps; SameSlot = $st.SameSlot
            ScorerErrors = $st.ScorerErrors; FrameErrors = $st.FrameErrors
        }
    }
    $sc = $Result.Score
    if ($sc) {
        $rec.Measured = $true
        $byClass = [ordered]@{}
        foreach ($k in $script:FrameLabBleedClasses) { $byClass[$k] = 0 }
        $frames = @()
        foreach ($f in @($sc.Frames | Where-Object { $_ })) {
            $fs = @()
            foreach ($x in @($f.Findings | Where-Object { $_ })) {
                if ($byClass.Contains([string]$x.Cls)) { $byClass[[string]$x.Cls]++ }
                $fs += [ordered]@{ Cls = [string]$x.Cls; Target = [string]$x.Target; Detail = [string]$x.Detail; Pixels = [int]$x.Pixels; At = Get-FrameLabFindingBox $x.At }
            }
            $frames += [ordered]@{ Index = [long]$f.Index; Png = [string]$f.Png; Findings = $fs }
        }
        $rec.Frames = $frames
        $rec.Bleed = [ordered]@{ Frames = [int]$sc.BleedFrames; FindingsByClass = $byClass }
        $mo = $sc.Motion
        $slotGaps = $(if ($v -and $null -ne $v.SlotGaps) { $v.SlotGaps } elseif ($rec.Capture) { $rec.Capture.SlotGaps } else { $null })
        # SlotGaps sits beside AdvanceRate on purpose (header).
        $rec.Motion = [ordered]@{
            AdvanceRate = Get-FrameLabNumber $(if ($mo) { $mo.AdvanceRate })
            SlotGaps = $slotGaps
            Slots = $(if ($mo) { $mo.Slots }); Due = $(if ($mo) { $mo.Due }); Advanced = $(if ($mo) { $mo.Advanced })
            Stalls = $(if ($mo) { $mo.Stalls }); LongestStall = $(if ($mo) { $mo.LongestStall })
            StepMean = Get-FrameLabNumber $(if ($mo) { $mo.StepMean }); StepStd = Get-FrameLabNumber $(if ($mo) { $mo.StepStd })
            StepMin = Get-FrameLabNumber $(if ($mo) { $mo.StepMin }); StepMax = Get-FrameLabNumber $(if ($mo) { $mo.StepMax })
            MaxCurveDev = Get-FrameLabNumber $(if ($mo) { $mo.MaxCurveDev })
            LagP50 = Get-FrameLabNumber $(if ($mo) { $mo.LagP50 }); LagP95 = Get-FrameLabNumber $(if ($mo) { $mo.LagP95 })
            LagSamples = $(if ($mo) { $mo.LagSamples })
            Reversals = $(if ($mo) { $mo.Reversals }); Unlocated = $(if ($mo) { $mo.Unlocated })
            Misses = @($sc.MotionMisses | Where-Object { $_ })
        }
    }
    if ($Result.Accounting) {
        $a = $Result.Accounting.Account
        $rec.Accounting = $(if ($null -eq $a) {
                [ordered]@{ Ran = $false; InputAborted = [bool]$Result.Accounting.Input.Aborted }
            } else {
                [ordered]@{
                    Ran = $true; Captured = $a.Captured; DdaPresents = $a.DdaPresents; DdaComposed = $a.DdaComposed
                    Matched = $a.Matched; Unmatched = $a.Unmatched; Hidden = $a.Hidden; Skipped = $a.Skipped
                    CaptureOnly = $a.CaptureOnly; Rescued = $a.Rescued
                }
            })
    }
    return [pscustomobject]$rec
}

<#
The run's verdict from its cells' verdicts (header). Pure.
#>
function Resolve-FrameLabRunVerdict([string[]]$CellVerdicts) {
    $v = @($CellVerdicts)
    if ($v -contains 'fail') { return 'fail' }
    if ($v -contains 'incomplete') { return 'incomplete' }
    if ($v -contains 'pass') { return 'pass' }
    return 'no-result'
}

function Get-FrameLabVerdictCounts($Cells) {
    $counts = [ordered]@{}
    foreach ($k in $script:FrameLabCellVerdicts) { $counts[$k] = 0 }
    foreach ($c in @($Cells)) { if ($counts.Contains([string]$c.Verdict)) { $counts[[string]$c.Verdict]++ } }
    return $counts
}

<#
The results object for a run. -Cells are Invoke-FrameLabCell results (or
records already converted). -Commit names the build that was measured.
#>
function New-FrameLabResults {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()][object[]]$Cells,
        [string]$Commit = '',
        [string]$Note = '',
        [datetime]$Generated = (Get-Date)
    )
    $recs = @(foreach ($c in @($Cells | Where-Object { $null -ne $_ })) {
            if ($c.PSObject.Properties['Measured']) { $c } else { ConvertTo-FrameLabCellRecord $c }
        })
    $hz = @($recs | ForEach-Object { if ($_.Capture) { $_.Capture.RefreshHz } } | Where-Object { $_ } | Sort-Object -Unique)
    $byInteraction = [ordered]@{}
    foreach ($r in $recs) {
        if (-not $byInteraction.Contains($r.Interaction)) { $byInteraction[$r.Interaction] = @() }
        $byInteraction[$r.Interaction] += $r.Verdict
    }
    $inter = [ordered]@{}
    foreach ($k in $byInteraction.Keys) {
        $inter[$k] = [ordered]@{ Verdict = Resolve-FrameLabRunVerdict $byInteraction[$k]; Counts = Get-FrameLabVerdictCounts @($recs | Where-Object { $_.Interaction -eq $k }) }
    }
    return [pscustomobject][ordered]@{
        Schema       = $script:FrameLabResultsSchema
        Generated    = $Generated.ToString('yyyy-MM-ddTHH:mm:sszzz')
        Commit       = $Commit
        Note         = $Note
        RefreshHz    = @($hz)
        Verdict      = Resolve-FrameLabRunVerdict @($recs | ForEach-Object { $_.Verdict })
        Counts       = Get-FrameLabVerdictCounts $recs
        Interactions = $inter
        Cells        = @($recs)
    }
}

function Write-FrameLabResults {
    param([Parameter(Mandatory = $true)]$Results, [Parameter(Mandatory = $true)][string]$Path)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Force -Path $dir }
    $json = $Results | ConvertTo-Json -Depth 12
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
    return $Path
}

<#
The harness audit's reader. Returns @{ Ok; Verdict; Problems }: Ok only when
the file parses, carries this schema, every cell has a known verdict, every
measured cell carries both AdvanceRate and SlotGaps, and the recorded run
verdict is the one the cells derive. -Path or -Json.
#>
function Test-FrameLabResults {
    param([string]$Path, [string]$Json)
    $problems = @()
    if ($Path) {
        if (-not (Test-Path -LiteralPath $Path)) { return [pscustomobject]@{ Ok = $false; Verdict = $null; Problems = @("no results file at $Path") } }
        $Json = [System.IO.File]::ReadAllText($Path)
    }
    $r = try { $Json | ConvertFrom-Json } catch { $null }
    if ($null -eq $r) { return [pscustomobject]@{ Ok = $false; Verdict = $null; Problems = @('results do not parse as JSON') } }
    if ($r.Schema -ne $script:FrameLabResultsSchema) { $problems += "schema '$($r.Schema)' is not $script:FrameLabResultsSchema" }
    # PS 5.1: a JSON array of one arrives as the object itself; unroll.
    $cells = @($r.Cells | ForEach-Object { $_ } | Where-Object { $null -ne $_ })
    foreach ($c in $cells) {
        if ([string]$c.Verdict -notin $script:FrameLabCellVerdicts) { $problems += "cell $($c.Id): unknown verdict '$($c.Verdict)'" }
        if ($c.Measured) {
            if ($null -eq $c.Motion -or -not $c.Motion.PSObject.Properties['AdvanceRate']) { $problems += "cell $($c.Id): measured but no AdvanceRate" }
            if ($null -eq $c.Motion -or $null -eq $c.Motion.SlotGaps) { $problems += "cell $($c.Id): measured but no SlotGaps beside AdvanceRate" }
        }
        if ($c.Verdict -eq 'pass' -and -not $c.Measured) { $problems += "cell $($c.Id): pass with nothing measured" }
    }
    $derived = Resolve-FrameLabRunVerdict @($cells | ForEach-Object { [string]$_.Verdict })
    if ([string]$r.Verdict -ne $derived) { $problems += "recorded verdict '$($r.Verdict)' but the cells say '$derived'" }
    return [pscustomobject]@{ Ok = ($problems.Count -eq 0); Verdict = $derived; Problems = @($problems) }
}

<#
The worst frames across the run, worst first: most finding pixels, then the
worst class, then cell id and frame index so the order is stable. Each entry
names its cell. -Max caps the strip.
#>
function Get-FrameLabWorstFrames {
    param([Parameter(Mandatory = $true)]$Results, [int]$Max = 12)
    $all = @()
    foreach ($c in @($Results.Cells | ForEach-Object { $_ })) {
        foreach ($f in @($c.Frames | ForEach-Object { $_ } | Where-Object { $null -ne $_ })) {
            $fs = @($f.Findings | ForEach-Object { $_ } | Where-Object { $null -ne $_ })
            if (-not $fs.Count) { continue }
            $px = 0; $rank = 0
            foreach ($x in $fs) {
                $px += [int]$x.Pixels
                $k = $script:FrameLabClassRank[[string]$x.Cls]; if ($k -gt $rank) { $rank = $k }
            }
            $all += [pscustomobject]@{ CellId = $c.Id; Interaction = $c.Interaction; Index = [long]$f.Index; Png = $f.Png; Findings = $fs; Pixels = $px; Rank = $rank }
        }
    }
    $sorted = @($all | Sort-Object @{ Expression = 'Pixels'; Descending = $true }, @{ Expression = 'Rank'; Descending = $true }, CellId, Index)
    return , @($sorted | Select-Object -First $Max)
}

function ConvertTo-FrameLabHtmlText([string]$s) {
    if ($null -eq $s) { return '' }
    return $s.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
}

function Get-FrameLabPngSize([byte[]]$Bytes) {
    # IHDR: width/height are big-endian at offsets 16 and 20.
    if ($Bytes.Length -lt 24) { return $null }
    $w = ([int]$Bytes[16] -shl 24) -bor ([int]$Bytes[17] -shl 16) -bor ([int]$Bytes[18] -shl 8) -bor [int]$Bytes[19]
    $h = ([int]$Bytes[20] -shl 24) -bor ([int]$Bytes[21] -shl 16) -bor ([int]$Bytes[22] -shl 8) -bor [int]$Bytes[23]
    return @($w, $h)
}

<#
One interaction's chart as inline SVG: a bar per measured cell for its advance
rate (0..1, the 0.98 target drawn), and below it a bar per cell for its longest
stall (refreshes, the 1-refresh target drawn). A bar that misses its target is
drawn in the fail colour.
#>
function New-FrameLabInteractionChart {
    param([Parameter(Mandatory = $true)][object[]]$Cells, [double]$MinAdvanceRate = 0.98, [int]$MaxStall = 1)
    $cells = @($Cells | Where-Object { $_.Measured -and $_.Motion })
    if (-not $cells.Count) { return '<p class="muted">No measured cells.</p>' }
    $n = $cells.Count
    $bw = 18; $gap = 6; $left = 44; $top = 10; $h1 = 120; $h2 = 70; $mid = 28
    # Wide enough for the axis titles and the target labels on the right.
    $w = [math]::Max(260, $left + $n * ($bw + $gap) + 40)
    $stallMax = [math]::Max(4, (@($cells | ForEach-Object { [int]$_.Motion.LongestStall }) | Measure-Object -Maximum).Maximum)
    $y2 = $top + $h1 + $mid
    $total = $y2 + $h2 + 24
    $sb = New-Object System.Text.StringBuilder
    $null = $sb.Append("<svg class=""chart"" viewBox=""0 0 $w $total"" width=""$w"" height=""$total"" role=""img"" aria-label=""advance rate and longest stall per cell"">")
    # Axes and targets.
    $ty = $top + $h1 * (1 - $MinAdvanceRate)
    $null = $sb.Append("<text x=""4"" y=""$($top + 8)"" class=""ax"">1.0</text><text x=""4"" y=""$($top + $h1)"" class=""ax"">0</text>")
    $null = $sb.Append("<text x=""$left"" y=""$($top - 1)"" class=""ax"">advance rate</text>")
    $null = $sb.Append("<line x1=""$left"" x2=""$($w - 30)"" y1=""$ty"" y2=""$ty"" class=""target""/><text x=""$($w - 28)"" y=""$([math]::Round($ty + 3,1))"" class=""ax"">$MinAdvanceRate</text>")
    $sy = $y2 + $h2 - $h2 * $MaxStall / $stallMax
    $null = $sb.Append("<text x=""$left"" y=""$($y2 - 3)"" class=""ax"">longest stall (refreshes)</text><text x=""4"" y=""$($y2 + 8)"" class=""ax"">$stallMax</text><text x=""4"" y=""$($y2 + $h2)"" class=""ax"">0</text>")
    $null = $sb.Append("<line x1=""$left"" x2=""$($w - 30)"" y1=""$([math]::Round($sy,1))"" y2=""$([math]::Round($sy,1))"" class=""target""/><text x=""$($w - 28)"" y=""$([math]::Round($sy + 3,1))"" class=""ax"">$MaxStall</text>")
    $i = 0
    foreach ($c in $cells) {
        $x = $left + $i * ($bw + $gap)
        $ar = $c.Motion.AdvanceRate
        $title = ConvertTo-FrameLabHtmlText ("{0}: advance {1} slot gaps {2} longest stall {3} verdict {4}" -f $c.Id, $(if ($null -eq $ar) { 'n/a' } else { '{0:0.000}' -f $ar }), $c.Motion.SlotGaps, $c.Motion.LongestStall, $c.Verdict)
        if ($null -ne $ar) {
            # Double literals: [math]::Max(0, 0.41) binds the int overload and
            # truncates the rate to 0.
            $bh = [math]::Round($h1 * [math]::Min(1.0, [math]::Max(0.0, [double]$ar)), 1)
            $cls = $(if ($ar -lt $MinAdvanceRate) { 'bar miss' } else { 'bar ok' })
            $null = $sb.Append("<rect x=""$x"" y=""$($top + $h1 - $bh)"" width=""$bw"" height=""$bh"" class=""$cls""><title>$title</title></rect>")
        }
        $ls = [int]$c.Motion.LongestStall
        $sh = [math]::Round($h2 * [math]::Min($stallMax, $ls) / $stallMax, 1)
        $cls2 = $(if ($ls -gt $MaxStall) { 'bar miss' } else { 'bar ok' })
        $null = $sb.Append("<rect x=""$x"" y=""$($y2 + $h2 - $sh)"" width=""$bw"" height=""$sh"" class=""$cls2""><title>$title</title></rect>")
        $null = $sb.Append("<text x=""$($x + $bw / 2)"" y=""$($y2 + $h2 + 12)"" class=""ax mid"">$($i + 1)</text>")
        $i++
    }
    $null = $sb.Append('</svg>')
    return $sb.ToString()
}

<#
The HTML report for a results object. -PngRoot resolves relative Png paths.
-MaxFrames caps the filmstrip. Returns the HTML; -Path also writes it.
#>
function New-FrameLabReportHtml {
    param(
        [Parameter(Mandatory = $true)]$Results,
        [string]$Path,
        [string]$PngRoot,
        [int]$MaxFrames = 12
    )
    $enc = { param($s) ConvertTo-FrameLabHtmlText ([string]$s) }
    $cells = @($Results.Cells | ForEach-Object { $_ })
    $sb = New-Object System.Text.StringBuilder
    $null = $sb.Append(@'
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Frame lab report</title>
<style>
:root { --bg:#fbfbfa; --fg:#1c1c1a; --muted:#6f6e69; --line:#dcdbd6; --ok:#2f8f5b; --miss:#d1453b; --warn:#c27c0e; --card:#ffffff; }
@media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) { --bg:#161615; --fg:#ecebe7; --muted:#9a9993; --line:#33332f; --ok:#4cc38a; --miss:#ff6b5e; --warn:#f0b45a; --card:#1f1f1d; } }
:root[data-theme="dark"] { --bg:#161615; --fg:#ecebe7; --muted:#9a9993; --line:#33332f; --ok:#4cc38a; --miss:#ff6b5e; --warn:#f0b45a; --card:#1f1f1d; }
body { background:var(--bg); color:var(--fg); font:14px/1.5 "Segoe UI", system-ui, sans-serif; margin:0; padding:24px 16px; }
main { max-width:1100px; margin:0 auto; }
h1 { font-size:24px; margin:0 0 4px; } h2 { font-size:18px; margin:28px 0 8px; } h3 { font-size:15px; margin:18px 0 6px; }
.muted { color:var(--muted); } .tiles { display:flex; flex-wrap:wrap; gap:8px; margin:12px 0; }
.tile { background:var(--card); border:1px solid var(--line); border-radius:6px; padding:8px 12px; min-width:84px; }
.tile b { display:block; font-size:20px; }
.v-pass { color:var(--ok); } .v-fail { color:var(--miss); } .v-incomplete, .v-no-result { color:var(--warn); } .v-blocked, .v-skipped, .v-aborted { color:var(--muted); }
.chart { max-width:100%; height:auto; } .chart .ax { font-size:9px; fill:var(--muted); } .chart .mid { text-anchor:middle; }
.chart .target { stroke:var(--fg); stroke-dasharray:3 3; stroke-width:1; opacity:.6; }
.bar.ok { fill:var(--ok); } .bar.miss { fill:var(--miss); }
.scroll { overflow-x:auto; } table { border-collapse:collapse; font-size:12px; } td, th { border-bottom:1px solid var(--line); padding:3px 8px; text-align:left; white-space:nowrap; }
.strip { display:flex; flex-wrap:wrap; gap:12px; } figure { margin:0; background:var(--card); border:1px solid var(--line); border-radius:6px; padding:8px; max-width:100%; }
figure svg { max-width:100%; height:auto; display:block; } figcaption { font-size:12px; margin-top:6px; max-width:520px; }
.find { fill:none; stroke-width:2; }
</style></head><body><main>
'@)
    $v = [string]$Results.Verdict
    $null = $sb.Append("<h1>Frame lab report</h1><p class=""muted"">Build $(& $enc $Results.Commit) - generated $(& $enc $Results.Generated) - refresh $(& $enc (@($Results.RefreshHz) -join '/')) Hz$(if ($Results.Note) { ' - ' + (& $enc $Results.Note) })</p>")
    $null = $sb.Append("<div class=""tiles""><div class=""tile""><span class=""muted"">verdict</span><b class=""v-$v"">$v</b></div>")
    foreach ($p in $Results.Counts.PSObject.Properties) {
        $null = $sb.Append("<div class=""tile""><span class=""muted"">$($p.Name)</span><b class=""v-$($p.Name)"">$($p.Value)</b></div>")
    }
    $null = $sb.Append('</div>')

    $null = $sb.Append('<h2>Motion per interaction</h2><p class="muted">Each bar is one measured cell (numbered in the table below it). Top: share of due refreshes that showed new motion, target 0.98. Bottom: longest run of refreshes with no motion, target 1. Red misses the target.</p>')
    $names = @($cells | ForEach-Object { $_.Interaction } | Select-Object -Unique)
    foreach ($name in $names) {
        $ic = @($cells | Where-Object { $_.Interaction -eq $name })
        $iv = Resolve-FrameLabRunVerdict @($ic | ForEach-Object { [string]$_.Verdict })
        $null = $sb.Append("<h3>$(& $enc $name) <span class=""v-$iv"">$iv</span></h3>")
        $measured = @($ic | Where-Object { $_.Measured -and $_.Motion })
        $null = $sb.Append('<div class="scroll">' + (New-FrameLabInteractionChart -Cells $ic) + '</div>')
        $null = $sb.Append('<div class="scroll"><table><tr><th>#</th><th>cell</th><th>verdict</th><th>advance</th><th>slot gaps</th><th>stalls</th><th>longest</th><th>lag p95</th><th>reversals</th><th>bleed frames</th><th>skipped (acct)</th><th>reasons</th></tr>')
        $k = 0
        foreach ($c in $ic) {
            $num = ''
            if ($c.Measured -and $c.Motion) { $k++; $num = $k }
            $m = $c.Motion
            $fmt = { param($x, $f) if ($null -eq $x) { '' } else { $f -f $x } }
            $acct = $(if ($c.Accounting -and $c.Accounting.Ran) { $c.Accounting.Skipped } elseif ($c.Accounting) { 'not run' } else { '' })
            $null = $sb.Append("<tr><td>$num</td><td>$(& $enc $c.Id)</td><td class=""v-$($c.Verdict)"">$($c.Verdict)</td><td>$(& $fmt $m.AdvanceRate '{0:0.000}')</td><td>$(& $fmt $m.SlotGaps '{0}')</td><td>$(& $fmt $m.Stalls '{0}')</td><td>$(& $fmt $m.LongestStall '{0}')</td><td>$(& $fmt $m.LagP95 '{0:0.##}')</td><td>$(& $fmt $m.Reversals '{0}')</td><td>$(if ($c.Bleed) { $c.Bleed.Frames })</td><td>$acct</td><td>$(& $enc (@($c.Reasons) -join '; '))</td></tr>")
        }
        $null = $sb.Append('</table></div>')
    }

    $null = $sb.Append('<h2>Worst frames</h2>')
    $worst = Get-FrameLabWorstFrames -Results $Results -Max $MaxFrames
    if (-not $worst.Count) {
        $null = $sb.Append('<p class="muted">No frame carried a finding.</p>')
    } else {
        $null = $sb.Append('<p class="muted">Ranked by failing pixels. Each box outlines one finding, coloured by class: ')
        foreach ($k in $script:FrameLabBleedClasses) { $null = $sb.Append("<span style=""color:$($script:FrameLabClassColour[$k])"">$k</span> ") }
        $null = $sb.Append('</p><div class="strip">')
        foreach ($f in $worst) {
            $png = [string]$f.Png
            if ($png -and $PngRoot -and -not [System.IO.Path]::IsPathRooted($png)) { $png = Join-Path $PngRoot $png }
            $bytes = $null
            if ($png -and (Test-Path -LiteralPath $png)) { $bytes = [System.IO.File]::ReadAllBytes($png) }
            $size = $(if ($bytes) { Get-FrameLabPngSize $bytes })
            if (-not $size) {
                # No image: size the canvas to the findings so the boxes still show where.
                $mx = 1; $my = 1
                foreach ($x in $f.Findings) { if ($x.At) { $mx = [math]::Max($mx, [int]$x.At.X1); $my = [math]::Max($my, [int]$x.At.Y1) } }
                $size = @($mx, $my)
            }
            $null = $sb.Append("<figure><svg viewBox=""0 0 $($size[0]) $($size[1])"" width=""$([math]::Min(520, $size[0]))"">")
            if ($bytes) {
                $null = $sb.Append("<image href=""data:image/png;base64,$([Convert]::ToBase64String($bytes))"" x=""0"" y=""0"" width=""$($size[0])"" height=""$($size[1])""/>")
            } else {
                $null = $sb.Append("<rect width=""$($size[0])"" height=""$($size[1])"" fill=""none"" stroke=""currentColor"" stroke-dasharray=""4 4""/>")
            }
            foreach ($x in $f.Findings) {
                if (-not $x.At) { continue }
                $col = $script:FrameLabClassColour[[string]$x.Cls]; if (-not $col) { $col = '#888888' }
                $bw = [math]::Max(1, [int]$x.At.X1 - [int]$x.At.X0); $bh = [math]::Max(1, [int]$x.At.Y1 - [int]$x.At.Y0)
                $null = $sb.Append("<rect class=""find"" x=""$($x.At.X0)"" y=""$($x.At.Y0)"" width=""$bw"" height=""$bh"" stroke=""$col""><title>$(& $enc ('{0} {1}: {2}' -f $x.Cls, $x.Target, $x.Detail))</title></rect>")
            }
            $null = $sb.Append('</svg><figcaption>')
            $null = $sb.Append("<b>$(& $enc $f.CellId)</b> frame #$($f.Index) - $($f.Pixels) px$(if (-not $bytes) { ' - <span class=""muted"">image not found</span>' })<br>")
            $null = $sb.Append((@($f.Findings | ForEach-Object { "<span style=""color:$($script:FrameLabClassColour[[string]$_.Cls])"">$($_.Cls)</span> " + (& $enc ("{0}: {1}" -f $_.Target, $_.Detail)) }) -join '<br>'))
            $null = $sb.Append('</figcaption></figure>')
        }
        $null = $sb.Append('</div>')
    }
    $null = $sb.Append('</main></body></html>')
    $html = $sb.ToString()
    if ($Path) {
        $dir = Split-Path -Parent $Path
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Force -Path $dir }
        [System.IO.File]::WriteAllText($Path, $html, (New-Object System.Text.UTF8Encoding($false)))
    }
    return $html
}
