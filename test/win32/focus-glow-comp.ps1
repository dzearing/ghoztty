# Acceptance for the focus glow fading on the compositor (tracker T2574).
#
# With the desk on the chrome host's visual (GHOZTTY_COMP_CHROME=1, elevated
# panes, opaque window) the focused card's glow is no longer composed into the
# desk. It goes up as its own premultiplied layer under the overlay, and a focus
# move is one opacity animation per layer, handed to DWM in one commit. Before
# this, every 16ms tick of the 250ms fade recomposed and re-uploaded the desk on
# the UI thread.
#
#   A. Compositor arm: the desk visual attaches. A split lights the new pane
#      (one layer), and a second split moves the glow to the newest pane (two
#      layers: the one it leaves fades out). Each move logs its fade declared
#      on the compositor, and then logs it done with desk_uploads=0: nothing
#      went up to the desk while the glow moved.
#   B. Negative control (debug seam GHOZTTY_DEBUG_GLOW_STEPPED=1, the A/B arm):
#      the same moves keep the glow in the desk and step it, so no
#      compositor fade is ever logged. This is the run that shows A's lines
#      come from the new path and not from the log in general.
#
# NOT asserted here: the PICTURE. This harness runs on a background desktop,
# which DWM never composes and Windows.Graphics.Capture refuses (T2463). Pixel
# equivalence of the layer with the window's own glow is the unit test
# "T2574: the glow layer faded to L over the unlit desk is the desk composed
# at glow level L" in src/apprt/win32/PaneDesk.zig. Seeing it on screen is the
# on-screen oracle's job, on the input desktop.
#
#   powershell -NoProfile -File test\win32\focus-glow-comp.ps1

param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [switch]$Interactive
)

$ErrorActionPreference = 'Continue'
Set-StrictMode -Off

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\HarnessLeak.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:passes = 0
$script:failures = 0
function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ }
    else { "  FAIL $name"; $script:failures++ }
}

if (-not (Test-Path $Exe)) { "SETUP FAIL: $Exe not found - build it first"; exit 2 }

$root = Join-Path $env:TEMP "ghoztty-focus-glow-comp-$PID"
$savedLocalAppData = $env:LOCALAPPDATA
$knobs = 'GHOZTTY_COMP_CHROME', 'GHOZTTY_DEBUG_GLOW_STEPPED'
$saved = @{}
foreach ($k in $knobs) { $saved[$k] = [Environment]::GetEnvironmentVariable($k) }

function Set-Knobs($on, $stepped) {
    $vals = @{ GHOZTTY_COMP_CHROME = $on; GHOZTTY_DEBUG_GLOW_STEPPED = $stepped }
    foreach ($k in $knobs) {
        if ($vals[$k]) { Set-Item "env:$k" $vals[$k] }
        else { Remove-Item "env:$k" -ErrorAction SilentlyContinue }
    }
}

[void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)
New-Item -ItemType Directory -Force $root | Out-Null

[void](Set-GhozttyTestIsolation -Tag 'focusglow')
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

function Count-Log($path, $pattern) {
    return ([regex]::Matches((Read-Text $path), $pattern)).Count
}

function Wait-Count($path, $pattern, $n, $timeoutMs) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $timeoutMs) {
        if ((Count-Log $path $pattern) -ge $n) { return $true }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

function Start-Arm($name) {
    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)
    $dir = Join-Path $root $name
    New-Item -ItemType Directory -Force $dir | Out-Null
    $env:LOCALAPPDATA = $dir
    $err = Join-Path $dir 'stderr.txt'
    $app = Start-OnTestDesktop -Exe $Exe -Arguments @(
        '--config-default-files=false', '--session-persistence=false',
        "--title=t2574-$name") -StdErr $err
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow' -TimeoutMs 30000
    & $Exe +new-window "--target=glow$name" | Out-Null
    $win = Wait-Win "glow$name"
    return [pscustomobject]@{ App = $app; Err = $err; Top = $top; Win = $win; Target = "glow$name" }
}

function Test-Alive($arm) { return ($arm.App.Process -and -not $arm.App.Process.HasExited) }

# Focus moves: a split lights the new pane, then the glow is moved between
# named panes by the debug build's focus link (the IPC `focus` the CLI and the
# palette's jump share), which on the background desktop does not depend on a
# split taking focus.
function Invoke-Moves($arm) {
    & $Exe +split "--target=$($arm.Target)" '--direction=right' "--name=$($arm.Target)b" 2>$null | Out-Null
    Start-Sleep -Milliseconds 900
    & $Exe +split "--target=$($arm.Target)b" '--direction=down' "--name=$($arm.Target)c" 2>$null | Out-Null
    Start-Sleep -Milliseconds 900
    foreach ($n in 'c', 'b', 'c') {
        # The debug build's scheme (url-scheme.ps1): the activation is a
        # client that forwards a `focus` over the run's pipe and exits.
        $link = "ghoztty-debug://focus/$($arm.Target)$n"
        & $Exe $link 2>&1 | Out-Null
        Start-Sleep -Milliseconds 900
    }
}

$deskLine = 'chrome desk visual attached'
$fadeLine = 'focus glow fade on the compositor layers=(\d+) uploads=\d+'
$doneLine = 'focus glow fade on the compositor done desk_uploads=(\d+)'
$failLine = 'focus glow layer \w+ failed'

try {
    # ========================================================================
    "== A: on the compositor, a focus move is a declared fade and no desk upload"
    # ========================================================================
    Set-Knobs '1' $null
    $a = Start-Arm 'a'
    Assert "A0 the arm's window came up" ($a.Top -ne [IntPtr]::Zero -and $null -ne $a.Win)
    if ($a.Top -ne [IntPtr]::Zero) { [void](Set-TestWindowSize -Window $a.Top -Width 1000 -Height 640) }
    Assert "A1 the desk went up as the chrome host's visual" (Wait-Count $a.Err $deskLine 1 15000)
    Invoke-Moves $a
    Assert "A2 every move declared its fade on the compositor ($(Count-Log $a.Err $fadeLine))" (Wait-Count $a.Err $fadeLine 3 8000)
    $layers = @([regex]::Matches((Read-Text $a.Err), $fadeLine) | ForEach-Object { [int]$_.Groups[1].Value })
    "  layers per move: $($layers -join ',')"
    Assert "A3 the first move lit one layer, a move between panes two (the pane it left fading out)" `
        ($layers.Count -ge 3 -and $layers[0] -eq 1 -and $layers[-1] -eq 2)
    Assert "A4 each fade ran out on its own clock ($(Count-Log $a.Err $doneLine))" (Wait-Count $a.Err $doneLine $layers.Count 8000)
    $uploads = @([regex]::Matches((Read-Text $a.Err), $doneLine) | ForEach-Object { [int]$_.Groups[1].Value })
    "  desk uploads during each fade: $($uploads -join ',')"
    Assert "A5 nothing went up to the desk while the glow moved" `
        ($uploads.Count -ge 3 -and @($uploads | Where-Object { $_ -ne 0 }).Count -eq 0)
    Assert "A6 no glow layer step failed" ((Count-Log $a.Err $failLine) -eq 0)
    Assert "A7 the app is still running" (Test-Alive $a)
    if ($script:failures -gt 0) { Copy-Item $a.Err (Join-Path $env:TEMP 'focus-glow-comp-a-stderr.txt') -Force -ErrorAction SilentlyContinue }

    # ========================================================================
    "== B: negative control - the stepped arm keeps the glow in the desk"
    # ========================================================================
    Set-Knobs '1' '1'
    $b = Start-Arm 'b'
    Assert "B0 the arm's window came up" ($b.Top -ne [IntPtr]::Zero -and $null -ne $b.Win)
    if ($b.Top -ne [IntPtr]::Zero) { [void](Set-TestWindowSize -Window $b.Top -Width 1000 -Height 640) }
    Assert "B1 the desk went up as the chrome host's visual" (Wait-Count $b.Err $deskLine 1 15000)
    Invoke-Moves $b
    Start-Sleep -Milliseconds 600
    Assert "B2 no fade was declared on the compositor" `
        ((Count-Log $b.Err $fadeLine) -eq 0 -and (Count-Log $b.Err $doneLine) -eq 0)
    Assert "B3 the app is still running" (Test-Alive $b)

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
        update -Guard focus-glow-comp -Repo (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path 2>&1 |
        ForEach-Object { Write-Host "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:passes -Fail $script:failures -Label 'focus-glow-comp' -MinPass 12
