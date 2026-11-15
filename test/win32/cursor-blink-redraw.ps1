# T2970 acceptance: a focused pane whose cursor cannot blink presents no frames.
#
# The defect: the render thread's blink timer flipped the blink phase every
# 600 ms for any focused pane, and the frame-change hash read the raw phase,
# so a pane whose cursor is steady (DECSCUSR 2) or hidden by its program
# (DECTCEM off, which is most full-screen TUIs) still built, uploaded and
# presented a frame of identical pixels 1.67 times a second - forever, for as
# long as it was focused.
#
# One window, one pane, focused, running a script that holds three cursor
# states in turn, each for a measured window (the harness moves it on by
# creating a marker file, so the pane prints nothing while being measured):
#
#   blink   DECTCEM on + DECSCUSR 1 (blinking block): the phase shows
#   hidden  DECTCEM off: nothing to blink
#   steady  DECTCEM on + DECSCUSR 2 (steady block): nothing to blink
#
# It reads the renderer's own per-pane frame counter (GHOZTTY_PERF=1,
# `perf pane=... fps=N`), which logs only when a frame is presented, so a pane
# that presents nothing writes nothing.
#
# Assertions:
#   A  blink: the pane presented frames (>= 2 perf lines in the window). This
#      is the positive control: it proves the pane is focused and the counter
#      is live, so the two silences below mean something - and that the fix
#      did not simply stop the cursor blinking.
#   B  hidden: the pane presented at most one frame-second (pre-fix: one about
#      every 1.2 s, i.e. ~5 lines)
#   C  steady: likewise
#   D  blink again after steady: frames resume (the stopped timer restarts
#      when a program turns blinking back on)
# preflight: Assert-GhozttyIsolatedBuild below; Debug build only.
# persistence: off - this measures the renderer, not the agent.
param([string]$ExePath, [int]$WindowSeconds = 6)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$env:GHOZTTY_NO_STARTUP_ESCAPE = '1'
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
[void](Set-GhozttyTestIsolation -Tag 't2970' -ReleaseSandbox)
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }
if (-not (Test-Path $exe)) { Write-Host "SETUP FAIL: $exe missing (zig build first)"; exit 1 }
Assert-GhozttyIsolatedBuild -Exe $exe | Out-Null

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

$work = Join-Path $env:TEMP "ghoztty-t2970-$PID"
New-Item -ItemType Directory -Force $work | Out-Null
$states = Join-Path $work 'states.ps1'
# Each state is entered when its marker file appears; the script prints only
# at the transitions. ASCII only (PS5.1 reads scripts as ANSI).
[IO.File]::WriteAllText($states, @"
`$e = [char]27
`$dir = '$work'
function WaitFor([string]`$n) { while (-not (Test-Path (Join-Path `$dir `$n))) { Start-Sleep -Milliseconds 100 } }
WaitFor 'go-blink'
[Console]::Write("`$e[?25h`$e[1 q")
WaitFor 'go-hidden'
[Console]::Write("`$e[?25l")
WaitFor 'go-steady'
[Console]::Write("`$e[?25h`$e[2 q")
WaitFor 'go-blink2'
[Console]::Write("`$e[1 q")
WaitFor 'go-done'
"@)
$errLog = Join-Path $work 'app-stderr.log'

function Stop-Children {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -like "*$work*" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

# Enter a state, let its transition frame settle, then count the perf lines
# logged over the measured window.
function Measure-State([string]$Marker) {
    [IO.File]::WriteAllText((Join-Path $work $Marker), '')
    Start-Sleep -Milliseconds 1500
    $mark = @(Get-Content $errLog).Count
    Start-Sleep -Seconds $WindowSeconds
    $lines = @(Get-Content $errLog | Select-Object -Skip $mark | Where-Object { $_ -match 'perf pane=\S+ fps=\d+' })
    $fps = @($lines | ForEach-Object { if ($_ -match 'fps=(\d+)') { [int]$matches[1] } })
    Write-Host "  $Marker : $($lines.Count) perf line(s) in ${WindowSeconds}s, fps=$($fps -join ',')"
    return $lines.Count
}

$env:GHOZTTY_PERF = '1'
$td = New-TestDesktop
& {
try {
    [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 300)
    $app = Start-OnTestDesktop -Exe $exe -StdErr $errLog -Arguments @(
        '--session-persistence=false',
        "--command=powershell -NoProfile -File $states"
    )
    Start-Sleep -Seconds 5

    $blink = Measure-State 'go-blink'
    $hidden = Measure-State 'go-hidden'
    $steady = Measure-State 'go-steady'
    $blink2 = Measure-State 'go-blink2'
    [IO.File]::WriteAllText((Join-Path $work 'go-done'), '')

    Assert ($blink -ge 2) "A: a blinking cursor in the focused pane still presents frames ($blink perf lines)"
    Assert (($blink -ge 2) -and ($hidden -le 1)) "B: a hidden cursor presents nothing ($hidden perf lines; pre-fix ~5)"
    Assert (($blink -ge 2) -and ($steady -le 1)) "C: a steady cursor presents nothing ($steady perf lines; pre-fix ~5)"
    Assert ($blink2 -ge 2) "D: turning blinking back on restarts the blink ($blink2 perf lines)"
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
        update -Guard cursor-blink-redraw -Repo $repo 2>&1 |
        ForEach-Object { Write-Host "  $_" }
}

Write-TestVerdict -Pass $script:pass -Fail $script:fail
