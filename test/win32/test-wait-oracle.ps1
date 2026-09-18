# T831 acceptance - a Zig wait may not be bounded by a count of iterations,
# and the wall-clock helper that replaces one lives in exactly one place.
#
# THE DEFECT. T472 replaced five spin-count waits in src\remote\connection.zig
# with a local `TestDeadline`, and found that src\remote\agent\pty_child.zig had
# independently arrived at the same answer for the same reason (waitContains,
# wall-clock bounded, dumping what it captured on timeout - T89b, where 30k
# spins was ~8 MINUTES of timeout per miss because Thread.sleep(100us) rounds up
# to Windows' 15.6ms tick). Two implementations of one idea, in two files, each
# written after the other's lesson was already paid for - and nothing stopped
# the third from being a spin count again.
#
# So T831 hoisted both onto `src\remote\test_util.zig`'s `Deadline`, and this is
# the half that keeps them there: a hand sweep that finds nothing is
# indistinguishable from a hand sweep nobody re-runs.
#
# Sections:
#
#   A  the analyzer (lib\TestWaitAudit.ps1) bites, BOTH directions: a counted
#      wait is named, a timer-bounded wait is not, and the
#      `// test-wait-audit: <reason>` exemption waives a site only when it
#      carries a reason.
#   B  the two files T831 names are clean AND on the shared helper - the local
#      `TestDeadline` is gone rather than merely unused, and pty_child's
#      waitContains no longer rolls its own deadline.
#   C  the whole `src` tree is clean, and the sweep says how many files it read
#      so a sweep that looked at nothing cannot read as a clean tree.
#   D  the helper has ONE home: `Deadline` is declared once under src, and the
#      agent lane reaches that same declaration through its re-export rather
#      than a copy.
#
# `-NegativeControl` plants a counted wait into a throwaway copy of the real
# tree and requires section C's sweep to report it, which is the demonstration
# that the sweep's scope is `src` rather than its own fixtures.
#
# Static scan, no app, no CLI - safe on the off-desktop harness.
#
#   powershell -NoProfile -File test\win32\test-wait-oracle.ps1
#   powershell -NoProfile -File test\win32\test-wait-oracle.ps1 -NegativeControl
#
# isolation: none - this script never runs a ghoztty verb; it only reads source
# files and runs the analyzer over fixtures under temp\.
param(
    [string]$Repo,
    [switch]$NegativeControl
)

$ErrorActionPreference = 'Stop'
if (-not $Repo) { $Repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\TestWaitAudit.ps1')

$script:failures = 0
$script:passes = 0
function Assert($name, $cond, $detail = '') {
    if ($cond) { "  PASS $name"; $script:passes++ }
    else { "  FAIL $name $detail"; $script:failures++ }
}

$fixtureDir = Join-Path $Repo ('temp\test-wait-oracle-{0}' -f $PID)
New-Item -ItemType Directory -Force -Path $fixtureDir | Out-Null

function New-Fixture([string]$name, [string]$body) {
    $p = Join-Path $fixtureDir $name
    [System.IO.File]::WriteAllText($p, $body, (New-Object System.Text.UTF8Encoding $false))
    return $p
}

try {
    "== A. the analyzer, both directions"

    $counted = New-Fixture 'counted.zig' @'
test "the shape this rule exists for" {
    for (0..30_000) |_| {
        if (done()) break;
        std.Thread.sleep(100 * std.time.ns_per_us);
    }
}
'@
    $hits = @(Get-TestWaitFindings -Path $counted)
    Assert 'A1 a counted sleep-wait is reported' ($hits.Count -eq 1) "(found $($hits.Count))"
    if ($hits.Count -eq 1) {
        Assert 'A2 the finding names the loop line' ($hits[0].Line -eq 2) "(line $($hits[0].Line))"
        Assert 'A3 the finding names its kind' ($hits[0].Kind -eq 'spin-count') "($($hits[0].Kind))"
    } else {
        Assert 'A2 the finding names the loop line' $false '(no finding)'
        Assert 'A3 the finding names its kind' $false '(no finding)'
    }

    $countedWhile = New-Fixture 'counted-while.zig' @'
test "the same shape, written as a while" {
    var i: usize = 0;
    while (i < 10_000) : (i += 1) {
        if (done()) break;
        std.Thread.yield() catch {};
    }
}
'@
    Assert 'A4 a counted yield-wait is reported too' (@(Get-TestWaitFindings -Path $countedWhile).Count -eq 1)

    $timed = New-Fixture 'timed.zig' @'
test "the answer the rule asks for" {
    var deadline = test_util.Deadline.start("the thing this test waits on");
    while (!done()) {
        deadline.tick() catch break;
    }
    var timer = std.time.Timer.start() catch unreachable;
    for (0..30_000) |_| {
        if (timer.read() >= test_util.liveness_ns) break;
        std.Thread.sleep(std.time.ns_per_ms);
    }
}
'@
    Assert 'A5 a clock-bounded wait is NOT reported' (@(Get-TestWaitFindings -Path $timed).Count -eq 0)

    $work = New-Fixture 'work.zig' @'
test "ordinary counted work is not a wait" {
    for (0..1000) |i| {
        try list.append(alloc, i);
    }
}
'@
    Assert 'A6 a counted loop that does not wait is NOT reported' (@(Get-TestWaitFindings -Path $work).Count -eq 0)

    $exempt = New-Fixture 'exempt.zig' @'
fn noClockFallback() void {
    // test-wait-audit: the clock itself is unavailable on this path.
    for (0..512) |_| {
        std.Thread.yield() catch return;
    }
}
'@
    Assert 'A7 a marker WITH a reason waives the site' (@(Get-TestWaitFindings -Path $exempt).Count -eq 0)

    $bare = New-Fixture 'bare-marker.zig' @'
fn silenced() void {
    // test-wait-audit:
    for (0..512) |_| {
        std.Thread.yield() catch return;
    }
}
'@
    Assert 'A8 a bare marker with no reason waives nothing' (@(Get-TestWaitFindings -Path $bare).Count -eq 1)

    "== B. the two files T831 names"

    $conn = Join-Path $Repo 'src\remote\connection.zig'
    $pty = Join-Path $Repo 'src\remote\agent\pty_child.zig'
    $connText = [System.IO.File]::ReadAllText($conn)
    $ptyText = [System.IO.File]::ReadAllText($pty)

    Assert 'B1 connection.zig carries no counted wait' (@(Get-TestWaitFindings -Path $conn).Count -eq 0)
    Assert 'B2 pty_child.zig carries no counted wait' (@(Get-TestWaitFindings -Path $pty).Count -eq 0)
    Assert 'B3 connection.zig no longer declares its own TestDeadline' `
        ($connText -notmatch 'const\s+TestDeadline\s*=\s*struct')
    Assert 'B4 connection.zig waits on the shared helper' `
        ($connText -match 'test_util\.Deadline\.start\(')
    Assert 'B5 pty_child.zig waits on the shared helper' `
        ($ptyText -match 'test_util\.Deadline\.start\(')
    Assert 'B6 pty_child.zig rolls no deadline of its own' `
        ($ptyText -notmatch 'milliTimestamp\(\)\s*\+')

    "== C. the whole src tree"

    $sweep = Invoke-TestWaitSweep -Root (Join-Path $Repo 'src')
    Assert 'C1 the sweep read the tree' ($sweep.Scanned -ge 300) "(scanned $($sweep.Scanned) file(s))"
    $found = @($sweep.Findings)
    if ($found.Count -gt 0) {
        foreach ($f in $found) {
            "      {0}:{1}  {2}" -f $f.File.Substring($Repo.Length + 1), $f.Line, $f.Text
        }
    }
    Assert 'C2 no counted wait anywhere under src' ($found.Count -eq 0) "(found $($found.Count))"

    "== D. one home for the helper"

    $decls = @(Get-ChildItem -Path (Join-Path $Repo 'src') -Recurse -Filter *.zig -File |
        Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match '(?m)^pub const Deadline = struct' })
    Assert 'D1 Deadline is declared exactly once under src' ($decls.Count -eq 1) `
        "(declared in $($decls.Count) file(s))"
    if ($decls.Count -eq 1) {
        Assert 'D2 and that home is src\remote\test_util.zig' `
            ($decls[0].FullName -eq (Join-Path $Repo 'src\remote\test_util.zig'))
    } else {
        Assert 'D2 and that home is src\remote\test_util.zig' $false '(not a single declaration)'
    }
    $agentReexport = [System.IO.File]::ReadAllText((Join-Path $Repo 'src\remote\agent\test_util.zig'))
    Assert 'D3 the agent lane re-exports that same declaration' `
        ($agentReexport -match 'pub const Deadline = shared\.Deadline;')

    if ($NegativeControl) {
        "== N. inverted: a planted counted wait must be REPORTED by the src sweep"
        $probe = Join-Path $Repo 'src\remote\test_util.zig'
        $original = [System.IO.File]::ReadAllText($probe)
        $planted = $original + @'

fn plantedByNegativeControl() void {
    for (0..30_000) |_| {
        std.Thread.sleep(100 * std.time.ns_per_us);
    }
}
'@
        $count = -1
        try {
            [System.IO.File]::WriteAllText($probe, $planted, (New-Object System.Text.UTF8Encoding $false))
            $count = @((Invoke-TestWaitSweep -Root (Join-Path $Repo 'src')).Findings).Count
        } finally {
            [System.IO.File]::WriteAllText($probe, $original, (New-Object System.Text.UTF8Encoding $false))
        }
        Assert 'N1 the planted wait goes unreported (inverted)' ($count -eq 0) `
            "(the sweep found $count, and 1 is the healthy answer)"
        Assert 'N2 the probe file is restored byte for byte' `
            ([System.IO.File]::ReadAllText($probe) -eq $original)
    }
}
catch {
    # T1511: score the throw rather than unwinding past it to a green verdict.
    Assert 'the run finished its sections' $false "(threw: $($_.Exception.Message))"
    $_.ScriptStackTrace
}
finally {
    Remove-Item -Recurse -Force -LiteralPath $fixtureDir -ErrorAction SilentlyContinue
}

# A clean green run stamps the covered files (T783) so scripts\guard-due.ps1 can
# answer "has this sweep been run against the tree as it now stands?".
Complete-TestBody  # T1039: before the stamp, which is a child process reading this run's state
if ($script:failures -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard test-wait-oracle -Repo $Repo 2>&1 | ForEach-Object { "  $_" }
}

""
Write-TestVerdict -Pass $script:passes -Fail $script:failures
