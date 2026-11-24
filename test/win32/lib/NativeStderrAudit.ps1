# NativeStderrAudit (T2176) - find the native calls whose redirected stderr can
# end the script under `$ErrorActionPreference = 'Stop'`.
#
# THE DEFECT (T1215): under `Stop`, Windows PowerShell 5.1 makes ANY stderr
# line from a native call with its stderr redirected (`2>$null`, `2>&1`,
# `*>...`) a terminating NativeCommandError. The ghoztty CLI prints "Waiting for
# Ghoztty to answer ..." on stderr whenever the app is slow to answer, on its
# way to succeeding - so a slow box ends the run with no verdict, past its
# cleanup. soak.ps1 died that way after every assertion had passed. The fix is
# `Invoke-Tolerant { ... }` from lib\NativeTolerant.ps1, which runs the call
# under `Continue` and leaves the caller's `Stop` in force.
#
# A FINDING is a command that
#   * calls the app or another native exe: `& $var ...` where $var names an
#     exe (its name ends in `exe`, or is exe/ghz/ghoztty/cli, or the file
#     assigns it from text naming a .exe/.com), or a bare `ghoztty` /
#     `ghoztty.exe` / `ghoztty.com` command;
#   * redirects its error stream (`2>`, `2>&1`, `*>`);
#   * and runs under `Stop`: the nearest enclosing script block (function
#     body, the file itself, ...) that assigns $ErrorActionPreference before
#     the call assigns it 'Stop'. A block with no assignment inherits from the
#     one around it; a file with none at all runs under the default Continue.
#
# NOT a finding: a call inside the script block handed to `Invoke-Tolerant`
# (it runs under Continue whatever surrounds it), and a call carrying
# `# native-stderr: <reason>` on its line or the line above (a marker with no
# reason exempts nothing). Library files with no assignment of their own are
# judged as Continue - what their CALLER runs under is not visible here.
#
# KINDS: `redirect` (hard - feeds the ratchet) and `parse-error`, held at zero.
# The sites present when this landed are a per-file count in
# native-stderr-audit.baseline.json, so recording them did not edit (and
# re-due) the harnesses that own them. A file ABOVE its count fails.

Set-StrictMode -Off

function Get-NativeStderrRelativePath([string]$Path, [string]$Repo) {
    $full = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetFullPath($Repo).TrimEnd('\') + '\'
    if ($full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $full.Substring($root.Length)
    }
    return $Path
}

function Test-NativeStderrExempt($Lines, [int]$LineNumber) {
    foreach ($n in @($LineNumber, ($LineNumber - 1))) {
        if ($n -lt 1 -or $n -gt $Lines.Count) { continue }
        if ($Lines[$n - 1] -match '#\s*native-stderr:\s*\S') { return $true }
    }
    return $false
}

function Get-NativeStderrVarName($VarAst) {
    $name = $VarAst.VariablePath.UserPath
    if ($name -match ':') { $name = ($name -split ':', 2)[1] }
    return $name
}

# The innermost ScriptBlockAst that contains $Ast (itself excluded).
function Get-NativeStderrBlock($Ast) {
    $p = $Ast.Parent
    while ($p -and -not ($p -is [System.Management.Automation.Language.ScriptBlockAst])) { $p = $p.Parent }
    return $p
}

# Is this script block the body handed to Invoke-Tolerant?
function Test-NativeStderrTolerantBlock($Block) {
    $sbe = $Block.Parent
    if (-not ($sbe -is [System.Management.Automation.Language.ScriptBlockExpressionAst])) { return $false }
    $cmd = $sbe.Parent
    if (-not ($cmd -is [System.Management.Automation.Language.CommandAst])) { return $false }
    return ($cmd.GetCommandName() -eq 'Invoke-Tolerant')
}

# 'Stop', 'Continue' (or any other value) or 'Tolerant' for the call at $Ast.
function Get-NativeStderrPreference($Ast, $Assignments) {
    $block = Get-NativeStderrBlock $Ast
    while ($block) {
        if (Test-NativeStderrTolerantBlock $block) { return 'Tolerant' }
        $last = $null
        foreach ($a in $Assignments) {
            if ($a.Extent.StartOffset -ge $Ast.Extent.StartOffset) { continue }
            if (-not [object]::ReferenceEquals((Get-NativeStderrBlock $a), $block)) { continue }
            if ($null -eq $last -or $a.Extent.StartOffset -gt $last.Extent.StartOffset) { $last = $a }
        }
        if ($last) {
            if ($last.Right.Extent.Text -match "^\s*['""]?Stop['""]?\s*$") { return 'Stop' }
            return 'Continue'
        }
        $block = Get-NativeStderrBlock $block
    }
    return 'Continue'
}

function Get-NativeStderrFindings {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()][AllowEmptyString()][string[]]$Text
    )
    $out = New-Object System.Collections.ArrayList
    if ($null -eq $Text) { $Text = @() }
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput(($Text -join "`n"), [ref]$tokens, [ref]$errors)
    if (@($errors).Count -gt 0) {
        [void]$out.Add([pscustomobject]@{ Path = $Path; Line = $errors[0].Extent.StartLineNumber; Kind = 'parse-error'; Detail = $errors[0].Message })
        return $out.ToArray()
    }

    $assignments = @($ast.FindAll({ param($n)
                $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                (Get-NativeStderrVarName $n.Left) -eq 'ErrorActionPreference' }, $true))

    # Variables the file assigns from text naming an executable.
    $exeVars = @{}
    foreach ($a in $ast.FindAll({ param($n)
                $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
        if ($a.Right.Extent.Text -match '(?i)\.(exe|com)\b') { $exeVars[(Get-NativeStderrVarName $a.Left).ToLowerInvariant()] = $true }
    }

    foreach ($cmd in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $errRedir = $false
        foreach ($r in $cmd.Redirections) {
            if ($r.FromStream -eq [System.Management.Automation.Language.RedirectionStream]::Error -or
                $r.FromStream -eq [System.Management.Automation.Language.RedirectionStream]::All) { $errRedir = $true }
        }
        if (-not $errRedir) { continue }

        $first = $cmd.CommandElements[0]
        $native = $false
        $what = ''
        if ($cmd.InvocationOperator -ne [System.Management.Automation.Language.TokenKind]::Unknown -and
            $first -is [System.Management.Automation.Language.VariableExpressionAst]) {
            $v = (Get-NativeStderrVarName $first).ToLowerInvariant()
            if ($v -match '^(exe|ghz|ghoztty|cli)$' -or $v -match 'exe$' -or $exeVars.ContainsKey($v)) {
                $native = $true; $what = '$' + $v
            }
        } elseif ($first -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
            if ($first.Value -match '(?i)(^|[\\/])ghoztty(\.exe|\.com)?$') { $native = $true; $what = $first.Value }
        }
        if (-not $native) { continue }

        if ((Get-NativeStderrPreference $cmd $assignments) -ne 'Stop') { continue }
        $line = $cmd.Extent.StartLineNumber
        if (Test-NativeStderrExempt $Text $line) { continue }
        [void]$out.Add([pscustomobject]@{
                Path = $Path; Line = $line; Kind = 'redirect'
                Detail = "$what with stderr redirected under Stop: $(($cmd.Extent.Text -split "`n")[0].Trim())"
            })
    }
    return $out.ToArray()
}

function Get-NativeStderrSweep {
    param([Parameter(Mandatory = $true)][string[]]$Roots)
    foreach ($r in $Roots) {
        foreach ($file in @(Get-ChildItem -LiteralPath $r -Filter *.ps1 -File -Recurse)) {
            $text = @(Get-Content -LiteralPath $file.FullName)
            foreach ($x in @(Get-NativeStderrFindings -Path $file.FullName -Text $text)) { $x }
        }
    }
}

# The ratchet comparison, as a function so the teeth can feed it a sweep with a
# planted file in it and require it to score red.
function Compare-NativeStderrBaseline {
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
