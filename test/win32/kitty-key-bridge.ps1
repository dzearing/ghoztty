# T2693 acceptance: a modified Enter reaches a program that asked for it in
# kitty / modifyOtherKeys form, the way it does on macOS.
#
# User report (2026-11-04): Ctrl+Enter does not "send now" in Claude Code on
# Windows; it does on Mac. Claude Code, seeing TERM_PROGRAM=ghostty, turns on
# the kitty keyboard protocol (CSI > 1 u) and modifyOtherKeys 2 (CSI > 4;2 m)
# and then reads VT bytes. Under ConPTY's Win32 Input Mode every key left
# Ghoztty as a key record and conhost flattened Ctrl+Enter to LF (0a) and
# Shift+Enter to CR (0d) - the program could not tell them from Ctrl+J and
# Enter. kitty_key_bridge.zig now sends those keys as the encoder's bytes,
# one char record each, which conhost passes through.
#
# The oracle is a raw-mode Node reader (libuv, the same console read path as
# Claude Code's Bun runtime) that sets its keys up the way Claude Code does
# and prints every byte it receives. It runs on the BACKGROUND test desktop
# (lib\TestDesktop.ps1), so nothing here takes the user's foreground
# (asserted at the end).
#
#   A. kitty on: Ctrl+Enter, Shift+Enter, Alt+Enter and Ctrl+Backspace each
#      arrive as CSI <code>;<mods> u with the right modifier bit.
#   B. Same session, controls: a plain Enter is still CR, Ctrl+J still LF and
#      Ctrl+A still 01 - the bridge only takes the keys a key record cannot
#      carry, and text / Ctrl+letter stay key records.
#   C. kitty off: Ctrl+Enter is LF again - the bridge answers the program's
#      request, it is not a blanket re-encoding.
#   D. modifyOtherKeys 2 alone: Ctrl+Enter arrives as CSI 27;<mods>;13 ~.
#
# Skips (exit 0, SKIP verdict) when node.exe is not on PATH: there is no
# raw-VT reader to read the bytes with.
#
# Only touches ghoztty processes running from this repo's zig-out*.
param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }
$env:GHOZTTY_PIPE_SUFFIX = "-kkbtest$PID"
$errlog = Join-Path $env:TEMP 'ghoztty-kitty-key-bridge-stderr.log'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\PaneLiveness.ps1')

$script:pass = 0
$script:fail = 0
$script:negReached = $false

function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

$node = Get-Command node.exe -ErrorAction SilentlyContinue
if (-not $node) {
    Write-Host 'SKIP  node.exe is not on PATH: no raw-VT reader to read the bytes with'
    Write-TestVerdict -Pass 0 -Fail 0 -Skipped 1 -Label 'KITTY KEY BRIDGE ACCEPTANCE'
}

# The reader. Mode: kitty (CSI < u, CSI > 1 u), mok (CSI > 4;2 m), none.
# Every chunk is appended to one running hex stream, so a sequence split
# across two reads still reads as one.
$probe = Join-Path $env:TEMP "kitty-key-bridge-probe-$PID.js"
Set-Content -Path $probe -Encoding ASCII -Value @(
    "const mode = process.argv[2] || 'kitty';"
    "process.stdin.setRawMode(true); process.stdin.resume();"
    "if (mode === 'kitty') process.stdout.write('\x1b[<u\x1b[>1u');"
    "if (mode === 'mok') process.stdout.write('\x1b[>4;2m');"
    "console.log('KEYPROBE READY mode=' + mode);"
    "let all = '';"
    "process.stdin.on('data', (b) => { all += Buffer.from(b).toString('hex'); console.log('KEYSTREAM ' + all); });"
)

function Stop-RepoInstances { [void](Stop-RepoGhoztty -Exe $exe -SettleMs 800) }

# Opens a named window running the reader in $mode, sends $keys (each an
# array of key + modifiers), and returns the hex stream the reader saw.
function Get-KeyStream([string]$mode, [object[]]$keys) {
    $name = "kkb$mode$PID"
    $out = Join-Path $env:TEMP "kitty-key-bridge-$mode-$PID.txt"
    $before = @(Get-TestWindows -ProcessId $app.Pid -Class 'GhozttyWindow' | ForEach-Object { [int64]$_.Hwnd })
    [void](Invoke-LivenessCli $exe "+new-window --target=$name `"--command=node.exe $probe $mode`"" $out 15)
    $top = [IntPtr]::Zero
    for ($t = 0; $t -lt 50 -and $top -eq [IntPtr]::Zero; $t++) {
        $new = @(Get-TestWindows -ProcessId $app.Pid -Class 'GhozttyWindow' |
            Where-Object { $before -notcontains [int64]$_.Hwnd })
        if ($new.Count -ge 1) { $top = [IntPtr]$new[0].Hwnd } else { Start-Sleep -Milliseconds 100 }
    }
    if ($top -eq [IntPtr]::Zero) { Write-Host "INFO  $mode window never opened"; return $null }
    $panes = @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal')
    if ($panes.Count -lt 1) { Write-Host "INFO  $mode window has no pane"; return $null }
    $pane = [IntPtr]$panes[0].Hwnd
    $read = {
        if ((Invoke-LivenessCli $exe "+read --name=$name --lines=200" $out 12) -ne 0) { return '' }
        try { return [string](Get-Content $out -Raw) } catch { return '' }
    }
    $txt = ''
    for ($t = 0; $t -lt 40 -and $txt -notmatch 'KEYPROBE READY'; $t++) {
        $txt = & $read; if ($txt -notmatch 'KEYPROBE READY') { Start-Sleep -Milliseconds 300 }
    }
    if ($txt -notmatch 'KEYPROBE READY') { Write-Host "INFO  $mode reader never started: $(($txt).Trim())"; return $null }
    foreach ($k in $keys) {
        $ok = if ($k[1]) { Send-TestKeys -Window $top -Target $pane -Key $k[0] -Modifiers $k[1] }
              else { Send-TestKeys -Window $top -Target $pane -Key $k[0] }
        if (-not $ok) { Write-Host "INFO  $mode could not deliver $($k -join '+')" }
        Start-Sleep -Milliseconds 400
    }
    # The stream is complete once it stops growing.
    $last = ''; $stream = ''
    for ($t = 0; $t -lt 20; $t++) {
        Start-Sleep -Milliseconds 400
        $txt = & $read
        $m = [regex]::Matches($txt, 'KEYSTREAM ([0-9a-f]+)')
        if ($m.Count -gt 0) { $stream = $m[$m.Count - 1].Groups[1].Value }
        if ($stream -and $stream -eq $last) { break }
        $last = $stream
    }
    Write-Host "INFO  $mode stream: $stream"
    Write-Host "INFO  $mode pane: $((($txt -split "`n") | Where-Object { $_.Trim() } | Select-Object -Last 4) -join ' | ')"
    return $stream
}

# Hex of an ASCII string, the way the reader prints bytes.
function Hex([string]$s) { return (-join ([Text.Encoding]::ASCII.GetBytes($s) | ForEach-Object { $_.ToString('x2') })) }

# The modifier field of the first CSI <code> ; <mods> u in the stream, or -1.
function Get-CsiUMods([string]$stream, [int]$code) {
    $text = -join ($(for ($i = 0; $i -lt $stream.Length; $i += 2) { [char][Convert]::ToInt32($stream.Substring($i, 2), 16) }))
    $m = [regex]::Match($text, "\x1b\[$code;(\d+)u")
    if (-not $m.Success) { return -1 }
    return [int]$m.Groups[1].Value
}

function Test-Bit([int]$mods, [int]$bit) { return ($mods -gt 0) -and ((($mods - 1) -band $bit) -ne 0) }

Stop-RepoInstances
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$launched = @()
$app = $null

try {
    if ($NegativeControl) {
        Write-Host 'NEGATIVE CONTROL: section A expects Ctrl+Enter WITHOUT its ctrl bit - this run MUST fail'
    }
    Remove-Item $errlog -ErrorAction SilentlyContinue
    $app = Start-OnTestDesktop -Exe $exe -Arguments @('--session-persistence=false') -StdErr $errlog
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $launched += $script:GhozttyTestDesktopPids
    $top0 = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top0 -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: top window not found'; exit 1 }
    Assert (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) 'window is NOT enumerable on the interactive desktop'

    # -----------------------------------------------------------------------
    # A + B. kitty on.
    # -----------------------------------------------------------------------
    $s = Get-KeyStream 'kitty' @(
        @('Enter', 'ctrl'), @('Enter', 'shift'), @('Enter', 'alt'), @('Backspace', 'ctrl'),
        @('Enter', ''), @('J', 'ctrl'), @('A', 'ctrl'))
    Assert ($null -ne $s) 'A: setup: the kitty reader read keys'
    if ($null -ne $s) {
        # The 13;N u forms in send order: ctrl, shift, alt.
        $text = -join ($(for ($i = 0; $i -lt $s.Length; $i += 2) { [char][Convert]::ToInt32($s.Substring($i, 2), 16) }))
        $enters = @([regex]::Matches($text, "\x1b\[13;(\d+)u") | ForEach-Object { [int]$_.Groups[1].Value })
        Assert ($enters.Count -eq 3) "A: three modified Enters arrived as CSI 13;N u (saw $($enters.Count))"
        $ctrlOk = ($enters.Count -ge 1) -and (Test-Bit $enters[0] 4)
        $ctrlLabel = "A: Ctrl+Enter carries the ctrl bit (mods=$(if ($enters.Count -ge 1) { $enters[0] } else { 'none' }))"
        if ($NegativeControl) { $ctrlOk = -not $ctrlOk; $ctrlLabel += ' [NEGATED]'; $script:negReached = $true }
        Assert $ctrlOk $ctrlLabel
        Assert (($enters.Count -ge 2) -and (Test-Bit $enters[1] 1) -and -not (Test-Bit $enters[1] 4)) 'A: Shift+Enter carries shift and not ctrl'
        Assert (($enters.Count -ge 3) -and (Test-Bit $enters[2] 2)) 'A: Alt+Enter carries alt'
        Assert (Test-Bit (Get-CsiUMods $s 127) 4) 'A: Ctrl+Backspace arrived as CSI 127;N u with ctrl'
        # B. After the CSI-u run: CR (plain Enter), LF (Ctrl+J), 01 (Ctrl+A).
        Assert ($s.EndsWith('0d0a01')) "B: plain Enter, Ctrl+J and Ctrl+A still arrive as 0d 0a 01 (tail $($s.Substring([math]::Max(0, $s.Length - 12))))"
        # Before that tail, no bare LF or CR: no modified Enter fell back to
        # its flattened byte.
        $head = $text.Substring(0, [math]::Max(0, $text.Length - 3))
        Assert (-not ($head.Contains([string][char]0x0a) -or $head.Contains([string][char]0x0d))) 'B: no modified Enter leaked out as a bare LF or CR'
    }

    # -----------------------------------------------------------------------
    # D. modifyOtherKeys 2 alone.
    # -----------------------------------------------------------------------
    $s = Get-KeyStream 'mok' @(,@('Enter', 'ctrl'))  # unary comma: a lone inner array would unroll into two strings
    Assert ($null -ne $s) 'D: setup: the modifyOtherKeys reader read keys'
    if ($null -ne $s) {
        $text = -join ($(for ($i = 0; $i -lt $s.Length; $i += 2) { [char][Convert]::ToInt32($s.Substring($i, 2), 16) }))
        $m = [regex]::Match($text, "\x1b\[27;(\d+);13~")
        Assert ($m.Success -and (Test-Bit ([int]$m.Groups[1].Value) 4)) "D: Ctrl+Enter arrived as CSI 27;N;13~ with ctrl (saw $s)"
    }

    # -----------------------------------------------------------------------
    # C. kitty off: the old bytes.
    # -----------------------------------------------------------------------
    $s = Get-KeyStream 'none' @(@('Enter', 'ctrl'), @('Enter', 'shift'))
    Assert ($null -ne $s) 'C: setup: the plain reader read keys'
    if ($null -ne $s) {
        Assert ($s -eq '0a0d') "C: with nothing asked for, Ctrl+Enter / Shift+Enter stay LF / CR (saw $s)"
    }

    Assert (-not ($app.Process -and $app.Process.HasExited)) 'no crash'
} catch {
    Write-Host "ERROR $_" -ForegroundColor Red
    $script:fail++
} finally {
    if ($app) { Stop-Process -Id $app.Pid -Force -ErrorAction SilentlyContinue }
    Remove-TestDesktop
    Stop-RepoInstances
    Remove-Item $probe -ErrorAction SilentlyContinue
}

$fgSeen = @(Stop-TestForegroundWatch)
Write-Host "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @($launched | Select-Object -Unique)
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) "no test-desktop app ever became foreground on the interactive desktop (saw $($leaked -join ','))"
}

if ($NegativeControl -and -not $script:negReached) {
    Assert $false 'NEGATIVE CONTROL never reached its inverted assertion'
}

Complete-TestBody
if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard kitty-key-bridge -Repo $repo 2>&1 | ForEach-Object { Write-Host "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Label 'KITTY KEY BRIDGE ACCEPTANCE'
