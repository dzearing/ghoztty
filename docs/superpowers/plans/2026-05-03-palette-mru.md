# Command Palette MRU Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "Recent" section to the command palette showing the 10 most recently used commands, with section headers and proper keyboard navigation.

**Architecture:** A partial implementation already exists on this branch — `PaletteHistory.swift` (persistence), `commandIdentifier` on `CommandOption`, MRU sorting in `TerminalCommandPalette`, and usage recording for terminal commands. The remaining work introduces section headers into the palette UI, caps the recent list to 10, and ensures keyboard navigation skips headers. Jump-to-surface commands are not tracked because they are ephemeral (they depend on which windows/surfaces are currently open and have no stable identifier across sessions).

**Tech Stack:** SwiftUI, macOS, GhosttyKit

---

## File Structure

- **Modify:** `macos/Sources/Features/Command Palette/CommandPalette.swift` — add `CommandPaletteSection` model, section header rendering in `CommandTable`, keyboard navigation that skips headers, flat-list behavior when query is non-empty
- **Modify:** `macos/Sources/Features/Command Palette/TerminalCommandPalette.swift` — cap recent to 10, emit sections instead of a flat list
- **Modify:** `macos/Sources/Features/Command Palette/PaletteHistory.swift` — add `recentIdentifiers(limit:)` method

---

### Task 1: Add `recentIdentifiers(limit:)` to PaletteHistory

**Files:**
- Modify: `macos/Sources/Features/Command Palette/PaletteHistory.swift`

- [ ] **Step 1: Add the method**

Add this method to `PaletteHistory` after the existing `recordUsage` method:

```swift
func recentIdentifiers(limit: Int = 10) -> [String] {
    history
        .sorted { $0.value > $1.value }
        .prefix(limit)
        .map(\.key)
}
```

This returns the top N action strings sorted by most recent first.

- [ ] **Step 2: Build and verify**

Run: `cd macos && xcodebuild build -scheme Ghostty -configuration Debug -destination 'platform=macOS' 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add "macos/Sources/Features/Command Palette/PaletteHistory.swift"
git commit -m "feat(palette): add recentIdentifiers method to PaletteHistory"
```

---

### Task 2: Introduce `CommandPaletteSection` and section-aware `CommandPaletteView`

This is the core UI change. We introduce a section model and modify `CommandPaletteView` to accept sections, render headers, and flatten during search.

**Files:**
- Modify: `macos/Sources/Features/Command Palette/CommandPalette.swift`

- [ ] **Step 1: Add `CommandPaletteSection` struct**

Add this struct at the top of `CommandPalette.swift`, before `CommandPaletteView`:

```swift
struct CommandPaletteSection {
    let title: String?
    let options: [CommandOption]
}
```

- [ ] **Step 2: Change `CommandPaletteView` to accept sections**

Replace the `options` property on `CommandPaletteView`:

```swift
// Replace:
var options: [CommandOption]

// With:
var sections: [CommandPaletteSection]
```

Add a computed property for all options flattened (used during search):

```swift
private var allOptions: [CommandOption] {
    sections.flatMap(\.options)
}
```

- [ ] **Step 3: Update `filteredOptions` to use `allOptions`**

In the `filteredOptions` computed property, change the `query.isEmpty` branch to return `allOptions` instead of `options`:

```swift
var filteredOptions: [CommandOption] {
    if query.isEmpty {
        return allOptions
    } else {
        let filtered = allOptions.filter {
            $0.title.matchedIndices(for: query) != nil ||
            ($0.subtitle?.matchedIndices(for: query) != nil) ||
            colorMatchScore(for: $0.leadingColor, query: query) > 0
        }

        return filtered.sorted { a, b in
            let scoreA = colorMatchScore(for: a.leadingColor, query: query)
            let scoreB = colorMatchScore(for: b.leadingColor, query: query)
            return scoreA > scoreB
        }
    }
}
```

Note: `filteredOptions` is still used for keyboard navigation index calculations and submit. The section-aware rendering only applies when query is empty.

- [ ] **Step 4: Update `CommandTable` to support sections**

Add a `sections` property to `CommandTable` alongside the existing `options`:

```swift
private struct CommandTable: View {
    var sections: [CommandPaletteSection]
    var options: [CommandOption]
    var query: String
    @Binding var selectedIndex: UInt?
    @Binding var hoveredOptionID: UUID?
    var action: (CommandOption) -> Void
```

When `query` is empty, render sections with headers. When non-empty, render the flat `options` list. Replace the `body` with:

```swift
var body: some View {
    if options.isEmpty && !query.isEmpty {
        Text("No matches")
            .foregroundStyle(.secondary)
            .padding()
    } else {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if query.isEmpty {
                        sectionContent
                    } else {
                        flatContent
                    }
                }
                .padding(10)
            }
            .frame(maxHeight: 200)
            .onChange(of: selectedIndex) { _ in
                guard let selectedIndex,
                      selectedIndex < options.count else { return }
                proxy.scrollTo(
                    options[Int(selectedIndex)].id)
            }
        }
    }
}

@ViewBuilder
private var sectionContent: some View {
    ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
        if !section.options.isEmpty {
            if let title = section.title {
                Text(title)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                    .padding(.bottom, 2)
            }

            ForEach(section.options, id: \.id) { option in
                let index = flatIndex(of: option)
                CommandRow(
                    option: option,
                    query: query,
                    isSelected: isSelected(at: index),
                    hoveredID: $hoveredOptionID
                ) {
                    action(option)
                }
            }
        }
    }
}

@ViewBuilder
private var flatContent: some View {
    ForEach(Array(options.enumerated()), id: \.1.id) { index, option in
        CommandRow(
            option: option,
            query: query,
            isSelected: isSelected(at: index),
            hoveredID: $hoveredOptionID
        ) {
            action(option)
        }
    }
}

private func isSelected(at index: Int) -> Bool {
    guard let selected = selectedIndex else { return false }
    if selected == index { return true }
    if selected >= options.count && index == options.count - 1 { return true }
    return false
}

private func flatIndex(of option: CommandOption) -> Int {
    options.firstIndex(where: { $0.id == option.id }) ?? 0
}
```

- [ ] **Step 5: Update `CommandPaletteView.body` to pass sections to `CommandTable`**

In the `body` of `CommandPaletteView`, update the `CommandTable` call:

```swift
CommandTable(
    sections: sections,
    options: filteredOptions,
    query: query,
    selectedIndex: $selectedIndex,
    hoveredOptionID: $hoveredOptionID) { option in
        isPresented = false
        option.action()
}
```

- [ ] **Step 6: Build and verify**

Run: `cd macos && xcodebuild build -scheme Ghostty -configuration Debug -destination 'platform=macOS' 2>&1 | tail -5`
Expected: Build will fail because `TerminalCommandPaletteView` still passes `options:` — that's fixed in the next task.

- [ ] **Step 7: Commit work-in-progress**

```bash
git add "macos/Sources/Features/Command Palette/CommandPalette.swift"
git commit -m "feat(palette): add section support to CommandPaletteView and CommandTable"
```

---

### Task 3: Emit sections from `TerminalCommandPaletteView`

**Files:**
- Modify: `macos/Sources/Features/Command Palette/TerminalCommandPalette.swift`

- [ ] **Step 1: Change `commandOptions` to `commandSections` returning `[CommandPaletteSection]`**

Replace the `commandOptions` computed property with:

```swift
private var commandSections: [CommandPaletteSection] {
    var sections: [CommandPaletteSection] = []

    let updates = updateOptions
    if !updates.isEmpty {
        sections.append(CommandPaletteSection(title: nil, options: updates))
    }

    let rest = jumpOptions + terminalOptions

    let defaultSorted = rest.sorted { a, b in
        let aNormalized = a.title.replacingOccurrences(of: ":", with: "\t")
        let bNormalized = b.title.replacingOccurrences(of: ":", with: "\t")
        let comparison = aNormalized.localizedCaseInsensitiveCompare(bNormalized)
        if comparison != .orderedSame {
            return comparison == .orderedAscending
        }
        if let aSortKey = a.sortKey, let bSortKey = b.sortKey {
            return aSortKey < bSortKey
        }
        return false
    }

    let recentIds = PaletteHistory.shared.recentIdentifiers(limit: 10)
    let recentOptions = recentIds.compactMap { id in
        defaultSorted.first { $0.commandIdentifier == id }
    }

    if !recentOptions.isEmpty {
        sections.append(CommandPaletteSection(title: "Recent", options: recentOptions))
    }

    sections.append(CommandPaletteSection(title: recentOptions.isEmpty ? nil : "All Commands", options: defaultSorted))

    return sections
}
```

Key changes from the current `commandOptions`:
- Returns sections instead of a flat list
- Uses `recentIdentifiers(limit: 10)` to cap to 10
- Uses `compactMap` over the ordered identifiers to preserve recency order and skip stale entries
- "All Commands" section contains all commands (including those in Recent) so users always find them in the expected position
- "All Commands" header only shown when there's a Recent section

- [ ] **Step 2: Update the `CommandPaletteView` call site**

In the `body`, change:

```swift
// From:
CommandPaletteView(
    isPresented: $isPresented,
    backgroundColor: ghosttyConfig.backgroundColor,
    options: commandOptions
)

// To:
CommandPaletteView(
    isPresented: $isPresented,
    backgroundColor: ghosttyConfig.backgroundColor,
    sections: commandSections
)
```

- [ ] **Step 3: Build and verify**

Run: `cd macos && xcodebuild build -scheme Ghostty -configuration Debug -destination 'platform=macOS' 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Manual test**

1. Launch the app
2. Open the command palette — should show only "All Commands" (no Recent section yet, no header since no recents)
3. Select a command (e.g. "New Tab")
4. Reopen the palette — "Recent" section should appear at top with that command
5. Use several more commands, reopen — Recent section should show them in reverse chronological order
6. Use more than 10 distinct commands — Recent section should cap at 10
7. Type a search query — section headers disappear, results filter as before
8. Clear the query — sections reappear
9. Verify keyboard navigation (arrow keys, Ctrl+N/P) skips section headers and only selects command rows

- [ ] **Step 5: Commit**

```bash
git add "macos/Sources/Features/Command Palette/TerminalCommandPalette.swift"
git commit -m "feat(palette): emit Recent and All Commands sections with 10-item cap"
```

---

### Task 4: Verify `palette-history.json` persistence

**Files:** None — this is a verification-only task.

- [ ] **Step 1: Check the JSON file was created**

After using a few palette commands in the manual test above:

```bash
cat ~/.config/ghostty/palette-history.json | python3 -m json.tool
```

Expected: A JSON object with action strings as keys and Unix timestamps (floats) as values.

- [ ] **Step 2: Verify persistence across app restart**

1. Quit the app
2. Relaunch
3. Open command palette — Recent section should still show previously used commands

- [ ] **Step 3: Verify graceful degradation**

1. Rename `palette-history.json` to `palette-history.json.bak`
2. Open palette — no Recent section, no errors
3. Use a command — `palette-history.json` is recreated
4. Restore backup: `mv ~/.config/ghostty/palette-history.json.bak ~/.config/ghostty/palette-history.json`

- [ ] **Step 4: Final commit (squash or clean up if needed)**

If any fixes were needed during verification, commit them:

```bash
git add -A
git commit -m "fix(palette): address issues found during MRU verification"
```
