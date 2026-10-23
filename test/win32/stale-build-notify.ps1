# T1211 acceptance: the "you are running an older build" notification, end to
# end through the app rather than through the text `+version` prints.
#
# T1205 made an open window volunteer that a newer build has been installed
# under it (a tray balloon, once per build that appears on disk) and turned the
# About box into the offer to restart. Its unit tests cover the DECISION
# (image_freshness.zig) and what a balloon click MEANS (tray_notify.zig), and
# ipc-version.ps1 section 2b covers the SENTENCE. Nothing watched the plumbing
# between them. This does:
#
#   S1. NEGATIVE CONTROL: a window running the file it launched from ticks the
#       check several times and never decides to notify.
#   S2. A newer build lands on disk (the running image is renamed aside and a
#       fresh file put at its path - the move msiexec makes): the app decides to
#       notify, and asks the shell for the balloon.
#   S3. DEDUPE: more ticks over the same file do NOT notify again.
#   S4. A second, newer file (another upgrade while the window is still open)
#       DOES notify again.
#   S5. The About box, with a newer build on disk, is the offer: its buttons are
#       "Restart Now" and "Later", and "Later" changes nothing.
#   S6. "Restart Now" when the restart cannot be set up leaves the window
#       running and says so (log + fallback balloon). The relaunch guard's
#       marker path is made a DIRECTORY in a private LOCALAPPDATA, so arming it
#       fails for real rather than by injection.
#
# WHY A LOG LINE IS THE ORACLE. On the background test desktop there is no
# notification area, so the balloon itself cannot be read back (the T448
# obstacle). The app logs the decision and the shell's answer
# ("stale-build balloon: shown=..."), and that is what is asserted. The
# successful restart is deliberately NOT exercised: the relaunched app would
# come up on the user's desktop. app-restart.ps1 owns that path.
#
# The app runs from a COPY of zig-out\bin under this run's temp dir, so the
# rename-aside never touches the build output or zig's cache.
#
# T218 house rules: runs on a BACKGROUND Win32 desktop, never takes the user's
# foreground, and only touches ghoztty processes from this repo's zig-out (and
# the private copy of it).
#
# -NegativeControl never puts a newer file on disk, so S2-S6 MUST score red.
#
#   powershell -NoProfile -File test\win32\stale-build-notify.ps1
param(
    [string]$Exe,
    [switch]$NegativeControl,
    [switch]$Interactive
)
$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not $Exe) { $Exe = Join-Path $repo 'zig-out\bin\ghoztty.exe' }

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
# T1511: the shared scorer; the dot-source is what ARMS the run.
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "  PASS $label" }
    else { $script:fail++; Write-Host "  FAIL $label" -ForegroundColor Red }
}

$root = Join-Path $env:TEMP "ghoztty-stale-build-$PID"
$bin = Join-Path $root 'bin'
$lad = Join-Path $root 'lad'
$errlog = Join-Path $root 'app.err.txt'
$savedLocalAppData = $env:LOCALAPPDATA

# Isolate the IPC endpoint before any CLI call.
$env:GHOZTTY_PIPE_SUFFIX = "-stalebuild$PID"
# Debug-only cadence seam (T1211): check every second instead of every minute.
$env:GHOZTTY_STALE_BUILD_CHECK_MS = '1000'

function Get-LogText {
    if (-not (Test-Path $errlog)) { return '' }
    try {
        $fs = [IO.File]::Open($errlog, 'Open', 'Read', 'ReadWrite')
        try { return (New-Object IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() }
    } catch { return '' }
}
function Get-LogCount([string]$Pattern) {
    return ([regex]::Matches((Get-LogText), $Pattern)).Count
}
# Poll until the log holds at least $Count matches of $Pattern.
function Wait-LogCount([string]$Pattern, [int]$Count, [int]$TimeoutMs = 8000) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        if ((Get-LogCount $Pattern) -ge $Count) { return $true }
        Start-Sleep -Milliseconds 200
    }
    return ((Get-LogCount $Pattern) -ge $Count)
}
# Click a control by POSTING a mouse pair to it: a sent BM_CLICK would sit in
# the dialog's nested pump (see activity-monitor.ps1).
function Click-TestPosted([IntPtr]$Top, $Ctl) {
    $h = [IntPtr]$Ctl.Hwnd
    $r = Get-TestWindowRect -Window $h
    return Send-TestMouse -Window $Top -Target $h `
        -X ([int](($r.Left + $r.Right) / 2)) -Y ([int](($r.Top + $r.Bottom) / 2)) `
        -Button left -Action click
}
# Open the About box through the palette, the way a user does. Returns the
# dialog hwnd or Zero.
function Open-AboutBox([IntPtr]$Top, [int]$AppPid) {
    $surface = Get-TestChildWindow -Window $Top -Class 'GhozttyTerminal'
    if ($surface -eq [IntPtr]::Zero) { return [IntPtr]::Zero }
    foreach ($try in 1..3) {
        if (-not (Send-TestKeys -Window $Top -Target $surface -Modifiers ctrl,shift -Key P)) { continue }
        $popup = Wait-TestWindow -ProcessId $AppPid -Class 'GhozttyCommandPalette' -TimeoutMs 5000
        if ($popup -eq [IntPtr]::Zero) { continue }
        $edit = Find-TestWindowEx -Parent $popup -Class 'EDIT'
        if ($edit -eq [IntPtr]::Zero) { continue }
        Send-TestControlText -Control $edit -Text 'about' | Out-Null
        Send-TestControlKey -Control $edit -Key Enter | Out-Null
        $dlg = Wait-TestWindow -ProcessId $AppPid -Class 'GhozttyConfirmDialog' -TimeoutMs 5000
        if ($dlg -ne [IntPtr]::Zero) { return $dlg }
    }
    return [IntPtr]::Zero
}
function Get-DialogButtons([IntPtr]$Dlg) {
    return @(Get-TestChildWindows -Window $Dlg -Class 'Button' | ForEach-Object {
        [pscustomobject]@{ Ctl = $_; Text = (Get-TestControlText -Control ([IntPtr]$_.Hwnd)) }
    })
}

Reset-GhozttyTestState -Exe $Exe -SettleMs 1000 | Out-Null
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$launched = @()
$runExe = Join-Path $bin 'ghoztty.exe'
$oldExe = "$runExe.t1211-old"

try {
    Write-Host '== setup: a private copy of the build, and a relaunch guard that cannot arm'
    New-Item -ItemType Directory -Force $bin | Out-Null
    Copy-Item -Path (Join-Path (Split-Path $Exe) '*') -Destination $bin -Recurse -Force -Exclude '*.pdb'
    Assert (Test-Path $runExe) 'setup: the private copy exists'
    # The guard writes %LOCALAPPDATA%\ghoztty\app-restart-debug.marker; a
    # directory sitting at that path makes the write fail, which is a real
    # "the restart could not be set up" rather than a simulated one.
    New-Item -ItemType Directory -Force (Join-Path $lad 'ghoztty\app-restart-debug.marker') | Out-Null
    $env:LOCALAPPDATA = $lad

    $app = Start-OnTestDesktop -Exe $runExe -Arguments @('--session-persistence=false') -StdErr $errlog
    $appPid = [int]$app.Pid
    $launched += $appPid
    $win = Wait-TestWindow -ProcessId $appPid -Class 'GhozttyWindow' -TimeoutMs 20000
    if ($win -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: launch window not found'; exit 1 }
    Assert (-not (Test-TestDesktopLeak -ProcessId $appPid)) 'setup: the app is NOT on the interactive desktop'

    Write-Host '== S1: the file the window launched from is not a newer build (negative control)'
    $tick = 'stale-build check: newer_build_installed='
    Assert (Wait-LogCount ([regex]::Escape($tick)) 3 10000) "S1: the check ticked at least 3 times (got $(Get-LogCount ([regex]::Escape($tick))))"
    Assert ((Get-LogCount ([regex]::Escape($tick + 'true'))) -eq 0) 'S1: no tick found a newer build'
    Assert ((Get-LogCount 'newer build installed on disk') -eq 0) 'S1: no notification was decided'

    $decide = 'newer build installed on disk \(running build started'
    Write-Host '== S2: a newer build lands under the running window'
    if ($NegativeControl) {
        Write-Host 'NEGATIVE CONTROL: no newer file is put on disk - S2-S6 MUST fail'
    } else {
        Rename-Item -Path $runExe -NewName (Split-Path -Leaf $oldExe) -ErrorAction Stop
        Copy-Item -Path $oldExe -Destination $runExe -ErrorAction Stop
        # Copy-Item keeps the source's mtime; stamp it now, the way an
        # installer's freshly extracted file is.
        (Get-Item $runExe).LastWriteTimeUtc = (Get-Date).ToUniversalTime()
    }
    Assert (Wait-LogCount $decide 1 8000) 'S2: the app decided to notify about the newer build'
    Assert ((Get-LogCount 'stale-build balloon: shown=(true|false)') -ge 1) 'S2: it asked the shell for the balloon, and logged the answer'
    "  balloon answer: $(([regex]::Match((Get-LogText), 'stale-build balloon: shown=\w+')).Value)"

    Write-Host '== S3: the same file is announced once'
    $ticksBefore = Get-LogCount ([regex]::Escape($tick + 'true'))
    Wait-LogCount ([regex]::Escape($tick + 'true')) ($ticksBefore + 3) 8000 | Out-Null
    Assert ((Get-LogCount ([regex]::Escape($tick + 'true'))) -ge ($ticksBefore + 3)) 'S3: the check kept ticking over the newer file'
    Assert ((Get-LogCount $decide) -eq 1) "S3: still exactly one notification (got $(Get-LogCount $decide))"

    Write-Host '== S4: a second upgrade while the window is open is announced again'
    if (-not $NegativeControl) {
        (Get-Item $runExe).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddSeconds(5)
    }
    Assert (Wait-LogCount $decide 2 8000) "S4: a newer file notified again (got $(Get-LogCount $decide))"
    Start-Sleep -Seconds 3
    Assert ((Get-LogCount $decide) -eq 2) 'S4: and only once for it'

    Write-Host '== S5: About is the offer, and Later changes nothing'
    $dlg = Open-AboutBox $win $appPid
    Assert ($dlg -ne [IntPtr]::Zero) 'S5: the About box opened (positive control for the palette chord)'
    if ($dlg -ne [IntPtr]::Zero) {
        $buttons = Get-DialogButtons $dlg
        "  buttons: $(($buttons | ForEach-Object { $_.Text }) -join ' | ')"
        $restartBtn = $buttons | Where-Object { $_.Text -eq 'Restart Now' } | Select-Object -First 1
        $laterBtn = $buttons | Where-Object { $_.Text -eq 'Later' } | Select-Object -First 1
        Assert ($null -ne $restartBtn) 'S5: the About box offers "Restart Now"'
        Assert ($null -ne $laterBtn) 'S5: the About box offers "Later"'
        Assert (-not ($buttons | Where-Object { $_.Text -eq 'OK' })) 'S5: not the bare-OK box a current build gets'
        if ($laterBtn) {
            Click-TestPosted $dlg $laterBtn.Ctl | Out-Null
            Assert (Wait-LogCount 'about: newer build on disk, user chose later' 1 5000) 'S5: Later was taken'
        } else {
            Send-TestWindowClose -Window $dlg | Out-Null
        }
        Start-Sleep -Milliseconds 800
        Assert ((Get-LogCount 'restart: the relaunch guard') -eq 0) 'S5: Later did not attempt a restart'
        Assert ($null -ne (Get-Process -Id $appPid -ErrorAction SilentlyContinue)) 'S5: the app is still running'
    }

    Write-Host '== S6: Restart Now that cannot be set up keeps the window'
    $dlg = Open-AboutBox $win $appPid
    Assert ($dlg -ne [IntPtr]::Zero) 'S6: the About box opened again'
    $restartBtn = $null
    if ($dlg -ne [IntPtr]::Zero) {
        $restartBtn = Get-DialogButtons $dlg | Where-Object { $_.Text -eq 'Restart Now' } | Select-Object -First 1
    }
    Assert ($null -ne $restartBtn) 'S6: Restart Now is there to press'
    if ($restartBtn) {
        Click-TestPosted $dlg $restartBtn.Ctl | Out-Null
        Assert (Wait-LogCount 'about: newer build on disk, user chose restart' 1 5000) 'S6: Restart Now was taken'
        Assert (Wait-LogCount 'relaunch guard: NOT armed for app_restart' 1 5000) 'S6: the relaunch guard really failed to arm'
        Assert (Wait-LogCount 'restart: the relaunch guard could not be armed; NOT quitting' 1 5000) 'S6: the app refused to quit without it'
        Assert (Wait-LogCount 'restart into the installed build failed; this window keeps running \(balloon shown=(true|false)\)' 1 5000) 'S6: the user is told (fallback balloon asked for)'
    } elseif ($dlg -ne [IntPtr]::Zero) {
        Send-TestWindowClose -Window $dlg | Out-Null
    }
    Start-Sleep -Seconds 2
    Assert ($null -ne (Get-Process -Id $appPid -ErrorAction SilentlyContinue)) 'S6: the app is still running'
    Assert ((Get-TestWindow -ProcessId $appPid -Class 'GhozttyWindow') -ne [IntPtr]::Zero) 'S6: its window is still there'

    Complete-TestBody
} finally {
    Remove-TestDesktop
    # The private copy is outside the repo, so CleanSlate (rightly) refuses to
    # kill it: stop it here by its own path, then reset the repo's state.
    Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $p = $null; try { $p = $_.Path } catch { }
        $p -and $p.StartsWith($bin, [StringComparison]::OrdinalIgnoreCase)
    } | Stop-Process -Force -ErrorAction SilentlyContinue
    Reset-GhozttyTestState -Exe $Exe -SettleMs 500 | Out-Null
    $env:LOCALAPPDATA = $savedLocalAppData
    Remove-Item Env:GHOZTTY_STALE_BUILD_CHECK_MS -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
    Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
}

$fgSeen = @(Stop-TestForegroundWatch)
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'no test-desktop app ever became foreground on the interactive desktop'
}
Assert (Test-TestBodyComplete) 'the script ran to the end (no section was skipped by an error)'

if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard stale-build-notify -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

""
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Label 'T1211 ACCEPTANCE'
