import Foundation

struct GitHubSkillLocation {
    let owner: String
    let repository: String
    let suffix: [String]
    let isBlob: Bool

    init(_ text: String) throws {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", url.host?.lowercased() == "github.com", url.user == nil, url.password == nil,
              url.port == nil else { throw NoteImportError.message("Enter an HTTPS GitHub repository or folder URL.") }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 2, !parts.contains(".."), !parts.contains(".") else {
            throw NoteImportError.message("Include the repository in the GitHub URL.")
        }
        guard parts.count == 2 || (parts.count >= 4 && ["tree", "blob"].contains(parts[2])) else {
            throw NoteImportError.message("Use a repository, folder, or SKILL.md URL from GitHub.")
        }
        owner = parts[0]
        repository = parts[1].hasSuffix(".git") ? String(parts[1].dropLast(4)) : parts[1]
        suffix = parts.count > 2 ? Array(parts.dropFirst(3)) : []
        isBlob = parts.count > 2 && parts[2] == "blob"
        if isBlob && suffix.last != "SKILL.md" { throw NoteImportError.message("Select a SKILL.md file or a folder containing skills.") }
    }
}

struct GitHubSkillGroup: Sendable {
    let name: String
    let files: [NoteFile]
}

struct GitHubSkillImporter {
    typealias Loader = (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let load: Loader
    init(load: @escaping Loader = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, response)
    }) { self.load = load }

    private struct Tree: Decodable {
        let tree: [Entry]
        var truncated: Bool? = nil
    }
    private struct Entry: Decodable {
        let path: String
        let type: String
        let sha: String
        var size: Int? = nil
        var mode: String? = nil
    }
    private struct Blob: Decodable { let encoding: String; let content: String }
    private struct Repository: Decodable { let default_branch: String }
    private struct HTTPFailure: Error { let status: Int }

    func fetch(_ text: String) async throws -> GitHubSkillGroup {
        let location = try GitHubSkillLocation(text)
        func api(_ parts: [String], recursive: Bool = false) -> URL {
            var url = URL(string: "https://api.github.com")!
            for part in ["repos", location.owner, location.repository] + parts { url.appendPathComponent(part) }
            if recursive {
                var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
                components.queryItems = [URLQueryItem(name: "recursive", value: "1")]
                return components.url!
            }
            return url
        }
        func request<T: Decodable>(_ type: T.Type, _ url: URL) async throws -> T {
            try Task.checkCancellation()
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("ClipboardLibrary", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await load(request)
            if response.statusCode == 403 || response.statusCode == 429 {
                throw NoteImportError.message("GitHub denied this request or its request limit was reached. Try again later. Public repositories are supported.")
            }
            guard (200..<300).contains(response.statusCode) else { throw HTTPFailure(status: response.statusCode) }
            return try JSONDecoder().decode(type, from: data)
        }
        do {
            var path: [String] = []
            var root: Tree?
            var resolvedRef = ""
            if location.suffix.isEmpty {
                let repo = try await request(Repository.self, api([]))
                resolvedRef = repo.default_branch
                root = try await request(Tree.self, api(["git", "trees", repo.default_branch]))
            } else {
                // A branch can contain slashes; extend the ref until GitHub resolves it.
                for count in 1...location.suffix.count {
                    do {
                        root = try await request(Tree.self, api(["git", "trees", location.suffix.prefix(count).joined(separator: "/")]))
                        resolvedRef = location.suffix.prefix(count).joined(separator: "/")
                        path = Array(location.suffix.dropFirst(count))
                        break
                    } catch let error as HTTPFailure where error.status == 404 { continue }
                }
            }
            guard var tree = root else { throw NoteImportError.message("The GitHub branch or folder was not found. Use a public repository URL.") }
            let selectedName = location.isBlob ? path.dropLast().last ?? location.repository : path.last ?? location.repository
            var singleSkill: Entry?
            for (index, component) in path.enumerated() {
                guard let entry = tree.tree.first(where: { $0.path == component }) else { throw NoteImportError.message("The selected GitHub folder was not found.") }
                if location.isBlob && index == path.count - 1 && entry.type == "blob" {
                    singleSkill = entry
                } else {
                    guard entry.type == "tree" else { throw NoteImportError.message("Select a folder containing SKILL.md files.") }
                    tree = try await request(Tree.self, api(["git", "trees", entry.sha], recursive: index == path.count - 1))
                }
            }
            if path.isEmpty {
                tree = try await request(Tree.self, api(["git", "trees", resolvedRef], recursive: true))
            }
            guard tree.truncated != true else { throw NoteImportError.message("This GitHub tree is too large. Select a smaller skills folder.") }
            let entries = singleSkill.map { [$0] } ?? tree.tree.filter { $0.type == "blob" && ($0.path == "SKILL.md" || $0.path.hasSuffix("/SKILL.md")) && $0.mode != "120000" }.sorted { $0.path < $1.path }
            guard !entries.isEmpty else { throw NoteImportError.message("No SKILL.md files were found in this folder.") }
            guard entries.count <= 100 else { throw NoteImportError.message("Select a folder with 100 or fewer skills.") }
            var files: [NoteFile] = []
            for entry in entries {
                guard (entry.size ?? 0) <= 1_048_576 else { throw NoteImportError.message("A SKILL.md file exceeds the 1 MB import limit.") }
                let blob = try await request(Blob.self, api(["git", "blobs", entry.sha]))
                guard blob.encoding == "base64", let data = Data(base64Encoded: blob.content, options: .ignoreUnknownCharacters),
                      data.count <= 1_048_576, String(data: data, encoding: .utf8) != nil else {
                    throw NoteImportError.message("GitHub returned an invalid Markdown file.")
                }
                let name = entry.path.split(separator: "/").dropLast().last.map(String.init) ?? selectedName
                files.append(NoteFile(name: name + ".md", data: data))
            }
            return GitHubSkillGroup(name: selectedName, files: files)
        } catch let error as HTTPFailure {
            throw NoteImportError.message(error.status == 404 ? "The repository was not found. Use a public GitHub URL." : "GitHub returned an error (\(error.status)). Try again.")
        }
    }
}
