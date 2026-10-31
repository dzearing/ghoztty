# On-screen oracle for a fade the compositor runs (tracker T2469).
#
# On a pane that presents through the composition swap chain, the bell
# border is a child visual of the pane and its 0.3s easeInOut fade is declared
# to DirectComposition once; DWM steps it at the display's refresh. Before
# T2469 the UI thread stepped the same visual's opacity on the frame clock.
# test\win32\comp-present.ps1 proves the declaration from
# the log (0 UI-thread steps), on the background test desktop, which DWM never
# composes. What it cannot see is whether the picture actually moves on every
# refresh. This script films it.
#
# The app runs as a GHOST window on the input desktop (GHOZTTY_DEBUG_GHOST,
# debug builds only: never activated, bottom of the z-order - the T2463/T2488
# shape), so the person at the desk sees nothing. ghoztty-comp-spike.exe
# --film-hwnd records every frame DWM composes of it. A pane rings its bell,
# and GHOZTTY_DEBUG_BELL_FADE_STALL_MS blocks the window's thread for
# -StallMs the moment the fade starts - the stand-in for a busy UI thread.
#
# Each frame is scored by how yellow it is (the frame's rgb(255,204,0) at the
# fade's opacity over a black pane). Between the first frame that differs from
# the pre-bell picture and the first one at the final value:
#
#   advance  = changed frames / refreshes the fade spanned   (>= 0.98)
#   max hold = the most refreshes one value stayed on screen   (<= 1)
#   max jump = the largest single change, as a share of the whole fade
#              (<= 15%; a frozen fade that snaps to its end jumps 100%)
#
# Both arms run GHOZTTY_COMP_PRESENT=1, so the frame is the same visual and the
# capture sees it (a popup frame is its own window, which a capture of the main
# window never shows). Arm 'declared' is the shipped path and must pass both
# checks through the stall. Arm 'stepped' (GHOZTTY_DEBUG_BELL_FADE_STEPPED=1:
# the visual's fade stepped on the UI thread, the pre-T2469 way) is the
# control: it must FREEZE through the stall and snap (a jump of at least half
# the fade), which is what shows the score can tell the two apart.
#
#   powershell -NoProfile -File scripts\bell-fade-onscreen.ps1
#   powershell -NoProfile -File scripts\bell-fade-onscreen.ps1 -StallMs 0
#   powershell -NoProfile -File scripts\bell-fade-onscreen.ps1 -NegativeControl   # must go red
#
# -NegativeControl drops every other changed frame from the 'declared' film before it
# is scored (a fade at half the refresh rate): the advance and hold checks
# must fail.

param(
    [string]$Exe = (Join-Path $PSScriptRoot '..\zig-out\bin\ghoztty.exe'),
    [string]$Spike = (Join-Path $PSScriptRoot '..\zig-out\bin\ghoztty-comp-spike.exe'),
    [string[]]$Arms = @('declared', 'stepped'),
    [int]$StallMs = 500,
    [string]$OutDir,
    [switch]$KeepFrames,
    [switch]$NegativeControl
)

$ErrorActionPreference = 'Continue'
Set-StrictMode -Off

$testLib = Join-Path $PSScriptRoot '..\test\win32\lib'
. (Join-Path $testLib 'CleanSlate.ps1')
. (Join-Path $testLib 'Isolation.ps1')
. (Join-Path $testLib 'TestDesktop.ps1')
Add-Type -AssemblyName System.Drawing

$script:passes = 0
$script:failures = 0
function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ }
    else { "  FAIL $name"; $script:failures++ }
}

$Exe = [System.IO.Path]::GetFullPath($Exe)
$Spike = [System.IO.Path]::GetFullPath($Spike)
if (-not (Test-Path $Exe)) { "SETUP FAIL: $Exe not found - build it first"; exit 2 }
if (-not (Test-Path $Spike)) { "SETUP FAIL: $Spike not found - zig build comp-spike -Dapp-runtime=win32 -Doptimize=Debug"; exit 2 }

if (-not $OutDir) { $OutDir = Join-Path $env:TEMP "ghoztty-bell-fade-$PID" }
New-Item -ItemType Directory -Force $OutDir | Out-Null
$savedLocalAppData = $env:LOCALAPPDATA
$knobs = 'GHOZTTY_COMP_PRESENT', 'GHOZTTY_DEBUG_GHOST', 'GHOZTTY_TEST_NO_OCCLUSION', 'GHOZTTY_DEBUG_BELL_FADE_STALL_MS', 'GHOZTTY_DEBUG_BELL_FADE_STEPPED'
$saved = @{}
foreach ($k in $knobs) { $saved[$k] = [Environment]::GetEnvironmentVariable($k) }

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class BfWin {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    public static IntPtr[] TopLevel(uint pid, string cls) {
        var list = new List<IntPtr>();
        EnumWindows((h, l) => {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p == pid && IsWindowVisible(h)) {
                var sb = new System.Text.StringBuilder(64);
                GetClassName(h, sb, 64);
                if (sb.ToString() == cls) list.Add(h);
            }
            return true;
        }, IntPtr.Zero);
        return list.ToArray();
    }
}
public static class BfScore {
    // Sum of red over the frame's yellow pixels: red well above blue, green
    // 0.6-0.95 of red. Rises with the frame's opacity (more pixels pass, each
    // brighter), and the black pane, white text and grey chrome score 0.
    public static long Yellow(byte[] b, int stride, int w, int h) {
        long sum = 0;
        for (int y = 0; y < h; y++) {
            int row = y * stride;
            for (int x = 0; x < w; x++) {
                int i = row + x * 4;
                int bl = b[i], g = b[i + 1], r = b[i + 2];
                if (r < 24 || r - bl < 20) continue;
                if (g * 100 < r * 60 || g * 100 > r * 95) continue;
                sum += r;
            }
        }
        return sum;
    }
}
'@

function Read-Text($path) {
    if (Test-Path $path) { return [string](Get-Content $path -Raw -ErrorAction SilentlyContinue) }
    return ''
}
function Wait-Log($path, $pattern, $ms) {
    $deadline = (Get-Date).AddMilliseconds($ms)
    do {
        if ((Read-Text $path) -match $pattern) { return $true }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Measure-Yellow($path) {
    $bmp = New-Object System.Drawing.Bitmap $path
    try {
        $rect = New-Object System.Drawing.Rectangle(0, 0, $bmp.Width, $bmp.Height)
        $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $bytes = New-Object byte[] ($data.Stride * $bmp.Height)
        [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $bytes.Length)
        $stride = $data.Stride
        $bmp.UnlockBits($data)
        return [BfScore]::Yellow($bytes, $stride, $bmp.Width, $bmp.Height)
    } finally { $bmp.Dispose() }
}

# Score one film: the series of (time, yellow) and the fade window inside it.
# The verdict lands in $script:score ($null when there is no fade to score).
function Score-Film($arm, $dir) {
    $script:score = $null
    $rows = @(Get-Content (Join-Path $dir 'frames.txt') | Where-Object { $_ -match '^\d' } | ForEach-Object {
        $p = $_ -split ' '
        [pscustomobject]@{ I = [int]$p[0]; T = [double]$p[1] / 10000.0; Y = [long](Measure-Yellow (Join-Path $dir ('f{0:d4}.bmp' -f [int]$p[0]))) }
    })
    if ($rows.Count -lt 3) { Assert "$arm.4 enough frames ($($rows.Count))" $false; return }
    # The display period: the shortest gap between two composed frames.
    $gaps = @(for ($i = 1; $i -lt $rows.Count; $i++) { $rows[$i].T - $rows[$i - 1].T }) | Where-Object { $_ -gt 3 } | Sort-Object
    $period = if ($gaps.Count -gt 0) { [double]$gaps[0] } else { 8.333 }
    $base = $rows[0].Y
    $final = $rows[$rows.Count - 1].Y
    $span = [Math]::Abs($final - $base)
    # Changed = moved by more than 1% of the whole fade's span.
    $tol = [Math]::Max(1, [long]($span / 100))
    $first = -1; $last = -1
    for ($i = 0; $i -lt $rows.Count; $i++) {
        if ($first -lt 0 -and [Math]::Abs($rows[$i].Y - $base) -gt $tol) { $first = $i }
        if ($first -ge 0 -and [Math]::Abs($rows[$i].Y - $final) -le $tol) { $last = $i; break }
    }
    "  frames=$($rows.Count) period_ms=$('{0:f3}' -f $period) base=$base final=$final first=$first last=$last"
    Assert "$arm.5 the film saw the frame fade in (span $span)" ($span -gt 1000 -and $first -ge 0 -and $last -ge $first)
    if (-not ($span -gt 1000 -and $first -ge 0 -and $last -ge $first)) {
        $rows | ForEach-Object { "    f$($_.I) t=$('{0:f1}' -f ($_.T - $rows[0].T)) yellow=$($_.Y)" }
        return
    }
    # The distinct values the fade put on screen, in order.
    $steps = New-Object System.Collections.Generic.List[object]
    $steps.Add($rows[$first])
    for ($i = $first + 1; $i -le $last; $i++) {
        if ([Math]::Abs($rows[$i].Y - $steps[$steps.Count - 1].Y) -gt 0) { $steps.Add($rows[$i]) }
    }
    if ($NegativeControl -and $arm -eq 'declared') {
        $kept = New-Object System.Collections.Generic.List[object]
        for ($i = 0; $i -lt $steps.Count; $i++) { if ($i % 2 -eq 0 -or $i -eq $steps.Count - 1) { $kept.Add($steps[$i]) } }
        $steps = $kept
    }
    $refreshes = [Math]::Max(1, [Math]::Round(($steps[$steps.Count - 1].T - $steps[0].T) / $period))
    $hold = 0
    for ($i = 1; $i -lt $steps.Count; $i++) { $hold = [Math]::Max($hold, [Math]::Round(($steps[$i].T - $steps[$i - 1].T) / $period)) }
    # The first visible value counts as a jump from the pre-bell picture.
    $jump = [Math]::Abs($steps[0].Y - $base)
    for ($i = 1; $i -lt $steps.Count; $i++) { $jump = [Math]::Max($jump, [Math]::Abs($steps[$i].Y - $steps[$i - 1].Y)) }
    $jumpPct = 100.0 * $jump / $span
    $advance = if ($steps.Count -gt 1) { ($steps.Count - 1) / $refreshes } else { 0 }
    $ms = $steps[$steps.Count - 1].T - $steps[0].T
    "  fade: values=$($steps.Count) over $('{0:f1}' -f $ms) ms = $refreshes refreshes; advance=$('{0:f3}' -f $advance) max_hold=$hold max_jump=$('{0:f1}' -f $jumpPct)%"
    $script:score = [pscustomobject]@{ Advance = $advance; Hold = $hold; Ms = $ms; Period = $period; JumpPct = $jumpPct }
}

[void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)
[void](Set-GhozttyTestIsolation -Tag 'bellfade')
Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null
Register-RepoBuildTeardown -Exe $Exe | Out-Null
# The input desktop, on purpose: DWM composes nothing else. Every window the
# app makes is a ghost, so nothing is shown and nothing is activated.
$td = New-TestDesktop -Interactive

$results = @{}
try {
    foreach ($arm in $Arms) {
        "== arm '$arm' (GHOZTTY_COMP_PRESENT=1, GHOZTTY_DEBUG_BELL_FADE_STEPPED=$(if ($arm -eq 'stepped') { '1' } else { 'unset' }), stall $StallMs ms)"
        [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)
        $dir = Join-Path $OutDir $arm
        if (Test-Path $dir) { Get-ChildItem $dir -File | ForEach-Object { Remove-Item $_.FullName } }
        New-Item -ItemType Directory -Force $dir | Out-Null
        $env:LOCALAPPDATA = $dir
        $env:GHOZTTY_DEBUG_GHOST = 'bottom'
        # A ghost sits under the user's windows, so the app would park its
        # renderer as occluded (T1951) after the first frame.
        $env:GHOZTTY_TEST_NO_OCCLUSION = '1'
        $env:GHOZTTY_DEBUG_BELL_FADE_STALL_MS = "$StallMs"
        $env:GHOZTTY_COMP_PRESENT = '1'
        if ($arm -eq 'stepped') { $env:GHOZTTY_DEBUG_BELL_FADE_STEPPED = '1' } else { Remove-Item env:GHOZTTY_DEBUG_BELL_FADE_STEPPED -ErrorAction SilentlyContinue }
        $err = Join-Path $dir 'stderr.txt'
        $app = Start-OnTestDesktop -Exe $Exe -Arguments @(
            '--config-default-files=false', '--session-persistence=false',
            '--window-width=100', '--window-height=30', '--background=#000000',
            '--command=powershell.exe -NoLogo', '--bell-features=border,title',
            "--title=t2469-$arm") -StdErr $err
        $top = $null
        for ($t = 0; $t -lt 100 -and -not $top; $t++) {
            $w = @([BfWin]::TopLevel([uint32]$app.Pid, 'GhozttyWindow'))
            if ($w.Count -gt 0) { $top = $w[0] } else { Start-Sleep -Milliseconds 200 }
        }
        Assert "$arm.0 the ghost window came up" ($null -ne $top)
        if (-not $top) { continue }
        & $Exe +new-window "--target=bf$arm" 2>$null | Out-Null
        $hw = $null
        for ($t = 0; $t -lt 50 -and -not $hw; $t++) {
            $hw = @([BfWin]::TopLevel([uint32]$app.Pid, 'GhozttyWindow') | Where-Object { $_ -ne $top }) | Select-Object -First 1
            if (-not $hw) { Start-Sleep -Milliseconds 200 }
        }
        Assert "$arm.1 the named window came up" ($null -ne $hw)
        if (-not $hw) { continue }
        & $Exe +split "--target=bf$arm" '--direction=right' "--name=bf$arm-2" '--shell=powershell' 2>$null | Out-Null
        Assert "$arm.2 the panes publish their overlay trees" (Wait-Log $err 'pane overlay tree published' 15000)
        Start-Sleep -Milliseconds 2500
        & $Exe +send-keys "--target=bf$arm-2" 'cls' Enter 2>$null | Out-Null
        Start-Sleep -Milliseconds 1000

        $fdir = Join-Path $dir 'film'
        $filmErr = Join-Path $dir 'film.txt'
        $filmMs = 1500 + $StallMs
        $fp = Start-Process -FilePath $Spike -ArgumentList @("--film-hwnd=$([int64]$hw)", "--film-dir=`"$fdir`"", "--film-ms=$filmMs") `
            -NoNewWindow -PassThru -RedirectStandardError $filmErr
        $ready = $false
        for ($t = 0; $t -lt 100 -and -not $ready; $t++) { $ready = Test-Path (Join-Path $fdir 'ready'); if (-not $ready) { Start-Sleep -Milliseconds 50 } }
        Assert "$arm.3 the film started" $ready
        Start-Sleep -Milliseconds 300
        # The pane's powershell evaluates [char]7 and echoes the BEL.
        & $Exe +send-keys "--target=bf$arm-2" '[char]7' Enter 2>$null | Out-Null
        [void]$fp.WaitForExit(60000)
        $filmOut = (Read-Text $filmErr).Trim()
        "  $filmOut"
        Assert "$arm.3a the film finished" ($filmOut -match '^FILM ok')
        $path = if ($arm -eq 'declared') { 'fade done alpha=255 ms=\d+ compositor=true ui_steps=0' } else { 'fade done alpha=255 ms=\d+ compositor=false ui_steps=[1-9]' }
        Assert "$arm.3b the app took the $arm path (log)" (Wait-Log $err $path 3000)
        if ($StallMs -gt 0) { Assert "$arm.3c the UI thread stalled $StallMs ms as the fade began (log)" (Wait-Log $err "bell border debug stall ms=$StallMs" 500) }

        Score-Film $arm $fdir
        $r = $script:score
        $results[$arm] = $r
        if ($r -and $arm -eq 'declared') {
            Assert "declared.6 the compositor fade advanced on every refresh (advance $('{0:f3}' -f $r.Advance) >= 0.98)" ($r.Advance -ge 0.98)
            Assert "declared.7 ... and no value was held past one refresh (max hold $($r.Hold))" ($r.Hold -le 1)
            Assert "declared.8 ... and it took about the fade's 300 ms ($('{0:f0}' -f $r.Ms) ms), not the stall's length" ($r.Ms -lt 400)
            Assert "declared.9 ... and moved in small steps (max jump $('{0:f1}' -f $r.JumpPct)% <= 15%)" ($r.JumpPct -le 15)
        }
        if ($r -and $arm -eq 'stepped' -and $StallMs -ge 100) {
            Assert "stepped.6 control: the stepped fade froze through the stall and snapped (max jump $('{0:f1}' -f $r.JumpPct)% >= 50%)" `
                ($r.JumpPct -ge 50)
        }

        $fgPid = [uint32]0
        [void][BfWin]::GetWindowThreadProcessId([BfWin]::GetForegroundWindow(), [ref]$fgPid)
        Assert "$arm.F the ghost never took the foreground (fg pid $fgPid)" ($fgPid -ne [uint32]$app.Pid)
        if (-not $KeepFrames) { Get-ChildItem $fdir -Filter 'f*.bmp' -ErrorAction SilentlyContinue | ForEach-Object { Remove-Item $_.FullName } }
    }
} finally {
    foreach ($k in $knobs) {
        if ($null -ne $saved[$k]) { Set-Item "env:$k" $saved[$k] } else { Remove-Item "env:$k" -ErrorAction SilentlyContinue }
    }
    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)
    Remove-TestDesktop | Out-Null
    $env:LOCALAPPDATA = $savedLocalAppData
}

"  films kept in $OutDir"
if ($script:failures -eq 0) { "ALL PASS ($script:passes)"; exit 0 }
"$script:failures FAILURE(S), $script:passes pass"
exit 1
