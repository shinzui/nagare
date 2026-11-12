# Sourced by every EP-248 D6 step, from env -i. Never the operator's shell.
set -euo pipefail
PKG="${PKG_OVERRIDE:-$(readlink "$HOME/.local/state/nagare/drills/ep248-cloud/pkg")}"
SP=$HOME/.local/state/nagare/drills/ep248-cloud
export PATH="/nix/store/bbw5prjp31gcchivgmhv12a92q18qv5l-pulumi-3.255.0/bin:/nix/store/llh8iqmk3ypvix1vir5hia4rfifi5vr6-pulumi-nodejs-3.255.0/bin:/nix/store/6hbiyfa4gzcjr6bnr440nnwznlsaldlc-nodejs-22.23.2/bin:$PATH"
CTX=ep248; PROJECT=tan-nb-exp; BASE=topagentnetworklabs.com
OPS=$HOME/Keikaku/bokuno/nagare-ops
RUN=$HOME/.local/state/nagare/ep248/run
SECRETS=$HOME/.local/state/nagare/secrets
AGE_KEY=$SECRETS/ep248-host.agekey
export XDG_CONFIG_HOME="$RUN/config" XDG_STATE_HOME="$RUN/state" XDG_CACHE_HOME="$RUN/cache"
export CLOUDSDK_CONFIG="$HOME/.config/gcloud" CLOUDSDK_ACTIVE_CONFIG_NAME=ep248
export GOOGLE_APPLICATION_CREDENTIALS="$SECRETS/ep248-adc.json"
export NAGARE_CONTEXT=$CTX SOPS_AGE_KEY_FILE="$AGE_KEY" NAGARE_HOST_AGE_KEY_FILE="$AGE_KEY"
export NIX_BUILDER_SSH_KEY="$SECRETS/drill-builder_ed25519"
export SSH_USER=deploy SSH_KEY="$HOME/.ssh/id_ed25519"
export CF_ACCOUNT_ID=d605625d4375aa3120a1374daf2f9a87 CF_ZONE_ID=a0bc2ff68ebe0ae99b7f9864a2219722
export CF_API_TOKEN="$(cat "$SECRETS/cloudflare-api-token-ep240")"
N() { "$PKG/bin/nagarectl" --context "$CTX" "$@"; }
log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { printf 'STOP: %s\n' "$*" >&2; exit 1; }
export KUBECONFIG="$XDG_CONFIG_HOME/nagare/kubeconfigs/$CTX.yaml"
export PATH="/nix/store/j1ly4dmdyi9mis8s6lkaf5j3p2rfxn4d-socat-1.8.1.3/bin:$PATH"
