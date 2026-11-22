# T3393 acceptance: a copy of Ghoztty that is not the installed one never
# hands an update package to msiexec.
#
# msiexec installs the PRODUCT a package names, wherever Windows Installer has
# it registered for this user, not "over the exe that launched it". On
# 2026-11-22 a release build copied into a test sandbox's Programs\Ghoztty
# applied the real MSI and reconfigured the user's own install (T3388). Since
# T3393 `update_install.arm` reads the staged package's UpgradeCode and its
# ghoztty.exe component, asks Windows Installer where that product's exe is,
# and refuses unless it is the running exe's own folder.
#
# Sections:
#   A. a fixture package carrying the RELEASE identity (UpgradeCode and the
#      ghoztty.exe ComponentId build-msi.sh derives) is staged from a canned
#      feed, and "Install and Restart" is clicked in a SANDBOX copy
#   B. the arm is refused: the app's own dialog says this is not the installed
#      copy and points at the releases page; the log names the folder the
#      product is really registered at (or that none is registered)
#   C. nothing was armed, the app stays up, the package stays staged
#   D. the repo build is untouched
#
# Safety: msiexec cannot run here whatever the guard decides.
# GHOZTTY_UPDATE_MSI_CODE=0 (a Debug-only seam) makes the applier return a
# forced code instead of running msiexec, and the fixture is a bare database
# with no ProductCode and no sequences that msiexec would reject anyway.
# GHOZTTY_UPDATE_TARGET_ENFORCE=1 (Debug-only) keeps the guard's teeth while
# that seam is set; without it the verdict is advisory, which is what
# -NegativeControl runs: the arm then SUCCEEDS, no refusal dialog appears, and
# the run MUST go red.
#
# The lookup reads the user's registration (read-only) - the point is to ask
# the same question a sandboxed release copy would have asked. With no release
# installed on the box, the verdict is "not installed", also a refusal; the run
# says which one it saw.
#
# Runs on a BACKGROUND desktop out of a SANDBOX copy of the build.
#
#   powershell -NoProfile -File test\win32\update-target-guard.ps1
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
[void](Set-GhozttyTestIsolation -Tag 't3393')
Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

trap { Restore-RepoBuild -ExePath $Exe; break }

# The words update_apply.zig spells; constants so a rename is deliberate.
$FAIL_TITLE = 'Ghoztty could not start the update'

# The release identity, as dist\windows-installer\build-msi.sh writes it:
# the permanent UpgradeCode, and uuid5(NS a934c3a7-..., "ghoztty.exe") for the
# exe's component. A published MSI carries exactly these (read back from
# Ghoztty-1.28.0-x64.msi on 2026-11-22).
$RELEASE_UPGRADE_CODE = '{5EB02044-7F06-498B-B7A9-7EFD65486CFB}'
$RELEASE_EXE_COMPONENT = '{B6468B9E-B857-5F18-A0B0-86EC18450A18}'

# ------------------------------------------------------------------ fixtures

$work = Join-Path $env:TEMP "ghoztty-t3393-$PID"
Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $work | Out-Null

$staging = Join-Path $env:LOCALAPPDATA 'ghoztty\updates-debug'
$stagedMsi = Join-Path $staging 'Ghoztty-9.9.9-x64.msi'

function Invoke-Com($obj, [string]$name, [string]$kind, [object[]]$argv) {
    return $obj.GetType().InvokeMember($name, $kind, $null, $obj, $argv)
}

# A bare installer database: Property(UpgradeCode), File(ghoztty.exe) and its
# Component in INSTALLDIR - the three things the guard reads, and nothing an
# install could act on.
function New-FixturePackage([string]$Path, [string]$UpgradeCode, [string]$ComponentId) {
    $inst = New-Object -ComObject WindowsInstaller.Installer
    $db = Invoke-Com $inst 'OpenDatabase' 'InvokeMethod' @($Path, 3)  # msiOpenDatabaseModeCreate
    $sql = @(
        'CREATE TABLE `Property` (`Property` CHAR(72) NOT NULL, `Value` LONGCHAR NOT NULL PRIMARY KEY `Property`)',
        'CREATE TABLE `Component` (`Component` CHAR(72) NOT NULL, `ComponentId` CHAR(38), `Directory_` CHAR(72) NOT NULL, `Attributes` SHORT NOT NULL, `Condition` CHAR(255), `KeyPath` CHAR(72) PRIMARY KEY `Component`)',
        'CREATE TABLE `File` (`File` CHAR(72) NOT NULL, `Component_` CHAR(72) NOT NULL, `FileName` CHAR(255) NOT NULL, `FileSize` LONG NOT NULL, `Version` CHAR(72), `Language` CHAR(20), `Attributes` SHORT, `Sequence` SHORT NOT NULL PRIMARY KEY `File`)',
        "INSERT INTO ``Property`` (``Property``, ``Value``) VALUES ('UpgradeCode', '$UpgradeCode')",
        "INSERT INTO ``Component`` (``Component``, ``ComponentId``, ``Directory_``, ``Attributes``, ``KeyPath``) VALUES ('cAgent', '{11111111-2222-3333-4444-555555555555}', 'INSTALLDIR', 0, 'fAgent')",
        "INSERT INTO ``File`` (``File``, ``Component_``, ``FileName``, ``FileSize``, ``Sequence``) VALUES ('fAgent', 'cAgent', 'GHOZTT~2.EXE|ghoztty-agent.exe', 1, 1)",
        "INSERT INTO ``Component`` (``Component``, ``ComponentId``, ``Directory_``, ``Attributes``, ``KeyPath``) VALUES ('cExe', '$ComponentId', 'INSTALLDIR', 0, 'fExe')",
        "INSERT INTO ``File`` (``File``, ``Component_``, ``FileName``, ``FileSize``, ``Sequence``) VALUES ('fExe', 'cExe', 'GHOZTT~1.EXE|ghoztty.exe', 1, 2)"
    )
    foreach ($q in $sql) {
        $v = Invoke-Com $db 'OpenView' 'InvokeMethod' @($q)
        [void](Invoke-Com $v 'Execute' 'InvokeMethod' $null)
        [void](Invoke-Com $v 'Close' 'InvokeMethod' $null)
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($v)
    }
    [void](Invoke-Com $db 'Commit' 'InvokeMethod' $null)
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($db)
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($inst)
    # The database handle closes only when the last RCW is finalized; until
    # then the file is locked against the app's download copy.
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
}

# Where Windows Installer has the release's exe, or '' - the oracle for B.
function Get-RegisteredReleaseDir {
    $inst = New-Object -ComObject WindowsInstaller.Installer
    try {
        foreach ($p in @(Invoke-Com $inst 'RelatedProducts' 'GetProperty' @($RELEASE_UPGRADE_CODE))) {
            $path = [string](Invoke-Com $inst 'ComponentPath' 'GetProperty' @($p, $RELEASE_EXE_COMPONENT))
            if ($path) { return (Split-Path $path -Parent) }
        }
    } catch {}
    return ''
}

$assetDir = Join-Path $work 'download\win-v9.9.9'
New-Item -ItemType Directory -Force $assetDir | Out-Null
$msiPath = Join-Path $assetDir 'Ghoztty-9.9.9-x64.msi'
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
$sandboxDir = Split-Path $sandbox.Exe -Parent
$script:reopened = @()

Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {

# ------------------------------------------- A: the fixture and the click
Write-Host '== A: a release-identity package staged in a sandbox copy, the click'
New-FixturePackage -Path $msiPath -UpgradeCode $RELEASE_UPGRADE_CODE -ComponentId $RELEASE_EXE_COMPONENT
$head = [IO.File]::ReadAllBytes($msiPath)[0..7]
Assert (($head[0] -eq 0xD0) -and ($head[1] -eq 0xCF)) 'the fixture is a real installer database (compound-file header)'
$realDir = Get-RegisteredReleaseDir
if ($realDir) { Write-Host "  the release is registered at $realDir" }
else { Write-Host '  no release product is registered for this user: expecting the not-installed refusal' }
Assert (-not $realDir -or ($realDir -ine $sandboxDir)) "the sandbox ($sandboxDir) is not where the release is registered"

$env:GHOZTTY_UPDATE_URL = $feedUrl
$env:GHOZTTY_UPDATE_MSI_CODE = '0'
$env:GHOZTTY_URL_SCHEME = 'off'
Remove-Item Env:GHOZTTY_UPDATE_AUTO_APPLY -ErrorAction SilentlyContinue
Remove-Item Env:GHOZTTY_UPDATE_ARM_FAIL -ErrorAction SilentlyContinue
if ($NegativeControl) {
    Write-Host 'NEGATIVE CONTROL: the guard is advisory - this run MUST fail'
    Remove-Item Env:GHOZTTY_UPDATE_TARGET_ENFORCE -ErrorAction SilentlyContinue
} else {
    $env:GHOZTTY_UPDATE_TARGET_ENFORCE = '1'
}

$script:app = Start-OnTestDesktop -Exe $sandbox.Exe -Arguments @('--session-persistence=false') -StdErr $script:appLog
$script:appPid = $script:app.Pid
Assert (Wait-Log 'update staged for win-v9\.9\.9') 'the package was downloaded and staged'
$script:msgWnd = Find-TestMessageWindow -ProcessId $script:appPid
Assert ($script:msgWnd -ne [IntPtr]::Zero) "the app's message-only window was found"
Assert (Send-BalloonClick) 'the balloon click was delivered'
$consent = Wait-DialogTitled 'Update Ghoztty'
Assert ($consent -ne [IntPtr]::Zero) 'the click raised the "Update Ghoztty" consent dialog'
$btn = if ($consent -ne [IntPtr]::Zero) { Get-DialogButton $consent 'Install and Restart' } else { $null }
Assert ($null -ne $btn) 'it has an "Install and Restart" button'
if ($btn) { [void](Send-TestControlClick -Control ([IntPtr]$btn.Hwnd)) }

# ------------------------------------------- B: refused, and said in-window
Write-Host '== B: the arm is refused, and the app says why'
$dlg = Wait-DialogTitled $FAIL_TITLE 15000
Assert ($dlg -ne [IntPtr]::Zero) "a dialog titled '$FAIL_TITLE' appeared in the app (pid $script:appPid)"
$body = if ($dlg -ne [IntPtr]::Zero) { Get-DialogBody $dlg } else { '' }
Assert ($body -match 'still running the version') 'it says the terminal is untouched'
Assert ($body -match 'not the installed one') 'it says this copy is not the installed one'
Assert ($body -match 'download the new version from the Ghoztty releases page') 'it sends the user to the releases page'
Assert ($body -notmatch 'Try again') 'it does not suggest retrying, which cannot help'
Assert ($body -match '\(Error: NotTheInstalledCopy\)') 'it carries the error for a bug report'
$appLog = Get-AppLog
Assert ($appLog -match [regex]::Escape("package UpgradeCode $RELEASE_UPGRADE_CODE, ghoztty.exe component $RELEASE_EXE_COMPONENT")) 'the app read the identity out of the package'
if ($realDir) {
    Assert ($appLog -match ('update apply: REFUSED - the package''s product is registered at ' + [regex]::Escape($realDir) + ', not at this copy')) "the log names the real install ($realDir) as the folder msiexec would have acted on"
} else {
    Assert ($appLog -match 'update apply: REFUSED - no installed product carries this package''s UpgradeCode') 'the log says no product is installed'
}
$close = if ($dlg -ne [IntPtr]::Zero) { Get-DialogButton $dlg 'Close' } else { $null }

# ------------------------------------------- C: nothing armed, nothing lost
Write-Host '== C: nothing was armed and the terminal is still there'
Assert (-not $script:app.Process.HasExited) 'the app is still running'
Assert ($appLog -notmatch 'update apply: ARMED') 'no applier was armed'
Assert ($appLog -notmatch 'msiexec\.exe /i') 'msiexec was never invoked'
Assert ($appLog -notmatch 'applier armed, quitting to install') 'the app did not quit'
Assert (Test-Path $stagedMsi) 'the package is still staged'
if ($close) { [void](Send-TestControlClick -Control ([IntPtr]$close.Hwnd)) }
Assert (Wait-NoDialog) '"Close" dismissed the dialog'

# ------------------------------------------- D: the repo build survived
Write-Host '== D: the repo build is untouched'
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
    Remove-Item Env:GHOZTTY_UPDATE_TARGET_ENFORCE -ErrorAction SilentlyContinue
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
        update -Guard update-target-guard -Repo $repo 2>&1 |
        ForEach-Object { Write-Host "  $_" }
}

Write-TestVerdict -Pass $script:pass -Fail $script:fail
