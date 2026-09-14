---
id: 132
slug: make-cluster-bootstrap-wait-for-knative-webhooks
title: "Make cluster bootstrap wait for Knative webhooks"
kind: exec-plan
created_at: 2026-09-14T03:39:09Z
intention: "intention_01m2ezt5bqew0r49we2pmwjydp"
provenance:
  created_by:
    model: "gpt-5.6-sol"
    harness: "codex-cli"
    at: 2026-09-14T03:39:09Z
---

# Make cluster bootstrap wait for Knative webhooks

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

On a newly created cluster, `nagare cluster-bootstrap` currently installs Knative Serving and then
patches Knative-owned ConfigMaps before Knative's validating webhook has any ready endpoint. The
Kubernetes API server rejects the patch, the recipe exits partway through, and the operator must run
the same otherwise-idempotent recipe a second time. This is the failure recorded in
[IR-21](../improvement-requests/cluster-bootstrap-races-the-knative-webhook.md).

After this change, both cloud and local bootstrap wait for the Knative Serving webhook with an
explicit deadline before changing any Knative ConfigMap. Cloud bootstrap also waits for the
net-certmanager webhook before patching `config-certmanager`. Each convergent ConfigMap merge patch
gets a short bounded retry so the small interval between Deployment readiness and Service endpoint
publication does not turn a healthy first boot into a failed run. An operator can see the result by
running local bootstrap once against a brand-new disposable k3d cluster: the command exits zero,
the expected ConfigMap values are present, and no second invocation is needed.


## Progress

- [ ] Add a bounded Knative ConfigMap patch helper and hermetic tests for successful retry,
  exhaustion, and bootstrap command ordering.
- [ ] Put explicit Knative Serving and net-certmanager webhook waits in the cloud recipe, and the
  Knative Serving wait in the local recipe, before their dependent patches.
- [ ] Prove one-shot success on a newly created disposable k3d cluster and record the observed
  rollout, endpoint, ConfigMap, and exit-status evidence here.
- [ ] Update bootstrap documentation, the changelog, IR-21, and the improvement-request bundle log;
  run the focused checks and the repository gate.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Wait at most five minutes for each validating-webhook Deployment.
  Rationale: fresh clusters may need to pull every control-plane image, so a short application-level
  timeout such as 30 seconds would create a new first-boot race. Five minutes is bounded, gives the
  existing pinned stack time to start, and produces a normal `kubectl rollout status` failure when a
  Deployment is genuinely unhealthy.
  Date: 2026-09-14.

- Decision: Retry only idempotent Knative ConfigMap merge patches through a small shell helper, with
  five attempts separated by two seconds, while leaving the best-effort JSON removal of
  `svc.cluster.local` outside the helper.
  Rationale: a merge patch can be safely submitted again after an ambiguous or transient API-server
  response. The JSON removal deliberately tolerates an already-absent key and is not useful to retry.
  Retrying all failures avoids coupling correctness to unstable webhook error prose; invalid patches
  still fail after a bounded eight-second delay and preserve kubectl's final exit status.
  Date: 2026-09-14.

- Decision: Exercise the first-run acceptance against a separately named disposable k3d cluster
  instead of deleting or reusing the developer's `nagare-local` cluster.
  Rationale: a distinct cluster provides the empty-cluster precondition without destroying unrelated
  local applications or depending on residual webhook endpoints. A trap removes only the cluster the
  test created.
  Date: 2026-09-14.

- Decision: Treat ADR 6 as the only relevant local architecture decision and do not create a new ADR
  merely for retry constants.
  Rationale: [ADR 6](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md)
  makes the final cluster stamp an observed completion marker, so waits and retries must remain before
  `nagarectl platform stamp`. The exact timeout and retry count are task-local operational tuning, not
  a new architectural boundary. No cross-repository ADR is needed.
  Date: 2026-09-14.


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Nagare's `justfile` is the operator command catalogue. Its `cluster-bootstrap` recipe targets a cloud
k3s cluster, while `local-bootstrap` installs the same HTTP-first Knative stack in a developer's k3d
cluster. A webhook is an HTTPS callback that the Kubernetes API server invokes before accepting a
matching object change. The Knative release registers a fail-closed validating webhook for labeled
Knative ConfigMaps, so those ConfigMaps cannot be patched while Service `webhook` has no ready
endpoint.

The cloud recipe in `justfile` currently applies cert-manager, waits without a deadline for
`cert-manager-webhook`, renders the context-owned ClusterIssuer, applies Knative Serving CRDs and
`serving-core.yaml`, applies Kourier, and immediately patches `config-network` and `config-domain`.
It then applies net-certmanager and immediately patches `config-certmanager`, `config-features`, and
`config-deployment`. Only after all those commands succeed does it run `nagarectl platform stamp`.
The local recipe has the same unsafe transition after `serving-core.yaml`, but skips the cloud issuer
and `config-certmanager` patch by design. Both recipes are convergent: applying the same manifests and
merge patches again should leave the same desired state.

`cluster/bootstrap/knative-serving/README.md` documents the Knative resource names and ConfigMap
patch order. `cluster/bootstrap/net-certmanager/README.md` documents the independent v1.14.0 pin but
currently waits only for its controller. `docs/user/cluster-bootstrap.md` is the operator runbook and
currently lists installation order without explaining the webhook gates or bounded retries.
`CHANGELOG.md` holds the unreleased user-visible fixes.

The static shell checks are declared in `nix/checks/scripts.nix`. Scripts under `scripts/*.sh` are
already included in its `shellcheck-scripts` derivation. Existing tests such as
`scripts/test-render-context-template.sh` create fake executables in a temporary `PATH` and use
environment variables to drive deterministic cases; the new retry test should follow that pattern.
`nix/checks/scripts/nagare-clone-free-platform.sh` already checks the packaged recipe's
`cluster-bootstrap` dry run, so the focused new check must complement rather than weaken that package
test.

The original stack implementation is recorded in
`docs/plans/4-knative-serving-kourier-ingress-and-cert-manager-tls.md`, and the local k3d twin is
recorded in `docs/plans/82-local-cluster-registry-and-local-target-bootstrap-for-nagare.md`. They are
useful history, but this plan contains the complete change and does not require the implementer to
reconstruct either earlier plan.

The ADR scan found one relevant record. [ADR 6](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md)
requires cloud and local bootstrap to stamp the cluster only after every earlier command succeeds;
the waits, retries, and verification in this plan preserve that meaning. No ADR specifically governs
Knative webhook readiness, and no cross-repository ADR is relevant.


## Plan of Work

### Milestone 1: Make bootstrap sequencing bounded and testable

Create `scripts/retry-knative-configmap-patch.sh`. Its command-line interface is a ConfigMap name
followed by the options accepted by `kubectl patch`, for example
`scripts/retry-knative-configmap-patch.sh config-network --type merge --patch DATA`. It always targets
namespace `knative-serving` and resource type `configmap`. It defaults to five attempts and a
two-second delay; `NAGARE_KNATIVE_PATCH_MAX_ATTEMPTS` and
`NAGARE_KNATIVE_PATCH_RETRY_DELAY_SECONDS` may override those values for the hermetic test. On a
failed non-final attempt it prints the ConfigMap name and attempt count to standard error, and on the
final failure it returns kubectl's status. Keep the script narrowly scoped instead of making a
general command retry framework.

In both `cluster-bootstrap` and `local-bootstrap` in `justfile`, add
`kubectl -n knative-serving rollout status deploy/webhook --timeout=5m` immediately after applying
`serving-core.yaml`. In cloud `cluster-bootstrap`, add the corresponding
`deploy/net-certmanager-webhook --timeout=5m` wait after applying net-certmanager and before patching
`config-certmanager`. Add `--timeout=5m` to the existing cert-manager webhook waits as well so every
bootstrap webhook gate is bounded. Route the merge patches for `config-network`, `config-domain`,
`config-certmanager`, `config-features`, and `config-deployment` through the new helper in whichever
recipe currently performs each patch. Keep the JSON removal of `/data/svc.cluster.local` as the
existing direct `kubectl ... || true` command. Keep every wait and retry before `nagarectl platform
stamp`.

Add `scripts/test-knative-bootstrap-readiness.sh` and a `knative-bootstrap-readiness` derivation in
`nix/checks/scripts.nix`. The test puts a recording fake `kubectl` and a no-delay fake or configured
`sleep` in a temporary `PATH`. Prove that the helper succeeds after two failures with exactly three
kubectl invocations, and that permanent failure stops at the configured attempt bound with a nonzero
status. Use `just --dry-run cluster-bootstrap` and `just --dry-run local-bootstrap` to assert the main
webhook wait is after `serving-core.yaml` and before the first Knative ConfigMap patch in both recipes,
and assert the net-certmanager webhook wait is between its manifest and `config-certmanager` patch in
the cloud recipe. Also assert every new wait carries `--timeout=5m` and the final platform stamp stays
after all patches. This milestone is accepted when the new Nix check and `shellcheck-scripts` both
build successfully and the dry-run transcript visibly has the intended order.

### Milestone 2: Prove the first invocation on an empty cluster

Create a uniquely named disposable k3d cluster using the same `k3s_image` pin as `just local-up`, but
without host port mappings or a registry because this test installs only the platform control plane.
Point `KUBECONFIG` only at that cluster, set the local domain and registry variables, and set
`NAGARE_UPGRADE_APPLY=1` so this isolated verification does not require or write an operator context's
platform-version marker. Run `just local-bootstrap` exactly once while capturing its exit status and
output. Then confirm the `webhook` Deployment completed its rollout, Service `webhook` has at least
one endpoint, all four locally patched ConfigMaps contain the expected data, and the output contains
no `no endpoints available for service \"webhook\"` error. Run `just local-bootstrap` a second time
only as an idempotence check, not as a way to make the first run pass. Always delete the specifically
named test cluster through a shell trap. This milestone is accepted only if the first invocation exits
zero from a genuinely empty cluster.

The local recipe deliberately cannot exercise the cloud-only `config-certmanager` patch. Its order is
covered hermetically in Milestone 1, and final live cloud acceptance remains one first invocation of
`nagare cluster-bootstrap` on a newly provisioned operator cluster when one is available. Do not make
access to a billable cloud cluster a prerequisite for merging the deterministic fix.

### Milestone 3: Publish the behavior and close the request

Update `cluster/bootstrap/knative-serving/README.md`,
`cluster/bootstrap/net-certmanager/README.md`, and `docs/user/cluster-bootstrap.md` to show the
readiness gates, five-minute timeout, and bounded merge-patch retry. Add an IR-21 item to the
`CHANGELOG.md` Unreleased section. After all validation passes, change
`docs/improvement-requests/cluster-bootstrap-races-the-knative-webhook.md` from `accepted` to
`completed`, advance its `timestamp`, add `completedAt` and a concise `resolution`, preserve its
`targetPlan`, and add the matching completion entry to `docs/improvement-requests/log.md`.

Run the focused checks, improvement-request validation, and the full current-system flake gate.
Update this plan's Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective with
the exact evidence. Revisit ADR distillation: amend ADR 6 only if implementation changes the meaning
or placement of the completion stamp; do not create an ADR solely to memorialize timing constants.
This milestone is accepted when the docs describe the actual commands, IR-21 is completed with its
bidirectional plan link intact, and all applicable checks pass or any pre-existing unrelated baseline
failure is recorded with evidence.


## Concrete Steps

Work from `/Users/shinzui/Keikaku/bokuno/nagare`. First run the hermetic focused checks after
Milestone 1:

```bash
bash scripts/test-knative-bootstrap-readiness.sh
nix build .#checks.aarch64-darwin.knative-bootstrap-readiness --print-build-logs
nix build .#checks.aarch64-darwin.shellcheck-scripts --print-build-logs
```

The direct script should end with a concise success line, and both Nix builds should exit zero:

```text
ok: Knative ConfigMap patches retry and preserve the final failure
ok: cloud and local bootstrap wait before dependent patches
knative bootstrap readiness tests: PASS
```

For the clean-cluster verification, use an explicit name and a trap so no existing local cluster is
deleted. Confirm the `k3s_image` value in `justfile` before copying it into the command if the pin has
changed since this plan was written.

```bash
set -o pipefail
test_cluster=nagare-webhook-readiness
trap 'k3d cluster delete "$test_cluster" >/dev/null 2>&1 || true' EXIT
k3d cluster create "$test_cluster" \
  --image rancher/k3s:v1.34.6-k3s1 \
  --k3s-arg '--disable=traefik@server:0'
test_kubeconfig="$(k3d kubeconfig write "$test_cluster")"
KUBECONFIG="$test_kubeconfig" \
NAGARE_UPGRADE_APPLY=1 \
NAGARE_MODE=local \
NAGARE_BASE_DOMAIN=127-0-0-1.sslip.io \
NAGARE_REGISTRY_HOST=k3d-registry.localhost:5000 \
  just local-bootstrap 2>&1 | tee /tmp/nagare-webhook-first-bootstrap.log
bootstrap_status=$?
test "$bootstrap_status" -eq 0
KUBECONFIG="$test_kubeconfig" kubectl -n knative-serving rollout status deploy/webhook --timeout=30s
KUBECONFIG="$test_kubeconfig" kubectl -n knative-serving get endpoints webhook
KUBECONFIG="$test_kubeconfig" kubectl -n knative-serving get configmap \
  config-network config-domain config-features config-deployment
! rg 'no endpoints available for service "webhook"' /tmp/nagare-webhook-first-bootstrap.log
```

Enable `set -o pipefail` in the verification shell before this transcript so the captured pipeline
status cannot hide a failing `just` command. The expected rollout and endpoint evidence is similar
to:

```text
deployment "webhook" successfully rolled out
NAME      ENDPOINTS          AGE
webhook   10.42.0.12:8443   2m
```

Run the second invocation with the same environment and require exit zero to prove convergence.
Then run the metadata and repository gates:

```bash
okf validate docs/improvement-requests \
  --profile docs/improvement-requests/profile.dhall \
  --profile-enforce \
  --log-enforce
nix flake check --print-build-logs
```

Commit implementation in working states. Every commit must use Conventional Commits and include
both active trailers, for example:

```text
fix(cluster): wait for Knative webhooks during bootstrap

ExecPlan: docs/plans/132-make-cluster-bootstrap-wait-for-knative-webhooks.md
Intention: intention_01m2ezt5bqew0r49we2pmwjydp
```


## Validation and Acceptance

The hermetic acceptance test must prove behavior rather than merely grep for filenames. With a fake
kubectl that fails twice and then succeeds, the helper invokes it exactly three times and exits zero.
With a permanently failing fake and `NAGARE_KNATIVE_PATCH_MAX_ATTEMPTS=3`, it invokes kubectl exactly
three times, reports exhaustion, and exits nonzero. Recipe dry runs prove that the main Knative
webhook wait precedes every Knative ConfigMap merge patch in cloud and local flows, that the
net-certmanager wait precedes the cloud `config-certmanager` patch, that all waits are bounded, and
that stamping remains last.

The required integration acceptance is a fresh disposable k3d cluster on which the first and only
`just local-bootstrap` invocation exits zero. Before any rerun, Service `webhook` must expose at least
one address, the Knative webhook Deployment must be successfully rolled out, `config-network` must
select Kourier, `config-domain` must contain `127-0-0-1.sslip.io`, `config-features` must contain the
repository's PVC feature values, and `config-deployment` must include
`k3d-registry.localhost:5000`. The captured first-run output must not contain the original
`no endpoints available` error. A second invocation must also exit zero and leave those values
unchanged.

Cloud acceptance, when a brand-new operator cluster is available, is one
`nagare cluster-bootstrap` invocation exiting zero, followed by ready `webhook` and
`net-certmanager-webhook` rollouts and a `config-certmanager` whose `issuerRef` points to
`letsencrypt-dns`. This is stronger environment evidence but is not needed to establish the local
regression fix.


## Idempotence and Recovery

The helper retries only merge patches, which converge on the same data when repeated. Applying the
upstream manifests, waiting for an already-ready Deployment, and rerunning either bootstrap recipe
are also safe. The existing best-effort removal of `svc.cluster.local` remains outside the retry
helper because an absent key is already treated as success by `|| true`.

A timeout or exhausted retry must stop the recipe before `nagarectl platform stamp`, preserving ADR
6's rule that the stamp records completion rather than intent. Diagnose a timeout with
`kubectl -n knative-serving describe deploy/webhook`, `kubectl -n knative-serving get pods`, and
`kubectl -n knative-serving get endpoints webhook`; after correcting image-pull, scheduling, or
network problems, rerun the same bootstrap command. Do not delete webhook configurations to bypass
fail-closed admission.

The live verification owns only `nagare-webhook-readiness`. Its EXIT trap may be rerun safely, and
`k3d cluster delete nagare-webhook-readiness` is the explicit cleanup if the shell is interrupted
before the trap runs. Never use `just local-down` for this test because that targets the developer's
separate `nagare-local` cluster.


## Interfaces and Dependencies

`scripts/retry-knative-configmap-patch.sh` is the only new runtime interface. It has this contract:

```text
scripts/retry-knative-configmap-patch.sh CONFIGMAP KUBECTL_PATCH_ARGUMENT...

Environment:
  NAGARE_KNATIVE_PATCH_MAX_ATTEMPTS          positive integer, default 5
  NAGARE_KNATIVE_PATCH_RETRY_DELAY_SECONDS   nonnegative sleep duration, default 2

Effect:
  kubectl -n knative-serving patch configmap CONFIGMAP KUBECTL_PATCH_ARGUMENT...
```

It depends only on Bash, kubectl, and sleep/coreutils, all already present in Nagare's operator and
development environments. It must preserve argument boundaries so JSON and YAML patch bodies are
passed unchanged. It must not interpret patch content or fetch manifests.

The Kubernetes resources are fixed by the already pinned authoritative manifests:
`serving-core.yaml` from Knative Serving v1.22.0 supplies `deployment/webhook` and `service/webhook`;
net-certmanager v1.14.0 supplies `deployment/net-certmanager-webhook` and
`service/net-certmanager-webhook`. No version bound or pin changes in this plan. The local Mori
registry has no Knative project, so those exact release artifacts were inspected upstream after the
required registry lookup. kubectl's existing `rollout status ... --timeout=5m` interface supplies the
bounded readiness wait; no new library dependency is introduced.
