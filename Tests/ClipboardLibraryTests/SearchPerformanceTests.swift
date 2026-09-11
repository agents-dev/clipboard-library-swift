import XCTest
import CryptoKit
import GRDB
@testable import ClipboardLibrary

final class SearchPerformanceTests: XCTestCase {
    func testTextSearchDoesNotRequireReadablePayload() throws {
        let repo = try ClipboardRepository(path: ":memory:", key: SymmetricKey(size: .bits256))
        let id = try repo.capture([.init(itemIndex: 0, uti: "public.utf8-plain-text", data: Data("needle".utf8))], source: "test", preview: "needle")
        try repo.db.write { try $0.execute(sql: "UPDATE payloads SET sealed=?", arguments: [Data()]) }
        XCTAssertEqual(try repo.items(query: "need", semantic: false).map(\.id), [id])
    }

    func testRecentHistoryUsesOrderedIndex() throws {
        let repo = try ClipboardRepository(path: ":memory:", key: SymmetricKey(size: .bits256))
        let plan = try repo.db.read { db in
            try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN SELECT items.* FROM items JOIN payloads ON payloads.itemID=items.id ORDER BY pinned DESC,lastSeen DESC LIMIT 300")
                .map { $0["detail"] as String }.joined(separator: "\n")
        }
        XCTAssertFalse(plan.contains("TEMP B-TREE"), plan)
    }

    func testWhitespaceSearchReturnsRecentHistory() throws {
        let repo = try ClipboardRepository(path: ":memory:", key: SymmetricKey(size: .bits256))
        let id = try repo.capture([.init(itemIndex: 0, uti: "public.utf8-plain-text", data: Data("hello".utf8))], source: "test", preview: "hello")
        XCTAssertEqual(try repo.items(query: "  ").map(\.id), [id])
    }
}
