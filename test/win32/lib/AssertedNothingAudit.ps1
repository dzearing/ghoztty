# AssertedNothingAudit (T271) - find the places where a script can announce
# ALL PASS and exit 0 having asserted nothing.
#
# The runtime half of this rule is `lib\TestScore.ps1` (`Write-TestVerdict`),
# which refuses to call a zero-assertion run a pass. This is the static half:
# the sweep that says whether any script still has a path around it.
#
# Two finding kinds are the defect itself and must stay at zero:
#
#   * `zero-count`  - a verdict whose own text hardcodes a zero assertion count
#                     (`ALL PASS (0 checks, 1 SKIPPED)`). Provable by reading it.
#   * `early-green` - a pass verdict that ENDS THE RUN with exit 0 somewhere
#                     other than the script's final verdict: a precondition or
#                     whole-run-skip branch that scores the run green. This is
#                     the exact shape T271 was filed for, and the three sites
#                     that had it (`host-settings`, `agent-user-env`,
#                     `agent-instance-lineage -Release`) each reached it for a
#                     different, entirely ordinary reason - a held port, a box
#                     without a usable PATH entry, a missing staging build.
#
# Three kinds are reported under a RATCHET but NOT yet enforced - the count may
# fall, never rise, and the acceptance script prints the number rather than a
# list of names that would be pure noise today:
#
#   * `uncounted-final` - the final verdict prints no assertion count at all
#                     (`"ALL PASS"`), so neither a human nor a machine can tell
#                     a full run from an empty one by reading it. 50-odd scripts
#                     are in this state; converting them onto `Write-TestVerdict`
#                     is T775's job.
#
#   * `self-verdict`  - (T1510) the final verdict is printed by the SCRIPT, from
#                     its own `if ($script:fail -eq 0)` check, rather than by
#                     `Write-TestVerdict`. This is the superset of the kind
#                     above, and it is the one that says whether T1039's rule -
#                     a run that UNWOUND may not print a pass - reaches the file
#                     at all. It does not: a hand-rolled check reads a failure
#                     counter an unwind leaves untouched, so the run that
#                     stopped a third of the way through prints a green line
#                     with an honest-looking count in front of it. Measured on
#                     `viewer-feedback-capture.ps1`: an assignment to `$home`
#                     (read-only) unwound the body, and the script printed
#                     `ALL PASS (14)` over a 92-assertion sweep.
#
#   * `unarmed-stamp` - (T1510) the script writes a guard stamp (T783) without
#                     dot-sourcing `lib\TestScore.ps1`. The stamp gate is
#                     enforced in the CHILD process that writes it, from the
#                     inherited `GHOZTTY_TEST_BODY`; a script that never arms
#                     publishes nothing, so `guard-due.ps1 update` stamps the
#                     covered files as proven over a run that unwound. This is
#                     the half that outlives the red line, and 78 scripts have
#                     it today.
#
# Exemption, narrow and stated: an `# asserted-nothing-audit: <reason>` marker
# anywhere in the file, the same state-your-intent convention the
# `# persistence:`, `# exitcode-audit:`, `# skip-audit:` and `# verdict-audit:`
# markers use.
#
# This reads the AST rather than the text, for the reason VerdictExitAudit does:
# `exit 0` shares a line with the verdict in most of this suite
# (`if ($fail -eq 0) { "ALL PASS"; exit 0 }`), and branch membership is a
# structural question. Helpers are named apart from that file's on purpose -
# both are dot-sourced into the same acceptance script, and two files quietly
# redefining each other's `Get-VerdictSite` is a trap nobody would see.

# Deliberately sets no StrictMode: this file is dot-sourced INTO suite scripts,
# and a mode set here would silently change how every one of them evaluates.

function Get-ScoreAst {
    param([string]$Path, [string[]]$Text)
    $tokens = $null
    $errors = $null
    if ($null -ne $Text) {
        $ast = [System.Management.Automation.Language.Parser]::ParseInput(
            ($Text -join "`n"), [ref]$tokens, [ref]$errors)
    } else {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $Path, [ref]$tokens, [ref]$errors)
    }
    return [pscustomobject]@{ Ast = $ast; Errors = @($errors) }
}

# A string that is an operand of a comparison is somebody ELSE's verdict being
# scored (`$laneText -match 'ALL PASS'`), not one this script emits.
function Test-ScoreComparisonOperand($Node) {
    $p = $Node.Parent
    while ($p) {
        if ($p -is [System.Management.Automation.Language.BinaryExpressionAst]) { return $true }
        if ($p -is [System.Management.Automation.Language.StatementAst]) { return $false }
        $p = $p.Parent
    }
    return $false
}

# Every pass verdict this file EMITS, in source order.
function Get-ScoreVerdictSites($Ast) {
    return @($Ast.FindAll({ param($n)
        ($n -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
         $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) -and
        $n.Extent.Text -match 'ALL PASS' }, $true) |
        Where-Object { -not (Test-ScoreComparisonOperand $_) })
}

function Get-ScoreEnclosingStatement($Node) {
    $n = $Node
    while ($n) {
        if ($n -is [System.Management.Automation.Language.StatementAst] -and
            $n.Parent -is [System.Management.Automation.Language.StatementBlockAst]) { return $n }
        if ($n -is [System.Management.Automation.Language.StatementAst] -and
            $n.Parent -is [System.Management.Automation.Language.NamedBlockAst]) { return $n }
        $n = $n.Parent
    }
    return $null
}

# `exit 0`, a bare `exit`, and `exit $anything` are three different answers.
function Get-ScoreExitKind($ExitStatement) {
    if ($null -eq $ExitStatement.Pipeline) { return 'zero' }
    $t = $ExitStatement.Pipeline.Extent.Text.Trim()
    if ($t -eq '0') { return 'zero' }
    if ($t -match '^-?\d+$') { return 'nonzero' }
    return 'unknown'
}

# Does the run END, green, in the same block as this verdict? Only the SAME
# block is considered, deliberately: walking outward would find the script's own
# closing `exit 0` for every site in the file and report the whole suite.
function Get-ScoreTerminatingExit($Site) {
    $stmt = Get-ScoreEnclosingStatement $Site
    if ($null -eq $stmt) { return $null }
    $parent = $stmt.Parent
    $stmts = $null
    if ($parent -is [System.Management.Automation.Language.StatementBlockAst]) { $stmts = $parent.Statements }
    elseif ($parent -is [System.Management.Automation.Language.NamedBlockAst]) { $stmts = $parent.Statements }
    if ($null -eq $stmts) { return $null }

    $seen = $false
    foreach ($s in $stmts) {
        if (-not $seen) { if ($s -eq $stmt) { $seen = $true }; continue }
        $exits = @($s.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.ExitStatementAst] }, $true))
        if ($exits.Count -gt 0) { return $exits[0] }
    }
    # `{ "ALL PASS"; exit 0 }` puts both in one pipeline-free block, but
    # `Write-TestVerdict` and `"...", exit` shapes can also hide the exit inside
    # the verdict statement itself - a call that exits is not an ExitStatement.
    return $null
}

# Does this site's own text name a pass COUNT? A verdict interpolating a counter
# (`ALL PASS ($script:pass assertions)`) reports what it measured; a bare
# `"ALL PASS"` reports nothing, and `(0 ...)` reports that it measured nothing.
function Test-ScoreCountsAssertions($Site) {
    $t = $Site.Extent.Text
    if ($t -match 'ALL PASS\s*\(\s*0\b') { return $false }
    return ($t -match '\$')
}

function Test-ScoreZeroCount($Site) {
    return ($Site.Extent.Text -match 'ALL PASS\s*\(\s*0\b')
}

# Is the verdict produced by the shared scorer rather than by a hand-rolled
# string? `Write-TestVerdict` cannot print a pass with a zero count, so a script
# that uses it satisfies the rule by construction.
function Test-ScoreUsesSharedScorer($Ast) {
    $calls = @($Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.CommandAst] }, $true))
    foreach ($c in $calls) {
        $name = $c.GetCommandName()
        if ($name -eq 'Write-TestVerdict' -or $name -eq 'Write-TestAssertedNothing') { return $true }
    }
    return $false
}

# ---------------------------------------------------------------------------
# The analyzer. One object per finding; an empty result is a clean file.
# `-Text` may be passed instead of `-Path` so the self-test drives it from
# fixtures without writing them to disk.
# ---------------------------------------------------------------------------
function Get-AssertedNothingFindings {
    param(
        [string]$Path,
        [string[]]$Text
    )
    $findings = New-Object System.Collections.ArrayList
    $lines = if ($null -ne $Text) { $Text } else { @(Get-Content -LiteralPath $Path) }

    foreach ($l in $lines) { if ($l -match '#\s*asserted-nothing-audit:') { return $findings } }

    $parsed = Get-ScoreAst -Path $Path -Text $Text
    if ($parsed.Errors.Count -gt 0) {
        [void]$findings.Add([pscustomobject]@{
            Path = $Path; Line = $parsed.Errors[0].Extent.StartLineNumber
            Kind = 'parse-error'; Detail = $parsed.Errors[0].Message })
        return $findings
    }

    $sites = @(Get-ScoreVerdictSites $parsed.Ast)
    # No verdict at all is VerdictExitAudit's finding, not this one - a helper
    # with nothing to score is not a script that scored nothing.
    if ($sites.Count -eq 0) { return $findings }

    $final = $sites[-1]

    foreach ($site in $sites) {
        if (Test-ScoreZeroCount $site) {
            [void]$findings.Add([pscustomobject]@{
                Path = $Path; Line = $site.Extent.StartLineNumber; Kind = 'zero-count'
                Detail = "the verdict names a zero assertion count: $($site.Extent.Text.Trim())" })
            continue
        }
        if ($site -eq $final) { continue }
        $exit = Get-ScoreTerminatingExit $site
        if ($null -ne $exit -and (Get-ScoreExitKind $exit) -eq 'zero') {
            [void]$findings.Add([pscustomobject]@{
                Path = $Path; Line = $site.Extent.StartLineNumber; Kind = 'early-green'
                Detail = "a pass verdict ends the run green before the final verdict: $($site.Extent.Text.Trim())" })
        }
    }

    $scored = Test-ScoreUsesSharedScorer $parsed.Ast

    if (-not (Test-ScoreCountsAssertions $final) -and -not $scored) {
        [void]$findings.Add([pscustomobject]@{
            Path = $Path; Line = $final.Extent.StartLineNumber; Kind = 'uncounted-final'
            Detail = "the final verdict names no assertion count: $($final.Extent.Text.Trim())" })
    }

    # T1510. The superset of `uncounted-final`, and the kind that says whether
    # T1039's rule reaches this file at all: a verdict the script PRINTS ITSELF
    # is decided by its own `$script:fail -eq 0` check, which an unwound run
    # leaves at 0. A count in that line does not help - the count is of the
    # assertions that DID run, and the run that stopped a third of the way
    # through has an honest-looking number in front of a green word.
    if (-not $scored) {
        [void]$findings.Add([pscustomobject]@{
            Path = $Path; Line = $final.Extent.StartLineNumber; Kind = 'self-verdict'
            Detail = "the final verdict is printed by the script rather than by Write-TestVerdict, so an unwound run still reaches it green: $($final.Extent.Text.Trim())" })
    }

    if (-not (Test-ScoreArmed $lines) -and (Test-ScoreWritesGuardStamp $lines)) {
        [void]$findings.Add([pscustomobject]@{
            Path = $Path; Line = 1; Kind = 'unarmed-stamp'
            Detail = "this script writes a guard stamp but never dot-sources lib\TestScore.ps1, so the stamping child process reads no GHOZTTY_TEST_BODY and records the covered files as proven even when the run unwound" })
    }

    return $findings
}

# Is the run ARMED - does the file dot-source the scorer, which is what
# publishes `GHOZTTY_TEST_BODY` to the child process that writes the stamp? A
# COMMENT naming the file does not arm anything, and the comment most likely to
# name it is the one explaining why a script hand-rolls its scoring instead.
function Test-ScoreArmed([string[]]$Lines) {
    foreach ($l in $Lines) {
        if ($l -match '^\s*#') { continue }
        if ($l -match 'TestScore\.ps1') { return $true }
    }
    return $false
}

# Does this script record a guard stamp (T783)? Read as text: the call is a
# child `powershell -File ... guard-due.ps1 update -Guard <name>` spread over a
# continuation line in every script that has one, so the command name and its
# arguments are not one AST node to interrogate.
function Test-ScoreWritesGuardStamp([string[]]$Lines) {
    $joined = ($Lines -join "`n")
    if ($joined -notmatch 'guard-due\.ps1') { return $false }
    return ($joined -match '(?m)^\s*update\s+-Guard\b' -or $joined -match 'guard-due\.ps1[^\n]*\bupdate\b')
}

# The kinds that are the defect and must stay at zero. `uncounted-final`,
# `self-verdict` and `unarmed-stamp` are reported and counted under a ratchet,
# not enforced - see the header.
function Get-AssertedNothingHardKinds { return @('zero-count', 'early-green', 'parse-error') }

# Sweep the acceptance scripts. NOT recursive, for the reason VerdictExitAudit
# is not: an acceptance script is a top-level file in `test\win32`, while `lib\`
# holds dot-sourced libraries with no verdict of their own.
function Get-AssertedNothingSweep([string]$Root) {
    $all = New-Object System.Collections.ArrayList
    foreach ($f in (Get-ChildItem -LiteralPath $Root -Filter *.ps1 -File)) {
        foreach ($x in @(Get-AssertedNothingFindings -Path $f.FullName)) { [void]$all.Add($x) }
    }
    return $all
}
