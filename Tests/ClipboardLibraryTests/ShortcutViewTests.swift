import XCTest
import SwiftUI
@testable import ClipboardLibrary

final class ShortcutViewTests: XCTestCase {
    @MainActor func testEditorFitsAndRendersAllActionKinds() async throws {
        _ = NSApplication.shared
        let suite = "ShortcutViewTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = ShortcutController(store: ShortcutStore(defaults: defaults))
        let mapping = ShortcutMapping(name: "Example: open menu, select item", trigger: .init(keyCode: 18, modifiers: .command),
                                      bundleID: "com.example.editor", actions: [
                                        .chord(.init(keyCode: 46, modifiers: [.control, .shift])), .key(18),
                                        .text("Hello 🌍\nSecond line"), .delay(0.5)
                                      ])
        let view = NSHostingView(rootView: ShortcutEditor(controller: controller, value: mapping))
        view.frame = NSRect(x: 0, y: 0, width: 850, height: 650)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(200))
        view.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(view.fittingSize.width, 850)
        XCTAssertLessThanOrEqual(view.fittingSize.height, 650)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-shortcut-editor.png")
        try data.write(to: output)
        print("SHORTCUT_EDITOR_SNAPSHOT \(output.path)")
        if ProcessInfo.processInfo.environment["SHORTCUT_CAPTURE_WINDOW"] == "1" {
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-l", String(window.windowNumber), output.path]
            try capture.run()
            capture.waitUntilExit()
            XCTAssertEqual(capture.terminationStatus, 0)
        }
        window.contentView = nil
        controller.stop()
    }
}
