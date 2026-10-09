#!/usr/bin/env bash
# Section 4 is not re-run on 83124396: the cloud pass on 3b59bcb7 counts, because 3b59bcb7..83124396 changes
# only host-switch scripts, their tests and docs, and section 4 performs no host activation (decision 2026-10-09).
# The full driver is s4-run.sh.full.
echo "S4-SKIPPED: counted from the 3b59bcb7 cloud pass (diff touches only host-switch scripts)"
