# Sourced by every phase: a clean environment for the disposable mp33 context.
set -euo pipefail
R=$HOME/.local/state/nagare/drills/mp33-final
export XDG_CONFIG_HOME=$R/config XDG_STATE_HOME=$R/state XDG_CACHE_HOME=$R/cache
export SOPS_AGE_KEY_FILE=$R/sops/age/keys.txt
set -a; . "$R/images.env"; set +a
export NAGARE_LOCAL_REGISTRY_FORWARD=127.0.0.1:15213
export DOCKER_HOST=unix://$HOME/.colima/nagare-c4-amd64/docker.sock
N="$(cat "$R/nagarectl.path")"
export NAGARE_DRILL_NAGARECTL=$N
# A rehearsal with the dev build resolves its payload from the source tree.
case "$N" in */dist-newstyle/*) export NAGARE_PLATFORM_ROOT=$HOME/Keikaku/bokuno/nagare ;; esac
OP() { "$N" --context mp33 "$@"; }
# The deployer: the same context name in its own home, as EP-248's bundle lays it out.
CIHOME=$R/ci
CI() { env XDG_CONFIG_HOME="$CIHOME/config" XDG_STATE_HOME="$CIHOME/state" XDG_CACHE_HOME="$CIHOME/cache" NAGARE_INVENTORY_STORE_CREDENTIALS_FILE="$CIHOME/store-credentials.json" "$N" --context mp33 "$@"; }
IMG=k3d-registry.localhost:5000/tan-nb-exp/nagare
SRC=(--source-repository https://forge.example.test/team-a/site --source-run https://ci.example.test/runs/42)
ids() { [ -f "$R/ids.env" ] && . "$R/ids.env"; true; }
setid() { printf '%s=%q\n' "$1" "$2" >> "$R/ids.env"; }
imageid() { sed -n 's/^Image resource: //p' | tail -1; }
history() { "$@" inventory history --limit "${HISTORY_LIMIT:-6}"; }
export KUBECONFIG=$R/config/nagare/kubeconfigs/mp33.yaml
K() { kubectl --context mp33 "$@"; }
[ "$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')" = "$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' | grep -E '^https://(127\.0\.0\.1|0\.0\.0\.0|localhost):[0-9]+$')" ] || { echo "kube server is not loopback" >&2; exit 1; }
[ "$(K get nodes -o jsonpath='{.items[*].metadata.name}')" = k3d-nagare-local-server-0 ] || { echo "unexpected kube node" >&2; exit 1; }
EV=$R/evidence; mkdir -p "$EV" "$R/reviews"
step() { printf '\n## %s\n' "$*"; }
run() { printf '$ %s\n' "$*"; "$@"; }
refused() { # expect a nonzero exit; print the output
  printf '$ %s   # expected refusal\n' "$*"; local out rc=0
  out="$("$@" 2>&1)" || rc=$?
  printf '%s\nexit %s\n' "$out" "$rc"
  [ "$rc" != 0 ] || { echo "UNEXPECTED: the command succeeded" >&2; exit 1; }
}
