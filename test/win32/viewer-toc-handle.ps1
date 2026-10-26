# Viewer side panel RESIZE HANDLE acceptance (T2265; Mac a81db68f9 + 5e4f30144).
#
# The contents card beside a viewer document resizes from a handle that
# straddles its trailing edge, in the gutter between the card and the page.
# Mac 5e4f30144 gave that handle the split dividers' GutterBar: a 4pt accent
# bar down the middle of the handle, half strength while the pointer is over
# it, full while it is dragged, and never left lit after the release. Before
# T2265 the Windows handle only changed the mouse pointer, so nothing showed
# that the edge could be taken.
#
# WHAT IS MEASURED (the app on a background desktop, posted mouse input):
#
#   A. a move onto the handle lights it (the debug log's `handle hover=true`:
#      on a background desktop the OS posts the leave within a frame, so the
#      hover is read where it is set, not from a paint);
#   B. a drag by 60 DIP moves the card's edge by 60 DIP - the handle still
#      drags (outward, or inward when the remembered width is near the cap);
#   C. mid-drag the bar is ON the card's edge: a synchronous capture shows the
#      core pixel saturated in the system accent's channel order where the
#      same pixel at rest is the card's neutral rim, and the paint log names
#      the drag's full-strength bar;
#   D. after the release the last bar painted is `none`.
#
#   powershell -NoProfile -File test\win32\viewer-toc-handle.ps1
#
# -NegativeControl drags by 0 DIP, so B fails.
param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive)

# T351: the shared reset/kill helpers, ahead of any isolation setup.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }
if (-not (Test-Path $exe)) { Write-Host "SETUP FAIL: no exe at $exe"; exit 1 }

# Endpoint isolation: a run must never reach the user's own instance.
$env:GHOZTTY_PIPE_SUFFIX = "-vtoch$PID"

. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
Assert-GhozttyIsolatedBuild -Exe $exe | Out-Null
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\ChromeGeometry.ps1')
. (Join-Path $PSScriptRoot 'lib\HarnessLeak.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
Register-RepoBuildTeardown -Exe $exe | Out-Null

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Invoke-Verb([string[]]$VerbArgs) {
    $out = (& $exe @VerbArgs 2>&1 | ForEach-Object { $_.ToString() } | Out-String)
    return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
}
function Px([double]$Dip) { Get-TestChromeDip -Dip $Dip -Scale $script:scale }
function Get-LogCount { @(Get-Content $script:errlog -ErrorAction SilentlyContinue).Count }
function Get-LogSince([int]$From) { @(Get-Content $script:errlog -ErrorAction SilentlyContinue | Select-Object -Skip $From) }
function Get-BarStates([string[]]$Lines) {
    @($Lines | ForEach-Object { if ($_ -match 'handle bar (\w+)') { $Matches[1] } })
}
function Get-Chroma([int[]]$c) {
    return (($c | Measure-Object -Maximum).Maximum - ($c | Measure-Object -Minimum).Minimum)
}
# The channels' order, brightest first (e.g. 'B>R>G'): what survives the
# lightness lift the contrast floor gives the accent.
function Get-ChannelOrder([int[]]$c) {
    return ((@(@{ N = 'R'; V = $c[0] }, @{ N = 'G'; V = $c[1] }, @{ N = 'B'; V = $c[2] }) |
        Sort-Object -Property @{ Expression = { $_.V }; Descending = $true } | ForEach-Object { $_.N }) -join '>')
}

# The user's accent, read only (DWM's ABGR DWORD). The bar is held to a 3:1
# floor against the page, so it is the accent's hue at some lightness: the
# oracle asks for a saturated pixel in the accent's channel order, never for
# an exact match.
function Get-SystemAccent {
    $p = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\DWM' -Name AccentColor -ErrorAction SilentlyContinue
    if ($null -eq $p) { return @(0, 120, 215) }
    $bytes = [BitConverter]::GetBytes([uint32]$p.AccentColor)
    return @([int]$bytes[0], [int]$bytes[1], [int]$bytes[2])
}

[void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
Start-TestForegroundWatch
$launched = @()
$td = $null
$app = $null
$script:scale = 1.0

try {
    $td = New-TestDesktop -Interactive:$Interactive
    $script:errlog = Join-Path $env:TEMP "ghoztty-viewer-toc-handle-stderr-$PID.log"
    Remove-Item $script:errlog -ErrorAction SilentlyContinue
    $app = Start-OnTestDesktop -Exe $exe -StdErr $script:errlog -Arguments @('--session-persistence=false')
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $launched += $script:GhozttyTestDesktopPids
    if ((Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow') -eq [IntPtr]::Zero) {
        Write-Host 'SETUP FAIL: no GhozttyWindow'; exit 1
    }

    $r = Invoke-Verb @('+new-window', '--target=tochandle',
        "--view=$(Join-Path $repo 'README.md')", "--working-directory=$repo")
    Assert ($r.Code -eq 0) "+new-window --view opened the viewer (exit $($r.Code))"
    Start-Sleep -Seconds 5

    $vtop = [IntPtr]::Zero
    foreach ($t in @(Get-TestWindows -ProcessId $app.Pid -Class 'GhozttyWindow')) {
        if (@(Get-TestChildWindows -Window ([IntPtr]$t.Hwnd) -Class 'GhozttyViewer').Count -ge 1) {
            $vtop = [IntPtr]$t.Hwnd
        }
    }
    Assert ($vtop -ne [IntPtr]::Zero) 'the viewer window is up'
    if ($vtop -eq [IntPtr]::Zero) { Write-Host 'ABORT: no viewer window'; exit 1 }
    $dpi = Get-TestWindowDpi -Window $vtop
    if ($dpi -gt 0) { $script:scale = $dpi / 96.0 }
    # Wide enough for the gutter layout, the only one with a handle.
    Set-TestWindowSize -Window $vtop -Width 1400 -Height 900 | Out-Null
    Start-Sleep -Seconds 2

    $toc = [IntPtr]::Zero
    foreach ($v in @(Get-TestChildWindows -Window $vtop -Class 'GhozttyViewer')) {
        foreach ($c in @(Get-TestChildWindows -Window ([IntPtr]$v.Hwnd) -Class 'GhozttyViewerTOC')) {
            $toc = [IntPtr]$c.Hwnd
        }
    }
    Assert ($toc -ne [IntPtr]::Zero -and (Test-TestWindowVisible -Window $toc)) `
        'the contents card is up in the gutter layout'
    if ($toc -eq [IntPtr]::Zero) { Write-Host 'ABORT: no contents card'; exit 1 }

    # Gutter layout: the window is the card plus a 12 DIP margin either side,
    # so the card's trailing edge - the handle's centre - is one margin in
    # from the window's right. One pixel inside it is on the handle.
    $rc = Get-TestWindowRect -Window $toc
    $hx = $rc.Right - (Px 12) - 1
    $hy = $rc.Top + (Px 60)
    $cx = $hx - $rc.Left
    $cy = $hy - $rc.Top
    $accent = Get-SystemAccent

    $rest = Get-TestWindowPixels -Window $toc -Sync
    try { $restPx = $rest.Bitmap.GetPixel($cx, $cy) } finally { Close-TestWindowPixels -Shot $rest }

    Write-Host '== A: a move onto the handle lights it'
    $from = Get-LogCount
    [void](Send-TestMouse -Window $vtop -Target $toc -X $hx -Y $hy -Action move)
    Start-Sleep -Milliseconds 400
    $lines = Get-LogSince $from
    Assert (@($lines | Where-Object { $_ -match 'handle hover=true' }).Count -ge 1) 'A hovering the handle lights its bar (log: handle hover=true)'

    Write-Host '== B/C: dragging it widens the card, with the bar at full strength'
    # The width is one remembered preference, so a run starts where the last
    # one left it: drag toward whichever side has room for 60 DIP below the
    # 460 DIP cap, and drag back afterwards.
    $cardDip = ($rc.Width / $script:scale) - 24
    $dir = if ($cardDip + 60 -gt 450) { -1 } else { 1 }
    $step = if ($NegativeControl) { 0 } else { 60 * $dir }
    if ($NegativeControl) { Write-Host '  NEGATIVE CONTROL: dragging by 0 DIP - this run MUST fail' }
    $from = Get-LogCount
    $down = Send-TestMouse -Window $vtop -Target $toc -X $hx -Y $hy -Action down
    foreach ($s in @(($step / 2), $step)) {
        [void](Send-TestMouse -Window $vtop -Target $toc -X ($hx + (Px $s)) -Y $hy -Action move)
        Start-Sleep -Milliseconds 150
    }
    Start-Sleep -Milliseconds 300
    # Mid-drag: the card has grown, so its edge (and the bar) moved with it.
    $rc2 = Get-TestWindowRect -Window $toc
    $mid = Get-TestWindowPixels -Window $toc -Sync
    try { $dragPx = $mid.Bitmap.GetPixel($rc2.Width - (Px 12) - 1, $cy) } finally { Close-TestWindowPixels -Shot $mid }
    [void](Send-TestMouse -Window $vtop -Target $toc -X ($hx + (Px $step)) -Y $hy -Action up)
    Start-Sleep -Milliseconds 500
    $lines = Get-LogSince $from
    $bars = @(Get-BarStates $lines)
    Assert $down 'B the press reached the handle'
    Assert ([math]::Abs(($rc2.Width - $rc.Width) - (Px (60 * $dir))) -le 2) "B the card followed the drag by $(60 * $dir) DIP ($($rc.Width) -> $($rc2.Width))"
    Assert ($bars -contains 'drag') "C the drag painted the bar at full strength (painted: $($bars -join ','))"
    $restRgb = @([int]$restPx.R, [int]$restPx.G, [int]$restPx.B)
    $dragRgb = @([int]$dragPx.R, [int]$dragPx.G, [int]$dragPx.B)
    Assert ((Get-Chroma $dragRgb) -ge (Get-Chroma $restRgb) + 40 -and (Get-ChannelOrder $dragRgb) -eq (Get-ChannelOrder $accent)) `
        "C mid-drag the handle's core pixel is the accent ($($dragRgb -join ',') $(Get-ChannelOrder $dragRgb) vs rest $($restRgb -join ','); accent $($accent -join ',') $(Get-ChannelOrder $accent))"

    Write-Host '== D: letting go leaves no bar lit'
    Assert ($bars.Count -gt 0 -and $bars[-1] -eq 'none') "D the last bar painted after the release is none (last: $(if ($bars.Count) { $bars[-1] }))"

    # Put the preference back where the run found it.
    $bx = $rc2.Right - (Px 12) - 1
    [void](Send-TestMouse -Window $vtop -Target $toc -X $bx -Y $hy -Action down)
    [void](Send-TestMouse -Window $vtop -Target $toc -X ($bx - ($rc2.Width - $rc.Width)) -Y $hy -Action move)
    Start-Sleep -Milliseconds 150
    [void](Send-TestMouse -Window $vtop -Target $toc -X ($bx - ($rc2.Width - $rc.Width)) -Y $hy -Action up)
    Start-Sleep -Milliseconds 300

    Assert (-not ($app.Process -and $app.Process.HasExited)) 'the GUI survived the whole run'
} catch {
    $script:fail++
    Write-Host "FAIL  the run terminated: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "      at $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())"
} finally {
    if ($td) { Remove-TestDesktop }
    [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 300)
}

$fgSeen = @(Stop-TestForegroundWatch)
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @($launched | Select-Object -Unique)
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'no test-desktop app ever became foreground on the interactive desktop'
}

Complete-TestBody  # T1039: the last statement of the body an unwind can skip

if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard viewer-toc-handle -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Label 'viewer-toc-handle' -MinPass 9
