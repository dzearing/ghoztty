# T3126 acceptance: a pane the user minimized into a blade is still a blade
# after a relaunch (Mac a7fe3e9f8, `aRestoredWindowKeepsItsBlades`).
#
# THE CLAIM. Until T3126 the win32 session layout carried no stack state at
# all: a relaunch laid every row out side by side again wherever it fit, and
# the caret went to whichever pane the rebuild happened to make last. Each tab
# now saves the rows the user collapsed and its focus history
# (`Tab.pane_stack`, panes by leaf position in screen order), re-saves when a
# collapse changes, and a restore takes both back before the window is shown
# and puts the caret in a pane on show - never a blade.
#
# Layout: P | (s1 | (s2 | s3)) in a window 1500 DIP wide, where all four fit
# side by side - so anything minimized after the relaunch was minimized by the
# saved state, not by want of room. Leaf positions: P=0 s1=1 s2=2 s3=3.
#
# A collapse is made by dragging a stack grip, which no script here can do
# without the input desktop, so the collapse is written into the manifest
# between a kill and a relaunch - the manifest is restore's own input, and
# this is the exact shape the app writes (`pane_stack_state.Persisted`).
#
#   A) the row saved collapsed to s1 (start 1, count 1) comes back with s1
#      alone on show, the other three minimized (`+list` and the pane HWNDs
#      agree), and s1 holding the caret (the history says s1 was focused)
#   B) the app re-saved the window itself: the manifest still carries the
#      collapse, written by the app (a marker key the patch planted inside it
#      is gone - the writer drops what it does not know)
#   C) relaunched from the app's OWN manifest, every blade is a blade again
#   D) a history whose newest pane is a blade (s3) still puts the caret on a
#      pane on show (s1): focusing the blade would have brought it back out
#
# -NegativeControl leaves the collapse OUT of the manifest: claim A must then
# fail (every pane on show), proving the harness can tell the difference.
#
# Hermetic: per-run LOCALAPPDATA, per-run agent binary override, a private IPC
# pipe suffix, and it only ever kills ghoztty processes launched from this
# repo's zig-out. Runs on the BACKGROUND test desktop.
#
#   powershell -NoProfile -File test\win32\session-blades.ps1
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
$root = Join-Path $env:TEMP "ghoztty-session-blades-$PID"

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

# Persistence ON: the manifest restore path is the subject.
$appArgs = @('--config-default-files=false', '--session-persistence=true', '--macos-pane-style=flat')

function Start-App {
    $app = Start-OnTestDesktop -Exe $exe -Arguments $appArgs -KeepWindowPlacement
    $t = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($t -eq [IntPtr]::Zero) { Write-TestAssertedNothing -Reason 'the app never opened a GhozttyWindow' }
    $script:app = $app
    $script:top = $t
}

function Stop-App {
    if ($script:app) { Stop-Process -Id $script:app.Pid -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 800
}

function Get-VisiblePanes([IntPtr]$top) {
    return @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal' | Where-Object Visible)
}

# Wait until exactly `$n` pane HWNDs are visible.
function Wait-Shown([IntPtr]$top, [int]$n, [int]$timeoutSec = 20) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    do {
        $v = @(Get-VisiblePanes $top)
        if ($v.Count -eq $n) { return $v }
        Start-Sleep -Milliseconds 300
    } while ((Get-Date) -lt $deadline)
    return @(Get-VisiblePanes $top)
}

# Every terminal leaf `+list --json` reports, as Name / Focused / Minimized.
function Get-ListLeaves {
    $raw = (& $exe +list --json 2>$null) -join "`n"
    $out = New-Object System.Collections.ArrayList
    try { $doc = $raw | ConvertFrom-Json } catch { return }
    $walk = {
        param($node)
        if ($null -eq $node) { return }
        if ($node.type -eq 'leaf') {
            $t = $node.terminal
            [void]$out.Add([pscustomobject]@{ Name = [string]$t.name; Focused = [bool]$t.focused; Minimized = ($t.minimized -eq $true) })
        } else {
            & $walk $node.left
            & $walk $node.right
        }
    }
    $doc.data.windows | ForEach-Object { $_.tabs | ForEach-Object { & $walk $_.splits } }
    return $out.ToArray()
}

# The restored window, read until it reports four panes (a restore re-attaches
# its sessions one by one).
function Wait-ListLeaves([int]$timeoutSec = 20) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    do {
        $leaves = @(Get-ListLeaves)
        if ($leaves.Count -eq 4) { return $leaves }
        Start-Sleep -Milliseconds 400
    } while ((Get-Date) -lt $deadline)
    return @(Get-ListLeaves)
}

function Format-Leaves($leaves) {
    return (($leaves | ForEach-Object { "$(if ($_.Name) { $_.Name } else { 'P' })$(if ($_.Minimized) { '[min]' })$(if ($_.Focused) { '*' })" }) -join ' ')
}

# s1 alone on show, the other three blades, and s1 holding the caret.
function Assert-Blades([string]$claim) {
    $shown = @(Wait-Shown $script:top 1)
    $leaves = @(Wait-ListLeaves)
    Say ("      +list: {0}; {1} pane HWND(s) visible" -f (Format-Leaves $leaves), $shown.Count)
    Assert ($leaves.Count -eq 4) "${claim}: the window came back with four panes (got $($leaves.Count))"
    $min = @($leaves | Where-Object Minimized)
    Assert ($min.Count -eq 3) "${claim}: three panes come back minimized into blades (got $($min.Count))"
    $s1 = @($leaves | Where-Object { $_.Name -eq 's1' })
    Assert ($s1.Count -eq 1 -and -not $s1[0].Minimized) "${claim}: s1 is the pane on show"
    Assert ($s1.Count -eq 1 -and $s1[0].Focused) "${claim}: s1 holds the caret"
    Assert (@($min | Where-Object Focused).Count -eq 0) "${claim}: no blade holds the caret"
    Assert ($shown.Count -eq 1) "${claim}: exactly one pane HWND is on show (got $($shown.Count))"
}

function Read-Manifest { if (Test-Path $script:manifest) { [System.IO.File]::ReadAllText($script:manifest) } else { '' } }
function Write-Manifest([string]$text) {
    # No BOM: the JSON parser rejects one, and restore would silently fall
    # back to a fresh window (session-restore-maximized.ps1 measured it).
    [System.IO.File]::WriteAllText($script:manifest, $text, (New-Object System.Text.UTF8Encoding $false))
}

# -----------------------------------------------------------------------------

$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN
$savedPipe = $env:GHOZTTY_PIPE_SUFFIX
$env:GHOZTTY_PIPE_SUFFIX = "-sessionblades$PID"

Stop-RepoInstances
New-Item -ItemType Directory -Force $root | Out-Null
$tmp = Join-Path $root 'app'
New-Item -ItemType Directory -Force (Get-GhozttyAgentStateDir -Root $tmp) | Out-Null
$script:manifest = Get-GhozttySessionLayoutPath -Root $tmp
$env:LOCALAPPDATA = $tmp
$env:GHOSTTY_LOCAL_AGENT_BIN = $agent

Reset-TestBody
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    Assert (Test-Path $exe) 'ghoztty exe exists in zig-out'
    Assert (Test-Path $agent) 'ghoztty-agent exe exists in zig-out'
    [void](Assert-GhozttyIsolatedBuild -Exe $exe)
    if ($NegativeControl) {
        Say 'NEGATIVE CONTROL: the collapse is left out of the manifest - claim A MUST fail'
    }

    # ---- setup: P | (s1 | (s2 | s3)), 1500 DIP wide, persisted ---------------
    Say '== setup: P | (s1 | (s2 | s3))'
    Start-App
    Start-Sleep -Milliseconds 800
    $dpi = [int](Get-TestWindowDpi -Window $top)
    for ($i = 0; $i -lt 10; $i++) {
        Start-Sleep -Milliseconds 400
        $again = [int](Get-TestWindowDpi -Window $top)
        if ($again -eq $dpi) { break }
        $dpi = $again
    }
    if ($dpi -le 0) { $dpi = 96 }
    $scale = $dpi / 96.0
    [void](Set-TestWindowPos -Window $top -X 0 -Y 0 -Width (Get-TestChromeDip -Dip 1500 -Scale $scale) -Height (Get-TestChromeDip -Dip 700 -Scale $scale))
    Start-Sleep -Seconds 2
    & $exe +split --direction=right --name=s1 | Out-Null
    Start-Sleep -Milliseconds 800
    & $exe +split --pane=s1 --direction=right --name=s2 | Out-Null
    Start-Sleep -Milliseconds 800
    & $exe +split --pane=s2 --direction=right --name=s3 | Out-Null
    $c4 = @(Wait-Shown $top 4)
    if ($c4.Count -ne 4) { Write-TestAssertedNothing -Reason "four panes never came up on show at 1500 DIP (got $($c4.Count))" }
    $before = @(Wait-ListLeaves)
    Say ("      +list before: {0}" -f (Format-Leaves $before))
    Assert (@($before | Where-Object Minimized).Count -eq 0) 'setup: all four fit side by side at 1500 DIP - nothing minimized by want of room'

    # The manifest holds four attached panes before the kill.
    $deadline = (Get-Date).AddSeconds(20)
    do {
        Start-Sleep -Milliseconds 400
        $text = Read-Manifest
        $sids = ([regex]::Matches($text, '"session_id"\s*:\s*"[0-9a-f]{32}"')).Count
    } while ($sids -lt 4 -and (Get-Date) -lt $deadline)
    if ($sids -lt 4) { Write-TestAssertedNothing -Reason "the manifest never recorded four attached panes (got $sids)" }
    Stop-App

    # ---- A: the collapse comes back -------------------------------------------
    Say '== A: a row saved collapsed to s1'
    $text = Read-Manifest
    $tabs = ([regex]::Matches($text, '"active"\s*:\s*true')).Count
    if ($tabs -ne 1) { Write-TestAssertedNothing -Reason "expected one active tab in the manifest (got $tabs)" }
    $stack = '"pane_stack":{"rows":[{"leaves":[0,1,2,3],"start":1,"count":1}],"recency":[1,0],"t3126_marker":1}'
    # The app already writes a `pane_stack` for a tab with a focus history (no
    # rows yet): REPLACE it. A second key fails the whole manifest with
    # DuplicateField and restore silently falls back to the agent's copy
    # (measured while writing this script).
    $existing = '"pane_stack"\s*:\s*\{\s*"rows"\s*:\s*\[\s*\]\s*,\s*"recency"\s*:\s*\[[^\]]*\]\s*\}'
    if ($NegativeControl) {
        $text = [regex]::Replace($text, (',\s*' + $existing), '')
    } elseif ($text -match $existing) {
        $text = [regex]::Replace($text, $existing, $stack)
    } else {
        $text = [regex]::Replace($text, '"active"\s*:\s*true', ('"active":true,' + $stack))
    }
    Assert (([regex]::Matches($text, '"pane_stack"')).Count -eq $(if ($NegativeControl) { 0 } else { 1 })) 'A setup: the manifest carries exactly the stack state this section means'
    Write-Manifest $text
    Assert (([System.IO.File]::ReadAllBytes($script:manifest))[0] -eq 0x7B) 'A setup: patched manifest starts with { (no BOM)'
    Start-App
    Assert-Blades 'A'

    # ---- B: the app saved it again itself -------------------------------------
    Say '== B: the app re-saves the collapse'
    $deadline = (Get-Date).AddSeconds(15)
    do {
        Start-Sleep -Milliseconds 400
        $saved = Read-Manifest
    } while ($saved -match 't3126_marker' -and (Get-Date) -lt $deadline)
    Assert ($saved -notmatch 't3126_marker') 'B: the app rewrote the manifest (the planted marker is gone)'
    Assert ($saved -match '"pane_stack"\s*:\s*\{\s*"rows"\s*:\s*\[\s*\{\s*"leaves"\s*:\s*\[\s*0\s*,\s*1\s*,\s*2\s*,\s*3\s*\]\s*,\s*"start"\s*:\s*1\s*,\s*"count"\s*:\s*1') `
        'B: the rewrite carries the collapse: leaves 0-3, start 1, count 1'
    Assert ($saved -match '"recency"\s*:\s*\[\s*1\b') 'B: ...and the focus history, s1 first'
    Stop-App

    # ---- C: from the app's own manifest ---------------------------------------
    Say '== C: relaunched from what the app wrote'
    Start-App
    Assert-Blades 'C'
    Stop-App

    # ---- D: a blade newest in the history never takes the caret ----------------
    Say '== D: the history names a blade (s3) first'
    $text = Read-Manifest
    $patched = [regex]::Replace($text, '"recency"\s*:\s*\[[^\]]*\]', '"recency":[3,1]')
    Assert ($patched -ne $text) 'D setup: the history patched to s3, then s1'
    Write-Manifest $patched
    Start-App
    Assert-Blades 'D'
    $leaves = @(Get-ListLeaves)
    $s3 = @($leaves | Where-Object { $_.Name -eq 's3' })
    Assert ($s3.Count -eq 1 -and $s3[0].Minimized -and -not $s3[0].Focused) 'D: s3 stays a blade, without the caret'
    Stop-App

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
        update -Guard session-blades -Repo $repo 2>&1 | ForEach-Object { Say "  $_" }
}

Say ''
Write-TestVerdict -Label 'T3126 SESSION BLADES' -Pass $script:pass -Fail $script:fail -MinPass 24
