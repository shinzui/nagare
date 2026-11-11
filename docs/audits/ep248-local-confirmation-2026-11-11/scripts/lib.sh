# Sourced by every phase: a clean environment for the disposable ep248 context.
set -euo pipefail
R=$HOME/.local/state/nagare/drills/ep248
CTX=ep248
export XDG_CONFIG_HOME=$R/config XDG_STATE_HOME=$R/state XDG_CACHE_HOME=$R/cache
export SOPS_AGE_KEY_FILE=$R/sops/age/keys.txt
set -a; . "$R/images.env"; set +a
export NAGARE_LOCAL_REGISTRY_FORWARD=127.0.0.1:15213
export DOCKER_HOST=unix://$HOME/.colima/nagare-c4-amd64/docker.sock
N="$(cat "$R/nagarectl.path")"
# A rehearsal with the dev build resolves its payload from the source tree.
case "$N" in */dist-newstyle/*) export NAGARE_PLATFORM_ROOT=$HOME/Keikaku/bokuno/nagare ;; esac
OP() { "$N" --context "$CTX" "$@"; }
IMG=k3d-registry.localhost:5000/tan-nb-exp/nagare
export KUBECONFIG=$R/config/nagare/kubeconfigs/$CTX.yaml
K() { kubectl --context "$CTX" "$@"; }
[ "$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' | grep -cE '^https://(127\.0\.0\.1|0\.0\.0\.0|localhost):[0-9]+$')" = 1 ] || { echo "kube server is not loopback" >&2; exit 1; }
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
# The deployer Pod runs the linux nagarectl image with only the bundle.
DEPLOYER_NS=default
D() { K -n "$DEPLOYER_NS" exec -i ep248-deployer -- "$@"; }
# A deployer command in the Pod: HOME and XDG_CONFIG_HOME at the bundle, nothing else of ours.
DN() { D env -i PATH=/bin HOME=/work/home XDG_CONFIG_HOME=/work/home/.config TMPDIR=/work/tmp KUBERNETES_SERVICE_HOST=kubernetes.default.svc KUBERNETES_SERVICE_PORT=443 nagarectl --context "$CTX" "$@"; }
# kubectl in the Pod with a bundle kubeconfig: the deployer's (default) or the builder's.
DK() { D kubectl --kubeconfig /work/home/.config/nagare/kubeconfigs/$CTX.yaml --context "$CTX" "$@"; }
BK() { D kubectl --kubeconfig /work/home/builder/kubeconfig.yaml --context "$CTX" "$@"; }

MC() { K -n nagare-system get job nagare-deployer-ci-store-grant -o jsonpath='{.spec.template.spec.containers[0].image}'; }
# A client Pod given only the bundle's key, then a check script, on standard input.
probe() { # bundle-dir script
  local key secret
  key="$(jq -r .accessKeyId "$1/.config/nagare/credentials/$CTX-s3.json")"; secret="$(jq -r .secretAccessKey "$1/.config/nagare/credentials/$CTX-s3.json")"
  { printf '%s
%s
' "$key" "$secret"; printf '%s
' "$2"; } | K -n "$DEPLOYER_NS" run "ep248-s3-$RANDOM" --image="$(MC)" --restart=Never --rm -i --quiet     --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":65532},"containers":[{"name":"probe","image":"'"$(MC)"'","stdin":true,"stdinOnce":true,"env":[{"name":"HOME","value":"/tmp"}],"command":["/bin/sh","-c","read -r k; read -r s; mc alias set b http://minio.nagare-system.svc.cluster.local:9000 \"$k\" \"$s\" >/dev/null 2>&1 || { echo alias-refused; exit 0; }; exec sh -s"]}]}}'
}
