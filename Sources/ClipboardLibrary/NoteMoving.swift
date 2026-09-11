import Foundation
import GRDB

enum NoteDropDestination: Equatable {
    case before(String)
    case after(String)
    case inside(String)
    case rootEnd

    var targetID: String? {
        switch self {
        case .before(let id), .after(let id), .inside(let id): return id
        case .rootEnd: return nil
        }
    }

    static func row(_ id: String, y: CGFloat, height: CGFloat) -> Self {
        if y < height * 0.25 { return .before(id) }
        if y > height * 0.75 { return .after(id) }
        return .inside(id)
    }
}

struct NoteInsertionMarker {
    let rowID: String
    let depth: Int
    let atTop: Bool

    init?(destination: NoteDropDestination, rows: [VisibleNote]) {
        switch destination {
        case .before, .after: break
        case .inside, .rootEnd: return nil
        }
        guard let start = rows.firstIndex(where: { $0.id == destination.targetID }) else { return nil }
        depth = rows[start].depth
        if case .before = destination {
            rowID = rows[start].id
            atTop = true
        } else {
            var end = start
            while end + 1 < rows.count, rows[end + 1].depth > depth { end += 1 }
            rowID = rows[end].id
            atTop = false
        }
    }
}

struct NoteMovePlan {
    let parentID: String?
    let oldSiblingIDs: [String]
    let newSiblingIDs: [String]

    init(id: String, destination: NoteDropDestination, notes: [OutlineNote]) throws {
        let byID = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })
        guard let source = byID[id] else { throw NoteMoveError.missingNote }
        var parent: String?
        if let targetID = destination.targetID {
            guard targetID != id else { throw NoteMoveError.cycle }
            guard let target = byID[targetID] else { throw NoteMoveError.missingNote }
            if case .inside = destination { parent = target.id }
            else { parent = target.parentID }
        }
        // Walk up from the proposed parent; reject the source and any existing loop.
        var ancestor = parent
        var visited: Set<String> = []
        while let current = ancestor {
            guard current != id, visited.insert(current).inserted else { throw NoteMoveError.cycle }
            guard let note = byID[current] else { throw NoteMoveError.missingNote }
            ancestor = note.parentID
        }
        func siblings(_ parent: String?) -> [String] {
            notes.filter { $0.parentID == parent && $0.id != id }
                .sorted { $0.position == $1.position ? $0.id < $1.id : $0.position < $1.position }
                .map(\.id)
        }
        var destinationIDs = siblings(parent)
        switch destination {
        case .before(let target), .after(let target):
            guard let index = destinationIDs.firstIndex(of: target) else { throw NoteMoveError.missingNote }
            let offset: Int
            if case .after = destination { offset = 1 } else { offset = 0 }
            destinationIDs.insert(id, at: index + offset)
        case .inside, .rootEnd: destinationIDs.append(id)
        }
        parentID = parent
        oldSiblingIDs = source.parentID == parent ? [] : siblings(source.parentID)
        newSiblingIDs = destinationIDs
    }
}

enum NoteMoveError: LocalizedError {
    case missingNote
    case cycle
    var errorDescription: String? {
        switch self {
        case .missingNote: return "This note no longer exists. Try moving it again."
        case .cycle: return "A note cannot be moved into itself or its descendants."
        }
    }
}

extension ClipboardRepository {
    func moveNote(_ id: String, to destination: NoteDropDestination) throws {
        try db.write { db in
            let notes = try OutlineNote.fetchAll(db)
            let plan = try NoteMovePlan(id: id, destination: destination, notes: notes)
            // Move only the branch root. Descendant IDs, parents, text, and files stay intact.
            try db.execute(sql: "UPDATE notes SET parentID=? WHERE id=?", arguments: [plan.parentID, id])
            for ids in [plan.oldSiblingIDs, plan.newSiblingIDs] {
                for (position, siblingID) in ids.enumerated() {
                    try db.execute(sql: "UPDATE notes SET position=? WHERE id=?", arguments: [position, siblingID])
                }
            }
            if let parentID = plan.parentID {
                try db.execute(sql: "UPDATE notes SET expanded=1 WHERE id=?", arguments: [parentID])
            }
        }
    }
}
