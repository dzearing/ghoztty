# Single-window mode on Windows (T3136, split T3180-T3187) - one section per
# child task. Spec: docs/reference/window-modes.md (Mac 3f772a2f0).
#
# A (T3180): `macos-window-mode` is read ONCE, at launch. A launch whose
#   config says `single` runs single; Settings > Panes & Windows carries Mac's
#   "Open windows" row (Each in its own window / All in one window) with the
#   "takes effect the next time Ghoztty starts" note; choosing the other value
#   there writes the file but does NOT move the running app's mode; the next
#   launch comes up in the new mode.
#
# THE ORACLE IS THE LATCH AND THE FILE. The mode the app runs in is a decision
# invisible in pixels (until T3181 gives it a window to act on), so it is read
# through the debug-only `settings` IPC action's `window_mode` field, which
# answers `window_mode.current()` - the same function every mode-dependent path
# asks. The row is read from the same seam and the write from the file itself.
#
# Runs on the BACKGROUND test desktop (lib\TestDesktop.ps1), so it never
# steals the user's foreground.
#
# -NegativeControl asserts the write DID move the running mode - that run
# MUST fail.
#
# Only touches ghoztty processes running from this repo's zig-out*.
param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }
$env:GHOZTTY_PIPE_SUFFIX = "-swm$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\PaneCapture.ps1')   # Invoke-GhozttyIpc
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
. (Join-Path $PSScriptRoot 'lib\AgentLineage.ps1')

[void](Assert-GhozttyIsolatedBuild -Exe $exe)

$script:pass = 0
$script:fail = 0
$script:skipped = 0
$script:negReached = $false

function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Kill-RepoInstances {
    [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
}

function Invoke-Settings([string[]]$ipcArgs) {
    return Invoke-GhozttyIpc -Action 'settings' -Arguments $ipcArgs
}

function Find-Row($state, [string]$key) {
    foreach ($r in @($state.data.rows)) { if ([string]$r.key -eq $key) { return $r } }
    return $null
}

function Get-KeyLines([string]$key) {
    if (-not (Test-Path $cfgFile)) { return @() }
    $text = [System.IO.File]::ReadAllText($cfgFile)
    return @(($text -split "`r?`n") | Where-Object { $_ -match ('^\s*' + [regex]::Escape($key) + '\s*=') })
}

$work = Join-Path $env:TEMP "ghoztty-swm-$PID"
$cfgHome = Join-Path $work 'xdg'
$cfgDir = Join-Path $cfgHome 'ghostty'
$cfgFile = Join-Path $cfgDir 'config-debug.ghostty'
$backupDir = Join-Path $work 'backups'
New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null
[System.IO.File]::WriteAllText($cfgFile, "macos-window-mode = single`n")

$errlog = Join-Path $env:TEMP "ghoztty-swm-stderr-$PID.log"
$script:launched = @()
$app = $null

# Launches the app on the test desktop with the temp config; returns $null
# (after recording why) when it does not come up.
function Start-App([string]$label) {
    $env:XDG_CONFIG_HOME = $cfgHome
    $env:GHOZTTY_SETTINGS_BACKUP_DIR = $backupDir
    $env:GHOZTTY_UPDATE_URL = 'http://127.0.0.1:9/releases'
    try {
        $sp = @{
            Exe       = $exe
            Arguments = @('--session-persistence=false', '--background=#101014')
        }
        if (-not $ExePath) { $sp.StdErr = $errlog }
        $a = Start-OnTestDesktop @sp
    } finally {
        Remove-Item Env:XDG_CONFIG_HOME -ErrorAction SilentlyContinue
        Remove-Item Env:GHOZTTY_SETTINGS_BACKUP_DIR -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 3
    if (-not $a -or ($a.Process -and $a.Process.HasExited)) {
        Write-TestAssertedNothing -Reason "GUI did not come up ($label)" -Label 'single-window-mode'
        return $null
    }
    $script:launched += $script:GhozttyTestDesktopPids
    $top = Wait-TestWindow -ProcessId $a.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) {
        Write-TestAssertedNothing -Reason "no terminal window appeared ($label)" -Label 'single-window-mode'
        return $null
    }
    return $a
}

[void](Set-GhozttyTestAgentLineage -Tag 'swm' -Quiet)
Kill-RepoInstances
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    if ($NegativeControl) {
        Write-Host "NEGATIVE CONTROL: section A asserts the Settings write DID move the running mode - this run MUST fail"
    }

    # =====================================================================
    # A (T3180): read once at launch; the Settings row; next launch.
    # =====================================================================
    $app = Start-App 'launch 1'
    if (-not $app) { exit 1 }

    # The seam answers state only while the Settings window is open.
    $s = Invoke-Settings @('--op=open')
    if (-not $s -or -not $s.success) {
        Write-TestAssertedNothing -Reason 'the settings IPC action never answered' -Label 'single-window-mode'
        exit 1
    }
    Assert ([string]$s.data.window_mode -eq 'single') "A: a launch whose config says single runs single (window_mode='$($s.data.window_mode)')"

    $s = Invoke-Settings @('--op=state', '--page=panes')
    Assert ([string]$s.data.page -eq 'panes') "A: Settings shows Panes & Windows (page='$($s.data.page)')"
    $row = Find-Row $s 'macos-window-mode'
    Assert ($null -ne $row) 'A: Panes & Windows lists macos-window-mode'
    if ($row) {
        Assert ([string]$row.label -eq 'Open windows') "A: the row reads Mac's 'Open windows' (got '$($row.label)')"
        Assert ([string]$row.shown -eq 'All in one window') "A: single reads 'All in one window' (got '$($row.shown)')"
        Assert ([string]$row.hint -match 'next time Ghoztty starts') "A: the row says it takes effect at the next launch (hint='$($row.hint)')"
        Assert ([string]$row.control -eq 'segmented') "A: Mac's segmented choice (got '$($row.control)')"
    }

    # The Settings write, the same function a click on the popup calls.
    $s = Invoke-Settings @('--op=set', '--key=macos-window-mode', '--value=separate')
    Assert ($null -ne $s -and $s.success) 'A: choosing Each in its own window is accepted'
    $lines = @(Get-KeyLines 'macos-window-mode')
    Assert ($lines.Count -eq 1 -and $lines[0] -match '=\s*separate\s*$') "A: the file now says separate ($($lines -join ' | '))"
    $row = Find-Row (Invoke-Settings @('--op=state', '--page=panes')) 'macos-window-mode'
    Assert ($row -and [string]$row.shown -eq 'Each in its own window') "A: the row reads the new value ('$($row.shown)')"

    # Give the reload the write triggered time to land, then ask again.
    Start-Sleep -Milliseconds 1500
    $s = Invoke-Settings @('--op=state')
    if ($NegativeControl) {
        $script:negReached = $true
        Assert ([string]$s.data.window_mode -eq 'separate') "A (NEGATIVE): the running mode moved with the file (window_mode='$($s.data.window_mode)')"
    } else {
        Assert ([string]$s.data.window_mode -eq 'single') "A: the running app stays single until the next launch (window_mode='$($s.data.window_mode)')"
    }
    [void](Invoke-Settings @('--op=close'))
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'A: no crash (launch 1)'

    # The next launch reads the file again.
    Stop-Process -Id $app.Pid -Force -ErrorAction SilentlyContinue
    Kill-RepoInstances
    $app = Start-App 'launch 2'
    if (-not $app) { exit 1 }
    $s = Invoke-Settings @('--op=open')
    Assert ([string]$s.data.window_mode -eq 'separate') "A: the next launch comes up in the new mode (window_mode='$($s.data.window_mode)')"

    # And with no line at all, the default is separate (as before the option).
    Stop-Process -Id $app.Pid -Force -ErrorAction SilentlyContinue
    Kill-RepoInstances
    [System.IO.File]::WriteAllText($cfgFile, "font-size = 13`n")
    $app = Start-App 'launch 3'
    if (-not $app) { exit 1 }
    $s = Invoke-Settings @('--op=open')
    Assert ([string]$s.data.window_mode -eq 'separate') "A: no config line means separate (window_mode='$($s.data.window_mode)')"
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'A: no crash (launch 3)'

    Complete-TestBody
} catch {
    Write-Host "ERROR $_" -ForegroundColor Red
    $script:fail++
} finally {
    if ($app) { Stop-Process -Id $app.Pid -Force -ErrorAction SilentlyContinue }
    Remove-TestDesktop
    Kill-RepoInstances
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}

$fgSeen = @(Stop-TestForegroundWatch)
Write-Host "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $script:launched = @($script:launched | Select-Object -Unique)
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    $leaked = @($script:launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) "no test-desktop app ever became foreground on the interactive desktop (saw $($leaked -join ','))"
}

if ($NegativeControl -and -not $script:negReached) {
    Assert $false 'NEGATIVE CONTROL never reached its inverted assertion'
}

# --- stamp (T783) ---------------------------------------------------------
if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard single-window-mode -Repo $repo 2>&1 | ForEach-Object { Write-Host "  $_" }
}

Write-TestVerdict -Pass $script:pass -Fail $script:fail -Skipped $script:skipped -Label 'single-window-mode'
