<#
.SYNOPSIS
    T1814 acceptance - with a fullscreen app in front, no automated run takes
    the foreground from it: not a declared input-desktop exception script, and
    not a soak-daemon round.

.DESCRIPTION
    The claim T1795 made and could not prove while the user was at the box.
    On 2026-09-27 two input-desktop scripts and the soak daemon ran over the
    user's fullscreen game. T1794/T1795 added the presence gate
    (lib\UserPresence.ps1) and moved soak rounds onto the lane desktop. This
    script checks both against a real fullscreen window, by watching the
    foreground hwnd rather than reading the code.

      A. (always) The exception list in lib\TestDesktop.ps1 parses and every
         declared script exists. Section C runs exactly this list, so a
         declaration added later is covered without editing this file.

    The live sections run ONLY with -Live, and only when nobody is at the box.
    Five idle minutes is not absence (frame-lab's lesson, 2026-10-28), so a
    sweep never runs them:

      B. A stand-in fullscreen window (a borderless form covering the primary
         monitor, in a System32 powershell.exe so it does not read as one of
         ours) is brought to the front. The presence probe must then report a
         person, and `soak-daemon.ps1 busy` must say BUSY user present.
      C. Every declared exception script runs under the stand-in. Each must
         end as SKIP ALL, within its timeout, while a 20 ms foreground sampler
         sees the stand-in in front the whole time.
      D. The soak daemon, gate left on: one `run -MaxRounds 1` against a
         private state dir must start no round. Then one FULL round (the
         win32-releasesafe lane, the one whose tests open banner windows) with
         presence forced absent, so the round really runs. The foreground must
         not move during it: rounds belong on the lane desktop (T1813).
      E. The negative control. Presence forced absent, one exception script
         that grabs the foreground (context-menu-real-input.ps1) runs under the
         stand-in, and the sampler MUST see the foreground leave it. This
         proves section C's quiet sampler could have seen a steal.

    Only this script sets GHOZTTY_TEST_FORCE_USER_PRESENCE outside
    test-desktop-harness.ps1, and only for its own children in D and E.

    ASCII-only by design (PS 5.1 on this box mangles non-ASCII on rewrite).

    powershell -NoProfile -File test\win32\fullscreen-guard.ps1 [-Live] [-SkipSoakRound]

.NOTES
    # persistence: launches the repo's zig-out app only through the section-C
    # and section-E child scripts, each of which isolates itself.

    The stand-in grabs the foreground on purpose, after Assert-UserAbsent, and
    only with -Live: this script is a declared input-desktop exception.
#>
[CmdletBinding()]
param(
    [switch]$Live,
    # Section D's full round costs minutes (a ReleaseSafe win32 lane).
    [switch]$SkipSoakRound,
    [ValidateRange(30, 1800)][int]$ScriptTimeoutSeconds = 240,
    [ValidateRange(60, 7200)][int]$RoundTimeoutSeconds = 2400
)

$ErrorActionPreference = 'Continue'
$Repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\UserPresence.ps1')
. (Join-Path $Repo 'scripts\lib\ProcessFamily.ps1')

$script:passes = 0
$script:failures = 0
$script:skipped = 0

function Assert([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { $script:passes++; Write-Host "  PASS $Name" }
    else { $script:failures++; Write-Host ("  FAIL $Name" + $(if ($Detail) { " - $Detail" } else { '' })) }
}
function Skip([string]$Name, [string]$Why) { $script:skipped++; Write-Host "  SKIP $Name - $Why" }

# ---- A. the exception list -------------------------------------------------
''
'A. the declared input-desktop exceptions'
$declared = @(Select-String -Path (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1') `
        -Pattern '^# @input-desktop-exception: (\S+\.ps1)' |
    ForEach-Object { $_.Matches[0].Groups[1].Value } | Select-Object -Unique)
Assert 'A1 the exception list parses to at least one script' ($declared.Count -ge 1) "found $($declared.Count)"
$missing = @($declared | Where-Object { -not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $_)) })
Assert 'A2 every declared exception script exists' ($missing.Count -eq 0) ($missing -join ', ')
Assert 'A3 this script is declared too (it puts a window on the input desktop)' ($declared -contains 'fullscreen-guard.ps1')

if (-not $Live) {
    ''
    '  SKIP B/C/D/E (live) - pass -Live to run them; a sweep never does'
    $script:skipped += 4
    Complete-TestBody
    Write-TestVerdict -Label 'FULLSCREEN GUARD' -Pass $script:passes -Fail $script:failures -Skipped $script:skipped
    exit $LASTEXITCODE
}

# Everything below puts a window on the user's screen.
Assert-UserAbsent
# A FORCE value inherited from the caller would fake every verdict below.
Remove-Item Env:\GHOZTTY_TEST_FORCE_USER_PRESENCE -ErrorAction SilentlyContinue

if (-not ('GfgWatch' -as [type])) {
Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class GfgWatch {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);

    static Thread worker;
    static volatile bool running;
    static readonly object gate = new object();
    static List<string> changes = new List<string>();
    static IntPtr last = IntPtr.Zero;

    public static string Describe(IntPtr h) {
        if (h == IntPtr.Zero) return "0x0 (none)";
        uint pid; GetWindowThreadProcessId(h, out pid);
        StringBuilder sb = new StringBuilder(256); GetClassName(h, sb, sb.Capacity);
        return String.Format("0x{0:x} pid {1} class {2}", h.ToInt64(), pid, sb);
    }

    // Changes away from the hwnd the window had when Start ran.
    public static void Start(int periodMs) {
        Stop();
        lock (gate) { changes = new List<string>(); last = GetForegroundWindow(); }
        running = true;
        worker = new Thread(() => {
            while (running) {
                IntPtr h = GetForegroundWindow();
                if (h != last) {
                    lock (gate) { changes.Add(DateTime.Now.ToString("HH:mm:ss.fff") + " " + Describe(h)); last = h; }
                }
                Thread.Sleep(periodMs);
            }
        });
        worker.IsBackground = true;
        worker.Start();
    }

    public static string[] Stop() {
        running = false;
        if (worker != null) { worker.Join(2000); worker = null; }
        lock (gate) { return changes.ToArray(); }
    }

    // A background process may not take the foreground on request; attaching
    // to the current owner's input queue is the documented way round it. The
    // Alt tap (the last-input source) is the T86 fallback, used only if the
    // attach alone did not work.
    public static bool Grab(IntPtr top) {
        uint cur = GetCurrentThreadId();
        for (int attempt = 0; attempt < 6; attempt++) {
            if (GetForegroundWindow() == top) return true;
            IntPtr fg = GetForegroundWindow();
            uint fgTid = 0;
            if (fg != IntPtr.Zero && fg != top) { uint p; fgTid = GetWindowThreadProcessId(fg, out p); }
            if (fgTid != 0) AttachThreadInput(cur, fgTid, true);
            if (attempt >= 3) { keybd_event(0x12, 0, 0, UIntPtr.Zero); keybd_event(0x12, 0, 2, UIntPtr.Zero); }
            BringWindowToTop(top);
            SetForegroundWindow(top);
            if (fgTid != 0) AttachThreadInput(cur, fgTid, false);
            Thread.Sleep(150 + attempt * 150);
        }
        return GetForegroundWindow() == top;
    }
}
'@
}

$Scratch = Join-Path $Repo ('temp\fullscreen-guard\' + (Get-Date).ToString('yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $Scratch | Out-Null
$HwndFile = Join-Path $Scratch 'standin.hwnd'
$QuitFile = Join-Path $Scratch 'standin.quit'
$StandinScript = Join-Path $Scratch 'standin.ps1'
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

# The stand-in: what a borderless-windowed game looks like to the probe.
@"
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
`$f = New-Object System.Windows.Forms.Form
`$f.Text = 'T1814 fullscreen stand-in'
`$f.FormBorderStyle = 'None'
`$f.StartPosition = 'Manual'
`$f.Bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
`$f.BackColor = [System.Drawing.Color]::FromArgb(24, 24, 32)
`$t = New-Object System.Windows.Forms.Timer
`$t.Interval = 200
`$t.Add_Tick({ if (Test-Path -LiteralPath '$QuitFile') { `$f.Close() } })
`$f.Add_Shown({ `$f.Activate(); [IO.File]::WriteAllText('$HwndFile', [string]`$f.Handle.ToInt64()); `$t.Start() })
[System.Windows.Forms.Application]::Run(`$f)
"@ | Set-Content -LiteralPath $StandinScript -Encoding ASCII

$standin = $null
$hwnd = [IntPtr]::Zero
function Restore-Standin {
    if ($hwnd -ne [IntPtr]::Zero -and [GfgWatch]::IsWindow($hwnd)) { [void][GfgWatch]::Grab($hwnd) }
}

# Run one child script under the sampler. Returns { Code, Out, Steals, TimedOut }.
function Invoke-Watched {
    param([string]$Script, [string[]]$Arguments = @(), [int]$TimeoutSeconds, [hashtable]$Env = @{})
    $log = Join-Path $Scratch ((Split-Path -Leaf $Script) + '.' + (Get-Random) + '.log')
    $saved = @{}
    foreach ($k in $Env.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $Env[$k]) }
    Restore-Standin
    [GfgWatch]::Start(20)
    $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $Script + '"')) + $Arguments
    $cmd = '"' + $ps + '" ' + ($argv -join ' ') + ' > "' + $log + '" 2>&1'
    $p = Start-Process -FilePath $env:ComSpec -ArgumentList @('/s', '/c', ('"' + $cmd + '"')) -WindowStyle Hidden -PassThru
    $null = $p.Handle
    $timedOut = -not $p.WaitForExit($TimeoutSeconds * 1000)
    if ($timedOut) { $null = Stop-ProcessFamily -Id $p.Id }
    $steals = @([GfgWatch]::Stop())
    foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
    $out = if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log -Raw } else { '' }
    return [pscustomobject]@{ Code = $p.ExitCode; Out = [string]$out; Steals = $steals; TimedOut = $timedOut; Log = $log }
}

try {
    # ---- B. the stand-in is in front, and the probe sees a person -----------
    ''
    'B. a fullscreen stand-in in front of everything'
    $standin = Start-Process -FilePath $ps -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $StandinScript + '"')) -PassThru
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline -and -not (Test-Path -LiteralPath $HwndFile)) { Start-Sleep -Milliseconds 100 }
    if (Test-Path -LiteralPath $HwndFile) { $hwnd = [IntPtr][long](Get-Content -LiteralPath $HwndFile -Raw).Trim() }
    Assert 'B1 the stand-in window came up' ($hwnd -ne [IntPtr]::Zero)
    $inFront = ($hwnd -ne [IntPtr]::Zero) -and [GfgWatch]::Grab($hwnd)
    Assert 'B2 the stand-in holds the foreground' $inFront ([GfgWatch]::Describe([GfgWatch]::GetForegroundWindow()))
    if (-not $inFront) { throw 'SETUP: the stand-in could not take the foreground; C/D/E would measure nothing' }

    $pr = Get-UserPresence
    Assert 'B3 the presence probe reports a person' ($pr.Present -and -not $pr.Forced) $pr.Reason
    Assert 'B4 ...because of the fullscreen window' ($pr.Reason -match 'covers its whole monitor|fullscreen app') $pr.Reason
    # A private state dir: the box's own daemon may be paused, and a pause is
    # answered before presence is asked.
    $busy = & $ps -NoProfile -File (Join-Path $Repo 'scripts\soak-daemon.ps1') busy -StateDir (Join-Path $Scratch 'soak-busy') 2>&1 | ForEach-Object { "$_" } | Out-String
    $busyCode = $LASTEXITCODE
    Assert 'B5 soak-daemon busy says BUSY user present' ($busyCode -eq 3 -and $busy -match 'BUSY user present') $busy.Trim()

    # ---- C. every exception script skips, and the foreground never moves ----
    ''
    "C. every declared exception script, under the stand-in ($($declared.Count))"
    foreach ($s in $declared) {
        if ($s -eq 'fullscreen-guard.ps1') { continue }
        $args2 = @()
        if ($s -eq 'frame-lab.ps1') { $args2 = @('-Live') }   # without -Live it never reaches the gate
        $r = Invoke-Watched -Script (Join-Path $PSScriptRoot $s) -Arguments $args2 -TimeoutSeconds $ScriptTimeoutSeconds
        $last = (($r.Out -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -Last 1)
        Assert "C $s ends in time" (-not $r.TimedOut) "killed at ${ScriptTimeoutSeconds}s; log $($r.Log)"
        # rdp-session asks SM_REMOTESESSION first and ends as `SKIP whole run`
        # on a console session, before it starts anything - also not a steal.
        Assert "C $s skips (SKIP ALL)" ($r.Out -match 'SKIP ALL|SKIP whole run') "last line: $last"
        $why = (($r.Out -split "`r?`n") | Where-Object { $_ -match 'SKIP (ALL|whole run)' } | Select-Object -First 1)
        if ($why) { Write-Host "    $($why.Trim())" }
        Assert "C $s leaves the foreground alone" ($r.Steals.Count -eq 0) ($r.Steals -join '; ')
    }

    # ---- D. the soak daemon -------------------------------------------------
    ''
    'D. the soak daemon under the stand-in'
    # The daemon yields to any process naming test\win32\ - which includes this
    # script and whatever started it. Ours are not foreign work.
    $own = New-Object System.Collections.Generic.List[int]
    $cur = $PID
    for ($i = 0; $i -lt 8 -and $cur; $i++) {
        $own.Add([int]$cur)
        $cur = (Get-CimInstance Win32_Process -Filter "ProcessId=$cur" -ErrorAction SilentlyContinue).ParentProcessId
    }
    $ignore = ($own -join ',')
    $daemon = Join-Path $Repo 'scripts\soak-daemon.ps1'
    $stateGate = Join-Path $Scratch 'soak-gate'
    $r = Invoke-Watched -Script $daemon -TimeoutSeconds 120 -Arguments @('run', '-MaxRounds', '1',
        '-Lanes', 'win32-releasesafe', '-StateDir', ('"' + $stateGate + '"'), '-IgnorePids', $ignore,
        '-YieldPollSeconds', '1', '-IdleWaitSeconds', '1', '-QuitAfterBusySeconds', '5')
    $ledger = Join-Path $stateGate 'ledger.jsonl'
    $rows = @(if (Test-Path -LiteralPath $ledger) { Get-Content -LiteralPath $ledger | Where-Object { $_.Trim() } })
    Assert 'D1 with the gate on, the daemon quits without starting a round' (-not $r.TimedOut -and $rows.Count -eq 0) "ledger rows: $($rows.Count)"
    Assert 'D2 ...and leaves the foreground alone' ($r.Steals.Count -eq 0) ($r.Steals -join '; ')

    if ($SkipSoakRound) {
        Skip 'D3-D5 a full round under the stand-in' 'by -SkipSoakRound'
    } else {
        # The daemon yields to ANY foreground work, including the other loop
        # lane's builds (correct, and not what this section measures), so a
        # round that yielded to foreign work is retried a few times.
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            $stateRun = Join-Path $Scratch "soak-round-$attempt"
            $r = Invoke-Watched -Script $daemon -TimeoutSeconds ($RoundTimeoutSeconds + 120) -Env @{ GHOZTTY_TEST_FORCE_USER_PRESENCE = 'absent' } -Arguments @(
                'run', '-MaxRounds', '1', '-Lanes', 'win32-releasesafe', '-StateDir', ('"' + $stateRun + '"'),
                '-IgnorePids', $ignore, '-RoundTimeoutSeconds', $RoundTimeoutSeconds, '-IdleWaitSeconds', '1')
            $ledger = Join-Path $stateRun 'ledger.jsonl'
            $row = @(if (Test-Path -LiteralPath $ledger) { Get-Content -LiteralPath $ledger | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json } }) | Select-Object -Last 1
            $outcome = if ($row) { [string]$row.outcome } else { '(none)' }
            if (-not ($outcome -eq 'yielded' -and [string]$row.detail -match 'foreground work')) { break }
            Write-Host "    attempt ${attempt}: yielded after $($row.seconds)s to $($row.detail)"
            if ($r.Steals.Count -gt 0) { break }   # a steal is the finding, whatever the outcome
            Start-Sleep -Seconds 30
        }
        if ($row -and $outcome -eq 'yielded' -and [string]$row.detail -match 'foreground work' -and $r.Steals.Count -eq 0) {
            Skip 'D3-D5 a full round under the stand-in' "the round yielded to foreign work on the box: $($row.detail)"
        } else {
            Assert 'D3 the forced-absent round ran to an outcome' ($outcome -in @('pass', 'fail', 'crash')) "outcome $outcome $(if ($row) { $row.detail })"
            Write-Host ("    round: lane {0} outcome {1} {2}s" -f $row.lane, $outcome, $row.seconds)
            Assert 'D4 the round ended in time' (-not $r.TimedOut)
            Assert 'D5 a full round never took the foreground' ($r.Steals.Count -eq 0) ($r.Steals -join '; ')
        }
    }

    # ---- E. negative control: with the gate forced off, the steal is seen ---
    ''
    'E. negative control: the gate forced off'
    $r = Invoke-Watched -Script (Join-Path $PSScriptRoot 'context-menu-real-input.ps1') -TimeoutSeconds $ScriptTimeoutSeconds `
        -Env @{ GHOZTTY_TEST_FORCE_USER_PRESENCE = 'absent' }
    Assert 'E1 the script did not skip on presence' ($r.Out -notmatch 'somebody is using this box') (($r.Out -split "`r?`n" | Where-Object { $_ -match 'SKIP' }) -join ' | ')
    Assert 'E2 the sampler saw the foreground leave the stand-in' ($r.Steals.Count -ge 1) 'no foreground change seen - section C proves nothing'
    foreach ($st in $r.Steals) { Write-Host "    foreground -> $st" }
    Complete-TestBody
} catch {
    $script:failures++
    Write-Host "  FAIL $($_.Exception.Message)"
} finally {
    [void][GfgWatch]::Stop()
    Set-Content -LiteralPath $QuitFile -Value 'quit' -Encoding ASCII -ErrorAction SilentlyContinue
    if ($standin) {
        if (-not $standin.WaitForExit(5000)) { $null = Stop-ProcessFamily -Id $standin.Id }
    }
}

# A green run stamps the covered files (T783); red or skipped stays due.
if ($script:failures -eq 0 -and $script:skipped -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard fullscreen-guard -Repo $Repo 2>&1 | ForEach-Object { "  $_" }
}

''
"  logs: $Scratch"
Write-TestVerdict -Label 'FULLSCREEN GUARD' -Pass $script:passes -Fail $script:failures -Skipped $script:skipped
exit $LASTEXITCODE
