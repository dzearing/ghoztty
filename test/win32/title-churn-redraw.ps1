# T1935 acceptance: a title that keeps changing costs no frames and no sidebar rebuilds.
#
# The defect: typing lagged in every pane with ~20 Claude Code panes open, and
# the app burned 5-15 cores. Claude animates its title several times a second.
# Every chunk of output woke the pane's renderer, which presented a full frame
# even when no cell had changed (each pane drew 10 fps from its title alone,
# with the GL driver threads busy), and every title change rebuilt the pane
# sidebar and every all-windows list on the UI thread, writing several KB of
# log for each rebuild.
#
# This script opens ten panes whose ONLY output is an OSC 0 title change
# every 100 ms, one pane that prints a real line every 100 ms, and one idle
# shell, and reads
# the renderer's own per-pane frame counter (GHOZTTY_PERF=1, `perf pane=...
# fps=N`) and the sidebar's rebuild lines from stderr.
#
# Assertions:
#   A  the titles really changed (the premise)
#   B  no title-only pane presents more than 2 frames a second
#   C  the printing pane still presents at least 5 (real changes still draw;
#      this is the half that says the fix did not simply stop rendering)
#   D  the sidebar rebuilt at most once per three title changes
# preflight: Assert-GhozttyIsolatedBuild below; Debug build only.
# persistence: off - this measures the renderer and the sidebar, not the agent,
# and the sandbox below keeps the user's config out of the measurement.
param([string]$ExePath, [int]$Windows = 6)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$env:GHOZTTY_NO_STARTUP_ESCAPE = '1'
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
# Its own LOCALAPPDATA: a config there (opacity, shaders, ...) changes what a
# frame costs, and the first measurement for this task was skewed by exactly that.
[void](Set-GhozttyTestIsolation -Tag 't1935' -ReleaseSandbox)
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }
$com = [IO.Path]::ChangeExtension($exe, '.com')
if (-not (Test-Path $exe)) { Write-Host "SETUP FAIL: $exe missing (zig build first)"; exit 1 }
Assert-GhozttyIsolatedBuild -Exe $exe | Out-Null

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

$work = Join-Path $env:TEMP "ghoztty-t1935-$PID"
New-Item -ItemType Directory -Force $work | Out-Null
$spin = Join-Path $work 'spin.ps1'
[IO.File]::WriteAllText($spin, @'
$f = @([char]0x25D0, [char]0x25D3, [char]0x25D1, [char]0x25D2)
$e = [char]27; $b = [char]7
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$i = 0
while ($true) { [Console]::Write("$e]0;$($f[$i % 4]) claude working$b"); $i++; Start-Sleep -Milliseconds 100 }
'@)
$count = Join-Path $work 'count.ps1'
[IO.File]::WriteAllText($count, @'
$i = 0
while ($true) { [Console]::WriteLine("line $i"); $i++; Start-Sleep -Milliseconds 100 }
'@)
$spinCmd = "powershell -NoProfile -File $spin"
$countCmd = "powershell -NoProfile -File $count"
$errLog = Join-Path $work 'app-stderr.log'

function Invoke-GCli([string]$a) { cmd /c "`"$com`" $a >nul 2>nul"; return $LASTEXITCODE }
function Stop-Children {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -like "*$work*" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

$env:GHOZTTY_PERF = '1'
$td = New-TestDesktop
& {
try {
    [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 300)
    $app = Start-OnTestDesktop -Exe $exe -StdErr $errLog -Arguments @('--session-persistence=false')
    Start-Sleep -Seconds 4
    [void](Invoke-GCli "+split --direction=right --command=`"$countCmd`"")
    for ($i = 2; $i -le $Windows; $i++) {
        [void](Invoke-GCli "+new-window --target=w$i --name=p$i --command=`"$spinCmd`"")
        Start-Sleep -Milliseconds 800
        [void](Invoke-GCli "+split --target=p$i --direction=right --command=`"$spinCmd`"")
        Start-Sleep -Milliseconds 500
    }
    # The first window's own pane stays an idle shell; it reports 0 fps.
    Start-Sleep -Seconds 15
    $mark = (Get-Content $errLog).Count
    Start-Sleep -Seconds 10
    $tail = @(Get-Content $errLog | Select-Object -Skip $mark)

    $titles = @($tail | Where-Object { $_ -match 'changing title' }).Count
    $rebuilds = @($tail | Where-Object { $_ -match 'pane sidebar (rows|outline|all-windows) ' }).Count
    $fps = @{}
    foreach ($l in $tail) {
        if ($l -match 'perf pane=(\S+) fps=(\d+)') {
            if (-not $fps.ContainsKey($matches[1])) { $fps[$matches[1]] = New-Object System.Collections.ArrayList }
            [void]$fps[$matches[1]].Add([int]$matches[2])
        }
    }
    $peak = @{}
    foreach ($k in $fps.Keys) { $peak[$k] = ($fps[$k] | Measure-Object -Maximum).Maximum }
    $peaks = @($peak.Values | Sort-Object -Descending)
    Write-Host "  titles=$titles rebuilds=$rebuilds panes-reporting=$($peak.Count) peaks=$($peaks -join ',')"

    Assert ($titles -ge 100) "A: the titles kept changing ($titles in 10 s)"
    Assert ($peak.Count -ge 2) "setup: panes reported their frame rate ($($peak.Count))"
    $quiet = @($peaks | Select-Object -Skip 1)
    Assert (($quiet.Count -ge 1) -and (@($quiet | Where-Object { $_ -gt 2 }).Count -eq 0)) `
        "B: no title-only pane presented more than 2 fps (next highest $($quiet | Select-Object -First 1))"
    Assert (($peaks.Count -ge 1) -and ($peaks[0] -ge 5)) "C: the printing pane still drew at $($peaks[0]) fps"
    Assert (($titles -gt 0) -and ($rebuilds * 3 -le $titles)) "D: the sidebar rebuilt $rebuilds times for $titles title changes"
} finally {
    [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 300)
    Stop-Children
}
}
Remove-Item Env:GHOZTTY_PERF -ErrorAction SilentlyContinue
Remove-TestDesktop | Out-Null
if ($script:fail -eq 0) { Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue }
else { Write-Host "logs kept in $work" }

Complete-TestBody

if ($script:fail -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot '..\..\scripts\guard-due.ps1') `
        update -Guard title-churn-redraw -Repo $repo 2>&1 |
        ForEach-Object { Write-Host "  $_" }
}

Write-TestVerdict -Pass $script:pass -Fail $script:fail
