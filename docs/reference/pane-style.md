# Pane style (`macos-pane-style`) and glass panes

How a window's panes look: elevated cards on a gradient desk, glass panes,
focus glow and unfocused dimming. Read before touching `PaneElevation` /
`PaneDesk` / `PaneCard` / `PaneGlass` / `PaneFocusGlow`, window gradients, or
anything painted behind or over a pane. Settled in the pane-sidebar mock
(`docs/design/pane-sidebar.md` → Pane style). Stacking geometry is in
[stacked-panes.md](stacked-panes.md); resize pacing in
[terminal-resize.md](terminal-resize.md).

## Styles

- **`elevated`** (default): panes are slightly raised rounded cards (11pt
  radius, a soft two-layer shadow, a hairline rim) on a soft blue-to-teal
  **ocean** gradient. ONE spacing, 10pt, is every gutter: pane to pane (the
  gaps are still the dividers), pane to window edge, and around the rail
  (which takes no trailing margin of its own — the grid's is that gap).
- **`flat`**: the classic edge-to-edge look with a 1px `split-divider-color`
  line drawn down the middle of a 6pt gutter (`PaneLayout.Metrics.flatGap`) —
  a real gutter, because gutters are where the resize grips live. Its panes
  stack like any other.
- Geometry and palette live once in `PaneElevation`/`PaneDesk`/`PaneCard`
  (`Features/Splits/PaneElevation.swift`), used by the grid AND the hidden
  stashed-pane slots — the slots must lay out exactly like the grid or a
  restored pane would reflow.
- The expanded pane sidebar goes translucent so the gradient runs under it.
- A translucent terminal (`background-opacity` < 1) gets an equally
  translucent gradient.

## Window gradients and `--color`

**A window opened by hand (Cmd-N, the New Window menu item / palette command)
gets a random gradient by default**, exactly as **`+new-window --color=random`**
does. In the elevated style that gives the window its OWN gradient
(`PaneDeskVariant`: a persisted seed; ONE random hue from the whole wheel, with
a soft spotlight from the top center, getting darker toward the
bottom-trailing corner on a dark theme and lighter on a light one, where a dim
pool of the **complementary** hue subtly lights that corner) and leaves the
terminals their theme color. An explicit `--color=#hex`, `random` on a split,
and `random` in the `flat` style still tint the terminal background.
(See also `docs/design/window-color.md`.)

## Glass panes (`macos-pane-glass`, default `true`, elevated only)

Each pane is a translucent sheet tinted with the terminal's own background
(Liquid Glass on macOS 26, a plain tint before — `PaneGlass`), so the
gradient's light and shade read through every pane.

**Tint levels**: every pane, focused or not, `PaneGlass.tint` 40%; under a
banner card `PaneGlass.bannerTint` 25%.

- The renderer stops drawing the terminal's background (`generic.zig`
  `pane_glass`, the same switch the `macos-glass-*` blur styles use).
- **Banner card**: the banner strip skips its base fill, and the card is a
  pane of glass of its own layered on top — the pane's sheet thins to
  `bannerTint` under it (the card publishes its frame up to `PaneCard` as
  `PaneBannerCardKey`), and the card itself is rim and drop shadow only, no
  white wash and no sheen (`SurfacePaneBanner.isGlass`). A white lift, or a
  second Liquid Glass sheet, greyed the gradient into a flat slab
  (`bannerOnGlassLetsTheGradientThrough`). `flat` and elevated-without-glass
  keep the wash.
- **Viewers**: template pages (markdown/code/diff/image) go see-through
  (`ViewerView.isOnGlass`, a `pane-glass` class in `viewer.css`); websites and
  HTML files keep their own background.
- **Titlebar**: the gradient runs up under it — the transparent-titlebar window
  turns on `.fullSizeContentView` and `titlebarAppearsTransparent` (macOS 26
  otherwise backs it with a material), and the desk sits behind the whole
  content stack. Any `.background(Color)` in that stack must pass
  `ignoresSafeAreaEdges: []` — SwiftUI's default extends it behind the
  titlebar.
- **Sidebar on glass**: the sidebar's card, in both modes, is an **unfocused
  pane's card** (`PaneSidebarCard` → `PaneCard`): the same corner radius,
  hairline rim, glass sheet and shadow as the panes beside it (not the viewer
  side panel's rounder, specular glass card). The header is no band of its own
  (the list starts below it); glyphs are
  the mock's icon set drawn natively (`PaneSidebarSymbol`), not SF Symbols.
  Folding a window or project group animates.
- **Hero mode** shows its pane as the same glass card — the hero container
  paints no fill of its own on glass (`HeroPaneContainer.isGlass`).
- **A stacked row has no solid cards**: a tucked card is a card of the
  strip's size, so nothing lies under a card on show and every card and strip
  is glass (see [stacked-panes.md](stacked-panes.md)).

## Focus: rim and glow only

- In the elevated style the **focused pane** (of several) is **backlit**: a
  soft white light behind the card spills past its edges onto the desk, masked
  to outside the card so it never lightens the pane's own glass
  (`PaneFocusGlow`, driven by `PaneView.isFocusedPane`; `PaneFocusGlowTests`).
- **On glass, focus changes only the rim and the glow.** The focused pane's
  hairline rim is lighter (34% white, against 10%); its sheet and content are
  exactly those of every other pane (`PaneGlass.tint`), nothing faded. (An
  unfocused pane used to get a thinner sheet and fade its terminal by
  `unfocused-split-opacity`, so focusing read as the pane lighting up; that is
  gone.)
- Upstream's unfocused dimming (a wash of `unfocused-split-fill` at
  `1 - unfocused-split-opacity` drawn OVER the pane) is not drawn on glass.
  `flat`, and `elevated` without glass, keep the wash and honor both keys.
- Any focus-driven fade animates opacity ONLY (`FocusFade`) — a strip click
  changes focus and a card's size in one update, and an
  `.animation(_:value:)` over the card would animate the frame too, resizing
  the terminal on every frame. `PaneCard.isDimmed` (one of several panes, not
  the focused one) is the switch for the non-glass wash.

## Tests

Measured on the composited window (how much of the desk in the gutter beside a
pane its glass hides): `glassPanesLetTheGradientThrough` (also writes a
ScreenCaptureKit capture of its own window),
`glassPanesLookTheSameFocusedOrNot`, `stackedRowCardsOnShowStayGlass`,
`heroModeIsGlassLikeAFocusedPane` (`PaneSidebarWindowTests`),
`bannerOnGlassLetsTheGradientThrough`; layout rule `noCardIsDrawnOverAnother`
(`PaneLayoutTests`).
