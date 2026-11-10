<#
.SYNOPSIS
    T1389 acceptance - no win32 UI module writes a font height the type ramp
    does not name, unless the exception is declared here with its reason.

.DESCRIPTION
    THE DEFECT: T310 counted seven copies of `px(15, scale)` by grep and T313
    retired them. T583 then found an EIGHTH spelled differently -
    `const FONT_H: f32 = 15.0` in BannerOverlay.zig - which the grep had walked
    straight past and which sat on the most-looked-at surface in the app for
    three weeks. The lesson is not that the count was wrong; it is that the
    count was a one-time grep, so nothing would notice a ninth. This run is the
    count, every time the win32 frontend changes (`lib\TypeRampAudit.ps1` holds
    the analyzer and the shapes it reads).

    Sections:

      A. The analyzer against fixtures, BOTH directions: each ramp-derived shape
         yields nothing, each hand-written off-ramp shape is reported by kind,
         and comments, strings, test blocks, switch arms and scale arguments
         are not sizes.

      B. The ramp is read from type_ramp.zig itself (12 / 14 / 20), so the
         audit cannot drift from the module it enforces.

      C. The win32 frontend as it stands: every off-ramp site is declared in
         $Allow below with its reason, and every $Allow entry still matches a
         site (a stale entry fails, so fixing a site obliges removing it).

      D. The teeth, on the REAL history (T1133): BannerOverlay.zig as it stood
         before T583 (`6463d0d10^`) is read back out of git and its FONT_H 15
         must be reported off-ramp. And a planted ninth size in a scratch copy
         of the tree must fail the allowlist check.

      E. The scan is not passing because it recognises nothing: it judged the
         CreateFontW sites and font-size declarations it exists to judge.

    One ALL PASS / N FAILURE(S) line last, per the house convention.

.NOTES
    # persistence: launches no GUI - this reads source files (and one historical
    # blob through `git show`), it does not build or run anything.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
$Repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\TypeRampAudit.ps1')

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

# The DECLARED exceptions. A size the ramp does not name is allowed only here,
# with the file, the exact expression the analyzer reports, and why. An entry
# that names a follow-up task is a known defect waiting on that task, not a
# licence: the task removes the entry, and C fails on an entry that no longer
# matches anything.
$Allow = @(
    [pscustomobject]@{ File = 'icon_button_paint.zig'; Detail = '-16'
        Why = 'a face-presence probe: the font is created to ask whether the icon face is installed and is never drawn' }
    [pscustomobject]@{ File = 'pane_drag_ghost.zig'; Detail = '10'
        Why = 'the drag ghost title matches the Mac card (10 pt semibold system font) on a thumbnail-sized card' }
    [pscustomobject]@{ File = 'Surface.zig'; Detail = '-@as(i32, @intFromFloat(@round(13.0 * s)))'
        Why = 'pending T2885: the link preview predates the ramp' }
    [pscustomobject]@{ File = 'Surface.zig'; Detail = '-@as(i32, @intFromFloat(@round(16.0 * s)))'
        Why = 'pending T2885: the find bar and palette input boxes predate the ramp' }
)
function Test-Allowed($Finding) {
    $leaf = Split-Path $Finding.Path -Leaf
    foreach ($a in $Allow) {
        if ($a.File -ieq $leaf -and $a.Detail -eq $Finding.Detail) { return $true }
    }
    return $false
}

function Fixture([string]$Body) {
    return @(Get-TypeRampFindings -Path 'fixture.zig' -Text ($Body -split "`n") -Ramp @(12, 14, 20))
}
function KindsOf($Findings) { return (@($Findings | ForEach-Object { $_.Kind }) -join ',') }

$tmp = Join-Path $env:TEMP "ghoztty-t1389-$PID"
if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force $tmp | Out-Null

# ===========================================================================
Write-Host ''
Write-Host '== A: the analyzer, both directions'
# ===========================================================================

$good = @'
const FONT_H: f32 = banner_layout.body_dip;
const font_h = type_ramp.body(scale).height;
self.font = w32.CreateFontW(
    -type_ramp.caption(scale).height,
    0, 0, 0, 400, 0, 0, 0, 0, 0, 0, 0, 0, face);
const f2 = w32.CreateFontW(-l.font_h, 0, 0, 0, 600, 0, 0, 0, 0, 0, 0, 0x01 | 0x30, face);
const font_px = @max(1, px(w, ts));
const font_px = px(FONT_PX, 1.5);
.font_px = @as(f32, @floatFromInt(body.height)) / scale,
self.row_font = w32.CreateFontW(-row_ramp.height, 0, 0, 0, 400, 0, 0, 0, 0, 0, 0, 0, 0, face);
'@
$f = @(Fixture $good)
AssertEq "A1 ramp-derived sizes, names and scale arguments yield nothing ($(KindsOf $f))" 0 $f.Count

$f = @(Fixture 'const FONT_H: f32 = 15.0;')
Assert 'A2 the T583 shape - a FONT_H constant at 15 - is off-ramp' ($f.Count -eq 1 -and $f[0].Kind -eq 'off-ramp' -and $f[0].Values -eq '15')
$f = @(Fixture 'const font_h = px(15, scale);')
Assert 'A3 the T310 shape - font_h = px(15, scale) - is off-ramp' ($f.Count -eq 1 -and $f[0].Kind -eq 'off-ramp')
$f = @(Fixture "self.link_font = w32.CreateFontW(`n    -@as(i32, @intFromFloat(@round(13.0 * s))),`n    0,`n);")
Assert 'A4 a literal height in a multi-line CreateFontW is off-ramp' ($f.Count -eq 1 -and $f[0].Kind -eq 'off-ramp' -and $f[0].Site -eq 'createfont')
$f = @(Fixture 'const font = w32.CreateFontW(-15, 0, 0, 0, 400, 0, 0, 0, 0, 0, 0, 0, 0, L("Segoe UI"));')
Assert 'A5 a bare literal height on one line is off-ramp, and its flag arguments are not sizes' ($f.Count -eq 1 -and $f[0].Values -eq '15')
$f = @(Fixture 'pub const FONT_PX: f32 = 12.0;')
Assert 'A6 a hand-written 12 is hand-ramp (informational), not off-ramp' ($f.Count -eq 1 -and $f[0].Kind -eq 'hand-ramp')
AssertEq 'A7 hand-ramp is not a hard kind' $false ((Get-TypeRampHardKinds) -contains 'hand-ramp')
$f = @(Fixture 'pub const title_font_dip: f32 = 10;')
Assert 'A8 a *_font_dip constant is a font-size name' ($f.Count -eq 1 -and $f[0].Kind -eq 'off-ramp')
$f = @(Fixture 'title_h: i32 = 19,')
AssertEq 'A9 a layout row height (title_h) is not a font size by name' 0 $f.Count
$f = @(Fixture "// const FONT_H: f32 = 15.0;`nconst msg = `"font_h = 15`";")
AssertEq 'A10 a size in a comment or a string is not a site' 0 $f.Count
$f = @(Fixture "test `"a fixture`" {`n    const font = w32.CreateFontW(-15, 0, 0, 0, 400, 0, 0, 0, 0, 0, 0, 0, 0, face);`n    const FONT_H: f32 = 15.0;`n}`nconst FONT_H: f32 = 16.0;")
Assert "A11 a test block is skipped, and the scan resumes after it ($(KindsOf $f))" ($f.Count -eq 1 -and $f[0].Line -eq 5)
$f = @(Fixture '    .increase_font_size => d(.font, "Bigger Text", "x", true, "increase_font_size:1"),')
AssertEq 'A12 a switch arm (=>) is not a declaration' 0 $f.Count
$f = @(Fixture 'pub const FONT_PX: f32 = 12.5;')
Assert 'A13 a fractional size beside a ramp size is off-ramp' ($f.Count -eq 1 -and $f[0].Kind -eq 'off-ramp')

# ===========================================================================
Write-Host ''
Write-Host '== B: the ramp is read from type_ramp.zig'
# ===========================================================================

$ramp = @(Get-TypeRampSizes -Repo $Repo)
AssertEq 'B1 the ramp is 12 / 14 / 20 (leading_dip is not a size)' '12,14,20' ($ramp -join ',')

# ===========================================================================
Write-Host ''
Write-Host '== C: the win32 frontend as it stands'
# ===========================================================================

$win32Root = Join-Path $Repo 'src\apprt\win32'
$sweep = @(Get-TypeRampSweep -Root $win32Root -Ramp $ramp -IncludeClean)
$hardKinds = @(Get-TypeRampHardKinds)
$hard = @($sweep | Where-Object { $hardKinds -contains $_.Kind })
$undeclared = @($hard | Where-Object { -not (Test-Allowed $_) })
AssertEq 'C1 every off-ramp font size is a declared exception' 0 $undeclared.Count
foreach ($x in $undeclared) {
    Write-Host "      $(Split-Path $x.Path -Leaf):$($x.Line) $($x.Name) = $($x.Detail)  [$($x.Values)]"
}
$stale = @($Allow | Where-Object {
        $a = $_
        @($hard | Where-Object { (Split-Path $_.Path -Leaf) -ieq $a.File -and $_.Detail -eq $a.Detail }).Count -eq 0
    })
AssertEq 'C2 every declared exception still matches a site (remove an entry when its site is fixed)' 0 $stale.Count
foreach ($a in $stale) { Write-Host "      stale: $($a.File) $($a.Detail)" }
AssertEq 'C3 every declared exception states its reason' 0 @($Allow | Where-Object { -not $_.Why -or $_.Why.Length -lt 20 }).Count
$hand = @($sweep | Where-Object { $_.Kind -eq 'hand-ramp' })
Write-Host "  INFO $($hand.Count) hand-written ramp size(s) - right today, wrong the day the ramp moves (T2885):"
foreach ($x in $hand) { Write-Host "      $(Split-Path $x.Path -Leaf):$($x.Line) $($x.Name) = $($x.Detail)" }

# ===========================================================================
Write-Host ''
Write-Host '== D: the teeth'
# ===========================================================================

$preFile = Join-Path $tmp 'BannerOverlay-pre-T583.zig'
$blob = (& git -C $Repo show '6463d0d10^:src/apprt/win32/BannerOverlay.zig' 2>$null | Out-String)
Assert 'D0 the pre-T583 BannerOverlay.zig was read out of history' ($LASTEXITCODE -eq 0 -and $blob.Length -gt 10000)
[System.IO.File]::WriteAllText($preFile, $blob)
$pre = @(Get-TypeRampFindings -Path $preFile -Ramp $ramp | Where-Object { $_.Kind -eq 'off-ramp' })
Assert "D1 the eighth copy T583 found - FONT_H 15 - is reported off-ramp ($(@($pre | ForEach-Object { "$($_.Name)=$($_.Values)" }) -join ', '))" (
    @($pre | Where-Object { $_.Name -eq 'FONT_H' -and $_.Values -eq '15' }).Count -eq 1)

# A ninth: plant one in a scratch copy of a real module and run the C1 check.
$plantRoot = Join-Path $tmp 'plant'
New-Item -ItemType Directory -Force $plantRoot | Out-Null
$src = [System.IO.File]::ReadAllText((Join-Path $win32Root 'RenameDialog.zig'))
[System.IO.File]::WriteAllText((Join-Path $plantRoot 'RenameDialog.zig'), ($src + "`nconst LABEL_FONT_PX: f32 = 15.0;`n"))
$planted = @(Get-TypeRampSweep -Root $plantRoot -Ramp $ramp | Where-Object { $hardKinds -contains $_.Kind -and -not (Test-Allowed $_) })
Assert "D2 a planted ninth size (LABEL_FONT_PX = 15.0) fails the declared-exception check ($($planted.Count))" (
    $planted.Count -eq 1 -and $planted[0].Name -eq 'LABEL_FONT_PX')
[System.IO.File]::WriteAllText((Join-Path $plantRoot 'RenameDialog.zig'), ($src + "`nfn f(s: f32) void { _ = w32.CreateFontW(-@as(i32, @intFromFloat(@round(15.0 * s))), 0); }`n"))
$planted = @(Get-TypeRampSweep -Root $plantRoot -Ramp $ramp | Where-Object { $hardKinds -contains $_.Kind -and -not (Test-Allowed $_) })
Assert "D3 a planted literal CreateFontW height fails it too ($($planted.Count))" ($planted.Count -eq 1 -and $planted[0].Site -eq 'createfont')

# ===========================================================================
Write-Host ''
Write-Host '== E: the scan saw the sites it judges'
# ===========================================================================

$cf = @($sweep | Where-Object { $_.Site -eq 'createfont' })
$decl = @($sweep | Where-Object { $_.Site -eq 'decl' })
Assert "E1 at least 40 CreateFontW heights judged ($($cf.Count))" ($cf.Count -ge 40)
Assert "E2 at least 20 font-size declarations judged ($($decl.Count))" ($decl.Count -ge 20)
$files = @($cf | ForEach-Object { Split-Path $_.Path -Leaf } | Sort-Object -Unique)
foreach ($want in @('BannerDialog.zig', 'MachineChooser.zig', 'Window.zig', 'Surface.zig', 'ViewerNavBar.zig', 'UpdateProgress.zig')) {
    Assert "E judged CreateFontW in $want" ($files -contains $want)
}
Assert 'E the banner''s FONT_H (the T583 site) is judged and clean' (
    @($sweep | Where-Object { (Split-Path $_.Path -Leaf) -eq 'BannerOverlay.zig' -and $_.Name -eq 'FONT_H' -and $_.Kind -eq 'ok' }).Count -eq 1)

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

Complete-TestBody  # T1039: the run reached the end of its body

# --- stamp (T783) ----------------------------------------------------------
if ($script:fail -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard type-ramp -Repo $Repo 2>&1 |
        ForEach-Object { Write-Host "  $($_.ToString())" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Label 'TYPE RAMP AUDIT' -MinPass 25
