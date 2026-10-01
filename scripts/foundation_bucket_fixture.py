#!/usr/bin/env python3
"""Loopback SDK bucket metadata for the public foundation CLI fixture."""
import json
import email.parser
import email.policy
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import sys
import threading
from urllib.parse import unquote, urlparse, parse_qs

state = Path(sys.argv[1])
endpoint_file = Path(sys.argv[2])
objects = {}
lock = threading.Lock()

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        self.dispatch()

    def do_POST(self):
        self.dispatch()

    def respond(self, status, value):
        body = value if isinstance(value, bytes) else json.dumps(value).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/octet-stream' if isinstance(value, bytes) else 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def dispatch(self):
        parsed = urlparse(self.path)
        route = parsed.path
        query = {k: v[0] for k, v in parse_qs(parsed.query).items()}
        data = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        if '/o' in route:
            with lock:
                return self.object_request(route, query, data)
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

    def object_request(self, route, query, data):
        # The same production SDK exercises empty-prefix discovery and migration.
        # Persist a trace and exact generations for assertions in the shell fixture.
        with (state / 'object-calls.jsonl').open('a') as trace:
            trace.write(json.dumps({'method': self.command, 'path': route, 'query': query}) + '\n')
        if not (state / 'bucket-created').exists():
            return self.respond(404, {})
        if self.headers.get('Authorization') != 'Bearer fixture-token' or query.get('userProject') != 'fixture-project':
            return self.respond(403, {})
        prefix = '/storage/v1/b/'
        upload = '/upload/storage/v1/b/'
        base = upload if route.startswith(upload) else prefix
        bucket, _, resource = route[len(base):].partition('/o')
        def metadata(name, value):
            return {'bucket': bucket, 'name': name, 'generation': str(value['generation']),
                    'size': str(len(value['bytes']))}
        if self.command == 'GET' and resource == '':
            return self.respond(200, {'items': [metadata(name, value)
                for (owner, name), value in sorted(objects.items())
                if owner == bucket and name.startswith(query.get('prefix', ''))]})
        name = unquote(resource.removeprefix('/')) if self.command == 'GET' else query.get('name', '')
        key = (bucket, name)
        value = objects.get(key)
        if self.command == 'GET':
            if value is None:
                return self.respond(404, {})
            if query.get('alt') == 'media':
                if query.get('generation') != str(value['generation']):
                    return self.respond(412, {})
                return self.respond(200, value['bytes'])
            return self.respond(200, metadata(name, value))
        if self.command == 'POST' and base == upload:
            generation = value['generation'] if value else 0
            if query.get('ifGenerationMatch') != str(generation):
                return self.respond(412, {})
            message = email.parser.BytesParser(policy=email.policy.default).parsebytes(
                ('Content-Type: ' + self.headers['Content-Type'] + '\r\n\r\n').encode() + data)
            parts = list(message.iter_parts())
            if len(parts) != 2:
                return self.respond(400, {})
            value = {'generation': generation + 1, 'bytes': parts[1].get_payload(decode=True)}
            objects[key] = value
            (state / 'remote-objects.json').write_text(json.dumps({
                owner + '/' + name: {'generation': item['generation'], 'bytes': item['bytes'].decode()}
                for (owner, name), item in objects.items()}))
            return self.respond(200, metadata(name, value))
        return self.respond(400, {})

server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
endpoint_file.write_text(f'http://127.0.0.1:{server.server_port}/storage/v1/')
server.serve_forever()
