# T3394 acceptance: test\win32\lib\UserInstallSentinel.ps1, the proof that a
# harness running a REAL msiexec never reached the user's installed Ghoztty.
#
# On 2026-11-22 a test's msiexec reconfigured the user's real product and left
# %LOCALAPPDATA%\Programs\Ghoztty with its agent renamed aside (T3388). The two
# harnesses that install on purpose (update-real-msi, update-graceful) carried
# a "user's install untouched" check that could not see that: a file count
# (a rename keeps it) and ghoztty.exe's mtime (not the file that moved). This
# measures the replacement on things it is allowed to break:
#
#   A. The package pre-flight. The published MSI is refused for every reason it
#      carries; its throwaway rewrite passes; a COPY of the rewrite with an
#      Upgrade-table row naming the shipping code - the rule a fresh
#      UpgradeCode alone would miss - is refused for exactly that; so is a copy
#      claiming the user's installed ProductCode; a missing or unreadable
#      package is refused rather than passed. Nothing here is ever installed.
#   B. The snapshot, on a scratch directory shaped like an install: an
#      untouched dir diffs clean; the 2026-11-22 shape (agent renamed to
#      .old-<n>) is named; a same-length same-mtime rewrite of an image is
#      caught by its hash; a sidelined .old-* file vanishing (the user's own
#      app sweeps those) is not a diff; a missing dir is.
#   C. The installer-event filter: the real 1035 message matches, a throwaway
#      identity's does not, and a live read of the log answers rather than
#      saying "unknown".
#   D. Wiring: both msiexec harnesses load the library, refuse before their
#      first msiexec, and no longer keep the file-count check.
#
#   -NegativeControl adds one inverted assertion a healthy tree MUST fail.
#
# Nothing here writes outside %TEMP%, runs msiexec, or opens a window. The
# user's install is only read (section A asks Windows Installer for the
# installed ProductCode).
#
# isolation: none - this script never runs a ghoztty verb.
[CmdletBinding(PositionalBinding = $false)]
param([switch]$NegativeControl)

$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\ThrowawayProduct.ps1')
. (Join-Path $PSScriptRoot 'lib\UserInstallSentinel.ps1')

$script:fail = 0
$script:pass = 0
$script:skip = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}
function Skip([string]$label) { $script:skip++; Write-Host "SKIP  $label" -ForegroundColor Yellow }

$work = Join-Path $env:TEMP "ghoztty-t3394-$PID"
New-Item -ItemType Directory -Force $work | Out-Null

function Invoke-MsiSql([string]$Msi, [string]$Sql) {
    # Edits a COPY only (callers pass one). Mode 1 = transact; Commit writes it.
    $inst = New-Object -ComObject WindowsInstaller.Installer
    $db = $inst.OpenDatabase($Msi, 1)
    $v = $db.OpenView($Sql)
    [void]$v.Execute()
    [void]$v.Close()
    [void]$db.Commit()
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($v)
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($db)
}

try {

# ============================================================ A. pre-flight
Write-Host '--- A. the package pre-flight ---'
# The same cache update-real-msi keeps, so a box that has run it pays nothing.
$cache = Join-Path $env:TEMP 'ghoztty-t1194'
$published = Join-Path $cache 'Ghoztty-1.35.0-x64.msi'
$throwaway = Get-ThrowawayPackage -Tag 'win-v1.35.0' -Version '1.35.0' -Work $cache -Identity 'GhozttyT1194Test' -Repo $repo
if (-not $throwaway -or -not (Test-Path $published)) {
    Skip 'A: the published win-v1.35.0 package could not be obtained (no network or gh) - the pre-flight is unmeasured'
} else {
    $r = @(Get-PackageUserProductReach -Msi $published)
    Assert (($r -join ';') -match 'UpgradeCode is the shipping') "A1 the published package is refused for its UpgradeCode ($($r.Count) reasons)"
    Assert (($r -join ';') -match 'Upgrade table names the shipping') 'A2 ... and for its Upgrade table'
    Assert (($r -join ';') -match 'ProductName is the shipping') 'A3 ... and for its ProductName'

    $r = @(Get-PackageUserProductReach -Msi $throwaway)
    Assert ($r.Count -eq 0) "A4 its throwaway rewrite passes ($($r -join '; '))"

    # The rule a fresh UpgradeCode alone would miss: a major upgrade removes
    # what its Upgrade table names, whatever the package calls itself.
    $upg = Join-Path $work 'upgrade-row.msi'
    Copy-Item $throwaway $upg -Force
    Invoke-MsiSql $upg ("INSERT INTO ``Upgrade`` (``UpgradeCode``,``VersionMin``,``Attributes``,``ActionProperty``) " +
        "VALUES ('$($script:ShippingUpgradeCode)','0.0.0',256,'T3394SHIPPING')")
    $r = @(Get-PackageUserProductReach -Msi $upg)
    Assert ($r.Count -eq 1 -and $r[0] -match 'Upgrade table names the shipping') "A5 a throwaway whose Upgrade table names the shipping code is refused for exactly that ($($r -join '; '))"

    $userCodes = @(Get-UserProductCodes)
    if ($userCodes.Count -eq 0) {
        Skip 'A6 no Ghoztty is installed for this user, so the ProductCode rule has nothing to match'
    } else {
        $pc = Join-Path $work 'product-code.msi'
        Copy-Item $throwaway $pc -Force
        Invoke-MsiSql $pc "UPDATE ``Property`` SET ``Value``='$($userCodes[0])' WHERE ``Property``='ProductCode'"
        $r = @(Get-PackageUserProductReach -Msi $pc)
        Assert ($r.Count -eq 1 -and $r[0] -match 'is the user''s installed product') "A6 a throwaway claiming the user's ProductCode is refused for exactly that ($($r -join '; '))"
    }
}
$r = @(Get-PackageUserProductReach -Msi (Join-Path $work 'no-such.msi'))
Assert ($r.Count -ge 1) 'A7 a missing package is refused, not passed'
$junk = Join-Path $work 'junk.msi'
[IO.File]::WriteAllText($junk, 'not an msi')
$r = @(Get-PackageUserProductReach -Msi $junk)
Assert ($r.Count -ge 1) "A8 an unreadable package is refused, not passed ($($r -join '; '))"

# ============================================================== B. snapshot
Write-Host '--- B. the install snapshot ---'
$fake = Join-Path $work 'Programs\Ghoztty'
New-Item -ItemType Directory -Force (Join-Path $fake 'share') | Out-Null
foreach ($n in @('ghoztty.exe', 'ghoztty.com', 'ghoztty-agent.exe')) {
    [IO.File]::WriteAllBytes((Join-Path $fake $n), [Text.Encoding]::ASCII.GetBytes("image $n"))
}
[IO.File]::WriteAllText((Join-Path $fake 'share\theme.txt'), 'x')
[IO.File]::WriteAllText((Join-Path $fake 'ghoztty-agent.exe.old-111'), 'old')

$s0 = Get-UserInstallSnapshot -Dir $fake -NoProducts
Assert ((Compare-UserInstallSnapshot -Before $s0 -After (Get-UserInstallSnapshot -Dir $fake -NoProducts)) -eq '') 'B1 an untouched install diffs clean (control)'

# The 2026-11-22 shape: the agent renamed aside, nothing written back. The
# file count is unchanged - which is exactly what the old check measured.
$agent = Join-Path $fake 'ghoztty-agent.exe'
$countBefore = @(Get-ChildItem $fake -Recurse -File).Count
Rename-Item $agent 'ghoztty-agent.exe.old-222'
$countAfter = @(Get-ChildItem $fake -Recurse -File).Count
$d = Compare-UserInstallSnapshot -Before $s0 -After (Get-UserInstallSnapshot -Dir $fake -NoProducts)
Assert ($countBefore -eq $countAfter) "B2 the incident shape keeps the file count ($countBefore -> $countAfter), so the old check passed it"
Assert ($d -match 'ghoztty-agent\.exe absent' -and $d -match '- file ghoztty-agent\.exe ') "B3 the snapshot names the missing agent ($($d -replace "`n", ' / '))"
Rename-Item (Join-Path $fake 'ghoztty-agent.exe.old-222') 'ghoztty-agent.exe'

# A rewrite that keeps the length and the mtime is still a rewrite.
$exe = Join-Path $fake 'ghoztty.exe'
$mt = (Get-Item $exe).LastWriteTimeUtc
$bytes = [IO.File]::ReadAllBytes($exe); $bytes[0] = [byte]([int]$bytes[0] -bxor 1)
[IO.File]::WriteAllBytes($exe, $bytes)
(Get-Item $exe).LastWriteTimeUtc = $mt
$d = Compare-UserInstallSnapshot -Before $s0 -After (Get-UserInstallSnapshot -Dir $fake -NoProducts)
Assert ($d -match 'hash ghoztty\.exe' -and $d -notmatch 'file ghoztty\.exe ') "B4 a same-length same-mtime rewrite is caught by its hash alone ($($d -replace "`n", ' / '))"
$bytes[0] = [byte]([int]$bytes[0] -bxor 1); [IO.File]::WriteAllBytes($exe, $bytes); (Get-Item $exe).LastWriteTimeUtc = $mt

# The user's own app sweeps sidelined images at startup; that is not a diff.
Remove-Item (Join-Path $fake 'ghoztty-agent.exe.old-111') -Force
Assert ((Compare-UserInstallSnapshot -Before $s0 -After (Get-UserInstallSnapshot -Dir $fake -NoProducts)) -eq '') 'B5 a sidelined .old-* image going away (the app''s own sweep) is not a diff'

Remove-Item (Join-Path $fake 'share\theme.txt') -Force
$d = Compare-UserInstallSnapshot -Before $s0 -After (Get-UserInstallSnapshot -Dir $fake -NoProducts)
Assert ($d -match '- file share\\theme\.txt') 'B6 any other file going away is a diff'

$d = Compare-UserInstallSnapshot -Before $s0 -After (Get-UserInstallSnapshot -Dir (Join-Path $work 'gone') -NoProducts)
Assert ($d -match '\+ dir missing') 'B7 a missing install directory is a diff'

# The product line is part of the real snapshot (registered version + cached
# package), so a reconfigure that re-caches it shows even with no file moved.
$real = Get-UserInstallSnapshot -Dir $fake
if (@(Get-UserProductCodes).Count -gt 0) {
    Assert (@($real.Lines | Where-Object { $_ -match '^product \{' }).Count -ge 1) 'B8 the real snapshot carries the registered product and version'
} else {
    Skip 'B8 no Ghoztty is registered for this user'
}

# ================================================================ C. events
Write-Host '--- C. installer events ---'
$m1035 = 'Windows Installer reconfigured the product. Product Name: Ghoztty. Product Version: 26.11.22282. Product Language: 1033. Manufacturer: dzearing. Reconfiguration success or error status: 0.'
Assert (Test-UserProductEventMessage -Message $m1035) 'C1 the 2026-11-22 reconfigure message is about the user''s product'
Assert (-not (Test-UserProductEventMessage -Message ($m1035 -replace 'Name: Ghoztty\.', 'Name: GhozttyT1194Test.'))) 'C2 the same message for a throwaway identity is not'
Assert (-not (Test-UserProductEventMessage -Message 'Ending a Windows Installer transaction: C:\x\Ghoztty-1.56.8-x64.msi.')) 'C3 a transaction line naming a package file is not'
$live = Get-UserProductInstallerEvents -Since (Get-Date).AddSeconds(1)
Assert ($live -notmatch '^unknown:') "C4 the Application log can be read here ($live)"

# ================================================================ D. wiring
Write-Host '--- D. wiring ---'
foreach ($h in @('update-real-msi', 'update-graceful')) {
    $t = [IO.File]::ReadAllText((Join-Path $PSScriptRoot "$h.ps1"))
    $iLoad = $t.IndexOf('lib\UserInstallSentinel.ps1')
    $iReach = $t.IndexOf('Get-PackageUserProductReach')
    $iMsi = $t.IndexOf('Start-Process msiexec.exe')
    Assert ($iLoad -ge 0 -and $iReach -ge 0 -and $iMsi -gt $iReach) "D $h loads the sentinel and refuses before its first msiexec"
    Assert ($t -match 'REFUSED: no msiexec was run' -and $t -match 'exit 1') "D $h stops the run on a refusal"
    Assert ($t -match 'Compare-UserInstallSnapshot' -and $t -match 'Get-UserProductInstallerEvents') "D $h compares the snapshot and reads the installer's events"
    Assert ($t -notmatch 'userInstallBefore') "D $h no longer keeps the file-count check"
    # The comparison must sit in the finally, after the cleanup's msiexec /x.
    $iFinally = $t.LastIndexOf('} finally {')
    Assert ($iFinally -ge 0 -and $t.IndexOf('Compare-UserInstallSnapshot', $iFinally) -gt $t.IndexOf('Remove-ThrowawayProduct', $iFinally)) "D $h compares after the cleanup uninstall"
}

if ($NegativeControl) {
    Assert ((Compare-UserInstallSnapshot -Before $s0 -After (Get-UserInstallSnapshot -Dir (Join-Path $work 'gone') -NoProducts)) -eq '') 'NEGATIVE CONTROL: a missing install must not diff clean (this must FAIL)'
}

Complete-TestBody  # T1039: the run reached the end of its body
} finally {
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}

# --- stamp (T783) -----------------------------------------------------------
# A green, fully-run sweep records the content of every file this harness
# covers; a red or skipped run leaves the stamp alone on purpose.
if ($script:fail -eq 0 -and $script:skip -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard user-install-sentinel -Repo $repo | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Skipped $script:skip -Label 'USER-INSTALL-SENTINEL' -MinPass 20
