# T1242 acceptance: the CONSENT step of the in-app update - the balloon click
# and the "Install and Restart" / "Later" dialog it raises.
#
# Everything either side of this step already has a harness: update-apply.ps1
# (T1178) finds, downloads and stages a package and drives the applier from a
# hand-written spec; update-progress.ps1 (T1195) clicks through the dialog on
# the `auto-update = check` path to watch a download. What nobody drove is the
# DEFAULT path, where the package is already staged and the click is the last
# thing standing between the user and their terminal closing:
#
#   balloon click -> offerUpdate -> ConfirmDialog -> applyStagedUpdate -> arm
#
# If "Install and Restart" stopped arming the applier, or "Later" started
# installing anyway, nothing in the suite would say so.
#
# Sections:
#   A. a staged update does NOT install itself: no dialog, nothing armed
#   B. the balloon click raises Ghoztty's own dialog, worded for what it does
#   C. "Later" closes it, arms nothing, keeps the app up and the package staged
#   D. a second click offers again; "Install and Restart" arms the applier, the
#      app quits, and the applier installs and reopens the terminal
#   E. the repo build survived (the applier only ever saw a sandbox copy)
#
# How it stays off the user's screen and away from their install:
#   * the app runs on a BACKGROUND desktop (lib\TestDesktop.ps1). The click is
#     synthesized the way update-progress.ps1 does it - the shell's tray
#     callback posted into the app's message-only window - which proves the
#     handler and everything after it, and nothing about whether the shell
#     delivers the click (the T240 caveat). The dialog's buttons are clicked as
#     buttons (BM_CLICK on the control the label names), so a swapped id or a
#     relabelled button is caught, which a posted IDOK would not catch.
#   * the app runs out of a SANDBOX COPY of the build (lib\ApplierSandbox.ps1),
#     so the install directory the applier clears is a throwaway one.
#   * msiexec is never run: GHOZTTY_UPDATE_MSI_CODE=0 (a Debug-only seam in
#     update_install.zig) makes the applier act on a success code, so no
#     installer starts and no failure dialog is raised anywhere.
#
# -NegativeControl presses "Later" where section D presses "Install and
# Restart", and the run MUST go red.
#
#   powershell -NoProfile -File test\win32\update-consent.ps1
param(
    [string]$Exe,
    [switch]$NegativeControl,
    [switch]$Interactive
)
$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not $Exe) { $Exe = Join-Path $repo 'zig-out\bin\ghoztty.exe' }
if (-not (Test-Path $Exe)) { Write-Host "SETUP FAIL: $Exe missing (zig build first)"; exit 1 }

# T351: drops an inherited $GHOZTTY_IPC_SOCKET before anything is launched.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
# T675: suppress the app's startup job self-escape - this harness tracks the
# pids it launches.
$env:GHOZTTY_NO_STARTUP_ESCAPE = '1'
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\ApplierSandbox.ps1')
[void](Set-GhozttyTestIsolation -Tag 't1242')
Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

# However this ends, the repo build is put back if anything sidelined it.
trap { Restore-RepoBuild -ExePath $Exe; break }

# ------------------------------------------------------------------ fixtures

$work = Join-Path $env:TEMP "ghoztty-t1242-$PID"
Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $work | Out-Null

# The staging directory a Debug build uses (update-apply.ps1 asserts the name).
$staging = Join-Path $env:LOCALAPPDATA 'ghoztty\updates-debug'
$stagedMsi = Join-Path $staging 'Ghoztty-9.9.9-x64.msi'
$applierCopy = Join-Path $staging 'ghoztty-updater.exe'

# The asset URL must contain /download/win-v<version>/ - that is how the
# scanner proves an asset belongs to the release it is offering.
$assetDir = Join-Path $work 'download\win-v9.9.9'
New-Item -ItemType Directory -Force $assetDir | Out-Null
$msiPath = Join-Path $assetDir 'Ghoztty-9.9.9-x64.msi'
# 8 KB opening with the OLE compound-file signature every MSI carries - enough
# for the content check, and never handed to msiexec (see the header).
$bytes = New-Object byte[] 8192
[Array]::Copy([byte[]](0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1), $bytes, 8)
[IO.File]::WriteAllBytes($msiPath, $bytes)
$msiUrl = 'file:///' + ($msiPath -replace '\\', '/')
$feedPath = Join-Path $work 'feed.json'
[IO.File]::WriteAllText($feedPath,
    '[{"tag_name":"v1.17.0","assets":[]},' +
    '{"tag_name":"win-v9.9.9","assets":[{"browser_download_url":"' + $msiUrl + '"}]}]')
$feedUrl = 'file:///' + ($feedPath -replace '\\', '/')

# WM_APP_TRAY is WM_APP+3 (App.zig); the wparam is the icon's uID and the low
# word of lparam is the event. uID 2 is the update balloon
# (tray_notify.update_uid).
$WM_APP_TRAY = 0x8003
$NIN_BALLOONUSERCLICK = 0x0405
$UID_UPDATE = 2

$script:appLog = Join-Path $work 'app.log'
# Get-Content, not ReadAllText: the app holds its stderr open for writing and
# only a read that shares write access can see it while it runs.
function Get-AppLog { if (Test-Path $script:appLog) { [string](Get-Content -LiteralPath $script:appLog -Raw -ErrorAction SilentlyContinue) } else { '' } }
function Wait-Log([string]$Pattern, [int]$TimeoutMs = 20000) {
    for ($t = 0; $t -lt $TimeoutMs; $t += 250) {
        if ((Get-AppLog) -match $Pattern) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

function Get-Dialogs { return @(Get-TestWindows -ProcessId $script:appPid -Class 'GhozttyConfirmDialog') }
function Wait-Dialog([int]$TimeoutMs = 10000) {
    for ($t = 0; $t -lt $TimeoutMs; $t += 200) {
        $d = @(Get-Dialogs)
        if ($d.Count -gt 0) { return [IntPtr]$d[0].Hwnd }
        Start-Sleep -Milliseconds 200
    }
    return [IntPtr]::Zero
}
function Wait-NoDialog([int]$TimeoutMs = 5000) {
    for ($t = 0; $t -lt $TimeoutMs; $t += 200) {
        if (@(Get-Dialogs).Count -eq 0) { return $true }
        Start-Sleep -Milliseconds 200
    }
    return $false
}
function Get-DialogButton([IntPtr]$Dialog, [string]$Label) {
    return @(Get-TestChildWindows -Window $Dialog -Class 'Button') |
        Where-Object { (Get-TestControlText -Control ([IntPtr]$_.Hwnd)) -eq $Label } |
        Select-Object -First 1
}
function Send-BalloonClick {
    return (Send-TestRawMessage -Window $script:msgWnd -Message ([uint32]$WM_APP_TRAY) `
            -WParam ([IntPtr]$UID_UPDATE) -LParam ([IntPtr]$NIN_BALLOONUSERCLICK))
}

# Processes running an image by full path - how the applier copy and the
# terminal it reopens are found, since neither was launched by this script.
function Get-ImagePids([string]$Path) {
    return @(Get-CimInstance Win32_Process -Filter "Name like 'ghoztty%'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath -and ($_.ExecutablePath -ieq $Path) } |
        ForEach-Object { [int]$_.ProcessId })
}

# ------------------------------------------------------------------- driver

[void](Stop-RepoGhoztty -Exe $Exe -AppOnly -SettleMs 500)
if (Test-Path $staging) { Remove-Item -Recurse -Force $staging -ErrorAction SilentlyContinue }
Remove-Item (Join-Path $env:LOCALAPPDATA 'ghoztty\update_check_at') -ErrorAction SilentlyContinue
$sandbox = New-ApplierSandbox -Exe $Exe -Root $work
$script:reopened = @()

Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {

$env:GHOZTTY_UPDATE_URL = $feedUrl
# The applier inherits this through the app (job_spawn passes the app's own
# environment explicitly, even on the shell-parent hop).
$env:GHOZTTY_UPDATE_MSI_CODE = '0'
# The app runs out of a temp directory here, and a Debug build registers its
# ghoztty-debug:// handler wherever it runs from - left on, this run would
# point the dev build's links at a directory the teardown deletes.
$env:GHOZTTY_URL_SCHEME = 'off'
Remove-Item Env:GHOZTTY_UPDATE_AUTO_APPLY -ErrorAction SilentlyContinue

# ------------------------------------- A: a staged update waits for consent
Write-Host '== A: a staged update waits for the user'
$script:app = Start-OnTestDesktop -Exe $sandbox.Exe -Arguments @('--session-persistence=false') -StdErr $script:appLog
$script:appPid = $script:app.Pid
Assert (Wait-Log 'update staged for win-v9\.9\.9') 'the package was pre-downloaded and staged (auto-update default)'
Assert (Wait-Log 'showing update balloon for win-v9\.9\.9') 'the update balloon was shown'
Assert (Test-Path $stagedMsi) 'the staged package is on disk'
$script:msgWnd = Find-TestMessageWindow -ProcessId $script:appPid
Assert ($script:msgWnd -ne [IntPtr]::Zero) "the app's message-only window was found"
# Settle long enough for an auto-apply tick to have fired had it been going to.
Start-Sleep -Seconds 3
Assert (@(Get-Dialogs).Count -eq 0) 'no dialog appears before the balloon is clicked'
Assert ((Get-AppLog) -notmatch 'update apply: ARMED') 'nothing is armed before the user consents'
Assert (-not $script:app.Process.HasExited) 'the app is still running'

# ------------------------------------------- B: the click raises the dialog
Write-Host '== B: the balloon click raises "Install and Restart?"'
Assert (Send-BalloonClick) 'the balloon click was delivered'
$dlg = Wait-Dialog
Assert ($dlg -ne [IntPtr]::Zero) 'the click raised a Ghoztty confirm dialog'
if ($dlg -ne [IntPtr]::Zero) {
    $title = Get-TestWindowText -Window $dlg
    Assert ($title -eq 'Update Ghoztty') "the dialog is titled 'Update Ghoztty' (got '$title')"
    $body = (@(Get-TestChildWindows -Window $dlg -Class 'Static') |
        ForEach-Object { Get-TestControlText -Control ([IntPtr]$_.Hwnd) }) -join "`n"
    Assert ($body -match '9\.9\.9 is available') "the dialog names the version on offer (got '$($body -replace "`n", ' | ')')"
    Assert ($body -match 'will close') 'the dialog says the terminal will close - that is what is being consented to'
    Assert ($body -match 'sessions are kept') 'the dialog says the sessions survive'
    Assert ($null -ne (Get-DialogButton $dlg 'Install and Restart')) 'the affirmative button reads "Install and Restart"'
    Assert ($null -ne (Get-DialogButton $dlg 'Later')) 'the other button reads "Later"'
}

# --------------------------------------------------- C: "Later" is a refusal
Write-Host '== C: "Later" installs nothing'
$later = if ($dlg -ne [IntPtr]::Zero) { Get-DialogButton $dlg 'Later' } else { $null }
if ($later) { [void](Send-TestControlClick -Control ([IntPtr]$later.Hwnd)) }
Assert (Wait-NoDialog) 'the dialog closed on "Later"'
Assert (Wait-Log 'update: user deferred win-v9\.9\.9' 5000) 'the app recorded a deferral'
Start-Sleep -Seconds 2
Assert ((Get-AppLog) -notmatch 'update apply: ARMED') '"Later" armed no applier'
Assert (-not $script:app.Process.HasExited) '"Later" left the terminal running'
Assert (Test-Path $stagedMsi) '"Later" left the package staged for next time'

# ----------------------------------- D: "Install and Restart" is the consent
Write-Host '== D: a second click, then "Install and Restart"'
Assert (Send-BalloonClick) 'the balloon click was delivered again'
$dlg2 = Wait-Dialog
Assert ($dlg2 -ne [IntPtr]::Zero) 'a deferred update is offered again on the next click'
$press = if ($NegativeControl) { 'Later' } else { 'Install and Restart' }
if ($NegativeControl) { Write-Host 'NEGATIVE CONTROL: pressing "Later" where the consent belongs - this run MUST fail' }
$btn = if ($dlg2 -ne [IntPtr]::Zero) { Get-DialogButton $dlg2 $press } else { $null }
# The terminal the applier reopens inherits GHOZTTY_UPDATE_URL and checks again
# at launch; with the release still in the feed it would stage the package
# right back and "the applier consumed it" could never be read. The running app
# checked already (and will not again for an hour), so only the reopened one
# sees this.
[IO.File]::WriteAllText($feedPath, '[{"tag_name":"v1.17.0","assets":[]}]')
if ($btn) { [void](Send-TestControlClick -Control ([IntPtr]$btn.Hwnd)) }

Assert (Wait-Log 'update apply: ARMED \(applier pid \d+' 10000) '"Install and Restart" armed the applier'
Assert ((Get-AppLog) -match 'update: applier armed, quitting to install') 'the app announced it was quitting to install'
Assert ((Get-AppLog) -notmatch 'installing win-v\S+ automatically') 'it was the click that installed it, not the automatic path'
$exited = $script:app.Process.WaitForExit(15000)
Assert $exited 'the app quit so the package could be installed'

# The applier: waits for the app, acts on the (seamed) success code, deletes
# the package it installed and reopens the terminal out of the install dir.
$applierGone = $false
for ($t = 0; $t -lt 30000; $t += 500) {
    if (@(Get-ImagePids $applierCopy).Count -eq 0 -and -not (Test-Path $stagedMsi)) { $applierGone = $true; break }
    Start-Sleep -Milliseconds 500
}
Assert $applierGone 'the applier ran to completion and consumed the staged package'
if (-not $applierGone) {
    Write-Host "      applier pids still running: $(@(Get-ImagePids $applierCopy) -join ','); package present: $(Test-Path $stagedMsi)"
}
for ($t = 0; $t -lt 15000; $t += 500) {
    $script:reopened = @(Get-ImagePids $sandbox.Exe | Where-Object { $_ -ne $script:appPid })
    if ($script:reopened.Count -gt 0) { break }
    Start-Sleep -Milliseconds 500
}
Assert ($script:reopened.Count -gt 0) "the terminal was reopened from the install directory (pid $($script:reopened -join ','))"

# ------------------------------------------------ E: the repo build survived
Write-Host '== E: the repo build is untouched'
Assert (Test-Path $Exe) 'zig-out\bin\ghoztty.exe is still there'
Assert (@(Get-SidelinedBuild -ExePath $Exe).Count -eq 0) 'nothing beside the repo build was renamed aside'

Complete-TestBody  # T1039: the last statement of the body an unwind can skip

} catch {
    $script:fail++
    Write-Host "FAIL  the run terminated: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "      at $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())"
} finally {
    Write-Host '== teardown'
    Remove-Item Env:GHOZTTY_UPDATE_URL -ErrorAction SilentlyContinue
    Remove-Item Env:GHOZTTY_UPDATE_MSI_CODE -ErrorAction SilentlyContinue
    Remove-Item Env:GHOZTTY_URL_SCHEME -ErrorAction SilentlyContinue
    $script:launched = @(Get-TestLaunchedPids) + $script:reopened
    [void](Stop-ApplierSandbox -Sandbox $sandbox)
    Remove-TestDesktop
    [void](Stop-RepoGhoztty -Exe $Exe -AppOnly -SettleMs 500)
    Restore-RepoBuild -ExePath $Exe
    if (Test-Path $staging) { Remove-Item -Recurse -Force $staging -ErrorAction SilentlyContinue }
}

$fgSeen = @(Stop-TestForegroundWatch)
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    $leaked = @($script:launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'no app this run started or reopened ever became foreground on the interactive desktop'
}

Write-Host ''
if ($script:fail -eq 0) { Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue }
else { Write-Host "logs kept in $work" }

# --- stamp (T783) ----------------------------------------------------------
if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot '..\..\scripts\guard-due.ps1') `
        update -Guard update-consent -Repo $repo 2>&1 |
        ForEach-Object { Write-Host "  $_" }
}

Write-TestVerdict -Pass $script:pass -Fail $script:fail
