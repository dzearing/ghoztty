# RunVerdict.ps1 - score one finished acceptance-script run from its exit code
# and its log. Shared by scripts\suite-run.ps1 (T361, the serial suite) and
# scripts\acceptance-parallel.ps1 (T1960, the due set run four at a time), so
# the two runners can never disagree about what "pass" means (T1960 moved it
# here out of suite-run.ps1 unchanged).

Set-StrictMode -Off

<#
Score one finished run from its exit code and its log.

The exit code is the authority - the suite's own contract (T221/T271) is that a
script printing failure exits failure - and the verdict LINE is what a human
reads. They are recorded separately on purpose: a script whose two disagree is
a defect this runner should be able to name, not paper over.
#>
function Get-VerdictLine {
    param([string]$LogPath)

    $line = ''
    if (-not $LogPath) { return $line }
    if (Test-Path -LiteralPath $LogPath) {
        $tail = @(Get-Content -LiteralPath $LogPath -Tail 40 -ErrorAction SilentlyContinue)
        for ($i = $tail.Count - 1; $i -ge 0; $i--) {
            $t = $tail[$i].Trim()
            if ($t) { $line = $t; break }
        }
        # Prefer an actual verdict line if one is in the tail but not last
        # (a few scripts print a teardown note after their verdict).
        for ($i = $tail.Count - 1; $i -ge 0; $i--) {
            $t = $tail[$i].Trim()
            if ($t -match 'ALL PASS|FAILURE\(S\)|ASSERTED (NOTHING|TOO LITTLE)|SKIP ALL') { $line = $t; break }
        }
    }
    return $line
}

function Get-RunVerdict {
    param([int]$ExitCode, [string]$LogPath, [bool]$TimedOut, [string]$AltLogPath)

    # STDOUT decides the quoted line, and stderr is only the fallback for a
    # script that said nothing there at all (T1125). The caller hands them in
    # as two files on purpose: stderr is folded onto the END of the log, so
    # scoring one merged file quotes the last stderr line as the verdict - which
    # is how a soak killed 20 minutes into its silent sampling loop was reported
    # as `Waiting for Ghoztty to answer '+list'`, a startup notice printed in its
    # first seconds, and left a hung app as the leading hypothesis for a day.
    $line = Get-VerdictLine -LogPath $LogPath
    if (-not $line) { $line = Get-VerdictLine -LogPath $AltLogPath }

    if ($TimedOut) { return @{ Kind = 'stall'; Line = $line } }

    switch ($ExitCode) {
        0 {
            if ($line -match 'ALL PASS') { return @{ Kind = 'pass'; Line = $line } }
            # A whole-script SKIP (T1100): the box could not answer the question
            # this script asks - no composited pixels on a background desktop, no
            # SendInput off the input desktop, an input lock owning the
            # foreground. It asserted nothing and it did not fail, so it is
            # neither `pass` nor red: scored apart, counted apart, and NOT
            # re-run by the confirm pass, which exists to separate a product
            # defect from an isolation artefact and has no such question to ask
            # here. The capability is named in the line by
            # lib\DesktopCapability.ps1, so the one line anybody reads says what
            # could not be asked.
            if ($line -match '^\s*SKIP ALL') { return @{ Kind = 'skip'; Line = $line } }
            # Exit 0 with no pass verdict: either a script with no verdict at
            # all, or the fall-through shape T221 exists to catch.
            return @{ Kind = 'error'; Line = $(if ($line) { $line } else { '(exit 0, no verdict line)' }) }
        }
        1 { return @{ Kind = 'fail'; Line = $(if ($line) { $line } else { '(exit 1, no verdict line)' }) } }
        2 { return @{ Kind = 'nothing'; Line = $(if ($line) { $line } else { '(exit 2, no verdict line)' }) } }
        default { return @{ Kind = 'error'; Line = "exit $ExitCode - $line" } }
    }
}


<#
A script's own declaration of how long it legitimately needs, read from a
`# suite-timeout-sec: <N>` comment in its text. Returns 0 when it declares
nothing, which means "use the run's -TimeoutSec".

Why a declaration in the script rather than a table in this runner (T1125):
`soak.ps1` runs a 30-minute soak by design and was killed at the 600s cap on
every sweep and scored `stall` - a measurement artefact that read exactly like
the app having hung. The number belongs beside the code that spends it, because
a table here goes stale the moment somebody changes a script's -Minutes default
and nobody edits the runner.

Only the first match counts, and only a positive integer: a garbled declaration
falls back to the run's cap rather than to "no bound", the same rule
ipc_timeout.zig applies to its env var.
#>
function Get-ScriptTimeout {
    param([string]$Text)
    if (-not $Text) { return 0 }
    # \r? before the anchor: `$` in .NET multiline matches before the \n, and a
    # CRLF file leaves the \r inside the line - so a declaration in a CRLF script
    # silently did not exist at all. soak.ps1 became CRLF in ce943e238 and went
    # straight back to being killed at 600s and scored `stall`, which is the
    # exact defect T1125 fixed.
    #
    # T1960: and only a real COMMENT counts. The line used to be matched anywhere
    # in the text, so test\win32\suite-run.ps1 - whose section N writes
    # `# suite-timeout-sec: 40` into a fixture HERE-STRING - was itself capped at
    # 40 seconds and scored `stall` by any runner that read it. The tokenizer
    # knows a comment from string content; a regex over raw lines does not.
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errors)
    $m = $null
    foreach ($t in $tokens) {
        if ($t.Kind -ne [System.Management.Automation.Language.TokenKind]::Comment) { continue }
        $c = [regex]::Match($t.Text, '^[ \t]*#[ \t]*suite-timeout-sec[ \t]*:[ \t]*(\d+)[ \t]*\r?$')
        if ($c.Success) { $m = $c; break }
    }
    if (-not $m) { return 0 }
    $v = 0
    if (-not [int]::TryParse($m.Groups[1].Value, [ref]$v)) { return 0 }
    if ($v -le 0) { return 0 }
    return $v
}

<#
Why a script that TRIED to declare a timeout did not get one, or '' when it
either declared one that parsed or never tried (T1166).

Get-ScriptTimeout's 0 means two different things - "declares nothing" and
"declares something this reader cannot read" - and they used to be the same
silence. soak.ps1 lost its 2400s to a CRLF rewrite and went back to a 600s kill
scored `stall` with nothing saying why, and agent-lineage-suites.ps1 sat at the
global cap for its whole life behind `# suite-timeout-sec 900` (no colon). An
attempt is any line comment that OPENS with the key, spelled loosely (case,
`_`, a missing `-sec`), so a typo is caught rather than read as no declaration.
A block comment or a string that merely mentions the key is not an attempt -
the same rule as the reader above.
#>
function Get-ScriptTimeoutProblem {
    param([string]$Text)
    if (-not $Text) { return '' }
    if ((Get-ScriptTimeout -Text $Text) -gt 0) { return '' }
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errors)
    foreach ($t in $tokens) {
        if ($t.Kind -ne [System.Management.Automation.Language.TokenKind]::Comment) { continue }
        if ($t.Text -notmatch '(?i)^[ \t]*#[ \t]*suite[-_ ]?timeout') { continue }
        $shown = $t.Text.Trim()
        return "timeout declaration does not parse (line $($t.Extent.StartLineNumber): '$shown'; want '# suite-timeout-sec: <seconds>') - it gets the run's cap instead"
    }
    return ''
}
