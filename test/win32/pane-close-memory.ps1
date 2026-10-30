# @timing-sensitive
# T2494 acceptance: closing a PANE (or a tab) gives back everything it held,
# while its window stays open.
#
# WHY. Mac's 2026-10 memory audit (origin/main 1bc34a8d7 + ef57f03fd,
# docs/reference/memory.md) fixed whole classes of retained state: closed
# panes kept alive by closures on window-owned state, glide timers outliving
# their owner, a closed viewer keeping its browser process. T2473's
# window-close-memory.ps1 measures the WINDOW-close half on Windows; nothing
# measured what a single pane close inside a long-lived window gives back,
# which is the shape a real session has - one window for hours, panes split
# and closed all day.
#
# HOW. One app, one window that stays open for the whole run. Each SCENARIO
# runs -Warmup cycles (one-time costs: font atlases, the WebView2
# environment, shader compiles, allocator arenas), samples a BASELINE, runs
# -Cycles more, samples the END, and asserts the per-cycle growth,
# (end - baseline) / cycles, against a budget that is a small fraction of what
# one open pane costs (the PEAK sample, taken with cycle 1's pane open).
# Every close waits out --undo-timeout (1s here) before the next cycle, so
# what is measured is the real teardown, not a parked pane.
#
# Scenarios (-Scenario, default all):
#   split         +split a terminal, let its shell start, +close it.
#   viewer        +split --view a markdown file, let it render, +close it -
#                 and its msedgewebview2 renderer must go with it.
#   viewer-rapid  +split --view and +close it at once: the pane dies while
#                 the WebView2 controller is still being created, the
#                 late-controller path (ViewerPane.onControllerCompleted
#                 with a dead token) has to close what arrives.
#   rapid         +split a terminal and +close it at once: the close lands
#                 mid-layout, while the new pane's renderer/IO threads are
#                 still starting - the oracle for "nothing outlives a pane
#                 closed mid-animation", plus B1 (the app survived).
#   tab           ctrl+t, then +close the new tab's only pane.
#
# What is sampled is lib\ProcessMemory.ps1's Get-Sample: the app's private
# bytes, handles, GDI/USER objects, threads and GPU memory, plus every
# descendant process (pane shells, conhost, the WebView2 browser/renderers).
#
# KNOWN RED (2026-10-30): `split` and `rapid` A8 - a closed terminal pane
# keeps a window-sized GPU buffer until its window is destroyed (T2499). The
# guard is acked to T2499 until it closes.
#
# -NegativeControl leaves every measured pane OPEN instead of closing it. The
# budget asserts MUST go red: it is the proof that this meter can see a
# retained pane at all.
#
# -Report samples after every cycle, not only at the end.
#
# Only touches ghoztty processes running from this repo's zig-out*.
#   powershell -NoProfile -File test\win32\pane-close-memory.ps1
param(
    [string]$ExePath,
    [ValidateSet('all', 'split', 'viewer', 'viewer-rapid', 'rapid', 'tab')][string[]]$Scenario = @('all'),
    [int]$Cycles = 10,
    [int]$Warmup = 2,
    [string[]]$AppArgs = @(),
    [switch]$NegativeControl,
    [switch]$Interactive,
    [switch]$Report)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }

$env:GHOZTTY_PIPE_SUFFIX = "-paneclosemem$PID"
$errlog = Join-Path $env:TEMP "ghoztty-pane-close-memory-$PID.log"
$tmp = Join-Path $env:TEMP "ghoztty-t2494-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\ProcessMemory.ps1')

$all = @('split', 'viewer', 'viewer-rapid', 'rapid', 'tab')
$run = if ($Scenario -contains 'all') { $all } else { @($all | Where-Object { $Scenario -contains $_ }) }

$script:pass = 0
$script:fail = 0
$script:skipped = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Invoke-Verb([string[]]$VerbArgs) {
    $out = @(& $exe @VerbArgs 2>&1 | ForEach-Object { "$_" }) -join "`n"
    return [pscustomobject]@{ Code = $LASTEXITCODE; Text = $out.Trim() }
}

# Every leaf (terminal or viewer pane) in `+list --json`: objects with an `id`
# and a `pid` field (a viewer's pid is the app's own).
function Get-Leaves {
    $r = Invoke-Verb @('+list', '--json')
    if ($r.Code -ne 0 -or [string]::IsNullOrWhiteSpace($r.Text)) { return @() }
    $out = New-Object System.Collections.ArrayList
    $walk = $null
    $walk = {
        param($o)
        if ($null -eq $o) { return }
        if ($o -is [System.Array]) { foreach ($x in $o) { & $walk $x }; return }
        if ($o -is [System.Management.Automation.PSCustomObject]) {
            $names = @($o.PSObject.Properties.Name)
            if (($names -contains 'id') -and ($names -contains 'pid')) { [void]$out.Add($o) }
            foreach ($p in $o.PSObject.Properties) { & $walk $p.Value }
        }
    }
    try { & $walk ($r.Text | ConvertFrom-Json) } catch { return @() }
    # Unrolled on purpose: callers pipe this into Where-Object and count it
    # with @(), and a `return ,` array arrives there as ONE object - every id
    # in one `+close --target`, which closes nothing and still exits 0.
    return $out.ToArray()
}

# Tabs across every window in `+list --json`.
function Get-TabCount {
    $r = Invoke-Verb @('+list', '--json')
    if ($r.Code -ne 0 -or [string]::IsNullOrWhiteSpace($r.Text)) { return -1 }
    try { $j = $r.Text | ConvertFrom-Json } catch { return -1 }
    $windows = if ($null -ne $j.data) { $j.data.windows } else { $j.windows }
    $n = 0
    foreach ($w in @($windows)) { $n += @($w.tabs).Count }
    return $n
}

function Wait-LeafCount([int]$Want, [int]$TimeoutSec = 20) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        if (@(Get-Leaves).Count -eq $Want) { return $true }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    return $false
}

# A viewer is "up" once a GhozttyViewer child of non-zero size exists under
# the top window - the WebView2 controller is created for it by then.
function Wait-Viewer([IntPtr]$Top, [int]$TimeoutSec = 20) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        foreach ($h in @(Get-TestChildWindows -Window $Top -Class 'GhozttyViewer')) {
            if ($h.Width -gt 0 -and $h.Height -gt 0) { return $true }
        }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    return $false
}

$doc = Join-Path $tmp 'doc.md'
$body = (1..40 | ForEach-Object { "## Section $_`n`nSome text under section $_, with a [link](https://example.invalid/$_).`n" }) -join "`n"
Set-Content -Path $doc -Value "# Memory probe`n`n$body" -Encoding utf8

# One cycle of one scenario. Opens the scenario's pane, optionally samples the
# PEAK with it open, and closes it unless $Close is false (the negative
# control). Returns the peak sample or $null.
function Invoke-Cycle([string]$Kind, [int]$ProcessId, [IntPtr]$Top, [string]$Anchor, [string]$Name, [bool]$Close, [bool]$SamplePeak) {
    $before = @(Get-Leaves).Count
    $target = $Name
    switch ($Kind) {
        'split' {
            $r = Invoke-Verb @('+split', "--target=$Anchor", "--name=$Name", '--direction=right')
            if ($r.Code -ne 0) { throw "${Name}: +split failed: $($r.Text)" }
            Start-Sleep -Milliseconds 2000
        }
        'rapid' {
            $r = Invoke-Verb @('+split', "--target=$Anchor", "--name=$Name", '--direction=right')
            if ($r.Code -ne 0) { throw "${Name}: +split failed: $($r.Text)" }
        }
        'viewer' {
            $r = Invoke-Verb @('+split', "--target=$Anchor", "--name=$Name", '--direction=down', "--view=$doc")
            if ($r.Code -ne 0) { throw "${Name}: +split --view failed: $($r.Text)" }
            if (-not (Wait-Viewer $Top)) { throw "${Name}: the viewer pane never appeared" }
            Start-Sleep -Milliseconds 2000
        }
        'viewer-rapid' {
            $r = Invoke-Verb @('+split', "--target=$Anchor", "--name=$Name", '--direction=down', "--view=$doc")
            if ($r.Code -ne 0) { throw "${Name}: +split --view failed: $($r.Text)" }
        }
        'tab' {
            $ids = @(Get-Leaves | ForEach-Object { $_.id })
            # A closed pane's HWND can linger hidden until its deferred reap
            # (T681); the keys go to a live, sized one.
            $panes = @(Get-TestChildWindows -Window $Top -Class 'GhozttyTerminal' | Where-Object { $_.Visible -and $_.Width -gt 0 })
            if ($panes.Count -lt 1) { throw "${Name}: no terminal pane to send ctrl+t to" }
            $h = [IntPtr][int64]$panes[0].Hwnd
            $f = Focus-TestWindow -Window $Top -Child $h
            $k = Send-TestKeys -Window $Top -Target $h -Modifiers ctrl,shift -Key T
            if (-not ($f -and $k)) { throw "${Name}: ctrl+shift+t was not delivered (focus=$f keys=$k)" }
            $deadline = (Get-Date).AddSeconds(20)
            $new = $null
            do {
                Start-Sleep -Milliseconds 300
                $new = @(Get-Leaves | Where-Object { $ids -notcontains $_.id }) | Select-Object -First 1
            } while ($null -eq $new -and (Get-Date) -lt $deadline)
            if ($null -eq $new) { throw "${Name}: ctrl+shift+t opened no listed pane ($(Get-TabCount) tabs)" }
            if ($null -eq $new) { throw "${Name}: the new tab's pane is not listed" }
            $target = $new.id
            Start-Sleep -Milliseconds 2000
        }
    }
    $peak = $null
    if ($SamplePeak) { $peak = Get-Sample $ProcessId "peak $Kind" }
    if ($Close) {
        $r = Invoke-Verb @('+close', "--target=$target")
        if ($r.Code -ne 0) { throw "${Name}: +close failed: $($r.Text)" }
        if (-not (Wait-LeafCount $before)) { throw "${Name}: the pane did not close" }
        # Wait out the 1s undo window, so the pane is torn down, not parked.
        Start-Sleep -Milliseconds 1800
    }
    return $peak
}

[void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$app = $null
$results = New-Object System.Collections.ArrayList

try {
    $launchArgs = @('--config-default-files=false', '--session-persistence=false', '--confirm-close-surface=false', '--undo-timeout=1s') + $AppArgs
    $app = Start-OnTestDesktop -Exe $exe -StdErr $errlog -Arguments $launchArgs
    $appPid = $app.Pid
    Assert (-not (Test-TestDesktopLeak -ProcessId $appPid)) 'GUI is NOT enumerable on the interactive desktop'
    $top = Wait-TestWindow -ProcessId $appPid -Class 'GhozttyWindow' -TimeoutMs 20000
    Assert ($top -ne [IntPtr]::Zero) 'the window appeared'
    if ($top -eq [IntPtr]::Zero) { throw 'no window' }
    [void](Set-TestWindowPos -Window ([IntPtr]$top) -X 40 -Y 40 -Width 1000 -Height 700)
    Start-Sleep -Seconds 2
    $deadline = (Get-Date).AddSeconds(15)
    $leaves = @()
    do { $leaves = @(Get-Leaves); if ($leaves.Count -ge 1) { break }; Start-Sleep -Milliseconds 300 } while ((Get-Date) -lt $deadline)
    if ($leaves.Count -ne 1) { throw "expected one pane at launch, +list shows $($leaves.Count)" }
    $anchor = $leaves[0].id

    $gpuReadable = $null -ne (Get-GpuBytes $appPid)
    Write-Host "GPU process-memory counters readable: $gpuReadable"

    foreach ($kind in $run) {
        Write-Host ''
        Write-Host "== $kind"
        $tag = ($kind -replace '[^a-z]', '')
        for ($i = 1; $i -le $Warmup; $i++) {
            [void](Invoke-Cycle $kind $appPid $top $anchor "pcmw$tag$i" $true $false)
        }
        $base = Wait-Settled $appPid "$kind baseline"
        $samples = New-Object System.Collections.ArrayList
        [void]$samples.Add($base)
        $peak = $null
        for ($i = 1; $i -le $Cycles; $i++) {
            $pk = Invoke-Cycle $kind $appPid $top $anchor "pcm$tag$i" (-not $NegativeControl) ($i -eq 1)
            if ($pk) { $peak = $pk; [void]$samples.Add($pk) }
            if ($Report) { [void]$samples.Add((Wait-Settled $appPid "$kind after $i")) }
        }
        $end = Wait-Settled $appPid "$kind end"
        [void]$samples.Add($end)
        $samples | Format-Table Label, PrivMB, Handles, Gdi, User, Threads, GpuDedMB, GpuShMB, Procs, ProcMB -AutoSize | Out-String -Width 200 | Write-Host
        if ($base.ProcNames -ne $end.ProcNames) {
            Write-Host "baseline descendants: $($base.ProcNames)"
            Write-Host "end      descendants: $($end.ProcNames)"
        }

        $n = [double]$Cycles
        $row = [pscustomobject]@{
            Scenario  = $kind
            PaneMB    = $(if ($peak) { [math]::Round($peak.PrivMB - $base.PrivMB, 1) } else { $null })
            PerPriv   = [math]::Round(($end.PrivMB - $base.PrivMB) / $n, 2)
            PerHandle = [math]::Round(($end.Handles - $base.Handles) / $n, 1)
            PerGdi    = [math]::Round(($end.Gdi - $base.Gdi) / $n, 1)
            PerUser   = [math]::Round(($end.User - $base.User) / $n, 1)
            PerThread = [math]::Round(($end.Threads - $base.Threads) / $n, 1)
            Procs     = "$($base.Procs)->$($end.Procs)"
            PerProcMB = [math]::Round(($end.ProcMB - $base.ProcMB) / $n, 2)
            PerGpuMB  = $(if ($gpuReadable) { [math]::Round((($end.GpuDedMB + $end.GpuShMB) - ($base.GpuDedMB + $base.GpuShMB)) / $n, 2) } else { $null })
        }
        [void]$results.Add($row)

        # Budgets: a pane costs MBs and dozens of handles; what a close may
        # leave behind is allocator slack, never the pane.
        Assert ($row.PerPriv -le 1.0) ("$kind A1 private bytes per closed pane <= 1 MB (left {0:N2} MB)" -f $row.PerPriv)
        Assert ($row.PerHandle -le 5) ("$kind A2 kernel handles per closed pane <= 5 (left {0:N1})" -f $row.PerHandle)
        Assert ($row.PerGdi -le 1) ("$kind A3 GDI objects per closed pane <= 1 (left {0:N1})" -f $row.PerGdi)
        Assert ($row.PerUser -le 1) ("$kind A4 USER objects per closed pane <= 1 (left {0:N1})" -f $row.PerUser)
        Assert ($row.PerThread -le 0.5) ("$kind A5 threads per closed pane <= 0.5 - every renderer/IO thread joined (left {0:N1})" -f $row.PerThread)
        Assert ($end.Procs -le $base.Procs) "$kind A6 no child process outlives its pane (descendants $($base.Procs) -> $($end.Procs))"
        Assert ($row.PerProcMB -le 1.0) ("$kind A7 descendant private bytes per closed pane <= 1 MB (left {0:N2} MB)" -f $row.PerProcMB)
        if ($gpuReadable) {
            Assert ($row.PerGpuMB -le 1.0) ("$kind A8 GPU memory per closed pane <= 1 MB (left {0:N2} MB)" -f $row.PerGpuMB)
        } else {
            $script:skipped++
            Write-Host "SKIP  $kind A8 GPU memory: the GPU Process Memory counters are not readable on this box"
        }
        Assert ($null -ne (Get-Process -Id $appPid -ErrorAction SilentlyContinue)) "$kind B1 the app survived every cycle"
        if ($NegativeControl) { break }
    }

    Write-Host ''
    Write-Host 'per closed pane (MB, counts):'
    $results | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
    Assert (-not (Test-TestDesktopLeak -ProcessId $appPid)) 'B2 GUI never became visible on the interactive desktop'
}
finally {
    [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
    Remove-TestDesktop
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

$fgSeen = @(Stop-TestForegroundWatch)
$leaked = @(Get-TestLaunchedPids | Where-Object { $fgSeen -contains $_ })
Assert ($leaked.Count -eq 0) "no test-desktop app ever became foreground on the interactive desktop (saw $($leaked -join ','))"

# A green run stamps the covered files (T783). Only the verdict shape stamps:
# every scenario, the full cycle count, no extra app flags.
$verdictShape = ($run.Count -eq $all.Count -and $AppArgs.Count -eq 0 -and $Cycles -ge 10)
if ($script:fail -eq 0 -and -not $NegativeControl -and $verdictShape) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard pane-close-memory -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions$(if ($script:skipped) { ", $script:skipped SKIPPED" }))" -ForegroundColor Green }
else { Write-Host "$script:fail FAILURE(S) ($script:pass passed)" -ForegroundColor Red }
exit $(if ($script:fail -eq 0) { 0 } else { 1 })
