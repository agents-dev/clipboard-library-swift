import XCTest
@testable import ClipboardLibrary

final class GitHubSkillTests: XCTestCase {
    func testRejectsNonGitHubAndUnsupportedURLs() {
        for text in ["https://example.com/a/b", "file:///tmp/skills", "https://github.com/a", "https://github.com/a/b/issues/1"] {
            XCTAssertThrowsError(try GitHubSkillLocation(text))
        }
        XCTAssertNoThrow(try GitHubSkillLocation(" https://github.com/openai/plugins/tree/main/plugins/build-macos-apps/ "))
    }

    func testImportsOnlySkillFilesUnderSelectedFolder() async throws {
        let markdown = Data("---\nname: alpha\n---\n# Exact bytes\n".utf8)
        let importer = GitHubSkillImporter { request in
            let url = try XCTUnwrap(request.url)
            let json: String
            switch url.path {
            case "/repos/acme/plugins/git/trees/main":
                json = #"{"tree":[{"path":"plugins","type":"tree","sha":"plugins-sha"}]}"#
            case "/repos/acme/plugins/git/trees/plugins-sha":
                json = #"{"tree":[{"path":"example","type":"tree","sha":"example-sha"}]}"#
            case "/repos/acme/plugins/git/trees/example-sha":
                json = #"{"tree":[{"path":"skills/alpha/SKILL.md","type":"blob","sha":"alpha-sha"},{"path":"README.md","type":"blob","sha":"readme-sha"},{"path":"skills/alpha/references/help.md","type":"blob","sha":"help-sha"}]}"#
            case "/repos/acme/plugins/git/blobs/alpha-sha":
                json = "{\"encoding\":\"base64\",\"content\":\"\(markdown.base64EncodedString())\"}"
            default: XCTFail("Unexpected request: \(url)"); throw URLError(.badURL)
            }
            return (Data(json.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let group = try await importer.fetch("https://github.com/acme/plugins/tree/main/plugins/example")
        XCTAssertEqual(group.name, "example")
        XCTAssertEqual(group.files.map(\.name), ["alpha.md"])
        XCTAssertEqual(group.files.first?.data, markdown)
    }

    func testReportsGitHubRateLimit() async {
        let importer = GitHubSkillImporter { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: ["X-RateLimit-Remaining": "0"])!)
        }
        do {
            _ = try await importer.fetch("https://github.com/acme/plugins")
            XCTFail("Expected a rate limit error")
        } catch { XCTAssertTrue(error.localizedDescription.lowercased().contains("limit")) }
    }

    func testResolvesSlashBranchAndSingleSkillURL() async throws {
        let importer = GitHubSkillImporter { request in
            let url = request.url!
            let json: String
            switch url.path {
            case "/repos/acme/plugin/git/trees/feature":
                return (Data(), HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!)
            case "/repos/acme/plugin/git/trees/feature/new":
                json = #"{"tree":[{"path":"alpha","type":"tree","sha":"alpha-tree"}]}"#
            case "/repos/acme/plugin/git/trees/alpha-tree":
                json = #"{"tree":[{"path":"SKILL.md","type":"blob","sha":"skill-blob"}]}"#
            case "/repos/acme/plugin/git/blobs/skill-blob":
                json = #"{"encoding":"base64","content":"IyBUZXN0Cg=="}"#
            default: XCTFail("Unexpected request \(url)"); throw URLError(.badURL)
            }
            return (Data(json.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let group = try await importer.fetch("https://github.com/acme/plugin/blob/feature/new/alpha/SKILL.md")
        XCTAssertEqual(group.name, "alpha")
        XCTAssertEqual(group.files.map(\.name), ["alpha.md"])
        XCTAssertEqual(group.files.first?.data, Data("# Test\n".utf8))
    }

    func testRejectsEmptyAndTruncatedTrees() async {
        for json in [#"{"tree":[]}"#, #"{"tree":[],"truncated":true}"#] {
            let importer = GitHubSkillImporter { request in
                let url = request.url!
                return (Data(json.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            do {
                _ = try await importer.fetch("https://github.com/acme/plugin/tree/main")
                XCTFail("Expected import failure")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("No SKILL.md") || error.localizedDescription.contains("too large"))
            }
        }
    }

    func testLiveExample() async throws {
        guard ProcessInfo.processInfo.environment["VERIFY_GITHUB_IMPORT"] == "1" else { throw XCTSkip("Run explicitly to verify the public GitHub example") }
        let group = try await GitHubSkillImporter().fetch("https://github.com/openai/plugins/tree/main/plugins/build-macos-apps")
        XCTAssertEqual(group.name, "build-macos-apps")
        XCTAssertTrue(group.files.contains { $0.name == "build-run-debug.md" && !$0.data.isEmpty })
        XCTAssertTrue(group.files.contains { $0.name == "test-triage.md" })
        XCTAssertTrue(group.files.contains { $0.name == "signing-entitlements.md" })
        print("LIVE_GITHUB_SKILLS \(group.files.map(\.name).joined(separator: ", "))")
    }
}
