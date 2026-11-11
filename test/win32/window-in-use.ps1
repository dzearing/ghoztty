# T2909 acceptance: motion that only matters to the eye runs only in the
# window IN USE (Mac `WindowInUse.animates`, main 68a8344f0). Every other
# window holds it still, and a window brought back forward picks it up again.
#
# Two motions are gated, and both say so in the debug log:
#
#   * The busy light circling a working pane (OSC 9;4;3): its clock runs at
#     the frame rate in the window in use (`busy light clock=turning`) and
#     falls back to the expiry tick elsewhere (`busy light clock=still`),
#     with the head held at the top.
#   * The sidebar's busy sheen (`+set-state busy`): its motion clock starts
#     (`pane sidebar motion on`) in the window in use and stops
#     (`pane sidebar motion off`) when another window takes over.
#
# Layout: window A runs a tiny emitter that re-sends 9;4;3 every half second
# (a real OSC stream through the ConPTY) and has a second pane, so its
# sidebar has rows; its first pane is marked busy. Window B is a plain shell.
#
#   1. A in use: the light turns and the sheen clock runs.
#   2. B brought forward (`+new-window --target=b --focus`): A's light goes
#      still and A's sheen clock stops - while A's pane still reports busy.
#   3. A brought back (`--target=a --focus`): both start again.
#
# Runs on a BACKGROUND desktop (lib\TestDesktop.ps1); activation there is
# the GUI thread's own, so nothing takes the user's foreground - asserted by
# the foreground watcher, not assumed.
#
# -NegativeControl asserts A's light NEVER goes still and MUST fail.
#
#   powershell -NoProfile -File test\win32\window-in-use.ps1

param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }
$cli = [System.IO.Path]::ChangeExtension($exe, '.com')
if (-not (Test-Path $cli)) { $cli = $exe }

$env:GHOZTTY_PIPE_SUFFIX = "-inuse$PID"
$tmp = Join-Path $env:TEMP "ghoztty-t2909-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null
$ctl = Join-Path $tmp 'report.ctl'
$emit = Join-Path $tmp 'emit.ps1'
$errlog = Join-Path $tmp 'app-stderr.log'

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

function Invoke-Cli([string]$CliArgs) {
    cmd /c "`"$cli`" $CliArgs > `"$tmp\out.txt`" 2> `"$tmp\err.txt`"" | Out-Null
    return $LASTEXITCODE
}
function Get-CliErr { "$(Get-Content "$tmp\err.txt" -Raw -ErrorAction SilentlyContinue)".Trim() }

function Get-LogCount { @(Get-Content $errlog -ErrorAction SilentlyContinue).Count }
# The first log line after line $From matching $Pattern, waiting up to $Ms.
function Wait-Log([int]$From, [string]$Pattern, [int]$Ms = 4000) {
    $deadline = (Get-Date).AddMilliseconds($Ms)
    do {
        $hit = @(Get-Content $errlog -ErrorAction SilentlyContinue | Select-Object -Skip $From) |
            Where-Object { $_ -match $Pattern } | Select-Object -First 1
        if ($hit) { return $hit }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)
    return $null
}

$emitBody = @'
param([string]$Ctl)
$esc = [char]27
$bel = [char]7
while ($true) {
    $m = ''
    try { $m = [System.IO.File]::ReadAllText($Ctl).Trim() } catch { }
    if ($m -eq 'ring') { [Console]::Out.Write("$esc]9;4;3;$bel"); [Console]::Out.Flush() }
    if ($m -eq 'off') { [Console]::Out.Write("$esc]9;4;0;$bel"); [Console]::Out.Flush() }
    Start-Sleep -Milliseconds 500
}
'@

Kill-RepoInstances
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$launched = @()

try {
    [System.IO.File]::WriteAllText($emit, $emitBody)
    [System.IO.File]::WriteAllText($ctl, 'off')
    $app = Start-OnTestDesktop -Exe $exe -StdErr $errlog -Arguments @('--config-default-files=false',
        '--background=#000000', '--session-persistence=false')
    $launched += $script:GhozttyTestDesktopPids
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $first = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($first -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: top window not found'; exit 1 }
    Assert (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) 'window is NOT enumerable on the interactive desktop'

    $cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$emit`" `"$ctl`""
    Assert ((Invoke-Cli "+new-window --target=a --name=pa --focus `"--command=$cmd`"") -eq 0) "setup: window a with the emitter ($(Get-CliErr))"
    Start-Sleep -Milliseconds 1500
    Assert ((Invoke-Cli '+split --target=pa --direction=right --name=pa2') -eq 0) "setup: a second pane in a ($(Get-CliErr))"
    Start-Sleep -Milliseconds 1200
    # The split took no focus; bring a forward again so step 1 starts there.
    Assert ((Invoke-Cli '+new-window --target=a --focus') -eq 0) "setup: a forward ($(Get-CliErr))"
    Start-Sleep -Milliseconds 800

    Write-Host '== 1: a in use - the light turns and the sheen moves'
    $mark = Get-LogCount
    [System.IO.File]::WriteAllText($ctl, 'ring')
    Assert ((Invoke-Cli '+set-state --target=pa --state=busy') -eq 0) "+set-state busy pa ($(Get-CliErr))"
    $turn = Wait-Log $mark 'busy light clock=turning' 5000
    Assert ($null -ne $turn) "a's busy light turns while a is in use ($turn)"
    $on = Wait-Log $mark 'pane sidebar motion on' 5000
    Assert ($null -ne $on) "a's sidebar sheen clock runs while a is in use"

    Write-Host '== 2: b brought forward - a holds still, still busy'
    $mark = Get-LogCount
    Assert ((Invoke-Cli '+new-window --target=b --name=pb --focus') -eq 0) "b forward ($(Get-CliErr))"
    $still = Wait-Log $mark 'busy light clock=still' 5000
    if ($NegativeControl) {
        Assert ($null -eq $still) 'NEGATIVE CONTROL: a''s light never goes still'
    } else {
        Assert ($null -ne $still) "a's busy light holds still once b is in use ($still)"
    }
    $off = Wait-Log $mark 'pane sidebar motion off' 5000
    Assert ($null -ne $off) "a's sidebar sheen clock stops once b is in use ($off)"
    # State never pauses: a's pane still reports busy.
    Start-Sleep -Milliseconds 1500
    $restart = Wait-Log ($mark) 'busy light off' 200
    Assert ($null -eq $restart) 'a''s light is still lit (held, not dropped) while b is in use'

    Write-Host '== 3: a brought back - both move again'
    $mark = Get-LogCount
    Assert ((Invoke-Cli '+new-window --target=a --focus') -eq 0) "a forward again ($(Get-CliErr))"
    $turn2 = Wait-Log $mark 'busy light clock=turning' 5000
    Assert ($null -ne $turn2) "a's busy light turns again ($turn2)"
    $on2 = Wait-Log $mark 'pane sidebar motion on' 5000
    Assert ($null -ne $on2) "a's sidebar sheen clock runs again"

    [System.IO.File]::WriteAllText($ctl, 'off')
    [void](Invoke-Cli '+set-state --target=pa --state=idle')
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'no crash'
    Stop-Process -Id $app.Pid -Force -ErrorAction SilentlyContinue
} catch {
    $script:fail++
    Write-Host "FAIL  the run terminated: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "      at $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())"
} finally {
    Remove-TestDesktop
    Kill-RepoInstances
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
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
        update -Guard window-in-use -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Skipped $script:skipped -Label 'WINDOW IN USE ACCEPTANCE'
