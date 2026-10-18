<#
.SYNOPSIS
    Read a published Windows release back from GitHub and check that what it
    is SERVING is a working Ghoztty (T1076).

.DESCRIPTION
    The release pipeline proves what it BUILT (dist/windows-installer and
    test\win32\release-artifacts.ps1) and what it DELIVERED to the local
    install locations (deliver-windows-build.ps1). Until this script nothing
    asked GitHub what it is actually handing out, so a broken download was only
    ever found by whoever downloaded it. T1065 had to hand-roll this readback
    in a scratchpad to close its own validation; this is that script, kept.

    It downloads the MSI and the portable ZIP of a win-v release (or reads a
    directory that already holds them) and checks:

      assets   both are attached, named for the tag's version, and the bytes
               on disk are as long as GitHub says they are
      zip      opens; one Ghoztty\ root; the app, its console twin, the agent,
               the terminfo sentinel and READ-ME-FIRST are all in it; no .pdb;
               ghoztty.exe is a GUI binary (2) and ghoztty.com a console one
               (3) - a console ghoztty.exe is a Debug build
      msi      opens through the Windows Installer COM API (no Docker, no
               msitools); its File table carries ghoztty.exe, ghoztty.com and
               ghoztty-agent.exe at one shared, non-empty version; the
               ARPDISPLAYVERSION it shows in Apps & Features is the tag's
      cross    the ZIP's binaries and the MSI's File table carry the same
               build, and that build is the commit the tag points at - the two
               downloads are one release, not two

    The verdict is an exit code, because the point is that it can say no:

      0  OK        every check passed
      3  BROKEN    at least one check failed; each one is named
      4  NOASK     the release could not be fetched at all (no gh, no
                   network, no such release). Distinct from BROKEN on purpose:
                   one is an answer, the other is the absence of one
      1  ERROR     something in this script broke

    Read-only: nothing is installed, executed or uploaded. The binaries are
    inspected by header and version resource, never run.

.PARAMETER Tag
    Release tag to verify (default: the newest win-v* release on -Repo).

.PARAMETER AssetDir
    Verify files already on disk instead of downloading. The harness uses this.

.PARAMETER ReleaseJson
    With -AssetDir: a file shaped like `gh release view --json assets` plus an
    optional "commit" field, standing in for what GitHub would report. Without
    it the size and commit checks are reported as not asked.

.EXAMPLE
    powershell -NoProfile -File scripts\verify-release-assets.ps1
    powershell -NoProfile -File scripts\verify-release-assets.ps1 -Tag win-v1.39.25
#>
[CmdletBinding()]
param(
    [string]$Tag,
    [string]$Repo = 'dzearing/ghoztty',
    [string]$AssetDir,
    [string]$ReleaseJson,
    [string]$WorkDir,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$EXIT_OK = 0
$EXIT_ERROR = 1
$EXIT_BROKEN = 3
$EXIT_NOASK = 4

. (Join-Path $PSScriptRoot 'delivery-manifest.ps1')   # Get-PeSubsystem

function Write-Line([string]$Text) {
    if (-not $Quiet) { Write-Host $Text }
}

$script:broken = New-Object System.Collections.Generic.List[string]
$script:passed = 0

function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) {
        $script:passed++
        Write-Line "  ok      $Name"
    } else {
        $line = $Name
        if ($Detail) { $line = "${Name}: $Detail" }
        $script:broken.Add($line)
        Write-Line "  BROKEN  $line"
    }
}

function NotAsked([string]$Name, [string]$Why) {
    Write-Line "  -       $Name (not asked: $Why)"
}

# MSI FileName is `SHORT~1.EXT|long name` when a short name exists, else the
# long name alone (msitools writes the latter).
function Get-LongFileName([string]$FileName) {
    $bar = $FileName.IndexOf('|')
    if ($bar -ge 0) { return $FileName.Substring($bar + 1) }
    return $FileName
}

# Read the File and Property tables, then let go of every handle: a view or a
# database object still referenced keeps the file open, and the work dir is
# deleted on the way out.
function Read-MsiTables([string]$Path) {
    $installer = New-Object -ComObject WindowsInstaller.Installer
    $db = $null
    $files = @{}
    $props = @{}
    try {
        $db = $installer.OpenDatabase($Path, 0)   # msiOpenDatabaseModeReadOnly
        foreach ($q in @(
                @{ sql = 'SELECT FileName, Version FROM File'; into = $files; long = $true },
                @{ sql = 'SELECT Property, Value FROM Property'; into = $props; long = $false })) {
            $view = $db.OpenView($q.sql)
            try {
                [void]$view.Execute()
                while ($true) {
                    $rec = $view.Fetch()
                    if ($null -eq $rec) { break }
                    $k = $rec.StringData(1)
                    if ($q.long) { $k = Get-LongFileName $k }
                    $q.into[$k] = $rec.StringData(2)
                    [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($rec)
                }
                [void]$view.Close()
            } finally {
                [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($view)
            }
        }
    } finally {
        if ($db) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($db) }
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($installer)
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
    }
    return @{ files = $files; props = $props }
}

# ------------------------------------------------------------ collect assets
$work = $WorkDir
if (-not $work) {
    $work = Join-Path $env:TEMP ("ghoztty-assets-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
}
$createdWork = $false
$release = $null    # @{ assets = @(@{name;size}); commit }

try {
    if (-not (Test-Path -LiteralPath $work)) {
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        $createdWork = $true
    }

    if ($AssetDir) {
        if (-not (Test-Path -LiteralPath $AssetDir)) {
            Write-Host "ERROR asset dir not found: $AssetDir" -ForegroundColor Red
            exit $EXIT_ERROR
        }
        $src = (Resolve-Path -LiteralPath $AssetDir).Path
        $label = "dir:$src"
        if ($ReleaseJson) {
            $release = Get-Content -LiteralPath $ReleaseJson -Raw | ConvertFrom-Json
        }
    } else {
        if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
            Write-Line "NOASK gh is not on PATH; cannot fetch release assets"
            exit $EXIT_NOASK
        }
        if (-not $Tag) {
            $list = & gh release list --repo $Repo --limit 30 2>$null
            if ($LASTEXITCODE -ne 0) {
                Write-Line "NOASK could not list releases on $Repo (gh exit $LASTEXITCODE)"
                exit $EXIT_NOASK
            }
            foreach ($line in $list) {
                $m = [regex]::Match($line, '(?<tag>win-v[0-9][^\s]*)')
                if ($m.Success) { $Tag = $m.Groups['tag'].Value; break }
            }
            if (-not $Tag) {
                Write-Line "NOASK no win-v* release found on $Repo"
                exit $EXIT_NOASK
            }
        }
        $label = "$Repo@$Tag"
        $viewJson = & gh release view $Tag --repo $Repo --json assets 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Line "NOASK GitHub has no release $Tag on $Repo (gh exit $LASTEXITCODE)"
            exit $EXIT_NOASK
        }
        try { $release = ($viewJson | Out-String) | ConvertFrom-Json } catch { $release = $null }
        if (-not $release -or -not ($release.PSObject.Properties.Name -contains 'assets')) {
            Write-Line "NOASK GitHub answered for $Tag but not with a release listing"
            exit $EXIT_NOASK
        }
        $sha = & gh api "repos/$Repo/commits/$Tag" --jq .sha 2>$null
        if ($LASTEXITCODE -eq 0 -and $sha) {
            $release | Add-Member -NotePropertyName commit -NotePropertyValue (($sha | Out-String).Trim()) -Force
        }
        $src = Join-Path $work 'download'
        New-Item -ItemType Directory -Path $src -Force | Out-Null
        Write-Line "downloading $Tag ..."
        & gh release download $Tag --repo $Repo --dir $src --pattern '*.msi' `
            --pattern 'Ghoztty-portable-*.zip' --clobber 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Line "NOASK could not download the assets of $Tag (gh exit $LASTEXITCODE)"
            exit $EXIT_NOASK
        }
    }

    # The version the release claims to be. From the tag when there is one,
    # else from the MSI's own name (a directory handed in by the harness).
    $version = $null
    if ($Tag) {
        $m = [regex]::Match($Tag, '^win-v(?<v>\d+\.\d+\.\d+)$')
        if ($m.Success) { $version = $m.Groups['v'].Value }
    }
    if (-not $version) {
        $msiGuess = Get-ChildItem -LiteralPath $src -Filter 'Ghoztty-*-x64.msi' -File | Select-Object -First 1
        if ($msiGuess) {
            $m = [regex]::Match($msiGuess.Name, '^Ghoztty-(?<v>\d+\.\d+\.\d+)-x64\.msi$')
            if ($m.Success) { $version = $m.Groups['v'].Value }
        }
    }

    Write-Line "release: $label"
    if (-not $version) {
        Check 'assets: the release names a version' $false "no win-vX.Y.Z tag and no Ghoztty-X.Y.Z-x64.msi"
        Write-Line ""
        Write-Line "BROKEN 1 check(s) failed: cannot tell which version this release is"
        exit $EXIT_BROKEN
    }
    Write-Line "version: $version"

    # ---------------------------------------------------------------- assets
    $msiName = "Ghoztty-$version-x64.msi"
    $zipName = "Ghoztty-portable-$version-x64.zip"
    $msiPath = Join-Path $src $msiName
    $zipPath = Join-Path $src $zipName
    $haveMsi = Test-Path -LiteralPath $msiPath
    $haveZip = Test-Path -LiteralPath $zipPath
    Check "assets: $msiName is attached" $haveMsi
    Check "assets: $zipName is attached" $haveZip

    if ($release -and ($release.PSObject.Properties.Name -contains 'assets')) {
        foreach ($pair in @(@($msiName, $msiPath, $haveMsi), @($zipName, $zipPath, $haveZip))) {
            if (-not $pair[2]) { continue }
            $remote = @($release.assets | Where-Object { $_.name -eq $pair[0] }) | Select-Object -First 1
            if (-not $remote) {
                Check "assets: GitHub lists $($pair[0])" $false 'not in the release asset list'
                continue
            }
            $local = (Get-Item -LiteralPath $pair[1]).Length
            Check "assets: $($pair[0]) is the $($remote.size) bytes GitHub reports" `
                ([int64]$local -eq [int64]$remote.size) "got $local bytes"
        }
    } else {
        NotAsked 'assets: sizes match GitHub' 'no release listing'
    }

    # ------------------------------------------------------------------- zip
    $zipExeVersion = $null
    $zipComVersion = $null
    if ($haveZip) {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $za = $null
        try { $za = [IO.Compression.ZipFile]::OpenRead($zipPath) } catch { $za = $null }
        Check 'zip: opens as an archive' ($null -ne $za)
        if ($za) {
            try {
                $names = @($za.Entries | ForEach-Object { $_.FullName })
                $roots = @($names | ForEach-Object { ($_ -split '/')[0] } | Sort-Object -Unique)
                Check 'zip: a single Ghoztty\ root' (($roots -join ',') -eq 'Ghoztty') "roots: $($roots -join ', ')"
                foreach ($need in @('Ghoztty/ghoztty.exe', 'Ghoztty/ghoztty.com', 'Ghoztty/ghoztty-agent.exe',
                        'Ghoztty/share/terminfo/ghostty.terminfo', 'Ghoztty/READ-ME-FIRST.txt')) {
                    Check "zip: carries $need" ($names -contains $need)
                }
                $pdbs = @($names | Where-Object { $_ -match '\.pdb$' })
                Check 'zip: no .pdb (symbols ship separately)' ($pdbs.Count -eq 0) ($pdbs -join ', ')

                $x = Join-Path $work 'zip-bin'
                New-Item -ItemType Directory -Path $x -Force | Out-Null
                foreach ($bin in @(@('ghoztty.exe', 2), @('ghoztty.com', 3), @('ghoztty-agent.exe', 0))) {
                    $entry = $za.Entries | Where-Object { $_.FullName -eq "Ghoztty/$($bin[0])" } | Select-Object -First 1
                    if (-not $entry) { continue }
                    $out = Join-Path $x $bin[0]
                    [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $out, $true)
                    $sub = Get-PeSubsystem $out
                    if ($bin[1] -eq 0) {
                        Check "zip: $($bin[0]) is a Windows binary" ($sub -ne 0) 'no readable PE header'
                    } else {
                        $kind = if ($bin[1] -eq 2) { 'GUI' } else { 'console' }
                        Check "zip: $($bin[0]) is a $kind binary (subsystem $($bin[1]))" ($sub -eq $bin[1]) "subsystem $sub"
                    }
                    $fv = [Diagnostics.FileVersionInfo]::GetVersionInfo($out)
                    $v = '{0}.{1}.{2}.{3}' -f $fv.FileMajorPart, $fv.FileMinorPart, $fv.FileBuildPart, $fv.FilePrivatePart
                    if ($bin[0] -eq 'ghoztty.exe') { $zipExeVersion = $v }
                    if ($bin[0] -eq 'ghoztty.com') { $zipComVersion = $v }
                }
            } finally {
                $za.Dispose()
            }
        }
    }

    # ------------------------------------------------------------------- msi
    $msi = $null
    if ($haveMsi) {
        try { $msi = Read-MsiTables $msiPath } catch { $msi = $null; $msiErr = $_.Exception.Message }
        $openDetail = ''
        if (-not $msi) { $openDetail = $msiErr }
        Check 'msi: opens as a Windows Installer database' ($null -ne $msi) $openDetail
    }
    $msiVersion = $null
    if ($msi) {
        $vers = @()
        foreach ($n in @('ghoztty.exe', 'ghoztty.com', 'ghoztty-agent.exe')) {
            $has = $msi.files.ContainsKey($n)
            Check "msi: installs $n" $has
            if ($has) {
                $v = $msi.files[$n]
                Check "msi: $n carries a file version" ([bool]$v) 'empty Version column - an upgrade would not replace it'
                $vers += [pscustomobject]@{ name = $n; version = $v }
            }
        }
        $distinct = @($vers | ForEach-Object { $_.version } | Sort-Object -Unique)
        if ($vers.Count -gt 1) {
            Check 'msi: the app, its twin and the agent are one build' ($distinct.Count -eq 1) `
                (($vers | ForEach-Object { "$($_.name)=$($_.version)" }) -join ', ')
        }
        $exeRow = @($vers | Where-Object { $_.name -eq 'ghoztty.exe' }) | Select-Object -First 1
        if ($exeRow) { $msiVersion = $exeRow.version }

        $arp = $null
        if ($msi.props.ContainsKey('ARPDISPLAYVERSION')) { $arp = $msi.props['ARPDISPLAYVERSION'] }
        Check "msi: Apps & Features will show $version" ($arp -eq $version) "ARPDISPLAYVERSION=$arp"
    }

    # ----------------------------------------------------------------- cross
    if ($msiVersion -and $zipExeVersion) {
        Check 'cross: the ZIP and the MSI carry the same ghoztty.exe build' ($zipExeVersion -eq $msiVersion) `
            "zip $zipExeVersion, msi $msiVersion"
    }
    if ($msiVersion -and $zipComVersion) {
        Check 'cross: the ZIP and the MSI carry the same ghoztty.com build' ($zipComVersion -eq $msiVersion) `
            "zip $zipComVersion, msi $msiVersion"
    }
    $expectCommit = $null
    if ($release -and ($release.PSObject.Properties.Name -contains 'commit') -and $release.commit) {
        $expectCommit = [string]$release.commit
    }
    if ($msi -and $expectCommit) {
        $comments = ''
        if ($msi.props.ContainsKey('ARPCOMMENTS')) { $comments = $msi.props['ARPCOMMENTS'] }
        $m = [regex]::Match($comments, 'Build \d{8}-(?<c>[0-9a-f]{7,40})')
        $built = if ($m.Success) { $m.Groups['c'].Value } else { '' }
        $same = $built -and $expectCommit.StartsWith($built, [StringComparison]::OrdinalIgnoreCase)
        Check "cross: the MSI was built from the tagged commit $($expectCommit.Substring(0, [Math]::Min(9, $expectCommit.Length)))" `
            ([bool]$same) "ARPCOMMENTS='$comments'"
    } elseif ($msi) {
        NotAsked 'cross: the MSI was built from the tagged commit' 'no tag commit to compare'
    }

    # ---------------------------------------------------------------- verdict
    Write-Line ""
    if ($script:broken.Count -gt 0) {
        Write-Line "BROKEN $($script:broken.Count) check(s) failed on ${label}:"
        foreach ($b in $script:broken) { Write-Line "  - $b" }
        exit $EXIT_BROKEN
    }
    Write-Line "OK $($script:passed) check(s) passed: $label is serving a working Ghoztty $version."
    exit $EXIT_OK
} catch {
    Write-Host "ERROR $($_.Exception.Message)" -ForegroundColor Red
    exit $EXIT_ERROR
} finally {
    if ($createdWork -and -not $WorkDir -and (Test-Path -LiteralPath $work)) {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}
