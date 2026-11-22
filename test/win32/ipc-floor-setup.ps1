# ipc-floor-setup acceptance (T1285) - the P1-P3 floor's two harness defects,
# each with the demonstration that the fix can actually fail.
#
#   powershell -NoProfile -File test\win32\ipc-floor-setup.ps1
#
# A. STREAM SEPARATION. `Invoke-OnTestDesktop` used to hand the child ONE file
#    for stdout and stderr, so the CLI's own diagnostics landed in the middle of
#    machine-readable output. Measured 2026-09-02: `+list --json` came back with
#    the 5-second "Waiting for Ghoztty to answer" notice in front of the JSON and
#    `ConvertFrom-Json` failed with "Invalid JSON primitive: Waiting." - a SLOW
#    answer scored as a MALFORMED one, in the floor whose job is telling those
#    apart. `.StdOut` and `.StdErr` are now separate; `.Output` still carries
#    both, because ~50 scripts read an error sentence out of it.
#
# B. THE FIXTURE IS CHECKED. `ipc-p2.ps1` scored 16 FAILURE(S) that day and
#    every line of it was a claim about the product - +split, +send-keys and
#    +rename all "broken" - when the truth was that its fixture window never came
#    up and every verb after it addressed a target that did not exist. A gate
#    that has only ever been seen saying "fine" is not a gate (go.md), so this
#    section CONSTRUCTS an unreachable app - `GHOZTTY_IPC_TIMEOUT_MS=1` gives
#    every exchange a one-millisecond bound - and asserts the floor answers with
#    ONE setup failure instead of a cascade.
#
# C. SLOW IS NOT BROKEN (T894). The first cut of B treated BOTH sentences the
#    CLI can print as "unreachable", including `writeNotice` - the 5-second "I
#    am still waiting" line that is followed by a successful answer. A cold
#    auto-launch is over 5 seconds by design (`ipc_timeout.auto_launch_ms` is
#    30s for the loader + Defender + config + restore), so the floor's first run
#    after `floor-lane.ps1 -Lane all` went red on a perfectly healthy build and
#    green on the warm re-run. That is the same cry-wolf defect as B, one layer
#    down. The two sentences cannot be constructed end to end on demand (the
#    notice needs a genuinely slow app), so this section drives `Need-Ghoz`
#    directly over canned CLI answers: slow-then-succeeded must PASS with a
#    note, gave-up must FAIL, and the FAIL half is what stops this from being a
#    fix that simply never refuses anything.
#
# D. THE POLL OUTLASTS ONE CALL (T1677). The floor polled +list for 20s while a
#    single +list is allowed 30s, so one cold call could spend the whole wait.
#    `Wait-FloorListMatch` grants its window on top of the CLI's own call bound;
#    D1 runs the old loop over the same canned answers and must miss.
#
# E. THE APP'S SIDE OF A FAILURE (T1769). A fixture verb that failed used to
#    name only the CLI's half - exit code, elapsed, "Timed out". The evidence
#    block now also says what the app was doing (running? pipe open? log tail?)
#    and names one of four shapes; each is constructed here.
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe'
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
$script:failures = 0
$script:passes = 0

function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ } else { "  FAIL $name"; $script:failures++ }
}

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 'floorsetup')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

# T900: a RED run's transcript is copied somewhere the next re-run cannot
# truncate, and the verdict line names it. See lib\Transcript.ps1.
. (Join-Path $PSScriptRoot 'lib\Transcript.ps1')
$transcript = New-TestTranscript -Name 'ipc-floor-setup'
$td = New-TestDesktop

& {

"== A: stdout and stderr come back apart"
# cmd.exe is the smallest thing on the box that writes a known line to each.
$marker = "FLOORSETUP-$PID"
$r = Invoke-OnTestDesktop -Exe "$env:SystemRoot\System32\cmd.exe" `
    -Arguments @('/c', "echo OUT-$marker& echo ERR-$marker 1>&2")
Assert "A1 the call ran" ($r.ExitCode -eq 0)
Assert "A2 stdout has only the stdout line" (
    $r.StdOut -match "OUT-$marker" -and $r.StdOut -notmatch "ERR-$marker")
Assert "A3 stderr has only the stderr line" (
    $r.StdErr -match "ERR-$marker" -and $r.StdErr -notmatch "OUT-$marker")
Assert "A4 Output still carries both (the compatibility half)" (
    $r.Output -match "OUT-$marker" -and $r.Output -match "ERR-$marker")

"== B: an app that cannot be reached is ONE setup failure, not a cascade"
# The negative control. Every exchange gets a 1ms bound, which no round trip
# meets, so the floor's very first fixture verb fails - exactly the state that
# produced sixteen wrong answers before this landed.
Reset-GhozttyTestState -Exe $Exe -SettleMs 800 | Out-Null
$log = Join-Path $env:TEMP "ghoztty-floor-setup-negative-$PID.log"
$prev = $env:GHOZTTY_IPC_TIMEOUT_MS
$env:GHOZTTY_IPC_TIMEOUT_MS = '1'
# T1475: this red is ours, on purpose - so the child must not file it as an
# ipc-p2 failure. On 2026-10-17 it did, and the deliberate run sat in %TEMP%
# looking exactly like the flake T1475 was hunting.
$prevExpected = $env:GHOZTTY_TRANSCRIPT_EXPECTED_RED
$env:GHOZTTY_TRANSCRIPT_EXPECTED_RED = 'ipc-floor-setup negative control'
$preservedBefore = @(Get-ChildItem $env:TEMP -Filter 'ghoztty-ipc-p2-fail-*.log' -ErrorAction SilentlyContinue |
    ForEach-Object { $_.Name })
try {
    # Streams apart, not `*>` (T883): the run under test tees its whole body to
    # STDOUT, which is the half this section reads back, and a merged redirect is
    # the very habit section A is about. Its stderr is discarded rather than
    # kept - a floor script writes nothing there, and a second capture file
    # would be one more merged-stream site for the T883 sweep to count.
    & powershell -NoProfile -File (Join-Path $PSScriptRoot 'ipc-p2.ps1') -Exe $Exe > $log 2> $null
    $code = $LASTEXITCODE
} finally {
    if ($null -eq $prev) { Remove-Item Env:GHOZTTY_IPC_TIMEOUT_MS -ErrorAction SilentlyContinue }
    else { $env:GHOZTTY_IPC_TIMEOUT_MS = $prev }
    if ($null -eq $prevExpected) { Remove-Item Env:GHOZTTY_TRANSCRIPT_EXPECTED_RED -ErrorAction SilentlyContinue }
    else { $env:GHOZTTY_TRANSCRIPT_EXPECTED_RED = $prevExpected }
}
$preservedNew = @(Get-ChildItem $env:TEMP -Filter 'ghoztty-ipc-p2-fail-*.log' -ErrorAction SilentlyContinue |
    Where-Object { $preservedBefore -notcontains $_.Name } | ForEach-Object { $_.Name })
$body = if (Test-Path $log) { Get-Content $log -Raw } else { '' }
$verdict = @(($body -split "`r?`n") | Where-Object { $_ -match 'P2 ACCEPTANCE:' }) | Select-Object -Last 1
$setupLines = @([regex]::Matches($body, '(?m)^\s*FAIL SETUP:'))
$failLines = @([regex]::Matches($body, '(?m)^\s*FAIL '))
Assert "B1 the run is red" ($code -ne 0)
Assert "B2 exactly one setup failure" ($setupLines.Count -eq 1)
Assert "B3 no cascade of product failures behind it" ($failLines.Count -eq 1)
Assert "B4 the failure names the verb it could not complete" ($body -match '(?m)^\s+verb:\s+ghoztty \+')
Assert "B5 the failure carries the CLI's own words" (
    $body -match 'Timed out after' -or $body -match 'Waiting for Ghoztty to answer')
Assert "B6 the run says why it stopped early" ($body -match 'run stopped after the setup failure')
Assert "B7 a give-up is what it named, not a still-waiting notice" ($body -match 'Timed out after')
# T1475: the one line a `-Last 1` reader keeps names the fixture and the verb.
Assert "B8 the verdict line itself names the setup failure" (
    "$verdict" -match 'FAILURE\(S\) \(0 assertions passed\) - setup failed: the p2ide fixture window .*\(ghoztty \+new-window --target=p2ide: exit')
"    verdict was: $verdict"
Assert "B9 an expected red says so instead of filing evidence" ("$verdict" -match 'not preserved: expected red \(ipc-floor-setup negative control\)')
Assert "B10 and no ipc-p2 failure transcript was preserved for it" ($preservedNew.Count -eq 0)
Remove-Item $log -Force -ErrorAction SilentlyContinue

"== C: a SLOW call is a pass with a note; a GAVE-UP call is still a failure"
# Need-Ghoz resolves `Invoke-OnTestDesktop` at call time, so a probe that
# defines its own gets canned CLI answers with no app, no desktop and no
# timing. It runs in a child process because Need-Ghoz scores into
# $script:failures, which in this scope is THIS script's verdict.
$probe = Join-Path $env:TEMP "ghoztty-floor-slow-probe-$PID.ps1"
$probeSrc = @'
param([Parameter(Mandatory = $true)][string]$Fixture,
      [Parameter(Mandatory = $true)][string]$Mode)
$ErrorActionPreference = 'Continue'
$script:failures = 0
. $Fixture
$notice = "Waiting for Ghoztty to answer '+new-window' (the app may still be starting up)...`n"
$gaveUp = "Timed out after 30000ms trying to get a response from Ghoztty for '+new-window'.`n"
function Invoke-OnTestDesktop {
    param([string]$Exe, [string[]]$Arguments, [string]$WorkingDirectory,
          [int]$TimeoutSec = 60, [switch]$KeepWindowPlacement,
          [switch]$AllowReleaseBuild, $Desktop)
    switch ($Mode) {
        'slow'    { return [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = $notice; Output = $notice; Pid = 0; TimedOut = $false } }
        'gaveup'  { return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = $gaveUp; Output = $gaveUp; Pid = 0; TimedOut = $false } }
        'silent'  { return [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = ''; Output = ''; Pid = 0; TimedOut = $false } }
        'harness' { return [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = ''; Output = ''; Pid = 0; TimedOut = $true } }
    }
}
$outcome = 'returned'
$body = Invoke-FloorBody {
    try { [void](Need-Ghoz -What 'the probe fixture window' -GhozArgs @('+new-window', '--target=probe') -Exe 'probe.exe') }
    catch { $script:outcome = 'stopped'; throw }
}
"OUTCOME: $outcome"
"FAILURES: $script:failures"
"BODY: $(($body -join ' | ').Trim())"
'@
Set-Content -LiteralPath $probe -Value $probeSrc -Encoding ASCII
$fixture = Join-Path $PSScriptRoot 'lib\FloorFixture.ps1'
$probeOut = @{}
foreach ($mode in 'slow', 'gaveup', 'silent', 'harness') {
    $probeOut[$mode] = (& powershell -NoProfile -File $probe -Fixture $fixture -Mode $mode) -join "`n"
}
Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue

Assert "C1 a slow-then-successful call does not stop the run" (
    $probeOut['slow'] -match 'OUTCOME: returned')
Assert "C2 and does not score a failure" ($probeOut['slow'] -match 'FAILURES: 0')
Assert "C3 but it is recorded, with how long it took" (
    $probeOut['slow'] -match 'NOTE SLOW SETUP: the probe fixture window answered after \d+ms')
Assert "C4 a gave-up call still stops the run" ($probeOut['gaveup'] -match 'OUTCOME: stopped')
Assert "C5 and still scores exactly one failure" ($probeOut['gaveup'] -match 'FAILURES: 1')
Assert "C6 naming the app, not the verb's caller" (
    $probeOut['gaveup'] -match 'FAIL SETUP: the probe fixture window - the app under test stopped answering IPC')
Assert "C7 a harness timeout is still a failure" (
    $probeOut['harness'] -match 'OUTCOME: stopped' -and $probeOut['harness'] -match 'FAILURES: 1')
Assert "C8 an ordinary quiet call passes with no note" (
    $probeOut['silent'] -match 'OUTCOME: returned' -and
    $probeOut['silent'] -match 'FAILURES: 0' -and
    $probeOut['silent'] -notmatch 'NOTE SLOW SETUP')

"== D: one cold +list cannot spend the whole poll (T1677)"
# Every floor script used to poll +list for 20s while ONE +list is allowed the
# CLI's 30s bound, so a single cold call could outlast the wait and the run
# reported a fixture "missing" from an app that was coming up fine. Scaled down
# so it runs in seconds: the CLI bound is 3s (GHOZTTY_IPC_TIMEOUT_MS, read the
# way the CLI reads it), the poll window 1s, and the canned +list's FIRST call
# takes 2.5s and answers without the fixture, every later one with it. D1 is the
# negative control: the old loop, verbatim, over the same canned answers, must
# miss - otherwise D2 proves nothing about the change.
$lprobe = Join-Path $env:TEMP "ghoztty-floor-list-probe-$PID.ps1"
$lprobeSrc = @'
param([Parameter(Mandatory = $true)][string]$Fixture,
      [Parameter(Mandatory = $true)][string]$Mode)
$ErrorActionPreference = 'Continue'
. $Fixture
if ($Mode -eq 'resolve') {
    "DEFAULT: $script:FloorIpcDefaultMs"
    foreach ($v in @('<unset>', '', 'soon', '-1', '12.5', '0', '1500', ' 2000 ')) {
        if ($v -eq '<unset>') { Remove-Item Env:GHOZTTY_IPC_TIMEOUT_MS -ErrorAction SilentlyContinue }
        else { $env:GHOZTTY_IPC_TIMEOUT_MS = $v }
        "RESOLVE [$v] = $(Get-FloorIpcCallBoundMs)"
    }
    return
}
$env:GHOZTTY_IPC_TIMEOUT_MS = '3000'
$script:calls = 0
$fake = {
    $script:calls++
    if ($Mode -eq 'never') { return 'no windows' }
    if ($Mode -eq 'warm' -or $script:calls -gt 1) { return 'win 1 [target: probe]' }
    Start-Sleep -Milliseconds 2500
    return 'no windows'
}
$sw = [Diagnostics.Stopwatch]::StartNew()
if ($Mode -eq 'legacy') {
    $deadline = (Get-Date).AddSeconds(1)
    do {
        $l = & $fake
        if ($l -match '\[target: probe\]') { break }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
} else {
    $l = Wait-FloorListMatch -Pattern '\[target: probe\]' -TimeoutSec 1 -GetList $fake
}
"MATCH: $("$l" -match '\[target: probe\]')"
"MS: $($sw.ElapsedMilliseconds)"
"CALLS: $script:calls"
"NOTES: $(($script:FloorSetupNotes -join ' | ').Trim())"
'@
Set-Content -LiteralPath $lprobe -Value $lprobeSrc -Encoding ASCII
$lout = @{}
foreach ($mode in 'legacy', 'cold', 'never', 'warm', 'resolve') {
    $lout[$mode] = (& powershell -NoProfile -File $lprobe -Fixture $fixture -Mode $mode) -join "`n"
}
Remove-Item -LiteralPath $lprobe -Force -ErrorAction SilentlyContinue
foreach ($mode in 'legacy', 'cold', 'never', 'warm') { "    ${mode}: $($lout[$mode] -replace "`n", '; ')" }

Assert "D1 negative control: the old 20s-style loop misses when one call outlasts it" (
    $lout['legacy'] -match 'MATCH: False' -and $lout['legacy'] -match 'CALLS: 1')
Assert "D2 the shared poll still finds a fixture after one call spent the whole window" (
    $lout['cold'] -match 'MATCH: True' -and $lout['cold'] -match 'CALLS: 2')
Assert "D3 and says the state was slow to settle" (
    $lout['cold'] -match 'NOTE SLOW STATE: \+list showing .* settled after \d+ms')
$neverMs = if ($lout['never'] -match 'MS: (\d+)') { [int]$Matches[1] } else { -1 }
Assert "D4 a fixture that never shows is still a miss, bounded by window + one call's bound (${neverMs}ms)" (
    $lout['never'] -match 'MATCH: False' -and $neverMs -ge 4000 -and $neverMs -lt 8000)
Assert "D5 a warm first-call match returns at once with no note" (
    $lout['warm'] -match 'MATCH: True' -and $lout['warm'] -match 'CALLS: 1' -and
    $lout['warm'] -match 'NOTES: $' -and $lout['warm'] -notmatch 'NOTE SLOW')
Assert "D6 the bound resolves the way the CLI's resolve() does" (
    $lout['resolve'] -match 'RESOLVE \[<unset>\] = 30000' -and
    $lout['resolve'] -match 'RESOLVE \[\] = 30000' -and
    $lout['resolve'] -match 'RESOLVE \[soon\] = 30000' -and
    $lout['resolve'] -match 'RESOLVE \[-1\] = 30000' -and
    $lout['resolve'] -match 'RESOLVE \[12\.5\] = 30000' -and
    $lout['resolve'] -match 'RESOLVE \[0\] = 0' -and
    $lout['resolve'] -match 'RESOLVE \[1500\] = 1500' -and
    $lout['resolve'] -match 'RESOLVE \[ 2000 \] = 2000')
$zigSrc = Get-Content -Raw (Join-Path $PSScriptRoot '..\..\src\os\ipc_timeout.zig')
$zigDefault = if ($zigSrc -match 'pub const default_ms: u32 = ([\d_]+);') { [int]($Matches[1] -replace '_', '') } else { -1 }
Assert "D7 the fixture's default is the CLI's default_ms ($zigDefault)" (
    $zigDefault -gt 0 -and $lout['resolve'] -match "DEFAULT: $zigDefault(`n|$)")

"== E: a setup failure says what the APP was doing (T1769)"
# The 2026-09-26 P1 flake waited 30s and the block could only say "timed out".
# Each of the four shapes the snapshot names is CONSTRUCTED here - a path
# nothing runs from, this very powershell.exe (a live process with no pipe),
# and a pipe this section opens itself - so every verdict is shown reachable,
# not just the one a healthy box happens to produce.
. $fixture
$self = (Get-Process -Id $PID).Path
$ghost = Join-Path $env:TEMP "ghoztty-floor-noexe-$PID\ghoztty.exe"
$pipeName = "ghoztty-floorsetup-snap-$PID"
$noPipe = "ghoztty-floorsetup-nopipe-$PID"
$snapLog = Join-Path $env:TEMP "ghoztty-floor-snap-$PID.log"
Set-Content -LiteralPath $snapLog -Value @('info(app): early line', "info(app): SNAPMARK-$PID last line") -Encoding ASCII
$e1 = Get-FloorAppSnapshot -Exe $ghost -PipeName $noPipe -LogPath $snapLog
$e2 = Get-FloorAppSnapshot -Exe $self -PipeName $noPipe -LogPath "$snapLog.missing"
$server = $null
try {
    $server = New-Object System.IO.Pipes.NamedPipeServerStream($pipeName)
    $e3 = Get-FloorAppSnapshot -Exe $self -PipeName $pipeName
    $e4 = Get-FloorAppSnapshot -Exe $ghost -PipeName $pipeName
    $e5 = Get-FloorAppSnapshot -Exe $self -PipeName $pipeName -ExcludePid @($PID) -MaxProcs 100000
} finally {
    if ($server) { $server.Dispose() }
}
Remove-Item -LiteralPath $snapLog -Force -ErrorAction SilentlyContinue
foreach ($n in 'e1', 'e2', 'e3', 'e4') { "    ${n}: $((Get-Variable $n -ValueOnly).Lines -join ' ; ')" }
Assert "E1 nothing running and no pipe reads as NO APP" (
    $e1.Verdict -eq 'never-started-or-exited' -and ($e1.Lines -join "`n") -match 'app verdict: NO APP' -and
    ($e1.Lines -join "`n") -match 'app state: 0 process')
Assert "E2 a live process with no pipe reads as STARTING OR STUCK, with its pid" (
    $e2.Verdict -eq 'running-no-pipe' -and ($e2.Lines -join "`n") -match "pid \d+ \(parent \d+\) up [\d.,]+s, cpu")
$e2rows = @($e2.Lines | Where-Object { $_ -match '^\s+pid \d+ \(parent' }).Count
$e2all = if (($e2.Lines -join "`n") -match 'app state: (\d+) process') { [int]$Matches[1] } else { -1 }
Assert "E2b a crowd of processes is capped to the youngest few, and the rest counted ($e2rows of $e2all shown)" (
    $e2all -gt 4 -and $e2rows -eq 4 -and ($e2.Lines -join "`n") -match "\(\+$($e2all - 4) older not shown\)")
Assert "E3 a live process whose pipe exists reads as UP BUT SILENT" (
    $e3.Verdict -eq 'running-not-answering' -and ($e3.Lines -join "`n") -match "pipe\\$pipeName EXISTS")
Assert "E4 a pipe with no process from the exe reads as FOREIGN PIPE" ($e4.Verdict -eq 'pipe-without-process')
Assert "E5 the CLI's own pid is left out of the count" (($e5.Lines -join "`n") -notmatch "pid $PID ")
Assert "E6 the app log's tail is quoted" (($e1.Lines -join "`n") -match "\| info\(app\): SNAPMARK-$PID last line")
Assert "E7 a missing app log is named as missing, not skipped" (($e2.Lines -join "`n") -match 'app log: .* does not exist')
Assert "E8 a failed fixture call carries the snapshot in its evidence" (
    $probeOut['gaveup'] -match 'app verdict: NO APP' -and $probeOut['gaveup'] -match 'app pipe:')
Assert "E9 a slow-but-successful call does not pay for one" ($probeOut['slow'] -notmatch 'app state:')

"== teardown"
Reset-GhozttyTestState -Exe $Exe -SettleMs 500 | Out-Null
Remove-TestDesktop | Out-Null

} 2>&1 | Tee-Object -FilePath $transcript

""
# A clean green run stamps the covered files (T783), so `guard-due.ps1` can
# answer "has this been run against the floor as it now stands?" after a pull
# brings in somebody else's edit to it.
Complete-TestBody
if ($script:failures -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $PSScriptRoot '..\..\scripts\guard-due.ps1') `
        update -Guard ipc-floor-setup 2>&1 | ForEach-Object { "  $_" }
}
exit (Complete-TestTranscript -Name 'ipc-floor-setup' -Path $transcript `
        -Label 'IPC FLOOR SETUP' -Pass $script:passes -Fail $script:failures).Code
