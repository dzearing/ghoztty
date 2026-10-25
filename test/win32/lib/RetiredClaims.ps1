# RetiredClaims (T1342) - a sentence the code made false must not come back.
#
# The shape this exists for, measured: on 2026-08-23 T1158 corrected a sentence
# in `test\win32\lib\BuildMode.ps1` saying the local agent's pipe had no env
# override - false since T167 - and its log named that sentence as plausibly how
# a release-lineage soak concluded the app pipe suffix was all there was, which
# is the defect that seeded the user's roster with immortal pinned sessions. The
# correction landed in that ONE file. The same claim sat in four more
# (`docs\claude\build.md`, the header of `test\win32\lib\Isolation.ps1`, step 3
# of `go.md` and the Details of T1023) for twelve more days, until a turn that
# happened to grep for it (T490). Nothing asked "where else is this written
# down?", so a correction lived exactly as long as its author thought to search.
#
# THE RULE. Correcting a claim about the code is not done until the claim is a
# row here. A row is the retired claim as a pattern, the change that made it
# false, the commit that corrected it, and where the true version now lives -
# and `test\win32\doc-claims.ps1` fails the tree on any recurrence, in any live
# doc, script, harness header or open task.
#
# Adding a row costs one entry in `$script:RetiredClaims` below:
#
#   Id          short slug, shown in a finding
#   Pattern     regex over NORMALISED text (see ConvertTo-ClaimText): lower
#               case, one space between words, comment leaders gone, curly
#               apostrophes straightened. Write it for prose that wraps.
#   FalseSince  the task/commit whose code change made the sentence untrue
#   CorrectedBy the commit that corrected the prose
#   Truth       where a reader finds the true version - the finding prints it,
#               so the person who tripped the check knows what to write instead
#   Proofs      @{ Ref; Path } pairs where the claim WAS present - the harness
#               proves the pattern still catches each one, so a row whose
#               pattern drifts away from the sentence it retired goes red rather
#               than silently matching nothing
#
# WHAT IS HISTORY, and therefore never scanned (the same line T1097's
# merge-terminology lint draws): the session log, digests, decision records,
# the audit/details/spec/divergence/feature-ideas files, any task file already
# `done` or `skipped(...)`, and the `## Progress log` of an open one. A log entry
# recording what was once believed is a record, not a defect. A double-quoted
# span or a markdown blockquote is a QUOTATION of the claim, not a use of it, so
# a doc explaining what used to be written may quote it.

$script:RetiredClaims = @(
    [pscustomobject]@{
        Id          = 'agent-pipe-no-env-override'
        # "the agent pipe has no env override", "the agent pipe is build-mode
        # derived and has no env override", "the local agent's pipe is
        # build-mode derived with no env override" - the five T490 sentences.
        Pattern     = "agent(?:'s)? pipe (?:is build-mode[ -]?derived,? (?:and |with )?)?(?:has )?no env override"
        FalseSince  = 'T167 (60bb1e9c9): GHOZTTY_AGENT_INSTANCE forks the agent pipe, state dir, guard and autostart'
        CorrectedBy = 'ce943e238 (T1158, BuildMode.ps1) and 63f2bab35 (T490, the other four)'
        Truth       = 'docs\claude\build.md: isolating a release-lineage run takes three knobs - GHOZTTY_PIPE_SUFFIX, GHOZTTY_AGENT_INSTANCE, LOCALAPPDATA (Set-GhozttyTestIsolation -ReleaseSandbox)'
        Proofs      = @(
            @{ Ref = 'ce943e238^'; Path = 'test/win32/lib/BuildMode.ps1' },
            @{ Ref = '63f2bab35^'; Path = 'docs/claude/build.md' },
            @{ Ref = '63f2bab35^'; Path = 'test/win32/lib/Isolation.ps1' },
            @{ Ref = '63f2bab35^'; Path = 'go.md' },
            @{ Ref = '63f2bab35^'; Path = 'docs/design/windows-parity-tasks/T1023.md' }
        )
    }
)

# The append-only parity record and the decision files - history, never scanned.
$script:RetiredClaimHistoryPattern = '^docs/design/windows-parity-(log|audit|details|spec|divergence|feature-ideas)|^docs/design/windows-parity-(digests|decisions)/'
$script:RetiredClaimTaskPattern = '^docs/design/windows-parity-tasks/T[0-9]+\.md$'
$script:RetiredClaimTextExt = @('.md', '.ps1', '.psm1', '.zig', '.swift', '.sh', '.yml', '.yaml', '.txt')
$script:RetiredClaimQuotationMaxChars = 800

function Get-RetiredClaims { return $script:RetiredClaims }

# A task file is history once it is closed; read the frontmatter, not the id.
function Test-RetiredClaimTaskClosed([string]$Text) {
    $m = [regex]::Match($Text, '(?m)^status:\s*"?([^"\r\n]+)"?\s*$')
    if (-not $m.Success) { return $false }
    $status = $m.Groups[1].Value.Trim()
    return ($status -eq 'done' -or $status -like 'skipped*')
}

# Strip what the rule does not apply to: an open task's progress log, markdown
# blockquotes, and bounded double-quoted spans. A quotation is under 800 chars
# and never crosses a blank line, so a stray quote mark cannot exempt a file.
function Remove-RetiredClaimExempt([string]$Text, [bool]$IsTask) {
    if ($IsTask) {
        $idx = $Text.IndexOf("`n## Progress log")
        if ($idx -ge 0) { $Text = $Text.Substring(0, $idx) }
    }
    $Text = [regex]::Replace($Text, '(?m)^[ \t]*>.*$', ' ')
    return [regex]::Replace($Text, '"[^"]*"', {
        param($m)
        if ($m.Value.Length -gt $script:RetiredClaimQuotationMaxChars) { return $m.Value }
        if ($m.Value -match '\r?\n[ \t]*\r?\n') { return $m.Value }
        return ' '
    })
}

# Normalise so a pattern is written once for prose that wraps: every line loses
# its comment leader (`#`, `//`, `*`), then the whole text becomes one lower-case
# line with single spaces and straight apostrophes. Hyphenated words broken
# across a line ("build-mode`n# derived") come out as "build-mode derived".
function ConvertTo-ClaimText([string]$Text) {
    $Text = [regex]::Replace($Text, '(?m)^[ \t]*(?:#+|//+|\*+)[ \t]?', '')
    $Text = $Text -replace "[$([char]0x2018)$([char]0x2019)]", "'"
    $Text = $Text -replace '[`*_]', ''
    return (($Text -replace '\s+', ' ').Trim()).ToLowerInvariant()
}

# Every retired claim found in $Text, as "<id> :: ...context..." strings.
function Get-RetiredClaimHits([string]$Text, [bool]$IsTask = $false) {
    $norm = ConvertTo-ClaimText (Remove-RetiredClaimExempt $Text $IsTask)
    $out = @()
    foreach ($claim in $script:RetiredClaims) {
        foreach ($m in [regex]::Matches($norm, $claim.Pattern)) {
            $from = [Math]::Max(0, $m.Index - 40)
            $len = [Math]::Min($norm.Length - $from, $m.Length + 80)
            $out += "$($claim.Id) :: ...$($norm.Substring($from, $len))..."
        }
    }
    return $out
}

# Should this tracked path be scanned at all? $Self lists the registry and the
# harness, which hold the patterns and their fixtures by construction.
function Test-RetiredClaimScannable([string]$Rel, [string[]]$Self) {
    if ($Self -contains $Rel) { return $false }
    if ($Rel -match $script:RetiredClaimHistoryPattern) { return $false }
    return ($script:RetiredClaimTextExt -contains ([System.IO.Path]::GetExtension($Rel)))
}
