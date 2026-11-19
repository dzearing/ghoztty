# loop-blocked-time.ps1 (T1488) - how long was the loop BLOCKED on a given day?
#
#   powershell -NoProfile -File scripts\loop-blocked-time.ps1                 # yesterday, every lane
#   powershell -NoProfile -File scripts\loop-blocked-time.ps1 -Date 2026-11-18
#   powershell -NoProfile -File scripts\loop-blocked-time.ps1 -Format markdown  # the digest's sentence
#   powershell -NoProfile -File scripts\loop-blocked-time.ps1 -Format json
#
# WHY IT EXISTS
#
# The morning digest's Commentary (go.md step 0.5) is written from the session
# log and the tracker. Both are silent about the hours the loop spent unable to
# work - a usage limit, an expired login - because a blocked turn writes nothing
# at all. So a day that shipped little because the account was out of budget
# read exactly like a slow day, in the one artifact meant to say what happened.
# On 2026-11-18 both lanes sat behind "You've hit your weekly limit" from 03:32
# to 20:14 and nothing in the log said so.
#
# The watchdog DOES know. Every tick it classifies the loop session's last
# answer (Resolve-LoopBlocker, T1483) and, when it is a blocker, logs
#
#     2026-11-18 03:37:59   BLOCKED(usage-limit, by=transcript): the session's last
#         answer was not work, it was '<message>' - clears 2026-11-21 00:00
#
# into %TEMP%\ghoztty-go-loop-watchdog[-<lane>].log. This script reads those
# observations back and turns them into spans: consecutive observations no more
# than -MaxGapMinutes apart, with no `healthy:` tick between them, are one span
# running from the first observation to the last. Spans are clipped to the day
# asked about, so a block that crossed midnight is counted in both days.
#
# THE VERDICTS (first word of the first line; exit 0 for all three - this is a
# report, and the digest must be written whatever it says):
#
#   LOOP BLOCKED      some lane was blocked for -MaterialMinutes or more. The
#                     digest's Commentary MUST say so, for how long, and why.
#   LOOP NOT BLOCKED  no lane was blocked for a material time (a sub-threshold
#                     span is still listed, as minor, and needs no sentence).
#   LOOP UNKNOWN      no watchdog log could be read for any lane, or no log
#                     carries a line from that day - never reported as "not
#                     blocked", because an absent watchdog is exactly when a
#                     block goes unseen.
#
# Exit 2 = bad arguments.
#
# Seams for the acceptance harness (test\win32\loop-blocked-time.ps1):
#   -LogPath 'a=C:\x.log','b=C:\y.log'   read these instead of the lanes' logs.
param(
    [string]$Date,
    [string[]]$LogPath,
    [int]$MaxGapMinutes = 20,
    [int]$MaterialMinutes = 60,
    [ValidateSet('text', 'markdown', 'json')][string]$Format = 'text',
    [string]$Repo
)

$ErrorActionPreference = 'Stop'
if (-not $Repo) { $Repo = Split-Path $PSScriptRoot -Parent }

if (-not $Date) { $Date = (Get-Date).Date.AddDays(-1).ToString('yyyy-MM-dd') }
$dayStart = [datetime]::MinValue
if (-not [datetime]::TryParseExact($Date, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::None, [ref]$dayStart)) {
    Write-Host "usage: -Date must be yyyy-MM-dd (got '$Date')"
    exit 2
}
$dayEnd = $dayStart.AddDays(1)

# --- which logs ------------------------------------------------------------
$logs = @()
if ($LogPath) {
    foreach ($spec in $LogPath) {
        foreach ($one in ([string]$spec -split ',')) {
            if ($one -notmatch '^\s*([A-Za-z0-9]+)=(.+)$') {
                Write-Host "usage: -LogPath entries are lane=path (got '$one')"
                exit 2
            }
            $logs += [pscustomobject]@{ Lane = $Matches[1].ToLowerInvariant(); Path = $Matches[2].Trim() }
        }
    }
} else {
    . (Join-Path $Repo 'scripts\lib\LoopLane.ps1')
    $ids = @()
    try { $ids = @(Get-LoopLanes -Repo $Repo | ForEach-Object { $_.Id }) } catch { $ids = @() }
    if ($ids.Count -eq 0) { $ids = @('a') }
    foreach ($id in $ids) { $logs += [pscustomobject]@{ Lane = $id; Path = (Get-LoopLaneWatchdogLog $id) } }
}

# --- read observations -----------------------------------------------------
# Only lines near the day matter: a span can start the evening before and end
# the morning after, so read [day - MaxGap - 1h, dayEnd + MaxGap + 1h).
$readFrom = $dayStart.AddMinutes(-($MaxGapMinutes + 60))
$readTo = $dayEnd.AddMinutes($MaxGapMinutes + 60)
$inv = [Globalization.CultureInfo]::InvariantCulture
$rxStamp = '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) (.*)$'
$rxBlocked = "^\s+BLOCKED\(([^,)]+)[^)]*\): the session's last answer was not work, it was '(.*)'(?: - clears (.+))?\s*$"
$rxHealthy = '^healthy:'

function Format-Duration([double]$minutes) {
    $m = [int][math]::Round($minutes)
    if ($m -lt 60) { return "${m}m" }
    return ('{0}h{1:00}m' -f [int][math]::Floor($m / 60), ($m % 60))
}

function Clean-Why([string]$s) {
    # The watchdog writes with PS5.1's ANSI Add-Content, so a dash in Claude's
    # message comes back as whatever the codepage made of it. Normalize.
    $s = $s -replace '[\u2013\u2014\uFFFD]', '-'
    return $s.Trim()
}

$laneResults = @()
foreach ($lg in $logs) {
    $res = [ordered]@{
        lane = $lg.Lane; log = $lg.Path; readable = $false; saw_day = $false
        minutes = 0.0; spans = @()
    }
    if (-not (Test-Path -LiteralPath $lg.Path)) { $laneResults += [pscustomobject]$res; continue }
    $res.readable = $true
    $obs = New-Object System.Collections.ArrayList
    $enc = [System.Text.Encoding]::Default
    $fromKey = $readFrom.ToString('yyyy-MM-dd HH:mm:ss')
    $toKey = $readTo.ToString('yyyy-MM-dd HH:mm:ss')
    $dayKey = $dayStart.ToString('yyyy-MM-dd')
    try {
        foreach ($line in [System.IO.File]::ReadLines($lg.Path, $enc)) {
            if ($line.Length -lt 20) { continue }
            $key = $line.Substring(0, 19)
            # Ordinal compare on the fixed-width stamp: cheap, and correct for
            # the yyyy-MM-dd HH:mm:ss shape. Lines without a stamp sort apart.
            if ([string]::CompareOrdinal($key, $fromKey) -lt 0) { continue }
            if ([string]::CompareOrdinal($key, $toKey) -ge 0) { break }
            if ($line -notmatch $rxStamp) { continue }
            $at = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss', $inv)
            $rest = $Matches[2]
            if ($key.StartsWith($dayKey)) { $res.saw_day = $true }
            if ($rest -match $rxBlocked) {
                [void]$obs.Add([pscustomobject]@{ At = $at; Blocked = $true; Kind = $Matches[1].Trim()
                    Why = (Clean-Why $Matches[2]); Clears = $(if ($Matches[3]) { $Matches[3].Trim() } else { '' }) })
            } elseif ($rest -match $rxHealthy) {
                [void]$obs.Add([pscustomobject]@{ At = $at; Blocked = $false })
            }
        }
    } catch {
        $res.readable = $false
        $res['error'] = $_.Exception.Message
        $laneResults += [pscustomobject]$res
        continue
    }

    # Group into spans.
    $spans = @()
    $cur = $null
    foreach ($o in $obs) {
        if (-not $o.Blocked) { if ($cur) { $spans += $cur; $cur = $null }; continue }
        if ($cur -and (($o.At - $cur.Last).TotalMinutes -le $MaxGapMinutes) -and $o.Kind -eq $cur.Kind) {
            $cur.Last = $o.At; $cur.Why = $o.Why; $cur.Clears = $o.Clears; $cur.Count++
        } else {
            if ($cur) { $spans += $cur }
            $cur = [pscustomobject]@{ First = $o.At; Last = $o.At; Kind = $o.Kind; Why = $o.Why; Clears = $o.Clears; Count = 1 }
        }
    }
    if ($cur) { $spans += $cur }

    $total = 0.0
    $outSpans = @()
    foreach ($s in $spans) {
        $a = if ($s.First -lt $dayStart) { $dayStart } else { $s.First }
        $b = if ($s.Last -gt $dayEnd) { $dayEnd } else { $s.Last }
        if ($b -lt $a) { continue }
        if ($s.Last -lt $dayStart -or $s.First -ge $dayEnd) { continue }
        $mins = ($b - $a).TotalMinutes
        $total += $mins
        $outSpans += [pscustomobject]@{
            from = $a.ToString('HH:mm'); to = $b.ToString('HH:mm')
            from_at = $a.ToString('yyyy-MM-dd HH:mm:ss'); to_at = $b.ToString('yyyy-MM-dd HH:mm:ss')
            minutes = [math]::Round($mins, 1); kind = $s.Kind; why = $s.Why; clears = $s.Clears
            observations = $s.Count
            crossed_in = ($s.First -lt $dayStart); crossed_out = ($s.Last -gt $dayEnd)
        }
    }
    $res.minutes = [math]::Round($total, 1)
    $res.spans = $outSpans
    $laneResults += [pscustomobject]$res
}

# --- verdict ---------------------------------------------------------------
$readable = @($laneResults | Where-Object { $_.readable })
$sawDay = @($readable | Where-Object { $_.saw_day })
$worst = @($laneResults | Sort-Object { $_.minutes } -Descending)[0]
$material = @($laneResults | Where-Object { $_.minutes -ge $MaterialMinutes })
$verdict = if ($sawDay.Count -eq 0) { 'LOOP UNKNOWN' }
           elseif ($material.Count -gt 0) { 'LOOP BLOCKED' }
           else { 'LOOP NOT BLOCKED' }
$why = ''
if ($verdict -eq 'LOOP UNKNOWN') {
    $why = if ($readable.Count -eq 0) { 'no watchdog log could be read for any lane' }
           else { "no watchdog log carries a line from $Date - the watchdog was not running, so a block would have gone unseen" }
}
$pct = if ($worst) { [math]::Round(100.0 * $worst.minutes / 1440.0) } else { 0 }

# The dominant reason: the longest span on the worst lane.
$main = $null
if ($worst -and @($worst.spans).Count) { $main = @($worst.spans | Sort-Object { $_.minutes } -Descending)[0] }

function Get-KindPhrase([string]$kind) {
    switch ($kind) {
        'usage-limit' { return 'this Claude account had hit its usage limit' }
        'login'       { return 'the Claude login had expired' }
        'api-error'   { return 'the Claude API kept answering with an error instead of work' }
        default       { return "the session was blocked ($kind)" }
    }
}

if ($Format -eq 'json') {
    [pscustomobject]@{
        date = $Date; verdict = $verdict; why = $why
        material_minutes = $MaterialMinutes; max_gap_minutes = $MaxGapMinutes
        worst_lane = $(if ($worst) { $worst.lane } else { '' })
        worst_minutes = $(if ($worst) { $worst.minutes } else { 0 })
        worst_percent_of_day = $pct
        lanes = @($laneResults)
    } | ConvertTo-Json -Depth 6
    exit 0
}

if ($Format -eq 'markdown') {
    switch ($verdict) {
        'LOOP UNKNOWN' {
            "**Whether the loop was blocked on $Date is unknown**: $why."
        }
        'LOOP NOT BLOCKED' {
            "The loop was not blocked on $Date - a thin day there is a thin day of work."
        }
        default {
            $laneWord = if ($material.Count -gt 1) { 'every lane' } else { "lane $($worst.lane)" }
            if ($material.Count -gt 1 -and $material.Count -lt @($laneResults).Count) {
                $laneWord = 'lanes ' + (($material | ForEach-Object { $_.lane }) -join ' and ')
            }
            $line = ("**The loop was blocked for $(Format-Duration $worst.minutes) on $Date** ($pct% of the day, " +
                     "$laneWord, $($main.from)-$($main.to)): $(Get-KindPhrase $main.kind) - '$($main.why)'.")
            if ($main.clears) { $line += " It was due to clear $($main.clears)." }
            $line += ' The loop cannot work through that, so what landed that day is what fit around the block, not a slow day.'
            $line
        }
    }
    exit 0
}

# text
$head = "$verdict ${Date}:"
if ($verdict -eq 'LOOP UNKNOWN') { $head += " $why" }
elseif ($worst.minutes -gt 0) { $head += " worst lane $($worst.lane) $(Format-Duration $worst.minutes) ($pct% of the day)" }
else { $head += ' no lane saw a blocker' }
$head
foreach ($l in $laneResults) {
    if (-not $l.readable) {
        $e = if ($l.PSObject.Properties['error']) { ": $($l.error)" } else { '' }
        "  lane $($l.lane)  no log ($($l.log))$e"
        continue
    }
    if (-not $l.saw_day) { "  lane $($l.lane)  log has no line from $Date"; continue }
    "  lane $($l.lane)  $(Format-Duration $l.minutes)$(if ($l.minutes -gt 0 -and $l.minutes -lt $MaterialMinutes) { ' (minor)' })"
    foreach ($s in $l.spans) {
        $c = if ($s.clears) { " (clears $($s.clears))" } else { '' }
        "    $($s.from)-$($s.to)  $($s.kind): '$($s.why)'$c"
    }
}
exit 0
