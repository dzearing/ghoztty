# T2912 acceptance: a window nobody can see HOLDS its title (Mac 68a8344f0,
# `BaseTerminalController.pendingWindowTitle`). A program that spins its title
# ten times a second costs a caption repaint and the taskbar/accessibility
# notifications behind it every time; while the window is minimized or
# covered the title waits, and lands the moment the window shows - or every
# 5 seconds at most, so the taskbar and screen readers are never far behind.
# `+list` never waits: it reports the held title at once.
#
# Layout: an anchor window (kept on screen, side by side) and the measured
# window, whose one pane runs an emitter that retitles it (OSC 2 "spin-N")
# every 100 ms and writes N to a file, so the test knows the newest title.
# The caption is read across processes with GetWindowTextW, which returns the
# text the app last SET (no message reaches the app), i.e. what the taskbar
# and Alt-Tab show.
#
#   A1  shown: the caption follows the title (many changes in 3 s)
#   B1  minimized: the caption changes at most twice in 6.5 s (the 5 s
#       landing), and at least once (it is held, not frozen)
#   B2  minimized: `+list` reports a title at most ~1 s behind the emitter
#       while the caption is older
#   B3  restored: the caption lands within 1 s, and follows the title again
#   C1  covered by a newer window: the caption holds (at most once in 3 s)
#   C2  uncovered: it lands within the visibility poll
#
# Runs on a BACKGROUND desktop (lib\TestDesktop.ps1); nothing takes the
# user's foreground - asserted by the foreground watcher, not assumed.
#
# -NegativeControl leaves the window shown where B minimizes it: B1 MUST fail.
#
#   powershell -NoProfile -File test\win32\hidden-title.ps1

param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }
$cli = [System.IO.Path]::ChangeExtension($exe, '.com')
if (-not (Test-Path $cli)) { $cli = $exe }

$env:GHOZTTY_PIPE_SUFFIX = "-hidtitle$PID"
$tmp = Join-Path $env:TEMP "ghoztty-t2912-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null
$counter = Join-Path $tmp 'n.txt'
$emit = Join-Path $tmp 'emit.ps1'
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

function Invoke-Cli([string]$CliArgs) {
    cmd /c "`"$cli`" $CliArgs > `"$tmp\out.txt`" 2> `"$tmp\err.txt`"" | Out-Null
    return $LASTEXITCODE
}
function Get-CliOut { "$(Get-Content "$tmp\out.txt" -Raw -ErrorAction SilentlyContinue)".Trim() }
function Get-CliErr { "$(Get-Content "$tmp\err.txt" -Raw -ErrorAction SilentlyContinue)".Trim() }

# The N in "spin-N", or -1.
function Get-SpinN([string]$Text) {
    if ($Text -match 'spin-(\d+)') { return [int]$Matches[1] }
    return -1
}
function Get-EmitterN {
    try { return [int]([System.IO.File]::ReadAllText($counter).Trim()) } catch { return -1 }
}

# Sample the caption every 50 ms for $Ms; returns how many times it changed
# and the last value.
function Measure-Caption([IntPtr]$Window, [int]$Ms) {
    $changes = 0
    $last = Get-TestWindowText -Window $Window
    $deadline = (Get-Date).AddMilliseconds($Ms)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 50
        $now = Get-TestWindowText -Window $Window
        if ($now -ne $last) { $changes++; $last = $now }
    }
    return [pscustomobject]@{ Changes = $changes; Last = $last }
}

# The measured window's title as `+list` reports it.
function Get-ListTitle([IntPtr]$Window) {
    if ((Invoke-Cli '+list --json') -ne 0) { return $null }
    $tree = (Get-CliOut) | ConvertFrom-Json
    $windows = @(if ($null -ne $tree.data) { $tree.data.windows } else { $tree.windows })
    foreach ($w in $windows) {
        if ([int64]$w.id -eq [int64]$Window) { return "$($w.title)" }
    }
    return $null
}

# Wait up to $Ms for the caption to name a title at most $Lag behind the
# emitter; returns the elapsed ms, or -1.
function Wait-CaptionCurrent([IntPtr]$Window, [int]$Ms, [int]$Lag = 3) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $Ms) {
        $n = Get-SpinN (Get-TestWindowText -Window $Window)
        $e = Get-EmitterN
        if ($n -ge 0 -and $e -ge 0 -and ($e - $n) -le $Lag) { return [int]$sw.ElapsedMilliseconds }
        Start-Sleep -Milliseconds 50
    }
    return -1
}

$emitBody = @'
param([string]$Counter)
$esc = [char]27
$bel = [char]7
$n = 0
while ($true) {
    $n++
    [Console]::Out.Write("$esc]2;spin-$n$bel"); [Console]::Out.Flush()
    try { [System.IO.File]::WriteAllText($Counter, "$n") } catch { }
    Start-Sleep -Milliseconds 100
}
'@

[void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
Start-TestForegroundWatch
[void](New-TestDesktop -Interactive:$Interactive)

try {
    [System.IO.File]::WriteAllText($emit, $emitBody)
    $app = Start-OnTestDesktop -Exe $exe -StdErr $errlog -Arguments @('--config-default-files=false',
        '--background=#000000', '--session-persistence=false', '--confirm-close-surface=false')
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $anchor = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($anchor -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: top window not found'; exit 1 }
    Assert (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) 'window is NOT enumerable on the interactive desktop'

    $cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$emit`" `"$counter`""
    Assert ((Invoke-Cli "+new-window --target=ht --name=htp `"--command=$cmd`"") -eq 0) "setup: the measured window with the emitter ($(Get-CliErr))"
    $top = [IntPtr]::Zero
    $deadline = (Get-Date).AddSeconds(20)
    while ($top -eq [IntPtr]::Zero -and (Get-Date) -lt $deadline) {
        foreach ($w in @(Get-TestWindows -ProcessId $app.Pid -Class 'GhozttyWindow')) {
            if ([int64]$w.Hwnd -ne [int64]$anchor) { $top = [IntPtr][int64]$w.Hwnd }
        }
        if ($top -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 250 }
    }
    if ($top -eq [IntPtr]::Zero) { throw 'the measured window did not open' }

    # Side by side, never overlapping, so only B and C hide the window.
    $wa = Get-TestWorkArea
    $mw = [math]::Min(900, [int]($wa.Width * 0.5))
    [void](Set-TestWindowPos -Window $top -X ($wa.Left + 10) -Y ($wa.Top + 10) -Width $mw -Height 500)
    $ax = $wa.Left + $mw + 30
    $aw = [math]::Min(420, $wa.Width - $mw - 40)
    [void](Set-TestWindowPos -Window $anchor -X $ax -Y ($wa.Top + 10) -Width $aw -Height 300)
    Start-Sleep -Seconds 2
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-EmitterN) -lt 5 -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }
    if ((Get-EmitterN) -lt 5) { throw 'the emitter never ran' }

    Write-Host '== A: shown - the caption follows the title'
    $a = Measure-Caption $top 3000
    Assert ($a.Changes -ge 10) "A1 shown, the caption changed $($a.Changes) times in 3 s (>= 10; last '$($a.Last)')"

    Write-Host '== B: minimized - the caption holds, +list does not'
    if (-not $NegativeControl) { [void](Send-TestSysCommand -Window $top -Command minimize) }
    Start-Sleep -Milliseconds 700
    $b = Measure-Caption $top 6500
    if ($NegativeControl) {
        Write-Host '  (negative control: the window was never minimized; B1 must fail)'
    }
    Assert ($b.Changes -le 2 -and $b.Changes -ge 1) "B1 minimized, the caption changed $($b.Changes) times in 6.5 s (1..2: held, landing every 5 s)"
    $listTitle = Get-ListTitle $top
    $emitN = Get-EmitterN
    $capN = Get-SpinN (Get-TestWindowText -Window $top)
    $listN = Get-SpinN $listTitle
    Write-Host "  emitter=$emitN +list=$listN caption=$capN ('$listTitle')"
    $listLag = $emitN - $listN
    Assert ($listN -ge 0 -and $listLag -le 12) "B2 +list reports the newest title while hidden (lag $listLag titles, <= 12)"
    if (-not $NegativeControl) {
        Assert ($capN -ge 0 -and $capN -lt $listN) "B2 ... while the caption is older (caption spin-$capN < +list spin-$listN)"
        [void](Send-TestSysCommand -Window $top -Command restore)
    }
    $land = Wait-CaptionCurrent $top 1500
    Assert ($land -ge 0) "B3 restored, the held title lands within 1.5 s ($land ms)"
    $b3 = Measure-Caption $top 2000
    Assert ($b3.Changes -ge 6) "B3 ... and the caption follows the title again ($($b3.Changes) changes in 2 s)"

    if (-not $NegativeControl) {
        Write-Host '== C: covered by a newer window - held; moved away - lands'
        # A window opened now is the top of the z-order, so it really covers
        # the measured one (the visibility poll walks the windows above it).
        Assert ((Invoke-Cli '+new-window --target=htcov --name=htcovp --focus') -eq 0) "C setup: a covering window ($(Get-CliErr))"
        $cov = [IntPtr]::Zero
        $deadline = (Get-Date).AddSeconds(20)
        while ($cov -eq [IntPtr]::Zero -and (Get-Date) -lt $deadline) {
            foreach ($w in @(Get-TestWindows -ProcessId $app.Pid -Class 'GhozttyWindow')) {
                if ([int64]$w.Hwnd -ne [int64]$anchor -and [int64]$w.Hwnd -ne [int64]$top) { $cov = [IntPtr][int64]$w.Hwnd }
            }
            if ($cov -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 250 }
        }
        if ($cov -eq [IntPtr]::Zero) { throw 'the covering window did not open' }
        [void](Set-TestWindowPos -Window $cov -X ($wa.Left) -Y ($wa.Top) -Width ($mw + 40) -Height 540)
        # The visibility poll (250 ms) reads the cover on its next tick.
        Start-Sleep -Milliseconds 1500
        $c = Measure-Caption $top 3000
        Assert ($c.Changes -le 1) "C1 covered, the caption changed $($c.Changes) times in 3 s (<= 1)"
        if ($c.Changes -gt 1) {
            $cr = Get-TestWindowRect -Window $cov; $mr = Get-TestWindowRect -Window $top
            Write-Host "  cover rect: $($cr.Left),$($cr.Top)-$($cr.Right),$($cr.Bottom)  measured: $($mr.Left),$($mr.Top)-$($mr.Right),$($mr.Bottom)"
            Write-Host ("  z: cover={0} measured={1} anchor={2}; cover exstyle=0x{3:X}" -f (Get-TestZIndex -Window $cov), (Get-TestZIndex -Window $top), (Get-TestZIndex -Window $anchor), (Get-TestWindowStyle -Window $cov -ExStyle))
            Select-String -Path $errlog -Pattern 'window hidden|window revealed' -ErrorAction SilentlyContinue |
                Select-Object -Last 6 | ForEach-Object { Write-Host "  log: $($_.Line)" }
        }
        [void](Set-TestWindowPos -Window $cov -X $ax -Y ($wa.Top + 320) -Width $aw -Height 200)
        $land2 = Wait-CaptionCurrent $top 3000
        Assert ($land2 -ge 0) "C2 uncovered, the held title lands within the poll ($land2 ms)"
        $held = @(Select-String -Path $errlog -Pattern 'title held: window hidden' -SimpleMatch -ErrorAction SilentlyContinue).Count
        Assert ($held -ge 2) "the mechanism is in the log ($held 'title held' lines: minimize and cover)"
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
if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard hidden-title -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Skipped $script:skipped -Label 'HIDDEN TITLE ACCEPTANCE'
