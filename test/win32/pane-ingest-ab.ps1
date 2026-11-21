# T1464 acceptance: is a pane SLOWER when its ConPTY is held by the agent?
#
#   powershell -NoProfile -File test\win32\pane-ingest-ab.ps1
#   powershell -NoProfile -File test\win32\pane-ingest-ab.ps1 -NegativeControl
#
# THE QUESTION THIS ANSWERS. T1463 measured, on an optimized build, the same
# 9.4 MB workload through three terminals on this box:
#
#     conhost                                  7,950 / 8,468 / 7,956 ms
#     Ghoztty pane, LOCAL ConPTY (Exec.zig)    6,511 / 6,138 ms
#     Ghoztty pane, AGENT-held (Remote.zig)   12,863 / 12,706 ms
#
# The same build, the same workload, 2.1x slower when the PTY is held by
# `ghoztty-agent` - and the agent-held one is the configuration we ship. The
# parse cost was identical in both (~41 ms of every second), so the deficit was
# the RELAY: the trip from the holder's ConPTY read, across two named pipes, to
# the app's parser, which was carrying the stream ~60 bytes at a time at
# 10,000-22,600 messages a second.
#
# That contrast is the entire finding, and until this script it existed once, by
# hand, in a scratchpad. What is regressed here is the RATIO rather than any
# absolute time: the ratio is what named the defect, and unlike a millisecond
# count it means the same thing on a Debug build, on a loaded box, and on
# somebody else's hardware.
#
# Sections:
#   A. Local-ConPTY pane (`--session-persistence=false`, termio.Exec) - the
#      control, the same app doing the same work with no relay in the path.
#   B. Agent-held pane (`--session-persistence=true`, termio.Remote) - the
#      shipped configuration.
#   C. The contrast: B is not materially slower than A. A and B each run
#      -Samples times (default 3), interleaved A,B,A,B, and C scores
#      median(B) / median(A) - one pair is noise on this box, not a
#      measurement (T3172).
#   D. conhost, for context. Reported, and asserted only as a sanity floor -
#      the box is not the variable this script controls.
#   E. The run stayed off the interactive desktop.
#
# -NegativeControl makes every timing arm wait for a stamp file the workload
# never writes, so each measured arm must go RED while the setup arms stay
# green. That is the proof the arms score ARRIVAL rather than the clock.
#
# READ THE RATIO ON AN OPTIMIZED BUILD. Against the default Debug `zig-out` the
# contrast INVERTS - measured 0.20x, agent-held 10.3 s against local 50.9 s -
# and that is not a relay win. Debug's parser is ~150x slower per byte (T1463),
# so a local pane back-pressures its child down to its own parse rate while the
# agent's ring absorbs the whole burst and lets the child run on. The same run
# shows it: `holder_read` still delivers 10,671 chunks a second while every leg
# downstream carries 2 frames a second of 32 KB, i.e. the writer coalescing this
# task added working exactly as designed against a consumer that is genuinely
# behind. Section C is still worth running on Debug - it is a liveness and
# correctness check on both paths - but the NUMBER only means something under
# `-ReleaseSandbox`.
#
# Runs on the BACKGROUND test desktop (lib\TestDesktop.ps1): every oracle is a
# CLI round trip or a file the child stamps, both desktop-independent.
#
# Only touches ghoztty processes running from this repo's zig-out.
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    # T1463's own size, ~7.7 MB of Claude-Code-shaped output, and it is not a
    # dial to turn down: at 20,000 chunks all three terminals finish in ~300 ms
    # and the agent path measures 0.89x - the relay's cost only exists once the
    # burst outlasts every buffer in the chain. A cheaper run measures nothing.
    [int]$Chunks = 400000,
    # WHICH output shape. `stream` (the default) is T1458's Claude-Code-shaped
    # stream of small writes. `type` is T1167's: one `type` of a big file of
    # numbered lines, i.e. a build log or a `cat` - few, large writes, which is
    # the shape a pipe-buffer or read-size limit would show up in and the
    # stream shape would not. Both are timed by the writer's own clock.
    [ValidateSet('stream', 'type')]
    [string]$Shape = 'stream',
    # Lines in the `type` payload. 500,000 is T1167's 4.5 MB.
    [int]$TypeLines = 500000,
    [int]$WaitSeconds = 300,
    # How many runs of EACH arm C1 is scored from (T3172). One run is not a
    # measurement on this box: T3168's twelve solo runs on one unchanged Debug
    # build found the agent arm steady (9.3-10.4 s) and the local arm anywhere
    # from 5.3 to 9.8 s, so a single pair scored 0.99x..1.72x - and once 2.73x -
    # with no code change. The arms run INTERLEAVED (A,B,A,B,...) so box drift
    # lands on both, and C1 scores median(B) / median(A), so one slow run of
    # either arm cannot decide the verdict.
    [ValidateRange(1, 15)]
    [int]$Samples = 3,
    # Measure an OPTIMIZED build. A ReleaseFast `zig-out` derives the same IPC
    # and agent endpoints as the user's installed release, so it can only be
    # measured under the three-knob release sandbox (T1158) - which is exactly
    # what the T1463 numbers this script regresses were taken under. Without
    # this switch a release build is REFUSED rather than silently driving the
    # terminal the user is sitting in.
    [switch]$ReleaseSandbox,
    # Leave the run's artifacts (app stderr, the workload, the stamps) on disk.
    # The path oracle below reads the app's own log, so a run that disagrees
    # with expectation is diagnosable only if that log outlives it.
    [switch]$KeepArtifacts,
    [switch]$NegativeControl
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
. (Join-Path $PSScriptRoot 'lib\PaneLiveness.ps1')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
[void](Set-GhozttyTestIsolation -Tag 'ingestab' -ReleaseSandbox:$ReleaseSandbox)

$script:passes = 0
$script:failures = 0

function Assert([string]$name, [bool]$cond) {
    if ($cond) { "  PASS $name"; $script:passes++ }
    else { "  FAIL $name"; $script:failures++ }
}

$tmp = Join-Path $env:TEMP "ghoztty-ingest-ab-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

# The app's own telemetry is this script's PATH ORACLE, and it has to be: a
# pane that could not reach an agent falls back to the local ConPTY silently,
# and the fallback looks exactly like a fast agent. `perf agent_feed` is logged
# only by `termio/Remote.zig` and `perf pty` only by `termio/Exec.zig`, so which
# line the app emitted says which backend carried the workload. T1463 measured
# the LOCAL path twice believing it was the agent one before this was checked.
$env:GHOZTTY_PERF = '1'

# ...and the agent's and the holders' halves of it, which reach nobody
# otherwise: the app's stderr is redirected by this script, but nothing
# redirects the agent's and nothing at all launches a pty holder except the
# agent. Both inherit this directory and append their relay meters to a file per
# process (`relay-perf-<pid>.log`), so a run that measures a deficit also says
# WHICH leg of the trip it is in.
$env:GHOZTTY_RELAY_PERF_DIR = $tmp

# --- bounds -----------------------------------------------------------------
# How much slower the agent-held pane may be than the local one.
#
# READ THIS BEFORE TIGHTENING IT. 1.75 is not the goal - it is a CEILING over a
# deficit that is still open. Measured on this box, optimized build: 2.25x
# before T1464's relay work, 1.97-2.15x after it, and 1.84-2.02x over five runs
# immediately before T1465. T1465 found the cause - the holder's process tree
# was being placed on the CPU's efficiency cores, where the shell->conhost round
# trip behind every ~73-byte chunk of output costs ~122 us against ~55 us on a
# performance core - and took the plumbing off them: three runs at 1.51x, 1.56x,
# 1.58x. Hence 1.75: above every measurement of the fixed path, below every
# measurement of the broken one, so this arm now fails if the fix stops working
# rather than only if something new breaks.
#
# The REST of the gap needs the user's own shell subtree pinned there too, which
# costs a build started in a persisted pane half the machine - a trade recorded
# as a decision rather than taken quietly. If that lands, this comes down to
# ~1.20 and the target becomes conhost parity.
$relayRatioBound = 1.75
# A run that produced no output at all would otherwise "pass" every ratio, so
# each pane must also clear a floor. Deliberately generous: the slowest thing
# measured on this box was the Debug agent path at ~50 KB/s.
$rateFloorKb = 20

# ---------------------------------------------------------------------------
# One CLI verb through cmd.exe with a real redirect (ghoztty.exe is
# GUI-subsystem, so `& $exe ... |` returns nothing), with a bounded wait so a
# wedged server fails the run instead of hanging it.
function Invoke-Ghoztty([string]$argsLine, [int]$timeoutSec = 20) {
    $out = Join-Path $tmp ("cli-{0}.txt" -f (Get-Random))
    $p = Start-Process -FilePath cmd.exe -WindowStyle Hidden -PassThru `
        -ArgumentList "/c `"`"$Exe`" $argsLine > `"$out`" 2>&1`""
    $null = $p.Handle   # exitcode-audit: cache before any wait (T197)
    if (-not $p.WaitForExit($timeoutSec * 1000)) {
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    }
    $text = if (Test-Path $out) { Get-Content $out -Raw } else { '' }
    Remove-Item $out -ErrorAction SilentlyContinue
    if ($null -eq $text) { return '' }
    return $text
}

<#
The pane `+list --json` reports for a window target, or $null. The whole
terminal object rather than its id, because `session_id` on it is this script's
PATH ORACLE: `+list` carries the agent session a pane is bound to and omits the
field entirely for a plain local ConPTY pane (T332), so it answers "is this pane
really on the relay?" without depending on how long the workload ran.
#>
function Get-Pane([string]$target) {
    $json = (Invoke-Ghoztty '+list --json').Trim()
    if (-not $json) { return $null }
    $data = $null
    try { $data = ($json | ConvertFrom-Json).data } catch { return $null }
    foreach ($w in $data.windows) {
        if ($w.target -eq $target) { return $w.tabs[0].splits.terminal }
    }
    return $null
}

<# Is this pane agent-backed? `session_id` present ⇒ yes (T332). #>
function Test-AgentBacked($pane) {
    if ($null -eq $pane) { return $false }
    $sid = $pane.session_id
    return ($null -ne $sid -and "$sid".Trim().Length -gt 0)
}

# --- the workload -----------------------------------------------------------
# A Claude-Code-shaped output stream (T1458): not a `cat` of one big file but
# many small writes - streaming token text, a spinner, and frequent full-width
# CR repaints of a status line. It times ITSELF and stamps the elapsed ms into a
# file, so the number is the writer's own clock and does not depend on how the
# harness launched it. Byte for byte the same file in all three terminals.
$workload = Join-Path $tmp 'workload.ps1'
@'
param([int]$Chunks = 4000, [string]$OutFile = '', [string]$TypeFile = '')
$ErrorActionPreference = 'Stop'
if ($TypeFile) {
    # T1167's shape: cmd's own `type` of one big file, inheriting this console,
    # so the bytes reach the terminal exactly as they would from a user's shell.
    $bytes = (Get-Item $TypeFile).Length
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Start-Process -FilePath $env:ComSpec -ArgumentList '/c', 'type', $TypeFile -NoNewWindow -Wait
    $sw.Stop()
    $ms = $sw.ElapsedMilliseconds
    [Console]::Out.Write("`nWORKLOAD_DONE ELAPSED_MS=$ms TYPE`n")
    if ($OutFile) { "ELAPSED_MS=$ms BYTES=$bytes" | Set-Content -Encoding ascii $OutFile }
    return
}
# Pre-build every chunk so the loop pays for terminal work, not for PowerShell
# string formatting - without this the emitter dominates and every terminal
# looks identical no matter what it does.
$spin = @('|', '/', '-', '\')
$bar = '=' * 46
$chunkList = New-Object 'System.Collections.Generic.List[string]'
for ($i = 0; $i -lt $Chunks; $i++) {
    if ($i % 7 -eq 0) {
        $s = $spin[[int](($i / 7) % 4)]
        $chunkList.Add("`r$s Working ($i)  $bar`r")
    } elseif ($i % 23 -eq 0) {
        $chunkList.Add("`n  * step $i complete`n")
    } else {
        $chunkList.Add("token$i ")
    }
}
$chunkArr = $chunkList.ToArray()
$bytes = 0
foreach ($c in $chunkArr) { $bytes += $c.Length }
$out = [Console]::Out
$sw = [System.Diagnostics.Stopwatch]::StartNew()
foreach ($c in $chunkArr) { $out.Write($c) }
$out.Flush()
$sw.Stop()
$ms = $sw.ElapsedMilliseconds
$out.Write("`nWORKLOAD_DONE ELAPSED_MS=$ms CHUNKS=$Chunks`n")
if ($OutFile) { "ELAPSED_MS=$ms BYTES=$bytes" | Set-Content -Encoding ascii $OutFile }
'@ | Set-Content -Encoding ascii $workload

# The `type` payload: L0000001..LNNNNNNN, one per line - T1142/T1167's file.
$typeArg = ''
if ($Shape -eq 'type') {
    $typeFile = Join-Path $tmp 'type-payload.txt'
    $sb = [System.Text.StringBuilder]::new()
    for ($i = 1; $i -le $TypeLines; $i++) { [void]$sb.AppendLine(('L{0:D6}' -f $i)) }
    [System.IO.File]::WriteAllText($typeFile, $sb.ToString())
    $typeArg = " -TypeFile `"$typeFile`""
}

<#
Write the .cmd shim a terminal runs. No arguments and no quoting for the caller
to mangle: every value is baked in when the file is written, which is what makes
`+send-keys <path>` and `cmd /c <path>` byte-identical launches.
#>
function New-RunShim([string]$tag) {
    $shim = Join-Path $tmp "go-$tag.cmd"
    $stamp = Join-Path $tmp "elapsed-$tag.txt"
    @(
        '@echo off',
        "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$workload`" -Chunks $Chunks -OutFile `"$stamp`"$typeArg"
    ) | Set-Content -Encoding ascii $shim
    # The pane is driven with `--keys-file`, whose bytes are sent VERBATIM. A
    # Windows path typed as a positional argument is not: `+send-keys` runs key
    # notation over it, so a CR escape inside a `run-...` path arrives as a
    # real carriage return and the shell sees the line broken in two.
    # (Observed: the shim ran as two commands, neither of which existed.)
    # The keys file is also written
    # WITHOUT a trailing newline, so the `Enter` after it is the only submit.
    $keys = Join-Path $tmp "keys-$tag.txt"
    [System.IO.File]::WriteAllText($keys, $shim)
    return [pscustomobject]@{ Shim = $shim; Stamp = $stamp; Keys = $keys }
}

<#
Wait for a workload stamp and parse it. Under -NegativeControl it watches a path
nothing ever writes, so every arm scoring the result must go red. Never throws.
#>
function Wait-Workload([string]$stamp, [int]$timeoutSec) {
    $watch = if ($NegativeControl) { "$stamp.never" } else { $stamp }
    # A stamp nothing writes proves the arm scores arrival after any wait at all,
    # so the negative control need not sit out the full budget once per sample:
    # 45 s still outlasts the real workload (~10 s on Debug), so the arm is red
    # because the oracle is watching the wrong file, not because it gave up early.
    # The REAL workload is then let finish (bounded by what is left of the
    # budget) before answering, so the setup arms that follow - B4's liveness
    # probe above all - meet a quiet pane, exactly as in a real run, rather than
    # one still flooding (observed: B4 red under the 45 s cap alone).
    $budgetEnd = (Get-Date).AddSeconds($timeoutSec)
    if ($NegativeControl -and $timeoutSec -gt 45) { $timeoutSec = 45 }
    $dl = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $dl) {
        if (Test-Path $watch) {
            $raw = Get-Content $watch -Raw
            if ($null -eq $raw) { $raw = '' }
            $ms = if ($raw -match 'ELAPSED_MS=(\d+)') { [int]$matches[1] } else { 0 }
            $by = if ($raw -match 'BYTES=(\d+)') { [int]$matches[1] } else { 0 }
            if ($ms -gt 0) {
                return [pscustomobject]@{
                    Ms = $ms
                    Bytes = $by
                    KbPerSec = if ($ms -gt 0) { [int](($by / 1024.0) / ($ms / 1000.0)) } else { 0 }
                }
            }
        }
        Start-Sleep -Milliseconds 250
    }
    if ($NegativeControl) {
        while ((Get-Date) -lt $budgetEnd -and -not (Test-Path $stamp)) { Start-Sleep -Milliseconds 250 }
    }
    return $null
}

<#
Bring up an app with the given persistence setting, run the workload in a fresh
pane, and return the writer's own timing (or $null). Never throws: an arm that
scores $null fails rather than ending the run (T1039).
#>
function Measure-Pane([string]$tag, [bool]$persistence, [bool]$warmAgent) {
    $run = New-RunShim $tag
    $errFile = Join-Path $tmp "app-$tag.err"

    # A COLD sandbox has no agent, and the app waits only ~2 s for the one it
    # spawns before deciding "no local agent" for the whole session - so a pane
    # opened in the first app of a fresh sandbox is LOCAL however persistent it
    # was asked to be. Bring one app up purely to spawn the agent, kill the APP
    # only, and measure in a second app that finds the agent already there.
    # Without this the agent-held section measures the local path and reports a
    # 1.01x ratio over a defect of 2.1x (observed while writing this script).
    if ($warmAgent) {
        [void](Start-OnTestDesktop -Exe $Exe `
                -Arguments @("--session-persistence=true") `
                -StdErr (Join-Path $tmp "warm-$tag.err") -AllowReleaseBuild:$ReleaseSandbox)
        $agentPath = Get-GhozttyAgentPath -Exe $Exe
        for ($t = 0; $t -lt 80; $t++) {
            Start-Sleep -Milliseconds 500
            $up = @(Get-Process -Name ghoztty-agent -ErrorAction SilentlyContinue |
                    Where-Object { $_.Path -eq $agentPath })
            if ($up.Count -gt 0) { break }
        }
        Start-Sleep -Seconds 5
        Reset-GhozttyTestState -Exe $Exe -AppOnly -SettleMs 1000 -AllowReleaseBuild:$ReleaseSandbox | Out-Null
        Start-Sleep -Seconds 2
    }

    # persistence: the flag IS passed, from this function's own $persistence
    # parameter - the A/B comparison is persistence-on against persistence-off,
    # so the value is the experiment and every caller states which side it wants.
    $app = Start-OnTestDesktop -Exe $Exe `
        -Arguments @("--session-persistence=$($persistence.ToString().ToLower())") `
        -StdErr $errFile -AllowReleaseBuild:$ReleaseSandbox
    Start-Sleep -Seconds 4

    # A `+new-window` that lands while the app's OWN startup resolve is still in
    # flight gets `sharedConnection() == null` ("still resolving; answering
    # none") and opens a plain local shell - silently, and in the section whose
    # entire subject is the agent path. Wait for the connection the app logs
    # before asking for the window. (Observed: the agent section measured
    # `termio.Exec` and reported a 1.01x ratio over a 2.1x defect.)
    if ($warmAgent) {
        $ready = Wait-ForLine $errFile 'shared local-agent connection ready' 60
        if (-not $ready) { "  (warning) the app never reported a ready local-agent connection" }
        Start-Sleep -Seconds 1
    }

    [void](Invoke-Ghoztty "+new-window --target=ab$tag" 60)

    $pane = $null
    $paneId = $null
    for ($t = 0; $t -lt 60; $t++) {
        $pane = Get-Pane "ab$tag"
        if ($null -ne $pane) { $paneId = $pane.id }
        if ($paneId) { break }
        Start-Sleep -Milliseconds 500
    }
    if (-not $paneId) {
        return [pscustomobject]@{
            Pane = $null; Primed = $false; Result = $null; App = $app; Err = $errFile; Agent = $false
        }
    }

    # Prime: the shell is alive and its echo reaches the screen, so a workload
    # that never runs is the workload's fault and not the pane's.
    [void](Invoke-Ghoztty "+send-keys --target=$paneId `"echo READY`" Enter")
    $primed = $false
    for ($t = 0; $t -lt 60; $t++) {
        Start-Sleep -Milliseconds 250
        if ((Invoke-Ghoztty "+read --name=$paneId --lines=6") -match 'READY') { $primed = $true; break }
    }
    if (-not $primed) {
        return [pscustomobject]@{
            Pane = $paneId; Primed = $false; Result = $null; App = $app; Err = $errFile
            Agent = (Test-AgentBacked $pane)
        }
    }

    # Re-read the pane now that its shell has answered. `+list` reports the
    # agent session from `liveSessionId()`, which is null until the OPEN has
    # completed - so the object fetched the instant the window appeared says
    # "local" about every pane, agent-held ones included.
    $settled = Get-Pane "ab$tag"
    if ($null -ne $settled) { $pane = $settled }

    [void](Invoke-Ghoztty "+send-keys --target=$paneId --keys-file=`"$($run.Keys)`" Enter")
    $r = Wait-Workload $run.Stamp $WaitSeconds
    # A workload that never stamped leaves the pane holding the reason (a shell
    # that never saw the line, a powershell that refused the file). Capture it
    # here rather than making the next run guess.
    $tail = ''
    if ($null -eq $r) { $tail = (Invoke-Ghoztty "+read --name=$paneId --lines=12") }
    return [pscustomobject]@{
        Pane = $paneId; Primed = $true; Result = $r; App = $app; Tail = $tail; Err = $errFile
        Agent = (Test-AgentBacked $pane)
    }
}

<#
Read a log the app still has OPEN. `Get-Content` on a live redirect target is a
sharing violation, and this script has to read one WHILE the app runs (below).
Never throws: anything unreadable is the empty string.
#>
function Read-LogSafe([string]$path) {
    if (-not (Test-Path $path)) { return '' }
    try {
        $fs = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
        $sr = New-Object System.IO.StreamReader($fs)
        $t = $sr.ReadToEnd()
        $sr.Close(); $fs.Close()
        if ($null -eq $t) { return '' }
        return $t
    } catch { return '' }
}

<#
Did the app log `needle`? Never throws: a missing or empty log answers false,
which fails the arm rather than ending the run.
#>
function Test-PerfLine([string]$errFile, [string]$needle) {
    return ((Read-LogSafe $errFile) -match [regex]::Escape($needle))
}

<#
Wait (bounded) for `needle` to appear in a live log. Answers whether it did.
#>
function Wait-ForLine([string]$errFile, [string]$needle, [int]$timeoutSec) {
    $dl = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $dl) {
        if (Test-PerfLine $errFile $needle) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

<#
Wait until the app has CAUGHT UP with a pane before its liveness probe (T1627,
T1670). The workload's stamp says when the WRITER finished, not when the app
finished drawing what it wrote: on the agent path the relay's ring absorbs the
whole 8 MB burst and the app digests it for seconds afterwards (observed
`ipcperf action=list accept=18445ms`, the renderer at fps=1). A probe typed into
that window has its `+send-keys` time out before the app accepts it, the token is
never sent, and a pane that answers twenty seconds later is scored DEAD.

So wait for what "caught up" means, bounded by the wall clock (T831): two
consecutive `+read`s that both ANSWER (an empty string is a timeout or an error)
and return the same screen. Returns a note for the run's output. Never throws,
and never decides liveness itself: a pane that never goes quiet is still probed,
so a genuinely dead pane fails B4 exactly as before (the teeth-check is
`GHOZTTY_TEST_LIVENESS_BREAK=1`, lib\PaneLiveness.ps1).
#>
function Wait-PaneCaughtUp([string]$target, [int]$timeoutSec = 120) {
    $t0 = Get-Date
    $dl = $t0.AddSeconds($timeoutSec)
    $prev = $null
    $reads = 0
    while ((Get-Date) -lt $dl) {
        $cur = Invoke-Ghoztty "+read --name=$target --lines=8" 20
        $reads++
        if ($cur.Trim() -and $null -ne $prev -and $cur -eq $prev) {
            return "caught up after {0:N1} s ({1} reads)" -f ((Get-Date) - $t0).TotalSeconds, $reads
        }
        $prev = if ($cur.Trim()) { $cur } else { $null }
        Start-Sleep -Milliseconds 1000
    }
    return "NOT quiet after $timeoutSec s ($reads reads) - probing anyway"
}

<#
The liveness arm for one sample: let the app catch up, then type the token. The
probe's own deadline is 45 s rather than the library's 25 s default because a
post-flood pane on a loaded Debug box still answers its first `+read` slowly even
once its screen has stopped moving; the catch-up wait above is what makes the
arm measure survival instead of the digestion time.
#>
function Test-PaneSurvived([string]$label, $r) {
    if ($null -eq $r -or -not $r.Pane) { return $false }
    "  ${label} liveness: " + (Wait-PaneCaughtUp $r.Pane) | Write-Host
    return (Test-PaneLive -Exe $Exe -Target $r.Pane -Tmp $tmp -TimeoutSec 45)
}

function Show-Run([string]$tag, $r) {
    if ($null -eq $r) { "  ${tag}: no result"; return }
    if (-not $r.Primed) { "  ${tag}: pane never primed (pane=$($r.Pane))"; return }
    if ($null -eq $r.Result) {
        "  ${tag}: workload never finished; pane tail:"
        foreach ($ln in ("$($r.Tail)" -split "`r?`n")) { if ($ln.Trim()) { "    | $ln" } }
        return
    }
    "  ${tag}: {0} ms, {1:N0} bytes, {2} KB/s (writer clock)" -f $r.Result.Ms, $r.Result.Bytes, $r.Result.KbPerSec
}

<#
The median of a list of numbers, or 0 for an empty one. Middle element of an odd
count, mean of the two middle ones of an even count. `@()` on the way in, since a
one-element pipeline result arrives as a scalar (PS5.1).
#>
function Get-Median($values) {
    $v = @($values | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ } | Sort-Object)
    if ($v.Count -eq 0) { return 0.0 }
    $mid = [int][math]::Floor($v.Count / 2)
    if ($v.Count % 2 -eq 1) { return $v[$mid] }
    return ($v[$mid - 1] + $v[$mid]) / 2.0
}

# Every run of each arm, in the order it was taken (T3172).
$localRuns = New-Object System.Collections.ArrayList
$agentRuns = New-Object System.Collections.ArrayList
$conhost = $null

try {
    "== setup: {0}, {1} sample(s) per arm, interleaved{2}" -f $(
        if ($Shape -eq 'type') { "type of $TypeLines lines" } else { "$Chunks chunks" }), $Samples, $(
        if ($NegativeControl) { ' (NEGATIVE CONTROL - watching a stamp nothing writes)' } else { '' })

    Reset-GhozttyTestState -Exe $Exe -SettleMs 1000 -AllowReleaseBuild:$ReleaseSandbox | Out-Null
    Assert-GhozttyPrivateEndpoint -Exe $Exe -AllowReleaseBuild:$ReleaseSandbox
    New-TestDesktop | Out-Null

    # --- Sections A and B, interleaved --------------------------------------
    # A: the local-ConPTY control (termio.Exec, no relay in the path).
    # B: the shipped, agent-held path (termio.Remote).
    # One A then one B per sample, so whatever the box is doing during the run
    # (a build cache being reclaimed, a defender scan) lands on both arms rather
    # than on whichever happened to run second.
    for ($s = 1; $s -le $Samples; $s++) {
        "== A#${s}: local-ConPTY pane (termio.Exec, no relay in the path)"
        $lr = Measure-Pane "local$s" $false $false
        Show-Run "A#$s" $lr
        $lr | Add-Member -NotePropertyName Live -NotePropertyValue (Test-PaneSurvived "A#$s" $lr) -Force
        $lr | Add-Member -NotePropertyName Leaked -NotePropertyValue (
            $null -eq $lr -or $null -eq $lr.App -or (Test-TestDesktopLeak -ProcessId $lr.App.Pid)) -Force
        [void]$localRuns.Add($lr)
        Reset-GhozttyTestState -Exe $Exe -SettleMs 1000 -AllowReleaseBuild:$ReleaseSandbox | Out-Null

        "== B#${s}: agent-held pane (termio.Remote, the shipped configuration)"
        $ar = Measure-Pane "agent$s" $true $true
        Show-Run "B#$s" $ar
        # Liveness is checked while this sample's app is still up - the reset
        # below takes it down.
        $ar | Add-Member -NotePropertyName Live -NotePropertyValue (Test-PaneSurvived "B#$s" $ar) -Force
        $ar | Add-Member -NotePropertyName Leaked -NotePropertyValue (
            $null -eq $ar -or $null -eq $ar.App -or (Test-TestDesktopLeak -ProcessId $ar.App.Pid)) -Force
        [void]$agentRuns.Add($ar)
        if ($s -lt $Samples) {
            Reset-GhozttyTestState -Exe $Exe -SettleMs 1000 -AllowReleaseBuild:$ReleaseSandbox | Out-Null
        }
    }

    # An arm's assertion holds only if it holds for EVERY sample: a pane that
    # fell back to the local path once is a broken agent path, however the
    # other samples went.
    $lAll = @($localRuns)
    $aAll = @($agentRuns)
    $lDone = @($lAll | Where-Object { $null -ne $_ -and $null -ne $_.Result })
    $aDone = @($aAll | Where-Object { $null -ne $_ -and $null -ne $_.Result })

    Assert "A1 the local pane came up and its shell echoes (all $Samples)" (
        $lAll.Count -eq $Samples -and @($lAll | Where-Object { $null -eq $_ -or -not $_.Primed }).Count -eq 0)
    Assert 'A2 the pane really was LOCAL (+list reports no agent session)' (
        $lAll.Count -eq $Samples -and @($lAll | Where-Object { $null -eq $_ -or $_.Agent }).Count -eq 0)
    Assert 'A2b the workload finished in the local pane' ($lDone.Count -eq $Samples)
    Assert "A3 local ingest is at least $rateFloorKb KB/s" (
        $lDone.Count -eq $Samples -and @($lDone | Where-Object { $_.Result.KbPerSec -lt $rateFloorKb }).Count -eq 0)
    Assert 'A4 the local pane is still LIVE afterwards' (
        $lAll.Count -eq $Samples -and @($lAll | Where-Object { -not $_.Live }).Count -eq 0)

    Assert "B1 the agent-held pane came up and its shell echoes (all $Samples)" (
        $aAll.Count -eq $Samples -and @($aAll | Where-Object { $null -eq $_ -or -not $_.Primed }).Count -eq 0)
    Assert 'B2 the pane really was AGENT-HELD (+list names its agent session)' (
        $aAll.Count -eq $Samples -and @($aAll | Where-Object { $null -eq $_ -or -not $_.Agent }).Count -eq 0)
    Assert 'B2b the workload finished in the agent-held pane' ($aDone.Count -eq $Samples)
    Assert "B3 agent-held ingest is at least $rateFloorKb KB/s" (
        $aDone.Count -eq $Samples -and @($aDone | Where-Object { $_.Result.KbPerSec -lt $rateFloorKb }).Count -eq 0)
    Assert 'B4 the agent-held pane is still LIVE afterwards' (
        $aAll.Count -eq $Samples -and @($aAll | Where-Object { -not $_.Live }).Count -eq 0)

    # The relay's own meters, from the agent and the holder processes, pooled
    # over every B sample. Reported rather than asserted: they are how a red C1
    # is diagnosed, and their shape (bytes per frame, frames per wake) is what
    # named the defect.
    $relayLogs = @(Get-ChildItem -Path $tmp -Filter 'relay-perf-*.log' -ErrorAction SilentlyContinue)
    if ($relayLogs.Count -gt 0) {
        # The MEDIAN busy second, not the busiest: every leg of this relay peaks
        # near the local path's rate while the burst is still being absorbed by
        # the buffers in front of it, and reporting that peak says the relay is
        # fine when the sustained rate is half of it.
        "  relay meters (median busy second per leg):"
        $byLeg = @{}
        foreach ($f in $relayLogs) {
            foreach ($ln in (Read-LogSafe $f.FullName) -split "`r?`n") {
                if ($ln -match '^perf (?<leg>\S+) .*kb_per_s=(?<kb>\d+)') {
                    $leg = $matches['leg']; $kb = [int]$matches['kb']
                    if ($kb -lt 20) { continue }   # an idle second is not a sample
                    if (-not $byLeg.ContainsKey($leg)) { $byLeg[$leg] = @() }
                    $byLeg[$leg] += [pscustomobject]@{ Kb = $kb; Line = $ln }
                }
            }
        }
        foreach ($leg in ($byLeg.Keys | Sort-Object)) {
            $rows = @($byLeg[$leg] | Sort-Object Kb)
            "    " + $rows[[int]($rows.Count / 2)].Line
        }
    }

    # --- Section C: the contrast --------------------------------------------
    # Scored from the MEDIAN of each arm (T3172), never from one pair, and every
    # sample is printed so a red names its own spread.
    "== C: the relay's cost"
    $ratio = 0.0
    $lMs = @($lDone | ForEach-Object { $_.Result.Ms })
    $aMs = @($aDone | ForEach-Object { $_.Result.Ms })
    "  A samples (ms): " + $(if ($lMs.Count) { $lMs -join ', ' } else { '(none)' })
    "  B samples (ms): " + $(if ($aMs.Count) { $aMs -join ', ' } else { '(none)' })
    for ($s = 0; $s -lt $Samples; $s++) {
        $l = $lAll[$s]; $a = $aAll[$s]
        if ($null -ne $l -and $null -ne $l.Result -and $null -ne $a -and $null -ne $a.Result -and $l.Result.Ms -gt 0) {
            "  pair {0}: {1:N2}x" -f ($s + 1), ($a.Result.Ms / [double]$l.Result.Ms)
        }
    }
    # Only a full set is scored: a median over the survivors of a partly failed
    # run would be a number about fewer samples than the verdict claims.
    $medL = Get-Median $lMs
    $medA = Get-Median $aMs
    if ($lMs.Count -eq $Samples -and $aMs.Count -eq $Samples -and $medL -gt 0) {
        $ratio = $medA / $medL
        "  agent / local = {0:N2}x  (median {1} ms vs median {2} ms, {3} sample(s) each)" -f $ratio, $medA, $medL, $Samples
    } else {
        "  agent / local = (not measured: {0} of {1} local and {2} of {1} agent samples finished)" -f $lMs.Count, $Samples, $aMs.Count
    }
    Assert "C1 the relay has not got worse (median agent within ${relayRatioBound}x of median local)" (
        $ratio -gt 0 -and $ratio -le $relayRatioBound)

    # --- Section D: conhost, for context ------------------------------------
    "== D: conhost control"
    $ch = New-RunShim 'conhost'
    # stderr: n/a - this is cmd.exe running the shim, the conhost CONTROL arm;
    # the shim writes its own measurements to a file the section reads back.
    $cp = Start-Process -FilePath $env:ComSpec -WindowStyle Minimized -PassThru `
        -ArgumentList '/c', $ch.Shim
    $null = $cp.Handle   # exitcode-audit: cache before any wait (T197)
    $conhost = Wait-Workload $ch.Stamp $WaitSeconds
    try { if (-not $cp.HasExited) { $cp.Kill() } } catch {}
    if ($null -ne $conhost) {
        "  D: {0} ms, {1} KB/s (writer clock)" -f $conhost.Ms, $conhost.KbPerSec
        if ($aMs.Count -gt 0 -and $conhost.Ms -gt 0) {
            "  median agent / conhost = {0:N2}x" -f ($medA / [double]$conhost.Ms)
        }
    } else {
        "  D: conhost never finished"
    }
    Assert "D1 the conhost control ran and cleared $rateFloorKb KB/s" (
        $null -ne $conhost -and $conhost.KbPerSec -ge $rateFloorKb)

    # Checked per sample while that sample's app was up (Measure-Pane's caller).
    Assert 'E1 the run never took the interactive desktop' (
        ($lAll.Count + $aAll.Count) -eq (2 * $Samples) -and
        @(($lAll + $aAll) | Where-Object { $_.Leaked }).Count -eq 0)

    Complete-TestBody   # T1039: last statement of the try body, before the stamp
} finally {
    Reset-GhozttyTestState -Exe $Exe -SettleMs 500 -AllowReleaseBuild:$ReleaseSandbox | Out-Null
    Remove-TestDesktop
    if ($KeepArtifacts) { "  artifacts: $tmp" }
    else { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
}

# --- stamp (T783) -----------------------------------------------------------
# A green run records the content of the relay this harness covers, so
# scripts\guard-due.ps1 can answer "has anything measured the relay against the
# code as it now stands?". A red run - the negative control included - leaves
# the stamp alone.
if ($script:failures -eq 0 -and -not $NegativeControl -and -not $ReleaseSandbox) {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard relay-throughput -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-TestVerdict -Label 'PANE-INGEST-AB' -Pass $script:passes -Fail $script:failures
