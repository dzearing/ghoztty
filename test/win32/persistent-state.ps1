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
  E  the user's own update (T2188): a published release the user's in-app
     updater installs mid-run is attributed and does not fail the run; a leak
     beside it, an unpublished version, a fixture install elsewhere, a
     throwaway identity and a bare exe swap all still do.
  F  another lane's fixture (T2452): a key a LIVE script of ANOTHER run has
     claimed (lib\FixtureClaim.ps1) does not fail this run; the same key
     claimed by this run, by a dead process or by a reused pid, or a key no
     claim's pattern covers, still does - shown with a real second process.
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

    # --- E. the user's own update is attributed, nothing else is (T2188) ---
    ''
    '-- E. a published update the user took mid-run is not a leak; look-alikes still are'
    $arpSub = 'Software\Microsoft\Windows\CurrentVersion\Uninstall'
    $userInst = Join-Path $localAppData 'Programs\Ghoztty'
    New-Item -ItemType Directory -Force -Path $userInst | Out-Null
    Set-Content -LiteralPath (Join-Path $userInst 'ghoztty.exe') -Value 'old' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $userInst 'ghoztty.com') -Value 'old' -Encoding ASCII
    Set-ScratchValue "$arpSub\{T2188-OLD}" 'DisplayName' 'Ghoztty'
    Set-ScratchValue "$arpSub\{T2188-OLD}" 'DisplayVersion' '1.43.4'
    Set-ScratchValue "$arpSub\{T2188-OLD}" 'InstallLocation' "$userInst\"
    $u0 = Snap
    # what the updater does: retire the old entry, add the new one, swap the files
    [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree("$prefix$arpSub\{T2188-OLD}", $false)
    Set-ScratchValue "$arpSub\{T2188-NEW}" 'DisplayName' 'Ghoztty'
    Set-ScratchValue "$arpSub\{T2188-NEW}" 'DisplayVersion' '1.43.5'
    Set-ScratchValue "$arpSub\{T2188-NEW}" 'InstallLocation' "$userInst\"
    Set-Content -LiteralPath (Join-Path $userInst 'ghoztty.exe') -Value 'new-bytes' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $userInst 'ghoztty.com') -Value 'new-bytes' -Encoding ASCII
    $u1 = Snap
    $d = @(SnapDiff $u0 $u1)
    $script:asked = @()
    $published = { param($Tag) $script:asked += $Tag; $Tag -eq 'win-v1.43.5' }
    $r = Resolve-PersistentStateAttribution -Changes $d -HkcuPrefix $prefix -LocalAppData $localAppData -ReleaseExists $published
    Assert 'E1 the 2026-10-23 shape (old arp entry out, published version in, install files swapped) is ALL attributed to the user update' `
        ($d.Count -eq 4 -and @($r.UserUpdate).Count -eq 4 -and @($r.Unattributed).Count -eq 0 -and $r.Version -eq '1.43.5') "diff=$($d.Count) $(Show $d) | user=$(@($r.UserUpdate).Count) left=$(Show $r.Unattributed)"
    Assert 'E2 the release that was asked about is the arp version as a win-v tag' ($script:asked -contains 'win-v1.43.5') "asked: $($script:asked -join ',')"
    Assert 'E3 the attribution names the release and the install it landed in' ($r.Reason -match 'win-v1\.43\.5' -and $r.Reason -match 'updater') $r.Reason

    # a leak riding along with a real update is still a leak
    Set-ScratchValue 'Software\Microsoft\Windows\CurrentVersion\Run' 'GhozttyAgent-t2188' 'x.exe'
    $d = @(SnapDiff $u0 (Snap))
    $r = Resolve-PersistentStateAttribution -Changes $d -HkcuPrefix $prefix -LocalAppData $localAppData -ReleaseExists $published
    Assert 'E4 a Run value planted during the same run is NOT swallowed by the update attribution' `
        (@($r.Unattributed).Count -eq 1 -and $r.Unattributed[0].Surface -eq 'run' -and @($r.UserUpdate).Count -eq 4) "left=$(Show $r.Unattributed)"
    Remove-ScratchValue 'Software\Microsoft\Windows\CurrentVersion\Run' 'GhozttyAgent-t2188'

    # a version that is not a published release: the installed files changed and nothing explains it
    $r = Resolve-PersistentStateAttribution -Changes (SnapDiff $u0 $u1) -HkcuPrefix $prefix -LocalAppData $localAppData -ReleaseExists { param($Tag) $false }
    Assert 'E5 an unpublished version (a repo build swapped into the install) stays RED, and says why' `
        (@($r.Unattributed).Count -eq 4 -and @($r.UserUpdate).Count -eq 0 -and $r.Reason -match 'could not be confirmed') "left=$(@($r.Unattributed).Count) reason=$($r.Reason)"

    # the right name and version, but installed somewhere else (a fixture install)
    Set-ScratchValue "$arpSub\{T2188-NEW}" 'InstallLocation' (Join-Path $scratch 'elsewhere')
    $r = Resolve-PersistentStateAttribution -Changes (SnapDiff $u0 (Snap)) -HkcuPrefix $prefix -LocalAppData $localAppData -ReleaseExists $published
    Assert 'E6 a published version installed OUTSIDE the user''s install dir is not the user''s update' `
        (@($r.UserUpdate).Count -eq 0 -and $r.Reason -match 'not the user''s install') "user=$(@($r.UserUpdate).Count) reason=$($r.Reason)"
    Set-ScratchValue "$arpSub\{T2188-NEW}" 'InstallLocation' "$userInst\"

    # install files changed with no arp move at all: nothing to attribute it to
    $i0 = Snap
    Set-Content -LiteralPath (Join-Path $userInst 'ghoztty.exe') -Value 'third-bytes-x' -Encoding ASCII
    $r = Resolve-PersistentStateAttribution -Changes (SnapDiff $i0 (Snap)) -HkcuPrefix $prefix -LocalAppData $localAppData -ReleaseExists $published
    Assert 'E7 a swapped installed exe with no new Ghoztty uninstall entry is still a leak' `
        (@($r.Unattributed).Count -eq 1 -and @($r.UserUpdate).Count -eq 0) "left=$(Show $r.Unattributed)"

    # a throwaway installer identity at a published version number
    $t0 = Snap
    Set-ScratchValue "$arpSub\{T2188-FIX}" 'DisplayName' 'Ghoztty Throwaway t2188'
    Set-ScratchValue "$arpSub\{T2188-FIX}" 'DisplayVersion' '1.43.5'
    Set-ScratchValue "$arpSub\{T2188-FIX}" 'InstallLocation' "$userInst\"
    $script:asked = @()
    $r = Resolve-PersistentStateAttribution -Changes (SnapDiff $t0 (Snap)) -HkcuPrefix $prefix -LocalAppData $localAppData -ReleaseExists $published
    Assert 'E8 a test product whose name is not exactly Ghoztty is never attributed (and gh is not even asked)' `
        (@($r.UserUpdate).Count -eq 0 -and @($r.Unattributed).Count -eq 1 -and $script:asked.Count -eq 0) "user=$(@($r.UserUpdate).Count) asked=$($script:asked -join ',')"
    $r = Resolve-PersistentStateAttribution -Changes @() -LocalAppData $localAppData -ReleaseExists { throw 'must not be called' }
    Assert 'E9 an empty diff attributes nothing and asks nobody' (@($r.Unattributed).Count -eq 0 -and @($r.UserUpdate).Count -eq 0)

    # --- F. another lane's live fixture is attributed; a leak is not (T2452) ---
    ''
    '-- F. a fixture another run''s LIVE script claims is forgiven; its own run''s, or a dead claimant''s, is not'
    $claimDir = Join-Path $scratch 'claims'
    $hiveChange = [pscustomobject]@{ Surface = 'hives'; Item = 'Software\dzearing-cleanup-test'; Change = 'added'; Before = $null; After = '<key>' }
    $runChange = [pscustomobject]@{ Surface = 'run'; Item = 'GhozttyAgent-t2452'; Change = 'added'; Before = $null; After = 'String:x' }
    $cl = Register-PersistentStateClaim -Surface hives -Pattern 'Software\dzearing-cleanup-test' -ClaimDir $claimDir -RunId 'lane-a-run'
    $live = @(Get-PersistentStateClaims -ClaimDir $claimDir)
    Assert 'F1 a claim held by a live process (this one) reads back live, with its surface, pattern and run' `
        ($live.Count -eq 1 -and $live[0].surface -eq 'hives' -and $live[0].pid -eq $PID -and $live[0].run -eq 'lane-a-run' -and $live[0].script -match 'persistent-state\.ps1') "live=$($live.Count)"
    $r = Resolve-PersistentStateClaimAttribution -Changes @($hiveChange, $runChange) -RunId 'lane-b-run' -Claims $live
    Assert 'F2 the 2026-10-29 shape: lane a''s live cleanup hive is NOT a state change in lane b''s sweep, and is named' `
        (@($r.Concurrent).Count -eq 1 -and $r.Concurrent[0].Item -eq 'Software\dzearing-cleanup-test' -and $r.Reason -match 'persistent-state\.ps1 \(pid \d+, run lane-a-run\)') "concurrent=$(Show $r.Concurrent) reason=$($r.Reason)"
    Assert 'F3 a change no claim covers, in the same diff, still fails the run' `
        (@($r.Unattributed).Count -eq 1 -and $r.Unattributed[0].Surface -eq 'run') "left=$(Show $r.Unattributed)"
    $r = Resolve-PersistentStateClaimAttribution -Changes @($hiveChange) -RunId 'lane-a-run' -Claims $live
    Assert 'F4 NEGATIVE: the same key claimed by THIS run''s own script is still a leak (a run never excuses itself)' `
        (@($r.Unattributed).Count -eq 1 -and @($r.Concurrent).Count -eq 0) "left=$(@($r.Unattributed).Count)"
    $r = Resolve-PersistentStateClaimAttribution -Changes @($hiveChange) -RunId 'lane-b-run' `
        -Claims @(Get-PersistentStateClaims -ClaimDir $claimDir -ProcessStartTicks { param($ProcessId) $null })
    Assert 'F5 NEGATIVE: a claim whose process has exited excuses nothing (the leak shape: the script is gone, the key is not)' `
        (@($r.Unattributed).Count -eq 1) "left=$(@($r.Unattributed).Count)"
    $r = Resolve-PersistentStateClaimAttribution -Changes @($hiveChange) -RunId 'lane-b-run' `
        -Claims @(Get-PersistentStateClaims -ClaimDir $claimDir -ProcessStartTicks { param($ProcessId) [int64]1 })
    Assert 'F6 NEGATIVE: a reused pid (same number, another start time) is not the claimant' (@($r.Unattributed).Count -eq 1)
    $other = [pscustomobject]@{ Surface = 'hives'; Item = 'Software\ghoztty-test-fixture'; Change = 'added'; Before = $null; After = '<key>' }
    $r = Resolve-PersistentStateClaimAttribution -Changes @($other, ([pscustomobject]@{ Surface = 'run'; Item = 'Software\dzearing-cleanup-test'; Change = 'added'; Before = $null; After = 'x' })) -RunId 'lane-b-run' -Claims $live
    Assert 'F7 NEGATIVE: a claim excuses only its own surface and pattern - a neighbour hive, or the same name on another surface, still fails' `
        (@($r.Unattributed).Count -eq 2 -and @($r.Concurrent).Count -eq 0) "left=$(Show $r.Unattributed)"
    $arpChange = [pscustomobject]@{ Surface = 'arp'; Item = '{1234-ABCD}'; Change = 'added'; Before = $null; After = 'GhozttyT1299Test 1.2.3' }
    $arpClaim = @([pscustomobject]@{ surface = 'arp'; pattern = '*GhozttyT1299Test*'; pid = 1; started = 1; run = ''; script = 'install-walkthrough.ps1' })
    $r = Resolve-PersistentStateClaimAttribution -Changes @($arpChange) -RunId 'lane-b-run' -Claims $arpClaim
    Assert 'F8 an arp row (keyed by product code) is matched by the name its value reads; a hand run with no run id is foreign to every sweep' `
        (@($r.Concurrent).Count -eq 1 -and $r.Reason -match 'no run') "reason=$($r.Reason)"
    Assert 'F9 an unknown surface is refused at claim time, not silently unmatchable' `
        ($(try { $null = Register-PersistentStateClaim -Surface nope -Pattern x -ClaimDir $claimDir; $false } catch { $_.Exception.Message -match 'unknown persistent-state surface' }))
    Unregister-PersistentStateClaim -Path $cl
    Assert 'F10 an unregistered claim is gone from the ledger' (@(Get-PersistentStateClaims -ClaimDir $claimDir).Count -eq 0)

    # a real second process, the way another lane's script holds one
    $childScript = Join-Path $scratch 'claimant.ps1'
    $libPath = Join-Path $PSScriptRoot 'lib\FixtureClaim.ps1'
    Set-Content -LiteralPath $childScript -Encoding ASCII -Value @"
Set-StrictMode -Version 2.0
. '$libPath'
`$null = Register-PersistentStateClaim -Surface hives -Pattern 'Software\dzearing-cleanup-test' -ClaimDir '$claimDir' -RunId 'lane-a-run'
Start-Sleep -Seconds 60
"@
    $child = Start-Process -FilePath powershell.exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$childScript`"") -WindowStyle Hidden -PassThru
    $seen = @(); $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline) { $seen = @(Get-PersistentStateClaims -ClaimDir $claimDir); if ($seen.Count -gt 0) { break }; Start-Sleep -Milliseconds 200 }
    $r = Resolve-PersistentStateClaimAttribution -Changes @($hiveChange) -RunId 'lane-b-run' -Claims $seen
    Assert 'F11 live, cross-process: another process''s claim (under strict mode) excuses the key while that process runs' `
        ($seen.Count -eq 1 -and $seen[0].pid -eq $child.Id -and @($r.Concurrent).Count -eq 1) "seen=$($seen.Count) child=$($child.Id)"
    Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue
    $null = $child.WaitForExit(10000)
    $r = Resolve-PersistentStateClaimAttribution -Changes @($hiveChange) -RunId 'lane-b-run' -Claims @(Get-PersistentStateClaims -ClaimDir $claimDir)
    Assert 'F12 live, cross-process: once that process is dead the same key is a leak again' `
        (@($r.Unattributed).Count -eq 1 -and @($r.Concurrent).Count -eq 0) "left=$(@($r.Unattributed).Count)"
    $deadFile = @(Get-ChildItem -LiteralPath $claimDir -Filter '*.json')
    foreach ($f in $deadFile) { $f.LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-5) }
    $null = Get-PersistentStateClaims -ClaimDir $claimDir
    Assert 'F13 a dead claimant''s file is pruned from the ledger once it is a minute old' `
        ($deadFile.Count -eq 1 -and @(Get-ChildItem -LiteralPath $claimDir -Filter '*.json').Count -eq 0) "files before=$($deadFile.Count)"
    foreach ($pair in @(@('ghoztty-cleanup.ps1', 'Software\dzearing-cleanup-test'), @('crash-first-chance.ps1', 'Software\ghoztty-test-t808'))) {
        $src = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot $pair[0])
        Assert "F14 $($pair[0]) claims the hive it plants ($($pair[1])) and lets the claim go" `
            ($src -match [regex]::Escape("Register-PersistentStateClaim -Surface hives -Pattern '$($pair[1])'") -and $src -match 'Unregister-PersistentStateClaim')
    }

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
    $iAttr = $runner.IndexOf('Resolve-PersistentStateAttribution -Changes $stateChanges')
    $iVerdict = $runner.IndexOf("'GREEN'")
    Assert 'D6 the user-update attribution runs after the check and before the verdict, and only its leftovers count (T2188)' `
        ($iAttr -gt $iCheck -and $iVerdict -gt $iAttr -and $runner -match '\$stateChanges = @\(\$stateAttr\.Unattributed\)') "check=$iCheck attr=$iAttr verdict=$iVerdict"
    Assert 'D7 an attributed update is printed, never silently dropped' ($runner -match 'PERSISTENT STATE USER UPDATE')
    $iClaim = $runner.IndexOf('Resolve-PersistentStateClaimAttribution -Changes $stateChanges -RunId $env:GHOZTTY_ACCEPTANCE_RUN')
    $iRunId = $runner.IndexOf('$env:GHOZTTY_ACCEPTANCE_RUN = [guid]::NewGuid()')
    Assert 'D8 the runner names its run before any script starts, so its workers'' claims carry it (T2452)' ($iRunId -gt 0 -and $iRunId -lt $iRun) "runId=$iRunId run=$iRun"
    Assert 'D9 the concurrent-fixture attribution runs after the update attribution and before the verdict, and only its leftovers count' `
        ($iClaim -gt $iAttr -and $iVerdict -gt $iClaim -and $runner -match '\$stateChanges = @\(\$claimAttr\.Unattributed\)') "attr=$iAttr claim=$iClaim verdict=$iVerdict"
    Assert 'D10 an attributed concurrent fixture is printed, never silently dropped' ($runner -match 'PERSISTENT STATE CONCURRENT FIXTURE')

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
