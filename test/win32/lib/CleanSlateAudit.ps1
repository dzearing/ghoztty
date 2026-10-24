# CleanSlateAudit.ps1 - the analyzer behind test\win32\cleanslate-audit.ps1 (T351).
#
# THE RULE IT ENFORCES
#
# An acceptance script must not carry its own kill of the app under test or its
# sibling agent. There is exactly one, in lib\CleanSlate.ps1 - `Stop-RepoGhoztty`
# (path-exact, refuses an exe outside the repo) and the full pre-fixture reset
# `Reset-GhozttyTestState` on top of it.
#
# WHY. T248 hoisted the reset and converted 19 scripts; by T351 there were 133
# private copies again, under six different names, with four different filters
# and eight different settle times. Two divergences were live in them:
#
#   * `$_.CommandLine -like '*zig-out*'` also matches a detached instance
#     running from `zig-out-release` (T53b) and kills it. Exact-exe does not.
#   * a copy that killed only `ghoztty.exe` left the agent owning the PTY, so a
#     pane from the previous run survived and `+new-window --target=` FOCUSED it
#     instead of running this run's fixture.
#
# N copies of one datum is N chances to be wrong and no way to notice (T257).
# This analyzer is the way to notice.
#
# WHAT COUNTS AS A FINDING
#
# A `Get-CimInstance Win32_Process` query that names `ghoztty.exe` or
# `ghoztty-agent.exe` and whose pipeline reaches `Stop-Process` within the next
# few lines. Since T1260 also a `Get-Process` (or `Get-<X>Process(es)` helper)
# query naming `ghoztty`/`ghoztty-agent`, and a kill spelled `.Kill()`. Enumerations are NOT findings: plenty of scripts legitimately count
# or inspect processes, and only the KILL is the shared datum.
#
# THE EXEMPTION, AND WHY IT IS A COMMENT RATHER THAN A LIST
#
# Some kills are deliberately different - `agent-adopt.ps1` picks its fake agents
# out by a run marker, `agent-upgrade.ps1` matches `ghoztty-agent%` because the
# image name under test IS `ghoztty-agent.exe.bak`. Those are correct and must
# stay. A central allow-list of file names would go stale silently the moment one
# of them was rewritten; a marker ON the kill cannot, because it is deleted with
# the code it excuses:
#
#     # cleanslate-exempt: matches the t549 fake agents by run marker, not path
#
# within the six lines above the kill. The reason text is required - an empty
# marker is itself a finding, so "exempt" can never become a rubber stamp.

Set-StrictMode -Off

# T1260: three query spellings, not one. `Get-Process` hands back objects with a
# `.Kill()` of their own, and a helper named `Get-<Something>Process(es)` is the
# same query one call removed - `Stop-ThrowawayInstances` killed through exactly
# that and the sweep never saw it.
$script:CleanSlateAuditQuery = 'Get-CimInstance\s+Win32_Process|\bGet-Process\b|\bGet-\w+Process(es)?\b'
$script:CleanSlateAuditNames = "ghoztty\.exe|ghoztty-agent\.exe|ghoztty-agent%|ghoztty\.exe'\s+OR"
# Get-Process takes the image name WITHOUT `.exe`, so for that family alone the
# bare quoted names count too. Not for a CIM query: the chooser scripts name
# 'ghoztty' beside one only to EXCLUDE it from a kill of their own litter.
$script:CleanSlateAuditCim = 'Get-CimInstance\s+Win32_Process'
$script:CleanSlateAuditBareNames = "['""]ghoztty(-agent)?['""]"
# T1260: the kill has two spellings too. `$p.Kill()` on an object the query
# returned is the same private kill as piping it into Stop-Process.
$script:CleanSlateAuditKill = 'Stop-Process|\.Kill\(\)'
# The reason is captured, not required by the pattern: a marker with an EMPTY
# reason has to be seen to be reported, and a pattern that demanded `\S` would
# simply not match it - leaving a rubber stamp indistinguishable from no stamp.
$script:CleanSlateAuditMarker = '#\s*cleanslate-exempt\s*:?(.*)$'
# T2053: a victim filter keyed on `zig-out` anywhere in the command line.
$script:CleanSlateAuditCrossLane = "CommandLine\s+-(i)?like\s+['""]\*zig-out"

# How far a kill's pipeline may run past the query line before we stop looking.
# Six covers the widest real shape in the corpus (query, two Where-Object lines,
# ForEach-Object, Stop-Process, close brace).
$script:CleanSlateAuditWindow = 6

function Get-CleanSlateFindings {
    <#
    .SYNOPSIS
    Private ghoztty kills in one script's text.

    .DESCRIPTION
    -Text takes the script as an array of lines. Returns one object per finding:
    Line (1-based), Kind ('private-kill' or 'empty-exemption'), Text (the query
    line, trimmed).

    The result UNROLLS, deliberately: every call site wraps it in `@(...)`, and a
    `return , @(...)` under that wrap would NEST instead - an empty result would
    then count as one phantom finding and a green sweep would go red for nothing
    (PS 5.1).
    #>
    # AllowNull as well as AllowEmptyCollection (T1004): an empty file read by
    # Get-Content arrives as $null, not as @(), and the empty permission alone
    # refuses it.
    param([Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()][AllowEmptyString()][string[]]$Text)

    $findings = @()
    for ($i = 0; $i -lt $Text.Count; $i++) {
        $line = $Text[$i]
        if ($line -notmatch $script:CleanSlateAuditQuery) { continue }

        # The query and the few lines under it are one pipeline as far as this
        # rule is concerned - but never PAST the end of the statement it is in.
        # Without the boundary an enumeration that happens to be followed by a
        # kill function reads as a kill itself (`agent-relay-session-e2e.ps1`
        # has exactly that pair), and the audit reports code that is fine.
        $last = [Math]::Min($Text.Count - 1, $i + $script:CleanSlateAuditWindow)
        for ($j = $i + 1; $j -le $last; $j++) {
            if ($Text[$j] -match '^\s*function\s' -or $Text[$j] -match '^\}') { $last = $j - 1; break }
        }
        $forward = ($Text[$i..$last] -join ' ')
        if ($forward -notmatch $script:CleanSlateAuditKill) { continue }

        # The image name is not always on the query line: the commonest copy in
        # the corpus looped `foreach ($n in @('ghoztty.exe', 'ghoztty-agent.exe'))`
        # and filtered on `$n`, so the name sits a line or two ABOVE.
        $back = [Math]::Max(0, $i - 3)
        $names = $script:CleanSlateAuditNames
        if ($line -notmatch $script:CleanSlateAuditCim) { $names += '|' + $script:CleanSlateAuditBareNames }
        if (($Text[$back..$last] -join ' ') -notmatch $names) { continue }

        # T2053: a kill that picks its victims by `zig-out` in the COMMAND LINE
        # is not excusable. Every debug ghoztty on the box has that in its
        # command line - the other loop lane's app, every parallel worker's
        # mirror - so no reason text can make it this run's process. It is
        # how agent-upgrade.ps1, exempt for its LIKE, killed lane B's apps.
        if ($forward -match $script:CleanSlateAuditCrossLane) {
            $findings += [pscustomobject]@{
                Line = $i + 1
                Kind = 'cross-lane-kill'
                Text = $line.Trim()
            }
            continue
        }

        # A comment ABOVE the kill excuses it, and must say why.
        $first = [Math]::Max(0, $i - $script:CleanSlateAuditWindow)
        $exempt = $false
        $blank = $false
        foreach ($above in $Text[$first..$i]) {
            if ($above -match $script:CleanSlateAuditMarker) {
                $exempt = $true
                if (-not $matches[1].Trim()) { $blank = $true }
            }
        }
        if ($exempt -and -not $blank) { continue }

        $findings += [pscustomobject]@{
            Line = $i + 1
            Kind = if ($blank) { 'empty-exemption' } else { 'private-kill' }
            Text = $line.Trim()
        }
    }
    return $findings
}

function Get-CleanSlateAuditScripts {
    <#
    .SYNOPSIS
    Every acceptance script the rule applies to: test\win32\*.ps1 plus its lib\.

    .DESCRIPTION
    Three files are excluded, and all three are the rule ITSELF rather than code
    the rule judges: lib\CleanSlate.ps1 (the one shared kill), this analyzer, and
    the acceptance script - the last two only ever mention a kill in prose or in
    a synthesized fixture, and auditing a rule against its own statement is a
    permanent finding that teaches nothing.
    #>
    param([Parameter(Mandatory = $true)][string]$Root)

    $skip = @('CleanSlate.ps1', 'CleanSlateAudit.ps1', 'cleanslate-audit.ps1')
    $files = @(Get-ChildItem -Path $Root -Filter '*.ps1' -File -ErrorAction SilentlyContinue)
    $lib = Join-Path $Root 'lib'
    if (Test-Path $lib) {
        $files += @(Get-ChildItem -Path $lib -Filter '*.ps1' -File -ErrorAction SilentlyContinue)
    }
    return ($files | Where-Object { $skip -notcontains $_.Name } | Sort-Object FullName)
}

# ============================================================================
# The applier's install directory (T1272)
# ============================================================================
#
# THE RULE. A script that arms the real update applier (`GHOZTTY_UPDATE_APPLY =
# "<pid>|<msi>|<install exe>"`) hands it an install directory whose job, on a
# rejected package, is to RENAME `ghoztty.exe` ASIDE. Aimed at `zig-out\bin`,
# that leaves the turn with no build (2026-09-01: update-apply.ps1, T1268; then
# update-failure-visible.ps1, T1271). The third field must therefore come from a
# scratch provider - `New-ApplierSandbox` (lib\ApplierSandbox.ps1) or
# `Get-ThrowawayInstallDir` (the throwaway product install) - traced through the
# script's own assignments.
#
# Kinds:
#   repo-build-target  the trace reaches `zig-out`. No exemption excuses it.
#   untraced-target    the trace reaches neither a provider nor the repo build;
#                      excused by `# applier-target: <reason>` within the six
#                      lines above the arming line (a reasonless marker is
#                      itself a finding, as with cleanslate-exempt).
#
# A spec whose value is a bare variable with no assignment in the file (a
# function parameter, as in update-failure-visible.ps1's Start-Applier) is
# judged at its call sites: every double-quoted three-field `a|b|c` string in
# the file. A value that is the variable itself saved and restored is not an
# arming. Literals without three fields (a malformed-spec test) arm nothing.

$script:ApplierProviders = 'New-ApplierSandbox|Get-ThrowawayInstallDir'

function Get-ApplierVarAssignments {
    param([string[]]$Lines, [string]$Name)
    $pat = '(?i)^\s*(\[[^\]]+\]\s*)?\$' + [regex]::Escape($Name) + '\s*=(?!=)\s*(?<expr>.+?)\s*,?\s*$'
    $out = @()
    foreach ($l in $Lines) {
        if ($l -match '^\s*#') { continue }
        if ($l -match $pat) { $out += $Matches['expr'] }
    }
    return $out
}

function Resolve-ApplierTarget {
    <#
    .SYNOPSIS
    Classify an expression as 'sandbox', 'repo' or 'unknown' by tracing the
    variables it names through the file's assignments.
    #>
    param([string[]]$Lines, [string]$Expr, [int]$Depth = 0, [hashtable]$Seen = @{})

    if ($Expr -match $script:ApplierProviders) { return 'sandbox' }
    if ($Expr -match '(?i)zig-out') { return 'repo' }
    if ($Depth -ge 6) { return 'unknown' }

    $verdict = 'unknown'
    $vars = [regex]::Matches($Expr, '\$(?!env:)(?<n>[A-Za-z_][A-Za-z0-9_]*)')
    foreach ($m in $vars) {
        $n = $m.Groups['n'].Value
        if ($n -in @('PSScriptRoot', 'PID', 'true', 'false', 'null', '_')) { continue }
        if ($Seen.ContainsKey($n.ToLower())) { continue }
        $Seen[$n.ToLower()] = $true
        foreach ($e in @(Get-ApplierVarAssignments -Lines $Lines -Name $n)) {
            $r = Resolve-ApplierTarget -Lines $Lines -Expr $e -Depth ($Depth + 1) -Seen $Seen
            if ($r -eq 'repo') { return 'repo' }
            if ($r -eq 'sandbox') { $verdict = 'sandbox' }
        }
    }
    return $verdict
}

function Get-ApplierSpecTarget {
    # The third field of a "<pid>|<msi>|<exe>" string, or $null when it is not one.
    param([string]$Spec)
    $fields = @($Spec -split '\|')
    if ($fields.Count -ne 3) { return $null }
    return $fields[2]
}

function Get-ApplierTargetFindings {
    <#
    .SYNOPSIS
    Every place a script arms the update applier at something that is not
    provably a scratch install directory.
    #>
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Text)

    $lines = @($Text)
    $findings = @()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -match '^\s*#') { continue }
        $rhs = $null
        if ($line -match "GHOZTTY_UPDATE_APPLY['""]?\s*=(?!=)\s*(?<rhs>.+?)\s*;?\s*$") {
            $rhs = $Matches['rhs']
        } elseif ($line -match "SetEnvironmentVariable\(\s*['""]GHOZTTY_UPDATE_APPLY['""]\s*,\s*(?<rhs>.+?)\s*(,[^,]*)?\)") {
            $rhs = $Matches['rhs']
        }
        if ($null -eq $rhs) { continue }
        # `if ($x) { $env:GHOZTTY_UPDATE_APPLY = $saved }` - the brace closes the
        # statement, not the value.
        if ($rhs -notmatch '["'']$') { $rhs = $rhs -replace '\s*[;}]+\s*$', '' }

        $specs = @()
        if ($rhs -match '^"(?<s>[^"]*)"') {
            $specs += $Matches['s']
        } elseif ($rhs -match "^'(?<s>[^']*)'") {
            $specs += $Matches['s']
        } elseif ($rhs -match '^\$(?<v>[A-Za-z_][A-Za-z0-9_]*)$') {
            $assigned = @(Get-ApplierVarAssignments -Lines $lines -Name $Matches['v'])
            if ($assigned.Count -and (@($assigned | Where-Object { $_ -notmatch 'GHOZTTY_UPDATE_APPLY' }).Count -eq 0)) {
                continue    # a saved value put back, not an arming
            }
            if ($assigned.Count) {
                foreach ($a in $assigned) {
                    if ($a -match '^"(?<s>[^"]*)"') { $specs += $Matches['s'] } else { $specs += "?|?|$a" }
                }
            } else {
                # A parameter: judge the call sites.
                foreach ($m in [regex]::Matches(($lines -join "`n"), '"(?<s>[^"\n]*\|[^"\n]*\|[^"\n]*)"')) {
                    $specs += $m.Groups['s'].Value
                }
            }
        } else {
            $specs += "?|?|$rhs"
        }

        foreach ($spec in $specs) {
            $target = Get-ApplierSpecTarget -Spec $spec
            if ($null -eq $target) { continue }
            $kind = switch (Resolve-ApplierTarget -Lines $lines -Expr $target) {
                'repo' { 'repo-build-target' }
                'sandbox' { $null }
                default { 'untraced-target' }
            }
            if ($kind -eq 'untraced-target') {
                $from = [Math]::Max(0, $i - 6)
                $marker = @($lines[$from..$i] | Where-Object { $_ -match '#\s*applier-target:(?<why>.*)$' } |
                    ForEach-Object { $null = $_ -match '#\s*applier-target:(?<why>.*)$'; $Matches['why'].Trim() })
                if ($marker.Count) {
                    $kind = if ($marker[-1]) { $null } else { 'empty-exemption' }
                }
            }
            if ($kind) {
                $findings += [pscustomobject]@{ Line = $i + 1; Kind = $kind; Text = $line.Trim(); Target = $target }
            }
        }
    }
    # Not `return ,`: an empty array returned that way counts as 1 at an @() call site.
    return $findings
}
