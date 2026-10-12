---
id: 138
slug: keep-bootstrap-tls-issuance-within-intended-names
title: "Keep bootstrap TLS issuance within intended names"
kind: exec-plan
created_at: 2026-09-14T04:16:15Z
intention: "intention_01m2f225p4e68bbf918ecvvwvr"
master_plan: "docs/masterplans/22-reliable-first-cluster-bootstrap-on-gcp.md"
provenance:
  created_by:
    model: "gpt-5.6-sol"
    harness: "codex-cli"
    at: 2026-09-14T04:16:15Z
  revisions:
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-14T16:26:57Z
      mode: "implement"
      note: "Started EP-5 TLS issuer and namespace policy implementation"
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-14T22:24:16Z
      mode: "implement"
      note: "Repair pure-Linux importer fixture portability for the 0.3.0 release gate"
---

# Keep bootstrap TLS issuance within intended names

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

Full plan before trimming: [138-keep-bootstrap-tls-issuance-within-intended-names.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/138-keep-bootstrap-tls-issuance-within-intended-names.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

On a freshly bootstrapped cluster, Knative's internal and cluster-local certificates use its
self-signed issuer, while the public ACME issuer receives only DNS names for explicitly labeled app
namespaces. Enabling TLS no longer creates rejected orders for internal names or public wildcard
certificates for Kubernetes system namespaces. A diagnostic fails before stamping success if an
ACME-backed certificate contains a non-public name. This plan implements IR-22 and IR-23 and
integrates with independent ExecPlan 132's webhook readiness work.

## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-09-14T16:40:54Z) Verify Knative/net-certmanager compatibility and pin explicit
  internal issuer references.
- [x] (2026-09-14T16:40:54Z) Define the app-namespace label contract and scope wildcard issuance
  to that selector across bootstrap and workload creation paths.
- [x] (2026-09-14T16:40:54Z) Add the focused certificate-policy command, doctor probe/remediation,
  parsed manifest gate, and pure inventory coverage.
- [x] (2026-09-14T17:44:42Z) Make the disposable k3d certificate-controller verification pass with
  the repository-owned patch and payload-bundled controller image.
- [x] (2026-09-14T17:49:14Z) Reconcile bootstrap ordering, update docs/ADR, complete both IRs,
  append bundle logs, and pass focused plus aggregate gates.
- [x] (2026-09-14T22:23:30Z) Repair the importer fixture's pure-Nix Linux execution by invoking
  the repository script through the check's Bash and giving generated fake executables exact Bash
  store-path shebangs; the focused Nix derivation and standalone fixture pass.

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Observation: net-certmanager v1.14.0 is both the repository's pinned version and the latest tag in
  the authoritative `knative-extensions/net-certmanager` repository, but its three documented
  issuer settings cannot hold distinct values.
  Evidence: Mori has no registered Knative project, so the fallback upstream tag inspection resolved
  `knative-v1.14.0` to commit `dcff3644e7037215a084af52905fb0e9e78bab52`. That source parses
  `issuerRef`, `clusterLocalIssuerRef`, and `systemInternalIssuerRef` separately and selects them by
  Knative certificate type. However, `NewCertManagerConfigFromConfigMap` initializes all three fields
  with the same `knativeSelfSignedIssuer` pointer and unmarshals into those shared objects. When all
  three keys are present, the last `systemInternalIssuerRef` parse overwrites every role. The tests
  exercise each override separately and do not cover the combined configuration. Current upstream
  `main` at `ece6a96aa096cbec0069e7037347d735878c50b1` retains the same implementation, and no newer
  release exists.

- Observation: the ambient shell lacks `k3d` and its configured Colima Docker socket is absent, but
  the project development shell provides k3d v5.9.0.
  Evidence: `docker info` could not connect to `~/.colima/docker.sock`; `k3d` was absent from the
  ambient `PATH`, while `nix develop -c k3d version` succeeded. The controller-level disposable
  verification therefore remains a distinct environment-dependent step.

- Observation: the disposable-cluster proof reproduces the aliasing defect rather than merely a
  stale ConfigMap watch.
  Evidence: after raising Colima's inotify limits, fresh k3d clusters installed the exact pinned
  stack. Explicitly classed system-internal and cluster-local fixtures became Ready on
  `knative-selfsigned-issuer`, but `personal/personal.apps.example.test` also became Ready on that
  issuer instead of `letsencrypt-dns`. Restarting the controller after the ConfigMap patch and then
  creating a new explicitly external-domain fixture produced the same result. The focused
  diagnostic now fails this self-signed public-wildcard state instead of treating absence of ACME
  violations as success.

- Observation: one existing upstream test accidentally depends on the production aliasing defect.
  Evidence: its `valid SystemInternalIssuerRef` case writes `clusterLocalIssuerRefKey`; the shared
  package-global pointer made the expected values mutate in test order. After separating defaults,
  the native Linux regression failed until the fixture wrote `systemInternalIssuerRef`, matching
  its name and expected value. The carried patch corrects the fixture and the native test passes.

- Observation: the scratch image must declare a numeric non-root user even though the Deployment
  already requires `runAsNonRoot`.
  Evidence: the first imported image was present on the k3d node but Kubernetes refused to create
  its container because image metadata defaulted to root. Declaring UID/GID 65532 preserved the
  upstream security context and the next fresh-cluster rollout passed.

- Observation: the exact payload-delivery design passes the controller-level acceptance proof.
  Evidence: Nix built the Linux/amd64 image from commit
  `dcff3644e7037215a084af52905fb0e9e78bab52`, k3d imported its Docker archive, and the patched
  Deployment became Ready on an arm64 Colima host through emulation. System-internal and
  cluster-local fixtures selected `knative-selfsigned-issuer`; the labeled `personal` wildcard
  selected `letsencrypt-dns`; no unlabeled namespace received a public wildcard; and
  `nagarectl cluster certificate-policy` exited zero. The deterministic self-signed public-issuer
  fixture left the ACME Order inventory empty. The disposable cluster was removed.

- Observation: macOS could execute the importer fixture's generated `#!/usr/bin/env bash` files,
  but a pure Linux Nix builder has no `/usr/bin/env` and rejected the repository installer before
  exercising its assertions.
  Evidence: GitHub CI job `104171043596` failed
  `net-certmanager-controller-install` with `bad interpreter: No such file or directory`. The
  fixture now invokes the repository installer through the check-provided Bash and renders exact
  Bash store paths into only its generated fakes; the same derivation passes locally.

## Decision Log

Record every decision made while working on the plan.

- Decision: Use the opt-in label `nagare.dev/app-namespace=true` and make Nagare's namespace-creating
  paths own it.
  Rationale: An allow-list remains safe as new system namespaces appear; a name-based exclusion
  list would silently issue public certificates for every unrecognized namespace.
  Date: 2026-09-14.

- Decision: Set both `systemInternalIssuerRef` and `clusterLocalIssuerRef` explicitly to
  `knative-selfsigned-issuer`; keep only public external-domain issuance on `letsencrypt-dns`.
  Rationale: Relying on version-dependent fallback behavior already routed an internal short name
  to production ACME. Explicit role-specific issuers preserve the intended trust boundaries.
  Date: 2026-09-14.

- Decision: Treat any ACME-issued DNS name without a dot, `.svc`, or `.svc.cluster.local` name as a
  bootstrap failure and diagnostic error.
  Rationale: Such names are never valid public ACME identifiers and are direct evidence that the
  issuer boundary regressed.
  Date: 2026-09-14.

- Decision: Amend ADR 10 if the label and public-name boundary survive implementation.
  Rationale: Public certificate eligibility and Certificate Transparency exposure are durable
  platform policy, not merely manifest syntax.
  Date: 2026-09-14.

- Decision: Do not claim the three-role ConfigMap as complete against unpatched net-certmanager
  v1.14.0.
  Rationale: source inspection and two live clusters prove the released controller aliases all
  three issuer references. A correct solution now requires either carrying and distributing a
  patched controller image or changing the certificate-controller architecture; both materially
  exceed the planned ConfigMap-only compatibility work and require an explicit scope decision.
  Date: 2026-09-14.

- Decision: Reconcile application namespaces by applying a Namespace object containing only
  Nagare's opt-in label, and reject fixed Kubernetes, control-plane, and observability namespaces.
  Rationale: `kubectl apply` creates a missing namespace or merges the one Nagare-owned label onto an
  existing namespace without deleting unrelated labels. A deny-list at this API boundary prevents
  accidental public wildcard issuance even when a caller selects a platform namespace.
  Date: 2026-09-14.

- Decision: Expose the focused check as `nagarectl cluster certificate-policy` and also include its
  probe in server status and doctor.
  Rationale: bootstrap needs a fail-closed command that checks only this policy before stamping,
  while day-two diagnostics should show the same parsed evidence and remediation with the rest of
  the platform inventory.
  Date: 2026-09-14.

- Decision: Carry the smallest net-certmanager correction in this repository and ship its image
  archive inside every immutable `nagare-platform` payload.
  Rationale: v1.14.0 is the latest and final upstream release, the repository is archived, and
  `main` retains the defect. Pinning the exact release commit, applying an auditable patch during
  Nix evaluation, and importing the archive directly into the selected k3s/containerd store avoids
  both a separately hosted fork and a mutable registry tag while preserving ADR 7's release
  closure. Only the controller is replaced; the latest upstream webhook remains unchanged.
  Date: 2026-09-14.

- Decision: Declare UID/GID 65532 in the patched scratch image rather than weakening the upstream
  Deployment security context.
  Rationale: the controller needs no root privileges, and Kubernetes should continue enforcing
  `runAsNonRoot` before process start.
  Date: 2026-09-14.

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

The opt-in namespace selector, workload namespace reconciliation, parsed certificate diagnostics,
repository-owned upstream patch, and immutable controller delivery are implemented. The live proof
prevented a false ConfigMap-only completion, then demonstrated the repaired behavior against the
exact bundled archive. The latest archived v1.14.0 release remains the base; Nagare owns no separate
fork or registry image. Native Linux runs the corrected upstream test plus the combined regression,
while hermetic importer, parsed policy, readiness-order, and platform-payload checks cover the
release boundary. Reader documentation and ADR 10 now record the public-name and patch lifecycle
policy. IR-22 and IR-23 are complete. All 520 Haskell tests, strict user/review/guide and
23-concept improvement-request validation, every buildable native flake check, the native Linux
upstream regression, and the fresh disposable-cluster proof pass.

The 0.3.0 release audit found and repaired one portability gap in the hermetic importer fixture:
pure Linux builders do not provide `/usr/bin/env`. This changed test execution only, not the shipped
installer or controller payload. The focused Nix check and direct fixture both pass after pinning
their interpreter to the Bash already supplied by the check.

