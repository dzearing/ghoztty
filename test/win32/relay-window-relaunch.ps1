# T3352 acceptance: a relay window open when Ghoztty goes away comes back at
# the next launch, re-attached to the same session on the far machine, under the
# same name - the Windows counterpart of Mac's RemoteSessionManifest (WP-D2).
#
# WHAT WAS WRONG. The local layout capture skips every relay window (its shells
# live on the FAR agent), and nothing else remembered it, so a relay window
# open at quit simply did not come back. The chooser's Restore All could
# rebuild it only from the far machine's own layouts, which never describe a
# window THIS app opened with `+new-remote-window`, and it dropped the window's
# `--name` either way.
#
# The arms, read from the app's log lines (`relay window record: ...`,
# `relay window restore: ...`), the record file itself
# (%LOCALAPPDATA%\ghoztty\remote-windows-debug.json), the pill oracle line and
# `+list --json`:
#
#   A  RECORD. `+new-remote-window --name=X` (a pinned name, T1736) is recorded
#      with its relay, device, name, pin and IPC name, and the record gains the
#      pane's session id once the far agent has opened it. A `+rename` title
#      lands in the record too.
#   B  A DELIBERATE CLOSE FORGETS. A second relay window closed with `+close`
#      leaves the record: a window the user closed does not come back.
#   C  RELAUNCH. The app process goes away without closing anything (the shape
#      of a quit, and of a crash - the record is already on disk). The next
#      launch re-attaches exactly the window still recorded: same session id on
#      the far agent, the pill reads X (the pin survived), `+list --json` finds
#      a window named X again, the title came back, and the closed window from
#      B did not.
#
# NEGATIVE CONTROL: -NegativeControl asserts that the relaunch opened NO relay
# window, which is the pre-fix behaviour, and MUST fail.
#
# LIMITS: a session the far agent has since lost is dropped by the same probe
# (`probeSessionTimeout` -> `.dead`) and is not constructed here; neither is an
# unreachable relay (the entry is kept). Both fates are unit-tested on the
# record's side (`relay_manifest.zig`, mark-don't-drain).
#
#   powershell -NoProfile -File test\win32\relay-window-relaunch.ps1
#
# Only touches ghoztty processes running from this repo's zig-out.
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [int]$AgentPort = 0,
    [int]$RelayPort = 0,
    [switch]$NegativeControl
)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\FreePort.ps1')
$AgentPort = Resolve-TestPort -Name 'agent' -Port $AgentPort
$RelayPort = Resolve-TestPort -Name 'relay' -Port $RelayPort

$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not (Test-Path $Exe)) { $Exe = Join-Path $repo 'zig-out\bin\ghoztty.exe' }
$agentExe = Join-Path (Split-Path $Exe -Parent) 'ghoztty-agent.exe'

$env:GHOZTTY_PIPE_SUFFIX = "-t3352$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\FakeRelay.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
. (Join-Path $PSScriptRoot 'lib\AgentLineage.ps1')

$script:pass = 0
$script:fail = 0
$script:skipped = 0
function Assert($cond, $name) {
    if ($cond) { Write-Host "  PASS $name"; $script:pass++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:fail++ }
}

function Count-LogLines($path, $pattern) {
    if (-not (Test-Path $path)) { return 0 }
    return @(Select-String -Path $path -Pattern $pattern -ErrorAction SilentlyContinue).Count
}

function Wait-LogCount($path, $pattern, $want, $timeoutMs) {
    $waited = 0
    while ($waited -lt $timeoutMs) {
        if ((Count-LogLines $path $pattern) -ge $want) { return $true }
        Start-Sleep -Milliseconds 200
        $waited += 200
    }
    return $false
}

function Get-PillLabels($log) {
    if (-not (Test-Path $log)) { return @() }
    return @(Select-String -Path $log -Pattern 'remote pill mode=connected label=(.*) w=\d+' -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Matches[0].Groups[1].Value })
}

# The record's windows, as objects (an empty array when the file is absent).
function Get-Record {
    if (-not (Test-Path $recordFile)) { return @() }
    try {
        $j = Get-Content -Raw $recordFile | ConvertFrom-Json
    } catch { return @() }
    return @($j.windows | ForEach-Object { $_ })
}

function Wait-Record([scriptblock]$cond, [int]$timeoutMs) {
    $waited = 0
    while ($waited -lt $timeoutMs) {
        $r = Get-Record
        if (& $cond $r) { return $r }
        Start-Sleep -Milliseconds 200
        $waited += 200
    }
    return Get-Record
}

function Invoke-Cli([string]$argLine, [string]$outName) {
    $out = Join-Path $tmp "$outName.txt"
    cmd /c "`"$Exe`" $argLine > `"$out`" 2>&1"
    $script:lastOut = (Get-Content -Raw $out -ErrorAction SilentlyContinue)
    return $LASTEXITCODE
}

function Start-App([string]$log) {
    $env:GHOSTTY_RELAY_BASE = "http://127.0.0.1:$RelayPort"
    $env:GHOSTTY_RELAY_TOKEN = $TOKEN
    $env:GHOSTTY_ACCOUNT_STORE = (Join-Path $tmp 'account.dat')
    $a = Start-OnTestDesktop -Exe $Exe `
        -Arguments @('--window-width=100', '--window-height=30', '--session-persistence=false') `
        -StdErr $log
    foreach ($k in 'GHOSTTY_RELAY_BASE', 'GHOSTTY_RELAY_TOKEN', 'GHOSTTY_ACCOUNT_STORE') {
        Remove-Item "env:$k" -ErrorAction SilentlyContinue
    }
    return $a
}

$TOKEN = 'faketoken-t3352'
$DEV = 'dev-t3352'
$PINNED = 'RelaunchPinned'
$CLOSED = 'RelaunchClosed'
$TITLE = 'RelaunchTitle'
$devicesJson = '{"devices":[{"id":"' + $DEV + '","name":"ListedName","online":true}]}'

$errlog1 = Join-Path $env:TEMP "ghoztty-t3352-stderr1-$PID.log"
$errlog2 = Join-Path $env:TEMP "ghoztty-t3352-stderr2-$PID.log"
$relaylog = Join-Path $env:TEMP "ghoztty-t3352-relay-$PID.log"
$agentlog = Join-Path $env:TEMP "ghoztty-t3352-agent-$PID.log"
$tmp = Join-Path $env:TEMP "ghoztty-t3352-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null
# The debug build's record (never the release app's). Whatever an earlier run
# left there is put back afterwards.
# The app names it after the lineage (relay_manifest.zig pathIn:
# remote-windows-debug[-<lineage>].json), so this run takes its own lineage -
# or keeps the parallel runner's - and reads the file the app actually writes,
# never a neighbouring worker's.
$savedLineage = Get-GhozttyAgentLineage
$lineage = Set-GhozttyTestAgentLineage -Tag 'rwr' -Quiet
$recordFile = Join-Path $env:LOCALAPPDATA "ghoztty\remote-windows-debug-$lineage.json"
$recordBackup = Join-Path $tmp 'remote-windows-debug.json.bak'
$hadRecord = Test-Path $recordFile
if ($hadRecord) { Move-Item $recordFile $recordBackup -Force }
Remove-Item $errlog1, $errlog2, $relaylog -ErrorAction SilentlyContinue

Write-Host 'T3352 a relay window open at quit comes back at the next launch'
Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null
[void](Stop-RepoGhoztty -Exe $Exe -SettleMs 500)
New-TestDesktop | Out-Null

$script:agent = $null
$script:relay = $null
$app = $null
try {
    if (-not (Test-Path $agentExe)) {
        Write-TestAssertedNothing -Reason "no agent binary at $agentExe"
    }
    $env:GHOSTTY_AGENT_LOCK = Join-Path $tmp 'agent.lock'
    Assert-GhozttyIsolatedAgent -Exe $agentExe | Out-Null
    $script:agent = Start-Process -FilePath $agentExe `
        -ArgumentList '--listen', "127.0.0.1:$AgentPort", '--headless' -PassThru -WindowStyle Hidden `
        -RedirectStandardError $agentlog
    $null = $script:agent.Handle
    Start-Sleep -Seconds 2
    if ($script:agent.HasExited) {
        Write-TestAssertedNothing -Reason 'the remote agent died at launch'
    }
    $script:relay = Start-FakeRelay -Port $RelayPort -AgentPort $AgentPort `
        -DevicesJson $devicesJson -LogPath $relaylog
    if (-not (Select-String -Path $relaylog -Pattern 'LISTEN' -Quiet)) {
        Write-TestAssertedNothing -Reason 'the fake relay never listened'
    }
    Write-Host "  OK   remote agent pid=$($script:agent.Id), fake relay on 127.0.0.1:$RelayPort"

    $app = Start-App $errlog1
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) {
        Write-TestAssertedNothing -Reason 'the GUI died at launch'
    }
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { Write-TestAssertedNothing -Reason 'no top window' }

    # --- A: the record ------------------------------------------------------
    Write-Host ''
    Write-Host 'A. a relay window is recorded, with its session, name, pin and title'
    $rc = Invoke-Cli "+new-remote-window --relay=http://127.0.0.1:$RelayPort --device=$DEV --token=$TOKEN --name=$PINNED" 'open-pinned'
    Assert ($rc -eq 0) "A +new-remote-window --name=$PINNED opened the window (exit $rc; $script:lastOut)"
    Assert (Wait-LogCount $errlog1 "relay window record: registered device=$DEV session=\(pending\) name=$PINNED pinned=true" 1 10000) 'A the window was registered, pinned'
    $rec = Wait-Record { param($r) @($r | Where-Object { $_.ipc_name -eq $PINNED -and $_.session_id }).Count -ge 1 } 15000
    $mine = @($rec | Where-Object { $_.ipc_name -eq $PINNED })
    Assert ($mine.Count -eq 1) "A the record holds one entry named $PINNED (got $($mine.Count))"
    $sid = if ($mine.Count -eq 1) { [string]$mine[0].session_id } else { '' }
    Assert ($sid.Length -gt 0) "A the entry gained the pane's session id ($sid)"
    if ($mine.Count -eq 1) {
        Assert ($mine[0].device -eq $DEV -and $mine[0].relay_base -eq "http://127.0.0.1:$RelayPort") 'A it says where to dial (relay + device)'
        Assert ($mine[0].name -eq $PINNED -and $mine[0].name_pinned -eq $true) 'A it carries the caller''s name as a pin'
    }
    $rc = Invoke-Cli "+rename --target=$PINNED --title=$TITLE" 'rename'
    Assert ($rc -eq 0) "A +rename set the window title (exit $rc; $script:lastOut)"
    $rec = Wait-Record { param($r) @($r | Where-Object { $_.window_title -eq $TITLE }).Count -ge 1 } 5000
    Assert (@($rec | Where-Object { $_.window_title -eq $TITLE }).Count -eq 1) "A the title '$TITLE' is in the record"

    # --- B: a deliberate close forgets ---------------------------------------
    Write-Host ''
    Write-Host 'B. a relay window the user closes leaves the record'
    $rc = Invoke-Cli "+new-remote-window --relay=http://127.0.0.1:$RelayPort --device=$DEV --token=$TOKEN --name=$CLOSED" 'open-closed'
    Assert ($rc -eq 0) "B a second relay window opened (exit $rc)"
    $rec = Wait-Record { param($r) @($r | Where-Object { $_.ipc_name -eq $CLOSED -and $_.session_id }).Count -ge 1 } 15000
    Assert (@($rec | Where-Object { $_.ipc_name -eq $CLOSED }).Count -eq 1) 'B it was recorded'
    $rc = Invoke-Cli "+close --target=$CLOSED" 'close'
    Assert ($rc -eq 0) "B +close closed it (exit $rc; $script:lastOut)"
    $rec = Wait-Record { param($r) @($r | Where-Object { $_.ipc_name -eq $CLOSED }).Count -eq 0 } 10000
    Assert (@($rec | Where-Object { $_.ipc_name -eq $CLOSED }).Count -eq 0) 'B and it is gone from the record'
    Assert (@($rec).Count -eq 1) "B the pinned window is still recorded (entries=$(@($rec).Count))"

    # --- C: relaunch -----------------------------------------------------------
    Write-Host ''
    Write-Host 'C. the app goes away and comes back: the recorded window is re-attached'
    # Only the GUI: the far agent (a repo build too) must keep the session.
    Stop-Process -Id $app.Pid -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Assert (@(Get-Record).Count -eq 1) 'C the record survived the app going away'

    $app = Start-App $errlog2
    Start-Sleep -Seconds 2
    if ($app.Process -and $app.Process.HasExited) {
        Write-TestAssertedNothing -Reason 'the GUI died at relaunch'
    }
    $back = Wait-LogCount $errlog2 "relay window restore: reattached device=$DEV session=$sid name=$PINNED" 1 20000
    if ($NegativeControl) {
        Assert (-not $back) 'NEGATIVE CONTROL: the relaunch opened no relay window (must FAIL)'
    } else {
        Assert $back "C the window re-attached session $sid under the name $PINNED"
        Assert (Wait-LogCount $errlog2 'relay window restore: 1 of 1 window\(s\) reopened' 1 5000) 'C exactly the one recorded window (not the closed one)'
        $labels = Get-PillLabels $errlog2
        $waited = 0
        while ($waited -lt 10000 -and -not ($labels -contains $PINNED)) {
            Start-Sleep -Milliseconds 200; $waited += 200; $labels = Get-PillLabels $errlog2
        }
        Assert ($labels -contains $PINNED) "C the pill reads the pinned name '$PINNED' (labels: $($labels -join ' | '))"
        Assert (-not ($labels -contains 'ListedName')) 'C and not the directory''s name for the machine'

        $rc = Invoke-Cli '+list --json' 'list'
        $named = $false
        $titled = $false
        try {
            $j = $script:lastOut | ConvertFrom-Json
            # A debug build suffixes every title with " [DEBUG]".
            foreach ($w in @($j.data.windows | ForEach-Object { $_ })) {
                if ($w.target -eq $PINNED) {
                    $named = $true
                    if ($w.title -eq $TITLE -or $w.title -like "$TITLE [[]DEBUG]") { $titled = $true }
                }
            }
        } catch {}
        Assert $named "C +list --json finds a window named $PINNED again"
        Assert $titled "C and its title is '$TITLE' again"

        $rec = Wait-Record { param($r) @($r | Where-Object { $_.session_id -eq $sid }).Count -eq 1 } 5000
        Assert (@($rec).Count -eq 1 -and $rec[0].session_id -eq $sid) 'C the record now holds the reopened window (same session, one entry)'
    }

    Assert (-not ($app.Process -and $app.Process.HasExited)) 'the app survived the whole run'
    Assert (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) 'the run never took the user''s foreground'
    Complete-TestBody
} finally {
    Stop-FakeRelay $script:relay
    if ($null -ne $script:agent) {
        Stop-Process -Id $script:agent.Id -Force -ErrorAction SilentlyContinue
    }
    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 500)
    Remove-TestDesktop
    Remove-Item 'env:GHOSTTY_AGENT_LOCK' -ErrorAction SilentlyContinue
    Remove-Item $recordFile -ErrorAction SilentlyContinue
    if ($hadRecord) { Move-Item $recordBackup $recordFile -Force }
    Restore-GhozttyAgentLineage -Saved $savedLineage
}

# A clean green run stamps this harness's guard (T783).
if ($script:fail -eq 0 -and $script:skipped -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard relay-window-relaunch -Repo $repo 2>&1 | ForEach-Object { Write-Host "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Skipped $script:skipped
