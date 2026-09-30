"""Loopback GCS JSON/upload fixture for actual nagarectl processes.

The only accepted token is synthetic. No Google endpoint is contacted.
"""
import copy
import email.parser
import email.policy
import http.server
import json
import socket
import threading
import urllib.parse


class StorageFixture:
    def __init__(self):
        self.lock = threading.Lock()
        self.objects = {}
        self.calls = []
        self.race = False
        self.lost_ack = False
        self.head_only = True
        self.denied = False
        self.denied_objects = False
        self.bucket_status = 200
        self.bucket_owner = '12345'
        self.partial_listing = False
        fixture = self

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.1'

            def setup(self):
                super().setup()
                self.connection.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

            def log_message(self, *_):
                pass

            def respond(self, status, value):
                body = value if isinstance(value, bytes) else json.dumps(value).encode()
                self.send_response(status)
                self.send_header('Content-Type', 'application/octet-stream' if isinstance(value, bytes) else 'application/json')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                self.dispatch()

            def do_POST(self):
                self.dispatch()

            def dispatch(self):
                parsed = urllib.parse.urlsplit(self.path)
                query = {k: v[0] for k, v in urllib.parse.parse_qs(parsed.query).items()}
                data = self.rfile.read(int(self.headers.get('Content-Length', 0)))
                with fixture.lock:
                    fixture.calls.append(dict(method=self.command, path=parsed.path, query=query))
                    if self.headers.get('Authorization') != 'Bearer fixture-token' or query.get('userProject') != 'project' or fixture.denied:
                        return self.respond(403, {})
                    if self.command == 'GET' and parsed.path == '/storage/v1/b/audit.invalid':
                        return self.respond(fixture.bucket_status, {
                            'name': 'audit.invalid', 'projectNumber': fixture.bucket_owner,
                            'location': 'US-WEST1'})
                    if fixture.denied_objects:
                        return self.respond(403, {})
                    prefix = '/storage/v1/b/audit.invalid/o'
                    if self.command == 'GET' and parsed.path == prefix:
                        requested = query.get('prefix', '')
                        entries = [(k, v) for k, v in sorted(fixture.objects.items()) if k.removeprefix('gs://audit.invalid/').startswith(requested)]
                        offset = int(query.get('pageToken', 0))
                        limit = min(100, int(query.get('maxResults', 100)))
                        page = entries[offset:offset + limit]
                        result = {'items': [metadata(k, v) for k, v in page]}
                        if offset + limit < len(entries) or fixture.partial_listing:
                            result['nextPageToken'] = str(offset + limit)
                        if fixture.race and requested == 'private/journal/':
                            fixture.objects['gs://audit.invalid/private/head.json']['generation'] += 1
                            fixture.race = False
                        return self.respond(200, result)
                    if self.command == 'GET' and parsed.path.startswith(prefix + '/'):
                        name = urllib.parse.unquote(parsed.path[len(prefix) + 1:])
                        key = 'gs://audit.invalid/' + name
                        value = fixture.objects.get(key)
                        if value is None:
                            return self.respond(404, {})
                        if query.get('alt') == 'media':
                            if query.get('generation') != str(value['generation']):
                                return self.respond(412, {})
                            return self.respond(200, value['bytes'].encode())
                        return self.respond(200, metadata(key, value))
                    if self.command == 'POST' and parsed.path == '/upload/storage/v1/b/audit.invalid/o':
                        name = query.get('name', '')
                        if not name.startswith('private/') or fixture.head_only and name != 'private/head.json':
                            return self.respond(403, {})
                        key = 'gs://audit.invalid/' + name
                        current = fixture.objects.get(key, {}).get('generation', 0)
                        if query.get('ifGenerationMatch') != str(current):
                            return self.respond(412, {})
                        message = email.parser.BytesParser(policy=email.policy.default).parsebytes(
                            ('Content-Type: ' + self.headers['Content-Type'] + '\r\n\r\n').encode() + data)
                        parts = list(message.iter_parts())
                        if len(parts) != 2:
                            return self.respond(400, {})
                        value = {'generation': current + 1, 'bytes': parts[1].get_payload(decode=True).decode()}
                        fixture.objects[key] = value
                        return self.respond(500, {}) if fixture.lost_ack else self.respond(200, metadata(key, value))
                    return self.respond(400, {})

        def metadata(key, value):
            return {'bucket': 'audit.invalid', 'name': key.removeprefix('gs://audit.invalid/'),
                    'generation': str(value['generation']), 'size': str(len(value['bytes'].encode()))}

        self.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.endpoint = f'http://127.0.0.1:{self.server.server_port}/storage/v1/'

    def reset(self, objects, *, race=False, lost_ack=False, head_only=True, denied=False):
        with self.lock:
            self.objects = copy.deepcopy(objects)
            self.calls = []
            self.race, self.lost_ack, self.head_only, self.denied = race, lost_ack, head_only, denied

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)


# Embedded in the existing process recorder, which already imports json/os/sys.
GCLOUD_HELPER = '''
if args[:2] == ['config', 'config-helper']:
    print(json.dumps({'credential': {'access_token': 'fixture-token', 'token_expiry': '2099-01-01T00:00:00Z'},
        'configuration': {'active_configuration': os.environ.get('CLOUDSDK_ACTIVE_CONFIG_NAME', 'fixture-config'), 'properties': {'core': {'account': os.environ.get('CLOUDSDK_CORE_ACCOUNT', 'fixture@example.invalid'), 'project': 'project'},
            'auth': {key: os.environ.get('CLOUDSDK_AUTH_' + key.upper(), '') for key in ['impersonate_service_account', 'credential_file_override', 'access_token_file', 'access_token']},
            'api_endpoint_overrides': {'storage': os.environ.get('CLOUDSDK_API_ENDPOINT_OVERRIDES_STORAGE', '')}}}}))
    sys.exit(0)
'''
