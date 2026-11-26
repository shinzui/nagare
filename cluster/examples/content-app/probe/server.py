"""content-app probe (MasterPlan 39): one image for both workloads of the example.

  /              the request's Host header, as traefik/whoami prints it
  /health        200
  /keyset        the files of NAGARE_KEYSET_VIEW_GRANTS_DIR
  /put-and-sign  write staging/probe-<time>.txt, then return a V4 signed PUT URL for another object
  /try-put       read the newest staging/ object, then try a write; report both statuses

The bucket is reached with Google's storage client unchanged: GOOGLE_APPLICATION_CREDENTIALS names
the workload's external_account configuration, and NAGARE_BUCKET_PUBLICATIONS_SERVICE_ACCOUNT the
account that signs. No key is read from anywhere.
"""

import datetime
import os
import socket
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import google.auth
import google.auth.transport.requests
from google.api_core import exceptions
from google.cloud import storage

BUCKET = os.environ.get("NAGARE_BUCKET_PUBLICATIONS_NAME", "")
ACCOUNT = os.environ.get("NAGARE_BUCKET_PUBLICATIONS_SERVICE_ACCOUNT", "")
KEYSET = os.environ.get("NAGARE_KEYSET_VIEW_GRANTS_DIR", "")
PORT = int(os.environ.get("PORT", os.environ.get("WHOAMI_PORT_NUMBER", "8080")))


def client():
    # cloud-platform: signing calls IAM signBlob, which a storage-only scope refuses.
    credentials, _ = google.auth.default(scopes=["https://www.googleapis.com/auth/cloud-platform"])
    project = ACCOUNT.split("@", 1)[1].split(".", 1)[0] if "@" in ACCOUNT else None
    return storage.Client(project=project, credentials=credentials), credentials


def put_and_sign():
    c, credentials = client()
    bucket = c.bucket(BUCKET)
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S")
    name = f"staging/probe-{stamp}.txt"
    bucket.blob(name).upload_from_string(f"written by {socket.gethostname()}\n")
    credentials.refresh(google.auth.transport.requests.Request())
    url = bucket.blob(f"staging/signed-{stamp}.txt").generate_signed_url(
        version="v4",
        method="PUT",
        expiration=datetime.timedelta(minutes=15),
        service_account_email=ACCOUNT,
        access_token=credentials.token,
    )
    return f"wrote gs://{BUCKET}/{name}\nsigned url {url}\n"


def try_put():
    c, _ = client()
    bucket = c.bucket(BUCKET)
    try:
        newest = max(c.list_blobs(bucket, prefix="staging/"), key=lambda blob: blob.updated, default=None)
        get = "ok" if newest is not None and newest.download_as_bytes() is not None else "empty"
    except exceptions.GoogleAPICallError as error:
        get = str(error.code)
    try:
        bucket.blob("staging/gateway-attempt.txt").upload_from_string("should be refused\n")
        put = "200"
    except exceptions.GoogleAPICallError as error:
        put = str(error.code)
    return f"{socket.gethostname()}: get {get}, put {put}\n"


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?", 1)[0]
        try:
            if path == "/health":
                body = "ok\n"
            elif path == "/keyset":
                body = "".join(f"{entry}\n" for entry in sorted(os.listdir(KEYSET))) if KEYSET else "no key set\n"
            elif path == "/put-and-sign":
                body = put_and_sign()
            elif path == "/try-put":
                body = try_put()
            else:
                body = f"Hostname: {socket.gethostname()}\nHost: {self.headers.get('Host', '')}\n"
            status = 200
        except Exception as error:  # the probe reports, it does not hide
            body, status = f"error: {type(error).__name__}: {error}\n", 500
        data = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *_):
        pass


ThreadingHTTPServer(("", PORT), Handler).serve_forever()
