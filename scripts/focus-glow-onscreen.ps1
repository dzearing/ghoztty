# On-screen oracle for the focus glow fading on the compositor (tracker T2627,
# the on-screen half of T2574).
#
# With the desk on the chrome host's visual (GHOZTTY_COMP_CHROME=1) the lit
# pane's glow goes up as its own premultiplied layer, and a focus move is one
# opacity animation per layer declared to DirectComposition; DWM steps it at
# the display's refresh. test\win32\focus-glow-comp.ps1 proves the declaration
# from the log on the background test desktop, which DWM never composes, and
# the unit test in PaneDesk.zig proves the layer's pixels. What neither can
# see is the picture on screen. This script films it.
#
# Same technique as bell-fade-onscreen.ps1 (T2469): the app runs as a GHOST
# window on the input desktop (GHOZTTY_DEBUG_GHOST=bottom, debug builds only:
# never activated, bottom of the z-order), so the person at the desk sees
# nothing; ghoztty-comp-spike.exe --film-hwnd records every frame DWM composes
# of it. The window is split three ways (b, then c under b; c is lit), and the
# glow is moved c -> b by the debug build's focus link while the film runs.
# GHOZTTY_DEBUG_GLOW_FADE_STALL_MS blocks the window's thread for -StallMs
# right after the move's first tick - the stand-in for a busy UI thread.
#
# Every pane runs a shell that clears the screen and hides its cursor, and
# unfocused panes are not dimmed, so the only thing a focus move changes on
# screen is the glow. Each frame is then scored by its distance from the
# frame before the move (the sum of every channel's difference): a layer at
# level L over the desk is lerp(desk, lit, L) per pixel, so the score is the
# fade's level times a constant, whatever the glow's colour.
#
# Arms (both GHOZTTY_COMP_CHROME=1):
#   - comp:    the shipped path. The fade advances on every refresh through
#              the stall (advance >= 0.98, no value held past one refresh,
#              done in about the fade's 250 ms, small steps).
#   - stepped: GHOZTTY_DEBUG_GLOW_STEPPED=1 - the glow stays in the desk and
#              is stepped on the UI thread, the pre-T2574 way. Control: it
#              must FREEZE through the stall and snap (a jump of at least half
#              the fade).
# And at rest: the comp arm's last frame (the glow faded in on b, out on c)
# matches the stepped arm's last frame - the window's own glow - to within
# rounding.
#
#   powershell -NoProfile -File scripts\focus-glow-onscreen.ps1
#   powershell -NoProfile -File scripts\focus-glow-onscreen.ps1 -StallMs 0
#   powershell -NoProfile -File scripts\focus-glow-onscreen.ps1 -NegativeControl   # must go red
#
# -NegativeControl drops every other changed frame from the comp film before it
# is scored (a fade at half the refresh rate), and scores the stepped arm's
# FIRST frame against the comp arm's last as the rest match (a glow that never
# moved): the advance, hold and match checks must fail.

param(
    [string]$Exe = (Join-Path $PSScriptRoot '..\zig-out\bin\ghoztty.exe'),
    [string]$Spike = (Join-Path $PSScriptRoot '..\zig-out\bin\ghoztty-comp-spike.exe'),
    [string[]]$Arms = @('comp', 'stepped'),
    [int]$StallMs = 500,
    [string]$OutDir,
    # Pixels whose largest channel differs by more than this count as differing.
    [int]$Tolerance = 12,
    # The share of the frame allowed to differ at rest.
    [double]$MaxDiffShare = 0.002,
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

if (-not $OutDir) { $OutDir = Join-Path $env:TEMP "ghoztty-glow-film-$PID" }
New-Item -ItemType Directory -Force $OutDir | Out-Null
$savedLocalAppData = $env:LOCALAPPDATA
$knobs = 'GHOZTTY_COMP_CHROME', 'GHOZTTY_DEBUG_GHOST', 'GHOZTTY_TEST_NO_OCCLUSION', 'GHOZTTY_DEBUG_GLOW_FADE_STALL_MS', 'GHOZTTY_DEBUG_GLOW_STEPPED'
$saved = @{}
foreach ($k in $knobs) { $saved[$k] = [Environment]::GetEnvironmentVariable($k) }

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class GfWin {
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
public static class GfScore {
    // Sum over B, G and R of |a - b|: linear in a layer's level over the desk.
    public static long Dist(byte[] a, byte[] b, int stride, int w, int h) {
        long sum = 0;
        for (int y = 0; y < h; y++) {
            int row = y * stride;
            for (int x = 0; x < w; x++) {
                int i = row + x * 4;
                sum += Math.Abs(a[i] - b[i]) + Math.Abs(a[i + 1] - b[i + 1]) + Math.Abs(a[i + 2] - b[i + 2]);
            }
        }
        return sum;
    }
    // Pixels whose largest channel differs by more than tol.
    public static int Diff(byte[] a, byte[] b, int stride, int w, int h, int tol) {
        int n = 0;
        for (int y = 0; y < h; y++) {
            int row = y * stride;
            for (int x = 0; x < w; x++) {
                int i = row + x * 4;
                int d = Math.Max(Math.Abs(a[i] - b[i]), Math.Max(Math.Abs(a[i + 1] - b[i + 1]), Math.Abs(a[i + 2] - b[i + 2])));
                if (d > tol) n++;
            }
        }
        return n;
    }
}
'@

function Read-Text($path) {
    if (Test-Path $path) { return [string](Get-Content $path -Raw -ErrorAction SilentlyContinue) }
    return ''
}
# The log from character $from on: the filmed move's lines, not the setup's.
function Read-From($path, $from) {
    $s = Read-Text $path
    if ($s.Length -le $from) { return '' }
    return $s.Substring($from)
}
function Wait-LogFrom($path, $from, $pattern, $ms) {
    $deadline = (Get-Date).AddMilliseconds($ms)
    do {
        if ((Read-From $path $from) -match $pattern) { return $true }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)
    return $false
}
function Wait-Log($path, $pattern, $ms) {
    $deadline = (Get-Date).AddMilliseconds($ms)
    do {
        if ((Read-Text $path) -match $pattern) { return $true }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Get-Pixels($path) {
    $bmp = New-Object System.Drawing.Bitmap $path
    try {
        $rect = New-Object System.Drawing.Rectangle(0, 0, $bmp.Width, $bmp.Height)
        $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $bytes = New-Object byte[] ($data.Stride * $bmp.Height)
        [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $bytes.Length)
        $o = [pscustomobject]@{ W = $bmp.Width; H = $bmp.Height; Stride = $data.Stride; B = $bytes }
        $bmp.UnlockBits($data)
        return $o
    } finally { $bmp.Dispose() }
}

# Score one film: the series of (time, distance from the first frame) and the
# fade window inside it. The verdict lands in $script:score ($null when there
# is no fade to score); the first and last frames' pixels in $script:ends.
function Score-Film($arm, $dir) {
    $script:score = $null
    $script:ends = $null
    $list = @(Get-Content (Join-Path $dir 'frames.txt') | Where-Object { $_ -match '^\d' })
    if ($list.Count -lt 3) { Assert "$arm.4 enough frames ($($list.Count))" $false; return }
    $first0 = Get-Pixels (Join-Path $dir ('f{0:d4}.bmp' -f [int](($list[0] -split ' ')[0])))
    $rows = @(foreach ($line in $list) {
        $p = $line -split ' '
        $px = Get-Pixels (Join-Path $dir ('f{0:d4}.bmp' -f [int]$p[0]))
        $d = if ($px.W -eq $first0.W -and $px.H -eq $first0.H) { [GfScore]::Dist($first0.B, $px.B, $px.Stride, $px.W, $px.H) } else { -1 }
        [pscustomobject]@{ I = [int]$p[0]; T = [double]$p[1] / 10000.0; Y = [long]$d; Px = $px }
    })
    Assert "$arm.4 every frame is the window's size ($($first0.W)x$($first0.H))" (@($rows | Where-Object { $_.Y -lt 0 }).Count -eq 0)
    $script:ends = [pscustomobject]@{ First = $rows[0].Px; Last = $rows[$rows.Count - 1].Px }
    $gaps = @(for ($i = 1; $i -lt $rows.Count; $i++) { $rows[$i].T - $rows[$i - 1].T }) | Where-Object { $_ -gt 3 } | Sort-Object
    $period = if ($gaps.Count -gt 0) { [double]$gaps[0] } else { 8.333 }
    $base = $rows[0].Y
    $final = $rows[$rows.Count - 1].Y
    $span = [Math]::Abs($final - $base)
    $tol = [Math]::Max(1, [long]($span / 100))
    $first = -1; $last = -1
    for ($i = 0; $i -lt $rows.Count; $i++) {
        if ($first -lt 0 -and [Math]::Abs($rows[$i].Y - $base) -gt $tol) { $first = $i }
        if ($first -ge 0 -and [Math]::Abs($rows[$i].Y - $final) -le $tol) { $last = $i; break }
    }
    "  frames=$($rows.Count) period_ms=$('{0:f3}' -f $period) span=$span first=$first last=$last"
    $seen = ($span -gt 20000 -and $first -ge 0 -and $last -ge $first)
    Assert "$arm.5 the film saw the glow move (span $span)" $seen
    if (-not $seen) {
        $rows | ForEach-Object { "    f$($_.I) t=$('{0:f1}' -f ($_.T - $rows[0].T)) dist=$($_.Y)" }
        return
    }
    $steps = New-Object System.Collections.Generic.List[object]
    $steps.Add($rows[$first])
    for ($i = $first + 1; $i -le $last; $i++) {
        if ([Math]::Abs($rows[$i].Y - $steps[$steps.Count - 1].Y) -gt 0) { $steps.Add($rows[$i]) }
    }
    if ($NegativeControl -and $arm -eq 'comp') {
        $kept = New-Object System.Collections.Generic.List[object]
        for ($i = 0; $i -lt $steps.Count; $i++) { if ($i % 2 -eq 0 -or $i -eq $steps.Count - 1) { $kept.Add($steps[$i]) } }
        $steps = $kept
    }
    $refreshes = [Math]::Max(1, [Math]::Round(($steps[$steps.Count - 1].T - $steps[0].T) / $period))
    $hold = 0
    for ($i = 1; $i -lt $steps.Count; $i++) { $hold = [Math]::Max($hold, [Math]::Round(($steps[$i].T - $steps[$i - 1].T) / $period)) }
    $jump = [Math]::Abs($steps[0].Y - $base)
    for ($i = 1; $i -lt $steps.Count; $i++) { $jump = [Math]::Max($jump, [Math]::Abs($steps[$i].Y - $steps[$i - 1].Y)) }
    $jumpPct = 100.0 * $jump / $span
    $advance = if ($steps.Count -gt 1) { ($steps.Count - 1) / $refreshes } else { 0 }
    $ms = $steps[$steps.Count - 1].T - $steps[0].T
    "  fade: values=$($steps.Count) over $('{0:f1}' -f $ms) ms = $refreshes refreshes; advance=$('{0:f3}' -f $advance) max_hold=$hold max_jump=$('{0:f1}' -f $jumpPct)%"
    if ($steps.Count -le 40) { "    " + (($steps | ForEach-Object { '{0:f0}' -f (100.0 * [Math]::Abs($_.Y - $base) / $span) }) -join ' ') }
    $script:score = [pscustomobject]@{ Advance = $advance; Hold = $hold; Ms = $ms; Period = $period; JumpPct = $jumpPct }
}

[void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)
[void](Set-GhozttyTestIsolation -Tag 'glowfilm')
Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null
Register-RepoBuildTeardown -Exe $Exe | Out-Null
# The input desktop, on purpose: DWM composes nothing else. Every window the
# app makes is a ghost, so nothing is shown and nothing is activated.
$td = New-TestDesktop -Interactive

# The panes' shell: clear, hide the cursor (a focus move would otherwise swap
# a hollow cursor for a solid one in two panes - a change the glow fade does
# not make), and wait.
$shell = Join-Path $OutDir 'quiet.ps1'
Set-Content -Path $shell -Encoding ascii -Value @'
Clear-Host
[Console]::CursorVisible = $false
Start-Sleep -Seconds 3600
'@
$cmd = "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $shell"

$results = @{}
$armEnds = @{}
try {
    foreach ($arm in $Arms) {
        "== arm '$arm' (GHOZTTY_COMP_CHROME=1, GHOZTTY_DEBUG_GLOW_STEPPED=$(if ($arm -eq 'stepped') { '1' } else { 'unset' }), stall $StallMs ms)"
        [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)
        $dir = Join-Path $OutDir $arm
        if (Test-Path $dir) { Get-ChildItem $dir -File | ForEach-Object { Remove-Item $_.FullName } }
        New-Item -ItemType Directory -Force $dir | Out-Null
        $env:LOCALAPPDATA = $dir
        $env:GHOZTTY_DEBUG_GHOST = 'bottom'
        # A ghost sits under the user's windows, so the app would park its
        # renderer as occluded (T1951) after the first frame.
        $env:GHOZTTY_TEST_NO_OCCLUSION = '1'
        $env:GHOZTTY_DEBUG_GLOW_FADE_STALL_MS = "$StallMs"
        $env:GHOZTTY_COMP_CHROME = '1'
        if ($arm -eq 'stepped') { $env:GHOZTTY_DEBUG_GLOW_STEPPED = '1' } else { Remove-Item env:GHOZTTY_DEBUG_GLOW_STEPPED -ErrorAction SilentlyContinue }
        $err = Join-Path $dir 'stderr.txt'
        $app = Start-OnTestDesktop -Exe $Exe -Arguments @(
            '--config-default-files=false', '--session-persistence=false',
            '--window-width=110', '--window-height=30', '--background=#101418',
            '--cursor-style-blink=false', '--unfocused-split-opacity=1',
            "--command=$cmd", "--title=t2627-$arm") -StdErr $err
        $top = $null
        for ($t = 0; $t -lt 100 -and -not $top; $t++) {
            $w = @([GfWin]::TopLevel([uint32]$app.Pid, 'GhozttyWindow'))
            if ($w.Count -gt 0) { $top = $w[0] } else { Start-Sleep -Milliseconds 200 }
        }
        Assert "$arm.0 the ghost window came up" ($null -ne $top)
        if (-not $top) { continue }
        $target = "gf$arm"
        & $Exe +new-window "--target=$target" 2>$null | Out-Null
        $hw = $null
        for ($t = 0; $t -lt 50 -and -not $hw; $t++) {
            $hw = @([GfWin]::TopLevel([uint32]$app.Pid, 'GhozttyWindow') | Where-Object { $_ -ne $top }) | Select-Object -First 1
            if (-not $hw) { Start-Sleep -Milliseconds 200 }
        }
        Assert "$arm.1 the named window came up" ($null -ne $hw)
        if (-not $hw) { continue }
        & $Exe +split "--target=$target" '--direction=right' "--name=${target}b" "--command=$cmd" 2>$null | Out-Null
        Start-Sleep -Milliseconds 900
        & $Exe +split "--pane=${target}b" '--direction=down' "--name=${target}c" "--command=$cmd" 2>$null | Out-Null
        Assert "$arm.2 the desk went up as the chrome host's visual" (Wait-Log $err 'chrome desk visual attached' 15000)
        Start-Sleep -Milliseconds 900
        # A split on a ghost does not move focus to the new pane, so light c
        # by hand: the filmed move is then c -> b, one layer in, one out.
        & $Exe "ghoztty-debug://focus/${target}c" 2>&1 | Out-Null
        Assert "$arm.2b the glow went to c before the film" (Wait-Log $err "IPC: focused '${target}c'" 5000)
        # The shells clear and hide their cursors, and that glow move runs
        # out, before the film starts.
        Start-Sleep -Milliseconds 2500
        $mark = (Read-Text $err).Length

        $fdir = Join-Path $dir 'film'
        $filmErr = Join-Path $dir 'film.txt'
        $filmMs = 2500 + $StallMs
        $fp = Start-Process -FilePath $Spike -ArgumentList @("--film-hwnd=$([int64]$hw)", "--film-dir=`"$fdir`"", "--film-ms=$filmMs") `
            -NoNewWindow -PassThru -RedirectStandardError $filmErr
        $ready = $false
        for ($t = 0; $t -lt 100 -and -not $ready; $t++) { $ready = Test-Path (Join-Path $fdir 'ready'); if (-not $ready) { Start-Sleep -Milliseconds 50 } }
        Assert "$arm.3 the film started" $ready
        Start-Sleep -Milliseconds 300
        # The debug build's scheme (url-scheme.ps1): a client that forwards a
        # `focus` over the run's pipe and exits. The glow moves c -> b.
        & $Exe "ghoztty-debug://focus/${target}b" 2>&1 | Out-Null
        [void]$fp.WaitForExit(60000)
        $filmOut = (Read-Text $filmErr).Trim()
        "  $filmOut"
        Assert "$arm.3a the film finished" ($filmOut -match '^FILM ok')
        if ($arm -eq 'comp') {
            Assert "comp.3b the move was declared on the compositor (two layers: b in, c out)" (Wait-LogFrom $err $mark 'focus glow fade on the compositor layers=2' 3000)
            Assert "comp.3c ... and ran out with no desk upload" (Wait-LogFrom $err $mark 'focus glow fade on the compositor done desk_uploads=0' 3000)
        } else {
            Assert "stepped.3b control: no fade was declared on the compositor" ((Read-From $err $mark) -notmatch 'focus glow fade on the compositor')
        }
        if ($StallMs -gt 0) {
            $decl = if ($arm -eq 'comp') { 'true' } else { 'false' }
            Assert "$arm.3d the UI thread stalled $StallMs ms after the move's first tick (log)" (Wait-LogFrom $err $mark "focus glow debug stall ms=$StallMs declared=$decl" 1000)
        }
        Assert "$arm.3e no glow layer step failed" ((Read-Text $err) -notmatch 'focus glow layer \w+ failed')

        Score-Film $arm $fdir
        $r = $script:score
        $results[$arm] = $r
        $armEnds[$arm] = $script:ends
        if ($r -and $arm -eq 'comp') {
            Assert "comp.6 the compositor fade advanced on every refresh (advance $('{0:f3}' -f $r.Advance) >= 0.98)" ($r.Advance -ge 0.98)
            Assert "comp.7 ... and no value was held past one refresh (max hold $($r.Hold))" ($r.Hold -le 1)
            Assert "comp.8 ... and it took about the fade's 250 ms ($('{0:f0}' -f $r.Ms) ms), not the stall's length" ($r.Ms -lt 350)
            Assert "comp.9 ... and moved in small steps (max jump $('{0:f1}' -f $r.JumpPct)% <= 15%)" ($r.JumpPct -le 15)
        }
        if ($r -and $arm -eq 'stepped' -and $StallMs -ge 100) {
            Assert "stepped.6 control: the stepped fade froze through the stall and snapped (max jump $('{0:f1}' -f $r.JumpPct)% >= 50%)" `
                ($r.JumpPct -ge 50)
        }

        $fgPid = [uint32]0
        [void][GfWin]::GetWindowThreadProcessId([GfWin]::GetForegroundWindow(), [ref]$fgPid)
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

# At rest: the faded-in compositor glow against the window's own (stepped)
# glow. Under -NegativeControl the stepped arm's FIRST frame stands in - the
# glow still on c - so the match must fail.
if ($armEnds['comp'] -and $armEnds['stepped']) {
    $g = $armEnds['comp'].Last
    $ref = if ($NegativeControl) { $armEnds['stepped'].First } else { $armEnds['stepped'].Last }
    if ($g.W -ne $ref.W -or $g.H -ne $ref.H) {
        Assert "match.0 the arms' frames are the same size ($($g.W)x$($g.H) vs $($ref.W)x$($ref.H))" $false
    } else {
        $total = $g.W * $g.H
        $moved = [GfScore]::Diff($armEnds['stepped'].First.B, $armEnds['stepped'].Last.B, $g.Stride, $g.W, $g.H, $Tolerance)
        "  stepped before vs after the move: differing=$moved"
        Assert "match.1 the move changes the window's own picture (positive control: $moved px)" ($moved -gt 200)
        $diff = [GfScore]::Diff($ref.B, $g.B, $g.Stride, $g.W, $g.H, $Tolerance)
        "  comp vs stepped at rest: $($g.W)x$($g.H) differing=$diff ($('{0:P2}' -f ($diff / [double]$total)))"
        Assert "match.2 the faded-in compositor glow matches the window's own glow (<= $('{0:P1}' -f $MaxDiffShare) differ by > $Tolerance)" ($diff -le $total * $MaxDiffShare)
    }
} elseif ($Arms -contains 'comp' -and $Arms -contains 'stepped') {
    Assert "match.0 both arms filmed" $false
}

"  films kept in $OutDir"
Exit-IfOccludedDisplay -Root $OutDir
if ($script:failures -eq 0) { "ALL PASS ($script:passes)"; exit 0 }
"$script:failures FAILURE(S), $script:passes pass"
exit 1
