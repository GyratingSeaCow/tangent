#!/usr/bin/env python
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Real-socket proof that a recording made on one device reaches another.

The unit tests use a TestClient; this runs an actual uvicorn process and
speaks HTTP to it, which is the only way to catch route wiring, header
plumbing and streaming-response bugs that a TestClient papers over.

Mirrors Jeff's two devices: dev-tablet creates a recording and uploads its
audio, dev-phone pulls it and downloads the bytes back.

Run:  python tests/smoke_dump_sync_http.py
"""
from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path

AUDIO = b"OggS" + bytes(range(256)) * 40  # ~10 KB, recognisable prefix


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return int(s.getsockname()[1])


def call(url, token=None, payload=None, method="GET", device=None, raw=False):
    data = None
    req = urllib.request.Request(url, method=method)
    if payload is not None:
        data = json.dumps(payload).encode()
        req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    if device:
        req.add_header("X-Device-Id", device)
    try:
        with urllib.request.urlopen(req, data=data, timeout=30) as r:
            body = r.read()
            if raw:
                return r.status, body
            return r.status, json.loads(body) if body else None
    except urllib.error.HTTPError as e:
        body = e.read()
        if raw:
            return e.code, body
        try:
            return e.code, json.loads(body) if body else None
        except Exception:
            return e.code, body


def upload(url, token, device, blob):
    boundary = "----tangent" + uuid.uuid4().hex
    body = (
        f"--{boundary}\r\n"
        'Content-Disposition: form-data; name="audio"; filename="a.opus"\r\n'
        "Content-Type: audio/ogg\r\n\r\n"
    ).encode() + blob + f"\r\n--{boundary}--\r\n".encode()
    req = urllib.request.Request(url, method="POST", data=body)
    req.add_header("Content-Type", f"multipart/form-data; boundary={boundary}")
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("X-Device-Id", device)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status
    except urllib.error.HTTPError as e:
        print("upload error body:", e.read()[:300])
        return e.code


def main() -> int:
    port = free_port()
    base = f"http://127.0.0.1:{port}"
    tmp = tempfile.mkdtemp(prefix="tangent-dumpsmoke-")
    env = dict(os.environ, TANGENT_DATA_DIR=tmp, TANGENT_MODEL_SIZE="tiny")
    proc = subprocess.Popen(
        [sys.executable, "-m", "uvicorn", "app.main:create_app", "--factory",
         "--host", "127.0.0.1", "--port", str(port), "--log-level", "warning"],
        env=env, cwd=str(Path(__file__).resolve().parents[1]),
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
    )
    failures = []
    try:
        for _ in range(120):
            if proc.poll() is not None:
                print("server died:\n", proc.stdout.read()[-2000:])
                return 1
            try:
                code, _ = call(f"{base}/openapi.json")
                if code == 200:
                    break
            except Exception:
                pass
            time.sleep(0.5)
        else:
            print("server never became healthy")
            return 1
        print(f"server up on {port}")

        code, setup = call(f"{base}/v1/setup", method="POST",
                           payload={"display_name": "smoke"})
        if code != 200:
            print(f"setup failed: {code} {setup}")
            return 1
        token = setup["token"]
        print("setup ok, token issued (not printed)")

        for dev, name in (("dev-tablet", "Tablet"), ("dev-phone", "Fold")):
            call(f"{base}/v1/devices", token, method="POST", payload={
                "device_id": dev, "display_name": name, "platform": "android"})

        dump_id = "smoke-" + uuid.uuid4().hex[:12]
        now = int(time.time())

        # --- the tablet records something -------------------------------
        code, created = call(f"{base}/v1/dumps", token, method="POST",
                             device="dev-tablet", payload={
                                 "id": dump_id, "mode": "brain_dump",
                                 "title": "Smoke recording",
                                 "duration_seconds": 9,
                                 "created_at": now, "updated_at": now})
        print(f"create dump      -> {code}")
        if code not in (200, 201):
            failures.append(f"create returned {code}: {created}")

        code = upload(f"{base}/v1/dumps/{dump_id}/audio", token, "dev-tablet", AUDIO)
        print(f"upload audio     -> {code}")
        if code not in (200, 204):
            failures.append(f"upload returned {code}")

        # --- the phone learns about it ----------------------------------
        code, page = call(
            f"{base}/v1/sync/pull?device_id=dev-phone&since_seq=0", token)
        dumps = [c for c in (page or {}).get("changes", [])
                 if c["entity_type"] == "dump" and c["entity_id"] == dump_id]
        print(f"phone pull       -> {code}, dump changes: {len(dumps)}")
        if not dumps:
            failures.append("THE DEFECT: recording never reached the phone's pull")
        else:
            payload = dumps[-1]["payload"]
            if payload.get("title") != "Smoke recording":
                failures.append(f"title did not travel: {payload.get('title')}")
            if not payload.get("audio_kept"):
                failures.append(
                    "audio_kept false after a successful upload -> the phone "
                    "would never offer a download")
            print(f"  title={payload.get('title')!r} "
                  f"audio_kept={payload.get('audio_kept')}")

        # --- the tablet does not receive its own change -----------------
        code, echo = call(
            f"{base}/v1/sync/pull?device_id=dev-tablet&since_seq=0", token)
        mine = [c for c in (echo or {}).get("changes", [])
                if c["entity_id"] == dump_id]
        print(f"tablet echo      -> {len(mine)} (want 0)")
        if mine:
            failures.append("device received an echo of its own change")

        # --- the phone downloads the audio ------------------------------
        code, blob = call(f"{base}/v1/dumps/{dump_id}/audio", token, raw=True)
        print(f"download audio   -> {code}, {len(blob) if blob else 0} bytes")
        if code != 200:
            failures.append(f"audio download returned {code}")
        elif blob != AUDIO:
            failures.append(
                f"audio bytes differ: sent {len(AUDIO)}, got {len(blob)}")
        else:
            print("  bytes match exactly")

        # --- the phone edits the transcript, tablet sees it -------------
        later = now + 60
        code, res = call(f"{base}/v1/sync/push", token, method="POST", payload={
            "device_id": "dev-phone",
            "changes": [{
                "entity_type": "dump", "entity_id": dump_id, "op": "upsert",
                "payload": {"mode": "brain_dump", "title": "Smoke recording",
                            "transcript": "typed on the phone",
                            "meeting_notes": "notes from the phone",
                            "duration_seconds": 9,
                            "created_at": now, "updated_at": later},
                "updated_at": later}]})
        applied = [r for r in (res or {}).get("results", [])
                   if r.get("status") == "applied"]
        print(f"phone push edit  -> {code}, applied: {len(applied)}")
        if not applied:
            failures.append(f"phone edit was not applied: {res}")

        code, page2 = call(
            f"{base}/v1/sync/pull?device_id=dev-tablet&since_seq=0", token)
        back = [c for c in (page2 or {}).get("changes", [])
                if c["entity_id"] == dump_id]
        if not back:
            failures.append("tablet never saw the phone's transcript edit")
        else:
            p = back[-1]["payload"]
            print(f"  transcript={p.get('transcript')!r} "
                  f"notes={p.get('meeting_notes')!r} "
                  f"audio_kept={p.get('audio_kept')}")
            if p.get("transcript") != "typed on the phone":
                failures.append("transcript did not travel back")
            if p.get("meeting_notes") != "notes from the phone":
                failures.append("meeting notes did not travel back")
            # The phone never held the audio; its push must not have told the
            # server to forget it.
            if not p.get("audio_kept"):
                failures.append(
                    "a metadata push from the device WITHOUT the audio cleared "
                    "audio_kept -> the recording becomes undownloadable")

        # audio still downloadable after that edit
        code, blob2 = call(f"{base}/v1/dumps/{dump_id}/audio", token, raw=True)
        print(f"re-download      -> {code}, {len(blob2) if blob2 else 0} bytes")
        if code != 200 or blob2 != AUDIO:
            failures.append("audio no longer downloadable after a metadata push")

        # --- deletion propagates ----------------------------------------
        code, _ = call(f"{base}/v1/dumps/{dump_id}", token, method="DELETE",
                       device="dev-tablet")
        print(f"delete dump      -> {code}")
        code, page3 = call(
            f"{base}/v1/sync/pull?device_id=dev-phone&since_seq=0", token)
        dels = [c for c in (page3 or {}).get("changes", [])
                if c["entity_id"] == dump_id and c["op"] == "delete"]
        print(f"phone sees delete-> {len(dels)}")
        if not dels:
            failures.append("deletion never reached the other device")

    finally:
        proc.terminate()
        try:
            proc.wait(timeout=15)
        except subprocess.TimeoutExpired:
            proc.kill()

    print()
    if failures:
        print(f"FAILED ({len(failures)}):")
        for f in failures:
            print("  -", f)
        return 1
    print("ALL RECORDING SYNC CHECKS PASSED over real HTTP")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
