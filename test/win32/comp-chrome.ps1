# Window-chrome composition host acceptance (tracker T2508, T2360 step 4a).
#
# THE CHANGE: a top-level window can carry a DirectComposition target
# (topmost=FALSE: under the pane child windows) with a Direct2D device context
# over a hardware-then-WARP D3D11 device, ready for the chrome painters to move
# onto (src/apprt/win32/chrome_comp.zig). It is opt-in while it is proven:
# GHOZTTY_COMP_CHROME=1. No visual is attached in a normal run - the first
# visual on that target covers the window's GDI chrome, which is T2509's step.
#
# THE CONTRACT this asserts:
#
#   A. Knob on: every window logs the host ready with target_hr and d2d_hr
#      both S_OK and the adapter it got (hardware or warp), and the windows
#      keep working - two windows, a split, a resize, text drawn, no failure.
#   B. A lost device is noticed on the next paint and the whole host is
#      rebuilt (debug seam GHOZTTY_COMP_CHROME_FORCE_LOSS=1 reports the first
#      check as lost): the loss line, then a second ready line with rebuilds=1.
#   C. The Direct2D context can draw into what the compositor shows: the debug
#      test fill (GHOZTTY_COMP_CHROME_TEST_FILL=1) is drawn through it into a
#      composition surface and attached without error.
#   D. Negative control: knob off, nothing is created and nothing is logged.
#
# NOT asserted here: the on-screen ORDER (fill above the GDI chrome, below the
# panes). This harness runs on a background desktop, which DWM never composes
# and Windows.Graphics.Capture refuses (T2463). That half is
# scripts\comp-chrome-onscreen.ps1, which films a ghost window.
#
#   powershell -NoProfile -File test\win32\comp-chrome.ps1

param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [switch]$Interactive
)

$ErrorActionPreference = 'Continue'
Set-StrictMode -Off

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\PaneCapture.ps1')
. (Join-Path $PSScriptRoot 'lib\HarnessLeak.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:passes = 0
$script:failures = 0
function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ }
    else { "  FAIL $name"; $script:failures++ }
}

if (-not (Test-Path $Exe)) { "SETUP FAIL: $Exe not found - build it first"; exit 2 }

$root = Join-Path $env:TEMP "ghoztty-comp-chrome-$PID"
$savedLocalAppData = $env:LOCALAPPDATA
$knobs = 'GHOZTTY_COMP_CHROME', 'GHOZTTY_COMP_CHROME_FORCE_LOSS', 'GHOZTTY_COMP_CHROME_TEST_FILL'
$saved = @{}
foreach ($k in $knobs) { $saved[$k] = [Environment]::GetEnvironmentVariable($k) }

function Set-Knobs($on, $loss, $fill) {
    $vals = @{ GHOZTTY_COMP_CHROME = $on; GHOZTTY_COMP_CHROME_FORCE_LOSS = $loss; GHOZTTY_COMP_CHROME_TEST_FILL = $fill }
    foreach ($k in $knobs) {
        if ($vals[$k]) { Set-Item "env:$k" $vals[$k] }
        else { Remove-Item "env:$k" -ErrorAction SilentlyContinue }
    }
}

[void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)
New-Item -ItemType Directory -Force $root | Out-Null

[void](Set-GhozttyTestIsolation -Tag 'compchrome')
Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null

Register-RepoBuildTeardown -Exe $Exe | Out-Null
$td = New-TestDesktop -Interactive:$Interactive

function Get-Win($target) {
    $json = (& $Exe +list --json 2>$null | Out-String).Trim()
    if (-not $json) { return $null }
    try { $data = ($json | ConvertFrom-Json).data } catch { return $null }
    foreach ($w in $data.windows) { if ($w.target -eq $target) { return $w } }
    return $null
}

function Wait-Win($target) {
    for ($t = 0; $t -lt 50; $t++) {
        $w = Get-Win $target
        if ($w) { return $w }
        Start-Sleep -Milliseconds 200
    }
    return $null
}

function Read-Text($path) {
    if (Test-Path $path) { return [string](Get-Content $path -Raw -ErrorAction SilentlyContinue) }
    return ''
}

function Wait-Count($path, $pattern, $n, $timeoutMs) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $timeoutMs) {
        if ((Count-Log $path $pattern) -ge $n) { return $true }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

function Count-Log($path, $pattern) {
    return ([regex]::Matches((Read-Text $path), $pattern)).Count
}

function Test-DrawsText($target) {
    for ($t = 0; $t -lt 40; $t++) {
        $shot = Get-TestPaneCapture -Target $target
        if ($shot) {
            $colors = Get-TestPaneColorCount -Shot $shot
            Close-TestPaneCapture $shot
            return ($colors -ge 8)
        }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

$readyLine = 'chrome composition host ready: target_hr=0x00000000 d2d_hr=0x00000000 adapter=(hardware|warp)'
$anyHost = 'chrome composition'
$unavailLine = 'chrome composition host unavailable'

function Start-Arm($name) {
    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)
    $dir = Join-Path $root $name
    New-Item -ItemType Directory -Force $dir | Out-Null
    $env:LOCALAPPDATA = $dir
    $err = Join-Path $dir 'stderr.txt'
    $app = Start-OnTestDesktop -Exe $Exe -Arguments @(
        '--config-default-files=false', '--session-persistence=false',
        "--title=t2508-$name") -StdErr $err
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow' -TimeoutMs 30000
    & $Exe +new-window "--target=chrome$name" | Out-Null
    $win = Wait-Win "chrome$name"
    return [pscustomobject]@{ App = $app; Err = $err; Top = $top; Win = $win; Target = "chrome$name" }
}

function Test-Alive($arm) { return ($arm.App.Process -and -not $arm.App.Process.HasExited) }

try {
    # ========================================================================
    "== A: knob on, every window builds its chrome host and keeps working"
    # ========================================================================
    Set-Knobs '1' $null $null
    $a = Start-Arm 'a'
    Assert "A0 the arm's windows came up" ($a.Top -ne [IntPtr]::Zero -and $null -ne $a.Win)
    Assert "A1 both windows logged the host ready, S_OK twice, adapter named ($(Count-Log $a.Err $readyLine))" `
        (Wait-Count $a.Err $readyLine 2 15000)
    $m = [regex]::Match((Read-Text $a.Err), $readyLine)
    if ($m.Success) { "  adapter: $($m.Groups[1].Value)" }
    & $Exe +split "--target=$($a.Target)" '--direction=right' '--name=chroma2' 2>$null | Out-Null
    for ($i = 0; $i -lt 3; $i++) {
        & $Exe +send-keys "--target=$($a.Target)" "echo comp-chrome-t2508-$i" Enter 2>$null | Out-Null
        Start-Sleep -Milliseconds 250
    }
    if ($a.Top -ne [IntPtr]::Zero) {
        [void](Set-TestWindowSize -Window $a.Top -Width 1100 -Height 700)
        Start-Sleep -Milliseconds 500
        [void](Set-TestWindowSize -Window $a.Top -Width 800 -Height 520)
        Start-Sleep -Milliseconds 500
    }
    Assert "A2 the app is still running" (Test-Alive $a)
    Assert "A3 a split does not build a second host for the same window" ((Count-Log $a.Err $readyLine) -eq 2)
    Assert "A4 nothing failed or was lost" `
        ((Count-Log $a.Err $unavailLine) -eq 0 -and (Count-Log $a.Err 'chrome composition device lost') -eq 0)
    Assert "A5 the panes still draw text" ((Test-DrawsText $a.Target) -and (Test-DrawsText 'chroma2'))
    Assert "A6 no test fill without its seam" ((Count-Log $a.Err 'test fill') -eq 0)

    # ========================================================================
    "== B: a lost device is noticed on paint and the host rebuilt"
    # ========================================================================
    Set-Knobs '1' '1' $null
    $b = Start-Arm 'b'
    Assert "B0 the arm's windows came up" ($b.Top -ne [IntPtr]::Zero -and $null -ne $b.Win)
    if ($b.Top -ne [IntPtr]::Zero) { [void](Set-TestWindowSize -Window $b.Top -Width 900 -Height 600) }
    Assert "B1 the simulated loss was detected" `
        (Wait-Count $b.Err 'chrome composition device lost \(simulated \(debug test hook\)\); rebuilding' 1 15000)
    Assert "B2 the host was rebuilt with S_OK and counted (rebuilds=1)" `
        (Wait-Count $b.Err "$readyLine rebuilds=1" 1 15000)
    Start-Sleep -Milliseconds 800
    # The seam fires once per host, so a rebuilt host is never lost again.
    $lost = Count-Log $b.Err 'chrome composition device lost'
    $windows = Count-Log $b.Err "$readyLine rebuilds=0"
    Assert "B3 one loss per window, never a rebuild loop ($lost losses, $windows windows)" ($lost -ge 1 -and $lost -le $windows)
    Assert "B4 the app is still running and the pane draws" ((Test-Alive $b) -and (Test-DrawsText $b.Target))

    # ========================================================================
    "== C: the Direct2D context draws a test fill the target shows"
    # ========================================================================
    Set-Knobs '1' $null '1'
    $c = Start-Arm 'c'
    Assert "C0 the arm's windows came up" ($c.Top -ne [IntPtr]::Zero -and $null -ne $c.Win)
    Assert "C1 the test fill was drawn and attached" (Wait-Count $c.Err 'chrome composition test fill attached: \d+x\d+' 1 15000)
    Assert "C2 no fill step failed" ((Count-Log $c.Err 'test fill failed') -eq 0)
    Assert "C3 the app is still running and the pane draws" ((Test-Alive $c) -and (Test-DrawsText $c.Target))

    # ========================================================================
    "== D: negative control - knob off, nothing is created"
    # ========================================================================
    Set-Knobs $null '1' '1'
    $d = Start-Arm 'd'
    Assert "D0 the arm's windows came up" ($d.Top -ne [IntPtr]::Zero -and $null -ne $d.Win)
    Start-Sleep -Milliseconds 1500
    Assert "D1 no chrome host line at all, even with both seams set" ((Count-Log $d.Err $anyHost) -eq 0)
    Assert "D2 the pane draws" (Test-DrawsText $d.Target)

    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)

    # LAST statement of the top-level try (T1039).
    Complete-TestBody
} finally {
    foreach ($k in $knobs) {
        if ($saved[$k]) { Set-Item "env:$k" $saved[$k] }
        else { Remove-Item "env:$k" -ErrorAction SilentlyContinue }
    }
    $env:LOCALAPPDATA = $savedLocalAppData
    Remove-TestDesktop
    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)
    Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
}

# --- stamp (T783) ----------------------------------------------------------
if ($script:failures -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot '..\..\scripts\guard-due.ps1') `
        update -Guard comp-chrome -Repo (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path 2>&1 |
        ForEach-Object { Write-Host "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:passes -Fail $script:failures -Label 'comp-chrome' -MinPass 19
