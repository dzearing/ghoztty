# Windows parity — task tracker

**This is the resume doc for the Windows parity effort, and it holds only what
is live.** Tasks live one per file in `windows-parity-tasks/` (`T<id>.md`); the
frozen state table and Current priorities moved to
`windows-parity-tasks-history.md` (T1050), so a fresh turn no longer reads
1,500 lines of history to reach this part. Never add a row or a priorities list
back here.

## Resume protocol (fresh session starts here)

**ONE TASK PER CONTEXT, then reset.** (A session that chained tasks hit a
716k context on 2026-07-12. Everything needed to resume lives in git + the
task files.) See `go.md`, which is the authoritative turn.

1. Read `go.md` and this doc ONLY. Do NOT read the log/audit/spec docs
   wholesale — they are split out precisely to keep resume cheap.
2. Pick the task `scripts\parity-tasks.ps1 next -Claim` hands you. That is
   the whole selection rule (T345): priority, then milestone, then `order:`
   within the band, then id. Re-triage with `set-priority`, never by editing a
   list here.
3. Read ONLY your task's own file (`parity-tasks.ps1 show T<id>`). Before any
   IPC task, also read the "Architecture decisions (pinned)" section of
   `windows-parity-spec.md`.
4. Implement methodically. Small commits, pushed at once, through
   `scripts\git-commit-guard.ps1`.
5. Run the task's **Validation criteria**. Do not mark `done` on a clean
   build alone — validation must actually pass, on the box when it says so.
6. Update: `parity-tasks.ps1 set-status <id> -Status done -Commit <sha>`,
   evidence into the task file, and ONE short dated entry in
   `windows-parity-log.md` (a few lines; no build output, no diffs).
7. Push, then **reset context** (`/reset-context read go.md and go`) and end
   the turn. Do not start the next task in the same context.

Task sizing: if a task looks like it will exceed ~250k context, split it
(`parity-tasks.ps1 new` for the halves, the parent `skipped(split → …)`) and
commit the split. Keep tool output small — grep build logs for `error`, take
only the last line of acceptance scripts (they print ALL PASS / N FAILURE(S)
by design).

New tasks: `parity-tasks.ps1 new -Title "…"` (bugs found during validation
become tasks, not loose threads). Never delete a task — mark
`skipped(<reason>)` so decisions stay visible.

**THE BAR (user, 2026-07-28, verbatim):** *"we are not done until we have
achieved our overall goals with a 99.9% well validated confidence level that
we have parity in all the places we can with the mac version of ghoztty. that
means current state!"*

Three things follow, and they are not negotiable:

- **Current state, not the state we forked from.** Parity is measured against
  Mac Ghoztty *as it is today*, so upstream merges (T88, T117) are part of the
  job, not a distraction from it — and every merge must be followed by a gap
  audit that files rows (that is what produced T89a–T94 and T118–T128).
- **99.9% confidence means validated, not believed.** A row goes `done` only
  with evidence that was actually run on the box. "It compiles", "it looks
  right", and "the code is obviously correct" are not evidence. When a harness
  and the product disagree, prove which one is lying (T113's four failures were
  the harness; T111b's two prime suspects were both refuted by instrumentation).
- **"In all the places we can"** — where a Mac concept has no Windows analog,
  build the native equivalent and record the divergence in the row, so the gap
  is a decision on the record rather than an omission.

**THE BAR, RESTATED AND SHARPENED (user, 2026-07-31, verbatim):** *"Your idea
of parity is not the same as mine. I mean, pixel parity, the UX looks and feels
cohesive and polished and scrubbed, and it isn't just buttons that exist in the
same place, but it looks like a posh win32 version of the MacOS app. The borders
look nice. There's a master details view. There are ways to get to the activity
viewer. If you haven't even built the activity monitor, then you don't have
parity with the dialogue in the MacOS app."*

This is a **correction**, and it retires the reading that had been in force:

- **A control that exists in the same place is not parity.** T172/T175/T176
  shipped the chooser's rows, master-detail and row menu and the tracker read
  that as the chooser being done. It is not done: the Activity Monitor behind
  its detail row was never built (T226), its button was never filed until
  T177, and nothing has been judged for finish.
- **Pixel parity and polish are part of the deliverable, not a follow-up.**
  Borders, seams, selection states, type ramp, DPI. Measure the target the way
  T202 did (`win32-tab-strip.md`) rather than eyeballing it.
- **"Posh win32 version of the macOS app"** is the phrase to design to — a
  Windows-native execution held to the Mac original's level of finish, not a
  cloned macOS dialog and not a functional stand-in.
- **A missing panel is a missing feature, even when its host dialog looks
  right.** Before calling any surface parity-complete, ask what every control
  on the Mac side OPENS, and whether that thing exists here.

**THE GOAL (user, 2026-07-15, verbatim intent):** Windows Ghoztty at full
parity with Mac Ghoztty, *very reliable and usable for long contexts*.
Thoroughly test it, optimize, fine-tune, make the Windows things look
Windows-native. Not slow, not crashing — well tuned and well tested.
The user is stepping away: do NOT stop to ask clarifying questions; audit
your own trail; use adversarial investigation for hard problems and
recommended approaches where they exist.

## History

The frozen **Current priorities** (2026-08-21, T345) and the frozen **state
table** (2026-07-29) are in `windows-parity-tasks-history.md`. Read them only
for the backstory of a specific old task; they decide nothing.

## Key code landmarks

- `src/apprt/win32/` IPC (as of 2026-07-12): IpcServer.zig (pipe
  transport), IpcHandlers.zig (verbs), IpcRegistry.zig (named targets),
  ProcessTree.zig (`--pid` ancestry); pure logic in `src/apprt/ipc/`
  (args.zig, list.zig — unit tested in both lanes). No action stubs remain
  (T19 landed the last one). `startUpdateCheck` still hard-disabled (T24).
- `src/apprt/none.zig` `sendIpc` — Mac client wire protocol (4-byte BE length
  + JSON), reuse `src/apprt/ipc.zig` `parseResponse`.
- `macos/Sources/Features/IPC/IPCServer.swift` — reference server semantics
  (registry, idempotency, send-keys notation, list format, rearrange).
- `macos/Sources/Features/Terminal/BaseTerminalController.swift` — activity
  title suffix + titleOverride precedence.
- `src/remote/` — shared Zig remote core (ws_client, relay_dial, client_mux,
  ssh_transport); termio `.remote` backend. Swift supplies only UI + creds.
- `src/config/Config.zig` ~line 6880 — the Windows ctrl-mirror keybind block.
- Windows keyboard path: `src/apprt/win32/Surface.zig` `handleKeyEvent`.

## Related docs (read only the slice you need)

- `windows-parity-tasks/` — one file per task; the task file wins over
  anything else. `parity-tasks.ps1 show T<id>` reads one.
- `windows-parity-tasks-history.md` — the frozen state table and Current
  priorities (T1050). History only.
- `windows-parity-details.md` — FROZEN 2026-07-29: its per-task sections
  were copied into the task files. Still holds "Bootstrap & environment"
  for a fresh box.
- `windows-parity-log.md` — dated session log, newest first. Open a single
  entry only when you need the backstory for your current task. Append ONE
  short entry at every task boundary.
- `windows-parity-audit.md` — the 2026-07-12 three-way audit findings.
- `windows-parity-divergence.md` — the mechanical divergence inventory vs
  upstream ghostty (T516): fork point, the changed-both merge risk set with
  per-file commit counts, and the two single-side lists. Regenerate with
  `scripts\divergence-inventory.ps1` before any upstream-pull planning; do not
  hand-edit it.
- `windows-parity-spec.md` — architecture decisions (pinned). Read its
  "Architecture decisions" section before implementing any IPC task.
