# @timing-sensitive - it asserts that four fake lanes really overlap in wall time, so a loaded box (other workers, the other loop lane) reads as peak=3 (T1069 turn); it runs with nothing beside it (scripts/acceptance-parallel.ps1, T1960).
<#
.SYNOPSIS
  Acceptance test for the parallel floor (T1959): `floor-lane.ps1 -Lane all`
  runs its lanes side by side, each in its own build root, and still gives the
  verdict a serial run would.

.DESCRIPTION
  The four floor lanes used to run one after another, 16-19 minutes a turn.
  T1959 runs each lane as an `-Isolated` child of the script, with its own
  `--cache-dir` / `--prefix` under `<repo>\zig-lanes\<lane>`, so the set takes
  the time of its slowest lane. What this harness holds, and why each is the
  thing that would break:

    * Each parallel lane builds into its OWN root, and the serial floor is
      unchanged. Shared roots are not a slowdown, they are a defect: a lane's
      leak sweep reaps every test binary under its build root (T1648), so two
      lanes sharing `.zig-cache` would kill each other's running tests.
    * A red lane still fails the set, and a wedged lane is still STALL - with
      STALL outranking FAIL in the exit code exactly as it does serially. A
      parallel runner that reported the first child back, or the last, would
      turn the floor into a coin flip.
    * The lanes really overlap. A "parallel" floor that waits on each child in
      turn would pass every verdict check here and save nothing.
    * The same planted lanes score the same per-lane words parallel and serial.
    * The commit budget throttles: with no room for a second lane the set runs
      one lane at a time instead of refusing or over-committing (T453).
    * A concurrent lane's crash record is not this lane's (lib\CrashDiag.ps1),
      and the cache sweeper sees the per-lane caches (lib\BuildCache.ps1).

  The lanes here are PLANTED commands (GHOZTTY_FLOOR_LANE_FAKE: ping for a
  slow green lane, `exit /b 1` for a red one, a `waitfor` that is never
  signalled for a wedge), so the whole run costs a couple of minutes instead of
  a floor's worth of compiling. The real lanes are compared parallel against
  serial in T1959's own validation.

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

$floor = Join-Path $RepoRoot 'scripts\floor-lane.ps1'

function Invoke-Floor {
    # One floor run over planted lanes. Returns the exit code and every line.
    param([hashtable]$Fake, [string[]]$Extra = @())
    $env:GHOZTTY_FLOOR_LANE_FAKE = ($Fake | ConvertTo-Json -Compress)
    try {
        $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $floor, '-Lane', 'all',
            '-StallSeconds', '15', '-NoCatch', '-NoSoloConfirm') + $Extra
        $out = @(& powershell @a 2>&1 | ForEach-Object { $_.ToString() })
        $code = $LASTEXITCODE
    }
    finally { Remove-Item Env:GHOZTTY_FLOOR_LANE_FAKE -ErrorAction SilentlyContinue }
    return [pscustomobject]@{ Code = $code; Lines = $out; Text = ($out -join "`n") }
}

function Get-Verdicts {
    # lane -> verdict word, from the FLOOR SUMMARY line.
    param([string[]]$Lines)
    $v = @{}
    $sum = @($Lines | Where-Object { $_ -like 'FLOOR SUMMARY:*' }) | Select-Object -Last 1
    if ($sum) { foreach ($m in [regex]::Matches($sum, '(\w+)#\d+=(\w+)')) { $v[$m.Groups[1].Value] = $m.Groups[2].Value } }
    return $v
}

$slow = 'ping -n 11 127.0.0.1 >nul'
$red = 'ping -n 4 127.0.0.1 >nul & exit /b 1'
$wedge = 'waitfor /t 600 GhozttyFloorParallelHarnessNever'

# ---- arms 1-3: build roots ---------------------------------------------------

$dry = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $floor -Lane all -DryRun 2>&1 |
        ForEach-Object { $_.ToString() } | Where-Object { $_ -like 'DRY-RUN *' })
$roots = @()
foreach ($l in 'lib', 'none', 'win32', 'agent') {
    $line = @($dry | Where-Object { $_ -like "DRY-RUN ${l}:*" }) | Select-Object -First 1
    $want = [regex]::Escape("zig-lanes\$l\.zig-cache")
    $wantP = [regex]::Escape("zig-lanes\$l\zig-out")
    Check "the parallel $l lane builds into its own cache and prefix" `
        ($line -match "--cache-dir `"[^`"]*$want`"" -and $line -match "--prefix `"[^`"]*$wantP`"") "$line"
    if ($line -match '--cache-dir "([^"]+)"') { $roots += $Matches[1] }
}
Check 'no two lanes share a build root' (@($roots | Select-Object -Unique).Count -eq 4) ($roots -join ' | ')

$drySerial = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $floor -Lane all -DryRun -Serial 2>&1 |
        ForEach-Object { $_.ToString() } | Where-Object { $_ -like 'DRY-RUN *' })
Check '-Serial runs the floor exactly as before: four lanes, no --cache-dir or --prefix' `
    ($drySerial.Count -eq 4 -and @($drySerial | Where-Object { $_ -match '--cache-dir|--prefix' }).Count -eq 0) `
    ($drySerial -join ' | ')

# ---- arms 4-8: a planted red and a planted wedge -----------------------------

$mixed = @{ lib = $slow; none = $red; win32 = $wedge; agent = $slow }
$r = Invoke-Floor -Fake $mixed
$v = Get-Verdicts -Lines $r.Lines
Check 'a wedged lane outranks a red one: the set exits 2 (STALL)' ($r.Code -eq 2) "exit=$($r.Code)"
Check 'the summary scores each lane: lib PASS, none FAIL, win32 STALL, agent PASS' `
    ($v['lib'] -eq 'PASS' -and $v['none'] -eq 'FAIL' -and $v['win32'] -eq 'STALL' -and $v['agent'] -eq 'PASS') `
    (($v.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' ')
Check 'the last line is FLOOR NOT GREEN' ($r.Lines.Count -gt 0 -and $r.Lines[-1] -eq 'FLOOR NOT GREEN') `
    "$(if ($r.Lines.Count) { $r.Lines[-1] })"
Check 'ONE failure detail block names both the red lane and the wedged one' `
    (@($r.Lines | Where-Object { $_ -like '-- FLOOR FAILURE DETAIL*' }).Count -eq 1 -and
    $r.Text -match '(?m)^  lane none: FAIL' -and $r.Text -match '(?m)^  lane win32: STALL') ''

Check 'a lane red side by side is re-run alone, stays red, and the token says both' `
    ($r.Text -match 'none#1=FAIL[^\n]*\[side by side: FAIL\]' -and $r.Text -match 'win32#1=STALL[^\n]*\[side by side: STALL\]' -and
    $r.Text -match 'alone re-runs: none, win32') ''
Check 'a genuine red is not reported as contention' ($r.Text -notmatch 'FLOOR PARALLEL CONTENTION') ''

# Four lanes of ~10s each: a floor that waited on each child in turn takes 40s.
# The side-by-side phase alone is measured: the alone re-runs are serial on
# purpose and are not what this arm is about.
$par = [regex]::Match($r.Text, 'FLOOR PARALLEL: wall (\d+)s for (\d+)s of lanes, up to (\d+) at once \(side by side (\d+)s')
$sum = if ($par.Success) { [int]$par.Groups[2].Value } else { -1 }
$peak = if ($par.Success) { [int]$par.Groups[3].Value } else { -1 }
$side = if ($par.Success) { [int]$par.Groups[4].Value } else { -1 }
Check 'the lanes really overlap: all four ran at once and wall time is well under their sum' `
    ($peak -eq 4 -and $side -gt 0 -and ($side * 2) -lt $sum) "side=${side}s sum=${sum}s peak=$peak"
Check 'each side-by-side child gets a share of the cores as zig -j' `
    ($r.Text -match 'side by side, -j(\d+) each' -and [int]$Matches[1] -ge 2 -and
    [int]$Matches[1] -lt [Environment]::ProcessorCount) ''

# A lane that fails ONLY side by side - the 2026-10-15 cold-cache shape - must
# come out green, and must say it was contention rather than vanish.
$marker = Join-Path $env:TEMP ("floor-lane-parallel-flaky-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$flaky = "powershell -NoProfile -Command `"if (Test-Path '$marker') { exit 0 }; `$null = New-Item -ItemType File '$marker'; exit 1`""
try {
    $rf = Invoke-Floor -Fake @{ lib = 'ping -n 2 127.0.0.1 >nul'; none = $flaky; win32 = 'ping -n 2 127.0.0.1 >nul'; agent = 'ping -n 2 127.0.0.1 >nul' }
}
catch { Write-Host "FAIL  the contention run threw: $($_.Exception.Message)"; $script:Failures++; $rf = [pscustomobject]@{ Code = -1; Lines = @(''); Text = '' } }
finally { Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue }
Check 'a lane red only side by side passes alone: exit 0, and FLOOR PARALLEL CONTENTION names it' `
    ($rf.Code -eq 0 -and $rf.Lines[-1] -eq 'ALL LANES PASS' -and $rf.Text -match 'FLOOR PARALLEL CONTENTION: none ' -and
    $rf.Text -match 'none#1=PASS[^\n]*\[side by side: FAIL\]') "exit=$($rf.Code)"

# ---- arm 9: the same planted lanes, serial, score the same words -------------

$rs = Invoke-Floor -Fake $mixed -Extra @('-Serial')
$vs = Get-Verdicts -Lines $rs.Lines
$same = $true
foreach ($k in 'lib', 'none', 'win32', 'agent') { if ($v[$k] -ne $vs[$k]) { $same = $false } }
Check 'serial and parallel give the same per-lane verdicts and the same exit code' `
    ($same -and $rs.Code -eq $r.Code) ("serial: " + (($vs.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' ') + " exit=$($rs.Code)")

# ---- arms 10-11: red alone, green alone ---------------------------------------

$quick = 'ping -n 3 127.0.0.1 >nul'
$r2 = Invoke-Floor -Fake @{ lib = $quick; none = $quick; win32 = $red; agent = $quick }
Check 'one red lane fails the set: exit 1, FLOOR NOT GREEN' `
    ($r2.Code -eq 1 -and $r2.Lines[-1] -eq 'FLOOR NOT GREEN' -and (Get-Verdicts -Lines $r2.Lines)['win32'] -eq 'FAIL') `
    "exit=$($r2.Code)"

$r3 = Invoke-Floor -Fake @{ lib = $quick; none = $quick; win32 = $quick; agent = $quick }
Check 'an all-green set exits 0 with ALL LANES PASS and no failure detail' `
    ($r3.Code -eq 0 -and $r3.Lines[-1] -eq 'ALL LANES PASS' -and $r3.Text -notmatch 'FLOOR FAILURE DETAIL') `
    "exit=$($r3.Code) last=$(if ($r3.Lines.Count) { $r3.Lines[-1] })"

# ---- arm 12: no commit for a second lane means one at a time -----------------

$r4 = Invoke-Floor -Fake @{ lib = $quick; none = $quick; win32 = $quick; agent = $quick } -Extra @('-LaneCommitGB', '100000')
$p4 = [regex]::Match($r4.Text, 'up to (\d+) at once')
Check 'a commit budget too small for two lanes runs them one at a time, and still all of them' `
    ($r4.Code -eq 0 -and $p4.Success -and $p4.Groups[1].Value -eq '1' -and
    @((Get-Verdicts -Lines $r4.Lines).Values | Where-Object { $_ -eq 'PASS' }).Count -eq 4) `
    "exit=$($r4.Code) $($p4.Value)"

# ---- arms 13-17: crash records belong to their own lane ----------------------

. (Join-Path $RepoRoot 'scripts\lib\CrashDiag.ps1')
$laneRoot = 'D:\r\zig-lanes\none'
$mine = 'D:\r\zig-lanes\none\.zig-cache\o\abc\ghostty-test.exe'
$theirs = 'D:\r\zig-lanes\win32\.zig-cache\o\abc\ghostty-test.exe'
Check 'an isolated lane keeps a crash of its own test binary' `
    (Test-CrashRecordInLaneRoots -App 'ghostty-test.exe' -AppPath $mine -Roots @($laneRoot)) ''
Check 'an isolated lane drops the same binary name crashing under ANOTHER lane''s root' `
    (-not (Test-CrashRecordInLaneRoots -App 'ghostty-test.exe' -AppPath $theirs -Roots @($laneRoot))) ''
Check 'a compiler crash is kept: every lane runs the same zig.exe' `
    (Test-CrashRecordInLaneRoots -App 'zig.exe' -AppPath 'C:\zig\zig.exe' -Roots @($laneRoot)) ''
Check 'a record with no readable image path is kept rather than lost' `
    (Test-CrashRecordInLaneRoots -App 'ghostty-test.exe' -AppPath '?' -Roots @($laneRoot)) ''
Check 'a lane that is not isolated keeps everything (the serial floor is unchanged)' `
    (Test-CrashRecordInLaneRoots -App 'ghostty-test.exe' -AppPath $theirs -Roots @()) ''

# ---- arm 18: the cache sweeper finds the per-lane caches ---------------------

. (Join-Path $RepoRoot 'scripts\lib\BuildCache.ps1')
$fakeRepo = Join-Path $env:TEMP ("floor-lane-parallel-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
try {
    foreach ($l in 'none', 'agent') {
        New-Item -ItemType Directory -Force -Path (Join-Path (Get-FloorLaneRoot -RepoPath $fakeRepo -Lane $l) '.zig-cache') | Out-Null
    }
    New-Item -ItemType Directory -Force -Path (Join-Path $fakeRepo 'zig-lanes\nocache') | Out-Null
    $found = @(Get-FloorLaneCacheDirs -RepoPath $fakeRepo)
    Check 'Get-FloorLaneCacheDirs lists exactly the lane caches that exist' `
        ($found.Count -eq 2 -and @($found | Where-Object { $_ -like '*\zig-lanes\none\.zig-cache' }).Count -eq 1 -and
        @($found | Where-Object { $_ -like '*\zig-lanes\agent\.zig-cache' }).Count -eq 1) ($found -join ' | ')
    $bc = @(& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot 'scripts\build-cache.ps1') check -Repo $fakeRepo -Json 2>&1 |
            ForEach-Object { $_.ToString() }) -join "`n"
    Check 'build-cache.ps1 measures the per-lane caches with the others' `
        ($bc -match 'zig-lanes\\\\none\\\\.zig-cache' -and $bc -match 'zig-lanes\\\\agent\\\\.zig-cache') ''
}
catch { Write-Host "FAIL  the per-lane cache arms threw: $($_.Exception.Message)"; $script:Failures++ }
finally { Remove-Item -LiteralPath $fakeRepo -Recurse -Force -ErrorAction SilentlyContinue }

Complete-TestBody  # T1039: the run reached the end of its body

if ($script:Failures -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot 'scripts\guard-due.ps1') `
        update -Guard lane-parallel -Repo $RepoRoot 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:Passes -Fail $script:Failures
