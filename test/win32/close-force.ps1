# T2938 acceptance: `+close --force`, and a `+close` that cannot close because
# the window is waiting on a close confirmation fails instead of reporting
# success (Mac 4b558ab8f).
#
# Phase A (session-persistence off, --undo-timeout=30s,
# --confirm-close-surface=always so every window close asks):
#   1. Control: a plain +close of a split is PARKED for the undo - its shell is
#      still alive afterwards. (The thing --force must not do.)
#   2. --force on a split: it leaves +list and its shell EXITS well inside the
#      30s undo window - no undo was kept.
#   3. A window close (WM_CLOSE) puts the "Processes are still running" dialog
#      up. A plain +close of a pane in that window now FAILS (exit != 0, says
#      "waiting on a close confirmation"), and closes nothing: the dialog is
#      still up and the pane is still listed.
#   4. +close --force of that pane: exit 0, the dialog is gone, the pane is gone
#      and its shell exits, and the window itself survives (the dismissed
#      confirmation was answered Cancel, not OK).
#   5. Same for a WINDOW target: a second window with its close confirmation
#      up refuses a plain +close, and +close --force destroys it (HWND gone,
#      not parked hidden) with the first window untouched.
#   6. --force on a window with no dialog: destroyed at once, not parked; a
#      plain +close of a third window is the control (parked: hidden, alive).
# Phase B (session-persistence on, private agent lineage, --undo-timeout=30s):
#   7. --force on an agent-backed window ENDS its session right away, where a
#      plain close holds it for the whole undo window.
#
# Runs on a BACKGROUND desktop (lib\TestDesktop.ps1) and never takes the
# user's foreground - asserted by the foreground watcher, not assumed.
# -NegativeControl sends every forced close WITHOUT --force, so it MUST fail.
#
#   powershell -NoProfile -File test\win32\close-force.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe',
    [switch]$NegativeControl,
    [switch]$Interactive
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:passes = 0
$tmp = Join-Path $env:TEMP "ghoztty-t2938-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ } else { "  FAIL $name"; $script:failures++ }
}
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
[void](Set-GhozttyTestAgentLineage -Tag 't2938')
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 't2938')

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not (Test-Path $Exe)) { $Exe = Join-Path $repoRoot 'zig-out\bin\ghoztty.exe' }
if (-not (Test-Path $AgentExe)) { $AgentExe = Join-Path $repoRoot 'zig-out\bin\ghoztty-agent.exe' }

# The console twin redirects cleanly (T245); the GUI exe is what launches.
$Cli = [System.IO.Path]::ChangeExtension($Exe, '.com')
if (-not (Test-Path $Cli)) { $Cli = $Exe }

function Invoke-Cli([string]$CliArgs) {
    cmd /c "`"$Cli`" $CliArgs > `"$tmp\out.txt`" 2> `"$tmp\err.txt`"" | Out-Null
    return $LASTEXITCODE
}
function Get-CliOut { (Get-Content "$tmp\out.txt" -Raw -ErrorAction SilentlyContinue) }
function Get-CliErr { (Get-Content "$tmp\err.txt" -Raw -ErrorAction SilentlyContinue) }

# The forced close under test. -NegativeControl drops the flag, so every
# assertion that depends on it goes red.
function Invoke-ForceClose([string]$Target) {
    if ($NegativeControl) { return (Invoke-Cli "+close --target=$Target") }
    return (Invoke-Cli "+close --force --target=$Target")
}

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
function Test-ProcAlive([int]$ProcId) {
    if ($ProcId -le 0) { return $false }
    return ($null -ne (Get-Process -Id $ProcId -ErrorAction SilentlyContinue))
}
function Wait-Until([scriptblock]$Probe, [int]$Seconds = 6) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    do {
        if (& $Probe) { return $true }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    return $false
}
function Get-Dialog([int]$AppPid) { Get-TestWindow -ProcessId $AppPid -Class 'GhozttyConfirmDialog' }
function Wait-DialogGone([int]$AppPid, [int]$Seconds = 5) {
    return (Wait-Until { (Get-Dialog $AppPid) -eq [IntPtr]::Zero } $Seconds)
}
# Every top-level GhozttyWindow of the app, hidden ones included (a parked
# window is hidden, not destroyed).
function Get-Tops([int]$AppPid) { @(Get-TestWindows -ProcessId $AppPid -Class 'GhozttyWindow' -AllowHidden) }
# The window `+new-window` just made: the one top-level that was not there.
function Get-NewTop([int]$AppPid, [int64[]]$Before) {
    $found = [int64]0
    [void](Wait-Until {
            $n = @(Get-Tops $AppPid | Where-Object { $_.Visible -and ($Before -notcontains $_.Hwnd) })
            if ($n.Count -gt 0) { $script:newTop = $n[0].Hwnd; return $true }
            return $false
        } 8)
    if ($script:newTop) { $found = $script:newTop }
    $script:newTop = $null
    return $found
}
# Raise the close confirmation over $Top the way the title-bar X does.
function Open-CloseConfirm([int]$AppPid, [IntPtr]$Top) {
    [void](Send-TestWindowClose -Window $Top)
    return (Wait-TestWindow -ProcessId $AppPid -Class 'GhozttyConfirmDialog' -TimeoutMs 5000)
}

# `+sessions --json` rows for this run's private agent.
function Get-Sessions {
    if ((Invoke-Cli '+sessions --json') -ne 0) { return @() }
    $raw = Get-CliOut
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    $rows = $null
    try { $rows = $raw | ConvertFrom-Json } catch { return @() }
    if ($null -eq $rows) { return @() }
    return @($rows)
}

. (Join-Path $PSScriptRoot 'lib\Transcript.ps1')
$transcript = New-TestTranscript -Name 't2938'

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
    if ($NegativeControl) { "  NEGATIVE CONTROL: every forced close is sent WITHOUT --force - this run MUST fail" }

    # ======================================================================
    "== phase A: local panes (session-persistence off)"
    $app = Start-OnTestDesktop -Exe $Exe -Arguments @('--session-persistence=false', '--undo-timeout=30s', '--confirm-close-surface=always')
    Start-Sleep -Seconds 3
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { "  SETUP FAIL: top window not found"; $script:failures++; return }
    Assert "window is NOT enumerable on the interactive desktop" (-not (Test-TestDesktopLeak -ProcessId $app.Pid))

    "== 1: control - a plain +close of a split is parked for the undo"
    [void](Invoke-Cli "+split --direction=right --name=p1")
    $p1 = $null
    [void](Wait-Until { $script:p1l = Get-LeafByName 'p1'; $null -ne $script:p1l } 8)
    $p1 = $script:p1l
    $p1Pid = if ($null -ne $p1) { [int]$p1.pid } else { 0 }
    Assert "setup: p1 listed with a live shell (pid $p1Pid)" (Test-ProcAlive $p1Pid)
    $code = Invoke-Cli "+close --target=p1"
    Assert "plain +close p1 exit 0 ($(Get-CliErr))" ($code -eq 0)
    Assert "p1 left +list" (Wait-Until { $null -eq (Get-LeafByName 'p1') })
    Start-Sleep -Seconds 3
    Assert "p1's shell is still alive 3s later (parked for the 30s undo)" (Test-ProcAlive $p1Pid)

    "== 2: --force on a split ends it now - no undo kept"
    [void](Invoke-Cli "+split --direction=right --name=p2")
    [void](Wait-Until { $script:p2l = Get-LeafByName 'p2'; $null -ne $script:p2l } 8)
    $p2Pid = if ($null -ne $script:p2l) { [int]$script:p2l.pid } else { 0 }
    Assert "setup: p2 listed with a live shell (pid $p2Pid)" (Test-ProcAlive $p2Pid)
    $code = Invoke-ForceClose 'p2'
    Assert "+close --force p2 exit 0 ($(Get-CliErr))" ($code -eq 0)
    Assert "p2 left +list" (Wait-Until { $null -eq (Get-LeafByName 'p2') })
    Assert "p2's shell exits within 10s (inside the 30s undo window)" (Wait-Until { -not (Test-ProcAlive $p2Pid) } 10)
    Assert "the window survives a forced split close" (Test-TestWindowVisible -Window $top)

    "== 3: a pane in a window waiting on its close confirmation"
    [void](Invoke-Cli "+split --direction=right --name=p3")
    [void](Wait-Until { $script:p3l = Get-LeafByName 'p3'; $null -ne $script:p3l } 8)
    $p3Pid = if ($null -ne $script:p3l) { [int]$script:p3l.pid } else { 0 }
    Assert "setup: p3 listed with a live shell (pid $p3Pid)" (Test-ProcAlive $p3Pid)
    $dlg = Open-CloseConfirm $app.Pid $top
    Assert "setup: the window close put the confirmation up" ($dlg -ne [IntPtr]::Zero)
    $code = Invoke-Cli "+close --target=p3"
    $err = Get-CliErr
    Assert "plain +close p3 FAILS while the confirmation is up (exit $code)" ($code -ne 0)
    Assert "and says it is waiting on a close confirmation ('$(($err -replace "`r?`n", ' ').Trim())')" ($err -match 'waiting on a close confirmation')
    Assert "and points at --force" ($err -match '--force')
    Assert "the confirmation is still up" ((Get-Dialog $app.Pid) -ne [IntPtr]::Zero)
    Assert "p3 is still listed (nothing closed)" ($null -ne (Get-LeafByName 'p3'))
    Assert "p3's shell is still alive" (Test-ProcAlive $p3Pid)

    "== 4: --force answers the confirmation and closes the pane"
    $code = Invoke-ForceClose 'p3'
    Assert "+close --force p3 exit 0 ($(Get-CliErr))" ($code -eq 0)
    Assert "the confirmation is gone" (Wait-DialogGone $app.Pid)
    Assert "p3 left +list" (Wait-Until { $null -eq (Get-LeafByName 'p3') })
    Assert "p3's shell exits within 10s (no undo)" (Wait-Until { -not (Test-ProcAlive $p3Pid) } 10)
    Assert "the window survives: the dismissed confirmation was a Cancel" (Test-TestWindowVisible -Window $top)
    Assert "the window takes input again (re-enabled)" (Wait-Until { Test-TestWindowEnabled -Window $top } 3)

    "== 5: a WINDOW target waiting on its close confirmation"
    $before = @(Get-Tops $app.Pid | ForEach-Object { $_.Hwnd })
    Assert "+new-window w1 exit 0 ($(Get-CliErr))" ((Invoke-Cli "+new-window --target=w1") -eq 0)
    $w1 = Get-NewTop $app.Pid $before
    Assert "setup: w1's window found" ($w1 -ne 0)
    Start-Sleep -Milliseconds 800
    if ($w1 -ne 0) {
        $dlg = Open-CloseConfirm $app.Pid ([IntPtr]$w1)
        Assert "setup: w1's close put the confirmation up" ($dlg -ne [IntPtr]::Zero)
        $code = Invoke-Cli "+close --target=w1"
        $err = Get-CliErr
        Assert "plain +close w1 FAILS while its confirmation is up (exit $code)" ($code -ne 0)
        Assert "and says it is waiting on a close confirmation" ($err -match 'waiting on a close confirmation')
        Assert "w1 still exists" (Test-TestWindowExists -Window ([IntPtr]$w1))
        $code = Invoke-ForceClose 'w1'
        Assert "+close --force w1 exit 0 ($(Get-CliErr))" ($code -eq 0)
        Assert "the confirmation is gone" (Wait-DialogGone $app.Pid)
        Assert "w1's HWND is DESTROYED (not parked hidden)" (Wait-Until { -not (Test-TestWindowExists -Window ([IntPtr]$w1)) } 8)
        Assert "the first window is untouched" (Test-TestWindowVisible -Window $top)
    }

    "== 6: --force on a window with nothing to answer; plain close is the control"
    $before = @(Get-Tops $app.Pid | ForEach-Object { $_.Hwnd })
    Assert "+new-window w2 exit 0" ((Invoke-Cli "+new-window --target=w2") -eq 0)
    $w2 = Get-NewTop $app.Pid $before
    Assert "setup: w2's window found" ($w2 -ne 0)
    $before = @(Get-Tops $app.Pid | ForEach-Object { $_.Hwnd })
    Assert "+new-window w3 exit 0" ((Invoke-Cli "+new-window --target=w3") -eq 0)
    $w3 = Get-NewTop $app.Pid $before
    Assert "setup: w3's window found" ($w3 -ne 0)
    if ($w2 -ne 0 -and $w3 -ne 0) {
        Assert "plain +close w3 exit 0" ((Invoke-Cli "+close --target=w3") -eq 0)
        Assert "control: w3 is hidden" (Wait-Until { -not (Test-TestWindowVisible -Window ([IntPtr]$w3)) } 5)
        Start-Sleep -Seconds 1
        Assert "control: w3's HWND still exists (parked for undo)" (Test-TestWindowExists -Window ([IntPtr]$w3))
        $code = Invoke-ForceClose 'w2'
        Assert "+close --force w2 exit 0 ($(Get-CliErr))" ($code -eq 0)
        Assert "w2's HWND is destroyed at once" (Wait-Until { -not (Test-TestWindowExists -Window ([IntPtr]$w2)) } 5)
    }
    Assert "no crash (phase A)" (-not ($app.Process -and $app.Process.HasExited))
    $launched += $script:GhozttyTestDesktopPids
    [void](Stop-RepoGhoztty -Exe $Exe -ScopeToLineage -SettleMs 700)

    # ======================================================================
    "== phase B: agent-backed panes (session-persistence on)"
    $root = Join-Path $tmp 'phase-b'
    New-Item -ItemType Directory -Force (Get-GhozttyAgentStateDir -Root $root) | Out-Null
    $env:LOCALAPPDATA = $root
    $env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe
    $appB = Start-OnTestDesktop -Exe $Exe -Arguments @('--session-persistence=true', '--undo-timeout=30s', '--title=t2938-phase-b')
    $topB = Wait-TestWindow -ProcessId $appB.Pid -Class 'GhozttyWindow'
    if ($topB -eq [IntPtr]::Zero) { "  SETUP FAIL: phase B window not found"; $script:failures++; return }
    Assert "setup: one live agent session" (Wait-Until { @(Get-Sessions | Where-Object { $_.alive -eq $true }).Count -eq 1 } 20)

    "== 7: --force ENDS an agent-backed window's session at once"
    # Control first: a plain close holds the session for the undo.
    $aliveBefore = @(Get-Sessions | Where-Object { $_.alive -eq $true } | ForEach-Object { $_.id })
    Assert "+new-window bc exit 0" ((Invoke-Cli "+new-window --target=bc") -eq 0)
    Assert "setup: bc has its own live session" (Wait-Until { @(Get-Sessions | Where-Object { $_.alive -eq $true }).Count -eq 2 } 15)
    $bcSess = @(Get-Sessions | Where-Object { $_.alive -eq $true -and $aliveBefore -notcontains $_.id }) | Select-Object -First 1
    $bcId = if ($null -ne $bcSess) { $bcSess.id } else { '' }
    Assert "plain +close bc exit 0" ((Invoke-Cli "+close --target=bc") -eq 0)
    Start-Sleep -Seconds 3
    $held = @(Get-Sessions) | Where-Object { $_.id -eq $bcId -and $_.alive -eq $true }
    Assert "control: 3s after a plain close bc's session is still alive (held for the undo)" ($bcId -ne '' -and @($held).Count -eq 1)

    $aliveBefore = @(Get-Sessions | Where-Object { $_.alive -eq $true } | ForEach-Object { $_.id })
    Assert "+new-window bf exit 0" ((Invoke-Cli "+new-window --target=bf") -eq 0)
    Assert "setup: bf has its own live session" (Wait-Until { @(Get-Sessions | Where-Object { $_.alive -eq $true -and $aliveBefore -notcontains $_.id }).Count -eq 1 } 15)
    $bfSess = @(Get-Sessions | Where-Object { $_.alive -eq $true -and $aliveBefore -notcontains $_.id }) | Select-Object -First 1
    $bfId = if ($null -ne $bfSess) { $bfSess.id } else { '' }
    Assert "setup: bf's session found ($bfId)" ($bfId -ne '')
    $code = Invoke-ForceClose 'bf'
    Assert "+close --force bf exit 0 ($(Get-CliErr))" ($code -eq 0)
    Assert "bf's session ENDS within 10s (inside the 30s undo window)" (Wait-Until {
            @(Get-Sessions | Where-Object { $_.id -eq $bfId -and $_.alive -eq $true }).Count -eq 0 } 10)
    Assert "no crash (phase B)" (-not ($appB.Process -and $appB.Process.HasExited))
    $launched += $script:GhozttyTestDesktopPids
    $script:reachedEnd = $true
} catch {
    "  FAIL body threw: $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim()))"
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
        update -Guard close-force -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

""
exit (Complete-TestTranscript -Name 't2938' -Path $transcript `
        -Label 'T2938 ACCEPTANCE' -Pass $script:passes -Fail $script:failures).Code
