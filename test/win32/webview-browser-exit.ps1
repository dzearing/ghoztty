# T3034 acceptance: the WebView2 browser process tree goes away on its own
# shortly after the last viewer pane closes, and comes back for the next one.
#
# WHY THIS EXISTS. Perf audit-1 (PA-V02, T2963) read `webview2.Host` - which
# holds the shared ICoreWebView2Environment until app exit - and ESTIMATED that
# the browser, GPU and utility processes (150-300 MB) therefore stay up for the
# rest of the session after any viewer has opened. T3034 built an idle release
# for it, and this harness, written to prove that release, measured the opposite
# on 2026-11-16 (runtime 157.0.4341.46): with the environment HELD, every
# msedgewebview2.exe of the app exits about five seconds after the last
# controller closes, and the next viewer gets a fresh browser process from the
# same environment. The runtime already does the release; the fix was reverted.
#
# What stays is this oracle, because that behavior is the runtime's, not ours:
# a future WebView2 that keeps its browser alive while an environment is
# referenced would bring PA-V02 back silently, and this goes red when it does.
#
# WHAT IS ASSERTED, in one app, in order:
#
#   A. A viewer opens and RENDERS (its contents card - built from headings the
#      page posts back over the bridge - is up), and a WebView2 tree hangs off
#      this app, seen both by walking the process tree and by the private
#      user-data folder on every process's command line.
#   B. Close it and re-open a viewer at once: the second viewer renders.
#   C. Close the last viewer: within 60 s NO process of this app's WebView2 tree
#      is left, and the app is still running and serving.
#   D. A viewer opened afterwards renders normally, on a NEW browser process.
#
# LOCALAPPDATA is private to the run, so the WebView2 user-data folder - and
# therefore the browser process - is this app's alone: a second app on the same
# folder shares one browser, and a parallel harness worker would otherwise keep
# (or own) the tree being counted. It also gives the folder-name match a path
# no other process carries.
#
#   powershell -NoProfile -File test\win32\webview-browser-exit.ps1
#
# -NegativeControl leaves the section-B viewer OPEN through section C, so the
# tree cannot exit: C's zero check and D's new-browser check MUST fail -
# exactly TWO failures, which proves C reads the real process table.
param([string]$ExePath, [switch]$Interactive, [switch]$NegativeControl)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }
if (-not (Test-Path $exe)) { Write-Host "SETUP FAIL: no exe at $exe"; exit 1 }

# Endpoint isolation: a run must never reach the user's own instance.
$env:GHOZTTY_PIPE_SUFFIX = "-wvx$PID"

. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
Assert-GhozttyIsolatedBuild -Exe $exe | Out-Null
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\HarnessLeak.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

Register-RepoBuildTeardown -Exe $exe | Out-Null

$script:pass = 0
$script:skipped = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Invoke-Verb([string[]]$VerbArgs) {
    $out = (& $exe @VerbArgs 2>&1 | ForEach-Object { $_.ToString() } | Out-String)
    return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
}

function Get-Data {
    $json = (& $exe +list --json 2>$null | Out-String).Trim()
    if (-not $json) { return $null }
    try { return ($json | ConvertFrom-Json).data } catch { return $null }
}

function Get-Win([string]$target) {
    $d = Get-Data
    if (-not $d) { return $null }
    foreach ($w in $d.windows) { if ($w.target -eq $target) { return $w } }
    return $null
}

function Wait-Win([string]$target) {
    for ($t = 0; $t -lt 30; $t++) {
        $w = Get-Win $target
        if ($w) { return $w }
        Start-Sleep -Milliseconds 200
    }
    return $null
}

function Wait-NoWin([string]$target) {
    for ($t = 0; $t -lt 30; $t++) {
        if (-not (Get-Win $target)) { return $true }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

# The WebView2 processes of THIS app, counted two ways. The walk follows
# msedgewebview2 children of the app pid and their descendants; the folder
# match takes every msedgewebview2 whose command line names this run's private
# user-data folder, which still finds a child orphaned by an exited browser
# root. Both are filtered by creation time so a recycled pid cannot count.
function Get-WebViewTree([int]$AppPid, [datetime]$Since) {
    $all = @(Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CreationDate -ge $Since })
    $roots = @($all | Where-Object { $_.ParentProcessId -eq $AppPid })
    $seen = @{}
    $queue = New-Object System.Collections.Queue
    foreach ($r in $roots) { $seen[[int]$r.ProcessId] = $true; $queue.Enqueue([int]$r.ProcessId) }
    while ($queue.Count -gt 0) {
        $p = $queue.Dequeue()
        foreach ($c in $all) {
            $cp = [int]$c.ProcessId
            if ($c.ParentProcessId -eq $p -and -not $seen.ContainsKey($cp)) {
                $seen[$cp] = $true
                $queue.Enqueue($cp)
            }
        }
    }
    $rootIds = @($roots | ForEach-Object { [int]$_.ProcessId })
    $byUdf = @($all | Where-Object { $_.CommandLine -and $_.CommandLine.IndexOf($localApp, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
    return [pscustomobject]@{
        Count = [math]::Max($seen.Count, $byUdf.Count)
        Walked = $seen.Count
        ByFolder = $byUdf.Count
        Roots = $rootIds
    }
}

function Wait-TreeAtLeast([int]$AppPid, [datetime]$Since, [int]$Min, [int]$TimeoutSec) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        $tree = Get-WebViewTree $AppPid $Since
        if ($tree.Count -ge $Min) { return $tree }
        Start-Sleep -Milliseconds 300
    } while ((Get-Date) -lt $deadline)
    return $tree
}

# The viewer's contents card: built from the headings the PAGE posts back, so
# its presence is proof the document rendered, not merely that a host window
# exists. It takes its on-screen presentation only past ~720 DIP of pane, so
# the viewer's window is widened first.
function Wait-RenderedViewer([int]$ProcessId) {
    for ($t = 0; $t -lt 60; $t++) {
        foreach ($w in @(Get-TestWindows -ProcessId $ProcessId -Class 'GhozttyWindow')) {
            $top = [IntPtr][int64]$w.Hwnd
            foreach ($vh in @(Get-TestChildWindows -Window $top -Class 'GhozttyViewer')) {
                if ($w.Width -lt 1300) {
                    [void](Set-TestWindowPos -Window $top -X 0 -Y 0 -Width 1400 -Height 900)
                }
                foreach ($c in @(Get-TestChildWindows -Window ([IntPtr][int64]$vh.Hwnd) -Class 'GhozttyViewerTOC')) {
                    if ($c.Width -gt 0 -and $c.Height -gt 0) { return $true }
                }
            }
        }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

function Test-AppServing {
    for ($t = 0; $t -lt 20; $t++) {
        if (Get-Data) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

$runDir = Join-Path $env:TEMP "ghoztty-wvx-$PID"
$localApp = Join-Path $runDir 'localappdata'
New-Item -ItemType Directory -Force -Path $localApp | Out-Null
$doc = Join-Path $runDir 'doc.md'
$headings = (1..40 | ForEach-Object { "## Heading $_`n`nSome text under heading $_.`n" }) -join "`n"
Set-Content -Path $doc -Value "# Browser exit`n`n$headings" -Encoding utf8

$errlog = Join-Path $runDir 'app.log'

$savedLocal = $env:LOCALAPPDATA
[void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 300)
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$app = $null
$since = (Get-Date).AddSeconds(-2)

try {
    $env:LOCALAPPDATA = $localApp
    $app = Start-OnTestDesktop -Exe $exe -StdErr $errlog -Arguments @(
        '--session-persistence=false', '--config-default-files=false')
    $env:LOCALAPPDATA = $savedLocal
    Start-Sleep -Seconds 3
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'the GUI came up'
    Assert (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) 'the GUI is NOT on the interactive desktop'
    $baseTop = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow' -TimeoutMs 15000
    Assert ($baseTop -ne [IntPtr]::Zero) 'the launch window exists (it keeps the app alive between viewers)'
    $t0 = Get-WebViewTree $app.Pid $since
    Assert ($t0.Count -eq 0) "no WebView2 process exists before any viewer opens (got $($t0.Count))"

    # =====================================================================
    # A. a viewer opens and renders
    # =====================================================================
    Write-Host ''
    Write-Host 'A. first viewer'
    $r = Invoke-Verb @('+new-window', '--target=wv1', "--view=$doc")
    Assert ($r.Code -eq 0) "A: +new-window --view exits 0 (got $($r.Code): $($r.Out.Trim()))"
    Assert ($null -ne (Wait-Win 'wv1')) 'A: the viewer window is listed'
    Assert (Wait-RenderedViewer $app.Pid) 'A: the document rendered (its contents card is up)'
    $tA = Wait-TreeAtLeast $app.Pid $since 2 20
    Assert ($tA.Count -ge 2) "A: a WebView2 process tree hangs off the app (got $($tA.Count) processes)"
    Assert ($tA.Roots.Count -eq 1) "A: exactly one browser root process (got $($tA.Roots.Count))"
    Assert ($tA.ByFolder -ge $tA.Walked -and $tA.ByFolder -ge 2) `
        "A: the user-data-folder match sees the whole tree (folder $($tA.ByFolder), walk $($tA.Walked)) - without it C's zero could be vacuous"
    $rootA = 0
    if ($tA.Roots.Count -ge 1) { $rootA = $tA.Roots[0] }

    # =====================================================================
    # B. close and re-open at once
    # =====================================================================
    Write-Host ''
    Write-Host 'B. close and re-open at once'
    $r = Invoke-Verb @('+close', '--target=wv1')
    Assert ($r.Code -eq 0) "B: +close exits 0 (got $($r.Code))"
    Assert (Wait-NoWin 'wv1') 'B: the viewer window is gone'
    $r = Invoke-Verb @('+new-window', '--target=wv2', "--view=$doc")
    Assert ($r.Code -eq 0) "B: re-open +new-window --view exits 0 (got $($r.Code))"
    Assert (Wait-RenderedViewer $app.Pid) 'B: the re-opened viewer rendered'
    $tB = Wait-TreeAtLeast $app.Pid $since 2 20
    Assert ($tB.Count -ge 2) "B: its WebView2 tree is up (got $($tB.Count))"
    $rootB = 0
    if ($tB.Roots.Count -ge 1) { $rootB = $tB.Roots[0] }

    # =====================================================================
    # C. close the last viewer: the whole tree exits on its own
    # =====================================================================
    Write-Host ''
    Write-Host 'C. close the last viewer and wait'
    if (-not $NegativeControl) {
        $r = Invoke-Verb @('+close', '--target=wv2')
        Assert ($r.Code -eq 0) "C: +close exits 0 (got $($r.Code))"
    } else {
        Write-Host '  NEGATIVE CONTROL: the viewer stays open'
    }
    $closedAt = Get-Date
    $tC = $null
    do {
        Start-Sleep -Milliseconds 500
        $tC = Get-WebViewTree $app.Pid $since
    } while ($tC.Count -gt 0 -and ((Get-Date) - $closedAt).TotalSeconds -lt 60)
    $took = [int]((Get-Date) - $closedAt).TotalSeconds
    Assert ($tC.Count -eq 0) "C: every WebView2 process of this app exited (left $($tC.Count) [walk $($tC.Walked), folder $($tC.ByFolder)] after ${took}s)"
    $aliveC = (-not ($app.Process -and $app.Process.HasExited))
    Assert $aliveC 'C: the app is still running'
    if ($aliveC) { Assert (Test-AppServing) 'C: the app still answers +list' }

    # =====================================================================
    # D. the next viewer renders, on a new browser
    # =====================================================================
    Write-Host ''
    Write-Host 'D. a viewer after the tree exited'
    if ($aliveC) {
        $r = Invoke-Verb @('+new-window', '--target=wv3', "--view=$doc")
        Assert ($r.Code -eq 0) "D: +new-window --view exits 0 (got $($r.Code))"
        Assert (Wait-RenderedViewer $app.Pid) 'D: the document rendered (contents card up)'
        $tD = Wait-TreeAtLeast $app.Pid $since 2 20
        Assert ($tD.Count -ge 2) "D: a WebView2 tree is back (got $($tD.Count))"
        Assert (($tD.Roots.Count -eq 1) -and ($tD.Roots[0] -ne $rootB) -and ($tD.Roots[0] -ne $rootA)) `
            "D: on a NEW browser process (earlier $rootA/$rootB, now $($tD.Roots -join ','))"
    } else {
        Write-Host '  SKIP D: the app did not survive section C'; $script:skipped++
    }

    Complete-TestBody
} finally {
    $env:LOCALAPPDATA = $savedLocal
    Remove-TestDesktop
    [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 300)
    Start-Sleep -Milliseconds 1500
    Remove-Item -Recurse -Force $runDir -ErrorAction SilentlyContinue
}

$fgSeen = @(Stop-TestForegroundWatch)
$leaked = @(Get-TestLaunchedPids | Where-Object { $fgSeen -contains $_ })
Assert ($leaked.Count -eq 0) "no test-desktop app ever became foreground on the interactive desktop (saw $($leaked -join ','))"

if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard webview-browser-exit -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Label 'WEBVIEW BROWSER EXIT' -Pass $script:pass -Fail $script:fail -Skipped $script:skipped -MinPass 20
