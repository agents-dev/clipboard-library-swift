# Maintain the architecture

- Store pasteboard item boundaries and all materialized UTI representations in AES-GCM payload files.
- Keep the payload key in Keychain.
- Treat SQLite metadata, previews, OCR text, and markup text as unencrypted local data.
- Use GRDB migrations to version storage.
- Use the statically linked sqlite-vec extension to query normalized 512-dimensional MobileCLIP vectors.
- Keep text and image vectors in separate tables.
- Bundle Apple MobileCLIP-S0 Core ML encoders and tokenizer resources.
- Run OCR and inference on the serial indexing queue.
- Preserve originals and store annotation documents as independent versions.
- Run as a regular Dock application and keep the menu-bar control available.
- Generate `Assets/AppIcon.icns` from the PNG master with `scripts/generate-icon.sh`.
- Use `scripts/fetch-models.sh` to reproduce model assets from the pinned upstream revision.
- Retain upstream license files with distributed assets.
