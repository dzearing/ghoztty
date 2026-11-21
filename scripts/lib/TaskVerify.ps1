# TaskVerify.ps1 - run a task card's own `verify:` check (T1560).
#
# A card whose definition of done is ONE runnable, read-only command can carry
# that command in its frontmatter:
#
#   verify: "powershell -NoProfile -File test\\win32\\persistence-flag.ps1"
#
# Exit 0 means the card is ALREADY satisfied. `next` runs the check of the card
# it hands out and `stale-scan` runs every open card's, so a card fixed by a
# sibling task that never cited it surfaces the first time anything asks - T719
# sat open 34 days that way and T726 a further day, both with a green sweep as
# their whole Summary.
#
# The command is a PowerShell command line, run from the repository root by a
# fresh `powershell -NoProfile -NonInteractive`, so it can be a script call, a
# `git grep`, or a one-liner (`if (git grep -q 'TODO') { exit 1 }`). It is
# scoped to read-only, fast checks - a sweep, a grep, a script's -Check switch,
# never a full acceptance harness - and the timeout is what holds it to that:
# a check that overruns is reported as TIMEOUT and killed with its tree, and a
# pick never waits on it longer than the timeout.

# Run one verify command. Returns
#   @{ Outcome = 'pass'|'fail'|'timeout'|'error'; ExitCode; Seconds; Tail }
# where Tail is the last few non-blank output lines (stdout then stderr), for a
# reader who wants to know WHY a check is still red. Never throws.
function Invoke-TaskVerify {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string]$Root,
        [int]$TimeoutSeconds = 60,
        [int]$TailLines = 3
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $result = @{ Outcome = 'error'; ExitCode = $null; Seconds = 0.0; Tail = @() }
    $proc = $null
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'powershell.exe'
        # -EncodedCommand, so no quoting in the card's command can be mangled
        # on the way through a second command line.
        # The verdict is the LAST statement's success (`$?`), the way a shell
        # reads a command line, unless the command exits explicitly. So
        # `git grep -q X` passes on a match, and `if (git grep -q X) { exit 1 }`
        # passes on NO match - re-exiting with $LASTEXITCODE instead read the
        # second one red, because git's own exit 1 was still sitting there.
        # And an ERROR is a failure: a cmdlet that errors sets no exit code,
        # and a broken check reading as a satisfied card is the one wrong
        # answer this field must never give.
        $wrapped = "`$ProgressPreference = 'SilentlyContinue'`n`$ErrorActionPreference = 'Stop'`n" +
            "try {`n$Command`n`$verifyOk = `$?`n} catch { [Console]::Error.WriteLine(`$_.ToString()); exit 99 }`n" +
            "if (`$verifyOk) { exit 0 }`nif (`$global:LASTEXITCODE) { exit `$global:LASTEXITCODE }`nexit 1"
        $enc = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($wrapped))
        # -OutputFormat Text: a redirected -EncodedCommand otherwise serialises
        # its error stream as CLIXML, and the tail a reader sees is XML.
        $psi.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -OutputFormat Text -EncodedCommand $enc"
        $psi.WorkingDirectory = $Root
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        [void]$proc.Start()
        # Async reads: a check that writes more than a pipe buffer would block
        # forever on a synchronous read taken after WaitForExit.
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
            # Kill the whole tree: the check is usually `powershell -File x.ps1`,
            # so the process we hold is only the outer shell.
            & taskkill.exe /T /F /PID $proc.Id 2>&1 | Out-Null
            try { [void]$proc.WaitForExit(5000) } catch { }
            $result.Outcome = 'timeout'
        } else {
            $proc.WaitForExit()  # flush the async readers
            $result.ExitCode = $proc.ExitCode
            $result.Outcome = if ($proc.ExitCode -eq 0) { 'pass' } else { 'fail' }
        }
        $text = ''
        try { if ($outTask.Wait(2000)) { $text += $outTask.Result } } catch { }
        try { if ($errTask.Wait(2000)) { $text += "`n" + $errTask.Result } } catch { }
        $result.Tail = @($text -split "`r?`n" | Where-Object { $_.Trim() -and $_ -notmatch '^(#< CLIXML|<Objs )' } |
                Select-Object -Last $TailLines)
    } catch {
        $result.Outcome = 'error'
        $result.Tail = @("could not run: " + $_.Exception.Message)
    } finally {
        $sw.Stop()
        $result.Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        if ($proc) { try { $proc.Dispose() } catch { } }
    }
    return $result
}

# One line describing a verify outcome, the same words in `next` and
# `stale-scan` so a reader learns them once.
function Format-TaskVerify {
    param([hashtable]$Result, [int]$TimeoutSeconds = 60)
    switch ($Result.Outcome) {
        'pass'    { return ("PASS (exit 0 in {0}s)" -f $Result.Seconds) }
        'fail'    { return ("still red (exit {0} in {1}s)" -f $Result.ExitCode, $Result.Seconds) }
        'timeout' { return ("TIMEOUT (killed after {0}s - a verify check must be fast)" -f $TimeoutSeconds) }
        default   { return "ERROR (the check could not be run)" }
    }
}
