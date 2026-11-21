# BuildFresh.ps1 - T1028. Refuse, BEFORE anything is launched or typed, to
# GRADE a zig-out exe that is older than the sources it is being asked to
# measure.
#
# Dot-sourced by lib\BuildMode.ps1, and called from
# `Assert-GhozttyIsolatedBuild`, so every acceptance script that already gates
# on build MODE now gates on build FRESHNESS too, with no per-script edit.
#
# WHY THIS EXISTS
#
# Every `test\win32\*.ps1` that launches the app defaults `-Exe` to
# `<repo>\zig-out\bin\ghoztty.exe`. Eleven of them run `zig build` first; the
# rest - including the P1-P3 floor - drive whatever copy happens to be on disk.
# Nothing checked that the copy came from the code under test.
#
# The false RED is merely annoying and self-correcting: on 2026-08-20 T316's
# first `relay-account.ps1` run reported 3 FAILURE(S) against an exe built four
# hours earlier, the code was right, and a rebuild made it green.
#
# The false GREEN is the defect. A change that a STALE exe still passes exits 0,
# and since T783 exiting 0 STAMPS the guard - so `scripts\guard-due.ps1`
# afterwards answers "this harness has been run against the code as it stands"
# about an exe that was never built from it. That is the single question the
# stamp exists to answer, and it can be made to lie without anybody acting in
# bad faith.
#
# WHY MTIME, AND NOT THE BAKED COMMIT
#
# `upgrade-staleness` compares a DELIVERED exe's baked commit against
# `git rev-parse HEAD`, which is exactly right for a delivery: what ships must
# be a commit. It is the wrong question here, in both directions:
#
#   * blind to uncommitted work - the state a turn is in for the whole of
#     steps 2-4, which is precisely when acceptance scripts run;
#   * red on a commit that changed nothing - the loop builds, tests, and THEN
#     commits, so at step 6 the exe's baked commit is the parent of HEAD while
#     its bytes are exactly what HEAD's sources produce. A hard refusal there
#     would fire on every turn, and a gate that cries wolf daily gets an
#     `-Allow` bolted onto every caller within a week.
#
# Newest relevant source mtime vs the exe's mtime answers the question actually
# being asked - "was this exe built from the tree as it now stands?" - and it
# answers it for uncommitted edits, for a `git pull` that brings in another
# seat's work (checkout stamps mtimes to now), and for a branch switch.
#
# WHAT COUNTS AS A SOURCE
#
# `build.zig`, `build.zig.zon`, and everything under `src\` EXCEPT `*.md` (a
# docs-only edit builds the same bytes) and `src\apprt\gtk\` (Linux's frontend,
# which this exe cannot contain). 1258 files, ~17ms, cached per process.
#
# BUILD-GRAPH SOURCES ARE COVERED BY A BUILD HAVING RUN (T1564)
#
# `build.zig` and most of `src\build\` are read by zig's BUILD RUNNER, not
# compiled into ghoztty.exe. An edit there that does not change the exe's bytes
# relinks nothing, so the exe's mtime never passes it and the plain
# `zig build` the refusal names could not clear it: T722 had to opt into
# GHOZTTY_TEST_REBUILD_STALE over an edit to src\build\InstallUnlock.zig, and a
# gate whose own remedy does not work teaches the loop to reach for the opt-in.
# So those files form a second mark, the GRAPH mark, judged against whichever
# is newer: the exe, or the build runner zig compiled into
# `<repo>\.zig-cache\o\<hash>\build.exe`. Zig recompiles that runner on the
# first `zig build` after any build-graph edit, so its mtime proves a build has
# read the edit. The few `src\build\` files the exe imports itself (Config.zig
# and its local imports, through src\build_config.zig) stay on the exe's mark,
# and so does build.zig.zon, whose dependencies are compiled into the exe.
# The residual: `zig build agent` alone, after a build.zig edit that DOES
# change the exe's bytes, compiles the runner without rebuilding the exe.
# Every turn's first test step is the Debug `zig build`, which closes it.
#
# THE ONE FALSE POSITIVE, AND ITS EXIT
#
# An edit to a `src\` file that is NOT in this exe's module graph - a Mac-only
# `src\apprt\embedded.zig` change arriving through a main intake, say - raises
# the high-water mark, and the remedial `zig build` then relinks nothing, so the
# exe's mtime does not move and the refusal would not clear. That would be a
# wedge, so the refusal names a second remedy that always terminates:
# `GHOZTTY_TEST_REBUILD_STALE=1` builds and, on success, writes a WITNESS beside
# the exe recording the high-water mark that build covered. A successful build
# IS the proof - relink or no relink - and the witness is what carries that
# proof to the next process. It is tied to the exe's mtime, so the moment the
# exe is rebuilt for real the witness stops applying.
#
# WHAT CATCHES WHAT (with BuildMode.ps1's table)
#
#   Assert-GhozttyIsolatedBuild - these bytes derive the USER'S endpoints.
#   Assert-GhozttyFreshBuild    - these bytes are not the code under test.
#
# Both speak before the first `+new-window`, and both are about the exe rather
# than about anything running, so both work on a cold box.

Set-StrictMode -Off

if (-not (Get-Variable -Name GhozttyFreshCache -Scope Script -ErrorAction SilentlyContinue)) {
    Set-Variable -Name GhozttyFreshCache -Scope Script -Value @{}
}

# Directories under src\ whose contents cannot be in a win32 ghoztty.exe.
$script:GhozttyFreshExcludedDirs = @('\src\apprt\gtk\')

# T1564: build-graph sources - read by the build runner, judged against the
# newest compiled runner as well as the exe. Repo-relative, lower case.
$script:GhozttyFreshGraphDir = 'src\build\'
# ...except these src\build\ files, which the exe itself imports
# (src\build_config.zig -> build/Config.zig -> its local imports).
$script:GhozttyFreshExeGraphBuildFiles = @(
    'src\build\config.zig', 'src\build\xcframework.zig', 'src\build\gtk.zig', 'src\build\gitversion.zig'
)

function Test-GhozttyBuildGraphSource {
    <#
    .SYNOPSIS
    Is this repo-relative path read by the build runner rather than the exe (T1564)?
    #>
    param([Parameter(Mandatory = $true)][string]$Relative)
    $rel = $Relative.TrimStart('\').ToLowerInvariant()
    if ($rel -eq 'build.zig') { return $true }
    if (-not $rel.StartsWith($script:GhozttyFreshGraphDir)) { return $false }
    return ($script:GhozttyFreshExeGraphBuildFiles -notcontains $rel)
}

# T1431: `Invoke-GhozttyDebugBuild` scratches on the repo's drive rather than in
# %TEMP%. The rule lives in one place (scripts\lib\BuildCache.ps1) beside the
# global-cache rule it mirrors, so this file asks for it instead of keeping a
# second copy that would be free to disagree.
. (Join-Path (Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent) 'scripts\lib\BuildCache.ps1')
# Invoke-ZigBuildHealed: the rebuild heals a torn cache entry (T998).
. (Join-Path (Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent) 'scripts\lib\CacheHeal.ps1')

function Get-GhozttyRepoRootForFresh {
    <#
    .SYNOPSIS
    The repo root, derived from this file's location (test\win32\lib\).
    #>
    param([string]$Repo)
    if ($Repo) { return $Repo.TrimEnd('\') }
    return (Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent).TrimEnd('\')
}

function Get-GhozttySourceHighWater {
    <#
    .SYNOPSIS
    The newest mtime among the files that feed a win32 ghoztty.exe.

    .DESCRIPTION
    Returns a PSCustomObject with Time (UTC) and Path - the CODE mark, the
    newest source the exe compiles - plus GraphTime / GraphPath, the newest
    build-graph-only source (T1564; $null when there is none), and Count over
    both, or $null when the tree cannot be read. Enumerated with
    [System.IO.Directory]::EnumerateFiles rather than Get-ChildItem: 1258 files
    in ~17ms, which is cheap enough to sit in front of every acceptance script.
    Cached per repo per process - the tree does not change under a running
    script, and three libraries may ask.
    #>
    param([string]$Repo)

    $root = Get-GhozttyRepoRootForFresh -Repo $Repo
    $key = "high:$root"
    if ($script:GhozttyFreshCache.ContainsKey($key)) { return $script:GhozttyFreshCache[$key] }

    $result = $null
    $srcDir = Join-Path $root 'src'
    if (Test-Path -LiteralPath $srcDir) {
        $newestTime = [datetime]::MinValue
        $newestPath = $null
        $graphTime = [datetime]::MinValue
        $graphPath = $null
        $count = 0
        $prefixLen = $root.Length + 1
        foreach ($f in [System.IO.Directory]::EnumerateFiles($srcDir, '*', 'AllDirectories')) {
            if ($f.EndsWith('.md', [StringComparison]::OrdinalIgnoreCase)) { continue }
            $skip = $false
            foreach ($ex in $script:GhozttyFreshExcludedDirs) {
                if ($f.IndexOf($ex, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $skip = $true; break }
            }
            if ($skip) { continue }
            $count++
            $t = [System.IO.File]::GetLastWriteTimeUtc($f)
            if (Test-GhozttyBuildGraphSource -Relative $f.Substring($prefixLen)) {
                if ($t -gt $graphTime) { $graphTime = $t; $graphPath = $f }
            } elseif ($t -gt $newestTime) { $newestTime = $t; $newestPath = $f }
        }
        foreach ($name in @('build.zig', 'build.zig.zon')) {
            $p = Join-Path $root $name
            if (Test-Path -LiteralPath $p) {
                $count++
                $t = [System.IO.File]::GetLastWriteTimeUtc($p)
                if (Test-GhozttyBuildGraphSource -Relative $name) {
                    if ($t -gt $graphTime) { $graphTime = $t; $graphPath = $p }
                } elseif ($t -gt $newestTime) { $newestTime = $t; $newestPath = $p }
            }
        }
        if ($newestPath -or $graphPath) {
            $result = [pscustomobject]@{
                Time      = $(if ($newestPath) { $newestTime } else { $null })
                Path      = $newestPath
                GraphTime = $(if ($graphPath) { $graphTime } else { $null })
                GraphPath = $graphPath
                Count     = $count
            }
        }
    }

    $script:GhozttyFreshCache[$key] = $result
    return $result
}

function Get-GhozttyBuildRunnerTime {
    <#
    .SYNOPSIS
    When zig last compiled this repo's build runner, as a UTC time, or $null.

    .DESCRIPTION
    T1564. The newest `<repo>\.zig-cache\o\<hash>\build.exe`. Zig compiles a
    new runner (a new hash directory) on the first `zig build` after any edit
    to the build graph, so a runner newer than a build-graph source proves a
    build has read that source - relink or no relink. ~4000 directories in
    ~45ms; cached per repo per process like the high-water scan.
    #>
    param([string]$Repo)
    $root = Get-GhozttyRepoRootForFresh -Repo $Repo
    $key = "runner:$root"
    if ($script:GhozttyFreshCache.ContainsKey($key)) { return $script:GhozttyFreshCache[$key] }
    $newest = $null
    $o = Join-Path $root '.zig-cache\o'
    if ([System.IO.Directory]::Exists($o)) {
        foreach ($d in [System.IO.Directory]::EnumerateDirectories($o)) {
            $b = Join-Path $d 'build.exe'
            if ([System.IO.File]::Exists($b)) {
                $t = [System.IO.File]::GetLastWriteTimeUtc($b)
                if ($null -eq $newest -or $t -gt $newest) { $newest = $t }
            }
        }
    }
    $script:GhozttyFreshCache[$key] = $newest
    return $newest
}

function Get-GhozttyFreshWitnessPath {
    <#
    .SYNOPSIS
    Where the "a build covered this high-water mark" note lives for $Exe.
    #>
    param([Parameter(Mandatory = $true)][string]$Exe)
    return (Join-Path (Split-Path $Exe -Parent) '.build-fresh-witness.json')
}

function Test-GhozttyExeIsRepoBuild {
    <#
    .SYNOPSIS
    Is $Exe the repo's own zig-out build - the only exe this gate speaks about?

    .DESCRIPTION
    An installed release, a portable copy, `zig-out-release`, and the `.cmd`
    stubs an acceptance script writes into $TEMP are all out of scope: none of
    them is claimed to be built from this tree, so "older than src\" says
    nothing about them. Scoping on the path is what keeps this gate from
    inventing a rule for exes it knows nothing about.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [string]$Repo
    )
    if (-not $Exe) { return $false }
    $root = Get-GhozttyRepoRootForFresh -Repo $Repo
    $full = $Exe
    try { $full = [System.IO.Path]::GetFullPath($Exe) } catch { $full = $Exe }
    $zigOut = (Join-Path $root 'zig-out') + '\'
    return $full.StartsWith($zigOut, [StringComparison]::OrdinalIgnoreCase)
}

function Get-GhozttyExeBuildTime {
    <#
    .SYNOPSIS
    When $Exe's bytes were last proved to cover the tree, as a UTC time.

    .DESCRIPTION
    The exe's own mtime, unless a witness written by the -Rebuild path applies:
    a build that relinked nothing still proves the exe covers the sources, and
    the witness is how that proof survives the process that made it. The witness
    only applies while the exe's mtime is the one it was written against, so a
    real rebuild retires it automatically.
    #>
    param([Parameter(Mandatory = $true)][string]$Exe)

    if (-not (Test-Path -LiteralPath $Exe)) { return $null }
    $exeTime = [System.IO.File]::GetLastWriteTimeUtc($Exe)

    $witnessPath = Get-GhozttyFreshWitnessPath -Exe $Exe
    if (Test-Path -LiteralPath $witnessPath) {
        try {
            $w = Get-Content -LiteralPath $witnessPath -Raw | ConvertFrom-Json
            $wExe = [datetime]::Parse($w.exeWriteTimeUtc).ToUniversalTime()
            $wBuilt = [datetime]::Parse($w.builtAtUtc).ToUniversalTime()
            # Sub-second write times survive a round trip through JSON only if
            # both sides use the same format; compare on whole seconds.
            if ([math]::Abs(($wExe - $exeTime).TotalSeconds) -lt 1 -and $wBuilt -gt $exeTime) {
                return $wBuilt
            }
        } catch {
            # A corrupt witness is no witness. Fall through to the exe's mtime.
        }
    }
    return $exeTime
}

function Write-GhozttyFreshWitness {
    <#
    .SYNOPSIS
    Record that a successful build covered the tree as it stands right now.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [Parameter(Mandatory = $true)][datetime]$BuiltAtUtc
    )
    $witness = [pscustomobject]@{
        exe             = $Exe
        exeWriteTimeUtc = ([System.IO.File]::GetLastWriteTimeUtc($Exe)).ToString('o')
        builtAtUtc      = $BuiltAtUtc.ToString('o')
        note            = 'T1028: a zig build that relinked nothing still proves this exe covers the sources.'
    }
    $path = Get-GhozttyFreshWitnessPath -Exe $Exe
    $witness | ConvertTo-Json | Set-Content -LiteralPath $path -Encoding ascii
}

function Invoke-GhozttyDebugBuild {
    <#
    .SYNOPSIS
    Build zig-out the way CLAUDE.md says. Returns $true when zig exits 0.

    .DESCRIPTION
    ZIG_GLOBAL_CACHE_DIR must sit on the repo's drive or zig 0.15.2 asserts
    instead of explaining itself (T243), so it is derived rather than assumed.
    TMP/TEMP go to the repo's drive for the same reason (T1431): zig's C/C++
    compile steps scratch there, %TEMP% is on C: on this box, and a full C:
    makes every build die with a bare `error: Unexpected` that names no disk.
    #>
    param([string]$Repo)

    $root = Get-GhozttyRepoRootForFresh -Repo $Repo
    if (-not $env:ZIG_GLOBAL_CACHE_DIR) {
        $env:ZIG_GLOBAL_CACHE_DIR = (Join-Path (Split-Path -Qualifier $root) '\zig-global-cache')
    }
    Write-Host "  BuildFresh: rebuilding $root (zig build -Dapp-runtime=win32 -Doptimize=Debug)..."
    $ok = $false
    $prevTemp = Push-BuildTempEnv -RepoPath $root
    Push-Location $root
    try {
        # T998: through the shared heal, so a torn cache entry is healed and
        # the build re-run once instead of failing the harness as red code.
        # (It stringifies every record, as lib\StderrCaptureAudit requires.)
        $b = Invoke-ZigBuildHealed -Arguments @('build', '-Dapp-runtime=win32', '-Doptimize=Debug') `
            -RepoPath $root -GlobalCacheDir $env:ZIG_GLOBAL_CACHE_DIR -Label 'BuildFresh rebuild'
        $out = $b.Output
        $ok = ($b.ExitCode -eq 0)
        if (-not $ok) {
            Write-Host "  BuildFresh: the rebuild FAILED (zig exit $($b.ExitCode))."
            foreach ($line in ($out -split "`r?`n" | Where-Object { $_ -match 'error' } | Select-Object -Last 10)) {
                Write-Host "    $line"
            }
        }
    } catch {
        Write-Host "  BuildFresh: the rebuild could not run: $($_.Exception.Message)"
        $ok = $false
    } finally {
        Pop-Location
        Pop-BuildTempEnv -Previous $prevTemp
    }
    return $ok
}

function Test-GhozttyFreshBuild {
    <#
    .SYNOPSIS
    Pure-ish predicate: is $Exe at least as new as the sources it would measure?

    .DESCRIPTION
    Returns a PSCustomObject: Fresh (bool), InScope (bool), ExeTime, HighWater,
    HighWaterPath, DriftSeconds, CoveredBy. Out-of-scope exes report Fresh =
    $true, because this gate has nothing to say about them.

    Two marks (T1564): the CODE mark must be older than the exe; the GRAPH mark
    (build-graph-only sources) must be older than the exe OR the newest
    compiled build runner. When both are stale the CODE drift is the one
    reported, since only a rebuild of the exe clears it. CoveredBy is 'exe', or
    'build-runner' when only the runner covered the graph mark.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [string]$Repo
    )

    $shape = [pscustomobject]@{
        Fresh         = $true
        InScope       = $false
        ExeTime       = $null
        HighWater     = $null
        HighWaterPath = $null
        DriftSeconds  = 0
        CoveredBy     = 'exe'
    }

    if (-not (Test-GhozttyExeIsRepoBuild -Exe $Exe -Repo $Repo)) { return $shape }
    $shape.InScope = $true

    $high = Get-GhozttySourceHighWater -Repo $Repo
    if (-not $high) { return $shape }
    $shape.HighWater = $high.Time
    $shape.HighWaterPath = $high.Path
    if (-not $high.Path) {
        $shape.HighWater = $high.GraphTime
        $shape.HighWaterPath = $high.GraphPath
    }

    $exeTime = Get-GhozttyExeBuildTime -Exe $Exe
    if (-not $exeTime) { return $shape }   # a missing exe is BuildMode's refusal to make
    $shape.ExeTime = $exeTime

    if ($high.Path -and $high.Time -gt $exeTime) {
        $shape.Fresh = $false
        $shape.DriftSeconds = [int]($high.Time - $exeTime).TotalSeconds
        return $shape
    }
    if ($high.GraphPath -and $high.GraphTime -gt $exeTime) {
        $runner = Get-GhozttyBuildRunnerTime -Repo $Repo
        if ($runner -and $runner -ge $high.GraphTime) {
            $shape.CoveredBy = 'build-runner'
        } else {
            $shape.Fresh = $false
            $shape.HighWater = $high.GraphTime
            $shape.HighWaterPath = $high.GraphPath
            $shape.DriftSeconds = [int]($high.GraphTime - $exeTime).TotalSeconds
        }
    }
    return $shape
}

function Assert-GhozttyFreshBuild {
    <#
    .SYNOPSIS
    Throw unless $Exe was built from the tree as it now stands.

    .DESCRIPTION
    Call this before the app under test is launched;
    `Assert-GhozttyIsolatedBuild` already does, so an acceptance script gets it
    for free. Silent on the ordinary green path - the whole point is that a
    fresh run reads exactly as it did before.

    -Rebuild (or GHOZTTY_TEST_REBUILD_STALE=1) builds instead of refusing, and
    records a witness so a build that relinked nothing still clears the drift.
    -Allow (or GHOZTTY_TEST_ALLOW_STALE=1) is the loud hatch for a box that
    cannot build; it prints what it let through, because a run made under it
    has to be explainable afterwards rather than silently excused.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [string]$Repo,
        [switch]$Allow,
        [switch]$Rebuild
    )

    $state = Test-GhozttyFreshBuild -Exe $Exe -Repo $Repo
    if ($state.Fresh) { return }

    $drift = [TimeSpan]::FromSeconds($state.DriftSeconds)
    $driftText = if ($drift.TotalHours -ge 1) { "{0:N1} hours" -f $drift.TotalHours }
                 elseif ($drift.TotalMinutes -ge 1) { "{0:N0} minutes" -f $drift.TotalMinutes }
                 else { "{0:N0} seconds" -f $drift.TotalSeconds }

    if ($Allow -or $env:GHOZTTY_TEST_ALLOW_STALE -eq '1') {
        Write-Host "  BuildFresh: STALE EXE ALLOWED - $Exe is $driftText older than $($state.HighWaterPath)."
        Write-Host "  BuildFresh: whatever this run reports is about the OLD bytes, not the code as it stands."
        return
    }

    if ($Rebuild -or $env:GHOZTTY_TEST_REBUILD_STALE -eq '1') {
        $startedUtc = [datetime]::UtcNow
        if (Invoke-GhozttyDebugBuild -Repo $Repo) {
            # The build read the sources as they are now, so it covers this
            # high-water mark whether or not the linker had anything to do.
            Write-GhozttyFreshWitness -Exe $Exe -BuiltAtUtc ([datetime]::UtcNow)
            $script:GhozttyFreshCache.Clear()
            $after = Test-GhozttyFreshBuild -Exe $Exe -Repo $Repo
            if ($after.Fresh) {
                Write-Host "  BuildFresh: rebuilt, and the exe now covers the tree."
                return
            }
            throw "Assert-GhozttyFreshBuild: rebuilt $Exe but it still reads as stale (sources changed mid-build?). Re-run."
        }
        throw @"
Assert-GhozttyFreshBuild: REFUSING TO RUN. The exe under test
    $Exe
is $driftText older than the sources it would measure, and the rebuild this run
was asked to do FAILED (see the zig errors above). Nothing was launched.
"@
    }

    $exeLocal = ([datetime]$state.ExeTime).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')
    $srcLocal = ([datetime]$state.HighWater).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')
    throw @"
Assert-GhozttyFreshBuild: REFUSING TO RUN. The exe under test
    $Exe
was built at $exeLocal, which is $driftText BEFORE the newest source it would
be measuring:
    $($state.HighWaterPath)   ($srcLocal)

So this run would grade code that is not the code under test. A red would be a
phantom you cannot fix by editing anything, and - the reason this gate exists -
a GREEN would exit 0 and STAMP the harness guard (T783), recording that this
harness has been run against the code as it now stands when it never saw it.

Build it and re-run:
    zig build -Dapp-runtime=win32 -Doptimize=Debug

A build-graph-only source (build.zig, most of src\build\) is cleared by that
build alone, relink or no relink: the build runner it compiles is the proof
(T1564). If the build reports nothing to do for anything else - the edit was
not in this exe's module graph - re-run this script once with the rebuild
opt-in, which records that a build covered these sources:
    `$env:GHOZTTY_TEST_REBUILD_STALE = '1'

If this box genuinely cannot build and you accept a result about the old bytes,
say so explicitly: `$env:GHOZTTY_TEST_ALLOW_STALE = '1'.
"@
}
