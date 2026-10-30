# Composition swap-chain presentation acceptance (tracker T2466, T2360 step 2).
#
# THE CHANGE: a terminal pane can present through a DXGI flip-model swap chain
# that is the content of a DirectComposition visual on the pane's window,
# instead of WGL SwapBuffers into the window's redirection bitmap
# (src/renderer/gl_comp_present.zig). It is opt-in while it is proven:
# GHOZTTY_COMP_PRESENT=1.
#
# THE CONTRACT this asserts:
#
#   A. With the knob on, every pane builds the chain (GL/D3D interop, swap
#      chain, DComp target on the pane window) and keeps presenting through it:
#      two panes, output, a resize, and no failure or fallback line. The panes
#      still draw text (capture-pane reads the renderer's own target).
#   B. A present that fails falls back to SwapBuffers for that pane, and the
#      pane keeps drawing - the debug-only seam
#      GHOZTTY_COMP_PRESENT_FAIL_AFTER=<n> fails the n+1th present.
#   C. A lost GL device on the composition path is rebuilt, and the rebuilt
#      context builds its chain again (T1690's seam).
#   D. Negative control: with the knob off, no pane touches the composition
#      path.
#
# NOT asserted here: the pixels DWM shows. This harness runs on a background
# desktop, which DWM never composes and Windows.Graphics.Capture refuses
# (T2463), so the on-screen picture of the swap chain - right way up, no tear,
# no blank frame - needs the input desktop and is T2466's follow-up.
#
#   powershell -NoProfile -File test\win32\comp-present.ps1

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

$root = Join-Path $env:TEMP "ghoztty-comp-present-$PID"
$savedLocalAppData = $env:LOCALAPPDATA
$knobs = 'GHOZTTY_COMP_PRESENT', 'GHOZTTY_COMP_PRESENT_FAIL_AFTER', 'GHOZTTY_GL_SIMULATE_RESET_AFTER'
$saved = @{}
foreach ($k in $knobs) { $saved[$k] = [Environment]::GetEnvironmentVariable($k) }

function Set-Knobs($comp, $failAfter, $resetAfter) {
    $vals = @{ GHOZTTY_COMP_PRESENT = $comp; GHOZTTY_COMP_PRESENT_FAIL_AFTER = $failAfter; GHOZTTY_GL_SIMULATE_RESET_AFTER = $resetAfter }
    foreach ($k in $knobs) {
        if ($vals[$k]) { Set-Item "env:$k" $vals[$k] }
        else { Remove-Item "env:$k" -ErrorAction SilentlyContinue }
    }
}

[void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)
New-Item -ItemType Directory -Force $root | Out-Null

[void](Set-GhozttyTestIsolation -Tag 'comppres')
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

function Wait-Log($path, $pattern, $timeoutMs) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $timeoutMs) {
        if ((Read-Text $path) -match $pattern) { return $true }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

function Count-Log($path, $pattern) {
    return ([regex]::Matches((Read-Text $path), $pattern)).Count
}

function Wait-Capture($target) {
    for ($t = 0; $t -lt 40; $t++) {
        $shot = Get-TestPaneCapture -Target $target
        if ($shot) { return $shot }
        Start-Sleep -Milliseconds 250
    }
    return $null
}

# Text in the pane, read through the renderer's own target.
function Test-DrawsText($target) {
    $shot = Wait-Capture $target
    if (-not $shot) { return $false }
    $colors = Get-TestPaneColorCount -Shot $shot
    Close-TestPaneCapture $shot
    return ($colors -ge 8)
}

$onLine = 'pane presents through a composition swap chain'
$failLine = 'composition present failed'
$unavailLine = 'composition present unavailable'

function Start-Arm($name) {
    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)
    $dir = Join-Path $root $name
    New-Item -ItemType Directory -Force $dir | Out-Null
    $env:LOCALAPPDATA = $dir
    $err = Join-Path $dir 'stderr.txt'
    $app = Start-OnTestDesktop -Exe $Exe -Arguments @(
        '--config-default-files=false', '--session-persistence=false',
        "--title=t2466-$name") -StdErr $err
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow' -TimeoutMs 30000
    & $Exe +new-window "--target=comp$name" | Out-Null
    $win = Wait-Win "comp$name"
    return [pscustomobject]@{ App = $app; Err = $err; Top = $top; Win = $win; Target = "comp$name" }
}

function Test-Alive($arm) { return ($arm.App.Process -and -not $arm.App.Process.HasExited) }

try {
    # ========================================================================
    "== A: with the knob on, panes present through the composition swap chain"
    # ========================================================================
    Set-Knobs '1' $null $null
    $a = Start-Arm 'a'
    Assert "A0 the arm's window came up" ($a.Top -ne [IntPtr]::Zero -and $null -ne $a.Win)
    Assert "A1 the first pane built its chain" (Wait-Log $a.Err $onLine 15000)

    & $Exe +split "--target=$($a.Target)" '--direction=right' '--name=compa2' 2>$null | Out-Null
    $two = $false
    for ($t = 0; $t -lt 50 -and -not $two; $t++) {
        $two = (Count-Log $a.Err $onLine) -ge 2
        if (-not $two) { Start-Sleep -Milliseconds 200 }
    }
    Assert "A2 the split pane built its own chain ($(Count-Log $a.Err $onLine) lines)" $two

    for ($i = 0; $i -lt 3; $i++) {
        & $Exe +send-keys "--target=$($a.Target)" "echo comp-present-t2466-$i" Enter 2>$null | Out-Null
        & $Exe +send-keys '--target=compa2' "dir" Enter 2>$null | Out-Null
        Start-Sleep -Milliseconds 300
    }
    # A resize reaches ResizeBuffers and a new shared texture on both panes.
    if ($a.Top -ne [IntPtr]::Zero) {
        [void](Set-TestWindowSize -Window $a.Top -Width 1100 -Height 700)
        Start-Sleep -Milliseconds 600
        [void](Set-TestWindowSize -Window $a.Top -Width 800 -Height 520)
        Start-Sleep -Milliseconds 600
    }
    & $Exe +send-keys "--target=$($a.Target)" 'echo after-resize' Enter 2>$null | Out-Null
    Start-Sleep -Milliseconds 800

    Assert "A3 the app is still running" (Test-Alive $a)
    Assert "A4 no pane fell back or failed to build" `
        ((Count-Log $a.Err $failLine) -eq 0 -and (Count-Log $a.Err $unavailLine) -eq 0)
    Assert "A5 the first pane still draws text" (Test-DrawsText $a.Target)
    Assert "A6 the split pane still draws text" (Test-DrawsText 'compa2')
    Assert "A7 no OpenGL errors were raised" ((Read-Text $a.Err) -notmatch 'error\(opengl\)')
    Assert "A8 and no draw failed" ((Read-Text $a.Err) -notmatch 'error drawing err=')

    # ========================================================================
    "== B: a failed present falls back to SwapBuffers and the pane keeps drawing"
    # ========================================================================
    Set-Knobs '1' '5' $null
    $b = Start-Arm 'b'
    Assert "B0 the arm's window came up" ($b.Top -ne [IntPtr]::Zero -and $null -ne $b.Win)
    Assert "B1 the pane built its chain" (Wait-Log $b.Err $onLine 15000)
    for ($i = 0; $i -lt 4; $i++) {
        & $Exe +send-keys "--target=$($b.Target)" "echo fallback-$i" Enter 2>$null | Out-Null
        Start-Sleep -Milliseconds 250
    }
    Assert "B2 the simulated failure was reported as a fallback" `
        (Wait-Log $b.Err 'composition present failed \(error\.ComFailed\) at simulated' 15000)
    & $Exe +send-keys "--target=$($b.Target)" 'echo drawn-by-swapbuffers' Enter 2>$null | Out-Null
    Start-Sleep -Milliseconds 800
    Assert "B3 the app is still running" (Test-Alive $b)
    Assert "B4 the pane draws text after the fallback" (Test-DrawsText $b.Target)
    Assert "B5 the fallback happened once, not per frame" ((Count-Log $b.Err $failLine) -eq 1)

    # ========================================================================
    "== C: a lost device on the composition path rebuilds its chain"
    # ========================================================================
    Set-Knobs '1' $null '20'
    $c = Start-Arm 'c'
    Assert "C0 the arm's window came up" ($c.Top -ne [IntPtr]::Zero -and $null -ne $c.Win)
    for ($i = 0; $i -lt 8; $i++) {
        & $Exe +send-keys "--target=$($c.Target)" "echo lost-$i" Enter 2>$null | Out-Null
        Start-Sleep -Milliseconds 200
    }
    Assert "C1 the simulated loss was detected" (Wait-Log $c.Err 'graphics device lost \(simulated' 20000)
    Assert "C2 the device was rebuilt" (Wait-Log $c.Err 'graphics device rebuilt after' 20000)
    & $Exe +send-keys "--target=$($c.Target)" 'echo after-rebuild' Enter 2>$null | Out-Null
    $again = $false
    for ($t = 0; $t -lt 50 -and -not $again; $t++) {
        $again = (Count-Log $c.Err $onLine) -ge 2
        if (-not $again) { Start-Sleep -Milliseconds 200 }
    }
    Assert "C3 the rebuilt context built its chain again" $again
    Assert "C4 the app is still running" (Test-Alive $c)
    Assert "C5 the rebuilt pane draws text" (Test-DrawsText $c.Target)
    Assert "C6 nothing fell back" ((Count-Log $c.Err $failLine) -eq 0)

    # ========================================================================
    "== D: negative control - with the knob off, nothing takes the new path"
    # ========================================================================
    Set-Knobs $null $null $null
    $d = Start-Arm 'd'
    Assert "D0 the arm's window came up" ($d.Top -ne [IntPtr]::Zero -and $null -ne $d.Win)
    & $Exe +send-keys "--target=$($d.Target)" 'echo plain-wgl' Enter 2>$null | Out-Null
    Start-Sleep -Milliseconds 1200
    Assert "D1 the pane draws text" (Test-DrawsText $d.Target)
    $text = Read-Text $d.Err
    Assert "D2 and no composition line was logged" `
        ($text -notmatch $onLine -and $text -notmatch $failLine -and $text -notmatch $unavailLine)

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
        update -Guard comp-present -Repo (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path 2>&1 |
        ForEach-Object { Write-Host "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:passes -Fail $script:failures -Label 'comp-present' -MinPass 25
