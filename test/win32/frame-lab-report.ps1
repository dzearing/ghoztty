<#
.SYNOPSIS
  Acceptance test for test\win32\lib\FrameLabReport.ps1 (T2390) - the T2373
  frame lab's results JSON and HTML report.

.DESCRIPTION
  The report is what a person reads and what a gate trusts, so it is proved on
  cells made by the real protocol (Invoke-FrameLabCell, T2389) against a fake
  driver - no window, no screen, no pointer:

    A. a cell record carries its knobs, verdict and reasons, every metric, and
       SlotGaps BESIDE AdvanceRate; NaN metrics become null (JSON has no NaN);
       findings are counted by class; the accounting run and the input timing
       ride along; a blocked or skipped cell is a record with nothing measured;
    B. the run verdict is derived from the cells - fail > incomplete > pass,
       and a run that measured nothing is no-result, never pass;
    C. the JSON round-trips and the harness audit's reader refuses a file whose
       verdict disagrees with its cells, a measured cell missing SlotGaps, an
       unknown verdict, a pass with nothing measured, and a missing file - and
       reads a one-cell file (PS 5.1 unrolls a one-element array);
    D. the HTML: a chart per interaction with an under-target bar drawn as a
       miss, the per-cell table, a filmstrip ranked worst first with the PNG
       embedded and each finding outlined at its own coordinates in its class
       colour, text escaped, and a frame whose PNG is gone still shown;
    E. negative control - an all-pass run draws no miss bar and no filmstrip.

  ASCII-only by design (PS 5.1 on this box mangles non-ASCII on rewrite).

  powershell -NoProfile -File test\win32\frame-lab-report.ps1
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
. (Join-Path $PSScriptRoot 'lib\FrameLabReport.ps1')
Add-Type -AssemblyName System.Drawing

$geo = @{
    Window  = @{ X = 400; Y = 200; W = 1200; H = 800 }
    Monitor = @{ X = 0; Y = 0; W = 2560; H = 1400 }
    Caption = 215
    Divider = @{ X = 1100; Y0 = 260; Y1 = 990 }
    Sidebar = @{ EdgeX = 660; Y0 = 260; Y1 = 990 }
}

$work = Join-Path $env:TEMP ("frame-lab-report-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Force -Path $work

Reset-TestBody
try {
    # A 40x30 PNG with a magenta block where the B1 finding says it is.
    $png = Join-Path $work 'f000007-fail.png'
    $bmp = New-Object System.Drawing.Bitmap 40, 30
    $gfx = [System.Drawing.Graphics]::FromImage($bmp)
    $gfx.Clear([System.Drawing.Color]::FromArgb(30, 60, 90))
    $gfx.FillRectangle([System.Drawing.Brushes]::Magenta, 10, 5, 8, 6)
    $gfx.Dispose(); $bmp.Save($png, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()

    function New-Motion([double]$Rate, [int]$Longest, [double]$LagP95 = 1.5) {
        [pscustomobject]@{
            Slots = 240; Due = 200; Advanced = [int](200 * $Rate); AdvanceRate = $Rate
            Stalls = $(if ($Longest -ge 2) { 1 } else { 0 }); LongestStall = $Longest
            StepMean = 4.0; StepStd = 0.5; StepMin = 3.0; StepMax = 5.0; MaxCurveDev = [double]::NaN
            LagP50 = 1.0; LagP95 = $LagP95; LagSamples = 180; Reversals = 0; Unlocated = 0
        }
    }

    # A fake driver whose Score returns whatever the cell should show.
    function New-FakeDriver([hashtable]$Opt = @{}) {
        $scene = $geo
        $d = @{}
        $d.Presence = { [pscustomobject]@{ Present = [bool]$Opt.Present; Reason = $(if ($Opt.Present) { 'input 2s ago' } else { 'idle 900s' }) } }.GetNewClosure()
        $d.Launch = { param($Cell) @{ Geometry = $scene; Close = {} } }.GetNewClosure()
        $d.StartCapture = { param($Rect, $Dup) @{ Dup = $Dup } }
        $d.Play = {
            param($Path)
            [pscustomobject]@{ Skipped = $false; SkipReason = ''; Aborted = $false; AbortReason = ''
                Planned = $Path.Length; Sent = $Path.Length; Late = 2; LatenessP50Us = 40.0; LatenessP95Us = 180.0
                LatenessMaxUs = 900.0; AchievedHz = 999.2; HighResolutionTimer = $true }
        }
        $d.StopCapture = {
            param($S)
            $tl = @([pscustomobject]@{ Index = 0; Superseded = $false }, [pscustomobject]@{ Index = 1; Superseded = $true }, [pscustomobject]@{ Index = 2; Superseded = $false })
            $acct = $(if ($S.Dup) { [pscustomobject]@{ Captured = 300; DdaPresents = 300; DdaComposed = 300; Matched = 300 - [int]$Opt.Skipped; Unmatched = [int]$Opt.Skipped; Hidden = 0; Skipped = [long]$Opt.Skipped; CaptureOnly = 0; Rescued = 0 } })
            @{ Stats = [pscustomobject]@{ RefreshHz = 120; Captured = 3; Failing = [int]$Opt.Bleed; Sampled = 1; PngWritten = 1; QueueDropped = 0; SlotGaps = [long]$Opt.SlotGaps; SameSlot = 1; ScorerErrors = 0; FrameErrors = 0 }
                Account = $acct; Timeline = $tl }
        }.GetNewClosure()
        $d.Score = {
            param($Cap, $Frames, $G, $Played)
            $m = $Opt.Motion
            # FrameScore's Test-FrameMotionTargets takes an FsMotion; the fakes
            # are plain objects, so the two targets the chart draws are checked
            # inline (a closure cannot see this script's functions).
            $miss = @()
            if ($m -and $m.AdvanceRate -lt 0.98) { $miss += ('advance rate {0:0.000} < 0.98' -f $m.AdvanceRate) }
            if ($m -and $m.LongestStall -gt 1) { $miss += ('longest stall {0} refreshes > 1' -f $m.LongestStall) }
            @{ BleedFrames = [int]$Opt.Bleed; Motion = $m; MotionMisses = $miss; Frames = $Opt.Frames }
        }.GetNewClosure()
        return $d
    }

    function Get-Cell([string]$Interaction, [int]$Panes = 4, [int]$Stall = 0) {
        Get-FrameLabMatrix -Interaction $Interaction -Panes $Panes -Theme flat -Dpi 100 -Sidebar hidden -StallMs $Stall
    }

    $b1 = @{ Index = 7; Png = 'f000007-fail.png'; Findings = @(@{ Cls = 'B1'; Target = 'pane2'; Detail = 'flash <magenta> & desk'; Pixels = 48; At = @{ X0 = 10; Y0 = 5; X1 = 18; Y1 = 11 } }) }
    $b2 = @{ Index = 9; Png = 'gone.png'; Findings = @(@{ Cls = 'B2'; Target = 'pane1'; Detail = 'ring inset 3px right'; Pixels = 20; At = @{ X0 = 2; Y0 = 2; X1 = 30; Y1 = 4 } }, @{ Cls = 'B6'; Target = 'pane1'; Detail = 'garbage'; Pixels = 1; At = @{ X0 = 0; Y0 = 0; X1 = 1; Y1 = 1 } }) }
    $b3 = @{ Index = 3; Png = ''; Findings = @(@{ Cls = 'B3'; Target = 'pane3'; Detail = 'ring 2px thick'; Pixels = 5; At = @{ X0 = 1; Y0 = 1; X1 = 3; Y1 = 3 } }) }

    $rPass = Invoke-FrameLabCell -Cell (Get-Cell frame-right 1) -Driver (New-FakeDriver @{ Motion = (New-Motion 0.995 1); SlotGaps = 2 })
    $rFail = Invoke-FrameLabCell -Cell (Get-Cell divider) -Driver (New-FakeDriver @{ Motion = (New-Motion 0.41 6 ([double]::NaN)); Bleed = 2; Frames = @($b1, $b2); SlotGaps = 17 })
    $rFail2 = Invoke-FrameLabCell -Cell (Get-Cell frame-right 4) -Driver (New-FakeDriver @{ Motion = (New-Motion 0.99 1); Bleed = 1; Frames = @($b3) })
    $rInc = Invoke-FrameLabCell -Cell (Get-Cell frame-bottom 1) -Driver (New-FakeDriver @{ Motion = (New-Motion 0.99 1); Skipped = 4 })
    $rBlocked = Invoke-FrameLabCell -Cell (Get-Cell frame-right 1 50) -Driver (New-FakeDriver @{})
    $rSkip = Invoke-FrameLabCell -Cell (Get-Cell frame-bottom 4) -Driver (New-FakeDriver @{ Present = $true })

    # ---- A. records --------------------------------------------------------------
    'A. cell records'
    Assert 'A0 the fakes produce the verdicts the sections rely on' `
        ("$($rPass.Verdict.Verdict),$($rFail.Verdict.Verdict),$($rFail2.Verdict.Verdict),$($rInc.Verdict.Verdict),$($rBlocked.Verdict.Verdict),$($rSkip.Verdict.Verdict)" -eq 'pass,fail,fail,incomplete,blocked,skipped') `
        "$($rPass.Verdict.Verdict),$($rFail.Verdict.Verdict),$($rFail2.Verdict.Verdict),$($rInc.Verdict.Verdict),$($rBlocked.Verdict.Verdict),$($rSkip.Verdict.Verdict)"
    $p = ConvertTo-FrameLabCellRecord $rPass
    Assert 'A1 knobs and verdict carried' ($p.Id -eq $rPass.Id -and $p.Interaction -eq 'frame-right' -and $p.Panes -eq 1 -and $p.Theme -eq 'flat' -and $p.Dpi -eq 100 -and $p.StallMs -eq 0 -and $p.Verdict -eq 'pass' -and $p.Measured)
    $keys = @($p.Motion.Keys)
    Assert 'A2 SlotGaps sits beside AdvanceRate, from the measurement run' ($keys[0] -eq 'AdvanceRate' -and $keys[1] -eq 'SlotGaps' -and $p.Motion.SlotGaps -eq 2 -and $p.Motion.AdvanceRate -eq 0.995) ($keys -join ',')
    Assert 'A3 every motion metric is in the record' (@('Slots', 'Due', 'Advanced', 'Stalls', 'LongestStall', 'StepMean', 'StepStd', 'StepMin', 'StepMax', 'MaxCurveDev', 'LagP50', 'LagP95', 'LagSamples', 'Reversals', 'Unlocated', 'Misses' | Where-Object { $_ -notin $keys }).Count -eq 0)
    Assert 'A4 a NaN metric is null, not NaN' ($null -eq $p.Motion.MaxCurveDev -and $null -eq (ConvertTo-FrameLabCellRecord $rFail).Motion.LagP95)
    Assert 'A5 input timing and capture counts carried' ($p.Input.Sent -gt 0 -and $p.Input.LatenessP95Us -eq 180 -and $p.Input.HighResolutionTimer -and $p.Capture.RefreshHz -eq 120 -and $p.Capture.Superseded -eq 1 -and $p.Capture.Scored -eq 2)
    Assert 'A6 the accounting run carried' ($p.Accounting.Ran -and $p.Accounting.Skipped -eq 0 -and $p.Accounting.Matched -eq 300)
    $f = ConvertTo-FrameLabCellRecord $rFail
    Assert 'A7 findings counted by class, every class present' ($f.Bleed.Frames -eq 2 -and $f.Bleed.FindingsByClass.B1 -eq 1 -and $f.Bleed.FindingsByClass.B2 -eq 1 -and $f.Bleed.FindingsByClass.B6 -eq 1 -and $f.Bleed.FindingsByClass.B4 -eq 0 -and @($f.Bleed.FindingsByClass.Keys).Count -eq 6)
    Assert 'A8 the motion misses and the verdict reasons are carried' (@($f.Motion.Misses).Count -eq 2 -and (@($f.Reasons) -join ';') -match 'bleed frame')
    $bk = ConvertTo-FrameLabCellRecord $rBlocked
    $sk = ConvertTo-FrameLabCellRecord $rSkip
    Assert 'A9 blocked and skipped cells are records with nothing measured' ($bk.Verdict -eq 'blocked' -and -not $bk.Measured -and $null -eq $bk.Motion -and $bk.Reasons[0] -match 'T2360' -and $sk.Verdict -eq 'skipped' -and -not $sk.Measured -and $sk.Reasons[0] -match 'input 2s ago')

    # ---- B. run verdict ----------------------------------------------------------
    'B. run verdict'
    Assert 'B1 fail outranks everything' ((Resolve-FrameLabRunVerdict @('pass', 'incomplete', 'fail', 'blocked')) -eq 'fail')
    Assert 'B2 incomplete outranks pass' ((Resolve-FrameLabRunVerdict @('pass', 'incomplete')) -eq 'incomplete')
    Assert 'B3 pass needs a pass' ((Resolve-FrameLabRunVerdict @('pass', 'blocked', 'skipped')) -eq 'pass')
    Assert 'B4 a run that measured nothing is no-result, never pass' ((Resolve-FrameLabRunVerdict @('blocked', 'skipped', 'aborted')) -eq 'no-result' -and (Resolve-FrameLabRunVerdict @()) -eq 'no-result')
    $res = New-FrameLabResults -Cells @($rPass, $rFail, $rFail2, $rInc, $rBlocked, $rSkip) -Commit 'abc1234' -Note 'fake run'
    Assert 'B5 the results derive their own verdict and counts' ($res.Verdict -eq 'fail' -and $res.Counts.pass -eq 1 -and $res.Counts.fail -eq 2 -and $res.Counts.incomplete -eq 1 -and $res.Counts.blocked -eq 1 -and $res.Counts.skipped -eq 1 -and $res.Schema -eq 'ghoztty-frame-lab-results/1')
    Assert 'B6 per-interaction verdicts' ($res.Interactions['divider'].Verdict -eq 'fail' -and $res.Interactions['frame-bottom'].Verdict -eq 'incomplete' -and $res.Interactions['frame-right'].Verdict -eq 'fail')
    Assert 'B7 refresh rate recorded from the capture' ((@($res.RefreshHz) -join ',') -eq '120')

    # ---- C. JSON round trip and the audit reader -----------------------------------
    'C. results JSON'
    $jp = Join-Path $work 'results.json'
    $null = Write-FrameLabResults -Results $res -Path $jp
    $raw = [System.IO.File]::ReadAllText($jp)
    $t = Test-FrameLabResults -Path $jp
    Assert 'C1 the written file passes the audit reader, verdict re-derived' ($t.Ok -and $t.Verdict -eq 'fail') (@($t.Problems) -join '; ')
    Assert 'C2 no NaN in the JSON and no BOM' ($raw -notmatch 'NaN' -and [int][char]$raw[0] -ne 0xFEFF)
    $o = $raw | ConvertFrom-Json
    $o.Verdict = 'pass'
    $t2 = Test-FrameLabResults -Json ($o | ConvertTo-Json -Depth 12)
    Assert 'C3 a verdict that disagrees with its cells is refused' (-not $t2.Ok -and (@($t2.Problems) -join ';') -match "cells say 'fail'")
    $o = $raw | ConvertFrom-Json
    $o.Cells[0].Motion.SlotGaps = $null
    $t3 = Test-FrameLabResults -Json ($o | ConvertTo-Json -Depth 12)
    Assert 'C4 a measured cell without SlotGaps is refused' (-not $t3.Ok -and (@($t3.Problems) -join ';') -match 'no SlotGaps')
    $o = $raw | ConvertFrom-Json
    $o.Cells[4].Verdict = 'green'
    $t4 = Test-FrameLabResults -Json ($o | ConvertTo-Json -Depth 12)
    Assert 'C5 an unknown cell verdict is refused' (-not $t4.Ok -and (@($t4.Problems) -join ';') -match "unknown verdict 'green'")
    $o = $raw | ConvertFrom-Json
    $o.Cells[4].Verdict = 'pass'
    $t5 = Test-FrameLabResults -Json ($o | ConvertTo-Json -Depth 12)
    Assert 'C6 a pass with nothing measured is refused' (-not $t5.Ok -and (@($t5.Problems) -join ';') -match 'pass with nothing measured')
    $t6 = Test-FrameLabResults -Path (Join-Path $work 'nope.json')
    Assert 'C7 a missing file is refused' (-not $t6.Ok -and $t6.Problems[0] -match 'no results file')
    $one = New-FrameLabResults -Cells @($rPass) -Commit 'abc1234'
    $op = Join-Path $work 'one.json'
    $null = Write-FrameLabResults -Results $one -Path $op
    $t7 = Test-FrameLabResults -Path $op
    Assert 'C8 a one-cell file reads (PS 5.1 unroll) and passes' ($t7.Ok -and $t7.Verdict -eq 'pass') (@($t7.Problems) -join '; ')
    $t8 = Test-FrameLabResults -Json 'not json {'
    Assert 'C9 garbage is refused' (-not $t8.Ok)
    $empty = New-FrameLabResults -Cells $null
    Assert 'C11 an empty cell list (a function return arriving as $null) is no-result, not an error' ($empty.Verdict -eq 'no-result' -and @($empty.Cells).Count -eq 0)
    $none = New-FrameLabResults -Cells @($rBlocked, $rSkip)
    Assert 'C10 a run of only blocked/skipped cells reads no-result' ($none.Verdict -eq 'no-result' -and (Test-FrameLabResults -Json ($none | ConvertTo-Json -Depth 12)).Verdict -eq 'no-result')

    # ---- D. HTML -----------------------------------------------------------------
    'D. HTML report'
    $back = $raw | ConvertFrom-Json
    $hp = Join-Path $work 'report.html'
    $html = New-FrameLabReportHtml -Results $back -Path $hp -PngRoot $work
    Assert 'D1 written, titled, verdict and build shown' ((Test-Path $hp) -and $html -match '<title>Frame lab report</title>' -and $html -match 'class="v-fail">fail<' -and $html -match 'abc1234')
    Assert 'D2 one chart per interaction measured' (([regex]::Matches($html, '<svg class="chart"')).Count -eq 3 -and $html -match '<h3>divider ' -and $html -match '<h3>frame-bottom ')
    Assert 'D3 an under-target advance rate and a long stall are drawn as misses' ($html -match 'class="bar miss"><title>divider/p4[^<]*advance 0\.410')
    # Heights are 120 * rate: a rate under 1 must not be truncated to 0 or rounded to a full bar.
    Assert 'D3b advance bars are drawn to scale (0.41 -> 49.2, 0.995 -> 119.4)' `
        ($html -match 'height="49\.2" class="bar miss"><title>divider' -and $html -match 'height="119\.4" class="bar ok"><title>frame-right/p1')
    Assert 'D4 SlotGaps is a column beside advance in the table' ($html -match '<th>advance</th><th>slot gaps</th>' -and $html -match '<td>0\.410</td><td>17</td>')
    $worst = Get-FrameLabWorstFrames -Results $back
    Assert 'D5 the filmstrip is ranked worst first' (($worst | ForEach-Object { $_.Index }) -join ',' -eq '7,9,3') (($worst | ForEach-Object { "$($_.Index):$($_.Pixels)" }) -join ',')
    Assert 'D6 the PNG is embedded, not linked' ($html -match 'href="data:image/png;base64,' -and $html -match 'viewBox="0 0 40 30"')
    Assert 'D7 the B1 finding is outlined at its own box in its class colour' ($html -match '<rect class="find" x="10" y="5" width="8" height="6" stroke="#e5484d">')
    Assert 'D8 finding text is escaped' ($html -match 'flash &lt;magenta&gt; &amp; desk' -and $html -notmatch 'flash <magenta>')
    Assert 'D9 a frame whose PNG is gone is still shown, and says so' ($html -match 'frame #9 - 21 px - <span class="muted">image not found' -and $html -match 'viewBox="0 0 30 4"')
    $cap = (Get-FrameLabWorstFrames -Results $back -Max 1)
    Assert 'D10 -Max caps the strip' ($cap.Count -eq 1 -and $cap[0].Index -eq 7)
    Assert 'D11 dark mode tokens and a body background' ($html -match 'prefers-color-scheme: dark' -and $html -match 'body \{ background:var\(--bg\)')

    # ---- E. negative control -------------------------------------------------------
    'E. negative control'
    $clean = New-FrameLabResults -Cells @($rPass, $rBlocked) -Commit 'abc1234'
    $ch = New-FrameLabReportHtml -Results (($clean | ConvertTo-Json -Depth 12) | ConvertFrom-Json)
    Assert 'E1 an all-pass run reads pass, draws no miss bar and no filmstrip' ($clean.Verdict -eq 'pass' -and $ch -notmatch 'bar miss' -and $ch -match 'No frame carried a finding' -and $ch -match 'class="bar ok"')

    Complete-TestBody
}
catch {
    "  FAIL unexpected: $($_.Exception.Message) at $($_.InvocationInfo.PositionMessage) $($_.ScriptStackTrace)"
    $script:failures++
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

# A green run stamps the covered files (T783); red or skipped stays due.
if ($script:failures -eq 0 -and $script:skipped -eq 0) {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard frame-lab-report -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

''
Write-TestVerdict -Label 'T2390 FRAME-LAB-REPORT' -Pass $script:passes -Fail $script:failures -Skipped $script:skipped
