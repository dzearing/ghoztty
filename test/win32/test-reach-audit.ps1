# test-reach acceptance (T1191, T1237): a module's unit tests may not sit un-run.
#
#   powershell -NoProfile -File test\win32\test-reach-audit.ps1
#   powershell -NoProfile -File test\win32\test-reach-audit.ps1 -TeethCheck
#
# isolation: none - this builds and runs the win32, none and agent TEST lanes
# (console test binaries out of `.zig-cache`, on the lane desktop) and reads
# their string tables. It launches no Ghoztty, takes no IPC endpoint, and
# touches no user state (T680 meta-check reads this marker).
#
# THE RULE: every `src\apprt\win32\*.zig` that contains a `test` block has that
# block executed by `zig build test -Dapp-runtime=win32` - and (section D)
# every `src\**\*.zig` with one has it executed by some lane, or is exempt.
#
# Why it needs checking at all, and why the check is shaped the way it is, is
# written out in `lib\TestReachAudit.ps1`. The short version: Zig runs a file's
# tests only if the file's container is REFERENCED from an analyzed one, the
# hand-written `test { _ = @import("win32/X.zig"); }` list in
# `src\apprt\win32.zig` is what does the referencing, and a module left off it
# compiles, reads as covered, and is skipped in silence. T1177 measured that on
# `startup_error.zig`: a deliberately broken assertion inside it went GREEN
# through the full lane.
#
# The oracle is the compiled test binary rather than a PowerShell model of Zig's
# reachability rules - see the library header for why a model is the wrong
# answer here specifically.
#
# Sections:
#
#   A. The comparison itself, against fixtures. Cheap, no build: proves the
#      analyzer names a missing module and stays quiet on a complete set.
#   B. The sweep. Builds the lane, reads the binary it ran, and requires the
#      missing set to be EMPTY. Reports the covered count as a number.
#   D. The whole tree (T1237). Builds the `none` and `agent` lanes too and
#      requires every `src\**\*.zig` with a test block to be in at least one
#      lane's binary or under a declared exemption - and every exemption to be
#      still true (an exempt module a lane runs is red).
#   C. The negative control the rule is worth nothing without, in every run.
#      It plants a test-bearing file nothing references under
#      `src\apprt\win32\` and under `src\os\`, and requires sections B and D's
#      comparisons to go red NAMING them - then deletes them. `-TeethCheck`
#      adds a real win32 rebuild over the plants, proving the lane itself stays
#      green over a test that fails by construction (minutes, not routine).
param(
    [string]$Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path,
    [switch]$TeethCheck
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\TestReachAudit.ps1')
. (Join-Path $Repo 'scripts\lib\LaneVerdict.ps1')

$script:failures = 0
$script:passes = 0

function Assert($name, $cond, $detail = '') {
    if ($cond) { "  PASS $name"; $script:passes++ }
    else { "  FAIL $name$(if ($detail) { " -- $detail" })"; $script:failures++ }
}

$tmp = Join-Path $env:TEMP "ghoztty-t1191-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

# ===========================================================================
'== A: the comparison, against fixtures'
# ===========================================================================

$fa = Get-TestReachFindings -WithTests @('alpha', 'beta', 'gamma') -InBinary @('alpha', 'beta', 'gamma')
Assert 'A1 a complete set yields no finding' (@($fa.Missing).Count -eq 0) `
    ("named: " + (@($fa.Missing) -join ', '))

$fb = Get-TestReachFindings -WithTests @('alpha', 'beta', 'gamma') -InBinary @('alpha', 'gamma')
Assert 'A2 a module the binary never heard of is named' `
    ((@($fb.Missing) -join ',') -eq 'beta') ("named: " + (@($fb.Missing) -join ', '))

# A module in the binary with no test block on disk should be impossible. It is
# reported rather than assumed away, because the way it would actually arise -
# a stale binary being read - is the one failure that could make section B pass
# over a tree it never measured.
$fc = Get-TestReachFindings -WithTests @('alpha') -InBinary @('alpha', 'ghost')
Assert 'A3 a binary-only module is reported, not swallowed' `
    ((@($fc.Extra) -join ',') -eq 'ghost') ("named: " + (@($fc.Extra) -join ', '))

# The source scan reads the tree, so it is checked against the tree: the four
# modules T1191 found are all real files with real test blocks, and the scan
# must see every one of them.
$withTests = @(Get-WinModulesWithTests $Repo)
Assert "A4 the source scan finds win32 modules with tests ($($withTests.Count))" `
    ($withTests.Count -ge 150) "found $($withTests.Count)"
foreach ($m in @('AgentIntegrationsDialog', 'ipc_agent_integration', 'provenance', 'restore_retry', 'startup_error')) {
    Assert "A5 the scan sees $m" ($withTests -contains $m)
}

# The whole-tree reader (T1237), against hand-made name runs. A tiny tree:
# `os.zig` is a file AND `os\` a directory, `os\power.zig` and `os\path.zig`
# carry tests, and so does `config\path.zig`.
$ft = [pscustomobject]@{
    WithTests = @('os', 'os.power', 'os.path', 'config.path')
    All = (New-Object System.Collections.Generic.HashSet[string])
    Dirs = (New-Object System.Collections.Generic.HashSet[string])
}
foreach ($n in @('os', 'os.power', 'os.path', 'os.quiet', 'config.path')) { [void]$ft.All.Add($n) }
foreach ($n in @('os', 'config')) { [void]$ft.Dirs.Add($n) }

# The previous test's name is glued to the front, dots and all.
$r6 = @(Get-SrcModulesInRuns -Runs @('version 1.2os.power') -Tree $ft)
Assert 'A6 a module behind a glued, dotted test-name tail is found' `
    ((@($r6) -join ',') -eq 'os.power') ("found: " + ($r6 -join ', '))
# A test inside a struct carries the struct's name before `.test`.
$r7 = @(Get-SrcModulesInRuns -Runs @('xconfig.path.Path') -Tree $ft)
Assert 'A7 a test nested in a struct credits its file' `
    ((@($r7) -join ',') -eq 'config.path') ("found: " + ($r7 -join ', '))
# `os.power`'s tests are not `os.zig`'s: a following segment that is a FILE
# belongs to the file below. `os.zig` is credited only by its own test.
$r8 = @(Get-SrcModulesInRuns -Runs @('os.power') -Tree $ft)
Assert 'A8 a submodule''s test does not credit the file above it' `
    (-not ($r8 -contains 'os')) ("found: " + ($r8 -join ', '))
$r9 = @(Get-SrcModulesInRuns -Runs @('aos') -Tree $ft)
Assert 'A9 the file above is credited by its own unnamed test' `
    ((@($r9) -join ',') -eq 'os') ("found: " + ($r9 -join ', '))

$fx = @([pscustomobject]@{ Prefix = 'apprt.gtk.*'; Why = 'linux' },
        [pscustomobject]@{ Prefix = 'build'; Why = 'own lane' })
$f10 = Get-TreeReachFindings -WithTests @('apprt.gtk', 'apprt.gtk.key', 'apprt.gtkish', 'build', 'build.x', 'build_config') `
    -InLanes @() -Exemptions $fx
Assert 'A10 an exemption covers its prefix and below (`.*`: below only), never a look-alike sibling' `
    (((@($f10.Missing) | Sort-Object) -join ',') -eq 'apprt.gtk,apprt.gtkish,build_config' -and
     ((@($f10.Exempt) | Sort-Object) -join ',') -eq 'apprt.gtk.key,build,build.x') `
    ("missing: " + (@($f10.Missing) -join ', ') + "; exempt: " + (@($f10.Exempt) -join ', '))
$f11 = Get-TreeReachFindings -WithTests @('apprt.gtk.key') -InLanes @('apprt.gtk.key') -Exemptions $fx
Assert 'A11 an exempt module that a lane runs is reported stale' (@($f11.Stale).Count -eq 1) `
    ("stale: " + (@($f11.Stale) -join ', '))

# ===========================================================================
'== B: the sweep - every win32 module with tests is in the lane'
# ===========================================================================

$buildLog = Join-Path $tmp 'lane.log'
$lane = Resolve-WinTestBinary -Repo $Repo -LogPath $buildLog
# A red lane names the test that failed and where, not only the log (T1734):
# this row is read out of a sweep's summary, where the kept temp dir is one
# path among forty and the reason has to travel in the message itself.
$b1Why = "zig build test exited $($lane.ExitCode)"
if ($lane.ExitCode -ne 0) {
    $b1Detail = Get-LaneFailureDetail -LaneName 'win32' -LogPath $buildLog -MaxTraceLines 40
    if ($b1Detail.FailedTest) { $b1Why += "; failed test: '$($b1Detail.FailedTest)'" }
    # The test's own frame (the line inside the test that failed) over the
    # trace's origin, which is usually a shared helper such as `waitFor`.
    $b1Frames = @($b1Detail.Trace | Where-Object { $_ -match ':\d+:\d+: 0x' })
    $b1At = @($b1Frames | Where-Object { $_ -match ' in test\.' }) | Select-Object -Last 1
    if (-not $b1At) { $b1At = $b1Frames | Select-Object -First 1 }
    if ($b1At) { $b1Why += "; at: $(([string]$b1At).Trim() -replace ':? 0x[0-9a-f]+ in .*$', '')" }
}
Assert 'B1 the win32 test lane builds and passes' ($lane.ExitCode -eq 0) `
    "$b1Why; log: $buildLog"
Assert 'B2 the lane names the test binary it ran' `
    ($lane.ExePath -and (Test-Path -LiteralPath $lane.ExePath)) "path: $($lane.ExePath)"

$inBinary = @()
if ($lane.ExePath -and (Test-Path -LiteralPath $lane.ExePath)) {
    $inBinary = @(Get-WinModulesInTestBinary $lane.ExePath)
}
Assert "B3 the binary names the modules whose tests it carries ($($inBinary.Count))" `
    ($inBinary.Count -ge 150) "found $($inBinary.Count)"

$found = Get-TestReachFindings -WithTests $withTests -InBinary $inBinary
$missing = @($found.Missing)
Assert 'B4 no win32 module has tests the lane never runs' ($missing.Count -eq 0) `
    ("un-run: " + ($missing -join ', ') + " -- add `_ = @import(""win32/<name>.zig"");` to src\apprt\win32.zig's test block")
Assert 'B5 the binary carries no module that has no test block on disk' `
    (@($found.Extra).Count -eq 0) ("stale binary? " + (@($found.Extra) -join ', '))

"  NOTE $($withTests.Count) win32 modules carry tests; $($inBinary.Count) of them run in the lane"

# ===========================================================================
'== D: the whole tree - every src module with tests runs in some lane (T1237)'
# ===========================================================================
# The win32 binary from section B, plus the other two lanes this box runs. Each
# is that lane's own verified build, newer than every source: reused when the
# floor lanes already left one (`Find-FreshLaneBinary`), built here otherwise.
$tree = Get-SrcTestTree $Repo
$srcNewest = Get-SourceNewestWriteUtc $Repo
$laneBins = [ordered]@{ win32 = $lane }
foreach ($spec in @(@('none', 'test -Dapp-runtime=none', 'ghostty-test.exe'),
                    @('agent', 'test-agent', 'ghoztty-agent-test.exe'))) {
    $fresh = Find-FreshLaneBinary -Repo $Repo -Lane $spec[0] -NotBeforeUtc $srcNewest
    if ($fresh) {
        "  NOTE $($spec[0]) lane: reusing $($fresh.Path) (built $($fresh.WriteUtc.ToLocalTime()), after every source)"
        $laneBins[$spec[0]] = [pscustomobject]@{ ExitCode = 0; ExePath = $fresh.Path }
    } else {
        "  NOTE $($spec[0]) lane: no fresh build to reuse - building it"
        $laneBins[$spec[0]] = Invoke-LaneTestBuild -Repo $Repo -LogPath (Join-Path $tmp "$($spec[0]).log") `
            -BuildArgs $spec[1] -ExeName $spec[2]
    }
}

$inLanes = New-Object System.Collections.Generic.HashSet[string]
$perLane = [ordered]@{}
foreach ($name in $laneBins.Keys) {
    $lb = $laneBins[$name]
    $ok = ($lb.ExitCode -eq 0) -and $lb.ExePath -and (Test-Path -LiteralPath $lb.ExePath)
    Assert "D1 the $name lane's binary is present (and passed, where built here)" $ok `
        "exit $($lb.ExitCode); path: $($lb.ExePath); log under $tmp"
    $mods = @()
    if ($lb.ExePath -and (Test-Path -LiteralPath $lb.ExePath)) {
        $mods = @(Get-SrcModulesInTestBinary -ExePath $lb.ExePath -Tree $tree)
    }
    $perLane[$name] = $mods.Count
    foreach ($m in $mods) { [void]$inLanes.Add($m) }
}
# Floors, so a reader that silently stops matching cannot pass as an empty
# tree: the agent lane alone carries well over a hundred modules.
Assert "D2 the reader finds the agent lane's modules ($($perLane['agent']))" ($perLane['agent'] -ge 100)
Assert "D3 the reader finds the none lane's modules ($($perLane['none']))" ($perLane['none'] -ge 300)

$tf = Get-TreeReachFindings -WithTests @($tree.WithTests) -InLanes @($inLanes)
Assert 'D4 no src module has tests that no lane runs' (@($tf.Missing).Count -eq 0) `
    ("un-run: " + (@($tf.Missing) -join ', ') + " -- reference it from its directory's test aggregator, or add an exemption that says where it runs")
Assert 'D5 no exemption covers a module a lane runs' (@($tf.Stale).Count -eq 0) `
    ("stale: " + (@($tf.Stale) -join '; '))
Assert 'D6 no lane carries a module with no test block on disk' (@($tf.Extra).Count -eq 0) `
    ("stale binary? " + (@($tf.Extra) -join ', '))

"  NOTE $(@($tree.WithTests).Count) src modules carry tests; $($inLanes.Count) run in a lane (" +
    (($perLane.Keys | ForEach-Object { "$_ $($perLane[$_])" }) -join ', ') +
    "); $(@($tf.Exempt).Count) exempt"

# ===========================================================================
'== C: the negative control - a planted violator must turn both sweeps red'
# ===========================================================================
# A test-bearing file that nothing references, written into the real tree:
# one under `src\apprt\win32\` (section B's rule) and one under `src\os\`
# (section D's). Each test FAILS if it ever runs, so a lane that passes with
# them planted is the defect itself, measured - the file compiles into nothing,
# looks covered, and cannot go red.
#
# Planted rather than wounded. Until T1237 this removed `provenance.zig`'s line
# from `src\apprt\win32.zig` and rebuilt, on the grounds that T1191 had
# measured the list as its only route. By 2026-10-23 it no longer was -
# provenance had picked up a second route and the control went red against a
# correct sweep - and T1237's own first control (`os\power.zig`) was wrong the
# same way from the start, because the agent lane reaches it. A hand-picked
# "only route" rots silently; a file nothing references has none by
# construction. It needs no rebuild to be scored: a file no build references
# cannot be in any binary, so sections B and D's binaries are the right
# oracle. `-TeethCheck` rebuilds the win32 lane over the plants anyway, to show
# the lane itself staying green over a failing test.
$probeName = "zz_reach_probe_$PID"
$probeBody = "test ""T1237 reach probe - must never run"" { try @import(""std"").testing.expect(false); }`n"
$probes = @(
    (Join-Path $Repo "src\apprt\win32\$probeName.zig"),
    (Join-Path $Repo "src\os\$probeName.zig")
)
try {
    foreach ($p in $probes) { [System.IO.File]::WriteAllText($p, $probeBody) }

    $cWin = Get-TestReachFindings -WithTests @(Get-WinModulesWithTests $Repo) -InBinary $inBinary
    Assert 'C1 the win32 sweep names the planted module' (@($cWin.Missing) -contains $probeName) `
        ("named: " + (@($cWin.Missing) -join ', '))
    $cTree = Get-SrcTestTree $Repo
    $cAll = Get-TreeReachFindings -WithTests @($cTree.WithTests) -InLanes @($inLanes)
    Assert 'C2 the whole-tree sweep names both planted modules, and nothing else' `
        (((@($cAll.Missing) | Sort-Object) -join ',') -eq "apprt.win32.$probeName,os.$probeName") `
        ("named: " + (@($cAll.Missing) -join ', '))

    if ($TeethCheck) {
        $tlane = Resolve-WinTestBinary -Repo $Repo -LogPath (Join-Path $tmp 'teeth.log')
        $tin = @()
        if ($tlane.ExePath -and (Test-Path -LiteralPath $tlane.ExePath)) {
            $tin = @(Get-WinModulesInTestBinary $tlane.ExePath)
        }
        # The whole subject of the bug: the LANE still passes, over a test that
        # fails by construction. If it went red on its own, no sweep would be
        # needed.
        Assert 'C3 the lane still passes with a failing test planted (which is the defect)' `
            ($tlane.ExitCode -eq 0) "zig build test exited $($tlane.ExitCode)"
        Assert 'C4 the rebuilt binary does not carry the planted module' `
            ($tin.Count -ge 150 -and -not ($tin -contains $probeName)) "found $($tin.Count)"
    }
} catch {
    # An unwind here must score, not skip to the verdict (T1039).
    "  FAIL C0 the planted control did not run to the end -- $_"
    $script:failures++
} finally {
    foreach ($p in $probes) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
    Assert 'C5 the planted files are gone' (-not (@($probes | Where-Object { Test-Path -LiteralPath $_ }).Count))
}

# --- stamp (T783 / T478) ---------------------------------------------------
# Only a CLEAN run stamps; a red one must stay due.
Complete-TestBody  # T1039: before the stamp, which is a child process reading this run's state
if ($script:failures -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard test-reach -Repo $Repo 2>&1 | ForEach-Object { "  $_" }
}

# A red run KEEPS its temp dir. B1's failure message names `lane.log` as the
# place to look, and this line used to delete it a few milliseconds later - so
# the one artifact that explains the failure was destroyed by the script
# pointing at it, and four consecutive reds were diagnosed by racing a copier
# against this `Remove-Item`. A green run still cleans up.
if ($script:failures -eq 0) {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
} else {
    "  kept for diagnosis: $tmp"
}

''
Write-TestVerdict -Pass $script:passes -Fail $script:failures
