# T158 acceptance: every launch in test\win32 says what it wants session
# persistence to do, and the flag that says "don't restore" actually stops the
# restore.
#
#   powershell -NoProfile -File test\win32\persistence-flag.ps1
#
# THE DEFECT THIS GUARDS. Session persistence is ON by default, so a GUI
# launched without `--session-persistence=false` restores whatever panes the
# last launch left behind - and the script's own setup assertions then describe
# someone else's layout. It is not a dirty-box problem: each launch writes the
# manifest the NEXT one restores, so a multi-section script poisons itself on a
# clean machine. T131 hit it in pane-banner.ps1 and T155 hit it again in
# split-dim.ps1 and split-zoom-nav.ps1, where both scripts failed
# `default setup: 2 visible panes` against a build whose geometry was
# independently verified correct. The cost is misattribution: it presents as a
# product regression in whatever change happens to be in flight.
#
# WHAT IS ASSERTED
#
#   A (sweep)   every launch of the app under test in test\win32 declares its
#               intent - by passing the flag, by passing something built from
#               it, by every caller of its helper passing it, or by a
#               `# persistence: <reason>` marker for a site where none of those
#               fit (a CLI verb, a throwaway-LOCALAPPDATA launch, a forward-and-
#               exit second instance).
#   B (teeth)   the sweep can say NO. Synthetic scripts in a temp directory
#               exercise each declaration form and one undeclared launch, so a
#               sweep that has quietly stopped finding launch sites at all fails
#               here instead of reporting a clean A.
#   C (control) the class negative control, live: build a two-pane window under
#               persistence, kill the app, and relaunch twice. Without the flag
#               the panes come back (the hazard is real, and the restored pane
#               is LIVE, not a picture); with `--session-persistence=false` they
#               do not (the flag every other script relies on works).
#
# Hermetic: per-run LOCALAPPDATA, per-run agent binary override, a private IPC
# pipe suffix, and it only ever kills ghoztty processes launched from this
# repo's zig-out. Section C runs on the BACKGROUND test desktop.
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
$root = Join-Path $env:TEMP "ghoztty-persistence-flag-$PID"

. (Join-Path $PSScriptRoot 'lib\PersistenceSweep.ps1')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
# T652: "attached is not alive" - section C's restored pane is proved by typing
# into it, not by finding it in a tree.
. (Join-Path $PSScriptRoot 'lib\PaneLiveness.ps1')
# T350: refuse a non-debug zig-out before anything is launched.
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

# Kill ONLY the app: the detached agent keeps its PTYs, which is the scenario a
# restore comes out of (quit / crash / upgrade).
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

function Count-Leaves($node) {
    if (-not $node) { return 0 }
    if ($node.type -eq 'leaf') { return 1 }
    return (Count-Leaves $node.left) + (Count-Leaves $node.right)
}

# Panes in the window whose target is $target, or -1 when no such window.
function Get-PaneCount($target) {
    foreach ($w in Get-Windows) {
        if ([string]$w.target -ne $target) { continue }
        $n = 0
        foreach ($t in @($w.tabs)) { $n += (Count-Leaves $t.splits) }
        return $n
    }
    return -1
}

# Leaves recorded for $target in the on-disk manifest, or -1 when the file does
# not exist / does not mention it. T1663: the manifest is what a relaunch
# restores FROM, so this is the only way to ask "has the layout actually been
# recorded yet" - `+list --json` answers about the live app, which is a
# different question and the one this script used to confuse it with.
function Get-PersistedLeafCount($target) {
    $path = Get-DebugSessionLayoutPath
    if (-not $path -or -not (Test-Path $path)) { return -1 }
    try { $doc = (Get-Content $path -Raw -ErrorAction Stop) | ConvertFrom-Json }
    catch { return -1 }   # a torn read of the atomic rewrite: not "absent", just not yet
    foreach ($w in @($doc.windows)) {
        if ([string]$w.ipc_name -ne $target) { continue }
        $n = 0
        foreach ($t in @($w.tabs)) {
            foreach ($node in @($t.nodes)) {
                if ($node.PSObject.Properties.Name -contains 'leaf') { $n++ }
            }
        }
        return $n
    }
    return -1
}

# T1663: the layout write is DEBOUNCED (App.zig LAYOUT_SYNC_DEBOUNCE_MS = 250)
# and every further mutation RESTARTS the timer, so `+new-window` immediately
# followed by `+split` can leave the app with nothing on disk at all. Killing
# it there - and the kill is TerminateProcess, so there is no shutdown flush -
# destroys the fixture the two relaunches below are measured against, and the
# failure surfaces as "restore is broken" rather than "nothing was ever saved".
# That is what made C2 red on 2026-09-19 against a product with no code change
# in range: a 300 ms poll racing a 250 ms debounce is a coin toss that the box's
# speed decides.
function Wait-Persisted($target, $leaves, $timeoutSec = 20) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $seen = -1
    while ((Get-Date) -lt $deadline) {
        $seen = Get-PersistedLeafCount $target
        if ($seen -eq $leaves) { return $seen }
        Start-Sleep -Milliseconds 200
    }
    return $seen
}

function Wait-PaneCount($target, $count, $timeoutSec = 45) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $seen = -1
    while ((Get-Date) -lt $deadline) {
        $seen = Get-PaneCount $target
        if ($seen -eq $count) { return $seen }
        Start-Sleep -Milliseconds 400
    }
    return $seen
}

# ---------------------------------------------------------------------------
# A: the sweep over the real suite
# ---------------------------------------------------------------------------
Say '== A: every launch site in test\win32 declares its persistence intent'
$sites = @(Get-GhozttyLaunchSites -Root $PSScriptRoot)
Assert ($sites.Count -ge 100) "A0 the sweep found the suite's launch sites (found $($sites.Count))"
$undeclared = @($sites | Where-Object { -not $_.Declared })
foreach ($u in $undeclared) {
    Say ("      undeclared: {0}:{1}  {2}" -f $u.File, $u.Line, $u.Stmt)
}
Assert ($undeclared.Count -eq 0) `
    "A1 no launch leaves persistence unstated (undeclared: $($undeclared.Count) of $($sites.Count))"
$byHow = $sites | Group-Object { ($_.How -split ':')[0] } | ForEach-Object { "$($_.Name)=$($_.Count)" }
Say ("      declared by: " + ($byHow -join ', '))

# ---------------------------------------------------------------------------
# B: the sweep's own teeth
# ---------------------------------------------------------------------------
Say '== B: the sweep can say no'
$fix = Join-Path $root 'sweepfix'
New-Item -ItemType Directory -Force $fix | Out-Null

# The fixtures spell the launch call as @@LAUNCH@@ and substitute it below,
# because section A sweeps THIS file too: a literal `Start-OnTestDesktop` inside
# a here-string reads to the sweep as an undeclared launch site, and the teeth
# check would fail the very assertion it exists to protect.
$literal = @'
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
$app = @@LAUNCH@@ -Exe $exe -Arguments @('--session-persistence=false')
'@
$viaVar = @'
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
$launchArgs = @('--session-persistence=false') + $extra
$sp = @{ Exe = $exe; Arguments = $launchArgs }
$app = @@LAUNCH@@ @sp
'@
$viaMarker = @'
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
# persistence: on (default) - a reason a reader can weigh.
$app = @@LAUNCH@@ -Exe $exe
'@
$viaCallers = @'
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
function Launch-Gui([string[]]$ExtraArgs) {
    return (@@LAUNCH@@ -Exe $exe -Arguments $ExtraArgs)
}
$a = Launch-Gui @('--session-persistence=false')
$b = Launch-Gui @('--session-persistence=true')
'@
$undeclaredFix = @'
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
$app = @@LAUNCH@@ -Exe $exe -Arguments @('--window-width=100')
'@
$otherImage = @'
$agentExe = Join-Path $repo 'zig-out\bin\ghoztty-agent.exe'
$a = @@LAUNCH@@ -Exe $agentExe -Arguments @('--listen', '127.0.0.1:7777')
'@
$badValue = @'
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
$app = @@LAUNCH@@ -Exe $exe -Arguments @('--session-persistence=nope')
'@
# T697: the shape the sweep used to miss - a marker written once on the helper's
# own header, further above the launch than the fixed six-line window reached.
$viaFnMarker = @'
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
# `ghoztty <argv>`, with the CLI's own environment.
# persistence: a CLI invocation - it opens no window, so there is nothing to restore.
function Run-Cli($argv) {
    $saved = $env:LOCALAPPDATA
    $env:LOCALAPPDATA = $tmp
    $out = Join-Path $tmp 'out.txt'
    $err = "$out.err"
    $code = $null
    $p = @@LAUNCH@@ -Exe $exe -Arguments $argv
    $env:LOCALAPPDATA = $saved
    return $p
}
$r = Run-Cli @('+list')
'@
# ... and the boundary that keeps it honest: the marker declares the function it
# is written on, not every function that happens to sit below it.
$fnScope = @'
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
# persistence: a CLI invocation - nothing to restore.
function Run-Declared($argv) {
    $g = 1
    $h = 2
    $i = 3
    $j = 4
    $k = 5
    $l = 6
    $p = @@LAUNCH@@ -Exe $exe -Arguments $argv
    return $p
}
function Run-Other($argv) {
    $a = 1
    $b = 2
    $c = 3
    $d = 4
    $e = 5
    $f = 6
    $q = @@LAUNCH@@ -Exe $exe -Arguments $argv
    return $q
}
$x = Run-Declared @('+list')
$y = Run-Other @('+list')
'@
# The other half of T697: the window is the comment BLOCK, not a line count, so a
# marker at the top of a long explanation still declares the launch under it.
$longBlock = @'
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
# persistence: on (default) - the first line of a long block that explains why.
# This launch restores on purpose: the section below is about what comes back,
# so turning persistence off would delete the fixture the assertions read.
# The block runs past six lines deliberately, because that is what a reader
# writes when the reason takes a paragraph rather than a sentence, and the
# marker belongs at the top of the reason rather than buried at the bottom of
# it where a fixed-size window would happen to catch it.
$app = @@LAUNCH@@ -Exe $exe
'@

# T1012. An image taken from the ENVIRONMENT is cmd.exe, not the terminal: five
# `ping` fixtures were reported as ghoztty launches nobody had declared, and no
# edit to any of them could have been right, since cmd.exe has no session to
# persist. The pair says it in both directions - an env var whose name says
# ghoztty is still ours, and still has to declare.
$envImage = @'
$d = @@LAUNCH@@ -Exe $env:ComSpec -Arguments @('/c', 'ping -n 3 127.0.0.1 >nul')
'@
$envOurs = @'
$d = @@LAUNCH@@ -Exe $env:GHOZTTY_TEST_EXE -Arguments @('--window-width=100')
'@
# T1012. Same shape one hop away: a tool looked up on PATH names itself, and
# `$node = Get-Command node` carries no `.exe` literal for the image check to
# read, so the dashboard's node server read as an undeclared ghoztty launch.
$pathTool = @'
$node = Get-Command node -ErrorAction SilentlyContinue
$srv = @@LAUNCH@@ -FilePath $node.Source -ArgumentList '--port 7788'
'@
# T1012. The third marker scope: a script whose HEADER reasons about persistence
# for the whole run has declared every launch in it (update-graceful.ps1 wrote
# exactly that and was still reported undeclared). Only the LEADING block counts
# - `headerlate.ps1` writes the same sentence after the code starts, where it
# belongs to whatever it sits on and declares nothing.
$fileHeader = @'
# A fixture script.
# persistence: on (default) - the run has its own LOCALAPPDATA.
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
$a = 1
$b = 2
$c = 3
$d = 4
$e = 5
$f = 6
$g = 7
$app = @@LAUNCH@@ -Exe $exe -Arguments @('--window-width=100')
'@
$headerLate = @'
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
$other = 1
# persistence: on (default) - written too late to be the file's header.
$a = 1
$b = 2
$c = 3
$d = 4
$e = 5
$f = 6
$g = 7
function Run-Other { return $other }
$app = @@LAUNCH@@ -Exe $exe -Arguments @('--window-width=100')
'@

foreach ($pair in @(
        @{ Name = 'literal.ps1'; Body = $literal },
        @{ Name = 'envimage.ps1'; Body = $envImage },
        @{ Name = 'envours.ps1'; Body = $envOurs },
        @{ Name = 'pathtool.ps1'; Body = $pathTool },
        @{ Name = 'fileheader.ps1'; Body = $fileHeader },
        @{ Name = 'headerlate.ps1'; Body = $headerLate },
        @{ Name = 'viavar.ps1'; Body = $viaVar },
        @{ Name = 'viamarker.ps1'; Body = $viaMarker },
        @{ Name = 'viacallers.ps1'; Body = $viaCallers },
        @{ Name = 'undeclared.ps1'; Body = $undeclaredFix },
        @{ Name = 'otherimage.ps1'; Body = $otherImage },
        @{ Name = 'badvalue.ps1'; Body = $badValue },
        @{ Name = 'fnmarker.ps1'; Body = $viaFnMarker },
        @{ Name = 'fnscope.ps1'; Body = $fnScope },
        @{ Name = 'longblock.ps1'; Body = $longBlock })) {
    $body = $pair.Body -replace '@@LAUNCH@@', 'Start-OnTestDesktop'
    Set-Content -Path (Join-Path $fix $pair.Name) -Value $body -Encoding ASCII
}

$fixSites = @(Get-GhozttyLaunchSites -Root $fix)
function Fix-How($file) {
    $row = $fixSites | Where-Object { $_.File -eq $file } | Select-Object -First 1
    if (-not $row) { return '<no site found>' }
    return $row.How
}
Assert ((Fix-How 'literal.ps1') -eq 'literal') "B1 a flag in the launch statement declares it (got '$(Fix-How 'literal.ps1')')"
Assert ((Fix-How 'viavar.ps1') -like 'var:*') "B2 a flag reached through a splat declares it (got '$(Fix-How 'viavar.ps1')')"
Assert ((Fix-How 'viamarker.ps1') -eq 'marker') "B3 a '# persistence:' marker declares it (got '$(Fix-How 'viamarker.ps1')')"
Assert ((Fix-How 'viacallers.ps1') -like 'callers:*') "B4 a helper whose every caller passes the flag declares it (got '$(Fix-How 'viacallers.ps1')')"
$bad = @($fixSites | Where-Object { $_.File -eq 'undeclared.ps1' })
Assert ($bad.Count -eq 1 -and -not $bad[0].Declared) `
    "B5 a launch that never mentions persistence is reported UNDECLARED (got $($bad.Count) site(s), declared=$(if ($bad.Count) { $bad[0].Declared } else { 'n/a' }))"
Assert (@($fixSites | Where-Object { $_.File -eq 'otherimage.ps1' }).Count -eq 0) `
    'B6 a launch of a different image (the agent) is not swept at all'
# A value `parseBool` rejects is logged and dropped, so the setting keeps its
# default: the launch looks explicit and restores anyway. That must not read as
# a declaration.
$badRow = @($fixSites | Where-Object { $_.File -eq 'badvalue.ps1' })
Assert ($badRow.Count -eq 1 -and -not $badRow[0].Declared) `
    "B7 a flag with a value the CLI rejects is NOT a declaration (got $($badRow.Count) site(s), declared=$(if ($badRow.Count) { $badRow[0].Declared } else { 'n/a' }))"

# T697. The sweep read a marker on a function header as no marker at all, and
# reported the site as work nobody had considered. These three say the opposite
# in both directions: the header declares the launches inside its function, it
# does NOT declare the next function's, and a long comment block is one unit.
Assert ((Fix-How 'fnmarker.ps1') -eq 'marker:fn:Run-Cli') `
    "B8 a marker on the enclosing function's header declares its launch, and says where (got '$(Fix-How 'fnmarker.ps1')')"
$scoped = @($fixSites | Where-Object { $_.File -eq 'fnscope.ps1' } | Sort-Object Line)
Assert ($scoped.Count -eq 2 -and $scoped[0].How -eq 'marker:fn:Run-Declared' -and -not $scoped[1].Declared) `
    ("B9 that marker declares ONLY its own function - the next one is still undeclared " +
        "(got $($scoped.Count) site(s): $(($scoped | ForEach-Object { if ($_.How) { $_.How } else { 'undeclared' } }) -join ', '))")
Assert ((Fix-How 'longblock.ps1') -eq 'marker') `
    "B10 a marker at the top of a comment block longer than six lines still declares it (got '$(Fix-How 'longblock.ps1')')"

# T1012. Three sweep reads that produced work nobody could do, each with the
# control that keeps the new rule from swallowing a real site.
Assert (@($fixSites | Where-Object { $_.File -eq 'envimage.ps1' }).Count -eq 0) `
    'B11 a launch of $env:ComSpec (cmd.exe) is not swept as the terminal'
$envOursRow = @($fixSites | Where-Object { $_.File -eq 'envours.ps1' })
Assert ($envOursRow.Count -eq 1 -and -not $envOursRow[0].Declared) `
    ("B12 but an env var whose NAME says ghoztty IS swept, and still has to declare " +
        "(got $($envOursRow.Count) site(s), declared=$(if ($envOursRow.Count) { $envOursRow[0].Declared } else { 'n/a' }))")
Assert (@($fixSites | Where-Object { $_.File -eq 'pathtool.ps1' }).Count -eq 0) `
    'B13 a tool found on PATH (Get-Command node) is not swept as the terminal'
Assert ((Fix-How 'fileheader.ps1') -eq 'marker:file') `
    "B14 a marker in the script's HEADER declares the launches in it (got '$(Fix-How 'fileheader.ps1')')"
$lateRow = @($fixSites | Where-Object { $_.File -eq 'headerlate.ps1' })
Assert ($lateRow.Count -eq 1 -and -not $lateRow[0].Declared) `
    ("B15 and the same sentence written after the code starts is not a header, so it " +
        "declares nothing (got $($lateRow.Count) site(s), declared=$(if ($lateRow.Count) { $lateRow[0].Declared } else { 'n/a' }))")

# ---------------------------------------------------------------------------
# C: the class negative control, live
# ---------------------------------------------------------------------------
$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN
$savedPipe = $env:GHOZTTY_PIPE_SUFFIX
$env:GHOZTTY_PIPE_SUFFIX = "-t158flag$PID"

Stop-RepoInstances
$tmp = Join-Path $root 'app'
New-Item -ItemType Directory -Force (Join-Path $tmp 'ghoztty\local-agent-debug') | Out-Null
$env:LOCALAPPDATA = $tmp
$env:GHOSTTY_LOCAL_AGENT_BIN = $agent

Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    Assert (Test-Path $exe) 'C0 ghoztty exe exists in zig-out'
    Assert (Test-Path $agent) 'C0 ghoztty-agent exe exists in zig-out'

    Say '== C1: build a two-pane window under persistence'
    # persistence: on, EXPLICITLY - this arm is the fixture the two relaunches
    # below are measured against, so it must not depend on what the default
    # happens to be.
    $app = Start-OnTestDesktop -Exe $exe -Arguments @('--session-persistence=true') `
        -StdErr (Join-Path $root 'app1.err.txt')
    if ((Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow') -eq [IntPtr]::Zero) {
        Say 'SETUP FAIL: no GhozttyWindow'; exit 1
    }
    $r = Invoke-Verb @('+new-window', '--target=t158-pair')
    Assert ($r.Code -eq 0) "C1a +new-window --target=t158-pair exits 0 (got $($r.Code))"
    $r = Invoke-Verb @('+split', '--target=t158-pair', '--direction=right')
    Assert ($r.Code -eq 0) "C1b +split exits 0 (got $($r.Code))"
    $panes = Wait-PaneCount 't158-pair' 2
    Assert ($panes -eq 2) "C1c the fixture window has 2 panes (got $panes)"
    # T1663. The fixture is not built until it is on DISK: everything below
    # measures a relaunch, and a relaunch reads the manifest, not the window
    # that was on screen a moment ago. Asserted rather than slept, so a write
    # that stops happening fails HERE, naming the fixture, instead of three
    # assertions later as a restore that did nothing.
    $saved = Wait-Persisted 't158-pair' 2
    Assert ($saved -eq 2) `
        "C1d the fixture window is PERSISTED before the app is killed (2 leaves on disk, got $saved)"

    Say '== C2: relaunch WITHOUT the flag - the panes come back'
    Stop-AppOnly
    $env:LOCALAPPDATA = $tmp
    $env:GHOSTTY_LOCAL_AGENT_BIN = $agent
    # persistence: on (default) - this is the hazard being demonstrated.
    $restored = Start-OnTestDesktop -Exe $exe -StdErr (Join-Path $root 'app2.err.txt')
    if ((Wait-TestWindow -ProcessId $restored.Pid -Class 'GhozttyWindow') -eq [IntPtr]::Zero) {
        Say 'SETUP FAIL: relaunched app has no GhozttyWindow'
    }
    $back = Wait-PaneCount 't158-pair' 2 60
    $restoreWorked = ($back -eq 2)
    Assert $restoreWorked `
        "C2a a launch with no persistence flag RESTORES the previous run's window (2 panes, got $back)"
    # T652: attached is not alive. A restored pane that came back as a frozen
    # picture satisfies every assertion above, so type into it and require an
    # answer - otherwise C3 could be passing against a restore that never worked.
    Assert (Test-PaneLive -Exe $exe -Target 't158-pair' -Tmp $root -Tag 'T158') `
        'C2b the restored pane is LIVE: input reaches its child and output returns'

    Say '== C3: relaunch WITH --session-persistence=false - they do not'
    Stop-AppOnly
    $env:LOCALAPPDATA = $tmp
    $env:GHOSTTY_LOCAL_AGENT_BIN = $agent
    $clean = Start-OnTestDesktop -Exe $exe -Arguments @('--session-persistence=false') `
        -StdErr (Join-Path $root 'app3.err.txt')
    if ((Wait-TestWindow -ProcessId $clean.Pid -Class 'GhozttyWindow') -eq [IntPtr]::Zero) {
        Say 'SETUP FAIL: the non-persistent app has no GhozttyWindow'
    }
    # Give the restore the same wall-clock it had in C2 before concluding it did
    # not happen: an assertion that fires immediately would pass on a slow box
    # for the wrong reason.
    $late = Wait-PaneCount 't158-pair' 2 20
    # T1663: "nothing came back" is only evidence that the FLAG works if
    # something would have come back without it. C2 answers that, so it is part
    # of this assertion - otherwise a restore that is dead in both arms reads as
    # a correct refusal, which is exactly how a dead restore hid here for a day.
    Assert (($late -eq -1) -and $restoreWorked) `
        ("C3a --session-persistence=false restores nothing, and C2 proved there was " +
            "something to refuse (expected no t158-pair window, got $late pane(s); " +
            "C2 restored=$restoreWorked)")
    $wins = @(Get-Windows)
    Assert ($wins.Count -eq 1) `
        "C3b the non-persistent launch comes up with exactly its own window (got $($wins.Count))"

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

# --- stamp (T783/T1012) ----------------------------------------------------
# A clean green run RECORDS the content of everything this covers, so
# scripts\guard-due.ps1 can answer "has anybody asked the suite as it now stands
# whether every launch declares its intent?". Red stays due: only a green sweep
# re-stamps. Nothing owned that question until now, which is how the undeclared
# count went from 14 to 52 with no run in between.
if ($script:fail -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard persistence-flag -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Say ''
if ($script:fail -eq 0) { Say "ALL PASS ($script:pass)"; exit 0 }
Say "$script:fail FAILURE(S) ($script:pass passed)"
exit 1
