# T1263: a Claude Code PreToolUse hook (registered in .claude/settings.json,
# matcher "Edit|Write|MultiEdit") that refuses a file write whose new text holds
# a backslash escape decoded into a control character.
#
# Why: T1231 found fifteen tracked files carrying 0x07 / 0x08 / 0x0c where a
# Windows path had been written - `zig-out\bin` on disk as `zig-out<0x08>in` -
# and two more arrived after its repair. T1263 found the writer in the session
# transcripts: the tool-call channel itself. An Edit or Write whose JSON
# arguments carry a path with ONE backslash has that backslash decoded as an
# escape (`\a` `\b` `\f` `\r` `\t`) before the tool sees the text, so the
# damaged byte is already in tool_input - beside correctly doubled backslashes
# in the same string. No script writes it, so no script can be fixed; the
# commit-time scan (scripts\control-char-scan.ps1) catches it, but only after
# the turn has moved on and somebody has to find the line again. This catches
# it at the one moment the author still knows what the path was meant to be.
#
# What counts is scripts\lib\EscapeDamage.ps1, shared with that scanner: a
# control byte other than tab/LF/CR, a CR that is not half of a CRLF, or a tab
# glued between path segments. Only files whose extension the scanner covers
# are judged, and only the NEW text (Write content, Edit/MultiEdit new_string),
# so an edit that repairs a damaged line is never refused for the old one.
#
# Fail-open by construction: anything unexpected (no stdin, bad JSON, another
# tool, an exception) exits 0 with no output, because a bug here must never be
# able to block every file write in a session.
#
# -Text/-FilePath runs the check without the hook envelope and prints DENY/ALLOW
# (the acceptance harness, test\win32\deny-escape-damage.ps1, uses it).
[CmdletBinding(PositionalBinding = $false)]
param([string]$Text, [string]$FilePath)

$ErrorActionPreference = 'Stop'

function Get-Refusal([string]$path, [string[]]$texts) {
    if (-not (Test-EscapeDamageExtension $path)) { return $null }
    foreach ($t in $texts) {
        $hits = Find-EscapeDamage $t
        if ($hits.Count -eq 0) { continue }
        $h = $hits[0]
        return [pscustomobject]@{
            Code    = $h.Code
            Kind    = $h.Kind
            Line    = $h.Line
            Count   = $hits.Count
            Context = Format-EscapeDamageContext $t $h.Index
        }
    }
    return $null
}

try {
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\EscapeDamage.ps1')

    if ($PSBoundParameters.ContainsKey('Text')) {
        $hit = Get-Refusal $FilePath @($Text)
        if ($hit) { "DENY $($hit.Code) $($hit.Kind) line $($hit.Line): $($hit.Context)" } else { 'ALLOW' }
        exit 0
    }

    $raw = [Console]::In.ReadToEnd()
    if (-not $raw) { exit 0 }
    $payload = $raw | ConvertFrom-Json
    $in = $payload.tool_input
    if (-not $in) { exit 0 }
    $texts = switch ([string]$payload.tool_name) {
        'Write'     { @([string]$in.content) }
        'Edit'      { @([string]$in.new_string) }
        'MultiEdit' { @($in.edits | ForEach-Object { [string]$_.new_string }) }
        default     { $null }
    }
    if (-not $texts) { exit 0 }
    $hit = Get-Refusal ([string]$in.file_path) $texts
    if (-not $hit) { exit 0 }

    $reason = ("Refused (T1263): the text for {0} holds {1} ({2}) at line {3} of the new text: '{4}'" -f
        $in.file_path, $hit.Code, $hit.Kind, $hit.Line, $hit.Context) +
        $(if ($hit.Count -gt 1) { " - and $($hit.Count - 1) more like it" } else { '' }) +
        ". A single backslash in the tool-call arguments was decoded as an escape on the way in " +
        "(\a -> 0x07, \b -> 0x08, \f -> 0x0c, \r -> CR, \t -> tab), so a path like zig-out\bin would " +
        "land on disk as zig-out<0x08>in. Re-send the call with that backslash escaped (doubled) in " +
        "the arguments, or write the path with forward slashes."
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
