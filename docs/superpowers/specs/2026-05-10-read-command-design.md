# `+read` IPC Command Design

## Summary

Add a `ghoztty +read` command that captures the last N lines of terminal output from a named pane and writes them to stdout. This is the primary missing feature for agent orchestration — currently agents must use log files because there's no way to programmatically read pane content from another process.

## CLI Interface

```
ghoztty +read --name=<pane> --lines=<N>
```

- `--name=<pane>` (required): The named pane to read from. Must have been created with `+split --name=<name>` or registered via `+new-window --target=<name>`.
- `--lines=<N>` (optional, default 50): Number of lines from the end of the scrollback+screen buffer. No artificial cap — the user can request as many lines as exist.

### Output

- Plain text to stdout, one line per terminal line.
- No JSON wrapping, no trailing metadata.
- Exit code 0 on success, 1 on error (error message to stderr).
- If no running Ghoztty instance: exit 1 with "No running Ghoztty instance found."

### Examples

```bash
# Read last 5 lines from a specific pane
ghoztty +read --name=worker1 --lines=5

# Default 50 lines
ghoztty +read --name=build

# Pipe for searching
ghoztty +read --name=build --lines=1000 | grep "ERROR"

# Capture into a variable
output=$(ghoztty +read --name=worker1 --lines=5)
```

## IPC Message Format

The Zig CLI sends the standard JSON format over the Unix domain socket:

```json
{"action":"read","arguments":["--name=worker1","--lines=5"]}
```

### Success Response

```json
{
  "success": true,
  "data": {
    "text": "line 1\nline 2\nline 3\nline 4\nline 5"
  }
}
```

### Error Response

```json
{"success": false, "error": "pane 'worker1' not found in registry"}
```

## Implementation

### Zig CLI (`src/cli/read.zig`)

Follows the `+list` pattern: direct socket I/O with data response parsing. Does not use `performIpc` (which only returns success/failure).

1. Parse `Options` struct with `--name`, `--lines` (default 50), `--help`.
2. Validate that `--name` was provided; exit 1 with usage error if missing.
3. Connect to Unix socket at `$TMPDIR/ghostty[-debug]-<uid>.sock`.
4. Construct and send JSON message: `{"action":"read","arguments":[...]}` with 4-byte big-endian length header.
5. Read response: 4-byte big-endian length + JSON body.
6. Parse response — if `success` is false, print `error` field to stderr, exit 1.
7. Extract `data.text` from the JSON response.
8. Write text to stdout, exit 0.

### Zig CLI dispatcher (`src/cli/ghostty.zig`)

- Add `const read = @import("read.zig");`
- Add `read` variant to the `Action` enum with description "Read terminal output from a pane via IPC"
- Add `read` case to `runMain` and `options`

### Swift IPC handler (`macos/Sources/Features/IPC/IPCServer.swift`)

Add `"read"` case to `dispatchAction` switch, and implement `handleRead`:

1. Parse arguments using `parseArguments()` (add `lines: Int?` field to `ParsedArguments`, parse `--lines=<N>`).
2. Resolve the surface: look up `--name` in `targetRegistry`, get its `.surfaceView`.
3. Get the surface's underlying `ghostty_surface_t` pointer via `surfaceView.surface`.
4. Read full screen content using `ghostty_surface_read_text` with `GHOSTTY_POINT_SCREEN` / `GHOSTTY_POINT_COORD_TOP_LEFT` and `GHOSTTY_POINT_COORD_BOTTOM_RIGHT` tags.
5. Convert to Swift `String`, split by newlines, take the last N lines (default 50).
6. Return `IPCResponse(success: true, data: .readResult(...))`.

Uses `DispatchQueue.main.async` + `DispatchSemaphore` for main-thread access to the renderer state (same pattern as `handleList`).

### Swift IPC message types (`macos/Sources/Features/IPC/IPCMessage.swift`)

Add to `IPCData` enum:

```swift
case readResult(ReadResultData)

struct ReadResultData: Encodable {
    let text: String
}
```

Update `IPCData.encode(to:)` to handle the new case, encoding `text` directly into the container.

## Files Changed

| File | Change |
|------|--------|
| `src/cli/read.zig` | **Create** — new CLI action |
| `src/cli/ghostty.zig` | **Modify** — add import, enum variant, dispatch |
| `macos/Sources/Features/IPC/IPCServer.swift` | **Modify** — add dispatch case, `handleRead`, `lines` to `ParsedArguments` |
| `macos/Sources/Features/IPC/IPCMessage.swift` | **Modify** — add `readResult` case to `IPCData` |

No changes to `src/apprt/ipc.zig` or `src/apprt/embedded.zig` — `+read` bypasses `performIpc` and talks directly to the socket (same as `+list`).

## Design Decisions

- **Just `--name`**: Agents create panes and know their names. No need for `--target=<window>` shortcut — keeps the interface simple.
- **Server-side line limiting**: The Swift handler reads the full buffer but only sends the last N lines over the socket. This keeps IPC payloads small for the common case (5-50 lines) while allowing large requests.
- **GHOSTTY_POINT_SCREEN**: Reads scrollback + visible area, not just the viewport. Agents need to see output that has scrolled past.
- **No ANSI stripping needed**: `ghostty_surface_read_text` returns cell content as plain UTF-8, not raw PTY bytes.
- **Direct socket I/O (like +list)**: `performIpc` only returns a boolean success. `+read` needs to return data, so it manages its own socket connection and JSON parsing.
