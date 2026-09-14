# Machine-chooser MODELESS acceptance (tracker T712).
#
# The defect, as a user would describe it: open "New Window" and the terminal
# behind it is frozen. You cannot type in it, you cannot close a tab, you
# cannot watch the session roster react to anything you do - the picker shows a
# snapshot and the only way to get your terminal back is to dismiss it.
#
# Mac fixed the same thing in `78a21daa8`: the picker used to run under
# `NSApp.runModal` and is now a floating, modeless panel, "which is the point:
# close a window and watch the roster update". The Windows half was one line -
# `EnableWindow(owner, 0)` in `MachineChooser.open` - which disables the owner
# top-level window and every control inside it for as long as the dialog is up.
#
# What is measured, all of it against a chooser that is open:
#
#   A. the chooser opens and the OWNER WINDOW IS ENABLED. `IsWindowEnabled` on
#      the owner is the cross-process modality check (the same oracle
#      `activity-monitor.ps1` uses for the dialogs that are still modal on
#      purpose), and it is the arm the unfixed build fails.
#   B. the terminal behind it ACCEPTS THE KEYBOARD: the window takes activation
#      while the picker is up, and a chord aimed at the pane really acts (a new
#      split appears). Neither of those discriminates on its own - posted input
#      and programmatic activation both walk past `EnableWindow`, and both were
#      measured green against the unfixed build - so they are the "and then it
#      works" half, not the teeth. A is the arm the unfixed build fails.
#   C. the picker does not go away when you work behind it - still visible,
#      still directly above its owner in the z-order with nothing sandwiched
#      between (Mac's `.floating` + `hidesOnDeactivate = false`, translated to
#      the owner relationship Windows already gives an owned popup).
#   D. and it is still a WORKING picker afterwards: its filter still narrows the
#      list, Escape still dismisses it, and the owner is enabled and alive at
#      the end. A picker that survived by becoming inert is not a fix.
#
# Teeth: `-NegativeControl` inverts A's assertion to "the owner is disabled
# while the chooser is up", which is the pre-T712 behavior and MUST fail.
#
#   powershell -NoProfile -File test\win32\chooser-modeless.ps1
#
# T218-era rules: runs on a BACKGROUND test desktop and only ever touches
# ghoztty processes running from this repo's zig-out.
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [switch]$NegativeControl,
    [switch]$Interactive
)

# T351: the shared reset/kill helpers, dot-sourced ahead of any isolation setup
# because it drops an inherited $GHOZTTY_IPC_SOCKET - a test never wants the
# caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not (Test-Path $Exe)) { $Exe = Join-Path $repo 'zig-out\bin\ghoztty.exe' }

# Isolate the IPC endpoint (inherited through CreateProcessW): an instance
# answering the shared pipe would let another run's windows into this one.
$env:GHOZTTY_PIPE_SUFFIX = "-t712$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\ChooserControls.ps1')

$script:pass = 0
$script:fail = 0
$script:negReached = $false
# A drive that throws part way unwinds to `finally` and would otherwise reach
# the summary having scored only the setup.
$script:drove = $false

function Assert([bool]$cond, [string]$name) {
    if ($cond) { Write-Host "  PASS $name"; $script:pass++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:fail++ }
}

# The list is owner-drawn and LBS_HASSTRINGS-less, so its item COUNT is the
# filter's whole visible output.
$LB_GETCOUNT = 0x018B
function Get-RowCount([IntPtr]$List) {
    # [int64], never [int]: a dead app answers [int64]::MinValue and casting
    # that to Int32 throws, replacing the assertion that would have named the
    # crash with a PowerShell stack trace.
    return [int64](Invoke-TestMessage -Window $List -Message $LB_GETCOUNT)
}

# `ghoztty +verb > file` writes zero bytes from PowerShell (T245) - capture
# through a pipe instead. `+list --json` reports each tab's split TREE, so the
# pane count is its leaf count.
function Count-Leaves($node) {
    if ($null -eq $node) { return 0 }
    if ($node.type -eq 'leaf') { return 1 }
    return (Count-Leaves $node.left) + (Count-Leaves $node.right)
}

function Get-PaneCount {
    $out = (& $Exe +list --json 2>$null | Out-String)
    if (-not $out -or $out.Trim().Length -eq 0) { return -1 }
    try { $j = $out | ConvertFrom-Json } catch { return -1 }
    if ($null -eq $j) { return -1 }
    $n = 0
    foreach ($w in @($j.data.windows)) {
        foreach ($t in @($w.tabs)) { $n += (Count-Leaves $t.splits) }
    }
    return $n
}

if (-not (Test-Path $Exe)) {
    Write-TestAssertedNothing -Label 'CHOOSER MODELESS ACCEPTANCE' -Reason "$Exe not found"
}
Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null

$tmp = Join-Path $env:TEMP "ghoztty-t712-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null
$errlog = Join-Path $tmp 'stderr.log'

Write-Host 'T712 machine chooser is modeless'
[void](Reset-GhozttyTestState -Exe $Exe -SettleMs 800)
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    # persistence: explicitly off - this script restores nothing and must not
    # inherit whatever panes the previous run left in the manifest.
    $app = Start-OnTestDesktop -Exe $Exe -Arguments @('--session-persistence=false') -StdErr $errlog
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) {
        Write-Host 'SETUP FAIL: GUI died at launch'
        Write-TestVerdict -Label 'CHOOSER MODELESS ACCEPTANCE' -Pass $script:pass -Fail ($script:fail + 1)
    }

    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) {
        Write-Host 'SETUP FAIL: GhozttyWindow not found'
        Write-TestVerdict -Label 'CHOOSER MODELESS ACCEPTANCE' -Pass $script:pass -Fail ($script:fail + 1)
    }
    $surface = Get-TestChildWindow -Window $top -Class 'GhozttyTerminal'

    # --- A. the chooser opens, and the terminal is NOT frozen ---------------
    Write-Host ''
    Write-Host '=== A: the window behind the picker stays enabled ==='
    Assert (Test-TestWindowEnabled -Window $top) 'A the owner window is enabled before the chooser opens (control)'

    [void](Send-TestKeys -Window $top -Target $surface -Modifiers ctrl, shift -Key N)
    $chooser = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyMachineChooser' -TimeoutMs 5000
    Assert ($chooser -ne [IntPtr]::Zero) 'A ctrl+shift+n opened the chooser'
    if ($chooser -eq [IntPtr]::Zero) {
        Write-Host 'SETUP FAIL: no chooser to score'
        Write-TestVerdict -Label 'CHOOSER MODELESS ACCEPTANCE' -Pass $script:pass -Fail ($script:fail + 1)
    }
    Start-Sleep -Milliseconds 800

    $ownerEnabled = Test-TestWindowEnabled -Window $top
    if ($NegativeControl) {
        $script:negReached = $true
        Write-Host 'NEGATIVE CONTROL: asserting the owner is DISABLED while the chooser is up (pre-T712) - this run MUST fail'
        Assert (-not $ownerEnabled) "A (inverted): the owner window is disabled while the chooser is up (really enabled=$ownerEnabled)"
    } else {
        Assert $ownerEnabled 'A the owner window is STILL ENABLED while the chooser is up'
    }
    # NOT asserted here: `IsWindowEnabled` on the terminal CHILD. It reads that
    # window's own flag, so it answers TRUE while a disabled parent is swallowing
    # every keystroke aimed at it - measured against the unfixed build, where it
    # scored a green PASS beside the red owner. An oracle that cannot see the
    # defect is worse than no oracle.

    # --- B. and it really accepts input -------------------------------------
    Write-Host ''
    Write-Host '=== B: you can keep working in the terminal behind it ==='
    $panesBefore = Get-PaneCount
    Assert ($panesBefore -ge 1) "B the window has panes to start with (found $panesBefore)"

    # Activation, asserted through the thread's own active hwnd because a
    # background desktop has no foreground window. Measured, not assumed: this
    # arm ALSO passes against the unfixed build - `AttachThreadInput` +
    # `SetActiveWindow` is not the mouse, and the disable that stops a user
    # clicking through does not stop a programmatic activation. It is here as
    # the "and then it works" half, like the chord below; A is the arm with the
    # teeth.
    [void](Set-TestActiveWindow -Window $top)
    Start-Sleep -Milliseconds 500
    $active = Get-TestActiveWindow -Window $top
    Assert ($active -eq $top) 'B clicking the terminal behind the picker activates it'

    # And the keyboard really acts there: ctrl+shift+d splits the focused pane.
    # A posted chord reaches a WndProc whatever EnableWindow says, so this arm
    # is the "it works" half rather than the discriminating one - A is where
    # the unfixed build dies.
    $surface = Get-TestChildWindow -Window $top -Class 'GhozttyTerminal'
    [void](Send-TestKeys -Window $top -Target $surface -Modifiers ctrl, shift -Key D)
    Start-Sleep -Seconds 2
    $panesAfter = Get-PaneCount
    Assert ($panesAfter -eq ($panesBefore + 1)) `
        "B a split chord aimed at the terminal really split it ($panesBefore -> $panesAfter)"

    # --- C. the picker stayed put while you worked --------------------------
    Write-Host ''
    Write-Host '=== C: the picker floats above its window instead of hiding ==='
    Assert (Test-TestWindowExists -Window $chooser) 'C the chooser is still open after working behind it'
    Assert (Test-TestWindowVisible -Window $chooser) 'C and still visible (it does not hide on deactivate)'
    $sandwich = Get-TestOverlaySandwich -Overlay $chooser -Owner $top
    Assert ($sandwich -eq '0:') "C the chooser is still directly above its owner (sandwich=$sandwich)"

    # --- D. and it is still a working picker --------------------------------
    Write-Host ''
    Write-Host '=== D: the picker still works after the detour ==='
    $filterCtl = Get-ChooserFilterField -Chooser $chooser
    $listCtl = Get-ChooserList -Chooser $chooser
    Assert ($null -ne $filterCtl -and $null -ne $listCtl) 'D the filter field and the list are still there'
    if ($filterCtl -and $listCtl) {
        $filterHwnd = ConvertTo-TestHwnd $filterCtl
        $listHwnd = ConvertTo-TestHwnd $listCtl
        $baseline = Get-RowCount $listHwnd
        Assert ($baseline -ge 1) "D an empty filter still lists at least the Local row (rows=$baseline)"

        [void](Set-TestControlText -Control $filterHwnd -Text 'zzzznope')
        Start-Sleep -Milliseconds 500
        $narrowed = Get-RowCount $listHwnd
        Assert ($narrowed -eq 0) "D the filter still narrows the list (rows=$narrowed)"

        [void](Set-TestControlText -Control $filterHwnd -Text '')
        Start-Sleep -Milliseconds 400
        Assert ((Get-RowCount $listHwnd) -eq $baseline) 'D clearing the filter restores every row'

        [void](Focus-TestWindow -Window $chooser -Child $filterHwnd)
        Start-Sleep -Milliseconds 300
        [void](Send-TestKeys -Window $chooser -Target $filterHwnd -Key Escape)
        Start-Sleep -Seconds 1
        Assert (-not (Test-TestWindowExists -Window $chooser)) 'D Escape still dismisses the picker'
    }

    Assert (Test-TestWindowEnabled -Window $top) 'D the terminal window is enabled once the picker is gone'
    Assert (Test-TestWindowExists -Window $top) 'D the terminal window is still open'
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'D the app survived the whole drive'
    Assert (-not (Select-String -Path $errlog -Pattern 'panic:' -Quiet)) 'D no panic reached the app log'
    $script:drove = $true
    Complete-TestBody  # T1039: the run reached the end of its body

} finally {
    Remove-TestDesktop
    [void](Reset-GhozttyTestState -Exe $Exe -SettleMs 800)
}

$fgSeen = @(Stop-TestForegroundWatch)
Write-Host "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @(Get-TestLaunchedPids)
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    Assert ($launched.Count -gt 0) 'the run actually launched apps on the test desktop'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'no test-desktop app ever became foreground on the interactive desktop'
}

Assert $script:drove 'the drive ran to the end (nothing threw out of it)'
if ($NegativeControl -and -not $script:negReached) {
    Assert $false 'NEGATIVE CONTROL never reached its inverted assertion'
}

# --- stamp (T783) -----------------------------------------------------------
# A clean green run records the covered files so scripts\guard-due.ps1 can
# answer "has anyone run this harness against the code as it now stands?".
if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard chooser-modeless -Repo $repo 2>&1 | ForEach-Object { Write-Host "  $($_.ToString())" }
}

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-TestVerdict -Label 'CHOOSER MODELESS ACCEPTANCE' -Pass $script:pass -Fail $script:fail
