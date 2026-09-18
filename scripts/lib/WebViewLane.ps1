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

  * WHOSE RUN a lane host belongs to (T1649). Both markers above are shared by
    every concurrent run of the same lane -- the profile PREFIX is a constant
    and the exe name is the same `ghostty-test.exe` -- so a soak round ending
    its lane killed the browser processes a turn's win32 lane was using right
    then. That is T1648's cross-kill on a second resource, and the separator is
    the same one: a host belongs to the run whose BUILD ROOT its owning test
    binary was launched from. `Get-WebViewHostOwnerPid` reads that owner off the
    profile folder (or, for an exe-name-only match, off the creator), and
    `Split-WebViewHostByOwner` applies `Test-PathUnderRoot` to its image.

  Nothing here ever touches a WebView2 process that is not a test lane's: the
  user's own Ghoztty runs its viewer panes out of the same exe, and a sweep
  that took those would close the panes they are reading this in.
#>

# Test-PathUnderRoot / Get-LaneBuildRoot: ownership by build root is one rule,
# written once, for test binaries (T1648) and for the browser processes they own
# (T1649). Nothing in LaneLeak.ps1 runs at load.
. "$PSScriptRoot\LaneLeak.ps1"

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

function Get-WebViewHostOwnerPid {
    <#
    .SYNOPSIS
        The pid of the TEST BINARY a lane's WebView2 host belongs to, or 0 when
        nothing on the process says.
    .DESCRIPTION
        The private profile a test binary mints carries that binary's own pid in
        the folder name -- `ghoztty-wv2test-<pid>`, minted by
        `webview2.TestProfile` -- and every process in the browser tree inherits
        the folder on its command line, children included. So the profile is an
        ownership RECORD rather than a mere marker, and it survives the tree
        being reparented, which is what makes it usable after the fact.

        A host matched only by `--webview-exe-name=` carries no profile, and
        then the creator is the best answer available: the WebView2 loader
        launches the browser process from the embedder, so the parent pid is the
        test binary until that binary exits.
    .OUTPUTS
        [int] the owning pid, or 0.
    #>
    param([string]$CommandLine, [int]$ParentProcessId = 0)

    if ($CommandLine -and $CommandLine -match "$script:WEBVIEW_LANE_PROFILE_PREFIX(\d+)") {
        return [int]$matches[1]
    }
    if ($ParentProcessId -gt 0) { return [int]$ParentProcessId }
    return 0
}

function Split-WebViewHostByOwner {
    <#
    .SYNOPSIS
        Split lane WebView2 hosts into the ones THIS run owns and the ones
        another concurrent run does (T1649).
    .DESCRIPTION
        `Get-WebViewLaneHost` answers "is this a test lane's browser process?",
        and that was the only question anyone asked until the idle soak daemon
        (T841) started running lanes alongside a turn on purpose. Both of its
        markers are shared by every concurrent run, so the end-of-lane sweep --
        which KILLS what it finds -- reached the browser processes the other
        run's tests were driving, and that run went red for somebody else's
        cleanup. Same failure as T1648, same remedy: identity is where the
        owning test binary was BUILT.

        A host is this run's when its owner is: the owner's image lives under
        one of this run's roots. An owner that is GONE is nobody's live process
        -- a true orphan, which is exactly what the sweep exists to reap -- so
        it stays ours. An owner that is alive but whose image cannot be read is
        left alone, the same conservative call `Split-LaneLeakByRoot` makes.
    .PARAMETER Roots
        This run's build roots (`Get-LaneBuildRoot`). EMPTY means no scoping is
        possible and nothing is dropped: a caller that cannot say where it built
        must not be silently disarmed.
    .OUTPUTS
        Mine / Foreign, each an array of the host objects passed in.
    #>
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()]$Hosts,
        [string[]]$Roots = @()
    )

    $all = @(@($Hosts) | Where-Object { $null -ne $_ })
    $scoped = @(@($Roots) | Where-Object { $_ })
    if ($scoped.Count -eq 0) {
        return [pscustomobject]@{ Mine = $all; Foreign = @() }
    }

    # One CIM lookup per distinct owner: a browser tree is a dozen processes
    # sharing one owner, and the sweep runs at every lane boundary.
    $imageOf = @{}
    $mine = @()
    $foreign = @()
    foreach ($h in $all) {
        $ownerPid = Get-WebViewHostOwnerPid -CommandLine ([string]$h.CommandLine) `
            -ParentProcessId ([int]$h.ParentProcessId)
        if ($ownerPid -le 0) { $mine += $h; continue }
        if (-not $imageOf.ContainsKey($ownerPid)) {
            $owner = Get-CimInstance Win32_Process -Filter "ProcessId=$ownerPid" -ErrorAction SilentlyContinue
            $image = $null
            if ($owner) { $image = [string]$owner.ExecutablePath }
            $imageOf[$ownerPid] = $image
        }
        $image = $imageOf[$ownerPid]
        # Owner gone: an orphan belongs to no live run, and reaping it is the
        # whole point of the sweep.
        if ($null -eq $image) { $mine += $h; continue }
        if (Test-PathUnderRoot -Path $image -Roots $scoped) { $mine += $h }
        else { $foreign += $h }
    }
    return [pscustomobject]@{ Mine = $mine; Foreign = $foreign }
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
    .PARAMETER Roots
        This run's build roots (T1649). When given, only hosts owned by a test
        binary built under one of them are counted -- so a concurrent run's live
        browser tree neither holds this lane at the gate for the full deadline
        nor gets reported as an unsettled teardown that never was one.
    .OUTPUTS
        [pscustomobject] Settled (bool), WaitedMs (int), Remaining (int),
        RemainingApp (int).
    #>
    param(
        [string[]]$ExeNames,
        [int]$TimeoutSeconds = 20,
        [int]$PollMs = 250,
        [switch]$IncludeAppTeardown,
        [string[]]$Roots = @()
    )

    $count = {
        $lane = @((Split-WebViewHostByOwner -Hosts (Get-WebViewLaneHost -ExeNames $ExeNames) `
                    -Roots $Roots).Mine).Count
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
        And it only ever kills THIS run's hosts (T1649). Both identity markers
        are shared by every concurrent run, so without `-Roots` a soak round
        ending its lane takes down the browser processes a turn's lane is
        driving right now -- a red lane that is somebody else's cleanup, which
        is the whole T1648 story on a second resource.
    .PARAMETER Roots
        This run's build roots (`Get-LaneBuildRoot`). Empty means no scoping,
        which is the pre-T1649 behavior for a caller that cannot say where it
        built.
    .OUTPUTS
        [pscustomobject] Killed (int), Settled (bool), WaitedMs (int),
        Remaining (int), ProfilesRemoved (int), Foreign (the hosts left alone
        because another run owns them).
    #>
    param(
        [string[]]$ExeNames,
        [int]$TimeoutSeconds = 20,
        [switch]$NoKill,
        [string[]]$Roots = @()
    )

    $split = Split-WebViewHostByOwner -Hosts (Get-WebViewLaneHost -ExeNames $ExeNames) -Roots $Roots
    $hosts = @($split.Mine)
    if (-not $NoKill) {
        foreach ($h in $hosts) {
            try { Stop-Process -Id $h.ProcessId -Force -ErrorAction Stop } catch {}
        }
    }

    $settle = Wait-WebViewLaneSettle -ExeNames $ExeNames -TimeoutSeconds $TimeoutSeconds -Roots $Roots
    $profiles = Remove-WebViewLaneProfile

    return [pscustomobject]@{
        Killed          = [int]$hosts.Count
        Settled         = $settle.Settled
        WaitedMs        = $settle.WaitedMs
        Remaining       = $settle.Remaining
        ProfilesRemoved = $profiles
        Foreign         = @($split.Foreign)
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
