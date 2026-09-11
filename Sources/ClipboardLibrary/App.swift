import SwiftUI
import AppKit
import Vision
import Carbon
import ApplicationServices

@MainActor final class AppModel: ObservableObject {
    @Published var items: [ClipboardItem] = []
    @Published var query = "" { didSet { refresh() } }
    @Published var paused = false
    @Published var message = ""
    @Published var grid = false
    @Published var notes: [OutlineNote] = []
    @Published var exclusions: String = UserDefaults.standard.string(forKey: "excludedApps") ?? "" { didSet { UserDefaults.standard.set(exclusions, forKey: "excludedApps") } }
    let repository: ClipboardRepository
    var count = NSPasteboard.general.changeCount
    var timer: Timer?
    var target: NSRunningApplication?
    var onPaste: (() -> Void)?
    var setShortcut: ((UInt32) -> Void)?
    var quitApplication: (() -> Void)?
    let shortcuts = ShortcutController()
    @Published var shortcutKey = UserDefaults.standard.string(forKey: "shortcutKey") ?? "V"
    let indexingQueue = OperationQueue()
    let noteSaveQueue = DispatchQueue(label: "ClipboardLibrary.note-saves", qos: .userInitiated)
    func saveNoteText(_ id: String, text: String) {
        let repository = repository
        noteSaveQueue.async { [weak self] in
            do { try repository.updateNote(id, text: text) }
            catch { let message = error.localizedDescription; Task { @MainActor [weak self] in self?.message = message } }
        }
    }
    init() throws {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ClipboardLibrary")
        let key = try LocalKeyFile.loadOrCreate(at: root.appendingPathComponent("history.key"))
        repository = try ClipboardRepository(path: root.appendingPathComponent("history.sqlite").path, key: key)
        indexingQueue.maxConcurrentOperationCount = 1; indexingQueue.qualityOfService = .utility
        refresh()
        refreshNotes()
        resumeIndexing()
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in Task { @MainActor in self?.capture() } }
    }
    func refreshNotes() { do { notes = try repository.notes() } catch { message = error.localizedDescription } }
    var searchTask: Task<Void, Never>?
    func refresh() {
        searchTask?.cancel()
        let query = query, repo = repository
        searchTask = Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try repo.items(query: query) } }.value
            guard !Task.isCancelled else { return }
            switch result { case .success(let items): self.items = items; case .failure(let error): message = error.localizedDescription }
        }
    }
    func capture() {
        let board = NSPasteboard.general
        guard board.changeCount != count else { return }; count = board.changeCount
        guard !paused else { return }
        let source = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "Unknown"
        guard !exclusions.split(separator: "\n").contains(where: { $0.trimmingCharacters(in: .whitespaces) == source }) else { return }
        let before = board.changeCount
        var reps: [PasteboardRepresentation] = []
        for (index, item) in (board.pasteboardItems ?? []).enumerated() {
            if item.types.contains(where: { ["org.nspasteboard.TransientType", "org.nspasteboard.ConcealedType"].contains($0.rawValue) }) { return }
            for type in item.types { if let data = item.data(forType: type) { reps.append(.init(itemIndex: index, uti: type.rawValue, data: data)) } }
        }
        guard before == board.changeCount, !reps.isEmpty else { return }
        let preview = board.string(forType: .string) ?? (NSImage(pasteboard: board) != nil ? "Image" : reps.map(\.uti).joined(separator: ", "))
        do {
            let id = try repository.capture(reps, source: source, preview: preview)
            refresh()
            enqueue(id)
        } catch { message = error.localizedDescription }
    }
    func resumeIndexing() {
        do { for id in try repository.pending() { enqueue(id) } } catch { message = error.localizedDescription }
    }
    func enqueue(_ id: String) {
        let repo = repository
        indexingQueue.addOperation { [weak self] in
            do {
                let reps = try repo.representations(id)
                var text = reps.map(\.uti).joined(separator: " ")
                for rep in reps {
                    if ["public.png", "public.tiff", "public.jpeg"].contains(rep.uti) {
                        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
                        try VNImageRequestHandler(data: rep.data).perform([request])
                        text += " " + (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                    } else if rep.uti == "public.rtf", let attributed = NSAttributedString(rtf: rep.data, documentAttributes: nil) { text += " " + attributed.string }
                    else if ["public.html", "public.utf8-plain-text", "public.url", "public.file-url"].contains(rep.uti), let decoded = String(data: rep.data, encoding: .utf8) { text += " " + decoded }
                }
                let image = reps.first { ["public.png", "public.tiff", "public.jpeg"].contains($0.uti) }?.data
                try repo.index(id, text: text, image: image)
                Task { @MainActor [weak self] in self?.refresh() }
            } catch { Task { @MainActor [weak self] in self?.message = "Indexing: " + error.localizedDescription } }
        }
    }
    func image(_ item: ClipboardItem) -> NSImage? { guard let reps = try? repository.representations(item.id) else { return nil }; return reps.lazy.filter { ["public.png", "public.tiff", "public.jpeg"].contains($0.uti) }.compactMap { NSImage(data: $0.data) }.first }
    func paste(_ item: ClipboardItem) {
        do {
            let reps = try repository.representations(item.id)
            let grouped = Dictionary(grouping: reps, by: \.itemIndex)
            let objects = grouped.keys.sorted().map { index -> NSPasteboardItem in
                let value = NSPasteboardItem(); for rep in grouped[index]! { value.setData(rep.data, forType: .init(rep.uti)) }; return value
            }
            NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects(objects); count = NSPasteboard.general.changeCount
            onPaste?()
            let trusted = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            target?.activate()
            if trusted { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                let down = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true); down?.flags = .maskCommand
                let up = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false); up?.flags = .maskCommand
                down?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap)
            } } else { message = "Copied. Press Command-V to paste. Enable Accessibility for automatic paste." }
        } catch { message = error.localizedDescription }
    }
    func remove(_ item: ClipboardItem) { do { try repository.delete(item.id); refresh() } catch { message = error.localizedDescription } }
    func pin(_ item: ClipboardItem) { do { try repository.pin(item); refresh() } catch { message = error.localizedDescription } }
}

struct LibraryView: View {
    @ObservedObject var model: AppModel
    @State var selection: String?
    @State var settings = false
    @State var editing: ClipboardItem?
    @State var filter = "All"
    @FocusState var focused: Bool
    var body: some View {
        HSplitView {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "doc.on.clipboard").foregroundStyle(.blue)
                TextField("Search clipboard history", text: $model.query).textFieldStyle(.plain).focused($focused)
                    .onSubmit { if let item = model.items.first(where: { $0.id == selection }) ?? model.items.first { model.paste(item) } }
                Button { model.paused.toggle() } label: { Image(systemName: model.paused ? "play.fill" : "pause.fill") }.help("Pause capture")
                Button { model.grid.toggle() } label: { Image(systemName: "square.grid.2x2") }
                Button { settings.toggle() } label: { Image(systemName: "gear") }
            }.padding(18)
            Divider()
            HStack {
                Picker("Type", selection: $filter) { ForEach(["All", "Images", "Text", "Pinned"], id: \.self) { Text($0) } }.pickerStyle(.segmented)
            }.padding(.horizontal).padding(.vertical, 6)
            if model.grid {
                ScrollView { LazyVGrid(columns: [GridItem(.adaptive(minimum: 160))]) { ForEach(visible) { item in
                    VStack { if let image = model.image(item) { Image(nsImage: image).resizable().scaledToFit().frame(height: 110) }; markdownText(item.preview).lineLimit(3) }.padding().onTapGesture { model.paste(item) }.contextMenu { actions(item) }
                } }.padding() }
            } else {
                List(visible, selection: $selection) { item in
                    let previewImage = model.image(item)
                    HStack(alignment: .top) {
                        ZStack(alignment: .topTrailing) {
                            if let image = previewImage {
                                Image(nsImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 68, height: 52)
                                    .clipShape(RoundedRectangle(cornerRadius: 7))
                                    .overlay { RoundedRectangle(cornerRadius: 7).stroke(.separator) }
                            } else {
                                Image(systemName: "doc.text")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 34, height: 42)
                            }
                            if item.pinned {
                                Image(systemName: "pin.fill")
                                    .font(.caption2)
                                    .padding(4)
                                    .background(.regularMaterial, in: Circle())
                                    .offset(x: 5, y: -5)
                            }
                        }
                        .accessibilityLabel(previewImage == nil ? "Clipboard text" : "Clipboard image preview")
                        VStack(alignment: .leading, spacing: 5) {
                            markdownText(item.preview).lineLimit(3)
                            Text("\(item.source) · \(item.state) · \(item.useCount) copies").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { model.paste(item) } label: { Image(systemName: "arrow.up.doc") }.buttonStyle(.borderless)
                    }
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { model.paste(item) }
                    .tag(item.id)
                    .contextMenu { actions(item) }
                }
            }
            Divider()
            HStack { Text(model.paused ? "Capture paused" : "Local history • ⌘⇧V"); Spacer(); Text(model.message.isEmpty ? "Return to paste" : model.message).lineLimit(2) }.font(.caption).foregroundStyle(.secondary).padding(12)
        }.frame(minWidth: 600, minHeight: 440)
        NotesPanel(model: model).frame(minWidth: 280, idealWidth: 340, maxWidth: 520)
        }.frame(minWidth: 920, minHeight: 440).onAppear { focused = true }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.return) {
            if NSApp.keyWindow?.firstResponder is NSTextView { return .ignored }
            if let item = visible.first(where: { $0.id == selection }) ?? visible.first { model.paste(item) }
            return .handled
        }
        .sheet(isPresented: $settings) {
            VStack {
            TabView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Settings").font(.title2)
                Text("Exclude application bundle IDs, one per line")
                Picker("Shortcut: Command-Shift", selection: $model.shortcutKey) { ForEach(["V", "B", "C", "X"], id: \.self) { Text($0) } }.onChange(of: model.shortcutKey) { _, value in
                    let codes: [String: UInt32] = ["V":9, "B":11, "C":8, "X":7]
                    model.setShortcut?(codes[value] ?? 9); UserDefaults.standard.set(model.shortcutKey, forKey: "shortcutKey")
                }
                TextEditor(text: $model.exclusions).frame(height: 100)
                Text("History has no expiration. Payloads are encrypted. Search text and metadata are stored in the local SQLite database.").font(.caption)
                Button("Delete all history", role: .destructive) { let alert = NSAlert(); alert.messageText = "Delete all clipboard history?"; alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Delete All"); if alert.runModal() == .alertSecondButtonReturn { do { try model.repository.deleteAll(); model.refresh() } catch { model.message = error.localizedDescription } } }
                Button("Rebuild search index") { model.indexingQueue.cancelAllOperations(); do { try model.repository.rebuild(); model.resumeIndexing() } catch { model.message = error.localizedDescription } }
                Button("Quit Clipboard Library") { model.quitApplication?() }
            }.padding(24).tabItem { Text("General") }
            ShortcutMapperView(controller: model.shortcuts).padding(24).tabItem { Text("Shortcut Mapper") }
            }
            Button("Done") { settings = false }.padding(.bottom, 16)
            }.frame(width: 780, height: 540)
        }.sheet(item: $editing) { item in if let image = model.image(item) { MarkupView(image: image, itemID: item.id, repository: model.repository) } }
    }
    var visible: [ClipboardItem] { model.items.filter { item in switch filter { case "Pinned": return item.pinned; case "Images": return item.preview == "Image"; case "Text": return item.preview != "Image"; default: return true } } }
    func markdownText(_ source: String) -> Text {
        Text((try? AttributedString(markdown: source)) ?? AttributedString(source))
    }
    func move(_ delta: Int) { guard !visible.isEmpty else { return }; let index = selection.flatMap { id in visible.firstIndex { $0.id == id } } ?? (delta > 0 ? -1 : visible.count); selection = visible[max(0,min(visible.count-1,index+delta))].id }
    @ViewBuilder func actions(_ item: ClipboardItem) -> some View {
        Button("Paste original") { model.paste(item) }
        Button(item.pinned ? "Unpin" : "Pin") { model.pin(item) }
        Button("Edit tags") {
            let alert = NSAlert(); alert.messageText = "Tags"; let input = NSTextField(string: item.tags); input.frame = NSRect(x: 0, y: 0, width: 320, height: 24); alert.accessoryView = input; alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn { do { try model.repository.setTags(item.id, tags: input.stringValue); model.enqueue(item.id); model.refresh() } catch { model.message = error.localizedDescription } }
        }
        if model.image(item) != nil { Button("Markup image") { editing = item } }
        Button("Delete", role: .destructive) { model.remove(item) }
    }
}

@main struct ClipboardLibraryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene { Settings { Text("Use the menu bar to open Clipboard Library.").padding() } }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var model: AppModel?
    var status: NSStatusItem?
    let statusMenu = NSMenu()
    var panel: NSPanel?
    var hotkey: EventHotKeyRef?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        do { model = try AppModel() } catch { let alert = NSAlert(); alert.messageText = "Cannot open clipboard history"; alert.informativeText = error.localizedDescription; alert.runModal(); NSApp.terminate(nil); return }
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status?.button?.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Clipboard Library")
        status?.button?.target = self; status?.button?.action = #selector(statusItemClicked)
        status?.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusMenu.addItem(withTitle: "Open Clipboard Library", action: #selector(show), keyEquivalent: "")
        statusMenu.addItem(withTitle: "Pause Capture", action: #selector(toggleCapture), keyEquivalent: "")
        statusMenu.addItem(.separator())
        statusMenu.addItem(withTitle: "Quit Clipboard Library", action: #selector(quit), keyEquivalent: "q")
        for item in statusMenu.items { item.target = self }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context else { return noErr }; let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            var hotkeyID = EventHotKeyID()
            guard let event, GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                MemoryLayout<EventHotKeyID>.size, nil, &hotkeyID) == noErr else { return OSStatus(eventNotHandledErr) }
            let signature = hotkeyID.signature, id = hotkeyID.id
            Task { @MainActor in
                if signature == ShortcutRegistry.signature { delegate.model?.shortcuts.fire(id) }
                else if signature == 0x434C4950 { delegate.show() }
            }; return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), nil)
        model?.setShortcut = { [weak self] code in self?.registerShortcut(code) }
        model?.quitApplication = { [weak self] in self?.quit() }
        let codes: [String: UInt32] = ["V":9, "B":11, "C":8, "X":7]
        registerShortcut(codes[model?.shortcutKey ?? "V"] ?? 9)
        model?.shortcuts.onEditingChanged = { [weak self] editing in
            guard let self else { return }
            if editing {
                if let hotkey { UnregisterEventHotKey(hotkey); self.hotkey = nil }
            } else { registerShortcut(codes[model?.shortcutKey ?? "V"] ?? 9) }
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        show()
        return true
    }
    @objc func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp, let button = status?.button {
            statusMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        } else {
            show()
        }
    }
    @objc func toggleCapture() {
        guard let model else { return }
        model.paused.toggle()
        statusMenu.items.first(where: { $0.action == #selector(toggleCapture) })?.title = model.paused ? "Resume Capture" : "Pause Capture"
    }
    @objc func quit() {
        model?.timer?.invalidate()
        model?.indexingQueue.cancelAllOperations()
        panel?.orderOut(nil)
        NSApplication.shared.terminate(self)
    }
    func applicationWillTerminate(_ notification: Notification) {
        model?.shortcuts.stop()
        model?.noteSaveQueue.sync {}
    }
    func registerShortcut(_ code: UInt32) {
        let reserved = ShortcutTrigger(keyCode: UInt16(code), modifiers: [.command, .shift])
        if let model, model.shortcuts.mappings.contains(where: { $0.trigger == reserved }) {
            model.message = "This shortcut is already used by Shortcut Mapper. Edit that mapping first."
            let labels: [UInt16: String] = [9: "V", 11: "B", 8: "C", 7: "X"]
            model.shortcutKey = labels[model.shortcuts.reservedTrigger.keyCode] ?? "V"
            UserDefaults.standard.set(model.shortcutKey, forKey: "shortcutKey")
            return
        }
        if let hotkey { UnregisterEventHotKey(hotkey); self.hotkey = nil }
        let status = RegisterEventHotKey(code, UInt32(cmdKey | shiftKey), EventHotKeyID(signature: 0x434C4950, id: 1), GetApplicationEventTarget(), 0, &hotkey)
        if status != noErr { model?.message = "Shortcut is unavailable. Choose another shortcut." }
        model?.shortcuts.reservedTrigger = reserved
        model?.shortcuts.refresh()
    }
    func windowDidResignKey(_ notification: Notification) {
        guard let picker = notification.object as? NSPanel, picker === panel else { return }
        DispatchQueue.main.async { [weak picker] in
            guard let picker else { return }
            let keyWindowBelongsToPicker = NSApp.keyWindow?.sheetParent === picker
            if picker.attachedSheet == nil && !keyWindowBelongsToPicker {
                picker.orderOut(nil)
            }
        }
    }
    @objc func show() {
        presentPicker()
    }
    private func presentPicker() {
        guard let model else { return }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier { model.target = NSWorkspace.shared.frontmostApplication }
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 620), styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "Clipboard Library"; panel.level = .floating; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.hidesOnDeactivate = true
            panel.delegate = self
            panel.contentView = NSHostingView(rootView: LibraryView(model: model)); self.panel = panel
            model.onPaste = { [weak panel] in panel?.orderOut(nil) }
        }
        panel?.center()
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
