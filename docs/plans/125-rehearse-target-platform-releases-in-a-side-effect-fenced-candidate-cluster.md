---
id: 125
slug: rehearse-target-platform-releases-in-a-side-effect-fenced-candidate-cluster
title: "Rehearse target platform releases in a side-effect-fenced candidate cluster"
kind: exec-plan
created_at: 2026-09-13T22:09:04Z
intention: "intention_01m2ecthzwek7t64p7wqn0x9wj"
master_plan: "docs/masterplans/21-rehearsed-replacement-upgrades-with-bounded-downtime-for-nagare.md"
provenance:
  created_by:
    model: "gpt-5.6-sol"
    harness: "codex-cli"
    at: 2026-09-13T22:09:04Z
  revisions:
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-16T04:38:37Z
      mode: "update"
      note: "Refresh rehearsal against current kubeconfig and certificate-policy boundaries"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-09T19:45:59Z
      mode: "update"
      note: "Refresh MP-21 as optional inventory-backed replacement after MP-23 upgrade drills"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-09T22:17:13Z
      mode: "update"
      note: "Cascade 2026-10-09 re-scope of MasterPlans 21/25/26"
---

# Rehearse target platform releases in a side-effect-fenced candidate cluster

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

Full plan before trimming: [125-rehearse-target-platform-releases-in-a-side-effect-fenced-candidate-cluster.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/125-rehearse-target-platform-releases-in-a-side-effect-fenced-candidate-cluster.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

**Current scope (2026-10-09).** This child implements optional machine/cluster replacement after
MP-23, not a prerequisite for ordinary node or PostgreSQL upgrades. The
[production checklist](../releases/production-readiness-checklist.md) credits those completed drills.
MP-23's typed scopes, reviewed native effects, conditional shared history, receipt verification and
proof-based recovery are the implementation foundation. Replacement phase records never grant
mutation authority independently of inventory admission. Proposed replacement commands below remain
unavailable until their owned implementation and acceptance are complete.

An operator can boot the candidate's target NixOS, k3s, and Nagare platform release while
the old machine still serves production, then run deterministic health and compatibility
checks against that candidate. Rehearsal uses an explicit candidate kubeconfig and a
side-effect fence: no public route, no scheduled jobs, no application workers, read-only
cloud credentials, and no production certificate issuance. Nagare refuses cutover if it
cannot attest that the fence held throughout the rehearsal.

`nagarectl platform replacement rehearse <transaction-id> --json` produces a signed-by-digest
evidence bundle containing host activation, cluster component versions, readiness, policy
audit, state restore checks, application probe results, durations, and log locations. A
failed rehearsal leaves the live host untouched and can be repeated after fixing the target
release or configuration.

Nagare 0.3.0 now has context-safe kubeconfig fetching, staged target-host identity, fail-closed
certificate-policy diagnostics, and a reviewed Kubernetes migration bundle for ordinary upgrades.
Rehearsal should specialize these current guards for a transaction-owned candidate rather than
reimplement kubeconfig normalization, trust ambient cluster state, or apply an unreviewed policy
mutation.

## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Add candidate-targeted host activation and kubeconfig plumbing with no ambient-target
```text
  fallback.
```
- [ ] Add a declarative rehearsal overlay that suspends side-effecting workloads and uses
```text
  local TLS.
```
- [ ] Add fence attestation and fail-closed validation before any application probe runs.
- [ ] Add platform, restored-state, and opt-in application probes plus evidence capture.
- [ ] Add offline/fake-target tests and a live candidate rehearsal test.

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Observation: Historical observation (2026-09-13): multi-cluster guidance paired context selection with an
  ambient kubeconfig. The current guarded kubeconfig implementation below is the reuse boundary;
  this historical pairing is not the proposed candidate targeting.
  Evidence: `docs/guides/running-multiple-clusters.md` documents this pairing and
  `scripts/live-test.sh` retrieves and rewrites a k3s kubeconfig over IAP.
- Observation: Applying production objects unchanged is not a safe rehearsal because Nagare
  manages CronJobs, backup uploads, minimum-scale services, workers, and migration hooks.
  Evidence: task and database modules render CronJobs, and deployed Knative Services may set
  minimum scale above zero.
- Observation: Production certificate bootstrap requires DNS mutation from the node service
  account.
  Evidence: `cluster/bootstrap/cert-manager/letsencrypt-dns.yaml.tmpl` uses DNS-01 and the
  active node account has zone administration permissions.
- Observation: certificate ownership and kubeconfig selection are now stricter than at plan
  creation.
  Evidence: `Nagare.Cluster.Kubeconfig` fetches and normalizes a named context kubeconfig;
  `Nagare.Cluster.CertificatePolicy` rejects unintended public wildcard issuance; the in-place
  upgrade retains reviewed certificate-migration evidence before Kubernetes mutation.

## Decision Log

Record every decision made while working on the plan.

- Decision: Candidate selection is a typed target passed to every host and Kubernetes
  operation; ambient `KUBECONFIG`, default instance names, and active context outputs are
  forbidden in replacement code.
  Rationale: The most dangerous rehearsal failure is accidentally applying target resources
  to production.
  Date: 2026-09-13
- Decision: Rehearsal transforms the rendered production objects into a fail-closed overlay:
  CronJobs suspended, workers and StatefulSets without seeded state at zero, and Knative
  user services at zero except one explicitly invoked probe revision.
  Rationale: A fresh cluster still needs realistic manifests, but merely hiding its address
  does not prevent outbound email, queues, webhooks, migrations, or backup writes.
  Date: 2026-09-13
- Decision: Use a local rehearsal issuer and copied/nonrenewing test certificate material,
  not the production ACME issuer.
  Rationale: Platform TLS wiring can be tested without mutating production DNS or consuming
  certificate authority capacity. ExecPlan 127 arms production credentials before downtime
  and reruns the affected checks.
  Date: 2026-09-13
- Decision: Application execution is opt-in and must declare allowed destinations and probe
  commands; an undeclared workload is inspected but not started.
  Rationale: Nagare cannot infer whether arbitrary application startup has external side
  effects.
  Date: 2026-09-13
- Decision: Build candidate targeting and certificate-fence evidence on the existing kubeconfig,
  cluster guard, certificate-policy, and reviewed Kubernetes-plan contracts.
  Rationale: these guards already encode wrong-context refusal and explicit public-certificate
  ownership; duplicating them for replacement rehearsal would create divergent safety semantics.
  Date: 2026-09-15

- Decision (operator, 2026-10-09): On hold. [MasterPlan 21](../masterplans/21-rehearsed-replacement-upgrades-with-bounded-downtime-for-nagare.md) runs only EP-122's measured IP-handoff spike until the operator decides, from its numbers, whether to resume, re-scope or cancel the remaining children. Do not start this plan's remaining milestones before that decision. If it resumes, candidate identities come from EP-124, which reuses [MasterPlan 25](../masterplans/25-reviewed-full-context-teardown-with-vm-workload-collection.md) EP-165's cloud identity.
  Rationale: Replacement has the largest cloud surface of the follow-up plans, and its downtime budget's feasibility is unmeasured.
  Date: 2026-10-09

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)

