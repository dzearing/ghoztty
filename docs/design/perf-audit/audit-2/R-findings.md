# Audit-2, area R: renderer and GPU (T3072)

- **Date:** 2026-11-14
- **Commit audited:** 879fba35a (HEAD of `users/dzearing/windows-amd64`)
- **Input:** `../audit-1/R-findings.md` (PA-R01..PA-R17, lines as of 4c8a7cd4f)
  and the R table in `../audit-1.md`

**Produced by Fable 5.2** (`claude-fable-5-2`), one re-auditor, read-only.

**Method.** Every verdict below comes from reading the cited code at HEAD and,
for the seven closed tasks, the source diff of the fix commit
(`git show <sha> -- src/`). Nothing was built, run or measured in this pass,
so every cost below is either quoted from a task/commit message (marked
*quoted*) or computed from the code (marked *computed*). Confidence is given
per row: **high** = read the whole path, **medium** = read the cited lines and
their callers but a runtime fact (driver, DWM) decides the size.

## Verdict table

| PA | Verdict | HEAD where | Evidence | Task action |
|---|---|---|---|---|
| R01 | **fixed** (high) | `renderer/generic.zig:70-81`, call at `:1417` | 8d2be0f7b. `terminalStateRecycleDue` zeroes the counter when it fires, then counts the frame; the unit test at `:83-105` expects 3 teardowns in 300,017 frames. | T2967 stays closed. Mac half T2984. |
| R02 | **fixed**, residual tracked (high for code, medium for driver behavior) | `renderer/gl_comp_present.zig:393-443` (`DeviceCache`), `:637-640` (acquire), `:676` and `:971-973` (waitable chain) | 29302f08c. One multithread-protected D3D11 device per process; each pane still opens it with its own `wglDXOpenDeviceNV` (`:775`). The DComp device is still one per pane (`:754`), and `child_comp.zig:211`, `chrome_comp.zig:643` still create their own D3D11 device: both are T3074. | T2968 stays closed. No new task; T3074 carries the rest. |
| R03 | **still open** (high) | `renderer/OpenGL.zig:482-488` (own context made current), `opengl/shaders.zig:116-119` (programs per pane), `generic.zig:477-490` (atlas textures per frame state) | No share group on the default path. Its dependency (R02) is now met. R07's fix removed the upload half of the cost, so what is left is memory only. | T2969: drop the "depends on PA-R02" blocker; restate the gain as memory only (atlas copy + programs per pane). Stays P2. |
| R04 | **fixed** (high) | `renderer/cursor.zig:77-87` (`blinkMatters`), `generic.zig:1714-1719` (hash), `Thread.zig:989-992` (timer stops), `:836` and `:948-960` (restart) | 2cdc77abe. The phase is hashed only when it can change pixels; the timer disarms itself and `renderCallback` restarts it. Focus gain still arms it (`Thread.zig:485-497`), then it disarms on its first tick if the cursor is steady. | T2970 stays closed. Mac half T2984. |
| R05 | **fixed** (high) | `renderer/link.zig:63-75` (`canHighlight`), `:96` (early return), `generic.zig:1606` | 5672c7165. `renderCellMap` returns before building the string; the default link is `hover_mods` (`config/Config.zig:4106`), so it is skipped unless Ctrl is held over the pane. | T2971 stays closed. Mac half T2984. |
| R06 | **fixed** for uploads; grow-only part remains (high) | `renderer/opengl/buffer.zig:83-100`, `:124-128`, `:159-166`; `renderer/upload_diff.zig:59-86`, `:131-138` | 60ae989a0. Each sync diffs against a CPU shadow in 512-byte blocks and issues one `glBufferSubData` for the changed range. Row layout unchanged. The buffer still only grows (`buffer.zig:114-121`, `:144-151`), and the shadow now doubles that on the CPU: see PA-R19. | T2972 stays closed. New P2 for the grow-only half (PA-R19). |
| R07 | **fixed** for uploads; shrink half split out (high) | `font/Atlas.zig:348-351` (`markModified`), `:358-383` (`dirtyRowsSince`), `generic.zig:2072-2074`, `:2081-2083`, `:3961-3991` | 396aac1db. Only the dirty row band is uploaded; never-synced (`since == 0`), a gap over 32 entries, `grow` and `clear` fall back to a full upload. `setFontGrid` zeroes the per-frame counters (`generic.zig:1345-1346`) and a rebuilt swap chain starts at 0, so no stale band can be applied to a new texture. "Never shrinks" is T3090. | T2973 stays closed. T3090 carries the memory half. |
| R08 | **fixed**, one small hole (high) | `renderer/storage_trim.zig:84-131`, `OpenGL.zig:1309-1312`, `:1356-1382`, `opengl/Target.zig:95-99`, `gl_comp_present.zig:954-958`, `:974-982`, `Thread.zig:593`, `:601-622`, `generic.zig:2019-2031` | 6711c4e45. One second after the size settles a forced frame rebuilds the target, the shared texture and the swap chain at a fresh allocation's buckets. Hole: a trim attempt can be spent on a re-present frame that cannot rebuild the target (PA-R18). | T2974 stays closed. New P2 (PA-R18). |
| R09 | **still open**, smaller (high) | `OpenGL.zig:1587-1591`, `generic.zig:1297-1330` (only `frame.resize(1,1)`), `Window.zig:4785-4790` | A tab switch still only calls `setVisible(false)` + `SW_HIDE`; the window-hide release still frees only the GL target, not the shared texture or the swap chain. With R08 a background pane now holds storage at its current size's buckets, not its high-water size. | T2975: re-state the per-pane cost as "current bucketed size" (R08 removed the high-water case). Stays P1. |
| R10 | **changed**: must be re-measured (medium) | `gl_comp_present.zig:443` (cache never dropped), `pane_pool.zig:28`, `Surface.zig:1541-1557` | The 107.4 vs 57.6 MB plateau was measured with one device per pane. Now one device is kept for the life of the process by design, 10-pane dedicated GPU is 226.9 MB (*quoted*, T2968 log), and R08 trims surfaces. A parked pane window on the default path carries no GL drawable and its DComp target is released in `releaseCom` (`gl_comp_present.zig:1104-1118`), so the pool is an unlikely carrier (inferred, not measured). | T2976: re-run `perf-baseline.ps1 -Phase cycle` first; rewrite the numbers and the suspect list (drop "per-pane device", add "the cached shared device is expected to stay"). Likely demote to P2 if the plateau is under ~20 MB. |
| R11 | **changed**: narrower than filed (high) | `generic.zig:1945-1964`, `OpenGL.zig:1605-1613`, `gl_comp_present.zig:1040-1056` | The re-present costs what audit-1 said (blit, copy, `Present(1,0)`), but on Windows it is not reached "twice a second per pane". `rebuildCells` runs on every `updateFrame` that gets past its two holds (`generic.zig:1769`, sets `cells_rebuilt` at `:3201`), so a forced or safety-bound present of an unchanged frame is a full draw, not a re-present. `presentLastTarget` is reached only when `updateFrame` returned early (synchronized output `:1479-1485`, prompt-redraw hold `:1491-1509`); `draw_now` is notified only by the macOS display link (`:1196-1204`). See the section below. | T2977: retitle. The real twice-a-second cost is a full draw of an unchanged frame under the 500 ms bound; the fix is to make `needs_redraw` false for it (skip, or re-present nothing), not to trim the re-present path. Stays P2. |
| R12 | **still open** (high) | `renderer/cell.zig:118-122` | Unchanged. | T2978 unchanged. |
| R13 | **still open** (high) | `generic.zig:2391` and `:2353` (two copies), `image.zig:906` (new texture), `generic.zig:2401` (`markDirty`) | Unchanged. T2968's log quotes the stack glide tick mean improving 12.8 -> 10.1 ms with the shared device, still over the 8.3 ms period. | T2979: update the measured context to 10.1 ms. |
| R14 | **still open** (high) | `opengl/Pipeline.zig:50-56` vs `:72-74` | Unchanged: `deinit` destroys only the program. | T2980 unchanged. |
| R15 | **still open** (high) | `apprt/win32/Surface.zig:1751-1752` | Unchanged. On the default path the format lands on the hidden helper window (`Surface.zig:1640-1653`), so the cost is still only on the SwapBuffers fallback (`adoptPaneDrawable`, `:1662-1679`). | T2981 unchanged. |
| R16 | **still open** (high) | `Window.zig:22388-22389`, `:8002` | Unchanged: `refreshOcclusion` on every `SIZE_RESTORED`; `heroSnapTick` checks only `IsIconic`. | T2982 unchanged. |
| R17 | **still open** (high) | `apprt/win32/Surface.zig:1019` | Unchanged, and not affected by R02. The guard `adoptPaneDrawable` already uses (`GetPixelFormat(dc) == 0`, `:1667`) is the fix. | T2983 unchanged. |

## Items whose shape changed

### PA-R02: fixed, with three things worth knowing

Read in full: `gl_comp_present.zig:344-443` and `Presenter.init` `:620-809`.

- **What is shared.** The D3D11 device and its immediate context only.
  `ID3D10Multithread::SetMultithreadProtected(1)` is set before the device is
  cached (`:413-418`); a device that cannot be protected is handed to its one
  caller unshared (`:414-416`). Reference counting is balanced: the cache keeps
  one reference, each `acquire` adds one for the caller (`:405-406`,
  `:422-423`), and `releaseCom` drops the caller's (`:1124-1125`). The
  pre-existing double release on a failed `createShared` was removed
  (`:795-802`).
- **What is not shared.** `DCompositionCreateDevice` still runs once per pane
  (`:754`), and the chrome and child hosts still create their own D3D11
  devices. Both are already filed as T3074, so no new task.
- **The frame-latency wait.** Chains on the shared device are created
  waitable (`:676`) and `begin` waits up to 100 ms for the chain before each
  frame (`:971-973`), so `Present` does not block while holding the device
  lock. Code is correct as read: the token survives a dropped frame (`:592`,
  `:1055`), the handle is closed on every exit path (`:713-715`, `:1122`), and
  `ResizeBuffers` passes the creation flags (`:849`, `:871`).
  Not verified, because it needs a running box: whether DWM withholds the
  signal for a pane that is drawing but not being composed. If it does, that
  pane draws at 10 fps with `draw_mutex` held for 100 ms a frame. Hidden,
  covered and minimized windows do not draw at all (`Thread.zig:818-821`), so
  the exposure is small. Suggested cheap check, not a task: count timeouts and
  log once.
- **Device removal is now process-wide** (it effectively was before: a GPU
  reset removes every device on the adapter). `acquire` refuses a removed
  device (`:402-410`); panes on the old one fail their next present and drop
  to SwapBuffers as before (`OpenGL.zig:1560-1572`).

### PA-R08: fixed; how the trim works at HEAD

- `surfaceSize` notes the size and asks `takeTrim` (`OpenGL.zig:1309-1312`):
  true once the size is 1 s old, something was oversized after the last
  present, and fewer than 3 attempts were spent since the size last moved.
- `noteStorage` (`OpenGL.zig:1370-1382`, deferred from `present`) records
  whether the target, the presenter or a slot is still oversized.
- `Thread.armStorageTrim` (`Thread.zig:601-606`) arms one timer after each
  frame; its callback forces a frame through `wakeup` (`:608-622`).
- That forced frame normally rebuilds cells (`generic.zig:1769`), so
  `needs_redraw` is true, `storageTrimDue` makes `frame.resize` run instead of
  `resizeInPlace` (`generic.zig:2019-2037`), and `Presenter.begin` shrinks
  the shared texture and swap chain (`gl_comp_present.zig:974-982`).
- Per-frame cost added: one `Instant.now()` in `surfaceSize`, one in
  `storageTrimInMs`, and a 2-entry loop. Negligible.

### PA-R10: the baseline it was measured against is gone

Do not work T2976 from its current text. Three of its inputs changed:
per-pane devices no longer exist, the shared device is deliberately never
released, and surfaces now trim. Re-measure, then decide whether a task is
still warranted.

### PA-R11: what really happens to an unchanged frame

Audit-1 described the wakeup path as reaching `presentLastTarget`. At HEAD
(and, since this code did not change, at audit-1) it does not:

1. `renderCallback` calls `updateFrame`, which calls `rebuildCells`
   unconditionally once past the synchronized-output and prompt-redraw holds
   (`generic.zig:1769`). `rebuildCells` always ends with
   `cells_rebuilt = true` (`:3201`).
2. `shouldPresent` lets an unchanged frame through only when forced or when
   the last present is 500 ms old (`Thread.zig:884-907`).
3. `drawFrame` then sees `cells_rebuilt` and takes the full path
   (`generic.zig:1945-1965`): target bind, buffer syncs (now diffed, so no
   upload), all draw calls, `gl.finish`, blit, copy, `Present`.

So a pane receiving output that changes no cell (title churn, bells) does a
full GL draw every 500 ms, and the cheap re-present path is essentially dead
on Windows. The audit-1 measurement (1.0-1.6% GPU on a 4090) still bounds
the size. T2977 should target step 3: do not draw, or do not present, a frame
whose key did not change.

## New findings

### PA-R18: a storage-trim attempt is spent on frames that cannot trim the target (P2)

- **Where:** `OpenGL.zig:1312` (attempt spent in `surfaceSize`),
  `generic.zig:1958-1964` (`presentLastTarget` path returns before
  `storageTrimDue` at `:2019`), `storage_trim.zig:114-119` and `:27`
  (`max_attempts = 3`), `Thread.zig:601-606` (re-arm with a 1 ms wait once
  settled).
- **Mechanism:** `takeTrim` runs at the top of every `drawFrame`. If that
  frame takes the `!needs_redraw` path, `present(last_target)` shrinks the
  presenter (`OpenGL.zig:1505`) but nothing rebuilds the GL render target, so
  `noteStorage` reports it still oversized, the timer re-arms for 1 ms, and
  the next two attempts go the same way. After 3, `takeTrim` returns false
  for good, including on later real redraws, until the pane's size changes.
  The trigger is a settle frame whose `updateFrame` returned early: the
  program is holding synchronized output (`generic.zig:1479-1485`) or a
  prompt-redraw hold is active (`:1491-1509`).
- **Cost (computed):** the render target stays at its high-water size:
  4 bytes per pixel, about 33 MB for a pane once maximized on 4K, per affected
  pane, until it is next resized. Three wasted presents within about 3 ms.
  Rare trigger; introduced by 6711c4e45.
- **Fix:** do not spend an attempt on a frame that will not redraw: either
  add `storageTrimDue` to `needs_redraw`, or give the attempt back in
  `noteStorage` when the frame was a re-present.
- **Risk:** low.

### PA-R19: cell buffers and their new CPU shadows only grow (P2)

- **Where:** `renderer/opengl/buffer.zig:114-121` and `:144-151` (the store is
  reallocated at twice the need and never smaller), `:83-90` (the shadow is
  the store's full capacity, from `page_allocator`), `upload_diff.zig:46-54`.
- **Mechanism:** audit-1 noted the grow-only buffer under R06; the R06 fix
  left it and added a CPU mirror of the same capacity. Neither shrinks when
  the grid does, and `storage_trim` (R08) does not cover them.
- **Cost (computed, `CellText` is 32 bytes, `shaders.zig:234-245`):**
  - at 160x45: up to 460 KB GPU + 460 KB committed CPU for text, 58 KB + 58 KB
    for backgrounds, per pane
  - after one maximize on 4K (about 480x120 cells): up to 3.7 MB GPU + 3.7 MB
    CPU for text, per pane, for the life of the pane
  - the CPU half is new with 60ae989a0
- **Fix:** on a storage-trim frame, reallocate a buffer (and reset its shadow)
  whose capacity is more than, say, 4x the frame's need.
- **Risk:** low.

## Regressions from the seven fix commits

- **6711c4e45 (T2974):** PA-R18 above. No other defect found.
- **60ae989a0 (T2972):** PA-R19's CPU half (memory, not a per-frame cost).
  The diff logic itself read correct: bytes past `valid` are always uploaded,
  a failed upload zeroes `valid`, and a reallocated store resets the shadow.
- **29302f08c (T2968):** none found by reading. One unverified runtime
  question (the 100 ms latency wait) is recorded under PA-R02.
- **8d2be0f7b, 2cdc77abe, 5672c7165, 396aac1db:** none found.

## Checked and found clean

| Checked | Result |
|---|---|
| `Shadow.write` / `take` range math (`upload_diff.zig:59-138`) | Correct for the only caller shape (lists laid back to back from offset 0). A gap between `valid` and a later write cannot occur. |
| A buffer made by `initFill` being diffed with the wrong capacity | `initFill` sets `len` in bytes (`buffer.zig:73`), which would over-size a shadow, but its only caller (`image.zig:145`) never calls `sync`. |
| Atlas dirty log vs writers that bypass it | Every write to `Atlas.data` goes through `set`, `setFromLarger`, `grow` or `clear`, all of which call `markModified` (`Atlas.zig:313`, `:344`, `:439`, `:445`). |
| Atlas band applied to the wrong texture after a font change or a device loss | `setFontGrid` zeroes the counters; a rebuilt swap chain starts at 0; a recreated texture gets a full upload (`generic.zig:3971-3978`). |
| Blink timer never restarting | `renderCallback` restarts it after any frame that finds a blinking cursor (`Thread.zig:836`); `reset_cursor_blink` only resets a running timer (`:502-514`), which is right. |
| Trim rebuild mid-drag | `Settle.note` restarts the clock on any size change (`storage_trim.zig:94-100`). |
| Trim for a hidden pane | The forced frame is dropped while invisible (`Thread.zig:818-821`) and the next visible frame trims. |
| Shared device reference counts and error paths | Balanced (see PA-R02). |
| New per-frame work from the fixes | One 512-byte-block compare of the cell buffers, two `Instant.now()` calls, one `WaitForSingleObject` that returns at once when the chain is ready. Nothing proportional to pane count. |
| `link.canHighlight` vs the old inline predicate | Same four cases; the seam pass now calls it (`generic.zig:1606`). |

## Not covered

- No measurement was taken. R10 and the 100 ms wait need a box.
- The window presenter path (`WindowPresenter.zig`, opt-in) and the pane tree
  path (`GHOZTTY_COMP_PANE_TREE`, opt-in) were read only where the fix
  commits touched them.
- The Mac halves (T2984) were not checked.
