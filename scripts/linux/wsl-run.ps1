# wsl-run.ps1 - the ONE way a Linux build, test or launch is started from
# Windows (T3329, docs/design/linux-port.md, "WSL specifics").
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -- uname -a
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -Step 'zig build -Doptimize=Debug' -Step 'zig build test'
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -Plan -- zig build     (prints, starts nothing)
#
# Why it exists: WSL2 has taken 28 GB on this box, and the user's
# %USERPROFILE%\.wslconfig (memory=48GB, vmIdleTimeout=-1) is THEIRS, tuned for
# other WSL work - this script never reads or edits it. So the guard is on the
# Windows side:
#
#   - REFUSES (exit 2, one line starting 'WSL-RUN REFUSED') when Windows free
#     physical memory is under -MinFreeGB (default 16, or
#     $env:GHOZTTY_WSL_MIN_FREE_GB). The check runs BEFORE any wsl.exe call
#     that could boot the VM, and again before every -Step.
#   - Caps zig's parallelism inside WSL: `zig build` gets -j<n>, n from the
#     free memory above the floor (-GBPerJob each, default 3) and the core count.
#   - Names the distro (-d Ubuntu); docker-desktop is refused outright.
#   - Puts the Linux build first on PATH and drops every /mnt/* entry WSL
#     appends from Windows, so a bare `ghoztty` can never reach the user's
#     Windows terminal through interop.
#   - Refuses to run from a Windows loop lane (a, b, ...): only lane l, or a
#     person passing -AllowAnyLane, may boot WSL (CLAUDE.md: "Never start WSL
#     unasked - nothing in the Windows floor, sweeps or go-loop may boot it").
#   - Leaves WSL as it found it: if no distro was running before the call, it
#     terminates the distro afterwards, and shuts the VM down when nothing else
#     is running (vmIdleTimeout=-1 would otherwise keep the memory forever).
#     -KeepRunning skips that.
#
# -Repo clone (default) runs in ~/ghoztty-l inside the distro's own filesystem,
#             synced to this worktree's HEAD commit (committed work only; the
#             clone is this script's mirror and is reset to that commit every
#             call). Measured 2026-11-21: `git status` 0.01s here against 42s
#             on /mnt, file walks and copies 100x+ faster (docs/claude/linux.md).
# -Repo mnt   runs in /mnt/<drive>/<path> of this worktree - the live tree,
#             uncommitted edits included - at /mnt's 9P speed.
#
# Exit: the command's own exit code; 2 refused (memory, lane, distro); 3 the
# distro is not installed or wsl.exe failed to start it.
#
# ASCII only and PS 5.1 compatible.

# Options are parsed BY HAND from $args, deliberately: under `powershell -File`
# a param() block turns `--` into an ambiguous parameter named '' and binds the
# command's own flags (`uname -a` -> -AllowAnyLane) to ours. Everything after
# `--`, or from the first token that is not one of our options, is the command.
#
#   -Distro <name>   (Ubuntu)        -Repo clone|mnt (clone)
#   -MinFreeGB <n>   (16)            -GBPerJob <n>   (3)
#   -Step <cmd>      repeatable; each step re-checks memory first
#   -CommandFile <path>  a bash script file run as one step, verbatim. Use it
#                    for anything with double quotes: PS 5.1 strips embedded "
#                    from a command line handed to `powershell -File`, so
#                    `-- 'echo "a b"'` arrives as `echo a b`.
#   Inside a step, `command -v zig` names the wrapper function below; ask
#   `type -P zig` for the real binary.
#   -KeepRunning  -AllowAnyLane  -Plan
#   -FakeFreeGB <n>  test seam: pretend Windows has this much free memory.
#                    Never used by a real caller; the acceptance script drives
#                    the refusal and the job arithmetic with it, booting nothing.

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
. (Join-Path $root 'scripts\lib\LoopLane.ps1')

function Write-Refusal([string]$why) {
    Write-Host "WSL-RUN REFUSED $why"
    exit 2
}

$Distro = 'Ubuntu'; $MinFreeGB = -1.0; $GBPerJob = 3.0; $Repo = 'clone'; $FakeFreeGB = -1.0
$Step = @(); $KeepRunning = $false; $AllowAnyLane = $false; $Plan = $false
$Command = @()
$argv = @($args)
$k = 0
function Get-OptValue([string]$name) {
    if ($script:k + 1 -ge $script:argv.Count) { Write-Refusal "option $name needs a value." }
    $script:k++
    return [string]$script:argv[$script:k]
}
function ConvertTo-Number([string]$name, [string]$v) {
    $d = 0.0
    if (-not [double]::TryParse($v, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { Write-Refusal "option $name wants a number, got '$v'." }
    return $d
}
while ($k -lt $argv.Count) {
    $a = [string]$argv[$k]
    if ($a -eq '--') { $Command = @($argv | Select-Object -Skip ($k + 1)); break }
    switch -regex ($a) {
        '^-Distro$'       { $Distro = Get-OptValue $a; break }
        '^-MinFreeGB$'    { $MinFreeGB = ConvertTo-Number $a (Get-OptValue $a); break }
        '^-GBPerJob$'     { $GBPerJob = ConvertTo-Number $a (Get-OptValue $a); break }
        '^-FakeFreeGB$'   { $FakeFreeGB = ConvertTo-Number $a (Get-OptValue $a); break }
        '^-Repo$'         { $Repo = Get-OptValue $a; if ($Repo -notin @('mnt', 'clone')) { Write-Refusal "-Repo is mnt or clone, got '$Repo'." }; break }
        '^-Step$'         { $Step += (Get-OptValue $a); break }
        '^-CommandFile$'  {
            $cf = Get-OptValue $a
            if (-not (Test-Path -LiteralPath $cf)) { Write-Refusal "-CommandFile '$cf' does not exist." }
            $Step += ([System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $cf).Path) -replace "`r`n", "`n")
            break
        }
        '^-KeepRunning$'  { $KeepRunning = $true; break }
        '^-AllowAnyLane$' { $AllowAnyLane = $true; break }
        '^-Plan$'         { $Plan = $true; break }
        '^-'              { Write-Refusal "unknown option '$a' (put the command after --)." }
        default           { $Command = @($argv | Select-Object -Skip $k); $k = $argv.Count }
    }
    $k++
}
if ($GBPerJob -le 0) { Write-Refusal '-GBPerJob must be above 0.' }

if ($MinFreeGB -lt 0) {
    $envFloor = [string]$env:GHOZTTY_WSL_MIN_FREE_GB
    $parsed = 0.0
    if ($envFloor -and [double]::TryParse($envFloor, [ref]$parsed)) { $MinFreeGB = $parsed } else { $MinFreeGB = 16 }
}

function Get-FreeGB {
    if ($FakeFreeGB -ge 0) { return [double]$FakeFreeGB }
    $os = Get-CimInstance Win32_OperatingSystem
    return [math]::Round(([double]$os.FreePhysicalMemory) / 1MB, 1)   # KB -> GB
}

function Assert-Memory([string]$when) {
    $free = Get-FreeGB
    if ($free -lt $MinFreeGB) {
        Write-Refusal ("Windows has {0:N1} GB free, under the {1:N1} GB floor ({2}) - a Linux build now would starve the Windows lanes. WSL was not started by this call." -f $free, $MinFreeGB, $when)
    }
    return $free
}

function Get-JobCount([double]$free) {
    $cores = [Environment]::ProcessorCount
    $n = [math]::Floor(($free - $MinFreeGB) / $GBPerJob)
    if ($n -lt 1) { $n = 1 }
    if ($n -gt $cores) { $n = $cores }
    return [int]$n
}

$Command = @($Command | Where-Object { $_ -ne $null })
$steps = @()
if ($Step.Count -gt 0) { $steps += $Step }
if ($Command.Count -gt 0) { $steps += ($Command -join ' ') }
if ($steps.Count -eq 0) {
    Write-Host 'usage: wsl-run.ps1 [-Distro Ubuntu] [-Repo mnt|clone] [-MinFreeGB 16] [-KeepRunning] [-Plan] -- <command>   |   -Step <cmd>,<cmd>'
    exit 2
}

# --- refusals that need no WSL at all -----------------------------------------
if ($Distro -match '^docker-desktop') {
    Write-Refusal "distro '$Distro' belongs to Docker Desktop; Linux builds run in Ubuntu."
}
$lane = Get-LoopLaneId -Repo $root
if ($lane -ne 'l' -and -not $AllowAnyLane) {
    Write-Refusal "lane $lane is a Windows lane; only the Linux lane (D:\git\ghoztty-l, lane l) starts WSL. A person running it by hand passes -AllowAnyLane."
}
$free = Assert-Memory 'before start'
$jobs = Get-JobCount $free

# --- paths ---------------------------------------------------------------------
function ConvertTo-WslPath([string]$p) {
    $full = [System.IO.Path]::GetFullPath($p)
    if ($full -notmatch '^([A-Za-z]):\\?(.*)$') { throw "not a drive path: $full" }
    $drive = $Matches[1].ToLowerInvariant()
    $rest = $Matches[2].Replace('\', '/').TrimEnd('/')
    if ($rest) { return "/mnt/$drive/$rest" } else { return "/mnt/$drive" }
}
$mntRepo = ConvertTo-WslPath $root
$head = (& git -C $root rev-parse HEAD 2>$null)
# A linked worktree's .git FILE says `gitdir: D:/git/ghoztty/.git/worktrees/...`,
# a Windows path Linux git cannot follow ("not a git repository"), so name both
# git dirs for it in /mnt form. The common dir holds every object, so the clone
# is made from it, not from the worktree.
$gitDirs = @(& git -C $root rev-parse --path-format=absolute --git-dir --git-common-dir 2>$null)
$wslGitDir = ConvertTo-WslPath ([string]$gitDirs[0]).Replace('/', '\')
$wslCommon = ConvertTo-WslPath ([string]$gitDirs[1]).Replace('/', '\')
if ($Repo -eq 'clone') { $workDir = '$HOME/ghoztty-l' } else { $workDir = "'$mntRepo'" }

# --- the bash prelude every step runs under -------------------------------------
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('set -e')
$lines.Add("export GHOZTTY_WSL_JOBS=$jobs")
if ($Repo -eq 'clone') {
    $lines.Add('if [ ! -d "$HOME/ghoztty-l/.git" ]; then git clone --quiet --no-checkout ' + "'$wslCommon'" + ' "$HOME/ghoztty-l"; fi')
    $lines.Add('git -C "$HOME/ghoztty-l" fetch --quiet ' + "'$wslCommon'" + " $head")
    $lines.Add("git -C `"`$HOME/ghoztty-l`" checkout --quiet --force --detach $head")
} else {
    # GIT_OPTIONAL_LOCKS=0: a Linux `git status` must not rewrite the index the
    # Windows lane's git owns (it would store Linux stat data and make every
    # Windows git call rehash the tree).
    $lines.Add("export GIT_DIR='$wslGitDir' GIT_WORK_TREE='$mntRepo' GIT_OPTIONAL_LOCKS=0")
}
$lines.Add("cd $workDir")
# PATH: our Linux build first, then the distro's own entries; every /mnt/* entry
# (the Windows PATH that WSL appends) is dropped.
$lines.Add('__p=""; IFS=:; for __e in $PATH; do case "$__e" in /mnt/*) ;; *) __p="${__p:+$__p:}$__e";; esac; done; unset IFS')
$lines.Add('export PATH="$PWD/zig-out/bin:$__p"; unset __p __e')
# zig build gets the memory-derived -j unless the caller already gave one.
$lines.Add('zig() { if [ "$1" = build ]; then shift; case " $* " in *" -j"*) command zig build "$@";; *) command zig build -j"$GHOZTTY_WSL_JOBS" "$@";; esac; else command zig "$@"; fi; }')
$lines.Add('export -f zig')
$lines.Add('set +e')
$prelude = ($lines -join "`n")

if ($Plan) {
    Write-Host ("WSL-RUN PLAN distro={0} lane={1} repo={2} free={3:N1}GB floor={4:N1}GB jobs={5}" -f $Distro, $lane, $Repo, $free, $MinFreeGB, $jobs)
    Write-Host '--- prelude'
    Write-Host $prelude
    $i = 0
    foreach ($s in $steps) { $i++; Write-Host "--- step $i"; Write-Host $s }
    exit 0
}

# --- WSL state (these calls never boot the VM) -----------------------------------
$env:WSL_UTF8 = '1'
function Get-WslDistros([switch]$Running) {
    $a = @('-l', '-q'); if ($Running) { $a = @('-l', '--running', '-q') }
    $out = @(& wsl.exe @a 2>$null)
    return @($out | ForEach-Object { (([string]$_) -replace "`0", '').Trim() } | Where-Object { $_ -and $_ -notmatch '^There are no' })
}
$installed = @(Get-WslDistros)
if (-not ($installed -contains $Distro)) {
    Write-Host "WSL-RUN NO DISTRO '$Distro' is not installed (have: $($installed -join ', '))"
    exit 3
}
$runningBefore = @(Get-WslDistros -Running)
$vmWasIdle = ($runningBefore.Count -eq 0)

$tmpDir = Join-Path $root 'temp\wsl-run'
if (-not (Test-Path $tmpDir)) { New-Item -ItemType Directory -Force $tmpDir | Out-Null }
$utf8 = New-Object System.Text.UTF8Encoding($false)
$rc = 0
$i = 0
try {
    foreach ($s in $steps) {
        $i++
        if ($i -gt 1) {
            $free = Assert-Memory "before step $i"
            $jobs = Get-JobCount $free
            $prelude = $prelude -replace 'export GHOZTTY_WSL_JOBS=\d+', "export GHOZTTY_WSL_JOBS=$jobs"
        }
        $file = Join-Path $tmpDir ("step-{0}-{1}.sh" -f $PID, $i)
        [System.IO.File]::WriteAllText($file, ($prelude + "`n" + $s + "`n"), $utf8)
        Write-Host ("WSL-RUN step {0}/{1} distro={2} repo={3} jobs={4} free={5:N1}GB: {6}" -f $i, $steps.Count, $Distro, $Repo, $jobs, $free, $s)
        & wsl.exe -d $Distro -- bash (ConvertTo-WslPath $file)
        $rc = $LASTEXITCODE
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
        if ($rc -ne 0) { Write-Host "WSL-RUN step $i exited $rc"; break }
    }
} finally {
    if ($vmWasIdle -and -not $KeepRunning) {
        & wsl.exe --terminate $Distro 2>$null | Out-Null
        $still = @(Get-WslDistros -Running)
        if ($still.Count -eq 0) {
            & wsl.exe --shutdown 2>$null | Out-Null
            Write-Host 'WSL-RUN left WSL as found: distro terminated, VM shut down (it was idle before this call)'
        } else {
            Write-Host "WSL-RUN terminated $Distro; VM kept for: $($still -join ', ')"
        }
    }
}
exit $rc
