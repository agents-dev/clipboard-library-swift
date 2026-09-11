import SwiftUI

struct GitHubNotesImportSheet: View {
    let repository: ClipboardRepository
    let imported: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var error = ""
    @State private var importing = false
    @State private var task: Task<Void, Never>?
    @FocusState private var urlFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import GitHub skills").font(.title2)
            Text("Enter a public GitHub repository or folder URL. Each skill becomes a Markdown file in Notes.")
                .foregroundStyle(.secondary)
            TextField("https://github.com/owner/repository/tree/main/skills", text: $url)
                .textFieldStyle(.roundedBorder).focused($urlFocused)
                .onSubmit { startImport() }.disabled(importing)
                .accessibilityIdentifier("github-skills-url")
            if importing { ProgressView("Importing skills…").controlSize(.small) }
            if !error.isEmpty { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Cancel") { task?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import") { startImport() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(importing || url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("github-skills-import")
            }
        }.padding(24).frame(width: 500)
            .onAppear { urlFocused = true }
            .onDisappear { task?.cancel() }
            .interactiveDismissDisabled(importing)
    }

    private func startImport() {
        guard !importing else { return }
        importing = true
        error = ""
        let source = url
        task = Task { @MainActor in
            do {
                let group = try await GitHubSkillImporter().fetch(source)
                try Task.checkCancellation()
                let id = try repository.importNoteFiles(group.files, group: group.name)
                imported(id)
                dismiss()
            } catch is CancellationError {
                importing = false
            } catch {
                self.error = error.localizedDescription
                importing = false
            }
        }
    }
}

/// Intercept file paste in the Notes area, including its AppKit field editor.
/// Leave all other paste events to the existing responder chain.
struct NotesFilePasteCapture: NSViewRepresentable {
    let paste: ([URL]) -> Void
    func makeNSView(context: Context) -> NotesFilePasteView { NotesFilePasteView() }
    func updateNSView(_ view: NotesFilePasteView, context: Context) { view.pasteFiles = paste }
}

final class NotesFilePasteView: NSView {
    var pasteFiles: (([URL]) -> Void)?
    private var monitor: Any?
    private var selectedArea = false
    override var acceptsFirstResponder: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            if event.type == .leftMouseDown {
                self.selectedArea = self.bounds.contains(self.convert(event.locationInWindow, from: nil))
                if self.selectedArea, !self.containsResponder() { self.window?.makeFirstResponder(self) }
            } else if self.handlePaste(event, pasteboard: .general) { return nil }
            return event
        }
    }

    private func containsResponder() -> Bool {
        guard let responder = window?.firstResponder else { return false }
        if responder === self { return true }
        let view: NSView?
        if let editor = responder as? NSTextView { view = (editor.delegate as? NSView) ?? editor }
        else { view = responder as? NSView }
        guard let view else { return false }
        return bounds.intersects(convert(view.bounds, from: view))
    }

    func handlePaste(_ event: NSEvent, pasteboard: NSPasteboard) -> Bool {
        guard event.type == .keyDown, event.keyCode == 9,
              event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
              event.window === window else { return false }
        var inNotes = selectedArea
        if let editor = window?.firstResponder as? NSTextView {
            // AppKit places the shared field editor outside the SwiftUI hierarchy.
            let owner = (editor.delegate as? NSView) ?? editor
            inNotes = bounds.intersects(convert(owner.bounds, from: owner))
        } else if let control = window?.firstResponder as? NSControl {
            inNotes = bounds.intersects(convert(control.bounds, from: control))
        }
        guard inNotes else { return false }
        let urls = NoteFile.urls(from: pasteboard)
        guard !urls.isEmpty, let pasteFiles else { return false }
        pasteFiles(urls)
        return true
    }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}
