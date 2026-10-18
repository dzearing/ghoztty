<#
.SYNOPSIS
    T1059 - which pull requests are open on the fork, and which of them need a
    turn spent on them?

.DESCRIPTION
    Once work ships as per-feature PRs (T1058, go.md step 6.9) a PR is work
    that can silently stop existing: it goes red, or conflicts, or just sits,
    and nothing in the turn ever looks. The daily digest (go.md step 0.5) is
    the read the user already does every morning, so this script writes the
    digest's "Open pull requests" block rather than standing up a new surface.

    EVERY STATE IS READ FROM GITHUB, never remembered. One call:

        gh pr list --repo dzearing/ghoztty --state open --json ...

    which carries each PR's check rollup, review decision and merge state. "It
    was green when I pushed" is not a CI status.

    Per PR it decides:

      checks   RED      any check concluded failure / timed_out /
                        startup_failure / action_required / cancelled-as-error,
                        or a status context reads FAILURE / ERROR
               PENDING  none red, at least one still queued / running
               GREEN    every check completed and none red
               NONE     the PR has no checks at all (CI never ran on it)
      waiting  draft / changes requested / awaiting review / ready to merge
      stalled  no activity for -StaleDays (3) days

    and sorts it into one of three bands:

      NEEDS A TURN  checks red, no checks at all, merge conflict, changes
                    requested, or stalled.
                    These are the PRs the digest tells the reader to act on.
      IN FLIGHT     checks still running, or a draft.
      HEALTHY       green, waiting on review or ready to merge.

    ABSENCE IS NEVER GREEN. No open PRs prints the empty state, and a GitHub
    that cannot be asked (no gh, not signed in, no network, or slower than
    -TimeoutSeconds) prints UNKNOWN with the reason. Neither is a failure: the
    digest must never be blocked by the state of a web service, so the exit
    code is 0 for every verdict and the call is bounded by a real timeout (the
    gh process is killed when it runs over).

    Formats: `text` (default; one line per PR plus a `PR HEALTH` verdict line)
    and `markdown` (paste into today's digest under `## Commentary`).

    ASCII-only by design (PS 5.1 on this box mangles non-ASCII on rewrite).

.EXAMPLE
    powershell -NoProfile -File scripts\pr-health.ps1
    powershell -NoProfile -File scripts\pr-health.ps1 -Format markdown
#>
[CmdletBinding()]
param(
    [ValidateSet('text', 'markdown', 'json')]
    [string]$Format = 'text',

    # The GitHub repository to ask. NEVER let `gh` resolve this itself: this
    # repo has `upstream` (ghostty-org/ghostty) as a remote and a bare gh
    # command resolves to it (go.md, step 6.9).
    [string]$ForkRepo = 'dzearing/ghoztty',

    # The gh executable. Defaults to whatever `gh` resolves to. The acceptance
    # harness points it at a stub so the transport - process launch, exit code,
    # stdout, the timeout kill - is exercised for real rather than bypassed.
    [string]$GhExe,

    # Read the PR list from a file instead of calling gh: the parsing and the
    # verdicts are the script's own, only the transport is replaced.
    [string]$PrsJsonFile,

    [int]$TimeoutSeconds = 20,

    # A PR with no activity for this many days is STALLED.
    [int]$StaleDays = 3,

    # The clock the ages are measured against. Tests pin it.
    [string]$Now
)

$ErrorActionPreference = 'Stop'

$nowUtc = if ($Now) { ([datetime]::Parse($Now, [Globalization.CultureInfo]::InvariantCulture)).ToUniversalTime() } else { (Get-Date).ToUniversalTime() }

$Fields = 'number,title,url,headRefName,createdAt,updatedAt,isDraft,reviewDecision,mergeable,mergeStateStatus,statusCheckRollup'

# Check-run conclusions that mean the build said no. Same set as
# ci-status.ps1, so a run the claim calls red is a PR check this calls red.
$RedConclusions = @('FAILURE', 'TIMED_OUT', 'STARTUP_FAILURE', 'ACTION_REQUIRED')
$RedStates = @('FAILURE', 'ERROR')

# PS 5.1's ConvertFrom-Json hands a JSON array back as ONE object; the
# ForEach-Object is what unrolls it (see ci-status.ps1's Expand-Json).
function Expand-Json([string]$text) {
    if (-not $text) { return @() }
    return @($text | ConvertFrom-Json | ForEach-Object { $_ })
}

# Run gh with a real deadline. Start-Process cannot hand back stdout without a
# temp file and `& gh` cannot be interrupted, so this drives
# System.Diagnostics.Process directly: async stdout/stderr reads (a full pipe
# must never be able to wedge the wait), WaitForExit(ms), and a kill on
# overrun. Answers @{ Ok; Why; Out }.
function Invoke-GhBounded([string[]]$argList) {
    $exe = $GhExe
    if (-not $exe) {
        $cmd = Get-Command gh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $cmd) { return @{ Ok = $false; Why = 'gh is not installed on this box'; Out = '' } }
        $exe = $cmd.Source
    }
    if (-not (Test-Path -LiteralPath $exe)) { return @{ Ok = $false; Why = "gh not found at $exe"; Out = '' } }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = (($argList | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    try { [void]$p.Start() } catch { return @{ Ok = $false; Why = "gh could not start: $($_.Exception.Message)"; Out = '' } }
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
        # The whole TREE, not just the process: a child left alive keeps the
        # inherited output handles open, and whoever is reading THIS script's
        # output then waits for the child anyway - which is the overrun the
        # deadline exists to cut off (C7 of test\win32\pr-health.ps1).
        # Process.Kill(true) is .NET Core only; PS 5.1 has taskkill.
        & taskkill.exe /T /F /PID $p.Id *> $null
        try { if (-not $p.HasExited) { $p.Kill() } } catch { }
        return @{ Ok = $false; Why = "GitHub did not answer within ${TimeoutSeconds}s"; Out = '' }
    }
    # The exit is in; give the readers a moment to drain what the process wrote.
    [void]$outTask.Wait(5000)
    [void]$errTask.Wait(5000)
    $out = if ($outTask.IsCompleted) { $outTask.Result } else { '' }
    $err = if ($errTask.IsCompleted) { $errTask.Result } else { '' }
    if ($p.ExitCode -ne 0) {
        $why = @($err -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
        $why = if ($why.Count -gt 0) { $why[0].Trim() } else { "gh exited $($p.ExitCode)" }
        return @{ Ok = $false; Why = $why; Out = '' }
    }
    return @{ Ok = $true; Why = ''; Out = $out }
}

function Get-Prs {
    if ($PrsJsonFile) {
        if (-not (Test-Path -LiteralPath $PrsJsonFile)) { return @{ Ok = $false; Why = "PR file not found: $PrsJsonFile"; Prs = @() } }
        $text = [System.IO.File]::ReadAllText($PrsJsonFile, [System.Text.Encoding]::UTF8)
    } else {
        $r = Invoke-GhBounded @('pr', 'list', '--repo', $ForkRepo, '--state', 'open', '--limit', '100', '--json', $Fields)
        if (-not $r.Ok) { return @{ Ok = $false; Why = $r.Why; Prs = @() } }
        $text = $r.Out
    }
    try { return @{ Ok = $true; Why = ''; Prs = @(Expand-Json $text) } }
    catch { return @{ Ok = $false; Why = 'GitHub answered with something that is not JSON'; Prs = @() } }
}

function Get-CheckVerdict($rollup) {
    $items = @($rollup | Where-Object { $null -ne $_ })
    if ($items.Count -eq 0) { return @{ State = 'NONE'; Failing = @() } }
    $failing = @()
    $pending = $false
    foreach ($c in $items) {
        $name = if ($c.name) { [string]$c.name } elseif ($c.context) { [string]$c.context } else { 'check' }
        if ($c.PSObject.Properties['state'] -and $c.state) {
            # StatusContext: SUCCESS / PENDING / EXPECTED / FAILURE / ERROR
            $s = ([string]$c.state).ToUpperInvariant()
            if ($RedStates -contains $s) { $failing += $name }
            elseif ($s -ne 'SUCCESS') { $pending = $true }
        } else {
            # CheckRun: status QUEUED / IN_PROGRESS / COMPLETED, then conclusion
            $st = ([string]$c.status).ToUpperInvariant()
            $co = ([string]$c.conclusion).ToUpperInvariant()
            if ($st -ne 'COMPLETED') { $pending = $true }
            elseif ($RedConclusions -contains $co) { $failing += $name }
        }
    }
    if ($failing.Count -gt 0) { return @{ State = 'RED'; Failing = @($failing | Select-Object -Unique) } }
    if ($pending) { return @{ State = 'PENDING'; Failing = @() } }
    return @{ State = 'GREEN'; Failing = @() }
}

function Format-Age([double]$days) {
    if ($days -lt 1) { return ('{0}h' -f [math]::Max(0, [math]::Floor($days * 24))) }
    return ('{0}d' -f [math]::Floor($days))
}

function Get-PrHealth($pr) {
    $checks = Get-CheckVerdict $pr.statusCheckRollup
    $created = ([datetime]$pr.createdAt).ToUniversalTime()
    $updated = if ($pr.updatedAt) { ([datetime]$pr.updatedAt).ToUniversalTime() } else { $created }
    $ageDays = ($nowUtc - $created).TotalDays
    $idleDays = ($nowUtc - $updated).TotalDays
    $review = ([string]$pr.reviewDecision).ToUpperInvariant()
    $merge = ([string]$pr.mergeStateStatus).ToUpperInvariant()
    $conflict = ($merge -eq 'DIRTY') -or (([string]$pr.mergeable).ToUpperInvariant() -eq 'CONFLICTING')

    $waiting = if ($pr.isDraft) { 'draft' }
        elseif ($review -eq 'CHANGES_REQUESTED') { 'changes requested' }
        elseif ($review -eq 'APPROVED' -or ($review -eq '' -and $merge -eq 'CLEAN')) { 'ready to merge' }
        else { 'awaiting review' }

    $reasons = @()
    if ($checks.State -eq 'RED') { $reasons += ('checks failing: ' + ($checks.Failing -join ', ')) }
    # Every push to the fork runs Fork CI, so a PR with no checks at all is one
    # CI never looked at - unmeasured, which is never the same as green.
    if ($checks.State -eq 'NONE') { $reasons += 'no CI checks ran on it' }
    if ($conflict) { $reasons += 'merge conflict with the base branch' }
    if ($review -eq 'CHANGES_REQUESTED') { $reasons += 'changes requested' }
    if ($idleDays -ge $StaleDays) { $reasons += ("stalled: no activity for {0}" -f (Format-Age $idleDays)) }

    $band = if ($reasons.Count -gt 0) { 'NEEDS A TURN' }
        elseif ($checks.State -eq 'PENDING' -or $pr.isDraft) { 'IN FLIGHT' }
        else { 'HEALTHY' }

    [pscustomobject]@{
        Number   = [int]$pr.number
        Title    = [string]$pr.title
        Url      = [string]$pr.url
        Branch   = [string]$pr.headRefName
        Age      = (Format-Age $ageDays)
        Idle     = (Format-Age $idleDays)
        Checks   = $checks.State
        Failing  = @($checks.Failing)
        Waiting  = $waiting
        Band     = $band
        Reasons  = @($reasons)
    }
}

$bandRank = @{ 'NEEDS A TURN' = 0; 'IN FLIGHT' = 1; 'HEALTHY' = 2 }

$got = Get-Prs
$rows = @()
if ($got.Ok) {
    $rows = @($got.Prs | ForEach-Object { Get-PrHealth $_ } | Sort-Object @{ Expression = { $bandRank[$_.Band] } }, Number)
}
$needs = @($rows | Where-Object { $_.Band -eq 'NEEDS A TURN' })

$verdict = if (-not $got.Ok) { 'UNKNOWN' }
    elseif ($rows.Count -eq 0) { 'NONE OPEN' }
    elseif ($needs.Count -gt 0) { 'NEEDS ATTENTION' }
    else { 'OK' }

switch ($Format) {
    'json' {
        [pscustomobject]@{ verdict = $verdict; why = $got.Why; repo = $ForkRepo; prs = $rows } | ConvertTo-Json -Depth 5
    }
    'markdown' {
        if (-not $got.Ok) {
            '### Open pull requests: unknown'
            ''
            "- **Could not ask GitHub** - $($got.Why). This is not a green: PR health is simply unmeasured today."
        } elseif ($rows.Count -eq 0) {
            '### Open pull requests: none open'
            ''
            "- Nothing is waiting to merge on ``$ForkRepo``."
        } else {
            $head = "### Open pull requests: $($rows.Count) open"
            if ($needs.Count -gt 0) { $head += ", $($needs.Count) need a turn" }
            $head
            ''
            foreach ($r in $rows) {
                $label = switch ($r.Band) {
                    'NEEDS A TURN' { 'Needs a turn' }
                    'IN FLIGHT' { 'In flight' }
                    default { 'Healthy' }
                }
                $checksText = switch ($r.Checks) {
                    'RED' { 'checks failing' }
                    'PENDING' { 'checks running' }
                    'GREEN' { 'checks green' }
                    default { 'no checks ran' }
                }
                $tail = if ($r.Reasons.Count -gt 0) { ($r.Reasons -join '; ') } else { "$checksText, $($r.Waiting)" }
                # The dashboard's inline link pattern is [^\]]+ for the text, so
                # an escaped bracket would still end the link early: swap them.
                $title = ($r.Title -replace '\[', '(') -replace '\]', ')'
                "- **$label** - [#$($r.Number) $title]($($r.Url)) - ``$($r.Branch)``, open $($r.Age). $tail."
            }
        }
    }
    default {
        foreach ($r in $rows) {
            $why = if ($r.Reasons.Count -gt 0) { ' - ' + ($r.Reasons -join '; ') } else { '' }
            "  #{0} [{1}] checks={2} {3} age={4} idle={5} {6}{7}" -f $r.Number, $r.Band, $r.Checks, $r.Waiting, $r.Age, $r.Idle, $r.Branch, $why
        }
        switch ($verdict) {
            'UNKNOWN' { "PR HEALTH UNKNOWN $ForkRepo - $($got.Why) (not a green; nothing was measured)" }
            'NONE OPEN' { "PR HEALTH NONE OPEN $ForkRepo" }
            'NEEDS ATTENTION' { "PR HEALTH NEEDS ATTENTION $ForkRepo - $($needs.Count) of $($rows.Count) open PR(s) need a turn" }
            default { "PR HEALTH OK $ForkRepo - $($rows.Count) open, none need a turn" }
        }
    }
}
exit 0
