"""workload-controls migration task: a real SQL schema change that records each run.

The table is created once and every execution appends one row to migration_runs, so a
second run of this task is visible as a second row (EP-256 M2 reads the count).
"""

import os

import psycopg

DSN = os.environ["DATABASE_URL"]
RUN_ID = os.environ.get("NAGARE_RUN_ID", "unknown")

with psycopg.connect(DSN, connect_timeout=5) as conn:
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS migration_runs (
          id bigserial PRIMARY KEY,
          run_id text NOT NULL,
          ran_at timestamptz NOT NULL DEFAULT now()
        )
        """
    )
    conn.execute("CREATE TABLE IF NOT EXISTS workload_events (id bigserial PRIMARY KEY, note text)")
    count = conn.execute(
        "INSERT INTO migration_runs (run_id) VALUES (%s) RETURNING id", (RUN_ID,)
    ).fetchone()[0]

print(f"migration done: run {RUN_ID} recorded as migration_runs row {count}", flush=True)
