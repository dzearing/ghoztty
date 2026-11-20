# @timing-sensitive
# T3004 acceptance: clearing a pane's scrollback gives its memory back.
#
# WHY. PA-M04 (perf audit 1, T2961): a pane that filled its 10 MB scrollback
# kept every page of it after a clear. Destroying a page zeroed it and parked
# it on the pool's free list, and only a full terminal reset (RIS) or closing
# the pane shrank the pool - so ten panes that each ran one noisy build held
# 100+ MB nobody could see. Since T3003 every standard page on Windows is its
# own allocation; T3004 hands a destroyed page past a one-page reserve back
# to the OS instead of zeroing and keeping it.
#
# HOW. One app, one pane, on the hidden test desktop. Settle and sample
# (BASE); `type` a generated file long enough to push the pane to its
# scrollback limit, wait for its end marker in `+read`, settle and sample
# (FULL); press ctrl+k (clear_screen: screen + scrollback), settle and
# sample (CLEARED).
#
#   A1  filling the scrollback grew private bytes by >= 8 MB (the meter sees
#       the scrollback at all - the precondition for A2 meaning anything)
#   A2  the clear gave back >= 8 MB of it (FULL - CLEARED)
#   A3  the pane still works afterwards: a fresh marker echoes and reads back
#   B1  the app survived; B2 the GUI never showed on the interactive desktop
#
# -NegativeControl skips the ctrl+k. A2 MUST go red: the proof that the
# meter can tell a cleared scrollback from a kept one.
#
# Only touches ghoztty processes running from this repo's zig-out*.
#   powershell -NoProfile -File test\win32\scrollback-clear-memory.ps1
param(
    [string]$ExePath,
    [int]$Lines = 40000,
    [switch]$NegativeControl,
    [switch]$Interactive)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }
if (-not (Test-Path $exe)) { Write-Host "FAIL  no build at $exe"; exit 1 }

$env:GHOZTTY_PIPE_SUFFIX = "-sbclearmem$PID"
$errlog = Join-Path $env:TEMP "ghoztty-scrollback-clear-memory-$PID.log"
$tmp = Join-Path $env:TEMP "ghoztty-t3004-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\ProcessMemory.ps1')

# T1511: arms the run, so an unwound body neither prints a pass nor stamps.
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Invoke-Verb([string[]]$VerbArgs) {
    $out = @(& $exe @VerbArgs 2>&1 | ForEach-Object { "$_" }) -join "`n"
    return [pscustomobject]@{ Code = $LASTEXITCODE; Text = $out.Trim() }
}

function Get-PaneId {
    $r = Invoke-Verb @('+list', '--json')
    if ($r.Code -ne 0 -or [string]::IsNullOrWhiteSpace($r.Text)) { return $null }
    $m = [regex]::Match($r.Text, '"id"\s*:\s*"([^"]+)"[^{}]*"pid"')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

function Wait-Marker([string]$Pane, [string]$Marker, [int]$TimeoutSec) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        $r = Invoke-Verb @('+read', "--name=$Pane", '--lines=6')
        if ($r.Code -eq 0 -and $r.Text -match [regex]::Escape($Marker)) { return $true }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    return $false
}

# Settled private bytes: Wait-Settled, then the lowest of three readings a
# second apart, so a transient allocation in flight is not read as kept.
function Get-SettledPriv([int]$ProcessId, [string]$Label) {
    $s = Wait-Settled $ProcessId $Label
    $min = $s.PrivMB
    for ($i = 0; $i -lt 3; $i++) {
        Start-Sleep -Milliseconds 1000
        $x = Get-Sample $ProcessId $Label
        if ($x.PrivMB -lt $min) { $min = $x.PrivMB }
    }
    return [math]::Round($min, 1)
}

# Long distinct lines (no repeats the renderer could dedupe, no wide glyphs),
# ending in a marker that only appears once the whole file has been typed.
$fill = Join-Path $tmp 'fill.txt'
$endMarker = "T3004-FILL-END-$PID"
$sb = New-Object System.Text.StringBuilder
for ($i = 1; $i -le $Lines; $i++) {
    [void]$sb.Append(('{0:D6} ' -f $i)).Append(('abcdefghij' * 9)).Append("`r`n")
}
[void]$sb.Append($endMarker).Append("`r`n")
[IO.File]::WriteAllText($fill, $sb.ToString(), (New-Object System.Text.ASCIIEncoding))

[void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$app = $null

try {
    $launchArgs = @('--config-default-files=false', '--session-persistence=false', '--confirm-close-surface=false')
    $app = Start-OnTestDesktop -Exe $exe -StdErr $errlog -Arguments $launchArgs
    $appPid = $app.Pid
    Assert (-not (Test-TestDesktopLeak -ProcessId $appPid)) 'GUI is NOT enumerable on the interactive desktop'
    $top = Wait-TestWindow -ProcessId $appPid -Class 'GhozttyWindow' -TimeoutMs 20000
    if ($top -eq [IntPtr]::Zero) { throw 'no window' }
    [void](Set-TestWindowPos -Window ([IntPtr]$top) -X 40 -Y 40 -Width 1000 -Height 700)

    $pane = $null
    $deadline = (Get-Date).AddSeconds(15)
    do { $pane = Get-PaneId; if ($pane) { break }; Start-Sleep -Milliseconds 300 } while ((Get-Date) -lt $deadline)
    if (-not $pane) { throw 'no pane listed' }
    Start-Sleep -Seconds 2

    $base = Get-SettledPriv $appPid 'base'
    $r = Invoke-Verb @('+send-keys', "--target=$pane", "type `"$fill`"", 'Enter')
    if ($r.Code -ne 0) { throw "+send-keys type failed: $($r.Text)" }
    $typed = Wait-Marker $pane $endMarker 240
    Assert $typed 'the fill file was typed to its end marker'
    if (-not $typed) { throw 'fill never finished' }
    $full = Get-SettledPriv $appPid 'full'

    if (-not $NegativeControl) {
        $panes = @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal' | Where-Object { $_.Visible -and $_.Width -gt 0 })
        if ($panes.Count -lt 1) { throw 'no terminal pane window to send ctrl+k to' }
        $h = [IntPtr][int64]$panes[0].Hwnd
        $f = Focus-TestWindow -Window $top -Child $h
        $k = Send-TestKeys -Window $top -Target $h -Modifiers ctrl -Key K
        Assert ($f -and $k) "ctrl+k was delivered (focus=$f keys=$k)"
    }
    Start-Sleep -Seconds 2
    $cleared = Get-SettledPriv $appPid 'cleared'

    $grew = [math]::Round($full - $base, 1)
    $gave = [math]::Round($full - $cleared, 1)
    Write-Host ''
    Write-Host ("private MB: base {0}  full {1}  cleared {2}  (fill +{3}, clear -{4})" -f $base, $full, $cleared, $grew, $gave)
    Assert ($grew -ge 8) "A1 filling the scrollback grew private bytes by >= 8 MB (+$grew MB)"
    Assert ($gave -ge 8) "A2 clearing the scrollback gave back >= 8 MB (-$gave MB)"

    # The marker lives only in the file, never on the typed command line, so
    # the shell's echo of the command cannot satisfy the wait (T1143).
    $after = "T3004-AFTER-$PID"
    $afterFile = Join-Path $tmp 'after.txt'
    [IO.File]::WriteAllText($afterFile, "$after`r`n", (New-Object System.Text.ASCIIEncoding))
    $r = Invoke-Verb @('+send-keys', "--target=$pane", "type `"$afterFile`"", 'Enter')
    Assert ($r.Code -eq 0 -and (Wait-Marker $pane $after 20)) 'A3 the pane still runs a command and reads back its output after the clear'
    Assert ($null -ne (Get-Process -Id $appPid -ErrorAction SilentlyContinue)) 'B1 the app survived'
    Assert (-not (Test-TestDesktopLeak -ProcessId $appPid)) 'B2 GUI never became visible on the interactive desktop'
}
catch {
    # T1511: the foreground-leak check below is part of this run too, so this
    # try cannot END in `Complete-TestBody`. It SCORES its own throw instead.
    Assert $false "the run threw and did not finish its sections: $($_.Exception.Message)"
}
finally {
    [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
    Remove-TestDesktop
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

$fgSeen = @(Stop-TestForegroundWatch)
$leaked = @(Get-TestLaunchedPids | Where-Object { $fgSeen -contains $_ })
Assert ($leaked.Count -eq 0) "no test-desktop app ever became foreground on the interactive desktop (saw $($leaked -join ','))"

Complete-TestBody  # T1039/T1511: before the stamp, which is a child process reading this run's state

# A green run stamps the covered files (T783); the negative control never does.
if ($script:fail -eq 0 -and -not $NegativeControl -and $Lines -ge 40000) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard scrollback-clear-memory -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Label 'SCROLLBACK-CLEAR-MEMORY'
