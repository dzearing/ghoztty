# T2197 acceptance: Ghoztty-Setup.exe, the installer's front door, SAYS SO
# when Windows Installer will not install - in Ghoztty's own dialog - and says
# nothing when it does.
#
# The defect (2026-08-31, the clean-machine walk): a second double-click on the
# MSI collided with the first install, and the only thing the user saw was a
# window that said "configuring" and vanished. A double-clicked MSI is Windows
# Installer's UI, and the collision is refused before any custom action of ours
# runs, so the fix is a small exe that runs BEFORE Windows Installer: it runs
# the package through MsiInstallProductW, answers Windows' own "Error 1500"
# box itself, and reports the result in the dialog the in-app updater uses.
#
# Arms:
#   A  the collision (1618) -> our dialog names it, says to wait, stays up;
#      the exit code is Windows Installer's
#   B  a REAL Windows Installer call (a damaged package, which msi.dll refuses
#      without installing anything) -> our dialog, and no Windows Installer box
#   C  negative controls: success (0) and a cancel (1602) raise NO dialog
#   D  a setup built without a package says so instead of failing silently
#   E  wiring the compiler does not check: the dialog is the app's, not a copy,
#      the seams are Debug-only, and the exe does not carry the terminal
#
# Runs on a BACKGROUND Win32 desktop (test/win32/lib/TestDesktop.ps1) with a
# per-run LOCALAPPDATA, and never installs anything: arm B's package is a fake
# that Windows Installer cannot open, and every other arm stops at the seam.
#
#   powershell -NoProfile -File test\win32\setup-front-door.ps1

param(
    [string]$Exe = (Join-Path $PSScriptRoot '..\..\zig-out\bin\ghoztty-setup.exe'),
    [switch]$Interactive
)

$ErrorActionPreference = 'Continue'
Set-StrictMode -Off

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:passes = 0
$script:failures = 0
function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ }
    else { "  FAIL $name"; $script:failures++ }
}

# As ConfirmDialog.zig / setup_result.zig spell them.
$DIALOG_CLASS = 'GhozttyConfirmDialog'
$DIALOG_TITLE = 'Ghoztty could not be installed'
$WM_CLOSE = 0x0010
$FEEDBACK_BUDGET_MS = 20000
$PERSIST_MS = 3000

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Exe = [IO.Path]::GetFullPath($Exe)
if (-not (Test-Path $Exe)) { "SETUP FAIL: $Exe not found - build it first (zig build -Dapp-runtime=win32 -Doptimize=Debug)"; exit 2 }

$root = Join-Path $env:TEMP "ghoztty-t2197-$PID"
$savedLocalAppData = $env:LOCALAPPDATA
$seamVars = 'GHOZTTY_SETUP_MSI_CODE', 'GHOZTTY_SETUP_MSI_PATH', 'GHOZTTY_SETUP_REPORT_TIMEOUT_MS'
Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $root | Out-Null
$td = New-TestDesktop -Interactive:$Interactive

function Get-DialogBody($hwnd) {
    $parts = @()
    foreach ($c in @(Get-TestChildWindows -Window ([IntPtr]$hwnd) -Class '*')) {
        $t = Get-TestControlText -Control ([IntPtr]$c.Hwnd)
        if ($t) { $parts += $t }
    }
    return ($parts -join "`n")
}

function Test-Alive($procId) {
    try { return -not ([System.Diagnostics.Process]::GetProcessById($procId).HasExited) }
    catch { return $false }
}

function Wait-Exit($proc, $timeoutMs) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ((Test-Alive $proc.Pid) -and $sw.ElapsedMilliseconds -lt $timeoutMs) { Start-Sleep -Milliseconds 100 }
    return -not (Test-Alive $proc.Pid)
}

function Get-ExitCode($proc) {
    try { if ($proc.Process) { $proc.Process.WaitForExit(2000) | Out-Null; return [int64]$proc.Process.ExitCode } } catch { }
    return -1
}

function Get-Log($file) {
    if (-not (Test-Path $file)) { return '' }
    try {
        $fs = [IO.File]::Open($file, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try { $sr = New-Object IO.StreamReader($fs); try { return $sr.ReadToEnd() } finally { $sr.Dispose() } }
        finally { $fs.Dispose() }
    } catch { return '' }
}

# Every visible top-level window the setup process owns, whatever its class.
function Get-SetupTops($procId) {
    return @(Get-TestWindows -ProcessId $procId -Class '*')
}

function Wait-Dialog($procId, $timeoutMs) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $timeoutMs) {
        $h = Get-TestWindow -ProcessId $procId -Class $DIALOG_CLASS
        if ($h -ne [IntPtr]::Zero) { return $h }
        if (-not (Test-Alive $procId)) { return [IntPtr]::Zero }
        Start-Sleep -Milliseconds 150
    }
    return [IntPtr]::Zero
}

# Run the setup exe on the test desktop with these seam values, in its own
# LOCALAPPDATA, and return the process plus its stderr log.
function Start-Setup($tag, [hashtable]$Seams) {
    $lad = Join-Path $root $tag
    New-Item -ItemType Directory -Force $lad | Out-Null
    $err = Join-Path $root "$tag.err.txt"
    $env:LOCALAPPDATA = $lad
    foreach ($k in $Seams.Keys) { Set-Item "env:$k" $Seams[$k] }
    try {
        $p = Start-OnTestDesktop -Exe $Exe -StdErr $err
    } finally {
        foreach ($v in $seamVars) { Remove-Item "env:$v" -ErrorAction SilentlyContinue }
        $env:LOCALAPPDATA = $savedLocalAppData
    }
    return [pscustomobject]@{ Pid = $p.Pid; Process = $p.Process; Err = $err; LocalAppData = $lad }
}

function Close-Dialog($hwnd) {
    if ($hwnd -ne [IntPtr]::Zero) { [void](Invoke-TestMessage -Window $hwnd -Message ([uint32]$WM_CLOSE)) }
}

try {
    # ========================================================================
    "== A: the collision the user hit is named, in our dialog, and stays up"
    # ========================================================================
    # 1618 cannot be made on demand: a user-created Global\_MSIExecute does not
    # collide (measured in T1206), and the only other way to hold the installer
    # is a real installation, which this script may not start. So the code is
    # forced through the Debug-only seam; everything after it ships.
    $a = Start-Setup 'a' @{ GHOZTTY_SETUP_MSI_CODE = '1618' }
    $dlgA = Wait-Dialog $a.Pid $FEEDBACK_BUDGET_MS
    Assert "A1 the collided install raised Ghoztty's own dialog" ($dlgA -ne [IntPtr]::Zero)
    $titleA = if ($dlgA -ne [IntPtr]::Zero) { Get-TestWindowText -Window $dlgA } else { '' }
    Assert "A2 titled for what happened (got '$titleA')" ($titleA -eq $DIALOG_TITLE)
    $bodyA = if ($dlgA -ne [IntPtr]::Zero) { Get-DialogBody $dlgA } else { '' }
    Assert "A3 it says Ghoztty was not installed" ($bodyA -match 'Ghoztty was not installed')
    Assert "A4 it says another installation is already running" ($bodyA -match 'Another installation is already running')
    Assert "A5 it says to wait for it and run the installer again" ($bodyA -match 'Wait for the other installation to finish.*run\s+this installer again')
    Assert "A6 it points at the log, under this run's profile" ($bodyA -match [regex]::Escape($a.LocalAppData) -and $bodyA -match 'install-\d+\.log')
    Assert "A7 it carries the code for a bug report" ($bodyA -match 'Windows Installer code 1618')
    # "Windows Update" is named on purpose (it holds the installer too); what
    # must not leak in is the updater's wording - "updating", "check for
    # updates", "Ghoztty's menu" - which means nothing before Ghoztty exists.
    Assert "A8 nothing in it is the updater's wording" ($bodyA -notmatch "(?i)updating|check for updates|Ghoztty's update|menu")
    # settle: the elapsed time IS the subject - A9 asks whether the dialog outlives it
    Start-Sleep -Milliseconds $PERSIST_MS
    Assert "A9 still on screen $PERSIST_MS ms later - it does not flash and close" `
        (($dlgA -ne [IntPtr]::Zero) -and (Test-TestWindowExists -Window $dlgA))
    Close-Dialog $dlgA
    $goneA = Wait-Exit $a 10000
    Assert "A10 dismissing it ends the setup" $goneA
    Assert "A11 the exit code is Windows Installer's (got $(Get-ExitCode $a))" ((Get-ExitCode $a) -eq 1618)
    $logA = Get-Log $a.Err
    Assert "A12 the seam stood in for Windows Installer, and said so" `
        ($logA -match 'GHOZTTY_SETUP_MSI_CODE=1618; Windows Installer not run')

    # ========================================================================
    "== B: a REAL Windows Installer refusal comes back as our dialog, not Windows'"
    # ========================================================================
    # A file with the compound-document signature and nothing else: msi.dll
    # opens it, finds no database, and refuses. Nothing is installed.
    $fake = Join-Path $root 'damaged.msi'
    $bytes = New-Object byte[] 65536
    [byte[]]$sig = 0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1
    [Array]::Copy($sig, $bytes, 8)
    [IO.File]::WriteAllBytes($fake, $bytes)

    $b = Start-Setup 'b' @{ GHOZTTY_SETUP_MSI_PATH = $fake }
    $dlgB = Wait-Dialog $b.Pid ($FEEDBACK_BUDGET_MS * 2)
    $topsB = @(Get-SetupTops $b.Pid)
    $foreignB = @($topsB | Where-Object { $_.Class -ne $DIALOG_CLASS })
    Assert "B1 Windows Installer's refusal raised Ghoztty's own dialog" ($dlgB -ne [IntPtr]::Zero)
    Assert "B2 and no Windows Installer box beside it ($(($foreignB | ForEach-Object { $_.Class }) -join ','))" ($foreignB.Count -eq 0)
    $bodyB = if ($dlgB -ne [IntPtr]::Zero) { Get-DialogBody $dlgB } else { '' }
    $codeB = if ($bodyB -match 'Windows Installer code (\d+)') { [int]$Matches[1] } else { 0 }
    Assert "B3 the code is a real refusal, not success or a cancel (got $codeB)" `
        ($codeB -ne 0 -and $codeB -ne 1602 -and $codeB -ne 3010)
    Assert "B4 a damaged package is told to download again" `
        (($codeB -notin 1619, 1620) -or ($bodyB -match 'Download the installer again'))
    Close-Dialog $dlgB
    [void](Wait-Exit $b 10000)
    Assert "B5 the exit code matches what the dialog said (got $(Get-ExitCode $b))" ((Get-ExitCode $b) -eq $codeB)
    $logB = Get-Log $b.Err
    Assert "B6 Windows Installer was really asked" ($logB -match 'installing .*damaged\.msi')
    $installLogs = @(Get-ChildItem -Path (Join-Path $b.LocalAppData 'ghoztty\setup-debug') -Filter 'install-*.log' -ErrorAction SilentlyContinue)
    Assert "B7 the log the dialog names exists ($($installLogs.Count))" ($installLogs.Count -ge 1)

    # ========================================================================
    "== C: negative controls - an install that succeeds or is cancelled says nothing"
    # ========================================================================
    foreach ($case in @(@{ Tag = 'c0'; Code = '0' }, @{ Tag = 'c1602'; Code = '1602' }, @{ Tag = 'c3010'; Code = '3010' })) {
        $c = Start-Setup $case.Tag @{ GHOZTTY_SETUP_MSI_CODE = $case.Code }
        $goneC = Wait-Exit $c 10000
        $dlgC = if (-not $goneC) { Get-TestWindow -ProcessId $c.Pid -Class $DIALOG_CLASS } else { [IntPtr]::Zero }
        Assert "C$($case.Code)a code $($case.Code): the setup exits on its own with no dialog" ($goneC -and $dlgC -eq [IntPtr]::Zero)
        Assert "C$($case.Code)b code $($case.Code): exit code passed through (got $(Get-ExitCode $c))" ((Get-ExitCode $c) -eq [int]$case.Code)
        if (-not $goneC) { Close-Dialog $dlgC; try { Stop-Process -Id $c.Pid -Force } catch { } }
    }

    # ========================================================================
    "== D: a setup that carries no package says so"
    # ========================================================================
    # The dev build is made without -Dsetup-msi, which is exactly this case.
    # A bounded dialog (the seam), so the arm does not depend on WM_CLOSE.
    $d = Start-Setup 'd' @{ GHOZTTY_SETUP_REPORT_TIMEOUT_MS = '8000' }
    $dlgD = Wait-Dialog $d.Pid $FEEDBACK_BUDGET_MS
    $bodyD = if ($dlgD -ne [IntPtr]::Zero) { Get-DialogBody $dlgD } else { '' }
    Assert "D1 an empty setup raised the dialog" ($dlgD -ne [IntPtr]::Zero)
    Assert "D2 it says the installer carries no package" ($bodyD -match 'does not carry a Ghoztty package')
    $goneD = Wait-Exit $d 20000
    Assert "D3 the bounded dialog dismissed itself and the setup exited non-zero (got $(Get-ExitCode $d))" `
        ($goneD -and (Get-ExitCode $d) -ne 0)

    # ========================================================================
    "== E: wiring the compiler does not check"
    # ========================================================================
    $src = Join-Path $repo 'src\apprt\win32'
    $mainSrc = Get-Content -Raw (Join-Path $src 'setup_main.zig')
    $dialogFiles = 'ConfirmDialog.zig', 'confirm_dialog_window.zig', 'confirm_dialog_layout.zig', 'WhatsNewNotesView.zig'
    $direct = @($dialogFiles | Where-Object { (Get-Content -Raw (Join-Path $src $_)) -match '@import\("App\.zig"\)' })
    Assert "E1 every dialog file names App through dialog_app.zig ($($direct -join ','))" ($direct.Count -eq 0)
    Assert "E2 the setup shows the app's ConfirmDialog, not a copy" ($mainSrc -match '@import\("ConfirmDialog\.zig"\)' -and $mainSrc -match 'showStandalone')
    Assert "E3 its words come from setup_result.zig" ($mainSrc -match 'setup_result\.describe\(')
    $seamGates = ([regex]::Matches($mainSrc, 'builtin\.mode != \.Debug|builtin\.mode == \.Debug')).Count
    Assert "E4 all three seams sit behind a Debug check ($seamGates gates)" ($seamGates -ge 3)
    Assert "E5 the root declares itself app-less" ((Get-Content -Raw (Join-Path $repo 'src\setup_main.zig')) -match 'pub const ghoztty_dialog_app_less = true')
    Assert "E6 the build installs it beside the exe" ((Get-Content -Raw (Join-Path $repo 'build.zig')) -match 'GhosttySetup\.init')
    $sizeMb = [math]::Round((Get-Item $Exe).Length / 1MB, 1)
    Assert "E7 the setup exe does not carry the terminal ($sizeMb MB, Debug)" ($sizeMb -lt 6)
    Assert "E8 the dialog's handler answers only the collision box" `
        ((Get-Content -Raw (Join-Path $src 'setup_result.zig')) -match 'return msi_error == msi_error_install_in_progress;')

    Complete-TestBody
} finally {
    foreach ($v in $seamVars) { Remove-Item "env:$v" -ErrorAction SilentlyContinue }
    $env:LOCALAPPDATA = $savedLocalAppData
    Remove-TestDesktop
    if ($script:failures -eq 0) { Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue }
    else { Write-Host "logs kept in $root" }
}

# --- stamp (T783) ----------------------------------------------------------
if ($script:failures -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot '..\..\scripts\guard-due.ps1') `
        update -Guard setup-front-door -Repo $repo 2>&1 |
        ForEach-Object { Write-Host "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:passes -Fail $script:failures -Label 'setup-front-door' -MinPass 36
