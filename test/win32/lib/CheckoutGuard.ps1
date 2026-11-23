# CheckoutGuard.ps1 - an acceptance script grades ITS OWN checkout's build (T1996).
#
# 283 acceptance scripts spell the repo as the literal D:\git\ghoztty, mostly as
# a parameter default:
#
#     param([string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe')
#
# A second loop lane runs from its own worktree (D:\git\ghoztty-b, T1984), and
# there that default names LANE A's build. scripts\acceptance-parallel.ps1
# re-roots those parameters for every job it starts (T1993), but a script run
# BY HAND - the `run:` line guard-due prints, a suite-run sweep, a turn trying
# one fix - took the default, launched lane A's exe, and reported the result as
# lane B's verdict. A broken change in lane B could pass that way.
#
# This file is the backstop. It is dot-sourced by the two libraries nearly every
# acceptance script already loads (lib\BuildMode.ps1, directly or through
# CleanSlate/TestDesktop, and lib\TestScore.ps1), and on load it asks one
# question of the script that loaded it:
#
#     does this script sit in a checkout OTHER than the literal one, and is it
#     about to resolve a path inside the literal one?
#
# If so it throws REFUSED, naming each parameter and the re-rooted value to pass
# instead, before the script's body can start anything. It does NOT re-root the
# values itself: a script that quietly tests something other than what its
# parameters say is the defect being closed, not a fix for it.
#
# Two shapes count, the same two the runner re-roots (Get-AcceptanceScriptClass
# in scripts\lib\AcceptanceParallel.ps1):
#
#   * a PARAMETER whose current value is the literal or a path below it, however
#     it got there (the default, or passed explicitly);
#   * the `if (-not (Test-Path $exe)) { $exe = '<literal>\zig-out\...' }`
#     fallback, when this checkout has no such file - that line would fire and
#     hand the script lane A's build.
#
# In the literal checkout itself (lane A, every run before T1984) this is a
# no-op, and so is any caller outside <checkout>\test\win32 (a scripts\ tool
# that borrows a test library is not an acceptance run). A line marked
# `# @repo-literal-fixture` holds the literal as data and is skipped, exactly as
# the runner skips it.
#
# GHOZTTY_TEST_FOREIGN_CHECKOUT=1 is the deliberate hatch - "yes, grade the
# other checkout from here" - and it prints that it was used.
#
# THE AGENT HALF (T2006)
#
# Re-rooting the exe is not enough. The local agent's pipe, guard and state dir
# are keyed by build mode plus GHOZTTY_AGENT_INSTANCE, and every debug build on
# the box derives the SAME default - so a lane-B script run by hand, with its
# own exe, still dialed LANE A's debug agent and adopted (or was refused by)
# its sessions. The runner closed that for its own phases in T1994
# (`apm-<runnerPid>`); this closes it for a run the runner never saw:
#
#   * in a checkout other than the literal one, with no lineage set, the guard
#     MINTS one - `aph-<pid>` - and arms the teardown of the autostart value
#     that lineage frees the agent to write (T1168), exactly as
#     Set-GhozttyTestAgentLineage would. A script that mints its own later is
#     told "already set" and keeps this one, as it does under the runner.
#   * a script that CANNOT honor a lineage - the runner's lineage-hostile
#     patterns (`$script:ApMainPatterns` in scripts\lib\AcceptanceParallel.ps1:
#     an unscoped agent state dir or layout manifest, or dropping the lineage)
#     - is REFUSED there, as the runner refuses it, because under any lineage
#     it reads the wrong files and without one it is lane A's agent. A
#     `# @lineage-safe - <why>` declaration exempts it, as it does in the runner.
#
# The literal checkout is untouched: lane A keeps the box's default lineage
# byte for byte. GHOZTTY_TEST_FOREIGN_CHECKOUT=1 skips both halves.
#
# Acceptance: test\win32\checkout-guard.ps1.

# The repo's path as the acceptance scripts spell it. Fixed, never derived: the
# same constant as $script:ApRepoLiteral in scripts\lib\AcceptanceParallel.ps1,
# and checkout-guard.ps1 fails if the two ever differ.
$script:CgRepoLiteral = 'D:\git\ghoztty'
$script:CgFixtureMarker = '@repo-literal-fixture'

# T2006: the runner's lineage-hostile patterns, regex -> reason. The same table
# as $script:ApMainPatterns (scripts\lib\AcceptanceParallel.ps1) - this library
# is copied into fixture checkouts that have no scripts\ - and checkout-guard.ps1
# fails if the two ever differ, or if the two disagree about any real script.
$script:CgLineageHostilePatterns = [ordered]@{
    'local-agent-debug'                                                   = 'hardcodes the unscoped agent state dir'
    'session-layout-debug'                                                = 'hardcodes the unscoped layout manifest'
    'Remove-Item\s+Env:\\?GHOZTTY_AGENT_INSTANCE|\$env:GHOZTTY_AGENT_INSTANCE\s*=\s*(\$null|''''|"")' = 'drops the agent lineage'
}
# The prefix a hand-run lineage carries: `aph-<pid>`, beside the runner's
# `apm-<pid>` and `apw<n>-<pid>`. Well inside the agent's 24-char cap.
$script:CgHandLineagePrefix = 'aph'

function Test-CgUnderPath {
    # True when $Value is $Root or a path below it - not a sibling that merely
    # shares the prefix (D:\git\ghoztty-b starts with D:\git\ghoztty).
    param([string]$Value, [string]$Root)
    if (-not $Value -or -not $Root) { return $false }
    $r = $Root.TrimEnd('\')
    if (-not $Value.StartsWith($r, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    return ($Value.Length -eq $r.Length -or $Value[$r.Length] -eq '\')
}

function Get-TestCheckoutRoot {
    # The checkout this library file lives in: <root>\test\win32\lib.
    return [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..')).TrimEnd('\')
}

function Get-ForeignCheckoutFindings {
    <#
    .SYNOPSIS
    The reasons script -ScriptPath, run from -Checkout, would resolve a path in
    the -Literal checkout instead. Empty when it would not, or when -Checkout IS
    the literal one.

    .DESCRIPTION
    -Lookup maps a parameter name to its current value (the caller's variable).
    Pure apart from Test-Path on the fallback targets, so the harness can drive
    it with any literal and checkout it likes.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [Parameter(Mandatory = $true)][string]$Checkout,
        [Parameter(Mandatory = $true)][scriptblock]$Lookup,
        [string]$Literal = $script:CgRepoLiteral
    )
    $lit = $Literal.TrimEnd('\')
    $co = $Checkout.TrimEnd('\')
    if ([string]::Equals($co, $lit, [StringComparison]::OrdinalIgnoreCase)) { return @() }

    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errors)
    $lines = $ast.Extent.Text -split "`n"
    $lineBase = $ast.Extent.StartLineNumber
    $isFixture = {
        param([int]$ln)
        ([string]$lines[$ln - $lineBase]) -match "#.*$([regex]::Escape($script:CgFixtureMarker))"
    }

    $found = @()
    if ($ast.ParamBlock) {
        foreach ($p in $ast.ParamBlock.Parameters) {
            $name = $p.Name.VariablePath.UserPath
            if (& $isFixture $p.Extent.StartLineNumber) { continue }
            $v = & $Lookup $name
            if (-not ($v -is [string])) { continue }
            if (-not (Test-CgUnderPath -Value $v -Root $lit)) { continue }
            $rest = $v.Substring($lit.Length).TrimStart('\')
            $fix = if ($rest) { Join-Path $co $rest } else { $co }
            $found += "-$name is '$v', in $lit - pass -$name '$fix'"
        }
    }

    $litRx = [regex]::Escape($lit)
    $fallback = "(?i)if\s*\(\s*-not\s*\(\s*Test-Path\s+\`$\w+\s*\)\s*\)\s*\{\s*\`$\w+\s*=\s*'$litRx\\(zig-out[^']*)'\s*\}"
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $m = [regex]::Match([string]$lines[$i], $fallback)
        if (-not $m.Success) { continue }
        if (& $isFixture ($i + $lineBase)) { continue }
        $target = Join-Path $co $m.Groups[1].Value
        if (-not (Test-Path -LiteralPath $target)) {
            $found += "line $($i + $lineBase) falls back to $lit\$($m.Groups[1].Value) because this checkout has no $target - build this checkout first"
        }
    }
    return @($found | Select-Object -Unique)
}

function Get-LineageHostileReasons {
    <#
    .SYNOPSIS
    Why script -ScriptPath cannot run under its own agent lineage (T2006):
    the reasons of every lineage-hostile pattern its CODE (comments blanked)
    matches. Empty when none does, or when it declares
    `# @lineage-safe - <why>`. Pure apart from reading the file.
    #>
    param([Parameter(Mandatory = $true)][string]$ScriptPath)
    $raw = [IO.File]::ReadAllText($ScriptPath)
    if ($raw -match '(?m)^[ \t]*#[ \t]*@lineage-safe[ \t]+-[ \t]*\S') { return @() }
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errors)
    $chars = $ast.Extent.Text.ToCharArray()
    $base = $ast.Extent.StartOffset
    foreach ($t in $tokens) {
        if ($t.Kind -ne [System.Management.Automation.Language.TokenKind]::Comment) { continue }
        for ($i = $t.Extent.StartOffset - $base; $i -lt ($t.Extent.EndOffset - $base); $i++) {
            if ($chars[$i] -ne "`n" -and $chars[$i] -ne "`r") { $chars[$i] = ' ' }
        }
    }
    $code = -join $chars
    $found = @()
    foreach ($k in $script:CgLineageHostilePatterns.Keys) {
        if ($code -match "(?i)$k") { $found += $script:CgLineageHostilePatterns[$k] }
    }
    return $found
}

function Get-CheckoutLineageDecision {
    <#
    .SYNOPSIS
    What a run of -ScriptPath from -Checkout does about its agent lineage
    (T2006): 'none' (the literal checkout, or a lineage already set),
    'mint' (with the name to use) or 'refuse' (with the reasons).

    .DESCRIPTION
    -Current is the GHOZTTY_AGENT_INSTANCE the run already has. Pure apart from
    reading the script, so the harness can ask it about any checkout.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [Parameter(Mandatory = $true)][string]$Checkout,
        [string]$Current,
        [string]$Literal = $script:CgRepoLiteral,
        [int]$ProcessId = $PID
    )
    if ([string]::Equals($Checkout.TrimEnd('\'), $Literal.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{ Action = 'none'; Instance = $null; Reasons = @() }
    }
    $hostile = @(Get-LineageHostileReasons -ScriptPath $ScriptPath)
    if ($hostile.Count -gt 0) { return [pscustomobject]@{ Action = 'refuse'; Instance = $null; Reasons = $hostile } }
    if ($Current) { return [pscustomobject]@{ Action = 'none'; Instance = $Current; Reasons = @() } }
    return [pscustomobject]@{ Action = 'mint'; Instance = "$($script:CgHandLineagePrefix)-$ProcessId"; Reasons = @() }
}

function Assert-TestCheckout {
    <#
    .SYNOPSIS
    Throw REFUSED when the acceptance script that loaded this library would grade
    another checkout's build, or run against another checkout's agent. Runs by
    itself when this file is dot-sourced; returns the lineage it minted, if any.
    #>
    $libDir = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
    $caller = $null
    foreach ($f in @(Get-PSCallStack)) {
        $sn = [string]$f.ScriptName
        if (-not $sn) { continue }
        if ([string]::Equals((Split-Path -Parent $sn).TrimEnd('\'), $libDir, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $caller = $sn
        break
    }
    if (-not $caller) { return }
    $root = Get-TestCheckoutRoot
    if (-not (Test-CgUnderPath -Value ([IO.Path]::GetFullPath($caller)) -Root (Join-Path $root 'test\win32'))) { return }
    if ([string]::Equals($root, $script:CgRepoLiteral, [StringComparison]::OrdinalIgnoreCase)) { return }

    # Script scope, by name: a dynamic lookup from in here would find this
    # function's own locals first ($root shadows a caller's -Root).
    $findings = @(Get-ForeignCheckoutFindings -ScriptPath $caller -Checkout $root -Lookup {
            param($n)
            Get-Variable -Name $n -Scope Script -ValueOnly -ErrorAction SilentlyContinue
        })
    $leaf = Split-Path -Leaf $caller
    if ($env:GHOZTTY_TEST_FOREIGN_CHECKOUT -eq '1') {
        Write-Host "  [checkout-guard] GHOZTTY_TEST_FOREIGN_CHECKOUT=1: $leaf runs from $root but grades $($script:CgRepoLiteral) ($($findings.Count) path(s)) on its default agent lineage, as asked"
        return
    }
    if ($findings.Count -eq 0) {
        # T2006: the build is this checkout's; now make the AGENT this run's too.
        $d = Get-CheckoutLineageDecision -ScriptPath $caller -Checkout $root -Current $env:GHOZTTY_AGENT_INSTANCE
        if ($d.Action -eq 'mint') {
            $env:GHOZTTY_AGENT_INSTANCE = $d.Instance
            Write-Host "  [checkout-guard] $leaf runs from $root - its own agent lineage GHOZTTY_AGENT_INSTANCE=$($d.Instance) (the default one is $($script:CgRepoLiteral)'s agent, T2006)"
            return $d.Instance
        }
        if ($d.Action -ne 'refuse') { return }
        $list = ($d.Reasons | ForEach-Object { "    - $_" }) -join "`n"
        Write-Host @"
REFUSED: $leaf is in $root, but it cannot run under its own agent lineage, and the default debug lineage is $($script:CgRepoLiteral)'s agent (T2006):

$list

Scope it (Get-GhozttyAgentStateDir / Get-GhozttySessionLayoutPath / Restore-GhozttyAgentLineage in
test\win32\lib\AgentLineage.ps1), declare `# @lineage-safe - <why>` if the match is fixture text,
or run it from $($script:CgRepoLiteral). GHOZTTY_TEST_FOREIGN_CHECKOUT=1 runs it against that agent on purpose.
"@
        throw "REFUSED: $leaf would run against another checkout's agent (T2006) - see above"
    }
    # The block goes to the host and the throw stays one line: an error record
    # is re-wrapped at the console width, which breaks the paths in half.
    $list = ($findings | ForEach-Object { "    - $_" }) -join "`n"
    Write-Host @"
REFUSED: $leaf is in $root, but it would grade the build in $($script:CgRepoLiteral) - another checkout (T1996):

$list

Run it through the runner, which re-roots these for you:
    powershell -NoProfile -File scripts\acceptance-parallel.ps1 run -Scripts $leaf
or pass the values above. GHOZTTY_TEST_FOREIGN_CHECKOUT=1 grades the other checkout on purpose.
"@
    throw "REFUSED: $leaf would grade another checkout's build (T1996) - see above"
}

$script:CgMintedLineage = Assert-TestCheckout
if ($script:CgMintedLineage) {
    # The autostart value a lineage frees the agent to write is this run's to
    # remove (T1168) - armed here, at file scope, so the teardown's functions
    # land where the caller can still reach them on exit.
    . (Join-Path $PSScriptRoot 'HarnessLeak.ps1')
    [void](Register-AgentRunKeyTeardown -Instance $script:CgMintedLineage)
}
