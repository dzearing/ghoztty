# Idempotent IPC + Close Action Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `+new-window` and `+split` idempotent (focus if exists, create if not), add pane-level naming via `--name`, and add a `+close` action that closes named panes or windows.

**Architecture:** Replace the `WeakController`-only registry with a unified `TargetEntry` enum that can reference either a window (weak TerminalController) or a pane (weak SurfaceView + weak TerminalController). All three commands (`+new-window`, `+split`, `+close`) check the registry first: if the target exists and is alive, perform the idempotent action (focus/no-op); if not, perform the create/close action. `+close` uses `closeSurface(_:withConfirmation:)` for panes and `closeWindow(nil)` for windows.

**Tech Stack:** Zig 0.15 (new `close` IPC action, CLI), Swift (registry refactor, idempotent handlers)

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `src/apprt/ipc.zig` | Modify | Add `close` action to Action union + Key enum |
| `include/ghostty.h` | Modify | Add `GHOSTTY_IPC_ACTION_CLOSE` and C struct |
| `src/cli/close.zig` | Create | `+close` CLI action |
| `src/cli/ghostty.zig` | Modify | Register `+close` action |
| `src/apprt/embedded.zig` | Modify | Add `close` case to `performIpc`, add `ipcClose` |
| `src/cli/split.zig` | Modify | Add `--name` to docstring |
| `macos/Sources/Features/IPC/IPCServer.swift` | Modify | Unified registry, idempotent handlers, `handleClose`, `--name` parsing |

---

### Task 1: Refactor Registry and Add Idempotent Behavior (Swift)

**Files:**
- Modify: `macos/Sources/Features/IPC/IPCServer.swift`

This is the core task — refactor the registry and make existing commands idempotent.

- [ ] **Step 1: Replace WeakController with unified TargetEntry**

Replace the existing `WeakController` struct and `targetRegistry` (lines 17-21) with:

```swift
    private var targetRegistry: [String: TargetEntry] = [:]

    private enum TargetEntry {
        case window(WeakRef<TerminalController>)
        case pane(controller: WeakRef<TerminalController>, surface: WeakRef<Ghostty.SurfaceView>)

        var controller: TerminalController? {
            switch self {
            case .window(let ref): return ref.value
            case .pane(let ref, _): return ref.value
            }
        }

        var surfaceView: Ghostty.SurfaceView? {
            switch self {
            case .window(let ref): return ref.value?.focusedSurface
            case .pane(_, let ref): return ref.value
            }
        }

        var isAlive: Bool {
            switch self {
            case .window(let ref): return ref.value != nil
            case .pane(_, let ref): return ref.value != nil
            }
        }
    }

    private class WeakRef<T: AnyObject> {
        weak var value: T?
        init(_ value: T) { self.value = value }
    }
```

- [ ] **Step 2: Update pruneStaleTargets**

```swift
    private func pruneStaleTargets() {
        targetRegistry = targetRegistry.filter { $0.value.isAlive }
    }
```

- [ ] **Step 3: Add `--name` to ParsedArguments and parseArguments**

Update `ParsedArguments`:

```swift
    struct ParsedArguments {
        var config: Ghostty.SurfaceConfiguration
        var splitDirection: String?
        var splitCommand: String?
        var target: String?
        var name: String?
    }
```

Add `--name=` parsing in the argument loop (after the `--direction=` case):

```swift
            if let value = arg.dropPrefix("--name=") {
                result.name = String(value)
                continue
            }
```

- [ ] **Step 4: Make handleNewWindow idempotent**

Replace `handleNewWindow` with a version that checks the registry first:

```swift
    private func handleNewWindow(_ request: IPCRequest) -> IPCResponse {
        let parsed: ParsedArguments
        if let arguments = request.arguments {
            parsed = parseArguments(arguments)
        } else {
            parsed = ParsedArguments(config: Ghostty.SurfaceConfiguration())
        }

        // Idempotent: if target exists and window is alive, focus it
        if let target = parsed.target {
            pruneStaleTargets()
            if let entry = targetRegistry[target], let controller = entry.controller {
                DispatchQueue.main.async {
                    controller.window?.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                }
                return .ok
            }
        }

        DispatchQueue.main.async { [ghostty = self.ghostty, weak self] in
            let controller = TerminalController.newWindow(ghostty, withBaseConfig: parsed.config)

            if let target = parsed.target {
                self?.targetRegistry[target] = .window(WeakRef(controller))
                Self.logger.info("IPC: registered window target '\(target)'")
            }

            if let splitDir = parsed.splitDirection,
               let direction = Self.parseSplitDirection(splitDir) {
                DispatchQueue.main.async { [weak self] in
                    guard let surfaceView = controller.focusedSurface else {
                        Self.logger.warning("IPC: no surface view for split")
                        return
                    }

                    var splitConfig = Ghostty.SurfaceConfiguration()
                    if let splitCommand = parsed.splitCommand {
                        splitConfig.command = splitCommand
                    }

                    // Register pane name if provided
                    if let name = parsed.name {
                        // We need to register the NEW surface after the split is created.
                        // The notification handler creates the surface synchronously,
                        // so we register after posting.
                    }

                    NotificationCenter.default.post(
                        name: Ghostty.Notification.ghosttyNewSplit,
                        object: surfaceView,
                        userInfo: [
                            "direction": direction,
                            Ghostty.Notification.NewSurfaceConfigKey: splitConfig,
                        ]
                    )

                    // After the split notification is handled synchronously,
                    // the new surface is the focused one
                    if let name = parsed.name, let newSurface = controller.focusedSurface {
                        self?.targetRegistry[name] = .pane(
                            controller: WeakRef(controller),
                            surface: WeakRef(newSurface)
                        )
                        Self.logger.info("IPC: registered pane target '\(name)'")
                    }
                }
            }
        }

        return .ok
    }
```

- [ ] **Step 5: Make handleSplit idempotent and support --name**

Replace `handleSplit`:

```swift
    private func handleSplit(_ request: IPCRequest) -> IPCResponse {
        let parsed: ParsedArguments
        if let arguments = request.arguments {
            parsed = parseArguments(arguments)
        } else {
            parsed = ParsedArguments(config: Ghostty.SurfaceConfiguration())
        }

        // Idempotent: if --name exists and pane is alive, focus it
        if let name = parsed.name {
            pruneStaleTargets()
            if let entry = targetRegistry[name], let surface = entry.surfaceView {
                DispatchQueue.main.async {
                    if let controller = entry.controller {
                        controller.focusSurface(surface)
                    }
                }
                return .ok
            }
        }

        let directionStr = parsed.splitDirection ?? "right"
        guard let direction = Self.parseSplitDirection(directionStr) else {
            return IPCResponse(success: false, error: "invalid direction: \(directionStr)")
        }

        DispatchQueue.main.async { [weak self] in
            let controller: TerminalController?
            if let target = parsed.target {
                self?.pruneStaleTargets()
                controller = self?.targetRegistry[target]?.controller
                if controller == nil {
                    Self.logger.warning("IPC: target '\(target)' not found")
                }
            } else {
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
            if let command = parsed.config.command {
                splitConfig.command = command
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

            // Register pane name after split creation
            if let name = parsed.name, let newSurface = controller.focusedSurface {
                self?.targetRegistry[name] = .pane(
                    controller: WeakRef(controller),
                    surface: WeakRef(newSurface)
                )
                Self.logger.info("IPC: registered pane target '\(name)'")
            }
        }

        return .ok
    }
```

- [ ] **Step 6: Add handleClose and wire into dispatchAction**

Add `"close"` to `dispatchAction`:

```swift
    private func dispatchAction(_ request: IPCRequest) -> IPCResponse {
        switch request.action {
        case "new-window":
            return handleNewWindow(request)
        case "split":
            return handleSplit(request)
        case "close":
            return handleClose(request)
        default:
            return IPCResponse(success: false, error: "unknown action: \(request.action)")
        }
    }
```

Add `handleClose`:

```swift
    private func handleClose(_ request: IPCRequest) -> IPCResponse {
        let parsed: ParsedArguments
        if let arguments = request.arguments {
            parsed = parseArguments(arguments)
        } else {
            parsed = ParsedArguments(config: Ghostty.SurfaceConfiguration())
        }

        guard let target = parsed.target else {
            return IPCResponse(success: false, error: "--target is required for +close")
        }

        pruneStaleTargets()

        guard let entry = targetRegistry[target] else {
            // Idempotent: target doesn't exist (already closed or never created)
            return .ok
        }

        DispatchQueue.main.async { [weak self] in
            switch entry {
            case .pane(let controllerRef, let surfaceRef):
                if let controller = controllerRef.value, let surface = surfaceRef.value {
                    controller.closeSurface(surface, withConfirmation: false)
                }
            case .window(let controllerRef):
                controllerRef.value?.closeWindowImmediately()
            }
            self?.targetRegistry.removeValue(forKey: target)
        }

        return .ok
    }
```

- [ ] **Step 7: Commit**

```bash
git add macos/Sources/Features/IPC/IPCServer.swift
git commit -m "feat(macos): unified registry, idempotent commands, +close handler"
```

---

### Task 2: Add `close` IPC Action (Zig)

**Files:**
- Modify: `src/apprt/ipc.zig`
- Modify: `include/ghostty.h`
- Create: `src/cli/close.zig`
- Modify: `src/cli/ghostty.zig`
- Modify: `src/cli/split.zig`
- Modify: `src/apprt/embedded.zig`

- [ ] **Step 1: Add Close to ipc.zig**

After `split: Split,` add: `close: Close,`

After the `Split` struct, add:

```zig
    pub const Close = struct {
        arguments: ?[][:0]const u8,

        pub const C = extern struct {
            arguments: ?[*]?[*:0]const u8,

            pub fn deinit(self: *Close.C, alloc: Allocator) void {
                if (self.arguments) |arguments| alloc.free(arguments);
            }
        };

        pub fn cval(self: *Close, alloc: Allocator) Allocator.Error!Close.C {
            var result: Close.C = undefined;
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

In the `Key` enum, after `split,` add: `close,`

- [ ] **Step 2: Update ghostty.h**

After `ghostty_ipc_action_split_s`, add:

```c
typedef struct {
  const char **arguments;
} ghostty_ipc_action_close_s;
```

Update the union:

```c
typedef union {
  ghostty_ipc_action_new_window_s new_window;
  ghostty_ipc_action_split_s split;
  ghostty_ipc_action_close_s close;
} ghostty_ipc_action_u;
```

Update the enum:

```c
typedef enum {
  GHOSTTY_IPC_ACTION_NEW_WINDOW,
  GHOSTTY_IPC_ACTION_SPLIT,
  GHOSTTY_IPC_ACTION_CLOSE,
} ghostty_ipc_action_tag_e;
```

- [ ] **Step 3: Create close.zig**

Create `src/cli/close.zig`:

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Action = @import("../cli.zig").ghostty.Action;
const apprt = @import("../apprt.zig");
const args = @import("args.zig");
const diagnostics = @import("diagnostics.zig");

pub const Options = struct {
    _arena: ?ArenaAllocator = null,
    _arguments: std.ArrayList([:0]const u8) = .empty,
    _diagnostics: diagnostics.DiagnosticList = .{},

    pub fn parseManuallyHook(self: *Options, alloc: Allocator, arg: []const u8, iter: anytype) (error{InvalidValue} || Allocator.Error)!bool {
        if (try self.checkArg(alloc, arg)) |a| try self._arguments.append(alloc, a);
        while (iter.next()) |param| {
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

/// The `close` command will use native platform IPC to close a named
/// pane or window in a running Ghostty instance.
///
/// The command is idempotent — closing a target that doesn't exist
/// (or was already closed) is a no-op and returns success.
///
/// Flags:
///
///   * `--target=<name>`: The name of the pane or window to close.
///     Required. The target must have been created with
///     `+new-window --target=<name>` or `+split --name=<name>`.
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
        .close,
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

    try stderr.print("+close is not supported on this platform.\n", .{});
    return 1;
}
```

- [ ] **Step 4: Register close in ghostty.zig**

Add import after `const split = ...`:

```zig
const close = @import("close.zig");
```

Add to Action enum after `split,`:

```zig
    // Use IPC to close a named pane or window.
    close,
```

Add to `runMain` after `.split => ...`:

```zig
            .close => try close.run(alloc),
```

Add to `options` function (if it exists) after the split entry — search for where `split.Options` appears and add `.close => close.Options,` after it.

- [ ] **Step 5: Add ipcClose to embedded.zig**

Update `performIpc` switch:

```zig
        switch (action) {
            .new_window => return ipcNewWindow(alloc, value),
            .split => return ipcSplit(alloc, value),
            .close => return ipcClose(alloc, value),
        }
```

Add `ipcClose` function after `ipcSplit`. It follows the same socket IPC pattern, sending `"close"` as the action:

```zig
    fn ipcClose(
        alloc: Allocator,
        value: apprt.ipc.Action.Close,
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
        jws.write("close") catch return error.IPCFailed;

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

- [ ] **Step 6: Update split.zig docstring**

In `src/cli/split.zig`, add `--name` to the docstring flags section (after the `--direction` bullet):

```zig
///   * `--name=<name>`: Register this split pane with a name for later
///     targeting. If a pane with this name already exists, it will be
///     focused instead of creating a new split.
///
```

- [ ] **Step 7: Commit**

```bash
git add src/apprt/ipc.zig include/ghostty.h src/cli/close.zig src/cli/ghostty.zig src/cli/split.zig src/apprt/embedded.zig
git commit -m "feat: add +close IPC action and --name flag for pane targeting"
```

---

### Task 3: Build and Test

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

- [ ] **Step 3: Test idempotent new-window**

```bash
# First call creates window
./zig-out/Ghostty.app/Contents/MacOS/ghostty +new-window --target=dev --command=bash
sleep 1

# Second call should focus existing window (not create new one)
./zig-out/Ghostty.app/Contents/MacOS/ghostty +new-window --target=dev --command=bash
```

Expected: Only one "dev" window exists. Second call focuses it.

- [ ] **Step 4: Test idempotent named split**

```bash
# First call creates split
./zig-out/Ghostty.app/Contents/MacOS/ghostty +split --target=dev --name=server --direction=right --command="echo server"
sleep 1

# Second call should focus existing pane (not create another split)
./zig-out/Ghostty.app/Contents/MacOS/ghostty +split --target=dev --name=server --direction=right --command="echo server"
```

Expected: Only one "server" pane exists. Second call focuses it.

- [ ] **Step 5: Test close pane**

```bash
./zig-out/Ghostty.app/Contents/MacOS/ghostty +close --target=server
```

Expected: The "server" pane closes. The "dev" window remains with one pane.

- [ ] **Step 6: Test close window**

```bash
./zig-out/Ghostty.app/Contents/MacOS/ghostty +close --target=dev
```

Expected: The entire "dev" window closes.

- [ ] **Step 7: Test idempotent close (already closed)**

```bash
./zig-out/Ghostty.app/Contents/MacOS/ghostty +close --target=dev
echo "Exit: $?"
```

Expected: Exit code 0. No error (target already gone — idempotent).

- [ ] **Step 8: Test full re-runnable workspace script**

```bash
# Run the full setup
./zig-out/Ghostty.app/Contents/MacOS/ghostty +new-window --target=workspace --command=bash
./zig-out/Ghostty.app/Contents/MacOS/ghostty +split --target=workspace --name=editor --direction=right --command="echo editor"
./zig-out/Ghostty.app/Contents/MacOS/ghostty +split --target=workspace --name=tests --direction=down --command="echo tests"

sleep 2

# Run it again — should just focus everything, not create duplicates
./zig-out/Ghostty.app/Contents/MacOS/ghostty +new-window --target=workspace --command=bash
./zig-out/Ghostty.app/Contents/MacOS/ghostty +split --target=workspace --name=editor --direction=right --command="echo editor"
./zig-out/Ghostty.app/Contents/MacOS/ghostty +split --target=workspace --name=tests --direction=down --command="echo tests"
```

Expected: Still only one window with three panes after the second run.

- [ ] **Step 9: Commit any fixes**

```bash
git add -u
git commit -m "fix: address issues found during idempotent IPC testing"
```

---

## Implementation Notes

### Registry Design

The unified `TargetEntry` enum replaces the old `WeakController` struct:
- `.window(WeakRef<TerminalController>)` — a named window
- `.pane(controller: WeakRef<TerminalController>, surface: WeakRef<Ghostty.SurfaceView>)` — a named pane within a window

Both use `WeakRef<T>`, a simple class wrapper around a weak reference. This must be a class (not struct) because Swift structs can't have weak stored properties without a class wrapper.

### Pane Registration Timing

After posting `ghosttyNewSplit`, the notification handler in `BaseTerminalController` creates the new surface synchronously and moves focus to it. So immediately after the post, `controller.focusedSurface` returns the NEW surface — this is what we register.

### Close Semantics

- `+close --target=server` (pane name) → calls `controller.closeSurface(surface, withConfirmation: false)`
- `+close --target=dev` (window name) → calls `controller.closeWindowImmediately()`
- `+close --target=nonexistent` → returns `.ok` (idempotent, already gone)

`withConfirmation: false` skips the "process still running" dialog since this is a programmatic close.

### Namespace

Window names and pane names share a single namespace. A name refers to exactly one thing. If a user creates `+new-window --target=foo` and then `+split --name=foo`, the second registration overwrites the first (last write wins).
