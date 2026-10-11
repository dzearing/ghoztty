# claude-code-fullscreen acceptance (tracker T1801): Ghoztty panes start
# Claude Code in its fullscreen ("no-flicker") renderer by default, on Windows
# exactly as on the Mac (main 7e78aacf4).
#
# The contract (src/config/Config.zig `claude-code-fullscreen`, docs/claude/
# sessions.md): with the option on (the default) the pane's shell sees
# CLAUDE_CODE_NO_FLICKER=1 in a LOCAL pane and in a SESSION-PERSISTENCE pane
# (on Windows that is an agent-hosted ConPTY, so the value has to ride the OPEN
# env rather than the app's own child env), and NEVER in a cross-machine pane.
# Every explicit choice wins:
#
#   * the variable already in the environment (any value) is left alone,
#   * Claude's settings set `tui` - read from $CLAUDE_CONFIG_DIR\settings.json,
#     else %USERPROFILE%\.claude\settings.json, which is what Node's homedir()
#     is on Windows (the Mac code read $HOME, unset here: before T1801 a user's
#     `/tui default` was silently overridden),
#   * `env = CLAUDE_CODE_NO_FLICKER=...` in the config, applied last,
#   * `claude-code-fullscreen = false`.
#
# Each case is its own hermetic launch on the test desktop with a fixture
# profile dir as %USERPROFILE% (the real one carries the user's own `tui`), and
# reads the pane's env back with cmd's `set <name>` - no `%` in the keystrokes,
# so the harness's own cmd /c cannot expand the probe before the pane sees it.
#
# Non-interactive; asserts and exits nonzero on any failure. Only ever kills
# ghoztty / ghoztty-agent processes launched from the repo zig-out.
#
#   powershell -NoProfile -File test\win32\claude-fullscreen-env.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe',
    [int]$Port = 0
)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

$ErrorActionPreference = 'Continue'
$script:passes = 0
$script:failures = 0
$root = Join-Path $env:TEMP "ghoztty-claude-fs-$PID"
$VAR = 'CLAUDE_CODE_NO_FLICKER'

function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ } else { "  FAIL $name"; $script:failures++ }
}
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\FreePort.ps1')

function Stop-TestProcs { [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 900) }

function Run-Cli($argsLine, $out, $timeoutSec = 15) {
    $p = Start-Process -FilePath cmd.exe -WindowStyle Hidden -PassThru `
        -ArgumentList "/c `"`"$Exe`" $argsLine > `"$out`" 2>&1`""
    $null = $p.Handle   # before any wait, or ExitCode reads empty (lib\ExitCodeAudit.ps1)
    if (-not $p.WaitForExit($timeoutSec * 1000)) {
        & taskkill.exe /F /T /PID $p.Id *> $null
        return $null
    }
    return $p.ExitCode
}
function Out-Text($f) { if (Test-Path $f) { Get-Content $f -Raw } else { '' } }
function Stripped($f) { return ((Out-Text $f) -replace '\s', '') }

function Get-Windows($tmp, $tag) {
    $code = Run-Cli '+list --json' "$tmp\list-$tag.json" 12
    if ($code -ne 0) { return @() }
    try { $tree = (Out-Text "$tmp\list-$tag.json" | ConvertFrom-Json) } catch { return @() }
    $windows = if ($null -ne $tree.data) { $tree.data.windows } else { $tree.windows }
    return @($windows)
}
function First-Pane($w) {
    $node = @($w.tabs)[0].splits
    while ($null -ne $node -and $node.type -eq 'split') { $node = $node.left }
    if ($null -eq $node) { return '' }
    return [string]$node.terminal.name
}
function Wait-Pane($tmp, $tag, $target, $timeoutSec = 30) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        foreach ($w in (Get-Windows $tmp $tag)) {
            if ($target -eq '' -or [string]$w.target -eq $target) {
                $p = First-Pane $w
                if ($p -ne '') { return $p }
            }
        }
        Start-Sleep -Milliseconds 500
    }
    return ''
}

# The pane's view of $VAR: the value, 'UNSET', or '' when the probe never
# answered. cmd prints `NAME=value`, or `Environment variable NAME not defined`;
# the typed line itself carries no `=`, so neither pattern can match the echo.
function Probe-Var($tmp, $pane, $tag, $timeoutSec = 30) {
    Run-Cli "+send-keys --target=$pane `"set $VAR`" Enter" "$tmp\send-$tag.txt" 12 | Out-Null
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $resent = $false
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 700
        Run-Cli "+read --name=$pane --lines=400" "$tmp\read-$tag.txt" 15 | Out-Null
        $hay = Stripped "$tmp\read-$tag.txt"
        if ($hay -match "Environmentvariable${VAR}notdefined") { return 'UNSET' }
        $m = [regex]::Match($hay, "(?<!set)$VAR=(\d+)")
        if ($m.Success) { return $m.Groups[1].Value }
        # A shell that was still starting can eat the first line; type it once more.
        if (-not $resent -and (Get-Date) -gt $deadline.AddSeconds(-$timeoutSec / 2)) {
            Run-Cli "+send-keys --target=$pane `"set $VAR`" Enter" "$tmp\send2-$tag.txt" 12 | Out-Null
            $resent = $true
        }
    }
    return ''
}

# One hermetic launch: own LOCALAPPDATA, own fixture profile, given args.
function Launch($tmp, [string[]]$extraArgs) {
    New-Item -ItemType Directory -Force (Join-Path $tmp 'ghoztty\local-agent-debug') | Out-Null
    $env:LOCALAPPDATA = $tmp
    $env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe
    # persistence: on (default) - the persistence pane IS a subject (A1, B1);
    # cases needing a local pane pass --session-persistence=false, and each
    # launch has its own LOCALAPPDATA, so nothing outside this run is restored.
    [void](Start-OnTestDesktop -Exe $Exe -Arguments (@('--title=t1801') + $extraArgs))
}

# Run one case end to end and return what the pane saw.
function Run-Case($tag, [string[]]$extraArgs, $profileTui) {
    $tmp = Join-Path $root $tag
    $profile = Join-Path $tmp 'profile'
    New-Item -ItemType Directory -Force (Join-Path $profile '.claude') | Out-Null
    if ($null -ne $profileTui) {
        Set-Content -Path (Join-Path $profile '.claude\settings.json') -Encoding ascii `
            -Value "{`"model`":`"x`",`"tui`":`"$profileTui`"}"
    }
    $env:USERPROFILE = $profile
    Launch $tmp $extraArgs
    $pane = Wait-Pane $tmp "$tag-0" ''
    $got = if ($pane -ne '') { Probe-Var $tmp $pane $tag } else { '' }
    $env:USERPROFILE = $savedProfile
    Stop-TestProcs
    "    [$tag] pane='$pane' $VAR -> '$got'"
    return $got
}

$td = New-TestDesktop
Stop-TestProcs
New-Item -ItemType Directory -Force $root | Out-Null
$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN
$savedProfile = $env:USERPROFILE
$savedVar = [Environment]::GetEnvironmentVariable($VAR)
$savedCfgDir = $env:CLAUDE_CONFIG_DIR
# This harness usually runs inside a Ghoztty pane that may itself carry the
# variable (or a CLAUDE_CONFIG_DIR) - the app under test would inherit that and
# read it as the user's choice. Start from neither.
Remove-Item "env:$VAR" -ErrorAction SilentlyContinue
Remove-Item env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue

Assert "ghoztty exe exists in zig-out" (Test-Path $Exe)
Assert "agent binary exists in zig-out" (Test-Path $AgentExe)

. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 'claudefs')
Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null
if ((Run-Cli '+list --json' "$root\preflight.json" 10) -eq 0) {
    "ABORT: an instance is already answering on this exe's IPC endpoint."
    exit 2
}

"== A: defaults - persistence pane and plain local pane both get it"
$a = Run-Case 'a-persist' @() $null
Assert "A1 a session-persistence (agent-hosted) pane sees $VAR=1" ($a -eq '1')
$b = Run-Case 'b-local' @('--session-persistence=false') $null
Assert "A2 a local (exec) pane sees $VAR=1" ($b -eq '1')

"== B: every explicit choice wins"
$c = Run-Case 'c-tui' @() 'default'
Assert "B1 a 'tui' key in %USERPROFILE%\.claude\settings.json leaves it unset (persistence pane)" ($c -eq 'UNSET')
$c2 = Run-Case 'c-tui-local' @('--session-persistence=false') 'default'
Assert "B2 ...and in a local pane" ($c2 -eq 'UNSET')
$d = Run-Case 'd-off' @('--claude-code-fullscreen=false') $null
Assert "B3 claude-code-fullscreen=false leaves it unset" ($d -eq 'UNSET')
$e = Run-Case 'e-cfgenv' @("--env=$VAR=0") $null
Assert "B4 config env = $VAR=0 wins (applied last)" ($e -eq '0')
Set-Item "env:$VAR" '7'
$f = Run-Case 'f-inherited' @() $null
Remove-Item "env:$VAR" -ErrorAction SilentlyContinue
Assert "B5 a value already in the environment is left as the user set it" ($f -eq '7')

"== C: never on a cross-machine pane"
$Port = Resolve-TestPort -Name 'agent' -Port $Port
$tmpR = Join-Path $root 'r-remote'
New-Item -ItemType Directory -Force (Join-Path $tmpR 'profile\.claude') | Out-Null
$env:USERPROFILE = Join-Path $tmpR 'profile'
$agent = Start-Process -FilePath $AgentExe -ArgumentList '--listen', "127.0.0.1:$Port", '--headless' `
    -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 2
Assert "C0 loopback agent is up on 127.0.0.1:$Port" (-not $agent.HasExited)
Launch $tmpR @()
$localPane = Wait-Pane $tmpR 'r-0' ''
$code = Run-Cli "+new-remote-window --host=127.0.0.1 --port=$Port --name=t1801rem" "$tmpR\open.txt" 30
Assert "C1 +new-remote-window opened" ($code -eq 0)
$remotePane = Wait-Pane $tmpR 'r-1' 't1801rem'
$r = if ($remotePane -ne '') { Probe-Var $tmpR $remotePane 'remote' } else { '' }
"    [remote] pane='$remotePane' $VAR -> '$r'"
Assert "C2 the cross-machine pane does NOT see $VAR" ($r -eq 'UNSET')
# Positive control in the same app: the local window right beside it does.
$l = if ($localPane -ne '') { Probe-Var $tmpR $localPane 'remote-local' } else { '' }
Assert "C3 control: the same app's local pane does see $VAR=1" ($l -eq '1')
$env:USERPROFILE = $savedProfile
Stop-TestProcs
if (-not $agent.HasExited) { & taskkill.exe /F /T /PID $agent.Id *> $null }

"== cleanup"
$env:LOCALAPPDATA = $savedLocalAppData
$env:USERPROFILE = $savedProfile
if ($null -ne $savedAgentBin) { $env:GHOSTTY_LOCAL_AGENT_BIN = $savedAgentBin }
else { Remove-Item env:GHOSTTY_LOCAL_AGENT_BIN -ErrorAction SilentlyContinue }
if ($null -ne $savedVar) { Set-Item "env:$VAR" $savedVar }
if ($null -ne $savedCfgDir) { $env:CLAUDE_CONFIG_DIR = $savedCfgDir }
Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
Remove-TestDesktop | Out-Null

Complete-TestBody  # T1039: before the stamp
if ($script:failures -eq 0) {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard claude-fullscreen-env -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-TestVerdict -Pass $script:passes -Fail $script:failures
