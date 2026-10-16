# T680 meta-check: a test\win32 script that drives the ghoztty CLI must claim
# a private IPC endpoint - as a CHECKED property, not a remembered rule.
#
# Why: every acceptance script here is usually started from one of the user's
# own Ghoztty panes, so `$GHOZTTY_IPC_SOCKET` in its environment names the
# USER'S app, and the CLI prefers that over its own derivation. A script that
# runs a `+verb` with no isolation therefore reads - or drives - the terminal
# the user is sitting in, and grades the wrong build while it is at it. T485
# fixed one such script and asked for the sweep; the sweep found seven more
# (T680). A hand-curated list goes stale the day someone adds a script, so
# this scan runs instead.
#
# What counts as DRIVING the CLI: the script's text contains a `+verb` from
# the CLI surface (+list, +read, +send-keys, ...). What counts as CLAIMING
# isolation, any one of:
#
#   * Set-GhozttyTestIsolation   (lib\Isolation.ps1 - the preferred form:
#                                 per-PID suffix + the throwing asserts)
#   * $env:GHOZTTY_PIPE_SUFFIX = (a hand-rolled suffix; outranks the pane's
#                                 baked endpoint in the CLI's resolution order)
#   * dot-sourcing CleanSlate.ps1 (drops $GHOZTTY_IPC_SOCKET at load, so the
#                                 CLI falls back to this build's derivation)
#   * `# isolation: none - <why>` (an explicit, reviewable opt-out for a
#                                 script whose verbs live in comments or
#                                 fixtures only - say what protects it instead)
#
# Since T352 the claim also has to be unique to the RUN - section C. A suffix
# that is a fixed literal isolates this script from the OTHER scripts and from
# the user's terminal, but not from its own previous run: the instance that run
# leaked is still answering on that endpoint with its `--target=` names
# registered, and `+new-window --target=` FOCUSES a name it finds rather than
# building the fixture again. `$PID` in the suffix is what closes it, and it
# closes the whole class at one site per script instead of at every name the
# script registers. Since T903 the same question is asked of
# `GHOZTTY_AGENT_INSTANCE`, which keys the agent's own pipe and state dir: a
# fixed lineage is a leaked HOLDER from an earlier run still answering.
#
# This is a PRESENCE check on purpose. An execution-order check would need to
# actually trace PowerShell, and a text-order check ("first verb line vs first
# isolation line") was measured flagging ~13 correct scripts that define a
# Run-Cli helper above their isolation call (T680's Details). Presence catches
# the class that burned us - no isolation anywhere - and never cries wolf, so
# it can afford to run on every change. The scan proves it still BITES on
# every run: section A feeds it a synthetic violator and a synthetic
# compliant script and requires the right verdict on both.
#
#   powershell -NoProfile -File test\win32\isolation-meta.ps1
#
# preflight: none - every Start-Process in this file is fixture text written to $env:TEMP and scanned; nothing is launched.
# @lineage-safe - the only GHOZTTY_AGENT_INSTANCE assignments here are fixture lines (A11-A13) written to %TEMP% and scanned as text; this script never sets or clears the variable and launches no ghoztty process or agent (its one child is the scripts\guard-due.ps1 stamp)
param([string]$Repo)

$ErrorActionPreference = 'Stop'
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

# The CLI surface (CLAUDE.md "CLI at a glance", plus +version). A verb added
# to the product gets added here when its first test is written.
$VerbPattern = '\+(new-window|split|close|rearrange|read|list|sessions|send-keys|set-state|set-banner|reload|new-remote-window|version)\b'
$ClaimPatterns = @(
    'Set-GhozttyTestIsolation',
    'GHOZTTY_PIPE_SUFFIX\s*=',
    'CleanSlate\.ps1',
    '#\s*isolation:\s*none'
)

# Returns $null when the file is fine, else a one-line reason.
function Get-IsolationViolation([string]$Path) {
    $text = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrEmpty($text)) { return $null }
    if ($text -notmatch $VerbPattern) { return $null }
    foreach ($claim in $ClaimPatterns) {
        if ($text -match $claim) { return $null }
    }
    return 'drives the CLI (+verb) with no isolation claim'
}

# T352: a claim is only worth what it isolates FROM. A hand-rolled suffix that
# is a fixed string - `'-vptest'` - gives every run of that script the same
# endpoint, so an instance leaked by a run that died before its cleanup is
# still answering there, with its windows and its `--target=` names registered.
# `+new-window --target=X` is idempotent by design, so the next run FOCUSES
# that stale window instead of building its own fixture, and grades the
# previous build. Two runs of one script on one box collide the same way.
#
# `Set-GhozttyTestIsolation` has always appended `$PID`; the hand-rolled half
# of the suite (131 scripts as of this task) did not. This is the rule that
# stops the fixed form coming back.
#
# WHAT COUNTS AS RUN-UNIQUE, per assignment:
#   * the right-hand side mentions $PID
#   * the right-hand side is a variable or expression, not a literal - the
#     save/restore pairs (`= $savedPipe`) and the parameterised helpers
#     (`= $Suffix`) resolve to whatever their caller chose, so the literal
#     they came from is what gets judged, wherever it is written
#   * `Set-GhozttyTestIsolation` with no literal assignment anywhere
#   * `# isolation: shared - <why>` for a script that genuinely needs an
#     endpoint a second process can name from a literal. The reason is
#     required, for the same purpose it is required on a cleanslate exemption.
#
# T903: the agent's lineage is judged by the same rule. `GHOZTTY_AGENT_INSTANCE`
# keys the agent's own pipe, state dir and autostart entry, so a fixed value has
# exactly the pipe suffix's failure: a holder leaked by an earlier run of the
# script is still serving on that lineage's control pipe, and the assertion that
# reads it ("is the foreign holder still alive?") answers about the leftover.
$script:SuffixAssign = '\$env:GHOZTTY_PIPE_SUFFIX\s*=\s*([^\r\n]+)'
$script:InstanceAssign = '\$env:GHOZTTY_AGENT_INSTANCE\s*=\s*([^\r\n]+)'

function Get-SuffixUniquenessViolation([string]$Path) {
    return (Get-PinnedEnvViolation $Path $script:SuffixAssign 'pipe suffix')
}

function Get-InstanceUniquenessViolation([string]$Path) {
    return (Get-PinnedEnvViolation $Path $script:InstanceAssign 'agent lineage')
}

function Get-PinnedEnvViolation([string]$Path, [string]$Assign, [string]$What) {
    $text = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrEmpty($text)) { return $null }
    # The reason has to be ON the marker line: `\s` matches a newline in a
    # -Raw read, so a `\s*\S` tail would happily accept the next line of code
    # as the justification and turn the marker into a rubber stamp.
    if ($text -match '#[^\S\r\n]*isolation:[^\S\r\n]*shared[^\S\r\n]*-[^\S\r\n]*\S') { return $null }

    $fixed = @()
    foreach ($line in ($text -split "`r?`n")) {
        # A commented-out assignment documents; it does not aim anything.
        if ($line -match '^\s*#') { continue }
        if ($line -notmatch $Assign) { continue }
        $rhs = $Matches[1].Trim()
        if ($rhs -match '\$PID') { continue }
        # Only a bare quoted literal is judged here. Anything else defers to a
        # value chosen elsewhere, and that site is judged on its own line.
        # A `$` in the literal means the value is chosen elsewhere too: these
        # scripts generate CHILD scripts through a here-string, so the line
        # `'$instanceValue'` in the source is an interpolation whose real value
        # is whatever the parent passed (job-escape-startup, T903).
        if ($rhs -match "^'([^'$]*)'" -or $rhs -match '^"([^"$]*)"') {
            $fixed += $Matches[1]
        }
    }
    if ($fixed.Count -eq 0) { return $null }
    return "pins a FIXED $What ($($fixed -join ', ')) - a leaked instance from an earlier run answers there"
}

# T1983: two loop lanes on one box (T1937) each build a DEBUG zig-out, and every
# debug build derives the same default app pipe, `ghoztty-debug-<user>`. That
# pipe is also the app's single-instance lock (IpcServer.zig), so an
# unsuffixed launch in lane B does not start lane B's app at all: it JOINS lane
# A's test app, opens its window there, and grades lane A's binary. Section B
# could not see it, for two reasons this section closes:
#
#   * B only asks scripts that run a `+verb`. A script that LAUNCHES the app
#     and reads it some other way (window probes, the registry, a log) was
#     never asked anything.
#   * B accepts dot-sourcing CleanSlate.ps1 as a claim. That protects the
#     user's terminal - it drops the pane's baked `$GHOZTTY_IPC_SOCKET` - but
#     the CLI then falls back to the build's own derivation, which is exactly
#     the shared default pipe above.
#
# So for a script that launches the app OR drives the CLI, the claim has to be
# one that moves the endpoint off the default: `Set-GhozttyTestIsolation`, a
# `$env:GHOZTTY_PIPE_SUFFIX =` assignment (section C already holds that one to
# `$PID`), or `# isolation: none - <why>` with the reason ON the marker line.
#
# WHAT COUNTS AS LAUNCHING: `Start-Process`, `Start-OnTestDesktop`,
# `Invoke-OnTestDesktop` or `[Diagnostics.Process]::Start` on a line that names
# a `ghoztty.exe` path, or a variable this script binds to one. The agent is not
# the app (`ghoztty-agent.exe` does not match), and neither is a stub this
# script binds to some other name.
$script:LaunchVerbs = '(?i)(Start-Process|Start-OnTestDesktop|Invoke-OnTestDesktop|Diagnostics\.Process\]::Start)\b'
$script:RunUniqueClaims = @(
    'Set-GhozttyTestIsolation',
    '(?m)^[^#\r\n]*\$env:GHOZTTY_PIPE_SUFFIX\s*=',
    '#[^\S\r\n]*isolation:[^\S\r\n]*none[^\S\r\n]*-[^\S\r\n]*\S'
)

function Get-AppLaunchSite([string]$Text) {
    $vars = @{}
    foreach ($m in [regex]::Matches($Text, '(?i)\$(\w+)\s*=\s*[^\r\n]*?\bghoztty\.exe')) {
        $vars[$m.Groups[1].Value.ToLower()] = $true
    }
    $sites = @()
    $n = 0
    foreach ($line in ($Text -split "`r?`n")) {
        $n++
        if ($line -match '^\s*#') { continue }
        if ($line -notmatch $script:LaunchVerbs) { continue }
        $hit = $line -match '(?i)\bghoztty\.exe'
        if (-not $hit) {
            foreach ($m in [regex]::Matches($line, '\$(\w+)')) {
                if ($vars.ContainsKey($m.Groups[1].Value.ToLower())) { $hit = $true; break }
            }
        }
        if ($hit) { $sites += "line $n" }
    }
    return $sites
}

function Get-LaneViolation([string]$Path) {
    $text = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrEmpty($text)) { return $null }
    $sites = @(Get-AppLaunchSite $text)
    $drives = $text -match $VerbPattern
    if ($sites.Count -eq 0 -and -not $drives) { return $null }
    foreach ($claim in $script:RunUniqueClaims) {
        if ($text -match $claim) { return $null }
    }
    $what = if ($sites.Count -gt 0) { "launches the app ($($sites[0]))" } else { 'drives the CLI (+verb)' }
    return "$what on the shared default debug pipe - CleanSlate alone does not move it; set a run-unique GHOZTTY_PIPE_SUFFIX"
}

# ---------------------------------------------------------------------------
"== A: the scan itself still bites (synthetic fixtures)"
# ---------------------------------------------------------------------------
$fixDir = Join-Path $env:TEMP "ghoztty-isometa-$PID"
New-Item -ItemType Directory -Force $fixDir | Out-Null
try {
    $bad = Join-Path $fixDir 'bad.ps1'
    Set-Content -LiteralPath $bad -Encoding ASCII -Value @(
        '$exe = "D:\somewhere\ghoztty.exe"',
        '& $exe +list --json'
    )
    Assert 'A1 a script with a +verb and no claim is flagged' `
        ($null -ne (Get-IsolationViolation $bad))

    $suffixed = Join-Path $fixDir 'suffixed.ps1'
    Set-Content -LiteralPath $suffixed -Encoding ASCII -Value @(
        '$env:GHOZTTY_PIPE_SUFFIX = "-fixture"',
        '& $exe +list --json'
    )
    Assert 'A2 a hand-rolled suffix counts as a claim' `
        ($null -eq (Get-IsolationViolation $suffixed))

    $lib = Join-Path $fixDir 'lib.ps1'
    Set-Content -LiteralPath $lib -Encoding ASCII -Value @(
        '. (Join-Path $PSScriptRoot ''lib\Isolation.ps1'')',
        '[void](Set-GhozttyTestIsolation -Tag ''fixture'')',
        '& $exe +read --name=x'
    )
    Assert 'A3 Set-GhozttyTestIsolation counts as a claim' `
        ($null -eq (Get-IsolationViolation $lib))

    $marked = Join-Path $fixDir 'marked.ps1'
    Set-Content -LiteralPath $marked -Encoding ASCII -Value @(
        '# isolation: none - verbs below are fixture text, nothing is executed',
        '$doc = "run ghoztty +list yourself"'
    )
    Assert 'A4 an explicit isolation: none marker counts as a claim' `
        ($null -eq (Get-IsolationViolation $marked))

    $quiet = Join-Path $fixDir 'quiet.ps1'
    Set-Content -LiteralPath $quiet -Encoding ASCII -Value @(
        'Write-Host "no CLI here at all"'
    )
    Assert 'A5 a verb-free script needs no claim' `
        ($null -eq (Get-IsolationViolation $quiet))

    # T352: the run-uniqueness half. The same fixture that satisfies A2 must
    # FAIL here - a claim that pins one endpoint forever is exactly the shape
    # this rule exists to catch, and A2 passing on it is why the two checks
    # are separate rather than one.
    Assert 'A6 a FIXED hand-rolled suffix is flagged as not run-unique' `
        ($null -ne (Get-SuffixUniquenessViolation $suffixed))

    $unique = Join-Path $fixDir 'unique.ps1'
    Set-Content -LiteralPath $unique -Encoding ASCII -Value @(
        '$env:GHOZTTY_PIPE_SUFFIX = "-fixture$PID"',
        '& $exe +list --json'
    )
    Assert 'A7 a $PID-keyed suffix passes' `
        ($null -eq (Get-SuffixUniquenessViolation $unique))

    $restore = Join-Path $fixDir 'restore.ps1'
    Set-Content -LiteralPath $restore -Encoding ASCII -Value @(
        '$saved = $env:GHOZTTY_PIPE_SUFFIX',
        '[void](Set-GhozttyTestIsolation -Tag ''fixture'')',
        '& $exe +list --json',
        '$env:GHOZTTY_PIPE_SUFFIX = $saved'
    )
    Assert 'A8 a save/restore pair is not a pinned suffix' `
        ($null -eq (Get-SuffixUniquenessViolation $restore))

    $shared = Join-Path $fixDir 'shared.ps1'
    Set-Content -LiteralPath $shared -Encoding ASCII -Value @(
        '# isolation: shared - a second process names this endpoint by hand',
        '$env:GHOZTTY_PIPE_SUFFIX = "-fixture"',
        '& $exe +list --json'
    )
    Assert 'A9 an explicit isolation: shared marker counts' `
        ($null -eq (Get-SuffixUniquenessViolation $shared))

    $stamp = Join-Path $fixDir 'stamp.ps1'
    Set-Content -LiteralPath $stamp -Encoding ASCII -Value @(
        '# isolation: shared -',
        '$env:GHOZTTY_PIPE_SUFFIX = "-fixture"',
        '& $exe +list --json'
    )
    Assert 'A10 an EMPTY shared reason is still a violation' `
        ($null -ne (Get-SuffixUniquenessViolation $stamp))

    # T903: the agent lineage half of section C. Same rule, same fixtures -
    # demonstrated separately because it is a separate variable and a separate
    # pipe, and a check nobody has watched go red is not a check.
    $pinnedInstance = Join-Path $fixDir 'pinned-instance.ps1'
    Set-Content -LiteralPath $pinnedInstance -Encoding ASCII -Value @(
        '$env:GHOZTTY_PIPE_SUFFIX = "-fixture$PID"',
        '$env:GHOZTTY_AGENT_INSTANCE = ''otherlineage''',
        '& $exe +list --json'
    )
    Assert 'A11 a FIXED agent lineage is flagged as not run-unique' `
        ($null -ne (Get-InstanceUniquenessViolation $pinnedInstance))

    $uniqueInstance = Join-Path $fixDir 'unique-instance.ps1'
    Set-Content -LiteralPath $uniqueInstance -Encoding ASCII -Value @(
        '$env:GHOZTTY_PIPE_SUFFIX = "-fixture$PID"',
        '$env:GHOZTTY_AGENT_INSTANCE = "otherlineage-$PID"',
        '& $exe +list --json'
    )
    Assert 'A12 a $PID-keyed agent lineage passes' `
        ($null -eq (Get-InstanceUniquenessViolation $uniqueInstance))

    $generated = Join-Path $fixDir 'generated.ps1'
    Set-Content -LiteralPath $generated -Encoding ASCII -Value @(
        '$child = @"',
        '`$env:GHOZTTY_AGENT_INSTANCE = ''$instanceValue''',
        '"@',
        '& $exe +list --json'
    )
    Assert 'A13 a here-string interpolation is judged where its value is chosen' `
        ($null -eq (Get-InstanceUniquenessViolation $generated))

    # T1983: section D's launcher rule. Each fixture is a shape the tree has
    # had: the first four are the four scripts this task fixed.
    function New-LaneFixture($name, [string[]]$lines) {
        $p = Join-Path $fixDir "$name.ps1"
        Set-Content -LiteralPath $p -Encoding ASCII -Value $lines
        return $p
    }
    $rawLaunch = New-LaneFixture 'lane-raw' @(
        '$exe = Join-Path $Repo ''zig-out\bin\ghoztty.exe''',
        '$p = Start-Process -FilePath $exe -PassThru'
    )
    Assert 'A14 an app launch with no claim at all is flagged' `
        ($null -ne (Get-LaneViolation $rawLaunch))

    $deskClean = New-LaneFixture 'lane-desk-cleanslate' @(
        '. (Join-Path $PSScriptRoot ''lib\CleanSlate.ps1'')',
        '[string]$Exe = ''D:\git\ghoztty\zig-out\bin\ghoztty.exe''',
        '$app = Start-OnTestDesktop -Exe $Exe -Arguments @(''--session-persistence=false'')'
    )
    Assert 'A15 a test-desktop launch whose only claim is CleanSlate is flagged' `
        ($null -ne (Get-LaneViolation $deskClean))
    Assert 'A15b ...which section B alone accepts (why D exists)' `
        ($null -eq (Get-IsolationViolation $deskClean))

    $cliClean = New-LaneFixture 'lane-cli-cleanslate' @(
        '. (Join-Path $PSScriptRoot ''lib\CleanSlate.ps1'')',
        '& $exe +new-window --target=x'
    )
    Assert 'A16 a CLI driver whose only claim is CleanSlate is flagged' `
        ($null -ne (Get-LaneViolation $cliClean))

    $invoke = New-LaneFixture 'lane-invoke' @(
        '$Exe = ''D:\git\ghoztty\zig-out\bin\ghoztty.exe''',
        '$r = Invoke-OnTestDesktop -Exe $Exe -Arguments @(''--install-prepare'')'
    )
    Assert 'A17 an Invoke-OnTestDesktop launch is a launch' `
        ($null -ne (Get-LaneViolation $invoke))

    $isoLaunch = New-LaneFixture 'lane-iso' @(
        '[void](Set-GhozttyTestIsolation -Tag ''fixture'')',
        '$exe = Join-Path $Repo ''zig-out\bin\ghoztty.exe''',
        '$p = Start-Process -FilePath $exe -PassThru'
    )
    Assert 'A18 Set-GhozttyTestIsolation satisfies the launcher rule' `
        ($null -eq (Get-LaneViolation $isoLaunch))

    $sufLaunch = New-LaneFixture 'lane-suffix' @(
        '$env:GHOZTTY_PIPE_SUFFIX = "-fixture$PID"',
        '$exe = Join-Path $Repo ''zig-out\bin\ghoztty.exe''',
        '$p = Start-Process -FilePath $exe -PassThru'
    )
    Assert 'A19 a hand-rolled suffix satisfies the launcher rule' `
        ($null -eq (Get-LaneViolation $sufLaunch))

    $commented = New-LaneFixture 'lane-commented' @(
        '# $env:GHOZTTY_PIPE_SUFFIX = "-fixture$PID"',
        '$exe = Join-Path $Repo ''zig-out\bin\ghoztty.exe''',
        '$p = Start-Process -FilePath $exe -PassThru'
    )
    Assert 'A20 a commented-out suffix is not a claim' `
        ($null -ne (Get-LaneViolation $commented))

    $agentOnly = New-LaneFixture 'lane-agent' @(
        '$AgentExe = ''D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe''',
        'Start-Process -FilePath $AgentExe -PassThru | Out-Null'
    )
    Assert 'A21 an agent-only launch is not an app launch' `
        ($null -eq (Get-LaneViolation $agentOnly))

    $bareMark = New-LaneFixture 'lane-bare-mark' @(
        '# isolation: none',
        '$exe = Join-Path $Repo ''zig-out\bin\ghoztty.exe''',
        '$p = Start-Process -FilePath $exe -PassThru'
    )
    Assert 'A22 an isolation: none marker with no reason does not excuse a launcher' `
        ($null -ne (Get-LaneViolation $bareMark))

    $reasonMark = New-LaneFixture 'lane-reason-mark' @(
        '# isolation: none - the exe is a stub copy of cmd.exe, nothing binds a pipe',
        '$exe = Join-Path $stub ''ghoztty.exe''',
        '$p = Start-Process -FilePath $exe -PassThru'
    )
    Assert 'A23 an isolation: none marker WITH a reason excuses it' `
        ($null -eq (Get-LaneViolation $reasonMark))
} catch {
    # T1511: score the throw rather than unwinding past it to a green verdict.
    # Sections B/C read the real tree and do not depend on these fixtures, so
    # the honest answer is "this section failed" and the run carries on.
    Assert 'A fixtures completed' $false "(threw: $($_.Exception.Message))"
    $_.ScriptStackTrace
} finally {
    Remove-Item -Recurse -Force $fixDir -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
"== B: the real tree is clean"
# ---------------------------------------------------------------------------
$self = Split-Path -Leaf $PSCommandPath
$scripts = @(Get-ChildItem (Join-Path $Repo 'test\win32\*.ps1') -File |
    Where-Object { $_.Name -ne $self })
Assert 'B1 the sweep found a plausible number of scripts' ($scripts.Count -ge 50) `
    "(got $($scripts.Count))"

$violations = @()
foreach ($s in $scripts) {
    $why = Get-IsolationViolation $s.FullName
    if ($null -ne $why) { $violations += "$($s.Name): $why" }
}
foreach ($v in $violations) { "  VIOLATION $v" }
Assert 'B2 every script that drives the CLI claims a private endpoint' `
    ($violations.Count -eq 0) "($($violations.Count) violation(s))"

# ---------------------------------------------------------------------------
"== C: and that endpoint is unique to the RUN (T352)"
# ---------------------------------------------------------------------------
$pinned = @()
foreach ($s in $scripts) {
    $why = Get-SuffixUniquenessViolation $s.FullName
    if ($null -ne $why) { $pinned += "$($s.Name): $why" }
}
foreach ($v in $pinned) { "  VIOLATION $v" }
Assert 'C1 no script pins a fixed pipe suffix' `
    ($pinned.Count -eq 0) "($($pinned.Count) violation(s))"

$pinnedLineage = @()
foreach ($s in $scripts) {
    $why = Get-InstanceUniquenessViolation $s.FullName
    if ($null -ne $why) { $pinnedLineage += "$($s.Name): $why" }
}
foreach ($v in $pinnedLineage) { "  VIOLATION $v" }
Assert 'C2 no script pins a fixed agent lineage (T903)' `
    ($pinnedLineage.Count -eq 0) "($($pinnedLineage.Count) violation(s))"

# ---------------------------------------------------------------------------
"== D: every app launcher holds an endpoint another loop lane cannot share (T1983)"
# ---------------------------------------------------------------------------
$launchers = 0
$laneShared = @()
foreach ($s in $scripts) {
    $t = Get-Content -LiteralPath $s.FullName -Raw -ErrorAction SilentlyContinue
    if ($t -and @(Get-AppLaunchSite $t).Count -gt 0) { $launchers++ }
    $why = Get-LaneViolation $s.FullName
    if ($null -ne $why) { $laneShared += "$($s.Name): $why" }
}
foreach ($v in $laneShared) { "  VIOLATION $v" }
# A floor, not a census: the T1983 sweep counted 251 launchers. A detector that
# silently stopped recognising launches would pass D2 over an empty set.
Assert 'D1 the launch detector still finds the suite''s launchers' ($launchers -ge 150) `
    "(found $launchers)"
Assert 'D2 no launcher or CLI driver relies on the shared default debug pipe' `
    ($laneShared.Count -eq 0) "($($laneShared.Count) violation(s))"

# A clean green run stamps the covered files (T783) so scripts\guard-due.ps1
# can answer "has this scan been run against the test tree as it now stands?".
Complete-TestBody  # T1039: before the stamp, which is a child process reading this run's state
if ($script:failures -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard isolation-meta -Repo $Repo 2>&1 | ForEach-Object { "  $_" }
}

""
Write-TestVerdict -Pass $script:passes -Fail $script:failures
