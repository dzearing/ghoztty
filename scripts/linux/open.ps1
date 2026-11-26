# Open the Linux (GTK) Ghoztty on the user's screen through WSLg.
#
#   powershell -NoProfile -File scripts\linux\open.ps1            # launch the latest lane-l build
#   powershell -NoProfile -File scripts\linux\open.ps1 -Build     # rebuild it first (lane l's tree)
#   powershell -NoProfile -File scripts\linux\open.ps1 -Stop      # close every window it opened
#
# Why this exists (user, 2026-11-24: "why havent we opened the linux version
# yet? can't we automate that"). Every Linux test runs in a private headless
# Weston (docs/claude/linux.md), so in its first three days nobody had seen
# the port on a real screen. This is the one-command way to look at it.
#
# It is a PERSON's command, not a loop step: it puts windows on the user's
# display, so no lane (not even lane l) calls it - the same rule as WSL
# itself. It goes through scripts\linux\wsl-run.ps1 like every Linux command
# (memory guard, distro pinned, Windows PATH dropped) with -AllowAnyLane and
# -KeepRunning -NoLease, because the app must outlive the call and belongs to
# the person who opened it: no lane lease is recorded, so a lane's -Release
# can never take it down (T3721).
#
# What it runs: lane l's in-distro build at ~/ghoztty-l/zig-out (a Debug build:
# its socket and agent dir are the -debug ones, so it never meets anything
# else). The binary needs the gtk4-layer-shell it was built with
# (-fno-sys=gtk4-layer-shell, Ubuntu 24.04 does not package it), hence
# LD_LIBRARY_PATH=zig-out/lib. The app picks the WSLg GPU itself (T3350).
#
# The floor is 8 GB, not wsl-run's 16: launching the app is not a zig build.
# -Build uses the 16 GB floor, since that IS one.

$Build = $false; $Stop = $false
foreach ($a in $args) {
    switch -Regex ($a) {
        '^-Build$' { $Build = $true; break }
        '^-Stop$' { $Stop = $true; break }
        default { Write-Host "open.ps1: unknown argument '$a' (use -Build or -Stop)"; exit 2 }
    }
}

$wslRun = Join-Path $PSScriptRoot 'wsl-run.ps1'
$tree = '/root/ghoztty-l'
$bin = "$tree/zig-out/bin/ghoztty"
$log = '/tmp/ghoztty-open.log'

if ($Stop) {
    # Only our build's processes, by full path - never a bare 'ghoztty'.
    & $wslRun -AllowAnyLane -KeepRunning -NoLease -Repo mnt -MinFreeGB 1 -Step "pkill -f '^$bin( |$)' && echo 'OPEN stopped the Linux Ghoztty' || echo 'OPEN no Linux Ghoztty was running'"
    exit $LASTEXITCODE
}

if ($Build) {
    # Lane l's tree, at lane l's HEAD: run from D:\git\ghoztty-l so wsl-run's
    # clone mode checks out THAT worktree's commit, not this one's.
    $laneL = Join-Path (Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent) 'ghoztty-l'
    $laneWslRun = Join-Path $laneL 'scripts\linux\wsl-run.ps1'
    if (-not (Test-Path $laneWslRun)) { Write-Host "OPEN FAILED no lane-l worktree at $laneL"; exit 1 }
    & $laneWslRun -AllowAnyLane -KeepRunning -NoLease -Step 'zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell'
    if ($LASTEXITCODE -ne 0) { Write-Host "OPEN FAILED the Linux build exited $LASTEXITCODE"; exit $LASTEXITCODE }
}

$step = @"
if [ ! -x $bin ]; then echo 'OPEN FAILED no Linux build at $bin (run with -Build)'; exit 1; fi
cd "`$HOME"
# WSLg's Wayland socket lives in /mnt/wslg/runtime-dir, and root's
# XDG_RUNTIME_DIR (/run/user/0) has no link to it, so GDK fell back to X11
# (XWayland). There Mesa's d3d12 driver cannot attach X11 shared memory
# ("MESA: error: Failed to attach to x11 shm"), so no frame ever reached the
# screen: the window was see-through while the app's own render was fine
# (user report 2026-11-25, T3783). Point it at the socket by absolute path.
wl=`$XDG_RUNTIME_DIR/`${WAYLAND_DISPLAY:-wayland-0}
if [ ! -S "`$wl" ] && [ -S /mnt/wslg/runtime-dir/wayland-0 ]; then export WAYLAND_DISPLAY=/mnt/wslg/runtime-dir/wayland-0; fi
LD_LIBRARY_PATH=$tree/zig-out/lib setsid nohup $bin > $log 2>&1 < /dev/null &
pid=`$!
sleep 5
if kill -0 `$pid 2>/dev/null; then
  echo "OPEN running pid=`$pid build=`$(date -r $bin '+%Y-%m-%d %H:%M') log=$log"
  grep -m1 'GALLIUM_DRIVER' $log || true
  grep -m1 'windowing protocol' $log || true
else
  echo 'OPEN FAILED the app exited at startup; last lines of its log:'; tail -15 $log; exit 1
fi
"@
& $wslRun -AllowAnyLane -KeepRunning -NoLease -Repo mnt -MinFreeGB 8 -Step $step
exit $LASTEXITCODE
