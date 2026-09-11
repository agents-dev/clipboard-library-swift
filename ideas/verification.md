# Complete release verification

- Verify global shortcuts and paste restoration with Accessibility enabled and disabled.
- Open Settings → Shortcut Mapper. Add, duplicate, edit, reorder, disable, and delete mappings. Restart and verify persistence.
- Record a trigger and action keys. Verify manual key and modifier controls. Verify Escape records as a key and recording does not open the picker.
- Map Command-1 to Control-Shift-M followed by 1. Release Command and verify both actions in the destination application.
- Verify Unicode text, explicit waits, the three-second test countdown, cancellation, and focus-loss cancellation.
- Verify global fallback and application-specific precedence. Verify duplicate scope and picker conflicts, failed registrations, and retry after releasing another application's shortcut.
- Verify sequences that output their own trigger or the picker shortcut without recursion. Verify physical modifiers do not leak into output.
- Verify application-only triggers reserve their chord globally while enabled; disable mappings to return that chord to other applications.
- Verify Quit from Settings, the menu-bar context menu, and Command-Q.
- Type rapidly in Notes with image history visible. Verify smooth input and retain the last edit after quitting and reopening.
- Verify Spaces, full-screen windows, multiple displays, and focus restoration manually.
- Verify actual source applications for custom pasteboard representations and promised file data.
- Measure 100,000-entry database latency and resident memory before claiming performance acceptance.
- Add dedicated tests for every annotation tool and rendered pixel coordinates.
- Verify model retrieval quality with a labeled image collection.
- Treat polling as best-effort capture; do not claim to capture intermediate clipboard updates between polls.

- Double-click a note and verify full-text paste into the previous application and picker dismissal. Repeat during editing.
- Paste multiple lines into a note. Select another note and verify only the first line remains visible. Select the original note and verify all lines remain intact.
- Focus a different note without typing. Verify the blue dot moves immediately and the editor contains all lines. Repeat with keyboard focus.
