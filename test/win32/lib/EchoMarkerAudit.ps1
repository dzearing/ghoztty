# EchoMarkerAudit (T1143) - find the harness waits that look in a pane for a
# needle the same script TYPED into that pane.
#
# THE DEFECT (T1116): holder-volume.ps1 typed a flood command whose last word
# was a unique end marker, then waited for the marker to appear in the pane as
# proof the flood had finished. A shell ECHOES the command line it is given, so
# the marker was on screen the instant the keys landed: the wait scored a flood
# that had not started, and in one run was still printing a minute later. The
# same bytes reach the agent's ring, so a ring wait is fooled the same way.
#
# Seeing the echo is not always wrong. "The shell echoed what I typed" proves
# the pane is live, and "the scrollback came back" is as true of an echoed line
# as of a printed one. What the echo can never prove is that the command RAN,
# and nothing in the source says which of the two a wait meant. So every such
# wait has to say it:
#
#   * it is a presence check - `# echo-marker: <reason>` on the wait's line or
#     the line above, with the reason (a marker with no reason exempts nothing);
#   * or the needle is assembled where the echo cannot hold it whole - typed in
#     halves the shell joins (holder-volume.ps1's `'x' + '$doneHead' +
#     '$doneTail'`), so only the command's OUTPUT contains it. That form is not a
#     finding at all, because the variable waited for is never typed.
#
# The sites present when this landed were each read by the T1143 sweep and are
# presence checks; they are a per-file count in echo-marker-audit.baseline.json
# rather than markers in their files, so recording them did not edit (and
# re-due) the harnesses that own them. A file ABOVE its count fails.
#
# WHAT IS "TYPED" - a variable is typed when it is interpolated into a
# `+send-keys` payload: an argument after `+send-keys` in an array literal or a
# command, or a word of a "+send-keys ..." string. `--target=`/`--name=` style
# options are addresses, not keystrokes, and are skipped; `--keys-file=$f`
# makes $f a keys file, and the variables written INTO $f (WriteAllText,
# WriteAllLines, Set-Content, Add-Content, Out-File) are typed. Typing is then
# carried through assignments: if `$cmd` is typed and `$cmd = "... $done"`,
# `$done` is typed too. It is not carried backwards, which is what lets the
# split form above through: `$done = $head + $tail` with `$head` and `$tail`
# typed leaves `$done` untyped.
#
# WHAT IS A WAIT - a typed variable used as
#   wait     an argument of a `Wait-*` command;
#   match    the right-hand side of -match / -like / -cmatch / -clike /
#            -imatch / -ilike (and their negations);
#   contains an argument of .Contains() / .IndexOf().
#
# KINDS: `wait`, `match`, `contains` (all hard - they feed the ratchet), and
# `parse-error`, held at zero.

Set-StrictMode -Off

function Get-EchoMarkerRelativePath([string]$Path, [string]$Repo) {
    $full = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetFullPath($Repo).TrimEnd('\') + '\'
    if ($full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $full.Substring($root.Length)
    }
    return $Path
}

function Test-EchoMarkerExempt($Lines, [int]$LineNumber) {
    foreach ($n in @($LineNumber, ($LineNumber - 1))) {
        if ($n -lt 1 -or $n -gt $Lines.Count) { continue }
        if ($Lines[$n - 1] -match '#\s*echo-marker:\s*\S') { return $true }
    }
    return $false
}

function Get-EchoMarkerVars($Node) {
    $out = @()
    foreach ($v in $Node.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
        $out += $v.VariablePath.UserPath.ToLower() -replace '^(script|global|local):', ''
    }
    return , $out
}

# The variables whose TEXT a value is built from: the value itself, the
# variables interpolated into a string, and the operands of a `+`. A variable
# that is only an argument (`Join-Path $tmp 'x'`, `$list.Count`) contributes no
# text of its own, so typing is not carried through it.
function Get-EchoMarkerTextVars($Node) {
    $out = @()
    if ($null -eq $Node) { return , $out }
    if ($Node -is [System.Management.Automation.Language.VariableExpressionAst]) {
        return , @($Node.VariablePath.UserPath.ToLower() -replace '^(script|global|local):', '')
    }
    if ($Node -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) {
        foreach ($e in $Node.NestedExpressions) { $out += Get-EchoMarkerTextVars $e }
        return , $out
    }
    if ($Node -is [System.Management.Automation.Language.SubExpressionAst]) {
        foreach ($st in $Node.SubExpression.Statements) { $out += Get-EchoMarkerTextVars $st }
        return , $out
    }
    if ($Node -is [System.Management.Automation.Language.BinaryExpressionAst] -and "$($Node.Operator)" -eq 'Plus') {
        $out += Get-EchoMarkerTextVars $Node.Left
        $out += Get-EchoMarkerTextVars $Node.Right
        return , $out
    }
    if ($Node -is [System.Management.Automation.Language.ParenExpressionAst]) { return , (Get-EchoMarkerTextVars $Node.Pipeline) }
    if ($Node -is [System.Management.Automation.Language.PipelineAst] -and $Node.PipelineElements.Count -eq 1) {
        return , (Get-EchoMarkerTextVars $Node.PipelineElements[0])
    }
    if ($Node -is [System.Management.Automation.Language.CommandExpressionAst]) { return , (Get-EchoMarkerTextVars $Node.Expression) }
    if ($Node -is [System.Management.Automation.Language.ConvertExpressionAst]) { return , (Get-EchoMarkerTextVars $Node.Child) }
    return , $out
}

# The variables a `+send-keys` payload element types. An element that is an
# option (`--target=$pane`) types nothing; `--keys-file=$f` is returned as a
# keys file instead.
function Add-EchoMarkerElement($Element, [hashtable]$Typed, [hashtable]$KeysFiles) {
    $L = [System.Management.Automation.Language.StringConstantExpressionAst]
    $E = [System.Management.Automation.Language.ExpandableStringExpressionAst]
    if ($Element -is $E) {
        # Word by word, so one "+send-keys --target=$p echo $m" string types
        # $m and not $p. A nested variable belongs to the word it starts in.
        $text = $Element.Value
        # Past the opening quote, when there is one: an unquoted `--target=$p`
        # argument is an expandable string too, and starts at its first char.
        $start = $Element.Extent.StartOffset
        if ($Element.Extent.Text.StartsWith('"')) { $start++ }
        foreach ($v in $Element.NestedExpressions) {
            $at = $v.Extent.StartOffset - $start
            if ($at -lt 0 -or $at -gt $text.Length) { $at = 0 }
            $before = $text.Substring(0, [Math]::Min($at, $text.Length))
            $word = ($before -split '\s')[-1]
            if ($word -match '^--keys-file=') { foreach ($n in (Get-EchoMarkerVars $v)) { $KeysFiles[$n] = $true }; continue }
            $names = Get-EchoMarkerTextVars $v
            if ($word -match '^--[\w-]+=') { continue }
            if ($word -match '^\+send-keys$') { continue }
            foreach ($n in $names) { $Typed[$n] = $true }
        }
        return
    }
    if ($Element -is $L) { return }
    $t = $Element.Extent.Text
    if ($t -match '^["'']?--keys-file=') {
        foreach ($n in (Get-EchoMarkerVars $Element)) { $KeysFiles[$n] = $true }
        return
    }
    if ($t -match '^["'']?--[\w-]+=') { return }
    foreach ($n in (Get-EchoMarkerTextVars $Element)) { $Typed[$n] = $true }
}

function Get-EchoMarkerFindings {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()][AllowEmptyString()][string[]]$Text
    )
    $findings = New-Object System.Collections.ArrayList
    $tok = $null; $err = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput(($Text -join "`n"), [ref]$tok, [ref]$err)
    if (@($err).Count -gt 0) {
        [void]$findings.Add([pscustomobject]@{ Path = $Path; Line = $err[0].Extent.StartLineNumber; Kind = 'parse-error'; Detail = $err[0].Message })
        return , $findings.ToArray()
    }
    $A = [System.Management.Automation.Language.ArrayLiteralAst]
    $C = [System.Management.Automation.Language.CommandAst]
    $S = [System.Management.Automation.Language.StringConstantExpressionAst]
    $E = [System.Management.Automation.Language.ExpandableStringExpressionAst]

    $typed = @{}
    $keysFiles = @{}
    $isSendKeys = { param($n) ($n -is $S -or $n -is $E) -and $n.Value -eq '+send-keys' }

    foreach ($n in $ast.FindAll({ param($x) $x -is $A -or $x -is $C -or $x -is $E }, $true)) {
        if ($n -is $E) {
            if ($n.Value -match '(^|\s)\+send-keys(\s|$)') { Add-EchoMarkerElement $n $typed $keysFiles }
            continue
        }
        $els = if ($n -is $A) { @($n.Elements) } else { @($n.CommandElements) }
        $idx = -1
        for ($i = 0; $i -lt $els.Count; $i++) { if (& $isSendKeys $els[$i]) { $idx = $i; break } }
        if ($idx -lt 0) { continue }
        for ($i = $idx + 1; $i -lt $els.Count; $i++) {
            $el = $els[$i]
            if ($el -is [System.Management.Automation.Language.CommandParameterAst]) { continue }
            if ($el -is [System.Management.Automation.Language.RedirectionAst]) { continue }
            Add-EchoMarkerElement $el $typed $keysFiles
        }
    }

    # What is written into a keys file is typed.
    if ($keysFiles.Count -gt 0) {
        foreach ($call in $ast.FindAll({ param($x)
                    ($x -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
                     $x.Member.Extent.Text -in 'WriteAllText', 'WriteAllLines', 'AppendAllText') -or
                    ($x -is $C -and $x.GetCommandName() -in 'Set-Content', 'Add-Content', 'Out-File') }, $true)) {
            if (@((Get-EchoMarkerVars $call) | Where-Object { $keysFiles.ContainsKey($_) }).Count -eq 0) { continue }
            $args_ = if ($call -is $C) { @($call.CommandElements | Select-Object -Skip 1) } else { @($call.Arguments) }
            foreach ($a in $args_) {
                foreach ($nm in (Get-EchoMarkerTextVars $a)) { if (-not $keysFiles.ContainsKey($nm)) { $typed[$nm] = $true } }
            }
        }
    }

    # Carry typing forward through assignments, to a fixed point: a typed
    # variable's text includes the text of every variable its value was built
    # from.
    $assigns = @($ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $x.Left -is [System.Management.Automation.Language.VariableExpressionAst] }, $true))
    do {
        $grew = $false
        foreach ($as in $assigns) {
            $lhs = $as.Left.VariablePath.UserPath.ToLower() -replace '^(script|global|local):', ''
            if (-not $typed.ContainsKey($lhs)) { continue }
            foreach ($nm in (Get-EchoMarkerTextVars $as.Right)) {
                if (-not $typed.ContainsKey($nm)) { $typed[$nm] = $true; $grew = $true }
            }
        }
    } while ($grew)

    # Automatic and plumbing variables are never a marker.
    foreach ($nm in 'pid', 'true', 'false', 'null', '_', 'psscriptroot', 'env:temp') { $typed.Remove($nm) }
    if ($typed.Count -eq 0) { return , $findings.ToArray() }

    $add = {
        param($Line, $Kind, $Name, $Detail)
        if (Test-EchoMarkerExempt $Text $Line) { return }
        [void]$findings.Add([pscustomobject]@{ Path = $Path; Line = $Line; Kind = $Kind; Var = $Name; Detail = ($Detail -replace '\s+', ' ') })
    }

    # A needle the echo can hold whole is one that is NOTHING BUT typed text:
    # the typed variable itself, "$marker", or [regex]::Escape($marker). A
    # needle with literal text of its own ("PROBE_READY_$tag", "R$count",
    # "$probe\s*$") is the script asking for something the command PRINTS,
    # which the echo of `-Tag $tag` does not contain.
    $bare = {
        param($Node)
        while ($true) {
            if ($Node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
                $Node.Static -and $Node.Member.Extent.Text -eq 'Escape' -and @($Node.Arguments).Count -eq 1) {
                $Node = $Node.Arguments[0]; continue
            }
            if ($Node -is [System.Management.Automation.Language.ParenExpressionAst] -and
                $Node.Pipeline.PipelineElements.Count -eq 1 -and
                $Node.Pipeline.PipelineElements[0] -is [System.Management.Automation.Language.CommandExpressionAst]) {
                $Node = $Node.Pipeline.PipelineElements[0].Expression; continue
            }
            break
        }
        if ($Node -is [System.Management.Automation.Language.VariableExpressionAst]) {
            $nm = $Node.VariablePath.UserPath.ToLower() -replace '^(script|global|local):', ''
            if ($typed.ContainsKey($nm)) { return $nm }
            return $null
        }
        if ($Node -is $E -and @($Node.NestedExpressions).Count -eq 1) {
            $inner = $Node.NestedExpressions[0]
            $rest = $Node.Value.Replace($inner.Extent.Text, '')
            if ($rest -notmatch '\S') { return (& $bare $inner) }
        }
        return $null
    }

    foreach ($w in $ast.FindAll({ param($x) $x -is $C -and $x.GetCommandName() -like 'Wait-*' }, $true)) {
        $seen = @{}
        foreach ($el in @($w.CommandElements | Select-Object -Skip 1)) {
            $nm = & $bare $el
            if ($nm -and -not $seen.ContainsKey($nm)) {
                $seen[$nm] = $true
                & $add $w.Extent.StartLineNumber 'wait' $nm $w.Extent.Text
            }
        }
    }
    foreach ($b in $ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.BinaryExpressionAst] -and
                "$($x.Operator)" -match '^(I|C)?(Not)?(Match|Like)$' }, $true)) {
        $nm = & $bare $b.Right
        if ($nm) { & $add $b.Extent.StartLineNumber 'match' $nm $b.Extent.Text }
    }
    foreach ($m in $ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
                -not $x.Static -and $x.Member.Extent.Text -in 'Contains', 'IndexOf' }, $true)) {
        foreach ($arg in @($m.Arguments)) {
            $nm = & $bare $arg
            if ($nm) { & $add $m.Extent.StartLineNumber 'contains' $nm $m.Extent.Text; break }
        }
    }
    return , $findings.ToArray()
}

function Get-EchoMarkerSweep {
    param([Parameter(Mandatory = $true)][string[]]$Roots)
    $all = New-Object System.Collections.ArrayList
    foreach ($r in $Roots) {
        foreach ($file in @(Get-ChildItem -LiteralPath $r -Filter *.ps1 -File -Recurse)) {
            $text = @(Get-Content -LiteralPath $file.FullName)
            foreach ($x in (Get-EchoMarkerFindings -Path $file.FullName -Text $text)) { [void]$all.Add($x) }
        }
    }
    return , $all.ToArray()
}

# The ratchet comparison, as a function so the teeth can feed it a sweep with a
# planted file in it and require it to score red.
function Compare-EchoMarkerBaseline {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Current,
        [Parameter(Mandatory = $true)][hashtable]$Baseline
    )
    $regressed = New-Object System.Collections.ArrayList
    $improved = New-Object System.Collections.ArrayList
    foreach ($k in ($Current.Keys | Sort-Object)) {
        $was = 0
        if ($Baseline.ContainsKey($k)) { $was = $Baseline[$k] }
        if ($Current[$k] -gt $was) { [void]$regressed.Add("$k ($was -> $($Current[$k]))") }
        elseif ($Current[$k] -lt $was) { [void]$improved.Add("$k ($was -> $($Current[$k]))") }
    }
    foreach ($k in ($Baseline.Keys | Sort-Object)) {
        if (-not $Current.ContainsKey($k) -and $Baseline[$k] -gt 0) {
            [void]$improved.Add("$k ($($Baseline[$k]) -> 0)")
        }
    }
    return [pscustomobject]@{ Regressed = $regressed.ToArray(); Improved = $improved.ToArray() }
}
