# On-screen oracle for the overlay scrollbar's compositor fade (tracker T2768,
# the live proof T2761 owes).
#
# On a pane that presents through the composition swap chain, the overlay
# scrollbar is a child visual of the pane and its fade is declared to
# DirectComposition once as a linear opacity ramp (128 ms for a full fade);
# DWM steps it at the display's refresh. Before T2761 the UI thread stepped it
# on the frame clock (32 alpha per 16 ms tick). test\win32\comp-present.ps1
# G1a-d proves the declaration from the log on the background test desktop,
# which DWM never composes. This script films it, the way
# scripts\bell-fade-onscreen.ps1 films the bell border (T2552).
#
# The app runs as a GHOST window on the input desktop (GHOZTTY_DEBUG_GHOST,
# debug builds only: never activated, bottom of the z-order), so the person at
# the desk sees nothing. ghoztty-comp-spike.exe --film-hwnd records every frame
# DWM composes of it. The right pane prints 1..400, which lights the thumb;
# one idle second later the thumb fades out, and that fade-out is what is
# scored (the text is still by then). GHOZTTY_DEBUG_SCROLLBAR_FADE_STALL_MS
# blocks the window's thread for -StallMs the moment a fade starts - the
# stand-in for a busy UI thread.
#
# Each frame is split in two at a vertical line near its right edge:
#   strip = the right-most columns, where the pane's overlay scrollbar sits
#           (the output is short numbers at the left, so nothing else moves
#           there once the output has stopped)
#   text  = everything to the left of it
# The strip is scored by its brightness (the thumb is the foreground colour
# over a black pane). The last frame whose text changed marks the end of the
# output; the fade-out is scored between the first frame after that whose
# strip differs from the lit thumb and the first one at the final value:
#
#   advance  = changed frames / refreshes the fade spanned   (>= 0.98)
#   max hold = the most refreshes one value stayed on screen   (<= 1)
#   max jump = the largest single change, as a share of the whole fade (<= 15%)
#   latency  = output end -> first faded frame (the 1 s idle delay, plus
#              whatever held the fade back)
#
# Both arms run GHOZTTY_COMP_PRESENT=1, so the strip is the same visual and
# the capture sees it. Arm 'declared' is the shipped path and must pass the
# smoothness checks through the stall. Arm 'stepped'
# (GHOZTTY_DEBUG_SCROLLBAR_FADE_STEPPED=1: the pre-T2761 UI-thread stepping) is
# the control: under a stall of 100 ms or more it must start its fade at
# least 0.6 x the stall later than the declared arm did (it froze), which is
# what shows the film can tell the two apart.
#
#   powershell -NoProfile -File scripts\scrollbar-fade-onscreen.ps1
#   powershell -NoProfile -File scripts\scrollbar-fade-onscreen.ps1 -StallMs 0
#   powershell -NoProfile -File scripts\scrollbar-fade-onscreen.ps1 -NegativeControl -Arms declared   # must go red
#
# -NegativeControl drops every other changed frame from the 'declared' film
# before it is scored (a fade at half the refresh rate): the advance and hold
# checks must fail.
#
# Run it only on an idle box (no fullscreen app): DWM starves an occluded
# ghost window under a fullscreen app (T2552), and the film is then scored on
# frames DWM never composed.

param(
    [string]$Exe = (Join-Path $PSScriptRoot '..\zig-out\bin\ghoztty.exe'),
    [string]$Spike = (Join-Path $PSScriptRoot '..\zig-out\bin\ghoztty-comp-spike.exe'),
    [string[]]$Arms = @('declared', 'stepped'),
    [int]$StallMs = 500,
    [int]$StripPx = 40,
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
. (Join-Path $testLib 'OccludedDisplay.ps1')   # T2650: a film of an occluded display is skipped, never scored
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

if (-not $OutDir) { $OutDir = Join-Path $env:TEMP "ghoztty-scrollbar-fade-$PID" }
New-Item -ItemType Directory -Force $OutDir | Out-Null
$savedLocalAppData = $env:LOCALAPPDATA
$knobs = 'GHOZTTY_COMP_PRESENT', 'GHOZTTY_DEBUG_GHOST', 'GHOZTTY_TEST_NO_OCCLUSION', 'GHOZTTY_DEBUG_SCROLLBAR_FADE_STALL_MS', 'GHOZTTY_DEBUG_SCROLLBAR_FADE_STEPPED'
$saved = @{}
foreach ($k in $knobs) { $saved[$k] = [Environment]::GetEnvironmentVariable($k) }

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class SfWin {
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
public static class SfScore {
    // Sum of r+g+b over the columns [x0, x1). The strip's sum rises with the
    // thumb's opacity; the text half's sum moves whenever the output does.
    public static long Bright(byte[] b, int stride, int h, int x0, int x1) {
        long sum = 0;
        for (int y = 0; y < h; y++) {
            int row = y * stride;
            for (int x = x0; x < x1; x++) {
                int i = row + x * 4;
                sum += b[i] + b[i + 1] + b[i + 2];
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

# One frame: (strip brightness, text brightness). The strip is the right-most
# $StripPx columns, less a 2 px frame edge.
function Measure-Frame($path) {
    $bmp = New-Object System.Drawing.Bitmap $path
    try {
        $rect = New-Object System.Drawing.Rectangle(0, 0, $bmp.Width, $bmp.Height)
        $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $bytes = New-Object byte[] ($data.Stride * $bmp.Height)
        [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $bytes.Length)
        $stride = $data.Stride
        $bmp.UnlockBits($data)
        $split = [Math]::Max(0, $bmp.Width - $StripPx)
        $edge = [Math]::Max($split, $bmp.Width - 2)
        return [pscustomobject]@{
            S = [SfScore]::Bright($bytes, $stride, $bmp.Height, $split, $edge)
            X = [SfScore]::Bright($bytes, $stride, $bmp.Height, 0, $split)
        }
    } finally { $bmp.Dispose() }
}

# Score one film. The verdict lands in $script:score ($null when there is no
# fade to score).
function Score-Film($arm, $dir) {
    $script:score = $null
    $rows = @(Get-Content (Join-Path $dir 'frames.txt') | Where-Object { $_ -match '^\d' } | ForEach-Object {
        $p = $_ -split ' '
        $m = Measure-Frame (Join-Path $dir ('f{0:d4}.bmp' -f [int]$p[0]))
        [pscustomobject]@{ I = [int]$p[0]; T = [double]$p[1] / 10000.0; S = [long]$m.S; X = [long]$m.X }
    })
    if ($rows.Count -lt 3) { Assert "$arm.4 enough frames ($($rows.Count))" $false; return }
    $gaps = @(for ($i = 1; $i -lt $rows.Count; $i++) { $rows[$i].T - $rows[$i - 1].T }) | Where-Object { $_ -gt 3 } | Sort-Object
    $period = if ($gaps.Count -gt 0) { [double]$gaps[0] } else { 8.333 }
    # The output's end: the last frame whose text half moved.
    $outEnd = -1
    for ($i = 1; $i -lt $rows.Count; $i++) { if ($rows[$i].X -ne $rows[$i - 1].X) { $outEnd = $i } }
    Assert "$arm.4 the film saw the output print and stop (last text change at frame $outEnd of $($rows.Count))" `
        ($outEnd -gt 0 -and $outEnd -lt $rows.Count - 3)
    if (-not ($outEnd -gt 0 -and $outEnd -lt $rows.Count - 3)) { return }
    $base = $rows[$outEnd].S
    $final = $rows[$rows.Count - 1].S
    $span = [Math]::Abs($final - $base)
    $tol = [Math]::Max(1, [long]($span / 100))
    $first = -1; $last = -1
    for ($i = $outEnd + 1; $i -lt $rows.Count; $i++) {
        if ($first -lt 0 -and [Math]::Abs($rows[$i].S - $base) -gt $tol) { $first = $i }
        if ($first -ge 0 -and [Math]::Abs($rows[$i].S - $final) -le $tol) { $last = $i; break }
    }
    "  frames=$($rows.Count) period_ms=$('{0:f3}' -f $period) out_end=$outEnd lit=$base final=$final first=$first last=$last"
    $saw = ($span -gt 1000 -and $final -lt $base -and $first -ge 0 -and $last -ge $first)
    Assert "$arm.5 the film saw the lit thumb fade out (span $span)" $saw
    if (-not $saw) {
        $rows | ForEach-Object { "    f$($_.I) t=$('{0:f1}' -f ($_.T - $rows[0].T)) strip=$($_.S) text=$($_.X)" }
        return
    }
    $steps = New-Object System.Collections.Generic.List[object]
    $steps.Add($rows[$first])
    for ($i = $first + 1; $i -le $last; $i++) {
        if ([Math]::Abs($rows[$i].S - $steps[$steps.Count - 1].S) -gt 0) { $steps.Add($rows[$i]) }
    }
    if ($NegativeControl -and $arm -eq 'declared') {
        $kept = New-Object System.Collections.Generic.List[object]
        for ($i = 0; $i -lt $steps.Count; $i++) { if ($i % 2 -eq 0 -or $i -eq $steps.Count - 1) { $kept.Add($steps[$i]) } }
        $steps = $kept
    }
    $refreshes = [Math]::Max(1, [Math]::Round(($steps[$steps.Count - 1].T - $steps[0].T) / $period))
    $hold = 0
    for ($i = 1; $i -lt $steps.Count; $i++) { $hold = [Math]::Max($hold, [Math]::Round(($steps[$i].T - $steps[$i - 1].T) / $period)) }
    $jump = [Math]::Abs($steps[0].S - $base)
    for ($i = 1; $i -lt $steps.Count; $i++) { $jump = [Math]::Max($jump, [Math]::Abs($steps[$i].S - $steps[$i - 1].S)) }
    $jumpPct = 100.0 * $jump / $span
    $advance = if ($steps.Count -gt 1) { ($steps.Count - 1) / $refreshes } else { 0 }
    $ms = $steps[$steps.Count - 1].T - $steps[0].T
    $latency = $rows[$first].T - $rows[$outEnd].T
    "  fade: values=$($steps.Count) over $('{0:f1}' -f $ms) ms = $refreshes refreshes; advance=$('{0:f3}' -f $advance) max_hold=$hold max_jump=$('{0:f1}' -f $jumpPct)% latency=$('{0:f0}' -f $latency) ms"
    $script:score = [pscustomobject]@{ Advance = $advance; Hold = $hold; Ms = $ms; Period = $period; JumpPct = $jumpPct; Latency = $latency }
}

[void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)
[void](Set-GhozttyTestIsolation -Tag 'scrollfade')
Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null
Register-RepoBuildTeardown -Exe $Exe | Out-Null
# The input desktop, on purpose: DWM composes nothing else. Every window the
# app makes is a ghost, so nothing is shown and nothing is activated.
$td = New-TestDesktop -Interactive

$results = @{}
try {
    foreach ($arm in $Arms) {
        "== arm '$arm' (GHOZTTY_COMP_PRESENT=1, GHOZTTY_DEBUG_SCROLLBAR_FADE_STEPPED=$(if ($arm -eq 'stepped') { '1' } else { 'unset' }), stall $StallMs ms)"
        [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)
        $dir = Join-Path $OutDir $arm
        if (Test-Path $dir) { Get-ChildItem $dir -File | ForEach-Object { Remove-Item $_.FullName } }
        New-Item -ItemType Directory -Force $dir | Out-Null
        $env:LOCALAPPDATA = $dir
        $env:GHOZTTY_DEBUG_GHOST = 'bottom'
        # A ghost sits under the user's windows, so the app would park its
        # renderer as occluded (T1951) after the first frame.
        $env:GHOZTTY_TEST_NO_OCCLUSION = '1'
        $env:GHOZTTY_DEBUG_SCROLLBAR_FADE_STALL_MS = "$StallMs"
        $env:GHOZTTY_COMP_PRESENT = '1'
        if ($arm -eq 'stepped') { $env:GHOZTTY_DEBUG_SCROLLBAR_FADE_STEPPED = '1' } else { Remove-Item env:GHOZTTY_DEBUG_SCROLLBAR_FADE_STEPPED -ErrorAction SilentlyContinue }
        $err = Join-Path $dir 'stderr.txt'
        $app = Start-OnTestDesktop -Exe $Exe -Arguments @(
            '--config-default-files=false', '--session-persistence=false',
            '--window-width=100', '--window-height=30', '--background=#000000',
            '--cursor-style-blink=false',
            '--command=powershell.exe -NoLogo', "--title=t2768-$arm") -StdErr $err
        $top = $null
        for ($t = 0; $t -lt 100 -and -not $top; $t++) {
            $w = @([SfWin]::TopLevel([uint32]$app.Pid, 'GhozttyWindow'))
            if ($w.Count -gt 0) { $top = $w[0] } else { Start-Sleep -Milliseconds 200 }
        }
        Assert "$arm.0 the ghost window came up" ($null -ne $top)
        if (-not $top) { continue }
        & $Exe +new-window "--target=sf$arm" 2>$null | Out-Null
        $hw = $null
        for ($t = 0; $t -lt 50 -and -not $hw; $t++) {
            $hw = @([SfWin]::TopLevel([uint32]$app.Pid, 'GhozttyWindow') | Where-Object { $_ -ne $top }) | Select-Object -First 1
            if (-not $hw) { Start-Sleep -Milliseconds 200 }
        }
        Assert "$arm.1 the named window came up" ($null -ne $hw)
        if (-not $hw) { continue }
        & $Exe +split "--target=sf$arm" '--direction=right' "--name=sf$arm-2" '--shell=powershell' 2>$null | Out-Null
        Assert "$arm.2 the panes publish their overlay trees" (Wait-Log $err 'pane overlay tree published' 15000)
        Start-Sleep -Milliseconds 2500
        & $Exe +send-keys "--target=sf$arm-2" 'cls' Enter 2>$null | Out-Null
        Start-Sleep -Milliseconds 1000
        # A first print gives the pane scrollback and lets its fade-in and
        # idle fade-out run once before the film, so the filmed one is the
        # steady case.
        & $Exe +send-keys "--target=sf$arm-2" '1..400' Enter 2>$null | Out-Null
        [void](Wait-Log $err 'scrollbar fade done fade=0 ' (4000 + 2 * $StallMs))

        $fdir = Join-Path $dir 'film'
        $filmErr = Join-Path $dir 'film.txt'
        $filmMs = 2600 + 2 * $StallMs
        $fp = Start-Process -FilePath $Spike -ArgumentList @("--film-hwnd=$([int64]$hw)", "--film-dir=`"$fdir`"", "--film-ms=$filmMs") `
            -NoNewWindow -PassThru -RedirectStandardError $filmErr
        $ready = $false
        for ($t = 0; $t -lt 100 -and -not $ready; $t++) { $ready = Test-Path (Join-Path $fdir 'ready'); if (-not $ready) { Start-Sleep -Milliseconds 50 } }
        Assert "$arm.3 the film started" $ready
        Start-Sleep -Milliseconds 300
        $doneBefore = ([regex]::Matches((Read-Text $err), 'scrollbar fade done fade=0 ')).Count
        & $Exe +send-keys "--target=sf$arm-2" '1..400' Enter 2>$null | Out-Null
        [void]$fp.WaitForExit(60000)
        $filmOut = (Read-Text $filmErr).Trim()
        "  $filmOut"
        Assert "$arm.3a the film finished" ($filmOut -match '^FILM ok')
        $path = if ($arm -eq 'declared') { 'scrollbar fade done fade=0 ms=\d+ compositor=true ui_steps=0' } else { 'scrollbar fade done fade=0 ms=\d+ compositor=false ui_steps=[1-9]' }
        $doneAfter = 0
        for ($t = 0; $t -lt 30 -and $doneAfter -le $doneBefore; $t++) {
            $doneAfter = ([regex]::Matches((Read-Text $err), 'scrollbar fade done fade=0 ')).Count
            if ($doneAfter -le $doneBefore) { Start-Sleep -Milliseconds 100 }
        }
        Assert "$arm.3b the filmed fade-out ended inside the film ($doneBefore -> $doneAfter done lines)" ($doneAfter -gt $doneBefore)
        Assert "$arm.3c the app took the $arm path (log)" (Wait-Log $err $path 500)
        if ($StallMs -gt 0) { Assert "$arm.3d the UI thread stalled $StallMs ms as the fade began (log)" (Wait-Log $err "scrollbar debug stall ms=$StallMs" 500) }

        Score-Film $arm $fdir
        $r = $script:score
        $results[$arm] = $r
        if ($r -and $arm -eq 'declared') {
            Assert "declared.6 the compositor fade advanced on every refresh (advance $('{0:f3}' -f $r.Advance) >= 0.98)" ($r.Advance -ge 0.98)
            Assert "declared.7 ... and no value was held past one refresh (max hold $($r.Hold))" ($r.Hold -le 1)
            Assert "declared.8 ... and it took about the fade's 128 ms ($('{0:f0}' -f $r.Ms) ms), not the stall's length" ($r.Ms -lt 250)
            Assert "declared.9 ... and moved in small steps (max jump $('{0:f1}' -f $r.JumpPct)% <= 15%)" ($r.JumpPct -le 15)
        }

        $fgPid = [uint32]0
        [void][SfWin]::GetWindowThreadProcessId([SfWin]::GetForegroundWindow(), [ref]$fgPid)
        Assert "$arm.F the ghost never took the foreground (fg pid $fgPid)" ($fgPid -ne [uint32]$app.Pid)
        if (-not $KeepFrames) { Get-ChildItem $fdir -Filter 'f*.bmp' -ErrorAction SilentlyContinue | ForEach-Object { Remove-Item $_.FullName } }
    }
    # The control: a stepped fade waits out the stall before its first step;
    # the declared one is already moving on the compositor.
    $d = $results['declared']; $s = $results['stepped']
    if ($d -and $s -and $StallMs -ge 100) {
        $lag = $s.Latency - $d.Latency
        Assert "stepped.6 control: the stepped fade froze through the stall (started $('{0:f0}' -f $lag) ms after the declared one; >= $([int](0.6 * $StallMs)))" `
            ($lag -ge 0.6 * $StallMs)
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
Exit-IfOccludedDisplay -Root $OutDir
if ($script:failures -eq 0) { "ALL PASS ($script:passes)"; exit 0 }
"$script:failures FAILURE(S), $script:passes pass"
exit 1
