# ClickCoordAudit (T1032) - find the harness clicks whose point carries no
# evidence of being in SCREEN coordinates.
#
# THE DEFECT. Send-TestMouse takes a SCREEN point and converts it to the
# target's client space itself (T263). A caller that hands it a CLIENT point -
# an offset measured from the window's own corner - lands the click one client
# origin up and to the left of where it aimed, usually outside the control. The
# post succeeds, the helper returns $true, and the assertion after it fails
# against a feature that works. T318 paid exactly that: `-X $geo.KillX`, a
# client offset, and a Kill button that "opened nothing" because the click
# never reached it. T327 audited every site by hand and found them correct;
# this is the ratchet that keeps them that way, because the suite gains click
# sites constantly and the failure is silent at the point it is made.
#
# THE RULE. Every -X / -Y argument to a sink (Send-TestMouse, and
# Get-TestMouseRoute, which answers for the same screen point) must show screen
# EVIDENCE: somewhere in the expression, or in what it resolves to, there is
#
#   * a rect origin - a member named Left / Top / Right / Bottom of a RECT
#     (every window rect the harness hands out is screen-space,
#     Get-TestWindowRect -Client included). Not of a geometry object that a
#     literal in its derivation builds with its own `Left = ...`: that is a
#     layout restatement, Get-TestChooserRosterGeometry's is client-space,
#     and its values must show the screen themselves;
#   * a call to a screen PRODUCER - Get-TestWindowRect, Get-TestPixel, a
#     Find-/Test-*Pixel probe, anything named *ToScreen* - or to a function
#     (same file or lib\) whose body shows that evidence itself;
#   * a variable the caller DECLARED screen-space (-ScreenVars), for the one
#     shape no analyzer can see through: a point parsed out of the app's own
#     log text. Each declaration carries its reason in the acceptance script.
#
# Resolution follows the value, not the spelling:
#
#   $x            the assignments to $x in the scope of the use, then each
#                 lexically enclosing function, then the script (`$script:x`
#                 is the script's); a foreach / for variable counts. ANY
#                 evidence-bearing source is enough - this is reachability.
#   $p.X  $p[0]   a coordinate member or an index reads through to $p
#   $m.ClientLeft any OTHER member reads through only to a hashtable or
#                 [pscustomobject] literal that defines that key - in $m's own
#                 derivation, or in the body of the function (same file or
#                 lib\) that built it. A member with no visible definition is
#                 OPAQUE and carries nothing: that is precisely the T318 shape,
#                 `-X $geo.KillX` with KillX a client offset.
#
# WRAPPERS. Half the suite clicks through a local helper whose point arrives as
# a PARAMETER (`Open-TabMenu $gpid $top $x $y`, `Invoke-DividerDrag -X0 ...`).
# A coordinate that resolves to a parameter of the enclosing function makes
# that function a sink in its own right, for that parameter, and its CALLERS
# are audited the same way - to a fixpoint, so a wrapper of a wrapper works.
# Wrappers defined in lib\ are sinks in every file (Get-ClickCoordLibContext).
# A parameter of a bare scriptblock (`$click = { param($x) ... }`) has no name
# to find callers by; that is kind `block-param`, informational.
#
# EXEMPT BY NAME: Send-TestClickStorm. Its -X/-Y are CLIENT coordinates on
# purpose - one point posted to many different windows has no single screen
# point inside all of them (TestDesktop.ps1 documents it). It is not a sink;
# Get-ClickCoordExemptSinks names it so the acceptance asserts the exemption
# rather than leaving it implicit.
#
# KINDS: `no-evidence` (hard - fails the sweep), `parse-error` (hard),
# `block-param` (informational). EXEMPTION: `# click-coord: <reason>` on the
# call's line or the line above; a marker with no reason exempts nothing.

Set-StrictMode -Off

$script:CLICK_ORIGIN_MEMBERS = @('left', 'top', 'right', 'bottom')
$script:CLICK_READTHROUGH_MEMBERS = @('x', 'y')
# The harness's own screen producers, by name. Most of them build their rect
# from the native helper's TEXT or ARRAY answer (`Left = [int]$c[0]`), which no
# static reading can see is screen-space - so they are named here, each with
# the reason, and the acceptance fails if one of them stops existing.
$script:CLICK_NAMED_PRODUCERS = [ordered]@{
    'Get-TestWindowRect'       = 'GetWindowRect / the client rect mapped to the screen (-Client)'
    'Get-TestWindowNormalRect' = 'the restored rect, in screen coordinates'
    'Get-TestWindows'          = 'top-level GetWindowRect, parsed from the helper''s text'
    'Get-TestChildWindows'     = 'child GetWindowRect, parsed from the helper''s text'
    'Get-TestWorkArea'         = 'the test desktop''s work area, in screen coordinates'
    'Get-TestPixel'            = 'a capture probe; captures are screen-space'
}
$script:CLICK_PRODUCER_PATTERN = '(?i)^(' + (($script:CLICK_NAMED_PRODUCERS.Keys | ForEach-Object { [regex]::Escape($_) }) -join '|') +
'|Find-\w*Pixel\w*|Test-\w*Pixel\w*|\S*To-?Screen\S*)$'

function Get-ClickCoordNamedProducers { return $script:CLICK_NAMED_PRODUCERS }
$script:CLICK_SCRIPT_SCOPE = '<script>'

function Get-ClickCoordExemptSinks { return @('Send-TestClickStorm') }

# The built-in sink: Send-TestMouse, with its declared parameter order (an
# advanced function binds positionally in declaration order) and its switches.
function Get-ClickCoordBuiltinSinks {
    return @{
        'send-testmouse' = [pscustomobject]@{
            Name     = 'Send-TestMouse'
            Params   = @('Window', 'Target', 'X', 'Y', 'Button', 'Action', 'Modifiers', 'HoldMs', 'Delta', 'Client', 'Desktop')
            Switches = @('Client')
            Coords   = @('X', 'Y')
        }
        # The routing Send-TestMouse WOULD use at a point: the same screen
        # convention, so the same mistake asserts a hit code nowhere near the
        # control it names.
        'get-testmouseroute' = [pscustomobject]@{
            Name     = 'Get-TestMouseRoute'
            Params   = @('Window', 'Target', 'X', 'Y', 'Desktop')
            Switches = @()
            Coords   = @('X', 'Y')
        }
    }
}

function Get-ClickCoordRelativePath([string]$Path, [string]$Repo) {
    $full = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetFullPath($Repo).TrimEnd('\') + '\'
    if ($full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $full.Substring($root.Length)
    }
    return $Path
}

function Test-ClickCoordExempt($Lines, [int]$LineNumber) {
    foreach ($n in @($LineNumber, ($LineNumber - 1))) {
        if ($n -lt 1 -or $n -gt $Lines.Count) { continue }
        if ($Lines[$n - 1] -match '#\s*click-coord:\s*\S') { return $true }
    }
    return $false
}

# '$script:x' -> @{ Name = 'x'; Script = $true }; '$x' -> @{ Name = 'x'; Script = $false }
function Get-ClickVarName($VarAst) {
    $n = $VarAst.VariablePath.UserPath
    $isScript = $false
    if ($n -match '^(script|global):(.+)$') { $n = $Matches[2]; $isScript = $true }
    elseif ($n -match '^(local|private):(.+)$') { $n = $Matches[2] }
    return [pscustomobject]@{ Name = $n.ToLowerInvariant(); Script = $isScript }
}

function Get-ClickEnclosingFunction($Node) {
    $p = $Node.Parent
    while ($null -ne $p) {
        if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst]) { return $p }
        $p = $p.Parent
    }
    return $null
}

function Get-ClickScopeKey($Fn) {
    if ($null -eq $Fn) { return $script:CLICK_SCRIPT_SCOPE }
    return "$($Fn.Name.ToLowerInvariant())@$($Fn.Extent.StartOffset)"
}

# The scopes a use can read, innermost first: its function, each lexically
# enclosing function, then the script.
function Get-ClickScopeChain($Node) {
    $chain = New-Object System.Collections.ArrayList
    $fn = Get-ClickEnclosingFunction $Node
    while ($null -ne $fn) {
        [void]$chain.Add((Get-ClickScopeKey $fn))
        $fn = Get-ClickEnclosingFunction $fn
    }
    [void]$chain.Add($script:CLICK_SCRIPT_SCOPE)
    return , $chain.ToArray()
}

# Parameter list of a function definition: inline `function F($a, $b)` or a
# param() block, in declaration order, with switches marked.
function Get-ClickFunctionParams($Fn) {
    $ps = @()
    if ($Fn.Parameters) { $ps = @($Fn.Parameters) }
    elseif ($Fn.Body.ParamBlock) { $ps = @($Fn.Body.ParamBlock.Parameters) }
    $names = New-Object System.Collections.ArrayList
    $switches = New-Object System.Collections.ArrayList
    foreach ($p in $ps) {
        $nm = $p.Name.VariablePath.UserPath
        [void]$names.Add($nm)
        foreach ($a in @($p.Attributes)) {
            if ($a -is [System.Management.Automation.Language.TypeConstraintAst] -and
                $a.TypeName.FullName -imatch '^(switch|System\.Management\.Automation\.SwitchParameter)$') { [void]$switches.Add($nm) }
        }
    }
    return [pscustomobject]@{ Names = $names.ToArray(); Switches = $switches.ToArray() }
}

# Bind a command's arguments to a parameter list the way PowerShell would for
# the cases the suite uses: named (`-X 5`, `-X:5`, unique prefix), switches,
# then positional in declaration order. Returns name(lower) -> argument AST.
function Get-ClickBoundArgs($Cmd, $ParamNames, $Switches) {
    $bound = @{}
    $positional = New-Object System.Collections.ArrayList
    $els = @($Cmd.CommandElements)
    $i = 1
    while ($i -lt $els.Count) {
        $el = $els[$i]
        if ($el -is [System.Management.Automation.Language.CommandParameterAst]) {
            $pn = $el.ParameterName
            $match = @($ParamNames | Where-Object { $_ -ieq $pn })
            if ($match.Count -eq 0) { $match = @($ParamNames | Where-Object { $_.StartsWith($pn, [System.StringComparison]::OrdinalIgnoreCase) }) }
            $name = $null
            if ($match.Count -eq 1) { $name = $match[0] }
            $isSwitch = ($null -ne $name -and @($Switches | Where-Object { $_ -ieq $name }).Count -gt 0)
            if ($el.Argument) {
                if ($name) { $bound[$name.ToLowerInvariant()] = $el.Argument }
                $i++; continue
            }
            if ($isSwitch) { $i++; continue }
            if ($i + 1 -lt $els.Count -and -not ($els[$i + 1] -is [System.Management.Automation.Language.CommandParameterAst])) {
                if ($name) { $bound[$name.ToLowerInvariant()] = $els[$i + 1] }
                $i += 2; continue
            }
            $i++; continue
        }
        if (-not ($el -is [System.Management.Automation.Language.VariableExpressionAst] -and $el.Splatted)) { [void]$positional.Add($el) }
        $i++
    }
    $k = 0
    foreach ($pn in $ParamNames) {
        if ($k -ge $positional.Count) { break }
        if ($bound.ContainsKey($pn.ToLowerInvariant())) { continue }
        if (@($Switches | Where-Object { $_ -ieq $pn }).Count -gt 0) { continue }
        $bound[$pn.ToLowerInvariant()] = $positional[$k]
        $k++
    }
    return $bound
}

# Per-file index: scoped assignments, functions, calls.
function New-ClickFileIndex($Ast, [string[]]$ScreenVars = @()) {
    $assign = @{}
    $add = {
        param($scope, $name, $rhs)
        $key = "$scope|$name"
        if (-not $assign.ContainsKey($key)) { $assign[$key] = New-Object System.Collections.ArrayList }
        [void]$assign[$key].Add($rhs)
    }
    foreach ($a in $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
        $targets = @($a.Left)
        if ($a.Left -is [System.Management.Automation.Language.ArrayLiteralAst]) { $targets = @($a.Left.Elements) }
        foreach ($t in $targets) {
            while ($t -is [System.Management.Automation.Language.AttributedExpressionAst]) { $t = $t.Child }
            if ($t -is [System.Management.Automation.Language.VariableExpressionAst]) {
                $v = Get-ClickVarName $t
                $scope = $script:CLICK_SCRIPT_SCOPE
                if (-not $v.Script) { $scope = Get-ClickScopeKey (Get-ClickEnclosingFunction $a) }
                & $add $scope $v.Name $a.Right
            }
        }
    }
    foreach ($f in $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ForEachStatementAst] }, $true)) {
        & $add (Get-ClickScopeKey (Get-ClickEnclosingFunction $f)) (Get-ClickVarName $f.Variable).Name $f.Condition
    }
    $fns = @{}
    foreach ($f in $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        $fns[$f.Name.ToLowerInvariant()] = $f
    }
    $calls = @{}
    foreach ($c in $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $nm = $c.GetCommandName()
        if (-not $nm) { continue }
        $k = $nm.ToLowerInvariant()
        if (-not $calls.ContainsKey($k)) { $calls[$k] = New-Object System.Collections.ArrayList }
        [void]$calls[$k].Add($c)
    }
    $sv = @{}
    foreach ($n in $ScreenVars) { $sv[$n.ToLowerInvariant()] = $true }
    return [pscustomobject]@{ Assign = $assign; Functions = $fns; Calls = $calls; BodyEvidence = @{}; ScreenVars = $sv; ScreenVarHits = @{} }
}

# Is this body screen-derived on its face - a rect origin, or a producer call?
function Test-ClickBodyHasEvidence($Body, $Ctx) {
    $hit = $Body.Find({
            param($n)
            ($n -is [System.Management.Automation.Language.MemberExpressionAst] -and
                $script:CLICK_ORIGIN_MEMBERS -contains $n.Member.Extent.Text.ToLowerInvariant()) -or
            ($n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -and
                ($n.GetCommandName() -match $script:CLICK_PRODUCER_PATTERN -or
                ($Ctx.Producers.ContainsKey($n.GetCommandName().ToLowerInvariant()))))
        }, $true)
    return ($null -ne $hit)
}

function Test-ClickFunctionEvidence($Index, $Fn, $Ctx) {
    $key = $Fn.Name.ToLowerInvariant()
    if ($Index.BodyEvidence.ContainsKey($key)) { return $Index.BodyEvidence[$key] }
    $Index.BodyEvidence[$key] = $false   # cycle guard
    $Index.BodyEvidence[$key] = (Test-ClickBodyHasEvidence $Fn.Body $Ctx)
    return $Index.BodyEvidence[$key]
}

# The enclosing parameter a variable use refers to, if any: walk outward to
# the nearest function or scriptblock that declares it.
function Find-ClickParamOwner($VarAst) {
    $name = (Get-ClickVarName $VarAst).Name
    $node = $VarAst.Parent
    while ($null -ne $node) {
        if ($node -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
            $pp = Get-ClickFunctionParams $node
            if (@($pp.Names | Where-Object { $_ -ieq $name }).Count -gt 0) {
                return [pscustomobject]@{ Function = $node; Param = $name }
            }
        }
        elseif ($node -is [System.Management.Automation.Language.ScriptBlockAst] -and $node.ParamBlock -and
            -not ($node.Parent -is [System.Management.Automation.Language.FunctionDefinitionAst])) {
            foreach ($p in @($node.ParamBlock.Parameters)) {
                if ($p.Name.VariablePath.UserPath -ieq $name) { return [pscustomobject]@{ Function = $null; Param = $name } }
            }
        }
        $node = $node.Parent
    }
    return $null
}

# The right-hand sides a variable use can see, innermost scope first.
function Get-ClickVarSources($Index, $VarAst) {
    $v = Get-ClickVarName $VarAst
    $chain = @($script:CLICK_SCRIPT_SCOPE)
    if (-not $v.Script) { $chain = Get-ClickScopeChain $VarAst }
    $out = New-Object System.Collections.ArrayList
    foreach ($s in $chain) {
        $k = "$s|$($v.Name)"
        if ($Index.Assign.ContainsKey($k)) { foreach ($r in $Index.Assign[$k]) { [void]$out.Add([pscustomobject]@{ Key = $k; Rhs = $r }) } }
    }
    return , $out.ToArray()
}

# Found: a keyed lookup met a literal that defines the key (Get-ClickKeyedEvidence).
function New-ClickResult { return [pscustomobject]@{ Ok = $false; Params = (New-Object System.Collections.ArrayList); Block = $false; Found = $false } }
function Join-ClickResult($Into, $From) {
    if ($From.Ok) { $Into.Ok = $true }
    if ($From.Found) { $Into.Found = $true }
    if ($From.Block) { $Into.Block = $true }
    foreach ($p in $From.Params) { if (-not $Into.Params.Contains($p)) { [void]$Into.Params.Add($p) } }
}

# Find the value a hashtable / [pscustomobject] literal gives KEY, anywhere in
# the derivation of BASE: its own subtree, the variables it is, and the bodies
# of the functions (this file or lib\) it calls. Evidence of any such value.
function Get-ClickKeyedEvidence($Index, $Base, [string]$Key, $Ctx, $Visited) {
    $r = New-ClickResult
    if ($null -eq $Base) { return $r }
    if ($Base -is [System.Management.Automation.Language.VariableExpressionAst]) {
        foreach ($src in (Get-ClickVarSources $Index $Base)) {
            $vk = "key:$($src.Key)|$Key"
            if ($Visited.ContainsKey($vk)) { continue }
            $Visited[$vk] = $true
            Join-ClickResult $r (Get-ClickKeyedEvidence $Index $src.Rhs $Key $Ctx $Visited)
            if ($r.Ok) { return $r }
        }
        return $r
    }
    $tables = @($Base.FindAll({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true))
    foreach ($h in $tables) {
        foreach ($kv in $h.KeyValuePairs) {
            if ($kv.Item1.Extent.Text.Trim("'`"") -ieq $Key) {
                $r.Found = $true
                Join-ClickResult $r (Get-ClickEvidence $Index $kv.Item2 $Ctx $Visited)
                if ($r.Ok) { return $r }
            }
        }
    }
    foreach ($c in @($Base.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))) {
        $nm = $c.GetCommandName()
        if (-not $nm) { continue }
        if ($nm -match $script:CLICK_PRODUCER_PATTERN) { $r.Found = $true; $r.Ok = $true; return $r }
        $k = $nm.ToLowerInvariant()
        $fnIndex = $null; $fn = $null
        if ($Index.Functions.ContainsKey($k)) { $fnIndex = $Index; $fn = $Index.Functions[$k] }
        elseif ($Ctx.LibFunctions.ContainsKey($k)) { $fnIndex = $Ctx.LibFunctions[$k].Index; $fn = $Ctx.LibFunctions[$k].Function }
        if ($null -eq $fn) { continue }
        $vk = "fnkey:${k}:$Key"
        if ($Visited.ContainsKey($vk)) { continue }
        $Visited[$vk] = $true
        $sub = Get-ClickKeyedEvidence $fnIndex $fn.Body $Key $Ctx $Visited
        # A wrapper parameter of ANOTHER function is not this call's to forward.
        if ($sub.Found) { $r.Found = $true }
        if ($sub.Ok) { $r.Ok = $true; return $r }
    }
    if ($Base -is [System.Management.Automation.Language.ParenExpressionAst] -or
        $Base -is [System.Management.Automation.Language.PipelineAst] -or
        $Base -is [System.Management.Automation.Language.CommandExpressionAst]) {
        foreach ($v in @($Base.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true))) {
            if ($v.Parent -is [System.Management.Automation.Language.MemberExpressionAst] -and $v.Parent.Expression -eq $v) {
                Join-ClickResult $r (Get-ClickKeyedEvidence $Index $v $Key $Ctx $Visited)
                if ($r.Ok) { return $r }
            }
        }
    }
    return $r
}

# Evidence of an expression. Returns { Ok; Params; Block } where Params lists
# the "function|param" keys the value flows from (wrapper candidates) and
# Block says it flows from a bare scriptblock's parameter.
function Get-ClickEvidence($Index, $Node, $Ctx, $Visited) {
    $r = New-ClickResult
    if ($null -eq $Node) { return $r }
    # A method call before a member access: InvokeMemberExpressionAst IS a
    # MemberExpressionAst, and `[Math]::Max($a, $b)` is not a member named Max.
    if ($Node -is [System.Management.Automation.Language.InvokeMemberExpressionAst]) {
        foreach ($a in @($Node.Arguments)) {
            Join-ClickResult $r (Get-ClickEvidence $Index $a $Ctx $Visited)
            if ($r.Ok) { return $r }
        }
        if (-not $Node.Static) { Join-ClickResult $r (Get-ClickEvidence $Index $Node.Expression $Ctx $Visited) }
        return $r
    }
    if ($Node -is [System.Management.Automation.Language.MemberExpressionAst]) {
        $m = $Node.Member.Extent.Text.Trim("'`"").ToLowerInvariant()
        if ($script:CLICK_ORIGIN_MEMBERS -contains $m) {
            # A rect's Left is evidence - unless a literal in its derivation
            # DEFINES Left, which makes it a geometry object, not a rect, and
            # its own numbers have to show the screen. The chooser roster
            # geometry (ChromeGeometry.ps1) is exactly that: Left/Top/Right/
            # Bottom in CLIENT space, beside the KillX that cost T318.
            $kd = Get-ClickKeyedEvidence $Index $Node.Expression $m $Ctx $Visited
            if (-not $kd.Found -or $kd.Ok) { $r.Ok = $true; return $r }
            Join-ClickResult $r (Get-ClickEvidence $Index $Node.Expression $Ctx $Visited)
            return $r
        }
        if ($script:CLICK_READTHROUGH_MEMBERS -contains $m) {
            Join-ClickResult $r (Get-ClickEvidence $Index $Node.Expression $Ctx $Visited)
            if ($r.Ok) { return $r }
        }
        # Any other member reads through only to a literal that defines it.
        Join-ClickResult $r (Get-ClickKeyedEvidence $Index $Node.Expression $m $Ctx $Visited)
        return $r
    }
    if ($Node -is [System.Management.Automation.Language.IndexExpressionAst]) {
        Join-ClickResult $r (Get-ClickEvidence $Index $Node.Target $Ctx $Visited)
        return $r
    }
    if ($Node -is [System.Management.Automation.Language.VariableExpressionAst]) {
        $v = Get-ClickVarName $Node
        if ($Index.ScreenVars.ContainsKey($v.Name)) {
            $Index.ScreenVarHits[$v.Name] = $true
            $r.Ok = $true; return $r
        }
        if ($v.Name -eq '_' -or $v.Name -eq 'psitem') {
            # A pipeline item: read through to what the pipeline enumerates.
            $pipe = $Node.Parent
            while ($null -ne $pipe -and -not ($pipe -is [System.Management.Automation.Language.PipelineAst])) { $pipe = $pipe.Parent }
            if ($pipe -and @($pipe.PipelineElements).Count -gt 1) {
                Join-ClickResult $r (Get-ClickEvidence $Index $pipe.PipelineElements[0] $Ctx $Visited)
            }
            return $r
        }
        $owner = Find-ClickParamOwner $Node
        if ($owner) {
            if ($null -eq $owner.Function) { $r.Block = $true }
            else { [void]$r.Params.Add("$($owner.Function.Name.ToLowerInvariant())|$($owner.Param)") }
        }
        foreach ($src in (Get-ClickVarSources $Index $Node)) {
            if ($Visited.ContainsKey($src.Key)) { continue }
            $Visited[$src.Key] = $true
            foreach ($rhs in @($Index.Assign[$src.Key])) {
                Join-ClickResult $r (Get-ClickEvidence $Index $rhs $Ctx $Visited)
                if ($r.Ok) { return $r }
            }
        }
        return $r
    }
    if ($Node -is [System.Management.Automation.Language.CommandAst]) {
        $nm = $Node.GetCommandName()
        if ($nm) {
            if ($nm -match $script:CLICK_PRODUCER_PATTERN) { $r.Ok = $true; return $r }
            $k = $nm.ToLowerInvariant()
            if ($Ctx.Producers.ContainsKey($k)) { $r.Ok = $true; return $r }
            if ($Index.Functions.ContainsKey($k)) {
                if (Test-ClickFunctionEvidence $Index $Index.Functions[$k] $Ctx) { $r.Ok = $true }
                return $r
            }
        }
        else {
            # `& $block ...`: the evidence is in the scriptblock it invokes.
            $head = $Node.CommandElements[0]
            if ($head -is [System.Management.Automation.Language.VariableExpressionAst]) {
                foreach ($src in (Get-ClickVarSources $Index $head)) {
                    if ($src.Rhs.Find({ param($n) $n -is [System.Management.Automation.Language.ScriptBlockExpressionAst] }, $true) -and
                        (Test-ClickBodyHasEvidence $src.Rhs $Ctx)) { $r.Ok = $true; return $r }
                }
            }
        }
        # An unknown command (a cmdlet, an external helper): its arguments are
        # the only visible derivation.
        foreach ($el in @($Node.CommandElements | Select-Object -Skip 1)) {
            Join-ClickResult $r (Get-ClickEvidence $Index $el $Ctx $Visited)
            if ($r.Ok) { return $r }
        }
        return $r
    }
    if ($Node -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) { return $r }
    # Everything else (binary ops, parens, casts, sub-expressions, arrays,
    # pipelines, hashtables): evidence anywhere among the direct children.
    foreach ($kid in @($Node.FindAll({ param($n) $n.Parent -eq $Node }, $false))) {
        Join-ClickResult $r (Get-ClickEvidence $Index $kid $Ctx $Visited)
        if ($r.Ok) { return $r }
    }
    return $r
}

# Discover the wrappers a file defines, to a fixpoint, given the sinks already
# known (built-in + lib). Returns the extended sink table.
function Get-ClickSinkTable($Index, $Sinks, $Ctx) {
    $table = @{}
    foreach ($k in $Sinks.Keys) { $table[$k] = $Sinks[$k] }
    $changed = $true
    while ($changed) {
        $changed = $false
        foreach ($sk in @($table.Keys)) {
            if (-not $Index.Calls.ContainsKey($sk)) { continue }
            $sink = $table[$sk]
            foreach ($c in $Index.Calls[$sk]) {
                $bound = Get-ClickBoundArgs $c $sink.Params $sink.Switches
                foreach ($coord in $sink.Coords) {
                    $arg = $bound[$coord.ToLowerInvariant()]
                    if ($null -eq $arg) { continue }
                    $ev = Get-ClickEvidence $Index $arg $Ctx @{}
                    if ($ev.Ok) { continue }
                    foreach ($fp in $ev.Params) {
                        $fname, $pname = $fp.Split('|')
                        if (-not $Index.Functions.ContainsKey($fname)) { continue }
                        if (-not $table.ContainsKey($fname)) {
                            $fn = $Index.Functions[$fname]
                            $pp = Get-ClickFunctionParams $fn
                            $table[$fname] = [pscustomobject]@{ Name = $fn.Name; Params = $pp.Names; Switches = $pp.Switches; Coords = @() }
                            $changed = $true
                        }
                        $w = $table[$fname]
                        $canon = @($w.Params | Where-Object { $_ -ieq $pname })[0]
                        if ($canon -and @($w.Coords | Where-Object { $_ -ieq $canon }).Count -eq 0) {
                            $w.Coords = @($w.Coords) + $canon
                            $changed = $true
                        }
                    }
                }
            }
        }
    }
    return $table
}

function New-ClickCoordContext { return [pscustomobject]@{ Sinks = @{}; Producers = @{}; LibFunctions = @{} } }

function Get-ClickCoordFindings {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowNull()][AllowEmptyString()][string[]]$Text,
        # What lib\ contributes (Get-ClickCoordLibContext); a fixture may omit it.
        $Context,
        # Variables this file DECLARES screen-space, by bare name (no `$`).
        [string[]]$ScreenVars = @(),
        # Filled with the ScreenVars that actually decided a site, so the
        # acceptance can fail a declaration nothing needs any more.
        [hashtable]$ScreenVarHits
    )
    if ($null -eq $Context) { $Context = New-ClickCoordContext }
    $lines = @($Text)
    $script:ClickCoordLastSites = 0
    $script:ClickCoordLastWrappers = @()
    $sinks = Get-ClickCoordBuiltinSinks
    foreach ($k in $Context.Sinks.Keys) { $sinks[$k] = $Context.Sinks[$k] }
    # A file that never names a sink has no site: every local wrapper is born
    # from a sink call, so there is nothing to parse. Most of the suite.
    $joined = $lines -join "`n"
    $named = $false
    foreach ($s in $sinks.Values) { if ($joined.IndexOf($s.Name, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $named = $true; break } }
    if (-not $named) { return , @() }
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($joined, [ref]$tokens, [ref]$errors)
    $out = New-Object System.Collections.ArrayList
    if (@($errors).Count -gt 0) {
        [void]$out.Add([pscustomobject]@{ Path = $Path; Line = $errors[0].Extent.StartLineNumber; Kind = 'parse-error'; Sink = ''; Param = ''; Detail = $errors[0].Message })
        return , $out.ToArray()
    }
    $index = New-ClickFileIndex $ast $ScreenVars
    $table = Get-ClickSinkTable $index $sinks $Context
    $sites = 0
    foreach ($sk in $table.Keys) {
        if (-not $index.Calls.ContainsKey($sk)) { continue }
        $sink = $table[$sk]
        foreach ($c in $index.Calls[$sk]) {
            $bound = Get-ClickBoundArgs $c $sink.Params $sink.Switches
            foreach ($coord in $sink.Coords) {
                $arg = $bound[$coord.ToLowerInvariant()]
                if ($null -eq $arg) { continue }
                $sites++
                $ev = Get-ClickEvidence $index $arg $Context @{}
                if ($ev.Ok) { continue }
                $forwarded = $false
                foreach ($fp in $ev.Params) {
                    $fname, $pname = $fp.Split('|')
                    if ($table.ContainsKey($fname) -and @($table[$fname].Coords | Where-Object { $_ -ieq $pname }).Count -gt 0) { $forwarded = $true }
                }
                if ($forwarded) { continue }
                $ln = $c.Extent.StartLineNumber
                if (Test-ClickCoordExempt $lines $ln) { continue }
                $kind = 'no-evidence'
                if ($ev.Block) { $kind = 'block-param' }
                [void]$out.Add([pscustomobject]@{
                        Path = $Path; Line = $ln; Kind = $kind; Sink = $sink.Name; Param = $coord
                        Detail = "$($sink.Name) -$coord $($arg.Extent.Text)"
                    })
            }
        }
    }
    if ($null -ne $ScreenVarHits) { foreach ($k in $index.ScreenVarHits.Keys) { $ScreenVarHits[$k] = $true } }
    $script:ClickCoordLastSites = $sites
    $script:ClickCoordLastWrappers = @($table.Keys | Where-Object { -not $sinks.ContainsKey($_) } | ForEach-Object { $table[$_].Name })
    return , @($out.ToArray() | Sort-Object Line, Param)
}

function Get-ClickCoordHardKinds { return @('no-evidence', 'parse-error') }

# What lib\ contributes to every other file: the wrappers it defines (a lib
# function forwarding a parameter into a sink), the producers (a lib function
# whose body is screen-derived on its face, e.g. a rect or probe helper), and
# every lib function body, so `$m.ClientLeft` can read through to the
# `ClientLeft = $cr.Left` that Get-TestChromeMetrics builds.
function Get-ClickCoordLibContext {
    param([Parameter(Mandatory = $true)][string]$LibRoot)
    $ctx = New-ClickCoordContext
    $indexes = New-Object System.Collections.ArrayList
    foreach ($f in @(Get-ChildItem -LiteralPath $LibRoot -Filter *.ps1 -File)) {
        $t = $null; $e = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$t, [ref]$e)
        $ix = New-ClickFileIndex $ast
        [void]$indexes.Add($ix)
        foreach ($k in $ix.Functions.Keys) {
            $ctx.LibFunctions[$k] = [pscustomobject]@{ Index = $ix; Function = $ix.Functions[$k] }
        }
    }
    $exempt = @(Get-ClickCoordExemptSinks | ForEach-Object { $_.ToLowerInvariant() })
    foreach ($ix in $indexes) {
        foreach ($k in $ix.Functions.Keys) {
            if ($exempt -contains $k) { continue }
            if (Test-ClickBodyHasEvidence $ix.Functions[$k].Body $ctx) { $ctx.Producers[$k] = $true }
        }
    }
    $builtin = Get-ClickCoordBuiltinSinks
    foreach ($ix in $indexes) {
        $table = Get-ClickSinkTable $ix $builtin $ctx
        foreach ($k in $table.Keys) {
            if ($builtin.ContainsKey($k)) { continue }
            $ctx.Sinks[$k] = $table[$k]
            # A wrapper's body mentions a rect too; it is a sink, not a source.
            $ctx.Producers.Remove($k)
        }
    }
    return $ctx
}

function Get-ClickCoordSweep {
    param(
        [Parameter(Mandatory = $true)][string[]]$Roots,
        [Parameter(Mandatory = $true)]$Context,
        # relative-path -> string[] of declared screen variables
        [hashtable]$ScreenVars = @{},
        [string]$Repo,
        # Filled with "relpath|var" for every declaration that decided a site.
        [hashtable]$ScreenVarHits
    )
    $all = New-Object System.Collections.ArrayList
    $sites = 0
    $wrappers = New-Object System.Collections.ArrayList
    $files = New-Object System.Collections.ArrayList
    foreach ($r in $Roots) {
        if (Test-Path -LiteralPath $r -PathType Leaf) { [void]$files.Add((Get-Item -LiteralPath $r)) }
        else { foreach ($f in @(Get-ChildItem -LiteralPath $r -Filter *.ps1 -File -Recurse)) { [void]$files.Add($f) } }
    }
    foreach ($file in $files) {
        $rel = $file.FullName
        if ($Repo) { $rel = Get-ClickCoordRelativePath -Path $file.FullName -Repo $Repo }
        $sv = @()
        if ($ScreenVars.ContainsKey($rel)) { $sv = @($ScreenVars[$rel]) }
        $hits = @{}
        $text = [System.IO.File]::ReadAllLines($file.FullName)
        foreach ($x in (Get-ClickCoordFindings -Path $file.FullName -Text $text -Context $Context -ScreenVars $sv -ScreenVarHits $hits)) { [void]$all.Add($x) }
        $sites += $script:ClickCoordLastSites
        foreach ($w in @($script:ClickCoordLastWrappers)) { [void]$wrappers.Add("$rel|$w") }
        if ($null -ne $ScreenVarHits) { foreach ($k in $hits.Keys) { $ScreenVarHits["$rel|$k"] = $true } }
    }
    # What the sweep read, for the acceptance's scope assertions.
    $script:ClickCoordSweepSites = $sites
    $script:ClickCoordSweepFiles = $files.Count
    $script:ClickCoordSweepWrappers = $wrappers.ToArray()
    return , $all.ToArray()
}
