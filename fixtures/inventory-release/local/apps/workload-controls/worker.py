"""workload-controls worker role: readiness from a marker, a 40-second drain (EP-256 M2).

/tmp/alive exists from process start (liveness). /tmp/ready appears once, after the
start delay and a database round trip (readiness); removing it reports the worker
unready and the process leaves it absent, so an operator's `rm` and `touch` hold.
SIGTERM removes the marker and drains for longer than the Kubernetes default of 30
seconds, inside the declared 60-second allowance.
"""

import os
import pathlib
import signal
import sys
import time
from datetime import datetime, timezone

import psycopg

ALIVE = pathlib.Path("/tmp/alive")
READY = pathlib.Path("/tmp/ready")
DSN = os.environ["DATABASE_URL"]
READY_DELAY = float(os.environ.get("WORKER_READY_DELAY_SECONDS", "20"))
DRAIN_SECONDS = float(os.environ.get("WORKER_DRAIN_SECONDS", "40"))

terminating_at = None


def log(message):
    stamp = datetime.now(timezone.utc).isoformat(timespec="milliseconds")
    print(f"{stamp} {message}", flush=True)


def on_sigterm(signum, frame):
    global terminating_at
    if terminating_at is None:
        terminating_at = time.monotonic()
        log("SIGTERM received; draining")


def database_answers():
    try:
        with psycopg.connect(DSN, connect_timeout=2) as conn:
            conn.execute("SELECT 1")
        return True
    except psycopg.Error:
        return False


def main():
    signal.signal(signal.SIGTERM, on_sigterm)
    ALIVE.touch()
    log("process started; /tmp/alive exists")
    start = time.monotonic()
    initialized = False
    while terminating_at is None:
        if not initialized and time.monotonic() - start >= READY_DELAY and database_answers():
            READY.touch()
            initialized = True
            log("initialization done; /tmp/ready exists")
        time.sleep(1)
    READY.unlink(missing_ok=True)
    log(f"drain started; /tmp/ready removed; draining {DRAIN_SECONDS} seconds")
    while time.monotonic() - terminating_at < DRAIN_SECONDS:
        time.sleep(1)
    log(f"drain complete after {time.monotonic() - terminating_at:.1f} seconds; exiting 0")
    sys.exit(0)


if __name__ == "__main__":
    main()
