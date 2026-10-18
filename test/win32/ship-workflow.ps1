# T1058 acceptance - the ship workflow: the cutover readiness gate and the
# per-feature worktree/branch/PR lifecycle.
#
#   powershell -NoProfile -File test\win32\ship-workflow.ps1
#
# @parallel-unsafe - A10 asserts `git status` of the repo is unchanged across a
# readiness run, so a neighbouring worker writing a guard stamp turns it red
# (2026-10-17, T1060's due sweep: red beside three workers, green alone).
#
# Non-interactive. Launches no Ghoztty and touches no user state: the subjects
# are two git/gh-driving scripts, so the lifecycle half runs entirely inside a
# throwaway repo pair under $env:TEMP, and the readiness half only READS this
# repo.
#
# isolation: none - no ghoztty binary is run and no CLI verb is invoked; the
# only executables this script starts are git and (read-only, section C) gh.
# (T680 meta-check reads this marker.)
#
# WHY IT EXISTS
#
# Both subjects are gates, and a gate that is wrong is worse than no gate: one
# says "this branch is ready to become the trunk" and the other deletes
# worktrees and branches. Every section below is an assertion that a REFUSAL
# actually refuses, because that is the half that cannot be checked by using the
# tool - a script that has quietly stopped refusing looks exactly like one that
# had nothing to refuse.
#
# A - ship-readiness reports honestly. An unmeasured criterion is UNKNOWN and
#     counts against readiness; the numbers it prints are the numbers git gives;
#     it never mutates the repo it judges; and a criterion that fails carries a
#     remedy, because a gate with no exit is a gate people route around.
# B - the feature lifecycle, end to end, in a sandbox: new / list / pr / done,
#     including every refusal (duplicate slug, bad slug, dirty tree, nothing to
#     propose, unpushed commits, missing worktree).
# C - the gh landmine. This repo has upstream (ghostty-org/ghostty) as a remote
#     and gh resolves to it by default, so a bare `gh pr create` here would
#     offer this fork's work to the public Ghostty project. Every gh call in the
#     family must name --repo, and this section is what keeps that true.
# D - the docs are wired: the workflow doc exists and covers the lifecycle, and
#     go.md reaches both scripts, so a turn following only go.md can execute one.
param(
    [string]$Repo
)

$ErrorActionPreference = 'Continue'
if (-not $Repo) { $Repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }

# T1511: the shared scorer, and the dot-source is also what ARMS the run - a
# body that unwinds before `Complete-TestBody` may not print a pass, and the
# guard-stamping child below reads the same state and refuses to write.
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

$Readiness = Join-Path $Repo 'scripts\ship-readiness.ps1'
$Feature = Join-Path $Repo 'scripts\ship-feature.ps1'
$Review = Join-Path $Repo 'scripts\pr-review.ps1'
$Doc = Join-Path $Repo 'docs\design\windows-parity-ship-workflow.md'
$GoMd = Join-Path $Repo 'go.md'

# Per-record capture (T883): a merged 2>&1 stream on a native command is
# formatted to the host's buffer width, so an assertion over that text would be
# an assertion about the console it ran in.
function Invoke-Script {
    param([string]$Path, [string[]]$ScriptArgs)
    $ErrorActionPreference = 'SilentlyContinue'
    $out = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $Path @ScriptArgs 2>&1)
    return [pscustomobject]@{ Code = $LASTEXITCODE; Text = ($out -join "`n"); Lines = $out }
}

function Invoke-GitIn {
    param([string]$At, [string[]]$GitArgs)
    $ErrorActionPreference = 'SilentlyContinue'
    $out = @(& git -C $At @GitArgs 2>&1)
    return [pscustomobject]@{ Code = $LASTEXITCODE; Text = ($out -join "`n"); Lines = $out }
}

$sandbox = Join-Path $env:TEMP ("ship-workflow-" + [guid]::NewGuid().ToString('N').Substring(0, 8))

try {
    # =====================================================================
    Say ''
    Say 'A - ship-readiness reports honestly'
    # =====================================================================

    if (-not (Test-Path $Readiness)) {
        Skip 'A (all)' 'scripts\ship-readiness.ps1 missing'
    }
    else {
        $before = (Invoke-GitIn $Repo @('status', '--porcelain')).Text
        $headBefore = (Invoke-GitIn $Repo @('rev-parse', 'HEAD')).Text
        $fetchHead = Join-Path $Repo '.git\FETCH_HEAD'
        $fetchBefore = if (Test-Path $fetchHead) { (Get-Item $fetchHead).LastWriteTimeUtc } else { $null }

        $r = Invoke-Script $Readiness @('-Json', '-Repo', $Repo)
        $payload = $null
        try { $payload = $r.Text | ConvertFrom-Json } catch { $payload = $null }

        Assert 'A1 -Json emits a parseable payload' ($null -ne $payload) "text: $($r.Text.Substring(0, [Math]::Min(200, $r.Text.Length)))"

        if ($payload) {
            $names = @($payload.criteria | ForEach-Object { $_.Name })
            # The criterion set is the contract. A criterion that silently
            # disappears is a gate that silently stopped gating, and every one
            # of these is load-bearing for the cutover decision.
            $required = @('tree', 'push', 'behind', 'p0', 'inprogress', 'macseat', 'guards', 'ghrepo', 'lanes', 'accept')
            $missing = @($required | Where-Object { $names -notcontains $_ })
            Assert 'A2 every cutover criterion is reported' ($missing.Count -eq 0) "missing: $($missing -join ',')"

            # An unmeasured criterion must never read as satisfied. This is the
            # assertion that keeps -RunLanes honest: without it, "the lanes were
            # green last week" is not evidence and must not produce READY.
            $lanes = @($payload.criteria | Where-Object { $_.Name -eq 'lanes' })[0]
            $accept = @($payload.criteria | Where-Object { $_.Name -eq 'accept' })[0]
            Assert 'A3 lanes are UNKNOWN without -RunLanes' ($lanes.State -eq 'UNKNOWN') "state: $($lanes.State)"
            Assert 'A4 accept is UNKNOWN without -RunLanes' ($accept.State -eq 'UNKNOWN') "state: $($accept.State)"
            Assert 'A5 UNKNOWN counts as unmet' (@($payload.unmet) -contains 'lanes' -and @($payload.unmet) -contains 'accept') `
                "unmet: $(@($payload.unmet) -join ',')"
            Assert 'A6 an unmet criterion means not ready' ($payload.ready -eq $false) "ready: $($payload.ready)"
            Assert 'A7 the verdict is the exit code' ($r.Code -eq 1) "exit: $($r.Code)"

            # Every failure carries a way out. A gate whose message is only
            # "no" is a gate somebody eventually deletes.
            $noRemedy = @($payload.criteria | Where-Object { $_.State -ne 'PASS' -and -not $_.Remedy })
            Assert 'A8 every unmet criterion carries a remedy' ($noRemedy.Count -eq 0) `
                "without remedy: $(@($noRemedy | ForEach-Object { $_.Name }) -join ',')"

            # The numbers are git's, not the script's opinion of git.
            $behind = @($payload.criteria | Where-Object { $_.Name -eq 'behind' })[0]
            $realBehind = (Invoke-GitIn $Repo @('rev-list', '--count', 'HEAD..origin/main')).Text.Trim()
            if ($realBehind -match '^\d+$') {
                if ([int]$realBehind -eq 0) {
                    Assert 'A9 behind matches git (contained)' ($behind.State -eq 'PASS') "detail: $($behind.Detail)"
                }
                else {
                    Assert 'A9 behind matches git' ($behind.State -eq 'FAIL' -and $behind.Detail -match "^$realBehind commit") `
                        "git says $realBehind; detail: $($behind.Detail)"
                }
            }
            else {
                Skip 'A9 behind matches git' 'origin/main not resolvable here'
            }
        }

        # A readiness check that fetched, staged, or otherwise moved the repo it
        # is judging would make its own answer a moving target - and this one is
        # meant to be safe to run at any point in a turn.
        $after = (Invoke-GitIn $Repo @('status', '--porcelain')).Text
        $headAfter = (Invoke-GitIn $Repo @('rev-parse', 'HEAD')).Text
        $fetchAfter = if (Test-Path $fetchHead) { (Get-Item $fetchHead).LastWriteTimeUtc } else { $null }
        Assert 'A10 readiness does not change the working tree' ($before -eq $after)
        Assert 'A11 readiness does not move HEAD' ($headBefore -eq $headAfter)
        Assert 'A12 readiness does not fetch' ($fetchBefore -eq $fetchAfter) `
            "FETCH_HEAD $fetchBefore -> $fetchAfter"

        # The gh criterion must have teeth: pointed at a repository that is not
        # the fork, it has to fail. Otherwise "gh is configured" would be
        # satisfied by gh being configured for ANYTHING, which is precisely the
        # upstream-by-default state this criterion exists to catch.
        $r2 = Invoke-Script $Readiness @('-Json', '-Repo', $Repo, '-ForkRepo', 'nobody/not-a-repo')
        $p2 = $null
        try { $p2 = $r2.Text | ConvertFrom-Json } catch { $p2 = $null }
        if ($p2) {
            $gh2 = @($p2.criteria | Where-Object { $_.Name -eq 'ghrepo' })[0]
            Assert 'A13 ghrepo fails when gh does not resolve to the named fork' ($gh2.State -eq 'FAIL') `
                "state: $($gh2.State) detail: $($gh2.Detail)"
        }
        else {
            Skip 'A13 ghrepo teeth' 'second readiness run did not emit JSON'
        }
    }

    # =====================================================================
    Say ''
    Say 'B - the feature lifecycle, in a sandbox'
    # =====================================================================

    if (-not (Test-Path $Feature)) {
        Skip 'B (all)' 'scripts\ship-feature.ps1 missing'
    }
    else {
        # A bare repo standing in for origin, and a clone standing in for this
        # working tree. Real git all the way down: the subject's whole job is
        # git plumbing, and a mocked git would assert nothing.
        $originDir = Join-Path $sandbox 'origin.git'
        $workDir = Join-Path $sandbox 'repo'
        New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
        & git init --bare -b main $originDir *> $null
        & git clone $originDir $workDir *> $null
        & git -C $workDir config user.email 'test@example.com' *> $null
        & git -C $workDir config user.name 'Ship Workflow Test' *> $null
        Set-Content -Path (Join-Path $workDir 'README.md') -Value 'seed' -Encoding ascii
        & git -C $workDir add README.md *> $null
        & git -C $workDir commit -m 'seed' *> $null
        & git -C $workDir push -u origin main *> $null

        # gh is deliberately pointed at a repository that does not exist, so the
        # PR lookups fail and return "no PR known" rather than reaching over the
        # network to the real fork from a test.
        $sandboxArgs = @('-Repo', $workDir, '-ForkRepo', 'nobody/not-a-repo')
        $wtRoot = "$workDir-wt"

        $b1 = Invoke-Script $Feature (@('new', '-Slug', 'demo-feature') + $sandboxArgs + @('-NoFetch'))
        $demoDir = Join-Path $wtRoot 'demo-feature'
        Assert 'B1 new creates the worktree' ($b1.Code -eq 0 -and (Test-Path $demoDir)) "exit $($b1.Code): $($b1.Text)"
        $demoBranch = (Invoke-GitIn $demoDir @('rev-parse', '--abbrev-ref', 'HEAD')).Text.Trim()
        Assert 'B2 the branch carries the prefix' ($demoBranch -eq 'users/dzearing/demo-feature') "branch: $demoBranch"
        $forkedFrom = (Invoke-GitIn $demoDir @('rev-parse', 'HEAD')).Text.Trim()
        $trunkSha = (Invoke-GitIn $workDir @('rev-parse', 'origin/main')).Text.Trim()
        Assert 'B3 it forks from the trunk' ($forkedFrom -eq $trunkSha) "$forkedFrom vs $trunkSha"

        $b4 = Invoke-Script $Feature (@('new', '-Slug', 'demo-feature') + $sandboxArgs + @('-NoFetch'))
        Assert 'B4 a duplicate slug is refused' ($b4.Code -eq 1 -and $b4.Text -match 'REFUSED') "exit $($b4.Code): $($b4.Text)"

        $b5 = Invoke-Script $Feature (@('new', '-Slug', 'Not A Slug') + $sandboxArgs + @('-NoFetch'))
        Assert 'B5 a non-kebab slug is refused' ($b5.Code -eq 1 -and $b5.Text -match 'REFUSED') "exit $($b5.Code): $($b5.Text)"

        $b6 = Invoke-Script $Feature (@('list', '-Json') + $sandboxArgs)
        $rows = $null
        try { $rows = @($b6.Text | ConvertFrom-Json) } catch { $rows = $null }
        Assert 'B6 list finds the worktree' ($null -ne $rows -and @($rows | Where-Object { $_.Slug -eq 'demo-feature' }).Count -eq 1) `
            "text: $($b6.Text)"

        # Nothing proposed yet: a PR over zero commits describes nothing, and
        # opening one is a notification everybody learns to ignore.
        $b7 = Invoke-Script $Feature (@('pr', '-Slug', 'demo-feature', '-Title', 'x') + $sandboxArgs)
        Assert 'B7 pr over zero commits is refused' ($b7.Code -eq 1 -and $b7.Text -match 'no commits of its own') `
            "exit $($b7.Code): $($b7.Text)"

        Set-Content -Path (Join-Path $demoDir 'feature.txt') -Value 'work' -Encoding ascii
        $b8 = Invoke-Script $Feature (@('pr', '-Slug', 'demo-feature', '-Title', 'x') + $sandboxArgs)
        Assert 'B8 pr over a dirty tree is refused' ($b8.Code -eq 1 -and $b8.Text -match 'uncommitted') `
            "exit $($b8.Code): $($b8.Text)"

        & git -C $demoDir add feature.txt *> $null
        & git -C $demoDir commit -m 'feature work' *> $null

        $b9 = Invoke-Script $Feature (@('list', '-Json') + $sandboxArgs)
        $rows9 = $null
        try { $rows9 = @($b9.Text | ConvertFrom-Json) } catch { $rows9 = $null }
        $row9 = if ($rows9) { @($rows9 | Where-Object { $_.Slug -eq 'demo-feature' })[0] } else { $null }
        Assert 'B9 list counts the commit' ($null -ne $row9 -and "$($row9.Ahead)" -eq '1') "row: $($b9.Text)"

        # The refusal that protects work: the commit exists only here.
        $b10 = Invoke-Script $Feature (@('done', '-Slug', 'demo-feature') + $sandboxArgs)
        Assert 'B10 done refuses unpushed commits' ($b10.Code -eq 1 -and $b10.Text -match 'never pushed|not pushed') `
            "exit $($b10.Code): $($b10.Text)"
        Assert 'B11 the refusal left the worktree alone' (Test-Path $demoDir)

        & git -C $demoDir push -u origin $demoBranch *> $null

        $b12 = Invoke-Script $Feature (@('done', '-Slug', 'demo-feature') + $sandboxArgs)
        Assert 'B12 done removes a pushed worktree' ($b12.Code -eq 0 -and -not (Test-Path $demoDir)) `
            "exit $($b12.Code): $($b12.Text)"
        $branchGone = (Invoke-GitIn $workDir @('rev-parse', '--verify', '--quiet', "refs/heads/$demoBranch")).Code -ne 0
        Assert 'B13 done deletes the local branch' $branchGone

        $b14 = Invoke-Script $Feature (@('done', '-Slug', 'demo-feature') + $sandboxArgs)
        Assert 'B14 done on a missing worktree is refused, not a crash' ($b14.Code -eq 1 -and $b14.Text -match 'REFUSED') `
            "exit $($b14.Code): $($b14.Text)"

        # -Force is the abandon path: it must work over exactly the state that
        # the unforced path refuses, and it must say that it was used.
        Invoke-Script $Feature (@('new', '-Slug', 'abandoned') + $sandboxArgs + @('-NoFetch')) | Out-Null
        $abDir = Join-Path $wtRoot 'abandoned'
        Set-Content -Path (Join-Path $abDir 'scratch.txt') -Value 'junk' -Encoding ascii
        & git -C $abDir add scratch.txt *> $null
        & git -C $abDir commit -m 'unpushed' *> $null
        $b15 = Invoke-Script $Feature (@('done', '-Slug', 'abandoned', '-Force') + $sandboxArgs)
        Assert 'B15 -Force discards an abandoned feature' ($b15.Code -eq 0 -and -not (Test-Path $abDir)) `
            "exit $($b15.Code): $($b15.Text)"
        Assert 'B16 -Force says it was used' ($b15.Text -match '-Force was used') "text: $($b15.Text)"

        $b17 = Invoke-Script $Feature (@('list') + $sandboxArgs)
        Assert 'B17 list handles the empty state' ($b17.Code -eq 0 -and $b17.Text -match 'no feature worktrees') `
            "exit $($b17.Code): $($b17.Text)"
    }

    # =====================================================================
    Say ''
    Say 'C - the gh landmine cannot come back'
    # =====================================================================

    # Every gh invocation in the family names its repository. Written as a scan
    # rather than a behavioural assertion on purpose: the failure is a call that
    # SUCCEEDS against the wrong repository, so there is no error to catch - by
    # the time anything is observable, a pull request exists on somebody else's
    # project.
    $familyScripts = @($Readiness, $Feature, $Review) | Where-Object { Test-Path $_ }
    $bareGh = @()
    foreach ($f in $familyScripts) {
        $lineNo = 0
        $inHelp = $false
        foreach ($line in (Get-Content $f)) {
            $lineNo++
            # The comment-based help block explains the landmine at length, so
            # scanning it finds the prose describing the bug and reports it AS
            # the bug. Skip the help block and ordinary line comments; what is
            # left is code.
            if ($line -match '^\s*<#') { $inHelp = $true }
            if ($inHelp) {
                if ($line -match '#>') { $inHelp = $false }
                continue
            }
            if ($line -match '^\s*#') { continue }
            # `gh pr`, `gh issue`, `gh api`, `gh run` - the repository-scoped
            # verbs. `gh repo set-default` and `gh auth` are not, and reading
            # the configured default is the whole point of the ghrepo check.
            if ($line -match '\bgh\s+(pr|issue|api|run)\b' -and $line -notmatch '--repo') {
                $bareGh += ("{0}:{1}: {2}" -f (Split-Path -Leaf $f), $lineNo, $line.Trim())
            }
        }
    }
    Assert 'C1 no repository-scoped gh call omits --repo' ($bareGh.Count -eq 0) ("`n    " + ($bareGh -join "`n    "))

    # The fork's own name must be a default somewhere, not a value every caller
    # is expected to remember and type.
    $forkDefaulted = @($familyScripts | Where-Object { (Get-Content $_ -Raw) -match "ForkRepo\s*=\s*'dzearing/ghoztty'" })
    Assert 'C2 the fork is the default -ForkRepo in every family script' ($forkDefaulted.Count -eq $familyScripts.Count) `
        "defaulted in $($forkDefaulted.Count) of $($familyScripts.Count)"

    # And the funnel is single. `--repo` on every call site is only as good as
    # the number of call sites somebody has to remember to write it on; one
    # funnel makes the NEXT call site inherit the guard instead of needing it.
    foreach ($funnelScript in @($Feature, $Review)) {
    if (-not (Test-Path $funnelScript)) { continue }
    $funnelName = [System.IO.Path]::GetFileNameWithoutExtension($funnelScript)
    $ghSites = @()
    $inHelp2 = $false
    $lineNo2 = 0
    foreach ($line in (Get-Content $funnelScript)) {
        $lineNo2++
        if ($line -match '^\s*<#') { $inHelp2 = $true }
        if ($inHelp2) {
            if ($line -match '#>') { $inHelp2 = $false }
            continue
        }
        if ($line -match '^\s*#') { continue }
        if ($line -match '&\s*gh\b') { $ghSites += "$lineNo2" }
    }
    Assert "C3 gh is invoked from exactly one place in $funnelName" ($ghSites.Count -eq 1) `
        "invocation lines: $($ghSites -join ',')"
    }

    # =====================================================================
    Say ''
    Say 'D - the workflow is reachable from the docs a turn actually reads'
    # =====================================================================

    if (-not (Test-Path $Doc)) {
        Assert 'D1 the ship-workflow doc exists' $false "expected $Doc"
    }
    else {
        $docText = Get-Content $Doc -Raw
        Assert 'D1 the ship-workflow doc exists' $true
        # The doc has to carry the whole lifecycle, or a turn reading it stops
        # somewhere in the middle and improvises the rest - which is the state
        # this task exists to end.
        $lifecycle = @('ship-readiness.ps1', 'ship-feature.ps1 new', 'ship-feature.ps1 pr', 'ship-feature.ps1 done')
        $absent = @($lifecycle | Where-Object { $docText -notmatch [regex]::Escape($_) })
        Assert 'D2 the doc covers the whole lifecycle' ($absent.Count -eq 0) "absent: $($absent -join ', ')"
        Assert 'D3 the doc names the gh landmine' ($docText -match '--repo') 'no --repo guidance in the doc'
    }

    if (-not (Test-Path $GoMd)) {
        Skip 'D4 go.md reaches the workflow' 'go.md missing'
    }
    else {
        $goText = Get-Content $GoMd -Raw
        Assert 'D4 go.md reaches the readiness gate' ($goText -match 'ship-readiness\.ps1')
        Assert 'D5 go.md reaches the feature lifecycle' ($goText -match 'ship-feature\.ps1')
        Assert 'D6 go.md links the workflow doc' ($goText -match 'windows-parity-ship-workflow\.md')
    }
    if (Test-Path $Doc) {
        $docText2 = Get-Content $Doc -Raw
        Assert 'D7 the doc carries the review checklist markers pr-review prompt reads' `
            ($docText2 -match '<!-- review-checklist:begin -->' -and $docText2 -match '<!-- review-checklist:end -->')
    }

    # =====================================================================
    Say ''
    Say 'E - the adversarial review gate catches what it exists to catch (T1060)'
    # =====================================================================

    # The teeth-check for the reviewer itself: a sandbox repo with one PR that
    # carries every defect the gate names, planted on purpose, and one clean PR
    # that must pass without invented findings. A rule that does not fire on
    # its own planted defect is a rule that cannot fire.
    if (-not (Test-Path $Review)) {
        Skip 'E (all)' 'scripts\pr-review.ps1 missing'
    }
    else {
        $rvOrigin = Join-Path $sandbox 'review-origin.git'
        $rvDir = Join-Path $sandbox 'review'
        New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
        & git init --bare -b main $rvOrigin *> $null
        & git clone $rvOrigin $rvDir *> $null
        & git -C $rvDir config user.email 'test@example.com' *> $null
        & git -C $rvDir config user.name 'Review Gate Test' *> $null
        function Write-Rv([string]$Rel, [string]$Text) {
            $p = Join-Path $rvDir $Rel
            New-Item -ItemType Directory -Path (Split-Path $p -Parent) -Force | Out-Null
            [System.IO.File]::WriteAllText($p, $Text, (New-Object System.Text.UTF8Encoding($false)))
        }
        function Commit-Rv([string]$Msg) {
            & git -C $rvDir add -A *> $null
            & git -C $rvDir commit -q -m $Msg *> $null
            return (Invoke-GitIn $rvDir @('rev-parse', 'HEAD')).Text.Trim()
        }
        # The base: a shared library helper, a frontend file, and the real
        # workflow doc (prompt reads its checklist from the repo it reviews).
        Write-Rv 'scripts/lib/Shared.ps1' "function Get-SharedThing {`n    param([string]`$x)`n    return `$x`n}`n"
        Write-Rv 'src/apprt/win32/base.zig' "pub fn parseKeyValue(s: []const u8) []const u8 {`n    return s;`n}`n"
        Write-Rv 'docs/design/windows-parity-ship-workflow.md' (Get-Content $Doc -Raw)
        $rvBase = Commit-Rv 'base'
        & git -C $rvDir push -q -u origin main *> $null

        # --- the planted-defect PR ------------------------------------------
        & git -C $rvDir checkout -q -b bad *> $null
        Write-Rv 'docs/design/windows-parity-tasks/T9001.md' ("---`nid: T9001`nseat: `"win`"`ntags: [`"feature`"]`n---`n`n# T9001`n`n" +
            "## Validation criteria`n`n- [x] it works`n- [x] the overlay draws: ``test\win32\overlay.ps1`` ALL PASS (12)`n")
        Write-Rv 'scripts/tool.ps1' "function Get-SharedThing {`n    return 1`n}`n"
        Write-Rv 'src/apprt/win32/bad.zig' ("fn parseKeyValue(s: []const u8) []const u8 {`n    return s;`n}`n`n" +
            "test `"looks like a test`" {`n    _ = parseKeyValue(`"a`");`n}`n")
        Write-Rv 'test/win32/bad.ps1' "Assert 'always' `$true`nAssert `"also always`" `$true`n"
        $rvBad = Commit-Rv 'a windows-only feature with every planted defect'

        $e1 = Invoke-Script $Review @('check', '-Repo', $rvDir, '-Base', $rvBase, '-Head', $rvBad, '-Json')
        $e1p = $null
        try { $e1p = $e1.Text | ConvertFrom-Json } catch { $e1p = $null }
        $keys = if ($e1p) { @($e1p.findings | ForEach-Object { $_.Key }) } else { @() }
        Assert 'E1 check exits 1 over the planted PR' ($e1.Code -eq 1) "exit $($e1.Code): $($e1.Text)"
        Assert 'E2 the unevidenced tick is caught, the evidenced one is not' `
            (@($keys | Where-Object { $_ -like 'unproven-tick:*T9001.md:L11' }).Count -eq 1 -and @($keys | Where-Object { $_ -like 'unproven-tick:*' }).Count -eq 1) `
            "keys: $($keys -join ', ')"
        Assert 'E3 the one-platform feature is caught' (@($keys | Where-Object { $_ -like 'one-platform:*' }).Count -eq 1) "keys: $($keys -join ', ')"
        Assert 'E4 the duplicated PowerShell helper is caught' ($keys -contains 'duplicate-helper:scripts/tool.ps1:Get-SharedThing') "keys: $($keys -join ', ')"
        Assert 'E5 the duplicated zig helper is caught' ($keys -contains 'duplicate-helper:src/apprt/win32/bad.zig:parseKeyValue') "keys: $($keys -join ', ')"
        Assert 'E6 the zig test that cannot fail is caught' ($keys -contains 'toothless-test:src/apprt/win32/bad.zig:looks like a test') "keys: $($keys -join ', ')"
        Assert 'E7 the harness whose asserts are all $true is caught' ($keys -contains 'toothless-test:test/win32/bad.ps1') "keys: $($keys -join ', ')"

        # A pass cannot be recorded over that, and the refusal names the keys.
        $e8 = Invoke-Script $Review @('record', '-Repo', $rvDir, '-Base', $rvBase, '-Head', $rvBad, '-Verdict', 'pass', '-Summary', 'lgtm')
        Assert 'E8 record refuses a pass over unanswered findings' ($e8.Code -eq 1 -and $e8.Text -match 'REFUSED' -and $e8.Text -match 'one-platform') `
            "exit $($e8.Code): $($e8.Text)"
        $e9 = Invoke-Script $Review @('gate', '-Repo', $rvDir, '-Head', $rvBad)
        Assert 'E9 gate is shut with no review recorded' ($e9.Code -eq 1 -and $e9.Text -match 'REVIEW MISSING') "exit $($e9.Code): $($e9.Text)"

        $e10 = Invoke-Script $Review @('prompt', '-Repo', $rvDir, '-Base', $rvBase, '-Head', $rvBad)
        Assert 'E10 the brief carries the doc checklist and every finding' `
            ($e10.Code -eq 0 -and $e10.Text -match 'Default to NOT PROVEN' -and $e10.Text -match 'duplicate-helper:scripts/tool.ps1:Get-SharedThing' -and $e10.Text -match 'VERDICT: FAIL') `
            "exit $($e10.Code)"

        $e11 = Invoke-Script $Review @('record', '-Repo', $rvDir, '-Base', $rvBase, '-Head', $rvBad, '-Verdict', 'fail', '-Summary', 'five planted defects')
        $e11g = Invoke-Script $Review @('gate', '-Repo', $rvDir, '-Head', $rvBad)
        Assert 'E11 a recorded fail keeps the gate shut' ($e11.Code -eq 0 -and $e11g.Code -eq 1 -and $e11g.Text -match 'REVIEW FAILED') `
            "record $($e11.Code) / gate $($e11g.Code): $($e11g.Text)"

        # --- untested code --------------------------------------------------
        & git -C $rvDir checkout -q main *> $null
        & git -C $rvDir checkout -q -b untested *> $null
        Write-Rv 'scripts/other.ps1' "Write-Host 'changed behaviour'`n"
        $rvUntested = Commit-Rv 'code with no test'
        $e12 = Invoke-Script $Review @('check', '-Repo', $rvDir, '-Base', $rvBase, '-Head', $rvUntested)
        Assert 'E12 code changed with no test is caught' ($e12.Code -eq 1 -and $e12.Text -match '\[untested:scripts/other.ps1\]') "exit $($e12.Code): $($e12.Text)"

        # A waiver is the recorded answer: it opens the gate, and it is IN the record.
        $e13 = Invoke-Script $Review @('record', '-Repo', $rvDir, '-Base', $rvBase, '-Head', $rvUntested, '-Verdict', 'pass', '-Summary', 'ok',
            '-Waive', 'untested:scripts/other.ps1=a log line only')
        $e13g = Invoke-Script $Review @('gate', '-Repo', $rvDir, '-Head', $rvUntested)
        $ledger = Join-Path $rvDir ".git\ghoztty-review\$rvUntested.json"
        $ledgerText = if (Test-Path $ledger) { Get-Content $ledger -Raw } else { '' }
        Assert 'E13 a waived finding allows a pass and the gate opens' ($e13.Code -eq 0 -and $e13g.Code -eq 0 -and $e13g.Text -match 'REVIEW PASS') `
            "record $($e13.Code): $($e13.Text) / gate $($e13g.Code): $($e13g.Text)"
        Assert 'E14 the waiver is written into the verdict' ($ledgerText -match 'a log line only') "ledger: $ledgerText"
        $e15 = Invoke-Script $Review @('record', '-Repo', $rvDir, '-Base', $rvBase, '-Head', $rvUntested, '-Verdict', 'pass', '-Summary', 'ok',
            '-Waive', 'untested:scripts/nope.ps1=invented')
        Assert 'E15 a waiver for a finding that is not reported is refused' ($e15.Code -eq 1) "exit $($e15.Code): $($e15.Text)"

        # A push after the review: the verdict was for the older commit.
        Write-Rv 'scripts/other.ps1' "Write-Host 'changed again after review'`n"
        $rvLater = Commit-Rv 'after the review'
        $e16 = Invoke-Script $Review @('gate', '-Repo', $rvDir, '-Head', $rvLater)
        Assert 'E16 a review of an older commit is STALE, not a pass' ($e16.Code -eq 1 -and $e16.Text -match 'REVIEW STALE' -and $e16.Text -match $rvUntested.Substring(0, 9)) `
            "exit $($e16.Code): $($e16.Text)"

        # --- the clean PR: no invented findings -----------------------------
        & git -C $rvDir checkout -q main *> $null
        & git -C $rvDir checkout -q -b clean *> $null
        Write-Rv 'docs/design/windows-parity-tasks/T9002.md' ("---`nid: T9002`nseat: `"win`"`ntags: [`"feature`"]`n---`n`n# T9002 - the banner fades, as it does on the Mac`n`n" +
            "## Validation criteria`n`n- [x] the fade runs: ``test\win32\banner.ps1`` section C, ALL PASS (9)`n")
        Write-Rv 'src/apprt/win32/fade.zig' ("const std = @import(`"std`");`n`nfn fadeStep(a: u8) u8 {`n    return a -| 16;`n}`n`n" +
            "test `"fade steps down`" {`n    try std.testing.expectEqual(@as(u8, 4), fadeStep(20));`n}`n")
        $rvClean = Commit-Rv 'the banner fades'
        $e17 = Invoke-Script $Review @('check', '-Repo', $rvDir, '-Base', $rvBase, '-Head', $rvClean)
        Assert 'E17 a clean PR passes check with no invented findings' ($e17.Code -eq 0 -and $e17.Text -match 'REVIEW CHECK CLEAN') "exit $($e17.Code): $($e17.Text)"

        # --- the merge verb runs the gate -----------------------------------
        $mgArgs = @('-Repo', $rvDir, '-ForkRepo', 'nobody/not-a-repo')
        $e18n = Invoke-Script $Feature (@('new', '-Slug', 'gated') + $mgArgs + @('-NoFetch'))
        $gatedDir = Join-Path "$rvDir-wt" 'gated'
        if ($e18n.Code -ne 0 -or -not (Test-Path $gatedDir)) {
            Assert 'E18 merge sandbox worktree created' $false "exit $($e18n.Code): $($e18n.Text)"
        }
        else {
            [System.IO.File]::WriteAllText((Join-Path $gatedDir 'notes.md'), "gated work`n")
            & git -C $gatedDir add -A *> $null
            & git -C $gatedDir commit -q -m 'gated work' *> $null
            & git -C $gatedDir push -q -u origin users/dzearing/gated *> $null
            $e18 = Invoke-Script $Feature (@('merge', '-Slug', 'gated') + $mgArgs)
            Assert 'E18 merge refuses with no review of the head' ($e18.Code -eq 1 -and $e18.Text -match 'REVIEW MISSING' -and $e18.Text -match 'REFUSED') `
                "exit $($e18.Code): $($e18.Text)"
            $e19 = Invoke-Script $Feature (@('merge', '-Slug', 'gated', '-Override') + $mgArgs)
            Assert 'E19 -Override without -Reason is refused' ($e19.Code -eq 1 -and $e19.Text -match 'needs -Reason') "exit $($e19.Code): $($e19.Text)"
            $e20r = Invoke-Script $Review @('record', '-Repo', $gatedDir, '-Base', 'origin/main', '-Head', 'HEAD', '-Verdict', 'pass', '-Summary', 'refuted nothing')
            $e20 = Invoke-Script $Feature (@('merge', '-Slug', 'gated') + $mgArgs)
            # The gate opens; the merge then stops at the PR lookup because gh is
            # pointed at a repository that does not exist - nothing leaves the box.
            Assert 'E20 a review recorded from the worktree opens the merge gate' `
                ($e20r.Code -eq 0 -and $e20.Text -match 'REVIEW PASS' -and $e20.Text -match 'no pull request found') `
                "record $($e20r.Code): $($e20r.Text) / merge $($e20.Code): $($e20.Text)"
            & git -C $rvDir worktree remove --force $gatedDir *> $null
        }
    }
}
catch {
    # A crash mid-run used to fall straight through to the verdict and print ALL
    # PASS over the handful of assertions that had run before it - the shape
    # verdict-exit-audit exists to distrust.
    Write-Host "  FAIL harness crashed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "    at $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())"
    $script:failures++
}
finally {
    # Worktrees hold administrative files under the parent repo's .git, so the
    # directory tree is only half the cleanup; prune what the sandbox left
    # behind before the sandbox itself goes.
    $workDirCleanup = Join-Path $sandbox 'repo'
    if (Test-Path -LiteralPath $workDirCleanup) {
        & git -C $workDirCleanup worktree prune *> $null
    }
    foreach ($p in @("$sandbox", "$sandbox-wt", (Join-Path $sandbox 'repo-wt'))) {
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# A clean green run stamps the covered files (T783) so scripts\guard-due.ps1 can
# answer "has anybody run this against the workflow as it now stands?". A red
# run - or one with skipped sections - leaves the stamp alone.
Complete-TestBody  # T1039: before the stamp, which is a child process reading this run's state
if ($script:failures -eq 0 -and $script:skips -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard ship-workflow -Repo $Repo 2>&1 | ForEach-Object { "  $_" }
}

Say ''
Write-TestVerdict -Pass $script:passes -Fail $script:failures -Skipped $script:skips -Label 'SHIP-WORKFLOW'
