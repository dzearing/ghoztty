<#
.SYNOPSIS
  Acceptance test for the release symbols asset (T1936):
  dist\windows-installer\build-symbols-zip.py, scripts\fetch-symbols.ps1, and
  their wiring into the release.

.DESCRIPTION
  The MSI and the portable ZIP ship no .pdb (D64), and until T1936 nothing kept
  the PDBs of a shipped build anywhere: a stack from a user's hot or hung
  ghoztty.exe was bare ghoztty+0x... offsets, for good. Every win-v release now
  publishes Ghoztty-symbols-<version>-x64.zip, a symbol store.

  The failure this guards is silent by construction. A store that holds the
  WRONG pdb (a rebuild between the packages and the symbols, a stale zig-out)
  looks complete and resolves nothing, and the debugger reports only "no
  symbols". So the identity check is tested from both sides: real pairs MATCH,
  and an image whose CodeView GUID or age has been tampered with is REFUSED,
  both by the packager (which then leaves no zip) and by the fetch script.

  Uses the zig-out debug build's ghoztty.exe/.com/ghoztty-agent.exe and their
  PDBs; it launches nothing but cdb (section E, skipped when WinDbg is not
  installed) and ghoztty.com +version. No window, no agent, no IPC.

  ASCII-only by design (PS 5.1 on this box mangles non-ASCII on rewrite).

  powershell -NoProfile -File test\win32\release-symbols.ps1
#>
# isolation: none - the only CLI call is ghoztty.com +version (via fetch-symbols.ps1 D5), which prints and touches no pipe
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$script:passes = 0
$script:failures = 0
$script:skips = 0
function Assert($name, $cond, $detail = '') {
    if ($cond) {
        "  PASS $name"
        $script:passes++
    } else {
        "  FAIL $name$(if ($detail) { " -- $detail" })"
        $script:failures++
    }
}
function Skip($name, $why) { "  SKIP $name -- $why"; $script:skips++ }

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$bin = Join-Path $repo 'zig-out\bin'
$packager = Join-Path $repo 'dist\windows-installer\build-symbols-zip.py'
$fetch = Join-Path $repo 'scripts\fetch-symbols.ps1'
$work = Join-Path $env:TEMP ("ghoztty-release-symbols-" + [guid]::NewGuid().ToString('N').Substring(0, 8))

$py = $null
foreach ($c in @('py', 'python3', 'python')) {
    $cmd = Get-Command $c -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source -notmatch 'WindowsApps') { $py = $cmd.Source; break }
}

# Run the packager; returns @{ Code; Out }.
function Invoke-Packager([string[]]$ArgList) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = (& $py $packager @ArgList 2>&1 | ForEach-Object { "$_" } | Out-String)
        return @{ Code = $LASTEXITCODE; Out = $out }
    } finally { $ErrorActionPreference = $prev }
}
function Invoke-Fetch([string[]]$ArgList) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = (& powershell -NoProfile -ExecutionPolicy Bypass -File $fetch @ArgList 2>&1 | ForEach-Object { "$_" } | Out-String)
        return @{ Code = $LASTEXITCODE; Out = $out }
    } finally { $ErrorActionPreference = $prev }
}

# A copy of $Src whose CodeView record has one byte flipped at $Offset past
# 'RSDS' (+4 = GUID, +20 = age). The image is otherwise byte-identical, so it is
# exactly the "right name, wrong build" shape a debugger silently rejects.
function New-TamperedImage([string]$Src, [string]$Dst, [int]$Offset) {
    $b = [IO.File]::ReadAllBytes($Src)
    # The bytes 'RSDS' also occur as data (std's PDB reader carries the
    # constant), so the record is the occurrence whose path ends in the PDB
    # name. Latin-1 maps every byte to one char, so string offsets are byte
    # offsets and IndexOf does the scan natively.
    $text = [Text.Encoding]::GetEncoding(28591).GetString($b)
    $want = [IO.Path]::GetFileNameWithoutExtension($Src) + '.pdb'
    $at = -1
    $i = $text.IndexOf('RSDS', [StringComparison]::Ordinal)
    while ($i -ge 0) {
        $end = $text.IndexOf([char]0, $i + 24)
        if ($end -gt 0 -and ($end - $i) -lt 600 -and $text.Substring($i + 24, $end - $i - 24) -like "*$want") { $at = $i; break }
        $i = $text.IndexOf('RSDS', $i + 4, [StringComparison]::Ordinal)
    }
    if ($at -lt 0) { throw "no RSDS record in $Src" }
    $b[$at + $Offset] = $b[$at + $Offset] -bxor 0x5A
    [IO.File]::WriteAllBytes($Dst, $b)
}

try {
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    $exe = Join-Path $bin 'ghoztty.exe'
    $com = Join-Path $bin 'ghoztty.com'
    $pdb = Join-Path $bin 'ghoztty.pdb'
    $agent = Join-Path $bin 'ghoztty-agent.exe'
    $agentPdb = Join-Path $bin 'ghoztty-agent.pdb'
    $have = @($exe, $com, $pdb, $agent, $agentPdb) | Where-Object { -not (Test-Path -LiteralPath $_) }

    # --- F. wiring (static; runs even without a build) --------------------
    ''
    '-- F. the release produces and publishes the asset'
    $bra = Get-Content -Raw (Join-Path $repo 'dist\windows-installer\build-release-artifacts.sh')
    Assert 'F1 build-release-artifacts.sh runs the packager' ($bra -match 'build-symbols-zip\.py')
    Assert 'F2 ... over all three shipped images' `
        (($bra -match 'ghoztty\.exe" "\$BIN/ghoztty\.pdb') -and ($bra -match 'ghoztty\.com" "\$BIN/ghoztty\.pdb') -and ($bra -match 'ghoztty-agent\.exe" "\$BIN/ghoztty-agent\.pdb'))
    Assert 'F3 ... and fails the build when the zip is missing' ($bra -match 'for f in "\$MSI" "\$ZIP" "\$SYMBOLS"')
    $wf = Get-Content -Raw (Join-Path $repo '.github\workflows\release-windows.yml')
    Assert 'F4 release-windows.yml uploads it onto an existing release' ($wf -match 'gh release upload "\$TAG" "\$MSI" "\$ZIP" "\$SYMBOLS"')
    Assert 'F5 ... and attaches it to a new one' ($wf -match '"\$MSI" "\$ZIP" "\$SYMBOLS"\s*\r?\n\s*fi')
    # F6: the release workflow is the ONLY publisher that attaches assets. The
    # on-box -Local publish used to attach the symbols zip too; it was retired in
    # T1328, so there is no second upload list left to fall out of step with F4/F5.
    Assert 'F6 no on-box publisher is left to attach assets' `
        (-not (Test-Path -LiteralPath (Join-Path $repo 'scripts\publish-windows-release.ps1')))

    if ($have) {
        Skip 'A-E' "no debug build to package (missing: $($have -join ', ')) - run zig build -Dapp-runtime=win32 -Doptimize=Debug"
    } elseif (-not $py) {
        Skip 'A-E' 'no Python on PATH (py/python3/python)'
    } else {
        $badGuid = Join-Path $work 'guid\ghoztty.exe'
        $badAge = Join-Path $work 'age\ghoztty.exe'
        New-Item -ItemType Directory -Force -Path (Split-Path $badGuid), (Split-Path $badAge) | Out-Null
        New-TamperedImage $exe $badGuid 4
        New-TamperedImage $exe $badAge 20

        # --- A. identity ---------------------------------------------------
        ''
        '-- A. an image and its own PDB match'
        $r = Invoke-Packager @('--ids', $exe, $pdb)
        Assert 'A1 ghoztty.exe + ghoztty.pdb MATCH' (($r.Code -eq 0) -and ($r.Out -match '^MATCH ')) $r.Out.Trim()
        $r = Invoke-Packager @('--ids', $com, $pdb)
        Assert 'A2 ghoztty.com resolves through the same ghoztty.pdb' (($r.Code -eq 0) -and ($r.Out -match '^MATCH ')) $r.Out.Trim()
        $r = Invoke-Packager @('--ids', $agent, $agentPdb)
        Assert 'A3 ghoztty-agent.exe + ghoztty-agent.pdb MATCH' (($r.Code -eq 0) -and ($r.Out -match '^MATCH ')) $r.Out.Trim()

        # --- B. refusal ----------------------------------------------------
        ''
        '-- B. a PDB that is not the image''s own is refused'
        $r = Invoke-Packager @('--ids', $badGuid, $pdb)
        Assert 'B1 an image whose GUID differs is refused' (($r.Code -eq 1) -and ($r.Out -match 'PDB GUID')) $r.Out.Trim()
        $r = Invoke-Packager @('--ids', $badAge, $pdb)
        Assert 'B2 an image whose age differs is refused' (($r.Code -eq 1) -and ($r.Out -match 'PDB age')) $r.Out.Trim()
        $r = Invoke-Packager @('--ids', $exe, $agentPdb)
        Assert 'B3 the wrong PDB file is refused by name' (($r.Code -eq 1) -and ($r.Out -match 'names its PDB')) $r.Out.Trim()

        # --- C. the zip ----------------------------------------------------
        ''
        '-- C. the zip is a symbol store, and a bad pair leaves none'
        $zip = Join-Path $work 'Ghoztty-symbols-9.9.9-x64.zip'
        $r = Invoke-Packager @('--out', $zip, '--semver', '9.9.9', '--commit', 'abc1234',
            '--pair', $exe, $pdb, '--pair', $com, $pdb, '--pair', $agent, $agentPdb)
        Assert 'C1 the packager succeeds over the three shipped pairs' (($r.Code -eq 0) -and (Test-Path -LiteralPath $zip)) $r.Out.Trim()
        if (Test-Path -LiteralPath $zip) {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $z = [IO.Compression.ZipFile]::OpenRead($zip)
            try { $names = @($z.Entries | ForEach-Object { $_.FullName }) } finally { $z.Dispose() }
            $exeKey = (Invoke-Packager @('--ids', $exe, $pdb)).Out -replace '(?s)^MATCH image=(\S+) pdb=(\S+).*$', '$1|$2'
            $ik, $pk = $exeKey.Split('|')
            Assert 'C2 the PDB sits at <name>.pdb/<GUID+age>/<name>.pdb' ($names -contains "ghoztty.pdb/$pk/ghoztty.pdb") ($names -join ', ')
            Assert 'C3 the image sits at <name>.exe/<stamp+size>/<name>.exe' ($names -contains "ghoztty.exe/$ik/ghoztty.exe") ($names -join ', ')
            Assert 'C4 the shared ghoztty.pdb is stored once, not per image' (@($names | Where-Object { $_ -like 'ghoztty.pdb/*' }).Count -eq 1) ($names -join ', ')
            Assert 'C5 seven entries: 3 images, 2 PDBs, symbols.json, README.txt' ($names.Count -eq 7) ($names -join ', ')
            $unz = Join-Path $work 'store'
            Expand-Archive -Force -LiteralPath $zip -DestinationPath $unz
            $man = Get-Content -Raw (Join-Path $unz 'symbols.json') | ConvertFrom-Json
            Assert 'C6 symbols.json names the version, commit and all three images' `
                (($man.semver -eq '9.9.9') -and ($man.commit -eq 'abc1234') -and (@($man.store).Count -eq 3)) ''
        }
        $bad = Join-Path $work 'Ghoztty-symbols-bad-x64.zip'
        $r = Invoke-Packager @('--out', $bad, '--semver', '9.9.9', '--pair', $agent, $agentPdb, '--pair', $badGuid, $pdb)
        Assert 'C7 one bad pair fails the whole build' ($r.Code -eq 1) $r.Out.Trim()
        Assert 'C8 ... and leaves no zip (or temp) behind, even for the good pair before it' `
            (-not (Test-Path -LiteralPath $bad) -and -not (Test-Path -LiteralPath "$bad.tmp")) ''

        # --- D. fetch-symbols ------------------------------------------------
        ''
        '-- D. fetch-symbols.ps1 checks the store against the exe it is for'
        $fdir = Join-Path $work 'fetched'
        $r = Invoke-Fetch @('-Exe', $exe, '-Version', '9.9.9', '-ZipPath', $zip, '-Dir', $fdir)
        Assert 'D1 the matching exe: MATCH, exit 0' (($r.Code -eq 0) -and ($r.Out -match 'MATCH ghoztty\.pdb')) $r.Out.Trim()
        Assert 'D2 ... and it prints a srv* symbol path naming the store' ($r.Out -match ('_NT_SYMBOL_PATH=srv\*' + [regex]::Escape($fdir) + ';')) $r.Out.Trim()
        $r = Invoke-Fetch @('-Exe', $agent, '-Version', '9.9.9', '-ZipPath', $zip, '-Dir', $fdir)
        Assert 'D3 the agent: MATCH' (($r.Code -eq 0) -and ($r.Out -match 'MATCH ghoztty-agent\.pdb')) $r.Out.Trim()
        $r = Invoke-Fetch @('-Exe', $badGuid, '-Version', '9.9.9', '-ZipPath', $zip, '-Dir', $fdir)
        Assert 'D4 a different build of the same version: MISMATCH, exit 1' (($r.Code -eq 1) -and ($r.Out -match 'MISMATCH')) $r.Out.Trim()
        $r = Invoke-Fetch @('-Exe', $exe)
        Assert 'D5 a dev build with no -Version is told it has no published symbols' (($r.Code -eq 1) -and ($r.Out -match 'no release version')) $r.Out.Trim()

        # --- E. a debugger resolves from it ----------------------------------
        ''
        '-- E. cdb names Ghoztty frames from the store alone'
        $cdb = $env:GHOZTTY_CDB
        if (-not $cdb) { $cdb = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\Microsoft.WinDbg_8wekyb3d8bbwe\cdbX64.exe' }
        if (-not (Test-Path -LiteralPath $cdb)) {
            Skip 'E1-E2' 'no cdb (install WinDbg, or set GHOZTTY_CDB)'
        } else {
            # The image alone, the way the installer lays it down: no PDB beside it.
            $inst = Join-Path $work 'install'
            New-Item -ItemType Directory -Force -Path $inst, (Join-Path $work 'empty') | Out-Null
            Copy-Item -LiteralPath $exe -Destination $inst
            $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
            # SYMOPT_IGNORE_CVREC (0x80): a dev build's CodeView record names
            # its PDB by absolute path, which cdb would otherwise open directly.
            # On a user's box that path does not exist, so ignoring it is the
            # faithful setup, and it makes the control below a real control.
            $cmd = '.symopt+ 0x80; .reload /f; lm m ghoztty; q'
            $with = (& $cdb -z (Join-Path $inst 'ghoztty.exe') -y "srv*$fdir" -c $cmd 2>&1 | ForEach-Object { "$_" } | Out-String)
            $without = (& $cdb -z (Join-Path $inst 'ghoztty.exe') -y (Join-Path $work 'empty') -c $cmd 2>&1 | ForEach-Object { "$_" } | Out-String)
            $ErrorActionPreference = $prev
            Assert 'E1 with the store: private pdb symbols, loaded FROM the store' `
                (($with -match 'ghoztty\s+\S*\s*\(private pdb symbols\)\s+(\S+)') -and ($Matches[1] -like ($fdir.ToLowerInvariant() + '\ghoztty.pdb\*'))) ''
            # A dev build has an export table, so its control reads "export
            # symbols"; a shipped one reads "no symbols". Neither is a PDB.
            Assert 'E2 control: without it, no PDB symbols' `
                (($without -match 'ghoztty\s+\S*\s*\((no|export) symbols\)') -and ($without -notmatch 'private pdb symbols')) ''
        }
    }

    Complete-TestBody
}
finally {
    if (Test-Path -LiteralPath $work) { Remove-Item -Recurse -Force -LiteralPath $work -ErrorAction SilentlyContinue }
}

if ($script:failures -eq 0 -and $script:skips -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard release-symbols -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

''
Write-TestVerdict -Label 'T1936 RELEASE SYMBOLS' -Pass $script:passes -Fail $script:failures -Skipped $script:skips