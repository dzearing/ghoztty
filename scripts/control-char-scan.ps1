<#
.SYNOPSIS
  Fails when a repository text file contains a control character that no text
  file should ever hold (T1231).

.DESCRIPTION
  On 2026-09-01 fifteen tracked files were found carrying real control
  characters where a Windows path had been written with a backslash escape:
  a tool interpreted `\a`, `\b` and `\f` and wrote 0x07, 0x08 and 0x0c into the
  file. `zig-out\bin` became `zig-out<BS>in`; `scripts\floor-lane.ps1` became
  `scripts<FF>loor-lane.ps1`; `src\apprt\win32\install_prepare.zig` inside
  scripts\guard-due.ps1's coverage table became `src<BEL>pprt\...`, so that
  guard row could never resolve the file it claimed to cover.

  This is the exact shape a check should own. The damage is trivially
  detectable and IMPOSSIBLE to see by eye - a reader sees the two halves of the
  path run together and assumes a typo - and in a live path string it is a path
  that quietly does not exist, which nothing reports as anything but not-found.

  What counts as damage: any byte below 0x20 other than tab (0x09), line feed
  (0x0a) and carriage return (0x0d), plus DEL (0x7f). Since T1263 also a
  carriage return that is not half of a CRLF, and a tab glued between path
  segments - the shapes a decoded `\r` / `\t` leaves (scripts\lib\EscapeDamage.ps1).

  The writer, found in T1263, is the tool-call channel: an Edit/Write whose JSON
  arguments carry one backslash has it decoded before the file is touched.
  scripts\hooks\deny-escape-damage.ps1 refuses such a call at write time; this
  scan is the commit-time net behind it.

  Scope: TRACKED files (git ls-files) whose extension is in the allowlist
  below. The allowlist rather than "every text file" is deliberate - the
  libghostty fuzz corpora under test/fuzz-libghostty/corpus/ are extensionless
  fixtures whose whole point is to hold control bytes, and a check that has to
  be argued with about its own exclusions is a check people learn to skip.

.PARAMETER Staged
  Scan the files staged for commit instead of the whole tracked tree. This is
  what the pre-commit hook asks for: it is bounded by the commit rather than the
  repo, so it costs nothing on a two-file commit.

.PARAMETER Paths
  Scan exactly these paths (relative to the repo root, or absolute). Used by
  the acceptance harness to point the scanner at a fixture.

.PARAMETER Repo
  Repository root. Defaults to the parent of this script's directory.

.EXAMPLE
  powershell -NoProfile -File scripts\control-char-scan.ps1
  powershell -NoProfile -File scripts\control-char-scan.ps1 -Staged
  powershell -NoProfile -File scripts\control-char-scan.ps1 -Paths temp\fixture\a.md

.OUTPUTS
  Exit 0 = clean. Exit 1 = at least one control character found (each one is
  printed as file:line:col with the offending line rendered so the invisible
  byte becomes visible). Exit 2 = the scan could not run.
#>
[CmdletBinding()]
param(
    [switch]$Staged,
    [string[]]$Paths,
    [string]$Repo,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

if (-not $Repo) { $Repo = Split-Path -Parent $PSScriptRoot }
if (-not (Test-Path -LiteralPath $Repo)) {
    Write-Host "CONTROL CHAR SCAN: repo not found: $Repo"
    exit 2
}
# Normalize before anything compares against it: the git hook hands this a
# forward-slash path (`D:/git/ghoztty`) and every path built below uses
# backslashes, so without this a finding would be reported as an absolute path
# instead of the repo-relative one a reader can act on.
$Repo = (Resolve-Path -LiteralPath $Repo).ProviderPath

# What counts - the extension allowlist, the bad bytes, and since T1263 the
# lone-CR and tab-in-path shapes a decoded `\r` / `\t` leaves - lives in one
# place, shared with the write-time hook (scripts\hooks\deny-escape-damage.ps1).
. (Join-Path $PSScriptRoot 'lib\EscapeDamage.ps1')

function Get-ScanTargets {
    if ($Paths) {
        return @($Paths | ForEach-Object {
            if ([System.IO.Path]::IsPathRooted($_)) { $_ } else { Join-Path $Repo $_ }
        })
    }

    Push-Location $Repo
    try {
        if ($Staged) {
            # Added/copied/modified/renamed only: a deletion has no content to
            # scan and would otherwise report as an unreadable path.
            $listed = & git diff --cached --name-only --diff-filter=ACMR 2>$null
        } else {
            $listed = & git ls-files 2>$null
        }
        if ($LASTEXITCODE -ne 0) { throw "git listing failed in $Repo" }
    } finally {
        Pop-Location
    }

    $out = New-Object System.Collections.Generic.List[string]
    foreach ($rel in $listed) {
        if (-not $rel) { continue }
        if (-not (Test-EscapeDamageExtension $rel)) { continue }
        $out.Add((Join-Path $Repo $rel))
    }
    return $out
}

try {
    $targets = @(Get-ScanTargets)
} catch {
    Write-Host ("CONTROL CHAR SCAN: could not enumerate files - {0}" -f $_.Exception.Message)
    exit 2
}

$findings = New-Object System.Collections.Generic.List[object]

foreach ($path in $targets) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
    try {
        $text = [System.IO.File]::ReadAllText($path)
    } catch {
        continue
    }
    # One native IndexOfAny pass and one regex pass in the common case (no
    # hit); only a file that HAS a hit pays for the line/column arithmetic.
    $hits = Find-EscapeDamage $text
    if ($hits.Count -eq 0) { continue }

    $rel = $path
    if ($path.StartsWith($Repo, [System.StringComparison]::OrdinalIgnoreCase)) {
        $rel = $path.Substring($Repo.Length).TrimStart('\', '/')
    }

    foreach ($h in $hits) {
        $findings.Add([pscustomobject]@{
            File    = $rel
            Line    = $h.Line
            Col     = $h.Col
            Code    = $h.Code
            Kind    = $h.Kind
            Context = Format-EscapeDamageContext $text $h.Index
        })
    }
}

if ($findings.Count -eq 0) {
    if (-not $Quiet) {
        Write-Host ("CONTROL CHAR SCAN CLEAN: {0} file(s)" -f $targets.Count)
    }
    exit 0
}

Write-Host ("CONTROL CHARACTERS IN {0} FILE(S) - a text file must not hold one (T1231):" -f (@($findings | Select-Object -ExpandProperty File -Unique)).Count)
foreach ($f in $findings) {
    $kind = if ($f.Kind -ne 'control') { " ($($f.Kind))" } else { '' }
    Write-Host ("  {0}:{1}:{2}  {3}{4}  {5}" -f $f.File, $f.Line, $f.Col, $f.Code, $kind, $f.Context)
}
Write-Host ""
Write-Host "  These are a backslash escape decoded on the way in - in practice a tool"
Write-Host "  call whose JSON arguments carried ONE backslash before a, b, f, r or t"
Write-Host "  (T1263): 0x07 was '\a', 0x08 '\b', 0x0c '\f', a lone 0x0d '\r', a tab"
Write-Host "  inside a path '\t' - so 'zig-out\bin' is now 'zig-out<0x08>in'."
Write-Host "  Restore the backslash the path was MEANT to have"
Write-Host "  rather than deleting the byte, and never rewrite the whole file from"
Write-Host "  PowerShell to do it (that re-encodes it); patch the one line."
exit 1
