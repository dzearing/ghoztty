# UnrollCountAudit (T794) - find the counts that cannot fail, because PowerShell
# 5.1 unrolled the thing being counted before anyone looked at it.
#
# THE DEFECT, measured on this box (PS 5.1.26100):
#
#     function Get-One { return @([pscustomobject]@{ a = 1 }) }
#     (Get-One).Count      ->  $null        <- one element: the array UNROLLED
#     (Get-Two).Count      ->  2
#     @(Get-One).Count     ->  1
#
# A function's output goes onto the pipeline, and the pipeline unrolls a
# collection. A ONE-element array therefore reaches the caller as the element
# itself - and `.Count` on a PSCustomObject is $null, because the scalar
# Count/Length property PowerShell 3.0 added does not cover PSObject-wrapped
# custom objects (a string or a hashtable does answer 1, which is why this looks
# fine in a REPL experiment with strings and lies in a test that counts windows).
#
# So the assertion
#
#     $before = (Get-TopWindows $g.Pid).Count
#     ...
#     Assert 'no plain terminal window was opened' ($after -eq $before)
#
# compares $null with $null, passes, and would keep passing whatever the product
# did. That is exactly what `test\win32\chooser-open-chord.ps1` (T746) printed on
# its first run: `( -> )` on both of its assertions. The `@()` INSIDE the helper
# does not survive the return - only the wrap AT THE POINT OF USE does.
#
# Same family as T271 (a run that asserted nothing) and T791 (a negative control
# that inverts nothing): an assertion that cannot fail is indistinguishable from
# one that passed. What makes this one worth a machine check is that it is
# invisible on the page - the line reads like ordinary arithmetic, and it only
# misbehaves in the one-element case, which for "how many windows does this app
# have" is the common case.
#
# THE RULE:
#
#     A count read off a repo-defined helper's return is `@()`-wrapped at the
#     point of use.
#
# TWO FINDING KINDS.
#
#   * `unwrapped-call` - `(Get-Thing ...).Count`, where `Get-Thing` is a helper
#     defined in this repo whose output can be an array. Fix: `@(Get-Thing ...).Count`.
#   * `unwrapped-var`  - `$v = Get-Thing ...` (no `@()`) and later `$v.Count`.
#     Fix: wrap at either end - `$v = @(Get-Thing ...)` or `@($v).Count`.
#
# The index of "helpers whose output can be an array" is built from the repo's
# own sources rather than from the file under analysis alone, because the
# population the task names - `Get-TestWindows`, `Get-TestChildWindows` and
# their wrappers - is dot-sourced from `lib\` into ~90 scripts. A name that also
# resolves to a real cmdlet or an external command is dropped from the index, so
# `(Get-Content x).Count` is never a finding.
#
# Read off the AST rather than the text: `.Count` inside a here-string or a
# comment is not a count, and the wrap can be spelled `@(...)`, `[array](...)`
# or `[object[]](...)`.
#
# EXEMPTION, narrow and stated: `# count-audit: <reason>` on the finding's line
# or the line above it - the same state-your-intent convention the
# `# persistence:`, `# exitcode-audit:`, `# skip-audit:`, `# verdict-audit:` and
# `# thread-join-audit:` markers use. A bare marker with no reason waives
# nothing.

# Deliberately sets no StrictMode: this file is dot-sourced INTO suite scripts,
# and a mode set here would silently change how every one of them evaluates.

$script:UnrollCountCmdletCache = @{}

function Get-UnrollCountAst {
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

# The commands whose output is a collection often enough that a function ending
# in one is treated as array-returning. Deliberately short: this is the tail of
# an OUTPUT pipeline, not a general "might emit more than one" list.
$script:UNROLL_COLLECTION_COMMANDS = @(
    'where-object', '?', 'select-object', 'sort-object', 'group-object',
    'get-childitem', 'get-content', 'foreach-object', '%', 'select-string'
)

# Can this function hand back an array? Three shapes count, and they are the
# three the suite writes:
#
#   return @( ... )                      an explicit wrap
#   $out = New-Object ArrayList ...      a collector variable, returned
#   ... | Where-Object { ... }           an output pipeline ending in a filter
#
# A false NEGATIVE here just means a site is not reported; a false POSITIVE
# means a harmless `@()` is asked for. Both are cheap, and the rule's fix is
# correct either way - which is why this stays a shape test rather than an
# attempt at type inference.
function Test-UnrollArrayReturning($FunctionAst) {
    $body = $FunctionAst.Body
    if ($null -eq $body) { return $false }
    $nodes = @($body.FindAll({ param($n) $true }, $true))

    $arrVars = @{}
    foreach ($n in $nodes) {
        if (-not ($n -is [System.Management.Automation.Language.AssignmentStatementAst])) { continue }
        $lhs = $n.Left.Extent.Text
        if ($lhs -notmatch '^\$[A-Za-z_:][A-Za-z0-9_:]*$') { continue }
        $rhs = $n.Right.Extent.Text
        if ($n.Operator -eq 'PlusEquals' -or
            $rhs -match '^@\(' -or
            $rhs -match 'ArrayList|System\.Collections\.Generic\.List') {
            $arrVars[$lhs.ToLower()] = $true
        }
    }

    $outs = New-Object System.Collections.ArrayList
    foreach ($n in $nodes) {
        if ($n -is [System.Management.Automation.Language.ReturnStatementAst] -and $n.Pipeline) {
            [void]$outs.Add($n.Pipeline)
        }
    }
    if ($body.EndBlock) {
        foreach ($st in @($body.EndBlock.Statements)) {
            if ($st -is [System.Management.Automation.Language.PipelineAst]) { [void]$outs.Add($st) }
        }
    }

    # THE COMMA IDIOM COMES FIRST, because it inverts the answer. `return , @(...)`
    # wraps the array in a one-element outer array, which is how this suite has
    # always defended the return - and it works: measured on this box,
    # `(CommaEmpty).Count` is 0, `(CommaOne).Count` is 1, `(CommaTwo).Count` is 2,
    # all correct. Wrapping such a CALL is not a fix, it is a NEW defect:
    # `@(CommaTwo).Count` answers 1, because the value at the call site is the
    # outer wrapper. So a helper that protects any of its outputs this way is out
    # of the index entirely - there is nothing here to fix, and the mechanical
    # `@()` pass that ignored this turned four green audits red (2026-09-16).
    foreach ($o in $outs) {
        if (-not ($o -is [System.Management.Automation.Language.PipelineAst])) { continue }
        $elements = @($o.PipelineElements)
        if ($elements.Count -eq 0) { continue }
        $first = $elements[0]
        if (-not ($first -is [System.Management.Automation.Language.CommandExpressionAst])) { continue }
        $ex = $first.Expression
        if ($ex -is [System.Management.Automation.Language.ArrayLiteralAst] -and
            @($ex.Elements).Count -eq 1) {
            return $false
        }
    }

    foreach ($o in $outs) {
        if (-not ($o -is [System.Management.Automation.Language.PipelineAst])) { continue }
        $elements = @($o.PipelineElements)
        if ($elements.Count -eq 0) { continue }

        $first = $elements[0]
        if ($first -is [System.Management.Automation.Language.CommandExpressionAst]) {
            $ex = $first.Expression
            if ($ex -is [System.Management.Automation.Language.ArrayExpressionAst]) { return $true }
            if ($ex -is [System.Management.Automation.Language.ArrayLiteralAst]) { return $true }
            if ($ex -is [System.Management.Automation.Language.VariableExpressionAst] -and
                $arrVars.ContainsKey(('$' + $ex.VariablePath.UserPath).ToLower())) {
                return $true
            }
        }

        $last = $elements[$elements.Count - 1]
        if ($last -is [System.Management.Automation.Language.CommandAst]) {
            $cn = $last.GetCommandName()
            if ($cn -and $script:UNROLL_COLLECTION_COMMANDS -contains $cn.ToLower()) { return $true }
        }
    }
    return $false
}

# A name that ALSO names a real cmdlet, function or executable outside this repo
# is not ours to reason about: `(Get-Content x).Count` reads a file, and a repo
# helper that shadowed such a name would be a different defect. Cached, because
# the sweep asks about the same few hundred names repeatedly.
function Test-UnrollExternalName([string]$Name) {
    $key = $Name.ToLower()
    if ($script:UnrollCountCmdletCache.ContainsKey($key)) {
        return $script:UnrollCountCmdletCache[$key]
    }
    $external = $false
    $cmd = Get-Command -Name $Name -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandType -ne 'Function' } |
        Select-Object -First 1
    if ($null -ne $cmd) { $external = $true }
    $script:UnrollCountCmdletCache[$key] = $external
    return $external
}

# Build the index of repo helpers whose output can be an array: name (lowered)
# -> the relative path of the file that defines it. Roots are directories; every
# *.ps1 under them is read.
function Get-UnrollCountIndex {
    param([string[]]$Roots)
    $index = @{}
    foreach ($root in @($Roots)) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($f in @(Get-ChildItem -LiteralPath $root -Filter *.ps1 -File -Recurse)) {
            $parsed = Get-UnrollCountAst -Path $f.FullName
            if ($parsed.Errors.Count -gt 0) { continue }
            foreach ($n in @($parsed.Ast.FindAll({ param($x)
                            $x -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))) {
                if (-not (Test-UnrollArrayReturning $n)) { continue }
                $name = $n.Name.ToLower()
                if (Test-UnrollExternalName $n.Name) { continue }
                if (-not $index.ContainsKey($name)) { $index[$name] = $f.Name }
            }
        }
    }
    return $index
}

# Does a `# count-audit: <reason>` marker cover this line? The finding's own line
# or the one above it, and the reason has to be there - a bare marker waives
# nothing, the way `# thread-join-audit:` works.
function Test-UnrollExempt($Lines, [int]$LineNumber) {
    # Parenthesised on purpose: in PS 5.1 `,` binds tighter than `-`, so
    # `@($LineNumber - 1, $LineNumber - 2)` is an array subtraction, not two
    # indexes (the same comma trap this file exists to machine-check).
    foreach ($i in @(($LineNumber - 1), ($LineNumber - 2))) {
        if ($i -lt 0 -or $i -ge $Lines.Count) { continue }
        if ($Lines[$i] -match '#\s*count-audit:\s*\S+') { return $true }
    }
    return $false
}

# Is this expression already counted safely? `@(...)`, `[array](...)` and
# `[object[]](...)` all survive the unroll.
function Test-UnrollWrapped($Expression) {
    if ($Expression -is [System.Management.Automation.Language.ArrayExpressionAst]) { return $true }
    if ($Expression -is [System.Management.Automation.Language.ConvertExpressionAst]) {
        $t = $Expression.Type.TypeName.FullName
        if ($t -match '^(array|object\[\]|.*\[\])$') { return $true }
    }
    return $false
}

# The single repo helper this expression calls, or $null. A paren-wrapped
# pipeline of exactly one command whose name is in the index.
function Get-UnrollIndexedCall($Expression, $Index) {
    if (-not ($Expression -is [System.Management.Automation.Language.ParenExpressionAst])) { return $null }
    $p = $Expression.Pipeline
    if (-not ($p -is [System.Management.Automation.Language.PipelineAst])) { return $null }
    if (@($p.PipelineElements).Count -ne 1) { return $null }
    $el = $p.PipelineElements[0]
    if (-not ($el -is [System.Management.Automation.Language.CommandAst])) { return $null }
    $cn = $el.GetCommandName()
    if (-not $cn) { return $null }
    if (-not $Index.ContainsKey($cn.ToLower())) { return $null }
    return $cn
}

# ---------------------------------------------------------------------------
# The analyzer. One object per finding; an empty result is a clean file.
# `-Text` may be passed instead of `-Path` so the self-test drives it from
# fixtures without writing them to disk.
# ---------------------------------------------------------------------------
function Get-UnrollCountFindings {
    param(
        [string]$Path,
        [string[]]$Text,
        [hashtable]$Index
    )
    $findings = New-Object System.Collections.ArrayList
    $lines = if ($null -ne $Text) { @($Text) } else { @(Get-Content -LiteralPath $Path) }
    if ($null -eq $Index) { $Index = @{} }

    $parsed = Get-UnrollCountAst -Path $Path -Text $Text
    if ($parsed.Errors.Count -gt 0) {
        [void]$findings.Add([pscustomobject]@{
                Path = $Path; Line = $parsed.Errors[0].Extent.StartLineNumber
                Kind = 'parse-error'; Name = ''; Detail = $parsed.Errors[0].Message
            })
        return $findings
    }

    $all = @($parsed.Ast.FindAll({ param($n) $true }, $true))

    # Local definitions join the index for this file only: a helper a script
    # keeps to itself is the same hazard as a shared one. A local definition
    # also SHADOWS the repo-wide entry of the same name, in both directions -
    # `Findings` is defined in four audits, one of them comma-protected, and
    # without the shadow that file inherited the others' verdict and reported
    # 17 sites whose `@()` would have been a new defect.
    $localIndex = @{}
    foreach ($k in $Index.Keys) { $localIndex[$k] = $Index[$k] }
    foreach ($n in $all) {
        if (-not ($n -is [System.Management.Automation.Language.FunctionDefinitionAst])) { continue }
        $key = $n.Name.ToLower()
        if ((Test-UnrollArrayReturning $n) -and -not (Test-UnrollExternalName $n.Name)) {
            $localIndex[$key] = '(local)'
        } elseif ($localIndex.ContainsKey($key)) {
            $localIndex.Remove($key)
        }
    }

    $members = New-Object System.Collections.ArrayList
    $assigns = New-Object System.Collections.ArrayList
    foreach ($n in $all) {
        if ($n -is [System.Management.Automation.Language.MemberExpressionAst]) { [void]$members.Add($n) }
        elseif ($n -is [System.Management.Automation.Language.AssignmentStatementAst]) { [void]$assigns.Add($n) }
    }

    # --- kind 1: (Helper ...).Count ----------------------------------------
    foreach ($m in $members) {
        if ("$($m.Member.Extent.Text)" -ne 'Count') { continue }
        if (Test-UnrollWrapped $m.Expression) { continue }
        $name = Get-UnrollIndexedCall $m.Expression $localIndex
        if (-not $name) { continue }
        $line = $m.Extent.StartLineNumber
        if (Test-UnrollExempt $lines $line) { continue }
        [void]$findings.Add([pscustomobject]@{
                Path = $Path; Line = $line; Kind = 'unwrapped-call'; Name = $name
                Detail = "$($m.Extent.Text.Split("`n")[0].Trim()) - $name unrolls to a scalar when it returns one element; wrap the call: @($name ...).Count"
            })
    }

    # --- kind 2: $v = Helper ... ; ... $v.Count -----------------------------
    #
    # One finding per COUNT SITE, bound to the NEAREST preceding assignment to
    # that variable. Pairing every assignment with every later use instead reads
    # 39 findings out of a file that has 12 count sites, and a number that grows
    # with how often a scratch variable is reused is not a defect count anybody
    # can work down.
    $assignsByVar = @{}
    foreach ($a in $assigns) {
        $lhs = $a.Left.Extent.Text
        if ($lhs -notmatch '^\$[A-Za-z_:][A-Za-z0-9_:]*$') { continue }
        $key = $lhs.ToLower()
        if (-not $assignsByVar.ContainsKey($key)) {
            $assignsByVar[$key] = New-Object System.Collections.ArrayList
        }
        [void]$assignsByVar[$key].Add($a)
    }

    foreach ($m in $members) {
        if ("$($m.Member.Extent.Text)" -ne 'Count') { continue }
        $target = $m.Expression.Extent.Text
        if ($target -notmatch '^\$[A-Za-z_:][A-Za-z0-9_:]*$') { continue }
        $key = $target.ToLower()
        if (-not $assignsByVar.ContainsKey($key)) { continue }

        $line = $m.Extent.StartLineNumber
        $nearest = $null
        foreach ($a in $assignsByVar[$key]) {
            if ($a.Extent.StartLineNumber -ge $line) { continue }
            if ($null -eq $nearest -or
                $a.Extent.StartLineNumber -gt $nearest.Extent.StartLineNumber) { $nearest = $a }
        }
        if ($null -eq $nearest) { continue }

        $r = $nearest.Right
        if (-not ($r -is [System.Management.Automation.Language.PipelineAst])) { continue }
        if (@($r.PipelineElements).Count -ne 1) { continue }
        $el = $r.PipelineElements[0]
        if (-not ($el -is [System.Management.Automation.Language.CommandAst])) { continue }
        $cn = $el.GetCommandName()
        if (-not $cn -or -not $localIndex.ContainsKey($cn.ToLower())) { continue }
        if (Test-UnrollExempt $lines $line) { continue }

        [void]$findings.Add([pscustomobject]@{
                Path = $Path; Line = $line; Kind = 'unwrapped-var'; Name = $cn
                Detail = "$target.Count reads a value assigned unwrapped from $cn at line $($nearest.Extent.StartLineNumber); wrap it: $target = @($cn ...)"
            })
    }

    return $findings
}

# Every kind is the defect. There is no advisory kind here: the fix is one
# `@()` and it is correct whatever the helper turns out to return.
function Get-UnrollCountHardKinds { return @('unwrapped-call', 'unwrapped-var', 'parse-error') }

function Get-UnrollCountRelativePath([string]$Path, [string]$Repo) {
    $full = (Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue)
    $p = if ($full) { $full.Path } else { $Path }
    if ($p.StartsWith($Repo, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $p.Substring($Repo.Length).TrimStart('\', '/')
    }
    return $p
}

# Sweep every *.ps1 under the roots, with one shared index.
function Get-UnrollCountSweep {
    param([string[]]$Roots, [hashtable]$Index)
    if ($null -eq $Index) { $Index = Get-UnrollCountIndex -Roots $Roots }
    $all = New-Object System.Collections.ArrayList
    foreach ($root in @($Roots)) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($f in @(Get-ChildItem -LiteralPath $root -Filter *.ps1 -File -Recurse)) {
            foreach ($x in @(Get-UnrollCountFindings -Path $f.FullName -Index $Index)) { [void]$all.Add($x) }
        }
    }
    return $all
}
