<#
.SYNOPSIS
  Fails when a union-merged ledger holds the same entry twice (T1025).

.DESCRIPTION
  T957 put the two shared append-only ledgers - docs/design/windows-parity-log.md
  and docs/design/windows-parity-feature-ideas.md - under git's built-in `union`
  merge driver, so a collision between the two seats merges silently instead of
  stopping a `git pull --rebase` with a conflict. That is the right trade: the
  conflict was always resolved by keeping both sides. But union is not free. A
  rebase that replays a commit whose entry is already in the file, or an old
  entry edited on both seats, comes out of the merge as the SAME entry twice, and
  nothing was obliged to notice. A conflict at least stopped somebody; this is
  the "somebody looks at it" half that the driver removed.

  Which files: every `.md` path that .gitattributes puts under `merge=union`. The
  list is read from the driver's own configuration rather than written down here,
  so a ledger added to the union set next month is checked from the day it joins.

  What an entry is: a block that opens at a `## ` heading or at a column-0 dated
  bullet (`- YYYY-MM-DD...`, the newest-first shape at the top of the log), and
  runs to the next one. Everything above the first entry is the file's preamble
  and is not checked.

  Three findings, each the trace a specific union accident leaves:

    DUPLICATE ENTRY    two entries identical from heading to last line - a
                       replayed commit appending an entry that was already there.
    DUPLICATE HEADING  two entries that open with the same line but whose bodies
                       differ - the same entry, edited one way on each seat.
    REPEATED LINE      one line occurring twice inside a single entry - the shape
                       union leaves when both seats changed the same lines of an
                       entry and it kept both versions of the hunk.

  What is NOT a finding: the same date and task id on two headings (one task
  routinely gets several entries in a day - T217 had seven on 2026-07-31), and a
  sentence repeated across DIFFERENT entries (floor boilerplate legitimately
  recurs). Both were measured against the live log before this check was
  written, and neither is the shape a union accident produces.

  Heading comparison folds an em or en dash to a hyphen and collapses runs of
  whitespace, because the log carries both dash styles and a hand edit on one
  seat can change one without changing what the heading says.

.PARAMETER Paths
  Check exactly these files (repo-relative or absolute) instead of the union set
  from .gitattributes. The acceptance harness uses this to point the check at a
  fixture.

.PARAMETER Repo
  Repository root. Defaults to the parent of this script's directory.

.PARAMETER MinLineLength
  Shortest trimmed line that REPEATED LINE considers. A bullet item (`- ...`) is
  considered at any length, because a feature idea is one short line and a
  duplicated one is exactly what this exists to see.

.EXAMPLE
  powershell -NoProfile -File scripts\ledger-dupes.ps1
  powershell -NoProfile -File scripts\ledger-dupes.ps1 -Paths temp\fixture\log.md

.OUTPUTS
  Exit 0 = clean. Exit 1 = at least one finding (each printed as file:line with
  the line it repeats). Exit 2 = the check could not run.
#>
[CmdletBinding()]
param(
    [string[]]$Paths,
    [string]$Repo,
    [int]$MinLineLength = 40,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

if (-not $Repo) { $Repo = Split-Path -Parent $PSScriptRoot }
if (-not (Test-Path -LiteralPath $Repo)) {
    Write-Host "LEDGER DUPLICATES: repo not found: $Repo"
    exit 2
}
$Repo = (Resolve-Path -LiteralPath $Repo).ProviderPath

# The union set, from the driver's own configuration. Only markdown: .gitignore
# is also union-merged, and a repeated ignore pattern is harmless noise rather
# than a ledger accident.
function Get-UnionLedgers {
    param([string]$Root)
    $attr = Join-Path $Root '.gitattributes'
    if (-not (Test-Path -LiteralPath $attr)) { return @() }
    $found = @()
    foreach ($line in [System.IO.File]::ReadAllLines($attr)) {
        $t = $line.Trim()
        if (-not $t -or $t.StartsWith('#')) { continue }
        $parts = @($t -split '\s+')
        if ($parts.Count -lt 2) { continue }
        if (@($parts | Select-Object -Skip 1) -notcontains 'merge=union') { continue }
        if ($parts[0] -notlike '*.md') { continue }
        $found += $parts[0]
    }
    return $found
}

$targets = @()
if ($Paths) {
    foreach ($p in $Paths) {
        if ([System.IO.Path]::IsPathRooted($p)) { $targets += $p } else { $targets += (Join-Path $Repo $p) }
    }
} else {
    foreach ($rel in (Get-UnionLedgers -Root $Repo)) {
        $targets += (Join-Path $Repo ($rel -replace '/', '\'))
    }
    if ($targets.Count -eq 0) {
        # A union set that reads as empty is a broken parse or a moved file, not
        # a clean ledger; saying CLEAN over it would be the silent pass this
        # check exists to prevent.
        Write-Host "LEDGER DUPLICATES: no merge=union markdown files found in .gitattributes - nothing to check"
        exit 2
    }
}

$EntryStart = '^(## |- \d{4}-\d{2}-\d{2})'

function Get-HeadingKey([string]$Line) {
    $k = $Line.Trim()
    $k = $k.Replace([string][char]0x2014, '-').Replace([string][char]0x2013, '-')
    $k = $k -replace '\s+', ' '
    return $k
}

function Get-Entries {
    param([string[]]$Lines)
    $entries = New-Object System.Collections.Generic.List[object]
    $cur = $null
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $line = $Lines[$i]
        if ($line -match $EntryStart) {
            if ($cur) { $entries.Add($cur) }
            $cur = [pscustomobject]@{ Line = $i + 1; Lines = (New-Object System.Collections.Generic.List[string]) }
        }
        if ($cur) { $cur.Lines.Add($line) }
    }
    if ($cur) { $entries.Add($cur) }
    return $entries
}

$findings = New-Object System.Collections.Generic.List[string]
$entryCount = 0

foreach ($path in $targets) {
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Host "LEDGER DUPLICATES: ledger not found: $path"
        exit 2
    }
    $shown = $path
    if ($path.StartsWith($Repo, [System.StringComparison]::OrdinalIgnoreCase)) {
        $shown = $path.Substring($Repo.Length).TrimStart('\', '/')
    }
    $lines = [System.IO.File]::ReadAllLines($path, [System.Text.Encoding]::UTF8)
    $entries = @(Get-Entries -Lines $lines)
    $entryCount += $entries.Count

    $byText = @{}
    $byHeading = @{}
    foreach ($e in $entries) {
        # Trailing whitespace and trailing blank lines are not content: the
        # separator after an entry depends on what follows it, so the same entry
        # at the end of a file and in the middle must still compare equal.
        $norm = @($e.Lines | ForEach-Object { $_.TrimEnd() })
        $last = $norm.Count - 1
        while ($last -ge 0 -and -not $norm[$last]) { $last-- }
        $text = ($norm[0..$last] -join "`n")
        $head = Get-HeadingKey $e.Lines[0]

        if ($byText.ContainsKey($text)) {
            $findings.Add(("DUPLICATE ENTRY {0}:{1} repeats the entry at line {2}: {3}" -f
                    $shown, $e.Line, $byText[$text], $e.Lines[0].Trim()))
        } else {
            $byText[$text] = $e.Line
            if ($byHeading.ContainsKey($head)) {
                $findings.Add(("DUPLICATE HEADING {0}:{1} opens like the entry at line {2} but differs from it: {3}" -f
                        $shown, $e.Line, $byHeading[$head], $e.Lines[0].Trim()))
            } else {
                $byHeading[$head] = $e.Line
            }
        }

        $seen = @{}
        for ($j = 1; $j -lt $e.Lines.Count; $j++) {
            $t = $e.Lines[$j].Trim()
            if (-not $t) { continue }
            if ($t.Length -lt $MinLineLength -and -not $t.StartsWith('- ')) { continue }
            if ($seen.ContainsKey($t)) {
                $findings.Add(("REPEATED LINE {0}:{1} repeats line {2} inside the entry at line {3}: {4}" -f
                        $shown, ($e.Line + $j), $seen[$t], $e.Line, $t))
            } else {
                $seen[$t] = $e.Line + $j
            }
        }
    }
}

if ($findings.Count -eq 0) {
    if (-not $Quiet) {
        Write-Host ("CLEAN: {0} entries in {1} union-merged ledger(s), no duplicates" -f $entryCount, $targets.Count)
    }
    exit 0
}

Write-Host ("LEDGER DUPLICATES: {0} finding(s) - union merge keeps both sides silently, so this is the only place a doubled entry is ever seen (T1025)" -f $findings.Count)
foreach ($f in $findings) {
    $one = $f
    if ($one.Length -gt 220) { $one = $one.Substring(0, 217) + '...' }
    Write-Host ("  " + $one)
}
Write-Host "  (delete the second copy, or merge the two edited versions into one entry)"
exit 1
