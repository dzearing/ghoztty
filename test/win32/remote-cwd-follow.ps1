# T1741 acceptance: a `cd` in a DIALED pane whose shell reports nothing reaches
# `+list --json`, through the agent's T1583 `META{cwd}` push alone.
#
#   powershell -NoProfile -File test\win32\remote-cwd-follow.ps1
#
# WHY THIS EXISTS. T1583 made the agent push `META{cwd}` when a session's
# working directory moves, and the pane apply it unless the shell reports
# OSC 7 itself. Each hop has a unit test (agent push-on-change in server.zig,
# connection routing in connection.zig, ring hand-off in inbound_ring.zig), but
# nothing drove the whole path on the box: a dialed cmd.exe with no OSC 7, and
# no local pid for the app to read, a real `cd`, and then what a script sees.
#
# THE OTHER HALF lives in `remote-reconnect-fresh.ps1` arm D: a cross-machine
# window is never in the session-layout manifest (`captureSessionLayout` skips
# `remote_dialed`), so where its recorded directory is SPENT is the Reconnect
# swap that opens fresh shells. That arm `cd`s one pane before the drop and
# asserts its fresh shell comes back there.
#
# THE FIXTURE. A loopback `ghoztty-agent --listen 127.0.0.1:<port>` stands in
# for the other machine, with its own state dir and NO inherited PROMPT (see
# section 0). The app runs on a private pipe suffix.
#
# WHAT IS ASSERTED
#   A0 the dialed shell really has no integration - asked of the shell itself,
#      because a PROMPT carrying OSC 7 makes B pass without the push.
#   A  baseline: `+list` names the marker ROOT at open, and NOT the sub
#      directory - the half that makes B mean something.
#   B  after `cd t1741-sub`, `+list --json` names the sub directory within the
#      agent's ~10 s cwd cadence (budget 30 s).
#   C  a SECOND `cd` (back to the root) is pushed too: the agent pushes on
#      CHANGE, not once, and the client does not latch the first value.
#
# NEGATIVE CONTROL. `-NegativeControl` inverts B's `+list` assertion (asserts
# the directory did NOT follow); that run MUST fail. Turning the push off in
# the product was considered and rejected: it would mean a test-only switch in
# the shipping agent, and A already proves the oracle can read a stale value.
#
# T211/T217: runs on a BACKGROUND Win32 desktop and asserts at the end that it
# never took the user's foreground. T248: the repo's app and agents are killed
# at setup through the shared clean slate.
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe',
    [int]$Port = 0,
    [int]$FollowTimeoutSec = 30,
    [switch]$NegativeControl,
    [switch]$Interactive
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:passes = 0
$tmp = Join-Path $env:TEMP "ghoztty-remote-cwd-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\FreePort.ps1')
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\AgentLineage.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$Port = Resolve-TestPort -Name 'agent' -Port $Port

function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ } else { "  FAIL $name"; $script:failures++ }
}

function Stop-DebugGhoztty {
    Reset-GhozttyTestState -Exe $Exe -SettleMs 1000 | Out-Null
}

function Get-ListObject {
    cmd /c "`"$Exe`" +list --json > `"$tmp\list.json`" 2>&1" | Out-Null
    try { return (Get-Content "$tmp\list.json" -Raw | ConvertFrom-Json) } catch { return $null }
}

# Every leaf terminal in `+list --json`, however deep the split tree. A leaf is
# the object that carries a pane `name`; windows carry `target` instead.
function Get-ListLeaves($node) {
    $out = New-Object System.Collections.ArrayList
    $stack = New-Object System.Collections.Stack
    if ($null -ne $node) { $stack.Push($node) }
    while ($stack.Count -gt 0) {
        $n = $stack.Pop()
        if ($n -is [System.Array]) { foreach ($x in $n) { if ($null -ne $x) { $stack.Push($x) } }; continue }
        if ($n -isnot [System.Management.Automation.PSCustomObject]) { continue }
        $props = @($n.PSObject.Properties.Name)
        if (($props -contains 'name') -and ($props -contains 'working_directory')) { [void]$out.Add($n) }
        foreach ($p in $n.PSObject.Properties) {
            $v = $p.Value
            if ($v -is [System.Array] -or $v -is [System.Management.Automation.PSCustomObject]) { $stack.Push($v) }
        }
    }
    return , $out.ToArray()
}

function Get-PaneNames {
    $names = @()
    foreach ($l in (Get-ListLeaves (Get-ListObject))) { if ([string]$l.name -ne '') { $names += [string]$l.name } }
    return $names
}

function Get-ListCwd([string]$pane) {
    foreach ($l in (Get-ListLeaves (Get-ListObject))) {
        if ([string]$l.name -eq $pane) { return [string]$l.working_directory }
    }
    return $null
}

# Poll `+list` until the pane's directory satisfies $pred. Returns the last
# value seen and how long it took, so a FAIL names what the oracle actually read.
function Wait-ListCwd([string]$pane, [scriptblock]$pred, [int]$timeoutSec) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $last = $null
    while ($sw.Elapsed.TotalSeconds -lt $timeoutSec) {
        $last = Get-ListCwd $pane
        if ($null -ne $last -and (& $pred $last)) { return @{ ok = $true; cwd = $last; sec = [math]::Round($sw.Elapsed.TotalSeconds, 1) } }
        Start-Sleep -Milliseconds 500
    }
    return @{ ok = $false; cwd = $last; sec = [math]::Round($sw.Elapsed.TotalSeconds, 1) }
}

function EndsWithDir([string]$path, [string]$dir) {
    if ([string]::IsNullOrEmpty($path)) { return $false }
    return ($path.TrimEnd('\', '/') -like "*\$dir") -or ($path.TrimEnd('\', '/') -like "*/$dir")
}

$saved = @{ lad = $env:LOCALAPPDATA; pipe = $env:GHOZTTY_PIPE_SUFFIX; lock = $env:GHOSTTY_AGENT_LOCK; bin = $env:GHOSTTY_LOCAL_AGENT_BIN; prompt = $env:PROMPT }

Stop-DebugGhoztty
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    $root = Join-Path $tmp 't1741-root'
    $sub = Join-Path $root 't1741-sub'
    New-Item -ItemType Directory -Force $sub | Out-Null
    $appState = Join-Path $tmp 'app-state'
    $remState = Join-Path $tmp 'remote-state'
    New-Item -ItemType Directory -Force (Get-GhozttyAgentStateDir -Root $appState) | Out-Null
    New-Item -ItemType Directory -Force (Get-GhozttyAgentStateDir -Root $remState) | Out-Null

    # Isolate the IPC endpoint so every oracle below answers about THIS app.
    $env:GHOZTTY_PIPE_SUFFIX = "-remcwd$PID"
    $env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe

    "== 0: a loopback agent (its own state dir) and an app with persistence on"
    $env:LOCALAPPDATA = $remState
    $env:GHOSTTY_AGENT_LOCK = Join-Path $tmp 'remote-agent.lock'
    # No inherited PROMPT. A script run from a Ghoztty cmd pane (the loop's own
    # shell is one) inherits the T512 integration PROMPT, OSC 7 included, and
    # the agent hands it to every cmd.exe it spawns - so the "other machine"
    # would report its own directory and the push would never be exercised.
    # A0 checks the shell itself, so a leak by any other route still fails.
    $env:PROMPT = $null
    $agent = Start-OnTestDesktop -Exe $AgentExe -Arguments @('--listen', "127.0.0.1:$Port", '--headless')
    $env:PROMPT = $saved.prompt
    $env:GHOSTTY_AGENT_LOCK = $saved.lock
    $env:LOCALAPPDATA = $appState
    Start-Sleep -Seconds 2
    Assert "loopback agent is running" (-not ($agent.Process -and $agent.Process.HasExited))

    # Persistence off: a cross-machine window is never in the session-layout
    # manifest (`captureSessionLayout` skips `remote_dialed`), so local
    # persistence would only add a restore this script never asked for.
    $app = Start-OnTestDesktop -Exe $Exe -Arguments @('--session-persistence=false') -StdErr (Join-Path $tmp 'app.err.txt')
    $win0 = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow' -TimeoutMs 40000
    Assert "GUI window is up" ($win0 -ne [IntPtr]::Zero)
    Assert "window is NOT enumerable on the interactive desktop" (-not (Test-TestDesktopLeak -ProcessId $app.Pid))
    Start-Sleep -Seconds 2
    $basePanes = @(Get-PaneNames)

    "== A: a dialed cmd.exe pane opened in the marker root"
    cmd /c "`"$Exe`" +new-remote-window --host=127.0.0.1 --port=$Port --name=rcwd `"--working-directory=$root`" >`"$tmp\open.txt`" 2>&1"
    Assert "open exit 0" ($LASTEXITCODE -eq 0)
    $pane = $null
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline -and -not $pane) {
        $new = @(Get-PaneNames | Where-Object { $basePanes -notcontains $_ })
        if ($new.Count -eq 1) { $pane = $new[0] } else { Start-Sleep -Milliseconds 500 }
    }
    Assert "the remote pane is listed" ($null -ne $pane)
    if (-not $pane) { throw "no remote pane appeared; open said: $(Get-Content "$tmp\open.txt" -Raw)" }

    # A0: the subject is a shell that does NOT report its own directory. Since
    # T512 cmd.exe can carry OSC 7 in an injected PROMPT, and a pane that has it
    # follows a `cd` through its own report without the agent push ever being
    # used - B would then pass for the wrong reason. Ask the shell itself.
    & $Exe +send-keys --target=rcwd "echo PR[%PROMPT%]OMPT" Enter 2>&1 | Out-Null
    $promptLine = $null
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline -and -not $promptLine) {
        cmd /c "`"$Exe`" +read --name=$pane --lines=60 > `"$tmp\prompt.txt`" 2>&1" | Out-Null
        $hit = @(Get-Content "$tmp\prompt.txt" -ErrorAction SilentlyContinue | Where-Object { $_ -match '^PR\[.*\]OMPT\s*$' })
        if ($hit.Count -gt 0) { $promptLine = $hit[-1] } else { Start-Sleep -Milliseconds 500 }
    }
    "  shell PROMPT: $promptLine"
    Assert "A0 the dialed shell answered the PROMPT probe" ($null -ne $promptLine)
    Assert "A0 and it carries no OSC 7 / 133 integration (the push is the only route)" `
        (($null -ne $promptLine) -and ($promptLine -notmatch '\]7;|\]133;|\$E\]'))

    $a = Wait-ListCwd $pane { param($c) EndsWithDir $c 't1741-root' } 20
    "  +list working_directory at open: '$($a.cwd)'"
    Assert "A1 +list names the marker root at open" $a.ok
    Assert "A2 +list does NOT already name the sub directory" (-not (EndsWithDir $a.cwd 't1741-sub'))

    "== B: cd into the sub directory"
    & $Exe +send-keys --target=rcwd "cd t1741-sub" Enter 2>&1 | Out-Null
    $b = Wait-ListCwd $pane { param($c) EndsWithDir $c 't1741-sub' } $FollowTimeoutSec
    "  +list working_directory after cd: '$($b.cwd)' (after $($b.sec)s)"
    if ($NegativeControl) {
        "NEGATIVE CONTROL: asserting the directory did NOT follow - this run MUST fail"
        Assert "B1 +list did NOT follow the cd (inverted)" (-not $b.ok)
    } else {
        Assert "B1 +list follows the cd within ${FollowTimeoutSec}s" $b.ok
    }

    "== C: a second cd (back to the root) is pushed too"
    & $Exe +send-keys --target=rcwd "cd .." Enter 2>&1 | Out-Null
    $c = Wait-ListCwd $pane { param($x) EndsWithDir $x 't1741-root' } $FollowTimeoutSec
    "  +list working_directory after cd ..: '$($c.cwd)' (after $($c.sec)s)"
    Assert "C1 +list follows the second cd" $c.ok

    "== cleanup"
    & $Exe +close --target=rcwd 2>&1 | Out-Null
    Start-Sleep -Seconds 1
    Complete-TestBody
} finally {
    Remove-TestDesktop
    Stop-DebugGhoztty
    $env:LOCALAPPDATA = $saved.lad
    $env:GHOZTTY_PIPE_SUFFIX = $saved.pipe
    $env:GHOSTTY_AGENT_LOCK = $saved.lock
    $env:GHOSTTY_LOCAL_AGENT_BIN = $saved.bin
    $env:PROMPT = $saved.prompt
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

$fgSeen = @(Stop-TestForegroundWatch)
"foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @(Get-TestLaunchedPids)
    Assert "the foreground watcher actually sampled (negative control)" ($fgSeen.Count -gt 0)
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert "no test-desktop app ever became foreground on the interactive desktop" ($leaked.Count -eq 0)
}

# A green run stamps the covered files (T783); red, or a negative-control run,
# leaves the stamp alone so the guard stays due.
if ($script:failures -eq 0 -and $script:passes -gt 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $PSScriptRoot '..\..\scripts\guard-due.ps1') `
        update -Guard remote-cwd-follow 2>&1 | ForEach-Object { "  $_" }
}

Write-TestVerdict -Label 'T1741 ACCEPTANCE' -Pass $script:passes -Fail $script:failures
