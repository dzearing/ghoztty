# OccludedDisplay (T2650) - did the display show anything while the app ran?
#
# THE DEFECT THIS EXISTS FOR. A capture of the real app's pixels (WGC film,
# a WGC grab, a recorder) taken while the display is OCCLUDED - the monitor
# asleep, the session locked, a screen saver up - photographs a terminal that
# never presented: solid black, with a strip wherever a pane grows. Every
# pixel verdict of that run is about the box, not the app. On 2026-11-02 all
# 23 red divider-flicker runs were exactly that (T2645), and the same black
# frames went on to cost T2653's resize film a whole turn before anyone
# looked at the app's log.
#
# THE APP SAYS SO ITSELF. FrameClock.zig logs one warning when
# DCompositionWaitForCompositorClock first fails with
# STATUS_GRAPHICS_PRESENT_OCCLUDED (0xC01E0006):
#
#   warning(frame_clock): compositor clock wait failed (c01e0006); falling
#   back to a timer at period_us=..., retrying in ... ms
#
# Every harness that photographs the real app reads its captured stderr for
# that line and SKIPS by name instead of scoring. This file is the one place
# the line is matched, so a reworded log cannot silently re-arm the false red
# in one harness and not another (T2724 reworded its tail on 2026-11-06 and
# divider-flicker's E3 was the only thing that noticed). Section E of
# test\win32\divider-flicker.ps1 is the acceptance, and guard-due's
# divider-flicker row covers this file and FrameClock.zig.
#
# NOT IN SCOPE: PrintWindow / WM_PRINT photographs. They read the window's own
# paint, not what DWM composed, so an occluded display does not blacken them
# (T2620's all-black strip face reproduced 8 of 10 times with the display lit).

$script:OccludedDisplayPattern = 'compositor clock wait failed \(c01e0006\)'
# The fixed prefix of FrameClock's format string, quote included: the part of
# the line this file matches, which must not change underneath it.
$script:OccludedDisplaySourceLiteral = '"compositor clock wait failed ({x}); falling back to a timer'

<#
The occluded line from an app log, or $null (no log, unreadable, or no such
line). Reads a log the app may still hold open for writing.
#>
function Get-OccludedDisplayLine {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$LogPath)
    if (-not $LogPath -or -not (Test-Path -LiteralPath $LogPath)) { return $null }
    $fs = $null
    try {
        $fs = [IO.File]::Open($LogPath, 'Open', 'Read', 'ReadWrite')
        $text = (New-Object IO.StreamReader($fs)).ReadToEnd()
    } catch { return $null } finally { if ($fs) { $fs.Dispose() } }
    $m = [regex]::Match($text, "(?im)^.*$script:OccludedDisplayPattern.*$")
    if ($m.Success) { return $m.Value.Trim() }
    return $null
}

<#
The SKIP line a harness prints for one cell/arm/drag whose app log says the
display was occluded, or $null when it does not. -What names the unit
skipped ("La/Lb 4x1-v", "drag fold"). Callers count the skip themselves.
#>
function Get-OccludedDisplaySkip {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$LogPath,
        [Parameter(Mandatory = $true)][string]$What
    )
    $line = Get-OccludedDisplayLine -LogPath $LogPath
    if ($null -eq $line) { return $null }
    # skip-audit: the wording RETURNED to callers, who print it and count the
    # skip in their own verdict; nothing here is skipped.
    return "  SKIP ${What}: the display was occluded while the app ran (asleep or locked), so these frames say nothing about the app -- $line"
}

<#
Whole-run form for a probe that films several arms and scores them against
each other: if ANY app log under -Root (or in -Logs) carries the line, print
`SKIP ALL: ...` naming each one and exit 0, so the runner scores a skip and
no PASS/FAIL printed above it stands as a verdict. Silent otherwise. Call it
after the capture, before the verdict line.
#>
function Exit-IfOccludedDisplay {
    param(
        [string]$Root = '',
        [string[]]$Logs = @(),
        [string[]]$Names = @('stderr.txt', 'app.log', 'app-stderr.log')
    )
    $paths = @($Logs | Where-Object { $_ })
    if ($Root -and (Test-Path -LiteralPath $Root)) {
        $paths += @(Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $Names -contains $_.Name } | ForEach-Object { $_.FullName })
    }
    $hits = @()
    foreach ($p in ($paths | Select-Object -Unique)) {
        $line = Get-OccludedDisplayLine -LogPath $p
        if ($null -ne $line) { $hits += "$p :: $line" }
    }
    if ($hits.Count -eq 0) { return }
    # skip-audit: the suite's SKIP ALL shape - the run ends here with exit 0,
    # so this line is the last verdict-bearing line anybody reads.
    "SKIP ALL: the display was occluded while the app ran (asleep or locked) - $($hits.Count) app log(s) say so, so this run's frames say nothing about the app and no PASS/FAIL above is a verdict (T2650)"
    $hits | ForEach-Object { "  occluded: $_" }
    exit 0
}

<#
Does FrameClock.zig still log the line this file matches? False means the
gate went blind: occluded runs would be scored again, silently.
#>
function Test-OccludedDisplaySource {
    param([Parameter(Mandatory = $true)][string]$Repo)
    $p = Join-Path $Repo 'src\apprt\win32\FrameClock.zig'
    if (-not (Test-Path -LiteralPath $p)) { return $false }
    return ([IO.File]::ReadAllText($p)).Contains($script:OccludedDisplaySourceLiteral)
}
