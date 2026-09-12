<#
.SYNOPSIS
    T702 acceptance - a Zig test may not spawn a thread it can return without
    joining.

.DESCRIPTION
    THE DEFECT (T693, then T702's own sweep of `src\remote\connection.zig`):

        const ath = try std.Thread.spawn(.{}, InboundAgentCtx.run, .{&ictx});
        try conn.start();          // <- any failure here returns, leaking `ath`
        _ = try conn.waitHandshake();
        ath.join();

    The spawned thread outlives the test body, parked on a read into a stack
    local this frame's defers are about to free. What the run then prints is a
    hang or an unrelated 0xAAAA.. panic instead of the assertion that failed -
    and it only happens on a run that was ALREADY red.

    T693 fixed two sites by hand; T702 was filed to sweep the rest of the file.
    By the time it was picked up the sweep had already landed in a667007a7
    (T536) and all 17 test-local spawn sites in `connection.zig` were guarded.
    So what was actually missing is this: the rule, machine-checked. A hand
    audit that finds nothing is indistinguishable from a hand audit nobody
    re-runs, and the same class was still open in nine other files.

    Four sections:

      A. The analyzer (`lib\ThreadJoinAudit.ps1`) against fixtures, BOTH
         directions: the T693 guard shape yields nothing, the unconditional
         join yields nothing, and each violating shape is named by kind. Also
         the exemption - a `// thread-join-audit: <reason>` marker waives a
         site, and a bare marker with no reason waives nothing.

      B. `src\remote\connection.zig` is CLEAN. This is the assertion T702 owed:
         the file the task names, checked rather than remembered.

      C. The ratchet over all of `src`. Nine other files carry the same
         defect (31 sites, measured 2026-09-12) and fixing them is T1505's job,
         not this run's - so the sweep is scored against a recorded baseline of
         per-file counts. A file ABOVE its baseline is a new defect and fails. A
         file BELOW it fails too, naming `-UpdateBaseline`: a ratchet that only
         tightens when somebody remembers to tighten it drifts back into a
         wishlist. A file with findings and NO baseline entry fails, so a newly
         added file cannot arrive already excused.

      D. The scope claim itself: the sweep has to have looked at the whole
         tree, and it must report nothing for production spawns (the ones whose
         handle a struct field owns and a teardown joins). An audit that cried
         about those is an audit nobody would leave switched on.

    `-TeethCheck` proves B and C can fail: it plants each violating shape into
    a throwaway copy of the tree and requires the assertions to score red. Run
    it after any change to the analyzer.

    `-UpdateBaseline` rewrites `thread-join-audit.baseline.json` from the
    current sweep. Use it in the commit that fixes sites, never to make a red
    run go green.

    One ALL PASS / N FAILURE(S) line last, per the house convention.

.NOTES
    # persistence: launches no GUI - this reads source files, it does not build
    # or run anything.
#>
[CmdletBinding()]
param(
    [switch]$TeethCheck,
    [switch]$UpdateBaseline
)

$ErrorActionPreference = 'Continue'
$Repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\ThreadJoinAudit.ps1')

$script:pass = 0
$script:fail = 0
function Assert([string]$name, [bool]$cond) {
    if ($cond) { Write-Host "  PASS $name"; $script:pass++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:fail++ }
}
function AssertEq([string]$name, $expected, $actual) {
    if ($expected -eq $actual) { Write-Host "  PASS $name"; $script:pass++ }
    else {
        Write-Host "  FAIL $name (expected '$expected', got '$actual')" -ForegroundColor Red
        $script:fail++
    }
}

$tmp = Join-Path $env:TEMP "ghoztty-t702-$PID"
if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force $tmp | Out-Null

$BaselinePath = Join-Path $PSScriptRoot 'thread-join-audit.baseline.json'

# Analyze a fixture written from a zig snippet. The snippet is a whole file's
# worth of text, so a fixture can state its own top-level shape.
function Get-FixtureFindings([string]$Body, [string]$Tag) {
    $f = Join-Path $tmp "$Tag.zig"
    Set-Content -LiteralPath $f -Encoding utf8 -Value ($Body -replace "`r`n", "`n")
    return @(Get-ThreadJoinFindings -Path $f)
}

# The shape under test, parameterised on the guard. Every fixture is a real
# zig-fmt'd top-level test block, because "closes with } in column 0" is part of
# what the analyzer relies on.
$guarded = @'
test "guarded: the T693 disarming errdefer" {
    var ctx: Ctx = .{};
    const ath = try std.Thread.spawn(.{}, Ctx.run, .{&ctx});
    var ath_joined = false;
    errdefer if (!ath_joined) {
        conn.shutdown();
        ath.join();
    };

    try conn.start();
    _ = try conn.waitHandshake();
    ath.join();
    ath_joined = true;
    try testing.expect(ctx.err == null);
}
'@

$unguarded = @'
test "unguarded: a try between the spawn and the join" {
    var ctx: Ctx = .{};
    const ath = try std.Thread.spawn(.{}, Ctx.run, .{&ctx});

    try conn.start();
    ath.join();
    try testing.expect(ctx.err == null);
}
'@

$unconditional = @'
test "unconditional: nothing between the spawn and the join can return" {
    var ctx: Ctx = .{};
    const ath = try std.Thread.spawn(.{}, Ctx.run, .{&ctx});
    ctx.gate.set();
    ath.join();
    try testing.expect(ctx.err == null);
}
'@

$neverJoined = @'
test "never joined: the thread outlives the body on every path" {
    var ctx: Ctx = .{};
    const ath = try std.Thread.spawn(.{}, Ctx.run, .{&ctx});
    try testing.expect(ctx.err == null);
}
'@

$detached = @'
test "detached: the handle is discarded" {
    var ctx: Ctx = .{};
    _ = try std.Thread.spawn(.{}, Ctx.run, .{&ctx});
    try testing.expect(ctx.err == null);
}
'@

$doubleJoin = @'
test "double join: a plain defer plus an explicit join" {
    var ctx: Ctx = .{};
    const ath = try std.Thread.spawn(.{}, Ctx.run, .{&ctx});
    defer ath.join();

    try conn.start();
    ath.join();
}
'@

$deferOnly = @'
test "defer only: joined on every path, once" {
    var ctx: Ctx = .{};
    const ath = try std.Thread.spawn(.{}, Ctx.run, .{&ctx});
    defer ath.join();

    try conn.start();
    try testing.expect(ctx.err == null);
}
'@

$arrayLoop = @'
test "array: a partial spawn is guarded before the loop" {
    var threads: [4]std.Thread = undefined;
    var spawned: usize = 0;
    errdefer if (spawned < 4) {
        conn.shutdown();
        for (threads[0..spawned]) |t| t.join();
    };
    for (&workers, 0..) |*w, i| {
        threads[i] = try std.Thread.spawn(.{}, Worker.run, .{w});
        spawned = i + 1;
    }
    for (threads) |t| t.join();
    try testing.expect(true);
}
'@

$waived = @'
test "waived: a stated reason exempts the site" {
    var ctx: Ctx = .{};
    // thread-join-audit: the loop exits on ctx.gate, which cannot fail
    const ath = try std.Thread.spawn(.{}, Ctx.run, .{&ctx});

    try conn.start();
    ath.join();
}
'@

$bareMarker = @'
test "bare marker: no reason, no exemption" {
    var ctx: Ctx = .{};
    // thread-join-audit:
    const ath = try std.Thread.spawn(.{}, Ctx.run, .{&ctx});

    try conn.start();
    ath.join();
}
'@

$productionField = @'
const Watcher = struct {
    thread: ?std.Thread = null,

    pub fn start(self: *Watcher) void {
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch |err| {
            log.warn("no thread: {s}", .{@errorName(err)});
            return;
        };
    }

    pub fn stop(self: *Watcher) void {
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }
};

test "a test that spawns nothing" {
    try testing.expect(true);
}
'@

$fieldNeverJoined = @'
const Leaker = struct {
    worker: ?std.Thread = null,

    pub fn start(self: *Leaker) !void {
        self.worker = try std.Thread.spawn(.{}, run, .{self});
    }
};

test "a test that spawns nothing" {
    try testing.expect(true);
}
'@

# ===========================================================================
Write-Host ''
Write-Host '== A: the analyzer, both directions'
# ===========================================================================

$f = @(Get-FixtureFindings $guarded 'a-guarded')
AssertEq 'A1 the T693 disarming errdefer yields nothing' 0 $f.Count

$f = @(Get-FixtureFindings $unconditional 'a-unconditional')
AssertEq 'A2 a join with nothing fallible before it yields nothing' 0 $f.Count

$f = @(Get-FixtureFindings $deferOnly 'a-defer-only')
AssertEq 'A3 a plain defer with no inline join yields nothing' 0 $f.Count

$f = @(Get-FixtureFindings $arrayLoop 'a-array')
AssertEq 'A4 the guarded spawn loop yields nothing' 0 $f.Count

$f = @(Get-FixtureFindings $unguarded 'a-unguarded')
AssertEq 'A5 the defect is reported' 1 $f.Count
Assert 'A6 and named as unguarded, with the handle' (
    $f.Count -eq 1 -and $f[0].Kind -eq 'unguarded' -and $f[0].Handle -eq 'ath')
Assert 'A7 and it names the line that can return' (
    $f.Count -eq 1 -and $f[0].Detail -match 'line 5 can return')

$f = @(Get-FixtureFindings $neverJoined 'a-never')
Assert 'A8 a handle never joined at all is reported' (
    $f.Count -eq 1 -and $f[0].Kind -eq 'never-joined')

$f = @(Get-FixtureFindings $detached 'a-detached')
Assert 'A9 a discarded handle is reported' (
    $f.Count -eq 1 -and $f[0].Kind -eq 'detached')

$f = @(Get-FixtureFindings $doubleJoin 'a-double')
Assert 'A10 a plain defer plus an inline join is reported (the second join is UB)' (
    $f.Count -eq 1 -and $f[0].Kind -eq 'double-join')

$f = @(Get-FixtureFindings $waived 'a-waived')
AssertEq 'A11 a stated reason exempts the site' 0 $f.Count

$f = @(Get-FixtureFindings $bareMarker 'a-bare')
Assert 'A12 a marker with no reason exempts nothing' (
    $f.Count -eq 1 -and $f[0].Kind -eq 'unguarded')

$f = @(Get-FixtureFindings $productionField 'a-field-ok')
AssertEq 'A13 a field the teardown joins through its payload capture yields nothing' 0 $f.Count

$f = @(Get-FixtureFindings $fieldNeverJoined 'a-field-leak')
Assert 'A14 a field nothing in the file ever joins is reported' (
    $f.Count -eq 1 -and $f[0].Kind -eq 'field-never-joined')

$f = @(Get-FixtureFindings ($guarded + "`n" + $unguarded) 'a-both')
Assert 'A15 one bad site among good ones is still the only finding' (
    $f.Count -eq 1 -and $f[0].Kind -eq 'unguarded')

# ===========================================================================
Write-Host ''
Write-Host '== B: connection.zig is clean (the assertion T702 owed)'
# ===========================================================================

$connPath = Join-Path $Repo 'src\remote\connection.zig'
Assert 'B0 the file is where the rule says it is' (Test-Path -LiteralPath $connPath)
$conn = @(Get-ThreadJoinFindings -Path $connPath)
AssertEq 'B1 no unjoined spawn in any connection.zig test block' 0 $conn.Count
foreach ($x in $conn) { Write-Host "      $($x.Line) $($x.Kind) $($x.Handle): $($x.Detail)" }

# The scope claim: B1 has to be scoring something. connection.zig's test blocks
# hold 17 test-local spawn sites - an analyzer that found none of them would
# also report none of them unguarded.
$connLines = @(Get-Content -LiteralPath $connPath -Encoding UTF8)
$connSites = 0
foreach ($b in @(Get-ThreadJoinBlocks -Lines $connLines)) {
    if ($b.End -lt 0) { continue }
    for ($i = $b.Start; $i -le $b.End; $i++) {
        if ($connLines[$i] -match 'std\.Thread\.spawn') { $connSites++ }
    }
}
Assert "B2 and it looked at every spawn site in them (found $connSites)" ($connSites -ge 17)

# ===========================================================================
Write-Host ''
Write-Host '== C: the ratchet over src'
# ===========================================================================

$sweep = @(Get-ThreadJoinSweep -Root (Join-Path $Repo 'src'))
$current = @{}
foreach ($x in $sweep) {
    $rel = Get-ThreadJoinRelativePath -Path $x.Path -Repo $Repo
    if (-not $current.ContainsKey($rel)) { $current[$rel] = 0 }
    $current[$rel] = $current[$rel] + 1
}

if ($UpdateBaseline) {
    $obj = [ordered]@{
        note      = 'Per-file counts of thread-join-audit findings not yet fixed. May only go DOWN, and the run that lowers one rewrites this file with -UpdateBaseline. See docs/design/windows-parity-tasks/T1505.md.'
        generated = (Get-Date -Format 'yyyy-MM-dd')
        files     = [ordered]@{}
    }
    foreach ($k in ($current.Keys | Sort-Object)) { $obj.files[$k] = $current[$k] }
    ($obj | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $BaselinePath -Encoding utf8
    Write-Host "  baseline rewritten: $($current.Keys.Count) file(s), $($sweep.Count) site(s)"
}

Assert 'C0 the baseline exists' (Test-Path -LiteralPath $BaselinePath)
$baseFiles = @{}
if (Test-Path -LiteralPath $BaselinePath) {
    $base = Get-Content -LiteralPath $BaselinePath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($p in $base.files.PSObject.Properties) { $baseFiles[$p.Name] = [int]$p.Value }
}

$regressed = New-Object System.Collections.ArrayList
$improved = New-Object System.Collections.ArrayList
foreach ($k in ($current.Keys | Sort-Object)) {
    $was = 0
    if ($baseFiles.ContainsKey($k)) { $was = $baseFiles[$k] }
    if ($current[$k] -gt $was) { [void]$regressed.Add("$k ($was -> $($current[$k]))") }
    elseif ($current[$k] -lt $was) { [void]$improved.Add("$k ($was -> $($current[$k]))") }
}
foreach ($k in ($baseFiles.Keys | Sort-Object)) {
    if (-not $current.ContainsKey($k) -and $baseFiles[$k] -gt 0) {
        [void]$improved.Add("$k ($($baseFiles[$k]) -> 0)")
    }
}

foreach ($r in $regressed) { Write-Host "      NEW: $r" -ForegroundColor Red }
AssertEq 'C1 no file has gained an unjoined spawn' 0 $regressed.Count
if ($regressed.Count -gt 0) {
    foreach ($x in $sweep) {
        $rel = Get-ThreadJoinRelativePath -Path $x.Path -Repo $Repo
        if ($regressed -match [regex]::Escape($rel)) {
            Write-Host "      $rel`:$($x.Line) $($x.Kind) $($x.Handle): $($x.Detail)"
        }
    }
}

foreach ($i in $improved) { Write-Host "      FIXED: $i" }
Assert 'C2 the baseline matches what is actually in the tree (-UpdateBaseline after a fix)' (
    $improved.Count -eq 0)

# ===========================================================================
Write-Host ''
Write-Host '== D: the sweep is scoped the way the rule says'
# ===========================================================================

$zigCount = @(Get-ChildItem -LiteralPath (Join-Path $Repo 'src') -Filter *.zig -File -Recurse).Count
Assert "D1 the sweep walked the whole tree ($zigCount .zig files)" ($zigCount -ge 300)

$kinds = @($sweep | ForEach-Object { $_.Kind } | Sort-Object -Unique)
Assert "D2 every finding is one of the declared kinds ($($kinds -join ', '))" (
    @($kinds | Where-Object { (Get-ThreadJoinHardKinds) -notcontains $_ }).Count -eq 0)

# The win32 frontend interleaves tests with production code and spawns threads
# from both. Nothing in it may be reported: every one of its spawns is a field a
# teardown joins, and a rule that could not tell those apart would be reporting
# ~20 correct sites.
$win32 = @($sweep | Where-Object {
        (Get-ThreadJoinRelativePath -Path $_.Path -Repo $Repo) -like 'src\apprt\win32\*' })
AssertEq 'D3 no production spawn in the win32 frontend is reported' 0 $win32.Count
foreach ($x in $win32) { Write-Host "      $($x.Path):$($x.Line) $($x.Kind)" }

# ===========================================================================
if ($TeethCheck) {
    Write-Host ''
    Write-Host '== T: the teeth (B1, C1 and D3 must be able to score red)'
    # =======================================================================
    $fake = Join-Path $tmp 'repo'
    New-Item -ItemType Directory -Force (Join-Path $fake 'src\remote') | Out-Null
    New-Item -ItemType Directory -Force (Join-Path $fake 'src\apprt\win32') | Out-Null

    # B1's teeth: the real connection.zig with ONE guard removed.
    $lines = @(Get-Content -LiteralPath $connPath -Encoding UTF8)
    $out = New-Object System.Collections.ArrayList
    $stripped = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if (-not $stripped -and $lines[$i] -match '^\s*errdefer if \(!ath_joined\) \{') {
            $indent = ($lines[$i] -replace '\S.*$', '')
            # Drop the errdefer block: the opener, its body, and its `};`.
            $j = $i
            while ($j -lt $lines.Count -and $lines[$j] -notmatch "^$indent\};") { $j++ }
            $i = $j
            $stripped = $true
            continue
        }
        [void]$out.Add($lines[$i])
    }
    Assert 'T0 the fixture actually removed a guard' $stripped
    $wounded = Join-Path $fake 'src\remote\connection.zig'
    Set-Content -LiteralPath $wounded -Encoding utf8 -Value $out
    $t = @(Get-ThreadJoinFindings -Path $wounded)
    Assert 'T1 a connection.zig with one guard removed is reported' (
        @($t | Where-Object { $_.Kind -eq 'unguarded' }).Count -ge 1)

    # C1's teeth: a file the baseline does not know about, carrying the defect.
    Set-Content -LiteralPath (Join-Path $fake 'src\remote\newcomer.zig') -Encoding utf8 `
        -Value ($unguarded -replace "`r`n", "`n")
    $t = @(Get-ThreadJoinSweep -Root (Join-Path $fake 'src'))
    $newcomer = @($t | Where-Object { $_.Path -like '*newcomer.zig' })
    AssertEq 'T2 a new file arriving with the defect is reported by the sweep' 1 $newcomer.Count
    Assert 'T3 and it has no baseline entry, so the ratchet scores it' (
        -not $baseFiles.ContainsKey('src\remote\newcomer.zig'))

    # D3's teeth: the exemption is narrow, not a blanket for the directory.
    Set-Content -LiteralPath (Join-Path $fake 'src\apprt\win32\wounded.zig') -Encoding utf8 `
        -Value ($unguarded -replace "`r`n", "`n")
    $t = @(Get-ThreadJoinSweep -Root (Join-Path $fake 'src\apprt\win32'))
    AssertEq 'T4 a win32 TEST block with the defect is still reported' 1 $t.Count
}

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

Complete-TestBody  # T1039: the run reached the end of its body

# --- stamp (T783) ----------------------------------------------------------
# Only a CLEAN green run records the covered files, and never a teeth check -
# that run plants violators, so its verdict says nothing about the tree as it
# stands.
if ($script:fail -eq 0 -and -not $TeethCheck) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard thread-join -Repo $Repo 2>&1 |
        ForEach-Object { Write-Host "  $($_.ToString())" }
}

Write-Host ''
Write-Host "  sweep: $($sweep.Count) site(s) still unguarded across $($current.Keys.Count) file(s) (baseline; T1505 works them down)"
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Label 'THREAD JOIN AUDIT' -MinPass 20
