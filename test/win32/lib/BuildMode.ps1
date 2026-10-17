# BuildMode.ps1 - T350. Refuse, BEFORE anything is launched or typed, to run an
# acceptance script against a build whose endpoints are the user's.
#
# Dot-source it (CleanSlate.ps1 and Isolation.ps1 already do):
#
#     . (Join-Path $PSScriptRoot 'BuildMode.ps1')
#     Assert-GhozttyIsolatedBuild -Exe $Exe
#
# WHY THIS EXISTS
#
# `-Exe zig-out\bin\ghoztty.exe` chooses which CLI BINARY runs. It does not
# choose which APP that CLI reaches, nor which AGENT: both are named endpoints
# derived from the BUILD MODE, and a mode that is not "debug" derives exactly
# the endpoints the user's installed Ghoztty already owns.
#
#   is_debug (Debug, ReleaseSafe)  ->  \\.\pipe\ghoztty-debug-<user>
#                                      \\.\pipe\ghoztty-agent-debug-<user>
#                                      %LOCALAPPDATA%\ghoztty\...-debug\...
#   otherwise (ReleaseFast, ReleaseSmall)
#                                  ->  \\.\pipe\ghoztty-<user>
#                                      \\.\pipe\ghoztty-agent-<user>
#                                      the user's own state files
#
# So a `zig build -Dapp-runtime=win32` run WITHOUT `-Doptimize=Debug` leaves a
# release build in zig-out, and from that moment the whole suite drives the
# user's terminal: `+new-window` opens windows in it, the path-filtered kills
# match nothing (different ExecutablePath), and every assertion measures a
# binary nobody here built. Nothing reports an error; the scripts pass.
# Observed for real on 2026-08-02 (T248): `zig-out\bin\ghoztty.exe +list --json`
# answered `"exe":"...\Programs\Ghoztty\ghoztty.exe"`, and the user's running
# terminal was holding leaked `ipc-p1.ps1` fixture windows.
#
# WHY BUILD MODE, AND NOT "IS A PRIVATE PIPE SUFFIX SET"
#
# `GHOZTTY_PIPE_SUFFIX` (T441 / Isolation.ps1) moves the APP endpoint and
# nothing else. Isolating a release-lineage run takes THREE knobs, because the
# agent half and the file half are named separately:
#
#   GHOZTTY_PIPE_SUFFIX     the app's IPC pipe
#   GHOZTTY_AGENT_INSTANCE  the agent's guard mutex, heartbeat, pipe, state dir
#                           and autostart Run value (T167; honored in RELEASE
#                           builds too, unlike the staleness/proto test hooks)
#   LOCALAPPDATA            every file either of them writes
#
# One or two of the three is the dangerous state, not a partial win: a release
# build under a private pipe suffix alone still dials the agent that owns the
# user's live sessions, which is what this gate exists to stop. Build mode is the
# one thing a cold-box check can read off the exe itself, so it stays the gate;
# a script that really does set all three says so with -Allow and proves it with
# its own assertions (test\win32\agent-instance-lineage.ps1 -Release is the
# pattern - it measures the user's agent and Run values before and after).
#
# WHAT CATCHES WHAT
#
#   Assert-GhozttyIsolatedBuild  (this file)  - the exe we are ABOUT to launch;
#                                               works on a cold box, where
#                                               nothing answers yet.
#   Assert-GhozttyFreshBuild     (BuildFresh) - that same exe is older than the
#                                               sources it would measure, so a
#                                               green run would stamp a guard
#                                               about code it never saw (T1028).
#                                               Called from the assert below, so
#                                               every caller gets it for free.
#   Assert-GhozttyUnderTest      (CleanSlate) - the app ALREADY answering is a
#                                               different install.
#   Assert-GhozttyPrivateEndpoint / -Isolated (Isolation) - the suffix took, and
#                                               we are not in the caller's app.
#
# The first is the only one that can speak before the first `+new-window`, which
# is the moment a leaked fixture becomes visible in the user's terminal.

Set-StrictMode -Off

# T1028: the freshness half of the same pre-flight. Dot-sourced HERE rather than
# added to 49 scripts one by one, so the two questions about the exe about to be
# launched - are these the user's endpoints, are these the code under test - are
# asked together by everything that already asks the first.
. (Join-Path $PSScriptRoot 'BuildFresh.ps1')

# T675: suppress the app's startup job self-escape for everything this script
# process launches. A script run from a Ghoztty pane hands every app it starts
# real pane lineage (GHOZTTY_PANE_ID) inside a real kill-on-close job chain, so
# the app would - correctly, in the field - respawn itself outside the job and
# EXIT, handing its work to a twin with a different pid. Every harness that
# tracks the pid it launched (dialog ownership, jail assignment, Stop-Process
# cleanup) would silently lose its subject. Harness launches are pid-tracked by
# definition, so the seam rides the one file every acceptance script already
# dot-sources. Deliberately inherited by nested launches; a script whose SUBJECT
# is the startup escape re-enables it for its own launcher
# (test\win32\job-escape-startup.ps1).
$env:GHOZTTY_NO_STARTUP_ESCAPE = '1'

# T1996: refuse a script run from one checkout that would grade another's
# build (lane B taking lane A's `D:\git\ghoztty` default). Rides this file for
# the same reason the seam above does: every acceptance script loads it.
. (Join-Path $PSScriptRoot 'CheckoutGuard.ps1')

# One `+version` per exe per process: three libraries may ask, and the answer
# cannot change while a run is in flight.
if (-not (Get-Variable -Name GhozttyBuildModeCache -Scope Script -ErrorAction SilentlyContinue)) {
    Set-Variable -Name GhozttyBuildModeCache -Scope Script -Value @{}
}

function Test-GhozttyIsolatedBuildMode {
    <#
    .SYNOPSIS
    Pure predicate: does this build mode derive the `-debug` endpoints?

    .DESCRIPTION
    Mirrors `build_config.is_debug` (src\build_config.zig), which is what both
    `ipc_client.endpointPath` and `LocalAgent.pipeName` switch on. Debug and
    ReleaseSafe are isolated; ReleaseFast and ReleaseSmall share the user's.
    An unrecognized mode is treated as NOT isolated - the safe direction is to
    refuse a run we cannot vouch for.
    #>
    param([string]$Mode)
    if (-not $Mode) { return $false }
    $m = $Mode.TrimStart('.').Trim()
    return ($m -eq 'Debug' -or $m -eq 'ReleaseSafe')
}

function Get-GhozttyBuildMode {
    <#
    .SYNOPSIS
    The build mode baked into $Exe, read from its own `+version` output.

    .DESCRIPTION
    Local and offline: `+version` prints `- build mode    : .Debug` from
    `builtin.mode` without needing a running server, which is what makes this
    usable on a cold box. (`+list --json`'s `build.mode` reports the RUNNING
    app instead, and on a cold box there is none.)

    Returns the mode as printed, minus zig's leading dot; $null when the exe is
    missing or prints no such line. The `Running Instance` section also carries
    a `- mode` line, so the match is anchored on `build mode`.
    #>
    param([Parameter(Mandatory = $true)][string]$Exe)

    if ($script:GhozttyBuildModeCache.ContainsKey($Exe)) {
        return $script:GhozttyBuildModeCache[$Exe]
    }

    $mode = $null
    try {
        # Piped capture, never `> file` from PowerShell: that writes 0 bytes for
        # a native ghoztty command (T245). Never `Select-Object -First` either -
        # it tears down the still-running child and reports a false failure.
        $raw = (& $Exe +version 2>&1 | ForEach-Object { $_.ToString() } | Out-String)
        if ($raw -match '(?m)^\s*-\s*build mode\s*:\s*\.?(\w+)') {
            $mode = $matches[1]
        }
    } catch {
        $mode = $null
    }

    $script:GhozttyBuildModeCache[$Exe] = $mode
    return $mode
}

function Get-GhozttyReleaseSandboxGaps {
    <#
    .SYNOPSIS
    Which of the three isolating knobs a release-lineage run is still missing.

    .DESCRIPTION
    T1158. The header above says it: "One or two of the three is the dangerous
    state, not a partial win." This is that sentence made checkable, so the
    `-Allow` opt-in can VERIFY the claim instead of taking the caller's word.

    Returns an array of human-readable gaps - empty means all three knobs are
    set, which is the only state in which a release-lineage build may open a
    window here.

      GHOZTTY_PIPE_SUFFIX     the app's IPC pipe
      GHOZTTY_AGENT_INSTANCE  the agent's guard mutex, pipe and state dir (T167;
                              honored in RELEASE builds too)
      LOCALAPPDATA            every file either of them writes; compared against
                              the KNOWN FOLDER rather than another env read,
                              since `[Environment]::GetFolderPath` is immune to
                              the very override we are trying to detect.
    #>
    $gaps = @()
    if ([string]::IsNullOrWhiteSpace($env:GHOZTTY_PIPE_SUFFIX)) {
        $gaps += 'GHOZTTY_PIPE_SUFFIX is unset - the app''s IPC pipe is the user''s'
    }
    if ([string]::IsNullOrWhiteSpace($env:GHOZTTY_AGENT_INSTANCE)) {
        $gaps += 'GHOZTTY_AGENT_INSTANCE is unset - sessions this run opens land in the agent that owns the user''s live panes, PINNED, where nothing reaps them'
    }
    $realLad = $null
    try { $realLad = [Environment]::GetFolderPath('LocalApplicationData') } catch { $realLad = $null }
    if ($realLad -and $env:LOCALAPPDATA -and
        ($env:LOCALAPPDATA.TrimEnd([char]92) -eq $realLad.TrimEnd([char]92))) {
        $gaps += "LOCALAPPDATA is still the user's ($realLad) - state files, layout blobs and the session roster are shared"
    }
    return @($gaps)
}

function Assert-GhozttyIsolatedBuild {
    <#
    .SYNOPSIS
    Throw unless $Exe's endpoints are the debug ones - i.e. not the user's.

    .DESCRIPTION
    Call this before the app under test is launched. Returns the build mode on
    success.

    -Allow (or GHOZTTY_TEST_ALLOW_RELEASE=1) is the opt-in for a script whose
    SUBJECT is a release build - an upgrade or delivery test, or a release-
    lineage acceptance run under the three isolating knobs above. It is
    deliberately an explicit act: there is no env var that makes a release run
    safe, only one that says "I know, and this script is about that build".

    T1158: the opt-in is CHECKED, not trusted. A release-lineage run must hold
    all three isolating knobs (Get-GhozttyReleaseSandboxGaps names the ones it
    is missing) - or say, with -UserEndpoints -Reason '<why>', that reaching the
    user's real endpoints IS the point and it opens no panes. `-Allow` on its
    own used to return unconditionally, and that unchecked return is what let
    `soak.ps1` seed the user's agent with pinned sessions nothing could reap.

    A mode this file cannot read at all (an exe that does not run, or one too
    old to print the line) is refused for the same reason an unknown mode is:
    a run we cannot vouch for is exactly the run that leaks into the user's
    terminal.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [switch]$Allow,
        [switch]$UserEndpoints,
        [string]$Reason
    )

    if ($Allow -or $env:GHOZTTY_TEST_ALLOW_RELEASE -eq '1') {
        $mode = Get-GhozttyBuildMode -Exe $Exe
        # A debug-lineage exe under -Allow needs nothing further: its endpoints
        # are already not the user's, which is the whole question here.
        if (Test-GhozttyIsolatedBuildMode -Mode $mode) { return $mode }

        # T1158: the opt-in used to return right here, and that unchecked return
        # is what shipped the window storm. `soak.ps1` set GHOZTTY_PIPE_SUFFIX,
        # passed -AllowReleaseBuild, and its panes opened sessions in the agent
        # that owns the user's live terminal. A pinned session survives the
        # window close its teardown does - that IS the persistence feature - so
        # every run left its shells behind, alive and unreapable, and the pile
        # grew until the 5am refresh restarted the user's terminal into it.
        #
        # So -Allow now VERIFIES rather than trusts. The header's sentence -
        # "one or two of the three is the dangerous state, not a partial win" -
        # is the rule, and this is where it is enforced.
        if ($UserEndpoints) {
            if ([string]::IsNullOrWhiteSpace($Reason)) {
                throw 'Assert-GhozttyIsolatedBuild: -UserEndpoints requires -Reason "<why this script must reach the user''s endpoints>". An unexplained opt-out is the state T1158 was.'
            }
            Write-Host "  [build-mode] release lineage on the USER'S endpoints, declared: $Reason"
            return $mode
        }

        $gaps = Get-GhozttyReleaseSandboxGaps
        if (@($gaps).Count -eq 0) { return $mode }

        $list = ($gaps | ForEach-Object { "    - $_" }) -join "`n"
        throw @"
Assert-GhozttyIsolatedBuild: REFUSING TO RUN. The exe under test
    $Exe
is a '$mode' build and -Allow says that is deliberate - but the run is only
PARTLY isolated, which is the dangerous state, not a partial win:

$list

Isolating a release-lineage run takes all THREE knobs. The one-liner is:

    . (Join-Path `$PSScriptRoot 'lib\Isolation.ps1')
    Set-GhozttyTestIsolation -Tag '<script>' -ReleaseSandbox

If this script's SUBJECT really is the user's installed build - an upgrade or
delivery test that must dial the real endpoints and opens no panes - say so:

    Assert-GhozttyIsolatedBuild -Exe `$Exe -Allow -UserEndpoints -Reason '<why>'

T1158: soak.ps1 held exactly one of the three for weeks. Each run left its
shells in the user's agent as pinned sessions nothing can reap, and the 5am
refresh restarted the user's terminal into the accumulated pile.
"@
    }

    $mode = Get-GhozttyBuildMode -Exe $Exe
    if (Test-GhozttyIsolatedBuildMode -Mode $mode) {
        # T1028: the mode says these bytes are ours to drive; freshness says
        # they are the bytes under test. Only the repo's own zig-out build is in
        # scope, so a stub or an installed exe passes straight through.
        Assert-GhozttyFreshBuild -Exe $Exe
        return $mode
    }

    $shown = if ($mode) { $mode } else { '<could not read `+version`>' }
    throw @"
Assert-GhozttyIsolatedBuild: REFUSING TO RUN. The exe under test
    $Exe
is a '$shown' build, so it does NOT use the -debug endpoints. Its IPC pipe, its
local agent's pipe and its state files are the ones the user's INSTALLED Ghoztty
owns, and this script would open windows in the user's terminal, type into it,
and then report a pass about a binary nobody here built.

A private GHOZTTY_PIPE_SUFFIX does not fix this on its own: it moves the app's
pipe and nothing else. The agent half needs GHOZTTY_AGENT_INSTANCE (T167,
honored in release builds too) and the file half needs LOCALAPPDATA - all three
or none, see Get-GhozttyReleaseSandboxGaps.

Rebuild zig-out the way CLAUDE.md says, and re-run:
    zig build -Dapp-runtime=win32 -Doptimize=Debug

If this script's SUBJECT really is a release build (an upgrade or delivery
test), say so explicitly: pass -Allow to this assert, or set
GHOZTTY_TEST_ALLOW_RELEASE=1 for the run. Since T1158 that opt-in is CHECKED,
not taken on trust - a release-lineage run that opens panes must hold all three
isolating knobs, or declare -UserEndpoints -Reason '<why>'.
"@
}

# ---------------------------------------------------------------------------
# T1036: the same question about ghoztty-agent.exe.
#
# The agent cannot answer `+version` (it prints a `YYYYMMDD-<hash>` build STAMP
# on `--version`, and every reader of that line in the field takes its last
# token), so since T1036 it has its own `--build-mode`:
#
#     ghoztty-agent
#       - build mode    : .Debug
#       - endpoints     : debug
#
# The ENDPOINTS line is what this gate reads, not the mode. The agent's family
# follows `agent_build_options.is_debug`, which is `-Doptimize=Debug` ONLY - so a
# ReleaseSafe agent derives the user's pipe, guard mutex and state dir even
# though Test-GhozttyIsolatedBuildMode would call the mode isolated. Measuring
# the binary is the point of the flag; re-deriving the answer from the mode
# would re-introduce exactly the guess the flag exists to replace.
#
# An agent too old to know the flag answers "unknown argument" and prints no
# endpoints line, which is refused like any other run this gate cannot vouch
# for. In practice that is a zig-out older than T1036: rebuild it.
# ---------------------------------------------------------------------------

if (-not (Get-Variable -Name GhozttyAgentEndpointsCache -Scope Script -ErrorAction SilentlyContinue)) {
    Set-Variable -Name GhozttyAgentEndpointsCache -Scope Script -Value @{}
}

function Get-GhozttyAgentEndpoints {
    <#
    .SYNOPSIS
    The endpoint family ('debug' or 'release') $Exe says it derives, read from
    its own `--build-mode` output; $null when it prints no such line.
    #>
    param([Parameter(Mandatory = $true)][string]$Exe)

    if ($script:GhozttyAgentEndpointsCache.ContainsKey($Exe)) {
        return $script:GhozttyAgentEndpointsCache[$Exe]
    }
    $family = $null
    try {
        # Piped capture for the same reasons as Get-GhozttyBuildMode. A debug
        # build also writes a `debug(os_power)` line to stderr; the match is
        # anchored on the endpoints line, so it never matters.
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $raw = (& $Exe --build-mode 2>&1 | ForEach-Object { $_.ToString() } | Out-String)
        } finally { $ErrorActionPreference = $prevEap }
        if ($raw -match '(?m)^\s*-\s*endpoints\s*:\s*(debug|release)\b') {
            $family = $matches[1]
        }
    } catch {
        $family = $null
    }
    $script:GhozttyAgentEndpointsCache[$Exe] = $family
    return $family
}

function Assert-GhozttyIsolatedAgent {
    <#
    .SYNOPSIS
    Throw unless the ghoztty-agent.exe at $Exe derives the debug endpoints - or,
    under -Allow, unless the run has moved the agent's endpoints itself.

    .DESCRIPTION
    Call this before a script launches the agent directly. (A script that only
    launches the APP is covered by Assert-GhozttyIsolatedBuild: the app's agent
    autostart is the app's own business.) Returns the endpoint family.

    -Allow (or GHOZTTY_TEST_ALLOW_RELEASE=1) is for a script whose subject IS a
    release agent. It is checked, not trusted, the T1158 way: a release agent is
    only isolated by GHOZTTY_AGENT_INSTANCE (T167; honored in release builds),
    which moves its guard mutex, heartbeat, pipe, state dir and Run value. The
    app's pipe suffix says nothing about the agent, so it is not asked for.
    -UserEndpoints -Reason '<why>' is the declared opt-out, as for the app.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [switch]$Allow,
        [switch]$UserEndpoints,
        [string]$Reason
    )

    $family = Get-GhozttyAgentEndpoints -Exe $Exe
    if ($family -eq 'debug') { return $family }

    if ($Allow -or $env:GHOZTTY_TEST_ALLOW_RELEASE -eq '1') {
        if ($UserEndpoints) {
            if ([string]::IsNullOrWhiteSpace($Reason)) {
                throw 'Assert-GhozttyIsolatedAgent: -UserEndpoints requires -Reason "<why this script must reach the user''s agent>".'
            }
            Write-Host "  [build-mode] release agent on the USER'S endpoints, declared: $Reason"
            return $family
        }
        if ($family -eq 'release' -and -not [string]::IsNullOrWhiteSpace($env:GHOZTTY_AGENT_INSTANCE)) {
            return $family
        }
    }

    $shown = if ($family) { "'$family' endpoints" } else { 'no readable endpoints (`--build-mode` printed none - an agent older than T1036, or one that does not run)' }
    throw @"
Assert-GhozttyIsolatedAgent: REFUSING TO RUN. The agent under test
    $Exe
reports $shown, so it is NOT known to use the -debug endpoints. A release
agent's pipe, guard mutex and state dir are the ones that hold the user's live
sessions: launching it here would either fight the user's agent for the guard
or open test sessions inside it, pinned, where nothing reaps them.

Note the agent is NOT the app: it derives the debug endpoints only from
-Doptimize=Debug, so a ReleaseSafe zig-out is refused here even though the app
half of the same build would pass Assert-GhozttyIsolatedBuild.

Rebuild zig-out the way CLAUDE.md says, and re-run:
    zig build -Dapp-runtime=win32 -Doptimize=Debug

If this script's SUBJECT really is a release agent, isolate it with
GHOZTTY_AGENT_INSTANCE and pass -Allow (checked, not trusted), or declare
-Allow -UserEndpoints -Reason '<why>'.
"@
}
