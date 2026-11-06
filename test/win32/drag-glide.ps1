# @timing-sensitive - it measures wall-clock cost, so it runs with nothing beside it (scripts/acceptance-parallel.ps1, T1960).
# T2451 acceptance: what the FOLD GLIDE costs under a divider drag, on a row
# with a viewer pane in it - the shape the user reported stepping at 10-15 fps
# (T2448, release 1.49.6).
#
# THE MECHANISM, because it decides what is asserted. Dragging a divider past a
# pane's minimum folds panes into strips (T2124), and the fold animates: a
# glide driven by the window's FrameClock, one layout pass per display frame.
# The mouse moves of the drag keep arriving while it runs. Before T2448 every
# glide frame was paid two or three times over - the glide's own pass, the
# window's WM_PAINT recomposing the identical elevated desk, and each mouse
# move's full `layoutSplitsLive` queued in between - so frames landed 60-100 ms
# apart. T2448 fixed the multiplier three ways, and those three are what this
# script holds in place:
#
#   1. a divider motion tick under a running glide DEFERS its layout to the
#      glide's next frame (`deferred_moves` counts them);
#   2. the layout pass validates the desk rect it just painted through GetDC,
#      so the window takes ~no WM_PAINT during the glide (`wm_paints`; it was
#      one per glide frame - 238 for 240 ticks);
#   3. the PaneDesk memo blits the cached composite when a compose's inputs are
#      unchanged (`desk_reused`), or recomposes only the cards that moved
#      (`desk_partial`, T2454).
#
# THE ORACLE. Under GHOZTTY_PERF the app prints, at WM_LBUTTONUP:
#
#   divider drag ticks=.. (the drag cost line drag-perf.ps1 reads)
#   divider drag viewers=.. mean_viewer_us=.. mean_viewer_nav_us=..
#               mean_viewer_bounds_us=.. mean_viewer_toc_us=.. mean_us=..
#   divider glide ticks=.. mean_us=.. max_us=.. mean_gap_us=.. max_gap_us=..
#               late=.. fps=.. viewer_ticks=.. viewer_us=.. period_us=..
#               deferred_moves=.. wm_paints=.. wm_paint_us=.. desk_composed=..
#               desk_reused=.. desk_partial=.. ... verdict=..
#
# (`Window.reportDragCost` / `reportGlideCost`; the arithmetic is
# `drag_perf.GlideStats`, unit-tested in every lane.)
#
# THE SCENE (T2448's measurement, made repeatable): a 1600x900 window, a row of
# five equal panes with a viewer SECOND, and the first divider - terminal |
# viewer - dragged -TravelPx out and back in -StepPx steps -TickMs apart, with
# posted mouse messages on the background test desktop. 720 px out folds the
# viewer and the panes beyond it; coming back unfolds them, so the drag runs
# glides both ways.
#
# WHAT IS ASSERTED - the COUNTS, which are properties of the code. The clock
# (gaps, late frames, fps) is a property of the box and is REPORTED only; a
# perf harness that fails on noise gets disabled rather than believed:
#   A. The oracle is live: the drag printed its cost line, a glide line with
#      glide ticks, and the viewer line (the viewer really was resized by the
#      drag, so the row this measures is the reported one).
#   B. Motion under a running glide defers its layout: deferred_moves > 0.
#   C. The window takes ~no WM_PAINT during the glide: wm_paints <= -MaxWmPaints
#      (2), against one per glide frame before T2448.
#   D. The desk memo is live: some glide paint reused the composite - whole
#      (desk_reused) or all but the cards that moved (desk_partial).
#   Numbers go to $env:TEMP\ghoztty-drag-glide\<stamp>\report.txt.
#
# -NegativeControl inverts B and C and MUST fail.
#
# Only touches ghoztty processes running from this repo's zig-out*.
#   powershell -NoProfile -File test\win32\drag-glide.ps1
param(
    [string]$ExePath,
    [int]$TravelPx = 720,
    [int]$StepPx = 12,
    [int]$TickMs = 16,
    [int]$MaxWmPaints = 2,
    [switch]$NegativeControl,
    [switch]$Interactive
)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }

$env:GHOZTTY_PIPE_SUFFIX = "-dragglide$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
Assert-GhozttyIsolatedBuild -Exe $exe | Out-Null

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$outDir = Join-Path $env:TEMP "ghoztty-drag-glide\$stamp-$PID"
New-Item -ItemType Directory -Force $outDir | Out-Null
$report = Join-Path $outDir 'report.txt'

$script:pass = 0
$script:fail = 0
$script:skipped = 0
function Rep([string]$m) { $m | Tee-Object -FilePath $report -Append | Write-Host }
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Rep "PASS  $label" }
    else { $script:fail++; $host.UI.WriteErrorLine("FAIL  $label"); "FAIL  $label" | Out-File -Append $report }
}

function Kill-RepoInstances {
    [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
}

# `ghoztty +verb > file` from PowerShell writes nothing (T245), so CLI answers
# are read through cmd's redirection.
function Invoke-Cli([string[]]$argv) {
    $out = Join-Path $outDir "cli-$PID.txt"
    $quoted = ($argv | ForEach-Object { '"' + $_.Replace('"', '\"') + '"' }) -join ' '
    cmd /c "`"$exe`" $quoted > `"$out`" 2>&1" | Out-Null
    $raw = if (Test-Path $out) { Get-Content $out -Raw } else { '' }
    Remove-Item $out -ErrorAction SilentlyContinue
    if ($null -eq $raw) { return '' }
    return $raw.Trim()
}

# The window's first (leftmost) pane id, from +list --json.
function Get-FirstPaneId([IntPtr]$top) {
    $j = try { Invoke-Cli @('+list', '--json') | ConvertFrom-Json } catch { $null }
    if ($null -eq $j -or -not $j.success) { return $null }
    foreach ($w in @($j.data.windows | ForEach-Object { $_ })) {
        if ([string]$w.id -ne [string]$top.ToInt64()) { continue }
        $n = @($w.tabs | ForEach-Object { $_ })[0].splits
        while ($n -and $n.type -ne 'leaf') { $n = $n.left }
        if ($n) { return [string]$n.terminal.id }
    }
    return $null
}

function Get-Visible([IntPtr]$top, [string]$class) {
    return @(Get-TestChildWindows -Window $top -Class $class | Where-Object Visible)
}

function Get-LastMatch([string]$log, [string]$pattern) {
    if (-not (Test-Path $log)) { return $null }
    $hit = $null
    foreach ($l in @(Get-Content $log -ErrorAction SilentlyContinue)) {
        if ($l -match $pattern) { $hit = $Matches.Clone() }
    }
    return $hit
}

function Get-GlideSample([string]$log) {
    $m = Get-LastMatch $log ('divider glide ticks=(\d+) mean_us=(\d+) max_us=(\d+) mean_gap_us=(\d+) ' +
        'max_gap_us=(\d+) late=(\d+) fps=(\d+) viewer_ticks=(\d+) viewer_us=(\d+) period_us=(\d+) ' +
        'deferred_moves=(\d+) wm_paints=(\d+) wm_paint_us=(\d+) desk_composed=(\d+) desk_reused=(\d+) ' +
        'desk_partial=(\d+) .*verdict=(\w+)')
    if ($null -eq $m) { return $null }
    return [pscustomobject]@{
        Ticks = [int]$m[1]; MeanUs = [int]$m[2]; MaxUs = [int]$m[3]; MeanGapUs = [int]$m[4]
        MaxGapUs = [int]$m[5]; Late = [int]$m[6]; Fps = [int]$m[7]; ViewerTicks = [int]$m[8]
        ViewerUs = [int]$m[9]; PeriodUs = [int]$m[10]; Deferred = [int]$m[11]; WmPaints = [int]$m[12]
        WmPaintUs = [int]$m[13]; DeskComposed = [int]$m[14]; DeskReused = [int]$m[15]
        DeskPartial = [int]$m[16]; Verdict = $m[17]
    }
}

function Get-ViewerSample([string]$log) {
    $m = Get-LastMatch $log ('divider drag viewers=(\d+) mean_viewer_us=(\d+) mean_viewer_nav_us=(\d+) ' +
        'mean_viewer_bounds_us=(\d+) mean_viewer_toc_us=(\d+) mean_us=(\d+)')
    if ($null -eq $m) { return $null }
    return [pscustomobject]@{
        Viewers = [int]$m[1]; ViewerUs = [int]$m[2]; NavUs = [int]$m[3]
        BoundsUs = [int]$m[4]; TocUs = [int]$m[5]; MeanUs = [int]$m[6]
    }
}

function Get-DragSample([string]$log) {
    $m = Get-LastMatch $log 'divider drag ticks=(\d+) mean_us=(\d+) max_us=(\d+) .*mean_paint_us=(\d+) .*verdict=(\w+)'
    if ($null -eq $m) { return $null }
    return [pscustomobject]@{ Ticks = [int]$m[1]; MeanUs = [int]$m[2]; MaxUs = [int]$m[3]; PaintUs = [int]$m[4]; Verdict = $m[5] }
}

$td = New-TestDesktop -Interactive:$Interactive
try {
    Rep "T2451 divider-drag fold glide with a viewer pane, $stamp"
    Rep "  exe:   $exe"
    Rep "  drag:  $TravelPx px out and back, $StepPx px every $TickMs ms"

    $log = Join-Path $outDir 'stderr.log'
    Kill-RepoInstances
    $env:GHOZTTY_PERF = '1'
    $app = Start-OnTestDesktop -Exe $exe -StdErr $log -Arguments @(
        '--config-default-files=false', '--background=#101014', '--session-persistence=false')
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow' -TimeoutMs 20000
    if ($top -eq [IntPtr]::Zero) { throw 'no window for the glide instance' }
    $top = [IntPtr]$top
    [void](Set-TestWindowPos -Window $top -X 20 -Y 20 -Width 1600 -Height 900)
    Start-Sleep -Milliseconds 1500

    # ---- the row: p1 | view | p3 | p4 | p5, equal widths ----------------
    $p1 = $null
    for ($t = 0; $t -lt 20 -and -not $p1; $t++) { $p1 = Get-FirstPaneId $top; if (-not $p1) { Start-Sleep -Milliseconds 250 } }
    $problems = @()
    if (-not $p1) { $problems += '+list named no first pane' }
    else {
        $page = Join-Path $outDir 'page.md'
        [IO.File]::WriteAllText($page, "# Glide`n`nA page for the viewer pane in the folding row (T2451).`n`n## Section`n`nText.`n")
        $steps = @(
            @('+split', "--target=$p1", '--direction=right', '--name=p3'),
            @('+split', '--target=p3', '--direction=right', '--name=p4'),
            @('+split', '--target=p4', '--direction=right', '--name=p5'),
            @('+split', "--target=$p1", '--direction=right', '--name=view', "--view=$page")
        )
        foreach ($argv in $steps) {
            $r = Invoke-Cli $argv
            if ($r -match '(?i)error|unknown|not found') { $problems += "$($argv -join ' '): $r" }
            Start-Sleep -Milliseconds 600
        }
        $chain = $null
        $chain = {
            param([object[]]$Nodes)
            if ($Nodes.Count -eq 1) { return $Nodes[0] }
            $rest = & $chain @($Nodes | Select-Object -Skip 1)
            return [ordered]@{ direction = 'horizontal'; ratio = [math]::Round(100.0 / $Nodes.Count, 4); left = $Nodes[0]; right = $rest }
        }
        $nodes = @($p1, 'view', 'p3', 'p4', 'p5' | ForEach-Object { [ordered]@{ pane = $_ } })
        $json = (& $chain $nodes) | ConvertTo-Json -Depth 20 -Compress
        $r = Invoke-Cli @('+rearrange', "--target=$p1", "--layout=$json")
        if ($r -match '(?i)error|unknown|not found|invalid') { $problems += "+rearrange: $r" }
    }
    Start-Sleep -Milliseconds 2500
    $terms = @(Get-Visible $top 'GhozttyTerminal' | Sort-Object Left)
    $view = @(Get-Visible $top 'GhozttyViewer')[0]
    if ($terms.Count -ne 4 -or -not $view) { $problems += "found $($terms.Count) terminal(s) and viewer=$([bool]$view), want 4 and a viewer" }
    elseif (-not ($terms[0].Right -le $view.Left -and @($terms | Where-Object { $_.Left -lt $view.Left }).Count -eq 1)) {
        $problems += "the viewer is not second in the row (viewer left $($view.Left))"
    }
    Assert ($problems.Count -eq 0) ("the row was built: p1 | viewer | p3 | p4 | p5" +
        $(if ($problems.Count) { " - " + ($problems -join ' | ') } else { '' }))
    if ($problems.Count) { throw 'the scene could not be built' }
    Rep ("  row: " + (($terms | ForEach-Object { "$($_.Left)-$($_.Right)" }) -join ', ') + "; viewer $($view.Left)-$($view.Right)")

    # ---- the drag: first divider, out and back ---------------------------
    # Screen coordinates; Send-TestMouse converts per target.
    $x = [int](($terms[0].Right + $view.Left) / 2)
    $y = [int](($view.Top + $view.Bottom) / 2)
    $n = [int][math]::Ceiling($TravelPx / $StepPx)
    $foldedMid = $null
    $base = 0
    [void](Send-TestMouse -Window $top -Target $top -X $x -Y $y -Action down -HoldMs 0)
    Start-Sleep -Milliseconds 150
    $sw = [Diagnostics.Stopwatch]::StartNew()
    for ($i = 1; $i -le 2 * $n; $i++) {
        $off = $(if ($i -le $n) { $i } else { 2 * $n - $i }) * $StepPx
        [void](Send-TestMouse -Window $top -Target $top -X ($x + $off) -Y $y -Action move -HoldMs 0)
        $due = ($i - $base) * $TickMs
        while ($sw.ElapsedMilliseconds -lt $due) { Start-Sleep -Milliseconds 1 }
        if ($i -eq $n) {
            # The far end: let the fold glide finish under the button, count
            # what is still a full pane, and restart the clock for the way back.
            Start-Sleep -Milliseconds 300
            $foldedMid = @(Get-Visible $top 'GhozttyTerminal').Count + @(Get-Visible $top 'GhozttyViewer').Count
            $sw.Restart(); $base = $i
        }
    }
    # Let the unfold glide finish under the button before releasing it.
    Start-Sleep -Milliseconds 400
    [void](Send-TestMouse -Window $top -Target $top -X $x -Y $y -Action up -HoldMs 0)

    $glide = $null; $viewer = $null; $drag = $null
    for ($t = 0; $t -lt 40 -and ($null -eq $glide -or $null -eq $drag); $t++) {
        Start-Sleep -Milliseconds 250
        $glide = Get-GlideSample $log; $viewer = Get-ViewerSample $log; $drag = Get-DragSample $log
    }
    Rep ''
    if ($drag) { Rep ("  drag:   ticks=$($drag.Ticks) mean=$($drag.MeanUs)us max=$($drag.MaxUs)us paint=$($drag.PaintUs)us verdict=$($drag.Verdict)") }
    if ($viewer) { Rep ("  viewer: resized by $($viewer.Viewers) pass(es) max, $($viewer.ViewerUs)us/pass (nav $($viewer.NavUs), bounds $($viewer.BoundsUs), toc $($viewer.TocUs))") }
    if ($glide) {
        Rep ("  glide:  ticks=$($glide.Ticks) mean=$($glide.MeanUs)us max=$($glide.MaxUs)us gap mean=$($glide.MeanGapUs)us max=$($glide.MaxGapUs)us " +
            "late=$($glide.Late) ~$($glide.Fps) fps (period $($glide.PeriodUs)us) verdict=$($glide.Verdict)")
        Rep ("          viewer_ticks=$($glide.ViewerTicks) viewer_us=$($glide.ViewerUs) deferred_moves=$($glide.Deferred) wm_paints=$($glide.WmPaints) " +
            "($($glide.WmPaintUs)us each) desk composed=$($glide.DeskComposed) reused=$($glide.DeskReused) partial=$($glide.DeskPartial)")
    }
    Rep "  panes+viewers visible at the far end of the drag: $foldedMid of 5 (fewer = folded into strips)"
    Rep ''

    # ---- A. the oracle is live, on the reported row -----------------------
    Assert ($null -ne $drag -and $drag.Ticks -ge 8) "A: the drag printed its cost line and really moved (ticks=$(if ($drag) { $drag.Ticks } else { 'none' }))"
    Assert ($null -ne $glide -and $glide.Ticks -gt 0) "A: a fold glide ran under the drag and printed its line (glide ticks=$(if ($glide) { $glide.Ticks } else { 'none' }))"
    Assert ($null -ne $viewer -and $viewer.Viewers -ge 1) "A: the viewer pane was resized by the drag (viewer line: $(if ($viewer) { "viewers=$($viewer.Viewers)" } else { 'none' }))"
    if ($null -eq $glide) { throw 'no glide line - GHOZTTY_PERF oracle missing (release build?) or nothing folded' }

    # ---- B. motion under a running glide defers its layout ----------------
    $deferred = ($glide.Deferred -gt 0)
    if ($NegativeControl) { $deferred = -not $deferred }
    Assert $deferred "B: mouse moves under a running glide left their layout to the glide's next frame (deferred_moves=$($glide.Deferred))"

    # ---- C. ~no WM_PAINT during the glide ---------------------------------
    $quiet = ($glide.WmPaints -le $MaxWmPaints)
    if ($NegativeControl) { $quiet = -not $quiet }
    Assert $quiet "C: the window took at most $MaxWmPaints WM_PAINTs over $($glide.Ticks) glide frames (wm_paints=$($glide.WmPaints); one per frame before T2448)"

    # ---- D. the desk memo is live -----------------------------------------
    Assert (($glide.DeskReused + $glide.DeskPartial) -gt 0) ("D: some glide paint reused the desk composite " +
        "(reused=$($glide.DeskReused) partial=$($glide.DeskPartial) composed=$($glide.DeskComposed))")

    Rep ''
    Rep "report: $report"
    Complete-TestBody
}
finally {
    Kill-RepoInstances
    Remove-TestDesktop
    Remove-Item env:GHOZTTY_PERF -ErrorAction SilentlyContinue
}

# --- stamp (T783) ----------------------------------------------------------
if ($script:fail -eq 0 -and $script:skipped -eq 0 -and -not $NegativeControl -and (Test-TestBodyComplete)) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard drag-glide -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Skipped $script:skipped
