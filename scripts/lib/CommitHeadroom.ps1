<#
.SYNOPSIS
    System-commit headroom accounting for the floor lanes (T453).

.DESCRIPTION
    Windows hands out memory against the COMMIT LIMIT -- physical RAM plus the
    page file -- and when that runs out `VirtualAlloc` starts returning null.
    C++ code that does not check every allocation then dereferences it, which
    is why T449's `zig.exe` access violations were chased as a commit problem
    in the first place (one fault was at address 0x10, the textbook
    `nullptr->field`).

    T449 measured the box and cleared commit as the cause of that crash --
    `zig build test-agent` peaked at 49.4 GB against a 67.7 GB limit, 18 GB of
    headroom at the worst moment -- and T453 was filed for the margin itself
    rather than the crash. The two numbers that matter come out of that
    measurement and are what the defaults below encode:

    - the BASELINE on this box is high before anything builds (~33.5 GB at
      idle, of which one `msedge.exe` held 12.2 GB), and
    - a single lane draws about **16 GB** on top of it.

    So a lane launched with less than a lane's worth of commit free cannot
    finish, and it will not say so: it dies somewhere in the middle in a
    compiler crash that reads exactly like broken code. That is the same class
    of fault as T1054's full disk and T243's cross-drive cache -- when the
    ENVIRONMENT is the fault, the run has to say so instead of relaying a
    message about something else -- and it gets the same treatment: a cheap
    question asked before the first lane launches.

    Deliberately NOT symmetric with the disk gate in one respect: the disk gate
    refuses, and this one mostly WARNS. Free commit is a whole-machine number
    that a browser can move by 12 GB while the check is running, so a hard
    refusal keyed on it would wedge the loop for a reason that had already gone
    away by the time anyone read it. The refusal floor is therefore set where a
    lane is not merely at risk but cannot complete at all.

.NOTES
    Functions only; no side effects at load. `Get-CommitHeadroomState` is pure
    (numbers in, verdict out) so the acceptance harness can drive every band
    without staging a memory-starved box; `Get-SystemCommit` is the one
    function that touches the machine.
#>

# Measured by T449 on this box, 3 runs of `zig build test-agent`: peak commit
# 49.4 / 41.8 / 41.8 GB against a ~33.5 GB idle baseline. The floor runs its
# lanes sequentially, so one lane's draw is the number a preflight needs.
$script:COMMIT_LANE_DRAW_GB = 16

function Get-SystemCommit {
    <#
        Committed bytes and the commit limit, as gigabytes. Returns $null when
        the counters cannot be read (a locale-renamed counter set, a stripped
        container image) -- an unreadable number is not the same as a bad one,
        and the caller must not turn it into a verdict.
    #>
    param()
    try {
        $committed = (Get-Counter '\Memory\Committed Bytes' -ErrorAction Stop).CounterSamples[0].CookedValue
        $limit = (Get-Counter '\Memory\Commit Limit' -ErrorAction Stop).CounterSamples[0].CookedValue
        if (-not $limit) { return $null }
        return [pscustomobject]@{
            CommittedGB = [math]::Round($committed / 1GB, 1)
            LimitGB     = [math]::Round($limit / 1GB, 1)
        }
    }
    catch { return $null }
}

function Get-PageFileGB {
    <#
        Total allocated page file across every volume, in GB, or $null when it
        cannot be read. Reported rather than gated on: the page file is a
        machine setting on the user's box (T453's Notes), so the loop measures
        it and says what it found, and the click stays theirs.
    #>
    param()
    try {
        $pf = @(Get-CimInstance Win32_PageFileUsage -ErrorAction Stop)
        if (-not $pf.Count) { return 0 }
        return [math]::Round((($pf | Measure-Object -Property AllocatedBaseSize -Sum).Sum) / 1024, 1)
    }
    catch { return $null }
}

function Get-CommitHeadroomState {
    <#
        Pure: the verdict for a given commit reading.

        -FailFreeGB  below this, a lane cannot complete -- refuse to launch.
        -WarnFreeGB  below this, a lane may not fit beside whatever else is
                     running -- say so and launch anyway.

        Verdict is one of 'ok', 'warn', 'fail', or 'unknown' when the reading
        itself is missing. 'unknown' NEVER refuses: a gate that cannot measure
        must not pretend it measured (the T1133 rule, from the other side).
    #>
    param(
        [Nullable[double]]$CommittedGB,
        [Nullable[double]]$LimitGB,
        [double]$FailFreeGB = 8,
        [double]$WarnFreeGB = 24
    )

    if ($null -eq $CommittedGB -or $null -eq $LimitGB -or $LimitGB -le 0) {
        return [pscustomobject]@{
            Verdict = 'unknown'
            FreeGB  = $null
            UsedPct = $null
            Reason  = 'system commit counters could not be read'
        }
    }

    $free = [math]::Round($LimitGB - $CommittedGB, 1)
    $pct = [math]::Round(100 * $CommittedGB / $LimitGB, 0)

    $verdict = 'ok'
    $reason = "$free GB of commit free ($pct% of the $LimitGB GB limit in use)"
    if ($free -lt $FailFreeGB) {
        $verdict = 'fail'
        $reason = "only $free GB of commit free ($pct% of the $LimitGB GB limit in use) - a lane draws about $script:COMMIT_LANE_DRAW_GB GB and cannot complete"
    }
    elseif ($free -lt $WarnFreeGB) {
        $verdict = 'warn'
        $reason = "$free GB of commit free ($pct% of the $LimitGB GB limit in use) - close to the ~$script:COMMIT_LANE_DRAW_GB GB a lane draws"
    }

    return [pscustomobject]@{
        Verdict = $verdict
        FreeGB  = $free
        UsedPct = $pct
        Reason  = $reason
    }
}

function Get-TopCommitters {
    <#
        The processes holding the most commit (private bytes), largest first,
        as "name pid N.N GB" strings. Named, never acted on: the committers are
        the user's applications, and closing one is their call (T1459).
    #>
    param([int]$Top = 3)
    try {
        return @(Get-Process -ErrorAction Stop |
            Sort-Object PrivateMemorySize64 -Descending |
            Select-Object -First $Top |
            ForEach-Object { '{0} (pid {1}) {2:N1} GB' -f $_.ProcessName, $_.Id, ($_.PrivateMemorySize64 / 1GB) })
    }
    catch { return @() }
}

function Wait-CommitHeadroom {
    <#
        Bounded wait for commit headroom to come back (T1459).

        Free commit is a whole-machine number another process moves by tens of
        GB: on 2026-09-08 the preflight refused at 1.6 GB free while a user
        application held 88 GB, and two minutes later 29 GB was free and every
        lane passed. So a 'fail' reading is a reason to WAIT, saying what is
        held and by whom, and only an expired wait is a refusal.

        -Read   scriptblock returning the state object Get-CommitHeadroomState
                returns (the floor passes the live reading; the harness passes
                a scripted sequence).
        -Sleep  scriptblock taking seconds (the harness passes a no-op).
        -Note   scriptblock taking one line to print.

        Returns { Verdict = 'ok'|'warn'|'unknown'|'fail'; State; WaitedSeconds;
        Polls }. 'fail' only when the budget ran out with the reading still
        under the floor. A reading that turns 'unknown' mid-wait ends the wait
        as 'unknown' -- an unreadable number never refuses (T1133).
    #>
    param(
        [Parameter(Mandatory)][scriptblock]$Read,
        [int]$MaxWaitSeconds = 600,
        [int]$PollSeconds = 15,
        [scriptblock]$Sleep = { param($s) Start-Sleep -Seconds $s },
        [scriptblock]$Note = { param($l) Write-Host $l },
        [scriptblock]$Committers = { Get-TopCommitters }
    )
    if ($PollSeconds -lt 1) { $PollSeconds = 1 }
    $state = & $Read
    $waited = 0
    $polls = 1
    if ($state.Verdict -ne 'fail' -or $MaxWaitSeconds -le 0) {
        return [pscustomobject]@{ Verdict = $state.Verdict; State = $state; WaitedSeconds = 0; Polls = $polls }
    }
    $held = @(& $Committers)
    & $Note "COMMIT WAIT: $($state.Reason)"
    & $Note "  waiting up to $MaxWaitSeconds s for the headroom to come back (polling every $PollSeconds s); nothing will be closed"
    if ($held.Count) { & $Note "  largest committers: $($held -join ', ')" }
    $lastReport = 0
    while ($waited -lt $MaxWaitSeconds) {
        $step = [math]::Min($PollSeconds, $MaxWaitSeconds - $waited)
        & $Sleep $step
        $waited += $step
        $state = & $Read
        $polls++
        if ($state.Verdict -ne 'fail') {
            & $Note "COMMIT WAIT OVER after $waited s: $($state.Reason)"
            return [pscustomobject]@{ Verdict = $state.Verdict; State = $state; WaitedSeconds = $waited; Polls = $polls }
        }
        if ($waited - $lastReport -ge 60) {
            $lastReport = $waited
            & $Note "  still waiting ($waited of $MaxWaitSeconds s): $($state.FreeGB) GB free"
        }
    }
    return [pscustomobject]@{ Verdict = 'fail'; State = $state; WaitedSeconds = $waited; Polls = $polls }
}

function Get-CommitHeadroomAdvice {
    <#
        The remedy lines printed under a warn or a fail. Kept beside the
        verdict so the harness can assert that a refusal always names a way
        out -- T1054's disk gate is the precedent: the message that refuses is
        also the message that fixes it.
    #>
    param([string]$Verdict, [Nullable[double]]$PageFileGB, [Nullable[double]]$LimitGB)
    $lines = @()
    if ($Verdict -eq 'ok' -or $Verdict -eq 'unknown') { return $lines }
    $lines += 'close the largest committers (a browser here has held 12 GB) and re-run'
    if ($null -ne $PageFileGB -and $null -ne $LimitGB -and $PageFileGB -lt ($LimitGB * 0.25)) {
        $lines += "the page file is $PageFileGB GB - a bigger one turns commit pressure into paging instead of allocation failures (System > About > Advanced system settings > Performance)"
    }
    $lines += 'measure a command''s own peak with: powershell -NoProfile -File scripts\commit-pressure-probe.ps1 -Command "<cmd>"'
    return $lines
}
