import XCTest
import AppKit
@testable import ClipboardLibrary

final class ShortcutTests: XCTestCase {
    let trigger = ShortcutTrigger(keyCode: 18, modifiers: .command)
    let reserved = ShortcutTrigger(keyCode: 9, modifiers: [.command, .shift])

    func mapping(scope: String? = nil) -> ShortcutMapping {
        ShortcutMapping(name: "Example", trigger: trigger, bundleID: scope,
                        actions: [.chord(.init(keyCode: 46, modifiers: [.control, .shift])), .key(18)])
    }

    func testScopeResolutionAndDisabledFallback() {
        let global = mapping()
        var local = mapping(scope: "com.example.editor")
        XCTAssertEqual(ShortcutResolver.resolve(trigger: trigger, frontmostBundleID: "com.example.editor", from: [global, local])?.id, local.id)
        local.enabled = false
        XCTAssertEqual(ShortcutResolver.resolve(trigger: trigger, frontmostBundleID: "com.example.editor", from: [global, local])?.id, global.id)
        XCTAssertNil(ShortcutResolver.resolve(trigger: trigger, frontmostBundleID: "other", from: [mapping(scope: "com.example.editor")]))
    }

    func testRejectsConflictsAndInvalidActions() {
        XCTAssertThrowsError(try ShortcutValidation.validate([mapping(), mapping()], reserved: reserved))
        XCTAssertNoThrow(try ShortcutValidation.validate([mapping(), mapping(scope: "app.a"), mapping(scope: "app.b")], reserved: reserved))
        XCTAssertThrowsError(try ShortcutValidation.validate([mapping(scope: "app.a"), mapping(scope: "app.a")], reserved: reserved))
        var value = mapping()
        value.trigger = reserved
        XCTAssertThrowsError(try ShortcutValidation.validate([value], reserved: reserved))
        value.trigger = .init(keyCode: 18, modifiers: [])
        XCTAssertThrowsError(try ShortcutValidation.validate([value], reserved: reserved))
        value.trigger = trigger
        for actions: [ShortcutAction] in [[], [.delay(-1)], [.delay(10.1)], [.text("")], [.key(65535)]] {
            value.actions = actions
            XCTAssertThrowsError(try ShortcutValidation.validate([value], reserved: reserved))
        }
    }

    func testPersistenceAndCorruptPayloadPreservation() throws {
        let suite = "ShortcutTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ShortcutStore(defaults: defaults)
        XCTAssertEqual(store.load(), [])
        var value = mapping()
        value.actions += [.text("Hello 🌍"), .delay(0.5)]
        try store.save([value])
        XCTAssertEqual(store.load(), [value])
        let corrupt = Data("{broken".utf8)
        defaults.set(corrupt, forKey: ShortcutStore.key)
        XCTAssertEqual(store.load(), [])
        XCTAssertNotNil(store.errorMessage)
        try store.save([value])
        XCTAssertEqual(defaults.data(forKey: ShortcutStore.backupKey), corrupt)
        defaults.set(Data("{\"version\":999,\"mappings\":[]}".utf8), forKey: ShortcutStore.key)
        XCTAssertEqual(store.load(), [])
        XCTAssertNotNil(store.errorMessage)
    }

    @MainActor func testRegistryGroupsTriggersAndKeepsIDsStable() {
        var registrations: [UInt32] = []
        let registry = ShortcutRegistry(register: { _, id in registrations.append(id); return 0 }, unregister: { _ in })
        XCTAssertTrue(registry.apply([mapping(), mapping(scope: "app.a")], reservedTrigger: reserved).isEmpty)
        XCTAssertEqual(registrations.count, 1)
        let id = registrations[0]
        _ = registry.apply([], reservedTrigger: reserved)
        _ = registry.apply([mapping()], reservedTrigger: reserved)
        XCTAssertEqual(registrations.last, id)
        XCTAssertEqual(registry.trigger(for: id), trigger)
    }

    @MainActor func testExecutionOrderUnicodeAndBalancedEvents() async throws {
        var events: [ShortcutOutput] = []
        var waits: [Double] = []
        let executor = ShortcutExecutor(send: { events.append($0) }, sleep: { waits.append($0) }, isTargetActive: { _ in true })
        var value = mapping()
        value.actions += [.delay(0.4), .text("Hi 🌍")]
        try await executor.execute(value, target: 42)
        XCTAssertEqual(events, [
            .key(code: 46, modifiers: [.control, .shift], down: true),
            .key(code: 46, modifiers: [.control, .shift], down: false),
            .key(code: 18, modifiers: [], down: true),
            .key(code: 18, modifiers: [], down: false),
            .text("Hi 🌍", down: true), .text("Hi 🌍", down: false)
        ])
        XCTAssertEqual(waits, [0.02, 0.02, 0.4])
        XCTAssertFalse(executor.isRunning)
    }

    @MainActor func testFocusLossCancelsRemainingOutput() async {
        var active = true
        var events: [ShortcutOutput] = []
        let executor = ShortcutExecutor(send: { events.append($0) }, sleep: { _ in active = false }, isTargetActive: { _ in active })
        do { try await executor.execute(mapping(), target: 42); XCTFail("Expected cancellation") }
        catch { XCTAssertEqual(events.count, 2) }
        XCTAssertFalse(executor.isRunning)
    }

    @MainActor func testBusyExecutorIgnoresAnotherTrigger() async throws {
        var continuation: CheckedContinuation<Void, Never>?
        var events: [ShortcutOutput] = []
        let executor = ShortcutExecutor(send: { events.append($0) }, sleep: { _ in
            await withCheckedContinuation { continuation = $0 }
        }, isTargetActive: { _ in true })
        let first = Task { try await executor.execute(mapping(), target: 42) }
        while continuation == nil { await Task.yield() }
        try await executor.execute(mapping(), target: 42)
        XCTAssertEqual(events.count, 2)
        continuation?.resume()
        try await first.value
        XCTAssertEqual(events.count, 4)
    }

    @MainActor func testRegistrationFailureCanRetryWithoutLosingOtherTriggers() {
        var unavailable = true
        var removed: [UInt32] = []
        let registry = ShortcutRegistry(register: { _, _ in unavailable ? -9878 : 0 }, unregister: { removed.append($0) })
        XCTAssertEqual(registry.apply([mapping()], reservedTrigger: reserved).count, 1)
        XCTAssertNil(registry.trigger(for: 1))
        unavailable = false
        XCTAssertTrue(registry.apply([mapping()], reservedTrigger: reserved).isEmpty)
        XCTAssertEqual(registry.trigger(for: 1), trigger)
        var disabled = mapping(); disabled.enabled = false
        _ = registry.apply([disabled], reservedTrigger: reserved)
        XCTAssertEqual(removed, [1])
        XCTAssertNil(registry.trigger(for: 1))
    }

    @MainActor func testPreparationFailureProducesNoOutput() async {
        var count = 0
        let executor = ShortcutExecutor(send: { _ in count += 1 }, sleep: { _ in }, isTargetActive: { _ in true }, prepare: {
            throw ShortcutError("Permission unavailable")
        })
        do { try await executor.execute(mapping(), target: 42); XCTFail("Expected permission failure") } catch {}
        XCTAssertEqual(count, 0)
        XCTAssertFalse(executor.isRunning)
    }

    @MainActor func testNativeEventsUseExactModifiersAndUnicode() throws {
        let chord = try ShortcutExecutor.makeEvent(.key(code: 46, modifiers: [.control, .shift], down: true))
        XCTAssertEqual(chord.type, .keyDown)
        XCTAssertEqual(chord.getIntegerValueField(.keyboardEventKeycode), 46)
        XCTAssertEqual(chord.flags, [.maskControl, .maskShift])
        let up = try ShortcutExecutor.makeEvent(.key(code: 18, modifiers: [], down: false))
        XCTAssertEqual(up.type, .keyUp)
        XCTAssertTrue(up.flags.isEmpty)
        let text = try ShortcutExecutor.makeEvent(.text("Hi 🌍", down: true))
        var units = [UniChar](repeating: 0, count: 20)
        var length = 0
        text.keyboardGetUnicodeString(maxStringLength: units.count, actualStringLength: &length, unicodeString: &units)
        XCTAssertEqual(String(utf16CodeUnits: units, count: length), "Hi 🌍")
    }

    @MainActor func testBriefFocusChangeCancelsEvenIfDestinationReturns() async {
        var changed: (() -> Void)?
        var stoppedWatching = false
        var events: [ShortcutOutput] = []
        let executor = ShortcutExecutor(send: { events.append($0) }, sleep: { _ in changed?() }, isTargetActive: { _ in true },
                                        watchTarget: { _, callback in changed = callback; return { stoppedWatching = true } })
        do { try await executor.execute(mapping(), target: 42); XCTFail("Expected focus cancellation") } catch {}
        XCTAssertEqual(events.count, 2)
        XCTAssertTrue(stoppedWatching)
    }

    func testSemanticallyInvalidSavedMappingsArePreservedAndNotLoaded() throws {
        let suite = "ShortcutTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var invalid = mapping(); invalid.actions = []
        let data = try JSONEncoder().encode(ShortcutStore.Envelope(version: 1, mappings: [invalid]))
        defaults.set(data, forKey: ShortcutStore.key)
        let store = ShortcutStore(defaults: defaults)
        XCTAssertTrue(store.load().isEmpty)
        XCTAssertEqual(defaults.data(forKey: ShortcutStore.backupKey), data)
        let value = mapping()
        XCTAssertThrowsError(try ShortcutValidation.validate([value, value], reserved: reserved))
    }
}
