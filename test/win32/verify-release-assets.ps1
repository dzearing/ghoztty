# A published release, read back, and the proof the readback can say no (T1076).
#
# The release pipeline proves what it built and what it copied locally, never
# what GitHub is serving: a broken download was only ever found by whoever
# downloaded it, and T1065 had to hand-roll the readback to close its own
# validation. scripts\verify-release-assets.ps1 is that readback kept, and
# daily-publish runs it once per release, when a pushed tag is confirmed real.
#
# A checker that has only ever been observed saying "OK" is indistinguishable
# from one that cannot say anything else (go.md, T1133), so every defect it
# exists to catch is CONSTRUCTED here, one at a time, and the exit code and the
# named check are asserted.
#
# What this asserts:
#
#   A  a well-formed synthetic release (a real ZIP, a real MSI database built
#      through the Windows Installer COM API, real PE binaries) -> exit 0
#   B  each defect, alone -> exit 3 with that check named: a missing asset, a
#      truncated download, a Debug ghoztty.exe, a .pdb in the ZIP, an
#      unreadable MSI, an unversioned or mismatched agent row, a wrong
#      Apps & Features version, the ZIP and MSI disagreeing about the build,
#      and an MSI built from a commit other than the tag's
#   C  NOASK: no gh at all -> exit 4, and never the word OK
#   D  parses under PS 5.1, is ASCII, and the release readback really calls it
#
# Offline: no network, nothing installed, nothing launched. A few seconds.
#
#   powershell -NoProfile -File test\win32\verify-release-assets.ps1
#   powershell -NoProfile -File test\win32\verify-release-assets.ps1 -NegativeControl
param(
    [string]$Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path,
    # Proof this harness can score red: breaks the expectations on purpose.
    [switch]$NegativeControl
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:failures = 0
$script:skipped = 0
$script:passes = 0

function Assert($name, $cond) {
    if ($NegativeControl) { $cond = -not $cond }
    if ($cond) { "  PASS $name"; $script:passes++ } else { "  FAIL $name"; $script:failures++ }
}
function AssertEq($name, $expected, $actual) {
    $ok = ($expected -eq $actual)
    if ($NegativeControl) { $ok = -not $ok }
    if ($ok) { "  PASS $name"; $script:passes++ }
    else { "  FAIL $name (expected '$expected', got '$actual')"; $script:failures++ }
}

$checker = Join-Path $Repo 'scripts\verify-release-assets.ps1'
$tmp = Join-Path $env:TEMP ("release-assets-test-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$Version = '9.9.9'
$Commit = 'abcdef1234567890abcdef1234567890abcdef12'

# ---------------------------------------------------------------------------
# Synthetic binaries. A small inbox Windows executable stands in for each one:
# it has a real PE header and a real version resource, which are the two things
# the checker reads. The subsystem WORD is patched to say GUI or console.
# ---------------------------------------------------------------------------
$donor = Join-Path $env:SystemRoot 'System32\whoami.exe'
$fv = [Diagnostics.FileVersionInfo]::GetVersionInfo($donor)
$BuildVersion = '{0}.{1}.{2}.{3}' -f $fv.FileMajorPart, $fv.FileMinorPart, $fv.FileBuildPart, $fv.FilePrivatePart

function New-PeBytes([int]$Subsystem) {
    $b = [IO.File]::ReadAllBytes($donor)
    $peOff = [BitConverter]::ToInt32($b, 0x3C)
    $w = [BitConverter]::GetBytes([uint16]$Subsystem)
    $b[$peOff + 0x5C] = $w[0]
    $b[$peOff + 0x5D] = $w[1]
    return , $b
}

function New-Zip {
    param([string]$Path, [hashtable]$Entries)
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
    $fs = [IO.File]::Open($Path, 'CreateNew')
    $za = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($k in $Entries.Keys) {
            $e = $za.CreateEntry($k)
            $s = $e.Open()
            try { $bytes = [byte[]]$Entries[$k]; $s.Write($bytes, 0, $bytes.Length) } finally { $s.Dispose() }
        }
    } finally { $za.Dispose(); $fs.Dispose() }
}

function Get-GoodZipEntries {
    $ascii = [Text.Encoding]::ASCII
    return @{
        'Ghoztty/ghoztty.exe'                     = (New-PeBytes 2)
        'Ghoztty/ghoztty.com'                     = (New-PeBytes 3)
        'Ghoztty/ghoztty-agent.exe'               = (New-PeBytes 3)
        'Ghoztty/share/terminfo/ghostty.terminfo' = $ascii.GetBytes('terminfo')
        'Ghoztty/READ-ME-FIRST.txt'               = $ascii.GetBytes('read me')
    }
}

# A real Windows Installer database with just the two tables the checker reads.
function Invoke-MsiSql($Db, [string]$Sql) {
    $v = $Db.OpenView($Sql)
    [void]$v.Execute()
    [void]$v.Close()
    [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($v)
}
function New-Msi {
    param([string]$Path, [hashtable]$Files, [hashtable]$Props)
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
    $installer = New-Object -ComObject WindowsInstaller.Installer
    $db = $installer.OpenDatabase($Path, 3)   # msiOpenDatabaseModeCreate
    try {
        Invoke-MsiSql $db 'CREATE TABLE `File` (`File` CHAR(72) NOT NULL, `FileName` CHAR(255) NOT NULL, `Version` CHAR(72) PRIMARY KEY `File`)'
        Invoke-MsiSql $db 'CREATE TABLE `Property` (`Property` CHAR(72) NOT NULL, `Value` LONGCHAR NOT NULL PRIMARY KEY `Property`)'
        $i = 0
        foreach ($k in $Files.Keys) {
            $i++
            Invoke-MsiSql $db ("INSERT INTO ``File`` (``File``, ``FileName``, ``Version``) VALUES ('f{0}', '{1}', '{2}')" -f $i, $k, $Files[$k])
        }
        foreach ($k in $Props.Keys) {
            Invoke-MsiSql $db ("INSERT INTO ``Property`` (``Property``, ``Value``) VALUES ('{0}', '{1}')" -f $k, $Props[$k])
        }
        [void]$db.Commit()
    } finally {
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($db)
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($installer)
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
    }
}

function Get-GoodMsiFiles {
    return @{
        'GHOZTT~1.EXE|ghoztty.exe' = $BuildVersion
        'GHOZTT~1.COM|ghoztty.com' = $BuildVersion
        'GHOZTT~2.EXE|ghoztty-agent.exe' = $BuildVersion
        'composer.css' = ''
    }
}
function Get-GoodMsiProps {
    return @{
        ARPDISPLAYVERSION = $Version
        ARPCOMMENTS       = "Build 20261017-$($Commit.Substring(0, 9))"
    }
}

# One release directory per case: the assets, plus the release.json that stands
# in for what GitHub reports about them.
$script:case = 0
function New-Release {
    param(
        [hashtable]$ZipEntries = (Get-GoodZipEntries),
        [hashtable]$MsiFiles = (Get-GoodMsiFiles),
        [hashtable]$MsiProps = (Get-GoodMsiProps),
        [string]$ReportedCommit = $Commit,
        [scriptblock]$Mutate = $null
    )
    $script:case++
    $dir = Join-Path $tmp ("case{0}" -f $script:case)
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $zip = Join-Path $dir "Ghoztty-portable-$Version-x64.zip"
    $msi = Join-Path $dir "Ghoztty-$Version-x64.msi"
    New-Zip -Path $zip -Entries $ZipEntries
    New-Msi -Path $msi -Files $MsiFiles -Props $MsiProps
    $assets = @(Get-ChildItem -LiteralPath $dir -File | ForEach-Object { @{ name = $_.Name; size = $_.Length } })
    if ($Mutate) { & $Mutate $dir $zip $msi }
    $json = @{ assets = $assets; commit = $ReportedCommit } | ConvertTo-Json -Depth 4
    $relJson = Join-Path $tmp ("case{0}.json" -f $script:case)
    [IO.File]::WriteAllText($relJson, $json, (New-Object Text.UTF8Encoding($false)))
    return @{ dir = $dir; json = $relJson }
}

function Invoke-Checker {
    param($Release, [string[]]$ExtraArgs = @(), [hashtable]$Env = $null)
    $argsList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $checker, '-Tag', "win-v$Version")
    if ($Release) { $argsList += @('-AssetDir', $Release.dir, '-ReleaseJson', $Release.json) }
    $argsList += $ExtraArgs
    $saved = @{}
    if ($Env) { foreach ($k in $Env.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $Env[$k]) } }
    try {
        # STDOUT ONLY (T883): the checker says everything on stdout, and a
        # merged stderr is host-formatted text an oracle must not read.
        $out = & (Join-Path $PSHOME 'powershell.exe') @argsList | Out-String
        $code = $LASTEXITCODE
    } finally {
        foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
    }
    return @{ Exit = $code; Text = $out }
}

function Assert-Broken {
    param([string]$Id, [string]$What, $Release, [string]$Named)
    $r = Invoke-Checker -Release $Release
    AssertEq "$Id $What -> exit 3" 3 $r.Exit
    Assert "$Id and the failed check is named ($Named)" ($r.Text -match ('BROKEN\s+' + $Named))
}

# ============================================================================
"== A: a well-formed release reads back OK"
# ============================================================================
$good = New-Release
$r = Invoke-Checker -Release $good
AssertEq 'A1 good release -> exit 0' 0 $r.Exit
Assert 'A2 the verdict line says OK' ($r.Text -match "(?m)^OK \d+ check\(s\) passed")
Assert 'A3 sizes were checked against the reported listing' ($r.Text -match 'bytes GitHub reports')
Assert 'A4 the tagged commit was compared' ($r.Text -match 'ok\s+cross: the MSI was built from the tagged commit')
Assert 'A5 the ZIP/MSI build cross-check ran' ($r.Text -match 'ok\s+cross: the ZIP and the MSI carry the same ghoztty\.exe build')

# ============================================================================
"== B: every defect it exists to catch, one at a time"
# ============================================================================
$rel = New-Release -Mutate { param($d, $z, $m) Remove-Item -LiteralPath $z -Force }
Assert-Broken 'B1' 'the portable ZIP is missing' $rel 'assets: Ghoztty-portable-9\.9\.9-x64\.zip is attached'

$rel = New-Release -Mutate {
    param($d, $z, $m)
    $b = [IO.File]::ReadAllBytes($z)
    [IO.File]::WriteAllBytes($z, $b[0..([int]($b.Length / 2))])
}
Assert-Broken 'B2' 'a truncated download' $rel 'assets: Ghoztty-portable-9\.9\.9-x64\.zip is the \d+ bytes GitHub reports'
Assert 'B2b and the truncated archive does not open' ((Invoke-Checker -Release $rel).Text -match 'BROKEN\s+zip: opens as an archive')

$e = Get-GoodZipEntries; $e['Ghoztty/ghoztty.exe'] = (New-PeBytes 3)
Assert-Broken 'B3' 'a Debug (console) ghoztty.exe in the ZIP' (New-Release -ZipEntries $e) 'zip: ghoztty\.exe is a GUI binary'

$e = Get-GoodZipEntries; $e['Ghoztty/ghoztty.pdb'] = [Text.Encoding]::ASCII.GetBytes('pdb')
Assert-Broken 'B4' 'symbols inside the portable ZIP' (New-Release -ZipEntries $e) 'zip: no \.pdb'

$e = Get-GoodZipEntries; $e.Remove('Ghoztty/ghoztty.com')
Assert-Broken 'B5' 'the console twin left out of the ZIP' (New-Release -ZipEntries $e) 'zip: carries Ghoztty/ghoztty\.com'

$rel = New-Release -Mutate { param($d, $z, $m) [IO.File]::WriteAllText($m, 'not an msi') }
Assert-Broken 'B6' 'an MSI that is not a database' $rel 'msi: opens as a Windows Installer database'

$f = Get-GoodMsiFiles; $f['GHOZTT~2.EXE|ghoztty-agent.exe'] = ''
Assert-Broken 'B7' 'an agent row with no file version' (New-Release -MsiFiles $f) 'msi: ghoztty-agent\.exe carries a file version'

$f = Get-GoodMsiFiles; $f['GHOZTT~2.EXE|ghoztty-agent.exe'] = '1.0.0.1'
Assert-Broken 'B8' 'an agent from a different build than the app' (New-Release -MsiFiles $f) 'msi: the app, its twin and the agent are one build'

$f = Get-GoodMsiFiles; $f.Remove('GHOZTT~2.EXE|ghoztty-agent.exe')
Assert-Broken 'B9' 'an MSI that does not install the agent' (New-Release -MsiFiles $f) 'msi: installs ghoztty-agent\.exe'

$p = Get-GoodMsiProps; $p['ARPDISPLAYVERSION'] = '9.9.8'
Assert-Broken 'B10' 'Apps & Features showing the wrong version' (New-Release -MsiProps $p) 'msi: Apps & Features will show 9\.9\.9'

$f = Get-GoodMsiFiles
foreach ($k in @($f.Keys)) { if ($f[$k]) { $f[$k] = '1.2.3.4' } }
Assert-Broken 'B11' 'the ZIP and the MSI from different builds' (New-Release -MsiFiles $f) 'cross: the ZIP and the MSI carry the same ghoztty\.exe build'

Assert-Broken 'B12' 'an MSI built from a commit other than the tag''s' `
    (New-Release -ReportedCommit '0123456789abcdef0123456789abcdef01234567') 'cross: the MSI was built from the tagged commit'

# ============================================================================
"== C: no way to ask is NOASK, never OK"
# ============================================================================
# Network mode with gh unreachable: PATH holds only Windows itself.
$r = Invoke-Checker -Release $null -Env @{ PATH = (Join-Path $env:SystemRoot 'System32') }
AssertEq 'C1 no gh on PATH -> exit 4' 4 $r.Exit
Assert 'C2 and it says NOASK' ($r.Text -match 'NOASK')
Assert 'C3 and never OK' ($r.Text -notmatch '(?m)^OK ')

# ============================================================================
"== D: parse, ASCII and wiring"
# ============================================================================
$parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile($checker, [ref]$null, [ref]$parseErrors) | Out-Null
AssertEq 'D1 checker parses cleanly under PS 5.1' 0 (@($parseErrors).Count)
$nonAscii = @([IO.File]::ReadAllBytes($checker) | Where-Object { $_ -gt 127 })
AssertEq 'D2 checker is ASCII' 0 $nonAscii.Count

# The readback belongs where a release becomes real: daily-publish's
# confirmation pass, once per release rather than the once somebody remembered.
$publish = Get-Content -LiteralPath (Join-Path $Repo 'scripts\daily-publish.ps1') -Raw
Assert 'D3 the release readback calls the checker' ($publish -match 'verify-release-assets\.ps1')

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue

# A clean green run stamps the covered files (T783).
Complete-TestBody
if (-not $NegativeControl -and $script:failures -eq 0 -and $script:skipped -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard verify-release-assets -Repo $Repo 2>&1 | ForEach-Object { "  $_" }
}

""
Write-TestVerdict -Pass $script:passes -Fail $script:failures -Skipped $script:skipped
