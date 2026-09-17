# Adopted controller clarification — frozen legacy inspection

Status: ADOPTED for Task 4. This is the authoritative engineering clarification of the approved immutable legacy-source requirement, not a new product feature. Controller adopts Sol's exact sections below, including two-pass capture → SQLite freeze → resolve, optional frozenAnchorJson input, exact envelope schemas, errors and regression matrix. The original Task 4 scope is extended only by the bounded prerequisite file inventory below. No schema migration, backend authority/cache, preference write, install, live-data repair or timestamp fix is authorized.

Sections phrased as recommendations or controller/Ted actions below are now adopted requirements, not open design choices. Implementation remains Ted-owned and must pass independent review. Historical review packages remain immutable evidence of earlier interfaces.

## 1. Exact public API and channel change

Replace only the existing backend method declaration, everywhere its binding contract is copied:

```dart
Future<Outcome<LegacyStorage?>> inspectLegacyStorage({
  required String filesystemLegacyDirectory,
  String? frozenAnchorJson,
});
```

Keep unchanged:

```dart
typedef LegacyStorage = ({StorageLocation? location, String anchorJson});
```

- `frozenAnchorJson == null`: **capture-only**. Read the original source once and return its envelope without provider/root-access resolution. Native SAF reads only `tangent_storage.recordings_tree_uri`; filesystem captures only the explicit required path. A backend instance stores no snapshot authority.
- Non-null `frozenAnchorJson`: **resolve-only**. Validate and resolve precisely that snapshot. Never read native preferences, current default, or the required filesystem argument as fallback. Return the supplied `anchorJson` string unchanged, including JSON whitespace/key order and URI escape spelling, on both resolved and anchor-only results.
- SAF forwards a non-null string under the exact channel argument `frozenAnchorJson` on the existing `inspectLegacyStorage` operation. In capture mode omit the key. Native absence or explicit channel null means capture; other non-string argument types are `invalid`. Empty string is a supplied malformed anchor, not capture.
- Filesystem handles the optional parameter locally; it does not call the native channel or place JSON into `filesystemLegacyDirectory`.
- Preserve `_start`/operationId, retained result, `operationState`, acknowledgement, `_pending`/drain, supervisor and actual-settlement behavior. The added argument requires no new native method or synchronous bypass. `StorageChannel.kt:32–49` already forwards its argument map to the worker.

Existing call sites compile when omitting an optional parameter, but **overrides/implementations must also accept it**. An overriding method without the new named parameter is not source-compatible with the widened interface. Inherited filesystem implementations need no override. Explicit scripted/mock overrides must preserve both modes and use/forward the frozen argument rather than consulting their mutable selection field during recovery.

## 2. Exact anchor schema v1

An anchor is an opaque source snapshot, **not a `DirectoryRef`**, usable location, grant claim or availability record. Its schema version is independent of the existing version-1 directory/audio codecs.

SAF, exactly these fields:

```json
{"version":1,"kind":"legacy-saf-selection","policy":"tree-root-documents-or-tangent-v1","selectedTreeUri":"content://Fixture.Provider/tree/opaque%2Froot"}
```

Confirmed unconfigured SAF snapshot, for catalog persistence:

```json
{"version":1,"kind":"legacy-saf-selection","policy":"tree-root-documents-or-tangent-v1","selectedTreeUri":null}
```

Filesystem, exactly these fields:

```json
{"version":1,"kind":"legacy-file-root","policy":"direct-root-v1","path":"C:\\Recordings\\Tangent"}
```

Rules:

1. `version` is integer `1`; `kind` and `policy` must be exactly the paired constants above. Require an object and all declared fields; reject foreign/mixed fields, missing fields, wrong types and unknown version/kind/policy. Cross-backend anchors fail `invalid`, never trigger platform fallback.
2. `selectedTreeUri` is String or explicit null. The `path` field is String, never null. URI/path strings are captured literally: no trim, normalization, URI rebuilding, case folding, derived parent, display-name substitution or canonical-path rewrite.
3. Envelope validation and source usability are different checks. An empty/malformed URI String or invalid path String is still a representable historical snapshot. Capture it; resolution yields `location:null` without substituting another source. A malformed **envelope** is instead `Fail(invalid)` and is never recaptured from preferences.
4. Do not embed a transient error, availability flag, effective directory, label, timestamp, default revision or account/credential data in the anchor. Those values would either change immutable bytes or imply authority the snapshot does not have.
5. Add narrowly scoped shared Dart helpers in `storage_codec.dart`: `encodeLegacySafAnchor(String? selectedTreeUri)`, `encodeLegacyFileAnchor(String path)`, and `decodeLegacyAnchor(String json, {required String expectedKind})` returning a validated `Map<String,dynamic>`. The decoder validates representation, not provider access. Preserve the original string separately; decoding never grants permission to reserialize/replace a persisted anchor. Keep all existing directory/audio/key validation semantics unchanged.
6. Native emits the same schema in capture mode and validates it in resolve mode. A stateless native helper may separate envelope/selection/policy decisions from Android calls for production-used JVM tests. Kotlin tests must not silently substitute a different test-only authority path.

### Nulls, absence and preference errors

- A successfully read absent preference (or native null String value) in capture mode returns **`Ok(null)`**. It means genuinely unconfigured, not inaccessible. The catalog persists the explicit-null SAF envelope above before marking any legacy snapshot frozen or advancing bootstrap. This records known absence distinctly from SQL NULL, which means no snapshot has been frozen yet.
- A supplied explicit-null SAF envelope returns **`Ok((location:null, anchorJson:theExactInput))`**. It never rereads a subsequently configured preference and never resolves against a new default. Old rows anchored to known absence stay unresolved until a separately authorized source-repair mechanism exists; new folder selection is not such a mechanism.
- An empty stored String is not absent: capture it as a String envelope and leave it unresolved. Wrong preference type, failure to read preferences, or unavailable native channel is **not `Ok(null)`**. Return typed `Fail(invalid)` for nonrepresentable/wrong-typed preference data, or `Fail(denied/unavailable/io)` as actually established; do not fabricate or persist an unknown-as-absent sentinel. Bootstrap remains incomplete and unbound legacy rows remain non-destructively unavailable. Settings need not disappear, but no new default may be used as their missing historical anchor.
- A valid supplied anchor receiving a native null result, missing/wrong-typed `anchorJson`, mismatched returned anchor bytes, malformed non-null location or wrong backend kind is an invalid protocol result, not a reason to recapture. Validate these cases explicitly in the Dart adapter and return typed failure rather than silently converting them to absence.
- Existing SQL NULL anchor with bootstrap not begun permits capture. Existing SQL NULL with a claimed completed bootstrap, or an unexpected historical bare DirectoryRef anchor, is inconsistent state: fail closed and surface a diagnostic. Do not guess the lost selected preference or silently rewrite old persisted anchors. No shipped Task 4 bootstrap at this baseline is established, so no automatic legacy-envelope migration is justified.

## 3. Capture, persistence and resolution ordering

The catalog owns the only durable snapshot authority, in the existing SQLite columns (`shared-implementation-context.md:233–240`). Use this exact ordering:

1. Restore native inventory/use fences before mutation/bootstrap admission as already required. Do not turn inventory failure into an empty set.
2. Under the catalog admission lane, read `storage_catalog_state.legacy_anchor_json`. If already non-null, use it; do not call capture mode. If absent and bootstrap has not started, call capture mode outside any SQLite transaction. For SAF `Ok(null)`, produce the explicit-null envelope above. For configured/file capture, require `location:null` and a valid backend-matching envelope.
3. In a short DB transaction, install that exact envelope only if the singleton anchor is still null and the bootstrap state still permits first capture. On a concurrent winner, discard the local candidate and reread the stored winner. On persistence/acknowledgement uncertainty, reread SQLite; do not proceed from an unconfirmed in-memory candidate. No provider query occurs in this transaction.
4. Only after durable freeze, call resolve mode with the **stored string**. This closes the initial inaccessible/hanging-provider gap: the snapshot is already durable before provider access starts. A crash before the freeze transaction committed has not frozen authority; do not claim otherwise.
5. Bootstrap rows in resumable chunks with their original audio locator, stable incarnation and exact frozen anchor. Copy the anchor to unresolved row bindings; never replace an existing per-row anchor with the singleton/current default. Resume incomplete row enumeration even if some rows remain unresolved; the bootstrap completion marker means initial rows were accounted for, not all storage became accessible.
6. A later recovery uses each unresolved row's own persisted anchor. Grouping equal anchors for one read-only inspection is acceptable, but no persistent/in-memory backend cache may supersede SQLite. Resolve outcomes may change; anchor bytes do not. A successful later resolution never rewrites the original anchor or original Dumps/audio fields.
7. Resolving old rows cannot reset a subsequently committed default pointer/revision. Initial legacy-default initialization, if appropriate under Task 4, remains conditional on the existing catalog transaction/state, not on every successful recovery. Candidate/default changes remain their existing separate state machine.

This is two invocations of the same operation, not an extra service or metadata store. Freeze-only capture also applies to the filesystem backend, so an unavailable root cannot withhold its explicit original path.

## 4. Native selection validation and effective-directory proof

The policy constant deliberately says **tree-root**. Preserve historical semantics instead of interpreting opaque document IDs as paths:

- Validate the literal content-URI envelope/structure before provider calls. Use the accepted codec rules as the cross-language fixture oracle: literal authority, no userinfo/port/query/fragment, strict escapes/UTF-8, no decoded NUL, split structural `/` separators before decoding individual opaque IDs (`storage_codec.dart:100–176`). Reject malformed shape; preserve arbitrary valid provider authorities and opaque IDs, including dot-valued IDs and encoded slash/colon/percent. Do not use the recording filename validator on provider document IDs.
- Accept `/tree/T` and the accepted tree-document form `/tree/T/document/D`, with nonempty opaque components. For this **legacy policy**, the selected root ID is T in both forms, matching historical `DocumentFile.fromTreeUri` and the accepted `getTreeDocumentId` implementation. D is not a filesystem parent/child instruction and must not silently become a different selected root. Preserve the entire original URI String as the grant capability. Direct `/document/D` without a tree is unresolved under this policy, not permission to infer a grant.
- Verify the provider's returned selected node is exactly the requested selected root ID, a directory, and nonvirtual. Similarly verify the resolved effective directory query returns its exact ID/type. The current generic `name` query checks cardinality/type but not ID (`AndroidDocumentsPort.kt:46–49`); add this identity assertion in the bounded legacy resolution path (or a narrowly shared checked-directory helper), rather than assuming any single returned directory is the requested one.
- Apply `SafPolicy.effectiveDirectory(..., true)` unchanged in meaning: selected Tangent name is direct (case-insensitive as today); selected Documents name requires exactly one nonvirtual directory child named literal `Tangent`; unknown selected names, missing/duplicate child or incomplete/error enumeration remain unresolved. Do not create that child, walk parents, enumerate alternative roots or retry using the current default. Keep `ProviderQuerySnapshot` loading/error classification and exact persisted-grant checks.
- Effective `DirectoryRef` is a separate result: original selected `treeUri`, literal authority, provider-proven effective `documentId`, empty filesystem path. Its ID/label are observation/location-registration data, not anchor fields. The catalog registers by the existing canonical directory tuple, without replacing a prior snapshot or treating a label as identity.
- Resolving the directory is **not proof for every old row**. Before binding a row, compare its original stored audio authority/document identity with the exact regular file returned from completed enumeration of that effective directory, matching the recording's owned filename and rejecting duplicates/virtuals/directories/foreign IDs. A read-only `listRecordingsAt` result and strict original audio decoding can supply this proof; do not use URI prefixes or assume the audio tree component identifies its effective parent. Preserve original `audio_json`/Dumps.audioPath even if the provider constructs an equivalent URI spelling. Per-file access/metadata problems remain per-row diagnostics, not permission to create/repair sidecars during bootstrap.

The historical picker explicitly stored the original selected URI because a child URI's tree component can still identify the parent (`MainActivity.kt:179–183`); `tangentDirectory` reopens the tree then applies the legacy child rule (`:209–216`). The new anchor must retain that distinction, not freeze only today's resolved child.

## 5. Filesystem and error/diagnostic semantics

- Capture the exact explicit `filesystemLegacyDirectory` into `legacy-file-root`, without filesystem access or creation. It is required and non-null at the API. Empty/relative/unusable strings remain representable but unresolved; never call `absolute()` against the current working directory to repair them.
- On supplied file-anchor resolution, ignore the newly passed path argument completely. Validate the frozen path using existing tagged absolute-path rules and existing `_root` link/ancestry/access checks. Perform a read-only completed root enumeration before advertising it as available. Return a file `StorageLocation` only when these checks succeed; original per-row basename/parent/type ownership still requires proof. Missing/denied/link roots yield anchor-only results and can later recover against that same path. Preserve drive/UNC strings; no cross-platform SAF fallback.
- For representable but unresolved selection/root, resolution returns **`Ok(LegacyStorage(location:null, anchorJson:unchanged))`**. Missing grant, missing/ambiguous legacy child, unavailable provider/root, loading/error cursor and unusable raw selection must not discard the anchor. Catch expected access/validation failures at this resolution boundary; do not blanket-catch programming defects or change other backend operations' error semantics.
- C1 currently has no `LegacyStorage.problem`. Do not stuff errors into the frozen envelope or add a second outcome/diagnostic authority. In resolution mode the catalog maps null location to an honest generic `ProblemCode.unresolved` in the existing `BootstrapResult.problems` and lists affected unresolved IDs. It must not claim a specific denied/missing diagnosis it did not receive. In capture mode null location is expected snapshot-only success, not a provider-error report.
- Envelope/protocol errors and failures before a source can be captured remain typed `Fail`. A read-only resolution transport/unexpected failure may also return `Fail`; the catalog already has the durable anchor and retains it. Unknown exceptions should retain debugging stack information without logging original URIs, paths or raw preference contents. Detailed per-provider failure transport would require a separately approved result-type extension; it is unnecessary for this correction.

## 6. Bounded change inventory for controller/Ted

Controller owns contract adoption/document reconciliation; Ted's continuation must include the full adopted block, not a pointer to an undecided proposal.

1. **Contract/document reconciliation:** update `client/lib/data/storage/storage_contract.dart`; canonical C1 and every task capsule in `docs/superpowers/plans/2026-09-15-dumps-selection-save-folder.md`; `.superpowers/sdd/2026-09-15-dumps-selection-save-folder/shared-implementation-context.md`; current Task 4 brief and any other live generated task briefs containing C1. Amend Task 4 allowed files/4.2/4.3 and Task 2 legacy-inspection description to the precise capture/freeze/resolve semantics. Add the adopted interface clarification to design §4 without changing its product scope. Keep historical immutable review packages and reports intact; clearly supersede their old interface descriptions through the controller's current contract. No specialist should silently execute an old capsule.
2. **Dart prerequisite:** narrowly modify `storage_codec.dart`, `saf_storage_backend.dart`, `filesystem_storage_backend.dart`; add optional parameter, envelope helpers, exact argument forwarding, nullable-location decoding, response validation and two-mode behavior. Keep existing C1 data shapes, old codec semantics and other backend operations unchanged.
3. **Native prerequisite:** modify only `AndroidDocumentsPort.kt` legacy-inspection branch plus, if needed, a small stateless `client/android/app/src/main/kotlin/dev/tangent/tangent/storage/LegacyStorageInspection.kt` used by that branch for envelope/selection/policy checks. Add `client/android/app/src/test/kotlin/dev/tangent/tangent/storage/LegacyStorageInspectionTest.kt`. Preserve supervisor/channel ownership, method set, `ProviderQuerySnapshot`, `ProbeReceipts`, existing policy meanings, grant retention and read-only preference behavior. No MainActivity picker/recorder rewrite is needed. JSON/Android boundary wiring remains production code; JVM fakes must exercise its production decision helper, not bypass it.
4. **Original Task 4 work:** retain its scoped catalog, scripted backend, `storage_catalog_test.dart`, `storage_legacy_binding_test.dart` and necessary LocalDb storage helpers. Teach catalog capture/freeze/resolve and exact row-anchor recovery. Scripted implementations must expose capture count, resolution input and separate mutable-current/frozen sources so tests can detect accidental rereads. Current source search found only the interface and two production implementations of `inspectLegacyStorage`, no existing client call sites; still re-search after Task 4 edits and update every explicit override.
5. **Regression extensions:** `storage_codec_test.dart` for anchor schema/literal preservation, `storage_backend_test.dart` for real adapters/mock channel, new native test above and the original Task 4 tests. Use existing dependencies unless the controller explicitly approves a necessary test dependency. No generated DB/schema/table migration, new preference, sidecar schema, service/UI feature or unrelated Task 3 refactor.

## 7. Behavioral test matrix / acceptance requirements

| Case | Required proof |
|---|---|
| Capture before denied/hanging provider | Capture makes zero provider calls, returns the selected URI envelope; SQLite freezes it before a gated resolution begins. Resolution failure/blockage cannot erase the durable anchor. |
| Absent vs unavailable preference | Successful null read is `Ok(null)` and persists explicit-null sentinel; wrong-typed/read-failed/channel-lost source is Fail and does not advance bootstrap or freeze absence. Empty String remains a String snapshot. |
| Recovery after current preference/default changes | Capture A; persist; change preference/default to B; recreate DB/coordinator/catalog; supplied-anchor resolution reads A and never invokes the preference reader. Exact singleton/per-row anchor bytes and original audio/Dumps fields remain unchanged. |
| Known unconfigured snapshot | Freeze explicit null, later configure B; old unresolved rows stay null-anchored and are never rebound to B. New default workflow remains separate. |
| Source/envelope validation | Malformed outer JSON, missing/wrong fields/version/policy/cross-kind fail closed with no preference/provider fallback. Well-shaped envelope containing invalid raw source stays retained/unresolved. Returned malformed/null/mismatched resolution payload is rejected. |
| Literal identity | Mixed-case authority, Unicode, percent spelling, encoded slash/dot/percent IDs and noncanonical JSON whitespace round-trip exactly; malformed path structure/escapes/NUL cannot authorize access. No normalization of original URI/anchor. |
| Legacy policy | Documents→one Tangent; direct Tangent; missing/duplicate/virtual/non-directory child; unknown folder; tree-document URI whose tree ID is parent. Wrong returned selected/effective ID rejected. No child creation or parent inference. |
| Access return | Missing grant/provider loading/error produces anchor-only; later valid access resolves the same anchor. Existing query-classifier/receipt regression suites remain green. |
| Original row ownership | Effective root resolution alone cannot bind a foreign same-name ID. Exact original document identity required; ambiguous/foreign rows stay anchored, unresolved and undeletable. Healthy peers work without rewriting old rows. |
| Filesystem freeze | Freeze A while missing; pass B on later call; restore A and resolve only A. Test links, relative/empty root, drive/UNC literal encoding, no directory/file creation and no metadata writes. |
| Persistence race/crash | Competing first captures choose one SQLite winner; delayed loser cannot replace it. Fail freeze transaction and restart; only committed anchor is used. Reopen after freeze before row chunks; resume against stored bytes. Failure after partial chunks preserves stable row keys/anchors. |
| Native transport/lifetime | Real StorageChannel/worker test preserves capture/resolution result across owner replacement until acknowledgement. Dart mock-channel separately proves optional arg, null location and exact anchor decoding. Inventory/settled handling stays unchanged. Distinguish these seams from unperformed physical Android acceptance. |
| Task 4 regressions | Original cancel/probe cleanup/commit rollback/revision/token/process-epoch/concurrent chooser/capture-serialization/same-directory tests still required. Recovery never resets a later default or invokes unrestricted import. |

Ted should obtain behavioral RED for the old decoder/frozen-input failure and wrong-source recovery, not merely missing-signature errors; then run the final task-focused suite, prior storage/codec/migration/lifetime/retirement regressions, full Flutter/analyzer and relevant native suite with actual logs/exits/source hashes. From `client/android`, the relevant native command remains `./gradlew.bat :app:testDebugUnitTest --console=plain`; use the existing full Flutter paths and logging convention. A changed native implementation requires a fresh native gate. This consultation ran none of those commands.
