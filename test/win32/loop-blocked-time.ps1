# T1488 acceptance - the morning digest can say how long the loop was BLOCKED.
#
#   powershell -NoProfile -File test\win32\loop-blocked-time.ps1
#
# Non-interactive. Launches no Ghoztty and touches no user state.
#
# isolation: none - no ghoztty binary is run and no CLI verb is invoked; the
# only executable this script starts is powershell (the subject), reading
# fixture logs written to a private temp sandbox. (T680 meta-check reads this
# marker.)
#
# WHY IT EXISTS
#
# scripts\loop-blocked-time.ps1 turns the watchdog's per-tick BLOCKED(...)
# observations into "the loop was blocked for 16h42m yesterday", which is what
# the digest's Commentary says instead of letting a blocked day read as a slow
# one. Its two lies that matter: a blocked day reported as not blocked (the
# digest then narrates a slow day again), and a day with no watchdog at all
# reported as not blocked (an unseen block is still a block).
#
# A - spans: one block inside the day is measured first-to-last observation,
#     with its kind, message and reset parsed; a healthy tick ends a span; a gap
#     longer than -MaxGapMinutes ends a span; a block that crossed midnight is
#     clipped to the day; a short block is minor and does not flip the verdict.
# B - absence: no log, or a log with no line from that day, is UNKNOWN - never
#     NOT BLOCKED.
# C - output: the markdown sentence names the duration, share of the day and the
#     reason in plain words; json carries the numbers; a bad -Date is exit 2.
# D - wiring: go.md's digest step runs the script and states the rule.
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
function Say($m) { Write-Host $m }

$Subject = Join-Path $Repo 'scripts\loop-blocked-time.ps1'
$GoMd = Join-Path $Repo 'go.md'

function Invoke-Subject {
    param([string[]]$SubjectArgs)
    $ErrorActionPreference = 'SilentlyContinue'
    $out = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $Subject @SubjectArgs 2>&1 | ForEach-Object { $_.ToString() })
    return [pscustomobject]@{ Code = $LASTEXITCODE; Text = ($out -join "`n"); Lines = $out }
}

$sandbox = Join-Path $env:TEMP ("loop-blocked-time-T1488-" + $PID + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Path $sandbox -Force | Out-Null

# The watchdog writes with PS5.1 Add-Content, i.e. the ANSI codepage; write the
# fixtures the same way so the dash normalization is exercised for real.
function Write-Log([string]$name, [string[]]$lines) {
    $p = Join-Path $sandbox $name
    [System.IO.File]::WriteAllLines($p, $lines, [System.Text.Encoding]::Default)
    return $p
}
$dash = [string][char]0x2014
function New-FxBlocked([string]$at, [string]$kind = 'usage-limit', [string]$clears = '2026-11-21 00:00') {
    $c = if ($clears) { " - clears $clears" } else { '' }
    return "$at   BLOCKED($kind, by=transcript): the session's last answer was not work, it was 'You've hit your weekly limit $dash resets Nov 21, 12am'$c"
}
function New-FxHealthy([string]$at) { return "$at healthy: pane=X pid=1 age=3m(by=transcript)" }
function New-FxHold([string]$at) { return "$at QUOTA HOLD: the quota clears 2026-11-21 00:00; not re-entering" }

try {
    # ---- A: spans -----------------------------------------------------------
    Say 'A - spans'
    $one = Write-Log 'one.log' @(
        (New-FxHealthy '2026-11-18 03:20:00'),
        (New-FxBlocked '2026-11-18 03:32:00'), (New-FxHold '2026-11-18 03:32:00'),
        (New-FxBlocked '2026-11-18 03:37:00'), (New-FxBlocked '2026-11-18 03:42:00'),
        (New-FxBlocked '2026-11-18 20:10:00'),   # a long hold with sparse ticks, see A3 for the gap rule
        (New-FxHealthy '2026-11-18 20:20:00')
    )
    # 03:42 -> 20:10 is a gap far over 20 minutes, so with the default this is
    # two spans; a gap rule wide enough joins them. Fill the hold with ticks.
    $ticks = @((New-FxHealthy '2026-11-18 03:20:00'))
    $t = [datetime]'2026-11-18 03:32:00'
    while ($t -le [datetime]'2026-11-18 20:14:00') { $ticks += (New-FxBlocked $t.ToString('yyyy-MM-dd HH:mm:ss')); $t = $t.AddMinutes(5) }
    $ticks += (New-FxHealthy '2026-11-18 20:20:00')
    $full = Write-Log 'full.log' $ticks
    $r = Invoke-Subject @('-Date', '2026-11-18', '-LogPath', "a=$full", '-Format', 'json')
    $j = $null; try { $j = $r.Text | ConvertFrom-Json } catch { }
    $lane = if ($j) { @($j.lanes | ForEach-Object { $_ })[0] } else { $null }
    $span = if ($lane) { @($lane.spans | ForEach-Object { $_ })[0] } else { $null }
    Assert 'A1 a block inside the day is LOOP BLOCKED' ($j -and $j.verdict -eq 'LOOP BLOCKED') "verdict=$($j.verdict) text=$($r.Text)"
    Assert 'A2 it is measured first to last observation (03:32 -> 20:12 = 1000 min)' ($lane -and $lane.minutes -eq 1000) "minutes=$($lane.minutes)"
    Assert 'A3 it is ONE span when the ticks are inside the gap' (@($lane.spans | ForEach-Object { $_ }).Count -eq 1) "spans=$(@($lane.spans).Count)"
    Assert 'A4 kind, message and reset are parsed' ($span -and $span.kind -eq 'usage-limit' -and $span.why -match '^You.ve hit your weekly limit - resets Nov 21, 12am$' -and $span.clears -eq '2026-11-21 00:00') "kind=$($span.kind) why=$($span.why) clears=$($span.clears)"
    Assert 'A5 the codepage dash is normalized to a plain hyphen' ($span -and $span.why -notmatch '[^\x20-\x7E]') "why=$($span.why)"

    $r = Invoke-Subject @('-Date', '2026-11-18', '-LogPath', "a=$one", '-Format', 'json')
    $j = $null; try { $j = $r.Text | ConvertFrom-Json } catch { }
    $lane = if ($j) { @($j.lanes | ForEach-Object { $_ })[0] } else { $null }
    Assert 'A6 a gap over -MaxGapMinutes ends the span (03:32-03:42 and a lone 20:10)' ($lane -and @($lane.spans | ForEach-Object { $_ }).Count -eq 2 -and $lane.minutes -eq 10) "spans=$(@($lane.spans).Count) minutes=$($lane.minutes)"
    Assert 'A7 a 10-minute block is not material: LOOP NOT BLOCKED' ($j -and $j.verdict -eq 'LOOP NOT BLOCKED') "verdict=$($j.verdict)"
    $r = Invoke-Subject @('-Date', '2026-11-18', '-LogPath', "a=$one")
    Assert 'A8 ...and the text report still lists it, marked minor' ($r.Text -match 'lane a\s+10m \(minor\)' -and $r.Text -match '03:32-03:42') $r.Text

    $split = Write-Log 'split.log' @(
        (New-FxBlocked '2026-11-18 10:00:00'), (New-FxBlocked '2026-11-18 10:05:00'), (New-FxHealthy '2026-11-18 10:10:00'),
        (New-FxBlocked '2026-11-18 10:15:00'), (New-FxBlocked '2026-11-18 10:20:00')
    )
    $j = (Invoke-Subject @('-Date', '2026-11-18', '-LogPath', "a=$split", '-Format', 'json')).Text | ConvertFrom-Json
    $lane = @($j.lanes | ForEach-Object { $_ })[0]
    Assert 'A9 a healthy tick between observations ends the span (two 5m spans, not one 20m)' (@($lane.spans | ForEach-Object { $_ }).Count -eq 2 -and $lane.minutes -eq 10) "spans=$(@($lane.spans).Count) minutes=$($lane.minutes)"

    $mid = Write-Log 'midnight.log' @(
        (New-FxBlocked '2026-11-17 23:50:00'), (New-FxBlocked '2026-11-17 23:55:00'),
        (New-FxBlocked '2026-11-18 00:00:30'), (New-FxBlocked '2026-11-18 00:05:00'), (New-FxBlocked '2026-11-18 00:10:00')
    )
    $j = (Invoke-Subject @('-Date', '2026-11-18', '-LogPath', "a=$mid", '-Format', 'json')).Text | ConvertFrom-Json
    $lane = @($j.lanes | ForEach-Object { $_ })[0]
    $s0 = @($lane.spans | ForEach-Object { $_ })[0]
    Assert 'A10 a block that crossed midnight is clipped to the day (00:00 -> 00:10)' ($lane.minutes -eq 10 -and $s0.crossed_in -eq $true -and $s0.from -eq '00:00') "minutes=$($lane.minutes) from=$($s0.from)"
    $j = (Invoke-Subject @('-Date', '2026-11-17', '-LogPath', "a=$mid", '-Format', 'json')).Text | ConvertFrom-Json
    $lane = @($j.lanes | ForEach-Object { $_ })[0]
    Assert 'A11 ...and the day before gets its own share (23:50 -> 24:00)' ($lane.minutes -eq 10) "minutes=$($lane.minutes)"

    # ---- B: absence ---------------------------------------------------------
    Say 'B - absence is UNKNOWN, never NOT BLOCKED'
    $r = Invoke-Subject @('-Date', '2026-11-18', '-LogPath', "a=$(Join-Path $sandbox 'missing.log')")
    Assert 'B1 no readable log is LOOP UNKNOWN, exit 0' ($r.Lines[0] -match '^LOOP UNKNOWN 2026-11-18:' -and $r.Code -eq 0) "code=$($r.Code) first=$($r.Lines[0])"
    $other = Write-Log 'otherday.log' @((New-FxHealthy '2026-11-10 10:00:00'), (New-FxHealthy '2026-11-25 10:00:00'))
    $r = Invoke-Subject @('-Date', '2026-11-18', '-LogPath', "a=$other")
    Assert 'B2 a log with no line from the day is LOOP UNKNOWN (the watchdog was not running)' ($r.Lines[0] -match '^LOOP UNKNOWN .*not running') $r.Lines[0]
    $r = Invoke-Subject @('-Date', '2026-11-18', '-LogPath', "a=$other", '-Format', 'markdown')
    Assert 'B3 ...and the digest sentence says unknown rather than not blocked' ($r.Text -match 'is unknown' -and $r.Text -notmatch 'not blocked') $r.Text
    $quiet = Write-Log 'quiet.log' @((New-FxHealthy '2026-11-18 10:00:00'), (New-FxHealthy '2026-11-18 10:05:00'))
    $r = Invoke-Subject @('-Date', '2026-11-18', '-LogPath', "a=$quiet,b=$full")
    Assert 'B4 two lanes: the worst one decides, and each is listed' ($r.Lines[0] -match '^LOOP BLOCKED 2026-11-18: worst lane b 16h40m' -and $r.Text -match 'lane a\s+0m' -and $r.Text -match 'lane b\s+16h40m') $r.Text

    # ---- C: output ----------------------------------------------------------
    Say 'C - the digest sentence and the numbers'
    $r = Invoke-Subject @('-Date', '2026-11-18', '-LogPath', "a=$full,b=$full", '-Format', 'markdown')
    Assert 'C1 the markdown names the duration and the share of the day' ($r.Text -match '\*\*The loop was blocked for 16h40m on 2026-11-18\*\*' -and $r.Text -match '69% of the day') $r.Text
    Assert 'C2 ...says why in plain words, quotes the message and when it clears' ($r.Text -match 'usage limit' -and $r.Text -match "'You've hit your weekly limit - resets Nov 21, 12am'" -and $r.Text -match 'due to clear 2026-11-21 00:00') $r.Text
    Assert 'C3 ...and says what it means for the day (not a slow day)' ($r.Text -match 'not a slow day' -and $r.Text -match 'every lane') $r.Text
    $r = Invoke-Subject @('-Date', '2026-11-18', '-LogPath', "a=$quiet", '-Format', 'markdown')
    Assert 'C4 an unblocked day reads as not blocked' ($r.Text -match 'was not blocked on 2026-11-18') $r.Text
    $login = Write-Log 'login.log' @(
        ("2026-11-18 09:00:00   BLOCKED(login, by=transcript): the session's last answer was not work, it was 'Please run /login'"),
        ("2026-11-18 11:00:00   BLOCKED(login, by=transcript): the session's last answer was not work, it was 'Please run /login'")
    )
    $j = (Invoke-Subject @('-Date', '2026-11-18', '-LogPath', "a=$login", '-MaxGapMinutes', '180', '-Format', 'json')).Text | ConvertFrom-Json
    $lane = @($j.lanes | ForEach-Object { $_ })[0]
    Assert 'C5 -MaxGapMinutes widens the join; a block with no reset parses with clears empty' ($lane.minutes -eq 120 -and @($lane.spans)[0].clears -eq '' -and @($lane.spans)[0].kind -eq 'login') "minutes=$($lane.minutes)"
    $r = Invoke-Subject @('-Date', '2026-11-18', '-LogPath', "a=$login", '-MaxGapMinutes', '180', '-Format', 'markdown')
    Assert 'C6 a login block is named as an expired login' ($r.Text -match 'login had expired' -and $r.Text -notmatch 'due to clear') $r.Text
    $r = Invoke-Subject @('-Date', '18/11/2026')
    Assert 'C7 a malformed -Date is exit 2' ($r.Code -eq 2) "code=$($r.Code)"
    $r = Invoke-Subject @('-Date', '2026-11-18', '-LogPath', 'nolane')
    Assert 'C8 a malformed -LogPath is exit 2' ($r.Code -eq 2) "code=$($r.Code)"

    # ---- D: wiring ----------------------------------------------------------
    Say 'D - wiring'
    $go = Get-Content -LiteralPath $GoMd -Raw
    Assert 'D1 go.md step 0.5 runs the script' ($go -match 'scripts\\loop-blocked-time\.ps1')
    Assert 'D2 go.md states the rule: a LOOP BLOCKED day must be named in Commentary' ($go -match 'LOOP BLOCKED' -and $go -match 'T1488')
    $src = Get-Content -LiteralPath $Subject -Raw
    Assert 'D3 the subject is ASCII-only (PS5.1 reads a BOM-less script as ANSI)' ($src -notmatch '[^\x00-\x7F]')
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
        update -Guard loop-blocked-time -Repo $Repo 2>&1 | ForEach-Object { "  $_" }
}

Say ''
Write-TestVerdict -Pass $script:passes -Fail $script:failures -Skipped $script:skips -Label 'LOOP-BLOCKED-TIME'
