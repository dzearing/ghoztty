# @timing-sensitive - it measures wall-clock cost, so it runs with nothing beside it (scripts/acceptance-parallel.ps1, T1960).
# Long-context soak harness (T53a/T53b): Claude-Code-like load against the
# release-staging build, fully IPC-driven (no keyboard injection, safe to
# run beside real work). Isolated on a run-unique '-soak<pid>' pipe suffix.
#
# Load mix (all --shell=cmd panes in one named window):
#   soak-stream : endless `type` of an 8MB file  -> sustained visible stream
#   soak-altscr : PS loop toggling ESC[?1049h/l  -> alt-screen churn (TUI-like)
#   soak-grow   : 150k-line passes, repeated     -> big scrollback, for the whole run
#   (original)  : idle cmd prompt                -> input-latency probe target
#
# Sampled every 15s: WorkingSet, PrivateBytes, Handles, Threads, GDI/USER
# objects, Responding. Every 60s: input-latency probe (+send-keys marker ->
# poll +read until visible). End: big-scrollback +read latency, GHOZTTY_PERF
# telemetry slice from the app log, assertions, CSV + report under
# %TEMP%\ghoztty-soak\<stamp>\.
#
# Usage:
#   soak.ps1                      # 30-minute bounded soak, foreground
#   soak.ps1 -Minutes 5           # quick smoke
#   soak.ps1 -Minutes 240 -Detach # relaunch self detached (T53b long run)
#
# The sampling loop below prints NOTHING between its start and its verdict, by
# design - it samples counters every 15s and only speaks when something is
# wrong. So an unattended runner sees a silent 30-minute process, which is what
# the declaration on the next line is for: scripts\suite-run.ps1 reads it and
# gives this script its own cap instead of the 600s one that killed it and
# scored it `stall` on every sweep (T1125). 30 minutes of soak, plus the
# launch, the 8MB asset build, the end-of-run probes and teardown.
#
# suite-timeout-sec: 2400
#
# @lineage-safe - the lineage is dropped only inside Get-UserSessionIds, around a read-only `+sessions` roster query (src\cli\sessions.zig: reads port.json and dials, never spawns an agent), and only when $exe is a release-lineage build, whose default lineage is the user's installed agent and never a debug loop lane's; for a debug exe the caller's lineage is kept, and the caller's env is restored right after each read
param(
    [int]$Minutes = 30,
    [string]$ExePath = 'D:\git\ghoztty\zig-out-release\bin\ghoztty.exe',
    [switch]$Detach,
    [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'

if ($Detach) {
    Start-Process powershell -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', $PSCommandPath, '-Minutes', $Minutes, '-ExePath', $ExePath)
    Write-Host "soak launched detached ($Minutes min); report will land under $env:TEMP\ghoztty-soak\"
    exit 0
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$outDir = Join-Path $env:TEMP "ghoztty-soak\$stamp"
New-Item -ItemType Directory -Force $outDir | Out-Null
$report = Join-Path $outDir 'report.txt'
$csv = Join-Path $outDir 'samples.csv'
$logSlice = Join-Path $outDir 'log-slice.txt'
# $appLog is derived AFTER the sandbox below moves LOCALAPPDATA - see there.
$appLog = $null

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
# T782: byte-exact argv - the --command= below carries embedded quotes.
. (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'scripts\lib\NativeArgv.ps1')

function Rep($m) { $m | Tee-Object -FilePath $report -Append | Write-Host }

# A native call whose stderr is redirected (`2>$null`, `2>&1`) runs under
# `Continue`. Under this file's `Stop`, PowerShell 5.1 makes ANY stderr line
# from such a call terminating - including the CLI's "Waiting for Ghoztty to
# answer" progress note, which it prints on its way to succeeding. T1215: the
# 30-minute run on 2026-10-22 died on exactly that at the teardown `+close`,
# after every assertion had passed, and skipped the kill and desktop teardown.
function Invoke-Tolerant([scriptblock]$Body) {
    $ErrorActionPreference = 'Continue'
    & $Body
}

# The verdict goes through the shared scorer (T271), so a zero-assertion run -
# a `-SelfTest` whose grading helpers all threw, or a soak that reached the end
# having measured nothing - ends ASSERTED NOTHING and exit 2 rather than green.
# `-NoExit` because the report file wants the line too; the exit code is the
# scorer's either way.
function Write-SoakVerdict([int]$Pass, [int]$Fail, [string]$Label) {
    $v = Write-TestVerdict -Label $Label -Pass $Pass -Fail $Fail -NoExit
    $v.Line | Out-File -FilePath $report -Append -Encoding utf8
    exit $v.Code
}

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Rep "PASS  $label" }
    else { $script:fail++; Rep "FAIL  $label" }
}

# --- Renderer telemetry grading (T1147) ---------------------------------------
# The `perf` sampler reports once a SECOND PER PANE, and this window has four
# panes of which one is a deliberately idle latency-probe target. An idle
# unfocused pane legitimately redraws about once a second, so it emits `fps=1`
# for essentially every window of the run - and there are more of those windows
# than loaded ones. Every statistic taken over the pooled population therefore
# describes HOW MANY PANES HAPPENED TO BE IDLE rather than how the renderer
# coped: the original `median fps >= 20` read 1 and failed (T1147), and T1158's
# `p90 >= 30` only avoided that by picking a percentile above the idle mass,
# which is still an inference about the population rather than a measurement of
# the panes under load.
#
# Since T1147 each sample NAMES ITS PANE (`perf pane=<uuid> fps=...`), so the
# grading is done where the load actually is: group by pane, map the ids back to
# the names this script gave them, and grade the panes it deliberately loaded.
# The idle probe pane is reported - which is what turns "the fps=1 population is
# idle panes" from an inference into a measurement - and graded by nothing.
function Measure-PaneFps {
    param([System.Collections.IDictionary]$ByPane)
    $rows = @()
    foreach ($k in @($ByPane.Keys)) {
        $v = @($ByPane[$k] | Sort-Object)
        if ($v.Count -eq 0) { continue }
        $p90i = [Math]::Min([int]($v.Count * 0.90), $v.Count - 1)
        $rows += [pscustomobject]@{
            Pane      = $k
            Samples   = $v.Count
            Min       = $v[0]
            Median    = $v[[Math]::Min([int]($v.Count / 2), $v.Count - 1)]
            P90       = $v[$p90i]
            Max       = $v[-1]
            IdleShare = [Math]::Round(@($v | Where-Object { $_ -le 1 }).Count / $v.Count, 2)
        }
    }
    return @($rows | Sort-Object -Property Pane)
}

# Grade one pane per key of $Floors (name -> the fps floor that pane must
# reach). A loaded pane that produced no telemetry at all FAILS (it was told to
# render and never did); one with too few samples to say anything is reported
# and not graded, so a short -Minutes smoke cannot manufacture a verdict out of
# six windows.
#
# The floor is PER PANE because the three load generators do not ask the same
# thing of the renderer, and one floor for all of them is a flake waiting to
# happen. Measured 2026-08-31 over a 5-minute run: `soak-stream` (an endless
# `type` of an 8MB file) sits at the 60 cap, min 59; `soak-altscr` sits at
# median 27 / p90 30 / max 32, because its script SLEEPS 150ms twice per
# iteration - it is paced by its own load, not by the renderer, and grading it
# at 30 puts the bar exactly on its ceiling. Each floor is set where a real
# renderer regression shows up and this run's own margin does not.
function Test-LoadedPaneFps {
    param(
        [object[]]$Rows,
        [System.Collections.IDictionary]$Floors,
        [int]$MinSamples = 60
    )
    $out = @()
    foreach ($name in @($Floors.Keys | Sort-Object)) {
        $floor = [int]$Floors[$name]
        $r = @($Rows | Where-Object { $_.Pane -eq $name })[0]
        if (-not $r) {
            $out += [pscustomobject]@{ Pane = $name; Floor = $floor; Graded = $true; Pass = $false; Why = 'no telemetry from this pane' }
        } elseif ($r.Samples -lt $MinSamples) {
            $out += [pscustomobject]@{ Pane = $name; Floor = $floor; Graded = $false; Pass = $true; Why = "only $($r.Samples) samples (< $MinSamples)" }
        } else {
            $out += [pscustomobject]@{ Pane = $name; Floor = $floor; Graded = $true; Pass = ($r.P90 -ge $floor); Why = "p90 $($r.P90) fps over $($r.Samples) samples" }
        }
    }
    return @($out)
}

# --- Window roster (T1214) -----------------------------------------------------
# The auto-launch below starts the app with its own STARTUP window before the
# `+new-window --target=soak` lands, so the instance holds two windows and the
# soak used only one. The extra window's idle pane then ran for the whole soak:
# 1486 of 7924 samples on 2026-08-31, listed in the report as `other`, while the
# layout assertion walked only the soak window and said 4. These two answer
# "what is in this instance that this run did not mean to open", from one
# `+list --json` roster, so setup can close it and the assertions can see it.
function Get-StrayWindows {
    param($ListJson, [string]$Target)
    # `$null -ne $_`: an absent `windows` pipes one $null, which is not a window.
    return @($ListJson.data.windows | Where-Object { ($null -ne $_) -and ($_.target -ne $Target) })
}

# Every pane leaf in one roster window, across its tabs.
function Get-WindowLeaves {
    param($Window)
    $out = New-Object System.Collections.ArrayList
    $stack = New-Object System.Collections.Stack
    foreach ($t in @($Window.tabs)) { if ($null -ne $t.splits) { $stack.Push($t.splits) } }
    while ($stack.Count -gt 0) {
        $n = $stack.Pop()
        if ($null -ne $n.terminal) { [void]$out.Add($n.terminal) }
        if ($null -ne $n.left) { $stack.Push($n.left) }
        if ($null -ne $n.right) { $stack.Push($n.right) }
    }
    return @($out)
}

# One line naming each stray window and how many panes it holds.
function Format-StrayWindows {
    param([object[]]$Strays)
    return (@($Strays | ForEach-Object { "$($_.target) ($(@(Get-WindowLeaves $_).Count) pane)" }) -join ', ')
}

# --- Scrollback-growth generator (T1215) ----------------------------------------
# `soak-grow` used to print ONE run of 150k lines. By 2026-08-31 the box printed
# that inside a 5-minute run, and the grader rightly skips a pane that finished
# (its tail is idle samples), so the pane was never graded at all. It now repeats
# the 150k-line pass, with a pass count scaled to -Minutes so generously that a
# pass would have to take under a second for the loop to run out: one pass per
# second of the run. It still stops eventually - an unbounded loop in a pane the
# teardown might miss is worse - and the already-finished exclusion stays, for
# the run that somehow outpaces it.
function Get-GrowPasses([int]$Minutes) { return [Math]::Max(60, $Minutes * 60) }

# Which pass the grow pane's tail has reached, and whether it printed the very
# last line of the very last pass. `SOAKGROW <pass> <line>`.
function Get-GrowProgress {
    param([string]$Tail, [int]$Passes)
    $last = @([regex]::Matches($Tail, 'SOAKGROW (\d+) (\d+)'))
    $pass = if ($last.Count) { [int]$last[-1].Groups[1].Value } else { 0 }
    return [pscustomobject]@{
        Pass = $pass
        Done = ($Tail -match "SOAKGROW $Passes 150000\b")
    }
}

# What each load generator is expected to sustain. Used by the run and by
# -SelfTest, so the negative control grades against the same numbers the real
# verdict does.
$script:PaneFpsFloors = @{
    'soak-stream' = 30
    'soak-altscr' = 15
    'soak-grow'   = 30
}

# Negative control for the grader (T1147): `soak.ps1 -SelfTest` proves the
# assertion can score red, in seconds, without a 30-minute run. A gate nobody
# has watched fail is indistinguishable from a gate that cannot fail.
if ($SelfTest) {
    $idle = @(1) * 400
    $fast = @(60) * 300 + @(1) * 100      # stream/grow, with idle stretches
    $paced = @(27) * 280 + @(30) * 20 + @(1) * 100   # altscr, as measured
    $slow = @(8) * 300 + @(1) * 100       # loaded, renderer cannot keep up
    $floors = $script:PaneFpsFloors

    $healthy = Measure-PaneFps @{ 'soak-stream' = $fast; 'soak-altscr' = $paced; 'soak-grow' = $fast; 'probe' = $idle }
    $hv = Test-LoadedPaneFps -Rows $healthy -Floors $floors
    Assert (@($hv | Where-Object { -not $_.Pass }).Count -eq 0) 'selftest: healthy build passes with 400 idle-pane fps=1 samples present'
    Assert ((@($healthy | Where-Object { $_.Pane -eq 'probe' })[0]).IdleShare -eq 1) 'selftest: the idle probe pane is reported as 100% fps<=1'

    $regressed = Measure-PaneFps @{ 'soak-stream' = $fast; 'soak-altscr' = $slow; 'soak-grow' = $fast; 'probe' = $idle }
    $rv = Test-LoadedPaneFps -Rows $regressed -Floors $floors
    Assert (@($rv | Where-Object { -not $_.Pass }).Count -eq 1) 'selftest: a loaded pane dropping to 8 fps turns the verdict RED'
    Assert ((@($rv | Where-Object { $_.Pane -eq 'soak-altscr' })[0]).Pass -eq $false) 'selftest: the red verdict names the pane that dropped'

    $streamDrop = Measure-PaneFps @{ 'soak-stream' = (@(25) * 300 + @(1) * 100); 'soak-altscr' = $paced; 'soak-grow' = $fast; 'probe' = $idle }
    $sv = Test-LoadedPaneFps -Rows $streamDrop -Floors $floors
    Assert ((@($sv | Where-Object { $_.Pane -eq 'soak-stream' })[0]).Pass -eq $false) 'selftest: the 60fps stream pane falling to 25 is RED even though 25 clears altscr floor'

    $missing = Measure-PaneFps @{ 'soak-stream' = $fast; 'soak-grow' = $fast; 'probe' = $idle }
    $mv = Test-LoadedPaneFps -Rows $missing -Floors $floors
    Assert ((@($mv | Where-Object { $_.Pane -eq 'soak-altscr' })[0]).Pass -eq $false) 'selftest: a loaded pane that rendered nothing at all is a failure'

    $short = Test-LoadedPaneFps -Rows (Measure-PaneFps @{ 'soak-stream' = @(60) * 10; 'soak-altscr' = @(60) * 10; 'soak-grow' = @(60) * 10 }) -Floors $floors
    Assert (@($short | Where-Object { $_.Graded }).Count -eq 0) 'selftest: too few samples is reported, not graded'

    # T1215: soak-grow is graded now, so its floor has to be able to fail too.
    $growDrop = Measure-PaneFps @{ 'soak-stream' = $fast; 'soak-altscr' = $paced; 'soak-grow' = $slow; 'probe' = $idle }
    $gv = Test-LoadedPaneFps -Rows $growDrop -Floors $floors
    Assert ((@($gv | Where-Object { $_.Pane -eq 'soak-grow' })[0]).Pass -eq $false) 'selftest: the grow pane dropping to 8 fps is RED'
    Assert ((Get-GrowPasses 5) -ge 300 -and (Get-GrowPasses 30) -ge 1800) 'selftest: the grow pass count scales with -Minutes'
    $mid = Get-GrowProgress -Tail "SOAKGROW 3 149999 x`nSOAKGROW 3 150000 x`nSOAKGROW 4 1 x" -Passes 1800
    Assert ($mid.Pass -eq 4 -and -not $mid.Done) 'selftest: a grow pane between passes reads as still loading, on the pass it reached'
    $end = Get-GrowProgress -Tail "SOAKGROW 1800 149999 x`nSOAKGROW 1800 150000 x" -Passes 1800
    Assert ($end.Done) 'selftest: the last line of the last pass reads as finished'
    Assert (-not (Get-GrowProgress -Tail 'SOAKGROW 18000 150000 x' -Passes 1800).Done) 'selftest: a longer pass number is not mistaken for the last pass'

    # T1215: the teardown hazard. A native progress note on stderr is
    # terminating under `Stop` (negative control), and survivable through
    # Invoke-Tolerant, which also leaves the caller's `Stop` in force.
    $threw = $false
    try { & cmd.exe /c 'echo Waiting for Ghoztty to answer 1>&2' 2>$null | Out-Null } catch { $threw = $true }
    Assert $threw 'selftest: a stderr note through 2>$null is terminating under Stop (negative control)'
    $threw = $false
    try { Invoke-Tolerant { & cmd.exe /c 'echo Waiting for Ghoztty to answer 1>&2' 2>$null | Out-Null } } catch { $threw = $true }
    Assert (-not $threw -and $ErrorActionPreference -eq 'Stop') 'selftest: Invoke-Tolerant survives the stderr note and restores Stop'

    # T1214: the roster audit, against a fabricated `+list --json`. The second
    # roster is the 2026-08-31 shape - the auto-launch's startup window beside
    # the soak window - and must come back as one stray naming it.
    $soakWin = [pscustomobject]@{ target = 'soak'; tabs = @([pscustomobject]@{ splits = [pscustomobject]@{
        left = [pscustomobject]@{ terminal = [pscustomobject]@{ name = 'probe' } }
        right = [pscustomobject]@{ left = [pscustomobject]@{ terminal = [pscustomobject]@{ name = 'soak-stream' } }
            right = [pscustomobject]@{ terminal = [pscustomobject]@{ name = 'soak-grow' } } } } }) }
    $startWin = [pscustomobject]@{ target = 'window-1'; tabs = @([pscustomobject]@{ splits = [pscustomobject]@{
        terminal = [pscustomobject]@{ name = 'p-startup' } } }) }
    $clean = [pscustomobject]@{ data = [pscustomobject]@{ windows = @($soakWin) } }
    $extra = [pscustomobject]@{ data = [pscustomobject]@{ windows = @($startWin, $soakWin) } }
    Assert (@(Get-StrayWindows $clean 'soak').Count -eq 0) 'selftest: a roster holding only the soak window has no stray'
    $es = @(Get-StrayWindows $extra 'soak')
    Assert ($es.Count -eq 1 -and $es[0].target -eq 'window-1') 'selftest: an injected extra window turns the roster check RED and is named'
    Assert ((Format-StrayWindows $es) -eq 'window-1 (1 pane)') 'selftest: the stray is reported with its pane count'
    Assert (@(Get-WindowLeaves $soakWin).Count -eq 3) 'selftest: leaves are counted across nested splits'

    Rep ""
    Rep "=== selftest: $($script:pass) passed, $($script:fail) failed"
    Complete-TestBody
    Write-SoakVerdict -Pass $script:pass -Fail $script:fail -Label 'T53 SOAK SELFTEST'
}

Add-Type @'
using System;
using System.Runtime.InteropServices;
public class SoakDrv {
    [DllImport("user32.dll")] public static extern uint GetGuiResources(IntPtr hProcess, uint uiFlags);
}
'@

# T1126: no release build is a box that cannot answer, not a failure.
if (-not (Test-Path $ExePath)) {
    Write-Host "SKIP ALL: no release build to soak at $ExePath - build it with:"
    Write-Host '    zig build -Dapp-runtime=win32 -Doptimize=ReleaseFast -Dtarget=x86_64-windows-gnu -Dstrip=false --prefix zig-out-release'
    exit 0
}
$exe = $ExePath
# T1158 bystander baseline. Read the USER'S session roster while the env is
# still theirs - $exe is a release build, so with no GHOZTTY_AGENT_INSTANCE set
# it dials exactly the agent that owns the user's live panes. This is the
# measurement the fix is judged by, and it is taken by the harness itself so
# every future run re-proves it instead of trusting the env vars below.
#
# T2005: and read in the SAME env both times - no lineage, the real
# LOCALAPPDATA - whatever the caller handed this process. A second loop lane's
# runner sets GHOZTTY_AGENT_INSTANCE, and the baseline used to be read under it
# (some other roster) while the after-read below dropped it (the user's), so
# every session the user owned scored as a stray. The lineage is dropped only
# for a release-lineage exe, whose default lineage is the user's installed
# agent; a debug exe's default lineage is a loop lane's own agent, so it keeps
# the caller's. Either way the env is handed back afterwards.
. (Join-Path $PSScriptRoot 'lib\AgentLineage.ps1')
$soakModeExe = [System.IO.Path]::ChangeExtension($exe, '.com')
if (-not (Test-Path $soakModeExe)) { $soakModeExe = $exe }
$soakIsDebugLineage = Test-GhozttyIsolatedBuildMode -Mode (Get-GhozttyBuildMode -Exe $soakModeExe)
function Get-UserSessionIds {
    $savedInst = Get-GhozttyAgentLineage
    $savedLad = $env:LOCALAPPDATA
    try {
        if (-not $soakIsDebugLineage) { Remove-Item Env:GHOZTTY_AGENT_INSTANCE -ErrorAction SilentlyContinue }
        $env:LOCALAPPDATA = [Environment]::GetFolderPath('LocalApplicationData')
        return @(
            (& $exe +sessions 2>&1 | ForEach-Object { $_.ToString() }) |
                Where-Object { $_ -match '^[0-9a-f]{32}' } |
                ForEach-Object { ($_ -split '\s+')[0] }
        )
    } finally {
        Restore-GhozttyAgentLineage -Saved $savedInst
        $env:LOCALAPPDATA = $savedLad
    }
}
$userSessionsBefore = @(Get-UserSessionIds)

# T1158: ALL THREE isolating knobs, not just the app pipe. This harness's
# subject is a RELEASE build, so its endpoints are the user's by default, and
# for weeks it held only `GHOZTTY_PIPE_SUFFIX` - the state BuildMode.ps1's own
# header calls "the dangerous state, not a partial win". The app pipe was
# private while every pane it opened became a session in the agent that owns the
# user's live terminal, PINNED. A pinned live session is immortal on purpose
# (it is what lets a pane outlive its window), so nothing reaped them: two runs
# left six shells behind, and the 5am refresh restarted the user's terminal into
# the pile. `-ReleaseSandbox` adds GHOZTTY_AGENT_INSTANCE and a private
# LOCALAPPDATA, and `Assert-GhozttyIsolatedBuild` below now verifies all three
# rather than taking `-AllowReleaseBuild` on trust.
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 'soak' -ReleaseSandbox -SandboxRoot (Join-Path $outDir 'sandbox'))
$env:GHOZTTY_PERF = '1'

# T1229: the sandbox above is deleted when this run exits; the report beside it
# is what a run is FOR, so it stays - but not forever. Keep the newest
# $keepReports run directories and drop the rest, oldest first.
$keepReports = 20
$oldRuns = @(Get-ChildItem -LiteralPath (Split-Path $outDir -Parent) -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^\d{8}-\d{6}$' } | Sort-Object Name -Descending | Select-Object -Skip $keepReports)
foreach ($r in $oldRuns) { try { [void](Remove-SandboxDir -Path $r.FullName) } catch { } }
if ($oldRuns.Count) { Rep "pruned $($oldRuns.Count) soak report dir(s) beyond the newest $keepReports" }
# Now that LOCALAPPDATA is the sandbox, this is the log THIS run's app writes.
# It used to be the user's own `ghoztty.log`, so the GHOZTTY_PERF slice below
# was reading the user's live terminal's telemetry interleaved with the soak's.
$appLog = Join-Path $env:LOCALAPPDATA 'ghoztty\ghoztty.log'
$exeItem = Get-Item $exe
Rep "=== ghoztty soak $stamp"
Rep "exe: $exe ($(($exeItem).LastWriteTime), $(($exeItem).Length) bytes)"
Rep "duration: $Minutes min; pipe suffix: $env:GHOZTTY_PIPE_SUFFIX"
Rep "agent lineage: $env:GHOZTTY_AGENT_INSTANCE; state root: $env:LOCALAPPDATA"

# --- Load-generator assets ----------------------------------------------------
$assetDir = Join-Path $env:TEMP 'ghoztty-soak'
$streamFile = Join-Path $assetDir 'stream.txt'
if (-not (Test-Path $streamFile) -or (Get-Item $streamFile).Length -lt 8000000) {
    $line = ('soak-stream-payload ' + ('x' * 60))
    $block = [System.Text.StringBuilder]::new()
    1..1000 | ForEach-Object { [void]$block.AppendLine("$line $_") }
    $sw = [System.IO.StreamWriter]::new($streamFile, $false)
    1..100 | ForEach-Object { $sw.Write($block.ToString()) }
    $sw.Close()
}
$altscrScript = Join-Path $assetDir 'altscr.ps1'
@'
$e = [char]27
while ($true) {
    [console]::Write("$e[?1049h")
    1..100 | ForEach-Object { [console]::WriteLine("altscr churn line $_ " + ('y' * 40)) }
    Start-Sleep -Milliseconds 150
    [console]::Write("$e[?1049l")
    1..20 | ForEach-Object { [console]::WriteLine("primary interlude $_") }
    Start-Sleep -Milliseconds 150
}
'@ | Set-Content -Encoding ascii $altscrScript

# --- Fresh isolated instance + layout -----------------------------------------
# T248: the sibling agent and the debug session-layout manifest are part of
# "fresh" — a soak that inherits the previous run's persisted pane is soaking
# a pane nobody just created, with hours of its own scrollback already in it.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
# T1241: the auto-launch below goes to the background test desktop.
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
# T350: -AllowReleaseBuild, said out loud. This harness's SUBJECT is the release
# build (its whole point is grading what ships), so it is the one caller that
# legitimately runs an exe whose endpoints are not the -debug ones. The run-unique
# suffix above keeps its app endpoint off the user's; its kills are path-exact
# to zig-out-release either way.
Reset-GhozttyTestState -Exe $exe -SettleMs 500 -AllowReleaseBuild | Out-Null

# Auto-launch flow: +new-window spawns the GUI (detached) when no soak
# instance answers, and names the window.
#
# T1241: the CLI runs on the BACKGROUND test desktop, and the app it auto-spawns
# inherits that desktop - so a soak no longer parks four load-generating panes
# across whatever the user is reading. -AllowReleaseBuild for the same reason
# Reset-GhozttyTestState above takes it: the release build IS this harness's
# subject.
$td = New-TestDesktop
[void](Invoke-OnTestDesktop -Exe $exe -Arguments @('+new-window', '--target=soak', '--shell=cmd') `
    -AllowReleaseBuild -TimeoutSec 60)
Start-Sleep -Seconds 3
$gui = @(Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
    Where-Object { $_.ExecutablePath -eq $exe } |
    Where-Object { $_.ProcessId -ne $PID })
# The window is on the test desktop, so .NET's MainWindowHandle - which
# enumerates the CALLER's desktop - reads 0 for every one of these processes.
# Ask the desktop that actually has the window.
$gui = @($gui | Where-Object {
    (Get-TestWindow -ProcessId $_.ProcessId -Class 'GhozttyWindow') -ne [IntPtr]::Zero })
# An ABORT after the GUI exists used to `exit 1` straight past the teardown at
# the bottom of this script, leaving the three load generators pinning the box
# and the sandbox agent running. On 2026-08-31 that turned one aborted setup
# into a machine that was still at full tilt five minutes later, which is
# exactly the state that makes the NEXT attempt abort too. Every abort from
# here down goes through this instead.
function Abort-Soak([string]$why) {
    Rep "ABORT: $why"
    Invoke-Tolerant { & $exe +close --target=soak 2>$null | Out-Null }
    Start-Sleep -Seconds 1
    try { [void](Stop-RepoGhoztty -Exe $exe -SettleMs 1500) } catch { Rep "  (teardown: $_)" }
    try { Remove-TestDesktop | Out-Null } catch { }
    exit 1
}

if ($gui.Count -ne 1) { Rep "ABORT: expected 1 soak GUI process, got $($gui.Count)"; exit 1 }
$proc = Get-Process -Id $gui[0].ProcessId
Rep "gui pid: $($proc.Id)"

# T1214: close what the auto-launch opened that this run did not ask for. The
# app comes up with its own startup window and only then takes the
# `+new-window`, so before this the soak carried a fifth, idle pane in a window
# nothing measured and nothing closed - `+close --target=soak` never reached it
# and it went only because the teardown killed the process. Done now, before
# any load starts, so its pane never reaches the telemetry; and proved by
# reading the roster back, not by trusting the close.
$startRaw = Get-GhozttyListRaw -Exe $exe
$startBrace = $startRaw.IndexOf('{')
if ($startBrace -lt 0) { Abort-Soak "+list --json produced no JSON at startup: $startRaw" }
$startStrays = @(Get-StrayWindows ($startRaw.Substring($startBrace) | ConvertFrom-Json) 'soak')
if ($startStrays.Count -eq 0) {
    Rep 'startup roster: only the soak window (no startup window to close)'
} else {
    Rep "startup roster: closing what the auto-launch opened beside the soak window: $(Format-StrayWindows $startStrays)"
    foreach ($s in $startStrays) { Invoke-Tolerant { & $exe +close "--target=$($s.target)" 2>$null | Out-Null } }
    Start-Sleep -Seconds 1
    $afterRaw = Get-GhozttyListRaw -Exe $exe
    $afterBrace = $afterRaw.IndexOf('{')
    if ($afterBrace -lt 0) { Abort-Soak "+list --json produced no JSON after closing the startup window: $afterRaw" }
    $left = @(Get-StrayWindows ($afterRaw.Substring($afterBrace) | ConvertFrom-Json) 'soak')
    if ($left.Count -gt 0) { Abort-Soak "the startup window would not close: $(Format-StrayWindows $left)" }
    Rep 'startup roster: closed; the instance now holds only the soak window'
}

& $exe +split --target=soak --name=soak-stream --direction=right --shell=cmd `
    "--command=for /l %i in (1,1,2000000) do @type $streamFile" | Out-Null
Start-Sleep -Milliseconds 800
# T782: the transport is Invoke-NativeExact (byte-exact argv), so the quotes
# below reach the CLI instead of being stripped by PowerShell 5.1 on the way
# out. T1601 gave them somewhere to land: sending them intact used to make the
# pane run nothing at all (the soak reported "no telemetry from this pane"),
# because the cmd flavor could not express a quoted path. Keep them - this is
# the quoted form a scripter would write, and the thing worth soaking.
$null = Invoke-NativeExact -FilePath $exe -Arguments @(
    '+split', '--target=soak', '--name=soak-altscr', '--direction=down',
    '--shell=cmd',
    "--command=powershell -nop -ExecutionPolicy Bypass -File `"$altscrScript`"")
Start-Sleep -Milliseconds 800
# T2163: `--pane`, not `--target`. `--target` names a WINDOW, so
# `--target=soak-stream` resolved to the soak window and split its focused pane
# - the probe, which already had soak-altscr under it. That made a column of
# three in a 600-DIP-tall window, and the stacked-panes layout (T2108) tucked
# soak-altscr out of sight: hidden on purpose, so its renderer presented
# nothing for the rest of the run, which read as a frozen pane.
$growPasses = Get-GrowPasses $Minutes
# argv-audit: $growPasses is an [int] from Get-GrowPasses - digits only, nothing argv can split or strip.
& $exe +split --pane=soak-stream --name=soak-grow --direction=down --shell=cmd `
    "--command=for /l %j in (1,1,$growPasses) do @for /l %i in (1,1,150000) do @echo SOAKGROW %j %i abcdefghijklmnopqrstuvwxyz0123456789" | Out-Null
Start-Sleep -Seconds 2

# The window's original (unnamed) pane is the latency-probe target: it is
# the leaf whose name we did not choose.
#
# This `+list` runs two seconds after three load generators were turned on, so
# it asks the app its busiest question at its busiest moment. The default 30s
# IPC budget is not enough there: on 2026-08-31 it timed out and the run
# ABORTED at minute one, throwing away a 30-minute soak before a single sample
# was taken. This is SETUP, not a measurement - the `+list` that is actually
# graded is the one at the end of the run, which keeps the default budget - so
# it gets a wider one rather than a verdict.
#
# And the OUTPUT is captured through cmd redirection, then sanitised before it
# is parsed. When the app does not answer immediately the client prints
# "Waiting for Ghoztty to answer '+list' ..." on its way to SUCCEEDING - a
# progress message, not a failure - and it cost this run twice on 2026-08-31.
# Once as JSON: `& $exe +list --json | ConvertFrom-Json` fed that line to the
# parser, the parse threw, and the run aborted with "soak window not in +list"
# while the window was right there. And once as an exception: rewriting it as
# `& $exe ... 2>&1` turned the same message into a NativeCommandError, which
# `$ErrorActionPreference = 'Stop'` at the top of this file makes TERMINATING -
# the script died with no ABORT line at all. `Get-GhozttyListRaw` (Isolation.ps1)
# redirects inside cmd, so neither hazard exists; everything from the first `{`
# is the JSON.
$prevIpcTimeout = $env:GHOZTTY_IPC_TIMEOUT_MS
$env:GHOZTTY_IPC_TIMEOUT_MS = '120000'
try {
    $listRaw = Get-GhozttyListRaw -Exe $exe
} finally { $env:GHOZTTY_IPC_TIMEOUT_MS = $prevIpcTimeout }
$brace = $listRaw.IndexOf('{')
if ($brace -lt 0) { Abort-Soak "+list --json produced no JSON: $listRaw" }
$listJson = $listRaw.Substring($brace) | ConvertFrom-Json
$leaves = @()
function Walk($node) {
    if ($null -ne $node.terminal) { $script:leaves += $node.terminal }
    if ($null -ne $node.left) { Walk $node.left; Walk $node.right }
}
$win = $listJson.data.windows | Where-Object { $_.target -eq 'soak' }
if (-not $win) { Abort-Soak 'soak window not in +list' }
$win.tabs | ForEach-Object { Walk $_.splits }
$named = @('soak-stream', 'soak-altscr', 'soak-grow')
$probe = @($leaves | Where-Object { $named -notcontains $_.name })
if ($probe.Count -ne 1) { Abort-Soak "expected 1 probe pane, got $($probe.Count) of $($leaves.Count) leaves" }
$probePane = $probe[0].name
# T1147: the `perf pane=<uuid>` telemetry names panes by their pane id; this is
# how the ids become the names this script gave them, so the report and the
# assertions read in the harness's own vocabulary.
$paneNames = @{}
foreach ($l in $leaves) { if ($l.id) { $paneNames[[string]$l.id] = [string]$l.name } }
$loadedPanes = $named
Assert ($leaves.Count -eq 4) "layout: 4 leaves in soak window (probe pane: $probePane)"
# T1214: and nothing beside it. The line above walks only the soak window, so
# it said 4 for a whole month while the instance held a fifth pane elsewhere.
$rosterStrays = @(Get-StrayWindows $listJson 'soak')
Assert ($rosterStrays.Count -eq 0) "layout: the instance holds only the soak window (strays: $(if ($rosterStrays.Count) { Format-StrayWindows $rosterStrays } else { 'none' }))"

# T2163: every pane must be ON SHOW. A pane the stacked-panes layout tucked
# away is hidden by design and presents no frames, so grading it would score
# the layout rather than the renderer - which is exactly how a mis-targeted
# split read as "the renderer stops after a split" for two full soaks. Abort
# with the layout in the report instead of spending 30 minutes on it.
$tucked = @($leaves | Where-Object { $_.minimized -eq $true } | ForEach-Object { $_.name })
if ($tucked.Count -gt 0) {
    Abort-Soak "pane(s) tucked out of sight by the stacked-panes layout, so they cannot render: $($tucked -join ', ')"
}
Rep "layout: all 4 panes on show (none tucked)"

# T1160: prove the alt-screen generator is RUNNING before spending 30 minutes
# grading it. "no telemetry from this pane" at minute 30 has two causes that
# read the same: a generator that never started (the T1601 shape), and a
# renderer that stopped presenting while the generator ran on. Checking the
# generator here separates them: a dead generator aborts in seconds with the
# pane's screen in the report, and the tucked-pane check above rules out the
# layout hiding it (T2163), so a missing-telemetry FAIL later is the renderer's.
$altscrAlive = $false
$altscrScreen = ''
$altscrDeadline = (Get-Date).AddSeconds(30)
while ((Get-Date) -lt $altscrDeadline) {
    $altscrScreen = (Invoke-Tolerant { & $exe +read --name=soak-altscr --lines=40 2>&1 | ForEach-Object { $_.ToString() } }) -join "`n"
    if ($altscrScreen -match 'altscr churn line|primary interlude') { $altscrAlive = $true; break }
    Start-Sleep -Seconds 2
}
if (-not $altscrAlive) {
    Rep "soak-altscr screen after 30s (last 15 lines):"
    ($altscrScreen -split "`n" | Select-Object -Last 15) | ForEach-Object { Rep "    | $_" }
    $altLeaf = @($leaves | Where-Object { $_.name -eq 'soak-altscr' })[0]
    if ($altLeaf) { Rep "soak-altscr leaf: id $($altLeaf.id) pid $($altLeaf.pid) title '$($altLeaf.title)'" }
    Abort-Soak 'soak-altscr load generator produced no output within 30s of setup'
}
Rep "soak-altscr generator confirmed running"

# Baseline +read latency on the (still small) grow pane, for the end-of-run
# big-scrollback comparison.
$sw = [System.Diagnostics.Stopwatch]::StartNew()
& $exe +read --name=soak-grow --lines=50 | Out-Null
$sw.Stop()
$readBaselineMs = $sw.ElapsedMilliseconds
Rep "baseline +read latency (grow pane mid-blast): ${readBaselineMs}ms"
if ($readBaselineMs -gt 2000) {
    Rep "WARN  +read stalled ${readBaselineMs}ms against a tiny-write storm - known issue (T62 renderer-mutex starvation), not asserted here"
}

$logStart = if (Test-Path $appLog) { (Get-Item $appLog).Length } else { 0 }

# --- Sampling loop -------------------------------------------------------------
'elapsed_s,ws_mb,private_mb,handles,threads,gdi,user,responding,latency_ms' |
    Set-Content -Encoding ascii $csv
$deadline = (Get-Date).AddMinutes($Minutes)
$t0 = Get-Date
$notRespondingSamples = 0
$latencies = @()
$samples = @()
$lastLatencyProbe = (Get-Date).AddSeconds(-60)
$probeN = 0
$procAlive = $true

while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 15
    $proc.Refresh()
    if ($proc.HasExited) { $procAlive = $false; Rep 'FATAL: gui process exited mid-soak'; break }

    $elapsed = [int]((Get-Date) - $t0).TotalSeconds
    $wsMb = [math]::Round($proc.WorkingSet64 / 1MB, 1)
    $privMb = [math]::Round($proc.PrivateMemorySize64 / 1MB, 1)
    $gdi = [SoakDrv]::GetGuiResources($proc.Handle, 0)
    $usr = [SoakDrv]::GetGuiResources($proc.Handle, 1)
    $resp = $proc.Responding
    if (-not $resp) { $notRespondingSamples++ }

    $latMs = ''
    if (((Get-Date) - $lastLatencyProbe).TotalSeconds -ge 60) {
        $lastLatencyProbe = Get-Date
        $probeN++
        $marker = "LATPROBE_$probeN"
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        & $exe +send-keys --target=$probePane "echo $marker" Enter | Out-Null
        $found = $false
        while (-not $found -and $sw.ElapsedMilliseconds -lt 5000) {
            Start-Sleep -Milliseconds 100
            $tail = & $exe +read --name=$probePane --lines=5 | Out-String
            # Marker must appear twice: the echoed command AND its output
            # (the send itself proves echo; the second copy proves execution).
            if (([regex]::Matches($tail, $marker)).Count -ge 2) { $found = $true }
        }
        $sw.Stop()
        if ($found) { $latMs = $sw.ElapsedMilliseconds; $latencies += [int]$latMs }
        else { $latMs = -1; Rep "WARN  latency probe $probeN never became visible (5s)" }
    }

    $row = "$elapsed,$wsMb,$privMb,$($proc.HandleCount),$($proc.Threads.Count),$gdi,$usr,$resp,$latMs"
    Add-Content -Encoding ascii $csv $row
    $samples += [pscustomobject]@{
        Elapsed = $elapsed; WsMb = $wsMb; PrivMb = $privMb
        Handles = $proc.HandleCount; Gdi = $gdi; Usr = $usr
    }
}

# --- End-of-run probes ---------------------------------------------------------
if ($procAlive) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $growTail = & $exe +read --name=soak-grow --lines=50 | Out-String
    $sw.Stop()
    $readBigMs = $sw.ElapsedMilliseconds
    $growProgress = Get-GrowProgress -Tail $growTail -Passes $growPasses
    $growDone = $growProgress.Done
    Rep "big-scrollback +read latency: ${readBigMs}ms (baseline ${readBaselineMs}ms; grow finished: $growDone, pass $($growProgress.Pass) of $growPasses)"

    $listOk = $true
    & $exe +list | Out-Null
    if ($LASTEXITCODE -ne 0) { $listOk = $false }
}

# Telemetry slice from the app log (only the soak exe runs with
# GHOZTTY_PERF set, so 'perf ' lines in the increment are ours).
$fpsVals = @()
$gapVals = @()
$fpsByPane = @{}
$anonSamples = 0
$slowMutex = 0
if ((Test-Path $appLog) -and (Get-Item $appLog).Length -gt $logStart) {
    $fs = [System.IO.FileStream]::new($appLog, 'Open', 'Read', 'ReadWrite')
    try {
        $fs.Seek($logStart, 'Begin') | Out-Null
        $sr = [System.IO.StreamReader]::new($fs)
        $sliceWriter = [System.IO.StreamWriter]::new($logSlice, $false)
        while ($null -ne ($line = $sr.ReadLine())) {
            if ($line -match 'perf |slow') { $sliceWriter.WriteLine($line) }
            # `pane=` is optional so this harness still reads an exe built
            # before T1147 - it falls back to the pooled assertion below and
            # says so, instead of silently grading nothing.
            if ($line -match 'perf (?:pane=(\S+) )?fps=(\d+) max_gap_ms=(\d+)') {
                $fps = [int]$Matches[2]
                $fpsVals += $fps
                $gapVals += [int]$Matches[3]
                $pane = $Matches[1]
                if ($pane) {
                    $key = if ($paneNames.ContainsKey($pane)) { $paneNames[$pane] } else { $pane }
                    if (-not $fpsByPane.ContainsKey($key)) { $fpsByPane[$key] = @() }
                    $fpsByPane[$key] += $fps
                } else { $anonSamples++ }
            }
            if ($line -match 'slow.*mutex|mutex.*slow') { $slowMutex++ }
        }
        $sliceWriter.Close()
    } finally { $fs.Close() }
}

# --- Assertions ---------------------------------------------------------------
Assert $procAlive 'gui process alive for the whole soak'
if ($procAlive) {
    Assert ($notRespondingSamples -eq 0) "responsive at every sample (not-responding samples: $notRespondingSamples)"
    Assert $listOk 'IPC still answers +list at the end'
    Assert ($readBigMs -lt 1000) "+read on 150k-line scrollback < 1s (${readBigMs}ms)"

    if ($fpsVals.Count -gt 10) {
        $sortedFps = $fpsVals | Sort-Object
        $medianFps = $sortedFps[[int]($sortedFps.Count / 2)]
        $maxGap = ($gapVals | Measure-Object -Maximum).Maximum
        # max_gap is informational only: an IDLE unfocused pane legitimately
        # reports gaps equal to the time between its redraws (e.g. ~60s
        # between latency probes), so a global stall assertion false-fails.
        # Stall detection comes from Responding, the per-pane fps grading
        # below, and the latency probes instead.
        $p90Fps = $sortedFps[[int]($sortedFps.Count * 0.90)]
        Rep "renderer telemetry: $($fpsVals.Count) samples across $($fpsByPane.Count) panes, pooled median fps $medianFps, pooled p90 $p90Fps, worst frame gap ${maxGap}ms, slow-mutex warns $slowMutex"

        # Per-pane breakdown FIRST, because it is the evidence the pooled
        # numbers above cannot be read without: it shows, from the telemetry
        # rather than by inference, that the fps=1 mass belongs to the idle
        # probe pane.
        $paneRows = Measure-PaneFps $fpsByPane
        foreach ($r in $paneRows) {
            $tag = if ($loadedPanes -contains $r.Pane) { 'LOADED' } elseif ($r.Pane -eq $probePane) { 'idle probe' } else { 'NOT OURS' }
            Rep ("  pane {0,-14} {1,-11} samples {2,5}  min {3,3}  median {4,3}  p90 {5,3}  max {6,3}  fps<=1 share {7}" -f `
                $r.Pane, $tag, $r.Samples, $r.Min, $r.Median, $r.P90, $r.Max, $r.IdleShare)
        }
        # T1214: every pane in the telemetry is one this run created. A row
        # keyed by a raw id is a pane the roster never named - the shape the
        # startup window's pane had, pooled into every number above.
        $notOurs = @($paneRows | Where-Object { ($loadedPanes -notcontains $_.Pane) -and ($_.Pane -ne $probePane) })
        Assert ($notOurs.Count -eq 0) "telemetry lists only the panes this run created (not ours: $(if ($notOurs.Count) { ($notOurs | ForEach-Object { "$($_.Pane) x$($_.Samples)" }) -join ', ' } else { 'none' }))"

        if ($fpsByPane.Count -gt 0) {
            # `soak-grow` repeats its 150k-line pass for the whole run (T1215),
            # but it is bounded: if it ever does finish, its tail samples are
            # idle samples like the probe's. Grade it only while it is still
            # loading at the end of the run; the same cannot happen to
            # stream/altscr, which are endless loops by construction.
            $grade = @{}
            foreach ($k in $script:PaneFpsFloors.Keys) { $grade[$k] = $script:PaneFpsFloors[$k] }
            if ($growDone) {
                $grade.Remove('soak-grow')
                Rep "  (soak-grow finished all $growPasses passes and went idle - not graded)"
            }

            $verdicts = Test-LoadedPaneFps -Rows $paneRows -Floors $grade
            foreach ($v in $verdicts) {
                if ($v.Graded) { Assert $v.Pass "loaded pane $($v.Pane) sustains >= $($v.Floor) fps ($($v.Why))" }
                else { Rep "  WARN  $($v.Pane) not graded: $($v.Why)" }
            }
            if ($anonSamples -gt 0) {
                Rep "  WARN  $anonSamples perf samples carried no pane= (pre-T1147 exe?) and were pooled only"
            }
        } else {
            # Pre-T1147 exe: no sample says which pane it came from, so the
            # best available claim is the pooled one T1158 left behind.
            Rep 'WARN  no perf sample carried pane= - grading the pooled population (pre-T1147 exe)'
            Assert ($p90Fps -ge 30) "the rendering windows sustain >= 30 fps (pooled p90 $p90Fps)"
        }
    } else {
        Rep "WARN  too few perf log windows ($($fpsVals.Count)) - telemetry assertions skipped"
    }

    if ($latencies.Count -ge 2) {
        $latSorted = $latencies | Sort-Object
        $latMed = $latSorted[[int]($latSorted.Count / 2)]
        Rep "input-latency probes: $($latencies.Count) ok, median ${latMed}ms, worst $($latSorted[-1])ms"
        Assert ($latMed -lt 2000) "median echo round-trip < 2s under load (${latMed}ms)"
    }

    # Leak heuristics: compare medians of the first and last quarters so
    # early scrollback fill does not count as a leak.
    if ($samples.Count -ge 8) {
        $q = [int]($samples.Count / 4)
        $firstQ = $samples[0..($q - 1)]
        $lastQ = $samples[($samples.Count - $q)..($samples.Count - 1)]
        function MedianOf($arr, $prop) {
            $v = @($arr | ForEach-Object { $_.$prop } | Sort-Object)
            return $v[[int]($v.Count / 2)]
        }
        $privDelta = (MedianOf $lastQ 'PrivMb') - (MedianOf $firstQ 'PrivMb')
        $handleDelta = (MedianOf $lastQ 'Handles') - (MedianOf $firstQ 'Handles')
        $gdiDelta = (MedianOf $lastQ 'Gdi') - (MedianOf $firstQ 'Gdi')
        $usrDelta = (MedianOf $lastQ 'Usr') - (MedianOf $firstQ 'Usr')
        Rep "growth q1->q4 (median): private ${privDelta}MB, handles $handleDelta, GDI $gdiDelta, USER $usrDelta"
        Assert ($privDelta -lt 300) "private-bytes growth after fill < 300MB (${privDelta}MB)"
        Assert ($handleDelta -lt 500) "handle growth after fill < 500 ($handleDelta)"
        Assert ($gdiDelta -lt 200) "GDI-object growth after fill < 200 ($gdiDelta)"
        Assert ($usrDelta -lt 200) "USER-object growth after fill < 200 ($usrDelta)"
    }
}

# --- Teardown ------------------------------------------------------------------
# Invoke-Tolerant: soak-grow is still loading here (T1215), so the app can be
# slow to answer and the CLI's progress note lands on stderr.
Invoke-Tolerant { & $exe +close --target=soak 2>$null | Out-Null }
Start-Sleep -Seconds 2
if ($procAlive) {
    # T1214: the close is shown to have closed everything this run opened,
    # BEFORE the kill below can paper over it: either the app quit with its
    # last window, or it answers with an empty roster.
    $proc.Refresh()
    if ($proc.HasExited) {
        Assert $true 'teardown: +close --target=soak closed the last window and the app exited on its own'
    } else {
        $endRaw = Get-GhozttyListRaw -Exe $exe
        $endBrace = $endRaw.IndexOf('{')
        # Every window is a stray once the soak window is meant to be gone, so
        # this is the same audit against a target nothing holds.
        # (Not `$x = if ... { @() }`: an assignment from `if` unrolls an empty
        # array to $null, which would read as "no JSON".)
        $endWins = @()
        if ($endBrace -ge 0) { $endWins = @(Get-StrayWindows ($endRaw.Substring($endBrace) | ConvertFrom-Json) '') }
        if ($endBrace -lt 0) {
            Assert $false "teardown: +list after the close produced no JSON: $endRaw"
        } else {
            Assert ($endWins.Count -eq 0) "teardown: +close --target=soak leaves no window behind (left: $(if ($endWins.Count) { Format-StrayWindows $endWins } else { 'none' }))"
        }
    }
    $proc.Refresh()
    if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
}

# T1158: the sandbox has an agent of its OWN now, and a `--pty-host` holder per
# pane that deliberately outlives it (T904/T906 - that is what makes a session
# survive an agent restart, so it is neither a child of the agent nor in its
# job). Closing the window reaches none of them, which is the T1127 shape
# exactly. Stop-RepoGhoztty is path-exact and refuses anything not under the
# repo, so this can only ever reach zig-out-release's own processes - never the
# installed agent holding the user's panes.
[void](Stop-RepoGhoztty -Exe $exe -SettleMs 1500)
Remove-TestDesktop | Out-Null

# --- T1158: the bystander check ------------------------------------------------
# The point of the whole sandbox, asserted rather than assumed. Read the user's
# roster back with the env restored to theirs; a session this run opened must
# not be in it. Before the sandbox every soak added its panes here as PINNED
# sessions, which are immortal by design (that is what lets a pane outlive its
# window), so nothing reaped them and the 5am refresh restarted the user's
# terminal into the accumulated pile.
$userSessionsAfter = @(Get-UserSessionIds)
$strays = @($userSessionsAfter | Where-Object { $userSessionsBefore -notcontains $_ })
Rep "bystander: user agent held $($userSessionsBefore.Count) session(s) before, $($userSessionsAfter.Count) after"
Assert ($strays.Count -eq 0) "no session leaked into the user's agent (strays: $($strays -join ' '))"

Rep ''
Rep "report: $report"
Complete-TestBody
Write-SoakVerdict -Pass $script:pass -Fail $script:fail -Label 'T53 SOAK'
