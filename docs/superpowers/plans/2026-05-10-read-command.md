# `+read` IPC Command Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `ghoztty +read --name=<pane> --lines=<N>` command that reads the last N lines of terminal output from a named pane and prints them to stdout.

**Architecture:** Zig CLI (`read.zig`) sends `{"action":"read","arguments":[...]}` over the Unix domain socket using direct I/O (same pattern as `+list`). Swift `IPCServer` receives it, reads terminal content via `ghostty_surface_read_text` with `GHOSTTY_POINT_SCREEN`, truncates to the last N lines, and returns the text in the JSON response. No changes to `ipc.zig` or `embedded.zig`.

**Tech Stack:** Zig (CLI), Swift (macOS IPC server), GhosttyKit C API

---

### Task 1: Add `readResult` to Swift IPC message types

**Files:**
- Modify: `macos/Sources/Features/IPC/IPCMessage.swift`

- [ ] **Step 1: Add `ReadResultData` struct and `readResult` case to `IPCData`**

In `macos/Sources/Features/IPC/IPCMessage.swift`, add the struct inside the `IPCData` enum (after `TerminalData`):

```swift
struct ReadResultData: Encodable {
    let text: String
}
```

Add the case to the `IPCData` enum (after `case listState`):

```swift
case readResult(ReadResultData)
```

- [ ] **Step 2: Update `IPCData.encode(to:)` to handle `readResult`**

In the `encode(to:)` method, add a case for `readResult`. The `readResult` case should encode its `text` field directly into the keyed container using a `text` coding key. Add `text` to the `CodingKeys` enum:

```swift
private enum CodingKeys: String, CodingKey {
    case windows
    case text
}

func encode(to encoder: Encoder) throws {
    switch self {
    case .listState(let data):
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(data.windows, forKey: .windows)
    case .readResult(let data):
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(data.text, forKey: .text)
    }
}
```

- [ ] **Step 3: Verify build**

Run: `xcodebuild build -project macos/Ghostty.xcodeproj -scheme Ghostty 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add macos/Sources/Features/IPC/IPCMessage.swift
git commit -m "feat(ipc): add readResult type to IPCData for +read responses"
```

---

### Task 2: Add `handleRead` to Swift IPC server

**Files:**
- Modify: `macos/Sources/Features/IPC/IPCServer.swift`

- [ ] **Step 1: Add `lines` field to `ParsedArguments`**

In `IPCServer.swift`, add to the `ParsedArguments` struct (after `color: String?`):

```swift
var lines: Int?
```

- [ ] **Step 2: Parse `--lines=` in `parseArguments()`**

In the `parseArguments` method, add a clause to parse the `--lines` argument (alongside the existing `--pane=`, `--color=`, etc. clauses):

```swift
if let value = arg.dropPrefix("--lines=") {
    result.lines = Int(value)
    continue
}
```

- [ ] **Step 3: Add `"read"` case to `dispatchAction`**

In the `dispatchAction` method's switch statement, add before the `default` case:

```swift
case "read":
    return handleRead(request)
```

- [ ] **Step 4: Implement `handleRead`**

Add the `handleRead` method to `IPCServer` (after `handleRename`):

```swift
private func handleRead(_ request: IPCRequest) -> IPCResponse {
    let parsed: ParsedArguments
    if let arguments = request.arguments {
        parsed = parseArguments(arguments)
    } else {
        parsed = ParsedArguments(config: Ghostty.SurfaceConfiguration())
    }

    guard let name = parsed.name else {
        return IPCResponse(success: false, error: "--name is required for +read")
    }

    let lineCount = parsed.lines ?? 50

    pruneStaleTargets()

    guard let entry = targetRegistry[name] else {
        return IPCResponse(success: false, error: "pane '\(name)' not found in registry")
    }

    guard let surfaceView = entry.surfaceView else {
        return IPCResponse(success: false, error: "pane '\(name)' is no longer alive")
    }

    var resultText = ""
    let semaphore = DispatchSemaphore(value: 0)

    DispatchQueue.main.async {
        defer { semaphore.signal() }

        guard let surface = surfaceView.surface else { return }

        var text = ghostty_text_s()
        let sel = ghostty_selection_s(
            top_left: ghostty_point_s(
                tag: GHOSTTY_POINT_SCREEN,
                coord: GHOSTTY_POINT_COORD_TOP_LEFT,
                x: 0,
                y: 0),
            bottom_right: ghostty_point_s(
                tag: GHOSTTY_POINT_SCREEN,
                coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
                x: 0,
                y: 0),
            rectangle: false)

        guard ghostty_surface_read_text(surface, sel, &text) else { return }
        defer { ghostty_surface_free_text(surface, &text) }

        let fullText = String(cString: text.text)
        let allLines = fullText.components(separatedBy: "\n")

        // Take the last N lines, dropping any trailing empty line from the split
        let trimmed = allLines.last == "" ? Array(allLines.dropLast()) : allLines
        let lastLines = trimmed.suffix(lineCount)
        resultText = lastLines.joined(separator: "\n")
    }

    semaphore.wait()

    if resultText.isEmpty {
        return IPCResponse(success: false, error: "failed to read terminal content from '\(name)'")
    }

    let data = IPCData.readResult(IPCData.ReadResultData(text: resultText))
    return IPCResponse(success: true, data: data)
}
```

- [ ] **Step 5: Verify build**

Run: `xcodebuild build -project macos/Ghostty.xcodeproj -scheme Ghostty 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 6: Commit**

```bash
git add macos/Sources/Features/IPC/IPCServer.swift
git commit -m "feat(ipc): add handleRead to IPCServer for +read command"
```

---

### Task 3: Create Zig CLI `read.zig`

**Files:**
- Create: `src/cli/read.zig`

- [ ] **Step 1: Create `read.zig`**

Create `src/cli/read.zig` following the `list.zig` pattern (direct socket I/O, JSON response parsing). The file handles:
- Parsing `--name` (required) and `--lines` (default 50) from CLI arguments
- Validating that `--name` is provided
- Connecting to the Unix domain socket
- Sending `{"action":"read","arguments":[...]}` with 4-byte length header
- Reading and parsing the JSON response
- Extracting `data.text` and writing it to stdout
- On error: printing the `error` field to stderr, exiting 1

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Action = @import("../cli.zig").ghostty.Action;
const args = @import("args.zig");
const diagnostics = @import("diagnostics.zig");

pub const Options = struct {
    _arena: ?ArenaAllocator = null,
    _diagnostics: diagnostics.DiagnosticList = .{},
    _arguments: std.ArrayList([:0]const u8) = .empty,

    name: ?[:0]const u8 = null,
    lines: u32 = 50,

    pub fn parseManuallyHook(self: *Options, alloc: Allocator, arg: []const u8, iter: anytype) (error{InvalidValue} || Allocator.Error)!bool {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return true;

        if (std.mem.startsWith(u8, arg, "--name=")) {
            self.name = try alloc.dupeZ(u8, arg["--name=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--lines=")) {
            self.lines = std.fmt.parseInt(u32, arg["--lines=".len..], 10) catch return error.InvalidValue;
        }

        if (try self.checkArg(alloc, arg)) |a| try self._arguments.append(alloc, a);

        while (iter.next()) |param| {
            if (std.mem.startsWith(u8, param, "--name=")) {
                self.name = try alloc.dupeZ(u8, param["--name=".len..]);
            } else if (std.mem.startsWith(u8, param, "--lines=")) {
                self.lines = std.fmt.parseInt(u32, param["--lines=".len..], 10) catch return error.InvalidValue;
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

/// Read the last N lines of terminal output from a named pane in a
/// running Ghoztty instance and print them to stdout.
///
/// The output is plain text with no JSON wrapping or ANSI escape
/// sequences, suitable for piping or capturing in a variable.
///
/// Flags:
///
///   * `--name=<pane>`: The name of the pane to read from. Required.
///     The pane must have been created with `+split --name=<name>` or
///     registered via `+new-window --target=<name>`.
///
///   * `--lines=<N>`: Number of lines to read from the end of the
///     scrollback buffer. Default: 50.
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

    if (opts.name == null) {
        try stderr.print("Error: --name is required for +read\n", .{});
        return 1;
    }

    var arena = ArenaAllocator.init(alloc_gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const resp_body = sendReadQuery(alloc, opts._arguments.items, stderr) catch |err| switch (err) {
        error.NoRunningInstance => {
            try stderr.print("No running Ghoztty instance found.\n", .{});
            return 1;
        },
        error.IPCFailed => return 1,
        else => {
            try stderr.print("IPC query failed: {}\n", .{err});
            return 1;
        },
    };

    // Parse the response to extract text
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, resp_body, .{}) catch {
        try stderr.print("IPC response is not valid JSON\n", .{});
        return 1;
    };
    defer parsed.deinit();

    const data_val = parsed.value.object.get("data") orelse {
        try stderr.print("IPC response missing data field\n", .{});
        return 1;
    };

    const text = switch (data_val) {
        .object => |obj| blk: {
            const t = obj.get("text") orelse break :blk "";
            break :blk switch (t) {
                .string => |s| s,
                else => "",
            };
        },
        else => "",
    };

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    stdout.writeAll(text) catch return 1;
    stdout.writeAll("\n") catch return 1;
    stdout.flush() catch return 1;

    return 0;
}

fn sendReadQuery(
    alloc: Allocator,
    arguments: [][:0]const u8,
    stderr: *std.Io.Writer,
) ![]const u8 {
    const tmpdir = std.posix.getenv("TMPDIR") orelse "/tmp";
    const uid = std.c.getuid();
    const build_config = @import("../build_config.zig");
    const suffix = if (build_config.is_debug) "-debug" else "";
    const sock_path = try std.fmt.allocPrintSentinel(alloc, "{s}ghostty{s}-{d}.sock", .{
        tmpdir, suffix, uid,
    }, 0);
    defer alloc.free(sock_path);

    const fd = connectUnixSocket(sock_path) catch {
        return error.NoRunningInstance;
    };
    defer std.posix.close(fd);

    // Build JSON payload
    var json_buf: std.Io.Writer.Allocating = .init(alloc);
    defer json_buf.deinit();
    var jws: std.json.Stringify = .{ .writer = &json_buf.writer };

    jws.beginObject() catch return error.IPCFailed;
    jws.objectField("action") catch return error.IPCFailed;
    jws.write("read") catch return error.IPCFailed;

    if (arguments.len > 0) {
        jws.objectField("arguments") catch return error.IPCFailed;
        jws.beginArray() catch return error.IPCFailed;
        for (arguments) |arg| {
            jws.write(arg) catch return error.IPCFailed;
        }
        jws.endArray() catch return error.IPCFailed;
    }

    jws.endObject() catch return error.IPCFailed;

    const json_bytes = json_buf.written();

    // Send: 4-byte big-endian length + JSON
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

    // Read response: 4-byte big-endian length + JSON
    var resp_len_bytes: [4]u8 = undefined;
    readFull(fd, &resp_len_bytes) catch {
        stderr.print("Failed to read IPC response length\n", .{}) catch {};
        stderr.flush() catch {};
        return error.IPCFailed;
    };

    const resp_len = std.mem.bigToNative(u32, std.mem.bytesAsValue(u32, &resp_len_bytes).*);
    if (resp_len == 0 or resp_len > 4_194_304) {
        stderr.print("IPC response has invalid length: {d}\n", .{resp_len}) catch {};
        stderr.flush() catch {};
        return error.IPCFailed;
    }

    const resp_buf = try alloc.alloc(u8, resp_len);

    readFull(fd, resp_buf) catch {
        stderr.print("Failed to read IPC response\n", .{}) catch {};
        stderr.flush() catch {};
        return error.IPCFailed;
    };

    // Check success field
    const success_parsed = std.json.parseFromSlice(
        struct { success: bool = false, @"error": ?[]const u8 = null },
        alloc,
        resp_buf,
        .{ .ignore_unknown_fields = true },
    ) catch {
        stderr.print("IPC response is not valid JSON\n", .{}) catch {};
        stderr.flush() catch {};
        return error.IPCFailed;
    };
    defer success_parsed.deinit();

    if (!success_parsed.value.success) {
        if (success_parsed.value.@"error") |err_msg| {
            stderr.print("{s}\n", .{err_msg}) catch {};
            stderr.flush() catch {};
        }
        return error.IPCFailed;
    }

    return resp_buf;
}

fn connectUnixSocket(path: [:0]const u8) !std.posix.fd_t {
    const fd = try std.posix.socket(
        std.posix.AF.UNIX,
        std.posix.SOCK.STREAM,
        0,
    );
    errdefer std.posix.close(fd);

    var addr: std.posix.sockaddr.un = .{ .path = undefined, .family = std.posix.AF.UNIX };
    if (path.len >= addr.path.len) return error.NameTooLong;
    @memcpy(addr.path[0..path.len], path);
    addr.path[path.len] = 0;

    try std.posix.connect(fd, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.un));
    return fd;
}

fn readFull(fd: std.posix.fd_t, buffer: []u8) !void {
    var total: usize = 0;
    while (total < buffer.len) {
        const n = std.posix.read(fd, buffer[total..]) catch |err| return err;
        if (n == 0) return error.EndOfStream;
        total += n;
    }
}
```

- [ ] **Step 2: Verify the file compiles in isolation**

Run: `zig build -Doptimize=Debug 2>&1 | head -20`
Expected: May fail because `ghostty.zig` doesn't import `read.zig` yet. That's fine — next task wires it up.

- [ ] **Step 3: Commit**

```bash
git add src/cli/read.zig
git commit -m "feat(cli): add read.zig for +read IPC command"
```

---

### Task 4: Wire `+read` into the Zig CLI dispatcher

**Files:**
- Modify: `src/cli/ghostty.zig`

- [ ] **Step 1: Add the import**

In `src/cli/ghostty.zig`, add after the `const list = @import("list.zig");` line:

```zig
const read = @import("read.zig");
```

- [ ] **Step 2: Add `read` to the `Action` enum**

Add after the `list` variant (line ~90):

```zig
// Use IPC to read terminal output from a named pane.
read,
```

- [ ] **Step 3: Add description**

In the `description` method, add after the `.list` case:

```zig
.read => "Read terminal output from a pane via IPC",
```

- [ ] **Step 4: Add to `runMain`**

In the `runMain` method, add after `.list`:

```zig
.read => try read.run(alloc),
```

- [ ] **Step 5: Add to `options`**

In the `options` method, add after `.list`:

```zig
.read => read.Options,
```

- [ ] **Step 6: Build**

Run: `zig build -Doptimize=Debug 2>&1 | tail -10`
Expected: BUILD SUCCEEDED (the full project builds with the new action wired in)

- [ ] **Step 7: Verify CLI registration**

Run: `zig-out/bin/ghoztty +read --help 2>&1 | head -5`
Expected: Shows the help text from the doc comment in `read.zig`

- [ ] **Step 8: Commit**

```bash
git add src/cli/ghostty.zig
git commit -m "feat(cli): wire +read action into CLI dispatcher"
```

---

### Task 5: End-to-end test

- [ ] **Step 1: Build the debug app**

Run: `zig build -Doptimize=Debug`

- [ ] **Step 2: Launch the debug app**

Run: `open zig-out/Ghoztty.app`

- [ ] **Step 3: Create a named pane with known content**

```bash
zig-out/bin/ghoztty +new-window --target=readtest --command="bash -c 'for i in $(seq 1 10); do echo line-$i; done; exec bash'"
```

Wait a moment for the output to render.

- [ ] **Step 4: Test `+read` with default lines**

Run: `zig-out/bin/ghoztty +read --name=readtest`
Expected: Shows the last 50 lines (or fewer if the pane has less content), including the `line-1` through `line-10` output.

- [ ] **Step 5: Test `+read` with `--lines`**

Run: `zig-out/bin/ghoztty +read --name=readtest --lines=3`
Expected: Shows only the last 3 lines of output.

- [ ] **Step 6: Test error on missing name**

Run: `zig-out/bin/ghoztty +read 2>&1`
Expected: Exit 1, stderr prints "Error: --name is required for +read"

- [ ] **Step 7: Test error on nonexistent pane**

Run: `zig-out/bin/ghoztty +read --name=nonexistent 2>&1`
Expected: Exit 1, stderr prints "pane 'nonexistent' not found in registry"

- [ ] **Step 8: Test capture into variable**

Run: `output=$(zig-out/bin/ghoztty +read --name=readtest --lines=2) && echo "GOT: $output"`
Expected: Prints `GOT:` followed by the last 2 lines.

- [ ] **Step 9: Clean up**

```bash
zig-out/bin/ghoztty +close --target=readtest
```

- [ ] **Step 10: Commit all remaining changes if any**

Verify `git status` is clean. If not, commit any missed files.
