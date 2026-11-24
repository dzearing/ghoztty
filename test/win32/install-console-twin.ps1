# The installer derives ghoztty.com instead of carrying it (T2071).
#
# THE CHANGE. ghoztty.com is ghoztty.exe with one PE header word flipped
# (Subsystem 2 -> 3, src/apprt/win32/console_twin.zig), and it is what a bare
# `ghoztty` on the PATH runs (PATHEXT prefers .COM; T245/T1052). The MSI used to
# carry it as a second full copy - about 20 MB of every download, since no
# cabinet compressor looks back 35 MB to notice two files are the same. Now the
# package carries ghoztty.exe once and two deferred DLL actions in
# ghoztty-msi-ca.dll write the twin after InstallFiles and delete it before
# RemoveFiles on uninstall.
#
# WHAT GOES WRONG IF THE WIRING SLIPS, and nobody sees it: an install where
# a bare `ghoztty` verb from PowerShell answers with silence (T1052 again), or an
# uninstall that leaves the install directory behind with the twin in it. Both
# only ever show up on a user's machine.
#
# WHAT THIS HARNESS PROVES, with no Docker and no msitools (this box cannot
# build an MSI; fork-ci does on every push):
#
#   A  the recipe: build-msi.sh no longer emits a File row for the twin, the
#      wxs declares both actions deferred + impersonated + ignore-return from
#      the package's own DLL, sequenced by NUMBER on the right side of
#      InstallFiles / RemoveFiles (T1367), and the DLL exports both entry
#      points. -TeethCheck breaks each surface and watches its check go red.
#   E  the build-time read-back, EXTRACTED from build-msi.sh and fed synthetic
#      tables: a correctly wired package passes and every shape it exists to
#      catch is refused - so what is demonstrated is what ships.
#   F  the File-table version patch refuses a package that carries the twin
#      again.
#
# What it does NOT prove: a real msiexec install. The derive/remove code is
# exercised against a real directory by the unit tests in console_twin.zig
# (win32 lane), and the installed result - ghoztty.com present beside the exe
# after install, repair and upgrade, gone after uninstall - is asserted by
# test\win32\install-walkthrough.ps1 against a real package.
#
#   powershell -NoProfile -File test\win32\install-console-twin.ps1
#   powershell -NoProfile -File test\win32\install-console-twin.ps1 -TeethCheck
#
# preflight: none - reads source files and runs python over text tables; it
# launches no ghoztty and touches no install.

param(
    [string]$Repo = 'D:\git\ghoztty',
    [switch]$TeethCheck
)

$ErrorActionPreference = 'Continue'
Set-StrictMode -Off

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:passes = 0
$script:failures = 0
$script:skipped = 0
function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ }
    else { "  FAIL $name"; $script:failures++ }
}
function Skip($name, $why) { "  SKIP $name ($why)"; $script:skipped++ }

$paths = [ordered]@{
    msi   = 'dist\windows-installer\build-msi.sh'
    ca    = 'src\apprt\win32\install_ca.zig'
    twin  = 'src\apprt\win32\console_twin.zig'
    patch = 'src\build\patch_subsystem_main.zig'
    exe   = 'src\build\GhosttyExe.zig'
    tests = 'src\apprt\win32\install_maintenance.zig'
}
$text = [ordered]@{}
foreach ($k in $paths.Keys) {
    $p = Join-Path $Repo $paths[$k]
    if (-not (Test-Path -LiteralPath $p)) {
        "FATAL: missing $p"
        Write-TestVerdict -Pass $script:passes -Fail 1 -Skipped $script:skipped -Label 'install-console-twin'
        exit 1
    }
    $text[$k] = (Get-Content -LiteralPath $p -Raw)
}

# ---------------------------------------------------------------------------
# A - the recipe. Each check reads the shipped text; each mutation is the
# smallest edit that would break the invariant, and -TeethCheck proves the
# check notices it.
# ---------------------------------------------------------------------------
$checks = [ordered]@{
    'A1 the package emits no File row for the console twin' =
        { param($t) ($t.msi -match 'emit_file_component\("", exe, 12\)') -and
                    ($t.msi -notmatch 'emit_file_component\("", com_exe') }
    'A2 DeriveConsoleTwin is a deferred, impersonated, ignore-return DLL action' =
        { param($t)
          $m = [regex]::Match($t.msi, '(?s)<CustomAction Id="DeriveConsoleTwin"(.*?)/>')
          $m.Success -and $m.Value -match 'BinaryKey="GhozttyMsiCa"' -and
          $m.Value -match 'DllEntry="DeriveConsoleTwinCA"' -and $m.Value -match 'Execute="deferred"' -and
          $m.Value -match 'Impersonate="yes"' -and $m.Value -match 'Return="ignore"' }
    'A3 RemoveConsoleTwin is a deferred, impersonated, ignore-return DLL action' =
        { param($t)
          $m = [regex]::Match($t.msi, '(?s)<CustomAction Id="RemoveConsoleTwin"(.*?)/>')
          $m.Success -and $m.Value -match 'BinaryKey="GhozttyMsiCa"' -and
          $m.Value -match 'DllEntry="RemoveConsoleTwinCA"' -and $m.Value -match 'Execute="deferred"' -and
          $m.Value -match 'Impersonate="yes"' -and $m.Value -match 'Return="ignore"' }
    'A4 each action is handed the install directory as CustomActionData' =
        { param($t)
          ($t.msi -match '(?s)<CustomAction Id="SetDeriveConsoleTwinData"\s+Property="DeriveConsoleTwin"\s+Value="\[INSTALLDIR\]"/>') -and
          ($t.msi -match '(?s)<CustomAction Id="SetRemoveConsoleTwinData"\s+Property="RemoveConsoleTwin"\s+Value="\[INSTALLDIR\]"/>') }
    'A5 derive runs after InstallFiles (4000), on everything but a full removal' =
        { param($t)
          ($t.msi -match '<Custom Action="SetDeriveConsoleTwinData" Sequence="4005">NOT REMOVE~="ALL"</Custom>') -and
          ($t.msi -match '<Custom Action="DeriveConsoleTwin" Sequence="4010">NOT REMOVE~="ALL"</Custom>') }
    'A6 remove runs before RemoveFiles (3500), on a full removal only' =
        { param($t)
          ($t.msi -match '<Custom Action="SetRemoveConsoleTwinData" Sequence="3480">REMOVE~="ALL"</Custom>') -and
          ($t.msi -match '<Custom Action="RemoveConsoleTwin" Sequence="3490">REMOVE~="ALL"</Custom>') }
    'A7 the DLL exports both entry points' =
        { param($t)
          ($t.ca -match 'export fn DeriveConsoleTwinCA\(hInstall: MSIHANDLE\) callconv\(\.winapi\) UINT') -and
          ($t.ca -match 'export fn RemoveConsoleTwinCA\(hInstall: MSIHANDLE\) callconv\(\.winapi\) UINT') }
    'A8 the DLL reads CustomActionData, the only property a deferred action has' =
        { param($t) ([regex]::Matches($t.ca, 'msi\.property\(hInstall, "CustomActionData"')).Count -eq 2 }
    'A9 neither action can fail the install (both always return success)' =
        { param($t)
          $d = [regex]::Match($t.ca, '(?s)export fn DeriveConsoleTwinCA.*?\n}\n')
          $r = [regex]::Match($t.ca, '(?s)export fn RemoveConsoleTwinCA.*?\n}\n')
          $d.Success -and $r.Success -and
          ($d.Value -notmatch 'return [1-9]') -and ($r.Value -notmatch 'return [1-9]') -and
          ($d.Value -notmatch 'return logic\.') -and ($r.Value -notmatch 'return logic\.') }
    'A10 the build tool and the installer make the twin with the same function' =
        { param($t)
          ($t.patch -match 'const twin = @import\("console_twin"\);') -and
          ($t.patch -match 'twin\.makeConsoleTwin\(bytes\)') -and
          ($t.exe -match 'b\.path\("src/apprt/win32/console_twin\.zig"\)') -and
          ($t.ca -match 'const twin = @import\("console_twin\.zig"\);') -and
          ($t.ca -match 'twin\.derive\(') }
    'A11 the twin keeps no stale Authenticode table (a flipped signed image would read as tampered)' =
        { param($t) $t.twin -match '(?s)pub fn makeConsoleTwin\(bytes: \[\]u8\) PeError!usize \{\s*try setSubsystem\(bytes, subsystem_console\);\s*return stripSignature\(bytes\);' }
    'A12 the lane runs the console twin tests' =
        { param($t) $t.tests -match '_ = @import\("console_twin\.zig"\);' }
    'A13 the build-time read-back for the twin is wired' =
        { param($t) $t.msi -match 'echo "==> verify console twin derivation' -and
                    $t.msi -match 'python3 - "\$WORK/CustomAction\.idt" "\$WORK/InstallExecuteSequence\.idt" "\$WORK/File\.idt" "\$MSI_CA_DLL"' }
}

$mutations = [ordered]@{
    'A1 the package emits no File row for the console twin' =
        @{ Key = 'msi'; Find = 'emit_file_component("", exe, 12)'; Replace = "emit_file_component(`"`", exe, 12)`nemit_file_component(`"`", com_exe, 12)" }
    'A2 DeriveConsoleTwin is a deferred, impersonated, ignore-return DLL action' =
        @{ Key = 'msi'; Find = 'DllEntry="DeriveConsoleTwinCA"
                  Execute="deferred"'; Replace = 'DllEntry="DeriveConsoleTwinCA"
                  Execute="immediate"' }
    'A3 RemoveConsoleTwin is a deferred, impersonated, ignore-return DLL action' =
        @{ Key = 'msi'; Find = 'DllEntry="RemoveConsoleTwinCA"
                  Execute="deferred"
                  Impersonate="yes"'; Replace = 'DllEntry="RemoveConsoleTwinCA"
                  Execute="deferred"
                  Impersonate="no"' }
    'A4 each action is handed the install directory as CustomActionData' =
        @{ Key = 'msi'; Find = 'Property="DeriveConsoleTwin"'; Replace = 'Property="DERIVEDIR"' }
    'A5 derive runs after InstallFiles (4000), on everything but a full removal' =
        @{ Key = 'msi'; Find = '<Custom Action="DeriveConsoleTwin" Sequence="4010">'; Replace = '<Custom Action="DeriveConsoleTwin" Sequence="3990">' }
    'A6 remove runs before RemoveFiles (3500), on a full removal only' =
        @{ Key = 'msi'; Find = '<Custom Action="RemoveConsoleTwin" Sequence="3490">'; Replace = '<Custom Action="RemoveConsoleTwin" Sequence="3510">' }
    'A7 the DLL exports both entry points' =
        @{ Key = 'ca'; Find = 'export fn RemoveConsoleTwinCA('; Replace = 'fn RemoveConsoleTwinCA(' }
    'A8 the DLL reads CustomActionData, the only property a deferred action has' =
        @{ Key = 'ca'; Find = 'msi.property(hInstall, "CustomActionData", &dir_buf) orelse {
        msi.logLine(hInstall, wide("DeriveConsoleTwinCA'; Replace = 'msi.property(hInstall, "INSTALLDIR", &dir_buf) orelse {
        msi.logLine(hInstall, wide("DeriveConsoleTwinCA' }
    'A9 neither action can fail the install (both always return success)' =
        @{ Key = 'ca'; Find = 'ghoztty.com NOT written"));
        return 0;'; Replace = 'ghoztty.com NOT written"));
        return 1603;' }
    'A10 the build tool and the installer make the twin with the same function' =
        @{ Key = 'patch'; Find = 'twin.makeConsoleTwin(bytes)'; Replace = 'localFlip(bytes)' }
    'A11 the twin keeps no stale Authenticode table (a flipped signed image would read as tampered)' =
        @{ Key = 'twin'; Find = 'return stripSignature(bytes);'; Replace = 'return bytes.len;' }
    'A12 the lane runs the console twin tests' =
        @{ Key = 'tests'; Find = '_ = @import("console_twin.zig");'; Replace = '' }
    'A13 the build-time read-back for the twin is wired' =
        @{ Key = 'msi'; Find = 'echo "==> verify console twin derivation'; Replace = 'echo "==> (skipped) console twin' }
}

if ($TeethCheck) {
    "== install-console-twin -TeethCheck: every A check, against its broken surface =="
    foreach ($name in $checks.Keys) {
        $m = $mutations[$name]
        if (-not $m) { Assert "$name has a mutation" $false; continue }
        $broken = [ordered]@{}
        foreach ($k in $text.Keys) { $broken[$k] = $text[$k] }
        $find = $m.Find -replace "`r`n", "`n"
        $src = $broken[$m.Key] -replace "`r`n", "`n"
        if (-not $src.Contains($find)) { Assert "$name mutation anchor is in $($paths[$m.Key])" $false; continue }
        $broken[$m.Key] = $src.Replace($find, $m.Replace)
        Assert "$name goes RED when broken" (-not (& $checks[$name] $broken))
    }
    Complete-TestBody
    Write-TestVerdict -Pass $script:passes -Fail $script:failures -Skipped $script:skipped -Label 'install-console-twin-teeth'
    exit ([int]($script:failures -gt 0))
}

"== install-console-twin A: the shipped recipe =="
$norm = [ordered]@{}
foreach ($k in $text.Keys) { $norm[$k] = $text[$k] -replace "`r`n", "`n" }
foreach ($name in $checks.Keys) { Assert $name (& $checks[$name] $norm) }
$missing = @($checks.Keys | Where-Object { -not $mutations.Contains($_) })
Assert "A14 no check ships without a mutation (-TeethCheck covers all $($checks.Count))" ($missing.Count -eq 0)

# ---------------------------------------------------------------------------
# E/F - the build-time read-backs, extracted from build-msi.sh and fed tables.
# ---------------------------------------------------------------------------
$py = $null
foreach ($cand in @('python', 'python3', 'py')) {
    if (-not (Get-Command $cand -ErrorAction SilentlyContinue)) { continue }
    $probe = & $cand -V 2>&1
    if ($LASTEXITCODE -eq 0 -and "$probe" -match '^Python 3') { $py = $cand; break }
}

"== install-console-twin E: the read-back, fed each package it must reject =="
if (-not $py) {
    Skip 'E  console twin read-back demonstration' 'no python interpreter on PATH'
    Skip 'F  File-table patch demonstration' 'no python interpreter on PATH'
} else {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("install-console-twin-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        function Put($name, $body) {
            $p = Join-Path $tmp $name
            [System.IO.File]::WriteAllText($p, $body, $utf8)
            return $p
        }
        function DropRow($table, $action) {
            return (($table -split "`r`n" | Where-Object { $_ -notmatch "^$action`t" }) -join "`r`n")
        }
        $t = "`t"
        $msiText = $norm.msi

        $verifier = ([regex]'(?ms)^python3 - "\$WORK/CustomAction\.idt" "\$WORK/InstallExecuteSequence\.idt" "\$WORK/File\.idt" "\$MSI_CA_DLL".*?\n(.*?)\nPYEOF$').Match($msiText)
        if (-not $verifier.Success) {
            Assert 'E0 the console twin read-back is extractable from build-msi.sh' $false
        } else {
            $vp = Put 'verify.py' $verifier.Groups[1].Value
            # CustomAction: Action/Type/Source/Target. 1 (DLL) + 64 (ignore)
            # + 1024 (deferred) = 1089, impersonated (no 2048).
            $goodCa = @(
                "Action${t}Type${t}Source${t}Target",
                "s72${t}i2${t}S72${t}S255",
                "CustomAction${t}Action",
                "SetDeriveConsoleTwinData${t}51${t}DeriveConsoleTwin${t}[INSTALLDIR]",
                "DeriveConsoleTwin${t}1089${t}GhozttyMsiCa${t}DeriveConsoleTwinCA",
                "SetRemoveConsoleTwinData${t}51${t}RemoveConsoleTwin${t}[INSTALLDIR]",
                "RemoveConsoleTwin${t}1089${t}GhozttyMsiCa${t}RemoveConsoleTwinCA"
            ) -join "`r`n"
            $goodSeq = @(
                "Action${t}Condition${t}Sequence",
                "s72${t}S255${t}I2",
                "InstallExecuteSequence${t}Action",
                "InstallInitialize${t}${t}1500",
                "SetRemoveConsoleTwinData${t}REMOVE~=`"ALL`"${t}3480",
                "RemoveConsoleTwin${t}REMOVE~=`"ALL`"${t}3490",
                "RemoveFiles${t}${t}3500",
                "InstallFiles${t}${t}4000",
                "SetDeriveConsoleTwinData${t}NOT REMOVE~=`"ALL`"${t}4005",
                "DeriveConsoleTwin${t}NOT REMOVE~=`"ALL`"${t}4010",
                "InstallFinalize${t}${t}6600"
            ) -join "`r`n"
            # FileName as wixl writes it: the bare long name, which is what the
            # version patch below matches exactly.
            $goodFile = @(
                "File${t}Component_${t}FileName${t}FileSize${t}Version${t}Language${t}Attributes${t}Sequence",
                "s72${t}s72${t}l255${t}i4${t}S72${t}S20${t}I2${t}i2",
                "File${t}File",
                "f1${t}c1${t}ghoztty.exe${t}100${t}1.2.3.4${t}${t}512${t}1",
                "f2${t}c2${t}ghoztty-agent.exe${t}100${t}1.2.3.4${t}${t}512${t}2"
            ) -join "`r`n"
            $goodDll = Join-Path $tmp 'good-ca.dll'
            [System.IO.File]::WriteAllBytes($goodDll, [byte[]](@(0x4D, 0x5A) +
                [System.Text.Encoding]::ASCII.GetBytes("MaintenancePromptCA") + @(0) +
                [System.Text.Encoding]::ASCII.GetBytes("DeriveConsoleTwinCA") + @(0) +
                [System.Text.Encoding]::ASCII.GetBytes("RemoveConsoleTwinCA") + @(0)))
            $oldDll = Join-Path $tmp 'old-ca.dll'
            [System.IO.File]::WriteAllBytes($oldDll, [byte[]](@(0x4D, 0x5A) +
                [System.Text.Encoding]::ASCII.GetBytes("MaintenancePromptCA") + @(0)))

            function RunVerifier($ca = $goodCa, $seq = $goodSeq, $file = $goodFile, $dll = $goodDll) {
                $f1 = Put ("ca-" + [guid]::NewGuid().ToString('N') + '.idt') $ca
                $f2 = Put ("seq-" + [guid]::NewGuid().ToString('N') + '.idt') $seq
                $f3 = Put ("file-" + [guid]::NewGuid().ToString('N') + '.idt') $file
                # Each line as its own string: PS 5.1 wraps a stderr ErrorRecord at
                # the console width, which would split the message an oracle reads.
                $out = (& $py $vp $f1 $f2 $f3 $dll 2>&1 | ForEach-Object { "$_" }) -join "`n"
                return @{ Exit = $LASTEXITCODE; Text = $out }
            }
            function Rejects($name, $r, $says) {
                Assert "$name" (($r.Exit -ne 0) -and ($r.Text -match $says))
            }

            $r = RunVerifier
            Assert 'E1 a correctly wired package passes' (($r.Exit -eq 0) -and ($r.Text -match 'console twin ok'))
            if ($r.Exit -ne 0) { "       verifier: $($r.Text.Trim())" }

            Rejects 'E2 a package that CARRIES the twin again (the 20 MB) is rejected' `
                (RunVerifier -file ($goodFile + "`r`nf3${t}c3${t}GHOZTT~1.COM|ghoztty.com${t}100${t}1.2.3.4${t}${t}512${t}3")) 'carries ghoztty\.com'
            Rejects 'E3 a package with no DeriveConsoleTwin - no ghoztty on the PATH - is rejected' `
                (RunVerifier -ca (DropRow $goodCa 'DeriveConsoleTwin') -seq (DropRow $goodSeq 'DeriveConsoleTwin')) 'no DeriveConsoleTwin row'
            Rejects 'E4 a package with no RemoveConsoleTwin - an uninstall that leaves the folder - is rejected' `
                (RunVerifier -ca (DropRow $goodCa 'RemoveConsoleTwin') -seq (DropRow $goodSeq 'RemoveConsoleTwin')) 'no RemoveConsoleTwin row'
            Rejects 'E5 an IMMEDIATE derive (runs outside the install script) is rejected' `
                (RunVerifier -ca ($goodCa -replace "DeriveConsoleTwin${t}1089", "DeriveConsoleTwin${t}65")) 'is not deferred'
            Rejects 'E6 a derive that runs as LocalSystem (no impersonation) is rejected' `
                (RunVerifier -ca ($goodCa -replace "DeriveConsoleTwin${t}1089", "DeriveConsoleTwin${t}3137")) 'is not impersonated'
            Rejects 'E7 a derive whose failure would roll back to no Ghoztty at all is rejected' `
                (RunVerifier -ca ($goodCa -replace "DeriveConsoleTwin${t}1089", "DeriveConsoleTwin${t}1025")) 'checks its return'
            Rejects 'E8 an ASYNCHRONOUS remove is rejected' `
                (RunVerifier -ca ($goodCa -replace "RemoveConsoleTwin${t}1089", "RemoveConsoleTwin${t}1217")) 'is asynchronous'
            Rejects 'E9 a derive pointed at the wrong entry point is rejected' `
                (RunVerifier -ca ($goodCa -replace "${t}DeriveConsoleTwinCA", "${t}MaintenancePromptCA")) 'expected DeriveConsoleTwinCA'
            Rejects 'E10 a DLL that predates T2071 (no export) is rejected - error 1723 at install' `
                (RunVerifier -dll $oldDll) 'does not export DeriveConsoleTwinCA'
            Rejects 'E11 a derive with no install directory handed to it is rejected' `
                (RunVerifier -ca (DropRow $goodCa 'SetDeriveConsoleTwinData')) 'no SetDeriveConsoleTwinData row'
            Rejects 'E12 a derive handed the wrong directory is rejected' `
                (RunVerifier -ca ($goodCa -replace 'DeriveConsoleTwin\t\[INSTALLDIR\]', "DeriveConsoleTwin${t}[TempFolder]")) 'expected type 51 setting DeriveConsoleTwin'
            Rejects 'E13 a derive sequenced BEFORE InstallFiles (no exe yet) is rejected' `
                (RunVerifier -seq ($goodSeq -replace "DeriveConsoleTwin${t}NOT REMOVE~=`"ALL`"${t}4010", "DeriveConsoleTwin${t}NOT REMOVE~=`"ALL`"${t}3990")) 'not after InstallFiles'
            Rejects 'E14 a derive appended past InstallFinalize (the wixl After= shape, T1367) is rejected' `
                (RunVerifier -seq ($goodSeq -replace "DeriveConsoleTwin${t}NOT REMOVE~=`"ALL`"${t}4010", "DeriveConsoleTwin${t}NOT REMOVE~=`"ALL`"${t}6605")) 'not after InstallFiles'
            Rejects 'E15 a remove sequenced AFTER RemoveFiles (folder already judged not empty) is rejected' `
                (RunVerifier -seq ($goodSeq -replace "RemoveConsoleTwin${t}REMOVE~=`"ALL`"${t}3490", "RemoveConsoleTwin${t}REMOVE~=`"ALL`"${t}3510")) 'not between InstallInitialize'
            Rejects 'E16 a derive that ALSO runs on uninstall is rejected' `
                (RunVerifier -seq ($goodSeq -replace "DeriveConsoleTwin${t}NOT REMOVE~=`"ALL`"${t}4010", "DeriveConsoleTwin${t}${t}4010")) 'DeriveConsoleTwin condition'
            Rejects 'E17 a remove that runs on every install (deleting the fresh twin) is rejected' `
                (RunVerifier -seq ($goodSeq -replace "RemoveConsoleTwin${t}REMOVE~=`"ALL`"${t}3490", "RemoveConsoleTwin${t}${t}3490")) 'RemoveConsoleTwin condition'
            Rejects 'E18 a package with no ghoztty.exe to derive from is rejected' `
                (RunVerifier -file (DropRow $goodFile 'f1')) 'no ghoztty\.exe'
        }

        "== install-console-twin F: the File-table patch refuses a carried twin =="
        $patch = ([regex]'(?ms)^python3 - "\$WORK/File\.idt" "\$EXE_FILE_VERSION" <<''PYEOF''\n(.*?)\nPYEOF$').Match($msiText)
        if (-not $patch.Success) {
            Assert 'F0 the File-table patch is extractable from build-msi.sh' $false
        } else {
            $pp = Put 'patch.py' $patch.Groups[1].Value
            $fGood = Put 'file-good.idt' $goodFile
            & $py $pp $fGood '9.9.9.9' 2>&1 | Out-Null
            $okExit = $LASTEXITCODE
            $patched = [System.IO.File]::ReadAllText($fGood)
            Assert 'F1 a package without the twin is versioned and accepted' (($okExit -eq 0) -and
                ($patched -match "ghoztty\.exe${t}100${t}9\.9\.9\.9") -and ($patched -match "ghoztty-agent\.exe${t}100${t}9\.9\.9\.9"))
            $fBad = Put 'file-bad.idt' ($goodFile + "`r`nf3${t}c3${t}GHOZTT~1.COM|ghoztty.com${t}100${t}1.2.3.4${t}${t}512${t}3")
            $out = (& $py $pp $fBad '9.9.9.9' 2>&1 | ForEach-Object { "$_" }) -join "`n"
            Assert 'F2 a package that carries ghoztty.com again is refused, by name' (($LASTEXITCODE -ne 0) -and ($out -match 'carries ghoztty\.com again'))
        }
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# LAST statement of the body (T1039).
Complete-TestBody

# A clean green run stamps the files this harness covers (T783).
if ($script:failures -eq 0 -and $script:skipped -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard install-console-twin -Repo $Repo 2>&1 | ForEach-Object { Write-Host "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:passes -Fail $script:failures -Skipped $script:skipped -Label 'install-console-twin' -MinPass 30
exit ([int]($script:failures -gt 0))
