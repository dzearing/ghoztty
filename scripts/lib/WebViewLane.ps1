<#
.SYNOPSIS
  The WebView2 browser processes a test lane leaves behind, and waiting for
  them to actually be gone before the next lane asks for an environment (T592).

.DESCRIPTION
  Two of the four floor lanes (win32 and agent) stand up a REAL WebView2
  environment, and `floor-lane.ps1 -Lane all` starts the next lane the instant
  the previous one exits. Three times between 2026-08-08 and 2026-08-09 that
  produced a red floor that was not red code: the incoming lane asked for an
  environment while the outgoing lane's browser tree was still tearing down,
  got `hr=0x80004005`, and the host-floor test reported it as a failure. Each
  occurrence cost a turn, and -- worse -- taught the loop to re-run a red gate
  instead of reading it.

  What this file owns is the identity question and the wait:

  * WHICH msedgewebview2.exe processes belong to a test lane. They live under
    Program Files, so a path filter on zig-out or zig-cache never sees them.
    Two markers name them, and BOTH are needed: `--webview-exe-name=<test exe>`
    is on the browser process the test binary created, and
    `--user-data-dir=...\ghoztty-wv2test-<pid>` is on that browser AND on every
    renderer/GPU/utility child it spawned. Matching only the first counted the
    tree as one process, which is how a sweep could report "0 leaked hosts"
    while several children were still holding the profile open.

  * WAITING for them to be gone. `Stop-Process` returns before the process
    dies, and a lane that starts on that return is racing the same teardown
    the kill was meant to end.

  * The OTHER thing a lane can start into (T678): an acceptance script's viewer
    panes. `test\win32\*.ps1` launch a repo-built debug Ghoztty, open viewer
    panes in it and kill it at the end, and that browser tree carries neither
    test marker -- so the wait above reported "nothing to settle" in precisely
    the back-to-back case it exists for. `Get-WebViewAppDebugHost` names it by
    the DEBUG profile folder, which a release install never uses.

  Nothing here ever touches a WebView2 process that is not a test lane's: the
  user's own Ghoztty runs its viewer panes out of the same exe, and a sweep
  that took those would close the panes they are reading this in.
#>

# Profile directories `webview2.TestProfile` mints, one per test-binary pid.
# The name is the contract between the Zig side and this file.
$script:WEBVIEW_LANE_PROFILE_PREFIX = 'ghoztty-wv2test-'

# The profile a DEBUG ghoztty uses for its viewer panes -- the build every
# acceptance script in test\win32 launches, and the one a lane can find still
# tearing down when it starts (T678). A release install uses the same path
# WITHOUT `-debug`, so this marker can never match the user's own terminal.
$script:WEBVIEW_APP_DEBUG_PROFILE_MARKER = '\ghoztty\EBWebView-debug'

function Get-WebViewLaneHost {
    <#
    .SYNOPSIS
        Every live msedgewebview2.exe process belonging to a test lane.
    .PARAMETER ExeNames
        Test binary names (e.g. ghostty-test.exe) whose browser processes count.
    .OUTPUTS
        Zero or more Win32_Process instances. Wrap the call in @().
    #>
    param([string[]]$ExeNames)

    $found = @()
    $all = Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -ErrorAction SilentlyContinue
    foreach ($h in $all) {
        $cl = $h.CommandLine
        if (-not $cl) { continue }
        # The children carry the profile but not the embedder's exe name, so
        # the profile marker is checked first: it is the one that matches the
        # whole tree.
        if ($cl -like "*$script:WEBVIEW_LANE_PROFILE_PREFIX*") { $found += $h; continue }
        foreach ($n in @($ExeNames)) {
            if ($n -and $cl -like "*--webview-exe-name=$n*") { $found += $h; break }
        }
    }
    return $found
}

function Get-WebViewAppDebugHost {
    <#
    .SYNOPSIS
        Every live msedgewebview2.exe process belonging to a DEBUG ghoztty --
        an acceptance run's viewer panes (T678).
    .DESCRIPTION
        The lane's own settle only ever knew about test-binary browser trees, so
        the shape it was built for -- an acceptance script, then a lane, back to
        back -- was exactly the one it could not see: `viewer-panes.ps1` stands
        up seventeen of these against a repo build and kills it at the end, and
        every one of them carries the app's profile rather than either test
        marker.

        Identity is the DEBUG profile folder and nothing else. A release install
        uses the same path WITHOUT `-debug`, so the user's own terminal -- whose
        viewer panes run out of the same exe -- can never be matched here,
        waited for, or (elsewhere in this file) killed. That exclusion is the
        rule; everything else about this function is a wait.

        It deliberately does NOT try to tell a tearing-down app from a healthy
        one. That refinement was written first and measurement threw it out: an
        acceptance script's app and its whole browser tree disappear inside a
        single 250ms sample (kill-on-close job objects take the tree with the
        app), so "orphaned" is a state that is essentially never observed, and a
        wait keyed on it would have been a no-op wearing a fix's clothes. What
        is left is honest: if a debug browser tree is up when a lane starts, the
        lane waits for it, bounded, and SAYS so if it runs out -- which also
        names the one case that legitimately costs the deadline, a dev Ghoztty
        somebody left open.
    .OUTPUTS
        Zero or more Win32_Process instances. Wrap the call in @().
    #>
    param()

    return @(Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine -like "*$script:WEBVIEW_APP_DEBUG_PROFILE_MARKER*" })
}

function Wait-WebViewLaneSettle {
    <#
    .SYNOPSIS
        Block until no test-lane WebView2 process remains, or the deadline.
    .DESCRIPTION
        Returns rather than throws on a deadline: a lane that starts anyway is
        the behavior we have today, and the caller's job is to SAY that it did
        so the next red result can be read against it.
    .PARAMETER IncludeAppTeardown
        Also wait for a DEBUG-ghoztty browser tree (T678) -- an acceptance
        script's viewer panes, on their way down or still up. This is for the
        wait a lane does BEFORE it starts; the end-of-lane sweep stays strictly
        about the lane's own leaks, because it KILLS what it finds.
    .OUTPUTS
        [pscustomobject] Settled (bool), WaitedMs (int), Remaining (int),
        RemainingApp (int).
    #>
    param(
        [string[]]$ExeNames,
        [int]$TimeoutSeconds = 20,
        [int]$PollMs = 250,
        [switch]$IncludeAppTeardown
    )

    $count = {
        $lane = @(Get-WebViewLaneHost -ExeNames $ExeNames).Count
        $app = if ($IncludeAppTeardown) { @(Get-WebViewAppDebugHost).Count } else { 0 }
        [pscustomobject]@{ Lane = $lane; App = $app; Total = $lane + $app }
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $deadlineMs = [math]::Max(0, $TimeoutSeconds) * 1000
    $remaining = & $count
    while ($remaining.Total -gt 0 -and $sw.ElapsedMilliseconds -lt $deadlineMs) {
        Start-Sleep -Milliseconds ([math]::Max(10, $PollMs))
        $remaining = & $count
    }
    $sw.Stop()
    return [pscustomobject]@{
        Settled      = ($remaining.Total -eq 0)
        WaitedMs     = [int]$sw.ElapsedMilliseconds
        Remaining    = [int]$remaining.Total
        RemainingApp = [int]$remaining.App
    }
}

function Remove-WebViewLaneProfile {
    <#
    .SYNOPSIS
        Delete the private profile directories of test binaries that are gone.
    .DESCRIPTION
        A test cannot delete its own: the browser process outlives it and holds
        the files open. Only a directory whose owning pid is gone is removed,
        so a concurrent run's profile is never pulled out from under it.
    .OUTPUTS
        [int] directories removed.
    #>
    param([string]$Root = $env:TEMP)

    $removed = 0
    $dirs = Get-ChildItem $Root -Directory -Filter "$script:WEBVIEW_LANE_PROFILE_PREFIX*" -ErrorAction SilentlyContinue
    foreach ($d in @($dirs)) {
        $ownerPid = 0
        if ($d.Name -match "^$script:WEBVIEW_LANE_PROFILE_PREFIX(\d+)$") { $ownerPid = [int]$matches[1] }
        if ($ownerPid -and (Get-Process -Id $ownerPid -ErrorAction SilentlyContinue)) { continue }
        try {
            Remove-Item $d.FullName -Recurse -Force -ErrorAction Stop
            $removed++
        }
        catch {}
    }
    return $removed
}

function Invoke-WebViewLaneSweep {
    <#
    .SYNOPSIS
        Kill a lane's leaked WebView2 processes, WAIT for them to exit, then
        remove the profile directories they were holding.
    .DESCRIPTION
        The order is the whole point. Killing and immediately deleting was the
        old shape, and it lost both halves on a loaded box: the delete failed
        because the browser still had the files open, and the next lane started
        while the tree was still unwinding.
    .OUTPUTS
        [pscustomobject] Killed (int), Settled (bool), WaitedMs (int),
        Remaining (int), ProfilesRemoved (int).
    #>
    param(
        [string[]]$ExeNames,
        [int]$TimeoutSeconds = 20,
        [switch]$NoKill
    )

    $hosts = @(Get-WebViewLaneHost -ExeNames $ExeNames)
    if (-not $NoKill) {
        foreach ($h in $hosts) {
            try { Stop-Process -Id $h.ProcessId -Force -ErrorAction Stop } catch {}
        }
    }

    $settle = Wait-WebViewLaneSettle -ExeNames $ExeNames -TimeoutSeconds $TimeoutSeconds
    $profiles = Remove-WebViewLaneProfile

    return [pscustomobject]@{
        Killed          = [int]$hosts.Count
        Settled         = $settle.Settled
        WaitedMs        = $settle.WaitedMs
        Remaining       = $settle.Remaining
        ProfilesRemoved = $profiles
    }
}

function Format-WebViewSettle {
    <#
    .SYNOPSIS
        The one line a lane prints about its settle, or '' when there was
        nothing to say.
    .DESCRIPTION
        Silence is the normal case and it has to stay silent, or the signal
        drowns: a settle that waited nothing gets no line at all. A settle that
        WAITED says how long, and one that gave up says so in the words a
        reader needs when the lane behind it goes red.
    #>
    param(
        [Parameter(Mandatory)]$Settle,
        [string]$Lane = ''
    )
    $where = if ($Lane) { "LANE $Lane " } else { '' }
    $app = 0
    if ($null -ne $Settle.PSObject.Properties['RemainingApp']) { $app = [int]$Settle.RemainingApp }
    if (-not $Settle.Settled) {
        $whose = if ($app -gt 0) { "$app of them an acceptance run's viewer panes (T678)" } else { 'T592' }
        return ("${where}WEBVIEW NOT SETTLED: $($Settle.Remaining) browser process(es) still up after " +
            "$([int]($Settle.WaitedMs / 1000))s - a WebView2 failure in this lane may be that teardown, not this code ($whose)")
    }
    if ($Settle.WaitedMs -ge 500) {
        return "${where}waited $($Settle.WaitedMs)ms for the previous lane's WebView2 processes to exit"
    }
    return ''
}
