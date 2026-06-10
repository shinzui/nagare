#!/usr/bin/env python3
# uploads-volume example app (EP-37).
#
# A tiny dependency-free HTTP server (Python stdlib) that stores uploaded files on
# the durable volume mounted at /uploads. Uploaded files survive a pod restart /
# revision roll because /uploads is a PersistentVolumeClaim.
#
#   POST /upload/<name>   raw request body -> /uploads/<name>
#   GET  /files/<name>    serve /uploads/<name>
#   GET  /                list stored files
#   GET  /healthz         200 ok (Knative readiness)
#
# Knative injects PORT (default 8080); files live under /uploads on the volume.
import os
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UPLOADS = os.environ.get("UPLOADS_DIR", "/uploads")
PORT = int(os.environ.get("PORT", "8080"))
SAFE = re.compile(r"^[A-Za-z0-9._-]+$")  # no path traversal


def safe_path(name):
    if not SAFE.match(name):
        return None
    return os.path.join(UPLOADS, name)


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype="text/plain; charset=utf-8"):
        payload = body if isinstance(body, bytes) else body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_POST(self):
        if self.path.startswith("/upload/"):
            name = self.path[len("/upload/"):]
            dest = safe_path(name)
            if not dest:
                return self._send(400, "bad name\n")
            length = int(self.headers.get("Content-Length", "0"))
            with open(dest, "wb") as f:
                f.write(self.rfile.read(length))
            return self._send(201, f"stored {name} ({length} bytes)\n")
        self._send(404, "not found\n")

    def do_GET(self):
        if self.path == "/healthz":
            return self._send(200, "ok\n")
        if self.path.startswith("/files/"):
            dest = safe_path(self.path[len("/files/"):])
            if dest and os.path.isfile(dest):
                with open(dest, "rb") as f:
                    return self._send(200, f.read(), "application/octet-stream")
            return self._send(404, "no such file\n")
        files = sorted(os.listdir(UPLOADS)) if os.path.isdir(UPLOADS) else []
        body = "uploaded files (durable /uploads volume):\n" + "".join(f"  {n}\n" for n in files)
        self._send(200, body)

    def log_message(self, *_args):
        pass  # quiet


if __name__ == "__main__":
    os.makedirs(UPLOADS, exist_ok=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
