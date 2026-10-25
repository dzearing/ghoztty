# T2257 acceptance: a side pane opened without focus into a row with no room
# comes on show, and the pane with the caret keeps it.
#
# THE CLAIM. A non-focusing `+split` (every agent split; focus is opt-in) into
# a stacked row used to be born a strip: it had never been focused, so the
# focus history ranked it last, and since T2250 the reply admitted it
# (`; it is minimized to a strip ...`). Mac 71da9a680 makes such a pane
# FEATURED (`PaneStackState.featured`): it outranks even the focused pane, the
# other panes minimize to make room, and the caret stays where it was. The
# win32 port is `PaneStackState.feature`/`layoutRank`, set by
# `Window.insertPaneAsSplit` when the split is in the background.
#
# Layout: P | s1 | s2 at a width that holds three cards but not four, P with
# the caret; then `+split --view --pane=s2` (the far end), no --focus. The far
# end matters: ranked by the focus history alone the run is P s1 s2, so the
# new pane is a strip (the defect); a pane landing beside P would be on show
# either way and prove nothing. Featured, it is on show and P - caret and all -
# is the pane that makes room (Mac's rule: the featured pane outranks the focus).
#
# Claims:
#   S1) the row really had no room: after the split at least one pane is
#       minimized (else the run proves nothing)
#   S2) the reply carries no strip note
#   S3) +list --json reports the side pane not minimized
#   S4) the caret stays on P (+list --json focused), even minimized
#   S5) its window is actually on screen (a visible GhozttyViewer child)
#   S6) focus away to s1 and back with no layout between: the featuring is
#       over, and the caller is on show with the caret again
#
# -NegativeControl inverts S3 to "the side pane is minimized" - the answer
# before T2257 - and MUST fail.
#
# Hermetic: per-run LOCALAPPDATA, per-run agent binary override, a private IPC
# pipe suffix, and it only ever kills ghoztty processes launched from this
# repo's zig-out. Runs on the BACKGROUND test desktop.
#
#   powershell -NoProfile -File test\win32\side-pane-featured.ps1
param(
    [string]$ExePath,
    [string]$AgentExe,
    [switch]$NegativeControl,
    [switch]$Interactive
)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }
$agent = Join-Path $repo 'zig-out\bin\ghoztty-agent.exe'
if ($AgentExe) { $agent = $AgentExe }

$script:pass = 0
$script:fail = 0
$root = Join-Path $env:TEMP "ghoztty-side-pane-featured-$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\ChromeGeometry.ps1')

function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}
function Say($m) { Write-Host $m }

function Stop-RepoInstances { [void](Stop-RepoGhoztty -Exe $exe -SettleMs 700) }

$appArgs = @('--config-default-files=false', '--session-persistence=false')

function Px([double]$Dip) { Get-TestChromeDip -Dip $Dip -Scale $script:scale }

function Get-VisibleTerminals([IntPtr]$top) {
    return @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal' | Where-Object Visible)
}
function Wait-Shown([IntPtr]$top, [int]$n, [int]$timeoutSec = 20) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    do {
        $v = @(Get-VisibleTerminals $top)
        if ($v.Count -eq $n) { return $v }
        Start-Sleep -Milliseconds 300
    } while ((Get-Date) -lt $deadline)
    return @(Get-VisibleTerminals $top)
}

# Every leaf of the selected tab, in tree order: name, id, type, focused,
# minimized.
function Get-Leaves {
    $out = New-Object System.Collections.ArrayList
    $raw = (& $exe +list --json 2>$null) -join "`n"
    try { $doc = $raw | ConvertFrom-Json } catch { return @() }
    $walk = $null
    $walk = {
        param($node)
        if ($null -eq $node) { return }
        if ($node.type -eq 'leaf') {
            $t = $node.terminal
            [void]$out.Add([pscustomobject]@{
                    Name = [string]$t.name; Id = [string]$t.id; Type = [string]$t.type
                    Focused = [bool]$t.focused; Minimized = ($t.minimized -eq $true)
                })
            return
        }
        & $walk $node.left
        & $walk $node.right
    }
    foreach ($w in @($doc.data.windows | ForEach-Object { $_ })) {
        foreach ($tab in @($w.tabs | ForEach-Object { $_ })) { if ($tab.selected) { & $walk $tab.splits } }
    }
    return $out.ToArray()
}
function Format-Leaves($leaves) {
    return (($leaves | ForEach-Object {
                $n = if ($_.Name -and $_.Name -ne $_.Id) { $_.Name } else { 'P' }
                "$n$(if ($_.Focused) { '*' })$(if ($_.Minimized) { '(min)' })"
            }) -join ' | ')
}

# -----------------------------------------------------------------------------

$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN
$savedPipe = $env:GHOZTTY_PIPE_SUFFIX
$env:GHOZTTY_PIPE_SUFFIX = "-sidepane$PID"

Stop-RepoInstances
New-Item -ItemType Directory -Force $root | Out-Null
$tmp = Join-Path $root 'app'
New-Item -ItemType Directory -Force (Get-GhozttyAgentStateDir -Root $tmp) | Out-Null
$env:LOCALAPPDATA = $tmp
$env:GHOSTTY_LOCAL_AGENT_BIN = $agent
$script:errlog = Join-Path $root 'app-stderr.log'
$doc = Join-Path $root 'side.md'
Set-Content -Path $doc -Value "# side pane`n`nT2257" -Encoding ascii

Reset-TestBody
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    Assert (Test-Path $exe) 'ghoztty exe exists in zig-out'
    Assert (Test-Path $agent) 'ghoztty-agent exe exists in zig-out'
    [void](Assert-GhozttyIsolatedBuild -Exe $exe)
    if ($NegativeControl) {
        Say 'NEGATIVE CONTROL: S3 is inverted to "the side pane is minimized" - this run MUST fail'
    }

    # ---- setup: P | s1 | s2, three cards and no room for a fourth -------------
    Say '== setup: P | s1 | s2'
    $app = Start-OnTestDesktop -Exe $exe -StdErr $script:errlog -Arguments $appArgs
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { Write-TestAssertedNothing -Reason 'the app never opened a GhozttyWindow' }
    # Two DPI readings in a row must agree (pane-stack-grid.ps1's reason).
    Start-Sleep -Milliseconds 800
    $dpi = [int](Get-TestWindowDpi -Window $top)
    for ($i = 0; $i -lt 10; $i++) {
        Start-Sleep -Milliseconds 400
        $again = [int](Get-TestWindowDpi -Window $top)
        if ($again -eq $dpi) { break }
        $dpi = $again
    }
    if ($dpi -le 0) { $dpi = 96 }
    $script:scale = $dpi / 96.0
    [void](Set-TestWindowPos -Window $top -X 0 -Y 0 -Width (Px 1500) -Height (Px 700))
    Start-Sleep -Seconds 2
    & $exe +split --direction=right --name=s1 | Out-Null
    Start-Sleep -Milliseconds 800
    & $exe +split --pane=s1 --direction=right --name=s2 | Out-Null
    $c3 = @(Wait-Shown $top 3)
    if ($c3.Count -ne 3) { Write-TestAssertedNothing -Reason "three panes never came up on show (got $($c3.Count))" }
    $before = @(Get-Leaves)
    Say ("      leaves: {0}" -f (Format-Leaves $before))
    $caller = @($before | Where-Object Focused) | Select-Object -First 1
    if ($null -eq $caller -or ($caller.Name -and $caller.Name -ne $caller.Id)) {
        Write-TestAssertedNothing -Reason "the first pane does not hold the caret ($(Format-Leaves $before))"
    }
    # Three cards fit, four do not: shrink until the row is exactly full.
    $full = $false
    foreach ($w in @(1100, 1050, 1000, 980)) {
        [void](Set-TestWindowPos -Window $top -X 0 -Y 0 -Width (Px $w) -Height (Px 700))
        Start-Sleep -Milliseconds 900
        if (@(Get-VisibleTerminals $top).Count -eq 3) { $full = $true; Say "      window $w DIP: three on show"; break }
    }
    if (-not $full) { Write-TestAssertedNothing -Reason 'no width held three cards side by side' }

    # ---- the side pane --------------------------------------------------------
    Say '== +split --view off the far pane, without --focus'
    $out = (& $exe +split --pane=s2 --direction=right --name=side "--view=$doc" 2>&1 | ForEach-Object { "$_" } | Out-String).Trim()
    Say "      reply: $out"
    Start-Sleep -Milliseconds 1500
    $after = @(Get-Leaves)
    Say ("      leaves: {0}" -f (Format-Leaves $after))
    $side = @($after | Where-Object { $_.Name -eq 'side' }) | Select-Object -First 1
    if ($null -eq $side) { Write-TestAssertedNothing -Reason "the side pane never appeared in +list ($out)" }

    Assert (@($after | Where-Object Minimized).Count -ge 1) "S1: the row had no room - something is minimized ($(Format-Leaves $after))"
    Assert ($out -match "^created pane 'side'" -and $out -notmatch 'minimized to a strip') "S2: the reply carries no strip note ('$out')"
    if ($NegativeControl) {
        Assert ($side.Minimized) 'NEGATIVE: the side pane is minimized'
    } else {
        Assert (-not $side.Minimized) 'S3: +list reports the side pane not minimized'
    }
    $focused = @($after | Where-Object Focused) | Select-Object -First 1
    Assert ($null -ne $focused -and $focused.Id -eq $caller.Id) "S4: the caret stays on the caller ($(Format-Leaves $after))"
    $viewers = @(Get-TestChildWindows -Window $top -Class 'GhozttyViewer' | Where-Object Visible)
    Assert ($viewers.Count -ge 1) "S5: the side pane's window is on screen ($($viewers.Count) visible viewer window(s))"

    # ---- the next change of focus ends it -------------------------------------
    # Away to s1 and back to the caller with no resize in between, so no layout
    # notes s1 on the way: the window's focus events alone must end it.
    Say '== focus s1, then the caller again'
    $link = 'ghoztty-debug://focus/s1'; & $exe $link 2>&1 | Out-Null
    Start-Sleep -Milliseconds 600
    $link = "ghoztty-debug://focus/$($caller.Id)"; & $exe $link 2>&1 | Out-Null
    Start-Sleep -Milliseconds 1200
    $back = @(Get-Leaves)
    Say ("      leaves: {0}" -f (Format-Leaves $back))
    $p = @($back | Where-Object { $_.Id -eq $caller.Id }) | Select-Object -First 1
    Assert ($null -ne $p -and $p.Focused -and -not $p.Minimized) "S6: after a focus change the caller is on show with the caret ($(Format-Leaves $back))"

    Complete-TestBody
} catch {
    $script:fail++
    Say "FAIL  script terminated: $($_.Exception.Message)"
    Say "      at $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())"
} finally {
    Say '== cleanup'
    foreach ($r in @($script:GhozttyTestDesktopLaunches)) { if ($r) { $r.Killed = $true } }
    Remove-TestDesktop
    Stop-RepoInstances
    $env:LOCALAPPDATA = $savedLocalAppData
    if ($null -ne $savedAgentBin) { $env:GHOSTTY_LOCAL_AGENT_BIN = $savedAgentBin }
    else { Remove-Item env:GHOSTTY_LOCAL_AGENT_BIN -ErrorAction SilentlyContinue }
    $env:GHOZTTY_PIPE_SUFFIX = $savedPipe
    if ($script:fail -eq 0) { Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue }
    else { Say "artifacts preserved at $root" }
}

$fgSeen = @(Stop-TestForegroundWatch)
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @(Get-TestLaunchedPids)
    Assert ($fgSeen.Count -gt 0) 'Z1 the foreground watcher actually sampled (negative control)'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'Z2 no test-desktop app ever became foreground on the interactive desktop'
}

if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard side-pane-featured -Repo $repo 2>&1 | ForEach-Object { Say "  $_" }
}

Say ''
Write-TestVerdict -Label 'T2257 SIDE PANE FEATURED' -Pass $script:pass -Fail $script:fail
