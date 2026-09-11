import Foundation
import Carbon

struct ShortcutModifiers: OptionSet, Codable, Hashable {
    let rawValue: UInt32
    static let command = Self(rawValue: 1)
    static let shift = Self(rawValue: 2)
    static let control = Self(rawValue: 4)
    static let option = Self(rawValue: 8)
    var carbon: UInt32 {
        (contains(.command) ? UInt32(cmdKey) : 0) | (contains(.shift) ? UInt32(shiftKey) : 0) |
        (contains(.control) ? UInt32(controlKey) : 0) | (contains(.option) ? UInt32(optionKey) : 0)
    }
    var label: String {
        (contains(.control) ? "⌃" : "") + (contains(.option) ? "⌥" : "") +
        (contains(.shift) ? "⇧" : "") + (contains(.command) ? "⌘" : "")
    }
}

struct ShortcutTrigger: Codable, Hashable {
    var keyCode: UInt16
    var modifiers: ShortcutModifiers
    var label: String { modifiers.label + ShortcutKeys.label(keyCode) }
}

enum ShortcutAction: Codable, Equatable {
    case chord(ShortcutTrigger)
    case key(UInt16)
    case text(String)
    case delay(Double)
}

struct ShortcutMapping: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var trigger: ShortcutTrigger
    var bundleID: String? = nil
    var enabled = true
    var actions: [ShortcutAction]
}

struct ShortcutError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum ShortcutKeys {
    // Physical macOS virtual keys. Text actions use Unicode instead of this layout.
    static let all: [(UInt16, String)] = [
        (0,"A"),(11,"B"),(8,"C"),(2,"D"),(14,"E"),(3,"F"),(5,"G"),(4,"H"),(34,"I"),(38,"J"),(40,"K"),(37,"L"),(46,"M"),
        (45,"N"),(31,"O"),(35,"P"),(12,"Q"),(15,"R"),(1,"S"),(17,"T"),(32,"U"),(9,"V"),(13,"W"),(7,"X"),(16,"Y"),(6,"Z"),
        (29,"0"),(18,"1"),(19,"2"),(20,"3"),(21,"4"),(23,"5"),(22,"6"),(26,"7"),(28,"8"),(25,"9"),
        (36,"Return"),(48,"Tab"),(49,"Space"),(51,"Delete"),(53,"Escape"),(117,"Forward Delete"),
        (123,"Left"),(124,"Right"),(125,"Down"),(126,"Up"),(115,"Home"),(119,"End"),(116,"Page Up"),(121,"Page Down"),
        (27,"-"),(24,"="),(33,"["),(30,"]"),(42,"\\"),(41,";"),(39,"'"),(43,","),(47,"."),(44,"/"),(50,"`"),
        (122,"F1"),(120,"F2"),(99,"F3"),(118,"F4"),(96,"F5"),(97,"F6"),(98,"F7"),(100,"F8"),(101,"F9"),(109,"F10"),(103,"F11"),(111,"F12"),
        (105,"F13"),(107,"F14"),(113,"F15"),(106,"F16"),(64,"F17"),(79,"F18"),(80,"F19"),(90,"F20"),
        (82,"Keypad 0"),(83,"Keypad 1"),(84,"Keypad 2"),(85,"Keypad 3"),(86,"Keypad 4"),(87,"Keypad 5"),(88,"Keypad 6"),(89,"Keypad 7"),(91,"Keypad 8"),(92,"Keypad 9"),
        (65,"Keypad ."),(67,"Keypad *"),(69,"Keypad +"),(75,"Keypad /"),(76,"Keypad Enter"),(78,"Keypad -"),(81,"Keypad ="),(71,"Clear")
    ]
    static func label(_ code: UInt16) -> String { all.first { $0.0 == code }?.1 ?? "Key \(code)" }
    static func valid(_ code: UInt16) -> Bool { all.contains { $0.0 == code } }
}

enum ShortcutValidation {
    static func validate(_ mappings: [ShortcutMapping], reserved: ShortcutTrigger) throws {
        var seen: [ShortcutTrigger: Set<String>] = [:]
        var identifiers = Set<UUID>()
        for mapping in mappings {
            guard identifiers.insert(mapping.id).inserted else { throw ShortcutError("Each mapping must have a unique identifier.") }
            guard !mapping.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ShortcutError("Enter a mapping name.") }
            try validateActions(mapping.actions)
            guard ShortcutKeys.valid(mapping.trigger.keyCode), mapping.trigger.modifiers.rawValue > 0,
                  mapping.trigger.modifiers.rawValue & ~15 == 0 else { throw ShortcutError("Choose a trigger key with Command, Control, Option, or Shift.") }
            guard mapping.trigger != reserved else { throw ShortcutError("This trigger is reserved for the clipboard picker.") }
            if let bundleID = mapping.bundleID, bundleID.isEmpty || bundleID.contains(where: { $0.isWhitespace }) {
                throw ShortcutError("Enter an application bundle ID without spaces.")
            }
            let scope = mapping.bundleID ?? ""
            guard seen[mapping.trigger, default: []].insert(scope).inserted else { throw ShortcutError("This trigger already has a mapping for the same application scope.") }
        }
    }

    static func validateActions(_ actions: [ShortcutAction]) throws {
        guard !actions.isEmpty else { throw ShortcutError("Add at least one action.") }
        for action in actions {
            switch action {
            case .key(let code):
                guard ShortcutKeys.valid(code) else { throw ShortcutError("Choose a supported action key.") }
            case .chord(let trigger):
                guard ShortcutKeys.valid(trigger.keyCode), trigger.modifiers.rawValue & ~15 == 0 else { throw ShortcutError("Choose a supported chord.") }
            case .text(let text):
                guard !text.isEmpty else { throw ShortcutError("Enter text for the text action.") }
            case .delay(let seconds):
                guard seconds.isFinite, (0...10).contains(seconds) else { throw ShortcutError("Set each wait between 0 and 10 seconds.") }
            }
        }
    }
}

enum ShortcutResolver {
    static func resolve(trigger: ShortcutTrigger, frontmostBundleID: String?, from mappings: [ShortcutMapping]) -> ShortcutMapping? {
        let candidates = mappings.filter { $0.enabled && $0.trigger == trigger }
        if let bundleID = frontmostBundleID, let local = candidates.first(where: { $0.bundleID == bundleID }) { return local }
        return candidates.first { $0.bundleID == nil }
    }
}

final class ShortcutStore {
    static let key = "shortcutMappings.v1"
    static let backupKey = "shortcutMappings.invalidBackup"
    struct Envelope: Codable { var version: Int; var mappings: [ShortcutMapping] }
    let defaults: UserDefaults
    private(set) var errorMessage: String?
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func load() -> [ShortcutMapping] {
        errorMessage = nil
        guard let data = defaults.data(forKey: Self.key) else { return [] }
        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard envelope.version == 1 else { throw ShortcutError("Unsupported shortcut data version.") }
            // Picker reservation is checked after the saved picker key is known.
            try ShortcutValidation.validate(envelope.mappings, reserved: .init(keyCode: .max, modifiers: []))
            return envelope.mappings
        } catch {
            defaults.set(data, forKey: Self.backupKey)
            errorMessage = "Cannot load shortcut mappings. The original data has been preserved. \(error.localizedDescription)"
            return []
        }
    }
    func save(_ mappings: [ShortcutMapping]) throws {
        let data = try JSONEncoder().encode(Envelope(version: 1, mappings: mappings))
        defaults.set(data, forKey: Self.key)
    }
}

struct RegistrationIssue: Identifiable {
    var id: String { message }
    let message: String
}

@MainActor final class ShortcutRegistry {
    static let signature: OSType = 0x4D415050
    private var ids: [ShortcutTrigger: UInt32] = [:]
    private var active: Set<ShortcutTrigger> = []
    private var nextID: UInt32 = 1
    private let register: (ShortcutTrigger, UInt32) -> OSStatus
    private let unregister: (UInt32) -> Void

    init(register: @escaping (ShortcutTrigger, UInt32) -> OSStatus, unregister: @escaping (UInt32) -> Void) {
        self.register = register; self.unregister = unregister
    }
    convenience init() {
        var references: [UInt32: EventHotKeyRef] = [:]
        self.init(register: { trigger, id in
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(trigger.keyCode), trigger.modifiers.carbon,
                EventHotKeyID(signature: Self.signature, id: id), GetApplicationEventTarget(), 0, &ref)
            if let ref, status == noErr { references[id] = ref }
            return status
        }, unregister: { id in
            if let ref = references.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        })
    }
    func apply(_ mappings: [ShortcutMapping], reservedTrigger: ShortcutTrigger) -> [RegistrationIssue] {
        do { try ShortcutValidation.validate(mappings, reserved: reservedTrigger) }
        catch { return [.init(message: error.localizedDescription)] }
        let wanted = Set(mappings.filter(\.enabled).map(\.trigger))
        for trigger in active.subtracting(wanted) { unregister(ids[trigger]!); active.remove(trigger) }
        var issues: [RegistrationIssue] = []
        for trigger in wanted.subtracting(active).sorted(by: { ($0.keyCode, $0.modifiers.rawValue) < ($1.keyCode, $1.modifiers.rawValue) }) {
            if ids[trigger] == nil { ids[trigger] = nextID; nextID += 1 }
            let result = register(trigger, ids[trigger]!)
            if result == noErr { active.insert(trigger) }
            else { issues.append(.init(message: "\(trigger.label) is unavailable (\(result)). Choose another trigger or release it in the other application.")) }
        }
        return issues
    }
    func trigger(for id: UInt32) -> ShortcutTrigger? { active.first { ids[$0] == id } }
    func stop() { for trigger in active { unregister(ids[trigger]!) }; active.removeAll() }
}
