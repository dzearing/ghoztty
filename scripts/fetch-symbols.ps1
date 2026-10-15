<#
.SYNOPSIS
    Fetch the debug symbols for an installed (or any) Ghoztty build and print
    the symbol path that resolves its stacks (T1936).

.DESCRIPTION
    The MSI and the portable ZIP ship no .pdb (D64). Every win-v release
    since T1936 carries a third asset, Ghoztty-symbols-<version>-x64.zip,
    laid out as a symbol store (built by
    dist\windows-installer\build-symbols-zip.py). This script:

      1. works out which version the target exe is (its console twin's
         +version, or -Version),
      2. downloads that release's symbols zip (plain HTTPS; `gh` as a
         fallback) unless -ZipPath names one already on disk,
      3. unzips it into a per-version store under
         %LOCALAPPDATA%\ghoztty\symbols\<version>,
      4. reads the CodeView GUID/age out of the target exe and checks the
         store holds THAT pdb -- a store for a different build of the same
         version (a same-day republish) resolves nothing, and the debugger
         would say so only as "no symbols",
      5. prints the _NT_SYMBOL_PATH to use with cdb, WinDbg or WPA.

    Nothing is executed beyond `ghoztty.com +version`, which only prints, and
    nothing in the install directory is written.

    Exit codes: 0 = store ready and matches the exe; 1 = mismatch, or the
    release has no symbols asset; 2 = bad arguments / exe not found.

.PARAMETER Exe
    The image to symbolize. Default: the installed
    %LOCALAPPDATA%\Programs\Ghoztty\ghoztty.exe.

.PARAMETER Version
    X.Y.Z. Default: read from the exe's console twin (+version).

.PARAMETER ZipPath
    Use this symbols zip instead of downloading one.

.PARAMETER Dir
    Where to unpack the store. Default: %LOCALAPPDATA%\ghoztty\symbols\<version>.

.EXAMPLE
    powershell -NoProfile -File scripts\fetch-symbols.ps1
    $env:_NT_SYMBOL_PATH = '<the line it prints>'
    wpr -start CPU; <reproduce>; wpr -stop hot.etl   # then open hot.etl in WPA
#>
param(
    [string]$Exe = (Join-Path $env:LOCALAPPDATA 'Programs\Ghoztty\ghoztty.exe'),
    [string]$Version = '',
    [string]$ZipPath = '',
    [string]$Dir = '',
    [string]$Repo = 'dzearing/ghoztty'
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Exe)) {
    Write-Host "fetch-symbols: no image at $Exe (pass -Exe)"
    exit 2
}

# Read the symbol-store keys out of a PE image: the image key
# (TimeDateStamp + SizeOfImage) and the PDB key (CodeView GUID + age).
# Mirrors read_pe_identity in build-symbols-zip.py.
function Get-ImageSymbolKey([string]$Path) {
    $b = [IO.File]::ReadAllBytes($Path)
    $pe = [BitConverter]::ToInt32($b, 0x3C)
    $coff = $pe + 4
    $nSec = [BitConverter]::ToUInt16($b, $coff + 2)
    $optSize = [BitConverter]::ToUInt16($b, $coff + 16)
    $opt = $coff + 20
    $magic = [BitConverter]::ToUInt16($b, $opt)
    if ($magic -eq 0x20B) { $dirs = $opt + 112 } else { $dirs = $opt + 96 }
    $dbgRva = [BitConverter]::ToUInt32($b, $dirs + 48)
    $dbgSize = [BitConverter]::ToUInt32($b, $dirs + 52)
    $secBase = $opt + $optSize
    $dbgOff = -1
    for ($i = 0; $i -lt $nSec; $i++) {
        $s = $secBase + $i * 40
        $vsize = [BitConverter]::ToUInt32($b, $s + 8)
        $vaddr = [BitConverter]::ToUInt32($b, $s + 12)
        $rawSize = [BitConverter]::ToUInt32($b, $s + 16)
        $rawPtr = [BitConverter]::ToUInt32($b, $s + 20)
        $span = [Math]::Max($vsize, $rawSize)
        if ($dbgRva -ge $vaddr -and $dbgRva -lt ($vaddr + $span)) { $dbgOff = $dbgRva - $vaddr + $rawPtr }
    }
    if ($dbgOff -lt 0) { return $null }
    for ($i = 0; $i -lt [int]($dbgSize / 28); $i++) {
        $e = $dbgOff + $i * 28
        if ([BitConverter]::ToUInt32($b, $e + 12) -ne 2) { continue }
        $ptr = [BitConverter]::ToInt32($b, $e + 24)
        if ([Text.Encoding]::ASCII.GetString($b, $ptr, 4) -ne 'RSDS') { continue }
        $guidBytes = New-Object byte[] 16
        [Array]::Copy($b, $ptr + 4, $guidBytes, 0, 16)
        $guid = New-Object Guid (, $guidBytes)
        $age = [BitConverter]::ToUInt32($b, $ptr + 20)
        $end = [Array]::IndexOf($b, [byte]0, $ptr + 24)
        $pdbPath = [Text.Encoding]::UTF8.GetString($b, $ptr + 24, $end - $ptr - 24)
        return [pscustomobject]@{
            PdbName = ($pdbPath -split '[\\/]')[-1]
            PdbKey  = $guid.ToString('N').ToUpperInvariant() + ('{0:x}' -f $age)
        }
    }
    return $null
}

$key = Get-ImageSymbolKey $Exe
if ($null -eq $key) {
    Write-Host "fetch-symbols: $Exe carries no CodeView record - it was built stripped, and no PDB can match it"
    exit 1
}

if (-not $Version) {
    $twin = [IO.Path]::ChangeExtension($Exe, '.com')
    if (-not (Test-Path -LiteralPath $twin)) {
        Write-Host "fetch-symbols: cannot tell the version (no $twin to ask); pass -Version X.Y.Z"
        exit 2
    }
    $out = (& $twin +version 2>&1 | Out-String)
    if ($out -match '- version:\s*(\d+\.\d+\.\d+)\+') {
        $Version = $Matches[1]
    } else {
        Write-Host "fetch-symbols: $twin +version names no release version (a dev build has no published symbols):"
        Write-Host ('  ' + (($out -split "`n") | Where-Object { $_ -match 'version:' } | Select-Object -First 1).Trim())
        exit 1
    }
}
if ($Version -notmatch '^\d+\.\d+\.\d+$') { Write-Host "fetch-symbols: -Version must be X.Y.Z (got '$Version')"; exit 2 }

if (-not $Dir) { $Dir = Join-Path $env:LOCALAPPDATA "ghoztty\symbols\$Version" }
$asset = "Ghoztty-symbols-$Version-x64.zip"

if (-not $ZipPath) {
    $ZipPath = Join-Path $env:TEMP $asset
    $url = "https://github.com/$Repo/releases/download/win-v$Version/$asset"
    Write-Host "fetch-symbols: downloading $url"
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $ZipPath
    } catch {
        $gh = Get-Command gh -ErrorAction SilentlyContinue
        if ($gh) {
            # gh reports "no assets match" on stderr, which Stop would turn
            # into a terminating error before the message below explains it.
            $ErrorActionPreference = 'Continue'
            & gh release download "win-v$Version" --repo $Repo --pattern $asset --dir $env:TEMP --clobber 2>&1 | Out-Null
        }
        if (-not (Test-Path -LiteralPath $ZipPath)) {
            Write-Host "fetch-symbols: release win-v$Version has no $asset."
            Write-Host '  Releases published before T1936 (2026-10-14) shipped no symbols; nothing can symbolize them.'
            exit 1
        }
    }
}

New-Item -ItemType Directory -Force -Path $Dir | Out-Null
Expand-Archive -Force -LiteralPath $ZipPath -DestinationPath $Dir

$want = Join-Path $Dir ("{0}\{1}\{0}" -f $key.PdbName, $key.PdbKey)
if (-not (Test-Path -LiteralPath $want)) {
    $have = Get-ChildItem -LiteralPath (Join-Path $Dir $key.PdbName) -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Name }
    Write-Host "fetch-symbols: MISMATCH - $Exe needs $($key.PdbName) $($key.PdbKey),"
    Write-Host "  but the $Version store holds: $(@($have) -join ', ')"
    Write-Host '  (a different build of the same version, e.g. a same-day republish)'
    exit 1
}

$cache = Join-Path $env:LOCALAPPDATA 'ghoztty\symcache'
Write-Host "fetch-symbols: MATCH $($key.PdbName) $($key.PdbKey) in $Dir"
Write-Host ''
Write-Host "_NT_SYMBOL_PATH=srv*$Dir;srv*$cache*https://msdl.microsoft.com/download/symbols"
exit 0
