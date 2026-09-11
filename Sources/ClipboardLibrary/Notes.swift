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
    @FocusState private var focused: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Notes", systemImage: "list.bullet.indent")
                    .font(.headline)
                Spacer()
                Button { addRoot() } label: { Image(systemName: "plus") }.help("Add note")
            }.padding(14)
            Divider()
            if visible.isEmpty {
                ContentUnavailableView("No notes", systemImage: "list.bullet", description: Text("Press + and start typing."))
                    .onTapGesture { addRoot() }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(visible) { row in noteRow(row) }
                    }.padding(.vertical, 8)
                }
            }
            Divider()
            HStack(spacing: 14) {
                Button { if let note = selected { tryChange { try model.repository.outdentNote(note) } } } label: { Image(systemName: "decrease.indent") }.help("Outdent")
                Button { if let note = selected { tryChange { try model.repository.indentNote(note) } } } label: { Image(systemName: "increase.indent") }.help("Indent")
                Button { if let note = selected { addChild(note) } } label: { Image(systemName: "arrow.turn.down.right") }.help("Add child")
                Spacer()
                Button(role: .destructive) { if let note = selected { remove(note) } } label: { Image(systemName: "trash") }.help("Delete note")
            }.buttonStyle(.borderless).padding(12)
        }.background(Color(nsColor: .controlBackgroundColor))
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
        HStack(spacing: 6) {
            if hasChildren(row.note) {
                Button { tryChange { try model.repository.updateNote(row.note.id, expanded: !row.note.expanded) } } label: {
                    Image(systemName: row.note.expanded ? "chevron.down" : "chevron.right").font(.caption)
                }.buttonStyle(.plain).frame(width: 14)
            } else { Color.clear.frame(width: 14, height: 1) }
            Circle().fill(selection == row.note.id ? Color.accentColor : Color.secondary).frame(width: 7, height: 7)
            NoteTextField(
                initialText: row.note.text,
                selected: selection == row.note.id,
                paste: { model.pasteNote($0) },
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
        .contextMenu {
            Button("Add child") { addChild(row.note) }
            Button("Indent") { tryChange { try model.repository.indentNote(row.note) } }
            Button("Outdent") { tryChange { try model.repository.outdentNote(row.note) } }
            Divider()
            Button("Delete", role: .destructive) { remove(row.note) }
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
    let paste: (String) -> Void
    let save: (String) -> Void
    let deleteIfEmpty: () -> Void
    let submit: () -> Void
    @Binding var focused: Bool

    init(
        initialText: String,
        selected: Bool = true,
        paste: @escaping (String) -> Void = { _ in },
        save: @escaping (String) -> Void,
        deleteIfEmpty: @escaping () -> Void,
        submit: @escaping () -> Void,
        focused: Binding<Bool>
    ) {
        _text = State(initialValue: initialText)
        self.selected = selected
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
