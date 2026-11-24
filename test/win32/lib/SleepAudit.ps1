# SleepAudit (T2179) - classify every Start-Sleep in the acceptance harnesses,
# so a fixed sleep standing in for a handshake can only become rarer.
#
# THE DEFECT (T1164, T1228): a fixed `Start-Sleep` that means "by now the other
# thing has happened" is a race. It passes on an idle box and goes red only
# when the box is busy - T1164's section-M flake slept a flat 3s where it should
# have waited on a predicate. A harness that goes red under load trains the
# next turn to shrug at red. T1228's census found 2006 such sites, far too many
# to convert in one context, so this is the gate that comes first: it holds
# the count where it stands and refuses a new one.
#
# Every CommandAst named `Start-Sleep` or `sleep` is sorted into one class:
#
#   poll    - inside a loop statement (while / do / for / foreach), or inside a
#             script block handed to a wait helper (a command named Wait-*,
#             Poll-*, Retry-*, or *-Until / *-Retry / *-Poll / *-Wait). That
#             sleep is a poll interval: the loop's predicate is the handshake.
#   settle  - a sleep outside a loop that carries `# settle: <reason>` on its
#             own line or the line above. That names a debounce or a timer the
#             PRODUCT has, where the sleep itself is the subject under test.
#   bare    - everything else: the handshake candidates. Feeds the ratchet.
#   settle-unreasoned - a `# settle:` marker with nothing after the colon. It
#             excuses nothing and is held at zero, so the marker cannot become
#             a way to silence the audit.
#   parse-error - the file does not parse; held at zero.
#
# T1228's census counted the loop rule alone (`LoopOnly` below is that count),
# so the classifier can be checked against its numbers.

Set-StrictMode -Off

$script:SLEEP_AUDIT_WAIT_HELPER = '(?i)^(wait|poll|retry)(-|$)|-(until|retry|poll|wait)$|^invoke-.*(retry|poll|wait)'

function Get-SleepAuditRelativePath([string]$Path, [string]$Repo) {
    $full = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetFullPath($Repo).TrimEnd('\') + '\'
    if ($full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $full.Substring($root.Length)
    }
    return $Path
}

# 'reason' when the line (or the one above) carries `# settle: <text>`,
# 'empty' when it carries the marker with no reason, '' when neither does.
function Get-SleepAuditSettleMarker($Lines, [int]$LineNumber) {
    $found = ''
    foreach ($n in @($LineNumber, ($LineNumber - 1))) {
        if ($n -lt 1 -or $n -gt $Lines.Count) { continue }
        $l = [string]$Lines[$n - 1]
        if ($l -match '#\s*settle:\s*\S') { return 'reason' }
        if ($l -match '#\s*settle:\s*$') { $found = 'empty' }
    }
    return $found
}

# 'loop', 'helper' or '' - why the sleep at $Ast is a poll interval, if it is.
function Get-SleepAuditPollReason($Ast) {
    $p = $Ast.Parent
    while ($p) {
        if ($p -is [System.Management.Automation.Language.LoopStatementAst]) { return 'loop' }
        if ($p -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) {
            $owner = $p.Parent
            # A script block bound to a named parameter sits under a
            # CommandParameterAst; one passed positionally sits under the command.
            if ($owner -is [System.Management.Automation.Language.CommandParameterAst]) { $owner = $owner.Parent }
            if ($owner -is [System.Management.Automation.Language.CommandAst]) {
                $name = $owner.GetCommandName()
                if ($name -and $name -match $script:SLEEP_AUDIT_WAIT_HELPER) { return 'helper' }
            }
        }
        $p = $p.Parent
    }
    return ''
}

function Get-SleepAuditSites {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()][AllowEmptyString()][string[]]$Text
    )
    $out = New-Object System.Collections.ArrayList
    if ($null -eq $Text) { $Text = @() }
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput(($Text -join "`n"), [ref]$tokens, [ref]$errors)
    if (@($errors).Count -gt 0) {
        [void]$out.Add([pscustomobject]@{
                Path = $Path; Line = $errors[0].Extent.StartLineNumber; Class = 'parse-error'; Poll = ''
                Detail = $errors[0].Message
            })
        return $out.ToArray()
    }
    foreach ($cmd in $ast.FindAll({ param($n)
                $n -is [System.Management.Automation.Language.CommandAst] -and
                "$($n.GetCommandName())" -match '^(?i)(start-sleep|sleep)$' }, $true)) {
        $line = $cmd.Extent.StartLineNumber
        $poll = Get-SleepAuditPollReason $cmd
        $class = 'bare'
        if ($poll) { $class = 'poll' }
        else {
            $m = Get-SleepAuditSettleMarker $Text $line
            if ($m -eq 'reason') { $class = 'settle' }
            elseif ($m -eq 'empty') { $class = 'settle-unreasoned' }
        }
        $argText = (@($cmd.CommandElements | Select-Object -Skip 1) | ForEach-Object { $_.Extent.Text }) -join ' '
        [void]$out.Add([pscustomobject]@{
                Path = $Path; Line = $line; Class = $class; Poll = $poll
                Detail = "Start-Sleep $argText".Trim()
            })
    }
    return $out.ToArray()
}

function Get-SleepAuditSweep {
    param([Parameter(Mandatory = $true)][string[]]$Roots)
    foreach ($r in $Roots) {
        foreach ($file in @(Get-ChildItem -LiteralPath $r -Filter *.ps1 -File -Recurse)) {
            $text = @(Get-Content -LiteralPath $file.FullName)
            foreach ($x in @(Get-SleepAuditSites -Path $file.FullName -Text $text)) { $x }
        }
    }
}

# Totals for a sweep: every class, plus LoopOnly - the loop rule alone, which
# is the definition T1228's census used.
function Get-SleepAuditCensus($Sites) {
    $c = [ordered]@{ Total = 0; Poll = 0; LoopOnly = 0; Helper = 0; Settle = 0; Bare = 0; Unreasoned = 0; ParseError = 0 }
    foreach ($s in @($Sites)) {
        if ($s.Class -eq 'parse-error') { $c.ParseError++; continue }
        $c.Total++
        switch ($s.Class) {
            'poll' { $c.Poll++; if ($s.Poll -eq 'loop') { $c.LoopOnly++ } else { $c.Helper++ } }
            'settle' { $c.Settle++ }
            'bare' { $c.Bare++ }
            'settle-unreasoned' { $c.Unreasoned++ }
        }
    }
    return [pscustomobject]$c
}

# The ratchet comparison, as a function so the teeth can feed it a sweep with a
# planted file in it and require it to score red.
function Compare-SleepAuditBaseline {
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
