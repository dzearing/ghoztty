# VtText (T740) - turn a captured VT stream back into the text a human would
# read, in ONE place, built on an escape character that is actually ESC.
#
# THE TRAP THIS EXISTS FOR. PowerShell 7 reads `` `e `` in a double-quoted string
# as U+001B. Windows PowerShell 5.1 - the host every script in this suite runs
# under - does not: it has no `e escape at all, so the backtick is dropped and
# the string is the single letter `e`.
#
#     PS 5.1> $s = "`e"; "len=$($s.Length) code=$([int][char]$s[0])"
#     len=1 code=101        # 101 = 'e'. Not 27.
#
# Two acceptance scripts had hand-rolled VT strippers written that way
# (`Snapshot-Text` in session-snapshot-reattach.ps1 and session-reattach-zombie.ps1),
# so their regexes said "delete every letter e" and left every escape sequence
# where it stood. Dumping a WP-D3 snapshot through one produced
# `C:\Us<e gone>rs\David>`: the letters removed, the CSI runs intact. The
# assertions on top still passed, because they matched markers that happen to
# contain no `e` and were never confronted with the sequences they meant to
# remove - a marker WITH an `e` would have failed for a reason nobody could see.
#
# So: `[char]27`, spelled out, and one implementation both callers share. The
# audit that keeps a new script from writing `` `e `` again is
# test\win32\vt-escape-scan.ps1 (a member of the harness floor).

Set-StrictMode -Off

# The escape character itself. Named rather than inlined so a reader can see
# what the regexes below are anchored on.
$script:VtEsc = [string][char]27

<#
.SYNOPSIS
Remove OSC, CSI and two-byte escape sequences from a captured VT stream.

.DESCRIPTION
Three passes, in order, matching what a pane snapshot actually carries:

  1. OSC - ESC ] ... terminated by BEL (0x07) or ST (ESC \). Window titles and
     shell-integration marks arrive this way.
  2. CSI - ESC [ params intermediates final. SGR runs, cursor moves, the bulk of
     a per-cell repaint.
  3. the two-byte forms - ESC followed by a single @-Z, \ or _.

Whitespace is deliberately left alone here; Get-VtReadableText is the caller
that also collapses it.
#>
function Remove-VtSequences([string]$Text) {
    if ($null -eq $Text) { return '' }
    $e = [regex]::Escape($script:VtEsc)
    $bel = [regex]::Escape([string][char]7)
    $t = [regex]::Replace($Text, "$e\][^$bel$e]*($bel|$e\\)", '')   # OSC
    $t = [regex]::Replace($t, "$e\[[0-9;:?]*[ -/]*[@-~]", '')       # CSI
    $t = [regex]::Replace($t, "$e[@-Z\\-_]", '')                    # 2-byte ESC
    return $t
}

<#
.SYNOPSIS
The readable text of a pane snapshot: escape sequences removed, then all
whitespace removed.

.DESCRIPTION
A snapshot is a per-CELL repaint, so a run of plain text is shot through with
SGR sequences and wrapped at the pane width. Dropping whitespace is the same
"match with the separators removed" technique the rest of the suite uses for
wrapped output, and it is what makes a substring assertion over a marker
survive a line break landing in the middle of it.
#>
function Get-VtReadableText([string]$Text) {
    if ($null -eq $Text) { return '' }
    return ((Remove-VtSequences $Text) -replace '\s', '')
}

<#
.SYNOPSIS
Decode a base64 snapshot payload to a string, or $null if it is not base64.
#>
function ConvertFrom-VtSnapshotBase64([string]$B64) {
    try { return [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($B64)) }
    catch { return $null }
}
