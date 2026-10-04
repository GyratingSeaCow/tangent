# Password-protected notebooks

Notebook password protection is an access-control guard for Tangent surfaces. It is not at-rest encryption of the notebook document.

## Verifier and sync contract

- A protected notebook stores `password_hash`, `password_salt`, and `password_iterations`.
- `password_hash` is a 32-byte PBKDF2-HMAC-SHA256 derived key encoded as Base64. New passwords use a random 16-byte salt and 210,000 iterations.
- Plaintext passwords are never persisted, logged, placed in durable notebook files, or sent in sync payloads.
- `password_hash == null` means protection is off. A non-null hash requires a non-empty salt and at least 100,000 iterations.
- Sync treats omitted verifier fields as “older peer; preserve existing metadata.” An explicitly null hash clears all three fields.
- Unlock state is in-memory, process-local, and bound to the current hash. A password change received through sync invalidates a prior unlock automatically.

## User-visible behavior

- The row and cover `⋮` menu says **Turn On Password Protection** or **Turn Off Password Protection**.
- Enabling requires the same non-empty password twice. Disabling requires the current password.
- Opening from any route is guarded by the editor itself. A wrong password leaves the notebook closed.
- Rename, pin/unpin, PDF export, Markdown/Obsidian export, and “Send to notebook” require an unlock.
- Move and delete, including bulk move/delete, remain permitted while locked. These operations do not reveal notebook content and provide recovery/organization paths when a password is forgotten.
- Protected notebooks remain named in library and picker metadata, with a lock icon. Their document text and recognized ink are excluded from library search, Ask/MCP retrieval, server OCR indexing, and other content previews.
- Bulk Obsidian export does not prompt repeatedly. It reports each locked notebook as failed with “Unlock this notebook before exporting it”; already-unlocked protected notebooks export normally.

## Migration

Client schema v31 and the server's idempotent startup migration add the three nullable columns. Existing rows receive nulls and remain unprotected.
