#!/usr/bin/env bash
# EP-172 M1: record the source side of the release transition fixture,
# cli/nagarectl/test/fixtures/transition-<source>/, from a transition rehearsal root
# (scripts/transition-rehearsal.sh) and the source release's nix-built nagarectl:
#   payload/          the source payload's cluster and NixOS trees, from the release tag, each
#                     file checked against the published payload workspace the rehearsal used
#   payload.sha256    every extracted file's digest; source.json binds the workspace digest
#   store/            bytes the source nagarectl wrote: a fresh head, the rehearsal head as the
#                     source's own export and restore rewrites it, a sample of the journal it
#                     appended, and both releases' revisions of every scope the transition
#                     re-declared (revisions.json pairs every platform scope's two digests)
# It reads the rehearsal root and writes only the fixture and a temporary directory.
set -euo pipefail

: "${NAGARE_FIXTURE_SOURCE:?the source release nagarectl, a nix output bin/nagarectl}"
: "${NAGARE_FIXTURE_REHEARSAL:?a transition rehearsal root whose source is that release}"
CTX="${NAGARE_FIXTURE_CONTEXT:-transition}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version="$("$NAGARE_FIXTURE_SOURCE" version | sed -n 's/^nagarectl \([0-9.]*\).*/\1/p')"
[ -n "$version" ] || { echo "could not read the source nagarectl's version" >&2; exit 1; }
out="$repo_root/cli/nagarectl/test/fixtures/transition-$version"
rehearsal_store="$NAGARE_FIXTURE_REHEARSAL/state/nagare/$CTX/inventory"
workspaces=("$NAGARE_FIXTURE_REHEARSAL/state/nagare/$CTX/platform/nagare-$version-"*)
[ "${#workspaces[@]}" = 1 ] && [ -d "${workspaces[0]}" ] || { echo "expected one nagare-$version workspace in the rehearsal root" >&2; exit 1; }
workspace="${workspaces[0]}"
[ -f "$rehearsal_store/head.json" ] || { echo "no inventory store at $rehearsal_store" >&2; exit 1; }
scratch="$(mktemp -d)"
trap 'rm -rf -- "$scratch"' EXIT

# --- the payload extract ---
rm -rf "$out"
mkdir -p "$out/payload" "$out/store/journal" "$out/store/scopes"
git -C "$repo_root" archive "v$version" cluster/bootstrap cluster/observability cluster/local nixos | tar -x -C "$out/payload"
cp "$workspace/release.json" "$out/payload/release.json"
(cd "$out/payload" && find . -type f | sed 's|^\./||' | LC_ALL=C sort) > "$scratch/files"
while IFS= read -r file; do
  cmp -s "$out/payload/$file" "$workspace/$file" || { echo "payload/$file differs from the published workspace" >&2; exit 1; }
done < "$scratch/files"
(cd "$out/payload" && tr '\n' '\0' < "$scratch/files" | xargs -0 shasum -a 256) > "$out/payload.sha256"
python3 -I - "$workspace/.nagare-workspace.json" "$out/source.json" <<'PY'
import json, sys
workspace = json.load(open(sys.argv[1]))
record = {key: workspace[key] for key in ("payloadId", "platformVersion", "sourceRevision")}
record["workspaceDigest"] = workspace["digest"]
json.dump(record, open(sys.argv[2], "w"), indent=2, sort_keys=True)
open(sys.argv[2], "a").write("\n")
PY

# --- the store bytes the source release writes ---
for v in $(env | sed -n "s/^\(NAGARE_[A-Z_]*\|CLOUDSDK_[A-Z_]*\|PULUMI_[A-Z_]*\|KUBECONFIG\|SOPS_AGE_KEY_FILE\)=.*/\1/p"); do
  case "$v" in NAGARE_FIXTURE_*) ;; *) unset "$v" ;; esac
done
source_in() { # root context args...
  local root="$1" context="$2"; shift 2
  env XDG_CONFIG_HOME="$root/config" XDG_STATE_HOME="$root/state" XDG_CACHE_HOME="$root/cache" \
    DOCKER_HOST="unix://$scratch/no-docker.sock" PATH=/usr/bin:/bin \
    "$NAGARE_FIXTURE_SOURCE" --context "$context" "$@"
}
# A fresh context's head: planning initializes the store before it reaches a provider, and
# with no k3d on the PATH it stops right after.
fresh="$scratch/fresh"
mkdir -p "$fresh"/{config,state,cache}
source_in "$fresh" fixture context create fixture --mode local --registry-host k3d-registry.localhost:5000 \
  --base-domain 127-0-0-1.sslip.io --target-platform linux/arm64 \
  --local-object-store http://minio.nagare-system.svc.cluster.local:9000/nagare-backups > /dev/null
source_in "$fresh" fixture platform bootstrap plan --out "$scratch/fresh-review" > /dev/null 2>&1 || true
cp "$fresh/state/nagare/fixture/inventory/head.json" "$out/store/head-initial.json"
# The rehearsal head as the source release rewrites it: its own export, restored into an
# empty store of the same context.
copy="$scratch/copy"
mkdir -p "$copy/config/nagare/contexts" "$copy/state/nagare/$CTX" "$copy/cache"
cp "$NAGARE_FIXTURE_REHEARSAL/config/nagare/contexts/$CTX.env" "$copy/config/nagare/contexts/"
cp -R "$rehearsal_store" "$copy/state/nagare/$CTX/inventory"
rm -f "$copy/state/nagare/$CTX/inventory/process.lock"
source_in "$copy" "$CTX" inventory export --out "$scratch/export" > /dev/null
mv "$copy/state/nagare/$CTX/inventory" "$scratch/exported-store"
source_in "$copy" "$CTX" inventory restore --from "$scratch/export" --yes > /dev/null
cp "$copy/state/nagare/$CTX/inventory/head.json" "$out/store/head.json"
# The journal events the source appended, before the first transition review's transaction:
# the first ten, and the first of every state and operation shape after them.
python3 -I - "$rehearsal_store" "$NAGARE_FIXTURE_REHEARSAL/reviews" "$out/store" <<'PY'
import glob, json, os, shutil, sys
store, reviews, out = sys.argv[1:]
def review_identity(digest):
    return json.load(open(f"{store}/reviews/{digest}.json")).get("payloadIdentity", "")
paths = sorted(glob.glob(f"{store}/journal/*.json"))
events = [json.load(open(p)) for p in paths]
end = next(i for i, e in enumerate(events) if review_identity(e["transaction"].removeprefix("tx-")).startswith("nagare-transition:"))
seen, kept = set(), []
for i in range(end):
    shape = (events[i]["state"]["tag"], events[i]["operation"] is None)
    if i < 10 or shape not in seen:
        kept.append(paths[i])
    seen.add(shape)
for p in kept:
    shutil.copy(p, f"{out}/journal/{os.path.basename(p)}")
# Every platform scope's revision at the transition's first plan (the source's last
# accepted) and at the end (the target's), with both files where they differ.
first = json.load(open(f"{reviews}/transition-1/review.json"))
final = json.load(open(f"{store}/head.json"))
def by_scope(entries):
    return {e["scope"]["name"]: e["revision"]["digest"] for e in entries if e["scope"]["kind"] == "Platform"}
source, target = by_scope(first["baseRevisions"]), by_scope(final["accepted"])
pairs = [{"scope": name, "source": source[name], "target": target[name]} for name in sorted(source) if name in target]
for pair in pairs:
    if pair["source"] != pair["target"]:
        for digest in (pair["source"], pair["target"]):
            shutil.copy(f"{store}/scopes/{digest}.json", f"{out}/scopes/{digest}.json")
json.dump({"sourceEvents": end, "scopes": pairs}, open(f"{out}/revisions.json", "w"), indent=2, sort_keys=True)
open(f"{out}/revisions.json", "a").write("\n")
PY
echo "recorded $out"
