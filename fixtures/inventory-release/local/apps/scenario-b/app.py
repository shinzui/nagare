"""redis-cache: a tiny stdlib HTTP app that uses the injected REDIS_URL as a cache.

GET /set?k=KEY&v=VALUE  -> stores KEY=VALUE
GET /get?k=KEY          -> returns the stored value (or "(miss)")

REDIS_URL is injected by `nagarectl deploy` as a Kubernetes Secret reference.
redis-py is installed by the Dockerfile.
"""

import os
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

import redis  # installed in the image

r = redis.from_url(os.environ["REDIS_URL"], decode_responses=True)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        if u.path == "/set":
            r.set(q["k"][0], q["v"][0])
            body = b"OK\n"
        elif u.path == "/get":
            body = (str(r.get(q["k"][0]) or "(miss)") + "\n").encode()
        else:
            body = b"redis-cache: /set?k=&v= or /get?k=\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
