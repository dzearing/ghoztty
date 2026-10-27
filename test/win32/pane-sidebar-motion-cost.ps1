# T1925 acceptance: what the pane sidebar's busy sheen COSTS on Windows.
# Mac 321e61d7c measured 40 windows / a dozen busy panes and found the
# shimmer re-ran the whole sidebar update every frame (86-99% of a core idle,
# 31-50 ms a scroll step), and moved it onto Core Animation. Here the sheen is
# a 30fps window timer (pane_sidebar_motion.zig), and before T1925 every tick
# invalidated the whole column: every row's pill, text and overlay repainted
# into a column-sized buffer, for one pill that moved. Now a tick invalidates
# the moving pills alone and the paint draws only the rows its clip reaches.
#
# Layout: the first pane P plus four named splits s1..s4 (five tiles on the
# rail). What it checks:
#
#   1. One busy pane: the clock runs, and when it stops its log line
#      (`motion off surface=rail frames=N area=A`) says the frames painted a
#      small share of the column - A is the percent of the column's pixels
#      the frames repainted, 100 being the whole sidebar every frame.
#   2. Four busy panes at once: still a fraction of the column (their
#      tiles' box, not the card, header and toggle).
#   3. Idle again, the clock stops and the app's CPU settles: the process's
#      CPU over a quiet stretch is reported beside the busy stretch's, as the
#      measurement the task asked for (informational, never a verdict - the
#      panes' own renderers share the process).
#
# The picture itself (that a busy tile still sheens, and an idle one holds
# still) is pane-sidebar-activity.ps1's, which photographs the column with
# WM_PRINTCLIENT - a whole-column paint either way.
#
# Runs on a BACKGROUND desktop (lib\TestDesktop.ps1) and never takes the
# user's foreground - asserted by the foreground watcher, not assumed.
# -NegativeControl expects the frames to repaint the WHOLE column and MUST
# fail.
#
#   powershell -NoProfile -File test\win32\pane-sidebar-motion-cost.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [switch]$NegativeControl,
    [switch]$Interactive
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:passes = 0
$tmp = Join-Path $env:TEMP "ghoztty-t1925-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ } else { "  FAIL $name"; $script:failures++ }
}
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 't1925')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$Cli = [System.IO.Path]::ChangeExtension($Exe, '.com')
if (-not (Test-Path $Cli)) { $Cli = $Exe }

function Invoke-Cli([string]$CliArgs) {
    cmd /c "`"$Cli`" $CliArgs > `"$tmp\out.txt`" 2> `"$tmp\err.txt`"" | Out-Null
    return $LASTEXITCODE
}
function Get-CliErr { (Get-Content "$tmp\err.txt" -Raw -ErrorAction SilentlyContinue) }

function Get-Panes($top) { @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal') }
function Get-Sidebar($top) { @(Get-TestChildWindows -Window $top -Class 'GhozttyPaneSidebar') | Select-Object -First 1 }
function Px([double]$Dip) { [int][math]::Floor($Dip * $script:scale + 0.5) }

# Log lines written after line $From, waiting up to $Ms for one matching $Pattern.
function Wait-Log([int]$From, [string]$Pattern, [int]$Ms = 4000) {
    $deadline = (Get-Date).AddMilliseconds($Ms)
    do {
        $hit = @(Get-Content $script:errlog -ErrorAction SilentlyContinue | Select-Object -Skip $From) |
            Where-Object { $_ -match $Pattern } | Select-Object -First 1
        if ($hit) { return $hit }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)
    return $null
}
function Get-LogCount { @(Get-Content $script:errlog -ErrorAction SilentlyContinue).Count }

# The app's CPU over $Ms, as percent of one core.
function Get-CpuPercent($proc, [int]$Ms = 3000) {
    if (-not $proc) { return $null }
    try {
        $proc.Refresh(); $a = $proc.TotalProcessorTime.TotalMilliseconds
        Start-Sleep -Milliseconds $Ms
        $proc.Refresh(); $b = $proc.TotalProcessorTime.TotalMilliseconds
        return [math]::Round(($b - $a) * 100.0 / $Ms, 1)
    } catch { return $null }
}

# Run `busy` on $Names for $Ms, then idle them; return the motion-off line's
# frames and area, plus the CPU while busy, in $script:run (a return value
# would carry the Assert lines too).
function Measure-Run([string[]]$Names, [int]$Ms = 3000) {
    $mark = Get-LogCount
    foreach ($n in $Names) {
        Assert "+set-state busy $n exit 0 ($(Get-CliErr))" ((Invoke-Cli "+set-state --target=$n --state=busy") -eq 0)
    }
    $on = Wait-Log $mark 'pane sidebar motion on surface=rail'
    Assert "the motion clock started (log)" ($null -ne $on)
    $cpu = Get-CpuPercent $script:app.Process $Ms
    foreach ($n in $Names) { [void](Invoke-Cli "+set-state --target=$n --state=idle") }
    $off = Wait-Log $mark 'pane sidebar motion off surface=rail frames=(\d+) area=(\d+)' 6000
    "  $off"
    Assert "the motion clock stopped itself, with its cost (log)" ($null -ne $off)
    if ($off -and $off -match 'frames=(\d+) area=(\d+)') {
        $script:run = @{ Frames = [int]$Matches[1]; Area = [int]$Matches[2]; Cpu = $cpu }; return
    }
    $script:run = @{ Frames = 0; Area = -1; Cpu = $cpu }
}

. (Join-Path $PSScriptRoot 'lib\Transcript.ps1')
$transcript = New-TestTranscript -Name 't1925'

Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$launched = @()
$script:reachedEnd = $false
$script:scale = 1.0

& {
try {
    [void](Stop-RepoGhoztty -Exe $Exe -AppOnly -SettleMs 500)
    Assert-GhozttyPrivateEndpoint -Exe $Exe
    $script:errlog = Join-Path $tmp 'app-stderr.log'
    $script:app = Start-OnTestDesktop -Exe $Exe -StdErr $script:errlog -Arguments @('--session-persistence=false', '--macos-pane-style=flat')
    Start-Sleep -Seconds 3
    $top = Wait-TestWindow -ProcessId $script:app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { "  SETUP FAIL: top window not found"; $script:failures++; return }
    Assert "window is NOT enumerable on the interactive desktop" (-not (Test-TestDesktopLeak -ProcessId $script:app.Pid))
    $dpi = Get-TestWindowDpi -Window $top
    if ($dpi -gt 0) { $script:scale = $dpi / 96.0 }
    "  (window dpi $dpi, scale $($script:scale))"
    [void](Set-TestWindowSize -Window $top -Width (Px 1100) -Height (Px 760))
    Start-Sleep -Milliseconds 600

    Assert "setup: +split s1 exit 0 ($(Get-CliErr))" ((Invoke-Cli "+split --direction=right --name=s1") -eq 0)
    Start-Sleep -Milliseconds 800
    Assert "setup: +split s2 exit 0 ($(Get-CliErr))" ((Invoke-Cli "+split --target=s1 --direction=down --name=s2") -eq 0)
    Start-Sleep -Milliseconds 800
    Assert "setup: +split s3 exit 0 ($(Get-CliErr))" ((Invoke-Cli "+split --target=s2 --direction=down --name=s3") -eq 0)
    Start-Sleep -Milliseconds 800
    Assert "setup: +split s4 exit 0 ($(Get-CliErr))" ((Invoke-Cli "+split --target=s1 --direction=right --name=s4") -eq 0)
    Start-Sleep -Milliseconds 1500
    $panes = @(Get-Panes $top | Where-Object Visible).Count
    Assert "setup: five visible panes ($panes)" ($panes -eq 5)
    $sb = Get-Sidebar $top
    Assert "setup: the rail is up" ($null -ne $sb -and $sb.Visible)

    "== 1: one busy pane repaints its tile, not the column"
    Measure-Run @('s3'); $one = $script:run
    "  frames=$($one.Frames) area=$($one.Area)% cpu(busy)=$($one.Cpu)%"
    Assert "the clock painted frames ($($one.Frames), want >= 30 in ~3s at 30fps)" ($one.Frames -ge 30)
    if ($NegativeControl) {
        Assert "NEGATIVE CONTROL: every frame repaints the whole column (area $($one.Area)%)" ($one.Area -ge 90)
    } else {
        Assert "a frame repaints a small share of the column (area $($one.Area)%, want <= 15)" ($one.Area -ge 0 -and $one.Area -le 15)
    }

    "== 2: four busy panes repaint their tiles' box, not the column"
    Measure-Run @('s1', 's2', 's3', 's4'); $four = $script:run
    "  frames=$($four.Frames) area=$($four.Area)% cpu(busy)=$($four.Cpu)%"
    Assert "the clock painted frames ($($four.Frames), want >= 30)" ($four.Frames -ge 30)
    Assert "four busy tiles still repaint less than the column (area $($four.Area)%, want <= 50)" ($four.Area -ge 0 -and $four.Area -le 50)

    "== 3: idle, the app settles (measurement)"
    Start-Sleep -Milliseconds 800
    $idle = Get-CpuPercent $script:app.Process 3000
    "  cpu: idle=$idle% one-busy=$($one.Cpu)% four-busy=$($four.Cpu)% (percent of one core, whole process)"
    $mark = Get-LogCount
    Assert "idle, no clock restarts" ($null -eq (Wait-Log $mark 'pane sidebar motion on' 500))

    Assert "no crash" (-not ($script:app.Process -and $script:app.Process.HasExited))
    $launched += $script:GhozttyTestDesktopPids
    $script:reachedEnd = $true
} catch {
    "  FAIL body threw: $($_.Exception.Message)"
    $script:failures++
} finally {
    Remove-TestDesktop
    [void](Stop-RepoGhoztty -Exe $Exe -AppOnly -SettleMs 500)
}

Assert "the body ran to its last section" ($script:reachedEnd -eq $true)
$fgSeen = @(Stop-TestForegroundWatch)
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @($launched | Select-Object -Unique)
    Assert "the foreground watcher actually sampled (negative control)" ($fgSeen.Count -gt 0)
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert "no test-desktop app ever became foreground on the interactive desktop" ($leaked.Count -eq 0)
}
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

} 2>&1 | Tee-Object -FilePath $transcript

Complete-TestBody  # T1039: the run reached the end of its body

if ($script:failures -eq 0 -and -not $NegativeControl) {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard pane-sidebar-motion-cost -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

""
exit (Complete-TestTranscript -Name 't1925' -Path $transcript `
        -Label 'T1925 ACCEPTANCE' -Pass $script:passes -Fail $script:failures).Code
