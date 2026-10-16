# harness-scope acceptance (T1969): a SCOPED harness-floor sweep lets its five
# heaviest audits read only the scripts the turn changed - and each of them
# still catches a violation in a changed script, leaves one in an unchanged
# script to the daily sweep, and reads the whole suite whenever the list could
# hide a red.
#
#   powershell -NoProfile -File test\win32\harness-scope.ps1
#
# Non-interactive, launches no Ghoztty and touches no user state: the subject is
# the harness. It plants small violator scripts in test\win32\ (named zz-t1969-*,
# deleted in a finally block) and runs the audits against them with -Only.
#
# isolation: none - this runs static audits over planted source files; nothing
# here launches ghoztty or runs a CLI verb (T680 meta-check reads this marker).
# persistence: launches no GUI - the audits it runs read scripts, they do not
# run them.
# foreground: does not touch the foreground window.
#
# WHY IT EXISTS. A scoped audit is a gate that reads less, and "reads less" is
# indistinguishable from "reads nothing" unless the red direction is seen. So for
# each of foreground-audit, argv-hazard-audit, unroll-count-audit and
# persistence-flag it plants one violator the -Only list names (must go red,
# naming it) and one it does not (must stay unread - the daily sweep's job), and
# then shows the same tree goes green when only a clean script is listed. For
# neuter-audit, whose subject is src\ rather than the suite, it shows a scoped
# run leaves a wounded src\ alone and a whole run over the same tree finds it.
#
#   A  lib\HarnessScope.ps1: when a list scopes a run and when it is ignored.
#   B  each audit, scoped: the changed violator is caught, the unchanged one is
#      not read, and a clean list over the same tree is green.
#   C  neuter-audit: scoped leaves src\ to the whole run; whole finds the wound.
#   D  the runner: scripts\harness-floor.ps1 -Scoped hands the list through, and
#      only for a scoped sweep.
param(
    [string]$Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\HarnessScope.ps1')
. (Join-Path $Repo 'scripts\lib\HarnessFloor.ps1')

$script:pass = 0
$script:fail = 0
function Assert([string]$name, [bool]$cond, [string]$detail = '') {
    if ($cond) { Write-Host "  PASS $name"; $script:pass++ }
    else {
        Write-Host ("  FAIL $name" + $(if ($detail) { " -- $detail" } else { '' })) -ForegroundColor Red
        $script:fail++
    }
}

$suite = Join-Path $Repo 'test\win32'
$envName = Get-HarnessScopeEnvName
$savedEnv = [Environment]::GetEnvironmentVariable($envName)
[Environment]::SetEnvironmentVariable($envName, $null)
$work = Join-Path $env:TEMP "ghoztty-t1969-$PID"
New-Item -ItemType Directory -Force -Path $work | Out-Null
$planted = New-Object System.Collections.ArrayList

# Run one audit as the floor would, capturing everything it printed. Output and
# exit code both, because a red verdict is the claim.
function Invoke-Audit([string]$Name, [string[]]$Extra) {
    $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $suite "$Name.ps1")) + @($Extra)
    # Each record stringified as it arrives, so an error record keeps its own
    # text instead of the host's formatting of it (stderr-capture-audit, T883).
    $text = (@(& powershell @argv 2>&1 | ForEach-Object { "$_" }) -join "`n")
    $code = $LASTEXITCODE
    return [pscustomobject]@{ Code = $code; Text = $text; Last = @(@($text -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -Last 1) -join '' }
}

function New-Planted([string]$Name, [string[]]$Body) {
    $p = Join-Path $suite $Name
    Set-Content -LiteralPath $p -Encoding ascii -Value (@(
            '# planted by test\win32\harness-scope.ps1 (T1969); deleted at the end of its run.'
            '# If this file is still here, that run did not clean up: delete it.'
        ) + @($Body))
    [void]$planted.Add($p)
    return "test\win32\$Name"
}

try {
    # ========================================================================
    Write-Host '== A: when a list scopes a run, and when it is ignored'
    # ========================================================================
    $self = Join-Path $suite 'foreground-audit.ps1'
    $s = Get-HarnessScope -Repo $Repo -Self $self -NoEnv
    Assert 'A1 no list reads the whole suite' (-not $s.Scoped) $s.Reason

    $s = Get-HarnessScope -Repo $Repo -Self $self -NoEnv -Only 'test\win32\ipc-p1.ps1,test/win32/pane-banner.ps1'
    Assert 'A2 a list of existing top-level scripts scopes the run (comma and slash spellings)' (
        $s.Scoped -and @($s.Rel).Count -eq 2 -and @($s.Rel) -contains 'test\win32\pane-banner.ps1') ($s.Reason + ' ' + (@($s.Rel) -join ','))
    Assert 'A2b and hands back full paths that exist' (
        @(@($s.Files) | Where-Object { Test-Path -LiteralPath $_ }).Count -eq 2)

    $s = Get-HarnessScope -Repo $Repo -Self $self -NoEnv -Only 'test\win32\ipc-p1.ps1;.\test\win32\ipc-p1.ps1'
    Assert 'A3 a script listed twice is read once' ($s.Scoped -and @($s.Rel).Count -eq 1) (@($s.Rel) -join ',')

    $s = Get-HarnessScope -Repo $Repo -Self $self -NoEnv -Only 'test\win32\ipc-p1.ps1;test\win32\lib\TestScore.ps1'
    Assert 'A4 a library on the list reads the whole suite' (-not $s.Scoped -and $s.Reason -match 'not a top-level') $s.Reason

    $s = Get-HarnessScope -Repo $Repo -Self $self -NoEnv -Only 'test\win32\ipc-p1.ps1;test\win32\foreground-audit.ps1'
    Assert "A5 the audit's own script on the list reads the whole suite" (-not $s.Scoped -and $s.Reason -match 'own script') $s.Reason

    $s = Get-HarnessScope -Repo $Repo -Self $self -NoEnv -Only 'test\win32\ipc-p1.ps1;test\win32\zz-t1969-gone.ps1'
    Assert 'A6 a deleted script on the list reads the whole suite' (-not $s.Scoped -and $s.Reason -match 'no longer exists') $s.Reason

    [Environment]::SetEnvironmentVariable($envName, 'test\win32\ipc-p1.ps1')
    $s = Get-HarnessScope -Repo $Repo -Self $self
    $sNoEnv = Get-HarnessScope -Repo $Repo -Self $self -NoEnv
    [Environment]::SetEnvironmentVariable($envName, $null)
    Assert "A7 the list arrives through `$env:$envName when no -Only is given" ($s.Scoped -and $s.Reason -match 'env') $s.Reason
    Assert 'A7b and -NoEnv ignores it' (-not $sNoEnv.Scoped) $sNoEnv.Reason

    $s = Get-HarnessScope -Repo $Repo -Self $self -NoEnv -Only 'test\win32\ipc-p1.ps1'
    Assert 'A8 a scoped run says so on its last line' ((Get-HarnessScopeLabel $s) -match 'scoped: 1 script') (Get-HarnessScopeLabel $s)
    Assert 'A8b and a whole one adds nothing' ((Get-HarnessScopeLabel $sNoEnv) -eq '')

    # ========================================================================
    Write-Host ''
    Write-Host '== B: each audit, scoped - the changed violator is caught, the unchanged one is not read'
    # ========================================================================
    # Each body is assembled from pieces so this file is not itself a violator
    # of the audits it drives.
    $cases = @(
        [pscustomobject]@{
            Audit = 'foreground-audit'
            Body  = @(('$null = [Drv]::Send' + 'Input(1, $inputs, 40)'))
        }
        [pscustomobject]@{
            Audit = 'argv-hazard-audit'
            Body  = @(
                '$exe = ''C:\x\ghoztty.exe'''
                '$resume = ''claude --continue "read go.md and go"'''
                ('& $exe ' + '+' + 'new-window --title=loop "--command=$resume"'))
        }
        [pscustomobject]@{
            Audit = 'unroll-count-audit'
            Body  = @(('$n = (Get-TestWindows -ProcessId 1)' + '.Count'))
        }
        [pscustomobject]@{
            Audit = 'persistence-flag'
            Body  = @(('Start-' + 'Process $exe'))
        }
    )
    foreach ($c in $cases) {
        $changed = New-Planted "zz-t1969-$($c.Audit)-changed.ps1" $c.Body
        $unchanged = New-Planted "zz-t1969-$($c.Audit)-unchanged.ps1" $c.Body
        $cLeaf = Split-Path -Leaf $changed
        $uLeaf = Split-Path -Leaf $unchanged

        $r = Invoke-Audit $c.Audit @('-Only', $changed)
        Assert "B $($c.Audit): scoped to the changed violator, the run is red" ($r.Code -ne 0) "exit $($r.Code): $($r.Last)"
        Assert "B $($c.Audit): and it names the changed violator" ($r.Text -match [regex]::Escape($cLeaf)) $r.Last
        Assert "B $($c.Audit): and never reads the unchanged one" ($r.Text -notmatch [regex]::Escape($uLeaf)) $r.Last
        Assert "B $($c.Audit): and its last line says it was scoped" ($r.Last -match 'scoped: 1 script') $r.Last

        # The same tree, the unchanged violator still in it: a list naming only
        # a clean script is green, because that violator is the daily sweep's.
        $r = Invoke-Audit $c.Audit @('-Only', 'test\win32\ipc-p1.ps1')
        Assert "B $($c.Audit): a clean list over the same tree is green (the unchanged violator waits for the daily sweep)" (
            $r.Code -eq 0) "exit $($r.Code): $($r.Last)"

        foreach ($p in @($planted)) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
        $planted.Clear()
    }

    # ========================================================================
    Write-Host ''
    Write-Host '== C: neuter-audit - a scoped run leaves src\ to the whole run'
    # ========================================================================
    # A wounded src\ in a scratch repo: a negative control with no shipped-value
    # pin (the `unpinned` finding). The suite's paths still resolve against this
    # repo; -Repo moves only the src\ the audit reads.
    $fake = Join-Path $work 'repo'
    New-Item -ItemType Directory -Force -Path (Join-Path $fake 'src') | Out-Null
    [IO.File]::WriteAllText((Join-Path $fake 'src\mod.zig'), ((@(
                'const std = @import("std");'
                ''
                '/// Negative control for `pane-banner.ps1`''s T999 assertions. Flipping it'
                '/// restores the pre-T999 world.'
                'const T999_NEUTERED = false;'
                ''
                'fn wrapWidth(w: i32) i32 {'
                '    return if (T999_NEUTERED) 0 else w;'
                '}'
                ''
                'pub fn paint(w: i32) i32 {'
                '    return wrapWidth(w);'
                '}'
                ''
                'test "T999 paints" {'
                '    try std.testing.expectEqual(@as(i32, 7), paint(7));'
                '}'
            ) -join "`n") + "`n"))

    $r = Invoke-Audit 'neuter-audit' @('-Repo', $fake, '-Only', 'test\win32\ipc-p1.ps1')
    Assert 'C1 neuter scoped: green over a wounded src\' ($r.Code -eq 0) "exit $($r.Code): $($r.Last)"
    Assert 'C2 neuter scoped: and it never read src\' ($r.Text -notmatch 'FOUND ') $r.Last
    Assert 'C3 neuter scoped: and says what it left to the whole run' ($r.Text -match 'SCOPED: B and C') $r.Last

    $r = Invoke-Audit 'neuter-audit' @('-Repo', $fake)
    Assert 'C4 neuter whole: the same tree is red' ($r.Code -ne 0) "exit $($r.Code): $($r.Last)"
    Assert 'C5 neuter whole: naming the unpinned control' ($r.Text -match 'FOUND \S*mod\.zig:\d+ T999_NEUTERED unpinned') $r.Last

    # ========================================================================
    Write-Host ''
    Write-Host '== D: the runner hands the list through, and only for a scoped sweep'
    # ========================================================================
    $scoped = [pscustomobject]@{ Mode = 'scoped'; Changed = @('test\win32\ipc-p1.ps1', 'scripts\vt-escape-scan.ps1', 'test\win32\pane-banner.ps1') }
    $list = @(Get-HarnessFloorOnlyList $scoped)
    Assert 'D1 a scoped sweep lists its changed top-level scripts' (
        $list.Count -eq 2 -and $list -contains 'test\win32\ipc-p1.ps1' -and $list -contains 'test\win32\pane-banner.ps1') ($list -join ',')
    Assert 'D2 and leaves an Owns file off, since only its member reads it' ($list -notcontains 'scripts\vt-escape-scan.ps1')
    Assert 'D3 a full sweep lists nothing' (
        @(Get-HarnessFloorOnlyList ([pscustomobject]@{ Mode = 'full'; Changed = @('test\win32\ipc-p1.ps1') })).Count -eq 0)
    Assert 'D4 and neither does a current one' (@(Get-HarnessFloorOnlyList ([pscustomobject]@{ Mode = 'current'; Changed = @() })).Count -eq 0)

    $runner = [IO.File]::ReadAllText((Join-Path $Repo 'scripts\harness-floor.ps1'))
    Assert "D5 the runner sets the variable the audits read ($envName)" ($runner.Contains("'$envName'"))
    Assert 'D6 and takes the list from Get-HarnessFloorOnlyList' ($runner -match 'Get-HarnessFloorOnlyList')
    Assert 'D7 and clears it again when the suite run ends' ($runner -match 'finally\s*\{\s*\[Environment\]::SetEnvironmentVariable\(\$onlyName, \$null\)')

    $members = @('foreground-audit', 'argv-hazard-audit', 'unroll-count-audit', 'neuter-audit', 'persistence-flag')
    $floorNames = @(Get-HarnessFloorAudits | ForEach-Object { [string]$_.Name })
    $notWired = @($members | Where-Object {
            -not ([IO.File]::ReadAllText((Join-Path $suite "$_.ps1")) -match 'Get-HarnessScope -Repo')
        })
    Assert 'D8 all five scoped audits ask lib\HarnessScope.ps1' ($notWired.Count -eq 0) ($notWired -join ', ')
    $notMembers = @($members | Where-Object { $floorNames -notcontains "$_.ps1" })
    Assert 'D9 and all five are harness-floor members, which is where the list comes from' ($notMembers.Count -eq 0) ($notMembers -join ', ')
} catch {
    # An unwind here must score red, not fall through to a green verdict (T1039).
    Write-Host "  FAIL the run threw: $($_.Exception.Message)" -ForegroundColor Red
    $script:fail++
} finally {
    foreach ($p in @($planted)) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
    [Environment]::SetEnvironmentVariable($envName, $savedEnv)
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

$left = @(Get-ChildItem -LiteralPath $suite -Filter 'zz-t1969-*.ps1' -File -ErrorAction SilentlyContinue)
Assert 'Z1 no planted violator is left in the suite' ($left.Count -eq 0) (@($left | ForEach-Object { $_.Name }) -join ', ')

Complete-TestBody  # T1039: the run reached the end of its body

# --- stamp (T783) ----------------------------------------------------------
# Only a clean green run records the covered files; a red one stays due.
if ($script:fail -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard harness-scope -Repo $Repo 2>&1 |
        ForEach-Object { Write-Host "  $($_.ToString())" }
}

Write-Host ''
Write-TestVerdict -Label 'T1969 HARNESS SCOPE' -Pass $script:pass -Fail $script:fail -MinPass 40
