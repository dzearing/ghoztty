# T2327 acceptance: a major upgrade leaves exactly ONE Ghoztty in Apps & Features.
#
# THE DEFECT. Every in-app update left the release it replaced listed in
# Settings > Apps: by 2026-11-03 the box showed 45 "Ghoztty" rows, 1.43.4 up to
# 1.52.9, only one of them a product Windows Installer still knew. Clicking
# Uninstall on any of the other 44 runs `msiexec /x` against a product that no
# longer exists.
#
# THE CAUSE, read out of the installed package: build-msi.sh asks for
# `<RemoveExistingProducts After="InstallValidate"/>`, and wixl's sequencer
# emitted it at 6604 - AFTER InstallFinalize (the same After=-anchoring defect
# T1367 found for the custom actions). A late RemoveExistingProducts installs
# the new product first and removes the old one second. The listed Apps &
# Features entry (C_ArpEntry, T2168) keeps ONE component GUID across releases,
# so by the time the old product is removed the new one is already a client of
# that component, Windows Installer leaves the component's resources in place -
# and the old release's `Uninstall\{old ProductCode}` values are among them.
# The fix pins the action to an explicit Sequence (1401, right after
# InstallValidate), which is the early placement every upgrade-safety comment
# in build-msi.sh was already written for.
#
# THE PROOF, on real published bytes with no rebuild (wixl needs Docker):
#
#   A  packages: the newest published release rewritten to two throwaway
#      identities, each as its own predecessor too (msi-test-identity.ps1)
#   B  AS PUBLISHED: upgrade predecessor -> release, count the listed entries.
#      The count must agree with where the package sequences
#      RemoveExistingProducts: late -> the orphan reproduces (2 entries, the
#      old ProductCode's key left behind), early -> 1. So this arm is red on
#      nothing: on a pre-fix release it is the demonstration that the count
#      can come out wrong (T794), and on a fixed release it is the live check.
#   C  AS FIXED: the same packages with RemoveExistingProducts moved to 1401,
#      exactly what build-msi.sh now emits. One listed entry, the
#      predecessor's key gone, and the upgrade still delivers every file (the
#      T23 vanishing-exe shape is what an early removal can regress).
#   D  nothing left behind; the user's own Ghoztty rows never moved.
#
# preflight: none - the binaries here come out of a PUBLISHED MSI, so they are
# release builds by definition and `Assert-GhozttyIsolatedBuild` would refuse
# them. Nothing is launched: every install is `/qn`, and the package's own
# launch-on-finish action is conditioned on a full UI.
#
# persistence: not applicable - no terminal is started, so no session layout is
# read or written.
#
# isolation: full - two throwaway product identities (own ProductCode,
# UpgradeCode, component GUIDs, install directory, registry key, Start Menu
# name) that cannot upgrade, remove or refcount the user's Ghoztty; section D
# measures that against the user's install on every run.
#
#   powershell -NoProfile -File test\win32\arp-orphan.ps1

param(
    [string]$Tag = '',
    [string]$OldProductVersion = '26.8.3109',
    [string]$PublishedIdentity = 'GhozttyT2327Pub',
    [string]$FixedIdentity = 'GhozttyT2327Fix',
    [int]$EarlySequence = 1401,
    [switch]$KeepInstall
)
$ErrorActionPreference = 'Continue'
Set-StrictMode -Off

$realLocalAppData = $env:LOCALAPPDATA
. (Join-Path $PSScriptRoot 'lib\ThrowawayProduct.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$work = Join-Path $env:TEMP 'ghoztty-t2327'
New-Item -ItemType Directory -Force $work | Out-Null

$script:pass = 0
$script:fail = 0
$script:skip = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}
function Skip([string]$label) { $script:skip++; Write-Host "SKIP  $label" -ForegroundColor Yellow }

# --- MSI table helpers (Windows Installer automation; no msitools) ----------
function Get-MsiActionSequence {
    param([string]$Msi, [string]$Action)
    $inst = New-Object -ComObject WindowsInstaller.Installer
    $db = $inst.OpenDatabase($Msi, 0)
    $v = $db.OpenView("SELECT ``Sequence`` FROM ``InstallExecuteSequence`` WHERE ``Action``='$Action'")
    [void]$v.Execute()
    $r = $v.Fetch()
    $out = if ($null -eq $r) { -1 } else { [int]$r.StringData(1) }
    [void]$v.Close()
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($v)
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($db)
    return $out
}

function New-EarlyRepCopy {
    # A copy of $Src with RemoveExistingProducts at $Sequence and a fresh
    # PackageCode (the installer cache keys on it, and these are different
    # bytes from the package they were copied from).
    param([string]$Src, [string]$Dst, [int]$Sequence)
    Copy-Item $Src $Dst -Force
    $inst = New-Object -ComObject WindowsInstaller.Installer
    $db = $inst.OpenDatabase($Dst, 1)
    $v = $db.OpenView("UPDATE ``InstallExecuteSequence`` SET ``Sequence``=$Sequence WHERE ``Action``='RemoveExistingProducts'")
    [void]$v.Execute()
    [void]$v.Close()
    $si = $db.SummaryInformation(4)
    $si.Property(9) = '{' + ([guid]::NewGuid().ToString().ToUpper()) + '}'
    [void]$si.Persist()
    [void]$db.Commit()
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($si)
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($v)
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($db)
}

function Get-ListedCodes {
    param([string]$Identity)
    return @(Get-ThrowawayUninstallEntries -Identity $Identity |
        ForEach-Object { Split-Path $_.PSPath -Leaf } | Sort-Object -Unique)
}

function Remove-ThrowawayOrphans {
    # What Remove-ThrowawayProduct cannot reach: a listed key whose product is
    # gone, so `msiexec /x` on its name has nothing to remove. Scoped to HKCU
    # keys whose DisplayName IS the throwaway identity - never a user row.
    param([string]$Identity)
    if ($Identity -notmatch '^GhozttyT\d+') { throw "refusing orphan sweep for non-throwaway identity '$Identity'" }
    $root = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall'
    foreach ($k in @(Get-ChildItem $root -ErrorAction SilentlyContinue)) {
        $p = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
        if ($p -and $p.DisplayName -eq $Identity) { Remove-Item $k.PSPath -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Remove-Arm {
    param([string]$Identity)
    $dir = Get-ThrowawayInstallDir -RealLocalAppData $realLocalAppData -Identity $Identity
    Remove-ThrowawayProduct -Identity $Identity -InstallDir $dir -RealLocalAppData $realLocalAppData
    Remove-ThrowawayOrphans -Identity $Identity
}

function Install-Msi {
    param([string]$Msi, [string]$Log)
    $p = Start-Process msiexec.exe -ArgumentList @('/i', "`"$Msi`"", '/qn', '/norestart',
        'LAUNCHAPP=0', '/l*v', "`"$Log`"") -Wait -PassThru
    $null = $p.Handle
    return $p.ExitCode
}

function Invoke-UpgradeArm {
    # Install $Old, then $New over it. Returns what an observer of Apps &
    # Features and of the install directory can see afterwards.
    param([string]$Identity, [string]$Old, [string]$New, [string]$Tag)
    $dir = Get-ThrowawayInstallDir -RealLocalAppData $realLocalAppData -Identity $Identity
    Remove-Arm -Identity $Identity
    $r = [ordered]@{ OldExit = -1; NewExit = -1; Listed = @(); FilesBefore = -1; FilesAfter = -1; Missing = @() }
    $r.OldExit = Install-Msi -Msi $Old -Log (Join-Path $work "$Identity-$Tag-old.log")
    $r.FilesBefore = @(Get-ChildItem $dir -Recurse -File -ErrorAction SilentlyContinue).Count
    $r.NewExit = Install-Msi -Msi $New -Log (Join-Path $work "$Identity-$Tag-new.log")
    $r.Listed = @(Get-ListedCodes -Identity $Identity)
    $r.FilesAfter = @(Get-ChildItem $dir -Recurse -File -ErrorAction SilentlyContinue).Count
    $r.Missing = @('ghoztty.exe', 'ghoztty.com', 'ghoztty-agent.exe' |
        Where-Object { -not (Test-Path (Join-Path $dir $_)) })
    return $r
}

# The user's rows, measured before anything runs and again in D.
$userRowsBefore = @(Get-ThrowawayUninstallEntries -Identity 'Ghoztty' -IncludeHidden |
    ForEach-Object { $_.PSPath } | Sort-Object)
$pathBefore = Get-UserPathEntryCount

# ===================================================== A. packages
Write-Host "`n-- A. throwaway packages from the newest published release --"
if (-not $Tag) {
    $Tag = (& gh release list --repo dzearing/ghoztty --limit 20 2>$null |
        ForEach-Object { ($_ -split "`t")[2] } | Where-Object { $_ -match '^win-v\d' } |
        Select-Object -First 1)
}
if (-not $Tag) {
    Write-TestAssertedNothing -Reason 'could not ask GitHub for the newest published release' -Label 'arp-orphan'
}
$ver = $Tag -replace '^win-v', ''
$pubWork = Join-Path $work $PublishedIdentity
$fixWork = Join-Path $work $FixedIdentity
$pubNew = Get-ThrowawayPackage -Tag $Tag -Version $ver -Work $pubWork -Identity $PublishedIdentity -Repo $repo
$pubOld = Get-ThrowawayPackage -Tag $Tag -Version $ver -Work $pubWork -Identity $PublishedIdentity -Repo $repo -AsProductVersion $OldProductVersion
$fixNewSrc = Get-ThrowawayPackage -Tag $Tag -Version $ver -Work $fixWork -Identity $FixedIdentity -Repo $repo
$fixOldSrc = Get-ThrowawayPackage -Tag $Tag -Version $ver -Work $fixWork -Identity $FixedIdentity -Repo $repo -AsProductVersion $OldProductVersion
if (-not $pubNew -or -not $pubOld -or -not $fixNewSrc -or -not $fixOldSrc) {
    Write-TestAssertedNothing -Reason "could not obtain the published package ($Tag)" -Label 'arp-orphan'
}
Assert ((Get-MsiProperty -Msi $pubNew -Name 'ProductName') -eq $PublishedIdentity) "A1 $Tag rewritten to $PublishedIdentity"
Assert ((Get-MsiProperty -Msi $fixNewSrc -Name 'ProductName') -eq $FixedIdentity) "A2 and to $FixedIdentity"
Assert ((Get-MsiProperty -Msi $pubNew -Name 'UpgradeCode') -ne '{5EB02044-7F06-498B-B7A9-7EFD65486CFB}') "A3 neither carries the shipping product's UpgradeCode"
Assert ((Get-MsiProperty -Msi $pubOld -Name 'ProductCode') -ne (Get-MsiProperty -Msi $pubNew -Name 'ProductCode')) 'A4 predecessor and release are two products under one UpgradeCode'

$fixNew = Join-Path $fixWork "early-$ver.msi"
$fixOld = Join-Path $fixWork "early-$ver-$OldProductVersion.msi"
New-EarlyRepCopy -Src $fixNewSrc -Dst $fixNew -Sequence $EarlySequence
New-EarlyRepCopy -Src $fixOldSrc -Dst $fixOld -Sequence $EarlySequence

$validate = Get-MsiActionSequence -Msi $pubNew -Action 'InstallValidate'
$initialize = Get-MsiActionSequence -Msi $pubNew -Action 'InstallInitialize'
$finalize = Get-MsiActionSequence -Msi $pubNew -Action 'InstallFinalize'
$repPub = Get-MsiActionSequence -Msi $pubNew -Action 'RemoveExistingProducts'
$repFix = Get-MsiActionSequence -Msi $fixNew -Action 'RemoveExistingProducts'
$pubEarly = ($repPub -gt $validate -and $repPub -lt $initialize)
Write-Host "  published $Tag sequences RemoveExistingProducts at $repPub (InstallValidate=$validate InstallInitialize=$initialize InstallFinalize=$finalize): $(if ($pubEarly) { 'EARLY' } else { 'LATE' })"
Assert ($repPub -gt 0) "A5 the published package has a RemoveExistingProducts row ($repPub)"
Assert ($repFix -gt $validate -and $repFix -lt $initialize) "A6 the fixed copy runs it between InstallValidate and InstallInitialize ($repFix)"

try {
    # ===================================================== B. as published
    Write-Host "`n-- B. as published: predecessor -> $Tag --"
    $b = Invoke-UpgradeArm -Identity $PublishedIdentity -Old $pubOld -New $pubNew -Tag $ver
    Assert ($b.OldExit -eq 0 -and $b.NewExit -eq 0) "B1 both installs succeeded (exit $($b.OldExit) / $($b.NewExit))"
    $pubOldCode = Get-MsiProperty -Msi $pubOld -Name 'ProductCode'
    Write-Host "  listed after upgrade: $($b.Listed -join ', ')"
    if ($pubEarly) {
        Assert ($b.Listed.Count -eq 1) "B2 an early removal leaves ONE listed entry ($($b.Listed.Count))"
    } else {
        # The positive control: the measurement below sees the defect when the
        # package carries it, so C's single entry is a real answer.
        Assert ($b.Listed.Count -eq 2 -and $b.Listed -contains $pubOldCode) `
            "B2 a late removal leaves the predecessor's entry behind - the defect reproduces ($($b.Listed.Count) listed)"
    }
    Remove-Arm -Identity $PublishedIdentity

    # ===================================================== C. as fixed
    Write-Host "`n-- C. as fixed: RemoveExistingProducts at $EarlySequence --"
    $c = Invoke-UpgradeArm -Identity $FixedIdentity -Old $fixOld -New $fixNew -Tag $ver
    Assert ($c.OldExit -eq 0 -and $c.NewExit -eq 0) "C1 both installs succeeded (exit $($c.OldExit) / $($c.NewExit))"
    $fixOldCode = Get-MsiProperty -Msi $fixOld -Name 'ProductCode'
    $fixNewCode = Get-MsiProperty -Msi $fixNew -Name 'ProductCode'
    Write-Host "  listed after upgrade: $($c.Listed -join ', ')"
    Assert ($c.Listed.Count -eq 1) "C2 exactly ONE listed entry after the upgrade ($($c.Listed.Count))"
    Assert ($c.Listed -notcontains $fixOldCode) "C3 the predecessor's entry is gone ($fixOldCode)"
    Assert ($c.Listed -contains $fixNewCode) "C4 the one left is the release that was installed ($fixNewCode)"
    Assert ($c.Missing.Count -eq 0) "C5 the upgrade delivered ghoztty.exe, ghoztty.com and ghoztty-agent.exe (missing: $($c.Missing -join ', '))"
    Assert ($c.FilesAfter -eq $c.FilesBefore -and $c.FilesAfter -gt 0) "C6 and every file the predecessor had ($($c.FilesBefore) -> $($c.FilesAfter))"
    $exeVer = Get-ThrowawayExeVersion -Exe (Join-Path (Get-ThrowawayInstallDir -RealLocalAppData $realLocalAppData -Identity $FixedIdentity) 'ghoztty.exe')
    Assert ($exeVer -eq $ver) "C7 the installed terminal reports $ver (got '$exeVer')"

    Complete-TestBody
} finally {
    Write-Host "`n-- D. cleanup --"
    if (-not $KeepInstall) {
        Remove-Arm -Identity $PublishedIdentity
        Remove-Arm -Identity $FixedIdentity
        foreach ($id in @($PublishedIdentity, $FixedIdentity)) {
            Assert ((@(Get-ThrowawayUninstallEntries -Identity $id -IncludeHidden)).Count -eq 0) "D1 nothing of $id left registered"
            Assert (-not (Test-Path (Get-ThrowawayInstallDir -RealLocalAppData $realLocalAppData -Identity $id))) "D2 the $id install directory is gone"
        }
        Assert ((Get-UserPathEntryCount) -eq $pathBefore) "D3 the user PATH is back to $pathBefore entries"
    } else {
        Write-Host '  installs kept (-KeepInstall)'
    }
    $userRowsAfter = @(Get-ThrowawayUninstallEntries -Identity 'Ghoztty' -IncludeHidden |
        ForEach-Object { $_.PSPath } | Sort-Object)
    Assert (($userRowsAfter -join '|') -eq ($userRowsBefore -join '|')) "D4 the user's own Ghoztty rows never moved ($($userRowsBefore.Count) -> $($userRowsAfter.Count))"
}

# --- stamp (T783) ----------------------------------------------------------
if ($script:fail -eq 0 -and $script:skip -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard arp-orphan -Repo $repo 2>&1 |
        ForEach-Object { Write-Host "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Skipped $script:skip -Label 'arp-orphan' -MinPass 16
