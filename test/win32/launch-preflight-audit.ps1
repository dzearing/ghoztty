# T1033 meta-check: a test\win32 script that LAUNCHES the app must run the
# build-mode pre-flight first - as a CHECKED property, not a remembered rule.
#
# Why: `Assert-GhozttyIsolatedBuild` (lib\BuildMode.ps1) is the only thing that
# stops an acceptance run driving the terminal the user is sitting in. A
# zig-out built without `-Doptimize=Debug` derives the SAME app pipe, agent
# pipe and state directory as their installed release, so every `+new-window`
# opens a window in their session, every kill matches nothing, and the script
# passes while measuring a binary nobody here built (T350 has the field
# report). 51 scripts asked the question. banner-resize-repaint.ps1 launched
# the app without asking, and nothing enumerated who else did - which is the
# hole this scan closes.
#
# WHAT COUNTS AS LAUNCHING THE APP, read off the PowerShell AST (T1029; T1033's
# text regex missed two real launchers): a `Start-Process` that mentions an app
# var or path anywhere in its arguments, the call operator on one, or a static
# call into a type the script itself declares with Add-Type (a P/Invoke
# CreateProcessW launcher). An "app var" is one this script binds to a
# `ghoztty.exe` by assignment or param() default. `Get-RawAppLaunch` has the
# detail. Deliberately NOT covered:
#
#   * `Start-OnTestDesktop` - since T1033 the helper runs the pre-flight itself
#     for any exe named ghoztty.exe, which is how ~80 GUI scripts get it, and
#     it answers for the `& $exe +verb` CLI calls those scripts make after it
#     (not for a raw launch beside it). That seam is not assumed either:
#     section B EXERCISES it against stub exes, so a refactor that drops the
#     assert fails here rather than years later.
#   * `ghoztty-agent.exe` launches, by the APP scan. Since T1036 they are a
#     second scan of their own (Get-AgentPreflightViolation): the agent answers
#     `--build-mode` and only `Assert-GhozttyIsolatedAgent` (or an explicit
#     `# agent-preflight: none - <why>`) answers for it. An app-side claim does
#     NOT - it checks the wrong binary, which is why T1033 left the agent out
#     rather than accept one. `--version` / `--build-mode` / `--help` queries
#     are not launches: they print a line and exit.
#   * `+verb` CLI calls with no process launch - that is isolation-meta.ps1's
#     property (a private endpoint), which is a different question about the
#     same run.
#
# WHAT COUNTS AS ASKING: a call to any function that reaches the gate -
# `Assert-GhozttyIsolatedBuild` itself, `Reset-GhozttyTestState` (CleanSlate)
# or `Assert-GhozttyPrivateEndpoint` (Isolation) - or an explicit, reviewable
# `# preflight: none - <why>` for a script that launches something the gate
# genuinely cannot vouch for.
#
# Like isolation-meta.ps1 this is a PRESENCE check by design: an execution-order
# check would have to trace PowerShell, and presence catches the class that
# burned us - nobody asked at all - without ever crying wolf. Section A proves
# the scan still bites on synthetic fixtures, so a green run here means the
# scanner works AND the tree is clean.
#
#   powershell -NoProfile -File test\win32\launch-preflight-audit.ps1
#
# Non-interactive; launches nothing real. The release cases are played by stub
# exes that print a `+version` banner, the same trick build-mode-guard.ps1 uses.
#
# isolation: none - every CLI verb in this file is prose or fixture text, and
# the only exe ever run is a stub .cmd in $env:TEMP that echoes a banner. There
# is no endpoint to make private.
#
# @lineage-safe - the lineage is cleared only for B5z/B5y, whose one call is Start-OnTestDesktop on a stub path under this run's %TEMP% dir that the build-mode gate refuses (REFUSING TO RUN, asserted) before anything is launched; the caller's lineage is put back right after B5
param([string]$Repo)

$ErrorActionPreference = 'Continue'
if (-not $Repo) { $Repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }

# T1511: the shared scorer, and the dot-source is also what ARMS the run - a
# body that unwinds before `Complete-TestBody` may not print a pass, and the
# guard-stamping child below reads the same state and refuses to write.
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:failures = 0
$script:passes = 0
function Assert($name, $cond, $detail = '') {
    if ($cond) { "  PASS $name"; $script:passes++ }
    else { "  FAIL $name $detail"; $script:failures++ }
}

# Run a scriptblock and return the exception message it threw, or $null.
function Get-Throw($block) {
    try { & $block | Out-Null; return $null } catch { return "$($_.Exception.Message)" }
}

$ClaimPattern = 'Assert-GhozttyIsolatedBuild|Reset-GhozttyTestState|Assert-GhozttyPrivateEndpoint|#\s*preflight:\s*none'
# T1029: a Start-OnTestDesktop launch answers for the CLI calls (`& $exe`) that
# follow it - the helper runs the gate for any ghoztty.exe (section B proves
# it), and ~60 GUI scripts launch through it and then drive the CLI that way.
# It does NOT answer for a raw Start-Process or a P/Invoke launch beside it.
$DesktopClaimPattern = 'Start-OnTestDesktop'

# A variable name without its scope prefix, lowercased: `$script:exe` and `$exe`
# are the same binding for this question.
function Get-AstVarKey($VarAst) {
    return (($VarAst.VariablePath.UserPath -split ':')[-1]).ToLower()
}

# Every variable this script binds to a path ending in ghoztty.exe - by
# assignment or by a param() default. Binding is what makes the variable NAME
# meaningful: $AgentExe and $ClientExe are launched the same way and are not
# the app, so the scan reads bindings rather than guessing from names.
function Get-AppExeVariable($Ast, [string]$Leaf = 'ghoztty\.exe') {
    $vars = @{}
    $assigns = $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)
    foreach ($a in $assigns) {
        if ($a.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
            $a.Right.Extent.Text -match "(?i)$Leaf") { $vars[(Get-AstVarKey $a.Left)] = $true }
    }
    $params = $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ParameterAst] }, $true)
    foreach ($p in $params) {
        if ($p.DefaultValue -and $p.DefaultValue.Extent.Text -match "(?i)$Leaf") {
            $vars[(Get-AstVarKey $p.Name)] = $true
        }
    }
    return $vars
}

# The app launches this script performs itself, as human-readable strings.
#
# T1029: read off the AST, not a regex over the text. T1033's regex knew one
# shape - `Start-Process $exe` - and two scripts launched the app in shapes it
# could not see, so neither was ever asked the pre-flight question:
#
#   * agent-pipe.ps1:  Start-Process cmd.exe -ArgumentList "/c `"$Exe`" ..."
#     (the app var is INSIDE an argument string, not the -FilePath)
#   * test-desktop-spike.ps1:  [DeskSpike]::Run($exe, ...) - its own Add-Type
#     class calls CreateProcessW, so no PowerShell launch verb appears at all
#
# So a launch is any of:
#   L1  a Start-Process whose arguments mention an app var or an app path
#       anywhere, nested strings included
#   L2  the call operator on one: `& $exe +list` runs the CLI, and a release
#       CLI dials the user's app
#   L3  a static call into a type THIS script declares (Add-Type `class X`)
#       with an app var as an argument - a P/Invoke launcher. Restricted to the
#       script's own types so `[regex]::Escape($exe)` and `[IO.File]::...` are
#       never read as launches.
#
# T1036: -Leaf 'ghoztty-agent\.exe' asks the same question about the agent. A
# launch whose only arguments are the agent's own read-only queries
# (`--version`, `--build-mode`, `--help`) is not counted: it prints a line and
# exits without touching a pipe, a mutex or a state dir.
function Get-RawAppLaunch([string]$Text, [string]$Leaf = 'ghoztty\.exe') {
    $tok = $null; $err = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tok, [ref]$err)
    $vars = Get-AppExeVariable $ast $Leaf
    $isApp = {
        param($n)
        ($n -is [System.Management.Automation.Language.VariableExpressionAst] -and
            $vars.ContainsKey((Get-AstVarKey $n))) -or
        ($n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
            $n.Value -match "(?i)$Leaf`$")
    }
    $isQueryOnly = {
        param($c)
        $words = @($c.CommandElements | Select-Object -Skip 1 | ForEach-Object {
            $_.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) |
                ForEach-Object { $_.Value }
        } | Where-Object { $_ -match '^--?\w' })
        $flags = @($words | Where-Object { $_ -notmatch '^-(FilePath|ArgumentList|PassThru|Wait|NoNewWindow|WindowStyle|RedirectStandard\w+)$' })
        ($flags.Count -gt 0) -and (@($flags | Where-Object { $_ -notmatch '^--(version|build-mode|help)$' }).Count -eq 0)
    }
    $ownTypes = @{}
    foreach ($m in [regex]::Matches($Text, '\b(?:class|struct)\s+(\w+)')) { $ownTypes[$m.Groups[1].Value.ToLower()] = $true }

    $hits = @()
    $cmds = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
    foreach ($c in $cmds) {
        if ($c.GetCommandName() -eq 'Start-Process') {
            if (@($c.FindAll($isApp, $true)).Count -eq 0) { continue }
            if ($Leaf -ne 'ghoztty\.exe' -and (& $isQueryOnly $c)) { continue }
            # Which element is the -FilePath: the named one, else the first
            # positional. The app AS the file is a direct launch; the app
            # inside a wrapper's arguments (`cmd /c "$Exe" +verb > out`) is the
            # CLI-call idiom, the same question as `& $exe`.
            $els = $c.CommandElements
            $file = $null
            for ($i = 1; $i -lt $els.Count; $i++) {
                $e = $els[$i]
                if ($e -is [System.Management.Automation.Language.CommandParameterAst]) {
                    if ('filepath'.StartsWith($e.ParameterName.ToLower()) -and $e.ParameterName.Length -ge 2) {
                        $file = if ($e.Argument) { $e.Argument } elseif ($i + 1 -lt $els.Count) { $els[$i + 1] } else { $null }
                        break
                    }
                    if (-not $e.Argument -and $i + 1 -lt $els.Count -and
                        $els[$i + 1] -isnot [System.Management.Automation.Language.CommandParameterAst] -and
                        $e.ParameterName -notmatch '^(?i)(PassThru|Wait|NoNewWindow|UseNewEnvironment|LoadUserProfile)$') { $i++ }
                    continue
                }
                if ($null -eq $file) { $file = $e; break }
            }
            if ($null -ne $file -and @($file.FindAll($isApp, $true)).Count -gt 0) {
                $hits += "Start-Process <app> (line $($c.Extent.StartLineNumber))"
            } else {
                $hits += "cli Start-Process <wrapper> <app> (line $($c.Extent.StartLineNumber))"
            }
        } elseif ($c.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Ampersand -and
                  (& $isApp $c.CommandElements[0])) {
            if ($Leaf -ne 'ghoztty\.exe' -and (& $isQueryOnly $c)) { continue }
            $hits += "& $($c.CommandElements[0].Extent.Text) (line $($c.Extent.StartLineNumber))"
        }
    }
    $members = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Static }, $true)
    foreach ($m in $members) {
        if ($m.Expression -isnot [System.Management.Automation.Language.TypeExpressionAst]) { continue }
        $type = (($m.Expression.TypeName.Name -split '\.')[-1]).ToLower()
        if (-not $ownTypes.ContainsKey($type)) { continue }
        foreach ($arg in @($m.Arguments)) {
            if ($null -ne $arg -and (& $isApp $arg)) {
                $hits += "$($m.Expression.Extent.Text)::$($m.Member.Extent.Text)(<app>) (line $($m.Extent.StartLineNumber))"
                break
            }
        }
    }
    return $hits
}

# $null when the file is fine, else a one-line reason.
function Get-PreflightViolation([string]$Path) {
    $text = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrEmpty($text)) { return $null }
    $hits = @(Get-RawAppLaunch $text)
    if ($hits.Count -eq 0) { return $null }
    if ($text -match $ClaimPattern) { return $null }
    if ($text -match $DesktopClaimPattern) {
        $hits = @($hits | Where-Object { -not ($_.StartsWith('& ') -or $_.StartsWith('cli ')) })
        if ($hits.Count -eq 0) { return $null }
    }
    return "launches the app ($($hits[0])) with no build-mode pre-flight"
}

# T1036: the agent half. An agent launch is answered ONLY by the agent's own
# gate - an app-side claim checks the wrong binary, which is why T1033 left the
# agent out rather than accept one - or by an explicit
# `# agent-preflight: none - <why>`.
$AgentClaimPattern = 'Assert-GhozttyIsolatedAgent|#\s*agent-preflight:\s*none'
$AgentLeaf = 'ghoztty-agent\.exe'

function Get-AgentPreflightViolation([string]$Path) {
    $text = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrEmpty($text)) { return $null }
    $hits = @(Get-RawAppLaunch $text $AgentLeaf)
    if ($hits.Count -eq 0) { return $null }
    if ($text -match $AgentClaimPattern) { return $null }
    return "launches the agent ($($hits[0] -replace '<app>', '<agent>')) with no agent build-mode pre-flight"
}

$tmp = Join-Path $env:TEMP "ghoztty-launchpre-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

# A stub that answers `+version` the way the real exe does. $Mode = '' prints no
# build-mode line at all - an exe too old to have one, or one that fails.
function New-StubExe($name, $Mode) {
    $path = Join-Path $tmp "$name.cmd"
    $lines = @('@echo off', 'echo Ghostty 1.4.0-stub', 'echo Build Config')
    if ($Mode) { $lines += "echo   - build mode    : .$Mode" }
    Set-Content -LiteralPath $path -Value $lines -Encoding ascii
    return $path
}

try {

# ---------------------------------------------------------------------------
"== A: the scan itself still bites (synthetic fixtures)"
# ---------------------------------------------------------------------------
$fixDir = Join-Path $tmp 'fixtures'
New-Item -ItemType Directory -Force $fixDir | Out-Null

function New-Fixture($name, [string[]]$lines) {
    $p = Join-Path $fixDir "$name.ps1"
    Set-Content -LiteralPath $p -Encoding ASCII -Value $lines
    return $p
}

$bad = New-Fixture 'bad' @(
    '$exe = Join-Path $repo ''zig-out\bin\ghoztty.exe''',
    '$p = Start-Process -FilePath $exe -PassThru'
)
Assert 'A1 a raw app launch with no pre-flight is flagged' `
    ($null -ne (Get-PreflightViolation $bad))

$asserted = New-Fixture 'asserted' @(
    '$exe = Join-Path $repo ''zig-out\bin\ghoztty.exe''',
    'Assert-GhozttyIsolatedBuild -Exe $exe | Out-Null',
    '$p = Start-Process -FilePath $exe -PassThru'
)
Assert 'A2 Assert-GhozttyIsolatedBuild counts as the pre-flight' `
    ($null -eq (Get-PreflightViolation $asserted))

$reset = New-Fixture 'reset' @(
    '$Exe = ''D:\git\ghoztty\zig-out\bin\ghoztty.exe''',
    '[void](Reset-GhozttyTestState -Exe $Exe)',
    'Start-Process -FilePath $Exe -WindowStyle Minimized | Out-Null'
)
Assert 'A3 Reset-GhozttyTestState counts (it asserts first)' `
    ($null -eq (Get-PreflightViolation $reset))

$priv = New-Fixture 'priv' @(
    '$Exe = ''D:\git\ghoztty\zig-out\bin\ghoztty.exe''',
    'Assert-GhozttyPrivateEndpoint -Exe $Exe',
    'Start-Process $Exe | Out-Null'
)
Assert 'A4 Assert-GhozttyPrivateEndpoint counts (same gate)' `
    ($null -eq (Get-PreflightViolation $priv))

$marked = New-Fixture 'marked' @(
    '# preflight: none - launches a stub, not a build of ours',
    '$exe = Join-Path $stub ''ghoztty.exe''',
    'Start-Process -FilePath $exe | Out-Null'
)
Assert 'A5 an explicit preflight: none marker counts as an answer' `
    ($null -eq (Get-PreflightViolation $marked))

$agent = New-Fixture 'agent' @(
    '$AgentExe = ''D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe''',
    'Start-Process -FilePath $AgentExe -PassThru | Out-Null'
)
Assert 'A6 an agent-only launcher is not the APP scan''s business' `
    ($null -eq (Get-PreflightViolation $agent))
# T1036: ...it is the agent scan's. A6 used to stop here, by design.
Assert 'A6a an agent launch with no agent pre-flight is flagged' `
    ($null -ne (Get-AgentPreflightViolation $agent))

$agentAppClaim = New-Fixture 'agentappclaim' @(
    '$Exe = ''D:\git\ghoztty\zig-out\bin\ghoztty.exe''',
    '$AgentExe = ''D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe''',
    'Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null',
    'Start-Process -FilePath $AgentExe -PassThru | Out-Null'
)
Assert 'A6b an app-side claim does NOT answer for an agent launch (it checks the wrong binary)' `
    ($null -ne (Get-AgentPreflightViolation $agentAppClaim))

$agentOk = New-Fixture 'agentok' @(
    '$AgentExe = ''D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe''',
    'Assert-GhozttyIsolatedAgent -Exe $AgentExe | Out-Null',
    'Start-Process -FilePath $AgentExe -PassThru | Out-Null'
)
Assert 'A6c Assert-GhozttyIsolatedAgent answers it' `
    ($null -eq (Get-AgentPreflightViolation $agentOk))

$agentQuery = New-Fixture 'agentquery' @(
    'param([string]$AgentExe = ''D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe'')',
    '$v = Start-Process -FilePath $AgentExe -ArgumentList @(''--version'') -PassThru -WindowStyle Hidden',
    '$m = & $AgentExe --build-mode'
)
Assert 'A6d a --version / --build-mode query is not a launch (it touches no endpoint)' `
    ($null -eq (Get-AgentPreflightViolation $agentQuery))

$agentCall = New-Fixture 'agentcall' @(
    '$agentExe = Join-Path $bin ''ghoztty-agent.exe''',
    '& $agentExe --listen-pipe=\\.\pipe\x --headless'
)
Assert 'A6e the call operator on the agent with real arguments is a launch' `
    ($null -ne (Get-AgentPreflightViolation $agentCall))

$agentMarked = New-Fixture 'agentmarked' @(
    '# agent-preflight: none - launches a stub agent under $env:TEMP',
    '$AgentExe = Join-Path $stub ''ghoztty-agent.exe''',
    'Start-Process -FilePath $AgentExe | Out-Null'
)
Assert 'A6f an explicit agent-preflight: none marker counts as an answer' `
    ($null -eq (Get-AgentPreflightViolation $agentMarked))

$desk = New-Fixture 'desk' @(
    '$exe = Join-Path $repo ''zig-out\bin\ghoztty.exe''',
    '$app = Start-OnTestDesktop -Exe $exe -Arguments @(''--session-persistence=false'')'
)
Assert 'A7 a Start-OnTestDesktop launch is covered by the helper' `
    ($null -eq (Get-PreflightViolation $desk))

$cmd = New-Fixture 'cmd' @(
    '$p = Start-Process -FilePath cmd.exe -ArgumentList ''/c echo hi'' -PassThru'
)
Assert 'A8 a launch that is not the app needs nothing' `
    ($null -eq (Get-PreflightViolation $cmd))

# T1029: the shapes the text regex could not see. Each is the real script's
# idiom, cut down to the launch.
$nested = New-Fixture 'nested' @(
    'param([string]$Exe = ''D:\git\ghoztty\zig-out\bin\ghoztty.exe'')',
    '$p = Start-Process -FilePath cmd.exe -WindowStyle Hidden -PassThru `',
    '    -ArgumentList "/c `"`"$Exe`" +sessions > out.txt 2>&1`""'
)
Assert 'A9 an app var inside a Start-Process argument string is a launch (agent-pipe shape)' `
    ($null -ne (Get-PreflightViolation $nested))

$pinvoke = New-Fixture 'pinvoke' @(
    'Add-Type @''',
    'public class FixSpike { public static void Run(string exe) { /* CreateProcessW(exe, ...) */ } }',
    '''@',
    '$exe = Join-Path $repo ''zig-out\bin\ghoztty.exe''',
    '[FixSpike]::Run($exe)'
)
Assert 'A10 a call into the script''s own Add-Type launcher is a launch (test-desktop-spike shape)' `
    ($null -ne (Get-PreflightViolation $pinvoke))

$callop = New-Fixture 'callop' @(
    '$script:exe = Join-Path $repo ''zig-out\bin\ghoztty.exe''',
    '$json = & $exe +list --json'
)
Assert 'A11 the call operator on the app is a launch (a release CLI dials the user''s app)' `
    ($null -ne (Get-PreflightViolation $callop))

$bcl = New-Fixture 'bcl' @(
    '$exe = Join-Path $repo ''zig-out\bin\ghoztty.exe''',
    '$rx = [regex]::Escape($exe)',
    '$ok = [IO.File]::Exists($exe)'
)
Assert 'A12 a framework call that merely takes the path is NOT a launch' `
    ($null -eq (Get-PreflightViolation $bcl))

$deskcli = New-Fixture 'deskcli' @(
    '$exe = Join-Path $repo ''zig-out\bin\ghoztty.exe''',
    '$app = Start-OnTestDesktop -Exe $exe',
    '$json = & $exe +list --json'
)
Assert 'A13 CLI calls after a Start-OnTestDesktop launch are answered by the helper' `
    ($null -eq (Get-PreflightViolation $deskcli))

$deskraw = New-Fixture 'deskraw' @(
    '$exe = Join-Path $repo ''zig-out\bin\ghoztty.exe''',
    '$app = Start-OnTestDesktop -Exe $exe',
    '$p = Start-Process -FilePath $exe -PassThru'
)
Assert 'A14 but a raw launch BESIDE Start-OnTestDesktop still needs its own pre-flight' `
    ($null -ne (Get-PreflightViolation $deskraw))

$prose = New-Fixture 'prose' @(
    '# Start-Process $exe and & $exe +list are discussed here, never run.',
    '$exe = Join-Path $repo ''zig-out\bin\ghoztty.exe''',
    '"  the old shape was: Start-Process $exe"'
)
Assert 'A15 a launch that only appears in a comment or a string is not one' `
    ($null -eq (Get-PreflightViolation $prose))

$deskwrap = New-Fixture 'deskwrap' @(
    'param([string]$Exe = ''D:\git\ghoztty\zig-out\bin\ghoztty.exe'')',
    '$app = Start-OnTestDesktop -Exe $Exe',
    '$p = Start-Process -FilePath cmd.exe -WindowStyle Hidden -PassThru -ArgumentList "/c `"`"$Exe`" +list"'
)
Assert 'A16 a cmd-wrapped CLI call after Start-OnTestDesktop is answered by the helper' `
    ($null -eq (Get-PreflightViolation $deskwrap))

$deskpos = New-Fixture 'deskpos' @(
    'param([string]$Exe = ''D:\git\ghoztty\zig-out\bin\ghoztty.exe'')',
    '$app = Start-OnTestDesktop -Exe $Exe',
    '$p = Start-Process -WindowStyle Minimized -PassThru $Exe'
)
Assert 'A17 the app as a positional -FilePath after other params is still a direct launch' `
    ($null -ne (Get-PreflightViolation $deskpos))

# ---------------------------------------------------------------------------
"== B: the helper the other ~80 scripts rely on really does ask"
# ---------------------------------------------------------------------------
# Behavioral, not textual: Start-OnTestDesktop is called for real, with stubs
# standing in for the exe. The refusal has to come BEFORE the desktop is
# resolved, which is also why these cases need no test desktop to run.
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\AgentLineage.ps1')

$stubDir = Join-Path $tmp 'stub'
New-Item -ItemType Directory -Force $stubDir | Out-Null
# Nothing here is runnable, and that is the point: the gate speaks before
# anything is launched, and an exe whose `+version` cannot be read is refused
# for the same reason a ReleaseFast one is - a run we cannot vouch for is
# exactly the run that leaks into the user's terminal.
$stubApp = Join-Path $stubDir 'ghoztty.exe'
# persistence: n/a - every $stubApp launch below is REFUSED by the preflight
# gate (or stops at "No test desktop"), so no app ever starts and there is
# nothing for a session to restore into.
$msgUnreadable = Get-Throw { Start-OnTestDesktop -Exe $stubApp }
Assert 'B1 Start-OnTestDesktop refuses an exe it cannot vouch for' `
    ($null -ne $msgUnreadable)
Assert 'B2 and it is the build-mode gate that speaks' `
    ($msgUnreadable -match 'REFUSING TO RUN') "(got: $msgUnreadable)"

# The stub with a readable ReleaseFast banner, to prove B1/B2 are not passing
# merely because the file is missing: this one runs and still gets refused.
$fastNamed = New-StubExe 'ghoztty.exe' 'ReleaseFast'
Assert 'B3 the stub really does report ReleaseFast' `
    ((Get-GhozttyBuildMode -Exe $fastNamed) -eq 'ReleaseFast')
Assert 'B4 and a readable release build is refused too' `
    ((Get-Throw { Assert-GhozttyIsolatedBuild -Exe $fastNamed }) -match 'REFUSING TO RUN')

# Past the gate, the next thing to complain is the desktop - which is how these
# prove the gate let them through rather than that it never ran.
#
# T1158: -AllowReleaseBuild is no longer a free pass. A release-lineage run has
# to hold all three isolating knobs, so the pass-through is shown from a
# sandboxed state - and B5z first shows that the launcher cannot be used to
# smuggle a PARTLY isolated release run past the tightened gate, which is the
# state soak.ps1 was in when it seeded the user's agent with pinned sessions.
$savedB5Suffix = $env:GHOZTTY_PIPE_SUFFIX
$savedB5Inst = Get-GhozttyAgentLineage
$savedB5Lad = $env:LOCALAPPDATA

$env:GHOZTTY_PIPE_SUFFIX = "-lpa$PID"
Remove-Item Env:GHOZTTY_AGENT_INSTANCE -ErrorAction SilentlyContinue
$env:LOCALAPPDATA = [Environment]::GetFolderPath('LocalApplicationData')
# persistence: n/a - refused by the gate; nothing starts.
$msgPartial = Get-Throw { Start-OnTestDesktop -Exe $stubApp -AllowReleaseBuild }
Assert 'B5z -AllowReleaseBuild does not excuse a partly-isolated release run' `
    ($msgPartial -match 'REFUSING TO RUN') "(got: $msgPartial)"
Assert 'B5y and the refusal names the knob that is missing' `
    ($msgPartial -match 'GHOZTTY_AGENT_INSTANCE is unset') "(got: $msgPartial)"

$env:GHOZTTY_AGENT_INSTANCE = "lpa$PID"
$env:LOCALAPPDATA = Join-Path $stubDir 'sandbox-lad'
# persistence: n/a - stops at "No test desktop"; the stub never runs.
$msgAllow = Get-Throw { Start-OnTestDesktop -Exe $stubApp -AllowReleaseBuild }
Assert 'B5 -AllowReleaseBuild reaches the gate and passes through once isolated' `
    ($msgAllow -match 'No test desktop') "(got: $msgAllow)"

if ($null -eq $savedB5Suffix) { Remove-Item Env:GHOZTTY_PIPE_SUFFIX -ErrorAction SilentlyContinue }
else { $env:GHOZTTY_PIPE_SUFFIX = $savedB5Suffix }
Restore-GhozttyAgentLineage -Saved $savedB5Inst
$env:LOCALAPPDATA = $savedB5Lad

# T1036: the agent is gated too - by its OWN gate, which is what speaks.
# persistence: n/a - refused by the agent gate; nothing starts.
$msgAgent = Get-Throw { Start-OnTestDesktop -Exe (Join-Path $stubDir 'ghoztty-agent.exe') }
Assert 'B6 Start-OnTestDesktop refuses an agent it cannot vouch for, through the agent gate' `
    ($msgAgent -match 'Assert-GhozttyIsolatedAgent: REFUSING TO RUN') "(got: $msgAgent)"

# persistence: n/a - stops at "No test desktop"; the stub never runs.
$msgOther = Get-Throw { Start-OnTestDesktop -Exe (Join-Path $stubDir 'helper.exe') }
Assert 'B6b a launch that is neither the app nor the agent is not gated at all' `
    ($msgOther -match 'No test desktop') "(got: $msgOther)"

# ---------------------------------------------------------------------------
"== C: the real tree is clean"
# ---------------------------------------------------------------------------
$self = Split-Path -Leaf $PSCommandPath
# lib\ is swept too: no helper there launches the app today (they launch cmd.exe
# as a pane payload), and a future one that does would otherwise be the one
# place the sweep could not see.
$scripts = @(Get-ChildItem (Join-Path $Repo 'test\win32\*.ps1') -File |
    Where-Object { $_.Name -ne $self }) +
    @(Get-ChildItem (Join-Path $Repo 'test\win32\lib\*.ps1') -File)
Assert 'C1 the sweep found a plausible number of scripts' ($scripts.Count -ge 50) `
    "(got $($scripts.Count))"

$launchers = 0
$agentLaunchers = 0
$violations = @()
foreach ($s in $scripts) {
    $text = Get-Content -LiteralPath $s.FullName -Raw -ErrorAction SilentlyContinue
    if (@(Get-RawAppLaunch $text).Count -gt 0) { $launchers++ }
    if (@(Get-RawAppLaunch $text $AgentLeaf).Count -gt 0) { $agentLaunchers++ }
    $why = Get-PreflightViolation $s.FullName
    if ($null -ne $why) { $violations += "$($s.Name): $why" }
    $why = Get-AgentPreflightViolation $s.FullName
    if ($null -ne $why) { $violations += "$($s.Name): $why" }
}
"  ($agentLaunchers script(s) launch the agent themselves)"
"  ($launchers script(s) launch the app themselves)"
foreach ($v in $violations) { "  VIOLATION $v" }
Assert 'C2 every script that launches the app runs the pre-flight first' `
    ($violations.Count -eq 0) "($($violations.Count) violation(s))"
# The scan is worthless if it stops finding the launches: a regex that matches
# nothing would report a clean tree forever.
Assert 'C3 the scan still recognises real launches' ($launchers -ge 5) `
    "(found $launchers)"
Assert 'C4 and real agent launches (T1036: 29 when the agent scan landed)' ($agentLaunchers -ge 20) `
    "(found $agentLaunchers)"

} catch {
    # T1511: score the throw rather than unwinding past it to a green verdict.
    Assert 'the run finished its sections' $false "(threw: $($_.Exception.Message))"
    $_.ScriptStackTrace
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

# A clean green run stamps the covered files (T783) so scripts\guard-due.ps1
# can answer "has this scan been run against the test tree as it now stands?".
Complete-TestBody  # T1039: before the stamp, which is a child process reading this run's state
if ($script:failures -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard launch-preflight -Repo $Repo 2>&1 | ForEach-Object { "  $_" }
}

""
Write-TestVerdict -Pass $script:passes -Fail $script:failures
