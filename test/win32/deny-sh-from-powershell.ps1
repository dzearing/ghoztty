# T1901 acceptance: scripts\hooks\deny-sh-from-powershell.ps1, the
# PreToolUse hook that refuses a PowerShell-tool command which would launch a
# .sh file (and so pop OpenWith's "How do you want to open this file?" picker
# on the user's desktop).
#
#   A. The decision table, via -CommandText: the exact 2026-10-13 02:32:46
#      command (T1901) and the T1823 shapes are DENIED; `bash x.sh`, reading a
#      .sh, and naming one as an argument are ALLOWED.
#   B. The hook envelope: stdin JSON from a PowerShell call -> a deny
#      decision on stdout, exit 0; another tool, a clean command and garbage
#      input -> no output, exit 0 (fail-open).
#   C. Wiring: .claude/settings.json registers the script for the PowerShell
#      tool, and the registered command line produces the deny when run
#      through bash the way Claude Code runs hooks.
#
#   -NegativeControl adds one inverted assertion a healthy tree MUST fail, so
#   the run ends with exactly one failure.
#
# Non-interactive. Nothing here executes a .sh or opens a window.
[CmdletBinding(PositionalBinding = $false)]
param([switch]$NegativeControl)

$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$hook = Join-Path $repo 'scripts\hooks\deny-sh-from-powershell.ps1'

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:fail = 0
$script:pass = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" }
}

function Get-Verdict([string]$cmd) {
    return ((& $hook -CommandText $cmd) | Out-String).Trim()
}

function Invoke-Hook([string]$json) {
    # A child process, because the hook reads its payload from stdin.
    $tmp = [IO.Path]::GetTempFileName()
    try {
        [IO.File]::WriteAllText($tmp, $json)
        $out = cmd /c "powershell -NoProfile -ExecutionPolicy Bypass -File `"$hook`" < `"$tmp`"" | Out-String
        return [pscustomobject]@{ Out = $out.Trim(); Exit = $LASTEXITCODE }
    } finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
}

try {
Write-Host '--- A. decision table ---'
$t1901 = 'powershell -NoProfile -File scripts\parity-tasks.ps1 note T1895 -Text "root cause" | Out-Null; ~/.config/ghoztty/hooks/ghoztty-banner.sh 2>$null; powershell -NoProfile -File scripts\guard-due.ps1 check *> temp\gd.log'
Assert ((Get-Verdict $t1901) -match '^DENY .*ghoztty-banner\.sh') 'the 2026-10-13 02:32:46 command (T1901) is denied'
Assert ((Get-Verdict "~/.config/ghoztty/hooks/ghoztty-banner.sh set --title 'x'") -match '^DENY') 'a bare banner call (T1823) is denied'
Assert ((Get-Verdict "& 'C:\x\y.sh' a") -match '^DENY') 'the call operator on a quoted .sh is denied'
Assert ((Get-Verdict '.\run.SH') -match '^DENY') 'a relative .sh is denied, case-insensitively'
Assert ((Get-Verdict 'Start-Process .\run.sh') -match '^DENY') 'Start-Process on a .sh is denied'
Assert ((Get-Verdict 'ii "C:\a b\c.sh"') -match '^DENY') 'Invoke-Item alias on a quoted .sh is denied'
Assert ((Get-Verdict 'powershell -NoProfile -Command "./foo.sh; Get-Date"') -match '^DENY') 'a .sh inside a nested powershell -Command is denied'
Assert ((Get-Verdict 'bash ~/.config/ghoztty/hooks/ghoztty-banner.sh set --title x') -eq 'ALLOW') 'bash x.sh is allowed'
Assert ((Get-Verdict 'sh ./build.sh') -eq 'ALLOW') 'sh x.sh is allowed'
Assert ((Get-Verdict 'Get-Content foo.sh | Select-String x') -eq 'ALLOW') 'reading a .sh is allowed'
Assert ((Get-Verdict 'git diff -- scripts/x.sh') -eq 'ALLOW') 'naming a .sh as an argument is allowed'
Assert ((Get-Verdict 'zig build -Doptimize=Debug') -eq 'ALLOW') 'an ordinary command is allowed'

Write-Host '--- B. hook envelope ---'
$deny = Invoke-Hook '{"tool_name":"PowerShell","tool_input":{"command":"~/.config/ghoztty/hooks/ghoztty-banner.sh set --title x"}}'
$parsed = $null; try { $parsed = $deny.Out | ConvertFrom-Json } catch {}
Assert ($parsed -and $parsed.hookSpecificOutput.permissionDecision -eq 'deny' -and $parsed.hookSpecificOutput.hookEventName -eq 'PreToolUse') 'a PowerShell .sh call gets a PreToolUse deny decision'
Assert ($parsed -and $parsed.hookSpecificOutput.permissionDecisionReason -match 'Bash tool') 'the reason names the remedy (the Bash tool)'
Assert ($deny.Exit -eq 0) 'deny is reported through JSON, exit 0'
$clean = Invoke-Hook '{"tool_name":"PowerShell","tool_input":{"command":"git status"}}'
Assert ((-not $clean.Out) -and $clean.Exit -eq 0) 'a clean PowerShell command passes silently'
$other = Invoke-Hook '{"tool_name":"Bash","tool_input":{"command":"./x.sh"}}'
Assert ((-not $other.Out) -and $other.Exit -eq 0) 'another tool is not judged'
$junk = Invoke-Hook 'not json'
Assert ((-not $junk.Out) -and $junk.Exit -eq 0) 'garbage input fails open (silent, exit 0)'

Write-Host '--- C. wiring ---'
$settingsPath = Join-Path $repo '.claude\settings.json'
$entry = $null
try {
    $settings = Get-Content -Raw $settingsPath | ConvertFrom-Json
    $entry = @($settings.hooks.PreToolUse | Where-Object { $_.matcher -eq 'PowerShell' })[0]
} catch {}
$command = if ($entry) { [string]@($entry.hooks)[0].command } else { '' }
Assert ($command -match 'deny-sh-from-powershell\.ps1') '.claude/settings.json registers the hook for the PowerShell tool'
# Git Bash, the shell Claude Code runs hooks with on Windows - never a bare
# `bash`, which resolves to System32's WSL launcher ahead of PATH and would
# start WSL (forbidden on this box unasked).
$bash = $null
if ($env:CLAUDE_CODE_GIT_BASH_PATH -and (Test-Path $env:CLAUDE_CODE_GIT_BASH_PATH)) {
    $bash = [pscustomobject]@{ Source = $env:CLAUDE_CODE_GIT_BASH_PATH }
} else {
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git) {
        $gitBash = Join-Path (Split-Path (Split-Path $git.Source -Parent) -Parent) 'bin\bash.exe'
        if (Test-Path $gitBash) { $bash = [pscustomobject]@{ Source = $gitBash } }
    }
}
if ($bash -and $command) {
    $tmp = [IO.Path]::GetTempFileName()
    [IO.File]::WriteAllText($tmp, '{"tool_name":"PowerShell","tool_input":{"command":"x.sh"}}')
    $env:CLAUDE_PROJECT_DIR = $repo
    $viaBash = (Get-Content -Raw $tmp | & $bash.Source -c $command) | Out-String
    Remove-Item $tmp -ErrorAction SilentlyContinue
    Assert ($viaBash -match '"permissionDecision":"deny"') 'the registered command line denies when run through bash'
} else {
    Assert $false 'Git Bash is present to run the registered command line'
}

if ($NegativeControl) {
    Assert ((Get-Verdict 'bash x.sh') -match '^DENY') 'NEGATIVE CONTROL: bash x.sh must not be denied (this must FAIL)'
}

Complete-TestBody  # T1039: the run reached the end of its body
} finally { }

# --- stamp (T783) -----------------------------------------------------------
# A green run records the content of every file this harness covers; a red run
# leaves the stamp alone on purpose - red must stay due.
if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard deny-sh-from-powershell -Repo $repo | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Label 'DENY-SH-FROM-POWERSHELL' -MinPass 20
