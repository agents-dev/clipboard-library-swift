import AppKit
import ApplicationServices

enum ShortcutOutput: Equatable {
    case key(code: UInt16, modifiers: ShortcutModifiers, down: Bool)
    case text(String, down: Bool)
}

@MainActor final class ShortcutExecutor {
    private(set) var isRunning = false
    private let send: (ShortcutOutput) throws -> Void
    private let sleep: (Double) async throws -> Void
    private let isTargetActive: (pid_t) -> Bool
    private let prepare: () async throws -> Void
    private let watchTarget: (pid_t, @escaping () -> Void) -> (() -> Void)

    init(send: @escaping (ShortcutOutput) throws -> Void,
         sleep: @escaping (Double) async throws -> Void,
         isTargetActive: @escaping (pid_t) -> Bool,
         prepare: @escaping () async throws -> Void = {},
         watchTarget: @escaping (pid_t, @escaping () -> Void) -> (() -> Void) = { _, _ in {} }) {
        self.send = send; self.sleep = sleep; self.isTargetActive = isTargetActive; self.prepare = prepare
        self.watchTarget = watchTarget
    }

    convenience init() {
        self.init(send: Self.post, sleep: { seconds in
            try await Task.sleep(for: .seconds(seconds))
        }, isTargetActive: { pid in
            NSWorkspace.shared.frontmostApplication?.processIdentifier == pid &&
            NSRunningApplication(processIdentifier: pid)?.isTerminated == false
        }, prepare: {
            guard AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) else {
                throw ShortcutError("Enable Clipboard Library in System Settings → Privacy & Security → Accessibility, then try again.")
            }
            // Wait for physical trigger keys to be released before synthesizing output.
            for _ in 0..<200 {
                let flags = CGEventSource.flagsState(.hidSystemState)
                if flags.intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate]).isEmpty { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw ShortcutError("Release the trigger modifiers and try again.")
        }, watchTarget: { target, changed in
            let center = NSWorkspace.shared.notificationCenter
            let activation = center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
                if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                   app.processIdentifier != target { changed() }
            }
            let termination = center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { note in
                if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                   app.processIdentifier == target { changed() }
            }
            return { center.removeObserver(activation); center.removeObserver(termination) }
        })
    }

    func execute(_ mapping: ShortcutMapping, target: pid_t) async throws {
        guard !isRunning else { return }
        try ShortcutValidation.validateActions(mapping.actions)
        isRunning = true
        defer { isRunning = false }
        var targetChanged = false
        let stopWatching = watchTarget(target) { targetChanged = true }
        defer { stopWatching() }
        try await prepare()
        for (index, action) in mapping.actions.enumerated() {
            try Task.checkCancellation()
            guard !targetChanged, isTargetActive(target) else { throw ShortcutError("Sequence cancelled because the destination application closed or lost focus.") }
            switch action {
            case .key(let code): try pair(.key(code: code, modifiers: [], down: true), .key(code: code, modifiers: [], down: false))
            case .chord(let chord): try pair(.key(code: chord.keyCode, modifiers: chord.modifiers, down: true), .key(code: chord.keyCode, modifiers: chord.modifiers, down: false))
            case .text(let text): try pair(.text(text, down: true), .text(text, down: false))
            case .delay(let seconds): try await sleep(seconds)
            }
            if index < mapping.actions.count - 1, case .delay = action { continue }
            if index < mapping.actions.count - 1 { try await sleep(0.02) }
        }
    }

    private func pair(_ down: ShortcutOutput, _ up: ShortcutOutput) throws {
        try send(down)
        do { try send(up) } catch { try? send(up); throw error }
    }

    static func post(_ output: ShortcutOutput) throws {
        try makeEvent(output).post(tap: .cghidEventTap)
    }

    static func makeEvent(_ output: ShortcutOutput) throws -> CGEvent {
        let source = CGEventSource(stateID: .privateState)
        let event: CGEvent?
        switch output {
        case .key(let code, let modifiers, let down):
            event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            var flags: CGEventFlags = []
            if modifiers.contains(.command) { flags.insert(.maskCommand) }
            if modifiers.contains(.shift) { flags.insert(.maskShift) }
            if modifiers.contains(.control) { flags.insert(.maskControl) }
            if modifiers.contains(.option) { flags.insert(.maskAlternate) }
            event?.flags = flags
        case .text(let text, let down):
            event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
            event?.flags = []
            let units = Array(text.utf16)
            units.withUnsafeBufferPointer { buffer in
                event?.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            }
        }
        guard let event else { throw ShortcutError("Cannot create a keyboard event.") }
        event.setIntegerValueField(.eventSourceUserData, value: 0x4D415050)
        return event
    }
}

@MainActor final class ShortcutController: ObservableObject {
    @Published private(set) var mappings: [ShortcutMapping] = []
    @Published var message = ""
    @Published private(set) var testing = false
    let store: ShortcutStore
    let registry = ShortcutRegistry()
    let executor = ShortcutExecutor()
    var reservedTrigger = ShortcutTrigger(keyCode: 9, modifiers: [.command, .shift])
    var onEditingChanged: ((Bool) -> Void)?
    private var suspended = false
    private var task: Task<Void, Never>?

    init(store: ShortcutStore = ShortcutStore()) {
        self.store = store
        mappings = store.load(); message = store.errorMessage ?? ""
    }
    func refresh() {
        guard !suspended else { return }
        let issues = registry.apply(mappings, reservedTrigger: reservedTrigger)
        if !issues.isEmpty { message = issues.map(\.message).joined(separator: "\n") }
    }
    @discardableResult func save(_ mapping: ShortcutMapping) -> Bool {
        var next = mappings
        if let index = next.firstIndex(where: { $0.id == mapping.id }) { next[index] = mapping }
        else { next.append(mapping) }
        return persist(next)
    }
    @discardableResult func persist(_ next: [ShortcutMapping]) -> Bool {
        do {
            try ShortcutValidation.validate(next, reserved: reservedTrigger)
            try store.save(next)
            mappings = next; message = ""; refresh(); return true
        } catch { message = error.localizedDescription; return false }
    }
    func setEditing(_ editing: Bool) {
        suspended = editing
        onEditingChanged?(editing)
        if editing { registry.stop() } else { refresh() }
    }
    func fire(_ id: UInt32) {
        guard !suspended, !executor.isRunning, task == nil,
              let trigger = registry.trigger(for: id), let app = NSWorkspace.shared.frontmostApplication,
              let mapping = ShortcutResolver.resolve(trigger: trigger, frontmostBundleID: app.bundleIdentifier, from: mappings) else { return }
        run(mapping, target: app.processIdentifier)
    }
    private func run(_ mapping: ShortcutMapping, target: pid_t) {
        // Remove our global grabs so generated output reaches the destination,
        // including output that happens to match another mapping or the picker.
        registry.stop()
        onEditingChanged?(true)
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                task = nil
                if !suspended { onEditingChanged?(false); refresh() }
            }
            do {
                try await executor.execute(mapping, target: target)
                try await Task.sleep(for: .milliseconds(50))
                message = "Finished: \(mapping.name)"
            }
            catch { message = error.localizedDescription }
        }
    }
    func test(_ mapping: ShortcutMapping) {
        guard task == nil, !executor.isRunning else { return }
        do { try ShortcutValidation.validateActions(mapping.actions) }
        catch { message = error.localizedDescription; return }
        testing = true
        task = Task { [weak self] in
            guard let self else { return }
            defer { task = nil; testing = false }
            do {
                for second in (1...3).reversed() {
                    message = "Test starts in \(second). Focus the destination application."
                    try await Task.sleep(for: .seconds(1))
                }
                guard let app = NSWorkspace.shared.frontmostApplication,
                      app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
                    throw ShortcutError("Test cancelled. Focus another application during the countdown.")
                }
                try await executor.execute(mapping, target: app.processIdentifier)
                message = "Test finished: \(mapping.name)"
            } catch { message = error.localizedDescription }
        }
    }
    func cancelTest() { task?.cancel() }
    func stop() { task?.cancel(); registry.stop() }
}
