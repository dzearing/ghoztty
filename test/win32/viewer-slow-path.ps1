# T3245 acceptance: a viewer loading from a SLOW path never freezes the
# terminals beside it.
#
# A markdown or html viewer reads its document (T3224) and every file the page
# asks for - pictures, stylesheets, scripts (T3245) - on a worker, the request
# parked on its WebView2 deferral. Before that, every read and every `stat` of
# the 3-tier resolution ran on the GUI thread, the message loop every terminal
# pane in the window draws and takes keys on, so a document with twenty
# pictures on a network share froze typing for the whole load.
#
# THE SLOW PATH. Nothing on this box is a slow disk, so the app is launched
# with GHOZTTY_TEST_VIEWER_SLOW_MS (src\apprt\win32\viewer_slow_path.zig,
# Debug builds only): every viewer file read takes that much longer, wherever
# it runs. What this proves is WHERE the reads run, which is the whole defect.
#
# THE ORACLES
#   latency: a sampler thread, bound to the test desktop, sends WM_NULL to the
#     window holding the terminal and the viewer (SendMessageTimeout) every
#     ~15 ms and records each round trip. That is exactly the wait a keystroke
#     has: it is answered only when the GUI thread gets back to its message
#     loop. (Off-desktop, SendInput is dead - lib\TestDesktop.ps1 - so the
#     probe asks the loop directly.) A send that FAILS is counted, never timed:
#     the first version of this probe ran on the interactive desktop, every
#     send failed at once, and a 6-second freeze read as 4 ms - which is the
#     reason C2 exists.
#   served: every answer logs `viewer resource pane=<id> served=<rel> bytes=N
#     serve_ms=M parked=<bool>` (template tier) or `viewer page pane=<id>
#     served=<rel> bytes=N mime=... parked=<bool>` (a rendered page), and the
#     document read logs `file rendered bytes=N read_ms=M`.
#
#   A1  markdown: all 12 pictures are served, every one parked on the worker
#   A2  ...each took the slow path's delay (serve_ms >= delay): the slowness
#       really happened, so A4's low number is not a load that skipped it
#   A3  the document itself was read on the worker, slowly (read_ms >= delay)
#   A4  while all that loaded, the window's message loop never stalled for
#       90% of one read (max round trip < 0.9 x delay)
#   B1  html page: its stylesheet and 6 pictures are served, every one parked
#   B2  ...and the message loop never stalled while they loaded
#   C1  CONTROL - the same markdown load with the worker refused
#       (GHOZTTY_TEST_VIEWER_INLINE=1): the pictures are answered inline
#       (parked=false) - the old behavior
#   C2  ...and the probe SEES it: several round trips of a whole read or more.
#       Without C2 a probe that could not see a stall would pass A4 and B2.
#
# Runs on a BACKGROUND desktop (lib\TestDesktop.ps1); nothing takes the
# user's foreground - asserted by the foreground watcher, not assumed.
#
# -NegativeControl runs arm A with the worker refused: A1 and A4 MUST fail.
#
#   powershell -NoProfile -File test\win32\viewer-slow-path.ps1

param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive, [int]$DelayMs = 500, [switch]$KeepTemp)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }
$cli = [System.IO.Path]::ChangeExtension($exe, '.com')
if (-not (Test-Path $cli)) { $cli = $exe }

$env:GHOZTTY_PIPE_SUFFIX = "-slowpath$PID"
$tmp = Join-Path $env:TEMP "ghoztty-t3245-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null
$docs = Join-Path $tmp 'docs'
New-Item -ItemType Directory -Force $docs | Out-Null

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

function Get-Log([string]$Path) {
    if (-not (Test-Path $Path)) { return '' }
    return ((Get-Content $Path -Raw -ErrorAction SilentlyContinue) -replace '\s+', ' ')
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
function Wait-NewWindow([int64[]]$Known, [int]$Pid0, [int]$Seconds = 20) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        foreach ($w in @(Get-TestWindows -ProcessId $Pid0 -Class 'GhozttyWindow')) {
            if ($Known -notcontains [int64]$w.Hwnd) { return [IntPtr][int64]$w.Hwnd }
        }
        Start-Sleep -Milliseconds 250
    }
    return [IntPtr]::Zero
}

# --- the documents -----------------------------------------------------------
$svg = '<svg xmlns="http://www.w3.org/2000/svg" width="40" height="40"><rect width="40" height="40" fill="#c33"/></svg>'
$mdImages = 12
$pageImages = 6
$md = Join-Path $docs 'slow.md'
$mdBody = "# Slow path`n`n"
for ($i = 1; $i -le $mdImages; $i++) {
    [System.IO.File]::WriteAllText((Join-Path $docs "img$i.svg"), $svg)
    $mdBody += "![picture $i](img$i.svg)`n`n"
}
[System.IO.File]::WriteAllText($md, $mdBody)
$page = Join-Path $docs 'slow.html'
$pageBody = '<!doctype html><html><head><meta charset="utf-8"><title>slow page</title><link rel="stylesheet" href="page.css"></head><body><h1>Slow page</h1>'
for ($i = 1; $i -le $pageImages; $i++) {
    [System.IO.File]::WriteAllText((Join-Path $docs "pic$i.svg"), $svg)
    $pageBody += "<img src=`"pic$i.svg`">"
}
$pageBody += '</body></html>'
[System.IO.File]::WriteAllText($page, $pageBody)
[System.IO.File]::WriteAllText((Join-Path $docs 'page.css'), 'body { background: #234; color: #fff; }')

# --- the probe ---------------------------------------------------------------
# A sampler THREAD in this process, bound to the test desktop: a SendMessage
# across desktops fails at once (which is why lib\TestDesktop.ps1 marshals every
# one onto its own desktop-bound worker), and a probe that times its own
# failures reads a frozen window as a 0 ms round trip. So the thread calls
# SetThreadDesktop first, and every failed send is counted, not timed.
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
public class T3245Probe {
    [DllImport("user32.dll", SetLastError = true)] static extern IntPtr OpenDesktopW([MarshalAs(UnmanagedType.LPWStr)] string name, uint flags, bool inherit, uint access);
    [DllImport("user32.dll", SetLastError = true)] static extern bool SetThreadDesktop(IntPtr h);
    [DllImport("user32.dll", SetLastError = true)] static extern bool CloseDesktop(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr SendMessageTimeoutW(IntPtr h, uint m, IntPtr w, IntPtr l, uint flags, uint ms, out IntPtr r);
    Thread thread;
    volatile bool stop;
    readonly object gate = new object();
    readonly List<double> at = new List<double>();
    readonly List<double> rt = new List<double>();
    public int Failed;
    public string Error = "";
    readonly Stopwatch clock = Stopwatch.StartNew();
    public double Now { get { return clock.Elapsed.TotalMilliseconds; } }

    public static T3245Probe Start(string desktop, long hwnd) {
        var p = new T3245Probe();
        var ready = new ManualResetEvent(false);
        p.thread = new Thread(delegate() { p.Loop(desktop, new IntPtr(hwnd), ready); });
        p.thread.IsBackground = true;
        p.thread.Start();
        ready.WaitOne(10000);
        return p;
    }

    void Loop(string desktop, IntPtr h, ManualResetEvent ready) {
        IntPtr hDesk = IntPtr.Zero;
        if (!string.IsNullOrEmpty(desktop)) {
            hDesk = OpenDesktopW(desktop, 0, false, 0x10000000);
            if (hDesk == IntPtr.Zero || !SetThreadDesktop(hDesk)) {
                Error = "cannot join desktop " + desktop + ": " + Marshal.GetLastWin32Error();
                ready.Set();
                return;
            }
        }
        ready.Set();
        IntPtr r;
        while (!stop) {
            double t0 = Now;
            // SMTO_ABORTIFHUNG (2): a window Windows already calls hung still
            // returns, so the probe itself never wedges.
            bool ok = SendMessageTimeoutW(h, 0, IntPtr.Zero, IntPtr.Zero, 2, 10000, out r) != IntPtr.Zero;
            double took = Now - t0;
            lock (gate) {
                if (ok) { at.Add(t0); rt.Add(took); } else { Failed++; }
            }
            Thread.Sleep(15);
        }
        if (hDesk != IntPtr.Zero) CloseDesktop(hDesk);
    }

    // Stop, and return the round trips of samples started at or after `from`.
    public double[] Finish(double from) {
        stop = true;
        thread.Join(15000);
        var list = new List<double>();
        lock (gate) {
            for (int i = 0; i < rt.Count; i++) if (at[i] >= from) list.Add(rt[i]);
        }
        return list.ToArray();
    }
}
'@

function Start-LoopProbe([int64]$Hwnd) {
    $td = $script:GhozttyTestDesktop
    $name = if ($td -and -not $td.Interactive) { $td.Name } else { '' }
    return [T3245Probe]::Start($name, $Hwnd)
}

# Served lines for one pane: template tier (`viewer resource`) or page tier.
function Get-Served([string]$Log, [string]$PaneId, [string]$Tier, [string]$RelPattern) {
    $id = [regex]::Escape($PaneId)
    $pat = if ($Tier -eq 'page') {
        "viewer page pane=$id served=($RelPattern) bytes=(\d+) mime=\S+ parked=(true|false)"
    } else {
        "viewer resource pane=$id served=($RelPattern) bytes=(\d+) serve_ms=(\d+) parked=(true|false)"
    }
    return @([regex]::Matches($Log, $pat) | ForEach-Object {
            if ($Tier -eq 'page') {
                [pscustomobject]@{ Rel = $_.Groups[1].Value; Ms = -1; Parked = $_.Groups[3].Value }
            } else {
                [pscustomobject]@{ Rel = $_.Groups[1].Value; Ms = [int]$_.Groups[3].Value; Parked = $_.Groups[4].Value }
            }
        })
}

# Load $View into a viewer split beside the terminal pane $Beside while the
# probe samples the window; waits until $Want resources matching $RelPattern
# are served (or $Seconds pass). Returns what happened.
function Measure-ViewerLoad([string]$ErrLog, [int64]$Hwnd, [string]$Beside, [string]$Name, [string]$View,
    [string]$Tier, [string]$RelPattern, [int]$Want, [int]$Seconds = 60) {
    $probe = Start-LoopProbe $Hwnd
    Start-Sleep -Milliseconds 800
    $from = $probe.Now
    $code = Invoke-Cli "+split --target=$Beside --direction=right --name=$Name `"--view=$View`""
    $leaf = Wait-LeafByName $Name
    $paneId = if ($leaf) { "$($leaf.id)" } else { '' }
    $served = @()
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ($paneId -and (Get-Date) -lt $deadline) {
        $served = @(Get-Served (Get-Log $ErrLog) $paneId $Tier $RelPattern)
        if ($served.Count -ge $Want) { break }
        Start-Sleep -Milliseconds 250
    }
    Start-Sleep -Milliseconds 500
    $rts = @($probe.Finish($from))
    $max = if ($rts.Count) { ($rts | Measure-Object -Maximum).Maximum } else { -1 }
    return [pscustomobject]@{
        Code = $code; Err = (Get-CliErr); PaneId = $paneId; Served = $served
        Samples = $rts.Count; Max = $max; Long = @($rts | Where-Object { $_ -ge (0.9 * $DelayMs) }).Count
        Failed = $probe.Failed; ProbeError = $probe.Error
    }
}

# Launch the app with the slow path (and, for the control, the worker refused),
# open a terminal window, and return what the arms need.
function Start-SlowApp([string]$ErrLog, [bool]$Inline) {
    $env:GHOZTTY_TEST_VIEWER_SLOW_MS = "$DelayMs"
    if ($Inline) { $env:GHOZTTY_TEST_VIEWER_INLINE = '1' }
    try {
        $app = Start-OnTestDesktop -Exe $exe -StdErr $ErrLog -Arguments @('--config-default-files=false',
            '--background=#000000', '--session-persistence=false', '--confirm-close-surface=false',
            '--command=cmd.exe')
    } finally {
        Remove-Item Env:GHOZTTY_TEST_VIEWER_SLOW_MS -ErrorAction SilentlyContinue
        Remove-Item Env:GHOZTTY_TEST_VIEWER_INLINE -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { throw 'the GUI died at launch' }
    $anchor = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($anchor -eq [IntPtr]::Zero) { throw 'the first window was not found' }
    if ((Invoke-Cli "+new-window --target=sp --name=spt --command=cmd.exe") -ne 0) { throw "the terminal window did not open ($(Get-CliErr))" }
    $win = Wait-NewWindow @([int64]$anchor) $app.Pid
    if ($win -eq [IntPtr]::Zero) { throw 'the terminal window did not appear' }
    if (-not (Wait-LeafByName 'spt')) { throw 'the terminal pane is not in +list' }
    $wa = Get-TestWorkArea
    [void](Set-TestWindowPos -Window $win -X ($wa.Left + 10) -Y ($wa.Top + 10) -Width ([math]::Min(1100, $wa.Width - 20)) -Height 640)
    Start-Sleep -Seconds 1
    return [pscustomobject]@{ App = $app; Hwnd = [int64]$win }
}

function Test-Crashed([string]$ErrLog) {
    return (Test-Path $ErrLog) -and (Select-String -Path $ErrLog -Pattern 'Segmentation fault|panic' -Quiet)
}

$threshold = 0.9 * $DelayMs
$errA = Join-Path $tmp 'app-a.log'
$errC = Join-Path $tmp 'app-c.log'

[void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
Start-TestForegroundWatch
[void](New-TestDesktop -Interactive:$Interactive)

try {
    Write-Host "== A/B: the worker, with every viewer read taking $DelayMs ms"
    $run = Start-SlowApp $errA ([bool]$NegativeControl)
    Assert (-not (Test-TestDesktopLeak -ProcessId $run.App.Pid)) 'window is NOT enumerable on the interactive desktop'

    $a = Measure-ViewerLoad $errA $run.Hwnd 'spt' 'spm' $md 'template' 'img\d+\.svg' $mdImages
    Assert ($a.Code -eq 0 -and $a.PaneId) "A setup: the markdown pane opened ($($a.Err))"
    Assert ($a.ProbeError -eq '' -and $a.Failed -eq 0) "A setup: every probe send reached the window (failed=$($a.Failed) $($a.ProbeError))"
    $parked = @($a.Served | Where-Object { $_.Parked -eq 'true' })
    Assert ($a.Served.Count -eq $mdImages -and $parked.Count -eq $mdImages) "A1 all $mdImages pictures served, every one parked on the worker (served=$($a.Served.Count) parked=$($parked.Count))"
    $slowOnes = @($a.Served | Where-Object { $_.Ms -ge $DelayMs })
    Assert ($a.Served.Count -gt 0 -and $slowOnes.Count -eq $a.Served.Count) "A2 ...each took the slow path's $DelayMs ms (serve_ms: $(($a.Served | ForEach-Object { $_.Ms }) -join ','))"
    $render = [regex]::Match((Get-Log $errA), "viewer pane $([regex]::Escape($a.PaneId)): file rendered bytes=\d+ read_ms=(\d+)")
    Assert ($render.Success -and [int]$render.Groups[1].Value -ge $DelayMs) "A3 the document was read on the worker, slowly (read_ms=$(if ($render.Success) { $render.Groups[1].Value } else { '-' }))"
    Assert ($a.Samples -ge 20 -and $a.Max -ge 0 -and $a.Max -lt $threshold) "A4 the message loop never stalled while it loaded: max round trip $([math]::Round($a.Max, 1)) ms over $($a.Samples) samples (must be < $threshold)"

    $b = Measure-ViewerLoad $errA $run.Hwnd 'spt' 'sph' $page 'page' 'pic\d+\.svg|page\.css' ($pageImages + 1)
    Assert ($b.Code -eq 0 -and $b.PaneId) "B setup: the html pane opened ($($b.Err))"
    Assert ($b.ProbeError -eq '' -and $b.Failed -eq 0) "B setup: every probe send reached the window (failed=$($b.Failed) $($b.ProbeError))"
    $bParked = @($b.Served | Where-Object { $_.Parked -eq 'true' })
    Assert ($b.Served.Count -eq ($pageImages + 1) -and $bParked.Count -eq $b.Served.Count) "B1 the page's stylesheet and $pageImages pictures served, every one parked (served=$($b.Served.Count) parked=$($bParked.Count))"
    Assert ($b.Samples -ge 10 -and $b.Max -ge 0 -and $b.Max -lt $threshold) "B2 ...and the message loop never stalled: max round trip $([math]::Round($b.Max, 1)) ms over $($b.Samples) samples (must be < $threshold)"
    Assert (-not (Test-Crashed $errA)) 'A/B no segfault or panic in the app log'
    [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)

    Write-Host '== C: CONTROL - the same load with the worker refused'
    $run = Start-SlowApp $errC $true
    $c = Measure-ViewerLoad $errC $run.Hwnd 'spt' 'spm' $md 'template' 'img\d+\.svg' $mdImages
    Assert ($c.Code -eq 0 -and $c.PaneId) "C setup: the markdown pane opened ($($c.Err))"
    Assert ($c.ProbeError -eq '' -and $c.Failed -eq 0) "C setup: every probe send reached the window (failed=$($c.Failed) $($c.ProbeError))"
    $inline = @($c.Served | Where-Object { $_.Parked -eq 'false' })
    Assert ($c.Served.Count -eq $mdImages -and $inline.Count -eq $mdImages) "C1 the pictures were answered inline, the old way (served=$($c.Served.Count) inline=$($inline.Count) serve_ms: $(($c.Served | ForEach-Object { $_.Ms }) -join ','))"
    Assert ($c.Long -ge 3 -and $c.Max -ge $threshold) "C2 ...and the probe SAW the stall: $($c.Long) round trips >= $threshold ms, max $([math]::Round($c.Max, 1)) ms"
    Assert (-not (Test-Crashed $errC)) 'C no segfault or panic in the app log'
} catch {
    $script:fail++
    Write-Host "FAIL  the run terminated: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "      at $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())"
} finally {
    [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
    Remove-TestDesktop
    if ($KeepTemp) { Write-Host "kept: $tmp" } else { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
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
        update -Guard viewer-slow-path -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Skipped $script:skipped -Label 'VIEWER SLOW PATH ACCEPTANCE'
