# T1804 acceptance: the command palette's "Restart Ghoztty" and "Restart
# Ghoztty and Background Sessions".
#
# WHAT THIS COVERS, end to end through the palette a user types into:
#
#   R1. Restart Ghoztty, persistence ON: no question is asked; the app process
#       exits and a NEW one comes back by itself (the relaunch guard waits for the
#       exit - a copy started earlier would forward to the dying instance and
#       quit). The agent is the SAME process, every session id that was alive is
#       still alive, both named panes are back, a marker printed before the
#       restart is still in a pane's scrollback, and the relaunched app is on the
#       test desktop - never on the user's.
#   R2. Restart Ghoztty and Background Sessions, CANCEL: the confirmation comes
#       up, opens with focus on Cancel (Enter must never end work), and Escape
#       leaves the app, the agent and the sessions exactly as they were.
#   R3. Restart Ghoztty and Background Sessions, CONFIRM: the app's own agent is
#       replaced by a new pid, a STAND-IN agent (a copy of the agent binary on a
#       different path and lineage - the shape of the user's installed release) is
#       untouched with the same pid, and the app comes back.
#   R4. Restart Ghoztty, persistence OFF: it asks before closing shells (the log
#       names prompt=shells_close and the dialog is up); cancelling keeps the app.
#
# WHAT IT DOES NOT COVER. The dialog's wording and the session count in it are
# owner-drawn; they are unit-tested in every lane (src/apprt/win32/app_restart.zig)
# and the count this run produced is read from the app's decision log line.
# Taking the foreground on the user's desktop is never exercised: the whole run
# is on a background desktop, so `AllowSetForegroundWindow` there has nothing to
# grant.
#
# T218 house rules: runs on a BACKGROUND Win32 desktop, never takes the user's
# foreground, and only touches ghoztty processes from this repo's zig-out. The
# stand-in agent is a COPY under this run's temp dir, on its own lineage.
#
#   powershell -NoProfile -File test\win32\app-restart.ps1
param(
    [string]$Exe,
    [string]$AgentExe,
    [switch]$Interactive
)
$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not $Exe) { $Exe = Join-Path $repo 'zig-out\bin\ghoztty.exe' }
if (-not $AgentExe) { $AgentExe = Join-Path $repo 'zig-out\bin\ghoztty-agent.exe' }

# Isolate the IPC endpoint before any CLI call.
$env:GHOZTTY_PIPE_SUFFIX = "-apprestart$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

$root = Join-Path $env:TEMP "ghoztty-app-restart-$PID"
$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN

function Stop-TestProcs {
    # Path-exact: only zig-out ghoztty / ghoztty-agent, never the user's release.
    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 700)
}

function Out-Text($f) { if (Test-Path $f) { Get-Content $f -Raw } else { '' } }

# Every live process whose image is exactly $path.
function Get-PidsAt([string]$path) {
    $want = [IO.Path]::GetFullPath($path)
    return @(Get-CimInstance Win32_Process -Filter "Name='$([IO.Path]::GetFileName($path))'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath -and ([IO.Path]::GetFullPath($_.ExecutablePath) -ieq $want) } |
        ForEach-Object { [int]$_.ProcessId })
}

# The app pid that is not $old, once one exists (the relaunch).
function Wait-NewAppPid([int]$old, [int]$timeoutSec = 40) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $n = @(Get-PidsAt $Exe | Where-Object { $_ -ne $old })
        if ($n.Count -ge 1) { return $n[0] }
        Start-Sleep -Milliseconds 500
    }
    return 0
}

function Wait-PidGone([int]$procId, [int]$timeoutSec = 20) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        if ($null -eq (Get-Process -Id $procId -ErrorAction SilentlyContinue)) { return $true }
        Start-Sleep -Milliseconds 300
    }
    return $false
}

function Agent-Pid {
    $p = Join-Path $root 'ghoztty\local-agent-debug\port.json'
    if (-not (Test-Path $p)) { return 0 }
    try { return [int]((Get-Content $p -Raw | ConvertFrom-Json).pid) } catch { return 0 }
}

# Alive session ids from `+sessions --json`, sorted; @() on any failure.
function Alive-Ids {
    $out = (& $Exe +sessions --json 2>$null | Out-String)
    if (-not $out -or $out.Trim().Length -eq 0) { return @() }
    try { $rows = $out | ConvertFrom-Json } catch { return @() }
    return @(@($rows) | Where-Object { $_.alive -eq $true } | ForEach-Object { [string]$_.id } | Sort-Object)
}

function Wait-Listed([string]$name, [int]$timeoutSec = 30) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $out = (& $Exe +list --json 2>$null | Out-String)
        if ($out -and $out -match [regex]::Escape("`"$name`"")) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Read-Has([string]$name, [string]$marker, [int]$timeoutSec = 20) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $txt = ((& $Exe +read "--name=$name" --lines=200 2>$null | Out-String) -replace '\s', '')
        if ($txt -match [regex]::Escape($marker)) { return $true }
        Start-Sleep -Milliseconds 600
    }
    return $false
}

function Wait-VisiblePalette([int]$appPid, [int]$TimeoutMs = 5000) {
    for ($t = 0; $t -lt $TimeoutMs; $t += 200) {
        $vis = @(Get-TestWindows -ProcessId $appPid -Class 'GhozttyCommandPalette' | Where-Object { $_.Visible })
        if ($vis.Count -ge 1) { return [IntPtr]$vis[0].Hwnd }
        Start-Sleep -Milliseconds 200
    }
    return [IntPtr]::Zero
}

# Open the palette in $appPid's first window, type $filter, press Enter.
function Invoke-PaletteCommand([int]$appPid, [string]$filter) {
    $win = Wait-TestWindow -ProcessId $appPid -Class 'GhozttyWindow' -TimeoutMs 15000
    if ($win -eq [IntPtr]::Zero) { return $false }
    $pane = Get-TestChildWindow -Window $win -Class 'GhozttyTerminal'
    if ($pane -eq [IntPtr]::Zero) { return $false }
    [void](Focus-TestWindow -Window $win -Child $pane)
    foreach ($try in 1..3) {
        if (-not (Send-TestKeys -Window $win -Target $pane -Modifiers ctrl, shift -Key P)) { continue }
        $popup = Wait-VisiblePalette $appPid
        if ($popup -eq [IntPtr]::Zero) { continue }
        $edit = Find-TestWindowEx -Parent $popup -Class 'EDIT'
        if ($edit -eq [IntPtr]::Zero) { continue }
        if (-not (Send-TestControlText -Control $edit -Text $filter)) { return $false }
        Start-Sleep -Milliseconds 500
        return (Send-TestControlKey -Control $edit -Key Enter)
    }
    return $false
}

function Wait-Dialog([int]$appPid, [int]$timeoutSec = 15) {
    return Wait-TestWindow -ProcessId $appPid -Class 'GhozttyConfirmDialog' -TimeoutMs ($timeoutSec * 1000)
}

function Focused-Text([IntPtr]$dlg) {
    $f = Get-TestFocusedWindow -Window $dlg
    if ($f -eq [IntPtr]::Zero) { return '' }
    return [string](Get-TestControlText -Control $f)
}

# Tab until the focused button reads "Restart", then Enter (agent-upgrade.ps1's
# Confirm-Update: a blind Tab+Enter can land on Cancel and silently measure the
# decline path).
function Confirm-Restart([IntPtr]$dlg) {
    for ($k = 0; $k -lt 4; $k++) {
        if ((Focused-Text $dlg) -like '*Restart*') { break }
        Send-TestControlKey -Control $dlg -Key Tab | Out-Null
        Start-Sleep -Milliseconds 300
    }
    Assert ((Focused-Text $dlg) -like '*Restart*') '  (focus is on Restart before Enter)'
    return (Send-TestControlKey -Control $dlg -Key Enter)
}

function Launch-App([string[]]$launchArgs, [string]$tag) {
    $err = Join-Path $root "app-$tag.err.txt"
    # persistence: per call - R1-R3 launch with it on (the default; persistence IS
    # their subject), R4 passes --session-persistence=false explicitly.
    $a = Start-OnTestDesktop -Exe $Exe -Arguments $launchArgs -StdErr $err
    return @{ Pid = [int]$a.Pid; Err = $err }
}

function Wait-LogLine([string]$file, [string]$pattern, [int]$timeoutSec = 10) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $hit = Select-String -LiteralPath $file -Pattern $pattern -ErrorAction SilentlyContinue | Select-Object -Last 1
        if ($hit) { return $hit.Line }
        Start-Sleep -Milliseconds 300
    }
    return $null
}

Stop-TestProcs
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$relaunched = New-Object System.Collections.ArrayList

try {
    New-Item -ItemType Directory -Force (Join-Path $root 'ghoztty\local-agent-debug') | Out-Null
    $env:LOCALAPPDATA = $root
    $env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe

    Write-Host '== setup: a stand-in agent on its own path and lineage'
    $standinDir = Join-Path $root 'standin'
    New-Item -ItemType Directory -Force $standinDir | Out-Null
    $standinExe = Join-Path $standinDir 'ghoztty-agent.exe'
    Copy-Item -LiteralPath $AgentExe -Destination $standinExe -Force
    $env:GHOZTTY_AGENT_INSTANCE = "standin$PID"
    $sa = Start-OnTestDesktop -Exe $standinExe -Arguments @(
        "--listen-pipe=\\.\pipe\ghoztty-agent-standin$PID",
        "--port-file=$standinDir\port.json",
        "--sessions-file=$standinDir\sessions.json") -StdErr (Join-Path $root 'standin.err.txt')
    Remove-Item Env:\GHOZTTY_AGENT_INSTANCE -ErrorAction SilentlyContinue
    $standinPid = [int]$sa.Pid
    Start-Sleep -Seconds 2
    Assert ($null -ne (Get-Process -Id $standinPid -ErrorAction SilentlyContinue)) 'setup: the stand-in agent is running'

    Write-Host '== setup: a persistent app with two named panes and a marker'
    $a = Launch-App @('--title=t1804') 'r1'
    $appPid = $a.Pid
    $win = Wait-TestWindow -ProcessId $appPid -Class 'GhozttyWindow' -TimeoutMs 20000
    if ($win -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: launch window not found'; exit 1 }
    Assert (-not (Test-TestDesktopLeak -ProcessId $appPid)) 'setup: the app is NOT on the interactive desktop'
    & $Exe +split --direction=right --name=t1804b 2>&1 | Out-Null
    Assert (Wait-Listed 't1804b') 'setup: the second named pane exists'
    $marker = 'T1804MARK' + (Get-Random -Maximum 999999)
    # Generated text goes through --keys-file, never the native argv.
    $keys = Join-Path $root 'marker-keys.txt'
    [IO.File]::WriteAllText($keys, "echo $marker")
    & $Exe +send-keys --target=t1804b "--keys-file=$keys" Enter 2>&1 | Out-Null
    Assert (Read-Has 't1804b' $marker) 'setup: the marker is in the pane'
    # The quit flush writes the layout, but give the debounced writer a moment so
    # the split is in it whichever path wins.
    Start-Sleep -Seconds 3
    $agent0 = Agent-Pid
    $ids0 = @(Alive-Ids)
    Assert ($agent0 -gt 0) "setup: the app's agent is running (pid $agent0)"
    Assert ($ids0.Count -ge 2) "setup: at least two live sessions ($($ids0.Count))"

    Write-Host '== R1: Restart Ghoztty keeps every session'
    Assert (Invoke-PaletteCommand $appPid 'Restart Ghoztty') 'R1 chose Restart Ghoztty from the palette'
    Assert ($null -ne (Wait-LogLine $a.Err 'restart requested: kind=app persistence=true .*prompt=none')) 'R1 the app decided to ask nothing'
    Assert ((Get-TestWindow -ProcessId $appPid -Class 'GhozttyConfirmDialog') -eq [IntPtr]::Zero) 'R1 no confirmation was shown'
    Assert (Wait-PidGone $appPid) 'R1 the old app process exited'
    $app1 = Wait-NewAppPid $appPid
    Assert ($app1 -gt 0) "R1 a new app process came back by itself (pid $app1)"
    if ($app1 -gt 0) {
        [void]$relaunched.Add($app1)
        Assert ((Wait-TestWindow -ProcessId $app1 -Class 'GhozttyWindow' -TimeoutMs 20000) -ne [IntPtr]::Zero) 'R1 the relaunched app has a window on the test desktop'
        Assert (-not (Test-TestDesktopLeak -ProcessId $app1)) 'R1 the relaunched app is NOT on the interactive desktop'
    }
    Assert (Wait-Listed 't1804b') 'R1 the named pane is back'
    Assert ((Agent-Pid) -eq $agent0) 'R1 the agent is the same process'
    $ids1 = @(Alive-Ids)
    Assert ((($ids0 -join ',') -eq ($ids1 -join ','))) "R1 the same sessions are alive ($($ids1.Count))"
    Assert (Read-Has 't1804b' $marker) 'R1 the marker survived in the scrollback'

    Write-Host '== R2: Restart Ghoztty and Background Sessions, cancelled'
    Assert (Invoke-PaletteCommand $app1 'Background Sessions') 'R2 chose the agent restart from the palette'
    $dlg = Wait-Dialog $app1
    Assert ($dlg -ne [IntPtr]::Zero) 'R2 a confirmation came up'
    if ($dlg -ne [IntPtr]::Zero) {
        Start-Sleep -Milliseconds 400
        Assert ((Focused-Text $dlg) -like '*Cancel*') 'R2 the confirmation opens with focus on Cancel'
        Send-TestControlKey -Control $dlg -Key Escape | Out-Null
    }
    Start-Sleep -Seconds 2
    Assert ((Get-TestWindow -ProcessId $app1 -Class 'GhozttyConfirmDialog') -eq [IntPtr]::Zero) 'R2 Escape closed it'
    Assert ($null -ne (Get-Process -Id $app1 -ErrorAction SilentlyContinue)) 'R2 the app is still the same process'
    Assert ((Agent-Pid) -eq $agent0) 'R2 the agent is still the same process'
    Assert (((Alive-Ids) -join ',') -eq ($ids0 -join ',')) 'R2 the sessions are untouched'

    Write-Host '== R3: Restart Ghoztty and Background Sessions, confirmed'
    Assert (Invoke-PaletteCommand $app1 'Background Sessions') 'R3 chose the agent restart from the palette'
    $dlg = Wait-Dialog $app1
    Assert ($dlg -ne [IntPtr]::Zero) 'R3 a confirmation came up'
    if ($dlg -ne [IntPtr]::Zero) {
        Start-Sleep -Milliseconds 400
        [void](Confirm-Restart $dlg)
    }
    Assert (Wait-PidGone $app1) 'R3 the app exited'
    Assert (Wait-PidGone $agent0) "R3 the app's own agent (pid $agent0) was stopped"
    $app2 = Wait-NewAppPid $app1
    Assert ($app2 -gt 0) "R3 a new app process came back (pid $app2)"
    if ($app2 -gt 0) {
        [void]$relaunched.Add($app2)
        Assert ((Wait-TestWindow -ProcessId $app2 -Class 'GhozttyWindow' -TimeoutMs 20000) -ne [IntPtr]::Zero) 'R3 the relaunched app has a window'
        Assert (-not (Test-TestDesktopLeak -ProcessId $app2)) 'R3 the relaunched app is NOT on the interactive desktop'
    }
    $deadline = (Get-Date).AddSeconds(25)
    while ((Get-Date) -lt $deadline -and ((Agent-Pid) -eq 0 -or (Agent-Pid) -eq $agent0)) { Start-Sleep -Milliseconds 500 }
    $agent2 = Agent-Pid
    Assert ($agent2 -gt 0 -and $agent2 -ne $agent0) "R3 a fresh agent is running (pid $agent2)"
    Assert ($null -ne (Get-Process -Id $standinPid -ErrorAction SilentlyContinue)) "R3 the stand-in agent is untouched (pid $standinPid)"

    Write-Host '== R4: Restart Ghoztty with persistence OFF asks first'
    Stop-TestProcs
    # A fresh profile: the palette lists RECENT commands first, and R2/R3 just
    # used the agent restart, so in the same profile "Restart Ghoztty" + Enter
    # would pick that row instead (measured: the first run of this arm did).
    $env:LOCALAPPDATA = Join-Path $root 'r4'
    New-Item -ItemType Directory -Force $env:LOCALAPPDATA | Out-Null
    $b = Launch-App @('--session-persistence=false', '--title=t1804off') 'r4'
    $offPid = $b.Pid
    Assert ((Wait-TestWindow -ProcessId $offPid -Class 'GhozttyWindow' -TimeoutMs 20000) -ne [IntPtr]::Zero) 'R4 setup: the app is up'
    Start-Sleep -Seconds 2
    Assert (Invoke-PaletteCommand $offPid 'Restart Ghoztty') 'R4 chose Restart Ghoztty from the palette'
    Assert ($null -ne (Wait-LogLine $b.Err 'restart requested: kind=app persistence=false .*prompt=shells_close')) 'R4 the app decided to ask about closing shells'
    $dlg = Wait-Dialog $offPid
    Assert ($dlg -ne [IntPtr]::Zero) 'R4 a confirmation came up'
    if ($dlg -ne [IntPtr]::Zero) {
        Start-Sleep -Milliseconds 400
        Assert ((Focused-Text $dlg) -like '*Cancel*') 'R4 it opens with focus on Cancel'
        Send-TestControlKey -Control $dlg -Key Escape | Out-Null
    }
    Start-Sleep -Seconds 2
    Assert ($null -ne (Get-Process -Id $offPid -ErrorAction SilentlyContinue)) 'R4 cancelling kept the app'
    Assert ($null -ne (Wait-LogLine $b.Err 'restart cancelled by the user')) 'R4 the cancel was logged'
} catch {
    $script:fail++
    Write-Host "FAIL  script terminated: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "      at $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())"
} finally {
    Remove-TestDesktop
    Stop-TestProcs
    $env:LOCALAPPDATA = $savedLocalAppData
    if ($null -ne $savedAgentBin) { $env:GHOSTTY_LOCAL_AGENT_BIN = $savedAgentBin } else { Remove-Item Env:\GHOSTTY_LOCAL_AGENT_BIN -ErrorAction SilentlyContinue }
}

$fgSeen = @(Stop-TestForegroundWatch)
Write-Host "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    # The relaunched apps were started by the guard, not the harness, so they are
    # added to the launched set by hand: they are exactly the processes that
    # could have come up on the user's screen.
    $launched = @(@(Get-TestLaunchedPids) + @($relaunched))
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'no app of this run ever became foreground on the interactive desktop'
}

Complete-TestBody

Write-Host ''
if ($script:fail -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard app-restart -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Label 'APP RESTART'
