---
id: 142
slug: migrate-legacy-namespace-wildcard-certificates-during-upgrades
title: "Migrate legacy namespace wildcard certificates during upgrades"
kind: exec-plan
created_at: 2026-09-15T14:04:02Z
intention: "intention_01m2jp35nje7j9kqpd7qgbmwpb"
provenance:
  created_by:
    model: "gpt-5.6-sol"
    harness: "codex-cli"
    at: 2026-09-15T14:04:02Z
  revisions:
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-15T16:31:36Z
      mode: "implement"
      note: "Implemented the pure migration model and began upgrade orchestration"
---

# Migrate legacy namespace wildcard certificates during upgrades

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

Full plan before trimming: [142-migrate-legacy-namespace-wildcard-certificates-during-upgrades.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/142-migrate-legacy-namespace-wildcard-certificates-during-upgrades.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

A TLS-enabled cluster created by Nagare 0.2.2 can upgrade to the narrowed 0.3.x certificate policy
without a manual ConfigMap patch or an unsafe blanket deletion. Upgrade planning records the
selector change plus the exact obsolete certificate chains and generated TLS Secrets in a private,
context-bound Kubernetes review bundle. Apply installs the narrowed selector before the certificate
policy gate, preserves valid wildcards in opted-in application namespaces, and removes only legacy
artifacts whose live identity still matches the reviewed evidence. The defect is recorded in
[BUG-3](../bug-reports/upgrade-does-not-migrate-certificate-selector.md).

The observable proof starts from a 0.2.2 fixture whose `namespace-wildcard-cert-selector` is `{}` and
whose system namespaces contain legacy public wildcard certificates. A 0.3.x dry run shows the
selector diff and exact cleanup inventory. Apply leaves the opted-in `personal` wildcard intact,
removes the reviewed system-namespace Certificate objects and matching generated Secrets, passes
`nagarectl cluster certificate-policy`, and produces no further changes on resume or reapply.

## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-09-15T16:31:36Z) Milestone 1: model legacy selector and certificate/Secret inventory
  as a pure, reviewable, transaction-bound Kubernetes migration bundle. Ten focused tests prove
  deterministic preserve/remove classification, disabled/target-selector no-ops, ambiguous Secret
  refusal, exact UID/content/reference drift refusal, idempotent absence, and transaction bindings.
- [x] (2026-09-15T16:57:42Z) Milestone 2: upgrade planning now publishes a private, canonical,
  context/transaction/payload-bound Kubernetes bundle after the cluster guard; apply verifies it,
  narrows the selector with server-side apply before bootstrap, waits for controller convergence,
  and deletes only unchanged reviewed Secrets. The installed clone-free check proves tamper
  refusal, exact legacy preserve/remove inventory, mutation order, and fixed-point reapply.
- [x] (2026-09-15T17:01:00Z) Milestone 3: added the repository-owned 0.2.2 observation fixture,
  hermetic installed-package convergence trace, and guarded disposable-k3d rehearsal; documented
  migration and recovery, updated the changelog, and amended ADRs 10 and 18. All runnable focused,
  package, documentation, and Nix checks pass. The k3d script is syntax-checked but its live run is
  recorded below as unavailable because this workstation has no Docker daemon.

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Observation: `mori registry search net-certmanager` and
  `mori registry show knative-extensions/net-certmanager --full` do not resolve the archived
  upstream project in the current local registry, even though ADR 10 records the intended
  `mori://knative-extensions/net-certmanager` project URI. The repository-owned exact source pin
  remains available in `nix/net-certmanager-controller.nix`, and the official upstream source was
  consulted for the object contract.
  Evidence: Mori printed `No projects matching 'net-certmanager'` and `Project ... not found in
  local registry`; the Nix expression pins commit `dcff3644e7037215a084af52905fb0e9e78bab52`.

- Observation: the plan's root-level `cabal test` examples do not work because the repository root
  has no `cabal.project`; Nagare's established package commands run from `cli/nagarectl` while the
  Nix development shell is discovered from the repository root.
  Evidence: Cabal returned `There is no <pkgname>.cabal package file or cabal.project file`; the
  same focused test from `cli/nagarectl` passed all 10 cases.

- Observation: the disposable k3d proof cannot run in this implementation environment because the
  configured Colima Docker socket does not exist.
  Evidence: `docker info` failed to connect to
  `unix:///Users/shinzui/.colima/docker.sock`; `bash -n` still accepted the complete guarded script,
  while the installed clone-free check exercised the same plan/apply/reapply transaction semantics.

## Decision Log

Record every decision made while working on the plan.

- Decision: Create a dedicated `kubernetes-plan/` bundle inside each upgrade transaction rather
  than enabling `config-network-tls.yaml` unconditionally in `cluster-bootstrap`.
  Rationale: Fresh clusters are deliberately HTTP-first until DNS and ACME prerequisites are ready.
  Only a cluster already observed with `external-domain-tls: Enabled` should retain TLS while its
  selector is migrated. A transaction-bound bundle makes that conditional decision reviewable and
  binds it to the same context, payload, and immutable workspace as the rest of the upgrade.
  Date: 2026-09-15.

- Decision: Inventory and clean only public wildcard Certificate objects that violate the target
  label/issuer policy and only their recorded cert-manager-generated Secrets; preserve every
  compliant Certificate, even if it predates the upgrade.
  Rationale: The desired state is policy convergence, not deletion by age or namespace alone. A
  valid wildcard in `personal` is user-visible serving state and must survive. Exact namespace,
  name, UID, issuer, DNS names, secret name, and Secret UID/digest bindings keep cleanup narrow.
  Date: 2026-09-15.

- Decision: If a reviewed Certificate or Secret changes identity or content before deletion, refuse
  the Kubernetes apply phase and print the exact mismatch; never broaden selection or silently skip
  a changed object.
  Rationale: A user or controller may have replaced an object after planning. Stopping preserves the
  review boundary and prevents deleting a newly repurposed Secret under a familiar name.
  Date: 2026-09-15.

- Decision: Keep the migration bundle outside the upgrade transaction JSON schema and bind it with
  its own versioned metadata and file digests.
  Rationale: The bundle is a private reviewed artifact analogous to the Pulumi plan directory. Its
  derived location and explicit transaction/context/payload bindings avoid coupling this fix to
  independent transaction-journal evolution while still detecting tampering and stale plans.
  Date: 2026-09-15.

- Decision: Recognize a generated TLS Secret only when the cert-manager Certificate UID appears in
  its owner references or when both `cert-manager.io/certificate-name` and
  `cert-manager.io/issuer-name` match the reviewed Certificate.
  Rationale: cert-manager owner references on generated Secrets are deployment-option dependent,
  while its generated annotations preserve a narrow identity binding. Requiring one of those exact
  bindings rejects an arbitrary same-named Secret without making legacy clusters depend on an
  optional controller flag.
  Date: 2026-09-15.

- Decision: Keep `metadata.json` canonical and omit an informational creation timestamp from the
  Kubernetes bundle metadata.
  Rationale: Every remaining metadata field is either checked against the current transaction,
  context, and payload or checked against a member digest. Requiring byte-for-byte canonical JSON
  therefore makes a one-file metadata edit fail closed instead of leaving an unchecked timestamp
  field that could be changed without invalidating the bundle.
  Date: 2026-09-15.

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

- Milestone 1 produced `Nagare.Cluster.CertificateMigration`, a pure JSON inventory and review
  model with no Kubernetes process execution. It hashes only stable Secret identity, annotations,
  labels, type, and data, deliberately excluding mutable server bookkeeping such as
  `resourceVersion`. The first focused run passed 10 tests.

- Milestone 2 integrated that model into `KubernetesDiff` and `KubernetesApply` without changing the
  upgrade journal schema. The hermetic 0.2.2 fixture includes `personal`, `kube-system`, and
  `observability`, so the successful exact trace proves the opt-in label drives cleanup rather than
  a system-namespace deny-list. Tampered review bytes refuse before any Kubernetes cleanup, and a
  second apply of the completed transaction adds no mutation.

- Milestone 3 leaves the operator-visible contract in the runbooks and durable security boundaries
  in ADRs 10 and 18. The final local matrix passed all 564 Haskell tests, Haskell style, the focused
  certificate-policy shell and Nix checks, the installed clone-free upgrade check, strict user-doc
  validation, fixture JSON validation, and shell syntax validation. The disposable script creates
  and verifies its own `nagare-certificate-migration-*` kube context, loads the legacy selector,
  reviews live controller UIDs, applies twice, and checks every preserved/removed chain from the
  retained review rather than assuming generated object names.

