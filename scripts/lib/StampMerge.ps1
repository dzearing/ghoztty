# Two loop lanes, one stamp (tracker T2027).
#
# A guard stamp (test\win32\<harness>.stamp.json, written by
# `scripts\guard-due.ps1 update`) records "this harness ran green against
# exactly these file hashes". Since T1986 two loop lanes run the same queue from
# two worktrees, and both re-stamp the shared harnesses (harness-floor,
# argv-hazard-audit, unroll-count-audit ...) on every turn that touches them.
# Two commits that each rewrite one stamp.json are a textual conflict on the
# commit guard's `pull --rebase` - JSON is not merge=union material - and the
# loop wedged on it closing T1986.
#
# The resolution rule is the one a person applied by hand that day: keep the
# NEWER stamp. A stamp is a whole-file claim, never a set of lines to splice,
# and the newer of two green runs is the better evidence about the merged tree.
# Choosing wrongly is cheap by construction: guard-due compares the kept stamp's
# hashes with the files on disk, so a stamp that does not describe the merged
# code reads DUE and the harness is simply run again. What the rule must never
# do is invent a stamp, so anything it cannot read is left to git as a conflict.

function Get-StampGenerated([string]$text) {
    # The stamp's own `generated` field, as an instant. $null for anything that
    # is not a readable stamp - an empty side (the file was added or deleted on
    # one branch), a conflict-marked file, hand-edited garbage.
    if (-not $text -or -not $text.Trim()) { return $null }
    try { $doc = $text | ConvertFrom-Json } catch { return $null }
    if ($null -eq $doc -or -not $doc.PSObject.Properties['generated']) { return $null }
    $raw = [string]$doc.generated
    $parsed = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse($raw, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::None, [ref]$parsed)) {
        return $parsed
    }
    return $null
}

function Select-NewerStamp([string]$ours, [string]$theirs) {
    # 'ours' | 'theirs' | $null (cannot decide: let git call it a conflict).
    # A tie keeps ours - the side already in the tree - so a resolution never
    # churns a file between two equally good answers.
    $o = Get-StampGenerated $ours
    $t = Get-StampGenerated $theirs
    if ($null -eq $o -or $null -eq $t) { return $null }
    if ($t -gt $o) { return 'theirs' }
    return 'ours'
}

function Test-StampPath([string]$relPath) {
    # The one shape guard-due writes. Kept in step with the .gitattributes line
    # `test/win32/*.stamp.json merge=ghoztty-stamp`.
    return (($relPath -replace '\\', '/') -match '^test/win32/[^/]+\.stamp\.json$')
}
