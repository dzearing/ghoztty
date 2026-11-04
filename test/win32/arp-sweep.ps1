# T2679 acceptance: the app removes the dead "Ghoztty" rows earlier in-app
# updates left in Settings > Apps, and nothing else.
#
# THE ROWS. Before T2327 every in-app update left the release it replaced
# listed in Apps & Features: an HKCU Uninstall\{ProductCode} key, written by
# the package's C_ArpEntry component, whose product Windows Installer no longer
# knows. By 2026-11-03 one box listed 44. T2327 stops new ones; the app now
# sweeps the old ones at launch (ArpOrphanSweep.zig), and which keys count as
# dead is arp_orphan.zig (unit-tested in every lane).
#
# THE PROOF, with throwaway rows under a throwaway product name, against the
# real HKCU Uninstall key and a real Windows Installer:
#
#   A  forced, named: the dead row in our exact shape is removed; a row for
#      another name, another publisher, a different uninstall command, a
#      Windows-owned entry, and a row naming a product Windows Installer DOES
#      know are all kept.
#   B  a Debug build without the force switch removes nothing (the rule that
#      keeps a dev build off the user's rows), and neither does a forced run
#      with no name (it never falls back to the release rows).
#   C  never during an install: while Windows Installer's install mutex is
#      held, a forced run removes nothing; released, the next launch does.
#   D  nothing left behind, and the user's own Ghoztty rows never moved.
#
# preflight: Assert-GhozttyIsolatedBuild - a debug zig-out build, launched on
# the test desktop with a private pipe suffix.
#
# persistence: off - every launch passes --session-persistence=false, so no
# layout is read or written.
#
# isolation: full - every row this writes carries a throwaway DisplayName
# (GhozttyT2679*), the app only sweeps the name it is given, and section D
# measures the user's own Ghoztty rows before and after.
#
#   powershell -NoProfile -File test\win32\arp-sweep.ps1

param([switch]$NegativeControl)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
$ErrorActionPreference = 'Stop'
$env:GHOZTTY_NO_STARTUP_ESCAPE = '1'
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 'arpsweep')
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
Assert-GhozttyIsolatedBuild -Exe $exe | Out-Null

$script:pass = 0
$script:fail = 0
$script:skip = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}
function Skip([string]$label) { $script:skip++; Write-Host "SKIP  $label" -ForegroundColor Yellow }

$uninst = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall'
$name = 'GhozttyT2679Sweep'
$publisher = 'dzearing'

function New-Code { '{' + ([guid]::NewGuid().ToString().ToUpperInvariant()) + '}' }

# Every key this run writes, so the finally block removes exactly those.
$script:written = New-Object System.Collections.Generic.List[string]

function New-Row([string]$code, [string]$display, [string]$pub, [string]$cmd, [switch]$WindowsInstaller) {
    $path = Join-Path $uninst $code
    if (Test-Path $path) { throw "fixture collision: $path already exists" }
    New-Item -Path $path -Force | Out-Null
    $script:written.Add($path)
    New-ItemProperty -Path $path -Name DisplayName -Value $display -PropertyType String | Out-Null
    New-ItemProperty -Path $path -Name Publisher -Value $pub -PropertyType String | Out-Null
    New-ItemProperty -Path $path -Name DisplayVersion -Value '1.43.4' -PropertyType String | Out-Null
    New-ItemProperty -Path $path -Name UninstallString -Value $cmd -PropertyType String | Out-Null
    if ($WindowsInstaller) {
        New-ItemProperty -Path $path -Name WindowsInstaller -Value 1 -PropertyType DWord | Out-Null
    }
    return $path
}

function Get-UserGhozttyRows {
    @(Get-ChildItem $uninst -ErrorAction SilentlyContinue | ForEach-Object {
        $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
        if ($p -and $p.DisplayName -eq 'Ghoztty') { $_.PSChildName }
    } | Sort-Object)
}

function Stop-Repo { [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500) }

# Launch with the given sweep env, give the thread $waitSecs (or until
# $untilGone disappears), kill it. Returns seconds until $untilGone was gone,
# or -1.
function Invoke-Launch($sweepEnv, $sweepName, [string]$untilGone, [int]$waitSecs) {
    Stop-Repo
    if ($null -ne $sweepEnv) { $env:GHOZTTY_ARP_SWEEP = $sweepEnv } else { Remove-Item Env:GHOZTTY_ARP_SWEEP -ErrorAction SilentlyContinue }
    if ($null -ne $sweepName) { $env:GHOZTTY_ARP_SWEEP_NAME = $sweepName } else { Remove-Item Env:GHOZTTY_ARP_SWEEP_NAME -ErrorAction SilentlyContinue }
    try {
        $app = Start-OnTestDesktop -Exe $exe -Arguments @('--session-persistence=false')
    } finally {
        Remove-Item Env:GHOZTTY_ARP_SWEEP -ErrorAction SilentlyContinue
        Remove-Item Env:GHOZTTY_ARP_SWEEP_NAME -ErrorAction SilentlyContinue
    }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $gone = -1
    while ($sw.Elapsed.TotalSeconds -lt $waitSecs) {
        if ($untilGone -and -not (Test-Path $untilGone)) { $gone = $sw.Elapsed.TotalSeconds; break }
        Start-Sleep -Milliseconds 250
    }
    $alive = -not $app.Process.HasExited
    Stop-Process -Id $app.Pid -Force -ErrorAction SilentlyContinue
    Stop-Repo
    if (-not $alive) { Write-Host "      (the app exited on its own during the launch)" -ForegroundColor Yellow }
    return $gone
}

# A product Windows Installer knows that has no HKCU listed key: a row naming
# it under our throwaway name must survive (test 5 of arp_orphan.zig).
function Find-RegisteredProduct {
    # The COM Installer.Products list comes back empty under PS 5.1 here, so
    # ask msi.dll directly: enumerate, and confirm each with the same call the
    # app makes.
    if (-not ('T2679Msi' -as [type])) {
        Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
using System.Text;
public static class T2679Msi {
    [DllImport("msi.dll", CharSet = CharSet.Unicode)]
    public static extern uint MsiEnumProductsW(uint index, StringBuilder product);
    [DllImport("msi.dll", CharSet = CharSet.Unicode)]
    public static extern int MsiQueryProductStateW(string product);
}
'@
    }
    for ($i = 0; $i -lt 2000; $i++) {
        $sb = New-Object System.Text.StringBuilder 39
        if ([T2679Msi]::MsiEnumProductsW([uint32]$i, $sb) -ne 0) { break }
        $p = $sb.ToString()
        if ([T2679Msi]::MsiQueryProductStateW($p) -ne -1 -and -not (Test-Path (Join-Path $uninst $p))) { return $p }
    }
    return $null
}

$userRowsBefore = Get-UserGhozttyRows
$td = New-TestDesktop

try {
    Write-Host '--- A. forced, named: the dead row goes, every other row stays ---'
    $dead = New-Code
    $deadPath = New-Row $dead $name $publisher "MsiExec.exe /X$dead"
    if ($NegativeControl) {
        # The control: a row the sweep must remove is given a shape it must
        # keep, so A1 has to go red.
        Set-ItemProperty -Path $deadPath -Name UninstallString -Value "MsiExec.exe /X$dead /qn"
    }
    $c = New-Code; $otherName = New-Row $c "${name}Other" $publisher "MsiExec.exe /X$c"
    $c = New-Code; $otherPub = New-Row $c $name 'Somebody else' "MsiExec.exe /X$c"
    $c = New-Code; $otherCmd = New-Row $c $name $publisher "MsiExec.exe /X$c /qn"
    $c = New-Code; $winOwned = New-Row $c $name $publisher "MsiExec.exe /X$c" -WindowsInstaller
    $registered = Find-RegisteredProduct
    $regPath = $null
    if ($registered) { $regPath = New-Row $registered $name $publisher "MsiExec.exe /X$registered" }

    $t = Invoke-Launch 'force' $name $deadPath 20
    Assert ($t -ge 0) "A1 the dead row in the package's exact shape is removed (after $([math]::Round($t,1))s)"
    Assert (Test-Path $otherName) 'A2 a row for another product name is kept'
    Assert (Test-Path $otherPub) 'A3 a row from another publisher is kept'
    Assert (Test-Path $otherCmd) 'A4 a row whose uninstall command is not the bare MsiExec /X{code} is kept'
    Assert (Test-Path $winOwned) "A5 Windows Installer's own entry (WindowsInstaller=1) is kept"
    if ($regPath) {
        Assert (Test-Path $regPath) "A6 a row naming a product Windows Installer knows ($registered) is kept"
    } else {
        Skip 'A6 a row naming a registered product is kept (no registered product without a listed key on this box)'
    }
    $settle = [math]::Max(6, [math]::Ceiling(3 * [math]::Max($t, 1)))

    Write-Host "--- B. no force, or no name: nothing is removed ($settle s each) ---"
    $b = New-Code
    $bPath = New-Row $b $name $publisher "MsiExec.exe /X$b"
    [void](Invoke-Launch $null $null $null $settle)
    Assert (Test-Path $bPath) 'B1 a Debug build without GHOZTTY_ARP_SWEEP=force removes nothing'
    [void](Invoke-Launch 'force' $null $null $settle)
    Assert (Test-Path $bPath) 'B2 a forced run with no name removes nothing (never falls back to the release rows)'
    [void](Invoke-Launch 'off' $name $null $settle)
    Assert (Test-Path $bPath) 'B3 GHOZTTY_ARP_SWEEP=off removes nothing'

    Write-Host '--- C. never while an install is running ---'
    $created = $false
    $mutex = $null
    try { $mutex = New-Object System.Threading.Mutex($true, 'Global\_MSIExecute', [ref]$created) } catch { $mutex = $null }
    if ($null -eq $mutex -or -not $created) {
        if ($mutex) { $mutex.Dispose() }
        Skip 'C1/C2 the install-running guard (could not take the install mutex: a real install is running, or this account cannot create it)'
    } else {
        try {
            [void](Invoke-Launch 'force' $name $null $settle)
            Assert (Test-Path $bPath) 'C1 while the install mutex is held, a forced run removes nothing'
        } finally {
            $mutex.ReleaseMutex(); $mutex.Dispose()
        }
        $t2 = Invoke-Launch 'force' $name $bPath 20
        Assert ($t2 -ge 0) 'C2 once it is released, the next launch removes the row'
    }
    Complete-TestBody
} finally {
    Stop-Repo
    foreach ($p in $script:written) { if (Test-Path $p) { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue } }
    Remove-TestDesktop | Out-Null
}

Write-Host '--- D. nothing left behind ---'
$left = @($script:written | Where-Object { Test-Path $_ })
Assert ($left.Count -eq 0) "D1 every throwaway row is gone ($($left.Count) left)"
$userRowsAfter = Get-UserGhozttyRows
Assert ((@($userRowsBefore) -join ',') -eq (@($userRowsAfter) -join ',')) "D2 the user's own Ghoztty rows never moved ($(@($userRowsBefore).Count) before, $(@($userRowsAfter).Count) after)"

# --- stamp (T783) ----------------------------------------------------------
if ($script:fail -eq 0 -and $script:skip -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard arp-sweep -Repo $repo 2>&1 |
        ForEach-Object { Write-Host "  $_" }
}

Write-TestVerdict -Pass $script:pass -Fail $script:fail -Skipped $script:skip -Label 'arp-sweep' -MinPass 11
