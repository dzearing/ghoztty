# ArgvHazardAudit (T782) - find the PowerShell call site that hands the ghoztty
# CLI free text on a native argv, where PowerShell 5.1 silently destroys it.
#
# THE DEFECT, measured (T279, 2026-08-11, with a GetCommandLineW oracle).
# PowerShell 5.1 composes a native process's command line itself, and its
# composer is not the inverse of the CRT parser every C/C++/Zig program uses to
# split that line back into argv:
#
#   * an argument is wrapped in `"` only when whitespace appears at a position
#     preceded by an EVEN number of `"` characters, and
#   * an embedded `"` is copied through UNESCAPED.
#
# So text arrives shredded, at exit 0, with every log line reporting success:
#
#   sent  --command=claude --dangerously-skip-permissions --continue "read go.md and go"
#   got   --command=claude --dangerously-skip-permissions --continue  +  go.md  +  and  +  go
#
# That was the loop's own relaunch, live in two scripts for weeks. There is no
# escaper that closes it - `scripts\lib\NativeArgv.ps1` carries the proof - so
# the fix is to compose the command line ourselves and hand it to CreateProcess
# (`Invoke-NativeExact`), which is what T279 converted the sites it could
# enumerate BY HAND to do.
#
# THE RULE this audit keeps:
#
#     A ghoztty CLI invocation from PowerShell must not put text on a free-text
#     flag or positional unless that text PROVABLY carries no `"` and provably
#     does not end in `\`. Those are the two ways the composer corrupts an
#     argument, and being a literal is not itself a defence - a hard-coded
#     `'claude --continue "read go.md and go"'` is destroyed exactly as a
#     computed one is.
#
# WHY A HAND ENUMERATION IS NOT ENOUGH. T279's table is a snapshot of
# 2026-08-11. Nothing stopped the next script from writing `& $exe
# "--title=$label"` again, and the symptom when it does is text arriving with
# pieces missing - the one failure shape this suite has learned reads exactly
# like success.
#
# WHAT IS HAZARDOUS, AND WHAT IS DELIBERATELY NOT. Most interpolation at these
# call sites is pane ids, GUIDs, `$PID`-derived names and repo paths - none of
# which can carry a `"` or end in `\`, and flagging them would produce the wall
# of noise that makes an audit nobody runs. So the finding needs BOTH halves:
#
#   1. the invocation is a NATIVE ghoztty call (`& $exe ...`, a bare
#      `ghoztty.exe`, `Start-Process -ArgumentList`, or a `cmd /c` line) - a
#      `& .\some.ps1` binds its parameters in-process and has no command line
#      at all, so it is not this audit's question; and
#   2. the argument is a FREE-TEXT carrier - `--title=`, `--command=`,
#      `--split-command=`, `--working-directory=`, `--keys=`, `--env=`, or the
#      positional text of `+set-banner` / `+send-keys` - and its value is not
#      provably quote-free and backslash-tail-free.
#
# EXEMPTION: `# argv-audit: <reason>` on the call's own line, or on the line
# immediately above it, states the intent the same way `# persistence:`,
# `# exitcode-audit:`, `# skip-audit:`, `# capture-audit:` and
# `# resolve-audit:` do for their sweeps. The marker is LINE-scoped rather than
# file-scoped on purpose: the hazard is per call site, and a file-wide marker
# would suppress the sites written after the exempted one - which is exactly
# the snapshot problem this audit exists to end.
#
# Read off the AST rather than the text, for the reason `VerdictExitAudit.ps1`
# gives: the question "is this string interpolated" is structural. A line
# matcher cannot tell `"--title=$label"` from `'--title=literal'` followed by a
# comment mentioning `$label`, and it cannot tell either from a here-string
# documenting the hazard - which this file, and T279's task card, are full of.

# Deliberately sets no StrictMode: this file is dot-sourced INTO suite scripts,
# and a mode set here would silently change how every one of them evaluates.

# The verbs that say "this command line is ghoztty's". Used to recognise a
# `& $exe`/`Start-Process`/`cmd /c` invocation whose program is a variable and
# therefore unreadable statically.
$script:ArgvHazardVerbs = @(
    'new-window', 'split', 'close', 'rearrange', 'read', 'list', 'sessions',
    'send-keys', 'set-state', 'set-banner', 'rename', 'reload',
    'new-remote-window', 'version', 'focus'
)

# The flags whose value is text a program composed, as opposed to an id. A
# `--target=<pane-guid>`, a `--name=<literal>`, a `--pid=<number>` cannot carry
# a `"` or end in `\`; these can.
$script:ArgvHazardFlags = @(
    'title', 'command', 'split-command', 'working-directory', 'keys', 'env'
)

# The verbs whose POSITIONAL argument is free text.
$script:ArgvHazardPositionalVerbs = @('set-banner', 'send-keys')

# Program names that are the ghoztty CLI by name alone.
$script:ArgvHazardExeNames = @(
    'ghoztty', 'ghoztty.exe', 'ghoztty.com', 'ghoztty-agent', 'ghoztty-agent.exe'
)

function Get-ArgvHazardFlags { @($script:ArgvHazardFlags) }
function Get-ArgvHazardVerbs { @($script:ArgvHazardVerbs) }

# Parsing dominates a sweep over ~700 scripts, so a file is parsed once per
# process. `Reset-ArgvHazardCache` empties it for a test that writes a fixture
# and re-reads it in the same session.
$script:ArgvHazardAstCache = @{}

function Reset-ArgvHazardCache {
    $script:ArgvHazardAstCache = @{}
}

function Get-ArgvHazardAst {
    param([string]$Path, [string]$Text)
    $tokens = $null
    $errors = $null
    # `-not IsNullOrEmpty` rather than `$null -ne`: an unbound [string] param
    # arrives as '' here, and ParseInput('') yields an empty AST that reports
    # zero of everything - the shape of an audit that passes because it never
    # looked.
    if (-not [string]::IsNullOrEmpty($Text)) {
        return [System.Management.Automation.Language.Parser]::ParseInput(
            $Text, [ref]$tokens, [ref]$errors)
    }
    $key = $Path.ToLowerInvariant()
    if (-not $script:ArgvHazardAstCache.ContainsKey($key)) {
        $script:ArgvHazardAstCache[$key] =
            [System.Management.Automation.Language.Parser]::ParseFile(
                $Path, [ref]$tokens, [ref]$errors)
    }
    $script:ArgvHazardAstCache[$key]
}

# What an argument expression can and cannot DO to a command line, as two
# facts, because those are exactly the two ways PowerShell 5.1 corrupts one:
#
#   NoQuote  - the value provably contains no `"`. An embedded quote is copied
#              through unescaped and flips the wrapping parity, which is the
#              half that makes `a "quoted phrase" mid string` arrive as four
#              arguments.
#   TailSafe - the value provably does not END in `\`. A trailing backslash
#              makes the closing quote read as escaped, which is the half that
#              turns `C:\my dir\` into `C:\my dir"`.
#
# Safe means both. Reading VALUES rather than just shapes is what lets this
# audit say something about a literal: `'claude --continue "read go.md and go"'`
# is text the author typed and can see, and it is still destroyed on argv.
#
# $Consts is the file's foldable variables (see Get-ArgvHazardConstants), which
# is what makes the NAMING of a payload irrelevant: `$banner = 'Wrap me: ...'`
# three lines up is the same text as writing it inline, so `+set-banner $banner`
# is judged on the same value. Without the fold this audit would report every
# test that hoisted its payload to a variable, and a reviewer would rightly ask
# why the tool cannot read the line above the call.
function Get-ArgvHazardFacts {
    param(
        [System.Management.Automation.Language.Ast]$Expr,
        [hashtable]$Consts = @{},
        [int]$Depth = 0
    )

    $safe = @{ NoQuote = $true; TailSafe = $true }
    $unknown = @{ NoQuote = $false; TailSafe = $false }

    if ($null -eq $Expr) { return $safe }
    if ($Depth -gt 8) { return $unknown }

    if ($Expr -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
        $Expr -is [System.Management.Automation.Language.ConstantExpressionAst]) {
        $v = Get-ArgvHazardStaticText -Expr $Expr
        return @{
            NoQuote  = ($v -notmatch '"')
            TailSafe = (-not $v.EndsWith('\'))
        }
    }

    if ($Expr -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) {
        # `"--title=plain"` is a literal written with double quotes; `"cd $p"`
        # is a template. Either way the LITERAL half is readable from .Value
        # (an interpolated hole appears as its own source text, and a variable
        # name cannot contain a quote), and the interpolated half is each
        # nested expression's own facts.
        $v = $Expr.Value
        $noQuote = ($v -notmatch '"')
        $nested = @($Expr.NestedExpressions)
        foreach ($n in $nested) {
            $f = Get-ArgvHazardFacts -Expr $n -Consts $Consts -Depth ($Depth + 1)
            if (-not $f.NoQuote) { $noQuote = $false }
        }
        # The TAIL is settled by whatever is last. When the string ends in an
        # interpolation, that expression's TailSafe decides; otherwise the
        # literal tail does.
        $tailSafe = (-not $v.EndsWith('\'))
        if ($nested.Count -gt 0 -and
            $v -match '(\$\{[^}]*\}|\$\([^)]*\)|\$[A-Za-z_][\w:.]*)$') {
            $last = $nested[0]
            foreach ($n in $nested) {
                if ($n.Extent.EndOffset -ge $last.Extent.EndOffset) { $last = $n }
            }
            $tailSafe = (Get-ArgvHazardFacts -Expr $last -Consts $Consts -Depth ($Depth + 1)).TailSafe
        }
        return @{ NoQuote = $noQuote; TailSafe = $tailSafe }
    }

    if ($Expr -is [System.Management.Automation.Language.VariableExpressionAst]) {
        $k = $Expr.VariablePath.UserPath.ToLowerInvariant()
        if ($Consts.ContainsKey($k)) { return $Consts[$k] }
        return $unknown
    }

    if ($Expr -is [System.Management.Automation.Language.ParenExpressionAst] -or
        $Expr -is [System.Management.Automation.Language.SubExpressionAst]) {
        $inner = $Expr.Pipeline
        if ($Expr -is [System.Management.Automation.Language.SubExpressionAst]) {
            $inner = $Expr.SubExpression
        }
        $stmts = @()
        if ($inner -is [System.Management.Automation.Language.PipelineAst]) { $stmts = @($inner) }
        else { $stmts = @($inner.Statements) }
        if ($stmts.Count -ne 1) { return $unknown }
        $st = $stmts[0]
        if ($st -isnot [System.Management.Automation.Language.PipelineAst]) { return $unknown }
        if ($st.PipelineElements.Count -ne 1) { return $unknown }
        $pe = $st.PipelineElements[0]
        if ($pe -is [System.Management.Automation.Language.CommandExpressionAst]) {
            return (Get-ArgvHazardFacts -Expr $pe.Expression -Consts $Consts -Depth ($Depth + 1))
        }
        return (Get-ArgvHazardFacts -Expr $pe -Consts $Consts -Depth ($Depth + 1))
    }

    if ($Expr -is [System.Management.Automation.Language.BinaryExpressionAst]) {
        # `'a' + $b`: no quote if neither half has one, and the TAIL is the
        # right half's. Only `+` - every other operator (`-replace` above all)
        # computes a string this audit would have to reason about rather than
        # read.
        if ($Expr.Operator -ne 'Plus') { return $unknown }
        $l = Get-ArgvHazardFacts -Expr $Expr.Left -Consts $Consts -Depth ($Depth + 1)
        $r = Get-ArgvHazardFacts -Expr $Expr.Right -Consts $Consts -Depth ($Depth + 1)
        return @{ NoQuote = ($l.NoQuote -and $r.NoQuote); TailSafe = $r.TailSafe }
    }

    if ($Expr -is [System.Management.Automation.Language.CommandAst]) {
        return (Get-ArgvHazardPathFacts -Expr $Expr -Consts $Consts -Depth $Depth)
    }
    $unknown
}

# Both facts at once: what the audit actually asks of an argument.
function Test-ArgvHazardLiteral {
    param(
        [System.Management.Automation.Language.Ast]$Expr,
        [hashtable]$Consts = @{},
        [int]$Depth = 0
    )
    $f = Get-ArgvHazardFacts -Expr $Expr -Consts $Consts -Depth $Depth
    return ($f.NoQuote -and $f.TailSafe)
}

# `Join-Path <base> <leaf>` - a FILESYSTEM PATH, where both facts hold however
# the base was computed:
#
#   * a `"` cannot appear in a Windows path at all (Win32 forbids it in a path
#     component), so neither half can contribute one;
#   * the composed value ends in the LEAF, so a literal non-empty leaf that does
#     not itself end in `\` settles the tail.
#
# That is why the base is unconstrained: `Join-Path $env:TEMP 'ghoztty-x'` is
# safe even though a bare `$env:TEMP` is NOT - a drive root (`D:\`) ends in the
# backslash that makes PowerShell's closing quote read as escaped, which is the
# exact second half of the T279 defect.
function Get-ArgvHazardPathFacts {
    param(
        [System.Management.Automation.Language.Ast]$Expr,
        [hashtable]$Consts = @{},
        [int]$Depth = 0
    )

    $unknown = @{ NoQuote = $false; TailSafe = $false }
    if ($Expr -isnot [System.Management.Automation.Language.CommandAst]) { return $unknown }
    if ($Expr.GetCommandName() -ne 'Join-Path') { return $unknown }

    $parts = @()
    foreach ($el in $Expr.CommandElements) {
        if ($el -eq $Expr.CommandElements[0]) { continue }
        if ($el -is [System.Management.Automation.Language.CommandParameterAst]) {
            # A named -ChildPath reorders what "last" means; stay conservative.
            if ($el.ParameterName -notin @('Path', 'Resolve')) { return $unknown }
            continue
        }
        $parts += $el
    }
    if ($parts.Count -lt 2) { return $unknown }

    $leaf = $parts[-1]
    $lf = Get-ArgvHazardFacts -Expr $leaf -Consts $Consts -Depth ($Depth + 1)
    if (-not ($lf.NoQuote -and $lf.TailSafe)) { return $unknown }
    $t = Get-ArgvHazardStaticText -Expr $leaf
    if ([string]::IsNullOrEmpty($t)) { return $unknown }
    @{ NoQuote = $true; TailSafe = $true }
}

# The file's LITERAL-VALUED variables: the ones whose every assignment in the
# file is a plain `=` of something that folds to a literal, and which nothing
# else in the file can rebind.
#
# Deliberately conservative, because a wrong answer here HIDES a hazard rather
# than reporting a harmless one. A name is disqualified outright by: being a
# parameter (the caller supplies the text), being the loop variable of a
# `foreach`, being assigned with a compound operator (`+=`), being the target of
# `Set-Variable`, or being assigned anywhere from something that is not itself a
# literal. Scope is not modelled - a name assigned a literal in one function and
# something else in another is disqualified by the second assignment, which is
# the safe direction.
function Get-ArgvHazardConstants {
    param([System.Management.Automation.Language.Ast]$Ast)

    $candidates = @{}
    $banned = @{}

    # Parameters are NOT banned here: a parameter is free text only inside the
    # function that declares it, and a file where one helper happens to take a
    # `$banner` must not make every other function's literal `$banner`
    # unreadable. `Get-ArgvHazardScopeParameters` applies that ban at the call
    # site, where scope is known.
    foreach ($f in $Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.ForEachStatementAst] }, $true)) {
        $banned[$f.Variable.VariablePath.UserPath.ToLowerInvariant()] = $true
    }
    foreach ($c in $Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $cn = $c.GetCommandName()
        if ($cn -and ($cn -in @('Set-Variable', 'sv', 'set', 'New-Variable'))) {
            foreach ($el in $c.CommandElements) {
                $t = Get-ArgvHazardStaticText -Expr $el
                if ($t -and $t -notmatch '^-') { $banned[$t.ToLowerInvariant().TrimStart('$')] = $true }
            }
        }
    }

    # Two passes: collect, then fold. One pass would make a variable's verdict
    # depend on the order the assignments appear in, and `$a = $b` above
    # `$b = 'x'` is ordinary PowerShell inside two different functions.
    $assigns = @{}
    foreach ($a in $Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {

        $left = $a.Left
        while ($left -is [System.Management.Automation.Language.ConvertExpressionAst]) {
            $left = $left.Child
        }
        if ($left -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }
        $k = $left.VariablePath.UserPath.ToLowerInvariant()
        if ($a.Operator -ne 'Equals') { $banned[$k] = $true; continue }

        $rhs = $a.Right
        if ($rhs -is [System.Management.Automation.Language.CommandExpressionAst]) {
            $rhs = $rhs.Expression
        } elseif ($rhs -is [System.Management.Automation.Language.PipelineAst] -and
                  $rhs.PipelineElements.Count -eq 1) {
            $one = $rhs.PipelineElements[0]
            if ($one -is [System.Management.Automation.Language.CommandExpressionAst]) {
                $rhs = $one.Expression
            } else {
                # A command on the right is only readable when it is a path
                # constructor (`$x = Join-Path $env:TEMP 'leaf'`); anything else
                # computes a value this audit cannot see.
                $rhs = $one
            }
        } else {
            $banned[$k] = $true
            continue
        }
        if (-not $assigns.ContainsKey($k)) { $assigns[$k] = @() }
        $assigns[$k] += $rhs
    }

    # Fold to a fixed point: `$b = "$a-tail"` is readable once `$a` is.
    # A name carries the AND of its assignments' facts - a variable assigned a
    # quoted string in one branch and a clean one in another can carry a quote,
    # so it does. Bounded by the number of names, so it always terminates.
    $out = @{}
    for ($round = 0; $round -lt 6; $round++) {
        $changed = $false
        foreach ($k in $assigns.Keys) {
            if ($banned.ContainsKey($k)) { continue }
            $noQuote = $true
            $tailSafe = $true
            foreach ($rhs in $assigns[$k]) {
                $f = Get-ArgvHazardFacts -Expr $rhs -Consts $out
                if (-not $f.NoQuote) { $noQuote = $false }
                if (-not $f.TailSafe) { $tailSafe = $false }
            }
            $prev = $out[$k]
            if ($null -eq $prev -or $prev.NoQuote -ne $noQuote -or $prev.TailSafe -ne $tailSafe) {
                $out[$k] = @{ NoQuote = $noQuote; TailSafe = $tailSafe }
                $changed = $true
            }
        }
        if (-not $changed) { break }
    }
    foreach ($k in @($out.Keys)) { if ($banned.ContainsKey($k)) { $out.Remove($k) } }
    $out
}

# The static text of an expression, with every interpolated hole rendered as
# `${...}` so a caller can read the FLAG off it without evaluating anything.
function Get-ArgvHazardStaticText {
    param([System.Management.Automation.Language.Ast]$Expr)

    if ($null -eq $Expr) { return '' }
    if ($Expr -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
        return $Expr.Value
    }
    if ($Expr -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) {
        return $Expr.Value
    }
    return $Expr.Extent.Text
}

# Does this argument carry free text, and if so under which name?
# Returns $null when it does not. `$PrevVerb` is the ghoztty verb seen earlier
# on the same command line, which is what makes a bare positional readable.
function Get-ArgvHazardCarrier {
    param(
        [System.Management.Automation.Language.Ast]$Expr,
        [string]$PrevVerb,
        [switch]$IsPositional
    )

    $text = Get-ArgvHazardStaticText -Expr $Expr
    if ($text -match '^--([a-z0-9-]+)=') {
        $flag = $Matches[1].ToLowerInvariant()
        if ($script:ArgvHazardFlags -contains $flag) { return "--$flag" }
        return $null
    }
    # A split flag/value pair (`--title` `$text`) is the same hazard.
    if ($text -match '^--([a-z0-9-]+)$') { return $null }

    if ($IsPositional -and $PrevVerb -and
        ($script:ArgvHazardPositionalVerbs -contains $PrevVerb)) {
        return "+$PrevVerb"
    }
    $null
}

# Every expression a command passes as an argument, in order, paired with the
# preceding `--flag` when the pair was written split rather than with `=`.
function Get-ArgvHazardArguments {
    param([System.Management.Automation.Language.CommandAst]$Command)

    $out = @()
    $verb = $null
    $pendingFlag = $null
    $first = $true
    foreach ($el in $Command.CommandElements) {
        if ($first) { $first = $false; continue }

        if ($el -is [System.Management.Automation.Language.CommandParameterAst]) {
            # `-ArgumentList`, `-FilePath` and friends. A parameter with an
            # attached argument (`-Foo:$bar`) carries it in .Argument.
            if ($null -ne $el.Argument) {
                $out += [pscustomobject]@{
                    Expr = $el.Argument; Verb = $verb
                    Param = $el.ParameterName; Positional = $false
                }
            } else {
                $out += [pscustomobject]@{
                    Expr = $null; Verb = $verb
                    Param = $el.ParameterName; Positional = $false
                }
            }
            $pendingFlag = $null
            continue
        }

        $text = Get-ArgvHazardStaticText -Expr $el
        if ($text -match '^\+([a-z0-9-]+)$') {
            $v = $Matches[1].ToLowerInvariant()
            if ($script:ArgvHazardVerbs -contains $v) { $verb = $v }
            $pendingFlag = $null
            $out += [pscustomobject]@{
                Expr = $el; Verb = $verb; Param = $null; Positional = $false
            }
            continue
        }

        $positional = $true
        if ($pendingFlag) { $positional = $false }
        $out += [pscustomobject]@{
            Expr = $el; Verb = $verb; Param = $null
            Positional = $positional; PendingFlag = $pendingFlag
        }

        if ($text -match '^--([a-z0-9-]+)$') { $pendingFlag = $Matches[1].ToLowerInvariant() }
        else { $pendingFlag = $null }
    }
    @($out)
}

# Expand an array literal / list argument into its elements, so
# `-ArgumentList @('+rename', "--title=$t")` is read element by element.
function Expand-ArgvHazardList {
    param([System.Management.Automation.Language.Ast]$Expr)

    $node = $Expr
    while ($node -is [System.Management.Automation.Language.ParenExpressionAst]) {
        $node = $node.Pipeline
    }
    if ($node -is [System.Management.Automation.Language.PipelineAst] -and
        $node.PipelineElements.Count -eq 1) {
        $node = $node.PipelineElements[0]
    }
    if ($node -is [System.Management.Automation.Language.CommandExpressionAst]) {
        $node = $node.Expression
    }
    if ($node -is [System.Management.Automation.Language.ArrayExpressionAst]) {
        $out = @()
        foreach ($st in $node.SubExpression.Statements) {
            if ($st -is [System.Management.Automation.Language.PipelineAst]) {
                foreach ($pe in $st.PipelineElements) {
                    if ($pe -is [System.Management.Automation.Language.CommandExpressionAst]) {
                        $out += (Expand-ArgvHazardList -Expr $pe.Expression)
                    }
                }
            }
        }
        return @($out)
    }
    if ($node -is [System.Management.Automation.Language.ArrayLiteralAst]) {
        $out = @()
        foreach ($e in $node.Elements) { $out += (Expand-ArgvHazardList -Expr $e) }
        return @($out)
    }
    @($node)
}

# Does this command invoke a NATIVE process at all? A `& .\thing.ps1` or a
# `& $scriptBlock` binds parameters in-process - no command line is composed,
# so PowerShell's composer never runs and there is nothing to corrupt.
function Test-ArgvHazardNativeCall {
    param([System.Management.Automation.Language.CommandAst]$Command)

    $name = $Command.GetCommandName()
    if ($name) {
        $leaf = ($name -split '[\\/]')[-1]
        if ($script:ArgvHazardExeNames -contains $leaf.ToLowerInvariant()) { return $true }
        if ($leaf -match '\.ps1$') { return $false }
        if ($leaf.ToLowerInvariant() -in @('cmd', 'cmd.exe', 'start-process')) { return $true }
        if ($leaf -match '\.(exe|com|bat|cmd)$') { return $true }
        # A named cmdlet/function is not a native call.
        return $false
    }

    # `& $exe ...` / `& "$dir\ghoztty.exe" ...`: the program cannot be read
    # statically. A `.ps1` in the expression's own text still rules it out.
    if ($Command.InvocationOperator -eq 'Ampersand') {
        $first = $Command.CommandElements[0]
        $t = Get-ArgvHazardStaticText -Expr $first
        if ($t -match '\.ps1') { return $false }
        return $true
    }
    $false
}

# Is this command line ghoztty's? Either the program says so, or a `+verb` on it
# does. Required so that `& $python -c "print('$x')"` - a native call with an
# interpolated argument, and not this task's subject - stays out of the sweep.
function Test-ArgvHazardGhozttyCall {
    param([System.Management.Automation.Language.CommandAst]$Command)

    $name = $Command.GetCommandName()
    if ($name) {
        $leaf = (($name -split '[\\/]')[-1]).ToLowerInvariant()
        if ($script:ArgvHazardExeNames -contains $leaf) { return $true }
    }
    foreach ($el in $Command.CommandElements) {
        foreach ($e in (Expand-ArgvHazardList -Expr $el)) {
            $t = Get-ArgvHazardStaticText -Expr $e
            if ($t -match 'ghoztty') { return $true }
            if ($t -match '(^|\s)\+([a-z0-9-]+)') {
                foreach ($m in [regex]::Matches($t, '(?:^|\s)\+([a-z0-9-]+)')) {
                    if ($script:ArgvHazardVerbs -contains $m.Groups[1].Value.ToLowerInvariant()) {
                        return $true
                    }
                }
            }
        }
    }
    $false
}

# The parameter names in scope AT a call site: every `param(...)` on the
# functions and script blocks enclosing it, plus the script's own. Text that
# arrives as a parameter is text a CALLER composed - the whole subject of this
# audit - so a name bound that way is never a literal here, whatever the rest of
# the file assigns to the same name elsewhere.
function Get-ArgvHazardScopeParameters {
    param([System.Management.Automation.Language.Ast]$Node)

    $out = @{}
    $n = $Node
    while ($null -ne $n) {
        $sb = $null
        if ($n -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
            foreach ($p in @($n.Parameters)) {
                if ($null -eq $p -or $null -eq $p.Name) { continue }
                $out[$p.Name.VariablePath.UserPath.ToLowerInvariant()] = $true
            }
            $sb = $n.Body
        } elseif ($n -is [System.Management.Automation.Language.ScriptBlockAst]) {
            $sb = $n
        }
        if ($null -ne $sb -and $null -ne $sb.ParamBlock) {
            foreach ($p in @($sb.ParamBlock.Parameters)) {
                if ($null -eq $p -or $null -eq $p.Name) { continue }
                $out[$p.Name.VariablePath.UserPath.ToLowerInvariant()] = $true
            }
        }
        $n = $n.Parent
    }
    $out
}

# The line-scoped exemption. A marker on the call's own line, or within the
# three lines above it, states the intent for THAT site.
function Test-ArgvHazardExempt {
    param([string[]]$Lines, [int]$StartLine, [int]$EndLine)

    $from = [Math]::Max(1, $StartLine - 1)
    for ($i = $from; $i -le $EndLine -and $i -le $Lines.Count; $i++) {
        if ($Lines[$i - 1] -match '#\s*argv-audit:') { return $true }
    }
    $false
}

# The analyzer. One object per hazardous site:
#   File (repo-relative), Line, Carrier, Text, Exempt.
# Exempt sites are RETURNED rather than dropped, so a caller can assert both
# "the analyzer sees this shape" and "the sweep is at zero" about the same line
# - which is what a deliberate negative control like `cli-argv-fidelity.ps1`
# section D needs.
function Get-ArgvHazardFindings {
    param(
        [string]$Repo,
        [string[]]$Paths,
        [switch]$IncludeExempt
    )

    $findings = @()
    foreach ($path in $Paths) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $ast = Get-ArgvHazardAst -Path $path
        $text = $ast.Extent.Text
        if ([string]::IsNullOrEmpty($text)) { continue }
        $lines = $text -split "`r?`n"
        $consts = Get-ArgvHazardConstants -Ast $ast

        $rel = $path
        if ($Repo -and $path.ToLowerInvariant().StartsWith($Repo.ToLowerInvariant())) {
            $rel = $path.Substring($Repo.Length).TrimStart('\', '/')
        }

        foreach ($c in $ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {

            if (-not (Test-ArgvHazardNativeCall -Command $c)) { continue }
            if (-not (Test-ArgvHazardGhozttyCall -Command $c)) { continue }

            # The file's literals, minus every name that is a PARAMETER where
            # this call sits.
            $siteConsts = @{}
            foreach ($k in $consts.Keys) { $siteConsts[$k] = $consts[$k] }
            foreach ($p in (Get-ArgvHazardScopeParameters -Node $c).Keys) {
                $siteConsts.Remove($p)
            }

            foreach ($arg in (Get-ArgvHazardArguments -Command $c)) {
                if ($null -eq $arg.Expr) { continue }
                $verb = $arg.Verb
                foreach ($e in (Expand-ArgvHazardList -Expr $arg.Expr)) {
                    # An element inside `-ArgumentList @(...)` is positional on
                    # the CHILD's command line whatever its position here.
                    $isPos = $arg.Positional -or ($null -ne $arg.Param)
                    $t = Get-ArgvHazardStaticText -Expr $e
                    if ($t -match '^\+([a-z0-9-]+)$') {
                        $v = $Matches[1].ToLowerInvariant()
                        if ($script:ArgvHazardVerbs -contains $v) { $verb = $v }
                        continue
                    }
                    $carrier = Get-ArgvHazardCarrier -Expr $e -PrevVerb $verb `
                        -IsPositional:$isPos
                    if (-not $carrier) {
                        # The split pair `--title` `$value`.
                        if ($arg.PendingFlag -and
                            ($script:ArgvHazardFlags -contains $arg.PendingFlag)) {
                            $carrier = "--$($arg.PendingFlag)"
                        } else { continue }
                    }
                    if (Test-ArgvHazardLiteral -Expr $e -Consts $siteConsts) { continue }

                    $exempt = Test-ArgvHazardExempt -Lines $lines `
                        -StartLine $c.Extent.StartLineNumber `
                        -EndLine $c.Extent.EndLineNumber
                    if ($exempt -and -not $IncludeExempt) { continue }

                    $findings += [pscustomobject]@{
                        File    = $rel
                        Line    = $e.Extent.StartLineNumber
                        Carrier = $carrier
                        Text    = $e.Extent.Text
                        Exempt  = $exempt
                    }
                }
            }
        }
    }
    @($findings)
}
