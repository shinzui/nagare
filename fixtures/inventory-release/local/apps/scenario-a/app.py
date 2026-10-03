"""postgres-app: a tiny stdlib HTTP app that uses the injected DATABASE_URL.

GET /add  -> inserts a timestamped row, returns the new row count
GET /     -> returns the current row count

DATABASE_URL is injected by `nagarectl deploy` as a Kubernetes Secret reference
(it never appears in the image or the config). psycopg is installed by the
Dockerfile; everything else is the Python standard library.
"""

import os
from http.server import BaseHTTPRequestHandler, HTTPServer

import psycopg  # installed in the image

DSN = os.environ["DATABASE_URL"]


def with_conn(fn):
    with psycopg.connect(DSN, autocommit=True) as conn:
        conn.execute(
            "CREATE TABLE IF NOT EXISTS hits (id bigserial primary key, at timestamptz default now())"
        )
        return fn(conn)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/add"):
            with_conn(lambda c: c.execute("INSERT INTO hits DEFAULT VALUES"))
        n = with_conn(lambda c: c.execute("SELECT count(*) FROM hits").fetchone()[0])
        body = f"rows: {n}\n".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
