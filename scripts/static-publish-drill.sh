#!/usr/bin/env bash
# EP-222 M4: the one-command publish loop on a bootstrapped disposable local context. From
# a drill root that scripts/site-access-drill.sh has bootstrapped (and, usually, run through
# step 7): publish the protected static-site example, edit its output and publish again,
# publish with nothing changed (no build, no new release), and roll back to the first
# release, reading the served bytes from the running pod at each step. Every timed command
# writes an EP-224 trace document; the record is evidence/static-publish-drill.md.
set -euo pipefail

: "${DOCKER_HOST:?the disposable Docker daemon socket, never the shared cp3 daemon}"
: "${NAGARE_DRILL_NAGARECTL:?the candidate nagarectl}"
: "${NAGARE_DRILL_ROOT:?the bootstrapped drill root}"
: "${NAGARE_DRILL_GHC_ENV:?the GHC package environment that resolves nagare-dsl}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$NAGARE_DRILL_ROOT"
CTX="${NAGARE_DRILL_CONTEXT:-site-access}"
FORWARD_PORT="${NAGARE_DRILL_FORWARD_PORT:-15213}"
SITE=protected-static-site
NS=personal
for v in $(env | sed -n "s/^\(NAGARE_[A-Z_]*\|CLOUDSDK_[A-Z_]*\|PULUMI_[A-Z_]*\|KUBECONFIG\|SOPS_AGE_KEY_FILE\)=.*/\1/p"); do
  case "$v" in NAGARE_DRILL_*) ;; *) unset "$v" ;; esac
done
export XDG_CONFIG_HOME="$ROOT/config" XDG_STATE_HOME="$ROOT/state" XDG_CACHE_HOME="$ROOT/cache"
export SOPS_AGE_KEY_FILE="$ROOT/sops/age/keys.txt"
set -a; . "$ROOT/images.env"; set +a
export NAGARE_LOCAL_REGISTRY_FORWARD="127.0.0.1:$FORWARD_PORT"
export KUBECONFIG="$XDG_CONFIG_HOME/nagare/kubeconfigs/$CTX.yaml"
KUBE="$(kubectl config current-context)"
EV="$ROOT/evidence/static-publish"
mkdir -p "$EV" "$ROOT/m4"
PROJECT="$ROOT/m4/project"
rm -rf "$PROJECT"; mkdir -p "$PROJECT"
cp -R "$REPO/cluster/examples/$SITE/nagare" "$REPO/cluster/examples/$SITE/public" "$PROJECT/"
log() { printf '%s publish-drill: %s\n' "$(date -u +%H:%M:%S)" "$*"; }
N() { local trace="$1"; shift; NAGARE_TRACE=1 NAGARE_TRACE_FILE="$EV/$trace.trace.json" "$NAGARE_DRILL_NAGARECTL" --context "$CTX" "$@"; }
publish() { # label args...
  local label="$1"; shift
  local start end
  start="$(python3 -I -c 'import time; print(time.monotonic_ns())')"
  N "$label" site publish -C "$PROJECT" -f "$PROJECT/nagare/Config.hs" --ghc-env "$NAGARE_DRILL_GHC_ENV" "$@" > "$EV/$label.out" 2> "$EV/$label.err" || {
    echo "publish $label failed:" >&2; tail -8 "$EV/$label.err" >&2; exit 1; }
  end="$(python3 -I -c 'import time; print(time.monotonic_ns())')"
  printf '%s\t%s\n' "$label" "$(( (end - start) / 1000000 ))" >> "$EV/wall-ms.tsv"
  log "$label: $(tr '\n' ' ' < "$EV/$label.out")"
}
field() { sed -n "s/^$2: //p" "$EV/$1.out" | head -1; }
served() { # the index.html bytes in a running pod of the site
  local pod
  pod="$(kubectl --context "$KUBE" -n "$NS" get pods -l "serving.knative.dev/service=$SITE" --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')"
  kubectl --context "$KUBE" -n "$NS" exec "$pod" -c user-container -- cat /usr/share/nginx/html/index.html
}
wait_served() { # marker
  for _ in $(seq 1 60); do served 2>/dev/null | grep -q "$1" && return 0; sleep 3; done
  echo "the pods never served $1" >&2; exit 1
}
docker_runs() { python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(sum(c["count"] for c in d.get("counts",[]) if c.get("name")=="docker"))' "$EV/$1.trace.json"; }

# 1. first publication
publish first --new-release
TAG1="$(field first tag)"; IMAGE1="$(field first image)"
wait_served "protected"
served > "$EV/served-1.html"
log "first release $TAG1 serves $(wc -c < "$EV/served-1.html") bytes"

# 2. edit the output and publish again: new tag and image, the same URL, the new bytes
printf '<!-- ep222 marker two -->\n' >> "$PROJECT/public/index.html"
publish update
TAG2="$(field update tag)"; IMAGE2="$(field update image)"
[ "$TAG2" != "$TAG1" ] && [ "$IMAGE2" != "$IMAGE1" ] || { echo "the update reused the first release" >&2; exit 1; }
[ "$(field update url)" = "$(field first url)" ] || { echo "the URL changed" >&2; exit 1; }
wait_served "ep222 marker two"
served > "$EV/served-2.html"

# 3. nothing changed: no build, no new release
publish unchanged
grep -q '^unchanged: release ' "$EV/unchanged.out" || { echo "an unchanged publish was not reported unchanged" >&2; exit 1; }
[ "$(docker_runs unchanged)" = 0 ] || { echo "the unchanged publish ran Docker" >&2; exit 1; }

# 4. --new-release publishes unchanged files anyway
publish forced --new-release
TAG3="$(field forced tag)"
[ "$TAG3" != "$TAG2" ] || { echo "--new-release reused the serving release" >&2; exit 1; }

# 4b. warm samples: three edited releases and three unchanged republishes, for medians
for i in 1 2 3; do
  printf '<!-- ep222 warm %s -->\n' "$i" >> "$PROJECT/public/index.html"
  publish "warm-update-$i"
  publish "warm-unchanged-$i"
  grep -q '^unchanged: release ' "$EV/warm-unchanged-$i.out" || { echo "warm-unchanged-$i built something" >&2; exit 1; }
done

# 4c. the machine-readable result: exactly one site-publish-result document on stdout
N contract site publish -C "$PROJECT" -f "$PROJECT/nagare/Config.hs" --ghc-env "$NAGARE_DRILL_GHC_ENV" --new-release --contract 1 > "$EV/contract.out" 2> "$EV/contract.err"
python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["document"]=="site-publish-result" and d["stage"]=="deployed" and d["url"] and d["imageResource"] and d["releaseDirectory"] and d["content"] and d["failure"] is None, d' "$EV/contract.out"
N contract-unchanged site publish -C "$PROJECT" -f "$PROJECT/nagare/Config.hs" --ghc-env "$NAGARE_DRILL_GHC_ENV" --contract 1 > "$EV/contract-unchanged.out" 2> "$EV/contract-unchanged.err"
python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["document"]=="site-publish-result" and d["stage"]=="unchanged", d' "$EV/contract-unchanged.out"
log "contract documents verified"

# 5. roll back to the first release (reviewed, with its accepted image)
RES1="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["imageResource"])' "$(command ls -d "$XDG_STATE_HOME/nagare/$CTX/static-releases/$SITE"/*/receipt.json | head -1)")"
rm -rf "$ROOT/reviews/m4-rollback"
N rollback site rollback "$TAG1" -f "$PROJECT/nagare/Config.hs" --ghc-env "$NAGARE_DRILL_GHC_ENV" --image-resource "$RES1" --save-plan "$ROOT/reviews/m4-rollback" > "$EV/rollback.plan.out" 2>&1
N rollback-apply inventory apply "$ROOT/reviews/m4-rollback" --yes > "$EV/rollback.apply.out" 2>&1
for _ in $(seq 1 60); do served 2>/dev/null | cmp -s - "$EV/served-1.html" && break; sleep 3; done
served | cmp -s - "$EV/served-1.html" || { echo "rollback did not restore the first release's bytes" >&2; exit 1; }
log "rolled back to $TAG1; served bytes match the first release"

# 5b. an interrupted release resumes from the stage its receipt proves, without rebuilding
RELEASES="$XDG_STATE_HOME/nagare/$CTX/static-releases/$SITE"
interrupted=0
for attempt in 1 2 3; do
  printf '<!-- ep222 resume %s -->\n' "$attempt" >> "$PROJECT/public/index.html"
  N resume-first site publish -C "$PROJECT" -f "$PROJECT/nagare/Config.hs" --ghc-env "$NAGARE_DRILL_GHC_ENV" > "$EV/resume-first.out" 2> "$EV/resume-first.err" &
  PID=$!
  stopped=""
  for _ in $(seq 1 600); do
    kill -0 "$PID" 2>/dev/null || break
    newest="$(command ls -dt "$RELEASES"/*/ 2>/dev/null | head -1)"
    stage="$([ -n "$newest" ] && [ -f "$newest/receipt.json" ] && python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["stage"])' "$newest/receipt.json" 2>/dev/null || true)"
    if [ "$stage" = "image-published" ]; then kill -TERM "$PID" 2>/dev/null && stopped="$stage"; break; fi
    sleep 0.1
  done
  wait "$PID" 2>/dev/null || true
  if [ -n "$stopped" ]; then interrupted=1; break; fi
  log "attempt $attempt finished before it could be interrupted"
done
[ "$interrupted" = 1 ] || { echo "could not interrupt a publish between image and deploy" >&2; exit 1; }
log "interrupted at stage $stopped in $newest"
publish resumed --resume --release-dir "$newest"
wait_served "ep222 resume $attempt"
[ "$(field resumed tag)" = "$(basename "$newest")" ] || [ -n "$(field resumed tag)" ] || { echo "resume did not report a release" >&2; exit 1; }
[ "$(docker_runs resumed)" = 0 ] || { echo "resume ran Docker" >&2; exit 1; }
python3 -I -c 'import json,sys; assert json.load(open(sys.argv[1]))["stage"]=="deployed"' "$newest/receipt.json"
log "resumed $newest without rebuilding"

# 6. the traced numbers
python3 -I - "$EV" <<'PY'
import json, sys, glob, os
for path in sorted(glob.glob(os.path.join(sys.argv[1], "*.trace.json"))):
    d = json.load(open(path))
    phases = {}
    for s in d.get("spans", []):
        phases[s["phase"]] = round(phases.get(s["phase"], 0) + (s["endNanos"] - s["startNanos"]) / 1e9, 2)
    procs = {c["name"]: [c["count"], round(c["nanos"] / 1e9, 2)] for c in d.get("counts", []) if c.get("category") == "process"}
    print(os.path.basename(path), "wall", round(d["elapsedNanos"] / 1e9, 2), json.dumps(phases, sort_keys=True), "process", json.dumps(procs, sort_keys=True))
PY
python3 -I - "$EV" <<'PY'
import json, glob, os, statistics, sys
groups = {"warm-update": [], "warm-unchanged": []}
for path in sorted(glob.glob(os.path.join(sys.argv[1], "warm-*.trace.json"))):
    name = os.path.basename(path)
    for group in groups:
        if name.startswith(group):
            d = json.load(open(path))
            phases = {}
            for s in d["spans"]:
                phases[s["phase"]] = phases.get(s["phase"], 0) + (s["endNanos"] - s["startNanos"]) / 1e9
            groups[group].append((d["elapsedNanos"] / 1e9, phases.get("publish.config", 0), phases.get("package.build", 0)))
for group, rows in groups.items():
    if rows:
        cols = list(zip(*rows))
        print(group, "n=%d" % len(rows), "wall median %.2f range %.2f-%.2f" % (statistics.median(cols[0]), min(cols[0]), max(cols[0])),
              "config median %.2f" % statistics.median(cols[1]), "build median %.2f" % statistics.median(cols[2]))
PY
log "evidence in $EV"
