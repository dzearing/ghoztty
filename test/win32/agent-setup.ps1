# T2605 acceptance: an agent running inside Ghoztty can find, read and install
# the Ghoztty skill with no web access.
#
#   powershell -NoProfile -File test\win32\agent-setup.ps1 [-NegativeControl]
#
# The defect (user report 2026-11-01): Claude Code installed after Ghoztty had
# no skill, and asked to find one it could only find the archived
# dzearing/ghoztty-claude-plugin repository and its stale CLI docs. Now every
# pane carries GHOZTTY_AGENT_SETUP=ghoztty +agent-setup, and that verb prints
# the pointer, the bundled skill, and installs it.
#
#   A. The verb, no app: the pointer names every reference file, both install
#      commands and the archived repo; --skill prints SKILL.md and each
#      reference file; ghoztty --help lists the verb; bad arguments exit 1.
#   B. --install in a sandbox home (GHOZTTY_AGENT_HOME, the same override the
#      Agent Integrations dialog obeys): with a stub claude it installs, the
#      installed SKILL.md carries the bundled text and the ownership marker, a
#      second run is "already up to date"; copilot, absent from the sandbox,
#      is "not installed" at exit 1.
#   C. The pane environment: an agent-backed pane (the default) and an exec
#      pane (--session-persistence=false) each read GHOZTTY_AGENT_SETUP from
#      `set > file`.
#
#   -NegativeControl adds one inverted assertion a healthy tree MUST fail.
#
# Non-interactive; the app runs on the test desktop. Only ever kills ghoztty /
# ghoztty-agent processes launched from the repo zig-out.
[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe',
    [switch]$NegativeControl
)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

$ErrorActionPreference = 'Continue'
$script:passes = 0
$script:failures = 0
$root = Join-Path $env:TEMP "ghoztty-agent-setup-$PID"
$expectedEnv = 'ghoztty +agent-setup'

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
function Out-Text($f) { if (Test-Path $f) { [string](Get-Content $f -Raw) } else { '' } }

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

# The pane's GHOZTTY_AGENT_SETUP from `set > file`; $null when the dump never
# arrived, '' when it arrived without the variable.
function Dump-AgentEnv($tmp, $pane, $tag, $timeoutSec = 30) {
    $envFile = Join-Path $tmp "env-$tag.txt"
    # Forward slashes: +send-keys reads a backslash as an escape.
    $typedFile = $envFile -replace '\\', '/'
    Run-Cli "+send-keys --target=$pane `"set > $typedFile`" Enter" "$tmp\send-$tag.txt" 12 | Out-Null
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $resent = $false
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 700
        if (Test-Path $envFile) {
            Start-Sleep -Milliseconds 300   # let cmd finish writing
            foreach ($line in (Get-Content $envFile)) {
                if ($line -match '^(?i)GHOZTTY_AGENT_SETUP=(.*)$') { return $Matches[1] }
            }
            return ''
        }
        # A shell that was still starting can eat the first line; type it once more.
        if (-not $resent -and (Get-Date) -gt $deadline.AddSeconds(-$timeoutSec / 2)) {
            Run-Cli "+send-keys --target=$pane `"set > $typedFile`" Enter" "$tmp\send2-$tag.txt" 12 | Out-Null
            $resent = $true
        }
    }
    return $null
}

# persistence: caller supplies - C1 runs agent-backed (default) and C2 passes =false; the env var must reach BOTH pane kinds.
function Run-PaneCase($tag, [string[]]$appArgs) {
    $tmp = Join-Path $root $tag
    New-Item -ItemType Directory -Force (Get-GhozttyAgentStateDir -Root $tmp) | Out-Null
    $env:LOCALAPPDATA = $tmp
    [void](Start-OnTestDesktop -Exe $Exe -Arguments $appArgs)
    $pane = Wait-Pane $tmp "$tag-0"
    $got = if ($pane -ne '') { Dump-AgentEnv $tmp $pane $tag } else { $null }
    Stop-TestProcs
    $script:lastCase = "    [$tag] pane='$pane' GHOZTTY_AGENT_SETUP='$got'"
    return $got
}

New-Item -ItemType Directory -Force $root | Out-Null
$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN

try {
Assert "ghoztty exe exists in zig-out" (Test-Path $Exe)
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 'agentsetup')
Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null

"== A: the verb prints the pointer and the bundled skill"
$skillDir = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'src\apprt\win32\assets\ghoztty\skills\ghoztty'
$refFiles = @(Get-ChildItem $skillDir -File | Where-Object { $_.Name -ne 'SKILL.md' } | ForEach-Object { $_.Name })
$code = Run-Cli '+agent-setup' "$root\pointer.txt"
$pointer = Out-Text "$root\pointer.txt"
Assert "A1 +agent-setup exits 0 (got $code)" ($code -eq 0)
Assert "A2 the pointer names both install commands" `
    ($pointer.Contains('--install=claude') -and $pointer.Contains('--install=copilot'))
Assert "A3 the pointer warns off the archived plugin repo" `
    ($pointer.Contains('ghoztty-claude-plugin') -and $pointer.Contains('archived'))
$missing = @($refFiles | Where-Object { -not $pointer.Contains($_) })
Assert "A4 the pointer lists all $($refFiles.Count) reference files (missing: $($missing -join ','))" `
    ($refFiles.Count -gt 0 -and $missing.Count -eq 0)

$code = Run-Cli '+agent-setup --skill' "$root\skill.txt"
$skill = Out-Text "$root\skill.txt"
Assert "A5 --skill exits 0 and prints the skill's front matter" `
    ($code -eq 0 -and $skill.StartsWith('---') -and $skill.Contains('name: ghoztty'))
$badRef = @()
foreach ($f in $refFiles) {
    $c = Run-Cli "+agent-setup --skill=$f" "$root\ref-$f.txt"
    $firstSource = @(Get-Content (Join-Path $skillDir $f) | Where-Object { $_.Trim() } | Select-Object -First 1)[0]
    if ($c -ne 0 -or -not (Out-Text "$root\ref-$f.txt").Contains($firstSource)) { $badRef += $f }
}
Assert "A6 --skill=<file> prints every reference file (bad: $($badRef -join ','))" ($badRef.Count -eq 0)

$code = Run-Cli '+agent-setup --skill=nope.md' "$root\nope.txt"
Assert "A7 an unknown skill file exits 1 and says so" `
    ($code -eq 1 -and (Out-Text "$root\nope.txt").Contains("no file named 'nope.md'"))
$code = Run-Cli '+agent-setup --install=codex' "$root\codex.txt"
Assert "A8 an unknown agent exits 1" ($code -eq 1)
$code = Run-Cli '+help' "$root\help.txt"
Assert "A9 ghoztty +help (what --help runs) lists +agent-setup" ((Out-Text "$root\help.txt") -match '\+agent-setup\s')

"== B: --install into a sandbox home"
$sbHome = Join-Path $root 'home'
New-Item -ItemType Directory -Force (Join-Path $sbHome '.local\bin') | Out-Null
"@echo off`r`necho ok`r`nexit /b 0`r`n" | Set-Content -Path (Join-Path $sbHome '.local\bin\claude.cmd') -Encoding ascii
$env:GHOZTTY_AGENT_HOME = $sbHome
$env:XDG_CONFIG_HOME = Join-Path $root 'xdg'
try {
    $code = Run-Cli '+agent-setup --install=claude' "$root\install1.txt" 30
    $out1 = Out-Text "$root\install1.txt"
    "    $($out1.Trim() -replace "`r?`n", ' | ')"
    $installed = Join-Path $sbHome '.claude\skills\ghoztty\SKILL.md'
    Assert "B1 --install=claude exits 0 and reports it installed (got $code)" `
        ($code -eq 0 -and $out1.Contains('Claude Code: installed'))
    $installedText = Out-Text $installed
    Assert "B2 the installed SKILL.md is the text --skill prints plus the ownership marker" `
        ($installedText.Length -gt 0 -and $installedText.StartsWith($skill.TrimEnd()) -and $installedText.Contains('ghoztty-managed'))
    $refInstalled = @($refFiles | Where-Object { -not (Test-Path (Join-Path $sbHome ".claude\skills\ghoztty\$_")) })
    Assert "B3 every reference file is installed beside it (missing: $($refInstalled -join ','))" ($refInstalled.Count -eq 0)
    Assert "B4 the status hooks are installed too (settings.json)" (Test-Path (Join-Path $sbHome '.claude\settings.json'))

    $code = Run-Cli '+agent-setup --install=claude' "$root\install2.txt" 30
    Assert "B5 a second install is 'already up to date' at exit 0 (got $code)" `
        ($code -eq 0 -and (Out-Text "$root\install2.txt").Contains('already up to date'))

    $code = Run-Cli '+agent-setup --install=copilot' "$root\install3.txt" 30
    Assert "B6 an agent that is not installed exits 1 and says so (got $code)" `
        ($code -eq 1 -and (Out-Text "$root\install3.txt").Contains('is not installed'))
    Assert "B7 ...and nothing was written for it" (-not (Test-Path (Join-Path $sbHome '.copilot\skills\ghoztty')))

    if ($NegativeControl) {
        Assert "NEGATIVE CONTROL: copilot must not read as installed (this must FAIL)" `
            (Test-Path (Join-Path $sbHome '.copilot\skills\ghoztty\SKILL.md'))
    }
} finally {
    Remove-Item env:GHOZTTY_AGENT_HOME -ErrorAction SilentlyContinue
    Remove-Item env:XDG_CONFIG_HOME -ErrorAction SilentlyContinue
}

"== C: every pane's environment points at the verb"
$td = New-TestDesktop
Stop-TestProcs
if ((Run-Cli '+list --json' "$root\preflight.json" 10) -eq 0) {
    "ABORT: an instance is already answering on this exe's IPC endpoint."
    exit 2
}
$env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe
$agentBacked = Run-PaneCase 'c-agent' @('--title=t2605')
$script:lastCase
Assert "C1 an agent-backed pane carries GHOZTTY_AGENT_SETUP='$expectedEnv'" ($agentBacked -eq $expectedEnv)
$exec = Run-PaneCase 'c-exec' @('--title=t2605', '--session-persistence=false')
$script:lastCase
Assert "C2 an exec pane carries GHOZTTY_AGENT_SETUP='$expectedEnv'" ($exec -eq $expectedEnv)

Complete-TestBody  # T1039: the run reached the end of its body
} finally {
    Stop-TestProcs
    $env:LOCALAPPDATA = $savedLocalAppData
    if ($null -ne $savedAgentBin) { $env:GHOSTTY_LOCAL_AGENT_BIN = $savedAgentBin }
    else { Remove-Item env:GHOSTTY_LOCAL_AGENT_BIN -ErrorAction SilentlyContinue }
    Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
    Remove-TestDesktop | Out-Null
}

if ($script:failures -eq 0 -and -not $NegativeControl) {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard agent-setup -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-TestVerdict -Pass $script:passes -Fail $script:failures -MinPass 17
