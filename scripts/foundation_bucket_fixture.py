#!/usr/bin/env python3
"""Loopback SDK bucket metadata for the public foundation CLI fixture."""
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import sys
from urllib.parse import unquote, urlparse

state = Path(sys.argv[1])
endpoint_file = Path(sys.argv[2])

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        route = urlparse(self.path).path
        prefix = '/storage/v1/b/'
        if not route.startswith(prefix) or '/' in route[len(prefix):]:
            self.send_error(404)
            return
        if not (state / 'bucket-created').exists():
            self.send_error(404)
            return
        body = json.dumps({
            'name': unquote(route[len(prefix):]), 'projectNumber': '12345',
            'location': 'US-WEST1',
            'versioning': {'enabled': (state / 'bucket-updated').exists()},
            'iamConfiguration': {'uniformBucketLevelAccess': {'enabled': True},
                                 'publicAccessPrevention': 'enforced'},
        }).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
endpoint_file.write_text(f'http://127.0.0.1:{server.server_port}/storage/v1/')
server.serve_forever()
