# T2393: a Claude Code PreToolUse hook (registered in .claude/settings.json,
# matcher "Bash|PowerShell") that refuses a git command asking for AUTOSTASH.
#
# Why: `git pull --rebase` refuses a tree with a dirty guard stamp in it, so
# turns typed `git pull --rebase --autostash` instead - 66 times in lane A's
# reflog, a dozen in lane B's. Autostash parks every dirty file on refs/stash,
# and that stack is SHARED by every worktree of this repo (lane A, lane B, the
# unmarked window). When the pop conflicts - a stamp the pull also rewrote - git
# leaves the entry on the stack "for safety". Four such entries were sitting
# there on 2026-11-05, unlabelled, one `git stash pop` away from being applied
# by a turn that never made them. The commit guard never autostashes (T1057);
# `git-commit-guard.ps1 sync` is the pull that does not need to.
#
# What it refuses, per shell segment (split on ; && || | and newlines) whose
# command is git:
#   - the `--autostash` flag (pull, rebase, merge)
#   - `-c rebase.autoStash=true` / `-c merge.autoStash=true`
#   - `git config ... rebase.autostash true` (making it the default)
# `--no-autostash` is allowed, and so is a segment that only MENTIONS the flag
# (`grep -e --autostash`, a commit message quoting it).
#
# Fail-open by construction: anything unexpected exits 0 with no output, so a
# bug here can never block every shell call in a session.
#
# -CommandText runs the check without the hook envelope and prints DENY/ALLOW
# (the acceptance harness, test\win32\deny-git-autostash.ps1, uses it).
[CmdletBinding(PositionalBinding = $false)]
param([string]$CommandText)

$ErrorActionPreference = 'Stop'

function Find-Autostash([string]$text) {
    if (-not $text) { return $null }
    $segments = [regex]::Split($text, '\r?\n|;|&&|\|\||\|')
    foreach ($seg in $segments) {
        $t = $seg.Trim()
        # Leading env assignments (Bash `X=1 git ...`) and the PowerShell call
        # operator do not change which command runs.
        $t = $t -replace '^(?:[A-Za-z_][A-Za-z0-9_]*=\S*\s+)+', ''
        $t = $t -replace '^&\s*', ''
        if ($t -notmatch '^["'']?(?:[^\s"'']*[\\/])?git(?:\.exe)?["'']?(?:\s|$)') { continue }
        if ($t -match '(?i)(?:^|\s)--autostash(?:\s|$)') { return '--autostash' }
        if ($t -match '(?i)(?:rebase|merge)\.autostash\s*=\s*(?:true|yes|on|1)\b') { return $Matches[0] }
        if ($t -match '(?i)\sconfig\s.*(?:rebase|merge)\.autostash\s+(?:true|yes|on|1)\b') { return $Matches[0].Trim() }
    }
    return $null
}

try {
    if ($PSBoundParameters.ContainsKey('CommandText')) {
        $hit = Find-Autostash $CommandText
        if ($hit) { "DENY $hit" } else { 'ALLOW' }
        exit 0
    }

    $raw = [Console]::In.ReadToEnd()
    if (-not $raw) { exit 0 }
    $payload = $raw | ConvertFrom-Json
    if (@('Bash', 'PowerShell') -notcontains [string]$payload.tool_name) { exit 0 }
    $hit = Find-Autostash ([string]$payload.tool_input.command)
    if (-not $hit) { exit 0 }

    $reason = "Refused (T2393): this git command asks for autostash ($hit). The stash is shared by " +
        "every worktree of this repo (both loop lanes and any other window), and an autostash whose " +
        "pop conflicts is left on it for some later turn to pop as its own. To pull, run " +
        "'powershell -NoProfile -File scripts\git-commit-guard.ps1 sync' - it fast-forwards past " +
        "dirty files the pull does not touch and parks dirty guard stamps across a rebase. If a real " +
        "edit of yours is in the way, commit it first."
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
