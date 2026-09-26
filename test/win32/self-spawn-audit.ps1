<#
.SYNOPSIS
    T980 acceptance - no code under src\ may launch "our own executable"
    through a raw std.fs.selfExe*Path call, where a test build would launch a
    copy of its own test suite.

.DESCRIPTION
    T933 measured the defect: inside a zig test binary `selfExePath` names the
    TEST RUNNER, so a spawn of "ourselves" starts a detached copy of the suite
    (40+ minutes of dead wall clock per floor run). It routed four sites
    through `src\os\self_exe.zig`, whose `productExePath*` refuse in a test
    build, and nothing stopped a fifth. This script is what stops it.

    Three sections:

      A. The analyzer (`lib\SelfSpawnAudit.ps1`) against fixtures, both
         directions: an unregistered site, a "read" whose function also
         launches a process and a stale registry entry are each reported; a
         registered read, a commented-out call and a call routed through
         self_exe resolve quietly.

      B. The sweep over the real `src\` against
         `self-spawn-audit.registry.json`. Zero findings, AND a floor on the
         number of sites seen - an analyzer whose pattern silently matched
         nothing would otherwise pass forever. B also checks that every public
         function in self_exe.zig still carries the `builtin.is_test` refusal,
         since the whole rule rests on it.

      C. `-TeethCheck` - the negative control. Plants the T933 shape (a raw
         selfExePathAlloc feeding a spawn) into a real file under src\, and
         requires section B's sweep to go RED naming it, then removes it.

    One `ALL PASS` / `N FAILURE(S)` line last, per the house convention.

.NOTES
    # persistence: launches no GUI and no ghoztty - this reads Zig source. No
    # IPC endpoint, no user state.
#>
[CmdletBinding()]
param(
    [switch]$TeethCheck
)

$ErrorActionPreference = 'Continue'
$Repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\SelfSpawnAudit.ps1')

$script:pass = 0
$script:fail = 0
function Assert([string]$name, [bool]$cond, [string]$detail = '') {
    if ($cond) { Write-Host "  PASS $name"; $script:pass++ }
    else {
        Write-Host "  FAIL $name$(if ($detail) { " -- $detail" })" -ForegroundColor Red
        $script:fail++
    }
}

$Registry = Join-Path $PSScriptRoot 'self-spawn-audit.registry.json'
$enc = New-Object Text.UTF8Encoding $false

# --- A: the analyzer against fixtures ---------------------------------------
Write-Host 'A. analyzer fixtures'
$tmp = Join-Path ([IO.Path]::GetTempPath()) "ghoztty-t980-$PID"
New-Item -ItemType Directory -Force -Path (Join-Path $tmp 'src\os') | Out-Null
try {
    [IO.File]::WriteAllText((Join-Path $tmp 'src\a.zig'), @'
fn unregistered(alloc: Allocator) !void {
    const exe = try std.fs.selfExePathAlloc(alloc);
    _ = exe;
}

fn registeredRead(alloc: Allocator) !void {
    const dir = try std.fs.selfExeDirPathAlloc(alloc);
    _ = dir;
}

fn readThatSpawns(alloc: Allocator) !void {
    const exe = try std.fs.selfExePathAlloc(alloc);
    var child = std.process.Child.init(&.{exe}, alloc);
    _ = try child.spawn();
}

fn commentedOut() void {
    // const exe = std.fs.selfExePath(&buf);
}

fn routed(alloc: Allocator) !void {
    const exe = try internal_os.self_exe.productExePathAlloc(alloc);
    _ = exe;
}

test "a site inside a test block" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    _ = try std.fs.selfExePath(&buf);
}
'@, $enc)
    # The one module allowed the raw call is exempt by path.
    [IO.File]::WriteAllText((Join-Path $tmp 'src\os\self_exe.zig'), @'
pub fn productExePathAlloc(alloc: Allocator) ![]u8 {
    return try std.fs.selfExePathAlloc(alloc);
}
'@, $enc)
    $fxReg = Join-Path $tmp 'registry.json'
    [IO.File]::WriteAllText($fxReg, @'
{ "entries": [
  { "file": "src\\a.zig", "fn": "registeredRead", "use": "read", "why": "fixture" },
  { "file": "src\\a.zig", "fn": "readThatSpawns", "use": "read", "why": "fixture" },
  { "file": "src\\a.zig", "fn": "test \"a site inside a test block\"", "use": "read", "why": "fixture" },
  { "file": "src\\gone.zig", "fn": "vanished", "use": "read", "why": "fixture" }
] }
'@, $enc)

    $sites = Get-SelfSpawnSites -Repo $tmp
    Assert 'A1 the analyzer sees exactly the four live fixture sites' ($sites.Count -eq 4) (
        ($sites | ForEach-Object { "$($_.File):$($_.Fn)" }) -join ', ')
    Assert 'A2 self_exe.zig is exempt by path' (
        @($sites | Where-Object { $_.File -like '*self_exe.zig' }).Count -eq 0)
    Assert 'A3 a test block is keyed by its name' (
        @($sites | Where-Object { $_.Fn -eq 'test "a site inside a test block"' }).Count -eq 1)

    $f = Get-SelfSpawnFindings -Repo $tmp -RegistryPath $fxReg
    $kinds = ($f | ForEach-Object { "$($_.Kind):$($_.Fn)" }) -join ', '
    Assert 'A4 an unregistered site is reported' (
        @($f | Where-Object { $_.Kind -eq 'unregistered' -and $_.Fn -eq 'unregistered' }).Count -eq 1) $kinds
    Assert 'A5 a registered read whose function launches a process is reported' (
        @($f | Where-Object { $_.Kind -eq 'read-but-spawns' -and $_.Fn -eq 'readThatSpawns' }).Count -eq 1) $kinds
    Assert 'A6 a registry entry naming no live site is reported stale' (
        @($f | Where-Object { $_.Kind -eq 'stale' -and $_.Fn -eq 'vanished' }).Count -eq 1) $kinds
    Assert 'A7 the quiet direction: registered reads, comments and routed calls raise nothing else' (
        $f.Count -eq 3) $kinds
} catch {
    Write-Host "  FAIL A0 the fixture section threw -- $_" -ForegroundColor Red
    $script:fail++
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

# --- B: the sweep over the real tree ----------------------------------------
Write-Host 'B. sweep over src\'
$live = Get-SelfSpawnSites -Repo $Repo
# 14 registered reads today. A floor well under that still catches the
# failure it exists for: a pattern edit that matches nothing.
Assert 'B1 the sweep sees the real sites (floor: 10)' ($live.Count -ge 10) "saw $($live.Count)"
$findings = Get-SelfSpawnFindings -Repo $Repo -RegistryPath $Registry
foreach ($x in $findings) { Write-Host "    $($x.Kind) $($x.File):$($x.Line) [$($x.Fn)] $($x.Detail)" -ForegroundColor Yellow }
Assert 'B2 no unregistered, misclassified or stale self-exe site under src\' ($findings.Count -eq 0) "$($findings.Count) finding(s)"

$selfExe = [IO.File]::ReadAllText((Join-Path $Repo 'src\os\self_exe.zig'))
$pubFns = [regex]::Matches($selfExe, '(?ms)^pub fn (\w+)\(.*?^\}')
Assert 'B3 self_exe.zig still exports its product-path helpers' ($pubFns.Count -ge 3) "found $($pubFns.Count)"
$unguarded = @($pubFns | Where-Object { $_.Value -notmatch 'comptime builtin\.is_test\) return Error\.SelfSpawnFromTestBinary' } |
    ForEach-Object { $_.Groups[1].Value })
Assert 'B4 every one of them refuses inside a test binary' ($unguarded.Count -eq 0) ($unguarded -join ', ')

# --- C: teeth ---------------------------------------------------------------
if ($TeethCheck) {
    Write-Host 'C. teeth check'
    $planted = Join-Path $Repo 'src\zz-t980-teeth-fixture.zig'
    try {
        [IO.File]::WriteAllText($planted, @'
// A synthesized violator (T980 teeth check). Delete this file if a teeth run
// left it behind; nothing imports it.
fn spawnOurselves(alloc: Allocator) !void {
    const exe = try std.fs.selfExePathAlloc(alloc);
    var child = std.process.Child.init(&.{ exe, "--pty-host" }, alloc);
    _ = try child.spawn();
}
'@, $enc)
        $teeth = @(Get-SelfSpawnFindings -Repo $Repo -RegistryPath $Registry |
            Where-Object { $_.File -like '*zz-t980-teeth-fixture.zig' })
        Assert 'C1 the sweep goes red on a planted T933-shape self-spawn' ($teeth.Count -eq 1)
        Assert 'C2 and names it as unregistered, with the remedy' (
            $teeth.Count -eq 1 -and $teeth[0].Kind -eq 'unregistered' -and $teeth[0].Detail -match 'productExePath')
    } finally {
        Remove-Item -LiteralPath $planted -Force -ErrorAction SilentlyContinue
    }
    Assert 'C3 the planted violator is removed again' (-not (Test-Path -LiteralPath $planted))
}

Complete-TestBody  # T1039: the run reached the end of its body

# --- stamp (T783) ----------------------------------------------------------
# Only a CLEAN green run records the covered files, and never a teeth check -
# that run deliberately plants a violator.
if ($script:fail -eq 0 -and -not $TeethCheck) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard self-spawn -Repo $Repo 2>&1 |
        ForEach-Object { Write-Host "  $($_.ToString())" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Label 'SELF-SPAWN AUDIT' -MinPass 11
