# T1418 acceptance: a relay window's connection pill names the machine by the
# name the chooser lists it under, not by its device id.
#
# WHAT WAS WRONG. `Window.RemoteMachine.displayName` - the one naming derivation
# the pill, its tooltip and the close confirmation all speak (T1390) - answered
# the DEVICE ID for a relay machine. The friendly name lived only in the relay
# directory, which the chooser fetched and no window ever kept, so a window
# reached through the relay was labelled with a string nobody chose while the
# chooser had listed the same box as "MaximusHome" two seconds earlier. Mac
# names it `fallbackName ?? reportedHostname ?? device`; this is that order.
#
# The arms, each read from the app's own pill oracle line
# (`remote pill mode=... label=<name> w=...`, the line remote-pill.ps1 section 2
# reads) or from the rename line `adoptRelayNames` logs:
#
#   A  A CLI-OPENED window, in an app that has NOT fetched the directory this
#      run, takes the name REMEMBERED from an earlier listing. The remembered-
#      machine cache is seeded before launch and the relay is not up yet, so
#      the launch warm fails and nothing but the cache can have named it - the
#      shape of a window restored at startup, or opened by
#      `+new-remote-window --device=...`, which never sees a listing itself.
#   B  A device the cache does NOT know falls back to the hostname the agent
#      reported in its HELLO - never the device id.
#   C  A LISTING RENAMES OPEN WINDOWS. The relay comes up serving a directory
#      that renames A's device and names B's; opening the chooser fetches it,
#      and both open windows take the new names without being reopened. The
#      relay is started once and never restarted, so no link drops under the
#      windows mid-arm.
#
# NEGATIVE CONTROL: -NegativeControl asserts arm A's pill reads the DEVICE ID,
# which is the pre-fix behaviour, and MUST fail.
#
# LIMITS: the tooltip and close confirmation are not read here; they call the
# same `machineDisplayName()` the pill label does (Window.zig), which is the
# unit of the claim. The launch warm and the chooser are the listing paths
# exercised; the Activity Monitor's carousel fetch feeds the same
# `adoptRelayNames` and is not driven here.
#
#   powershell -NoProfile -File test\win32\remote-pill-relay-name.ps1
#
# Only touches ghoztty processes running from this repo's zig-out.
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [int]$AgentPort = 0,
    [int]$RelayPort = 0,
    [switch]$NegativeControl
)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\FreePort.ps1')
$AgentPort = Resolve-TestPort -Name 'agent' -Port $AgentPort
$RelayPort = Resolve-TestPort -Name 'relay' -Port $RelayPort

$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not (Test-Path $Exe)) { $Exe = Join-Path $repo 'zig-out\bin\ghoztty.exe' }
$agentExe = Join-Path (Split-Path $Exe -Parent) 'ghoztty-agent.exe'

$env:GHOZTTY_PIPE_SUFFIX = "-t1418$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\FakeRelay.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')

$script:pass = 0
$script:fail = 0
$script:skipped = 0
function Assert($cond, $name) {
    if ($cond) { Write-Host "  PASS $name"; $script:pass++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:fail++ }
}

function Stop-RepoProcesses {
    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 500)
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

# Every label the connected pill has been measured at, in log order.
function Get-PillLabels() {
    if (-not (Test-Path $errlog)) { return @() }
    return @(Select-String -Path $errlog -Pattern 'remote pill mode=connected label=(.*) w=\d+' -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Matches[0].Groups[1].Value })
}

function Wait-PillLabel([string]$label, [int]$timeoutMs) {
    $waited = 0
    while ($waited -lt $timeoutMs) {
        if ((Get-PillLabels) -contains $label) { return $true }
        Start-Sleep -Milliseconds 200
        $waited += 200
    }
    return $false
}

function Open-RelayWindow([string]$device, [string]$name) {
    $out = Join-Path $tmp "open-$name.txt"
    cmd /c "`"$Exe`" +new-remote-window --relay=http://127.0.0.1:$RelayPort --device=$device --token=$TOKEN --name=$name > `"$out`" 2>&1"
    return $LASTEXITCODE
}

$TOKEN = 'faketoken-t1418'
$DEV = 'dev-t1418-listed'
$DEV2 = 'dev-t1418-unlisted'
$NAME1 = 'PillFriendly'
$NAME1B = 'PillRenamedBox'
$NAME2 = 'Second-Machine-Name'
# The remembered list for the env-token account bucket (`""`), which is what
# `machine_cache.load` hands a window when nobody is signed in with Google.
$seedJson = '{"account":"","devices":[{"id":"' + $DEV + '","name":"' + $NAME1 + '"}]}'
$devicesJson2 = '{"devices":[' +
'{"id":"' + $DEV + '","name":"' + $NAME1B + '","hostname":"remote.local","online":true},' +
'{"id":"' + $DEV2 + '","name":"' + $NAME2 + '","online":true}]}'

$errlog = Join-Path $env:TEMP "ghoztty-t1418-stderr-$PID.log"
$relaylog = Join-Path $env:TEMP "ghoztty-t1418-relay-$PID.log"
$agentlog = Join-Path $env:TEMP "ghoztty-t1418-agent-$PID.log"
$tmp = Join-Path $env:TEMP "ghoztty-t1418-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null
# The debug build's cache file (never the release app's). Whatever an earlier
# run left there is put back afterwards.
$cacheFile = Join-Path $env:LOCALAPPDATA 'ghoztty\machines-debug.json'
$cacheBackup = Join-Path $tmp 'machines-debug.json.bak'
$hadCache = Test-Path $cacheFile
if ($hadCache) { Copy-Item $cacheFile $cacheBackup -Force }
Remove-Item $errlog, $relaylog -ErrorAction SilentlyContinue

Write-Host 'T1418 relay pill names the machine the way the chooser does'
Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null
Stop-RepoProcesses
New-TestDesktop | Out-Null

$script:agent = $null
$script:relay = $null
try {
    # --- The "other machine": a real agent on a TCP port -------------------
    if (-not (Test-Path $agentExe)) {
        Write-TestAssertedNothing -Reason "no agent binary at $agentExe"
    }
    $env:GHOSTTY_AGENT_LOCK = Join-Path $tmp 'agent.lock'
    $script:agent = Start-Process -FilePath $agentExe `
        -ArgumentList '--listen', "127.0.0.1:$AgentPort", '--headless' -PassThru -WindowStyle Hidden `
        -RedirectStandardError $agentlog
    $null = $script:agent.Handle
    Start-Sleep -Seconds 2
    if ($script:agent.HasExited) {
        Write-TestAssertedNothing -Reason 'the remote agent died at launch'
    }
    Write-Host "  OK   remote agent pid=$($script:agent.Id) on 127.0.0.1:$AgentPort"

    New-Item -ItemType Directory -Force (Split-Path $cacheFile -Parent) | Out-Null
    [System.IO.File]::WriteAllText($cacheFile, $seedJson)

    # --- The app, signed in via the env token, on the test desktop ---------
    $env:GHOSTTY_RELAY_BASE = "http://127.0.0.1:$RelayPort"
    $env:GHOSTTY_RELAY_TOKEN = $TOKEN
    $env:GHOSTTY_ACCOUNT_STORE = (Join-Path $tmp 'account.dat')
    $app = Start-OnTestDesktop -Exe $Exe `
        -Arguments @('--window-width=100', '--window-height=30', '--session-persistence=false') `
        -StdErr $errlog
    foreach ($k in 'GHOSTTY_RELAY_BASE', 'GHOSTTY_RELAY_TOKEN', 'GHOSTTY_ACCOUNT_STORE') {
        Remove-Item "env:$k" -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) {
        Write-TestAssertedNothing -Reason 'the GUI died at launch'
    }
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { Write-TestAssertedNothing -Reason 'no top window' }
    $surface = Get-TestChildWindow -Window $top -Class 'GhozttyTerminal'
    if ($surface -eq [IntPtr]::Zero) { Write-TestAssertedNothing -Reason 'no pane' }

    # Nothing is listening on the relay port yet, so the launch warm FAILS and
    # leaves the seeded cache as the only source of a name.
    $warmFailed = Wait-LogCount $errlog 'chooser directory: (quiet refresh|device list) failed' 1 15000
    Assert $warmFailed 'setup: the launch warm found no relay (the cache is all A can use)'
    Assert ((Count-LogLines $errlog 'chooser directory: fetched') -eq 0) 'setup: and fetched nothing'

    $script:relay = Start-FakeRelay -Port $RelayPort -AgentPort $AgentPort `
        -DevicesJson $devicesJson2 -LogPath $relaylog
    if (-not (Select-String -Path $relaylog -Pattern 'LISTEN' -Quiet)) {
        Write-TestAssertedNothing -Reason 'the fake relay never listened'
    }
    Write-Host "  OK   fake relay on 127.0.0.1:$RelayPort"

    # --- A: a listed device takes the directory's name ---------------------
    Write-Host ''
    Write-Host 'A. a CLI-opened window shows the REMEMBERED friendly name'
    $rc = Open-RelayWindow $DEV 'relwin1'
    Assert ($rc -eq 0) "A +new-remote-window opened the window (exit $rc)"
    if ($NegativeControl) {
        $gotA = Wait-PillLabel $DEV 10000
        Assert $gotA "NEGATIVE CONTROL: the pill reads the device id '$DEV' (must FAIL)"
    } else {
        $gotA = Wait-PillLabel $NAME1 10000
        Assert $gotA "A the pill reads '$NAME1' (labels seen: $((Get-PillLabels) -join ' | '))"
        Assert (-not ((Get-PillLabels) -contains $DEV)) 'A and never the device id'
    }

    # --- B: an unlisted device falls back to the HELLO hostname -------------
    Write-Host ''
    Write-Host 'B. a device nobody has named falls back to the machine''s own hostname'
    $rc = Open-RelayWindow $DEV2 'relwin2'
    Assert ($rc -eq 0) "B +new-remote-window opened the window (exit $rc)"
    $hostName = [System.Net.Dns]::GetHostName()
    $waited = 0
    $gotB = $false
    while ($waited -lt 10000 -and -not $gotB) {
        $gotB = [bool]((Get-PillLabels) | Where-Object { $_ -ieq $hostName })
        if (-not $gotB) { Start-Sleep -Milliseconds 200; $waited += 200 }
    }
    Assert $gotB "B the pill reads the agent's hostname '$hostName' (labels seen: $((Get-PillLabels) -join ' | '))"
    Assert (-not ((Get-PillLabels) -contains $DEV2)) 'B and never the device id'

    # --- C: a later listing renames the open windows -----------------------
    Write-Host ''
    Write-Host 'C. a new directory listing renames windows that are already open'
    $chooser = [IntPtr]::Zero
    foreach ($try in 1..3) {
        if (Send-TestKeys -Window $top -Target $surface -Modifiers ctrl, shift -Key N) {
            $chooser = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyMachineChooser' -TimeoutMs 4000
        }
        if ($chooser -ne [IntPtr]::Zero) { break }
    }
    Assert ($chooser -ne [IntPtr]::Zero) 'C ctrl+shift+n opens the chooser (which fetches the directory)'
    $ren1 = Wait-LogCount $errlog "remote machine renamed from directory device=$DEV name=$NAME1B" 1 15000
    $ren2 = Wait-LogCount $errlog "remote machine renamed from directory device=$DEV2 name=$NAME2" 1 15000
    Assert $ren1 "C the listed window is renamed to '$NAME1B'"
    Assert $ren2 "C the hostname-named window takes its new directory name '$NAME2'"
    Assert (Wait-PillLabel $NAME1B 5000) "C the first pill now reads '$NAME1B'"
    Assert (Wait-PillLabel $NAME2 5000) "C the second pill now reads '$NAME2'"
    if ($chooser -ne [IntPtr]::Zero) {
        Send-TestControlKey -Control $chooser -Key Escape | Out-Null
        Start-Sleep -Milliseconds 500
    }

    Assert (-not ($app.Process -and $app.Process.HasExited)) 'the app survived the whole run'
    Assert (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) 'the run never took the user''s foreground'
    Complete-TestBody  # T1039: the run reached the end of its body
} finally {
    Stop-FakeRelay $script:relay
    if ($null -ne $script:agent) {
        Stop-Process -Id $script:agent.Id -Force -ErrorAction SilentlyContinue
    }
    Stop-RepoProcesses
    Remove-TestDesktop
    Remove-Item 'env:GHOSTTY_AGENT_LOCK' -ErrorAction SilentlyContinue
    if ($hadCache) { Copy-Item $cacheBackup $cacheFile -Force }
    else { Remove-Item $cacheFile -ErrorAction SilentlyContinue }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Skipped $script:skipped
