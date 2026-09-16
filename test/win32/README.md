# `test\win32\` — the house rules for an acceptance script

This directory is the Windows acceptance suite: one script per behavior, each
one a standalone PowerShell 5.1 program that launches the freshly built
`zig-out\bin\ghoztty.exe`, measures something, and prints a verdict.

It also holds a second family whose subject is not the product but **this
suite**: audits that ask whether every script here scores itself, exits the
code its verdict implies, says out loud when it skipped a section, isolates its
endpoints, and keeps what the app said on its way out. Those rules were each
written by the turn that had just been burned by the trap it checks, and until
T725 they ran only when somebody remembered them by name — so a new script met
them one red run at a time, weeks apart (T732).

They do not have to be remembered any more. **This file is the entry point, and
one command is the check.**

## The one command

```powershell
powershell -NoProfile -File scripts\floor-lane.ps1 -Lane harness
```

That runs every audit in the **harness floor** — the set declared in
`scripts\lib\HarnessFloor.ps1` — and prints a single
`HARNESS FLOOR: ALL PASS (N audits)` / `N FAILURE(S)` line. About fifteen
minutes, because it is scanning the whole suite's source; nothing in it launches
the GUI or waits on a build.

Useful narrower forms, all through `scripts\harness-floor.ps1`:

```powershell
powershell -NoProfile -File scripts\harness-floor.ps1 -List
powershell -NoProfile -File scripts\harness-floor.ps1 -Include skip-visibility.ps1
```

It is not part of `-Lane all` (those are the four zig lanes). What makes it
standing instead is the **`harness-floor` guard row**: touch any script in this
directory and `scripts\guard-due.ps1 check` reports the floor as DUE, step 0's
`go-loop-exec.ps1 claim` prints that, and `parity-tasks.ps1 validate` refuses
the commit until the floor has been run green. The narrative is in
`docs/claude/testing.md`; the set and the reason each member is in it are in
`scripts\lib\HarnessFloor.ps1`.

An audit that is red today for a reason somebody has already filed is listed in
`$HARNESS_FLOOR_PENDING` against the task that converts it: it is run and
reported, and does not fail the floor. That list may only **shrink** — an entry
whose audit has gone green fails the floor as STALE, so a baseline cannot
outlive the work it was a baseline for.

## Two conventions every script here already follows

1. **The last line is the verdict, and it is the only line anybody reads.**
   Score with `lib\TestScore.ps1`: call `Complete-TestBody` at the end of the
   body and `Write-TestVerdict` after it, so a run that printed failure exits
   nonzero, a run that asserted nothing is not a pass, and a body that unwound
   early cannot print `ALL PASS`. Every script also takes `-NegativeControl`,
   which inverts one assertion — a green run is only evidence if the script can
   be made to go red.
2. **Only ever touch ghoztty processes that came from the `-Exe` path.** Reset
   shared state through `Reset-GhozttyTestState` (`lib\CleanSlate.ps1`) rather
   than a private kill, claim private endpoints with
   `Set-GhozttyTestIsolation` (`lib\Isolation.ps1`), and call
   `Assert-GhozttyIsolatedBuild` (`lib\BuildMode.ps1`) before launching
   anything. A release-lineage build derives the SAME app pipe, agent pipe and
   state directory as the user's installed Ghoztty, so a script that skips that
   pre-flight drives the terminal they are sitting in and passes while
   measuring a binary nobody here built.

## The rules, and how to declare an exception to one

Every rule below is enforced by a static sweep over this directory's source. A
script that genuinely cannot follow one says so in a comment — a **marker with a
reason**, which the analyzer reads and the reviewer can argue with. A bare
marker with no reason waives nothing.

| What the rule holds | Audit in `test\win32\` | Marker that declares an exception |
|---|---|---|
| A script exits the code its verdict implies (T197) | `harness-exitcode-audit.ps1` | `# exitcode-audit: <reason>` |
| A scorer cannot fall through without printing a verdict (T221) | `verdict-exit-audit.ps1` | `# verdict-audit: <reason>` |
| A run that proved nothing is not a pass (T271) | `asserted-nothing.ps1` | `# asserted-nothing-audit: <reason>` |
| A body that unwound early is not a pass (T1039) | `body-complete-audit.ps1` | `# body-audit: <reason>` |
| A skipped section is named in the verdict, never hidden by `ALL PASS` (T219) | `skip-visibility.ps1` | `# skip-audit: <reason>` |
| An assertion count is a real count, not a zero dressed as one (T617) | `count-or-zero.ps1` | — use `Get-CountOrZero` |
| A count is wrapped at the point of use, so a one-element return cannot make it vacuous (T794) | `unroll-count-audit.ps1` | `# count-audit: <reason>` |
| An env seam a script sets is classified, so the shipped unset state is armed, a named gap, or knowingly out of reach (T796) | `seam-audit.ps1` | — add the seam to `seam-audit.registry.json` |
| A script drives its own endpoints, never the user terminal's (T680) | `isolation-meta.ps1` | `# isolation: none\|shared - <reason>` |
| A run refuses a release-lineage build before it launches anything (T350) | `build-mode-guard.ps1` | — call `Assert-GhozttyIsolatedBuild` |
| No script launches the app without asking what build it is (T1033) | `launch-preflight-audit.ps1` | `# preflight: none - <reason>` |
| Shared state is cleared per script, so order cannot decide a verdict (T351) | `cleanslate-audit.ps1` | `# cleanslate-exempt: <reason>` |
| A launch states its session-persistence intent rather than inheriting one (T158) | `persistence-flag.ps1` | `# persistence: <what this launch wants>` |
| A capture's text does not depend on the host it ran under (T883) | `stderr-capture-audit.ps1` | `# capture-audit: <reason>` |
| Every launch keeps what the app said on its way out (T689) | `stderr-launch-capture.ps1` | `# stderr: <reason>` |
| A command a script depends on resolves, or the run says so (T586) | `command-resolve-audit.ps1` | `# resolve-audit: <reason>` |
| Free text reaches the CLI intact rather than shredded by PS 5.1 argv (T782) | `argv-hazard-audit.ps1` | `# argv-audit: <reason>` (line-scoped) |
| A GUI script launches on the test desktop, not the user's (T1193) | `desktop-launch-audit.ps1` | `# desktop-launch-audit: <reason>` |
| A script states what it does to the foreground window (T272/T276) | `foreground-audit.ps1` | `# foreground-audit: <reason>` |
| A win32 module's unit tests are actually executed by the lane (T1191) | `test-reach-audit.ps1` | — |
| A `*_NEUTERED` negative control has a live consumer, a shipped-value pin and a claim (T788) | `neuter-audit.ps1` | `// neuter-audit: <reason>` (Zig side) |
| Every painting window answers the screenshot path the tests read (T940) | `printclient-audit.ps1` | — listed in that script |
| A thread a test starts is joined, so a leak is not scored green | `thread-join-audit.ps1` | `// thread-join-audit: <reason>` (Zig side) |
| A job object a test creates is torn down with its processes (T1517) | `job-teardown.ps1` | — |
| A run measures the build it thinks it measures, not a stale one | `build-fresh-guard.ps1` | — |
| No script carries a control character that breaks it on another box | `control-char-scan.ps1` | — |
| A shared helper is anchored to the caller that is actually under test (T1079) | `caller-anchor.ps1` | — |
| No script writes `` `e `` for ESC — under 5.1 it is the letter e (T740) | `vt-escape-scan.ps1` | — use `[char]27`, or `lib\VtText.ps1` |

Each audit is also its own acceptance script: it self-tests its analyzer
against fixtures and proves its own teeth, so running one by hand answers a
single rule in seconds.

## Adding a script here

1. Write it against the two conventions above, and run
   `scripts\floor-lane.ps1 -Lane harness` before you commit — that is the whole
   of "does my script follow the house rules".
2. If it is behavior worth guarding standing, add a coverage row in
   `scripts\guard-due.ps1` naming the sources it covers, so the script goes DUE
   when they change rather than running when remembered.
3. If it is a new *harness* rule, add a row to `$HARNESS_FLOOR_AUDITS` in
   `scripts\lib\HarnessFloor.ps1` with one line saying what property it holds,
   document it in the table above, and keep it a static sweep — no GUI, no app
   launch, no `zig build`. That criterion is what lets the whole set run as one
   lane in minutes.

`test\win32\harness-floor.ps1` is the acceptance harness for the floor itself,
and its section F asserts that every audit in the set appears in the table
above — so a rule cannot be added to the floor and left undocumented here.
