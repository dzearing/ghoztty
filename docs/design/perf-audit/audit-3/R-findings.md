# Audit-3, area R: renderer and GPU (T3101)

- **Date:** 2026-11-15
- **Commit audited:** d0d874326 (audit-2 was 879fba35a)
- **Input:** audit-3, a re-audit of `../audit-2/R-findings.md` (PA-R01..PA-R19),
  with `../audit-1/R-findings.md` for the original descriptions

**Produced by Fable 5.2** (`claude-fable-5-2`), one read-only auditor.

**Method.** Every verdict comes from reading the cited code at HEAD and, for
each task closed since audit-2, the source diff of its fix commit. Nothing was
built, run or measured. A cost is marked *quoted* (from a task or commit
message), *computed* (from the code) or *inferred* (mechanism read, size not
known). Confidence per row: **high** = cited lines read at HEAD and the
mechanism traced; **medium** = lines read, but a runtime fact (driver, DWM,
thread timing) decides the size.

## What moved since audit-2

`git diff --stat 879fba35a HEAD` over the area:

| File | Change |
|---|---|
| `src/renderer/generic.zig` | +287/-35: idle frame release, `visible` flag, `FrameMemory`, atlas release |
| `src/renderer/Thread.zig` | +81: `idle_h` timer and `idle_arm` async |
| `src/renderer/OpenGL.zig` | +64: `releaseIdleTargetsNow`, the knob, `releaseShared` call |
| `src/renderer/gl_comp_present.zig` | +10: `Presenter.releaseShared` |
| `src/renderer/Metal.zig`, `metal/*` | Mac half of the idle release (not audited) |
| `src/apprt/win32/Surface.zig` | +56: `window_hidden` doc, snapshot release (T3001) |
| `src/apprt/win32/Window.zig`, `PaneView.zig` | tab switch, zoom and stash now mark panes `window_hidden` |

`src/renderer/opengl/*`, `cell.zig`, `image.zig`, `link.zig`, `cursor.zig`,
`storage_trim.zig`, `upload_diff.zig`, `font/Atlas.zig` and
`apprt/win32/pane_pool.zig` did not change, so their line numbers are
audit-2's.

Commits and tasks:

| Commit | Task | What |
|---|---|---|
| 19581323a | T2975 (PA-R09) | background-tab panes release targets; every hidden release frees the shared staging texture |
| ef6aee174 | T2976 (PA-R10) | measurement only, no renderer source: the residue is the GL driver's reuse pool; T3110 filed |
| 6dc6ecb90 | T3102 | merge from main: brings Mac's 8b0de569b (idle release, generic half) and 6bd6fe7fb (hidden surface draws nothing) |
| ad014989d | T3103 | OpenGL opts in to the idle release: 3 s without a draw frees the target, the atlas copies and the shared texture |
| ae9b1adb2 | T3104 | zoom-covered and stashed panes take the hidden release |
| 40297c800 | T3001 | pane snapshot buffer and DIB are freed when no longer needed |

## Verdicts

| PA | Verdict | HEAD where | Evidence | Task action |
|---|---|---|---|---|
| R01 | **fixed** (high) | `renderer/generic.zig:76-81`, call at `:1634` | 8d2be0f7b. Unchanged since audit-2; only the call site line moved. | T2967 stays closed. |
| R02 | **fixed**, residual tracked (high for code) | `renderer/gl_comp_present.zig:393-443`, `:754` (DComp device per pane); `apprt/win32/child_comp.zig:211`, `chrome_comp.zig:686` | 29302f08c. Unchanged. The per-pane DComp device and the two extra D3D11 devices are still there. | T2968 stays closed. T3074 still open and still accurate (re-cite `chrome_comp.zig:686`). |
| R03 | **still open**, and now carries a time cost (high) | `renderer/OpenGL.zig:482-488`, `opengl/shaders.zig:116-119`, `generic.zig:499-512` (atlas textures per frame state), `:580-601` (`releaseAtlases`) | No share group. New since audit-2: the per-pane atlas copies are freed after 3 s idle and re-uploaded in full on the next frame (PA-R20). A shared atlas would remove both the memory and the re-upload. | T2969: add "removes PA-R20's atlas re-upload" to the gain. Stays P2 unless PA-R20 measures large. |
| R04 | **fixed** (high) | `renderer/cursor.zig:77-87`, `generic.zig:1927-1936`, `Thread.zig:860`, `:1068` | 2cdc77abe. Unchanged. | T2970 stays closed. |
| R05 | **fixed** (high) | `renderer/link.zig:63-75`, `:96`; `generic.zig:1823` | 5672c7165. Unchanged. | T2971 stays closed. |
| R06 | **fixed** for uploads (high) | `renderer/opengl/buffer.zig:83-100`, `:124-128`, `:159-166` | 60ae989a0. Unchanged. Grow-only half is PA-R19. | T2972 stays closed. |
| R07 | **fixed** for steady state; **changed** for a pane that goes idle (high) | `generic.zig:2303-2321`, `:4198-4228`, `:580-601` | 396aac1db still uploads only the dirty band. But `releaseAtlases` now zeroes `grayscale_modified`/`color_modified` and shrinks the texture to 1x1, so the first frame after any 3 s pause takes the `atlas.size > texture.width` branch (`:4204-4210`): a new texture and a whole-atlas upload, per pane. See PA-R20. | T2973 stays closed. T3090 unchanged. |
| R08 | **fixed**; the hole is smaller (high) | `renderer/OpenGL.zig:1309-1312`, `:1356-1382`; `gl_comp_present.zig:984-992`; `Thread.zig:617`, `:625-645`; `generic.zig:2252-2279` | 6711c4e45. Trim code unchanged. The idle and hidden releases now rebuild the target and the shared texture at fresh buckets on their own, so only the swap chain still depends on the trim. | T2974 stays closed. |
| R09 | **fixed (incomplete)**, remainder tracked (high) | `apprt/win32/Window.zig:4486-4496`, `:4848-4858` (tab switch sets `window_hidden`); `OpenGL.zig:1589-1593`, `:1646-1658`; `gl_comp_present.zig:938-943`; `generic.zig:1478-1546` | 19581323a. A tab going behind marks each pane `window_hidden` before `setVisible(false)`, so `releaseHiddenTargetsNow` is true and the renderer frees the GL target, both atlas copies (since ad014989d) and the shared staging texture, then `gl.finish()`. Not freed: the composition swap chain (kept on purpose so a reveal is not blank) and the window-presenter slot textures. The released "1x1" target is really 256x256 (PA-R21). | T2975 stays closed. T3091 (swap chain) and T3092 (slots) carry the rest. |
| R10 | **changed**: closed as not ours (medium: a measurement, not re-run) | no renderer source changed; `docs/design/windows-parity-tasks/T2976.md` | ef6aee174. Nine cycle runs: the +49.7 MB survives `GHOZTTY_PANE_REUSE=0`, tree mode, a D3D flush+Trim and `GHOZTTY_COMP_PRESENT=0`, scales with peak pane count (5.5 MB each) and adds 0 on the second cycle (*quoted*). The "driver reuse pool" reading fits. One thing to carry forward: T3103 measured dedicated memory *falling* 109 -> 95 MB when four panes freed their renderbuffers and atlas textures (*quoted*), so the driver does return that kind of storage while a context lives. The residue is therefore more likely per-context driver state than pooled texture storage (*inferred*), which points T3110 at the context count (PA-R03) rather than at atlas or buffer sizes. | T2976 stays closed. T3110: add this note, and re-measure with the idle release on (the A/B predates ad014989d). |
| R11 | **changed**: same finding, one new cost (high) | `generic.zig:1986` (`rebuildCells` unconditional), `:3438` (`cells_rebuilt = true`), `:2170-2191`; `Thread.zig:903-930`; `OpenGL.zig:1661-1669`; `gl_comp_present.zig:1053-1066` | Audit-2's reading holds: an unchanged frame let through by the 500 ms bound is a full GL draw, and the re-present path is reached only from the two early returns of `updateFrame` (`:1696-1701`, `:1708-1726`). New: if such frames arrive more than 3 s apart, each one also re-creates the target, the shared texture and both atlas textures (PA-R20). T3103 records this as a known cost. | T2977: the fix (do not draw or present a frame whose key did not change) now also stops the release/re-create cycle; say so. Stays P2. |
| R12 | **still open** (high) | `renderer/cell.zig:118-122` | Unchanged. | T2978 unchanged. |
| R13 | **still open** (high) | `generic.zig:2630` and `:2590` (two copies), `image.zig:906` (new texture), `generic.zig:2638` (`markDirty`) | Unchanged apart from line numbers. | T2979: re-cite lines. |
| R14 | **still open** (high) | `renderer/opengl/Pipeline.zig:50-56` vs `:72-74` | Unchanged. | T2980 unchanged. |
| R15 | **still open** (high) | `apprt/win32/Surface.zig:1754-1755`; helper `:1643-1658`; fallback `:1665-1682` | Unchanged apart from line numbers. | T2981: re-cite lines. |
| R16 | **changed**: larger for a window with a zoomed or stashed pane (high for the mechanism, medium for the size) | `apprt/win32/Window.zig:22652-22653`, `:4814-4820` (`refreshOcclusion`), `:4771-4778` (`setActiveTabVisible`), `:8066-8073` (`heroSnapTick`) | Both original halves are unchanged. New: see "Changed items". Every size step re-shows the panes T3104 just released. | T2982: add the zoom/stash case; fix `refreshOcclusion` to act only on an occlusion transition. Stays P2. |
| R17 | **still open** (high) | `apprt/win32/Surface.zig:1022` | Unchanged apart from the line number. | T2983: re-cite line. |
| R18 | **changed**: smaller (high) | `OpenGL.zig:1312`; `generic.zig:2185-2191` (returns before `storageTrimDue` at `:2256`); `storage_trim.zig:114-119`, `:27`; `generic.zig:1419-1436` | The three attempts can still be spent on re-present frames. But the oversized target no longer lasts "until the pane is next resized": 3 s after the pane's last real draw the idle release frees it and the next frame makes a fresh one. It persists only for a pane that keeps drawing. M13's other half (a pane behind a tab never trims) is also reduced: the hidden release frees the target and shared texture, leaving the swap chain (T3091). | T3096: restate as "swap chain only, plus the target of a pane that never goes 3 s without drawing". Stays P2. |
| R19 | **still open** (high) | `renderer/opengl/buffer.zig:114-121`, `:144-151`, `:83-90` | Unchanged. The idle release does not touch cell buffers or their shadows (`generic.zig:1517-1533` frees atlases and targets only). | T3098: note the idle release (`releaseFrameResources`) as a natural place to drop them. |

## Changed items

### PA-R09: what a background tab holds at HEAD

Per pane behind a tab, read from the release path:

- freed: GL render target, both atlas copies, shared staging texture
- kept: composition swap chain at its current buckets (T3091), a 256x256
  placeholder target (PA-R21), cell buffers and shadows (PA-R19), programs
  and the GL context (PA-R03), the per-pane DComp device (T3074)

The same list applies to a minimized or covered window, a zoom-covered pane
and a stashed pane (T3104), and, without the "hidden" conditions, to any
visible pane 3 s after its last draw (T3103).

### PA-R10: closed as a driver pool; one inference to keep

See the table row. The task's own evidence is consistent. The only addition
is that the T3103 number shows this driver returning freed renderbuffer and
texture storage, which narrows what the 5.5 MB per peak pane can be.

### PA-R11: an unchanged frame after 3 s now re-creates storage

Sequence for a pane whose program emits output that changes no cell (a
title, a bell) less often than every 3 s:

1. `idleCallback` (`Thread.zig:1015-1039`) releases the frames.
2. The next wakeup builds an unchanged frame; `presentDecision` lets it
   through because the last present is over 500 ms old (`Thread.zig:925-929`).
3. `drawFrame` sees `redraw_after_release` (`generic.zig:2174`) and does the
   full draw, now with a new target, a new shared texture and two full atlas
   uploads.
4. 3 s later it is released again.

Bounded (one cycle per wakeup), and T3103 measured a title flood as fine,
but a flood is the case that never goes idle. The sparse case is unmeasured.

### PA-R16: every size step re-shows panes that T3104 released

- `WM_SIZE` with `SIZE_RESTORED` or `SIZE_MAXIMIZED` calls `refreshOcclusion`
  (`Window.zig:22652-22653`), on every step of an edge drag and every
  programmatic resize.
- When the window is visible, `refreshOcclusion` ends in
  `setActiveTabVisible(true)` (`:4819`), which walks every pane of the active
  tab, clears `window_hidden` and calls `setVisible(true)` (`:4774-4777`).
  That includes a pane behind a zoom and a stashed pane.
- `handleResize` then lays out (`:20100-20101`) and the zoom and stash
  branches call `hideReleasing` again (`:8268`, `:8856`, `:13391`).

So per size step, each such pane gets two visibility messages and two
renderer wakeups, each forcing a frame (`Thread.zig:436`). If the renderer
thread drains between them it draws: since T3104 that draw first re-creates
the target, the shared texture and the atlas copies, and the hide that follows
frees them again. Before T3104 the same flip cost a draw but no allocation.
Whether the drain lands in the gap is thread timing (*inferred*); the layout
pass in between waits on other panes' frames, so the gap is not short. Not
traced: whether a pre-laid step (`finishPrelaidSize`, `:20100`) re-hides the
panes at all before the next layout.

Fix: `refreshOcclusion` should do nothing when the window was not occluded
and is not occluded now. That is the same change PA-R16 already asks for.

### PA-R18: bounded by the idle release

See the table row. No code change in the trim; the bound comes from
`releaseIdleFrames`.

## Fix-commit review

- **19581323a (T2975):** correct as read. `releaseShared`
  (`gl_comp_present.zig:938-943`) unlocks, unregisters and releases in the
  right order and `begin` rebuilds on `texture == null` (`:985-992`) at fresh
  buckets. `width`/`height` are left stale but `begin` does not trust them
  when the texture is null. No leak found on the error paths of
  `createShared` (`:882-931`, every step has an `errdefer`). No new cost.
- **ad014989d (T3103) with 8b0de569b from the merge:** PA-R20 (first frame
  after a pause) and PA-R21 (placeholder size). The bookkeeping itself is
  sound: `frames_released`, `last_draw_time`, `visible` and `idle_arm` are
  all read and written under `draw_mutex`; the timer is armed only on the
  released-to-drawing transition (`generic.zig:2197-2202`) and re-arms itself
  with the remaining time, so a pane that draws continuously pays one timer
  callback every 3 s and a pane that sits still pays none. An idle release
  followed by a hide returns early (`:1494-1500`) and frees nothing twice.
  The release ends in one `gl.finish()` (`OpenGL.zig:1657`) on the render
  thread with nothing waiting on it.
- **ae9b1adb2 (T3104):** correct as read; its interaction with
  `refreshOcclusion` is the PA-R16 change above.
- **6dc6ecb90 (T3102):** the renderer part is the generic half of the idle
  release, reviewed with ad014989d. The `visible` early return in
  `drawFrame` (`generic.zig:2095-2097`) is compiled only for Metal; on
  Windows the thread-side check (`Thread.zig:602`, `:842-845`) is the only
  guard, which is enough because only the render thread draws here.
- **ef6aee174 (T2976):** no renderer source.
- **40297c800 (T3001):** PA-R22 (the thumbnail buffer is now freed and
  re-allocated per capture in hero mode).

## New findings

### PA-R20: the first frame after a 3 s pause re-creates the target, the shared texture and both atlas copies (P2, promote to P1 if it measures over ~2 ms)

- **Where:** `generic.zig:1406` (`idle_release_ns` = 3 s), `:1517-1533`
  (release), `:2174` and `:2196-2202` (first frame back), `:2260-2279`
  (`frame.resize`: new renderbuffer and framebuffer), `:2303-2321` with
  `:4204-4210` (new atlas texture, whole-atlas upload, twice);
  `OpenGL.zig:1653` and `gl_comp_present.zig:985-992`, `:882-931` (new D3D11
  texture, `wglDXRegisterObjectNV`, new renderbuffer and framebuffer).
- **Mechanism:** introduced by ad014989d. A visible pane that has not drawn
  for 3 s gives everything back. The frame that ends the pause pays for all
  of it before it can present. That frame is very often the one the user is
  waiting on: the first keystroke after reading, the first line of output
  after a prompt sat still, the frame a fold or hero capture asks for. A
  focused pane with a blinking cursor draws every 600 ms and never goes
  idle; a steady or hidden cursor (most TUIs, every unfocused pane) does.
- **Cost:** per first frame, per pane:
  - one renderbuffer allocation at the pane's bucketed size (4 bytes per
    pixel; 5 MB at 1400x860) (*computed*)
  - one `CreateTexture2D` of the same size plus one interop register
    (*computed*; time not known)
  - 1.25 MB of atlas upload at the default 512 px atlases (262 KB grayscale
    + 1 MB color; `atlases=1280KB` in T3103's readout, *quoted*), and 4x that
    per doubling of the atlas
  - the time is *inferred*, not measured. Mac's note says about 1 ms for its
    path; the Windows path adds the interop register and was not timed.
    T3103's harness checks that the frame is drawn in full (I2), not how
    long it takes.
- **Fix, cheapest first:**
  1. Measure it: time `drawFrame` for the first frame after an idle release
     against a warm frame (`GHOZTTY_IDLE_FRAME_RELEASE=0` is the control).
  2. Keep the atlas copies on an idle release (free them only on a hidden
     release). They are the upload; the target and shared texture are
     allocations only. Or share the atlas across panes (PA-R03), which
     removes the copies altogether.
  3. Do not idle-release the focused pane.
- **Risk:** low for 2 and 3; each gives back some of T3103's saving
  (14 MB over four panes, *quoted*).

### PA-R21: a released pane's "1x1" target is 256x256 (P2)

- **Where:** `OpenGL.zig:1343-1350` (`initTarget` always sets `grow_only` on
  win32), `opengl/Target.zig:34-37` and `:56-58` (`capacityFor(1, true)` is
  256), reached from `generic.zig:1529` (`frame.resize(api, 1, 1)`) and from
  `FrameState.init` (`:522`).
- **Mechanism:** the placeholder left by a hidden or idle release, and the
  one every new pane starts with, is rounded up to one grow bucket per side.
- **Cost (computed):** 256 KB of renderbuffer per released pane (20 idle
  panes: 5 MB) that the release was meant to give back. It also makes
  `frameMemory` and the release log under-report by that much, since they
  read `width`/`height`, not `alloc_width`/`alloc_height`
  (`generic.zig:1394`, `:1506`).
- **Fix:** `capacityFor` returns `need` when `need <= 1`, or the release
  path asks for a non-grow-only target.
- **Risk:** none.

### PA-R22: hero mode frees and re-allocates each pane's thumbnail buffer on every capture (P2)

- **Where:** `apprt/win32/Surface.zig:2853` (`heroSnapPublish` frees the
  buffer when no request is pending), `:2664-2672` (`snapRequest` allocates
  when the length differs), `:2736-2743` (`heroSnapCommit` clears
  `snap_requested` before the publish message is posted),
  `hero_snap_schedule.zig:58-62` (a terminal is captured every 150 ms).
- **Mechanism:** introduced by 40297c800. The free was meant for the
  full-size fold snapshot, but it runs for every publish. In hero mode the
  request flag is already clear when the GUI thread publishes, so the buffer
  is freed and the next heartbeat allocates it again: one allocation and one
  free of `thumb_w * thumb_h * 4` bytes per pane, 6.7 times a second, on the
  GUI thread under `snap_mutex`.
- **Cost:** small (*inferred*): a few hundred KB per allocation, which a
  general-purpose allocator typically serves from fresh pages each time.
  Only while hero mode is on.
- **Fix:** free in `heroSnapPublish` only when the request was exact or
  full-size, or not at all (`releaseSnapshot` already frees it when hero
  mode ends, a glide lands or a drag ends).
- **Risk:** none.

## Checked and found clean

| Checked | Result |
|---|---|
| Idle release fighting the storage trim | The trim timer is armed only after a frame (`Thread.zig:617`) and the release presents nothing, so neither wakes the other. A trim frame resets the idle clock once. |
| Idle release leaving a re-present with no target | `hiddenTargetsReleased` nulls `last_target` and `redraw_after_release` forces `needs_redraw` (`generic.zig:2174`), so `presentLastTarget` is not reached with a freed target. |
| A capture on a released pane | A request makes `frame_changed` true (`generic.zig:1955-1957`), the frame draws in full and `captureThumb` reads the new target. |
| Atlas band applied to a released texture | `releaseAtlases` zeroes the counters, so the next sync is a full upload of a new texture (`:4204-4210`). |
| Idle timer cost while drawing | One callback per 3 s per drawing pane, one mutex lock and one clock read. None while still. |
| Hero mode against the idle release | Terminals are captured every 150 ms, each a full draw, so a hero tab's panes never reach 3 s idle and do not cycle. |
| `releaseShared` while the texture is locked | `destroyShared` unlocks first (`gl_comp_present.zig:946-950`). |

## Not covered

- Nothing was measured. PA-R20's time, PA-R16's race and R10's per-context
  inference all need a box.
- The window presenter path and tree mode (both opt-in) were read only where
  the fix commits touched them.
- The Mac halves (Metal, `IOSurfaceLayer`, T2984) were not checked.

## Summary

Counts over the 19 existing ids:

- **fixed:** 8 (R01, R02, R04, R05, R06, R07, R08, R09); R09 is new this
  round and is "fixed (incomplete)" with the remainder on T3091/T3092; R07
  gained a caveat (PA-R20)
- **still open:** 7 (R03, R12, R13, R14, R15, R17, R19)
- **changed:** 4 (R10 closed as a driver pool; R11 one new cost; R16 larger;
  R18 smaller)
- **wrong:** 0
- **new:** 3 (PA-R20, PA-R21, PA-R22), all P2

Open P0/P1 in this area: none filed as such. Two things could become P1:

- PA-R20, if the first frame after a pause measures over about 2 ms
- T3074 (P1, open): the per-pane DComp device and the chrome and child D3D11
  devices, the residual of PA-R02
