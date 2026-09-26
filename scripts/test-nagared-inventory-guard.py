#!/usr/bin/env python3
"""An already running webhook worker must refuse a newly initialized context."""

import hashlib
import hmac
import http.client
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time


def request(port, method, path, body=b"", headers=None):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=2)
    try:
        connection.request(method, path, body, headers or {})
        response = connection.getresponse()
        return response.status, response.read().decode()
    finally:
        connection.close()


def main():
    executable = sys.argv[1]
    with tempfile.TemporaryDirectory(prefix="nagared-inventory-guard-") as root:
        root = Path(root)
        context_dir = root / "config" / "nagare" / "contexts"
        context_dir.mkdir(parents=True)
        (context_dir / "guarded.env").write_text(
            "CLOUDSDK_CORE_PROJECT=project\nNAGARE_MODE=local\n"
        )
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            port = listener.getsockname()[1]
        environment = os.environ.copy()
        environment.pop("CLOUDSDK_CORE_PROJECT", None)
        environment.update(
            XDG_CONFIG_HOME=str(root / "config"),
            XDG_STATE_HOME=str(root / "state"),
            NAGARE_CONTEXT="guarded",
            NAGARE_WEBHOOK_SECRET="topsecret",
        )
        workspace = root / "workspace"
        process = subprocess.Popen(
            [executable, "--port", str(port), "--workspace", str(workspace)],
            env=environment,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        )
        try:
            for _ in range(50):
                if process.poll() is not None:
                    raise AssertionError(process.stderr.read().decode())
                try:
                    if request(port, "GET", "/healthz")[0] == 200:
                        break
                except (OSError, TimeoutError):
                    time.sleep(0.1)
            else:
                raise AssertionError("nagared did not become healthy")

            store_dir = root / "state" / "nagare" / "guarded" / "inventory"
            store_dir.mkdir(parents=True)
            head = {
                "version": 1,
                "generation": 1,
                "sequence": 0,
                "binding": {"identity": "guarded", "project": "project"},
                "clientIdentity": "nagared-inventory-guard-test",
                "accepted": [],
                "converged": [],
                "activeTransaction": None,
                "executorClaim": None,
            }
            head_path = store_dir / "head.json"
            original_head = json.dumps(head, sort_keys=True, separators=(",", ":")).encode()
            head_path.write_bytes(original_head)
            head_path.chmod(0o600)

            body = json.dumps(
                {
                    "ref": "refs/heads/main",
                    "after": "deadbeef",
                    "repository": {
                        "clone_url": "file:///nonexistent/nagared-test.git",
                        "full_name": "fixture/site",
                    },
                },
                separators=(",", ":"),
            ).encode()
            signature = hmac.new(b"topsecret", body, hashlib.sha256).hexdigest()
            status, response = request(
                port,
                "POST",
                "/webhooks/github/static/site",
                body,
                {
                    "X-GitHub-Event": "push",
                    "X-Hub-Signature-256": "sha256=" + signature,
                    "Content-Type": "application/json",
                },
            )
            assert status == 409, (status, response)
            assert "inventory history is initialized" in response, response
            assert head_path.read_bytes() == original_head
            assert not workspace.exists(), "webhook checked out a repository before refusal"
            print("nagared inventory guard: post-start initialization refused before checkout")
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)


if __name__ == "__main__":
    main()
