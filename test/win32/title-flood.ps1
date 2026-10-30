# T2428 acceptance - a pane that re-titles itself on every output line does
# not tie up the thread that answers the mouse, and the title still ends on the
# one the program set last.
#
# THE DEFECT. cmd.exe titles its console with each command it runs, and ConPTY
# hands each line over as its own read, so `for /L ... do @echo` set a new
# title per output line: ~13,000 set_title messages a second, each one a
# GUI-thread wakeup (measured 2026-10-29 with a per-message mailbox counter).
# The UI thread spent ~22% of its time on them in a Debug build, and on the
# T2418 shape (ReleaseFast, a 4K window, the sidebar open) a divider press was
# not lit for seconds.
#
# THE FIX (src/termio/title_pace.zig). The newest title is held and sent at
# most once per frame interval: the first change in a burst at once, the rest
# on a termio timer that also sends the last one when the output stops.
#
# THE ORACLES, all read from outside the app:
#   A. setup: a window, a split, the flood really running (its counter rises)
#   B. the GUI thread's CPU time while the flood runs, under -CpuBudgetPct
#      (Debug, measured: ~22% unfixed, ~0.4% fixed)
#   C. a finite burst of `title` commands ends with the LAST title on the pane
#      (+list --json), within a second of the burst ending - the held title is
#      never stranded
#   D. the flood's throughput is not what paid for B: the counter still rises
#      at least -MinLinesPerSec
#
# NEGATIVE CONTROL. Build with `interval_ns = 0` in title_pace.zig into another
# prefix and pass -ExePath: B goes red.
#
# One ALL PASS / N FAILURE(S) line last, per the house convention.

param([string]$ExePath, [switch]$Interactive, [double]$CpuBudgetPct = 6.0, [int]$MinLinesPerSec = 2000)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'

$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }
$env:GHOZTTY_PIPE_SUFFIX = "-titleflood$PID"
$errlog = Join-Path $env:TEMP "ghoztty-title-flood-$PID.log"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

Add-Type -Namespace T2428 -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
'@

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Stop-Flood {
    Get-CimInstance Win32_Process -Filter "Name='cmd.exe'" |
        Where-Object { $_.CommandLine -like '*T2428-FLOOD*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

function Get-FloodCounter {
    $tail = (& $exe +read --name=t2428flood --lines=200 2>&1 | ForEach-Object { $_.ToString() } | Out-String)
    $m = [regex]::Matches($tail, 'T2428-FLOOD-(\d+)')
    if ($m.Count -eq 0) { return -1 }
    return [int]$m[$m.Count - 1].Groups[1].Value
}

function Get-GuiCpuMs([int]$procId, [uint32]$threadId) {
    $p = Get-Process -Id $procId
    $p.Refresh()
    foreach ($t in $p.Threads) {
        if ($t.Id -eq $threadId) { return $t.TotalProcessorTime.TotalMilliseconds }
    }
    return -1
}

function Get-PaneTitle([string]$name) {
    $json = (& $exe +list --json 2>&1 | ForEach-Object { $_.ToString() } | Out-String)
    $m = [regex]::Match($json, '"name"\s*:\s*"' + [regex]::Escape($name) + '"[^{}]*?"title"\s*:\s*"([^"]*)"')
    if (-not $m.Success) {
        $m = [regex]::Match($json, '"title"\s*:\s*"([^"]*)"[^{}]*?"name"\s*:\s*"' + [regex]::Escape($name) + '"')
    }
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

Reset-GhozttyTestState -Exe $exe -SettleMs 0 | Out-Null
Stop-Flood
$td = New-TestDesktop -Interactive:$Interactive
$appPid = 0
try {
    Write-Host '== A: setup - a window, a split, and a flood that is really running'
    $app = Start-OnTestDesktop -Exe $exe -StdErr $errlog -Arguments @(
        '--config-default-files=false', '--session-persistence=false', '--command=cmd.exe')
    $appPid = $app.Pid
    $top = Wait-TestWindow -ProcessId $appPid -Class 'GhozttyWindow' -TimeoutMs 20000
    Assert ($top -ne [IntPtr]::Zero) 'A1 top-level window appeared'
    if ($top -eq [IntPtr]::Zero) { throw 'no window' }
    [void](Set-TestWindowPos -Window ([IntPtr]$top) -X 40 -Y 40 -Width 1400 -Height 900)
    Start-Sleep -Seconds 2
    & $exe +split --name=t2428flood --direction=right 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    $panes = @(Get-TestChildWindows -Window ([IntPtr]$top) -Class 'GhozttyTerminal' | Where-Object Visible)
    Assert ($panes.Count -eq 2) "A2 split produced 2 panes (saw $($panes.Count))"

    $tp = 0
    $guiTid = [T2428.Win]::GetWindowThreadProcessId([IntPtr]$top, [ref]$tp)
    Assert (($guiTid -ne 0) -and ($tp -eq $appPid)) "A3 the window's thread is the app's GUI thread (tid $guiTid)"

    & $exe +send-keys --target=t2428flood "for /L %i in (1,1,5000000) do @echo T2428-FLOOD-%i a line long enough to scroll the pane hard and keep the renderer drawing" Enter 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    $c1 = Get-FloodCounter
    Assert ($c1 -gt 0) "A4 the flood is running (counter $c1; T107: load asserted, not assumed)"

    Write-Host '== B: GUI thread CPU while the pane floods'
    $g0 = Get-GuiCpuMs $appPid $guiTid
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Start-Sleep -Seconds 4
    $g1 = Get-GuiCpuMs $appPid $guiTid
    $el = $sw.ElapsedMilliseconds
    $c2 = Get-FloodCounter
    $pct = 100.0 * ($g1 - $g0) / $el
    Write-Host ("  GUI thread: {0:N0} ms of CPU over {1} ms = {2:N1}%" -f ($g1 - $g0), $el, $pct)
    Assert (($g0 -ge 0) -and ($g1 -ge $g0)) 'B1 the GUI thread CPU clock reads'
    Assert ($pct -le $CpuBudgetPct) ("B2 GUI thread CPU {0:N1}% is within {1}% while one pane floods" -f $pct, $CpuBudgetPct)

    Write-Host '== D: the flood was not throttled to pay for it'
    $rate = [int](($c2 - $c1) * 1000.0 / ($el + 1))
    Write-Host "  flood counter $c1 -> $c2 (~$rate lines/s, counter read across ~4 s)"
    Assert ($rate -ge $MinLinesPerSec) "D1 the flood kept printing at $rate lines/s (floor $MinLinesPerSec)"
    Stop-Flood
    Start-Sleep -Seconds 2

    Write-Host '== C: the last title of a burst is the one the pane shows'
    & $exe +split --name=t2428title --direction=down 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    & $exe +send-keys --target=t2428title "for /L %i in (1,1,3000) do @title T2428-T%i" Enter 2>&1 | Out-Null
    $final = 'T2428-T3000'
    $seen = $null
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 20000) {
        $seen = Get-PaneTitle 't2428title'
        if ($seen -eq $final) { break }
        Start-Sleep -Milliseconds 100
    }
    Write-Host "  pane title after the burst: '$seen' ($($sw.ElapsedMilliseconds) ms)"
    Assert ($seen -eq $final) "C1 the pane ends on the burst's last title ($final)"
    Start-Sleep -Milliseconds 1000
    $again = Get-PaneTitle 't2428title'
    Assert ($again -eq $final) "C2 and stays on it once the burst is over (saw '$again')"
}
catch {
    $script:fail++
    Write-Host "FAIL  setup: $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    Stop-Flood
    Reset-GhozttyTestState -Exe $exe -SettleMs 0 | Out-Null
    Remove-TestDesktop
}

# --- stamp (T783) ----------------------------------------------------------
# Only a clean green run of the repo build, never a negative control.
if ($script:fail -eq 0 -and -not $ExePath) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard title-flood -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

if ($script:fail -eq 0) { Write-Host "ALL PASS ($($script:pass) checks)"; exit 0 }
Write-Host "$($script:fail) FAILURE(S) ($($script:pass) passed)"
exit 1
