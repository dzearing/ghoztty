<#
.SYNOPSIS
    T883 acceptance - no acceptance script may read a capture whose text
    depends on the host it ran under.

.DESCRIPTION
    Five sections:

      A. The BEHAVIOUR the rule exists for, measured live rather than quoted:
         a native command's stderr through `2>&1 | Out-String` arrives as a
         formatted ErrorRecord block whose size tracks the host's buffer
         width, while the same capture stringified per record arrives as the
         command's own text at any width. Needs a host at least 40 columns
         wide; a narrower one (no real console) SKIPS this section by name
         rather than scoring the host as a regression, and is not stamped.

      B. The analyzer (`lib\StderrCaptureAudit.ps1`) against fixtures, both
         directions: each host-dependent shape is named, and each of the two
         proven-good shapes yields nothing.

      C. The sweep over `test\win32\*.ps1` and `test\win32\lib\*.ps1`: no
         script may still format a merged stream. `merged-to-file` is
         reported against a ceiling rather than asserted away - most of those
         sites discard to a file nobody reads back.

      D. The regrowth story is WRITTEN DOWN: docs\claude\testing.md names the
         rule, so the harness audit has something to point at.

      E. Section A's host gate, both directions (T1144): below its width
         floor the formatter genuinely cannot render what A measures, and at
         the floor it can, so the gate neither scores a narrow host red nor
         skips one that could have answered.

    `-TeethCheck` proves the section-C assertion can fail: it injects a
    synthesized violator and requires the sweep to go red. Run it after any
    change to the analyzer.

    One `ALL PASS` / `N FAILURE(S)` line last, per the house convention.

.NOTES
    # persistence: launches no GUI and drives no CLI - this scores scripts, it
    # does not run them. The one process it starts is a PowerShell fixture
    # that prints its own buffer width.
    # isolation: none - the `+list` and `+verb` spellings below are FIXTURE
    # TEXT handed to the analyzer as strings; no ghoztty binary is ever run.
#>
[CmdletBinding()]
param(
    [switch]$TeethCheck
)

$ErrorActionPreference = 'Continue'
$Repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\StderrCaptureAudit.ps1')

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

$tmp = Join-Path $env:TEMP "ghoztty-t883-$PID"
if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force $tmp | Out-Null

# ===========================================================================
Write-Host ''
Write-Host '== A: the two capture shapes, measured'
# ===========================================================================

# `git` with a bad flag is the cheapest native command on this box that writes
# a known phrase to stderr and exits nonzero. cmd.exe would do as well; what
# matters is that PowerShell wraps the line in an ErrorRecord.
$git = (Get-Command git -ErrorAction SilentlyContinue)
if ($null -eq $git) {
    Write-TestAssertedNothing -Reason 'git is not on PATH, so there is no native stderr to measure' `
        -Label 'T883 ACCEPTANCE'
}
$gitExe = $git.Source

# T1144 - this section measures the FORMATTER, and the formatter writes to the
# host's buffer width. Called from a host with no real console (a tool or CI
# runner that redirects output) the width reads as 1, git's message is wrapped
# a few characters a line, and A1/A2 scored FAILURE over a product nothing was
# wrong with. Measured with `Out-String -Width`: every condition below holds
# from width 20 and A1 breaks at 15, so the floor is twice the measured
# minimum. A narrower host skips THIS section by name; B-D score the test tree,
# not the host, and run regardless. Section E proves the floor both ways.
#
# The width is read off the formatter itself - where it wraps a 1000-character
# information record - not off $Host.UI.RawUI: a runspace with no console has
# no RawUI at all and still formats at a default 120, so the RawUI reading
# skipped a host that could have answered.
$script:T883MinWidth = 40
function Get-T883HostWidth([int]$Width = 0) {
    $rec = { Write-Host ('W' * 1000) }
    $text = if ($Width -gt 0) { & $rec 6>&1 | Out-String -Width $Width } else { & $rec 6>&1 | Out-String }
    [int](($text -split '\r?\n') | Measure-Object -Property Length -Maximum).Maximum
}
function Test-T883HostCanFormat([int]$Width) { $Width -ge $script:T883MinWidth }

$hostWidth = Get-T883HostWidth
$script:skippedA = 0
if (-not (Test-T883HostCanFormat $hostWidth)) {
    $script:skippedA += 8
    Write-Host "  SKIP section A (8 assertions): this host's formatter renders at most $hostWidth columns, narrower than the $($script:T883MinWidth) columns the formatter needs to render what A measures - run it from a real console. B-D still score; the guard is not stamped."
} else {

$plain = (& $gitExe --nosuchflag 2>&1 | Out-String)
$strung = (& $gitExe --nosuchflag 2>&1 | ForEach-Object { $_.ToString() } | Out-String)

Assert 'A1 both shapes carry the command''s own message in a host that can format' `
    (($plain -match 'unknown option') -and ($strung -match 'unknown option'))
Assert 'A2 the unstringified capture is padded with host-formatted decoration' `
    ($plain -match 'CategoryInfo' -and $plain.Length -gt $strung.Length)
Assert 'A3 the stringified capture carries none of it' `
    ($strung -notmatch 'CategoryInfo' -and $strung -notmatch 'FullyQualifiedErrorId')

# Out-String formats OBJECTS to the host width and passes STRINGS through. That
# asymmetry is the whole mechanism: stringify first and the formatter is out of
# the path, so the capture cannot depend on where it ran.
$long = 'X' * 300
$throughOutString = ($long | Out-String)
Assert 'A4 a plain string survives Out-String unwrapped' `
    ($throughOutString.TrimEnd() -notmatch '\r?\n' -and $throughOutString -match ('X' * 300))

# The same capture in a child host with a DIFFERENT buffer width. The
# stringified text must be byte-identical across the two; the formatted one is
# not required to be, and historically is not.
$probe = Join-Path $tmp 'probe.ps1'
Set-Content -LiteralPath $probe -Encoding utf8 -Value @(
    '$exe = (Get-Command git).Source'
    '$plain = (& $exe --nosuchflag 2>&1 | Out-String)'
    '$strung = (& $exe --nosuchflag 2>&1 | ForEach-Object { $_.ToString() } | Out-String)'
    '"plainlen=$($plain.Length)"'
    '"strunglen=$($strung.Length)"'
    '"width=$($Host.UI.RawUI.BufferSize.Width)"'
)
$childText = (& powershell -NoProfile -ExecutionPolicy Bypass -File $probe 2>&1 |
    ForEach-Object { $_.ToString() } | Out-String)
$childStrung = if ($childText -match 'strunglen=(\d+)') { [int]$Matches[1] } else { -1 }
$childWidth = if ($childText -match 'width=(\d+)') { [int]$Matches[1] } else { -1 }

Assert 'A5 the child host really ran the probe' ($childStrung -gt 0 -and $childWidth -gt 0)
AssertEq 'A6 the stringified capture is the same length in another host' $strung.Length $childStrung

# The sharpest form of the same mechanism, and the one the T883 grep missed:
# `6>&1` on a helper's Write-Host output is formatted too, so a phrase longer
# than the host's width is WRAPPED and a -match on it fails outright.
function Get-T883LongLine { Write-Host ('LEAK ' + ('X' * 300) + ' END') }
$infoPlain = (Get-T883LongLine 6>&1 | Out-String)
$infoStrung = (Get-T883LongLine 6>&1 | ForEach-Object { $_.ToString() } | Out-String)
Assert 'A7 an information-stream capture is wrapped by the formatter' `
    ($infoPlain.TrimEnd() -match '\r?\n' -and $infoPlain -notmatch 'X{300} END')
Assert 'A8 and survives whole once stringified' `
    ($infoStrung.TrimEnd() -notmatch '\r?\n' -and $infoStrung -match 'X{300} END')

}  # end of the T1144 host-width gate

# ===========================================================================
Write-Host ''
Write-Host '== B: the analyzer, both directions'
# ===========================================================================

function Get-Kinds([string[]]$Text) {
    return @(Get-StderrCaptureFindings -Path 'fixture.ps1' -Text $Text |
        ForEach-Object { $_.Kind })
}

Assert 'B1 a merged stream piped straight into Out-String is named' `
    ((Get-Kinds @('$out = & $exe +list 2>&1 | Out-String')) -contains 'merged-formatted')

Assert 'B2 the star-merge spelling is named too' `
    ((Get-Kinds @('$out = & $exe +list *>&1 | Out-String -Width 4096')) -contains 'merged-formatted')

AssertEq 'B3 a ToString stringify clears it' 0 `
    @(Get-Kinds @('$out = & $exe +list 2>&1 | ForEach-Object { $_.ToString() } | Out-String')).Count

AssertEq 'B4 the "$_" stringify clears it as well' 0 `
    @(Get-Kinds @('$out = & $exe +list 2>&1 | ForEach-Object { "$_" } | Out-String')).Count

AssertEq 'B5 a merge with no formatter downstream is not a capture' 0 `
    @(Get-Kinds @('& $exe +list 2>&1 | Select-String ok')).Count

Assert 'B6 a Format-* formatter counts, not just Out-String' `
    ((Get-Kinds @('$out = & $exe +list 2>&1 | Format-Table | Out-String')) -contains 'merged-formatted')

# A `2>&1` inside a comment or a string is not a redirection - the whole reason
# this reads the AST instead of the text.
AssertEq 'B7 a mention in a comment is not a finding' 0 `
    @(Get-Kinds @('# never write 2>&1 | Out-String here', '$x = 1')).Count

AssertEq 'B8 a redirect to $null is a discard, not a capture' 0 `
    @(Get-Kinds @('& $exe +list *> $null')).Count

Assert 'B9 a merged stream redirected to a real file is reported' `
    ((Get-Kinds @('& $exe +list *> $log')) -contains 'merged-to-file')

AssertEq 'B10 the stated-intent marker exempts a file' 0 `
    @(Get-Kinds @('# capture-audit: this one measures the formatter itself',
                 '$out = & $exe +list 2>&1 | Out-String')).Count

Assert 'B11 a file that does not parse is named rather than skipped' `
    ((Get-Kinds @('function Broken {')) -contains 'parse-error')

# The INFORMATION stream is the same defect with a different record type, and
# the one the T883 sweep's grep missed: five sites captured a helper's
# Write-Host output this way.
Assert 'B12 the information stream counts as a merged stream' `
    ((Get-Kinds @('$out = Invoke-Thing -X 1 6>&1 | Out-String')) -contains 'merged-formatted')

# ===========================================================================
Write-Host ''
Write-Host '== C: the sweep over the acceptance suite'
# ===========================================================================

$sweep = @(Get-StderrCaptureSweep (Join-Path $Repo 'test\win32'))
$hardKinds = Get-StderrCaptureHardKinds
$hard = @($sweep | Where-Object { $hardKinds -contains $_.Kind })

if ($TeethCheck) {
    # Synthesized rather than taken off the real state, so this mode keeps its
    # teeth once the suite is clean - which is the whole point and would
    # otherwise be the moment it stopped proving anything.
    $hard = @($hard) + [pscustomobject]@{
        Path = 'synthetic-violator.ps1'; Line = 1; Kind = 'merged-formatted'
        Detail = 'teeth check' }
    Write-Host '  TEETH CHECK: a synthesized merged-formatted violator is in the sweep'
    Assert 'C1 goes red when a script formats a merged stream' ($hard.Count -gt 0)
} else {
    Assert 'C1 no script reads a capture whose text depends on the host' ($hard.Count -eq 0)
    foreach ($h in $hard) {
        Write-Host "       $(Split-Path $h.Path -Leaf):$($h.Line) $($h.Kind) - $($h.Detail)"
    }
}

# The analyzer must actually have read the suite - a sweep that found no files
# would report zero violations and look identical to a clean one.
$scanned = @(Get-ChildItem -LiteralPath (Join-Path $Repo 'test\win32') -Filter *.ps1 -File).Count +
           @(Get-ChildItem -LiteralPath (Join-Path $Repo 'test\win32\lib') -Filter *.ps1 -File).Count
Assert 'C2 the sweep read the whole suite, lib included' ($scanned -gt 100)

$toFile = @($sweep | Where-Object { $_.Kind -eq 'merged-to-file' })
Write-Host "  ($($toFile.Count) site(s) redirect a merged stream to a file - reported, not enforced)"
foreach ($t in $toFile) {
    Write-Host "       $(Split-Path $t.Path -Leaf):$($t.Line)"
}

# A ceiling, not a name list: the sites that remain are discards or logs nobody
# reads back, and the number may fall, never rise. A NEW one is a new place a
# text oracle could grow blind, and is worth a human looking at it.
$ceiling = 2
Assert "C3 the merged-to-file count did not grow past $ceiling" ($toFile.Count -le $ceiling)

# ===========================================================================
Write-Host ''
Write-Host '== D: the rule is written down where the harness audit looks'
# ===========================================================================

$testingDoc = Join-Path $Repo 'docs\claude\testing.md'
$doc = if (Test-Path -LiteralPath $testingDoc) { Get-Content -LiteralPath $testingDoc -Raw } else { '' }
Assert 'D1 testing.md names the host-dependent capture rule' ($doc -match 'ForEach-Object \{ \$_\.ToString\(\) \}')
Assert 'D2 and points at this harness by name' ($doc -match 'stderr-capture-audit')

# ===========================================================================
Write-Host ''
Write-Host '== E: the section-A host gate, both directions (T1144)'
# ===========================================================================

# `Out-String -Width` drives the same formatter at a chosen width, so the floor
# is checked against the real thing on any host, including one that skipped A.
$narrow = (& $gitExe --nosuchflag 2>&1 | Out-String -Width 10)
Assert 'E1 below the floor the formatter really cannot carry what A measures' `
    ($narrow -notmatch 'unknown option')
$atFloor = (& $gitExe --nosuchflag 2>&1 | Out-String -Width $script:T883MinWidth)
$atFloorStrung = (& $gitExe --nosuchflag 2>&1 | ForEach-Object { $_.ToString() } |
    Out-String -Width $script:T883MinWidth)
Assert 'E2 at the floor it can, so the gate never skips a host that could answer' `
    ($atFloor -match 'unknown option' -and $atFloor -match 'CategoryInfo' -and
     $atFloor.Length -gt $atFloorStrung.Length)
Assert 'E3 the gate skips a console-less host (width 1) and an unreadable one (0)' `
    (-not (Test-T883HostCanFormat 1) -and -not (Test-T883HostCanFormat 0))
Assert 'E4 and runs section A under an ordinary console' (Test-T883HostCanFormat 120)
$w10 = Get-T883HostWidth -Width 10
$w60 = Get-T883HostWidth -Width 60
Assert "E5 the width probe reads the formatter's own wrap point (10 -> $w10, 60 -> $w60)" `
    ($w10 -ge 9 -and $w10 -le 10 -and $w60 -ge 59 -and $w60 -le 60)

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

# A clean green run stamps the covered files (T783) so scripts\guard-due.ps1 can
# answer "has this scan been run against the test tree as it now stands?". Never
# under -TeethCheck: that mode's C1 scores a synthesized violator and never asks
# the real sweep anything, so it must not vouch for the tree. Nor when section A
# was skipped (T1144): an unmeasured section is not a green one.
Complete-TestBody  # T1039: before the stamp, which is a child process reading this run's state
if ($script:fail -eq 0 -and -not $TeethCheck -and $script:skippedA -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard stderr-capture -Repo $Repo 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Label 'T883 ACCEPTANCE' -Pass $script:pass -Fail $script:fail `
    -Skipped $script:skippedA -MinPass ($(if ($script:skippedA -gt 0) { 14 } else { 22 }))
