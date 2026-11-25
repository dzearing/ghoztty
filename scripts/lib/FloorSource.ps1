# FloorSource.ps1 - what the parallel floor's "contention" verdict compares (T2191).
#
# floor-lane.ps1 runs its lanes side by side, and a lane that is red there is
# re-run ALONE; when the solo run is green the summary used to say
# FLOOR PARALLEL CONTENTION ... "the box, not the code". That is only true when
# the two runs built the SAME code. On 2026-10-23 (T2169) win32 and agent went
# red side by side on a real allocator leak, the leak was fixed in the tree
# before the solo re-runs started, the solo runs passed, and the summary blamed
# the box for a genuine code defect.
#
# So each run records a fingerprint of the build inputs as it starts, and the
# verdict compares them. Everything here is pure enough to test without
# launching a lane (test\win32\floor-lane-parallel.ps1).
#
# ASCII-only by design (PS 5.1 on this box mangles non-ASCII on rewrite).

# What `zig build` reads. Tracker docs, test scripts and the dashboard change
# constantly while a floor runs (the other loop lane commits them) and none of
# them can turn a zig test red, so they are deliberately NOT in the fingerprint:
# counting them would report "source changed" on every run and the label would
# mean nothing again.
$script:FloorSourcePaths = @('src', 'pkg', 'include', 'vendor', 'build.zig', 'build.zig.zon')

function Get-FloorSourceFingerprint {
    <#
    .SYNOPSIS
        A short hash of the build inputs as they stand right now, or $null.
    .DESCRIPTION
        Covers HEAD, every uncommitted edit to a tracked build input (staged or
        not), and every untracked, non-ignored file under the build inputs, by
        content. Two calls return the same string exactly when a build started
        at either moment would have read the same sources.

        $null means "could not tell" (no git, not a repo), and the caller says
        so instead of guessing either way.

        GHOZTTY_FLOOR_SOURCE_FAKE names a file whose CONTENT stands in for the
        tree, so the acceptance harness can change "the source" from inside a
        planted lane without editing the repo it runs from.
    #>
    param([Parameter(Mandatory)][string]$Repo)
    # Native stderr under a caller's Stop preference is a terminating error in
    # PS 5.1; a git warning must not read as "could not tell".
    $ErrorActionPreference = 'Continue'

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        if ($env:GHOZTTY_FLOOR_SOURCE_FAKE) {
            $fake = $env:GHOZTTY_FLOOR_SOURCE_FAKE
            $text = if (Test-Path -LiteralPath $fake) { [System.IO.File]::ReadAllText($fake) } else { '<absent>' }
            $bytes = [System.Text.Encoding]::UTF8.GetBytes("fake`n$text")
            return ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').Substring(0, 16).ToLowerInvariant()
        }

        $paths = $script:FloorSourcePaths
        $head = (& git -C $Repo rev-parse HEAD 2>$null)
        if ($LASTEXITCODE -ne 0 -or -not $head) { return $null }

        $parts = New-Object System.Collections.Generic.List[string]
        $parts.Add("head $head")
        # Text diff of tracked inputs against HEAD: one string, cheap even over
        # src/. --binary so an edited binary fixture still changes the hash.
        $diff = (& git -C $Repo -c core.quotepath=off diff HEAD --binary --no-color -- $paths 2>$null) -join "`n"
        if ($LASTEXITCODE -ne 0) { return $null }
        $parts.Add("diff $diff")
        $untracked = @(& git -C $Repo -c core.quotepath=off ls-files --others --exclude-standard -- $paths 2>$null)
        if ($LASTEXITCODE -ne 0) { return $null }
        foreach ($u in ($untracked | Sort-Object)) {
            $p = Join-Path $Repo $u
            $h = try { (Get-FileHash -LiteralPath $p -Algorithm SHA256 -ErrorAction Stop).Hash } catch { '<unreadable>' }
            $parts.Add("new $u $h")
        }
        $bytes = [System.Text.Encoding]::UTF8.GetBytes(($parts -join "`n"))
        return ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').Substring(0, 16).ToLowerInvariant()
    }
    catch { return $null }
    finally { $sha.Dispose() }
}

function Get-FloorRerunCause {
    <#
    .SYNOPSIS
        Why a lane that was red side by side came out green alone.
    .DESCRIPTION
        'contention'     - both runs built the same sources: the box, not the code.
        'source-changed' - the sources moved between the two runs, so the solo
                           green says nothing about the side-by-side red; it may
                           have been a real defect that has since been fixed.
        'unknown'        - either fingerprint is missing; neither claim is made.
        $null            - the solo run was not green, so there is nothing to
                           explain (the lane is red and reported as red).
    #>
    param(
        [AllowNull()][string]$SideFingerprint,
        [AllowNull()][string]$AloneFingerprint,
        [Parameter(Mandatory)][bool]$AlonePassed
    )
    if (-not $AlonePassed) { return $null }
    if (-not $SideFingerprint -or -not $AloneFingerprint) { return 'unknown' }
    if ($SideFingerprint -eq $AloneFingerprint) { return 'contention' }
    return 'source-changed'
}
