import XCTest
import CryptoKit
import AppKit
import GRDB
@testable import ClipboardLibrary

final class NoteFileTests: XCTestCase {
    func testImportedSkillsPersistAsTreeAndEncryptedFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = SymmetricKey(size: .bits256)
        let path = dir.appendingPathComponent("notes.sqlite").path
        let repo = try ClipboardRepository(path: path, key: key)
        let original = Data("---\nname: build-run-debug\n---\n# Keep original bytes\n".utf8)
        let root = try repo.importNoteFiles([NoteFile(name: "build-run-debug.md", data: original)], group: "build-macos-apps")
        let reopened = try ClipboardRepository(path: path, key: key)
        let notes = try reopened.notes()
        XCTAssertEqual(notes.first { $0.id == root }?.text, "build-macos-apps")
        let child = try XCTUnwrap(notes.first { $0.parentID == root })
        XCTAssertEqual(child.text, "build-run-debug")
        XCTAssertEqual(child.attachmentName, "build-run-debug.md")
        XCTAssertEqual(try reopened.noteFile(child.id)?.data, original)
        let stored = try reopened.db.read { try Data.fetchOne($0, sql: "SELECT sealed FROM noteFiles WHERE noteID=?", arguments: [child.id]) }
        XCTAssertNotEqual(stored, original)
        try reopened.deleteNote(root)
        XCTAssertNil(try reopened.noteFile(child.id))
    }

    func testInvalidFilenameRollsBackWholeImport() throws {
        let repo = try ClipboardRepository(path: ":memory:", key: SymmetricKey(size: .bits256))
        XCTAssertThrowsError(try repo.importNoteFiles([
            NoteFile(name: "good.md", data: Data()),
            NoteFile(name: "../escape.md", data: Data())
        ], group: "Skills"))
        XCTAssertTrue(try repo.notes().isEmpty)
    }

    func testPastedFileSurvivesSourceRemovalAndExportsRealFileURL() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("example.pdf")
        let bytes = Data([0, 1, 255, 42])
        try bytes.write(to: source)
        let repo = try ClipboardRepository(path: ":memory:", key: SymmetricKey(size: .bits256))
        let parent = try repo.addNote(text: "Files")
        let id = try repo.importNoteFiles(NoteFile.read([source]), parentID: parent)
        try FileManager.default.removeItem(at: source)
        let note = try XCTUnwrap(repo.notes().first { $0.id == id })
        XCTAssertEqual(note.parentID, parent)
        XCTAssertEqual(note.text, "example.pdf")
        let file = try XCTUnwrap(repo.noteFile(id))
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        try file.writeToPasteboard(board, exportRoot: dir.appendingPathComponent("exports"))
        let url = try XCTUnwrap(NoteFile.urls(from: board).first)
        XCTAssertEqual(url.lastPathComponent, "example.pdf")
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testPlainTextFilePathIsNotTreatedAsAFilePaste() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("file:///tmp/example.md", forType: .string)
        XCTAssertTrue(NoteFile.urls(from: board).isEmpty)
    }

    @MainActor func testFilePasteRoutesOnlyFromNotesFieldEditor() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        let capture = NotesFilePasteView(frame: NSRect(x: 300, y: 0, width: 300, height: 200))
        let note = NSTextField(frame: NSRect(x: 320, y: 80, width: 250, height: 24))
        let search = NSTextField(frame: NSRect(x: 20, y: 80, width: 250, height: 24))
        content.addSubview(capture)
        content.addSubview(note)
        content.addSubview(search)
        window.contentView = content
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        var pasted: [[URL]] = []
        capture.pasteFiles = { pasted.append($0) }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let url = URL(fileURLWithPath: "/tmp/skill.md")
        board.writeObjects([url as NSURL])
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9))
        XCTAssertTrue(window.makeFirstResponder(note))
        XCTAssertTrue(capture.handlePaste(event, pasteboard: board))
        XCTAssertEqual(pasted, [[url]])
        XCTAssertTrue(window.makeFirstResponder(search))
        XCTAssertFalse(capture.handlePaste(event, pasteboard: board))
        XCTAssertEqual(pasted.count, 1)
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 400, y: 30), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        NSApp.sendEvent(click)
        XCTAssertTrue(capture.handlePaste(event, pasteboard: board), "Clicking blank Notes space must support file paste even after searching")
        XCTAssertEqual(pasted.count, 2)
        board.clearContents()
        board.setString("Keep normal text paste", forType: .string)
        XCTAssertTrue(window.makeFirstResponder(note))
        XCTAssertFalse(capture.handlePaste(event, pasteboard: board))
    }

    func testMissingParentAndDirectoriesLeaveNoPartialNotes() throws {
        let repo = try ClipboardRepository(path: ":memory:", key: SymmetricKey(size: .bits256))
        XCTAssertThrowsError(try repo.importNoteFiles([NoteFile(name: "file.md", data: Data())], parentID: "missing"))
        XCTAssertTrue(try repo.notes().isEmpty)
        XCTAssertThrowsError(try NoteFile.read([FileManager.default.temporaryDirectory]))
    }
}
