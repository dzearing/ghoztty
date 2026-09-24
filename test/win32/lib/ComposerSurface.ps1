# Which surface the viewer's feedback composer came up on, stated rather than
# assumed (T1102).
#
# Since T1704 there is one surface -- the WebView2 page -- and no fallback: the
# hidden RichEdit and the GHOZTTY_COMPOSER_SURFACE switch that pinned scripts to
# it are gone. What is left to ask is whether the composer came up at all. A
# pane whose WebView2 cannot produce a second controller logs `surface=none(...)`
# and takes no text, and a script that types into it would otherwise report the
# composer "holds ''" -- a LOUD and MISLEADING failure that reads as a broken
# feature. So every script that types into the composer opens with
#
#   Wait-ComposerSurface $errlog 'web'  - PROVE the page came up, in one assertion
#
# and names what the app said instead when it did not (Get-ComposerSurface).

Set-StrictMode -Version Latest

# True once the pane's stderr says the composer opened on $Want.
#
# The app logs `viewer feedback composer surface=<what>` from openComposer:
# `web`, or `none(no-environment)` / `none(controller-refused)` naming WHY the
# composer has no text surface at all. Matching on the `none` stem accepts both
# reasons.
function Wait-ComposerSurface {
    param(
        [Parameter(Mandatory = $true)][string]$Log,
        [Parameter(Mandatory = $true)]
        [ValidateSet('web', 'none')]
        [string]$Want,
        [int]$TimeoutMs = 15000
    )
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $Log) {
            $hit = @(Select-String -Path $Log -Pattern ('composer surface=' + $Want) `
                    -SimpleMatch -ErrorAction SilentlyContinue)
            if ($hit.Count -gt 0) { return $true }
        }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

# What the app actually reported, for the failure message. Empty when it has not
# said anything yet.
function Get-ComposerSurface {
    param([Parameter(Mandatory = $true)][string]$Log)
    if (-not (Test-Path $Log)) { return '' }
    $hits = @(Select-String -Path $Log -Pattern 'composer surface=(\S+)' -ErrorAction SilentlyContinue)
    if ($hits.Count -eq 0) { return '' }
    return $hits[-1].Matches[0].Groups[1].Value
}
