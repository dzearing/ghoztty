import AppKit
import SwiftUI

/// One setting: label, the doc's summary, the control, and — on hover — a
/// reset button. A dot marks a value that differs from the default; ⓘ shows
/// the full documentation with the key, default and where it's set.
struct SettingsRowView: View {
    @ObservedObject var model: SettingsModel
    let row: SettingRow
    var highlighted: Bool = false
    var query: String = ""

    @State private var hovering = false
    @State private var showingDoc = false

    private var disabledReason: String? {
        guard let condition = row.enabledWhen else { return nil }
        let value = model.value(condition.key)
        if let equals = condition.equals, value != equals { return condition.reason }
        if let limit = condition.lessThan, !((Double(value) ?? limit) < limit) { return condition.reason }
        return nil
    }

    var body: some View {
        let override = model.overridingSource(row.key)
        let reason = disabledReason
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent {
                SettingControl(model: model, row: row)
                    .disabled(reason != nil || override != nil)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        highlightedText(row.label, query)
                        SettingRowAccessories(model: model, key: row.key, hovering: hovering, showingDoc: $showingDoc)
                    }
                    (highlightedText(reason.map { "\($0). " } ?? "", query) + highlightedText(row.hint ?? model.doc(row.key)?.summary ?? "", query))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .opacity(reason == nil ? 1 : 0.55)
            }
            if let override {
                SettingNotice(symbol: "arrow.turn.down.right",
                              text: "Set in \(override.url.lastPathComponent), which loads after your config.",
                              action: ("Open", { NSWorkspace.shared.open(override.url) }))
            }
            if let problem = model.problems[row.key] {
                SettingNotice(symbol: "exclamationmark.triangle.fill", text: problem + " — not saved.", tint: .red)
            }
        }
        .padding(.vertical, 2)
        .background(highlighted ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .onHover { hovering = $0 }
        .id(row.key)
    }
}

/// The modified dot, ⓘ, and ↺ that follow a setting's label.
struct SettingRowAccessories: View {
    @ObservedObject var model: SettingsModel
    let key: String
    var hovering: Bool
    @Binding var showingDoc: Bool

    var body: some View {
        if model.isModified(key) {
            Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                .help("Changed from the default")
                .accessibilityLabel("Changed from the default")
        }
        Button { showingDoc.toggle() } label: {
            Image(systemName: "info.circle")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(showingDoc ? Color.accentColor : .secondary)
        .help("Documentation for \(key)")
        .popover(isPresented: $showingDoc, arrowEdge: .trailing) {
            SettingDocView(model: model, key: key)
        }
        if model.isSetInFile(key) {
            Button { model.reset(key) } label: {
                Image(systemName: "arrow.uturn.backward.circle")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.accentColor)
            .opacity(hovering ? 1 : 0)
            .help("Reset to default (\(model.defaultValue(key).isEmpty ? "unset" : model.defaultValue(key)))")
            .accessibilityLabel("Reset \(key) to default")
        }
    }
}

/// The full documentation for one key.
struct SettingDocView: View {
    @ObservedObject var model: SettingsModel
    let key: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(key).font(.system(.body, design: .monospaced)).bold()
                Spacer()
                if model.isSetInFile(key) {
                    Text("Set in your config").font(.caption).padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.15), in: Capsule()).foregroundStyle(Color.accentColor)
                } else if model.isModified(key) {
                    Text("Set in another file").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Default").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Default:").foregroundStyle(.secondary)
                Text(model.defaultValue(key).isEmpty ? "(unset)" : model.defaultValue(key))
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
            .font(.caption)
            ScrollView {
                Text(model.doc(key)?.doc ?? "No documentation.")
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 320)
            if model.isSetInFile(key) {
                HStack {
                    Spacer()
                    Button("Reset to Default") { model.reset(key) }
                }
            }
        }
        .padding(14)
        .frame(width: 440)
    }
}

/// An inline note under a row (an override elsewhere, or a rejected value).
struct SettingNotice: View {
    let symbol: String
    let text: String
    var tint: Color = .orange
    var action: (String, () -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
            Text(text).fixedSize(horizontal: false, vertical: true)
            if let action {
                Button(action.0, action: action.1).buttonStyle(.link)
            }
        }
        .font(.caption)
        .foregroundStyle(tint)
    }
}

func highlightedText(_ text: String, _ query: String) -> Text {
    guard !query.isEmpty, let range = text.range(of: query, options: .caseInsensitive) else { return Text(text) }
    return Text(text[..<range.lowerBound])
        + Text(text[range]).bold().foregroundColor(.accentColor)
        + Text(text[range.upperBound...])
}

// MARK: - Controls

struct SettingControl: View {
    @ObservedObject var model: SettingsModel
    let row: SettingRow

    var body: some View {
        switch row.control {
        case .toggle:
            Toggle("", isOn: Binding(
                get: { model.value(row.key) == "true" },
                set: { model.set(row.key, $0 ? "true" : "false") }))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)

        case .picker(let options):
            Picker("", selection: choice) {
                ForEach(allOptions(options), id: \.0) { Text($0.1).tag($0.0) }
            }
            .labelsHidden()
            .fixedSize()

        case .segmented(let options):
            Picker("", selection: choice) {
                ForEach(allOptions(options), id: \.0) { Text($0.1).tag($0.0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()

        case .slider(let min, let max, let step, let percent, let inverted):
            SliderControl(model: model, key: row.key, range: min...max, step: step, percent: percent, inverted: inverted)

        case .stepper(let min, let max, let step, let unit):
            NumberControl(model: model, key: row.key, range: min...max, step: step, unit: unit)

        case .megabytes(let max):
            MegabytesControl(model: model, key: row.key, max: max)

        case .color(let noneLabel):
            ColorControl(model: model, key: row.key, noneLabel: noneLabel)

        case .text(let placeholder):
            CommitTextField(model: model, key: row.key, placeholder: placeholder)

        case .font:
            FontControl(model: model)

        case .list(let placeholder):
            ListControl(model: model, key: row.key, placeholder: placeholder)

        case .flags:
            FlagsControl(model: model, key: row.key)

        case .shell(let scripted):
            ShellControl(model: model, key: row.key, scripted: scripted)

        case .folder:
            FolderControl(model: model, key: row.key)
        }
    }

    /// The selection, where "" means unset (the default) and choosing it
    /// removes the key rather than writing an empty value.
    private var choice: Binding<String> {
        Binding(
            get: {
                let value = model.value(row.key)
                return model.isSetInFile(row.key) || !row.curatedOptions.isEmpty ? value : value
            },
            set: { newValue in
                if newValue.isEmpty { model.reset(row.key) } else { model.set(row.key, newValue) }
            })
    }

    /// Curated options, then any schema option without a curated label (so a
    /// new enum value still appears), then the current value if it's neither.
    private func allOptions(_ curated: [(String, String)]) -> [(String, String)] {
        var out = curated
        for option in model.doc(row.key)?.options ?? [] where !out.contains(where: { $0.0 == option }) {
            if model.doc(row.key)?.kind == .enum { out.append((option, option)) }
        }
        let current = model.value(row.key)
        if !out.contains(where: { $0.0 == current }) { out.append((current, current.isEmpty ? "Default" : current)) }
        return out
    }
}

/// A slider that previews while dragging and writes once on release.
private struct SliderControl: View {
    @ObservedObject var model: SettingsModel
    let key: String
    let range: ClosedRange<Double>
    let step: Double
    let percent: Bool
    let inverted: Bool
    @State private var dragging: Double?

    var body: some View {
        let current = dragging ?? Double(model.value(key)) ?? range.lowerBound
        HStack(spacing: 8) {
            Slider(value: Binding(get: { current }, set: { dragging = $0 }), in: range, step: step) { editing in
                if !editing, let value = dragging {
                    model.set(key, Self.format(value))
                    dragging = nil
                }
            }
            .frame(width: 160)
            Text(label(current)).monospacedDigit().foregroundStyle(.secondary).frame(width: 42, alignment: .trailing)
        }
    }

    private func label(_ value: Double) -> String {
        guard percent else { return Self.format(value) }
        return "\(Int(((inverted ? 1 - value : value) * 100).rounded()))%"
    }

    static func format(_ value: Double) -> String {
        var text = String(format: "%.3f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}

/// A number field with a stepper; out-of-range or non-numeric input is
/// shown inline and not written.
private struct NumberControl: View {
    @ObservedObject var model: SettingsModel
    let key: String
    let range: ClosedRange<Double>
    let step: Double
    let unit: String
    @State private var text: String?
    @FocusState private var focused: Bool

    var body: some View {
        let value = Double(model.value(key)) ?? range.lowerBound
        HStack(spacing: 4) {
            TextField("", text: Binding(get: { text ?? Self.format(value) }, set: { text = $0 }))
                .settingsField()
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 64)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { if !$0 { commit() } }
            Stepper("", value: Binding(
                get: { value },
                set: { model.set(key, Self.format(min(range.upperBound, max(range.lowerBound, $0)))) }),
                    in: range, step: step)
                .labelsHidden()
            Text(unit).foregroundStyle(.secondary)
        }
    }

    private func commit() {
        guard let typed = text else { return }
        text = nil
        let trimmed = typed.trimmingCharacters(in: .whitespaces)
        guard let number = Double(trimmed), range.contains(number) else {
            model.problems[key] = "Enter a number from \(Self.format(range.lowerBound)) to \(Self.format(range.upperBound))"
            return
        }
        model.set(key, Self.format(number))
    }

    static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}

private struct MegabytesControl: View {
    @ObservedObject var model: SettingsModel
    let key: String
    let max: Double
    @State private var text: String?
    @FocusState private var focused: Bool

    var body: some View {
        let bytes = Double(model.value(key)) ?? 0
        HStack(spacing: 4) {
            TextField("", text: Binding(get: { text ?? NumberControlFormat.trim(bytes / 1_000_000) }, set: { text = $0 }))
                .settingsField()
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 72)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { if !$0 { commit() } }
            Text("MB per pane").foregroundStyle(.secondary)
        }
    }

    private func commit() {
        guard let typed = text else { return }
        text = nil
        guard let mb = Double(typed.trimmingCharacters(in: .whitespaces)), mb >= 0, mb <= max else {
            model.problems[key] = "Enter a size in megabytes, 0 to \(Int(max))"
            return
        }
        model.set(key, String(Int((mb * 1_000_000).rounded())))
    }
}

enum NumberControlFormat {
    static func trim(_ value: Double) -> String {
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}

/// A color well that writes `#rrggbb` (debounced while the panel is dragged),
/// with a button back to the unset default.
private struct ColorControl: View {
    @ObservedObject var model: SettingsModel
    let key: String
    let noneLabel: String
    @State private var pending: DispatchWorkItem?

    var body: some View {
        let value = model.value(key)
        let color = NSColor(hex: value)
        HStack(spacing: 8) {
            if color == nil {
                Text(noneLabel).foregroundStyle(.secondary)
            } else if model.isSetInFile(key) {
                Button("Use \(noneLabel)") { model.reset(key) }.buttonStyle(.link)
            }
            ColorPicker("", selection: Binding(
                get: { Color(nsColor: color ?? .gray) },
                set: { write(NSColor($0)) }), supportsOpacity: false)
                .labelsHidden()
        }
    }

    private func write(_ color: NSColor) {
        pending?.cancel()
        let hex = color.hexString ?? "#000000"
        let item = DispatchWorkItem { model.set(key, hex) }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: item)
    }
}

/// A text field that writes on Return or when it loses focus.
struct CommitTextField: View {
    @ObservedObject var model: SettingsModel
    let key: String
    var placeholder: String = ""
    var width: CGFloat = 200
    @State private var text: String?
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: Binding(get: { text ?? model.value(key) }, set: { text = $0 }), prompt: Text(placeholder))
            .settingsField()
            .frame(width: width)
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: focused) { if !$0 { commit() } }
    }

    private func commit() {
        guard let typed = text else { return }
        text = nil
        if typed.trimmingCharacters(in: .whitespaces).isEmpty {
            model.reset(key)
        } else if typed != model.value(key) {
            model.set(key, typed)
        }
    }
}

/// The primary font family (fallbacks after it are kept). Lists the
/// installed fixed-pitch families; "Default" removes the key.
private struct FontControl: View {
    @ObservedObject var model: SettingsModel

    static let monospacedFamilies: [String] = {
        let names = NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? []
        let families = Set(names.compactMap { NSFont(name: $0, size: 12)?.familyName })
        return families.filter { !$0.hasPrefix(".") }.sorted()
    }()

    var body: some View {
        let list = model.values("font-family")
        let primary = list.first ?? ""
        let installed = Self.monospacedFamilies
        VStack(alignment: .trailing, spacing: 3) {
            HStack(spacing: 6) {
                Picker("", selection: Binding(
                    get: { primary },
                    set: { family in
                        if family.isEmpty { model.reset("font-family"); return }
                        var fileList = model.file.values(for: "font-family")
                        if fileList.isEmpty { fileList = [family] } else { fileList[0] = family }
                        model.setList("font-family", fileList)
                    })) {
                    Text("Default (JetBrains Mono)").tag("")
                    Divider()
                    ForEach(installed, id: \.self) { Text($0).font(.custom($0, size: 13)).tag($0) }
                    if !primary.isEmpty && !installed.contains(primary) {
                        Text("\(primary) (not installed)").tag(primary)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 240)
                if list.count > 1 {
                    Text("+\(list.count - 1) fallback").font(.caption).foregroundStyle(.secondary)
                        .help(list.dropFirst().joined(separator: ", "))
                }
            }
            if !primary.isEmpty && NSFont(name: primary, size: 12) == nil && !installed.contains(primary) {
                Text("\(primary) isn't installed — Ghoztty uses the next font.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }
}

/// A repeatable key's values from the user's file, as removable chips,
/// plus a field to add one (validated by Ghostty before it is written).
struct ListControl: View {
    @ObservedObject var model: SettingsModel
    let key: String
    let placeholder: String
    @State private var adding = ""

    var body: some View {
        let values = model.file.values(for: key)
        HStack(spacing: 4) {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                HStack(spacing: 3) {
                    Text(value).font(.system(.caption, design: .monospaced))
                    Button {
                        var list = values
                        list.remove(at: index)
                        model.setList(key, list)
                    } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove \(value)")
                }
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
            }
            TextField("", text: $adding, prompt: Text(placeholder))
                .settingsField()
                .frame(width: 120)
                .onSubmit {
                    let value = adding.trimmingCharacters(in: .whitespaces)
                    guard !value.isEmpty else { return }
                    if model.setList(key, values + [value]) { adding = "" }
                }
        }
    }
}

/// A packed-struct flags key (`cursor,no-sudo,…`) as checkboxes; the names
/// come from the schema. Writes every flag explicitly.
private struct FlagsControl: View {
    @ObservedObject var model: SettingsModel
    let key: String

    var body: some View {
        let options = model.doc(key)?.options ?? []
        let set = Self.parse(model.value(key))
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), alignment: .leading)], alignment: .leading, spacing: 4) {
            ForEach(options, id: \.self) { flag in
                Toggle(flag, isOn: Binding(
                    get: { set[flag] ?? false },
                    set: { on in
                        var next = set
                        next[flag] = on
                        model.set(key, options.map { (next[$0] ?? false ? "" : "no-") + $0 }.joined(separator: ","))
                    }))
                .toggleStyle(.checkbox)
            }
        }
        .frame(width: 320)
    }

    static func parse(_ value: String) -> [String: Bool] {
        var out: [String: Bool] = [:]
        for part in value.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !part.isEmpty {
            if part.hasPrefix("no-") { out[String(part.dropFirst(3))] = false } else { out[part] = true }
        }
        return out
    }
}

/// The shell to run: the login shell by default, common shells, or any
/// executable (checked to exist before it's written).
private struct ShellControl: View {
    @ObservedObject var model: SettingsModel
    let key: String
    let scripted: Bool
    @State private var askingOther = false
    @State private var other = ""

    static let common = ["/bin/zsh", "/bin/bash", "/opt/homebrew/bin/fish", "/opt/homebrew/bin/nu", "/usr/local/bin/fish"]
        .filter { FileManager.default.isExecutableFile(atPath: $0) }

    var body: some View {
        let value = model.value(key)
        let loginShell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        Picker("", selection: Binding(
            get: { value },
            set: { choice in
                if choice == "\u{0}other" { other = value; askingOther = true }
                else if choice.isEmpty { model.reset(key) }
                else { model.set(key, choice) }
            })) {
            Text(scripted ? "The --shell flag, else $SHELL" : "Login shell (\(loginShell))").tag("")
            Divider()
            ForEach(Self.common, id: \.self) { Text($0).tag($0) }
            if !value.isEmpty && !Self.common.contains(value) { Text(value).tag(value) }
            Divider()
            Text("Other…").tag("\u{0}other")
        }
        .labelsHidden()
        .fixedSize()
        .sheet(isPresented: $askingOther) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Shell").font(.headline)
                Text("A path or a command on your PATH, with optional arguments.").font(.caption).foregroundStyle(.secondary)
                TextField("", text: $other, prompt: Text("/opt/homebrew/bin/fish --login"))
                    .settingsField()
                    .frame(width: 340)
                if let problem = Self.problem(other) {
                    Text(problem).font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { askingOther = false }.keyboardShortcut(.cancelAction)
                    Button("Use Shell") {
                        model.set(key, other.trimmingCharacters(in: .whitespaces))
                        askingOther = false
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(Self.problem(other) != nil)
                }
            }
            .padding(18)
        }
    }

    /// Nil if the command's program exists (absolute, or found on PATH).
    static func problem(_ command: String) -> String? {
        let program = command.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
        guard !program.isEmpty else { return "Enter a shell." }
        if program.hasPrefix("/") || program.hasPrefix("~") {
            let path = (program as NSString).expandingTildeInPath
            return FileManager.default.isExecutableFile(atPath: path) ? nil : "\(program) isn't an executable file."
        }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        let found = path.split(separator: ":").contains {
            FileManager.default.isExecutableFile(atPath: "\($0)/\(program)")
        }
        return found ? nil : "\(program) isn't on your PATH."
    }
}

/// Where new windows start: home, where Ghoztty was launched, or a folder.
private struct FolderControl: View {
    @ObservedObject var model: SettingsModel
    let key: String

    var body: some View {
        let value = model.isSetInFile(key) ? model.value(key) : ""
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        Picker("", selection: Binding(
            get: { value == "home" ? "" : value },
            set: { choice in
                switch choice {
                case "": model.reset(key)
                case "\u{0}choose": choose()
                default: model.set(key, choice)
                }
            })) {
            Text("Home folder").tag("")
            Text("Where Ghoztty was launched").tag("inherit")
            if !value.isEmpty, value != "home", value != "inherit" {
                Text(value.replacingOccurrences(of: home, with: "~")).tag(value)
            }
            Divider()
            Text("Choose Folder…").tag("\u{0}choose")
        }
        .labelsHidden()
        .fixedSize()
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.set(key, url.path)
    }
}

extension View {
    /// A text field inside a grouped Form: no side label (Form would show
    /// the title as one), a visible border.
    func settingsField() -> some View {
        labelsHidden().textFieldStyle(.roundedBorder)
    }
}
