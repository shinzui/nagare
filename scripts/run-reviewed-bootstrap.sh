#!/usr/bin/env bash
set -euo pipefail

# Keep the public review after an interrupted apply; the private native bundle
# and transaction journal remain in the selected context's inventory store.
review_root="$(mktemp -d "${TMPDIR:-/tmp}/nagare-bootstrap-review.XXXXXX")"
review_dir="$review_root/review"
printf 'Bootstrap review: %s\n' "$review_dir"
nagarectl platform bootstrap plan --out "$review_dir"
nagarectl platform bootstrap apply "$review_dir" --yes
