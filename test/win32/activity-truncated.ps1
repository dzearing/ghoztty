# The Activity Monitor says when its process list was CUT (tracker T1640).
#
# WHAT IS PROMISED. The panel shows at most max_rows (512) processes. When the
# machine runs more than that, the table on screen is the top slice, not the
# whole machine, and the control bar says so with Mac's words
# (RemoteActivityMonitorView.swift:998-1003): a "List truncated" badge beside
# the Show all checkbox, whose hover help reads "The agent capped the process
# table; some rows are not shown." When the table fit, the bar says nothing.
#
# The badge has been painted since T286 and explained since T1634; what was
# never demonstrated is that it appears when - and only when - the table was
# cut. A local table on an ordinary box never reaches 512 rows, so the
# activity-help-tooltips harness could only ever show the badge ABSENT.
#
# HOW THE CUT IS MADE. GHOZTTY_TEST_ACTIVITY_ROW_CAP=<n> (debug builds only,
# activity_sample.zig) lowers the Local panel's row cap, so the real sampler
# returns a real truncated snapshot through the real adopt/paint/hover path.
# Nothing downstream of the sampler is faked.
#
# WHAT IS ASSERTED
#   A  run 1, the seam at 20 rows: the app announces the seam, the panel's
#      state line reads total=20 truncated=true
#   B  run 1: walking right from the checkbox finds the badge, and its help is
#      Mac's sentence - the badge is on screen exactly where the bar says it is
#   C  run 2, no seam (the NEGATIVE CONTROL): the state line reads
#      truncated=false and the same walk finds no badge at all. Without C, B
#      would pass equally well against a badge painted unconditionally.
#
# WHY A LOG LINE IS AN ORACLE. The badge is GDI text with nothing to read back.
# The panel logs what its hover derived (`activity help tooltip target=badge
# text=...`), and the hover derives a badge tip only where the badge's own
# painted text is (activity_hover.paintedAt measures the same string the paint
# draws), so a badge hit IS the badge's presence.
#
# C needs a box under the cap. If this box is itself over 512 processes the
# unseamed table is truncated for real; C is then SKIPPED, loudly, rather than
# scored against a premise that does not hold.
#
# Isolation: the IPC endpoint is keyed on $PID and persistence is off (T248).
# T211/T217: runs on a BACKGROUND desktop and never takes the user's foreground.
#
#   powershell -NoProfile -File test\win32\activity-truncated.ps1
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

$env:GHOZTTY_PIPE_SUFFIX = "-t1640$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')

$WM_MOUSEMOVE = 0x0200
$MAX_ROWS = 512              # ActivityMonitor.max_rows
$SEAM_CAP = 20
$MAC_SENTENCE = 'The agent capped the process table; some rows are not shown.'

$script:pass = 0
$script:fail = 0
$script:skipped = 0
function Assert($cond, $name) {
    if ($cond) { Write-Host "  PASS $name"; $script:pass++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:fail++ }
}
function Skip($name) {
    Write-Host "  SKIP $name" -ForegroundColor Yellow
    $script:skipped++
}

$tmp = Join-Path $env:TEMP "ghoztty-t1640-$PID"
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
    $pat = 'activity monitor: source=Local total=(\d+) shown=(\d+) .* truncated=(\w+)'
    $m = @(Select-String -Path $log -Pattern $pat) | Select-Object -Last 1
    if (-not $m) { return $null }
    $g = $m.Matches[0].Groups
    return [pscustomobject]@{ Total = [int]$g[1].Value; Truncated = ($g[3].Value -eq 'true') }
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

    $buttons = @(Get-TestChildWindows -Window $panel -Class 'Button')
    $showAll = $buttons | Where-Object { (Get-TestControlText -Control ([IntPtr]$_.Hwnd)) -eq 'Show all' } | Select-Object -First 1
    $newProc = $buttons | Where-Object { (Get-TestControlText -Control ([IntPtr]$_.Hwnd)) -like 'New Process*' } | Select-Object -First 1
    if (-not ($showAll -and $newProc)) { return $null }

    $client = Get-TestWindowRect -Window $panel -Client
    $sa = Get-TestWindowRect -Window ([IntPtr]$showAll.Hwnd)
    $np = Get-TestWindowRect -Window ([IntPtr]$newProc.Hwnd)
    return [pscustomobject]@{
        App     = $app
        Panel   = $panel
        RowY    = [int](($sa.Top + $sa.Bottom) / 2) - $client.Top
        SaRight = $sa.Right - $client.Left
        NpLeft  = $np.Left - $client.Left
        Client  = $client
    }
}

# Walk right from the checkbox toward New Process. Returns the badge's help
# text at the first point whose hover derives one, or $null when the walk found
# no badge anywhere on the row.
function Find-Badge($log, $fx) {
    $before = Get-LastLineNo $log 'activity help tooltip target=badge text='
    for ($x = $fx.SaRight + 2; $x -lt $fx.NpLeft; $x += 3) {
        Move-Pointer $fx.Panel $x $fx.RowY 60
        if ((Get-LastLineNo $log 'activity help tooltip target=badge text=') -gt $before) {
            Start-Sleep -Milliseconds 200
            $m = @(Select-String -Path $log -Pattern 'activity help tooltip target=badge text=(.*)$' -Encoding UTF8) | Select-Object -Last 1
            if ($m -and $m.Line -match 'text=(.*)$') { return $Matches[1] }
            return ''
        }
    }
    return $null
}

Write-Host 'T1640 Activity Monitor says when its process list was cut'
Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null
New-TestDesktop | Out-Null

try {
    # --- A/B: the seam cuts the table -------------------------------------
    Write-Host ''
    Write-Host "1. a Local panel capped at $SEAM_CAP rows"
    $log1 = Join-Path $tmp 'seam.log'
    $env:GHOZTTY_TEST_ACTIVITY_ROW_CAP = "$SEAM_CAP"
    try { $fx = Open-Panel $log1 } finally { Remove-Item Env:\GHOZTTY_TEST_ACTIVITY_ROW_CAP -ErrorAction SilentlyContinue }
    if ($null -eq $fx) { Write-TestAssertedNothing -Reason 'no Activity Monitor panel with the seam set' -Skipped $script:skipped }

    Assert (Select-String -Path $log1 -Pattern "test seam active: GHOZTTY_TEST_ACTIVITY_ROW_CAP=$SEAM_CAP" -Quiet) `
        'A the app announces the row-cap seam'
    $st = Get-PanelState $log1
    Assert ($st -and $st.Total -eq $SEAM_CAP) "A the panel holds exactly the capped rows (total=$(if ($st) { $st.Total } else { 'no state line' }))"
    Assert ($st -and $st.Truncated) 'A the state line says the table was truncated'

    $tip = Find-Badge $log1 $fx
    Assert ($null -ne $tip) 'B walking right from Show all finds the badge'
    Assert ($tip -ceq $MAC_SENTENCE) "B the badge explains itself with Mac's sentence (got '$tip')"
    Assert (-not ($fx.App.Process -and $fx.App.Process.HasExited)) 'B the app survived the capped run'
    Assert (-not (Select-String -Path $log1 -Pattern 'panic:' -Quiet)) 'B no panic reached the capped run''s log'
    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 500)

    # --- C: no seam, no badge (negative control) --------------------------
    Write-Host ''
    Write-Host '2. the same panel, uncapped'
    $log2 = Join-Path $tmp 'plain.log'
    $fx = Open-Panel $log2
    if ($null -eq $fx) { Write-TestAssertedNothing -Reason 'no Activity Monitor panel without the seam' -Skipped $script:skipped }

    Assert (-not (Select-String -Path $log2 -Pattern 'test seam active: GHOZTTY_TEST_ACTIVITY_ROW_CAP' -Quiet)) `
        'C with the variable unset, no seam is announced'
    $st = Get-PanelState $log2
    Assert ($null -ne $st) 'C the uncapped panel logged a state line'
    if ($st -and $st.Total -ge $MAX_ROWS) {
        Skip "C this box runs $($st.Total)+ processes, so the uncapped table is truncated for real - no negative control here"
    } else {
        Assert ($st -and $st.Total -gt $SEAM_CAP) "C the uncapped table is the whole machine (total=$(if ($st) { $st.Total } else { '?' }))"
        Assert ($st -and -not $st.Truncated) 'C the state line says the table fit'
        $tip = Find-Badge $log2 $fx
        Assert ($null -eq $tip) "C the same walk finds no badge (got '$tip')"
    }
    Assert (-not ($fx.App.Process -and $fx.App.Process.HasExited)) 'C the app survived the uncapped run'
    Assert (-not (Select-String -Path $log2 -Pattern 'panic:' -Quiet)) 'C no panic reached the uncapped run''s log'

    Complete-TestBody  # T1039: the run reached the end of its body
} finally {
    Remove-TestDesktop
    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 500)
}

# --- stamp (T783) -------------------------------------------------------------
# A badge that stopped appearing leaves nothing on screen to notice, and no
# other harness can cut a local table.
if ($script:fail -eq 0 -and $script:skipped -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard activity-truncated -Repo $repo 2>&1 | ForEach-Object { Write-Host "  $($_.ToString())" }
}

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Skipped $script:skipped -MinPass 11
