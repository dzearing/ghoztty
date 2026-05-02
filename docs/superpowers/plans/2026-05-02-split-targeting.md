# Split Targeting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `+split` CLI action and a `--target` naming system so users can create named windows and add splits to them by name.

**Architecture:** IPCServer gains a `[String: Weak<TerminalController>]` registry. `+new-window --target=X` registers the controller. New `+split --target=X --direction=right` looks up the controller and posts `ghosttyNewSplit` on its focused surface. The `+split` action follows the same IPC patterns as `+new-window`: Zig CLI → Unix socket → Swift server.

**Tech Stack:** Zig 0.15 (CLI action, IPC types), Swift (IPCServer registry, split dispatch)

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `src/cli/split.zig` | Create | `+split` CLI action: parse args, call `performIpc` |
| `src/cli/ghostty.zig` | Modify | Register `+split` action in the Action enum and runMain |
| `src/apprt/ipc.zig` | Modify | Add `split` action to the IPC Action union |
| `include/ghostty.h` | Modify | Add `GHOSTTY_IPC_ACTION_SPLIT` and C struct |
| `src/apprt/embedded.zig` | Modify | Add `split` case to `performIpc` switch, add `ipcSplit` |
| `macos/Sources/Features/IPC/IPCServer.swift` | Modify | Add target registry, handle `--target` in new-window, add `split` action handler |

---

### Task 1: Add `split` IPC Action Types

**Files:**
- Modify: `src/apprt/ipc.zig`
- Modify: `include/ghostty.h`

- [ ] **Step 1: Add Split to the Action union in ipc.zig**

In `src/apprt/ipc.zig`, after the `new_window: NewWindow` field (line 74), add:

```zig
    split: Split,
```

After the `NewWindow` struct (after line 111), add:

```zig
    pub const Split = struct {
        arguments: ?[][:0]const u8,

        pub const C = extern struct {
            arguments: ?[*]?[*:0]const u8,

            pub fn deinit(self: *Split.C, alloc: Allocator) void {
                if (self.arguments) |arguments| alloc.free(arguments);
            }
        };

        pub fn cval(self: *Split, alloc: Allocator) Allocator.Error!Split.C {
            var result: Split.C = undefined;

            if (self.arguments) |arguments| {
                result.arguments = try alloc.alloc([*:0]const u8, arguments.len + 1);

                for (arguments, 0..) |argument, i|
                    result.arguments[i] = argument.ptr;

                result.arguments[arguments.len] = null;
            } else {
                result.arguments = null;
            }

            return result;
        }
    };
```

In the `Key` enum (line 115), after `new_window,` add:

```zig
        split,
```

- [ ] **Step 2: Update ghostty.h**

In `include/ghostty.h`, after the `ghostty_ipc_action_new_window_s` struct (line 1048), add:

```c
typedef struct {
  const char **arguments;
} ghostty_ipc_action_split_s;
```

Update the `ghostty_ipc_action_u` union (line 1050-1052) to:

```c
typedef union {
  ghostty_ipc_action_new_window_s new_window;
  ghostty_ipc_action_split_s split;
} ghostty_ipc_action_u;
```

Update the `ghostty_ipc_action_tag_e` enum (line 1054-1057) to:

```c
typedef enum {
  GHOSTTY_IPC_ACTION_NEW_WINDOW,
  GHOSTTY_IPC_ACTION_SPLIT,
} ghostty_ipc_action_tag_e;
```

- [ ] **Step 3: Commit**

```bash
git add src/apprt/ipc.zig include/ghostty.h
git commit -m "feat: add split IPC action type"
```

---

### Task 2: Create `+split` CLI Action

**Files:**
- Create: `src/cli/split.zig`
- Modify: `src/cli/ghostty.zig`

- [ ] **Step 1: Create split.zig**

Create `src/cli/split.zig` modeled on `new_window.zig` but simpler — it only needs `--target`, `--direction`, and `--command`/`-e`:

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Action = @import("../cli.zig").ghostty.Action;
const apprt = @import("../apprt.zig");
const args = @import("args.zig");
const diagnostics = @import("diagnostics.zig");
const lib = @import("../lib/main.zig");

pub const Options = struct {
    _arena: ?ArenaAllocator = null,

    /// All of the arguments after `+split`. They will be sent to Ghostty
    /// for processing.
    _arguments: std.ArrayList([:0]const u8) = .empty,

    _diagnostics: diagnostics.DiagnosticList = .{},

    pub fn parseManuallyHook(self: *Options, alloc: Allocator, arg: []const u8, iter: anytype) (error{InvalidValue} || Allocator.Error)!bool {
        var e_seen: bool = std.mem.eql(u8, arg, "-e");

        if (try self.checkArg(alloc, arg)) |a| try self._arguments.append(alloc, a);

        while (iter.next()) |param| {
            if (e_seen) {
                try self._arguments.append(alloc, try alloc.dupeZ(u8, param));
                continue;
            }
            if (std.mem.eql(u8, param, "-e")) {
                e_seen = true;
                try self._arguments.append(alloc, try alloc.dupeZ(u8, param));
                continue;
            }
            if (try self.checkArg(alloc, param)) |a| try self._arguments.append(alloc, a);
        }

        return false;
    }

    fn checkArg(self: *Options, alloc: Allocator, arg: []const u8) (error{InvalidValue} || Allocator.Error)!?[:0]const u8 {
        _ = self;
        return try alloc.dupeZ(u8, arg);
    }

    pub fn deinit(self: *Options) void {
        if (self._arena) |arena| arena.deinit();
        self.* = undefined;
    }

    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// The `split` command will use native platform IPC to create a new split
/// in a running Ghostty window.
///
/// If `--target` is specified, the split will be added to the window that
/// was created with the matching `--target` name. If `--target` is not
/// specified, the split will be added to the most recently focused window.
///
/// Flags:
///
///   * `--target=<name>`: The target window name to add the split to.
///     The target must have been created with `+new-window --target=<name>`.
///
///   * `--direction=right|down|left|up`: The direction to split. Defaults
///     to `right` if not specified.
///
///   * `--command=<command>`: The command to run in the split pane.
///
///   * `-e`: Any arguments after this will be interpreted as a command to
///     execute in the split pane.
///
/// Available since: 1.2.0
pub fn run(alloc: Allocator) !u8 {
    var iter = try args.argsIterator(alloc);
    defer iter.deinit();

    var buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&buffer);
    const stderr = &stderr_writer.interface;

    const result = runArgs(alloc, &iter, stderr);
    stderr.flush() catch {};
    return result;
}

fn runArgs(
    alloc_gpa: Allocator,
    argsIter: anytype,
    stderr: *std.Io.Writer,
) !u8 {
    var opts: Options = .{};
    defer opts.deinit();

    args.parse(Options, alloc_gpa, &opts, argsIter) catch |err| switch (err) {
        error.ActionHelpRequested => return err,
        else => {
            try stderr.print("Error parsing args: {}\n", .{err});
            return 1;
        },
    };

    var arena = ArenaAllocator.init(alloc_gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    if (apprt.App.performIpc(
        alloc,
        .detect,
        .split,
        .{
            .arguments = if (opts._arguments.items.len == 0) null else opts._arguments.items,
        },
    ) catch |err| switch (err) {
        error.IPCFailed => return 1,
        else => {
            try stderr.print("Sending the IPC failed: {}", .{err});
            return 1;
        },
    }) return 0;

    try stderr.print("+split is not supported on this platform.\n", .{});
    return 1;
}
```

- [ ] **Step 2: Register in ghostty.zig**

In `src/cli/ghostty.zig`, add the import after line 22 (`const new_window = ...`):

```zig
const split = @import("split.zig");
```

In the `Action` enum, after line 74 (`@"new-window",`), add:

```zig
    // Use IPC to tell the running Ghostty to create a split in an existing window.
    split,
```

In the `runMain` function, after line 154 (`.@"new-window" => ...`), add:

```zig
            .split => try split.run(alloc),
```

- [ ] **Step 3: Commit**

```bash
git add src/cli/split.zig src/cli/ghostty.zig
git commit -m "feat: add +split CLI action"
```

---

### Task 3: Add Zig IPC Client for Split

**Files:**
- Modify: `src/apprt/embedded.zig`

- [ ] **Step 1: Add split case to performIpc and ipcSplit function**

In `src/apprt/embedded.zig`, update the `performIpc` switch (around line 337-339) to:

```zig
        switch (action) {
            .new_window => return ipcNewWindow(alloc, value),
            .split => return ipcSplit(alloc, value),
        }
```

After the `ipcNewWindow` function (after `readFull`), add `ipcSplit`. It follows the same pattern as `ipcNewWindow` but sends action `"split"`:

```zig
    fn ipcSplit(
        alloc: Allocator,
        value: apprt.ipc.Action.Split,
    ) (Allocator.Error || std.posix.WriteError || apprt.ipc.Errors)!bool {
        var buf: [256]u8 = undefined;
        var stderr_writer = std.fs.File.stderr().writer(&buf);
        const stderr = &stderr_writer.interface;

        const tmpdir = std.posix.getenv("TMPDIR") orelse "/tmp";
        const uid = std.c.getuid();
        const build_config = @import("../build_config.zig");
        const suffix = if (build_config.is_debug) "-debug" else "";
        const sock_path = std.fmt.allocPrintSentinel(alloc, "{s}ghostty{s}-{d}.sock", .{
            tmpdir, suffix, uid,
        }, 0) catch |err| {
            stderr.print("Failed to build socket path: {}\n", .{err}) catch {};
            stderr.flush() catch {};
            return error.IPCFailed;
        };
        defer alloc.free(sock_path);

        const fd = connectUnixSocket(sock_path) catch {
            stderr.print(
                "Failed to connect to Ghostty IPC socket at {s}\nIs Ghostty running?\n",
                .{sock_path},
            ) catch {};
            stderr.flush() catch {};
            return error.IPCFailed;
        };
        defer std.posix.close(fd);

        var json_buf: std.Io.Writer.Allocating = .init(alloc);
        defer json_buf.deinit();
        var jws: std.json.Stringify = .{ .writer = &json_buf.writer };

        jws.beginObject() catch return error.IPCFailed;
        jws.objectField("action") catch return error.IPCFailed;
        jws.write("split") catch return error.IPCFailed;

        if (value.arguments) |arguments| {
            jws.objectField("arguments") catch return error.IPCFailed;
            jws.beginArray() catch return error.IPCFailed;
            for (arguments) |arg| {
                jws.write(arg) catch return error.IPCFailed;
            }
            jws.endArray() catch return error.IPCFailed;
        }

        jws.endObject() catch return error.IPCFailed;

        const json_bytes = json_buf.written();

        const len: u32 = @intCast(json_bytes.len);
        const len_bytes = std.mem.toBytes(std.mem.nativeToBig(u32, len));
        _ = std.posix.write(fd, &len_bytes) catch |err| {
            stderr.print("Failed to send IPC message: {}\n", .{err}) catch {};
            stderr.flush() catch {};
            return error.IPCFailed;
        };
        _ = std.posix.write(fd, json_bytes) catch |err| {
            stderr.print("Failed to send IPC message: {}\n", .{err}) catch {};
            stderr.flush() catch {};
            return error.IPCFailed;
        };

        var resp_len_bytes: [4]u8 = undefined;
        readFull(fd, &resp_len_bytes) catch {
            stderr.print("Failed to read IPC response length\n", .{}) catch {};
            stderr.flush() catch {};
            return error.IPCFailed;
        };

        const resp_len = std.mem.bigToNative(u32, std.mem.bytesAsValue(u32, &resp_len_bytes).*);
        if (resp_len == 0 or resp_len > 1048576) {
            stderr.print("IPC response has invalid length: {d}\n", .{resp_len}) catch {};
            stderr.flush() catch {};
            return error.IPCFailed;
        }

        const resp_buf = alloc.alloc(u8, resp_len) catch {
            stderr.print("Out of memory reading IPC response\n", .{}) catch {};
            stderr.flush() catch {};
            return error.IPCFailed;
        };
        defer alloc.free(resp_buf);

        readFull(fd, resp_buf) catch {
            stderr.print("Failed to read IPC response\n", .{}) catch {};
            stderr.flush() catch {};
            return error.IPCFailed;
        };

        const parsed = std.json.parseFromSlice(
            struct { success: bool = false },
            alloc,
            resp_buf,
            .{ .ignore_unknown_fields = true },
        ) catch {
            stderr.print("IPC response is not valid JSON\n", .{}) catch {};
            stderr.flush() catch {};
            return error.IPCFailed;
        };
        defer parsed.deinit();

        return parsed.value.success;
    }
```

- [ ] **Step 2: Commit**

```bash
git add src/apprt/embedded.zig
git commit -m "feat: add split IPC client in embedded apprt"
```

---

### Task 4: Add Target Registry and Split Handler to Swift IPCServer

**Files:**
- Modify: `macos/Sources/Features/IPC/IPCServer.swift`

This is the core task. Three changes:

1. Add a target registry (weak references to TerminalController keyed by name)
2. Handle `--target` in `handleNewWindow` to register the controller
3. Add a `handleSplit` method that looks up the target and posts the split notification

- [ ] **Step 1: Add target registry property**

In `IPCServer.swift`, after line 16 (`private let queue = ...`), add:

```swift
    private var targetRegistry: [String: WeakController] = [:]

    private struct WeakController {
        weak var controller: TerminalController?
    }
```

- [ ] **Step 2: Add "split" to dispatchAction**

Update the `dispatchAction` method to handle "split":

```swift
    private func dispatchAction(_ request: IPCRequest) -> IPCResponse {
        switch request.action {
        case "new-window":
            return handleNewWindow(request)
        case "split":
            return handleSplit(request)
        default:
            return IPCResponse(success: false, error: "unknown action: \(request.action)")
        }
    }
```

- [ ] **Step 3: Update handleNewWindow to register targets**

In the existing `handleNewWindow` method, after `let controller = TerminalController.newWindow(...)`, add target registration. The updated method:

```swift
    private func handleNewWindow(_ request: IPCRequest) -> IPCResponse {
        let parsed: ParsedArguments
        if let arguments = request.arguments {
            parsed = parseArguments(arguments)
        } else {
            parsed = ParsedArguments(config: Ghostty.SurfaceConfiguration())
        }

        DispatchQueue.main.async { [ghostty = self.ghostty, weak self] in
            let controller = TerminalController.newWindow(ghostty, withBaseConfig: parsed.config)

            // Register target name if provided
            if let target = parsed.target {
                self?.targetRegistry[target] = WeakController(controller: controller)
                Self.logger.info("IPC: registered target '\(target)'")
            }

            if let splitDir = parsed.splitDirection,
               let direction = Self.parseSplitDirection(splitDir) {
                DispatchQueue.main.async {
                    guard let surfaceView = controller.focusedSurface else {
                        Self.logger.warning("IPC: no surface view for split")
                        return
                    }

                    var splitConfig = Ghostty.SurfaceConfiguration()
                    if let splitCommand = parsed.splitCommand {
                        splitConfig.command = splitCommand
                    }

                    NotificationCenter.default.post(
                        name: Ghostty.Notification.ghosttyNewSplit,
                        object: surfaceView,
                        userInfo: [
                            "direction": direction,
                            Ghostty.Notification.NewSurfaceConfigKey: splitConfig,
                        ]
                    )
                }
            }
        }

        return .ok
    }
```

- [ ] **Step 4: Add handleSplit method**

```swift
    private func handleSplit(_ request: IPCRequest) -> IPCResponse {
        let parsed: ParsedArguments
        if let arguments = request.arguments {
            parsed = parseArguments(arguments)
        } else {
            parsed = ParsedArguments(config: Ghostty.SurfaceConfiguration())
        }

        let directionStr = parsed.splitDirection ?? "right"
        guard let direction = Self.parseSplitDirection(directionStr) else {
            return IPCResponse(success: false, error: "invalid direction: \(directionStr)")
        }

        DispatchQueue.main.async { [weak self] in
            // Find the target controller
            let controller: TerminalController?
            if let target = parsed.target {
                self?.pruneStaleTargets()
                controller = self?.targetRegistry[target]?.controller
                if controller == nil {
                    Self.logger.warning("IPC: target '\(target)' not found")
                }
            } else {
                // Default to frontmost terminal window
                controller = TerminalController.preferredParent
            }

            guard let controller else {
                Self.logger.warning("IPC: no controller found for split")
                return
            }

            guard let surfaceView = controller.focusedSurface else {
                Self.logger.warning("IPC: no focused surface for split")
                return
            }

            var splitConfig = Ghostty.SurfaceConfiguration()
            if let splitCommand = parsed.splitCommand {
                splitConfig.command = splitCommand
            }
            if let workingDirectory = parsed.config.workingDirectory {
                splitConfig.workingDirectory = workingDirectory
            }

            NotificationCenter.default.post(
                name: Ghostty.Notification.ghosttyNewSplit,
                object: surfaceView,
                userInfo: [
                    "direction": direction,
                    Ghostty.Notification.NewSurfaceConfigKey: splitConfig,
                ]
            )
        }

        return .ok
    }

    private func pruneStaleTargets() {
        targetRegistry = targetRegistry.filter { $0.value.controller != nil }
    }
```

- [ ] **Step 5: Add `--target` to ParsedArguments and parseArguments**

Update the `ParsedArguments` struct:

```swift
    struct ParsedArguments {
        var config: Ghostty.SurfaceConfiguration
        var splitDirection: String?
        var splitCommand: String?
        var target: String?
    }
```

Update `parseArguments` to handle `--target=` and `--direction=`. Add these cases in the argument loop (after the `--split-command=` case):

```swift
            if let value = arg.dropPrefix("--target=") {
                result.target = String(value)
                continue
            }

            if let value = arg.dropPrefix("--direction=") {
                result.splitDirection = String(value)
                continue
            }
```

Also update the `ParsedArguments` initializer call in `parseArguments`:

```swift
        var result = ParsedArguments(config: Ghostty.SurfaceConfiguration())
```

This already matches since the new `target` field defaults to `nil`.

- [ ] **Step 6: Check that `TerminalController.preferredParent` exists**

Search for `preferredParent` in `TerminalController.swift`:

```bash
grep -n "preferredParent" macos/Sources/Features/Terminal/TerminalController.swift
```

This property is used in `AppDelegate.swift:519` and `newWindow` (line 258). It returns the most recently focused TerminalController. This is the correct fallback when no `--target` is specified.

- [ ] **Step 7: Commit**

```bash
git add macos/Sources/Features/IPC/IPCServer.swift
git commit -m "feat(macos): add target registry and +split handler to IPC server"
```

---

### Task 5: Build and Test

- [ ] **Step 1: Build**

```bash
PATH="/opt/homebrew/opt/zig@0.15/bin:$PATH" zig build -Doptimize=Debug
```

Expected: Clean build.

- [ ] **Step 2: Launch debug Ghostty**

```bash
./zig-out/Ghostty.app/Contents/MacOS/ghostty &
sleep 3
```

- [ ] **Step 3: Test named window + split targeting**

```bash
# Create a named window
./zig-out/Ghostty.app/Contents/MacOS/ghostty +new-window --target=myproject --command=bash

# Add a right split to that window
./zig-out/Ghostty.app/Contents/MacOS/ghostty +split --target=myproject --direction=right --command="echo right pane"

# Add a down split to that window
./zig-out/Ghostty.app/Contents/MacOS/ghostty +split --target=myproject --direction=down --command="echo bottom pane"
```

Expected: One window with three panes.

- [ ] **Step 4: Test split without target (defaults to frontmost)**

```bash
./zig-out/Ghostty.app/Contents/MacOS/ghostty +split --direction=right --command="echo no target"
```

Expected: Split added to whichever Ghostty window is focused.

- [ ] **Step 5: Test error — unknown target**

```bash
./zig-out/Ghostty.app/Contents/MacOS/ghostty +split --target=nonexistent --direction=right
```

Expected: Exit code 0 (fire-and-forget) but the split won't appear. Console.app should show "IPC: target 'nonexistent' not found".

- [ ] **Step 6: Commit any fixes**

```bash
git add -u
git commit -m "fix: address issues found during split testing"
```

---

## Implementation Notes

### Argument Reuse
The `+split` action reuses the same IPC argument-passing pattern as `+new-window`. Arguments like `--target=X`, `--direction=right`, and `--command=foo` are collected into a string array and sent as the JSON `"arguments"` field. The Swift side parses them identically via `parseArguments`.

### Target Lifecycle
Targets use `weak` references to `TerminalController`. When a user closes a window, the controller is deallocated and the weak reference becomes `nil`. `pruneStaleTargets()` is called before lookups to clean stale entries.

### Default Direction
When `+split` is called without `--direction`, it defaults to `"right"` in the `handleSplit` method.

### `preferredParent`
`TerminalController.preferredParent` is an existing static property that returns the most recently focused terminal controller. It's used as the default target when `--target` is not specified.
