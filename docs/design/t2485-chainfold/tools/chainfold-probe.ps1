# T2485 probe: six panes, divider 1 dragged right ~3.4 pane widths in small
# steps on the background test desktop (posted mouse, real pointer untouched),
# debug build, app log kept. Counts the carried-face oracle lines.
param([string]$Repo = 'D:\git\ghoztty-b', [ValidateSet('flat', 'elevated')][string]$PaneStyle = 'elevated', [int]$Steps = 160, [int]$StepMs = 10)
$test = Join-Path $Repo 'test\win32'
. (Join-Path $test 'lib\CleanSlate.ps1')
. (Join-Path $test 'lib\TestDesktop.ps1')
. (Join-Path $test 'lib\BuildMode.ps1')
. (Join-Path $test 'lib\ChromeGeometry.ps1')
$ErrorActionPreference = 'Continue'
$exe = Join-Path $Repo 'zig-out\bin\ghoztty.exe'
$agent = Join-Path $Repo 'zig-out\bin\ghoztty-agent.exe'
$root = Join-Path $env:TEMP "t2485-probe-$PID"
$errlog = Join-Path $root 'app-stderr.log'
[void](Stop-RepoGhoztty -Exe $exe -SettleMs 700)
New-Item -ItemType Directory -Force $root | Out-Null
$tmp = Join-Path $root 'app'
New-Item -ItemType Directory -Force (Get-GhozttyAgentStateDir -Root $tmp) | Out-Null
$env:LOCALAPPDATA = $tmp
$env:GHOSTTY_LOCAL_AGENT_BIN = $agent
$env:GHOZTTY_PIPE_SUFFIX = "-t2485probe$PID"
$env:GHOZTTY_LOG = 'debug'
Reset-TestBody
$td = New-TestDesktop
try {
    [void](Assert-GhozttyIsolatedBuild -Exe $exe)
    $app = Start-OnTestDesktop -Exe $exe -Arguments @('--config-default-files=false', '--session-persistence=false', "--macos-pane-style=$PaneStyle") -StdErr $errlog
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    Start-Sleep -Milliseconds 800
    $dpi = [int](Get-TestWindowDpi -Window $top); if ($dpi -le 0) { $dpi = 96 }
    $scale = $dpi / 96.0
    [void](Set-TestWindowPos -Window $top -X 0 -Y 0 -Width (Get-TestChromeDip -Dip 1600 -Scale $scale) -Height (Get-TestChromeDip -Dip 800 -Scale $scale))
    Start-Sleep -Seconds 2
    $prev = $null
    foreach ($n in 2..6) {
        if ($prev) { & $exe +split --pane=$prev --direction=right --name="p$n" | Out-Null } else { & $exe +split --direction=right --name="p$n" | Out-Null }
        $prev = "p$n"
        Start-Sleep -Milliseconds 600
    }
    Start-Sleep -Seconds 2
    $cols = @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal' | Where-Object Visible | Sort-Object Left)
    Write-Host ("columns: " + (($cols | ForEach-Object { "$($_.Left)-$($_.Right)" }) -join ' | '))
    if ($cols.Count -ne 6) { Write-Host "SETUP FAIL: $($cols.Count) columns"; return }
    $paneW = $cols[0].Width
    $x0 = [int](($cols[0].Right + $cols[1].Left) / 2)
    $y = [int](($cols[0].Top + $cols[0].Bottom) / 2)
    $x1 = [int]($x0 + 3.4 * ($cols[1].Left - $cols[0].Left))
    $mark = @(Get-Content $errlog -ErrorAction SilentlyContinue).Count
    [void](Send-TestMouse -Window $top -Target $top -X $x0 -Y $y -Action down -HoldMs 0)
    for ($i = 1; $i -le $Steps; $i++) {
        $x = [int]($x0 + ($x1 - $x0) * $i / $Steps)
        [void](Send-TestMouse -Window $top -Target $top -X $x -Y $y -Action move -HoldMs 0)
        Start-Sleep -Milliseconds $StepMs
    }
    Start-Sleep -Milliseconds 900
    [void](Send-TestMouse -Window $top -Target $top -X $x1 -Y $y -Action up -HoldMs 0)
    Start-Sleep -Seconds 2
    $lines = @(Get-Content $errlog | Select-Object -Skip $mark)
    Write-Host "log lines during drag: $($lines.Count)"
    foreach ($p in 'stack fold carried misfit', 'stack fold carried content', 'carries its frame', 'divider drag run=', 'strip face alpha', 'window resize cause', 'timeouts=[1-9]', 'stale=[1-9]') {
        Write-Host ("{0,-30} {1}" -f $p, @($lines | Select-String -Pattern $p).Count)
    }
    $lines | Out-File (Join-Path $root 'drag.log') -Encoding utf8
    Write-Host "log: $(Join-Path $root 'drag.log')"
} finally {
    [void](Stop-RepoGhoztty -Exe $exe -SettleMs 500)
    if ($td) { Remove-TestDesktop $td }
}
