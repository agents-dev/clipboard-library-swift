import XCTest
import CryptoKit
import AppKit
import GRDB
@testable import ClipboardLibrary

final class StorageTests: XCTestCase {
    @MainActor func testReplacementFocusClearsThenMovesOnNextMainLoopCycle() async {
        var focusChanges: [String?] = []
        let focusedPrevious = expectation(description: "Focus moves to previous note")

        scheduleReplacementNoteFocus("previous") { value in
            focusChanges.append(value)
            if value == "previous" { focusedPrevious.fulfill() }
        }

        XCTAssertEqual(focusChanges, [nil])
        await fulfillment(of: [focusedPrevious], timeout: 1)
        XCTAssertEqual(focusChanges, [nil, "previous"])
    }

    func testBackspaceDeletesOnlyAnAlreadyEmptyNoteField() {
        var deleteCount = 0
        let coordinator = NoteTextFieldCoordinator(
            textChanged: { _ in },
            deleteEmpty: { deleteCount += 1 },
            submit: {}
        )
        let field = NSTextField(string: "")
        let editor = NSTextView()

        XCTAssertTrue(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.deleteBackward(_:))))
        XCTAssertEqual(deleteCount, 1)

        field.stringValue = "text"
        XCTAssertFalse(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.deleteBackward(_:))))
        XCTAssertEqual(deleteCount, 1)
    }

    func testReplacementNoteFocusPrefersPreviousThenNext() {
        let first = OutlineNote(id: "first", parentID: nil, position: 0, text: "", expanded: true)
        let second = OutlineNote(id: "second", parentID: nil, position: 1, text: "", expanded: true)
        let third = OutlineNote(id: "third", parentID: nil, position: 2, text: "", expanded: true)
        let rows = [first, second, third].map { VisibleNote(note: $0, depth: 0) }

        XCTAssertEqual(replacementNoteID(removing: "second", from: rows), "first")
        XCTAssertEqual(replacementNoteID(removing: "first", from: rows), "second")
        XCTAssertNil(replacementNoteID(removing: "first", from: [rows[0]]))
    }

    func testDeletingNoteAndPromotingChildrenPreservesOutlineOrder() throws {
        let repo = try ClipboardRepository(path: ":memory:", key: SymmetricKey(size: .bits256))
        let beforeID = try repo.addNote(text: "Before")
        let parentID = try repo.addNote(text: "Parent")
        let parent = try XCTUnwrap(repo.notes().first { $0.id == parentID })
        let afterID = try repo.addNote(after: parent, text: "After")
        let firstChildID = try repo.addNote(parentID: parentID, text: "First child")
        let secondChildID = try repo.addNote(parentID: parentID, text: "Second child")

        try repo.deleteNotePromotingChildren(parentID)

        let notes = try repo.notes()
        XCTAssertEqual(notes.map(\.id), [beforeID, firstChildID, secondChildID, afterID])
        XCTAssertTrue(notes.allSatisfy { $0.parentID == nil })
        XCTAssertEqual(notes.map(\.position), [0, 1, 2, 3])
    }

    func testOutlineNoteHierarchyAndRecursiveDelete() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try ClipboardRepository(path: ":memory:", key: SymmetricKey(size: .bits256))
        let firstID = try repo.addNote(text: "First")
        let first = try XCTUnwrap(repo.notes().first { $0.id == firstID })
        let secondID = try repo.addNote(after: first, text: "Second")
        var second = try XCTUnwrap(repo.notes().first { $0.id == secondID })

        try repo.indentNote(second)
        second = try XCTUnwrap(repo.notes().first { $0.id == secondID })
        XCTAssertEqual(second.parentID, firstID)

        try repo.updateNote(secondID, text: "Nested", expanded: false)
        second = try XCTUnwrap(repo.notes().first { $0.id == secondID })
        XCTAssertEqual(second.text, "Nested")
        XCTAssertFalse(second.expanded)

        try repo.outdentNote(second)
        second = try XCTUnwrap(repo.notes().first { $0.id == secondID })
        XCTAssertNil(second.parentID)

        let childID = try repo.addNote(parentID: firstID, text: "Child")
        try repo.deleteNote(firstID)
        let remainingIDs = Set(try repo.notes().map(\.id))
        XCTAssertFalse(remainingIDs.contains(firstID))
        XCTAssertFalse(remainingIDs.contains(childID))
        XCTAssertTrue(remainingIDs.contains(secondID))
    }
    func testHundredThousandEntrySearch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try ClipboardRepository(path: ":memory:", key: SymmetricKey(size: .bits256))
        let vector = try MobileCLIP.shared.text("a receipt")
        try repo.db.write { db in
            let item = try db.makeStatement(sql: "INSERT INTO items(id,created,lastSeen,source,preview,hash) VALUES(?,0,0,'benchmark',?,'test')")
            let fts = try db.makeStatement(sql: "INSERT INTO search(id,text) VALUES(?,?)")
            let vec = try db.makeStatement(sql: "INSERT INTO vectors(id,embedding) VALUES(?,?)")
            let payload = try db.makeStatement(sql: "INSERT INTO payloads(itemID,sealed) VALUES(?,?)")
            for i in 0..<100000 {
                let id = String(i), text = "receipt number \(i)"
                try item.execute(arguments: [id,text]); try fts.execute(arguments: [id,text]); try vec.execute(arguments: [id,vector]); try payload.execute(arguments: [id,Data()])
            }
        }
        let start = Date()
        let rows = try repo.items(query: "receipt")
        let milliseconds = Date().timeIntervalSince(start) * 1000
        print("BENCHMARK 100000 entries combined search: \(milliseconds) ms, \(rows.count) results")
        XCTAssertFalse(rows.isEmpty)
    }
    func testBundledImageAndTextEmbeddings() throws {
        let text = try MobileCLIP.shared.text("a red square")
        XCTAssertEqual(text.count, 512 * 4)
        let image = NSImage(size: NSSize(width: 256, height: 256), flipped: false) { rect in NSColor.red.setFill(); rect.fill(); return true }
        let vector = try MobileCLIP.shared.image(XCTUnwrap(image.tiffRepresentation))
        XCTAssertEqual(vector.count, 512 * 4)
        let tokens = try CLIPTokens().encode(String(repeating: "hello ", count: 1000))
        XCTAssertEqual(tokens.count, 77); XCTAssertEqual(tokens.last, 49407)
    }
    func testRoundTripSearchDedupAndDelete() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try ClipboardRepository(path: ":memory:", key: SymmetricKey(size: .bits256))
        let representations = [PasteboardRepresentation(itemIndex: 0, uti: "public.utf8-plain-text", data: Data("hello world".utf8)), .init(itemIndex: 0, uti: "custom.raw", data: Data([0,255,8])), .init(itemIndex: 1, uti: "empty", data: Data())]
        let id = try repo.capture(representations, source: "test", preview: "hello world")
        XCTAssertEqual(try repo.representations(id), representations)
        let sealed = try XCTUnwrap(repo.db.read { try Data.fetchOne($0, sql: "SELECT sealed FROM payloads WHERE itemID=?", arguments: [id]) })
        XCTAssertNotEqual(sealed, try JSONEncoder().encode(representations))
        XCTAssertEqual(try repo.capture(representations, source: "test", preview: "hello world"), id)
        XCTAssertEqual(try repo.items().first?.useCount, 2)
        XCTAssertEqual(try repo.items(query: "hel").first?.id, id)
        try repo.index(id, text: "scanned receipt")
        XCTAssertEqual(try repo.items(query: "receipt").first?.id, id)
        try repo.delete(id)
        XCTAssertTrue(try repo.items().isEmpty)
        XCTAssertNil(try repo.db.read { try Data.fetchOne($0, sql: "SELECT sealed FROM payloads WHERE itemID=?", arguments: [id]) })
    }
    func testLegacyMetadataDoesNotSuppressDatabaseCapture() throws {
        let repo = try ClipboardRepository(path: ":memory:", key: SymmetricKey(size: .bits256))
        let representations = [PasteboardRepresentation(itemIndex: 0, uti: "public.text", data: Data("same".utf8))]
        let encoded = try JSONEncoder().encode(representations)
        let hash = SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
        try repo.db.write { db in
            try db.execute(sql: "INSERT INTO items(id,created,lastSeen,source,preview,hash) VALUES('legacy',0,1,'test','same',?)", arguments: [hash])
            try db.execute(sql: "INSERT INTO search(id,text) VALUES('legacy','same')")
        }
        let id = try repo.capture(representations, source: "test", preview: "same")
        XCTAssertNotEqual(id, "legacy")
        XCTAssertEqual(try repo.representations(id), representations)
        XCTAssertEqual(try repo.items().map(\.id), [id])
    }
    func testTamperDetection() throws {
        let repo = try ClipboardRepository(path: ":memory:", key: SymmetricKey(size: .bits256))
        let id = try repo.capture([.init(itemIndex: 0, uti: "public.text", data: Data("private".utf8))], source: "test", preview: "private")
        try repo.db.write { db in
            var sealed = try XCTUnwrap(Data.fetchOne(db, sql: "SELECT sealed FROM payloads WHERE itemID=?", arguments: [id]))
            sealed[15] ^= 1
            try db.execute(sql: "UPDATE payloads SET sealed=? WHERE itemID=?", arguments: [sealed, id])
        }
        XCTAssertThrowsError(try repo.representations(id))
    }
    func testLocalKeyFilePersistsAndUsesOwnerOnlyPermissions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("history.key")
        let first = try LocalKeyFile.loadOrCreate(at: url).withUnsafeBytes { Data($0) }
        let second = try LocalKeyFile.loadOrCreate(at: url).withUnsafeBytes { Data($0) }
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 32)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
}
