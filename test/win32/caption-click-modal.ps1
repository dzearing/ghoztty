# T1141 acceptance: a synthetic click on a window's drag band never leaves the
# app inside DefWindowProc's modal move loop.
#
# Send-TestMouse routes a click the way Windows does (T263): a point the window
# hit-tests as HTCAPTION is posted as WM_NCLBUTTONDOWN/UP, and DefWindowProc
# answers the down with its modal SC_MOVE loop. A real user ends that loop by
# lifting a real button; a POSTED up does not reliably do so, and the loop then
# pumps its own messages and eats whatever the script clicks next. The script
# reports the CONSEQUENCE ("nothing happened") instead of the lost click, which
# is how T1110 filed a menu defect against a correct menu.
#
# WHEN the loop starts, measured (T1141): only when the app's key state says
# the left button is HELD. Posted messages never set that bit, so on a clean
# key state a posted caption down starts no loop at all - which is why T1110
# could not reproduce its lost click on an idle box (0/10). With the bit left
# set, the loop starts on every caption down and the posted up does NOT end
# it. GHOZTTY_TEST_MOUSE_STALE_LBUTTON=1 makes Send-TestMouse leave the bit
# set, and that is how this script constructs the state it guards.
#
# The fix lives in the harness's click path (lib\TestDesktop.ps1,
# EndModalLoop): after a whole click or doubleclick on a loop-starting hit
# code, a loop that is running is cancelled before Send-TestMouse returns. A
# bare `-Action down` keeps its loop, because that IS a caption drag.
#
# What this script asserts, and how:
#
#   A. The aim is real: the probe point answers HTCAPTION (2), so the clicks
#      below are the non-client drag-band clicks the defect is about.
#   B. With the stale held bit, click the drag band, then the maximize button,
#      several times over. After every drag-band click the GUI thread is NOT in
#      a move/size loop (GUITHREADINFO's GUI_INMOVESIZE, sampled for a second - a
#      state, not a timing guess), and every maximize click that follows
#      toggles the zoom. That second half is the T1110 shape: the click after
#      the drag band lands.
#   C. A deliberate drag keeps its loop: with the same bit, `-Action down` on
#      the drag band leaves the thread IN the move loop, so the cancel was not
#      bolted onto the down as well. This is also B's positive control: the
#      state B says never survives a click demonstrably exists.
#   D. On a clean key state no caption click starts a loop at all - the
#      ordinary case, recorded so a change in it is noticed.
#
# NEGATIVE CONTROL: -NegativeControl sets GHOZTTY_TEST_MOUSE_KEEP_MODAL=1 (the
# pre-T1141 click) and asserts section B's loop state anyway. It MUST fail -
# that is the demonstration that B can tell a fixed harness from a broken one.
#
# Runs on the background test desktop (test/win32/lib/TestDesktop.ps1), so it
# never takes the user's foreground. Only touches ghoztty processes running
# from this repo's zig-out.
param([string]$ExePath, [switch]$NegativeControl, [int]$Iterations = 8)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }
$env:GHOZTTY_PIPE_SUFFIX = "-capmodaltest$PID"
if ($NegativeControl) { $env:GHOZTTY_TEST_MOUSE_KEEP_MODAL = '1' } else { Remove-Item Env:GHOZTTY_TEST_MOUSE_KEEP_MODAL -ErrorAction SilentlyContinue }

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$script:pass = 0
$script:fail = 0
function Ok([string]$msg) { $script:pass++; Write-Host "  PASS  $msg" }
function Bad([string]$msg) { $script:fail++; Write-Host "  FAIL  $msg" }
function Check([bool]$cond, [string]$msg) { if ($cond) { Ok $msg } else { Bad $msg } }

$HTCAPTION = 2; $HTMAXBUTTON = 9

# The drag band and the maximize button, in this window, right now. Re-derived
# per call: maximizing moves the rect, and a stale one aims at the wrong place.
# Same arithmetic as caption-bar.ps1's CaptionGeom (the system trio is three
# native slabs flush to the client's right edge), which is where it is checked
# against painted pixels.
function Geom($h) {
    $m = Get-TestChromeMetrics -Window $h -StripVisible $false
    $win = Get-TestWindowRect -Window $h
    $cli = Get-TestWindowRect -Window $h -Client
    $cy = $cli.Top + [int]($m.CaptionH / 2)
    $maxL = $cli.Width - 2 * $m.CapBtnW
    [pscustomobject]@{
        Drag = @(($cli.Left + 40), $cy)
        Max  = @(($cli.Left + $maxL + [int]($m.CapBtnW / 2)), $cy)
    }
}

# Sampled, not read once, and for a whole second: the loop starts about a
# double-click interval AFTER the down (measured 433ms on a 500ms setting), so
# an early read sees "not yet" and calls it "never" - which is what an earlier
# 300ms version of section D did.
function InLoopWithin($h, [int]$ms) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $ms) {
        if (Test-TestInMoveSize -Window $h) { return $true }
        Start-Sleep -Milliseconds 15
    }
    return $false
}

function WaitZoom($h, [bool]$want, [int]$ms) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $ms) {
        if ((Test-TestWindowZoomed -Window $h) -eq $want) { return $true }
        Start-Sleep -Milliseconds 50
    }
    return $false
}

New-TestDesktop | Out-Null
$exitCode = 1
try {
    Write-Host "T1141 caption-click modal-loop acceptance$(if ($NegativeControl) { ' (NEGATIVE CONTROL)' })"
    Write-Host "  exe: $exe"
    if (-not (Test-Path $exe)) { throw "SETUP FAIL: no build at $exe" }

    $proc = Start-OnTestDesktop -Exe $exe -Arguments @(
        '--config-default-files=false',
        '--session-persistence=false',
        # No strip: the caption is the standalone 32 DIP band, so the drag band
        # is plain caption and the maximize slab sits where Geom says.
        '--window-show-tab-bar=never'
    )
    $h = Wait-TestWindow -ProcessId $proc.Pid -Class 'GhozttyWindow' -TimeoutMs 25000
    if ($h -eq [IntPtr]::Zero) { throw 'SETUP FAIL: no GhozttyWindow appeared' }
    Start-Sleep -Milliseconds 2500
    Set-TestWindowSize -Window $h -Width 1100 -Height 700 | Out-Null
    Start-Sleep -Milliseconds 1000

    # --- A. the aim ---------------------------------------------------------
    $g = Geom $h
    $rDrag = Get-TestMouseRoute -Window $h -Target $h -X $g.Drag[0] -Y $g.Drag[1]
    $rMax = Get-TestMouseRoute -Window $h -Target $h -X $g.Max[0] -Y $g.Max[1]
    Check ($rDrag.Code -eq $HTCAPTION) "A: the probe point is the drag band (HTCAPTION, got $($rDrag.Code))"
    Check ($rMax.Code -eq $HTMAXBUTTON) "A: the second click's point is the maximize button (HTMAXBUTTON, got $($rMax.Code))"
    Check (-not (Test-TestInMoveSize -Window $h)) "A: the window starts outside any move/size loop"

    # --- D. a clean key state starts no loop ---------------------------------
    # First, while nothing has touched the key state yet.
    Remove-Item Env:GHOZTTY_TEST_MOUSE_STALE_LBUTTON -ErrorAction SilentlyContinue
    $cleanLoop = 0
    for ($i = 1; $i -le 3; $i++) {
        $g = Geom $h
        [void](Send-TestMouse -Window $h -Target $h -X $g.Drag[0] -Y $g.Drag[1] -Action down)
        if (InLoopWithin $h 1000) { $cleanLoop++; [void](Invoke-TestMessage -Window $h -Message 0x001F) }
        [void](Send-TestMouse -Window $h -Target $h -X $g.Drag[0] -Y $g.Drag[1] -Action up)
        Start-Sleep -Milliseconds 100
    }
    Check ($cleanLoop -eq 0) "D: on a clean key state a posted caption down starts no move loop ($cleanLoop of 3 did)"

    # --- B. drag-band click, then a click that must land --------------------
    $env:GHOZTTY_TEST_MOUSE_STALE_LBUTTON = '1'
    $leftLoop = 0; $landed = 0
    for ($i = 1; $i -le $Iterations; $i++) {
        $g = Geom $h
        $wasZoomed = Test-TestWindowZoomed -Window $h
        [void](Send-TestMouse -Window $h -Target $h -X $g.Drag[0] -Y $g.Drag[1] -Action click)
        if (InLoopWithin $h 1000) {
            $leftLoop++
            Write-Host "      B[$i]: the drag-band click left the thread in a move loop"
            # Clear it so one bad iteration does not poison the rest.
            [void](Invoke-TestMessage -Window $h -Message 0x001F)
            Start-Sleep -Milliseconds 100
        }
        [void](Send-TestMouse -Window $h -Target $h -X $g.Max[0] -Y $g.Max[1] -Action click)
        if (WaitZoom $h (-not $wasZoomed) 2000) { $landed++ } else { Write-Host "      B[$i]: the maximize click after it did not toggle the zoom" }
        Start-Sleep -Milliseconds 200
    }
    if ($NegativeControl) {
        Check ($leftLoop -eq 0) "NEGATIVE CONTROL: with the cancel disabled, no drag-band click leaves a move loop ($leftLoop of $Iterations did)"
    } else {
        Check ($leftLoop -eq 0) "B: no drag-band click left a move loop behind ($leftLoop of $Iterations did)"
        Check ($landed -eq $Iterations) "B: every maximize click after a drag-band click landed ($landed of $Iterations)"
    }
    if (Test-TestWindowZoomed -Window $h) {
        Send-TestSysCommand -Window $h -Command 'restore' | Out-Null
        [void](WaitZoom $h $false 2000)
    }

    # --- C. a deliberate drag keeps its loop --------------------------------
    if (-not $NegativeControl) {
        $g = Geom $h
        [void](Send-TestMouse -Window $h -Target $h -X $g.Drag[0] -Y $g.Drag[1] -Action down)
        $dragLoop = InLoopWithin $h 1000
        Check $dragLoop "C: a bare down on the drag band still enters the move loop (the drag a script asked for)"
        [void](Send-TestMouse -Window $h -Target $h -X ($g.Drag[0] + 30) -Y $g.Drag[1] -Action up)
        [void](Invoke-TestMessage -Window $h -Message 0x001F)
        Start-Sleep -Milliseconds 200
        Check (-not (Test-TestInMoveSize -Window $h)) "C: the drag's loop ends when the script ends it"
    }
    Remove-Item Env:GHOZTTY_TEST_MOUSE_STALE_LBUTTON -ErrorAction SilentlyContinue

    Write-Host ""
    if ($script:fail -eq 0) {
        Write-Host "ALL PASS ($script:pass assertions)"
        $exitCode = 0
        # A clean green run records what it covered, so scripts\guard-due.ps1
        # can say whether the click path as it now stands has been asked
        # (T783). The negative control never gets here; red stays due.
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
            update -Guard caption-click-modal -Repo $repo 2>&1 | ForEach-Object { "  $_" }
    } else {
        Write-Host "$script:fail FAILURE(S) ($script:pass passed)"
        $exitCode = 1
    }
} catch {
    Write-Host ""
    Write-Host "1 FAILURE(S) - $($_.Exception.Message)"
    $exitCode = 1
} finally {
    Remove-TestDesktop
}
exit $exitCode
