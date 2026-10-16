# MachineLock.ps1 - the box-wide locks two loop lanes take turns on (T1982).
#
# Two loop lanes (T1937) share one box. Almost everything they do can overlap:
# each has its own worktree, zig-out and test endpoints. Two things cannot:
#
#   timing  Global\GhozttyTimingTest - a script that declares
#           `# @timing-sensitive` measures a wall-clock or CPU budget (resize
#           flicker, drag perf, ingest lag, soak). The other lane's compile
#           makes that measurement read wrong, so a timing script holds this
#           for its whole run. test\win32\lib\CleanSlate.ps1 takes it for any
#           script carrying the marker, so the marker IS the opt-in: a script
#           without it never waits.
#   floor   Global\GhozttyHarnessFloor - `floor-lane.ps1 -Lane harness` is
#           fifteen-plus minutes of source scanning; two at once halve both.
#
# Waiting is BOUNDED and PRINTED, never silent: the first line names who holds
# the lock (from a holder file written beside it), a line every -PollSeconds
# says it is still waiting, and the end says how long it took. A wait that runs
# out returns Acquired=$false and the caller decides - a timing script reports
# ASSERTED NOTHING (a measurement under the other lane's load is not evidence),
# the floor runs anyway and says so.
#
# A process that dies holding a lock abandons the mutex; the next waiter gets
# AbandonedMutexException, which is ownership, so a crash never wedges a lane.
# The mutex is thread-affine and held until Exit-MachineLock or process exit.
#
# Test seams: GHOZTTY_MACHINE_LOCK_SCOPE suffixes every mutex name and
# GHOZTTY_MACHINE_LOCK_DIR moves the holder files, so the acceptance harness
# (test\win32\machine-lock.ps1) never contends with a real lane.

$script:MachineLockKinds = @{
    timing = @{ Base = 'GhozttyTimingTest'; Label = 'TIMING LOCK'; WaitMinutes = 20 }
    floor  = @{ Base = 'GhozttyHarnessFloor'; Label = 'FLOOR LOCK'; WaitMinutes = 45 }
}

function Get-MachineLockName {
    param([ValidateSet('timing', 'floor')][string]$Kind)
    $name = 'Global\' + $script:MachineLockKinds[$Kind].Base
    $scope = [string]$env:GHOZTTY_MACHINE_LOCK_SCOPE
    if ($scope) { $name += '-' + ($scope -replace '[^A-Za-z0-9_-]', '_') }
    return $name
}

function Get-MachineLockHolderPath {
    param([ValidateSet('timing', 'floor')][string]$Kind)
    $dir = [string]$env:GHOZTTY_MACHINE_LOCK_DIR
    if (-not $dir) { $dir = Join-Path $env:LOCALAPPDATA 'ghoztty\machine-locks' }
    $leaf = (Get-MachineLockName -Kind $Kind) -replace '^Global\\', ''
    return (Join-Path $dir ($leaf + '.json'))
}

# Which lane is asking: GHOZTTY_LOOP_LANE when set (LoopLedger.ps1's rule),
# else the worktree the caller runs from.
function Get-MachineLockLane {
    if ($env:GHOZTTY_LOOP_LANE) { return [string]$env:GHOZTTY_LOOP_LANE }
    return (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent)
}

function Read-MachineLockHolder {
    param([string]$Kind)
    $p = Get-MachineLockHolderPath -Kind $Kind
    try {
        if (Test-Path -LiteralPath $p) { return (Get-Content -LiteralPath $p -Raw | ConvertFrom-Json) }
    } catch { }
    return $null
}

function Format-MachineLockHolder {
    param($Holder)
    if ($null -eq $Holder) { return 'an unnamed holder (no holder file)' }
    # A holder that exits without Exit-MachineLock (the usual case: a timing
    # script holds the lock until its process ends) leaves its file behind.
    # The next holder overwrites it; until then, say it is stale.
    $gone = $null -eq (Get-Process -Id ([int]$Holder.pid) -ErrorAction SilentlyContinue)
    $tail = if ($gone) { '; that pid is gone, so the file is stale' } else { '' }
    return ("{0} (lane {1}, pid {2}, since {3}{4})" -f $Holder.label, $Holder.lane, $Holder.pid, $Holder.at, $tail)
}

function Enter-MachineLock {
    <#
    .SYNOPSIS
        Take a box-wide lock, waiting at most -WaitMinutes and saying so.
        Returns @{ Acquired; WaitedSeconds; Holder; Kind; Mutex; Reentrant }.
    #>
    param(
        [ValidateSet('timing', 'floor')][string]$Kind,
        [string]$Label,
        [double]$WaitMinutes = -1,
        [int]$PollSeconds = 30
    )
    $k = $script:MachineLockKinds[$Kind]
    if ($WaitMinutes -lt 0) {
        $envWait = [string][Environment]::GetEnvironmentVariable("GHOZTTY_$($Kind.ToUpper())_LOCK_WAIT_MIN")
        $WaitMinutes = if ($envWait) { [double]$envWait } else { [double]$k.WaitMinutes }
    }
    if (-not (Get-Variable -Name GhozttyMachineLocks -Scope Global -ErrorAction SilentlyContinue)) {
        $global:GhozttyMachineLocks = @{}
    }
    # Held already by this process (a script that dot-sources CleanSlate twice).
    if ($global:GhozttyMachineLocks.ContainsKey($Kind)) {
        $held = $global:GhozttyMachineLocks[$Kind]
        return [pscustomobject]@{ Acquired = $true; WaitedSeconds = 0; Holder = $null; Kind = $Kind; Mutex = $held; Reentrant = $true }
    }

    $name = Get-MachineLockName -Kind $Kind
    $mutex = New-Object System.Threading.Mutex($false, $name)
    $started = Get-Date
    $deadline = $started.AddMinutes($WaitMinutes)
    $acquired = $false
    $announced = $false
    $holder = $null
    while ($true) {
        $remainingMs = [int][Math]::Max(0, [Math]::Min($PollSeconds * 1000, ($deadline - (Get-Date)).TotalMilliseconds))
        if (-not $announced) { $remainingMs = 0 }   # first try is instant, so the wait can be announced
        try {
            $acquired = $mutex.WaitOne($remainingMs)
        } catch [System.Threading.AbandonedMutexException] {
            $acquired = $true
            Write-Host ("{0}: the previous holder died without releasing {1}; taking it" -f $k.Label, $name)
        }
        if ($acquired) { break }
        $holder = Read-MachineLockHolder -Kind $Kind
        $waited = [int]((Get-Date) - $started).TotalSeconds
        if (-not $announced) {
            Write-Host ("{0} WAIT: {1} is held by {2}; {3} waits up to {4} min" -f $k.Label, $name, (Format-MachineLockHolder $holder), $Label, $WaitMinutes)
            $announced = $true
            continue
        }
        if ((Get-Date) -ge $deadline) {
            Write-Host ("{0} TIMEOUT after {1}s: {2} is still held by {3}" -f $k.Label, $waited, $name, (Format-MachineLockHolder $holder))
            $mutex.Dispose()
            return [pscustomobject]@{ Acquired = $false; WaitedSeconds = $waited; Holder = $holder; Kind = $Kind; Mutex = $null; Reentrant = $false }
        }
        Write-Host ("{0}: still waiting for {1} ({2}s)" -f $k.Label, $name, $waited)
    }

    $waitedSec = [int]((Get-Date) - $started).TotalSeconds
    $global:GhozttyMachineLocks[$Kind] = $mutex
    $hp = Get-MachineLockHolderPath -Kind $Kind
    try {
        $dir = Split-Path $hp -Parent
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $rec = [ordered]@{ label = $Label; lane = (Get-MachineLockLane); pid = $PID; at = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss') }
        [IO.File]::WriteAllText($hp, ($rec | ConvertTo-Json -Compress))
    } catch { }
    if ($announced) {
        Write-Host ("{0} acquired after {1}s: {2} for {3}" -f $k.Label, $waitedSec, $name, $Label)
    } else {
        Write-Host ("{0} acquired: {1} for {2}" -f $k.Label, $name, $Label)
    }
    return [pscustomobject]@{ Acquired = $true; WaitedSeconds = $waitedSec; Holder = $holder; Kind = $Kind; Mutex = $mutex; Reentrant = $false }
}

function Exit-MachineLock {
    param($Lock)
    if ($null -eq $Lock -or -not $Lock.Acquired -or $Lock.Reentrant) { return }
    $hp = Get-MachineLockHolderPath -Kind $Lock.Kind
    try {
        $h = Read-MachineLockHolder -Kind $Lock.Kind
        if ($h -and [int]$h.pid -eq $PID) { Remove-Item -LiteralPath $hp -Force -ErrorAction SilentlyContinue }
    } catch { }
    try { $Lock.Mutex.ReleaseMutex() } catch { }
    try { $Lock.Mutex.Dispose() } catch { }
    if ($global:GhozttyMachineLocks) { $global:GhozttyMachineLocks.Remove($Lock.Kind) }
}

# The script on the call stack that declares `# @timing-sensitive`, or $null.
# Same marker rule as scripts\lib\AcceptanceParallel.ps1.
function Find-TimingSensitiveCaller {
    foreach ($f in @(Get-PSCallStack)) {
        $p = [string]$f.ScriptName
        if (-not $p -or $p -match '\\lib\\[^\\]+\.ps1$') { continue }
        try {
            $raw = [IO.File]::ReadAllText($p)
            if ($raw -match '(?m)^[ \t]*#[ \t]*@timing-sensitive\b') { return $p }
        } catch { }
    }
    return $null
}

# CleanSlate's hook: a timing-sensitive caller takes the timing lock for the
# rest of its run, or ends with ASSERTED NOTHING (exit 2) when the wait runs out.
function Invoke-TimingLockForCaller {
    if ($env:GHOZTTY_TIMING_LOCK -eq '0') { return }
    $caller = Find-TimingSensitiveCaller
    if (-not $caller) { return }
    $lock = Enter-MachineLock -Kind timing -Label (Split-Path $caller -Leaf)
    if (-not $lock.Acquired) {
        Write-Host ("ASSERTED NOTHING (timing lock: another lane held {0} for the whole wait, and a measurement taken under its load is not evidence; re-run when it is free)" -f (Get-MachineLockName -Kind timing))
        # [Environment]::Exit, not `exit`: this runs while CleanSlate.ps1 is
        # being dot-sourced, and `exit` there only ends the dot-sourced file -
        # the caller would go on and measure under the other lane's load
        # (caught by section B of test\win32\machine-lock.ps1). Nothing has
        # been launched yet at this point, so there is nothing to tear down.
        [Environment]::Exit(2)
    }
}
