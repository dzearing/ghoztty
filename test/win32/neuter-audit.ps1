<#
.SYNOPSIS
    T788 acceptance - every `*_NEUTERED` negative control has a live consumer,
    a shipped-value pin, and a claim naming the script it guards.

.DESCRIPTION
    A `*_NEUTERED` flag is a negative control in source form: flip it to `true`,
    rebuild, and the acceptance script that claims to measure T<id> must go red.
    It is the only thing separating an assertion that MEASURES a fix from one
    that would pass either way.

    It has failed silently twice, both times found by hand:

      * T209, then T283 again - `glyphCentered()` and `icon_button
        .universalHover()` each read their flag, were documented, were
        unit-tested, and had NO consumer on any paint path. Flipping the flag
        changed nothing, so the control adjudicated nothing.

      * T283 - five of the eight flags then in the tree had no shipped-value
        pin, so a flag left `true` by an experiment would have SHIPPED and gone
        red only in an acceptance script somebody remembered to run.

    Both are properties of the tree, and this repo holds properties with an
    analyzer: `ExitCodeAudit`, `SkipAudit`, `VerdictExitAudit`,
    `AssertedNothingAudit`, `ForegroundAudit`. This is the sixth of that
    family, and the first whose subject is Zig source.

    That the sweep was worth automating is not a theory: run against the tree
    the day it was written it found THREE unpinned flags (`T833`, `T1344`,
    `T737`) - all of them added after T283's hand sweep, all of them the exact
    class T283 had just finished fixing by hand a month earlier.

    Sections:

      A. The analyzer against fixtures, both directions: a clean module yields
         nothing, each of the three findings is named by kind, the one-hop
         orphan (flag -> predicate -> nothing but tests) is caught while a live
         predicate is not, and the `// neuter-audit: <reason>` exemption waives
         a flag while a bare marker waives nothing.

      B. The sweep over `src\`. Zero findings, and the flag count reported as a
         number rather than asserted away.

      C. The claim list as a contract: every script a doc comment names exists
         under `test\win32`, and the `Measured <date>` notes are reported with
         their age. The claim is REPORTED rather than measured - flipping a
         flag costs a rebuild and a GUI run apiece - but a claim naming a
         script that no longer exists is a claim nobody can run, and that is
         checkable for free.

      D. `-TeethCheck` only: the negative control this rule is worth nothing
         without. It copies `src\` to a scratch tree, plants one REAL violator
         of each kind into it, and requires the sweep to name each. A copy
         rather than the live tree, so an interrupted run cannot leave a
         wounded source file behind.

    One ALL PASS / N FAILURE(S) line last, per the house convention.

.NOTES
    # isolation: none - this reads source files and (under -TeethCheck) copies
    # them to a scratch directory. It launches no Ghoztty, takes no IPC
    # endpoint, builds nothing, and touches no user state.
    # persistence: launches no GUI.
    # foreground: does not touch the foreground window.
#>
[CmdletBinding()]
param(
    [string]$Repo,
    [switch]$TeethCheck
)

$ErrorActionPreference = 'Continue'
if (-not $Repo) { $Repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\NeuterAudit.ps1')

$script:pass = 0
$script:fail = 0
function Assert([string]$name, [bool]$cond, [string]$detail = '') {
    if ($cond) { Write-Host "  PASS $name"; $script:pass++ }
    else {
        Write-Host ("  FAIL $name" + $(if ($detail) { " -- $detail" } else { '' })) -ForegroundColor Red
        $script:fail++
    }
}

$tmp = Join-Path $env:TEMP "ghoztty-t788-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

function New-Fixture([string]$Name, [string]$Body) {
    $dir = Join-Path $tmp $Name
    New-Item -ItemType Directory -Force $dir | Out-Null
    $p = Join-Path $dir 'mod.zig'
    [System.IO.File]::WriteAllText($p, $Body)
    return $dir
}

function Get-FixtureFindings([string]$Dir) {
    return @(Get-NeuterSweep -Root $Dir -Fresh)
}

function Get-Kinds($findings) { return (@($findings | ForEach-Object { $_.Kind }) | Sort-Object) -join ',' }

# ===========================================================================
'== A: the analyzer, against fixtures'
# ===========================================================================

# A clean control: doc comment naming a script, a predicate the paint path
# calls, and a pin. This is the shape all twelve flags in the tree have.
$clean = @'
const std = @import("std");
const testing = std.testing;

/// Negative control for `pane-banner.ps1`'s T999 assertions. Flipping it
/// restores the pre-T999 world. (Measured 2026-09-16: 3 FAILED / 40 passed.)
const T999_NEUTERED = false;

fn wrapWidth(w: i32) i32 {
    return if (T999_NEUTERED) 0 else w;
}

pub fn paint(w: i32) i32 {
    return wrapWidth(w);
}

test "T999 ships clear" {
    try testing.expect(!T999_NEUTERED);
    try testing.expectEqual(@as(i32, 7), paint(7));
}
'@
$fClean = Get-FixtureFindings (New-Fixture 'clean' $clean)
Assert 'A1 a clean control yields no finding' (@($fClean).Count -eq 0) ("named: " + (Get-Kinds $fClean))

# `no-consumer`, the one-hop shape. `wrapWidth` reads the flag and nothing but
# a test calls `wrapWidth` - which is precisely `universalHover` after T282
# moved its call sites away. A grep for the FLAG sees a production reference
# and reports nothing.
$orphan = $clean.Replace(@'
pub fn paint(w: i32) i32 {
    return wrapWidth(w);
}
'@, @'
pub fn paint(w: i32) i32 {
    return w;
}
'@)
$fOrphan = Get-FixtureFindings (New-Fixture 'orphan' $orphan)
Assert 'A2 a predicate nothing but tests calls is no-consumer' `
    ((Get-Kinds $fOrphan) -eq 'no-consumer') ("named: " + (Get-Kinds $fOrphan))
Assert 'A2b the finding names the orphaned predicate' `
    (@($fOrphan)[0].Detail -like '*wrapWidth*') ("detail: " + @($fOrphan)[0].Detail)

# The degenerate case of the same finding: no production reference at all.
$testOnly = $clean.Replace('    return if (T999_NEUTERED) 0 else w;', '    return w;')
$fTestOnly = Get-FixtureFindings (New-Fixture 'testonly' $testOnly)
Assert 'A3 a flag referenced only from tests is no-consumer' `
    ((Get-Kinds $fTestOnly) -eq 'no-consumer') ("named: " + (Get-Kinds $fTestOnly))

# `unpinned` - the T283 finding, and the one the tree was actually carrying.
$unpinned = $clean.Replace('    try testing.expect(!T999_NEUTERED);' + "`r`n", '').Replace('    try testing.expect(!T999_NEUTERED);' + "`n", '')
$fUnpinned = Get-FixtureFindings (New-Fixture 'unpinned' $unpinned)
Assert 'A4 a flag with no shipped-value pin is unpinned' `
    ((Get-Kinds $fUnpinned) -eq 'unpinned') ("named: " + (Get-Kinds $fUnpinned))

# `no-claim` - the doc comment names no script, so there is nothing to run
# against a flipped flag and the control cannot be audited by a human either.
$noClaim = $clean.Replace("/// Negative control for ``pane-banner.ps1``'s T999 assertions. Flipping it", '/// Negative control for the T999 assertions. Flipping it')
$fNoClaim = Get-FixtureFindings (New-Fixture 'noclaim' $noClaim)
Assert 'A5 a declaration naming no script is no-claim' `
    ((Get-Kinds $fNoClaim) -eq 'no-claim') ("named: " + (Get-Kinds $fNoClaim))

# All three at once, so a fixture cannot pass by the analyzer stopping early.
$allThree = $noClaim.Replace('    return if (T999_NEUTERED) 0 else w;', '    return w;')
$allThree = $allThree.Replace('    try testing.expect(!T999_NEUTERED);' + "`r`n", '').Replace('    try testing.expect(!T999_NEUTERED);' + "`n", '')
$fAll = Get-FixtureFindings (New-Fixture 'allthree' $allThree)
Assert 'A6 all three kinds are reported together' `
    ((Get-Kinds $fAll) -eq 'no-claim,no-consumer,unpinned') ("named: " + (Get-Kinds $fAll))

# The stated-intent exemption, both directions.
$waived = $allThree.Replace('const T999_NEUTERED = false;', 'const T999_NEUTERED = false; // neuter-audit: fixture, deliberately bare')
$fWaived = Get-FixtureFindings (New-Fixture 'waived' $waived)
Assert 'A7 a reasoned neuter-audit marker waives the flag' (@($fWaived).Count -eq 0) `
    ("named: " + (Get-Kinds $fWaived))

$bare = $allThree.Replace('const T999_NEUTERED = false;', 'const T999_NEUTERED = false; // neuter-audit:')
$fBare = Get-FixtureFindings (New-Fixture 'bare' $bare)
Assert 'A8 a bare marker with no reason waives nothing' (@($fBare).Count -eq 3) `
    ("named: " + (Get-Kinds $fBare))

# A predicate called from ANOTHER module is live. This is the case a
# single-file analyzer would get wrong, and `applySticky` (read by
# `Window.zig`, declared in `tab_strip_layout.zig`) is the real one.
$crossDir = New-Fixture 'cross' $orphan
[System.IO.File]::WriteAllText((Join-Path $crossDir 'caller.zig'), @'
const mod = @import("mod.zig");

pub fn draw(w: i32) i32 {
    return mod.wrapWidth(w);
}
'@)
$fCross = Get-FixtureFindings $crossDir
Assert 'A9 a predicate another module calls is live' (@($fCross).Count -eq 0) `
    ("named: " + (Get-Kinds $fCross))

# ===========================================================================
'== B: the sweep - src\ is at zero'
# ===========================================================================

$srcRoot = Join-Path $Repo 'src'
$sweep = @(Get-NeuterSweep -Root $srcRoot -Fresh)
foreach ($f in $sweep) {
    Write-Host ("  FOUND {0}:{1} {2} {3} -- {4}" -f `
        (Get-NeuterRelativePath $f.Path $Repo), $f.Line, $f.Flag, $f.Kind, $f.Detail)
}
Assert 'B1 no *_NEUTERED flag in src\ is unconsumed, unpinned or unclaimed' ($sweep.Count -eq 0) `
    ("$($sweep.Count) finding(s) above")

$inv = @(Get-NeuterInventory -Root $srcRoot -Fresh)
Assert "B2 the sweep found the tree's negative controls ($($inv.Count))" ($inv.Count -ge 10) `
    "found $($inv.Count)"

# A sweep that looked at no file cannot report zero findings honestly. The
# `AssertedNothing` failure mode (T271), stated as a positive number.
$modules = @($inv | ForEach-Object { Get-NeuterRelativePath $_.Path $Repo } | Sort-Object -Unique)
Assert "B3 the controls span more than one module ($($modules.Count))" ($modules.Count -ge 3) `
    ("modules: " + ($modules -join ', '))

# ===========================================================================
'== C: the claim list is a contract'
# ===========================================================================

$missingClaim = New-Object System.Collections.ArrayList
$measuredCount = 0
foreach ($i in $inv) {
    foreach ($c in @($i.Claims)) {
        if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $c))) {
            [void]$missingClaim.Add("$($i.Flag) -> $c")
        }
    }
    if ($i.Measured) { $measuredCount++ }
}
Assert 'C1 every script a control claims exists under test\win32' ($missingClaim.Count -eq 0) `
    (($missingClaim -join '; '))

# Reported, not enforced: what a flag's last real measurement was. T283 had to
# read five task files to learn this. Enforcing an age here would mean a
# rebuild and a GUI acceptance run per flag on every sweep, which is why the
# task filed it as "consider" rather than as a fourth finding.
foreach ($i in ($inv | Sort-Object Flag)) {
    $m = if ($i.Measured) {
        if ($i.Measured.Date) {
            "{0} ({1}d ago)" -f $i.Measured.Text, [int]((Get-Date) - $i.Measured.Date).TotalDays
        } else { $i.Measured.Text }
    } else { 'never recorded' }
    Write-Host ("  NOTE {0} guards [{1}] - {2}" -f $i.Flag, (@($i.Claims) -join ', '), $m)
}
Write-Host ("  NOTE $measuredCount of $($inv.Count) controls carry a Measured date")

# ===========================================================================
if ($TeethCheck) {
    '== D: the negative control - plant a violator of each kind, sweep must find it'
    # =======================================================================
    # Against a COPY of the tree. The live source is never edited, so an
    # interrupted run cannot leave a wounded module behind - which matters
    # more here than usual, because a wounded *_NEUTERED module is exactly the
    # state this audit exists to detect and it would look like a real finding.
    $copy = Join-Path $tmp 'srccopy'
    Copy-Item -Recurse -Force -LiteralPath $srcRoot -Destination $copy
    Assert 'D1 the scratch copy of src\ is clean to start with' `
        (@(Get-NeuterSweep -Root $copy -Fresh).Count -eq 0)

    $bannerPath = Join-Path $copy 'apprt\win32\BannerOverlay.zig'
    $tslPath = Join-Path $copy 'apprt\win32\tab_strip_layout.zig'

    # unpinned: remove T758's pin. Exactly the state the tree was in for
    # T833/T1344 when this audit was written.
    $orig = [System.IO.File]::ReadAllText($bannerPath)
    $wounded = $orig.Replace("    try std.testing.expect(!T758_NEUTERED);`r`n", '').Replace("    try std.testing.expect(!T758_NEUTERED);`n", '')
    Assert 'D2 the unpinned wound applied' ($wounded -ne $orig)
    [System.IO.File]::WriteAllText($bannerPath, $wounded)
    $d = @(Get-NeuterSweep -Root $copy -Fresh)
    Assert 'D3 removing a pin is reported as unpinned' `
        (@($d | Where-Object { $_.Flag -eq 'T758_NEUTERED' -and $_.Kind -eq 'unpinned' }).Count -eq 1) `
        ("named: " + (Get-Kinds $d))
    [System.IO.File]::WriteAllText($bannerPath, $orig)

    # no-claim: strip the script name out of T206's doc comment.
    $shapePath = Join-Path $copy 'apprt\win32\tab_shape.zig'
    $origShape = [System.IO.File]::ReadAllText($shapePath)
    $woundedShape = $origShape.Replace('tab-strip.ps1', 'the acceptance script')
    Assert 'D4 the no-claim wound applied' ($woundedShape -ne $origShape)
    [System.IO.File]::WriteAllText($shapePath, $woundedShape)
    $d = @(Get-NeuterSweep -Root $copy -Fresh)
    Assert 'D5 a doc comment naming no script is reported as no-claim' `
        (@($d | Where-Object { $_.Flag -eq 'T206_NEUTERED' -and $_.Kind -eq 'no-claim' }).Count -eq 1) `
        ("named: " + (Get-Kinds $d))
    [System.IO.File]::WriteAllText($shapePath, $origShape)

    # no-consumer, the one-hop shape: orphan `freezeActive`, the predicate that
    # reads T737, by rewriting its one production call site to the raw value.
    # `applySticky` keeps its own T737 reference, so this also proves the
    # analyzer judges each reference rather than stopping at the first.
    $origTsl = [System.IO.File]::ReadAllText($tslPath)
    $woundedTsl = $origTsl.Replace('    const frozen = freeze and !T737_NEUTERED;', '    const frozen = freeze;')
    $woundedTsl = $woundedTsl.Replace('    if (T249_NEUTERED) return prefer[0..n];', '    if (false) return prefer[0..n];')
    Assert 'D6 the no-consumer wound applied' ($woundedTsl -ne $origTsl)
    [System.IO.File]::WriteAllText($tslPath, $woundedTsl)
    $d = @(Get-NeuterSweep -Root $copy -Fresh)
    Assert 'D7 a flag whose only consumer is the pin test is no-consumer' `
        (@($d | Where-Object { $_.Flag -eq 'T249_NEUTERED' -and $_.Kind -eq 'no-consumer' }).Count -eq 1) `
        ("named: " + (Get-Kinds $d))
    [System.IO.File]::WriteAllText($tslPath, $origTsl)

    Assert 'D8 the scratch copy is clean again after every wound is reverted' `
        (@(Get-NeuterSweep -Root $copy -Fresh).Count -eq 0)

    # The live tree was never touched, stated as an assertion rather than as a
    # comment claiming it.
    Assert 'D9 src\ itself is still clean' (@(Get-NeuterSweep -Root $srcRoot -Fresh).Count -eq 0)
}

# --- stamp (T783 / T478) ---------------------------------------------------
# Only a CLEAN run stamps; a red one must stay due.
Complete-TestBody
if ($script:fail -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard neuter-audit -Repo $Repo 2>&1 | ForEach-Object { "  $_" }
}

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

''
Write-TestVerdict -Pass $script:pass -Fail $script:fail
