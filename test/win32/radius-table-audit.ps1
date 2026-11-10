<#
.SYNOPSIS
    T1399 acceptance - the design system's corner-radius table and the win32
    code agree, in both directions.

.DESCRIPTION
    THE DEFECT: docs\design\win32-design-system.md section 3.1 said cards and
    overlays round at 8 DIP. Every glass card on screen - the banner, the viewer
    TOC card, the find card - drew at banner_card.RADIUS, 14, which is Mac's
    GlassCard.cornerRadius and what the Windows card was built to match. The
    table is what a future change is checked against, and it had been wrong
    for two months because nothing executed it. Its tab row (6) was stale too
    (tab_shape draws 7), and it never named the 10 and 11 DIP radii at all.

    The table now carries a Source column naming the constants each row
    governs, and this run holds the two sides together
    (`lib\RadiusTableAudit.ps1` holds the analyzer):

      A. The analyzer against fixtures, both directions: the table parser reads
         values and refs, the declaration scan finds corner radii and skips
         blur/glow names, comments, strings and test blocks.

      B. Table -> code: every constant the table names exists in
         src\apprt\win32\ and holds its row's value.

      C. Code -> table: every corner-radius constant in src\apprt\win32\ is
         named by a row, or declared in $Allow below with its reason (and an
         $Allow entry that no longer matches anything fails, so fixing a site
         obliges removing it).

      D. The teeth (T1133): the table as T1399 found it - 8 DIP for the glass
         cards - put back in a scratch copy fails B on banner_card.RADIUS; a
         planted unnamed radius constant fails C.

      E. The scan is not passing because it recognises nothing: it judged the
         rows and the declarations it exists to judge.

    One ALL PASS / N FAILURE(S) line last, per the house convention.

.NOTES
    # persistence: launches no GUI - this reads source files and one markdown
    # document, it does not build or run anything.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
$Repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\RadiusTableAudit.ps1')

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

# The DECLARED exceptions: a corner-radius constant in the win32 tree that no
# row of the table names, with why. An entry is `module.Name`.
$Allow = @(
    # Mac's `shadowRadius` for a stacked card - a Gaussian blur radius whose
    # name says "card", not a corner. Its blade sibling is skipped by name.
    'blade_shadow.card_radius_dip'
)

$docPath = Join-Path $Repo 'docs\design\win32-design-system.md'
$win32Root = Join-Path $Repo 'src\apprt\win32'
$tmp = Join-Path $env:TEMP "ghoztty-t1399-$PID"
if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force $tmp | Out-Null

# ===========================================================================
Write-Host ''
Write-Host '== A: the analyzer, both directions'
# ===========================================================================

$fixtureDoc = @'
## 3. Shape

### 3.1 Corner radius

| Radius | Applies to | Source |
|---|---|---|
| **4 DIP** | Small things | `a.SMALL` `b.chip_radius` |
| **14 DIP** | Glass cards | `card.RADIUS` |
| **0** | Full bleed | |

Nothing else.

| **99 DIP** | a table after the prose is not this table | `x.Y` |

### 3.2 Elevation
'@ -split "`n" | ForEach-Object { $_.TrimEnd("`r") }
$rows = @(Get-RadiusTable -Lines $fixtureDoc)
AssertEq 'A1 three rows read from the fixture table (the later table is not section 3.1)' 3 $rows.Count
AssertEq 'A2 the 14 DIP row names card.RADIUS' 'card.RADIUS' (@($rows | Where-Object { $_.Value -eq 14 })[0].Refs -join ',')
AssertEq 'A3 a row can name two refs' 2 @($rows | Where-Object { $_.Value -eq 4 })[0].Refs.Count
AssertEq 'A4 the full-bleed row reads as 0 with no refs' 0 @($rows | Where-Object { $_.Value -eq 0 })[0].Refs.Count
AssertEq 'A5 a document without section 3.1 has no table' 0 @(Get-RadiusTable -Lines @('# nothing', '| **8 DIP** | x | `a.B` |')).Count

$zig = @'
pub const RADIUS: f32 = 14.0;
const chip_radius_dip: f32 = 4;
    pub const card_radius = 8;
pub const CORNER_TOP: f32 = 7.0;
pub const glow_radius_dip: f32 = 5;
pub const shadow_radius_dip: f32 = 6;
const SHEEN_RADIUS: f32 = 1.15;
const slot_dcomp_rect_clip_first_radius = 12;
pub const MARGIN: f32 = 12.0;
pub const radius_from = other.RADIUS;
// pub const OLD_RADIUS: f32 = 8.0;
const msg = "const RADIUS: f32 = 3;";
test "a fixture" {
    const radius: f32 = 17;
    {
        const corner: f32 = 2;
    }
}
const after_test_radius: f32 = 9;
'@ -split "`n" | ForEach-Object { $_.TrimEnd("`r") }
$d = @(Get-RadiusDecls -Module 'fx' -Text $zig)
$names = ($d | ForEach-Object { $_.Name }) -join ','
AssertEq 'A6 corner radii found; blur/glow/sheen/slot names, non-radius names, derived values, comments, strings and test blocks are not' 'RADIUS,chip_radius_dip,card_radius,CORNER_TOP,after_test_radius' $names
AssertEq 'A7 the value is read as a number' 14 @($d | Where-Object { $_.Name -eq 'RADIUS' })[0].Value
AssertEq 'A8 a declaration is addressed as module.Name' 'fx.card_radius' @($d | Where-Object { $_.Name -eq 'card_radius' })[0].Ref

$fxRows = @([pscustomobject]@{ Value = 14; Refs = @('fx.RADIUS', 'fx.gone') }, [pscustomobject]@{ Value = 8; Refs = @('fx.CORNER_TOP') })
$mm = @(Get-RadiusMismatches -Rows $fxRows -Decls $d)
AssertEq 'A9 a missing ref and a wrong value are both reported, a right one is not' 'fx.gone:missing,fx.CORNER_TOP:value' (($mm | ForEach-Object { "$($_.Ref):$($_.Kind)" }) -join ',')
$un = @(Get-RadiusUnnamed -Rows $fxRows -Decls $d)
AssertEq 'A10 the declarations no row names are reported' 'chip_radius_dip,card_radius,after_test_radius' (($un | ForEach-Object { $_.Name }) -join ',')

# ===========================================================================
Write-Host ''
Write-Host '== B: table -> code'
# ===========================================================================

$docLines = [System.IO.File]::ReadAllLines($docPath)
$table = @(Get-RadiusTable -Lines $docLines)
$sweep = @(Get-RadiusSweep -Root $win32Root)
$mism = @(Get-RadiusMismatches -Rows $table -Decls $sweep)
foreach ($m in $mism) {
    Write-Host "    $($m.Ref): $($m.Kind) (row $($m.Row) DIP, code $($m.Actual))" -ForegroundColor Red
}
AssertEq 'B1 every constant the table names exists and holds its row''s value' 0 $mism.Count
foreach ($r in $table) {
    if ($r.Value -ne 0) {
        Assert "B2 the $($r.Value) DIP row names at least one source constant" ($r.Refs.Count -ge 1)
    }
}
$vals = @($table | Where-Object { $_.Value -ne 0 } | ForEach-Object { $_.Value })
AssertEq 'B3 the rounded rows ascend with no repeats, so the scale reads as one ladder (full bleed sits last)' (($vals | Sort-Object -Unique) -join ',') ($vals -join ',')
$glass = @($table | Where-Object { $_.Refs -ccontains 'banner_card.RADIUS' })
Assert 'B4 the glass-card row is the 14 DIP row (Mac GlassCard.cornerRadius)' ($glass.Count -eq 1 -and $glass[0].Value -eq 14)
$elev = @($table | Where-Object { $_.Refs -ccontains 'pane_elevation.CORNER_RADIUS_DIP' })
Assert 'B5 the elevated pane row is the 11 DIP row (Mac PaneElevation.cornerRadius)' ($elev.Count -eq 1 -and $elev[0].Value -eq 11)

# ===========================================================================
Write-Host ''
Write-Host '== C: code -> table'
# ===========================================================================

$unnamed = @(Get-RadiusUnnamed -Rows $table -Decls $sweep | Where-Object { $Allow -cnotcontains $_.Ref })
foreach ($u in $unnamed) {
    Write-Host "    $($u.Module).zig:$($u.Line) $($u.Name) = $($u.Value) is on no row of section 3.1" -ForegroundColor Red
}
AssertEq 'C1 every corner-radius constant in the win32 tree is on the table or declared' 0 $unnamed.Count
foreach ($a in $Allow) {
    Assert "C2 the declared exception $a still matches a site" (@($sweep | Where-Object { $_.Ref -ceq $a }).Count -ge 1)
}
$named = @($table | ForEach-Object { $_.Refs })
$both = @($Allow | Where-Object { $named -ccontains $_ })
AssertEq 'C3 no declared exception is also on the table' 0 $both.Count

# ===========================================================================
Write-Host ''
Write-Host '== D: the teeth'
# ===========================================================================

# The table as T1399 found it: the glass cards at 8. Put that value back on the
# glass-card row of a scratch copy and B must name banner_card.RADIUS.
$bad = $docLines | ForEach-Object {
    if ($_ -match '^\|\s*\*\*14 DIP\*\*') { $_ -replace '\*\*14 DIP\*\*', '**8 DIP**' } else { $_ }
}
$badMism = @(Get-RadiusMismatches -Rows @(Get-RadiusTable -Lines $bad) -Decls $sweep)
Assert "D1 the glass cards back at 8 DIP fail B on banner_card.RADIUS ($(($badMism | ForEach-Object { $_.Ref }) -join ','))" (
    $badMism.Count -eq 1 -and $badMism[0].Ref -eq 'banner_card.RADIUS' -and $badMism[0].Kind -eq 'value' -and $badMism[0].Actual -eq 14)

# A new card with its own hand-picked radius, in a scratch copy of a real module.
$plantRoot = Join-Path $tmp 'plant'
New-Item -ItemType Directory -Force $plantRoot | Out-Null
$src = [System.IO.File]::ReadAllText((Join-Path $win32Root 'readonly_badge.zig'))
[System.IO.File]::WriteAllText((Join-Path $plantRoot 'readonly_badge.zig'), ($src + "`npub const POPOVER_RADIUS: f32 = 12.0;`n"))
$planted = @(Get-RadiusUnnamed -Rows $table -Decls @(Get-RadiusSweep -Root $plantRoot) | Where-Object { $Allow -cnotcontains $_.Ref })
Assert "D2 a planted unnamed radius (POPOVER_RADIUS = 12) fails C ($(($planted | ForEach-Object { $_.Ref }) -join ','))" (
    $planted.Count -eq 1 -and $planted[0].Ref -eq 'readonly_badge.POPOVER_RADIUS')

# And a row that names a constant the code renamed away.
$renamed = $src -replace 'pub const RADIUS: f32', 'pub const CARD_R: f32'
[System.IO.File]::WriteAllText((Join-Path $plantRoot 'readonly_badge.zig'), $renamed)
$gone = @(Get-RadiusMismatches -Rows $table -Decls @(Get-RadiusSweep -Root $plantRoot) | Where-Object { $_.Ref -eq 'readonly_badge.RADIUS' })
Assert 'D3 a constant renamed away fails B as missing' ($gone.Count -eq 1 -and $gone[0].Kind -eq 'missing')

# ===========================================================================
Write-Host ''
Write-Host '== E: the scan saw what it judges'
# ===========================================================================

Assert "E1 at least 7 rows read from section 3.1 ($($table.Count))" ($table.Count -ge 7)
Assert "E2 at least 18 source refs checked ($($named.Count))" ($named.Count -ge 18)
Assert "E3 at least 18 corner-radius declarations judged ($($sweep.Count))" ($sweep.Count -ge 18)
foreach ($want in @('banner_card.RADIUS', 'tab_shape.CORNER_TOP', 'pane_elevation.CORNER_RADIUS_DIP', 'settings_window_layout.card_radius')) {
    Assert "E the scan judged $want" (@($sweep | Where-Object { $_.Ref -ceq $want }).Count -eq 1)
}

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

Complete-TestBody  # T1039: the run reached the end of its body

# --- stamp (T783) ----------------------------------------------------------
if ($script:fail -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard radius-table -Repo $Repo 2>&1 |
        ForEach-Object { Write-Host "  $($_.ToString())" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Label 'RADIUS TABLE AUDIT' -MinPass 25
