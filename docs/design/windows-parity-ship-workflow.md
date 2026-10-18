# The ship workflow: cutting over from one long branch to per-feature PRs

**Task:** T1058. **User directive, 2026-08-21:** *"when we feel like we're in a
stable state and feature complete, we would get this all merged back into main
and continue work from there or build individual worktrees for new features and
make prs."*

This doc is the whole transition in one place: what has to be true before the
cutover, how the cutover is done, and what a turn looks like afterwards. It is
referenced from `go.md`, which is the file every turn actually reads.

## Which merge this is

Three different merges used to share the name "merge back", and two of them got
mistaken for the third on 2026-08-22 (T1097). They are named apart now. This doc
covers the **cutover**, the first row:

| | The operation | Direction | Where it is planned |
|---|---|---|---|
| **Cutover** | `users/dzearing/windows-amd64` → `main` on dzearing/ghoztty | our branch becomes the trunk | **this doc**, gated by `scripts\ship-readiness.ps1` |
| **Upstream pull** | ghostty-org/ghostty `main` → this fork | code flows INTO us, on the user's call only | `windows-parity-upstream-pull-plan.md`, policy in D80 |
| **Upstreaming** | this fork → ghostty-org/ghostty | **never happens** | D80. No PR, no pushed branch; the `upstream` remote is fetch-only by construction |

Never write the bare phrase "merge back" again — say "cutover", "upstream pull",
or "upstreaming", and name the direction in the same sentence.

`origin/main` is not a dead trunk. The Mac seat has been merging feature
branches into it all along — `users/dzearing/pane-resize-fixed-edges`,
`users/dzearing/session-restore`, `users/dzearing/url-protocol` — with releases
cut off it up to v1.34.0. **So the post-cutover shape is not invented here; it
is the shape `main` already has.** What the Windows seat is doing is joining it.

## Today, and the two things wrong with it

Every turn commits straight onto `users/dzearing/windows-amd64`. As of
2026-08-21 that is 1397 commits ahead of `origin/main` and 93 behind.

1. **There is no review point.** Work is finished when a turn says it is
   finished. The only reader is the turn that wrote it, which is the weakest
   check the project has (T1060 exists for exactly this).
2. **Nothing ships independently.** A feature cannot reach `main` without
   bringing every other in-flight change with it, so the whole branch is either
   good or not good, and it has been "not yet" for months.

## Entry criteria — checked, not felt

"When we feel like we're in a stable state" is the part that has to become a
command, because the cutover happens once and a mood is not a gate:

```powershell
powershell -NoProfile -File scripts\ship-readiness.ps1
powershell -NoProfile -File scripts\ship-readiness.ps1 -RunLanes   # the real one
```

Exit 0 = READY, 1 = NOT READY (with every unmet criterion and its remedy named),
2 = the check could not run. `-Json` for the machine-readable form.

| Criterion | Satisfied when | Why it gates |
|---|---|---|
| `tree` | nothing uncommitted | a cutover carrying a dirty tree merges work nobody can name |
| `push` | HEAD == its upstream | a merge computed from unpushed commits is not the merge that happens |
| `behind` | `origin/main` fully contained in HEAD | main is live; unmerged main commits make this a three-way merge, not a cutover |
| `p0` | no open P0 (either seat) | a P0 is a crash, hang, data loss or a broken feature — "stable" cannot be true over one |
| `inprogress` | no other task in-progress | half-finished work in the trunk is what the PR boundary exists to prevent |
| `guards` | `guard-due.ps1 check` clean | a due harness means "green" is a memory, not a measurement |
| `macseat` | T87 done or explicitly sequenced | this box cannot build macOS; the Mac half is unowned until a human takes it |
| `lanes` | the four floor lanes green **this run** | measured only under `-RunLanes`; otherwise UNKNOWN, which counts as unmet |
| `accept` | P1–P3 green **this run** | same rule |
| `ghrepo` | `gh` resolves to `dzearing/ghoztty` | see the landmine below |

**UNKNOWN counts as unmet, deliberately.** A lane that was green yesterday says
nothing about today's tree, and the one failure mode this gate cannot afford is
reading "we did not look" as "ready".

### The `gh` landmine

This repo has two remotes — `origin` (dzearing/ghoztty) and `upstream`
(ghostty-org/ghostty) — and until T1058 no `gh repo set-default`. `gh` picks a
repository by walking the remotes, and a bare `gh pr list` here answered with
**upstream's** open pull requests. Under a PR workflow that means a bare
`gh pr create` would have offered this fork's Windows work as a pull request to
the public Ghostty project: outward-facing, and not retractable.

Two defences, both required, because the first one is local config that no
`git clone` and no `git pull` carries:

- `gh repo set-default dzearing/ghoztty` (done on this box; `ghrepo` re-checks it
  every readiness run).
- **Every repository-scoped `gh` call in this family passes `--repo` explicitly.**
  Section C of `test\win32\ship-workflow.ps1` scans for a bare one and fails.

## The cutover

Run only when `ship-readiness.ps1 -RunLanes` exits 0.

1. **Close the `behind` gap first.** Merge `origin/main` **into** the branch, on
   the branch, where the floor lanes can judge the result. Resolving 93 commits'
   worth of conflicts inside the merge *to* main would put the resolution
   straight onto the trunk with nothing to test it against.
2. **Re-run the floor lanes and P1–P3** after that merge. It is a real merge;
   green before it is not evidence about after it.
3. **The Mac seat runs T87** — the macOS regression build — against the merged
   branch. The Windows seat cannot do this and must not assume it.
4. **Merge branch → `main`** as a merge commit (never a squash: 1397 commits of
   history and the tracker's `commits:` fields both reference these shas).
5. **Verify on the trunk**: floor lanes and P1–P3 green from `main`, and a
   `+list` smoke on both platforms.
6. **Retire the old path** — `go.md` step 6 stops committing to the long branch
   and starts the per-feature flow below. Until this step happens, the old path
   is still the path.

## After the cutover: one feature, one worktree, one PR

`scripts\ship-feature.ps1` is the lifecycle. Each command has its checks built
in, so the workflow does not depend on a turn reading this section carefully.

```powershell
# start: a worktree at D:\git\ghoztty-wt\<slug> on users/dzearing/<slug>, forked
# from a freshly fetched origin/main
powershell -NoProfile -File scripts\ship-feature.ps1 new -Slug banner-fade

# what is in flight, and where each one stands (branch, commits, dirty, unpushed, PR)
powershell -NoProfile -File scripts\ship-feature.ps1 list

# push and open the PR against the FORK, explicitly
powershell -NoProfile -File scripts\ship-feature.ps1 pr -Slug banner-fade `
    -Title "the banner fades out when it collapses" -Body "..."

# after it merges: remove the worktree and delete the branch
powershell -NoProfile -File scripts\ship-feature.ps1 done -Slug banner-fade
```

**What each command refuses, and why:**

- `new` — a slug that already exists (silently landing in someone else's
  worktree is how two features end up in one branch) and a slug that is not
  kebab-case (it becomes both a directory name and a git ref). It fetches first,
  so the fork point is today's main.
- `pr` — a dirty tree (a PR must describe committed work) and a branch with no
  commits of its own (a PR over nothing is a notification people learn to
  ignore). Re-running it on a branch that already has an open PR pushes and says
  so rather than opening a second one.
- `done` — a dirty tree, unpushed commits, or a PR that is still open. `-Force`
  is the abandon path and prints that it was used.

**Why a worktree rather than `git checkout`.** This box runs a long-lived
Ghoztty out of `zig-out`, a dashboard server, an agent, and a go-loop whose lock
is keyed on a pane in this directory. A branch switch swaps the source out from
under all of it. A worktree gives the feature its own directory and leaves the
loop's tree alone — and an unfinished feature is then a directory somebody can
see rather than a stash somebody must remember.

**Relationship to the `/wt` skill.** `/wt` is the *interactive* path: it opens a
Ghoztty window, installs dependencies and starts a Claude session for a human.
`ship-feature.ps1` is the loop's non-interactive path and launches nothing. Both
can be used on the same worktree.

## The post-cutover turn

The turn shape in `go.md` changes in exactly three places:

- **Step 1 (pick a task)** gains a branch decision. `ship-feature.ps1 list`
  first: a worktree whose PR is open and not merged is **inherited work** and
  outranks a fresh task, the same way a `RESUME:` outranks a `NEXT:`. Otherwise
  `new -Slug <slug-from-the-task>`, and the turn works in that worktree.
- **Step 6 (update the tracker)** commits in the worktree, through the same
  `git-commit-guard.ps1` (the guard takes a repo-wide lock, and worktrees share
  the index-adjacent state that made the guard necessary), then `ship-feature.ps1
  pr`. The tracker update — task status, the log entry — is part of the feature's
  PR, not a separate commit on the trunk.
- **Merging** is its own act, gated by the adversarial review (T1060) and
  reported in the digest (T1059). A turn does not merge its own PR without that
  review having run — `ship-feature.ps1 merge` refuses until it has.

## The adversarial review (T1060)

User directive, 2026-08-21: every PR gets a review whose job is to **refute**
it — accuracy, CLAUDE.md compliance, quality and DRY design, and tests that can
fail. The person who wrote the change is the worst judge of it, so the reviewer
is never the turn that wrote the code: it is a fresh subagent handed the brief
below, with no stake in the merge.

```
# 1. mechanical refutation over the PR's diff (exit 1 = findings)
powershell -NoProfile -File scripts\pr-review.ps1 check -Base origin/main -Head HEAD

# 2. the brief for the independent reviewer: this checklist + the findings + the range
powershell -NoProfile -File scripts\pr-review.ps1 prompt -Base origin/main -Head HEAD

# 3. record what the reviewer concluded, keyed on the exact head; posted on the PR
powershell -NoProfile -File scripts\pr-review.ps1 record -Head HEAD -Verdict pass `
    -Summary "..." -Pr 12 [-Waive '<key>=<why it is a false positive>']

# 4. the merge, which runs the gate itself
powershell -NoProfile -File scripts\ship-feature.ps1 merge -Slug banner-fade
```

How it holds:

- **A pass cannot be recorded over an unanswered finding.** Each mechanical
  finding is fixed (it stops being reported) or waived with a one-sentence
  argument, and the waiver is written into the verdict and the PR comment.
- **The verdict is for one commit.** A push after the review makes it stale;
  `gate` says `REVIEW STALE` and names the commit that was reviewed.
- **Overriding is explicit.** `merge -Override -Reason "<why>"` records an
  `override` verdict with the reason, in the ledger and on the PR.
- The ledger lives under the repository's git common dir (`ghoztty-review\`),
  so a review recorded from a feature worktree is the one the gate reads.

The checklist the reviewer works — `pr-review.ps1 prompt` prints exactly the
text between these markers, so the gate and this document cannot drift apart:

<!-- review-checklist:begin -->
1. **Accuracy.** Every claim in the PR description, the commit messages and the
   task file is backed by evidence you can re-run or read. A ticked validation
   criterion is unproven until its text names how it was verified and that
   check actually says so. Re-run at least one claimed-green check yourself.
2. **CLAUDE.md compliance.** Platform symmetry: a feature lands on both macOS
   and Windows, or the other seat's task is filed in the same change. Nothing
   touches the user's installed Ghoztty; Windows builds are `-Doptimize=Debug`
   with the cache on the repo drive. The app<->agent wire protocol evolves
   additively. Code flows from Ghostty into Ghoztty, never back.
3. **Quality and DRY.** No second implementation of something that already
   exists: before accepting a new helper, search the shared libraries
   (`scripts\lib`, `test\win32\lib`, `src/`) for one that does the job. No mega
   files; split modules as they grow.
4. **Tests that can fail.** Pure logic has unit tests; behavior has an on-box
   acceptance script. For each new or changed test, name the edit to the code
   under test that would turn it red — a test nobody has seen go red is not
   evidence. A negative control is the best answer.
5. **Default to NOT PROVEN.** When you cannot establish a claim, it fails.
   Report defects a user or the next turn would pay for, not style preferences.
<!-- review-checklist:end -->

Everything else — the claim, the digest, the guards, `/reset-context` — is
unchanged.

## Open dependencies

| | What is needed | Owner |
|---|---|---|
| T87 | macOS regression build, then the merge validated on Mac | **Mac seat** — cannot be done here |
| T1059 | the digest names every open PR and its CI health | Windows seat, after this |
| T1060 | the adversarial review gate before any merge | done: `scripts\pr-review.ps1`, `ship-feature.ps1 merge` |
| `behind` | 93 commits of `origin/main` merged into the branch | Windows seat |

## Acceptance

`test\win32\ship-workflow.ps1` — the readiness gate's honesty (A), the whole
lifecycle in a throwaway repo pair including every refusal (B), the `gh`
landmine scan (C), the doc/go.md wiring (D), and the review gate's teeth (E): a
sandbox PR carrying every defect the gate names, each of which must be caught,
a clean PR that must pass without invented findings, and the record / stale /
merge refusals. Registered in `scripts\guard-due.ps1` as `ship-workflow`, so
editing any of the three scripts marks the harness due.
