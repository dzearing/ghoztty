# T784 acceptance: the agent's build stamp follows everything the agent is
# built from.
#
# The defect, measured on 2026-08-12 while wiring T281's agent read-back: a
# zig-out holding ghoztty.exe at +9672383fb and ghoztty-agent.exe stamped
# 20260811-3bbf0eefb from the SAME build run. The stamp came from the last
# commit touching four hand-listed leaves (`src/agent_main.zig`, `src/remote`,
# `src/pty.zig`, `src/CommandCore.zig`), and the agent is compiled from far more
# than that - `src/os`, `src/terminal`, `src/apprt/win32/job_spawn.zig` and what
# those reach. A commit to any of them changed the agent's BYTES and left its
# identity alone, so `isStale(running, bundled)` read two different builds as the
# same one: the app's upgrade policy stood down, and T281's delivery freshness
# gate compared two copies of the same wrong answer and passed.
#
# The fix is a path list taken from what the COMPILER reads (every `zig build
# agent` writes a manifest of its inputs) plus this harness, which is what keeps
# the list honest as imports move.
#
# Sections:
#
#   A  the scanner itself bites - synthetic manifests, both directions
#   B  the live tree: every compiled input is covered by the stamp path list
#   C  the three trees the defect was about are really in the agent's inputs,
#      and really covered now
#   D  the recipe and the scanner agree, and the widened list reached the BINARY:
#      the built agent's stamp is the git answer for that same path set
#   E  exclusions are declared with a reason - never a silent hole in the list
#
# Static + one cached build; no app, no CLI, no windows.
#
#   powershell -NoProfile -File test\win32\agent-stamp-inputs.ps1
#   powershell -NoProfile -File test\win32\agent-stamp-inputs.ps1 -NegativeControl
#
# isolation: none - this script never runs a ghoztty verb; it reads the repo,
# builds the agent into zig-out, and runs the scanner over fixtures under temp\.
param(
    [string]$Repo,
    [switch]$NegativeControl
)

$ErrorActionPreference = 'Stop'
if (-not $Repo) { $Repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }

# T1511: the shared scorer, and the dot-source is also what ARMS the run.
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:failures = 0
$script:passes = 0
function Assert($name, $cond, $detail = '') {
    if ($cond) { "  PASS $name"; $script:passes++ }
    else { "  FAIL $name $detail"; $script:failures++ }
}

$Scanner = Join-Path $Repo 'scripts\agent-stamp-inputs.ps1'
$Recipe = Join-Path $Repo 'src\build\GhosttyAgent.zig'

# The scanner is a separate process on purpose: what is under test is the exit
# code and the report a caller sees, not a function this script could hold
# differently.
function Invoke-Scan([hashtable]$Opts) {
    $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Scanner, '-Repo', $Repo)
    foreach ($k in $Opts.Keys) {
        $v = $Opts[$k]
        if ($v -is [switch] -or $v -is [bool]) { if ($v) { $argv += "-$k" } ; continue }
        # One argument, ';'-joined: powershell -File passes each argv element
        # through as a literal string, so a multi-value array would bind its
        # second element positionally to the next parameter instead.
        $argv += "-$k"
        $argv += ((@($v)) -join ';')
    }
    $out = & powershell @argv 2>&1 | ForEach-Object { $_.ToString() } | Out-String
    return [pscustomobject]@{ Code = $LASTEXITCODE; Text = $out }
}

# A manifest line is `<size> <inode> <mtime> <hash> <prefix> <path>`, after a
# one-line header. Only the path column matters to the scanner, so the fixtures
# carry plausible filler in the rest.
function Write-Manifest([string]$Path, [string[]]$Files) {
    $lines = @('0')
    foreach ($f in $Files) {
        $lines += "100 1 2 0123456789abcdef0123456789abcdef 0 $($f -replace '/', '\')"
    }
    Set-Content -LiteralPath $Path -Value $lines -Encoding ASCII
}

$fixtureDir = Join-Path $Repo 'temp\agent-stamp-inputs-fixtures'
Remove-Item -Recurse -Force -LiteralPath $fixtureDir -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $fixtureDir | Out-Null

try {
    # -----------------------------------------------------------------------
    "A. the scanner bites on synthetic manifests"
    # -----------------------------------------------------------------------

    # Real repo files, because the scanner keeps only manifest entries that
    # resolve to a file in the tree (that is how it drops zig-lib and package
    # cache entries without hard-coding zig's prefix numbering).
    $covered = Join-Path $fixtureDir 'covered.txt'
    Write-Manifest $covered @('src/pty.zig', 'src/remote/agent/main.zig')
    $a1 = Invoke-Scan @{ Manifest = $covered; StampPaths = @('src') }
    Assert 'A1 a manifest inside the stamp paths scores clean' ($a1.Code -eq 0) $a1.Text
    Assert 'A1b and says so' ($a1.Text -match 'OK: all 2 compiled input') $a1.Text

    $uncovered = Join-Path $fixtureDir 'uncovered.txt'
    Write-Manifest $uncovered @('src/pty.zig', 'build.zig')
    $a2 = Invoke-Scan @{ Manifest = $uncovered; StampPaths = @('src') }
    Assert 'A2 an input outside the stamp paths is a finding' ($a2.Code -eq 1) $a2.Text
    Assert 'A2b and the finding NAMES the file' ($a2.Text -match 'build\.zig') $a2.Text

    # The exclusion list is the only other way a file may be uncovered, and it
    # must work - otherwise the honest answer for macos/ would be to widen the
    # stamp and re-stamp the agent for Swift edits it never compiles.
    $excl = Join-Path $fixtureDir 'excluded.txt'
    Write-Manifest $excl @('src/pty.zig', 'macos/Sources/Features/Remote/LocalAgentManager.swift')
    $a3 = Invoke-Scan @{ Manifest = $excl; StampPaths = @('src') }
    Assert 'A3 a declared exclusion is not a finding' ($a3.Code -eq 0) $a3.Text

    # A scanner that cannot find its inputs must say so rather than score green
    # over an empty set - the ASSERTED NOTHING shape, in a scanner.
    $empty = Join-Path $fixtureDir 'empty.txt'
    Set-Content -LiteralPath $empty -Value @('0') -Encoding ASCII
    $a4 = Invoke-Scan @{ Manifest = $empty; StampPaths = @('src') }
    Assert 'A4 a manifest naming no repo file is an ERROR, not a pass' ($a4.Code -eq 2) $a4.Text

    # -----------------------------------------------------------------------
    ""
    "B. the live tree - every compiled input is covered"
    # -----------------------------------------------------------------------

    # -Build so the manifest describes the tree as it stands rather than
    # whatever the last build here happened to be. Cached: seconds when nothing
    # moved, and the build is the thing that produces the evidence.
    $b = Invoke-Scan @{ Build = $true; Format = 'json' }
    $report = $null
    try { $report = $b.Text | ConvertFrom-Json } catch { }
    Assert 'B1 the scanner produced a report' ($null -ne $report) $b.Text
    Assert 'B2 the live tree has no uncovered compiled inputs' ($b.Code -eq 0) `
        ("uncovered: " + (@($report.uncovered) -join ', '))
    Assert 'B3 the manifest is a real agent build (hundreds of inputs)' `
        ($null -ne $report -and @($report.inputs).Count -gt 200) `
        ("inputs: " + (@($report.inputs).Count))

    # -----------------------------------------------------------------------
    ""
    "C. the trees the defect was about"
    # -----------------------------------------------------------------------

    # Each of these is reached from src/remote/agent by relative import, so each
    # one changes the agent's bytes. If a future refactor drops one of them the
    # assertion turns advisory-false here rather than silently narrowing what
    # this harness proves.
    foreach ($f in @('src/os/main.zig', 'src/terminal/main.zig', 'src/apprt/win32/job_spawn.zig')) {
        $present = ($null -ne $report) -and (@($report.inputs) -contains $f)
        Assert "C1 $f is a compiled input of the agent" $present
        if ($present) {
            Assert "C2 $f is covered by a stamp path" (-not (@($report.uncovered) -contains $f))
        }
    }

    # -----------------------------------------------------------------------
    ""
    "D. the recipe, the scanner and the BINARY agree"
    # -----------------------------------------------------------------------

    $recipeText = Get-Content -LiteralPath $Recipe -Raw
    Assert 'D1 versionString() still derives the stamp from a git log path list' `
        ($recipeText -match '--pretty=format:%cs-%h') $Recipe

    $paths = @($report.stampPaths)
    Assert 'D2 the scanner read the path list out of the recipe' ($paths.Count -ge 1) `
        ("paths: " + ($paths -join ', '))
    foreach ($p in $paths) {
        Assert "D3 the recipe names '$p'" ($recipeText -match ('"' + [regex]::Escape($p) + '"'))
    }

    # The stamp the BINARY carries must be the git answer for that same path
    # set. This is what makes the widening real rather than a comment: it fails
    # if the recipe's argv and the list this harness checked ever come apart.
    Push-Location $Repo
    try {
        $gitArgs = @('log', '-1', '--pretty=format:%cs-%h', '--') + $paths
        $expectRaw = (& git @gitArgs | Select-Object -Last 1)
    } finally { Pop-Location }
    $expect = ''
    if ($expectRaw -match '^(\d{4})-(\d{2})-(\d{2})-(.+)$') {
        $expect = "$($matches[1])$($matches[2])$($matches[3])-$($matches[4])"
    }
    Assert 'D4 git answers a stamp for the recipe path set' ($expect -ne '') "raw: $expectRaw"

    $agentExe = Join-Path $Repo 'zig-out\bin\ghoztty-agent.exe'
    if (Test-Path -LiteralPath $agentExe) {
        # The agent logs a debug line to stderr on startup, and PowerShell 5.1
        # turns a native command's stderr into ErrorRecords - which under
        # $ErrorActionPreference='Stop' throws before the version line can be
        # read. Drop to 'Continue' for the one call rather than lose the output.
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $verOut = & $agentExe --version 2>&1 | ForEach-Object { $_.ToString() } | Out-String
        } finally { $ErrorActionPreference = $prevEap }
        $actual = ''
        foreach ($line in ($verOut -split "`n")) {
            if ($line -match 'ghoztty-agent\s+(\S+)') { $actual = $matches[1]; break }
        }
        Assert 'D5 the built agent carries a stamp' ($actual -ne '') $verOut
        Assert 'D6 the built agent stamp IS the git answer for the recipe path set' `
            ($actual -eq $expect) "built=$actual expected=$expect"
    } else {
        Assert 'D5 the built agent exists (section B built it)' $false $agentExe
    }

    # -----------------------------------------------------------------------
    ""
    "E. exclusions are declared, with a reason"
    # -----------------------------------------------------------------------

    $ex = @($report.exclusions)
    Assert 'E1 every exclusion carries a reason' `
        (($ex | Where-Object { -not $_.why -or $_.why.Trim() -eq '' }).Count -eq 0) `
        (($ex | ForEach-Object { $_.path }) -join ', ')
    Assert 'E2 no exclusion shadows a stamp path' `
        (($ex | Where-Object { $paths -contains $_.path }).Count -eq 0) `
        (($ex | ForEach-Object { $_.path }) -join ', ')

    # -----------------------------------------------------------------------
    # Negative control: the check must be able to go RED against the LIVE tree,
    # not only against section A's fixtures. Run the live manifest against the
    # OLD four-leaf path list - the exact list that shipped the defect - and
    # assert, INVERTED, that it still scores clean. A working scanner fails that
    # assertion, so a healthy repo scores exactly 1 FAILURE here; a scanner
    # whose enumeration quietly stopped reaching the tree would pass it.
    # -----------------------------------------------------------------------
    if ($NegativeControl) {
        ""
        "NEGATIVE CONTROL: asserting the pre-T784 path list still covers the agent - a working scan MUST fail this"
        $n = Invoke-Scan @{
            StampPaths = 'src/agent_main.zig;src/remote;src/pty.zig;src/CommandCore.zig;src/build/GhosttyAgent.zig'
        }
        Assert 'N1 the old four-leaf list covers every compiled input (inverted)' ($n.Code -eq 0) `
            "(exit $($n.Code), and 1 is the healthy answer)"
    }
}
catch {
    # T1511: score the throw rather than unwinding past it to a green verdict.
    Assert 'the run finished its sections' $false "(threw: $($_.Exception.Message))"
    $_.ScriptStackTrace
}
finally {
    Remove-Item -Recurse -Force -LiteralPath $fixtureDir -ErrorAction SilentlyContinue
}

# A clean green run stamps the covered files (T783) so scripts\guard-due.ps1 can
# answer "has this been run against the code as it now stands?".
Complete-TestBody  # T1039: before the stamp, which is a child process reading this run's state
if ($script:failures -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard agent-stamp-inputs -Repo $Repo 2>&1 | ForEach-Object { "  $_" }
}

""
Write-TestVerdict -Pass $script:passes -Fail $script:failures
