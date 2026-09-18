# T827 acceptance: `+rearrange` on a window that contains a VIEWER pane.
#
# WHAT THIS MIRRORS. Main c0c86e88e fixed a Mac defect where `+rearrange`
# resolved every name in a layout through `TargetEntry.surfaceView` - which is
# nil for a viewer pane by design - so ANY layout naming a preview pane failed
# with `pane '<name>' is no longer alive` about a pane `+list` had reported one
# line earlier. A window holding a viewer was therefore permanently
# un-rearrangeable. The Mac covered it with RearrangeLayoutTests plus
# `scripts/e2e/rearrange-viewer.py`; this is the Windows seat's half.
#
# WHY IT IS A TEST AND NOT A FIX. Reading `IpcHandlers.handleRearrange`, win32
# cannot have the Mac's defect by construction: it resolves every layout name to
# a `*PaneView` through `app.ipcLookup`, checks tree membership against the
# window's own tree, and picks post-swap focus from `*PaneView` identity with a
# first-leaf fallback - a surface is only ever consulted for the OPTIONAL agent
# session id, behind `orelse continue`. But nothing MEASURED that, so the
# property lived in a task file as an assertion about code somebody had read.
# This script is what turns it into something the box re-checks.
#
# WHAT IS ASSERTED, and why each case is a different code path:
#
#   A. A layout mixing TERMINAL and viewer panes - the reported shape. The
#      viewer must resolve like any other pane (no 'no longer alive'), the
#      requested topology must be what `+list --json` reports afterwards, the
#      viewer must be the SAME pane (id and url unchanged => its rendered page
#      and scroll position are untouched, which is the whole point of keeping
#      the pane rather than rebuilding it), the surviving terminals must keep
#      their shells (same pid, scrollback intact), focus must stay on the pane
#      that had it, and the pane the layout OMITS must be gone from the tree
#      and unregistered.
#   B. A VIEWER-ONLY layout. The focus pick is the path that differs: every
#      leaf is surfaceless, so a focus fallback written in terms of surfaces
#      would have nothing to choose and the window would come back with no
#      active pane. Asserted as the window becoming a single viewer leaf that
#      still answers as focused.
#   C. A DEAD pane name. Section B dropped the terminals, so their registry
#      names are the real thing rather than a name that never existed: the
#      layout must be refused, naming the pane, and the window must be
#      UNCHANGED afterwards (a refusal that had already swapped the tree would
#      be worse than the defect).
#   D. A pane from ANOTHER window, mixed with this window's viewer. The
#      membership check, which is the one place a viewer leaf is walked by the
#      tree iterator rather than looked up by name.
#
# THE ORACLE is `+list --json` (topology, leaf type, url, pane id, focus, name)
# plus `+read` for scrollback and the CLI's own exit code and stderr text for
# the refusals. All of it is visible from outside the process, so none of this
# needs a screenshot - which matters because the run happens on the background
# test desktop where nothing can photograph a window.
#
# POSITIVE CONTROLS. Section A refuses to score anything until the fixture is
# the shape it claims: four leaves, exactly one of them a viewer, focus on the
# pane created last, and a marker line already in each terminal's scrollback.
# A green run over a window that never grew a viewer is the failure mode a
# viewer harness falls into most easily, so the viewer's `type` is asserted
# BEFORE the rearrange as well as after it.
#
# Runs on the BACKGROUND test desktop, so it never steals the user's
# foreground. Only touches ghoztty processes running from this repo's zig-out.
#
#   powershell -NoProfile -File test\win32\rearrange-viewer.ps1
#
# -NegativeControl inverts section A's "the mixed layout succeeded" assertion
# and MUST fail with exactly ONE failure on a good build. That is what proves
# the assertion reads the real exit code rather than a constant: a run scoring
# zero failures under the control is measuring nothing, and a run scoring more
# than one has a second assertion keyed off the same thing.
#
# # isolation: a private pipe suffix, so nothing here can reach the user's own
# #            instance; see Assert-GhozttyIsolatedBuild below.
# # persistence: off, explicitly - this builds its own window fixture and a
# #              restored pane from a previous run would break every count.
# # foreground: launches on the background test desktop and watches for a leak;
# #             synthesises no input, so it never needs the foreground.
param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }
if (-not (Test-Path $exe)) { Write-Host "SETUP FAIL: no exe at $exe"; exit 1 }

# Endpoint isolation: a run must never reach the user's own instance.
$env:GHOZTTY_PIPE_SUFFIX = "-rvw$PID"

. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
Assert-GhozttyIsolatedBuild -Exe $exe | Out-Null
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\HarnessLeak.ps1')
Register-RepoBuildTeardown -Exe $exe | Out-Null

$script:pass = 0
$script:fail = 0
$script:skipped = 0
# A skip the VERDICT cannot see is an un-run assertion wearing a green hat
# (T219), and the only line a caller reads is the last one.
function Skip([string]$label) { $script:skipped++; Write-Host "SKIP  $label" }
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

# Section A's headline assertion, in one place so -NegativeControl can invert
# it without touching the rest of the run.
function Assert-Rearranged([bool]$Ok, [string]$Label) {
    if ($NegativeControl) {
        Assert (-not $Ok) "$Label (NEGATIVE CONTROL: asserting the rearrange FAILED)"
    } else {
        Assert $Ok $Label
    }
}

# A PIPE, not a `>` redirect: `ghoztty +verb > file` from PowerShell writes zero
# bytes against the GUI-subsystem exe (T245). Each object is stringified before
# Out-String (T526): a consoleless host formats an ErrorRecord as a blank line
# while its ToString() keeps the text.
function Invoke-Verb([string[]]$VerbArgs) {
    $out = (& $exe @VerbArgs 2>&1 | ForEach-Object { $_.ToString() } | Out-String)
    return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out.Trim() }
}

function Get-Data {
    $json = (& $exe +list --json 2>$null | Out-String).Trim()
    if (-not $json) { return $null }
    try { return ($json | ConvertFrom-Json).data } catch { return $null }
}

function Get-Win([string]$target) {
    $d = Get-Data
    if (-not $d) { return $null }
    foreach ($w in $d.windows) { if ($w.target -eq $target) { return $w } }
    return $null
}

function Wait-Win([string]$target) {
    for ($t = 0; $t -lt 40; $t++) {
        $w = Get-Win $target
        if ($w) { return $w }
        Start-Sleep -Milliseconds 250
    }
    return $null
}

function Get-Leaves($node) {
    if ($null -eq $node) { return @() }
    if ($node.type -eq 'leaf') { return @($node.terminal) }
    return @(Get-Leaves $node.left) + @(Get-Leaves $node.right)
}

function Get-Splits([string]$target) {
    $w = Get-Win $target
    if (-not $w) { return $null }
    return $w.tabs[0].splits
}

# T794: the count is wrapped at the point of use, so a one-element return
# cannot make a comparison vacuous.
function Get-LeafCount([string]$target) {
    return @(Get-Leaves (Get-Splits $target)).Count
}

function Get-LeafNamed([string]$target, [string]$name) {
    foreach ($l in @(Get-Leaves (Get-Splits $target))) {
        if ($l.name -eq $name) { return $l }
    }
    return $null
}

function Wait-LeafNamed([string]$target, [string]$name) {
    for ($t = 0; $t -lt 40; $t++) {
        $l = Get-LeafNamed $target $name
        if ($l) { return $l }
        Start-Sleep -Milliseconds 250
    }
    return $null
}

# The topology as a flat string, leaves as their pane name: the whole shape in
# one comparable value, so a wrong tree names itself in the failure line
# instead of reading as "some assertion about ratios".
function Get-Shape($node) {
    if ($null -eq $node) { return '<none>' }
    if ($node.type -eq 'leaf') { return "L:$($node.terminal.name)" }
    $ratio = [math]::Round([double]$node.ratio, 3)
    return "S($($node.direction) $ratio $(Get-Shape $node.left) $(Get-Shape $node.right))"
}

# The leading comma is load-bearing: a bare `return @(...)` UNROLLS in PS 5.1,
# so a ONE-element result comes back as a scalar whose `.Count` is $null and
# every `-eq 1` below reads false while the failure line prints the right name.
# That is exactly the shape T794's audit exists for, and it cost this script one
# red run. Call sites wrap in `@()` as well, so neither half alone is load-bearing.
function Get-FocusedNames([string]$target) {
    return , @(@(Get-Leaves (Get-Splits $target)) | Where-Object { $_.focused } | ForEach-Object { $_.name })
}

# PS 5.1 destroys embedded quotes on a native argv, so every layout goes
# through the escape the rest of this suite uses (ipc-p3.ps1, viewer-close.ps1).
function New-LayoutArg([string]$Json) {
    return ('--layout=' + ($Json -replace '"', '\"'))
}

function Read-Pane([string]$name, [int]$lines = 200) {
    $r = Invoke-Verb @('+read', "--name=$name", "--lines=$lines")
    if ($r.Code -ne 0) { return '' }
    return $r.Out
}

# A marker the pane's own shell prints once, so "the scrollback survived" is a
# claim about THIS pane's history rather than about a prompt that would be there
# either way. Plain ASCII with no quoting: free text on a native argv is the
# T782 hazard, and a bare word cannot be shredded by it.
function Wait-Marker([string]$name, [string]$marker) {
    for ($t = 0; $t -lt 40; $t++) {
        if ((Read-Pane $name) -match [regex]::Escape($marker)) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

$docDir = Join-Path $env:TEMP "ghoztty-rearrange-viewer-$PID"
New-Item -ItemType Directory -Force -Path $docDir | Out-Null
$doc = Join-Path $docDir 'preview.md'
Set-Content -Path $doc -Value "# preview`n`nA viewer pane, rearranged.`n" -Encoding utf8

$errlog = Join-Path $env:TEMP "ghoztty-rearrange-viewer-$PID.log"
Remove-Item $errlog -ErrorAction SilentlyContinue

[void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 300)
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$app = $null

try {
    # persistence: off, explicitly - a restored pane from an earlier run would
    # break every leaf count below.
    $app = Start-OnTestDesktop -Exe $exe -StdErr $errlog -Arguments @(
        '--session-persistence=false', '--config-default-files=false')
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) {
        Write-TestAssertedNothing -Label 'T827 ACCEPTANCE' -Reason 'the GUI died at launch'
    }
    $appPid = $app.Pid
    if ((Wait-TestWindow -ProcessId $appPid -Class 'GhozttyWindow' -TimeoutMs 20000) -eq [IntPtr]::Zero) {
        Write-TestAssertedNothing -Label 'T827 ACCEPTANCE' -Reason 'the GUI never grew a GhozttyWindow'
    }
    Assert (-not (Test-TestDesktopLeak -ProcessId $appPid)) 'the GUI is NOT on the interactive desktop'

    # =====================================================================
    # Fixture: one window, three terminals and a viewer; plus a second window
    # whose pane is the "wrong window" case in section D.
    # =====================================================================
    Write-Host ''
    Write-Host 'fixture: window rvw = 3 terminals + 1 viewer'
    $r = Invoke-Verb @('+new-window', '--target=rvw')
    if ($r.Code -ne 0 -or -not (Wait-Win 'rvw')) {
        Write-TestAssertedNothing -Label 'T827 ACCEPTANCE' -Reason "the rvw fixture window never appeared ($($r.Out))"
    }
    $r = Invoke-Verb @('+split', '--target=rvw', '--direction=right', '--name=rv1', "--view=$doc")
    Assert ($r.Code -eq 0) "fixture: +split --view exits 0 (got $($r.Code): $($r.Out))"
    if (-not (Wait-LeafNamed 'rvw' 'rv1')) {
        Write-TestAssertedNothing -Label 'T827 ACCEPTANCE' -Reason 'the viewer pane rv1 never appeared in +list'
    }
    $r = Invoke-Verb @('+split', '--target=rvw', '--direction=down', '--name=rvt1')
    Assert ($r.Code -eq 0) "fixture: +split rvt1 exits 0 (got $($r.Code): $($r.Out))"
    [void](Wait-LeafNamed 'rvw' 'rvt1')
    $r = Invoke-Verb @('+split', '--target=rvw', '--direction=right', '--name=rvt2')
    Assert ($r.Code -eq 0) "fixture: +split rvt2 exits 0 (got $($r.Code): $($r.Out))"
    [void](Wait-LeafNamed 'rvw' 'rvt2')
    Start-Sleep -Seconds 3

    $leaves = @(Get-Leaves (Get-Splits 'rvw'))
    Assert ($leaves.Count -eq 4) "fixture: the window has four leaves (got $($leaves.Count))"
    $viewers = @($leaves | Where-Object { $_.type -eq 'viewer' })
    Assert ($viewers.Count -eq 1) "fixture: exactly one of them is a viewer (got $($viewers.Count))"
    # The window's OWN pane is unnamed; `+list` auto-registers it under its id,
    # which is the name a layout has to use for it.
    $named = @('rv1', 'rvt1', 'rvt2')
    $t0 = @($leaves | Where-Object { $named -notcontains $_.name } | ForEach-Object { $_.name })
    Assert ($t0.Count -eq 1) "fixture: the window's own pane has a registry name (got $($t0.Count))"
    if ($leaves.Count -ne 4 -or $viewers.Count -ne 1 -or $t0.Count -ne 1) {
        Write-TestAssertedNothing -Label 'T827 ACCEPTANCE' -Reason 'the fixture is not 3 terminals + 1 viewer'
    }
    $t0name = $t0[0]

    # Markers, so "scrollback survived" is about this pane's own history. One
    # bare word per pane - `echo` plus a literal, which a native argv cannot
    # shred (T782).
    [void](Invoke-Verb @('+send-keys', '--target=rvt2', 'echo RVWMARKTWO', 'Enter'))
    [void](Invoke-Verb @('+send-keys', "--target=$t0name", 'echo RVWMARKZERO', 'Enter'))
    Assert (Wait-Marker 'rvt2' 'RVWMARKTWO') 'fixture: rvt2 printed its marker (its shell is live)'
    Assert (Wait-Marker $t0name 'RVWMARKZERO') "fixture: the window's own pane printed its marker"

    Write-Host 'fixture: window rvw2 (the pane in the wrong window)'
    $r = Invoke-Verb @('+new-window', '--target=rvw2', '--name=rvo')
    Assert ($r.Code -eq 0) "fixture: +new-window rvw2 exits 0 (got $($r.Code): $($r.Out))"
    $w2 = Wait-Win 'rvw2'
    Assert ($null -ne $w2) 'fixture: the second window is listed'
    $otherName = $null
    if ($w2) {
        $ol = @(Get-Leaves $w2.tabs[0].splits)
        if ($ol.Count -ge 1) { $otherName = $ol[0].name }
    }
    Assert ($null -ne $otherName) "fixture: the second window's pane has a registry name (got '$otherName')"

    # =====================================================================
    # A. A layout mixing terminal and viewer panes - the reported shape.
    # =====================================================================
    Write-Host ''
    Write-Host 'A. mixed terminal + viewer layout: (t0 / rvt2) | rv1'
    $before = Get-Splits 'rvw'
    $vBefore = Get-LeafNamed 'rvw' 'rv1'
    Assert ($vBefore.type -eq 'viewer') 'A: the pane the layout names really is a viewer BEFORE the rearrange'
    Assert (-not [string]::IsNullOrEmpty($vBefore.url)) "A: and it carries a url (got '$($vBefore.url)')"
    $focusBefore = @(Get-FocusedNames 'rvw')
    Assert ($focusBefore.Count -eq 1 -and $focusBefore[0] -eq 'rvt2') `
        "A: the pane created last holds focus, so the focus assertion below can move (got '$($focusBefore -join ',')')"
    $pidT0Before = (Get-LeafNamed 'rvw' $t0name).pid
    $pidT2Before = (Get-LeafNamed 'rvw' 'rvt2').pid

    $layout = '{"direction":"horizontal","ratio":40,' +
        '"left":{"direction":"vertical","ratio":50,"left":{"pane":"' + $t0name + '"},' +
        '"right":{"pane":"rvt2"}},"right":{"pane":"rv1"}}'
    $r = Invoke-Verb @('+rearrange', '--target=rvw', (New-LayoutArg $layout))
    Assert-Rearranged ($r.Code -eq 0) "A: a layout naming a viewer pane succeeds (got $($r.Code): $($r.Out))"
    Assert ($r.Out -notmatch 'no longer alive') `
        "A: no bogus 'no longer alive' about the viewer pane (got '$($r.Out)')"
    if ($r.Code -ne 0) {
        Write-Host '  the rearrange failed; the rest of section A cannot be measured'
    } else {
        Start-Sleep -Seconds 2
        $shape = Get-Shape (Get-Splits 'rvw')
        $want = "S(horizontal 0.4 S(vertical 0.5 L:$t0name L:rvt2) L:rv1)"
        Assert ($shape -eq $want) "A: the topology is the requested layout (wanted $want, got $shape)"

        $vAfter = Get-LeafNamed 'rvw' 'rv1'
        Assert ($null -ne $vAfter -and $vAfter.type -eq 'viewer') 'A: the viewer pane is still a viewer'
        Assert ($null -ne $vAfter -and $vAfter.url -eq $vBefore.url) `
            "A: it still shows the same document (was '$($vBefore.url)', now '$($vAfter.url)')"
        Assert ($null -ne $vAfter -and $vAfter.id -eq $vBefore.id) `
            'A: it is the SAME pane (id unchanged => rendered page and scroll position intact)'

        $t0After = Get-LeafNamed 'rvw' $t0name
        Assert ($null -ne $t0After) "A: the window's own terminal is still in the tree"
        Assert ($null -ne $t0After -and $t0After.pid -eq $pidT0Before) `
            "A: and it is the same shell (pid $pidT0Before -> $($t0After.pid))"
        Assert ((Read-Pane $t0name) -match 'RVWMARKZERO') 'A: its scrollback survived the swap'

        $t2After = Get-LeafNamed 'rvw' 'rvt2'
        Assert ($null -ne $t2After) 'A: rvt2 is still in the tree'
        Assert ($null -ne $t2After -and $t2After.pid -eq $pidT2Before) `
            "A: and it is the same shell (pid $pidT2Before -> $($t2After.pid))"
        Assert ((Read-Pane 'rvt2') -match 'RVWMARKTWO') 'A: its scrollback survived the swap too'

        $focusAfter = @(Get-FocusedNames 'rvw')
        Assert ($focusAfter.Count -eq 1 -and $focusAfter[0] -eq 'rvt2') `
            "A: focus stayed on the pane that had it (got '$($focusAfter -join ',')')"

        Assert ($null -eq (Get-LeafNamed 'rvw' 'rvt1')) 'A: the omitted pane rvt1 is gone from the tree'
        $dead = Invoke-Verb @('+read', '--name=rvt1', '--lines=1')
        Assert ($dead.Code -ne 0) "A: and its name is unregistered (+read exits $($dead.Code))"
    }

    # =====================================================================
    # B. A viewer-only layout. Every leaf is surfaceless, which is the case a
    #    surface-based focus pick cannot answer at all.
    # =====================================================================
    Write-Host ''
    Write-Host 'B. viewer-only layout'
    $r = Invoke-Verb @('+rearrange', '--target=rvw', (New-LayoutArg '{"pane":"rv1"}'))
    Assert ($r.Code -eq 0) "B: a layout of nothing but a viewer succeeds (got $($r.Code): $($r.Out))"
    Start-Sleep -Seconds 2
    Assert ((Get-LeafCount 'rvw') -eq 1) "B: the window is down to one pane (got $(Get-LeafCount 'rvw'))"
    Assert ((Get-Shape (Get-Splits 'rvw')) -eq 'L:rv1') `
        "B: and that pane is the viewer (got $(Get-Shape (Get-Splits 'rvw')))"
    $focusB = @(Get-FocusedNames 'rvw')
    Assert ($focusB.Count -eq 1 -and $focusB[0] -eq 'rv1') `
        "B: the surviving viewer is the focused pane, so the window has an active pane (got '$($focusB -join ',')')"
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'B: the app survived a window of nothing but a viewer'

    # =====================================================================
    # C. A dead pane name. Section B dropped rvt2, so this is a name the
    #    registry really did hold rather than one that never existed.
    # =====================================================================
    Write-Host ''
    Write-Host 'C. a layout naming a pane the previous layout dropped'
    $shapeBeforeC = Get-Shape (Get-Splits 'rvw')
    $r = Invoke-Verb @('+rearrange', '--target=rvw',
        (New-LayoutArg '{"direction":"horizontal","left":{"pane":"rv1"},"right":{"pane":"rvt2"}}'))
    Assert ($r.Code -ne 0) "C: the layout is refused (got $($r.Code): $($r.Out))"
    Assert ($r.Out -match 'rvt2') "C: and the refusal names the dead pane (got '$($r.Out)')"
    Start-Sleep -Milliseconds 800
    Assert ((Get-Shape (Get-Splits 'rvw')) -eq $shapeBeforeC) `
        "C: the window is unchanged by the refusal (was $shapeBeforeC, now $(Get-Shape (Get-Splits 'rvw')))"

    # =====================================================================
    # D. A pane from another window, mixed with this window's viewer.
    # =====================================================================
    Write-Host ''
    Write-Host 'D. a layout naming a live pane in the WRONG window'
    if (-not $otherName) {
        Skip 'D: the second window never reported a pane name, so the wrong-window case cannot be posed'
    } else {
        $shapeBeforeD = Get-Shape (Get-Splits 'rvw')
        $r = Invoke-Verb @('+rearrange', '--target=rvw',
            (New-LayoutArg ('{"direction":"horizontal","left":{"pane":"rv1"},"right":{"pane":"' + $otherName + '"}}')))
        Assert ($r.Code -ne 0) "D: the layout is refused (got $($r.Code): $($r.Out))"
        Assert ($r.Out -match 'not in the target window') `
            "D: and the refusal says the pane is not in this window (got '$($r.Out)')"
        Start-Sleep -Milliseconds 800
        Assert ((Get-Shape (Get-Splits 'rvw')) -eq $shapeBeforeD) `
            "D: the window is unchanged by the refusal (was $shapeBeforeD, now $(Get-Shape (Get-Splits 'rvw')))"
        Assert ($null -ne (Get-Win 'rvw2')) "D: and the other window is untouched"
    }

    Assert (-not ($app.Process -and $app.Process.HasExited)) 'the GUI survived all of it'
    Assert (-not (Test-TestDesktopLeak -ProcessId $appPid)) `
        'the GUI never became visible on the interactive desktop'
    Complete-TestBody  # T1039: the run reached the end of its body
} finally {
    Write-Host ''
    [void](Invoke-Verb @('+close', '--target=rvw'))
    [void](Invoke-Verb @('+close', '--target=rvw2'))
    [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
    Remove-TestDesktop $td
    Remove-Item $docDir -Recurse -Force -ErrorAction SilentlyContinue
}

$fgSeen = @(Stop-TestForegroundWatch)
$leaked = @(Get-TestLaunchedPids | Where-Object { $fgSeen -contains $_ })
Assert ($leaked.Count -eq 0) `
    "no test-desktop app ever became foreground on the interactive desktop (saw $($leaked -join ','))"

# A green run stamps the covered files (T783) so guard-due can answer "has this
# harness been run against the code as it now stands?". Red leaves the stamp
# alone: red stays due, and so does a negative-control run, which is red by
# construction.
if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard rearrange-viewer -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
# -MinPass: a full run scores 45. A throw that unwinds a section leaves far
# less than that, and a partial score must not read as a pass (T271/T1039).
Write-TestVerdict -Label 'T827 ACCEPTANCE' -Pass $script:pass -Fail $script:fail `
    -Skipped $script:skipped -MinPass 30
