<#
.SYNOPSIS
  Acceptance test for the ReleaseSafe test lanes (T846): floor-lane.ps1's
  `none-releasesafe` / `win32-releasesafe` / `releasesafe` lanes, and the idle
  soak daemon's rotation over them.

.DESCRIPTION
  Every test lane on this box built its tests at DEBUG, and Debug's allocator
  and frame reuse accidentally PROVIDE correctness that the shipping build does
  not: T477 found two live defects at once behind 26 consecutive green Debug
  runs, one of them in shipping renderer code. T846 added the same two test
  lanes compiled at ReleaseSafe, plus the cadence that actually runs them.

  What this harness holds, and why each is the thing that would break:

    * The ReleaseSafe lanes really carry `-Dtest-optimize=ReleaseSafe`. A lane
      that silently lost the flag would be a second copy of the Debug lane
      reporting green under a name that claims otherwise - the exact failure
      this task exists to end.
    * They always carry a `--seed`, and `-Seed` is honoured verbatim. The first
      red these lanes produced was green on the very next unfiltered run; only
      the seed off the failing build's own command line brought it back. A
      verdict nobody can re-run is not evidence.
    * The DEBUG floor lanes carry neither. The cadence decision was that
      ReleaseSafe is a sweep and not a per-turn gate (~9-11 minutes a run from a
      cold optimize-mode cache, against ~3m for the whole Debug floor), and a
      flag leaking into `-Lane all` would quietly undo it.
    * `-Lane all` does not include them, and `-Lane releasesafe` runs the pair.
    * The idle soak daemon's DEFAULT rotation covers them. The installed tick
      task passes no `-Lanes`, so the default is the standing cadence: if these
      lanes are not in it, nothing on this box ever runs ReleaseSafe again.

  Everything here is asserted through the DRY-RUN paths of the two scripts, so
  the whole run costs seconds rather than the forty minutes four real lanes
  would. The lanes themselves are exercised for real by the sweep.

  Prints a single ALL PASS / N FAILURE(S) line, like every other script here.

  ASCII-only by design (PS 5.1 on this box mangles non-ASCII on rewrite).
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:Failures = 0
$script:Passes = 0
function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    if ($Ok) { Write-Host ("PASS  {0}" -f $Name); $script:Passes++ }
    else {
        Write-Host ("FAIL  {0}{1}" -f $Name, $(if ($Detail) { " - $Detail" } else { '' }))
        $script:Failures++
    }
}

$floor = Join-Path $RepoRoot 'scripts\floor-lane.ps1'
$daemon = Join-Path $RepoRoot 'scripts\soak-daemon.ps1'

function Invoke-FloorDryRun {
    param([string]$LaneName, [string]$SeedValue)
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $floor, '-Lane', $LaneName, '-DryRun')
    if ($SeedValue) { $a += @('-Seed', $SeedValue) }
    $out = & powershell @a 2>&1 | ForEach-Object { $_.ToString() }
    return , @($out | Where-Object { $_ -like 'DRY-RUN *' })
}

# ---- arms 1-4: the ReleaseSafe pair carries the mode and a seed -------------

$pair = Invoke-FloorDryRun -LaneName 'releasesafe'
Check '-Lane releasesafe expands to exactly the two ReleaseSafe lanes' `
    ($pair.Count -eq 2) (($pair -join ' | '))
Check 'the pair is the none lane and the win32 lane, in that order' `
    ($pair.Count -eq 2 -and $pair[0] -like 'DRY-RUN none-releasesafe:*' -and
    $pair[1] -like 'DRY-RUN win32-releasesafe:*') (($pair -join ' | '))
Check 'both carry -Dtest-optimize=ReleaseSafe, which is the whole point of the lane' `
    (@($pair | Where-Object { $_ -match '-Dtest-optimize=ReleaseSafe' }).Count -eq 2) `
    (($pair -join ' | '))
Check 'both name a seed, so a red run is replayable' `
    (@($pair | Where-Object { $_ -match '--seed 0x[0-9a-f]+' }).Count -eq 2) `
    (($pair -join ' | '))

# A fresh seed per run is what keeps the sweep covering new test orders; two
# runs handing out the same seed would narrow it to one order for ever.
$pair2 = Invoke-FloorDryRun -LaneName 'releasesafe'
$seed1 = [regex]::Match(($pair -join ' '), '--seed (0x[0-9a-f]+)').Groups[1].Value
$seed2 = [regex]::Match(($pair2 -join ' '), '--seed (0x[0-9a-f]+)').Groups[1].Value
Check 'an unseeded run draws a fresh seed each time' `
    ($seed1 -and $seed2 -and $seed1 -ne $seed2) ("$seed1 vs $seed2")

$pinned = Invoke-FloorDryRun -LaneName 'win32-releasesafe' -SeedValue '0xdeadbeef'
Check '-Seed is honoured verbatim, which is how a red run is reproduced' `
    (($pinned -join ' ') -match '--seed 0xdeadbeef') (($pinned -join ' | '))

# ---- arms 7-10: the Debug floor is untouched -------------------------------

$all = Invoke-FloorDryRun -LaneName 'all'
Check '-Lane all still runs the four Debug lanes' ($all.Count -eq 4) (($all -join ' | '))
Check 'and none of them is a ReleaseSafe lane - the cadence decision holds' `
    (@($all | Where-Object { $_ -match 'releasesafe' }).Count -eq 0) (($all -join ' | '))
Check 'no Debug lane carries -Dtest-optimize' `
    (@($all | Where-Object { $_ -match '-Dtest-optimize' }).Count -eq 0) (($all -join ' | '))
Check 'no Debug lane carries a seed, so the floor command is unchanged' `
    (@($all | Where-Object { $_ -match '--seed' }).Count -eq 0) (($all -join ' | '))

# ---- arms 11-14: the idle cadence ------------------------------------------

$dry = & powershell -NoProfile -ExecutionPolicy Bypass -File $daemon dry-run 2>&1 |
    ForEach-Object { $_.ToString() }
$dryText = $dry -join "`n"
Check 'the soak daemon default rotation includes the none ReleaseSafe lane' `
    ($dryText -match 'none-releasesafe: zig build test -Dapp-runtime=none -Dtest-optimize=ReleaseSafe') $dryText
Check 'and the win32 ReleaseSafe lane' `
    ($dryText -match 'win32-releasesafe: zig build test -Dapp-runtime=win32 -Dtest-optimize=ReleaseSafe') $dryText
Check 'a soak round names its seed too, so a red round is replayable' `
    (@([regex]::Matches($dryText, 'releasesafe.*--seed 0x[0-9a-f]+')).Count -ge 2) $dryText
Check 'the T443 lanes are still in the rotation - this is an addition, not a swap' `
    ($dryText -match '(?m)^\s*agent:' -and $dryText -match '(?m)^\s*none:') $dryText

# Each ReleaseSafe lane gets its OWN cache, for the reason the daemon's own
# comment gives: a shared one would make every round rebuild what the last
# round evicted. The optimize mode makes that sharper, not softer.
Check 'each ReleaseSafe lane builds in its own cache directory' `
    ($dryText -match 'none-releasesafe\\zig-cache' -and $dryText -match 'win32-releasesafe\\zig-cache') $dryText

# ---- arm 16: an unknown lane is refused rather than silently defaulted ------

& powershell -NoProfile -ExecutionPolicy Bypass -File $daemon dry-run -Lanes 'releasesafe' *> $null
Check 'the daemon refuses a lane name it does not know (exit 2)' ($LASTEXITCODE -eq 2) "exit=$LASTEXITCODE"

Complete-TestBody  # T1039: the run reached the end of its body

if ($script:Failures -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot 'scripts\guard-due.ps1') `
        update -Guard lane-releasesafe -Repo $RepoRoot 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:Passes -Fail $script:Failures
