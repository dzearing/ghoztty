# T3664 acceptance: the Settings window is on screen at once, even when the
# theme catalog is slow to read.
#
# The user's report (2026-11-24): "the settings pane takes quite a few seconds
# to pop open". Measured cause: the window opens on Appearance, whose theme
# picker read all ~500 theme files on the UI thread BEFORE the first
# ShowWindow, and the first read of an installed build's theme folder (fresh
# files after every update, scanned on open) took 1.3 s on this box against
# 17 ms on the dev drive. The fix shows the window first and reads the catalog
# on a worker thread; Appearance says "Loading themes..." until it lands.
#
# THE SLOW CATALOG IS INJECTED: a dev drive never reproduces the cold read, so
# the debug-only GHOZTTY_SETTINGS_THEME_DELAY_MS seam stretches the worker's
# read by $DelayMs.
#
# THE ORACLE IS THE WINDOW, WATCHED FROM OUTSIDE. The open request is written
# to the pipe and, while its answer is still pending, this script polls the
# test desktop for a visible GhozttySettings window. The IPC handler waits for
# the theme read before it answers (every settings op acts on the real
# catalog), so the answer arriving after the delay while the window was
# visible long before it is the proof that the window did not wait. The app's
# own self-report (`opened`) is checked too, as a second witness.
#
# Sections:
#   A  first open, slow catalog: visible within $BudgetMs, answer after the
#      delay, the self-report agrees, and the catalog then holds themes
#   B  a second open_config while open: answered (and focused) within budget
#   C  close + reopen: shown before the (again slow) catalog, themes again
#
# Runs on the BACKGROUND test desktop (lib\TestDesktop.ps1).
#
# -NegativeControl inverts A's load-bearing claim (asserts the window only
# appeared AFTER the slow read, the pre-fix behaviour) - that run MUST fail.
#
# Only touches ghoztty processes running from this repo's zig-out*.
param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive, [int]$DelayMs = 1500, [int]$BudgetMs = 700)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }
$env:GHOZTTY_PIPE_SUFFIX = "-setlat$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\PaneCapture.ps1')   # Invoke-GhozttyIpc, Read-PipeExact
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

function Invoke-Settings([string[]]$ipcArgs) {
    return Invoke-GhozttyIpc -Action 'settings' -Arguments $ipcArgs
}

# Send one `settings` request and, while its answer is pending, poll for a
# visible Settings window. Returns the ms until the window was first seen
# visible (-1: never), the ms until the answer arrived, and the answer.
function Measure-SettingsOpen([int]$AppPid, [string[]]$ipcArgs, [int]$TimeoutMs = 20000) {
    $res = [pscustomobject]@{ VisibleMs = -1; AnswerMs = -1; Answer = $null }
    $pipe = New-Object System.IO.Pipes.NamedPipeClientStream('.', (Get-GhozttyPipeName),
        [System.IO.Pipes.PipeDirection]::InOut, [System.IO.Pipes.PipeOptions]::Asynchronous)
    try {
        $pipe.Connect(5000)
        $json = @{ action = 'settings'; arguments = @($ipcArgs) } | ConvertTo-Json -Compress -Depth 5
        $payload = [System.Text.Encoding]::UTF8.GetBytes($json)
        $len = [System.BitConverter]::GetBytes([int]$payload.Length)
        [Array]::Reverse($len)
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $pipe.Write($len, 0, 4)
        $pipe.Write($payload, 0, $payload.Length)
        $pipe.Flush()
        $head = New-Object byte[] 4
        $read = $pipe.ReadAsync($head, 0, 4)
        while (-not $read.IsCompleted -and $sw.ElapsedMilliseconds -lt $TimeoutMs) {
            if ($res.VisibleMs -lt 0) {
                $w = @(Get-TestWindows -ProcessId $AppPid -Class 'GhozttySettings' | Where-Object { $_.Visible })
                if ($w.Count -gt 0) { $res.VisibleMs = [int]$sw.ElapsedMilliseconds }
            }
            Start-Sleep -Milliseconds 10
        }
        if (-not $read.Wait([Math]::Max(1, $TimeoutMs - [int]$sw.ElapsedMilliseconds))) { return $res }
        $res.AnswerMs = [int]$sw.ElapsedMilliseconds
        if ($res.VisibleMs -lt 0) {
            # Shown between the last poll and the answer: count it at the answer.
            $w = @(Get-TestWindows -ProcessId $AppPid -Class 'GhozttySettings' | Where-Object { $_.Visible })
            if ($w.Count -gt 0) { $res.VisibleMs = $res.AnswerMs }
        }
        if ($read.Result -ne 4) { return $res }
        [Array]::Reverse($head)
        $respLen = [System.BitConverter]::ToInt32($head, 0)
        $bytes = Read-PipeExact $pipe $respLen $TimeoutMs
        if ($bytes) { $res.Answer = [System.Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json }
    } catch {
        Write-Host "  (measure failed: $_)"
    } finally {
        try { $pipe.Dispose() } catch {}
    }
    return $res
}

$work = Join-Path $env:TEMP "ghoztty-setlat-$PID"
$cfgHome = Join-Path $work 'xdg'
$cfgDir = Join-Path $cfgHome 'ghostty'
$backupDir = Join-Path $work 'backups'
New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null
[System.IO.File]::WriteAllText((Join-Path $cfgDir 'config-debug.ghostty'), "font-size = 13`n")

$errlog = Join-Path $env:TEMP 'ghoztty-settings-open-latency-stderr.log'
$script:launched = @()
$app = $null

[void](Set-GhozttyTestAgentLineage -Tag 'setlat' -Quiet)
[void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    if ($NegativeControl) {
        Write-Host "NEGATIVE CONTROL: section A asserts the window waited for the slow theme read - this run MUST fail"
    }
    Remove-Item $errlog -ErrorAction SilentlyContinue
    $env:XDG_CONFIG_HOME = $cfgHome
    $env:GHOZTTY_SETTINGS_BACKUP_DIR = $backupDir
    $env:GHOZTTY_SETTINGS_THEME_DELAY_MS = "$DelayMs"
    $env:GHOZTTY_UPDATE_URL = 'http://127.0.0.1:9/releases'
    try {
        $sp = @{
            Exe       = $exe
            Arguments = @('--session-persistence=false', '--background=#101014')
        }
        if (-not $ExePath) { $sp.StdErr = $errlog }
        $app = Start-OnTestDesktop @sp
    } finally {
        Remove-Item Env:XDG_CONFIG_HOME -ErrorAction SilentlyContinue
        Remove-Item Env:GHOZTTY_SETTINGS_BACKUP_DIR -ErrorAction SilentlyContinue
        Remove-Item Env:GHOZTTY_SETTINGS_THEME_DELAY_MS -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 3
    if (-not $app -or ($app.Process -and $app.Process.HasExited)) {
        Write-TestAssertedNothing -Reason 'GUI did not come up' -Label 'settings-open-latency'
        exit 1
    }
    $script:launched += $script:GhozttyTestDesktopPids
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) {
        Write-TestAssertedNothing -Reason 'no terminal window appeared' -Label 'settings-open-latency'
        exit 1
    }

    # =====================================================================
    # A: the first open, against a slow theme catalog.
    # =====================================================================
    $m = Measure-SettingsOpen -AppPid $app.Pid -ipcArgs @('--op=action')
    if ($null -eq $m.Answer -or -not $m.Answer.success) {
        Write-TestAssertedNothing -Reason "the settings IPC action never answered (visible=$($m.VisibleMs) answer=$($m.AnswerMs))" -Label 'settings-open-latency'
        exit 1
    }
    Write-Host "  A: visible after $($m.VisibleMs) ms, answered after $($m.AnswerMs) ms (theme read delayed $DelayMs ms)"
    if ($NegativeControl) {
        $script:negReached = $true
        Assert ($m.VisibleMs -ge $DelayMs) "A (NEGATIVE): the window only appeared after the slow theme read ($($m.VisibleMs) ms >= $DelayMs ms)"
    } else {
        Assert ($m.VisibleMs -ge 0 -and $m.VisibleMs -le $BudgetMs) "A: the Settings window is visible within $BudgetMs ms of open_config ($($m.VisibleMs) ms)"
    }
    Assert ($m.AnswerMs -ge ($DelayMs - 50)) "A: the answer (which waits for the theme read) came after the injected delay ($($m.AnswerMs) ms) - the slow read really ran"
    Assert ($m.VisibleMs -ge 0 -and $m.VisibleMs -lt ($m.AnswerMs - 500)) "A: the window was on screen well before the theme read finished ($($m.VisibleMs) ms vs $($m.AnswerMs) ms)"
    $o = $m.Answer.data.opened
    Assert ($null -ne $o -and [bool]$o.before_themes) "A: the app reports it showed the window before the themes landed (before_themes=$($o.before_themes))"
    Assert ($null -ne $o -and [int]$o.open_ms -le $BudgetMs) "A: the app's own open time is within budget (open_ms=$($o.open_ms))"
    Assert ($null -ne $o -and [int]$o.themes_ms -ge ($DelayMs - 50)) "A: the app timed the slow theme read (themes_ms=$($o.themes_ms))"
    $th = $m.Answer.data.theme
    Assert ($null -ne $th -and ([int]$th.light_count + [int]$th.dark_count) -gt 100) "A: the catalog then holds the bundled themes (light=$($th.light_count) dark=$($th.dark_count))"
    Assert ([string]$m.Answer.data.page -eq 'appearance') "A: it opened on Appearance, the page that reads the catalog (page='$($m.Answer.data.page)')"

    # =====================================================================
    # B: open_config again while it is open - immediate.
    # =====================================================================
    $m2 = Measure-SettingsOpen -AppPid $app.Pid -ipcArgs @('--op=action')
    Assert ($null -ne $m2.Answer -and $m2.Answer.success -and $m2.AnswerMs -le $BudgetMs) "B: a second open_config is answered within $BudgetMs ms ($($m2.AnswerMs) ms)"
    $wins = @(Get-TestWindows -ProcessId $app.Pid -Class 'GhozttySettings')
    Assert ($wins.Count -eq 1) "B: still exactly one Settings window ($($wins.Count))"

    # =====================================================================
    # C: close, then open again - shown before the (still slow) read.
    # =====================================================================
    [void](Invoke-Settings @('--op=close'))
    $wins = @(Get-TestWindows -ProcessId $app.Pid -Class 'GhozttySettings')
    Assert ($wins.Count -eq 0) "C: the window closed ($($wins.Count))"
    $m3 = Measure-SettingsOpen -AppPid $app.Pid -ipcArgs @('--op=action')
    Write-Host "  C: visible after $($m3.VisibleMs) ms, answered after $($m3.AnswerMs) ms"
    Assert ($m3.VisibleMs -ge 0 -and $m3.VisibleMs -le $BudgetMs) "C: a reopen is visible within $BudgetMs ms ($($m3.VisibleMs) ms)"
    $th = if ($m3.Answer) { $m3.Answer.data.theme } else { $null }
    Assert ($null -ne $th -and ([int]$th.light_count + [int]$th.dark_count) -gt 100) "C: the reopened window's catalog holds the themes too"

    [void](Invoke-Settings @('--op=close'))

    $log = if (Test-Path $errlog) { Get-Content $errlog -Raw } else { '' }
    Assert ($log -match 'settings: themes loaded count=\d+ themes_ms=\d+') 'the log carries the theme read''s own timing line'
    Assert ($log -match 'settings: opened .*open_ms=\d+ .*themes_pending=true') 'the log carries the per-phase open timing, themes pending at show'

    Assert (-not ($app.Process -and $app.Process.HasExited)) 'no crash'
    Complete-TestBody
} catch {
    Write-Host "ERROR $_" -ForegroundColor Red
    $script:fail++
} finally {
    if ($app) { Stop-Process -Id $app.Pid -Force -ErrorAction SilentlyContinue }
    Remove-TestDesktop
    [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
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
        update -Guard settings-open-latency -Repo $repo 2>&1 | ForEach-Object { Write-Host "  $_" }
}

Write-TestVerdict -Pass $script:pass -Fail $script:fail -Skipped $script:skipped -Label 'settings-open-latency'
