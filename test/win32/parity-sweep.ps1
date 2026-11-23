<#
.SYNOPSIS
  Acceptance test for scripts\parity-sweep.ps1 (T152).

.DESCRIPTION
  The sweep is a GATE: it decides whether a range of Mac-side history has been
  written down as Windows work. A gate that answers "clean" when it should not
  is worse than no gate at all, so every arm here has a deterministic oracle -
  a fixed six-commit range of real history, and a fixture docs tree this test
  writes itself, so the expected mapped/unmapped split is known exactly rather
  than compared against whatever the live tracker happens to say today.

  Two of the arms exist to check the sweep's teeth rather than its function:
  a nine-character token that shares a commit's first seven characters must
  NOT map it (that is the difference between a sha reference and a hex-shaped
  coincidence), and a "#rrggbbaa" color must not either.

  Arms 8-10 are T685: the watch list now covers the shared src/ core, and the
  two things that keeps honest. 8 proves a commit touching only src/termio/ is
  caught where the old macos/+src/viewer/ default saw nothing. 9 proves a range
  spanning THIS branch reports none of our own commits (the topological guard).
  10 proves a src/apprt/win32/ commit is dropped by the path exclusion even
  when the topological guard cannot see it, so the two mechanisms are tested
  apart rather than covering for each other.

  Arms 11-12 are T3342: the Linux seat's own view (-Seat linux), where only
  seat:linux / seat:any task files and the Linux watermark count as coverage,
  and -Record, which moves that watermark only over a clean, contiguous range.

  Prints a single ALL PASS / N FAILURE(S) line, like every other script here.

  ASCII-only by design (PS 5.1 on this box mangles non-ASCII on rewrite).
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Sweep = Join-Path $RepoRoot 'scripts\parity-sweep.ps1'

# A fixed slice of real history: exactly these six commits touch macos/ or
# src/viewer/ between these two revisions. Frozen on 2026-08-09; if history is
# ever rewritten under it the first arm fails loudly rather than silently
# testing nothing.
$Range = '261de0390b50d8dc23fb2a64d18294f2acea4f25..4a41394b232bab712749b1ccbc8b102cc87800de'
$Expected = @(
    'c182302e3cda342123bcf6998f15bdcaa79494bd'
    'a7f7476e11bc9e5789a12eacde467103931b004a'
    '5bd426ba24cafe176aae03e0cb05223875b4849a'
    '11fe14bc311656974703a2efafb85fb9aeef24fb'
    '2389d318249a47333d7bfad9d05ded7247a44011'
    'dfa54ff3cb428534a235dbfdd68cf438ef5486da'
)

# The watch list as it stood before T685, kept here so an arm can show what the
# widened default now catches that this one did not.
$LegacyPaths = @('macos/', 'src/viewer/')

# T685 oracles, all frozen shas.
#   SharedRange - one commit, eb1876f09, whose only files are src/termio/*.
#   MixedRange  - an old main sha to this branch's tip, which is 481 commits of
#                 BOTH kinds: 294 Mac changes we merged in, and 187 of our own.
#                 A range with only one kind could not tell a guard that
#                 separates the sides from one that zeroes the report.
#   Win32Range  - one commit whose only src/ files are under src/apprt/win32/.
$SharedRange = 'ba76e3f93f04a79ffa56e7523a65b7d37600b543..eb1876f09ce054be8f5095e5e2b49d3e8c6cd64a'
$SharedSha = 'eb1876f09ce054be8f5095e5e2b49d3e8c6cd64a'
$MixedRange = '680a07ed398f064d106b6ea476f43ce0d143d21a..95b3f35b4269e3f83c3de408c55447b5407aabf7'
$MixedIncoming = 'b388bb62c25c8a4564c88aec8e211b2d4fdc6bf0'
$MixedIncomingCount = 294
$MixedLocalCount = 187
$BranchOwnSha = '029ae4b1238c0e7ac8ee729d283b6fe7ec7ec926'
$Win32Range = '839a1b812941901088169c92d512bcd55b2bd7cb..c72220cd7420f720cd2cde1ff9de5d33922ce556'
$Win32Incoming = 'c72220cd7420f720cd2cde1ff9de5d33922ce556'

# T271/T1768: the shared scorer arms the run, so the guard stamp at the end
# is refused when the body unwound or asserted nothing.
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:Failures = 0
$script:Passes = 0
function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    if ($Ok) {
        Write-Host ("PASS  {0}" -f $Name)
        $script:Passes++
    }
    else {
        Write-Host ("FAIL  {0}{1}" -f $Name, $(if ($Detail) { " - $Detail" } else { '' }))
        $script:Failures++
    }
}

# Run the sweep against a fixture docs tree. Returns the captured stdout lines
# plus the exit code; the sweep's exit code IS its verdict, so both matter.
#
# Invoked through -Command rather than -File: PS 5.1's -File parser binds only
# the FIRST value of a multi-value argument and drops the rest silently, so
# "-File ... -Paths macos/ src/viewer/" would sweep macos/ alone and the arm
# that depends on the narrower list would pass for the wrong reason.
function Invoke-Sweep {
    param(
        [string]$DocsPath,
        [string]$Format = 'text',
        [switch]$ShowMapped,
        [string]$UseRange,
        [string[]]$Paths,
        [string]$IncomingRef,
        [string]$Seat,
        [switch]$Record,
        [string]$Note,
        [switch]$NoRange
    )

    $r = if ($UseRange) { $UseRange } else { $Range }
    $cmd = "& '$Sweep' -DocsPath '$DocsPath' -Format '$Format' -RepoRoot '$RepoRoot'"
    if (-not $NoRange) { $cmd += " -Range '$r'" }
    if ($Seat) { $cmd += " -Seat '$Seat'" }
    if ($Record) { $cmd += ' -Record' }
    if ($Note) { $cmd += " -Note '$Note'" }
    if ($Paths) {
        $cmd += ' -Paths @(' + (($Paths | ForEach-Object { "'" + $_ + "'" }) -join ',') + ')'
    }
    if ($IncomingRef) { $cmd += " -IncomingRef '$IncomingRef'" }
    if ($ShowMapped) { $cmd += ' -ShowMapped' }
    # -Command reports a script's "exit 2" as 1, so hand the real code back;
    # a throw is caught and stays non-zero (T3342: -Record's 1 vs 2 matters).
    $cmd = "try { $cmd; exit `$LASTEXITCODE } catch { Write-Output ('THROWN: ' + `$_); exit 99 }"

    # Capture through a pipe: powershell.exe is a console binary here, so
    # stdout redirects normally, but $LASTEXITCODE is only trustworthy when the
    # whole stream has been drained (never -First; see go.md).
    # Continue across the call: a refusal arm's child writes its error to
    # stderr, and under Stop PS 5.1 turns that line into a throw HERE (T3342).
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = & powershell.exe -NoProfile -Command $cmd 2>&1 }
    finally { $ErrorActionPreference = $prev }
    $out = @($out | ForEach-Object { [string]$_ })
    return [pscustomobject]@{ Lines = @($out); Exit = $LASTEXITCODE; Text = (@($out) -join "`n") }
}

# Write a fixture docs tree whose only sha references are the ones given.
function New-FixtureDocs {
    param([string[]]$Shas, [string]$Extra = '')

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("parity-sweep-fixture-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $tasks = Join-Path $root 'windows-parity-tasks'
    New-Item -ItemType Directory -Path $tasks -Force | Out-Null

    $body = @('# T900 - fixture', '')
    foreach ($s in $Shas) {
        # Reference each as a 9-character abbreviation, the way the tracker
        # actually writes them.
        $body += ("- ``{0}`` covered by this fixture" -f $s.Substring(0, 9))
    }
    if ($Extra) { $body += ''; $body += $Extra }

    Set-Content -LiteralPath (Join-Path $tasks 'T900.md') -Value ($body -join "`n") -Encoding ASCII
    return $root
}

# T3342: a fixture tree of task files that carry a seat in their frontmatter,
# plus optional loose docs. -Tasks maps a task id to @{ Seat; Shas }; a $null
# seat writes no seat line at all (the tracker's default, win).
function New-SeatFixture {
    param([hashtable]$Tasks, [hashtable]$Files = @{})

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("parity-sweep-seat-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $dir = Join-Path $root 'windows-parity-tasks'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    foreach ($id in $Tasks.Keys) {
        $t = $Tasks[$id]
        $body = @('---', ('id: ' + $id), ('title: "fixture ' + $id + '"'))
        if ($t.Seat) { $body += ('seat: "' + $t.Seat + '"') }
        $body += @('status: "todo"', '---', '', ('# ' + $id + ' - fixture'), '')
        foreach ($sha in @($t.Shas)) {
            if ($sha) { $body += ("- ``{0}`` cited by this fixture" -f $sha.Substring(0, 9)) }
        }
        Set-Content -LiteralPath (Join-Path $dir ($id + '.md')) -Value ($body -join "`r`n") -Encoding ASCII
    }
    foreach ($name in $Files.Keys) {
        Set-Content -LiteralPath (Join-Path $root $name) -Value $Files[$name] -Encoding ASCII
    }
    return $root
}

function Get-CountLine {
    param($R)
    return ("got: " + (($R.Lines | Where-Object { $_ -match 'commits:' }) -join '; '))
}

$created = New-Object System.Collections.ArrayList

try {
    # --- 1. The range itself is what the test thinks it is -------------------
    $none = New-FixtureDocs -Shas @()
    [void]$created.Add($none)
    $r = Invoke-Sweep -DocsPath $none

    Check '1a range yields exactly the six frozen commits' `
        ($r.Text -match 'commits: 6\s') ("got: " + (($r.Lines | Where-Object { $_ -match 'commits:' }) -join '; '))
    Check '1b nothing referenced => all six unmapped' `
        ($r.Text -match 'unmapped: 6')
    Check '1c an unmapped sweep exits 1 (this is the gate)' `
        ($r.Exit -eq 1) ("exit=" + $r.Exit)
    $allListed = $true
    foreach ($s in $Expected) {
        if ($r.Text -notmatch [regex]::Escape($s.Substring(0, 9))) { $allListed = $false }
    }
    Check '1d every unmapped commit is named in the report' $allListed

    # --- 2. Partial coverage: exactly the remainder is reported --------------
    $mappedThree = $Expected[0..2]
    $partial = New-FixtureDocs -Shas $mappedThree
    [void]$created.Add($partial)
    $r = Invoke-Sweep -DocsPath $partial

    Check '2a three referenced => three mapped' ($r.Text -match 'mapped: 3\s')
    Check '2b three referenced => three unmapped' ($r.Text -match 'unmapped: 3')
    Check '2c still exits 1 while anything is unmapped' ($r.Exit -eq 1) ("exit=" + $r.Exit)

    $unmappedSection = ($r.Text -split 'UNMAPPED \(')[-1]
    $rightOnes = $true
    foreach ($s in $Expected[3..5]) {
        if ($unmappedSection -notmatch [regex]::Escape($s.Substring(0, 9))) { $rightOnes = $false }
    }
    foreach ($s in $mappedThree) {
        if ($unmappedSection -match [regex]::Escape($s.Substring(0, 9))) { $rightOnes = $false }
    }
    Check '2d the unmapped list is exactly the un-referenced three' $rightOnes

    # --- 3. Full coverage is clean and exits 0 -------------------------------
    $full = New-FixtureDocs -Shas $Expected
    [void]$created.Add($full)
    $r = Invoke-Sweep -DocsPath $full

    Check '3a everything referenced => 0 unmapped' ($r.Text -match 'unmapped: 0')
    Check '3b a clean sweep exits 0' ($r.Exit -eq 0) ("exit=" + $r.Exit)
    Check '3c and says so on its last line' ($r.Text -match 'SWEEP CLEAN')

    # --- 4. Teeth: a near-miss token must not map a commit -------------------
    # Same first seven characters, different eighth and ninth. If the sweep
    # keyed on the seven-character bucket alone this would map all six, and the
    # gate would go quiet on exactly the commits it exists to catch.
    $nearMiss = @()
    foreach ($s in $Expected) {
        $seven = $s.Substring(0, 7)
        $eighthNinth = $s.Substring(7, 2)
        $wrong = if ($eighthNinth -eq 'aa') { 'bb' } else { 'aa' }
        $nearMiss += ("- near-miss ``{0}{1}``" -f $seven, $wrong)
    }
    $teeth = New-FixtureDocs -Shas @() -Extra ($nearMiss -join "`n")
    [void]$created.Add($teeth)
    $r = Invoke-Sweep -DocsPath $teeth

    Check '4a a 9-char token sharing only the first 7 does NOT map' `
        ($r.Text -match 'unmapped: 6') ("got: " + (($r.Lines | Where-Object { $_ -match 'unmapped:' }) -join '; '))
    Check '4b and the sweep still fails' ($r.Exit -eq 1)

    # --- 5. Teeth: a hex color must not map a commit -------------------------
    $colors = ($Expected | ForEach-Object { '- color #' + $_.Substring(0, 8) }) -join "`n"
    $colorFixture = New-FixtureDocs -Shas @() -Extra $colors
    [void]$created.Add($colorFixture)
    $r = Invoke-Sweep -DocsPath $colorFixture

    Check '5a "#rrggbbaa" is a color, not a sha reference' ($r.Text -match 'unmapped: 6')

    # --- 6. The markdown block is the pasteable evidence ---------------------
    $r = Invoke-Sweep -DocsPath $partial -Format markdown -ShowMapped

    Check '6a markdown emits the Parity coverage heading' ($r.Text -match '(?m)^## Parity coverage')
    Check '6b it states the range' ($r.Text -match [regex]::Escape('261de0390'))
    Check '6c it carries a Commit/Subject/Filed as table' ($r.Text -match '\|\s*Commit\s*\|\s*Subject\s*\|\s*Filed as\s*\|')
    Check '6d it calls out the unmapped count in bold' ($r.Text -match '\*\*Unmapped: 3\*\*')
    Check '6e -ShowMapped names the file that mapped each commit' ($r.Text -match 'T900')

    # --- 7. JSON is machine-readable and agrees with the text ---------------
    $r = Invoke-Sweep -DocsPath $partial -Format json
    $ok = $false
    $detail = ''
    try {
        $obj = $r.Text | ConvertFrom-Json
        $ok = ($obj.total -eq 6 -and @($obj.mapped).Count -eq 3 -and @($obj.unmapped).Count -eq 3)
        $detail = ("total={0} mapped={1} unmapped={2}" -f $obj.total, @($obj.mapped).Count, @($obj.unmapped).Count)
    }
    catch {
        $detail = "parse failed: $_"
    }
    Check '7a json parses and its counts match the text report' $ok $detail
    Check '7b the Windows json carries no seat field (T3342 left it byte-identical)' `
        ($r.Text -notmatch '"seat"')
    $r = Invoke-Sweep -DocsPath $partial -Format json -Seat linux
    $ok = $false
    try { $ok = (($r.Text | ConvertFrom-Json).seat -eq 'linux') } catch { }
    Check '7c the Linux json says which seat it answered for' $ok

    # --- 8. T685: the shared core is watched --------------------------------
    # eb1876f09 touches src/termio/ and nothing else. It is exactly the shape
    # that produced T604 (main rewriting shared code underneath this branch),
    # and the pre-T685 default could not see it at all.
    $sharedFixture = New-FixtureDocs -Shas @()
    [void]$created.Add($sharedFixture)

    $r = Invoke-Sweep -DocsPath $sharedFixture -UseRange $SharedRange -Paths $LegacyPaths
    Check '8a the old macos/+src/viewer/ list saw nothing here' `
        ($r.Text -match 'commits: 0\s') ("got: " + (($r.Lines | Where-Object { $_ -match 'commits:' }) -join '; '))
    Check '8b and therefore reported clean' ($r.Exit -eq 0) ("exit=" + $r.Exit)

    $r = Invoke-Sweep -DocsPath $sharedFixture -UseRange $SharedRange
    Check '8c the default now enumerates the src/termio/ commit' `
        ($r.Text -match 'commits: 1\s') ("got: " + (($r.Lines | Where-Object { $_ -match 'commits:' }) -join '; '))
    Check '8d unreferenced, it is unmapped and the gate fails' `
        (($r.Text -match 'unmapped: 1') -and $r.Exit -eq 1) ("exit=" + $r.Exit)
    Check '8e the report names it' ($r.Text -match [regex]::Escape($SharedSha.Substring(0, 9)))
    Check '8f the default path list carries both frontend exclusions' `
        (($r.Text -match [regex]::Escape(':(exclude)src/apprt/win32/')) -and `
         ($r.Text -match [regex]::Escape(':(exclude)src/apprt/gtk/')))

    # --- 9. T685: this branch's own commits are never reported ---------------
    # A range holding both sides at once. Without the incoming-side guard,
    # widening the paths would report all 481 - our 187 included - and the gate
    # would be noise within a day. The two counts below must SPLIT the range,
    # which is the claim a single-sided range cannot check.
    $r = Invoke-Sweep -DocsPath $sharedFixture -UseRange $MixedRange -IncomingRef $MixedIncoming
    Check '9a only the incoming side is enumerated' `
        ($r.Text -match ("commits: {0}\s" -f $MixedIncomingCount)) `
        ("got: " + (($r.Lines | Where-Object { $_ -match 'commits:' }) -join '; '))
    Check '9b and the branch-local remainder is reported, not silently dropped' `
        ($r.Text -match ("branch-local excluded: {0}\b" -f $MixedLocalCount)) `
        ("got: " + (($r.Lines | Where-Object { $_ -match 'branch-local' }) -join '; '))
    Check '9c one of our own shared-src commits is not in the report' `
        ($r.Text -notmatch [regex]::Escape($BranchOwnSha.Substring(0, 9)))
    Check '9d a Mac-side shared-src commit in the same range IS in it' `
        ($r.Text -match [regex]::Escape($SharedSha.Substring(0, 9)))

    $r = Invoke-Sweep -DocsPath $sharedFixture -UseRange $MixedRange -IncomingRef $MixedIncoming -Format json
    $ok = $false; $detail = ''
    try {
        $obj = $r.Text | ConvertFrom-Json
        $ok = ($obj.excluded_local -eq $MixedLocalCount -and $obj.total -eq $MixedIncomingCount -and `
               $obj.incoming_ref -eq $MixedIncoming)
        $detail = ("excluded_local={0} total={1} incoming_ref={2}" -f $obj.excluded_local, $obj.total, $obj.incoming_ref)
    }
    catch { $detail = "parse failed: $_" }
    Check '9e json carries the exclusion count and the incoming ref' $ok $detail

    # --- 10. T685: src/apprt/win32/ is dropped by PATH, not by topology ------
    # Same commit, but pointed at an incoming ref that reaches it - so the
    # topological guard cannot help and the path exclusion has to. The second
    # half removes the exclusion to prove the arm has teeth.
    $r = Invoke-Sweep -DocsPath $sharedFixture -UseRange $Win32Range -IncomingRef $Win32Incoming
    Check '10a a win32-only commit is not a Mac change' `
        (($r.Text -match 'commits: 0\s') -and ($r.Text -match 'branch-local excluded: 0')) `
        ("got: " + (($r.Lines | Where-Object { $_ -match 'commits:|branch-local' }) -join '; '))

    $r = Invoke-Sweep -DocsPath $sharedFixture -UseRange $Win32Range -IncomingRef $Win32Incoming -Paths @('src/')
    Check '10b without the exclusion the same commit IS enumerated' `
        ($r.Text -match 'commits: 1\s') ("got: " + (($r.Lines | Where-Object { $_ -match 'commits:' }) -join '; '))

    # --- 11. T3342: the Linux seat counts only Linux work as coverage --------
    $first3 = $Expected[0..2]; $last3 = $Expected[3..5]
    $winOnly = New-SeatFixture -Tasks @{ T910 = @{ Seat = 'win'; Shas = $Expected } }
    [void]$created.Add($winOnly)

    $r = Invoke-Sweep -DocsPath $winOnly -Seat linux
    Check '11a a seat:win task citing all six maps NOTHING for Linux' `
        (($r.Text -match 'unmapped: 6') -and $r.Exit -eq 1) ((Get-CountLine $r) + " exit=" + $r.Exit)
    Check '11b the Linux report says which seat it answered for' ($r.Text -match '(?m)^\s*seat:\s+linux')

    $r = Invoke-Sweep -DocsPath $winOnly
    Check '11c the same tree is clean for the Windows seat (its sweep is unchanged)' `
        (($r.Text -match 'unmapped: 0') -and $r.Exit -eq 0 -and $r.Text -notmatch '(?m)^\s*seat:') ((Get-CountLine $r) + " exit=" + $r.Exit)

    $noSeat = New-SeatFixture -Tasks @{ T911 = @{ Seat = $null; Shas = $Expected } }
    [void]$created.Add($noSeat)
    $r = Invoke-Sweep -DocsPath $noSeat -Seat linux
    Check '11d a task with no seat line is a Windows task, not Linux coverage' ($r.Text -match 'unmapped: 6') (Get-CountLine $r)

    $split = New-SeatFixture -Tasks @{
        T912 = @{ Seat = 'linux'; Shas = $first3 }
        T913 = @{ Seat = 'win'; Shas = $last3 }
    }
    [void]$created.Add($split)
    $r = Invoke-Sweep -DocsPath $split -Seat linux
    $unmappedSection = ($r.Text -split 'UNMAPPED \(')[-1]
    $rightOnes = $true
    foreach ($x in $last3) { if ($unmappedSection -notmatch [regex]::Escape($x.Substring(0, 9))) { $rightOnes = $false } }
    foreach ($x in $first3) { if ($unmappedSection -match [regex]::Escape($x.Substring(0, 9))) { $rightOnes = $false } }
    Check '11e seat:linux cites three => exactly the other three are unmapped for Linux' `
        (($r.Text -match 'mapped: 3\s') -and ($r.Text -match 'unmapped: 3') -and $rightOnes) (Get-CountLine $r)

    $anyFix = New-SeatFixture -Tasks @{
        T914 = @{ Seat = 'linux'; Shas = $first3 }
        T915 = @{ Seat = 'any'; Shas = $last3 }
    }
    [void]$created.Add($anyFix)
    $r = Invoke-Sweep -DocsPath $anyFix -Seat linux -Format markdown -ShowMapped
    Check '11f a seat:any task is Linux coverage too' `
        (($r.Text -match '- Unmapped: 0') -and $r.Exit -eq 0) ("exit=" + $r.Exit)
    Check '11g the markdown names Linux work items and the mapping task' `
        (($r.Text -match 'Mapped to Linux work items: 6') -and ($r.Text -match 'T915'))

    $citeAll = (($Expected | ForEach-Object { '- ' + $_.Substring(0, 9) }) -join "`n")
    $logOnly = New-SeatFixture -Tasks @{} -Files @{
        'windows-parity-log.md'    = $citeAll
        'windows-parity-digest.md' = $citeAll
    }
    [void]$created.Add($logOnly)
    $r = Invoke-Sweep -DocsPath $logOnly -Seat linux
    Check '11h the log and digests are not Linux coverage' ($r.Text -match 'unmapped: 6') (Get-CountLine $r)

    $noted = ('{ "lastEvaluated": "261de0390", "note": "' + (($last3 | ForEach-Object { $_.Substring(0, 9) + ' AppKit-only' }) -join '; ') + '" }')
    $markFix = New-SeatFixture -Tasks @{ T916 = @{ Seat = 'linux'; Shas = $first3 } } -Files @{ 'windows-parity-linux-intake.json' = $noted }
    [void]$created.Add($markFix)
    $r = Invoke-Sweep -DocsPath $markFix -Seat linux
    Check '11i a no-parity-owed citation in the Linux watermark maps the commit' `
        (($r.Text -match 'unmapped: 0') -and $r.Exit -eq 0) ((Get-CountLine $r) + " exit=" + $r.Exit)
    $winMark = New-SeatFixture -Tasks @{} -Files @{ 'windows-parity-linux-intake.json' = $noted }
    [void]$created.Add($winMark)
    $r = Invoke-Sweep -DocsPath $winMark
    Check '11j ...but it is a Linux judgement: the Windows sweep ignores it' ($r.Text -match 'unmapped: 6') (Get-CountLine $r)

    $bare = New-SeatFixture -Tasks @{}
    [void]$created.Add($bare)
    $r = Invoke-Sweep -DocsPath $bare -Seat linux -NoRange
    Check '11k with no range the Linux seat reads ITS watermark, and says so when absent' `
        (($r.Exit -ne 0) -and ($r.Text -match 'windows-parity-linux-intake\.json')) ("exit=" + $r.Exit)

    # --- 12. T3342: -Record moves the Linux watermark only over a clean, contiguous range
    $start = '261de0390'
    $markJson = '{ "lastEvaluated": "' + $start + '", "note": "baseline" }'
    $recDirty = New-SeatFixture -Tasks @{ T917 = @{ Seat = 'linux'; Shas = $first3 } } -Files @{ 'windows-parity-linux-intake.json' = $markJson }
    [void]$created.Add($recDirty)
    $markPath = Join-Path $recDirty 'windows-parity-linux-intake.json'
    $before = Get-Content -LiteralPath $markPath -Raw
    $r = Invoke-Sweep -DocsPath $recDirty -Seat linux -Record
    Check '12a -Record over unmapped commits refuses and leaves the watermark' `
        (($r.Exit -eq 1) -and ($r.Text -match 'NOT RECORDED') -and ((Get-Content -LiteralPath $markPath -Raw) -eq $before)) ("exit=" + $r.Exit)

    $gapJson = '{ "lastEvaluated": "' + $Expected[5].Substring(0, 9) + '" }'
    $recGap = New-SeatFixture -Tasks @{ T918 = @{ Seat = 'linux'; Shas = $Expected } } -Files @{ 'windows-parity-linux-intake.json' = $gapJson }
    [void]$created.Add($recGap)
    $gapPath = Join-Path $recGap 'windows-parity-linux-intake.json'
    $before = Get-Content -LiteralPath $gapPath -Raw
    $r = Invoke-Sweep -DocsPath $recGap -Seat linux -Record
    Check '12b -Record over a range that does not start at the watermark refuses' `
        (($r.Exit -eq 2) -and ($r.Text -match 'NOT RECORDED') -and ((Get-Content -LiteralPath $gapPath -Raw) -eq $before)) ("exit=" + $r.Exit + " " + (@($r.Lines | Select-Object -Last 3) -join ' / '))

    $recOk = New-SeatFixture -Tasks @{ T919 = @{ Seat = 'linux'; Shas = $Expected } } -Files @{ 'windows-parity-linux-intake.json' = $markJson }
    [void]$created.Add($recOk)
    $okPath = Join-Path $recOk 'windows-parity-linux-intake.json'
    $r = Invoke-Sweep -DocsPath $recOk -Seat linux -Record -Note 'fixture intake'
    $ok = $false; $detail = "exit=" + $r.Exit
    try {
        $j = Get-Content -LiteralPath $okPath -Raw | ConvertFrom-Json
        $run0 = @($j.runs | ForEach-Object { $_ })[0]
        $ok = ($r.Exit -eq 0 -and $j.lastEvaluated -eq '4a41394b2' -and $run0.from -eq $start -and `
               $run0.commits -eq 6 -and $j.note -eq 'fixture intake')
        $detail += (" last={0} from={1} commits={2} note={3}" -f $j.lastEvaluated, $run0.from, $run0.commits, $j.note)
    }
    catch { $detail += " parse failed: $_" }
    Check '12c a clean contiguous sweep records the range end, its size and the note' $ok $detail
    $bytes = [System.IO.File]::ReadAllBytes($okPath)
    Check '12d the watermark is written without a BOM' (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB))

    $noteCite = (($last3 | ForEach-Object { $_.Substring(0, 9) + ' AppKit-only' }) -join ', ')
    $recNote = New-SeatFixture -Tasks @{ T920 = @{ Seat = 'linux'; Shas = $first3 } } -Files @{ 'windows-parity-linux-intake.json' = $markJson }
    [void]$created.Add($recNote)
    $notePath = Join-Path $recNote 'windows-parity-linux-intake.json'
    $r = Invoke-Sweep -DocsPath $recNote -Seat linux -Record -Note $noteCite
    $ok = $false; $detail = "exit=" + $r.Exit
    try {
        $j = Get-Content -LiteralPath $notePath -Raw | ConvertFrom-Json
        $ok = ($r.Exit -eq 0 -and $j.lastEvaluated -eq '4a41394b2' -and $j.note -eq $noteCite -and $r.Text -match 'RECORDED')
        $detail += (" last={0}" -f $j.lastEvaluated)
    }
    catch { $detail += " parse failed: $_" }
    Check '12f a no-parity-owed commit cited in -Note is covered in the same run, and the note is kept' $ok $detail

    $r = Invoke-Sweep -DocsPath $recOk -Record
    Check '12e -Record without -Seat linux is refused (Windows records through main-intake.ps1)' `
        (($r.Exit -ne 0) -and ($r.Text -match 'main-intake')) ("exit=" + $r.Exit)

    Complete-TestBody  # T1039: the run reached the end of its body
}
finally {
    foreach ($d in $created) {
        if ($d -and (Test-Path -LiteralPath $d)) {
            Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Write-Host ''
if ($script:Failures -eq 0) {
    # A clean green run stamps the covered files (T783/T1768); red stays due.
    # Continue: under Stop, a stderr line from the native call through 2>&1
    # would throw in PowerShell 5.1.
    $ErrorActionPreference = 'Continue'
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot 'scripts\guard-due.ps1') `
        update -Guard parity-sweep -Repo $RepoRoot 2>&1 | ForEach-Object { "  $_" }
}
Write-TestVerdict -Label 'T152 PARITY SWEEP' -Pass $script:Passes -Fail $script:Failures
