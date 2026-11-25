<#
.SYNOPSIS
    T2179 acceptance - a fixed sleep standing in for a handshake can only get
    rarer in test\win32: a new one fails, and an excuse has to give a reason.

.DESCRIPTION
    THE DEFECT (T1164, T1228): a bare `Start-Sleep` that means "by now the
    other thing has happened" passes on an idle box and goes red only when the
    box is busy. T1228's census (2026-10-22) found 2006 of them; a month later
    there were 2741. Too many to convert in one context, so the gate comes
    first: the analyzer in `lib\SleepAudit.ps1` (its header has the classes)
    sorts every sleep into poll / settle / bare, and the bare count per file is
    a ratchet that may only fall.

    Sections:

      A. The classifier against fixtures, BOTH directions: a sleep in a
         while / do / for / foreach body is a poll, and so is one inside a
         script block handed to a wait helper (Wait-*, *-Until); a bare one is
         bare, `sleep` is the same command, a `# settle: <reason>` on the line
         or the line above makes it a settle, a `# settle:` with no reason is
         `settle-unreasoned`, a loop beats a marker, and a file that does not
         parse is reported rather than skipped.

      B. The census against T1228's, on the tree T1228 counted (ee8597405, read
         with `git archive`): 3287 sites, 1281 in loops, 2006 bare. So the
         numbers the ratchet holds are the numbers T1228 measured, not a new
         definition.

      C. The ratchet. The bare sites present on 2026-11-24 are a per-file count
         in `sleep-handshake-audit.baseline.json`. A file ABOVE its count
         fails, a file BELOW it fails naming `-UpdateBaseline`, and a new file
         with a bare sleep fails - a new harness starts at zero. A
         `settle-unreasoned` marker anywhere fails, and so does a file that
         does not parse.

      D. Scope: the sweep walked the whole tree and says how much.

      T. Teeth, every run: a planted bare sleep and a planted reasonless
         `# settle:` under a swept tree are each flagged AND fail the gate.

    `-NegativeControl` adds the inverted assertions (the planted sleep and the
    planted marker each go unreported), so a healthy sweep scores exactly
    2 FAILURES and never stamps.

    `-UpdateBaseline` rewrites the baseline from the current sweep. Use it in
    the commit that converts a site, never to make a red run go green.

    One ALL PASS / N FAILURE(S) line last, per the house convention.

.NOTES
    # persistence: launches no GUI - this reads source files, and section B
    # extracts an old tree with git archive + tar into temp.
    # isolation: none - this script never runs a ghoztty verb; the sleeps here are fixture text for the analyzer
#>
[CmdletBinding()]
param(
    [switch]$UpdateBaseline,
    [switch]$NegativeControl
)

$ErrorActionPreference = 'Continue'
$Repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\SleepAudit.ps1')

$script:pass = 0
$script:fail = 0
function Assert([string]$name, [bool]$cond) {
    if ($cond) { Write-Host "  PASS $name"; $script:pass++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:fail++ }
}
function AssertEq([string]$name, $expected, $actual) {
    if ($expected -eq $actual) { Write-Host "  PASS $name"; $script:pass++ }
    else {
        Write-Host "  FAIL $name (expected '$expected', got '$actual')" -ForegroundColor Red
        $script:fail++
    }
}

$tmp = Join-Path $env:TEMP "ghoztty-t2179-$PID"
if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force $tmp | Out-Null

$Root = Join-Path $Repo 'test\win32'
$BaselinePath = Join-Path $PSScriptRoot 'sleep-handshake-audit.baseline.json'

# `return ,` so a one-site result stays an array: a lone pscustomobject has a
# $null .Count under 5.1, which read as zero sites.
function Fixture([string]$Body) {
    return , @(Get-SleepAuditSites -Path 'fixture.ps1' -Text ($Body -split "`n"))
}
function Classes($Sites) { return (@($Sites | ForEach-Object { $_.Class }) -join ',') }

# ===========================================================================
Write-Host ''
Write-Host '== A: the classifier, both directions'
# ===========================================================================

$f = Fixture @'
while (-not (Test-Path $x)) { Start-Sleep -Milliseconds 100 }
do { Start-Sleep 1 } until ($done)
for ($i = 0; $i -lt 5; $i++) { if ($i) { Start-Sleep -Seconds 1 } }
foreach ($p in $panes) { Start-Sleep -Milliseconds 50 }
'@
AssertEq 'A1 a sleep in a while / do / for / foreach body is a poll, however deep' 'poll,poll,poll,poll' (Classes $f)

$f = Fixture @'
Wait-Until { Start-Sleep -Milliseconds 50; Test-Path $x } -TimeoutMs 5000
Invoke-WithRetry -Body { Start-Sleep 1; Get-Thing }
'@
AssertEq 'A2 a sleep inside a script block handed to a wait helper is a poll' 'poll,poll' (Classes $f)
Assert 'A2b and says it was the helper, not a loop' (@($f | Where-Object { $_.Poll -eq 'helper' }).Count -eq 2)

$f = Fixture @'
& $exe +new-window --name=x
Start-Sleep -Seconds 3
sleep 2
Invoke-Command { Start-Sleep 1 }
'@
AssertEq 'A3 a sleep after an action, `sleep`, and a block handed to a non-wait command are bare' 'bare,bare,bare' (Classes $f)

$f = Fixture @'
# settle: the banner's collapse debounce is 750ms and the debounce IS the subject
Start-Sleep -Milliseconds 900
Start-Sleep -Milliseconds 300  # settle: below the 400ms coalesce window on purpose
'@
AssertEq 'A4 a stated reason on the line or the line above makes a settle' 'settle,settle' (Classes $f)

$f = Fixture @'
# settle:
Start-Sleep -Seconds 2
Start-Sleep 1 # settle:
'@
AssertEq 'A5 a marker with no reason is settle-unreasoned - it excuses nothing' 'settle-unreasoned,settle-unreasoned' (Classes $f)

$f = Fixture @'
Start-Sleep 1
# settle: about the line below, not the one two lines down
x
Start-Sleep 1
'@
AssertEq 'A6 a marker reaches its own line and the next, no further' 'bare,bare' (Classes $f)

$f = Fixture @'
while ($true) {
    # settle:
    Start-Sleep 1
}
'@
AssertEq 'A7 inside a loop the sleep is a poll, whatever marker it carries' 'poll' (Classes $f)

$f = Fixture 'function Broken( {'
Assert 'A8 a file that does not parse is reported, not skipped' ($f.Count -eq 1 -and $f[0].Class -eq 'parse-error')

$f = Fixture @'
Start-Sleeper 1
$sleep = 3
Write-Host "Start-Sleep 5"
'@
AssertEq 'A9 a different command, a variable and a string are not sleeps' 0 $f.Count

$c = Get-SleepAuditCensus @(
    [pscustomobject]@{ Class = 'poll'; Poll = 'loop' }, [pscustomobject]@{ Class = 'poll'; Poll = 'helper' },
    [pscustomobject]@{ Class = 'bare'; Poll = '' }, [pscustomobject]@{ Class = 'settle'; Poll = '' },
    [pscustomobject]@{ Class = 'settle-unreasoned'; Poll = '' }, [pscustomobject]@{ Class = 'parse-error'; Poll = '' })
Assert "A10 the census adds up (total $($c.Total), poll $($c.Poll) = loop $($c.LoopOnly) + helper $($c.Helper))" (
    $c.Total -eq 5 -and $c.Poll -eq 2 -and $c.LoopOnly -eq 1 -and $c.Helper -eq 1 -and $c.Bare -eq 1 -and
    $c.Settle -eq 1 -and $c.Unreasoned -eq 1 -and $c.ParseError -eq 1)

# ===========================================================================
Write-Host ''
Write-Host '== B: the census against T1228''s, on the tree it counted'
# ===========================================================================

$censusSha = 'ee8597405'
$oldRoot = Join-Path $tmp 'old'
New-Item -ItemType Directory -Force $oldRoot | Out-Null
$tar = Join-Path $tmp 'old.tar'
& git -C $Repo archive $censusSha 'test/win32' -o $tar 2>$null
# System32's tar by full path: launched from Git Bash, PATH puts MSYS tar first,
# which reads `C:\...` as host `C` and extracts nothing (B1 went red there).
$sysTar = Join-Path $env:SystemRoot 'System32\tar.exe'
if (Test-Path -LiteralPath $tar) { & $sysTar -xf $tar -C $oldRoot 2>$null }
$oldTree = Join-Path $oldRoot 'test\win32'
$oldCount = 0
if (Test-Path -LiteralPath $oldTree) { $oldCount = @(Get-ChildItem -LiteralPath $oldTree -Filter *.ps1 -File -Recurse).Count }
Assert "B1 test\win32 at $censusSha (T1228's census, 2026-10-22 22:14) was extracted ($oldCount .ps1 files)" ($oldCount -ge 300)
if ($oldCount -gt 0) {
    $oc = Get-SleepAuditCensus @(Get-SleepAuditSweep -Roots @($oldTree))
    AssertEq 'B2 every Start-Sleep site T1228 counted is found' 3287 $oc.Total
    AssertEq 'B3 the loop rule alone gives T1228''s poll count' 1281 $oc.LoopOnly
    AssertEq 'B4 and the bare count is T1228''s handshake candidates (no helper polls or settles then)' 2006 $oc.Bare
}

# ===========================================================================
Write-Host ''
Write-Host '== C: the ratchet over test\win32'
# ===========================================================================

$all = @(Get-SleepAuditSweep -Roots @($Root))
$census = Get-SleepAuditCensus $all
$current = @{}
foreach ($x in @($all | Where-Object { $_.Class -eq 'bare' })) {
    $rel = Get-SleepAuditRelativePath -Path $x.Path -Repo $Repo
    if (-not $current.ContainsKey($rel)) { $current[$rel] = 0 }
    $current[$rel] = $current[$rel] + 1
}

if ($UpdateBaseline) {
    $obj = [ordered]@{
        note      = 'Per-file counts of bare Start-Sleep sites in test\win32 (outside any loop or wait-helper block, with no "# settle: <reason>"): fixed sleeps standing in for a handshake, which pass on an idle box and go red on a busy one (T1164, T1228). Recorded 2026-11-24 by T2179; worked down by T2180/T2181, converting each to a wait on the condition it stands for. May only go DOWN. See docs/design/windows-parity-tasks/T2179.md.'
        generated = (Get-Date -Format 'yyyy-MM-dd')
        files     = [ordered]@{}
    }
    foreach ($k in ($current.Keys | Sort-Object)) { $obj.files[$k] = $current[$k] }
    $json = ($obj | ConvertTo-Json -Depth 5)
    [System.IO.File]::WriteAllText($BaselinePath, $json + "`n", (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "  baseline rewritten: $($current.Keys.Count) file(s), $($census.Bare) bare site(s)"
}

Assert 'C0 the baseline exists' (Test-Path -LiteralPath $BaselinePath)
$baseFiles = @{}
if (Test-Path -LiteralPath $BaselinePath) {
    $base = Get-Content -LiteralPath $BaselinePath -Raw | ConvertFrom-Json
    foreach ($p in $base.files.PSObject.Properties) { $baseFiles[$p.Name] = [int]$p.Value }
}

$cmp = Compare-SleepAuditBaseline -Current $current -Baseline $baseFiles
foreach ($r in $cmp.Regressed) { Write-Host "      NEW: $r" -ForegroundColor Red }
if (@($cmp.Regressed).Count -gt 0) {
    Write-Host '        -> wait on the condition the sleep stands for (a Wait-* helper or an until-loop),'
    Write-Host '           or, when the product''s own timer IS the subject: # settle: <reason>'
}
AssertEq 'C1 no file has gained a bare sleep' 0 @($cmp.Regressed).Count
foreach ($i in $cmp.Improved) { Write-Host "      CONVERTED: $i" }
Assert 'C2 the baseline matches the tree (-UpdateBaseline in the commit that converts a site)' (
    @($cmp.Improved).Count -eq 0)
$unreasoned = @($all | Where-Object { $_.Class -eq 'settle-unreasoned' })
foreach ($x in $unreasoned) { Write-Host "      $(Get-SleepAuditRelativePath $x.Path $Repo):$($x.Line) # settle: with no reason" -ForegroundColor Red }
AssertEq 'C3 every # settle: marker gives its reason' 0 $unreasoned.Count
$parse = @($all | Where-Object { $_.Class -eq 'parse-error' })
foreach ($x in $parse) { Write-Host "      $(Get-SleepAuditRelativePath $x.Path $Repo):$($x.Line) $($x.Detail)" -ForegroundColor Red }
AssertEq 'C4 nothing in the tree fails to parse' 0 $parse.Count

# ===========================================================================
Write-Host ''
Write-Host '== D: scope'
# ===========================================================================

$ps1Count = @(Get-ChildItem -LiteralPath $Root -Filter *.ps1 -File -Recurse).Count
$libCount = @(Get-ChildItem -LiteralPath (Join-Path $Root 'lib') -Filter *.ps1 -File).Count
Assert "D1 the sweep walked test\win32 ($ps1Count .ps1 files, $libCount of them in lib\)" (
    $ps1Count -ge 300 -and $libCount -ge 20)
Assert "D2 and it had something to read: $($census.Total) sleep site(s)" ($census.Total -ge 1000)

# ===========================================================================
Write-Host ''
Write-Host '== T: the teeth (C1 and C3 must be able to score red)'
# ===========================================================================

$fakeRoot = Join-Path $tmp 'plant\test\win32'
New-Item -ItemType Directory -Force $fakeRoot | Out-Null
Set-Content -LiteralPath (Join-Path $fakeRoot 'planted-sleep.ps1') -Encoding ascii -Value @(
    '& $exe +new-window --name=planted',
    'Start-Sleep -Seconds 3',
    '# settle:',
    'Start-Sleep -Milliseconds 500')
$planted = @(Get-SleepAuditSweep -Roots @($fakeRoot))
$plantBare = @($planted | Where-Object { $_.Class -eq 'bare' })
$plantEmpty = @($planted | Where-Object { $_.Class -eq 'settle-unreasoned' })
Assert 'T1 a bare sleep planted in a scratch file under a swept tree is flagged' ($plantBare.Count -eq 1)
Assert 'T2 and so is a planted # settle: with no reason' ($plantEmpty.Count -eq 1)
$withPlant = @{}
foreach ($k in $current.Keys) { $withPlant[$k] = $current[$k] }
$withPlant['test\win32\planted-sleep.ps1'] = $plantBare.Count
$cmpT = Compare-SleepAuditBaseline -Current $withPlant -Baseline $baseFiles
Assert 'T3 and the ratchet fails on it - a new harness starts at zero' (
    @($cmpT.Regressed | Where-Object { $_ -like 'test\win32\planted-sleep.ps1 *' }).Count -eq 1)
$oneMore = @{}
foreach ($k in $current.Keys) { $oneMore[$k] = $current[$k] }
$anyKey = @($baseFiles.Keys | Sort-Object)[0]
if ($anyKey) { $oneMore[$anyKey] = $baseFiles[$anyKey] + 1 }
$cmpU = Compare-SleepAuditBaseline -Current $oneMore -Baseline $baseFiles
Assert "T4 and one more bare sleep in a baselined file fails too ($anyKey)" (
    $anyKey -and @($cmpU.Regressed | Where-Object { $_ -like "$anyKey *" }).Count -eq 1)

if ($NegativeControl) {
    Write-Host ''
    Write-Host 'NEGATIVE CONTROL: asserting the planted sleep and marker go unreported - a working sweep MUST fail both'
    Assert 'N1 the planted bare sleep goes unreported (inverted)' ($plantBare.Count -eq 0)
    Assert 'N2 the planted reasonless # settle: goes unreported (inverted)' ($plantEmpty.Count -eq 0)
}

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

Complete-TestBody  # T1039: the run reached the end of its body

# --- stamp (T783) ----------------------------------------------------------
if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard sleep-handshake -Repo $Repo 2>&1 |
        ForEach-Object { Write-Host "  $($_.ToString())" }
}

Write-Host ''
Write-Host "  sweep: $ps1Count script(s); $($census.Total) sleep(s) = $($census.Poll) poll ($($census.LoopOnly) loop, $($census.Helper) helper) + $($census.Settle) settle + $($census.Bare) bare across $($current.Keys.Count) file(s)"
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Label 'SLEEP HANDSHAKE AUDIT' -MinPass 20
