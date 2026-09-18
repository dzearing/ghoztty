# TestWaitAudit (T831) - the analyzer behind test\win32\test-wait-oracle.ps1.
#
# THE RULE it encodes: a wait in Zig code may not be bounded by a COUNT of
# iterations. A loop that gives up after N sleeps or N yields has not measured
# time, it has measured scheduler contention - 100_000 yields can burn through
# in milliseconds on a loaded box (T472), and `Thread.sleep(100us)` rounds up
# to Windows' ~15.6ms timer tick, so 30k sleeping spins was ~8 MINUTES per miss
# (T89b). Both failures are invisible: the first is a red that means nothing,
# the second is a lane that looks wedged.
#
# A finding is a loop whose EXIT is an iteration count -
#
#     for (0..30_000) |_| { ... std.Thread.sleep(...) ... }
#     while (i < 10_000) : (i += 1) { ... std.Thread.yield() ... }
#
# - and whose body sleeps or yields, which is what makes it a WAIT rather than
# ordinary work. A loop bounded by a timer, a ResetEvent, or one of the shared
# `src\remote\test_util.zig` helpers is not a finding, because those measure
# the thing they claim to measure.
#
# EXEMPTION: `// test-wait-audit: <reason>` on the loop line or within the
# three lines above it waives that site. A bare marker with no reason waives
# nothing - an exemption that does not say why is a silencer, not a decision.
# The one live use is production code with NO clock available
# (`src\renderer\State.zig`, where `std.time.Timer.start()` itself failed), for
# which a bounded spin is the honest last resort.

Set-StrictMode -Version Latest

# A loop header whose bound is a literal iteration count.
$script:TestWaitLoopPatterns = @(
    # for (0..30_000) |_| {
    '^\s*(?:\}\s*else\s*)?for\s*\(\s*0\s*\.\.\s*[0-9_]+\s*\)',
    # while (i < 10_000) ... / while (spins < 500)
    '^\s*while\s*\(\s*[A-Za-z_][A-Za-z0-9_\.]*\s*<\s*[0-9_]+\s*\)',
    # while (n > 0) : (n -= 1)
    '^\s*while\s*\(\s*[A-Za-z_][A-Za-z0-9_\.]*\s*>\s*0\s*\)\s*:\s*\(\s*[A-Za-z_][A-Za-z0-9_\.]*\s*-=\s*1\s*\)'
)

function Test-TestWaitExempt {
    param([string[]]$Lines, [int]$Index)
    $from = [Math]::Max(0, $Index - 3)
    for ($i = $from; $i -le $Index; $i++) {
        $m = [regex]::Match($Lines[$i], '//\s*test-wait-audit:\s*(?<why>\S.*)$')
        if ($m.Success -and $m.Groups['why'].Value.Trim().Length -gt 0) { return $true }
    }
    return $false
}

# Every finding in one file. Writes objects to the pipeline; callers wrap the
# call in @(...) so a single finding cannot unroll into a bare object (T794).
function Get-TestWaitFindings {
    param([Parameter(Mandatory)][string]$Path)

    $raw = [System.IO.File]::ReadAllText($Path)
    $lines = $raw -split "`r?`n"

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -match '^\s*//') { continue }

        $isLoop = $false
        foreach ($p in $script:TestWaitLoopPatterns) {
            if ($line -match $p) { $isLoop = $true; break }
        }
        if (-not $isLoop) { continue }
        if (-not ($line -match '\{\s*$')) { continue }   # single-statement loops carry no wait body

        # The loop body, by brace depth from this line.
        $depth = 0
        $body = New-Object System.Collections.Generic.List[string]
        $end = $i
        for ($j = $i; $j -lt $lines.Count; $j++) {
            $text = $lines[$j] -replace '//.*$', ''
            $depth += ([regex]::Matches($text, '\{')).Count
            $depth -= ([regex]::Matches($text, '\}')).Count
            if ($j -gt $i) { [void]$body.Add($lines[$j]) }
            $end = $j
            if ($depth -le 0 -and $j -gt $i) { break }
        }
        $bodyText = ($body -join "`n")

        if ($bodyText -notmatch 'std\.Thread\.(sleep|yield)\s*\(') { continue }
        # A body that also consults a clock is bounded by the clock; the count
        # is then a belt-and-braces cap, not the oracle.
        if ($bodyText -match '\.read\(\)|milliTimestamp|nanoTimestamp|timedWait|Deadline\.|deadline\.(yield|tick)') { continue }
        if (Test-TestWaitExempt -Lines $lines -Index $i) { continue }

        [pscustomobject]@{
            File = $Path
            Line = $i + 1
            End  = $end + 1
            Kind = 'spin-count'
            Text = $line.Trim()
        }
    }
}

# The whole sweep. Returns findings plus how many files it actually read, so a
# sweep that looked at nothing cannot be reported as a clean tree.
function Invoke-TestWaitSweep {
    param([Parameter(Mandatory)][string]$Root)

    $files = @(Get-ChildItem -Path $Root -Recurse -Filter *.zig -File -ErrorAction SilentlyContinue)
    $findings = New-Object System.Collections.Generic.List[object]
    foreach ($f in $files) {
        foreach ($hit in @(Get-TestWaitFindings -Path $f.FullName)) { [void]$findings.Add($hit) }
    }
    [pscustomobject]@{
        Scanned  = $files.Count
        Findings = $findings.ToArray()
    }
}
