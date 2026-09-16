<#
.SYNOPSIS
    T794 acceptance - a count read off a helper's return is `@()`-wrapped at the
    point of use, so the assertion that reads it can actually fail.

.DESCRIPTION
    THE DEFECT (found while writing `test\win32\chooser-open-chord.ps1`, T746):

        $before = (Get-TopWindows $g.Pid).Count
        ...
        Assert 'and no plain terminal window was opened instead' ($after -eq $before)

    printed `( -> )` and passed. PowerShell 5.1 unrolls a ONE-element array on
    return, the caller gets the element itself, and `.Count` on a PSCustomObject
    is `$null` - so the assertion compared `$null` with `$null` and could not
    have gone red whatever the product did. The `@()` INSIDE the helper does not
    survive the return; only the wrap at the point of use does.

    Same family as T271 (a run that asserted nothing) and T791 (a negative
    control that inverts nothing). What makes this one worth a machine check is
    that it is invisible on the page: the line reads like ordinary arithmetic,
    and it only misbehaves in the one-element case - which for "how many windows
    does this app have" is the common case.

    Four sections:

      A. The analyzer (`lib\UnrollCountAudit.ps1`) against fixtures, BOTH
         directions: `@(...)`-wrapped and `[array]`-cast counts yield nothing,
         each unwrapped shape is reported by kind, a count off a real cmdlet is
         never a finding, and the `# count-audit: <reason>` exemption waives a
         site while a bare marker waives nothing.

      B. The NEGATIVE CONTROL: the trap is real on THIS interpreter. Without it
         the rest of the file could pass on a runtime where a one-element return
         keeps its `.Count`, and would then be enforcing a rule about nothing.

      C. The ratchet over `test\win32` and `scripts`. The 2026-09-16 sweep found
         197 sites; this run fixed the 46 in the harness-floor audits and their
         libs, and the rest are a recorded per-file baseline that T1617 works
         down. A file ABOVE its baseline is a new defect and fails. A file BELOW
         it fails too, naming `-UpdateBaseline`: a ratchet that only tightens
         when somebody remembers to tighten it drifts back into a wishlist. A
         file with findings and no baseline entry fails, so a newly added script
         cannot arrive already excused.

      D. The scope claim: the sweep has to have looked at both trees and built a
         real index, and the files this run FIXED have to be at zero - the
         assertion the fix owed, checked rather than remembered.

    `-TeethCheck` proves C and D can fail: it plants each unwrapped shape into a
    throwaway tree and requires the assertions to score red. Run it after any
    change to the analyzer.

    `-UpdateBaseline` rewrites `unroll-count-audit.baseline.json` from the
    current sweep. Use it in the commit that fixes sites, never to make a red
    run go green.

    One ALL PASS / N FAILURE(S) line last, per the house convention.

.NOTES
    # persistence: launches no GUI - this reads source files, it does not build
    # or run anything.
#>
[CmdletBinding()]
param(
    [switch]$TeethCheck,
    [switch]$UpdateBaseline
)

$ErrorActionPreference = 'Continue'
$Repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\UnrollCountAudit.ps1')

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

$tmp = Join-Path $env:TEMP "ghoztty-t794-$PID"
if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force $tmp | Out-Null

$BaselinePath = Join-Path $PSScriptRoot 'unroll-count-audit.baseline.json'

# The roots the rule covers. Both, because the population the defect lives in -
# the shared window helpers - is defined in `test\win32\lib` and called from
# scripts in both trees.
$Roots = @((Join-Path $Repo 'test\win32'), (Join-Path $Repo 'scripts'))

# The files this run fixed. D2 holds them at zero; without the list, "the fix
# landed" would be a memory rather than an assertion.
$Fixed = @(
    'test\win32\asserted-nothing.ps1', 'test\win32\build-mode-guard.ps1',
    'test\win32\stderr-capture-audit.ps1', 'test\win32\command-resolve-audit.ps1',
    'test\win32\argv-hazard-audit.ps1', 'test\win32\foreground-audit.ps1',
    'test\win32\caller-anchor.ps1', 'test\win32\window-composite.ps1',
    'scripts\vt-escape-scan.ps1',
    'test\win32\lib\WindowComposite.ps1', 'test\win32\lib\BuildMode.ps1',
    'test\win32\lib\PersistenceSweep.ps1'
)

# A fixture is analyzed with an index that knows the one helper it calls, so the
# fixtures state the cross-file case too (the shared-helper population) without
# writing files into the trees under test.
$FixtureIndex = @{ 'get-testwindows' = 'lib\TestDesktop.ps1' }
function Get-FixtureFindings([string]$Body) {
    return @(Get-UnrollCountFindings -Path 'fixture.ps1' -Text ($Body -split "`n") -Index $FixtureIndex)
}

# ===========================================================================
Write-Host ''
Write-Host '== A: the analyzer, both directions'
# ===========================================================================

$wrapped = @'
function Get-Rows { return @($raw | Where-Object { $_ }) }
$n = @(Get-Rows).Count
$w = @(Get-TestWindows -ProcessId 1)
$m = $w.Count
$c = ([array](Get-Rows)).Count
'@
AssertEq 'A1 wrapped counts yield nothing' 0 @(Get-FixtureFindings $wrapped).Count

$scalarHelper = @'
function Get-Title { return "a title" }
$n = (Get-Title).Count
'@
AssertEq 'A2 a helper that cannot return an array is not a finding' 0 `
    @(Get-FixtureFindings $scalarHelper).Count

$cmdlet = @'
$n = (Get-Content 'x.txt').Count
$d = (Get-ChildItem 'x').Count
'@
AssertEq 'A3 a count off a real cmdlet is never a finding' 0 @(Get-FixtureFindings $cmdlet).Count

$call = @'
function Get-Rows { return @($raw | Where-Object { $_ }) }
$n = (Get-Rows).Count
'@
$f = @(Get-FixtureFindings $call)
AssertEq 'A4 an unwrapped local call is reported' 1 $f.Count
Assert 'A5 and named as unwrapped-call, with the helper' (
    $f.Count -eq 1 -and $f[0].Kind -eq 'unwrapped-call' -and $f[0].Name -eq 'Get-Rows')

$shared = @'
$before = (Get-TestWindows -ProcessId $pid).Count
'@
$f = @(Get-FixtureFindings $shared)
Assert 'A6 a dot-sourced shared helper is reported too (the T746 shape)' (
    $f.Count -eq 1 -and $f[0].Kind -eq 'unwrapped-call' -and $f[0].Name -eq 'Get-TestWindows')

$var = @'
function Get-Rows { return @($raw | Where-Object { $_ }) }
$rows = Get-Rows
$n = $rows.Count
'@
$f = @(Get-FixtureFindings $var)
AssertEq 'A7 a variable assigned unwrapped and then counted is reported' 1 $f.Count
Assert 'A8 and named as unwrapped-var, at the COUNT site' (
    $f.Count -eq 1 -and $f[0].Kind -eq 'unwrapped-var' -and $f[0].Line -eq 3)

$reassigned = @'
function Get-Rows { return @($raw | Where-Object { $_ }) }
$rows = Get-Rows
$rows = @(Get-Rows)
$n = $rows.Count
'@
AssertEq 'A9 the NEAREST assignment decides - a later wrap clears the site' 0 `
    @(Get-FixtureFindings $reassigned).Count

$reused = @'
function Get-Rows { return @($raw | Where-Object { $_ }) }
$rows = Get-Rows
$a = $rows.Count
$rows = Get-Rows
$b = $rows.Count
'@
AssertEq 'A10 a reused scratch variable counts once per COUNT site, not per pair' 2 `
    @(Get-FixtureFindings $reused).Count

$waived = @'
function Get-Rows { return @($raw | Where-Object { $_ }) }
# count-audit: the caller only ever has many, and the empty case throws above
$n = (Get-Rows).Count
'@
AssertEq 'A11 a stated reason exempts the site' 0 @(Get-FixtureFindings $waived).Count

$bare = @'
function Get-Rows { return @($raw | Where-Object { $_ }) }
# count-audit:
$n = (Get-Rows).Count
'@
Assert 'A12 a marker with no reason exempts nothing' (
    @(Get-FixtureFindings $bare).Count -eq 1)

$mixed = @'
function Get-Rows { return @($raw | Where-Object { $_ }) }
$ok = @(Get-Rows).Count
$bad = (Get-Rows).Count
'@
$f = @(Get-FixtureFindings $mixed)
Assert 'A13 one bad site among good ones is still the only finding' (
    $f.Count -eq 1 -and $f[0].Line -eq 3)

# The other half of the rule, and the half that costs something to get wrong:
# `return , @(...)` is this suite's existing defence and it WORKS, so a count
# off such a helper is already right and wrapping it would break it (see B5).
$comma = @'
function Findings($lines) { return , @($lines | Where-Object { $_ }) }
$n = (Findings $x).Count
$f = Findings $x
$m = $f.Count
'@
AssertEq 'A14 a comma-protected helper is not a finding - its count is already right' 0 `
    @(Get-FixtureFindings $comma).Count

# ...and a LOCAL definition decides for its own file. `Findings` is defined in
# four audits, one of them comma-protected; without this, that file inherits the
# others' verdict and gets told to add an `@()` that would be a new defect.
$shadow = @'
function Get-TestWindows { return , @($raw | Where-Object { $_ }) }
$n = (Get-TestWindows).Count
'@
AssertEq 'A15 a local definition shadows the repo-wide index, in both directions' 0 `
    @(Get-FixtureFindings $shadow).Count

$shadowOther = @'
function Get-Rows { return , @($raw | Where-Object { $_ }) }
$n = (Get-TestWindows -ProcessId 1).Count
'@
Assert 'A16 and shadowing one name does not excuse the rest of the file' (
    @(Get-FixtureFindings $shadowOther).Count -eq 1)

# ===========================================================================
Write-Host ''
Write-Host '== B: negative control - the trap is real on THIS interpreter'
# ===========================================================================

function Get-OneRecord { return @([pscustomobject]@{ a = 1 }) }
function Get-TwoRecords { return @([pscustomobject]@{ a = 1 }, [pscustomobject]@{ a = 2 }) }

# Deliberately the WRONG idiom. If this ever stops answering $null, the rule
# this file enforces has changed and the file should be re-read, not quietly
# kept green.
# count-audit: the WRONG idiom on purpose - this line IS the negative control
$naive = (Get-OneRecord).Count
Assert 'B1 a one-element return really does lose its .Count on this runtime' ($null -eq $naive)
# count-audit: unwrapped on purpose - B2 measures what the unwrapped read answers
$naiveTwo = (Get-TwoRecords).Count
AssertEq 'B2 and a two-element return does not, which is why it looks fine in review' 2 $naiveTwo
AssertEq 'B3 the wrap at the point of use is what fixes it' 1 @(Get-OneRecord).Count

# And the measurement the A14 rule rests on: the suite's `return , @(...)`
# idiom keeps the count correct at the call site, and an `@()` around THAT call
# answers 1 whatever it holds. A sweep that did not know this turned four green
# audits red on 2026-09-16 by "fixing" them.
function Get-CommaWrapped { return , @([pscustomobject]@{ a = 1 }, [pscustomobject]@{ a = 2 }) }
AssertEq 'B5 a comma-protected return counts correctly unwrapped' 2 (Get-CommaWrapped).Count
AssertEq 'B6 and wrapping THAT call is the new defect, not the fix' 1 @(Get-CommaWrapped).Count

# The assertion shape the defect actually wears: two vacuous counts compared.
# count-audit: the defect shape on purpose - B4 measures that it passes
$before = (Get-OneRecord).Count
$after = (Get-TwoRecords | Select-Object -First 1).Count
Assert 'B4 and the comparison it hides in passes while both sides are nothing' ($before -eq $after)

# ===========================================================================
Write-Host ''
Write-Host '== C: the ratchet over test\win32 and scripts'
# ===========================================================================

$index = Get-UnrollCountIndex -Roots $Roots
$sweep = @(Get-UnrollCountSweep -Roots $Roots -Index $index)
$current = @{}
foreach ($x in $sweep) {
    $rel = Get-UnrollCountRelativePath -Path $x.Path -Repo $Repo
    if (-not $current.ContainsKey($rel)) { $current[$rel] = 0 }
    $current[$rel] = $current[$rel] + 1
}

if ($UpdateBaseline) {
    $obj = [ordered]@{
        note      = 'Per-file counts of unroll-count-audit findings not yet fixed. May only go DOWN, and the run that lowers one rewrites this file with -UpdateBaseline. See docs/design/windows-parity-tasks/T1617.md.'
        generated = (Get-Date -Format 'yyyy-MM-dd')
        files     = [ordered]@{}
    }
    foreach ($k in ($current.Keys | Sort-Object)) { $obj.files[$k] = $current[$k] }
    ($obj | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $BaselinePath -Encoding ascii
    Write-Host "  baseline rewritten: $($current.Keys.Count) file(s), $($sweep.Count) site(s)"
}

Assert 'C0 the baseline exists' (Test-Path -LiteralPath $BaselinePath)
$baseFiles = @{}
if (Test-Path -LiteralPath $BaselinePath) {
    $base = Get-Content -LiteralPath $BaselinePath -Raw | ConvertFrom-Json
    foreach ($p in $base.files.PSObject.Properties) { $baseFiles[$p.Name] = [int]$p.Value }
}

$regressed = New-Object System.Collections.ArrayList
$improved = New-Object System.Collections.ArrayList
foreach ($k in ($current.Keys | Sort-Object)) {
    $was = 0
    if ($baseFiles.ContainsKey($k)) { $was = $baseFiles[$k] }
    if ($current[$k] -gt $was) { [void]$regressed.Add("$k ($was -> $($current[$k]))") }
    elseif ($current[$k] -lt $was) { [void]$improved.Add("$k ($was -> $($current[$k]))") }
}
foreach ($k in ($baseFiles.Keys | Sort-Object)) {
    if (-not $current.ContainsKey($k) -and $baseFiles[$k] -gt 0) {
        [void]$improved.Add("$k ($($baseFiles[$k]) -> 0)")
    }
}

foreach ($r in $regressed) { Write-Host "      NEW: $r" -ForegroundColor Red }
AssertEq 'C1 no file has gained a vacuous count' 0 $regressed.Count
if ($regressed.Count -gt 0) {
    foreach ($x in $sweep) {
        $rel = Get-UnrollCountRelativePath -Path $x.Path -Repo $Repo
        if ($regressed -match [regex]::Escape($rel)) {
            Write-Host "      $rel`:$($x.Line) $($x.Kind): $($x.Detail)"
        }
    }
}

foreach ($i in $improved) { Write-Host "      FIXED: $i" }
Assert 'C2 the baseline matches what is actually in the tree (-UpdateBaseline after a fix)' (
    $improved.Count -eq 0)

AssertEq 'C3 nothing in either tree fails to parse' 0 `
    @($sweep | Where-Object { $_.Kind -eq 'parse-error' }).Count

# ===========================================================================
Write-Host ''
Write-Host '== D: the sweep is scoped the way the rule says'
# ===========================================================================

$ps1Count = 0
foreach ($r in $Roots) { $ps1Count += @(Get-ChildItem -LiteralPath $r -Filter *.ps1 -File -Recurse).Count }
Assert "D1 the sweep walked both trees ($ps1Count .ps1 files)" ($ps1Count -ge 400)

$missing = New-Object System.Collections.ArrayList
foreach ($rel in $Fixed) {
    if ($current.ContainsKey($rel)) { [void]$missing.Add("$rel ($($current[$rel]))") }
}
foreach ($m in $missing) { Write-Host "      STILL VACUOUS: $m" -ForegroundColor Red }
AssertEq "D2 the $($Fixed.Count) files this task fixed are at zero" 0 $missing.Count

Assert "D3 the index found the repo's array-returning helpers ($($index.Count))" ($index.Count -ge 100)
Assert 'D4 and the shared window helpers are among them' (
    $index.ContainsKey('get-testwindows') -and $index.ContainsKey('get-testchildwindows'))

$kinds = @($sweep | ForEach-Object { $_.Kind } | Sort-Object -Unique)
Assert "D5 every finding is one of the declared kinds ($($kinds -join ', '))" (
    @($kinds | Where-Object { (Get-UnrollCountHardKinds) -notcontains $_ }).Count -eq 0)

# ===========================================================================
if ($TeethCheck) {
    Write-Host ''
    Write-Host '== T: the teeth (C1 and D2 must be able to score red)'
    # =======================================================================
    $fake = Join-Path $tmp 'repo'
    New-Item -ItemType Directory -Force (Join-Path $fake 'test\win32\lib') | Out-Null

    Set-Content -LiteralPath (Join-Path $fake 'test\win32\lib\Helpers.ps1') -Encoding ascii -Value @(
        'function Get-Rows { return @($raw | Where-Object { $_ }) }')

    # C1's teeth: a file the baseline does not know about, carrying each shape.
    Set-Content -LiteralPath (Join-Path $fake 'test\win32\newcomer.ps1') -Encoding ascii -Value @(
        '$n = (Get-Rows).Count',
        '$rows = Get-Rows',
        '$m = $rows.Count')
    $t = @(Get-UnrollCountSweep -Roots @((Join-Path $fake 'test\win32')))
    $newcomer = @($t | Where-Object { $_.Path -like '*newcomer.ps1' })
    AssertEq 'T1 a new file arriving with both shapes is reported by the sweep' 2 $newcomer.Count
    Assert 'T2 and it has no baseline entry, so the ratchet scores it' (
        -not $baseFiles.ContainsKey('test\win32\newcomer.ps1'))

    # D2's teeth: re-plant the defect into a copy of a file this run fixed and
    # require the analyzer to find it again.
    $victim = Join-Path $Repo 'test\win32\argv-hazard-audit.ps1'
    $text = @(Get-Content -LiteralPath $victim)
    $re = [regex]'@\((Fixture-Findings [^)]*)\)\.Count'
    $wounded = @($text | ForEach-Object { $re.Replace($_, '($1).Count') })
    Assert 'T3 the fixture actually re-planted the defect' (
        (($text -join "`n") -ne ($wounded -join "`n")))
    $t = @(Get-UnrollCountFindings -Path $victim -Text $wounded -Index $index)
    Assert 'T4 a re-wounded fixed file is reported again' (
        @($t | Where-Object { $_.Kind -eq 'unwrapped-call' }).Count -ge 1)
}

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

Complete-TestBody  # T1039: the run reached the end of its body

# --- stamp (T783) ----------------------------------------------------------
# Only a CLEAN green run records the covered files, and never a teeth check -
# that run plants violators, so its verdict says nothing about the tree as it
# stands.
if ($script:fail -eq 0 -and -not $TeethCheck) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard unroll-count -Repo $Repo 2>&1 |
        ForEach-Object { Write-Host "  $($_.ToString())" }
}

Write-Host ''
Write-Host "  sweep: $($sweep.Count) site(s) still unwrapped across $($current.Keys.Count) file(s) (baseline; T1617 works them down)"
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Label 'UNROLL COUNT AUDIT' -MinPass 20
