# pty-host acceptance (T904): the per-session ConPTY holder process.
#
# Sections:
#   A. End-to-end smoke: `ghoztty-agent --pty-host-smoke` spawns REAL holder
#      processes and drives them over the real control pipe. Its checks (all
#      asserted here individually off its stdout): HELLO fields, output flow,
#      RESIZE reaching the shell (`mode con` reports the new width), owner
#      death leaving the shell alive, reconnect gap-replay with contiguous
#      offsets, EXIT carrying the shell's exit code, the holder finishing
#      after delivery, and a killed holder's Job Object taking the shell
#      subtree with it. Since T905 it also drives the PRODUCTION owner client
#      (`pty_holder_child.open`, the one the agent uses) through the
#      `session.Child` vtable: output to the sink, the spawn spec's forwarded
#      `OPEN.env` reaching the shell, resize, the exit code via `tryWait`, and
#      a terminate that leaves neither shell nor holder behind. Since T970, an
#      owner that never releases what it took is flooded past a 4 KB ring, and
#      the drop must be logged by the holder and totalled in the next HELLO.
#   B. Pipe security: a live holder's control pipe carries an owner-only DACL
#      - every access rule on it names the current user, nobody else.
#   C. Idle cost and exit (T3021): an idle holder is scheduled under
#      -IdleMaxPerSec times a second, and a shell that exits with no owner
#      ends its holder once the linger runs out (not before).
#
# The smoke's holder pipe names are read back from its own log (section A) so
# section B derives the real `[-debug]` segment instead of assuming the build
# mode. Holders use per-PID session ids and the agent's `--pty-host` mode only
# - no GUI is launched, no user endpoint is shared, and only processes spawned
# by this run are touched.
#
# The agent is a GUI-subsystem binary: launched via Start-Process with
# redirected streams (PowerShell would not wait for it otherwise), gated on
# its OUTPUT (the verdict line), not its exit code.

param(
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe',
    [int]$SmokeTimeoutMs = 200000,
    # Section C (T3021): how long an idle holder is watched, after how long a
    # settle, and the context-switch rate it must stay under.
    [int]$IdleSettleSeconds = 4,
    [int]$IdleSeconds = 30,
    [double]$IdleMaxPerSec = 0.5
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')  # T1036: Assert-GhozttyIsolatedAgent

$script:passes = 0
$script:failures = 0

function Assert([string]$name, [bool]$cond) {
    if ($cond) { "  PASS $name"; $script:passes++ }
    else { "  FAIL $name"; $script:failures++ }
}

if (-not (Test-Path $AgentExe)) {
    Write-TestAssertedNothing -Label 'PTY-HOST' -Reason "agent exe not found: $AgentExe (build with: zig build agent -Doptimize=Debug)"
}

# --- Section A: the end-to-end smoke ----------------------------------------

$outLog = Join-Path $env:TEMP "pty-host-smoke-out-$PID.log"
$errLog = Join-Path $env:TEMP "pty-host-smoke-err-$PID.log"
Remove-Item $outLog, $errLog -ErrorAction SilentlyContinue

# T1036: the agent answers for its own endpoints before it is launched.
Assert-GhozttyIsolatedAgent -Exe $AgentExe | Out-Null
$p = Start-Process -FilePath $AgentExe -ArgumentList '--pty-host-smoke' `
    -RedirectStandardOutput $outLog -RedirectStandardError $errLog `
    -NoNewWindow -PassThru
$null = $p.Handle   # cache BEFORE any wait (T197) - though the gate below is the OUTPUT
if (-not $p.WaitForExit($SmokeTimeoutMs)) {
    try { $p.Kill() } catch {}
    Assert 'A0 smoke completed within the timeout' $false
}

$smokeOut = @(Get-Content $outLog -ErrorAction SilentlyContinue)
$smokeErr = @(Get-Content $errLog -ErrorAction SilentlyContinue)
$joined = $smokeOut -join "`n"

Assert 'A1 smoke verdict is ALL PASS' ($joined -match 'PTY-HOST SMOKE: ALL PASS')
Assert 'A2 no FAIL lines in the smoke output' (-not ($smokeOut | Where-Object { $_ -match '^FAIL' }))
Assert 'A3 hello carried the holder build stamp' ($joined -match 'ok - hello: holder build stamp present')
Assert 'A4 output flowed through the holder' ($joined -match 'ok - output flows')
Assert 'A5 resize reached the shell' ($joined -match 'ok - resize: shell reports the new width')
Assert 'A6 owner death left the shell alive' ($joined -match 'ok - owner death leaves the shell alive')
Assert 'A7 reconnect replayed the ownerless gap' ($joined -match 'ok - reconnect: gap replayed')
Assert 'A8 replay offsets were contiguous (no bytes lost)' ($joined -match 'ok - reconnect: output offsets are contiguous')
Assert 'A9 EXIT carried the shell exit code' ($joined -match 'ok - exit: shell exit code carried')
Assert 'A10 holder finished after delivering EXIT' ($joined -match 'ok - holder exits after delivering EXIT')
Assert 'A11 killing the holder killed the shell subtree (job)' ($joined -match 'ok - job-kill: killing the holder terminates the shell subtree')

# T905's production owner (`pty_holder_child.open`) — the SAME client the agent
# uses for every holder-backed session, driven through the `session.Child`
# vtable so what is proven here is what the agent will get.
Assert 'A12 production owner: holder + shell both running' (($joined -match 'ok - production owner: shell running') -and ($joined -match 'ok - production owner: holder running'))
Assert 'A13 production owner: output reaches the session sink' ($joined -match 'ok - production owner: output reaches the session sink')
Assert 'A14 production owner: forwarded OPEN.env reached the shell' ($joined -match 'ok - production owner: OPEN.env reached the shell')
Assert 'A15 production owner: resize reaches the shell' ($joined -match 'ok - production owner: resize reaches the shell')
Assert 'A16 production owner: exit code arrives via tryWait' ($joined -match 'ok - production owner: exit code via tryWait')
Assert 'A17 production owner: terminate leaves no shell and no holder' (($joined -match 'ok - production owner: terminate leaves no shell') -and ($joined -match 'ok - production owner: terminate leaves no holder'))

# T970: an owner that takes every byte and releases none, against a 4 KB ring.
# The owner itself sees no gap, so the holder is the only witness: it must log
# the drop and hand the running total to the next owner in HELLO.
Assert 'A18 unreleased drop: the owner saw no gap (only the holder can see this loss)' ($joined -match 'ok - unreleased-drop: the owner saw no gap')
Assert 'A19 unreleased drop: the next owner''s HELLO carries a non-zero total' (($joined -match 'ok - unreleased-drop: the next owner''s HELLO carries the total') -and ($joined -match 'ok - unreleased-drop: the total is the flood'))
Assert 'A20 unreleased drop: the holder''s log names it' ($joined -match 'ok - unreleased-drop: the holder''s log names the drop')
$t970 = @($smokeOut | Where-Object { $_ -match 'unreleased-drop: the (next owner|total)' })
foreach ($l in $t970) { "    $l" }

# --- Section B: the control pipe is owner-only ------------------------------
#
# Derive the real pipe naming (including the [-debug] segment) from the pipe
# name the smoke's holders logged, then stand up one more holder and read the
# DACL off its live pipe.

$pipePrefix = $null
$pipeSep = '-'
foreach ($line in $smokeErr) {
    # The separator in front of the session id is `-` normally and `~` when
    # this process runs under a GHOZTTY_AGENT_INSTANCE lineage (T1594), so it
    # is CAPTURED rather than assumed - the same reason the `[-debug]` segment
    # is read back out of the log instead of being spelled out here.
    if ($line -match '\\\\\.\\pipe\\(ghoztty-pty-host\S*?)([-~])smoke-\d+-[ab]') {
        $pipePrefix = $Matches[1]
        $pipeSep = $Matches[2]
        break
    }
}
Assert 'B1 smoke log names the holder pipe (prefix derivable)' ($null -ne $pipePrefix)

if ($null -ne $pipePrefix) {
    $sid = "acc-$PID"
    $holder = Start-Process -FilePath $AgentExe `
        -ArgumentList @('--pty-host', '--session-id', $sid, '--exit-linger-ms', '3000') `
        -WindowStyle Hidden -PassThru
    $null = $holder.Handle  # exitcode-audit: holder is killed below; nothing scores its exit code
    try {
        $pipeName = "$pipePrefix$pipeSep$sid"
        $npc = New-Object System.IO.Pipes.NamedPipeClientStream('.', $pipeName, ([System.IO.Pipes.PipeDirection]::InOut))
        $connected = $false
        for ($i = 0; $i -lt 50 -and -not $connected; $i++) {
            try { $npc.Connect(200); $connected = $true } catch { Start-Sleep -Milliseconds 100 }
        }
        Assert 'B2 holder pipe accepts this user' $connected
        if ($connected) {
            $acl = $npc.GetAccessControl()
            $rules = @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))
            $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
            $allowRules = @($rules | Where-Object { $_.AccessControlType -eq 'Allow' })
            $foreign = @($allowRules | Where-Object { $_.IdentityReference -ne $me })
            Assert 'B3 the pipe DACL has at least one ACE' ($rules.Count -ge 1)
            Assert 'B4 every allow ACE names the current user (owner-only)' ($allowRules.Count -ge 1 -and $foreign.Count -eq 0)
        } else {
            Assert 'B3 the pipe DACL has at least one ACE' $false
            Assert 'B4 every allow ACE names the current user (owner-only)' $false
        }
        if ($null -ne $npc) { $npc.Dispose() }
    } finally {
        try { Stop-Process -Id $holder.Id -Force -ErrorAction SilentlyContinue } catch {}
    }
}

# --- Section C: an idle holder sleeps; an exited shell still ends it (T3021) --
#
# The exit poller used to wake five times a second for the shell's whole life
# (and twice a second through the linger), in every holder process. It now
# waits on the shell's process handle and on a condition, so an idle holder
# with an idle shell should barely be scheduled at all. Measured as the sum of
# the holder's per-thread context switches (SystemProcessInformation) at both
# ends of the span. C2/C3 prove the wait still ends: a shell that exits on its
# own takes its holder down once the ownerless linger runs out - not before.

if (-not ('HolderThreadCtx' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class HolderThreadCtx {
    [DllImport("ntdll.dll")] static extern int NtQuerySystemInformation(int cls, IntPtr buf, int len, out int ret);
    // SystemProcessInformation (class 5), x64: NumberOfThreads at 0x04,
    // UniqueProcessId at 0x50, process record 0x100 bytes, then 0x50-byte
    // thread records with ClientId.UniqueThread at 0x30 and ContextSwitches
    // at 0x40 (the layout scripts\perf-baseline.ps1's PerfSnap reads).
    // Returns [tid, switches, tid, switches, ...], or null when the pid is
    // not found. Per THREAD, because a thread that exits inside the span
    // takes its count out of a process total (a negative rate, 2026-11-16).
    public static long[] Threads(int pid) {
        int len = 4 << 20;
        for (int tries = 0; tries < 6; tries++) {
            IntPtr buf = Marshal.AllocHGlobal(len);
            try {
                int ret;
                int st = NtQuerySystemInformation(5, buf, len, out ret);
                if ((uint)st == 0xC0000004u) { len *= 2; continue; }
                if (st != 0) return null;
                long p = buf.ToInt64();
                while (true) {
                    int next = Marshal.ReadInt32(new IntPtr(p));
                    long id = Marshal.ReadIntPtr(new IntPtr(p + 0x50)).ToInt64();
                    if (id == pid) {
                        int n = Marshal.ReadInt32(new IntPtr(p + 4));
                        long[] r = new long[n * 2];
                        for (int i = 0; i < n; i++) {
                            long t = p + 0x100 + i * 0x50;
                            r[i * 2] = Marshal.ReadIntPtr(new IntPtr(t + 0x30)).ToInt64();
                            r[i * 2 + 1] = (uint)Marshal.ReadInt32(new IntPtr(t + 0x40));
                        }
                        return r;
                    }
                    if (next == 0) return null;
                    p += next;
                }
            } finally { Marshal.FreeHGlobal(buf); }
        }
        return null;
    }
}
'@
}

$idle = Start-Process -FilePath $AgentExe `
    -ArgumentList @('--pty-host', '--session-id', "idle-$PID", '--exit-linger-ms', '3000') `
    -WindowStyle Hidden -PassThru
$null = $idle.Handle  # exitcode-audit: holder is killed below; nothing scores its exit code
try {
    Start-Sleep -Seconds $IdleSettleSeconds   # shell startup output, prompt, first paint
    $t0 = [HolderThreadCtx]::Threads($idle.Id)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Start-Sleep -Seconds $IdleSeconds
    $t1 = [HolderThreadCtx]::Threads($idle.Id)
    $sec = $sw.Elapsed.TotalSeconds
    $alive = -not $idle.HasExited
    Assert 'C0 the idle holder stayed up through the measurement' ($alive -and $null -ne $t0 -and $null -ne $t1)
    # Threads alive at the end: their growth since the start, or their whole
    # count when they were born inside the span. Exited threads are lost
    # either way; one that came and went inside the span is not seen at all.
    $before = @{}
    if ($null -ne $t0) { for ($i = 0; $i -lt $t0.Length; $i += 2) { $before[[long]$t0[$i]] = [long]$t0[$i + 1] } }
    $delta = 0L; $threads = 0
    if ($null -ne $t1) {
        for ($i = 0; $i -lt $t1.Length; $i += 2) {
            $tid = [long]$t1[$i]; $now = [long]$t1[$i + 1]; $threads++
            $delta += $(if ($before.ContainsKey($tid)) { $now - $before[$tid] } else { $now })
        }
    }
    $rate = if ($null -ne $t0 -and $null -ne $t1) { [math]::Round($delta / $sec, 2) } else { -1 }
    "    idle holder pid $($idle.Id): $delta context switch(es) across $threads thread(s) over $([math]::Round($sec, 1)) s = $rate/s (was ~5/s from the 200 ms exit poll alone)"
    Assert "C1 an idle holder is scheduled under $IdleMaxPerSec times a second ($rate/s)" ($rate -ge 0 -and $rate -lt $IdleMaxPerSec)
} catch {
    # An unwind here must score, never skip C1 on the way to the verdict.
    "  FAIL C1 the idle measurement threw: $($_.Exception.Message)"; $script:failures++
} finally {
    try { Stop-Process -Id $idle.Id -Force -ErrorAction SilentlyContinue } catch {}
}

# The shell runs a short command and exits by itself; no owner ever connects,
# so the holder must notice the exit (event wait) and then outlive it by the
# linger (timed condition wait) - and not by much more.
$lingerMs = 2000
$started = [Diagnostics.Stopwatch]::StartNew()
# Start-Process joins -ArgumentList unquoted, so the command carries its own quotes.
$ex = Start-Process -FilePath $AgentExe `
    -ArgumentList @('--pty-host', '--session-id', "exit-$PID", '--exit-linger-ms', "$lingerMs", '--command', '"ping -n 2 127.0.0.1"') `
    -WindowStyle Hidden -PassThru
$null = $ex.Handle  # exitcode-audit: the verdict is the holder's lifetime, not its exit code
try {
    $done = $ex.WaitForExit(20000)
    $life = $started.Elapsed.TotalMilliseconds
    "    exiting-shell holder lived $([math]::Round($life)) ms (shell ~1000 ms + linger $lingerMs ms)"
    Assert 'C2 a holder whose shell exited, with no owner, ends on its own' $done
    Assert "C3 ...but only after the $lingerMs ms linger ran out" ($done -and $life -ge $lingerMs)
} catch {
    "  FAIL C2 the exiting-shell check threw: $($_.Exception.Message)"; $script:failures++
} finally {
    if (-not $ex.HasExited) { try { Stop-Process -Id $ex.Id -Force -ErrorAction SilentlyContinue } catch {} }
}

Remove-Item $outLog, $errLog -ErrorAction SilentlyContinue

# --- stamp (T783)-----------------------------------------------------------
# A green run records the content of every file this harness covers, so
# scripts\guard-due.ps1 can answer "has anything run pty-host.ps1 against the
# code as it now stands?". A red run leaves the stamp alone - red must stay due.
Complete-TestBody  # T1039: before the stamp, which is a child process reading this run's state
if ($script:failures -eq 0) {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard pty-host -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-TestVerdict -Label 'PTY-HOST' -Pass $script:passes -Fail $script:failures
