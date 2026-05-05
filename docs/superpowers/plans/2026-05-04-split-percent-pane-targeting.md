# Split Percentage & Pane Targeting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow IPC `+split` and `+new-window` commands to specify a split ratio via `--percent`/`--split-percent`, and allow `+split` to target a specific named pane via `--pane`.

**Architecture:** Thread a `ratio: Double` parameter from `SplitTree.inserting()` up through `BaseTerminalController.newSplit()` to `IPCServer.handleSplit()`/`handleNewWindow()`. Add `percent` and `pane` fields to `ParsedArguments`. Validate percent (1–99), convert to ratio (clamped 0.1–0.9), and resolve `--pane` names against `targetRegistry`.

**Tech Stack:** Swift (macOS app), Zig (CLI), Swift Testing framework

---

### Task 1: Add `ratio` parameter to `SplitTree.inserting()`

**Files:**
- Modify: `macos/Sources/Features/Splits/SplitTree.swift:125-130` (tree-level `inserting`)
- Modify: `macos/Sources/Features/Splits/SplitTree.swift:512-549` (node-level `inserting`)
- Test: `macos/Tests/Splits/SplitTreeTests.swift`

- [ ] **Step 1: Write a failing test for `inserting` with custom ratio**

Add to `SplitTreeTests.swift` at the end of the "Removing and Replacing" section (after the existing inserting tests):

```swift
@Test func insertingWithCustomRatio() throws {
    let view1 = MockView()
    let view2 = MockView()
    var tree = SplitTree<MockView>(view: view1)
    tree = try tree.inserting(view: view2, at: view1, direction: .right, ratio: 0.7)

    guard case .split(let split) = tree.root else {
        Issue.record("Expected split node")
        return
    }
    #expect(split.ratio == 0.7)
}

@Test func insertingWithDefaultRatioIsHalf() throws {
    let view1 = MockView()
    let view2 = MockView()
    var tree = SplitTree<MockView>(view: view1)
    tree = try tree.inserting(view: view2, at: view1, direction: .right)

    guard case .split(let split) = tree.root else {
        Issue.record("Expected split node")
        return
    }
    #expect(split.ratio == 0.5)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project macos/Ghostty.xcodeproj -scheme Ghostty -only-testing:"GhosttyTests/SplitTreeTests/insertingWithCustomRatio" -only-testing:"GhosttyTests/SplitTreeTests/insertingWithDefaultRatioIsHalf" 2>&1 | tail -20`
Expected: compilation error — `inserting` does not accept `ratio` parameter

- [ ] **Step 3: Add `ratio` parameter to tree-level `inserting`**

In `macos/Sources/Features/Splits/SplitTree.swift`, replace the tree-level method (lines 123–130):

```swift
/// Insert a new view at the given view point by creating a split in the given direction.
/// This will always reset the zoomed state of the tree.
func inserting(view: ViewType, at: ViewType, direction: NewDirection, ratio: Double = 0.5) throws -> Self {
    guard let root else { throw SplitError.viewNotFound }
    return .init(
        root: try root.inserting(view: view, at: at, direction: direction, ratio: ratio),
        zoomed: nil)
}
```

- [ ] **Step 4: Add `ratio` parameter to node-level `inserting`**

In `macos/Sources/Features/Splits/SplitTree.swift`, replace the node-level method signature and the hardcoded ratio (lines 500–549):

```swift
/// Inserts a new view into the split tree by creating a split at the location of an existing view.
///
/// This method creates a new split node containing both the existing view and the new view,
/// The position of the new view relative to the existing view is determined by the direction parameter.
///
/// - Parameters:
///   - view: The new view to insert into the tree
///   - at: The existing view at whose location the split should be created
///   - direction: The direction relative to the existing view where the new view should be placed
///   - ratio: The proportion allocated to the left/top child (0.0–1.0, default 0.5)
///
/// - Note: If the existing view (`at`) is not found in the tree, this method does nothing. We should
/// maybe throw instead but at the moment we just do nothing.
func inserting(view: ViewType, at: ViewType, direction: NewDirection, ratio: Double = 0.5) throws -> Self {
    // Get the path to our insertion point. If it doesn't exist we do
    // nothing.
    guard let path = path(to: .leaf(view: at)) else {
        throw SplitError.viewNotFound
    }

    // Determine split direction and which side the new view goes on
    let splitDirection: SplitTree.Direction
    let newViewOnLeft: Bool
    switch direction {
    case .left:
        splitDirection = .horizontal
        newViewOnLeft = true
    case .right:
        splitDirection = .horizontal
        newViewOnLeft = false
    case .up:
        splitDirection = .vertical
        newViewOnLeft = true
    case .down:
        splitDirection = .vertical
        newViewOnLeft = false
    }

    // Create the new split node
    let newNode: Node = .leaf(view: view)
    let existingNode: Node = .leaf(view: at)
    let newSplit: Node = .split(.init(
        direction: splitDirection,
        ratio: ratio,
        left: newViewOnLeft ? newNode : existingNode,
        right: newViewOnLeft ? existingNode : newNode
    ))

    // Replace the node at the path with the new split
    return try replacingNode(at: path, with: newSplit)
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test -project macos/Ghostty.xcodeproj -scheme Ghostty -only-testing:"GhosttyTests/SplitTreeTests" 2>&1 | tail -20`
Expected: all SplitTree tests PASS (new ones + all existing ones unchanged)

- [ ] **Step 6: Commit**

```bash
git add macos/Sources/Features/Splits/SplitTree.swift macos/Tests/Splits/SplitTreeTests.swift
git commit -m "feat(splits): add ratio parameter to SplitTree.inserting()"
```

---

### Task 2: Thread `ratio` through `BaseTerminalController.newSplit()`

**Files:**
- Modify: `macos/Sources/Features/Terminal/BaseTerminalController.swift:235-270`

- [ ] **Step 1: Add `ratio` parameter to `newSplit()`**

In `macos/Sources/Features/Terminal/BaseTerminalController.swift`, replace the method (lines 234–270):

```swift
/// Create a new split.
@discardableResult
func newSplit(
    at oldView: Ghostty.SurfaceView,
    direction: SplitTree<Ghostty.SurfaceView>.NewDirection,
    baseConfig config: Ghostty.SurfaceConfiguration? = nil,
    ratio: Double = 0.5
) -> Ghostty.SurfaceView? {
    // We can only create new splits for surfaces in our tree.
    guard surfaceTree.root?.node(view: oldView) != nil else { return nil }

    // Create a new surface view
    guard let ghostty_app = ghostty.app else { return nil }
    let newView = Ghostty.SurfaceView(ghostty_app, baseConfig: config)

    // Do the split
    let newTree: SplitTree<Ghostty.SurfaceView>
    do {
        newTree = try surfaceTree.inserting(
            view: newView,
            at: oldView,
            direction: direction,
            ratio: ratio)
    } catch {
        // If splitting fails for any reason (it should not), then we just log
        // and return. The new view we created will be deinitialized and its
        // no big deal.
        Ghostty.logger.warning("failed to insert split: \(error)")
        return nil
    }

    replaceSurfaceTree(
        newTree,
        moveFocusTo: newView,
        moveFocusFrom: oldView,
        undoAction: "New Split")

    return newView
}
```

- [ ] **Step 2: Verify existing tests still pass**

Run: `xcodebuild test -project macos/Ghostty.xcodeproj -scheme Ghostty -only-testing:"GhosttyTests/SplitTreeTests" 2>&1 | tail -20`
Expected: all tests PASS (default parameter means no callers need updating)

- [ ] **Step 3: Commit**

```bash
git add macos/Sources/Features/Terminal/BaseTerminalController.swift
git commit -m "feat(splits): thread ratio parameter through BaseTerminalController.newSplit()"
```

---

### Task 3: Add `percent` and `pane` to `ParsedArguments` and `parseArguments()`

**Files:**
- Modify: `macos/Sources/Features/IPC/IPCServer.swift:249-256` (ParsedArguments)
- Modify: `macos/Sources/Features/IPC/IPCServer.swift:448-510` (parseArguments)

- [ ] **Step 1: Add fields to `ParsedArguments`**

In `macos/Sources/Features/IPC/IPCServer.swift`, replace the struct (lines 249–256):

```swift
struct ParsedArguments {
    var config: Ghostty.SurfaceConfiguration
    var splitDirection: String?
    var splitCommand: String?
    var target: String?
    var name: String?
    var title: String?
    var percent: Int?
    var pane: String?
}
```

- [ ] **Step 2: Parse `--percent`, `--split-percent`, and `--pane` in `parseArguments()`**

In `macos/Sources/Features/IPC/IPCServer.swift`, add three new argument parsers inside the `for arg in arguments` loop in `parseArguments()`, after the `--title=` block (after line 501):

```swift
if let value = arg.dropPrefix("--percent=") {
    result.percent = Int(value)
    continue
}

if let value = arg.dropPrefix("--split-percent=") {
    result.percent = Int(value)
    continue
}

if let value = arg.dropPrefix("--pane=") {
    result.pane = String(value)
    continue
}
```

- [ ] **Step 3: Verify the project compiles**

Run: `xcodebuild build -project macos/Ghostty.xcodeproj -scheme Ghostty 2>&1 | tail -10`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add macos/Sources/Features/IPC/IPCServer.swift
git commit -m "feat(ipc): add percent and pane fields to ParsedArguments"
```

---

### Task 4: Wire `percent` and `pane` into `handleSplit()`

**Files:**
- Modify: `macos/Sources/Features/IPC/IPCServer.swift:323-398` (handleSplit)

- [ ] **Step 1: Add percent validation and pane targeting to `handleSplit()`**

In `macos/Sources/Features/IPC/IPCServer.swift`, replace `handleSplit()` (lines 323–398):

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

    // Validate percent if provided
    let ratio: Double
    if let percent = parsed.percent {
        guard (1...99).contains(percent) else {
            return IPCResponse(success: false, error: "percent must be between 1 and 99, got \(percent)")
        }
        ratio = min(0.9, max(0.1, Double(percent) / 100.0))
    } else {
        ratio = 0.5
    }

    // Resolve --pane targeting: find the named pane's surface and controller
    if let paneName = parsed.pane {
        pruneStaleTargets()
        guard let entry = targetRegistry[paneName] else {
            return IPCResponse(success: false, error: "pane '\(paneName)' not found")
        }
        guard let surface = entry.surfaceView, let controller = entry.controller else {
            return IPCResponse(success: false, error: "pane '\(paneName)' not found")
        }

        let directionStr = parsed.splitDirection ?? "right"
        guard let direction = Self.parseSplitDirection(directionStr) else {
            return IPCResponse(success: false, error: "invalid direction: \(directionStr)")
        }

        DispatchQueue.main.async { [weak self] in
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

            let newView = controller.newSplit(
                at: surface,
                direction: direction,
                baseConfig: splitConfig,
                ratio: ratio
            )

            if let name = parsed.name, let newView {
                self?.targetRegistry[name] = .pane(
                    controller: WeakRef(controller),
                    surface: WeakRef(newView)
                )
                Self.logger.info("IPC: registered pane target '\(name)'")
            }
        }

        return .ok
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

        let newView = controller.newSplit(
            at: surfaceView,
            direction: direction,
            baseConfig: splitConfig,
            ratio: ratio
        )

        if let name = parsed.name, let newView {
            self?.targetRegistry[name] = .pane(
                controller: WeakRef(controller),
                surface: WeakRef(newView)
            )
            Self.logger.info("IPC: registered pane target '\(name)'")
        }
    }

    return .ok
}
```

- [ ] **Step 2: Verify the project compiles**

Run: `xcodebuild build -project macos/Ghostty.xcodeproj -scheme Ghostty 2>&1 | tail -10`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add macos/Sources/Features/IPC/IPCServer.swift
git commit -m "feat(ipc): wire percent and pane targeting into handleSplit()"
```

---

### Task 5: Wire `percent` into `handleNewWindow()`

**Files:**
- Modify: `macos/Sources/Features/IPC/IPCServer.swift:258-321` (handleNewWindow)

- [ ] **Step 1: Add percent validation and ratio passthrough to `handleNewWindow()`**

In `macos/Sources/Features/IPC/IPCServer.swift`, replace `handleNewWindow()` (lines 258–321):

```swift
private func handleNewWindow(_ request: IPCRequest) -> IPCResponse {
    let parsed: ParsedArguments
    if let arguments = request.arguments {
        parsed = parseArguments(arguments)
    } else {
        parsed = ParsedArguments(config: Ghostty.SurfaceConfiguration())
    }

    // Validate percent if provided
    let ratio: Double
    if let percent = parsed.percent {
        guard (1...99).contains(percent) else {
            return IPCResponse(success: false, error: "percent must be between 1 and 99, got \(percent)")
        }
        ratio = min(0.9, max(0.1, Double(percent) / 100.0))
    } else {
        ratio = 0.5
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

        if let title = parsed.title {
            controller.titleOverride = title
        }

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

                let newView = controller.newSplit(
                    at: surfaceView,
                    direction: direction,
                    baseConfig: splitConfig,
                    ratio: ratio
                )

                if let name = parsed.name, let newView {
                    self?.targetRegistry[name] = .pane(
                        controller: WeakRef(controller),
                        surface: WeakRef(newView)
                    )
                    Self.logger.info("IPC: registered pane target '\(name)'")
                }
            }
        }
    }

    return .ok
}
```

- [ ] **Step 2: Verify the project compiles**

Run: `xcodebuild build -project macos/Ghostty.xcodeproj -scheme Ghostty 2>&1 | tail -10`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add macos/Sources/Features/IPC/IPCServer.swift
git commit -m "feat(ipc): wire split-percent into handleNewWindow()"
```

---

### Task 6: Update Zig CLI help text

**Files:**
- Modify: `src/cli/split.zig:63-90`
- Modify: `src/cli/new_window.zig:132-158`

- [ ] **Step 1: Update `split.zig` help text**

In `src/cli/split.zig`, replace the doc comment block (lines 63–90) with:

```zig
/// Create a new split pane in a running Ghoztty window.
///
/// If `--target` is specified, the split will be added to the window
/// with that name. If not specified, the split is added to the most
/// recently focused window.
///
/// This command is idempotent: if `--name` is specified and a pane with
/// that name already exists, the existing pane is focused instead of
/// creating a new split.
///
/// Flags:
///
///   * `--target=<name>`: The target window name to add the split to.
///     The target must have been created with `+new-window --target=<name>`.
///
///   * `--name=<name>`: Register this split pane with a name for later
///     targeting. If a pane with this name already exists, it will be
///     focused instead of creating a new split.
///
///   * `--direction=right|down|left|up`: The direction to split. Defaults
///     to `right` if not specified.
///
///   * `--percent=<1-99>`: The percentage of space allocated to the
///     existing pane. Defaults to 50 if not specified. Values outside
///     1-99 return an error.
///
///   * `--pane=<name>`: Split adjacent to the named pane instead of the
///     focused surface. The pane must exist (returns an error if not
///     found). Can be used without `--target` to search across all
///     registered targets.
///
///   * `--command=<command>`: The command to run in the split pane.
///
///   * `-e`: Any arguments after this will be interpreted as a command to
///     execute in the split pane.
///
/// Available since: 1.2.0
```

- [ ] **Step 2: Update `new_window.zig` help text**

In `src/cli/new_window.zig`, replace the Flags section (lines 132–158) with:

```zig
/// Flags:
///
///   * `--class=<class>`: If set, open up a new window in a custom instance of
///     Ghostty. The class must be a valid GTK application ID.
///
///   * `--command`: The command to be executed in the first surface of the new window.
///
///   * `--working-directory=<directory>`: The working directory to pass to Ghoztty.
///
///   * `--title`: A title that will override the title of the first surface in
///     the new window. The title override may be edited or removed later.
///
///   * `-e`: Any arguments after this will be interpreted as a command to
///     execute inside the first surface of the new window instead of the
///     default command.
///
///   * `--target=<name>`: Register this window with a name. If a window
///     with this name already exists, it is focused instead of creating
///     a new one. Named windows can be targeted by `+split` and `+close`.
///
///   * `--split=right|down|left|up`: After creating the new window, create a
///     split in the given direction.
///
///   * `--split-command=<command>`: The command to run in the split pane.
///     Only meaningful when `--split` is also specified.
///
///   * `--split-percent=<1-99>`: The percentage of space allocated to the
///     existing pane when creating the initial split. Defaults to 50.
///     Only meaningful when `--split` is also specified. Values outside
///     1-99 return an error.
///
/// Available since: 1.2.0
```

- [ ] **Step 3: Verify Zig compiles**

Run: `cd /Users/davidzearing/git/ghoztty-split-percent && zig build 2>&1 | tail -10`
Expected: no compilation errors (doc comments don't affect compilation, but verify nothing broke)

- [ ] **Step 4: Commit**

```bash
git add src/cli/split.zig src/cli/new_window.zig
git commit -m "docs(cli): add --percent, --pane, --split-percent to help text"
```

---

### Task 7: Manual integration testing

**Files:** None (testing only)

- [ ] **Step 1: Build the project**

Run: `xcodebuild build -project macos/Ghostty.xcodeproj -scheme Ghostty -configuration Debug 2>&1 | tail -10`
Expected: BUILD SUCCEEDED

- [ ] **Step 2: Run the full test suite**

Run: `xcodebuild test -project macos/Ghostty.xcodeproj -scheme Ghostty 2>&1 | tail -30`
Expected: all tests PASS

- [ ] **Step 3: Test split with default (no percent)**

Start Ghoztty, then run:
```bash
ghoztty +new-window --target=test1
ghoztty +split --target=test1 --direction=right
```
Expected: 50/50 split (existing behavior unchanged)

- [ ] **Step 4: Test split with --percent**

```bash
ghoztty +new-window --target=test2
ghoztty +split --target=test2 --direction=right --percent=70
```
Expected: 70/30 split (left pane gets 70%)

- [ ] **Step 5: Test split with invalid percent**

```bash
ghoztty +split --target=test2 --direction=right --percent=0
ghoztty +split --target=test2 --direction=right --percent=100
ghoztty +split --target=test2 --direction=right --percent=-5
```
Expected: all three return IPC error

- [ ] **Step 6: Test --pane targeting**

```bash
ghoztty +new-window --target=test3
ghoztty +split --target=test3 --direction=right --name=editor
ghoztty +split --pane=editor --direction=down --percent=30
```
Expected: splits the "editor" pane vertically with 30/70 ratio

- [ ] **Step 7: Test --pane with nonexistent name**

```bash
ghoztty +split --pane=nonexistent --direction=right
```
Expected: IPC error — pane not found

- [ ] **Step 8: Test --split-percent in new-window**

```bash
ghoztty +new-window --target=test4 --split=right --split-percent=25
```
Expected: new window with 25/75 split
