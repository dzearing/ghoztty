# T2686 acceptance: Settings > Remote Machines lists the account and every
# enrolled machine with a live presence dot and its host defaults, and opens
# Host Settings... and New Remote Window... from the page - Mac's
# RemoteMachinesSection (macos/Sources/Features/Settings/
# SettingsStatusSections.swift).
#
#   A. read without blocking: with the relay HELD (it answers nothing until
#      this script releases it), opening the page already shows the signed-in
#      account and the REMEMBERED machine from the device cache, drawn
#      "checking", with its stored folder and shell - and the fetch that will
#      confirm it is still out. The IPC answer arriving at all while the fetch
#      is held is the proof the GUI thread never waited on the network.
#   B. presence lands: released, the relay's answer replaces the seed - the
#      remembered machine online, a second machine offline with
#      "remote default" for both defaults.
#   C. the page paints New Remote Window... and one Host Settings... per row.
#   D. Host Settings... opens the chooser's own editor for THAT machine;
#      saving writes the store keyed on the device id, and the row's caption
#      re-reads it (Mac's settingsRevision bump).
#   E. New Remote Window... opens the machine chooser.
#
# THE ORACLE IS THE MODEL AND THE STORE: the rows are read through the
# debug-only `settings` IPC action (`live.remote`, src/apprt/win32/
# ipc_settings.zig), the store file is read directly, and the dialog/chooser
# are found as real top-level windows of the app.
#
# Isolation: the IPC endpoint is keyed on $PID; the account store, host
# defaults store and config live in a temp dir; the DEBUG device cache
# (%LOCALAPPDATA%\ghoztty\machines-debug.json) is backed up and restored; the
# relay is a loopback listener on a port drawn free a moment ago. Runs on the
# BACKGROUND test desktop (lib\TestDesktop.ps1), so it never takes the user's
# foreground.
#
# -NegativeControl inverts B's claim that the second machine reads offline -
# that run MUST fail.
#
# Only touches ghoztty processes running from this repo's zig-out*.
param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive, [int]$DirPort = 0)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }
$env:GHOZTTY_PIPE_SUFFIX = "-setremote$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\PaneCapture.ps1')   # Invoke-GhozttyIpc
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
. (Join-Path $PSScriptRoot 'lib\AgentLineage.ps1')
. (Join-Path $PSScriptRoot 'lib\FreePort.ps1')
Add-Type -AssemblyName System.Security

[void](Assert-GhozttyIsolatedBuild -Exe $exe)

$script:pass = 0
$script:fail = 0
$script:skipped = 0
$script:negReached = $false

function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Invoke-Settings([string[]]$ipcArgs) {
    return Invoke-GhozttyIpc -Action 'settings' -Arguments $ipcArgs
}

function Get-Remote($s) { return $s.data.live.remote }

function Find-Machine($rm, [string]$id) {
    foreach ($m in @($rm.machines)) { if ([string]$m.id -eq $id) { return $m } }
    return $null
}

# The caption words, built from code points so this file stays ASCII.
$ell = [string][char]0x2026
$dot = ' ' + [char]0x00B7 + ' '
function Caption([string]$presence, [string]$wd, [string]$shell) {
    return $presence + $dot + 'folder: ' + $wd + $dot + 'shell: ' + $shell
}

$work = Join-Path $env:TEMP "ghoztty-setremote-$PID"
$cfgHome = Join-Path $work 'xdg'
New-Item -ItemType Directory -Force -Path (Join-Path $cfgHome 'ghostty') | Out-Null
[System.IO.File]::WriteAllText((Join-Path $cfgHome 'ghostty\config-debug.ghostty'), "font-size = 13`n")
$storeFile = Join-Path $work 'host_defaults.json'
$gateFile = Join-Path $work 'release.gate'
$hitFile = Join-Path $work 'hits.txt'
$errlog = Join-Path $work 'stderr.log'

# --- the signed-in account (DPAPI, the T93 store shape) ----------------------
$Email = 't2686@example.com'
$AccountStore = Join-Path $work 'account.dat'
$DirPort = Resolve-TestPort -Name 'relay' -Port $DirPort
$exp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 3600
$acct = '{"session_token":"sess-t2686","expiry":' + $exp + ',"email":"' + $Email + '","relay_base":"http://127.0.0.1:' + $DirPort + '"}'
[IO.File]::WriteAllBytes($AccountStore, [Security.Cryptography.ProtectedData]::Protect(
    [Text.Encoding]::UTF8.GetBytes($acct), $null, 'CurrentUser'))

# --- the remembered machine (the DEBUG cache, backed up) ---------------------
$cacheDir = Join-Path $env:LOCALAPPDATA 'ghoztty'
$cachePath = Join-Path $cacheDir 'machines-debug.json'
$cacheBackup = Join-Path $work 'machines-debug.json.bak'
$hadCache = Test-Path $cachePath
if ($hadCache) { Copy-Item $cachePath $cacheBackup -Force }
New-Item -ItemType Directory -Force $cacheDir | Out-Null
[IO.File]::WriteAllText($cachePath,
    '{"account":"' + $Email + '","devices":[{"id":"t2686-a","name":"Alphabox","hostname":"alpha.local"}]}',
    (New-Object Text.UTF8Encoding $false))

# --- its stored host defaults (no BOM: a BOM reads as an empty store) --------
[IO.File]::WriteAllText($storeFile,
    '{"hosts":[{"key":"t2686-a","working_directory":"~/src","shell":"zsh"}]}',
    (New-Object Text.UTF8Encoding $false))

# --- the relay: HELD until the gate file exists ------------------------------
$dirJob = Start-Job -ScriptBlock {
    param($port, $hitFile, $gateFile)
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port)
    $listener.Start()
    $body = '{"devices":[{"id":"t2686-a","name":"Alphabox","hostname":"alpha.local","online":true},' +
        '{"id":"t2686-b","name":"Betabox","hostname":"beta.local","online":false}]}'
    while ($true) {
        if (-not $listener.Pending()) { Start-Sleep -Milliseconds 25; continue }
        $client = $listener.AcceptTcpClient()
        try {
            $stream = $client.GetStream()
            $sb = New-Object Text.StringBuilder
            $buf = New-Object byte[] 16384
            for ($i = 0; $i -lt 40; $i++) {
                if ($stream.DataAvailable) {
                    $n = $stream.Read($buf, 0, $buf.Length)
                    [void]$sb.Append([Text.Encoding]::UTF8.GetString($buf, 0, $n))
                    if ($sb.ToString() -match "`r`n`r`n") { break }
                }
                Start-Sleep -Milliseconds 25
            }
            Add-Content -Path $hitFile -Value (($sb.ToString() -split "`r`n")[0])
            # Held: the GUI must already be showing the seed by now.
            for ($w = 0; $w -lt 1200 -and -not (Test-Path $gateFile); $w++) { Start-Sleep -Milliseconds 25 }
            $payload = [Text.Encoding]::UTF8.GetBytes($body)
            $head = "HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: $($payload.Length)`r`nConnection: close`r`n`r`n"
            $bytes = [Text.Encoding]::UTF8.GetBytes($head) + $payload
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush()
        } catch {}
        $client.Close()
    }
} -ArgumentList $DirPort, $hitFile, $gateFile

$dirUp = $false
for ($t = 0; $t -lt 40 -and -not $dirUp; $t++) {
    try {
        $probe = New-Object Net.Sockets.TcpClient
        $probe.Connect('127.0.0.1', $DirPort)
        $dirUp = $probe.Connected
        $probe.Close()
    } catch { Start-Sleep -Milliseconds 250 }
}
# The probe connection above was a request too; let it through and forget it.
New-Item -ItemType File -Force $gateFile | Out-Null
Start-Sleep -Milliseconds 300
Remove-Item $gateFile -Force -ErrorAction SilentlyContinue
Remove-Item $hitFile -Force -ErrorAction SilentlyContinue

$script:launched = @()
$app = $null
[void](Set-GhozttyTestAgentLineage -Tag 'setremote' -Quiet)
[void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    if (-not $dirUp) {
        Write-TestAssertedNothing -Reason "the fake relay never came up on port $DirPort" -Label 'settings-remote-machines'
        exit 1
    }
    if ($NegativeControl) {
        Write-Host "NEGATIVE CONTROL: section B asserts Betabox reads ONLINE - this run MUST fail"
    }
    $env:XDG_CONFIG_HOME = $cfgHome
    $env:GHOSTTY_ACCOUNT_STORE = $AccountStore
    $env:GHOSTTY_RELAY_BASE = "http://127.0.0.1:$DirPort"
    $env:GHOSTTY_HOST_DEFAULTS = $storeFile
    $env:GHOZTTY_UPDATE_URL = 'http://127.0.0.1:9/releases'
    try {
        $sp = @{ Exe = $exe; Arguments = @('--session-persistence=false', '--background=#101014') }
        if (-not $ExePath) { $sp.StdErr = $errlog }
        $app = Start-OnTestDesktop @sp
    } finally {
        foreach ($k in 'XDG_CONFIG_HOME', 'GHOSTTY_ACCOUNT_STORE', 'GHOSTTY_RELAY_BASE', 'GHOSTTY_HOST_DEFAULTS', 'GHOZTTY_UPDATE_URL') {
            Remove-Item "Env:$k" -ErrorAction SilentlyContinue
        }
    }
    Start-Sleep -Seconds 3
    if (-not $app -or ($app.Process -and $app.Process.HasExited)) {
        Write-TestAssertedNothing -Reason 'GUI did not come up' -Label 'settings-remote-machines'
        exit 1
    }
    $script:launched += $script:GhozttyTestDesktopPids
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) {
        Write-TestAssertedNothing -Reason 'no terminal window appeared' -Label 'settings-remote-machines'
        exit 1
    }
    # The launch warm is a directory fetch too; let it through, then hold
    # the relay again for the page's own.
    New-Item -ItemType File -Force $gateFile | Out-Null
    Start-Sleep -Milliseconds 1500
    Remove-Item $gateFile -Force -ErrorAction SilentlyContinue
    # The warm rewrote the cache with both machines; put the one-machine
    # seed back so A can tell a seed from an answer.
    [IO.File]::WriteAllText($cachePath,
        '{"account":"' + $Email + '","devices":[{"id":"t2686-a","name":"Alphabox","hostname":"alpha.local"}]}',
        (New-Object Text.UTF8Encoding $false))
    $hitsBefore = if (Test-Path $hitFile) { @(Get-Content $hitFile).Count } else { 0 }

    # =====================================================================
    # A: seeded from the cache, with the relay held
    # =====================================================================
    [void](Invoke-Settings @('--op=action'))
    $s = Invoke-Settings @('--op=state', '--page=remote')
    $rm = Get-Remote $s
    Assert ($null -ne $rm -and [bool]$rm.snapped) "A: the page read its rows (snapped=$($rm.snapped))"
    Assert ([string]$rm.account -eq 'signed_in' -and [string]$rm.title -eq "Signed in as $Email") "A: the account reads as Mac's ('$($rm.title)')"
    Assert ([string]$rm.caption -eq 'Machines enrolled in your account appear below.') "A: ...with Mac's caption ('$($rm.caption)')"
    $ms = @($rm.machines)
    $a = Find-Machine $rm 't2686-a'
    Assert ($ms.Count -eq 1 -and $a -and [string]$a.name -eq 'Alphabox') "A: the remembered machine is listed before any answer ($($ms.Count): $(($ms | ForEach-Object { $_.name }) -join ','))"
    Assert ($a -and [string]$a.presence -eq 'checking' -and [string]$a.caption -eq (Caption ('checking' + $ell) '~/src' 'zsh')) "A: ...drawn checking, with its stored folder and shell ('$($a.caption)')"
    Assert ([bool]$rm.fetching -and -not [bool]$rm.fetched) "A: ...while the presence fetch is still held (fetching=$($rm.fetching) fetched=$($rm.fetched))"
    $hitsNow = if (Test-Path $hitFile) { @(Get-Content $hitFile).Count } else { 0 }
    Assert ($hitsNow -gt $hitsBefore) "A: the page asked the relay ($hitsBefore -> $hitsNow requests)"

    # =====================================================================
    # B: the relay answers
    # =====================================================================
    New-Item -ItemType File -Force $gateFile | Out-Null
    $deadline = (Get-Date).AddSeconds(15)
    do {
        Start-Sleep -Milliseconds 250
        $rm = Get-Remote (Invoke-Settings @('--op=state'))
    } while (-not [bool]$rm.fetched -and (Get-Date) -lt $deadline)
    Assert ([bool]$rm.fetched -and -not [bool]$rm.fetching) "B: the presence fetch landed (fetched=$($rm.fetched))"
    $a = Find-Machine $rm 't2686-a'
    $b = Find-Machine $rm 't2686-b'
    Assert ($a -and [string]$a.presence -eq 'online' -and [string]$a.caption -eq (Caption 'online' '~/src' 'zsh')) "B: Alphabox reads online with its defaults ('$($a.caption)')"
    $wantB = 'offline'
    if ($NegativeControl) { $wantB = 'online'; $script:negReached = $true }
    Assert ($b -and [string]$b.presence -eq $wantB -and [string]$b.caption -eq (Caption $wantB 'remote default' 'remote default')) "B: Betabox appears $wantB with remote defaults ('$($b.caption)')"

    # =====================================================================
    # C: the painted affordances
    # =====================================================================
    $shot = Join-Path $work 'remote.png'
    $s = Invoke-Settings @('--op=shot', "--path=$shot")
    $nrw = @($s.data.hits | Where-Object { $_.kind -eq 'new_remote_window' })
    $hs = @($s.data.hits | Where-Object { $_.kind -eq 'host_settings' } | ForEach-Object { [string]$_.key })
    Assert ($nrw.Count -eq 1) "C: New Remote Window... is painted ($($nrw.Count))"
    Assert ($hs.Count -eq 2 -and ($hs -contains 't2686-a') -and ($hs -contains 't2686-b')) "C: one Host Settings... per machine ($($hs -join ','))"

    # =====================================================================
    # D: Host Settings... for Betabox
    # =====================================================================
    $s = Invoke-Settings @('--op=click', '--value=host_settings:t2686-b')
    Assert ([bool]$s.data.ok) 'D: the click lands on Betabox''s button'
    $dlg = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyHostSettings' -TimeoutMs 4000
    Assert ($dlg -ne [IntPtr]::Zero) 'D: it opens the Host Settings editor'
    if ($dlg -ne [IntPtr]::Zero) {
        $caption = Get-TestControlText -Control $dlg
        Assert ($caption -like '*Betabox*') "D: ...for Betabox ('$caption')"
        $focus = Get-TestFocusedWindow -Window $dlg
        $target = if ($focus -ne 0) { [IntPtr]$focus } else { $dlg }
        [void](Send-TestControlText -Control $target -Text '~/work')
        Start-Sleep -Milliseconds 150
        [void](Send-TestControlKey -Control $target -Key Tab)
        Start-Sleep -Milliseconds 150
        $focus = Get-TestFocusedWindow -Window $dlg
        $target = if ($focus -ne 0) { [IntPtr]$focus } else { $dlg }
        [void](Send-TestControlText -Control $target -Text 'fish')
        Start-Sleep -Milliseconds 150
        [void](Send-TestControlKey -Control $target -Key Enter)
        Start-Sleep -Milliseconds 800
        Assert (-not (Test-TestWindowExists -Window $dlg)) 'D: Enter saves and closes it'
        $store = if (Test-Path $storeFile) { Get-Content $storeFile -Raw } else { '' }
        Assert ($store -match '"key"\s*:\s*"t2686-b"' -and $store -match '"shell"\s*:\s*"fish"' -and $store -match '"working_directory"\s*:\s*"~/work"') 'D: the store holds Betabox''s defaults under its device id'
        Assert ($store -match '"key"\s*:\s*"t2686-a"') 'D: ...and kept Alphabox''s'
        $b = Find-Machine (Get-Remote (Invoke-Settings @('--op=state'))) 't2686-b'
        Assert ($b -and [string]$b.caption -eq (Caption 'offline' '~/work' 'fish')) "D: Betabox's row re-reads them ('$($b.caption)')"
    }

    # =====================================================================
    # E: New Remote Window...
    # =====================================================================
    [void](Invoke-Settings @('--op=shot', "--path=$shot"))
    $s = Invoke-Settings @('--op=click', '--value=new_remote_window')
    Assert ([bool]$s.data.ok) 'E: the click lands on New Remote Window...'
    $ch = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyMachineChooser' -TimeoutMs 5000
    Assert ($ch -ne [IntPtr]::Zero) 'E: it opens the machine chooser'
    if ($ch -ne [IntPtr]::Zero) {
        [void](Send-TestControlKey -Control $ch -Key Escape)
        Start-Sleep -Milliseconds 400
    }

    [void](Invoke-Settings @('--op=close'))
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'no crash'
    Complete-TestBody
} catch {
    Write-Host "ERROR $_" -ForegroundColor Red
    $script:fail++
} finally {
    if ($app) { Stop-Process -Id $app.Pid -Force -ErrorAction SilentlyContinue }
    Remove-TestDesktop
    [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
    Stop-Job $dirJob -ErrorAction SilentlyContinue | Out-Null
    Remove-Job $dirJob -Force -ErrorAction SilentlyContinue | Out-Null
    if ($hadCache) { Copy-Item $cacheBackup $cachePath -Force }
    else { Remove-Item $cachePath -Force -ErrorAction SilentlyContinue }
    if ($env:GHOZTTY_SETTINGS_SHOTS -and (Test-Path $work)) {
        New-Item -ItemType Directory -Force -Path $env:GHOZTTY_SETTINGS_SHOTS | Out-Null
        Copy-Item -Path (Join-Path $work '*.png') -Destination $env:GHOZTTY_SETTINGS_SHOTS -Force -ErrorAction SilentlyContinue
    }
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}

$fgSeen = @(Stop-TestForegroundWatch)
Write-Host "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $script:launched = @($script:launched | Select-Object -Unique)
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    $leaked = @($script:launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) "no test-desktop app ever became foreground on the interactive desktop (saw $($leaked -join ','))"
}

if ($NegativeControl -and -not $script:negReached) {
    Assert $false 'NEGATIVE CONTROL never reached its inverted assertion'
}

# --- stamp (T783) ---------------------------------------------------------
if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard settings-remote-machines -Repo $repo 2>&1 | ForEach-Object { Write-Host "  $_" }
}

Write-TestVerdict -Pass $script:pass -Fail $script:fail -Skipped $script:skipped -Label 'settings-remote-machines'
