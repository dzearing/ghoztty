# PaintWait.ps1 - wait for a PAINTED result instead of sleeping through it (T1372).
#
# The shape this retires: post a click or a key, `Start-Sleep` a flat interval,
# take one capture, assert. The sleep is a bet on how fast the input is drained
# and the WM_PAINT lands, so on a loaded box the assert photographs the frame
# BEFORE the change and reads a working feature as broken - and the red run says
# only "not painted", with no record of how long anything took. T561 fixed one
# instance in activity-monitor.ps1 section J (the dismissal reached a capture in
# 135-141ms against a 600ms sleep); this is that loop, once, for every script.
#
# Each poll is a `-Sync` capture, which repaints the window inside the call
# (T1287), so the only thing being waited for is the app having PROCESSED the
# input. The latency is returned so a caller can print it beside its assert.
#
# A NEGATIVE claim ("this leaves the banner up") still sleeps: nothing to wait
# for is the claim. Only a positive, painted result belongs here.
#
# Dot-source it after lib\TestDesktop.ps1, whose Get-TestWindowPixels /
# Close-TestWindowPixels it calls.

<#
Poll $Window until $Until, given a synchronous capture, returns true.

    $w = Wait-TestPaint -Window $panel -Until { param($s) Test-Lit $s } -KeepShot
    Assert $w.Met "the row lit (after $($w.ElapsedMs)ms)"
    try { Measure-Row $w.Shot } finally { Close-TestWindowPixels $w.Shot }

Returns { Met, ElapsedMs, Polls, Shot }. The predicate always sees a fresh shot
and never has to close it. Without -KeepShot every shot is closed and Shot is
$null; with it, Shot is the LAST capture taken - the one that met the condition,
or the final one at the deadline - and the caller closes it. Measuring that same
frame is the point: a re-capture after the wait is a second, unwaited photograph.
#>
function Wait-TestPaint {
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Window,
        [Parameter(Mandatory = $true)][scriptblock]$Until,
        [int]$TimeoutMs = 3000,
        [int]$IntervalMs = 100,
        [switch]$KeepShot,
        $Desktop
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $polls = 0
    $met = $false
    $shot = $null
    while ($true) {
        $shot = Get-TestWindowPixels -Window $Window -Sync -Desktop $Desktop
        $polls++
        $met = [bool](& $Until $shot)
        if ($met -or $sw.ElapsedMilliseconds -ge $TimeoutMs) { break }
        Close-TestWindowPixels $shot
        $shot = $null
        Start-Sleep -Milliseconds $IntervalMs
    }
    $sw.Stop()
    if (-not $KeepShot -and $shot) {
        Close-TestWindowPixels $shot
        $shot = $null
    }
    return [pscustomobject]@{
        Met       = $met
        ElapsedMs = [int]$sw.ElapsedMilliseconds
        Polls     = $polls
        Shot      = $shot
    }
}
