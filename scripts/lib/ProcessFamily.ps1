# T1867: walk and kill a process's descendants without adopting strangers.
#
# Windows recycles pids and never rewrites a process's ParentProcessId, so a
# walk keyed on the parent pid alone adopts any long-lived process whose real
# parent died before one of OUR processes was handed that pid. T1840 found the
# user's own Spotify inside a floor lane's tree that way; in a READ path that
# is a false red, in a KILL path it is the user's app force-killed. Both soak
# scripts' tree-kill had exactly that walk, so it lives here once.
#
# The rule (the same one floor-lane.ps1 Get-ProcessTree applies): a child is
# adopted only if it is no older than the member it names, and -- when a
# member's pid is now held by a DIFFERENT, later-born process -- only if it
# was born before that impostor, since anything younger is the impostor's.
# A missing CreationDate on either side keeps the old answer (adopt), so a
# snapshot without dates degrades to the pid-only walk rather than to no walk.
#
#   Get-ProcessFamily  -RootPid -Snapshot [-Known]   pure: the descendants
#   Stop-ProcessFamily -Id [-Snapshot] [-Kill]       root first, then them
#
# Acceptance: test\win32\process-family.ps1.

function Get-ProcessFamily {
    <#
        Every descendant of $RootPid in $Snapshot (Win32_Process rows carrying
        ProcessId, ParentProcessId and CreationDate), root excluded.

        $Known maps pid -> CreationDate for members recorded EARLIER (the
        root's birth, captured before it was killed, and members found by a
        previous pass that may be dead now). It is updated in place, so a
        caller that passes the same table across passes keeps reaching the
        orphans of a member that has already died. A known member's recorded
        birth wins over whatever now holds its pid.

        Plain return, callers wrap in @() (T982).
    #>
    param([int]$RootPid, $Snapshot, [hashtable]$Known = @{})

    $byPid = @{}
    $byParent = @{}
    foreach ($p in @($Snapshot)) {
        if ($null -eq $p) { continue }
        $byPid[[int]$p.ProcessId] = $p
        $key = [int]$p.ParentProcessId
        if (-not $byParent.ContainsKey($key)) { $byParent[$key] = New-Object System.Collections.ArrayList }
        $null = $byParent[$key].Add($p)
    }
    if (-not $Known.ContainsKey($RootPid)) {
        $Known[$RootPid] = $null
        if ($byPid.ContainsKey($RootPid)) { $Known[$RootPid] = $byPid[$RootPid].CreationDate }
    }

    $out = New-Object System.Collections.ArrayList
    $seen = @{ $RootPid = $true }      # emitted (or the root)
    $walked = @{}                      # already expanded
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue($RootPid)
    # Members known from earlier passes are walked too: their orphans still
    # name them, and the root's own entry alone would not reach a grandchild
    # whose parent died in the previous pass.
    foreach ($k in @($Known.Keys)) { $queue.Enqueue([int]$k) }
    while ($queue.Count -gt 0) {
        $cur = [int]$queue.Dequeue()
        if ($walked.ContainsKey($cur)) { continue }
        $walked[$cur] = $true
        if (-not $byParent.ContainsKey($cur)) { continue }
        $born = $Known[$cur]
        # A later-born process now holding this member's pid is an impostor;
        # its children are its own.
        $usurped = $null
        if ($null -ne $born -and $byPid.ContainsKey($cur)) {
            $now = $byPid[$cur].CreationDate
            if ($null -ne $now -and [datetime]$now -gt [datetime]$born) { $usurped = [datetime]$now }
        }
        foreach ($c in $byParent[$cur]) {
            $cpid = [int]$c.ProcessId
            if ($seen.ContainsKey($cpid)) { continue }
            $cBorn = $c.CreationDate
            if ($null -ne $cBorn) {
                if ($null -ne $born -and [datetime]$cBorn -lt [datetime]$born) { continue }
                if ($null -ne $usurped -and [datetime]$cBorn -ge $usurped) { continue }
            }
            $seen[$cpid] = $true
            if (-not $Known.ContainsKey($cpid)) { $Known[$cpid] = $cBorn }
            $null = $out.Add($c)
            $queue.Enqueue($cpid)
        }
    }
    return $out
}

function Stop-ProcessFamily {
    <#
        Kill $Id and every descendant, ROOT FIRST (T858: a root that outlives
        its children respawns into the teardown). After the root dies its
        children keep naming it, so a fresh snapshot per pass still finds them;
        its birth is captured BEFORE the kill so the walk can tell them from a
        stranger. The root is never re-killed by pid -- the pid may already be
        somebody else's -- unless the snapshot shows the SAME process still
        alive.

        -Snapshot and -Kill are seams for the harness: synthetic rows in, the
        pids that would have been killed out. Returns the pids it killed.
    #>
    param(
        [int]$Id,
        [scriptblock]$Snapshot = { @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue) },
        [scriptblock]$Kill = { param([int]$KillPid) Stop-Process -Id $KillPid -Force -ErrorAction SilentlyContinue },
        [int]$Passes = 4,
        [int]$PauseMs = 300
    )
    $killed = New-Object System.Collections.ArrayList
    $known = @{}
    $snap = @()
    try { $snap = @(& $Snapshot) } catch {}
    $rootRow = @($snap | Where-Object { $null -ne $_ -and [int]$_.ProcessId -eq $Id })
    $known[$Id] = $null
    if ($rootRow.Count -gt 0) { $known[$Id] = $rootRow[0].CreationDate }

    try { & $Kill $Id } catch {}
    $null = $killed.Add($Id)

    for ($pass = 0; $pass -lt $Passes; $pass++) {
        $snap = @()
        try { $snap = @(& $Snapshot) } catch {}
        $alive = New-Object System.Collections.ArrayList
        foreach ($m in @(Get-ProcessFamily -RootPid $Id -Snapshot $snap -Known $known)) {
            if ([int]$m.ProcessId -ne $PID) { $null = $alive.Add([int]$m.ProcessId) }
        }
        # The root, only if it is provably the same process (a failed kill).
        $again = @($snap | Where-Object { $null -ne $_ -and [int]$_.ProcessId -eq $Id })
        if ($again.Count -gt 0 -and $null -ne $known[$Id] -and $null -ne $again[0].CreationDate -and
            ([datetime]$again[0].CreationDate -eq [datetime]$known[$Id])) {
            $null = $alive.Add($Id)
        }
        if ($alive.Count -eq 0) { break }
        foreach ($k in $alive) {
            try { & $Kill $k } catch {}
            $null = $killed.Add($k)
        }
        if ($PauseMs -gt 0) { Start-Sleep -Milliseconds $PauseMs }
    }
    return $killed
}
