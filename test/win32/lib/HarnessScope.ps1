# HarnessScope (T1969) - which scripts a SCOPED harness-floor sweep asks an
# audit to read.
#
# THE GAP THIS CLOSES. T1958 scoped the per-turn harness floor by MEMBER, but
# every member it kept still swept the whole suite: about 13 minutes a turn, of
# which five audits (foreground, argv-hazard, unroll-count, neuter,
# persistence-flag) were ~8. A scoped sweep only runs when nothing SHARED
# changed since the floor was last verified green (scripts\lib\HarnessFloor.ps1
# Get-HarnessFloorScope), so every unchanged top-level script still scores
# exactly what it scored then. Re-reading it buys nothing; the changed scripts
# are the whole question.
#
# THE CONTRACT. scripts\harness-floor.ps1 -Scoped sets
# $env:GHOZTTY_HARNESS_FLOOR_ONLY to the changed top-level scripts,
# repo-relative and `;`-separated, for the suite-run it starts and for nothing
# else. An audit that supports a scoped mode asks Get-HarnessScope, which also
# takes the same list as an explicit -Only (the way a test drives it). The
# answer is WHOLE - read the suite, as before - whenever reading only the list
# could miss a red:
#
#   * no list at all (every ordinary run, the daily sweep, guard-due's runs);
#   * an entry that is not a top-level test\win32\<name>.ps1 - a library or a
#     runner change reaches every script, which is why the floor makes those a
#     full sweep in the first place;
#   * the audit's OWN script is on the list - its rules changed, so its old
#     verdict on the unchanged scripts no longer stands;
#   * an entry that no longer exists - a deleted script can leave a declaration,
#     a claim or a registry row naming it, and only a whole read sees that.
#
# A scoped run proves less than a whole one, so an audit never stamps its guard
# row from one, and it says it was scoped on its last line.

Set-StrictMode -Off

$script:HarnessScopeEnv = 'GHOZTTY_HARNESS_FLOOR_ONLY'

function Get-HarnessScopeEnvName { return $script:HarnessScopeEnv }

# 'a;b', 'a,b' (how `-Only a,b` arrives through `powershell -File`), or an
# array of either -> clean repo-relative entries.
function ConvertTo-HarnessScopeList([object[]]$Value) {
    $out = New-Object System.Collections.ArrayList
    foreach ($v in @($Value)) {
        if ($null -eq $v) { continue }
        foreach ($p in ([string]$v -split '[;,]')) {
            $t = $p.Trim().Replace('/', '\')
            while ($t.StartsWith('.\')) { $t = $t.Substring(2) }
            if ($t) { [void]$out.Add($t) }
        }
    }
    # Unrolled on purpose, and wrapped at every call site: `return ,` on an
    # EMPTY array arrives at `@(...)` as one element, which is a phantom entry.
    return $out.ToArray()
}

<#
.SYNOPSIS
Should this audit read the whole suite, or only the changed scripts?

.OUTPUTS
{ Scoped (bool); Files (full paths, when scoped); Rel (repo-relative, when
scoped); Reason }
#>
function Get-HarnessScope {
    param(
        [Parameter(Mandatory)][string]$Repo,
        # The audit's own script ($PSCommandPath).
        [string]$Self,
        [string[]]$Only,
        # Read the environment when -Only is empty. Off only for the tests.
        [switch]$NoEnv
    )
    $list = @(ConvertTo-HarnessScopeList $Only)
    $from = '-Only'
    if ($list.Count -eq 0 -and -not $NoEnv) {
        $list = @(ConvertTo-HarnessScopeList ([Environment]::GetEnvironmentVariable($script:HarnessScopeEnv)))
        $from = '$env:' + $script:HarnessScopeEnv
    }
    $whole = { param($why) [pscustomobject]@{ Scoped = $false; Files = @(); Rel = @(); Reason = $why } }
    if ($list.Count -eq 0) { return (& $whole 'no scope was given') }

    $root = $Repo.TrimEnd('\')
    $selfRel = $null
    if ($Self -and $Self.ToLowerInvariant().StartsWith($root.ToLowerInvariant() + '\')) {
        $selfRel = $Self.Substring($root.Length + 1)
    }

    $files = New-Object System.Collections.ArrayList
    $rels = New-Object System.Collections.ArrayList
    foreach ($rel in $list) {
        if ($rel -notmatch '^test\\win32\\[^\\]+\.ps1$') {
            return (& $whole "$rel is not a top-level test script, and a shared file can change what any script scores")
        }
        if ($selfRel -and $rel -ieq $selfRel) {
            return (& $whole "this audit's own script changed, so its verdict on the unchanged scripts no longer stands")
        }
        $full = Join-Path $root $rel
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            return (& $whole "$rel no longer exists - only a whole read can see what still names it")
        }
        if (@($rels | Where-Object { $_ -ieq $rel }).Count -gt 0) { continue }
        [void]$rels.Add($rel)
        [void]$files.Add($full)
    }
    return [pscustomobject]@{
        Scoped = $true
        Files  = $files.ToArray()
        Rel    = $rels.ToArray()
        Reason = ("{0} changed script(s), from {1}" -f $rels.Count, $from)
    }
}

# The one line an audit prints about its scope, so a log says which kind of
# run it was before any assertion does.
function Format-HarnessScopeLine($Scope) {
    if ($Scope.Scoped) {
        return ("  SCOPED (T1969): reading only {0}: {1}" -f $Scope.Reason, (@($Scope.Rel) -join ', '))
    }
    return ("  WHOLE SUITE: {0}" -f $Scope.Reason)
}

# The suffix an audit puts on its verdict label, so the last line - the one
# go.md reads - says the run was scoped.
function Get-HarnessScopeLabel($Scope) {
    if ($Scope.Scoped) { return (" (scoped: {0} script(s))" -f @($Scope.Rel).Count) }
    return ''
}
