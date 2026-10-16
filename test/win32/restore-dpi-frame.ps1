# T1971 acceptance: a restored window keeps its size when the desktop's scale
# changed between save and restore, and a window nobody has a record of opens
# at its default size in DEVICE-INDEPENDENT pixels.
#
# The report (user, 2026-10-15): after a restart "the window sizes are all
# small and not restored". The user's Cloud PC is reached over Remote Desktop /
# Windows App, where the scale is a property of the CONNECTION - 100% from one
# client, 200% (DPI 192) from another. Every number the session-layout
# manifest and the placement memory held was a PHYSICAL pixel with no record
# of the scale it was measured at, so a frame saved at one scale came back at
# a fraction of its size at another, and the built-in 800x600 default was a
# quarter of the intended area at 200%.
#
# The scale cannot be changed on this box from a script, so the seam is the
# recorded DPI itself: the manifest and the memory now carry `frame_dpi` /
# a fourth token, and a restore converts from it to the DPI of the monitor the
# window lands on. Patching the RECORDED scale to twice (or half) this box's
# is exactly the state a reconnect at another scale produces, from the
# restore's point of view.
#
#   A. Capture: a drag-resized window's manifest frame records this monitor's
#      DPI, and the placement memory records it too.
#   B. Same scale: the frame is replayed exactly (within 2 px).
#   C. Saved at TWICE this scale: the window comes back at half the pixels -
#      the same DIP size (within 2 px).
#   D. Saved at HALF this scale: the window doubles, and stays inside the work
#      area.
#   E. Negative control: a manifest with no `frame_dpi` (pre-T1971) is replayed
#      verbatim, so C and D are measuring the conversion and nothing else.
#   F. Placement memory: a size remembered at twice this scale opens a new
#      window at half the pixels; a three-token (pre-T1971) file opens at its
#      number unscaled; no memory at all opens at 800x600 DIP.
#
# Isolation: LOCALAPPDATA points at a throwaway dir, so the manifest, the
# memory and the agent's state dir are all this run's own. Runs on a
# BACKGROUND desktop (lib\TestDesktop.ps1).
param([string]$ExePath, [switch]$Interactive)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }
$env:GHOZTTY_PIPE_SUFFIX = "-restoredpitest$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

$fakeLocal = Join-Path $env:TEMP ("ghoztty-t1971-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $fakeLocal | Out-Null
$memFile = Join-Path $fakeLocal 'ghoztty\window_placement-debug'
$manifest = Get-GhozttySessionLayoutPath -Root $fakeLocal

function Read-Text([string]$p) { if (Test-Path $p) { (Get-Content $p -Raw) } else { '' } }

# PS 5.1's Set-Content writes a BOM, which the JSON reader rejects - restore
# then silently opens a fresh window that can score a section for the wrong
# reason (session-restore-maximized.ps1 measured it).
function Write-NoBom([string]$p, [string]$text) {
    [System.IO.File]::WriteAllText($p, $text, (New-Object System.Text.UTF8Encoding $false))
}

function Get-ManifestFrame {
    $m = Read-Text $manifest
    if ($m -match '"frame"\s*:\s*\{\s*"x"\s*:\s*(-?\d+)\s*,\s*"y"\s*:\s*(-?\d+)\s*,\s*"w"\s*:\s*(\d+)\s*,\s*"h"\s*:\s*(\d+)') {
        return [pscustomobject]@{ X = [int]$Matches[1]; Y = [int]$Matches[2]; W = [int]$Matches[3]; H = [int]$Matches[4] }
    }
    return $null
}

function Get-ManifestDpi {
    $m = Read-Text $manifest
    if ($m -match '"frame_dpi"\s*:\s*(\d+)') { return [int]$Matches[1] }
    return $null
}

# Rewrite the one window's frame and its recorded scale. $Dpi = 0 removes the
# field (the pre-T1971 shape).
function Set-ManifestFrame([int]$X, [int]$Y, [int]$W, [int]$H, [int]$Dpi) {
    $m = Read-Text $manifest
    $m = $m -replace '"frame"\s*:\s*\{[^}]*\}', ('"frame":{"x":' + $X + ',"y":' + $Y + ',"w":' + $W + ',"h":' + $H + '}')
    $m = $m -replace ',\s*"frame_dpi"\s*:\s*\d+', ''
    if ($Dpi -gt 0) { $m = $m -replace '("frame"\s*:\s*\{[^}]*\})', ('$1,"frame_dpi":' + $Dpi) }
    Write-NoBom $manifest $m
}

function Kill-RepoInstances { [void](Stop-RepoGhoztty -Exe $exe -SettleMs 500) }

# -NoPersist: sections F1/F2 read the placement memory alone, so no manifest
# may restore over it; everything else needs persistence ON, since the
# manifest restore IS the subject.
function Launch([switch]$NoPersist) {
    $savedLocal = $env:LOCALAPPDATA
    $env:LOCALAPPDATA = $fakeLocal
    try {
        # -KeepWindowPlacement: the memory and the manifest ARE the subject.
        $a = if ($NoPersist) {
            Start-OnTestDesktop -Exe $exe -Arguments @('--session-persistence=false') -KeepWindowPlacement
        } else {
            Start-OnTestDesktop -Exe $exe -Arguments @('--session-persistence=true') -KeepWindowPlacement
        }
    } finally {
        $env:LOCALAPPDATA = $savedLocal
    }
    Start-Sleep -Seconds 3
    if ($a.Process -and $a.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $t = Wait-TestWindow -ProcessId $a.Pid -Class 'GhozttyWindow'
    if ($t -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: top window not found'; exit 1 }
    $script:app = $a
    $script:top = $t
    $script:launched += $a.Pid
}

function Stop-App {
    if ($script:app) { Stop-Process -Id $script:app.Pid -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 600
}

function Near([int]$a, [int]$b, [int]$tol = 2) { return [math]::Abs($a - $b) -le $tol }

function Show-Rect([string]$tag) {
    $r = Get-TestWindowRect -Window $top
    Write-Host ("      {0}: {1}x{2} at {3},{4}" -f $tag, $r.Width, $r.Height, $r.Left, $r.Top)
    return $r
}


$script:launched = @()
Kill-RepoInstances
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    # ---------------------------------------------------------------- A
    Write-Host ''
    Write-Host '--- A: a saved frame records the scale it was measured at ---'
    Remove-Item -Recurse -Force (Join-Path $fakeLocal 'ghoztty') -ErrorAction SilentlyContinue
    Launch
    $dpi = [int](Get-TestWindowDpi -Window $top)
    Write-Host "      this monitor: $dpi dpi"
    Assert ($dpi -ge 96) "the window reports a DPI (got $dpi)"
    $work = Get-TestWorkArea

    # F3 rides here: a fresh profile has no memory, so this IS the default.
    $init = Show-Rect 'fresh profile'
    $defW = [math]::Round(800 * $dpi / 96.0, [System.MidpointRounding]::AwayFromZero)
    $defH = [math]::Round(600 * $dpi / 96.0, [System.MidpointRounding]::AwayFromZero)
    Assert ((Near $init.Width $defW) -and (Near $init.Height $defH)) "F3: no memory opens at 800x600 DIP = ${defW}x${defH} px here (got $($init.Width)x$($init.Height))"

    Set-TestWindowPos -Window $top -X 60 -Y 40 | Out-Null
    Invoke-TestDragResize -Window $top -DeltaWidth 137 -DeltaHeight 91 | Out-Null
    $mem = ''
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 100
        $mem = (Read-Text $memFile).Trim()
        if ($mem -match ' (\d+)$' -and (Get-ManifestDpi)) { break }
    }
    $live = Show-Rect 'after drag'
    Stop-App
    $f = Get-ManifestFrame
    $mDpi = Get-ManifestDpi
    Assert ($null -ne $f) 'A: the manifest recorded a frame'
    Assert ($mDpi -eq $dpi) "A: the manifest recorded frame_dpi = this monitor's $dpi (got '$mDpi')"
    Assert ($mem -match "^\d+ \d+ [01] $dpi$") "A: the placement memory carries the DPI as its fourth token (got '$mem')"
    if (-not $f) { throw 'no frame to work with' }
    Assert ((Near $f.W $live.Width) -and (Near $f.H $live.Height)) "A: the frame is the live window's size ($($f.W)x$($f.H) vs $($live.Width)x$($live.Height))"

    # ---------------------------------------------------------------- B
    Write-Host ''
    Write-Host '--- B: same scale -> replayed exactly ---'
    Launch
    $r = Show-Rect 'restored'
    Assert ((Near $r.Width $f.W) -and (Near $r.Height $f.H) -and (Near $r.Left $f.X) -and (Near $r.Top $f.Y)) "B: restored at the manifest's $($f.W)x$($f.H) at $($f.X),$($f.Y)"
    Stop-App

    # ---------------------------------------------------------------- C
    Write-Host ''
    Write-Host '--- C: saved at twice this scale -> half the pixels, same DIP size ---'
    $cw = 1600; $ch = 1000
    Set-ManifestFrame -X 80 -Y 60 -W $cw -H $ch -Dpi ($dpi * 2)
    Launch
    $r = Show-Rect 'restored'
    Assert ((Near $r.Width ($cw / 2)) -and (Near $r.Height ($ch / 2))) "C: ${cw}x${ch} at $($dpi * 2) dpi lands as $($cw / 2)x$($ch / 2) at $dpi (got $($r.Width)x$($r.Height))"
    Assert ((Near $r.Left 80) -and (Near $r.Top 60)) "C: the position is not moved by a scale change (got $($r.Left),$($r.Top))"
    Stop-App

    # ---------------------------------------------------------------- D
    Write-Host ''
    Write-Host '--- D: saved at half this scale -> doubled, inside the work area ---'
    $dw = 500; $dh = 350
    Set-ManifestFrame -X 100 -Y 50 -W $dw -H $dh -Dpi ([math]::Floor($dpi / 2))
    Launch
    $r = Show-Rect 'restored'
    $wantW = [math]::Min($dw * 2, $work.Width)
    $wantH = [math]::Min($dh * 2, $work.Height)
    Assert ((Near $r.Width $wantW 4) -and (Near $r.Height $wantH 4)) "D: ${dw}x${dh} at half scale lands as ${wantW}x${wantH} (got $($r.Width)x$($r.Height))"
    Assert ($r.Left -ge $work.Left -and $r.Top -ge $work.Top -and $r.Right -le $work.Right -and $r.Bottom -le $work.Bottom) "D: the window is inside the work area ($($work.Width)x$($work.Height))"
    Assert ($r.Width -ge $dw -and $r.Height -ge $dh) 'D: never smaller than its saved pixel size when the scale went UP'
    Stop-App

    # ---------------------------------------------------------------- E
    Write-Host ''
    Write-Host '--- E: negative control - no recorded scale, replayed verbatim ---'
    Set-ManifestFrame -X 80 -Y 60 -W $cw -H $ch -Dpi 0
    Assert (-not ((Read-Text $manifest) -match 'frame_dpi')) 'E setup: frame_dpi removed'
    Launch
    $r = Show-Rect 'restored'
    Assert ((Near $r.Width $cw) -and (Near $r.Height $ch)) "E: a pre-T1971 frame keeps its ${cw}x${ch} pixels (got $($r.Width)x$($r.Height))"
    Stop-App

    # ---------------------------------------------------------------- F
    Write-Host ''
    Write-Host '--- F: the placement memory converts the same way ---'
    Remove-Item -Force $manifest -ErrorAction SilentlyContinue
    Write-NoBom $memFile "1400 900 0 $($dpi * 2)`n"
    Launch -NoPersist
    $r = Show-Rect 'memory at twice the scale'
    Assert ((Near $r.Width 700) -and (Near $r.Height 450)) "F1: 1400x900 remembered at $($dpi * 2) dpi opens at 700x450 (got $($r.Width)x$($r.Height))"
    Stop-App

    Write-NoBom $memFile "700 450 0`n"
    Launch -NoPersist
    $r = Show-Rect 'pre-T1971 memory'
    Assert ((Near $r.Width 700) -and (Near $r.Height 450)) "F2: a three-token memory opens at its number unscaled (got $($r.Width)x$($r.Height))"
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'F: no crash'
    Stop-App
    Complete-TestBody
} finally {
    Remove-TestDesktop
    Kill-RepoInstances
    Remove-Item -Recurse -Force $fakeLocal -ErrorAction SilentlyContinue
}

$fgSeen = @(Stop-TestForegroundWatch)
Write-Host "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @($script:launched | Select-Object -Unique)
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'no test-desktop app ever became foreground on the interactive desktop'
}

# --- stamp (T783) -----------------------------------------------------------
if ($script:fail -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard restore-dpi-frame -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Label 'T1971 RESTORE-DPI-FRAME' -Pass $script:pass -Fail $script:fail -MinPass 19
