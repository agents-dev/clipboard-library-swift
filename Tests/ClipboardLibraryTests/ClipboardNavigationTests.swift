import XCTest
import SwiftUI
import CryptoKit
import GRDB
@testable import ClipboardLibrary

final class ClipboardNavigationTests: XCTestCase {
    @MainActor func testArrowKeysNavigateClipsWhileSearchKeepsFocus() async throws {
        _ = NSApplication.shared
        let repository = try ClipboardRepository(path: ":memory:", key: SymmetricKey(size: .bits256))
        try repository.addNote(text: "First note line\nSecond note line")
        for index in 0..<3 {
            try repository.capture([.init(itemIndex: 0, uti: "public.utf8-plain-text", data: Data("Clip \(index)".utf8))], source: "Test", preview: "Clip \(index)")
        }
        try await repository.db.write { try $0.execute(sql: "UPDATE items SET state='Ready'") }
        let model = try AppModel(repository: repository)
        model.timer?.invalidate()
        await model.searchTask?.value
        let host = NSHostingView(rootView: LibraryView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 620), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(for: .milliseconds(150))
        func find<T: NSView>(_ view: NSView, matching: (T) -> Bool = { _ in true }) -> T? {
            if let result = view as? T, matching(result) { return result }
            return view.subviews.compactMap { find($0, matching: matching) }.first
        }
        let search: NSTextField = try XCTUnwrap(find(host) { $0.placeholderString == "Search clipboard history" })
        let table: NSTableView = try XCTUnwrap(find(host))
        XCTAssertEqual(table.numberOfRows, 3)
        XCTAssertTrue(window.makeFirstResponder(search))
        func arrow(_ down: Bool) throws {
            let characters = String(UnicodeScalar(down ? NSDownArrowFunctionKey : NSUpArrowFunctionKey)!)
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.function, .numericPad], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: down ? 125 : 126))
            NSApp.sendEvent(event)
        }
        try arrow(true)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(table.selectedRow, 0)
        try arrow(true)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(table.selectedRow, 1)
        try arrow(false)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(table.selectedRow, 0)
        XCTAssertTrue(search.currentEditor() === window.firstResponder)

        window.makeFirstResponder(nil)
        try arrow(true)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(table.selectedRow, 1, "Arrows must still work after a drag clears editor focus")
        try arrow(false)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(table.selectedRow, 0)

        let note: NoteNativeTextField = try XCTUnwrap(find(host))
        XCTAssertTrue(window.makeFirstResponder(note))
        try arrow(true)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(table.selectedRow, 0, "Editing a note must not navigate clips")

        XCTAssertTrue(window.makeFirstResponder(table))
        try arrow(true)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(table.selectedRow, 1, "A list arrow must advance exactly once")
        try arrow(true)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(table.selectedRow, 2)
        try arrow(true)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(table.selectedRow, 2, "Navigation must stop at the last clip")

        XCTAssertTrue(window.makeFirstResponder(note))
        window.orderOut(nil)
        window.makeKeyAndOrderFront(nil)
        model.pickerPresentation += 1
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(search.currentEditor() === window.firstResponder, "Reopening the picker must restore Search focus")
        try arrow(false)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(table.selectedRow, 1)
    }

    @MainActor func testArrowRoutingIgnoresModifiersAndSheets() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        let capture = ClipboardNavigationView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        window.contentView = capture
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        XCTAssertTrue(window.makeFirstResponder(capture))
        var moves: [Int] = []
        capture.moveSelection = { moves.append($0) }
        func event(_ modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: String(UnicodeScalar(NSDownArrowFunctionKey)!),
                charactersIgnoringModifiers: String(UnicodeScalar(NSDownArrowFunctionKey)!), isARepeat: true, keyCode: 125))
        }
        for modifier: NSEvent.ModifierFlags in [.shift, .command, .option, .control] {
            XCTAssertFalse(capture.handleArrow(try event(modifier)))
        }
        XCTAssertTrue(moves.isEmpty)
        XCTAssertTrue(capture.handleArrow(try event([.function, .numericPad])))
        XCTAssertEqual(moves, [1], "Repeated plain arrows must keep navigating")
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.beginSheet(sheet)
        defer { window.endSheet(sheet); sheet.orderOut(nil) }
        XCTAssertFalse(capture.handleArrow(try event([])))
        XCTAssertEqual(moves, [1])
    }
}
