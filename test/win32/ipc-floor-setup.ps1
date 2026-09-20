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
}
$body = if (Test-Path $log) { Get-Content $log -Raw } else { '' }
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
