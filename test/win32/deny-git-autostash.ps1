# T2393 acceptance: scripts\hooks\deny-git-autostash.ps1, the PreToolUse hook
# that refuses a git command asking for autostash (which parks work on the
# stash every worktree of this repo shares), and `git-commit-guard.ps1 sync`,
# the pull it points at instead.
#
#   A. The decision table, via -CommandText: the exact shapes found in the
#      reflogs are DENIED; --no-autostash, a grep for the flag and an ordinary
#      pull are ALLOWED.
#   B. The hook envelope: Bash and PowerShell payloads -> a deny decision on
#      stdout, exit 0; another tool, a clean command and garbage input -> no
#      output, exit 0 (fail-open).
#   C. Wiring: .claude/settings.json registers the script for both shell tools,
#      and the registered command line denies when run through Git Bash.
#   D. sync against fixture repos with a real bare remote: the negative control
#      (an autostash pull over a conflicting dirty stamp leaves an entry on the
#      stash), then sync fast-forwarding past a dirty task file, parking a dirty
#      stamp, refusing (untouched) on an overlapping real edit, rebasing a local
#      commit - and never adding a stash entry.
#
#   -NegativeControl adds one inverted assertion a healthy tree MUST fail, so
#   the run ends with exactly one failure.
#
# Non-interactive. Opens no window; the fixtures live under %TEMP%.
[CmdletBinding(PositionalBinding = $false)]
param([switch]$NegativeControl)

$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$hook = Join-Path $repo 'scripts\hooks\deny-git-autostash.ps1'
$cgScript = Join-Path $repo 'scripts\git-commit-guard.ps1'

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
    $tmp = [IO.Path]::GetTempFileName()
    try {
        [IO.File]::WriteAllText($tmp, $json)
        $out = cmd /c "powershell -NoProfile -ExecutionPolicy Bypass -File `"$hook`" < `"$tmp`"" | Out-String
        return [pscustomobject]@{ Out = $out.Trim(); Exit = $LASTEXITCODE }
    } finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
}

function G([string]$dir, [string[]]$a) {
    $o = & git -C $dir @a 2>&1 | ForEach-Object { $_.ToString() } | Out-String
    return @{ Code = $LASTEXITCODE; Out = $o.Trim() }
}
function Sync([string]$dir) {
    $o = & powershell -NoProfile -ExecutionPolicy Bypass -File $cgScript sync -Repo $dir 2>&1 |
        ForEach-Object { $_.ToString() } | Out-String
    return @{ Code = $LASTEXITCODE; Out = $o.Trim() }
}
function StashCount([string]$dir) { @(& git -C $dir stash list 2>$null).Count }
function Write-Utf8([string]$path, [string]$text) {
    New-Item -ItemType Directory -Force (Split-Path $path -Parent) | Out-Null
    [IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding $false))
}
function Stamp([string]$dir, [string]$when) {
    Write-Utf8 (Join-Path $dir 'test\win32\shared.stamp.json') "{`n  `"guard`": `"shared`",`n  `"generated`": `"$when`"`n}`n"
}

$root = Join-Path $env:TEMP ("deny-autostash-" + [guid]::NewGuid().ToString('N').Substring(0, 8))

try {
Write-Host '--- A. decision table ---'
Assert ((Get-Verdict 'git pull -q --rebase --autostash') -match '^DENY --autostash') 'the lane A shape (pull -q --rebase --autostash) is denied'
Assert ((Get-Verdict 'cd /d/git/ghoztty-b && git pull --rebase --autostash -q && git log -1') -match '^DENY') 'the lane B shape, mid-chain, is denied'
Assert ((Get-Verdict 'git -C D:\git\ghoztty pull --autostash') -match '^DENY') 'git -C <dir> pull --autostash is denied'
Assert ((Get-Verdict 'git rebase --autostash origin/main') -match '^DENY') 'rebase --autostash is denied'
Assert ((Get-Verdict 'git -c rebase.autoStash=true pull --rebase') -match '^DENY') '-c rebase.autoStash=true is denied'
Assert ((Get-Verdict 'git config rebase.autostash true') -match '^DENY') 'making autostash the default is denied'
Assert ((Get-Verdict 'GIT_TRACE=1 git pull --autostash') -match '^DENY') 'an env-prefixed git is still git'
Assert ((Get-Verdict '& git.exe pull --rebase --autostash; Get-Date') -match '^DENY') 'the PowerShell call operator on git.exe is denied'
Assert ((Get-Verdict 'git pull --rebase --no-autostash') -eq 'ALLOW') '--no-autostash is allowed'
Assert ((Get-Verdict 'git -c rebase.autoStash=false pull --rebase') -eq 'ALLOW') '-c rebase.autoStash=false is allowed'
Assert ((Get-Verdict "grep -rn -e '--autostash' scripts") -eq 'ALLOW') 'grepping for the flag is allowed'
Assert ((Get-Verdict 'git log -g --format=%gs | grep autostash') -eq 'ALLOW') 'reading the reflog for it is allowed'
Assert ((Get-Verdict 'git pull --rebase') -eq 'ALLOW') 'an ordinary pull is allowed'
Assert ((Get-Verdict 'powershell -NoProfile -File scripts\git-commit-guard.ps1 sync') -eq 'ALLOW') 'the remedy is allowed'

Write-Host '--- B. hook envelope ---'
$deny = Invoke-Hook '{"tool_name":"Bash","tool_input":{"command":"git pull --rebase --autostash"}}'
$parsed = $null; try { $parsed = $deny.Out | ConvertFrom-Json } catch {}
Assert ($parsed -and $parsed.hookSpecificOutput.permissionDecision -eq 'deny' -and $parsed.hookSpecificOutput.hookEventName -eq 'PreToolUse') 'a Bash autostash pull gets a PreToolUse deny decision'
Assert ($parsed -and $parsed.hookSpecificOutput.permissionDecisionReason -match 'git-commit-guard\.ps1 sync') 'the reason names the remedy (guard sync)'
Assert ($deny.Exit -eq 0) 'deny is reported through JSON, exit 0'
$denyPs = Invoke-Hook '{"tool_name":"PowerShell","tool_input":{"command":"git pull --autostash"}}'
Assert ($denyPs.Out -match '"permissionDecision":"deny"') 'a PowerShell autostash pull is denied too'
$clean = Invoke-Hook '{"tool_name":"Bash","tool_input":{"command":"git status"}}'
Assert ((-not $clean.Out) -and $clean.Exit -eq 0) 'a clean command passes silently'
$other = Invoke-Hook '{"tool_name":"Write","tool_input":{"content":"git pull --autostash"}}'
Assert ((-not $other.Out) -and $other.Exit -eq 0) 'another tool is not judged'
$junk = Invoke-Hook 'not json'
Assert ((-not $junk.Out) -and $junk.Exit -eq 0) 'garbage input fails open (silent, exit 0)'

Write-Host '--- C. wiring ---'
$entry = $null
try {
    $settings = Get-Content -Raw (Join-Path $repo '.claude\settings.json') | ConvertFrom-Json
    $entry = @($settings.hooks.PreToolUse | Where-Object { @($_.hooks).command -match 'deny-git-autostash\.ps1' })[0]
} catch {}
$command = if ($entry) { [string]@($entry.hooks)[0].command } else { '' }
Assert ($entry -and ('Bash' -match "^(?:$($entry.matcher))$") -and ('PowerShell' -match "^(?:$($entry.matcher))$")) '.claude/settings.json registers the hook for both Bash and PowerShell'
$bash = $null
if ($env:CLAUDE_CODE_GIT_BASH_PATH -and (Test-Path $env:CLAUDE_CODE_GIT_BASH_PATH)) { $bash = $env:CLAUDE_CODE_GIT_BASH_PATH }
else {
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git) {
        $gb = Join-Path (Split-Path (Split-Path $git.Source -Parent) -Parent) 'bin\bash.exe'
        if (Test-Path $gb) { $bash = $gb }
    }
}
if ($bash -and $command) {
    $env:CLAUDE_PROJECT_DIR = $repo
    $viaBash = ('{"tool_name":"Bash","tool_input":{"command":"git pull --autostash"}}' | & $bash -c $command) | Out-String
    Assert ($viaBash -match '"permissionDecision":"deny"') 'the registered command line denies when run through Git Bash'
} else {
    Assert $false 'Git Bash is present to run the registered command line'
}

Write-Host '--- D. sync never touches the stash ---'
$bare = Join-Path $root 'remote.git'
$la = Join-Path $root 'a'
$lb = Join-Path $root 'b'
New-Item -ItemType Directory -Force $root | Out-Null
& git init -q --bare $bare 2>$null
& git clone -q $bare $la 2>$null
foreach ($d in @($la)) { G $d @('config', 'user.email', 't@t') | Out-Null; G $d @('config', 'user.name', 't') | Out-Null }
Stamp $la '2026-11-05T09:00:00-08:00'
Write-Utf8 (Join-Path $la 'task.md') "status: todo`n"
Write-Utf8 (Join-Path $la 'code.txt') "v1`n"
G $la @('add', '-A') | Out-Null
G $la @('-c', 'core.hooksPath=', 'commit', '-q', '-m', 'seed') | Out-Null
G $la @('push', '-q', '-u', 'origin', 'HEAD') | Out-Null
& git clone -q $bare $lb 2>$null
foreach ($d in @($lb)) { G $d @('config', 'user.email', 't@t') | Out-Null; G $d @('config', 'user.name', 't') | Out-Null }
function Move-Trunk([string]$when, [string]$code) {
    Stamp $lb $when
    if ($code) { Write-Utf8 (Join-Path $lb 'code.txt') "$code`n" }
    G $lb @('add', '-A') | Out-Null
    G $lb @('-c', 'core.hooksPath=', 'commit', '-q', '-m', "trunk $when") | Out-Null
    G $lb @('push', '-q') | Out-Null
}

# Negative control: the reflog shape. Lane a holds a dirty stamp, the trunk
# rewrote the same stamp, and an autostash pull conflicts on the pop.
Move-Trunk '2026-11-05T10:00:00-08:00' ''
Stamp $la '2026-11-05T11:00:00-08:00'
$before = StashCount $la
G $la @('pull', '-q', '--rebase', '--autostash') | Out-Null
Assert ((StashCount $la) -gt $before) 'control: an autostash pull over a conflicting dirty stamp leaves an entry on the stash'
G $la @('checkout', '-q', 'HEAD', '--', '.') | Out-Null
G $la @('stash', 'clear') | Out-Null

# 1. Nothing unpushed, a dirty task file (the claim's own edit) and a dirty
#    stamp the trunk also rewrote: fast-forward, task file untouched, newer
#    stamp kept.
Move-Trunk '2026-11-05T12:00:00-08:00' 'v2'
Write-Utf8 (Join-Path $la 'task.md') "status: in-progress`n"
Stamp $la '2026-11-05T13:00:00-08:00'
$r = Sync $la
Assert ($r.Code -eq 0 -and $r.Out -match 'SYNCED .*fast-forward') "sync fast-forwards past a dirty task file and a dirty stamp ($($r.Code))"
Assert (([IO.File]::ReadAllText((Join-Path $la 'code.txt'))).Trim() -eq 'v2') 'the trunk''s change arrived'
Assert (([IO.File]::ReadAllText((Join-Path $la 'task.md'))).Trim() -eq 'status: in-progress') 'the dirty task file is exactly as it was'
Assert (([IO.File]::ReadAllText((Join-Path $la 'test\win32\shared.stamp.json'))) -match '13:00:00') 'the newer (local) stamp is kept'
Assert ((StashCount $la) -eq 0) 'and the stash is still empty'

# 2. An OLDER dirty stamp gives way to the pulled newer one.
Move-Trunk '2026-11-05T15:00:00-08:00' ''
Stamp $la '2026-11-05T14:00:00-08:00'
$r = Sync $la
Assert ($r.Code -eq 0 -and $r.Out -match 'stamp dropped') 'an older dirty stamp is dropped for the newer pulled one'

# 3. A real edit overlapping the incoming change: refused, edit untouched, the
#    remedy named, nothing stashed.
Move-Trunk '2026-11-05T16:00:00-08:00' 'v3'
Write-Utf8 (Join-Path $la 'code.txt') "half-written`n"
$r = Sync $la
Assert ($r.Code -eq 6 -and $r.Out -match 'never with --autostash') 'an overlapping real edit is refused with the remedy named'
Assert (([IO.File]::ReadAllText((Join-Path $la 'code.txt'))).Trim() -eq 'half-written') 'and the edit is exactly as it was'
Assert ((StashCount $la) -eq 0) 'and nothing was stashed'
G $la @('checkout', '-q', 'HEAD', '--', 'code.txt') | Out-Null

# 4. A local unpushed commit plus a dirty stamp: rebase pull, stamp parked.
Write-Utf8 (Join-Path $la 'mine.txt') "mine`n"
G $la @('add', 'mine.txt') | Out-Null
G $la @('-c', 'core.hooksPath=', 'commit', '-q', '-m', 'local work') | Out-Null
G $la @('checkout', '-q', 'HEAD', '--', 'task.md') | Out-Null
Move-Trunk '2026-11-05T17:00:00-08:00' ''
Stamp $la '2026-11-05T18:00:00-08:00'
$r = Sync $la
$ahead = (G $la @('rev-list', '--count', '@{u}..HEAD')).Out
$behind = (G $la @('rev-list', '--count', 'HEAD..@{u}')).Out
Assert ($r.Code -eq 0 -and $r.Out -match 'rebase pull' -and $r.Out -match 'parking 1 dirty guard stamp') "a local commit is rebased with the dirty stamp parked ($($r.Code))"
Assert ($ahead -eq '1' -and $behind -eq '0') 'the local commit sits on top of the trunk'
Assert ((StashCount $la) -eq 0) 'and the stash is still empty'

# 5. Litter on the stack is named, never popped.
Write-Utf8 (Join-Path $la 'mine.txt') "dirty`n"
G $la @('stash', 'push', '-q', '-m', 'autostash') | Out-Null
$r = Sync $la
Assert ($r.Code -eq 0 -and $r.Out -match '1 autostash entry on the shared stash' -and (StashCount $la) -eq 1) 'an autostash entry already on the stash is named and left alone'

if ($NegativeControl) {
    Assert ((Get-Verdict 'git pull --rebase --autostash') -eq 'ALLOW') 'NEGATIVE CONTROL: an autostash pull must be denied (this must FAIL)'
}

Complete-TestBody  # T1039: the run reached the end of its body
} finally {
    if (Test-Path $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
}

# --- stamp (T783) -----------------------------------------------------------
if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard deny-git-autostash -Repo $repo | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Label 'DENY-GIT-AUTOSTASH' -MinPass 30
