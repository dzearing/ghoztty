# Command Palette MRU Ordering

## Overview

Add a "Recent" section to the top of the command palette showing the 10 most recently used commands. Commands from all three palette categories (update, terminal, jump-to-surface) are eligible. History is persisted as a JSON file in the ghostty config directory for cross-platform portability.

## Data Model

### PaletteHistory

A new Swift class responsible for loading, querying, and persisting command usage history.

**Storage format**: `palette-history.json` in the ghostty config directory (e.g. `~/.config/ghostty/palette-history.json`).

**File contents**: A flat JSON dictionary mapping command action strings to ISO 8601 timestamps:

```json
{
  "new_tab": "2026-05-03T10:30:00Z",
  "goto_split:left": "2026-05-02T14:22:00Z"
}
```

**Responsibilities**:

- **Load**: Read and decode `palette-history.json` on init. If the file doesn't exist or can't be read, start with an empty dictionary.
- **Record**: Update the timestamp for a given action string to the current time.
- **Save**: Write the dictionary to disk immediately after each update. The file is small (finite command set), so this has no performance concern.
- **Query**: Return the N most recent entries sorted by timestamp descending.

### Config Directory Resolution

- Call `ghostty_config_open_path()` to get the config file path (e.g. `~/.config/ghostty/config`).
- Take the parent directory.
- Append `palette-history.json`.

If the path can't be resolved, degrade gracefully — no Recent section, and history is not persisted until the path becomes available.

## UI Changes

### TerminalCommandPalette.swift — Command Population

The `options` computed property currently builds a flat list (update + terminal + jump options) sorted alphabetically. The new behavior when the search query is empty:

1. Build the full command list as today.
2. Consult `PaletteHistory` for the 10 most recently used action strings.
3. Match those against the current command list by action string.
4. Build two sections:
   - **"Recent"** — matched commands ordered by most recent first (up to 10).
   - **"All Commands"** — the full command list in its current alphabetical order (including commands that also appear in Recent — no deduplication, so users always find commands in their expected position).
5. Each section has a visible header label.

If there are no recent commands (empty history or no matches), the Recent section and its header are omitted entirely.

### CommandPalette.swift — Filtering

- **Query empty**: Show the sectioned layout (Recent + All Commands) with headers.
- **Query non-empty**: Flatten to a single list with no section headers — same substring/color matching behavior as today. Recent commands get no special treatment during search.

### Section Headers

Section headers are a new UI element in the palette. They should be non-selectable, visually distinct from command rows (e.g. smaller, muted text), and not interfere with keyboard navigation.

### CommandPalette.swift — Recording Usage

When a command is executed via the palette (the `action` closure fires), record the action string and current timestamp in `PaletteHistory`. This requires threading the action string through to the point where `CommandOption.action()` is called.

Currently `CommandOption` stores only a `() -> Void` action closure with no identifier. To support history tracking, either:

- Add an optional `actionKey: String?` field to `CommandOption` so the palette view can record it on execution, or
- Wrap the action closure at creation time in `TerminalCommandPalette` to record before delegating to the original action.

The wrapping approach is simpler and avoids changing the `CommandOption` struct's public interface.

## Recording Flow

1. User opens palette → `PaletteHistory` is consulted (loaded from disk or cached in memory).
2. User selects a command → the wrapped action closure records the action string with the current timestamp, then fires the original action.
3. `PaletteHistory` writes to disk immediately.
4. Next palette open → Recent section reflects the update.

## Edge Cases

- **Command no longer exists**: If a recorded action string doesn't match any current command (e.g. a custom command was removed), skip it when building the Recent section. Don't clean up the history file — the command may return.
- **Fewer than 10 recent commands**: Show however many exist. Zero means no Recent section.
- **File permissions / missing directory**: If writing fails, log and continue silently. The palette works without history.
- **Concurrent access**: Not a concern — only one palette instance writes at a time.

## Files to Create/Modify

- **Create**: `macos/Sources/Features/Command Palette/PaletteHistory.swift` — history management class.
- **Modify**: `macos/Sources/Features/Command Palette/TerminalCommandPalette.swift` — add Recent section to command population, wrap action closures to record usage.
- **Modify**: `macos/Sources/Features/Command Palette/CommandPalette.swift` — add section header support, conditionally show sections vs. flat list based on query state.
