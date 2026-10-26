# Terminal resize pacing

How a pane resize reaches the program and the screen. Read before touching
`src/termio/Thread.zig` resize coalescing, `Termio.resizePace`, the renderer's
prompt-redraw hold, or anything that resizes a surface during an animation
(see also banner collapse in [banners.md](banners.md) and stacked-pane glides
in [stacked-panes.md](stacked-panes.md)).

- **Resizes are debounced before they reach the program**
  (`src/termio/Thread.zig` `Coalesce`): applied once resizes stop arriving for
  100ms, never held back more than 350ms. Each one is a SIGWINCH on which a
  full-screen TUI (Claude Code) clears and repaints; a 600ms divider drag is
  ~4 repaints (was 35 at a fixed 25ms coalesce)
  (`aDragDoesNotStormTheProgramWithResizes`). A program running (the cursor's
  content is output, or the alternate screen) is debounced this way.
- **A shell at its prompt is not debounced** (`Termio.resizePace`): the grid
  reflows at once, and the next resize waits only for the shell's redraw of
  the last, so a drag reflows the prompt as it goes
  (`aResizeReflowsThePromptAsItHappens`, local and agent panes).
- **A resize never shows the prompt blank.** With the cursor at a prompt, a
  resize clears the prompt for the shell to redraw (`Screen.resize`, shell
  integration); the redraw takes a round trip (longer through the session
  agent, and may arrive in pieces). The renderer holds the last frame
  (`Terminal.flags.awaiting_prompt_redraw`) until the cursor's line (its row,
  or a row it soft-wraps from: a wrapped prompt's last row can hold just the
  space before the cursor) shows text again and output has been quiet 15ms,
  capped at 250ms (`termio.Thread.prompt_redraw_ms`) for a shell that never
  redraws. That cap is armed after `loop.update_now()`: the IO loop's cached
  clock is seconds stale after an idle stretch, and a timer measured from it
  fires at once. Tests: `aResizeNeverBlanksThePrompt` (window resizes, local
  and agent panes; frames in `/tmp/banner-collapse-resize[-agent]`).
- `ghostty_surface_flush_resize` skips the debounce for a resize made out of
  sight (banner collapse).
- `resize-overlay` defaults to `never` in this fork (the dimensions popup on
  every divider drag).
