---
id: 18
slug: platform-prerequisites-for-the-agent-content-plane-forge-credentials-a-one-shot-job-kind-and-a-nix-binary-cache
title: "Platform prerequisites for the agent content plane — forge credentials, a one-shot job kind, and a Nix binary cache"
kind: master-plan
created_at: 2026-07-14T19:28:20Z
intention: "intention_01kx3qz212e989078m6ssetr2b"
---

# Platform prerequisites for the agent content plane — forge credentials, a one-shot job kind, and a Nix binary cache

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

After this initiative, workloads in the `personal` cluster namespace can obtain
short-lived, role-named GitHub credentials without embedding a personal access token;
Nagare users can describe and render a hardened, bounded, one-shot Kubernetes Job as a
first-class `nagare-dsl` workload; and both laptops and cluster workloads can exchange
Nix build products through a Nagare-operated Attic cache backed by durable cloud
storage. These are the three platform prerequisites requested by
`mori://shinzui/kikan/plans/27-author-nagare-s-platform-prerequisites-forge-credentials-a-one-shot-job-kind-and-a-nix-binary-cache`.

The scope includes the Nagare host configuration and secret-refresh mechanism, the
public Haskell Job API and its deterministic Kubernetes renderer, the quota and network
policy bootstrap resources needed by that Job kind, the Pulumi storage resources and
raw cluster bootstrap component for Attic, and operator/user documentation with live
acceptance procedures. It does not implement Kikan's content-plane contracts,
repository mirror, Shikigami scheduler, or Kotei evaluation service. It also does not
expose Attic on a public ingress: laptops push through an authenticated local
port-forward, while in-cluster readers use the ClusterIP service.

The MasterPlan and its original child drafts share Intention
`intention_01kx3qz212e989078m6ssetr2b`; the EP-2 implementation session was explicitly
re-associated with Intention `intention_01kxh323kyegvvmkqscf59nahr`, which is recorded in
that child's frontmatter and commit trailers. The originating Kikan C16 contract is not
yet authored as of 2026-07-14. Until it lands, the integration boundary is the declared
intent in that repository: a repository identity is a Mori repository ID plus a full
40-character Git commit SHA, only the resolve route accepts branch/tag input, and only
one mirror workload talks to the forge. Implementers must reconcile the completed
Nagare interfaces with C16 before Kikan consumes them.


## Decomposition Strategy

The initiative is split on ownership and failure boundaries. EP-1 owns forge identity,
token minting, and Kubernetes Secret publication. EP-2 owns a new public DSL type and
the cluster policy that limits its Pods. EP-3 owns cache infrastructure, Attic runtime
state, and the Nix client contract. Each stream changes a different subsystem and has a
standalone, observable acceptance test, so all three can be implemented in parallel.

A single ExecPlan was rejected because it would couple Nix/Pulumi work, NixOS secret
rotation, and Haskell API work in one non-reviewable change and make partial rollback
unclear. More than three plans was also rejected: the cache's cloud bucket, database,
Attic manifests, and client configuration form one deployable feature, while the Job
type and its ResourceQuota/NetworkPolicy policy form one behavioral contract. The
child plans deliberately avoid making either Kikan or Kotei a build dependency of
Nagare.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| EP-1 | Rotating GitHub App installation-token credentials for runtime pods | `docs/plans/94-rotating-github-app-installation-token-credentials-for-runtime-pods.md` | None | None | Not Started |
| EP-2 | A one-shot job workload kind in nagare-dsl | `docs/plans/95-a-one-shot-job-workload-kind-in-nagare-dsl.md` | None | EP-3 for the live cache mount test | Complete |
| EP-3 | An in-cluster Nix binary cache (Attic) as a cluster bootstrap component | `docs/plans/96-an-in-cluster-nix-binary-cache-attic-as-a-cluster-bootstrap-component.md` | None | EP-2 for the rendered Job integration test | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

There are no hard child-to-child dependencies. EP-1 publishes Secrets that Kikan's
future mirror and publishing workloads consume, but neither other Nagare child needs
those tokens. EP-2 can add and test the `Job` API using a named optional ConfigMap
without a live cache. EP-3 can deploy and test Attic with `nix copy` from a temporary
Pod without the new DSL kind.

EP-2 and EP-3 meet at one soft integration edge. EP-3 owns the ConfigMap named
`nagare-nix-cache-client`; EP-2 owns the optional Job field that mounts its `nix.conf`
key at `/etc/nix/nix.conf`. Whichever finishes second must run the combined live test:
render a Job with that ConfigMap selected, apply it, and observe the Job substitute a
previously uploaded path from Attic. This edge changes final validation order, not
implementation order.


## Integration Points

| Plans | Shared artifact | Owner and contract |
|---|---|---|
| EP-1 and downstream Kikan work | Secrets `nagare-forge-read` and `nagare-forge-write` in `personal` | EP-1 owns creation and rotation. Each Secret has `token` for direct consumers and `GITHUB_TOKEN` for Nagare's `EnvSecretRef`; consumers select a role name and never know GitHub App credentials. |
| EP-2 and EP-3 | ConfigMap `nagare-nix-cache-client` and label `nagare.dev/nix-cache-client: "true"` | EP-3 owns the `nix.conf` data, cache public key, and additive cache/DNS egress policy. EP-2 treats the ConfigMap as an optional input, owns the read-only mount at `/etc/nix/nix.conf`, and adds the opt-in label only when that input is present. |
| EP-2 and cluster bootstrap | ResourceQuota `nagare-terminating-jobs` and the k3s NetworkPolicy dataplane | EP-2 owns the quota and base default-deny manifest. The quota scopes the two-Pod cap to `Terminating` Pods, which are Pods whose own `spec.activeDeadlineSeconds` is present; the Job renderer copies its validated deadline to both Job and Pod template because the controller does not do that. The quota is not label-selective. Live kube-router probes proved steady-state deny and narrow additive allow, but also an asynchronous new-Pod startup window; production untrusted workloads need a dataplane or admission-time mechanism that closes that gap. |
| EP-3 and existing database machinery | Database `nix-cache` and Secret `nagare-db-nix-cache` | EP-3 consumes the current `nagarectl db create postgres` interface and maps `DATABASE_URL` to Attic. The existing database renderer remains authoritative. |
| All three and Kikan C16 | Immutable repository coordinate | Nagare does not define C16. Plans use `(Mori repository ID, full 40-character Git SHA)` as the provisional boundary and must record any reconciliation when Kikan's C16 plan lands. |


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. This section provides an at-a-glance view of the entire initiative.

- [ ] EP-1: configure least-privilege read and write GitHub Apps through sops-nix.
- [ ] EP-1: mint installation tokens on a host timer and atomically publish role-named Secrets.
- [ ] EP-1: prove rotation, read access, and denial of unauthorized write access.
- [x] EP-2: add, serialize, load, and deterministically render the first-class `Job` type.
- [x] EP-2: add hardening, terminating-Pod quota, and default-deny network policy resources.
- [x] EP-2: prove golden output, validation failures, quota backpressure, and steady-state network isolation.
- [ ] EP-3: provision durable cache storage and pin/build the Attic server image.
- [ ] EP-3: bootstrap Attic, Postgres, secrets, garbage collection, and the Nix client ConfigMap.
- [ ] EP-3: prove laptop push, cluster substitution, restart durability, and key rotation.


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

- Discovery: EP-2's originating Kikan plan still has no standalone conformance fixture,
  and its embedded draft omits explicit one-way parallelism/completions plus the Pod-level
  active deadline required for the `Terminating` quota. Nagare's corrected Job golden is
  the provider-side source until Kikan copies and reconciles it.

- Discovery: The embedded k3s kube-router controller reconciles NetworkPolicy rules for a
  new Pod IP asynchronously. An immediate TCP probe escaped before its Pod chain existed;
  after a 15-second delay the default deny blocked it, and an additive `/32` TCP/80 policy
  allowed only its target. This affects both EP-2's base deny and EP-3's additive cache/DNS
  policy: neither should be described as fail-closed from workload process start on the
  current dataplane.

- Discovery: The aggregate `nix flake check` currently fails in the unrelated
  `nagare-access` derivation because a sandboxed Cabal dependency clone needs GitHub
  credentials. EP-2's 381-test suite and focused DSL, example, and shell Nix checks pass.


## Decision Log

Record every decomposition or coordination decision made while working on the master
plan.

- Decision: Create one MasterPlan with three child ExecPlans and no hard dependencies.
  Rationale: The work has three independent owners and failure domains, while the only
  cross-plan artifact is an optional cache ConfigMap mount.
  Date: 2026-07-14

- Decision: Initially use Kikan's existing Intention ID on the MasterPlan and all child
  drafts.
  Rationale: These Nagare changes are the provider-side work for the same cross-repository
  outcome, so separate intentions would hide the traceability Kikan requested.
  Date: 2026-07-14

- Decision: Treat the current Kikan C16 description as provisional rather than inventing
  a Nagare-owned repository-reference contract.
  Rationale: Kikan owns the content-plane contract and its C16 ExecPlan is still a
  skeleton. Nagare needs enough boundary detail to plan now but must not become the
  source of truth.
  Date: 2026-07-14

- Decision: Model excess Job concurrency as ResourceQuota admission backpressure.
  Rationale: Kubernetes rejects a Pod that exceeds quota with HTTP 403. For a Job this
  appears as a `FailedCreate` event while its controller retries; describing a third Pod
  as Pending would encode behavior Kubernetes does not provide.
  Date: 2026-07-14

- Decision: Render the active deadline at both Job and Pod-template level.
  Rationale: The Job-level field bounds the whole Job, while the ResourceQuota
  `Terminating` scope tests the created Pod's own field. The Job controller copies the Pod
  template unchanged and does not synthesize that field. Kikan's not-yet-created golden
  must include the Pod deadline before cross-repository byte equality is asserted.
  Date: 2026-07-14

- Decision: Rely on and verify k3s's embedded kube-router NetworkPolicy controller.
  Rationale: `nixos/hosts/nagare-01/k3s.nix` does not pass
  `--disable-network-policy`, so a second network-policy engine is unnecessary. A live
  deny/allow probe is still required before claiming isolation.
  Date: 2026-07-14

- Decision: Keep Attic private to the cluster and use `kubectl port-forward` for laptop
  pushes.
  Rationale: This supplies the required producer/consumer flow without adding a public
  attack surface or ingress authentication system for an upstream that still describes
  itself as an early prototype.
  Date: 2026-07-14

- Decision: Associate EP-2 implementation commits with Intention
  `intention_01kxh323kyegvvmkqscf59nahr` while retaining the MasterPlan's originating
  Intention.
  Rationale: The user explicitly selected the newer Intention for this implementation
  session. Recording both preserves initiative provenance without hiding the actual
  implementation association.
  Date: 2026-07-14

- Decision: Treat EP-2's NetworkPolicy as proven steady-state isolation but not a
  fail-closed startup boundary on the current kube-router dataplane.
  Rationale: The live delayed deny/narrow allow probes validate policy reconciliation,
  while the immediate successful connection is direct evidence of a startup gap. EP-3
  and future Kikan scheduling must account for that gap instead of relying on manifest
  apply order alone.
  Date: 2026-07-14


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision.

EP-2 is complete. Nagare now owns the validated one-shot Job API, deterministic hardened
resource bundle, two-slot terminating-Pod quota, operator recipes, and compiled example.
Its DSL suite, focused Nix checks, server-side dry-run, hardening/TTL probe, quota
backpressure probe, and steady-state deny/narrow-allow probe passed. The remaining
MasterPlan work is EP-1 and EP-3, plus EP-2/EP-3's soft live cache-mount integration.

The milestone also leaves two coordination risks visible rather than silently passing
them downstream: Kikan must create and reconcile its conformance fixture, and production
untrusted workloads require startup-fail-closed network isolation beyond the current
asynchronous kube-router behavior.


## Revision Notes

2026-07-14: Audited the MasterPlan and all three child ExecPlans against the shared
formatting specification. The MasterPlan contains no command or code excerpts requiring
fences; every such excerpt in the children now uses a language-tagged fenced block.

2026-08-23: Registered this initiative's cross-project lineage in `docs/plan-registry.md`
and replaced the repository-relative Kikan origin with its canonical `mori://` plan URI.
The current Mori release does not yet resolve that artifact-level URI; the intended URI
remains authoritative while registry coverage catches up.
