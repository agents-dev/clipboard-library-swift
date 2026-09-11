import SwiftUI
import AppKit

struct ShortcutMapperView: View {
    @ObservedObject var controller: ShortcutController
    @State private var draft: ShortcutMapping?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Shortcut Mapper").font(.title2)
                Spacer()
                Button("Add Mapping") {
                    draft = ShortcutMapping(name: "New mapping", trigger: .init(keyCode: 18, modifiers: .command),
                                            actions: [.chord(.init(keyCode: 46, modifiers: [.control, .shift])), .key(18)])
                }
            }
            Text("Run keys, text, and waits in the active application. Application mappings override global mappings.")
                .font(.caption).foregroundStyle(.secondary)
            if controller.mappings.isEmpty {
                ContentUnavailableView("No mappings", systemImage: "keyboard", description: Text("Add a mapping such as ⌘1 → ⌃⇧M, then 1."))
            } else {
                List {
                    ForEach(controller.mappings) { mapping in
                        HStack {
                            Toggle("Enable \(mapping.name)", isOn: Binding(get: { mapping.enabled }, set: { value in
                                var changed = mapping; changed.enabled = value; controller.save(changed)
                            })).labelsHidden()
                            VStack(alignment: .leading) {
                                Text(mapping.name).font(.headline)
                                Text("\(mapping.trigger.label) · \(mapping.bundleID ?? "All applications") · \(mapping.actions.count) actions")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Edit") { draft = mapping }
                            Menu {
                                Button("Duplicate") {
                                    var copy = mapping; copy.id = UUID(); copy.name += " copy"; copy.enabled = false; draft = copy
                                }
                                Button("Delete", role: .destructive) { controller.persist(controller.mappings.filter { $0.id != mapping.id }) }
                            } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 24)
                        }.padding(.vertical, 4)
                    }
                }.frame(minHeight: 200)
            }
            Text(controller.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
        .sheet(item: $draft) { value in
            ShortcutEditor(controller: controller, value: value)
        }
    }
}

struct ShortcutEditor: View {
    @ObservedObject var controller: ShortcutController
    @Environment(\.dismiss) private var dismiss
    @State var value: ShortcutMapping
    @State private var recordingActions = false
    @State private var recordingTrigger = false
    @State private var recorderMessage = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit Mapping").font(.title2)
            TextField("Name", text: $value.name)
            HStack {
                Text("Trigger")
                ShortcutKeyControls(value: $value.trigger)
                Toggle("Record trigger", isOn: $recordingTrigger).toggleStyle(.button)
                    .onChange(of: recordingTrigger) { _, active in if active { recordingActions = false } }
            }
            HStack {
                Toggle("Only in application", isOn: Binding(get: { value.bundleID != nil }, set: { value.bundleID = $0 ? "" : nil }))
                if value.bundleID != nil {
                    TextField("com.example.application", text: Binding(get: { value.bundleID ?? "" }, set: { value.bundleID = $0 }))
                    Menu("Choose App") {
                        ForEach(runningApps, id: \.bundleIdentifier) { app in
                            Button(app.localizedName ?? app.bundleIdentifier ?? "Application") { value.bundleID = app.bundleIdentifier }
                        }
                    }
                }
            }
            HStack {
                Text("Actions").font(.headline)
                Spacer()
                Toggle("Record actions", isOn: $recordingActions).toggleStyle(.button)
                    .onChange(of: recordingActions) { _, active in if active { recordingTrigger = false } }
                Menu("Add Action") {
                    Button("Key chord") { value.actions.append(.chord(.init(keyCode: 46, modifiers: [.control, .shift]))) }
                    Button("Single key") { value.actions.append(.key(18)) }
                    Button("Type text") { value.actions.append(.text("")) }
                    Button("Wait") { value.actions.append(.delay(0.5)) }
                }
            }
            if recordingTrigger || recordingActions {
                Text("Press keys to record. Click the active Record button to stop. Escape is recorded as a key.")
                    .font(.caption).foregroundStyle(.blue)
                ShortcutRecorder { trigger in
                    guard ShortcutKeys.valid(trigger.keyCode) else { recorderMessage = "This key is not supported."; return }
                    recorderMessage = ""
                    if recordingTrigger {
                        value.trigger = trigger; recordingTrigger = false
                    } else {
                        value.actions.append(trigger.modifiers.isEmpty ? .key(trigger.keyCode) : .chord(trigger))
                    }
                }.frame(height: 1)
            }
            if !recorderMessage.isEmpty { Text(recorderMessage).font(.caption).foregroundStyle(.red) }
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(value.actions.indices, id: \.self) { index in
                        let original = value.actions[index]
                        HStack(alignment: .top) {
                            Text("\(index + 1)").frame(width: 24)
                            ShortcutActionEditor(action: Binding(get: {
                                value.actions.indices.contains(index) ? value.actions[index] : original
                            }, set: { if value.actions.indices.contains(index) { value.actions[index] = $0 } }))
                            Spacer(minLength: 0)
                            Button { value.actions.swapAt(index, index - 1) } label: { Image(systemName: "arrow.up") }.disabled(index == 0).help("Move action up")
                            Button { value.actions.swapAt(index, index + 1) } label: { Image(systemName: "arrow.down") }.disabled(index == value.actions.count - 1).help("Move action down")
                            Button(role: .destructive) { value.actions.remove(at: index) } label: { Image(systemName: "trash") }.help("Remove action")
                        }.padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }.frame(minHeight: 160, maxHeight: .infinity)
            Text("Keys use physical positions (US labels). Text actions type Unicode. A 20 ms gap follows key and text actions. Add Wait for a longer pause.")
                .font(.caption).foregroundStyle(.secondary)
            Text(controller.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Toggle("Enabled", isOn: $value.enabled)
                Spacer()
                if controller.testing { Button("Cancel Test") { controller.cancelTest() } }
                else { Button("Test in 3 seconds") { recordingActions = false; recordingTrigger = false; controller.test(value) } }
                Button("Cancel") { dismiss() }
                Button("Save") {
                    value.name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    value.bundleID = value.bundleID?.trimmingCharacters(in: .whitespacesAndNewlines)
                    if controller.save(value) { dismiss() }
                }.buttonStyle(.borderedProminent).disabled(controller.testing)
            }
        }.padding(24).frame(width: 850, height: 650)
            .onAppear { controller.setEditing(true) }
            .onDisappear { controller.cancelTest(); controller.setEditing(false) }
    }
    private var runningApps: [NSRunningApplication] {
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications.filter {
            guard $0.activationPolicy == .regular, let id = $0.bundleIdentifier else { return false }
            return seen.insert(id).inserted
        }.sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }
}

struct ShortcutActionEditor: View {
    @Binding var action: ShortcutAction
    var body: some View {
        switch action {
        case .chord(let trigger):
            Text("Chord").frame(width: 50, alignment: .leading)
            ShortcutKeyControls(value: Binding(get: { if case .chord(let current) = action { return current }; return trigger }, set: { action = .chord($0) }))
        case .key(let code):
            Text("Key").frame(width: 50, alignment: .leading)
            ShortcutKeyPicker(code: Binding(get: { if case .key(let current) = action { return current }; return code }, set: { action = .key($0) }))
        case .text(let text):
            Text("Text").frame(width: 50, alignment: .leading)
            TextEditor(text: Binding(get: { if case .text(let current) = action { return current }; return text }, set: { action = .text($0) }))
                .font(.body).frame(height: 70).overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
        case .delay(let seconds):
            Text("Wait").frame(width: 50, alignment: .leading)
            TextField("Seconds", value: Binding(get: { if case .delay(let current) = action { return current }; return seconds }, set: { action = .delay($0) }), format: .number)
                .frame(width: 80)
            Text("seconds (0–10)").foregroundStyle(.secondary)
        }
    }
}

struct ShortcutKeyPicker: View {
    @Binding var code: UInt16
    var body: some View {
        Picker("Key", selection: $code) {
            ForEach(ShortcutKeys.all, id: \.0) { key in Text(key.1).tag(key.0) }
        }.labelsHidden().frame(width: 120)
    }
}

struct ShortcutKeyControls: View {
    @Binding var value: ShortcutTrigger
    var body: some View {
        ShortcutKeyPicker(code: $value.keyCode)
        modifier("⌘", .command)
        modifier("⌃", .control)
        modifier("⌥", .option)
        modifier("⇧", .shift)
    }
    func modifier(_ label: String, _ modifier: ShortcutModifiers) -> some View {
        Toggle(label, isOn: Binding(get: { value.modifiers.contains(modifier) }, set: {
            if $0 { value.modifiers.insert(modifier) } else { value.modifiers.remove(modifier) }
        })).toggleStyle(.button)
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    var onKey: (ShortcutTrigger) -> Void
    func makeNSView(context: Context) -> RecordingView { let view = RecordingView(); view.onKey = onKey; return view }
    func updateNSView(_ view: RecordingView, context: Context) { view.onKey = onKey }
    static func dismantleNSView(_ view: RecordingView, coordinator: ()) { view.stop() }

    final class RecordingView: NSView {
        var onKey: ((ShortcutTrigger) -> Void)?
        private var monitor: Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
                guard let self, self.window?.isKeyWindow == true else { return event }
                if event.type == .keyDown, !event.isARepeat {
                    var modifiers: ShortcutModifiers = []
                    if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
                    if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
                    if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
                    if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
                    self.onKey?(.init(keyCode: event.keyCode, modifiers: modifiers))
                }
                return nil
            }
        }
        func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
