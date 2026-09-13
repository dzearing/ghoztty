# job-teardown acceptance (T1517): a harness's cleanup finishes in bounded
# time, and no relay job in this suite can park where a stop cannot reach it.
#
#   powershell -NoProfile -File test\win32\job-teardown.ps1
#
# Non-interactive. Launches no Ghoztty and touches no user state: the subject is
# the HARNESS, so this runs small fixtures of its own on loopback ports and then
# reads .ps1 text.
#
# WHY IT EXISTS. `relay-account.ps1` reached its LAST assertion and then stopped
# dead in its top-level `finally`: 25+ minutes with the output file frozen and
# the process at 4.64 seconds of CPU, killed by hand in the end. Everything the
# run measured was thrown away, because a run that never returns has no verdict
# and no exit code - and on this box it held the per-user pipe against every
# script queued behind it. A wedged harness is worse than a red one: red is an
# answer.
#
# A: the mechanism is real - `Stop-Job` against a job parked in a blocking
#    `AcceptTcpClient()` does not return, and `Stop-JobBounded` ends the same
#    job anyway, inside its cap.
# B: the shipped shape - a `Pending()`-polling relay job - stops promptly and is
#    reaped.
# C: the give-up path is bounded and SAYS SO rather than blocking, which is the
#    only honest behaviour when nothing can be killed by pid.
# D: the sweep - no `Start-Job` body in test\win32 blocks in `AcceptTcpClient()`
#    without a `Pending()` guard.
#
# `-TeethCheck` proves section D can go red at all: it plants a violator in a
# temp copy of the swept text and passes only if the assertion turns over.
param([switch]$TeethCheck)

$ErrorActionPreference = 'Continue'

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\JobTeardown.ps1')

$script:failures = 0
$script:passes = 0
$Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ } else { "  FAIL $name"; $script:failures++ }
}

$tmp = Join-Path $env:TEMP "ghoztty-job-teardown-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

# A free loopback port, taken fresh each time so a re-run cannot collide with a
# listener the previous run leaked.
function Get-FreePort {
    $l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $l.Start(); $p = $l.LocalEndpoint.Port; $l.Stop(); return $p
}

# Start a listener job in one of the two shapes, writing its pid where the
# teardown helper looks for it.
#   blocking - the defect: parked inside AcceptTcpClient()
#   polling  - the fix: Pending() + Start-Sleep, interruptible every 25ms
function Start-Listener([ValidateSet('blocking', 'polling')][string]$Shape, [int]$Port, [string]$PidFile) {
    Remove-Item $PidFile -ErrorAction SilentlyContinue
    $job = Start-Job -ScriptBlock {
        param($port, $pidFile, $shape)
        Set-Content -Path $pidFile -Value $PID
        $l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port)
        $l.Start()
        try {
            while ($true) {
                if ($shape -eq 'polling' -and -not $l.Pending()) { Start-Sleep -Milliseconds 25; continue }
                $c = $l.AcceptTcpClient()
                $c.Close()
            }
        } finally { $l.Stop() }
    } -ArgumentList $Port, $PidFile, $Shape
    # Wait for the pid file: until the job is actually running its body, a
    # teardown measurement is timing the scheduler, not the stop.
    foreach ($i in 1..100) {
        if (Test-Path $PidFile) { break }
        Start-Sleep -Milliseconds 100
    }
    return $job
}

try {

# ============================================================================
"== A: Stop-Job cannot stop a job parked in AcceptTcpClient(); Stop-JobBounded can"
# ============================================================================
# The bare Stop-Job is measured in a CHILD powershell, because measuring it in
# this one is precisely the hang under test - the child can be abandoned, this
# process cannot.
$fixture = Join-Path $tmp 'stopjob-fixture.ps1'
Set-Content -Encoding ASCII -Path $fixture -Value @'
param([int]$Port)
$j = Start-Job -ScriptBlock {
    param($port)
    $l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port)
    $l.Start()
    while ($true) { $c = $l.AcceptTcpClient(); $c.Close() }
} -ArgumentList $Port
Start-Sleep -Seconds 3
"state=$($j.State)"
Stop-Job $j -ErrorAction SilentlyContinue
"stop-job returned"
'@
$fxOut = Join-Path $tmp 'stopjob-fixture.out'
$fxPort = Get-FreePort
$p = Start-Process powershell -PassThru -WindowStyle Hidden -RedirectStandardOutput $fxOut `
    -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $fixture, '-Port', $fxPort
$null = $p.Handle   # cache it or ExitCode reads empty later (the T217 trap)
$exited = $p.WaitForExit(12000)
if (-not $exited) { $p.Kill(); $null = $p.WaitForExit(5000) }
$fxText = if (Test-Path $fxOut) { Get-Content $fxOut -Raw } else { '' }
Assert "A the fixture's job really was running (negative control)" ($fxText -match 'state=Running')
Assert "A a bare Stop-Job never returns over a blocking accept" (
    -not $exited -and $fxText -notmatch 'stop-job returned')
# The fixture's own job child outlives the killed fixture, so end it by the
# port it is holding - this audit must not leak the listener it just
# demonstrated.
Get-NetTCPConnection -State Listen -LocalPort $fxPort -ErrorAction SilentlyContinue |
    ForEach-Object { Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue }

$portA = Get-FreePort
$pidA = Join-Path $tmp 'a.pid'
$jobA = Start-Listener -Shape blocking -Port $portA -PidFile $pidA
Assert "A the blocking fixture job started and recorded its pid" (
    $jobA.State -eq 'Running' -and (Test-Path $pidA))
$sw = [Diagnostics.Stopwatch]::StartNew()
$okA = Stop-JobBounded -Job $jobA -PidFile $pidA -TimeoutSec 10 -Label 'blocking fixture'
$sw.Stop()
Assert "A Stop-JobBounded ends the blocking job it could not politely stop" $okA
Assert "A and does it inside the cap (took $([math]::Round($sw.Elapsed.TotalSeconds, 1))s)" (
    $sw.Elapsed.TotalSeconds -lt 10)
Assert "A the job is reaped, not merely stopped" (
    $null -eq (Get-Job -Id $jobA.Id -ErrorAction SilentlyContinue))

# ============================================================================
""
"== B: the shipped shape - a Pending() polling relay - stops promptly"
# ============================================================================
$portB = Get-FreePort
$pidB = Join-Path $tmp 'b.pid'
$jobB = Start-Listener -Shape polling -Port $portB -PidFile $pidB
Assert "B the polling fixture job started" ($jobB.State -eq 'Running')
$sw = [Diagnostics.Stopwatch]::StartNew()
$okB = Stop-JobBounded -Job $jobB -PidFile $pidB -TimeoutSec 10 -Label 'polling fixture'
$sw.Stop()
Assert "B Stop-JobBounded reports success" $okB
Assert "B teardown took under 5s (took $([math]::Round($sw.Elapsed.TotalSeconds, 1))s)" (
    $sw.Elapsed.TotalSeconds -lt 5)
$portFree = $false
foreach ($i in 1..20) {
    try {
        $probe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $portB)
        $probe.Start(); $probe.Stop(); $portFree = $true; break
    } catch { Start-Sleep -Milliseconds 100 }
}
Assert "B the listener really went away - its port binds again" $portFree

# ============================================================================
""
"== C: with no pid to kill, teardown gives up OUT LOUD instead of blocking"
# ============================================================================
$portC = Get-FreePort
$pidC = Join-Path $tmp 'c.pid'
$jobC = Start-Listener -Shape blocking -Port $portC -PidFile $pidC
$realPid = [int](Get-Content $pidC)
# Take the pid away: the state where nothing recorded one, and the only stop
# left is the blocking one this helper refuses to make.
Remove-Item $pidC -ErrorAction SilentlyContinue
$sw = [Diagnostics.Stopwatch]::StartNew()
$outC = @(Stop-JobBounded -Job $jobC -PidFile $pidC -TimeoutSec 10 -Label 'pidless fixture' 6>&1)
$sw.Stop()
$saidSo = ($outC -join ' ') -match 'cannot end it in bounded time'
$verdictC = @($outC | Where-Object { $_ -is [bool] })
Assert "C it returns false rather than claiming the job is gone" (
    $verdictC.Count -eq 1 -and $verdictC[0] -eq $false)
Assert "C it names what it left behind" $saidSo
Assert "C and it returns immediately (took $([math]::Round($sw.Elapsed.TotalSeconds, 1))s)" (
    $sw.Elapsed.TotalSeconds -lt 5)
Stop-Process -Id $realPid -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500
Remove-Job $jobC -Force -ErrorAction SilentlyContinue

# ============================================================================
""
"== D: no Start-Job body in test\win32 blocks in AcceptTcpClient()"
# ============================================================================
# Text, not behaviour: the point is that the NEXT fake relay somebody writes
# cannot reintroduce the wedge and stay green until a run happens to hang.
function Get-BlockingAcceptFindings([string]$Text) {
    $findings = @()
    # A job body starts at `Start-Job` and, for this rule's purposes, ends at
    # the `-ArgumentList` that closes the call (every site in the suite writes
    # it that way) or at the end of the text.
    $starts = [regex]::Matches($Text, 'Start-Job')
    foreach ($m in $starts) {
        $rest = $Text.Substring($m.Index)
        $end = [regex]::Match($rest, '(?m)^\s*\}\s*-ArgumentList')
        $body = if ($end.Success) { $rest.Substring(0, $end.Index) } else { $rest }
        if ($body -match 'AcceptTcpClient\(\)' -and $body -notmatch 'Pending\(\)') {
            $findings += @{ Index = $m.Index }
        }
    }
    return , @($findings)
}

$swept = @(Get-ChildItem (Join-Path $Repo 'test\win32') -Recurse -Filter *.ps1 -File)
$offenders = @()
foreach ($f in $swept) {
    # This audit's own fixture text is the defect ON PURPOSE.
    if ($f.FullName -eq $PSCommandPath) { continue }
    $text = Get-Content $f.FullName -Raw
    if ((Get-BlockingAcceptFindings $text).Count -gt 0) {
        $offenders += $f.FullName.Substring($Repo.Length + 1)
    }
}
if ($TeethCheck) {
    # A green sweep whose red path nobody has seen is the claim this file
    # exists to distrust: plant the violator and require the analyzer to find
    # it.
    $planted = @'
$j = Start-Job -ScriptBlock {
    param($port)
    $l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port)
    $l.Start()
    while ($true) { $c = $l.AcceptTcpClient(); $c.Close() }
} -ArgumentList $port
'@
    Assert "D TEETH the analyzer flags a planted blocking accept" (
        (Get-BlockingAcceptFindings $planted).Count -eq 1)
    $guarded = $planted -replace 'while \(\$true\) \{', 'while ($true) { if (-not $l.Pending()) { Start-Sleep -Milliseconds 25; continue }'
    Assert "D TEETH and does not flag the same job once it polls" (
        (Get-BlockingAcceptFindings $guarded).Count -eq 0)
} else {
    Assert "D the sweep actually read the suite (negative control)" ($swept.Count -gt 50)
    if ($offenders.Count -gt 0) { $offenders | ForEach-Object { "       $_" } }
    Assert "D no harness parks a job in a bare AcceptTcpClient()" ($offenders.Count -eq 0)
}

Complete-TestBody  # T1039: the run reached the end of its body
} finally {
    Get-Job | Where-Object { $_.State -ne 'Running' } | Remove-Job -Force -ErrorAction SilentlyContinue
    if ($script:failures -eq 0) { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
    else { "  logs kept: $tmp" }
}

# A clean green run stamps the covered files (T783) so scripts\guard-due.ps1 can
# answer "has this rule been checked against the suite as it now stands?".
# NOT under -TeethCheck: that run scores the analyzer against planted text and
# never observes the real suite.
if ($script:failures -eq 0 -and -not $TeethCheck) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard job-teardown -Repo $Repo 2>&1 | ForEach-Object { "  $_" }
}

""
Write-TestVerdict -Label 'T1517 JOB TEARDOWN' -Pass $script:passes -Fail $script:failures
