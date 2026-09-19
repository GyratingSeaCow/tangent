# Tap-to-download audio — implementation notes

Status: **service layer BUILT and green; UI not wired yet.**

Jeff's decision (2026-09-19): downloaded audio lands in its own dedicated
folder, `Tangent Synced Audio`, a sibling of `Tangent Notebooks` and
`Tangent Text Notes`.

## Built so far (all green: 1294 Dart tests, 99 Kotlin tests)

- `syncedAudioSubdirectoryName = 'Tangent Synced Audio'`
  (`storage_contract.dart`), mirrored in Kotlin.
- `StorageBackend.publishBinaryDocument(...)` — new port method. The existing
  `publishDocument` is TEXT-ONLY: Kotlin encodes its content as UTF-8 and
  verifies readback against those bytes, which corrupts audio. Implemented in
  both `FilesystemStorageBackend` and `SafStorageBackend`.
- Kotlin `DocumentPublication.publishBinary` + shared private `write(...)`, so
  the atomic temp -> verify -> park -> rename -> delete sequence cannot drift
  between the text and binary paths. Registered in the method allow-list, the
  arg schema, and the router gate test.
- `LocalDb.clearDownloadedAudio(id)` — reverts a failed download to
  remote-only.
- `SyncedAudioDownloader` (`lib/services/synced_audio_download.dart`) — the
  whole sequence, 7 tests.

## The ordering constraint that shapes it

`bindRecording` verifies the dump's `audio_path` ALREADY equals the
binding's locator (guard at `local_db.dart:951`, fault raised at `:970`)
and faults 'Original audio identity differs' otherwise. So the order is: publish -> attach -> bind. Binding
before attaching cannot work.

And the binding is mandatory: `resolveRecording` (`storage_catalog.dart:439`)
faults without one, so a download that only
writes the file produces a recording that looks available and refuses to
play. Sabotage confirmed this — skipping the bind fails the playability test.

## Why `reserveCapture` is NOT used

It mints a fresh id and rejects any id already in `dumps`
(`storage_catalog.dart:501`). A downloaded recording keeps the SERVER'S id,
which is already there. The `AudioImporter` template does not transfer: it
creates a NEW dump, the opposite of attaching audio to an existing synced row.

## Remaining

1. **UI.** Download affordance where `audioOnServer == true && remoteOnly ==
   true`. Own entry point (the per-row overflow menu in
   `dumps_list_screen.dart`) — never overload the row tap, which means
   "open". Disable with a stated reason rather than hiding when Wi-Fi-only
   blocks it.
2. **Wi-Fi-only gate.** `settings_store.dart` has `wifiOnlySync`. Metadata
   always syncs; only this audio fetch respects it.
3. **Provider wiring.** The service needs a provider reading the selected
   location and `TranscriptionClient.downloadAudio`.
4. **Device proof.** Download on the Fold, verify bytes match the server
   exactly, PLAY it, and confirm the file lands in `Tangent Synced Audio`.

## Non-negotiables carried from the skill

- Never write into the destination folder directly; go through the port.
- Keep temp names MIME-coherent or AOSP renames them (`.opus` declares
  `audio/ogg` — an Opus file is an Ogg container).
- Never delete the previous copy before the replacement is renamed into place.
- Metadata always syncs; Wi-Fi-only gates ONLY the audio fetch.
- A dump without local audio is a first-class state, not an error.

---

# Appendix — the original investigation

Kept because each finding below is read off the code with its file and line,
so the next session does not re-derive them. Its "what already works" list
predates the service layer above; trust the status table at the top of this
file, not this appendix, for what is built.

Jeff's decision (2026-09-19): downloaded audio lands in **its own dedicated
folder**, saved the same way `Tangent Notebooks/` and `Tangent Text Notes/`
are — a named child of the user-selected storage folder, NOT the root and NOT
an app-private cache.

## What already worked before this session's service layer

- `GET /v1/dumps/{id}/audio` — server route, verified 200 + exact byte match.
- `TranscriptionClient.downloadAudio(dumpId)` — `transcription_client.dart:466`,
  returns raw bytes, throws `ApiException` on 404 with code `empty_audio`.
- `LocalDb.attachDownloadedAudio(id, audioPath:, audioSizeBytes:)` —
  `local_db.dart:635`, sets the path/size and clears `remoteOnly`.
- `dumps.audio_on_server` — synced from the feed, already correct on device.

No button calls any of it.

## Three constraints that shape the implementation

### 1. Playback REQUIRES a binding row

`StorageCatalog.resolveRecording` (`storage_catalog.dart:439`) faults with
`ProblemCode.conflict` / 'Original audio identity differs' (local_db.dart:967) when
`recording_bindings` has no row for the dump. `dump_detail_screen.dart:136`
plays via `access.openPlayback(binding.key, raw)`.

So writing bytes to disk and setting `audioPath` is NOT enough — the row
would look downloaded and refuse to play. This is what "adopted, not merely
written" means here.

### 2. `reserveCapture` CANNOT be reused

`storage_catalog.dart:458` mints a fresh id and, at line 501, rejects any id
already present in `dumps`, `recording_bindings`, `local_deletion_tickets` or
`capture_reservations`. A downloaded recording must keep the SERVER'S dump id,
which is already in `dumps` — so the capture-reservation path refuses it by
construction. The `AudioImporter` template (`audio_import.dart`) therefore
does not transfer: it creates a NEW dump, which is the opposite of attaching
audio to an existing synced row.

### 3. `publishDocument` is TEXT-ONLY — this is the real work

`publishDocument(location, directoryName, name, content, publicationId)`
(`storage_contract.dart:450`) takes a `String`. Kotlin
`DocumentPublication.kt:89` does `content.toByteArray(Charsets.UTF_8)` and
`:101` verifies readback with `contentEquals` on those UTF-8 bytes.

Opus audio cannot travel through it. UTF-8 encoding would corrupt the bytes,
and the readback check would fail anyway. Base64 is not an option — the file
must be a playable `.opus` in the user's folder, not an encoded blob.

**A binary document publication path does not exist and has to be built.**

The good news: `directoryName` is a PARAMETER, not an allow-list —
`DocumentPublication.kt:75` reads it via `DocumentWire.literal(args[...])`
and `directoryFor(..., create: true)` creates it idempotently. So a NEW
directory needs no Kotlin allow-list edit; only the binary write does.

## Implementation order

1. **Constant.** Add the subdirectory name beside `textNoteSubdirectoryName`
   (`storage_contract.dart:100`) and `notebookSubdirectoryName` (`:105`),
   mirrored in Kotlin next to `DocumentWire.NOTEBOOK_DIRECTORY`
   (`DocumentPublication.kt:20`). Name is Jeff's call — see open question.
2. **Binary publish.** Add an optional `publishBinaryDocument(... List<int>
   bytes ...)` to `StorageBackend`, defaulting to `Unsupported` so every
   backend keeps compiling (the port's default-method rule: an
   `abstract interface class` default is NOT inherited through `implements`,
   so each backend and test double must declare it). Mirror in
   `AndroidDocumentsPort`/`DocumentPublication` using the SAME temp →
   verify → park → rename → delete sequence, with an audio MIME so the temp
   extension stays MIME-coherent (SAF renames a mismatched temp — see the
   `.wav.oga` incident). Filesystem backend gets the plain-file version.
3. **Binding.** After publishing, write the `recording_bindings` row so
   `resolveRecording` succeeds, then `attachDownloadedAudio`. Both in one
   transaction — a published file with no binding is an orphan that import
   resurrects.
4. **Service.** `SyncedAudioDownloader`: check Wi-Fi-only FIRST (metadata
   always syncs; only audio fetch respects it), download, publish, bind,
   attach. On any failure delete the published file and leave `remoteOnly`
   true so the button stays available.
5. **UI.** Download affordance on rows where `audioOnServer == true &&
   remoteOnly == true`. Per the skill's contract rule: give it its OWN entry
   point (the existing per-row overflow menu at `dumps_list_screen.dart`),
   never overload the row tap, which already means "open". Disable with a
   stated reason rather than hiding when Wi-Fi-only blocks it.
6. **Device proof.** Download on the Fold, verify bytes match the server
   exactly, PLAY it, and confirm the file appears in the new folder.

## Open question for Jeff

The folder name. `Tangent Synced Audio` is the literal sibling of the
existing two, but the name is user-visible and permanent — renaming it later
strands every file already published under the old name.

## Non-negotiables carried from the skill

- Never write into the destination folder directly; go through the port so
  ownership checks and atomic publish apply.
- Keep temp names MIME-coherent or AOSP renames them.
- Never delete the previous copy before the replacement is renamed into place.
- Metadata always syncs; Wi-Fi-only gates ONLY the audio fetch.
- A dump without local audio is a first-class state, not an error.
