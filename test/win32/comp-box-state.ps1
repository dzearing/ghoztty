<#
.SYNOPSIS
  Acceptance test for scripts\lib\CompBoxState.ps1 (T2733).

.DESCRIPTION
  The comp-spike live oracle read comp=0 on 2026-11-05 and 0.944 on
  2026-11-07 with the same build: the failure was a desktop state, and nothing
  recorded which. scripts\comp-spike.ps1 now prints a BOXSTATE line on every
  -Live run and a blind verdict names it. This checks the part that can lie:

    A. Get-UncoveredFraction - the coverage math, including the NEGATIVE
       control (a fully covered ghost really scores 0, so the "fully covered"
       hint can fire at all).
    B. Get-CompBlindHint - which cause each state names.
    C. Get-CompBoxState against the live desktop: read-only (it enumerates
       windows; it never opens, moves or focuses one), and every field the
       hint reads is present.

  No exe, no window. ASCII-only by design.

  powershell -NoProfile -File test\win32\comp-box-state.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$script:passes = 0
$script:failures = 0
function Assert($name, $cond, $detail = '') {
    if ($cond) {
        "  PASS $name"
        $script:passes++
    } else {
        "  FAIL $name$(if ($detail) { " -- $detail" })"
        $script:failures++
    }
}

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $repo 'scripts\lib\CompBoxState.ps1')

try {
    ''
    '-- A. coverage math'
    $t = @{ L = 0; T = 0; R = 100; B = 100 }
    $f = Get-UncoveredFraction -Target $t -Covers @()
    Assert 'A1 nothing above the ghost: fully uncovered' ($f -eq 1.0) "got $f"
    $f = Get-UncoveredFraction -Target $t -Covers @(@{ L = -10; T = -10; R = 200; B = 200 })
    Assert 'A2 negative control: one window over all of it scores 0' ($f -eq 0.0) "got $f"
    $f = Get-UncoveredFraction -Target $t -Covers @(@{ L = 0; T = 0; R = 50; B = 100 })
    Assert 'A3 the left half covered leaves half' ([Math]::Abs($f - 0.5) -lt 0.0001) "got $f"
    $f = Get-UncoveredFraction -Target $t -Covers @(@{ L = 0; T = 0; R = 50; B = 100 }, @{ L = 50; T = 0; R = 100; B = 100 })
    Assert 'A4 two windows that tile it cover all of it' ($f -eq 0.0) "got $f"
    $f = Get-UncoveredFraction -Target $t -Covers @(@{ L = 0; T = 0; R = 50; B = 100 }, @{ L = 0; T = 0; R = 50; B = 100 })
    Assert 'A5 overlapping windows are not double-counted' ([Math]::Abs($f - 0.5) -lt 0.0001) "got $f"
    $f = Get-UncoveredFraction -Target $t -Covers @(@{ L = 300; T = 300; R = 400; B = 400 })
    Assert 'A6 a window elsewhere covers nothing' ($f -eq 1.0) "got $f"
    $f = Get-UncoveredFraction -Target @{ L = 0; T = 0; R = 0; B = 10 } -Covers @()
    Assert 'A7 an empty target reads 0, not a divide by zero' ($f -eq 0.0) "got $f"

    ''
    '-- B. which cause a blind verdict names'
    $covered = 'BOXSTATE ghost=200,200,1016x679 uncovered=0.00 covers=3 fg_fullscreen=false battery_saver=off'
    $h = Get-CompBlindHint $covered
    # 2026-11-07: a fully covered ghost scored 0.944, so coverage is not a cause.
    # Judge only the verdict text after the box line: the line itself says uncovered=.
    function Tail([string]$s) { return ($s -replace '^.*\]', '') }
    Assert 'B1 a fully covered ghost is NOT blamed on coverage (disproved 11-07)' ((Tail $h) -notmatch 'cover') $h
    Assert 'B2 the hint carries the box line itself' ($h -match 'uncovered=0.00') $h
    Assert 'B2b and says to diff it against a green run' ($h -match 'diff this line against a green run') $h
    $h = Get-CompBlindHint 'BOXSTATE ghost=1,1,1x1 uncovered=0.80 fg_fullscreen=true battery_saver=off'
    Assert 'B3 a fullscreen foreground is named' ($h -match 'fullscreen foreground') $h
    $h = Get-CompBlindHint 'BOXSTATE ghost=1,1,1x1 uncovered=0.80 fg_fullscreen=false battery_saver=on'
    Assert 'B4 battery saver is named' ($h -match 'battery saver') $h
    $h = Get-CompBlindHint 'BOXSTATE ghost=1,1,1x1 uncovered=0.80 fg_fullscreen=false battery_saver=off'
    Assert 'B5 an ordinary desktop names no cause it cannot show' ((Tail $h) -notmatch 'fullscreen|battery saver') $h
    Assert 'B6 no box line, no hint' ((Get-CompBlindHint '') -eq '') ''

    ''
    '-- C. the live desktop (read-only)'
    $line = Get-CompBoxState -X 200 -Y 200
    "  $line"
    Assert 'C1 it answers a BOXSTATE line' ($line -match '^BOXSTATE ') $line
    foreach ($k in 'ghost', 'uncovered', 'covers', 'overlays', 'os', 'monitor', 'monitors', 'fg_class', 'fg_fullscreen', 'client_anim', 'power', 'battery_saver', 'transparency') {
        Assert "C2 field $k is present" ($line -match " $k=[^ ]+") ''
    }
    $u = if ($line -match ' uncovered=([0-9.]+)') { [double]$Matches[1] } else { -1 }
    Assert 'C3 uncovered is a fraction' ($u -ge 0 -and $u -le 1) "got $u"
    $off = Get-CompBoxState -X -100000 -Y -100000
    Assert 'C4 a ghost off every monitor says so' ($off -match ' monitor=none ') $off

    Complete-TestBody
}
finally {
}

if ($script:failures -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard comp-box-state -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

''
Write-TestVerdict -Label 'T2733 COMP-BOX-STATE' -Pass $script:passes -Fail $script:failures
