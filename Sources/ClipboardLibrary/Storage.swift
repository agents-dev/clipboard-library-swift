import Foundation
import CryptoKit
import GRDB
import CSQLiteVec

struct PasteboardRepresentation: Codable, Equatable {
    var itemIndex: Int
    var uti: String
    var data: Data
}
struct ClipboardItem: Identifiable, FetchableRecord, TableRecord, Decodable {
    static let databaseTableName = "items"
    var id: String
    var created: Double
    var lastSeen: Double
    var source: String
    var preview: String
    var hash: String
    var pinned: Bool
    var useCount: Int
    var state: String
    var tags: String
}
struct OutlineNote: Identifiable, FetchableRecord, TableRecord, Decodable, Equatable {
    static let databaseTableName = "notes"
    var id: String
    var parentID: String?
    var position: Int
    var text: String
    var expanded: Bool
    var attachmentName: String? = nil
}
enum LocalKeyFile {
    static func loadOrCreate(at url: URL) throws -> SymmetricKey {
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if manager.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            guard data.count == 32 else { throw CocoaError(.fileReadCorruptFile) }
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return key
    }
}
final class ClipboardRepository: @unchecked Sendable {
    let db: DatabaseQueue
    let key: SymmetricKey
    init(path: String, key: SymmetricKey) throws {
        self.key = key
        var configuration = Configuration()
        configuration.prepareDatabase { database in
            guard sqlite3_vec_init(database.sqliteConnection, nil, nil) == 0 else { throw NSError(domain: "SQLiteVec", code: 1) }
        }
        db = try DatabaseQueue(path: path, configuration: configuration)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: "CREATE TABLE items(id TEXT PRIMARY KEY, created DOUBLE NOT NULL, lastSeen DOUBLE NOT NULL, source TEXT NOT NULL, preview TEXT NOT NULL, hash TEXT NOT NULL, pinned BOOLEAN NOT NULL DEFAULT 0, useCount INTEGER NOT NULL DEFAULT 1, state TEXT NOT NULL DEFAULT 'Indexing', tags TEXT NOT NULL DEFAULT ''); CREATE VIRTUAL TABLE search USING fts5(id UNINDEXED, text); CREATE TABLE markup(id TEXT PRIMARY KEY, itemID TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE, name TEXT NOT NULL, document BLOB NOT NULL)")
        }
        migrator.registerMigration("v2-local-vectors") { db in
            try db.execute(sql: "CREATE VIRTUAL TABLE vectors USING vec0(id TEXT PRIMARY KEY, embedding float[512]); CREATE TABLE indexVersion(version INTEGER NOT NULL); INSERT INTO indexVersion VALUES(1)")
        }
        migrator.registerMigration("v3-mobileclip") { db in
            try db.execute(sql: "DELETE FROM vectors; UPDATE items SET state='Indexing'; UPDATE indexVersion SET version=2; CREATE VIRTUAL TABLE imageVectors USING vec0(id TEXT PRIMARY KEY, embedding float[512])")
        }
        migrator.registerMigration("v4-outline-notes") { db in
            try db.execute(sql: "CREATE TABLE notes(id TEXT PRIMARY KEY, parentID TEXT REFERENCES notes(id) ON DELETE CASCADE, position INTEGER NOT NULL, text TEXT NOT NULL DEFAULT '', expanded BOOLEAN NOT NULL DEFAULT 1); CREATE INDEX notes_parent_position ON notes(parentID, position)")
        }
        migrator.registerMigration("v5-database-payloads") { db in
            try db.execute(sql: "CREATE TABLE payloads(itemID TEXT PRIMARY KEY REFERENCES items(id) ON DELETE CASCADE, sealed BLOB NOT NULL)")
        }
        migrator.registerMigration("v6-note-files") { db in
            try db.execute(sql: "ALTER TABLE notes ADD COLUMN attachmentName TEXT; CREATE TABLE noteFiles(noteID TEXT PRIMARY KEY REFERENCES notes(id) ON DELETE CASCADE, sealed BLOB NOT NULL)")
        }
        migrator.registerMigration("v7-history-order") { db in
            try db.execute(sql: "CREATE INDEX items_recent ON items(lastSeen DESC); CREATE INDEX items_picker_order ON items(pinned DESC,lastSeen DESC)")
        }
        try migrator.migrate(db)
    }
    @discardableResult func capture(_ representations: [PasteboardRepresentation], source: String, preview: String) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(representations)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let previous = try db.read { try ClipboardItem.fetchOne($0, sql: "SELECT items.* FROM items JOIN payloads ON payloads.itemID=items.id ORDER BY lastSeen DESC LIMIT 1") }
        if let previous, previous.hash == hash {
            try db.write { try $0.execute(sql: "UPDATE items SET lastSeen=?, useCount=useCount+1 WHERE id=?", arguments: [Date().timeIntervalSince1970, previous.id]) }; return previous.id
        }
        let id = UUID().uuidString
        let sealed = try AES.GCM.seal(data, using: key).combined!
        try db.write { db in
            let now = Date().timeIntervalSince1970
            try db.execute(sql: "INSERT INTO items(id,created,lastSeen,source,preview,hash) VALUES(?,?,?,?,?,?)", arguments: [id, now, now, source, preview, hash])
            try db.execute(sql: "INSERT INTO search(id,text) VALUES(?,?)", arguments: [id, preview + " " + source + " " + representations.map(\.uti).joined(separator: " ")])
            try db.execute(sql: "INSERT INTO payloads(itemID,sealed) VALUES(?,?)", arguments: [id, sealed])
        }
        return id
    }
    func representations(_ id: String) throws -> [PasteboardRepresentation] {
        guard let sealed = try db.read({ try Data.fetchOne($0, sql: "SELECT sealed FROM payloads WHERE itemID=?", arguments: [id]) }) else {
            throw NSError(domain: "ClipboardLibrary", code: 1, userInfo: [NSLocalizedDescriptionKey: "This item uses the old Keychain-backed storage format."])
        }
        let data = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key)
        return try JSONDecoder().decode([PasteboardRepresentation].self, from: data)
    }
    func items(query: String = "", semantic: Bool = true) throws -> [ClipboardItem] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let queryVector = query.isEmpty || !semantic ? nil : try? MobileCLIP.shared.text(query)
        return try db.read { db in
            if query.isEmpty { return try ClipboardItem.fetchAll(db, sql: "SELECT items.* FROM items JOIN payloads ON payloads.itemID=items.id ORDER BY pinned DESC,lastSeen DESC LIMIT 300") }
            let terms = query.split(whereSeparator: \.isWhitespace).map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"*" }.joined(separator: " AND ")
            guard !terms.isEmpty else { return [] }
            var results = try ClipboardItem.fetchAll(db, sql: "SELECT items.* FROM search JOIN items ON items.id=search.id JOIN payloads ON payloads.itemID=items.id WHERE search MATCH ? ORDER BY pinned DESC,rank,lastSeen DESC LIMIT 300", arguments: [terms])
            if let vector = queryVector {
                let matches = try ClipboardItem.fetchAll(db, sql: "SELECT items.* FROM vectors JOIN items ON items.id=vectors.id JOIN payloads ON payloads.itemID=items.id WHERE embedding MATCH ? AND k=40 ORDER BY distance", arguments: [vector])
                let seen = Set(results.map(\.id)); results.append(contentsOf: matches.filter { !seen.contains($0.id) })
                let images = try ClipboardItem.fetchAll(db, sql: "SELECT items.* FROM imageVectors JOIN items ON items.id=imageVectors.id JOIN payloads ON payloads.itemID=items.id WHERE embedding MATCH ? AND k=40 ORDER BY distance", arguments: [vector])
                let existing = Set(results.map(\.id)); results.append(contentsOf: images.filter { !existing.contains($0.id) })
            }
            return results
        }
    }
    func index(_ id: String, text: String, image: Data? = nil) throws {
        let item = try db.read { try ClipboardItem.fetchOne($0, key: id) }; guard let item else { return }
        let vector = try MobileCLIP.shared.text(item.preview + " " + text)
        let imageVector = try image.map { try MobileCLIP.shared.image($0) }
        try db.write { db in
        guard let item = try ClipboardItem.fetchOne(db, key: id) else { return }
        try db.execute(sql: "UPDATE search SET text=? WHERE id=?", arguments: [item.preview + " " + item.source + " " + item.tags + " " + text, id])
        try db.execute(sql: "UPDATE items SET state='Ready' WHERE id=?", arguments: [id])
        do {
            try db.execute(sql: "DELETE FROM vectors WHERE id=?", arguments: [id])
            try db.execute(sql: "INSERT INTO vectors(id,embedding) VALUES(?,?)", arguments: [id, vector])
        }
        if let imageVector {
            try db.execute(sql: "DELETE FROM imageVectors WHERE id=?", arguments: [id])
            try db.execute(sql: "INSERT INTO imageVectors(id,embedding) VALUES(?,?)", arguments: [id,imageVector])
        }
    } }
    func pin(_ item: ClipboardItem) throws { try db.write { try $0.execute(sql: "UPDATE items SET pinned=? WHERE id=?", arguments: [!item.pinned, item.id]) } }
    func pending() throws -> [String] { try db.read { try String.fetchAll($0, sql: "SELECT items.id FROM items JOIN payloads ON payloads.itemID=items.id WHERE state='Indexing' ORDER BY created") } }
    func rebuild() throws { try db.write { try $0.execute(sql: "UPDATE items SET state='Indexing' WHERE id IN (SELECT itemID FROM payloads)") } }
    func setTags(_ id: String, tags: String) throws { try db.write { try $0.execute(sql: "UPDATE items SET tags=?,state='Indexing' WHERE id=?", arguments: [tags,id]) } }
    func delete(_ id: String) throws { try db.write { try $0.execute(sql: "DELETE FROM payloads WHERE itemID=?; DELETE FROM imageVectors WHERE id=?; DELETE FROM vectors WHERE id=?; DELETE FROM search WHERE id=?; DELETE FROM items WHERE id=?", arguments: [id,id,id,id,id]) } }
    func deleteAll() throws { let ids = try db.read { try String.fetchAll($0, sql: "SELECT id FROM items") }; for id in ids { try delete(id) } }
    func notes() throws -> [OutlineNote] { try db.read { try OutlineNote.fetchAll($0, sql: "SELECT * FROM notes ORDER BY position,id") } }
    @discardableResult func addNote(parentID: String? = nil, after: OutlineNote? = nil, text: String = "") throws -> String {
        let id = UUID().uuidString
        try db.write { db in
            let parent = after?.parentID ?? parentID
            let position: Int
            if let after { position = after.position + 1 }
            else { position = (try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(position),-1)+1 FROM notes WHERE parentID IS ?", arguments: [parent])) ?? 0 }
            try db.execute(sql: "UPDATE notes SET position=position+1 WHERE parentID IS ? AND position>=?", arguments: [parent,position])
            try db.execute(sql: "INSERT INTO notes(id,parentID,position,text) VALUES(?,?,?,?)", arguments: [id,parent,position,text])
        }
        return id
    }
    func updateNote(_ id: String, text: String? = nil, expanded: Bool? = nil) throws { try db.write { db in
        if let text { try db.execute(sql: "UPDATE notes SET text=? WHERE id=?", arguments: [text,id]) }
        if let expanded { try db.execute(sql: "UPDATE notes SET expanded=? WHERE id=?", arguments: [expanded,id]) }
    } }
    func deleteNote(_ id: String) throws { try db.write { try $0.execute(sql: "WITH RECURSIVE descendants(id) AS (SELECT ? UNION ALL SELECT notes.id FROM notes JOIN descendants ON notes.parentID=descendants.id) DELETE FROM notes WHERE id IN descendants", arguments: [id]) } }
    func deleteNotePromotingChildren(_ id: String) throws { try db.write { db in
        guard let note = try OutlineNote.fetchOne(db, key: id) else { return }
        let children = try OutlineNote.fetchAll(db, sql: "SELECT * FROM notes WHERE parentID=? ORDER BY position,id", arguments: [id])
        let positionDelta = children.count - 1
        try db.execute(
            sql: "UPDATE notes SET position=position+? WHERE parentID IS ? AND position>?",
            arguments: [positionDelta, note.parentID, note.position]
        )
        for (offset, child) in children.enumerated() {
            try db.execute(
                sql: "UPDATE notes SET parentID=?,position=? WHERE id=?",
                arguments: [note.parentID, note.position + offset, child.id]
            )
        }
        try db.execute(sql: "DELETE FROM notes WHERE id=?", arguments: [id])
    } }
    func indentNote(_ note: OutlineNote) throws { try db.write { db in
        guard let previous = try OutlineNote.fetchOne(db, sql: "SELECT * FROM notes WHERE parentID IS ? AND position<? ORDER BY position DESC LIMIT 1", arguments: [note.parentID,note.position]) else { return }
        let position = (try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(position),-1)+1 FROM notes WHERE parentID=?", arguments: [previous.id])) ?? 0
        try db.execute(sql: "UPDATE notes SET parentID=?,position=? WHERE id=?; UPDATE notes SET expanded=1 WHERE id=?", arguments: [previous.id,position,note.id,previous.id])
    } }
    func outdentNote(_ note: OutlineNote) throws { try db.write { db in
        guard let parentID = note.parentID, let parent = try OutlineNote.fetchOne(db, key: parentID) else { return }
        try db.execute(sql: "UPDATE notes SET position=position+1 WHERE parentID IS ? AND position>?", arguments: [parent.parentID,parent.position])
        try db.execute(sql: "UPDATE notes SET parentID=?,position=? WHERE id=?", arguments: [parent.parentID,parent.position+1,note.id])
    } }
}
