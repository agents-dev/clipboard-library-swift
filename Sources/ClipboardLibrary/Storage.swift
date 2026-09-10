import Foundation
import CryptoKit
import Security
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
protocol PayloadStorage: Sendable { func save(_ data: Data, id: String) throws; func read(_ id: String) throws -> Data; func remove(_ id: String) throws }
final class EncryptedStorage: PayloadStorage, @unchecked Sendable {
    let directory: URL
    let key: SymmetricKey
    init(directory: URL, key: SymmetricKey? = nil) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let key { self.key = key; return }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "local.ClipboardLibrary", kSecAttrAccount as String: "payload-key"]
        var result: CFTypeRef?
        var read = query; read[kSecReturnData as String] = true
        let status = SecItemCopyMatching(read as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data { self.key = SymmetricKey(data: data) }
        else if status == errSecItemNotFound {
            let newKey = SymmetricKey(size: .bits256)
            var insert = query; insert[kSecValueData as String] = newKey.withUnsafeBytes { Data($0) }; insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let saved = SecItemAdd(insert as CFDictionary, nil)
            guard saved == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(saved)) }
            self.key = newKey
        } else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
    func save(_ data: Data, id: String) throws { try AES.GCM.seal(data, using: key).combined!.write(to: directory.appendingPathComponent(id), options: .atomic) }
    func read(_ id: String) throws -> Data { try AES.GCM.open(AES.GCM.SealedBox(combined: Data(contentsOf: directory.appendingPathComponent(id))), using: key) }
    func remove(_ id: String) throws { let url = directory.appendingPathComponent(id); if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) } }
}
final class ClipboardRepository: @unchecked Sendable {
    let db: DatabaseQueue
    let payloads: PayloadStorage
    init(path: String, payloads: PayloadStorage) throws {
        self.payloads = payloads
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
        try migrator.migrate(db)
    }
    @discardableResult func capture(_ representations: [PasteboardRepresentation], source: String, preview: String) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(representations)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let previous = try db.read { try ClipboardItem.fetchOne($0, sql: "SELECT * FROM items ORDER BY lastSeen DESC LIMIT 1") }
        if let previous, previous.hash == hash {
            try db.write { try $0.execute(sql: "UPDATE items SET lastSeen=?, useCount=useCount+1 WHERE id=?", arguments: [Date().timeIntervalSince1970, previous.id]) }; return previous.id
        }
        let id = UUID().uuidString; try payloads.save(data, id: id)
        do { try db.write { db in
            let now = Date().timeIntervalSince1970
            try db.execute(sql: "INSERT INTO items(id,created,lastSeen,source,preview,hash) VALUES(?,?,?,?,?,?)", arguments: [id, now, now, source, preview, hash])
            try db.execute(sql: "INSERT INTO search(id,text) VALUES(?,?)", arguments: [id, preview + " " + source + " " + representations.map(\.uti).joined(separator: " ")])
        } } catch { try? payloads.remove(id); throw error }; return id
    }
    func representations(_ id: String) throws -> [PasteboardRepresentation] { try JSONDecoder().decode([PasteboardRepresentation].self, from: payloads.read(id)) }
    func items(query: String = "") throws -> [ClipboardItem] {
        let queryVector = query.isEmpty ? nil : try? MobileCLIP.shared.text(query)
        return try db.read { db in
            if query.isEmpty { return try ClipboardItem.fetchAll(db, sql: "SELECT * FROM items ORDER BY pinned DESC,lastSeen DESC LIMIT 300") }
            let terms = query.split(whereSeparator: \.isWhitespace).map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"*" }.joined(separator: " AND ")
            guard !terms.isEmpty else { return [] }
            var results = try ClipboardItem.fetchAll(db, sql: "SELECT items.* FROM search JOIN items ON items.id=search.id WHERE search MATCH ? ORDER BY pinned DESC,rank,lastSeen DESC LIMIT 300", arguments: [terms])
            if let vector = queryVector {
                let matches = try ClipboardItem.fetchAll(db, sql: "SELECT items.* FROM vectors JOIN items ON items.id=vectors.id WHERE embedding MATCH ? AND k=40 ORDER BY distance", arguments: [vector])
                let seen = Set(results.map(\.id)); results.append(contentsOf: matches.filter { !seen.contains($0.id) })
                let images = try ClipboardItem.fetchAll(db, sql: "SELECT items.* FROM imageVectors JOIN items ON items.id=imageVectors.id WHERE embedding MATCH ? AND k=40 ORDER BY distance", arguments: [vector])
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
    func pending() throws -> [String] { try db.read { try String.fetchAll($0, sql: "SELECT id FROM items WHERE state='Indexing' ORDER BY created") } }
    func rebuild() throws { try db.write { try $0.execute(sql: "UPDATE items SET state='Indexing'") } }
    func setTags(_ id: String, tags: String) throws { try db.write { try $0.execute(sql: "UPDATE items SET tags=?,state='Indexing' WHERE id=?", arguments: [tags,id]) } }
    func delete(_ id: String) throws { try db.write { try $0.execute(sql: "DELETE FROM imageVectors WHERE id=?; DELETE FROM vectors WHERE id=?; DELETE FROM search WHERE id=?; DELETE FROM items WHERE id=?", arguments: [id,id,id,id]) }; try payloads.remove(id) }
    func deleteAll() throws { let ids = try db.read { try String.fetchAll($0, sql: "SELECT id FROM items") }; for id in ids { try delete(id) } }
}
