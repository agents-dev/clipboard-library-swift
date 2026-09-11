import SwiftUI

/// Route arrows before AppKit's search field editor or list consumes them.
struct ClipboardKeyNavigation: NSViewRepresentable {
    let move: (Int) -> Void
    func makeNSView(context: Context) -> ClipboardNavigationView { ClipboardNavigationView() }
    func updateNSView(_ view: ClipboardNavigationView, context: Context) { view.moveSelection = move }
}

final class ClipboardNavigationView: NSView {
    var moveSelection: ((Int) -> Void)?
    private var monitor: Any?
    private var selectedArea = true
    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { [weak self] event in
            guard let self, event.window === self.window, self.window?.attachedSheet == nil else { return event }
            if event.type == .leftMouseDown {
                self.selectedArea = self.bounds.contains(self.convert(event.locationInWindow, from: nil))
                if self.selectedArea, !self.containsResponder() { self.window?.makeFirstResponder(self) }
            } else if self.handleArrow(event) { return nil }
            return event
        }
    }

    private func containsResponder() -> Bool {
        guard let responder = window?.firstResponder else { return selectedArea }
        if responder === self { return true }
        let view: NSView?
        if let editor = responder as? NSTextView { view = (editor.delegate as? NSView) ?? editor }
        else { view = responder as? NSView }
        guard let view else { return selectedArea }
        let rect = convert(view.bounds, from: view)
        // A hosting view may span both panes; use the last clicked pane in that case.
        if rect.width > bounds.width + 1 { return selectedArea }
        return bounds.intersects(rect)
    }

    func handleArrow(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.window === window, window?.attachedSheet == nil,
              event.keyCode == 125 || event.keyCode == 126,
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
              containsResponder(), let moveSelection else { return false }
        moveSelection(event.keyCode == 125 ? 1 : -1)
        return true
    }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}
