<#
.SYNOPSIS
    T796 acceptance - every env seam an acceptance script sets is classified,
    and the shipped state it hides either runs somewhere or is a named open gap.

.DESCRIPTION
    THE DEFECT (T747):

        Every GUI section of `test\win32\relay-account.ps1` set
        GHOSTTY_GOOGLE_CLIENT_ID=cid-e2e, because a fake relay needs a fake id.
        The seam was legitimate; what it implied was not noticed. The
        configuration every real user runs - no id at all - was never once
        launched, so a Sign in button that could not work read as a fully
        tested feature for months.

    The shape generalises: a seam that makes a flow reachable also makes its
    absence invisible, and the absent case is usually the one that ships.

    What cannot be automated is the JUDGMENT. `GHOZTTY_PIPE_SUFFIX` unset is
    the user's live endpoints, which the harness is forbidden to touch;
    `GHOSTTY_GOOGLE_CLIENT_ID` unset is a dialog the user meets every day. A
    rule that flagged both would report 78 findings of which two matter, and a
    report like that is read once. So the enumeration is mechanical and the
    classification is a reviewed file - `seam-audit.registry.json`, one entry
    per seam - and what this script enforces is that the two agree.

    Four sections:

      A. The analyzer (`lib\SeamAudit.ps1`) against fixtures: a var set by a
         script AND read by the product is a seam; set-but-unread and
         read-but-unset are not; and each registry defect - unregistered,
         stale, bad class, an unset disposition outside the closed set, an
         `armed` entry with no arm, an arm naming a file or marker that does
         not exist, a `gap` naming a closed task - is reported by kind.

      B. The NEGATIVE CONTROL: the fixture tree with a correct registry yields
         NO findings. Without it section A could be passing because the
         analyzer reports everything, and the real sweep would then be noise.

      C. The real sweep over this repo: every seam the sweep finds is in the
         registry, no entry is stale, every `armed` entry's arm resolves, and
         every `gap` names an OPEN task.

      D. The ceiling: the number of `gap` entries may only fall. A gap is a
         seam whose shipped state nothing exercises - two at the 2026-09-16
         sweep (T1619, T1620). A file that is below its ceiling fails too,
         naming `-UpdateCeiling`: a ratchet nobody tightens is a wishlist.

    `-TeethCheck` proves C and D can fail: it perturbs a COPY of the registry
    (drop an entry, invent one, break an arm, add a gap) and requires each
    assertion to score red.

    One ALL PASS / N FAILURE(S) line last, per the house convention.

.NOTES
    # persistence: launches no GUI - this reads source files, it does not build
    # or run anything.
#>
[CmdletBinding()]
param(
    [switch]$TeethCheck,
    [switch]$UpdateCeiling
)

$ErrorActionPreference = 'Continue'
$Repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\SeamAudit.ps1')

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
function KindsOf($findings, [string]$seam) {
    return @(@($findings) | Where-Object { $_.Seam -eq $seam } | ForEach-Object { $_.Kind })
}

$RegistryPath = Join-Path $PSScriptRoot 'seam-audit.registry.json'

# ---------------------------------------------------------------------------
# Fixture tree: a miniature repo with the same shape (test\win32 + src +
# docs\design\windows-parity-tasks), so the analyzer is exercised on inputs
# whose right answer is known rather than on this repo's 78 real seams.
# ---------------------------------------------------------------------------
$tmp = Join-Path $env:TEMP "ghoztty-t796-$PID"
if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
New-Item -ItemType Directory -Force -Path (Join-Path $tmp 'test\win32') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $tmp 'src\apprt\win32') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $tmp 'docs\design\windows-parity-tasks') | Out-Null

Set-Content -Encoding ascii -LiteralPath (Join-Path $tmp 'test\win32\alpha.ps1') -Value @'
$env:GHOSTTY_FIXTURE_ENABLE = 'on'
$env:GHOZTTY_FIXTURE_ISOLATE = "$env:TEMP\fixture"
$env:GHOZTTY_FIXTURE_HARNESS_ONLY = '1'
if ($env:GHOZTTY_FIXTURE_READ_ONLY_HERE) { }
the unset arm marker lives here
'@
Set-Content -Encoding ascii -LiteralPath (Join-Path $tmp 'test\win32\beta.ps1') -Value @'
$env:GHOSTTY_FIXTURE_ENABLE = 'on again'
'@
Set-Content -Encoding ascii -LiteralPath (Join-Path $tmp 'src\apprt\win32\Fixture.zig') -Value @'
const a = "GHOSTTY_FIXTURE_ENABLE";
const b = "GHOZTTY_FIXTURE_ISOLATE";
const c = "GHOZTTY_FIXTURE_READ_ONLY_HERE";
const d = "GHOZTTY_FIXTURE_PRODUCT_ONLY";
'@
Set-Content -Encoding ascii -LiteralPath (Join-Path $tmp 'docs\design\windows-parity-tasks\T9001.md') -Value @'
---
id: T9001
status: "todo"
---
'@
Set-Content -Encoding ascii -LiteralPath (Join-Path $tmp 'docs\design\windows-parity-tasks\T9002.md') -Value @'
---
id: T9002
status: "done"
---
'@

function Write-FixtureRegistry([hashtable]$Seams) {
    $path = Join-Path $tmp 'registry.json'
    ([pscustomobject]@{ note = 'fixture'; gapCeiling = 0; seams = $Seams }) |
        ConvertTo-Json -Depth 6 | Set-Content -Encoding ascii -LiteralPath $path
    return (Get-SeamRegistry -Path $path)
}

# ---------------------------------------------------------------------------
"== A: the analyzer on fixtures"
# ---------------------------------------------------------------------------
$fixInv = Get-SeamInventory -Root $tmp
$fixNames = @($fixInv | ForEach-Object { $_.Name })

AssertEq 'A1 the sweep finds exactly the set-AND-read vars' 'GHOSTTY_FIXTURE_ENABLE,GHOZTTY_FIXTURE_ISOLATE' ($fixNames -join ',')
Assert 'A2 a var the harness sets but the product never reads is not a seam' ($fixNames -notcontains 'GHOZTTY_FIXTURE_HARNESS_ONLY')
Assert 'A3 a var the product reads but no script sets is not a seam' ($fixNames -notcontains 'GHOZTTY_FIXTURE_PRODUCT_ONLY')
Assert 'A4 merely READING a var in a script is not setting it' ($fixNames -notcontains 'GHOZTTY_FIXTURE_READ_ONLY_HERE')
$enable = @($fixInv | Where-Object { $_.Name -eq 'GHOSTTY_FIXTURE_ENABLE' })[0]
AssertEq 'A5 a seam carries every script that sets it' 2 (@($enable.Scripts).Count)

$good = @{
    GHOSTTY_FIXTURE_ENABLE  = [pscustomobject]@{ class = 'enable'; unset = 'armed'; unsetArm = 'test\win32\alpha.ps1::the unset arm marker lives here'; note = 'ok' }
    GHOZTTY_FIXTURE_ISOLATE = [pscustomobject]@{ class = 'isolation'; unset = 'unreachable'; note = 'ok' }
}
$clean = Test-SeamRegistry -Root $tmp -Inventory $fixInv -Registry (Write-FixtureRegistry $good)

# Each defect, one at a time, against the same fixture tree.
$missing = $good.Clone(); $missing.Remove('GHOZTTY_FIXTURE_ISOLATE')
$fMissing = Test-SeamRegistry -Root $tmp -Inventory $fixInv -Registry (Write-FixtureRegistry $missing)
AssertEq 'A6 a seam with no registry entry is unregistered' 'unregistered' ((KindsOf $fMissing 'GHOZTTY_FIXTURE_ISOLATE') -join ',')

$stale = $good.Clone(); $stale['GHOZTTY_FIXTURE_GONE'] = [pscustomobject]@{ class = 'tuning'; unset = 'shipped-elsewhere'; note = 'ok' }
$fStale = Test-SeamRegistry -Root $tmp -Inventory $fixInv -Registry (Write-FixtureRegistry $stale)
AssertEq 'A7 an entry for a seam that no longer exists is stale' 'stale' ((KindsOf $fStale 'GHOZTTY_FIXTURE_GONE') -join ',')

$badClass = $good.Clone(); $badClass['GHOZTTY_FIXTURE_ISOLATE'] = [pscustomobject]@{ class = 'convenient'; unset = 'unreachable'; note = 'ok' }
$fBadClass = Test-SeamRegistry -Root $tmp -Inventory $fixInv -Registry (Write-FixtureRegistry $badClass)
AssertEq 'A8 a class outside the closed set is reported' 'bad-class' ((KindsOf $fBadClass 'GHOZTTY_FIXTURE_ISOLATE') -join ',')

$badUnset = $good.Clone(); $badUnset['GHOZTTY_FIXTURE_ISOLATE'] = [pscustomobject]@{ class = 'isolation'; unset = 'probably-fine'; note = 'ok' }
$fBadUnset = Test-SeamRegistry -Root $tmp -Inventory $fixInv -Registry (Write-FixtureRegistry $badUnset)
AssertEq 'A9 an unset disposition outside the closed set is reported' 'bad-unset' ((KindsOf $fBadUnset 'GHOZTTY_FIXTURE_ISOLATE') -join ',')

$noArm = $good.Clone(); $noArm['GHOSTTY_FIXTURE_ENABLE'] = [pscustomobject]@{ class = 'enable'; unset = 'armed'; note = 'ok' }
$fNoArm = Test-SeamRegistry -Root $tmp -Inventory $fixInv -Registry (Write-FixtureRegistry $noArm)
AssertEq 'A10 armed with no unsetArm is missing-arm' 'missing-arm' ((KindsOf $fNoArm 'GHOSTTY_FIXTURE_ENABLE') -join ',')

$badFile = $good.Clone(); $badFile['GHOSTTY_FIXTURE_ENABLE'] = [pscustomobject]@{ class = 'enable'; unset = 'armed'; unsetArm = 'test\win32\gamma.ps1::whatever'; note = 'ok' }
$fBadFile = Test-SeamRegistry -Root $tmp -Inventory $fixInv -Registry (Write-FixtureRegistry $badFile)
AssertEq 'A11 an arm naming a script that does not exist is arm-broken' 'arm-broken' ((KindsOf $fBadFile 'GHOSTTY_FIXTURE_ENABLE') -join ',')

$badMarker = $good.Clone(); $badMarker['GHOSTTY_FIXTURE_ENABLE'] = [pscustomobject]@{ class = 'enable'; unset = 'armed'; unsetArm = 'test\win32\alpha.ps1::a sentence nobody wrote'; note = 'ok' }
$fBadMarker = Test-SeamRegistry -Root $tmp -Inventory $fixInv -Registry (Write-FixtureRegistry $badMarker)
AssertEq 'A12 an arm whose marker is gone is arm-broken' 'arm-broken' ((KindsOf $fBadMarker 'GHOSTTY_FIXTURE_ENABLE') -join ',')

$openGap = $good.Clone(); $openGap['GHOSTTY_FIXTURE_ENABLE'] = [pscustomobject]@{ class = 'enable'; unset = 'gap'; gap = 'T9001'; note = 'ok' }
$fOpenGap = Test-SeamRegistry -Root $tmp -Inventory $fixInv -Registry (Write-FixtureRegistry $openGap)
AssertEq 'A13 a gap naming an OPEN task is not a finding' 0 (@(KindsOf $fOpenGap 'GHOSTTY_FIXTURE_ENABLE').Count)

$closedGap = $good.Clone(); $closedGap['GHOSTTY_FIXTURE_ENABLE'] = [pscustomobject]@{ class = 'enable'; unset = 'gap'; gap = 'T9002'; note = 'ok' }
$fClosedGap = Test-SeamRegistry -Root $tmp -Inventory $fixInv -Registry (Write-FixtureRegistry $closedGap)
AssertEq 'A14 a gap naming a CLOSED task is reported' 'gap-closed' ((KindsOf $fClosedGap 'GHOSTTY_FIXTURE_ENABLE') -join ',')

$ghostGap = $good.Clone(); $ghostGap['GHOSTTY_FIXTURE_ENABLE'] = [pscustomobject]@{ class = 'enable'; unset = 'gap'; gap = 'T9999'; note = 'ok' }
$fGhostGap = Test-SeamRegistry -Root $tmp -Inventory $fixInv -Registry (Write-FixtureRegistry $ghostGap)
AssertEq 'A15 a gap naming no task at all is reported' 'missing-arm' ((KindsOf $fGhostGap 'GHOSTTY_FIXTURE_ENABLE') -join ',')

AssertEq 'A16 gap entries are counted for the ceiling' 1 (Get-SeamGapCount -Registry (Write-FixtureRegistry $openGap))

# ---------------------------------------------------------------------------
"== B: negative control - a correct registry yields nothing"
# ---------------------------------------------------------------------------
# Without this, section A would pass on an analyzer that reported every seam
# unconditionally, and section C would then be enforcing noise.
AssertEq 'B1 the fixture tree with a correct registry has NO findings' 0 (@($clean).Count)

# ---------------------------------------------------------------------------
"== C: the real sweep over this repo"
# ---------------------------------------------------------------------------
$registry = Get-SeamRegistry -Path $RegistryPath
Assert 'C1 the registry parses' ($null -ne $registry)
$inventory = Get-SeamInventory -Root $Repo
Write-Host "     seams found: $(@($inventory).Count)"
Assert 'C2 the sweep looked at both trees and found a real population' (@($inventory).Count -ge 50)

$findings = @(Test-SeamRegistry -Root $Repo -Inventory $inventory -Registry $registry)
foreach ($f in $findings) { Write-Host "     $($f.Kind): $($f.Seam) - $($f.Detail)" -ForegroundColor Yellow }

AssertEq 'C3 every seam the sweep finds is registered' 0 (@($findings | Where-Object { $_.Kind -eq 'unregistered' }).Count)
AssertEq 'C4 no registry entry names a seam that no longer exists' 0 (@($findings | Where-Object { $_.Kind -eq 'stale' }).Count)
AssertEq 'C5 every class and unset disposition is in the closed set' 0 (@($findings | Where-Object { $_.Kind -eq 'bad-class' -or $_.Kind -eq 'bad-unset' }).Count)
AssertEq 'C6 every armed seam names an arm that exists' 0 (@($findings | Where-Object { $_.Kind -eq 'missing-arm' -or $_.Kind -eq 'arm-broken' }).Count)
AssertEq 'C7 every gap names an OPEN task' 0 (@($findings | Where-Object { $_.Kind -eq 'gap-closed' }).Count)

# The seam this audit was written for, asserted by name: if relay-account.ps1
# ever stops launching without the client id, this file goes red rather than
# the defect shipping twice.
$t747 = $registry.seams.'GHOSTTY_GOOGLE_CLIENT_ID'
Assert 'C8 T747s own seam is still registered as armed' ($null -ne $t747 -and $t747.unset -eq 'armed')

# ---------------------------------------------------------------------------
"== D: the gap ceiling may only fall"
# ---------------------------------------------------------------------------
$gaps = Get-SeamGapCount -Registry $registry
$ceiling = [int]$registry.gapCeiling
Write-Host "     gaps: $gaps, ceiling: $ceiling"

if ($UpdateCeiling) {
    $raw = Get-Content -LiteralPath $RegistryPath -Raw
    $updated = [regex]::Replace($raw, '"gapCeiling":\s*\d+', "`"gapCeiling`": $gaps", 1)
    Set-Content -Encoding ascii -LiteralPath $RegistryPath -Value $updated -NoNewline
    Write-Host "  ceiling rewritten to $gaps" -ForegroundColor Cyan
    $ceiling = $gaps
}

Assert "D1 gaps ($gaps) are not above the ceiling ($ceiling)" ($gaps -le $ceiling)
if ($gaps -lt $ceiling) {
    Write-Host "  a gap was closed - re-run with -UpdateCeiling in the commit that closed it" -ForegroundColor Yellow
}
Assert "D2 the ceiling is not stale (gaps $gaps == ceiling $ceiling)" ($gaps -eq $ceiling)

# ---------------------------------------------------------------------------
if ($TeethCheck) {
    "== TEETH: C and D can go red"
    # Each perturbation is applied to a COPY, so the real registry is never
    # written by a teeth run.
    $teethPath = Join-Path $tmp 'teeth.json'
    $realSeams = @{}
    foreach ($p in $registry.seams.PSObject.Properties) { $realSeams[$p.Name] = $p.Value }

    function Write-Teeth([hashtable]$Seams, [int]$Ceiling) {
        ([pscustomobject]@{ note = 'teeth'; gapCeiling = $Ceiling; seams = $Seams }) |
            ConvertTo-Json -Depth 6 | Set-Content -Encoding ascii -LiteralPath $teethPath
        return (Get-SeamRegistry -Path $teethPath)
    }

    $dropped = $realSeams.Clone(); $dropped.Remove('GHOZTTY_PIPE_SUFFIX')
    $t1 = @(Test-SeamRegistry -Root $Repo -Inventory $inventory -Registry (Write-Teeth $dropped $ceiling))
    Assert 'T1 dropping a real seam from the registry is caught' (@($t1 | Where-Object { $_.Kind -eq 'unregistered' }).Count -eq 1)

    $invented = $realSeams.Clone(); $invented['GHOZTTY_NOT_A_REAL_SEAM'] = [pscustomobject]@{ class = 'tuning'; unset = 'shipped-elsewhere'; note = 'x' }
    $t2 = @(Test-SeamRegistry -Root $Repo -Inventory $inventory -Registry (Write-Teeth $invented $ceiling))
    Assert 'T2 an invented entry is caught as stale' (@($t2 | Where-Object { $_.Kind -eq 'stale' }).Count -eq 1)

    $brokenArm = $realSeams.Clone()
    $brokenArm['GHOSTTY_GOOGLE_CLIENT_ID'] = [pscustomobject]@{ class = 'enable'; unset = 'armed'; unsetArm = 'test\win32\relay-account.ps1::a marker nobody wrote'; note = 'x' }
    $t3 = @(Test-SeamRegistry -Root $Repo -Inventory $inventory -Registry (Write-Teeth $brokenArm $ceiling))
    Assert 'T3 an arm whose marker is gone is caught' (@($t3 | Where-Object { $_.Kind -eq 'arm-broken' }).Count -eq 1)

    $extraGap = $realSeams.Clone()
    $extraGap['GHOZTTY_PERF'] = [pscustomobject]@{ class = 'non-default'; unset = 'gap'; gap = 'T796'; note = 'x' }
    $teethReg = Write-Teeth $extraGap $ceiling
    Assert 'T4 one more gap than the ceiling allows is caught' ((Get-SeamGapCount -Registry $teethReg) -gt $ceiling)
}

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

Complete-TestBody  # T1039: the run reached the end of its body

# --- stamp (T783) ----------------------------------------------------------
# Only a CLEAN green run records the covered files, and never a teeth check -
# that run perturbs the registry on purpose, so its verdict says nothing about
# the tree as it stands.
if ($script:fail -eq 0 -and -not $TeethCheck) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard seam-audit -Repo $Repo 2>&1 |
        ForEach-Object { Write-Host "  $($_.ToString())" }
}

Write-Host ''
Write-TestVerdict -Label 'SEAM AUDIT' -Pass $script:pass -Fail $script:fail -MinPass 20
