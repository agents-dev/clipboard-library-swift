import AppKit
import CryptoKit
import GRDB

struct NoteFile: Sendable {
    let name: String
    let data: Data
    static let maximumFileSize = 25 * 1024 * 1024
    static let maximumBatchSize = 100 * 1024 * 1024

    func validate() throws {
        guard !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains("\\"), !name.contains(":"), !name.contains("\0") else {
            throw NoteImportError.message("The file name is invalid: \(name)")
        }
        guard data.count <= Self.maximumFileSize else {
            throw NoteImportError.message("Files must be 25 MB or smaller: \(name)")
        }
    }

    static func urls(from pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    static func read(_ urls: [URL]) throws -> [NoteFile] {
        var total = 0
        return try urls.map { url in
            guard url.isFileURL else { throw NoteImportError.message("Paste files copied from Finder.") }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { throw NoteImportError.message("Paste individual files, not folders: \(url.lastPathComponent)") }
            guard (values.fileSize ?? 0) <= maximumFileSize else { throw NoteImportError.message("Files must be 25 MB or smaller: \(url.lastPathComponent)") }
            let file = NoteFile(name: url.lastPathComponent, data: try Data(contentsOf: url))
            try file.validate()
            total += file.data.count
            guard total <= maximumBatchSize else { throw NoteImportError.message("Paste up to 100 MB at a time.") }
            return file
        }
    }

    func writeToPasteboard(_ pasteboard: NSPasteboard, exportRoot: URL) throws {
        try validate()
        // Use a fresh directory so later pastes and duplicate filenames cannot change an earlier export.
        let directory = exportRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        pasteboard.clearContents()
        guard pasteboard.writeObjects([url as NSURL]) else { throw NoteImportError.message("Could not copy the file to the clipboard.") }
    }
}

enum NoteImportError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

extension ClipboardRepository {
    /// Return the group ID, or the last attached file ID when importing without a group.
    @discardableResult func importNoteFiles(_ files: [NoteFile], group: String? = nil, parentID: String? = nil) throws -> String {
        guard !files.isEmpty else { throw NoteImportError.message("No files were found to import.") }
        var total = 0
        let sealed = try files.map { file -> Data in
            try file.validate()
            total += file.data.count
            guard total <= NoteFile.maximumBatchSize else { throw NoteImportError.message("Import up to 100 MB at a time.") }
            return try AES.GCM.seal(file.data, using: key).combined!
        }
        return try db.write { db in
            func insert(_ text: String, parent: String?, filename: String? = nil) throws -> String {
                let id = UUID().uuidString
                let position = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(position),-1)+1 FROM notes WHERE parentID IS ?", arguments: [parent]) ?? 0
                try db.execute(sql: "INSERT INTO notes(id,parentID,position,text,attachmentName) VALUES(?,?,?,?,?)", arguments: [id, parent, position, text, filename])
                return id
            }
            if let parentID { try db.execute(sql: "UPDATE notes SET expanded=1 WHERE id=?", arguments: [parentID]) }
            let groupID = try group.map { try insert($0, parent: parentID) }
            var lastID = ""
            for (index, file) in files.enumerated() {
                let title = group == nil ? file.name : (file.name as NSString).deletingPathExtension
                lastID = try insert(title, parent: groupID ?? parentID, filename: file.name)
                try db.execute(sql: "INSERT INTO noteFiles(noteID,sealed) VALUES(?,?)", arguments: [lastID, sealed[index]])
            }
            return groupID ?? lastID
        }
    }

    func noteFile(_ id: String) throws -> NoteFile? {
        try db.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT notes.attachmentName, noteFiles.sealed FROM notes JOIN noteFiles ON noteFiles.noteID=notes.id WHERE notes.id=?", arguments: [id]) else { return nil }
            let name: String = row["attachmentName"]
            let sealed: Data = row["sealed"]
            return NoteFile(name: name, data: try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key))
        }
    }
}
