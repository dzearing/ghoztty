# T1263 acceptance: scripts\hooks\deny-escape-damage.ps1, the PreToolUse hook
# that refuses an Edit/Write whose new text holds a backslash escape decoded
# into a control character (`zig-out\bin` arriving as `zig-out<0x08>in`).
#
#   A. The decision table, via -Text/-FilePath: each byte the decode produces
#      (0x07, 0x08, 0x0c, a lone CR, a tab inside a path) is DENIED; correct
#      paths, CRLF, ordinary tabs and an out-of-scope file are ALLOWED.
#   B. The hook envelope: stdin JSON from Write, Edit and MultiEdit -> a deny
#      decision on stdout, exit 0; a repair edit (damage only in old_string),
#      a clean write, another tool and garbage input -> no output, exit 0
#      (fail-open).
#   C. Wiring: .claude/settings.json registers the script for the file-writing
#      tools, and the registered command line produces the deny when run
#      through Git Bash the way Claude Code runs hooks.
#   D. One definition: the hook and the commit-time scanner
#      (scripts\control-char-scan.ps1) both read scripts\lib\EscapeDamage.ps1,
#      so the write-time and commit-time answers cannot drift apart.
#
#   -NegativeControl adds one inverted assertion a healthy tree MUST fail, so
#   the run ends with exactly one failure.
#
# Non-interactive. Nothing here writes a repository file or opens a window.
#
# isolation: none - this script never runs a ghoztty verb.
[CmdletBinding(PositionalBinding = $false)]
param([switch]$NegativeControl)

$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$hook = Join-Path $repo 'scripts\hooks\deny-escape-damage.ps1'

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:fail = 0
$script:pass = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" }
}

function Get-Verdict([string]$text, [string]$path = 'docs\x.md') {
    return ((& $hook -Text $text -FilePath $path) | Out-String).Trim()
}

function Invoke-Hook($payload) {
    # A child process, because the hook reads its payload from stdin. The
    # payload is serialized here, so a control character travels the way
    # Claude Code sends one: as a \u00XX escape inside the JSON.
    $json = if ($payload -is [string]) { $payload } else { $payload | ConvertTo-Json -Depth 6 -Compress }
    $tmp = [IO.Path]::GetTempFileName()
    try {
        [IO.File]::WriteAllText($tmp, $json)
        $out = cmd /c "powershell -NoProfile -ExecutionPolicy Bypass -File `"$hook`" < `"$tmp`"" | Out-String
        return [pscustomobject]@{ Out = $out.Trim(); Exit = $LASTEXITCODE }
    } finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
}

function Get-Decision($r) {
    $p = $null
    try { $p = $r.Out | ConvertFrom-Json } catch {}
    if ($p) { return $p.hookSpecificOutput }
    return $null
}

$BEL = [string][char]7; $BS = [string][char]8; $FF = [string][char]12
$CR = [string][char]13; $TAB = [string][char]9

try {
Write-Host '--- A. decision table ---'
Assert ((Get-Verdict ("zig-out" + $BS + "in\ghoztty.exe")) -match '^DENY 0x08 control') '\b decoded to 0x08 (the T1251 line) is denied'
Assert ((Get-Verdict ("test\win32" + $BEL + "gent-handoff.ps1")) -match '^DENY 0x07') '\a decoded to 0x07 is denied'
Assert ((Get-Verdict ("scripts" + $FF + "loor-lane.ps1")) -match '^DENY 0x0c') '\f decoded to 0x0c is denied'
Assert ((Get-Verdict ("see test\win32" + $CR + "esize-flicker.ps1")) -match '^DENY 0x0d lone-cr') '\r decoded to a lone CR is denied'
Assert ((Get-Verdict ("'test\win32" + $TAB + "ranslucent.stamp.json'") 'scripts\guard-due.ps1') -match '^DENY 0x09 tab-in-path') '\t decoded inside a path is denied'
Assert ((Get-Verdict ("x`ny`nzig-out" + $BS + "in")) -match 'line 3') 'the refusal names the line of the new text'
Assert ((Get-Verdict ("zig-out" + $BS + "in")) -match [regex]::Escape('zig-out<0x08>in')) 'the refusal shows the byte made visible'
Assert ((Get-Verdict 'zig-out\bin\ghoztty.exe and test\win32\resize.ps1') -eq 'ALLOW') 'correctly written paths are allowed'
Assert ((Get-Verdict ("line`r`n" + $TAB + "indent`r`ncol" + $TAB + "two`r`n")) -eq 'ALLOW') 'CRLF, a leading tab and a tab between words are allowed'
Assert ((Get-Verdict ("blob" + $BEL) 'test\fuzz-libghostty\corpus\seed') -eq 'ALLOW') 'a file the scanner does not cover is not judged'
Assert ((Get-Verdict ("x" + $BS) 'src\a.ZIG') -match '^DENY') 'the extension check is case-insensitive'

Write-Host '--- B. hook envelope ---'
$damaged = "see test\win32" + $CR + "esize-flicker.ps1"
$w = Invoke-Hook @{ tool_name = 'Write'; tool_input = @{ file_path = 'D:\r\docs\a.md'; content = $damaged } }
$d = Get-Decision $w
Assert ($d -and $d.permissionDecision -eq 'deny' -and $d.hookEventName -eq 'PreToolUse') 'a damaged Write gets a PreToolUse deny decision'
Assert ($d -and $d.permissionDecisionReason -match 'doubled' -and $d.permissionDecisionReason -match 'forward slashes') 'the reason names the remedy'
Assert ($w.Exit -eq 0) 'deny is reported through JSON, exit 0'
$e = Invoke-Hook @{ tool_name = 'Edit'; tool_input = @{ file_path = 'D:\r\x.ps1'; old_string = 'a'; new_string = ("zig-out" + $BS + "in") } }
Assert ((Get-Decision $e).permissionDecision -eq 'deny') 'a damaged Edit new_string is denied'
$m = Invoke-Hook @{ tool_name = 'MultiEdit'; tool_input = @{ file_path = 'D:\r\x.md'; edits = @(
    @{ old_string = 'a'; new_string = 'fine' },
    @{ old_string = 'b'; new_string = ("scripts" + $FF + "loor") }) } }
Assert ((Get-Decision $m).permissionDecision -eq 'deny') 'a damaged second MultiEdit edit is denied'
$repair = Invoke-Hook @{ tool_name = 'Edit'; tool_input = @{ file_path = 'D:\r\x.md'; old_string = ("zig-out" + $BS + "in"); new_string = 'zig-out\bin' } }
Assert ((-not $repair.Out) -and $repair.Exit -eq 0) 'an edit that REPAIRS a damaged line passes silently'
$clean = Invoke-Hook @{ tool_name = 'Write'; tool_input = @{ file_path = 'D:\r\x.md'; content = "zig-out\bin`r`n" } }
Assert ((-not $clean.Out) -and $clean.Exit -eq 0) 'a clean write passes silently'
$other = Invoke-Hook @{ tool_name = 'Bash'; tool_input = @{ command = ("echo " + $BS) } }
Assert ((-not $other.Out) -and $other.Exit -eq 0) 'another tool is not judged'
$junk = Invoke-Hook 'not json'
Assert ((-not $junk.Out) -and $junk.Exit -eq 0) 'garbage input fails open (silent, exit 0)'

Write-Host '--- C. wiring ---'
$settingsPath = Join-Path $repo '.claude\settings.json'
$entry = $null
try {
    $settings = Get-Content -Raw $settingsPath | ConvertFrom-Json
    $entry = @($settings.hooks.PreToolUse | ForEach-Object { $_ } | Where-Object {
        @($_.hooks | Where-Object { $_.command -match 'deny-escape-damage\.ps1' }).Count -gt 0 })[0]
} catch {}
$command = if ($entry) { [string]@($entry.hooks)[0].command } else { '' }
Assert ($command -match 'deny-escape-damage\.ps1') '.claude/settings.json registers the hook'
$matcher = if ($entry) { [string]$entry.matcher } else { '' }
$tools = @($matcher -split '\|')
Assert (($tools -contains 'Edit') -and ($tools -contains 'Write') -and ($tools -contains 'MultiEdit')) 'its matcher covers Edit, Write and MultiEdit'
# Git Bash, the shell Claude Code runs hooks with on Windows - never a bare
# `bash`, which resolves to System32's WSL launcher ahead of PATH and would
# start WSL (forbidden on this box unasked).
$bash = $null
if ($env:CLAUDE_CODE_GIT_BASH_PATH -and (Test-Path $env:CLAUDE_CODE_GIT_BASH_PATH)) {
    $bash = $env:CLAUDE_CODE_GIT_BASH_PATH
} else {
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git) {
        $gitBash = Join-Path (Split-Path (Split-Path $git.Source -Parent) -Parent) 'bin\bash.exe'
        if (Test-Path $gitBash) { $bash = $gitBash }
    }
}
if ($bash -and $command) {
    $tmp = [IO.Path]::GetTempFileName()
    $payload = @{ tool_name = 'Edit'; tool_input = @{ file_path = 'x.md'; old_string = 'a'; new_string = ("zig-out" + $BS + "in") } } |
        ConvertTo-Json -Depth 4 -Compress
    [IO.File]::WriteAllText($tmp, $payload)
    $env:CLAUDE_PROJECT_DIR = $repo
    $viaBash = (Get-Content -Raw $tmp | & $bash -c $command) | Out-String
    Remove-Item $tmp -ErrorAction SilentlyContinue
    Assert ($viaBash -match '"permissionDecision":"deny"') 'the registered command line denies when run through bash'
} else {
    Assert $false 'Git Bash is present to run the registered command line'
}

Write-Host '--- D. one definition ---'
$scanText = [IO.File]::ReadAllText((Join-Path $repo 'scripts\control-char-scan.ps1'))
$hookText = [IO.File]::ReadAllText($hook)
Assert ($scanText -match 'lib\\EscapeDamage\.ps1' -and $hookText -match 'lib\\EscapeDamage\.ps1') 'the hook and the scanner both load scripts\lib\EscapeDamage.ps1'
Assert ($scanText -notmatch '\$AllowedExtensions\s*=' -and $hookText -notmatch '\[char\[\]\]\(@\(0\.\.8\)') 'neither keeps a private copy of the rules'

if ($NegativeControl) {
    Assert ((Get-Verdict 'zig-out\bin\ghoztty.exe') -match '^DENY') 'NEGATIVE CONTROL: a correct path must not be denied (this must FAIL)'
}

Complete-TestBody  # T1039: the run reached the end of its body
} finally { }

# --- stamp (T783) -----------------------------------------------------------
# A green run records the content of every file this harness covers; a red run
# leaves the stamp alone on purpose - red must stay due.
if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard deny-escape-damage -Repo $repo | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Label 'DENY-ESCAPE-DAMAGE' -MinPass 25
