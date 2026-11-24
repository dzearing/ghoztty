# WindowRoster.ps1 - "what is in this instance that this run did not mean to
# open", answered from one `+list --json` roster (T1214, lifted here by T2172).
# Dot-source it:
#
#     . (Join-Path $PSScriptRoot 'lib\WindowRoster.ps1')
#     $r = Close-StartupStrays -Exe $exe -Target 'soak'
#
# WHY THIS EXISTS
#
# `+new-window --target=X` with no instance running auto-launches the app, and
# the app opens its own STARTUP window (auto-named `window-1`) before it takes
# the `+new-window`. The instance then holds two windows and the harness meant
# one. In soak.ps1 the extra window's idle pane ran for the whole soak (1486 of
# 7924 samples on 2026-08-31); in profile-latency.ps1 it pooled into the fps
# medians and `FindTop`-by-pid could hand the injected keys to it (T2172).
#
# Close-StartupStrays needs Get-GhozttyListRaw from lib\Isolation.ps1 at CALL
# time; the three pure helpers need nothing, so a -SelfTest can use them
# before any instance exists.

# Every roster window whose target is not $Target. `$null -ne $_`: an absent
# `windows` pipes one $null, which is not a window.
function Get-StrayWindows {
    param($ListJson, [string]$Target)
    return @($ListJson.data.windows | Where-Object { ($null -ne $_) -and ($_.target -ne $Target) })
}

# Every pane leaf in one roster window, across its tabs and nested splits.
function Get-WindowLeaves {
    param($Window)
    $out = New-Object System.Collections.ArrayList
    $stack = New-Object System.Collections.Stack
    foreach ($t in @($Window.tabs)) { if ($null -ne $t.splits) { $stack.Push($t.splits) } }
    while ($stack.Count -gt 0) {
        $n = $stack.Pop()
        if ($null -ne $n.terminal) { [void]$out.Add($n.terminal) }
        if ($null -ne $n.left) { $stack.Push($n.left) }
        if ($null -ne $n.right) { $stack.Push($n.right) }
    }
    return @($out)
}

# One line naming each stray window and how many panes it holds.
function Format-StrayWindows {
    param([object[]]$Strays)
    return (@($Strays | ForEach-Object { "$($_.target) ($(@(Get-WindowLeaves $_).Count) pane)" }) -join ', ')
}

# Parse a `+list --json` capture that may carry a progress note before the JSON.
# Returns $null when there is no JSON in it.
function ConvertFrom-RosterRaw {
    param([string]$Raw)
    if (-not $Raw) { return $null }
    $brace = $Raw.IndexOf('{')
    if ($brace -lt 0) { return $null }
    return ($Raw.Substring($brace) | ConvertFrom-Json)
}

# Close every window that is not $Target, then READ THE ROSTER BACK - the
# close is not trusted. Never throws on the CLI's stderr progress note.
# Returns @{ Closed = <the strays found>; Error = $null | '<why it failed>' }.
# The caller reports and aborts on Error; it owns its own report format.
function Close-StartupStrays {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [Parameter(Mandatory = $true)][string]$Target,
        [int]$SettleMs = 1000
    )
    $before = ConvertFrom-RosterRaw (Get-GhozttyListRaw -Exe $Exe)
    if ($null -eq $before) {
        return [pscustomobject]@{ Closed = @(); Error = '+list --json produced no JSON at startup' }
    }
    $strays = @(Get-StrayWindows $before $Target)
    if ($strays.Count -eq 0) { return [pscustomobject]@{ Closed = @(); Error = $null } }
    foreach ($s in $strays) {
        $eap = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            & $Exe +close "--target=$($s.target)" 2>$null | Out-Null
        } catch { } finally { $ErrorActionPreference = $eap }
    }
    Start-Sleep -Milliseconds $SettleMs
    $after = ConvertFrom-RosterRaw (Get-GhozttyListRaw -Exe $Exe)
    if ($null -eq $after) {
        return [pscustomobject]@{ Closed = $strays; Error = '+list --json produced no JSON after closing the startup window' }
    }
    $left = @(Get-StrayWindows $after $Target)
    if ($left.Count -gt 0) {
        return [pscustomobject]@{ Closed = $strays; Error = "the startup window would not close: $(Format-StrayWindows $left)" }
    }
    if (-not @($after.data.windows | Where-Object { ($null -ne $_) -and ($_.target -eq $Target) })) {
        return [pscustomobject]@{ Closed = $strays; Error = "the $Target window is gone from the roster after closing the strays" }
    }
    return [pscustomobject]@{ Closed = $strays; Error = $null }
}
