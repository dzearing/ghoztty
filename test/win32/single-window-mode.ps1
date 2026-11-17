# Single-window mode on Windows (T3136, split T3180-T3187) - one section per
# child task. Spec: docs/reference/window-modes.md (Mac 3f772a2f0).
#
# A (T3180): `macos-window-mode` is read ONCE, at launch. A launch whose
#   config says `single` runs single; Settings > Panes & Windows carries Mac's
#   "Open windows" row (Each in its own window / All in one window) with the
#   "takes effect the next time Ghoztty starts" note; choosing the other value
#   there writes the file but does NOT move the running app's mode; the next
#   launch comes up in the new mode.
#
# B (T3191): one shared HWND handed between Window controllers. Read through
#   the debug-only `workspaces` IPC seam (ipc_workspaces.zig: who is on show,
#   who is parked with no HWND) and the test desktop's own window list.
#
# C (T3184): closing a workspace - parked closes in place (+close, last shell
#   exiting), on show hands the same HWND on, the last one closes the window.
# D (T3185): the CLI sees no difference. `+list` names every workspace (on
#   show first, a parked one with its title and a stable id); +split,
#   +send-keys, +read, +set-state, +set-banner, +stash/+restore reach a parked
#   workspace without showing it; ghoztty://focus and --focus switch.
#
# THE ORACLE IS THE LATCH AND THE FILE. The mode the app runs in is a decision
# invisible in pixels (until T3181 gives it a window to act on), so it is read
# through the debug-only `settings` IPC action's `window_mode` field, which
# answers `window_mode.current()` - the same function every mode-dependent path
# asks. The row is read from the same seam and the write from the file itself.
#
# Runs on the BACKGROUND test desktop (lib\TestDesktop.ps1), so it never
# steals the user's foreground.
#
# -NegativeControl asserts the write DID move the running mode - that run
# MUST fail.
#
# Only touches ghoztty processes running from this repo's zig-out*.
param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }
$env:GHOZTTY_PIPE_SUFFIX = "-swm$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\PaneCapture.ps1')   # Invoke-GhozttyIpc
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
. (Join-Path $PSScriptRoot 'lib\AgentLineage.ps1')

[void](Assert-GhozttyIsolatedBuild -Exe $exe)

$script:pass = 0
$script:fail = 0
$script:skipped = 0
$script:negReached = $false

function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Kill-RepoInstances {
    [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
}

function Invoke-Settings([string[]]$ipcArgs) {
    return Invoke-GhozttyIpc -Action 'settings' -Arguments $ipcArgs
}

function Find-Row($state, [string]$key) {
    foreach ($r in @($state.data.rows)) { if ([string]$r.key -eq $key) { return $r } }
    return $null
}

function Get-KeyLines([string]$key) {
    if (-not (Test-Path $cfgFile)) { return @() }
    $text = [System.IO.File]::ReadAllText($cfgFile)
    return @(($text -split "`r?`n") | Where-Object { $_ -match ('^\s*' + [regex]::Escape($key) + '\s*=') })
}

$work = Join-Path $env:TEMP "ghoztty-swm-$PID"
$cfgHome = Join-Path $work 'xdg'
$cfgDir = Join-Path $cfgHome 'ghostty'
$cfgFile = Join-Path $cfgDir 'config-debug.ghostty'
$backupDir = Join-Path $work 'backups'
New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null
[System.IO.File]::WriteAllText($cfgFile, "macos-window-mode = single`n")

$errlog = Join-Path $env:TEMP "ghoztty-swm-stderr-$PID.log"
$script:launched = @()
$app = $null

# Launches the app on the test desktop with the temp config; returns $null
# (after recording why) when it does not come up.
function Start-App([string]$label) {
    $env:XDG_CONFIG_HOME = $cfgHome
    $env:GHOZTTY_SETTINGS_BACKUP_DIR = $backupDir
    $env:GHOZTTY_UPDATE_URL = 'http://127.0.0.1:9/releases'
    try {
        $sp = @{
            Exe       = $exe
            Arguments = @('--session-persistence=false', '--background=#101014')
        }
        if (-not $ExePath) { $sp.StdErr = $errlog }
        $a = Start-OnTestDesktop @sp
    } finally {
        Remove-Item Env:XDG_CONFIG_HOME -ErrorAction SilentlyContinue
        Remove-Item Env:GHOZTTY_SETTINGS_BACKUP_DIR -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 3
    if (-not $a -or ($a.Process -and $a.Process.HasExited)) {
        Write-TestAssertedNothing -Reason "GUI did not come up ($label)" -Label 'single-window-mode'
        return $null
    }
    $script:launched += $script:GhozttyTestDesktopPids
    $top = Wait-TestWindow -ProcessId $a.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) {
        Write-TestAssertedNothing -Reason "no terminal window appeared ($label)" -Label 'single-window-mode'
        return $null
    }
    return $a
}

[void](Set-GhozttyTestAgentLineage -Tag 'swm' -Quiet)
Kill-RepoInstances
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    if ($NegativeControl) {
        Write-Host "NEGATIVE CONTROL: section A asserts the Settings write DID move the running mode - this run MUST fail"
    }

    # =====================================================================
    # A (T3180): read once at launch; the Settings row; next launch.
    # =====================================================================
    $app = Start-App 'launch 1'
    if (-not $app) { exit 1 }

    # The seam answers state only while the Settings window is open.
    $s = Invoke-Settings @('--op=open')
    if (-not $s -or -not $s.success) {
        Write-TestAssertedNothing -Reason 'the settings IPC action never answered' -Label 'single-window-mode'
        exit 1
    }
    Assert ([string]$s.data.window_mode -eq 'single') "A: a launch whose config says single runs single (window_mode='$($s.data.window_mode)')"

    $s = Invoke-Settings @('--op=state', '--page=panes')
    Assert ([string]$s.data.page -eq 'panes') "A: Settings shows Panes & Windows (page='$($s.data.page)')"
    $row = Find-Row $s 'macos-window-mode'
    Assert ($null -ne $row) 'A: Panes & Windows lists macos-window-mode'
    if ($row) {
        Assert ([string]$row.label -eq 'Open windows') "A: the row reads Mac's 'Open windows' (got '$($row.label)')"
        Assert ([string]$row.shown -eq 'All in one window') "A: single reads 'All in one window' (got '$($row.shown)')"
        Assert ([string]$row.hint -match 'next time Ghoztty starts') "A: the row says it takes effect at the next launch (hint='$($row.hint)')"
        Assert ([string]$row.control -eq 'segmented') "A: Mac's segmented choice (got '$($row.control)')"
    }

    # The Settings write, the same function a click on the popup calls.
    $s = Invoke-Settings @('--op=set', '--key=macos-window-mode', '--value=separate')
    Assert ($null -ne $s -and $s.success) 'A: choosing Each in its own window is accepted'
    $lines = @(Get-KeyLines 'macos-window-mode')
    Assert ($lines.Count -eq 1 -and $lines[0] -match '=\s*separate\s*$') "A: the file now says separate ($($lines -join ' | '))"
    $row = Find-Row (Invoke-Settings @('--op=state', '--page=panes')) 'macos-window-mode'
    Assert ($row -and [string]$row.shown -eq 'Each in its own window') "A: the row reads the new value ('$($row.shown)')"

    # Give the reload the write triggered time to land, then ask again.
    Start-Sleep -Milliseconds 1500
    $s = Invoke-Settings @('--op=state')
    if ($NegativeControl) {
        $script:negReached = $true
        Assert ([string]$s.data.window_mode -eq 'separate') "A (NEGATIVE): the running mode moved with the file (window_mode='$($s.data.window_mode)')"
    } else {
        Assert ([string]$s.data.window_mode -eq 'single') "A: the running app stays single until the next launch (window_mode='$($s.data.window_mode)')"
    }
    [void](Invoke-Settings @('--op=close'))
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'A: no crash (launch 1)'

    # The next launch reads the file again.
    Stop-Process -Id $app.Pid -Force -ErrorAction SilentlyContinue
    Kill-RepoInstances
    $app = Start-App 'launch 2'
    if (-not $app) { exit 1 }
    $s = Invoke-Settings @('--op=open')
    Assert ([string]$s.data.window_mode -eq 'separate') "A: the next launch comes up in the new mode (window_mode='$($s.data.window_mode)')"

    # And with no line at all, the default is separate (as before the option).
    Stop-Process -Id $app.Pid -Force -ErrorAction SilentlyContinue
    Kill-RepoInstances
    [System.IO.File]::WriteAllText($cfgFile, "font-size = 13`n")
    $app = Start-App 'launch 3'
    if (-not $app) { exit 1 }
    $s = Invoke-Settings @('--op=open')
    Assert ([string]$s.data.window_mode -eq 'separate') "A: no config line means separate (window_mode='$($s.data.window_mode)')"
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'A: no crash (launch 3)'

    # =====================================================================
    # B (T3191): one shared HWND. A programmatic open parks (no HWND of its
    # own, nothing new on screen); a --focus open and a show hand the SAME
    # HWND over; the shell of a parked workspace keeps running and is there
    # when it comes back on show.
    # =====================================================================
    Stop-Process -Id $app.Pid -Force -ErrorAction SilentlyContinue
    Kill-RepoInstances
    [System.IO.File]::WriteAllText($cfgFile, "macos-window-mode = single`n")
    $app = Start-App 'launch 4 (single)'
    if (-not $app) { exit 1 }

    $ws = Invoke-GhozttyIpc -Action 'workspaces' -Arguments @('--op=state')
    if (-not $ws -or -not $ws.success) {
        Write-TestAssertedNothing -Reason 'the workspaces IPC action never answered' -Label 'single-window-mode'
        exit 1
    }
    $first = [string]$ws.data.active
    $shared = [int64](@($ws.data.workspaces)[0].hwnd)
    Assert ($ws.data.mode -eq 'single' -and $first -and @($ws.data.workspaces).Count -eq 1) "B: the first window loads the shared window (active='$first', $(@($ws.data.workspaces).Count) workspace)"
    Assert ($shared -ne 0) "B: the first workspace holds an HWND ($shared)"

    function Visible-Tops { return @(Get-TestWindows -ProcessId $app.Pid -Class 'GhozttyWindow') }
    function Ws-Row($state, [string]$name) {
        foreach ($r in @($state.data.workspaces)) { if ([string]$r.name -eq $name) { return $r } }
        return $null
    }
    function Shared-Panes {
        return @(Get-TestChildWindows -Window ([IntPtr]$shared) -Class 'GhozttyTerminal' | Where-Object { $_.Visible })
    }

    # B1: a programmatic open stays parked behind the one on show.
    $r = Invoke-GhozttyIpc -Action 'new-window' -Arguments @('--target=swm-b')
    Assert ($r -and $r.success) 'B1: +new-window --target=swm-b (no --focus) succeeds'
    Start-Sleep -Milliseconds 1500
    $ws = Invoke-GhozttyIpc -Action 'workspaces' -Arguments @('--op=state')
    $b = Ws-Row $ws 'swm-b'
    Assert ([string]$ws.data.active -eq $first) "B1: the workspace on show keeps the window (active='$($ws.data.active)')"
    Assert ($b -and $b.parked -and [int64]$b.hwnd -eq 0 -and [int]$b.panes -eq 1) "B1: swm-b is parked with no HWND and its one pane (parked=$($b.parked) hwnd=$($b.hwnd) panes=$($b.panes))"
    Assert ([int]$ws.data.windows_with_hwnd -eq 1) "B1: one controller holds an HWND (windows_with_hwnd=$($ws.data.windows_with_hwnd))"
    $tops = @(Visible-Tops)
    Assert ($tops.Count -eq 1 -and $tops[0].Hwnd -eq $shared) "B1: still ONE window on screen, the same HWND ($($tops.Count): $(($tops | ForEach-Object Hwnd) -join ','))"

    # A parked workspace's shell keeps running: type into it while parked.
    cmd /c "`"$exe`" +send-keys --target=swm-b `"echo PARKED-B-OK`" Enter > nul 2>&1" | Out-Null

    # B2: a --focus open puts the new workspace on show IN THE SAME HWND.
    $r = Invoke-GhozttyIpc -Action 'new-window' -Arguments @('--target=swm-c', '--focus')
    Assert ($r -and $r.success) 'B2: +new-window --target=swm-c --focus succeeds'
    Start-Sleep -Milliseconds 1500
    $ws = Invoke-GhozttyIpc -Action 'workspaces' -Arguments @('--op=state')
    $c = Ws-Row $ws 'swm-c'
    $one = Ws-Row $ws $first
    Assert ([string]$ws.data.active -eq 'swm-c' -and $c -and [int64]$c.hwnd -eq $shared) "B2: swm-c adopted the shared HWND (active='$($ws.data.active)' hwnd=$($c.hwnd) shared=$shared)"
    Assert ($one -and $one.parked -and [int64]$one.hwnd -eq 0) "B2: $first surrendered it and is parked (hwnd=$($one.hwnd))"
    Assert ([string](@($ws.data.workspaces)[0].name) -eq 'swm-c' -and [string](@($ws.data.workspaces)[1].name) -eq $first) "B2: most recently shown first ($((@($ws.data.workspaces) | ForEach-Object name) -join ','))"
    $tops = @(Visible-Tops)
    Assert ($tops.Count -eq 1 -and $tops[0].Hwnd -eq $shared) "B2: no second window appeared ($($tops.Count) on screen)"
    $panes = @(Shared-Panes)
    Assert ($panes.Count -eq 1) "B2: the shared window shows only the adopter's pane ($($panes.Count) visible terminal children)"

    # B3: a show by name hands it over again, and the parked shell's output
    # is there.
    $ws = Invoke-GhozttyIpc -Action 'workspaces' -Arguments @('--op=show', '--target=swm-b')
    Assert ($ws -and $ws.data.shown -eq $true -and [string]$ws.data.active -eq 'swm-b') "B3: show swm-b hands it the window (shown=$($ws.data.shown) active='$($ws.data.active)')"
    $b = Ws-Row $ws 'swm-b'
    Assert ($b -and [int64]$b.hwnd -eq $shared -and -not $b.parked) "B3: swm-b holds the same shared HWND (hwnd=$($b.hwnd))"
    Start-Sleep -Milliseconds 800
    $readOut = Join-Path $work 'read-b.txt'
    cmd /c "`"$exe`" +read --name=swm-b --lines=60 > `"$readOut`" 2>&1" | Out-Null
    $txt = if (Test-Path $readOut) { [string](Get-Content $readOut -Raw) } else { '' }
    # A workspace born parked has no window to take its grid from yet, so its
    # terminal runs one column wide until T3193 lays parked content out at
    # the window's size; the output is there, one cell per line. Join the
    # lines: this asserts the shell RAN while parked, not the grid.
    $txt = $txt -replace '\r?\n', ''
    Assert ($txt -match 'PARKED-B-OK') "B3: what was typed into swm-b while parked ran (read: $($txt -replace '\s+',' '))"
    $panes = @(Shared-Panes)
    Assert ($panes.Count -eq 1) "B3: the shared window shows only swm-b's pane ($($panes.Count))"

    # B4: and back to the first; a show of the one on show is a no-op.
    $ws = Invoke-GhozttyIpc -Action 'workspaces' -Arguments @('--op=show', "--target=$first")
    Assert ($ws -and [string]$ws.data.active -eq $first -and [int64](Ws-Row $ws $first).hwnd -eq $shared) "B4: $first takes the shared HWND back"
    $ws = Invoke-GhozttyIpc -Action 'workspaces' -Arguments @('--op=show', "--target=$first")
    Assert ($ws -and $ws.data.shown -eq $true -and [int]$ws.data.windows_with_hwnd -eq 1) 'B4: showing the one on show changes nothing'
    $tops = @(Visible-Tops)
    Assert ($tops.Count -eq 1 -and $tops[0].Hwnd -eq $shared) "B4: one window on screen throughout ($($tops.Count))"

    # B5 (T3184): closing the window with the workspace on show hands the
    # SAME window to the most recently shown other one - it never blinks and
    # no new top-level appears; the rest stay parked.
    [void](Send-TestSysCommand -Window ([IntPtr]$shared) -Command 'close')
    $deadline = (Get-Date).AddSeconds(8)
    do {
        Start-Sleep -Milliseconds 400
        $ws = Invoke-GhozttyIpc -Action 'workspaces' -Arguments @('--op=state')
    } while ((Get-Date) -lt $deadline -and -not ($ws -and @($ws.data.workspaces).Count -eq 2 -and $ws.data.active))
    $names = @($ws.data.workspaces | ForEach-Object { [string]$_.name })
    Assert ($ws -and $names.Count -eq 2 -and $names -notcontains $first) "B5: closing the window ended only the workspace on show ($($names -join ','))"
    Assert ($ws -and [string]$ws.data.active -eq 'swm-b') "B5: the one shown before it (swm-b) is on show (active='$($ws.data.active)')"
    $tops = @(Visible-Tops)
    $b = Ws-Row $ws 'swm-b'
    Assert ($b -and [int64]$b.hwnd -eq $shared) "B5: swm-b adopted the SAME window (hwnd=$($b.hwnd) shared=$shared)"
    Assert ($tops.Count -eq 1 -and $tops[0].Hwnd -eq $shared) "B5: one window on screen, the shared one ($($tops.Count): $(($tops | ForEach-Object Hwnd) -join ','))"
    $c = Ws-Row $ws 'swm-c'
    Assert ($c -and $c.parked -and [int64]$c.hwnd -eq 0) "B5: swm-c stays parked (hwnd=$($c.hwnd))"
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'B: no crash'

    # =====================================================================
    # D (T3185): the CLI sees no difference. +list names every workspace (on
    # show first and focused, a parked one with its title), with an id that
    # stays put across a switch; the verbs reach a parked workspace WITHOUT
    # putting it on show; a focus (the ghoztty://focus wire action, or
    # --focus) is the switch. (+close of a parked workspace is section C's.)
    # Runs BEFORE section C, which closes every workspace; it leaves the
    # state it found: swm-b on show (B5), swm-c parked.
    # =====================================================================
    function Invoke-SwmCli([string]$argLine) {
        $outFile = Join-Path $work "cli-$([guid]::NewGuid().ToString('N')).txt"
        cmd /c "`"$exe`" $argLine > `"$outFile`" 2>&1" | Out-Null
        $code = $LASTEXITCODE
        $txt = if (Test-Path $outFile) { [string](Get-Content $outFile -Raw) } else { '' }
        return [pscustomobject]@{ Code = $code; Text = $txt }
    }
    function List-Windows {
        $l = Invoke-GhozttyIpc -Action 'list'
        if (-not $l -or -not $l.success) { return @() }
        return @($l.data.windows)
    }
    function List-Row($rows, [string]$name) {
        foreach ($w in @($rows)) { if ([string]$w.target -eq $name) { return $w } }
        return $null
    }
    function Walk-Leaves($node) {
        $acc = @()
        if ($null -eq $node) { return $acc }
        if ($node.type -eq 'leaf') { return @($node.terminal) }
        if ($node.type -eq 'split') { $acc += Walk-Leaves $node.left; $acc += Walk-Leaves $node.right }
        return $acc
    }
    function Window-Leaves($w) {
        $acc = @()
        foreach ($t in @($w.tabs)) { $acc += Walk-Leaves $t.splits }
        return $acc
    }
    function Active-Name {
        $s = Invoke-GhozttyIpc -Action 'workspaces' -Arguments @('--op=state')
        return [string]$s.data.active
    }

    # D1: +list lists both workspaces, on show first.
    $rows = @(List-Windows)
    $names = @($rows | ForEach-Object { [string]$_.target })
    Assert ($rows.Count -eq 2 -and $names[0] -eq 'swm-b' -and $names[1] -eq 'swm-c') "D1: +list names every workspace, on show first ($($names -join ','))"
    $lb = List-Row $rows 'swm-b'
    $lc = List-Row $rows 'swm-c'
    Assert ($lb -and $lb.focused -eq $true) "D1: the workspace on show reads focused (focused=$($lb.focused))"
    Assert ($lc -and $lc.focused -ne $true) "D1: the parked workspace does not (focused=$($lc.focused))"
    Assert ($lc -and ([string]$lc.title).Length -gt 0) "D1: the parked workspace keeps its title ('$($lc.title)')"
    Assert ($lc -and @(Window-Leaves $lc).Count -eq 1) "D1: the parked workspace lists its pane ($(@(Window-Leaves $lc).Count))"
    Assert ($lb -and $lc -and [string]$lb.id -ne [string]$lc.id -and [string]$lc.id -ne '0') "D1: each workspace has its own id (b=$($lb.id) c=$($lc.id))"
    $idB = [string]$lb.id; $idC = [string]$lc.id

    # D2: +split on the parked workspace lands in it and leaves it parked.
    $r = Invoke-SwmCli '+split --target=swm-c --direction=right --name=swm-c-right'
    Start-Sleep -Milliseconds 1200
    $ws = Invoke-GhozttyIpc -Action 'workspaces' -Arguments @('--op=state')
    $c = Ws-Row $ws 'swm-c'
    Assert ($r.Code -eq 0) "D2: +split --target=swm-c succeeds (exit $($r.Code): $($r.Text.Trim()))"
    Assert ($c -and $c.parked -and [int]$c.panes -eq 2) "D2: the split landed in parked swm-c and it stayed parked (parked=$($c.parked) panes=$($c.panes))"
    Assert ([string]$ws.data.active -eq 'swm-b') "D2: the workspace on show did not change (active='$($ws.data.active)')"

    # D3: send-keys / read / set-state / set-banner reach the parked pane.
    [void](Invoke-SwmCli '+send-keys --target=swm-c-right "echo PARKED-C-OK" Enter')
    Start-Sleep -Milliseconds 1500
    $rd = Invoke-SwmCli '+read --name=swm-c-right --lines=60'
    Assert (($rd.Text -replace '\r?\n', '') -match 'PARKED-C-OK') "D3: +send-keys and +read reach a pane in a parked workspace (read: $(($rd.Text -replace '\s+',' ').Trim()))"
    $st = Invoke-SwmCli '+set-state --target=swm-c-right --state=busy'
    $bn = Invoke-SwmCli '+set-banner --target=swm-c-right "parked banner T3185"'
    Start-Sleep -Milliseconds 800
    $lc = List-Row (List-Windows) 'swm-c'
    $leaf = @(Window-Leaves $lc | Where-Object { [string]$_.name -eq 'swm-c-right' })[0]
    Assert ($st.Code -eq 0 -and $leaf -and [string]$leaf.state -eq 'busy') "D3: +set-state reaches it (exit $($st.Code), state='$($leaf.state)')"
    Assert ($bn.Code -eq 0 -and $leaf -and [string]$leaf.banner -match 'parked banner T3185') "D3: +set-banner reaches it (exit $($bn.Code), banner='$($leaf.banner)')"
    Assert ((Active-Name) -eq 'swm-b') 'D3: none of them put swm-c on show'

    # D4: +stash / +restore on the parked workspace's pane.
    $sh = Invoke-SwmCli '+stash --target=swm-c-right'
    Start-Sleep -Milliseconds 800
    $leaf = @(Window-Leaves (List-Row (List-Windows) 'swm-c') | Where-Object { [string]$_.name -eq 'swm-c-right' })[0]
    Assert ($sh.Code -eq 0 -and $leaf -and $leaf.stashed -eq $true) "D4: +stash reaches a parked pane (exit $($sh.Code), stashed=$($leaf.stashed))"
    $rs = Invoke-SwmCli '+restore --target=swm-c-right'
    Start-Sleep -Milliseconds 800
    $leaf = @(Window-Leaves (List-Row (List-Windows) 'swm-c') | Where-Object { [string]$_.name -eq 'swm-c-right' })[0]
    Assert ($rs.Code -eq 0 -and $leaf -and $leaf.stashed -ne $true) "D4: +restore brings it back (exit $($rs.Code), stashed=$($leaf.stashed))"
    Assert ((Active-Name) -eq 'swm-b') 'D4: stash and restore left swm-c parked'

    # D5: a focus is the switch - the ghoztty://focus wire action puts the
    # parked workspace on show, and +list follows with the SAME ids.
    $f = Invoke-GhozttyIpc -Action 'focus' -Arguments @('--target=swm-c')
    Start-Sleep -Milliseconds 1000
    Assert ($f -and $f.success -and (Active-Name) -eq 'swm-c') "D5: ghoztty://focus on a parked workspace puts it on show (active='$(Active-Name)')"
    $rows = @(List-Windows)
    $names = @($rows | ForEach-Object { [string]$_.target })
    Assert ($names.Count -eq 2 -and $names[0] -eq 'swm-c') "D5: +list now leads with swm-c ($($names -join ','))"
    Assert ([string](List-Row $rows 'swm-c').id -eq $idC -and [string](List-Row $rows 'swm-b').id -eq $idB) "D5: ids are the same parked or shown (c=$((List-Row $rows 'swm-c').id)/$idC b=$((List-Row $rows 'swm-b').id)/$idB)"
    Assert ((List-Row $rows 'swm-b').focused -ne $true) 'D5: swm-b, now parked, no longer reads focused'
    $tops = @(Visible-Tops)
    Assert ($tops.Count -eq 1) "D5: still one window on screen ($($tops.Count))"

    # D6: --focus switches too (+new-window --focus on the existing, now
    # parked, swm-b focuses it rather than opening another).
    $nf = Invoke-SwmCli '+new-window --target=swm-b --focus'
    Start-Sleep -Milliseconds 1000
    Assert ($nf.Code -eq 0 -and (Active-Name) -eq 'swm-b') "D6: --focus on a parked workspace puts it on show (exit $($nf.Code), active='$(Active-Name)')"
    Assert (@(List-Windows).Count -eq 2) "D6: and opened nothing new ($(@(List-Windows).Count) workspaces)"
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'D: no crash'


    # =====================================================================
    # C (T3184): closing a workspace. A parked one closes in place (+close,
    # its last shell exiting); the one on show hands the window on (+close);
    # the last one's close closes the window.
    # =====================================================================
    function Wait-Ws([scriptblock]$until, [int]$seconds = 8) {
        $deadline = (Get-Date).AddSeconds($seconds)
        do {
            Start-Sleep -Milliseconds 400
            $s = Invoke-GhozttyIpc -Action 'workspaces' -Arguments @('--op=state')
        } while ((Get-Date) -lt $deadline -and -not (& $until $s))
        return $s
    }

    # C1: +close on a parked workspace closes it in place.
    $r = Invoke-GhozttyIpc -Action 'close' -Arguments @('--target=swm-c')
    Assert ($r -and $r.success) 'C1: +close --target=swm-c (parked) succeeds'
    $ws = Wait-Ws { param($s) $s -and @($s.data.workspaces).Count -eq 1 }
    $names = @($ws.data.workspaces | ForEach-Object { [string]$_.name })
    Assert ($names.Count -eq 1 -and $names[0] -eq 'swm-b') "C1: only swm-c went ($($names -join ','))"
    Assert ([string]$ws.data.active -eq 'swm-b' -and [int64](Ws-Row $ws 'swm-b').hwnd -eq $shared) "C1: swm-b kept the window untouched (active='$($ws.data.active)')"
    $tops = @(Visible-Tops)
    Assert ($tops.Count -eq 1 -and $tops[0].Hwnd -eq $shared) "C1: the window never moved ($($tops.Count))"
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'C1: no crash'

    # C2: a parked workspace whose last shell exits closes in place too.
    $r = Invoke-GhozttyIpc -Action 'new-window' -Arguments @('--target=swm-d')
    Assert ($r -and $r.success) 'C2: +new-window --target=swm-d (parked) succeeds'
    $ws = Wait-Ws { param($s) $s -and (Ws-Row $s 'swm-d') }
    $d = Ws-Row $ws 'swm-d'
    Assert ($d -and $d.parked) "C2: swm-d is parked (parked=$($d.parked))"
    Start-Sleep -Milliseconds 1500
    cmd /c "`"$exe`" +send-keys --target=swm-d `"exit`" Enter > nul 2>&1" | Out-Null
    $ws = Wait-Ws { param($s) $s -and -not (Ws-Row $s 'swm-d') } 12
    Assert ($ws -and -not (Ws-Row $ws 'swm-d')) "C2: swm-d closed when its shell exited ($((@($ws.data.workspaces) | ForEach-Object name) -join ','))"
    Assert ([string]$ws.data.active -eq 'swm-b' -and [int64](Ws-Row $ws 'swm-b').hwnd -eq $shared) "C2: swm-b kept the window (active='$($ws.data.active)')"
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'C2: no crash'

    # C3: +close on the workspace on show hands the window to the one shown
    # before it.
    $r = Invoke-GhozttyIpc -Action 'new-window' -Arguments @('--target=swm-e')
    Assert ($r -and $r.success) 'C3: +new-window --target=swm-e (parked) succeeds'
    [void](Wait-Ws { param($s) $s -and (Ws-Row $s 'swm-e') })
    $r = Invoke-GhozttyIpc -Action 'close' -Arguments @('--target=swm-b')
    Assert ($r -and $r.success) 'C3: +close --target=swm-b (on show) succeeds'
    $ws = Wait-Ws { param($s) $s -and [string]$s.data.active -eq 'swm-e' -and @($s.data.workspaces).Count -eq 1 }
    $e = Ws-Row $ws 'swm-e'
    Assert ($e -and [string]$ws.data.active -eq 'swm-e' -and [int64]$e.hwnd -eq $shared) "C3: swm-e adopted the same window (active='$($ws.data.active)' hwnd=$($e.hwnd))"
    $tops = @(Visible-Tops)
    Assert ($tops.Count -eq 1 -and $tops[0].Hwnd -eq $shared) "C3: one window, the shared one ($($tops.Count))"
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'C3: no crash'

    # C4: the last workspace's close closes the window.
    [void](Send-TestSysCommand -Window ([IntPtr]$shared) -Command 'close')
    $deadline = (Get-Date).AddSeconds(8)
    do { Start-Sleep -Milliseconds 400; $tops = @(Visible-Tops) } while ((Get-Date) -lt $deadline -and $tops.Count -gt 0)
    Assert ($tops.Count -eq 0) "C4: the last workspace's close closed the window ($($tops.Count) left)"


    Complete-TestBody
} catch {
    Write-Host "ERROR $_" -ForegroundColor Red
    $script:fail++
} finally {
    if ($app) { Stop-Process -Id $app.Pid -Force -ErrorAction SilentlyContinue }
    Remove-TestDesktop
    Kill-RepoInstances
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}

$fgSeen = @(Stop-TestForegroundWatch)
Write-Host "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $script:launched = @($script:launched | Select-Object -Unique)
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    $leaked = @($script:launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) "no test-desktop app ever became foreground on the interactive desktop (saw $($leaked -join ','))"
}

if ($NegativeControl -and -not $script:negReached) {
    Assert $false 'NEGATIVE CONTROL never reached its inverted assertion'
}

# --- stamp (T783) ---------------------------------------------------------
if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard single-window-mode -Repo $repo 2>&1 | ForEach-Object { Write-Host "  $_" }
}

Write-TestVerdict -Pass $script:pass -Fail $script:fail -Skipped $script:skipped -Label 'single-window-mode'
