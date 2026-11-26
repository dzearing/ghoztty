# FixtureClaim.ps1 - the box-wide ledger of fixtures a test has planted on a
# surface the persistent-state arm snapshots (T2452). Dot-source it from a
# fixture script (PersistentState.ps1 loads it too):
#
#     . (Join-Path $PSScriptRoot 'lib\FixtureClaim.ps1')
#     $claim = Register-PersistentStateClaim -Surface hives -Pattern 'Software\my-fixture'
#     ... plant HKCU:\Software\my-fixture, test, remove it ...
#     Unregister-PersistentStateClaim -Path $claim
#
# Strict-mode safe and sets no mode of its own (a fixture script that runs
# under Set-StrictMode -Version 2.0 keeps it). ASCII only, PS 5.1 compatible.

#
# T2452. PersistentState.ps1's settle re-check forgives another lane's TRANSIENT, but a
# fixture that stands for longer than the settle delay still painted this run
# red: on 2026-10-29 lane b's sweep ended state-changes=1 for
# HKCU\Software\dzearing-cleanup-test, a key only ghoztty-cleanup.ps1 writes -
# running in lane a at the time, not in lane b's sweep at all.
#
# So a script that plants a fixture on a snapshotted surface CLAIMS it first, in
# a box-wide ledger every lane reads (the user-scope TEMP, which every lane and
# every parallel-runner worker share whatever their process env says). A claim
# names the surface, an item pattern, the claiming process (pid + start time,
# so a reused pid is not mistaken for the claimant) and the acceptance run it
# belongs to (GHOZTTY_ACCEPTANCE_RUN, which acceptance-parallel.ps1 sets for
# its workers). A sweep then forgives a change ONLY when a claim from a
# DIFFERENT run is held by a process that is STILL ALIVE. Its own run's claims
# never excuse anything, and neither does a claim whose process is gone - which
# is exactly the shape of a leak, so a leak still turns the run red.

function Get-PersistentStateClaimDir {
    if ($env:GHOZTTY_FIXTURE_CLAIM_DIR) { return $env:GHOZTTY_FIXTURE_CLAIM_DIR }
    $t = [Environment]::GetEnvironmentVariable('TEMP', 'User')
    if ($t) { $t = [Environment]::ExpandEnvironmentVariables($t) } else { $t = [IO.Path]::GetTempPath() }
    return (Join-Path $t 'ghoztty-fixture-claims')
}

function Get-PsProcessStartTicks {
    param([int]$ProcessId)
    try { return (Get-Process -Id $ProcessId -ErrorAction Stop).StartTime.ToUniversalTime().Ticks } catch { return $null }
}

<#
.SYNOPSIS
  Claim a fixture this script is about to plant on a snapshotted surface.
  -Pattern is a -like pattern matched against a change's Item, or its
  Before/After text (an arp row is keyed by product code but reads by name).
  Returns the claim file's path; hand it to Unregister-PersistentStateClaim at
  teardown (a claim whose process has exited excuses nothing either way).
#>
function Register-PersistentStateClaim {
    param(
        [Parameter(Mandatory = $true)][string]$Surface,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [string]$ClaimDir = (Get-PersistentStateClaimDir),
        [int]$ProcessId = $PID,
        [string]$RunId = $env:GHOZTTY_ACCEPTANCE_RUN,
        [string]$Script = $MyInvocation.PSCommandPath
    )
    if (@('run', 'env', 'classes', 'hives', 'arp', 'tasks', 'startmenu', 'install', 'account') -notcontains $Surface) { throw "unknown persistent-state surface '$Surface'" }
    New-Item -ItemType Directory -Force -Path $ClaimDir | Out-Null
    $claim = [ordered]@{
        surface = $Surface; pattern = $Pattern; pid = $ProcessId
        started = Get-PsProcessStartTicks -ProcessId $ProcessId
        run = [string]$RunId; script = [string]$Script; at = (Get-Date).ToString('o')
    }
    $path = Join-Path $ClaimDir ("{0}-{1}.json" -f $ProcessId, [guid]::NewGuid().ToString('N').Substring(0, 12))
    [IO.File]::WriteAllText($path, ($claim | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding $false))
    return $path
}

function Unregister-PersistentStateClaim {
    param([string]$Path)
    if ($Path) { Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue }
}

<#
.SYNOPSIS
  Every claim in the ledger whose claiming process is still alive (same pid,
  same start time). Claims of exited processes are reported nowhere and their
  files are pruned. -ProcessStartTicks is the seam for the harness.
#>
function Get-PersistentStateClaims {
    param(
        [string]$ClaimDir = (Get-PersistentStateClaimDir),
        [scriptblock]$ProcessStartTicks = { param($ProcessId) Get-PsProcessStartTicks -ProcessId $ProcessId }
    )
    if (-not (Test-Path -LiteralPath $ClaimDir)) { return @() }
    $live = @()
    foreach ($f in @(Get-ChildItem -LiteralPath $ClaimDir -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        $c = $null
        try { $c = [IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json } catch { }
        if (-not $c -or -not $c.pid) { continue }
        $now = & $ProcessStartTicks ([int]$c.pid)
        if ($null -ne $now -and $null -ne $c.started -and [int64]$now -eq [int64]$c.started) {
            $live += $c
        } elseif ($f.LastWriteTimeUtc -lt [DateTime]::UtcNow.AddMinutes(-1)) {
            # dead (or a reused pid): it excuses nothing, so drop the file -
            # after a minute, so a claim written this instant is never raced
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
        }
    }
    return $live
}

<#
.SYNOPSIS
  Split a diff into what a CONCURRENT run's live fixture explains and what it
  does not. Returns Unattributed (still fails the run), Concurrent, Reason.
  A claim excuses a change only when its surface matches, its pattern matches
  the change's Item / Before / After, and its run is NOT -RunId.
#>
function Resolve-PersistentStateClaimAttribution {
    param($Changes, [string]$RunId = $env:GHOZTTY_ACCEPTANCE_RUN, $Claims = $null)
    $all = @($Changes | Where-Object { $_ })
    $result = [pscustomobject]@{ Unattributed = $all; Concurrent = @(); Reason = $null }
    if ($all.Count -eq 0) { return $result }
    if ($null -eq $Claims) { $Claims = @(Get-PersistentStateClaims) }
    $foreign = @($Claims | Where-Object { $_ -and -not ($RunId -and [string]$_.run -eq $RunId) })
    if ($foreign.Count -eq 0) { return $result }
    $mine = @(); $rest = @(); $who = @()
    foreach ($c in $all) {
        $hit = $null
        foreach ($cl in $foreign) {
            if ($cl.surface -ne $c.Surface) { continue }
            $p = [string]$cl.pattern
            if (($c.Item -like $p) -or ([string]$c.Before -like $p) -or ([string]$c.After -like $p)) { $hit = $cl; break }
        }
        if ($hit) {
            $mine += $c
            $who += "{0} (pid {1}{2})" -f (Split-Path -Leaf ([string]$hit.script)), $hit.pid, $(if ($hit.run) { ", run $($hit.run)" } else { ', no run' })
        } else { $rest += $c }
    }
    $result.Concurrent = $mine
    $result.Unattributed = $rest
    if ($mine.Count -gt 0) { $result.Reason = "still held by a live fixture of another run: $((@($who | Sort-Object -Unique)) -join ', ')" }
    return $result
}

