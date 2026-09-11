import XCTest
import CryptoKit
import AppKit
import GRDB
@testable import ClipboardLibrary

final class StorageTests: XCTestCase {
    func testOutlineNoteHierarchyAndRecursiveDelete() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try ClipboardRepository(path: ":memory:", payloads: EncryptedStorage(directory: root, key: SymmetricKey(size: .bits256)))
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
        let repo = try ClipboardRepository(path: ":memory:", payloads: EncryptedStorage(directory: root, key: SymmetricKey(size: .bits256)))
        let vector = try MobileCLIP.shared.text("a receipt")
        try repo.db.write { db in
            let item = try db.makeStatement(sql: "INSERT INTO items(id,created,lastSeen,source,preview,hash) VALUES(?,0,0,'benchmark',?,'test')")
            let fts = try db.makeStatement(sql: "INSERT INTO search(id,text) VALUES(?,?)")
            let vec = try db.makeStatement(sql: "INSERT INTO vectors(id,embedding) VALUES(?,?)")
            for i in 0..<100000 {
                let id = String(i), text = "receipt number \(i)"
                try item.execute(arguments: [id,text]); try fts.execute(arguments: [id,text]); try vec.execute(arguments: [id,vector])
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
        let storage = try EncryptedStorage(directory: root, key: SymmetricKey(size: .bits256))
        let repo = try ClipboardRepository(path: ":memory:", payloads: storage)
        let representations = [PasteboardRepresentation(itemIndex: 0, uti: "public.utf8-plain-text", data: Data("hello world".utf8)), .init(itemIndex: 0, uti: "custom.raw", data: Data([0,255,8])), .init(itemIndex: 1, uti: "empty", data: Data())]
        let id = try repo.capture(representations, source: "test", preview: "hello world")
        XCTAssertEqual(try repo.representations(id), representations)
        XCTAssertNotEqual(try Data(contentsOf: root.appendingPathComponent(id)), try JSONEncoder().encode(representations))
        XCTAssertEqual(try repo.capture(representations, source: "test", preview: "hello world"), id)
        XCTAssertEqual(try repo.items().first?.useCount, 2)
        XCTAssertEqual(try repo.items(query: "hel").first?.id, id)
        try repo.index(id, text: "scanned receipt")
        XCTAssertEqual(try repo.items(query: "receipt").first?.id, id)
        try repo.delete(id)
        XCTAssertTrue(try repo.items().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(id).path))
    }
    func testTamperDetection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try EncryptedStorage(directory: root, key: SymmetricKey(size: .bits256))
        try storage.save(Data("private".utf8), id: "payload")
        var bytes = try Data(contentsOf: root.appendingPathComponent("payload")); bytes[15] ^= 1
        try bytes.write(to: root.appendingPathComponent("payload"))
        XCTAssertThrowsError(try storage.read("payload"))
    }
}
