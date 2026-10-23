#!/usr/bin/env python3
"""Exercise the actual app twice with a disposable profile and a local MV3 extension."""
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json
import os
import re
import shutil
import signal
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parent
NAME = "Vane Chromium Prototype"
EXECUTABLE = ROOT / ".build" / (NAME + ".app") / "Contents/MacOS" / NAME
LEDGER = ROOT / ".build/test-launches.jsonl"


def process_snapshot():
    result = subprocess.run(["ps", "-axo", "pid=,lstart=,command="], capture_output=True, text=True, check=True)
    rows = {}
    for line in result.stdout.splitlines():
        parts = line.split(None, 6)
        if len(parts) == 7:
            rows[int(parts[0])] = {"pid": int(parts[0]), "started": " ".join(parts[1:6]), "command": parts[6]}
    return rows


def owned_processes(profile, parent_pid):
    root = str(EXECUTABLE.parents[2])
    paths = {str(Path(profile)), str(Path(profile).resolve())}
    return [row for row in process_snapshot().values()
            if row["command"].startswith(root + "/Contents/")
            and (row["pid"] == parent_pid or any(path in row["command"] for path in paths))]


def stop_tracked(rows):
    # Revalidate executable, launch time and full arguments before every signal.
    for sig in (signal.SIGTERM, signal.SIGKILL):
        current = process_snapshot()
        live = [row for row in rows if current.get(row["pid"]) == row]
        if not live:
            return
        for row in live:
            try:
                os.kill(row["pid"], sig)
            except ProcessLookupError:
                pass
        time.sleep(0.5)
    current = process_snapshot()
    if any(current.get(row["pid"]) == row for row in rows):
        raise RuntimeError("A tracked Chromium test process did not exit")


def run_app(command, profile):
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    record = process_snapshot().get(process.pid)
    with LEDGER.open("a") as ledger:
        ledger.write(json.dumps({"bundle": str(EXECUTABLE.parents[2]), "profile": profile, **(record or {})}) + "\n")
    try:
        stdout, stderr = process.communicate(timeout=50)
        return subprocess.CompletedProcess(command, process.returncode, stdout, stderr)
    except subprocess.TimeoutExpired as error:
        print((error.stdout or b"").decode() if isinstance(error.stdout, bytes) else error.stdout)
        print((error.stderr or b"").decode() if isinstance(error.stderr, bytes) else error.stderr)
        raise RuntimeError("Chromium test did not finish and shut down within 50 seconds") from error
    finally:
        tracked = owned_processes(profile, process.pid)
        if record and process.poll() is None and record not in tracked:
            tracked.append(record)
        if tracked:
            with LEDGER.open("a") as ledger:
                ledger.write(json.dumps({"cleanup": tracked}) + "\n")
            stop_tracked(tracked)
        process.wait(timeout=5)


class QuietHandler(SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


def main():
    handler = partial(QuietHandler, directory=str(ROOT / "fixtures"))
    with ThreadingHTTPServer(("127.0.0.1", 0), handler) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with tempfile.TemporaryDirectory(prefix="vane-chromium-smoke-") as profile:
                for visit in (1, 2):
                    command = [str(EXECUTABLE), "--vane-smoke", f"--vane-profile={profile}",
                        f"--url=http://127.0.0.1:{server.server_port}/smoke.html?visit={visit}",
                        f"--load-extension={ROOT / 'fixtures/extension'}"]
                    result = run_app(command, profile)
                    expected = f"VANE_SMOKE_PASS:visit={visit},extension={visit}"
                    style = re.search(r"Runtime style=(\d+) \(Chrome=(\d+)\)", result.stdout)
                    if result.returncode != 0 or expected not in result.stdout or not style or style[1] != style[2]:
                        log = Path(profile) / "chromium.log"
                        if log.exists():
                            shutil.copy2(log, ROOT / ".build/smoke-failure-chromium.log")
                        print(result.stdout)
                        print(result.stderr)
                        raise SystemExit(f"FAIL: real Chromium smoke launch {visit} (exit {result.returncode})")
                    print(expected)
        finally:
            server.shutdown()
    print("PASS: native app shutdown, Chromium rendering, MV3 content scripts/service worker/messaging,")
    print("      page storage and extension storage persisted across two launches in an isolated profile.")


if __name__ == "__main__":
    main()
