# T1356 acceptance: closing a viewer pane - and the window around one - must
# not take the app down with it.
#
# WHAT BROKE. A ViewerPane's `deinit` calls `ICoreWebView2Controller::Close`,
# and that call PUMPS MESSAGES. Anything dispatched during the pump runs while
# the pane is half-freed: on 2026-09-05 a WM_SETFOCUS landed on the viewer's
# own host window, its arm called `Window.updateDimOverlays`, and that sweep
# walked `tab_trees` - which still held the pane being freed, because every
# teardown site deinit'ed the OLD tree while it was still installed in the
# window. `PaneView.showDimOverlay` then dereferenced a freed surface and the
# WHOLE PROCESS died with STATUS_FATAL_USER_CALLBACK_EXCEPTION, taking every
# other window and every unsaved pane with it.
#
# WHY NOTHING ELSE CAUGHT IT. Every viewer harness on this box opens viewers
# and lets the desktop teardown reap the process; none of them CLOSES a window
# that owns one and then keeps asserting. `viewer-narrow-pane.ps1` found the
# crash by accident and then stopped closing its probe window to get around it
# (the comment there names this task), which is the shape of a defect becoming
# permanent: the one script that could see it was edited until it could not.
# So the close is the subject here rather than the cleanup.
#
# WHAT IS ASSERTED, and why each case is a different code path:
#
#   A. `+close` on a WINDOW holding one viewer pane. The whole-window path
#      (`Window.close` -> `cleanupAllSurfaces`). The app must still be running
#      afterwards, the other window must still answer `+list`, and the closed
#      target must be gone.
#   B. `+close` on a window holding a TERMINAL pane AND a focused viewer pane.
#      THE SHAPE THAT ACTUALLY CRASHED, and the reason this script has five
#      sections instead of three: the fault dereferenced a freed *Surface*, so
#      the sweep needs a terminal leaf to walk back over. A window of viewers
#      alone (C) survived even the broken build.
#   C. `+close` on a window holding TWO viewer panes - two controllers closing
#      inside one teardown, so the second one pumps with the first already
#      freed.
#   D. `+close` on a single viewer PANE inside a split, beside a terminal. A
#      different site (`closeSplitPane`), which swaps in a new tree; the window
#      survives and keeps its other pane.
#   F. Closing one TAB (run before E) that holds a terminal and a focused
#      viewer with its contents card up, from the tab strip's close "x", in a
#      window that keeps another tab (T2245). A different site again:
#      `closeTabByIndex`, which T1358 found freeing the tab's tree BEFORE
#      removing its slot - the T1356 shape. The window must survive with its
#      other tab, and the viewer's host window must be DESTROYED (a parked
#      tab only hides it, so that is the proof the tab was really released).
#   E. Closing the LAST window, where the close IS the shutdown. The process
#      must EXIT CLEANLY - `Get-GuiPostmortem` reads the real exit code, so a
#      crash here is named (`CRASHED - 0xC000041D ...`) rather than passing as
#      "the process is gone, which is what we wanted".
#
# Liveness is measured two ways on purpose. `HasExited` on the launched process
# object is the cheap answer; `+list` answering over the IPC pipe is the one
# that says the app is still SERVING rather than merely still resident, which
# is the difference between a survivor and a process stuck unwinding.
#
#   powershell -NoProfile -File test\win32\viewer-close.ps1
#
# -NegativeControl inverts every survival assertion - it demands the app be
# DEAD after each close. On a fixed build it MUST fail with exactly SIX
# failures, one per section, which is what proves these assertions read real
# liveness rather than a constant.
#
# THE OTHER CONTROL, and the one that matters most, was run by hand against the
# pre-fix `Window.zig` on 2026-09-05: section B FAILED there with
# `CRASHED - 0xC000041D STATUS_FATAL_USER_CALLBACK_EXCEPTION`, the same code the
# original report carries. That is the evidence that this script can score red
# on the defect it exists for - a gate nobody has watched fail is not a gate
# (T1133). Getting there took three drafts: a window of viewers alone survives
# the broken build, and so does a terminal+viewer window with no contents card
# up. The card is load-bearing, which is why section B asserts it is there.
param([string]$ExePath, [switch]$Interactive, [switch]$NegativeControl)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }
if (-not (Test-Path $exe)) { Write-Host "SETUP FAIL: no exe at $exe"; exit 1 }

# Endpoint isolation: a run must never reach the user's own instance.
$env:GHOZTTY_PIPE_SUFFIX = "-vcl$PID"

. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
Assert-GhozttyIsolatedBuild -Exe $exe | Out-Null
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\HarnessLeak.ps1')
. (Join-Path $PSScriptRoot 'lib\ChromeGeometry.ps1')
# Arms the run (T1039): the dot-source itself, so a body that unwinds cannot
# reach `Complete-TestBody` and cannot be scored green - or stamp its guard.
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

# T1127: everything running out of this build's directory is reaped when this
# PowerShell exits.
Register-RepoBuildTeardown -Exe $exe | Out-Null

$script:pass = 0
$script:skipped = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

# The survival assertion, in one place so -NegativeControl can invert all four
# at once. `$Alive` is what the run measured; the control demands the opposite.
function Assert-Survived([bool]$Alive, [string]$Label) {
    if ($NegativeControl) {
        Assert (-not $Alive) "$Label (NEGATIVE CONTROL: asserting the app DIED)"
    } else {
        Assert $Alive $Label
    }
}

function Invoke-Verb([string[]]$VerbArgs) {
    # A PIPE, never a `>` redirect (T245), and each object stringified before
    # Out-String (T526): a consoleless host formats an ErrorRecord as a blank
    # line while its ToString() keeps the text.
    $out = (& $exe @VerbArgs 2>&1 | ForEach-Object { $_.ToString() } | Out-String)
    return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
}

function Get-Data {
    $json = (& $exe +list --json 2>$null | Out-String).Trim()
    if (-not $json) { return $null }
    try { return ($json | ConvertFrom-Json).data } catch { return $null }
}

function Get-Win([string]$target) {
    $d = Get-Data
    if (-not $d) { return $null }
    foreach ($w in $d.windows) { if ($w.target -eq $target) { return $w } }
    return $null
}

function Wait-Win([string]$target) {
    for ($t = 0; $t -lt 30; $t++) {
        $w = Get-Win $target
        if ($w) { return $w }
        Start-Sleep -Milliseconds 200
    }
    return $null
}

function Wait-NoWin([string]$target) {
    for ($t = 0; $t -lt 30; $t++) {
        if (-not (Get-Win $target)) { return $true }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

function Get-Leaves($node) {
    if ($node.type -eq 'leaf') { return @($node.terminal) }
    return @(Get-Leaves $node.left) + @(Get-Leaves $node.right)
}

function Get-PaneCount([string]$target) {
    $w = Get-Win $target
    if (-not $w) { return 0 }
    return @(Get-Leaves $w.tabs[0].splits).Count
}

# A viewer host window with real bounds under this process: the proof that the
# viewer pane actually EXISTS before we go and close it. Without this the
# sections would happily close windows that never grew a WebView2 and score a
# crash-free run that proved nothing.
function Wait-ViewerHost([int]$ProcessId) {
    for ($t = 0; $t -lt 40; $t++) {
        foreach ($w in @(Get-TestWindows -ProcessId $ProcessId -Class 'GhozttyWindow')) {
            foreach ($h in @(Get-TestChildWindows -Window ([IntPtr][int64]$w.Hwnd) -Class 'GhozttyViewer')) {
                if ($h.Width -gt 0 -and $h.Height -gt 0) { return $true }
            }
        }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

# The viewer's CONTENTS CARD, if this pane has one up. It is a child window of
# the viewer host (`GhozttyViewerTOC`) and therefore a second thing the
# teardown destroys - and a focus target while it is up, which is what puts a
# focus message into the `Close` pump that follows. Section B asserts one
# exists before it closes anything, because a window WITHOUT a card is a
# simpler teardown than the one that crashed.
function Get-TocCard([int]$ProcessId) {
    foreach ($w in @(Get-TestWindows -ProcessId $ProcessId -Class 'GhozttyWindow')) {
        foreach ($vh in @(Get-TestChildWindows -Window ([IntPtr][int64]$w.Hwnd) -Class 'GhozttyViewer')) {
            foreach ($c in @(Get-TestChildWindows -Window ([IntPtr][int64]$vh.Hwnd) -Class 'GhozttyViewerTOC')) {
                if ($c.Width -gt 0 -and $c.Height -gt 0) {
                    return [pscustomobject]@{ Top = [IntPtr][int64]$w.Hwnd; Card = [IntPtr][int64]$c.Hwnd }
                }
            }
        }
    }
    return $null
}

function Wait-TocCard([int]$ProcessId) {
    for ($t = 0; $t -lt 40; $t++) {
        $c = Get-TocCard $ProcessId
        if ($c) { return $c }
        Start-Sleep -Milliseconds 250
    }
    return $null
}

# Still serving, not merely still resident (see the header).
function Test-AppServing {
    for ($t = 0; $t -lt 20; $t++) {
        if (Get-Data) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

$docDir = Join-Path $env:TEMP "ghoztty-viewer-close-$PID"
New-Item -ItemType Directory -Force -Path $docDir | Out-Null
$doc1 = Join-Path $docDir 'one.md'
$doc2 = Join-Path $docDir 'two.md'
# Many headings on purpose: that is what makes the viewer build its CONTENTS
# CARD, which is a second popup window the pane owns and destroys during the
# same teardown. The reproduction found on 2026-09-05 had one open, and a card
# that is up is a focus target - so its destruction is what puts a focus
# message into the WebView2 `Close` pump that follows.
$headings = (1..60 | ForEach-Object { "## Heading $_`n`nSome text under heading $_.`n" }) -join "`n"
Set-Content -Path $doc1 -Value "# One`n`n$headings" -Encoding utf8
Set-Content -Path $doc2 -Value "# Two`n`n$headings" -Encoding utf8

$errlog = Join-Path $env:TEMP "ghoztty-viewer-close-$PID.log"
Remove-Item $errlog -ErrorAction SilentlyContinue

[void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 300)
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$app = $null
$since = Get-Date

try {
    # One app for the whole run. That is deliberate rather than economical:
    # sections A-C each close something and then keep asserting against the
    # SAME process, so "the app survived" accumulates instead of being re-asked
    # of a fresh launch that could not have died yet.
    # `--quit-after-last-window-closed=true` is what makes section D a
    # SHUTDOWN. It defaults to false on Windows (the app sits there with no
    # windows), so without it D's last close would be just another window
    # teardown and the case it exists to cover - the one where the crash is
    # indistinguishable from a clean quit - would never be entered. With no
    # delay configured the quit is immediate, so the wait below is bounded by
    # the app's own unwind rather than by a timer.
    # `--undo-timeout=0` (T2245): since T1825/T1874 a closed pane, tab or
    # window is PARKED for the undo window (5s by default) and its tree is
    # only released when the undo expires - long after the survival checks
    # below have been read. Zero turns undo off (`close_undo.timeoutMs`), so
    # every close here is the real release this script exists to watch,
    # which is also what every close was when T1356 was found.
    # `f9=new_tab`: no CLI verb opens a tab; a posted keybind does, and it
    # works on the background test desktop (hidden-window-memory.ps1 T).
    $app = Start-OnTestDesktop -Exe $exe -StdErr $errlog -Arguments @(
        '--session-persistence=false', '--config-default-files=false',
        '--quit-after-last-window-closed=true', '--undo-timeout=0',
        '--keybind=f9=new_tab')
    Start-Sleep -Seconds 3
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'the GUI came up'
    Assert (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) 'the GUI is NOT on the interactive desktop'
    $baseTop = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow' -TimeoutMs 15000
    Assert ($baseTop -ne [IntPtr]::Zero) 'the launch window exists (the one that must OUTLIVE every close below)'

    # =====================================================================
    # A. +close on a window holding ONE viewer pane
    # =====================================================================
    Write-Host ''
    Write-Host 'A. a window with one viewer pane'
    $r = Invoke-Verb @('+new-window', '--target=vc1', "--view=$doc1")
    Assert ($r.Code -eq 0) "A: +new-window --view exits 0 (got $($r.Code): $($r.Out.Trim()))"
    Assert ($null -ne (Wait-Win 'vc1')) 'A: the viewer window is listed'
    Assert (Wait-ViewerHost $app.Pid) 'A: a viewer host window with real bounds exists (the pane is really there)'

    $r = Invoke-Verb @('+close', '--target=vc1')
    Assert ($r.Code -eq 0) "A: +close exits 0 (got $($r.Code): $($r.Out.Trim()))"
    Start-Sleep -Milliseconds 1500
    $aliveA = (-not ($app.Process -and $app.Process.HasExited))
    Assert-Survived $aliveA 'A: the app is still running after closing the window that held the viewer'
    if ($aliveA) {
        Assert (Test-AppServing) 'A: the app still answers +list (serving, not stuck unwinding)'
        Assert (Wait-NoWin 'vc1') 'A: the closed window is gone from +list'
    }

    # =====================================================================
    # B. +close on a window holding a TERMINAL pane and a VIEWER pane
    # =====================================================================
    # THE REPORTED SHAPE, and the one that actually reproduces. The crash
    # dereferenced a freed *Surface* (`PaneView.showDimOverlay`'s `.terminal`
    # arm), so the window has to contain a terminal for the sweep to have one
    # to walk: the tree teardown frees the terminal leaf, the viewer leaf's
    # `deinit` then pumps inside `Close`, a focus message is dispatched, and
    # `updateDimOverlays` walks back over the leaf that is already gone. A
    # window of viewers alone - section C - never crashed on the broken build,
    # which is exactly why this case is separate from that one rather than
    # folded into it.
    Write-Host ''
    Write-Host 'B. a window with a terminal pane and a viewer pane (the reported repro)'
    $aliveB2 = $false
    if ($aliveA) {
        $r = Invoke-Verb @('+new-window', '--target=vc5')
        Assert ($r.Code -eq 0) "B: +new-window (terminal) exits 0 (got $($r.Code))"
        Assert ($null -ne (Wait-Win 'vc5')) 'B: the terminal window is listed'
        $r = Invoke-Verb @('+split', '--target=vc5', '--name=vc5b', "--view=$doc1")
        Assert ($r.Code -eq 0) "B: +split --view exits 0 (got $($r.Code): $($r.Out.Trim()))"
        $panes = 0
        for ($t = 0; $t -lt 30 -and $panes -lt 2; $t++) { $panes = Get-PaneCount 'vc5'; if ($panes -lt 2) { Start-Sleep -Milliseconds 200 } }
        Assert ($panes -eq 2) "B: the window has a terminal and a viewer (got $panes panes)"
        Assert (Wait-ViewerHost $app.Pid) 'B: the viewer host window exists'
        # Focus the viewer, so the pane whose `Close` pumps is the one holding
        # focus - which is what puts a focus message into that pump. `+split`
        # with an existing `--name` is documented to FOCUS that pane instead of
        # creating a second one, so this is a focus request that needs no key
        # synthesis (dead on the background test desktop anyway).
        [void](Invoke-Verb @('+split', '--target=vc5', '--name=vc5b', "--view=$doc1"))
        # Long enough for the page to render and the contents card to slide in:
        # the card is the second popup the teardown destroys, and closing
        # before it exists tests a simpler window than the one that crashed.
        Start-Sleep -Seconds 3
        Assert ((Get-PaneCount 'vc5') -eq 2) 'B: focusing the viewer created no extra pane (the idempotent path)'

        # Give the viewer most of a WIDE window. The contents card only takes
        # its gutter presentation - the one that is on screen with no toggle -
        # past 720 DIP of pane, so a default-sized window has no card at all
        # and would test a simpler teardown than the one that crashed.
        $probeTop = [IntPtr]::Zero
        foreach ($t in @(Get-TestWindows -ProcessId $app.Pid -Class 'GhozttyWindow')) {
            if (@(Get-TestChildWindows -Window ([IntPtr][int64]$t.Hwnd) -Class 'GhozttyViewer').Count -ge 1) {
                $probeTop = [IntPtr][int64]$t.Hwnd
            }
        }
        if ($probeTop -ne [IntPtr]::Zero) {
            [void](Set-TestWindowPos -Window $probeTop -X 0 -Y 0 -Width 1400 -Height 900)
            Start-Sleep -Milliseconds 800
        }
        $wB = Get-Win 'vc5'
        if ($wB) {
            $leavesB = @(Get-Leaves $wB.tabs[0].splits)
            $termB = @($leavesB | Where-Object { $_.type -ne 'viewer' })
            $viewB = @($leavesB | Where-Object { $_.type -eq 'viewer' })
            if ($termB.Count -eq 1 -and $viewB.Count -eq 1) {
                $layoutB = '{"direction":"horizontal","ratio":15,"left":{"pane":"' +
                    $termB[0].name + '"},"right":{"pane":"' + $viewB[0].name + '"}}'
                [void](Invoke-Verb @('+rearrange', '--target=vc5',
                    ('--layout=' + ($layoutB -replace '"', '\"'))))
                Start-Sleep -Milliseconds 1500
            }
        }
        Assert ($null -ne (Wait-TocCard $app.Pid)) `
            'B: the viewer has its contents card up (the second popup the teardown has to destroy)'

        $r = Invoke-Verb @('+close', '--target=vc5')
        Assert ($r.Code -eq 0) "B: +close exits 0 (got $($r.Code))"
        Start-Sleep -Milliseconds 2000
        $aliveB2 = (-not ($app.Process -and $app.Process.HasExited))
        Assert-Survived $aliveB2 'B: the app is still running after closing a window holding a terminal AND a viewer'
        if ($aliveB2) {
            Assert (Test-AppServing) 'B: the app still answers +list'
            Assert (Wait-NoWin 'vc5') 'B: the closed window is gone from +list'
        }
    } else {
        Write-Host '  SKIP B: the app did not survive section A'; $script:skipped++
    }

    # =====================================================================
    # C. +close on a window holding TWO viewer panes
    # =====================================================================
    Write-Host ''
    Write-Host 'C. a window with two viewer panes'
    if ($aliveB2) {
        $r = Invoke-Verb @('+new-window', '--target=vc2', "--view=$doc1")
        Assert ($r.Code -eq 0) "C: +new-window --view exits 0 (got $($r.Code))"
        Assert ($null -ne (Wait-Win 'vc2')) 'C: the window is listed'
        $r = Invoke-Verb @('+split', '--target=vc2', '--name=vc2b', "--view=$doc2")
        Assert ($r.Code -eq 0) "C: +split --view exits 0 (got $($r.Code): $($r.Out.Trim()))"
        $panes = 0
        for ($t = 0; $t -lt 30 -and $panes -lt 2; $t++) { $panes = Get-PaneCount 'vc2'; if ($panes -lt 2) { Start-Sleep -Milliseconds 200 } }
        Assert ($panes -eq 2) "C: the window has both viewer panes (got $panes)"

        $r = Invoke-Verb @('+close', '--target=vc2')
        Assert ($r.Code -eq 0) "C: +close exits 0 (got $($r.Code))"
        Start-Sleep -Milliseconds 1500
        $aliveC2 = (-not ($app.Process -and $app.Process.HasExited))
        Assert-Survived $aliveC2 'C: the app is still running after closing a window with TWO viewer panes'
        if ($aliveC2) {
            Assert (Test-AppServing) 'C: the app still answers +list'
            Assert (Wait-NoWin 'vc2') 'C: the closed window is gone from +list'
        }
    } else {
        Write-Host '  SKIP C: the app did not survive an earlier section'; $script:skipped++
    }

    # =====================================================================
    # D. +close on ONE viewer pane inside a split (closeSplitPane)
    # =====================================================================
    Write-Host ''
    Write-Host 'D. one viewer pane out of a split'
    $aliveD = $false
    if (-not ($app.Process -and $app.Process.HasExited)) {
        # A TERMINAL root with a viewer split, for the reason section B gives:
        # `closeSplitPane` frees the viewer, and the sweep that runs inside its
        # pump has to have a terminal leaf to walk back over.
        $r = Invoke-Verb @('+new-window', '--target=vc3')
        Assert ($r.Code -eq 0) "D: +new-window exits 0 (got $($r.Code))"
        Assert ($null -ne (Wait-Win 'vc3')) 'D: the window is listed'
        $r = Invoke-Verb @('+split', '--target=vc3', '--name=vc3b', "--view=$doc2")
        Assert ($r.Code -eq 0) "D: +split --view exits 0 (got $($r.Code))"
        $panes = 0
        for ($t = 0; $t -lt 30 -and $panes -lt 2; $t++) { $panes = Get-PaneCount 'vc3'; if ($panes -lt 2) { Start-Sleep -Milliseconds 200 } }
        Assert ($panes -eq 2) "D: the window has two panes before the pane close (got $panes)"

        $r = Invoke-Verb @('+close', '--target=vc3b')
        Assert ($r.Code -eq 0) "D: +close on the pane exits 0 (got $($r.Code))"
        Start-Sleep -Milliseconds 2000
        $aliveD = (-not ($app.Process -and $app.Process.HasExited))
        Assert-Survived $aliveD 'D: the app is still running after closing ONE viewer pane out of a split'
        if ($aliveD) {
            Assert (Test-AppServing) 'D: the app still answers +list'
            $left = 0
            for ($t = 0; $t -lt 30; $t++) { $left = Get-PaneCount 'vc3'; if ($left -eq 1) { break }; Start-Sleep -Milliseconds 200 }
            Assert ($left -eq 1) "D: the window survived the pane close with its other pane (got $left)"
        }
    } else {
        Write-Host '  SKIP D: the app did not survive an earlier section'; $script:skipped++
    }

    # =====================================================================
    # F. one TAB holding a terminal and a focused viewer (closeTabByIndex)
    # =====================================================================
    # Run before E, which has to be last. The tab is closed from the tab
    # strip's close "x" - a posted click, which moves no keyboard focus, so
    # the viewer is still the focused pane (with its contents card up) when
    # the close lands: section B's crash ingredients, at the tab site. The
    # window keeps its FIRST tab, so the close is a tab close and not a
    # window close (the last tab takes `Window.close` instead). With
    # `--undo-timeout=0` nothing is parked: `closeTabByIndex` releases the
    # tree on the spot, which is the order T1358 fixed.
    Write-Host ''
    Write-Host 'F. one tab (terminal + focused viewer) closed out of a two-tab window'
    $aliveF = $false
    if ($aliveD) {
        # Its top-level HWND is the one that did not exist before the verb:
        # D's window is still open with one terminal too, and a keybind sent
        # there would open its tab in the wrong window (the first draft did).
        $preF = @(Get-TestWindows -ProcessId $app.Pid -Class 'GhozttyWindow' | ForEach-Object { [int64]$_.Hwnd })
        $r = Invoke-Verb @('+new-window', '--target=vc6')
        Assert ($r.Code -eq 0) "F: +new-window exits 0 (got $($r.Code))"
        $wF = Wait-Win 'vc6'
        Assert ($null -ne $wF) 'F: the window is listed'
        $topF = [IntPtr]::Zero
        $termF = [IntPtr]::Zero
        for ($t = 0; $t -lt 30 -and $termF -eq [IntPtr]::Zero; $t++) {
            foreach ($tw in @(Get-TestWindows -ProcessId $app.Pid -Class 'GhozttyWindow')) {
                if ($preF -contains [int64]$tw.Hwnd) { continue }
                $vis = @(Get-TestChildWindows -Window ([IntPtr][int64]$tw.Hwnd) -Class 'GhozttyTerminal' | Where-Object Visible)
                if ($vis.Count -eq 1) { $topF = [IntPtr][int64]$tw.Hwnd; $termF = [IntPtr][int64]$vis[0].Hwnd }
            }
            if ($termF -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 200 }
        }
        Assert ($termF -ne [IntPtr]::Zero) 'F: the new window has one visible terminal pane to send new_tab to'
        if ($termF -ne [IntPtr]::Zero) {
            [void](Send-TestKeys -Window $topF -Target $termF -Key F9)
        }
        $tabsF = 0
        for ($t = 0; $t -lt 30 -and $tabsF -lt 2; $t++) {
            $wF = Get-Win 'vc6'
            if ($wF) { $tabsF = @($wF.tabs).Count }
            if ($tabsF -lt 2) { Start-Sleep -Milliseconds 200 }
        }
        Assert ($tabsF -eq 2) "F: the posted new_tab keybind opened a second tab (got $tabsF tabs)"

        # The new tab is the selected one; split its terminal into a viewer.
        $selF = -1
        $tab2Term = $null
        if ($wF) {
            for ($i = 0; $i -lt @($wF.tabs).Count; $i++) {
                if (@($wF.tabs)[$i].selected) { $selF = $i }
            }
            if ($selF -ge 1) {
                $tab2Term = @(Get-Leaves @($wF.tabs)[$selF].splits | Where-Object { $_.type -ne 'viewer' })[0]
            }
        }
        Assert ($selF -eq 1 -and $null -ne $tab2Term) "F: the second tab is selected and holds a terminal (selected=$selF)"
        if ($null -ne $tab2Term) {
            $r = Invoke-Verb @('+split', "--target=$($tab2Term.name)", '--name=vc6v', "--view=$doc1")
            Assert ($r.Code -eq 0) "F: +split --view in the second tab exits 0 (got $($r.Code): $($r.Out.Trim()))"
            # Focus the viewer (the idempotent +split, as in B).
            [void](Invoke-Verb @('+split', "--target=$($tab2Term.name)", '--name=vc6v', "--view=$doc1"))
            # Wide window, viewer-heavy layout: the contents card's gutter
            # presentation needs a pane past 720 DIP (see B). Nothing is
            # waited for here: SetWindowPos is a SENT message (done when it
            # returns), the +rearrange reply comes after the layout is
            # applied, and the card wait below polls for the end state.
            [void](Set-TestWindowPos -Window $topF -X 0 -Y 0 -Width 1400 -Height 900)
            $layoutF = '{"direction":"horizontal","ratio":15,"left":{"pane":"' +
                $tab2Term.name + '"},"right":{"pane":"vc6v"}}'
            [void](Invoke-Verb @('+rearrange', '--target=vc6', ('--layout=' + ($layoutF -replace '"', '\"'))))
        }
        $wF = Get-Win 'vc6'
        $tab1Panes = 0; $tab2Panes = 0
        if ($wF -and @($wF.tabs).Count -eq 2) {
            $tab1Panes = @(Get-Leaves @($wF.tabs)[0].splits).Count
            $tab2Leaves = @(Get-Leaves @($wF.tabs)[1].splits)
            $tab2Panes = $tab2Leaves.Count
        }
        Assert ($tab1Panes -eq 1 -and $tab2Panes -eq 2) `
            "F: tab 1 holds one pane and tab 2 a terminal and a viewer (got $tab1Panes / $tab2Panes)"

        # The viewer host under THIS window, and its contents card.
        $hostF = [IntPtr]::Zero
        for ($t = 0; $t -lt 40 -and $hostF -eq [IntPtr]::Zero; $t++) {
            foreach ($h in @(Get-TestChildWindows -Window $topF -Class 'GhozttyViewer')) {
                if ($h.Visible -and $h.Width -gt 0 -and $h.Height -gt 0) { $hostF = [IntPtr][int64]$h.Hwnd }
            }
            if ($hostF -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 250 }
        }
        Assert ($hostF -ne [IntPtr]::Zero) 'F: the second tab shows a viewer host window with real bounds'
        $cardF = $null
        for ($t = 0; $t -lt 80 -and -not $cardF; $t++) {
            if ($hostF -ne [IntPtr]::Zero) {
                $cardF = @(Get-TestChildWindows -Window $hostF -Class 'GhozttyViewerTOC' |
                    Where-Object { $_.Width -gt 0 -and $_.Height -gt 0 })[0]
            }
            if (-not $cardF) { Start-Sleep -Milliseconds 250 }
        }
        Assert ($null -ne $cardF) 'F: the viewer has its contents card up'

        # The selected tab's close "x", from the strip geometry the product
        # publishes (T231): `Metrics.closeRect`'s hit box spans the tab's
        # right ~(pad_sm + btn_paint + btn_pad), so 14 DIP in from the right
        # edge is inside it at any scale. A miss is not silent - the tab count
        # below would stay 2.
        $closedF = $false
        $wF = Get-Win 'vc6'
        $rect = $null
        if ($wF -and $wF.chrome -and $wF.chrome.tab_strip) { $rect = @($wF.chrome.tab_strip.tabs)[1] }
        Assert ($null -ne $rect) 'F: +list publishes the second tab button''s rect'
        $markF = 0
        if (Test-Path $errlog) { $markF = @(Get-Content $errlog).Count }
        if ($null -ne $rect -and $hostF -ne [IntPtr]::Zero) {
            $dpi = [int]$wF.chrome.dpi
            if ($dpi -le 0) { $dpi = 96 }
            $client = Get-TestWindowRect -Window $topF -Client
            $cx = $client.Left + [int]$rect.right - (Get-TestChromeDip -Dip 14 -Scale ($dpi / 96.0))
            $cy = $client.Top + [int](([int]$rect.top + [int]$rect.bottom) / 2)
            [void](Send-TestMouse -Window $topF -Target $topF -X $cx -Y $cy -Button left -Action click)
            $closedF = $true
        }
        # Until the close has visibly finished - one tab left AND the viewer
        # host destroyed (the release, not just the slot) - or the app died.
        for ($t = 0; $closedF -and $t -lt 50; $t++) {
            if ($app.Process -and $app.Process.HasExited) { break }
            $wDone = Get-Win 'vc6'
            if ($wDone -and @($wDone.tabs).Count -eq 1 -and -not (Test-TestWindowExists -Window $hostF)) { break }
            Start-Sleep -Milliseconds 200
        }
        $aliveF = (-not ($app.Process -and $app.Process.HasExited))
        Assert-Survived $aliveF 'F: the app is still running after closing a TAB holding a terminal AND a focused viewer'
        if ($aliveF -and $closedF) {
            Assert (Test-AppServing) 'F: the app still answers +list'
            $left = 0
            for ($t = 0; $t -lt 30; $t++) {
                $wF = Get-Win 'vc6'
                $left = if ($wF) { @($wF.tabs).Count } else { 0 }
                if ($left -eq 1) { break }
                Start-Sleep -Milliseconds 200
            }
            Assert ($left -eq 1) "F: the window survived with its other tab (got $left tabs)"
            $gone = $false
            for ($t = 0; $t -lt 30; $t++) {
                if (-not (Test-TestWindowExists -Window $hostF)) { $gone = $true; break }
                Start-Sleep -Milliseconds 200
            }
            Assert $gone 'F: the closed tab''s viewer host window was DESTROYED (released, not parked for undo)'

            # THE ORDER T1358 FIXED, read off the app's own debug log. The
            # survival checks above cannot score it: run against the pre-T1358
            # `closeTabByIndex` (release the tree, THEN remove the slot) on
            # 2026-11-25 this section stayed green, because the freed terminal
            # leaf's window is parked for reuse and nothing dispatched in the
            # viewer's `Close` pump happened to walk it - the crash is a race,
            # not a certainty. The ordering is not a race. Removing the slot
            # re-seats the window's remaining tab (`selectTabIndex`, logged
            # `window resize cause=tabswitch`), and releasing the tree frees
            # its terminal leaf (`surface deinit: start`). Fixed: the switch is
            # logged first. Pre-T1358: the deinit is (line 858 vs 895 in that
            # run's log). Both lines are debug-level, which the isolated-build
            # check at the top of this script already guarantees.
            $afterF = @()
            if (Test-Path $errlog) { $afterF = @(Get-Content $errlog | Select-Object -Skip $markF) }
            $iSwitch = -1; $iFree = -1
            for ($i = 0; $i -lt $afterF.Count; $i++) {
                if ($iSwitch -lt 0 -and $afterF[$i] -like '*window resize cause=tabswitch*') { $iSwitch = $i }
                if ($iFree -lt 0 -and $afterF[$i] -like '*surface deinit: start*') { $iFree = $i }
            }
            Assert ($iSwitch -ge 0 -and $iFree -ge 0) `
                "F: the close logged both the tab re-seat and the terminal leaf's release (switch at +$iSwitch, free at +$iFree)"
            Assert ($iSwitch -ge 0 -and $iFree -ge 0 -and $iSwitch -lt $iFree) `
                "F: the tab's slot was removed BEFORE its tree was released (T1358 order: switch at +$iSwitch, free at +$iFree)"
        }
    } else {
        Write-Host '  SKIP F: the app did not survive an earlier section'; $script:skipped++
    }

    # =====================================================================
    # E. the LAST window: the close IS the shutdown
    # =====================================================================
    Write-Host ''
    Write-Host 'E. the last window, where closing it ends the process'
    if ($aliveF) {
        # Put the app back to ONE window, and make that window the viewer one:
        # closing it is then both the window teardown and the app exit, which
        # is the case where a crash is easiest to mistake for a clean quit.
        [void](Invoke-Verb @('+close', '--target=vc3'))
        Start-Sleep -Milliseconds 800
        $r = Invoke-Verb @('+new-window', '--target=vc4', "--view=$doc1")
        Assert ($r.Code -eq 0) "E: +new-window --view exits 0 (got $($r.Code))"
        Assert ($null -ne (Wait-Win 'vc4')) 'E: the viewer window is listed'
        Assert (Wait-ViewerHost $app.Pid) 'E: its viewer host window exists'

        # Every OTHER window first, so the viewer window is genuinely last.
        $d = Get-Data
        if ($d) {
            foreach ($w in $d.windows) {
                if ($w.target -ne 'vc4') {
                    $t = $w.target
                    if ($t) { [void](Invoke-Verb @('+close', "--target=$t")) }
                    else { [void](Invoke-Verb @('+close', "--target=$($w.id)")) }
                }
            }
        }
        Start-Sleep -Milliseconds 1200

        [void](Invoke-Verb @('+close', '--target=vc4'))
        # Wait for the process to actually go. A crash and a clean quit both
        # end it; only the exit code tells them apart, which is the assertion
        # after this one - and that assertion says NOTHING while the process is
        # still running, so "it ended at all" has to be asserted first. The
        # first draft of this script scored a green E against a process that
        # had never exited.
        for ($t = 0; $t -lt 120; $t++) {
            if ($app.Process -and $app.Process.HasExited) { break }
            Start-Sleep -Milliseconds 250
        }
        Assert ($app.Process -and $app.Process.HasExited) `
            'E: closing the last window ended the process (without this, the crash check below is vacuous)'
        $pm = Get-GuiPostmortem -ProcessId $app.Pid -Name 'ghoztty' -Process $app.Process `
            -StdErr $errlog -Since $since -WaitSeconds 10
        Write-GuiPostmortem -Report $pm
        Assert-Survived (-not $pm.Crashed) `
            "E: closing the last window - the one holding the viewer - ended the process without a crash (verdict: $($pm.Verdict))"
        Assert ($null -eq $pm.DumpPath) `
            "E: no crash dump was written (dump: $(if ($pm.DumpPath) { $pm.DumpPath } else { 'none' }))"
    } else {
        Write-Host '  SKIP E: the app did not survive an earlier section'; $script:skipped++
    }

    Complete-TestBody
} finally {
    Remove-TestDesktop
    Remove-Item -Recurse -Force $docDir -ErrorAction SilentlyContinue
    [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 300)
}

$fgSeen = @(Stop-TestForegroundWatch)
$leaked = @(Get-TestLaunchedPids | Where-Object { $fgSeen -contains $_ })
Assert ($leaked.Count -eq 0) "no test-desktop app ever became foreground on the interactive desktop (saw $($leaked -join ','))"

# A green run stamps the covered files (T783) so guard-due can answer "has this
# harness been run against the code as it now stands?". Red leaves the stamp
# alone: red stays due, and so does a run that unwound.
if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard viewer-close -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
# -MinPass: a full run scores 60 (T2245 added section F's 16). A throw that
# unwinds a section leaves far less than that, and a partial score must not
# read as a pass (T271/T1039).
Write-TestVerdict -Label 'VIEWER CLOSE' -Pass $script:pass -Fail $script:fail -Skipped $script:skipped -MinPass 56
