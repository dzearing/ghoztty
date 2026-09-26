# T891 acceptance: the command palette orders its rows the way Mac's does -
# alphabetically by title, with the most recently used commands surfaced
# first - and remembers what was used across a relaunch.
#
# WHAT THIS COVERS. The win32 palette used to show REGISTRY order, which is
# the order the commands happen to be written in. The Mac palette sorts every
# option by title and keeps a "Recent" section fed by PaletteHistory. This
# drives the win32 twin end to end, through the one thing a script can read
# about an owner-drawn list: WHICH ROW ENTER RUNS.
#
#   O1. alphabetical order: with no history at all, filtering the palette to
#       "new " and pressing Enter runs "New Remote Window" (the alphabetically
#       first match, which opens the machine chooser) rather than "New Window"
#       (the first REGISTRY match, which would open a second terminal window).
#       The two outcomes are different window classes, so the arm cannot pass
#       by accident.
#   O2. the execution is recorded: the store
#       %LOCALAPPDATA%\ghoztty\palette-history-debug.json now names the
#       command that was run.
#   O3. Recent leads, in recency order, and survives a relaunch: with the
#       store seeded (BEFORE launch) so that "New Tab" is newer than
#       "New Remote Window", the same keystrokes run New Tab instead - a
#       result neither registry order nor alphabetical order can produce.
#   O4. the recording is durable: that run stamped New Tab with a FRESHER
#       timestamp than the seed.
#   O5. a click on a SCROLLED list runs the row painted under the pointer
#       (T1671): Enter on row 5 in one launch names its command; in a second
#       launch the list is arrowed until row 5 is painted in the TOP slot and
#       that slot is clicked - the store must name the same command, not
#       row 0's (the pre-fix hit-test ignored the scroll).
#   O6. a command-palette-entry added on the command line shows and runs
#       (T1752): before, the palette read only the first 64 entries of a list
#       that starts with Ghostty's ~100 defaults, so no user entry ever showed.
#   O7. a default the registry already carries is listed ONCE (T1752):
#       filtering to "Change Window Title" leaves one row, so Down then Enter
#       still runs the registry command rather than its duplicate.
#
# WHAT IT DOES NOT COVER. The section HEADERS ("Recent" / "All Commands") are
# owner-drawn text and unreadable from a script; header placement, the
# selection stepping over a header, and the ordering itself are unit-tested in
# the none lane (src/apprt/win32/palette_order.zig).
#
# T218 house rules: runs on a BACKGROUND Win32 desktop, never takes the
# user's foreground, and only touches ghoztty processes from this repo's
# zig-out.
#
#   powershell -NoProfile -File test\win32\palette-order.ps1
param(
    [string]$Exe,
    [switch]$Interactive
)
$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not $Exe) { $Exe = Join-Path $repo 'zig-out\bin\ghoztty.exe' }
if (-not (Test-Path $Exe)) { $Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }

# Isolate the IPC endpoint before any CLI call.
$env:GHOZTTY_PIPE_SUFFIX = "-paletteorder$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
# T1511: the shared scorer, and the dot-source is also what ARMS the run.
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Stop-DebugGhoztty {
    Reset-GhozttyTestState -Exe $Exe -SettleMs 500 | Out-Null
}

# The store this whole script is about. The `-debug` name is what keeps a dev
# build out of the installed release's recents, so a run here can never
# reorder the palette the user is sitting in front of.
$script:storePath = Join-Path $env:LOCALAPPDATA 'ghoztty\palette-history-debug.json'

function Clear-PaletteHistory {
    Remove-Item -LiteralPath $script:storePath -Force -ErrorAction SilentlyContinue
}

function Set-PaletteHistory([object[]]$Commands) {
    $dir = Split-Path $script:storePath -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $json = ConvertTo-Json @{ commands = $Commands } -Depth 4 -Compress
    [System.IO.File]::WriteAllText($script:storePath, $json)
}

# The stored stamps as a hashtable id -> used, or an empty one when the store
# is absent or unreadable (which is exactly what the app treats as "no
# recents", so the test reads it the same way).
function Get-PaletteHistory {
    $out = @{}
    if (-not (Test-Path $script:storePath)) { return $out }
    try { $j = Get-Content -LiteralPath $script:storePath -Raw | ConvertFrom-Json } catch { return $out }
    foreach ($c in @($j.commands)) {
        if ($null -ne $c -and $c.id) { $out[[string]$c.id] = [int64]$c.used }
    }
    return $out
}

# The palette popup is a top-level GhozttyCommandPalette-class window, and
# every surface that has EVER opened one keeps a HIDDEN popup around - so
# "open" must mean the VISIBLE one.
function Wait-VisiblePalette([int]$TimeoutMs = 5000) {
    for ($t = 0; $t -lt $TimeoutMs; $t += 200) {
        $vis = @(Get-TestWindows -ProcessId $script:appPid -Class 'GhozttyCommandPalette' |
            Where-Object { $_.Visible })
        if ($vis.Count -ge 1) { return [IntPtr]$vis[0].Hwnd }
        Start-Sleep -Milliseconds 200
    }
    return [IntPtr]::Zero
}

function Open-Palette([IntPtr]$top, [IntPtr]$pane) {
    foreach ($try in 1..3) {
        if (-not (Send-TestKeys -Window $top -Target $pane -Modifiers ctrl, shift -Key P)) { continue }
        $popup = Wait-VisiblePalette
        if ($popup -ne [IntPtr]::Zero) {
            $edit = Find-TestWindowEx -Parent $popup -Class 'EDIT'
            if ($edit -ne [IntPtr]::Zero) { return @{ Popup = $popup; Edit = $edit } }
        }
    }
    return $null
}

# The tab count of the app's FIRST listed window. The chooser-restore recipe
# verbatim: Out-String (an explicit exe path needs a real pipe to deliver
# stdout), then unwrap the {data: ...} envelope, then @(...) every walk.
function Get-FirstWindowTabCount {
    $out = (& $Exe +list --json 2>$null | Out-String)
    if (-not $out -or $out.Trim().Length -eq 0) { return 0 }
    try { $j = $out | ConvertFrom-Json } catch { return 0 }
    if ($null -ne $j -and $null -ne $j.data) { $j = $j.data }
    if ($null -eq $j) { return 0 }
    $win = @($j.windows) | Select-Object -First 1
    if ($null -eq $win) { return 0 }
    return @($win.tabs).Count
}

function Count-TestWindowsOfClass([string]$Class) {
    return @(Get-TestWindows -ProcessId $script:appPid -Class $Class).Count
}

Stop-DebugGhoztty
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$app = $null
$script:appPid = 0

try {

# ---------------------------------------------------------------------
# O1 / O2: no history at all - alphabetical order decides, and the run is
# recorded.
# ---------------------------------------------------------------------
Write-Host '== O1: with no history, "new " + Enter runs the ALPHABETICALLY first match'
Clear-PaletteHistory
Assert (-not (Test-Path $script:storePath)) 'O1 setup: the palette history store starts absent'

$errlog = Join-Path $env:TEMP "ghoztty-palette-order-a-$PID.log"
$app = Start-OnTestDesktop -Exe $Exe -Arguments @('--session-persistence=false') -StdErr $errlog
$script:appPid = $app.Pid
Start-Sleep -Seconds 3
if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }

$top = Wait-TestWindow -ProcessId $script:appPid -Class 'GhozttyWindow'
if ($top -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: launch window not found'; exit 1 }
Assert (-not (Test-TestDesktopLeak -ProcessId $script:appPid)) 'the GUI is NOT enumerable on the interactive desktop'
$pane = Get-TestChildWindow -Window $top -Class 'GhozttyTerminal'
if ($pane -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: no pane'; exit 1 }

[void](Focus-TestWindow -Window $top -Child $pane)
$pal = Open-Palette $top $pane
if ($null -eq $pal) {
    Write-Host 'ABORT: positive control failed (palette never opened) - injection broken, not a verdict'
    exit 1
}
Write-Host 'OK    positive control: ctrl+shift+p opens the palette'

$windowsBefore = Count-TestWindowsOfClass 'GhozttyWindow'
Assert (Send-TestControlText -Control $pal.Edit -Text 'new ') 'O1 typed "new " as the filter'
Start-Sleep -Milliseconds 600
Send-TestControlKey -Control $pal.Edit -Key Enter | Out-Null

$chooser = Wait-TestWindow -ProcessId $script:appPid -Class 'GhozttyMachineChooser' -TimeoutMs 6000
Assert ($chooser -ne [IntPtr]::Zero) 'O1 Enter ran "New Remote Window" - the alphabetically first match'
Assert ((Count-TestWindowsOfClass 'GhozttyWindow') -eq $windowsBefore) `
    'O1 no second terminal window opened (registry order would have run "New Window")'

Write-Host '== O2: the execution was recorded in the history store'
$hist = Get-PaletteHistory
Assert ($hist.ContainsKey('new_remote_window')) `
    "O2 the store names new_remote_window (got: $(($hist.Keys | Sort-Object) -join ', '))"

# ---------------------------------------------------------------------
# O3 / O4: a seeded history - Recent leads, in recency order, across a
# relaunch.
# ---------------------------------------------------------------------
Write-Host '== O3: with New Tab most recent, the SAME keystrokes run New Tab'
Stop-DebugGhoztty
$script:appPid = 0
$now = [int64][double]::Parse((Get-Date -UFormat %s))
Set-PaletteHistory @(
    @{ id = 'new_remote_window'; used = ($now - 600) },
    @{ id = 'new_tab'; used = ($now - 60) }
)
$seeded = Get-PaletteHistory
Assert ($seeded['new_tab'] -eq ($now - 60)) 'O3 setup: the store was seeded with New Tab as the most recent'

$errlog2 = Join-Path $env:TEMP "ghoztty-palette-order-b-$PID.log"
$app = Start-OnTestDesktop -Exe $Exe -Arguments @('--session-persistence=false') -StdErr $errlog2
$script:appPid = $app.Pid
Start-Sleep -Seconds 3
if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died on relaunch'; exit 1 }

$top2 = Wait-TestWindow -ProcessId $script:appPid -Class 'GhozttyWindow'
Assert ($top2 -ne [IntPtr]::Zero) 'O3 the relaunched window is up'
if ($top2 -eq [IntPtr]::Zero) { exit 1 }
$pane2 = Get-TestChildWindow -Window $top2 -Class 'GhozttyTerminal'
Assert ($pane2 -ne [IntPtr]::Zero) 'O3 the relaunched window has a pane'

Assert ((Get-FirstWindowTabCount) -eq 1) 'O3 setup: the window starts with one tab'
[void](Focus-TestWindow -Window $top2 -Child $pane2)
$pal2 = Open-Palette $top2 $pane2
Assert ($null -ne $pal2) 'O3 the palette opened'
if ($null -ne $pal2) {
    Assert (Send-TestControlText -Control $pal2.Edit -Text 'new ') 'O3 typed "new " as the filter'
    Start-Sleep -Milliseconds 600
    Send-TestControlKey -Control $pal2.Edit -Key Enter | Out-Null

    $deadline = (Get-Date).AddSeconds(8)
    while ((Get-Date) -lt $deadline -and (Get-FirstWindowTabCount) -lt 2) { Start-Sleep -Milliseconds 400 }
    Assert ((Get-FirstWindowTabCount) -eq 2) `
        'O3 Enter ran "New Tab" - the most recently used match, ahead of the alphabetical first'
    Assert ((Count-TestWindowsOfClass 'GhozttyMachineChooser') -eq 0) `
        'O3 the chooser did NOT open (alphabetical order alone would have run New Remote Window)'

    Write-Host '== O4: that run re-stamped New Tab in the store'
    $after = Get-PaletteHistory
    Assert ($after.ContainsKey('new_tab') -and $after['new_tab'] -ge ($now - 60)) `
        "O4 new_tab carries a fresher timestamp than the seed (seed=$($now - 60), stored=$($after['new_tab']))"
    Assert ($after.ContainsKey('new_remote_window')) 'O4 the older entry survived the rewrite'
}

# ---------------------------------------------------------------------
# O5: a click on a SCROLLED list runs the row painted under the pointer
# (T1671). The oracle is the keyboard: launch A arrows to row N and presses
# Enter, which names row N's command in the store. Launch B arrows PAST the
# last visible row - so the list scrolls and row N is painted in the TOP slot
# - and clicks that slot. Both must name the same command. The pre-fix
# hit-test took the visual slot as the absolute row, so launch B ran row 0,
# a different command (every row carries a distinct key).
#
# Built-in rows rather than configured ones, so the arm does not depend on
# the config list (O6/O7 cover that; before T1752 an entry a test added was
# never shown at all). With the history cleared and no filter
# there are no section headers, so rows are plain alphabetical order, and
# row 5 is a title prompt - harmless to run.
# ---------------------------------------------------------------------
function Start-O5Palette([string]$Tag) {
    Stop-DebugGhoztty
    $script:appPid = 0
    Clear-PaletteHistory
    $log = Join-Path $env:TEMP "ghoztty-palette-order-$Tag-$PID.log"
    $script:app = Start-OnTestDesktop -Exe $Exe -Arguments @('--session-persistence=false') -StdErr $log
    $script:appPid = $script:app.Pid
    Start-Sleep -Seconds 3
    if ($script:app.Process -and $script:app.Process.HasExited) { return $null }
    $t = Wait-TestWindow -ProcessId $script:appPid -Class 'GhozttyWindow'
    if ($t -eq [IntPtr]::Zero) { return $null }
    $p = Get-TestChildWindow -Window $t -Class 'GhozttyTerminal'
    if ($p -eq [IntPtr]::Zero) { return $null }
    [void](Focus-TestWindow -Window $t -Child $p)
    return (Open-Palette $t $p)
}

function Wait-OnlyPaletteRun {
    $deadline = (Get-Date).AddSeconds(5)
    $keys = @()
    while ((Get-Date) -lt $deadline) {
        $keys = @((Get-PaletteHistory).Keys)
        if ($keys.Count -gt 0) { break }
        Start-Sleep -Milliseconds 250
    }
    return , $keys
}

$o5Row = 5
Write-Host "== O5a: Enter on row $o5Row names the command the click must run"
$palA = Start-O5Palette 'o5a'
Assert ($null -ne $palA) 'O5a the palette opened'
$wantKey = $null
if ($null -ne $palA) {
    foreach ($k in 1..$o5Row) { Send-TestControlKey -Control $palA.Edit -Key Down | Out-Null }
    Start-Sleep -Milliseconds 300
    Send-TestControlKey -Control $palA.Edit -Key Enter | Out-Null
    $ranA = Wait-OnlyPaletteRun
    Assert ($ranA.Count -eq 1) "O5a Enter ran exactly one command (got: $($ranA -join ', '))"
    if ($ranA.Count -eq 1) { $wantKey = [string]$ranA[0] }
}

Write-Host "== O5b: scrolled so row $o5Row is the TOP slot, a click there runs it"
$palB = Start-O5Palette 'o5b'
Assert ($null -ne $palB) 'O5b the palette opened'
if ($null -ne $palB -and $null -ne $wantKey) {
    # The popup's own geometry, the way paintPaletteInto derives it.
    $cr = Get-TestWindowRect -Window $palB.Popup -Client
    $s = (Get-TestWindowDpi -Window $palB.Popup) / 96.0
    $listTop = [int][math]::Round(40.0 * $s)
    $itemH = [int][math]::Round(28.0 * $s)
    $maxVis = [int][math]::Floor(($cr.Height - $listTop) / $itemH)
    Write-Host "      popup client $($cr.Width)x$($cr.Height) scale=$s -> $maxVis visible rows"
    Assert ($maxVis -ge 2) "O5b setup: the popup shows a list ($maxVis rows)"

    # Selecting row (maxVis + o5Row - 1) scrolls the list by exactly o5Row,
    # which puts row o5Row in the top slot.
    $downs = $maxVis + $o5Row - 1
    foreach ($k in 1..$downs) { Send-TestControlKey -Control $palB.Edit -Key Down | Out-Null }
    Start-Sleep -Milliseconds 400

    $x = $cr.Left + [int]($cr.Width / 2)
    $y = $cr.Top + $listTop + [int]($itemH / 2)
    [void](Send-TestMouse -Window $palB.Popup -X $x -Y $y)
    $ranB = Wait-OnlyPaletteRun
    Assert ($ranB.Count -eq 1) "O5b the click ran exactly one command (got: $($ranB -join ', '))"
    Assert ($ranB.Count -eq 1 -and [string]$ranB[0] -eq $wantKey) `
        "O5b the click ran the row painted in the top slot, $wantKey (got: $($ranB -join ', '); pre-fix it ran row 0)"
}

# ---------------------------------------------------------------------
# O6 / O7: the config's own palette entries (T1752). The config list is
# Ghostty's ~100 defaults with the user's appended after them, and the palette
# used to read only its first 64 - so a user's entry NEVER showed. And every
# default the registry also carries was listed twice.
# ---------------------------------------------------------------------
$probeTitle = 'ZzqT1752Probe'
Write-Host "== O6: an entry added in the config shows up, and Enter runs it"
Stop-DebugGhoztty
$script:appPid = 0
Clear-PaletteHistory
$log6 = Join-Path $env:TEMP "ghoztty-palette-order-o6-$PID.log"
$app = Start-OnTestDesktop -Exe $Exe -StdErr $log6 -Arguments @(
    '--session-persistence=false',
    "--command-palette-entry=title:$probeTitle,action:new_tab")
$script:appPid = $app.Pid
Start-Sleep -Seconds 3
$top6 = Wait-TestWindow -ProcessId $script:appPid -Class 'GhozttyWindow'
Assert ($top6 -ne [IntPtr]::Zero) 'O6 the window is up'
if ($top6 -ne [IntPtr]::Zero) {
    $pane6 = Get-TestChildWindow -Window $top6 -Class 'GhozttyTerminal'
    [void](Focus-TestWindow -Window $top6 -Child $pane6)
    Assert ((Get-FirstWindowTabCount) -eq 1) 'O6 setup: the window starts with one tab'
    $pal6 = Open-Palette $top6 $pane6
    Assert ($null -ne $pal6) 'O6 the palette opened'
    if ($null -ne $pal6) {
        Assert (Send-TestControlText -Control $pal6.Edit -Text $probeTitle) "O6 typed `"$probeTitle`" as the filter"
        Start-Sleep -Milliseconds 600
        Send-TestControlKey -Control $pal6.Edit -Key Enter | Out-Null
        $deadline = (Get-Date).AddSeconds(8)
        while ((Get-Date) -lt $deadline -and (Get-FirstWindowTabCount) -lt 2) { Start-Sleep -Milliseconds 400 }
        Assert ((Get-FirstWindowTabCount) -eq 2) `
            'O6 Enter ran the configured entry (new_tab) - pre-fix the filter matched no row at all'
        $h6 = Get-PaletteHistory
        Assert ($h6.ContainsKey("user:$probeTitle")) `
            "O6 the run was recorded under the user key (got: $(($h6.Keys | Sort-Object) -join ', '))"
    }
}

Write-Host '== O7: a default the registry already offers is listed once, as the registry row'
Stop-DebugGhoztty
$script:appPid = 0
Clear-PaletteHistory
$log7 = Join-Path $env:TEMP "ghoztty-palette-order-o7-$PID.log"
$app = Start-OnTestDesktop -Exe $Exe -Arguments @('--session-persistence=false') -StdErr $log7
$script:appPid = $app.Pid
Start-Sleep -Seconds 3
$top7 = Wait-TestWindow -ProcessId $script:appPid -Class 'GhozttyWindow'
Assert ($top7 -ne [IntPtr]::Zero) 'O7 the window is up'
if ($top7 -ne [IntPtr]::Zero) {
    $pane7 = Get-TestChildWindow -Window $top7 -Class 'GhozttyTerminal'
    [void](Focus-TestWindow -Window $top7 -Child $pane7)
    $pal7 = Open-Palette $top7 $pane7
    Assert ($null -ne $pal7) 'O7 the palette opened'
    if ($null -ne $pal7) {
        # Two rows matched this before, with the SAME title: the registry's
        # command and Ghostty's default for the same action. Down moved the
        # selection onto the second, and Enter ran the duplicate. With one row,
        # Down has nowhere to go and Enter runs the registry command.
        Assert (Send-TestControlText -Control $pal7.Edit -Text 'Change Window Title') 'O7 typed "Change Window Title"'
        Start-Sleep -Milliseconds 600
        Send-TestControlKey -Control $pal7.Edit -Key Down | Out-Null
        Start-Sleep -Milliseconds 200
        Send-TestControlKey -Control $pal7.Edit -Key Enter | Out-Null
        $ran7 = Wait-OnlyPaletteRun
        Assert ($ran7.Count -eq 1 -and [string]$ran7[0] -eq 'prompt_window_title') `
            "O7 Enter ran the registry row prompt_window_title (got: $($ran7 -join ', '); pre-fix Down reached the duplicate, user:Change Window Title)"
    }
}

Assert ($null -ne (Get-Process -Id $script:appPid -ErrorAction SilentlyContinue)) 'the app survived all arms'

} catch {
    # T1511: this try cannot end in `Complete-TestBody` (the foreground-leak
    # check below is part of the run), so it SCORES its own throw.
    $script:fail++
    Write-Host "FAIL  script terminated: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "      at $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())"
} finally {
    Remove-TestDesktop
    Stop-DebugGhoztty
    Clear-PaletteHistory
}

$fgSeen = @(Stop-TestForegroundWatch)
Write-Host "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @(Get-TestLaunchedPids)
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'no test-desktop app ever became foreground on the interactive desktop'
}

Complete-TestBody  # T1039: the last statement of the body an unwind can skip

Write-Host ''
if ($script:fail -eq 0) {
    # A clean green run records the covered files so scripts\guard-due.ps1 can
    # answer "has anyone run this harness against the code as it now stands?"
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard palette-order -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Label 'PALETTE ORDER'
