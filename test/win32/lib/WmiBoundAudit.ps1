# T2024: find WMI calls that can wait forever.
#
# `Get-CimInstance` without `-OperationTimeoutSec` waits as long as the CIM
# provider host does, and `Get-WmiObject` cannot be bounded at all. On
# 2026-10-16 the CIMWin32 host stalled for 24 minutes and every acceptance
# script running at the time sat in its own query (see lib\ProcessTable.ps1).
#
# THE RULE: a process lookup reads the kernel (`Get-OsProcess`), and a query
# that genuinely needs WMI is bounded - `-OperationTimeoutSec` on the call, or a
# splatted hashtable literal that carries the key (`Get-BoundedCimProcess`).
#
# Parsed, not grepped: a regex that names the cmdlet (CleanSlateAudit.ps1 keeps
# several) and a comment that mentions it are not calls, and only the AST can
# tell them apart from one.

Set-StrictMode -Off

$script:WmiBoundAuditCmdlets = @('Get-CimInstance', 'gcim', 'Get-WmiObject', 'gwmi')

function Find-UnboundedWmiCalls {
    <#
    .SYNOPSIS
    The unbounded WMI calls in one script's text, as { Line; Command; Text }.

    .DESCRIPTION
    A Get-CimInstance call is bounded when it names -OperationTimeoutSec, or
    splats a variable that this same text assigns a hashtable literal holding an
    OperationTimeoutSec key. A Get-WmiObject call is never bounded. Unrolls;
    call sites wrap it in `@(...)`.
    #>
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$null, [ref]$errs)

    # Splat names whose hashtable literal carries the bound.
    $boundSplats = @{}
    foreach ($a in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
        if ($a.Left -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }
        $ht = $a.Right.Find({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true)
        if (-not $ht) { continue }
        foreach ($kv in $ht.KeyValuePairs) {
            if ($kv.Item1 -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                $kv.Item1.Value -ieq 'OperationTimeoutSec') {
                $boundSplats[$a.Left.VariablePath.UserPath.ToLowerInvariant()] = $true
            }
        }
    }

    foreach ($c in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $name = $c.GetCommandName()
        if (-not $name -or ($script:WmiBoundAuditCmdlets -notcontains $name)) { continue }
        $bounded = $false
        if ($name -imatch '^(Get-CimInstance|gcim)$') {
            foreach ($el in $c.CommandElements) {
                if ($el -is [System.Management.Automation.Language.CommandParameterAst] -and
                    'OperationTimeoutSec' -ilike "$($el.ParameterName)*" -and $el.ParameterName.Length -ge 2) {
                    $bounded = $true
                }
                if ($el -is [System.Management.Automation.Language.VariableExpressionAst] -and $el.Splatted -and
                    $boundSplats.ContainsKey($el.VariablePath.UserPath.ToLowerInvariant())) {
                    $bounded = $true
                }
            }
        }
        if (-not $bounded) {
            [pscustomobject]@{
                Line    = $c.Extent.StartLineNumber
                Command = $name
                Text    = ($c.Extent.Text -split "`n")[0].Trim()
            }
        }
    }
}

function Get-WmiBoundAuditFindings {
    <#
    .SYNOPSIS
    Every .ps1 under -Dir (recursive) with an unbounded WMI call, as
    { Path; Lines; Count }. Unrolls.
    #>
    param([Parameter(Mandatory = $true)][string]$Dir)
    if (-not (Test-Path -LiteralPath $Dir)) { return }
    foreach ($f in Get-ChildItem -LiteralPath $Dir -Recurse -Filter '*.ps1' -File) {
        $hits = @(Find-UnboundedWmiCalls -Text ([System.IO.File]::ReadAllText($f.FullName)))
        if ($hits.Count -gt 0) {
            [pscustomobject]@{ Path = $f.FullName; Lines = @($hits | ForEach-Object { $_.Line }); Count = $hits.Count }
        }
    }
}
