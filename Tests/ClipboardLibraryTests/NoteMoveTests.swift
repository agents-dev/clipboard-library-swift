import XCTest
import CryptoKit
@testable import ClipboardLibrary

final class NoteMoveTests: XCTestCase {
    func testReordersWholeSubtreeInBothDirections() throws {
        let repo = try ClipboardRepository(path: ":memory:", key: SymmetricKey(size: .bits256))
        let first = try repo.addNote(text: "First")
        let middle = try repo.addNote(text: "Middle")
        let last = try repo.addNote(text: "Last")
        let child = try repo.addNote(parentID: first, text: "Child")
        let grandchild = try repo.addNote(parentID: child, text: "Grandchild")
        try repo.moveNote(first, to: .after(last))
        var notes = try repo.notes()
        XCTAssertEqual(notes.filter { $0.parentID == nil }.map(\.id), [middle, last, first])
        XCTAssertEqual(notes.first { $0.id == child }?.parentID, first)
        XCTAssertEqual(notes.first { $0.id == grandchild }?.parentID, child)
        try repo.moveNote(first, to: .before(middle))
        notes = try repo.notes()
        XCTAssertEqual(notes.filter { $0.parentID == nil }.map(\.id), [first, middle, last])
        XCTAssertEqual(notes.filter { $0.parentID == nil }.map(\.position), [0, 1, 2])
    }

    func testReparentsSubtreeAndExpandsNewParentWithoutChangingFiles() throws {
        let repo = try ClipboardRepository(path: ":memory:", key: SymmetricKey(size: .bits256))
        let oldParent = try repo.addNote(text: "Old parent")
        let branch = try repo.addNote(parentID: oldParent, text: "Branch")
        let sibling = try repo.addNote(parentID: oldParent, text: "Sibling")
        let bytes = Data("# Skill\n".utf8)
        let file = try repo.importNoteFiles([NoteFile(name: "skill.md", data: bytes)], parentID: branch)
        let newParent = try repo.addNote(text: "New parent")
        let existing = try repo.addNote(parentID: newParent, text: "Existing child")
        try repo.updateNote(newParent, expanded: false)
        try repo.updateNote(branch, expanded: false)

        try repo.moveNote(branch, to: .inside(newParent))

        let notes = try repo.notes()
        XCTAssertEqual(notes.filter { $0.parentID == newParent }.map(\.id), [existing, branch])
        XCTAssertEqual(notes.filter { $0.parentID == oldParent }.map(\.id), [sibling])
        XCTAssertEqual(notes.first { $0.id == sibling }?.position, 0)
        XCTAssertEqual(notes.first { $0.id == newParent }?.expanded, true)
        XCTAssertEqual(notes.first { $0.id == branch }?.expanded, false)
        XCTAssertEqual(notes.first { $0.id == file }?.parentID, branch)
        XCTAssertEqual(try repo.noteFile(file)?.data, bytes)
    }

    func testMovesAcrossParentsBeforeSiblingThenBackToRoot() throws {
        let repo = try ClipboardRepository(path: ":memory:", key: SymmetricKey(size: .bits256))
        let first = try repo.addNote(text: "First")
        let second = try repo.addNote(text: "Second")
        let moving = try repo.addNote(parentID: first, text: "Moving")
        let target = try repo.addNote(parentID: second, text: "Target")
        try repo.moveNote(moving, to: .before(target))
        XCTAssertEqual(try repo.notes().filter { $0.parentID == second }.map(\.id), [moving, target])
        try repo.moveNote(moving, to: .rootEnd)
        XCTAssertEqual(try repo.notes().filter { $0.parentID == nil }.map(\.id), [first, second, moving])
        XCTAssertEqual(try repo.notes().first { $0.id == target }?.position, 0)
    }

    func testRejectsSelfAndDescendantMovesWithoutChangingTree() throws {
        let repo = try ClipboardRepository(path: ":memory:", key: SymmetricKey(size: .bits256))
        let root = try repo.addNote(text: "Root")
        let child = try repo.addNote(parentID: root, text: "Child")
        let leaf = try repo.addNote(parentID: child, text: "Leaf")
        let before = try repo.notes()
        for destination: NoteDropDestination in [.inside(root), .before(root), .after(root), .inside(leaf), .before(child), .after(leaf), .inside("missing")] {
            XCTAssertThrowsError(try repo.moveNote(root, to: destination))
            XCTAssertEqual(try repo.notes(), before)
        }
        XCTAssertThrowsError(try repo.moveNote("missing", to: .rootEnd))
    }

    func testMoveSurvivesReopeningDatabase() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let key = SymmetricKey(size: .bits256)
        let path = folder.appendingPathComponent("notes.sqlite").path
        let repo = try ClipboardRepository(path: path, key: key)
        let first = try repo.addNote(text: "First")
        let second = try repo.addNote(text: "Second")
        try repo.moveNote(first, to: .inside(second))
        let reopened = try ClipboardRepository(path: path, key: key)
        XCTAssertEqual(try reopened.notes().first { $0.id == first }?.parentID, second)
    }

    func testDropZonesDistinguishSiblingAndChildMoves() {
        XCTAssertEqual(NoteDropDestination.row("target", y: 2, height: 40), .before("target"))
        XCTAssertEqual(NoteDropDestination.row("target", y: 20, height: 40), .inside("target"))
        XCTAssertEqual(NoteDropDestination.row("target", y: 38, height: 40), .after("target"))
    }

    func testAfterIndicatorFollowsEntireVisibleSubtree() {
        let root = OutlineNote(id: "root", parentID: nil, position: 0, text: "Root", expanded: true)
        let child = OutlineNote(id: "child", parentID: "root", position: 0, text: "Child", expanded: true)
        let leaf = OutlineNote(id: "leaf", parentID: "child", position: 0, text: "Leaf", expanded: true)
        let next = OutlineNote(id: "next", parentID: nil, position: 1, text: "Next", expanded: true)
        let rows = [VisibleNote(note: root, depth: 0), VisibleNote(note: child, depth: 1), VisibleNote(note: leaf, depth: 2), VisibleNote(note: next, depth: 0)]
        let marker = NoteInsertionMarker(destination: .after("root"), rows: rows)
        XCTAssertEqual(marker?.rowID, "leaf")
        XCTAssertEqual(marker?.depth, 0)
        XCTAssertEqual(marker?.atTop, false)
        XCTAssertEqual(NoteInsertionMarker(destination: .before("child"), rows: rows)?.rowID, "child")
        XCTAssertNil(NoteInsertionMarker(destination: .inside("root"), rows: rows))
        XCTAssertEqual(NoteInsertionMarker(destination: .after("root"), rows: [rows[0], rows[3]])?.rowID, "root")
    }

    func testDragProviderPreservesNoteIdentity() async throws {
        let provider = NoteDrag.provider("note-id")
        let loaded: Data = try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: NoteDrag.type.identifier) { data, error in
                if let error { continuation.resume(throwing: error) }
                else if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: CocoaError(.fileReadUnknown)) }
            }
        }
        XCTAssertEqual(String(data: loaded, encoding: .utf8), "note-id")
    }
}
