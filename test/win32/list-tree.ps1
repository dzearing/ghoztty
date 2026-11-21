# T1561 acceptance: test\win32\lib\ListTree.ps1, the shared reader of pane ids
# out of `ghoztty +list --json`.
#
#   A. Constructed +list answers (the real shape: a tab's layout is a `splits`
#      tree, never a `panes` array). A lone leaf, a nested split read left
#      before right, the selected tab preferred, and every way to have no id -
#      each one answering with a reason rather than a $null nobody explains.
#   B. The old wrong shape (`tabs[0].panes[0].id`) yields NO id from the
#      helper - the shape float-on-top.ps1 read for months.
#   C. Wiring: no test\win32 script reads a pane id off a tab's `.panes`, and
#      float-on-top.ps1 takes its pane id from this helper.
#   D. Which window holds a pane (T1641): every tab of every window searched,
#      an unknown or doubly-listed id answering NO window (never the first),
#      and the window id proven against the app's own top-levels.
#
#   -NegativeControl adds one inverted assertion a healthy tree MUST fail, so
#   the run ends with exactly one failure.
#
# Pure. Launches nothing.
# isolation: none - pure parse of constructed JSON; "+list" appears only in comments and labels, no CLI or app is ever run
[CmdletBinding(PositionalBinding = $false)]
param([switch]$NegativeControl)

$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\ListTree.ps1')

$script:fail = 0
$script:pass = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" }
}

function List([string]$tabsJson) {
    return ('{"success":true,"data":{"windows":[{"id":"1","target":"window-1","tabs":' + $tabsJson + '}]}}') | ConvertFrom-Json
}

try {
Write-Host '--- A. the splits tree ---'
$leaf = List '[{"id":"0","splits":{"type":"leaf","terminal":{"id":"AAA"}}}]'
$r = Get-GhozttyFirstPaneId $leaf
Assert ($r.Id -eq 'AAA' -and -not $r.Reason) "a lone leaf yields its terminal id (id=$($r.Id))"

$nested = List ('[{"id":"0","splits":{"type":"split","left":{"type":"split","left":{"type":"leaf","terminal":{"id":"L1"}},' +
    '"right":{"type":"leaf","terminal":{"id":"L2"}}},"right":{"type":"leaf","terminal":{"id":"R1"}}}}]')
$all = Get-GhozttyListLeaves (@($nested.data.windows)[0].tabs[0].splits)
Assert ($all.Count -eq 3) "a nested split yields every leaf (count=$($all.Count))"
Assert ((($all | ForEach-Object { $_.id }) -join ',') -eq 'L1,L2,R1') "leaves come left before right ($((($all | ForEach-Object { $_.id }) -join ',')))"
Assert ((Get-GhozttyFirstPaneId $nested).Id -eq 'L1') 'the first pane of a nested split is the leftmost leaf'

$sel = List '[{"id":"0","splits":{"type":"leaf","terminal":{"id":"T0"}}},{"id":"1","selected":true,"splits":{"type":"leaf","terminal":{"id":"T1"}}}]'
Assert ((Get-GhozttyFirstPaneId $sel).Id -eq 'T1') 'the selected tab is preferred over the first'

$none = Get-GhozttyListLeaves $null
Assert ($none.Count -eq 0) "a null tree yields no leaves (count=$($none.Count))"

$cases = @(
    @{ Label = 'no answer'; List = $null; Want = 'no \+list' },
    @{ Label = 'success=false'; List = ('{"success":false}' | ConvertFrom-Json); Want = 'success=false' },
    @{ Label = 'no windows'; List = ('{"success":true,"data":{"windows":[]}}' | ConvertFrom-Json); Want = '0 window' },
    @{ Label = 'no tabs'; List = (List '[]'); Want = 'no tabs' },
    @{ Label = 'no splits'; List = (List '[{"id":"0"}]'); Want = "no 'splits'" },
    @{ Label = 'empty split'; List = (List '[{"id":"0","splits":{"type":"split"}}]'); Want = 'holds no leaf' },
    @{ Label = 'leaf without id'; List = (List '[{"id":"0","splits":{"type":"leaf","terminal":{}}}]'); Want = 'no terminal id' }
)
foreach ($c in $cases) {
    $r = Get-GhozttyFirstPaneId $c.List
    Assert ($null -eq $r.Id -and [string]$r.Reason -match $c.Want) "$($c.Label): no id, and says why ($($r.Reason))"
}

Write-Host '--- B. the old wrong shape ---'
$old = List '[{"id":"0","panes":[{"id":"OLD"}]}]'
$r = Get-GhozttyFirstPaneId $old
Assert ($null -eq $r.Id) "a tab with a 'panes' array and no 'splits' yields no id (reason: $($r.Reason))"

if ($NegativeControl) {
    Assert ((Get-GhozttyFirstPaneId $old).Id -eq 'OLD') 'NEGATIVE CONTROL: the panes shape must not yield an id (this must FAIL)'
}

Write-Host '--- D. which window holds a pane (T1641) ---'
$multi = ('{"success":true,"data":{"windows":[' +
    '{"id":"1001","target":"wa","tabs":[{"id":"0","selected":true,"splits":{"type":"leaf","terminal":{"id":"A1"}}}]},' +
    '{"id":"2002","target":"wb","tabs":[{"id":"0","selected":true,"splits":{"type":"split","left":{"type":"leaf","terminal":{"id":"B1"}},"right":{"type":"leaf","terminal":{"id":"B2"}}}},' +
    '{"id":"1","splits":{"type":"leaf","terminal":{"id":"B3"}}}]}]}}') | ConvertFrom-Json
$w = Get-GhozttyWindowForPane -List $multi -PaneId 'B2'
Assert ($w.WindowId -eq '2002' -and $w.Target -eq 'wb' -and -not $w.Reason) "a pane in the SECOND window's split maps to that window (id=$($w.WindowId))"
Assert ($w.TabIndex -eq 0 -and $w.TabSelected) 'the hit names its tab and that the tab is on show'
$w = Get-GhozttyWindowForPane -List $multi -PaneId 'B3'
Assert ($w.WindowId -eq '2002' -and $w.TabIndex -eq 1 -and -not $w.TabSelected) "a pane in an unselected tab is still found, and flagged as not on show (tab=$($w.TabIndex))"
$w = Get-GhozttyWindowForPane -List $multi -PaneId 'NOPE'
Assert ($null -eq $w.Window -and $null -eq $w.WindowId -and $w.Reason -match 'no tab') "an id no tab holds answers NO window, not the first one ($($w.Reason))"
$w = Get-GhozttyWindowForPane -List $multi -PaneId ''
Assert ($null -eq $w.WindowId -and $w.Reason) 'an empty id answers no window'
$w = Get-GhozttyWindowForPane -List $null -PaneId 'A1'
Assert ($null -eq $w.WindowId -and $w.Reason -match 'no \+list') 'no listing answers no window'
$dup = ('{"success":true,"data":{"windows":[' +
    '{"id":"1","tabs":[{"id":"0","splits":{"type":"leaf","terminal":{"id":"X"}}}]},' +
    '{"id":"2","tabs":[{"id":"0","splits":{"type":"leaf","terminal":{"id":"X"}}}]}]}}') | ConvertFrom-Json
$w = Get-GhozttyWindowForPane -List $dup -PaneId 'X'
Assert ($null -eq $w.WindowId -and $w.Reason -match 'refusing') "a pane listed twice is refused rather than picked ($($w.Reason))"

$h = Resolve-GhozttyPaneHwnd -List $multi -PaneId 'A1' -Tops @(2002, 1001)
Assert ($h.Hwnd -eq 1001 -and -not $h.Reason) "a window id that IS one of the app's top-levels is the HWND ($($h.Hwnd))"
$h = Resolve-GhozttyPaneHwnd -List $multi -PaneId 'A1' -Tops @(2002)
Assert ($h.Hwnd -eq 0 -and $h.Reason -match 'not one of') "a window id the app has no top-level for answers 0 with the reason ($($h.Reason))"
$h = Resolve-GhozttyPaneHwnd -List $multi -PaneId 'NOPE' -Tops @(1001, 2002)
Assert ($h.Hwnd -eq 0 -and $h.Reason -match 'no tab') 'an unknown pane answers 0 even when windows exist'
$ws = ('{"success":true,"data":{"windows":[{"id":"ws-one","tabs":[{"id":"0","splits":{"type":"leaf","terminal":{"id":"W"}}}]}]}}') | ConvertFrom-Json
$h = Resolve-GhozttyPaneHwnd -List $ws -PaneId 'W' -Tops @(1)
Assert ($h.Hwnd -eq 0 -and $h.Reason -match 'not a number') "a non-numeric window id answers 0 ($($h.Reason))"


Write-Host '--- C. wiring ---'
$readers = @(Get-ChildItem (Join-Path $repo 'test\win32') -Filter *.ps1 -Recurse | Where-Object {
    # The helper and this harness both NAME the old idiom, on purpose.
    $_.FullName -notlike '*\list-tree.ps1' -and $_.FullName -notlike '*\lib\ListTree.ps1' -and
    (Select-String -Path $_.FullName -Pattern '\.tabs\)?\[\d\]\.panes|\$\w*tab\w*\.panes|\(\$w\.tabs\)\[0\]\.panes' -Quiet)
})
Assert ($readers.Count -eq 0) "no harness reads a pane id off a tab's .panes ($(($readers | ForEach-Object Name) -join ', '))"
$fot = [IO.File]::ReadAllText((Join-Path $repo 'test\win32\float-on-top.ps1'))
Assert ($fot.Contains('Get-GhozttyFirstPaneId') -and $fot.Contains("lib\ListTree.ps1")) 'float-on-top.ps1 takes its pane id from the shared helper'
$td = [IO.File]::ReadAllText((Join-Path $repo 'test\win32\lib\TestDesktop.ps1'))
Assert ($td.Contains("'ListTree.ps1'") -and $td -match 'function Get-TestWindowForPane[\s\S]*?Resolve-GhozttyPaneHwnd') `
    'T1641: TestDesktop.ps1 loads ListTree.ps1 and Get-TestWindowForPane resolves through Resolve-GhozttyPaneHwnd'
$vdiff = [IO.File]::ReadAllText((Join-Path $repo 'test\win32\viewer-diff.ps1'))
Assert ($vdiff.Contains('Get-TestWindowForPane') -and -not ($vdiff -match "foreach \(\`$gone in")) `
    "T1641: viewer-diff.ps1's click arm finds its window by pane id and no longer closes the others first"

Complete-TestBody  # T1039: the run reached the end of its body
} finally { }

# --- stamp (T783) -----------------------------------------------------------
# A green run records the content of every file this harness covers; a red run
# leaves the stamp alone on purpose - red must stay due.
if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard list-tree -Repo $repo | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Label 'LIST-TREE' -MinPass 29
