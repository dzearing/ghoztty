# T2913 acceptance: viewer panes in a window nobody can see do no work
# (Mac 68a8344f0: `ViewerView.startWatchingDiff` skips the git-status poll
# while the window is hidden and refreshes once when shown;
# `ViewerImageView.advanceFrame` holds an animated image on its frame).
#
# Layout: an anchor window (cmd.exe, so nothing in it runs git), a server
# window (a tiny loopback HTTP server, in a pane of the app under test so it
# dies with it), and the MEASURED window: a `git-status:` pane on a scratch
# repository with a website pane split beside it. A covering window comes
# last.
#
# THE ORACLES
#   git: the app is launched with GIT_TRACE pointing at a file, so every git
#     process it starts (and only it - the anchor runs cmd.exe, the CLI runs
#     no git) writes one "resolved executable dir" line there. Counting lines
#     counts git runs; no sampling of short-lived processes.
#   listing: `ViewerPane.applyDiffListing` logs one
#     `viewer diff pane=<id> ... files=N` line per push (the viewer-diff.ps1
#     oracle), so "the change reached the pane" is readable from stderr.
#   page frames: the website counts requestAnimationFrame callbacks into its
#     document.title ("raf-N"), which `+list --json` reports as the pane's
#     title. rAF runs on the same frame clock as GIF playback, so a page whose
#     count stops is a page whose GIFs stop. Without a positive control (the
#     count must climb while shown) the frame arms are SKIPPED, never passed.
#
#   A1  shown: the git-status pane runs git (the 2 s poll)
#   A2  shown: the page produces frames (positive control for B3/C3)
#   B1  minimized: no git runs in 6 s
#   B2  the panes were told: "page paused (hidden)" for both
#   B3  minimized: the page produces no frames
#   B4  restored: a file added while minimized is listed within 1.5 s, via
#       the one catch-up ("diff poll catch-up on show")
#   B5  restored: the poll and the frames run again
#   C1  covered by a newer window: no git runs in 5 s
#   C3  covered: the page produces no frames
#   C4  uncovered: the poll runs again
#
# Runs on a BACKGROUND desktop (lib\TestDesktop.ps1); nothing takes the
# user's foreground - asserted by the foreground watcher, not assumed.
#
# -NegativeControl leaves the window shown where B minimizes it: B1 MUST fail.
#
#   powershell -NoProfile -File test\win32\hidden-viewer.ps1

param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }
$cli = [System.IO.Path]::ChangeExtension($exe, '.com')
if (-not (Test-Path $cli)) { $cli = $exe }

$env:GHOZTTY_PIPE_SUFFIX = "-hidview$PID"
$tmp = Join-Path $env:TEMP "ghoztty-t2913-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null
$work = Join-Path $tmp 'repo'
$trace = Join-Path $tmp 'git-trace.txt'
$portFile = Join-Path $tmp 'port.txt'
$server = Join-Path $tmp 'server.ps1'
$errlog = Join-Path $tmp 'app-stderr.log'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:pass = 0
$script:fail = 0
$script:skipped = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}
function Skip([string]$label) {
    $script:skipped++
    Write-Host "SKIP  $label" -ForegroundColor Yellow
}

function Invoke-Cli([string]$CliArgs) {
    cmd /c "`"$cli`" $CliArgs > `"$tmp\out.txt`" 2> `"$tmp\err.txt`"" | Out-Null
    return $LASTEXITCODE
}
function Get-CliOut { "$(Get-Content "$tmp\out.txt" -Raw -ErrorAction SilentlyContinue)".Trim() }
function Get-CliErr { "$(Get-Content "$tmp\err.txt" -Raw -ErrorAction SilentlyContinue)".Trim() }

# How many git processes the app has started.
function Get-GitRuns {
    if (-not (Test-Path $trace)) { return 0 }
    return @(Select-String -Path $trace -Pattern 'trace: resolved executable dir' -SimpleMatch -ErrorAction SilentlyContinue).Count
}

function Get-Log {
    if (-not (Test-Path $errlog)) { return '' }
    return ((Get-Content $errlog -Raw -ErrorAction SilentlyContinue) -replace '\s+', ' ')
}
function Get-DiffLines([string]$PaneId) {
    return @([regex]::Matches((Get-Log), "viewer diff pane=$([regex]::Escape($PaneId)) spec=\S+ repo=\S* files=(\d+)"))
}

function Get-Leaves($node) {
    if ($null -eq $node) { return @() }
    if ($node.type -eq 'leaf') { return @($node.terminal) }
    return @(Get-Leaves $node.left) + @(Get-Leaves $node.right)
}
function Get-LeafByName([string]$Name) {
    if ((Invoke-Cli '+list --json') -ne 0) { return $null }
    $json = Get-CliOut
    if (-not $json) { return $null }
    $data = ($json | ConvertFrom-Json).data
    foreach ($w in @($data.windows)) {
        foreach ($t in @($w.tabs)) {
            foreach ($leaf in @(Get-Leaves $t.splits)) {
                if ($leaf.name -eq $Name) { return $leaf }
            }
        }
    }
    return $null
}
function Wait-LeafByName([string]$Name, [int]$Seconds = 20) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        $leaf = Get-LeafByName $Name
        if ($leaf) { return $leaf }
        Start-Sleep -Milliseconds 300
    }
    return $null
}

# The page's frame count, from its title ("raf-N"), or -1.
function Get-FrameCount {
    $leaf = Get-LeafByName 'hvw'
    if ($leaf -and "$($leaf.title)" -match 'raf-(\d+)') { return [int]$Matches[1] }
    return -1
}

# A GhozttyWindow of the app that is not one of $Known.
function Wait-NewWindow([int64[]]$Known, [int]$Seconds = 20) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        foreach ($w in @(Get-TestWindows -ProcessId $app.Pid -Class 'GhozttyWindow')) {
            if ($Known -notcontains [int64]$w.Hwnd) { return [IntPtr][int64]$w.Hwnd }
        }
        Start-Sleep -Milliseconds 250
    }
    return [IntPtr]::Zero
}

$serverBody = @'
param([string]$PortFile)
$html = '<!doctype html><html><head><meta charset="utf-8"><title>raf-0</title></head>' +
    '<body style="background:#123;color:#fff"><p>T2913 frame counter</p><script>' +
    'var n=0;function f(){n++;if(n%5===0){document.title="raf-"+n;}requestAnimationFrame(f);}' +
    'requestAnimationFrame(f);</script></body></html>'
$body = [System.Text.Encoding]::UTF8.GetBytes($html)
$l = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback), 0
$l.Start()
[System.IO.File]::WriteAllText($PortFile, "$($l.LocalEndpoint.Port)")
while ($true) {
    $c = $l.AcceptTcpClient()
    try {
        $s = $c.GetStream()
        $buf = New-Object byte[] 8192
        [void]$s.Read($buf, 0, $buf.Length)
        $hdr = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: text/html; charset=utf-8`r`nContent-Length: $($body.Length)`r`nCache-Control: no-store`r`nConnection: close`r`n`r`n")
        $s.Write($hdr, 0, $hdr.Length)
        $s.Write($body, 0, $body.Length)
        $s.Flush()
    } catch { } finally { $c.Close() }
}
'@

# --- the scratch repository: one committed file, one untracked ---------------
New-Item -ItemType Directory -Force $work | Out-Null
Set-Content -Path (Join-Path $work 'kept.txt') -Value 'one' -Encoding ascii
& git.exe -C $work init -q 2>&1 | Out-Null
& git.exe -C $work config user.email 't2913@example.com' 2>&1 | Out-Null
& git.exe -C $work config user.name 'T2913' 2>&1 | Out-Null
& git.exe -C $work add -A 2>&1 | Out-Null
& git.exe -C $work commit -q -m base 2>&1 | Out-Null
Set-Content -Path (Join-Path $work 'loose1.txt') -Value 'u1' -Encoding ascii
if (-not (& git.exe -C $work rev-parse --short HEAD 2>$null)) {
    Write-TestAssertedNothing -Label 'HIDDEN VIEWER ACCEPTANCE' -Reason "the scratch repository could not be created in $work"
}

[void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
Start-TestForegroundWatch
[void](New-TestDesktop -Interactive:$Interactive)

try {
    [System.IO.File]::WriteAllText($server, $serverBody)
    # GIT_TRACE reaches the app (and only the app's children) through the
    # inherited environment; this script's own git calls are done by now.
    $env:GIT_TRACE = $trace
    try {
        $app = Start-OnTestDesktop -Exe $exe -StdErr $errlog -Arguments @('--config-default-files=false',
            '--background=#000000', '--session-persistence=false', '--confirm-close-surface=false',
            '--command=cmd.exe')
    } finally { Remove-Item Env:GIT_TRACE -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $anchor = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($anchor -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: top window not found'; exit 1 }
    Assert (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) 'window is NOT enumerable on the interactive desktop'

    # The loopback server, in a pane of the app under test.
    $cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$server`" `"$portFile`""
    Assert ((Invoke-Cli "+new-window --target=hvs --name=hvsp `"--command=$cmd`"") -eq 0) "setup: the server window ($(Get-CliErr))"
    $srvWin = Wait-NewWindow @([int64]$anchor)
    $deadline = (Get-Date).AddSeconds(20)
    while (-not (Test-Path $portFile) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }
    $port = "$(Get-Content $portFile -Raw -ErrorAction SilentlyContinue)".Trim()
    if (-not $port) { throw 'the loopback server never reported a port' }

    # The measured window: git-status, with the website split beside it.
    Assert ((Invoke-Cli "+new-window --target=hv --name=hvd `"--working-directory=$work`" --view=git-status:") -eq 0) "setup: the git-status window ($(Get-CliErr))"
    $top = Wait-NewWindow @([int64]$anchor, [int64]$srvWin)
    if ($top -eq [IntPtr]::Zero) { throw 'the measured window did not open' }
    $diffLeaf = Wait-LeafByName 'hvd'
    if (-not $diffLeaf) { throw 'the git-status pane is not in +list' }
    $diffId = "$($diffLeaf.id)"
    Assert ((Invoke-Cli "+split --target=hvd --direction=right --name=hvw --view=http://127.0.0.1:$port/") -eq 0) "setup: the website pane ($(Get-CliErr))"
    $webLeaf = Wait-LeafByName 'hvw'
    if (-not $webLeaf) { throw 'the website pane is not in +list' }
    $webId = "$($webLeaf.id)"

    # Side by side, never overlapping, so only B and C hide the window.
    $wa = Get-TestWorkArea
    $mw = [math]::Min(1000, [int]($wa.Width * 0.55))
    [void](Set-TestWindowPos -Window $top -X ($wa.Left + 10) -Y ($wa.Top + 10) -Width $mw -Height 560)
    $ax = $wa.Left + $mw + 30
    $aw = [math]::Min(420, $wa.Width - $mw - 40)
    [void](Set-TestWindowPos -Window $anchor -X $ax -Y ($wa.Top + 10) -Width $aw -Height 250)
    [void](Set-TestWindowPos -Window $srvWin -X $ax -Y ($wa.Top + 270) -Width $aw -Height 250)

    # The first listing (files=1: the one untracked file).
    $deadline = (Get-Date).AddSeconds(15)
    while (@(Get-DiffLines $diffId).Count -lt 1 -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 300 }
    $first = @(Get-DiffLines $diffId)
    if ($first.Count -lt 1) { throw "the git-status pane never listed the repository (pane $diffId)" }
    Assert ($first[-1].Groups[1].Value -eq '1') "setup: the first listing counts the one untracked file (files=$($first[-1].Groups[1].Value))"

    Write-Host '== A: shown - the poll runs git, the page draws frames'
    Start-Sleep -Seconds 1
    $g0 = Get-GitRuns; $f0 = Get-FrameCount
    Start-Sleep -Seconds 5
    $g1 = Get-GitRuns; $f1 = Get-FrameCount
    Assert (($g1 - $g0) -ge 2) "A1 shown, the git-status pane ran git $($g1 - $g0) times in 5 s (>= 2: the 2 s poll)"
    $framesLive = ($f0 -ge 0 -and ($f1 - $f0) -ge 20)
    if ($framesLive) { Assert $true "A2 shown, the page drew frames (raf $f0 -> $f1 in 5 s)" }
    else { Skip "A2 the page drew no countable frames on this desktop (raf $f0 -> $f1); the frame arms B3/B5/C3 cannot be scored" }

    Write-Host '== B: minimized - no git, no frames; restored - one catch-up'
    if (-not $NegativeControl) { [void](Send-TestSysCommand -Window $top -Command minimize) }
    else { Write-Host '  (negative control: the window was never minimized; B1 must fail)' }
    # Let a git run already out when the window hid finish, and the frame
    # count the page last wrote settle into +list.
    Start-Sleep -Milliseconds 1500
    $g0 = Get-GitRuns; $f0 = Get-FrameCount
    Set-Content -Path (Join-Path $work 'loose2.txt') -Value 'u2' -Encoding ascii
    Start-Sleep -Seconds 6
    $g1 = Get-GitRuns; $f1 = Get-FrameCount
    Assert (($g1 - $g0) -eq 0) "B1 minimized, the git-status pane ran git $($g1 - $g0) times in 6 s (0)"
    if (-not $NegativeControl) {
        $log = Get-Log
        Assert ($log -match "viewer pane $([regex]::Escape($diffId)): page paused \(hidden\)") 'B2 the git-status pane was told it is hidden'
        Assert ($log -match "viewer pane $([regex]::Escape($webId)): page paused \(hidden\)") 'B2 the website pane was told it is hidden (its WebView2 stops drawing)'
    }
    if ($framesLive) { Assert (($f1 - $f0) -le 5) "B3 minimized, the page drew $($f1 - $f0) frames in 6 s (<= 5: paused; raf $f0 -> $f1)" }
    $before = @(Get-DiffLines $diffId).Count
    if (-not $NegativeControl) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        [void](Send-TestSysCommand -Window $top -Command restore)
        $landed = -1
        while ($sw.ElapsedMilliseconds -lt 4000) {
            $lines = @(Get-DiffLines $diffId)
            if ($lines.Count -gt $before -and $lines[-1].Groups[1].Value -eq '2') { $landed = [int]$sw.ElapsedMilliseconds; break }
            Start-Sleep -Milliseconds 100
        }
        Assert ($landed -ge 0 -and $landed -le 1500) "B4 restored, the file added while minimized is listed within 1.5 s ($landed ms)"
        Assert ((Get-Log) -match "viewer pane $([regex]::Escape($diffId)): diff poll catch-up on show") 'B4 ... by the one catch-up on show'
        Start-Sleep -Seconds 1
        $g0 = Get-GitRuns; $f0 = Get-FrameCount
        Start-Sleep -Seconds 5
        $g1 = Get-GitRuns; $f1 = Get-FrameCount
        Assert (($g1 - $g0) -ge 2) "B5 restored, the poll runs git again ($($g1 - $g0) times in 5 s)"
        if ($framesLive) { Assert (($f1 - $f0) -ge 20) "B5 restored, the page draws frames again (raf $f0 -> $f1)" }

        Write-Host '== C: covered by a newer window - no git; uncovered - polling again'
        $known = @([int64]$anchor, [int64]$srvWin, [int64]$top)
        Assert ((Invoke-Cli '+new-window --target=hvcov --name=hvcovp --focus') -eq 0) "C setup: a covering window ($(Get-CliErr))"
        $cov = Wait-NewWindow $known
        if ($cov -eq [IntPtr]::Zero) { throw 'the covering window did not open' }
        [void](Set-TestWindowPos -Window $cov -X ($wa.Left) -Y ($wa.Top) -Width ($mw + 40) -Height 600)
        # The visibility poll reads the cover on its next tick.
        Start-Sleep -Milliseconds 1500
        $g0 = Get-GitRuns; $f0 = Get-FrameCount
        Start-Sleep -Seconds 5
        $g1 = Get-GitRuns; $f1 = Get-FrameCount
        Assert (($g1 - $g0) -eq 0) "C1 covered, the git-status pane ran git $($g1 - $g0) times in 5 s (0)"
        if ($framesLive) { Assert (($f1 - $f0) -le 5) "C3 covered, the page drew $($f1 - $f0) frames in 5 s (<= 5; raf $f0 -> $f1)" }
        [void](Set-TestWindowPos -Window $cov -X $ax -Y ($wa.Top + 540) -Width $aw -Height 150)
        Start-Sleep -Milliseconds 1500
        $g0 = Get-GitRuns
        Start-Sleep -Seconds 5
        $g1 = Get-GitRuns
        Assert (($g1 - $g0) -ge 2) "C4 uncovered, the poll runs git again ($($g1 - $g0) times in 5 s)"
    }

    $crashed = (Test-Path $errlog) -and (Select-String -Path $errlog -Pattern 'Segmentation fault|panic' -Quiet)
    Assert (-not $crashed) 'no segfault or panic in the app log'
    Assert (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) 'GUI never became visible on the interactive desktop'
} catch {
    $script:fail++
    Write-Host "FAIL  the run terminated: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "      at $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())"
} finally {
    [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
    Remove-TestDesktop
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

$fgSeen = @(Stop-TestForegroundWatch)
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $leaked = @(Get-TestLaunchedPids | Where-Object { $fgSeen -contains $_ })
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    Assert ($leaked.Count -eq 0) 'no test-desktop app ever became foreground on the interactive desktop'
}

Complete-TestBody
if ($script:fail -eq 0 -and $script:skipped -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard hidden-viewer -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Skipped $script:skipped -Label 'HIDDEN VIEWER ACCEPTANCE'
