# The USER-INSTALL SENTINEL (T3394) - proof, measured on every run, that a
# harness which runs a REAL msiexec never reached the user's installed Ghoztty.
#
# Why it exists: on 2026-11-22 a release build running inside a test sandbox
# ran msiexec against the shipping product (T3388). Windows Installer state is
# per-user, not per-LOCALAPPDATA, so the sandbox did nothing to stop it: the
# installer reconfigured the user's real product and renamed
# %LOCALAPPDATA%\Programs\Ghoztty\ghoztty-agent.exe aside with no fresh copy
# written back. The harnesses that run msiexec ON PURPOSE (update-real-msi,
# update-graceful) already install a throwaway product identity, but nothing
# REFUSED the install when that rewrite had not taken, and their "user's
# install untouched" check was a file count plus the exe's mtime - which reads
# the 2026-11-22 damage (one file renamed aside, nothing rewritten) as clean.
#
# Three pieces, each one function so a harness can call it in one line:
#
#   Get-PackageUserProductReach  BEFORE msiexec: every way a package could act
#                                on the shipping product (its UpgradeCode, an
#                                Upgrade-table row naming the shipping code, a
#                                ProductCode the user has installed, the
#                                shipping ProductName). Empty = safe to run.
#   Get-UserInstallSnapshot      before and after: the user's registered
#   Compare-UserInstallSnapshot  product(s) and version, plus every file of
#                                the install (path, length, mtime) and a
#                                SHA-256 of the three live images. A diff is
#                                the user's install having moved.
#   Get-UserProductInstallerEvents  after: any MsiInstaller event in the
#                                Application log naming the shipping product
#                                since the run began - the direct record of a
#                                reconfigure, which is what 1035 was that day.
#
# Everything here only READS the user's install. Nothing in this file writes,
# renames or deletes anything outside the caller's own directories.

Set-StrictMode -Off

# The shipping product's UpgradeCode (packaging/windows, unchanged since the
# first MSI) and its ProductName. A throwaway identity has neither.
$script:ShippingUpgradeCode = '{5EB02044-7F06-498B-B7A9-7EFD65486CFB}'
$script:ShippingProductName = 'Ghoztty'

# The images a broken install would be missing. Hashed, not just stat'ed: an
# in-place rewrite that kept the length and the mtime is still a rewrite.
$script:UserInstallLiveImages = @('ghoztty.exe', 'ghoztty.com', 'ghoztty-agent.exe')

function Get-MsiTableRows {
    <#
      Every row of one query against a package, as strings joined by ' | '.
      Field reads go through InvokeMember: StringData is a parameterized
      property, and PowerShell's own binding of it inside a pipeline hands back
      the method object instead of the value.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Msi,
        [Parameter(Mandatory = $true)][string]$Query
    )
    $inst = New-Object -ComObject WindowsInstaller.Installer
    $db = $inst.OpenDatabase($Msi, 0)
    $rows = @()
    $v = $null
    try {
        $v = $db.OpenView($Query)
        [void]$v.Execute()
        while ($true) {
            $r = $v.Fetch()
            if ($null -eq $r) { break }
            $n = [int]$r.GetType().InvokeMember('FieldCount', 'GetProperty', $null, $r, $null)
            $fields = @()
            for ($i = 1; $i -le $n; $i++) {
                $fields += [string]$r.GetType().InvokeMember('StringData', 'GetProperty', $null, $r, @($i))
            }
            $rows += ($fields -join ' | ')
        }
    } catch {
        # A package with no Upgrade table is legal; say nothing rather than
        # inventing a row.
    } finally {
        if ($v) { [void]$v.Close(); [void][Runtime.InteropServices.Marshal]::ReleaseComObject($v) }
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($db)
    }
    return $rows
}

function Get-UserProductCodes {
    <# The ProductCodes Windows Installer has registered under the shipping UpgradeCode, for this user. #>
    $inst = New-Object -ComObject WindowsInstaller.Installer
    $out = @()
    try { foreach ($c in $inst.RelatedProducts($script:ShippingUpgradeCode)) { $out += [string]$c } } catch {}
    return $out
}

function Get-PackageUserProductReach {
    <#
      Every way $Msi could act on the user's installed product. Returns the
      reasons as strings; an EMPTY result is the only answer that permits
      running msiexec on it. A package that cannot be opened at all is a reason
      too - "could not check" must never read as "checked and safe".
    #>
    param([Parameter(Mandatory = $true)][string]$Msi)
    $why = @()
    if (-not (Test-Path -LiteralPath $Msi)) { return @("package not found: $Msi") }
    $props = @{}
    try {
        foreach ($row in @(Get-MsiTableRows -Msi $Msi -Query "SELECT ``Property``,``Value`` FROM ``Property``")) {
            $kv = $row -split ' \| ', 2
            if ($kv.Count -eq 2) { $props[$kv[0]] = $kv[1] }
        }
    } catch {
        return @("package could not be opened to check its identity: $_")
    }
    if (-not $props.ContainsKey('UpgradeCode') -or -not $props.ContainsKey('ProductCode')) {
        return @('package identity unreadable (no UpgradeCode/ProductCode in its Property table)')
    }
    if ($props['UpgradeCode'] -eq $script:ShippingUpgradeCode) {
        $why += "its UpgradeCode is the shipping product's ($($props['UpgradeCode']))"
    }
    if ($props['ProductName'] -eq $script:ShippingProductName) {
        $why += "its ProductName is the shipping product's ('$($props['ProductName'])')"
    }
    # A major upgrade removes every product the Upgrade table names, whatever
    # the package's own UpgradeCode is - so a rewrite that moved the identity
    # and left this table alone would uninstall the user's terminal.
    foreach ($row in @(Get-MsiTableRows -Msi $Msi -Query "SELECT ``UpgradeCode`` FROM ``Upgrade``")) {
        if ($row -eq $script:ShippingUpgradeCode) {
            $why += "its Upgrade table names the shipping UpgradeCode, so installing it would upgrade or remove the user's product"
            break
        }
    }
    foreach ($c in @(Get-UserProductCodes)) {
        if ($c -eq $props['ProductCode']) {
            $why += "its ProductCode $c is the user's installed product (msiexec would reconfigure it)"
        }
    }
    return $why
}

function Get-UserInstallSnapshot {
    <#
      What the user's install IS, as sorted lines, so before/after is a plain
      set difference. `$Dir` defaults to the real install; the self-test points
      it at a scratch directory instead.

      `*.old-*` files are listed by NAME ONLY and left out of the comparison's
      file lines: the user's own running app sweeps those at its next startup
      (update_install.sweep), so a sidelined image disappearing mid-run is the
      user's terminal doing its job, not the test reaching it. A sidelined
      image APPEARING is caught anyway - the live image it was renamed from is
      then missing or different.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Dir,
        [switch]$NoProducts
    )
    $lines = @()
    if (-not $NoProducts) {
        $inst = New-Object -ComObject WindowsInstaller.Installer
        foreach ($c in @(Get-UserProductCodes)) {
            $ver = try { [string]$inst.ProductInfo($c, 'VersionString') } catch { '?' }
            $pkg = try { [string]$inst.ProductInfo($c, 'LocalPackage') } catch { '?' }
            $lines += "product $c version=$ver package=$pkg"
        }
    }
    if (-not (Test-Path -LiteralPath $Dir)) {
        $lines += 'dir missing'
        return [pscustomobject]@{ Dir = $Dir; Taken = Get-Date; Lines = $lines }
    }
    $root = (Resolve-Path -LiteralPath $Dir).Path.TrimEnd('\')
    foreach ($f in @(Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue)) {
        $rel = $f.FullName.Substring($root.Length + 1)
        if ($f.Name -match '\.old-\d+$') { continue }
        $lines += "file $rel len=$($f.Length) mtime=$($f.LastWriteTimeUtc.Ticks)"
    }
    foreach ($img in $script:UserInstallLiveImages) {
        $p = Join-Path $root $img
        if (Test-Path -LiteralPath $p) {
            $h = try { (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash } catch { 'unreadable' }
            $lines += "hash $img $h"
        } else {
            $lines += "hash $img absent"
        }
    }
    return [pscustomobject]@{ Dir = $Dir; Taken = Get-Date; Lines = @($lines | Sort-Object) }
}

function Compare-UserInstallSnapshot {
    <#
      The lines that differ, '-' for gone and '+' for new. Empty means the
      install is what it was. Returned joined by newlines so an empty answer
      survives the trip out of a function intact (an empty array does not).
    #>
    param(
        [Parameter(Mandatory = $true)]$Before,
        [Parameter(Mandatory = $true)]$After
    )
    $b = @{}; foreach ($l in $Before.Lines) { $b[$l] = $true }
    $a = @{}; foreach ($l in $After.Lines) { $a[$l] = $true }
    $diff = @()
    foreach ($l in $Before.Lines) { if (-not $a.ContainsKey($l)) { $diff += "- $l" } }
    foreach ($l in $After.Lines) { if (-not $b.ContainsKey($l)) { $diff += "+ $l" } }
    return ($diff -join "`n")
}

function Test-UserProductEventMessage {
    <#
      Whether one MsiInstaller event message is about the SHIPPING product.
      Exact product name only: a throwaway identity is named
      Ghoztty<Something>Test, and "Product Name: Ghoztty." must not match it.
    #>
    param([string]$Message)
    if (-not $Message) { return $false }
    return ($Message -match "Product Name:\s*$([regex]::Escape($script:ShippingProductName))\s*[.,]")
}

function Get-UserProductInstallerEvents {
    <#
      MsiInstaller events naming the shipping product since $Since, one line
      each. These are the installer's own record that it acted on the user's
      product - 1035 (reconfigured) was the 2026-11-22 entry - and they are
      written whether or not any file changed.

      An unreadable log returns a single 'unknown: ...' line rather than an
      empty answer: "could not look" must not read as "nothing happened".
    #>
    param([Parameter(Mandatory = $true)][datetime]$Since)
    $out = @()
    try {
        $evs = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'MsiInstaller'; StartTime = $Since } -ErrorAction Stop)
    } catch {
        if ("$_" -match 'No events were found') { return '' }
        return "unknown: the Application log could not be read ($_)"
    }
    foreach ($e in $evs) {
        $msg = "$($e.Message)"
        if (Test-UserProductEventMessage -Message $msg) {
            $flat = ($msg -replace '\s+', ' ')
            if ($flat.Length -gt 220) { $flat = $flat.Substring(0, 220) }
            $out += "$($e.TimeCreated.ToString('HH:mm:ss')) id=$($e.Id) $flat"
        }
    }
    return ($out -join "`n")
}
