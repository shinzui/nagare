"""workload-controls web role: independent startup, readiness and liveness (EP-256 M2).

GET /started  -> 200 once the process serves (startup check)
GET /healthz  -> 200 while the process runs; never reads the database (liveness)
GET /ready    -> 200 when the database answers, 503 when it does not (readiness)
GET /         -> 200 with the recorded migration runs

DATABASE_URL is injected by the managed database binding as a Secret reference.
The process exits when it is told to stop; only the worker drains.
"""

import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import psycopg

DSN = os.environ["DATABASE_URL"]
PORT = int(os.environ.get("PORT", "8080"))


def database_answers():
    try:
        with psycopg.connect(DSN, connect_timeout=2) as conn:
            conn.execute("SELECT 1")
        return True
    except psycopg.Error:
        return False


def migration_runs():
    with psycopg.connect(DSN, connect_timeout=2) as conn:
        return conn.execute("SELECT count(*) FROM migration_runs").fetchone()[0]


class Handler(BaseHTTPRequestHandler):
    def respond(self, status, text):
        body = text.encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/started" or self.path == "/healthz":
            self.respond(200, "ok\n")
        elif self.path == "/ready":
            if database_answers():
                self.respond(200, "ready\n")
            else:
                self.respond(503, "database unavailable\n")
        elif self.path == "/":
            try:
                self.respond(200, f"migration runs: {migration_runs()}\n")
            except psycopg.Error:
                self.respond(503, "database unavailable\n")
        else:
            self.respond(404, "not found\n")

    def log_message(self, fmt, *args):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
