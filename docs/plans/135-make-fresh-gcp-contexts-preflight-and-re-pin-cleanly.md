---
id: 135
slug: make-fresh-gcp-contexts-preflight-and-re-pin-cleanly
title: "Make fresh GCP contexts preflight and re-pin cleanly"
kind: exec-plan
created_at: 2026-09-14T04:16:14Z
intention: "intention_01m2f225p4e68bbf918ecvvwvr"
master_plan: "docs/masterplans/22-reliable-first-cluster-bootstrap-on-gcp.md"
provenance:
  created_by:
    model: "gpt-5.6-sol"
    harness: "codex-cli"
    at: 2026-09-14T04:16:14Z
  revisions:
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-14T12:33:05Z
      mode: "implement"
      note: "Started ADC and undeployed-context implementation"
---

# Make fresh GCP contexts preflight and re-pin cleanly

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

Full plan before trimming: [135-make-fresh-gcp-contexts-preflight-and-re-pin-cleanly.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/135-make-fresh-gcp-contexts-preflight-and-re-pin-cleanly.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

A freshly initialized GCP context reports `not deployed` for resources that do not exist instead of
calling them legacy, and an operator can re-pin that context to the current patch release before
creating a VM. Initialization and every later cloud guard inspect the Application Default
Credentials (ADC) that Pulumi actually uses, refuse a foreign quota project, and make any detectable
account disagreement visible. This plan implements IR-12 and IR-16 without changing adoption or
upgrade semantics for deployed clusters.

## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-09-14 12:40Z) Model and test ADC discovery, principal evidence, and quota-project policy.
- [x] (2026-09-14 12:49Z) Add the shared ADC observation to initialization and the context guard.
- [x] (2026-09-14 13:10Z) Represent not-deployed host/cluster identities and add a guarded re-pin command.
- [x] (2026-09-14 13:18Z) Update setup/upgrade docs, complete the IRs, and run all focused and repository checks.

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Observation: The Mori registry contains the exact `aeson` source used to verify strict JSON
  decoding and key lookup, but has no registered Google Cloud SDK or `gcloud` project.
  Evidence: `mori registry show haskell/aeson --full` resolved the corpus source, while
  `mori registry search google-cloud-sdk` and `mori registry search gcloud` returned no projects.

- Observation: Direct Cabal resolution remains unavailable in this checkout, so the authoritative
  focused gate is the flake-provided `nagarectl-build-test` check.
  Evidence: `nix build .#checks.aarch64-darwin.nagarectl-build-test --print-build-logs` compiled the
  normal and profiled executables and passed all 501 tests.

- Observation: A missing Kubernetes release marker cannot distinguish an absent cluster from an
  unreachable or unversioned deployed cluster.
  Evidence: deriving cluster `NotDeployed` only after a project-scoped GCE NotFound lets status skip
  kubectl for a host that cannot contain the single-host cluster, while all other lookup outcomes
  retain `DeploymentUnknown` and `legacy-unknown`.

- Observation: The full repository gate's intentional missing-Pulumi scenario began refusing at
  the newly earlier missing-ADC boundary.
  Evidence: `nagare-operator-tools` passed again after its context-guard fixture received a matching
  ADC file, preserving the test's intended Pulumi diagnostic without weakening guard order.

## Decision Log

Record every decision made while working on the plan.

- Decision: Refuse a known ADC `quota_project_id` that differs from the selected context project;
  warn on an absent quota project or an account that cannot be determined.
  Rationale: Foreign quota attribution is deterministic and directly violates project confinement.
  Authorized-user ADC files may omit a principal name, so absence must not be misreported as a
  mismatch; the command must still show that the account is unknown.
  Date: 2026-09-14.

- Decision: Add `nagarectl platform repin --version VERSION --yes` for never-deployed contexts.
  Rationale: `adopt` means attaching identity to legacy deployed objects, while `upgrade` is a
  guarded host-and-cluster transaction. A narrow re-pin makes the pre-resource state explicit and
  can fail permanently once deployment evidence exists.
  Date: 2026-09-14.

- Decision: Use absence of the context's GCE instance as the authoritative cloud evidence that the
  single-host cluster cannot yet exist; distinguish NotFound from lookup failure.
  Rationale: An unreachable kubeconfig alone cannot prove absence. In Nagare's current architecture,
  the cluster resides on that one context-owned host, so a successful project-scoped NotFound is a
  reliable boundary.
  Date: 2026-09-14.

- Decision: Amend ADRs 6 and 9 during implementation if the proposed interfaces remain.
  Rationale: Deployment-state identity and ADC quota attribution are durable extensions of those
  existing decisions, not task-local mechanics.
  Date: 2026-09-14.

- Decision: Resolve ADC in this precedence order: a nonblank
  `GOOGLE_APPLICATION_CREDENTIALS`, then `CLOUDSDK_CONFIG/application_default_credentials.json`,
  then `$HOME/.config/gcloud/application_default_credentials.json`.
  Rationale: This matches the credential sources operators can select and makes the exact file
  used by Nagare visible without exposing its contents.
  Date: 2026-09-14.

- Decision: Require a credential `type`, recognize authorized-user and service-account principals,
  and accept other credential types with an explicitly unknown principal.
  Rationale: Quota-project confinement is enforceable across credential kinds, while rejecting a
  future credential kind solely because its principal field is unfamiliar would be unnecessarily
  brittle.
  Date: 2026-09-14.

- Decision: Retain only credential kind, optional principal, optional quota project, and source in
  the typed ADC observation; do not include JSON parser details in malformed-file errors.
  Rationale: Token-bearing input must never enter `Show`, structured evidence, or repair output,
  including through parser excerpts.
  Date: 2026-09-14.

- Decision: Run a dedicated ADC refusal check before context-guard workspace preparation, and make
  `projectGuardInputsFor` independently validate ADC before its Pulumi config probe.
  Rationale: Workspace preparation can install dependencies and invoke Pulumi. The outer check
  protects the literal first Pulumi process, while the collector's own ordering preserves the
  invariant for upgrade and future callers.
  Date: 2026-09-14.

- Decision: Return non-fatal ADC findings from initialization and render them as both human warnings
  and a top-level structured `observations.warnings` array in context-guard JSON.
  Rationale: Principal absence or disagreement and missing quota attribution must be visible without
  being conflated with the deterministic foreign-quota refusal.
  Date: 2026-09-14.

- Decision: Classify only an explicit GCE resource-not-found diagnostic as `NotDeployed`; treat a
  successful malformed response, permission or network failure, and process startup failure as
  `DeploymentUnknown`.
  Rationale: Re-pin destroys no cloud state only when absence is positively established. Ambiguous
  observations must fail closed instead of becoming an absence bypass.
  Date: 2026-09-14.

- Decision: Derive cluster `NotDeployed` only from host `NotDeployed` and omit both absent identities
  from compatibility aggregation.
  Rationale: The current cluster lives exclusively on the context-owned host. This preserves real
  context patch skew while existing or uncertain resources without identities remain
  `legacy-unknown`.
  Date: 2026-09-14.

- Decision: Limit re-pin to the current packaged payload, cloud contexts, confirmed absence, normal
  context and ADC guards, and an explicit `--yes` confirmation.
  Rationale: Re-pin is a pre-deployment pin correction, not a general release selector or an
  alternative to upgrade/adoption.
  Date: 2026-09-14.

- Decision: Update a recognized generated host flake and its context pin as one guarded operation,
  preserve `host.nix` and `secrets.yaml`, and restore the previous context pin if the host commit
  fails.
  Rationale: ADR 5 requires one release identity across context-owned host inputs, while refusing
  unrecognized flakes prevents a narrow command from rewriting operator-owned structure.
  Date: 2026-09-14.

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

The plan closes both reported gaps. Initialization and all cloud project-guard collection now
validate the exact ADC file selected by environment precedence before Pulumi can start. Foreign
quota attribution, missing or malformed files, and unsafe reads fail closed without retaining or
printing token material; incomplete or disagreeing principal evidence remains visible as a warning.

Fresh cloud status now reports authoritative GCE absence as host and cluster `not-deployed`, so a
real context patch difference remains `patch-skew`. Existing unversioned objects and every
inconclusive lookup retain the prior `legacy-unknown` semantics. The new `platform repin` command is
limited to the current immutable payload and confirmed pre-deployment state, applies the normal
release, ADC, and project guards, and keeps a recognized generated host flake consistent without
changing operator-owned configuration or secrets.

IR-12 and IR-16 are completed; ADRs 9 and 6 respectively record the durable credential and
deployment-state rules. The focused Haskell gate passes all 505 tests, the packaged clone-free
integration covers success and fail-closed cases, strict OKF validation passes all 23 concepts, and
the complete native `nix flake check --print-build-logs` passes. No live GCP resource was created or
modified; all cloud behavior was verified hermetically.

