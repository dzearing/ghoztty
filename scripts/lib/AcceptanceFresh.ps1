# AcceptanceFresh.ps1 - T1961. Settle whether zig-out is the code under test
# ONCE, before the first acceptance script of a run starts.
#
# Every acceptance script already refuses a stale exe on its own
# (test\win32\lib\BuildFresh.ps1, T1028, through Assert-GhozttyIsolatedBuild).
# That refusal is right and stays. What it cannot do is stop the RUN: under
# scripts\acceptance-parallel.ps1 each of four workers met the same stale exe,
# each refused (or, under GHOZTTY_TEST_REBUILD_STALE, each started its own
# `zig build` under the other workers' hard-linked zig-out), and the turn read
# a page of red rows about one cause. And the refusal only fires in scripts
# that launch the app; build-fresh-guard.ps1, the harness that proves the gate,
# runs inside the harness floor - after the GUI tests have already been
# measured. T1936 paid 10-30 minutes for exactly that re-run.
#
# So the runner asks first, about the one exe every worker will hard-link:
#   fresh             nothing to do, nothing printed beyond one line.
#   stale or missing  rebuild once (Debug, the BuildFresh way) and record the
#                     witness, so a build that relinks nothing still clears the
#                     drift; refuse the whole run if the build fails.
#   -NoRebuild        refuse instead of building, naming the drift.
# A refusal means NOTHING was launched - the caller exits before its first job.

Set-StrictMode -Off

. (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'test\win32\lib\BuildFresh.ps1')

function Get-AcceptanceDrift {
    # Seconds as a readable span, for the one line the preflight prints.
    param([int]$Seconds)
    $d = [TimeSpan]::FromSeconds($Seconds)
    if ($d.TotalHours -ge 1) { return ("{0:N1} hours" -f $d.TotalHours) }
    if ($d.TotalMinutes -ge 1) { return ("{0:N0} minutes" -f $d.TotalMinutes) }
    return ("{0:N0} seconds" -f $d.TotalSeconds)
}

function Invoke-AcceptanceFreshPreflight {
    <#
    .SYNOPSIS
    Is <Repo>\zig-out\bin\ghoztty.exe built from the tree as it stands? Rebuild
    it once if not. Returns { Ok, State, Line }.

    .DESCRIPTION
    State is 'fresh', 'rebuilt', 'refused' or 'allowed'. Ok is false only for
    'refused', and then nothing may be launched. -Builder is the build to run
    (default: BuildFresh's Invoke-GhozttyDebugBuild); it returns $true on
    success, and the harness passes a stand-in so the stale case can be played
    without compiling anything. GHOZTTY_TEST_ALLOW_STALE=1 is honoured exactly
    as the per-script gate honours it - loudly.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Repo,
        [switch]$NoRebuild,
        [scriptblock]$Builder
    )
    $exe = Join-Path $Repo 'zig-out\bin\ghoztty.exe'
    $script:GhozttyFreshCache.Clear()
    $missing = -not (Test-Path -LiteralPath $exe)
    $state = $null
    if (-not $missing) { $state = Test-GhozttyFreshBuild -Exe $exe -Repo $Repo }
    if (-not $missing -and $state.Fresh) {
        return [pscustomobject]@{ Ok = $true; State = 'fresh'; Line = "BUILD FRESH zig-out covers the tree (newest source $(Split-Path -Leaf $state.HighWaterPath))" }
    }

    $what = if ($missing) { "zig-out has no ghoztty.exe" }
            else { "zig-out\bin\ghoztty.exe is $(Get-AcceptanceDrift $state.DriftSeconds) older than $($state.HighWaterPath.Substring($Repo.TrimEnd('\').Length + 1))" }

    if (-not $missing -and $env:GHOZTTY_TEST_ALLOW_STALE -eq '1') {
        return [pscustomobject]@{ Ok = $true; State = 'allowed'; Line = "BUILD STALE ALLOWED (GHOZTTY_TEST_ALLOW_STALE=1): $what - every verdict below is about the OLD bytes" }
    }
    if ($NoRebuild) {
        return [pscustomobject]@{ Ok = $false; State = 'refused'; Line = "BUILD STALE - REFUSED, nothing launched: $what. Build it (zig build -Dapp-runtime=win32 -Doptimize=Debug) or drop -NoRebuild" }
    }

    Write-Host "BUILD STALE: $what - rebuilding once before any script starts"
    if (-not $Builder) { $Builder = { param($r) Invoke-GhozttyDebugBuild -Repo $r } }
    $built = $false
    try { $built = [bool](& $Builder $Repo | Select-Object -Last 1) } catch { Write-Host "  the build threw: $($_.Exception.Message)" }
    if (-not $built -or -not (Test-Path -LiteralPath $exe)) {
        return [pscustomobject]@{ Ok = $false; State = 'refused'; Line = "BUILD STALE - REFUSED, nothing launched: $what, and the rebuild FAILED (errors above). Fix the build, then re-run" }
    }
    # The build read the sources as they are now, relink or no relink.
    Write-GhozttyFreshWitness -Exe $exe -BuiltAtUtc ([datetime]::UtcNow)
    $script:GhozttyFreshCache.Clear()
    $after = Test-GhozttyFreshBuild -Exe $exe -Repo $Repo
    if (-not $after.Fresh) {
        return [pscustomobject]@{ Ok = $false; State = 'refused'; Line = "BUILD STALE - REFUSED, nothing launched: rebuilt, but $($after.HighWaterPath) changed during the build. Re-run" }
    }
    return [pscustomobject]@{ Ok = $true; State = 'rebuilt'; Line = "BUILD FRESH rebuilt before any script started ($what)" }
}
