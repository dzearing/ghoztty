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

Write-Host '--- C. wiring ---'
$readers = @(Get-ChildItem (Join-Path $repo 'test\win32') -Filter *.ps1 -Recurse | Where-Object {
    # The helper and this harness both NAME the old idiom, on purpose.
    $_.FullName -notlike '*\list-tree.ps1' -and $_.FullName -notlike '*\lib\ListTree.ps1' -and
    (Select-String -Path $_.FullName -Pattern '\.tabs\)?\[\d\]\.panes|\$\w*tab\w*\.panes|\(\$w\.tabs\)\[0\]\.panes' -Quiet)
})
Assert ($readers.Count -eq 0) "no harness reads a pane id off a tab's .panes ($(($readers | ForEach-Object Name) -join ', '))"
$fot = [IO.File]::ReadAllText((Join-Path $repo 'test\win32\float-on-top.ps1'))
Assert ($fot.Contains('Get-GhozttyFirstPaneId') -and $fot.Contains("lib\ListTree.ps1")) 'float-on-top.ps1 takes its pane id from the shared helper'

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
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Label 'LIST-TREE' -MinPass 16
