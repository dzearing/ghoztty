# T1210 acceptance: what Apps & Features shows for an installed Ghoztty is read
# off the machine and held against the package that installed it.
#
# T1205 split the package's version in two - ProductVersion (yy.m.dNN, the
# sequencing number) and ARPDISPLAYVERSION (the release semver, the number a
# person should see) - and proved the split at the recipe: build-msi.sh, the
# release-artifacts statics, verify-release-assets. Nothing read the registry
# entry Windows actually writes. The first read (2026-10-22) found the user's
# win-v1.43.3 install showing 26.10.2290: Windows Installer does not honour the
# property. That defect is T2168; this harness is the check that sees it.
#
#   A. The verdict, pure: fixtures for agree / today's mismatch / a moved
#      sequencing number / display and sequencing fused into one value / the
#      pre-T1205 package with no display number. Every FAIL line names the
#      surface it read (registry or package) and both numbers.
#   B. The CLI end to end against a FIXTURE install: an Uninstall key under
#      HKCU:\Software\GhozttyT1210Test and a fixture MSI holding only a Property
#      table. Exit 0 / 1 / 3, and the lines name the key and the package path.
#   C. LIVE, READ-ONLY: the user's installed Ghoztty, through the same CLI.
#      Reads the registry and the cached MSI; writes nothing. Red until T2168
#      ships (acked to it); SKIP on a box with no installed Ghoztty.
#
#   -NegativeControl adds one inverted assertion a healthy run MUST fail.
#
# Non-interactive: no window, no install, no msiexec. The only write is the
# fixture key under HKCU:\Software\GhozttyT1210Test, removed in the finally.
[CmdletBinding(PositionalBinding = $false)]
param([switch]$NegativeControl)

$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$check = Join-Path $repo 'scripts\arp-version-check.ps1'

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $repo 'scripts\lib\ArpVersion.ps1')

$script:fail = 0
$script:pass = 0
$script:skipped = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" }
}
function Skip([string]$label, [string]$why) {
    $script:skipped++
    Write-Host "SKIP  $label ($why)"
}

# 26.10.2290 as the Uninstall key's Version DWORD: 26<<24 | 10<<16 | 2290.
$dw = 436865266

# Runs the CLI in a child and returns its exit code and output. Output is
# redirected to a file and read back rather than piped (a piped child's exit
# code is the pipe's, not its own).
function Invoke-Check([string[]]$CheckArgs) {
    # stdout and stderr to separate files as the child wrote them, each read back
    # whole (T883: a PowerShell redirect of a native stderr writes ErrorRecords
    # formatted to the host's width). -Wait holds the process handle, so the
    # exit code survives the child's exit.
    $stem = Join-Path $work ("check-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
    $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$check`"") +
        @($CheckArgs | ForEach-Object { "`"$_`"" })
    $p = Start-Process powershell -ArgumentList $argv -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput "$stem.out" -RedirectStandardError "$stem.err"
    $code = $p.ExitCode
    $text = ''
    foreach ($f in @("$stem.out", "$stem.err")) {
        if (Test-Path -LiteralPath $f) { $text += [IO.File]::ReadAllText($f) }
    }
    return [pscustomobject]@{ Code = $code; Text = $text }
}

# A Windows Installer database holding only a Property table. Built in a child
# process: the automation object only reliably lets go of the file when the
# process that opened it exits.
function New-FixtureMsi([string]$Path, [hashtable]$Props) {
    $rows = ($Props.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ';'
    $env:GHOZTTY_T1210_MSI = $Path
    $env:GHOZTTY_T1210_ROWS = $rows
    & powershell -NoProfile -Command {
        $db = (New-Object -ComObject WindowsInstaller.Installer).OpenDatabase($env:GHOZTTY_T1210_MSI, 3)
        $v = $db.OpenView('CREATE TABLE `Property` (`Property` CHAR(72) NOT NULL, `Value` LONGCHAR NOT NULL LOCALIZABLE PRIMARY KEY `Property`)')
        [void]$v.Execute(); [void]$v.Close()
        foreach ($pair in ($env:GHOZTTY_T1210_ROWS -split ';')) {
            $k, $val = $pair -split '=', 2
            $v = $db.OpenView("INSERT INTO ``Property`` (``Property``, ``Value``) VALUES ('$k', '$val')")
            [void]$v.Execute(); [void]$v.Close()
        }
        [void]$db.Commit()
    } *> $null
    Remove-Item Env:\GHOZTTY_T1210_MSI, Env:\GHOZTTY_T1210_ROWS -ErrorAction SilentlyContinue
    return (Test-Path -LiteralPath $Path)
}

$fixtureRoot = 'HKCU:\Software\GhozttyT1210Test'
$fixtureUninst = "$fixtureRoot\Uninstall"
$fixtureName = 'GhozttyT1210Test'
$fixtureCode = '{7D1E1210-0000-4000-8000-000000001210}'
$work = Join-Path ([IO.Path]::GetTempPath()) ("t1210-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $work | Out-Null

try {
Write-Host '--- A. the verdict, pure ---'
Assert ((ConvertFrom-ArpVersionDword -Value $dw) -eq '26.10.2290') 'A1 the Version DWORD decodes to 26.10.2290'
Assert ((ConvertFrom-ArpVersionDword -Value ([int32]-2130706432)) -eq '129.0.0') 'A2 a major >= 128 (negative as Int32) decodes unsigned'

$ok = Get-ArpVersionVerdict -DisplayVersion '1.43.3' -VersionDword $dw -PackageDisplay '1.43.3' -PackageProduct '26.10.2290'
Assert ($ok.Ok) "A3 display 1.43.3 over a 1.43.3 / 26.10.2290 package is OK ($($ok.Failed -join ','))"

$today = Get-ArpVersionVerdict -DisplayVersion '26.10.2290' -VersionDword $dw -PackageDisplay '1.43.3' -PackageProduct '26.10.2290' `
    -RegistryWhere 'HKLM:\X' -PackageWhere 'C:\pkg.msi'
Assert (-not $today.Ok -and (@($today.Failed) -join ',') -eq 'display') "A4 today's shape (shows 26.10.2290, asked for 1.43.3) fails on display alone ($($today.Failed -join ','))"
$line = @($today.Lines | Where-Object { $_ -like 'FAIL  display*' }) -join ''
Assert ($line -match "'26\.10\.2290'" -and $line -match "'1\.43\.3'" -and $line -match 'HKLM:\\X' -and $line -match 'C:\\pkg\.msi') `
    "A5 its FAIL line names both numbers and both surfaces ($line)"

$moved = Get-ArpVersionVerdict -DisplayVersion '1.43.3' -VersionDword $dw -PackageDisplay '1.43.3' -PackageProduct '26.10.2291'
Assert ((@($moved.Failed) -join ',') -eq 'sequencing') "A6 a registered ProductVersion that is not the package's fails on sequencing ($($moved.Failed -join ','))"

$fused = Get-ArpVersionVerdict -DisplayVersion '26.10.2290' -VersionDword $dw -PackageDisplay '26.10.2290' -PackageProduct '26.10.2290'
Assert ((@($fused.Failed) -join ',') -eq 'unfused') "A7 a package whose display number IS its ProductVersion fails on unfused, not passes on display ($($fused.Failed -join ','))"

$old = Get-ArpVersionVerdict -DisplayVersion '26.8.3109' -VersionDword 436735013 -PackageDisplay '' -PackageProduct '26.8.3109'
Assert ($old.Ok) "A8 a pre-T1205 package (no display number) showing its ProductVersion is OK ($($old.Failed -join ','))"
Assert ((@($old.Lines) -join "`n") -match 'declares no ARPDISPLAYVERSION') 'A9 ... and says why the display check used ProductVersion'

Assert (Test-ArpVersionEqual '1.43' '1.43.0') 'A10 1.43 and 1.43.0 are the same number'
Assert (-not (Test-ArpVersionEqual '' '')) 'A11 two empty values never count as agreeing'

Write-Host '--- B. the CLI, against a fixture install ---'
$msiOk = Join-Path $work 'fixture.msi'
$built = New-FixtureMsi -Path $msiOk -Props @{ ProductVersion = '26.10.2290'; ARPDISPLAYVERSION = '1.43.3'; ProductName = $fixtureName }
Assert $built 'B1 the fixture MSI was created'
Assert ((Get-ArpPackageProperty -Package $msiOk -Name 'ARPDISPLAYVERSION') -eq '1.43.3') 'B2 its Property table reads back through the same reader the check uses'

$key = "$fixtureUninst\$fixtureCode"
New-Item -Path $key -Force | Out-Null
New-ItemProperty -Path $key -Name DisplayName -Value $fixtureName -PropertyType String -Force | Out-Null
New-ItemProperty -Path $key -Name Version -Value $dw -PropertyType DWord -Force | Out-Null

New-ItemProperty -Path $key -Name DisplayVersion -Value '1.43.3' -PropertyType String -Force | Out-Null
$r = Invoke-Check @('-DisplayName', $fixtureName, '-Roots', $fixtureUninst, '-Package', $msiOk)
Assert ($r.Code -eq 0 -and $r.Text -match 'ARP VERSION OK') "B3 an entry showing the package's display number exits 0 (exit $($r.Code))"

New-ItemProperty -Path $key -Name DisplayVersion -Value '26.10.2290' -PropertyType String -Force | Out-Null
$r = Invoke-Check @('-DisplayName', $fixtureName, '-Roots', $fixtureUninst, '-Package', $msiOk)
Assert ($r.Code -eq 1 -and $r.Text -match 'ARP VERSION MISMATCH') "B4 the 2026-10-22 shape exits 1 (exit $($r.Code))"
Assert ($r.Text -match [regex]::Escape("$fixtureUninst\$fixtureCode") -and $r.Text -match [regex]::Escape($msiOk)) `
    'B5 ... and its output names the registry key and the package it read'

$r = Invoke-Check @('-DisplayName', 'GhozttyT1210Absent', '-Roots', $fixtureUninst, '-Package', $msiOk)
Assert ($r.Code -eq 3 -and $r.Text -match 'NOT INSTALLED') "B6 no such product exits 3, never 0 (exit $($r.Code))"

$r = Invoke-Check @('-DisplayName', $fixtureName, '-Roots', $fixtureUninst, '-Package', (Join-Path $work 'missing.msi'))
Assert ($r.Code -eq 1 -and $r.Text -match 'no cached package') "B7 an entry with no package to hold it against fails, never passes (exit $($r.Code))"

Write-Host '--- C. live, read-only: the installed Ghoztty ---'
$live = @(Find-ArpEntries -DisplayName 'Ghoztty')
if ($live.Count -eq 0) {
    Skip 'C1 the installed Ghoztty shows the release number' 'no Ghoztty is installed on this box'
} else {
    $r = Invoke-Check @()
    $r.Text -split "`r?`n" | Where-Object { $_ -match '\S' } | ForEach-Object { Write-Host "      $_" }
    Assert ($r.Code -eq 0) "C1 the installed Ghoztty shows the release number in Apps & Features (exit $($r.Code); red until T2168)"
}

if ($NegativeControl) {
    Assert ($ok.Ok -eq $false) 'NEGATIVE CONTROL: the agreeing fixture must not be flagged (this must FAIL)'
}

Complete-TestBody  # T1039: the run reached the end of its body
} finally {
    # Only this run's own fixture key and folder.
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    if ($work -and (Test-Path $work)) { Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue }
}

# --- stamp (T783) -----------------------------------------------------------
if ($script:fail -eq 0 -and $script:skipped -eq 0 -and -not $NegativeControl -and (Test-TestBodyComplete)) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard arp-version -Repo $repo | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Skipped $script:skipped -Label 'ARP-VERSION' -MinPass 18
