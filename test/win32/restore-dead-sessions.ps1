# T1978 acceptance: when a restart finds that the agent has lost EVERY session
# a window held, the window still comes back - at its saved frame, with its
# splits - and each pane opens a fresh shell, instead of the user getting one
# default window in place of their whole layout.
#
# The report (user, 2026-10-15): a restart lost the sessions AND the windows;
# what came back was one fresh window. The sessions half is T1970/T1973. This
# is the windows half: restore used to drop any window whose every session the
# agent positively did not know (the Mac T06b drop rule), and when the agent
# had lost them all, that was every window.
#
# The state is built for real, then the one thing that makes it "every session
# gone" is done by hand:
#
#   A. Build: two windows, the first split in two (3 agent-backed panes), at
#      known frames. The manifest records 2 windows / 3 leaves with session ids.
#   B. Kill the app AND this run's agent, then delete the agent's sessions.json,
#      so the agent that the relaunch starts has an empty roster: every
#      recorded session is POSITIVELY gone (not unknown - that is carried).
#   C. Relaunch: both windows come back, at their saved frames, with 3 panes;
#      the log names each window as rebuilt with fresh shells; the panes are
#      new sessions (none of the old ids), and a pane answers input.
#   D. Negative control: the same kill with sessions.json KEPT comes back by
#      relaunching the recorded sessions, not by the T1978 rebuild - so C's log
#      line is caused by the empty roster and nothing else.
#
# Isolation: a private LOCALAPPDATA, IPC pipe suffix and agent lineage
# (lib\AgentLineage.ps1), so the agent this run kills is its own. Runs on a
# BACKGROUND desktop (lib\TestDesktop.ps1).
#
#   powershell -NoProfile -File test\win32\restore-dead-sessions.ps1
param([string]$ExePath, [switch]$Interactive, [switch]$KeepState)

# T351: dot-sourced first - it drops an inherited $GHOZTTY_IPC_SOCKET.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }
$agentExe = Join-Path (Split-Path $exe -Parent) 'ghoztty-agent.exe'
$env:GHOZTTY_PIPE_SUFFIX = "-deadsess$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\AgentLineage.ps1')
[void](Set-GhozttyTestAgentLineage -Tag 'deadsess' -Quiet)

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

$fakeLocal = Join-Path $env:TEMP ("ghoztty-t1978-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $fakeLocal | Out-Null
# The manifest name carries the agent lineage (session_layout.layoutPath).
$manifest = Join-Path $fakeLocal "ghoztty\session-layout-debug-$($env:GHOZTTY_AGENT_INSTANCE).json"
$agentDir = Get-GhozttyAgentStateDir -Root $fakeLocal -Exe $exe
$sessionsFile = Join-Path $agentDir 'sessions.json'

function Read-Text([string]$p) { if (Test-Path $p) { (Get-Content $p -Raw) } else { '' } }

function Read-Manifest {
    $t = Read-Text $manifest
    if (-not $t) { return $null }
    try { return ($t | ConvertFrom-Json) } catch { return $null }
}

# Every leaf session id across the manifest, in order.
function Manifest-Sids($m) {
    $ids = @()
    foreach ($w in @($m.windows)) {
        foreach ($t in @($w.tabs)) {
            foreach ($n in @($t.nodes)) {
                if ($null -ne $n.leaf -and $n.leaf.session_id) { $ids += [string]$n.leaf.session_id }
            }
        }
    }
    return , $ids
}

function Wait-Manifest([scriptblock]$Pred, [int]$TimeoutSec = 12) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $m = $null
    while ((Get-Date) -lt $deadline) {
        $m = Read-Manifest
        if ($null -ne $m) { try { if (& $Pred $m) { return $m } } catch {} }
        Start-Sleep -Milliseconds 300
    }
    return $m
}

# The CLI on the test desktop, against this run's pipe.
function Ghoz([string[]]$GhozArgs, [int]$TimeoutSec = 20) {
    $saved = $env:LOCALAPPDATA
    $env:LOCALAPPDATA = $fakeLocal
    try { return Invoke-OnTestDesktop -Exe $exe -Arguments $GhozArgs -TimeoutSec $TimeoutSec }
    finally { $env:LOCALAPPDATA = $saved }
}

function Get-ListTree {
    $r = Ghoz @('+list', '--json') 15
    if ($null -eq $r -or $r.ExitCode -ne 0) { return $null }
    try { return ($r.StdOut | ConvertFrom-Json) } catch { return $null }
}

function Count-LeafNodes($node) {
    if ($null -eq $node) { return 0 }
    if ($node.type -eq 'leaf') { return 1 }
    if ($node.type -eq 'split') { return (Count-LeafNodes $node.left) + (Count-LeafNodes $node.right) }
    return 0
}

# Windows and terminal leaves +list reports, or -1/-1 when the CLI failed.
function Get-Shape {
    $tree = Get-ListTree
    if ($null -eq $tree) { return [pscustomobject]@{ Windows = -1; Leaves = -1 } }
    $windows = if ($null -ne $tree.data) { $tree.data.windows } else { $tree.windows }
    $leaves = 0
    foreach ($w in @($windows)) { foreach ($t in @($w.tabs)) { $leaves += (Count-LeafNodes $t.splits) } }
    return [pscustomobject]@{ Windows = @($windows).Count; Leaves = $leaves }
}

function Wait-Shape([int]$Windows, [int]$Leaves, [int]$TimeoutSec = 30) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $s = $null
    while ((Get-Date) -lt $deadline) {
        $s = Get-Shape
        if ($s.Windows -eq $Windows -and $s.Leaves -eq $Leaves) { return $s }
        Start-Sleep -Milliseconds 500
    }
    return $s
}

function Wait-LogLine([string]$Path, [string]$Pattern, [int]$TimeoutSec = 20) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if ((Test-Path $Path) -and (Select-String -Path $Path -Pattern $Pattern -Quiet)) { return $true }
        Start-Sleep -Milliseconds 400
    }
    return $false
}

function Count-LogLines([string]$Path, [string]$Pattern) {
    if (-not (Test-Path $Path)) { return 0 }
    return @(Select-String -Path $Path -Pattern $Pattern).Count
}

# The app AND this run's agent (Stop-RepoGhoztty narrows to our lineage).
function Kill-All { [void](Stop-RepoGhoztty -Exe $exe -SettleMs 500) }

function Launch([string]$Tag) {
    $err = Join-Path $fakeLocal "app-$Tag.err.txt"
    $savedLocal = $env:LOCALAPPDATA
    $savedBin = $env:GHOSTTY_LOCAL_AGENT_BIN
    $env:LOCALAPPDATA = $fakeLocal
    $env:GHOSTTY_LOCAL_AGENT_BIN = $agentExe
    try {
        # -KeepWindowPlacement: the restored frames ARE the subject.
        $a = Start-OnTestDesktop -Exe $exe -Arguments @('--session-persistence=true') -StdErr $err -KeepWindowPlacement
    } finally {
        $env:LOCALAPPDATA = $savedLocal
        $env:GHOSTTY_LOCAL_AGENT_BIN = $savedBin
    }
    Start-Sleep -Seconds 2
    if ($a.Process -and $a.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $script:app = $a
    $script:errLog = $err
    $script:launched += $a.Pid
}

function Near([int]$a, [int]$b, [int]$tol = 2) { return [math]::Abs($a - $b) -le $tol }

# The app's top-level windows, as rects.
function Get-AppRects {
    return @(Get-TestWindows -ProcessId $script:app.Pid -Class 'GhozttyWindow' |
        ForEach-Object { Get-TestWindowRect -Window ([IntPtr][int64]$_.Hwnd) })
}

# Does any of $rects sit at $f (x, y, w, h) within 2 px?
function Has-Frame($rects, $f) {
    foreach ($r in @($rects)) {
        if ((Near $r.Left $f.X) -and (Near $r.Top $f.Y) -and (Near $r.Width $f.W) -and (Near $r.Height $f.H)) { return $true }
    }
    return $false
}

$script:launched = @()
Kill-All
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    # ---------------------------------------------------------------- A
    Write-Host ''
    Write-Host '--- A: two windows, three agent-backed panes, at known frames ---'
    Launch 'build'
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: top window not found'; exit 1 }
    $r = Ghoz @('+split', '--direction=right')
    Assert ($null -ne $r -and $r.ExitCode -eq 0) "A: +split answered (exit $($r.ExitCode))"
    $r = Ghoz @('+new-window', '--target=t1978second')
    Assert ($null -ne $r -and $r.ExitCode -eq 0) "A: +new-window answered (exit $($r.ExitCode))"
    $shapeA = Wait-Shape 2 3
    Assert ($shapeA.Windows -eq 2 -and $shapeA.Leaves -eq 3) "A: +list shows 2 windows / 3 panes (got $($shapeA.Windows)/$($shapeA.Leaves))"

    # Distinct frames, so "came back at its frame" is a per-window claim.
    $wins = @(Get-TestWindows -ProcessId $app.Pid -Class 'GhozttyWindow' | ForEach-Object { [IntPtr][int64]$_.Hwnd })
    Assert ($wins.Count -eq 2) "A: the app has 2 top-level windows (got $($wins.Count))"
    if ($wins.Count -ne 2) { throw 'cannot place the windows' }
    Set-TestWindowPos -Window $wins[0] -X 40 -Y 30 | Out-Null
    Set-TestWindowSize -Window $wins[0] -Width 900 -Height 560 | Out-Null
    Set-TestWindowPos -Window $wins[1] -X 260 -Y 180 | Out-Null
    Set-TestWindowSize -Window $wins[1] -Width 700 -Height 480 | Out-Null
    $saved = @($wins | ForEach-Object { $x = Get-TestWindowRect -Window $_; [pscustomobject]@{ X = $x.Left; Y = $x.Top; W = $x.Width; H = $x.Height } })
    $mA = Wait-Manifest {
        param($m)
        if (@($m.windows).Count -ne 2) { return $false }
        if ((Manifest-Sids $m).Count -ne 3) { return $false }
        foreach ($s in $saved) {
            $hit = $false
            foreach ($w in @($m.windows)) {
                if ((Near $w.frame.x $s.X) -and (Near $w.frame.y $s.Y) -and (Near $w.frame.w $s.W) -and (Near $w.frame.h $s.H)) { $hit = $true }
            }
            if (-not $hit) { return $false }
        }
        return $true
    }
    $oldSids = if ($mA) { (Manifest-Sids $mA) } else { @() }
    Assert ($null -ne $mA -and @($mA.windows).Count -eq 2) 'A: the manifest records 2 windows'
    Assert ($oldSids.Count -eq 3) "A: the manifest records 3 leaf session ids (got $($oldSids.Count))"
    foreach ($s in $saved) { Write-Host ("      saved frame {0}x{1} at {2},{3}" -f $s.W, $s.H, $s.X, $s.Y) }

    # ---------------------------------------------------------------- B
    Write-Host ''
    Write-Host '--- B: the app and the agent die, and the agent forgets every session ---'
    $manifestBefore = Read-Text $manifest
    Kill-All
    Assert (Test-Path $sessionsFile) "B: the agent had written sessions.json ($sessionsFile)"
    Remove-Item -Force $sessionsFile -ErrorAction SilentlyContinue
    Assert (-not (Test-Path $sessionsFile)) 'B: sessions.json removed, so the next agent starts with an empty roster'
    Assert ((Read-Text $manifest) -eq $manifestBefore) 'B: the layout manifest is untouched by the kill'

    # ---------------------------------------------------------------- C
    Write-Host ''
    Write-Host '--- C: relaunch rebuilds both windows with fresh shells ---'
    Launch 'dead'
    $shapeC = Wait-Shape 2 3
    Assert ($shapeC.Windows -eq 2) "C: both windows came back (got $($shapeC.Windows))"
    Assert ($shapeC.Leaves -eq 3) "C: with all 3 panes, so the split survived (got $($shapeC.Leaves))"
    Assert (Wait-LogLine $errLog 'every session of .* is gone; rebuilding the window with fresh shells' 10) 'C: the log names the rebuild'
    $rebuilt = Count-LogLines $errLog 'rebuilding the window with fresh shells'
    Assert ($rebuilt -eq 2) "C: both windows were rebuilt that way (got $rebuilt)"
    $rects = Get-AppRects
    foreach ($s in $saved) {
        Assert (Has-Frame $rects $s) ("C: a window is back at {0}x{1} at {2},{3}" -f $s.W, $s.H, $s.X, $s.Y)
    }
    $mC = Wait-Manifest { param($m) (Manifest-Sids $m).Count -eq 3 -and -not ((Manifest-Sids $m) | Where-Object { $oldSids -contains $_ }) }
    $newSids = if ($mC) { (Manifest-Sids $mC) } else { @() }
    $reused = @($newSids | Where-Object { $oldSids -contains $_ })
    Assert ($newSids.Count -eq 3 -and $reused.Count -eq 0) "C: the 3 panes are new sessions, none of the lost ids (new $($newSids.Count), reused $($reused.Count))"
    $marker = 'T1978ALIVE' + $PID
    $sk = Ghoz @('+send-keys', '--target=t1978second', "echo $marker", '--enter')
    $seen = $false
    $rd = $null
    for ($i = 0; $i -lt 20 -and -not $seen; $i++) {
        Start-Sleep -Milliseconds 400
        $rd = Ghoz @('+read', '--name=t1978second')
        if ($rd -and $rd.StdOut -match $marker) { $seen = $true }
    }
    if (-not $seen) {
        Write-Host "      send-keys: exit $($sk.ExitCode) $($sk.Output)"
        if ($rd) { Write-Host "      read: exit $($rd.ExitCode) tail: $((($rd.Output -split "`n") | Select-Object -Last 6) -join ' | ')" }
    }
    Assert $seen 'C: a rebuilt pane runs a live shell (echo round-trips through +read)'
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'C: no crash'

    # ---------------------------------------------------------------- D
    Write-Host ''
    Write-Host '--- D: negative control - with sessions.json kept, no T1978 rebuild ---'
    Wait-Manifest { param($m) @($m.windows).Count -eq 2 } | Out-Null
    Kill-All
    Assert (Test-Path $sessionsFile) 'D: sessions.json is there this time'
    Launch 'kept'
    $shapeD = Wait-Shape 2 3
    Assert ($shapeD.Windows -eq 2 -and $shapeD.Leaves -eq 3) "D: both windows come back (got $($shapeD.Windows)/$($shapeD.Leaves))"
    Assert (Wait-LogLine $errLog 'session-restore: restored 2 window' 10) 'D: the restore finished'
    Assert ((Count-LogLines $errLog 'rebuilding the window with fresh shells') -eq 0) 'D: no window was rebuilt by the T1978 rule - C measured the empty roster'
    Complete-TestBody
} finally {
    Remove-TestDesktop
    Kill-All
    if ($KeepState) { Write-Host "state kept: $fakeLocal" }
    else { Remove-Item -Recurse -Force $fakeLocal -ErrorAction SilentlyContinue }
}

$fgSeen = @(Stop-TestForegroundWatch)
Write-Host "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @($script:launched | Select-Object -Unique)
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'no test-desktop app ever became foreground on the interactive desktop'
}

# --- stamp (T783) -----------------------------------------------------------
if ($script:fail -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard restore-dead-sessions -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Label 'T1978 RESTORE-DEAD-SESSIONS' -Pass $script:pass -Fail $script:fail -MinPass 20
