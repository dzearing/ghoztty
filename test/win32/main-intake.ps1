# main-intake acceptance (tracker T2260): the main intake runs several times a
# day, whenever origin/main has moved AND the window since the last intake has
# passed, and exactly one lane runs it at a time (scripts\main-intake.ps1).
#
# Sections, all against a throwaway git repo with a planted "main" branch and
# a fixed clock, so nothing on the live repo or the real lease is touched:
#   A. main has not moved past the watermark: NOT DUE, exit 0.
#   B. main moved, the last intake 1h ago: NOT DUE inside the 4h window, and
#      the line says when it falls due.
#   C. main moved, the last intake 5h ago: INTAKE DUE, exit 3 (the positive
#      control for A and B - the same fixture CAN say due).
#   D. one lane at a time: lane a claims; lane b's check is BUSY (exit 4), its
#      claim is REFUSED (exit 3) and its record is refused.
#   E. record: refused without a merge task, refused with a CLOSED one, refused
#      with a P2 one; accepted with an open P1 one - the watermark moves to
#      main, keeps its old note, and the run carries the worst latency.
#      Afterwards the check is NOT DUE again.
#   F. release is lane-scoped; a lease nobody released expires.
#   G. a newer watermark on the branch's remote refuses the record (pull
#      first), so two lanes' watermark commits cannot conflict - and the check
#      honours the remote one.
#   H. `day` reports the day's runs and worst latency for the digest.
#   I. wiring: step 0's claim asks the check, go.md says so, and "daily for
#      now" is gone.
#
# `-NegativeControl` inverts C1, so the run must end in exactly one failure.
#
#   powershell -NoProfile -File test\win32\main-intake.ps1
param(
    [string]$Repo = (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent),
    [switch]$NegativeControl
)

$ErrorActionPreference = 'Continue'

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:failures = 0
$script:passes = 0

$Script = Join-Path $Repo 'scripts\main-intake.ps1'
$work = Join-Path $env:TEMP "ghoztty-main-intake-$PID"
$fx = Join-Path $work 'repo'
New-Item -ItemType Directory -Force $fx | Out-Null
$env:GHOZTTY_MACHINE_LOCK_SCOPE = "test-$PID"
$env:GHOZTTY_MACHINE_LOCK_DIR = Join-Path $work 'locks'
$env:GHOZTTY_INTAKE_NOW = '2026-10-25T14:00:00'

function Assert($name, $cond, $Detail = $null) {
    if ($cond) { "  PASS $name"; $script:passes++ } else { "  FAIL $name"; $script:failures++; if ($Detail) { ($Detail -split "`r?`n") | ForEach-Object { "        | $_" } } }
}

function G {
    $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { & git -C $fx -c user.name=fixture -c user.email=fixture@example.invalid -c core.hooksPath=NUL -c commit.gpgsign=false @args 2>&1 | ForEach-Object { $_.ToString() } | Out-String } finally { $ErrorActionPreference = $eap }
}

function Commit-At([string]$When, [string]$Msg) {
    $env:GIT_COMMITTER_DATE = $When; $env:GIT_AUTHOR_DATE = $When
    try { $null = G commit --allow-empty -q -m $Msg } finally { Remove-Item Env:GIT_COMMITTER_DATE, Env:GIT_AUTHOR_DATE -ErrorAction SilentlyContinue }
    return ((G rev-parse --short=9 HEAD).Trim())
}

$wmPath = Join-Path $fx 'docs\design\windows-parity-main-intake.json'
function Set-Watermark([string]$Sha, [string]$At) {
    $o = [ordered]@{ lastEvaluated = $Sha; date = $At.Substring(0, 10); at = $At; note = 'OLD NOTE' }
    if ($At.Length -eq 10) { $o.Remove('at') }
    [IO.File]::WriteAllText($wmPath, ($o | ConvertTo-Json) + "`n")
}

function New-Task([string]$Id, [string]$Status, [string]$Priority) {
    $t = "---`nid: $Id`ntitle: `"Merge origin/main`"`nstatus: `"$Status`"`npriority: `"$Priority`"`n---`n"
    [IO.File]::WriteAllText((Join-Path $fx "docs\design\windows-parity-tasks\$Id.md"), $t)
}

# Run the script under test as lane $Lane; returns @{ Code; Out }.
function Intake([string]$Lane, [string[]]$Arguments) {
    $saved = $env:GHOZTTY_LOOP_LANE
    $env:GHOZTTY_LOOP_LANE = $Lane
    try {
        $o = & powershell -NoProfile -ExecutionPolicy Bypass -File $Script @Arguments -Repo $fx -MainRef fakemain -NoFetch 2>&1 |
            ForEach-Object { $_.ToString() } | Out-String
        return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $o }
    } finally { $env:GHOZTTY_LOOP_LANE = $saved }
}

try {
    Reset-TestBody

    # ---- fixture: trunk carries the watermark; fakemain is "origin/main"
    $null = G init -q -b trunk
    New-Item -ItemType Directory -Force (Join-Path $fx 'docs\design\windows-parity-tasks') | Out-Null
    $c0 = Commit-At '2026-10-24T20:00:00' 'c0: the evaluated main'
    $null = G branch fakemain
    Set-Watermark $c0 '2026-10-25T13:00:00'
    $null = G add -A; $c0w = Commit-At '2026-10-24T21:00:00' 'watermark'

    "A. main has not moved"
    $r = Intake 'a' @('check', '-BranchRef', 'none')
    Assert 'A1 NOT DUE when main sits on the watermark, exit 0' ($r.Code -eq 0 -and $r.Out -match "INTAKE NOT DUE: fakemain has not moved from $c0") $r.Out

    # Main moves: two Mac commits, the oldest landed at 04:00.
    $null = G checkout -q fakemain
    $c1 = Commit-At '2026-10-25T04:00:00' 'mac: one'
    $c2 = Commit-At '2026-10-25T11:30:00' 'mac: two'
    $null = G checkout -q trunk

    "B. inside the window"
    $r = Intake 'a' @('check', '-BranchRef', 'none')
    Assert 'B1 main moved but the last intake was 1h ago: NOT DUE, exit 0' ($r.Code -eq 0 -and $r.Out -match 'INTAKE NOT DUE: fakemain moved 2 commit\(s\) past' -and $r.Out -match 'inside the 4h window') $r.Out
    Assert 'B2 and it says when the intake falls due (13:00 + 4h)' ($r.Out -match 'due at 17:00') $r.Out
    Assert 'B3 and how long the oldest Mac commit has waited (10h)' ($r.Out -match 'the oldest waiting 10h 00m') $r.Out

    "C. past the window"
    Set-Watermark $c0 '2026-10-25T09:00:00'
    $r = Intake 'a' @('check', '-BranchRef', 'none')
    $c1ok = $r.Code -eq 3 -and $r.Out -match 'INTAKE DUE: fakemain moved 2 commit\(s\)' -and $r.Out -match 'last intake 5h 00m ago'
    if ($NegativeControl) { $c1ok = -not $c1ok }
    Assert 'C1 main moved and the last intake was 5h ago: INTAKE DUE, exit 3' $c1ok $r.Out
    $r = Intake 'a' @('check', '-BranchRef', 'none', '-Hours', '6')
    Assert 'C2 the window is a parameter: -Hours 6 keeps the same state NOT DUE' ($r.Code -eq 0 -and $r.Out -match 'inside the 6h window') $r.Out
    Set-Watermark $c0 '2026-10-24'
    $r = Intake 'a' @('check', '-BranchRef', 'none')
    Assert 'C3 a pre-T2260 watermark (date only) reads as that morning''s 05:00 intake' ($r.Code -eq 3 -and $r.Out -match 'last intake 33h 00m ago') $r.Out
    Set-Watermark $c0 '2026-10-25T09:00:00'

    "D. one lane at a time"
    $r = Intake 'a' @('claim', '-BranchRef', 'none')
    Assert 'D1 lane a claims the due intake' ($r.Code -eq 0 -and $r.Out -match 'INTAKE CLAIMED by lane a') $r.Out
    $r = Intake 'b' @('check', '-BranchRef', 'none')
    Assert 'D2 lane b''s check is BUSY while lane a holds it, exit 4' ($r.Code -eq 4 -and $r.Out -match 'INTAKE BUSY: .*lane a is running the intake') $r.Out
    $r = Intake 'b' @('claim', '-BranchRef', 'none')
    Assert 'D3 lane b''s claim is REFUSED, exit 3' ($r.Code -eq 3 -and $r.Out -match 'INTAKE REFUSED: lane a holds the intake lease') $r.Out
    $r = Intake 'b' @('record', '-BranchRef', 'none', '-NoMergeTask', '-Reason', 'x')
    Assert 'D4 lane b cannot record over lane a''s lease' ($r.Code -eq 1 -and $r.Out -match 'INTAKE RECORD REFUSED: this lane \(b\) does not hold the intake lease \(lane a holds it\)') $r.Out
    $r = Intake 'a' @('claim', '-BranchRef', 'none')
    Assert 'D5 lane a re-claiming its own lease is fine' ($r.Code -eq 0 -and $r.Out -match 'INTAKE CLAIMED by lane a') $r.Out

    "E. record"
    New-Task 'T1' 'todo' 'P1'; New-Task 'T8' 'todo' 'P2'; New-Task 'T9' 'done' 'P1'; New-Task 'T5' 'todo' 'P1'
    $r = Intake 'a' @('record', '-BranchRef', 'none', '-Tasks', 'T5')
    Assert 'E1 Mac commits with no merge task: MERGE TASK REQUIRED' ($r.Code -eq 1 -and $r.Out -match 'MERGE TASK REQUIRED - 2 Mac commit') $r.Out
    $r = Intake 'a' @('record', '-BranchRef', 'none', '-Tasks', 'T5', '-MergeTask', 'T9')
    Assert 'E2 a CLOSED merge task is refused' ($r.Code -eq 1 -and $r.Out -match 'merge task T9 is already closed') $r.Out
    $r = Intake 'a' @('record', '-BranchRef', 'none', '-Tasks', 'T5', '-MergeTask', 'T8')
    Assert 'E3 a P2 merge task is refused (the merge must follow the same day)' ($r.Code -eq 1 -and $r.Out -match 'must be P1 or higher') $r.Out
    $r = Intake 'a' @('record', '-BranchRef', 'none', '-Tasks', 'T5,T404', '-MergeTask', 'T1')
    Assert 'E4 a filed task id with no file is refused' ($r.Code -eq 1 -and $r.Out -match 'no task file for T404') $r.Out
    $before = [IO.File]::ReadAllText($wmPath)
    Assert 'E5 no refused record touched the watermark' ($before -match '"OLD NOTE"' -and $before -notmatch '"runs"') $before
    $r = Intake 'a' @('record', '-BranchRef', 'none', '-Tasks', 'T5', '-MergeTask', 'T1', '-Note', 'two mac commits, T5 filed')
    Assert 'E6 an open P1 merge task records, exit 0' ($r.Code -eq 0 -and $r.Out -match "INTAKE RECORDED: watermark $c0 -> $c2, 2 commit\(s\), worst latency 10h 00m") $r.Out
    $wm = [IO.File]::ReadAllText($wmPath) | ConvertFrom-Json
    Assert 'E7 the watermark moved to main, stamped with date AND time' ($wm.lastEvaluated -eq $c2 -and $wm.at -eq '2026-10-25T14:00:00' -and $wm.date -eq '2026-10-25') ($wm | ConvertTo-Json)
    Assert 'E8 the note keeps its per-run entry (date and time) in front of the old one' ([string]$wm.note -match '^2026-10-25 14:00 intake \(lane a\): two mac commits, T5 filed \|\| OLD NOTE$') $wm.note
    $run = @($wm.runs)[0]
    Assert 'E9 the run records range, tasks, merge task and worst latency (600 min)' ($run.from -eq $c0 -and $run.to -eq $c2 -and $run.commits -eq 2 -and (@($run.tasks) -join ',') -eq 'T5' -and $run.mergeTask -eq 'T1' -and [double]$run.worstLatencyMinutes -eq 600) ($run | ConvertTo-Json)
    $raw = [IO.File]::ReadAllBytes($wmPath)
    Assert 'E10 written as UTF-8 without a BOM' (-not ($raw.Length -ge 3 -and $raw[0] -eq 0xEF -and $raw[1] -eq 0xBB))
    $r = Intake 'a' @('check', '-BranchRef', 'none')
    Assert 'E11 after the record the check is NOT DUE again (main has not moved)' ($r.Code -eq 0 -and $r.Out -match "has not moved from $c2") $r.Out

    "F. release and expiry"
    $r = Intake 'b' @('release')
    Assert 'F1 lane b cannot release lane a''s lease' ($r.Out -match 'not held by this lane \(lane a has it\)') $r.Out
    $r = Intake 'a' @('release')
    Assert 'F2 lane a releases it' ($r.Out -match 'INTAKE RELEASED by lane a') $r.Out
    $r = Intake 'b' @('claim', '-BranchRef', 'none')
    Assert 'F3 with nothing due, a claim takes no lease (exit 5)' ($r.Code -eq 5 -and $r.Out -match 'INTAKE NOT CLAIMED') $r.Out
    $r = Intake 'b' @('claim', '-BranchRef', 'none', '-Force')
    Assert 'F4 -Force claims anyway' ($r.Code -eq 0 -and $r.Out -match 'INTAKE CLAIMED by lane b') $r.Out
    $env:GHOZTTY_INTAKE_NOW = '2026-10-25T16:00:00'
    $r = Intake 'a' @('claim', '-BranchRef', 'none', '-Force')
    Assert 'F5 two hours on, lane b''s unreleased 90-minute lease has expired and lane a can claim' ($r.Code -eq 0 -and $r.Out -match 'INTAKE CLAIMED by lane a') $r.Out
    $env:GHOZTTY_INTAKE_NOW = '2026-10-25T14:00:00'

    "G. the other lane's newer watermark"
    $null = G add -A; $null = Commit-At '2026-10-25T14:00:00' 'record'
    $null = G checkout -q -b remote-trunk
    $o = [IO.File]::ReadAllText($wmPath) | ConvertFrom-Json
    $o.at = '2026-10-25T15:30:00'
    [IO.File]::WriteAllText($wmPath, ($o | ConvertTo-Json -Depth 6) + "`n")
    $null = G add -A; $null = Commit-At '2026-10-25T15:30:00' 'other lane recorded'
    $null = G checkout -q trunk
    $env:GHOZTTY_INTAKE_NOW = '2026-10-25T16:00:00'
    $r = Intake 'a' @('record', '-BranchRef', 'remote-trunk', '-NoMergeTask', '-Reason', 'x')
    Assert 'G1 a newer watermark on the remote branch refuses the record: pull first' ($r.Code -eq 1 -and $r.Out -match 'carries a newer watermark .* git pull --rebase first') $r.Out
    $r = Intake 'a' @('status', '-BranchRef', 'remote-trunk')
    Assert 'G2 the check reads the newer remote watermark' ($r.Out -match 'watermark from origin') $r.Out
    $env:GHOZTTY_INTAKE_NOW = '2026-10-25T14:00:00'
    $null = Intake 'a' @('release')

    "H. the digest line"
    $r = Intake 'a' @('day', '-Date', '2026-10-25', '-BranchRef', 'none')
    Assert 'H1 day reports the runs and the worst Mac-commit -> filed latency' ($r.Out -match 'INTAKES 2026-10-25: 1 run\(s\), 2 commit\(s\) evaluated, 1 task\(s\) filed, worst latency 10h 00m') $r.Out
    $r = Intake 'a' @('day', '-Date', '2026-10-26', '-BranchRef', 'none')
    Assert 'H2 a day with no run says none recorded' ($r.Out -match 'INTAKES 2026-10-26: none recorded') $r.Out

    "I. wiring"
    $exec = [IO.File]::ReadAllText((Join-Path $Repo 'scripts\go-loop-exec.ps1'))
    Assert 'I1 step 0''s claim asks main-intake.ps1 check' ($exec -match "main-intake\.ps1'" -and $exec -match '\bcheck\b')
    $go = [IO.File]::ReadAllText((Join-Path $Repo 'go.md'))
    Assert 'I2 go.md names the due-check in step 0.6' ($go -match 'scripts\\main-intake\.ps1 claim' -and $go -match 'INTAKE DUE')
    Assert 'I3 go.md no longer says the intake is "daily for now"' ($go -notmatch 'daily for now')

    Complete-TestBody
}
finally {
    Remove-Item Env:GHOZTTY_MACHINE_LOCK_SCOPE, Env:GHOZTTY_MACHINE_LOCK_DIR, Env:GHOZTTY_INTAKE_NOW, Env:GHOZTTY_LOOP_LANE -ErrorAction SilentlyContinue
    if (Test-Path $work) { Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue }
}

# --- stamp (T783) ----------------------------------------------------------------
if ($script:failures -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard main-intake -Repo $Repo 2>&1 | ForEach-Object { Write-Host "  $_" }
}

""
Write-TestVerdict -Pass $script:passes -Fail $script:failures
