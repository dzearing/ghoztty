# The Activity Monitor's "Show all" checkbox is DISABLED when it can do nothing
# (tracker T1748).
#
# WHAT IS PROMISED. "Show all" switches the table between every process and
# only the ones Ghoztty started. Telling those apart needs a root pid (the agent
# or this app) or at least one row attributed to a pane. An agent that pre-dates
# PROC_SNAPSHOT.agent_pid, on a machine with no pane of ours, gives neither - so
# there is nothing to narrow to and the table always shows everything. Mac
# disables the toggle then (RemoteActivityMonitorView.swift:1016-1024,
# `.disabled(!canFilterSpawned)`) and its help says why: "This agent pre-dates
# spawned-process filtering, so all processes are shown." win32 used to leave it
# clickable, so unchecking it silently changed nothing.
#
# HOW THE STATE IS MADE. Every agent this repo builds sends agent_pid and a
# Local panel always knows its own pid, so the no-evidence state cannot arise on
# its own here. GHOZTTY_TEST_ACTIVITY_NO_SPAWNED=1 (debug builds only,
# activity_sample.zig) makes a Local panel's samples carry no root and no pane
# attribution - exactly what such an agent hands back - and everything
# downstream (filter, enable, focus ring, hover) runs for real.
#
# WHAT IS ASSERTED
#   A  run 1, the seam set: the app announces it, the panel logs
#      `show-all enabled=false`, and the control itself reads disabled
#      (IsWindowEnabled - the control, not the app's word for it)
#   B  run 1: the table shows every row (shown == total) and a click where the
#      checkbox is - delivered to the panel, which is where Windows routes the
#      pointer over a disabled child - changes nothing
#   C  run 1: hovering the disabled checkbox still explains it, with Mac's
#      "pre-dates" sentence (a disabled control gets no mouse input of its own,
#      so the panel answers for it)
#   D  run 1: Tab from the filter steps OVER the disabled checkbox (and the
#      hidden Kill) to New Process
#   E  run 2, no seam (the NEGATIVE CONTROL): `show-all enabled=true`, the
#      control reads enabled, Tab from the filter lands ON it, entering it
#      derives the "When off" sentence, and the panel-routed hover that C used
#      derives nothing. Without E, A-D would pass equally well against a
#      checkbox that is disabled unconditionally.
#
# Isolation: the IPC endpoint is keyed on $PID and persistence is off (T248).
# T211/T217: runs on a BACKGROUND desktop and never takes the user's foreground.
#
#   powershell -NoProfile -File test\win32\activity-show-all-disabled.ps1
#
# Only touches ghoztty processes running from this repo's zig-out.
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe'
)

# T351: the shared reset/kill helpers. Dot-sourced HERE, ahead of any isolation
# setup, because it drops an inherited $GHOZTTY_IPC_SOCKET.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not (Test-Path $Exe)) { $Exe = Join-Path $repo 'zig-out\bin\ghoztty.exe' }

$env:GHOZTTY_PIPE_SUFFIX = "-t1748$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')

$WM_MOUSEMOVE = 0x0200
$WM_SETCURSOR = 0x0020
$WM_LBUTTONDOWN = 0x0201
$WM_LBUTTONUP = 0x0202
$MK_LBUTTON = 0x0001
$HTCLIENT = 1
$PRE_DATES = 'This agent pre-dates spawned-process filtering, so all processes are shown.'
$WHEN_OFF = 'When off, show only processes Ghoztty started (the agent and its descendants).'

$script:pass = 0
$script:fail = 0
$script:skipped = 0
function Assert($cond, $name) {
    if ($cond) { Write-Host "  PASS $name"; $script:pass++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:fail++ }
}

$tmp = Join-Path $env:TEMP "ghoztty-t1748-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

function Get-LastLineNo($log, $pattern) {
    if (-not (Test-Path $log)) { return 0 }
    $m = @(Select-String -Path $log -Pattern $pattern -ErrorAction SilentlyContinue)
    if ($m.Count -eq 0) { return 0 }
    return $m[-1].LineNumber
}

function Wait-LogCount($log, $pattern, $want, $timeoutMs) {
    $waited = 0
    while ($waited -lt $timeoutMs) {
        if (Test-Path $log) {
            if (@(Select-String -Path $log -Pattern $pattern -ErrorAction SilentlyContinue).Count -ge $want) { return $true }
        }
        Start-Sleep -Milliseconds 250
        $waited += 250
    }
    return $false
}

# The text of the newest help line for $target newer than line $afterLine, or
# $null when none arrives.
function Wait-HelpText($log, $target, $afterLine, $timeoutMs = 4000) {
    $pattern = "activity help tooltip target=$target text=(.*)$"
    $waited = 0
    while ($waited -lt $timeoutMs) {
        if (Test-Path $log) {
            $m = @(Select-String -Path $log -Pattern $pattern -Encoding UTF8 -ErrorAction SilentlyContinue)
            if ($m.Count -gt 0 -and $m[-1].LineNumber -gt $afterLine) {
                if ($m[-1].Line -match $pattern) { return $Matches[1] }
            }
        }
        Start-Sleep -Milliseconds 250
        $waited += 250
    }
    return $null
}

function Pack-Point([int]$x, [int]$y) {
    return [IntPtr]((($y -band 0xFFFF) -shl 16) -bor ($x -band 0xFFFF))
}

function Move-Pointer([IntPtr]$window, [int]$x, [int]$y, [int]$settleMs = 300) {
    [void](Send-TestRawMessage -Window $window -Message $WM_MOUSEMOVE -LParam (Pack-Point $x $y))
    Start-Sleep -Milliseconds $settleMs
}

# The newest Local state line, or $null.
function Get-PanelState($log) {
    if (-not (Test-Path $log)) { return $null }
    $pat = 'activity monitor: source=Local total=(\d+) shown=(\d+) needle="[^"]*" show_all=(\w+) .* root=(\d+) panes=(\d+) attributed=(\d+)'
    $m = @(Select-String -Path $log -Pattern $pat) | Select-Object -Last 1
    if (-not $m) { return $null }
    $g = $m.Matches[0].Groups
    return [pscustomobject]@{
        Total = [int]$g[1].Value; Shown = [int]$g[2].Value; ShowAll = ($g[3].Value -eq 'true')
        Root = [int64]$g[4].Value; Attributed = [int]$g[6].Value; Line = $m.LineNumber
    }
}

# The newest `show-all enabled=` value, or $null when none was logged.
function Get-EnabledLog($log) {
    $m = @(Select-String -Path $log -Pattern 'activity monitor: show-all enabled=(\w+)' -ErrorAction SilentlyContinue) | Select-Object -Last 1
    if (-not $m) { return $null }
    return ($m.Matches[0].Groups[1].Value -eq 'true')
}

# Launch the app, open a Local Activity Monitor, and return what the run needs.
# $null when the fixture could not be built (the caller reports it).
function Open-Panel($log) {
    [void](Reset-GhozttyTestState -Exe $Exe -SettleMs 500)
    $app = Start-OnTestDesktop -Exe $Exe -Arguments @('--session-persistence=false') -StdErr $log
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { return $null }
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { return $null }
    $surface = Get-TestChildWindow -Window $top -Class 'GhozttyTerminal'

    $panel = [IntPtr]::Zero
    foreach ($try in 1..3) {
        if (Send-TestKeys -Window $top -Target $surface -Modifiers ctrl, shift -Key P) {
            $popup = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyCommandPalette' -TimeoutMs 5000
            if ($popup -ne [IntPtr]::Zero) {
                $edit = Find-TestWindowEx -Parent $popup -Class 'EDIT'
                if ($edit -ne [IntPtr]::Zero) {
                    Send-TestControlText -Control $edit -Text 'ACTIVITY MONITOR' | Out-Null
                    [void](Send-TestControlKey -Control $edit -Key Enter)
                    $panel = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyActivityMonitor' -TimeoutMs 8000
                }
            }
        }
        if ($panel -ne [IntPtr]::Zero) { break }
        Start-Sleep -Milliseconds 500
    }
    if ($panel -eq [IntPtr]::Zero) { return $null }
    if (-not (Wait-LogCount $log 'activity monitor: source=Local total=' 1 10000)) { return $null }
    # The enable decision follows the first sample; give the second poll a beat
    # so a value that flips on attribution has flipped.
    Start-Sleep -Milliseconds 1500

    $buttons = @(Get-TestChildWindows -Window $panel -Class 'Button')
    $showAll = $buttons | Where-Object { (Get-TestControlText -Control ([IntPtr]$_.Hwnd)) -eq 'Show all' } | Select-Object -First 1
    $newProc = $buttons | Where-Object { (Get-TestControlText -Control ([IntPtr]$_.Hwnd)) -like 'New Process*' } | Select-Object -First 1
    $filter = Find-TestWindowEx -Parent $panel -Class 'EDIT'
    if (-not ($showAll -and $newProc) -or $filter -eq [IntPtr]::Zero) { return $null }

    $client = Get-TestWindowRect -Window $panel -Client
    $sa = Get-TestWindowRect -Window ([IntPtr]$showAll.Hwnd)
    return [pscustomobject]@{
        App     = $app
        Panel   = $panel
        ShowAll = [IntPtr]$showAll.Hwnd
        NewProc = [IntPtr]$newProc.Hwnd
        Filter  = $filter
        # The checkbox's centre, in the panel's client coordinates.
        SaX     = [int](($sa.Left + $sa.Right) / 2) - $client.Left
        SaY     = [int](($sa.Top + $sa.Bottom) / 2) - $client.Top
        Client  = $client
    }
}

# Tab from the filter; the window that holds focus afterwards.
function Tab-FromFilter($fx) {
    Send-TestControlKey -Control $fx.Filter -Key Tab | Out-Null
    Start-Sleep -Milliseconds 300
    return (Get-TestFocusedWindow -Window $fx.Panel)
}

Write-Host 'T1748 Activity Monitor disables Show all when it cannot filter'
Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null
New-TestDesktop | Out-Null

try {
    # --- A-D: no spawned-set evidence ---------------------------------------
    Write-Host ''
    Write-Host '1. a Local panel whose samples name no root and no pane'
    $log1 = Join-Path $tmp 'seam.log'
    $env:GHOZTTY_TEST_ACTIVITY_NO_SPAWNED = '1'
    try { $fx = Open-Panel $log1 } finally { Remove-Item Env:\GHOZTTY_TEST_ACTIVITY_NO_SPAWNED -ErrorAction SilentlyContinue }
    if ($null -eq $fx) { Write-TestAssertedNothing -Reason 'no Activity Monitor panel with the seam set' -Skipped $script:skipped }

    Assert (Select-String -Path $log1 -Pattern 'test seam active: GHOZTTY_TEST_ACTIVITY_NO_SPAWNED=1' -Quiet) `
        'A the app announces the no-spawned seam'
    $st = Get-PanelState $log1
    Assert ($st -and $st.Root -eq 0 -and $st.Attributed -eq 0) `
        "A the samples carry no root and no attribution (root=$(if ($st) { $st.Root }) attributed=$(if ($st) { $st.Attributed }))"
    Assert ((Get-EnabledLog $log1) -eq $false) 'A the panel logs show-all enabled=false'
    Assert (-not (Test-TestWindowEnabled -Window $fx.ShowAll)) 'A the Show all control itself reads DISABLED'

    # D runs before B: B's click lands on the panel, which hands the keyboard
    # to the table, and Tab is scored from the filter as the panel opened.
    $focused = Tab-FromFilter $fx
    Assert ($focused -eq $fx.NewProc) "D Tab from the filter steps over the disabled checkbox to New Process (focus=$focused)"
    Assert ($focused -ne $fx.ShowAll) 'D the disabled checkbox never takes focus'

    Assert ($st -and $st.Total -gt 0 -and $st.Shown -eq $st.Total) `
        "B the table shows every process (shown=$(if ($st) { $st.Shown }) total=$(if ($st) { $st.Total }))"
    $before = (Get-PanelState $log1).ShowAll
    $lp = Pack-Point $fx.SaX $fx.SaY
    [void](Send-TestRawMessage -Window $fx.Panel -Message $WM_LBUTTONDOWN -WParam ([IntPtr]$MK_LBUTTON) -LParam $lp)
    [void](Send-TestRawMessage -Window $fx.Panel -Message $WM_LBUTTONUP -WParam ([IntPtr]0) -LParam $lp)
    Start-Sleep -Milliseconds 1500
    $after = Get-PanelState $log1
    Assert ($after -and $after.ShowAll -eq $before -and $after.Shown -eq $after.Total) `
        "B a click on the disabled checkbox changes nothing (show_all $before -> $(if ($after) { $after.ShowAll }))"
    Assert (-not (Test-TestWindowEnabled -Window $fx.ShowAll)) 'B the control is still disabled after the click'

    # The panel's own WM_SETCURSOR first (what the real pointer sends over a
    # disabled child), then the move that carries the point.
    $line = Get-LastLineNo $log1 'activity help tooltip target='
    $sc = [IntPtr](($WM_MOUSEMOVE -shl 16) -bor $HTCLIENT)
    [void](Send-TestRawMessage -Window $fx.Panel -Message $WM_SETCURSOR -WParam $fx.Panel -LParam $sc)
    Move-Pointer $fx.Panel $fx.SaX $fx.SaY
    $got = Wait-HelpText $log1 'show-all' $line
    Assert ($got -ceq $PRE_DATES) "C hovering the disabled checkbox explains it with Mac's sentence (got '$got')"
    Move-Pointer $fx.Panel ([int]($fx.Client.Width / 2)) ([int]($fx.Client.Height * 3 / 4))
    Assert (Wait-LogCount $log1 'activity help tooltip dropped target=show-all$' 1 4000) 'C moving off it drops the tip'

    Assert (-not ($fx.App.Process -and $fx.App.Process.HasExited)) 'the app survived the no-spawned run'
    Assert (-not (Select-String -Path $log1 -Pattern 'panic:' -Quiet)) 'no panic reached the no-spawned run''s log'
    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 500)

    # --- E: the ordinary panel (negative control) ---------------------------
    Write-Host ''
    Write-Host '2. the same panel without the seam'
    $log2 = Join-Path $tmp 'plain.log'
    $fx = Open-Panel $log2
    if ($null -eq $fx) { Write-TestAssertedNothing -Reason 'no Activity Monitor panel without the seam' -Skipped $script:skipped }

    Assert (-not (Select-String -Path $log2 -Pattern 'test seam active: GHOZTTY_TEST_ACTIVITY_NO_SPAWNED' -Quiet)) `
        'E with the variable unset, no seam is announced'
    $st = Get-PanelState $log2
    Assert ($st -and $st.Root -ne 0) "E the samples carry this app's root pid (root=$(if ($st) { $st.Root }))"
    Assert ((Get-EnabledLog $log2) -eq $true) 'E the panel logs show-all enabled=true'
    Assert (Test-TestWindowEnabled -Window $fx.ShowAll) 'E the Show all control reads ENABLED'
    Assert ($st -and $st.Shown -lt $st.Total) "E the spawned-only filter is narrowing the table (shown=$(if ($st) { $st.Shown }) total=$(if ($st) { $st.Total }))"

    $focused = Tab-FromFilter $fx
    Assert ($focused -eq $fx.ShowAll) "E Tab from the filter lands on the enabled checkbox (focus=$focused)"

    $line = Get-LastLineNo $log2 'activity help tooltip target='
    $sc = [IntPtr](($WM_MOUSEMOVE -shl 16) -bor $HTCLIENT)
    [void](Send-TestRawMessage -Window $fx.Panel -Message $WM_SETCURSOR -WParam $fx.Panel -LParam $sc)
    Move-Pointer $fx.Panel $fx.SaX $fx.SaY
    Start-Sleep -Milliseconds 500
    Assert ((Get-LastLineNo $log2 'activity help tooltip target=show-all text=') -le $line) `
        'E with the checkbox enabled, the panel-routed hover C used derives nothing (comctl32 owns that tip)'
    [void](Send-TestRawMessage -Window $fx.ShowAll -Message $WM_SETCURSOR -WParam $fx.ShowAll -LParam $sc)
    $got = Wait-HelpText $log2 'show-all' $line
    Assert ($got -ceq $WHEN_OFF) "E entering the enabled checkbox derives the When-off sentence (got '$got')"

    Assert (-not ($fx.App.Process -and $fx.App.Process.HasExited)) 'the app survived the plain run'
    Assert (-not (Select-String -Path $log2 -Pattern 'panic:' -Quiet)) 'no panic reached the plain run''s log'

    Complete-TestBody  # T1039: the run reached the end of its body
} finally {
    Remove-TestDesktop
    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 500)
}

# --- stamp (T783) -------------------------------------------------------------
# A checkbox that stopped disabling looks exactly like one that works, and no
# other harness can take a Local panel's spawned-set evidence away.
if ($script:fail -eq 0 -and $script:skipped -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard activity-show-all-disabled -Repo $repo 2>&1 | ForEach-Object { Write-Host "  $($_.ToString())" }
}

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Skipped $script:skipped -MinPass 23
