#!/usr/bin/env python3
"""Real-HTTP smoke test of the sync API against a locally launched server.

Runs the actual FastAPI app over a real socket with a real SQLite file in a
throwaway directory, then drives the exact two-device flow the tablet and the
phone will perform. Unit tests already cover the handlers; this proves the
wiring -- routing, auth, serialisation -- which is where a deployment breaks.

Never touches the production database: TANGENT_DATA_DIR points at a temp dir.
"""
from __future__ import annotations

import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

SERVER_DIR = r"C:\Users\Jeff\Documents\ADH2\server"


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def call(url: str, token: str | None = None, payload=None, method="GET"):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            body = r.read().decode()
            return r.status, json.loads(body) if body else None
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


def main() -> int:
    port = free_port()
    tmp = tempfile.mkdtemp(prefix="tangent-sync-smoke-")
    env = {
        **os.environ,
        "TANGENT_DATA_DIR": tmp,
        "TANGENT_HOST": "127.0.0.1",
        "TANGENT_PORT": str(port),
    }
    proc = subprocess.Popen(
        [sys.executable, "-m", "uvicorn", "app.main:create_app", "--factory",
         "--host", "127.0.0.1", "--port", str(port), "--log-level", "warning"],
        cwd=SERVER_DIR, env=env,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
    )
    base = f"http://127.0.0.1:{port}"
    failures: list[str] = []
    try:
        # Wait for readiness rather than sleeping blind.
        for _ in range(60):
            if proc.poll() is not None:
                print("SERVER DIED:\n" + (proc.stdout.read() if proc.stdout else ""))
                return 1
            try:
                code, _ = call(f"{base}/openapi.json")
                if code == 200:
                    break
            except Exception:
                pass
            time.sleep(0.5)
        else:
            print("server never became ready")
            return 1

        print(f"server up on {port}")

        code, setup = call(f"{base}/v1/setup", method="POST",
                           payload={"display_name": "smoke-test"})
        if code != 200:
            print(f"setup failed: {code} {setup}")
            return 1
        token = setup["token"]
        print("setup ok, token issued (not printed)")

        # --- the actual two-device flow -------------------------------------
        code, _ = call(f"{base}/v1/devices", token, method="POST", payload={
            "device_id": "dev-tablet", "display_name": "SM-X520", "platform": "android"})
        print(f"register tablet -> {code}")
        if code != 200:
            failures.append(f"tablet registration returned {code}")

        code, _ = call(f"{base}/v1/devices", token, method="POST", payload={
            "device_id": "dev-phone", "display_name": "SM-F971U1", "platform": "android"})
        print(f"register phone  -> {code}")
        if code != 200:
            failures.append(f"phone registration returned {code}")

        code, devices = call(f"{base}/v1/devices", token)
        names = sorted(d["display_name"] for d in devices["devices"])
        print(f"device list     -> {code} {names}")
        if names != ["SM-F971U1", "SM-X520"]:
            failures.append(f"device list wrong: {names}")

        # Tablet pushes a notebook.
        code, pushed = call(f"{base}/v1/sync/push", token, method="POST", payload={
            "device_id": "dev-tablet",
            "changes": [{
                "entity_type": "notebook",
                "entity_id": "nb-1",
                "op": "upsert",
                "payload": {"title": "Bench notes", "updated_at": 1000},
            }],
        })
        print(f"tablet push     -> {code} {pushed}")
        if code != 200:
            failures.append(f"push returned {code}")

        # Phone pulls it.
        code, page = call(f"{base}/v1/sync/pull?device_id=dev-phone&since_seq=0", token)
        got = [(c["entity_id"], (c["payload"] or {}).get("title"))
               for c in page["changes"]]
        print(f"phone pull      -> {code} {got}")
        if got != [("nb-1", "Bench notes")]:
            failures.append(f"phone did not receive the notebook: {got}")

        # The tablet must NOT receive its own change back.
        code, echo = call(f"{base}/v1/sync/pull?device_id=dev-tablet&since_seq=0", token)
        print(f"tablet echo     -> {code} {len(echo['changes'])} changes (want 0)")
        if echo["changes"]:
            failures.append("echo suppression failed: tablet got its own change back")

        # A delete must travel as a tombstone, not a silent disappearance.
        call(f"{base}/v1/sync/push", token, method="POST", payload={
            "device_id": "dev-tablet",
            "changes": [{"entity_type": "notebook", "entity_id": "nb-1",
                         "op": "delete", "payload": None}],
        })
        code, page2 = call(
            f"{base}/v1/sync/pull?device_id=dev-phone&since_seq={page['head_seq']}", token)
        deletes = [(c["entity_id"], c["op"]) for c in page2["changes"]]
        print(f"phone pull del  -> {code} {deletes}")
        if deletes != [("nb-1", "delete")]:
            failures.append(f"tombstone did not propagate: {deletes}")

        # Auth must actually be enforced.
        code, _ = call(f"{base}/v1/sync/pull?device_id=dev-phone&since_seq=0")
        print(f"no-token pull   -> {code} (want 401/403)")
        if code not in (401, 403):
            failures.append(f"unauthenticated pull returned {code}")
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
        shutil.rmtree(tmp, ignore_errors=True)

    print()
    if failures:
        print("FAILURES:")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("ALL SYNC HTTP CHECKS PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
