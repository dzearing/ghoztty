<#
.SYNOPSIS
  Acceptance test for scripts\divergence-inventory.ps1 (T516).

.DESCRIPTION
  The inventory is the input to upstream-pull planning, so a wrong list sends a
  future merge hunting conflicts in the wrong files. Every arm here runs
  against a synthetic repo this test builds itself - a base commit, a "fork"
  branch and an "upstreamref" branch with a known overlap - so the expected
  three-way split is exact rather than compared against live history.

  What the arms prove:
    A. the three sets land exactly where constructed (both / only-here /
       only-upstream), with statuses (M/A/D) and per-file commit counts;
    B. a merge commit on our side does not double-count the merged change,
       and the count matches the documented equivalent
       (git log --full-history --no-merges -- <path>);
    C. error paths answer instead of lying: a bogus ref and unrelated
       histories both exit 2 with an ERROR line and write no report.
    D. a second run reports the delta since the first (T960): the path that
       joined the risk set, the new upstream commits, and upstream's
       minimum_zig_version moving; the history file carries both runs;
    E. -Check is due exactly at the interval, current before it, due when
       nothing was ever recorded, and writes nothing;
    F. a report written before the history existed is the baseline, so the
       first monthly run still has a delta to report.

  No network, no GUI, no ghoztty processes - safe on the background desktop.

  ASCII-only by design (PS 5.1 on this box mangles non-ASCII on rewrite).
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Script = Join-Path $RepoRoot 'scripts\divergence-inventory.ps1'

$script:passes = 0
$script:failures = 0
function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    if ($Ok) { $script:passes++; Write-Host ("PASS  {0}" -f $Name) }
    else {
        $script:failures++
        Write-Host ("FAIL  {0}{1}" -f $Name, $(if ($Detail) { " - $Detail" } else { '' }))
    }
}

function Invoke-TmpGit {
    param([string]$Repo, [string[]]$GitArgs)
    $out = & git -C $Repo @GitArgs
    if ($LASTEXITCODE -ne 0) {
        throw ("fixture git {0} failed (exit {1})" -f ($GitArgs -join ' '), $LASTEXITCODE)
    }
    return @($out)
}

function Invoke-Inventory {
    param([string[]]$ScriptArgs)
    $out = & powershell -NoProfile -File $Script @ScriptArgs
    return [pscustomobject]@{
        Code  = $LASTEXITCODE
        Lines = @($out)
        Text  = (@($out) -join "`n")
    }
}

$tmp = Join-Path $env:TEMP ("divinv-test-{0}" -f [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp | Out-Null

try {
    # --- fixture repo -------------------------------------------------------
    # base: a,b,c.  fork: M a (twice), A d, then MERGES a side branch adding e.
    # upstreamref: M a, M c, D b.
    # both = {a}, only-here = {d, e}, only-upstream = {b(D), c(M)}.
    $null = Invoke-TmpGit $tmp @('init', '--quiet')
    $null = Invoke-TmpGit $tmp @('config', 'user.email', 'test@test')
    $null = Invoke-TmpGit $tmp @('config', 'user.name', 'test')

    Set-Content -LiteralPath (Join-Path $tmp 'a.txt') -Value 'a v0' -Encoding Ascii
    Set-Content -LiteralPath (Join-Path $tmp 'b.txt') -Value 'b v0' -Encoding Ascii
    Set-Content -LiteralPath (Join-Path $tmp 'c.txt') -Value 'c v0' -Encoding Ascii
    # Unchanged on both sides until section D bumps it upstream, so it is in
    # none of section A's sets.
    Set-Content -LiteralPath (Join-Path $tmp 'build.zig.zon') -Value '.{ .minimum_zig_version = "0.15.2" }' -Encoding Ascii
    $null = Invoke-TmpGit $tmp @('add', '-A')
    $null = Invoke-TmpGit $tmp @('commit', '--quiet', '-m', 'base')
    # @(...) wrap: a 1-line git answer unrolls to a bare string on return,
    # and [0] on a string is its first CHARACTER (PS 5.1).
    $baseSha = @(Invoke-TmpGit $tmp @('rev-parse', 'HEAD'))[0]
    $baseShort = $baseSha.Substring(0, 9)

    $null = Invoke-TmpGit $tmp @('checkout', '--quiet', '-b', 'side')
    Set-Content -LiteralPath (Join-Path $tmp 'e.txt') -Value 'e v1' -Encoding Ascii
    $null = Invoke-TmpGit $tmp @('add', '-A')
    $null = Invoke-TmpGit $tmp @('commit', '--quiet', '-m', 'side: add e')

    $null = Invoke-TmpGit $tmp @('checkout', '--quiet', '-b', 'fork', $baseSha)
    Set-Content -LiteralPath (Join-Path $tmp 'a.txt') -Value 'a fork1' -Encoding Ascii
    $null = Invoke-TmpGit $tmp @('commit', '--quiet', '-am', 'fork: a 1')
    Set-Content -LiteralPath (Join-Path $tmp 'd.txt') -Value 'd v1' -Encoding Ascii
    $null = Invoke-TmpGit $tmp @('add', '-A')
    $null = Invoke-TmpGit $tmp @('commit', '--quiet', '-m', 'fork: add d')
    Set-Content -LiteralPath (Join-Path $tmp 'a.txt') -Value 'a fork2' -Encoding Ascii
    $null = Invoke-TmpGit $tmp @('commit', '--quiet', '-am', 'fork: a 2')
    $null = Invoke-TmpGit $tmp @('merge', '--quiet', '--no-ff', '--no-edit', 'side')

    $null = Invoke-TmpGit $tmp @('checkout', '--quiet', '-b', 'upstreamref', $baseSha)
    Set-Content -LiteralPath (Join-Path $tmp 'a.txt') -Value 'a up1' -Encoding Ascii
    $null = Invoke-TmpGit $tmp @('commit', '--quiet', '-am', 'up: a')
    Set-Content -LiteralPath (Join-Path $tmp 'c.txt') -Value 'c up1' -Encoding Ascii
    $null = Invoke-TmpGit $tmp @('commit', '--quiet', '-am', 'up: c')
    $null = Invoke-TmpGit $tmp @('rm', '--quiet', 'b.txt')
    $null = Invoke-TmpGit $tmp @('commit', '--quiet', '-m', 'up: delete b')

    # --- A. the three sets --------------------------------------------------
    $report = Join-Path $tmp 'report.md'
    $history = Join-Path $tmp 'report-history.json'
    $r = Invoke-Inventory @('-RepoRoot', $tmp, '-OurRef', 'fork', '-UpstreamRef', 'upstreamref', '-NoFetch', '-OutFile', $report, '-Now', '2026-01-01')
    Check 'A1 run exits 0' ($r.Code -eq 0) ("exit=" + $r.Code)
    Check 'A11 first run says there is no baseline' ($r.Text -match 'DELTA first recorded run') $r.Text
    Check 'A12 min zig read from both sides' ($r.Text -match 'min zig: ours 0\.15\.2, upstream 0\.15\.2') $r.Text
    Check 'A13 history written beside the report' (Test-Path -LiteralPath $history)
    $reportA = if (Test-Path -LiteralPath $report) { Get-Content -LiteralPath $report -Raw } else { '' }
    Check 'A2 fork point is the base commit' ($r.Text -match [regex]::Escape("fork point $baseShort")) $r.Text
    Check 'A3 risk set counted as 1' ($r.Text -match 'changed both \(risk set\): 1\b') $r.Text
    Check 'A4 only-here counted as 2' ($r.Text -match 'changed only here: 2\b') $r.Text
    Check 'A5 only-upstream counted as 2' ($r.Text -match 'changed only upstream: 2\b') $r.Text
    Check 'A6 report file written' (Test-Path -LiteralPath $report)

    $rep = if (Test-Path -LiteralPath $report) { Get-Content -LiteralPath $report -Raw } else { '' }
    Check 'A7 a.txt in risk table: M/2 ours, M/1 upstream' `
        ($rep -match [regex]::Escape('| `a.txt` | M | 2 | M | 1 |')) `
        (($rep -split "`n" | Where-Object { $_ -match 'a\.txt' }) -join '; ')
    Check 'A8 d.txt listed only-here with 1 commit' `
        (($rep -match [regex]::Escape('d.txt  (1 commits)')) -and ($rep -notmatch '\| `d\.txt` \|'))
    Check 'A9 b.txt deletion is only-upstream, not risk' `
        (($rep -match [regex]::Escape('b.txt  (1 commits)')) -and ($rep -notmatch '\| `b\.txt` \|'))
    Check 'A10 c.txt listed only-upstream' ($rep -match [regex]::Escape('c.txt  (1 commits)'))

    # --- B. merge commits do not double-count -------------------------------
    # e.txt reached fork through a merge; its count must be the 1 real commit,
    # and must equal the documented oracle command.
    Check 'B1 merged e.txt counts its 1 commit, not the merge too' `
        ($rep -match [regex]::Escape('e.txt  (1 commits)')) `
        (($rep -split "`n" | Where-Object { $_ -match 'e\.txt' }) -join '; ')
    $oracle = @(Invoke-TmpGit $tmp @('log', '--format=%H', '--full-history', '--no-merges', "$baseSha..fork", '--', 'e.txt')).Count
    Check 'B2 count matches git log --full-history --no-merges' ($oracle -eq 1) ("oracle=" + $oracle)

    # --- D. delta since the previous run (T960) ------------------------------
    # upstreamref gains two commits: it adds d.txt (which fork added too, so
    # d joins the risk set) and bumps minimum_zig_version.
    $null = Invoke-TmpGit $tmp @('checkout', '--quiet', 'upstreamref')
    Set-Content -LiteralPath (Join-Path $tmp 'd.txt') -Value 'd up' -Encoding Ascii
    $null = Invoke-TmpGit $tmp @('add', 'd.txt')  # never -A: the report and history live in this repo's tree
    $null = Invoke-TmpGit $tmp @('commit', '--quiet', '-m', 'up: add d')
    Set-Content -LiteralPath (Join-Path $tmp 'build.zig.zon') -Value '.{ .minimum_zig_version = "0.16.0" }' -Encoding Ascii
    $null = Invoke-TmpGit $tmp @('commit', '--quiet', '-am', 'up: zig 0.16')
    $null = Invoke-TmpGit $tmp @('checkout', '--quiet', 'fork')

    $r = Invoke-Inventory @('-RepoRoot', $tmp, '-OurRef', 'fork', '-UpstreamRef', 'upstreamref', '-NoFetch', '-OutFile', $report, '-Now', '2026-01-15')
    Check 'D1 second run exits 0' ($r.Code -eq 0) ("exit=" + $r.Code)
    Check 'D2 delta names the risk-set move and the new upstream commits' `
        ($r.Text -match 'DELTA since 2026-01-01: risk set 1 -> 2 \(\+1 -0\), upstream \+2 commits, fork point unchanged') $r.Text
    Check 'D3 upstream zig bump is reported as MOVED' ($r.Text -match 'DELTA upstream zig 0\.15\.2 -> 0\.16\.0 \(MOVED\); our zig 0\.15\.2 \(unchanged\)') $r.Text
    $rep = if (Test-Path -LiteralPath $report) { Get-Content -LiteralPath $report -Raw } else { '' }
    Check 'D4 report lists d.txt as joining the risk set' `
        (($rep -match 'Joined the risk set \(1\)') -and ($rep -match '(?m)^d\.txt\r?$')) `
        (($rep -split "`n" | Where-Object { $_ -match 'Joined|Risk set' }) -join '; ')
    $h = if (Test-Path -LiteralPath $history) { ConvertFrom-Json ([System.IO.File]::ReadAllText($history)) } else { $null }
    $runs = if ($null -ne $h) { @($h.runs) } else { @() }
    Check 'D5 history carries both runs in order' `
        (($runs.Count -eq 2) -and ($runs[0].date -eq '2026-01-01') -and ($runs[1].date -eq '2026-01-15') -and ($runs[1].upZig -eq '0.16.0')) `
        ("runs=" + $runs.Count)
    Check 'D6 run-history table has a row per run' `
        (($rep -match '\| 2026-01-01 \| `') -and ($rep -match '\| 2026-01-15 \| `')) ''

    # --- E. -Check ------------------------------------------------------------
    $before = [System.IO.File]::ReadAllText($history)
    $r = Invoke-Inventory @('-RepoRoot', $tmp, '-Check', '-OutFile', $report, '-Now', '2026-02-13')
    Check 'E1 29 days after the last run is CURRENT (exit 0)' `
        (($r.Code -eq 0) -and ($r.Text -match 'DIVERGENCE CURRENT last run 2026-01-15 \(29d ago, risk set 2') -and ($r.Text -match 'next due in 1d')) ("exit=" + $r.Code + " " + $r.Text)
    $r = Invoke-Inventory @('-RepoRoot', $tmp, '-Check', '-OutFile', $report, '-Now', '2026-02-14')
    Check 'E2 30 days after the last run is DUE (exit 3)' `
        (($r.Code -eq 3) -and ($r.Text -match 'DIVERGENCE DUE last run 2026-01-15 \(30d ago')) ("exit=" + $r.Code + " " + $r.Text)
    Check 'E3 -Check wrote nothing' ([System.IO.File]::ReadAllText($history) -eq $before)
    $r = Invoke-Inventory @('-RepoRoot', $tmp, '-Check', '-OutFile', (Join-Path $tmp 'never.md'), '-Now', '2026-02-14')
    Check 'E4 nothing ever recorded is DUE (exit 3)' `
        (($r.Code -eq 3) -and ($r.Text -match 'DIVERGENCE DUE never run')) ("exit=" + $r.Code + " " + $r.Text)
    Check 'E5 -Check on a fresh path created nothing' `
        ((-not (Test-Path -LiteralPath (Join-Path $tmp 'never.md'))) -and (-not (Test-Path -LiteralPath (Join-Path $tmp 'never-history.json'))))

    # --- F. a pre-history report is the baseline ----------------------------
    $legacy = Join-Path $tmp 'legacy.md'
    $legacyHistory = Join-Path $tmp 'legacy-history.json'
    [System.IO.File]::WriteAllText($legacy, $reportA)
    $r = Invoke-Inventory @('-RepoRoot', $tmp, '-Check', '-OutFile', $legacy, '-Now', '2026-01-20')
    Check 'F1 -Check reads the legacy report date' `
        (($r.Code -eq 0) -and ($r.Text -match 'last run 2026-01-01 \(19d ago, risk set 1')) ("exit=" + $r.Code + " " + $r.Text)
    $r = Invoke-Inventory @('-RepoRoot', $tmp, '-OurRef', 'fork', '-UpstreamRef', 'upstreamref', '-NoFetch', '-OutFile', $legacy, '-Now', '2026-01-20')
    Check 'F2 first run over a legacy report reports its delta' `
        (($r.Code -eq 0) -and ($r.Text -match 'DELTA since 2026-01-01: risk set 1 -> 2 \(\+1 -0\), upstream \+2 commits')) ("exit=" + $r.Code + " " + $r.Text)
    Check 'F3 legacy baseline had no zig record and says so' ($r.Text -match 'DELTA upstream zig 0\.16\.0 \(not recorded last run\)') $r.Text
    $lh = if (Test-Path -LiteralPath $legacyHistory) { ConvertFrom-Json ([System.IO.File]::ReadAllText($legacyHistory)) } else { $null }
    $lruns = if ($null -ne $lh) { @($lh.runs) } else { @() }
    Check 'F4 the legacy baseline becomes the first history record' `
        (($lruns.Count -eq 2) -and ($lruns[0].date -eq '2026-01-01') -and (@($lruns[0].riskSet).Count -eq 1)) ("runs=" + $lruns.Count)

    # --- C. error paths -----------------------------------------------------
    $badReport = Join-Path $tmp 'bad.md'
    $r = Invoke-Inventory @('-RepoRoot', $tmp, '-OurRef', 'fork', '-UpstreamRef', 'no-such-ref', '-NoFetch', '-OutFile', $badReport)
    Check 'C1 bogus upstream ref exits 2 with ERROR' `
        (($r.Code -eq 2) -and ($r.Text -match 'ERROR: cannot resolve upstream ref')) ("exit=" + $r.Code + " " + $r.Text)
    Check 'C2 no report written on error' (-not (Test-Path -LiteralPath $badReport))

    $null = Invoke-TmpGit $tmp @('checkout', '--quiet', '--orphan', 'lonely')
    $null = Invoke-TmpGit $tmp @('rm', '-rfq', '--cached', '.')
    Set-Content -LiteralPath (Join-Path $tmp 'z.txt') -Value 'z' -Encoding Ascii
    $null = Invoke-TmpGit $tmp @('add', 'z.txt')
    $null = Invoke-TmpGit $tmp @('commit', '--quiet', '-m', 'lonely root')
    $r = Invoke-Inventory @('-RepoRoot', $tmp, '-OurRef', 'fork', '-UpstreamRef', 'lonely', '-NoFetch', '-OutFile', $badReport)
    Check 'C3 unrelated histories exit 2 with no-merge-base ERROR' `
        (($r.Code -eq 2) -and ($r.Text -match 'ERROR: no merge base')) ("exit=" + $r.Code + " " + $r.Text)
    Complete-TestBody  # T1039: the run reached the end of its body
}
finally {
    if ($tmp -and (Test-Path -LiteralPath $tmp)) {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# --- stamp (T783) -----------------------------------------------------------
# A green run records the content of every file this harness covers, so
# scripts\guard-due.ps1 can answer "has anything run it against the code as it
# now stands?". A red run leaves the stamp alone on purpose - red must stay due.
if ($script:failures -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot 'scripts\guard-due.ps1') `
        update -Guard divergence-inventory -Repo $RepoRoot | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:passes -Fail $script:failures -MinPass 33
