import XCTest
import SwiftUI
@testable import ClipboardLibrary

final class NoteViewTests: XCTestCase {
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
