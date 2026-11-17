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
# E (T3192): parked counts as hidden - a parked workspace's terminals present
#   nothing and give back their render targets, its popups (a banner) go off
#   screen, a viewer in it is paused, panes made in it while parked start
#   held, and all of it comes back on show. Read from the seam's
#   presenting / holding_targets / overlays_shown counts.
#
# E (T3186): activity never pauses while parked - the window reports the
#   most urgent of every workspace (seam `activity`), the title suffix is the
#   one on show's own, a parked needs_input asks on the SHARED window, and a
#   notification click from a parked pane puts that workspace on show.
#
# F (T3193): parked content is laid out at the shared window's size - from
#   birth (the seam's per-workspace `cols`/`rows`), 0.3s after a resize of
#   the shared window settles, and at once on a tree change while parked.
#
# G (T3194): opening a window by hand opens a workspace on show in the
#   shared window - Ctrl+N and a pane popped out of its window - and the
#   adopter puts the caret on its own focused pane before its first layout.
# H (T3182): a workspace has no tabs - its strip stays off even with
#   window-show-tab-bar = always, Ctrl+T (new_tab) opens a workspace on show,
#   and goto_tab (Ctrl+1 / Ctrl+9 / next / previous) walks the workspaces in
#   the pane sidebar's all-windows order, putting each on show.
# I (T3187): session restore. Three workspaces, a parked one put on show,
#   then a relaunch with session persistence on: the manifest holds every
#   workspace at the shared window's frame with the one on show marked
#   frontmost; the relaunch brings all three back as workspaces of ONE
#   window with that one on show; and the same manifest read in `separate`
#   mode is three windows at that one frame, the frontmost on top. A window
#   saved with two tabs comes back in single mode as a workspace per tab.
# J (T3183): the shade crossfades on a switch - the seam's `desk_fade` starts
#   from the leaving workspace's gradient with the old desk whole, steps and
#   draws for 0.35s, and is over by 0.9s; switching back fades the other way;
#   two workspaces with the same gradient switch with no fade at all. (Flat
#   style and Animation effects off are `desk_fade.owed`'s unit tests.)
# K (T3205): the pane sidebar's all-windows list switches. The sidebar on
#   show is expanded and put in all-windows scope by clicks; a click on a
#   parked workspace's header puts it on show (the deferred switch T3182
#   added - `workspace switch from the sidebar`), in the SAME window, and the
#   adopter's sidebar comes back expanded (it was parked when the toggle was
#   clicked, and no activation tells it) in all-windows scope; then a click on
#   another parked workspace's PANE row (its chevron unfolds it first) does
#   the same. Every click lands on a point the sidebar's own `pane sidebar
#   outline` line names (toggle=, scope=, heads, chev=, items).
# L (T3200): undo of a workspace close - the closed one waits (seam
#   `closed_for_undo`) while the window goes on to the next, Ctrl+Shift+Z
#   puts it back ON SHOW in the same window with the same shell, a parked
#   one's close undoes onto show too, and an undo that runs out closes it.
# M (T3206): Restore All parks what it rebuilds. Two instances on one agent;
#   A's three workspaces (swm-la on show) are orphaned by killing A, and the
#   chooser's Restore All in B brings all three back as workspaces of B's one
#   window with swm-la on show - through exactly ONE `workspace adopted the
#   window` hand-off, not one per rebuilt workspace.
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
. (Join-Path $PSScriptRoot 'lib\ChromeGeometry.ps1')   # Get-TestChromeDip
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
. (Join-Path $PSScriptRoot 'lib\AgentLineage.ps1')
. (Join-Path $repo 'scripts\lib\NativeArgv.ps1')   # Invoke-NativeExact (D5)

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
$persistLocal = Join-Path $work 'local'
New-Item -ItemType Directory -Force -Path $persistLocal | Out-Null
$script:launched = @()
$app = $null

# Launches the app on the test desktop with the temp config; returns $null
# (after recording why) when it does not come up.
function Start-App([string]$label, [switch]$Persist, [string[]]$Extra = @()) {
    $env:XDG_CONFIG_HOME = $cfgHome
    $env:GHOZTTY_SETTINGS_BACKUP_DIR = $backupDir
    $env:GHOZTTY_UPDATE_URL = 'http://127.0.0.1:9/releases'
    $savedLocal = $env:LOCALAPPDATA
    $savedBin = $env:GHOSTTY_LOCAL_AGENT_BIN
    # Section I (T3187): a private LOCALAPPDATA holds the manifest, and this
    # build's agent hosts the sessions.
    if ($Persist) {
        $env:LOCALAPPDATA = $persistLocal
        $env:GHOSTTY_LOCAL_AGENT_BIN = Join-Path (Split-Path $exe -Parent) 'ghoztty-agent.exe'
    }
    $persistArg = if ($Persist) { '--session-persistence=true' } else { '--session-persistence=false' }
    try {
        $sp = @{
            Exe       = $exe
            # Rearrange mode on a chord for section F's pop-out (T3194).
            Arguments = @($persistArg, '--background=#101014',
                '--keybind=ctrl+shift+f9=toggle_rearrange_mode',
                # Section H's tab walk (T3182) on chords the test can type.
                '--keybind=ctrl+shift+f7=next_tab', '--keybind=ctrl+shift+f8=previous_tab') + $Extra
        }
        if ($Persist) { $sp.KeepWindowPlacement = $true }
        if (-not $ExePath) { $sp.StdErr = $errlog }
        $a = Start-OnTestDesktop @sp
    } finally {
        Remove-Item Env:XDG_CONFIG_HOME -ErrorAction SilentlyContinue
        Remove-Item Env:GHOZTTY_SETTINGS_BACKUP_DIR -ErrorAction SilentlyContinue
        $env:LOCALAPPDATA = $savedLocal
        $env:GHOSTTY_LOCAL_AGENT_BIN = $savedBin
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
    # The strip asked for always, so section H's "a workspace shows no tab
    # strip" (T3182) is the mode's doing and not `auto` at one tab.
    [System.IO.File]::WriteAllText($cfgFile, "macos-window-mode = single`nwindow-show-tab-bar = always`n")
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
    # F1 (T3193): born parked, it is laid out at the shared window's size -
    # the same grid as the one on show, not the park host's one column.
    $one = Ws-Row $ws $first
    Assert ($b -and $one -and [int]$one.cols -gt 20 -and [int]$b.cols -eq [int]$one.cols -and [int]$b.rows -eq [int]$one.rows) "F1: swm-b, born parked, has the window's grid ($($b.cols)x$($b.rows) vs on show $($one.cols)x$($one.rows))"

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
    # Laid out at the window's size from birth (T3193), the line arrives whole.
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
    # E (T3192): a parked workspace counts as hidden. Its terminals stop
    # presenting and give their render targets back, its popups (swm-c-right
    # carries D3's banner) go off screen, and a viewer in it is paused - and
    # all of it comes back when it is shown. Read from the `workspaces`
    # seam's per-workspace `presenting` / `holding_targets` /
    # `overlays_shown`, which walk every pane of every tab. Starts where D
    # left it (swm-b on show, swm-c parked with 2 panes); leaves the same.
    # =====================================================================
    function Wait-Drawing([string]$name, [scriptblock]$until, [int]$seconds = 6) {
        $deadline = (Get-Date).AddSeconds($seconds)
        do {
            $s = Invoke-GhozttyIpc -Action 'workspaces' -Arguments @('--op=state')
            $row = Ws-Row $s $name
            if ($row -and (& $until $row)) { return $row }
            Start-Sleep -Milliseconds 300
        } while ((Get-Date) -lt $deadline)
        return $row
    }
    function Row-Text($r) { if (-not $r) { return 'no row' }; return "parked=$($r.parked) panes=$($r.panes) presenting=$($r.presenting) holding=$($r.holding_targets) overlays=$($r.overlays_shown)" }
    $quiet = { param($r) [int]$r.presenting -eq 0 -and [int]$r.holding_targets -eq 0 -and [int]$r.overlays_shown -eq 0 }

    # E1: the parked one draws nothing; the one on show does.
    $c = Wait-Drawing 'swm-c' $quiet
    Assert ($c -and $c.parked -and (& $quiet $c)) "E1: parked swm-c presents nothing, holds no render targets, shows no popup ($(Row-Text $c))"
    $b = Wait-Drawing 'swm-b' { param($r) [int]$r.presenting -ge 1 }
    Assert ($b -and -not $b.parked -and [int]$b.presenting -eq [int]$b.panes) "E1: swm-b on show presents every pane ($(Row-Text $b))"

    # E2: show swm-c - its panes present again and its banner is back up;
    # swm-b, now parked, goes quiet (popups included).
    $ws = Invoke-GhozttyIpc -Action 'workspaces' -Arguments @('--op=show', '--target=swm-c')
    Assert ($ws -and [string]$ws.data.active -eq 'swm-c') "E2: swm-c goes on show (active='$($ws.data.active)')"
    $c = Wait-Drawing 'swm-c' { param($r) [int]$r.presenting -eq [int]$r.panes -and [int]$r.overlays_shown -ge 1 }
    Assert ($c -and [int]$c.presenting -eq 2 -and [int]$c.holding_targets -eq 2) "E2: shown, both of swm-c's terminals present and hold targets again ($(Row-Text $c))"
    Assert ($c -and [int]$c.overlays_shown -ge 1) "E2: swm-c-right's banner is back on screen ($(Row-Text $c))"
    # T3202: its banner, made while swm-c was parked under the park host, is
    # now owned by the shared window it came into.
    Assert ($c -and $null -ne $c.popups_misowned -and [int]$c.popups_misowned -eq 0) "E2/T3202: swm-c's popups are owned by the shared window (misowned=$($c.popups_misowned))"
    $b = Wait-Drawing 'swm-b' $quiet
    if ($NegativeControl) {
        $script:negReached = $true
        Assert (-not ($b -and (& $quiet $b))) "NEGATIVE CONTROL: swm-b, parked, still draws ($(Row-Text $b))"
    } else {
        Assert ($b -and $b.parked -and (& $quiet $b)) "E2: swm-b, now parked, goes quiet ($(Row-Text $b))"
    }

    # E3: a terminal and a viewer made in the PARKED workspace start held -
    # a fresh surface starts out drawing, and nobody can see this one.
    $doc = Join-Path $work 'parked-view.md'
    [System.IO.File]::WriteAllText($doc, "# parked viewer T3192`n`nfirst`n")
    $r1 = Invoke-SwmCli '+split --target=swm-b --direction=right --name=swm-b-right'
    $r2 = Invoke-SwmCli "+split --target=swm-b --direction=down --name=swm-b-view --view=`"$doc`""
    Start-Sleep -Milliseconds 1500
    $b = Wait-Drawing 'swm-b' { param($r) [int]$r.panes -eq 3 -and (& $quiet $r) }
    Assert ($r1.Code -eq 0 -and $r2.Code -eq 0) "E3: +split and +split --view into parked swm-b succeed (exit $($r1.Code)/$($r2.Code): $(($r1.Text + ' ' + $r2.Text).Trim()))"
    Assert ($b -and $b.parked -and [int]$b.panes -eq 3 -and (& $quiet $b)) "E3: the new terminal and viewer stay quiet while parked ($(Row-Text $b))"
    Assert ((Active-Name) -eq 'swm-c') 'E3: neither split put swm-b on show'

    # E4: back to swm-b: everything in it presents, the viewer included;
    # swm-c goes quiet and takes its banner with it.
    $ws = Invoke-GhozttyIpc -Action 'workspaces' -Arguments @('--op=show', '--target=swm-b')
    $b = Wait-Drawing 'swm-b' { param($r) [int]$r.presenting -eq [int]$r.panes }
    Assert ($b -and [int]$b.panes -eq 3 -and [int]$b.presenting -eq 3) "E4: shown, all three of swm-b's panes present, the viewer too ($(Row-Text $b))"
    Assert ($b -and [int]$b.holding_targets -eq 2) "E4: and its two terminals hold render targets again ($(Row-Text $b))"
    $c = Wait-Drawing 'swm-c' $quiet
    Assert ($c -and $c.parked -and (& $quiet $c)) "E4: swm-c, parked again, is quiet - banner off screen ($(Row-Text $c))"
    # T3202: every pane's popups are owned by the top-level the pane is in -
    # the park host for parked swm-c (its banner was made while it was on
    # show, owned by the shared window), the shared window for swm-b. Left
    # owned by the shared window, a parked workspace's banner died when that
    # window was destroyed under it.
    $ws = Invoke-GhozttyIpc -Action 'workspaces' -Arguments @('--op=state')
    $mis = @($ws.data.workspaces | ForEach-Object { "$($_.name)=$($_.popups_misowned)" })
    Assert (@($ws.data.workspaces | Where-Object { $null -eq $_.popups_misowned -or [int]$_.popups_misowned -ne 0 }).Count -eq 0) "E4/T3202: no pane popup is owned by a window its pane is not in ($($mis -join ' '))"

    # E5: a workspace parked from birth is quiet from its first frame.
    $r = Invoke-GhozttyIpc -Action 'new-window' -Arguments @('--target=swm-f')
    Assert ($r -and $r.success) 'E5: +new-window --target=swm-f (parked) succeeds'
    $f = Wait-Drawing 'swm-f' { param($r) [int]$r.panes -ge 1 -and (& $quiet $r) }
    Assert ($f -and $f.parked -and [int]$f.panes -eq 1 -and (& $quiet $f)) "E5: swm-f, parked from birth, never draws ($(Row-Text $f))"
    $r = Invoke-GhozttyIpc -Action 'close' -Arguments @('--target=swm-f')
    $deadline = (Get-Date).AddSeconds(8)
    do { Start-Sleep -Milliseconds 400; $ws = Invoke-GhozttyIpc -Action 'workspaces' -Arguments @('--op=state') } while ((Get-Date) -lt $deadline -and (Ws-Row $ws 'swm-f'))
    Assert ($r -and $r.success -and -not (Ws-Row $ws 'swm-f')) 'E5: and closes again (fixture cleanup for C)'
    Assert ((Active-Name) -eq 'swm-b') 'E: swm-b is on show, swm-c parked, as D left them'
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'E: no crash'

    # =====================================================================
    # F (T3193): parked content is laid out at the shared window's size. F1
    # (in B1) is the born-parked case. Here: a resize of the shared window
    # reaches every parked workspace once it settles (0.3s), so the grid it
    # shows with is the grid it already had; a tree change in a parked
    # workspace lays it out at once, with no window to do it. Starts where E
    # left it (swm-b on show, swm-c parked with 2 panes); leaves swm-b on
    # show, swm-c parked with 1 pane, and the window at its old size.
    # =====================================================================
    function F-Row([string]$name) { return Ws-Row (Invoke-GhozttyIpc -Action 'workspaces' -Arguments @('--op=state')) $name }
    function Wait-Grid([string]$name, [scriptblock]$until, [int]$seconds = 5) {
        $deadline = (Get-Date).AddSeconds($seconds)
        do {
            $row = F-Row $name
            if ($row -and (& $until $row)) { return $row }
            Start-Sleep -Milliseconds 250
        } while ((Get-Date) -lt $deadline)
        return $row
    }
    function F-LogCount { return @(Get-Content $errlog -ErrorAction SilentlyContinue).Count }
    function F-WaitLog([int]$From, [string]$Pattern, [int]$Ms = 5000) {
        $deadline = (Get-Date).AddMilliseconds($Ms)
        do {
            $hit = @(Get-Content $errlog -ErrorAction SilentlyContinue | Select-Object -Skip $From | Where-Object { $_ -match $Pattern })
            if ($hit.Count -gt 0) { return $true }
            Start-Sleep -Milliseconds 200
        } while ((Get-Date) -lt $deadline)
        return $false
    }
    $c0 = F-Row 'swm-c'
    $c0cols = [int]$c0.cols
    Assert ($c0 -and $c0.parked -and $c0cols -gt 10) "F2: parked swm-c starts with a real grid ($($c0.cols)x$($c0.rows))"

    # F2: shrink the shared window; the parked workspace follows once the
    # resize settles.
    $from = F-LogCount
    [void](Set-TestWindowSize -Window ([IntPtr]$shared) -Width -160 -Height 0 -Grow)
    $c1 = Wait-Grid 'swm-c' { param($r) [int]$r.cols -lt $c0cols }
    Assert ($c1 -and $c1.parked -and [int]$c1.cols -lt $c0cols) "F2: a resize of the shared window reaches parked swm-c ($c0cols -> $($c1.cols) cols)"
    if (-not $ExePath) {
        Assert (F-WaitLog $from 'parked workspaces laid out why=resize-settled count=1') 'F2: laid out once the resize settled, one parked workspace'
    }

    # F3: shown, it already has that grid - nothing re-lays it out.
    $parkedCols = [int]$c1.cols; $parkedRows = [int]$c1.rows
    $ws = Invoke-GhozttyIpc -Action 'workspaces' -Arguments @('--op=show', '--target=swm-c')
    Start-Sleep -Milliseconds 600
    $c2 = F-Row 'swm-c'
    Assert ($c2 -and -not $c2.parked -and [int]$c2.cols -eq $parkedCols -and [int]$c2.rows -eq $parkedRows) "F3: on show swm-c has the grid it had parked ($($c2.cols)x$($c2.rows) vs parked ${parkedCols}x$parkedRows)"
    $ws = Invoke-GhozttyIpc -Action 'workspaces' -Arguments @('--op=show', '--target=swm-b')
    Assert ($ws -and [string]$ws.data.active -eq 'swm-b') 'F3: swm-b back on show'

    # F4: a tree change in a parked workspace lays it out at once: closing
    # swm-c-right gives its left pane the whole width, no window involved.
    $narrow = [int](F-Row 'swm-c').cols
    $r = Invoke-SwmCli '+close --target=swm-c-right'
    $c3 = Wait-Grid 'swm-c' { param($r) [int]$r.panes -eq 1 -and [int]$r.cols -gt $narrow + 10 } 4
    Assert ($r.Code -eq 0 -and $c3 -and $c3.parked -and [int]$c3.panes -eq 1 -and [int]$c3.cols -gt $narrow + 10) "F4: closing a pane in parked swm-c re-lays it at once ($narrow -> $($c3.cols) cols, panes=$($c3.panes), parked=$($c3.parked))"

    # F5: and growing the window back reaches it the same way.
    [void](Set-TestWindowSize -Window ([IntPtr]$shared) -Width 160 -Height 0 -Grow)
    $c4 = Wait-Grid 'swm-c' { param($r) [int]$r.cols -gt [int]$c3.cols }
    Assert ($c4 -and [int]$c4.cols -gt [int]$c3.cols) "F5: growing the window back reaches it too ($($c3.cols) -> $($c4.cols) cols)"
    Assert ((Active-Name) -eq 'swm-b') 'F: swm-b is on show, swm-c parked, as C expects'
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'F: no crash'


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

    # =====================================================================
    # E (T3186): activity never pauses while parked. The window reports the
    # most urgent activity of EVERY workspace (the seam's `activity`, Mac
    # AXWindowActivityState); the title suffix stays the one on show's own; a
    # parked workspace going needs_input asks for attention on the SHARED
    # window (the attention log names its HWND); and a notification click
    # from a parked pane puts that workspace on show.
    # =====================================================================
    function Log-Count { return @(Get-Content $errlog -ErrorAction SilentlyContinue).Count }
    function Wait-LogLine([int]$From, [string]$Pattern, [int]$Ms = 5000) {
        $deadline = (Get-Date).AddMilliseconds($Ms)
        do {
            $hit = @(Get-Content $errlog -ErrorAction SilentlyContinue | Select-Object -Skip $From |
                Where-Object { $_ -match $Pattern }) | Select-Object -First 1
            if ($hit) { return [string]$hit }
            Start-Sleep -Milliseconds 250
        } while ((Get-Date) -lt $deadline)
        return $null
    }
    function Wait-Title([scriptblock]$until, [int]$seconds = 6) {
        $deadline = (Get-Date).AddSeconds($seconds)
        do {
            $t = [string](Get-TestWindowText -Window ([IntPtr]$shared))
            if (& $until $t) { return $t }
            Start-Sleep -Milliseconds 300
        } while ((Get-Date) -lt $deadline)
        return $t
    }

    if ($ExePath) {
        # The attention oracle is the app's stderr log, which only a launch
        # this script made captures.
        $script:skipped++
        Write-Host 'SKIP  E: -ExePath launches without a captured log; section E needs it'
    } else {
        $r = Invoke-GhozttyIpc -Action 'new-window' -Arguments @('--target=swm-f')
        Assert ($r -and $r.success) 'E1: +new-window --target=swm-f (parked) succeeds'
        $ws = Wait-Ws { param($s) $s -and (Ws-Row $s 'swm-f') }
        $f = Ws-Row $ws 'swm-f'
        Assert ($f -and $f.parked -and [string]$ws.data.active -eq 'swm-e') "E1: swm-f is parked behind swm-e (parked=$($f.parked) active='$($ws.data.active)')"
        Assert ([string]$ws.data.activity -eq 'idle') "E1: the window reads idle with every workspace idle (activity='$($ws.data.activity)')"

        # E2: a PARKED workspace starts waiting on a question.
        $mark = Log-Count
        $r = Invoke-GhozttyIpc -Action 'set-state' -Arguments @('--target=swm-f', '--state=needs_input')
        Assert ($r -and $r.success) 'E2: +set-state --target=swm-f (parked) needs_input succeeds'
        $ws = Wait-Ws { param($s) $s -and [string]$s.data.activity -eq 'needs_input' } 5
        Assert ([string]$ws.data.activity -eq 'needs_input') "E2: the window reports the parked workspace's question (activity='$($ws.data.activity)')"
        Assert ([string](Ws-Row $ws 'swm-f').activity -eq 'needs_input' -and [string](Ws-Row $ws 'swm-e').activity -eq 'idle') "E2: swm-f's own state moved while parked; swm-e's did not (f=$((Ws-Row $ws 'swm-f').activity) e=$((Ws-Row $ws 'swm-e').activity))"
        $att = Wait-LogLine $mark 'activity attention needs_input=true .*parked=true'
        Assert ($null -ne $att) "E2: the parked workspace's move into needs_input reached the attention rule (log: $att)"
        if ($att) {
            $m = [regex]::Match($att, 'active=(\w+) flash=(\w+) parked=true target=(\d+)')
            Assert ($m.Success -and [int64]$m.Groups[3].Value -eq $shared) "E2: it asks on the SHARED window (target=$($m.Groups[3].Value) shared=$shared)"
            Assert ($m.Success -and ($m.Groups[2].Value -eq 'true') -eq ($m.Groups[1].Value -eq 'false')) "E2: it flashes exactly when the shared window is in the background (active=$($m.Groups[1].Value) flash=$($m.Groups[2].Value))"
        }
        $rolled = Wait-LogLine $mark 'window activity rolled up state=needs_input'
        Assert ($null -ne $rolled) "E2: the roll-up is logged (log: $rolled)"
        $t = Wait-Title { param($x) $x -and $x -notmatch '\(question\)' } 2
        Assert ($t -notmatch '\(question\)') "E2: the title suffix is the workspace on show's own - no (question) for a parked one (title='$t')"

        # E3: the one on show goes busy - its suffix shows, the window stays
        # at the more urgent parked question.
        $r = Invoke-GhozttyIpc -Action 'set-state' -Arguments @('--target=swm-e', '--state=busy')
        Assert ($r -and $r.success) 'E3: +set-state --target=swm-e busy succeeds'
        $t = Wait-Title { param($x) $x -match '\(busy\)' }
        Assert ($t -match '\(busy\)') "E3: the title carries the on-show workspace's (busy) (title='$t')"
        $ws = Invoke-GhozttyIpc -Action 'workspaces' -Arguments @('--op=state')
        Assert ([string]$ws.data.activity -eq 'needs_input') "E3: the window still reports the parked question, the most urgent (activity='$($ws.data.activity)')"

        # E4: the question answered while parked - the window drops to busy.
        $r = Invoke-GhozttyIpc -Action 'set-state' -Arguments @('--target=swm-f', '--state=idle')
        $ws = Wait-Ws { param($s) $s -and [string]$s.data.activity -eq 'busy' } 5
        Assert ([string]$ws.data.activity -eq 'busy') "E4: answering the parked question leaves the window busy (activity='$($ws.data.activity)')"

        # E5: a desktop notification from a parked pane; its click puts that
        # workspace on show (Mac bringForward). The click is the tray callback
        # posted into OUR message window, as notification-click-focus.ps1 does.
        $msgWnd = Find-TestMessageWindow -ProcessId $app.Pid
        if ($msgWnd -eq [IntPtr]::Zero) {
            Assert $false 'E5: found our app''s message-only window (pid-filtered)'
        } else {
            $cmd = "powershell -NoProfile -Command `"[console]::Write([char]27+']777;notify;Ghoztty;swm-d5'+[char]7)`""
            $nr = Invoke-NativeExact -FilePath $exe -Arguments @('+send-keys', '--target=swm-f', $cmd, 'Enter')
            Assert ($nr.Code -eq 0) "E5: +send-keys delivered the OSC 777 notify to parked swm-f (exit $($nr.Code))"
            Start-Sleep -Seconds 4
            $ws = Invoke-GhozttyIpc -Action 'workspaces' -Arguments @('--op=state')
            Assert ([string]$ws.data.active -eq 'swm-e') "E5: raising a notification did not itself switch (active='$($ws.data.active)')"
            $mark = Log-Count
            # WM_APP_TRAY (WM_APP+3), wparam = the desktop icon's uID (1),
            # lparam = NIN_BALLOONUSERCLICK.
            [void](Send-TestRawMessage -Window $msgWnd -Message ([uint32]0x8003) -WParam ([IntPtr]1) -LParam ([IntPtr]0x0405))
            $ws = Wait-Ws { param($s) $s -and [string]$s.data.active -eq 'swm-f' } 5
            $f = Ws-Row $ws 'swm-f'
            Assert ([string]$ws.data.active -eq 'swm-f' -and $f -and [int64]$f.hwnd -eq $shared) "E5: the click put swm-f on show in the shared window (active='$($ws.data.active)' hwnd=$($f.hwnd))"
            $tops = @(Visible-Tops)
            Assert ($tops.Count -eq 1 -and $tops[0].Hwnd -eq $shared) "E5: still one window ($($tops.Count))"
            $sw = Wait-LogLine $mark 'present_terminal put a parked workspace on show name=swm-f shown=true'
            Assert ($null -ne $sw) "E5: the present path logged the switch (log: $sw)"
        }

        # E6: swm-e, now parked, keeps its own state and still counts.
        $ws = Invoke-GhozttyIpc -Action 'workspaces' -Arguments @('--op=state')
        Assert ([string](Ws-Row $ws 'swm-e').activity -eq 'busy' -and [string]$ws.data.activity -eq 'busy') "E6: the now-parked swm-e's busy still rolls up (e=$((Ws-Row $ws 'swm-e').activity) window=$($ws.data.activity))"
        $t = Wait-Title { param($x) $x -and $x -notmatch '\(busy\)' }
        Assert ($t -notmatch '\(busy\)') "E6: the title follows swm-f, idle, on show (title='$t')"

        # Leave one workspace for C4.
        $r = Invoke-GhozttyIpc -Action 'close' -Arguments @('--target=swm-e')
        $ws = Wait-Ws { param($s) $s -and @($s.data.workspaces).Count -eq 1 }
        Assert (@($ws.data.workspaces).Count -eq 1 -and [string]$ws.data.activity -eq 'idle') "E7: closing the busy parked workspace drops it from the roll-up (activity='$($ws.data.activity)')"
        Assert (-not ($app.Process -and $app.Process.HasExited)) 'E: no crash'
    }

    # =====================================================================
    # G (T3194): every path that opens a window by hand opens a WORKSPACE on
    # show in the shared window - Ctrl+Shift+N (the new_window binding the
    # menus and palette also run) and a pane popped out of its window - and
    # the adopter takes the caret on its own focused pane in the same turn.
    # (+new-window and --focus are B1/B2; the sidebar's + is
    # App.newWindowFromSidebar -> createWindow, the same present call.)
    # =====================================================================
    function Focused-Pane {
        return [int64](Get-TestFocusedWindow -Window ([IntPtr]$shared))
    }
    function Wait-Focused([int64]$want, [int]$seconds = 4) {
        $deadline = (Get-Date).AddSeconds($seconds)
        do {
            $f = Focused-Pane
            if ($f -eq $want) { return $f }
            Start-Sleep -Milliseconds 250
        } while ((Get-Date) -lt $deadline)
        return $f
    }
    $ws = Invoke-GhozttyIpc -Action 'workspaces' -Arguments @('--op=state')
    $homeWs = [string]$ws.data.active
    $countBefore = @($ws.data.workspaces).Count
    Assert ($homeWs -and $countBefore -eq 1) "G: setup: one workspace on show ('$homeWs', $countBefore)"

    # G1: Ctrl+N (Windows' new_window chord, Mac Cmd-N; Ctrl+Shift+N is the
    # machine chooser here, whose New Window button is the same createWindow)
    # makes a workspace and puts it on show in the key's turn.
    Assert (Set-TestActiveWindow -Window ([IntPtr]$shared)) 'G1: setup: the keyboard is in the shared window'
    Start-Sleep -Milliseconds 400
    $homeWsPane = @(Shared-Panes)[0].Hwnd
    $f = Wait-Focused ([int64]$homeWsPane)
    Assert ($f -eq [int64]$homeWsPane) "G1: setup: the caret is on $homeWs's pane (focused=$f pane=$homeWsPane)"
    $sent = Send-TestKeys -Window ([IntPtr]$shared) -Target ([IntPtr]$homeWsPane) -Modifiers ctrl -Key N
    Assert $sent 'G1: Ctrl+N delivered'
    $ws = Wait-Ws { param($s) $s -and @($s.data.workspaces).Count -eq ($countBefore + 1) }
    $newName = [string]$ws.data.active
    $nw = Ws-Row $ws $newName
    Assert (@($ws.data.workspaces).Count -eq ($countBefore + 1) -and $newName -ne $homeWs) "G1: a new workspace was made and is on show (active='$newName', $(@($ws.data.workspaces).Count) workspaces)"
    Assert ($nw -and [int64]$nw.hwnd -eq $shared) "G1: it adopted the SAME window (hwnd=$($nw.hwnd) shared=$shared)"
    $hw = Ws-Row $ws $homeWs
    Assert ($hw -and $hw.parked -and [int64]$hw.hwnd -eq 0) "G1: $homeWs is parked behind it (parked=$($hw.parked))"
    $tops = @(Visible-Tops)
    Assert ($tops.Count -eq 1 -and $tops[0].Hwnd -eq $shared) "G1: no second window appeared ($($tops.Count))"
    $panes = @(Shared-Panes)
    $newPane = if ($panes.Count -eq 1) { [int64]$panes[0].Hwnd } else { 0 }
    Assert ($panes.Count -eq 1 -and $newPane -ne [int64]$homeWsPane) "G1: the window shows only the new workspace's pane ($($panes.Count))"
    $f = Wait-Focused $newPane
    Assert ($newPane -ne 0 -and $f -eq $newPane) "G1: the caret is on the new workspace's pane (focused=$f pane=$newPane)"

    # G2: a switch back puts the caret on the adopter's own focused pane.
    $caretMark = Log-Count
    $ws =Invoke-GhozttyIpc -Action 'workspaces' -Arguments @('--op=show', "--target=$homeWs")
    Assert ($ws -and [string]$ws.data.active -eq $homeWs) "G2: $homeWs is back on show (active='$($ws.data.active)')"
    $f = Wait-Focused ([int64]$homeWsPane)
    Assert ($f -eq [int64]$homeWsPane) "G2: the caret came back to $homeWs's pane, not left on the parked one (focused=$f pane=$homeWsPane)"
    if (-not $ExePath) {
        # The caret line comes before the adopt turn's tab layout and its
        # 'adopted' line: set before the first layout, not after it.
        $after = @(Get-Content $errlog -ErrorAction SilentlyContinue | Select-Object -Skip $caretMark)
        $ci = -1; $ai = -1; $li = -1
        for ($k = 0; $k -lt $after.Count; $k++) {
            if ($ci -lt 0 -and $after[$k] -match 'workspace adopt caret pane=') { $ci = $k }
            if ($ci -ge 0 -and $li -lt 0 -and $after[$k] -match 'window resize cause=tabswitch') { $li = $k }
            if ($ai -lt 0 -and $after[$k] -match "workspace adopted the window name=$([regex]::Escape($homeWs))") { $ai = $k }
        }
        Assert ($ci -ge 0 -and $ai -gt $ci -and $li -gt $ci) "G2: the adopt turn set the caret before its first layout (caret line $ci, layout $li, adopted $ai)"
    }

    # G3: a pane popped out of its window (the header's pop-out button, the
    # same commit as a drag released over the desktop) makes a workspace on
    # show holding THAT pane; the workspace it left is parked with the rest.
    $r = Invoke-SwmCli "+split --target=$homeWs --direction=right"
    $ws = Wait-Ws { param($s) $s -and [int](Ws-Row $s $homeWs).panes -eq 2 }
    Assert ([int](Ws-Row $ws $homeWs).panes -eq 2) "G3: setup: $homeWs has two panes ($((Ws-Row $ws $homeWs).panes))"
    Start-Sleep -Milliseconds 600
    Assert (Set-TestActiveWindow -Window ([IntPtr]$shared)) 'G3: setup: the keyboard is in the shared window'
    Start-Sleep -Milliseconds 300
    [void](Send-TestKeys -Window ([IntPtr]$shared) -Target ([IntPtr](Focused-Pane)) -Modifiers ctrl, shift -Key F9)
    Start-Sleep -Milliseconds 1200
    $boxes = @(Get-TestChildWindows -Window ([IntPtr]$shared) -Class 'GhozttyTerminal' | Where-Object Visible | Sort-Object Left)
    Assert ($boxes.Count -eq 2) "G3: setup: two panes on screen ($($boxes.Count))"
    if ($boxes.Count -eq 2) {
        $popped = $boxes[1]
        $scale = (Get-TestWindowDpi -Window ([IntPtr]$shared)) / 96.0
        $band = Get-TestChromeDip -Dip 24 -Scale $scale
        $btnX = $popped.Left + $popped.Width - (Get-TestChromeDip -Dip 18 -Scale $scale)
        $btnY = $popped.Top - [int]($band / 2)
        $countBefore = @((Invoke-GhozttyIpc -Action 'workspaces' -Arguments @('--op=state')).data.workspaces).Count
        [void](Send-TestMouse -Window ([IntPtr]$shared) -Target ([IntPtr]$shared) -X $btnX -Y $btnY -Action 'down' -Client)
        [void](Send-TestMouse -Window ([IntPtr]$shared) -Target ([IntPtr]$shared) -X $btnX -Y $btnY -Action 'up' -Client)
        $ws = Wait-Ws { param($s) $s -and @($s.data.workspaces).Count -eq ($countBefore + 1) }
        $outName = [string]$ws.data.active
        Assert (@($ws.data.workspaces).Count -eq ($countBefore + 1) -and $outName -ne $homeWs) "G3: the pop-out made a workspace and put it on show (active='$outName', $(@($ws.data.workspaces).Count))"
        $o = Ws-Row $ws $outName
        Assert ($o -and [int64]$o.hwnd -eq $shared -and [int]$o.panes -eq 1) "G3: it is in the SAME window with one pane (hwnd=$($o.hwnd) panes=$($o.panes))"
        $hw = Ws-Row $ws $homeWs
        Assert ($hw -and $hw.parked -and [int]$hw.panes -eq 1) "G3: $homeWs is parked with the pane it kept (parked=$($hw.parked) panes=$($hw.panes))"
        $panes = @(Shared-Panes)
        Assert ($panes.Count -eq 1 -and [int64]$panes[0].Hwnd -eq [int64]$popped.Hwnd) "G3: the window shows the popped pane itself - the same handle ($(@($panes | ForEach-Object Hwnd) -join ',') vs $($popped.Hwnd))"
        $tops = @(Visible-Tops)
        Assert ($tops.Count -eq 1 -and $tops[0].Hwnd -eq $shared) "G3: no second window appeared ($($tops.Count))"
        $f = Wait-Focused ([int64]$popped.Hwnd)
        Assert ($f -eq [int64]$popped.Hwnd) "G3: the caret is on the popped pane (focused=$f)"
    }
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'G: no crash'

    # Back to one workspace for C4: close every other one.
    $ws = Invoke-GhozttyIpc -Action 'workspaces' -Arguments @('--op=state')
    foreach ($n in @($ws.data.workspaces | ForEach-Object { [string]$_.name } | Select-Object -Skip 1)) {
        [void](Invoke-GhozttyIpc -Action 'close' -Arguments @("--target=$n", '--force'))
    }
    $ws = Wait-Ws { param($s) $s -and @($s.data.workspaces).Count -eq 1 }
    Assert (@($ws.data.workspaces).Count -eq 1) "G: back to one workspace for C4 ($(@($ws.data.workspaces).Count))"

    # =====================================================================
    # H (T3182): no tabs in a workspace. new_tab is a new workspace, and
    # goto_tab walks the workspaces in the all-windows list's order (the
    # app's own `goto_tab ... over workspaces` line names the order index).
    # =====================================================================
    $ws = Invoke-GhozttyIpc -Action 'workspaces' -Arguments @('--op=state')
    $h0 = [string]$ws.data.active
    $r0 = Ws-Row $ws $h0
    Assert ($r0 -and [int]$r0.tabs -eq 1 -and $r0.tab_bar -eq $false) "H0: the workspace on show has one tab and no strip under window-show-tab-bar=always (tabs=$($r0.tabs) tab_bar=$($r0.tab_bar))"
    function H-Key([string[]]$mods, [string]$key) {
        [void](Set-TestActiveWindow -Window ([IntPtr]$shared))
        Start-Sleep -Milliseconds 250
        return (Send-TestKeys -Window ([IntPtr]$shared) -Target ([IntPtr](Focused-Pane)) -Modifiers $mods -Key $key)
    }
    # H1: Ctrl+T (new_tab) twice: two workspaces, each on show as it opens.
    $made = @($h0)
    foreach ($k in 1..2) {
        $before = @((Invoke-GhozttyIpc -Action 'workspaces' -Arguments @('--op=state')).data.workspaces).Count
        Assert (H-Key @('ctrl') 'T') "H1.$($k): Ctrl+T delivered"
        $ws = Wait-Ws { param($s) $s -and @($s.data.workspaces).Count -eq ($before + 1) }
        $nn = [string]$ws.data.active
        $nr = Ws-Row $ws $nn
        Assert (@($ws.data.workspaces).Count -eq ($before + 1) -and $made -notcontains $nn) "H1.$($k): new_tab made a workspace and put it on show (active='$nn', $(@($ws.data.workspaces).Count))"
        Assert ($nr -and [int64]$nr.hwnd -eq $shared -and [int]$nr.tabs -eq 1 -and $nr.tab_bar -eq $false) "H1.$($k): in the SAME window, one tab, no strip (hwnd=$($nr.hwnd) tabs=$($nr.tabs) tab_bar=$($nr.tab_bar))"
        $pr = Ws-Row $ws $made[-1]
        Assert ($pr -and $pr.parked -and [int]$pr.tabs -eq 1) "H1.$($k): the one it left is parked, still one tab - no tab was added to it (tabs=$($pr.tabs))"
        $made += $nn
    }
    $tops = @(Visible-Tops)
    Assert ($tops.Count -eq 1 -and $tops[0].Hwnd -eq $shared) "I1: one window on screen ($($tops.Count))"

    # H2: goto_tab walks them. Ctrl+1 goes to the first in the list's order,
    # Ctrl+9 (last_tab) to the last, next/previous step and wrap. Each
    # landing is read back from the app's own line and the seam.
    function H-Goto([string[]]$mods, [string]$key, [string]$label) {
        $mark = Log-Count
        Assert (H-Key $mods $key) "$($label): chord delivered"
        $line = Wait-LogLine $mark 'goto_tab -?\d+ over workspaces: '
        Start-Sleep -Milliseconds 400
        $s = Invoke-GhozttyIpc -Action 'workspaces' -Arguments @('--op=state')
        return @{ Line = [string]$line; Active = [string]$s.data.active; State = $s }
    }
    if ($ExePath) {
        Assert $true 'H2: skipped (no log under -ExePath)'
    } else {
        $g = H-Goto @('ctrl') '1' 'H2 Ctrl+1'
        Assert ($g.Line -match 'goto_tab 1 over workspaces: (\d+ -> 0 of 3|nowhere else to go \(3 listed\))') "I2: Ctrl+1 is goto_tab over the workspaces, landing on the list's first ($($g.Line))"
        $listFirst = $g.Active
        $g = H-Goto @('ctrl') '9' 'H2 Ctrl+9'
        $okLast = ($g.Line -match 'goto_tab -3 over workspaces: \d+ -> 2 of 3 name=(\S+)') -and $g.Active -eq $Matches[1]
        Assert $okLast "I2: Ctrl+9 (last_tab) puts the list's last on show (active='$($g.Active)'; $($g.Line))"
        $listLast = $g.Active
        Assert ($listLast -ne $listFirst) "I2: first and last are different workspaces ($listFirst / $listLast)"
        $g = H-Goto @('ctrl', 'shift') 'F7' 'H2 next'
        Assert ($g.Line -match 'goto_tab -2 over workspaces: 2 -> 0 of 3' -and $g.Active -eq $listFirst) "I2: next from the last wraps to the first (active='$($g.Active)'; $($g.Line))"
        $g = H-Goto @('ctrl', 'shift') 'F8' 'H2 previous'
        Assert ($g.Line -match 'goto_tab -1 over workspaces: 0 -> 2 of 3' -and $g.Active -eq $listLast) "I2: previous from the first wraps to the last (active='$($g.Active)'; $($g.Line))"
        $g = H-Goto @('ctrl', 'shift') 'F8' 'H2 previous again'
        $okMid = ($g.Line -match 'goto_tab -1 over workspaces: 2 -> 1 of 3 name=(\S+)') -and $g.Active -eq $Matches[1]
        Assert ($okMid -and $g.Active -ne $listFirst -and $g.Active -ne $listLast) "I2: previous again is the middle one (active='$($g.Active)'; $($g.Line))"
        $sh = Ws-Row $g.State $g.Active
        Assert ($sh -and [int64]$sh.hwnd -eq $shared -and [int]$g.State.data.windows_with_hwnd -eq 1) "I2: each landing is the SAME window, one HWND held (windows_with_hwnd=$($g.State.data.windows_with_hwnd))"
        $panes = @(Shared-Panes)
        Assert ($panes.Count -eq 1) "I2: the window shows only the one on show's pane ($($panes.Count))"
    }
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'H: no crash'
    $ws = Invoke-GhozttyIpc -Action 'workspaces' -Arguments @('--op=state')
    foreach ($n in @($ws.data.workspaces | ForEach-Object { [string]$_.name } | Select-Object -Skip 1)) {
        [void](Invoke-GhozttyIpc -Action 'close' -Arguments @("--target=$n", '--force'))
    }
    $ws = Wait-Ws { param($s) $s -and @($s.data.workspaces).Count -eq 1 }
    Assert (@($ws.data.workspaces).Count -eq 1) "H: back to one workspace for C4 ($(@($ws.data.workspaces).Count))"

    # =====================================================================
    # J (T3183): the shade crossfades on a switch - the old workspace's
    # gradient laid over the new one's and faded out over 0.35s - and only
    # between two different gradients. Read from the seam's `desk_fade`
    # (on / from_seed / started / frames / last_keep) and `desks`, the count
    # of desks actually rendered with the fade laid on.
    # =====================================================================
    $ws = Invoke-GhozttyIpc -Action 'workspaces' -Arguments @('--op=state')
    $j0 = [string]$ws.data.active
    $j0Seed = [uint64](Ws-Row $ws $j0).desk_seed
    [void](Invoke-GhozttyIpc -Action 'new-window' -Arguments @('--target=swm-j1', '--color=random'))
    [void](Invoke-GhozttyIpc -Action 'new-window' -Arguments @('--target=swm-j2'))
    [void](Invoke-GhozttyIpc -Action 'new-window' -Arguments @('--target=swm-j3'))
    $ws = Wait-Ws { param($s) $s -and @($s.data.workspaces).Count -eq 4 }
    $j1 = Ws-Row $ws 'swm-j1'
    $j2 = Ws-Row $ws 'swm-j2'
    $j1Seed = if ($j1) { [uint64]$j1.desk_seed } else { 0 }
    Assert ($j1 -and $j1.parked -and $j1Seed -ne 0 -and $j1Seed -ne $j0Seed) "J0: swm-j1 (--color=random) is parked with a gradient of its own (seed=$j1Seed vs on show $j0Seed)"
    $j3 = Ws-Row $ws 'swm-j3'
    Assert ($j2 -and $j3 -and [uint64]$j2.desk_seed -eq [uint64]$j3.desk_seed) "J0: swm-j2 and swm-j3 (plain) share a shade, the ocean ($($j2.desk_seed) / $($j3.desk_seed))"
    # J1: a switch to another gradient starts the fade FROM the one that
    # left, its first frame the old desk whole. The show's own answer is the
    # state the instant after the hand-off.
    $s = Invoke-GhozttyIpc -Action 'workspaces' -Arguments @('--op=show', '--target=swm-j1')
    $f = (Ws-Row $s 'swm-j1').desk_fade
    Assert ($s -and $s.data.shown -and $f -and $f.on -and [uint64]$f.from_seed -eq $j0Seed -and [int]$f.started -eq 1 -and [int]$f.last_keep -eq 255) "J1: the switch starts a fade from $j0's shade, old desk whole (on=$($f.on) from=$($f.from_seed) started=$($f.started) keep=$($f.last_keep))"
    Start-Sleep -Milliseconds 900
    $s = Invoke-GhozttyIpc -Action 'workspaces' -Arguments @('--op=state')
    $f = (Ws-Row $s 'swm-j1').desk_fade
    # 0.35s on the frame clock is ~20 frames at 60 Hz; 4 is a floor a loaded
    # box clears while a fade that never stepped (0) or never reached the
    # pixels (desks 0) cannot.
    Assert ($f -and -not $f.on -and [int]$f.frames -ge 4 -and [int]$f.desks -ge 4) "J1: 0.9s later the fade is over, having stepped and drawn (on=$($f.on) frames=$($f.frames) desks=$($f.desks))"
    Assert ($f -and [int]$f.last_keep -lt 128) "J1: its last frame had the old desk mostly gone (last_keep=$($f.last_keep))"
    # J2: back the other way fades too; the one that left is parked, no fade.
    $s = Invoke-GhozttyIpc -Action 'workspaces' -Arguments @('--op=show', "--target=$j0")
    $f0 = (Ws-Row $s $j0).desk_fade
    $fl = (Ws-Row $s 'swm-j1').desk_fade
    Assert ($f0 -and $f0.on -and [uint64]$f0.from_seed -eq $j1Seed) "J2: switching back fades from swm-j1's shade (on=$($f0.on) from=$($f0.from_seed))"
    Assert ($fl -and -not $fl.on) "J2: the workspace that left carries no fade parked (on=$($fl.on))"
    # J2b: a switch MID-fade - $j0's is still running - ends it there: parked,
    # it has nothing to fade, and the adopter starts its own from $j0's shade.
    $s = Invoke-GhozttyIpc -Action 'workspaces' -Arguments @('--op=show', '--target=swm-j1')
    $f0 = (Ws-Row $s $j0).desk_fade
    $fl = (Ws-Row $s 'swm-j1').desk_fade
    Assert ($f0 -and -not $f0.on -and $fl -and $fl.on -and [uint64]$fl.from_seed -eq $j0Seed -and [int]$fl.started -eq 2) "J2b: a switch mid-fade ends the parked one's and starts the adopter's (left on=$($f0.on); adopter on=$($fl.on) from=$($fl.from_seed) started=$($fl.started))"
    Start-Sleep -Milliseconds 900
    # J3: the same shade on both sides is no fade at all (Mac
    # `leavingShade != deskVariant`): swm-j2 on show (fading in from the
    # hand-opened gradient), then swm-j3, ocean to ocean.
    [void](Invoke-GhozttyIpc -Action 'workspaces' -Arguments @('--op=show', '--target=swm-j2'))
    Start-Sleep -Milliseconds 900
    $s = Invoke-GhozttyIpc -Action 'workspaces' -Arguments @('--op=show', '--target=swm-j3')
    $f3 = (Ws-Row $s 'swm-j3').desk_fade
    Assert ($s -and $s.data.shown -and [string]$s.data.active -eq 'swm-j3') "J3: swm-j3 is on show (active='$($s.data.active)')"
    Assert ($f3 -and -not $f3.on -and [int]$f3.started -eq 0 -and [int]$f3.desks -eq 0) "J3: same shade to same shade starts no fade (on=$($f3.on) started=$($f3.started) desks=$($f3.desks))"
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'J: no crash'
    $ws = Invoke-GhozttyIpc -Action 'workspaces' -Arguments @('--op=state')
    foreach ($n in @($ws.data.workspaces | ForEach-Object { [string]$_.name } | Select-Object -Skip 1)) {
        [void](Invoke-GhozttyIpc -Action 'close' -Arguments @("--target=$n", '--force'))
    }
    $ws = Wait-Ws { param($s) $s -and @($s.data.workspaces).Count -eq 1 }
    Assert (@($ws.data.workspaces).Count -eq 1) "J: back to one workspace for C4 ($(@($ws.data.workspaces).Count))"

    # =====================================================================
    # L (T3200): undo of a workspace close brings it back ON SHOW, in the
    # same window, with the same shell (its scrollback still holds what was
    # typed before the close). Closing the one on show hands the window on
    # at once, as C3; the closed one waits out undo-timeout (5s default)
    # off the list, counted by the seam's `closed_for_undo`; Ctrl+Shift+Z in
    # the shared window brings it back; a parked one's close undoes onto show
    # too; and when the undo runs out it closes for real.
    # =====================================================================
    function L-Undo {
        [void](Set-TestActiveWindow -Window ([IntPtr]$shared))
        Start-Sleep -Milliseconds 250
        return (Send-TestKeys -Window ([IntPtr]$shared) -Target ([IntPtr](Focused-Pane)) -Modifiers @('ctrl', 'shift') -Key 'Z')
    }
    function L-Read([string]$name) { return ([string](Invoke-SwmCli "+read --name=$name --lines=60").Text -replace '\r?\n', '') }
    $ws = Invoke-GhozttyIpc -Action 'workspaces' -Arguments @('--op=state')
    $kHome = [string]$ws.data.active
    $r = Invoke-GhozttyIpc -Action 'new-window' -Arguments @('--target=swm-k1', '--focus')
    Assert ($r -and $r.success) 'L: setup: +new-window --target=swm-k1 --focus'
    $ws = Wait-Ws { param($s) $s -and [string]$s.data.active -eq 'swm-k1' }
    Assert ([string]$ws.data.active -eq 'swm-k1' -and [int64](Ws-Row $ws 'swm-k1').hwnd -eq $shared) "L: setup: swm-k1 on show in the shared window (active='$($ws.data.active)')"
    Start-Sleep -Milliseconds 1500
    [void](Invoke-SwmCli '+send-keys --target=swm-k1 "echo K1-MARK-3200" Enter')
    $deadline = (Get-Date).AddSeconds(6)
    do { Start-Sleep -Milliseconds 300; $k1Text = L-Read 'swm-k1' } while ((Get-Date) -lt $deadline -and $k1Text -notmatch 'K1-MARK-3200')
    Assert ($k1Text -match 'K1-MARK-3200') 'L: setup: swm-k1''s shell echoed its mark'

    # L1: close the one on show - the window goes to the one shown before it.
    $r = Invoke-GhozttyIpc -Action 'close' -Arguments @('--target=swm-k1')
    Assert ($r -and $r.success) 'L1: +close --target=swm-k1 (on show) succeeds'
    $ws = Wait-Ws { param($s) $s -and -not (Ws-Row $s 'swm-k1') -and [string]$s.data.active -eq $kHome }
    Assert ([string]$ws.data.active -eq $kHome -and [int64](Ws-Row $ws $kHome).hwnd -eq $shared) "L1: $kHome took the same window back (active='$($ws.data.active)')"
    Assert ([int]$ws.data.closed_for_undo -eq 1) "L1: swm-k1 waits out its undo (closed_for_undo=$($ws.data.closed_for_undo))"
    $tops = @(Visible-Tops)
    Assert ($tops.Count -eq 1 -and $tops[0].Hwnd -eq $shared) "L1: one window, the shared one, still on screen ($($tops.Count))"

    # L2: Ctrl+Shift+Z puts it back on show, same window, same shell.
    Assert (L-Undo) 'L2: Ctrl+Shift+Z delivered'
    $ws = Wait-Ws { param($s) $s -and [string]$s.data.active -eq 'swm-k1' }
    $k1 = Ws-Row $ws 'swm-k1'
    Assert ($k1 -and [string]$ws.data.active -eq 'swm-k1' -and [int64]$k1.hwnd -eq $shared) "L2: undo brought swm-k1 back on show in the shared window (active='$($ws.data.active)' hwnd=$(if ($k1) { $k1.hwnd }))"
    Assert ([int]$ws.data.closed_for_undo -eq 0 -and @($ws.data.workspaces).Count -eq 2) "L2: listed again, nothing waiting (closed_for_undo=$($ws.data.closed_for_undo), $(@($ws.data.workspaces).Count) workspaces)"
    Assert ((L-Read 'swm-k1') -match 'K1-MARK-3200') 'L2: the same shell - its scrollback still holds the mark, and +read reaches it by name'
    $kp = Ws-Row $ws $kHome
    Assert ($kp -and $kp.parked -and [int]$kp.presenting -eq 0) "L2: $kHome is parked again and draws nothing (parked=$($kp.parked) presenting=$($kp.presenting))"
    $tops = @(Visible-Tops)
    Assert ($tops.Count -eq 1 -and $tops[0].Hwnd -eq $shared) "L2: still the one window ($($tops.Count))"

    # L3: a PARKED workspace's close undoes onto show as well (Mac: undo
    # brings the workspace back on show).
    [void](Invoke-GhozttyIpc -Action 'workspaces' -Arguments @('--op=show', '--target=' + $kHome))
    $ws = Wait-Ws { param($s) $s -and [string]$s.data.active -eq $kHome }
    $r = Invoke-GhozttyIpc -Action 'close' -Arguments @('--target=swm-k1')
    Assert ($r -and $r.success) 'L3: +close --target=swm-k1 (parked) succeeds'
    $ws = Wait-Ws { param($s) $s -and -not (Ws-Row $s 'swm-k1') }
    Assert ([string]$ws.data.active -eq $kHome -and [int]$ws.data.closed_for_undo -eq 1) "L3: $kHome kept the window, swm-k1 waits (active='$($ws.data.active)' closed_for_undo=$($ws.data.closed_for_undo))"
    Assert (L-Undo) 'L3: Ctrl+Shift+Z delivered'
    $ws = Wait-Ws { param($s) $s -and [string]$s.data.active -eq 'swm-k1' }
    Assert ([string]$ws.data.active -eq 'swm-k1' -and [int64](Ws-Row $ws 'swm-k1').hwnd -eq $shared) "L3: undo put the parked one's close back ON SHOW (active='$($ws.data.active)')"

    # L4: left alone, the undo runs out and the close is real: the workspace
    # is gone for good, and its shell with it (+read finds no such target).
    $r = Invoke-GhozttyIpc -Action 'close' -Arguments @('--target=swm-k1')
    Assert ($r -and $r.success) 'L4: +close --target=swm-k1 again'
    $ws = Wait-Ws { param($s) $s -and [int]$s.data.closed_for_undo -eq 1 }
    Assert ([int]$ws.data.closed_for_undo -eq 1) "L4: waiting out the undo (closed_for_undo=$($ws.data.closed_for_undo))"
    $ws = Wait-Ws { param($s) $s -and [int]$s.data.closed_for_undo -eq 0 } 14
    Assert ([int]$ws.data.closed_for_undo -eq 0 -and @($ws.data.workspaces).Count -eq 1 -and [string]$ws.data.active -eq $kHome) "L4: the undo ran out - nothing waiting, $kHome alone on show (closed_for_undo=$($ws.data.closed_for_undo), active='$($ws.data.active)')"
    $gone = Invoke-SwmCli '+read --name=swm-k1 --lines=60'
    Assert ($gone.Code -ne 0 -and ($gone.Text -replace '\r?\n', '') -notmatch 'K1-MARK-3200') "L4: swm-k1 is gone for real (+read no longer reaches it: exit $($gone.Code))"
    Assert (L-Undo) 'L4: Ctrl+Shift+Z delivered after the expiry'
    Start-Sleep -Milliseconds 1200
    $ws = Invoke-GhozttyIpc -Action 'workspaces' -Arguments @('--op=state')
    Assert (@($ws.data.workspaces).Count -eq 1 -and [string]$ws.data.active -eq $kHome) "L4: an undo after the expiry brings nothing back ($(@($ws.data.workspaces).Count) workspaces)"
    $tops = @(Visible-Tops)
    Assert ($tops.Count -eq 1 -and $tops[0].Hwnd -eq $shared) "L4: the shared window never moved ($($tops.Count))"
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'L: no crash'

    # C4: the last workspace's close closes the window.
    [void](Send-TestSysCommand -Window ([IntPtr]$shared) -Command 'close')
    $deadline = (Get-Date).AddSeconds(8)
    do { Start-Sleep -Milliseconds 400; $tops = @(Visible-Tops) } while ((Get-Date) -lt $deadline -and $tops.Count -gt 0)
    Assert ($tops.Count -eq 0) "C4: the last workspace's close closed the window ($($tops.Count) left)"

    # =====================================================================
    # I (T3187): a relaunch brings every workspace back in ONE window with
    # the one that was on show on show again; the manifest it reads is
    # windows at one frame, frontmost marked, which `separate` mode restores
    # as windows at that frame with the frontmost on top.
    # =====================================================================
    Stop-Process -Id $app.Pid -Force -ErrorAction SilentlyContinue
    Kill-RepoInstances
    [System.IO.File]::WriteAllText($cfgFile, "macos-window-mode = single`n")
    $manifestPath = Get-GhozttySessionLayoutPath -Root $persistLocal
    $app = Start-App 'launch I1 (single, persisted)' -Persist
    if (-not $app) { exit 1 }
    $ws = Wait-Ws { param($s) $s -and $s.data.active }
    $h1 = [string]$ws.data.active
    $shared = [int64](Ws-Row $ws $h1).hwnd
    Assert ($h1 -and $shared -ne 0) "I: setup: the first workspace has the window ('$h1', hwnd=$shared)"
    [void](Invoke-GhozttyIpc -Action 'new-window' -Arguments @('--target=swm-h2', '--title=SWM-H2-FRONT'))
    [void](Invoke-GhozttyIpc -Action 'new-window' -Arguments @('--target=swm-h3'))
    $ws = Wait-Ws { param($s) $s -and @($s.data.workspaces).Count -eq 3 }
    Assert (@($ws.data.workspaces).Count -eq 3 -and [string]$ws.data.active -eq $h1) "I: setup: three workspaces, $h1 on show ($(@($ws.data.workspaces).Count), active='$($ws.data.active)')"
    # A window placement the restore must carry, distinct from the default.
    [void](Set-TestWindowPos -Window ([IntPtr]$shared) -X 120 -Y 90)
    [void](Set-TestWindowSize -Window ([IntPtr]$shared) -Width 900 -Height 560)
    Start-Sleep -Milliseconds 600
    # The switch the relaunch must remember: swm-h2, never activated as a
    # window of its own, goes on show.
    $ws = Invoke-GhozttyIpc -Action 'workspaces' -Arguments @('--op=show', '--target=swm-h2')
    Assert ($ws -and [string]$ws.data.active -eq 'swm-h2') "I: setup: swm-h2 is on show (active='$($ws.data.active)')"
    $tops = @(Visible-Tops)
    $rect = if ($tops.Count -eq 1) { $tops[0] } else { $null }

    # I1: the manifest - three entries, one frame, swm-h2 in front.
    $deadline = (Get-Date).AddSeconds(15)
    $m = $null
    do {
        Start-Sleep -Milliseconds 400
        try { $m = Get-Content $manifestPath -Raw -ErrorAction Stop | ConvertFrom-Json } catch { $m = $null }
        $ok = $m -and @($m.windows).Count -eq 3 -and @(@($m.windows) | Where-Object { $_.frontmost -eq $true -and [string]$_.ipc_name -eq 'swm-h2' }).Count -eq 1
    } while ((Get-Date) -lt $deadline -and -not $ok)
    $mw = @(if ($m) { @($m.windows) | ForEach-Object { $_ } })
    Assert ($mw.Count -eq 3) "I1: the manifest holds every workspace ($($mw.Count) entries)"
    $front = @($mw | Where-Object { $_.frontmost -eq $true } | ForEach-Object { [string]$_.ipc_name })
    Assert ($front.Count -eq 1 -and $front[0] -eq 'swm-h2') "I1: the workspace on show is the one marked frontmost (got '$($front -join ',')')"
    $framed = @($mw | Where-Object { $null -ne $_.frame })
    $frames = @($framed | ForEach-Object { "$($_.frame.x),$($_.frame.y),$($_.frame.w),$($_.frame.h)" } | Select-Object -Unique)
    Assert ($framed.Count -eq 3 -and $frames.Count -eq 1) "I1: every entry - the parked ones too - carries the window's frame ($($framed.Count) framed: $($frames -join ' | '))"
    if ($rect -and $framed.Count -gt 0) {
        $f0 = $framed[0].frame
        Assert ([math]::Abs([int]$f0.x - $rect.Left) -le 2 -and [math]::Abs([int]$f0.w - $rect.Width) -le 2) "I1: that frame is the shared window's ($($f0.x),$($f0.y) $($f0.w)x$($f0.h) vs $($rect.Left),$($rect.Top) $($rect.Width)x$($rect.Height))"
    }

    # I2: relaunch in single mode - one window, three workspaces, swm-h2 on
    # show.
    Stop-Process -Id $app.Pid -Force -ErrorAction SilentlyContinue
    Kill-RepoInstances
    $app = Start-App 'launch I2 (single, restore)' -Persist
    if (-not $app) { exit 1 }
    $deadline = (Get-Date).AddSeconds(30)
    do {
        Start-Sleep -Milliseconds 500
        $ws = Invoke-GhozttyIpc -Action 'workspaces' -Arguments @('--op=state')
    } while ((Get-Date) -lt $deadline -and -not ($ws -and @($ws.data.workspaces).Count -ge 3))
    $names = @($ws.data.workspaces | ForEach-Object { [string]$_.name })
    Assert ($names.Count -eq 3 -and $names -contains 'swm-h2' -and $names -contains 'swm-h3') "I2: every workspace came back ($($names -join ','))"
    Assert ([string]$ws.data.active -eq 'swm-h2') "I2: the one that was on show is on show again (active='$($ws.data.active)')"
    Assert ($ws -and [int]$ws.data.windows_with_hwnd -eq 1) "I2: they share ONE window (windows_with_hwnd=$($ws.data.windows_with_hwnd))"
    $parked = @($ws.data.workspaces | Where-Object { $_.parked })
    Assert ($parked.Count -eq 2) "I2: the other two are parked ($($parked.Count))"
    Start-Sleep -Milliseconds 800
    $tops = @(Visible-Tops)
    Assert ($tops.Count -eq 1) "I2: one window on screen ($($tops.Count))"
    if ($tops.Count -eq 1 -and $framed.Count -gt 0) {
        $f0 = $framed[0].frame
        Assert ([math]::Abs($tops[0].Left - [int]$f0.x) -le 2 -and [math]::Abs($tops[0].Width - [int]$f0.w) -le 2) "I2: at the saved frame ($($tops[0].Left),$($tops[0].Top) $($tops[0].Width)x$($tops[0].Height))"
    }
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'I2: no crash'

    # I3: the same manifest in `separate` mode - three windows at one frame,
    # swm-h2 on top.
    Stop-Process -Id $app.Pid -Force -ErrorAction SilentlyContinue
    Kill-RepoInstances
    [System.IO.File]::WriteAllText($cfgFile, "macos-window-mode = separate`n")
    $app = Start-App 'launch I3 (separate, restore)' -Persist
    if (-not $app) { exit 1 }
    $deadline = (Get-Date).AddSeconds(30)
    do { Start-Sleep -Milliseconds 500; $tops = @(Visible-Tops) } while ((Get-Date) -lt $deadline -and $tops.Count -lt 3)
    Start-Sleep -Milliseconds 1500
    $tops = @(Visible-Tops)
    Assert ($tops.Count -eq 3) "I3: separate mode restores each workspace as a window ($($tops.Count))"
    $at = @($tops | ForEach-Object { "$($_.Left),$($_.Top),$($_.Width),$($_.Height)" } | Select-Object -Unique)
    Assert ($tops.Count -eq 3 -and $at.Count -eq 1) "I3: all at the one frame ($($at -join ' | '))"
    $topText = if ($tops.Count -gt 0) { [string](Get-TestWindowText -Window ([IntPtr]$tops[0].Hwnd)) } else { '' }
    Assert ($topText -match 'SWM-H2-FRONT') "I3: the frontmost (swm-h2) is on top (top window reads '$topText')"
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'I3: no crash'

    # I4: a window with TWO tabs, saved in separate mode, comes back in
    # single mode (which has no tabs, T3182) as a workspace per tab - its
    # active tab keeping the window's name and on show.
    if ($tops.Count -gt 0) {
        $h2 = [IntPtr]$tops[0].Hwnd
        $h2Pane = @(Get-TestChildWindows -Window $h2 -Class 'GhozttyTerminal' | Where-Object Visible | Select-Object -First 1)
        $paneTarget = if ($h2Pane.Count -eq 1) { [IntPtr]$h2Pane[0].Hwnd } else { [IntPtr]::Zero }
        [void](Set-TestActiveWindow -Window $h2)
        Start-Sleep -Milliseconds 300
        [void](Send-TestKeys -Window $h2 -Target $paneTarget -Modifiers ctrl -Key T)
    }
    # Focus it by name too, so its focus stamp is the newest and the
    # separate-mode capture marks it frontmost.
    [void](Invoke-GhozttyIpc -Action 'new-window' -Arguments @('--target=swm-h2', '--focus'))
    $deadline = (Get-Date).AddSeconds(15)
    do {
        Start-Sleep -Milliseconds 400
        try { $m = Get-Content $manifestPath -Raw -ErrorAction Stop | ConvertFrom-Json } catch { $m = $null }
        $e2 = if ($m) { @($m.windows) | Where-Object { [string]$_.ipc_name -eq 'swm-h2' } | Select-Object -First 1 } else { $null }
        $ok = $e2 -and @($e2.tabs).Count -eq 2 -and $e2.frontmost -eq $true
    } while ((Get-Date) -lt $deadline -and -not $ok)
    Assert ($e2 -and @($e2.tabs).Count -eq 2) "I4: setup: swm-h2 is saved with two tabs ($(if ($e2) { @($e2.tabs).Count } else { 'no entry' }))"
    Assert ($e2 -and $e2.frontmost -eq $true) "I4: setup: and in front (frontmost=$(if ($e2) { $e2.frontmost }))"
    Stop-Process -Id $app.Pid -Force -ErrorAction SilentlyContinue
    Kill-RepoInstances
    [System.IO.File]::WriteAllText($cfgFile, "macos-window-mode = single`n")
    $app = Start-App 'launch I4 (single, a two-tab window)' -Persist
    if (-not $app) { exit 1 }
    $deadline = (Get-Date).AddSeconds(30)
    do {
        Start-Sleep -Milliseconds 500
        $ws = Invoke-GhozttyIpc -Action 'workspaces' -Arguments @('--op=state')
    } while ((Get-Date) -lt $deadline -and -not ($ws -and @($ws.data.workspaces).Count -ge 4))
    $rows = @($ws.data.workspaces)
    Assert ($rows.Count -eq 4) "I4: three windows, one with two tabs, come back as four workspaces ($(@($rows | ForEach-Object name) -join ','))"
    Assert ([string]$ws.data.active -eq 'swm-h2') "I4: the two-tab window's active tab keeps its name and is on show (active='$($ws.data.active)')"
    $multi = @($rows | Where-Object { [int]$_.tabs -ne 1 })
    Assert ($rows.Count -gt 0 -and $multi.Count -eq 0) "I4: every workspace holds exactly one tab ($(@($rows | ForEach-Object { "$($_.name)=$($_.tabs)" }) -join ','))"
    Assert ($ws -and [int]$ws.data.windows_with_hwnd -eq 1) "I4: still ONE window (windows_with_hwnd=$($ws.data.windows_with_hwnd))"
    if (-not $ExePath) {
        $split = @(Select-String -Path $errlog -Pattern "had 2 tabs; single-window mode brought back 2 workspace" -ErrorAction SilentlyContinue)
        Assert ($split.Count -ge 1) "I4: the restore says it split the window's tabs ($($split.Count) line)"
    }
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'I4: no crash'
    Stop-Process -Id $app.Pid -Force -ErrorAction SilentlyContinue
    [void](Stop-RepoGhoztty -Exe $exe -SettleMs 500)
    $app = $null

    # =====================================================================
    # K (T3205): the pane sidebar's all-windows list switches workspaces,
    # and the adopter's sidebar comes back the way the shared one is.
    # =====================================================================
    if ($ExePath) {
        $script:skipped++
        Write-Host 'SKIP  K: reads the app log, which -ExePath does not capture'
    } else {
        [System.IO.File]::WriteAllText($cfgFile, "macos-window-mode = single`n")
        # Collapsed at launch whatever the debug build remembers, so the
        # parked workspaces are born with the sidebar collapsed.
        $app = Start-App 'launch K (single, sidebar collapsed)' -Extra @('--macos-pane-sidebar=collapsed')
        if (-not $app) { exit 1 }
        $ws = Wait-Ws { param($s) $s -and $s.data.active }
        $j1 = [string]$ws.data.active
        $shared = [int64](Ws-Row $ws $j1).hwnd
        $dpi = Get-TestWindowDpi -Window ([IntPtr]$shared)
        $jScale = if ($dpi -gt 0) { $dpi / 96.0 } else { 1.0 }
        function K-Px([double]$d) { return [int][math]::Floor($d * $jScale + 0.5) }
        [void](Set-TestWindowSize -Window ([IntPtr]$shared) -Width (K-Px 1100) -Height (K-Px 900))
        [void](Invoke-GhozttyIpc -Action 'new-window' -Arguments @('--target=swm-jb', '--title=SWM-J-B'))
        [void](Invoke-GhozttyIpc -Action 'new-window' -Arguments @('--target=swm-jc', '--title=SWM-J-C'))
        $ws = Wait-Ws { param($s) $s -and @($s.data.workspaces).Count -eq 3 }
        Assert (@($ws.data.workspaces).Count -eq 3 -and [string]$ws.data.active -eq $j1) "K: setup: three workspaces, $j1 on show ($(@($ws.data.workspaces).Count), active='$($ws.data.active)')"
        Start-Sleep -Milliseconds 800

        # The LAST line matching after line $From, once one has appeared.
        function K-Last([int]$From, [string]$Pattern, [int]$Ms = 4000) {
            $deadline = (Get-Date).AddMilliseconds($Ms)
            do {
                Start-Sleep -Milliseconds 200
                $hit = @(Get-Content $errlog -ErrorAction SilentlyContinue | Select-Object -Skip $From | Where-Object { $_ -match $Pattern }) | Select-Object -Last 1
            } while (-not $hit -and (Get-Date) -lt $deadline)
            if ($hit) {
                Start-Sleep -Milliseconds 300
                $hit = @(Get-Content $errlog -ErrorAction SilentlyContinue | Select-Object -Skip $From | Where-Object { $_ -match $Pattern }) | Select-Object -Last 1
            }
            return [string]$hit
        }
        # The line number just past the first line matching after $From, or -1.
        function K-After([int]$From, [string]$Pattern) {
            $lines = @(Get-Content $errlog -ErrorAction SilentlyContinue)
            for ($k = $From; $k -lt $lines.Count; $k++) { if ($lines[$k] -match $Pattern) { return $k + 1 } }
            return -1
        }
        function K-Sidebar { return @(Get-TestChildWindows -Window ([IntPtr]$shared) -Class 'GhozttyPaneSidebar' | Where-Object { $_.Visible }) | Select-Object -First 1 }
        function K-Click($sb, [int]$x, [int]$y) {
            return Send-TestMouse -Window ([IntPtr]$shared) -Target ([IntPtr]$sb.Hwnd) -X ($sb.Left + $x) -Y ($sb.Top + $y) -Action click
        }
        function K-Point([string]$line, [string]$field) {
            if ($line -match (" $field=(-?\d+),(-?\d+)")) { return @{ X = [int]$Matches[1]; Y = [int]$Matches[2] } }
            return $null
        }
        # Every head of an outline line, in heads order, and the rows.
        function K-Heads([string]$line) {
            $out = @()
            if ($line -match ' heads=(\S*)') {
                foreach ($h in ($Matches[1] -split ';' | Where-Object { $_ })) {
                    if ($h -match '^([PWU])(\d+)@(-?\d+),(-?\d+)$') { $out += , @{ Kind = $Matches[1]; Group = [int]$Matches[2]; X = [int]$Matches[3]; Y = [int]$Matches[4] } }
                }
            }
            return , $out
        }
        function K-Items([string]$line) {
            $out = @()
            if ($line -match ' items=(\S*)') {
                foreach ($i in ($Matches[1] -split ';' | Where-Object { $_ })) {
                    if ($i -match '^g(\d+)([gs])@(-?\d+),(-?\d+)$') { $out += , @{ Group = [int]$Matches[1]; X = [int]$Matches[3]; Y = [int]$Matches[4] } }
                }
            }
            return , $out
        }
        function K-Chevrons([string]$line) {
            $out = @()
            if ($line -match ' chev=(\S*)') { foreach ($c in ($Matches[1] -split ';' | Where-Object { $_ })) { $xy = $c -split ','; $out += , @{ X = [int]$xy[0]; Y = [int]$xy[1] } } }
            return , $out
        }
        # A workspace's group index in the all-windows list's name order.
        function K-Group([string]$groupsLine, [string]$title) {
            if ($groupsLine -notmatch ' order=(.*)$') { return -1 }
            $order = @($Matches[1] -split '\|')
            for ($k = 0; $k -lt $order.Count; $k++) { if ($order[$k] -like "*$title*") { return $k } }
            return -1
        }
        $outlineRx = 'pane sidebar outline mode='
        # This window's scope logs the same shape as `rows` (logRows).
        $anyRx = 'pane sidebar (outline|rows) mode='

        # K1: expand the sidebar on show, then put it in all-windows scope.
        $sb0 = K-Sidebar
        $line = K-Last 0 $anyRx
        $tg = K-Point $line 'toggle'
        Assert ($null -ne $sb0 -and $line -match 'mode=mini' -and $null -ne $tg) "K1: setup: the sidebar on show starts collapsed (width=$(if ($sb0) { $sb0.Width }); $(if ($line -match 'mode=(\w+)') { $Matches[0] }))"
        $railW = if ($sb0) { $sb0.Width } else { 0 }
        $mark = Log-Count
        if ($sb0 -and $tg) { Assert (K-Click $sb0 $tg.X $tg.Y) 'K1: toggle click delivered' }
        $line = K-Last $mark ($anyRx + 'expanded')
        Start-Sleep -Milliseconds 500
        $sb1 = K-Sidebar
        Assert ($line -and $sb1 -and $sb1.Width -gt ($railW + (K-Px 100))) "K1: the toggle expanded it (width $railW -> $(if ($sb1) { $sb1.Width }))"
        $launchScope = [string](K-Last 0 'pane sidebar scope at launch all_windows=' 500)
        $scoped = K-Last 0 'pane sidebar scope all_windows=' 300
        $allOn = if ($scoped) { $scoped -match 'all_windows=true' } else { $launchScope -match 'all_windows=true' }
        if (-not $allOn) {
            $sc = K-Point $line 'scope'
            $mark = Log-Count
            if ($sb1 -and $sc) { Assert (K-Click $sb1 $sc.X $sc.Y) 'K1: scope click delivered' }
            Assert ([bool](K-Last $mark 'pane sidebar scope all_windows=true')) 'K1: the scope button turned all windows on'
        }
        $mark = Log-Count
        [void](Invoke-GhozttyIpc -Action 'workspaces' -Arguments @('--op=state'))
        $line = K-Last 0 ($outlineRx + 'expanded')
        $groups = K-Last 0 'pane sidebar all-windows groups='
        Write-Host "  $groups"
        $gB = K-Group $groups 'SWM-J-B'
        $gC = K-Group $groups 'SWM-J-C'
        Assert ($gB -ge 0 -and $gC -ge 0) "K1: every workspace - the parked two too - is on the all-windows list (SWM-J-B=g$gB SWM-J-C=g$gC)"

        # K2: a click on parked SWM-J-B's header puts it on show.
        $heads = K-Heads $line
        $hB = @($heads | Where-Object { $_.Kind -eq 'W' -and $_.Group -eq $gB }) | Select-Object -First 1
        $mark = Log-Count
        if ($hB -and $sb1) { Assert (K-Click $sb1 $hB.X $hB.Y) 'K2: header click delivered' } else { Assert $false "K2: SWM-J-B has a header to click (g$gB in $($heads.Count) heads)" }
        $sw = K-Last $mark 'workspace switch from the sidebar name='
        Assert ($sw -match 'name=swm-jb') "K2: the click asked for the deferred switch ($sw)"
        $ws = Wait-Ws { param($s) $s -and [string]$s.data.active -eq 'swm-jb' }
        $rb = Ws-Row $ws 'swm-jb'
        Assert ([string]$ws.data.active -eq 'swm-jb') "K2: SWM-J-B is on show (active='$($ws.data.active)')"
        Assert ($rb -and [int64]$rb.hwnd -eq $shared -and [int]$ws.data.windows_with_hwnd -eq 1) "K2: in the SAME window, one HWND held (hwnd=$(if ($rb) { $rb.hwnd }) windows_with_hwnd=$($ws.data.windows_with_hwnd))"
        $r1 = Ws-Row $ws $j1
        Assert ($r1 -and $r1.parked) "K2: the one it left is parked ($j1 parked=$(if ($r1) { $r1.parked }))"
        $tops = @(Visible-Tops)
        Assert ($tops.Count -eq 1) "K2: one window on screen ($($tops.Count))"

        # K3: the adopter's sidebar came back expanded, in all-windows scope -
        # it was parked when the toggle was clicked.
        $adoptAt = K-After $mark 'workspace adopt sidebar expanded='
        $adoptLine = K-Last $mark 'workspace adopt sidebar expanded=' 500
        Assert ($adoptLine -match 'expanded=true hidden=false') "K3: the adopter took the shared sidebar's flags ($adoptLine)"
        Start-Sleep -Milliseconds 500
        $sb2 = K-Sidebar
        Assert ($sb2 -and $sb1 -and $sb2.Hwnd -ne $sb1.Hwnd) "K3: the sidebar is the adopter's own (hwnd $(if ($sb1) { $sb1.Hwnd }) -> $(if ($sb2) { $sb2.Hwnd }))"
        Assert ($sb2 -and $sb1 -and [math]::Abs($sb2.Width - $sb1.Width) -le 1) "K3: expanded, the width the shared one has ($(if ($sb2) { $sb2.Width }) vs $(if ($sb1) { $sb1.Width }))"
        $from = if ($adoptAt -ge 0) { $adoptAt } else { $mark }
        $line2 = K-Last $from ($outlineRx + 'expanded')
        $groups2 = K-Last $from 'pane sidebar all-windows groups='
        Assert ($line2 -and $groups2 -match 'windows=3 ') "K3: in all-windows scope, all three listed ($groups2)"

        # K4: a click on parked SWM-J-C's PANE row - its chevron unfolds it
        # first, without raising it - puts it on show.
        $heads = K-Heads $line2
        $chev = K-Chevrons $line2
        $gC = K-Group $groups2 'SWM-J-C'
        $kC = -1
        for ($k = 0; $k -lt $heads.Count; $k++) { if ($heads[$k].Kind -eq 'W' -and $heads[$k].Group -eq $gC) { $kC = $k } }
        $mark = Log-Count
        if ($kC -ge 0 -and $kC -lt $chev.Count -and $sb2) { [void](K-Click $sb2 $chev[$kC].X $chev[$kC].Y) }
        Assert ([bool](K-Last $mark 'pane sidebar unfold' 2000)) "K4: SWM-J-C's chevron unfolded it (head $kC of $($heads.Count))"
        $ws = Invoke-GhozttyIpc -Action 'workspaces' -Arguments @('--op=state')
        Assert ([string]$ws.data.active -eq 'swm-jb') "K4: ...without switching (active='$($ws.data.active)')"
        $line3 = K-Last $mark ($outlineRx + 'expanded')
        $row = @(K-Items $line3 | Where-Object { $_.Group -eq $gC }) | Select-Object -First 1
        $mark = Log-Count
        if ($row -and $sb2) { Assert (K-Click $sb2 $row.X $row.Y) 'K4: pane row click delivered' } else { Assert $false "K4: SWM-J-C's pane has a row to click (g$gC)" }
        Assert ([bool](K-Last $mark 'pane sidebar focus other window' 2000)) 'K4: the row click is the other-window focus (log)'
        $sw = K-Last $mark 'workspace switch from the sidebar name='
        Assert ($sw -match 'name=swm-jc') "K4: and asked for the deferred switch ($sw)"
        $ws = Wait-Ws { param($s) $s -and [string]$s.data.active -eq 'swm-jc' }
        $rc = Ws-Row $ws 'swm-jc'
        Assert ($rc -and [string]$ws.data.active -eq 'swm-jc' -and [int64]$rc.hwnd -eq $shared -and [int]$ws.data.windows_with_hwnd -eq 1) "K4: SWM-J-C is on show in the SAME window (active='$($ws.data.active)' windows_with_hwnd=$($ws.data.windows_with_hwnd))"
        $adoptLine = K-Last $mark 'workspace adopt sidebar expanded=' 500
        Assert ($adoptLine -match 'expanded=true') "K4: its sidebar came back expanded too ($adoptLine)"
        Assert (-not ($app.Process -and $app.Process.HasExited)) 'K: no crash'
        Stop-Process -Id $app.Pid -Force -ErrorAction SilentlyContinue
        [void](Stop-RepoGhoztty -Exe $exe -SettleMs 500)
        $app = $null
    }

    # =====================================================================
    # M (T3206): Restore All rebuilds orphaned workspaces PARKED and puts
    # the one that was in front on show once - one hand-off, not one per
    # rebuilt workspace. Fixture (chooser-restore-all-adopt.ps1's shape):
    # two instances on ONE agent; A builds three workspaces with swm-la on
    # show, is killed the way a crash kills it, and B - already running, so
    # it never saw them at launch - presses Restore All in its chooser.
    # =====================================================================
    if ($ExePath) {
        $script:skipped++
        Write-Host 'SKIP  M: reads the app log, which -ExePath does not capture'
    } else {
        [System.IO.File]::WriteAllText($cfgFile, "macos-window-mode = single`n")
        # A fresh LOCALAPPDATA: section I's manifest and agent store would
        # otherwise come back at B's launch.
        $persistLocal = Join-Path $work 'local-l'
        New-Item -ItemType Directory -Force -Path $persistLocal | Out-Null
        $suffixB = $env:GHOZTTY_PIPE_SUFFIX
        $suffixA = "-swmA$PID"
        $errlogB = $errlog
        $errlogA = Join-Path $env:TEMP "ghoztty-swm-stderrA-$PID.log"
        Remove-Item $errlogA -ErrorAction SilentlyContinue
        $manifestPath = Get-GhozttySessionLayoutPath -Root $persistLocal
        $agentDir = Get-GhozttyAgentStateDir -Root $persistLocal -Exe $exe
        $appA = $null

        # The agent's own view, dialled directly - never through either app.
        function L-Sessions {
            $saved = $env:LOCALAPPDATA
            $env:LOCALAPPDATA = $persistLocal
            try { $out = (& $exe +sessions --json 2>$null | Out-String) } finally { $env:LOCALAPPDATA = $saved }
            if (-not $out -or $out.Trim().Length -eq 0) { return @() }
            try { $j = $out | ConvertFrom-Json } catch { return @() }
            if ($null -eq $j) { return @() }
            return @($j | ForEach-Object { $_ })
        }
        # The agent-held blob for a workspace, once it is marked frontmost.
        function L-FrontBlob([string]$name) {
            $path = Join-Path $agentDir 'layouts.json'
            if (-not (Test-Path $path)) { return $null }
            try { $doc = (Get-Content $path -Raw) | ConvertFrom-Json } catch { return $null }
            foreach ($rec in @($doc.layouts | ForEach-Object { $_ })) {
                $w = $null
                try { $w = $rec.blob | ConvertFrom-Json } catch {}
                if ($w -and [string]$w.ipc_name -eq $name -and $w.frontmost -eq $true) { return $w }
            }
            return $null
        }

        try {
            # M0: B, the survivor - one workspace, nothing to restore.
            $env:GHOZTTY_PIPE_SUFFIX = $suffixB
            $app = Start-App 'launch M (B, single, persisted)' -Persist
            if (-not $app) { exit 1 }
            $ws = Wait-Ws { param($s) $s -and $s.data.active }
            $lb = [string]$ws.data.active
            Assert ($lb -and @($ws.data.workspaces).Count -eq 1) "M: setup: B is one workspace ('$lb', $(@($ws.data.workspaces).Count))"

            # M1: A on the SAME agent builds three workspaces, swm-la on show.
            $env:GHOZTTY_PIPE_SUFFIX = $suffixA
            $errlog = $errlogA
            try { $appA = Start-App 'launch M (A, single, persisted)' -Persist } finally { $errlog = $errlogB }
            if (-not $appA) { exit 1 }
            $ws = Wait-Ws { param($s) $s -and $s.data.active }
            [void](Invoke-GhozttyIpc -Action 'new-window' -Arguments @('--target=swm-la', '--title=SWM-L-A'))
            [void](Invoke-GhozttyIpc -Action 'new-window' -Arguments @('--target=swm-lb', '--title=SWM-L-B'))
            $ws = Wait-Ws { param($s) $s -and @($s.data.workspaces).Count -eq 3 }
            Assert (@($ws.data.workspaces).Count -eq 3) "M: setup: A holds three workspaces ($(@($ws.data.workspaces).Count))"
            $ws = Invoke-GhozttyIpc -Action 'workspaces' -Arguments @('--op=show', '--target=swm-la')
            Assert ($ws -and [string]$ws.data.active -eq 'swm-la') "M: setup: swm-la is on show in A (active='$($ws.data.active)')"
            $deadline = (Get-Date).AddSeconds(20)
            do { Start-Sleep -Milliseconds 500; $fb = L-FrontBlob 'swm-la' } while ((Get-Date) -lt $deadline -and -not $fb)
            Assert ($null -ne $fb) 'M: setup: the agent holds swm-la''s layout, marked frontmost'
            $deadline = (Get-Date).AddSeconds(20)
            do { Start-Sleep -Milliseconds 500; $rows = @(L-Sessions | Where-Object { $_.alive }) } while ((Get-Date) -lt $deadline -and $rows.Count -lt 4)
            Assert ($rows.Count -ge 4) "M: setup: the agent has B's session and A's three alive ($($rows.Count))"

            # M2: A dies; its sessions are orphans B never saw at launch.
            Stop-Process -Id $appA.Pid -Force -ErrorAction SilentlyContinue
            $appA = $null
            Start-Sleep -Milliseconds 700
            Remove-Item $manifestPath -ErrorAction SilentlyContinue
            $deadline = (Get-Date).AddSeconds(25)
            do {
                Start-Sleep -Milliseconds 500
                $rows = @(L-Sessions | Where-Object { $_.alive })
                $att = @($rows | Where-Object { $_.attached })
            } while ((Get-Date) -lt $deadline -and -not ($rows.Count -ge 4 -and $att.Count -eq 1))
            Assert ($rows.Count -ge 4 -and $att.Count -eq 1) "M: setup: A's sessions are alive and unattached ($($rows.Count) alive, $($att.Count) attached)"

            # M3: Restore All in B's chooser.
            $env:GHOZTTY_PIPE_SUFFIX = $suffixB
            $ws = Invoke-GhozttyIpc -Action 'workspaces' -Arguments @('--op=state')
            $top = [IntPtr][int64](Ws-Row $ws $lb).hwnd
            $pane = @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal' | Where-Object Visible | Select-Object -First 1)
            $paneH = if ($pane.Count -eq 1) { [IntPtr]$pane[0].Hwnd } else { [IntPtr]::Zero }
            $chooser = [IntPtr]::Zero
            if (Send-TestKeys -Window $top -Target $paneH -Modifiers ctrl, shift -Key N) {
                $chooser = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyMachineChooser' -TimeoutMs 5000
            }
            Assert ($chooser -ne [IntPtr]::Zero) 'M: ctrl+shift+n opens the chooser on B'
            if ($chooser -eq [IntPtr]::Zero) { throw 'M: no chooser' }
            $filter = Get-TestChildWindow -Window $chooser -Class 'Edit'
            $deadline = (Get-Date).AddSeconds(10)
            do { Start-Sleep -Milliseconds 250; $loaded = Select-String -Path $errlogB -Pattern 'chooser roster: loaded \d+ session' -Quiet -ErrorAction SilentlyContinue } while ((Get-Date) -lt $deadline -and -not $loaded)
            Start-Sleep -Milliseconds 800
            $btn = ConvertTo-TestHwnd (Get-ChooserRestoreAllButton -Chooser $chooser)
            Assert ($btn -ne [IntPtr]::Zero -and (Test-TestWindowVisible -Window $btn)) 'M: Restore All is offered'
            Assert (Focus-ChooserControl -Chooser $chooser -From $filter -To $btn) 'M: Tab reaches the button (the positive control)'
            $mark = Log-Count
            [void](Send-TestKeys -Window $chooser -Target $btn -Key Return)
            $deadline = (Get-Date).AddSeconds(15)
            do {
                Start-Sleep -Milliseconds 300
                $rebuilt = @(Get-Content $errlogB -ErrorAction SilentlyContinue | Select-Object -Skip $mark | Where-Object { $_ -match 'restore all: rebuilt (\d+) window' }) | Select-Object -Last 1
            } while ((Get-Date) -lt $deadline -and -not $rebuilt)
            Assert ([string]$rebuilt -match 'rebuilt 3 window') "M1: B rebuilt A's three workspaces ($rebuilt)"
            Start-Sleep -Milliseconds 1500

            # M4: the oracle - every workspace is there, the frontmost on show,
            # in the one window, reached by exactly ONE hand-off.
            $ws = Wait-Ws { param($s) $s -and @($s.data.workspaces).Count -ge 4 }
            $names = @($ws.data.workspaces | ForEach-Object { [string]$_.name })
            Assert ($names.Count -eq 4 -and $names -contains 'swm-la' -and $names -contains 'swm-lb') "M2: every rebuilt workspace is present beside B's own ($($names -join ','))"
            Assert ([string]$ws.data.active -eq 'swm-la') "M2: the one that was in front is on show (active='$($ws.data.active)')"
            Assert ($ws -and [int]$ws.data.windows_with_hwnd -eq 1 -and @($ws.data.workspaces | Where-Object { $_.parked }).Count -eq 3) "M2: ONE window, the other three parked (windows_with_hwnd=$($ws.data.windows_with_hwnd))"
            $after = @(Get-Content $errlogB -ErrorAction SilentlyContinue | Select-Object -Skip $mark)
            $adopted = @($after | Where-Object { $_ -match 'workspace adopted the window' })
            Assert ($adopted.Count -eq 1) "M3: exactly one hand-off, not one per rebuilt workspace ($($adopted.Count): $(@($adopted | ForEach-Object { if ($_ -match 'name=(\S+)') { $Matches[1] } }) -join ','))"
            Assert ($adopted.Count -ge 1 -and $adopted[-1] -match 'name=swm-la') 'M3: ...and it was to swm-la'
            Assert (@($after | Where-Object { $_ -match 'restore all: the frontmost workspace is on show name=swm-la shown=true' }).Count -eq 1) 'M3: the rebuild says it put the frontmost on show once'
            Assert (-not ($app.Process -and $app.Process.HasExited)) 'M: no crash'
        } finally {
            if ($appA) { Stop-Process -Id $appA.Pid -Force -ErrorAction SilentlyContinue }
            $env:GHOZTTY_PIPE_SUFFIX = $suffixB
            $errlog = $errlogB
        }
        if ($app) { Stop-Process -Id $app.Pid -Force -ErrorAction SilentlyContinue }
        [void](Stop-RepoGhoztty -Exe $exe -SettleMs 500)
        $app = $null
    }

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
