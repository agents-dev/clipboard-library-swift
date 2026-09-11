# Maintain Clipboard Library

- Target macOS 15 and Apple Silicon.
- Run `swift test` after storage, search, or rendering changes.
- Run `bash scripts/build-app.sh` to create the internal application.
- Keep clipboard inference local.
- Preserve original payloads during indexing and markup.
- Commit every completed change before ending the turn.
- Do not leave project changes uncommitted.
- Write a clear, focused commit message for each change.
- Use subagents only for end-to-end testing or monitoring long-running commands. Do not use subagents for code review.
- Read [architecture](wiki/architecture.md) before changing service boundaries.
- Read [app outline](wiki/app-outline.md) before changing product scope or user flows.
- Read [local signing](wiki/local-signing.md) before changing build signing.
- Read [skill and file notes](wiki/note-files.md) before changing Notes import or file paste.
- Read [follow-up checks](ideas/verification.md) before release.
