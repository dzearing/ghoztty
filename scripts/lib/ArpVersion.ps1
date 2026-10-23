# ArpVersion.ps1 - what Apps & Features shows for an INSTALLED Ghoztty, read off
# the machine and held against the package that installed it (T1210).
#
# T1205 gave the package two version numbers on purpose:
#
#   - ProductVersion (yy.m.dNN, e.g. 26.10.2290) - the SEQUENCING number Windows
#     Installer decides upgrades with. Load-bearing; never the one people read.
#   - ARPDISPLAYVERSION (the release semver, e.g. 1.43.3) - the number the
#     package asks Apps & Features to show.
#
# Everything that checked that split read the RECIPE: build-msi.sh reading the
# compiled Property table back, release-artifacts A20-A22 reading the script,
# verify-release-assets reading the published package. None read the last hop -
# the registry entry Windows actually writes - and that is the hop that matters,
# because the property only does anything if Windows Installer honours it. On
# 2026-10-22 the user's installed win-v1.43.3 declared ARPDISPLAYVERSION=1.43.3
# and Apps & Features showed 26.10.2290.
#
# So the verdict below is made from three surfaces, and every line it prints
# names which one it read and where:
#
#   registry  the Uninstall keys for the product: DisplayVersion from the one
#             Apps & Features lists (what a person sees) and Version (a DWORD,
#             the registered ProductVersion) from Windows' own registration.
#             Since T2168 those are two keys - Windows' entry is hidden and the
#             package writes the listed one itself, because Windows Installer
#             never reads ARPDISPLAYVERSION - and Group-ArpProducts pairs them.
#             The CLI adds a fourth check, `listed`: exactly one shown entry.
#   package   the cached MSI Windows installed from (its LocalPackage):
#             ARPDISPLAYVERSION and ProductVersion from its Property table.
#
# Three checks, each its own line:
#
#   display     registry DisplayVersion == package ARPDISPLAYVERSION
#               (or == ProductVersion when the package declares none - the
#               pre-T1205 shape, which is then honestly what it should show).
#   sequencing  registry Version == package ProductVersion: the display fix
#               must not have moved the number upgrades are decided on.
#   unfused     package ARPDISPLAYVERSION != ProductVersion: display and
#               sequencing must not have been re-fused into one value, which
#               would make `display` pass by construction.
#
# Pure functions first (the harness drives them with fixtures); the two readers
# at the bottom touch the registry and the Windows Installer automation object,
# both READ-ONLY. Nothing here installs, repairs or writes anything.

# The Uninstall key's `Version` DWORD packs a ProductVersion as
# major<<24 | minor<<16 | build. Read as Int32 a major >= 128 is negative, so
# widen and mask before shifting. (4294967295, not 0xFFFFFFFF: PS 5.1 reads that
# hex literal as Int32 -1.)
function ConvertFrom-ArpVersionDword {
    param([Parameter(Mandatory = $true)]$Value)
    $u = ([int64]$Value) -band [int64]4294967295
    $major = ($u -shr 24) -band 255
    $minor = ($u -shr 16) -band 255
    $build = $u -band 65535
    return "$major.$minor.$build"
}

# Two dotted versions are the same number when [version] says so ('1.2' vs
# '1.2.0' differ there, so pad to three parts first). Anything unparseable is
# compared as text.
function Test-ArpVersionEqual {
    param([string]$A, [string]$B)
    if ([string]::IsNullOrWhiteSpace($A) -or [string]::IsNullOrWhiteSpace($B)) { return $false }
    $pa = @($A.Trim().Split('.')); $pb = @($B.Trim().Split('.'))
    while ($pa.Count -lt 3) { $pa += '0' }
    while ($pb.Count -lt 3) { $pb += '0' }
    try { return ([version]($pa -join '.')) -eq ([version]($pb -join '.')) }
    catch { return $A.Trim() -eq $B.Trim() }
}

# The verdict. -RegistryWhere / -PackageWhere are only for the lines: they say
# WHERE each number came from so a red line names the surface that disagreed.
function Get-ArpVersionVerdict {
    param(
        [string]$DisplayVersion,
        $VersionDword,
        [string]$PackageDisplay,
        [string]$PackageProduct,
        [string]$RegistryWhere = 'registry',
        [string]$PackageWhere = 'package'
    )
    $lines = @()
    $failed = @()

    $registered = if ($null -ne $VersionDword -and "$VersionDword" -ne '') {
        ConvertFrom-ArpVersionDword -Value $VersionDword
    } else { '' }

    $wantDisplay = $PackageDisplay
    $wantFrom = "ARPDISPLAYVERSION in $PackageWhere"
    if ([string]::IsNullOrWhiteSpace($PackageDisplay)) {
        $wantDisplay = $PackageProduct
        $wantFrom = "ProductVersion in $PackageWhere (it declares no ARPDISPLAYVERSION)"
    }

    if (Test-ArpVersionEqual $DisplayVersion $wantDisplay) {
        $lines += "OK    display: Apps & Features shows '$DisplayVersion' ($RegistryWhere DisplayVersion), as $wantFrom asks"
    } else {
        $failed += 'display'
        $lines += "FAIL  display: Apps & Features shows '$DisplayVersion' ($RegistryWhere DisplayVersion), but $wantFrom is '$wantDisplay'"
    }

    if (Test-ArpVersionEqual $registered $PackageProduct) {
        $lines += "OK    sequencing: Windows registered ProductVersion $registered ($RegistryWhere Version), the package's own $PackageProduct"
    } else {
        $failed += 'sequencing'
        $lines += "FAIL  sequencing: Windows registered ProductVersion '$registered' ($RegistryWhere Version), but ProductVersion in $PackageWhere is '$PackageProduct'"
    }

    if ([string]::IsNullOrWhiteSpace($PackageDisplay)) {
        $lines += "NOTE  unfused: $PackageWhere declares no ARPDISPLAYVERSION, so there is no display number to keep apart"
    } elseif (Test-ArpVersionEqual $PackageDisplay $PackageProduct) {
        $failed += 'unfused'
        $lines += "FAIL  unfused: $PackageWhere declares ARPDISPLAYVERSION '$PackageDisplay' EQUAL to its ProductVersion - display and sequencing have been fused into one value"
    } else {
        $lines += "OK    unfused: display '$PackageDisplay' and sequencing '$PackageProduct' are still two numbers"
    }

    return [pscustomobject]@{
        Ok         = ($failed.Count -eq 0)
        Failed     = $failed
        Lines      = $lines
        Registered = $registered
    }
}

# --- readers (read-only) -----------------------------------------------------

$script:ArpUninstallRoots = @(
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
)

# Every Uninstall entry whose DisplayName is exactly -DisplayName. A per-user
# MSI's entry lands in HKLM on this box, so all three roots are searched.
function Find-ArpEntries {
    param(
        [Parameter(Mandatory = $true)][string]$DisplayName,
        [string[]]$Roots = $script:ArpUninstallRoots
    )
    $out = @()
    foreach ($root in $Roots) {
        foreach ($k in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
            if ($p -and [string]$p.DisplayName -eq $DisplayName) {
                $out += [pscustomobject]@{
                    Where          = "$root\$($k.PSChildName)"
                    ProductCode    = $k.PSChildName
                    DisplayVersion = [string]$p.DisplayVersion
                    Version        = $p.Version
                    Hidden         = ([int]($p.PSObject.Properties['SystemComponent'] | ForEach-Object { $_.Value }) -eq 1)
                }
            }
        }
    }
    return $out
}

# One row per product out of Find-ArpEntries' keys (T2168). Since T2168 a
# package writes two keys under one ProductCode: Windows' own registration,
# hidden from the list (SystemComponent=1) but still carrying the `Version`
# DWORD, and the HKCU entry a person sees, carrying the release number. A
# pre-T2168 package writes only the first, unhidden. Either way:
#
#   Shown           the keys Apps & Features LISTS for the product - exactly
#                   one is right; two is a duplicate line in the list, zero is
#                   a product nobody can find to remove.
#   DisplayVersion  what the listed key shows ('' when none is listed).
#   Version         the registration's DWORD, from whichever key carries it.
function Group-ArpProducts {
    param([object[]]$Entries = @())
    $out = @()
    foreach ($g in @($Entries | Group-Object -Property ProductCode)) {
        $shown = @($g.Group | Where-Object { -not $_.Hidden })
        $reg = @($g.Group | Where-Object { $null -ne $_.Version -and "$($_.Version)" -ne '' } | Select-Object -First 1)
        $out += [pscustomobject]@{
            ProductCode    = $g.Name
            Shown          = $shown
            DisplayVersion = $(if ($shown.Count -gt 0) { [string]$shown[0].DisplayVersion } else { '' })
            Version        = $(if ($reg.Count -gt 0) { $reg[0].Version } else { $null })
            Where          = (@($g.Group | ForEach-Object { $_.Where + $(if ($_.Hidden) { ' (hidden)' } else { '' }) }) -join ', ')
            DisplayWhere   = $(if ($shown.Count -gt 0) { $shown[0].Where } else { '' })
        }
    }
    return $out
}

# One Property row of an MSI, '' when absent. Opened read-only (mode 0).
function Get-ArpPackageProperty {
    param(
        [Parameter(Mandatory = $true)][string]$Package,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $inst = New-Object -ComObject WindowsInstaller.Installer
    $db = $inst.OpenDatabase($Package, 0)
    $v = $db.OpenView("SELECT ``Value`` FROM ``Property`` WHERE ``Property``='$Name'")
    try {
        [void]$v.Execute()
        $r = $v.Fetch()
        if ($null -eq $r) { return '' }
        return [string]$r.StringData(1)
    } finally {
        [void]$v.Close()
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($v)
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($db)
    }
}

# The cached package Windows installed a product from, '' when the product is
# not registered with Windows Installer (or its cache is gone).
function Get-ArpLocalPackage {
    param([Parameter(Mandatory = $true)][string]$ProductCode)
    try {
        $inst = New-Object -ComObject WindowsInstaller.Installer
        return [string]$inst.ProductInfo($ProductCode, 'LocalPackage')
    } catch { return '' }
}
