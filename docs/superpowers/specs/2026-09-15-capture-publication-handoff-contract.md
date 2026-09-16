# Adopted capture publication handoff contract

## Controller phase-B activation

Phase A and T5-I2A-I1 correction are accepted at `7985b982984260e0235ba7fdfe5500b0d50417b7` following independent spec/quality PASS. Phase B (section 9) is now authorized. Final C1 omits the transitional one-shot method. Mechanical removal includes AndroidDocumentsPort `publishCaptureAt` dispatch and StorageChannel old method/key allowlist entries, preserving shared semantic metadata publication helpers. Caller inventory additionally includes the negative assertion in capture_publication_test.dart (retain/adapt that assertion, not remove coverage); no other new caller path was found. Remaining approved files are exactly section 9 PhaseB plus the enumerated compatibility paths. LocalDb public ABI/schema/CAS remain unchanged unless a concrete missing behavior receives a further controller decision. PhaseB must satisfy the real receipt-checkpoint SQL trigger and true process-exit/cold-owner regressions, not merely same-process replay.


Status: ADOPTED by controller for T5-I2. This is an engineering correction to approved owned-capture recovery, not implementation or acceptance evidence. Sections 1–10 below are binding; recommendation/adoption wording retained in the source report is superseded by this declaration. SQLite remains the only durable authority. No phone or live-data action is authorized.

## Controller adoption and compilation boundary

- Adopt the exact prepare-before-content protocol, strict journal/wire schema, creation-receipt identity proof, fail-closed unknown/partial outcomes, platform identity ports and required evidence matrix below.
- Phase A is a backend prerequisite: synchronized C1 temporarily includes the unchanged legacy publishCapture method PLUS all new methods/types. No persistence integration or acceptance of T5-I2 is implied. Phase B removes that legacy method, every override and caller atomically; no runtime fallback is allowed.
- The single direct runtime dependency crypto: 3.0.6 is authorized. This supersedes the earlier plan estimate that no new runtime package was required. Its upstream published SDK constraint ^3.4.0 was independently checked against the package API; all other dependency restrictions remain. Do not force-add ignored lock files.
- Ted remains the only production writer. Finish the T5-I1 slice before Phase A. Preserve its guarded settled-failure transition and all earlier approved invariants. Each prerequisite phase requires independent review; combined T5 corrections require scoped re-review before Task6.
- Controller re-enumerated publishCapture callers: the listed Dart/native paths in section 9 are complete at the current source. Native legacy method names are included in removal inventory. No broader client/** permission.
- Real Windows and Linux filesystem identity tests are mandatory for claimed cross-platform support. Host has WSL Ubuntu and a responding linux/amd64 Docker engine; this is availability discovery, not evidence of a passing Linux port. Use isolated disposable test environments only; no server/container/gateway lifecycle changes or global installation. If platform execution cannot be established, report the precise blocker rather than waiving it.
- Historical task reviews remain evidence for their exact commits only. New protocol schema version does not change sidecar schema, Drift schema, old timestamps, serializer or CAS behavior. Ambiguous empty CREATE/partial artifacts remain retained; successful complete content must be recoverable from prior durable claims.

## Controller amendment — JVM JSON test runtime

Authorize `client/android/app/build.gradle` solely to add `testImplementation "org.json:json:20240303"` beside JUnit. This is a test-only harness prerequisite, not an Android runtime dependency, protocol change or unrelated upgrade. It supplements section 9 allowed files and the earlier JUnit-only test-dependency wording. Maven Central artifact identity/license/test-dependency metadata was independently retrieved by controller; real Gradle resolution/execution remains an implementation gate. Do not enable returnDefaultValues or replace production parsing with canned mock success. JSON-java JVM results are not evidence of identical Android parser behavior for every malformed input: retain strict production validation and explicitly label physical Android acceptance unperformed.

## Adopted source specification (verbatim sections)

## 1. Decision

Adopt **prepare empty, exclusively created target objects -> persist their exact creation receipts in SQLite -> initialize only those objects -> reconcile them read-only -> commit row/binding**.

The important inversion is that the exact final object identities become durable BEFORE either final object receives recording/metadata bytes. A successful write can then lose its response, the subsequent SQLite UPDATE, or the entire app process without losing the identity required to inspect the result. Keep reservation-owned staging until the existing atomic row/binding/committed transaction succeeds. Use the existing `capture_reservations.publication_json`; no database migration, backend durable cache, new default preference, metadata schema change, or content-addressed library is required.

This narrowly replaces the one-shot **initial capture publication** contract. It does not change existing post-commit `writeMetadata` publication, transcript serialization, timestamp acknowledgement or CAS. Initializing an object exclusively created and receipted by THIS capture is permitted; replacing, truncating, deleting or adopting any pre-existing/foreign target is not. Nonempty partial targets are retained, not overwritten. This distinction must appear in the adopted C1 supplement rather than be left to the implementer.

### Problem / three options / one pick

1. Retain the current returned result longer or delay native acknowledgement. Small change, useful for channel replacement, but process-local retention disappears on process death. It cannot solve the cold-process case alone. Reject as the complete fix.
2. Add a durable backend receipt log after rename/publication. Can recover many successes, but another gap exists between the effect and logging its identity; SAF rename may return a different document ID. A backend log also introduces another durable writer/cleanup protocol. Reject for this bounded correction.
3. Persist final-object claims before writing content, then perform exact read-only reconciliation. Removes the successful-content-to-identity gap without another durable authority. Select this option. It requires a narrow C1 extension and a filesystem object-identity/handle seam; those are explicit prerequisites, not hidden implementation choices.

No user-level product decision is needed. Controller approval is needed for the engineering supplement, changed C1 and allowed files. Automatic recovery of every ambiguous provider CREATE or every partial write is NOT promised; the exact fail-closed boundary is specified below. If automatic cleanup/repair of such uncertain artifacts is later desired, that is separate scope.

## 2. Source-backed reason the present contract is insufficient

All production references below are at the immutable commit, not Ted's evolving working tree.

- `client/lib/services/recording_persistence.dart:153–172` calls `publishCapture`, then persists `journal['published']`. Recovery at `:367–371` replays publication when that field is null. The exact confirmed counterexample and required trigger/reopen test are in `task-5-sol-review.md:53–72`.
- `client/lib/data/storage/filesystem_storage_backend.dart:277–341` rejects either existing final target, creates empty targets, then replaces them with temporary files. Keeping this one-shot API and merely retrying it preserves the conflict forever. Replacing those placeholders changes filesystem object identity, so a receipt for the placeholder cannot prove the renamed replacement.
- `client/android/app/src/main/kotlin/dev/tangent/tangent/storage/AndroidDocumentsPort.kt:125–141,173–184` publishes audio and metadata separately using temporary creation/write/readback/rename. It returns only the audio binding and total size, not a durable receipt for both final objects. A successful audio publication followed by metadata failure is already a possible partial boundary.
- `NativeIoSupervisor.kt:9–47` retains operations/results in process memory. `StorageChannel.kt:17–31` observes and acknowledges them. It is not a cross-process journal.
- `client/lib/data/storage/saf_storage_backend.dart:63–90` acknowledges a delivered result before the caller's SQLite handoff. `:153` also uses a settlement-only `_track<void>` observer. Neither receipt delivery nor restoration of worker fences is evidence that SQLite retained a publication result.
- `ProbeReceipts.kt:5–35` captures exact provider returns only inside an operation-local `ThreadLocal` ledger; `AndroidDocumentsPort.kt:154` activates it for candidate probes, not durable capture. It is useful precedent for mutation-before-observation receipt collection, not a durable capture authority.
- C1 currently exposes only `publishCapture(reservation, metadata) -> IoOperation<Outcome<PublishedCapture>>`; `PublishedCapture` contains a binding and size. It cannot represent preparation, partial exact claims, or read-only reconciliation of those claims. See `storage_contract.dart:277` and shared context C1.
- `storage_tables.dart:50–68` already provides the reservation identity/epoch/state and nullable JSON journal. A versioned JSON envelope fits without changing tables or Drift-generated code.

**Metadata identity alone is insufficient.** Equal dump ID, schemaVersion, mode, timestamps, size, name or even equal complete contents do not establish that an unrelated same-name object was created by this reservation. Recovery needs a previously frozen creation receipt identifying the actual object, plus validation of its contents. A hash of mutable metadata is not a substitute for provenance. A path alone is not persistent filesystem object identity.

## 3. Authority and invariant

SQLite remains the sole capture lifecycle/ownership authority. The trusted original audio is the regular, non-link, reservation-owned staging file finalized by the recorder. After its coherent stopped result is accepted, the application MUST NOT modify that staging file; only the existing committed-cleanup path may remove it. No temporary OS directory, backend map or native preference is durable authority.

Before any destination CREATE, freeze and read back a journal containing the original reservation identity, exact location/directory, mode, nonzero Unix-millisecond startedAt, stopped result, SHA-256 of the finalized staging bytes, initial semantic metadata and its exact UTF-8 serialization. Compute the audio digest once while accepting the known-stopped result, then compare later source reads to that frozen digest; source identity plus size alone cannot detect an in-place equal-length staging modification. Use the existing `dumpMetadata(staged)` values unchanged. The destination is still the reserved root, never a current default.

The invariant is:

> No bytes may be written to either final component until SQLite has durably stored valid creation receipts for BOTH final components and the retained source/root proofs. Any later recovery uses those exact receipts; absence of a receipt never authorizes adoption by filename.

Persisting a `preparing` intent permits one exclusive preparation attempt, not arbitrary retries. Persisting a valid complete `prepared` result permits initialization of those objects, not deletion/replacement of them. Persisting `published` is an observation checkpoint, not the first durable evidence of ownership.

SQLite transactions are short and contain no provider/file I/O. Each guarded write compares reservation ID, RecordingKey, location, staging path, mode, startedAt, current process epoch and the prior journal bytes/stage. On uncertain commit acknowledgement, reread the exact reservation before launching the next external operation. No successful in-memory write acknowledgement is assumed.

## 4. Exact C1 amendment

Keep existing `CaptureReservation`, `PublishedCapture`, `Outcome`, `IoOperation`, `UseLease`, component enum, row/binding commit and public coordinator/importer signatures. Replace the backend's one-shot `publishCapture` declaration with the declarations below. Every production override, fake and scripted backend must change in the same compilation boundary. Do not add an optional fallback which still executes the old unreceipted path.

```dart
// New C1 types; persisted encodings are specified in section 5.
typedef CaptureObjectIdentity = ({
  String kind,       // exactly windows-file, posix-file, or saf-document
  String scope,      // volume/device identity or literal provider authority
  String objectId,   // native file identity or literal opaque document ID
  String? generation // stable birth/generation evidence, when supplied
});
typedef CaptureComponentClaim = ({
  RecordingComponent component,
  String name,
  AudioLocator locator,
  CaptureObjectIdentity identity
});
typedef PreparedCapture = ({
  String publicationId,
  String reservationId,
  RecordingKey key,
  StorageLocation location,
  String stagingPath,
  CaptureObjectIdentity sourceIdentity,
  CaptureObjectIdentity rootIdentity,
  int audioSizeBytes,
  String audioSha256,
  String metadataJson,
  CaptureComponentClaim? audio,
  CaptureComponentClaim? metadata
});
enum CapturePreparationState { notStarted, uncertain, prepared }
typedef CapturePreparationResult = ({
  CapturePreparationState state,
  PreparedCapture? preparation,
  List<String> rawReturnedLocators,
  StorageProblem? problem
});
enum CaptureContentState { empty, complete, partial, absent, foreign, unknown }
typedef CaptureComponentInspection = ({
  CaptureContentState state,
  StorageProblem? problem
});
typedef CaptureInspection = ({
  CaptureComponentInspection audio,
  CaptureComponentInspection metadata
});

// Members of StorageBackend:
IoOperation<CapturePreparationResult> prepareCapture(
  CaptureReservation reservation,
  String metadataJson,
  String audioSha256,
  String operationId, {
  required bool observeOnly,
});
IoOperation<Outcome<CaptureInspection>> inspectPreparedCapture(
  CaptureReservation reservation,
  PreparedCapture preparation,
);
IoOperation<Outcome<PublishedCapture>> publishPreparedCapture(
  CaptureReservation reservation,
  PreparedCapture preparation,
);
Future<Outcome<void>> acknowledgeCapturePreparation(String operationId);
```

`publicationId` is exactly `reservation.id`; it is not regenerated on recovery. The prepare operation ID is exactly `capture-${reservation.id}-prepare`. It is persisted before dispatch and validated as a literal ID. Reservation IDs already meet the literal-ID contract. Worker payload identity excludes mutable phase/processEpoch; transmit the frozen reservation fields, exact metadataJson and operationId so channel replacement cannot change the operation fingerprint merely because recovery changed the current epoch. The Dart owner still guards its own epoch on every durable write.

Method semantics:

- `prepareCapture(... observeOnly:false)` performs read-only input/root checks, complete conflict enumeration and exclusive creation of two EMPTY final components, returning exact source/root/object evidence. It NEVER writes recording bytes, renames, replaces, or deletes a target, including on failure. Before each create, revalidate that the intended name is available. Both target names are exactly `${dumpId}.opus` and `${dumpId}.meta.json`.
- `notStarted` is allowed only when no CREATE was issued and there are no returned claims. Once any CREATE was dispatched, ambiguous failure is `uncertain`, even if no URI returned. `prepared` requires both distinct, valid, zero-length, owned regular components, exact expected names/root, source proof and no problem. A partial result retains each exact returned locator and any validated claim, with `uncertain` and a problem. Never return a generic failure which discards already-returned ownership evidence.
- `prepareCapture(... observeOnly:true)` observes only a retained operation with this exact ID/payload in the CURRENT native/FS process. It must never submit CREATE, even if the operation is unknown. Return `uncertain/unresolved` when its result is unavailable. This is a read-only receipt lookup, not another publication attempt. Cold recovery does not manufacture a retained receipt. This small observer mode can recover some pre-content handoff failures but is not the durability mechanism.
- `inspectPreparedCapture` is strictly read-only. It validates frozen reservation/preparation coherence, original root and source, the staging digest against frozen audioSha256, exact target object identities and regular-file status, then compares complete audio bytes to validated staging and metadata bytes to `utf8.encode(metadataJson)`. It does not rely on listing's size/mtime/metadata-map equality. Stream/chunk comparison is allowed. Use the vetted package:crypto SHA-256 implementation for the frozen source fingerprint (the narrowly proposed dependency amendment is listed in section 9); a digest is content evidence, never object ownership. Exact byte comparison plus frozen source digest is the normative content proof.
- `empty` means the same claimed regular object is positively readable and has zero bytes. `complete` means the same object has exactly the required bytes, including EOF/length. `partial` means the same object is nonempty but differs in any byte/length. `foreign` means identity/containment/name is wrong or ambiguous. `absent` requires successful complete observation, never permission/query failure. Otherwise `unknown` with the specific problem. Missing/changed/unreadable staging or root makes the whole inspection Fail, not complete.
- `publishPreparedCapture` accepts only a preparation loaded back from SQLite by the owner. It first validates/inspects the pair. Both must be `empty` or `complete`; check both before mutating either. It leaves complete components byte-for-byte untouched and initializes only its exact empty claimed components. It performs no CREATE, no rename, no unlink, no replacement and no truncation of a nonempty component. Write audio first, then metadata, retaining identity; flush/close and exact-readback each. A partial/foreign/absent/unknown component fails closed with staging and all target artifacts retained. A fresh inspection after both writes is required before success.
- Backend writers cannot independently authenticate that an arbitrary caller committed SQLite. That ordering is a service-layer C1 precondition enforced by the sole publication owner and tested at the production seam; the backend additionally enforces all structural/content/identity guards. Do not expose these methods as general UI mutation entry points.

No generic public deletion permission is conferred by these claims. An uncertain or partial preparation is not imported or cleaned automatically. `PublishedCapture` remains the normal binding/size result after both components prove complete.

## 5. Journal and wire schema

Use `publication_json.version = 2` for this protocol. This is NOT sidecar schemaVersion 2 or a database schema version change. Required exact top-level keys:

```text
version: 2
stopped: {path: string, durationSeconds: nonnegative integer,
          sizeBytes: positive integer}
metadata: the unchanged initial dumpMetadata map
handoff: {
  version: 1,
  publicationId: reservation_id,
  reservationId: reservation_id,
  key: C1 versioned RecordingKey,
  location: C1 versioned StorageLocation,
  stagingPath: exact stopped.path,
  mode: exact reservation mode,
  startedAtMs: exact capture_reservations.started_at,
  audioSha256: 64 lowercase hexadecimal characters,
  metadataJson: exact initial JSON string,
  prepareOperationId: "capture-<reservation_id>-prepare",
  stage: "intent" | "preparing" | "prepared" | "initializing" | "complete",
  preparation: null | versioned PreparedCapture object,
  prepareResult: null | versioned CapturePreparationResult object
}
published: null | {binding: existing StorageCodec-encoded binding string,
                   sizeBytes: positive integer}
```

Encoding rules:

- Every new structured wire object has integer `version:1`; fields use the exact names in section 4. Existing C1 nested objects use their existing versioned encoders. Enums encode exact names. `rawReturnedLocators` is an array of exact strings; it is diagnostic evidence, NOT validated authority.
- Identity `scope/objectId` strings are lossless native values, never JSON floating-point numbers. Windows uses volume serial plus native file ID; POSIX uses device identity plus inode; SAF uses literal authority plus document ID. `generation` is stable birth/generation evidence if available, never mutable ctime/mtime. If present it must compare equal; inability to establish a reliable identity is unsupported/unresolved, never a path-only fallback. Encodings and platform-supported limits must be independently tested.
- Fix the identity encoding rather than letting platforms choose: windows-file scope is the unsigned volume serial as lowercase zero-padded 16-digit hexadecimal; objectId is the native FILE_ID_128 byte array in returned byte order, lowercase 32-digit hexadecimal; generation is the stable creation FILETIME as unsigned decimal when available, otherwise null. posix-file scope is unsigned decimal device-major + `:` + device-minor, objectId is unsigned decimal inode, generation is birth seconds + `:` + zero-padded 9-digit birth nanoseconds when the returned stat mask proves availability, otherwise null. saf-document scope is the literal validated provider authority, objectId is the exact decoded opaque document ID, generation is null. Native URI strings remain separately preserved in locator.value. Test format boundaries and byte order independently; do not normalize received malformed tokens.
- For SAF, each claim's `locator.value` is the exact URI returned by CREATE, with its original spelling retained. It must decode to the same literal authority/document ID; a URI prefix or normalized string is not proof. No filename traversal validator is applied to opaque provider IDs. `rootIdentity` names the explicit effective directory, not an inferred parent or display label.
- Metadata JSON must parse to exactly the unchanged frozen semantic map, and its UTF-8 bytes are reused unchanged for initialization/reconciliation. No regeneration from a later clock, no added ownership fields in the sidecar, no stripping nullable manual-marker fields. Freeze once, reread the winner; do not reserialize on cold recovery.
- A complete preparation must match all handoff/reservation fields, positive source length and frozen audioSha256, two distinct component identities and the two exact expected names. Preparation verifies staging bytes against the supplied frozen digest before creating anything; initialization and recovery verify it again. Metadata cannot alias audio/source. An ambiguous/prepared-with-problem result cannot authorize writes.
- Reject unknown versions, unknown stages/enums, missing/extra keys in the new closed protocol objects, wrong types, fractional sizes, invalid URI envelopes and incoherent combinations before mutation. Do not apply a new closed-key rule to the existing semantic metadata map. Preserve raw stored bytes on invalid/unsupported decode, report a typed problem and retain the journal/staging.
- Record progress using exact prior-envelope CAS, not blind replacement of the whole reservation. Error handling never clears `preparation`, raw receipts, stopped result or published evidence. Source phase and process ownership checks survive uncertain DB acknowledgement.

Existing version-1 journals must not be silently upgraded into ownership proof. A committed v1 journal still takes the existing cleanup-only route. A noncommitted v1 journal with an existing valid positive receipt keeps the existing receipt validation route, without stronger guarantees being retroactively claimed. A v1 `published:null` row may already have executed the old unreceipted publisher; return unresolved and retain it. Do not infer ownership from matching files or pretend to repair historical live data. No live migration/repair is authorized in this task.

## 6. Ordered protocol and crash table

1. Accept the existing coherent stopped result and unchanged initial metadata. Persist journal v2 with `handoff.stage=intent`; reread its exact committed winner. Failure here starts no destination mutation.
2. Under the existing admitted capture use/per-key lane, CAS intent -> preparing, freeze the prepare operation ID, commit and reread. Then call prepare with observeOnly false. Await actual settlement, not only result delivery.
3. Persist the complete preparation or uncertain result under the same owner. Reread SQLite. Only a full validated `prepared` result may advance to stage prepared. If receipt persistence fails, do not write target contents; try only a guarded persistence/readback of the same retained result. Across replacement, observeOnly may retrieve it; across true process loss, an unknown result stays unresolved. Never repeat CREATE because a receipt is missing.
4. CAS prepared -> initializing and reread before content work. Call inspect/publishPrepared under the same admitted use. Complete components are never rewritten. If only an owned empty component remains, initialize it; if any component is nonempty partial or uncertain, stop without target mutation.
5. Both exact components complete -> persist stage complete plus the existing published binding/size checkpoint. If that UPDATE fails or the process dies first, SQLite still contains the full prepared identities from step 3. New owners reopen SQLite, load those claims, inspect the exact components and reconstruct the same PublishedCapture READ-ONLY. They do not call prepare or overwrite anything. This is the required T5-I2 recovery.
6. Use the existing atomic insert-if-unclaimed Dump + binding + committed reservation transaction. Recheck deletion/retired fences, epoch and late collision inside it. On uncertain acknowledgement, reread matching committed authority; no second INSERT/upsert or timestamp rewrite.
7. Committed recovery remains cleanup-only. Verify the committed row/binding and remove only the owned staging source, then journal after confirmed absence. Do not revalidate or rewrite initial sidecar bytes after commitment: later legitimate edits may already exist. New stronger source identity may be used to avoid deleting a substituted staging file, without changing semantic row data.

| Loss/failure boundary | Required durable interpretation and next action |
|---|---|
| Before preparing transaction | No destination mutation authorized. Retry the transaction. |
| Preparing persisted but CREATE invocation uncertain | No blind create replay. Observe retained operation only; otherwise unresolved, preserving staging. |
| CREATE took effect, process died before its receipt was frozen | Empty/unknown artifacts may remain. Never infer their identity from name, bytes or apparent absence. Retain unresolved. No successful content publication is possible yet by invariant. |
| First empty claim exists; second conflicts/fails | Retain first exact receipt if returned, every raw return and staging. Leave both owned/foreign objects untouched; no automatic cleanup or continuing creation. |
| Prepared transaction acknowledgement lost | Reread exact SQLite; if committed, use stored identities. Otherwise no content writes. |
| Process dies after prepared, before either write | Fresh owner validates the same objects. Positively empty owned claims can be initialized; no create is required. |
| Audio complete, metadata empty | Validate both exact identities and audio bytes; write only the receipted empty metadata object. Preserve audio bytes. |
| Either component has nonempty partial/different data | Retain unresolved/partial diagnostic and staging. Do not truncate, overwrite, delete, append blindly or adopt. |
| Both complete, result/receipt UPDATE lost | Read-only inspection against prepared claims reconstructs receipt; atomic commit can proceed. This includes cold-process loss, not merely channel replacement. |
| Provider lost access, returns loading/error cursor or ambiguous rows | Typed denied/unavailable/io/unknown; never absent or complete. Later access restoration permits the same read-only reconciliation. |
| Object replaced with foreign same-name object | Identity mismatch: fail conflict/invalid; unchanged contents do not authorize adoption. |
| DB row/binding already committed | Existing cleanup-only semantics; no publication or initial-metadata comparison. |

This is a safety-complete process-loss protocol, not an assertion of universal automatic liveness. The irreducible CREATE-return/receipt window moves to EMPTY object allocation, BEFORE content publication. Generic SAF has no transaction joining provider CREATE to app SQLite. Refusing to guess there is necessary, not waiving the complete-success handoff case. A future explicit cleanup/retry UX would need a separate contract and authorization.

## 7. Backend feasibility and real limits

### Filesystem

Do not implement this by storing path/size/mtime and then using `File.writeAsBytes`, nor by reusing the current temp-file rename over claimed targets. A replacement at the same path would pass weak checks, and rename would invalidate the receipt.

Add a narrowly scoped production filesystem capture port which creates with OS-exclusive semantics, returns a persistent object identity, opens without following links/reparse points, verifies identity on the OPEN HANDLE, initializes only a verified zero-length owned handle without truncation, flushes and compares through verified handles. Recheck directory containment/root identity and final path-to-object association. Do not perform a path-check followed by an unverified truncating open.

For Windows, use CREATE_NEW for claims, OPEN_EXISTING/nontruncating access for initialization, `GetFileInformationByHandleEx(FileIdInfo)` for volume/file identity, reparse checks, `FlushFileBuffers`, and handle-bound reads/writes. Preserve native drive and UNC semantics; do not use URI scheme guessing. For Linux, use root-relative exclusive open/no-follow, handle-bound stat identity, nontruncating writes/fsync and readback. `statx` can supply inode/device and optional stable birth evidence. Directory/open-handle validation must prevent following a replaced link. This port covers new capture only, not a wholesale rewrite of filesystem deletion or metadata updates.

Dart `FileStat` exposes type/size/mode/timestamps, not the persistent native object identifiers this protocol needs. A small `dart:ffi` implementation against platform libraries can supply the missing seam without a new runtime package; it must include real Windows/Linux object-identity and no-truncation tests. Unsupported filesystems/ABIs which cannot provide reliable identity must return unsupported, not degrade to path equality. This is an explicit prerequisite/compatibility limit; if preserving a particular filesystem requires another mechanism, return to the controller before widening scope.

Native object identifiers are not cryptographic provenance against a malicious filesystem or arbitrary ID reuse. Compare available stable generation/birth evidence and reject known replacement. The safety model is a conforming filesystem/provider plus application-owned immutable staging, not a hostile storage implementation. Do not claim protection against a third party writing concurrently through another handle; recheck before commit and surface detected changes. Platform tests must document unsupported identity semantics, including network filesystems, rather than silently asserting universal support.

### SAF

Use a separate initial-capture path, not the existing `publish(... replace=...)` helper. CREATE the final empty documents directly, capture EACH exact returned URI immediately before subsequent query/validation, and return even partially observed raw receipts. Only after Dart confirms the durable prepared transaction may native code open those exact documents for initial content writes. There is no rename and hence no rename-returned-ID handoff gap in this protocol. Keep the original helper unchanged for unrelated semantic metadata publication.

Before creating, require completed enumeration with no existing exact names; reject loading/error/null cursor, duplicates, directories and virtual documents. Validate CREATE returns against the prior complete child inventory: do not write to an already-existing returned document ID, auto-renamed target, alias of the other component/source, wrong authority/root, or unknown node. Reobserve exact child membership/name/ID and regular status before every write/readback. Preserve literal URI strings and opaque IDs. The accepted `ProviderQuerySnapshot` and `SafPolicy` decisions remain production-used, not reimplemented in weaker mocks.

For initialization, require readable/writable exact zero-length owned document, use the actual provider descriptor and verify complete bytes afterward. Existing `AndroidDocumentsPort.write` uses rwt; never call it for a nonempty or unreceipted target. Where descriptor semantics/identity cannot be verified sufficiently, fail unsupported/unknown before writing. A provider may supply pipes/cloud behavior, delayed durability, lost grants or stale observations; ContentResolver cannot make every provider transactional or guarantee power-loss/remote-service durability. Success requires completed observations and readback, not merely write/close returning. Process-death recovery can discover unavailable/missing content and retain a problem rather than fabricate completion.

The provider may finish an uncertain CREATE after the app worker dies. Therefore even a later empty enumeration is not sufficient to resubmit a preparing operation. The original reservation remains fenced from import/deletion; new unrelated captures may proceed only according to the existing settled-failure policy. No provider-side idempotency key is invented.

### Worker/channel lifetime

All preparation, inspection and initialization remain `IoOperation`s started INSIDE admitted `runIo`; protection lasts through actual local worker settlement. New native methods must be classified capture/recovery as appropriate and keyed by the same RecordingKey, not a synthetic catalog key. Reattached native inventory fences are restored before recovery/admission. An old observer timeout cannot authorize overlapping initialization.

Native retained results are a same-process optimization only. `observeOnly` MUST NOT dispatch an unknown operation. The observer needs positive current-process inventory/settlement classification and a finite typed unknown result; do not reuse the present endless unknown-operation polling loop for cold lookup. The lookup's settlement means that read-only lookup finished, not that a historical remote provider effect never happened.

A settlement-only inventory observer must not consume a preparation result before the durable owner records it. Add a non-consuming mode to `_track` for restored inventory and preparation observations; preserve the raw preparation result until the owner deliberately acknowledges it after SQLite stores the result. Adopt the exact public backend member already included in section 4:

```dart
Future<Outcome<void>> acknowledgeCapturePreparation(String operationId);
```

For a fixed executable C1, adopt this member on BOTH backends (filesystem releases its in-process retained result). The persistence owner invokes it only after re-reading durable prepareResult/preparation. Acknowledgement failure retains evidence and is not publication failure. It does not release unsettled I/O. No durable native log is introduced. Inspection/initialization results need no new durable acknowledgement scheme because prepared identities already support read-only cold reconciliation. Do not otherwise change NativeIoSupervisor's accepted key serialization/settlement behavior.
The filesystem preparation-result registry is process-owned, keyed by the frozen operation ID and exact payload, and survives replacement of a FilesystemStorageBackend instance; it is explicitly NOT used as cold-process authority. Retain failed/partial results too until their evidence is durably recorded. Add the existing descriptor's `method` string to native activeOperations inventory so restored observers can identify preparation receipts and leave them unconsumed without redesigning unrelated operation acknowledgements. This is a backward-compatible inventory field, not a C1 RestoredUse change.

## 8. Strict outcomes and preserved boundaries

- Invalid schema/identity combinations: invalid (unknown version: unsupported). Well-formed but insufficient old/ambiguous evidence: unresolved. Actual known foreign target: conflict. Native permission loss: denied. Loading/unobservable provider: unavailable/unknown. SQL failure: persistence. Missing claimed component: absent observation but overall capture remains unresolved, never recreate automatically.
- Native malformed responses must not escape as an unhandled Dart cast exception or silently become notStarted. Preserve raw already-returned receipt evidence where possible and report invalid/unknown with no subsequent mutation.
- No new Dump/binding is inserted until exact pair proof succeeds. Import remains fenced by the reservation. Delete remains blocked by its journal until committed cleanup completes. A foreign row, wrong incarnation, deletion ticket, process owner change or different frozen payload wins over a late callback.
- Keep normal failure/settlement integration compatible with the separately owned T5-I1 fix. Do not reimplement that fix here. No automatic retry loop, current-default lookup or storage redirection is added.
- Retain the original `dumpMetadata`/`importedDumpRow`, UTC initial values, millisecond startedAt decoding, CAS and nullable fields. There is no repair of the unrelated existing Dumps timestamp mismatch.

## 9. Implementation phase split and exact allowed inventory

Controller must first adopt this supplement and synchronize canonical C1, every repeated capsule, shared context and affected task briefs. That controller documentation work is NOT performed by this consultation. Use immutable bases for both phases; serialize the later persistence edit after Ted's T5-I1 correction. No worker edits shared files concurrently.

### Phase A — backend/receipt prerequisite, Ted; independent review before integration

Amend C1/types/codecs; implement the real filesystem identity/handle seam, native capture policy, partial-receipt wire/result transport, non-consuming observation/explicit acknowledgement, and all backend implementations/overrides. To keep this prerequisite separately compilable, Phase A temporarily ADDS the new methods alongside the unchanged known-defective one-shot method; controller must label that transitional capsule explicitly. Phase A is primitive acceptance, not T5-I2 acceptance. Phase B removes the old method and updates ALL callers/overrides atomically to the final C1 in section 4. No fallback from the new protocol to the old publisher is permitted, and no throwing placeholders may ship.

Allowed production files (paths relative to `client/`):

- Modify `lib/data/storage/storage_contract.dart`.
- Modify `lib/data/storage/storage_codec.dart` for the new strict codecs or delegate to the new codec file below.
- Create `lib/data/storage/capture_publication_codec.dart`.
- Modify `pubspec.yaml` to add the direct dependency `crypto: 3.0.6` for frozen staging SHA-256. Its published SDK constraint is ^3.4.0, compatible with this project's >=3.6.0. This explicitly supersedes the shared plan's no-new-runtime-package expectation for this utility only; do not write bespoke cryptography or import an undeclared transitive dependency. Dependency resolution/lock handling occurs in the implementation lane under repository policy, with no unrelated upgrades. The immutable Git lookup did not expose a tracked pubspec.lock entry, so do not assume a tracked lock file already exists or add an ignored file without controller approval.
- Modify `lib/data/storage/filesystem_storage_backend.dart`.
- Create `lib/data/storage/filesystem_capture_io.dart` (platform-independent capture port, native dispatch and byte/identity checks).
- Create `lib/data/storage/filesystem_capture_io_windows.dart` and `lib/data/storage/filesystem_capture_io_posix.dart` (OS handle primitives through dart:ffi; no new package/CMake/plugin registration required).
- Modify `lib/data/storage/saf_storage_backend.dart`.
- Modify `android/app/src/main/kotlin/dev/tangent/tangent/storage/AndroidDocumentsPort.kt` for production routing, raw-return capture and exact descriptor access; leave legacy/semantic write behavior unchanged.
- Keep `android/app/src/main/kotlin/dev/tangent/tangent/storage/DocumentsPort.kt` unchanged: declare the new capture-specific ABI in the new policy file below.
- Create `android/app/src/main/kotlin/dev/tangent/tangent/storage/CapturePublication.kt` containing the JVM-testable preparation/inspection/initialization policy and capture-port ABI used by the REAL Android adapter.
- Modify `android/app/src/main/kotlin/dev/tangent/tangent/storage/StorageChannel.kt` for exact method allowlist, stable payload key/kind and receipt observation/acknowledgement routing.
- `NativeIoSupervisor.kt` is NOT preauthorized for a durability redesign; existing result retention/acknowledge primitives suffice. If a precise production-seam limitation requires a small change, return an explicit bounded amendment before editing it. Likewise do not repurpose or weaken ProbeReceipts, ProviderQuerySnapshot or SafPolicy.

Fixed native method names: `prepareCaptureAt`, `inspectPreparedCaptureAt`, `publishPreparedCaptureAt`; observeOnly uses operationState lookup without dispatch. `acknowledgeCapturePreparation` uses existing acknowledgeOperation after a validated matching retained preparation. All new payloads carry frozen reservation plus versioned preparation where applicable; metadataJson is the exact frozen string, not a reencoded native JSONObject.

Allowed tests/support:

- Modify `test/support/scripted_storage_backend.dart`, `test/support/storage_fixture.dart` only for the new contract.
- Modify `test/unit/data/storage_backend_test.dart`, `test/unit/data/storage_codec_test.dart`, `test/unit/data/storage_lifetime_test.dart` and `test/unit/services/pinned_recording_test.dart` only for mechanical override compatibility until Phase B.
- Modify `test/widget/recording_controller_test.dart` for its direct production-publication call at immutable line 91; preserve the real controller/settlement assertion rather than replacing it with a canned success.
- Create `test/unit/data/capture_publication_test.dart` and `test/unit/data/filesystem_capture_io_test.dart`.
- Create `android/app/src/test/kotlin/dev/tangent/tangent/storage/CapturePublicationTest.kt`.
- Modify `android/app/src/test/kotlin/dev/tangent/tangent/storage/NativeIoSupervisorTest.kt` for production-channel capture handoff tests.
- Create `android/app/src/test/kotlin/dev/tangent/tangent/storage/CapturePublicationFixture.kt` as the shared adversarial port fixture; it must drive the production policy rather than duplicate it.

The immutable call-site enumeration found only the two backends, contract, persistence, scripted backend, storage_backend_test, pinned_recording_test and recording_controller_test. Before dispatch, controller repeats that enumeration at its chosen base and explicitly lists any new mechanical-only files. No blanket `client/**` authorization. Beyond the named crypto dependency, no package, generated DB, platform runner or schema edits are expected; newly discovered needs are blockers for bounded amendment, not implicit permission. Kotlin uses java.security.MessageDigest SHA-256 for the supplied source proof; identical digest vectors must cross the production Dart/native seam.

### Phase B — persistence/recovery integration, Ted; independent T5-I2 review

- Modify `client/lib/services/recording_persistence.dart` for the v2 handoff and exact checkpoint/reconciliation sequence.
- Remove the transitional one-shot declaration/implementations and migrate its enumerated tests/support callers using the Phase A file inventory in this same Phase B compilation boundary. This is mechanical completion of the adopted protocol, not an authorization to change unrelated backend behavior.
- Modify `client/test/unit/services/pinned_recording_test.dart` and `client/test/unit/services/recording_persistence_test.dart` for the decisive SQL trigger/cold reopen matrix.
- Modify `client/test/unit/data/storage_import_test.dart` only to prove retained reservations remain fenced and mechanical contract use remains coherent.
- Create `client/test/support/capture_handoff_process.dart` for disposable child-process interruption/reopen tests if needed. It must invoke production backend/persistence code, never synthesize a success response.
- No changes to semantic `recording_metadata.dart`, recorder configuration, UI, server, existing CAS SQL, generated `local_db.g.dart`, schema version or `storage_tables.dart`. Existing `commitOwnedCapture` and transactions are enough. If more public DB ABI is claimed necessary, supply the concrete missing behavior for controller review first.

T5-I1 integration is a prerequisite, not another correction delegated by this document. No independent source review of its evolving files occurred here.

## 10. Required evidence matrix for later execution (NOT RUN here)

1. **Exact confirmed defect RED:** real filesystem backend + file-backed SQLite; allow prepare/initialization, then a SQLite trigger rejects ONLY the transition from `published:null` to a nonnull published receipt. Assert both real final files contain the intended bytes, no Dump/binding committed, and SQLite still contains BOTH prepared identities. Remove trigger, fully close/reopen DB, create fresh catalog/mutation/backend/persistence owners and recover. Require exactly one row/binding in the original root, unchanged artifact bytes AND identities, no CREATE/rename/delete/nonempty-write on recovery, then staging/journal cleanup. Use synthetic IDs only. A trigger on Dumps INSERT is not this test.
2. **True lost-handoff process case:** child process runs production capture publication and exits after both final write/readbacks but before receipt checkpoint, without graceful cleanup/receipt transfer. Fresh process reopens the same fixture DB and artifacts; no Dart/native retained map is carried over. Require the same successful read-only reconciliation as case 1. Also test a lost method response separately. Restarting one object on the same open connection is insufficient.
3. **Earlier crash boundaries:** before prepare; preparing persisted before dispatch; after each CREATE but before receipt persistence; prepared committed; before audio write; after audio complete with metadata empty; nonempty partial audio/metadata; after both complete; after atomic row/binding commit before staging cleanup. Assert the exact success vs retained-unresolved distinctions in section 6, not blanket eventual success.
4. **Foreign controls:** pre-existing audio, metadata, both, and identical schema-2 fields in the reserved root; foreign objects with exact matching audio/metadata BYTES but no valid creation receipts; same names in another root; replacement of a claimed file/document with a new same-name object (also byte-identical). No adoption, overwrite, delete or row insert. Include links/reparse points, duplicate SAF names, directories, virtual nodes and returned-ID aliasing.
5. **Source proof:** missing/swapped/truncated staging; valid size but changed bytes; wrong source identity; wrong root, metadataJson, mode, key, incarnation, location or startedAtMs; zero audio. Fail closed, retain evidence. Test nonzero Unix-millisecond DB reopen without modifying old Dumps timestamp semantics.
6. **SQL ownership faults:** preparing/prepareResult/initializing/complete checkpoint failure separately; commit acknowledgement lost; competing epoch; late conflicting row/binding; deletion/retired ticket; concurrent two fresh recovery owners. At most one row/binding; no loss of claims and no late owner regression. Reuse existing atomic commit tests, do not weaken them.
7. **Filesystem production identity seam:** real temporary Windows and Linux files; exclusive create, true persistent object identity across close/reopen, identity changed by replacement, handle-bound zero-only initialization, unchanged complete bytes, root swap/link rejection and no truncation on mismatch. Include UNC/network limitations explicitly if no real target is available. Passing Windows tests alone does not establish Linux ABI correctness; report the remaining platform gate honestly.
8. **Native production-seam counterparts:** drive `CapturePublication` through actual `StorageChannel`/`NativeIoSupervisor`, with the Android adapter routing to that SAME policy. Fake only provider primitives: opaque CREATE-return IDs different from names; record returned URI BEFORE a failing query; complete/error/loading/blank-error snapshots; create auto-rename; changed/duplicate IDs; audio succeeds then metadata write fails; permission revoked; descriptor open/flush/readback errors. Assert no rename/delete for capture and no write before durable-preparation authorization. A fake dispatch which simply returns a prebuilt PublishedCapture is insufficient.
9. **Native cold reconstruction:** new supervisor and policy with only persisted prepared payload plus retained fixture document objects; no prior operation map. Both-complete reconcile returns the same binding without writes. Missing preparation never adopts same-name documents. Pair this with Dart real SQLite close/reopen and exact channel decoder tests; label this composition of production seams, not physical Kotlin-to-Dart/provider acceptance.
10. **Worker lifetime/receipt observation:** detach/replace channel during preparation and content write; result fails before worker settles; restored inventory does not acknowledge/discard the preparation; only SQLite-readback owner acknowledgement consumes it. No same-key initialization/deletion overlap. ObserveOnly unknown never dispatches CREATE and does not poll forever. Explicit acknowledgement failure retains evidence and does not undo completion.
11. **Strict wire regressions:** independent malformed/unknown-version/extra-key/fractional-number/escaped-URI fixtures, nullable partial claims, raw malformed return preserved only as diagnostics, mutable phase excluded from fingerprint. No TypeError leaks or fallback to a new operation/current root. Exact metadata UTF-8 preservation across language boundaries, including Unicode and null fields.
12. **Committed preservation:** later title/transcript/notes/manual-marker/sidecar changes survive committed cleanup-only recovery byte-for-byte; no new clock/serializer/CAS behavior. Retained unresolved journals still prevent importer/deletion bypass, while actual settled-failure admission follows the separately accepted T5-I1 contract.

Controller-owned gates after implementation: focused RED/GREEN, full relevant Flutter suite/analyzer, real JVM native tests and source-bound immutable review evidence for each phase. Repeat race shard after the final tree, not before its last edit. Synthetic/JVM evidence is not real Android provider or physical-device acceptance. No tests/builds/runtime probes were executed in this consultation.

## 11. Limitations, adoption checklist and sources

Adopt before implementation:

- The prepare-before-content invariant, three backend methods plus explicit preparation acknowledgement, strict v2 journal and native wire format.
- Direct initialization of exclusively owned empty targets (not rename-over-placeholder); no mutation of complete/nonempty partial/foreign artifacts.
- Fail-closed ambiguous CREATE and partial-write boundaries, and the lack of retroactive proof for old null-receipt v1 journals.
- The scoped Windows/Linux native identity seam and its platform gates. Existing `FileStat` cannot silently stand in for persistent identity.
- The single direct crypto dependency for a frozen source fingerprint, plus Kotlin's standard SHA-256 counterpart. Equal source identity/size is not sufficient to detect content mutation.
- Two implementation phases, synchronized C1 copies, exact mechanical caller inventory, and serialization with T5-I1.

No true user-level decision was found. Engineering limitations are explicit: generic provider CREATE is not atomic with SQLite; hostile/recycled identity or unobservable storage cannot be proven safe; arbitrary partial files are retained rather than repaired; storage hardware/remote provider durability cannot be guaranteed by a local receipt. If the controller instead requires automatic recovery of EVERY one of those cases, this contract is insufficient and a larger provider-specific/idempotent-storage product design is needed. That stronger requirement must not be silently claimed.

Guidance: plan/architecture guidance was loaded, and durable-async/Flutter guidance plus state-machine/storage-lifecycle references were read from their existing default-profile paths because the named skills were unavailable through this profile's skill_view. They were read-only. Production sources were retrieved with `git show` at the immutable commit. The exact finding/brief/shared context were read as requested. No evolving T5-I1 production source was used as baseline.

Verifiable sources:

- `06a2b558eff3cdaeadb069201533473205084c70:client/lib/services/recording_persistence.dart:91–174,214–254,260–452`.
- Same commit: `client/lib/data/storage/filesystem_storage_backend.dart:277–341`; `saf_storage_backend.dart:40–98,117–154,298–320`; `storage_contract.dart:277`; `storage_tables.dart:50–68`; `storage_providers.dart:17–20` (Android SAF, desktop filesystem).
- Same commit: `client/android/app/src/main/kotlin/dev/tangent/tangent/storage/AndroidDocumentsPort.kt:28–40,57–94,125–141,173–184`; `NativeIoSupervisor.kt:9–47`; `StorageChannel.kt:17–49`; `ProbeReceipts.kt:5–35`; `SafPolicy.kt:36–52`; existing `NativeIoSupervisorTest.kt` replacement/receipt tests.
- Same commit: `docs/superpowers/specs/2026-09-15-dumps-selection-save-folder-design.md`, sections 3–5 (pinned recovery, immutable ownership, staged retention, no current-default adoption, actual-I/O lifetime).
- `.superpowers/sdd/2026-09-15-dumps-selection-save-folder/task-5-sol-review.md:53–80`; `task-5-brief.md:200–212`; `shared-implementation-context.md:84–246,274–288`.
- https://api.dart.dev/dart-io/FileStat-class.html — exposed stat fields omit a persistent native file ID.
- https://learn.microsoft.com/en-us/windows/win32/api/winbase/ns-winbase-file_id_info — FILE_ID_INFO contains volume serial and file ID, returned by GetFileInformationByHandleEx.
- https://man7.org/linux/man-pages/man2/statx.2.html — handle/path-relative stat, device/inode, birth evidence and no-follow support. Platform feasibility, not evidence this application's helper exists or has passed.
- https://pub.dev/api/packages/crypto/versions/3.0.6 — exact published version, SHA implementation and SDK ^3.4.0 requirement; dependency compatibility was inspected, not installed or exercised.

Only this design report was authored. No production/plan/ledger edits, tests, builds, runtime probes, commits, messages, device/live-data/server/config/credential/gateway actions. HARD STOP BEFORE INSTALL and the unrelated timestamp pause remain unchanged.
