import XCTest
import SwiftUI
@testable import ClipboardLibrary

final class NoteViewTests: XCTestCase {
    @MainActor func testDoubleClickSkillRowCopiesAMarkdownFile() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let original = Data("# Build and run\n\nKeep this Markdown unchanged.\n".utf8)
        var copyError: Error?
        let host = NSHostingView(rootView: NoteTextField(
            initialText: "build-run-debug", selected: false,
            paste: { _ in
                do { try NoteFile(name: "build-run-debug.md", data: original).writeToPasteboard(board, exportRoot: directory) }
                catch { copyError = error }
            }, save: { _ in }, deleteIfEmpty: {}, submit: {}, focused: .constant(false)
        ))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(for: .milliseconds(100))
        func findField(_ view: NSView) -> NoteNativeTextField? {
            if let field = view as? NoteNativeTextField { return field }
            return view.subviews.compactMap { findField($0) }.first
        }
        let field = try XCTUnwrap(findField(host))
        let point = field.convert(NSPoint(x: field.bounds.midX, y: field.bounds.midY), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 2, pressure: 1))
        NSApp.sendEvent(event)
        XCTAssertNil(copyError)
        let url = try XCTUnwrap(NoteFile.urls(from: board).first)
        XCTAssertEqual(url.lastPathComponent, "build-run-debug.md")
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    @MainActor func testFocusSelectsNoteBeforeTyping() async throws {
        _ = NSApplication.shared
        var selection = "old"
        let host = NSHostingView(rootView: NoteTextField(
            initialText: "First line\nSecond line", selected: false,
            save: { _ in }, deleteIfEmpty: {}, submit: {},
            focused: Binding(get: { selection == "new" }, set: { if $0 { selection = "new" } })
        ))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 160),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(for: .milliseconds(100))
        func findField(_ view: NSView) -> NoteNativeTextField? {
            if let field = view as? NoteNativeTextField { return field }
            return view.subviews.compactMap { findField($0) }.first
        }
        let field = try XCTUnwrap(findField(host))
        window.makeFirstResponder(nil)
        selection = "old"
        XCTAssertTrue(window.makeFirstResponder(field))
        XCTAssertEqual(selection, "new", "Focus must move selection without a text edit")
        XCTAssertEqual(field.currentEditor()?.string, "First line\nSecond line")
    }

    @MainActor func testCollapsedNoteRetainsFullTextForSelectionAndDoubleClick() async throws {
        _ = NSApplication.shared
        var pasted: [String] = []
        var saved: [String] = []
        func content(selected: Bool) -> NoteTextField {
            NoteTextField(initialText: "First line\nSecond line\nThird line", selected: selected,
                          paste: { pasted.append($0) }, save: { saved.append($0) },
                          deleteIfEmpty: {}, submit: {}, focused: .constant(false))
        }
        let host = NSHostingView(rootView: content(selected: false))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 160),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(for: .milliseconds(100))
        func findField(_ view: NSView) -> NoteNativeTextField? {
            if let field = view as? NoteNativeTextField { return field }
            return view.subviews.compactMap { findField($0) }.first
        }
        let field = try XCTUnwrap(findField(host))
        XCTAssertEqual(field.stringValue, "First line")
        host.rootView = content(selected: true)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(field.stringValue, "First line\nSecond line\nThird line")
        host.rootView = content(selected: false)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(field.stringValue, "First line")
        let point = field.convert(NSPoint(x: field.bounds.midX, y: field.bounds.midY), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 2, pressure: 1))
        NSApp.sendEvent(event)
        XCTAssertEqual(pasted, ["First line\nSecond line\nThird line"])
        XCTAssertTrue(saved.isEmpty, "Display changes must not overwrite the stored note")
    }
}
