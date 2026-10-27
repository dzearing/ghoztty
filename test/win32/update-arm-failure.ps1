# T2322 acceptance: an "Install and Restart" that cannot START says so, in the
# app's own window.
#
# The report (2026-10-26): "i click install and restart. NOTHING HAPPENS". The
# log had the reason - `update apply: NOT armed err=error.AccessDenied` - and
# the app had answered with a tray balloon, which Do Not Disturb and the
# notification settings swallow whole. So a click in the window got no answer
# anywhere the user was looking. Mac's Sparkle answers the same failure with an
# alert in the app; the Windows translation is Ghoztty's own dialog, owned by
# the window.
#
# Sections:
#   A. a staged update; the click and "Install and Restart" (as update-consent.ps1)
#   B. the arm fails (forced) -> a dialog in the APP's process, titled for what
#      happened, saying the terminal is untouched, the cause, the way forward
#      and the error
#   C. the app stays up, nothing was armed, the package is still staged, and the
#      menu row now says the last try failed
#   D. "Close" dismisses it and the app is still running
#
# The failure is forced through GHOZTTY_UPDATE_ARM_FAIL=1, a Debug-only seam in
# update_install.zig that fails the arm with AccessDenied (the error the report
# hit) before anything is spawned. Everything else - the click, the consent
# dialog, the failure report - is the shipping path.
#
# -NegativeControl leaves the seam OFF: the arm then succeeds, the app quits to
# install, no failure dialog appears, and the run MUST go red. msiexec is never
# run either way (GHOZTTY_UPDATE_MSI_CODE=0, as in update-consent.ps1).
#
# Runs on a BACKGROUND desktop out of a SANDBOX copy of the build.
#
#   powershell -NoProfile -File test\win32\update-arm-failure.ps1
param(
    [string]$Exe,
    [switch]$NegativeControl,
    [switch]$Interactive
)
$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not $Exe) { $Exe = Join-Path $repo 'zig-out\bin\ghoztty.exe' }
if (-not (Test-Path $Exe)) { Write-Host "SETUP FAIL: $Exe missing (zig build first)"; exit 1 }
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$env:GHOZTTY_NO_STARTUP_ESCAPE = '1'
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\ApplierSandbox.ps1')
[void](Set-GhozttyTestIsolation -Tag 't2322')
Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

trap { Restore-RepoBuild -ExePath $Exe; break }

# The words update_apply.zig / update_badge.zig spell; constants so a rename
# has to be deliberate on both sides.
$FAIL_TITLE = 'Ghoztty could not start the update'
$FAILED_SUFFIX = ' (last try failed)'

# ------------------------------------------------------------------ fixtures

$work = Join-Path $env:TEMP "ghoztty-t2322-$PID"
Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $work | Out-Null

$staging = Join-Path $env:LOCALAPPDATA 'ghoztty\updates-debug'
$stagedMsi = Join-Path $staging 'Ghoztty-9.9.9-x64.msi'

$assetDir = Join-Path $work 'download\win-v9.9.9'
New-Item -ItemType Directory -Force $assetDir | Out-Null
$msiPath = Join-Path $assetDir 'Ghoztty-9.9.9-x64.msi'
$bytes = New-Object byte[] 8192
[Array]::Copy([byte[]](0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1), $bytes, 8)
[IO.File]::WriteAllBytes($msiPath, $bytes)
$msiUrl = 'file:///' + ($msiPath -replace '\\', '/')
$feedPath = Join-Path $work 'feed.json'
[IO.File]::WriteAllText($feedPath,
    '[{"tag_name":"v1.17.0","assets":[]},' +
    '{"tag_name":"win-v9.9.9","assets":[{"browser_download_url":"' + $msiUrl + '"}]}]')
$feedUrl = 'file:///' + ($feedPath -replace '\\', '/')

$WM_APP_TRAY = 0x8003
$NIN_BALLOONUSERCLICK = 0x0405
$UID_UPDATE = 2

$script:appLog = Join-Path $work 'app.log'
function Get-AppLog { if (Test-Path $script:appLog) { [string](Get-Content -LiteralPath $script:appLog -Raw -ErrorAction SilentlyContinue) } else { '' } }
function Wait-Log([string]$Pattern, [int]$TimeoutMs = 20000) {
    for ($t = 0; $t -lt $TimeoutMs; $t += 250) {
        if ((Get-AppLog) -match $Pattern) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return $false
}
function Get-Dialogs { return @(Get-TestWindows -ProcessId $script:appPid -Class 'GhozttyConfirmDialog') }
function Wait-DialogTitled([string]$Title, [int]$TimeoutMs = 10000) {
    for ($t = 0; $t -lt $TimeoutMs; $t += 200) {
        foreach ($d in @(Get-Dialogs)) {
            if ((Get-TestWindowText -Window ([IntPtr]$d.Hwnd)) -eq $Title) { return [IntPtr]$d.Hwnd }
        }
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
function Get-DialogBody([IntPtr]$Dialog) {
    return (@(Get-TestChildWindows -Window $Dialog -Class 'Static') |
        ForEach-Object { Get-TestControlText -Control ([IntPtr]$_.Hwnd) }) -join "`n"
}
function Send-BalloonClick {
    return (Send-TestRawMessage -Window $script:msgWnd -Message ([uint32]$WM_APP_TRAY) `
            -WParam ([IntPtr]$UID_UPDATE) -LParam ([IntPtr]$NIN_BALLOONUSERCLICK))
}
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
$env:GHOZTTY_UPDATE_MSI_CODE = '0'
$env:GHOZTTY_URL_SCHEME = 'off'
Remove-Item Env:GHOZTTY_UPDATE_AUTO_APPLY -ErrorAction SilentlyContinue
if ($NegativeControl) {
    Write-Host 'NEGATIVE CONTROL: the arm is NOT forced to fail - this run MUST fail'
    Remove-Item Env:GHOZTTY_UPDATE_ARM_FAIL -ErrorAction SilentlyContinue
} else {
    $env:GHOZTTY_UPDATE_ARM_FAIL = '1'
}

# ------------------------------------------- A: the click and the consent
Write-Host '== A: a staged update, the click, "Install and Restart"'
$script:app = Start-OnTestDesktop -Exe $sandbox.Exe -Arguments @('--session-persistence=false') -StdErr $script:appLog
$script:appPid = $script:app.Pid
Assert (Wait-Log 'update staged for win-v9\.9\.9') 'the package was pre-downloaded and staged'
$script:msgWnd = Find-TestMessageWindow -ProcessId $script:appPid
Assert ($script:msgWnd -ne [IntPtr]::Zero) "the app's message-only window was found"
Assert (Send-BalloonClick) 'the balloon click was delivered'
$consent = Wait-DialogTitled 'Update Ghoztty'
Assert ($consent -ne [IntPtr]::Zero) 'the click raised the "Update Ghoztty" consent dialog'
$btn = if ($consent -ne [IntPtr]::Zero) { Get-DialogButton $consent 'Install and Restart' } else { $null }
Assert ($null -ne $btn) 'it has an "Install and Restart" button'
if ($btn) { [void](Send-TestControlClick -Control ([IntPtr]$btn.Hwnd)) }

# ------------------------------------------- B: the failure is SAID, in-window
Write-Host '== B: the arm fails, and the app says so in its own dialog'
$dlg = Wait-DialogTitled $FAIL_TITLE 15000
Assert ($dlg -ne [IntPtr]::Zero) "a dialog titled '$FAIL_TITLE' appeared in the APP's process (pid $script:appPid)"
$body = if ($dlg -ne [IntPtr]::Zero) { Get-DialogBody $dlg } else { '' }
Assert ($body -match 'still running the version') 'it says the terminal is untouched'
Assert ($body -match 'earlier update is still finishing') 'it names the cause in words'
Assert ($body -match "Try again from Ghoztty's menu") 'it says what to do next'
Assert ($body -match '\(Error: AccessDenied\)') 'it carries the error for a bug report'
Assert ($null -ne $(if ($dlg -ne [IntPtr]::Zero) { Get-DialogButton $dlg 'Open Releases Page' })) 'it offers the releases page'
$close = if ($dlg -ne [IntPtr]::Zero) { Get-DialogButton $dlg 'Close' } else { $null }
Assert ($null -ne $close) 'it has a "Close" button'
Assert ((Get-AppLog) -match 'update: install could not start \(AccessDenied\); telling the user in a dialog') 'the app logged that it told the user'
Assert ((Get-AppLog) -notmatch 'showing update balloon.*could not be started') 'it no longer answers the click with a tray balloon alone'

# ------------------------------------------- C: nothing lost
Write-Host '== C: the terminal, the package and the offer are all still there'
Assert (-not $script:app.Process.HasExited) 'the app is still running'
Assert ((Get-AppLog) -notmatch 'update apply: ARMED') 'nothing was armed'
Assert ((Get-AppLog) -notmatch 'applier armed, quitting to install') 'the app did not quit'
Assert (Test-Path $stagedMsi) 'the package is still staged for the next try'
Assert ((Get-AppLog) -match 'update: the install row now says the last try failed') "the menu row now reads '...$FAILED_SUFFIX'"

# ------------------------------------------- D: Close
Write-Host '== D: "Close" dismisses it'
if ($close) { [void](Send-TestControlClick -Control ([IntPtr]$close.Hwnd)) }
Assert (Wait-NoDialog) 'the dialog closed'
Start-Sleep -Milliseconds 800
Assert (-not $script:app.Process.HasExited) 'and the app is still running'

# ------------------------------------------- E: the repo build survived
Write-Host '== E: the repo build is untouched'
Assert (Test-Path $Exe) 'zig-out\bin\ghoztty.exe is still there'
Assert (@(Get-SidelinedBuild -ExePath $Exe).Count -eq 0) 'nothing beside the repo build was renamed aside'

Complete-TestBody  # T1039

} catch {
    $script:fail++
    Write-Host "FAIL  the run terminated: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "      at $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())"
} finally {
    Write-Host '== teardown'
    Remove-Item Env:GHOZTTY_UPDATE_URL -ErrorAction SilentlyContinue
    Remove-Item Env:GHOZTTY_UPDATE_MSI_CODE -ErrorAction SilentlyContinue
    Remove-Item Env:GHOZTTY_UPDATE_ARM_FAIL -ErrorAction SilentlyContinue
    Remove-Item Env:GHOZTTY_URL_SCHEME -ErrorAction SilentlyContinue
    # The negative control's app quits to install and is reopened by the
    # applier; those pids are ours too.
    $script:reopened = @(Get-ImagePids $sandbox.Exe | Where-Object { $_ -ne $script:appPid })
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
    Assert ($leaked.Count -eq 0) 'no app this run started ever became foreground on the interactive desktop'
}

Write-Host ''
if ($script:fail -eq 0) { Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue }
else { Write-Host "logs kept in $work" }

# --- stamp (T783) ----------------------------------------------------------
if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot '..\..\scripts\guard-due.ps1') `
        update -Guard update-arm-failure -Repo $repo 2>&1 |
        ForEach-Object { Write-Host "  $_" }
}

Write-TestVerdict -Pass $script:pass -Fail $script:fail
