# PersistentState.ps1 - snapshot the places a test run could change something
# PERMANENT about this machine, and diff two snapshots (T1230). Dot-source it:
#
#     . (Join-Path $Repo 'test\win32\lib\PersistentState.ps1')
#     $before = Get-PersistentStateSnapshot
#     ... run the suite ...
#     $diff = @(Compare-PersistentStateSnapshot -Before $before -After (Get-PersistentStateSnapshot))
#     $diff | ForEach-Object { Format-PersistentStateChange $_ }
#
# WHY THIS EXISTS
#
# T1168 found the suite writing permanent HKCU Run entries - four startup
# programs from one morning's soak runs - eight days after it started, by eye.
# It closed that hole (lib\HarnessLeak.ps1 tears the value down; the clean slate
# sweeps what a killed run left). The general question stayed open: the Run key
# is not the only durable place a run can reach, and until this file nothing
# compared any of the others before and after a run. scripts\acceptance-parallel.ps1
# now takes a snapshot before the first script starts and another after the last
# one ends, and a difference turns the run RED.
#
# THE SURFACES, and the answer for each (isolation = the run never reaches the
# user's copy; teardown = it does, and puts it back; snapshot = this file
# notices when either fails). Every surface below is SNAPSHOTTED; the column is
# what keeps it from changing in the first place.
#
#   run        HKCU\...\CurrentVersion\Run, every value with "ghoztty" in its
#              name. Isolation (T167 lineage-suffixed value names) + teardown
#              (T1168: Isolation.ps1 arms it, CleanSlate.ps1 sweeps a killed run).
#   env        HKCU\Environment: the PATH entries that name ghoztty, a zig-out
#              or %TEMP%, and every GHOZTTY_* value. Isolation: PathInstaller's
#              self-heal is gated off for a source checkout (T1151/T1213);
#              path-selfheal.ps1 restores what it plants.
#   classes    HKCU\Software\Classes\ghoztty* (the ghoztty:// handler), every
#              value of every subkey. Isolation: the location gate (T1151).
#              The ghoztty-debug* classes are LEFT OUT: a debug build rewrites
#              its own lineage's handler on every launch by design (the last
#              debug launch answers dev links, url_scheme.zig), so with two
#              lanes it flips between D:\git\ghoztty and D:\git\ghoztty-b on
#              any run that launches the app. Measured on T1230's first live
#              run, which read that flip as a leak.
#   hives      HKCU\Software top-level keys named *ghoztty* / *dzearing*, and the
#              key names under HKCU\Software\dzearing. Teardown: the fixture
#              hives (arp-version, crash-first-chance, ghoztty-cleanup,
#              install-walkthrough) each remove their own.
#   arp        HKCU\...\Uninstall entries whose key or DisplayName says ghoztty,
#              with DisplayVersion. Isolation: ThrowawayProduct.ps1 identities.
#   tasks      scheduled tasks named *ghoztty* (path + name). Nothing in the
#              suite should create one; the loop's own (GhozttyGoLoopWatchdog*,
#              GhozttySoakDaemon, GhozttyTaskDashboard) are re-registered under
#              the same names, so a name set is the stable thing to compare.
#   startmenu  %APPDATA%\...\Start Menu\Programs, recursively, every entry named
#              *ghoztty* - which includes the Startup folder's ghoztty-agent.cmd.
#              Isolation: installer tests use throwaway identities.
#   install    %LOCALAPPDATA%\Programs\Ghoztty\ghoztty.exe / ghoztty-agent.exe /
#              ghoztty.com, length + write time. The non-negotiable "never touch
#              the user's installed Ghoztty", measured instead of trusted.
#              The user may take a PUBLISHED update mid-run, which changes this
#              surface and arp exactly like a leak would; the runner asks
#              Resolve-PersistentStateAttribution before judging (T2188).
#   account    %LOCALAPPDATA%\ghoztty\account-debug.dat, length + write time:
#              the DEBUG lineage's DPAPI sign-in blob, which a debug test run
#              could reach with the real LOCALAPPDATA.
#
# DELIBERATELY NOT SNAPSHOTTED, and why:
#
#   %LOCALAPPDATA%\ghoztty\account.dat and the release state dir (session-layout
#   manifests, the agent's state) - the user's LIVE installed release rewrites
#   them during any run (a token refresh, a layout save), so a diff there would
#   be the user's own terminal, not the suite. Their protection is isolation:
#   test\win32\lib\BuildMode.ps1 refuses a non-debug build before anything
#   launches (T350), and Set-GhozttyTestIsolation -ReleaseSandbox moves
#   LOCALAPPDATA for the scripts whose subject is a release build.
#   The debug state dir (%LOCALAPPDATA%\ghoztty-debug*) - the suite's own working
#   surface, reset by the clean slate on purpose.
#
# A CONCURRENT RUN. Lane B runs its own suite on this box; a value its run has
# planted and has not yet removed can be standing at this run's AFTER snapshot.
# The caller re-snapshots after a settle delay and reports only what is still
# different (see Invoke-PersistentStateCheck), so a transient of somebody
# else's does not paint this run red - and a real leak, which does not go away,
# still does.
#
# SEAMS (for test\win32\persistent-state.ps1, which must be able to make every
# surface change without touching the user's real state): -HkcuPrefix reroots
# every registry read under a scratch key, -AppData / -LocalAppData reroot the
# folders, and -TaskSource replaces the scheduled-task query.
#
# ASCII-only by design (PS 5.1 mangles non-ASCII on rewrite).

Set-StrictMode -Off

$script:PersistentStateSurfaces = @('run', 'env', 'classes', 'hives', 'arp', 'tasks', 'startmenu', 'install', 'account')

function Get-PsRegKey {
    param([string]$Sub)
    try { return [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($Sub, $false) } catch { return $null }
}

# Every value of a key, as name -> "kind:data" strings (REG_EXPAND_SZ is read
# unexpanded, so a change to the raw text is a change).
function Get-PsRegValueMap {
    param($Key, [string]$Prefix)
    $out = [ordered]@{}
    foreach ($n in @($Key.GetValueNames() | Sort-Object)) {
        $v = $Key.GetValue($n, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if ($v -is [array]) { $v = ($v | ForEach-Object { [string]$_ }) -join '|' }
        $label = if ($n -eq '') { '(default)' } else { $n }
        $out["$Prefix$label"] = "$($Key.GetValueKind($n)):$v"
    }
    return $out
}

function Add-PsRegTree {
    param($Into, [string]$Sub, [string]$Label, [int]$Depth = 8)
    $k = Get-PsRegKey $Sub
    if (-not $k) { return }
    try {
        $Into["$Label\"] = '<key>'
        $vals = Get-PsRegValueMap -Key $k -Prefix "$Label\"
        foreach ($e in $vals.GetEnumerator()) { $Into[$e.Key] = $e.Value }
        if ($Depth -gt 0) {
            foreach ($c in @($k.GetSubKeyNames() | Sort-Object)) {
                Add-PsRegTree -Into $Into -Sub "$Sub\$c" -Label "$Label\$c" -Depth ($Depth - 1)
            }
        }
    } finally { $k.Close() }
}

function Get-PsFileStamp {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $i = Get-Item -LiteralPath $Path -Force
    return "{0} bytes, written {1}" -f $i.Length, $i.LastWriteTimeUtc.ToString('o')
}

<#
.SYNOPSIS
  One snapshot: an ordered map of surface -> (item -> string). An item absent
  from a surface's map is absent from the machine; the strings are only ever
  compared for equality.
#>
function Get-PersistentStateSnapshot {
    param(
        [string]$HkcuPrefix = '',
        [string]$AppData = $env:APPDATA,
        [string]$LocalAppData = $env:LOCALAPPDATA,
        [scriptblock]$TaskSource,
        [string[]]$Surfaces = $script:PersistentStateSurfaces
    )
    $snap = [ordered]@{}
    $p = $HkcuPrefix

    foreach ($s in $Surfaces) {
        $m = [ordered]@{}
        switch ($s) {
            'run' {
                $k = Get-PsRegKey "${p}Software\Microsoft\Windows\CurrentVersion\Run"
                if ($k) {
                    try {
                        $all = Get-PsRegValueMap -Key $k -Prefix ''
                        foreach ($e in $all.GetEnumerator()) { if ($e.Key -match 'ghoztty') { $m[$e.Key] = $e.Value } }
                    } finally { $k.Close() }
                }
            }
            'env' {
                $k = Get-PsRegKey "${p}Environment"
                if ($k) {
                    try {
                        $temp = [IO.Path]::GetTempPath().TrimEnd('\')
                        foreach ($n in @($k.GetValueNames())) {
                            if ($n -like 'GHOZTTY*') {
                                $m["value:$n"] = [string]$k.GetValue($n, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                            }
                        }
                        $path = [string]$k.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                        foreach ($entry in @($path -split ';' | Where-Object { $_ })) {
                            $hit = ($entry -match 'ghoztty') -or ($entry -match 'zig-out') -or
                                ($temp -and $entry.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase)) -or
                                ($entry -match '%TEMP%|%TMP%')
                            if ($hit) { $m["path:$entry"] = 'present' }
                        }
                    } finally { $k.Close() }
                }
            }
            'classes' {
                $k = Get-PsRegKey "${p}Software\Classes"
                if ($k) {
                    $names = @()
                    try {
                        $names = @($k.GetSubKeyNames() | Where-Object { $_ -like 'ghoztty*' -and $_ -notlike 'ghoztty-debug*' } | Sort-Object)
                    } finally { $k.Close() }
                    foreach ($n in $names) { Add-PsRegTree -Into $m -Sub "${p}Software\Classes\$n" -Label $n }
                }
            }
            'hives' {
                $k = Get-PsRegKey "${p}Software"
                if ($k) {
                    try {
                        foreach ($n in @($k.GetSubKeyNames() | Where-Object { $_ -match 'ghoztty|dzearing' } | Sort-Object)) { $m["Software\$n"] = '<key>' }
                    } finally { $k.Close() }
                }
                $d = Get-PsRegKey "${p}Software\dzearing"
                if ($d) {
                    try { foreach ($n in @($d.GetSubKeyNames() | Sort-Object)) { $m["Software\dzearing\$n"] = '<key>' } } finally { $d.Close() }
                }
            }
            'arp' {
                $sub = "${p}Software\Microsoft\Windows\CurrentVersion\Uninstall"
                $k = Get-PsRegKey $sub
                if ($k) {
                    $names = @()
                    try { $names = @($k.GetSubKeyNames() | Sort-Object) } finally { $k.Close() }
                    foreach ($n in $names) {
                        $c = Get-PsRegKey "$sub\$n"
                        if (-not $c) { continue }
                        try {
                            $dn = [string]$c.GetValue('DisplayName', '')
                            if (($n -match 'ghoztty') -or ($dn -match 'ghoztty')) {
                                $m[$n] = "$dn $([string]$c.GetValue('DisplayVersion', ''))".Trim()
                            }
                        } finally { $c.Close() }
                    }
                }
            }
            'tasks' {
                $rows = if ($TaskSource) { @(& $TaskSource) } else {
                    @(try { Get-ScheduledTask -ErrorAction Stop } catch { })
                }
                foreach ($t in $rows) {
                    if ($t.TaskName -match 'ghoztty') { $m["$($t.TaskPath)$($t.TaskName)"] = 'present' }
                }
            }
            'startmenu' {
                if ($AppData) {
                    $root = Join-Path $AppData 'Microsoft\Windows\Start Menu\Programs'
                    if (Test-Path -LiteralPath $root) {
                        foreach ($i in @(Get-ChildItem -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue |
                                    Where-Object { $_.Name -match 'ghoztty' })) {
                            $m[$i.FullName.Substring($root.Length).TrimStart('\')] = if ($i.PSIsContainer) { '<dir>' } else { "$($i.Length) bytes" }
                        }
                    }
                }
            }
            'install' {
                if ($LocalAppData) {
                    foreach ($f in @('ghoztty.exe', 'ghoztty.com', 'ghoztty-agent.exe')) {
                        $st = Get-PsFileStamp (Join-Path $LocalAppData "Programs\Ghoztty\$f")
                        if ($st) { $m[$f] = $st }
                    }
                }
            }
            'account' {
                if ($LocalAppData) {
                    $st = Get-PsFileStamp (Join-Path $LocalAppData 'ghoztty\account-debug.dat')
                    if ($st) { $m['account-debug.dat'] = $st }
                }
            }
            default { throw "unknown persistent-state surface '$s'" }
        }
        $snap[$s] = $m
    }
    return $snap
}

<#
.SYNOPSIS
  Every item that differs between two snapshots, as objects with Surface, Item,
  Change ('added' / 'removed' / 'changed'), Before and After. Nothing for two
  equal snapshots. Only surfaces present in BOTH are compared.
#>
function Compare-PersistentStateSnapshot {
    param($Before, $After)
    foreach ($s in @($Before.Keys)) {
        if (-not $After.Contains($s)) { continue }
        $b = $Before[$s]; $a = $After[$s]
        $keys = @(@($b.Keys) + @($a.Keys) | Sort-Object -Unique)
        foreach ($k in $keys) {
            $inB = $b.Contains($k); $inA = $a.Contains($k)
            $change = if ($inB -and -not $inA) { 'removed' }
                elseif ($inA -and -not $inB) { 'added' }
                elseif ([string]$b[$k] -cne [string]$a[$k]) { 'changed' }
                else { $null }
            if ($change) {
                [pscustomobject]@{
                    Surface = $s; Item = $k; Change = $change
                    Before = if ($inB) { $b[$k] } else { $null }
                    After  = if ($inA) { $a[$k] } else { $null }
                }
            }
        }
    }
}

function Format-PersistentStateChange {
    param($Change)
    switch ($Change.Change) {
        'added'   { "{0} ADDED {1} = {2}" -f $Change.Surface, $Change.Item, $Change.After }
        'removed' { "{0} REMOVED {1} (was {2})" -f $Change.Surface, $Change.Item, $Change.Before }
        default   { "{0} CHANGED {1}: {2} -> {3}" -f $Change.Surface, $Change.Item, $Change.Before, $Change.After }
    }
}

<#
.SYNOPSIS
  Split a diff into what the USER'S OWN IN-APP UPDATE did and what nothing
  explains (T2188). Returns an object with Unattributed (the changes that still
  fail the run), UserUpdate (the changes attributed to the update), Version and
  Reason.

.DESCRIPTION
  The install and arp surfaces watch the user's installed Ghoztty, and the user
  is free to take a published update while a run is going: on 2026-10-23 the
  updater installed win-v1.43.5 mid-run and a green run ended RED with
  state-changes=4. A snapshot diff alone cannot tell that from a test writing
  into the install, so this asks for the evidence a real update leaves and a
  test leak does not, ALL of it:

    1. an arp entry was ADDED or CHANGED to exactly "Ghoztty <x.y.z>" - the
       product's own name (throwaway installer identities carry other names);
    2. that entry's InstallLocation is the user's install,
       <LocalAppData>\Programs\Ghoztty - read live from the key;
    3. win-v<x.y.z> is a PUBLISHED release on dzearing/ghoztty (not a draft,
       not merely a tag) - -ReleaseExists is the seam, gh is the default.

  Only then are these changes attributed to it: the install surface's three
  files, that arp entry, and arp entries REMOVED that read "Ghoztty <ver>"
  (a major upgrade retires the previous version's entry). Anything else in the
  diff - a Run value, a start menu item, a second product - stays unattributed
  and still turns the run red. A release that cannot be confirmed (no gh, no
  network) attributes nothing: the check fails closed, never open.
#>
function Resolve-PersistentStateAttribution {
    param(
        $Changes,
        [string]$HkcuPrefix = '',
        [string]$LocalAppData = $env:LOCALAPPDATA,
        [scriptblock]$ReleaseExists = {
            param([string]$Tag)
            $out = & { $ErrorActionPreference = 'Continue'; gh release view $Tag --repo dzearing/ghoztty --json tagName,isDraft 2>$null }
            if ($LASTEXITCODE -ne 0 -or -not $out) { return $false }
            try { $j = ($out -join "`n") | ConvertFrom-Json; return ($j.tagName -eq $Tag -and -not $j.isDraft) } catch { return $false }
        }
    )
    $all = @($Changes | Where-Object { $_ })
    $result = [pscustomobject]@{ Unattributed = $all; UserUpdate = @(); Version = $null; Reason = $null }
    if ($all.Count -eq 0 -or -not $LocalAppData) { return $result }

    $userInstall = (Join-Path $LocalAppData 'Programs\Ghoztty').TrimEnd('\')
    $sub = "${HkcuPrefix}Software\Microsoft\Windows\CurrentVersion\Uninstall"
    $candidate = $null
    foreach ($c in @($all | Where-Object { $_.Surface -eq 'arp' -and $_.Change -in @('added', 'changed') })) {
        if ([string]$c.After -notmatch '^Ghoztty (\d+\.\d+\.\d+)$') { continue }
        $ver = $Matches[1]
        $loc = $null
        $k = Get-PsRegKey "$sub\$($c.Item)"
        if ($k) { try { $loc = [string]$k.GetValue('InstallLocation', '') } finally { $k.Close() } }
        if (-not $loc -or -not $loc.TrimEnd('\').Equals($userInstall, [StringComparison]::OrdinalIgnoreCase)) {
            $result.Reason = "arp $($c.Item) reads Ghoztty $ver but its InstallLocation '$loc' is not the user's install"
            continue
        }
        if (-not (& $ReleaseExists "win-v$ver")) {
            $result.Reason = "arp $($c.Item) reads Ghoztty $ver, but win-v$ver could not be confirmed as a published release"
            continue
        }
        $candidate = $c; $result.Version = $ver
        break
    }
    if (-not $candidate) { return $result }

    $installFiles = @('ghoztty.exe', 'ghoztty.com', 'ghoztty-agent.exe')
    $mine = @(); $rest = @()
    foreach ($c in $all) {
        $isUpdate = ($c -eq $candidate) -or
            ($c.Surface -eq 'install' -and $installFiles -contains $c.Item) -or
            ($c.Surface -eq 'arp' -and $c.Change -eq 'removed' -and [string]$c.Before -match '^Ghoztty \d+\.\d+\.\d+$')
        if ($isUpdate) { $mine += $c } else { $rest += $c }
    }
    $result.UserUpdate = $mine
    $result.Unattributed = $rest
    $result.Reason = "the user's in-app updater installed published release win-v$($result.Version) into $userInstall during the run"
    return $result
}

<#
.SYNOPSIS
  The after-half of the arm: snapshot, and if anything differs from -Before,
  wait -SettleSeconds and snapshot again, returning only what is STILL
  different. A transient planted by a concurrent run (another lane's suite)
  is gone by then; a leak is not. -Snapshot replaces the snapshot call (the
  harness's seam).
#>
function Invoke-PersistentStateCheck {
    param($Before, [int]$SettleSeconds = 15, [scriptblock]$Snapshot = { Get-PersistentStateSnapshot })
    $diff = @(Compare-PersistentStateSnapshot -Before $Before -After (& $Snapshot))
    if ($diff.Count -eq 0) { return @() }
    if ($SettleSeconds -gt 0) { Start-Sleep -Seconds $SettleSeconds }
    return @(Compare-PersistentStateSnapshot -Before $Before -After (& $Snapshot))
}
