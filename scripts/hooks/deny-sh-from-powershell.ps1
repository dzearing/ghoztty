# T1901: a Claude Code PreToolUse hook (registered in .claude/settings.json,
# matcher "PowerShell") that refuses a PowerShell-tool command which would
# LAUNCH a .sh file.
#
# Why: PowerShell cannot run a .sh, so it ShellExecutes it; `.sh` has no open
# verb on this box, so DCOM starts `OpenWith.exe -Embedding` - the "How do you
# want to open this file?" picker - on the user's interactive desktop, where
# it sits over whatever they are doing. T1823 traced two of those to the
# banner hook line (`~/.config/ghoztty/hooks/ghoztty-banner.sh set ...`) run
# from the PowerShell tool and fixed the hook's help text; T1901 is the same
# line again, because the help text a session receives comes from the
# INSTALLED copy of the script, which stays at its old text until somebody
# clicks Update in Agent Integrations. Wording cannot reach a stale install,
# so this gate sits in front of the tool call instead.
#
# What it refuses (PowerShell's own parser, never a regex over the text):
#   - a command whose NAME ends in .sh            (`x.sh`, `& 'x.sh'`, `.\x.sh`)
#   - Start-Process / Invoke-Item (and aliases) on a .sh argument
#   - either of those inside `powershell|pwsh -Command "<script>"`
# `bash x.sh` / `sh x.sh` are allowed: the command there is bash.
#
# Fail-open by construction: anything unexpected (no stdin, bad JSON, another
# tool, a parse failure) exits 0 with no output, because a bug here must never
# be able to block every PowerShell call in a session.
#
# -CommandText runs the check without the hook envelope and prints DENY/ALLOW
# (the acceptance harness, test\win32\deny-sh-from-powershell.ps1, uses it).
[CmdletBinding(PositionalBinding = $false)]
param([string]$CommandText)

$ErrorActionPreference = 'Stop'

$launchers = @('start-process', 'saps', 'start', 'invoke-item', 'ii')
$shells = @('powershell', 'powershell.exe', 'pwsh', 'pwsh.exe')

function Get-Unquoted([string]$s) {
    return $s.Trim().Trim("'", '"')
}

function Find-ShLaunch([string]$text, [int]$depth) {
    if ($depth -gt 3 -or -not $text) { return $null }
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
    $cmds = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
    foreach ($cmd in $cmds) {
        $name = $cmd.GetCommandName()
        if (-not $name) {
            $first = $cmd.CommandElements[0]
            if ($first) { $name = Get-Unquoted $first.Extent.Text }
        }
        if (-not $name) { continue }
        if ($name -match '\.sh$') { return $name }
        $lower = $name.ToLowerInvariant()
        $rest = @($cmd.CommandElements | Select-Object -Skip 1)
        if ($launchers -contains $lower) {
            foreach ($el in $rest) {
                $v = if ($el -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $el.Value } else { Get-Unquoted $el.Extent.Text }
                if ($v -match '\.sh$') { return "$name $v" }
            }
        }
        if ($shells -contains $lower) {
            for ($i = 0; $i -lt $rest.Count; $i++) {
                $t = $rest[$i].Extent.Text
                if ($t -match '^-(c|command)$' -and ($i + 1) -lt $rest.Count) {
                    $inner = $rest[$i + 1]
                    $body = if ($inner -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $inner.Value }
                            elseif ($inner -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) { $inner.Value }
                            else { $inner.Extent.Text }
                    $hit = Find-ShLaunch $body ($depth + 1)
                    if ($hit) { return $hit }
                }
            }
        }
    }
    return $null
}

try {
    if ($PSBoundParameters.ContainsKey('CommandText')) {
        $hit = Find-ShLaunch $CommandText 0
        if ($hit) { "DENY $hit" } else { 'ALLOW' }
        exit 0
    }

    $raw = [Console]::In.ReadToEnd()
    if (-not $raw) { exit 0 }
    $payload = $raw | ConvertFrom-Json
    if ($payload.tool_name -ne 'PowerShell') { exit 0 }
    $hit = Find-ShLaunch ([string]$payload.tool_input.command) 0
    if (-not $hit) { exit 0 }

    $reason = "Refused (T1901): this PowerShell command launches a .sh file ($hit). " +
        "PowerShell cannot run a .sh, so Windows pops a 'How do you want to open this file?' " +
        "picker over the user's screen. Run that part from the Bash tool instead " +
        "(e.g. the banner: Bash tool, ~/.config/ghoztty/hooks/ghoztty-banner.sh set ...), " +
        "and the rest of the command from PowerShell as before."
    $out = @{
        hookSpecificOutput = @{
            hookEventName            = 'PreToolUse'
            permissionDecision       = 'deny'
            permissionDecisionReason = $reason
        }
    }
    $out | ConvertTo-Json -Depth 4 -Compress
    exit 0
} catch {
    exit 0
}
