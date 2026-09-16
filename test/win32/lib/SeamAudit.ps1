# SeamAudit (T796) - every env seam an acceptance script sets is also a
# statement that the UNSET case is untested.
#
# THE DEFECT (T747, shipped for months):
#
#     Every GUI section of `test\win32\relay-account.ps1` set
#     GHOSTTY_GOOGLE_CLIENT_ID=cid-e2e, because a fake relay needs a fake id.
#     The seam is legitimate. What nobody noticed is what it implied: the
#     configuration EVERY REAL USER runs - no id at all - was never once
#     launched, so a button that could not work read as a fully tested feature.
#
# The shape generalises. A seam that makes a flow reachable also makes its
# absence invisible, and the absent case is usually the one that ships.
#
# THE RULE:
#
#     For every env var that an acceptance script SETS and the product READS,
#     somebody has written down what happens when it is unset, and - where the
#     unset state is one only a real user meets - which arm exercises it.
#
# That judgment cannot be read off the source: `GHOZTTY_PIPE_SUFFIX` unset is
# the user's live endpoints, which the harness is FORBIDDEN to touch, while
# `GHOSTTY_GOOGLE_CLIENT_ID` unset is a dialog the user sees every day. So the
# analyzer enumerates the seams mechanically and the registry
# (`seam-audit.registry.json`) carries the classification, one entry per seam.
# What is enforced is that the enumeration and the registry agree, that an arm
# claimed actually exists, and that the number of known gaps only falls.
#
# CLASSES (`class`) - what the seam DOES, for the reader:
#
#   isolation    redirects a real resource (endpoint, store, path, binary) at a
#                test-owned one
#   tuning       turns a timer, cap or buffer size down so a test can finish
#   fault        injects a failure that cannot otherwise happen
#   non-default  selects a non-default variant, or turns a default-ON behavior
#                off
#   enable       turns ON a capability that is ABSENT by default
#
# UNSET DISPOSITION (`unset`) - what the rule is actually about:
#
#   shipped-elsewhere  the unset state is what every OTHER run already uses -
#                      the seam is the exception, not the rule. No arm owed.
#   armed              the unset state is reached only if somebody aims at it,
#                      and `unsetArm` names the arm that does.
#   gap                nothing exercises it and `gap` names the open task.
#   unreachable        cannot be exercised on this box by design (the user's
#                      live endpoints, a real network service); `note` says why.
#
# `unsetArm` is `<script>::<marker>`: the script must exist and the marker must
# occur in it, so an arm that is renamed away fails the audit instead of
# silently becoming a sentence about nothing.
#
# SCOPE, stated rather than implied: ENV seams only - the half with one
# spelling to enumerate. A seeded store, a planted HKCU value or a staged
# config file makes exactly the same statement about its absent case and is not
# covered here; T1621 carries that if a defect of that shape ever appears.

$script:SeamClasses = @('isolation', 'tuning', 'fault', 'non-default', 'enable')
$script:SeamUnsetValues = @('shipped-elsewhere', 'armed', 'gap', 'unreachable')

function Get-SeamClasses { return $script:SeamClasses }
function Get-SeamUnsetValues { return $script:SeamUnsetValues }

# Every GHOSTTY_/GHOZTTY_ env var ASSIGNED by a script under test\win32.
# Assignment only: a script that merely reads one is not making a statement
# about the unset case.
function Get-SeamEnvSets {
    param([Parameter(Mandatory)][string]$Root)

    $dir = Join-Path $Root 'test\win32'
    $map = @{}
    if (-not (Test-Path $dir)) { return $map }

    $files = @(Get-ChildItem -Path $dir -Filter *.ps1 -Recurse -File -ErrorAction SilentlyContinue)
    foreach ($f in $files) {
        $text = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $text) { continue }
        $rel = $f.FullName.Substring($Root.Length).TrimStart('\', '/')
        foreach ($m in [regex]::Matches($text, '\$env:(GHOSTTY|GHOZTTY)_[A-Z0-9_]+\s*=')) {
            $name = $m.Value -replace '^\$env:', '' -replace '\s*=$', ''
            if (-not $map.ContainsKey($name)) { $map[$name] = New-Object System.Collections.ArrayList }
            if (-not $map[$name].Contains($rel)) { [void]$map[$name].Add($rel) }
        }
    }
    return $map
}

# Every GHOSTTY_/GHOZTTY_ env var named as a string literal in the product
# sources. A var a test sets and the product never reads cannot mask a shipped
# default - it is harness plumbing and out of scope.
function Get-SeamProductReads {
    param([Parameter(Mandatory)][string]$Root)

    $dir = Join-Path $Root 'src'
    $names = @{}
    if (-not (Test-Path $dir)) { return $names }

    $files = @(Get-ChildItem -Path $dir -Filter *.zig -Recurse -File -ErrorAction SilentlyContinue)
    foreach ($f in $files) {
        $text = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $text) { continue }
        foreach ($m in [regex]::Matches($text, '"(GHOSTTY|GHOZTTY)_[A-Z0-9_]+"')) {
            $names[$m.Value.Trim('"')] = $true
        }
    }
    return $names
}

# The seams: set by the harness AND read by the product.
function Get-SeamInventory {
    param([Parameter(Mandatory)][string]$Root)

    $sets = Get-SeamEnvSets -Root $Root
    $reads = Get-SeamProductReads -Root $Root

    $out = New-Object System.Collections.ArrayList
    foreach ($name in ($sets.Keys | Sort-Object)) {
        if (-not $reads.ContainsKey($name)) { continue }
        [void]$out.Add([pscustomobject]@{
            Name    = $name
            Scripts = @($sets[$name])
        })
    }
    if ($out.Count -eq 0) { return @() }
    return , $out.ToArray()
}

function Get-SeamRegistry {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path $Path)) { return $null }
    $raw = Get-Content -LiteralPath $Path -Raw
    return ($raw | ConvertFrom-Json)
}

# Findings, by kind:
#   unregistered   a seam the sweep found with no registry entry
#   stale          a registry entry naming a seam the sweep no longer finds
#   bad-class      class outside the closed set
#   bad-unset      unset disposition outside the closed set
#   missing-arm    unset=armed with no unsetArm, or unset=gap with no gap id
#   arm-broken     unsetArm names a file that does not exist, or a marker that
#                  does not occur in it
#   gap-closed     unset=gap naming a task that is closed (fix the entry, or
#                  the task was closed without the arm it promised)
function Test-SeamRegistry {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)]$Inventory,
        [Parameter(Mandatory)]$Registry
    )

    $findings = New-Object System.Collections.ArrayList
    $seams = $null
    if ($Registry -and $Registry.PSObject.Properties.Name -contains 'seams') { $seams = $Registry.seams }

    $registered = @{}
    if ($seams) {
        foreach ($p in $seams.PSObject.Properties) { $registered[$p.Name] = $p.Value }
    }

    $found = @{}
    foreach ($seam in @($Inventory)) {
        $found[$seam.Name] = $true
        $entry = $registered[$seam.Name]
        if (-not $entry) {
            [void]$findings.Add([pscustomobject]@{ Kind = 'unregistered'; Seam = $seam.Name; Detail = "set by $(@($seam.Scripts).Count) script(s)" })
            continue
        }

        $class = $entry.class
        if ($script:SeamClasses -notcontains $class) {
            [void]$findings.Add([pscustomobject]@{ Kind = 'bad-class'; Seam = $seam.Name; Detail = "class='$class'" })
        }

        $unset = $entry.unset
        if ($script:SeamUnsetValues -notcontains $unset) {
            [void]$findings.Add([pscustomobject]@{ Kind = 'bad-unset'; Seam = $seam.Name; Detail = "unset='$unset'" })
            continue
        }

        if ($unset -eq 'armed') {
            $arm = $entry.unsetArm
            if (-not $arm) {
                [void]$findings.Add([pscustomobject]@{ Kind = 'missing-arm'; Seam = $seam.Name; Detail = 'unset=armed with no unsetArm' })
            }
            else {
                $parts = $arm -split '::', 2
                $armPath = Join-Path $Root $parts[0]
                if (-not (Test-Path $armPath)) {
                    [void]$findings.Add([pscustomobject]@{ Kind = 'arm-broken'; Seam = $seam.Name; Detail = "no such script: $($parts[0])" })
                }
                elseif ($parts.Count -lt 2 -or -not $parts[1]) {
                    [void]$findings.Add([pscustomobject]@{ Kind = 'missing-arm'; Seam = $seam.Name; Detail = "unsetArm names no marker: $arm" })
                }
                else {
                    # .Contains, not -like: a marker with a `[`, `*` or `?` in
                    # it is ordinary test prose, not a wildcard, and -like would
                    # quietly answer about a pattern nobody wrote.
                    $armText = Get-Content -LiteralPath $armPath -Raw
                    if (-not $armText.Contains($parts[1])) {
                        [void]$findings.Add([pscustomobject]@{ Kind = 'arm-broken'; Seam = $seam.Name; Detail = "marker not in $($parts[0]): $($parts[1])" })
                    }
                }
            }
        }
        elseif ($unset -eq 'gap') {
            $gap = $entry.gap
            if (-not $gap) {
                [void]$findings.Add([pscustomobject]@{ Kind = 'missing-arm'; Seam = $seam.Name; Detail = 'unset=gap with no task id' })
            }
            else {
                $taskFile = Join-Path $Root "docs\design\windows-parity-tasks\$gap.md"
                if (-not (Test-Path $taskFile)) {
                    [void]$findings.Add([pscustomobject]@{ Kind = 'missing-arm'; Seam = $seam.Name; Detail = "gap names no such task: $gap" })
                }
                else {
                    $t = Get-Content -LiteralPath $taskFile -Raw
                    if ($t -match '(?m)^status:\s*"?(?<s>[a-z\-]+)') {
                        $st = $Matches['s']
                        if ($st -ne 'todo' -and $st -ne 'in-progress') {
                            [void]$findings.Add([pscustomobject]@{ Kind = 'gap-closed'; Seam = $seam.Name; Detail = "$gap is $st" })
                        }
                    }
                }
            }
        }
    }

    foreach ($name in ($registered.Keys | Sort-Object)) {
        if (-not $found.ContainsKey($name)) {
            [void]$findings.Add([pscustomobject]@{ Kind = 'stale'; Seam = $name; Detail = 'no script sets it, or the product no longer reads it' })
        }
    }

    # `return , @()` hands an `@()` call site ONE null element, which reads as a
    # phantom finding - the same PS 5.1 trap T794 is about, in the other
    # direction. An empty result is spelled empty.
    if ($findings.Count -eq 0) { return @() }
    return , $findings.ToArray()
}

function Get-SeamGapCount {
    param([Parameter(Mandatory)]$Registry)

    $n = 0
    if ($Registry -and ($Registry.PSObject.Properties.Name -contains 'seams')) {
        foreach ($p in $Registry.seams.PSObject.Properties) {
            if ($p.Value.unset -eq 'gap') { $n++ }
        }
    }
    return $n
}
