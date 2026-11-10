# T1163 acceptance (decision D102): a launch that restores several saved
# windows brings back the LAST-FOCUSED one first, and the rest a moment later,
# one at a time, behind it - instead of every window at once in listed order.
#
#   A. Build: four windows at distinct frames (the startup window plus three
#      `+new-window --target=` ones), then focus the SECOND one by name, so the
#      last-focused window is neither the first nor the last created. The
#      manifest records a `last_focused_ms` stamp, newest on that window.
#   B. Kill the app (and this run's agent), then relaunch.
#   C. The log names that window as the one restored first, the other three
#      follow as paced windows 1/3..3/3 at strictly increasing offsets at
#      least a pacing interval apart, all four are back (+list), the first
#      one sits at the top of our z-order, and the manifest still holds four
#      windows afterwards (nothing lost).
#   D. Negative control: focus a DIFFERENT window, relaunch - the first
#      restored window follows the focus, so C measured the stamp and not the
#      listed order.
#   E. Crash recovery (T194): delete the manifest, relaunch - the windows come
#      back from the agent's own layouts, still paced.
#
# Isolation: a private LOCALAPPDATA, IPC pipe suffix and agent lineage
# (lib\AgentLineage.ps1). Runs on a BACKGROUND desktop (lib\TestDesktop.ps1).
#
#   powershell -NoProfile -File test\win32\restore-paced.ps1
param([string]$ExePath, [switch]$Interactive, [switch]$KeepState)

# T351: dot-sourced first - it drops an inherited $GHOZTTY_IPC_SOCKET.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }
$agentExe = Join-Path (Split-Path $exe -Parent) 'ghoztty-agent.exe'
$env:GHOZTTY_PIPE_SUFFIX = "-paced$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\AgentLineage.ps1')
[void](Set-GhozttyTestAgentLineage -Tag 'paced' -Quiet)

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

# The pacing interval (restore_pacing.interval_ms) less a scheduling margin.
$minGapMs = 150

$fakeLocal = Join-Path $env:TEMP ("ghoztty-t1163-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $fakeLocal | Out-Null
$manifest = Get-GhozttySessionLayoutPath -Root $fakeLocal

function Read-Text([string]$p) { if (Test-Path $p) { (Get-Content $p -Raw) } else { '' } }

function Read-Manifest {
    $t = Read-Text $manifest
    if (-not $t) { return $null }
    try { return ($t | ConvertFrom-Json) } catch { return $null }
}

function Wait-Manifest([scriptblock]$Pred, [int]$TimeoutSec = 15) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $m = $null
    while ((Get-Date) -lt $deadline) {
        $m = Read-Manifest
        if ($null -ne $m) { try { if (& $Pred $m) { return $m } } catch {} }
        Start-Sleep -Milliseconds 300
    }
    return $m
}

# The manifest window whose stamp is newest, by ipc_name ('' when none is stamped).
function Newest-Focused($m) {
    $best = $null
    foreach ($w in @($m.windows)) {
        if ($null -eq $w.last_focused_ms) { continue }
        if ($null -eq $best -or [int64]$w.last_focused_ms -gt [int64]$best.last_focused_ms) { $best = $w }
    }
    if ($null -eq $best) { return '' }
    return [string]$best.ipc_name
}

function Ghoz([string[]]$GhozArgs, [int]$TimeoutSec = 20) {
    $saved = $env:LOCALAPPDATA
    $env:LOCALAPPDATA = $fakeLocal
    try { return Invoke-OnTestDesktop -Exe $exe -Arguments $GhozArgs -TimeoutSec $TimeoutSec }
    finally { $env:LOCALAPPDATA = $saved }
}

function Get-WindowCount {
    $r = Ghoz @('+list', '--json') 15
    if ($null -eq $r -or $r.ExitCode -ne 0) { return -1 }
    try { $tree = $r.StdOut | ConvertFrom-Json } catch { return -1 }
    $windows = if ($null -ne $tree.data) { $tree.data.windows } else { $tree.windows }
    return @($windows).Count
}

function Wait-WindowCount([int]$N, [int]$TimeoutSec = 30) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $c = -1
    while ((Get-Date) -lt $deadline) {
        $c = Get-WindowCount
        if ($c -eq $N) { return $c }
        Start-Sleep -Milliseconds 500
    }
    return $c
}

function Wait-LogLine([string]$Path, [string]$Pattern, [int]$TimeoutSec = 20) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if ((Test-Path $Path) -and (Select-String -Path $Path -Pattern $Pattern -Quiet)) { return $true }
        Start-Sleep -Milliseconds 400
    }
    return $false
}

function Kill-All { [void](Stop-RepoGhoztty -Exe $exe -SettleMs 500) }

function Launch([string]$Tag) {
    $err = Join-Path $fakeLocal "app-$Tag.err.txt"
    $savedLocal = $env:LOCALAPPDATA
    $savedBin = $env:GHOSTTY_LOCAL_AGENT_BIN
    $env:LOCALAPPDATA = $fakeLocal
    $env:GHOSTTY_LOCAL_AGENT_BIN = $agentExe
    try {
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

# The window the launch restored first, by name, from the log ('' if none).
function Lead-From-Log([string]$Path) {
    if (-not (Test-Path $Path)) { return '' }
    $m = Select-String -Path $Path -Pattern "restored the last-focused window '([^']*)'" | Select-Object -First 1
    if ($null -eq $m) { return '' }
    return $m.Matches[0].Groups[1].Value
}

# The paced windows' log lines as objects: Name, Index, Of, Ms.
function Paced-From-Log([string]$Path) {
    if (-not (Test-Path $Path)) { return @() }
    return @(Select-String -Path $Path -Pattern "paced window '([^']*)' (\d+)/(\d+) at \+(-?\d+)ms" | ForEach-Object {
        $g = $_.Matches[0].Groups
        [pscustomobject]@{ Name = $g[1].Value; Index = [int]$g[2].Value; Of = [int]$g[3].Value; Ms = [int64]$g[4].Value }
    })
}

# The saved frame (x, y, w, h) of the manifest window named $Name.
function Frame-Of($m, [string]$Name) {
    foreach ($w in @($m.windows)) { if ([string]$w.ipc_name -eq $Name) { return $w.frame } }
    return $null
}

# Our topmost visible top-level window (Get-TestWindows enumerates in z-order).
function Top-Rect {
    $tops = @(Get-TestWindows -ProcessId $script:app.Pid -Class 'GhozttyWindow')
    if ($tops.Count -eq 0) { return $null }
    return $tops[0]
}

# Relaunch and score one paced restore whose first window must be $Expect.
function Check-Paced([string]$Tag, [string]$Expect, $Saved, [string]$Section) {
    Launch $Tag
    $n = Wait-WindowCount 4
    Assert ($n -eq 4) "${Section}: all 4 windows came back (got $n)"
    Assert (Wait-LogLine $errLog 'session-restore: restored 4 window' 15) "${Section}: the restore finished with 4 windows"
    $lead = Lead-From-Log $errLog
    Assert ($lead -eq $Expect) "${Section}: the first window restored is the last-focused one, '$Expect' (got '$lead')"
    $paced = @(Paced-From-Log $errLog)
    Assert ($paced.Count -eq 3) "${Section}: the other 3 followed as paced windows (got $($paced.Count))"
    $idxOk = ($paced.Count -eq 3) -and ($paced[0].Index -eq 1) -and ($paced[1].Index -eq 2) -and ($paced[2].Index -eq 3) -and ($paced[2].Of -eq 3)
    Assert $idxOk "${Section}: one at a time, 1/3 then 2/3 then 3/3"
    $gapOk = $paced.Count -eq 3
    $gaps = @()
    $prev = 0
    foreach ($p in $paced) {
        $gaps += ($p.Ms - $prev)
        if (($p.Ms - $prev) -lt $minGapMs) { $gapOk = $false }
        $prev = $p.Ms
    }
    Assert $gapOk "${Section}: each a moment after the one before, at least ${minGapMs}ms apart (gaps $($gaps -join ', ')ms)"
    Assert (-not ($paced | Where-Object { $_.Name -eq $Expect })) "${Section}: the first window was not built twice"
    $top = Top-Rect
    $f = Frame-Of $Saved $Expect
    $topOk = $null -ne $top -and $null -ne $f -and (Near $top.Left $f.x) -and (Near $top.Top $f.y)
    $topDesc = if ($top) { "$($top.Left),$($top.Top)" } else { 'none' }
    $fDesc = if ($f) { "$($f.x),$($f.y)" } else { 'none' }
    Assert $topOk "${Section}: the first window stays in front of the rest (top window at $topDesc, '$Expect' saved at $fDesc)"
    $after = Wait-Manifest { param($m) @($m.windows).Count -eq 4 } 10
    Assert ($null -ne $after -and @($after.windows).Count -eq 4) "${Section}: the manifest still holds all 4 windows afterwards (nothing lost)"
    Assert (-not ($app.Process -and $app.Process.HasExited)) "${Section}: no crash"
}

$script:launched = @()
Kill-All
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    # ---------------------------------------------------------------- A
    Write-Host ''
    Write-Host '--- A: four windows at distinct frames; the second is focused last ---'
    Launch 'build'
    $first = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($first -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: top window not found'; exit 1 }
    $names = @('t1163b', 't1163c', 't1163d')
    foreach ($nm in $names) {
        $r = Ghoz @('+new-window', "--target=$nm")
        Assert ($null -ne $r -and $r.ExitCode -eq 0) "A: +new-window --target=$nm answered (exit $($r.ExitCode))"
    }
    Assert ((Wait-WindowCount 4) -eq 4) 'A: +list shows 4 windows'
    $wins = @(Get-TestWindows -ProcessId $app.Pid -Class 'GhozttyWindow' | ForEach-Object { [IntPtr][int64]$_.Hwnd })
    Assert ($wins.Count -eq 4) "A: the app has 4 top-level windows (got $($wins.Count))"
    if ($wins.Count -ne 4) { throw 'cannot place the windows' }
    $i = 0
    foreach ($w in $wins) {
        Set-TestWindowPos -Window $w -X (40 + 120 * $i) -Y (30 + 70 * $i) | Out-Null
        Set-TestWindowSize -Window $w -Width 640 -Height 420 | Out-Null
        $i++
    }
    $r = Ghoz @('+new-window', '--target=t1163b', '--focus')
    Assert ($null -ne $r -and $r.ExitCode -eq 0) "A: focusing t1163b by name answered (exit $($r.ExitCode))"
    $mA = Wait-Manifest { param($m) @($m.windows).Count -eq 4 -and (Newest-Focused $m) -eq 't1163b' }
    $newest = if ($mA) { Newest-Focused $mA } else { '' }
    Assert ($newest -eq 't1163b') "A: the manifest stamps t1163b as the last-focused window (got '$newest')"
    $distinct = if ($mA) { @($mA.windows | ForEach-Object { "$($_.frame.x),$($_.frame.y)" } | Select-Object -Unique).Count } else { 0 }
    Assert ($distinct -eq 4) "A: the 4 windows are saved at distinct frames (got $distinct)"
    $savedA = Read-Manifest

    # ---------------------------------------------------------------- B/C
    Write-Host ''
    Write-Host '--- B/C: relaunch - t1163b first, the rest one at a time behind it ---'
    Kill-All
    Check-Paced 'paced' 't1163b' $savedA 'C'

    # ---------------------------------------------------------------- D
    Write-Host ''
    Write-Host '--- D: negative control - focus t1163d instead, and it leads ---'
    $r = Ghoz @('+new-window', '--target=t1163d', '--focus')
    Assert ($null -ne $r -and $r.ExitCode -eq 0) "D: focusing t1163d by name answered (exit $($r.ExitCode))"
    $mD = Wait-Manifest { param($m) @($m.windows).Count -eq 4 -and (Newest-Focused $m) -eq 't1163d' }
    $newestD = if ($mD) { Newest-Focused $mD } else { '' }
    Assert ($newestD -eq 't1163d') "D: the manifest now stamps t1163d (got '$newestD')"
    $savedD = Read-Manifest
    Kill-All
    Check-Paced 'flip' 't1163d' $savedD 'D'

    # ---------------------------------------------------------------- E
    Write-Host ''
    Write-Host '--- E: crash recovery - no manifest, the agent''s layouts still restore paced ---'
    $savedE = Read-Manifest
    [void](Stop-RepoGhoztty -Exe $exe -SettleMs 500 -AppOnly)
    Remove-Item -Force $manifest -ErrorAction SilentlyContinue
    Assert (-not (Test-Path $manifest)) 'E: the manifest is gone'
    Check-Paced 'crash' 't1163d' $savedE 'E'
    Assert (Wait-LogLine $errLog 'recovered 4 crash-orphaned window' 5) 'E: the windows came from the agent''s own layouts'
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
        update -Guard restore-paced -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Label 'T1163 RESTORE-PACED' -Pass $script:pass -Fail $script:fail -MinPass 30
