# What does Apps & Features show for the installed Ghoztty, and is it the
# number the package asked for? (T1210)
#
# READ-ONLY: it reads the Uninstall key Windows wrote and the cached MSI Windows
# installed from, and prints one line per check naming the surface it read. It
# never installs, repairs or writes anything, so it is safe to point at the
# user's own install. The checks and why they are three are in
# scripts\lib\ArpVersion.ps1.
#
#   powershell -NoProfile -File scripts\arp-version-check.ps1
#   powershell -NoProfile -File scripts\arp-version-check.ps1 -DisplayName GhozttyT1299Test
#
# Exit 0  every installed entry agrees with its package.
# Exit 1  at least one check failed (the FAIL line says which surface).
# Exit 3  no installed product by that name - nothing to read, not a pass.
#
# -Roots and -Package exist for the acceptance harness: a fixture Uninstall key
# under HKCU and a fixture MSI stand in for an install, since installing one is
# what this check exists to avoid needing.
[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$DisplayName = 'Ghoztty',
    [string[]]$Roots = @(),
    [string]$Package = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\ArpVersion.ps1')

$findArgs = @{ DisplayName = $DisplayName }
if ($Roots.Count -gt 0) { $findArgs.Roots = $Roots }
$entries = @(Find-ArpEntries @findArgs)
if ($entries.Count -eq 0) {
    Write-Host "ARP VERSION NOT INSTALLED: no Apps & Features entry named '$DisplayName'"
    exit 3
}

$bad = 0
foreach ($e in $entries) {
    $pkg = if ($Package) { $Package } else { Get-ArpLocalPackage -ProductCode $e.ProductCode }
    Write-Host "$DisplayName $($e.ProductCode)"
    Write-Host "  registry: $($e.Where)"
    if (-not $pkg -or -not (Test-Path -LiteralPath $pkg)) {
        $bad++
        Write-Host "  FAIL  package: Windows Installer has no cached package for $($e.ProductCode) ('$pkg'), so there is nothing to hold DisplayVersion '$($e.DisplayVersion)' against"
        continue
    }
    Write-Host "  package : $pkg"
    $v = Get-ArpVersionVerdict -DisplayVersion $e.DisplayVersion -VersionDword $e.Version `
        -PackageDisplay (Get-ArpPackageProperty -Package $pkg -Name 'ARPDISPLAYVERSION') `
        -PackageProduct (Get-ArpPackageProperty -Package $pkg -Name 'ProductVersion') `
        -RegistryWhere 'registry' -PackageWhere 'the package'
    foreach ($l in $v.Lines) { Write-Host "  $l" }
    if (-not $v.Ok) { $bad++ }
}

if ($bad -gt 0) {
    Write-Host "ARP VERSION MISMATCH: $bad of $($entries.Count) installed '$DisplayName' entr$(if ($entries.Count -eq 1) { 'y' } else { 'ies' }) disagree with the package"
    exit 1
}
Write-Host "ARP VERSION OK: $($entries.Count) installed '$DisplayName' entr$(if ($entries.Count -eq 1) { 'y' } else { 'ies' }) agree with the package"
exit 0
