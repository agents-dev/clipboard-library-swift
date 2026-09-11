# App Outline

## Define the product

Build Clipboard Library as a private macOS clipboard history application.

- Capture clipboard items in the background.
- Preserve all available pasteboard representations.
- Search copied text, image text, tags, source applications, and meaning.
- Restore the original item and paste it into the previous application.
- Keep capture, storage, OCR, and semantic inference on the Mac.

## Support the primary user flow

1. Copy text, rich content, an image, a file URL, or another pasteboard item.
2. Detect the changed pasteboard and create a history item.
3. Encrypt the original payload and create a preview.
4. Index text immediately. Queue OCR and semantic indexing when required.
5. Open the picker with the global shortcut.
6. Type a query or move through results with the keyboard.
7. Select an item and press Return.
8. Restore its original representations, copy them to the pasteboard, and paste when Accessibility access permits it.

## Provide these screens

### Clipboard picker

- Show a compact, floating search field and result list.
- Show a preview, source application, content type, capture time, tags, and indexing state for each result.
- Accept exact and semantic search in one query field.
- Let users move with Up and Down, select with Return, and close with Escape.
- Keep the picker focused on search when it opens.
- Hide the picker when it loses application focus.

### Item detail

- Show the best preview for the selected item.
- Show preserved content types and searchable metadata.
- Let users pin, tag, delete, copy, or paste the item.
- Open image items in the non-destructive markup editor.
- Show indexing progress or errors without blocking access to the item.

### Image markup

- Keep the captured source image unchanged.
- Add independent markup versions.
- Support drawing, highlighting, shapes, text, crop, blur, and redaction.
- Support undo, redo, copy, and PNG export.

### Notes panel

- Show a persistent, nested outline beside clipboard history.
- Let users add, edit, indent, outdent, reorder, collapse, expand, and delete notes.
- Attach imported files to notes.
- Keep notes available after clipboard items are deleted or re-indexed.

### Settings

- Configure the picker shortcut.
- Configure retention and excluded applications.
- Manage shortcut mappings and test them safely.
- Show Accessibility permission status.
- Rebuild search indexes when indexing data requires repair.

## Store data locally

- Save history metadata, previews, OCR text, tags, markup documents, and notes in SQLite.
- Encrypt raw clipboard payloads with AES-GCM.
- Keep the payload key in local application support storage.
- Store text search data in FTS5.
- Store normalized text and image embeddings in separate sqlite-vec tables.
- Store attachment bytes encrypted in SQLite. Export temporary unencrypted copies only when another application needs a file.

## Keep privacy guarantees

- Do not send clipboard data, OCR text, embeddings, notes, or markup to a network service.
- Skip content marked transient or concealed by its source application.
- Let users exclude applications by bundle identifier.
- Make deletion remove payloads and searchable metadata.

## Define the release scope

### Required for the first usable release

- Capture and preserve common text, rich-text, image, and file URL content.
- Search with FTS, OCR, and local semantic ranking.
- Open, select, restore, and paste an item from a global shortcut.
- Encrypt stored original payloads.
- Support pins, tags, exclusions, and deletion.
- Support the persistent outline notes panel.
- Provide a reproducible local build and automated tests.

### Extend after the first release

- Add richer preview types for uncommon pasteboard formats.
- Add configurable retention policies and storage reporting.
- Add import and export for clipboard history.
- Add more markup tools and export formats.
- Add optional sync only if it preserves the local-first privacy model.

## Measure success

- Open the picker and find a recent item in a few keystrokes.
- Restore rich clipboard formats without degrading the source data.
- Keep ordinary queries responsive on a large local history.
- Keep all normal capture and search operations offline.
- Make permission limits and indexing errors clear to the user.
