# Is the Claude session sitting in this pane still the LOOP's? (T1482)
#
# The watchdog re-enters a stalled loop by TYPING into the loop's pane - the
# lock's pane, or since T1478 the last pane the loop's ledger remembers. A pane
# id is a GUID and never recycled, but the WINDOW is the user's: after a stop
# (or any time at all) they can take it over for their own Claude session. The
# re-entry prompt is reset-first ("run /reset-context read go.md and go"), so
# landing it there clears the user's context and starts the loop in their work.
# Until this file, nothing asked whose session was in the pane before typing.
#
# The question is answered from what Claude Code itself writes, not from the
# screen:
#
#   pane shell pid -> its claude.exe descendant (or the lock's own claude pid)
#   ~/.claude/sessions/<pid>.json -> the session id that process runs NOW
#       (a /clear gives the same process a new session id; procStart guards
#        against a recycled pid)
#   ~/.claude/projects/<cwd>/<session>.jsonl -> the prompts typed into it
#
# Verdict (Get-LoopSessionVerdict, pure):
#
#   foreign  the LAST prompt a person typed is not a loop prompt. Every prompt
#            the loop types names go.md (the reset continuation, the watchdog's
#            nudge, the resume shim), so anything else is somebody's own work.
#   loop     the last typed prompt is the loop's, and the session either ran
#            go.md step 0's claim (its ACQUIRED / STOPPED output is in the
#            transcript) or has never been typed anything BUT loop prompts (a
#            turn that died before it could claim).
#   unknown  nothing readable: no claude pid, no session file, no transcript, no
#            typed prompt. The caller keeps its pre-T1482 behaviour - the lock
#            or the ledger naming the pane is still evidence it is the loop's,
#            and refusing on "could not look" would turn every Claude Code
#            format change into a loop that never recovers in place.
#
# Only `foreign` stops the typing. Acceptance: section F of
# test\win32\go-loop-resume.ps1.

# Pure: what kind of prompt is this? 'loop' | 'maybe' | 'other' | 'skip'.
#   skip   not typed by a person at the composer (slash-command wrappers, hook
#          and local-command output, interrupt markers, compaction summaries)
#   maybe  a reset-context continuation pointer whose file is gone, so its
#          content - which says whether it was the loop's - cannot be read
function Get-LoopPromptClass {
    param([string]$Text)
    $t = ([string]$Text).Trim()
    if (-not $t) { return 'skip' }
    # `!cmd` typed at the composer is a person at the keyboard; every other
    # tag-wrapped entry is the harness talking (slash commands - which the
    # loop's own /reset-context issues - hook output, reminders).
    if ($t.StartsWith('<bash-input>')) { return 'other' }
    if ($t.StartsWith('<')) { return 'skip' }
    if ($t.StartsWith('[Request interrupted')) { return 'skip' }
    if ($t -match '(?i)\bgo\.md\b') { return 'loop' }
    $m = [regex]::Match($t, '(?i)([A-Za-z]:[\\/][^\s"''<>|]*reset-context-cont-\d+\.txt)')
    if ($m.Success) {
        $p = $m.Groups[1].Value
        $body = $null
        try { if (Test-Path -LiteralPath $p) { $body = [IO.File]::ReadAllText($p) } } catch { $body = $null }
        if ($null -eq $body) { return 'maybe' }
        if ($body -match '(?i)\bgo\.md\b') { return 'loop' }
        return 'other'
    }
    return 'other'
}

# Pure: the verdict from a session's typed prompts (oldest first) and whether
# the session ever ran the loop's claim. Returns @{ Verdict; Why }.
function Get-LoopSessionVerdict {
    param([string[]]$Prompts = @(), [bool]$Claimed = $false)
    $classes = @()
    $last = ''
    foreach ($p in @($Prompts)) {
        $c = Get-LoopPromptClass $p
        if ($c -eq 'skip') { continue }
        $classes += $c
        $last = [string]$p
    }
    if ($classes.Count -eq 0) {
        return @{ Verdict = 'unknown'; Why = 'no typed prompt in the session transcript' }
    }
    $lastClass = $classes[$classes.Count - 1]
    $snippet = ($last -replace '\s+', ' ').Trim()
    if ($snippet.Length -gt 60) { $snippet = $snippet.Substring(0, 57) + '...' }
    if ($lastClass -eq 'other') {
        return @{ Verdict = 'foreign'; Why = "the last prompt typed there is not the loop's: '$snippet'" }
    }
    if ($Claimed) {
        return @{ Verdict = 'loop'; Why = "it ran the loop's claim and its last prompt is the loop's" }
    }
    if (-not ($classes -contains 'other') -and -not ($classes -contains 'maybe')) {
        return @{ Verdict = 'loop'; Why = "every prompt typed there is the loop's (it has not claimed yet)" }
    }
    return @{ Verdict = 'unknown'; Why = "its last prompt looks like the loop's but it never ran the claim" }
}

# Read the typed prompts and the claim evidence out of a transcript (JSONL).
# Returns @{ Ok; Prompts; Claimed; Why }. Lines are filtered by substring before
# any JSON parse: a loop transcript runs to megabytes, almost all tool results.
function Read-LoopTranscriptPrompts {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
        return @{ Ok = $false; Prompts = @(); Claimed = $false; Why = "no transcript at '$Path'" }
    }
    $prompts = New-Object System.Collections.ArrayList
    $claimed = $false
    # The claim's own output, never its source: a session that merely READ
    # go.md or the lock script would match a looser pattern. A real ACQUIRED
    # line carries a pane GUID; STOPPED is the parked shape T1478 recovers.
    # Or the claim COMMAND in a tool call: a turn that redirects the claim's
    # output to a file (lane b does) leaves only that in the transcript.
    $claimRx = [regex]('ACQUIRED pane=[0-9A-Fa-f]{8}-|STOPPED by request at \d{4}-|' +
        '"command":"[^"]*go-loop-exec\.ps1[^"]*\bclaim\b')
    try {
        foreach ($line in [IO.File]::ReadLines($Path)) {
            if (-not $claimed -and $claimRx.IsMatch($line)) { $claimed = $true }
            if (-not $line.Contains('"type":"user"')) { continue }
            if ($line.Contains('"tool_use_id"')) { continue }
            $d = $null
            try { $d = $line | ConvertFrom-Json } catch { continue }
            if ($null -eq $d -or $d.type -ne 'user' -or $null -eq $d.message) { continue }
            if ($d.isMeta -eq $true -or $d.isCompactSummary -eq $true) { continue }
            $c = $d.message.content
            $text = ''
            if ($c -is [string]) { $text = $c }
            else {
                $parts = @($c | Where-Object { $_ -and $_.type -eq 'text' } | ForEach-Object { [string]$_.text })
                $text = $parts -join "`n"
            }
            if ($text) { [void]$prompts.Add($text) }
        }
    } catch {
        return @{ Ok = $false; Prompts = @(); Claimed = $false; Why = "could not read '$Path': $($_.Exception.Message)" }
    }
    return @{ Ok = $true; Prompts = @($prompts); Claimed = $claimed; Why = '' }
}

# The session a live claude process is running RIGHT NOW, from Claude Code's
# own per-process record. Returns @{ SessionId; Cwd; Why }.
function Get-ClaudeProcessSession {
    param([int]$ClaudePid, [string]$SessionsDir)
    if ($ClaudePid -le 0) { return @{ SessionId = ''; Cwd = ''; Why = 'no claude process' } }
    $f = Join-Path $SessionsDir "$ClaudePid.json"
    if (-not (Test-Path -LiteralPath $f)) { return @{ SessionId = ''; Cwd = ''; Why = "no session record for pid $ClaudePid" } }
    $j = $null
    try { $j = [IO.File]::ReadAllText($f) | ConvertFrom-Json } catch { $j = $null }
    if ($null -eq $j -or -not $j.sessionId) { return @{ SessionId = ''; Cwd = ''; Why = "unreadable session record $f" } }
    # A record left behind by a dead process whose pid was reused describes
    # somebody else. procStart is the process creation FILETIME; a mismatch of
    # more than a second means a different process.
    if ($j.procStart) {
        try {
            $proc = Get-Process -Id $ClaudePid -ErrorAction Stop
            $born = $proc.StartTime.ToFileTimeUtc()
            if ([math]::Abs([double]$born - [double][string]$j.procStart) -gt 1e7) {
                return @{ SessionId = ''; Cwd = ''; Why = "session record for pid $ClaudePid belongs to an earlier process" }
            }
        } catch { }
    }
    return @{ SessionId = [string]$j.sessionId; Cwd = [string]$j.cwd; Why = '' }
}

function Resolve-ClaudeSessionTranscript {
    param([string]$SessionId, [string]$Cwd, [string]$ProjectsRoot)
    if (-not $SessionId -or -not (Test-Path -LiteralPath $ProjectsRoot)) { return '' }
    # Same mangling go-loop-lock.ps1's Resolve-Transcript tries first, with the
    # same tree walk behind it, so a rule change degrades to slow, not wrong.
    if ($Cwd) {
        $direct = Join-Path (Join-Path $ProjectsRoot ($Cwd.TrimEnd('\', '/') -replace '[:\\/]', '-')) "$SessionId.jsonl"
        if (Test-Path -LiteralPath $direct) { return $direct }
    }
    $hit = Get-ChildItem -Path $ProjectsRoot -Filter "$SessionId.jsonl" -Recurse -File -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($hit) { return $hit.FullName }
    return ''
}

# The whole question for one claude pid. Returns @{ Verdict; Why; SessionId; Transcript }.
function Get-LoopPidSessionVerdict {
    param(
        [int]$ClaudePid,
        [string]$SessionsDir = (Join-Path $env:USERPROFILE '.claude\sessions'),
        [string]$ProjectsRoot = (Join-Path $env:USERPROFILE '.claude\projects')
    )
    $s = Get-ClaudeProcessSession -ClaudePid $ClaudePid -SessionsDir $SessionsDir
    if (-not $s.SessionId) { return @{ Verdict = 'unknown'; Why = $s.Why; SessionId = ''; Transcript = '' } }
    $t = Resolve-ClaudeSessionTranscript -SessionId $s.SessionId -Cwd $s.Cwd -ProjectsRoot $ProjectsRoot
    if (-not $t) {
        return @{ Verdict = 'unknown'; Why = "no transcript for session $($s.SessionId)"; SessionId = $s.SessionId; Transcript = '' }
    }
    $r = Read-LoopTranscriptPrompts -Path $t
    if (-not $r.Ok) { return @{ Verdict = 'unknown'; Why = $r.Why; SessionId = $s.SessionId; Transcript = $t } }
    $v = Get-LoopSessionVerdict -Prompts $r.Prompts -Claimed $r.Claimed
    return @{ Verdict = $v.Verdict; Why = $v.Why; SessionId = $s.SessionId; Transcript = $t }
}
