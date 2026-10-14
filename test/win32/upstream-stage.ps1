# T1026 acceptance - the pre-flight gate before an upstream pull stage.
#
#   powershell -NoProfile -File test\win32\upstream-stage.ps1
#
# Non-interactive. Launches no Ghoztty and touches no user state: the subject is
# a gate script over git state, so everything below runs inside throwaway repos
# under $env:TEMP.
#
# isolation: none - no ghoztty binary is run and no CLI verb is invoked; the
# only executables this script starts are git and child PowerShells running the
# script under test (T680 meta-check reads this marker).
#
# WHY IT EXISTS
#
# `scripts\upstream-remote.ps1 check` asserts that every sha the upstream pull
# plan pins still resolves and is anchored, and before T1026 nothing called it:
# a merge stage could begin against a plan whose shas had gone missing, a dirty
# tree, an unpushed base, or a base the floor had never seen green.
# `scripts\upstream-stage.ps1 preflight` is that missing call. A gate is only a
# gate if it can be watched saying no, so almost every case below constructs a
# state the gate must REFUSE and asserts that it does - and that the expensive
# floor is not run over a base that is already refused.
#
# The three heavy sibling gates (fork-identity, guard-due, floor-lane) are
# replaced by stubs through -ScriptsDir: what is under test here is the order,
# the arguments each is given, and what the verdict does with its exit code -
# not the twenty-minute floor itself. upstream-remote.ps1 is NOT stubbed: the
# fixture copies the real one, so P4 is the real assertion over a real repo.
param(
    [string]$Repo,
    [switch]$NegativeControl
)

$ErrorActionPreference = 'Continue'
if (-not $Repo) { $Repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }

# T1511: the shared scorer, and the dot-source is also what ARMS the run.
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:failures = 0
$script:passes = 0
function Assert($name, $cond, $detail = '') {
    if ($cond) { Write-Host "  PASS $name"; $script:passes++ }
    else { Write-Host "  FAIL $name $detail" -ForegroundColor Red; $script:failures++ }
}
function Say($m) { Write-Host $m }

$StageScript = Join-Path $Repo 'scripts\upstream-stage.ps1'
$RemoteScript = Join-Path $Repo 'scripts\upstream-remote.ps1'
$UpstreamUrl = 'https://github.com/ghostty-org/ghostty.git'

function Invoke-GitIn {
    param([string]$At, [string[]]$GitArgs)
    $ErrorActionPreference = 'SilentlyContinue'
    $out = @(& git -C $At @GitArgs 2>$null)
    return [pscustomobject]@{ Code = $LASTEXITCODE; Text = ($out -join "`n").Trim(); Lines = $out }
}
$Ident = @('-c', 'user.email=t@example.invalid', '-c', 'user.name=t', '-c', 'commit.gpgsign=false')
function Invoke-GitCommit {
    param([string]$At, [string[]]$GitArgs)
    $ErrorActionPreference = 'SilentlyContinue'
    $out = @(& git -C $At @Ident @GitArgs 2>$null)
    return [pscustomobject]@{ Code = $LASTEXITCODE; Text = ($out -join "`n").Trim() }
}
function New-Commit {
    param([string]$At, [string]$File, [string]$Text, [string]$Msg)
    Set-Content -LiteralPath (Join-Path $At $File) -Value $Text -Encoding ASCII
    Invoke-GitIn $At @('add', '--', $File) | Out-Null
    Invoke-GitCommit $At @('commit', '-q', '-m', $Msg) | Out-Null
    return (Invoke-GitIn $At @('rev-parse', 'HEAD')).Text
}

$sandbox = Join-Path $env:TEMP "ghoztty-upstream-stage-$PID"
if (Test-Path -LiteralPath $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force }
New-Item -ItemType Directory -Force -Path $sandbox | Out-Null

# Runs the gate as a child and returns exit code + lines. Stub behaviour is set
# through environment variables the stubs read, and every stub appends one line
# to the call log so the ORDER and ARGUMENTS can be asserted.
$StubLog = Join-Path $sandbox 'stub-calls.log'
function Invoke-Stage {
    param([string]$At, [string[]]$StageArgs, [hashtable]$Exits = @{})
    if (Test-Path -LiteralPath $StubLog) { Remove-Item -LiteralPath $StubLog -Force }
    foreach ($n in @('FORK', 'GUARD', 'FLOOR')) {
        $v = if ($Exits.ContainsKey($n)) { [string]$Exits[$n] } else { '0' }
        Set-Item -Path "env:UPSTREAM_STAGE_STUB_$n" -Value $v
    }
    $env:UPSTREAM_STAGE_STUB_LOG = $StubLog
    $out = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $StageScript @StageArgs -Repo $At -ScriptsDir $stubDir 2>&1 | ForEach-Object { "$_" })
    $code = $LASTEXITCODE
    $calls = @()
    if (Test-Path -LiteralPath $StubLog) { $calls = @(Get-Content -LiteralPath $StubLog) }
    return [pscustomobject]@{ Code = $code; Lines = $out; Text = ($out -join "`n"); Calls = $calls }
}
function Get-Line {
    param($Run, [string]$Id)
    return (@($Run.Lines | Where-Object { $_ -match "^\s+$([regex]::Escape($Id))\s" }) | Select-Object -First 1)
}

try {

# ---------------------------------------------------------------------------
Say ''
Say 'A. the real plan, on this box'
# ---------------------------------------------------------------------------

Assert 'setup: scripts\upstream-stage.ps1 exists' (Test-Path -LiteralPath $StageScript)
$list = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $StageScript list -Repo $Repo 2>&1 | ForEach-Object { "$_" })
$listCode = $LASTEXITCODE
$stageRows = @($list | Where-Object { $_ -match '^S\d+\s+[0-9a-f]+\.\.[0-9a-f]+' })
Assert 'A1 `list` exits 0 on the real plan' ($listCode -eq 0) "(exit $listCode)"
Assert 'A2 the real plan defines six stages (S1..S6)' ($stageRows.Count -eq 6) "(got $($stageRows.Count): $($list -join ' / '))"
Assert 'A3 the real stage table is contiguous (no GAP line)' (@($list | Where-Object { $_ -match '^GAP' }).Count -eq 0) "(got: $($list -join ' / '))"
Assert 'A4 exactly one stage reads as next' (@($stageRows | Where-Object { $_ -match '\snext$' }).Count -eq 1) "(got: $($stageRows -join ' / '))"

# ---------------------------------------------------------------------------
Say ''
Say 'B. fixture: an upstream with two stages, a fork, and a pushed branch'
# ---------------------------------------------------------------------------

$stubDir = Join-Path $sandbox 'stubs'
New-Item -ItemType Directory -Force -Path $stubDir | Out-Null
# The real upstream-remote.ps1 - P4 is not stubbed.
Copy-Item -LiteralPath $RemoteScript -Destination (Join-Path $stubDir 'upstream-remote.ps1')
$stubBody = @'
$name = '__NAME__'
Add-Content -LiteralPath $env:UPSTREAM_STAGE_STUB_LOG -Value ("$name " + ($args -join ' '))
$code = [int]$env:__VAR__
if ($code -ne 0) { "GUARD DUE stub-harness: stub says no"; "  last line of $name" }
exit $code
'@
foreach ($s in @(@('fork-identity', 'UPSTREAM_STAGE_STUB_FORK'), @('guard-due', 'UPSTREAM_STAGE_STUB_GUARD'), @('floor-lane', 'UPSTREAM_STAGE_STUB_FLOOR'))) {
    $body = $stubBody.Replace('__NAME__', $s[0]).Replace('__VAR__', $s[1])
    Set-Content -LiteralPath (Join-Path $stubDir "$($s[0]).ps1") -Value $body -Encoding ASCII
}

# Upstream history: F (fork point) -> U1 -> U2.
$up = Join-Path $sandbox 'up'
New-Item -ItemType Directory -Force -Path $up | Out-Null
Invoke-GitIn $up @('init', '-q', '-b', 'main') | Out-Null
$F = New-Commit $up 'core.txt' 'fork point' 'fork point'
$U1 = New-Commit $up 'up1.txt' 'upstream one' 'upstream one'
$U2 = New-Commit $up 'up2.txt' 'upstream two' 'upstream two'
$f9 = $F.Substring(0, 9); $u19 = $U1.Substring(0, 9); $u29 = $U2.Substring(0, 9)

# Our side: a bare origin, and a clone branched from F with its own commit.
$bare = Join-Path $sandbox 'origin.git'
Invoke-GitIn $sandbox @('init', '-q', '--bare', $bare) | Out-Null
$work = Join-Path $sandbox 'work'
Invoke-GitIn $sandbox @('clone', '-q', $up, $work) | Out-Null
Invoke-GitIn $work @('remote', 'rename', 'origin', 'upsrc') | Out-Null
Invoke-GitIn $work @('checkout', '-q', '-b', 'ours', $F) | Out-Null
Invoke-GitIn $work @('remote', 'add', 'origin', $bare) | Out-Null

$planDir = Join-Path $work 'docs\design'
New-Item -ItemType Directory -Force -Path $planDir | Out-Null
$planPath = Join-Path $planDir 'windows-parity-upstream-pull-plan.md'
function Write-Plan {
    param([string]$S2From)
    $plan = @(
        '# fixture plan',
        '',
        '| Stage | Range | commits |',
        '|---|---|---|',
        "| S1 | ``$f9..$u19`` (first) | 1 |",
        "| **S2** | ``$S2From..$u29`` (second) | 1 |",
        '',
        "Fork point ``$f9``, merge ``$u19``, then merge ``$u29``."
    )
    Set-Content -LiteralPath $planPath -Value $plan -Encoding ASCII
}
Write-Plan -S2From $u19
Invoke-GitIn $work @('add', '--', 'docs') | Out-Null
Invoke-GitCommit $work @('commit', '-q', '-m', 'our plan') | Out-Null
Invoke-GitIn $work @('push', '-q', '-u', 'origin', 'ours') | Out-Null

# The upstream remote, wired the way `ensure` leaves it, without a network:
# canonical URL, upstream/main pointing at U2, anchors written by the REAL ensure.
Invoke-GitIn $work @('remote', 'add', 'upstream', $UpstreamUrl) | Out-Null
Invoke-GitIn $work @('update-ref', 'refs/remotes/upstream/main', $U2) | Out-Null
& powershell -NoProfile -ExecutionPolicy Bypass -File $RemoteScript ensure -Repo $work -NoFetch | Out-Null
$chk = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $RemoteScript check -Repo $work 2>&1)
Assert 'setup: the fixture passes the real upstream-remote check' ($LASTEXITCODE -eq 0) "(got: $($chk -join ' / '))"

# ---------------------------------------------------------------------------
Say ''
Say 'C. a ready base is let through - and every gate actually ran'
# ---------------------------------------------------------------------------

$ok = Invoke-Stage $work @('preflight', '-Stage', 'S1')
Assert 'C1 preflight S1 on a ready base exits 0' ($ok.Code -eq 0) "(exit $($ok.Code): $($ok.Text))"
Assert 'C2 ...and says PREFLIGHT OK S1' ($ok.Text -match '(?m)^PREFLIGHT OK S1\s*$') "(got: $($ok.Text))"
Assert 'C3 ...with P4 answered by the real upstream check' ((Get-Line $ok 'P4') -match '\bok\b.*UPSTREAM OK') "(got: $(Get-Line $ok 'P4'))"
Assert 'C4 fork-identity ran over the repo (-Path <repo>)' (@($ok.Calls | Where-Object { $_ -match '^fork-identity check -Path ' -and $_.Contains($work) }).Count -eq 1) "(calls: $($ok.Calls -join ' / '))"
Assert 'C5 guard-due ran against the repo (-Repo <repo>)' (@($ok.Calls | Where-Object { $_ -match '^guard-due check -Repo ' -and $_.Contains($work) }).Count -eq 1) "(calls: $($ok.Calls -join ' / '))"
Assert 'C6 the floor ran ALL lanes against the repo' (@($ok.Calls | Where-Object { $_ -match '^floor-lane -Lane all -Repo ' -and $_.Contains($work) }).Count -eq 1) "(calls: $($ok.Calls -join ' / '))"
Assert 'C7 ...and ran LAST, after the cheap gates' ($ok.Calls.Count -eq 3 -and $ok.Calls[2] -match '^floor-lane') "(calls: $($ok.Calls -join ' / '))"

# ---------------------------------------------------------------------------
Say ''
Say 'D. every check can say no'
# ---------------------------------------------------------------------------

# P2: a dirty tree.
Set-Content -LiteralPath (Join-Path $work 'stray.txt') -Value 'left behind' -Encoding ASCII
$d = Invoke-Stage $work @('preflight', '-Stage', 'S1')
Assert 'D1 a dirty tree is REFUSED (exit 1)' ($d.Code -eq 1) "(exit $($d.Code))"
Assert 'D2 ...by P2, naming the path' ((Get-Line $d 'P2') -match 'FAIL.*stray\.txt') "(got: $(Get-Line $d 'P2'))"
Assert 'D3 ...and the floor is NOT run over a refused base' (@($d.Calls | Where-Object { $_ -match '^floor-lane' }).Count -eq 0) "(calls: $($d.Calls -join ' / '))"
Assert 'D4 ...and the floor line says why it was skipped' ((Get-Line $d 'P8') -match 'skip.*already refused.*P2') "(got: $(Get-Line $d 'P8'))"
Remove-Item -LiteralPath (Join-Path $work 'stray.txt') -Force

# P3: a commit that never left the box.
$local = New-Commit $work 'local.txt' 'unpushed' 'unpushed work'
$p = Invoke-Stage $work @('preflight', '-Stage', 'S1')
Assert 'D5 an unpushed base is REFUSED by P3' ($p.Code -eq 1 -and (Get-Line $p 'P3') -match 'FAIL.*1 commit\(s\) ahead') "(exit $($p.Code): $(Get-Line $p 'P3'))"
$ph = Invoke-Stage $work @('preflight', '-Stage', 'S1', '-NoPushCheck')
Assert 'D6 -NoPushCheck lets it through but NAMES the hatch' ($ph.Code -eq 0 -and $ph.Text -match 'PREFLIGHT OK S1 \(hatches used: -NoPushCheck\)') "(exit $($ph.Code): $($ph.Text))"
Assert 'D7 ...and the skipped check reads skip, never ok' ((Get-Line $ph 'P3') -match '\bskip\b') "(got: $(Get-Line $ph 'P3'))"
Invoke-GitIn $work @('push', '-q', 'origin', 'ours') | Out-Null

# P4: a plan sha whose anchor is gone.
Invoke-GitIn $work @('tag', '-d', "upstream-anchor/$u29") | Out-Null
$a = Invoke-Stage $work @('preflight', '-Stage', 'S1')
Assert 'D8 an unanchored plan sha is REFUSED by P4' ($a.Code -eq 1 -and (Get-Line $a 'P4') -match 'FAIL') "(exit $($a.Code): $(Get-Line $a 'P4'))"
Assert 'D9 ...and the refusal carries upstream-remote''s own reason' ($a.Text -match "$u29 is not anchored") "(got: $($a.Text))"
& powershell -NoProfile -ExecutionPolicy Bypass -File $RemoteScript ensure -Repo $work -NoFetch | Out-Null

# P6 / P7 / P8: each sibling gate's no is the verdict's no.
$fi = Invoke-Stage $work @('preflight', '-Stage', 'S1') @{ FORK = 1 }
Assert 'D10 a red fork-identity check is REFUSED by P6' ($fi.Code -eq 1 -and (Get-Line $fi 'P6') -match 'FAIL') "(exit $($fi.Code): $(Get-Line $fi 'P6'))"
$gd = Invoke-Stage $work @('preflight', '-Stage', 'S1') @{ GUARD = 1 }
Assert 'D11 a harness owed a run is REFUSED by P7' ($gd.Code -eq 1 -and (Get-Line $gd 'P7') -match 'FAIL') "(exit $($gd.Code): $(Get-Line $gd 'P7'))"
Assert 'D12 ...and the GUARD DUE line is echoed, not the tail' ($gd.Text -match 'GUARD DUE stub-harness') "(got: $($gd.Text))"
Assert 'D13 ...and the floor is not run' (@($gd.Calls | Where-Object { $_ -match '^floor-lane' }).Count -eq 0) "(calls: $($gd.Calls -join ' / '))"
$fl = Invoke-Stage $work @('preflight', '-Stage', 'S1') @{ FLOOR = 1 }
Assert 'D14 a red floor is REFUSED by P8' ($fl.Code -eq 1 -and (Get-Line $fl 'P8') -match 'FAIL' -and $fl.Text -match 'PREFLIGHT REFUSED S1 - P8') "(exit $($fl.Code): $($fl.Text))"
$nf = Invoke-Stage $work @('preflight', '-Stage', 'S1', '-NoFloor', '-NoGuardDue', '-NoForkIdentity')
Assert 'D15 every hatch is named in the verdict' ($nf.Code -eq 0 -and $nf.Text -match 'hatches used: -NoForkIdentity -NoGuardDue -NoFloor') "(got: $($nf.Text))"
Assert 'D16 ...and no hatched gate was called' ($nf.Calls.Count -eq 0) "(calls: $($nf.Calls -join ' / '))"

# ---------------------------------------------------------------------------
Say ''
Say 'E. the stage sequence'
# ---------------------------------------------------------------------------

$s2 = Invoke-Stage $work @('preflight', '-Stage', 'S2')
Assert 'E1 S2 before S1 landed is REFUSED by P5' ($s2.Code -eq 1 -and (Get-Line $s2 'P5') -match 'FAIL.*S1 has not landed') "(exit $($s2.Code): $(Get-Line $s2 'P5'))"

Invoke-GitCommit $work @('merge', '-q', '--no-edit', $U1) | Out-Null
Invoke-GitIn $work @('push', '-q', 'origin', 'ours') | Out-Null
$again = Invoke-Stage $work @('preflight', '-Stage', 'S1')
Assert 'E2 S1 once taken is REFUSED by P5 (already in HEAD)' ($again.Code -eq 1 -and (Get-Line $again 'P5') -match 'FAIL.*already in HEAD') "(exit $($again.Code): $(Get-Line $again 'P5'))"
$s2b = Invoke-Stage $work @('preflight', '-Stage', 's2')
Assert 'E3 S2 after S1 is let through (stage name is case-insensitive)' ($s2b.Code -eq 0 -and $s2b.Text -match 'PREFLIGHT OK S2') "(exit $($s2b.Code): $($s2b.Text))"
$ls = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $StageScript list -Repo $work 2>&1 | ForEach-Object { "$_" })
Assert 'E4 `list` reads S1 taken, S2 next' ((@($ls | Where-Object { $_ -match '^S1 .*taken$' }).Count -eq 1) -and (@($ls | Where-Object { $_ -match '^S2 .*next$' }).Count -eq 1)) "(got: $($ls -join ' / '))"

# ---------------------------------------------------------------------------
Say ''
Say 'F. the plan itself'
# ---------------------------------------------------------------------------

$unk = Invoke-Stage $work @('preflight', '-Stage', 'S7')
Assert 'F1 an unknown stage is REFUSED by P1' ($unk.Code -eq 1 -and (Get-Line $unk 'P1') -match 'FAIL.*no stage ''S7''') "(exit $($unk.Code): $(Get-Line $unk 'P1'))"
$none = Invoke-Stage $work @('preflight')
Assert 'F2 preflight without -Stage is a usage error (exit 2)' ($none.Code -eq 2) "(exit $($none.Code): $($none.Text))"

# A re-cut plan whose stages no longer meet. Not committed: P1 is judged off
# the file on disk, and the dirty tree adds P2, which is fine - what is asserted
# is that P1 names the gap.
Write-Plan -S2From $f9
$gap = Invoke-Stage $work @('preflight', '-Stage', 'S2')
Assert 'F3 a non-contiguous stage table is REFUSED by P1' ($gap.Code -eq 1 -and (Get-Line $gap 'P1') -match 'FAIL.*not contiguous.*S2 starts at') "(exit $($gap.Code): $(Get-Line $gap 'P1'))"
$lg = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $StageScript list -Repo $work 2>&1 | ForEach-Object { "$_" })
Assert 'F4 ...and `list` prints the GAP' (@($lg | Where-Object { $_ -match '^GAP S2 starts at' }).Count -eq 1) "(got: $($lg -join ' / '))"
Invoke-GitIn $work @('checkout', '-q', '--', 'docs') | Out-Null

if ($NegativeControl) {
    Say ''
    Say 'NEGATIVE CONTROL: asserting a dirty tree is let through - a working gate MUST fail this'
    Set-Content -LiteralPath (Join-Path $work 'stray.txt') -Value 'left behind' -Encoding ASCII
    $nc = Invoke-Stage $work @('preflight', '-Stage', 'S2')
    Assert 'N1 a dirty tree passes preflight (inverted)' ($nc.Code -eq 0) "(exit $($nc.Code))"
}

} catch {
    Write-Host "  FAIL harness crashed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "    at $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())"
    $script:failures++
} finally {
    foreach ($n in @('FORK', 'GUARD', 'FLOOR', 'LOG')) { Remove-Item -Path "env:UPSTREAM_STAGE_STUB_$n" -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue }
}

# A clean green run stamps the covered files (T783). A red run, or the
# -NegativeControl run (red by construction), leaves the stamp alone.
Complete-TestBody  # T1039: before the stamp, which is a child process reading this run's state
if ($script:failures -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard upstream-stage -Repo $Repo 2>&1 | ForEach-Object { "  $_" }
}

Say ''
Write-TestVerdict -Pass $script:passes -Fail $script:failures -Label 'UPSTREAM-STAGE'
