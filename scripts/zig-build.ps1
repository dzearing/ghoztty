<#
.SYNOPSIS
    `zig build <args>` from the repo, with the torn-cache heal every other build
    path has (T998).

.DESCRIPTION
    A bare `zig build` that trips over a half-written cache entry reports it as
    red code, and the diagnosis -- read the error, notice the file lives under
    `.zig-cache\c\<hash>\`, delete the entry, build again -- has been paid by
    hand more than once. This is the same build with that diagnosis already
    made: on a red run whose log blames a torn cache entry it deletes exactly
    that entry, loudly, and builds ONCE more. The second verdict is final, so a
    genuine compile error still fails, just as it would have.

    It also sets the two environment variables a Windows build here needs and
    a fresh shell never has: ZIG_GLOBAL_CACHE_DIR on the repo's drive (T243)
    and TMP/TEMP on the repo's drive for the build only (T1431).

    Everything after the script name is passed to `zig build` verbatim:

        powershell -NoProfile -File scripts\zig-build.ps1 -Dapp-runtime=win32 -Doptimize=Debug
        powershell -NoProfile -File scripts\zig-build.ps1 test -Dapp-runtime=none

    There is no param block on purpose: every `-D...` flag has to reach zig
    untouched, and a declared parameter set would try to bind them.

    Output streams as zig writes it. Exit code is zig's (of the final run).
    Acceptance: section T998 of test\win32\floor-lane-cache-heal.ps1.
#>

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'lib\BuildCache.ps1')
. (Join-Path $PSScriptRoot 'lib\CacheHeal.ps1')

# GHOZTTY_ZIG_BUILD_EXE / _PREFIX: the acceptance harness's stand-in for zig,
# so the heal can be driven end to end without a real torn cache. The prefix
# carries the stand-in's own arguments (a powershell -File script) ahead of
# the forwarded ones; neither is for everyday use.
$zigExe = if ($env:GHOZTTY_ZIG_BUILD_EXE) { $env:GHOZTTY_ZIG_BUILD_EXE } else { 'zig' }
$zigArgs = @()
if ($env:GHOZTTY_ZIG_BUILD_PREFIX) { $zigArgs += @($env:GHOZTTY_ZIG_BUILD_PREFIX -split '\|') }
$zigArgs += 'build'
$zigArgs += @($args | ForEach-Object { [string]$_ })

$env:ZIG_GLOBAL_CACHE_DIR = Resolve-ZigGlobalCacheDir -RepoPath $repo
$prevTemp = Push-BuildTempEnv -RepoPath $repo
try {
    $r = Invoke-ZigBuildHealed -Arguments $zigArgs -RepoPath $repo `
        -GlobalCacheDir $env:ZIG_GLOBAL_CACHE_DIR -ZigExe $zigExe -Label 'zig-build' -Stream
}
finally {
    Pop-BuildTempEnv -Previous $prevTemp
}
if ($r.Healed) {
    $verdict = if ($r.ExitCode -eq 0) { 'PASSED' } else { 'FAILED (final)' }
    Write-Host "zig-build: healed a torn cache entry and re-ran; the re-run $verdict (first run's log: $($r.FirstLog))"
}
exit $r.ExitCode
