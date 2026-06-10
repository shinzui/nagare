#!/usr/bin/env python3
# sqlite-pvc-litestream example app (EP-37).
#
# A tiny dependency-free HTTP server (Python stdlib) that keeps a SQLite database
# on the durable volume mounted at /data. It proves the point of the example:
# data written here survives a pod restart / revision roll because /data is a
# PersistentVolumeClaim, not the ephemeral container filesystem.
#
#   GET /          -> the current row count (and a hint)
#   GET /add       -> insert a timestamped row, then return the new count
#   GET /healthz   -> 200 ok (Knative readiness)
#
# Knative injects PORT (default 8080); the DB path is /data/app.db on the volume.
import os
import sqlite3
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DB = os.environ.get("DB_PATH", "/data/app.db")
PORT = int(os.environ.get("PORT", "8080"))


def db():
    conn = sqlite3.connect(DB)
    conn.execute("CREATE TABLE IF NOT EXISTS notes(id INTEGER PRIMARY KEY, body TEXT)")
    return conn


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body):
        payload = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        if self.path == "/healthz":
            return self._send(200, "ok\n")
        conn = db()
        try:
            if self.path == "/add":
                conn.execute(
                    "INSERT INTO notes(body) VALUES (?)",
                    (f"persisted at {datetime.now(timezone.utc).isoformat()}",),
                )
                conn.commit()
            (count,) = conn.execute("SELECT count(*) FROM notes").fetchone()
        finally:
            conn.close()
        self._send(200, f"notes rows: {count}\n(GET /add to insert one; data is on the durable /data volume)\n")

    def log_message(self, *_args):
        pass  # quiet


if __name__ == "__main__":
    os.makedirs(os.path.dirname(DB), exist_ok=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
