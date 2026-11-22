<#
T277 - toggle_window_float_on_top actually pins the window.

The regression this guards: `SetWindowPos(HWND_TOPMOST)` is not a reliable
report of its own outcome. With no foreground window - a background desktop, a
locked session, the moment between two windows taking focus - it returns TRUE
with GetLastError()==0 and leaves WS_EX_TOPMOST clear, and an identical call
issued immediately after lands. That is why the action read as "a feature that
does nothing" from a KEYBIND while working from the Window menu: the menu path
happened to run with a foreground window and the keybind path did not.
`win32.setTopmost` reads the ex-style back and retries; this script drives the
keybind path, which is the one that used to fail.

Sections:
  A. the bound action pins the window, and toggling again unpins it
  B. the pin propagates to the pane's banner overlay, and survives a banner
     reposition (the "legitimate topmost owner" the T142 heal protects)

NOTE (T607): this script deliberately runs ONE window, and the two-window case
lives in overlay-zorder.ps1 section E, which asserts again as of T607. The old
reading here - that a second ghoztty window puts the first into a state where
nothing can pin it - did not survive measurement: the product's float pins the
first window with two windows up. What is unreliable off the input desktop is a
SINGLE band-change request, because there is no foreground window for
SetWindowPos(HWND_TOPMOST) to succeed against and `setTopmost`'s three retries
are one instant with no pump between them. Section E presses until the band
moves for that reason.
#>
param(
    [string]$ExePath,
    [switch]$Interactive
)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')   # T271/T1768: arms the run, so the stamp below is refused for a body that unwound or asserted nothing

$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }

# Isolate the IPC endpoint (inherited through CreateProcessW) so a real
# instance on the shared pipe cannot answer for this run.
$env:GHOZTTY_PIPE_SUFFIX = "-fottest$PID"

# Section B measures the banner POPUP (GhozttyBannerOverlay) inheriting the
# owner's topmost bit. On the composition present (GHOZTTY_COMP_PRESENT, the
# default since T2514) the banner is a visual inside the pane and the popup
# stays hidden, so B could only ever SKIP. The popup is still the shipped
# fallback on any machine without GL/D3D interop, so pin it here, the way
# pane-banner.ps1 and overlay-zorder.ps1 do (T2747; found under T1561).
$env:GHOZTTY_COMP_PRESENT = '0'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\ListTree.ps1')

$script:pass = 0
$script:fail = 0
$script:skipped = 0   # T1768: the stamp tail tests -eq 0, which $null never is

function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Stop-RepoInstances {
    # T351: one shared, path-exact kill (lib\CleanSlate.ps1) instead of a private
    # copy - the filter this replaced also matched a detached instance running from
    # zig-out-release (T53b), and every copy answered "does the agent go too" alone.
    [void](Stop-RepoGhoztty -Exe $exe -SettleMs 800)
}

function Test-Topmost([IntPtr]$h) {
    return ((Get-TestWindowStyle -Window $h -ExStyle) -band 0x8) -ne 0
}

# Activation is read back from GetGUIThreadInfo: Focus-TestWindow's return is
# about the FOCUSED hwnd, which the app moves to the pane child.
function Set-Active([IntPtr]$top, [IntPtr]$pane) {
    Focus-TestWindow -Window $top -Child $pane | Out-Null
    for ($t = 0; $t -lt 20; $t++) {
        if ((Get-TestActiveWindow -Window $top) -eq [int64]$top) { return $true }
        Start-Sleep -Milliseconds 100
    }
    return $false
}

function Wait-Topmost([IntPtr]$h, [bool]$want) {
    for ($t = 0; $t -lt 25; $t++) {
        if ((Test-Topmost $h) -eq $want) { return $true }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

Stop-RepoInstances
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    # A control keybind alongside the subject: "the chord reached the app" must
    # be measured, or a dead harness reads as a broken feature.
    $app = Start-OnTestDesktop -Exe $exe -Arguments @(
        '--background=#101014',
        '--session-persistence=false',
        '--target=fot1',
        '--keybind=ctrl+shift+f7=toggle_window_float_on_top',
        '--keybind=ctrl+shift+f6=write_screen_file')
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $appPid = $app.Pid
    if ((Wait-TestWindow -ProcessId $appPid -Class 'GhozttyWindow') -eq [IntPtr]::Zero) {
        Write-Host 'SETUP FAIL: no GhozttyWindow'; exit 1
    }
    $A = [IntPtr](@(Get-TestWindows -ProcessId $appPid -Class 'GhozttyWindow')[0].Hwnd)
    $pane = Get-TestChildWindow -Window $A -Class 'GhozttyTerminal'
    if ($pane -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: no terminal child'; exit 1 }
    if (-not (Set-Active $A $pane)) { Write-Host 'SETUP FAIL: could not activate the window'; exit 1 }

    # -----------------------------------------------------------------------
    # A. The bound action pins and unpins the window.
    # -----------------------------------------------------------------------
    Assert (-not (Test-Topmost $A)) 'A: a fresh window is not pinned'

    Send-TestKeys -Window $A -Target $pane -Key F7 -Modifiers ctrl, shift | Out-Null
    Assert (Wait-Topmost $A $true) 'A: the bound toggle_window_float_on_top PINS the window (WS_EX_TOPMOST)'

    Send-TestKeys -Window $A -Target $pane -Key F7 -Modifiers ctrl, shift | Out-Null
    Assert (Wait-Topmost $A $false) 'A: pressing it again unpins the window'

    # -----------------------------------------------------------------------
    # B. A pinned window takes its banner overlay with it, and a reposition of
    # the banner does not knock either of them out of the topmost band. This is
    # the state overlay_zorder's heal is written to leave alone.
    # -----------------------------------------------------------------------
    # Target the pane by its own id rather than a name: the window's name comes
    # from the launch flag, and a banner on the wrong target is a silent no-op
    # that would read here as "the overlay never appeared".
    # A tab's panes are a `splits` TREE in +list --json, not a `panes` array
    # (T1561: this read `.panes` for months, always got $null and always fell
    # back without anybody noticing). lib\ListTree.ps1 walks the real shape.
    $paneId = $null
    $why = $null
    try {
        $json = (& $exe +list --json 2>$null | Out-String).Trim()
        $listed = if ($json) { $json | ConvertFrom-Json } else { $null }
        $first = Get-GhozttyFirstPaneId $listed
        $paneId = $first.Id
        $why = $first.Reason
    } catch { $why = "+list --json did not parse: $($_.Exception.Message)" }
    if ($paneId) {
        Write-Host "SETUP: banner target is pane $paneId (from +list --json)"
    } else {
        Write-Host "SETUP NOTE: no pane id from +list --json ($why); falling back to the window's auto name 'window-1'"
        $paneId = 'window-1'
    }
    $bannerSaid = (& $exe +set-banner --target=$paneId '**T277** pinned owner' 2>&1 | ForEach-Object { $_.ToString() } | Out-String).Trim()
    $ov = $null
    for ($t = 0; $t -lt 25 -and -not $ov; $t++) {
        $ov = @(Get-TestWindows -ProcessId $appPid -Class 'GhozttyBannerOverlay')[0]
        if (-not $ov) { Start-Sleep -Milliseconds 200 }
    }
    if (-not $ov) {
        Write-Host "SKIP B: no banner overlay window appeared (+set-banner --target=$paneId answered: $bannerSaid)"
        $script:skipped++
    } else {
        $ovHwnd = [IntPtr]$ov.Hwnd
        Set-Active $A $pane | Out-Null
        Send-TestKeys -Window $A -Target $pane -Key F7 -Modifiers ctrl, shift | Out-Null
        $pinned = Wait-Topmost $A $true
        Assert $pinned 'B: the window pins with a banner up'
        if ($pinned) {
            Assert (Wait-Topmost $ovHwnd $true) 'B: the pin propagates to the owned banner overlay'
            # A new banner re-lays-out and re-seats the overlay, which is where
            # a heal that cleared the propagated bit would drag the OWNER out of
            # the topmost band with it.
            & $exe +set-banner --target=$paneId '**T277** pinned owner, relaid out' | Out-Null
            Start-Sleep -Milliseconds 1500
            Assert (Test-Topmost $ovHwnd) 'B: a banner reposition PRESERVES the overlay pin'
            Assert (Test-Topmost $A) 'B: and does not knock the window itself out of the band'
            $zOv = Get-TestZIndex -Window $ovHwnd
            $zA = Get-TestZIndex -Window $A
            Assert ($zOv -lt $zA) "B: the overlay is still above its own window (ov=$zOv < win=$zA)"

            Send-TestKeys -Window $A -Target $pane -Key F7 -Modifiers ctrl, shift | Out-Null
            Assert (Wait-Topmost $A $false) 'B: unpinning clears the window'
            Assert (Wait-Topmost $ovHwnd $false) 'B: unpinning clears the overlay with it'
        }
    }

    # -----------------------------------------------------------------------
    # C. With a SECOND window up, the float still works for the window the
    # user is on - and where it does not work, the refusal is the window
    # manager's and not ours (T720).
    #
    # T720 was filed on the reading that float-on-top is still broken. It is
    # not, and the measurement that says so is this section. With two windows
    # open there are two different cases and they must not be confused:
    #
    #   1. The window the user is ON - active, in front. ONE press pins it and
    #      one more unpins it. This is every path a person can actually take:
    #      the keybind and the palette go to the focused window, and the menu
    #      belongs to it. This is the assertion that protects the feature.
    #   2. A window BEHIND another one, which only an injected keystroke can
    #      reach. Here the band change is refused - silently, `SetWindowPos`
    #      returning TRUE with `GetLastError() == 0` and `WS_EX_TOPMOST` still
    #      clear, on all three of `setTopmost`'s attempts.
    #
    # Case 2 is NOT a product defect, and the control below is what proves it:
    # an injection of the same bit from THIS PROCESS - which shares none of
    # the app's code - is refused on the same window in the same state. So the
    # assertion is an EQUALITY, not a verdict about either outcome: whatever
    # the window manager decides for a background window, the app gets the
    # same answer as anybody else asking. If a future Windows starts allowing
    # it, both sides move together and this still passes; if the app ever
    # starts differing from an external caller, something in our code is
    # deciding it, and that is worth a red line.
    #
    # The presses are SINGLE on purpose. A press loop would pass the moment
    # one of its presses happened to land with the window in front, which is
    # how the shape of this defect survived T277 and T607.
    # -----------------------------------------------------------------------
    & $exe +new-window --target=fot2 | Out-Null
    $B = [IntPtr]::Zero
    for ($t = 0; $t -lt 25 -and $B -eq [IntPtr]::Zero; $t++) {
        Start-Sleep -Milliseconds 200
        foreach ($w in @(Get-TestWindows -ProcessId $appPid -Class 'GhozttyWindow')) {
            if ([int64]$w.Hwnd -ne [int64]$A) { $B = [IntPtr]$w.Hwnd; break }
        }
    }
    if ($B -eq [IntPtr]::Zero) {
        Write-Host 'SKIP C: the second window never appeared'
        $script:skipped++
    } else {
        # fot2 is put in front and given the keyboard; the chord is then sent
        # to fot1 where it stands, BEHIND it. Activating fot1 first would
        # raise it and dissolve the very condition under test - which is how
        # this defect survived T277 and T607, both of which activated first.
        $paneB = Get-TestChildWindow -Window $B -Class 'GhozttyTerminal'
        Set-Active $B $paneB | Out-Null
        Start-Sleep -Milliseconds 600
        $zA = Get-TestZIndex -Window $A
        $zB = Get-TestZIndex -Window $B
        Assert ($zA -gt $zB) "C: the subject window really is behind the new one (fot1=$zA > fot2=$zB)"
        Assert (-not (Test-Topmost $A)) 'C: and is not pinned going in'

        # The control: the app's own log says whether the chord ARRIVED, so a
        # press that never reached the window cannot read here as a broken
        # feature (and a pass cannot be scored by a dead harness).
        $errPath = (@(Get-TestLaunchRecords) | Where-Object { $_.Pid -eq $appPid } | Select-Object -First 1).StdErr
        $seenBefore = ([regex]::Matches(
            ((Get-Content $errPath -Raw -ErrorAction SilentlyContinue) + ''),
            'toggle_window_float_on_top')).Count

        Send-TestKeys -Window $A -Target $pane -Key F7 -Modifiers ctrl, shift | Out-Null
        $pinnedBehind = Wait-Topmost $A $true
        $seenAfter = ([regex]::Matches(
            ((Get-Content $errPath -Raw -ErrorAction SilentlyContinue) + ''),
            'toggle_window_float_on_top')).Count
        Assert ($seenAfter -gt $seenBefore) "C: the chord reached the background window (positive control, $seenBefore -> $seenAfter)"

        # The same request, from a process that shares none of the app's code.
        # Ledgered, so it cannot leak a pinned window even if this dies here.
        [void](Set-TestWindowTopmost -Window $A -On $true)
        Start-Sleep -Milliseconds 600
        $injectedBehind = Test-Topmost $A
        [void](Set-TestWindowTopmost -Window $A -On $false)
        Start-Sleep -Milliseconds 300
        Assert ($pinnedBehind -eq $injectedBehind) "C: the app's float and an EXTERNAL injection get the same answer for a background window (app=$pinnedBehind external=$injectedBehind) - the refusal is the window manager's, not ours"

        # And the path a person actually takes: the window they are ON.
        Set-Active $A $pane | Out-Null
        Start-Sleep -Milliseconds 400
        Assert (-not (Test-Topmost $A)) 'C: still unpinned before the real-user press'
        Send-TestKeys -Window $A -Target $pane -Key F7 -Modifiers ctrl, shift | Out-Null
        Assert (Wait-Topmost $A $true) 'C: with two windows open, ONE press pins the window the user is on'

        Send-TestKeys -Window $A -Target $pane -Key F7 -Modifiers ctrl, shift | Out-Null
        Assert (Wait-Topmost $A $false) 'C: and one more press unpins it again'
    }

    Assert (-not ($app.Process -and $app.Process.HasExited)) 'no crash'
    Assert (-not (Test-TestDesktopLeak -ProcessId $appPid)) 'GUI never became visible on the interactive desktop'
    # The try's last statement (body-complete-audit D1): an unwind above skips
    # it, so the verdict reads DID NOT FINISH instead of green.
    Complete-TestBody
} finally {
    Remove-TestDesktop
    Stop-RepoInstances
}

# Section C pins a window from OUTSIDE the app. The ledger puts any such pin
# back (Remove-TestDesktop did it above); this is the oracle that says it had
# nothing left to put back.
$stray = @(Get-TestTopmostRestored)
Assert ($stray.Count -eq 0) "no probe left a window topmost (harness had to un-pin: $($stray -join ','))"

Write-Host ''
if ($script:fail -eq 0 -and $script:skipped -eq 0) {
    # A clean green run with no skipped section stamps the covered files
    # (T783/T1768); red or skipped stays due.
    # Continue: under Stop, a stderr line from the native call through 2>&1
    # would throw in PowerShell 5.1.
    $ErrorActionPreference = 'Continue'
    $gdRepo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $gdRepo 'scripts\guard-due.ps1') `
        update -Guard float-on-top -Repo $gdRepo 2>&1 | ForEach-Object { "  $_" }
}
Write-TestVerdict -Label 'T277 FLOAT ON TOP' -Pass $script:pass -Fail $script:fail -Skipped $script:skipped
