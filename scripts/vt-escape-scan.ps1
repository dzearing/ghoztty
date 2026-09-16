# vt-escape-scan (T740) - no PowerShell script in this repo writes `` `e `` and
# means ESC, because under Windows PowerShell 5.1 it is the letter e.
#
# THE TRAP. PowerShell 7 added `` `e `` as U+001B. 5.1 - the host every script
# here runs under - has no such escape: the backtick is dropped and the string is
# a plain `e`.
#
#     PS 5.1> $s = "`e"; "len=$($s.Length) code=$([int][char]$s[0])"
#     len=1 code=101        # 101 = 'e'. Not 27.
#
# That is silent in exactly the place it does the most damage: a VT-stripping
# regex. A pattern written "``e\[[0-9;]*m" reads as "the letter e, then [, then
# ..." - so the helper deletes an `e` here and there and leaves every escape
# sequence standing. Two acceptance scripts shipped that way for a month; their
# assertions kept passing because the markers they matched happened to contain
# no `e`.
#
# THE RULE. In a tracked `.ps1` / `.psm1` under the scanned roots, a backtick
# followed by a lowercase `e` INSIDE AN EXPANDABLE STRING is a finding. That
# scoping is the whole accuracy of the check, and it is why this walks the file
# with a small state machine rather than a regex:
#
#   * a single-quoted string does no escape processing at all, so
#     'the claim`s own line' is correct as written and is not a finding;
#   * a comment is prose, where `` `echo` `` and `` `error:` `` are markdown
#     inline code and mean nothing to the parser;
#   * a doubled backtick is a literal backtick, not an escape.
#
# Write ESC as `[char]27` (or `[regex]::Escape([string][char]27)` for a pattern),
# or use the shared helpers in `test\win32\lib\VtText.ps1`.
#
#   powershell -NoProfile -File scripts\vt-escape-scan.ps1
#   powershell -NoProfile -File scripts\vt-escape-scan.ps1 -Paths <file> [<file>...]
#
# Exit 0 = clean, 1 = findings. Acceptance: test\win32\vt-escape-scan.ps1.
param(
    [string]$Repo,
    # Scan these files instead of the standard roots (used by the acceptance
    # harness to point the scanner at fixtures).
    [string[]]$Paths,
    # Report the count only, no per-finding lines.
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Off

if (-not $Repo) { $Repo = Split-Path $PSScriptRoot -Parent }

# The roots that matter: the acceptance suite and the scripts that drive it.
# Both run under 5.1 and both are where a VT-stripping helper gets written.
$script:VT_SCAN_ROOTS = @('test\win32', 'scripts')

function Get-VtScanFiles([string]$RepoPath) {
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($root in $script:VT_SCAN_ROOTS) {
        $full = Join-Path $RepoPath $root
        if (-not (Test-Path -LiteralPath $full)) { continue }
        # NOTE -Include is filtered on the extension afterwards rather than
        # passed to Get-ChildItem: with -LiteralPath and -Recurse it is silently
        # ignored, which is how the first run of this scanner enumerated .js,
        # .md and .py files and reported markdown backticks as findings.
        Get-ChildItem -LiteralPath $full -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -eq '.ps1' -or $_.Extension -eq '.psm1' } |
            ForEach-Object { $out.Add($_.FullName) }
    }
    return @($out)
}

<#
.SYNOPSIS
Findings in one file: line number, column, and the line as written.

.DESCRIPTION
A single left-to-right walk of the whole file, carrying state across lines
because a string, a here-string and a block comment all span them. States:

  code    - ordinary script. A quote opens a string, a hash opens a line
            comment, a less-than-hash a block comment, an at-quote a
            here-string.
  single  - non-expanding string: nothing in it is an escape.
  double  - expanding string: THIS is where a backtick means something.
  block   - block comment, to its closing delimiter.
#>
function Get-VtEscapeFindings([string]$Path) {
    $findings = @()
    $text = ''
    try { $text = [System.IO.File]::ReadAllText($Path) } catch { return @() }
    $lines = $text -split "`r?`n"

    $state = 'code'          # code | single | double | block
    $hereTerminator = $null  # '"@' or ''@' while inside a here-string

    for ($i = 0; $i -lt $lines.Length; $i++) {
        $line = $lines[$i]

        # A here-string ends only at a line whose first characters are its
        # terminator; nothing inside it can close it early.
        if ($hereTerminator) {
            if ($line.TrimEnd() -eq $hereTerminator -or $line.StartsWith($hereTerminator)) {
                $hereTerminator = $null
                $state = 'code'
            } elseif ($state -eq 'double') {
                $findings += Find-VtEscapeInSpan $Path ($i + 1) $line
            }
            continue
        }

        $c = 0
        while ($c -lt $line.Length) {
            $ch = $line[$c]
            switch ($state) {
                'block' {
                    if ($ch -eq '>' -and $c -gt 0 -and $line[$c - 1] -eq '#') { $state = 'code' }
                    $c++
                }
                'single' {
                    if ($ch -eq "'") {
                        if ($c + 1 -lt $line.Length -and $line[$c + 1] -eq "'") { $c += 2; continue }
                        $state = 'code'
                    }
                    $c++
                }
                'double' {
                    if ($ch -eq '`') {
                        if ($c + 1 -lt $line.Length) {
                            if ($line[$c + 1] -eq 'e') {
                                $findings += [pscustomobject]@{
                                    Path = $Path; Line = $i + 1; Col = $c + 1; Text = $lines[$i].Trim()
                                }
                            }
                            $c += 2
                            continue
                        }
                        $c++   # trailing backtick: line continuation inside the string
                        continue
                    }
                    if ($ch -eq '"') {
                        if ($c + 1 -lt $line.Length -and $line[$c + 1] -eq '"') { $c += 2; continue }
                        $state = 'code'
                    }
                    $c++
                }
                default {
                    # code
                    if ($ch -eq '`') { $c += 2; continue }
                    if ($ch -eq '#') {
                        if ($c + 1 -lt $line.Length -and $line[$c + 1] -eq '>') { $c += 2; continue }
                        $c = $line.Length   # line comment
                        continue
                    }
                    if ($ch -eq '<' -and $c + 1 -lt $line.Length -and $line[$c + 1] -eq '#') {
                        $state = 'block'; $c += 2; continue
                    }
                    if ($ch -eq '@' -and $c + 1 -lt $line.Length -and ($line[$c + 1] -eq '"' -or $line[$c + 1] -eq "'")) {
                        $hereTerminator = "$($line[$c + 1])@"
                        $state = if ($line[$c + 1] -eq '"') { 'double' } else { 'single' }
                        $c = $line.Length
                        continue
                    }
                    if ($ch -eq '"') { $state = 'double'; $c++; continue }
                    if ($ch -eq "'") { $state = 'single'; $c++; continue }
                    $c++
                }
            }
        }

        # An unterminated ordinary string does not survive the newline in real
        # PowerShell parsing either; resetting here stops one stray quote in a
        # comment-free line from mis-scoping the whole rest of the file. A
        # here-string is the exception - its whole point is to span lines - and
        # not excluding it here is what made the first version of this scanner
        # blind to every here-string body.
        if (-not $hereTerminator -and ($state -eq 'single' -or $state -eq 'double')) { $state = 'code' }
    }
    return @($findings)
}

# A whole line that is known to be inside an expanding here-string, reported the
# same way the ordinary path reports.
function Find-VtEscapeInSpan([string]$Path, [int]$LineNo, [string]$Line) {
    $out = @()
    $c = 0
    while ($c -lt $Line.Length - 1) {
        if ($Line[$c] -ne '`') { $c++; continue }
        if ($Line[$c + 1] -eq 'e') {
            $out += [pscustomobject]@{ Path = $Path; Line = $LineNo; Col = $c + 1; Text = $Line.Trim() }
        }
        $c += 2
    }
    return @($out)
}

if ($MyInvocation.InvocationName -eq '.') { return }   # dot-sourced: functions only

$files = if ($Paths) { @($Paths) } else { Get-VtScanFiles $Repo }
$all = @()
foreach ($f in $files) { $all += Get-VtEscapeFindings $f }

if (@($all).Count -gt 0) {
    "BACKTICK-E ESCAPE: $(@($all).Count) use(s) of ``e, which is the letter e under PowerShell 5.1"
    if (-not $Quiet) {
        foreach ($f in $all) {
            $rel = $f.Path
            if ($rel.StartsWith($Repo, [System.StringComparison]::OrdinalIgnoreCase)) {
                $rel = $rel.Substring($Repo.Length).TrimStart('\', '/')
            }
            "  {0}:{1}:{2}  {3}" -f $rel, $f.Line, $f.Col, $f.Text
        }
        "  fix: write [char]27 (or use test\win32\lib\VtText.ps1)"
    }
    exit 1
}

"CLEAN: $($files.Count) file(s), no ``e escape"
exit 0
