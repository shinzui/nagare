#!/usr/bin/env bash
set -euo pipefail
root=/Users/shinzui/.local/state/nagare-verify/mp23-c3m
args=(PATH="$PATH" HOME=/Users/shinzui USER=shinzui
  XDG_CONFIG_HOME="$root/config" XDG_STATE_HOME="$root/state" XDG_CACHE_HOME="$root/cache"
  CLOUDSDK_ACTIVE_CONFIG_NAME=labs CLOUDSDK_CORE_PROJECT=tan-ng-labs
  CLOUDSDK_CORE_DISABLE_FILE_LOGGING=true CLOUDSDK_CORE_DISABLE_PROMPTS=true
  CLOUDSDK_COMPUTE_ZONE=us-west1-a ZONE=us-west1-a
  SSH_KEY=/Users/shinzui/.ssh/google_compute_engine IAP_MAX_ATTEMPTS=1
  KUBECONFIG="$root/config/nagare/kubeconfigs/mp23-c3m.yaml"
  SOPS_AGE_KEY_FILE="$root/age-key.txt"
  NAGARE_HOST_AGE_KEY_FILE="$root/age-key.txt"
  NAGARE_BUILDER_PROJECT=tan-ng-labs NAGARE_BUILDER_ZONE=us-west1-a
  NAGARE_BUILDER_INSTANCE=nix-builder-ep150
  NAGARE_MODE=cloud NAGARE_REGISTRY_HOST=us-west1-docker.pkg.dev NAGARE_ARTIFACT_REGISTRY_ID=nagare-c3-1012
  NAGARE_BASE_DOMAIN=c3-1012.labs.topagentnetwork.net
  NAGARE_AUTH_ACCESS_IMAGE=us-west1-docker.pkg.dev/tan-ng-labs/nagare/nagare-access@sha256:c679a2627f92f0d7f8dcd2c7edc9d3e6ce400bac7c8702605d79edfc9cf1097c
  NAGARE_AUTH_EN_IMAGE=us-west1-docker.pkg.dev/tan-ng-labs/nagare/en@sha256:5999f31f823b9fa470e2cab01a10a8cd0fdf574a72740e9373ad9b95624990b3
  NAGARE_AUTH_SHOMEI_IMAGE=us-west1-docker.pkg.dev/tan-ng-labs/nagare/shomei@sha256:0b88cb6b7b0a843dd868902ba4dabede2beb65e918cce59404b9f1f6dc3f1bf2
)
exec env -i "${args[@]}" /private/tmp/result-83124396-nagare/bin/nagarectl "$@"
