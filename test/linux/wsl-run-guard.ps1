# wsl-run.ps1 guard acceptance (tracker T3329): the one Linux entry point
# refuses before it can boot WSL, and plans the run it would make.
#
# Every case here is a path that returns BEFORE wsl.exe could start the VM
# (-Plan, or a refusal), and the script asserts at the end that no WSL distro
# is running that was not running at the start - so it is safe to run from any
# lane and never boots WSL (CLAUDE.md: never start WSL unasked). The real
# `-- uname -a` run is the task's manual validation, recorded in T3329.
#
# Sections:
#   A. Memory floor: -FakeFreeGB under the floor -> exit 2, 'WSL-RUN REFUSED',
#      names both numbers. Also via $env:GHOZTTY_WSL_MIN_FREE_GB. Negative
#      control: the same call above the floor plans (exit 0).
#   B. Lane: GHOZTTY_LOOP_LANE=a and =b are refused; -AllowAnyLane lets a
#      person through; lane l plans.
#   C. Distro: docker-desktop is refused; the plan names -d's distro.
#   D. Argv: under `powershell -File`, `-- uname -a` reaches the command intact
#      (the param() block this replaced bound -a to -AllowAnyLane); an unknown
#      option before -- is refused, not silently swallowed.
#   E. Jobs: zig's -j comes from free memory above the floor (3 GB a job),
#      never under 1, never over the core count; the prelude wraps `zig build`
#      and drops /mnt/* from PATH.
#   F. Steps: -Step is repeatable and -CommandFile carries double quotes that
#      a plain command line loses.
#   G. Repo: the default is the in-distro clone; -Repo mnt exports a Linux
#      GIT_DIR (a worktree's .git file names a Windows path) with optional
#      locks off.
#   Z. WSL state unchanged.
#
# Exit 0 all pass, 1 any fail. ASCII only, PS 5.1.

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$wrapper = Join-Path $root 'scripts\linux\wsl-run.ps1'
$script:fails = 0
$script:passes = 0

function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { $script:passes++; Write-Host "PASS $name" }
    else { $script:fails++; Write-Host "FAIL $name $detail" }
}

# Run the wrapper as a real `powershell -File` child (the argv path under
# test), capture its combined output to a file and its exit code.
function Invoke-Wrapper([string[]]$argList, [hashtable]$envOver = @{}) {
    $out = Join-Path $env:TEMP ("wsl-run-guard-{0}-{1}.txt" -f $PID, [guid]::NewGuid().ToString('N').Substring(0, 8))
    $saved = @{}
    foreach ($kv in $envOver.GetEnumerator()) {
        $saved[$kv.Key] = [Environment]::GetEnvironmentVariable($kv.Key)
        [Environment]::SetEnvironmentVariable($kv.Key, $kv.Value)
    }
    try {
        & powershell -NoProfile -File $wrapper @argList *> $out
        $code = $LASTEXITCODE
    } finally {
        foreach ($kv in $saved.GetEnumerator()) { [Environment]::SetEnvironmentVariable($kv.Key, $kv.Value) }
    }
    $text = ''
    if (Test-Path $out) { $text = [System.IO.File]::ReadAllText($out); Remove-Item $out -Force }
    return [pscustomobject]@{ Code = $code; Text = $text }
}

function Get-Running {
    $env:WSL_UTF8 = '1'
    $r = @(& wsl.exe -l --running -q 2>$null)
    return @($r | ForEach-Object { (([string]$_) -replace "`0", '').Trim() } | Where-Object { $_ -and $_ -notmatch '^There are no' })
}

$lane = @{ GHOZTTY_LOOP_LANE = 'l'; GHOZTTY_WSL_MIN_FREE_GB = $null }
$runningAtStart = @(Get-Running)

# --- A. memory floor ---------------------------------------------------------
$r = Invoke-Wrapper @('-FakeFreeGB', '10', '-MinFreeGB', '16', '--', 'uname', '-a') $lane
Check 'A1 under the floor exits 2' ($r.Code -eq 2) "code=$($r.Code) $($r.Text)"
Check 'A2 refusal is one plain WSL-RUN REFUSED line naming both numbers' (($r.Text -match 'WSL-RUN REFUSED Windows has 10\.0 GB free, under the 16\.0 GB floor') -and ($r.Text -match 'WSL was not started')) $r.Text
Check 'A3 a refusal never plans or runs a step' ($r.Text -notmatch 'WSL-RUN (PLAN|step)') $r.Text
$r = Invoke-Wrapper @('-FakeFreeGB', '10', '--', 'uname', '-a') @{ GHOZTTY_LOOP_LANE = 'l'; GHOZTTY_WSL_MIN_FREE_GB = '12' }
Check 'A4 GHOZTTY_WSL_MIN_FREE_GB sets the floor' (($r.Code -eq 2) -and ($r.Text -match 'under the 12\.0 GB floor')) $r.Text
$r = Invoke-Wrapper @('-Plan', '-FakeFreeGB', '40', '-MinFreeGB', '16', '--', 'uname', '-a') $lane
Check 'A5 negative control: above the floor it plans' (($r.Code -eq 0) -and ($r.Text -match 'WSL-RUN PLAN')) "code=$($r.Code) $($r.Text)"

# --- B. lane -----------------------------------------------------------------
foreach ($l in @('a', 'b')) {
    $r = Invoke-Wrapper @('-Plan', '-FakeFreeGB', '40', '--', 'true') @{ GHOZTTY_LOOP_LANE = $l; GHOZTTY_WSL_MIN_FREE_GB = $null }
    Check "B1 Windows lane $l is refused" (($r.Code -eq 2) -and ($r.Text -match "WSL-RUN REFUSED lane $l is a Windows lane")) $r.Text
}
$r = Invoke-Wrapper @('-Plan', '-AllowAnyLane', '-FakeFreeGB', '40', '--', 'true') @{ GHOZTTY_LOOP_LANE = 'a'; GHOZTTY_WSL_MIN_FREE_GB = $null }
Check 'B2 -AllowAnyLane lets a person through from lane a' (($r.Code -eq 0) -and ($r.Text -match 'lane=a')) $r.Text
$r = Invoke-Wrapper @('-Plan', '-FakeFreeGB', '40', '--', 'true') $lane
Check 'B3 lane l plans' (($r.Code -eq 0) -and ($r.Text -match 'lane=l')) $r.Text

# --- C. distro ---------------------------------------------------------------
$r = Invoke-Wrapper @('-Plan', '-Distro', 'docker-desktop', '-FakeFreeGB', '40', '--', 'true') $lane
Check 'C1 docker-desktop is refused' (($r.Code -eq 2) -and ($r.Text -match "WSL-RUN REFUSED distro 'docker-desktop'")) $r.Text
$r = Invoke-Wrapper @('-Plan', '-FakeFreeGB', '40', '--', 'true') $lane
Check 'C2 the default distro is Ubuntu, named' ($r.Text -match 'distro=Ubuntu ') $r.Text

# --- D. argv -----------------------------------------------------------------
$r = Invoke-Wrapper @('-Plan', '-FakeFreeGB', '40', '--', 'uname', '-a') $lane
Check 'D1 -- uname -a reaches the step intact' (($r.Code -eq 0) -and ($r.Text -match "--- step 1\r?\nuname -a\r?\n")) $r.Text
$r = Invoke-Wrapper @('-Plan', '-FakeFreeGB', '40', 'uname', '-a') $lane
Check 'D2 without --, the first non-option token starts the command' (($r.Code -eq 0) -and ($r.Text -match "--- step 1\r?\nuname -a\r?\n")) $r.Text
$r = Invoke-Wrapper @('-Plan', '-Bogus', '-FakeFreeGB', '40', '--', 'true') $lane
Check 'D3 an unknown option before -- is refused' (($r.Code -eq 2) -and ($r.Text -match "unknown option '-Bogus'")) $r.Text
$r = Invoke-Wrapper @('-Plan', '-FakeFreeGB', '40') $lane
Check 'D4 no command prints usage and exits 2' (($r.Code -eq 2) -and ($r.Text -match 'usage: wsl-run.ps1')) $r.Text

# --- E. jobs + prelude -------------------------------------------------------
$cores = [Environment]::ProcessorCount
$r = Invoke-Wrapper @('-Plan', '-FakeFreeGB', '25', '-MinFreeGB', '16', '--', 'true') $lane
$want = [math]::Min(3, $cores)
Check "E1 9 GB above the floor at 3 GB a job is -j$want" ($r.Text -match "jobs=$want\b") $r.Text
$r = Invoke-Wrapper @('-Plan', '-FakeFreeGB', '17', '-MinFreeGB', '16', '--', 'true') $lane
Check 'E2 never under one job' ($r.Text -match 'jobs=1\b') $r.Text
$r = Invoke-Wrapper @('-Plan', '-FakeFreeGB', '100000', '-MinFreeGB', '16', '--', 'true') $lane
Check "E3 never over the core count ($cores)" ($r.Text -match "jobs=$cores\b") $r.Text
Check 'E4 zig build is wrapped with -j' ($r.Text -match 'command zig build -j"\$GHOZTTY_WSL_JOBS"') $r.Text
Check 'E5 /mnt/* is dropped from PATH and zig-out/bin goes first' (($r.Text -match '/mnt/\*\) ;;') -and ($r.Text -match 'export PATH="\$PWD/zig-out/bin:')) $r.Text
Check 'E5b the pinned build tools dir is on PATH, right after zig-out/bin' ($r.Text -match 'export PATH="\$PWD/zig-out/bin:\$HOME/\.local/ghoztty-tools/bin:') $r.Text

# --- F. steps ----------------------------------------------------------------
$r = Invoke-Wrapper @('-Plan', '-FakeFreeGB', '40', '-Step', 'echo one', '-Step', 'echo two') $lane
Check 'F1 -Step is repeatable, one step each' (($r.Text -match "--- step 1\r?\necho one") -and ($r.Text -match "--- step 2\r?\necho two")) $r.Text
$cf = Join-Path $env:TEMP "wsl-run-guard-cf-$PID.sh"
[System.IO.File]::WriteAllText($cf, "echo `"a  b`"`r`n", (New-Object System.Text.UTF8Encoding($false)))
$r = Invoke-Wrapper @('-Plan', '-FakeFreeGB', '40', '-CommandFile', $cf) $lane
Remove-Item $cf -Force
Check 'F2 -CommandFile keeps double quotes and drops CR' (($r.Text -match '--- step 1\r?\necho "a  b"') -and ($r.Text -notmatch "echo `"a  b`"`r`r")) $r.Text
$r = Invoke-Wrapper @('-Plan', '-FakeFreeGB', '40', '-CommandFile', 'C:\no\such\file.sh') $lane
Check 'F3 a missing -CommandFile is refused' (($r.Code -eq 2) -and ($r.Text -match 'does not exist')) $r.Text

# --- G. repo -----------------------------------------------------------------
$r = Invoke-Wrapper @('-Plan', '-FakeFreeGB', '40', '--', 'true') $lane
Check 'G1 the default is the in-distro clone, synced to HEAD' (($r.Text -match 'repo=clone') -and ($r.Text -match 'checkout --quiet --force --detach [0-9a-f]{40}') -and ($r.Text -match 'cd \$HOME/ghoztty-l')) $r.Text
Check 'G2 the clone is made from the common git dir in /mnt form' ($r.Text -match "git clone --quiet --no-checkout '/mnt/[a-z]/") $r.Text
$r = Invoke-Wrapper @('-Plan', '-Repo', 'mnt', '-FakeFreeGB', '40', '--', 'true') $lane
Check 'G3 -Repo mnt exports a Linux GIT_DIR with optional locks off' (($r.Text -match "export GIT_DIR='/mnt/[a-z]/") -and ($r.Text -match 'GIT_OPTIONAL_LOCKS=0') -and ($r.Text -notmatch "GIT_DIR='[A-Za-z]:")) $r.Text
$r = Invoke-Wrapper @('-Plan', '-Repo', 'nfs', '-FakeFreeGB', '40', '--', 'true') $lane
Check 'G4 an unknown -Repo is refused' ($r.Code -eq 2) $r.Text

# --- Z. nothing booted ---------------------------------------------------------
$runningAtEnd = @(Get-Running)
$new = @($runningAtEnd | Where-Object { $runningAtStart -notcontains $_ })
Check 'Z1 no WSL distro was started by this script' ($new.Count -eq 0) ("now running: " + ($new -join ', '))

# --- stamp (T783) ----------------------------------------------------------------
if ($script:fails -eq 0 -and $script:passes -gt 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\guard-due.ps1') `
        update -Guard wsl-run -Repo $root 2>&1 | ForEach-Object { Write-Host "  $_" }
}

Write-Host ("wsl-run-guard: {0} pass, {1} fail" -f $script:passes, $script:fails)
if ($script:fails -gt 0) { exit 1 }
exit 0
