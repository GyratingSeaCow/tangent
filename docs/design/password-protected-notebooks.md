# Password-protected notebooks

Notebook password protection is an access-control guard for Tangent surfaces. It is not at-rest encryption of the notebook document.

## Verifier and sync contract

- A protected notebook stores `password_hash`, `password_salt`, and `password_iterations`.
- `password_hash` is a 32-byte PBKDF2-HMAC-SHA256 derived key encoded as Base64. New passwords use a random 16-byte salt and 210,000 iterations.
- Plaintext passwords are never persisted, logged, placed in durable notebook files, or sent in sync payloads.
- `password_hash == null` means protection is off. A non-null hash requires a non-empty salt and 100,000–1,000,000 iterations.
- `password_hash_prev` is a verifier hash, never plaintext. It is a compare-and-swap predecessor for a verifier transition and, after removal, the durable cleared-generation tombstone.
- `password_hash_prev` is stale-replay protection, not authentication: every paired peer receives the current verifier, so any paired device can submit the matching predecessor to clear or rotate protection. Sync treats omitted verifier fields as “older peer; preserve existing metadata.” For a complete, well-typed tuple whose predecessor does not match the server generation, the server preserves its canonical verifier tuple but still applies and republishes the notebook title, document, and ink. Only malformed verifier types, incomplete tuples, or iteration bounds reject the push.
- **Turn Off Password Protection** writes and pushes `password_hash: null`, null salt/iterations, and `password_hash_prev: H`, where `H` is the verifier that the entered password just proved locally. Peers apply the null only when that predecessor matches their current local hash.
- Initial enable uses no predecessor. Re-pushing the current verifier is idempotent. Rotation requires the current verifier as predecessor. After a clear, a fresh enable must name the tombstone as predecessor and must not reinstall the tombstoned hash.
- The server and durable notebook file retain the latest predecessor/tombstone. This one-generation causal marker distinguishes a stale device replaying the cleared tuple from a genuine enable made after observing the clear; the stale verifier transition is ignored rather than re-protecting peers, while any accompanying notebook edit still lands.
- Current durable files always carry all four verifier fields. A post-Turn-Off file therefore carries the predecessor needed to apply the clear when adopted by another folder-sharing device; legacy files with no verifier keys preserve local metadata.
- Malformed or causally invalid verifier metadata in a client pull is skipped while the notebook body and pull checkpoint continue, preventing a bad payload from wedging sync. A fresh local/server row has no generation to defend, so a complete valid incoming tuple is accepted verbatim even when it carries a predecessor.
- A rejected dirty notebook response includes the canonical server verifier tuple. The client rebases only those verifier fields, keeps the local body dirty, surfaces the rejection as a sync error, and retries the body with the current generation on the next sync instead of silently retrying a malformed tuple forever.
- Unlock state is in-memory, process-local, and bound to the current hash. Successfully enabling protection keeps that notebook unlocked because the user just entered the password twice. Process exit or a password change received through sync invalidates the unlock automatically.

## User-visible behavior

- The row and cover `⋮` menu says **Turn On Password Protection** or **Turn Off Password Protection**.
- Enabling requires the same non-empty password twice. Disabling requires the current password.
- Opening from any route is guarded by the editor itself. A wrong password leaves the notebook closed.
- Rename, pin/unpin, PDF export, Markdown/Obsidian export, and “Send to notebook” require an unlock.
- Move and delete, including bulk move/delete, remain permitted while locked. These operations do not reveal notebook content and provide recovery/organization paths when a password is forgotten.
- Protected notebooks remain named in library and picker metadata, with a lock icon. Their document text and recognized ink are excluded from library search, Ask/MCP retrieval, server OCR indexing, and other content previews.
- Bulk Obsidian export does not prompt repeatedly. It reports each locked notebook as failed with “Unlock this notebook before exporting it”; already-unlocked protected notebooks export normally.

## Migration

Client schema v31 and the server's idempotent startup migration add the three nullable verifier columns. Client schema v32 and the same server migration add nullable `password_hash_prev`. Existing rows receive nulls and remain unprotected; legacy protected rows continue to accept idempotent re-pushes of their current tuple.

## Deferred follow-ups

- **M6:** `/v1/ocr/status` backlog counts still include protected notebooks.
- **M7:** Ask history can retain snippets created before a notebook became protected.
- **M8:** Server `ink_index` purge is asynchronous, so pull can briefly serve old words until the worker runs; current readers remain guarded.
- The protected-notebook filter in OCR `backfill_scan` remains untested.
- A user-facing **Lock** action remains deferred. An unlocked notebook stays unlocked until process exit or its verifier changes.
