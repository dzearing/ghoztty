# T1934 acceptance: a downloaded update installs ITSELF.
#
# The defect: every release was downloaded and none was installed, because the
# only route from a staged package to msiexec was a click on an offer shown once
# a day. The user sat on a September build for six weeks with 1.39.7 staged
# beside it. The timing rules (launch / idle / fullscreen / overdue /
# persistence off / retry backoff) are unit-tested in
# src\apprt\win32\update_auto_apply.zig; this script drives the parts that need
# a real app: that the app, with nobody clicking anything, arms the applier and
# exits, and that each hold actually holds.
#
# Every launch is a COPY of the build in a scratch install directory (the
# applier renames locked images aside, and must never be aimed at zig-out\bin),
# on the background test desktop, against a canned file:// feed and a fake
# package. msiexec is never run: GHOZTTY_UPDATE_MSI_CODE=0 is the Debug seam
# that makes the applier act on "msiexec succeeded" without running it, so the
# relaunch path is the success path. The real install is update-real-msi.ps1's.
#
# Debug builds never auto-install on their own (they are not the user's
# product); GHOZTTY_UPDATE_AUTO_APPLY=1 opts a run in. GHOZTTY_UPDATE_IDLE_MS
# and GHOZTTY_UPDATE_FULLSCREEN stand in for the session's input clock and
# notification state, which the test desktop shares with the user.
#
# Sections:
#   A  idle, persistence on: installs with no click, app exits, applier reopens it
#   B  NEGATIVE CONTROL: the same run with auto-update = check stays put
#   C  user active: waits
#   D  fullscreen in front: waits
#   E  persistence off: never installs silently in a running app
#   F  a launch with a package already staged installs before any window opens
#   G  a version already attempted today is not attempted again (no loop)
#   H  a new download prunes superseded packages; a launch keeps the pending one
#   I  a leftover applier still running its image does not block the arm (T2321)
# persistence: on for A, C, D (the shape the user runs); off for E and F, which
# are about exactly that.
param([string]$ExePath)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$env:GHOZTTY_NO_STARTUP_ESCAPE = '1'
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
# Its own LOCALAPPDATA and agent lineage: the offer record, the attempt record
# and the staging directory all start empty, and nothing here can touch the
# debug-lineage state other harnesses read.
[void](Set-GhozttyTestIsolation -Tag 't1934' -ReleaseSandbox)
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }
if (-not (Test-Path $exe)) { Write-Host "SETUP FAIL: $exe missing (zig build first)"; exit 1 }
Assert-GhozttyIsolatedBuild -Exe $exe | Out-Null

. (Join-Path $PSScriptRoot 'lib\ApplierSandbox.ps1')
trap { Restore-RepoBuild -ExePath $exe; break }

$td = New-TestDesktop

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

# ---------------------------------------------------------------- fixtures
$work = Join-Path $env:TEMP "ghoztty-t1934-$PID"
Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $work | Out-Null

$sandbox = New-ApplierSandbox -Exe $exe -Root $work
$appExe = $sandbox.Exe
# The agent beside it, so persistence is real: the applier's rename-aside is
# what lets msiexec replace an agent image that is still hosting sessions.
$agentSrc = Join-Path (Split-Path $exe -Parent) 'ghoztty-agent.exe'
if (Test-Path $agentSrc) { Copy-Item $agentSrc (Join-Path $sandbox.Dir 'ghoztty-agent.exe') -Force }

$staging = Join-Path $env:LOCALAPPDATA 'ghoztty\updates-debug'
$attemptFile = Join-Path $env:LOCALAPPDATA 'ghoztty\update-auto-apply-debug.txt'
$offerFile = Join-Path $env:LOCALAPPDATA 'ghoztty\update-offer-debug.txt'

$assetDir = Join-Path $work 'download\win-v9.9.9'
New-Item -ItemType Directory -Force $assetDir | Out-Null
function New-FakePackage([string]$path) {
    $bytes = New-Object byte[] 8192
    $magic = [byte[]](0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1)
    [Array]::Copy($magic, $bytes, 8)
    [IO.File]::WriteAllBytes($path, $bytes)
}
$msiPath = Join-Path $assetDir 'Ghoztty-9.9.9-x64.msi'
New-FakePackage $msiPath
$msiUrl = 'file:///' + ($msiPath -replace '\\', '/')
$feedPath = Join-Path $work 'feed.json'
[IO.File]::WriteAllText($feedPath, '[{"tag_name":"win-v9.9.9","assets":[{"browser_download_url":"' + $msiUrl + '"}]}]')
$feedUrl = 'file:///' + ($feedPath -replace '\\', '/')
$stagedMsi = Join-Path $staging 'Ghoztty-9.9.9-x64.msi'

function Reset-UpdateState {
    [void](Stop-ApplierSandbox -Sandbox $sandbox)
    foreach ($f in @($attemptFile, $offerFile, (Join-Path $env:LOCALAPPDATA 'ghoztty\update_check_at'))) {
        Remove-Item $f -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path $staging) { Remove-Item -Recurse -Force $staging -ErrorAction SilentlyContinue }
}

# One launch. Returns the app's stderr, whether it exited ON ITS OWN inside
# $watchSecs, and how many processes the sandbox held afterwards (the applier's
# relaunch is one of them).
function Invoke-Case {
    param(
        [string]$Label,
        [hashtable]$Env = @{},
        [string[]]$AppArgs = @(),
        [int]$WatchSecs = 20,
        [string]$Feed = $feedUrl
    )
    $errFile = Join-Path $work "$Label.err.txt"
    Remove-Item $errFile -ErrorAction SilentlyContinue
    $all = @{
        GHOZTTY_UPDATE_URL                = $Feed
        GHOZTTY_UPDATE_AUTO_APPLY         = '1'
        GHOZTTY_UPDATE_AUTO_APPLY_TICK_MS = '1000'
        GHOZTTY_UPDATE_MSI_CODE           = '0'
        GHOZTTY_UPDATE_FULLSCREEN         = '2'
        GHOZTTY_UPDATE_IDLE_MS            = '600000'
    }
    foreach ($k in $Env.Keys) { $all[$k] = $Env[$k] }
    $saved = @{}
    foreach ($k in $all.Keys) {
        $saved[$k] = [Environment]::GetEnvironmentVariable($k, 'Process')
        if ($null -eq $all[$k]) { [Environment]::SetEnvironmentVariable($k, $null, 'Process') }
        else { [Environment]::SetEnvironmentVariable($k, [string]$all[$k], 'Process') }
    }
    $exited = $false
    try {
        $app = Start-OnTestDesktop -Exe $appExe -Arguments $AppArgs -StdErr $errFile
        $exited = $app.Process.WaitForExit($WatchSecs * 1000)
        if (-not $exited) { try { $app.Process.Kill() } catch {} }
    } finally {
        foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k], 'Process') }
    }
    # The applier waits for the app, then relaunches it; give it the moment.
    if ($exited) { Start-Sleep -Seconds 4 }
    $left = [int](Stop-ApplierSandbox -Sandbox $sandbox)
    $log = if (Test-Path $errFile) { [IO.File]::ReadAllText($errFile) } else { '' }
    return [pscustomobject]@{ Log = $log; Exited = $exited; Left = $left }
}

$installed = 'installing win-v9\.9\.9 automatically'

# -- A. idle, persistence on: no click, the app installs and comes back -----
Reset-UpdateState
$a = Invoke-Case -Label 'idle' -AppArgs @('--session-persistence=true') -WatchSecs 40
Assert ($a.Log -match 'update staged for win-v9\.9\.9') 'idle: the package was staged in the background'
Assert ($a.Log -match "$installed \(idle; moment=tick") 'idle: an idle user with persistence on got the install without a click'
Assert ($a.Log -match 'update apply: ARMED') 'idle: the applier was armed'
Assert $a.Exited 'idle: the app closed itself for the install (nobody clicked anything)'
Assert ($a.Left -ge 1) "idle: the applier reopened the app afterwards ($($a.Left) sandbox process(es) found)"
Assert ((Test-Path $attemptFile) -and ((Get-Content $attemptFile -Raw) -match '^9\.9\.9\r?\n\d+')) 'idle: the attempt was recorded by version'

# -- B. NEGATIVE CONTROL: auto-update = check keeps the click ---------------
# The same facts with the product switch that keeps the old behavior. Nothing
# is staged under `check`, so stage it first with a run that has auto-install
# off, exactly the state the user's app was in for six weeks.
Reset-UpdateState
$pre = Invoke-Case -Label 'stage-only' -Env @{ GHOZTTY_UPDATE_AUTO_APPLY = $null } -AppArgs @('--session-persistence=true') -WatchSecs 10
Assert ((-not $pre.Exited) -and ($pre.Log -notmatch $installed)) 'stage-only: with auto-install off a staged update just sits there (the old behavior)'
Assert (Test-Path $stagedMsi) 'stage-only: the package is staged'
$b = Invoke-Case -Label 'check' -AppArgs @('--session-persistence=true', '--auto-update=check') -WatchSecs 12
Assert (-not $b.Exited) 'check: the app stayed up'
Assert ($b.Log -notmatch $installed) 'check: nothing installed itself under auto-update = check'
Assert ($b.Log -match 'restored pending update offer win-v9\.9\.9 .*staged=true') 'check: the launch sweep kept the package the pending offer names'
Assert (Test-Path $stagedMsi) 'check: the staged package survived the launch'

# -- C. the user is typing: wait -------------------------------------------
Reset-UpdateState
$c = Invoke-Case -Label 'active' -Env @{ GHOZTTY_UPDATE_IDLE_MS = '1' } -AppArgs @('--session-persistence=true') -WatchSecs 12
Assert (-not $c.Exited) 'active: the app stayed up'
Assert ($c.Log -match 'update auto-install \(tick\) waiting for win-v9\.9\.9: user_active') 'active: it said it is waiting for the user to step away'
Assert ($c.Log -notmatch $installed) 'active: nothing installed'

# -- D. something fullscreen in front: wait --------------------------------
Reset-UpdateState
$d = Invoke-Case -Label 'fullscreen' -Env @{ GHOZTTY_UPDATE_FULLSCREEN = '1' } -AppArgs @('--session-persistence=true') -WatchSecs 12
Assert (-not $d.Exited) 'fullscreen: the app stayed up'
Assert ($d.Log -match 'waiting for win-v9\.9\.9: fullscreen') 'fullscreen: it held off for the fullscreen app'
Assert ($d.Log -notmatch $installed) 'fullscreen: nothing installed over it'

# -- E. persistence off: never silently, in a running app -------------------
Reset-UpdateState
$e = Invoke-Case -Label 'nopersist' -AppArgs @('--session-persistence=false') -WatchSecs 12
Assert (-not $e.Exited) 'nopersist: the app stayed up'
Assert ($e.Log -match 'waiting for win-v9\.9\.9: persistence_off') 'nopersist: it refused to close shells it cannot keep'
Assert ($e.Log -notmatch $installed) 'nopersist: nothing installed'

# -- F. launch with a package already staged: install before any window -----
# Persistence OFF on purpose: at launch there is no shell to lose either way.
# The user is "typing" too - no window of ours is up to type in.
Reset-UpdateState
[void](Invoke-Case -Label 'stage-only2' -Env @{ GHOZTTY_UPDATE_AUTO_APPLY = $null } -AppArgs @('--session-persistence=false') -WatchSecs 10)
$f = Invoke-Case -Label 'launch' -Env @{ GHOZTTY_UPDATE_IDLE_MS = '1'; GHOZTTY_UPDATE_URL = $null } -AppArgs @('--session-persistence=false') -WatchSecs 20
Assert ($f.Log -match "$installed \(launch; moment=launch") 'launch: the staged package installed at launch'
Assert ($f.Log -notmatch 'update available') 'launch: before the network check had even gone out'
Assert $f.Exited 'launch: the process ended for the install'
Assert ($f.Left -ge 1) "launch: and was reopened ($($f.Left) sandbox process(es) found)"

# -- G. the same version is not attempted twice in a day -------------------
# After F the attempt record holds 9.9.9. Stage it again (the applier's success
# seam deleted it) and launch: a package msiexec keeps rejecting must not turn
# every launch into an install-and-reopen loop.
Assert ((Test-Path $attemptFile)) 'retry: the launch attempt was recorded'
[void](Invoke-Case -Label 'stage-only3' -Env @{ GHOZTTY_UPDATE_AUTO_APPLY = $null } -AppArgs @('--session-persistence=true') -WatchSecs 10)
$g = Invoke-Case -Label 'retry' -AppArgs @('--session-persistence=true') -WatchSecs 12
Assert (-not $g.Exited) 'retry: the app stayed up'
Assert ($g.Log -match 'waiting for win-v9\.9\.9: retry_backoff') 'retry: it held the second attempt off'
Assert ($g.Log -notmatch $installed) 'retry: nothing installed twice'

# -- H. a newer download prunes the package it supersedes -----------------
# The shape the user's box was in: an older release still pending and staged
# (the launch sweep keeps it, since the offer names it), then a newer one
# arrives. Before T1934 every one of them stayed - 800 MB back to 1.36.37.
Reset-UpdateState
New-Item -ItemType Directory -Force $staging | Out-Null
$older = Join-Path $staging 'Ghoztty-1.39.6-x64.msi'
New-FakePackage $older
$nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
[IO.File]::WriteAllText($offerFile, "version=1.39.6`nfirst_offered_ms=$nowMs`nstaged=$older`n")
$h = Invoke-Case -Label 'prune' -Env @{ GHOZTTY_UPDATE_AUTO_APPLY = $null } -AppArgs @('--session-persistence=true') -WatchSecs 10
$msis = @(Get-ChildItem $staging -Filter *.msi -ErrorAction SilentlyContinue | ForEach-Object Name)
Assert ($h.Log -match 'restored pending update offer win-v1\.39\.6 .*staged=true') 'prune: the older pending package survived the launch sweep'
Assert ($h.Log -match 'pruned superseded package Ghoztty-1\.39\.6-x64\.msi') 'prune: the newer download said what it pruned'
Assert (($msis.Count -eq 1) -and ($msis[0] -eq 'Ghoztty-9.9.9-x64.msi')) "prune: only the newest package is left ($($msis -join ', '))"

# -- I. a leftover applier still running does not block the next install ---
# T2321, the user's 2026-10-26 day: an applier from a failed install never
# exited, so ghoztty-updater.exe stayed a RUNNING image, and every later arm
# (four automatic, two clicks) logged `NOT armed err=error.AccessDenied` while
# the click did nothing. Reproduce the leftover for real: a copy of the build
# running from that exact path, as an applier parked on a live pid. The arm
# must take the per-pid fallback name rather than give up - and the
# 'could not be replaced' line is this run's proof that the usual path really
# was blocked, i.e. that the old code would have refused here.
Reset-UpdateState
New-Item -ItemType Directory -Force $staging | Out-Null
$leftoverExe = Join-Path $staging 'ghoztty-updater.exe'
Copy-Item $exe $leftoverExe -Force
$parkOn = Start-Process -FilePath 'ping.exe' -ArgumentList '-n', '600', '127.0.0.1' -WindowStyle Hidden -PassThru
$leftoverMsi = Join-Path $work 'leftover.msi'
New-FakePackage $leftoverMsi
$savedApply = $env:GHOZTTY_UPDATE_APPLY
$savedCode = $env:GHOZTTY_UPDATE_MSI_CODE
# The spec's target is the sandbox copy ($appExe), never the repo build; and
# the success seam means the leftover never runs msiexec even if it got there.
$env:GHOZTTY_UPDATE_APPLY = "$($parkOn.Id)|$leftoverMsi|$($sandbox.Exe)"
$env:GHOZTTY_UPDATE_MSI_CODE = '0'
try {
    $leftover = Start-OnTestDesktop -Exe $leftoverExe -StdErr (Join-Path $work 'leftover-applier.err.txt')
} finally {
    Remove-Item env:GHOZTTY_UPDATE_APPLY -ErrorAction SilentlyContinue
    if ($savedApply) { $env:GHOZTTY_UPDATE_APPLY = $savedApply }
    [Environment]::SetEnvironmentVariable('GHOZTTY_UPDATE_MSI_CODE', $savedCode, 'Process')
}
Start-Sleep -Milliseconds 1500
$leftoverAlive = $false
try { $leftoverAlive = -not ([System.Diagnostics.Process]::GetProcessById($leftover.Pid).HasExited) } catch {}
Assert $leftoverAlive 'leftover: a leftover applier is running out of ghoztty-updater.exe'
$i = $null
try {
    $i = Invoke-Case -Label 'leftover' -AppArgs @('--session-persistence=true') -WatchSecs 40
} finally {
    # Its own pid, never by name: the user's installed release may have a real one.
    try { Stop-Process -Id $leftover.Pid -Force -ErrorAction Stop } catch {}
    try { Stop-Process -Id $parkOn.Id -Force -ErrorAction Stop } catch {}
}
Assert ($i.Log -notmatch 'NOT armed') 'leftover: the arm was not refused (before T2321: NOT armed err=error.AccessDenied)'
Assert ($i.Log -match 'ghoztty-updater\.exe could not be replaced .*arming .*ghoztty-updater-\d+\.exe instead') 'leftover: the usual applier path really was blocked, and the arm took the per-pid copy'
Assert ($i.Log -match 'update apply: ARMED') 'leftover: the applier was armed anyway'
Assert $i.Exited 'leftover: the app closed for the install'
Assert ($i.Left -ge 1) "leftover: and the applier reopened it ($($i.Left) sandbox process(es) found)"

Reset-UpdateState
[void](Stop-ApplierSandbox -Sandbox $sandbox)
$strays = @(Get-SidelinedBuild -ExePath $exe)
Assert ((Test-Path $exe) -and $strays.Count -eq 0) 'harness: the repo build is exactly where it was'
Restore-RepoBuild -ExePath $exe
Remove-TestDesktop | Out-Null
Write-Host ''
if ($script:fail -eq 0) { Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue }
else { Write-Host "logs kept in $work" }

Complete-TestBody

# --- stamp (T783) ----------------------------------------------------------
if ($script:fail -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot '..\..\scripts\guard-due.ps1') `
        update -Guard update-auto-apply -Repo $repo 2>&1 |
        ForEach-Object { Write-Host "  $_" }
}

Write-TestVerdict -Pass $script:pass -Fail $script:fail
