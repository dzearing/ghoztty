<#
.SYNOPSIS
  Mechanical divergence inventory against upstream ghostty (T516).

.DESCRIPTION
  Upstream-pull planning needs a list, not a guess: which files did THIS fork
  change since the fork point, which did upstream change in the same span,
  and - the actual merge risk - which did both sides touch. This script
  computes all three sets mechanically and writes a committed report so the
  dashboard and digests can cite it.

  Mechanics: fetch the upstream ref (or resolve a local ref with -NoFetch,
  which is how the acceptance test runs against a synthetic repo), find the
  fork point with `git merge-base`, diff each side against it with
  `--name-status -M`, and tally per-file commit counts with one
  `git log --name-only` pass per side.

  The three lists are emitted in full: the changed-both risk set as a table
  with per-side status and commit counts, the two single-side lists as
  directory rollups with the complete file list in a collapsed block.

  Every run also appends a record to a history file beside the report
  (windows-parity-divergence-history.json by default) and writes a "Since the
  last run" section: how the risk set moved (the paths that joined and left
  it), how many commits upstream gained, whether the fork point moved (an
  upstream pull landed), and whether either side's minimum_zig_version moved
  (T960). A first run with no history takes its baseline from the report it
  is about to overwrite, so the delta is never lost to a missing file.

  -Check answers "is the monthly re-run due?" without fetching or writing
  anything: DUE when the newest recorded run is -IntervalDays (30) old or
  older, or when there is no record at all. The daily triage (go.md step 0.6)
  asks it and runs the inventory when it says DUE.

  Exit codes: 0 = report written / -Check not due; 3 = -Check due;
  2 = no merge base / bad ref; 1 = git error.

  ASCII-only by design (PS 5.1 on this box mangles non-ASCII on rewrite).

.EXAMPLE
  powershell -NoProfile -File scripts\divergence-inventory.ps1
  # fetches ghostty-org/ghostty main, writes docs\design\windows-parity-divergence.md

.EXAMPLE
  powershell -NoProfile -File scripts\divergence-inventory.ps1 -NoFetch -UpstreamRef mylocal -RepoRoot C:\tmp\repo -OutFile C:\tmp\report.md

.EXAMPLE
  powershell -NoProfile -File scripts\divergence-inventory.ps1 -Check
  # DIVERGENCE DUE / DIVERGENCE CURRENT; exit 3 when due
#>
[CmdletBinding()]
param(
    [string]$UpstreamUrl = 'https://github.com/ghostty-org/ghostty.git',
    [string]$UpstreamRef = 'main',
    [switch]$NoFetch,
    [string]$OurRef = 'HEAD',
    [string]$RepoRoot,
    [string]$OutFile,
    [string]$HistoryFile,
    [switch]$Check,
    [int]$IntervalDays = 30,
    # Test seam: the date -Check measures against and a run records (yyyy-MM-dd).
    [string]$Now
)

$ErrorActionPreference = 'Stop'

if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
if (-not $OutFile) { $OutFile = Join-Path $RepoRoot 'docs\design\windows-parity-divergence.md' }
if (-not $HistoryFile) {
    $HistoryFile = Join-Path (Split-Path -Parent $OutFile) (([System.IO.Path]::GetFileNameWithoutExtension($OutFile)) + '-history.json')
}
$nowDate = if ($Now) { [datetime]::ParseExact($Now, 'yyyy-MM-dd', $null) } else { (Get-Date).Date }

# --- run history (T960) -----------------------------------------------------
# The file is { "runs": [ ... ] } rather than a bare array: PS 5.1's
# ConvertFrom-Json hands a top-level array back as ONE object, and a 1-element
# array round-trips as a scalar. A property holding the array has neither
# problem.
function Read-History {
    if (-not (Test-Path -LiteralPath $HistoryFile)) { return @() }
    $raw = [System.IO.File]::ReadAllText($HistoryFile)
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    $h = ConvertFrom-Json $raw
    return @($h.runs | Where-Object { $null -ne $_ })
}

# Baseline from a report written before the history existed (the 2026-08-16
# T516 run): its header lines and risk table carry everything the delta needs
# except the zig versions, which it never recorded.
function Read-ReportBaseline {
    if (-not (Test-Path -LiteralPath $OutFile)) { return $null }
    $text = [System.IO.File]::ReadAllText($OutFile)
    $m = [regex]::Match($text, 'Generated (\d{4}-\d{2}-\d{2}) by')
    if (-not $m.Success) { return $null }
    $rec = [ordered]@{ date = $m.Groups[1].Value }
    $m = [regex]::Match($text, '\*\*Fork point:\*\* `([0-9a-f]+)`')
    $rec.forkPoint = if ($m.Success) { $m.Groups[1].Value } else { '' }
    $m = [regex]::Match($text, '\*\*Ours:\*\* `([0-9a-f]+)`[^\n]*? - (\d+) commits')
    $rec.ours = if ($m.Success) { $m.Groups[1].Value } else { '' }
    $rec.ourCommits = if ($m.Success) { [int]$m.Groups[2].Value } else { -1 }
    $m = [regex]::Match($text, '\*\*Upstream:\*\* `([0-9a-f]+)`[^\n]*? - (\d+) commits')
    $rec.upstream = if ($m.Success) { $m.Groups[1].Value } else { '' }
    $rec.upCommits = if ($m.Success) { [int]$m.Groups[2].Value } else { -1 }
    $m = [regex]::Match($text, '\*\*Changed only upstream:\*\* (\d+) files')
    $rec.onlyUp = if ($m.Success) { [int]$m.Groups[1].Value } else { -1 }
    $rec.ourZig = ''
    $rec.upZig = ''
    $risk = New-Object System.Collections.Generic.List[string]
    $inRisk = $false
    foreach ($line in ($text -split "`r?`n")) {
        if ($line -match '^## Changed on both sides') { $inRisk = $true; continue }
        if ($inRisk -and $line -match '^## ') { break }
        if ($inRisk -and $line -match '^\| `(.+)` \| [A-Z] \|') { $risk.Add($Matches[1]) }
    }
    $rec.riskCount = $risk.Count
    $rec.riskSet = @($risk)
    return [pscustomobject]$rec
}

function Get-LastRun {
    $runs = @(Read-History)
    if ($runs.Count -gt 0) { return $runs[$runs.Count - 1] }
    return Read-ReportBaseline
}

if ($Check) {
    $last = Get-LastRun
    if ($null -eq $last) {
        Write-Host ('DIVERGENCE DUE never run (no history at {0}, no report at {1})' -f $HistoryFile, $OutFile)
        Write-Host '  run: powershell -NoProfile -File scripts\divergence-inventory.ps1'
        exit 3
    }
    $lastDate = [datetime]::ParseExact([string]$last.date, 'yyyy-MM-dd', $null)
    $age = [int][math]::Floor(($nowDate - $lastDate).TotalDays)
    $what = 'last run {0} ({1}d ago, risk set {2}, upstream {3})' -f $last.date, $age, $last.riskCount, $last.upstream
    if ($age -ge $IntervalDays) {
        Write-Host ('DIVERGENCE DUE {0}; interval {1}d' -f $what, $IntervalDays)
        Write-Host '  run: powershell -NoProfile -File scripts\divergence-inventory.ps1'
        exit 3
    }
    Write-Host ('DIVERGENCE CURRENT {0}; next due in {1}d' -f $what, ($IntervalDays - $age))
    exit 0
}

function Invoke-Git {
    param([Parameter(Mandatory)][string[]]$GitArgs)
    $out = & git -C $RepoRoot -c core.quotepath=false @GitArgs
    if ($LASTEXITCODE -ne 0) {
        throw ("git {0} failed (exit {1})" -f ($GitArgs -join ' '), $LASTEXITCODE)
    }
    if ($null -eq $out) { return @() }
    return @($out)
}

function Resolve-Commit {
    param([string]$Ref)
    # ^{commit} so a tag or branch name resolves to the commit it points at.
    $r = @(& git -C $RepoRoot rev-parse --verify --quiet ($Ref + '^{commit}'))
    if ($LASTEXITCODE -ne 0 -or $r.Count -eq 0) { return $null }
    return $r[0]
}

# name-status -M: rename detection on, so a moved file is one R entry under its
# NEW name rather than a phantom delete + add pair. The map value is the
# one-letter status (M/A/D/R/C...); for R/C lines the path is the last field.
function Get-ChangedFiles {
    param([string]$FromSha, [string]$ToSha)
    $map = @{}
    foreach ($line in (Invoke-Git @('diff', '--name-status', '-M', $FromSha, $ToSha))) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line -split "`t"
        if ($parts.Count -lt 2) { continue }
        $map[$parts[$parts.Count - 1]] = $parts[0].Substring(0, 1)
    }
    return $map
}

# One log pass over the whole side: every path line is one commit touching that
# path. `--format=` keeps commit headers out of the stream (blank separators
# are skipped; no real path is whitespace-only).
function Get-CommitCounts {
    param([string]$FromSha, [string]$ToSha)
    $counts = @{}
    $range = '{0}..{1}' -f $FromSha, $ToSha
    foreach ($line in (Invoke-Git @('log', '--format=', '--name-only', $range))) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($counts.ContainsKey($line)) { $counts[$line]++ } else { $counts[$line] = 1 }
    }
    return $counts
}

# Depth-2 directory rollup ("src/apprt/", "docs/design/", "(root)") so a
# 2000-file list has a readable summary above the full listing.
function Get-DirRollup {
    param([string[]]$Paths)
    $roll = @{}
    foreach ($p in $Paths) {
        $seg = $p -split '/'
        $key = if ($seg.Count -ge 3) { ($seg[0..1] -join '/') + '/' }
               elseif ($seg.Count -eq 2) { $seg[0] + '/' }
               else { '(root)' }
        if ($roll.ContainsKey($key)) { $roll[$key]++ } else { $roll[$key] = 1 }
    }
    return $roll
}

# --- resolve the three commits ---------------------------------------------

$ourSha = Resolve-Commit $OurRef
if (-not $ourSha) { Write-Host ("ERROR: cannot resolve our ref '{0}'" -f $OurRef); exit 2 }

if ($NoFetch) {
    $upSha = Resolve-Commit $UpstreamRef
    if (-not $upSha) { Write-Host ("ERROR: cannot resolve upstream ref '{0}' (-NoFetch)" -f $UpstreamRef); exit 2 }
    $upstreamLabel = $UpstreamRef
}
else {
    Invoke-Git @('fetch', '--quiet', $UpstreamUrl, $UpstreamRef) | Out-Null
    # @(...) at every call site: a 1-line git answer unrolls to a bare string
    # on return, and [0] on a string is its first CHARACTER (PS 5.1).
    $upSha = @(Invoke-Git @('rev-parse', 'FETCH_HEAD'))[0]
    $upstreamLabel = '{0} {1}' -f $UpstreamUrl, $UpstreamRef
}

$mbOut = @(& git -C $RepoRoot merge-base $ourSha $upSha)
if ($LASTEXITCODE -ne 0 -or $mbOut.Count -eq 0) {
    Write-Host ("ERROR: no merge base between {0} and {1} (unrelated histories?)" -f $ourSha, $upSha)
    exit 2
}
$mb = $mbOut[0]

$mbDate = @(Invoke-Git @('log', '-1', '--format=%ad', '--date=short', $mb))[0]
$mbSubject = @(Invoke-Git @('log', '-1', '--format=%s', $mb))[0]
$ourCommits = [int]@(Invoke-Git @('rev-list', '--count', ('{0}..{1}' -f $mb, $ourSha)))[0]
$upCommits = [int]@(Invoke-Git @('rev-list', '--count', ('{0}..{1}' -f $mb, $upSha)))[0]

# minimum_zig_version out of a commit's build.zig.zon, or '' when the file or
# the field is absent. ls-tree first: `git show` of a missing path writes to
# stderr, which PS 5.1 turns into a terminating error under Stop.
function Get-MinZig {
    param([string]$Sha)
    $hit = @(Invoke-Git @('ls-tree', '--name-only', $Sha, '--', 'build.zig.zon'))
    if ($hit.Count -eq 0) { return '' }
    foreach ($line in (Invoke-Git @('show', ('{0}:build.zig.zon' -f $Sha)))) {
        if ($line -match 'minimum_zig_version\s*=\s*"([^"]+)"') { return $Matches[1] }
    }
    return ''
}

function Format-ZigMove {
    param([string]$Before, [string]$After)
    $a = if ($After) { $After } else { 'n/a' }
    if (-not $Before) { return ('{0} (not recorded last run)' -f $a) }
    if ($Before -eq $After) { return ('{0} (unchanged)' -f $a) }
    return ('{0} -> {1} (MOVED)' -f $Before, $a)
}

$ourZig = Get-MinZig $ourSha
$upZig = Get-MinZig $upSha

# --- compute the three sets -------------------------------------------------

$oursMap = Get-ChangedFiles $mb $ourSha
$upMap = Get-ChangedFiles $mb $upSha

$both = @($oursMap.Keys | Where-Object { $upMap.ContainsKey($_) } | Sort-Object)
$onlyOurs = @($oursMap.Keys | Where-Object { -not $upMap.ContainsKey($_) } | Sort-Object)
$onlyUp = @($upMap.Keys | Where-Object { -not $oursMap.ContainsKey($_) } | Sort-Object)

$ourCounts = Get-CommitCounts $mb $ourSha
$upCounts = Get-CommitCounts $mb $upSha

# --- write the report -------------------------------------------------------

$ourShort = $ourSha.Substring(0, 9)
$upShort = $upSha.Substring(0, 9)
$mbShort = $mb.Substring(0, 9)
$today = $nowDate.ToString('yyyy-MM-dd')

# --- delta against the previous run (T960) ----------------------------------
# Read BEFORE the report is overwritten: with no history yet, the report on
# disk is the baseline.
$history = @(Read-History)
$prev = if ($history.Count -gt 0) { $history[$history.Count - 1] } else { Read-ReportBaseline }
$delta = $null
if ($null -ne $prev) {
    $prevRisk = @($prev.riskSet | Where-Object { $_ })
    $joined = @($both | Where-Object { $prevRisk -notcontains $_ })
    $left = @($prevRisk | Where-Object { $both -notcontains $_ } | Sort-Object)
    # Upstream commits since the previous pin; unknown when that sha is no
    # longer in the object store (upstream-remote.ps1 anchors the plan's pins,
    # not every inventory's).
    $newUp = -1
    $prevUpSha = $null
    if ($prev.upstream) { $prevUpSha = Resolve-Commit ([string]$prev.upstream) }
    if ($prevUpSha) {
        $newUp = [int]@(Invoke-Git @('rev-list', '--count', ('{0}..{1}' -f $prevUpSha, $upSha)))[0]
    }
    $delta = [pscustomobject]@{
        Date       = [string]$prev.date
        PrevRisk   = [int]$prev.riskCount
        Joined     = $joined
        Left       = $left
        NewUp      = $newUp
        PrevUp     = [string]$prev.upstream
        PrevOurC   = [int]$prev.ourCommits
        PrevFork   = [string]$prev.forkPoint
        ForkMoved  = [bool]($prev.forkPoint -and -not $mb.StartsWith([string]$prev.forkPoint))
        PrevUpZig  = [string]$prev.upZig
        PrevOurZig = [string]$prev.ourZig
    }
}

$thisRun = [pscustomobject][ordered]@{
    date       = $today
    forkPoint  = $mbShort
    ours       = $ourShort
    upstream   = $upShort
    ourCommits = $ourCommits
    upCommits  = $upCommits
    riskCount  = $both.Count
    onlyOurs   = $onlyOurs.Count
    onlyUp     = $onlyUp.Count
    ourZig     = $ourZig
    upZig      = $upZig
    riskSet    = @($both)
}
# A report-derived baseline is carried into the history as its first record,
# so the run-history table starts at the real first inventory.
$priorRuns = if ($history.Count -gt 0) { $history } elseif ($null -ne $prev) { @($prev) } else { @() }
$allRuns = @($priorRuns) + @($thisRun)

$L = New-Object System.Collections.Generic.List[string]
$L.Add('# Divergence inventory vs upstream Ghostty')
$L.Add('')
$L.Add(('Generated {0} by `scripts/divergence-inventory.ps1` (T516). Regenerate with:' -f $today))
$L.Add('')
$L.Add('```')
$L.Add('powershell -NoProfile -File scripts\divergence-inventory.ps1')
$L.Add('```')
$L.Add('')
$L.Add(('- **Fork point:** `{0}` ({1}) - {2}' -f $mbShort, $mbDate, $mbSubject))
$L.Add(('- **Ours:** `{0}` ({1}) - {2} commits, {3} files changed since the fork point' -f $ourShort, $OurRef, $ourCommits, ($oursMap.Count)))
$L.Add(('- **Upstream:** `{0}` ({1}) - {2} commits, {3} files changed' -f $upShort, $upstreamLabel, $upCommits, ($upMap.Count)))
$L.Add(('- **Changed on both sides (merge risk set): {0} files** - listed in full below' -f $both.Count))
$L.Add(('- **Changed only here:** {0} files (no upstream conflict possible)' -f $onlyOurs.Count))
$L.Add(('- **Changed only upstream:** {0} files (arrive clean on a merge)' -f $onlyUp.Count))
$L.Add(('- **minimum_zig_version:** ours `{0}`, upstream `{1}`' -f $(if ($ourZig) { $ourZig } else { 'n/a' }), $(if ($upZig) { $upZig } else { 'n/a' })))
$L.Add('')
$L.Add('## Since the last run')
$L.Add('')
$L.Add('Re-run monthly from the daily triage (go.md step 0.6, T960) so the growing')
$L.Add('gap is measured rather than assumed; `-Check` says whether one is due.')
$L.Add('')
if ($null -eq $delta) {
    $L.Add('- First recorded run - no baseline to compare against.')
}
else {
    $L.Add(('- **Compared with:** the run of {0}' -f $delta.Date))
    $L.Add(('- **Risk set:** {0} -> {1} files ({2} joined, {3} left)' -f $delta.PrevRisk, $both.Count, $delta.Joined.Count, $delta.Left.Count))
    $upText = if ($delta.NewUp -ge 0) { '{0} new commits since `{1}`' -f $delta.NewUp, $delta.PrevUp }
              else { 'unknown (the previous pin `{0}` is not in the object store)' -f $delta.PrevUp }
    $L.Add(('- **Upstream:** {0}' -f $upText))
    if ($delta.PrevOurC -ge 0) {
        $L.Add(('- **Ours:** {0} new commits' -f ($ourCommits - $delta.PrevOurC)))
    }
    $forkText = if ($delta.ForkMoved) { 'MOVED `{0}` -> `{1}` (an upstream pull landed)' -f $delta.PrevFork, $mbShort } else { 'unchanged' }
    $L.Add(('- **Fork point:** {0}' -f $forkText))
    $L.Add(('- **Upstream minimum_zig_version:** {0}' -f (Format-ZigMove $delta.PrevUpZig $upZig)))
    $L.Add(('- **Our minimum_zig_version:** {0}' -f (Format-ZigMove $delta.PrevOurZig $ourZig)))
    foreach ($grp in @(@{ T = 'Joined the risk set'; P = $delta.Joined }, @{ T = 'Left the risk set'; P = $delta.Left })) {
        if ($grp.P.Count -eq 0) { continue }
        $L.Add('')
        $L.Add(('<details><summary>{0} ({1})</summary>' -f $grp.T, $grp.P.Count))
        $L.Add('')
        $L.Add('```')
        foreach ($p in $grp.P) { $L.Add($p) }
        $L.Add('```')
        $L.Add('')
        $L.Add('</details>')
    }
}
$L.Add('')
$L.Add('## Run history')
$L.Add('')
$L.Add('| Date | Upstream | Upstream commits | Risk set | Only upstream | Upstream zig |')
$L.Add('|---|---|---|---|---|---|')
foreach ($run in $allRuns) {
    $L.Add(('| {0} | `{1}` | {2} | {3} | {4} | {5} |' -f $run.date, $run.upstream, $run.upCommits, $run.riskCount, $run.onlyUp, $(if ($run.upZig) { $run.upZig } else { 'n/a' })))
}
$L.Add('')
$L.Add('Status letters: M modified, A added, D deleted, R renamed, C copied.')
$L.Add('A file we deleted that upstream kept editing (D vs M) is still merge')
$L.Add('risk - the risk set is any path BOTH sides touched, whatever the touch.')
$L.Add('Commit counts are non-merge commits whose diff touches the path')
$L.Add('(equivalent to `git log --full-history --no-merges -- <path>` over the')
$L.Add('same range), so a merge that carried a change in is not double-counted.')
$L.Add('')
$L.Add(('## Changed on both sides ({0} files) - the merge risk set' -f $both.Count))
$L.Add('')
$L.Add('| File | Ours | Our commits | Upstream | Upstream commits |')
$L.Add('|---|---|---|---|---|')
foreach ($p in $both) {
    $oc = if ($ourCounts.ContainsKey($p)) { $ourCounts[$p] } else { 0 }
    $uc = if ($upCounts.ContainsKey($p)) { $upCounts[$p] } else { 0 }
    $L.Add(('| `{0}` | {1} | {2} | {3} | {4} |' -f $p, $oursMap[$p], $oc, $upMap[$p], $uc))
}

foreach ($side in @(
        @{ Title = 'Changed only here'; Paths = $onlyOurs; Counts = $ourCounts },
        @{ Title = 'Changed only upstream'; Paths = $onlyUp; Counts = $upCounts })) {
    $L.Add('')
    $L.Add(('## {0} ({1} files)' -f $side.Title, $side.Paths.Count))
    $L.Add('')
    $L.Add('| Directory | Files |')
    $L.Add('|---|---|')
    $roll = Get-DirRollup $side.Paths
    foreach ($k in ($roll.Keys | Sort-Object)) {
        $L.Add(('| `{0}` | {1} |' -f $k, $roll[$k]))
    }
    $L.Add('')
    $L.Add('<details><summary>Full list</summary>')
    $L.Add('')
    $L.Add('```')
    foreach ($p in $side.Paths) {
        $c = if ($side.Counts.ContainsKey($p)) { $side.Counts[$p] } else { 0 }
        $L.Add(('{0}  ({1} commits)' -f $p, $c))
    }
    $L.Add('```')
    $L.Add('')
    $L.Add('</details>')
}
$L.Add('')

$outDir = Split-Path -Parent $OutFile
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
}
[System.IO.File]::WriteAllLines($OutFile, $L, (New-Object System.Text.UTF8Encoding($false)))
$histJson = ConvertTo-Json -InputObject ([pscustomobject]@{ runs = @($allRuns) }) -Depth 5
[System.IO.File]::WriteAllText($HistoryFile, ($histJson + "`n"), (New-Object System.Text.UTF8Encoding($false)))

# --- stdout summary ---------------------------------------------------------

Write-Host ('DIVERGENCE fork point {0} ({1})' -f $mbShort, $mbDate)
Write-Host ('  ours     {0} ({1}): {2} commits, {3} files' -f $ourShort, $OurRef, $ourCommits, $oursMap.Count)
Write-Host ('  upstream {0} ({1}): {2} commits, {3} files' -f $upShort, $upstreamLabel, $upCommits, $upMap.Count)
Write-Host ('  changed both (risk set): {0}' -f $both.Count)
Write-Host ('  changed only here: {0}' -f $onlyOurs.Count)
Write-Host ('  changed only upstream: {0}' -f $onlyUp.Count)
Write-Host ('  min zig: ours {0}, upstream {1}' -f $(if ($ourZig) { $ourZig } else { 'n/a' }), $(if ($upZig) { $upZig } else { 'n/a' }))
if ($null -eq $delta) {
    Write-Host '  DELTA first recorded run'
}
else {
    Write-Host ('  DELTA since {0}: risk set {1} -> {2} (+{3} -{4}), upstream +{5} commits, fork point {6}' -f `
            $delta.Date, $delta.PrevRisk, $both.Count, $delta.Joined.Count, $delta.Left.Count, `
            $(if ($delta.NewUp -ge 0) { $delta.NewUp } else { '?' }), $(if ($delta.ForkMoved) { 'MOVED' } else { 'unchanged' }))
    Write-Host ('  DELTA upstream zig {0}; our zig {1}' -f (Format-ZigMove $delta.PrevUpZig $upZig), (Format-ZigMove $delta.PrevOurZig $ourZig))
}
Write-Host ('  report: {0}' -f $OutFile)
Write-Host ('  history: {0}' -f $HistoryFile)
exit 0
