<#
.SYNOPSIS
  Acceptance test for floor-lane.ps1's stall detector under a box that cannot
  be sampled cleanly (T848).

.DESCRIPTION
  `floor-lane.ps1` decides a lane is WEDGED by watching its process tree burn no
  CPU and write no output. The signal it read for years was "did the number
  CHANGE", and two things change that number without any work happening: a
  process leaving the tree takes its CPU with it, and a `Get-CimInstance
  Win32_Process` that comes back empty or short -- which is what a loaded box
  does -- takes out everything it missed. A sample that flapped empty and back
  therefore reset the no-progress clock every time, so a genuinely wedged lane
  looked busy until the wall-clock cap: `crash-stacks.ps1` ran the self-test
  seconds after writing two ~100 MB minidumps and got
  `FAIL selftest-wedge: wanted STALL, got TIMEOUT` on an unchanged tree.

  The fix is two rules, and this harness is the demonstration of both:
    * CPU is CUMULATIVE per pid (a high-water mark per process), so the number
      is monotonic and only work moves it -- and progress means GREATER, never
      merely different.
    * A sample that saw nothing is not a sample: it buys no progress, and the
      seconds it covers are not charged as stall time either.

  Arms 1-6 drive Get-TreeCpu, lifted out of floor-lane.ps1 by its AST so the
  code under test is the shipped code and not a copy. Arms 7-9 are the wiring.
  Arm 10 is the end-to-end proof: the self-test's wedge case still reaches
  STALL with every second sample forced empty. Arm 11 is the NEGATIVE CONTROL
  -- the pre-fix rule grafted back in, which must score TIMEOUT -- so the
  assertion above is known to be able to fail rather than assumed to be. That
  arm has no switch to turn it off: it is the only section whose absence would
  leave every other one still printing ALL PASS.

  Prints a single ALL PASS / N FAILURE(S) line, like every other script here.

  ASCII-only by design (PS 5.1 on this box mangles non-ASCII on rewrite).
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:Failures = 0
$script:Passes = 0
function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    if ($Ok) { Write-Host ("PASS  {0}" -f $Name); $script:Passes++ }
    else {
        Write-Host ("FAIL  {0}{1}" -f $Name, $(if ($Detail) { " - $Detail" } else { '' }))
        $script:Failures++
    }
}

$Floor = Join-Path $RepoRoot 'scripts\floor-lane.ps1'
$TmpCopy = Join-Path $RepoRoot 'scripts\floor-lane-t848-negctl.tmp.ps1'

# A stand-in for one row of a Win32_Process sample. Only the four properties the
# detector reads are needed, and using a plain object keeps the arm honest about
# what Get-TreeCpu is actually given.
function New-Proc {
    param([int]$ProcessId, [uint64]$User = 0, [uint64]$Kernel = 0)
    [pscustomobject]@{ ProcessId = $ProcessId; UserModeTime = $User; KernelModeTime = $Kernel; Name = "p$ProcessId" }
}

try {
    # ---- arms 1-6: the CPU accounting itself -------------------------------

    # Lift Get-TreeCpu out of the shipped script rather than re-typing it: the
    # file is a script with a param block and top-level work, so it cannot be
    # dot-sourced, and a copy of the function here would be free to disagree
    # with the one that runs.
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Floor, [ref]$tokens, [ref]$errors)
    Check 'floor-lane.ps1 parses' ($errors.Count -eq 0) "$($errors.Count) parse error(s)"
    $fnAst = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $n.Name -eq 'Get-TreeCpu' }, $true) | Select-Object -First 1
    Check 'Get-TreeCpu is still there to test' ($null -ne $fnAst)
    if ($null -eq $fnAst) { throw 'Get-TreeCpu not found in scripts\floor-lane.ps1' }
    Invoke-Expression $fnAst.Extent.Text

    # 100ns units, as Win32_Process reports them.
    $state = @{}
    $t1 = @((New-Proc -ProcessId 101 -User 1000 -Kernel 500), (New-Proc -ProcessId 102 -User 200))
    $a = Get-TreeCpu -Tree $t1 -IgnorePids @() -State $state
    Check 'the first sample is the sum of the tree' ($a -eq 1700) "got $a"

    # The tree sampled again with the same numbers is not progress.
    $b = Get-TreeCpu -Tree $t1 -IgnorePids @() -State $state
    Check 'an unchanged tree does not move the number' ($b -eq $a) "got $b, was $a"

    # THE DEFECT, arm 1 of 2: a process that leaves the tree used to take its
    # CPU out of the total, which the old `-ne` rule read as progress.
    $t2 = @((New-Proc -ProcessId 101 -User 1000 -Kernel 500))
    $c = Get-TreeCpu -Tree $t2 -IgnorePids @() -State $state
    Check 'a process leaving the tree does not lower the number' ($c -eq 1700) "got $c"

    # THE DEFECT, arm 2 of 2: an empty sample -- the shape a loaded box returns.
    $d = Get-TreeCpu -Tree @() -IgnorePids @() -State $state
    Check 'an empty sample does not lower the number' ($d -eq 1700) "got $d"

    # Real work still registers, or the detector would be blind in the other
    # direction: this is what stops the fix from being "stop asking".
    $t3 = @((New-Proc -ProcessId 101 -User 9000 -Kernel 500), (New-Proc -ProcessId 103 -User 42))
    $e = Get-TreeCpu -Tree $t3 -IgnorePids @() -State $state
    Check 'real CPU still raises the number' ($e -gt 1700) "got $e, was 1700"

    # An ignored pid (T933's self-spawned test binary) stays ignored even in a
    # sample that did not name it, so its CPU cannot re-enter the signal.
    $state2 = @{}
    $null = Get-TreeCpu -Tree @((New-Proc -ProcessId 201 -User 100), (New-Proc -ProcessId 202 -User 5000)) `
        -IgnorePids @(202) -State $state2
    $f = Get-TreeCpu -Tree @((New-Proc -ProcessId 201 -User 100)) -IgnorePids @() -State $state2
    Check 'a self-spawned pid stays out of the total for good' ($f -eq 100) "got $f"

    # ---- arms 7-9: the wiring in floor-lane.ps1 ----------------------------

    $src = Get-Content -LiteralPath $Floor -Raw

    Check 'the watchdog keeps a cumulative CPU state' `
        ($src -match 'Get-TreeCpu -Tree \$tree -IgnorePids \$selfSpawned -State \$cpuState') ''
    Check 'progress means GREATER, not different' `
        ($src -match '\$cpu -gt \$lastCpu -or \$logLen -gt \$lastLogLen') ''
    Check 'an empty sample is neither progress nor stall time' `
        (($src -match '\$blind = \(\$tree\.Count -eq 0\)') -and ($src -match '\$blindSeconds \+=')) ''
    Check 'a wedge is never declared off a blind iteration' `
        ($src -match '-not \$blind -and \$stalledFor -ge \$StallSeconds') ''
    # The wall-clock cap is the other half: a box that can never be sampled must
    # still not hold a lane open forever.
    $capAt = $src.IndexOf("if (`$elapsed -ge `$TimeoutSeconds)")
    $stallAt = $src.IndexOf("-not `$blind -and `$stalledFor -ge `$StallSeconds")
    Check 'the wall-clock cap is still reached on a blind iteration' `
        ($capAt -gt 0 -and $stallAt -gt $capAt) "cap=$capAt stall=$stallAt"

    # ---- arm 10: the end-to-end proof --------------------------------------

    # Every second sample forced empty. Pre-fix, this is the crash-stacks flake
    # made deterministic; post-fix the wedge must still be named a wedge.
    $env:GHOZTTY_FLOOR_LANE_BLIND_EVERY = '2'
    try {
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $Floor -SelfTest 2>&1 |
            ForEach-Object { $_.ToString() } | Out-String
    }
    finally { Remove-Item Env:\GHOZTTY_FLOOR_LANE_BLIND_EVERY -ErrorAction SilentlyContinue }
    Check 'the self-test still names the wedge with half its samples blind' `
        ($out -match 'PASS selftest-wedge: STALL') $out
    Check 'and it says out loud that it could not sample' `
        ($out -match 'LANE BLIND SAMPLE') $out
    Check 'the whole self-test is green under that load' ($out -match 'ALL PASS') $out

    # ---- arm 11: the negative control --------------------------------------

    # Always run, and deliberately not switchable off: a skip here would be the
    # one section whose absence nobody would notice, since every other arm still
    # says ALL PASS without it. It costs the two minutes the pre-fix wall-clock
    # cap takes to expire.
    # The pre-fix progress rule, grafted back into a copy of the shipped
    # script: any change is progress, and an empty sample is a change. If
    # this does NOT go red, arm 10 is not measuring anything.
    $neg = $src
    $neg = $neg.Replace(
        'if ($cpu -gt $lastCpu -or $logLen -gt $lastLogLen) {',
        'if ($cpu -ne $lastCpu -or $logLen -ne $lastLogLen) {')
    $neg = $neg.Replace(
        '$cpu = Get-TreeCpu -Tree $tree -IgnorePids $selfSpawned -State $cpuState',
        '$cpu = Get-TreeCpu -Tree $tree -IgnorePids $selfSpawned')
    $neg = $neg.Replace('$blind = ($tree.Count -eq 0)', '$blind = $false')
    Check 'the negative control really is the pre-fix rule' `
        (($neg -ne $src) -and ($neg -match '\$cpu -ne \$lastCpu') -and ($neg -match '\$blind = \$false')) ''
    Set-Content -LiteralPath $TmpCopy -Value $neg -Encoding ascii

    $env:GHOZTTY_FLOOR_LANE_BLIND_EVERY = '2'
    try {
        $negOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $TmpCopy -SelfTest 2>&1 |
            ForEach-Object { $_.ToString() } | Out-String
    }
    finally { Remove-Item Env:\GHOZTTY_FLOOR_LANE_BLIND_EVERY -ErrorAction SilentlyContinue }
    Check 'the pre-fix rule fails the same assertion (teeth)' `
        ($negOut -match 'FAIL selftest-wedge: wanted STALL, got TIMEOUT') $negOut

    Complete-TestBody  # T1039: the run reached the end of its body
}
finally {
    Remove-Item -LiteralPath $TmpCopy -Force -ErrorAction SilentlyContinue
    Get-Process -Name 'waitfor' -ErrorAction SilentlyContinue |
        Where-Object { $_.StartTime -gt (Get-Date).AddMinutes(-20) } |
        ForEach-Object { try { Stop-Process -Id $_.Id -Force -ErrorAction Stop } catch {} }
}

if ($script:Failures -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot 'scripts\guard-due.ps1') `
        update -Guard lane-stall-sampling -Repo $RepoRoot 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:Passes -Fail $script:Failures
