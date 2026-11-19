# FixtureNames (T1501) - find a filename a script means to create that Windows
# will quietly create under a DIFFERENT name.
#
# THE TRAP. Win32 path normalization rewrites the last characters of a path
# segment before the file system ever sees it, and it does so without an error:
#
#     PS 5.1> Set-Content -Path (Join-Path $d '._.') -Value x   # succeeds...
#     PS 5.1> (Get-ChildItem $d).Name
#     ._                                                       # ...as '._'
#
#   * a trailing dot or space is stripped ('._.' -> '._', 'name ' -> 'name');
#   * a reserved device name (CON, PRN, AUX, NUL, COM0-9, LPT0-9 - with or
#     without an extension) opens the DEVICE, so nothing is planted at all.
#
# A fixture written that way plants something other than the name it reads as,
# and the harness on top of it is quietly weaker than it says. That is exactly
# T1436: the torn-package fixtures reproduced the real package "exactly" apart
# from the one name (`._.`) that defeats the delete, every arm stayed green, and
# the real heal could not delete the real package - four floor lanes red until a
# human deleted it by hand (T1499).
#
# THE RULE. A string a script hands to something that CREATES or NAMES a path
# - New-Item, Set-Content, Out-File, Copy-Item, Join-Path, [IO.File]::Write*,
# a `>` redirection, or a helper function in the same file that passes its
# parameter on to one of those - may not carry such a segment, unless the path
# goes through `ConvertTo-ExtendedPath` (scripts\lib\HardDelete.ps1) or a
# literal `\\?\` prefix, which hand the name to the object manager verbatim.
# A deliberate exception carries `# fixture-name-ok: <why>` on the line.
#
# Literals are followed one hop at a time (bounded) through `$x = ...`,
# `foreach ($x in ...)` and a same-file helper's parameters, which is the shape
# the T1436 fixture had: `foreach ($f in '._.', ...) { New-CacheFile -Name $f }`.
#
# Consumer: test\win32\fixture-name-audit.ps1 (a harness-floor member).

Set-StrictMode -Off

# Command name -> which of its arguments are paths. `Params` are matched by
# prefix (PowerShell accepts any unambiguous abbreviation); `Positional` lists
# the positional slots that bind a path ('*' = every positional argument).
$script:FIXTURE_PATH_COMMANDS = @{
    'set-content'    = @{ Params = @('path', 'literalpath'); Positional = @(0) }
    'add-content'    = @{ Params = @('path', 'literalpath'); Positional = @(0) }
    'out-file'       = @{ Params = @('filepath', 'literalpath'); Positional = @(0) }
    'new-item'       = @{ Params = @('path', 'name'); Positional = @(0) }
    'copy-item'      = @{ Params = @('path', 'literalpath', 'destination'); Positional = @(0, 1) }
    'move-item'      = @{ Params = @('path', 'literalpath', 'destination'); Positional = @(0, 1) }
    'rename-item'    = @{ Params = @('newname'); Positional = @(1) }
    'join-path'      = @{ Params = @('path', 'childpath', 'additionalchildpath'); Positional = @('*') }
    'export-csv'     = @{ Params = @('path', 'literalpath'); Positional = @(0) }
    'export-clixml'  = @{ Params = @('path', 'literalpath'); Positional = @(0) }
    'tee-object'     = @{ Params = @('filepath', 'literalpath'); Positional = @() }
    'ni'             = @{ Params = @('path', 'name'); Positional = @(0) }
    'sc'             = @{ Params = @('path', 'literalpath'); Positional = @(0) }
    'ac'             = @{ Params = @('path', 'literalpath'); Positional = @(0) }
    'copy'           = @{ Params = @('path', 'literalpath', 'destination'); Positional = @(0, 1) }
    'cp'             = @{ Params = @('path', 'literalpath', 'destination'); Positional = @(0, 1) }
    'move'           = @{ Params = @('path', 'literalpath', 'destination'); Positional = @(0, 1) }
    'mv'             = @{ Params = @('path', 'literalpath', 'destination'); Positional = @(0, 1) }
    'mkdir'          = @{ Params = @('path'); Positional = @(0) }
    'md'             = @{ Params = @('path'); Positional = @(0) }
}

# Switch parameters that take no argument, so the element after them is not
# their value. Only the ones the commands above actually carry.
$script:FIXTURE_SWITCHES = @('force', 'recurse', 'nonewline', 'append', 'passthru', 'confirm',
    'whatif', 'noclobber', 'container', 'resolve', 'notypeinformation', 'asbytestream')

# [type]::Method -> which argument slots are paths ('*' = all).
$script:FIXTURE_PATH_TYPES = @('io.file', 'system.io.file', 'io.directory', 'system.io.directory',
    'io.path', 'system.io.path')
$script:FIXTURE_PATH_METHODS = @{
    'writealltext' = @(0); 'writeallbytes' = @(0); 'writealllines' = @(0)
    'appendalltext' = @(0); 'appendalllines' = @(0); 'create' = @(0); 'createtext' = @(0)
    'appendtext' = @(0); 'createdirectory' = @(0); 'copy' = @(0, 1); 'move' = @(0, 1)
    'replace' = @(0, 1); 'combine' = @('*')
}

$script:FIXTURE_PRAGMA = 'fixture-name-ok:'

if (-not ('GhozttyFixtureAstIndex' -as [type])) {
    Add-Type -TypeDefinition @'
using System.Collections.Generic;
using System.Management.Automation.Language;
public static class GhozttyFixtureAstIndex {
    // Files every node by kind in one compiled walk. Returns, in order:
    // strings, commands, members, redirections, functions, bindings.
    public static List<Ast>[] Collect(Ast root) {
        var o = new List<Ast>[6];
        for (int i = 0; i < 6; i++) o[i] = new List<Ast>();
        foreach (Ast n in root.FindAll(x => true, true)) {
            if (n is StringConstantExpressionAst || n is ExpandableStringExpressionAst) o[0].Add(n);
            else if (n is CommandAst) o[1].Add(n);
            else if (n is InvokeMemberExpressionAst) o[2].Add(n);
            else if (n is FileRedirectionAst) o[3].Add(n);
            else if (n is FunctionDefinitionAst) o[4].Add(n);
            else if (n is ForEachStatementAst) o[5].Add(n);
            else if (n is AssignmentStatementAst && ((AssignmentStatementAst)n).Left is VariableExpressionAst) o[5].Add(n);
        }
        return o;
    }

    static readonly System.Text.RegularExpressions.Regex Reserved =
        new System.Text.RegularExpressions.Regex(@"^(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])$",
            System.Text.RegularExpressions.RegexOptions.IgnoreCase);

    // Why Windows would not create this one segment verbatim, or null. A
    // segment may hold `$var` text from an expanding string: a trailing dot or
    // space on its literal tail is stripped whatever the variable holds, but a
    // device-name test only means something on an all-literal segment.
    public static string SegmentHazard(string seg) {
        if (string.IsNullOrEmpty(seg) || seg == "." || seg == "..") return null;
        if (seg.IndexOf('*') >= 0 || seg.IndexOf('?') >= 0) return null;   // a filter, not a name
        if (seg.EndsWith(".")) return "trailing dot (Windows strips it)";
        if (seg.EndsWith(" ")) return "trailing space (Windows strips it)";
        if (seg.IndexOf('$') >= 0) return null;
        int dot = seg.IndexOf('.');
        string b = (dot >= 0 ? seg.Substring(0, dot) : seg).TrimEnd(' ');
        if (Reserved.IsMatch(b)) return "reserved device name (opens the device, plants nothing)";
        return null;
    }

    // { segment, hazard } for the first bad segment of a literal, or null. An
    // extended `\\?\` path is handed over verbatim: the remedy, not a hazard.
    public static string[] LiteralHazard(string v) {
        if (string.IsNullOrEmpty(v) || v.StartsWith(@"\\?\")) return null;
        foreach (string seg in v.Split('\\', '/')) {
            string h = SegmentHazard(seg);
            if (h != null) return new string[] { seg, h };
        }
        return null;
    }

    public static int CountHazards(List<Ast> strings) {
        int n = 0;
        foreach (Ast a in strings) {
            string v = a is StringConstantExpressionAst ? ((StringConstantExpressionAst)a).Value
                                                        : ((ExpandableStringExpressionAst)a).Value;
            if (LiteralHazard(v) != null) n++;
        }
        return n;
    }
}
'@
}

# The rule itself lives in the compiled helper below (GhozttyFixtureAstIndex),
# because it runs over every string in the suite; these are its PowerShell faces.
function Get-FixtureSegmentHazard([string]$Segment) { return [GhozttyFixtureAstIndex]::SegmentHazard($Segment) }

function Get-FixtureLiteralHazard([string]$Value) {
    $r = [GhozttyFixtureAstIndex]::LiteralHazard($Value)
    if ($null -eq $r) { return $null }
    return [pscustomobject]@{ Segment = $r[0]; Hazard = $r[1] }
}

function Get-FixtureAncestor($Ast, [scriptblock]$Predicate) {
    $p = $Ast.Parent
    while ($p) {
        if (& $Predicate $p) { return $p }
        $p = $p.Parent
    }
    return $null
}

# A site is exempt when its path is already wrapped in the remedy, or the line
# carries the pragma.
function Test-FixtureSiteExempt($SiteAst, [string[]]$Lines) {
    $wrapped = Get-FixtureAncestor $SiteAst {
        param($a)
        ($a -is [System.Management.Automation.Language.CommandAst]) -and
        ([string]$a.GetCommandName() -ieq 'ConvertTo-ExtendedPath')
    }
    if ($wrapped) { return $true }
    if ($SiteAst.Extent.Text.Contains('\\?\') -or $SiteAst.Extent.Text -match 'ConvertTo-ExtendedPath') { return $true }
    $ln = $SiteAst.Extent.StartLineNumber
    if ($ln -ge 1 -and $ln -le $Lines.Count -and $Lines[$ln - 1].Contains($script:FIXTURE_PRAGMA)) { return $true }
    return $false
}

# Bind a CommandAst's arguments: returns @{ Named = @(@{Name;Ast}); Positional = @(ast) }.
function Get-FixtureCommandBinding($CommandAst) {
    $named = New-Object System.Collections.ArrayList
    $positional = New-Object System.Collections.ArrayList
    $els = @($CommandAst.CommandElements)
    $i = 1
    while ($i -lt $els.Count) {
        $e = $els[$i]
        if ($e -is [System.Management.Automation.Language.CommandParameterAst]) {
            $pn = ([string]$e.ParameterName).ToLowerInvariant()
            if ($e.Argument) { [void]$named.Add(@{ Name = $pn; Ast = $e.Argument }); $i++; continue }
            $isSwitch = $false
            foreach ($s in $script:FIXTURE_SWITCHES) { if ($s.StartsWith($pn)) { $isSwitch = $true; break } }
            if (-not $isSwitch -and ($i + 1) -lt $els.Count -and
                -not ($els[$i + 1] -is [System.Management.Automation.Language.CommandParameterAst])) {
                [void]$named.Add(@{ Name = $pn; Ast = $els[$i + 1] })
                $i += 2
                continue
            }
            $i++
            continue
        }
        [void]$positional.Add($e)
        $i++
    }
    return @{ Named = @($named); Positional = @($positional) }
}

function Test-FixtureParamMatch([string]$Given, [string[]]$Wanted) {
    foreach ($w in $Wanted) { if ($w.StartsWith($Given)) { return $true } }
    return $false
}

# The ordered parameter names of a function definition, lower-cased.
function Get-FixtureFunctionParams($FuncAst) {
    $ps = @()
    if ($FuncAst.Body.ParamBlock -and $FuncAst.Body.ParamBlock.Parameters) {
        $ps = @($FuncAst.Body.ParamBlock.Parameters)
    }
    elseif ($FuncAst.Parameters) { $ps = @($FuncAst.Parameters) }
    return @($ps | ForEach-Object { ([string]$_.Name.VariablePath.UserPath).ToLowerInvariant() })
}

<#
.SYNOPSIS
Every literal string a path argument can carry, with the extent it was written at.

.DESCRIPTION
Walks the argument expression, and through a variable to whatever was bound
to it - an assignment, a foreach, or (for a helper function's parameter) every
call site's argument for that parameter. Bounded by $Depth and a visited set,
so a self-assignment cannot loop. Command calls inside the expression are NOT
descended: a nested path command is a site of its own.
#>
function Get-FixtureLiterals($Expr, $Ctx, [int]$Depth, [hashtable]$Visited) {
    $L = [System.Management.Automation.Language.StringConstantExpressionAst]
    $out = New-Object System.Collections.ArrayList
    if ($null -eq $Expr -or $Depth -lt 0) { return @() }

    if ($Expr -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
        [void]$out.Add([pscustomobject]@{ Value = [string]$Expr.Value; Ast = $Expr })
    }
    elseif ($Expr -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) {
        [void]$out.Add([pscustomobject]@{ Value = [string]$Expr.Value; Ast = $Expr })
    }
    elseif ($Expr -is [System.Management.Automation.Language.ArrayLiteralAst]) {
        foreach ($e in $Expr.Elements) { foreach ($x in (Get-FixtureLiterals $e $Ctx $Depth $Visited)) { [void]$out.Add($x) } }
    }
    elseif ($Expr -is [System.Management.Automation.Language.ParenExpressionAst]) {
        foreach ($x in (Get-FixtureLiterals $Expr.Pipeline $Ctx $Depth $Visited)) { [void]$out.Add($x) }
    }
    elseif ($Expr -is [System.Management.Automation.Language.ArrayExpressionAst] -or
            $Expr -is [System.Management.Automation.Language.SubExpressionAst]) {
        foreach ($st in $Expr.SubExpression.Statements) {
            foreach ($x in (Get-FixtureLiterals $st $Ctx $Depth $Visited)) { [void]$out.Add($x) }
        }
    }
    elseif ($Expr -is [System.Management.Automation.Language.PipelineAst]) {
        $pe = @($Expr.PipelineElements)
        if ($pe.Count -eq 1 -and $pe[0] -is [System.Management.Automation.Language.CommandExpressionAst]) {
            foreach ($x in (Get-FixtureLiterals $pe[0].Expression $Ctx $Depth $Visited)) { [void]$out.Add($x) }
        }
    }
    elseif ($Expr -is [System.Management.Automation.Language.CommandExpressionAst]) {
        foreach ($x in (Get-FixtureLiterals $Expr.Expression $Ctx $Depth $Visited)) { [void]$out.Add($x) }
    }
    elseif ($Expr -is [System.Management.Automation.Language.BinaryExpressionAst]) {
        $op = [string]$Expr.Operator
        if ($op -eq 'Plus') {
            foreach ($x in (Get-FixtureLiterals $Expr.Left $Ctx $Depth $Visited)) { [void]$out.Add($x) }
            # The right operand of `+` continues the left one's text, so only
            # its END can end a segment - check it as a whole literal too.
            foreach ($x in (Get-FixtureLiterals $Expr.Right $Ctx $Depth $Visited)) { [void]$out.Add($x) }
        }
        elseif ($op -eq 'Format') {
            foreach ($x in (Get-FixtureLiterals $Expr.Left $Ctx $Depth $Visited)) { [void]$out.Add($x) }
        }
    }
    elseif ($Expr -is [System.Management.Automation.Language.VariableExpressionAst]) {
        $name = ([string]$Expr.VariablePath.UserPath).ToLowerInvariant()
        $func = Get-FixtureAncestor $Expr { param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] }
        $scopeKey = if ($func) { [string]$func.Name } else { '<script>' }
        $key = "$scopeKey`:$name"
        if ($Visited.ContainsKey($key) -or $Depth -eq 0) { return @($out) }
        $Visited[$key] = $true

        # The bindings were indexed once per file (Get-FixtureBindingIndex):
        # this function's own first, else the variable's bindings anywhere.
        $sources = New-Object System.Collections.ArrayList
        $own = $Ctx.Bindings[$key]
        if ($own) { foreach ($s in $own) { [void]$sources.Add($s) } }
        elseif ($Ctx.Bindings["*:$name"]) { foreach ($s in $Ctx.Bindings["*:$name"]) { [void]$sources.Add($s) } }
        # A helper's parameter: what every call site passes for it.
        if ($func) {
            [string[]]$params = @(Get-FixtureFunctionParams $func)
            $slot = [array]::IndexOf($params, $name)
            if ($slot -ge 0) {
                foreach ($call in @($Ctx.Calls[([string]$func.Name).ToLowerInvariant()])) {
                    if (-not $call) { continue }
                    $b = Get-FixtureCommandBinding $call
                    foreach ($n in $b.Named) { if ($name.StartsWith($n.Name)) { [void]$sources.Add($n.Ast) } }
                    $pos = @($b.Positional)
                    # Positional slot = this parameter's index among those not bound by name.
                    $boundByName = @($b.Named | ForEach-Object { $nn = $_.Name; $params | Where-Object { $_.StartsWith($nn) } })
                    [string[]]$free = @($params | Where-Object { $boundByName -notcontains $_ })
                    $pi = [array]::IndexOf($free, $name)
                    if ($pi -ge 0 -and $pi -lt $pos.Count) { [void]$sources.Add($pos[$pi]) }
                }
            }
        }
        foreach ($s in $sources) {
            foreach ($x in (Get-FixtureLiterals $s $Ctx ($Depth - 1) $Visited)) { [void]$out.Add($x) }
        }
    }
    return @($out)
}

# ONE walk of the tree (T1501 perf): every node is visited once and filed by
# kind. A FindAll per question, plus a parent walk per assignment, took 137 s
# over the suite; the predicate scriptblock is what costs, so it runs once.

function Get-FixtureFileIndex($Root) {
    $o = [GhozttyFixtureAstIndex]::Collect($Root)
    $hz = [GhozttyFixtureAstIndex]::CountHazards($o[0])
    return @{
        Commands = $o[1]; Members = $o[2]; Redirs = $o[3]; Funcs = $o[4]; Binds = $o[5]; Hazards = $hz
    }
}

# Every `$x = ...` and `foreach ($x in ...)`, keyed '<function>:<name>' (or
# '<script>:<name>') and '*:<name>' -> source expressions.
function Get-FixtureBindingIndex($Binds) {
    $D = [System.Management.Automation.Language.FunctionDefinitionAst]
    $idx = @{}
    foreach ($a in $Binds) {
        if ($a -is [System.Management.Automation.Language.ForEachStatementAst]) {
            $n = ([string]$a.Variable.VariablePath.UserPath).ToLowerInvariant(); $src = $a.Condition
        }
        else { $n = ([string]$a.Left.VariablePath.UserPath).ToLowerInvariant(); $src = $a.Right }
        $p = $a.Parent
        while ($p -and -not ($p -is $D)) { $p = $p.Parent }
        $scopeKey = if ($p) { [string]$p.Name } else { '<script>' }
        foreach ($k in @("$scopeKey`:$n", "*:$n")) {
            if (-not $idx.ContainsKey($k)) { $idx[$k] = New-Object System.Collections.ArrayList }
            [void]$idx[$k].Add($src)
        }
    }
    return $idx
}

<#
.SYNOPSIS
The path-argument expressions in one file: each with the site that consumes it.
#>
function Get-FixturePathSites($Ix) {
    $sites = New-Object System.Collections.ArrayList

    foreach ($cmd in $Ix.Commands) {
        $n = [string]$cmd.GetCommandName()
        if (-not $n) { continue }
        $spec = $script:FIXTURE_PATH_COMMANDS[$n.ToLowerInvariant()]
        if (-not $spec) { continue }
        $b = Get-FixtureCommandBinding $cmd
        foreach ($nm in $b.Named) {
            if (Test-FixtureParamMatch $nm.Name $spec.Params) { [void]$sites.Add(@{ Site = $cmd; Arg = $nm.Ast }) }
        }
        $pos = @($b.Positional)
        for ($i = 0; $i -lt $pos.Count; $i++) {
            if ($spec.Positional -contains '*' -or $spec.Positional -contains $i) {
                [void]$sites.Add(@{ Site = $cmd; Arg = $pos[$i] })
            }
        }
    }

    foreach ($m in $Ix.Members) {
        if (-not ($m.Expression -is [System.Management.Automation.Language.TypeExpressionAst])) { continue }
        $t = ([string]$m.Expression.TypeName.FullName).ToLowerInvariant()
        if ($script:FIXTURE_PATH_TYPES -notcontains $t) { continue }
        if (-not ($m.Member -is [System.Management.Automation.Language.StringConstantExpressionAst])) { continue }
        $slots = $script:FIXTURE_PATH_METHODS[([string]$m.Member.Value).ToLowerInvariant()]
        # NOT `-not $slots`: @(0) is a one-element array whose element is 0, so
        # it reads as false and every slot-0 method would be skipped.
        if ($null -eq $slots) { continue }
        $margs = @($m.Arguments)
        for ($i = 0; $i -lt $margs.Count; $i++) {
            if ($slots -contains '*' -or $slots -contains $i) { [void]$sites.Add(@{ Site = $m; Arg = $margs[$i] }) }
        }
    }

    foreach ($r in $Ix.Redirs) { [void]$sites.Add(@{ Site = $r; Arg = $r.Location }) }
    return @($sites)
}

<#
.SYNOPSIS
Findings in one file: where the hostile name is written, and which call takes it.
#>
function Get-FixtureNameFindings([string]$Path) {
    $tokens = $null; $errors = $null
    $root = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if (-not $root) { return @() }
    $ix = Get-FixtureFileIndex $root
    # Every finding IS a hazardous literal, so a file without one has none -
    # and that is most files, which is what keeps the sweep to seconds.
    if ($ix.Hazards -eq 0) { return @() }
    $lines = @([System.IO.File]::ReadAllLines($Path))

    $calls = @{}
    foreach ($f in $ix.Funcs) { $calls[([string]$f.Name).ToLowerInvariant()] = New-Object System.Collections.ArrayList }
    foreach ($c in $ix.Commands) {
        $cn = [string]$c.GetCommandName()
        if (-not $cn) { continue }
        $k = $cn.ToLowerInvariant()
        if ($calls.ContainsKey($k)) { [void]$calls[$k].Add($c) }
    }
    $ctx = @{ Root = $root; Calls = $calls; Bindings = (Get-FixtureBindingIndex $ix.Binds) }

    $seen = @{}
    $findings = New-Object System.Collections.ArrayList
    foreach ($s in (Get-FixturePathSites $ix)) {
        $exempt = $null   # decided once, and only when a hazard reaches the site
        foreach ($lit in (Get-FixtureLiterals $s.Arg $ctx 4 @{})) {
            $hz = Get-FixtureLiteralHazard $lit.Value
            if (-not $hz) { continue }
            if ($null -eq $exempt) { $exempt = Test-FixtureSiteExempt $s.Site $lines }
            if ($exempt) { break }
            $ln = $lit.Ast.Extent.StartLineNumber
            if ($ln -ge 1 -and $ln -le $lines.Count -and $lines[$ln - 1].Contains($script:FIXTURE_PRAGMA)) { continue }
            $k = '{0}:{1}:{2}' -f $ln, $lit.Ast.Extent.StartColumnNumber, $s.Site.Extent.StartLineNumber
            if ($seen.ContainsKey($k)) { continue }
            $seen[$k] = $true
            [void]$findings.Add([pscustomobject]@{
                    Path     = $Path
                    Line     = $ln
                    Col      = $lit.Ast.Extent.StartColumnNumber
                    Literal  = $lit.Value
                    Segment  = $hz.Segment
                    Hazard   = $hz.Hazard
                    SiteLine = $s.Site.Extent.StartLineNumber
                    SiteText = ($s.Site.Extent.Text -split "`r?`n")[0].Trim()
                })
        }
    }
    return @($findings)
}

function Get-FixtureScanFiles([string]$Repo) {
    $root = Join-Path $Repo 'test\win32'
    # -Include is filtered afterwards: with -LiteralPath and -Recurse it is
    # silently ignored (the vt-escape-scan lesson).
    return @(Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -eq '.ps1' -or $_.Extension -eq '.psm1' } |
            Where-Object { $_.FullName -notmatch '\\temp\\' } |
            ForEach-Object { $_.FullName })
}
