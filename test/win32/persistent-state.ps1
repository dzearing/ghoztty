<#
.SYNOPSIS
  Acceptance test for test\win32\lib\PersistentState.ps1 (T1230): the
  before/after snapshot that turns an acceptance run RED when it leaves
  durable state changed on this machine.

.DESCRIPTION
  T1168 found the suite planting permanent startup programs by eye, eight days
  late. The snapshot arm is what notices the next such leak on the run that
  causes it - but an arm that has only ever said "nothing changed" is
  indistinguishable from one that cannot see, so most of this file is the
  arm being SHOWN each kind of change and required to name it.

  A  the real box: every surface is read, the read is fast enough to run on
     every acceptance run, and two back-to-back reads agree - a surface that
     flickered on its own would paint every run red.
  B  teeth, per surface, under a scratch registry key and scratch folders (the
     seams), never the user's real state: an item is planted, changed and
     removed, and the diff must name the surface, the item and the kind of
     change. Unrelated neighbours (another program's startup entry, an
     ordinary PATH entry, another product's uninstall entry) must NOT be
     reported - an arm that flags the user's other software is an arm people
     learn to skip.
  C  the settle re-check: a difference that has gone by the second look (a
     concurrent lane's transient) is forgiven; one that persists is not.
  D  the runner is wired: acceptance-parallel.ps1 takes the snapshot before
     the run, checks after it, and the exit code and GREEN verdict both depend
     on the result. The live demonstration - a fixture script that really
     leaves a Run value behind and turns a real runner run red - is section G
     of test\win32\acceptance-parallel.ps1.

  Pure PowerShell: no exe, no window, no agent. Runs anywhere.
  ASCII-only by design (PS 5.1 mangles non-ASCII on rewrite).

  powershell -NoProfile -File test\win32\persistent-state.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$script:passes = 0
$script:failures = 0
function Assert($name, $cond, $detail = '') {
    if ($cond) {
        "  PASS $name"
        $script:passes++
    } else {
        "  FAIL $name$(if ($detail) { " -- $detail" })"
        $script:failures++
    }
}

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\PersistentState.ps1')

$Repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

# The scratch hive is deliberately NOT named *ghoztty* / *dzearing*: while it
# exists, a concurrent acceptance run's own `hives` surface must not see it.
$hiveName = "gzt-test-t1230-$PID"
$prefix = "Software\$hiveName\"
$scratch = Join-Path $env:TEMP "gzt-t1230-$PID"
$appData = Join-Path $scratch 'appdata'
$localAppData = Join-Path $scratch 'localappdata'

function Set-ScratchValue([string]$Sub, [string]$Name, $Value, [string]$Kind = 'String') {
    $k = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey("$prefix$Sub")
    try { $k.SetValue($Name, $Value, [Microsoft.Win32.RegistryValueKind]$Kind) } finally { $k.Close() }
}
function Remove-ScratchValue([string]$Sub, [string]$Name) {
    $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("$prefix$Sub", $true)
    if ($k) { try { $k.DeleteValue($Name, $false) } finally { $k.Close() } }
}
$script:fakeTasks = @()
function Snap {
    Get-PersistentStateSnapshot -HkcuPrefix $prefix -AppData $appData -LocalAppData $localAppData -TaskSource { $script:fakeTasks }
}
function SnapDiff($a, $b) { @(Compare-PersistentStateSnapshot -Before $a -After $b) }
function Has($diff, [string]$surface, [string]$change, [string]$itemLike) {
    @($diff | Where-Object { $_.Surface -eq $surface -and $_.Change -eq $change -and $_.Item -like $itemLike }).Count -eq 1
}
function Show($diff) { (@($diff | ForEach-Object { Format-PersistentStateChange $_ }) -join ' | ') }

try {
    # --- A. the real box ---------------------------------------------------
    ''
    '-- A. the real box: every surface reads, quickly, and holds still'
    $t = [Diagnostics.Stopwatch]::StartNew()
    $real1 = Get-PersistentStateSnapshot
    $ms = $t.ElapsedMilliseconds
    $real2 = Get-PersistentStateSnapshot
    $missing = @($script:PersistentStateSurfaces | Where-Object { -not $real1.Contains($_) })
    Assert 'A1 a real snapshot carries every surface' ($missing.Count -eq 0) "missing: $($missing -join ', ')"
    Assert 'A2 a real snapshot takes under 10 s (it runs on every acceptance run)' ($ms -lt 10000) "took $ms ms"
    $self = @(SnapDiff $real1 $real2)
    Assert 'A3 two back-to-back reads of the real box agree' ($self.Count -eq 0) (Show $self)
    $rawRun = @(try { (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -ErrorAction Stop).PSObject.Properties.Name |
                Where-Object { $_ -match 'ghoztty' -and $_ -notlike 'PS*' } } catch { })
    Assert 'A4 the run surface reads the same ghoztty startup entries the registry provider does' `
        ($real1['run'].Count -eq $rawRun.Count) "snapshot=$($real1['run'].Count) provider=$($rawRun.Count)"
    Assert 'A5 an unknown surface name is refused, not silently empty' `
        ($(try { $null = Get-PersistentStateSnapshot -Surfaces 'nope'; $false } catch { $_.Exception.Message -match 'unknown persistent-state surface' }))

    # --- B. teeth, per surface --------------------------------------------
    ''
    '-- B. every surface notices a plant, a change and a removal (scratch seams only)'
    New-Item -ItemType Directory -Force -Path $appData, $localAppData | Out-Null
    $base = Snap
    Assert 'B0 the empty scratch world snapshots clean against itself' (@(SnapDiff $base (Snap)).Count -eq 0)

    # run
    Set-ScratchValue 'Software\Microsoft\Windows\CurrentVersion\Run' 'OtherApp' 'C:\other.exe'
    $s0 = Snap
    Assert 'B1 run: another program''s startup entry is not reported' (@(SnapDiff $base $s0).Count -eq 0) (Show (SnapDiff $base $s0))
    Set-ScratchValue 'Software\Microsoft\Windows\CurrentVersion\Run' 'GhozttyAgent-probe' 'C:\x\ghoztty-agent.exe'
    $s1 = Snap
    $d = @(SnapDiff $s0 $s1)
    Assert 'B2 run: a planted GhozttyAgent-<instance> value is reported ADDED' ((Has $d 'run' 'added' 'GhozttyAgent-probe') -and $d.Count -eq 1) (Show $d)
    Set-ScratchValue 'Software\Microsoft\Windows\CurrentVersion\Run' 'GhozttyAgent-probe' 'C:\y\ghoztty-agent.exe'
    $d = @(SnapDiff $s1 (Snap))
    Assert 'B3 run: a rewritten value is reported CHANGED with both texts' `
        ((Has $d 'run' 'changed' 'GhozttyAgent-probe') -and $d[0].Before -match 'C:\\x' -and $d[0].After -match 'C:\\y') (Show $d)
    Remove-ScratchValue 'Software\Microsoft\Windows\CurrentVersion\Run' 'GhozttyAgent-probe'
    $d = @(SnapDiff $s1 (Snap))
    Assert 'B4 run: a removed value is reported REMOVED (a test that deletes the user''s entry is the same defect)' (Has $d 'run' 'removed' 'GhozttyAgent-probe') (Show $d)

    # env
    Set-ScratchValue 'Environment' 'Path' 'C:\Tools;%USERPROFILE%\bin' 'ExpandString'
    $e0 = Snap
    Assert 'B5 env: ordinary PATH entries are not reported' (@(SnapDiff $base $e0).Count -eq 0) (Show (SnapDiff $base $e0))
    Set-ScratchValue 'Environment' 'Path' "C:\Tools;%USERPROFILE%\bin;D:\git\ghoztty\zig-out\bin;$([IO.Path]::GetTempPath())ghz-x" 'ExpandString'
    Set-ScratchValue 'Environment' 'GHOZTTY_PROBE' '1'
    $d = @(SnapDiff $e0 (Snap))
    Assert 'B6 env: a zig-out PATH entry, a %TEMP% PATH entry and a GHOZTTY_* value are each reported' `
        ((Has $d 'env' 'added' 'path:*zig-out*') -and (Has $d 'env' 'added' 'path:*ghz-x') -and (Has $d 'env' 'added' 'value:GHOZTTY_PROBE') -and $d.Count -eq 3) (Show $d)

    # classes
    $c0 = Snap
    Set-ScratchValue 'Software\Classes\NotOurs\shell\open\command' '' 'x.exe'
    Set-ScratchValue 'Software\Classes\ghoztty\shell\open\command' '' '"D:\scratch\ghoztty.exe" "%1"'
    $c1 = Snap
    $d = @(SnapDiff $c0 $c1)
    Assert 'B7 classes: a planted ghoztty:// handler is reported (keys and the command), another class is not' `
        ((Has $d 'classes' 'added' 'ghoztty\shell\open\command\(default)') -and -not @($d | Where-Object { $_.Item -like 'NotOurs*' }).Count) (Show $d)
    Set-ScratchValue 'Software\Classes\ghoztty\shell\open\command' '' '"D:\other\ghoztty.exe" "%1"'
    $d = @(SnapDiff $c1 (Snap))
    Assert 'B8 classes: a repointed handler is reported CHANGED (the T1124 shape)' `
        ((Has $d 'classes' 'changed' 'ghoztty\shell\open\command\(default)') -and $d.Count -eq 1) (Show $d)
    $c2 = Snap
    Set-ScratchValue 'Software\Classes\ghoztty-debug\shell\open\command' '' '"D:\git\ghoztty-b\zig-out\bin\ghoztty.exe" "%1"'
    $d = @(SnapDiff $c2 (Snap))
    Assert 'B8b classes: the ghoztty-debug handler, which every debug launch rewrites by design, is NOT reported' ($d.Count -eq 0) (Show $d)

    # hives
    $h0 = Snap
    $null = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey("${prefix}Software\ghoztty-test-fixture").Close()
    $null = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey("${prefix}Software\dzearing\T1230Probe").Close()
    $null = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey("${prefix}Software\SomeVendor").Close()
    $d = @(SnapDiff $h0 (Snap))
    Assert 'B9 hives: a fixture hive left under HKCU\Software and a product identity under dzearing are reported; a vendor key is not' `
        ((Has $d 'hives' 'added' 'Software\ghoztty-test-fixture') -and (Has $d 'hives' 'added' 'Software\dzearing\T1230Probe') -and
        -not @($d | Where-Object { $_.Item -like '*SomeVendor*' }).Count) (Show $d)

    # arp
    $a0 = Snap
    Set-ScratchValue 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{OTHER}' 'DisplayName' 'Some Editor'
    Set-ScratchValue 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{T1230}' 'DisplayName' 'Ghoztty'
    Set-ScratchValue 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{T1230}' 'DisplayVersion' '9.9.9'
    $a1 = Snap
    $d = @(SnapDiff $a0 $a1)
    Assert 'B10 arp: a Ghoztty uninstall entry is reported with its version; another product''s is not' `
        ((Has $d 'arp' 'added' '{T1230}') -and $d.Count -eq 1 -and $d[0].After -match '9\.9\.9') (Show $d)
    Set-ScratchValue 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{T1230}' 'DisplayVersion' '9.9.10'
    $d = @(SnapDiff $a1 (Snap))
    Assert 'B11 arp: a version move on the user''s product entry is reported CHANGED' (Has $d 'arp' 'changed' '{T1230}') (Show $d)

    # tasks
    $script:fakeTasks = @([pscustomobject]@{ TaskPath = '\'; TaskName = 'SomeUpdater' }, [pscustomobject]@{ TaskPath = '\'; TaskName = 'GhozttyGoLoopWatchdog' })
    $t0 = Snap
    $script:fakeTasks += [pscustomobject]@{ TaskPath = '\'; TaskName = 'GhozttyAgent' }
    $d = @(SnapDiff $t0 (Snap))
    Assert 'B12 tasks: a new ghoztty scheduled task is reported, an unrelated one never is' `
        ((Has $d 'tasks' 'added' '\GhozttyAgent') -and $d.Count -eq 1) (Show $d)
    $script:fakeTasks = @($script:fakeTasks | Where-Object { $_.TaskName -ne 'GhozttyGoLoopWatchdog' })
    $d = @(SnapDiff $t0 (Snap))
    Assert 'B13 tasks: an unregistered ghoztty task is reported REMOVED' (Has $d 'tasks' 'removed' '\GhozttyGoLoopWatchdog') (Show $d)

    # startmenu
    $m0 = Snap
    $startup = Join-Path $appData 'Microsoft\Windows\Start Menu\Programs\Startup'
    New-Item -ItemType Directory -Force -Path $startup | Out-Null
    Set-Content -LiteralPath (Join-Path $startup 'ghoztty-agent.cmd') -Value '@echo off' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $startup 'other.cmd') -Value '@echo off' -Encoding ASCII
    $d = @(SnapDiff $m0 (Snap))
    Assert 'B14 startmenu: a ghoztty-agent.cmd in the Startup folder is reported; another file there is not' `
        ((Has $d 'startmenu' 'added' 'Startup\ghoztty-agent.cmd') -and $d.Count -eq 1) (Show $d)

    # install
    $inst = Join-Path $localAppData 'Programs\Ghoztty'
    New-Item -ItemType Directory -Force -Path $inst | Out-Null
    Set-Content -LiteralPath (Join-Path $inst 'ghoztty.exe') -Value 'v1' -Encoding ASCII
    $i0 = Snap
    Set-Content -LiteralPath (Join-Path $inst 'ghoztty.exe') -Value 'v2-longer' -Encoding ASCII
    $d = @(SnapDiff $i0 (Snap))
    Assert 'B15 install: a replaced installed ghoztty.exe is reported CHANGED (never touch the user''s install, measured)' `
        ((Has $d 'install' 'changed' 'ghoztty.exe') -and $d.Count -eq 1) (Show $d)

    # account
    $k0 = Snap
    New-Item -ItemType Directory -Force -Path (Join-Path $localAppData 'ghoztty') | Out-Null
    Set-Content -LiteralPath (Join-Path $localAppData 'ghoztty\account-debug.dat') -Value 'blob' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $localAppData 'ghoztty\account.dat') -Value 'blob' -Encoding ASCII
    $d = @(SnapDiff $k0 (Snap))
    Assert 'B16 account: a debug sign-in blob is reported; the release blob (the live app rewrites it) is deliberately not' `
        ((Has $d 'account' 'added' 'account-debug.dat') -and $d.Count -eq 1) (Show $d)

    $fmt = Format-PersistentStateChange ([pscustomobject]@{ Surface = 'run'; Item = 'X'; Change = 'added'; Before = $null; After = 'v' })
    Assert 'B17 a change formats as one readable line naming surface, kind and item' ($fmt -eq 'run ADDED X = v') $fmt

    # --- C. the settle re-check -------------------------------------------
    ''
    '-- C. a transient is forgiven on the second look; a leak is not'
    $clean = Snap
    $dirty = Snap
    $dirty['run']['GhozttyAgent-otherlane'] = 'String:x'
    $script:calls = 0
    $r = @(Invoke-PersistentStateCheck -Before $clean -SettleSeconds 0 -Snapshot { $script:calls++; if ($script:calls -eq 1) { $dirty } else { $clean } })
    Assert 'C1 a difference gone by the settle re-check is not reported (another lane''s transient)' ($r.Count -eq 0 -and $script:calls -eq 2) "reported=$($r.Count) calls=$($script:calls)"
    $script:calls = 0
    $r = @(Invoke-PersistentStateCheck -Before $clean -SettleSeconds 0 -Snapshot { $script:calls++; $dirty })
    Assert 'C2 a difference still there on the re-check IS reported' ($r.Count -eq 1 -and $r[0].Item -eq 'GhozttyAgent-otherlane') "reported=$($r.Count)"
    $script:calls = 0
    $r = @(Invoke-PersistentStateCheck -Before $clean -SettleSeconds 0 -Snapshot { $script:calls++; $clean })
    Assert 'C3 a clean first look takes no second look (no settle delay on a green run)' ($r.Count -eq 0 -and $script:calls -eq 1) "calls=$($script:calls)"

    # --- D. the runner is wired -------------------------------------------
    ''
    '-- D. scripts\acceptance-parallel.ps1 carries the arm'
    $runner = Get-Content -Raw -LiteralPath (Join-Path $Repo 'scripts\acceptance-parallel.ps1')
    $iBefore = $runner.IndexOf('$stateBefore = if ($NoStateCheck)')
    $iRun = $runner.IndexOf('Invoke-AcceptanceRun -Repo')
    $iCheck = $runner.IndexOf('Invoke-PersistentStateCheck -Before $stateBefore')
    Assert 'D1 the runner loads this library' ($runner -match [regex]::Escape("test\win32\lib\PersistentState.ps1"))
    Assert 'D2 the BEFORE snapshot is taken before any script starts, the check after the run' `
        ($iBefore -gt 0 -and $iRun -gt $iBefore -and $iCheck -gt $iRun) "before=$iBefore run=$iRun check=$iCheck"
    Assert 'D3 a state change blocks the GREEN verdict' ($runner -match '\$stateChanges\.Count -eq 0\) \{ ''GREEN'' \}')
    Assert 'D4 a state change fails the exit code' ($runner -match 'exit \(\[int\]\([^\r\n]*\$stateChanges\.Count -gt 0\)\)')
    Assert 'D5 the -NoStateCheck hatch says it was used' ($runner -match 'PERSISTENT STATE: not checked \(-NoStateCheck\)')

    Complete-TestBody
}
finally {
    try { [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree("Software\$hiveName", $false) } catch {}
    if (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue }
}

$gone = -not [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("Software\$hiveName")
Assert 'Z1 the scratch hive is gone afterwards (this harness obeys its own rule)' $gone

if ($script:failures -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard persistent-state -Repo $Repo 2>&1 | ForEach-Object { "  $_" }
}

''
Write-TestVerdict -Label 'T1230 PERSISTENT-STATE' -Pass $script:passes -Fail $script:failures
