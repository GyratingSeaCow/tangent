# SPDX-License-Identifier: AGPL-3.0-or-later
"""The change log: one authority, one monotonic sequence.

Every accepted mutation appends exactly one row here and is stamped with the
next `seq`. A client remembers the highest `seq` it has seen and asks "what
changed after N?".

This is a CHECKPOINT, not a clock. It is assigned by a single authority, so
device clock skew is irrelevant by design — which is the whole reason
last-write-wins on `updated_at` was rejected: at whole-notebook granularity it
silently destroys a page of handwriting when another device saves a title edit
a second later.
"""

from __future__ import annotations

import json
import sqlite3
import time
from typing import Any, Literal

EntityType = Literal["dump", "notebook", "note"]
Op = Literal["upsert", "delete"]

#: Entity types the log accepts. Kept beside the DB CHECK constraint so a new
#: kind fails loudly here rather than as an opaque IntegrityError.
ENTITY_TYPES: frozenset[str] = frozenset({"dump", "notebook", "note"})


def record_change(
    conn: sqlite3.Connection,
    *,
    entity_type: EntityType,
    entity_id: str,
    op: Op,
    device_id: str,
    payload: dict[str, Any] | None = None,
    now: int | None = None,
) -> int:
    """Append one change and return its assigned ``seq``.

    ``payload`` is the full entity for an upsert and is ignored for a delete —
    a tombstone carries no body, and writing one would let a client resurrect
    content by replaying it.
    """
    if entity_type not in ENTITY_TYPES:
        raise ValueError(f"unknown entity_type: {entity_type!r}")
    if op not in ("upsert", "delete"):
        raise ValueError(f"unknown op: {op!r}")
    if not device_id:
        # Without an author the client cannot suppress the echo of its own
        # push, and would immediately re-apply everything it just sent.
        raise ValueError("device_id is required")

    encoded = json.dumps(payload) if (op == "upsert" and payload is not None) else None
    cursor = conn.execute(
        "INSERT INTO change_log "
        "(entity_type, entity_id, op, device_id, payload, created_at) "
        "VALUES (?, ?, ?, ?, ?, ?)",
        (
            entity_type,
            entity_id,
            op,
            device_id,
            encoded,
            now if now is not None else int(time.time()),
        ),
    )
    return int(cursor.lastrowid)


def head_seq(conn: sqlite3.Connection) -> int:
    """Highest assigned sequence, or 0 when nothing has ever been recorded."""
    row = conn.execute("SELECT MAX(seq) AS head FROM change_log").fetchone()
    head = row["head"] if isinstance(row, sqlite3.Row) else (row[0] if row else None)
    return int(head) if head is not None else 0


def changes_since(
    conn: sqlite3.Connection,
    *,
    since_seq: int,
    limit: int = 500,
    exclude_device_id: str | None = None,
) -> list[dict[str, Any]]:
    """Changes with ``seq`` strictly greater than ``since_seq``, in order.

    Ordering is what makes the checkpoint safe to advance: a client that
    applies these in sequence and stores the last ``seq`` can resume exactly
    where it stopped, even if it dies halfway through.

    ``exclude_device_id`` drops the caller's own echoes server-side. The client
    also filters, but doing it here keeps a chatty device from paying to
    download everything it just uploaded.
    """
    sql = "SELECT seq, entity_type, entity_id, op, device_id, payload " \
          "FROM change_log WHERE seq > ?"
    args: list[Any] = [since_seq]
    if exclude_device_id:
        sql += " AND device_id != ?"
        args.append(exclude_device_id)
    sql += " ORDER BY seq ASC LIMIT ?"
    args.append(limit)

    out: list[dict[str, Any]] = []
    for row in conn.execute(sql, args):
        out.append(
            {
                "seq": row["seq"],
                "entity_type": row["entity_type"],
                "entity_id": row["entity_id"],
                "op": row["op"],
                "device_id": row["device_id"],
                "payload": json.loads(row["payload"]) if row["payload"] else None,
            }
        )
    return out
