"""Execute the rendered ingestion shell against a strict disposable GCS double."""

import hashlib
import hmac
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


script = sys.stdin.read()
with tempfile.TemporaryDirectory(prefix="nagare-gcs-ingest-") as directory:
    root = Path(directory)
    work = root / "work"
    work.mkdir()
    data = b"scheduled database bytes"
    metadata = {"scheduleRevision": "a" * 64}
    payload = {
        "jobUid": "run-1", "object": "gs://backups/databases/mydb/run-1.sql.gz",
        "sha256": hashlib.sha256(data).hexdigest(), "backup": metadata,
        "source": {"statefulSetUid": "stateful-1", "pvcUid": "pvc-1"},
    }
    key = "ab" * 32
    receipt = canonical({"version": 4, "payload": payload, "hmacSha256":
        hmac.new(bytes.fromhex(key), canonical(payload), hashlib.sha256).hexdigest()})
    (root / "OBJECT").write_bytes(data)
    (root / "RECEIPT").write_bytes(receipt)
    fake = root / "gcloud"
    fake.write_text("#!" + sys.executable + "\n" + '''
import json, os, pathlib, sys
e = os.environ
a = sys.argv[1:]
assert a[0] == "storage"
url = a[3] if a[1] == "objects" else a[3]
label = next(k for k in ["OBJECT", "RECEIPT"]
    if url == "gs://" + e["BUCKET"] + "/" + e[k+"_KEY"] + "#" + e[k+"_VERSION"])
if a[1:3] == ["objects", "describe"]:
    assert a[4:] == ["--format=json"]
    print(json.dumps({"bucket": "foreign" if e["FAULT"] == "bucket" else e["BUCKET"],
        "name": e[label+"_KEY"], "generation": "999" if e["FAULT"] == "generation" else e[label+"_VERSION"],
        "size": e[label+"_LENGTH"]}))
else:
    assert a[1:3] == ["cp", "--do-not-decompress"] and len(a) == 5
    data = pathlib.Path(e["FIXTURE"], label).read_bytes()
    if e["FAULT"] == "bytes": data = b"X" + data[1:]
    pathlib.Path(a[4]).write_bytes(data)
''')
    fake.chmod(0o755)
    env = dict(os.environ, PATH=directory + os.pathsep + os.environ["PATH"],
        FIXTURE=directory, BUCKET="backups", OBJECT_KEY="databases/mydb/run-1.sql.gz",
        RECEIPT_KEY="databases/mydb/run-1.sql.gz.receipt.json", OBJECT_VERSION="123",
        RECEIPT_VERSION="456", OBJECT_LENGTH=str(len(data)), RECEIPT_LENGTH=str(len(receipt)),
        OBJECT_SHA256=payload["sha256"], RECEIPT_SHA256=hashlib.sha256(receipt).hexdigest(),
        BACKUP_SIGNING_KEY=key, BACKUP_RUN_ID="run-1", OBJECT_ADDRESS=payload["object"],
        STATEFUL_UID="stateful-1", PVC_UID="pvc-1", SCHEDULE_REVISION="a" * 64,
        METADATA_SHA256=hashlib.sha256(canonical(metadata)).hexdigest())
    proof = root / "proof"
    script = script.replace("/work/", str(work) + "/").replace("/dev/termination-log", str(proof))
    for fault in ["", "bucket", "generation", "bytes", "hmac"]:
        proof.unlink(missing_ok=True)
        selected = dict(env, FAULT=fault)
        if fault == "hmac": selected["BACKUP_SIGNING_KEY"] = "cd" * 32
        result = subprocess.run(["/bin/sh", "-c", script], env=selected, capture_output=True)
        assert (result.returncode == 0) == (fault == ""), (fault, result.stderr.decode())
        assert proof.exists() == (fault == ""), fault
        if not fault:
            assert json.loads(proof.read_text()) == {
                "objectVersion": "123", "receiptVersion": "456", "sha256": payload["sha256"]}

    payload["recoveryPoint"] = "2026-10-02T12:00:00Z"
    receipt = canonical({"version": 5, "payload": payload, "hmacSha256":
        hmac.new(bytes.fromhex(key), canonical(payload), hashlib.sha256).hexdigest()})
    (root / "RECEIPT").write_bytes(receipt)
    env.update(RECEIPT_LENGTH=str(len(receipt)), RECEIPT_SHA256=hashlib.sha256(receipt).hexdigest())
    for point in [payload["recoveryPoint"], "2026-10-02T12:30:00Z"]:
        proof.unlink(missing_ok=True)
        result = subprocess.run(["/bin/sh", "-c", script],
            env=dict(env, FAULT="", RECOVERY_POINT=point), capture_output=True)
        assert (result.returncode == 0) == (point == payload["recoveryPoint"]), result.stderr.decode()
        assert proof.exists() == (point == payload["recoveryPoint"])
