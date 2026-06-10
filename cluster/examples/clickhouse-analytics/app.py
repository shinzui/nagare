"""clickhouse-analytics: a tiny stdlib HTTP app that writes/queries events.

GET /track  -> inserts one event row
GET /count  -> returns the event count

Uses the injected CLICKHOUSE_HOST/CLICKHOUSE_PORT (native 9000), CLICKHOUSE_USER
(literals) and CLICKHOUSE_PASSWORD (a Secret reference). clickhouse-driver is
installed by the Dockerfile.
"""

import os
from http.server import BaseHTTPRequestHandler, HTTPServer

from clickhouse_driver import Client  # installed in the image

client = Client(
    host=os.environ["CLICKHOUSE_HOST"],
    port=int(os.environ.get("CLICKHOUSE_PORT", "9000")),
    user=os.environ.get("CLICKHOUSE_USER", "nagare"),
    password=os.environ["CLICKHOUSE_PASSWORD"],
)
client.execute(
    "CREATE TABLE IF NOT EXISTS events (at DateTime DEFAULT now()) ENGINE = MergeTree ORDER BY at"
)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/track"):
            client.execute("INSERT INTO events (at) VALUES", [{}])
        n = client.execute("SELECT count(*) FROM events")[0][0]
        body = f"events: {n}\n".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
