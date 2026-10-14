<#
.SYNOPSIS
    T1020 acceptance - a DIP length converted to pixels in the harness rounds
    the way the app does (half away from zero), not the way PowerShell does.

.DESCRIPTION
    THE DEFECT: the layout modules' `px()` is `@intFromFloat(@round(dip *
    scale))`, half-AWAY-from-zero. PowerShell's bare `[Math]::Round(x)` and an
    `[int]` cast are both half-to-EVEN. A script that converts with either one
    measures a pixel the app never drew whenever `dip * scale` lands on .5 -
    4 DIP at 112.5%, 18 DIP at 125%, any odd DIP at 150%.
    `test\win32\lib\ChromeGeometry.ps1`'s `Get-TestChromeDip` is the one
    correct conversion.

    T257 found it in two tab-strip scripts and swept "the four scripts that
    measured the tab strip"; T314 found the identical helper in the chooser
    script, which no subject-scoped sweep reached. Four hand sweeps did not
    close it because the defect is an IDIOM, not a subject. This sweeps the
    idiom over every script in `test\win32` (including `lib\`), with the
    analyzer in `lib\DipRoundingAudit.ps1` - read its header for the kinds and
    for the half no sweep can catch (a script must not re-derive a number the
    module COMPOSES: round each term, then add, never round the total).

    Sections:

      A. The analyzer against fixtures, BOTH directions: the correct forms
         yield nothing, each defective form is reported by kind, a display
         Round with a digit count is not a pixel, the exemption marker needs a
         reason.

      B. NEGATIVE CONTROL: the divergence is real on THIS interpreter, at the
         scales the header names. Without it the rest of the file could be
         enforcing a rule about nothing.

      C. The ratchet. The first sweep (2026-10-14) found the defect in 40
         scripts' worth of sites; they are a per-file baseline in
         `dip-rounding-audit.baseline.json` that T1931 works down. A file ABOVE
         its baseline fails, a file BELOW it fails naming `-UpdateBaseline`,
         and a file with findings and no entry fails - so a new script cannot
         arrive already excused. `shadow` (a second Get-TestChromeDip) is held
         at zero outright.

      D. Scope: the sweep looked at the whole tree and says how much, and the
         one correct helper really answers the app's numbers.

      T. Teeth, every run: a planted bare Round in a scratch file under a swept
         tree is flagged AND fails the ratchet; a correct private copy with its
         MidpointRounding stripped is flagged; a planted shadow is flagged.

    `-UpdateBaseline` rewrites the baseline from the current sweep. Use it in
    the commit that fixes sites, never to make a red run go green.

    One ALL PASS / N FAILURE(S) line last, per the house convention.

.NOTES
    # persistence: launches no GUI - this reads source files, it does not build
    # or run anything.
#>
[CmdletBinding()]
param(
    [switch]$UpdateBaseline
)

$ErrorActionPreference = 'Continue'
$Repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\DipRoundingAudit.ps1')
. (Join-Path $PSScriptRoot 'lib\ChromeGeometry.ps1')

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

$tmp = Join-Path $env:TEMP "ghoztty-t1020-$PID"
if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force $tmp | Out-Null

$Root = Join-Path $Repo 'test\win32'
$BaselinePath = Join-Path $PSScriptRoot 'dip-rounding-audit.baseline.json'

# Sites the sweep matches that are not DIP-to-pixel conversions. Each names the
# file, the exact expression the analyzer reports, and why it is not the
# defect. Kept here rather than as markers in those files, so allow-listing a
# site does not edit (and re-due) the harness that owns it.
$Allow = @(
    [pscustomobject]@{ File = 'test\win32\dpi-change.ps1'; Detail = '[math]::Round($dpi0 * 1.5)'
        Why = 'scales a DPI value, not a DIP length; 96 * 1.5 is exact' }
    [pscustomobject]@{ File = 'test\win32\chooser-selection.ps1'; Detail = '[int]((Px 2 $scale) / 2)'
        Why = 'halves an already-converted pixel count (Px is the correct private copy)' }
    [pscustomobject]@{ File = 'test\win32\viewer-diff-tree.ps1'; Detail = '[int]((Rect-Width $topRect) / $scale)'
        Why = 'pixels back to DIP for a log line, not a measurement' }
)
function Test-Allowed($Finding) {
    $rel = Get-DipRoundingRelativePath -Path $Finding.Path -Repo $Repo
    foreach ($a in $Allow) {
        if ($a.File -ieq $rel -and $a.Detail -eq $Finding.Detail) { return $true }
    }
    return $false
}

function Fixture([string]$Body) {
    return Get-DipRoundingFindings -Path 'fixture.ps1' -Text ($Body -split "`n")
}
function KindsOf($Findings) { return (@($Findings | ForEach-Object { $_.Kind }) -join ',') }

# ===========================================================================
Write-Host ''
Write-Host '== A: the analyzer, both directions'
# ===========================================================================

$good = @'
$a = Get-TestChromeDip 4 $scale
$b = [int][Math]::Round($dip * $scale, [MidpointRounding]::AwayFromZero)
$c = [int][math]::Round(3 * $dpi / 96.0, [System.MidpointRounding]::AwayFromZero)
$d = [math]::Round($dpi / 96.0, 2)
$e = [math]::Round($elapsed)
$f = [int]($w / 2)
$g = [int][math]::Floor($dip * $scale + 0.5)
'@
$f = Fixture $good
AssertEq "A1 the correct forms, a display Round and non-scale arithmetic yield nothing ($(KindsOf $f))" 0 $f.Count

$f = Fixture '$x = [int][math]::Round(24.0 * $scale)'
Assert 'A2 a bare Round of a scale product is bare-round' ($f.Count -eq 1 -and $f[0].Kind -eq 'bare-round')
$f = Fixture '$x = [System.Math]::Round(4 * $dpi / 96)'
Assert 'A3 the System.Math spelling and a /96 conversion are caught too' ($f.Count -eq 1 -and $f[0].Kind -eq 'bare-round')
$f = Fixture 'function Px([double]$Dip) { [int][math]::Round($Dip * $script:scale) }'
Assert "A4 the T314 shape - a private Px with a bare Round - is bare-round AND private-dip ($(KindsOf $f))" (
    (KindsOf $f) -eq 'bare-round,private-dip')
$f = Fixture '$y = [int](18 * $scale)'
Assert 'A5 an [int] cast of a scale product is int-cast' ($f.Count -eq 1 -and $f[0].Kind -eq 'int-cast')
$f = Fixture '$y = [int]($rect.Right - [Math]::Round(18 * $scale))'
Assert "A6 a cast around a Round is reported once, as the Round ($(KindsOf $f))" ((KindsOf $f) -eq 'bare-round')
$f = Fixture 'function Get-TestChromeDip { param($Dip, $Scale) $Dip * $Scale }'
Assert 'A7 a second Get-TestChromeDip is a shadow' ($f.Count -eq 1 -and $f[0].Kind -eq 'shadow')
$f = Fixture 'function Px([double]$d, [double]$s) { return [int][math]::Floor($d * $s + 0.5) }'
Assert "A8 a correct private copy is private-dip only, which is informational ($(KindsOf $f))" (
    (KindsOf $f) -eq 'private-dip' -and (Get-DipRoundingHardKinds) -notcontains 'private-dip')
$f = Fixture '$px = { param([double]$dip) Get-TestChromeDip -Dip $dip -Scale $scale }'
AssertEq 'A9 a private block that CALLS the helper is not a private copy' 0 $f.Count
$f = Fixture "# dip-audit: a DPI value, not a length`n`$x = [int][math]::Round(`$dpi * 1.5)"
AssertEq 'A10 a stated reason on the line above exempts the site' 0 $f.Count
$f = Fixture "# dip-audit:`n`$x = [int][math]::Round(`$dpi * 1.5)"
AssertEq 'A11 a marker with no reason exempts nothing' 1 $f.Count
$f = Fixture "`$ok = Get-TestChromeDip 4 `$scale`n`$bad = [math]::Round(8 * `$scale)"
Assert 'A12 one bad site among good ones is the only finding, at its line' ($f.Count -eq 1 -and $f[0].Line -eq 2)

# ===========================================================================
Write-Host ''
Write-Host '== B: negative control - the divergence is real on THIS interpreter'
# ===========================================================================

AssertEq 'B1 4 DIP at 112.5%: bare Round answers 4' 4 ([int][Math]::Round(4 * 1.125))
AssertEq 'B2 and the app (half away from zero) answers 5' 5 (Get-TestChromeDip 4 1.125)
AssertEq 'B3 18 DIP at 125%: bare Round answers 22 - the header''s "agrees at 125%" is not general' 22 ([int][Math]::Round(18 * 1.25))
AssertEq 'B4 and the app answers 23' 23 (Get-TestChromeDip 18 1.25)
AssertEq 'B5 an [int] cast rounds half-to-even too (3 DIP at 150% -> 4)' 4 ([int](3 * 1.5))
AssertEq 'B6 where the app answers 5' 5 (Get-TestChromeDip 3 1.5)
AssertEq 'B7 Floor(x + 0.5) agrees with the app for a positive length' 5 ([int][math]::Floor(3 * 1.5 + 0.5))

# ===========================================================================
Write-Host ''
Write-Host '== C: the ratchet over test\win32'
# ===========================================================================

$all = Get-DipRoundingSweep -Roots @($Root)
$hardKinds = Get-DipRoundingHardKinds
$hard = @($all | Where-Object { $hardKinds -contains $_.Kind -and -not (Test-Allowed $_) })
$info = @($all | Where-Object { $_.Kind -eq 'private-dip' })
$allowedHits = @($all | Where-Object { Test-Allowed $_ })

$current = @{}
foreach ($x in @($hard | Where-Object { $_.Kind -ne 'shadow' })) {
    $rel = Get-DipRoundingRelativePath -Path $x.Path -Repo $Repo
    if (-not $current.ContainsKey($rel)) { $current[$rel] = 0 }
    $current[$rel] = $current[$rel] + 1
}

if ($UpdateBaseline) {
    $obj = [ordered]@{
        note      = 'Per-file counts of dip-rounding-audit findings (bare-round + int-cast) not yet fixed. May only go DOWN, and the run that lowers one rewrites this file with -UpdateBaseline. See docs/design/windows-parity-tasks/T1931.md.'
        generated = (Get-Date -Format 'yyyy-MM-dd')
        files     = [ordered]@{}
    }
    foreach ($k in ($current.Keys | Sort-Object)) { $obj.files[$k] = $current[$k] }
    ($obj | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $BaselinePath -Encoding ascii
    Write-Host "  baseline rewritten: $($current.Keys.Count) file(s)"
}

Assert 'C0 the baseline exists' (Test-Path -LiteralPath $BaselinePath)
$baseFiles = @{}
if (Test-Path -LiteralPath $BaselinePath) {
    $base = Get-Content -LiteralPath $BaselinePath -Raw | ConvertFrom-Json
    foreach ($p in $base.files.PSObject.Properties) { $baseFiles[$p.Name] = [int]$p.Value }
}

$cmp = Compare-DipRoundingBaseline -Current $current -Baseline $baseFiles
foreach ($r in $cmp.Regressed) { Write-Host "      NEW: $r" -ForegroundColor Red }
if (@($cmp.Regressed).Count -gt 0) {
    foreach ($x in $hard) {
        $rel = Get-DipRoundingRelativePath -Path $x.Path -Repo $Repo
        if (@($cmp.Regressed | Where-Object { $_.StartsWith("$rel ") }).Count -gt 0) {
            Write-Host "      $rel`:$($x.Line) $($x.Kind): $($x.Detail)  -> use Get-TestChromeDip (lib\ChromeGeometry.ps1)"
        }
    }
}
AssertEq 'C1 no file has gained a banker''s-rounded DIP conversion' 0 @($cmp.Regressed).Count
foreach ($i in $cmp.Improved) { Write-Host "      FIXED: $i" }
Assert 'C2 the baseline matches the tree (-UpdateBaseline in the commit that fixes a site)' (
    @($cmp.Improved).Count -eq 0)

$shadows = @($hard | Where-Object { $_.Kind -eq 'shadow' })
foreach ($x in $shadows) { Write-Host "      $(Get-DipRoundingRelativePath $x.Path $Repo):$($x.Line) $($x.Detail)" -ForegroundColor Red }
AssertEq 'C3 nothing shadows Get-TestChromeDip' 0 $shadows.Count
AssertEq 'C4 nothing in the tree fails to parse' 0 @($hard | Where-Object { $_.Kind -eq 'parse-error' }).Count
AssertEq "C5 every allow-list entry still matches a site (a stale entry is a hole)" $Allow.Count $allowedHits.Count

# ===========================================================================
Write-Host ''
Write-Host '== D: scope, and the one correct helper'
# ===========================================================================

$ps1Count = @(Get-ChildItem -LiteralPath $Root -Filter *.ps1 -File -Recurse).Count
$libCount = @(Get-ChildItem -LiteralPath (Join-Path $Root 'lib') -Filter *.ps1 -File).Count
Assert "D1 the sweep walked test\win32 ($ps1Count .ps1 files, $libCount of them in lib\)" (
    $ps1Count -ge 300 -and $libCount -ge 20)
$homeHits = @($all | Where-Object { [System.IO.Path]::GetFileName($_.Path) -ieq 'ChromeGeometry.ps1' })
AssertEq 'D2 ChromeGeometry.ps1 itself has no findings' 0 $homeHits.Count
AssertEq 'D3 Get-TestChromeDip answers the app at 112.5% (4 -> 5)' 5 (Get-TestChromeDip 4 1.125)
AssertEq 'D4 and at 100% it is the identity' 28 (Get-TestChromeDip 28 1.0)

# ===========================================================================
Write-Host ''
Write-Host '== T: the teeth (C1, the analyzer and C3 must be able to score red)'
# ===========================================================================

$fakeRoot = Join-Path $tmp 'test\win32'
New-Item -ItemType Directory -Force $fakeRoot | Out-Null
Set-Content -LiteralPath (Join-Path $fakeRoot 'planted-dip.ps1') -Encoding ascii -Value @(
    '$scale = 1.125',
    '$edge = [int][Math]::Round(4 * $scale)')
$planted = Get-DipRoundingSweep -Roots @($fakeRoot)
Assert 'T1 a bare Round planted in a scratch file under a swept tree is flagged' (
    $planted.Count -eq 1 -and $planted[0].Kind -eq 'bare-round')
$withPlant = @{}
foreach ($k in $current.Keys) { $withPlant[$k] = $current[$k] }
$withPlant['test\win32\planted-dip.ps1'] = 1
$cmpT = Compare-DipRoundingBaseline -Current $withPlant -Baseline $baseFiles
Assert 'T2 and the ratchet fails on it - a new file cannot arrive excused' (
    @($cmpT.Regressed | Where-Object { $_ -like 'test\win32\planted-dip.ps1 *' }).Count -eq 1)

$victim = Join-Path $Root 'key-state-pill.ps1'
$text = @(Get-Content -LiteralPath $victim)
$wounded = @($text | ForEach-Object { $_.Replace(', [System.MidpointRounding]::AwayFromZero)', ')') })
Assert 'T3 the fixture actually stripped a correct private copy''s MidpointRounding' (
    ($text -join "`n") -ne ($wounded -join "`n"))
$t = Get-DipRoundingFindings -Path $victim -Text $wounded
AssertEq 'T4 and the analyzer flags the wounded copy' 1 @($t | Where-Object { $_.Kind -eq 'bare-round' }).Count

Set-Content -LiteralPath (Join-Path $fakeRoot 'shadow-dip.ps1') -Encoding ascii -Value @(
    'function Get-TestChromeDip { param($Dip, $Scale) [int]($Dip * $Scale) }')
$t = Get-DipRoundingSweep -Roots @($fakeRoot)
AssertEq 'T5 a planted shadow helper is flagged as a shadow' 1 @($t | Where-Object { $_.Kind -eq 'shadow' }).Count

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

Complete-TestBody  # T1039: the run reached the end of its body

# --- stamp (T783) ----------------------------------------------------------
if ($script:fail -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard dip-rounding -Repo $Repo 2>&1 |
        ForEach-Object { Write-Host "  $($_.ToString())" }
}

Write-Host ''
Write-Host "  sweep: $ps1Count script(s); $($hard.Count) banker's-rounded site(s) across $($current.Keys.Count) file(s) (baseline; T1931 works them down)"
Write-Host "  private DIP conversions (informational - the hoist list): $($info.Count)"
foreach ($x in $info) { Write-Host "      $(Get-DipRoundingRelativePath $x.Path $Repo):$($x.Line) $($x.Detail)" }
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Label 'DIP ROUNDING AUDIT' -MinPass 30
