#!/usr/bin/env bash
# scripts/enable-apis.sh (EP-63) — codify the GCP service-API enablement that the
# original bootstrap had to do by hand (MasterPlan 1, EP-2 surprise:
# artifactregistry.googleapis.com and iam.googleapis.com were off and blocked
# `pulumi up`). On a brand-new project even compute/dns/storage may be off, so we
# enable the full set the Pulumi program needs, idempotently. Enabling an
# already-enabled API is a harmless no-op.
#
# Sources scripts/lib/target.sh (EP-60) for TARGET_PROJECT and the fail-closed
# project-isolation guardrail. SET NAGARE_ENABLE_APIS_DRY_RUN=1 to print the
# gcloud argv without running it (used by `nagarectl init --dry-run` and by tests
# on hosts with no real project).
set -euo pipefail

# Source the single target/guardrail helper from EP-60. It computes the repo root
# from its own path, loads nagare.target.env if present, and sets TARGET_PROJECT.
# shellcheck source=lib/target.sh
source "$(dirname "$0")/lib/target.sh"

# Fail closed unless gcloud's active project equals the configured target.
_require_target_project

APIS=(
  compute.googleapis.com
  dns.googleapis.com
  storage.googleapis.com
  artifactregistry.googleapis.com
  iam.googleapis.com
  servicenetworking.googleapis.com
)

if [ "${NAGARE_ENABLE_APIS_DRY_RUN:-0}" = "1" ]; then
  echo "DRY RUN: would run:"
  echo "  gcloud services enable ${APIS[*]} --project=${TARGET_PROJECT}"
  exit 0
fi

echo "Enabling GCP service APIs on ${TARGET_PROJECT}:"
printf '  %s\n' "${APIS[@]}"
gcloud services enable "${APIS[@]}" --project="${TARGET_PROJECT}"
echo "done."
