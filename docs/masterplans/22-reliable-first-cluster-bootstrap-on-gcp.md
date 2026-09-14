---
id: 22
slug: reliable-first-cluster-bootstrap-on-gcp
title: "Reliable first-cluster bootstrap on GCP"
kind: master-plan
created_at: 2026-09-14T04:16:14Z
intention: "intention_01m2f225p4e68bbf918ecvvwvr"
provenance:
  created_by:
    model: "gpt-5.6-sol"
    harness: "codex-cli"
    at: 2026-09-14T04:16:14Z
  revisions:
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-14T04:46:24Z
      mode: "implement"
      note: "Started EP-1 implementation and coordination"
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-14T13:38:21Z
      mode: "implement"
      note: "Started EP-3 implementation and coordination"
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-14T14:18:39Z
      mode: "implement"
      note: "Completed EP-3 and selected EP-4 as the next implementable child"
---

# Reliable first-cluster bootstrap on GCP

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope

After this initiative, an operator can start with a supported Nagare release and an empty GCP
project, create a context, provision one host, retrieve the correct cluster credentials, and run
cluster bootstrap once. Every cloud mutation is visibly tied to that context's project, a reviewed
Pulumi plan can be applied without a TTY, the first boot reaches a Ready k3s node without a reboot,
and TLS requests are limited to names intended for public applications. The consolidated onboarding
guide and a disposable-project rehearsal make that complete path observable.

The initiative owns the ten proposed improvement requests that directly block or mislead initial
GCP cluster bootstrap: [IR-10](../improvement-requests/operator-package-exports-lib-links.md),
[IR-11](../improvement-requests/boot-disk-size-docs-say-in-place.md),
[IR-12](../improvement-requests/check-the-adc-account-and-quota-project.md),
[IR-15](../improvement-requests/infra-up-cannot-apply-a-reviewed-plan-non-interactively.md),
[IR-16](../improvement-requests/undeployed-context-reports-legacy-unknown.md),
[IR-17](../improvement-requests/host-image-builder-escapes-the-context-project.md),
[IR-19](../improvement-requests/first-boot-data-disk-format-races-fsck.md),
[IR-20](../improvement-requests/fetch-a-per-context-kubeconfig.md),
[IR-22](../improvement-requests/system-internal-cert-sent-to-acme.md), and
[IR-23](../improvement-requests/wildcard-certs-for-system-namespaces.md).

[ExecPlan 132](../plans/132-make-cluster-bootstrap-wait-for-knative-webhooks.md) for IR-21 and
[ExecPlan 133](../plans/133-deliver-the-host-age-key-after-first-boot.md) for IR-18 are already
accepted independent plans. They are integration prerequisites, not children of this MasterPlan.
Completed bootstrap requests remain completed, and every request unrelated to first-cluster GCP
bootstrap—including cross-cluster diagnostics and Apple Container local mode—is explicitly out of
scope. This initiative does not redesign Nagare's application platform, add another cloud, replace
Pulumi or the remote-builder model, or make boot-disk growth in-place.


## Decomposition Strategy

The six child plans follow operator-visible boundaries rather than one plan per request. EP-1 makes
the release installable and establishes context-safe cluster access. EP-2 makes an undeployed
context truthful and safe before any resource exists. EP-3 owns the two expensive workstation-to-GCP
mutation paths: Pulumi updates and remote Nix builds. EP-4 owns the host's boot dependency graph.
EP-5 owns certificate issuer and namespace-selection policy. EP-6 depends on all of them and owns
the integrated runbook, regression checks, and live proof. This groups changes that share an
interface while keeping unrelated code paths independently testable.

A single large ExecPlan was rejected because it would couple Nix packaging, Haskell context state,
Pulumi execution, NixOS boot ordering, Kubernetes TLS configuration, and documentation into one
unreviewable change. Ten one-IR plans were also rejected: IR-10 and IR-20 share the installed
operator/access boundary; IR-12 and IR-16 share pre-deployment context evidence; IR-15 and IR-17
share guarded GCP execution; and IR-22 and IR-23 share Knative certificate configuration. The final
rehearsal remains separate because it must validate the composed behavior without taking ownership
of those implementations.

The ADR scan found the following governing decisions. [ADR 3](../adr/0003-package-the-typed-config-runtime-with-nagarectl.md),
[ADR 4](../adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md), and
[ADR 7](../adr/0007-publish-immutable-nix-releases-from-validated-tags.md) govern the installed operator
surface. [ADR 5](../adr/0005-use-context-owned-host-flakes-for-operator-nixos-inputs.md) and
[ADR 6](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md) govern
context, host, and cluster identity. [ADR 9](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md)
governs every GCP mutation. [ADR 10](../adr/0010-the-active-context-owns-the-acme-identity.md)
governs public certificate identity. [ADR 11](../adr/0011-host-activation-is-guarded-and-self-reverting.md),
[ADR 12](../adr/0012-platform-data-disk-capacity-is-forward-only-and-grows-itself.md), and
[ADR 14](../adr/0014-the-active-context-owns-the-vm-shape.md) constrain host boot and
shape. [ADR 18](../adr/0018-the-upgrade-transaction-is-as-guarded-as-the-recipes-it-replaces.md) governs
upgrade-time Pulumi application. Child plans must amend the owning ADR when implementation makes a
durable decision; this planning pass creates no ADR merely for task decomposition.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| EP-1 | Install a clean operator package and fetch a context-safe kubeconfig | [docs/plans/134-install-a-clean-operator-package-and-fetch-a-context-safe-kubeconfig.md](../plans/134-install-a-clean-operator-package-and-fetch-a-context-safe-kubeconfig.md) | None | None | Complete |
| EP-2 | Make fresh GCP contexts preflight and re-pin cleanly | [docs/plans/135-make-fresh-gcp-contexts-preflight-and-re-pin-cleanly.md](../plans/135-make-fresh-gcp-contexts-preflight-and-re-pin-cleanly.md) | None | None | Complete |
| EP-3 | Apply reviewed infrastructure and confine remote builders | [docs/plans/136-apply-reviewed-infrastructure-and-confine-remote-builders.md](../plans/136-apply-reviewed-infrastructure-and-confine-remote-builders.md) | None | EP-2 | Complete |
| EP-4 | Make a new GCP host reach Ready on its first boot | [docs/plans/137-make-a-new-gcp-host-reach-ready-on-its-first-boot.md](../plans/137-make-a-new-gcp-host-reach-ready-on-its-first-boot.md) | None | None | Not Started |
| EP-5 | Keep bootstrap TLS issuance within intended names | [docs/plans/138-keep-bootstrap-tls-issuance-within-intended-names.md](../plans/138-keep-bootstrap-tls-issuance-within-intended-names.md) | None | EP-1 | Not Started |
| EP-6 | Prove and document one-pass GCP cluster onboarding | [docs/plans/139-prove-and-document-one-pass-gcp-cluster-onboarding.md](../plans/139-prove-and-document-one-pass-gcp-cluster-onboarding.md) | EP-1, EP-2, EP-3, EP-4, EP-5 | None | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

EP-1, EP-2, EP-3, EP-4, and EP-5 can begin in parallel. EP-3 has a soft dependency on EP-2 because
its apply-time guard should consume EP-2's Application Default Credentials evidence when available;
it can initially build against the current context-guard interface and reconcile before completion.
EP-5 has a soft dependency on EP-1 because cluster-mutating recipes should eventually call EP-1's
cluster identity guard, but its issuer and selector changes are independently testable.

EP-4 has an external integration dependency on ExecPlan 133: a Ready node is not a complete usable
host until the age key can be placed and Tailscale can join. EP-5 has an external integration
dependency on ExecPlan 132 because both edit `justfile` bootstrap ordering and Knative ConfigMaps.
Those external plans do not block isolated implementation, but their changes must be reconciled
before the live rehearsal.

EP-6 has hard dependencies on all five children because it validates their public commands and
documents one linear path. Its live cloud acceptance also requires ExecPlans 132 and 133 complete.
The hard dependency does not mean all work must merge serially; it means EP-6 cannot claim the
one-pass outcome until each upstream behavior exists.


## Integration Points

`cli/nagarectl/app/Main.hs` and `justfile` are shared command surfaces. EP-1 owns the cluster guard,
kubeconfig-fetch command, and launcher exposure. EP-2 owns ADC observations and undeployed-context
state. EP-3 owns saved-plan preview/apply commands and builder selection. EP-5 may only consume the
cluster guard from EP-1; it must not define a second cluster identity check. EP-6 edits command help
or recipes only to align documentation and tests with the interfaces their owning plans established.

The selected context is the shared identity root. EP-2 extends `ProjectGuardInputs` with ADC
evidence. EP-3 consumes that verdict before Pulumi or builder-related GCP operations, and EP-1
derives the expected Kubernetes node name from the same context-owned host configuration. Any
change that makes saved Pulumi plans context-bound execution artifacts should amend ADR 18; builder
project ownership should amend ADR 9. EP-2 owns any ADR 6 amendment for the explicit `not-deployed`
state.

The installed Nix package is shared by EP-1 and EP-3. EP-1 owns filtering user-facing outputs to
`bin`, required `share`, and `nix-support`, and adds `socat`. EP-3 may add a builder proxy/helper but
must use that package boundary rather than reintroducing build-only link farms.

The Knative ConfigMaps and `personal` namespace are shared by EP-5, ExecPlan 132, and EP-6. EP-5
owns the issuer references, the label key `nagare.dev/app-namespace=true`, and the selector that
consumes it. ExecPlan 132 owns webhook readiness and patch retries. EP-6 only verifies their composed
order. If implementation changes the durable rule that public ACME issuers receive only public app
names, EP-5 should amend ADR 10 or create a narrowly scoped successor ADR.

`docs/user/onboarding-bring-your-own-project.md` is the final integrated narrative. Child plans may
update focused reference pages, but EP-6 owns the final ordering and removes contradictory legacy
steps. This prevents parallel plans from each inventing a different end-to-end sequence.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. This section provides an at-a-glance view of the entire initiative.

- [x] (2026-09-14T05:29:57Z) EP-1: ship collision-free operator tools, context kubeconfig fetch, and a cluster identity guard.
- [x] (2026-09-14T13:18:00Z) EP-2: validate ADC and represent/re-pin an undeployed context safely.
- [x] (2026-09-14T14:18:39Z) EP-3: bind reviewed Pulumi plans and remote builders to the selected context.
- [ ] EP-4: serialize blank-disk formatting before fsck and prove first-boot k3s readiness.
- [ ] EP-5: separate internal issuers and opt app namespaces into public wildcard certificates.
- [ ] EP-6: correct boot-disk guidance and pass hermetic plus authorized live onboarding rehearsals.
- [ ] External: complete ExecPlans 132 and 133 before EP-6's live cloud acceptance.


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

- EP-1 found that the pinned nixpkgs `symlinkJoin` does not honor `pathsToLink`; its implementation
  links complete inputs and reproduced the Darwin `lib/links` collision. `buildEnv` provides the
  required filtered public surface and passed the deliberate profile-collision fixture.

- The final native check compiles both normal and profiled Haskell outputs. EP-1 passed every
  buildable `aarch64-darwin` check and all 496 Haskell tests; Nix omitted the incompatible
  `x86_64-linux` outputs, which remain CI/native-runner evidence under ADR 7.

- EP-2 found that a Kubernetes marker lookup cannot distinguish true absence from an unreachable or
  unversioned cluster. A project-scoped GCE NotFound for the context-owned single host is the
  authoritative absence boundary; every other probe result remains unknown and blocks re-pin.

- Moving ADC validation ahead of Pulumi intentionally changed a missing-Pulumi integration fixture:
  it now needs matching ADC evidence to reach the diagnostic it was designed to test. This confirms
  the shared guard fails in the intended order instead of starting workspace or Pulumi work first.

- EP-3 confirmed that Pulumi's saved plan constrains provider operations but does not bind Nagare's
  context identity. A private sidecar supplies the context/project/stack/backend/payload/program
  boundary, while apply remains explicitly constrained rather than atomic.

- EP-3 found that Nix flake evaluation ignores new untracked proxy/test files until they are staged.
  It also exposed a pre-existing improvement-request profile advisory: 22 records lack the newly
  recommended `reviews` field, while strict structure and log validation still pass.


## Decision Log

Record every decomposition or coordination decision made while working on the master
plan.

- Decision: Limit this MasterPlan to initial bootstrap of one Nagare cluster on GCP.
  Rationale: The user explicitly excluded unrelated improvement requests; a narrow outcome keeps the
  dependency graph testable and avoids turning backlog triage into an open-ended platform plan.
  Date: 2026-09-14.

- Decision: Group ten unplanned requests into six functional child plans and keep ExecPlans 132 and
  133 independent.
  Rationale: Shared interfaces belong to one owner, while already accepted plans retain their
  existing provenance, intention, and lifecycle.
  Date: 2026-09-14.

- Decision: Treat a saved Pulumi plan as a constrained execution artifact, not as an atomic
  transaction, and wrap it in Nagare-owned context metadata.
  Rationale: Source inspection of `mori://pulumi/pulumi/packages/pulumi` shows that a deployment plan
  constrains resource goals and operations but does not encode Nagare context, GCP project, backend,
  or stack. Nagare must bind and verify those facts itself, and must not promise all-or-nothing cloud
  execution.
  Date: 2026-09-14.

- Decision: Reserve the end-to-end onboarding narrative and live rehearsal for EP-6.
  Rationale: One plan must verify the integrated sequence after all independently testable changes,
  including external ExecPlans 132 and 133, without duplicating their implementation ownership.
  Date: 2026-09-14.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision. Before marking the MasterPlan complete,
distill durable project context from this MasterPlan and its child ExecPlans into
docs/adr/. Keep task-local execution and coordination details here.

EP-1 is complete. Operators can install the full package beside Home Manager, use its packaged IAP
transport to create a private context-named kubeconfig, and rely on a shared fail-closed cluster
identity guard before the direct cloud Kubernetes mutation recipes. IR-10 and IR-20 are completed;
ADRs 4 and 7 now own the durable credential-state and release-profile boundaries. The isolated
implementation passed all native repository gates. The integrated live GCP proof remains assigned
to EP-6 after the other children establish their parts of the bootstrap path.

EP-2 is complete. Init and every cloud context guard now validate token-safe ADC evidence before
Pulumi; foreign quota attribution refuses while principal uncertainty stays visible. Status
distinguishes authoritative absence from legacy or unreachable state. The guarded command
`nagarectl platform repin` advances only a never-deployed context and recognized generated host
metadata.
IR-12 and IR-16 are completed, with durable rules recorded in ADRs 9 and 6. All 505 focused tests,
strict OKF validation, the clone-free packaged scenario, and the complete native flake gate pass.

EP-3 is complete. Operators and upgrade transactions can apply the exact saved Pulumi plan they
reviewed without a TTY; stale or cross-context bundles refuse before update. Host-image bypasses
ambient Nix builder selection, displays a context-owned GCP builder, and requires a named exception
for another project. IR-15 and IR-17 are completed, and ADRs 18 and 9 record these durable rules.
All 508 Haskell tests and every buildable native flake check pass. EP-4 is the next registry-ordered
implementable child; it has no hard dependencies.


Revision note (2026-09-14): Completed EP-1, closed IR-10 and IR-20, recorded the durable package
and kubeconfig boundaries in ADRs 7 and 4, and identified EP-2 as the next implementable child.

Revision note (2026-09-14): Started EP-2 after confirming it has no unmet hard dependencies.

Revision note (2026-09-14): Completed EP-2, closed IR-12 and IR-16, amended ADRs 9 and 6, and
satisfied EP-3's soft dependency with shared ADC guard evidence.

Revision note (2026-09-14): Started EP-3 after confirming it has no hard dependencies and its
soft dependency on EP-2 is satisfied.

Revision note (2026-09-14): Completed EP-3, closed IR-15 and IR-17, amended ADRs 18 and 9, and
identified EP-4 as the next implementable child.
