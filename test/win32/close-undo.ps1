# T1825 acceptance: closing a pane or a tab can be undone on Windows, the way
# Mac's undo-timeout does it - the closed pane comes back in the same place
# with its shell still running, and only when the undo expires is it ended.
#
# Phase A (session-persistence off, --undo-timeout=6s; local ConPTY panes):
#   1. +close a split: it leaves +list and its HWND is hidden, NOT destroyed,
#      and its shell process is still alive.
#   2. ctrl+shift+z: it is back - same pane id, same shell pid, same HWND, in
#      the same rectangle it left, and its --name resolves again.
#   3. ctrl+shift+y (redo) closes it again; ctrl+shift+z brings it back again.
#   4. A single-pane TAB closed with +close comes back as a tab, same pid.
#   5. Expiry: close it and wait out the timeout - the HWND is destroyed, the
#      shell has exited, and ctrl+shift+z has nothing to bring back.
# Phase B (session-persistence on, private agent lineage, --undo-timeout=5s):
#   6. +close an agent-backed split: during the undo window its session is
#      still alive AND attached (held for us); undo re-shows the same pane on
#      the same session.
#   7. Close it again and wait: the agent ends the session (one left alive).
#
# Runs on a BACKGROUND desktop (lib\TestDesktop.ps1) and never takes the
# user's foreground - asserted by the foreground watcher, not assumed.
# -NegativeControl launches phase A with --undo-timeout=0 (undo disabled) and
# keeps every expectation, so it MUST fail.
#
#   powershell -NoProfile -File test\win32\close-undo.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe',
    [switch]$NegativeControl,
    [switch]$Interactive
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:passes = 0
$tmp = Join-Path $env:TEMP "ghoztty-t1825-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ } else { "  FAIL $name"; $script:failures++ }
}
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
[void](Set-GhozttyTestAgentLineage -Tag 't1825')
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 't1825')

# The console twin redirects cleanly (T245); the GUI exe is what launches.
$Cli = [System.IO.Path]::ChangeExtension($Exe, '.com')
if (-not (Test-Path $Cli)) { $Cli = $Exe }

function Invoke-Cli([string]$CliArgs) {
    cmd /c "`"$Cli`" $CliArgs > `"$tmp\out.txt`" 2> `"$tmp\err.txt`"" | Out-Null
    return $LASTEXITCODE
}
function Get-CliOut { (Get-Content "$tmp\out.txt" -Raw -ErrorAction SilentlyContinue) }
function Get-CliErr { (Get-Content "$tmp\err.txt" -Raw -ErrorAction SilentlyContinue) }

# Every leaf object in `+list --json`: anything carrying both `id` and `pid`.
function Get-Leaves {
    [void](Invoke-Cli '+list --json')
    $raw = Get-CliOut
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    $out = New-Object System.Collections.ArrayList
    $walk = $null
    $walk = {
        param($o)
        if ($null -eq $o) { return }
        if ($o -is [System.Array]) { foreach ($x in $o) { & $walk $x }; return }
        if ($o -is [System.Management.Automation.PSCustomObject]) {
            $names = @($o.PSObject.Properties.Name)
            if (($names -contains 'id') -and ($names -contains 'pid')) { [void]$out.Add($o) }
            foreach ($p in $o.PSObject.Properties) { & $walk $p.Value }
        }
    }
    try { & $walk ($raw | ConvertFrom-Json) } catch { return @() }
    return , $out.ToArray()
}
function Get-LeafById([string]$Id) {
    foreach ($l in (Get-Leaves)) { if ($l.id -eq $Id) { return $l } }
    return $null
}
function Get-LeafByName([string]$Name) {
    foreach ($l in (Get-Leaves)) { if ($l.name -eq $Name) { return $l } }
    return $null
}
# Tabs across every window in `+list --json`.
function Get-TabCount {
    [void](Invoke-Cli '+list --json')
    $raw = Get-CliOut
    if ([string]::IsNullOrWhiteSpace($raw)) { return -1 }
    try { $j = $raw | ConvertFrom-Json } catch { return -1 }
    $windows = if ($null -ne $j.data) { $j.data.windows } else { $j.windows }
    $n = 0
    foreach ($w in @($windows)) { $n += @($w.tabs).Count }
    return $n
}
function Test-ProcAlive([int]$ProcId) {
    if ($ProcId -le 0) { return $false }
    return ($null -ne (Get-Process -Id $ProcId -ErrorAction SilentlyContinue))
}
function Get-Panes($top) { @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal') }
function Get-Pane($top, $hwnd) { @(Get-Panes $top) | Where-Object { $_.Hwnd -eq $hwnd } | Select-Object -First 1 }

# Poll until $Probe answers true (or the deadline passes).
function Wait-Until([scriptblock]$Probe, [int]$Seconds = 6) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    do {
        if (& $Probe) { return $true }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    return $false
}

# Press a ctrl+shift chord at the pane that has the keyboard.
function Send-Chord($top, $hwnd, [string]$Key) {
    [void](Focus-TestWindow -Window $top -Child ([IntPtr]$hwnd))
    return (Send-TestKeys -Window $top -Target ([IntPtr]$hwnd) -Modifiers ctrl,shift -Key $Key)
}

# `+sessions --json` rows for this run's private agent.
function Get-Sessions {
    if ((Invoke-Cli '+sessions --json') -ne 0) { return @() }
    $raw = Get-CliOut
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    # PS 5.1 hands a JSON array back as ONE object; landing it in a variable
    # first is what unrolls it into rows.
    $rows = $null
    try { $rows = $raw | ConvertFrom-Json } catch { return @() }
    if ($null -eq $rows) { return @() }
    return @($rows)
}
function Get-SessionForPane([string]$PaneId) {
    @(Get-Sessions) | Where-Object { $_.pane_id -eq $PaneId -and $_.alive -eq $true } | Select-Object -First 1
}

. (Join-Path $PSScriptRoot 'lib\Transcript.ps1')
$transcript = New-TestTranscript -Name 't1825'

Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$launched = @()
$script:reachedEnd = $false
$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN

& {
try {
    [void](Stop-RepoGhoztty -Exe $Exe -ScopeToLineage -SettleMs 500)
    Assert-GhozttyPrivateEndpoint -Exe $Exe

    # ======================================================================
    "== phase A: local panes (session-persistence off)"
    $timeout = if ($NegativeControl) { '0' } else { '6s' }
    if ($NegativeControl) { "  NEGATIVE CONTROL: undo-timeout=0 disables undo - this run MUST fail" }
    $app = Start-OnTestDesktop -Exe $Exe -Arguments @('--session-persistence=false', "--undo-timeout=$timeout")
    Start-Sleep -Seconds 3
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { "  SETUP FAIL: top window not found"; $script:failures++; return }
    Assert "window is NOT enumerable on the interactive desktop" (-not (Test-TestDesktopLeak -ProcessId $app.Pid))

    $P0 = @(Get-Panes $top)
    Assert "setup: one pane at launch" ($P0.Count -eq 1)
    $hP = $P0[0].Hwnd

    [void](Invoke-Cli "+split --direction=right --name=u1")
    Start-Sleep -Milliseconds 900
    $leaf = Get-LeafByName 'u1'
    $u1Id = if ($null -ne $leaf) { $leaf.id } else { '' }
    $u1Pid = if ($null -ne $leaf) { [int]$leaf.pid } else { 0 }
    $h1 = (@(Get-Panes $top) | Where-Object { $_.Hwnd -ne $hP } | Select-Object -First 1).Hwnd
    $before1 = Get-Pane $top $h1
    $beforeP = Get-Pane $top $hP
    Assert "setup: u1 is listed with a live shell (pid $u1Pid)" ($u1Id -ne '' -and (Test-ProcAlive $u1Pid))
    Assert "setup: two visible panes" (@(Get-Panes $top | Where-Object Visible).Count -eq 2 -and $h1)

    "== 1: a closed split is parked, not destroyed"
    $code = Invoke-Cli "+close --target=u1"
    Assert "+close u1 exit 0 ($(Get-CliErr))" ($code -eq 0)
    Assert "u1 left +list" (Wait-Until { $null -eq (Get-LeafById $u1Id) })
    $p1 = Get-Pane $top $h1
    Assert "u1's HWND still exists, hidden" ((Test-TestWindowExists -Window ([IntPtr]$h1)) -and $null -ne $p1 -and -not $p1.Visible)
    Assert "u1's shell is still running" (Test-ProcAlive $u1Pid)
    Assert "P took the whole window" (Wait-Until { $p = Get-Pane $top $hP; $p.Width -gt $beforeP.Width })

    "== 2: ctrl+shift+z brings it back where it was"
    Assert "ctrl+shift+z delivered" (Send-Chord $top $hP 'Z')
    Assert "u1 is listed again" (Wait-Until { $null -ne (Get-LeafById $u1Id) })
    $back = Get-LeafById $u1Id
    Assert "same shell pid ($u1Pid -> $(if ($back) { $back.pid }))" ($null -ne $back -and [int]$back.pid -eq $u1Pid)
    Assert "its --name resolves again" ($null -ne (Get-LeafByName 'u1'))
    $a1 = Get-Pane $top $h1
    Assert "same HWND, visible, in the slot it left" ($null -ne $a1 -and $a1.Visible -and `
            $a1.Left -eq $before1.Left -and $a1.Top -eq $before1.Top -and `
            $a1.Width -eq $before1.Width -and $a1.Height -eq $before1.Height)

    "== 3: redo closes it again; undo brings it back again"
    Assert "ctrl+shift+y delivered" (Send-Chord $top $hP 'Y')
    Assert "redo closed u1 again" (Wait-Until { $null -eq (Get-LeafById $u1Id) })
    Assert "the shell survived the redo too" (Test-ProcAlive $u1Pid)
    Assert "ctrl+shift+z delivered (after redo)" (Send-Chord $top $hP 'Z')
    Assert "undo after redo brought u1 back" (Wait-Until { $null -ne (Get-LeafById $u1Id) })

    "== 4: a closed tab comes back as a tab"
    $tabsBefore = Get-TabCount
    $leavesBefore = Get-Leaves
    $idsBefore = @($leavesBefore | ForEach-Object { $_.id })
    Assert "ctrl+t delivered" ((Focus-TestWindow -Window $top -Child ([IntPtr]$hP)) -and `
            (Send-TestKeys -Window $top -Target ([IntPtr]$hP) -Modifiers ctrl -Key T))
    Assert "a second tab opened" (Wait-Until { (Get-TabCount) -eq $tabsBefore + 1 })
    $known = @($hP, $h1)
    $leavesAfter = Get-Leaves
    $tabLeaf = $leavesAfter | Where-Object { $idsBefore -notcontains $_.id } | Select-Object -First 1
    $tabId = if ($null -ne $tabLeaf) { $tabLeaf.id } else { '' }
    $tabPid = if ($null -ne $tabLeaf) { [int]$tabLeaf.pid } else { 0 }
    Assert "setup: the new tab's pane is listed (pid $tabPid)" ($tabId -ne '' -and (Test-ProcAlive $tabPid))
    $hT = (@(Get-Panes $top) | Where-Object { $known -notcontains $_.Hwnd } | Select-Object -First 1).Hwnd
    $code = Invoke-Cli "+close --target=$tabId"
    Assert "+close the tab's only pane exit 0" ($code -eq 0)
    Assert "the tab closed" (Wait-Until { (Get-TabCount) -eq $tabsBefore })
    Assert "its shell is still running" (Test-ProcAlive $tabPid)
    Assert "ctrl+shift+z delivered (tab)" (Send-Chord $top $hP 'Z')
    Assert "the tab is back" (Wait-Until { (Get-TabCount) -eq $tabsBefore + 1 })
    $tb = Get-LeafById $tabId
    Assert "same pane, same shell pid" ($null -ne $tb -and [int]$tb.pid -eq $tabPid)
    Assert "its HWND is shown again" ($hT -and (Wait-Until { $p = Get-Pane $top $hT; $null -ne $p -and $p.Visible }))

    "== 5: when the undo expires, the close happens for real"
    $code = Invoke-Cli "+close --target=u1"
    Assert "+close u1 exit 0 (expiry)" ($code -eq 0)
    Assert "u1 left +list (expiry)" (Wait-Until { $null -eq (Get-LeafById $u1Id) })
    Assert "u1's HWND is destroyed once the 6s undo runs out" (Wait-Until { -not (Test-TestWindowExists -Window ([IntPtr]$h1)) } 14)
    Assert "u1's shell has exited" (Wait-Until { -not (Test-ProcAlive $u1Pid) } 6)
    # The tab's undo is the newest entry left (it was undone, so nothing): the
    # chord must find nothing and change nothing.
    $leavesNow = (Get-Leaves).Count
    [void](Send-Chord $top $hP 'Z')
    Start-Sleep -Milliseconds 800
    Assert "nothing comes back after the expiry" ((Get-Leaves).Count -eq $leavesNow -and $null -eq (Get-LeafById $u1Id))
    Assert "no crash (phase A)" (-not ($app.Process -and $app.Process.HasExited))
    $launched += $script:GhozttyTestDesktopPids
    [void](Stop-RepoGhoztty -Exe $Exe -ScopeToLineage -SettleMs 700)

    # ======================================================================
    "== phase B: agent-backed panes (session-persistence on)"
    $root = Join-Path $tmp 'phase-b'
    New-Item -ItemType Directory -Force (Get-GhozttyAgentStateDir -Root $root) | Out-Null
    $env:LOCALAPPDATA = $root
    $env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe
    $appB = Start-OnTestDesktop -Exe $Exe -Arguments @('--session-persistence=true', '--undo-timeout=5s', '--title=t1825-phase-b')
    $topB = Wait-TestWindow -ProcessId $appB.Pid -Class 'GhozttyWindow'
    if ($topB -eq [IntPtr]::Zero) { "  SETUP FAIL: phase B window not found"; $script:failures++; return }
    Assert "setup: one live agent session" (Wait-Until { @(Get-Sessions | Where-Object { $_.alive -eq $true }).Count -eq 1 } 20)
    $hB = (@(Get-Panes $topB) | Select-Object -First 1).Hwnd
    [void](Invoke-Cli "+split --direction=right --name=b1")
    Assert "setup: a second live session for b1" (Wait-Until { @(Get-Sessions | Where-Object { $_.alive -eq $true }).Count -eq 2 } 15)
    $b1 = Get-LeafByName 'b1'
    $b1Id = if ($null -ne $b1) { $b1.id } else { '' }
    $sess = Get-SessionForPane $b1Id
    $sessId = if ($null -ne $sess) { $sess.id } else { '' }
    Assert "setup: b1's session found ($sessId)" ($sessId -ne '')

    "== 6: during the undo window the session is held for us"
    $code = Invoke-Cli "+close --target=b1"
    Assert "+close b1 exit 0" ($code -eq 0)
    Assert "b1 left +list" (Wait-Until { $null -eq (Get-LeafById $b1Id) })
    $held = @(Get-Sessions) | Where-Object { $_.id -eq $sessId } | Select-Object -First 1
    Assert "its session is still alive and attached" ($null -ne $held -and $held.alive -eq $true -and $held.attached -eq $true)
    Assert "ctrl+shift+z delivered (phase B)" (Send-Chord $topB $hB 'Z')
    Assert "b1 is back" (Wait-Until { $null -ne (Get-LeafById $b1Id) })
    $again = Get-SessionForPane $b1Id
    Assert "on the same session" ($null -ne $again -and $again.id -eq $sessId -and $again.attached -eq $true)

    "== 7: when the undo expires the agent ends the session"
    $code = Invoke-Cli "+close --target=b1"
    Assert "+close b1 exit 0 (expiry)" ($code -eq 0)
    $stillThere = @(Get-Sessions) | Where-Object { $_.id -eq $sessId -and $_.alive -eq $true }
    Assert "right after the close the session is still alive" (@($stillThere).Count -eq 1)
    Assert "after the 5s undo the session is gone (one alive)" (Wait-Until {
            @(Get-Sessions | Where-Object { $_.alive -eq $true }).Count -eq 1 -and
            @(Get-Sessions | Where-Object { $_.id -eq $sessId -and $_.alive -eq $true }).Count -eq 0 } 15)
    Assert "no crash (phase B)" (-not ($appB.Process -and $appB.Process.HasExited))
    $launched += $script:GhozttyTestDesktopPids
    $script:reachedEnd = $true
} catch {
    "  FAIL body threw: $($_.Exception.Message)"
    $script:failures++
} finally {
    Remove-TestDesktop
    [void](Stop-RepoGhoztty -Exe $Exe -ScopeToLineage -SettleMs 500)
    $env:LOCALAPPDATA = $savedLocalAppData
    if ($null -ne $savedAgentBin) { $env:GHOSTTY_LOCAL_AGENT_BIN = $savedAgentBin }
    else { Remove-Item env:GHOSTTY_LOCAL_AGENT_BIN -ErrorAction SilentlyContinue }
}

# A body that died part-way must not score green on the assertions it made
# before dying (the T271 shape).
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

# A green run stamps the covered files (T783); red, or a negative control,
# leaves the stamp alone so the row stays due.
if ($script:failures -eq 0 -and -not $NegativeControl) {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard close-undo -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

""
exit (Complete-TestTranscript -Name 't1825' -Path $transcript `
        -Label 'T1825 ACCEPTANCE' -Pass $script:passes -Fail $script:failures).Code
