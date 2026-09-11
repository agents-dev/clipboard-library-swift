import XCTest
import CryptoKit
@testable import ClipboardLibrary

final class ClipboardDragTests: XCTestCase {
    func testDropBelowChildPreservesParentAndSiblingOrder() throws {
        let repo = try ClipboardRepository(path: ":memory:", key: SymmetricKey(size: .bits256))
        let parent = try repo.addNote(text: "Parent")
        let child = try repo.addNote(parentID: parent, text: "Child")
        let next = try repo.addNote(parentID: parent, text: "Next")
        let anchor = try XCTUnwrap(repo.notes().first { $0.id == child })
        let inserted = try repo.addNote(after: anchor, text: "Dropped text")
        let children = try repo.notes().filter { $0.parentID == parent }
        XCTAssertEqual(children.map(\.id), [child, inserted, next])
        XCTAssertEqual(children.map(\.position), [0, 1, 2])
    }

    func testDragUsesFullOriginalTextAndPreservesItemOrder() {
        let reps: [PasteboardRepresentation] = [
            .init(itemIndex: 1, uti: "public.utf8-plain-text", data: Data("Second".utf8)),
            .init(itemIndex: 0, uti: "public.url", data: Data("https://example.com".utf8)),
            .init(itemIndex: 0, uti: "public.utf8-plain-text", data: Data("First\nFull text".utf8))
        ]
        XCTAssertEqual(clipboardNoteText(reps, fallback: "Truncated"), "First\nFull text\nSecond")
    }

    func testDragUsesURLOrPreviewWhenPlainTextIsUnavailable() {
        XCTAssertEqual(clipboardNoteText([
            .init(itemIndex: 0, uti: "public.url", data: Data("https://example.com".utf8))
        ], fallback: "Preview"), "https://example.com")
        XCTAssertEqual(clipboardNoteText([
            .init(itemIndex: 0, uti: "public.png", data: Data([1, 2]))
        ], fallback: "Image"), "Image")
    }
}
