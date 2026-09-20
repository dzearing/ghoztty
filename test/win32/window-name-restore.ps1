# T121 acceptance: auto `window-N` target names stay UNIQUE across a session
# restore.
#
#   powershell -NoProfile -File test\win32\window-name-restore.ps1
#
# Every window without an explicit `--target=` gets an auto name from an
# in-memory counter that restarts at zero on every app launch - while session
# restore re-adopts the names its PREVIOUS run minted. Restore `window-1..3`,
# open three fresh windows, and pre-fix the fresh ones mint `window-1..3`
# again: two live windows holding one target name, with `+close`/`+rename`
# routed to whichever registered first. That is destructive, not cosmetic - a
# `+close --target=window-3` closes somebody else's work.
#
# What is asserted:
#
#   A (capture)  three auto-named windows exist and the manifest records their
#                names, so the collision is actually set up. This is the
#                fixture's own control: if A is red, C proves nothing.
#   B (restore)  killing the app and relaunching brings the same three names
#                back - the adopted names the allocator must reserve.
#   C (the fix)  three FRESH windows opened after the restore carry names
#                nobody else holds: every `target` in `+list` is distinct, and
#                none of the restored names moved to a different window.
#   D (routing)  `+close --target=window-3` closes THE window that holds
#                window-3 and no other - checked by pane id, not by counting.
#   E (T896)     a manifest that ALREADY holds the same name twice - what
#                T590's carry-forward can merge out of two app runs - restores
#                both windows: the incumbent keeps the name, the loser takes a
#                deterministic fallback that `+list` reports, `--target=`
#                routes to, and the next sync re-records.
#   F (T896)     the other shape of the same symptom: a manifest entry whose
#                `ipc_name` is present but EMPTY mints a name rather than
#                leaving the window with a blank `target` nothing can reach.
#
# Hermetic: per-run LOCALAPPDATA, per-run agent binary override, a private IPC
# pipe suffix, and it only ever kills ghoztty processes launched from this
# repo's zig-out. Runs on the BACKGROUND test desktop, so it never takes the
# user's foreground.
param(
    [string]$ExePath,
    [string]$AgentExe,
    [switch]$Interactive
)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }
$agent = Join-Path $repo 'zig-out\bin\ghoztty-agent.exe'
if ($AgentExe) { $agent = $AgentExe }

$script:pass = 0
$script:fail = 0
$root = Join-Path $env:TEMP "ghoztty-window-name-restore-$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
# T652: the "attached is not alive" oracle. Read its header before adding an
# assertion about a restored pane.
. (Join-Path $PSScriptRoot 'lib\PaneLiveness.ps1')
# T350: refuse a non-debug zig-out before anything is launched. This script
# opens and CLOSES windows by auto name; against the user's endpoints that is
# their terminal it would be closing.
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
Assert-GhozttyIsolatedBuild -Exe $exe

# Write-Host, not the pipeline: a helper that asserts must never also return a
# value, or its return silently becomes an array (T217 batch 5).
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}
function Say($m) { Write-Host $m }

function Stop-RepoInstances {
    # T351: one shared, path-exact kill (lib\CleanSlate.ps1) instead of a private
    # copy - the filter this replaced also matched a detached instance running from
    # zig-out-release (T53b), and every copy answered "does the agent go too" alone.
    [void](Stop-RepoGhoztty -Exe $exe -SettleMs 700)
}

# Kill ONLY the app: the detached agent keeps its PTYs, which is the scenario
# (quit / crash / upgrade, then re-attach).
function Stop-AppOnly {
    # T351: one shared, path-exact kill (lib\CleanSlate.ps1) instead of a private
    # copy - the filter this replaced also matched a detached instance running from
    # zig-out-release (T53b), and every copy answered "does the agent go too" alone.
    [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 900)
}

# A PIPE, not a `>` redirect: `ghoztty +verb > file` from PowerShell writes zero
# bytes (T245).
function Invoke-Verb([string[]]$VerbArgs) {
    $out = (& $exe @VerbArgs 2>&1 | ForEach-Object { $_.ToString() } | Out-String)
    return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
}

function Get-Windows {
    $json = (& $exe +list --json 2>$null | Out-String).Trim()
    if (-not $json) { return @() }
    try { $doc = $json | ConvertFrom-Json } catch { return @() }
    if (-not $doc.data) { return @() }
    return @($doc.data.windows)
}

function Get-Targets {
    return @(Get-Windows | ForEach-Object { [string]$_.target } | Where-Object { $_ })
}

# The first pane id of a window, so "which window" is a stable identity rather
# than a position in the list.
function Get-FirstPaneId($w) {
    function Walk($node) {
        if (-not $node) { return $null }
        if ($node.type -eq 'leaf') { return [string]$node.terminal.id }
        $l = Walk $node.left
        if ($l) { return $l }
        return Walk $node.right
    }
    foreach ($t in @($w.tabs)) {
        $id = Walk $t.splits
        if ($id) { return $id }
    }
    return $null
}

# The same identity, read out of a MANIFEST window instead of a live one: the
# first leaf of tab 0, walking left at every split. Restore re-adopts a
# recorded pane id, so this is how a doctored entry is recognised afterwards.
function Get-ManifestFirstPane($w) {
    $tab = @($w.tabs)[0]
    if (-not $tab) { return $null }
    $nodes = @($tab.nodes)
    $i = 0
    for ($guard = 0; $guard -le $nodes.Count; $guard++) {
        if ($i -lt 0 -or $i -ge $nodes.Count) { return $null }
        $n = $nodes[$i]
        if ($n.leaf) { return [string]$n.leaf.pane_id }
        if (-not $n.split) { return $null }
        $i = [int]$n.split.left
    }
    return $null
}

function Get-PaneIdOf($target) {
    foreach ($w in Get-Windows) {
        if ([string]$w.target -eq $target) { return Get-FirstPaneId $w }
    }
    return $null
}

# Wait for the window list to STOP growing, not merely to reach a number: a
# restore brings windows back over seconds, and a launch can also adopt
# agent-held sessions the local manifest never listed. A count-threshold wait
# samples mid-restore and answers a different question every run.
function Wait-WindowsSettle($min, $timeoutSec = 60) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $last = -1
    $stable = 0
    while ((Get-Date) -lt $deadline) {
        $n = @(Get-Windows).Count
        if ($n -eq $last) { $stable++ } else { $stable = 0; $last = $n }
        if ($n -ge $min -and $stable -ge 3) { break }
        Start-Sleep -Milliseconds 500
    }
    return @(Get-Windows)
}

function Wait-WindowCount($count, $timeoutSec = 45) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $t = @(Get-Targets)
        if ($t.Count -ge $count) { return $t }
        Start-Sleep -Milliseconds 400
    }
    return @(Get-Targets)
}

function Manifest-Path($tmp) { return (Join-Path $tmp 'ghoztty\session-layout-debug.json') }

function Wait-Manifest($tmp, $pred, $timeoutSec = 25) {
    $p = Manifest-Path $tmp
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $p) {
            $m = $null
            try { $m = Get-Content $p -Raw | ConvertFrom-Json } catch { $m = $null }
            if ($null -ne $m) { if (& $pred $m) { return $m } }
        }
        Start-Sleep -Milliseconds 400
    }
    return $null
}

# Names that appear more than once. The whole defect, in one list.
function Get-Duplicates($names) {
    $seen = @{}
    $dupes = @()
    foreach ($n in @($names)) {
        if ($seen.ContainsKey($n)) { $dupes += @($n) } else { $seen[$n] = $true }
    }
    return @($dupes)
}

$restored = @('window-1', 'window-2', 'window-3')

$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN
$savedPipe = $env:GHOZTTY_PIPE_SUFFIX
$env:GHOZTTY_PIPE_SUFFIX = "-wnrestore$PID"

Stop-RepoInstances
New-Item -ItemType Directory -Force $root | Out-Null
$tmp = Join-Path $root 'app'
New-Item -ItemType Directory -Force (Join-Path $tmp 'ghoztty\local-agent-debug') | Out-Null
$env:LOCALAPPDATA = $tmp
$env:GHOSTTY_LOCAL_AGENT_BIN = $agent

Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    Assert (Test-Path $exe) "ghoztty exe exists in zig-out"
    Assert (Test-Path $agent) "ghoztty-agent exe exists in zig-out"

    # persistence: on (default) - the relaunch below has to RESTORE what this launch left.
    $app = Start-OnTestDesktop -Exe $exe
    if ((Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow') -eq [IntPtr]::Zero) {
        Say 'SETUP FAIL: no GhozttyWindow'; exit 1
    }

    # ---- A: three auto-named windows, recorded in the manifest --------------
    Say '== A: capture'
    # The startup window is window-1; two more bare `+new-window`s mint 2 and 3.
    for ($i = 0; $i -lt 2; $i++) {
        $r = Invoke-Verb @('+new-window')
        Assert ($r.Code -eq 0) "A0 bare +new-window exits 0 (got $($r.Code))"
    }
    $pre = @(Wait-WindowCount 3)
    $missing = @($restored | Where-Object { $pre -notcontains $_ })
    Assert ($missing.Count -eq 0) `
        "A1 the three auto names are live pre-quit (missing: $($missing -join ', '); got $($pre -join ', '))"
    Assert (@(Get-Duplicates $pre).Count -eq 0) `
        "A2 no duplicate target name before the restore (dupes: $((Get-Duplicates $pre) -join ', '))"

    $m = Wait-Manifest $tmp {
        param($mm)
        $names = @(@($mm.windows) | ForEach-Object { [string]$_.ipc_name })
        @($restored | Where-Object { $names -notcontains $_ }).Count -eq 0
    }
    Assert ($null -ne $m) 'A3 the manifest recorded all three auto names'

    # ---- B: they come back under the same names ----------------------------
    Say '== B: restore'
    Stop-AppOnly
    $env:LOCALAPPDATA = $tmp
    $env:GHOSTTY_LOCAL_AGENT_BIN = $agent
    # persistence: on (default) - this is the restore under test.
    $relaunched = Start-OnTestDesktop -Exe $exe
    if ((Wait-TestWindow -ProcessId $relaunched.Pid -Class 'GhozttyWindow') -eq [IntPtr]::Zero) {
        Say 'SETUP FAIL: relaunched app has no GhozttyWindow'
    }
    $post = @(Wait-WindowCount 3 60)
    $stillMissing = @($restored | Where-Object { $post -notcontains $_ })
    Assert ($stillMissing.Count -eq 0) `
        "B1 the restored windows kept their names (missing: $($stillMissing -join ', '); got $($post -join ', '))"
    Assert (@(Get-Duplicates $post).Count -eq 0) `
        "B2 the restore itself minted no duplicate (dupes: $((Get-Duplicates $post) -join ', '))"

    # Identities to check routing against, captured BEFORE anything new opens.
    $idOf = @{}
    foreach ($n in $restored) { $idOf[$n] = Get-PaneIdOf $n }
    Assert (@($restored | Where-Object { $idOf[$_] }).Count -eq 3) `
        'B3 each restored window resolves to a pane id'

    # B4 (T652): ATTACHED IS NOT ALIVE. Everything above is app-side
    # bookkeeping - a name in `+list` and a pane id in a tree are equally true
    # of a pane that came back as a frozen picture. Type into one restored
    # window and require new output, so the names C and D route by belong to
    # panes that still work. One is enough here: all three restore by the same
    # path, and this script's subject is the name allocator, not the attach.
    Assert (Test-PaneLive -Exe $exe -Target 'window-1' -Tmp $root -Tag 'WNR') `
        'B4 a restored window is LIVE: input reaches its child and output returns'

    # ---- C: fresh windows cannot re-mint an adopted name -------------------
    Say '== C: fresh windows after the restore'
    $before = @(Get-Targets).Count
    for ($i = 0; $i -lt 3; $i++) {
        $r = Invoke-Verb @('+new-window')
        Assert ($r.Code -eq 0) "C0 bare +new-window after restore exits 0 (got $($r.Code))"
    }
    $all = @(Wait-WindowCount ($before + 3) 45)
    Assert ($all.Count -eq $before + 3) `
        "C1 three more windows opened (expected $($before + 3), got $($all.Count))"
    $dupes = @(Get-Duplicates $all)
    Assert ($dupes.Count -eq 0) `
        "C2 every window still has a target name nobody else holds (dupes: $($dupes -join ', '); all: $($all -join ', '))"
    $moved = @($restored | Where-Object { (Get-PaneIdOf $_) -ne $idOf[$_] })
    Assert ($moved.Count -eq 0) `
        "C3 no restored name now resolves to a different window (moved: $($moved -join ', '))"

    # ---- D: +close routes to the window you meant --------------------------
    Say '== D: routing'
    $victim = $idOf['window-3']
    $survivors = @(Get-Windows | ForEach-Object { Get-FirstPaneId $_ } |
        Where-Object { $_ -and $_ -ne $victim })
    $r = Invoke-Verb @('+close', '--target=window-3')
    Assert ($r.Code -eq 0) "D0 +close --target=window-3 exits 0 (got $($r.Code))"
    $deadline = (Get-Date).AddSeconds(30)
    $live = @()
    while ((Get-Date) -lt $deadline) {
        $live = @(Get-Windows | ForEach-Object { Get-FirstPaneId $_ } | Where-Object { $_ })
        if ($live -notcontains $victim) { break }
        Start-Sleep -Milliseconds 400
    }
    Assert ($live -notcontains $victim) 'D1 the window that held window-3 is gone'
    $collateral = @($survivors | Where-Object { $live -notcontains $_ })
    Assert ($collateral.Count -eq 0) `
        "D2 no other window was closed (lost $($collateral.Count) of $($survivors.Count))"
    Assert ((Get-Targets) -notcontains 'window-3') 'D3 window-3 no longer names any live window'

    # ---- E: a manifest that already holds a DUPLICATE name (T896) ----------
    # T590's carry-forward can merge entries written by two different app runs
    # into one manifest, and each run's auto allocator starts at zero - so the
    # file can legitimately record `window-1` twice. Restore must still give
    # every window a target: the incumbent keeps the name and the loser takes a
    # deterministic fallback, rather than coming back nameless and unreachable.
    Say '== E: duplicate names in the manifest'
    Stop-AppOnly
    $mpath = Manifest-Path $tmp
    $doc = $null
    try { $doc = Get-Content $mpath -Raw | ConvertFrom-Json } catch { $doc = $null }
    if ($null -eq $doc) {
        Assert $false 'E0 the manifest is readable before doctoring it'
    } else {
        # Two windows, both recording the same auto name - the exact shape the
        # carry-forward produces. Trimmed to two so the assertions below are
        # about the collision and nothing else.
        $keep = @(@($doc.windows) | Select-Object -First 2)
        foreach ($w in $keep) { $w.ipc_name = 'window-1'; $w.id = 'window-1' }
        $doc.windows = $keep
        # No `Set-Content -Encoding utf8`: PowerShell 5.1 writes a BOM, and the
        # manifest reader is a JSON parser that would reject the file outright -
        # a doctored fixture that never loads proves nothing.
        [System.IO.File]::WriteAllText(
            $mpath,
            ($doc | ConvertTo-Json -Depth 40),
            (New-Object System.Text.UTF8Encoding($false)))
        $recheck = Get-Content $mpath -Raw | ConvertFrom-Json
        $dupNames = @(@($recheck.windows) | ForEach-Object { [string]$_.ipc_name })
        Assert ($dupNames.Count -eq 2 -and @(Get-Duplicates $dupNames).Count -eq 1) `
            "E0 the manifest now records one name twice (got: $($dupNames -join ', '))"
        # The two colliding entries, named by the pane id restore re-adopts -
        # so the assertions below are about THOSE windows and not about
        # whatever else the launch brings back.
        $dupPanes = @(@($recheck.windows) | ForEach-Object { Get-ManifestFirstPane $_ } |
            Where-Object { $_ })
        Assert ($dupPanes.Count -eq 2) `
            "E0b both colliding entries name a pane to identify them by (got $($dupPanes.Count))"

        $env:LOCALAPPDATA = $tmp
        $env:GHOSTTY_LOCAL_AGENT_BIN = $agent
        # persistence: on (default) - the doctored manifest above is what this
        # launch must restore.
        $dup = Start-OnTestDesktop -Exe $exe
        if ((Wait-TestWindow -ProcessId $dup.Pid -Class 'GhozttyWindow') -eq [IntPtr]::Zero) {
            Say 'SETUP FAIL: duplicate-name relaunch has no GhozttyWindow'
        }
        # Both doctored entries come back - and possibly more, since a launch
        # also adopts agent-held sessions the local file never listed. The
        # subject is the NAMES, so the count is a floor, not an equality.
        $eWins = @(Wait-WindowsSettle 2)
        Assert ($eWins.Count -ge 2) `
            "E1 both windows in the manifest came back (got $($eWins.Count))"

        # The two colliding windows, found by the pane ids they re-adopted.
        $eDup = @($eWins | Where-Object { $dupPanes -contains (Get-FirstPaneId $_) })
        Assert ($eDup.Count -eq 2) `
            "E1b both colliding entries are identifiable after the restore (found $($eDup.Count) of 2)"

        # The defect, stated: a window whose recorded name the incumbent kept
        # used to record no name at all, so `+list` reported an empty target
        # and `--target=` could not reach it.
        $eTargets = @($eDup | ForEach-Object { [string]$_.target })
        $allTargets = @($eWins | ForEach-Object { [string]$_.target })
        $nameless = @($allTargets | Where-Object { -not $_ })
        Assert ($nameless.Count -eq 0) `
            "E2 no restored window came back nameless (empty targets: $($nameless.Count) of $($allTargets.Count))"
        Assert (@(Get-Duplicates $allTargets).Count -eq 0) `
            "E3 every live window holds a DIFFERENT name (got: $($allTargets -join ', '))"
        Assert (@($eTargets | Where-Object { $_ -eq 'window-1' }).Count -eq 1) `
            "E4 exactly one of the two kept the contested name (got: $($eTargets -join ', '))"

        # E5: the fallback is a name that actually ROUTES, not just a string in
        # `+list`. Rename by it and require the title to land on that window
        # and no other.
        $fallback = @($eTargets | Where-Object { $_ -and $_ -ne 'window-1' })[0]
        $fallbackPane = if ($fallback) { Get-PaneIdOf $fallback } else { $null }
        $otherPane = @($eDup | ForEach-Object { Get-FirstPaneId $_ } |
            Where-Object { $_ -and $_ -ne $fallbackPane })[0]
        if (-not $fallback) {
            Assert $false 'E5 the losing window has a fallback name to route by'
        } else {
            $r = Invoke-Verb @('+rename', "--target=$fallback", '--title=T896 routed')
            Assert ($r.Code -eq 0) "E5 +rename --target=$fallback exits 0 (got $($r.Code))"
            $landed = $false
            $strayed = $false
            $deadline = (Get-Date).AddSeconds(20)
            while ((Get-Date) -lt $deadline) {
                foreach ($w in Get-Windows) {
                    if ([string]$w.title -notlike '*T896 routed*') { continue }
                    if ((Get-FirstPaneId $w) -eq $fallbackPane) { $landed = $true }
                    else { $strayed = $true }
                }
                if ($landed -or $strayed) { break }
                Start-Sleep -Milliseconds 400
            }
            Assert $landed "E6 --target=$fallback reached the window that holds it"
            Assert (-not $strayed) 'E7 the rename did not reach the other window'
            Assert ($null -ne $otherPane) 'E8 the incumbent window is still a distinct window'
        }

        # E9: the next sync records the fallback, so the name survives the NEXT
        # restart instead of being re-contested every launch.
        $synced = Wait-Manifest $tmp {
            param($mm)
            $all = @(@($mm.windows) | ForEach-Object { [string]$_.ipc_name })
            $named = @($all | Where-Object { $_ })
            $named.Count -ge 2 -and $named.Count -eq $all.Count -and
                @(Get-Duplicates $named).Count -eq 0
        } 30
        Assert ($null -ne $synced) 'E9 the manifest re-recorded both names, now distinct'
    }

    # ---- F: a manifest recording an EMPTY name (T896) -----------------------
    # The other way a restored window ends up with nothing in `+list`'s
    # `target`: a manifest entry whose `ipc_name` is present but blank. An
    # adopted name of "" is not a name - it must mint one, the same as an entry
    # that recorded no name at all.
    Say '== F: an empty recorded name'
    Stop-AppOnly
    $fdoc = $null
    try { $fdoc = Get-Content (Manifest-Path $tmp) -Raw | ConvertFrom-Json } catch { $fdoc = $null }
    if ($null -eq $fdoc) {
        Assert $false 'F0 the manifest is readable before doctoring it'
    } else {
        foreach ($w in @($fdoc.windows)) { $w.ipc_name = '' }
        [System.IO.File]::WriteAllText(
            (Manifest-Path $tmp),
            ($fdoc | ConvertTo-Json -Depth 40),
            (New-Object System.Text.UTF8Encoding($false)))
        $env:LOCALAPPDATA = $tmp
        $env:GHOSTTY_LOCAL_AGENT_BIN = $agent
        # persistence: on (default) - this launch restores the blank-name manifest.
        $blank = Start-OnTestDesktop -Exe $exe
        if ((Wait-TestWindow -ProcessId $blank.Pid -Class 'GhozttyWindow') -eq [IntPtr]::Zero) {
            Say 'SETUP FAIL: empty-name relaunch has no GhozttyWindow'
        }
        $fWins = @(Wait-WindowsSettle 2)
        Assert ($fWins.Count -ge 2) "F1 both windows came back (got $($fWins.Count))"
        $fTargets = @($fWins | ForEach-Object { [string]$_.target })
        Assert (@($fTargets | Where-Object { -not $_ }).Count -eq 0) `
            "F2 a blank recorded name mints a real one (targets: '$($fTargets -join "', '")')"
        Assert (@(Get-Duplicates @($fTargets | Where-Object { $_ })).Count -eq 0) `
            "F3 the minted names are distinct (targets: $($fTargets -join ', '))"
    }

} finally {
    Say '== cleanup'
    Remove-TestDesktop
    Stop-RepoInstances
    $env:LOCALAPPDATA = $savedLocalAppData
    if ($null -ne $savedAgentBin) { $env:GHOSTTY_LOCAL_AGENT_BIN = $savedAgentBin }
    else { Remove-Item env:GHOSTTY_LOCAL_AGENT_BIN -ErrorAction SilentlyContinue }
    $env:GHOZTTY_PIPE_SUFFIX = $savedPipe
    if ($script:fail -eq 0) { Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue }
    else { Say "artifacts preserved at $root" }
}

$fgSeen = @(Stop-TestForegroundWatch)
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @(Get-TestLaunchedPids)
    Assert ($fgSeen.Count -gt 0) 'Z1 the foreground watcher actually sampled (negative control)'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'Z2 no test-desktop app ever became foreground on the interactive desktop'
}

Say ''
if ($script:fail -eq 0) { Say "ALL PASS ($script:pass)"; exit 0 }
Say "$script:fail FAILURE(S) ($script:pass passed)"
exit 1
