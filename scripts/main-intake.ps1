# main-intake.ps1 - when the Mac side's main is read into the Windows queue (T2260).
#
# The main intake (go.md step 0.6) reads every commit new on origin/main and
# breaks it into Windows tasks. Until T2260 it was part of the morning block,
# so it ran once a day: a Mac commit that landed at 09:00 was not even READ
# until 05:00 the next day, and its merge and port tasks queued behind that.
# User, 2026-10-25: "we should be checking main maybe a few times a day for mac
# updates so that updates stream with a very low latency."
#
# So the intake is its own due-check, asked at every task boundary (step 0's
# claim prints it) in either lane:
#
#   due  = origin/main has moved past the watermark
#          AND at least -Hours (4) have passed since the last intake
#
# and exactly one lane runs it at a time: `claim` takes a box-wide LEASE (a
# file under %LOCALAPPDATA%\ghoztty\machine-locks, written under a short-lived
# named mutex - the T1982 pattern, but a lease because an intake spans many
# tool calls and a mutex dies with the process that took it). `record` refuses
# unless this lane holds it, and refuses while the branch on origin carries a
# NEWER watermark than this tree - so the watermark commit can never conflict
# with the other lane's (the T2115 lesson: lane A's 40 minutes were thrown away
# at push-rebase on 2026-10-21).
#
#   powershell -NoProfile -File scripts\main-intake.ps1 check
#   powershell -NoProfile -File scripts\main-intake.ps1 claim
#   powershell -NoProfile -File scripts\main-intake.ps1 record -Tasks T1,T2 -MergeTask T3 -Note "..."
#   powershell -NoProfile -File scripts\main-intake.ps1 release
#   powershell -NoProfile -File scripts\main-intake.ps1 status
#   powershell -NoProfile -File scripts\main-intake.ps1 day -Date 2026-10-25
#
# check   exit 0 = not due (one 'INTAKE NOT DUE' / 'INTAKE UNKNOWN' line says why)
#              3 = 'INTAKE DUE': run the intake this turn, before step 1
#              4 = 'INTAKE BUSY': due, but another lane holds the lease
# claim   exit 0 = 'INTAKE CLAIMED' (lease held by this lane), 3 = 'INTAKE
#              REFUSED' (another lane holds it), 5 = not due (no lease taken;
#              -Force claims anyway)
# record  exit 0 = 'INTAKE RECORDED' (watermark file rewritten, NOT committed -
#              commit it with the filed tasks through the commit guard), 1 =
#              refused with the reason named
# release exit 0 always ('INTAKE RELEASED' or 'not held by this lane')
# day     the digest's line: how many intakes ran that day and the worst
#              Mac-commit -> filed latency
#
# Test seams: GHOZTTY_MACHINE_LOCK_SCOPE / GHOZTTY_MACHINE_LOCK_DIR (as in
# lib\MachineLock.ps1) move the mutex and the lease file; GHOZTTY_INTAKE_NOW
# (or -Now) fixes the clock; -MainRef / -BranchRef / -NoFetch point the check
# at a fixture repo. Acceptance: test\win32\main-intake.ps1.
#
# ASCII only and PS 5.1 compatible.

param(
    [Parameter(Position = 0)]
    [ValidateSet('check', 'claim', 'record', 'release', 'status', 'day')]
    [string]$Command = 'check',
    [string]$Repo,
    # The window: an intake is not due again until this long after the last.
    [double]$Hours = 4,
    [string]$MainRef = 'origin/main',
    # Where the OTHER lane's watermark is visible: the branch on origin.
    [string]$BranchRef = '@{u}',
    [switch]$NoFetch,
    [string]$Now,
    # A lease nobody released (a turn that died mid-intake) expires.
    [int]$LeaseMinutes = 90,
    [switch]$Force,
    # record
    [string]$To,
    [string[]]$Tasks = @(),
    [string]$MergeTask,
    [switch]$NoMergeTask,
    [string]$Reason,
    [string]$Note,
    # day
    [string]$Date
)

$ErrorActionPreference = 'Continue'
if (-not $Repo) { $Repo = Split-Path -Parent $PSScriptRoot }
# 'none' turns the remote read off (PS 5.1 drops an empty argument on the way
# to a child powershell, so '' cannot say it).
if ($BranchRef -eq 'none') { $BranchRef = '' }
. (Join-Path $PSScriptRoot 'lib\LoopLane.ps1')

$WatermarkRel = 'docs/design/windows-parity-main-intake.json'
$WatermarkPath = Join-Path $Repo ($WatermarkRel -replace '/', '\')
$TasksDir = Join-Path $Repo 'docs\design\windows-parity-tasks'
$Lane = Get-LoopLaneId -Repo $Repo

function Get-IntakeNow {
    $s = if ($Now) { $Now } else { [string]$env:GHOZTTY_INTAKE_NOW }
    if ($s) { return [datetime]::Parse($s, [Globalization.CultureInfo]::InvariantCulture) }
    return (Get-Date)
}

function Invoke-Git {
    $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        $out = @(& git -C $Repo @args 2>$null)
        return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
    } finally { $ErrorActionPreference = $eap }
}

function ConvertFrom-WatermarkText([string]$Text) {
    if (-not $Text) { return $null }
    try { return ($Text | ConvertFrom-Json) } catch { return $null }
}

# When the watermark says the last intake happened. Entries written before
# T2260 carry only a date; the intake then ran with the 05:00 morning block.
function Get-WatermarkAt($Wm) {
    if ($null -eq $Wm) { return $null }
    $inv = [Globalization.CultureInfo]::InvariantCulture
    if ($Wm.at) { try { return [datetime]::Parse([string]$Wm.at, $inv) } catch { } }
    if ($Wm.date) { try { return [datetime]::ParseExact([string]$Wm.date, 'yyyy-MM-dd', $inv).AddHours(5) } catch { } }
    return $null
}

# The watermark this check must honour: this tree's, or the branch on origin's
# when that one is newer (the other lane recorded and pushed, and this tree has
# not pulled yet).
function Get-Watermark {
    $local = $null
    if (Test-Path -LiteralPath $WatermarkPath) { $local = ConvertFrom-WatermarkText ([IO.File]::ReadAllText($WatermarkPath)) }
    $remote = $null
    if ($BranchRef) {
        $g = Invoke-Git show ("{0}:{1}" -f $BranchRef, $WatermarkRel)
        if ($g.Code -eq 0) { $remote = ConvertFrom-WatermarkText ($g.Out -join "`n") }
    }
    $la = Get-WatermarkAt $local; $ra = Get-WatermarkAt $remote
    $useRemote = $remote -and (-not $local -or ($ra -and $la -and $ra -gt $la))
    return [pscustomobject]@{
        Local = $local; Remote = $remote
        Effective = $(if ($useRemote) { $remote } else { $local })
        Source = $(if ($useRemote) { 'origin' } else { 'local' })
        RemoteNewer = [bool]$useRemote -and [bool]$local
    }
}

function Get-LeasePath {
    $dir = [string]$env:GHOZTTY_MACHINE_LOCK_DIR
    if (-not $dir) { $dir = Join-Path $env:LOCALAPPDATA 'ghoztty\machine-locks' }
    $leaf = 'GhozttyMainIntake'
    $scope = [string]$env:GHOZTTY_MACHINE_LOCK_SCOPE
    if ($scope) { $leaf += '-' + ($scope -replace '[^A-Za-z0-9_-]', '_') }
    return (Join-Path $dir ($leaf + '.lease.json'))
}

function Get-LeaseMutexName {
    $name = 'Global\GhozttyMainIntake'
    $scope = [string]$env:GHOZTTY_MACHINE_LOCK_SCOPE
    if ($scope) { $name += '-' + ($scope -replace '[^A-Za-z0-9_-]', '_') }
    return $name
}

# Run $Body with the lease file's mutex held: read-modify-write of the lease
# is atomic across lanes. The mutex is held for milliseconds, never a run.
function Invoke-UnderLeaseMutex([scriptblock]$Body) {
    $m = New-Object System.Threading.Mutex($false, (Get-LeaseMutexName))
    $got = $false
    try {
        try { $got = $m.WaitOne(15000) } catch [System.Threading.AbandonedMutexException] { $got = $true }
        if (-not $got) { throw "could not take $(Get-LeaseMutexName) within 15s" }
        return (& $Body)
    } finally {
        if ($got) { try { $m.ReleaseMutex() } catch { } }
        $m.Dispose()
    }
}

# The lease as it stands, or $null when there is none or it has expired.
function Read-Lease {
    $p = Get-LeasePath
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try { $l = [IO.File]::ReadAllText($p) | ConvertFrom-Json } catch { return $null }
    try {
        $exp = [datetime]::Parse([string]$l.expires, [Globalization.CultureInfo]::InvariantCulture)
        if ($exp -le (Get-IntakeNow)) { return $null }
    } catch { return $null }
    return $l
}

function Format-Lease($L) {
    return ("lane {0} ({1}) since {2}, expires {3}" -f $L.lane, $L.root, $L.at, $L.expires)
}

function Format-Age([double]$Minutes) {
    if ($Minutes -lt 0) { $Minutes = 0 }
    $h = [int][Math]::Floor($Minutes / 60); $m = [int][Math]::Round($Minutes - ($h * 60))
    if ($m -eq 60) { $h++; $m = 0 }
    if ($h -gt 0) { return ("{0}h {1:00}m" -f $h, $m) }
    return ("{0}m" -f $m)
}

# Committer times of the non-merge commits in a range, oldest first.
function Get-RangeCommits([string]$From, [string]$ToSha) {
    $g = Invoke-Git log --no-merges --reverse '--format=%h %cI' ("{0}..{1}" -f $From, $ToSha)
    if ($g.Code -ne 0) { return @() }
    return @($g.Out | Where-Object { $_ } | ForEach-Object {
            $parts = ([string]$_).Split(' ', 2)
            [pscustomobject]@{ Sha = $parts[0]; At = [datetimeoffset]::Parse($parts[1], [Globalization.CultureInfo]::InvariantCulture).LocalDateTime }
        })
}

# The whole due question, answered once for check/claim/status.
function Get-IntakeState([switch]$Fetch) {
    if ($Fetch -and -not $NoFetch -and $MainRef -like 'origin/*') {
        $null = Invoke-Git fetch --quiet origin
    }
    $clock = Get-IntakeNow
    $wm = Get-Watermark
    $s = [ordered]@{ State = 'unknown'; Line = ''; Watermark = $wm; From = $null; To = $null; Commits = @(); Total = 0; Lease = (Read-Lease) }
    if (-not $wm.Effective -or -not $wm.Effective.lastEvaluated) {
        $s.Line = "INTAKE UNKNOWN: $WatermarkRel has no lastEvaluated - nothing to measure main against"
        return [pscustomobject]$s
    }
    $from = [string]$wm.Effective.lastEvaluated
    $s.From = $from
    $g = Invoke-Git rev-parse --verify --quiet ($MainRef + '^{commit}')
    if ($g.Code -ne 0 -or -not $g.Out) {
        $s.Line = "INTAKE UNKNOWN: cannot resolve $MainRef (no fetch yet, no network?) - not due until it can be read"
        return [pscustomobject]$s
    }
    $to = ([string]$g.Out[0]).Substring(0, 9)
    $s.To = $to
    $cnt = Invoke-Git rev-list --count ("{0}..{1}" -f $from, $to)
    if ($cnt.Code -ne 0) {
        $s.Line = "INTAKE UNKNOWN: the watermark $from is not a commit this repo knows - fetch origin, or repair $WatermarkRel"
        return [pscustomobject]$s
    }
    $s.Total = [int]$cnt.Out[0]
    if ($s.Total -eq 0) {
        $s.State = 'not-moved'
        $s.Line = "INTAKE NOT DUE: $MainRef has not moved from $from (watermark from $($wm.Source))"
        return [pscustomobject]$s
    }
    $s.Commits = @(Get-RangeCommits $from $to)
    $oldest = if ($s.Commits.Count) { $s.Commits[0].At } else { $null }
    $waiting = if ($oldest) { ", the oldest waiting " + (Format-Age (($clock - $oldest).TotalMinutes)) } else { '' }
    $last = Get-WatermarkAt $wm.Effective
    $sinceMin = if ($last) { ($clock - $last).TotalMinutes } else { [double]::MaxValue }
    $moved = "$MainRef moved $($s.Total) commit(s) past $from ($($s.Commits.Count) non-merge$waiting)"
    if ($sinceMin -lt ($Hours * 60)) {
        $s.State = 'window'
        $dueAt = $last.AddHours($Hours).ToString('HH:mm')
        $s.Line = "INTAKE NOT DUE: $moved, but the last intake was $(Format-Age $sinceMin) ago - inside the $($Hours)h window, due at $dueAt"
        return [pscustomobject]$s
    }
    $ago = if ($last) { Format-Age $sinceMin } else { 'never' }
    if ($s.Lease -and [string]$s.Lease.lane -ne $Lane) {
        $s.State = 'busy'
        $s.Line = "INTAKE BUSY: $moved; lane $($s.Lease.lane) is running the intake ($(Format-Lease $s.Lease)) - not this lane's"
        return [pscustomobject]$s
    }
    $s.State = 'due'
    $s.Line = ("INTAKE DUE: $moved; last intake $ago ago. Run it before step 1 (go.md step 0.6 'Main intake'): " +
        "main-intake.ps1 claim, file the tasks, record, commit, release")
    return [pscustomobject]$s
}

function Write-Watermark($Obj) {
    $json = $Obj | ConvertTo-Json -Depth 6
    [IO.File]::WriteAllText($WatermarkPath, $json + "`n", (New-Object System.Text.UTF8Encoding($false)))
}

switch ($Command) {
    'check' {
        $s = Get-IntakeState -Fetch
        Write-Host $s.Line
        switch ($s.State) { 'due' { exit 3 } 'busy' { exit 4 } default { exit 0 } }
    }

    'status' {
        $s = Get-IntakeState
        Write-Host $s.Line
        $l = Read-Lease
        if ($l) { Write-Host "  lease: $(Format-Lease $l)" } else { Write-Host '  lease: free' }
        $runs = @($s.Watermark.Effective.runs | Where-Object { $_ } | Select-Object -First 3)
        foreach ($r in $runs) {
            Write-Host ("  run {0} lane {1}: {2}..{3}, {4} commit(s), tasks {5}, worst latency {6}" -f $r.at, $r.lane, $r.from, $r.to, $r.commits, (@($r.tasks) -join ','), (Format-Age ([double]$r.worstLatencyMinutes)))
        }
        exit 0
    }

    'claim' {
        $s = Get-IntakeState -Fetch
        if ($s.State -ne 'due' -and $s.State -ne 'busy' -and -not $Force) {
            Write-Host $s.Line
            Write-Host 'INTAKE NOT CLAIMED: nothing is due (-Force claims anyway)'
            exit 5
        }
        $clock = Get-IntakeNow
        $res = Invoke-UnderLeaseMutex {
            $cur = Read-Lease
            if ($cur -and [string]$cur.lane -ne $Lane) { return @{ Ok = $false; Lease = $cur } }
            $p = Get-LeasePath
            $dir = Split-Path $p -Parent
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            $rec = [ordered]@{
                lane = $Lane; root = $Repo; pid = $PID
                at = $clock.ToString('yyyy-MM-ddTHH:mm:ss'); expires = $clock.AddMinutes($LeaseMinutes).ToString('yyyy-MM-ddTHH:mm:ss')
                from = $s.From; to = $s.To
            }
            [IO.File]::WriteAllText($p, ($rec | ConvertTo-Json -Compress))
            return @{ Ok = $true; Lease = [pscustomobject]$rec }
        }
        if (-not $res.Ok) {
            Write-Host "INTAKE REFUSED: lane $($res.Lease.lane) holds the intake lease ($(Format-Lease $res.Lease)); one lane reads main at a time"
            exit 3
        }
        Write-Host ("INTAKE CLAIMED by lane {0} until {1}: evaluate {2}..{3} ({4} non-merge commit(s)), file the tasks, then record" -f $Lane, $res.Lease.expires, $s.From, $s.To, @($s.Commits).Count)
        exit 0
    }

    'release' {
        $msg = Invoke-UnderLeaseMutex {
            $p = Get-LeasePath
            $cur = $null
            if (Test-Path -LiteralPath $p) { try { $cur = [IO.File]::ReadAllText($p) | ConvertFrom-Json } catch { } }
            if (-not $cur) { return 'INTAKE RELEASED: no lease was held' }
            if ([string]$cur.lane -ne $Lane -and -not $Force) { return "intake lease not held by this lane (lane $($cur.lane) has it); -Force to clear it" }
            Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
            return "INTAKE RELEASED by lane $Lane"
        }
        Write-Host $msg
        exit 0
    }

    'record' {
        $clock = Get-IntakeNow
        $l = Read-Lease
        if (-not $l -or [string]$l.lane -ne $Lane) {
            $who = if ($l) { "lane $($l.lane) holds it" } else { 'nobody holds it' }
            Write-Host "INTAKE RECORD REFUSED: this lane ($Lane) does not hold the intake lease ($who) - run main-intake.ps1 claim first"
            exit 1
        }
        $wm = Get-Watermark
        if ($wm.RemoteNewer) {
            Write-Host "INTAKE RECORD REFUSED: $BranchRef carries a newer watermark ($($wm.Remote.lastEvaluated) at $($wm.Remote.at)) than this tree - git pull --rebase first, so the two lanes' watermark commits cannot conflict"
            exit 1
        }
        $cur = $wm.Local
        if (-not $cur -or -not $cur.lastEvaluated) { Write-Host "INTAKE RECORD REFUSED: $WatermarkRel has no lastEvaluated"; exit 1 }
        $from = [string]$cur.lastEvaluated
        $target = if ($To) { $To } elseif ($l.to) { [string]$l.to } else { $MainRef }
        $g = Invoke-Git rev-parse --verify --quiet ($target + '^{commit}')
        if ($g.Code -ne 0 -or -not $g.Out) { Write-Host "INTAKE RECORD REFUSED: '$target' is not a commit"; exit 1 }
        $toSha = ([string]$g.Out[0]).Substring(0, 9)
        $anc = Invoke-Git merge-base --is-ancestor $from $toSha
        if ($anc.Code -ne 0) { Write-Host "INTAKE RECORD REFUSED: $toSha does not descend from the watermark $from - the range would skip or rewind"; exit 1 }
        $commits = @(Get-RangeCommits $from $toSha)
        $taskIds = @($Tasks | ForEach-Object { ([string]$_).Split(',') } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $missing = @($taskIds | Where-Object { -not (Test-Path -LiteralPath (Join-Path $TasksDir "$_.md")) })
        if ($missing.Count) { Write-Host "INTAKE RECORD REFUSED: no task file for $($missing -join ', ')"; exit 1 }
        if ($commits.Count -gt 0 -and -not $NoMergeTask) {
            if (-not $MergeTask) {
                Write-Host (("INTAKE RECORD REFUSED: MERGE TASK REQUIRED - {0} Mac commit(s) were evaluated, and the code merge has to follow within the day: " +
                    "file or refresh the 'merge origin/main' task at P1 and pass -MergeTask <id> (or -NoMergeTask -Reason '<why none is owed>')") -f $commits.Count)
                exit 1
            }
            $mf = Join-Path $TasksDir "$MergeTask.md"
            if (-not (Test-Path -LiteralPath $mf)) { Write-Host "INTAKE RECORD REFUSED: no task file for merge task $MergeTask"; exit 1 }
            $mt = [IO.File]::ReadAllText($mf)
            if ($mt -match '(?m)^status:\s*"?(done|skipped)') { Write-Host "INTAKE RECORD REFUSED: merge task $MergeTask is already closed - file a fresh one for $from..$toSha"; exit 1 }
            if ($mt -notmatch '(?m)^priority:\s*"?P[01]"?\s*$') { Write-Host "INTAKE RECORD REFUSED: merge task $MergeTask must be P1 or higher so the merge follows the same day (set-priority $MergeTask -Priority P1)"; exit 1 }
        }
        if ($NoMergeTask -and $commits.Count -gt 0 -and -not $Reason) { Write-Host 'INTAKE RECORD REFUSED: -NoMergeTask needs -Reason'; exit 1 }
        $worst = 0.0
        if ($commits.Count) { $worst = [Math]::Round(($clock - $commits[0].At).TotalMinutes, 1) }
        $run = [ordered]@{
            at = $clock.ToString('yyyy-MM-ddTHH:mm:ss'); lane = $Lane; from = $from; to = $toSha
            commits = $commits.Count; tasks = $taskIds; mergeTask = $(if ($MergeTask) { $MergeTask } else { $null })
            worstLatencyMinutes = $worst
        }
        $runs = @($run) + @($cur.runs | Where-Object { $_ } | Select-Object -First 59)
        $text = if ($Note) { $Note } else { "origin/main moved $from -> $toSha ($($commits.Count) non-merge commit(s)); $($taskIds.Count) task(s) filed" }
        if ($NoMergeTask -and $Reason) { $text += " No merge task: $Reason" }
        $entry = "{0} intake (lane {1}): {2}" -f $clock.ToString('yyyy-MM-dd HH:mm'), $Lane, $text
        $out = [ordered]@{
            lastEvaluated = $toSha
            date = $clock.ToString('yyyy-MM-dd')
            at = $clock.ToString('yyyy-MM-ddTHH:mm:ss')
            runs = $runs
            note = $(if ($cur.note) { $entry + ' || ' + [string]$cur.note } else { $entry })
        }
        Write-Watermark $out
        Write-Host ("INTAKE RECORDED: watermark {0} -> {1}, {2} commit(s), worst latency {3}. Commit {4} with the filed tasks, then main-intake.ps1 release" -f $from, $toSha, $commits.Count, (Format-Age $worst), ($WatermarkRel -replace '/', '\'))
        exit 0
    }

    'day' {
        $d = if ($Date) { $Date } else { (Get-IntakeNow).ToString('yyyy-MM-dd') }
        $wm = Get-Watermark
        $runs = @($wm.Effective.runs | Where-Object { $_ -and ([string]$_.at).StartsWith($d) })
        if (-not $runs.Count) {
            Write-Host "INTAKES $($d): none recorded (main did not move past the watermark, or nobody ran one)"
            exit 0
        }
        $commits = 0; $taskCount = 0; $worst = 0.0
        foreach ($r in $runs) {
            $commits += [int]$r.commits; $taskCount += @($r.tasks).Count
            if ([double]$r.worstLatencyMinutes -gt $worst) { $worst = [double]$r.worstLatencyMinutes }
        }
        Write-Host ("INTAKES {0}: {1} run(s), {2} commit(s) evaluated, {3} task(s) filed, worst latency {4} (Mac commit -> filed)" -f $d, $runs.Count, $commits, $taskCount, (Format-Age $worst))
        exit 0
    }
}
