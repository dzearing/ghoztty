# CardRot.ps1 - does a task card's quoted EVIDENCE still describe the code? (T1474)
#
# A card can be right about the defect and wrong about its size. T676 swept
# seven cards on 2026-09-09 looking for phantoms and found none; what it found
# in three of them was rot: `hero-nav.ps1:464-465` had moved to `:488-489`,
# "the one other file under src/build/" had become one of three, and "roughly
# twenty more sites" was 55 across 21 files. None was closable, so no check
# looked at them, and each one would have handed the turn that claimed it a
# job planned at the wrong size.
#
# Two signals, both REPORTS and never verdicts (the T404 posture: a card whose
# evidence moved is a prompt to re-read, not proof that it is wrong):
#
#   LINE  a `path:N[-M]` or `path lines N-M` reference is re-resolved. The
#         lines are read at the commit where the card FIRST quoted them and
#         compared with the same lines now. Same text: fresh, silent. The text
#         is elsewhere in the file: MOVED, with where it went. The text is
#         gone: CHANGED. The file is now shorter than the reference: PAST END,
#         which needs no history and so works on a card git has never seen.
#   CLAIM a count or uniqueness phrase ("the only", "the one other", "the
#         remaining instance", "roughly twenty sites", "15 files") in a
#         paragraph that scopes it to a DIRECTORY that has changed since the
#         sentence was written. Counts over an area grow as the area grows;
#         a claim about one named file is the LINE check's job and the
#         existing touched= signal's, and flagging it too made the accurate
#         cards (T1030's "the one other suspect") read as rotted.
#
# Deliberately NOT done: rewriting the card. T676's corrections each carried a
# judgement ("not all 38 are defects - focus-defer.ps1 polls on purpose") that
# is not mechanizable.
#
# Dot-sourced by scripts\parity-tasks.ps1 (`next` prints ROT: lines for the
# card it hands out; `rot-scan` sweeps the queue). Pure PowerShell + git, no
# state, ASCII only.

$CardRotAreaRoots = '(?:src|scripts|test|macos|dist|include|images)'

# A code reference with a line number, in the two shapes the cards actually
# use: `test\win32\hero-nav.ps1:464-465` and `chooser-restore-all.ps1 lines
# 333-339`. The path is either rooted at a real top-level directory or a bare
# basename with a code extension (resolved the T1382 way: the ONE tracked file
# carrying it, or nothing).
$CardRotLinePattern = '(?<![\w./\\-])(?<path>' + $CardRotAreaRoots + '[\\/][\w.\\/-]*\w|\w[\w.-]*\.(?:ps1|zig|swift|md|json|yml|sh|c|h))`?(?::(?<a>\d+)(?:-(?<b>\d+))?(?!\d)|\s+lines?\s+(?<a2>\d+)(?:\s*(?:-|to)\s*(?<b2>\d+))?(?!\d))'

# Count / uniqueness phrases. Kept narrow on purpose: every phrase here has to
# be the kind of statement that goes false as an area grows. "about 40
# minutes" must not match, so an approximate number needs a countable noun -
# and so does "the only": a first sweep of the queue flagged three cards for
# "the only thing that ...", which is prose, not a count.
$CardRotCountNoun = '(?:sites?|files?|places?|instances?|callers?|call sites?|occurrences?|scripts?|hits?|uses?|copies|consumers?|references?|cards?|tests?)'
$CardRotNumber = '(?:\d+|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|fifteen|twenty|thirty|forty|fifty|a dozen|dozens of)'
$CardRotClaimPattern = '(?i)\b(?:the one other\b|the (?:only|last|remaining|sole)\s+(?:\w+\s+){0,2}?' + $CardRotCountNoun + '\b|only (?:one|remaining)\b|(?:roughly|about|around|some|~)\s*' + $CardRotNumber + '\s+(?:more\s+|other\s+)?' + $CardRotCountNoun + '\b|' + '\d+\s+(?:more\s+|other\s+)?' + $CardRotCountNoun + '\s+(?:across|under|in)\b)'

# Directory areas a paragraph names: `test\win32`, `src/build/`. A bare root
# word needs its slash (`test/`), or "`test` blocks" reads as the test tree.
$CardRotAreaPattern = '(?<![\w./\\-])(' + $CardRotAreaRoots + '(?:[\\/][\w.-]+)+|' + $CardRotAreaRoots + '(?=[\\/]))[\\/]?(?![\w.\\/-])'

function Invoke-CardRotGit {
    param([string]$Root, [string[]]$GitArgs)
    try {
        $out = @(& git -C $Root @GitArgs 2>$null)
        if ($LASTEXITCODE -ne 0) { return $null }
        return , $out
    } catch { return $null }
}

# Lines of a file at a revision ($Rev $null = the working tree), or $null.
function Get-CardRotFileLines {
    param([string]$Root, [string]$Rel, [string]$Rev)
    if (-not $Rev) {
        $full = Join-Path $Root $Rel
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return $null }
        try { return , [System.IO.File]::ReadAllLines($full) } catch { return $null }
    }
    $out = Invoke-CardRotGit -Root $Root -GitArgs @('show', ($Rev + ':' + $Rel))
    if ($null -eq $out) { return $null }
    return , ([string[]]$out)
}

function Test-CardRotIsDir {
    param([string]$Root, [string]$Rel, [string]$Rev)
    if (-not $Rev) { return (Test-Path -LiteralPath (Join-Path $Root $Rel) -PathType Container) }
    $t = Invoke-CardRotGit -Root $Root -GitArgs @('cat-file', '-t', ($Rev + ':' + $Rel))
    return ($null -ne $t -and ($t -join '') -match 'tree')
}

# basename -> repo-relative path ($null when two or more files share it), at a
# revision or in the working tree. The tracker's own files never count.
$script:CardRotNameIndex = @{}
function Get-CardRotNameIndex {
    param([string]$Root, [string]$Rev)
    $key = $Root + '|' + $Rev
    if ($script:CardRotNameIndex.ContainsKey($key)) { return $script:CardRotNameIndex[$key] }
    $files = if ($Rev) { Invoke-CardRotGit -Root $Root -GitArgs @('ls-tree', '-r', '--name-only', $Rev) }
    else { Invoke-CardRotGit -Root $Root -GitArgs @('ls-files') }
    $index = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($f in @($files)) {
        if (-not $f -or $f -match '^docs/design/windows-parity-') { continue }
        $name = $f.Substring($f.LastIndexOf('/') + 1)
        if ($index.ContainsKey($name)) { $index[$name] = $null } else { $index[$name] = $f }
    }
    $script:CardRotNameIndex[$key] = $index
    return $index
}

function Resolve-CardRotPath {
    param([string]$Root, [string]$Raw, [string]$Rev)
    $p = ($Raw -replace '\\', '/').TrimEnd('/')
    if ($p -match ('^' + $CardRotAreaRoots + '/')) { return $p }
    $hit = $null
    $index = Get-CardRotNameIndex -Root $Root -Rev $Rev
    if ($index.TryGetValue($p, [ref]$hit) -and $hit) { return $hit }
    return $null
}

# The card's history, oldest first: each revision's text, read lazily. The
# anchor for a quoted string is the FIRST revision that contains it - the
# moment its author read the code they were quoting.
function New-CardRotHistory {
    param([string]$Root, [string]$CardRel, [string]$Rev)
    $range = if ($Rev) { $Rev } else { 'HEAD' }
    $revs = Invoke-CardRotGit -Root $Root -GitArgs @('log', '--reverse', '--format=%H %aI', $range, '--', $CardRel)
    $list = New-Object System.Collections.ArrayList
    foreach ($l in @($revs)) {
        if (-not $l) { continue }
        $bits = $l.Split(' ', 2)
        [void]$list.Add([pscustomobject]@{ Sha = $bits[0]; When = $bits[1]; Text = $null })
    }
    return [pscustomobject]@{ Root = $Root; CardRel = $CardRel; Revs = $list }
}

function Find-CardRotAnchor {
    param($History, [string]$Needle)
    foreach ($r in $History.Revs) {
        if ($null -eq $r.Text) {
            $t = Invoke-CardRotGit -Root $History.Root -GitArgs @('show', ($r.Sha + ':' + $History.CardRel))
            $r.Text = if ($null -eq $t) { '' } else { ($t -join "`n") }
        }
        if ($r.Text.Contains($Needle)) { return $r }
    }
    return $null
}

function Get-CardRotNorm { param([string[]]$Lines) return @($Lines | ForEach-Object { ($_ -replace '\s+', ' ').Trim() }) }

# Where does $Slice (normalised) start in $All (normalised)? Every match, as
# 1-based line numbers.
function Find-CardRotSlice {
    param([string[]]$All, [string[]]$Slice)
    $hits = @()
    if ($Slice.Count -eq 0 -or $All.Count -lt $Slice.Count) { return $hits }
    for ($i = 0; $i -le $All.Count - $Slice.Count; $i++) {
        $ok = $true
        for ($j = 0; $j -lt $Slice.Count; $j++) { if ($All[$i + $j] -ne $Slice[$j]) { $ok = $false; break } }
        if ($ok) { $hits += ($i + 1) }
    }
    return $hits
}

# Card body split into paragraphs: blank lines separate them, and every list
# item or progress-log bullet starts its own. Checkbox items are dropped -
# a validation criterion is a promise about the future, not evidence.
function Get-CardRotParagraphs {
    param([string]$Body)
    $paras = @(); $cur = @()
    foreach ($line in ($Body -split "`r?`n")) {
        $starts = $line -match '^\s*(?:[-*]\s|\d+\.\s)'
        if (-not $line.Trim() -or ($starts -and $cur.Count -gt 0)) {
            if ($cur.Count -gt 0) { $paras += , $cur; $cur = @() }
            if (-not $line.Trim()) { continue }
        }
        $cur += $line
    }
    if ($cur.Count -gt 0) { $paras += , $cur }
    return @($paras | Where-Object { $_[0] -notmatch '^\s*[-*]\s+\[[ xX]\]' })
}

# The findings for one card. $Text is the card as it stands at $Rev (or on
# disk when $Rev is empty); $CardRel is its repo-relative path, used to ask
# git when each quoted string first appeared. A card git has never seen gets
# the PAST END check only - there is no "when it was written" to compare with.
function Get-CardRot {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$CardRel,
        [Parameter(Mandatory = $true)][string]$Text,
        [string]$Rev
    )
    $findings = @()
    $body = $Text
    if ($body -match '(?s)^---\r?\n.*?\r?\n---\r?\n(.*)$') { $body = $Matches[1] }
    # Most cards quote neither; they cost no git call at all.
    if ($body -notmatch $CardRotLinePattern -and $body -notmatch $CardRotClaimPattern) { return @() }
    $history = New-CardRotHistory -Root $Root -CardRel ($CardRel -replace '\\', '/') -Rev $Rev
    $head = if ($Rev) { $Rev } else { 'HEAD' }
    $seen = @{}

    foreach ($m in [regex]::Matches($body, $CardRotLinePattern)) {
        $raw = $m.Groups['path'].Value
        $a = if ($m.Groups['a'].Success) { [int]$m.Groups['a'].Value } else { [int]$m.Groups['a2'].Value }
        $bG = if ($m.Groups['b'].Success) { $m.Groups['b'] } else { $m.Groups['b2'] }
        $b = if ($bG.Success) { [int]$bG.Value } else { $a }
        if ($a -lt 1 -or $b -lt $a) { continue }
        if ($b - $a -gt 40) { $b = $a + 40 }
        $rel = Resolve-CardRotPath -Root $Root -Raw $raw -Rev $Rev
        if (-not $rel) { continue }
        $key = "$rel|$a|$b"
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $ref = if ($a -eq $b) { "{0}:{1}" -f $rel, $a } else { "{0}:{1}-{2}" -f $rel, $a, $b }

        $now = Get-CardRotFileLines -Root $Root -Rel $rel -Rev $Rev
        if ($null -eq $now) { continue }   # file gone: touched= / CHECK FIRST already say so
        if ($a -gt $now.Count) {
            $findings += [pscustomobject]@{ Kind = 'PAST END'; Ref = $ref; Detail = ("the file has {0} lines now" -f $now.Count) }
            continue
        }
        $anchor = Find-CardRotAnchor -History $history -Needle $m.Value
        if (-not $anchor) { continue }
        $then = Get-CardRotFileLines -Root $Root -Rel $rel -Rev $anchor.Sha
        if ($null -eq $then -or $b -gt $then.Count) { continue }
        $thenSlice = Get-CardRotNorm $then[($a - 1)..($b - 1)]
        if (-not (($thenSlice -join '').Trim())) { continue }
        $nowEnd = [math]::Min($b, $now.Count)
        $nowSlice = Get-CardRotNorm $now[($a - 1)..($nowEnd - 1)]
        if (($thenSlice -join "`n") -eq ($nowSlice -join "`n")) { continue }
        $hits = @(Find-CardRotSlice -All (Get-CardRotNorm $now) -Slice $thenSlice)
        $since = $anchor.When.Substring(0, 10)
        if ($hits.Count -gt 0) {
            $best = $hits | Sort-Object { [math]::Abs($_ - $a) } | Select-Object -First 1
            $to = if ($a -eq $b) { ":$best" } else { ":{0}-{1}" -f $best, ($best + $b - $a) }
            $findings += [pscustomobject]@{ Kind = 'MOVED'; Ref = $ref; Detail = ("quoted {0}; those lines are now at {1}" -f $since, $to) }
        } else {
            $findings += [pscustomobject]@{ Kind = 'CHANGED'; Ref = $ref; Detail = ("quoted {0}; the lines it pointed at no longer exist in that form" -f $since) }
        }
    }

    foreach ($para in (Get-CardRotParagraphs -Body $body)) {
        $joined = ($para -join ' ')
        $cm = [regex]::Match($joined, $CardRotClaimPattern)
        if (-not $cm.Success) { continue }
        $areas = @()
        foreach ($am in [regex]::Matches($joined, $CardRotAreaPattern)) {
            $rel = ($am.Groups[1].Value -replace '\\', '/').TrimEnd('/')
            if ($areas -contains $rel) { continue }
            if (Test-CardRotIsDir -Root $Root -Rel $rel -Rev $Rev) { $areas += $rel }
        }
        if ($areas.Count -eq 0) { continue }
        # Anchor on the physical line carrying the phrase: a wrapped sentence
        # is not a substring of the file, but each of its lines is.
        $phrase = $cm.Value
        $carrier = $para | Where-Object { $_ -match [regex]::Escape($phrase.Split(' ')[0]) -and ($_ -replace '\s+', ' ') -match [regex]::Escape(($phrase -split '\s+')[-1]) } | Select-Object -First 1
        if (-not $carrier) { $carrier = $para[0] }
        $anchor = Find-CardRotAnchor -History $history -Needle $carrier.Trim()
        if (-not $anchor) { continue }
        $moved = Invoke-CardRotGit -Root $Root -GitArgs (@('rev-list', '--count', '--no-merges', ($anchor.Sha + '..' + $head), '--') + $areas)
        $n = if ($null -eq $moved) { 0 } else { [int](($moved -join '').Trim()) }
        if ($n -eq 0) { continue }
        $findings += [pscustomobject]@{
            Kind = 'CLAIM'; Ref = ('"{0}"' -f $phrase.Trim())
            Detail = ("written {0} about {1}; {2} commit(s) have changed it since - re-measure" -f $anchor.When.Substring(0, 10), ($areas -join ', '), $n)
        }
    }
    return @($findings)
}
