# Implement skill and file notes

- Replace Notes + with a GitHub URL sheet. Keep Add text note in the Notes menu.
- Parse public repository, tree, and SKILL.md URLs. Resolve the selected directory, find SKILL.md files, and preserve their bytes.
- Import one parent named after the selected folder. Add one child per skill and name its attachment after the skill directory with a .md extension.
- Add a versioned notes attachment migration. Encrypt attachment bytes with the existing local key. Save each import in one transaction.
- Accept Finder file URLs through Command-V in Notes and Paste files. Preserve normal text paste and limit file interception to Notes.
- Export a fresh file copy before double-click paste. Keep exported copies available for the destination application.
- Test URL validation, GitHub discovery and errors, attachment persistence and rollback, pasteboard file contents, and Notes paste routing.
- Run swift test, verify the example URL with a live import test, and run bash scripts/build-app.sh. Commit and push the completed feature.
