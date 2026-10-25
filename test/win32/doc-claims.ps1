# T1342 meta-check: a claim the code made false never comes back into the tree.
#
# Why: T1158 corrected "the agent pipe has no env override" in BuildMode.ps1 and
# the identical sentence stood in four other files for twelve more days (T490).
# A correction that only lands where its author happened to look is a
# correction with a lifetime. The registry in `test\win32\lib\RetiredClaims.ps1`
# holds every claim retired so far - its pattern, the change that made it false,
# the commit that corrected it, and where the truth now lives - and this script
# fails the tree the moment any of them is written down again. The header of
# that library has the rule, the row format and what counts as history.
#
# Sections:
#
#   A  the scanner bites, in both directions (string fixtures)
#   B  every registry row is well formed and still catches the sentence it
#      retired, read out of git at a commit where that sentence was present -
#      the "red against the pre-T490 tree" half
#   C  the live tree carries no retired claim - the "green against today's" half
#
# Static scan, no app, no CLI - safe on the off-desktop harness.
#
#   powershell -NoProfile -File test\win32\doc-claims.ps1
#   powershell -NoProfile -File test\win32\doc-claims.ps1 -NegativeControl
#
# isolation: none - this script never runs a ghoztty verb; it only reads files.
param(
    [string]$Repo,
    [switch]$NegativeControl
)

$ErrorActionPreference = 'Stop'
if (-not $Repo) { $Repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }

# T1511: the shared scorer; the dot-source also ARMS the run.
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\RetiredClaims.ps1')

$script:failures = 0
$script:passes = 0
function Assert($name, $cond, $detail = '') {
    if ($cond) { "  PASS $name"; $script:passes++ }
    else { "  FAIL $name $detail"; $script:failures++ }
}

function Read-Text([string]$Path) {
    # ReadAllText decodes the UTF-8 the repo is written in; PS 5.1's
    # Get-Content would read it as the ANSI codepage.
    try { return [System.IO.File]::ReadAllText($Path) } catch { return '' }
}

# git show <ref>:<path> as one string, UTF-8 decoded.
function Get-GitBlob([string]$Ref, [string]$Path) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'git'
    $psi.Arguments = "-C `"$Repo`" show `"${Ref}:$Path`""
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $p = [System.Diagnostics.Process]::Start($psi)
    $errTask = $p.StandardError.ReadToEndAsync()
    $out = $p.StandardOutput.ReadToEnd()
    $p.WaitForExit()
    $null = $errTask.Result
    if ($p.ExitCode -ne 0) { return $null }
    return $out
}

# ---------------------------------------------------------------------------
"== A: the scanner bites, in both directions"
# ---------------------------------------------------------------------------
$hits = @(Get-RetiredClaimHits 'A private suffix is not enough: the agent pipe has no env override.')
Assert 'A1 the plain claim is a finding' ($hits.Count -eq 1) "(got $($hits.Count))"

$hits = @(Get-RetiredClaimHits "# the local agent's pipe is build-mode`n# derived with no env override - so" )
Assert 'A2 a claim wrapped across comment lines is a finding' ($hits.Count -eq 1) "(got $($hits.Count))"

$hits = @(Get-RetiredClaimHits "the agent pipe is build-mode`nderived and has no env override.")
Assert 'A3 the BuildMode.ps1 wording is a finding' ($hits.Count -eq 1) "(got $($hits.Count))"

$hits = @(Get-RetiredClaimHits "the local agent$([char]0x2019)s pipe is build-mode derived with no env override")
Assert 'A4 a curly apostrophe does not hide it' ($hits.Count -eq 1) "(got $($hits.Count))"

$hits = @(Get-RetiredClaimHits 'the sentence used to say the agent pipe had NO env override, which was false')
Assert 'A5 a past-tense account of the old claim is not a finding' ($hits.Count -eq 0) "(got $($hits.Count))"

$hits = @(Get-RetiredClaimHits 'the old doc said "the agent pipe has no env override" and that was wrong')
Assert 'A6 a double-quoted mention is not a finding' ($hits.Count -eq 0) "(got $($hits.Count))"

$hits = @(Get-RetiredClaimHits "> the agent pipe has no env override`nwas the quote")
Assert 'A7 a markdown blockquote is not a finding' ($hits.Count -eq 0) "(got $($hits.Count))"

$long = '"' + ('x' * 900) + ' the agent pipe has no env override ' + '"'
$hits = @(Get-RetiredClaimHits $long)
Assert 'A8 an over-long quoted span is NOT treated as a quotation' ($hits.Count -eq 1) "(got $($hits.Count))"

$taskText = @"
---
id: T999
status: "todo"
---

The summary is live prose.

## Progress log

- 2026-08-22 07:47: found it; the agent pipe has no env override.
"@
$hits = @(Get-RetiredClaimHits $taskText $true)
Assert 'A9 an open task file exempts its Progress log' ($hits.Count -eq 0) "(got $($hits.Count))"
$hits = @(Get-RetiredClaimHits ($taskText -replace 'live prose', 'live prose: the agent pipe has no env override') $true)
Assert 'A10 ...but its Summary is scanned' ($hits.Count -eq 1) "(got $($hits.Count))"

Assert 'A11 a done task reads as closed' (Test-RetiredClaimTaskClosed 'status: "done"')
Assert 'A12 a skipped task reads as closed' (Test-RetiredClaimTaskClosed 'status: "skipped(stale)"')
Assert 'A13 a blocked task reads as open' (-not (Test-RetiredClaimTaskClosed 'status: "blocked(user)"'))
Assert 'A14 the session log is history' (-not (Test-RetiredClaimScannable 'docs/design/windows-parity-log.md' @()))
Assert 'A15 a digest is history' (-not (Test-RetiredClaimScannable 'docs/design/windows-parity-digests/2026-10-24.md' @()))
Assert 'A16 a live doc is scanned' (Test-RetiredClaimScannable 'docs/claude/build.md' @())
Assert 'A17 a harness lib is scanned' (Test-RetiredClaimScannable 'test/win32/lib/Isolation.ps1' @())

# ---------------------------------------------------------------------------
"== B: every row is well formed and still catches the sentence it retired"
# ---------------------------------------------------------------------------
$claims = @(Get-RetiredClaims)
Assert 'B1 the registry has rows' ($claims.Count -ge 1) "(got $($claims.Count))"
$ids = @{}
foreach ($c in $claims) {
    $missing = @('Id', 'Pattern', 'FalseSince', 'CorrectedBy', 'Truth') |
        Where-Object { -not $c.$_ }
    Assert "B2 $($c.Id): every field is filled" (@($missing).Count -eq 0) "(missing: $($missing -join ', '))"
    Assert "B3 $($c.Id): the id is unique" (-not $ids.ContainsKey($c.Id))
    $ids[$c.Id] = $true
    $proofs = @($c.Proofs)
    Assert "B4 $($c.Id): carries at least one proof" ($proofs.Count -ge 1) "(got $($proofs.Count))"
    foreach ($p in $proofs) {
        $blob = Get-GitBlob $p.Ref $p.Path
        if ($null -eq $blob) {
            Assert "B5 $($c.Id): $($p.Path)@$($p.Ref) is readable from git" $false '(git show failed)'
            continue
        }
        $isTask = $p.Path -match $script:RetiredClaimTaskPattern
        $hit = @(Get-RetiredClaimHits $blob $isTask | Where-Object { $_ -like "$($c.Id) ::*" })
        Assert "B5 $($c.Id): caught in $($p.Path)@$($p.Ref)" ($hit.Count -ge 1) '(the pattern no longer matches the sentence it retired)'
    }
}

# ---------------------------------------------------------------------------
"== C: the live tree carries no retired claim"
# ---------------------------------------------------------------------------
Push-Location $Repo
try { $tracked = @(& git ls-files) } finally { Pop-Location }
Assert 'C1 git listed the tracked tree' ($tracked.Count -gt 100) "(got $($tracked.Count))"

# The registry and this harness hold the patterns and the fixtures by design.
$Self = @('test/win32/lib/RetiredClaims.ps1', 'test/win32/doc-claims.ps1')

$scanned = 0
$findings = @()
foreach ($rel in $tracked) {
    if (-not (Test-RetiredClaimScannable $rel $Self)) { continue }
    $full = Join-Path $Repo ($rel -replace '/', '\')
    if (-not (Test-Path -LiteralPath $full)) { continue }
    $text = Read-Text $full
    if ($text.Length -eq 0) { continue }
    $isTask = $rel -match $script:RetiredClaimTaskPattern
    if ($isTask -and (Test-RetiredClaimTaskClosed $text)) { continue }
    $scanned++
    foreach ($h in (Get-RetiredClaimHits $text $isTask)) { $findings += "$rel :: $h" }
}
Assert 'C2 the scan reached the live tree' ($scanned -gt 100) "(scanned $scanned)"
foreach ($f in $findings) {
    "  RETIRED CLAIM $f"
    $id = ($f -split ' :: ')[1]
    $row = $claims | Where-Object { $_.Id -eq $id } | Select-Object -First 1
    if ($row) { "    false since $($row.FalseSince); the truth: $($row.Truth)" }
}
Assert 'C3 no live file repeats a retired claim' ($findings.Count -eq 0) "($($findings.Count) finding(s))"

# ---------------------------------------------------------------------------
# Negative control: plant the claim in a real tracked doc, scan it, and assert -
# INVERTED - that nothing was reported. A working scanner fails that, so a
# healthy repo scores exactly 1 FAILURE here. The probe is restored either way.
# ---------------------------------------------------------------------------
if ($NegativeControl) {
    ""
    "NEGATIVE CONTROL: asserting a planted retired claim is NOT reported - a working scan MUST fail this"
    $probe = Join-Path $Repo 'docs\claude\build.md'
    $original = [System.IO.File]::ReadAllText($probe)
    $hits = @()
    try {
        [System.IO.File]::WriteAllText($probe, $original + "`nA private suffix will do, since the agent pipe has no env override.`n")
        $hits = @(Get-RetiredClaimHits (Read-Text $probe) $false)
    } finally {
        [System.IO.File]::WriteAllText($probe, $original)
    }
    Assert 'N1 a planted retired claim goes unreported (inverted)' ($hits.Count -eq 0) `
        "(reported $($hits.Count), which is the healthy answer)"
    Assert 'N2 the probe file is restored byte for byte' `
        ([System.IO.File]::ReadAllText($probe) -eq $original)
}

# A clean green run stamps the covered files (T783).
Complete-TestBody  # T1039: before the stamp, which is a child process reading this run's state
if ($script:failures -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard doc-claims -Repo $Repo 2>&1 | ForEach-Object { "  $_" }
}

""
Write-TestVerdict -Pass $script:passes -Fail $script:failures
