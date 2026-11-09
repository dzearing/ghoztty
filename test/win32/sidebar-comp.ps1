# T2765 acceptance: the pane sidebar - a GDI child window - can build a
# composition tree of its own (src\apprt\win32\child_comp.zig), which the
# sidebar's motions hang their visuals on (T2801 sheen, T2802 list
# transitions, T2803 reorder, T2804 column glide).
#
# Layout: P, then `+split right` -> s1, so the sidebar is on show.
#
# Three arms, each a fresh app (the seams are read per sidebar):
#
#   PLAIN (no seam): the sidebar is on show and NO tree is built - a sidebar
#   that never animates pays for no device (the tree is lazy).
#   FILL (GHOZTTY_DEBUG_SIDEBAR_COMP_FILL=1): placing the sidebar builds its
#   tree (`pane sidebar composition tree up for=debug-fill adapter=...
#   build=1`) and hangs one cover layer on it (`composition fill attached
#   build=1`) - device, target on the child's window, root visual, a layer's
#   surface and upload all ran.
#   LOSS (FILL + GHOZTTY_DEBUG_SIDEBAR_COMP_LOSS=1): the first paint after the
#   build reports the device lost (`composition tree lost: simulated`); the
#   tree is dropped, built again (`build=2`), and the layer comes back on the
#   NEW generation - a later one than it first joined.
#
#   SHEEN (T2801, no seam): `+set-state busy` on s1 puts its pill's sheen on
#   the tree (`tree up for=sheen`, `sheen comp placed`), the motion clock
#   starts with `comp=1` and runs slow, so 3 s busy costs a handful of
#   paints (`motion off ... frames=N`, N <= 12) rather than one a vblank;
#   idle again, the faded-out sheen comes off the tree (`sheen comp reaped`).
#   STEPPED (GHOZTTY_DEBUG_SIDEBAR_SHEEN_STEPPED=1): the control - nothing on
#   the tree, the sheen painted frame by frame (frames >= 60). The sheen's
#   pieces are unit-tested against the stepped paint pixel for pixel
#   (pane_sidebar_sheen_layers.zig).
#
# The build back-off is unit-tested (child_comp.zig `Policy`). NOT covered
# here: what the layer LOOKS like on screen - a background desktop cannot be
# photographed (CopyFromScreen is dead there) and WM_PRINTCLIENT returns the
# window's GDI pixels, not its composition tree. The motions that use the tree
# carry the on-screen films (T2801-T2804).
#
# Runs on a BACKGROUND desktop (lib\TestDesktop.ps1) and never takes the
# user's foreground - asserted by the foreground watcher, not assumed.
# -NegativeControl expects a tree in the PLAIN arm and MUST fail.
#
#   powershell -NoProfile -File test\win32\sidebar-comp.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [switch]$NegativeControl,
    [switch]$Interactive
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:passes = 0
$tmp = Join-Path $env:TEMP "ghoztty-t2765-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ } else { "  FAIL $name"; $script:failures++ }
}
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 't2765')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$Cli = [System.IO.Path]::ChangeExtension($Exe, '.com')
if (-not (Test-Path $Cli)) { $Cli = $Exe }

function Invoke-Cli([string]$CliArgs) {
    cmd /c "`"$Cli`" $CliArgs > `"$tmp\out.txt`" 2> `"$tmp\err.txt`"" | Out-Null
    return $LASTEXITCODE
}
function Get-CliErr { (Get-Content "$tmp\err.txt" -Raw -ErrorAction SilentlyContinue) }
function Get-Sidebar($top) { @(Get-TestChildWindows -Window $top -Class 'GhozttyPaneSidebar') | Select-Object -First 1 }
function Get-LogLines([string]$Pattern) { @(Get-Content $script:errlog -ErrorAction SilentlyContinue | Where-Object { $_ -match $Pattern }) }
# The first line matching $Pattern, waiting up to $Ms.
function Wait-Log([string]$Pattern, [int]$Ms = 5000) {
    $deadline = (Get-Date).AddMilliseconds($Ms)
    do {
        $hit = Get-LogLines $Pattern | Select-Object -First 1
        if ($hit) { return $hit }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)
    return $null
}

. (Join-Path $PSScriptRoot 'lib\Transcript.ps1')
$transcript = New-TestTranscript -Name 't2765'

Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$launched = @()
$script:reachedEnd = $false
$seams = @('GHOZTTY_DEBUG_SIDEBAR_COMP_FILL', 'GHOZTTY_DEBUG_SIDEBAR_COMP_LOSS', 'GHOZTTY_DEBUG_SIDEBAR_SHEEN_STEPPED')

& {
try {
    Assert-GhozttyPrivateEndpoint -Exe $Exe
    foreach ($arm in @('plain', 'fill', 'loss', 'sheen', 'stepped')) {
    "==== arm: $arm"
    [void](Stop-RepoGhoztty -Exe $Exe -AppOnly -SettleMs 500)
    Remove-Item ($seams | ForEach-Object { "env:$_" }) -ErrorAction SilentlyContinue
    if ($arm -in 'fill', 'loss') { $env:GHOZTTY_DEBUG_SIDEBAR_COMP_FILL = '1' }
    if ($arm -eq 'loss') { $env:GHOZTTY_DEBUG_SIDEBAR_COMP_LOSS = '1' }
    # T2801: the control arm keeps the sheen stepped; -NegativeControl steps
    # the compositor arm too, so its rows must go red.
    if ($arm -eq 'stepped' -or ($arm -eq 'sheen' -and $NegativeControl)) { $env:GHOZTTY_DEBUG_SIDEBAR_SHEEN_STEPPED = '1' }
    $script:errlog = Join-Path $tmp "app-stderr-$arm.log"
    $app = Start-OnTestDesktop -Exe $Exe -StdErr $script:errlog -Arguments @('--session-persistence=false')
    Start-Sleep -Seconds 3
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { "  SETUP FAIL: top window not found"; $script:failures++; return }
    Assert "[$arm] window is NOT enumerable on the interactive desktop" (-not (Test-TestDesktopLeak -ProcessId $app.Pid))
    Assert "[$arm] setup: +split s1 exit 0 ($(Get-CliErr))" ((Invoke-Cli "+split --direction=right --name=s1") -eq 0)
    Start-Sleep -Milliseconds 1500
    $sb = Get-Sidebar $top
    Assert "[$arm] setup: the sidebar is on show" ($null -ne $sb -and $sb.Visible)
    if ($null -eq $sb -or -not $sb.Visible) { return }

    switch ($arm) {
        'plain' {
            "== the sidebar is on show, and builds no tree until a motion asks"
            Start-Sleep -Milliseconds 1000
            $up = @(Get-LogLines 'pane sidebar composition tree up').Count
            $want = if ($NegativeControl) { 1 } else { 0 }
            Assert "[plain] no composition tree was built ($up built)" ($up -eq $want)
            Assert "[plain] and no build was even tried ($(@(Get-LogLines 'pane sidebar composition tree failed').Count) failures)" (@(Get-LogLines 'pane sidebar composition tree failed').Count -eq 0)
        }
        'fill' {
            "== placing the sidebar builds its tree and hangs the fill layer on it"
            $up = Wait-Log 'pane sidebar composition tree up for=debug-fill adapter=(hardware|warp) build=1 generation=(\d+)'
            Assert "[fill] the tree went up (log: $up)" ($null -ne $up)
            $fill = Wait-Log 'pane sidebar composition fill attached build=1 generation=\d+'
            Assert "[fill] the cover layer joined it and uploaded (log: $fill)" ($null -ne $fill)
            Assert "[fill] no build failed" (@(Get-LogLines 'pane sidebar composition tree failed').Count -eq 0)
            Assert "[fill] no layer failure was logged" (@(Get-LogLines 'pane sidebar composition fill: ').Count -eq 0)
            Start-Sleep -Milliseconds 800
            Assert "[fill] exactly one tree: a placement again does not build another ($(@(Get-LogLines 'pane sidebar composition tree up').Count))" (@(Get-LogLines 'pane sidebar composition tree up').Count -eq 1)
        }
        'loss' {
            "== a lost device drops the tree; it is built again and the layer comes back on it"
            $first = Wait-Log 'pane sidebar composition fill attached build=1 generation=(\d+)'
            Assert "[loss] the fill went up on the first tree (log: $first)" ($null -ne $first)
            $g1 = if ($first -match 'generation=(\d+)') { [int]$Matches[1] } else { -1 }
            $lost = Wait-Log 'pane sidebar composition tree lost: simulated'
            Assert "[loss] the paint noticed the (simulated) loss (log: $lost)" ($null -ne $lost)
            $up2 = Wait-Log 'pane sidebar composition tree up for=debug-fill adapter=\w+ build=2 '
            Assert "[loss] the tree was built again (log: $up2)" ($null -ne $up2)
            $second = Wait-Log 'pane sidebar composition fill attached build=2 generation=(\d+)'
            Assert "[loss] the layer came back on the rebuilt tree (log: $second)" ($null -ne $second)
            $g2 = if ($second -match 'generation=(\d+)') { [int]$Matches[1] } else { -1 }
            Assert "[loss] ... on a LATER generation than it first joined ($g1 -> $g2)" ($g1 -gt 0 -and $g2 -gt $g1)
            Start-Sleep -Milliseconds 800
            Assert "[loss] the loss seam fires once: two trees, not a rebuild loop ($(@(Get-LogLines 'pane sidebar composition tree up').Count))" (@(Get-LogLines 'pane sidebar composition tree up').Count -eq 2)
        }
        { $_ -in 'sheen', 'stepped' } {
            "== T2801: a busy pane's sheen - on the compositor, or (control) stepped on the frame clock"
            $comp = ($arm -eq 'sheen')
            Assert "[$arm] +set-state busy s1 exit 0 ($(Get-CliErr))" ((Invoke-Cli "+set-state --target=s1 --state=busy") -eq 0)
            $on = Wait-Log 'pane sidebar motion on surface=rail busy=1 comp=(\d+)'
            "  $on"
            Assert "[$arm] the motion clock started for the busy pane (log)" ($null -ne $on)
            $n = if ($on -match 'comp=(\d+)') { [int]$Matches[1] } else { -1 }
            # Three seconds busy: one and a half glints, most of a drift.
            Start-Sleep -Milliseconds 3000
            Assert "[$arm] +set-state idle s1 exit 0 ($(Get-CliErr))" ((Invoke-Cli "+set-state --target=s1 --state=idle") -eq 0)
            $off = Wait-Log 'pane sidebar motion off surface=rail frames=(\d+) area=(\d+)' 6000
            "  $off"
            Assert "[$arm] the clock stopped itself once the sheen faded out (log)" ($null -ne $off)
            $frames = if ($off -match 'frames=(\d+)') { [int]$Matches[1] } else { -1 }
            $placed = @(Get-LogLines 'pane sidebar sheen comp placed key=').Count
            $treeUp = Wait-Log 'pane sidebar composition tree up for=sheen adapter=(hardware|warp) build=1' 500
            if ($comp) {
                Assert "[sheen] the sheen built the column's tree (log: $treeUp)" ($null -ne $treeUp)
                Assert "[sheen] its pieces went on the tree ($placed placed)" ($placed -ge 1)
                Assert "[sheen] the busy pill was the compositor's when the clock started (comp=$n)" ($n -eq 1)
                # Stepped, 3.6 s at the display rate is 200+ frames; here the
                # only paints are the roster's own (busy on, busy off, reap).
                Assert "[sheen] the column barely repainted while it sheened ($frames frames, want <= 12)" ($frames -ge 0 -and $frames -le 12)
                Assert "[sheen] the faded-out sheen came off the tree (log)" ($null -ne (Wait-Log 'pane sidebar sheen comp reaped key=' 500))
            } else {
                Assert "[stepped] nothing went on the tree (comp=$n, $placed placed)" ($n -eq 0 -and $placed -eq 0)
                Assert "[stepped] the control steps the sheen frame by frame ($frames frames, want >= 60)" ($frames -ge 60)
            }
        }
    }

    Assert "[$arm] no crash" (-not ($app.Process -and $app.Process.HasExited))
    $launched += $script:GhozttyTestDesktopPids
    }
    $script:reachedEnd = $true
} catch {
    "  FAIL body threw: $($_.Exception.Message)"
    $script:failures++
} finally {
    Remove-Item ($seams | ForEach-Object { "env:$_" }) -ErrorAction SilentlyContinue
    Remove-TestDesktop
    [void](Stop-RepoGhoztty -Exe $Exe -AppOnly -SettleMs 500)
}

Assert "the body ran to its last section" ($script:reachedEnd -eq $true)
$fgSeen = @(Stop-TestForegroundWatch)
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @($launched | Select-Object -Unique)
    Assert "the foreground watcher actually sampled (negative control)" ($fgSeen.Count -gt 0)
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert "no test-desktop app ever became foreground on the interactive desktop" ($leaked.Count -eq 0)
}
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

} 2>&1 | Tee-Object -FilePath $transcript

Complete-TestBody  # T1039: the run reached the end of its body

if ($script:failures -eq 0 -and -not $NegativeControl) {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard sidebar-comp -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

""
exit (Complete-TestTranscript -Name 't2765' -Path $transcript `
        -Label 'T2765 ACCEPTANCE' -Pass $script:passes -Fail $script:failures).Code
