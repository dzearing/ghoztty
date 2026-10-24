<#
.SYNOPSIS
    T1281 acceptance - a pixel probe that aggregates over a WHOLE capture has
    to say why the whole capture is the right region for its claim.

.DESCRIPTION
    THE DEFECT (T1115): test-desktop-spike.ps1 decided "PrintWindow returns the
    real window" from the mean luminance and distinct-colour count of every
    4th pixel of the whole window. The terminal surface is dark by design and
    fills most of the window, so light chrome over a flat, uncomposed client
    area scored about the same as a full capture - the two outcomes the
    assertion existed to separate. It read green for a month and flipped red
    with no behaviour change when the chrome shrank. T363 was the same class
    the day before. The fix scored by region, with the chrome band as the
    in-script positive control.

    A hand sweep closes today's instances (T1281's inventory, recorded in the
    task file); it says nothing about the next probe. This sweeps the IDIOM -
    two nested full-axis loops whose body accumulates - with the analyzer in
    `lib\PixelOracleAudit.ps1` (its header has the rules), including walks in
    embedded C# here-strings, which is where the T1115 one lived.

    Sections:

      A. The analyzer against fixtures, BOTH directions: a whole-capture mean
         and a distinct-colour set (PowerShell and C#) are reported; a walk
         bounded to a band, a half or a parameterised sub-rect is not; a
         read-only search and a buffer copy are not; the C# one-line nest
         parses; the exemption marker needs a reason.

      B. NEGATIVE CONTROL against the real thing: test-desktop-spike.ps1 as it
         stood BEFORE the T1115 fix (read from git) is flagged on its Sample()
         walk, and the file as it stands now is not.

      C. The ratchet. The sites present on 2026-10-24 were each read by the
         T1281 sweep and are SOUND (a crop's own size, or a window that is the
         subject); they are a per-file count in `pixel-oracle-audit.baseline.json`.
         A file ABOVE its count fails, a file BELOW it fails naming
         `-UpdateBaseline`, and a new file with a finding fails - so a new walk
         has to bound its region or declare `# pixel-region: <reason>`.

      D. Scope: the sweep looked at the whole tree and says how much.

      T. Teeth, every run: a planted file under a swept tree is flagged AND
         fails the ratchet.

    `-UpdateBaseline` rewrites the baseline from the current sweep. Use it in
    the commit that removes a site, never to make a red run go green.

    One ALL PASS / N FAILURE(S) line last, per the house convention.

.NOTES
    # persistence: launches no GUI - this reads source files, it does not build
    # or run anything.
    # isolation: none - nothing is launched; the GetPixel calls here are fixture text for the analyzer
#>
[CmdletBinding()]
param(
    [switch]$UpdateBaseline
)

$ErrorActionPreference = 'Continue'
$Repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\PixelOracleAudit.ps1')

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

$tmp = Join-Path $env:TEMP "ghoztty-t1281-$PID"
if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force $tmp | Out-Null

$Root = Join-Path $Repo 'test\win32'
$BaselinePath = Join-Path $PSScriptRoot 'pixel-oracle-audit.baseline.json'

function Fixture([string]$Body) {
    return , @(Get-PixelOracleFindings -Path 'fixture.ps1' -Text ($Body -split "`n") | ForEach-Object { $_ })
}
function KindsOf($Findings) { return (@($Findings | ForEach-Object { $_.Kind }) -join ',') }

# ===========================================================================
Write-Host ''
Write-Host '== A: the analyzer, both directions'
# ===========================================================================

$f = Fixture @'
$sum = 0
for ($y = 0; $y -lt $shot.Height; $y += 4) {
    for ($x = 0; $x -lt $shot.Width; $x += 4) {
        $c = $shot.Bitmap.GetPixel($x, $y)
        $sum += $c.R
    }
}
'@
Assert "A1 a whole-capture mean in PowerShell is a finding ($(KindsOf $f))" ($f.Count -eq 1 -and $f[0].Kind -eq 'whole-capture' -and $f[0].Line -eq 2)

$f = Fixture @'
static void Sample(IntPtr dc, int w, int h, out int distinct) {
    var seen = new HashSet<uint>();
    for (int y = 2; y < h; y += 4) {
        for (int x = 2; x < w; x += 4) {
            seen.Add(GetPixel(dc, x, y));
        }
    }
    distinct = seen.Count;
}
'@
Assert "A2 a whole-capture distinct-colour set in C# is a finding ($(KindsOf $f))" ($f.Count -eq 1 -and $f[0].Line -eq 3)

$f = Fixture @'
for ($y = $shot.Top; $y -lt $shot.Top + $shot.Height - 2; $y++) {
    for ($x = $shot.Left + 1; $x -lt $shot.Left + $shot.Width; $x++) { $n++ }
}
'@
Assert "A3 an origin-relative walk with a literal margin is still the whole capture ($(KindsOf $f))" ($f.Count -eq 1)

$f = Fixture @'
for ($y = 0; $y -lt $bandH; $y++) { for ($x = 0; $x -lt $shot.Width; $x++) { $n++ } }
for ($y = 0; $y -lt $shot.Height / 2; $y++) { for ($x = 0; $x -lt $shot.Width; $x++) { $n++ } }
for ($y = $top; $y -lt $shot.Height - $bandH; $y++) { for ($x = 0; $x -lt $shot.Width; $x++) { $n++ } }
'@
AssertEq "A4 a band, a half and a variable-trimmed axis are regions, not findings ($(KindsOf $f))" 0 $f.Count

$f = Fixture @'
static void SampleRect(IntPtr dc, int x0, int y0, int w, int h) {
    for (int y = y0 + 2; y < y0 + h; y += 4) {
        for (int x = x0 + 2; x < x0 + w; x += 4) { sum += GetPixel(dc, x, y); }
    }
}
'@
AssertEq "A5 a sub-rect helper (start at a caller's x0/y0) is a region - the T1115 fix shape ($(KindsOf $f))" 0 $f.Count

$f = Fixture @'
for ($y = 0; $y -lt $h; $y++) {
    for ($x = 0; $x -lt $w; $x++) {
        $px[($y * $w) + $x] = $shot.Bitmap.GetPixel($x, $y).ToArgb()
        if ($px[($y * $w) + $x] -eq $want) { $hit = $true; break }
    }
}
'@
AssertEq "A6 a buffer copy indexed by both loop variables and a search that breaks are not accumulations ($(KindsOf $f))" 0 $f.Count

$f = Fixture @'
protected override void OnPaint(PaintEventArgs e) {
    for (int y = 0; y < Height; y += 8) for (int x = 0; x < Width; x += 8)
      e.Graphics.FillRectangle(Brushes.Red, x, y, 8, 8);
    for (int y = 0; y < Height; y++) for (int x = 0; x < Width; x++) n++;
}
'@
Assert "A7 the C# one-line nest parses: a painter is not a finding, an accumulating one is ($(KindsOf $f))" (
    $f.Count -eq 1 -and $f[0].Line -eq 4)

$f = Fixture @'
# pixel-region: the claim is "the capture is not blank", which is about the whole capture
for ($y = 0; $y -lt $shot.Height; $y++) {
    for ($x = 0; $x -lt $shot.Width; $x++) { $n++ }
}
'@
AssertEq 'A8 a stated reason on the line above exempts the walk' 0 $f.Count

$f = Fixture @'
# pixel-region:
for ($y = 0; $y -lt $shot.Height; $y++) {
    for ($x = 0; $x -lt $shot.Width; $x++) { $n++ }
}
'@
AssertEq 'A9 a marker with no reason exempts nothing' 1 $f.Count

$f = Fixture @'
$s = "for ($y = 0; $y -lt $shot.Height; $y++) { for ($x = 0; $x -lt $shot.Width; $x++) { $n++ } }"
# for ($y = 0; $y -lt $shot.Height; $y++) { for ($x = 0; $x -lt $shot.Width; $x++) { $n++ } }
'@
AssertEq 'A10 a walk inside a string or a comment is not code' 0 $f.Count

$f = Fixture @'
for ($y = 0; $y -lt $shot.Height; $y++) {
    for ($x = 0; $x -lt $shot.Width; $x++) { $n++
'@
Assert "A11 a full-axis walk whose body never closes is reported, not skipped ($(KindsOf $f))" (
    $f.Count -ge 1 -and @($f | Where-Object { $_.Kind -ne 'unbalanced' }).Count -eq 0)

$f = Fixture @'
for ($y = 0; $y -lt $shot.Height; $y++) { for ($x = 0; $x -lt $shot.Width; $x++) { $n++ } }
'@
AssertEq "A12 the analyzer's own harness is the one file the sweep skips, and only by name" 'pixel-oracle-audit.ps1' $script:PIXEL_ORACLE_SELF
Assert "A13 its fixture text is still read when handed over directly ($(KindsOf $f))" ($f.Count -eq 1)

# ===========================================================================
Write-Host ''
Write-Host '== B: negative control - the real T1115 defect, before and after'
# ===========================================================================

$pre = @(& git -C $Repo show '9e0418217~1:test/win32/test-desktop-spike.ps1' 2>$null)
Assert "B1 test-desktop-spike.ps1 before the T1115 fix was read from git ($($pre.Count) lines)" ($pre.Count -gt 400)
$preHits = @(Get-PixelOracleFindings -Path 'test-desktop-spike.pre-T1115.ps1' -Text $pre | ForEach-Object { $_ })
Assert "B2 and its whole-window Sample() walk is flagged ($(@($preHits | ForEach-Object { 'L' + $_.Line }) -join ','))" (
    @($preHits | Where-Object { $_.Kind -eq 'whole-capture' -and $_.Detail -match 'sum \+=' }).Count -ge 1)
$now = @(Get-Content -LiteralPath (Join-Path $Root 'test-desktop-spike.ps1'))
$nowHits = @(Get-PixelOracleFindings -Path 'test-desktop-spike.ps1' -Text $now | ForEach-Object { $_ })
AssertEq 'B3 the file as it stands now (scored by region through SampleRect) has no finding' 0 $nowHits.Count

# ===========================================================================
Write-Host ''
Write-Host '== C: the ratchet over test\win32'
# ===========================================================================

$all = @(Get-PixelOracleSweep -Roots @($Root) | ForEach-Object { $_ })
$hard = @($all | Where-Object { $_.Kind -eq 'whole-capture' })
$current = @{}
foreach ($x in $hard) {
    $rel = Get-PixelOracleRelativePath -Path $x.Path -Repo $Repo
    if (-not $current.ContainsKey($rel)) { $current[$rel] = 0 }
    $current[$rel] = $current[$rel] + 1
}

if ($UpdateBaseline) {
    $obj = [ordered]@{
        note      = 'Per-file counts of pixel-oracle-audit findings: two nested full-axis loops whose body accumulates (a mean, a count, a colour set). Every site here was read by the T1281 sweep (2026-10-24) and is SOUND - its w/h are a crop''s own size, or the capture is a window that is itself the subject. May only go DOWN; a new walk bounds its region or carries # pixel-region: <reason>. See docs/design/windows-parity-tasks/T1281.md.'
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

$cmp = Compare-PixelOracleBaseline -Current $current -Baseline $baseFiles
foreach ($r in $cmp.Regressed) { Write-Host "      NEW: $r" -ForegroundColor Red }
if (@($cmp.Regressed).Count -gt 0) {
    foreach ($x in $hard) {
        $rel = Get-PixelOracleRelativePath -Path $x.Path -Repo $Repo
        if (@($cmp.Regressed | Where-Object { $_.StartsWith("$rel ") }).Count -gt 0) {
            Write-Host "      $rel`:$($x.Line) $($x.Detail)"
            Write-Host '        -> score the subject''s own region (and keep a second region as the positive control), or say why the whole capture is right: # pixel-region: <reason>'
        }
    }
}
AssertEq 'C1 no file has gained a whole-capture aggregate' 0 @($cmp.Regressed).Count
foreach ($i in $cmp.Improved) { Write-Host "      FIXED: $i" }
Assert 'C2 the baseline matches the tree (-UpdateBaseline in the commit that removes a site)' (
    @($cmp.Improved).Count -eq 0)
$unb = @($all | Where-Object { $_.Kind -eq 'unbalanced' })
foreach ($x in $unb) { Write-Host "      $(Get-PixelOracleRelativePath $x.Path $Repo):$($x.Line) $($x.Detail)" -ForegroundColor Red }
AssertEq 'C3 no full-axis walk in the tree is unreadable' 0 $unb.Count

# ===========================================================================
Write-Host ''
Write-Host '== D: scope'
# ===========================================================================

$ps1Count = @(Get-ChildItem -LiteralPath $Root -Filter *.ps1 -File -Recurse).Count
$libCount = @(Get-ChildItem -LiteralPath (Join-Path $Root 'lib') -Filter *.ps1 -File).Count
Assert "D1 the sweep walked test\win32 ($ps1Count .ps1 files, $libCount of them in lib\)" (
    $ps1Count -ge 300 -and $libCount -ge 20)
# The pixel-API names are split so foreground-audit does not read this filter
# as a screen read of our own.
$pixelApis = 'GetPixel|Get-TestPixel|CopyFrom' + 'Screen|PrintWindow'
$pixelFiles = @(Get-ChildItem -LiteralPath $Root -Filter *.ps1 -File -Recurse |
    Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match $pixelApis }).Count
Assert "D2 and it had something to read: $pixelFiles script(s) read pixels" ($pixelFiles -ge 50)

# ===========================================================================
Write-Host ''
Write-Host '== T: the teeth (C1 must be able to score red)'
# ===========================================================================

$fakeRoot = Join-Path $tmp 'test\win32'
New-Item -ItemType Directory -Force $fakeRoot | Out-Null
Set-Content -LiteralPath (Join-Path $fakeRoot 'planted-mean.ps1') -Encoding ascii -Value @(
    'for ($y = 0; $y -lt $shot.Height; $y += 4) {',
    '    for ($x = 0; $x -lt $shot.Width; $x += 4) { $sum += $shot.Bitmap.GetPixel($x, $y).R }',
    '}')
$planted = @(Get-PixelOracleSweep -Roots @($fakeRoot) | ForEach-Object { $_ })
Assert 'T1 a whole-capture mean planted in a scratch file under a swept tree is flagged' (
    $planted.Count -eq 1 -and $planted[0].Kind -eq 'whole-capture')
$withPlant = @{}
foreach ($k in $current.Keys) { $withPlant[$k] = $current[$k] }
$withPlant['test\win32\planted-mean.ps1'] = 1
$cmpT = Compare-PixelOracleBaseline -Current $withPlant -Baseline $baseFiles
Assert 'T2 and the ratchet fails on it - a new file cannot arrive excused' (
    @($cmpT.Regressed | Where-Object { $_ -like 'test\win32\planted-mean.ps1 *' }).Count -eq 1)
$oneMore = @{}
foreach ($k in $current.Keys) { $oneMore[$k] = $current[$k] }
$anyKey = @($baseFiles.Keys | Sort-Object)[0]
if ($anyKey) { $oneMore[$anyKey] = $baseFiles[$anyKey] + 1 }
$cmpU = Compare-PixelOracleBaseline -Current $oneMore -Baseline $baseFiles
Assert "T3 and one more site in a baselined file fails too ($anyKey)" (
    $anyKey -and @($cmpU.Regressed | Where-Object { $_ -like "$anyKey *" }).Count -eq 1)

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

Complete-TestBody  # T1039: the run reached the end of its body

# --- stamp (T783) ----------------------------------------------------------
if ($script:fail -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard pixel-oracle -Repo $Repo 2>&1 |
        ForEach-Object { Write-Host "  $($_.ToString())" }
}

Write-Host ''
Write-Host "  sweep: $ps1Count script(s); $($hard.Count) whole-capture aggregate walk(s) across $($current.Keys.Count) file(s) (baseline: SOUND sites read by T1281)"
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Label 'PIXEL ORACLE AUDIT' -MinPass 20
