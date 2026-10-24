# T1194 acceptance: the in-app update, all the way through msiexec SUCCEEDING.
#
# T1178's harness (test\win32\update-apply.ps1) drives the whole update path
# against canned feeds and a canned "package", and stops one inch short on
# purpose: it runs msiexec against a package msiexec REJECTS, because a real
# install would replace the user's Ghoztty. So "the new version is actually on
# disk afterwards" was the one claim nothing could make.
#
# This closes it, with two REAL published releases and no rebuild:
#
#   * `scripts\msi-test-identity.ps1` rewrites each published
#     `Ghoztty-<v>-x64.msi` into a throwaway product - its own ProductCode,
#     UpgradeCode, install directory, component GUIDs, registry key and Start
#     Menu name. The payload, the sequences and the custom actions are the
#     published ones; only the identity moves. Installing it therefore lands
#     in %LOCALAPPDATA%\Programs\GhozttyT1194Test and cannot upgrade, remove
#     or refcount anything belonging to the user's Ghoztty.
#   * The older release is installed for real. The app is then pointed at a
#     canned feed offering the newer release, and downloads and stages it the
#     way it would from GitHub. The applier is armed exactly as `arm()` arms
#     it - a copy of the exe in the staging directory, the spec in
#     GHOZTTY_UPDATE_APPLY - and msiexec is expected to exit 0.
#
# What is deliberately NOT driven here: the tray balloon click and the "Install
# and Restart" confirmation. Those are two mouse events in front of
# `applyStagedUpdate`, and update-apply.ps1 already covers the shape on the
# other side of them. Everything from the staged package onward is real.
#
# Sections:
#   A  packages: the published MSIs, rewritten to a throwaway identity
#   B  install the older release for real (msiexec exit 0)
#   C  the app finds the newer release and stages its package
#   D  the applier installs it (msiexec exit 0) and the version moves
#   E  nothing is left behind, and the user's Ghoztty was never touched
# preflight: none - the binaries here come out of a PUBLISHED MSI, so they are
# release builds by definition and `Assert-GhozttyIsolatedBuild` would refuse
# them. The isolation is bought a different way: `-ReleaseSandbox` below gives
# the run its own pipe, its own agent lineage and its own LOCALAPPDATA, and the
# product itself is a throwaway identity installed in its own directory, which
# section E measures against the user's install on every run.
# persistence: on (default) for every launch here - `-ReleaseSandbox` gives the
# run its own LOCALAPPDATA, so the first launch has nothing to restore and the
# post-update launch picks up only what this run itself recorded, which is also
# the shape a real user's update walks.
param(
    [string]$Identity = 'GhozttyT1194Test',
    [string]$OldTag = 'win-v1.35.0',
    [string]$NewTag = 'win-v1.36.0',
    [switch]$KeepInstall,
    # Negative control for section C (T1269): offer an "MSI" that is not one.
    # The app's download refuses it, and C must report that as the failure it
    # is, early, instead of waiting out the whole poll. D and E skip, so a run
    # under this switch never stamps the guard.
    [switch]$BreakDownload,
    # Negative control for section E (T1303): plant a sidelined image the
    # sweep cannot delete (held open without FILE_SHARE_DELETE) right before
    # the next launch. E must then pass "the sweep ran" and FAIL "swept
    # everything", naming the planted file - a real leak and a slow launch are
    # two different verdicts. The run fails, so it never stamps the guard.
    [switch]$PlantLeak
)
$ErrorActionPreference = 'Stop'

# The install directory is chosen by Windows Installer from the SHELL's idea of
# LocalAppData, which -ReleaseSandbox below is about to move out from under
# $env:LOCALAPPDATA. Capture the real one FIRST or every path assertion in this
# file points at the sandbox and passes while measuring nothing.
$realLocalAppData = $env:LOCALAPPDATA

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$env:GHOZTTY_NO_STARTUP_ESCAPE = '1'
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
# Every launch here goes to a background desktop (T1269): the installed
# terminal, the applier and the terminal the applier relaunches all open
# windows, and none of them may land on the user's screen.
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
# The throwaway product identity, its packages and its processes - shared with
# test\win32\update-graceful.ps1, which drives the same machinery through the
# graceful close-and-reopen this harness stubs out.
. (Join-Path $PSScriptRoot 'lib\ThrowawayProduct.ps1')
# The registered-ProductVersion decode D reads (T2168).
. (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'scripts\lib\ArpVersion.ps1')
# -ReleaseSandbox, not a bare suffix: everything this script launches is a
# RELEASE build (it is a published package), so without the sandbox it would
# dial the agent that owns the user's live sessions and stage its package into
# the user's own updates directory.
[void](Set-GhozttyTestIsolation -Tag 't1194' -ReleaseSandbox)

$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$work = Join-Path $env:TEMP 'ghoztty-t1194'
New-Item -ItemType Directory -Force $work | Out-Null

$oldVer = $OldTag -replace '^win-v', ''
$newVer = $NewTag -replace '^win-v', ''
$installDir = Get-ThrowawayInstallDir -RealLocalAppData $realLocalAppData -Identity $Identity
$userInstallDir = Get-ThrowawayUserInstallDir -RealLocalAppData $realLocalAppData
$stagingDir = Join-Path $env:LOCALAPPDATA 'ghoztty\updates'

$script:pass = 0
$script:fail = 0
$script:skip = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}
function Skip([string]$label) { $script:skip++; Write-Host "SKIP  $label" -ForegroundColor Yellow }

$pathBefore = Get-UserPathEntryCount
$userInstallBefore = if (Test-Path $userInstallDir) {
    @(Get-ChildItem $userInstallDir -Recurse -File -ErrorAction SilentlyContinue).Count
} else { -1 }
$userExeVersionBefore = if (Test-Path (Join-Path $userInstallDir 'ghoztty.exe')) {
    (Get-Item (Join-Path $userInstallDir 'ghoztty.exe')).LastWriteTimeUtc.Ticks
} else { 0 }

try {

# =========================================================== A. packages
Write-Host "`n-- A. throwaway packages from the published releases --"

$msiOld = Get-ThrowawayPackage -Tag $OldTag -Version $oldVer -Work $work -Identity $Identity -Repo $repo
$msiNew = Get-ThrowawayPackage -Tag $NewTag -Version $newVer -Work $work -Identity $Identity -Repo $repo

if (-not $msiOld -or -not $msiNew) {
    # No network, or no `gh`. The published package IS the subject of this
    # harness, so there is nothing to substitute - say so and stop, rather
    # than reporting green over a test that never ran.
    Skip "A: could not obtain both published packages ($OldTag, $NewTag)"
    Write-Host "`nSKIPPED (no published packages available)"
    exit 0
}
Assert (Test-Path $msiOld) "A: $OldTag rewritten to the $Identity identity"
Assert (Test-Path $msiNew) "A: $NewTag rewritten to the $Identity identity"

# The two packages must share ONE UpgradeCode, or the newer one installs
# beside the older instead of replacing it - which would pass every version
# check below while testing the opposite of an upgrade.

$upOld = Get-MsiProperty -Msi $msiOld -Name 'UpgradeCode'
$upNew = Get-MsiProperty -Msi $msiNew -Name 'UpgradeCode'
Assert ($upOld -eq $upNew -and $upOld -ne '') 'A: both packages share one throwaway UpgradeCode'
Assert ($upOld -ne '{5EB02044-7F06-498B-B7A9-7EFD65486CFB}') "A: that UpgradeCode is NOT the shipping product's"
Assert ((Get-MsiProperty -Msi $msiOld -Name 'ProductName') -eq $Identity) 'A: the older package is the throwaway product'

# ================================================ B. install the old release
Write-Host "`n-- B. install $OldTag for real --"
Stop-ThrowawayInstances -InstallDir $installDir -RealLocalAppData $realLocalAppData
Remove-ThrowawayProduct -Identity $Identity -InstallDir $installDir -RealLocalAppData $realLocalAppData

$installLog = Join-Path $work 'install-old.log'
# LAUNCHAPP=0 so a successful install does not open a terminal window on the
# user's desktop; /qn because nobody is watching this one.
$p = Start-Process msiexec.exe -ArgumentList @('/i', "`"$msiOld`"", '/qn', '/norestart',
    'LAUNCHAPP=0', '/l*v', "`"$installLog`"") -Wait -PassThru
$null = $p.Handle
Assert ($p.ExitCode -eq 0) "B: msiexec installed $OldTag (exit $($p.ExitCode))"

$testExe = Join-Path $installDir 'ghoztty.exe'
Assert (Test-Path $testExe) "B: ghoztty.exe is in $installDir"
Assert (Test-Path (Join-Path $installDir 'ghoztty-agent.exe')) 'B: the agent came with it'
$verInstalled = Get-ThrowawayExeVersion -Exe $testExe
Assert ($verInstalled -eq $oldVer) "B: it reports $oldVer (got '$verInstalled')"
Assert ((@(Get-ThrowawayUninstallEntries -Identity $Identity)).Count -ge 1) 'B: it registered as its own product in Apps & Features'

# ============================================ C. the app stages the update
Write-Host "`n-- C. the app finds $NewTag and stages its package --"
$td = New-TestDesktop

# The asset URL must sit under /download/<tag>/ - that is how the scanner
# proves an asset belongs to the release it is offering - so the package is
# published locally under a directory tree of exactly that shape.
$assetDir = Join-Path $work "download\$NewTag"
New-Item -ItemType Directory -Force $assetDir | Out-Null
$assetMsi = Join-Path $assetDir "Ghoztty-$newVer-x64.msi"
if ($BreakDownload) {
    [IO.File]::WriteAllText($assetMsi, 'not an msi package (T1269 negative control)')
} else {
    Copy-Item $msiNew $assetMsi -Force
}
$assetUrl = 'file:///' + ($assetMsi -replace '\\', '/')
$feedPath = Join-Path $work 'feed.json'
[IO.File]::WriteAllText($feedPath,
    '[{"tag_name":"v1.0.0","assets":[]},' +
    '{"tag_name":"' + $NewTag + '","assets":[{"browser_download_url":"' + $assetUrl + '"}]}]')
$feedUrl = 'file:///' + ($feedPath -replace '\\', '/')

if (Test-Path $stagingDir) { Remove-Item $stagingDir -Recurse -Force -ErrorAction SilentlyContinue }

# The poll used to be a flat 120s that knew nothing about the app, so a box
# busy with a floor run read as "the app never staged the package" and the
# failure could not say why (T1269, red once on 2026-09-01 and 30/30 on the
# re-run). A released build is GUI-subsystem but still writes its log to the
# redirected stderr below, and the update path names every step there. So the
# poll reads the app's own account: a step that means nothing will ever be
# staged ends it at once, and a log or staging directory that is still moving
# keeps it waiting past the base deadline, up to a hard cap.
#
# Terminal lines: after a failed pre-download every later tick answers
# "already offered; not re-notifying" (App.zig, T1171), and a feed that offers
# nothing never will. A failed CHECK is not terminal - the recheck below runs
# it again.
function Get-StageLogVerdict([string]$Text) {
    $terminal = @(
        'update (pre-)?download failed[^\r\n]*',
        'update download: [^\r\n]*is not an MSI package[^\r\n]*',
        'update check[^\r\n]*: no win-v release found[^\r\n]*',
        'update check[^\r\n]*: up to date[^\r\n]*'
    )
    foreach ($re in $terminal) {
        $m = [regex]::Match($Text, $re)
        if ($m.Success) { return "failed: $($m.Value)" }
    }
    if ($Text -match 'update download: staged ') { return 'staged' }
    if ($Text -match 'update available') { return 'offered' }
    return 'checking'
}

# The reader's control: each verdict it can return, from lines the real app
# writes (the "(automatic)" form is today's, the bare form is the 1.35.0
# release this section actually launches).
Assert ((Get-StageLogVerdict "info(win32): update available: current=1.35.0 latest=win-v1.36.0`r`n") -eq 'offered') 'C: the poll reads an offered update as still in progress (control)'
Assert ((Get-StageLogVerdict "info(win32_update_install): update download: staged 41451008 bytes at x`r`n") -eq 'staged') 'C: the poll reads a staged package as staged (control)'
Assert ((Get-StageLogVerdict "warning(win32): update pre-download failed: error.HttpFailed`r`ninfo: next`r`n") -eq 'failed: update pre-download failed: error.HttpFailed') 'C: the poll ends at once on a failed download, naming it (control)'
Assert ((Get-StageLogVerdict "warning(win32_update_install): update download: 44 bytes from file:///x is not an MSI package`n").StartsWith('failed: ')) 'C: the poll ends at once on a package that is not an MSI (control)'
Assert ((Get-StageLogVerdict "info(win32): update check (automatic): up to date (current=1.36.0 latest=win-v1.36.0)`n").StartsWith('failed: ')) 'C: the poll ends at once when the app says it is up to date (control)'
Assert ((Get-StageLogVerdict "warning(win32): update check (automatic) failed: error.Timeout`n") -eq 'checking') 'C: a failed CHECK keeps the poll waiting for the recheck (control)'

# Read what the app has written so far without disturbing its handle.
function Read-AppLog([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    try {
        $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
        try { return (New-Object IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() }
    } catch { return '' }
}

$env:GHOZTTY_UPDATE_URL = $feedUrl
# The check re-runs on a timer, and this is the knob update-check.ps1 already
# uses to watch a second tick. Without it the harness gets exactly one attempt
# at startup and a slow launch reads as "the app never offered the update" -
# which it did, once, on a box busy with the rest of a floor run.
$env:GHOZTTY_UPDATE_RECHECK_MS = '10000'
$app = $null
try {
    # T689: the installed build's own stderr. This launch is the one expected
    # to find and stage the update, so when it does not, its log is the only
    # record of how far it got.
    $appLog = Join-Path $work 'app-update.err.txt'
    Remove-Item $appLog -Force -ErrorAction SilentlyContinue
    # -AllowReleaseBuild: the subject is a published build, and the launch gate
    # checks the -ReleaseSandbox above rather than taking this on trust.
    $app = Start-OnTestDesktop -Exe $testExe -Arguments @() -StdErr $appLog -AllowReleaseBuild
    $appProc = $app.Process
    # The check runs in the background at startup and the download follows it;
    # poll for the staged package rather than guessing a sleep, and follow the
    # app's log while doing it (above). Base deadline 120s; any movement - log
    # growth, staging bytes - buys another 120s from that moment; 360s is the
    # cap however busy the box is.
    $staged = $null
    $verdict = 'checking'
    $stopReason = ''
    $started = Get-Date
    $lastMove = $started
    $lastSig = ''
    while ($true) {
        Start-Sleep -Seconds 1
        $logText = Read-AppLog $appLog
        $verdict = Get-StageLogVerdict $logText
        # The download creates the .msi and THEN writes 40 MB into it
        # (update_install.download), so the file appearing is not the package
        # being staged; the app's own "staged" line is.
        if ($verdict -eq 'staged' -and (Test-Path $stagingDir)) {
            $hit = @(Get-ChildItem $stagingDir -Filter '*.msi' -File -ErrorAction SilentlyContinue)
            if ($hit.Count -gt 0) { $staged = $hit[0].FullName; break }
        }
        if ($verdict.StartsWith('failed: ')) { $stopReason = "the app reported $($verdict.Substring(8))"; break }
        if ($appProc -and $appProc.HasExited) { $stopReason = 'the app exited before staging anything'; break }
        $stagingBytes = 0
        foreach ($f in @(Get-ChildItem $stagingDir -File -ErrorAction SilentlyContinue)) { $stagingBytes += $f.Length }
        $sig = "$($logText.Length)/$stagingBytes"
        $now = Get-Date
        if ($sig -ne $lastSig) { $lastSig = $sig; $lastMove = $now }
        $elapsed = ($now - $started).TotalSeconds
        if ($elapsed -ge 360) { $stopReason = 'the 360s cap ran out while the app was still moving'; break }
        if ($elapsed -ge 120 -and ($now - $lastMove).TotalSeconds -ge 120) {
            $stopReason = "nothing moved for 120s (last verdict: $verdict)"; break
        }
    }
    $waited = [int]((Get-Date) - $started).TotalSeconds
} finally {
    Remove-Item Env:GHOZTTY_UPDATE_URL -ErrorAction SilentlyContinue
    Remove-Item Env:GHOZTTY_UPDATE_RECHECK_MS -ErrorAction SilentlyContinue
}

if ($BreakDownload) {
    # The negative control: a refused package must END the poll, named, well
    # before the base deadline - not read as a slow box.
    Assert ($null -eq $staged) 'C: a package that is not an MSI was not staged (negative control)'
    Assert ($stopReason -like 'the app reported*') "C: the poll stopped on the app's own failure line ($stopReason)"
    Assert ($waited -lt 90) "C: and stopped early instead of waiting out the poll (${waited}s)"
} else {
    Assert ($null -ne $staged) "C: the app downloaded and staged a package into $stagingDir$(if (-not $staged) { " - $stopReason after ${waited}s" })"
}
if (-not $staged) {
    # Whatever stopped the poll, the app's own account of how far it got is
    # the evidence a red run needs.
    Write-Host "  app log tail ($appLog):" -ForegroundColor Yellow
    foreach ($l in @((Read-AppLog $appLog) -split "`r?`n" | Where-Object { $_ } | Select-Object -Last 12)) { Write-Host "    $l" }
}
if ($staged) {
    Assert ((Get-Item $staged).Length -eq (Get-Item $msiNew).Length) 'C: the staged bytes are the package it was offered'
    Assert ($staged -like "*$newVer*") "C: it staged the $newVer package"
}

# The applier refuses to install while the app it must replace is running, and
# it is right to. Close the APP the way a real update does - and deliberately
# leave the agent and its per-session pty-host holders running, because those
# outliving the terminal is the whole feature the rename-aside design protects.
$holdersBefore = @(Get-ThrowawayProcesses -InstallDir $installDir -Names @('ghoztty-agent'))
Stop-ThrowawayInstances -InstallDir $installDir -RealLocalAppData $realLocalAppData -AppOnly

# =============================================== D. the applier installs it
Write-Host "`n-- D. the applier runs msiexec and the version moves --"

if (-not $staged) {
    Skip 'D: nothing was staged to install'
} else {
    # Exactly the shape `arm()` produces: a COPY of the exe in the staging
    # directory (an applier running out of the directory it clears would
    # rename its own image aside), and the spec in the environment. The pid it
    # waits on has already exited, so the wait is satisfied at once.
    $applier = Join-Path $stagingDir 'ghoztty-updater.exe'
    Copy-Item $testExe $applier -Force
    $dead = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', 'exit' -PassThru -WindowStyle Hidden
    $null = $dead.Handle
    [void]$dead.WaitForExit(10000)

    $env:GHOZTTY_UPDATE_APPLY = "$($dead.Id)|$staged|$testExe"
    try {
        # The applier relaunches the terminal, and that child inherits the
        # applier's desktop - so this one launch keeps both off the user's.
        $ap = (Start-OnTestDesktop -Exe $applier -Arguments @()).Process
        $exited = $ap.WaitForExit(300000)
    } finally {
        Remove-Item Env:GHOZTTY_UPDATE_APPLY -ErrorAction SilentlyContinue
    }
    if (-not $exited) { try { $ap.Kill() } catch {} }

    Assert $exited 'D: the applier finished instead of hanging'
    # THE claim this harness exists to make. The applier returns 0 only when
    # msiexec returned 0 (or 3010) AND the terminal came back.
    Assert ($ap.ExitCode -eq 0) "D: msiexec SUCCEEDED and the terminal relaunched (applier exit $($ap.ExitCode))"

    # msiexec's own verbose log lands beside the package. It is often gone by
    # the time this reads: the applier RELAUNCHES the terminal, and a launching
    # app sweeps its staging directory (App.zig, `update_install.sweep`). Both
    # outcomes are evidence - one of msiexec's verdict, the other of the sweep
    # that clears the directory after an update - so both are checked, and
    # neither is allowed to be "the file is simply missing".
    $msiLog = Join-Path $stagingDir 'install.log'
    if (Test-Path $msiLog) {
        $logText = [IO.File]::ReadAllText($msiLog)
        Assert ($logText -match 'success or error status: 0') 'D: msiexec''s own log records success'
    } else {
        $pkgLeft = @(Get-ChildItem $stagingDir -Filter '*.msi' -File -ErrorAction SilentlyContinue)
        Assert ($pkgLeft.Count -eq 0) "D: the relaunched app already swept the package and the log ($($pkgLeft.Count) left)"
    }

    # The claim the rename-aside design exists to make: a session's holder
    # keeps running the image it already mapped, so the shells behind the
    # user's panes are still there after the installer replaced the files
    # underneath them. Nothing else in the suite can observe this - it needs a
    # real msiexec run over real running holders.
    if ($holdersBefore.Count -eq 0) {
        Skip 'D: no agent/holder was running to carry through the update'
    } else {
        $survived = 0
        foreach ($h in $holdersBefore) {
            if (-not $h.HasExited) { $survived++ }
        }
        Assert ($survived -eq $holdersBefore.Count) `
            "D: every session holder survived the install ($survived of $($holdersBefore.Count))"
    }

    # The relaunch is a real terminal and it belongs to this harness now.
    Stop-ThrowawayInstances -InstallDir $installDir -RealLocalAppData $realLocalAppData

    $verAfter = Get-ThrowawayExeVersion -Exe $testExe
    Assert ($verAfter -eq $newVer) "D: the installed build now reports $newVer (got '$verAfter')"

    $entries = @(Get-ThrowawayUninstallEntries -Identity $Identity)
    Assert ($entries.Count -eq 1) "D: still ONE product in Apps & Features (an upgrade, not a second install) - found $($entries.Count)"
    # The check is that the REGISTERED product moved from the old package's
    # ProductVersion (yy.m.dNN) to the new one's. Anything else means the
    # update installed beside the old product rather than over it. Read from
    # the registration's Version DWORD, never DisplayVersion: since T2168 the
    # entry a person sees shows the release number, which is not the number
    # upgrades are decided on, and the DWORD lives on Windows' own (hidden)
    # registration.
    $registered = ''
    foreach ($e in @(Get-ThrowawayUninstallEntries -Identity $Identity -IncludeHidden)) {
        $p = Get-ItemProperty $e.PSPath -ErrorAction SilentlyContinue
        if ($p -and $null -ne $p.Version) { $registered = ConvertFrom-ArpVersionDword -Value $p.Version; break }
    }
    $prodOld = Get-MsiProperty -Msi $msiOld -Name 'ProductVersion'
    $prodNew = Get-MsiProperty -Msi $msiNew -Name 'ProductVersion'
    Assert ($prodOld -ne $prodNew) "D: the two packages have different ProductVersions ($prodOld / $prodNew)"
    Assert (Test-ArpVersionEqual $registered $prodNew) "D: the registered product is now $prodNew, was $prodOld (got '$registered')"
}

# ================================================= E. nothing left behind
Write-Host "`n-- E. nothing left behind, nothing of the user's touched --"

if ($staged) {
    Assert (-not (Test-Path $staged)) 'E: the staged package was deleted after a successful install'
} else {
    Skip 'E: nothing was staged, so there is nothing to have been cleaned up'
}
# A holder that survived the install is still running the OLD agent image, and
# the installer got it out of msiexec's way by renaming it rather than killing
# the process - so a `.old-<stamp>` file here is the expected state, not a
# leak. What the task asks is that it does not OUTLIVE the holders.
$sidelined = @(Get-ChildItem $installDir -Filter '*.old-*' -File -Recurse -ErrorAction SilentlyContinue)
if (-not $staged) {
    Skip 'E: nothing was installed, so nothing could have been renamed aside'
} elseif ($holdersBefore.Count -gt 0) {
    Assert ($sidelined.Count -ge 1) 'E: the old agent image was renamed aside rather than the holder killed'
} else {
    Assert ($sidelined.Count -eq 0) "E: nothing was sidelined when no holder was running ($($sidelined.Count))"
}

# Two things survive the update's own sweep by design, both because they were
# in use at the time: the applier's copy of the exe (it was running the sweep's
# sibling) and any sidelined image a holder still had mapped. "Still in use is
# the normal answer... the next launch tries again" (update_install.sweep).
# The holders are stopped by now, so this launch is that next one - and it is
# the only thing that can prove the leftovers are temporary rather than
# permanent.
#
# That launch sweeps ONCE, at startup, so polling after it re-reads a directory
# nothing will touch again: whatever still held a leftover at the instant it
# started stays there for good (T1248). The applier has exited by now (D waited
# on its pid), but "exited" is not "released" - 2 of 4 runs on 2026-09-01 found
# ghoztty-updater.exe still in place and passed on an immediate re-run. So wait
# until nothing holds any leftover BEFORE launching. An exclusive read-write
# open fails while any handle is open or the file is still mapped as an image,
# and it changes nothing on disk, so the sweep is still the only thing that can
# delete it.
function Get-HeldFiles([string[]]$Paths) {
    $held = @()
    foreach ($p in $Paths) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        try {
            $fs = [IO.File]::Open($p, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            $fs.Dispose()
        } catch { $held += (Split-Path $p -Leaf) }
    }
    # A joined string, not an array: an empty array returned from a function
    # does not survive the trip back intact.
    return ($held -join ', ')
}

# The probe's own control: a file this script holds open must read as held, or
# a probe that can only ever say "released" would make the wait a no-op.
$probeFile = Join-Path $work 't1248-probe.bin'
[IO.File]::WriteAllBytes($probeFile, [byte[]](1, 2, 3))
$probeLock = [IO.File]::Open($probeFile, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
try {
    Assert ((Get-HeldFiles @($probeFile)) -eq 't1248-probe.bin') 'E: the release probe reads a file that is still open as held (control)'
} finally { $probeLock.Dispose() }
Assert ((Get-HeldFiles @($probeFile)) -eq '') 'E: the release probe reads the same file as released once it is closed (control)'
Remove-Item $probeFile -Force -ErrorAction SilentlyContinue

$leftovers = @()
foreach ($f in @(Get-ChildItem $stagingDir -File -ErrorAction SilentlyContinue)) { $leftovers += $f.FullName }
foreach ($f in @(Get-ChildItem $installDir -Filter '*.old-*' -File -Recurse -ErrorAction SilentlyContinue)) { $leftovers += $f.FullName }
$stillHeld = Get-HeldFiles $leftovers
$heldDeadline = (Get-Date).AddSeconds(60)
while ($stillHeld -and (Get-Date) -lt $heldDeadline) {
    Start-Sleep -Milliseconds 250
    $stillHeld = Get-HeldFiles $leftovers
}
if ($stillHeld) { Write-Host "  note: still held 60s after every holder exited: $stillHeld" -ForegroundColor Yellow }

# This launch is judged on what it SWEEPS, so it must not stage anything new:
# with no feed set it asks GitHub, finds a newer release and starts a 40 MB
# download into the very directory being checked for emptiness (seen in
# T1269's runs). A feed that offers no win-v release answers that question
# with "nothing to offer".
$leakLock = $null
if ($PlantLeak) {
    $leakFile = Join-Path $installDir 'ghoztty-agent.exe.old-1303'
    [IO.File]::WriteAllBytes($leakFile, [byte[]](1, 2, 3))
    $leakLock = [IO.File]::Open($leakFile, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
}
$emptyFeed = Join-Path $work 'feed-empty.json'
[IO.File]::WriteAllText($emptyFeed, '[{"tag_name":"v1.0.0","assets":[]}]')
$env:GHOZTTY_UPDATE_URL = 'file:///' + ($emptyFeed -replace '\\', '/')
try {
    $again = Start-OnTestDesktop -Exe $testExe -Arguments @() -StdErr (Join-Path $work 'app-sweep.err.txt') -AllowReleaseBuild   # T689
} finally {
    Remove-Item Env:GHOZTTY_UPDATE_URL -ErrorAction SilentlyContinue
}
# Judge the sweep once it has RUN, not after a fixed window (T1303). A flat 30s
# went red on a loaded box and green solo minutes later over the same code, so
# "a real leak" and "a slow launch" read identically. The sweep runs on the GUI
# thread inside App.init, before `run` creates the first window
# (`update_install.sweep`, App.zig), so a window answering `+list --json` is
# proof that it has finished - and the directories can be read once, as its
# verdict. Same load-aware shape as C: base 60s, any sign of life (stderr
# growth) buys another 60s, 240s cap.
function Get-AppWindowCount([string]$Exe) {
    $com = [IO.Path]::ChangeExtension($Exe, '.com')
    $bin = if (Test-Path $com) { $com } else { $Exe }
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $raw = & $bin +list --json 2>&1 | ForEach-Object { $_.ToString() } | Out-String } catch { $raw = "$_" } finally { $ErrorActionPreference = $old }
    $script:lastListRaw = "[$(Split-Path -Leaf $bin) rc=$LASTEXITCODE] $raw"
    try { $j = $raw | ConvertFrom-Json } catch { return 0 }
    # The envelope is `{ success, data: { windows: [...] } }`.
    if ($null -eq $j -or $null -eq $j.data -or $null -eq $j.data.windows) { return 0 }
    return @($j.data.windows | ForEach-Object { $_ }).Count
}
function Get-SweepLeftovers {
    $n = @()
    foreach ($f in @(Get-ChildItem $stagingDir -File -ErrorAction SilentlyContinue)) { $n += $f.Name }
    foreach ($f in @(Get-ChildItem $installDir -Filter '*.old-*' -File -Recurse -ErrorAction SilentlyContinue)) { $n += $f.Name }
    return ($n -join ', ')
}
$sweepLog = Join-Path $work 'app-sweep.err.txt'
$swept = $false
$sweepStop = ''
$sweepStarted = Get-Date
$sweepLastMove = $sweepStarted
$sweepLastSig = ''
while ($true) {
    Start-Sleep -Seconds 1
    if ((Get-AppWindowCount $testExe) -gt 0) { $swept = $true; break }
    if ($again -and $again.Process -and $again.Process.HasExited) { $sweepStop = 'the app exited before opening a window'; break }
    $sig = if (Test-Path $sweepLog) { (Get-Item $sweepLog).Length } else { 0 }
    $now = Get-Date
    if ("$sig" -ne $sweepLastSig) { $sweepLastSig = "$sig"; $sweepLastMove = $now }
    $elapsed = ($now - $sweepStarted).TotalSeconds
    if ($elapsed -ge 240) { $sweepStop = 'the 240s cap ran out while the app was still starting'; break }
    if ($elapsed -ge 60 -and ($now - $sweepLastMove).TotalSeconds -ge 60) { $sweepStop = 'nothing moved for 60s'; break }
}
$sweepWaited = [int]((Get-Date) - $sweepStarted).TotalSeconds
if (-not $swept) {
    $rawHead = "$script:lastListRaw"
    if ($rawHead.Length -gt 400) { $rawHead = $rawHead.Substring(0, 400) }
    Write-Host "  note: last +list --json answer: $rawHead" -ForegroundColor Yellow
}
$leftAfter = Get-SweepLeftovers
if ($leakLock) {
    $leakLock.Dispose()
    Remove-Item $leakFile -Force -ErrorAction SilentlyContinue
}
Stop-ThrowawayInstances -InstallDir $installDir -RealLocalAppData $realLocalAppData
$heldNote = if ($stillHeld) { "; still held when it launched: $stillHeld" } else { '' }
# Two different failures, named differently: a launch that never got past its
# sweep says nothing about leaks, and must not be reported as one.
$sweepWhy = if ($swept) { "window up after ${sweepWaited}s" } else { "$sweepStop after ${sweepWaited}s; not a leak verdict" }
Assert $swept "E: the next launch reached its first window, so its sweep ran ($sweepWhy)"
if ($swept) {
    $leftNote = if ($leftAfter) { "left: $leftAfter$heldNote" } else { 'nothing left' }
    Assert ($leftAfter -eq '') "E: the next launch swept everything the update left ($leftNote)"
}

# The whole reason a throwaway identity was worth building. If any of these
# three moved, the test upgraded the user's terminal.
Assert (Test-Path $userInstallDir) 'E: the user''s Ghoztty install directory is still there'
$userInstallAfter = if (Test-Path $userInstallDir) {
    @(Get-ChildItem $userInstallDir -Recurse -File -ErrorAction SilentlyContinue).Count
} else { -1 }
Assert ($userInstallAfter -eq $userInstallBefore) "E: its file count is unchanged ($userInstallBefore -> $userInstallAfter)"
$userExeVersionAfter = if (Test-Path (Join-Path $userInstallDir 'ghoztty.exe')) {
    (Get-Item (Join-Path $userInstallDir 'ghoztty.exe')).LastWriteTimeUtc.Ticks
} else { 0 }
Assert ($userExeVersionAfter -eq $userExeVersionBefore) 'E: the user''s ghoztty.exe was not rewritten'

Complete-TestBody

} finally {
    Remove-TestDesktop
    if (-not $KeepInstall) {
        Write-Host "`n-- cleanup --"
        Stop-ThrowawayInstances -InstallDir $installDir -RealLocalAppData $realLocalAppData
        Remove-ThrowawayProduct -Identity $Identity -InstallDir $installDir -RealLocalAppData $realLocalAppData
        $pathAfter = Get-UserPathEntryCount
        Assert ($pathAfter -eq $pathBefore) "cleanup: the user PATH is back to $pathBefore entries (got $pathAfter)"
        Assert (-not (Test-Path $installDir)) 'cleanup: the throwaway install directory is gone'
        Assert ((@(Get-ThrowawayUninstallEntries -Identity $Identity)).Count -eq 0) 'cleanup: no throwaway product left registered'
        Remove-Item (Join-Path $env:LOCALAPPDATA 'ghoztty\updates') -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        Write-Host "`n-- cleanup SKIPPED (-KeepInstall) --"
    }
}

Write-Host ''
# --- stamp (T783) ----------------------------------------------------------
# Only a clean, fully-run sweep re-stamps. A run that SKIPPED (no network, no
# `gh`, no published packages) proves nothing about the code and must leave the
# guard due.
if ($script:fail -eq 0 -and $script:skip -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard update-real-msi -Repo $repo 2>&1 |
        ForEach-Object { Write-Host "  $_" }
}

Write-TestVerdict -Pass $script:pass -Fail $script:fail -Skipped $script:skip -Unit 'checks'
