# T1972 acceptance: a pane the APP spawns itself (the exec backend) must get
# the interactive user's PATH, exactly as an agent-hosted pane does (T42).
#
#   powershell -NoProfile -File test\win32\exec-user-env.ps1
#
# The defect (user report 2026-10-15): after a restart, restored panes had no
# user PATH and a pane opened a minute later did. A restore whose local agent
# cannot be reached inside its bound (an installer just killed it, it is still
# coming up) falls back to the exec backend, and that path took the app's own
# environment verbatim. An app relaunched by msiexec / Restart Manager carries
# a PATH without the user's entries, so every restored pane did too, while the
# later pane went through the agent, which merges the registry PATH per spawn.
#
# How this reproduces it on one box: launch the debug app on the test desktop
# with its OWN PATH stripped to %SystemRoot%\system32 + %SystemRoot% and
# session persistence off (so the pane is an exec pane - the same construction
# site the restore fallback uses), then have the pane's cmd dump its whole
# environment to a file (`set > file`; a file, because a wrapped PATH on screen
# would measure the terminal, not the environment).
#
# Negative control: the same launch with GHOZTTY_USER_ENV=off in the app's
# environment. The merge is skipped and the marker must be ABSENT; without it a
# green run could just mean the PATH was never stripped.
#
# Non-interactive; asserts and exits nonzero on any failure. Only ever kills
# ghoztty / ghoztty-agent processes launched from the repo zig-out.
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe'
)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

$ErrorActionPreference = 'Continue'
$script:passes = 0
$script:failures = 0
$root = Join-Path $env:TEMP "ghoztty-exec-userenv-$PID"

function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ } else { "  FAIL $name"; $script:failures++ }
}
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

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

function Wait-Pane($tmp, $tag, $timeoutSec = 30) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $code = Run-Cli '+list --json' "$tmp\list-$tag.json" 12
        if ($code -eq 0) {
            try { $tree = (Out-Text "$tmp\list-$tag.json" | ConvertFrom-Json) } catch { $tree = $null }
            if ($null -ne $tree) {
                $windows = if ($null -ne $tree.data) { $tree.data.windows } else { $tree.windows }
                foreach ($w in @($windows)) {
                    $node = @($w.tabs)[0].splits
                    while ($null -ne $node -and $node.type -eq 'split') { $node = $node.left }
                    if ($null -ne $node -and [string]$node.terminal.name -ne '') {
                        return [string]$node.terminal.name
                    }
                }
            }
        }
        Start-Sleep -Milliseconds 500
    }
    return ''
}

# The pane's own Path, read from `set > file` ('' when the dump never arrived).
function Dump-Path($tmp, $pane, $tag, $timeoutSec = 30) {
    $envFile = Join-Path $tmp "env-$tag.txt"
    # Typed with forward slashes: +send-keys reads a backslash as an escape
    # (`\e` is ESC), so `...\env-a-on.txt` arrived as `...nv-a-on.txt`.
    $typedFile = $envFile -replace '\\', '/'
    Run-Cli "+send-keys --target=$pane `"set > $typedFile`" Enter" "$tmp\send-$tag.txt" 12 | Out-Null
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $resent = $false
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 700
        if (Test-Path $envFile) {
            foreach ($line in (Get-Content $envFile)) {
                if ($line -match '^(?i)path=(.*)$') { return $Matches[1] }
            }
        }
        # A shell that was still starting can eat the first line; type it once more.
        if (-not $resent -and (Get-Date) -gt $deadline.AddSeconds(-$timeoutSec / 2)) {
            Run-Cli "+send-keys --target=$pane `"set > $typedFile`" Enter" "$tmp\send2-$tag.txt" 12 | Out-Null
            $resent = $true
        }
    }
    # No dump: keep what the pane shows, so a failure says why.
    Run-Cli "+read --name=$pane --lines=30" "$tmp\read-$tag.txt" 15 | Out-Null
    $script:lastScreen = Out-Text "$tmp\read-$tag.txt"
    return ''
}

function Has-Entry($pathValue, $entry) {
    foreach ($e in ($pathValue -split ';')) {
        if ($e.Trim().Trim('"').TrimEnd('\') -ieq $entry) { return $true }
    }
    return $false
}

# One hermetic launch with a stripped PATH; returns the pane's Path.
function Run-Case($tag, $overlay) {
    $tmp = Join-Path $root $tag
    New-Item -ItemType Directory -Force (Get-GhozttyAgentStateDir -Root $tmp) | Out-Null
    $savedPath = $env:Path
    $env:LOCALAPPDATA = $tmp
    # THE CONDITION: an app whose own environment carries no user PATH at all.
    $env:Path = "$winRoot\system32;$winRoot"
    if ($overlay -eq 'off') { $env:GHOZTTY_USER_ENV = 'off' }
    [void](Start-OnTestDesktop -Exe $Exe -Arguments @('--title=t1972', '--session-persistence=false'))
    $env:Path = $savedPath
    Remove-Item env:GHOZTTY_USER_ENV -ErrorAction SilentlyContinue

    $pane = Wait-Pane $tmp "$tag-0"
    $got = if ($pane -ne '') { Dump-Path $tmp $pane $tag } else { '' }
    Stop-TestProcs
    # Reported by the caller: anything this function emits would become part
    # of its return value.
    $entries = @(($got -split ';') | Where-Object { $_ })
    $script:lastCase = "    [$tag] pane='$pane' Path has $($entries.Count) entries; first: $(@($entries | Select-Object -First 2) -join ';')"
    return $got
}

# ---------------------------------------------------------------------------
# The marker: an entry of the user's OWN registry PATH (HKCU\Environment\Path)
# that does not live under %SystemRoot%, so the stripped PATH cannot hold it by
# accident. Same choice as agent-user-env.ps1, read expanded.
$winRoot = $env:SystemRoot
$userPathRaw = ''
try {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment')
    if ($null -ne $key) {
        $userPathRaw = [string]$key.GetValue('Path', '')
        $key.Close()
    }
} catch { $userPathRaw = '' }
$userPath = [Environment]::ExpandEnvironmentVariables($userPathRaw)
$marker = $null
foreach ($e in ($userPath -split ';')) {
    $t = $e.Trim().Trim('"').TrimEnd('\')
    if ($t.Length -eq 0) { continue }
    if ($t.ToLower().StartsWith($winRoot.ToLower())) { continue }
    $marker = $t
    break
}
if ($null -eq $marker) {
    Write-TestAssertedNothing -Reason 'no usable HKCU\Environment\Path entry on this box - nothing to assert' -Skipped 1
}
"  marker (user PATH entry): $marker"

$td = New-TestDesktop
Stop-TestProcs
New-Item -ItemType Directory -Force $root | Out-Null
$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN
$env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe

Assert "ghoztty exe exists in zig-out" (Test-Path $Exe)

. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 'execuserenv')
Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null
if ((Run-Cli '+list --json' "$root\preflight.json" 10) -eq 0) {
    "ABORT: an instance is already answering on this exe's IPC endpoint."
    exit 2
}

"== A: an exec pane of an app with a stripped PATH gets the user's PATH"
$on = Run-Case 'a-on' 'on'
$script:lastCase
if ($script:lastScreen) { "    screen:"; $script:lastScreen; $script:lastScreen = $null }
Assert "A1 the pane's environment was dumped" ($on -ne '')
Assert "A2 the pane's Path carries the user entry '$marker'" (Has-Entry $on $marker)
Assert "A3 the app's own entries keep their place (system32 first)" `
    ((($on -split ';')[0]).TrimEnd('\') -ieq "$winRoot\system32")

"== B: negative control - GHOZTTY_USER_ENV=off skips the merge"
$off = Run-Case 'b-off' 'off'
$script:lastCase
if ($script:lastScreen) { "    screen:"; $script:lastScreen; $script:lastScreen = $null }
Assert "B1 the pane's environment was dumped" ($off -ne '')
Assert "B2 the pane's Path does NOT carry '$marker' (the PATH really was stripped)" `
    ($off -ne '' -and -not (Has-Entry $off $marker))

"== cleanup"
$env:LOCALAPPDATA = $savedLocalAppData
if ($null -ne $savedAgentBin) { $env:GHOSTTY_LOCAL_AGENT_BIN = $savedAgentBin }
else { Remove-Item env:GHOSTTY_LOCAL_AGENT_BIN -ErrorAction SilentlyContinue }
Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
Remove-TestDesktop | Out-Null

Complete-TestBody  # T1039: before the stamp
if ($script:failures -eq 0) {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard exec-user-env -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-TestVerdict -Pass $script:passes -Fail $script:failures
