# Split Percentage & Pane Targeting

Add percentage-based splits and named pane targeting to the Ghoztty IPC CLI commands.

## Motivation

The current `+split` command always creates 50/50 splits and can only split the focused surface. AI agents and automation scripts need to create precise layouts — e.g., a 67/33 editor/sidebar split, then subdivide the sidebar — without relying on which pane happens to be focused.

## CLI Interface

### `ghoztty +split` — new flags

| Flag | Description |
|------|-------------|
| `--percent=<N>` | Percentage of space for the new pane (1–99). Default: 50. |
| `--pane=<name>` | Split a specific named pane instead of the focused surface. |

### `ghoztty +new-window` — new flag

| Flag | Description |
|------|-------------|
| `--split-percent=<N>` | Percentage of space for the split pane (1–99). Only meaningful with `--split`. |

### Example

```bash
ghoztty +new-window --target=ide --command="nvim ." --split=right --split-percent=33 --split-command=zsh --name=sidebar
ghoztty +split --target=ide --pane=sidebar --name=logs --direction=down --percent=50 --command="tail -f app.log"
```

## Implementation

### Argument parsing (`IPCServer.swift`)

Add fields to `ParsedArguments`:

- `percent: Int?`
- `pane: String?`

Parse `--percent=<N>`, `--split-percent=<N>`, and `--pane=<name>` in `parseArguments()`.

### `handleSplit()`

- If `--pane` is provided, look up the named surface in `targetRegistry` instead of using `controller.focusedSurface`.
- Convert `percent` to ratio: `Double(percent) / 100.0`, clamped to 0.1–0.9 (matching existing SplitTree resize constraints).
- Pass ratio to `controller.newSplit()`.

### `handleNewWindow()`

- If `--split-percent` is provided, same conversion and pass-through when creating the initial split.

### `BaseTerminalController.newSplit()`

- Add optional `ratio: Double?` parameter (default `nil`, meaning 0.5).
- Pass through to `SplitTree.inserting()`.

### `SplitTree.inserting()`

- Add `ratio: Double` parameter (default `0.5`).
- Use it instead of the hardcoded `0.5`.

## Validation & Edge Cases

- `--percent` values outside 1–99 return an IPC error response.
- Ratio is clamped to 0.1–0.9 (SplitTree already enforces this for resize).
- `--pane=<name>` referencing a nonexistent or stale pane returns an IPC error (this is a targeting failure, not a "create or focus" scenario).
- `--pane` and `--target` can be combined: `--target=ide --pane=sidebar` means "in the window named `ide`, split the pane named `sidebar`."
- If `--pane` is used without `--target`, the pane is looked up across all registered targets.

## Files to modify

- `macos/Sources/Features/IPC/IPCServer.swift` — argument parsing, handleSplit, handleNewWindow
- `macos/Sources/Features/Terminal/BaseTerminalController.swift` — newSplit signature
- `macos/Sources/Features/Splits/SplitTree.swift` — inserting() ratio parameter
- `src/cli/split.zig` — help text update
- `src/cli/new_window.zig` — help text update
- `README.md` — CLI docs update
- `CLAUDE.md` — CLI docs update
