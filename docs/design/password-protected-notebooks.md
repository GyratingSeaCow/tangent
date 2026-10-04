# Password-protected notebooks

Notebook password protection is an access-control guard for Tangent surfaces. It is not at-rest encryption of the notebook document.

## Verifier and sync contract

- A protected notebook stores `password_hash`, `password_salt`, and `password_iterations`.
- `password_hash` is a 32-byte PBKDF2-HMAC-SHA256 derived key encoded as Base64. New passwords use a random 16-byte salt and 210,000 iterations.
- Plaintext passwords are never persisted, logged, placed in durable notebook files, or sent in sync payloads.
- `password_hash == null` means protection is off. A non-null hash requires a non-empty salt and 100,000–1,000,000 iterations.
- `password_hash_prev` is a verifier hash, never plaintext. It is the causal proof for a verifier transition and, after removal, the durable cleared-generation tombstone.
- Sync treats omitted verifier fields as “older peer; preserve existing metadata.” Explicit nulls are unauthenticated unless `password_hash_prev` exactly matches the currently stored `password_hash`; missing or wrong proof rejects the change and preserves protection.
- **Turn Off Password Protection** writes and pushes `password_hash: null`, null salt/iterations, and `password_hash_prev: H`, where `H` is the verifier that the entered password just proved. Peers apply the null only when that predecessor matches their current local hash.
- Initial enable uses no predecessor. Re-pushing the current verifier is idempotent. Rotation requires the current verifier as predecessor. After a clear, a fresh enable must name the tombstone as predecessor and must not reinstall the tombstoned hash.
- The server and durable notebook file retain the latest predecessor/tombstone. This one-generation causal marker distinguishes a stale device replaying the cleared tuple from a genuine enable made after observing the clear; the stale replay is rejected rather than re-protecting peers.
- Current durable files always carry all four verifier fields. A post-Turn-Off file therefore authenticates the clear when adopted by another folder-sharing device; legacy files with no verifier keys preserve local metadata.
- Malformed or causally invalid verifier metadata in a client pull is skipped while the notebook body and pull checkpoint continue, preventing a bad payload from wedging sync.
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

Client schema v31 and the server's idempotent startup migration add the three nullable verifier columns. Client schema v32 and the same server migration add nullable `password_hash_prev`. Existing rows receive nulls and remain unprotected; legacy protected rows continue to accept idempotent re-pushes of their current tuple.
