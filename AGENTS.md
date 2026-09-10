# Maintain Clipboard Library

- Target macOS 15 and Apple Silicon.
- Run `swift test` after storage, search, or rendering changes.
- Run `bash scripts/build-app.sh` to create the internal application.
- Keep clipboard inference local.
- Preserve original payloads during indexing and markup.
- Commit every completed change before ending the turn.
- Do not leave project changes uncommitted.
- Write a clear, focused commit message for each change.
- Read [architecture](wiki/architecture.md) before changing service boundaries.
- Read [follow-up checks](ideas/verification.md) before release.
