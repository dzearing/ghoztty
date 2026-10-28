# T1206 acceptance: an in-app update that cannot be applied SAYS SO.
#
# The defect, from the clean-machine walk on 2026-08-31: a second installer
# transaction collided with the first, and the only thing the user saw was a
# window that said "configuring" and then vanished. Nothing named the cause,
# nothing stayed on screen, and there was no way to tell an update that failed
# from one that never started.
#
# The in-app update path is the half that is entirely ours (Windows Installer
# owns the UI of a double-clicked MSI), so it is the half made loud here: when
# msiexec comes back non-zero, the applier relaunches the terminal and then
# raises Ghoztty's own dialog naming the cause, the remedy, the log and the
# code — and that dialog stays until it is dismissed.
#
# Since T2344 the dialog is the REOPENED APP's, owned by its window: the
# applier, windowless and without the foreground, leaves a failure marker
# before it relaunches and exits, because its own modal opened behind the
# terminal it had just reopened and on 2026-10-26 nobody saw it.
#
# Arms:
#   A  a real msiexec rejection -> the reopened app's dialog, owned by its window
#   B  the collision itself (1618) -> the dialog names it in words
#   G  an automatic install that fails -> no dialog, the marker consumed
#   C  negative control: an update that succeeds raises NO dialog
#   D  wiring the compiler does not check: the other silent path, and the
#      Debug-only seam arm B needs
#   E  the repo build survived the run (T1271; -NegativeControl proves the
#      alarm can score red)
#   F  with no reopened app the applier's own dialog times out and it exits
#      (T2321) - runs before E, which must stay last
#
# Every arm hands the applier a THROWAWAY install directory holding a copy of
# the build (lib\ApplierSandbox.ps1), never zig-out\bin. The applier's job when
# it meets a locked image is to rename it aside so msiexec can write a fresh
# one, and the packages here are ones msiexec never accepts - so pointed at the
# repo build, a single straggler holding ghoztty.exe open leaves the turn with
# no binary at all (T1268, observed for real on 2026-09-01).
#
# Runs on a BACKGROUND Win32 desktop (test/win32/lib/TestDesktop.ps1) with a
# private IPC endpoint and a per-run LOCALAPPDATA, and never installs anything:
# arm A's package is a fake msiexec rejects, and arms B/C never reach msiexec
# at all.
#
#   powershell -NoProfile -File test\win32\update-failure-visible.ps1

param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [switch]$Interactive,
    [switch]$NegativeControl
)

$ErrorActionPreference = 'Continue'
Set-StrictMode -Off

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$env:GHOZTTY_NO_STARTUP_ESCAPE = '1'
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\HarnessLeak.ps1')
. (Join-Path $PSScriptRoot 'lib\ApplierSandbox.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:passes = 0
$script:failures = 0
function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ }
    else { "  FAIL $name"; $script:failures++ }
}

# The dialog's class and title as ConfirmDialog.zig / update_apply.zig spell
# them. Constants here so a rename has to be deliberate on both sides.
$DIALOG_CLASS = 'GhozttyConfirmDialog'
$DIALOG_TITLE = 'Ghoztty could not finish updating'
$WM_CLOSE = 0x0010

# How long the message may take to appear once the applier has its verdict.
$FEEDBACK_BUDGET_MS = 30000
# How long the dialog must still be there afterwards. The defect was a window
# that closed before it could be read; anything that auto-dismisses fails this.
$PERSIST_MS = 3000

$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not (Test-Path $Exe)) { "SETUP FAIL: $Exe not found - build it first"; exit 2 }

$root = Join-Path $env:TEMP "ghoztty-t1206-$PID"
$savedLocalAppData = $env:LOCALAPPDATA
$savedApply = $env:GHOZTTY_UPDATE_APPLY
$savedCode = $env:GHOZTTY_UPDATE_MSI_CODE

[void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)
Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $root | Out-Null

[void](Set-GhozttyTestIsolation -Tag 't1206')
Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null
Register-RepoBuildTeardown -Exe $Exe | Out-Null
$td = New-TestDesktop -Interactive:$Interactive

# Production spawns the applier as a COPY in the staging directory, never as
# the installed exe (an applier running out of the directory it clears would
# rename its own image aside). The harness drives the same shape, so what is
# tested is what ships.
$applier = Join-Path $root 'ghoztty-updater.exe'
Copy-Item $Exe $applier -Force

# ...and the directory it is told to install INTO is a throwaway holding a copy
# of the build (T1271). See the header: the applier renames a locked image
# aside, every package here is one msiexec refuses, and nothing ever writes the
# exe back - so the one binary the rest of the turn depends on is not what that
# is aimed at. Every assertion below reads the applier's own log or its dialog,
# so all of them hold just as well against the copy.
$sandbox = New-ApplierSandbox -Exe $Exe -Root $root

# A file with the compound-document signature and enough bytes to pass the
# app's own "is this really a package" check, so the rejection under test comes
# from msiexec rather than from us.
function New-FakePackage($path) {
    $bytes = New-Object byte[] 65536
    [byte[]]$sig = 0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1
    [Array]::Copy($sig, $bytes, 8)
    [IO.File]::WriteAllBytes($path, $bytes)
}

# A pid the applier's wait is satisfied by immediately: one that has already
# exited. The wait itself is update-apply.ps1's subject, not this script's.
function New-DeadPid {
    $p = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', 'exit' -PassThru -WindowStyle Hidden
    $null = $p.Handle
    [void]$p.WaitForExit(10000)
    return $p.Id
}

function Get-DialogBody($hwnd) {
    $parts = @()
    foreach ($c in @(Get-TestChildWindows -Window ([IntPtr]$hwnd) -Class '*')) {
        $t = Get-TestControlText -Control ([IntPtr]$c.Hwnd)
        if ($t) { $parts += $t }
    }
    return ($parts -join "`n")
}

function Wait-Dialog($procId, $timeoutMs) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $timeoutMs) {
        $h = Get-TestWindow -ProcessId $procId -Class $DIALOG_CLASS
        if ($h -ne [IntPtr]::Zero) { return $h }
        Start-Sleep -Milliseconds 150
    }
    return [IntPtr]::Zero
}

function Wait-Exit($procId, $timeoutMs) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ((Test-Alive $procId) -and $sw.ElapsedMilliseconds -lt $timeoutMs) {
        Start-Sleep -Milliseconds 150
    }
    return -not (Test-Alive $procId)
}

# The pid the applier relaunched the terminal as, from its own log line.
function Get-RelaunchedPid($log) {
    if ($log -match 'relaunched .*ghoztty\.exe as pid (\d+)') { return [int]$Matches[1] }
    return 0
}

# Where the applier leaves a failure for the reopened app (T2344), under the
# per-arm LOCALAPPDATA: update_apply.failureMarkerName on a Debug build.
function Get-FailureMarkerPath($localAppData) {
    return (Join-Path $localAppData 'ghoztty\update-failed-debug')
}

function Test-Alive($procId) {
    try { return -not ([System.Diagnostics.Process]::GetProcessById($procId).HasExited) }
    catch { return $false }
}

# Start the applier on the test desktop with a spec, and return its pid plus
# the stderr file it is writing (Debug builds use the console subsystem, so
# std.log lands there).
function Start-Applier($tag, $spec, [string]$Report = '') {
    $err = Join-Path $root "$tag.err.txt"
    $env:GHOZTTY_UPDATE_APPLY = $spec
    # How the app would have asked for the install (T2344): `manual` for a
    # click, `auto` for an automatic one. Unset means an applier driven by hand.
    if ($Report) { $env:GHOZTTY_UPDATE_REPORT = $Report }
    try {
        $p = Start-OnTestDesktop -Exe $applier -StdErr $err
    } finally {
        Remove-Item env:GHOZTTY_UPDATE_APPLY -ErrorAction SilentlyContinue
        Remove-Item env:GHOZTTY_UPDATE_REPORT -ErrorAction SilentlyContinue
    }
    return [pscustomobject]@{ Pid = $p.Pid; Err = $err }
}

# Read the applier's stderr WHILE it still holds the file open - every arm here
# asserts on the log of a process that is deliberately still alive, sitting on
# its modal. `[IO.File]::ReadAllText` opens with FileShare.Read and throws on
# exactly that, so the share mode is spelled out.
function Get-ApplierLog($file) {
    if (-not (Test-Path $file)) { return '' }
    try {
        $fs = [IO.File]::Open($file, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            $sr = New-Object IO.StreamReader($fs)
            try { return $sr.ReadToEnd() } finally { $sr.Dispose() }
        } finally { $fs.Dispose() }
    } catch { return '' }
}

try {
    # ========================================================================
    "== A: an update msiexec refuses is reported BY THE REOPENED APP, in its window"
    # ========================================================================
    # Since T2344 the applier says nothing itself when it could relaunch the
    # app: its modal opened behind the terminal it had just reopened, and on
    # 2026-10-26 nobody saw it. It leaves a failure marker, and the reopened
    # app raises the dialog, owned by its own window.
    $tmpA = Join-Path $root 'a'
    New-Item -ItemType Directory -Force $tmpA | Out-Null
    $env:LOCALAPPDATA = $tmpA
    $markerA = Get-FailureMarkerPath $tmpA

    $msiA = Join-Path $root 'apply-me.msi'
    New-FakePackage $msiA
    $appA = Start-Applier 'a' "$(New-DeadPid)|$msiA|$($sandbox.Exe)" -Report 'manual'

    $goneA = Wait-Exit $appA.Pid $FEEDBACK_BUDGET_MS
    $logA = Get-ApplierLog $appA.Err
    Assert "A0 the applier handed the failure over and exited on its own" `
        ($goneA -and ($logA -match 'failure handed to the reopened app'))
    $reopenedA = Get-RelaunchedPid $logA
    Assert "A1 the terminal was relaunched (pid $reopenedA)" ($reopenedA -gt 0)

    $dlgA = if ($reopenedA -gt 0) { Wait-Dialog $reopenedA $FEEDBACK_BUDGET_MS } else { [IntPtr]::Zero }
    Assert "A2 the REOPENED app raised Ghoztty's own dialog" ($dlgA -ne [IntPtr]::Zero)

    $titleA = if ($dlgA -ne [IntPtr]::Zero) { Get-TestWindowText -Window $dlgA } else { '' }
    Assert "A3 titled for what happened, not for msiexec (got '$titleA')" ($titleA -eq $DIALOG_TITLE)

    $bodyA = if ($dlgA -ne [IntPtr]::Zero) { Get-DialogBody $dlgA } else { '' }
    # What a person needs: that their terminal survived, what went wrong, what
    # to do, and the two identifiers a bug report is matched on.
    Assert "A4 it says the old version is still there" ($bodyA -match 'still running the version')
    Assert "A5 it names a cause in words" ($bodyA -match 'Windows Installer stopped|package could not be opened|damaged')
    Assert "A6 it says what to do next" ($bodyA -match 'Check for updates again')
    Assert "A7 it points at the log" ($bodyA -match 'install\.log')
    Assert "A8 it carries the numeric code for a bug report" ($bodyA -match 'Windows Installer code \d+')

    # Owned by the terminal window, so it sits ON the window it is about
    # instead of somewhere behind it.
    $ownerA = if ($dlgA -ne [IntPtr]::Zero) { [IntPtr](Get-TestWindowOwner -Window $dlgA) } else { [IntPtr]::Zero }
    $termA = if ($reopenedA -gt 0) { Get-TestWindow -ProcessId $reopenedA } else { [IntPtr]::Zero }
    Assert "A9 the dialog is owned by the reopened terminal's window" `
        (($ownerA -ne [IntPtr]::Zero) -and ($ownerA -eq $termA))

    # The whole defect: a window nobody could read.
    Start-Sleep -Milliseconds $PERSIST_MS
    Assert "A10 the dialog is still on screen $PERSIST_MS ms later - it does not flash and close" `
        (($dlgA -ne [IntPtr]::Zero) -and (Test-TestWindowExists -Window $dlgA))
    Assert "A11 the marker was consumed, so the failure is told once" (-not (Test-Path $markerA))

    if ($dlgA -ne [IntPtr]::Zero) {
        [void](Invoke-TestMessage -Window $dlgA -Message ([uint32]$WM_CLOSE))
    }
    Start-Sleep -Milliseconds 1500
    Assert "A12 dismissing it leaves the terminal running" `
        (($reopenedA -gt 0) -and (Test-Alive $reopenedA) -and (-not (Test-TestWindowExists -Window $dlgA)))
    Assert "A13 a package msiexec rejected is kept, not deleted" (Test-Path $msiA)
    [void](Stop-ApplierSandbox -Sandbox $sandbox)
    [void](Stop-RepoGhoztty -Exe $Exe -AppOnly -SettleMs 600)

    # ========================================================================
    "== B: the collision the user actually hit is named in words"
    # ========================================================================
    # 1618 (ERROR_INSTALL_ALREADY_RUNNING) cannot be manufactured from outside
    # msiexec - a user-created Global\_MSIExecute does not collide (measured on
    # box 2026-09-01: msiexec ran straight past it), and the only other way to
    # hold that mutex is a real installation, which this script may not start.
    # So the code is forced through the Debug-only seam and everything
    # downstream of it - the message, the marker, the dialog - is the shipping
    # path. No GHOZTTY_UPDATE_REPORT on purpose: an applier armed without it
    # reports as a click would, the louder of the two.
    $tmpB = Join-Path $root 'b'
    New-Item -ItemType Directory -Force $tmpB | Out-Null
    $env:LOCALAPPDATA = $tmpB

    $msiB = Join-Path $root 'collide.msi'
    New-FakePackage $msiB
    $env:GHOZTTY_UPDATE_MSI_CODE = '1618'
    try {
        $appB = Start-Applier 'b' "$(New-DeadPid)|$msiB|$($sandbox.Exe)"
    } finally {
        Remove-Item env:GHOZTTY_UPDATE_MSI_CODE -ErrorAction SilentlyContinue
    }

    [void](Wait-Exit $appB.Pid $FEEDBACK_BUDGET_MS)
    $logB = Get-ApplierLog $appB.Err
    $reopenedB = Get-RelaunchedPid $logB
    $dlgB = if ($reopenedB -gt 0) { Wait-Dialog $reopenedB $FEEDBACK_BUDGET_MS } else { [IntPtr]::Zero }
    Assert "B1 the collided transaction raised a dialog in the reopened app" ($dlgB -ne [IntPtr]::Zero)
    $bodyB = if ($dlgB -ne [IntPtr]::Zero) { Get-DialogBody $dlgB } else { '' }
    Assert "B2 it says another installation is already running" `
        ($bodyB -match 'Another installation is already running')
    Assert "B3 it tells the user to wait for it and try again" `
        ($bodyB -match 'Wait for the other installation')
    Assert "B4 the code is there for a bug report, but not the whole message" `
        (($bodyB -match '1618') -and ($bodyB.Length -gt 200))
    Assert "B5 the seam skipped msiexec rather than running one" ($logB -notmatch 'msiexec\.exe /i')
    Assert "B6 with no report spec the applier still handed over a click's dialog" `
        ($logB -match 'failure marker written origin=manual code=1618')

    if ($dlgB -ne [IntPtr]::Zero) {
        [void](Invoke-TestMessage -Window $dlgB -Message ([uint32]$WM_CLOSE))
    }
    Start-Sleep -Milliseconds 1500
    Assert "B7 dismissing it leaves the terminal running" (($reopenedB -gt 0) -and (Test-Alive $reopenedB))
    [void](Stop-ApplierSandbox -Sandbox $sandbox)
    [void](Stop-RepoGhoztty -Exe $Exe -AppOnly -SettleMs 600)

    # ========================================================================
    "== G: an AUTOMATIC install that fails says so without a dialog (T2344)"
    # ========================================================================
    # Nobody clicked anything, so nobody is owed a modal: the reopened app
    # consumes the marker, flags the menu row and posts a balloon. The balloon
    # itself is not observable on a background desktop (no notification area),
    # so this arm proves the app consumed the marker and raised NO dialog; D7
    # holds the balloon and the menu flag to the source.
    $tmpG = Join-Path $root 'g'
    New-Item -ItemType Directory -Force $tmpG | Out-Null
    $env:LOCALAPPDATA = $tmpG
    $markerG = Get-FailureMarkerPath $tmpG

    $msiG = Join-Path $root 'auto.msi'
    New-FakePackage $msiG
    $env:GHOZTTY_UPDATE_MSI_CODE = '1603'
    try {
        $appG = Start-Applier 'g' "$(New-DeadPid)|$msiG|$($sandbox.Exe)" -Report 'auto'
    } finally {
        Remove-Item env:GHOZTTY_UPDATE_MSI_CODE -ErrorAction SilentlyContinue
    }
    $goneG = Wait-Exit $appG.Pid $FEEDBACK_BUDGET_MS
    $logG = Get-ApplierLog $appG.Err
    Assert "G1 the applier wrote an automatic install's marker and exited" `
        ($goneG -and ($logG -match 'failure marker written origin=auto code=1603'))
    $reopenedG = Get-RelaunchedPid $logG
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ((Test-Path $markerG) -and $sw.ElapsedMilliseconds -lt $FEEDBACK_BUDGET_MS) {
        Start-Sleep -Milliseconds 200
    }
    Assert "G2 the reopened app consumed the marker ($($sw.ElapsedMilliseconds) ms)" `
        (($reopenedG -gt 0) -and (-not (Test-Path $markerG)))
    Start-Sleep -Milliseconds $PERSIST_MS
    $aliveG = ($reopenedG -gt 0) -and (Test-Alive $reopenedG)
    # By title: the sandbox has no agent beside its copy of the build, so the
    # reopened app also raises "Session persistence unavailable" - true, and
    # not this arm's subject.
    $foundG = if ($reopenedG -gt 0) { @(Get-TestWindows -ProcessId $reopenedG -Class $DIALOG_CLASS -AllowHidden) } else { @() }
    $titlesG = @($foundG | ForEach-Object { Get-TestWindowText -Window ([IntPtr]$_.Hwnd) })
    $oursG = @($titlesG | Where-Object { $_ -eq $DIALOG_TITLE })
    Assert "G3 the terminal is still running (alive=$aliveG)" $aliveG
    Assert "G4 and raised no update dialog for an install nobody asked for (dialogs up: '$($titlesG -join "', '")')" `
        (($reopenedG -gt 0) -and ($oursG.Count -eq 0))
    [void](Stop-ApplierSandbox -Sandbox $sandbox)
    [void](Stop-RepoGhoztty -Exe $Exe -AppOnly -SettleMs 600)

    # ========================================================================
    "== C: negative control - an update that WORKS says nothing"
    # ========================================================================
    # Without this arm every assertion above is also satisfied by a build that
    # raises the dialog on every update, which would be a worse defect than the
    # silence it replaced.
    $tmpC = Join-Path $root 'c'
    New-Item -ItemType Directory -Force $tmpC | Out-Null
    $env:LOCALAPPDATA = $tmpC

    $msiC = Join-Path $root 'ok.msi'
    New-FakePackage $msiC
    $env:GHOZTTY_UPDATE_MSI_CODE = '0'
    try {
        $appC = Start-Applier 'c' "$(New-DeadPid)|$msiC|$($sandbox.Exe)"
    } finally {
        Remove-Item env:GHOZTTY_UPDATE_MSI_CODE -ErrorAction SilentlyContinue
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ((Test-Alive $appC.Pid) -and $sw.ElapsedMilliseconds -lt $FEEDBACK_BUDGET_MS) {
        Start-Sleep -Milliseconds 200
    }
    Assert "C1 a successful apply finishes on its own, with nothing to dismiss" `
        (-not (Test-Alive $appC.Pid))
    Assert "C2 and raised NO dialog" `
        (@(Get-TestWindows -ProcessId $appC.Pid -Class $DIALOG_CLASS -AllowHidden).Count -eq 0)
    Assert "C3 the applied package was cleaned up" (-not (Test-Path $msiC))
    $logC = Get-ApplierLog $appC.Err
    Assert "C4 and the log records a success, not a failure" `
        (($logC -match 'msiexec succeeded') -and ($logC -notmatch 'could not finish updating'))
    [void](Stop-ApplierSandbox -Sandbox $sandbox)
    [void](Stop-RepoGhoztty -Exe $Exe -AppOnly -SettleMs 600)

    # ========================================================================
    "== D: the wiring no compiler checks"
    # ========================================================================
    $instSrc = [IO.File]::ReadAllText((Join-Path $repo 'src\apprt\win32\update_install.zig'))
    $applySrc = [IO.File]::ReadAllText((Join-Path $repo 'src\apprt\win32\update_apply.zig'))

    # The other silent outcome on this path: the app never exited, so nothing
    # was installed and the user was told nothing. A 2-minute wait is not worth
    # a live arm; that it is REPORTED is.
    Assert "D1 the 'app never closed' path reports instead of returning quietly" `
        ($instSrc -match 'report\(update_apply\.describeAppStillRunning')
    Assert "D2 and a non-zero msiexec code reports too" `
        ($instSrc -match 'report\(update_apply\.describeFailure\(&buf, code, log_path\)\)')
    Assert "D3 the report goes up AFTER the relaunch, so the terminal is back first" `
        ($instSrc -match '(?s)const relaunched = relaunch\(arena, spec\.exe\);.*?if \(code != 0\) \{')
    # The seam arm B depends on must not exist in anything shipped.
    Assert "D4 the msiexec-code seam is compiled out of every non-Debug build" `
        ($instSrc -match 'if \(comptime builtin\.mode != \.Debug\) return null;')
    Assert "D5 the dialog title is the one constant both sides read" `
        ($applySrc -match 'pub const failure_title = "Ghoztty could not finish updating";')
    # T2344: the hand-over. The marker is written BEFORE the relaunch, so the
    # reopened app can never start ahead of it, and the app consumes it at
    # startup and tells an automatic failure with a balloon and the menu flag.
    Assert "D6 the failure marker is left before the terminal is relaunched" `
        ($instSrc -match '(?s)leaveFailureMarker\(arena, code, log_path\).*?const relaunched = relaunch\(arena, spec\.exe\);')
    $appSrc = [IO.File]::ReadAllText((Join-Path $repo 'src\apprt\win32\App.zig'))
    Assert "D7 the reopened app consumes it at startup, and an automatic failure gets the balloon and the menu flag" `
        (($appSrc -match 'self\.announceUpdateFailure\(\);') -and
         ($appSrc -match '(?s)fn announceUpdateFailure.*?self\.markInstallFailed\(\);.*?\.balloon => \{.*?update_apply\.auto_failure_title'))
    Assert "D8 both install paths tell the applier who asked" `
        (($appSrc -match '(?s)update_install\.arm\(self\.core_app\.alloc, msi, \.\{\s*\.origin = \.manual') -and
         ($appSrc -match '(?s)update_install\.arm\(alloc, msi\.\?, \.\{\s*\.origin = \.auto'))

    # ========================================================================
    "== F: with no reopened app, the applier's own dialog is bounded (T2321)"
    # ========================================================================
    # 2026-10-26: the applier raised this dialog, nobody ever saw it, and the
    # process sat on it for 26 hours - holding its own image locked, so every
    # later Install Update failed with AccessDenied. Since T2344 the applier
    # raises it only when the relaunch FAILED (A0 is the other half: with a
    # reopened app it exits at once). That dialog dismisses itself after
    # update_apply.report_timeout_ms; the Debug seam shortens it so the exit is
    # observable here. The relaunch is made to fail by naming an exe that is
    # not there.
    $tmpF = Join-Path $root 'f'
    New-Item -ItemType Directory -Force $tmpF | Out-Null
    $env:LOCALAPPDATA = $tmpF
    $markerF = Get-FailureMarkerPath $tmpF

    $msiF = Join-Path $root 'unseen.msi'
    New-FakePackage $msiF
    $missingExe = Join-Path (Split-Path $sandbox.Exe -Parent) 'not-here.exe'
    $REPORT_TIMEOUT_MS = 4000
    $env:GHOZTTY_UPDATE_MSI_CODE = '1603'
    $env:GHOZTTY_UPDATE_REPORT_TIMEOUT_MS = "$REPORT_TIMEOUT_MS"
    try {
        $appF = Start-Applier 'f' "$(New-DeadPid)|$msiF|$missingExe" -Report 'manual'
    } finally {
        Remove-Item env:GHOZTTY_UPDATE_MSI_CODE -ErrorAction SilentlyContinue
        Remove-Item env:GHOZTTY_UPDATE_REPORT_TIMEOUT_MS -ErrorAction SilentlyContinue
    }

    $dlgF = Wait-Dialog $appF.Pid $FEEDBACK_BUDGET_MS
    Assert "F1 with no terminal to reopen, the applier reported on screen itself" ($dlgF -ne [IntPtr]::Zero)
    # Nothing touches the dialog from here on: that is the user's 26 hours.
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ((Test-Alive $appF.Pid) -and $sw.ElapsedMilliseconds -lt ($REPORT_TIMEOUT_MS + 15000)) {
        Start-Sleep -Milliseconds 200
    }
    Assert "F2 the applier exited on its own with the dialog unanswered ($($sw.ElapsedMilliseconds) ms)" `
        (-not (Test-Alive $appF.Pid))
    $logF = Get-ApplierLog $appF.Err
    Assert "F3 and its log says the dialog timed out rather than was read" `
        ($logF -match 'failure dialog unanswered after \d+ms; dismissed it and exiting')
    Assert "F4 it reported because the relaunch failed" ($logF -match 'relaunch of .*not-here\.exe FAILED')
    Assert "F5 and took its marker back, so a later launch does not report it twice" (-not (Test-Path $markerF))
    $instSrcF = [IO.File]::ReadAllText((Join-Path $repo 'src\apprt\win32\update_install.zig'))
    Assert "F6 a shipped build bounds the dialog too (the seam only shortens it)" `
        ($instSrcF -match 'orelse update_apply\.report_timeout_ms;')
    [void](Stop-ApplierSandbox -Sandbox $sandbox)
    [void](Stop-RepoGhoztty -Exe $Exe -AppOnly -SettleMs 600)

    # ========================================================================
    "== E: the harness left the repo build alone"
    # ========================================================================
    # Arms A-C each drive a process whose JOB is to move ghoztty.exe out of the
    # way when it cannot be overwritten. Whatever they did, they did it to the
    # sandbox copy: this is the check that would have gone red on 2026-09-01,
    # when update-apply.ps1 - the same shape, the same applier - finished having
    # left zig-out\bin\ghoztty.exe.old-1788324281 and no ghoztty.exe.
    if ($NegativeControl) {
        # Reconstruct exactly what that run left behind, at the point in the
        # script where it left it. Planting it any earlier would only prove that
        # the app's own launch-time sweep works: every arm above starts a real
        # Ghoztty, and that sweep is what clears a sidelined image.
        Copy-Item $Exe (Join-Path (Split-Path $Exe -Parent) 'ghoztty.exe.old-1788324281') -Force
        "  NEGATIVE CONTROL: planted a sidelined repo build"
    }
    $strays = @(Get-SidelinedBuild -ExePath $Exe)
    Assert "E1 the repo build is exactly where it was" (Test-Path $Exe)
    Assert "E2 nothing sidelined the repo build ($($strays.Count) stray .old-* left)" `
        ($strays.Count -eq 0)
    # Reported first, then repaired: the assertion above is the finding, and a
    # run that quietly fixed the damage before looking would never have one.
    Restore-RepoBuild -ExePath $Exe

    # LAST statement of the top-level try (T1039): an unwind from anywhere
    # above must not reach the verdict as if the run had finished.
    Complete-TestBody
} finally {
    Remove-Item env:GHOZTTY_UPDATE_MSI_CODE -ErrorAction SilentlyContinue
    Remove-Item env:GHOZTTY_UPDATE_REPORT_TIMEOUT_MS -ErrorAction SilentlyContinue
    Remove-Item env:GHOZTTY_UPDATE_APPLY -ErrorAction SilentlyContinue
    Remove-Item env:GHOZTTY_UPDATE_REPORT -ErrorAction SilentlyContinue
    if ($savedCode) { $env:GHOZTTY_UPDATE_MSI_CODE = $savedCode }
    if ($savedApply) { $env:GHOZTTY_UPDATE_APPLY = $savedApply }
    $env:LOCALAPPDATA = $savedLocalAppData
    Remove-TestDesktop
    if ($sandbox) { [void](Stop-ApplierSandbox -Sandbox $sandbox) }
    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 600)
    # However this run ended - an assertion walked off the bottom, or something
    # threw before arm E could even look - the repo build is put back on the way
    # out. The sandbox is why this should never have anything to do.
    Restore-RepoBuild -ExePath $Exe
    if ($script:failures -eq 0) { Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue }
    else { Write-Host "logs kept in $root" }
}

# --- stamp (T783) ----------------------------------------------------------
if ($script:failures -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot '..\..\scripts\guard-due.ps1') `
        update -Guard update-failure-visible -Repo $repo 2>&1 |
        ForEach-Object { Write-Host "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:passes -Fail $script:failures -Label 'update-failure-visible' -MinPass 45
