# TestReachAudit (T1191) - which win32 modules' unit tests the lane ACTUALLY
# runs, measured against which ones have tests at all.
#
# THE RULE:
#
#     Every `src\apprt\win32\*.zig` that contains a `test` block has that test
#     block executed by `zig build test -Dapp-runtime=win32`.
#
# Why the rule needs a sweep rather than a reviewer. Zig only analyzes - and
# therefore only RUNS - the tests of a file whose container is referenced from
# an analyzed one. `src\apprt\win32.zig` carries a hand-written
#
#     test { _ = @import("win32/X.zig"); }
#
# block, and reachability through THAT chain is what pulls a win32 module's
# tests into the lane. Ordinary imports do not: `startup_error.zig` was
# imported and used by `App.zig`, compiled by every lane, carried five unit
# tests, and a deliberately broken assertion inside one of them ran GREEN
# through the full lane and through `-Dtest-filter` both (T1177). Adding one
# line to that list made the identical tree go red. Nothing else in the repo
# measures the difference, so a module added without its line is silently
# uncovered for as long as nobody breaks one of its tests on purpose.
#
# ---------------------------------------------------------------------------
# The oracle is the COMPILED BINARY, not a model of the compiler.
#
# The obvious sweep - "has tests but is not named in `win32.zig`'s list" -
# reports ~130 files and is wrong: a listed module carries its own test-block
# imports, so plenty of unlisted files are reached transitively and do run. The
# next-most-obvious sweep - re-implement Zig's reachability in PowerShell - is
# wrong in a worse way: it would be a MODEL of the rule, and a model that
# drifts from the compiler fails exactly the way this task exists to stop. The
# first draft of it scored all 174 files as unreachable, because `src\main.zig`
# references its entrypoint by IDENTIFIER rather than by a literal `@import`,
# and `refAllDecls(@This())` is a third shape again.
#
# So this asks the compiler instead. Zig names every test after the file it
# came from (`apprt.win32.<module>.test.<name>`), those names are string data
# in the test binary, and a test that was never analyzed contributes no name.
# Scanning the binary for `apprt.win32.<module>.test` therefore answers "which
# modules' tests are in this lane" exactly, with no semantics of Zig's
# re-implemented here. When Zig changes how reachability works, the sweep
# follows for free.
#
# ---------------------------------------------------------------------------
# Scope, stated rather than implied: `src\apprt\win32\*.zig`, non-recursive
# (there are no subdirectories today), against the win32 lane alone.
#
# ---------------------------------------------------------------------------
# THE WHOLE-TREE RULE (T1237):
#
#     Every `src\**\*.zig` that contains a `test` block has that block in at
#     least one of the three lanes this box runs - `none`, `win32`, `agent` -
#     or sits under a declared exemption that says where else it runs.
#
# The shared core reaches its lanes through the same hand-written aggregator
# shape (`src\os\main.zig`'s `test { _ = x; }` list, and so on), so it has the
# same silence: when T1237 first measured it, `os\desktop.zig` was imported,
# used, carried a test, and was in no lane's binary - `src\os\main.zig`'s list
# had never named it. Union over lanes, not per lane, because a core module
# legitimately runs in whichever lane imports it: `os\power.zig` is in neither
# the win32 nor the none binary and runs in the agent lane, and only the agent
# lane reaches `remote\agent\`. Measuring two lanes instead of three reported
# `os\power.zig` as un-run too, which is the mistake the union exists to avoid.
#
# The name a module has in the binary is its path under `src\`, dotted, with
# no extension: every test root this box builds (`main.zig`, `agent_main.zig`)
# sits directly in `src\`. Two shapes make reading it back harder than the
# win32 regex:
#
#   - Test names are packed end to end with no separator, so the bytes in
#     front of `os.power.test.x` are the TAIL of the previous test's name, and
#     that tail can hold dots (`... 1.2`). The reader therefore tries every
#     start inside the run, and accepts only paths that exist under `src\`.
#   - A test inside a struct is named after the struct too
#     (`config.path.Path.test.parse`), so a module counts as present when its
#     path is followed by `.test`, by `.decltest`, by an unnamed `.test_N`, or
#     by a declaration name - but NOT by a segment that is itself a file under
#     it, which would credit `apprt.zig` with `apprt\win32.zig`'s tests.

# Where a test-bearing module runs if not in one of this box's three lanes.
# Each row is a dotted-path PREFIX and the reason, and a row is checked in the
# other direction too: an exempted module that DOES turn up in a lane is
# reported (`Stale`), so an exemption cannot outlive the reason for it.
$script:TestReachExemptions = @(
    [pscustomobject]@{ Prefix = 'apprt.gtk.*'; Why = 'the Linux GTK frontend; no Windows lane compiles it (apprt\gtk.zig itself is compiled, and runs)' }
    [pscustomobject]@{ Prefix = 'font.face.coretext'; Why = 'CoreText, macOS only' }
    [pscustomobject]@{ Prefix = 'font.shaper.coretext'; Why = 'CoreText, macOS only' }
    [pscustomobject]@{ Prefix = 'input.KeymapDarwin'; Why = 'the macOS keymap' }
    [pscustomobject]@{ Prefix = 'os.mach'; Why = 'Darwin only (os\main.zig references it under isDarwin)' }
    [pscustomobject]@{ Prefix = 'os.macos'; Why = 'Darwin only (os\main.zig references it under isDarwin)' }
    [pscustomobject]@{ Prefix = 'os.kernel_info'; Why = 'Linux only (os\main.zig references it under .linux)' }
    [pscustomobject]@{ Prefix = 'renderer.metal'; Why = 'Metal, macOS only' }
    [pscustomobject]@{ Prefix = 'build'; Why = 'src\build\ runs in ghoztty-build-helpers-test, rooted at src\build\, whose own sweep (T736) fails the lane on an unreached file' }
    [pscustomobject]@{ Prefix = 'lib_vt'; Why = 'libghostty-vt; runs in `zig build test-lib-vt`, which no floor lane on this box builds (T2193)' }
    [pscustomobject]@{ Prefix = 'terminal.c'; Why = 'libghostty-vt C API; runs in `zig build test-lib-vt`, which no floor lane on this box builds (T2193)' }
    [pscustomobject]@{ Prefix = 'remote_test_client_main'; Why = 'the root of its own test-client exe, not of any test lane' }
    [pscustomobject]@{ Prefix = 'comp_spike_main'; Why = 'the root of the T2360 comp-spike exe, not of any test lane; its scoring module runs in the win32 lane (apprt\win32\comp_spike_stats.zig)' }
)

Set-StrictMode -Version Latest

# CrashCatch for its lane-verified binary resolver (T855/T952), and through it
# LaneDesktop (T1813).
. (Join-Path $PSScriptRoot '..\..\..\scripts\lib\CrashCatch.ps1')

# Every win32 module that CONTAINS a test block, by module name (the basename
# Zig uses in a test's fully qualified name).
#
# Plain line matching, no comment stripping, and that is not a shortcut: a
# commented-out test reads `// test "x" {` so the `//` already precedes the
# keyword, and a `test` line inside a Zig multiline string is prefixed `\\`.
# Neither can match `^[ \t]*test\b`.
function Get-WinModulesWithTests([string]$Repo) {
    $dir = Join-Path $Repo 'src\apprt\win32'
    $out = New-Object System.Collections.ArrayList
    foreach ($f in (Get-ChildItem -LiteralPath $dir -Filter *.zig -File | Sort-Object Name)) {
        $text = [System.IO.File]::ReadAllText($f.FullName)
        if ($text -match '(?m)^[ \t]*test\b') {
            [void]$out.Add([System.IO.Path]::GetFileNameWithoutExtension($f.Name))
        }
    }
    return $out
}

# Every module whose tests are present in a compiled test binary, read out of
# the test-name string data. Latin-1 rather than UTF-8 on purpose: this is a
# byte scan of an executable, not text, and Latin-1 is the decoding that maps
# every byte to exactly one char so offsets and ASCII runs survive intact.
# By codepage rather than `[Text.Encoding]::Latin1`, which is .NET 5+ and this
# box's Windows PowerShell 5.1 does not have it.
function Get-WinModulesInTestBinary([string]$ExePath) {
    $bytes = [System.IO.File]::ReadAllBytes($ExePath)
    $blob = [System.Text.Encoding]::GetEncoding(28591).GetString($bytes)
    $seen = New-Object System.Collections.Generic.HashSet[string]
    foreach ($m in [regex]::Matches($blob, 'apprt\.win32\.([A-Za-z0-9_]+)\.(?:test|decltest)')) {
        [void]$seen.Add($m.Groups[1].Value)
    }
    $out = New-Object System.Collections.ArrayList
    foreach ($n in ($seen | Sort-Object)) { [void]$out.Add($n) }
    return $out
}

# Build the win32 test lane and hand back the path of the binary it ran.
#
# `--verbose` prints the run command, which names the cache path of the test
# exe - so the binary this reads is THE binary the lane ran, rather than a
# freshly emitted lookalike or the newest thing in `.zig-cache`. Building via
# the lane's own command also means the sweep cannot pass over a tree that does
# not compile.
#
# The redirect goes through `cmd`, not through PowerShell (T883): the build's
# verbose output is on STDERR, and a PowerShell `2>` / `*>` of a native
# command's stderr formats every line as an ErrorRecord on its way to disk, at
# a width that depends on the host. This function then reads that file as a
# TEXT ORACLE - it is looking for a path inside it - which is exactly the shape
# that rule exists for. `cmd` writes the child's own bytes and PowerShell never
# holds an object, the same proven-good shape `cli-unknown-flag.ps1` uses.
function Resolve-WinTestBinary {
    param([string]$Repo, [string]$LogPath)
    return (Invoke-LaneTestBuild -Repo $Repo -LogPath $LogPath `
            -BuildArgs 'test -Dapp-runtime=win32' -ExeName 'ghostty-test.exe')
}

# The build cache must sit on the repo's drive (T243): Zig 0.15's build runner
# cannot relativize a path across drives and asserts instead of saying so.
function Get-ZigGlobalCacheDir([string]$Repo) {
    $cur = $env:ZIG_GLOBAL_CACHE_DIR
    $drive = [System.IO.Path]::GetPathRoot((Resolve-Path -LiteralPath $Repo).Path)
    if ($cur -and ([System.IO.Path]::GetPathRoot($cur) -eq $drive)) { return $cur }
    return (Join-Path $drive 'zig-global-cache')
}

# The finding set: modules with tests that the lane never ran. `Missing` is the
# defect; `Extra` is a module named by the binary with no test block on disk,
# which should be impossible and is reported rather than assumed away.
function Get-TestReachFindings {
    param([string[]]$WithTests, [string[]]$InBinary)
    $bin = New-Object System.Collections.Generic.HashSet[string]
    foreach ($m in $InBinary) { [void]$bin.Add($m) }
    $src = New-Object System.Collections.Generic.HashSet[string]
    foreach ($m in $WithTests) { [void]$src.Add($m) }

    $missing = New-Object System.Collections.ArrayList
    foreach ($m in $WithTests) { if (-not $bin.Contains($m)) { [void]$missing.Add($m) } }
    $extra = New-Object System.Collections.ArrayList
    foreach ($m in $InBinary) { if (-not $src.Contains($m)) { [void]$extra.Add($m) } }

    return [pscustomobject]@{ Missing = $missing; Extra = $extra }
}

# ===========================================================================
# The whole-tree rule (T1237). See the header for the rule and the name shape.
# ===========================================================================

# Every module under `src\` by dotted path, which of them carry a test block,
# and every directory prefix - the last is what lets the binary reader keep
# extending `remote` -> `remote.agent` -> `remote.agent.mux` through path
# segments that are directories rather than files. Same line match as
# `Get-WinModulesWithTests`, for the same reasons.
function Get-SrcTestTree([string]$Repo) {
    $src = Join-Path $Repo 'src'
    $withTests = New-Object System.Collections.ArrayList
    $all = New-Object System.Collections.Generic.HashSet[string]
    $dirs = New-Object System.Collections.Generic.HashSet[string]
    foreach ($f in (Get-ChildItem -LiteralPath $src -Recurse -Filter *.zig -File | Sort-Object FullName)) {
        $rel = $f.FullName.Substring($src.Length + 1)
        $fq = ($rel -replace '\.zig$', '') -replace '\\', '.'
        [void]$all.Add($fq)
        $parts = $fq.Split('.')
        for ($i = 1; $i -lt $parts.Length; $i++) { [void]$dirs.Add(($parts[0..($i - 1)] -join '.')) }
        if ([System.IO.File]::ReadAllText($f.FullName) -match '(?m)^[ \t]*test\b') { [void]$withTests.Add($fq) }
    }
    return [pscustomobject]@{ WithTests = $withTests; All = $all; Dirs = $dirs }
}

# The test-name runs of a compiled test binary: for every `.test.` /
# `.decltest.` / `.test_<n>` in its bytes, the run of name characters in front
# of it. Latin-1 for the reason `Get-WinModulesInTestBinary` gives.
function Get-TestNameRuns([string]$ExePath) {
    $bytes = [System.IO.File]::ReadAllBytes($ExePath)
    $blob = [System.Text.Encoding]::GetEncoding(28591).GetString($bytes)
    $runs = New-Object System.Collections.Generic.HashSet[string]
    foreach ($m in [regex]::Matches($blob, '\.(?:test|decltest)(?:\.|_[0-9])')) {
        $start = $m.Index - 1
        while ($start -ge 0 -and ($m.Index - $start) -lt 400) {
            $c = [int]$blob[$start]
            if (($c -ge 97 -and $c -le 122) -or ($c -ge 65 -and $c -le 90) -or
                ($c -ge 48 -and $c -le 57) -or $c -eq 95 -or $c -eq 46 -or $c -eq 45) { $start-- } else { break }
        }
        [void]$runs.Add($blob.Substring($start + 1, $m.Index - $start - 1))
    }
    return ,$runs
}

# Which test-bearing modules of `$Tree` a set of name runs carries. Every start
# position in the run is tried (the front of a run is the previous test's
# name), a candidate is extended one segment at a time only while it is still a
# path under `src\`, and a match followed by a segment that is a FILE under it
# is not a match - that test belongs to the file below.
function Get-SrcModulesInRuns {
    param($Runs, $Tree)
    $hasTests = New-Object System.Collections.Generic.HashSet[string]
    foreach ($m in $Tree.WithTests) { [void]$hasTests.Add($m) }
    $hit = New-Object System.Collections.Generic.HashSet[string]
    foreach ($run in $Runs) {
        $segs = $run.Split('.')
        for ($s = 0; $s -lt $segs.Length; $s++) {
            $seg = $segs[$s]
            for ($k = 0; $k -lt $seg.Length; $k++) {
                $p = $seg.Substring($k)
                for ($e = $s; $e -lt $segs.Length; $e++) {
                    if ($e -gt $s) {
                        if (-not $Tree.Dirs.Contains($p)) { break }
                        $p = $p + '.' + $segs[$e]
                    }
                    if (-not $hasTests.Contains($p)) { continue }
                    if (($e + 1) -lt $segs.Length -and $Tree.All.Contains($p + '.' + $segs[$e + 1])) { continue }
                    [void]$hit.Add($p)
                }
            }
        }
    }
    $out = New-Object System.Collections.ArrayList
    foreach ($n in ($hit | Sort-Object)) { [void]$out.Add($n) }
    return $out
}

function Get-SrcModulesInTestBinary {
    param([string]$ExePath, $Tree)
    return (Get-SrcModulesInRuns -Runs (Get-TestNameRuns $ExePath) -Tree $Tree)
}

# The exemption a module falls under, or $null. A prefix matches itself and
# anything below it (`build` covers `build.LaneStamp`), never a sibling that
# merely shares the letters (`build` does not cover `build_config`). A prefix
# ending `.*` covers only what is below it: `apprt.gtk.*` leaves `apprt\gtk.zig`
# itself to the rule, because a lane compiles that file and runs its tests.
function Get-TestReachExemption([string]$Module, $Exemptions = $script:TestReachExemptions) {
    foreach ($x in $Exemptions) {
        if ($x.Prefix.EndsWith('.*')) {
            if ($Module.StartsWith($x.Prefix.Substring(0, $x.Prefix.Length - 1))) { return $x }
        } elseif ($Module -eq $x.Prefix -or $Module.StartsWith($x.Prefix + '.')) { return $x }
    }
    return $null
}

# The whole-tree finding set. `Missing`: test-bearing, in no lane, not exempt -
# the defect. `Exempt`: in no lane and covered by an exemption (reported as a
# count). `Stale`: exempt AND present in a lane, so the exemption's reason no
# longer holds. `Extra`: in a binary, no test block on disk (a stale binary).
function Get-TreeReachFindings {
    param([string[]]$WithTests, [string[]]$InLanes, $Exemptions = $script:TestReachExemptions)
    $lane = New-Object System.Collections.Generic.HashSet[string]
    foreach ($m in $InLanes) { [void]$lane.Add($m) }
    $src = New-Object System.Collections.Generic.HashSet[string]
    foreach ($m in $WithTests) { [void]$src.Add($m) }

    $missing = New-Object System.Collections.ArrayList
    $exempt = New-Object System.Collections.ArrayList
    $stale = New-Object System.Collections.ArrayList
    foreach ($m in $WithTests) {
        $x = Get-TestReachExemption $m $Exemptions
        if ($lane.Contains($m)) {
            if ($x) { [void]$stale.Add("$m (exempt as '$($x.Prefix)': $($x.Why))") }
        } elseif ($x) { [void]$exempt.Add($m) } else { [void]$missing.Add($m) }
    }
    $extra = New-Object System.Collections.ArrayList
    foreach ($m in $InLanes) { if (-not $src.Contains($m)) { [void]$extra.Add($m) } }
    return [pscustomobject]@{ Missing = $missing; Exempt = $exempt; Stale = $stale; Extra = $extra }
}

# Build one lane by its own command and hand back the binary it ran
# (`Resolve-WinTestBinary` is this for win32).
#
# On the LANE DESKTOP (T1813), not the caller's: the lane's tests open windows
# - twelve banner overlays per win32 run, measured - and a build started from
# here inherits whatever desktop this script is on, which until T1237 was the
# user's whenever the harness floor ran it. `Start-LaneRedirected` is `cmd`
# doing the redirect, so the T883 reason above still holds.
function Invoke-LaneTestBuild {
    param([string]$Repo, [string]$LogPath, [string]$BuildArgs, [string]$ExeName)

    $env:ZIG_GLOBAL_CACHE_DIR = (Get-ZigGlobalCacheDir $Repo)
    $p = Start-LaneRedirected -FilePath 'zig' -ArgumentLine "build $BuildArgs -Doptimize=Debug --verbose" `
        -StdOut $LogPath -WorkingDirectory $Repo
    $p.WaitForExit()
    $code = $p.ExitCode

    $exe = $null
    $pat = '(?<p>[^ "'']*' + [regex]::Escape($ExeName) + ')'
    foreach ($line in [System.IO.File]::ReadAllLines($LogPath)) {
        $m = [regex]::Match($line, $pat)
        if ($m.Success) { $exe = $m.Groups['p'].Value; break }
    }
    if ($exe -and -not [System.IO.Path]::IsPathRooted($exe)) {
        $exe = [System.IO.Path]::GetFullPath((Join-Path $Repo $exe))
    }
    return [pscustomobject]@{ ExitCode = $code; ExePath = $exe }
}

# The newest moment any source a test binary is built from was written: every
# `.zig` under `src\` plus the build files. A binary linked after this cannot
# be missing a test file that exists now.
function Get-SourceNewestWriteUtc([string]$Repo) {
    $newest = [datetime]::MinValue
    $items = @(Get-ChildItem -LiteralPath (Join-Path $Repo 'src') -Recurse -Filter *.zig -File) +
        @(Get-Item -LiteralPath (Join-Path $Repo 'build.zig'), (Join-Path $Repo 'build.zig.zon') -ErrorAction SilentlyContinue)
    foreach ($i in $items) { if ($i.LastWriteTimeUtc -gt $newest) { $newest = $i.LastWriteTimeUtc } }
    return $newest
}

# A lane's own test binary that is already built and newer than every source,
# or $null. Section D reads the `none` and `agent` lanes this way first: the
# floor lanes (step 3 of a turn, run just before the harness) leave exactly
# these binaries in `zig-lanes\<lane>`, and building them again here would
# triple this harness's run past the harness floor's per-script timeout.
#
# "This lane's binary" is CrashCatch's `Resolve-LaneTestBinary` (T855/T952):
# the stamp and the lane's own test-name markers, so the other lane's
# same-named `ghostty-test.exe` and a `-Dtest-filter` build are both refused.
# "Fresh" is the write time against `Get-SourceNewestWriteUtc`. When neither
# root has one, the caller builds.
function Find-FreshLaneBinary {
    param([string]$Repo, [ValidateSet('none', 'win32', 'agent')][string]$Lane, [datetime]$NotBeforeUtc)
    $best = $null
    foreach ($root in @((Join-Path $Repo "zig-lanes\$Lane"), $Repo)) {
        if (-not (Test-Path -LiteralPath (Join-Path $root '.zig-cache\o'))) { continue }
        foreach ($e in @(Resolve-LaneTestBinary -Lane $Lane -Repo $root)) {
            if (-not $e.Ok) { continue }
            $t = (Get-Item -LiteralPath $e.Path).LastWriteTimeUtc
            if ($t -ge $NotBeforeUtc -and (-not $best -or $t -gt $best.WriteUtc)) {
                $best = [pscustomobject]@{ Path = $e.Path; WriteUtc = $t }
            }
        }
    }
    return $best
}
