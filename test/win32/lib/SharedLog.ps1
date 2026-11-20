# SharedLog (T1520) - a log file that a background job APPENDS to while the
# harness READS it.
#
# WHY THIS EXISTS, measured. Every fake relay and fake HTTP server in this suite
# runs in a `Start-Job` and records what it saw in a log file; the harness's
# oracle then reads that file. Both sides used the cmdlets, and the cmdlets do
# not share: in a 4-second race on this box (a job appending one line every
# ~15 ms, the harness reading in a loop), `Add-Content` as the writer made
# 2,538 of 2,620 `Get-Content` reads (97%) and as many `Select-String -Path`
# reads throw "the file is being used by another process", and the WRITER lost
# 240 of its own lines the other way round. Under the suite's usual
# `$ErrorActionPreference = 'Continue'` a failed read is just an empty result,
# so a hit that IS in the log scored as a missing one. That is how T1517's run of
# relay-account.ps1 reported "FAIL signing back in RE-ENROLLED this machine
# (T1425)" over traffic the log held: a PLAUSIBLE product defect, which is worse
# than a hang because it sends the next turn hunting a bug that is not there.
#
# The same race with the writer as `[IO.File]::AppendAllText` - which opens the
# file for append with FileShare.Read and closes it at once - failed 0 of 2,370
# reads and dropped 0 lines, with the readers unchanged.
#
# THE RULE, two halves:
#
#   1. Inside a `Start-Job` body, append with
#          [IO.File]::AppendAllText($path, "$line`r`n")
#      never `Add-Content` or `Out-File -Append`. job-teardown.ps1 section H
#      sweeps test\win32 for exactly that, so a new fixture cannot bring the
#      race back and stay green until a run happens to lose it.
#   2. Read with `Read-SharedLog` below (or plain `Get-Content`, which opens with
#      FileShare.ReadWrite and is safe against rule 1's writer). Never
#      `[IO.File]::ReadAllText`/`ReadAllLines` on a job's log: they open with
#      FileShare.Read and so lock the WRITER out for the length of the read.
#
# Read-SharedLog additionally retries, so even a writer outside this rule (a
# product process, an antivirus scan) costs a few milliseconds rather than a
# phantom FAIL, and when it truly cannot read it THROWS - a harness error names
# the harness; an empty log names the product.

function Read-SharedLog {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        # The whole file as one string, like `Get-Content -Raw` (but '' rather
        # than $null for an empty file). Without it, the lines are EMITTED one
        # by one, exactly like `Get-Content`: pipe them, or wrap the call in
        # @() to count them. (Never `return ,` an array here - a caller piping
        # into Select-String would get one joined object, and @() of an empty
        # one counts 1.)
        [switch]$Raw,
        [int]$TimeoutMs = 2000
    )
    if (-not (Test-Path -LiteralPath $Path)) { if ($Raw) { return '' } else { return } }
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    $lastError = $null
    while ($true) {
        try {
            # ReadWrite|Delete: legal while a writer holds the file open, and
            # never the reason a writer's own open fails.
            $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
            $fs = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
            try {
                $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8, $true)
                $text = $sr.ReadToEnd()
            } finally { $fs.Dispose() }
            break
        } catch [IO.FileNotFoundException] {
            # Deleted between the Test-Path and the open: same as never written.
            if ($Raw) { return '' } else { return }
        } catch {
            $lastError = $_.Exception.Message
            if ([DateTime]::UtcNow -ge $deadline) {
                throw "Read-SharedLog: could not read '$Path' for ${TimeoutMs}ms ($lastError) - a harness error, not a product result (T1520)"
            }
            Start-Sleep -Milliseconds 25
        }
    }
    if ($Raw) { return $text }
    if ($text -eq '') { return }
    # A writer may be mid-line; the final line is whatever has landed so far.
    # The terminator of the last complete line is not a line of its own.
    $lines = $text -split "`r?`n"
    if ($lines[-1] -eq '') { $lines = $lines[0..($lines.Count - 2)] }
    $lines
}
