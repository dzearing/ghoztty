# release-notes-author.ps1 -- write the bundled release notes for a Windows
# release from the work that landed since the previous one (T1444).
#
# THE PROBLEM THIS EXISTS FOR. T624 put the "What's New in Ghoztty" window on
# Windows. It reads release-notes\{client,agent}\<version>.json, which are
# EMBEDDED in the exe at build time (src\build\GhosttyReleaseNotes.zig). On the
# Mac seat those files are written by hand as step 2 of the release command,
# before the tag. The Windows publish is a tag push the loop makes on its own
# (daily-publish.ps1 -> publish-windows-tag.ps1), and nothing in it wrote a
# notes file for the version it minted. So every win-v release shipped the notes
# that happened to exist when the Mac line last moved, and the window a user
# opened after updating described work from weeks earlier.
#
# WHAT IT DRAWS ON. The same evidence the digest does: the commits since the
# previous win-v tag. Every task-closing commit already carries a subject
# written for a reader ("Your commit message is the activity feed", go.md step
# 6), and its task file says whether the work is user-facing through its tags.
# So an item is a commit that names a task (T<id>) whose tags include
# feature / fix / polish / perf / security; infra, test and docs work is the
# project's own business and is left out. `chore(...)` commits never count.
#
# SCOPE, per release-notes\README.md: a commit that touches src\remote\ (the
# session-persistence agent) goes to agent\<version>.json, which the
# agent-restart dialog shows; everything else goes to client\<version>.json.
#
# NOTHING TO SAY IS AN OUTCOME, NOT A MISSING FILE. A range with no user-facing
# work still writes client\<version>.json, with one plain line saying so,
# because a missing file makes the window show an older release as if it were
# the one just installed -- which is the defect this exists to remove.
#
# A file that already exists is left alone (NOTES EXIST): notes written by hand
# for that version win over generated ones.
#
#   scripts\release-notes-author.ps1 -Version 1.54.11              # writes
#   scripts\release-notes-author.ps1 -Version 1.54.11 -DryRun      # prints only
#   scripts\release-notes-author.ps1 -Version 1.54.11 -Since win-v1.54.9
#
# Output contract (read by publish-windows-tag.ps1): one `NOTES ...` verdict
# line per scope, and one `NOTES-PATH <repo-relative path>` line for every file
# it wrote. Exit 0 always on a decided outcome, 1 when it could not decide.
#
# Acceptance: section S of test\win32\daily-publish.ps1.
[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$Version = '',
    # The commit-ish the range starts after. Empty = the nearest win-v tag that
    # is an ancestor of HEAD.
    [string]$Since = '',
    # Test seam. Empty = the repo this script lives in.
    [string]$Repo = '',
    # Where the scope directories live. Empty = <Repo>\release-notes.
    [string]$OutDir = '',
    [switch]$DryRun
)
$ErrorActionPreference = 'Continue'

# The tags that make a task something a user of the terminal would notice.
$script:UserFacingTags = @('feature', 'fix', 'polish', 'perf', 'security')

# Section titles, in the order they are shown.
$script:SectionOrder = @(
    @{ Kind = 'feature'; Title = 'New' },
    @{ Kind = 'fix'; Title = 'Fixes' },
    @{ Kind = 'improve'; Title = 'Improvements' }
)

# The one line a release with nothing user-facing carries.
$script:NothingToSayText = 'No user-visible changes in this release: it carries reliability, test and tooling work behind the scenes.'

# ---- pure helpers (dot-sourceable by the acceptance harness) ---------------

# The tags list out of a task file's frontmatter: `tags: ["fix", "polish"]`.
function Get-TaskFileTags([string]$Text) {
    if (-not $Text) { return @() }
    $m = [regex]::Match($Text, '(?m)^tags:\s*\[([^\]]*)\]')
    if (-not $m.Success) { return @() }
    return @([regex]::Matches($m.Groups[1].Value, '"([^"]+)"') | ForEach-Object { $_.Groups[1].Value.Trim().ToLowerInvariant() })
}

# Which section a task's tags put it in, or '' when it is not user-facing.
# A task may carry several; the most newsworthy wins (feature > fix > the rest).
function Get-ReleaseNoteKind([string[]]$Tags) {
    $t = @($Tags | ForEach-Object { "$_".ToLowerInvariant() })
    if ($t -contains 'feature') { return 'feature' }
    if ($t -contains 'fix') { return 'fix' }
    foreach ($x in @('polish', 'perf', 'security')) { if ($t -contains $x) { return 'improve' } }
    return ''
}

# A commit subject as a release-note line: the trailing task reference goes.
# "Signing back in ... restarting the app (T1428)" -> "Signing back in ... restarting the app."
function ConvertTo-ReleaseNoteText([string]$Subject) {
    $s = "$Subject".Trim()
    $s = [regex]::Replace($s, '\s*\((T\d+[^)]*)\)\s*$', '')
    $s = $s.Trim()
    if ($s -and $s -notmatch '[.!?]$') { $s += '.' }
    return $s
}

# Commits -> note items. Each commit is @{ Subject; Files }. TagLookup maps a
# task id to its tags (a scriptblock, so the harness can inject one).
function Select-ReleaseNoteItems {
    param($Commits, [scriptblock]$TagLookup)
    $items = New-Object System.Collections.ArrayList
    $seen = @{}
    foreach ($c in @($Commits)) {
        if (-not $c) { continue }
        $subject = "$($c.Subject)".Trim()
        if (-not $subject) { continue }
        if ($subject -match '^(chore|Merge|Revert)\b') { continue }
        $m = [regex]::Match($subject, '\((T\d+)[^)]*\)\s*$')
        if (-not $m.Success) { continue }
        $tid = $m.Groups[1].Value
        $kind = Get-ReleaseNoteKind -Tags @(& $TagLookup $tid)
        if (-not $kind) { continue }
        $text = ConvertTo-ReleaseNoteText $subject
        if (-not $text -or $seen.ContainsKey($text)) { continue }
        $seen[$text] = $true
        $scope = if (@($c.Files | Where-Object { "$_" -match '^src[\\/]remote[\\/]' }).Count) { 'agent' } else { 'client' }
        [void]$items.Add([pscustomobject]@{ Scope = $scope; Kind = $kind; Text = $text; Task = $tid })
    }
    # Unrolled on purpose: callers wrap the call in @(), and `return ,` would
    # hand them ONE element that is the whole list.
    return $items.ToArray()
}

function ConvertTo-JsonString([string]$s) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($ch in $s.ToCharArray()) {
        switch ($ch) {
            '"' { [void]$sb.Append('\"') }
            '\' { [void]$sb.Append('\\') }
            "`n" { [void]$sb.Append('\n') }
            "`r" { [void]$sb.Append('\r') }
            "`t" { [void]$sb.Append('\t') }
            default {
                if ([int]$ch -lt 0x20) { [void]$sb.Append(('\u{0:x4}' -f [int]$ch)) } else { [void]$sb.Append($ch) }
            }
        }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

# The notes document for one scope, in the house shape of release-notes\*.json.
# Empty items yields the "nothing to say" document.
function ConvertTo-ReleaseNotesJson {
    param([string]$Version, $Items)
    $all = @($Items | Where-Object { $_ })
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add('{')
    [void]$lines.Add("  `"version`": $(ConvertTo-JsonString $Version),")
    [void]$lines.Add('  "sections": [')
    $sections = New-Object System.Collections.ArrayList
    if (-not $all.Count) {
        [void]$sections.Add("    { `"title`": `"This release`",`n      `"items`": [`n        { `"text`": $(ConvertTo-JsonString $script:NothingToSayText) }`n      ] }")
    } else {
        foreach ($sec in $script:SectionOrder) {
            $mine = @($all | Where-Object { $_.Kind -eq $sec.Kind })
            if (-not $mine.Count) { continue }
            $itemLines = @($mine | ForEach-Object { "        { `"text`": $(ConvertTo-JsonString $_.Text) }" })
            [void]$sections.Add("    { `"title`": $(ConvertTo-JsonString $sec.Title),`n      `"items`": [`n$($itemLines -join ",`n")`n      ] }")
        }
    }
    [void]$lines.Add(($sections.ToArray() -join ",`n"))
    [void]$lines.Add('  ]')
    [void]$lines.Add('}')
    return (($lines.ToArray() -join "`n") + "`n")
}

if ($env:GHOZTTY_RELEASE_NOTES_DOTSOURCE -eq '1') { return }

# ---- the run ----------------------------------------------------------------

function Fail([string]$m) { Write-Host "NOTES FAILED: $m"; exit 1 }

if ($Version -notmatch '^\d+\.\d+\.\d+$') { Fail "Version must be X.Y.Z (got '$Version')" }
if (-not $Repo) { $Repo = Split-Path -Parent $PSScriptRoot }
if (-not $OutDir) { $OutDir = Join-Path $Repo 'release-notes' }

# git prints UTF-8; PS 5.1 decodes native output with the console's code page,
# which turns an em dash in a subject into mojibake in a file the user reads.
$prevEnc = [Console]::OutputEncoding
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
try {
    if (-not $Since) {
        $Since = (& git -C $Repo describe --tags --abbrev=0 --match 'win-v*' HEAD 2>$null)
        if ($LASTEXITCODE -ne 0 -or -not $Since) { Fail 'no win-v tag is an ancestor of HEAD; pass -Since <commit>' }
        $Since = "$Since".Trim()
    }
    & git -C $Repo rev-parse -q --verify "$Since^{commit}" *> $null
    if ($LASTEXITCODE -ne 0) { Fail "-Since '$Since' is not a commit here" }

    $raw = @(& git -C $Repo log --reverse --no-merges --name-only --format='@@COMMIT@@%s' "$Since..HEAD" 2>$null)
    if ($LASTEXITCODE -ne 0) { Fail "could not read the log for $Since..HEAD" }
} finally {
    try { [Console]::OutputEncoding = $prevEnc } catch { }
}

$commits = New-Object System.Collections.ArrayList
$cur = $null
foreach ($line in $raw) {
    if ("$line".StartsWith('@@COMMIT@@')) {
        $cur = [pscustomobject]@{ Subject = "$line".Substring(10); Files = (New-Object System.Collections.ArrayList) }
        [void]$commits.Add($cur)
    } elseif ($cur -and "$line".Trim()) {
        [void]$cur.Files.Add("$line".Trim())
    }
}

$tasksDir = Join-Path $Repo 'docs\design\windows-parity-tasks'
$tagCache = @{}
$lookup = {
    param($tid)
    if (-not $tagCache.ContainsKey($tid)) {
        $f = Join-Path $tasksDir "$tid.md"
        $tagCache[$tid] = if (Test-Path -LiteralPath $f) { @(Get-TaskFileTags ([IO.File]::ReadAllText($f))) } else { @() }
    }
    return $tagCache[$tid]
}.GetNewClosure()

$items = @(Select-ReleaseNoteItems -Commits $commits.ToArray() -TagLookup $lookup)
Write-Host "NOTES RANGE: $Since..HEAD - $($commits.Count) commit(s), $($items.Count) user-facing"

$utf8 = New-Object System.Text.UTF8Encoding($false)
foreach ($scope in @('client', 'agent')) {
    $mine = @($items | Where-Object { $_.Scope -eq $scope })
    # The agent dialog only appears when the agent changed; an agent file with
    # nothing in it would be noise. The client file is always written.
    if ($scope -eq 'agent' -and -not $mine.Count) { continue }
    $rel = "release-notes/$scope/$Version.json"
    $path = Join-Path (Join-Path $OutDir $scope) "$Version.json"
    if (Test-Path -LiteralPath $path) {
        Write-Host "NOTES EXIST: $rel is already there (hand-written notes win); left alone"
        continue
    }
    $json = ConvertTo-ReleaseNotesJson -Version $Version -Items $mine
    $what = if ($mine.Count) { "$($mine.Count) item(s)" } else { 'nothing user-facing - says so' }
    if ($DryRun) {
        Write-Host "NOTES DRY RUN: would write $rel ($what)"
        continue
    }
    try {
        $dir = Split-Path -Parent $path
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [IO.File]::WriteAllText($path, $json, $utf8)
    } catch {
        Fail "could not write $path ($($_.Exception.Message))"
    }
    $verdict = if ($mine.Count) { 'NOTES WROTE' } else { 'NOTES NOTHING TO SAY' }
    Write-Host "${verdict}: $rel ($what)"
    Write-Host "NOTES-PATH $rel"
}
exit 0
