"""Probe the released Nginx golden config without touching a cluster."""

import datetime
import hashlib
import http.client
import json
from pathlib import Path
import subprocess
import tempfile
import time

IMAGE = "nginx:alpine@sha256:df221db836e1754089190208cee7eeda94f233197056426eda74a43ab1abeac2"
config = subprocess.check_output([
    "git", "show", "v0.6.2:cli/nagare-dsl/test/golden/static-site.nginx.conf"
])
report = {"at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
          "release": "v0.6.2", "image": IMAGE,
          "goldenConfigSha256": hashlib.sha256(config).hexdigest()}
with tempfile.TemporaryDirectory(prefix="nagare-static-defaults-", dir=Path.cwd()) as directory:
    root = Path(directory)
    (root / "nginx.conf").write_bytes(config)
    public = root / "public"
    (public / "guide").mkdir(parents=True)
    (public / "guide/index.html").write_text("<!doctype html><h1>Guide</h1>")
    (public / "example.txt").write_text("# Unicode\nAn em dash — and café.\n", encoding="utf-8")
    container = subprocess.check_output([
        "docker", "create", "--pull=never", "--platform=linux/amd64",
        "-p", "127.0.0.1::8080", IMAGE
    ], text=True).strip()
    try:
        subprocess.run(["docker", "cp", str(root / "nginx.conf"), f"{container}:/etc/nginx/conf.d/default.conf"], check=True)
        subprocess.run(["docker", "cp", str(public) + "/.", f"{container}:/usr/share/nginx/html"], check=True)
        subprocess.run(["docker", "start", container], check=True, stdout=subprocess.DEVNULL)
        address = subprocess.check_output(["docker", "port", container, "8080/tcp"], text=True).strip()
        deadline = time.monotonic() + 10
        def request(path):
            connection = http.client.HTTPConnection(address, timeout=2)
            try:
                connection.request("GET", path, headers={"Host": "docs.example.test", "X-Forwarded-Proto": "https"})
                response = connection.getresponse()
                return {"status": response.status, "headers": dict(response.getheaders()),
                        "body": response.read().decode("utf-8")}
            finally:
                connection.close()
        while True:
            try:
                report["directory"] = request("/guide")
                break
            except (OSError, http.client.HTTPException):
                if time.monotonic() >= deadline:
                    raise
                time.sleep(0.1)
        report["markdown"] = request("/example.txt")
    finally:
        subprocess.run(["docker", "rm", "-f", container], check=True, stdout=subprocess.DEVNULL)
print(json.dumps(report, indent=2, ensure_ascii=False))
