# Nagare command runner. These recipes are THIN WRAPPERS. The detailed
# contents of each step are owned by the child plans referenced below,
# under docs/plans/. Run `just --list` to see all recipes.
#
# Cloud commands target the active target context: a named env file under
# ${XDG_CONFIG_HOME:-$HOME/.config}/nagare/contexts/<name>.env, selected with
# `nagarectl context use NAME`, `NAGARE_CONTEXT`, or `--context`. The in-repo
# `nagare.target.env` and `nagare.local.env` remain lower-precedence compatibility
# fallbacks; with nothing configured, defaults reproduce tan-nb-exp / us-west1 /
# us-west1-a. See .envrc, CLAUDE.md, and docs/user/contexts.md. Enter the dev
# shell with `nix develop`, or let direnv load it after `direnv allow`.

# Show all recipes.
default:
    @just --list

# Run every repository-native documentation validation target.
[group('docs')]
docs-validate: reviews-validate user-documentation-validate terminology-validate

# Validate the controlled vocabulary and its cross-term graph.
[group('docs')]
terminology-validate:
    okf validate docs/terminology \
      --strict \
      --profile mori/terminology-profile.dhall \
      --profile-enforce \
      --log-enforce
    @okf graph docs/terminology --json >/dev/null
    mori terms validate --path .

# Strictly validate commit-pinned review records against the shared
# assurance.reviews profile. Findings stay in the review body or become records
# in the owning bug-report or improvement-request bundle.
[group('docs')]
reviews-validate:
    okf validate docs/reviews \
      --strict \
      --profile docs/reviews/profile.dhall \
      --profile-enforce \
      --log-enforce

# Strictly validate and graph the reader-facing documentation bundles against
# mori://shinzui/okf-profiles/profiles/user-documentation.
[group('docs')]
user-documentation-validate:
    okf validate docs/user \
      --strict \
      --profile mori/user-documentation-profile.dhall \
      --profile-enforce \
      --log-enforce
    @okf graph docs/user --json >/dev/null
    okf validate docs/guides \
      --strict \
      --profile mori/user-documentation-profile.dhall \
      --profile-enforce \
      --log-enforce
    @okf graph docs/guides --json >/dev/null

# EP-2 (docs/plans/2-pulumi-gcp-infrastructure.md): create/update the GCP
# resources (VM, static IP, Cloud DNS, disks, service account, Artifact
# Registry, backup bucket).
# EP-113: `platform guard` keeps its NAGARE_UPGRADE_APPLY escape hatch (an
# in-progress platform upgrade legitimately runs with skewed versions);
# `context guard` has none, because there is no situation in which writing to
# the wrong GCP project is correct.
# Apply a context-bound reviewed Pulumi plan without a TTY.
[group('infra')]
infra-up *args:
    nagarectl infra apply {{args}}

# Save and classify one context-bound Pulumi preview.
[group('infra')]
infra-preview *args:
    nagarectl infra preview {{args}}

# Save each staged cloud teardown review; apply it separately with inventory apply.
[group('infra')]
infra-destroy *args:
    nagarectl infra destroy {{args}}

# Cheapest reversible "off": halts compute charges; the boot/data disks and the
# reserved static IP keep their small storage/reservation cost. Targets the
# instance/zone/project from the target profile (.envrc / nagare.target.env),
# defaulting to nagare-01 / us-west1-a / tan-nb-exp. For reviewed teardown stages,
# use `nagare infra-destroy --save-plan DIR` (see docs/user/provisioning-with-pulumi.md).
# Stop the VM (reversible; restart with `just vm-start`).
[group('infra')]
vm-stop *args:
    nagarectl host stop {{args}}

# Caveat: a plain start boots the EXISTING boot disk (the current system
# generation), NOT the latest registered image, and some runtime-only fixes do
# not survive a reboot — see the "Power management" section of
# docs/runbooks/disaster-recovery.md.
# Start the VM again after `just vm-stop`.
[group('infra')]
vm-start *args:
    nagarectl host start {{args}}

# Review the next immutable image build/publication stage. Apply separately with
# inventory apply; bootstrap reviews the image-link config and VM stages.
[group('host')]
host-image *args:
    nagarectl host image {{args}}

# Show the registry host now carried by the generated context host flake.
[group('host')]
nixos-registry-host:
    @echo "nixos-registry-host no longer writes into the Nagare source."
    nagarectl host show

# EP-3: apply day-2 host configuration changes to the running nagare-01
# over Tailscale. The non-root deploy user needs --sudo.
# Apply day-2 host config to running nagare-01.
[group('host')]
host-switch review="":
    @if [ -n "{{review}}" ]; then nagarectl host apply "{{review}}" --yes; else scripts/host-switch.sh; fi

# Run the project-confined IAP SSH helper from the installed platform payload.
[group('host')]
iap-ssh *args:
    scripts/iap-ssh.sh {{args}}

# Pinned upstream versions for the cluster platform (EP-4). These move; see
# each cluster/bootstrap/*/README.md for the version-discovery procedure.
# Knative Serving v1.22.0 has no net-certmanager release asset; the independent
# GCS artifact remains pinned at the latest v1.14.0 URL (rechecked 2026-09-14).
# Nagare replaces only its controller image with the repository-owned aliasing
# fix after importing that image directly into the selected k3s image store.
knative_version := "knative-v1.22.0"
certmanager_version := "v1.20.2"
netcertmanager_version := "v1.14.0"

# Local k3s and registry pins live in cluster/bootstrap/local-substrate.json.

# EP-4 (docs/plans/4-knative-serving-kourier-ingress-and-cert-manager-tls.md):
# install cert-manager + DNS-01 issuer, Knative Serving, Kourier ingress, and
# net-certmanager, then wire the config-network / config-domain / config-certmanager
# ConfigMaps. HTTP-first: external-domain-tls stays OFF here — run
# `just cluster-enable-tls` once a real baseDomain is delegated.
#
# Assumes KUBECONFIG points at the cluster (see the MasterPlan access note: an
# SSH local-forward to 127.0.0.1:6443 until Tailscale is joined) and that the
# Pulumi stack output `baseDomain` is the real apps domain.
# Review and reconcile the complete cloud platform bootstrap inventory.
[group('cluster')]
cluster-bootstrap:
    @if [ -z "${NAGARE_UPGRADE_APPLY:-}" ]; then nagarectl platform guard; fi
    scripts/run-reviewed-bootstrap.sh

# Create or rotate the context-owned sops ciphertext for Attic storage/JWT credentials.
[group('cluster')]
nix-cache-secret-init *args:
    cluster/bootstrap/nix-cache/create-secret.sh {{args}}

# Reconcile the reviewed cache image publication and its dependent bootstrap scope.
[group('cluster')]
nix-cache-publish:
    @if [ -z "${NAGARE_UPGRADE_APPLY:-}" ]; then nagarectl platform guard; fi
    scripts/run-reviewed-bootstrap.sh

# Reconcile the enabled Attic cache through the reviewed platform inventory.
[group('cluster')]
nix-cache-bootstrap:
    @if [ -z "${NAGARE_UPGRADE_APPLY:-}" ]; then nagarectl platform guard; fi
    scripts/run-reviewed-bootstrap.sh

# Report Attic image, database, rollout, trust, retention, schedules, and client digest.
[group('cluster')]
nix-cache-status:
    nagarectl cluster guard
    cluster/bootstrap/nix-cache/status.sh

# Reconcile the complete inventory, including the personal Job-run quota.
[group('cluster')]
job-runs-bootstrap:
    @if [ -z "${NAGARE_UPGRADE_APPLY:-}" ]; then nagarectl platform guard; fi
    scripts/run-reviewed-bootstrap.sh

# EP-95: show current quota usage and the admission events used as backpressure.
# Inspect the bounded Job-run quota, admitted Pods, and recent Job events.
[group('cluster')]
job-runs-status:
    kubectl -n personal describe resourcequota nagare-terminating-jobs
    kubectl -n personal get pods -o custom-columns='NAME:.metadata.name,DEADLINE:.spec.activeDeadlineSeconds,PHASE:.status.phase'
    kubectl -n personal get events --field-selector=reason=FailedCreate --sort-by=.lastTimestamp

# Show the selected kubectl context and API server without contacting the cluster.
[group('cluster')]
context-show:
    @printf 'context: '
    @kubectl config current-context
    @printf 'server:  '
    @kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}{"\n"}'

# Enable automatic per-namespace wildcard HTTPS after the configured baseDomain
# is delegated. Persist the desired policy first with
# `nagarectl context create NAME --force --enable-external-tls`.
[group('cluster')]
cluster-enable-tls:
    @if [ -z "${NAGARE_UPGRADE_APPLY:-}" ]; then nagarectl platform guard; fi
    @nagarectl context show | rg -q '^export NAGARE_EXTERNAL_DOMAIN_TLS_ENABLED=1$' || { echo 'Set --enable-external-tls on the selected context before review' >&2; exit 2; }
    scripts/run-reviewed-bootstrap.sh

# EP-82 (docs/plans/82-local-cluster-registry-and-local-target-bootstrap-for-nagare.md):
# stand up the LOCAL development substrate — a k3d (k3s-in-Docker) cluster plus a
# managed local registry — so nagare can be exercised on a laptop with NO GCP
# account. Requires a running Docker daemon. Pair with `just local-bootstrap`.
# The first review creates the registry and cluster with the exact selected
# local substrate config. Later calls advance kubeconfig and cluster stages.
[group('local')]
local-up:
    @if [ -z "${NAGARE_UPGRADE_APPLY:-}" ]; then nagarectl platform guard; fi
    scripts/run-reviewed-bootstrap.sh

# EP-82: legacy teardown is available only before inventory admission. The
# reviewed registry has its own lifecycle and is not deleted with the cluster.
[group('local')]
local-down:
    @if [ -z "${NAGARE_UPGRADE_APPLY:-}" ]; then nagarectl platform guard; fi
    nagarectl inventory guard-legacy local-down
    k3d cluster delete nagare-local

# Reconcile the complete local bootstrap inventory against the selected k3d
# context, including its local CA, object store, auth plane, and observability.
# Requires the local context profile and immutable auth image references.
[group('local')]
local-bootstrap:
    @if [ -z "${NAGARE_UPGRADE_APPLY:-}" ]; then nagarectl platform guard; fi
    scripts/run-reviewed-bootstrap.sh

# EP-84 (docs/plans/84-local-data-services-and-gcs-free-backups-and-snapshots-for-nagare.md):
# reconcile the complete local inventory, including the MinIO object store used
# by `db backup`/`db restore` and `storage snapshot`/`storage restore`.
# In-cluster S3 endpoint:
# http://minio.nagare-system.svc.cluster.local:9000 (bucket nagare-backups) — the
# NAGARE_LOCAL_OBJECT_STORE contract value.
# Install the local MinIO object store for backups/snapshots (EP-84).
[group('local')]
local-minio:
    @if [ -z "${NAGARE_UPGRADE_APPLY:-}" ]; then nagarectl platform guard; fi
    scripts/run-reviewed-bootstrap.sh

# EP-5 (docs/plans/5-victoria-observability-stack-and-grafana.md): install the
# VictoriaMetrics/Logs/Traces stack + OpenTelemetry Collector + Grafana via Helm.
# The script owns the pinned chart versions and the install order; it is idempotent
# (helm upgrade --install). Assumes KUBECONFIG points at the cluster.
# Install the VictoriaMetrics/Logs/Traces + OTel + Grafana stack.
[group('cluster')]
observability:
    @if [ -z "${NAGARE_UPGRADE_APPLY:-}" ]; then nagarectl platform guard; fi
    scripts/run-reviewed-bootstrap.sh

# Deploy the typed hello example from an already accepted image publication.
# The image resource must name the exact context-registry hello:TAG image.
# Publish the image with `nagarectl app image-plan` first.
[group('apps')]
deploy-hello image_resource tag:
    nagarectl cluster guard
    nagarectl deploy --file cluster/examples/hello-knative-service/nagare/Config.hs --tag {{tag}} --image-resource {{image_resource}}

# Quick cluster status across all namespaces (pods and Knative services).
[group('apps')]
status:
    kubectl get pods -A
    kubectl get ksvc -A

# EP-6 (docs/plans/70-cli-and-operator-harness-ergonomics.md): stand up a
# workstation->cluster kube connection in one command — open the IAP port-22
# tunnel, layer an ssh -L forward of the k3s API (127.0.0.1:6443 -> :16443),
# fetch /etc/rancher/k3s/k3s.yaml and rewrite its server: to the forwarded
# port, and print the KUBECONFIG to export. Reuses scripts/iap-ssh.sh.
# Open a workstation->cluster kube connection in one command.
[group('test')]
live-test:
    scripts/live-test.sh

# MP-23: real restore/recovery logic with local request interpreters; no cloud.
[group('test')]
test-inventory-effects:
    python3 scripts/knative-collection-fixture.py --check
    cabal test nagarectl-test --project-dir=cli/nagarectl --test-options='-p effectful' --test-show-details=direct

# EP-119: enforce the production Haskell source contract and pinned formatting.
# Check Haskell structure, Fourmolu formatting, and Cabal manifest formatting.
[group('test')]
haskell-style-check:
    scripts/check-haskell-style.sh
    git ls-files -z 'cli/**/*.hs' | xargs -0 fourmolu --mode check --config cli/fourmolu.yaml --ghc-opt=-XImportQualifiedPost
    cabal-gild --mode check --input cli/nagare-dsl/nagare-dsl.cabal
    cabal-gild --mode check --input cli/nagarectl/nagarectl.cabal
    cabal-gild --mode check --input cli/nagare-access/nagare-access.cabal
    cabal-gild --mode check --input cli/nagare-harness/nagare-harness.cabal

# EP-174: the fast local gate the pre-push hook runs. Both Haskell suites
# (serially), the style check and the architecture check; logs go to
# ${XDG_STATE_HOME:-~/.local/state}/nagare/gates/logs/.
# Run the fast local gate (both Haskell suites, style, architecture).
[group('test')]
gate-fast:
    cabal run --project-dir=cli/nagare-harness -v0 nagare-harness -- gate --fast

# EP-177/EP-179 (ADR 25): the recovery model's deep tier over the explicit and
# generated scenarios: every placement alone, then every pair of placements
# whose faults can interact, run as parallel shards of the placements on the
# remote builder (`just test-remote`), for a committed revision. Each shard's
# log has `recovery-model:` progress lines and each violation, as it is found,
# as `recovery-model: violation:` lines. Its budget is one hour with the
# default 16 shards. `just deep-tier-required` says whether a change needs it.
# Run the recovery model's deep tier for a commit on the remote builder.
[group('test')]
gate-deep rev="HEAD" shards="16":
    #!/usr/bin/env bash
    set -euo pipefail
    specs=$(for i in $(seq 0 $(( {{shards}} - 1 ))); do printf '%s/%s ' "$i" "{{shards}}"; done)
    just test-remote '{{rev}}' '/deep tier/' "$specs" true

# EP-179 (ADR 25 amendment of 2026-10-06): list the recovery-related files
# changed since `base` (committed, uncommitted or untracked), and exit non-zero
# when there are any: such a change needs a passing `just gate-deep`.
# Report whether changes since a base need the recovery model's deep tier.
[group('test')]
deep-tier-required base="origin/master":
    #!/usr/bin/env bash
    set -euo pipefail
    inventory=cli/nagarectl/src/Nagare/Inventory
    paths=(
      "$inventory/Execute.hs" "$inventory/Execute/"
      "$inventory/Journal.hs" "$inventory/OperationStep.hs" "$inventory/Store.hs" "$inventory/Store/"
      "$inventory/Plan/CloseRecord.hs" "$inventory/Identity.hs"
      "$inventory/Adapter.hs" "$inventory/Adapters/" "$inventory/Collection/"
      "$inventory/DataFence.hs" "$inventory/DataFence/"
      "$inventory/LiveRestoreAdapter.hs" "$inventory/LiveRestoreFence.hs"
      "$inventory/MaintenanceAdapter.hs" "$inventory/MaintenanceFence.hs"
      cli/nagarectl/test/InventoryRecoveryModelSpec.hs cli/nagarectl/test/Nagare/Test/World/ cli/nagarectl/test/Nagare/Test/Model/
    )
    # Accept both `just deep-tier-required <ref>` and `base=<ref>`.
    base="{{base}}"
    base="${base#base=}"
    since=$(git merge-base "$base" HEAD)
    changed=$( { git diff --name-only "$since" -- "${paths[@]}"; git ls-files --others --exclude-standard -- "${paths[@]}"; } | sort -u)
    if [ -z "$changed" ]; then
      echo "deep tier not required: no recovery-related file changed since $base ($since)"
      exit 0
    fi
    echo "deep tier required: recovery-related files changed since $base ($since):"
    printf '  %s\n' $changed
    exit 1

# EP-174: the full gate for a candidate: clean tree, fast gate, a salted probe
# build on every remote system, `nix flake check --all-systems`, a dry-run
# proof that every check of every supported system is realised, and a record
# at ${XDG_STATE_HOME:-~/.local/state}/nagare/gates/<commit>.json.
# Run the full local gate and write the revision's gate record.
[group('test')]
gate:
    cabal run --project-dir=cli/nagare-harness -v0 nagare-harness -- gate --full

# EP-174: refuse a revision without a green, clean, fully realised gate record.
# Check that a revision has a green full-gate record (run before native work).
[group('test')]
gate-verify rev:
    cabal run --project-dir=cli/nagare-harness -v0 nagare-harness -- gate verify --revision {{rev}}

# Heavy nagarectl test runs go to the remote x86_64-linux builder, not the
# operator's machine (2026-10-06). Builds nix/test-runs.nix's testRun from the
# exact commit, so uncommitted changes are never what ran. shards is a
# space-separated list of NAGARE_RECOVERY_MODEL_SHARD values run in parallel;
# deep=true sets NAGARE_RECOVERY_MODEL_DEEP. Logs and per-shard exit codes are
# copied to ${XDG_STATE_HOME:-~/.local/state}/nagare/gates/logs/remote-*/.
# Run nagarectl tests for a commit on the remote builder.
[group('test')]
test-remote rev pattern shards="0/1" deep="false":
    #!/usr/bin/env bash
    set -euo pipefail
    commit=$(git rev-parse --verify '{{rev}}^{commit}')
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    label="${commit:0:8}-$stamp"
    shard_list=$(for spec in {{shards}}; do printf '"%s" ' "$spec"; done)
    expr="(builtins.getFlake \"git+file://$(git rev-parse --show-toplevel)?rev=$commit\").legacyPackages.x86_64-linux.testRun { label = \"$label\"; pattern = \"{{pattern}}\"; shards = [ $shard_list]; deep = {{deep}}; }"
    out=$(nix build --no-link --print-out-paths --print-build-logs --impure --expr "$expr")
    logs="${XDG_STATE_HOME:-$HOME/.local/state}/nagare/gates/logs/remote-$label"
    mkdir -p "$logs"
    cp "$out"/* "$logs"/
    chmod -R u+w "$logs"
    echo "test-remote: logs in $logs"
    cat "$logs/status"
    ! grep -qv ' exit=0 ' "$logs/status"

# The only way a revision reaches master (2026-10-06): it needs a green full
# gate record for its exact tree (`just gate` on a clean checkout of it), must
# descend from origin/master, and master moves by fast-forward only. Run from a
# clean master checkout. The push hook accepts the same record.
# Fast-forward master to a gate-verified revision and push it.
[group('test')]
land rev:
    #!/usr/bin/env bash
    set -euo pipefail
    target=$(git rev-parse --verify '{{rev}}^{commit}')
    just gate-verify "$target"
    [ "$(git rev-parse --abbrev-ref HEAD)" = master ] || { echo "land: run from a master checkout" >&2; exit 1; }
    [ -z "$(git status --porcelain)" ] || { echo "land: the checkout is dirty" >&2; exit 1; }
    git fetch origin master
    git merge-base --is-ancestor origin/master "$target" || { echo "land: $target does not descend from origin/master; rebase it and gate it again" >&2; exit 1; }
    git merge --ff-only "$target"
    git push origin master

# EP-174: build and run every fixture application with only its declared
# bindings (fixtures/inventory-release/local/fixture-smoke.json), plus the
# scenario-b-on-PostgreSQL negative. Refuses a Docker daemon hosting k3d.
# Smoke-run every acceptance fixture application locally.
[group('test')]
fixture-smoke *args:
    cabal run --project-dir=cli/nagare-harness -v0 nagare-harness -- fixture-smoke {{args}}

# EP-174: point git at the tracked hooks in .githooks/ (pre-push runs
# `just gate-fast`). Undo with `git config --unset core.hooksPath`.
# Install the tracked git hooks (pre-push runs the fast gate).
[group('test')]
install-hooks:
    git config core.hooksPath .githooks

# EP-5 (docs/plans/69-ci-pipeline-and-live-smoke-test.md): live smoke test.
# Starts the VM if needed, deploys a private-registry build-mode app, snapshots
# and RESTORES a volume (confirming a sentinel round-trips through GCS), verifies
# HTTP 200, and tears down. Requires the running VM + GCP credentials; this is
# NOT part of the per-PR offline CI (that is `nix flake check`).
# Run the live smoke test (deploy, volume snapshot/restore, HTTP 200, teardown).
[group('test')]
smoke:
    scripts/live-smoke.sh

# EP-86 (docs/plans/86): LOCAL smoke test — the cloud `smoke`'s zero-cloud twin.
# Assumes the EP-82 local cluster (stands it up with just local-up +
# local-bootstrap + local-minio if it is down); sets NAGARE_MODE=local so the GCP
# guardrail steps aside, deploys uploads-volume, round-trips a volume snapshot
# through local MinIO, verifies HTTP 200, and tears down. NO gcloud / IAP / GCS.
# Needs only Docker + the dev shell.
# Run the LOCAL smoke test (zero-cloud deploy, MinIO snapshot/restore, HTTP 200).
[group('test')]
local-smoke:
    scripts/local-smoke.sh
