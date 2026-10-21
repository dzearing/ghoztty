# @timing-sensitive - it asserts presents per second, which a busy box lowers (red beside other scripts, green alone on 2026-10-18; scripts/acceptance-parallel.ps1, T1960).
# T1951 acceptance: low-power rendering on a machine with no GPU.
#
# GitHub #13: a Windows 365 Cloud PC renders through Mesa d3d12 on WARP, so
# every present is rasterized on the CPU (16 panes in 11 windows ran 12-16
# cores). When the GL renderer is software, or the session is remote, each
# pane's presents are capped - the focused pane near 30 fps, the rest at 4 -
# and a window nobody can see presents nothing at all, in every mode.
#
# The software path is FORCED on this GPU box the way the Cloud PC reaches it:
# GHOZTTY_GL_FORCE_VERSION=1.1 (debug seam) makes the system OpenGL fall short,
# the app falls back to the bundled Mesa, and GALLIUM_DRIVER=d3d12 +
# LIBGL_ALWAYS_SOFTWARE=1 put Mesa's d3d12 driver on WARP ("D3D12 (Microsoft
# Basic Render Driver)"). Frame rates are read from GHOZTTY_PERF, which logs
# each pane's presents per second.
#
# What is asserted:
#
#   DETECTED. The log names the software renderer and says low-power is on.
#
#   CAPPED. With two panes printing a spinner (~16 updates a second), the
#   focused one presents at its full rate (>= 10 fps) and the unfocused one at
#   the cap (<= 6 fps).
#
#   HIDDEN. A window moved fully under another stops presenting; moved clear
#   again, it presents again.
#
#   CONTROLS. The same software path with GHOZTTY_LOW_POWER=off presents the
#   unfocused pane at full rate, and a plain hardware launch never enters
#   low-power mode.
#
# Runs on a background desktop (test/win32/lib/TestDesktop.ps1): nothing here
# takes the user's foreground, which is asserted at the end.
#
# -NegativeControl asserts the unfocused pane is NOT capped in the low-power
# run, and MUST fail.
#
#   powershell -NoProfile -File test\win32\low-power-render.ps1
param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }

$env:GHOZTTY_PIPE_SUFFIX = "-lowpwr$PID"
$env:GHOZTTY_PERF = '1'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:pass = 0
$script:fail = 0
$script:skipped = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Kill-RepoInstances {
    [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
}

$spin = Join-Path $env:TEMP "ghoztty-lowpwr-spin-$PID.ps1"
Set-Content -Path $spin -Encoding Ascii -Value @'
$c = '|/-\'
$i = 0
while ($true) { [Console]::Write("`r" + $c[$i % 4] + ' working ' + (Get-Date).ToString('HH:mm:ss.fff') + '   '); $i++; Start-Sleep -Milliseconds 50 }
'@
$spinCmd = "--command=powershell -NoProfile -ExecutionPolicy Bypass -File $spin"
$idleCmd = '--command=cmd.exe'

function Set-SoftwarePath([bool]$on) {
    if ($on) {
        $env:GHOZTTY_GL_FORCE_VERSION = '1.1'
        $env:GALLIUM_DRIVER = 'd3d12'
        $env:LIBGL_ALWAYS_SOFTWARE = '1'
    } else {
        Remove-Item Env:\GHOZTTY_GL_FORCE_VERSION, Env:\GALLIUM_DRIVER, Env:\LIBGL_ALWAYS_SOFTWARE -ErrorAction SilentlyContinue
    }
}

function Get-Tops([int]$procId) {
    @(Get-TestWindows -ProcessId $procId -Class 'GhozttyWindow' | ForEach-Object { [int64]$_.Hwnd })
}

# Open a named window and return its top-level HWND (the one that was not
# there before).
function New-NamedWindow([int]$procId, [string]$name, [string]$cmd) {
    $before = Get-Tops $procId
    & $exe +new-window "--target=$name" $cmd | Out-Null
    for ($t = 0; $t -lt 30; $t++) {
        Start-Sleep -Milliseconds 200
        $new = @(Get-Tops $procId | Where-Object { $before -notcontains $_ })
        if ($new.Count -ge 1) { return [IntPtr]$new[0] }
    }
    return [IntPtr]::Zero
}

function Get-LogText([string]$path) {
    try { return [IO.File]::ReadAllText($path) } catch {
        $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
        try { return (New-Object IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() }
    }
}

# Per-pane average fps in the log written after $fromLen, highest first.
function Get-PaneFps([string]$path, [int]$fromLen) {
    $text = Get-LogText $path
    $tail = $text.Substring([math]::Min($fromLen, $text.Length))
    $rows = @([regex]::Matches($tail, 'perf pane=(\S+) fps=(\d+)') | ForEach-Object { [pscustomobject]@{ Pane = $_.Groups[1].Value; Fps = [int]$_.Groups[2].Value } })
    @($rows | Group-Object Pane | ForEach-Object { ($_.Group | Measure-Object Fps -Average).Average } | Sort-Object -Descending)
}

function Measure-Fps([string]$path, [int]$seconds) {
    $from = (Get-LogText $path).Length
    Start-Sleep -Seconds $seconds
    return Get-PaneFps $path $from
}

function Format-Fps($list) { ($list | ForEach-Object { [math]::Round($_, 1) }) -join ' ' }

# Launch, then open F (spinner, focused) and U (spinner, unfocused).
function Start-Pair([string]$label) {
    Kill-RepoInstances
    # persistence: off - --session-persistence=false below; a restored layout
    # would bring panes whose frame rates this script did not set up.
    $app = Start-OnTestDesktop -Exe $exe -Arguments @('--config-default-files=false', '--session-persistence=false', $idleCmd)
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host "SETUP FAIL ($label): GUI died at launch"; exit 1 }
    $err = @($script:GhozttyTestDesktopLaunches | Where-Object { $_.Pid -eq $app.Pid })[0].StdErr
    $u = New-NamedWindow $app.Pid 'lp-u' $spinCmd
    $f = New-NamedWindow $app.Pid 'lp-f' $spinCmd
    Assert (($u -ne [IntPtr]::Zero) -and ($f -ne [IntPtr]::Zero)) "$label setup: both spinner windows opened"
    [void](Set-TestActiveWindow -Window $f)
    $fp = @(Get-TestChildWindows -Window $f -Class 'GhozttyTerminal')[0]
    [void](Focus-TestWindow -Window $f -Child ([IntPtr]$fp.Hwnd))
    $focusOk = $false
    for ($t = 0; $t -lt 20 -and -not $focusOk; $t++) {
        Start-Sleep -Milliseconds 100
        $focusOk = ([int64](Get-TestFocusedWindow -Window $f) -eq [int64]$fp.Hwnd)
    }
    Assert $focusOk "$label setup: F's pane holds the keyboard"
    Start-Sleep -Seconds 3
    [pscustomobject]@{ App = $app; Err = $err; U = $u; F = $f }
}

Kill-RepoInstances
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$launched = @()

try {

# ---------------------------------------------------------------------------
# Run 1: the software path, low-power decided by the app.
# ---------------------------------------------------------------------------
Set-SoftwarePath $true
Remove-Item Env:\GHOZTTY_LOW_POWER -ErrorAction SilentlyContinue
$g = Start-Pair 'software'
$launched += $script:GhozttyTestDesktopPids
$log = Get-LogText $g.Err
$gl = ($log -split "`n" | Select-String 'loaded OpenGL 4' | Select-Object -First 1)
Write-Host "      $(if ($gl) { $gl.Line.Trim() } else { '(no 4.x context logged)' })"
Assert ($log -match 'low-power rendering on: renderer="[^"]*Basic Render Driver') 'software: the WARP renderer is detected and low-power mode is logged with it'

$fps = Measure-Fps $g.Err 8
Write-Host "      software per-pane fps: $(Format-Fps $fps)"
Assert ($fps.Count -ge 2) "software: both spinner panes reported their frame rate (saw $($fps.Count))"
if ($fps.Count -ge 2) {
    Assert ($fps[0] -ge 10) "software: the focused pane presents at its full rate ($([math]::Round($fps[0],1)) fps >= 10)"
    if ($NegativeControl) {
        Write-Host 'NEGATIVE CONTROL: asserting the unfocused pane is NOT capped - this run MUST fail'
        Assert ($fps[1] -ge 10) 'software: the unfocused pane runs at full rate (negative control)'
    } else {
        Assert ($fps[1] -le 6) "software: the unfocused pane is capped ($([math]::Round($fps[1],1)) fps <= 6)"
    }
}

# Cover U with an idle window C, bigger on every side.
$c = New-NamedWindow $g.App.Pid 'lp-c' $idleCmd
$ur = Get-TestWindowRect -Window $g.U
[void](Set-TestWindowPos -Window $c -X ([int]$ur.Left - 40) -Y ([int]$ur.Top - 40) -Width ([int]($ur.Right - $ur.Left) + 80) -Height ([int]($ur.Bottom - $ur.Top) + 80))
Start-Sleep -Seconds 2
$fps = Measure-Fps $g.Err 6
$moving = @($fps | Where-Object { $_ -ge 2 }).Count
Write-Host "      U covered: per-pane fps: $(Format-Fps $fps)"
Assert ($moving -eq 1) "hidden: with U fully covered only the focused pane still presents (moving panes: $moving)"

[void](Set-TestWindowPos -Window $c -X ([int]$ur.Right + 200) -Y ([int]$ur.Top))
Start-Sleep -Seconds 2
$fps = Measure-Fps $g.Err 6
$moving = @($fps | Where-Object { $_ -ge 2 }).Count
Write-Host "      U revealed: per-pane fps: $(Format-Fps $fps)"
Assert ($moving -eq 2) "hidden: moved clear, U presents again (moving panes: $moving)"
Assert (-not ($g.App.Process -and $g.App.Process.HasExited)) 'software: no crash'
Stop-Process -Id $g.App.Pid -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# Run 2 (control): the same software path with low-power pinned off.
# ---------------------------------------------------------------------------
$env:GHOZTTY_LOW_POWER = 'off'
$g = Start-Pair 'software-off'
$launched += $script:GhozttyTestDesktopPids
$fps = Measure-Fps $g.Err 8
Write-Host "      low-power off per-pane fps: $(Format-Fps $fps)"
Assert (($fps.Count -ge 2) -and ($fps[1] -ge 10)) 'control: with low-power off the unfocused pane presents at full rate'
Stop-Process -Id $g.App.Pid -Force -ErrorAction SilentlyContinue
Remove-Item Env:\GHOZTTY_LOW_POWER -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# Run 3 (control): the hardware path never enters low-power mode.
# ---------------------------------------------------------------------------
Set-SoftwarePath $false
$g = Start-Pair 'hardware'
$launched += $script:GhozttyTestDesktopPids
$log = Get-LogText $g.Err
Assert (-not ($log -match 'low-power rendering on')) 'hardware: a GPU box does not enter low-power mode'
$fps = Measure-Fps $g.Err 8
Write-Host "      hardware per-pane fps: $(Format-Fps $fps)"
Assert (($fps.Count -ge 2) -and ($fps[1] -ge 10)) 'hardware: the unfocused pane presents at full rate'
Stop-Process -Id $g.App.Pid -Force -ErrorAction SilentlyContinue

} catch {
    $script:fail++
    Write-Host "FAIL  the run terminated: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "      at $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())"
} finally {
    Remove-TestDesktop
    Kill-RepoInstances
    Set-SoftwarePath $false
    Remove-Item Env:\GHOZTTY_LOW_POWER, Env:\GHOZTTY_PERF -ErrorAction SilentlyContinue
    Remove-Item $spin -ErrorAction SilentlyContinue
}

$fgSeen = @(Stop-TestForegroundWatch)
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @($launched | Select-Object -Unique)
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'no test-desktop app ever became foreground on the interactive desktop'
}

Complete-TestBody
if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard low-power-render -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Skipped $script:skipped -Label 'LOW-POWER RENDER ACCEPTANCE'
