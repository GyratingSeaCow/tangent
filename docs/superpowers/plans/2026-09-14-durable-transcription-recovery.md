# Durable Transcription Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make server transcription idempotent and recoverable across navigation, app suspension, and process death while showing durable transcript-status pills and independent Mode/Transcript filters.

**Architecture:** The server assigns one job to each client-generated request ID and returns that same job for safe retries. The Flutter client stores the latest attempt on its existing Drift `dumps` row, treats SQLite as the authority, reconciles unfinished work on startup/resume, and uses SSE with polling fallback. List and detail screens render reactive database state rather than screen-owned operation state.

**Tech Stack:** Python 3.14, FastAPI, SQLite, pytest; Dart 3.6+, Flutter 3.27+, Riverpod 2.5, Drift 2.20, Dio 5.7, uuid 4.5.

## Global Constraints

- Preserve AGPL-3.0-or-later headers in every source and test file.
- Server model remains exactly `large-v3`; do not restore on-device Whisper.
- Allowed durable client statuses are exactly `not_transcribed`, `uploading`, `queued`, `running`, `completed`, and `failed`.
- Preserve raw recordings on every failure path.
- Persist a new request ID before the first network call of a new attempt.
- A retry creates a new request ID and increments the attempt; replay/recovery reuses the current request ID.
- An older attempt must never overwrite a newer attempt.
- Clean SSE EOF, socket failure, and timeout before a terminal event fall back to polling under one shared 30-minute deadline; they do not enqueue another job.
- Do not add an Android foreground service or server-side cancellation.
- Keep Mode and Transcript as two independent filter rows combined with logical AND.
- Physical installation uses `adb install -r`; never run `pm clear`.
- Follow strict RED → GREEN → REFACTOR for every behavior below and commit only green states.

---

## File Map

### Server

- `server/app/db.py` — additive jobs-table migration and unique request-ID index.
- `server/app/models.py` — request/response API schema for `request_id`.
- `server/app/services/job_queue.py` — atomic create-or-return job operation.
- `server/app/api/jobs.py` — idempotent HTTP semantics, conflict response, and one-time background scheduling.
- `server/tests/test_db.py` — fresh and legacy schema migration coverage.
- `server/tests/test_jobs.py` — idempotency, conflicts, and stable polling/SSE identity.
- `server/tests/test_audio_upload.py` — required request ID on the no-audio contract test.
- `server/tests/test_live_sse.py` — required request ID on the opt-in live transcription test.

### Flutter client

- `client/lib/models/transcription_status.dart` — durable wire enum and filter predicates.
- `client/lib/data/local_db.dart` — Drift v4 columns, migration, guarded updates, recovery query.
- `client/lib/data/local_db.g.dart` — generated Drift output; regenerate, never hand-edit.
- `client/lib/data/recording_metadata.dart` — sidecar schema v2 serialization/import of durable transcription fields.
- `client/lib/services/transcription_client.dart` — typed job snapshot, request-ID enqueue, poll endpoint, resilient SSE fallback.
- `client/lib/services/server_transcription_service.dart` — durable start, persistence, reattachment, and stale-attempt guards.
- `client/lib/services/server_transcription.dart` — delete in Task 6 after list/detail consumers move to durable `DumpRow` state.
- `client/lib/screens/home/home_providers.dart` — app-scoped service wiring.
- `client/lib/main.dart` — lifecycle/startup recovery host.
- `client/lib/screens/dump/dumps_providers.dart` — independent Mode and Transcript filters.
- `client/lib/screens/dump/dumps_list_screen.dart` — explicit status pills and two filter rows.
- `client/lib/screens/dump/dump_detail_screen.dart` — reactive durable progress/completion/failure controls.
- `client/test/unit/data/local_db_test.dart` — v4 migration and guarded persistence.
- `client/test/unit/data/recording_metadata_test.dart` — sidecar round-trip.
- `client/test/unit/services/transcription_client_test.dart` — request payload, polling mapping, and SSE fallback.
- `client/test/unit/services/server_transcription_service_test.dart` — durable orchestration and recovery.
- `client/test/widget/dump_detail_playback_test.dart` — compile-safe fake client after the transport contract changes.
- `client/test/widget/dumps_providers_test.dart` — combined filter behavior.
- `client/test/widget/dumps_list_transcription_indicator_test.dart` — all pills and both filter rows.
- `client/test/widget/dump_detail_local_transcription_test.dart` — route exit/re-entry and retry presentation.
- `client/test/widget/home_screen_test.dart` — startup/resume recovery wiring where needed.

---

### Task 1: Idempotent Server Job Contract

**Files:**
- Modify: `server/app/db.py`
- Modify: `server/app/models.py`
- Modify: `server/app/services/job_queue.py`
- Modify: `server/app/api/jobs.py`
- Test: `server/tests/test_db.py`
- Test: `server/tests/test_jobs.py`
- Test: `server/tests/test_audio_upload.py`
- Test: `server/tests/test_live_sse.py`

**Interfaces:**
- Consumes: existing `POST /v1/dumps/{dump_id}/transcribe`, `GET /v1/jobs/{job_id}`, and `run_job_inline(job_id, audio_path)`.
- Produces: `JobCreate.request_id: str`; `JobResponse.request_id: str`; `enqueue_job(db, dump_id, model, request_id) -> tuple[str, bool]`, where the boolean is true only for a newly inserted row.

- [ ] **Step 1: Write failing database migration tests**

Add tests that create the legacy jobs schema, insert two rows, call `init_db`, and assert exact deterministic IDs and uniqueness:

```python
def test_init_db_migrates_legacy_jobs_to_request_ids(temp_data_dir: Path) -> None:
    db_path = temp_data_dir / "tangent.db"
    conn = sqlite3.connect(db_path)
    conn.executescript(SCHEMA.replace("request_id TEXT NOT NULL,", ""))
    conn.executemany(
        "INSERT INTO jobs (id, dump_id, status, model) VALUES (?, ?, ?, ?)",
        [
            ("job-a", "dump-a", "queued", "large-v3"),
            ("job-b", "dump-b", "failed", "large-v3"),
        ],
    )
    conn.commit()
    conn.close()

    init_db(str(temp_data_dir))

    conn = sqlite3.connect(db_path)
    rows = conn.execute(
        "SELECT id, request_id FROM jobs ORDER BY id"
    ).fetchall()
    indexes = conn.execute("PRAGMA index_list('jobs')").fetchall()
    conn.close()
    assert rows == [
        ("job-a", "legacy:job-a"),
        ("job-b", "legacy:job-b"),
    ]
    assert any(index[1] == "idx_jobs_request_id" and index[2] == 1 for index in indexes)
```

Also import `SCHEMA` from `app.db` for this fixture, extend the fresh-schema test to assert `request_id` is present and non-nullable, and assert inserting a third row with `request_id = 'legacy:job-a'` raises `sqlite3.IntegrityError`.

- [ ] **Step 2: Run the migration tests and verify RED**

```bash
cd server
/c/Python314/python.exe -m pytest tests/test_db.py -q
```

Expected: failure because legacy databases are not upgraded and `jobs.request_id` does not exist.

- [ ] **Step 3: Implement the additive server migration**

In `db.py`, define `_migrate_jobs_request_id(conn)` and call it after `conn.executescript(SCHEMA)` but before commit:

```python
def _migrate_jobs_request_id(conn: sqlite3.Connection) -> None:
    columns = {row[1] for row in conn.execute("PRAGMA table_info(jobs)")}
    if "request_id" not in columns:
        conn.execute("ALTER TABLE jobs ADD COLUMN request_id TEXT")
    conn.execute(
        "UPDATE jobs SET request_id = 'legacy:' || id "
        "WHERE request_id IS NULL OR request_id = ''"
    )
    conn.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_jobs_request_id "
        "ON jobs(request_id)"
    )
```

Add `request_id TEXT NOT NULL` to the fresh `CREATE TABLE jobs` statement. Do not place the request-ID index inside `SCHEMA`, because old tables lack the column until the migration runs.

- [ ] **Step 4: Run database tests and verify GREEN**

```bash
/c/Python314/python.exe -m pytest tests/test_db.py -q
```

Expected: all `test_db.py` tests pass.

- [ ] **Step 5: Write failing API idempotency tests**

Update existing enqueue payloads to include a fixed request ID, then add these behaviors:

```python
def test_repeating_request_id_returns_same_job_without_rescheduling(
    authed_client_with_dump, monkeypatch
):
    client, token, dump_id = authed_client_with_dump
    scheduled = []
    monkeypatch.setattr(
        "app.api.jobs.run_job_inline",
        lambda job_id, audio_path: scheduled.append(job_id),
    )
    payload = {"model": "large-v3", "request_id": "request-repeat-001"}
    first = client.post(
        f"/v1/dumps/{dump_id}/transcribe", json=payload, headers=_auth(token)
    )
    second = client.post(
        f"/v1/dumps/{dump_id}/transcribe", json=payload, headers=_auth(token)
    )
    assert first.status_code == 201
    assert second.status_code == 200
    assert second.json()["id"] == first.json()["id"]
    assert second.json()["request_id"] == "request-repeat-001"
    assert scheduled == [first.json()["id"]]


def test_request_id_conflicts_across_dump_or_model(authed_client_with_dump):
    client, token, dump_id = authed_client_with_dump
    request_id = "request-conflict-001"
    first = client.post(
        f"/v1/dumps/{dump_id}/transcribe",
        json={"model": "large-v3", "request_id": request_id},
        headers=_auth(token),
    )
    conflict = client.post(
        f"/v1/dumps/{dump_id}/transcribe",
        json={"model": "small", "request_id": request_id},
        headers=_auth(token),
    )
    assert first.status_code == 201
    assert conflict.status_code == 409
```

Add a second seeded dump to cover cross-dump conflict separately. Extend polling/SSE assertions to require the same `request_id`. For the completed SSE test, insert `request_id = 'request-stream-001'`, parse the `data:` line with `json.loads`, and assert exactly `{"status": "completed", "request_id": "request-stream-001", "transcript": transcript}`.

- [ ] **Step 6: Run API tests and verify RED**

```bash
/c/Python314/python.exe -m pytest tests/test_jobs.py -q
```

Expected: validation failures because `request_id` is unsupported and repeated requests create distinct jobs.

- [ ] **Step 7: Implement create-or-return semantics**

Use exact Pydantic fields:

```python
class JobCreate(BaseModel):
    model: str = Field(default="large-v3", min_length=1, max_length=50)
    request_id: str | None = Field(default=None, min_length=8, max_length=128)


class JobResponse(BaseModel):
    id: str
    request_id: str
    dump_id: str
    status: JobStatus
    model: str
    started_at: datetime | None
    completed_at: datetime | None
    result_transcript: str | None
    error: str | None
```

In the queue layer, query `request_id` before inserting. Return `(existing_id, False)` only when both dump ID and model match; otherwise raise a named `RequestIdConflict`. Catch the unique-index race by re-reading the winning row after `sqlite3.IntegrityError`. Add a FastAPI `Response` parameter to the route, schedule `run_job_inline` only when `created is True`, and set `response.status_code` to 201 for new or 200 for replay. Map conflicts to HTTP 409. A matching replay must be returned before checking whether audio still exists. During this server-first task only, omitted request IDs remain backward compatible: generate `legacy:<uuid>` server-side and add a test proving omission still returns 201. Task 3 makes the field required in the same commit that cuts over every client caller. Update `test_audio_upload.py` and `test_live_sse.py` to send unique request IDs. Include `request_id` in the SSE query and emitted payload, serialized only with `json.dumps(payload)`.

- [ ] **Step 8: Run server tests and verify GREEN**

```bash
/c/Python314/python.exe -m pytest -q
```

Expected: full server suite passes with no duplicate background scheduling.

- [ ] **Step 9: Leave the compatible server contract uncommitted for the Task 3 client cutover**

```bash
git diff --check -- server
```

Expected: the server suite is green and the existing client remains compatible because omission is temporarily accepted. The atomic server+client contract commit occurs in Task 3.

---

### Task 2: Durable Client Schema and Sidecar State

**Files:**
- Create: `client/lib/models/transcription_status.dart`
- Modify: `client/lib/data/local_db.dart`
- Regenerate: `client/lib/data/local_db.g.dart`
- Modify: `client/lib/data/recording_metadata.dart`
- Test: `client/test/unit/data/local_db_test.dart`
- Test: `client/test/unit/data/recording_metadata_test.dart`

**Interfaces:**
- Consumes: existing `DumpRow`, `dumpMetadata`, and `importedDumpRow`.
- Produces: `TranscriptionStatus`; `Future<DumpRow> beginTranscriptionAttempt(String id, {required String requestId, required DateTime now})`; `Future<bool> updateTranscriptionStatus(String id, {required int attempt, required String requestId, required TranscriptionStatus status, required DateTime now, String? jobId, String? error})`; `Future<bool> completeTranscriptionAttempt(String id, {required int attempt, required String requestId, required String transcript, String? meetingNotes, required DateTime now})`; `Future<List<DumpRow>> dumpsNeedingTranscriptionRecovery()`.

- [ ] **Step 1: Write failing enum and v3→v4 migration tests**

Define expected enum behavior in a new test group:

```dart
expect(TranscriptionStatus.fromWire('not_transcribed'),
    TranscriptionStatus.notTranscribed);
expect(TranscriptionStatus.uploading.isInProgress, isTrue);
expect(TranscriptionStatus.queued.isInProgress, isTrue);
expect(TranscriptionStatus.running.isInProgress, isTrue);
expect(TranscriptionStatus.completed.isTerminal, isTrue);
expect(TranscriptionStatus.failed.isTerminal, isTrue);
```

Build a real v3 in-memory database with one blank transcript and one non-empty transcript, open it through `LocalDb`, and assert:

```dart
expect(sqlite.userVersion, 4);
expect(blank.transcriptionStatus, 'not_transcribed');
expect(done.transcriptionStatus, 'completed');
expect(done.transcriptionCompletedAt, done.updatedAt);
expect(blank.transcriptionAttempt, 0);
```

- [ ] **Step 2: Run migration tests and verify RED**

```bash
cd client
"~/AppData/Local/flutter/bin/flutter.bat" test test/unit/data/local_db_test.dart
```

Expected: compile/test failure because the enum and v4 columns do not exist.

- [ ] **Step 3: Add the durable enum and Drift v4 columns**

Create the enum with exact wire values:

```dart
enum TranscriptionStatus {
  notTranscribed('not_transcribed'),
  uploading('uploading'),
  queued('queued'),
  running('running'),
  completed('completed'),
  failed('failed');

  const TranscriptionStatus(this.wireValue);
  final String wireValue;

  bool get isInProgress =>
      this == uploading || this == queued || this == running;
  bool get isTerminal => this == completed || this == failed;

  static TranscriptionStatus fromWire(String value) =>
      values.firstWhere((status) => status.wireValue == value);
}
```

Add all eight columns from the approved design to `Dumps`, raise `schemaVersion` to 4, add each column in `onUpgrade` when `from < 4`, then run one SQL update that marks `TRIM(COALESCE(transcript, '')) != ''` as completed and all other rows as not transcribed.

- [ ] **Step 4: Regenerate Drift and verify migration GREEN**

```bash
"~/AppData/Local/flutter/bin/flutter.bat" pub run build_runner build --delete-conflicting-outputs
"~/AppData/Local/flutter/bin/flutter.bat" test test/unit/data/local_db_test.dart
```

Expected: generated row/companion types expose every v4 field and all local DB tests pass.

- [ ] **Step 5: Write failing guarded-update and recovery-query tests**

Use two attempts for the same dump and prove stale writes return false:

```dart
final first = await db.beginTranscriptionAttempt(
  'test-1', requestId: 'request-first', now: now);
final second = await db.beginTranscriptionAttempt(
  'test-1', requestId: 'request-second', now: now.add(const Duration(seconds: 1)));
final stale = await db.updateTranscriptionStatus(
  'test-1', attempt: first.transcriptionAttempt,
  requestId: 'request-first', status: TranscriptionStatus.failed,
  now: now.add(const Duration(seconds: 2)), error: 'old failure');
expect(stale, isFalse);
expect((await db.getDump('test-1'))!.transcriptionRequestId, 'request-second');
```

Also assert the recovery query returns `uploading`, `queued`, and `running` rows plus completed rows whose error begins with `sidecar_sync_pending:`; exclude ordinary completed, failed, and not-transcribed rows.

- [ ] **Step 6: Implement atomic latest-attempt helpers**

Use Drift transactions and guarded `WHERE id = ? AND transcription_attempt = ? AND transcription_request_id = ?`. `beginTranscriptionAttempt` must increment the persisted attempt, write `uploading`, write the request ID and timestamps, clear job ID/completion/error, and return the updated row before the transaction ends. `completeTranscriptionAttempt` must atomically write transcript, optional meeting notes, `completed`, and completion/update timestamps under the same guard.

- [ ] **Step 7: Write failing sidecar v2 round-trip test**

Assert `dumpMetadata` emits and `importedDumpRow` restores every durable field, including request/job IDs, attempt, timestamps, status, and error. Assert importing schema-v1 metadata defaults to completed only when its transcript is non-empty.

- [ ] **Step 8: Implement sidecar v2 and verify all data tests GREEN**

Raise `recordingMetadataSchemaVersion` to 2. Serialize the durable fields with UTC ISO-8601 timestamps and restore them with safe defaults. Then run:

```bash
"~/AppData/Local/flutter/bin/flutter.bat" test test/unit/data/local_db_test.dart test/unit/data/recording_metadata_test.dart
```

Expected: both test files pass.

- [ ] **Step 9: Commit durable client storage**

```bash
git add client/lib/models/transcription_status.dart client/lib/data/local_db.dart client/lib/data/local_db.g.dart client/lib/data/recording_metadata.dart client/test/unit/data/local_db_test.dart client/test/unit/data/recording_metadata_test.dart
git commit -m "feat(client): persist transcription attempts"
```

---

### Task 3: Typed Job Transport and SSE-to-Polling Recovery

**Files:**
- Modify: `client/lib/services/transcription_client.dart`
- Modify: `server/app/models.py`
- Modify: `server/tests/test_jobs.py`
- Test: `client/test/unit/services/transcription_client_test.dart`
- Modify: `client/test/unit/services/server_transcription_service_test.dart`
- Modify: `client/test/widget/dumps_list_transcription_indicator_test.dart`
- Modify: `client/test/widget/dump_detail_local_transcription_test.dart`
- Modify: `client/test/widget/dump_detail_playback_test.dart`

**Interfaces:**
- Consumes: server `JobResponse` including `request_id` and `result_transcript`.
- Produces: immutable `TranscriptionJobSnapshot`; `enqueueTranscription(..., required String requestId) -> Future<TranscriptionJobSnapshot>`; `getJob(String jobId) -> Future<TranscriptionJobSnapshot>`; `streamJob` that always reaches a terminal event or emits timeout under one shared deadline.

- [ ] **Step 1: Write failing request/poll mapping tests**

Assert enqueue sends exactly:

```dart
expect(request.data, {
  'model': 'large-v3',
  'request_id': 'request-client-001',
});
```

Assert a polling response with `result_transcript` maps to:

```dart
expect(snapshot.id, 'job-1');
expect(snapshot.requestId, 'request-client-001');
expect(snapshot.status, 'completed');
expect(snapshot.transcript, 'poll result');
```

- [ ] **Step 2: Run transport tests and verify RED**

```bash
"~/AppData/Local/flutter/bin/flutter.bat" test test/unit/services/transcription_client_test.dart
```

Expected: compile failure because enqueue returns only a string and `getJob`/snapshot do not exist.

- [ ] **Step 3: Implement the typed snapshot and API methods**

Use this public shape:

```dart
final class TranscriptionJobSnapshot {
  const TranscriptionJobSnapshot({
    required this.id,
    required this.requestId,
    required this.dumpId,
    required this.status,
    required this.model,
    this.startedAt,
    this.completedAt,
    this.transcript,
    this.error,
  });
  final String id;
  final String requestId;
  final String dumpId;
  final String status;
  final String model;
  final DateTime? startedAt;
  final DateTime? completedAt;
  final String? transcript;
  final String? error;
}
```

Centralize JSON parsing so both enqueue and `getJob` map `result_transcript` consistently. Update every concrete `implements TranscriptionClient` fake in the four listed test files with the new enqueue signature and `getJob`; Mockito's `_MockClient extends Mock implements TranscriptionClient` needs no manual method bodies.

- [ ] **Step 4: Write failing SSE EOF/socket/timeout/shared-deadline fallback tests**

Inject an `HttpClient` factory, `DateTime Function()` clock, and `Future<void> Function(Duration)` delay into `TranscriptionClient.forTesting`. Cover three separate cases: a 200 SSE response ending after `running`, a socket error before terminal state, and a timeout before terminal state. In every case, return a completed poll response and assert one terminal `completed` event carrying `poll result`. Add a fake-clock test that spends 20 minutes in SSE, advances through 10 minutes of polling, then emits timeout; prove polling does not receive a fresh 30-minute budget.

- [ ] **Step 5: Implement terminal-aware fallback**

At entry to `streamJob`, compute one `deadline = now().add(maxWait)` and pass that deadline to both SSE and polling. Track whether SSE emitted `completed` or `failed`. If iteration ends cleanly without either, throw `_SseUnavailable('SSE ended before terminal event')`. Convert socket and timeout errors to `_SseUnavailable`, then poll only for the remaining deadline. Poll immediately once before delaying; stop at completed/failed; map `result_transcript` into event data as `transcript`.

- [ ] **Step 6: Run transport tests and full client analysis**

```bash
"~/AppData/Local/flutter/bin/flutter.bat" test test/unit/services/transcription_client_test.dart
"~/AppData/Local/flutter/bin/flutter.bat" analyze
```

Expected: test file passes and analyzer reports no issues.

- [ ] **Step 7: Enforce the required server field and run both suites**

Change `JobCreate.request_id` from the temporary optional field to `str = Field(min_length=8, max_length=128)`. Replace the temporary omission-compatibility test with an assertion that omission returns HTTP 422. Then run:

```bash
cd ~/Documents/ADH2/server
/c/Python314/python.exe -m pytest -q
cd ../client
"~/AppData/Local/flutter/bin/flutter.bat" test
```

Expected: both full suites pass with server and client on the same required request-ID contract.

- [ ] **Step 8: Commit the atomic server/client contract and resilient transport**

```bash
git add server/app/db.py server/app/models.py server/app/services/job_queue.py server/app/api/jobs.py server/tests/test_db.py server/tests/test_jobs.py server/tests/test_audio_upload.py server/tests/test_live_sse.py client/lib/services/transcription_client.dart client/test/unit/services/transcription_client_test.dart client/test/unit/services/server_transcription_service_test.dart client/test/widget/dumps_list_transcription_indicator_test.dart client/test/widget/dump_detail_local_transcription_test.dart client/test/widget/dump_detail_playback_test.dart
git commit -m "feat: add idempotent recoverable transcription jobs"
```

---

### Task 4: Durable Start and Completion Orchestration

**Files:**
- Modify: `client/lib/services/server_transcription_service.dart`
- Test: `client/test/unit/services/server_transcription_service_test.dart`

**Interfaces:**
- Consumes: Task 2 guarded DB helpers and Task 3 job transport.
- Produces: `transcribeDump(String dumpId)`, backed by durable state; `reconcilePending()` is added in Task 5.

- [ ] **Step 1: Replace fake-client signatures and write the failing persist-before-network test**

Make the fake capture the dump row at its first client call:

```dart
onCreateDump = () async {
  final persisted = await db.getDump('r1');
  expect(persisted!.transcriptionStatus, 'uploading');
  expect(persisted.transcriptionRequestId, isNotEmpty);
  expect(persisted.transcriptionAttempt, 1);
};
```

Assert enqueue receives that same request ID and its returned job ID is persisted.

- [ ] **Step 2: Run the service test and verify RED**

```bash
"~/AppData/Local/flutter/bin/flutter.bat" test test/unit/services/server_transcription_service_test.dart
```

Expected: failure because current operation state is only in memory and enqueue accepts no request ID.

- [ ] **Step 3: Implement durable start flow**

Inject `Uuid` or a `String Function()` request-ID factory for deterministic tests. At the start of a new attempt, reject durable in-progress duplicates, persist the request ID/attempt first, then create metadata, upload audio, enqueue with the persisted ID, and guard every later database write by attempt plus request ID. Drive any compatibility presentation getters by the current `DumpRow`, not `_terminal`.

- [ ] **Step 4: Write failing completion/error tests**

Cover:

```dart
expect(saved.transcriptionStatus, 'completed');
expect(saved.transcriptionJobId, 'job-r1');
expect(saved.transcript, 'phone transcript');
expect(metadata['transcript'], 'phone transcript');
expect(metadata['transcriptionStatus'], 'completed');
```

For definitive HTTP rejection (authentication, validation, or request-ID conflict) and terminal server failures, assert `failed`, a stored error, and that `storage.pathFor(id).existsSync()` remains true. Separately simulate socket loss/timeout after enqueue may have reached the server: assert the row stays nonterminal with the same request ID, remains eligible for reconciliation, and does not expose a new-attempt Retry path. For an empty completed transcript, assert the exact stored error contains `Server returned an empty transcript`.

- [ ] **Step 5: Implement guarded transitions and winning-row sidecar repair**

Persist `queued` with job ID after enqueue and `running` on the running event. On completion, first call the guarded atomic database completion. Only when that returns true, fetch the winning committed row and write its sidecar. If the sidecar write fails, keep the completed transcript and set `transcription_error` to a `sidecar_sync_pending:` marker under the same attempt/request guard. Reconciliation rewrites the sidecar from that winning row and clears the marker. A stale attempt that loses the database guard never writes the sidecar. Treat uncertain transport failures as recoverable nonterminal state; only definitive HTTP rejection or a server `failed` event becomes durable `failed`.

- [ ] **Step 6: Write and satisfy stale-attempt tests**

Pause attempt 1, start attempt 2 after marking attempt 1 failed, then release attempt 1's completion. Assert attempt 2's request ID, status, transcript, and sidecar remain unchanged. Do not accept a test that checks only in-memory operation state.

- [ ] **Step 7: Run service and data tests GREEN**

```bash
"~/AppData/Local/flutter/bin/flutter.bat" test test/unit/services/server_transcription_service_test.dart test/unit/data/local_db_test.dart test/unit/data/recording_metadata_test.dart
```

Expected: all pass.

- [ ] **Step 8: Commit durable orchestration**

```bash
git add client/lib/services/server_transcription_service.dart client/lib/services/server_transcription.dart client/test/unit/services/server_transcription_service_test.dart
git commit -m "feat(client): make transcription orchestration durable"
```

---

### Task 5: Startup, Resume, and Reattachment

**Files:**
- Modify: `client/lib/services/server_transcription_service.dart`
- Modify: `client/lib/screens/home/home_providers.dart`
- Modify: `client/lib/main.dart`
- Test: `client/test/unit/services/server_transcription_service_test.dart`
- Test: `client/test/widget/home_screen_test.dart`

**Interfaces:**
- Consumes: persisted statuses/request IDs/job IDs and typed `getJob`/enqueue methods.
- Produces: `Future<void> reconcilePending()` and an app lifecycle host that invokes it at startup and on `AppLifecycleState.resumed`.

- [ ] **Step 1: Write failing reattachment tests**

Seed one `running` row with a job ID, construct a fresh service, call `reconcilePending`, and assert:

```dart
expect(fake.createCalls, 0);
expect(fake.uploadCalls, 0);
expect(fake.enqueueCalls, 0);
expect(fake.getJobCalls, 1);
expect((await db.getDump('r1'))!.transcript, 'recovered transcript');
```

Seed a second `uploading` row with a request ID but no job ID. Assert recovery calls idempotent enqueue with the stored request ID, persists the returned job ID, and does not generate a new request ID. Model server 404/missing-dump and assert metadata creation followed by replay with the same request ID. Model server 422/no-audio separately and assert audio upload followed by replay with the same request ID.

- [ ] **Step 2: Run recovery tests and verify RED**

```bash
"~/AppData/Local/flutter/bin/flutter.bat" test test/unit/services/server_transcription_service_test.dart
```

Expected: compile failure because `reconcilePending` does not exist.

- [ ] **Step 3: Implement non-blocking independent reconciliation**

Use one short in-flight scan future so startup and resume cannot launch duplicate watchers. Reconcile rows independently: never await one row's long-running stream before inspecting the next row. First poll/resolve every initial snapshot, then attach nonterminal jobs as separately tracked futures keyed by dump ID. Add a test where row A remains running indefinitely while row B is already completed; row B must persist promptly. For each recoverable row:

1. If job ID exists, call `getJob` first.
2. If its snapshot is terminal, persist it immediately.
3. If nonterminal, attach to `streamJob` without upload/enqueue.
4. If only request ID exists, call idempotent enqueue first.
5. On server 404 for a missing dump, recreate metadata and replay the same request ID.
6. On server 422 for missing audio, upload audio and replay the same request ID.

Continue reconciling other rows if one row fails. Store per-row connection errors without deleting IDs or audio. Also process completed rows carrying `sidecar_sync_pending:` by rewriting metadata from the committed row and clearing only that marker.

- [ ] **Step 4: Write failing lifecycle-host widget test**

Override the service with a counting fake, pump `TangentApp`, then send:

```dart
final binding = tester.binding;
await binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
await binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
await service.reconcileCompleted.future;
await tester.pumpAndSettle();
expect(service.reconcileCalls, 2); // startup + resume
```

- [ ] **Step 5: Add the app-scoped lifecycle host**

Make a small `ConsumerStatefulWidget` that observes `WidgetsBinding`, calls `ref.read(serverTranscriptionServiceProvider).reconcilePending()` once after startup, calls it again on `resumed`, and removes itself as observer in `dispose`. Wrap the router/home content with this host. Do not dispose the service when a detail route pops.

- [ ] **Step 6: Verify lifecycle and recovery GREEN**

```bash
"~/AppData/Local/flutter/bin/flutter.bat" test test/unit/services/server_transcription_service_test.dart test/widget/home_screen_test.dart
"~/AppData/Local/flutter/bin/flutter.bat" analyze
```

Expected: all tests pass and analyzer reports no issues.

- [ ] **Step 7: Commit lifecycle recovery**

```bash
git add client/lib/services/server_transcription_service.dart client/lib/screens/home/home_providers.dart client/lib/main.dart client/test/unit/services/server_transcription_service_test.dart client/test/widget/home_screen_test.dart
git commit -m "feat(client): reconcile transcriptions on startup and resume"
```

---

### Task 6: Explicit Status Pills and Independent Filters

**Files:**
- Modify: `client/lib/screens/dump/dumps_providers.dart`
- Modify: `client/lib/screens/dump/dumps_list_screen.dart`
- Modify: `client/lib/screens/dump/dump_detail_screen.dart`
- Modify: `client/lib/data/local_db.dart`
- Delete: `client/lib/services/server_transcription.dart`
- Modify: `client/lib/services/server_transcription_service.dart`
- Test: `client/test/widget/dumps_providers_test.dart`
- Test: `client/test/widget/dumps_list_transcription_indicator_test.dart`
- Test: `client/test/widget/dump_detail_local_transcription_test.dart`

**Interfaces:**
- Consumes: `DumpRow.transcriptionStatus` and reactive `dumpsProvider`.
- Produces: `DumpModeFilter`, `TranscriptFilter`, `filterDumps(rows, mode, transcript)`, `LocalDb.watchDump(String id) -> Stream<DumpRow?>`, `dumpProvider(String id)`, status pill widget, and durable detail controls.

- [ ] **Step 1: Write failing independent-filter tests**

Replace `DumpFilter.awaiting` coverage with two enums. Use rows spanning both dimensions and assert exact combinations:

```dart
expect(
  filterDumps(rows, DumpModeFilter.meeting, TranscriptFilter.needsTranscript)
      .map((row) => row.id),
  ['meeting-not-transcribed'],
);
expect(
  filterDumps(rows, DumpModeFilter.all, TranscriptFilter.inProgress)
      .map((row) => row.id),
  ['uploading', 'queued', 'running'],
);
```

Repeat through `searchResultsProvider` to prove search is constrained by both selected filters.

- [ ] **Step 2: Run provider tests and verify RED**

```bash
"~/AppData/Local/flutter/bin/flutter.bat" test test/widget/dumps_providers_test.dart
```

Expected: compile failure because independent filter providers do not exist.

- [ ] **Step 3: Implement the two filter providers**

Use exact labels:

```dart
enum DumpModeFilter { all, brainDump, meeting }
enum TranscriptFilter { all, needsTranscript, inProgress, transcribed, failed }
```

Create non-auto-disposed `StateProvider`s for both. `filteredDumpsProvider` and `searchResultsProvider` must watch both and combine predicates with logical AND.

- [ ] **Step 4: Write failing pill/widget tests**

Seed at least eight rows, including two completed and two not-transcribed rows, and assert row-specific keyed pills:

```dart
expect(find.byKey(const ValueKey('transcription-pill-dump-a-not-transcribed')), findsOneWidget);
expect(find.byKey(const ValueKey('transcription-pill-dump-b-not-transcribed')), findsOneWidget);
expect(find.byKey(const ValueKey('transcription-pill-dump-c-completed')), findsOneWidget);
expect(find.byKey(const ValueKey('transcription-pill-dump-d-completed')), findsOneWidget);
expect(find.text('Not transcribed'), findsNWidgets(2));
expect(find.text('Uploading'), findsOneWidget);
expect(find.text('Queued'), findsOneWidget);
expect(find.text('Transcribing'), findsOneWidget);
expect(find.text('Transcribed'), findsNWidgets(2));
expect(find.text('Failed'), findsOneWidget);
```

Assert the first row is exactly `All / Brain Dump / Meeting`, the second is `All / Needs transcript / In progress / Transcribed / Failed`, and selecting one chip in each row shows only the intersection.

- [ ] **Step 5: Implement the approved Option A list**

Render one text+icon pill on every row:

- completed: check icon + `Transcribed`, success colors.
- not transcribed: hollow-circle icon + `Not transcribed`, neutral/amber colors.
- uploading: upload icon + `Uploading`, primary colors.
- queued: pending icon + `Queued`, primary colors.
- running: 14px indeterminate progress indicator + `Transcribing`, primary colors.
- failed: error icon + `Failed`, error colors.

Include both dump ID and status in every pill key. Keep sync/privacy information secondary. Remove the old `Awaiting` chip and in-memory `operationFor` list logic. Delete `server_transcription.dart` and remove the service's `_terminal`, `_activeOperation`, `_lastOperation`, `operation`, and `operationFor` compatibility state after all UI consumers use `DumpRow`.

- [ ] **Step 6: Write failing durable detail-state tests**

Add `LocalDb.watchDump(id)` and a Riverpod family provider backed by it. Pump detail screens for durable `running`, `completed`, and `failed` rows. Assert running says work continues when leaving, completed shows transcript and Done, and failed says the recording is preserved and offers Retry. Keep one detail screen mounted, complete its row through the DB, and assert the transcript appears without reopening or a second enqueue. Keep the Dumps list mounted, update another row from running to completed, and assert its pill changes reactively.

- [ ] **Step 7: Implement reactive detail behavior**

Watch the dump row rather than retaining a screen-local operation. Disable duplicate Transcribe taps for in-progress rows. Retry only from failed/not-transcribed and route it through `transcribeDump`, which creates a new request ID. Dispose playback resources only; do not cancel transcription on route disposal.

- [ ] **Step 8: Run all provider/widget tests GREEN**

```bash
"~/AppData/Local/flutter/bin/flutter.bat" test test/widget/dumps_providers_test.dart test/widget/dumps_list_transcription_indicator_test.dart test/widget/dump_detail_local_transcription_test.dart
"~/AppData/Local/flutter/bin/flutter.bat" analyze
```

Expected: all tests pass and analyzer reports no issues.

- [ ] **Step 9: Commit the durable UI**

```bash
git add client/lib/data/local_db.dart client/lib/screens/dump/dumps_providers.dart client/lib/screens/dump/dumps_list_screen.dart client/lib/screens/dump/dump_detail_screen.dart client/lib/services/server_transcription_service.dart client/lib/services/server_transcription.dart client/test/widget/dumps_providers_test.dart client/test/widget/dumps_list_transcription_indicator_test.dart client/test/widget/dump_detail_local_transcription_test.dart
git commit -m "feat(client): show durable transcription status"
```

---

### Task 7: Full Regression, Docker, APK, and Physical Android Proof

**Files:**
- Modify only if verification reveals a tested defect in files already owned by Tasks 1–6.
- Record evidence in commit messages/test output; do not commit recordings, tokens, databases, APKs, or `server/data/`.

**Interfaces:**
- Consumes: complete server/client implementation and the running Docker server on host port 8765.
- Produces: verified server suite, Flutter suite, analyzer, APK, installed app, one-job recovery evidence, local SQLite evidence, and clean PID-scoped logcat.

- [ ] **Step 1: Run all automated gates**

```bash
cd ~/Documents/ADH2/server
/c/Python314/python.exe -m pytest -q
cd ../client
"~/AppData/Local/flutter/bin/flutter.bat" pub get
"~/AppData/Local/flutter/bin/flutter.bat" analyze
"~/AppData/Local/flutter/bin/flutter.bat" test
```

Expected: every server/client test passes, no analyzer issues.

- [ ] **Step 2: Rebuild and health-check the Docker stack**

```bash
cd ~/Documents/ADH2/server
DOCKER_CONFIG="$LOCALAPPDATA/Temp/tangent-docker-config"
mkdir -p "$DOCKER_CONFIG"
export DOCKER_CONFIG
docker compose build
docker compose up -d
docker compose ps
curl --fail --silent http://localhost:8765/health
```

Expected: `tangent-server` is healthy and `/health` succeeds. Do not print the bearer token in logs or commits.

- [ ] **Step 3: Build and install the debug APK without clearing data**

```bash
cd ~/Documents/ADH2/client
"~/AppData/Local/flutter/bin/flutter.bat" build apk --debug
"~/AppData/Local/Android/Sdk/platform-tools/adb.exe" devices
"~/AppData/Local/Android/Sdk/platform-tools/adb.exe" install -r build/app/outputs/flutter-apk/app-debug.apk
```

Expected: APK build succeeds, one authorized device is listed, and install reports success.

- [ ] **Step 4: Prove navigation/background recovery on real speech**

Clear logcat, record a short unique sentence, tap Transcribe, confirm the list pill reaches `Transcribing`, back out, switch apps until the server finishes, then return. Confirm the pill changes to `Transcribed`, detail shows the complete sentence, and no second user tap is required. Use these commands around the manual interaction:

```bash
ADB="~/AppData/Local/Android/Sdk/platform-tools/adb.exe"
$ADB logcat -c
# Perform the navigation/background scenario now.
PID="$($ADB shell pidof -s dev.tangent.tangent | tr -d '\r')"
$ADB logcat -d --pid="$PID" > "$LOCALAPPDATA/Temp/tangent-navigation.log"
```

- [ ] **Step 5: Prove cold-start recovery**

Clear logcat and start a second unique recording. After the job ID is persisted and the server reports running, force-stop Tangent only, wait for server completion, relaunch Tangent, and verify startup reconciliation changes the row to `Transcribed`. Do not clear app data. Capture the relaunched process:

```bash
ADB="~/AppData/Local/Android/Sdk/platform-tools/adb.exe"
$ADB logcat -c
# Start transcription, then force-stop only after its job ID is persisted.
$ADB shell am force-stop dev.tangent.tangent
# Wait for server completion, then launch Tangent from the phone and verify recovery.
PID="$($ADB shell pidof -s dev.tangent.tangent | tr -d '\r')"
$ADB logcat -d --pid="$PID" > "$LOCALAPPDATA/Temp/tangent-cold-start.log"
```

- [ ] **Step 6: Verify one request maps to one server job**

After force-stopping Tangent so SQLite checkpoints cleanly, copy the app database and derive the real request ID:

```bash
ADB="~/AppData/Local/Android/Sdk/platform-tools/adb.exe"
PHONE_DB="$LOCALAPPDATA/Temp/tangent-phone.sqlite"
$ADB shell am force-stop dev.tangent.tangent
$ADB exec-out run-as dev.tangent.tangent cat files/tangent.sqlite > "$PHONE_DB"
REQUEST_ID=$(/c/Python314/python.exe -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); print(c.execute(\"SELECT transcription_request_id FROM dumps WHERE transcription_status='completed' ORDER BY transcription_completed_at DESC LIMIT 1\").fetchone()[0])" "$PHONE_DB")
/c/Python314/python.exe -c "import sqlite3,sys; c=sqlite3.connect('~/Documents/ADH2/server/data/tangent.db'); print(c.execute('SELECT request_id, COUNT(*) FROM jobs WHERE request_id=? GROUP BY request_id',(sys.argv[1],)).fetchone())" "$REQUEST_ID"
```

The equivalent SQL assertion is:

```sql
SELECT request_id, COUNT(*) AS job_count
FROM jobs
WHERE request_id = :observed_request_id
GROUP BY request_id;
```

Expected: `job_count = 1`. The observed value comes from the local database; never substitute a made-up ID.

- [ ] **Step 7: Verify local durable state and sidecar**

Use the copied `tangent-phone.sqlite` from Step 6 and Python's `sqlite3` module to verify the tested dump has a non-empty request ID, non-empty job ID, `completed`, attempt `1`, and the exact transcript. Read its sidecar from the selected Tangent recording folder and verify the same transcript and completed state.

- [ ] **Step 8: Verify PID-scoped runtime logs**

```bash
/c/Python314/python.exe -c "from pathlib import Path; import sys; paths=[Path(r'~/AppData/Local/Temp/tangent-navigation.log'),Path(r'~/AppData/Local/Temp/tangent-cold-start.log')]; bad=('flutter error','unhandled exception','duplicate enqueue','sidecar_sync_pending:'); hits=[(str(p),line) for p in paths for line in p.read_text(errors='replace').splitlines() if any(x in line.lower() for x in bad)]; print(*hits,sep='\n'); sys.exit(bool(hits))"
```

Expected: exit 0 with no matches for Flutter errors, unhandled exceptions, duplicate-enqueue errors, or sidecar persistence failures in either captured scenario log.

- [ ] **Step 9: Record final verification commit if fixes were required**

If verification exposed a defect, reproduce it with a failing automated test before changing production code, rerun all gates, and commit the minimal fix. If no changes were required, do not create an empty commit.
