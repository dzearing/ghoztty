# T2342 acceptance: a new window opens MAXIMIZED by default, as Mac's do since
# main's a0aaed0f2 flipped the shared `maximize` default to true, and
# `maximize = false` brings back the restored size.
#
# THE CHANGE. `src/config/Config.zig` `maximize` is shared core, so the flip
# arrived with the T2343 merge and win32's Window.init already honours it
# (`window_placement.startMaximized`). Nothing measured that end to end, and
# every other GUI harness now pins `--maximize=false` in Start-OnTestDesktop so
# its geometry stays a choice it made - so this is the one script that launches
# with the PRODUCT default (-DefaultMaximize) and reads what a user would get.
#
# CASES, each its own app:
#
#   A) default config  -> the startup window is maximized (IsZoomed), and its
#      restore-down rect is smaller than the maximized one - a real maximize,
#      not a window that was merely sized to the screen or made full screen.
#   B) `+new-window` into A's app -> the second window is maximized too: the
#      default applies to every new window, not only the first.
#   C) `--maximize=false` -> the startup window is NOT maximized: the opt-out
#      works, and is A's negative control (an IsZoomed oracle that read true
#      for every window would pass A and B and fail here).
#
# Ctrl+Shift+N is the same Window.init path as `+new-window` and needs real
# keyboard input, which the test desktop cannot deliver; session restore's own
# maximized flag is applyRestoreFrame's, covered by the session-restore
# harnesses.
#
# Runs on a BACKGROUND Win32 desktop, so it never takes the user's foreground -
# asserted at the end, not assumed. Only touches ghoztty processes running from
# this repo's zig-out.
param([string]$ExePath, [switch]$Interactive)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }

. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
Set-GhozttyTestIsolation -Tag 't2342max' | Out-Null

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

# session-persistence=false: a persisted session would restore a LAYOUT whose
# own maximized flag outranks the default under test.
$base = @('--config-default-files=false', '--session-persistence=false')

function Start-Case([string[]]$Extra, [switch]$Default, [string]$Name) {
    Reset-GhozttyTestState -Exe $exe | Out-Null
    $app = Start-OnTestDesktop -Exe $exe -Arguments ($base + $Extra) -DefaultMaximize:$Default
    $top = Wait-TestWindow -ProcessId ([int]$app.Pid) -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) {
        Write-TestGuiPostmortem -ProcessId ([int]$app.Pid) | Out-Null
        Write-Host "SETUP FAIL: top window not found ($Name)"; exit 1
    }
    # The first show is posted after the first pane is ready; give it a beat
    # so IsZoomed reads the shown state rather than the created one.
    Start-Sleep -Seconds 2
    return [pscustomobject]@{ App = $app; Top = $top }
}

Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    # --- A: the default ---------------------------------------------------
    $a = Start-Case -Default -Name 'A'
    Assert (-not (Test-TestDesktopLeak -ProcessId ([int]$a.App.Pid))) `
        'A: GUI is NOT enumerable on the interactive desktop'
    $zoomedA = [bool](Test-TestWindowZoomed -Window $a.Top)
    Assert $zoomedA "A: default config opens the window maximized (IsZoomed=$zoomedA)"
    $cur = Get-TestWindowRect -Window $a.Top
    $normal = Get-TestWindowNormalRect -Window $a.Top
    Assert (($normal.Width -lt $cur.Width) -and ($normal.Height -lt $cur.Height)) `
        "A: restore-down size $($normal.Width)x$($normal.Height) is smaller than the maximized $($cur.Width)x$($cur.Height)"

    # --- B: +new-window into the same app ------------------------------------
    $before = @(Get-TestWindows -ProcessId ([int]$a.App.Pid))
    $r = Invoke-OnTestDesktop -Exe $exe -Arguments @('+new-window', '--target=t2342-second') -TimeoutSec 30
    Assert (-not $r.TimedOut -and $r.ExitCode -eq 0) "B: +new-window answered (exit $($r.ExitCode))"
    $second = $null
    for ($i = 0; $i -lt 40 -and -not $second; $i++) {
        $now = @(Get-TestWindows -ProcessId ([int]$a.App.Pid))
        $second = $now | Where-Object { $before.Hwnd -notcontains $_.Hwnd } | Select-Object -First 1
        if (-not $second) { Start-Sleep -Milliseconds 250 }
    }
    Assert ($null -ne $second) 'B: a second top-level window appeared'
    if ($second) {
        Start-Sleep -Seconds 1
        $zoomedB = [bool](Test-TestWindowZoomed -Window ([IntPtr]$second.Hwnd))
        Assert $zoomedB "B: the +new-window window opens maximized too (IsZoomed=$zoomedB)"
    }

    # --- C: maximize = false (A's negative control) ----------------------------
    $c = Start-Case -Extra @('--maximize=false') -Name 'C'
    $zoomedC = [bool](Test-TestWindowZoomed -Window $c.Top)
    Assert (-not $zoomedC) "C: maximize=false opens the window restored (IsZoomed=$zoomedC)"
}
finally {
    Reset-GhozttyTestState -Exe $exe | Out-Null
    Remove-TestDesktop
}

$fgSeen = @(Stop-TestForegroundWatch)
$leaked = @(Get-TestLaunchedPids | Where-Object { $fgSeen -contains $_ })
Assert ($leaked.Count -eq 0) `
    'no test-desktop app ever became foreground on the interactive desktop'

# --- stamp (T783) ----------------------------------------------------------
if ($script:fail -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard new-window-maximized -Repo $repo 2>&1 | ForEach-Object { Write-Host "  $_" }
}

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILURE(S) ($script:pass passed)" -ForegroundColor Red }
exit ([int]($script:fail -gt 0))
