import SwiftUI

struct VisibleNote: Identifiable {
    let note: OutlineNote
    let depth: Int
    var id: String { note.id }
}

func replacementNoteID(removing id: String, from rows: [VisibleNote]) -> String? {
    guard let index = rows.firstIndex(where: { $0.id == id }) else { return nil }
    if index > 0 { return rows[index - 1].id }
    if index + 1 < rows.count { return rows[index + 1].id }
    return nil
}

@MainActor func scheduleReplacementNoteFocus(_ id: String?, setFocus: @escaping (String?) -> Void) {
    setFocus(nil)
    DispatchQueue.main.async { setFocus(id) }
}

struct NotesPanel: View {
    @ObservedObject var model: AppModel
    @State private var selection: String?
    @State private var showGitHubImport = false
    @State private var importingFiles = false
    @State private var importError = ""
    @State private var draggingID: String?
    @State private var dropIndicator: NoteDropDestination?
    @FocusState private var focused: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Notes", systemImage: "list.bullet.indent")
                    .font(.headline)
                Spacer()
                Menu {
                    Button("Add text note") { addRoot() }
                    Button("Paste files") { pasteFiles() }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize().help("Notes actions")
                Button { showGitHubImport = true } label: { Image(systemName: "plus") }
                    .help("Import GitHub skills").accessibilityIdentifier("notes-import-github")
            }.padding(14)
            Divider()
            if visible.isEmpty {
                ContentUnavailableView("No notes", systemImage: "list.bullet", description: Text("Press + to import GitHub skills, or copy files in Finder and paste them here."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(visible) { row in noteRow(row) }
                        Text("Drop here to move to top level")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 32)
                            .background(dropIndicator == .rootEnd ? Color.accentColor.opacity(0.15) : Color.clear)
                            .contentShape(Rectangle())
                            .onDrop(of: [NoteDrag.type], delegate: NoteDropDelegate(
                                rowID: nil, notes: model.notes, draggingID: $draggingID,
                                indicator: $dropIndicator, move: moveSubtree
                            ))
                    }.padding(.vertical, 8)
                }
            }
            Divider()
            if importingFiles { ProgressView("Importing files…").controlSize(.small).padding(8) }
            if !importError.isEmpty { Text(importError).font(.caption).foregroundStyle(.red).padding(8) }
            HStack(spacing: 14) {
                Button { pasteFiles() } label: { Image(systemName: "doc.on.clipboard") }
                    .help("Paste files under the selected note (Command-V)").disabled(importingFiles)
                Button { if let note = selected { tryChange { try model.repository.outdentNote(note) } } } label: { Image(systemName: "decrease.indent") }.help("Outdent")
                Button { if let note = selected { tryChange { try model.repository.indentNote(note) } } } label: { Image(systemName: "increase.indent") }.help("Indent")
                Button { if let note = selected { addChild(note) } } label: { Image(systemName: "arrow.turn.down.right") }.help("Add child")
                Spacer()
                Button(role: .destructive) { if let note = selected { remove(note) } } label: { Image(systemName: "trash") }.help("Delete note")
            }.buttonStyle(.borderless).padding(12)
        }.background(Color(nsColor: .controlBackgroundColor))
            .background(NotesFilePasteCapture { importFiles($0) })
            .sheet(isPresented: $showGitHubImport) {
                GitHubNotesImportSheet(repository: model.repository) { id in
                    model.refreshNotes()
                    selection = id
                    focused = nil
                }
            }
    }

    var selected: OutlineNote? { model.notes.first { $0.id == selection } }
    var visible: [VisibleNote] {
        let grouped = Dictionary(grouping: model.notes, by: { $0.parentID })
        func walk(_ parent: String?, depth: Int) -> [VisibleNote] {
            (grouped[parent] ?? []).sorted { $0.position < $1.position }.flatMap { note in
                [VisibleNote(note: note, depth: depth)] + (note.expanded ? walk(note.id, depth: depth + 1) : [])
            }
        }
        return walk(nil, depth: 0)
    }
    func hasChildren(_ note: OutlineNote) -> Bool { model.notes.contains { $0.parentID == note.id } }

    @ViewBuilder func noteRow(_ row: VisibleNote) -> some View {
        HStack(alignment: .top, spacing: 6) {
            if hasChildren(row.note) {
                Button { tryChange { try model.repository.updateNote(row.note.id, expanded: !row.note.expanded) } } label: {
                    Image(systemName: row.note.expanded ? "chevron.down" : "chevron.right").font(.caption)
                }.buttonStyle(.plain).frame(width: 14, height: 17)
            } else { Color.clear.frame(width: 14, height: 17) }
            Circle()
                .fill(selection == row.note.id ? Color.accentColor : Color.secondary)
                .frame(width: 7, height: 7)
                .frame(width: 16, height: 17)
                .contentShape(Rectangle())
                .help("Drag to move this note and its children. Drop between rows to reorder, or on a row to make it a child.")
                .accessibilityLabel("Move \(row.note.text)")
                .onDrag {
                    focused = nil
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    model.noteSaveQueue.sync {}
                    selection = row.id
                    draggingID = row.id
                    return NoteDrag.provider(row.id)
                } preview: {
                    Label(row.note.text.components(separatedBy: .newlines).first ?? "Note", systemImage: "list.bullet.indent")
                        .lineLimit(1).padding(8)
                }
            if row.note.attachmentName != nil {
                Image(systemName: "doc").font(.caption).foregroundStyle(.secondary)
                    .frame(width: 12, height: 17)
            }
            NoteTextField(
                initialText: row.note.text,
                selected: selection == row.note.id,
                emphasized: hasChildren(row.note),
                paste: { text in
                    if row.note.attachmentName != nil { model.pasteNoteFile(row.note.id) }
                    else { model.pasteNote(text) }
                },
                save: { model.saveNoteText(row.note.id, text: $0) },
                deleteIfEmpty: { removePromotingChildren(row.note) },
                submit: { addAfter(row.note) },
                focused: Binding(
                    get: { focused == row.note.id },
                    set: { isFocused in
                        if isFocused { selection = row.note.id; focused = row.note.id }
                        else if focused == row.note.id { focused = nil }
                    }
                )
            )
        }
        .padding(.leading, CGFloat(row.depth * 22) + 8).padding(.trailing, 8).padding(.vertical, 5)
        .overlay(alignment: .leading) { if row.depth > 0 { Rectangle().fill(Color.secondary.opacity(0.18)).frame(width: 1).padding(.leading, CGFloat(row.depth * 22)) } }
        .contentShape(Rectangle())
        .onTapGesture { selection = row.note.id; focused = row.note.id }
        .modifier(NoteRowDropTarget(row: row, notes: model.notes,
                                    marker: dropIndicator.flatMap { NoteInsertionMarker(destination: $0, rows: visible) }, draggingID: $draggingID,
                                    indicator: $dropIndicator, move: moveSubtree))
        .contextMenu {
            if row.note.attachmentName != nil {
                Button("Paste file") { model.pasteNoteFile(row.note.id) }
            }
            Button("Paste files as children") { pasteFiles(parentID: row.note.id) }
            Button("Add child") { addChild(row.note) }
            Button("Indent") { tryChange { try model.repository.indentNote(row.note) } }
            Button("Outdent") { tryChange { try model.repository.outdentNote(row.note) } }
            Divider()
            Button("Delete", role: .destructive) { remove(row.note) }
        }
    }
    func moveSubtree(_ id: String, to destination: NoteDropDestination) {
        do {
            try model.repository.moveNote(id, to: destination)
            model.refreshNotes()
            selection = id
            focused = nil
        } catch { model.message = error.localizedDescription }
        draggingID = nil
        dropIndicator = nil
    }
    func pasteFiles(parentID: String? = nil) {
        let urls = NoteFile.urls(from: .general)
        guard !urls.isEmpty else { importError = "Copy files in Finder, then paste them here."; return }
        importFiles(urls, parentID: parentID)
    }
    func importFiles(_ urls: [URL], parentID: String? = nil) {
        guard !importingFiles else { return }
        importingFiles = true
        importError = ""
        let parent = parentID ?? selection
        let repository = model.repository
        Task { @MainActor in
            defer { importingFiles = false }
            do {
                let id = try await Task.detached(priority: .userInitiated) {
                    try repository.importNoteFiles(NoteFile.read(urls), parentID: parent)
                }.value
                model.refreshNotes()
                selection = id
                focused = nil
            } catch { importError = error.localizedDescription }
        }
    }
    func tryChange(_ change: () throws -> Void) { do { try change(); model.refreshNotes() } catch { model.message = error.localizedDescription } }
    func addRoot() { do { let id = try model.repository.addNote(); model.refreshNotes(); selection = id; focused = id } catch { model.message = error.localizedDescription } }
    func addAfter(_ note: OutlineNote) { do { let id = try model.repository.addNote(after: note); model.refreshNotes(); selection = id; focused = id } catch { model.message = error.localizedDescription } }
    func addChild(_ note: OutlineNote) { do { try model.repository.updateNote(note.id, expanded: true); let id = try model.repository.addNote(parentID: note.id); model.refreshNotes(); selection = id; focused = id } catch { model.message = error.localizedDescription } }
    func remove(_ note: OutlineNote) { do { try model.repository.deleteNote(note.id); model.refreshNotes(); selection = nil } catch { model.message = error.localizedDescription } }
    func removePromotingChildren(_ note: OutlineNote) {
        let rows = visible
        let nextID = replacementNoteID(removing: note.id, from: rows)
        do {
            try model.repository.deleteNotePromotingChildren(note.id)
            model.refreshNotes()
            selection = nextID
            scheduleReplacementNoteFocus(nextID) { focused = $0 }
        } catch { model.message = error.localizedDescription }
    }
}

struct NoteTextField: NSViewRepresentable {
    @State private var text: String
    let selected: Bool
    let emphasized: Bool
    let paste: (String) -> Void
    let save: (String) -> Void
    let deleteIfEmpty: () -> Void
    let submit: () -> Void
    @Binding var focused: Bool

    init(
        initialText: String,
        selected: Bool = true,
        emphasized: Bool = false,
        paste: @escaping (String) -> Void = { _ in },
        save: @escaping (String) -> Void,
        deleteIfEmpty: @escaping () -> Void,
        submit: @escaping () -> Void,
        focused: Binding<Bool>
    ) {
        _text = State(initialValue: initialText)
        self.selected = selected
        self.emphasized = emphasized
        self.paste = paste
        self.save = save
        self.deleteIfEmpty = deleteIfEmpty
        self.submit = submit
        _focused = focused
    }

    func makeCoordinator() -> NoteTextFieldCoordinator {
        NoteTextFieldCoordinator(
            textChanged: { value in text = value; save(value) },
            deleteEmpty: deleteIfEmpty,
            submit: submit,
            focusChanged: { focused = $0 }
        )
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NoteNativeTextField(string: text)
        field.placeholderString = "Note"
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.textChanged = { value in text = value; save(value) }
        context.coordinator.deleteEmpty = deleteIfEmpty
        context.coordinator.submit = submit
        context.coordinator.focusChanged = { focused = $0 }
        let displayed = selected ? text : text.components(separatedBy: .newlines).first ?? ""
        if field.stringValue != displayed { field.stringValue = displayed }
        field.maximumNumberOfLines = selected ? 0 : 1
        field.lineBreakMode = selected ? .byWordWrapping : .byTruncatingTail
        field.usesSingleLineMode = !selected
        field.font = .systemFont(ofSize: NSFont.systemFontSize, weight: emphasized ? .semibold : .regular)
        if let noteField = field as? NoteNativeTextField {
            noteField.didFocus = { context.coordinator.focusChanged(true) }
            noteField.fullText = text
            noteField.pasteNote = paste
        }
        field.invalidateIntrinsicContentSize()
        if focused, field.currentEditor() == nil {
            DispatchQueue.main.async {
                guard field.window?.isVisible == true else { return }
                field.window?.makeFirstResponder(field)
            }
        }
    }
}

final class NoteTextFieldCoordinator: NSObject, NSTextFieldDelegate {
    var textChanged: (String) -> Void
    var deleteEmpty: () -> Void
    var submit: () -> Void
    var focusChanged: (Bool) -> Void

    init(
        textChanged: @escaping (String) -> Void,
        deleteEmpty: @escaping () -> Void,
        submit: @escaping () -> Void,
        focusChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.textChanged = textChanged
        self.deleteEmpty = deleteEmpty
        self.submit = submit
        self.focusChanged = focusChanged
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        textChanged(field.stringValue)
    }

    func controlTextDidBeginEditing(_ notification: Notification) { focusChanged(true) }
    func controlTextDidEndEditing(_ notification: Notification) { focusChanged(false) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.deleteBackward(_:)), control.stringValue.isEmpty {
            deleteEmpty()
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            submit()
            return true
        }
        return false
    }
}

final class NoteNativeTextField: NSTextField {
    var fullText = ""
    var pasteNote: ((String) -> Void)?

    var didFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        restoreFullText()
        let accepted = super.becomeFirstResponder()
        if accepted { didFocus?() }
        return accepted
    }

    private func restoreFullText() {
        // Restore all lines before AppKit creates the editor for a collapsed row.
        if currentEditor() == nil {
            stringValue = fullText
            maximumNumberOfLines = 0
            usesSingleLineMode = false
            lineBreakMode = .byWordWrapping
            invalidateIntrinsicContentSize()
        }
    }

    override func mouseDown(with event: NSEvent) {
        restoreFullText()
        super.mouseDown(with: event)
    }
    private var clickMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor); self.clickMonitor = nil }
        guard window != nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, event.window === self.window, event.clickCount == 2,
                  self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
            self.pasteNote?(self.currentEditor()?.string ?? self.fullText)
            return nil
        }
    }

    deinit {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
    }
}
