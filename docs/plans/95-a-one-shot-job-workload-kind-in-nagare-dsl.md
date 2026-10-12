---
id: 95
slug: a-one-shot-job-workload-kind-in-nagare-dsl
title: "A one-shot job workload kind in nagare-dsl"
kind: exec-plan
created_at: 2026-07-14T19:28:25Z
intention: "intention_01kxh323kyegvvmkqscf59nahr"
master_plan: "docs/masterplans/18-platform-prerequisites-for-the-agent-content-plane-forge-credentials-a-one-shot-job-kind-and-a-nix-binary-cache.md"
---

# A one-shot job workload kind in nagare-dsl

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

Full plan before trimming: [95-a-one-shot-job-workload-kind-in-nagare-dsl.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/95-a-one-shot-job-workload-kind-in-nagare-dsl.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

`nagare-dsl` will gain a sixth workload kind, `Job`, for a single bounded execution.
A `Config.hs` can describe an image/build, command, runtime environment, resources,
deadline, retry count, cleanup TTL, and sized ephemeral scratch directory without
pretending the run is a scheduled `Task` or a continuously reconciled `Worker`.
Rendering produces a deterministic `batch/v1` Job plus its restricted ServiceAccount
and default-deny NetworkPolicy.

The result is visible at two levels. The Haskell config round-trips through the current
config-as-program loader and renders byte-for-byte golden YAML. On the live k3s cluster,
the rendered workload completes with `/scratch` writable, its root filesystem read-only,
no Kubernetes API token, and no egress unless a separate allow policy is applied. A
namespace quota admits at most two deadline-bounded Pods at once and reports excess work
as Job `FailedCreate` events that a caller can treat as backpressure.

## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-07-14 13:05 PDT) Added the public `Job` model, shared command type,
  smart validation, preset, and deterministic naming while preserving Worker re-exports.
- [x] (2026-07-14 13:05 PDT) Added Job JSON emission/loading, a Config.hs fixture,
  and round-trip/kind-discrimination validation; the full DSL suite passed 372 tests.
- [x] (2026-07-14 13:15 PDT) Added deterministic ServiceAccount, default-deny
  NetworkPolicy, and hardened Job renderers with four goldens; 381 tests passed
  on two consecutive runs and all pre-existing Task/Worker goldens remained unchanged.
- [x] (2026-07-14 13:43 PDT) Added the terminating-Pod ResourceQuota,
  idempotent bootstrap/status recipes, and a compiled agent-run example with
  quota, immutable-input, network, scratch, and cleanup guidance.
- [x] (2026-07-14 14:05 PDT) Passed all 381 DSL tests, the focused Nix DSL/example/shell
  checks, server-side dry-run, and live hardening, TTL cleanup, steady-state deny/narrow
  allow, and three-Job quota acceptance on local k3s. The aggregate flake check remains
  blocked by the unrelated credentialed `nagare-access` dependency described below.

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Discovery: The Kikan conformance file still does not exist, and its embedded draft
  predates three fields required by this ExecPlan: `parallelism: 1`, `completions: 1`,
  and the Pod-template `activeDeadlineSeconds` used by the Terminating quota.
  Evidence: `test -f .../nagare-prereqs/agent-run.job.yaml` exited 1; the embedded
  specimen contains only the Job-level deadline and omits parallelism/completions.

- Discovery: Moving Task's environment/resource rendering and key comparison into
  `Nagare.Dsl.Batch.Render` did not perturb its golden bytes.
  Evidence: both existing Task golden tests and all Worker golden tests passed as part
  of two consecutive 381-test runs after the extraction.

- Discovery: The plan's `nix fmt` command is unavailable on this aarch64-darwin
  checkout because the flake exports no formatter for that system.
  Evidence: `nix fmt` exited 1 with `does not provide attribute
  'formatter.aarch64-darwin'`; `flake.nix` also documents why the pinned Fourmolu is
  intentionally not used as a whole-tree formatting check.

- Discovery: Even `kubectl apply --dry-run=client` attempted to download the active
  GKE context's OpenAPI schema and could not refresh its non-interactive gcloud token.
  Evidence: validation failed while fetching `/openapi/v2` from `35.247.110.193` with
  `Reauthentication failed`; server-side and live acceptance therefore require renewed
  credentials or a usable local context.

- Discovery: The existing `k3d-nagare-local` context supplied a healthy k3s
  `v1.34.6+k3s1` acceptance target after starting its stopped Colima runtime. The
  checked-in Job golden passed server-side dry-run there without writing to the unrelated
  active GKE cluster. The original `sennari` context and stopped Colima state were restored
  after cleanup.

- Discovery: k3s's embedded kube-router controller enforces the default-deny policy after
  reconciliation, but it is not a fail-closed startup barrier for a newly allocated Pod IP.
  Evidence: an immediate BusyBox TCP probe reached `1.1.1.1:80` even though its policy had
  existed for minutes; iptables contained the policy chain but no rule for that short-lived
  Pod IP. Repeating the probe after a 15-second in-Pod delay produced `egress=blocked`.
  A separate additive policy restricted to `1.1.1.1/32` TCP/80 then produced
  `egress=target-allowed` and `egress=non-target-blocked` for `1.0.0.1:80`.

- Discovery: The aggregate `nix flake check` is blocked by an unrelated credentialed
  dependency in the `nagare-access` check. Its sandboxed Cabal build exited 128 while
  cloning from GitHub with `could not read Username`; Nix cancelled the other checks.
  The Job-relevant DSL, example, and shell checks were therefore also run individually.

## Decision Log

Record every decision made while working on the plan.

- Decision: Associate implementation work and commits with Intention
  `intention_01kxh323kyegvvmkqscf59nahr`, replacing the intention originally recorded
  when this plan was drafted.
  Rationale: The user explicitly selected this Intention ID for the implementation
  session, and the ExecPlan workflow requires the active intention to be reflected in
  frontmatter and commit trailers.
  Date: 2026-07-14

- Decision: Treat `cli/nagare-dsl/test/golden/job-agent-run.job.yaml` as the
  provider-side conformance source until Kikan creates its standalone fixture, and
  include every explicit field required by this ExecPlan even where the older embedded
  Kikan draft relied on Kubernetes defaults.
  Rationale: The current plan explicitly requires one completion, one-way parallelism,
  and matching Job/Pod deadlines; omitting them would weaken determinism and make the
  ResourceQuota fail to select the Pod. The Context section already designates the
  Nagare golden as authoritative while Kikan's fixture is absent.
  Date: 2026-07-14

- Decision: Share a context-parameterized deterministic key comparator rather than one
  global rank table between Task and Job renderers.
  Rationale: YAML key names such as `env`, `envFrom`, and `securityContext` need different
  relative positions in the established Task contract and the hardened Job contract.
  Sharing the comparison algorithm and batch value helpers preserves existing Task bytes
  while keeping both renderers deterministic.
  Date: 2026-07-14

- Decision: Add a first-class `Job`; do not extend `Task` with a missing schedule or use
  `kubectl create job --from=cronjob` as the public model.
  Rationale: A programmatic run has no scheduling policy or history limits. Making those
  fields nullable would weaken both workload types and keep one-shot runs second-class.
  Date: 2026-07-14

- Decision: Fix `restartPolicy` to `Never` and hardening defaults in the renderer rather
  than expose them as optional user choices.
  Rationale: This kind is the locked-down one-shot substrate. A caller may choose retry
  count and deadline, but cannot turn it into an indefinitely restarting or privileged
  general Pod.
  Date: 2026-07-14

- Decision: Reuse `Worker`'s validated `Command` through a common module and factor shared
  batch-render helpers out of `Task.Render` without changing existing Task bytes.
  Rationale: Copying argv validation and YAML ordering would create two subtly different
  APIs. Existing Task and Worker goldens protect the compatibility-preserving refactor.
  Date: 2026-07-14

- Decision: Render conservative request/limit defaults when `jobResources` is `Nothing`
  and reject a `Just Resources` value unless all four request/limit fields are present.
  Rationale: The public input remains consistent with other workload records while every
  Job emitted by this hardened kind has schedulable requests and explicit limits.
  Date: 2026-07-14

- Decision: Enforce the two-Pod bound with a `ResourceQuota` scoped to Kubernetes
  `Terminating` Pods.
  Rationale: `Terminating` selects Pods whose own `spec.activeDeadlineSeconds` is set;
  ResourceQuota cannot select labels. The Job controller copies the Pod template but does
  not copy the Job-level deadline into that template, so the renderer must put the same
  validated deadline at both Job and Pod level. Exceeding quota rejects Pod creation; the
  Job remains and reports `FailedCreate`, so the future scheduler must observe Job
  events/status and retry rather than assume a third Pending Pod exists.
  Date: 2026-07-14

- Decision: Use the existing k3s network-policy controller and prove it with a live probe.
  Rationale: `nixos/hosts/nagare-01/k3s.nix` does not set
  `--disable-network-policy`; k3s therefore runs its embedded kube-router policy
  controller. Installing another controller would add conflict without adding isolation.
  Date: 2026-07-14

- Decision: Document the kube-router convergence window as a production isolation gap
  instead of describing the base NetworkPolicy as fail-closed from process start.
  Rationale: The delayed deny and narrow allow probes prove steady-state rule enforcement,
  while the immediate successful connection proves that this manifest/controller pair
  cannot safely launch untrusted code that sends traffic before the Pod-specific rule is
  programmed. Hiding the distinction would overstate the delivered security property;
  the target CNI or a separate admission-time mechanism must close it before production.
  Date: 2026-07-14

- Decision: Make the Attic client ConfigMap an optional, typed Job input.
  Rationale: EP-3 of the parent MasterPlan owns `nagare-nix-cache-client`; mounting it at
  `/etc/nix/nix.conf` lets Nix-capable Jobs substitute without coupling every Job to the
  cache or duplicating configuration in environment variables.
  Date: 2026-07-14

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

The repository now has a first-class, validated one-shot `Job` model with config-as-program
round-tripping and deterministic rendering of a tokenless ServiceAccount, default-deny
NetworkPolicy, and hardened `batch/v1` Job. The renderer fixes parallelism/completions at
one, emits explicit resources and sized scratch, duplicates the validated deadline at Job
and Pod level, and supports an opt-in Nix client ConfigMap without granting network access.
All 381 DSL tests passed, including the four new goldens and every pre-existing Task and
Worker golden. The focused Nix DSL, example-compilation, and shell checks also passed.

The cluster milestone installed an idempotent two-slot `Terminating` ResourceQuota and
proved its exact backpressure contract: two default Pods consumed the full pool, the third
Job had repeated `FailedCreate/exceeded quota` events and no Pod, and deleting one admitted
Job caused the third Pod to be created. A separate hardened probe logged `uid=65532`,
`root=readonly`, `scratch=writable`, and `api-token=absent`, completed successfully, and was
deleted by its TTL; its separately applied ServiceAccount and NetworkPolicy were then
removed explicitly. The checked-in Job bundle also passed Kubernetes server-side dry-run.

Steady-state network enforcement was demonstrated with a denied outbound probe and an
additive `/32` TCP/80 policy that allowed its target while continuing to deny another IP.
The immediate-start probe exposed a residual security boundary: this kube-router dataplane
programs new Pod-IP rules asynchronously, so the base manifest is not a fail-closed startup
barrier. The example documentation now says so plainly. Production use with untrusted agent
code still needs a target CNI or admission-time isolation mechanism that proves enforcement
before the workload process starts.

Two integrations remain outside this child's completion boundary. Kikan has not created
the standalone conformance fixture, so its consumer copy still needs the corrected Pod
deadline plus explicit parallelism/completions before byte comparison. EP-3 has not yet
provided `nagare-nix-cache-client`, so the live cache substitution check remains the parent
MasterPlan's soft integration acceptance. The aggregate `nix flake check` is also not green
because the unrelated `nagare-access` derivation cannot clone a credentialed GitHub
dependency in its sandbox; all checks Nix cancelled as a result were rerun individually.

