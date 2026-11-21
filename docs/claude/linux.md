# Linux (WSL) bring-up: running anything Linux from this box

> Progressive-disclosure doc routed from `/CLAUDE.md`. Load it for any
> `seat: linux` task, anything under `src/apprt/gtk/`, `scripts/linux/` or
> `test/linux/`. The plan and phases are `docs/design/linux-port.md`; this file
> is how to actually run things. L4 (T3333) grows it into the full harness
> guide.

## The one entry point: `scripts\linux\wsl-run.ps1` (T3329)

Every Linux build, test or launch goes through it. Nothing else calls
`wsl.exe`, and nothing in the Windows floor, sweeps or Windows lanes calls it.

```powershell
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -- uname -a
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -Step 'zig build -Doptimize=Debug' -Step 'zig build test'
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile my-step.sh     # anything with double quotes
powershell -NoProfile -File scripts\linux\wsl-run.ps1 -Plan -- zig build         # print what it would run; starts nothing
```

What it guarantees:

| Guard | Behavior |
|---|---|
| Memory | Exit **2** `WSL-RUN REFUSED Windows has X GB free, under the Y GB floor` when free physical memory is under 16 GB (`-MinFreeGB`, `$env:GHOZTTY_WSL_MIN_FREE_GB`). Checked before any `wsl.exe` call that could boot the VM, and again before every `-Step`. |
| Parallelism | `zig build` inside a step gets `-j<n>`, n = (free - floor) / 3 GB, at least 1, at most the core count, recomputed per step. An explicit `-j` wins. `$GHOZTTY_WSL_JOBS` carries n. |
| Lane | Refused from Windows lanes (a, b, ...). Lane l runs; a person by hand passes `-AllowAnyLane`. |
| Distro | `-d Ubuntu` always (`-Distro` to change it); `docker-desktop` is refused. |
| PATH | `zig-out/bin` first, every `/mnt/*` entry (the Windows PATH WSL appends) dropped, so a bare `ghoztty` cannot reach the user's Windows terminal through interop. |
| Cleanup | If no distro was running before the call, the distro is terminated and the VM shut down afterwards (the user's `vmIdleTimeout=-1` would otherwise hold the memory forever). `-KeepRunning` skips it. A VM someone else started is left alone. |

Exit codes: the step's own; 2 refused; 3 the distro is not installed.

**Never edit `%USERPROFILE%\.wslconfig`.** It is the user's (`memory=48GB`,
`swap=16GB`, `vmIdleTimeout=-1`) and tuned for their other WSL work.

Acceptance: `test\linux\wsl-run-guard.ps1` (refusals, argv, job arithmetic,
plan contents) - it never boots WSL, and asserts so.

## Where the repo lives in WSL: the in-distro clone, by a mile

`-Repo clone` (default) runs in `~/ghoztty-l` inside the distro's ext4
filesystem, synced to this worktree's **HEAD commit** on every call (fetched
from the main repo's common `.git`, then a detached checkout). Uncommitted
edits are NOT there: commit first, or use `-Repo mnt`.

`-Repo mnt` runs in `/mnt/d/git/ghoztty-l` - the live tree - with
`GIT_DIR` pointed at the worktree's git dir in `/mnt` form (the worktree's
`.git` file names a Windows path, `D:/git/ghoztty/.git/worktrees/ghoztty-l`,
which Linux git reports as "not a git repository") and
`GIT_OPTIONAL_LOCKS=0`, so a Linux `git status` never rewrites the index the
Windows lane's git owns.

Measured 2026-11-21 on this box (Ubuntu 24.04, WSL kernel 5.15.167, same commit
a8e7bd2d1, 1764 files under `src/` + `pkg/`):

| Operation | `/mnt/d/...` | `~/ghoztty-l` |
|---|---|---|
| `git status --porcelain` (first) | 85.76 s | 0.16 s |
| `git status --porcelain` (warm) | 41.83 s | 0.01 s |
| `find src pkg -type f` | 0.31 s | 0.00 s |
| `grep -r` over `src/*.zig` | 1.21 s | 0.01 s |
| `tar -cf /dev/null src pkg` (read every file) | 1.12 s | 0.00 s |
| `cp -r src /tmp` | 5.12 s | 0.05 s |
| create 2000 small files | 2.80 s | 0.02 s |
| `rm -rf` those 2000 | 1.02 s | 0.01 s |

Zig's cache is thousands of small files written and stat'ed, which is exactly
the 100x+ row. A zig build timing is owed once zig is installed in the distro
(L1, T3330); the file-system gap above already settles the default.

## Distro state (2026-11-21)

- Ubuntu 24.04.1 LTS, runs as `root` (`$HOME=/root`), 32 cores, 47 GB visible.
- **No zig** (`type -P zig` is empty; inside a step `command -v zig` names the
  wrapper function, not a binary). 0.15.2 (`build.zig.zon`
  `minimum_zig_version`) is installed in L1.
- git is `/usr/bin/git`. No Linux `ghoztty` yet, and the Windows `ghoztty.exe`
  is not reachable from a step (PATH guard).
- The user runs other work in this distro (`~/*.sh`, a model server): do not
  touch `~` beyond `~/ghoztty-l`.
