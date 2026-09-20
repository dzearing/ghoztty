# Transcript.ps1 - T900. A RED run's transcript must outlive the re-run.
#
# THE DEFECT THIS EXISTS TO PREVENT, measured 2026-08-16. `ipc-p2.ps1` scored
#
#     P2 ACCEPTANCE: 16 FAILURE(S) (2 assertions passed)
#
# and two immediate re-runs were ALL PASS with no code change in between. The
# run HAD written a full transcript - T379 put a `Tee-Object` there for exactly
# this - but to a FIXED path, `%TEMP%\ghoztty-ipc-p2-last.log`. The first green
# re-run truncated it. So the one flake anybody had ever seen was diagnosable
# for about ninety seconds, and what reached the tracker was a shrug.
#
# The other half of the same defect: five of the seven floor scripts never
# NAMED the file. A transcript nobody is told about is a transcript nobody
# reads, and the floor is habitually run as
# `... | Select-Object -Last 1`, which throws away every line that is not the
# verdict. So the path has to be IN the verdict line or it does not exist.
#
# THE RULE:
#
#     A run that ends red leaves its transcript at a path NO LATER RUN CAN
#     WRITE, and names that path in the one line a `-Last 1` reader keeps.
#
# THE SHAPE THIS FILE IMPOSES, replacing the three-line trailer each script
# used to carry:
#
#     $transcript = New-TestTranscript -Name 'ipc-p2'
#     & { ...body... } 2>&1 | Tee-Object -FilePath $transcript
#     Complete-TestBody
#     exit (Complete-TestTranscript -Name 'ipc-p2' -Path $transcript `
#         -Label 'P2 ACCEPTANCE' -Pass $script:passes -Fail $script:failures).Code
#
# A green run preserves nothing (the live `-last.log` is still there for the
# curious, and is still truncated by the next run - that is the point of the
# word "last"). A red run is copied to
#
#     %TEMP%\ghoztty-<name>-fail-<yyyyMMdd-HHmmss>-<pid>.log
#
# whose name carries the clock and the process, so back-to-back reds - the
# shape a flake hunt actually produces - accumulate instead of overwriting each
# other. The newest `$script:TranscriptKeep` per name are kept and the rest are
# deleted, so an unattended loop cannot fill `%TEMP%` with evidence nobody will
# ever read.
#
# What this deliberately does NOT do: decide anything about the verdict. The
# scorer in lib\TestScore.ps1 is still the only thing that says whether a run
# passed; this file reads that answer and files the evidence when it is bad.

Set-StrictMode -Off

. (Join-Path $PSScriptRoot 'TestScore.ps1')

# How many preserved failures to keep per harness name. Ten is enough to hold
# an evening of flake-hunting re-runs and small enough that nobody has to think
# about %TEMP%.
$script:TranscriptKeep = 10

function Get-TestTranscriptPath {
    <#
      The LIVE transcript path for a harness: the file `Tee-Object` writes and
      the next run truncates. One place so the naming cannot drift between the
      script that writes it and the acceptance test that reads it.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Dir = $env:TEMP
    )
    return (Join-Path $Dir "ghoztty-$Name-last.log")
}

function New-TestTranscript {
    <#
      Start a run's transcript. Removes the previous run's live file first, so
      a run that dies before `Tee-Object` ever opens it cannot leave the LAST
      run's lines sitting there to be read as this one's.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Dir = $env:TEMP
    )
    $path = Get-TestTranscriptPath -Name $Name -Dir $Dir
    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    return $path
}

function Get-PreservedTranscripts {
    <#
      Every preserved failure transcript for a harness, newest first. The
      acceptance script reads this; so can a human hunting a flake.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Dir = $env:TEMP
    )
    return @(Get-ChildItem -LiteralPath $Dir -Filter "ghoztty-$Name-fail-*.log" `
            -File -ErrorAction SilentlyContinue |
        Sort-Object -Property LastWriteTime -Descending)
}

function Save-FailedTranscript {
    <#
      Copy a red run's transcript somewhere no later run will write, and prune
      the older ones. Returns the preserved path, or $null when there was no
      transcript to preserve.

      The name carries the clock to the second AND the pid, because two runs of
      the same harness inside one second is a thing a flake hunt does; a
      collision would silently overwrite the very evidence this exists to keep.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Dir = $env:TEMP,
        [int]$Keep = 0
    )
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    if ($Keep -lt 1) { $Keep = $script:TranscriptKeep }

    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $preserved = Join-Path $Dir "ghoztty-$Name-fail-$stamp-$PID.log"
    $n = 1
    while (Test-Path -LiteralPath $preserved) {
        $preserved = Join-Path $Dir "ghoztty-$Name-fail-$stamp-$PID-$n.log"
        $n++
    }
    Copy-Item -LiteralPath $Path -Destination $preserved -Force

    # Prune oldest-first, and never let a locked or vanished file turn evidence
    # keeping into a run failure.
    # `@(...)` at the CALL SITE, not only inside the function: PS 5.1 unrolls a
    # function's array return, so a single preserved file would arrive here as a
    # bare FileInfo and the range index below would throw.
    $all = @(Get-PreservedTranscripts -Name $Name -Dir $Dir)
    if ($all.Count -gt $Keep) {
        foreach ($old in $all[$Keep..($all.Count - 1)]) {
            Remove-Item -LiteralPath $old.FullName -Force -ErrorAction SilentlyContinue
        }
    }
    return $preserved
}

function Complete-TestTranscript {
    <#
      The trailer every teed acceptance script ends on: score the run, and if it
      is red, append the verdict to the transcript, preserve it under a name
      later runs cannot clobber, and print the verdict line NAMING that file.

      Returns the verdict object (Line / Code / Kind) with an added `Evidence`
      property, so the caller ends on `exit (...).Code`.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Label,
        [int]$Pass,
        [int]$Fail,
        [int]$Skipped = 0,
        [string]$Unit = 'assertions',
        [int]$MinPass = 1,
        [string]$Dir = $env:TEMP,
        [int]$Keep = 0
    )

    $v = Get-TestVerdictLine -Pass $Pass -Fail $Fail -Skipped $Skipped `
        -Label $Label -Unit $Unit -MinPass $MinPass `
        -Incomplete:(-not (Test-TestBodyComplete))

    $evidence = $null
    if ($v.Code -ne 0) {
        # The verdict lands in the transcript BEFORE the copy, so the preserved
        # file is self-contained: every assertion line and the verdict they add
        # up to, in one file, with nothing to cross-reference.
        if (Test-Path -LiteralPath $Path) { Add-Content -LiteralPath $Path -Value $v.Line }
        $evidence = Save-FailedTranscript -Name $Name -Path $Path -Dir $Dir -Keep $Keep
    }

    $line = $v.Line
    if ($evidence) { $line = "$line - evidence: $evidence" }
    $color = if ($v.Kind -eq 'pass') { 'Green' } else { 'Red' }
    Write-Host $line -ForegroundColor $color

    return [pscustomobject]@{
        Kind     = $v.Kind
        Code     = $v.Code
        Line     = $line
        Verdict  = $v.Line
        Evidence = $evidence
    }
}
