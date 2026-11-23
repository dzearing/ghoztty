# T1721 acceptance: the session manager (ghoztty-agent) and its pty holders
# leave their warnings in a FILE on Windows, not only on a stderr nobody has.
#
# The app spawns the agent DETACHED through spawnEscapingJob with no std
# handles, and the agent spawns each holder the same way, so before T1721
# every std.log line either of them raised - holder replay gaps, the T970
# "dropped ... not yet saved" warning, adoption failures - went nowhere on a
# user's box. The Mac's LaunchAgent redirects the agent's stdout/stderr to
# <agent state dir>/agent.log; the Windows translation is the process appending
# to that same file itself:
#
#   %LOCALAPPDATA%\ghoztty\local-agent[-debug][-<instance>]\agent.log
#
# bounded by log_rotate's two generations (agent.log + agent.log.1).
#
# Arms, all on the repo's Debug agent, hermetic (a per-run LOCALAPPDATA and
# GHOZTTY_AGENT_INSTANCE, no window, no pipe, nothing else launched):
#   A. An agent warning (GHOSTTY_AGENT_SUPPRESS_CAPS, raised on every start)
#      lands in agent.log in this lineage's own state dir, carries the T270
#      stamp and the agent's pid, and is still written to stderr as before.
#   B. A holder's error (--pty-host with an invalid session id) lands in the
#      same file, tagged "holder", and still reaches stderr.
#   C. The file is bounded: an agent.log already at the 4 MiB bound becomes
#      agent.log.1 on the next line, and the new line starts a fresh live file.
#   D. The sink is the lineage's alone: nothing is written to the app's
#      ghoztty-debug.log, and no other state dir is created.
#
#   powershell -NoProfile -File test\win32\agent-log.ps1
#
# @lineage-safe - hermetic: its own LOCALAPPDATA and GHOZTTY_AGENT_INSTANCE, and the Remove-Item in finally restores the caller's lineage (T2006)
param(
    [string]$AgentExe = (Join-Path $PSScriptRoot '..\..\zig-out\bin\ghoztty-agent.exe')
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')  # T1036: Assert-GhozttyIsolatedAgent

$script:failures = 0
$script:passes = 0
$script:skipped = 0
function Assert($name, $cond) {
    if ($cond) { Write-Host "  PASS $name"; $script:passes++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:failures++ }
}
function Say($m) { Write-Host $m }

$AgentExe = [System.IO.Path]::GetFullPath($AgentExe)
if (-not (Test-Path $AgentExe)) {
    Say "SKIP: no agent at $AgentExe - build it: zig build -Dapp-runtime=win32 -Doptimize=Debug"
    $script:skipped++
    Write-TestVerdict -Pass $script:passes -Fail $script:failures -Skipped $script:skipped -Label 'AGENT-LOG'
}
# A release agent here would derive the user's endpoints; refuse it before
# anything launches (the launch-preflight-audit C2 rule).
Assert-GhozttyIsolatedAgent -Exe $AgentExe | Out-Null

$root = Join-Path $env:TEMP "ghoztty-agent-log-$PID"
$instance = "alog$PID"
$saved = @{
    LOCALAPPDATA = $env:LOCALAPPDATA
    INSTANCE     = $env:GHOZTTY_AGENT_INSTANCE
    SUPP         = $env:GHOSTTY_AGENT_SUPPRESS_CAPS
}

# One agent process, its stdout/stderr captured, bounded in time. The handle is
# cached before the child can exit (the PS5.1 ExitCode trap).
function Invoke-Agent([string[]]$argv, [string]$tag) {
    $out = Join-Path $root "$tag.out"
    $p = Start-Process -FilePath $AgentExe -ArgumentList $argv -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $out -RedirectStandardError "$out.err"
    $null = $p.Handle
    if (-not $p.WaitForExit(20000)) {
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        return $null
    }
    $p.WaitForExit()
    $err = if (Test-Path "$out.err") { Get-Content "$out.err" -Raw } else { '' }
    return [pscustomobject]@{ Pid = $p.Id; Stderr = [string]$err }
}

try {
    New-Item -ItemType Directory -Force $root | Out-Null
    $env:LOCALAPPDATA = $root
    $env:GHOZTTY_AGENT_INSTANCE = $instance

    $mode = (& $AgentExe --build-mode 2>$null | Out-String)
    if ($mode -notmatch 'endpoints\s*:\s*debug') {
        Say "SKIP: $AgentExe is not a Debug build ($($mode.Trim())); this harness measures the debug lineage"
        $script:skipped++
        throw 'not-debug'
    }

    $stateDir = Join-Path $root "ghoztty\local-agent-debug-$instance"
    $log = Join-Path $stateDir 'agent.log'
    $stampRe = '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z \d+ '

    # --- A: an agent warning lands in agent.log ----------------------------
    Say "A. agent warning -> agent.log"
    $env:GHOSTTY_AGENT_SUPPRESS_CAPS = 'repaint_data'
    $a = Invoke-Agent @('--version') 'a'
    Remove-Item Env:GHOSTTY_AGENT_SUPPRESS_CAPS -ErrorAction SilentlyContinue
    Assert 'A0 the agent ran and exited' ($null -ne $a)
    $lines = @(if (Test-Path $log) { Get-Content $log })
    $warn = @($lines | Where-Object { $_ -match 'warning: advertising a REDUCED capability set \(suppressed: repaint_data\)' })
    Assert "A1 the warning is in $log" ($warn.Count -eq 1)
    Assert 'A2 it carries the T270 stamp' ($warn.Count -eq 1 -and $warn[0] -match $stampRe)
    Assert 'A3 the stamp names the agent''s own pid' ($null -ne $a -and $warn.Count -eq 1 -and $warn[0] -match "Z $($a.Pid) warning")
    Assert 'A4 an agent line is not tagged holder' ($warn.Count -eq 1 -and $warn[0] -notmatch ' holder ')
    Assert 'A5 stderr still carries the warning' ($null -ne $a -and $a.Stderr -match 'advertising a REDUCED capability set')

    # --- B: a holder's error lands in the same file, tagged ----------------
    Say "B. holder error -> agent.log"
    $b = Invoke-Agent @('--pty-host', '--session-id', 'bad!id') 'b'
    Assert 'B0 the holder ran and exited' ($null -ne $b)
    $lines = @(if (Test-Path $log) { Get-Content $log })
    $herr = @($lines | Where-Object { $_ -match "holder error\(pty_host\): invalid --session-id 'bad!id'" })
    Assert 'B1 the holder error is in agent.log' ($herr.Count -eq 1)
    Assert 'B2 it is stamped with the holder''s pid' ($null -ne $b -and $herr.Count -eq 1 -and $herr[0] -match "$stampRe" -and $herr[0] -match "Z $($b.Pid) holder ")
    Assert 'B3 stderr still carries it' ($null -ne $b -and $b.Stderr -match 'invalid --session-id')
    $bad = @($lines | Where-Object { $_ -notmatch $stampRe })
    Assert "B4 every line in the file has the stamp shape ($($lines.Count) lines)" ($lines.Count -ge 2 -and $bad.Count -eq 0)

    # --- C: bounded by log_rotate's two generations ------------------------
    Say "C. agent.log is bounded"
    $max = 4 * 1024 * 1024
    $fill = New-Object byte[] $max
    for ($i = 0; $i -lt $max; $i++) { $fill[$i] = 0x61 }
    [System.IO.File]::WriteAllBytes($log, $fill)
    $env:GHOSTTY_AGENT_SUPPRESS_CAPS = 'repaint_data'
    $c = Invoke-Agent @('--version') 'c'
    Remove-Item Env:GHOSTTY_AGENT_SUPPRESS_CAPS -ErrorAction SilentlyContinue
    $rot = Join-Path $stateDir 'agent.log.1'
    Assert 'C0 the agent ran and exited' ($null -ne $c)
    Assert 'C1 the full file was archived as agent.log.1' ((Test-Path $rot) -and (Get-Item $rot).Length -ge $max)
    # The line that crossed the bound is in the archive (rotation is asked after
    # the write); the next line starts the fresh live file.
    $c2 = Invoke-Agent @('--pty-host', '--session-id', 'bad!id2') 'c2'
    $live = @(if (Test-Path $log) { Get-Content $log })
    Assert 'C2 the next line starts a fresh, small live agent.log' ((Test-Path $log) -and (Get-Item $log).Length -lt 64KB -and @($live | Where-Object { $_ -match "bad!id2" }).Count -eq 1)
    Assert 'C3 exactly two generations exist' (@(Get-ChildItem $stateDir -Filter 'agent.log*').Count -eq 2)

    # --- D: the sink is this lineage's alone -------------------------------
    Say "D. no other sink is written"
    Assert 'D1 the app''s ghoztty-debug.log was not written' (-not (Test-Path (Join-Path $root 'ghoztty\ghoztty-debug.log')))
    $dirs = @(Get-ChildItem (Join-Path $root 'ghoztty') -Directory | ForEach-Object { $_.Name })
    Assert "D2 only this lineage's state dir exists ($($dirs -join ', '))" ($dirs.Count -eq 1 -and $dirs[0] -eq "local-agent-debug-$instance")
} catch {
    if ("$_" -ne 'not-debug') { Say "  ERROR $_"; $script:failures++ }
} finally {
    $env:LOCALAPPDATA = $saved.LOCALAPPDATA
    if ($null -ne $saved.INSTANCE) { $env:GHOZTTY_AGENT_INSTANCE = $saved.INSTANCE } else { Remove-Item Env:GHOZTTY_AGENT_INSTANCE -ErrorAction SilentlyContinue }
    if ($null -ne $saved.SUPP) { $env:GHOSTTY_AGENT_SUPPRESS_CAPS = $saved.SUPP } else { Remove-Item Env:GHOSTTY_AGENT_SUPPRESS_CAPS -ErrorAction SilentlyContinue }
}

Complete-TestBody
if ($script:failures -eq 0 -and $script:skipped -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot '..\..\scripts\guard-due.ps1') `
        update -Guard agent-log -Repo (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path 2>&1 |
        ForEach-Object { Write-Host "  $_" }
}

Say ""
Write-TestVerdict -Pass $script:passes -Fail $script:failures -Skipped $script:skipped -Label 'AGENT-LOG'
