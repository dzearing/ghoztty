# T3105 acceptance (Mac 1956f5f55): a client that connects to the IPC pipe and
# says nothing cannot hold up anybody else, and cannot hold up quit.
#
# THE DEFECT. The win32 IPC server read each request with a synchronous,
# untimed ReadFile, one listener thread per pipe instance, four instances. A
# client that connected and sent nothing - a hook killed mid-write, a script
# that opened the pipe and then blocked on something else - parked its
# listener for the life of the app. Four of them and every later
# `ghoztty +verb`, status hook and banner hook in every pane printed "No
# running Ghoztty instance found." after ~10 s of PIPE_BUSY retries. One of
# them and quit hung: shutdown waits for every listener to come home, and a
# listener inside a synchronous ReadFile never does.
#
# THE FIX (src/apprt/win32/ipc_pipe_io.zig + IpcServer.zig): overlapped pipe
# instances, every server read/write bounded at 5 s (the Mac bound), the
# unbounded FlushFileBuffers replaced by a bounded wait for the client to hang
# up, shutdown cancels every listener's pending I/O, and 16 instances.
#
# WHAT IS ASSERTED:
#   A. With more silent clients than the OLD pool had (8 > 4), +list,
#      +set-banner and +read from other clients answer in their normal time.
#   B. With every instance taken by a silent client, +list still answers -
#      inside the client's ~10 s connect budget, because the server drops each
#      silent client at the 5 s bound. Pre-fix: never.
#   C. The silent clients ARE dropped: each sees its connection end within a
#      few seconds of the bound.
#   D. Quit is not held up: closing the last window with silent clients
#      connected exits about as fast as the same quit with none (control).
#
# persistence: launches with --session-persistence=false; the defect is in the
# IPC transport, which has nothing to do with whether panes persist.
#
#   powershell -NoProfile -File test\win32\ipc-silent-client.ps1
param(
    [string]$Exe = (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'zig-out\bin\ghoztty.exe'),
    [switch]$Interactive
)
$ErrorActionPreference = 'Continue'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
$script:failures = 0
$script:passes = 0
$script:skipped = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { "  PASS $label"; $script:passes++ } else { "  FAIL $label"; $script:failures++ }
}

if (-not (Test-Path $Exe)) { Write-TestAssertedNothing -Reason "exe not found: $Exe" }

$env:GHOZTTY_PIPE_SUFFIX = "-silentcli$PID"
$pipeName = "ghoztty$($env:GHOZTTY_PIPE_SUFFIX)-$env:USERNAME"
$instanceCount = 16   # IpcServer.instance_count

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\HarnessLeak.ps1')
Reset-GhozttyTestState -Exe $Exe -SettleMs 500 | Out-Null
Register-RepoBuildTeardown -Exe $Exe | Out-Null

$appArgs = @('--config-default-files=false', '--session-persistence=false',
    '--confirm-close-surface=false', '--quit-after-last-window-closed=true')

function Ghoz([string[]]$GhozArgs, [int]$TimeoutSec = 30) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-OnTestDesktop -Exe $Exe -Arguments $GhozArgs -TimeoutSec $TimeoutSec
    $sw.Stop()
    return [pscustomobject]@{ ExitCode = $r.ExitCode; Output = "$($r.Output)"; Ms = $sw.ElapsedMilliseconds }
}

function Start-App {
    Clear-DebugSessionLayout | Out-Null
    $app = Start-OnTestDesktop -Exe $Exe -Arguments $appArgs
    $top = Wait-TestWindow -ProcessId ([int]$app.Pid) -Class 'GhozttyWindow' -TimeoutMs 25000
    if ($top -eq [IntPtr]::Zero) { return $null }
    # The pipe answers once the app is up; wait for a real round trip.
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline) {
        if ((Ghoz @('+list') 10).ExitCode -eq 0) { break }
        Start-Sleep -Milliseconds 300
    }
    return [pscustomobject]@{ Pid = [int]$app.Pid; Window = $top }
}

# Connect $n raw clients that send nothing. Each Connect is bounded so a full
# pool cannot wedge the harness itself; returns only the clients that got in.
function Open-SilentClients([int]$n) {
    $held = @()
    for ($i = 0; $i -lt $n; $i++) {
        $c = New-Object System.IO.Pipes.NamedPipeClientStream('.', $pipeName, [System.IO.Pipes.PipeDirection]::InOut)
        try { $c.Connect(2000); $held += $c } catch { $c.Dispose() }
    }
    return , $held
}
function Close-Clients($clients) { foreach ($c in @($clients)) { try { $c.Dispose() } catch { } } }

# Has the server ended this client's connection? A read that returns 0 or
# throws "pipe is broken" both mean yes; a read still pending means no.
function Test-Dropped($client, [int]$WaitMs) {
    $buf = New-Object byte[] 16
    try {
        $t = $client.ReadAsync($buf, 0, 16)
        if (-not $t.Wait($WaitMs)) { return $false }
        return ($t.Result -eq 0)
    } catch { return $true }
}

function Wait-Exit([int]$ProcId, [int]$TimeoutMs) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        if (-not (Get-Process -Id $ProcId -ErrorAction SilentlyContinue)) { return $sw.ElapsedMilliseconds }
        Start-Sleep -Milliseconds 50
    }
    return -1
}

Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$launched = @()
$silent = @()
try {
    $app = Start-App
    if (-not $app) { Write-TestAssertedNothing -Reason 'SETUP FAIL: app window never appeared' }
    $launched += $app.Pid

    # The first pane id in the listing - read off the JSON text so the tree's
    # shape (a leaf or a split) does not matter.
    $paneId = $null
    $listing = (Ghoz @('+list', '--json')).Output
    $m = [regex]::Match($listing, '"(?:pane_id|id)"\s*:\s*"([0-9A-Fa-f-]{36})"')
    if ($m.Success) { $paneId = $m.Groups[1].Value }
    Assert ([bool]$paneId) "setup: resolved the window's pane id ($paneId)"

    # Baseline: how long these verbs take with nobody squatting on the pipe.
    $base = Ghoz @('+list')
    Assert ($base.ExitCode -eq 0) "baseline: +list answers (exit $($base.ExitCode), $($base.Ms) ms)"

    # --- A: more silent clients than the old pool had ---------------------
    "== A: 8 silent clients connected; other clients still answer promptly"
    $silent = Open-SilentClients 8
    Assert ($silent.Count -eq 8) "A: 8 silent clients got a pipe instance each (got $($silent.Count))"
    $l = Ghoz @('+list')
    Assert ($l.ExitCode -eq 0 -and $l.Ms -lt 3000) "A: +list answers in $($l.Ms) ms (exit $($l.ExitCode)); < 3000 ms"
    $b = Ghoz @('+set-banner', "--target=$paneId", 'silent-client probe')
    Assert ($b.ExitCode -eq 0 -and $b.Ms -lt 3000) "A: +set-banner answers in $($b.Ms) ms (exit $($b.ExitCode)); < 3000 ms"
    $r = Ghoz @('+read', "--name=$paneId", '--lines=2')
    Assert ($r.ExitCode -eq 0 -and $r.Ms -lt 3000) "A: +read answers in $($r.Ms) ms (exit $($r.ExitCode)); < 3000 ms"

    # --- C (on A's clients): the server drops them at its bound ----------
    "== C: the silent clients are dropped at the server's 5 s bound"
    $dropped = 0
    foreach ($c in $silent) { if (Test-Dropped $c 9000) { $dropped++ } }
    Assert ($dropped -eq $silent.Count) "C: $dropped of $($silent.Count) silent clients were disconnected by the server"
    Close-Clients $silent; $silent = @()

    # --- B: every instance taken ----------------------------------------
    "== B: every pipe instance held by a silent client; +list still gets in"
    $silent = Open-SilentClients $instanceCount
    Assert ($silent.Count -eq $instanceCount) "B: all $instanceCount instances taken (got $($silent.Count))"
    $l = Ghoz @('+list') 40
    Assert ($l.ExitCode -eq 0) "B: +list still answers with the pool full (exit $($l.ExitCode), $($l.Ms) ms; pre-fix: No running Ghoztty instance found)"
    Assert ($l.Ms -lt 9500) "B: ... inside the client's connect budget ($($l.Ms) ms < 9500 ms)"
    Close-Clients $silent; $silent = @()

    # --- D: quit with silent clients vs. without --------------------------
    "== D: quit is not held up by silent clients"
    Send-TestWindowClose -Window $app.Window | Out-Null
    $ctl = Wait-Exit $app.Pid 20000
    Assert ($ctl -ge 0) "D control: closing the last window quits the app ($ctl ms)"

    $app2 = Start-App
    if (-not $app2) {
        Assert $false 'D: relaunch for the silent-client quit produced no window'
    } else {
        $launched += $app2.Pid
        $silent = Open-SilentClients 4
        Assert ($silent.Count -eq 4) "D: 4 silent clients connected before quit (got $($silent.Count))"
        Send-TestWindowClose -Window $app2.Window | Out-Null
        $q = Wait-Exit $app2.Pid 30000
        Assert ($q -ge 0) "D: the app quits with silent clients connected ($q ms; pre-fix: never, until they hang up)"
        # Cancel, not the 5 s bound, is what frees the listeners: allow the
        # control's time plus slack well under the bound.
        Assert ($q -ge 0 -and $q -lt ($ctl + 3000)) "D: ... about as fast as the control ($q ms vs $ctl ms + 3000 ms)"
        Close-Clients $silent; $silent = @()
    }

    Complete-TestBody
} finally {
    Close-Clients $silent
    Remove-TestDesktop | Out-Null
    Reset-GhozttyTestState -Exe $Exe -SettleMs 300 | Out-Null
}

$fgSeen = @(Stop-TestForegroundWatch)
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    $leaked = @(@($launched | Select-Object -Unique) | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'no test-desktop app ever became foreground on the interactive desktop'
}
Assert (Test-TestBodyComplete) 'the script ran to the end (no section was skipped by an error)'

if ($script:failures -eq 0 -and $script:skipped -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard ipc-silent-client -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

""
Write-TestVerdict -Pass $script:passes -Fail $script:failures -Skipped ([int]$script:skipped) -Label 'T3105 ACCEPTANCE'
