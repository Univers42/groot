#!/usr/bin/env python3
"""dev-rebuild-server — tiny localhost daemon that lets the osionos "Update" button
rebuild the Docker stack. A browser button is sandboxed and cannot run host commands,
so this host-side helper is the bridge: POST /rebuild runs `make all` (override with
REBUILD_CMD) at the repo root and returns the result; GET /health reports status.

Run it once in a terminal:   python3 scripts/dev-rebuild-server.py   (or: make rebuild-server)
Then the Update button in osionos triggers a rebuild; without it, Update just refreshes.
Bound to 127.0.0.1 only (loopback, dev-only). Python 3 stdlib only (the host has no node).

  REBUILD_PORT  default 7799
  REBUILD_CMD   default "make all"  (e.g. 'COMPOSE_PROFILES=dev docker compose up -d --build osionos-app osionos-bridge' for a faster targeted rebuild)
"""
import json
import os
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

PORT = int(os.environ.get("REBUILD_PORT", "7799"))
REPO_ROOT = Path(__file__).resolve().parent.parent
CMD = os.environ.get("REBUILD_CMD", "make all")

_lock = threading.Lock()
_running = False


def _run_rebuild():
    """Run CMD at the repo root, streaming output live to this terminal; return (code, tail)."""
    proc = subprocess.Popen(
        ["bash", "-lc", CMD], cwd=str(REPO_ROOT),
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1,
    )
    tail = []
    for line in proc.stdout:
        print(line, end="", flush=True)
        tail.append(line)
        if len(tail) > 400:
            tail = tail[-400:]
    proc.wait()
    return proc.returncode, "".join(tail)


class Handler(BaseHTTPRequestHandler):
    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET,POST,OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")

    def _json(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self._cors()
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors()
        self.end_headers()

    def do_GET(self):
        if self.path == "/health":
            return self._json(200, {"ok": True, "running": _running, "cmd": CMD})
        self._json(404, {"ok": False, "message": "Not found"})

    def do_POST(self):
        global _running
        if self.path != "/rebuild":
            return self._json(404, {"ok": False, "message": "Not found"})
        with _lock:
            if _running:
                return self._json(409, {"ok": False, "running": True, "message": "A rebuild is already in progress."})
            _running = True
        try:
            print(f"\n[rebuild] $ {CMD}", flush=True)
            code, tail = _run_rebuild()
            print(f"[rebuild] exit {code}", flush=True)
            self._json(200, {"ok": code == 0, "code": code, "tail": tail[-4000:]})
        finally:
            _running = False

    def log_message(self, *_args):
        pass  # keep the terminal focused on rebuild output, not request logs


if __name__ == "__main__":
    httpd = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print(f"[rebuild] listening on http://127.0.0.1:{PORT}  (cmd: {CMD})", flush=True)
    print("[rebuild] the osionos Update button now triggers a rebuild. Ctrl-C to stop.", flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n[rebuild] stopped.", flush=True)
