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
  revisions:
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-14T04:20:01Z
      mode: "implement"
      note: "Implemented bounded Knative webhook readiness and patch retry checks"
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-14T23:06:40Z
      mode: "implement"
      note: "Hardened v0.3.0 readiness fixture after Linux CI evidence"
---

# Make cluster bootstrap wait for Knative webhooks

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

Full plan before trimming: [132-make-cluster-bootstrap-wait-for-knative-webhooks.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/132-make-cluster-bootstrap-wait-for-knative-webhooks.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

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

- [x] (2026-09-14 04:20Z) Added a bounded Knative ConfigMap patch helper and hermetic tests for
  successful retry, exhaustion, and bootstrap command ordering.
- [x] (2026-09-14 04:20Z) Put explicit Knative Serving and net-certmanager webhook waits in the
  cloud recipe, and the Knative Serving wait in the local recipe, before their dependent patches.
- [x] (2026-09-14 04:25Z) Proved one-shot success on disposable k3d cluster
  `nagare-webhook-readiness-49505`: the first bootstrap exited 0, the webhook rolled out with an
  endpoint, all four local ConfigMaps held the expected values, the original error was absent, the
  second idempotence run exited 0, and the trap deleted the cluster.
- [x] (2026-09-14 04:35Z) Updated bootstrap documentation, the changelog, IR-21, and the
  improvement-request bundle log; the direct test, focused Nix checks, 23-concept OKF validation,
  and all 23 native flake checks passed, including 486 `nagarectl` tests.

## Surprises & Discoveries

- Observation: A flake build does not include a newly created untracked test script in its source
  snapshot, even though the direct test can execute it from the working tree. Staging the two new
  scripts is therefore required before the new derivation can validate them.
  Evidence: the first readiness build exited 1 with
  `bash: scripts/test-knative-bootstrap-readiness.sh: No such file or directory`; the separately
  evaluated `shellcheck-scripts` derivation exited 0.

- Observation: The first disposable-cluster attempt could not reach Kubernetes API readiness because
  the restarted Colima VM had `fs.inotify.max_user_instances = 128` while two pre-existing k3d
  clusters were also running. Raising that transient VM limit to 8192 let the isolated acceptance
  proceed; no Nagare code change was needed for this host constraint.
  Evidence: the failed k3s log included `inotify_init: too many open files`. The successful retry
  produced:

  ```text
  live-test: first local-bootstrap exit=0
  deployment "webhook" successfully rolled out
  live-test: webhook endpoints=10.42.0.11
  live-test: config-network={"autocreate-cluster-domain-claims":"true","ingress-class":"kourier.ingress.networking.knative.dev"}
  live-test: config-domain={"127-0-0-1.sslip.io":""}
  live-test: config-features={"kubernetes.podspec-persistent-volume-claim":"enabled","kubernetes.podspec-persistent-volume-write":"enabled"}
  live-test: config-deployment={"registriesSkippingTagResolving":"kind.local,ko.local,dev.local,k3d-registry.localhost:5000"}
  live-test: second local-bootstrap exit=0
  live-test: PASS
  ```

- Observation: A test can be launched with Nix-provided Bash while still escaping the pure Linux
  closure through a directly executed helper or fake executable. Evidence: v0.3.0 release CI reached
  `knative-bootstrap-readiness`, then failed on the helper's `/usr/bin/env` shebang; invoking the
  helper through Bash and rendering the same Bash path into fake kubectl made the focused pure-build
  check pass without changing runtime behavior.

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

- Decision: Complete the plan without amending ADR 6 or creating another ADR after the final
  distillation pass.
  Rationale: implementation preserved ADR 6 exactly: every new failure gate remains before
  `nagarectl platform stamp`, while the retry counts, delays, and rollout deadlines are narrow
  operational tuning documented in the recipes, helper, tests, and runbooks. No durable interface
  ownership or architectural boundary changed.
  Date: 2026-09-14.

## Outcomes & Retrospective

Cloud and local bootstrap now wait up to five minutes for the validating webhooks that guard their
next ConfigMap changes. Cloud bootstrap additionally gates `config-certmanager` on the
net-certmanager webhook. All convergent Knative ConfigMap merge patches use one bounded helper with
five attempts and two-second delays, while the already-best-effort JSON key removal remains direct.
The final platform stamp is still later than every gate and patch.

The hermetic regression test proved success after two transient failures, exact exhaustion after
three permanent failures with the final kubectl status preserved, and the complete cloud/local
dry-run ordering. A new k3d cluster then proved the user-visible result: the first
`just local-bootstrap` exited 0, the webhook rolled out with endpoint `10.42.0.11`, the four expected
ConfigMaps contained their desired values, the original no-endpoints error was absent, and an
idempotence rerun also exited 0. The test cluster was deleted by its trap.

The v0.3.0 release audit additionally made the hermetic fixture self-contained in the pure Linux
builder by using the check-provided Bash for both the helper and fake kubectl.

Documentation and `CHANGELOG.md` describe the actual waits and retries, and IR-21 is completed with
its target-plan link intact. `okf validate` accepted all 23 improvement requests. The direct and
focused Nix checks passed, and `nix flake check --print-build-logs` passed all 23 native checks,
including all 486 `nagarectl` tests. No cloud cluster was consumed; the plan intentionally treats
fresh-cloud evidence as optional because local integration plus deterministic cloud ordering covers
the regression without a billable environment.

