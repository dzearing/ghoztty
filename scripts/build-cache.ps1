<#
.SYNOPSIS
    Keep the zig build caches from filling the repo drive (T1054).

.DESCRIPTION
    Zig never evicts its build cache and this project builds all day, so the
    cache grows ~40 GB a day forever. On 2026-08-21 D: reached exactly 0 bytes
    free with 31,359 entries and 1,235 GB in `.zig-cache\o`, and every floor
    lane then died in five seconds with a bare `error: Unexpected` -- which
    reads as broken code, not as a full disk. A turn can burn its whole context
    on that.

    Actions:

      check   Report the cheap health question and exit 0. Never deletes.
      sweep   Report, and CLEAR the caches when they are over a limit. This is
              what `go-loop-exec.ps1 claim` runs once a turn. A clear is
              DEFERRED while a build is using the cache (any zig.exe, or a
              process whose image lives in a cache dir - the build runner and
              test binaries), because the other window or the other loop lane
              may be mid-build (T1061); `-IgnoreBusy` overrides.
      clear   Clear now, whatever the numbers say.
      scratch List every stale scratch directory (leftover `zig-out-*` copies
              and our own dirs under a cache) with its size, when it was first
              seen, and which tracked scripts still name it. Unreferenced ones
              are delete CANDIDATES, printed with the command that removes
              them; nothing here deletes - outside a cache that is the user's
              call (T1062).

    Stale scratch dirs on the `sweep` line are announced only while NEW - for
    -ScratchNewHours after a dir is first seen - so the claim names a dead
    turn's leftover a few times and then stops repeating it every turn (T1062).
    `check` still names all of them.

    `check` and `sweep` also ask whether the fetched packages in the global
    cache look WHOLE, not merely numerous (T1436). On 2026-09-07 the claim
    printed "build cache ok: 1025.8 GB free, 1474 entries" and every build on
    the box was already dead: one package had been half-extracted, and this
    report counted it as an entry like any other. Scanning for that costs ~90ms
    over 1,500 packages and is described in scripts\lib\CacheHeal.ps1.

    They also read every generated source under `c\<hash>\` for the shapes a
    hard reboot leaves (empty, NUL bytes, no trailing newline) (T999). Both
    torn-cache incidents followed an unclean shutdown and were found only when
    a lane went red minutes later; `sweep` - which the claim runs, so it is the
    first thing after a reboot - deletes such an entry so the next build
    regenerates it, and `check` names it.

    Clearing is WHOLE, never by age: pruning `o\` alone leaves Zig's manifests
    in `h\` claiming outputs that no longer exist, and the next build fails
    with `failed to spawn build runner ... FileNotFound`. See
    scripts\lib\BuildCache.ps1 for the full argument and the measurements.

    Exit codes: 0 ok (including "over, and cleared"), 2 error. Being over a
    limit is never a nonzero exit -- this runs inside the claim, and a claim
    that can fail over housekeeping wedges the loop, which is the disease and
    not the cure.

.EXAMPLE
    powershell -NoProfile -File scripts\build-cache.ps1 check
    powershell -NoProfile -File scripts\build-cache.ps1 sweep
    powershell -NoProfile -File scripts\build-cache.ps1 clear -Force
#>
param(
    [Parameter(Position = 0)]
    [ValidateSet('check', 'sweep', 'clear', 'scratch')]
    [string]$Action = 'check',

    [string]$Repo,
    # Cache directories to consider. Default: the repo's `.zig-cache` plus the
    # zig GLOBAL cache, which is a second multi-GB pile on the same drive.
    [string[]]$CacheDir,
    # Clear when free space on a cache's drive is at or below this. 100 GB is
    # about two and a half days of headroom at the measured ~40 GB/day, which
    # is enough for a weekend of unattended loop turns.
    [double]$MinFreeGB = 100,
    # Backstop for a drive so large that free space never trips: 12,000 entries
    # is ~470 GB at the measured average. A cache this size on a roomy drive is
    # still worth dropping, because every zig operation walks it.
    [int]$MaxEntries = 12000,
    [double]$WarnFreeGB = 0,
    # `clear` refuses without this, so a stray invocation cannot cost somebody
    # a cold rebuild. `sweep` does not need it: being over the limit IS the
    # authorization.
    [switch]$Force,
    # Clear even while a build is using the cache (T1061). `sweep` otherwise
    # DEFERS an over-limit clear while any zig, build runner or test binary is
    # alive, and the next claim tries again.
    [switch]$IgnoreBusy,
    # The process names counted as a compiler. Only a harness changes this, to
    # stand a harmless fixture in for zig.exe.
    [string[]]$ZigName = @('zig.exe'),
    [switch]$Json,
    # How long `sweep` keeps announcing a scratch dir after first seeing it.
    [double]$ScratchNewHours = 24
)

$ErrorActionPreference = 'Stop'

if (-not $Repo) { $Repo = Split-Path -Parent $PSScriptRoot }
. (Join-Path $PSScriptRoot 'lib\BuildCache.ps1')
# Get-TornPackage: the integrity half of the cache question (T1436).
. (Join-Path $PSScriptRoot 'lib\CacheHeal.ps1')

if (-not $CacheDir -or $CacheDir.Count -eq 0) {
    $CacheDir = @(
        (Join-Path $Repo '.zig-cache'),
        (Resolve-ZigGlobalCacheDir -RepoPath $Repo)
    )
    # The per-lane caches the parallel floor builds into (T1959): one pile per
    # lane, each growing like the repo cache, so each is swept like it.
    $CacheDir += @(Get-FloorLaneCacheDirs -RepoPath $Repo)
}
# A repo whose global cache resolves onto the repo cache (or a caller passing
# the same path twice) must not be cleared twice and counted twice.
$CacheDir = @($CacheDir | Where-Object { $_ } | Select-Object -Unique)

$scratchState = Join-Path $Repo 'temp\scratch-dirs-seen.json'

if ($Action -eq 'scratch') {
    $all = @(Get-StaleScratchDir -Repo $Repo -CacheDirs $CacheDir)
    $all = @(Update-ScratchDirSeen -Dirs $all -StatePath $scratchState -NewHours $ScratchNewHours)
    if ($all.Count -eq 0) { Write-Host 'stale scratch dirs: none'; exit 0 }
    $candidates = @()
    $totalMB = 0
    Write-Host "stale scratch dirs: $($all.Count)"
    foreach ($d in $all) {
        $bytes = (Get-ChildItem -LiteralPath $d.Path -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
        $mb = [math]::Round(([double]$bytes) / 1MB)
        $totalMB += $mb
        $refs = Get-ScratchDirReference -Repo $Repo -Name $d.Name
        $refFiles = @($refs.Files)
        $refText = if (-not $refs.Known) { 'references unknown (not a git repo)' }
            elseif ($refFiles.Count -eq 0) { 'UNREFERENCED' }
            else { 'named by ' + (($refFiles | Select-Object -First 3) -join ', ') }
        if ($refs.Known -and $refFiles.Count -eq 0) { $candidates += $d }
        Write-Host ("  {0,-24} {1,6} MB  first seen {2}  {3}" -f $d.Name, $mb, $d.FirstSeen.ToString('yyyy-MM-dd'), $refText)
    }
    Write-Host ("  total {0} MB; {1} unreferenced" -f $totalMB, $candidates.Count)
    if ($candidates.Count -gt 0) {
        Write-Host '  delete candidates (outside a cache: confirm before running):'
        foreach ($d in $candidates) { Write-Host "    Remove-Item -LiteralPath '$($d.Path)' -Recurse -Force" }
    }
    exit 0
}

$state = Get-BuildCacheState -CacheDirs $CacheDir -MinFreeGB $MinFreeGB `
    -MaxEntries $MaxEntries -WarnFreeGB $WarnFreeGB
$tempState = Get-SystemTempState -RepoPath $Repo

# Asked of every cache dir that has a `p\`, which in practice is the global
# one. Never fatal and never nonzero, like everything else this script reports:
# a torn package is a thing to NAME before a lane trips over it, and the repair
# is a delete the caller decides on.
$torn = @()
foreach ($dir in $CacheDir) { $torn += @(Get-TornPackage -GlobalCacheDir $dir) }

# T999: the generated SOURCES a hard reboot tears (both observed incidents
# were an options.zig under `c\<hash>\` whose tail was zeros or missing).
# Unlike a package these are cheap to regenerate and certain to break the next
# build, so `sweep` - the claim, the first thing to run after a reboot -
# deletes them; `check` only names them.
$tornGen = @()
foreach ($dir in $CacheDir) { $tornGen += @(Get-TornGeneratedEntry -CacheDir $dir) }

$cleared = @()
$didClear = $false

if ($Action -eq 'clear') {
    if (-not $Force) {
        Write-Host "build cache: refusing to clear without -Force (this costs a cold rebuild)"
        exit 0
    }
    $didClear = $true
} elseif ($Action -eq 'sweep' -and $state.Over) {
    $didClear = $true
}

# T1061: a clear is whole, so it deletes generated files out from under any
# build that is running - in the other Claude window on this repo, or in the
# other loop lane, which shares the global cache. Ask only when about to clear:
# the process walk costs a few hundred ms and the ordinary claim never needs it.
# `sweep` defers (being over the limit is not urgent enough to break a build;
# the next claim retries). `clear -Force` was asked for by a person, so it goes
# ahead but names who it is about to break.
$busy = @()
$deferred = $false
if ($didClear -and -not $IgnoreBusy) {
    $busy = @(Get-BuildCacheUser -CacheDirs $CacheDir -ZigName $ZigName)
    if ($busy.Count -gt 0 -and $Action -eq 'sweep') {
        $didClear = $false
        $deferred = $true
    }
}

if ($didClear) {
    foreach ($dir in $CacheDir) {
        $r = Clear-BuildCache -CacheDir $dir
        $cleared += $r
    }
}

# A whole clear already removed them; otherwise the sweep repairs them here
# (a deferred clear included: the in-flight age window already keeps this from
# touching a file a running build is writing).
$tornGenHealed = 0
if (-not $didClear -and $Action -eq 'sweep' -and $tornGen.Count -gt 0) {
    $tornGenHealed = Invoke-CacheHeal -Entries $tornGen
}

if ($Json) {
    ([ordered]@{
        action  = $Action
        over    = [bool]$state.Over
        reason  = $state.Reason
        deferred = $deferred
        busy    = @($busy | ForEach-Object { [ordered]@{ pid = $_.Pid; name = $_.Name; path = $_.Path } })
        warn    = [bool]$state.Warn
        freeGB  = $state.FreeGB
        entries = $state.Entries
        caches  = @($state.Caches)
        tornPackages = @($torn)
        tornGenerated = @($tornGen | ForEach-Object { [ordered]@{ entry = $_.Entry; file = $_.File; defect = $_.Detail } })
        tornGeneratedHealed = $tornGenHealed
        systemTemp = ([ordered]@{
            path       = $tempState.Path
            drive      = $tempState.Drive
            freeGB     = $tempState.FreeGB
            buildTemp  = $tempState.BuildTemp
            redirected = [bool]$tempState.Redirected
            low        = [bool]$tempState.Low
        })
        cleared = @($cleared)
    } | ConvertTo-Json -Depth 5)
    exit 0
}

if ($didClear) {
    $freed = 0
    $failed = @()
    foreach ($c in $cleared) {
        $freed += $c.FreedGB
        if ($c.Error -and $c.Error -ne 'absent') { $failed += $c }
    }
    $why = if ($Action -eq 'clear') { 'on request' } else { "over limit ($($state.Reason))" }
    Write-Host ("BUILD CACHE CLEARED $why - {0} GB reclaimed, was {1} entries with {2} GB free" -f `
        [math]::Round($freed, 1), $state.Entries, $state.FreeGB)
    foreach ($f in $failed) {
        # Loud, because a partial clear is the dangling-manifest state: `h\`
        # can now name outputs under a half-removed `o\`.
        Write-Host "  PARTIAL: $($f.Path) not fully removed - $($f.Error)"
    }
} elseif ($deferred) {
    $names = ($busy | Select-Object -First 4 | ForEach-Object { "$($_.Name) pid $($_.Pid)" }) -join ', '
    $more = if ($busy.Count -gt 4) { ", +$($busy.Count - 4) more" } else { '' }
    Write-Host ("BUILD CACHE CLEAR DEFERRED: over limit ($($state.Reason)), {0} entries with {1} GB free, but {2} build process(es) are using it ($names$more) - left in place; the next claim tries again" -f `
        $state.Entries, $state.FreeGB, $busy.Count)
} else {
    Write-Host $state.Summary
}
if ($didClear -and $busy.Count -gt 0) {
    $names = ($busy | Select-Object -First 4 | ForEach-Object { "$($_.Name) pid $($_.Pid)" }) -join ', '
    Write-Host "  WARNING: cleared while $($busy.Count) build process(es) were running ($names) - those builds may fail on missing cache files"
}

# T1436: "big" and "healthy" are different questions and only the first one was
# ever asked here. A torn package is silent until a build needs the file that
# went missing, and then it takes every lane down at once with a message that
# names no task and no change.
if (-not $didClear -and $torn.Count -gt 0) {
    Write-Host "  BUILD CACHE TORN: $($torn.Count) fetched package(s) look half-extracted"
    foreach ($t in ($torn | Select-Object -First 5)) {
        Write-Host "    $($t.Reason): $($t.Entry) - $($t.Detail)"
    }
    Write-Host "    delete the named director(y/ies); the next build re-fetches them"
}

if (-not $didClear -and $tornGen.Count -gt 0) {
    $verb = if ($Action -eq 'sweep') { "deleted $tornGenHealed of them; the next build regenerates them" } else { 'delete the named entries (build-cache.ps1 sweep does); the next build regenerates them' }
    Write-Host "  BUILD CACHE TORN: $($tornGen.Count) generated source(s) look half-written - $verb"
    foreach ($t in ($tornGen | Select-Object -First 5)) {
        Write-Host "    $($t.Detail): $($t.File)"
    }
}

# T1431. The cache numbers above are about the REPO drive; zig's C/C++ compile
# steps scratch in %TEMP%, which is a different drive on this box and was
# measured by nothing. A claim that prints "1078 GB free" while C: holds 0.1 GB
# is worse than silence: it is a reassurance that the next bare
# `error: Unexpected` will be read as broken code. So the drive %TEMP% is
# actually on gets a line of its own, and it says whether a build would even be
# affected -- once the build shells scratch on the repo drive, a full C: is a
# heads-up rather than an outage.
if ($tempState.Low -or -not $tempState.Redirected) {
    Write-Host "  $($tempState.Summary)"
}

if ($Action -ne 'clear') {
    $scratch = @(Get-StaleScratchDir -Repo $Repo -CacheDirs $CacheDir)
    $label = 'stale scratch dirs'
    if ($Action -eq 'sweep') {
        # The claim's line: only what is new since it was first seen (T1062).
        $scratch = @(Update-ScratchDirSeen -Dirs $scratch -StatePath $scratchState -NewHours $ScratchNewHours |
            Where-Object { $_.New })
        $label = 'new scratch dirs'
    }
    if ($scratch.Count -gt 0) {
        $names = ($scratch | Select-Object -First 6 | ForEach-Object { $_.Name }) -join ', '
        $more = if ($scratch.Count -gt 6) { ", +$($scratch.Count - 6) more" } else { '' }
        Write-Host "  ${label}: $($scratch.Count) ($names$more) - left alone; build-cache.ps1 scratch lists every leftover and what still names it"
    }
}

exit 0
