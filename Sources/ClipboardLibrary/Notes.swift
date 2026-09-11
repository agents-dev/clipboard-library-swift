import SwiftUI

struct VisibleNote: Identifiable {
    let note: OutlineNote
    let depth: Int
    var id: String { note.id }
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
            NoteTextField(initialText: row.note.text, save: { model.saveNoteText(row.note.id, text: $0) })
                .focused($focused, equals: row.note.id).onSubmit { addAfter(row.note) }
        }
        .padding(.leading, CGFloat(row.depth * 22) + 8).padding(.trailing, 8).padding(.vertical, 5)
        .background(selection == row.note.id ? Color.accentColor.opacity(0.12) : Color.clear)
        .overlay(alignment: .leading) { if row.depth > 0 { Rectangle().fill(Color.secondary.opacity(0.18)).frame(width: 1).padding(.leading, CGFloat(row.depth * 22)) } }
        .contentShape(Rectangle()).onTapGesture { selection = row.note.id; focused = row.note.id }
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
}

private struct NoteTextField: View {
    @State private var text: String
    let save: (String) -> Void

    init(initialText: String, save: @escaping (String) -> Void) {
        _text = State(initialValue: initialText)
        self.save = save
    }

    var body: some View {
        TextField("Note", text: $text)
            .textFieldStyle(.plain)
            .onChange(of: text) { _, value in save(value) }
    }
}
