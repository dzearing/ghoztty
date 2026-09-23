# Lost graphics device acceptance (tracker T1690).
#
# THE DEFECT: on 2026-09-20 Windows Update replaced the NVIDIA display driver
# under a running Ghoztty and every window vanished at once - the renderer's
# OpenGL context was a plain `wglCreateContext` one, which has no contract at
# all for a device reset, and the driver took the process down with it. The
# sessions survived in the agent; the terminal the user was looking at did not.
#
# THE CONTRACT this asserts:
#
#   1. Contexts are created ROBUST (`WGL_ARB_create_context_robustness`, lose
#      context on reset) on a driver that offers it, which is what turns a
#      device reset from undefined behaviour into a status the renderer can read.
#   2. When a pane's device is lost, the app does not exit: the pane throws its
#      context away, builds a new one on the same window, rebuilds its GPU
#      resources, and DRAWS AGAIN - asserted on the pane's real pixels, read
#      back through the renderer (`capture-pane`, lib\PaneCapture.ps1), not on a
#      log line alone. A rebuild that produced a context but lost the glyph
#      atlas or the shaders would show up here as a flat or wrong capture.
#   3. A device that stays unusable for a while (a driver being REPLACED leaves
#      the machine on the basic display adapter) is retried on a backoff until
#      it comes back, and the app stays up throughout.
#   4. The negative control: with nothing simulated, a healthy device is NEVER
#      reported lost. The reset-status check runs every frame; a false positive
#      would rebuild every pane in a loop.
#
# A real driver reset is not something to do to a box a user is sitting at, so
# the loss is SIMULATED through two DEBUG-ONLY seams in `src/renderer/OpenGL.zig`
# (never compiled into a release build):
#   GHOZTTY_GL_SIMULATE_RESET_AFTER=<n>       report the context lost after n frames
#   GHOZTTY_GL_SIMULATE_REBUILD_FAILURES=<k>  the first k rebuild attempts fail
# Only the DETECTION is simulated. The rebuild is the shipping one: the live
# context is really deleted and a new one really created, so what the capture
# proves is that a pane draws from a brand-new context.
#
# Runs on a BACKGROUND Win32 desktop (lib\TestDesktop.ps1), hermetically:
# private IPC endpoint, per-arm $env:LOCALAPPDATA, and it only ever kills
# ghoztty processes launched from the repo zig-out.
#
#   powershell -NoProfile -File test\win32\gl-device-lost.ps1

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

$root = Join-Path $env:TEMP "ghoztty-gl-device-lost-$PID"
$savedLocalAppData = $env:LOCALAPPDATA
$savedResetAfter = $env:GHOZTTY_GL_SIMULATE_RESET_AFTER
$savedRebuildFailures = $env:GHOZTTY_GL_SIMULATE_REBUILD_FAILURES

[void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)
New-Item -ItemType Directory -Force $root | Out-Null

[void](Set-GhozttyTestIsolation -Tag 'gllost')
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

# Wait until $pattern appears in the captured stderr, or the timeout passes.
function Wait-Log($path, $pattern, $timeoutMs) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $timeoutMs) {
        if ((Read-Text $path) -match $pattern) { return $true }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

# The pane's rendered glass, retried: right after a rebuild there is no
# presented frame yet, and the capture answers "no frame" until there is.
function Wait-Capture($target) {
    for ($t = 0; $t -lt 40; $t++) {
        $shot = Get-TestPaneCapture -Target $target
        if ($shot) { return $shot }
        Start-Sleep -Milliseconds 250
    }
    return $null
}

# Everything logged after the first line matching $anchor.
function Get-LogAfter($text, $anchor) {
    $m = [regex]::Match($text, $anchor)
    if (-not $m.Success) { return '' }
    return $text.Substring($m.Index)
}

# Launch one app for an arm, open a tinted window in it and return both.
function Start-Arm($name, $tint) {
    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)
    $dir = Join-Path $root $name
    New-Item -ItemType Directory -Force $dir | Out-Null
    $env:LOCALAPPDATA = $dir
    $err = Join-Path $dir 'stderr.txt'
    $app = Start-OnTestDesktop -Exe $Exe -Arguments @(
        '--config-default-files=false', '--session-persistence=false',
        "--title=t1690-$name") -StdErr $err
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow' -TimeoutMs 30000
    & $Exe +new-window "--target=lost$name" "--color=$tint" | Out-Null
    $win = Wait-Win "lost$name"
    return [pscustomobject]@{ App = $app; Err = $err; Top = $top; Win = $win; Target = "lost$name" }
}

try {
    # ========================================================================
    "== A: a lost device is rebuilt in place and the pane draws again"
    # ========================================================================
    $env:GHOZTTY_GL_SIMULATE_RESET_AFTER = '3'
    Remove-Item env:GHOZTTY_GL_SIMULATE_REBUILD_FAILURES -ErrorAction SilentlyContinue
    $a = Start-Arm 'a' '#204080'
    Assert "A0 the arm's window came up" ($a.Top -ne [IntPtr]::Zero -and $null -ne $a.Win)

    Assert "A1 contexts are created robust on this driver" `
        (Wait-Log $a.Err 'GL context created robust=true' 10000)
    Assert "A2 the simulated loss was detected" `
        (Wait-Log $a.Err 'graphics device lost \(simulated' 20000)
    Assert "A3 and the device was rebuilt on the first attempt" `
        (Wait-Log $a.Err 'graphics device rebuilt after 1 attempt\(s\)' 20000)

    # Output after the rebuild, so the capture below is of a frame drawn
    # entirely in the new context rather than one left over from the old.
    & $Exe +send-keys "--target=$($a.Target)" 'echo rebuilt-t1690' Enter 2>$null | Out-Null
    Start-Sleep -Milliseconds 800

    $alive = $a.App.Process -and -not $a.App.Process.HasExited
    Assert "A4 the app is still running" $alive
    Assert "A5 and the window is still there" ($null -ne (Get-Win $a.Target))

    $shotA = Wait-Capture $a.Target
    Assert "A6 the rebuilt pane hands back a frame ($(Get-LastPaneCaptureError))" ($null -ne $shotA)
    if ($shotA) {
        $colors = Get-TestPaneColorCount -Shot $shotA
        # Glyphs antialiased over the tint: a rebuild that lost the atlas or
        # the text pipeline would capture as a flat fill.
        Assert "A7 it draws text, not a flat fill ($colors distinct colors, >= 8)" ($colors -ge 8)
        $dom = Get-TestPaneDominantColor -Shot $shotA
        Assert "A8 and it is this pane's glass, tint #204080 (dominant $dom)" `
            (Test-PaneColorNear -Color $dom -R 0x20 -G 0x40 -B 0x80)
        Close-TestPaneCapture $shotA
    }

    $textA = Read-Text $a.Err
    $afterA = Get-LogAfter $textA 'graphics device rebuilt'
    Assert "A9 the new context raised no OpenGL errors" `
        ($afterA.Length -gt 0 -and $afterA -notmatch 'error\(opengl\)')
    Assert "A10 and nothing reports a failed draw after the rebuild" `
        ($afterA -notmatch 'error drawing err=')

    # ========================================================================
    "== B: a device that stays unusable is retried until it comes back"
    # ========================================================================
    $env:GHOZTTY_GL_SIMULATE_RESET_AFTER = '3'
    $env:GHOZTTY_GL_SIMULATE_REBUILD_FAILURES = '3'
    $b = Start-Arm 'b' '#802040'
    Assert "B0 the arm's window came up" ($b.Top -ne [IntPtr]::Zero -and $null -ne $b.Win)

    Assert "B1 the loss was detected" `
        (Wait-Log $b.Err 'graphics device lost \(simulated' 20000)
    $textB = ''
    $rebuiltB = Wait-Log $b.Err 'graphics device rebuilt after 4 attempt\(s\)' 30000
    $textB = Read-Text $b.Err
    $failedB = ([regex]::Matches($textB, 'graphics device rebuild attempt \d+ failed')).Count
    Assert "B2 the failed attempts were retried, not abandoned ($failedB failure lines)" ($failedB -ge 3)
    Assert "B3 and the fourth attempt rebuilt it" $rebuiltB
    Assert "B4 the app stayed up throughout" ($b.App.Process -and -not $b.App.Process.HasExited)

    $shotB = Wait-Capture $b.Target
    Assert "B5 the pane draws again ($(Get-LastPaneCaptureError))" ($null -ne $shotB)
    if ($shotB) {
        $domB = Get-TestPaneDominantColor -Shot $shotB
        Assert "B6 with its own tint #802040 (dominant $domB)" `
            (Test-PaneColorNear -Color $domB -R 0x80 -G 0x20 -B 0x40)
        Close-TestPaneCapture $shotB
    }

    # ========================================================================
    "== C: negative control - a healthy device is never reported lost"
    # ========================================================================
    Remove-Item env:GHOZTTY_GL_SIMULATE_RESET_AFTER -ErrorAction SilentlyContinue
    Remove-Item env:GHOZTTY_GL_SIMULATE_REBUILD_FAILURES -ErrorAction SilentlyContinue
    $c = Start-Arm 'c' '#206040'
    Assert "C0 the arm's window came up" ($c.Top -ne [IntPtr]::Zero -and $null -ne $c.Win)
    & $Exe +send-keys "--target=$($c.Target)" 'echo healthy-t1690' Enter 2>$null | Out-Null
    $shotC = Wait-Capture $c.Target
    Assert "C1 the pane draws ($(Get-LastPaneCaptureError))" ($null -ne $shotC)
    if ($shotC) { Close-TestPaneCapture $shotC }
    Start-Sleep -Seconds 2
    $textC = Read-Text $c.Err
    Assert "C2 contexts are robust here too" ($textC -match 'GL context created robust=true')
    Assert "C3 and with every frame checked, nothing was ever reported lost" `
        ($textC -notmatch 'graphics device lost')

    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)

    # LAST statement of the top-level try (T1039).
    Complete-TestBody
} finally {
    if ($savedResetAfter) { $env:GHOZTTY_GL_SIMULATE_RESET_AFTER = $savedResetAfter }
    else { Remove-Item env:GHOZTTY_GL_SIMULATE_RESET_AFTER -ErrorAction SilentlyContinue }
    if ($savedRebuildFailures) { $env:GHOZTTY_GL_SIMULATE_REBUILD_FAILURES = $savedRebuildFailures }
    else { Remove-Item env:GHOZTTY_GL_SIMULATE_REBUILD_FAILURES -ErrorAction SilentlyContinue }
    $env:LOCALAPPDATA = $savedLocalAppData
    Remove-TestDesktop
    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)
    Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
}

# --- stamp (T783) ----------------------------------------------------------
if ($script:failures -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot '..\..\scripts\guard-due.ps1') `
        update -Guard gl-device-lost -Repo (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path 2>&1 |
        ForEach-Object { Write-Host "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:passes -Fail $script:failures -Label 'gl-device-lost' -MinPass 22
