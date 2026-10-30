<#
TreeIdle.ps1 - "has this script's whole process tree gone quiet?" for the
acceptance runners (suite-run.ps1, AcceptanceParallel.ps1).

A wall-clock cap alone cannot tell a hang from a slow script: a hung script
holds its slot for the whole cap (15 minutes in the harness floor), and a slow
one that does real work - test-reach-audit.ps1 compiling two test lanes - is
killed at the same cap and scored the same `stall` (2026-10-29: the user
watched both lanes sit for an hour behind exactly that). The idle check is the
signal floor-lane.ps1 already trusts for zig lanes: no CPU anywhere in the tree
AND no new log output for -IdleSeconds means wedged, and the script is killed
then instead of at the cap. A tree that is burning CPU or writing output is
never idle, however long it runs.

The tree walk and the CPU sum are NOT re-typed here. They are lifted out of
floor-lane.ps1 by its AST, the same way floor-lane-stall-sampling.ps1 tests
them, so the pid-reuse guard (T1840) and the monotonic per-pid CPU (T848) have
one copy that cannot drift.

A script that legitimately waits without CPU or output (a soak that sleeps on
purpose) declares its own window, or opts out with 0:
    # suite-idle-sec: 1200
#>

$script:TreeIdleDefaultSeconds = 300
$script:TreeIdleSampleSeconds = 15

& {
    $floor = Join-Path $PSScriptRoot '..\floor-lane.ps1'
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($floor, [ref]$tokens, [ref]$errors)
    foreach ($name in 'Get-ProcessTree', 'Get-TreeCpu') {
        $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $n.Name -eq $name }, $true) | Select-Object -First 1
        if ($null -eq $fn) { throw "TreeIdle.ps1: $name not found in scripts\floor-lane.ps1" }
        # Defined at script scope so the dot-sourcing caller sees it.
        $null = New-Item -Path "function:script:$name" -Value $fn.Body.GetScriptBlock() -Force
    }
}

function Get-ScriptIdleSeconds {
    <#
    The idle window a script declares with `# suite-idle-sec: <N>` (0 = never
    killed for being idle), else $Default. Read from a comment line only.
    #>
    param([string]$Text, [int]$Default = $script:TreeIdleDefaultSeconds)
    $m = [regex]::Match([string]$Text, '(?m)^\s*#\s*suite-idle-sec:\s*(\d+)\s*$')
    if ($m.Success) { return [int]$m.Groups[1].Value }
    return $Default
}

function New-TreeIdleWatch {
    param([int]$RootPid, [string[]]$LogPaths = @(), [int]$IdleSeconds = $script:TreeIdleDefaultSeconds)
    $now = Get-Date
    return [pscustomobject]@{
        RootPid = $RootPid; LogPaths = @($LogPaths); IdleSeconds = $IdleSeconds
        State = @{}; LastCpu = [uint64]0; LastLen = [int64]0
        LastProgress = $now; LastSample = [datetime]::MinValue; Blind = 0.0
        IdleFor = 0; Killed = $false
    }
}

function Test-TreeIdle {
    <#
    Sample the tree (at most every $TreeIdleSampleSeconds) and return $true when
    it has shown no CPU and no new output for the watch's IdleSeconds. A sample
    that sees nothing (CIM came back empty on a loaded box) is BLIND: it never
    counts toward idle, as in floor-lane.ps1 ("I looked and saw nothing" is not
    a reading this sample made).
    #>
    param($Watch)
    if ($Watch.IdleSeconds -le 0) { return $false }
    $now = Get-Date
    if (($now - $Watch.LastSample).TotalSeconds -lt $script:TreeIdleSampleSeconds) {
        return ($Watch.IdleFor -ge $Watch.IdleSeconds)
    }
    $gap = $(if ($Watch.LastSample -eq [datetime]::MinValue) { 0 } else { ($now - $Watch.LastSample).TotalSeconds })
    $Watch.LastSample = $now

    $snapshot = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    $tree = @()
    if ($snapshot.Count -gt 0) { $tree = @(Get-ProcessTree -RootPid $Watch.RootPid -Snapshot $snapshot) }
    if ($tree.Count -eq 0) {
        $Watch.Blind += $gap
        return $false
    }
    $cpu = [uint64](Get-TreeCpu -Tree $tree -State $Watch.State)
    $len = [int64]0
    foreach ($l in $Watch.LogPaths) {
        if ($l -and (Test-Path -LiteralPath $l)) { $len += (Get-Item -LiteralPath $l).Length }
    }
    # GREATER, not different (T848): both numbers only grow.
    if ($cpu -gt $Watch.LastCpu -or $len -gt $Watch.LastLen) {
        $Watch.LastCpu = $cpu; $Watch.LastLen = $len
        $Watch.LastProgress = $now; $Watch.Blind = 0.0
    }
    $Watch.IdleFor = [int](($now - $Watch.LastProgress).TotalSeconds - $Watch.Blind)
    if ($Watch.IdleFor -lt 0) { $Watch.IdleFor = 0 }
    return ($Watch.IdleFor -ge $Watch.IdleSeconds)
}

function Get-TreeIdleLine {
    param($Watch)
    return "IDLE-KILLED: no CPU and no output anywhere in its process tree for $($Watch.IdleFor)s (a hang, not a slow script; window $($Watch.IdleSeconds)s, declare '# suite-idle-sec: N' to change it)"
}
