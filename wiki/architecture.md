# Maintain the architecture

- Store pasteboard item boundaries and all materialized UTI representations as AES-GCM blobs in SQLite.
- Keep the random payload key in an owner-readable local application-support file.
- Treat SQLite metadata, previews, OCR text, and markup text as unencrypted local data.
- Use GRDB migrations to version storage.
- Use the statically linked sqlite-vec extension to query normalized 512-dimensional MobileCLIP vectors.
- Keep text and image vectors in separate tables.
- Bundle Apple MobileCLIP-S0 Core ML encoders and tokenizer resources.
- Run OCR and inference on the serial indexing queue.
- Preserve originals and store annotation documents as independent versions.
- Store outline notes as ordered parent-child rows in SQLite.
- Delete a note and all descendants with one recursive SQLite query.
- Run as a regular Dock and menu-bar application and hide the picker when the application loses focus.
- Use accessory activation only for background screenshot launches.
- Generate `Assets/AppIcon.icns` from the PNG master with `scripts/generate-icon.sh`.
- Use `scripts/fetch-models.sh` to reproduce model assets from the pinned upstream revision.
- Retain upstream license files with distributed assets.
