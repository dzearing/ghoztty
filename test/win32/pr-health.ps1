# T1059 acceptance - the digest's "Open pull requests" block: every open PR on
# the fork, its real CI status, and which of them need a turn.
#
#   powershell -NoProfile -File test\win32\pr-health.ps1
#
# Non-interactive. Launches no Ghoztty and touches no user state.
#
# isolation: none - no ghoztty binary is run and no CLI verb is invoked; the
# only executables this script starts are powershell (the subject), cmd (the gh
# stubs) and, read-only in section D, gh itself. (T680 meta-check reads this
# marker.)
#
# WHY IT EXISTS
#
# The subject is a report whose whole value is that it does not lie. The two
# lies that matter are a red PR shown as healthy, and an unreachable GitHub
# shown as "nothing to worry about" - both look exactly like a quiet morning.
#
# A - verdicts. Each PR shape lands in the right band: a real red check (the
#     fork's own PR #12, captured verbatim) is NEEDS A TURN and names the job;
#     conflict, changes-requested and stalled are NEEDS A TURN; running checks
#     and drafts are IN FLIGHT; green ones are HEALTHY; a cancelled or skipped
#     check is not red; a StatusContext ERROR is.
# B - absence. No open PRs is the empty state, never a list of nothing.
# C - transport, for real: a stub gh is launched as a process, and its exit
#     code, stderr, non-JSON output and an overrun all read UNKNOWN with the
#     reason, exit 0 and inside the time budget. Never a fabricated green.
# D - wiring: every gh call names --repo (this repo's default gh repo is the
#     public Ghostty project), a live read-only call answers a verdict, and
#     go.md's digest step reaches the script.
param(
    [string]$Repo
)

$ErrorActionPreference = 'Continue'
if (-not $Repo) { $Repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:failures = 0
$script:passes = 0
$script:skips = 0
function Assert($name, $cond, $detail = '') {
    if ($cond) { Write-Host "  PASS $name"; $script:passes++ }
    else { Write-Host "  FAIL $name $detail" -ForegroundColor Red; $script:failures++ }
}
function Skip($name, $why) { Write-Host "  SKIP $name - $why" -ForegroundColor Yellow; $script:skips++ }
function Say($m) { Write-Host $m }

$Subject = Join-Path $Repo 'scripts\pr-health.ps1'
$GoMd = Join-Path $Repo 'go.md'
$Now = '2026-10-17T12:00:00Z'

# Per-record capture (T883), so assertions are about the script's lines and
# not about the width of the console this ran in.
function Invoke-Subject {
    param([string[]]$SubjectArgs)
    $ErrorActionPreference = 'SilentlyContinue'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $out = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $Subject @SubjectArgs 2>&1 | ForEach-Object { $_.ToString() })
    $sw.Stop()
    return [pscustomobject]@{ Code = $LASTEXITCODE; Text = ($out -join "`n"); Lines = $out; Seconds = $sw.Elapsed.TotalSeconds }
}

function Get-Json($r) {
    try { return ($r.Text | ConvertFrom-Json) } catch { return $null }
}

function Find-Pr($payload, [int]$n) {
    return @($payload.prs | ForEach-Object { $_ } | Where-Object { $_.Number -eq $n })[0]
}

$sandbox = Join-Path $env:TEMP ("pr-health-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $sandbox -Force | Out-Null

function Write-Fixture([string]$name, [string]$text) {
    $p = Join-Path $sandbox $name
    [System.IO.File]::WriteAllText($p, $text, (New-Object System.Text.UTF8Encoding $false))
    return $p
}

# PR #12 on dzearing/ghoztty, captured from `gh pr list --state all` on
# 2026-10-17 and trimmed to three of its checks (one per conclusion that
# matters). Its build-test check genuinely failed - the T578 red-check probe -
# so this is a real red rollup, not a hand-written one. Only `updatedAt` is
# moved, so that it is recent relative to $Now and the only reason it needs a
# turn is the red check.
# skip-audit: a GitHub check conclusion in fixture data, not this script skipping
$skippedConclusion = 'SKIPPED'
$real12 = @'
{"createdAt":"2026-08-16T19:22:12Z","headRefName":"scratch/t578-red-check","isDraft":false,"mergeStateStatus":"UNSTABLE","mergeable":"MERGEABLE","number":12,"reviewDecision":"","title":"T578 red-check probe","url":"https://github.com/dzearing/ghoztty/pull/12","updatedAt":"2026-10-17T09:00:00Z","statusCheckRollup":[{"__typename":"CheckRun","completedAt":"2026-08-16T19:23:49Z","conclusion":"FAILURE","detailsUrl":"https://github.com/dzearing/ghoztty/actions/runs/31967370788/job/95214483056","name":"build-test","startedAt":"2026-08-16T19:22:18Z","status":"COMPLETED","workflowName":"Fork CI"},{"__typename":"CheckRun","completedAt":"2026-08-17T19:29:31Z","conclusion":"CANCELLED","detailsUrl":"https://github.com/dzearing/ghoztty/actions/runs/31967730803/job/95215353916","name":"Milestone Update","startedAt":"2026-08-16T19:29:31Z","status":"COMPLETED","workflowName":"Milestone Action"},{"__typename":"CheckRun","completedAt":"2026-08-16T19:22:16Z","conclusion":"%SKIPCONC%","detailsUrl":"https://github.com/dzearing/ghoztty/actions/runs/31967370800/job/95214483629","name":"check-zig-cache-hash","startedAt":"2026-08-16T19:22:16Z","status":"COMPLETED","workflowName":"Nix"}]}
'@.Trim().Replace('%SKIPCONC%', $skippedConclusion)

function New-Pr([int]$n, [string]$checks, [string]$extra = '') {
    $base = '"createdAt":"2026-10-15T12:00:00Z","updatedAt":"2026-10-17T10:00:00Z","headRefName":"feature/p{0}","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","number":{0},"reviewDecision":"","title":"PR {0}","url":"https://github.com/dzearing/ghoztty/pull/{0}","statusCheckRollup":{1}' -f $n, $checks
    $obj = '{' + $base + '}'
    if ($extra) {
        # Overrides: later keys win in ConvertFrom-Json, so append them.
        $obj = $obj.TrimEnd('}') + ',' + $extra + '}'
    }
    return $obj
}

$green = '[{"__typename":"CheckRun","name":"build-test","status":"COMPLETED","conclusion":"SUCCESS"}]'
$running = '[{"__typename":"CheckRun","name":"build-test","status":"IN_PROGRESS","conclusion":""}]'
$ctxError = '[{"__typename":"StatusContext","context":"ci/legacy","state":"ERROR"}]'
$cancelledOnly = '[{"__typename":"CheckRun","name":"build-test","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"CheckRun","name":"Milestone Update","status":"COMPLETED","conclusion":"CANCELLED"}]'

$mix = '[' + (@(
    $real12,
    (New-Pr 20 $green),                                              # healthy, ready to merge
    (New-Pr 21 $green '"reviewDecision":"REVIEW_REQUIRED","mergeStateStatus":"BLOCKED"'), # healthy, awaiting review
    (New-Pr 22 $running),                                            # in flight
    (New-Pr 23 $green '"isDraft":true,"mergeStateStatus":"DRAFT"'),  # in flight (draft)
    (New-Pr 24 $green '"mergeStateStatus":"DIRTY","mergeable":"CONFLICTING"'), # conflict
    (New-Pr 25 $green '"reviewDecision":"CHANGES_REQUESTED"'),       # changes requested
    (New-Pr 26 $green '"updatedAt":"2026-10-10T12:00:00Z"'),         # stalled 7d
    (New-Pr 27 $ctxError),                                           # status-context error
    (New-Pr 28 '[]'),                                                # no checks
    (New-Pr 29 $cancelledOnly '"title":"[WIP] bracketed"')           # cancelled is not red
) -join ',') + ']'

try {
    if (-not (Test-Path $Subject)) { throw 'scripts\pr-health.ps1 missing' }

    # =====================================================================
    Say ''
    Say 'A - each PR shape lands in the right band'
    # =====================================================================
    $mixFile = Write-Fixture 'mix.json' $mix
    $r = Invoke-Subject @('-PrsJsonFile', $mixFile, '-Now', $Now, '-Format', 'json')
    $p = Get-Json $r
    Assert 'A0 json payload parses, exit 0' ($null -ne $p -and $r.Code -eq 0) "code=$($r.Code) text=$($r.Text)"
    if ($p) {
        Assert 'A1 verdict is NEEDS ATTENTION' ($p.verdict -eq 'NEEDS ATTENTION') "verdict=$($p.verdict)"
        $x = Find-Pr $p 12
        Assert 'A2 real red PR #12 is NEEDS A TURN with checks RED' ($x.Band -eq 'NEEDS A TURN' -and $x.Checks -eq 'RED') "band=$($x.Band) checks=$($x.Checks)"
        Assert 'A3 the failing job is named, the cancelled/skipped ones are not' ((@($x.Failing) -join ',') -eq 'build-test') "failing=$(@($x.Failing) -join ',')"
        $x = Find-Pr $p 20
        Assert 'A4 green + clean is HEALTHY, ready to merge' ($x.Band -eq 'HEALTHY' -and $x.Waiting -eq 'ready to merge') "band=$($x.Band) waiting=$($x.Waiting)"
        $x = Find-Pr $p 21
        Assert 'A5 green + review required is HEALTHY, awaiting review' ($x.Band -eq 'HEALTHY' -and $x.Waiting -eq 'awaiting review') "band=$($x.Band) waiting=$($x.Waiting)"
        $x = Find-Pr $p 22
        Assert 'A6 running checks are IN FLIGHT, PENDING' ($x.Band -eq 'IN FLIGHT' -and $x.Checks -eq 'PENDING') "band=$($x.Band) checks=$($x.Checks)"
        $x = Find-Pr $p 23
        Assert 'A7 a draft is IN FLIGHT' ($x.Band -eq 'IN FLIGHT' -and $x.Waiting -eq 'draft') "band=$($x.Band) waiting=$($x.Waiting)"
        $x = Find-Pr $p 24
        Assert 'A8 a merge conflict needs a turn' ($x.Band -eq 'NEEDS A TURN' -and (@($x.Reasons) -join ';') -match 'conflict') "band=$($x.Band) reasons=$(@($x.Reasons) -join ';')"
        $x = Find-Pr $p 25
        Assert 'A9 changes requested needs a turn' ($x.Band -eq 'NEEDS A TURN' -and (@($x.Reasons) -join ';') -match 'changes requested') "band=$($x.Band)"
        $x = Find-Pr $p 26
        Assert 'A10 seven idle days is stalled and needs a turn' ($x.Band -eq 'NEEDS A TURN' -and (@($x.Reasons) -join ';') -match 'stalled: no activity for 7d') "reasons=$(@($x.Reasons) -join ';')"
        $x = Find-Pr $p 27
        Assert 'A11 a StatusContext ERROR is RED' ($x.Checks -eq 'RED' -and $x.Band -eq 'NEEDS A TURN') "checks=$($x.Checks)"
        $x = Find-Pr $p 28
        Assert 'A12 no checks at all is NONE, not GREEN, and needs a turn' ($x.Checks -eq 'NONE' -and $x.Band -eq 'NEEDS A TURN') "checks=$($x.Checks) band=$($x.Band)"
        $x = Find-Pr $p 29
        Assert 'A13 a cancelled check alone is not red' ($x.Checks -eq 'GREEN' -and $x.Band -eq 'HEALTHY') "checks=$($x.Checks) band=$($x.Band)"
        $bands = @($p.prs | ForEach-Object { $_.Band })
        $firstHealthy = [array]::IndexOf($bands, 'HEALTHY')
        $lastNeeds = [array]::LastIndexOf($bands, 'NEEDS A TURN')
        Assert 'A14 needs-a-turn PRs sort ahead of healthy ones' ($lastNeeds -lt $firstHealthy) "bands=$($bands -join ',')"
    }

    $md = Invoke-Subject @('-PrsJsonFile', $mixFile, '-Now', $Now, '-Format', 'markdown')
    Assert 'A15 markdown heading counts open and needs-a-turn' ($md.Lines[0] -eq '### Open pull requests: 11 open, 6 need a turn') "head=$($md.Lines[0])"
    $line12 = @($md.Lines | Where-Object { $_ -match '#12 ' })[0]
    Assert 'A16 markdown renders the red PR as a link with its failing job' ($line12 -match '^\- \*\*Needs a turn\*\* - \[#12 T578 red-check probe\]\(https://github.com/dzearing/ghoztty/pull/12\)' -and $line12 -match 'checks failing: build-test') "line=$line12"
    $line20 = @($md.Lines | Where-Object { $_ -match '#20 ' })[0]
    Assert 'A17 a healthy PR is visibly distinct from a red one' ($line20 -match '^\- \*\*Healthy\*\*' -and $line20 -match 'checks green, ready to merge') "line=$line20"
    # The dashboard's link pattern takes [^\]]+ as the text, so a bracket in a
    # title must not reach it.
    $line29 = @($md.Lines | Where-Object { $_ -match '#29 ' })[0]
    Assert 'A17b a bracketed title stays one dashboard link' ($line29 -match '\[#29 \(WIP\) bracketed\]\(https://') "line=$line29"
    $t = Invoke-Subject @('-PrsJsonFile', $mixFile, '-Now', $Now)
    Assert 'A18 text verdict line names how many need a turn' ($t.Lines[-1] -match '^PR HEALTH NEEDS ATTENTION dzearing/ghoztty - 6 of 11') "last=$($t.Lines[-1])"

    # =====================================================================
    Say ''
    Say 'B - no open PRs is the empty state'
    # =====================================================================
    $emptyFile = Write-Fixture 'empty.json' '[]'
    $r = Invoke-Subject @('-PrsJsonFile', $emptyFile, '-Format', 'markdown')
    Assert 'B1 markdown empty state' ($r.Lines[0] -eq '### Open pull requests: none open' -and $r.Text -match 'Nothing is waiting to merge') "text=$($r.Text)"
    $r = Invoke-Subject @('-PrsJsonFile', $emptyFile)
    Assert 'B2 text empty verdict, exit 0' ($r.Lines[-1] -eq 'PR HEALTH NONE OPEN dzearing/ghoztty' -and $r.Code -eq 0) "last=$($r.Lines[-1]) code=$($r.Code)"

    # =====================================================================
    Say ''
    Say 'C - the transport fails to UNKNOWN, never to green'
    # =====================================================================
    # Each stub is a real process the subject launches through its bounded
    # runner, so the exit code, stderr and kill paths are the shipping ones.
    $okStub = Write-Fixture 'gh-ok.cmd' ("@type `"" + $mixFile + "`"`r`n@exit /b 0`r`n")
    $r = Invoke-Subject @('-GhExe', $okStub, '-Now', $Now)
    Assert 'C1 a stub gh that answers is parsed through the real transport' ($r.Lines[-1] -match '^PR HEALTH NEEDS ATTENTION .* 6 of 11') "last=$($r.Lines[-1])"

    $authStub = Write-Fixture 'gh-auth.cmd' "@echo To get started with GitHub CLI, please run:  gh auth login 1>&2`r`n@exit /b 4`r`n"
    $r = Invoke-Subject @('-GhExe', $authStub)
    Assert 'C2 gh failing (not signed in) is UNKNOWN with its reason, exit 0' ($r.Lines[-1] -match '^PR HEALTH UNKNOWN .*gh auth login.*not a green' -and $r.Code -eq 0) "last=$($r.Lines[-1]) code=$($r.Code)"
    $r = Invoke-Subject @('-GhExe', $authStub, '-Format', 'markdown')
    Assert 'C3 markdown says unknown and that it is not a green' ($r.Lines[0] -eq '### Open pull requests: unknown' -and $r.Text -match 'This is not a green') "text=$($r.Text)"

    $r = Invoke-Subject @('-GhExe', (Join-Path $sandbox 'no-such-gh.exe'))
    Assert 'C4 a missing gh is UNKNOWN' ($r.Lines[-1] -match '^PR HEALTH UNKNOWN .*gh not found') "last=$($r.Lines[-1])"

    $junkStub = Write-Fixture 'gh-junk.cmd' "@echo ^<html^>rate limited^</html^>`r`n@exit /b 0`r`n"
    $r = Invoke-Subject @('-GhExe', $junkStub)
    Assert 'C5 a non-JSON answer is UNKNOWN' ($r.Lines[-1] -match '^PR HEALTH UNKNOWN .*not JSON') "last=$($r.Lines[-1])"

    # The slow stub sleeps 30s; with a 2s budget the subject must kill it and
    # come back well inside the time a digest can afford to wait.
    $slowStub = Write-Fixture 'gh-slow.cmd' "@ping -n 31 127.0.0.1 >nul`r`n@type `"$mixFile`"`r`n"
    $r = Invoke-Subject @('-GhExe', $slowStub, '-TimeoutSeconds', '2')
    Assert 'C6 a GitHub slower than the budget is UNKNOWN' ($r.Lines[-1] -match '^PR HEALTH UNKNOWN .*did not answer within 2s') "last=$($r.Lines[-1])"
    Assert 'C7 and the call comes back inside the budget, not after the stub' ($r.Seconds -lt 15) ("took {0:N1}s" -f $r.Seconds)

    # =====================================================================
    Say ''
    Say 'D - wiring'
    # =====================================================================
    $bare = @()
    $n = 0
    $inHelp = $false
    foreach ($line in (Get-Content $Subject)) {
        $n++
        if ($line -match '^\s*<#') { $inHelp = $true }
        if ($inHelp) { if ($line -match '#>') { $inHelp = $false }; continue }
        if ($line -match '^\s*#') { continue }
        if ($line -match "'pr',\s*'list'" -and $line -notmatch "'--repo'") { $bare += "${n}: $($line.Trim())" }
    }
    $hasRepo = (Get-Content $Subject -Raw) -match "'pr',\s*'list',\s*'--repo',\s*\`$ForkRepo"
    Assert 'D1 the gh call names --repo $ForkRepo' ($hasRepo -and $bare.Count -eq 0) ($bare -join '; ')
    Assert 'D2 the fork is the default -ForkRepo' ((Get-Content $Subject -Raw) -match "ForkRepo\s*=\s*'dzearing/ghoztty'")

    if (Get-Command gh -ErrorAction SilentlyContinue) {
        $r = Invoke-Subject @()
        Assert 'D3 a live read-only call answers a verdict, exit 0' ($r.Lines[-1] -match '^PR HEALTH (OK|NONE OPEN|NEEDS ATTENTION|UNKNOWN) dzearing/ghoztty' -and $r.Code -eq 0) "last=$($r.Lines[-1])"
        Assert 'D4 the live call fits the digest budget' ($r.Seconds -lt 30) ("took {0:N1}s" -f $r.Seconds)
    } else {
        Skip 'D3/D4 live call' 'gh is not installed'
    }

    $go = Get-Content $GoMd -Raw
    Assert 'D5 go.md digest step reaches pr-health.ps1' ($go -match 'scripts\\pr-health\.ps1 -Format markdown')

    # =====================================================================
    Say ''
    Say 'E - the review read (-Detail, T1182): what it does, what to test, what is inside'
    # =====================================================================
    # Bodies are built as objects and serialized, so the newlines, fences and
    # brackets reach the subject exactly as GitHub would send them.
    $nl = "`n"
    $bodyNamed = (@(
        'Intro line that is not the summary.', '',
        '## What it does', '',
        'The banner fades out when it collapses,', 'instead of vanishing.', '',
        'A second paragraph that is not part of the summary.', '',
        '```', '## What to test', '- a fenced line that is not a test step', '```', '',
        '## What to test', '',
        '- [ ] collapse a banner and watch it fade',
        '- [x] reopen it',
        '1. resize the pane mid-fade', '',
        'Generated with [Claude Code](https://claude.com/claude-code)'
    ) -join $nl)
    $bodyPlain = (@('Fixes the copy menu on wide panes.', '', '- not a test list, just notes', '', '### Testing', '', '* run the copy harness') -join $nl)
    $commits = @(@{ oid = '0123456789abcdef0123456789abcdef01234567'; messageHeadline = 'banner: fade on collapse' }, @{ oid = 'fedcba9876543210fedcba9876543210fedcba98'; messageHeadline = 'test: fade harness' })
    $files = @(@{ path = 'src/apprt/win32/Banner.zig'; additions = 40; deletions = 3 }, @{ path = 'test/win32/banner-fade.ps1'; additions = 120; deletions = 0 })
    $detailPrs = @(
        @{ number = 40; title = 'Banner fades'; url = 'https://github.com/dzearing/ghoztty/pull/40'; headRefName = 'feature/banner-fade'; createdAt = '2026-10-15T12:00:00Z'; updatedAt = '2026-10-17T10:00:00Z'; isDraft = $false; reviewDecision = 'REVIEW_REQUIRED'; mergeable = 'MERGEABLE'; mergeStateStatus = 'BLOCKED'; statusCheckRollup = @(@{ __typename = 'CheckRun'; name = 'build-test'; status = 'COMPLETED'; conclusion = 'SUCCESS' }); body = $bodyNamed; commits = $commits; files = $files; additions = 160; deletions = 3 },
        @{ number = 41; title = 'Copy menu'; url = 'https://github.com/dzearing/ghoztty/pull/41'; headRefName = 'feature/copy'; createdAt = '2026-10-15T12:00:00Z'; updatedAt = '2026-10-17T10:00:00Z'; isDraft = $false; reviewDecision = ''; mergeable = 'MERGEABLE'; mergeStateStatus = 'CLEAN'; statusCheckRollup = @(); body = $bodyPlain; commits = @($commits[0]); files = @($files[0]); additions = 40; deletions = 3 },
        @{ number = 42; title = 'Empty body'; url = 'https://github.com/dzearing/ghoztty/pull/42'; headRefName = 'feature/empty'; createdAt = '2026-10-15T12:00:00Z'; updatedAt = '2026-10-17T10:00:00Z'; isDraft = $true; reviewDecision = ''; mergeable = 'MERGEABLE'; mergeStateStatus = 'DRAFT'; statusCheckRollup = @(); body = ''; commits = @(); files = @(); additions = 0; deletions = 0 }
    )
    $detailFile = Write-Fixture 'detail.json' (ConvertTo-Json -InputObject $detailPrs -Depth 6)
    $r = Invoke-Subject @('-PrsJsonFile', $detailFile, '-Now', $Now, '-Format', 'json', '-Detail')
    $p = Get-Json $r
    Assert 'E0 the detail json parses, exit 0' ($null -ne $p -and $r.Code -eq 0) "code=$($r.Code) text=$($r.Text)"
    if ($p) {
        $x = (Find-Pr $p 40).Review
        Assert 'E1 a "## What it does" section is the summary, its first paragraph only, joined' ($x.Summary -eq 'The banner fades out when it collapses, instead of vanishing.') "summary=$($x.Summary)"
        $tests = @($x.ToTest | ForEach-Object { $_ })
        Assert 'E2 "## What to test" items are the test steps, checkbox and numbering stripped' (($tests -join '|') -eq 'collapse a banner and watch it fade|reopen it|resize the pane mid-fade') "tests=$($tests -join '|')"
        Assert 'E3 a heading inside a code fence is not a section' (-not (($tests -join '|') -match 'fenced')) "tests=$($tests -join '|')"
        $cs = @($x.Commits | ForEach-Object { $_ })
        Assert 'E4 commits carry a short sha and the headline' ($cs.Count -eq 2 -and $cs[0].Sha -eq '012345678' -and $cs[0].Headline -eq 'banner: fade on collapse') "commits=$($cs | ConvertTo-Json -Compress)"
        $fs = @($x.Files | ForEach-Object { $_ })
        Assert 'E5 files carry their path and line counts' ($fs.Count -eq 2 -and $fs[1].Path -eq 'test/win32/banner-fade.ps1' -and $fs[1].Additions -eq 120 -and $x.Additions -eq 160) "files=$($fs | ConvertTo-Json -Compress)"
        Assert 'E6 the generated-with boilerplate is not in the body' (-not ($x.Body -match 'Generated with')) "body tail=$($x.Body.Substring([math]::Max(0, $x.Body.Length - 80)))"
        $y = (Find-Pr $p 41).Review
        Assert 'E7 no named summary: the first prose paragraph, not a bullet' ($y.Summary -eq 'Fixes the copy menu on wide panes.') "summary=$($y.Summary)"
        # PS 5.1 collapses a one-element array to a scalar in ConvertTo-Json
        # only through the pipeline; the payload must still read as a list.
        Assert 'E8 a single test step under "### Testing" is still a one-item list' ($r.Text -match '"ToTest":\s*\[\s*"run the copy harness"\s*\]') 'ToTest for #41 is not a JSON list'
        Assert 'E9 a single commit and file are still lists' ($r.Text -match '"Commits":\s*\[\s*\{' -and @($y.Files | ForEach-Object { $_ }).Count -eq 1)
        $z = (Find-Pr $p 42).Review
        Assert 'E10 an empty body says nothing rather than inventing a summary or steps' ($z.Summary -eq '' -and @($z.ToTest | ForEach-Object { $_ }).Count -eq 0) "summary=$($z.Summary)"
        # 40 green + awaiting review; 41 and 42 have no checks at all, which is
        # never green (A12) - a draft included.
        $bands = '{0}|{1}|{2}' -f (Find-Pr $p 40).Band, (Find-Pr $p 41).Band, (Find-Pr $p 42).Band
        Assert 'E11 the verdicts are unchanged by -Detail' ($bands -eq 'HEALTHY|NEEDS A TURN|NEEDS A TURN') "bands=$bands"
    }
    $plain = Get-Json (Invoke-Subject @('-PrsJsonFile', $detailFile, '-Now', $Now, '-Format', 'json'))
    Assert 'E12 without -Detail the payload carries no review fields (the digest read stays small)' ($plain -and -not (Find-Pr $plain 40).PSObject.Properties['Review'])
    $src = Get-Content $Subject -Raw
    # GitHub refuses the whole query when PRs x commits x authors passes
    # 500,000 nodes - the live 100-PR detail read did exactly that.
    Assert 'E13 the detail read asks GitHub for at most 25 PRs' ($src -match '\$DetailLimit = 25' -and $src -match "if \(\`$Detail\) \{ \`$DetailLimit \}")
    if (Get-Command gh -ErrorAction SilentlyContinue) {
        $r = Invoke-Subject @('-Format', 'json', '-Detail')
        $p = Get-Json $r
        Assert 'E14 a live detail read is a verdict GitHub accepted, not a refused query' ($p -and $p.verdict -ne 'UNKNOWN') "verdict=$($p.verdict) why=$($p.why)"
    } else {
        Skip 'E14 live detail read' 'gh is not installed'
    }
}
catch {
    Write-Host "  FAIL harness crashed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "    at $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())"
    $script:failures++
}
finally {
    if (Test-Path -LiteralPath $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue }
}

Complete-TestBody
if ($script:failures -eq 0 -and $script:skips -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard pr-health -Repo $Repo 2>&1 | ForEach-Object { "  $_" }
}

Say ''
Write-TestVerdict -Pass $script:passes -Fail $script:failures -Skipped $script:skips -Label 'PR-HEALTH'
