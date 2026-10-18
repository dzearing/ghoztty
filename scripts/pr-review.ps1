<#
.SYNOPSIS
  The adversarial review gate every pull request passes before it merges:
  mechanical refutation, a brief for an independent reviewer, a verdict keyed on
  the exact commit it judged, and the gate that reads it.

.DESCRIPTION
  T1060. User directive, 2026-08-21: "an adversarial review would be done to
  enforce accuracy, claude.md rules followed, code is quality, design is dry and
  well tested."

  The reviewer's job is to REFUTE, not to approve. A review that starts from
  "does this look fine" finds nothing; one that starts from "this claim is false,
  prove otherwise" finds the defects this project keeps paying for - a
  validation box ticked with no evidence, a test that cannot go red, a second
  copy of a helper that already exists, a feature that landed on one platform.
  So the gate is built in two halves that a self-satisfied reviewer cannot skip:

    1. `check` refutes mechanically, over the PR's diff, and its findings are
       not advisory: `record -Verdict pass` REFUSES while any finding is
       unanswered. A finding is answered by fixing it (it stops being reported)
       or by a `-Waive '<key>=<why>'` that is written into the verdict, so a
       dismissal is a recorded argument rather than a silence.
    2. `prompt` prints the brief for the judgement half - the checklist in
       docs/design/windows-parity-ship-workflow.md, the mechanical findings and
       the range - for a reviewer with NO stake in the change (a fresh subagent,
       never the turn that wrote it). Its default answer is "not proven".

  The verdict is keyed on the full head sha. A push after the review makes the
  review stale, and `gate` says so instead of passing an unreviewed commit
  because an older one was fine.

  THE COMMANDS

    check   Refute over <Base>...<Head>. Exit 0 = no findings, 1 = findings.
    prompt  The reviewer brief (stdout). Hand it to an independent reviewer.
    record  Write the verdict: pass | fail | override. Ledger file under the
            repository's git common dir (shared by every worktree), plus a PR
            comment when -Pr is given, so the verdict is visible on the PR.
            `override` needs -Summary and is how a merge over a failing review
            is made explicit and recorded (ship-feature.ps1 merge -Override).
    gate    Exit 0 when the head carries a pass or override verdict, else 1
            with the reason (none, stale, failed).

  THE RULES `check` APPLIES

    unproven-tick     A validation criterion newly ticked in a task file with no
                      evidence in its text (how it was verified: a script, a
                      lane, a commit, "Verified").
    one-platform      A feature (a changed task tagged `feature`) that touches
                      one frontend only - src/apprt/win32/ or macos/ - with no
                      task for the other seat added in the same change and no
                      `Parity-Owed: none (<why>)` trailer on a commit. CLAUDE.md's
                      platform-symmetry rule: land both, or file the other half.
    duplicate-helper  A function added under a name a shared library already
                      defines: a PowerShell `function` that exists in
                      scripts\lib or test\win32\lib, or a zig `fn` that exists
                      as `pub fn` in another file under src/ (common lifecycle
                      names excluded).
    toothless-test    A zig `test` block added with nothing in it that can fail,
                      or a new test\win32 harness with no assertion that is not
                      a literal $true.
    untested          Code changed (src/, scripts/, macos/) and no test changed
                      or added anywhere in the range.

  EXIT CODES
    0  check: clean / gate: open / record, prompt: done
    1  check: findings / gate: shut / record: refused
    2  could not run (bad repo, bad ref, bad arguments)

.EXAMPLE
  powershell -NoProfile -File scripts\pr-review.ps1 check -Base origin/main -Head HEAD
  powershell -NoProfile -File scripts\pr-review.ps1 prompt -Base origin/main -Head HEAD
  powershell -NoProfile -File scripts\pr-review.ps1 record -Head HEAD -Verdict pass -Summary "..." -Pr 12
  powershell -NoProfile -File scripts\pr-review.ps1 gate -Head HEAD
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('check', 'prompt', 'record', 'gate')]
    [string]$Command,

    [string]$Repo,
    [string]$Base = 'origin/main',
    [string]$Head = 'HEAD',

    # record only.
    [ValidateSet('pass', 'fail', 'override')]
    [string]$Verdict,
    [string]$Summary,
    [string]$Reviewer = 'independent reviewer',
    # 'key=why' - one per finding being dismissed. The key is what `check`
    # prints in brackets.
    [string[]]$Waive = @(),
    # The PR to comment the verdict on. Omitted: ledger only.
    [int]$Pr = 0,
    [string]$ForkRepo = 'dzearing/ghoztty',

    [switch]$Json
)

$ErrorActionPreference = 'Continue'
if (-not $Repo) { $Repo = Split-Path -Parent $PSScriptRoot }

function Invoke-Git {
    param([string[]]$GitArgs)
    $out = @(& git -C $Repo @GitArgs 2>$null)
    return [pscustomobject]@{ Ok = ($LASTEXITCODE -eq 0); Lines = $out; Text = (($out | Out-String).Trim()) }
}

# THE ONLY gh call in this script, and it names the fork unconditionally: this
# repo has `upstream` (ghostty-org/ghostty) as a remote and gh resolves to it by
# default (the landmine test\win32\ship-workflow.ps1 section C scans for).
function Invoke-GhPr {
    param([string]$Verb, [string[]]$Rest = @())
    $out = & gh pr $Verb --repo $ForkRepo @Rest 2>&1
    return [pscustomobject]@{ Ok = ($LASTEXITCODE -eq 0); Text = ($out | Out-String).Trim() }
}

function Resolve-Sha {
    param([string]$Ref)
    $r = Invoke-Git @('rev-parse', '--verify', '--quiet', "$Ref^{commit}")
    if (-not $r.Ok -or -not $r.Text) { return $null }
    return $r.Text
}

function Get-LedgerDir {
    # The git COMMON dir, so a review recorded from a feature worktree is the
    # same record the main tree's gate reads.
    $r = Invoke-Git @('rev-parse', '--git-common-dir')
    $d = $r.Text
    if (-not [System.IO.Path]::IsPathRooted($d)) { $d = Join-Path $Repo $d }
    return (Join-Path $d 'ghoztty-review')
}

function Get-FileAt {
    param([string]$Sha, [string]$Path)
    $r = Invoke-Git @('show', "${Sha}:$Path")
    if (-not $r.Ok) { return @() }
    return , @($r.Lines | ForEach-Object { "$_" })
}

# Added lines per file, with their line numbers in the head version. One diff
# call for the whole range; -U0 so every '+' line is exactly an added line.
function Get-AddedLines {
    param([string]$BaseSha, [string]$HeadSha)
    $map = @{}
    $r = Invoke-Git @('diff', '--no-color', '--no-ext-diff', '-U0', "$BaseSha...$HeadSha")
    $file = $null
    $ln = 0
    foreach ($raw in $r.Lines) {
        $l = "$raw"
        if ($l -match '^\+\+\+ (?:b/)?(.+)$') {
            $file = $Matches[1]
            if ($file -eq '/dev/null') { $file = $null }
            elseif (-not $map.ContainsKey($file)) { $map[$file] = New-Object System.Collections.ArrayList }
            continue
        }
        if ($l -match '^@@ -\S+ \+(\d+)') { $ln = [int]$Matches[1]; continue }
        if (-not $file) { continue }
        if ($l.StartsWith('+')) {
            [void]$map[$file].Add([pscustomobject]@{ Line = $ln; Text = $l.Substring(1) })
            $ln++
        }
    }
    return $map
}

function Get-ChangedFiles {
    param([string]$BaseSha, [string]$HeadSha)
    $r = Invoke-Git @('diff', '--name-status', '--no-renames', "$BaseSha...$HeadSha")
    $rows = @()
    foreach ($l in $r.Lines) {
        $parts = "$l" -split "`t"
        if ($parts.Count -ge 2) { $rows += [pscustomobject]@{ Status = $parts[0].Substring(0, 1); Path = $parts[1] } }
    }
    return , $rows
}

# Names a zig file may legitimately redefine: lifecycle and protocol methods
# that every struct in the tree carries. A `fn deinit` is not a second copy of
# anybody's helper.
$ZigCommonNames = @(
    'init', 'deinit', 'create', 'destroy', 'format', 'run', 'main', 'parse', 'get', 'set', 'put',
    'len', 'eql', 'hash', 'next', 'reset', 'clear', 'update', 'draw', 'render', 'start', 'stop',
    'open', 'close', 'read', 'write', 'flush', 'append', 'remove', 'contains', 'count', 'clone',
    'free', 'alloc', 'apply', 'handle', 'callback', 'toString', 'fromString', 'jsonStringify',
    'jsonParse', 'deinitState', 'tick', 'wait', 'notify', 'send', 'recv', 'connect', 'accept',
    'name', 'size', 'items', 'slice', 'value', 'kind', 'tag', 'parseCLI', 'help', 'setup', 'teardown'
)

# What counts as saying HOW a criterion was verified. Deliberately wide: the
# house style puts the evidence inline in many shapes (a script, an assert id, a
# PASS count, a negative control, a quoted artifact), and the rule exists for
# the tick that names none of them - "- [x] it works".
$EvidencePattern = '(?i)\bverified\b|\.ps1\b|\.zig\b|\bzig build\b|\blanes?\b|\bcommit [0-9a-f]{7,}|\b[0-9a-f]{9,40}\b|test[\\/]' +
    '|\bpass(es|ed)?\b|\bfail(s|ed)?\b|\bgreen\b|\bred\b|negative control|\bsections? [A-Z0-9]+\b|\b[A-Z]{1,2}\d{1,3}[a-z]?\b' +
    '|\bharness\b|\boracle\b|\barm [A-Z]\b' +
    '|\b(re-?)?ran\b|\bre-?run\b|\bmeasured\b|\bobserved\b|\bstamped\b|\bexit \d|`[^`]+`|\bread from source\b'

function Invoke-Check {
    param([string]$BaseSha, [string]$HeadSha)
    $findings = New-Object System.Collections.ArrayList
    $files = Get-ChangedFiles $BaseSha $HeadSha
    $added = Get-AddedLines $BaseSha $HeadSha

    function Add-Finding($rule, $path, $line, $name, $detail) {
        $key = if ($name) { "${rule}:${path}:$name" } else { "${rule}:$path" }
        [void]$findings.Add([pscustomobject]@{ Rule = $rule; Key = $key; Path = $path; Line = $line; Detail = $detail })
    }

    $taskFiles = @($files | Where-Object { $_.Path -match '^docs/design/windows-parity-tasks/T\d+\.md$' -and $_.Status -ne 'D' })

    # ---- unproven-tick ----------------------------------------------------
    foreach ($tf in $taskFiles) {
        $addedHere = @()
        if ($added.ContainsKey($tf.Path)) { $addedHere = @($added[$tf.Path] | ForEach-Object { $_.Line }) }
        $lines = Get-FileAt $HeadSha $tf.Path
        $inCrit = $false
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $l = $lines[$i]
            if ($l -match '^##\s') { $inCrit = ($l -match '^##\s+Validation criteria'); continue }
            if (-not $inCrit) { continue }
            if ($l -notmatch '^\s*-\s\[[xX]\]') { continue }
            if ($addedHere -notcontains ($i + 1)) { continue }
            # The item is the tick line plus its indented continuation.
            $text = $l
            for ($j = $i + 1; $j -lt $lines.Count; $j++) {
                $c = $lines[$j]
                if ($c -match '^\s*-\s\[' -or $c -match '^#' -or $c.Trim() -eq '') { break }
                $text += ' ' + $c.Trim()
            }
            if ($text -notmatch $EvidencePattern) {
                $short = ($l.Trim() -replace '^-\s\[[xX]\]\s*', '')
                if ($short.Length -gt 70) { $short = $short.Substring(0, 70) + '...' }
                Add-Finding 'unproven-tick' $tf.Path ($i + 1) "L$($i + 1)" "ticked with no evidence of how it was verified: '$short'"
            }
        }
    }

    # ---- one-platform -----------------------------------------------------
    $winTouched = @($files | Where-Object { $_.Path -like 'src/apprt/win32/*' }).Count -gt 0
    $macTouched = @($files | Where-Object { $_.Path -like 'macos/*' }).Count -gt 0
    if ($winTouched -xor $macTouched) {
        $isFeature = $false
        $otherSeat = if ($winTouched) { 'mac' } else { 'win' }
        $otherFiled = $false
        # A port of something the other platform already has names it (the
        # whole tracker is written that way: "as an enrolled Mac now is"). A
        # feature task that never mentions the other side is the one that never
        # considered it.
        $otherWord = if ($winTouched) { '(?i)\bmac(os)?\b' } else { '(?i)\bwindows\b|\bwin32\b' }
        $mentionsOther = $false
        foreach ($tf in $taskFiles) {
            $body = (Get-FileAt $HeadSha $tf.Path) -join "`n"
            if ($body -match '(?m)^tags:.*"feature"') {
                $isFeature = $true
                $sansSeat = $body -replace '(?m)^seat:.*$', ''
                if ($sansSeat -match $otherWord) { $mentionsOther = $true }
            }
            if ($tf.Status -eq 'A' -and $body -match "(?m)^seat:\s*`"?$otherSeat`"?\s*$") { $otherFiled = $true }
        }
        $msgs = (Invoke-Git @('log', '--format=%B', "$BaseSha..$HeadSha")).Text
        $owedNone = $msgs -match '(?im)^Parity-Owed:\s*none\b'
        if ($isFeature -and -not $mentionsOther -and -not $otherFiled -and -not $owedNone) {
            $side = if ($winTouched) { 'src/apprt/win32/ (Windows)' } else { 'macos/ (Mac)' }
            Add-Finding 'one-platform' $(if ($winTouched) { 'src/apprt/win32' } else { 'macos' }) 0 $null `
                "a feature touches only $side and no seat:$otherSeat task was filed for the other half (or add a 'Parity-Owed: none (<why>)' trailer)"
        }
    }

    # ---- duplicate-helper -------------------------------------------------
    foreach ($path in @($added.Keys)) {
        foreach ($a in $added[$path]) {
            if ($path -like '*.ps1' -and $a.Text -match '^\s*function\s+([A-Za-z][\w-]*)') {
                $nm = $Matches[1]
                $hits = Invoke-Git @('grep', '-l', '-i', '-E', "^[[:space:]]*function[[:space:]]+$([regex]::Escape($nm))([[:space:]]|[{(]|`$)", $HeadSha, '--', 'scripts/lib/*.ps1', 'test/win32/lib/*.ps1')
                $others = @($hits.Lines | ForEach-Object { ("$_" -replace '^[^:]+:', '') } | Where-Object { $_ -and $_ -ne $path })
                if ($others.Count -gt 0) {
                    Add-Finding 'duplicate-helper' $path $a.Line $nm "function $nm is already defined in shared library $($others[0]); use it rather than a second copy"
                }
            }
            elseif ($path -like '*.zig' -and $a.Text -match '^\s*(?:pub\s+)?fn\s+([A-Za-z_]\w*)\s*\(') {
                $nm = $Matches[1]
                if ($ZigCommonNames -contains $nm) { continue }
                # Zig functions are namespaced by their file, so a one-word name
                # (`decide`, `finish`) in two files is two different verbs, not a
                # copy. A multi-word name (`parseKeyValue`, `read_env_flag`) is
                # specific enough that a second definition is worth an answer.
                if ($nm -cnotmatch '[a-z][A-Z]|_[a-z]') { continue }
                # A method (first parameter `self`) belongs to its type; a
                # wrapper delegating to the same-named method on another type is
                # the design, not a copy. The rule is about free helpers.
                if ($a.Text -match '\(\s*self\s*:') { continue }
                $hits = Invoke-Git @('grep', '-l', '-E', "^[[:space:]]*pub[[:space:]]+fn[[:space:]]+$nm[[:space:]]*[(]", $HeadSha, '--', 'src/*.zig')
                $others = @($hits.Lines | ForEach-Object { ("$_" -replace '^[^:]+:', '') } | Where-Object { $_ -and $_ -ne $path })
                if ($others.Count -gt 0) {
                    Add-Finding 'duplicate-helper' $path $a.Line $nm "fn $nm is already a pub fn in $($others[0]); reuse it or say why this one differs"
                }
            }
        }
    }

    # ---- toothless-test ---------------------------------------------------
    foreach ($path in @($added.Keys)) {
        if ($path -like '*.zig') {
            $addedNums = @($added[$path] | ForEach-Object { $_.Line })
            $lines = $null
            foreach ($a in $added[$path]) {
                if ($a.Text -notmatch '^\s*test\s+("[^"]*"|[A-Za-z_]\w*)?\s*\{') { continue }
                if ($null -eq $lines) { $lines = Get-FileAt $HeadSha $path }
                $depth = 0; $bodyText = ''
                for ($k = $a.Line - 1; $k -lt $lines.Count; $k++) {
                    $t = $lines[$k]
                    $bodyText += "`n" + $t
                    $depth += ([regex]::Matches($t, '\{')).Count - ([regex]::Matches($t, '\}')).Count
                    if ($depth -le 0 -and $k -ge $a.Line - 1) { break }
                }
                if ($bodyText -notmatch 'expect|testing\.|return error|@panic|unreachable|try\s+\w+\(') {
                    $nm = if ($a.Text -match '"([^"]*)"') { $Matches[1] } else { "L$($a.Line)" }
                    Add-Finding 'toothless-test' $path $a.Line $nm "test '$nm' contains nothing that can fail"
                }
            }
        }
    }
    foreach ($f in @($files | Where-Object { $_.Status -eq 'A' -and $_.Path -match '^test/win32/[^/]+\.ps1$' })) {
        $lines = Get-FileAt $HeadSha $f.Path
        $asserts = @($lines | Where-Object { $_ -match '^\s*Assert\s' })
        $real = @($asserts | Where-Object { $_ -notmatch '^\s*Assert\s+(''[^'']*''|"[^"]*")\s+\$true\b' })
        $writesFail = @($lines | Where-Object { $_ -match '\bFAIL\b' -and $_ -notmatch '^\s*#' }).Count -gt 0
        if ($real.Count -eq 0 -and -not ($asserts.Count -eq 0 -and $writesFail)) {
            Add-Finding 'toothless-test' $f.Path 0 $null "new harness has $($asserts.Count) assertion(s) and none of them can be false"
        }
    }

    # ---- untested ---------------------------------------------------------
    $code = @($files | Where-Object {
            $_.Status -ne 'D' -and (
                ($_.Path -like 'src/*' -and $_.Path -like '*.zig') -or
                ($_.Path -match '^scripts/[^/]+\.ps1$') -or
                ($_.Path -like 'macos/*' -and $_.Path -like '*.swift' -and $_.Path -notlike 'macos/Tests/*' -and $_.Path -notlike 'macos/*Tests/*'))
        })
    if ($code.Count -gt 0) {
        $testTouched = @($files | Where-Object { $_.Path -like 'test/*' -or $_.Path -like 'macos/*Tests/*' }).Count -gt 0
        if (-not $testTouched) {
            foreach ($path in @($added.Keys)) {
                if ($path -like '*.zig' -and @($added[$path] | Where-Object { $_.Text -match '^\s*test\s+("|[A-Za-z_]|\{)' }).Count -gt 0) { $testTouched = $true; break }
            }
        }
        if (-not $testTouched) {
            $names = (@($code | Select-Object -First 3 | ForEach-Object { $_.Path }) -join ', ')
            Add-Finding 'untested' $code[0].Path 0 $null "$($code.Count) code file(s) changed ($names) and no test was added or changed"
        }
    }

    return , @($findings)
}

function Get-Range {
    $b = Resolve-Sha $Base
    $h = Resolve-Sha $Head
    if (-not $b) { Write-Host "ERROR: no such ref: $Base"; exit 2 }
    if (-not $h) { Write-Host "ERROR: no such ref: $Head"; exit 2 }
    return @($b, $h)
}

function Get-Checklist {
    # The checklist lives in the workflow doc, between markers, so the gate and
    # the process it guards cannot drift apart: this prints what the doc says.
    $doc = Join-Path $Repo 'docs\design\windows-parity-ship-workflow.md'
    if (-not (Test-Path $doc)) { return $null }
    $t = Get-Content -LiteralPath $doc -Raw -Encoding UTF8
    $m = [regex]::Match($t, '(?s)<!-- review-checklist:begin -->(.*?)<!-- review-checklist:end -->')
    if (-not $m.Success) { return $null }
    return $m.Groups[1].Value.Trim()
}

switch ($Command) {

    'check' {
        $range = Get-Range
        $found = Invoke-Check $range[0] $range[1]
        if ($Json) {
            ConvertTo-Json -Depth 4 ([pscustomobject]@{ base = $range[0]; head = $range[1]; findings = @($found) })
        }
        elseif ($found.Count -eq 0) {
            Write-Host ("REVIEW CHECK CLEAN {0}..{1}: no mechanical findings - the judgement half still applies" -f $range[0].Substring(0, 9), $range[1].Substring(0, 9))
        }
        else {
            Write-Host ("REVIEW CHECK {0} finding(s) {1}..{2}" -f $found.Count, $range[0].Substring(0, 9), $range[1].Substring(0, 9))
            foreach ($f in $found) {
                $at = if ($f.Line) { "$($f.Path):$($f.Line)" } else { $f.Path }
                Write-Host "  [$($f.Key)] $($f.Rule) at $at - $($f.Detail)"
            }
        }
        if ($found.Count -gt 0) { exit 1 } else { exit 0 }
    }

    'prompt' {
        $range = Get-Range
        $found = Invoke-Check $range[0] $range[1]
        $checklist = Get-Checklist
        if (-not $checklist) {
            Write-Host 'ERROR: the review checklist markers are missing from docs\design\windows-parity-ship-workflow.md'
            exit 2
        }
        $stat = (Invoke-Git @('diff', '--stat', "$($range[0])...$($range[1])")).Text
        $log = (Invoke-Git @('log', '--format=%h %s', "$($range[0])..$($range[1])")).Text
        Write-Output @"
You are the ADVERSARIAL REVIEWER for a pull request on the Ghoztty repository
($Repo). You did not write this change and you have no stake in it merging.
Your job is to REFUTE it. Treat every claim in the commit messages, the task
files and the PR description as false until you have re-run or read the
evidence yourself. When you cannot establish a claim, the answer is NOT PROVEN,
which is a fail. Do not suggest style nits; report defects a user or the next
turn would pay for.

Range: $($range[0])...$($range[1])
Read the change with: git -C "$Repo" diff $($range[0])...$($range[1])

Commits:
$log

Files:
$stat

THE CHECKLIST (from docs/design/windows-parity-ship-workflow.md):

$checklist

MECHANICAL FINDINGS from scripts\pr-review.ps1 check ($($found.Count)):
$(if ($found.Count -eq 0) { '  (none - the judgement half above still applies in full)' } else { ($found | ForEach-Object { "  [$($_.Key)] $($_.Detail)" }) -join "`n" })

For each mechanical finding, say whether it is REAL (must be fixed) or a
FALSE POSITIVE (and why, in one sentence - that sentence becomes the recorded
waiver). Then work the checklist and list anything else you can refute, each
with file:line and the evidence.

End with exactly one line:
VERDICT: PASS   - every claim held up and nothing was refuted
VERDICT: FAIL   - followed by the numbered defects that must be fixed
"@
        exit 0
    }

    'record' {
        if (-not $Verdict) { Write-Host 'ERROR: -Verdict pass|fail|override is required'; exit 2 }
        if (-not $Summary) { Write-Host 'ERROR: -Summary is required (what the reviewer concluded, or why the override)'; exit 2 }
        $range = Get-Range
        $found = Invoke-Check $range[0] $range[1]

        $waivers = @{}
        foreach ($w in $Waive) {
            $ix = $w.IndexOf('=')
            if ($ix -lt 1 -or $ix -ge $w.Length - 1) { Write-Host "ERROR: a waiver is 'key=why', got: $w"; exit 2 }
            $waivers[$w.Substring(0, $ix)] = $w.Substring($ix + 1)
        }
        $unanswered = @($found | Where-Object { -not $waivers.ContainsKey($_.Key) })
        if ($Verdict -eq 'pass' -and $unanswered.Count -gt 0) {
            Write-Host ("REFUSED: a pass cannot be recorded over {0} unanswered finding(s). Fix them, or waive each with -Waive '<key>=<why>':" -f $unanswered.Count)
            foreach ($f in $unanswered) { Write-Host "  [$($f.Key)] $($f.Detail)" }
            exit 1
        }
        $unknown = @($waivers.Keys | Where-Object { $k = $_; @($found | Where-Object { $_.Key -eq $k }).Count -eq 0 })
        if ($unknown.Count -gt 0) {
            Write-Host "REFUSED: waiver for a finding that is not reported: $($unknown -join ', ')"
            exit 1
        }

        $rec = [ordered]@{
            head       = $range[1]
            base       = $range[0]
            verdict    = $Verdict
            summary    = $Summary
            reviewer   = $Reviewer
            recordedAt = (Get-Date).ToString('o')
            findings   = @($found | ForEach-Object { [ordered]@{ key = $_.Key; detail = $_.Detail; waiver = $waivers[$_.Key] } })
            pr         = $Pr
        }
        $dir = Get-LedgerDir
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $file = Join-Path $dir "$($range[1]).json"
        [System.IO.File]::WriteAllText($file, (ConvertTo-Json -Depth 5 $rec), (New-Object System.Text.UTF8Encoding($false)))
        Write-Host ("RECORDED {0} for {1} ({2} finding(s), {3} waived) -> {4}" -f $Verdict.ToUpperInvariant(), $range[1].Substring(0, 9), $found.Count, $waivers.Count, $file)

        if ($Pr -gt 0) {
            $lines = @("<!-- ghoztty-review head=$($range[1]) verdict=$Verdict -->",
                "**Adversarial review: $($Verdict.ToUpperInvariant())** for ``$($range[1].Substring(0, 9))`` ($Reviewer)", '', $Summary)
            if ($found.Count -gt 0) {
                $lines += ''
                $lines += 'Mechanical findings:'
                foreach ($f in $found) {
                    $w = $waivers[$f.Key]
                    $lines += if ($w) { "- ``$($f.Key)`` waived: $w" } else { "- ``$($f.Key)`` $($f.Detail)" }
                }
            }
            $c = Invoke-GhPr 'comment' @("$Pr", '--body', ($lines -join "`n"))
            if ($c.Ok) { Write-Host "  posted to PR #$Pr" }
            else { Write-Host "  WARNING: the verdict is recorded but could not be posted to PR #${Pr}: $($c.Text)" }
        }
        exit 0
    }

    'gate' {
        $h = Resolve-Sha $Head
        if (-not $h) { Write-Host "ERROR: no such ref: $Head"; exit 2 }
        $dir = Get-LedgerDir
        $file = Join-Path $dir "$h.json"
        if (Test-Path $file) {
            $rec = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
            if ($rec.verdict -eq 'pass') { Write-Host "REVIEW PASS $($h.Substring(0, 9)) by $($rec.reviewer): $($rec.summary)"; exit 0 }
            if ($rec.verdict -eq 'override') { Write-Host "REVIEW OVERRIDDEN $($h.Substring(0, 9)): $($rec.summary)"; exit 0 }
            Write-Host "REVIEW FAILED $($h.Substring(0, 9)): $($rec.summary)"
            exit 1
        }
        # Stale: a review exists for an ancestor. Name it, so "I reviewed this"
        # about an older push cannot pass for a review of this one.
        $older = @()
        if (Test-Path $dir) {
            foreach ($f in (Get-ChildItem -LiteralPath $dir -Filter '*.json')) {
                $s = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
                & git -C $Repo merge-base --is-ancestor $s $h 2>$null
                if ($LASTEXITCODE -eq 0) {
                    $n = (Invoke-Git @('rev-list', '--count', "$s..$h")).Text
                    $older += [pscustomobject]@{ Sha = $s; Since = [int]$n }
                }
            }
        }
        if ($older.Count -gt 0) {
            $last = @($older | Sort-Object Since)[0]
            Write-Host ("REVIEW STALE {0}: the last review was of {1}, {2} commit(s) ago. Review the head again." -f $h.Substring(0, 9), $last.Sha.Substring(0, 9), $last.Since)
            exit 1
        }
        Write-Host "REVIEW MISSING $($h.Substring(0, 9)): no adversarial review has been recorded. Run: scripts\pr-review.ps1 prompt, hand it to an independent reviewer, then record."
        exit 1
    }
}
