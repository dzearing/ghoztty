<#
.SYNOPSIS
  Acceptance test for the task dashboard server + page (T505).

.DESCRIPTION
  Starts scripts\task-dashboard.js on a private port and asserts the HTTP
  surface the page depends on, from outside, the way the page consumes it:

    - the served page carries the T505 event-L2 wiring (openEvent dialog,
      whole-card hover, the /api/commit fetch) and its inline script parses;
    - /api/data answers with an activity feed whose work items carry the sha
      the page hands to /api/commit, and carries every priority band the CLI
      knows, in queue order (T345 - the payload keeps its own copy of that
      closed set, so a band it has not learned is invisible on the charts);
    - /api/commit returns the FULL commit message for a real sha (oracle:
      git show -s on the same sha), and refuses a malformed or unknown sha
      with 400/404 rather than resolving whatever it was handed;
    - the pre-existing /api/task surface still answers, as the regression
      control;
    - a loop blocked by something only the user can clear reaches the payload
      with its reason and reset time (T1484), and a record belonging to a turn
      the loop has since completed does NOT - a stale "blocked" over a working
      loop being worse than none at all.

  The server is started on a port this script verified free first, because the
  server treats EADDRINUSE as "already serving" and exits 0 - a leftover
  server from an older tree would then be the thing under test. The page
  marker assertions double as the identity check: a stale server cannot serve
  the new page.

  No GUI, no desktop, no ghoztty processes - node + HTTP only.

  Prints a single verdict line via Write-TestVerdict, like every other script
  here. ASCII-only by design (PS 5.1 on this box mangles non-ASCII on
  rewrite).
#>
[CmdletBinding()]
param(
    [int]$Port = 0
)

$ErrorActionPreference = 'Stop'
$Repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:pass = 0
$script:fail = 0
$script:skipped = 0
function Assert([string]$label, [bool]$cond, [string]$detail = '') {
    if ($cond) { $script:pass++; Write-Host "  PASS $label" }
    else {
        $script:fail++
        Write-Host "  FAIL $label$(if ($detail) { ' -- ' + $detail })"
    }
}

$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) {
    Write-TestAssertedNothing -Reason 'node is not installed on this box, so the dashboard server cannot run'
}

$dash = Join-Path $Repo 'scripts\task-dashboard.js'
$page = Join-Path $Repo 'scripts\task-dashboard.page.html'

# --- pick a port that is verifiably FREE ------------------------------------
# The server's EADDRINUSE branch exits 0 with "(already serving)", so starting
# it on a busy port silently tests whatever old server holds it.
function Test-PortFree([int]$p) {
    $l = $null
    try {
        $l = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, $p)
        $l.Start()
        return $true
    } catch { return $false }
    finally { if ($l) { $l.Stop() } }
}
if ($Port -eq 0) {
    foreach ($p in 7841..7860) { if (Test-PortFree $p) { $Port = $p; break } }
}
if ($Port -eq 0) {
    Write-TestAssertedNothing -Reason 'no free port in 7841-7860, so a fresh server cannot be started'
}
$Base = "http://127.0.0.1:$Port"

# --- HTTP helper: status + body, no throw on 4xx ----------------------------
function Get-Http([string]$url, [int]$timeoutSec = 30) {
    try {
        $r = Invoke-WebRequest -UseBasicParsing -Uri $url -TimeoutSec $timeoutSec
        return [pscustomobject]@{ Status = [int]$r.StatusCode; Body = [string]$r.Content }
    } catch [System.Net.WebException] {
        $resp = $_.Exception.Response
        if ($null -eq $resp) { return [pscustomobject]@{ Status = -1; Body = $_.Exception.Message } }
        $sr = New-Object System.IO.StreamReader ($resp.GetResponseStream())
        $body = $sr.ReadToEnd(); $sr.Close()
        return [pscustomobject]@{ Status = [int]$resp.StatusCode; Body = $body }
    }
}

Write-Host "task-dashboard acceptance (T505) on port $Port"
$srv = Start-Process -FilePath $node.Source -ArgumentList ('"' + $dash + '" --port ' + $Port) `
    -WorkingDirectory $Repo -WindowStyle Hidden -PassThru
try {
    # --- readiness ----------------------------------------------------------
    $up = $false
    foreach ($i in 1..60) {
        $r = Get-Http "$Base/" 5
        if ($r.Status -eq 200) { $up = $true; break }
        Start-Sleep -Milliseconds 500
    }
    Assert 'server answers GET / within 30s' $up
    if (-not $up) { throw 'ABORT: server never came up; nothing else can be measured' }
    $html = (Get-Http "$Base/").Body

    # --- section A: the page ships the event L2 (T505) ----------------------
    Assert 'A1 page defines the openEvent dialog' ($html -match 'function openEvent\(')
    Assert 'A2 page fetches /api/commit for the full message' ($html -match '/api/commit\?sha=')
    Assert 'A3 timeline cards have a whole-card hover state' ($html -match '\.ev:hover')
    Assert 'A4 timeline cards are keyboard-openable' ($html -match "openEvent\(a\)")

    # The inline script must PARSE - a syntax error takes the whole dashboard
    # down to a blank page while the server keeps answering 200.
    $m = [regex]::Match($html, '(?s)<script>(.*?)</script>')
    Assert 'A5 page has one inline script' $m.Success
    if ($m.Success) {
        $tmp = Join-Path $env:TEMP "task-dashboard-page-$PID.js"
        [System.IO.File]::WriteAllText($tmp, $m.Groups[1].Value)
        & $node.Source --check $tmp 2>&1 | Out-Null
        Assert 'A6 the inline page script parses (node --check)' ($LASTEXITCODE -eq 0)
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }

    # --- section B: /api/data carries what the cards need -------------------
    $data = $null
    $r = Get-Http "$Base/api/data" 120
    Assert 'B1 /api/data answers 200' ($r.Status -eq 200) "got $($r.Status)"
    try { $data = $r.Body | ConvertFrom-Json } catch {}
    Assert 'B2 /api/data is JSON with an activity feed' ($null -ne $data -and $null -ne $data.activity)
    $work = @($data.activity | Where-Object { $_.kind -eq 'work' })
    Assert 'B3 the feed has at least one work event' ($work.Count -ge 1) "got $($work.Count)"
    Assert 'B4 work events carry the sha the L2 fetch needs' `
        ($work.Count -ge 1 -and $work[0].sha -match '^[0-9a-f]{7,40}$') "got '$(if ($work.Count) { $work[0].sha })'"

    # The priority bands are the queue's own vocabulary, and the dashboard keeps
    # a SECOND copy of the closed set (here, and again in the page's PRI_LABEL /
    # priRank). A band the CLI knows and this payload does not is invisible on
    # the charts: that is exactly how `P3` hid in two real task files until T345
    # went looking. Assert the set, and assert its order, since "reviewed and
    # deliberately last" must still rank ahead of "nobody has looked yet".
    $bands = @($data.priorities | ForEach-Object { $_.priority })
    Assert 'B5 the payload carries every priority band, untriaged last' `
        (($bands -join ',') -eq 'P0,P1,P2,P3,untriaged') "got '$($bands -join ',')'"

    # --- section C: /api/commit, both directions ----------------------------
    # C4 proves the endpoint serves the WHOLE message, not just the subject, so
    # it needs a commit that actually has a body. It used to take HEAD blindly
    # and went red whenever the newest commit was a one-liner - which the loop's
    # own `chore(tracker): ...` commits routinely are (ae4ba7b5b, 2026-08-17).
    # A red that depends on what someone last committed is not evidence about
    # the endpoint, so pick the newest commit with a body and say so when there
    # is none rather than failing an assertion nothing in the code can satisfy.
    $head = (& git -C $Repo rev-parse --short=9 HEAD).Trim()
    foreach ($cand in (& git -C $Repo log -40 --format=%h)) {
        $cand = $cand.Trim()
        if (-not $cand) { continue }
        if ((& git -C $Repo show -s --format=%b $cand) -join "`n" -match '\S') {
            $head = (& git -C $Repo rev-parse --short=9 $cand).Trim()
            break
        }
    }
    $subject = (& git -C $Repo show -s --format=%s $head).Trim()
    $r = Get-Http "$Base/api/commit?sha=$head"
    Assert 'C1 a real sha answers 200' ($r.Status -eq 200) "got $($r.Status)"
    $j = $null
    try { $j = $r.Body | ConvertFrom-Json } catch {}
    Assert 'C2 the answer echoes the sha' ($null -ne $j -and $j.sha -eq $head)
    $firstLine = if ($null -ne $j -and $j.body) { ($j.body -split "`n")[0].Trim() } else { '' }
    Assert 'C3 the body is the full message (first line = git subject)' ($firstLine -eq $subject) `
        "got '$firstLine' want '$subject'"
    $bodyText = (& git -C $Repo show -s --format=%b $head) -join "`n"
    if ($bodyText -match '\S') {
        Assert 'C4 the body reaches past the first paragraph' `
            ($null -ne $j -and $j.body.Length -gt $firstLine.Length)
    }
    else {
        "  SKIP C4: no commit with a body in the last 40 - nothing to prove the full-message path against"
        $script:skipped++
    }

    if ($work.Count -ge 1 -and $work[0].sha) {
        $r = Get-Http "$Base/api/commit?sha=$($work[0].sha)"
        $j = $null
        try { $j = $r.Body | ConvertFrom-Json } catch {}
        Assert 'C5 the sha exactly as the feed ships it resolves' `
            ($r.Status -eq 200 -and $null -ne $j -and $j.body.Length -gt 0) "got $($r.Status)"
    } else {
        Write-Host 'SKIP  C5: no work event in the feed to take a sha from'
        $script:skipped++
    }

    $r = Get-Http "$Base/api/commit?sha=zzz"
    Assert 'C6 a non-hex sha is refused with 400' ($r.Status -eq 400) "got $($r.Status)"
    $r = Get-Http "$Base/api/commit?sha=..%2F..%2Fsecret"
    Assert 'C7 a traversal-shaped sha is refused with 400' ($r.Status -eq 400) "got $($r.Status)"
    $r = Get-Http "$Base/api/commit?sha=$('deadbeef' * 5)"
    Assert 'C8 an unknown-but-valid-hex sha answers 404' ($r.Status -eq 404) "got $($r.Status)"
    $r = Get-Http "$Base/api/commit"
    Assert 'C9 a missing sha is refused with 400' ($r.Status -eq 400) "got $($r.Status)"

    # --- section D: the pre-existing surface still answers ------------------
    $r = Get-Http "$Base/api/task?id=T505"
    $j = $null
    try { $j = $r.Body | ConvertFrom-Json } catch {}
    Assert 'D1 /api/task still serves a task body' `
        ($r.Status -eq 200 -and $null -ne $j -and $j.body -match '## Summary') "got $($r.Status)"

    # --- section E: the click path, in a real browser -----------------------
    # ?selftest=event makes the page itself click the first timeline card,
    # require the event dialog + a loaded commit message, and close it again,
    # writing the verdict into the DOM - which --dump-dom can read. An HTTP
    # probe cannot see a click path; this can.
    $edge = @(
        "$env:ProgramFiles (x86)\Microsoft\Edge\Application\msedge.exe",
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($edge) {
        $dom = Join-Path $env:TEMP "task-dashboard-selftest-$PID.html"
        & cmd /c "`"$edge`" --headless=new --disable-gpu --hide-scrollbars --virtual-time-budget=20000 --dump-dom `"$Base/?selftest=event`" > `"$dom`" 2>nul"
        $domText = if (Test-Path $dom) { [System.IO.File]::ReadAllText($dom) } else { '' }
        $verdictLine = ([regex]::Match($domText, 'T505-SELFTEST [^<]*')).Value
        Assert 'E1 the in-browser click path passes' ($verdictLine -eq 'T505-SELFTEST PASS') `
            "got '$verdictLine'"
        Remove-Item $dom -Force -ErrorAction SilentlyContinue
    } else {
        Write-Host 'SKIP  E1: Edge is not installed on this box'
        $script:skipped++
    }

    # --- section F: the blocked loop the payload has to report (T1484) ------
    # A loop stopped by something only the user can clear - a spend limit - is
    # what the page's top bar exists for, and "blocked" is a state no harness
    # can wait for on a live box. So the two files the answer is derived from
    # are staged: the loop lock, and the watchdog state the supervisor stamps
    # its classification into. `--loop` prints exactly that half of the
    # payload, so all three cases cost milliseconds instead of a history walk.
    #
    # The third case is the one that matters most. The bar clearing itself is
    # not a timer: the watchdog records the TURN it was looking at, and a turn
    # that has since completed makes the record history. A stale "blocked" over
    # a working loop is worse than no bar at all, so it is measured here rather
    # than assumed.
    $fix = Join-Path $env:TEMP "dashboard-loop-$PID"
    New-Item -ItemType Directory -Force -Path $fix | Out-Null
    try {
        $lockFile = Join-Path $fix 'lock.json'
        $wdFile   = Join-Path $fix 'watchdog.json'
        # A live pid, so the payload reads the loop as running without shelling
        # out to the real lock for a second opinion.
        @{ state = 'held'; pane_id = 'FIXTURE'; claude_pid = $PID; turn = 12
           turn_started = '2026-09-09T13:00:00.0000000-07:00'
           acquired = '2026-09-09T13:00:00.0000000-07:00'
           heartbeat = (Get-Date).ToString('o') } |
            ConvertTo-Json | Out-File -FilePath $lockFile -Encoding utf8
        function Write-WdFixture($turnKey, $blocked) {
            @{ watchdog_pid = $PID; tick_at = (Get-Date).ToString('o'); poll_seconds = 300
               last_tick = 'nudge'; recovery_turn_key = $turnKey; recovery_ineffective = 180
               recovery_blocked = $blocked; recovery_blocked_kind = 'usage-limit'
               recovery_blocked_why = "You've hit your monthly spend limit"
               recovery_blocked_resets_at = '2026-09-12 01:00' } |
                ConvertTo-Json | Out-File -FilePath $wdFile -Encoding utf8
        }
        function Get-LoopJson {
            $env:GHOZTTY_LOOP_LOCK = $lockFile
            $env:GHOZTTY_WATCHDOG_STATE = $wdFile
            try { $out = & $node.Source $dash --loop 2>$null } finally {
                Remove-Item Env:GHOZTTY_LOOP_LOCK, Env:GHOZTTY_WATCHDOG_STATE -ErrorAction SilentlyContinue
            }
            try { return ($out -join "`n" | ConvertFrom-Json) } catch { return $null }
        }

        Write-WdFixture 'started=2026-09-09T13:00:00.0000000-07:00' $true
        $j = Get-LoopJson
        Assert 'F1 a blocked loop reaches the payload' `
            ($null -ne $j -and $null -ne $j.loop -and $null -ne $j.loop.blocked) `
            "loop=$($j.loop | ConvertTo-Json -Compress)"
        Assert 'F2 it carries the reason and when it clears, not just a flag' `
            ($null -ne $j.loop.blocked -and $j.loop.blocked.kind -eq 'usage-limit' -and
             $j.loop.blocked.why -match 'monthly spend limit' -and
             $j.loop.blocked.resetsAt -eq '2026-09-12 01:00') `
            "$($j.loop.blocked | ConvertTo-Json -Compress)"

        # The freshness rule: the same record, against a loop that has since
        # completed that turn.
        Write-WdFixture 'started=2026-09-08T09:00:00.0000000-07:00' $true
        $j = Get-LoopJson
        Assert 'F3 a block recorded against an older turn is history, not news' `
            ($null -ne $j -and $null -ne $j.loop -and $null -eq $j.loop.blocked) `
            "$($j.loop.blocked | ConvertTo-Json -Compress)"

        # And the plain negative control: the supervisor looked and found no
        # blocker.
        Write-WdFixture 'started=2026-09-09T13:00:00.0000000-07:00' $false
        $j = Get-LoopJson
        Assert 'F4 a loop the supervisor found unblocked reports nothing' `
            ($null -ne $j -and $null -ne $j.loop -and $null -eq $j.loop.blocked) `
            "$($j.loop.blocked | ConvertTo-Json -Compress)"
    } finally {
        Remove-Item $fix -Recurse -Force -ErrorAction SilentlyContinue
    }
} catch {
    # An abort mid-suite (server died, JSON refused to parse where an Assert
    # did not guard it) must still end in the one verdict line, red - not in a
    # PowerShell error with no verdict and whatever exit code falls out.
    $script:fail++
    Write-Host "  FAIL suite aborted: $($_.Exception.Message)"
} finally {
    if ($srv -and -not $srv.HasExited) { Stop-Process -Id $srv.Id -Force -ErrorAction SilentlyContinue }
}

# --- stamp (T783) -----------------------------------------------------------
# A clean green run records the covered files so scripts\guard-due.ps1 can
# answer "has anyone run this harness against the code as it now stands?".
# Red or skipped runs leave the stamp alone - red must stay due.
Complete-TestBody  # T1039: before the stamp, which is a child process reading this run's state
if ($script:fail -eq 0) {
    if ($script:skipped -gt 0) {
        "  stamp NOT updated: $($script:skipped) section(s) skipped, so this run did not cover the whole harness"
    } else {
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
            update -Guard task-dashboard -Repo $Repo 2>&1 | ForEach-Object { "  $_" }
    }
}

Write-TestVerdict -Label 'T505 TASK DASHBOARD' -Pass $script:pass -Fail $script:fail -Skipped $script:skipped
