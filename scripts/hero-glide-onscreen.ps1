# On-screen oracle for the hero selection slide on the compositor (tracker T2573).
#
# In hero mode one pane is the hero and the rest sit in the carousel; picking
# another slides the outgoing pane's picture out and the incoming one in, one
# strip slot, over HERO_SLIDE_MS (Mac PaneStage hero glide). Until T2573 the
# window's thread painted every frame of that slide (HeroCarousel.paintSlide,
# a 16 ms tick), so a busy thread froze it mid-way. In the composition pane
# tree (GHOZTTY_COMP_PRESENT + GHOZTTY_COMP_CHROME + GHOZTTY_COMP_PANE_TREE)
# the two pictures now go to DirectComposition once and their offsets run the
# same ease on DWM's clock (Window.declareHeroSlide).
#
# The app runs as a GHOST window on the input desktop (GHOZTTY_DEBUG_GHOST=
# bottom, debug builds only: never activated, bottom of the z-order) and
# ghoztty-comp-spike.exe --film-hwnd records every frame DWM composes of it.
# Nothing is shown to the person at the desk and nothing takes the focus: the
# hero toggle and the selection are POSTED key messages (F9 / F7, bound with
# --keybind), so the real keyboard is never touched.
#
# Layout: two panes side by side, each painted with a solid block (red, blue),
# then hero mode with the red pane as the hero. F7 selects the next pane: red
# slides out, blue slides in. The hero region is scored (the carousel's own
# thumbnails of the same blocks lie right of it and are cut off).
#
# Arms:
#   tree   the composition pane tree; the slide is declared to the compositor
#   stall  tree, with the window's thread blocked -StallMs at the slide's first
#          tick (GHOZTTY_DEBUG_HERO_STALL_MS, debug builds)
#   off    no composition knobs: the GDI-painted slide, the frame-match control
# Per arm:
#   .5 glide: the incoming block is seen at 2+ distinct heights on the way
#   .6 rest:  before and after, one block on show in the hero region
#   .6m       (tree/stall) the landing rests where `off` lands, to 2 px
#   .6b       (tree/stall) the rest BEFORE the slide matches `off` too, to 2 px:
#             the hero picture is not stretched after entering hero mode
#             (T2641, fixed by T2625's 1:1 source transform)
#   .10 (stall) the incoming block's longest still stretch on the way is under
#             a quarter of the stall
#   .11 (tree/stall) the app declared the slide ("hero slide declared"); 0
#             declared under -NoDeclare
#   .F  the ghost never took the foreground
#
#   powershell -NoProfile -File scripts\hero-glide-onscreen.ps1
#   powershell -NoProfile -File scripts\hero-glide-onscreen.ps1 -Arms stall -NoDeclare   # stall.10 must go red
# -NoDeclare sets GHOZTTY_HERO_DECLARE=0: the window's thread paints the slide
# again, as before T2573.

param(
    [string]$Exe = (Join-Path $PSScriptRoot '..\zig-out\bin\ghoztty.exe'),
    [string]$Spike = (Join-Path $PSScriptRoot '..\zig-out\bin\ghoztty-comp-spike.exe'),
    [string[]]$Arms = @('off', 'tree', 'stall'),
    [int]$StallMs = 500,
    [string]$OutDir,
    [switch]$KeepFrames,
    [switch]$NoDeclare
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

if (-not $OutDir) { $OutDir = Join-Path $env:TEMP "ghoztty-hero-glide-$PID" }
New-Item -ItemType Directory -Force $OutDir | Out-Null
$savedLocalAppData = $env:LOCALAPPDATA
$knobs = 'GHOZTTY_COMP_PRESENT', 'GHOZTTY_COMP_CHROME', 'GHOZTTY_COMP_PANE_TREE', 'GHOZTTY_DEBUG_GHOST', 'GHOZTTY_TEST_NO_OCCLUSION', 'GHOZTTY_DEBUG_HERO_STALL_MS', 'GHOZTTY_HERO_DECLARE'
$saved = @{}
foreach ($k in $knobs) { $saved[$k] = [Environment]::GetEnvironmentVariable($k) }

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class HgWin {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr p, EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int ht, uint flags);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
    static string Cls(IntPtr h) { var sb = new System.Text.StringBuilder(64); GetClassName(h, sb, 64); return sb.ToString(); }
    public static IntPtr[] TopLevel(uint pid, string cls) {
        var list = new List<IntPtr>();
        EnumWindows((h, l) => {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p == pid && IsWindowVisible(h) && Cls(h) == cls) list.Add(h);
            return true;
        }, IntPtr.Zero);
        return list.ToArray();
    }
    public static string[] Panes(IntPtr top) {
        var list = new List<string>();
        EnumChildWindows(top, (h, l) => {
            if (Cls(h) == "GhozttyTerminal") {
                RECT r; GetWindowRect(h, out r);
                list.Add(((long)h) + " " + r.Left + " " + r.Top + " " + r.Right + " " + r.Bottom + " " + (IsWindowVisible(h) ? 1 : 0));
            }
            return true;
        }, IntPtr.Zero);
        return list.ToArray();
    }
    public static bool Size(IntPtr h, int w, int ht) {
        return SetWindowPos(h, IntPtr.Zero, 0, 0, w, ht, 0x0002 | 0x0004 | 0x0010); // NOMOVE|NOZORDER|NOACTIVATE
    }
    // A key press, posted to one window: no SendInput, nothing the person at
    // the desk can feel.
    public static void Key(IntPtr h, int vk, int scan) {
        PostMessageW(h, 0x0100, (IntPtr)vk, (IntPtr)(1 | (scan << 16)));
        System.Threading.Thread.Sleep(30);
        PostMessageW(h, 0x0101, (IntPtr)vk, (IntPtr)(1 | (scan << 16) | (1 << 30) | (1 << 31)));
    }
}
public static class HgBlocks {
    static int Kind(int r, int g, int b) {
        if (r > 110 && g < 70 && b < 70) return 0;
        if (b > 110 && r < 70 && g < 70) return 1;
        return -1;
    }
    // Per colour (red, blue) left of xMax: rows present, top, bottom, left,
    // right. 2 x 5 ints.
    public static int[] Score(byte[] px, int stride, int w, int h, int xMax) {
        var o = new int[10];
        for (int k = 0; k < 2; k++) { o[k * 5 + 1] = int.MaxValue; o[k * 5 + 3] = int.MaxValue; o[k * 5 + 2] = -1; o[k * 5 + 4] = -1; }
        int xm = Math.Min(w, xMax);
        var n = new int[2];
        for (int y = 0; y < h; y++) {
            n[0] = 0; n[1] = 0;
            int row = y * stride;
            for (int x = 0; x < xm; x++) {
                int i = row + x * 4;
                int k = Kind(px[i + 2], px[i + 1], px[i]);
                if (k < 0) continue;
                n[k]++;
                int b = k * 5;
                if (x < o[b + 3]) o[b + 3] = x;
                if (x > o[b + 4]) o[b + 4] = x;
            }
            for (int k = 0; k < 2; k++) {
                if (n[k] < 8) continue;
                int b = k * 5;
                o[b]++;
                o[b + 1] = Math.Min(o[b + 1], y); o[b + 2] = Math.Max(o[b + 2], y);
            }
        }
        return o;
    }
}
'@

$colourNames = 'red', 'blue'
$consoleColours = 'DarkRed', 'DarkBlue'

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
function Get-Panes([IntPtr]$top) {
    return @([HgWin]::Panes($top) | ForEach-Object {
            $f = $_ -split ' '
            [pscustomobject]@{ Hwnd = [int64]$f[0]; Left = [int]$f[1]; Top = [int]$f[2]; Right = [int]$f[3]; Bottom = [int]$f[4]; Visible = ($f[5] -eq '1') }
        } | Sort-Object Left)
}
function Wait-Shown([IntPtr]$top, [int]$n, [int]$ms = 15000) {
    $deadline = (Get-Date).AddMilliseconds($ms)
    do {
        $v = @(Get-Panes $top | Where-Object Visible)
        if ($v.Count -eq $n) { return $v }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    return @(Get-Panes $top | Where-Object Visible)
}
# A block of 12 rows of 40 coloured cells: big enough to survive the
# snapshot's thumbnail-size round trip.
function Paint($target, [int]$k) {
    $c = $consoleColours[$k]
    # argv-audit: a fixed command with no double quote and no trailing backslash survives a native argv; $c is a console colour name
    $r = (& $Exe +send-keys "--target=$target" "cls; ''; 1..12 | % { Write-Host '  ' -NoNewline; Write-Host (' ' * 40) -BackgroundColor $c }" Enter 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { "  send-keys $target -> exit $LASTEXITCODE $r" }
}

function Measure-Frame($path, [int]$xMax) {
    $bmp = New-Object System.Drawing.Bitmap $path
    try {
        $rect = New-Object System.Drawing.Rectangle(0, 0, $bmp.Width, $bmp.Height)
        $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $bytes = New-Object byte[] ($data.Stride * $bmp.Height)
        [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $bytes.Length)
        $stride = $data.Stride
        $bmp.UnlockBits($data)
        $s = [HgBlocks]::Score($bytes, $stride, $bmp.Width, $bmp.Height, $xMax)
        $out = @()
        for ($k = 0; $k -lt 2; $k++) {
            $b = $k * 5
            $out += [pscustomobject]@{ Rows = $s[$b]; Top = $s[$b + 1]; Bottom = $s[$b + 2]; Left = $s[$b + 3]; Right = $s[$b + 4] }
        }
        return , $out
    } finally { $bmp.Dispose() }
}

$script:rest = @{}
function Score-Film($arm, $fdir, [int]$xMax) {
    $rows = @(Get-Content (Join-Path $fdir 'frames.txt') | Where-Object { $_ -match '^\d' } | ForEach-Object {
            $p = $_ -split ' '
            [pscustomobject]@{ I = [int]$p[0]; T = [double]$p[1] / 10000.0; B = (Measure-Frame (Join-Path $fdir ('f{0:d4}.bmp' -f [int]$p[0])) $xMax) }
        })
    Assert "$arm.4 the film has frames ($($rows.Count))" ($rows.Count -ge 3)
    if ($rows.Count -lt 3) { return }
    $first = $rows[0]; $last = $rows[$rows.Count - 1]
    $r0 = $first.B[0]; $b1 = $last.B[1]
    "    rest: before red $($r0.Left)-$($r0.Right) x $($r0.Top)-$($r0.Bottom) ($($r0.Rows) rows), blue $($first.B[1].Rows) rows; after blue $($b1.Left)-$($b1.Right) x $($b1.Top)-$($b1.Bottom) ($($b1.Rows) rows), red $($last.B[0].Rows) rows"
    $script:rest[$arm] = @($r0, $b1)
    Assert "$arm.6 rest: red alone is the hero before, blue alone after" ($r0.Rows -gt 20 -and $first.B[1].Rows -eq 0 -and $b1.Rows -gt 20 -and $last.B[0].Rows -eq 0)
    # The incoming (blue) block's top on the way in.
    $endTop = $b1.Top
    $tops = @{}
    foreach ($f in $rows) { $b = $f.B[1]; if ($b.Rows -gt 0 -and $b.Top -ne $endTop) { $tops[$b.Top] = $true } }
    $t0 = $rows[0].T
    "    trace (blue ms:top/rows): " + (($rows | ForEach-Object { $b = $_.B[1]; "$([Math]::Round($_.T - $t0)):$(if ($b.Rows -gt 0) { "$($b.Top)/$($b.Rows)" } else { '-' })" }) -join ' ')
    Assert "$arm.5 glide: blue is seen at $($tops.Count) heights on the way in (need 2+)" ($tops.Count -ge 2)
    if ($arm -eq 'stall') {
        # From the first frame it shows to where it settles: the longest gap
        # in the film's clock between two frames that show it somewhere new.
        # WGC delivers a frame only when the picture changes, so a frozen
        # slide is a gap, not a run of identical frames.
        $prev = $null; $lastT = $null; $gap = 0.0; $moves = 0
        foreach ($f in $rows) {
            $b = $f.B[1]
            if ($b.Rows -eq 0 -or $b.Top -eq $prev) { continue }
            if ($null -ne $lastT -and ($f.T - $lastT) -gt $gap) { $gap = $f.T - $lastT }
            $lastT = $f.T; $prev = $b.Top; $moves++
            if ($b.Top -eq $endTop) { break }
        }
        $limit = $StallMs / 4.0
        "    stall: blue moves $moves times; longest still stretch $([Math]::Round($gap)) ms, stall $StallMs ms"
        Assert "$arm.10 through a $StallMs ms stall the slide keeps moving: longest still stretch $([Math]::Round($gap)) ms (need < $limit)" ($moves -ge 3 -and $gap -lt $limit)
    }
}

$onLine = 'pane presents through a composition swap chain'

[void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)
[void](Set-GhozttyTestIsolation -Tag 'heroglide')
Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null
Register-RepoBuildTeardown -Exe $Exe | Out-Null
$td = New-TestDesktop -Interactive

try {
    foreach ($arm in $Arms) {
        $isTree = $arm -in 'tree', 'stall'
        "== arm '$arm' (composition pane tree $(if ($isTree) { 'on' } else { 'off' })$(if ($arm -eq 'stall') { ", stall $StallMs ms" })$(if ($isTree) { ", declare $(if ($NoDeclare) { 'off' } else { 'on' })" }))"
        [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)
        $dir = Join-Path $OutDir $arm
        if (Test-Path $dir) { Get-ChildItem $dir -File -Recurse | ForEach-Object { Remove-Item $_.FullName } }
        New-Item -ItemType Directory -Force $dir | Out-Null
        $env:LOCALAPPDATA = $dir
        $env:GHOZTTY_DEBUG_GHOST = 'bottom'
        $env:GHOZTTY_TEST_NO_OCCLUSION = '1'
        foreach ($k in 'GHOZTTY_COMP_PRESENT', 'GHOZTTY_COMP_CHROME', 'GHOZTTY_COMP_PANE_TREE') {
            # T2514: the present is on by default, so the non-tree arm opts out.
            if ($isTree) { Set-Item "env:$k" '1' } elseif ($k -eq 'GHOZTTY_COMP_PRESENT') { Set-Item "env:$k" '0' } else { Remove-Item "env:$k" -ErrorAction SilentlyContinue }
        }
        if ($arm -eq 'stall') { $env:GHOZTTY_DEBUG_HERO_STALL_MS = "$StallMs" } else { Remove-Item env:GHOZTTY_DEBUG_HERO_STALL_MS -ErrorAction SilentlyContinue }
        if ($NoDeclare) { $env:GHOZTTY_HERO_DECLARE = '0' } else { Remove-Item env:GHOZTTY_HERO_DECLARE -ErrorAction SilentlyContinue }
        $err = Join-Path $dir 'stderr.txt'
        $app = Start-OnTestDesktop -Exe $Exe -Arguments @(
            '--config-default-files=false', '--session-persistence=false',
            '--window-width=100', '--window-height=30', '--background=#000000',
            '--palette=1=#ff0000', '--palette=4=#0000ff',
            '--keybind=f9=toggle_hero_mode', '--keybind=f7=goto_split:next',
            '--command=powershell.exe -NoLogo -NoProfile', "--title=t2573-$arm") -StdErr $err
        $top = $null
        for ($t = 0; $t -lt 100 -and -not $top; $t++) {
            $w = @([HgWin]::TopLevel([uint32]$app.Pid, 'GhozttyWindow'))
            if ($w.Count -gt 0) { $top = $w[0] } else { Start-Sleep -Milliseconds 200 }
        }
        Assert "$arm.0 the ghost window came up" ($null -ne $top)
        if (-not $top) { continue }
        $name = "hg$arm"
        & $Exe +new-window "--target=$name" 2>$null | Out-Null
        $hw = $null
        for ($t = 0; $t -lt 50 -and -not $hw; $t++) {
            $hw = @([HgWin]::TopLevel([uint32]$app.Pid, 'GhozttyWindow') | Where-Object { $_ -ne $top }) | Select-Object -First 1
            if (-not $hw) { Start-Sleep -Milliseconds 200 }
        }
        Assert "$arm.1 the named window came up" ($null -ne $hw)
        if (-not $hw) { continue }
        $scale = [Math]::Max(1, [HgWin]::GetDpiForWindow($hw)) / 96.0
        [void][HgWin]::Size($hw, [int](1200 * $scale), [int](700 * $scale))
        Start-Sleep -Milliseconds 1500
        & $Exe +split "--target=$name" '--direction=right' "--name=$name-1" 2>$null | Out-Null
        $two = @(Wait-Shown $hw 2)
        Start-Sleep -Milliseconds 3000
        Paint $name 0
        Paint "$name-1" 1
        Start-Sleep -Milliseconds 2000
        Assert "$arm.2 two panes on show ($($two.Count))" ($two.Count -eq 2)
        if ($isTree) {
            Assert "$arm.3 the panes present through the composition chain" (Wait-Log $err $onLine 15000)
            Assert "$arm.3t both panes went into the window tree (adopts=2)" (Wait-Log $err 'adopted into the window tree \(adopts=2\)' 15000)
        }
        if ($two.Count -ne 2) { continue }
        # Hero mode, from the red (left) pane: it is the hero.
        [HgWin]::Key([IntPtr]$two[0].Hwnd, 0x78, 0x43)  # F9
        $one = @(Wait-Shown $hw 1)
        Assert "$arm.2h hero mode: one pane on show ($($one.Count))" ($one.Count -eq 1)
        if ($one.Count -ne 1) { continue }
        # The carousel's snapshots are made by its first paints.
        Start-Sleep -Milliseconds 2500
        $wr = New-Object HgWin+RECT
        [void][HgWin]::GetWindowRect($hw, [ref]$wr)
        $xMax = $one[0].Right - $wr.Left
        "  hero pane $($one[0].Left)-$($one[0].Right); scoring film x < $xMax"

        $fdir = Join-Path $dir 'film'
        $filmErr = Join-Path $dir 'film.txt'
        $filmMs = 350 + $StallMs + 1500
        $fp = Start-Process -FilePath $Spike -ArgumentList @("--film-hwnd=$([int64]$hw)", "--film-dir=`"$fdir`"", "--film-ms=$filmMs") `
            -NoNewWindow -PassThru -RedirectStandardError $filmErr
        $ready = $false
        for ($t = 0; $t -lt 100 -and -not $ready; $t++) { $ready = Test-Path (Join-Path $fdir 'ready'); if (-not $ready) { Start-Sleep -Milliseconds 50 } }
        Assert "$arm.3a the film started" $ready
        Start-Sleep -Milliseconds 300
        [HgWin]::Key([IntPtr]$one[0].Hwnd, 0x76, 0x41)  # F7: the next pane
        [void]$fp.WaitForExit(60000)
        $filmOut = (Read-Text $filmErr).Trim()
        "  $filmOut"
        Assert "$arm.3b the film finished" ($filmOut -match '^FILM ok')
        $after = @(Get-Panes $hw | Where-Object Visible)
        Assert "$arm.3c the blue pane is the hero now" ($after.Count -eq 1 -and $after[0].Hwnd -ne $one[0].Hwnd)

        Score-Film $arm $fdir $xMax

        $dec = [regex]::Matches((Read-Text $err), 'hero slide declared').Count
        if ($isTree -and -not $NoDeclare) { Assert "$arm.11 the slide was handed to the compositor ($dec declared)" ($dec -ge 1) }
        else { Assert "$arm.11 control: no slide declared ($dec)" ($dec -eq 0) }

        $fgPid = [uint32]0
        [void][HgWin]::GetWindowThreadProcessId([HgWin]::GetForegroundWindow(), [ref]$fgPid)
        Assert "$arm.F the ghost never took the foreground (fg pid $fgPid)" ($fgPid -ne [uint32]$app.Pid)
        if (-not $KeepFrames) { Get-ChildItem $fdir -Filter 'f*.bmp' -ErrorAction SilentlyContinue | ForEach-Object { Remove-Item $_.FullName } }
    }
    # The frame match: the composition arms rest where the painted one does,
    # before the slide (the hero picture right after entering hero mode, which
    # T2641 saw stretched ~1.5x until T2625) and after it (the landing).
    if ($script:rest.ContainsKey('off')) {
        foreach ($arm in @($script:rest.Keys | Where-Object { $_ -ne 'off' })) {
            $bad = @(); $before = @()
            for ($i = 0; $i -lt 2; $i++) {
                $a = $script:rest['off'][$i]; $b = $script:rest[$arm][$i]
                foreach ($f in 'Left', 'Right', 'Top', 'Bottom') {
                    if ([Math]::Abs($a.$f - $b.$f) -le 2) { continue }
                    $d = "$($colourNames[$i]).$f off=$($a.$f) $arm=$($b.$f)"
                    if ($i -eq 0) { $before += $d } else { $bad += $d }
                }
            }
            Assert "$arm.6b before the slide: the hero block rests where the painted arm's does (2 px)$(if ($before) { ': ' + ($before -join '; ') })" ($before.Count -eq 0)
            Assert "$arm.6m landing: the incoming block rests where the painted arm's does (2 px)$(if ($bad) { ': ' + ($bad -join '; ') })" ($bad.Count -eq 0)
        }
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
