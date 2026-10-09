---
id: 122
slug: prove-isolated-replacement-rehearsal-and-static-ip-handoff
title: "Prove isolated replacement rehearsal and static-IP handoff"
kind: exec-plan
created_at: 2026-09-13T22:09:03Z
intention: "intention_01m2ecthzwek7t64p7wqn0x9wj"
master_plan: "docs/masterplans/21-rehearsed-replacement-upgrades-with-bounded-downtime-for-nagare.md"
provenance:
  created_by:
    model: "gpt-5.6-sol"
    harness: "codex-cli"
    at: 2026-09-13T22:09:03Z
  revisions:
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-16T04:38:36Z
      mode: "update"
      note: "Refresh feasibility gate against current bootstrap rehearsal and Pulumi evidence"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-09T19:45:59Z
      mode: "update"
      note: "Refresh MP-21 as optional inventory-backed replacement after MP-23 upgrade drills"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-09T22:13:41Z
      mode: "update"
      note: "Cascade 2026-10-09 re-scope of MasterPlans 21/25/26"
---

# Prove isolated replacement rehearsal and static-IP handoff

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

**Current scope (2026-10-09).** This child implements optional machine/cluster replacement after
MP-23, not a prerequisite for ordinary node or PostgreSQL upgrades. The
[production checklist](../releases/production-readiness-checklist.md) credits those completed drills.
MP-23's typed scopes, reviewed native effects, conditional shared history, receipt verification and
proof-based recovery are the implementation foundation. Replacement phase records never grant
mutation authority independently of inventory admission. Proposed replacement commands below remain
unavailable until their owned implementation and acceptance are complete.

Before Nagare encodes a replacement-upgrade state machine, prove the cloud operations on which its
safety promise depends. This plan delivers a disposable same-project spike that creates two tiny
hosts and a test regional address, reaches the inactive host through IAP, transfers the address from
the old host to the candidate without changing DNS, and transfers it back after an injected
verification failure. It measures both directions and records structured evidence without touching
the context's real VM, disks, address, DNS zone, or buckets.

The user-visible result is a command that either prints a JSON proof that forward cutover plus
reserved rollback fits a requested budget, or refuses with the failed invariant. Its evidence fixes
the resource topology and operation order used by the remaining child plans. This plan is a
feasibility gate, not the production cutover implementation.

The current flake now includes a hermetic `gcp-bootstrap-rehearsal` that proves two reviewed Pulumi
plans, context-bound builder/kubeconfig identity, first-boot readiness, and certificate confinement.
That check supplies reusable setup/identity patterns but does not perform a live two-host reserved-
address handoff, so none of this plan's milestones are complete.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Milestone 1: add a fail-closed dry-run model and fake-`gcloud` contract tests for every spike operation. Deferred until the operator resumes MasterPlan 21 (2026-10-09); Milestone 2 runs first as a measurement spike.
- [ ] Milestone 2: run the disposable live two-host/IAP/static-IP forward-and-reverse handoff and retain redacted timing evidence.
- [ ] Milestone 3: record the proven topology and budget semantics in ADR 19, or revise the MasterPlan if the proof fails.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Observation: the repository gained a hermetic GCP bootstrap rehearsal after this plan was drafted,
  but it deliberately fakes provider operations and cannot establish address detach/attach timing or
  rollback behavior.
  Evidence: `checks.aarch64-darwin.gcp-bootstrap-rehearsal` passes two reviewed-plan applications and
  identity/certificate assertions in `nix flake check`; it creates no live GCE address users.


## Decision Log

Record every decision made while working on the plan.

- Decision: use a separately reserved disposable address and transaction-prefixed resources for the
  spike; never detach the active context's `publicIp` during feasibility work.
  Rationale: the proof must exercise the same GCE API shape without turning research into a
  production outage.
  Date: 2026-09-13.
- Decision: require a live reverse handoff after an injected failed health check.
  Rationale: a fast forward move does not establish that the downtime budget can include rollback.
  Date: 2026-09-13.
- Decision: reuse the bootstrap rehearsal's context, reviewed-plan, identity, and certificate
  fixtures where applicable, while retaining a separate operator-approved live handoff proof.
  Rationale: hermetic coverage should not be duplicated, but provider control-plane timing and
  address ownership can only be established by the scoped live experiment this plan owns.
  Date: 2026-09-15.

- Decision (operator, 2026-10-09): Run Milestone 2 first, as a measurement spike, and defer Milestone 1's fake-`gcloud` contract tests until the operator resumes [MasterPlan 21](../masterplans/21-rehearsed-replacement-upgrades-with-bounded-downtime-for-nagare.md).
  - The spike is one script with a `--dry-run` that prints every command.
  - It runs under `_require_target_project` against two tiny disposable VMs and a test reserved address, never the context's own.
  - It moves the address forward and back at least five times, timing detach, attach, the first TCP and TLS connect through the address, and IAP reachability of the inactive host.
  - It deletes what it created by exact name.
  - The operator approves the reviewed dry run once, as a single bounded sequence.

  Rationale: The spike measures provider behaviour, not a Nagare code path, so ADR 25's interpreter-first rule does not apply to it. Its numbers decide whether the rest of MasterPlan 21 is worth building, which is the cheapest decision available.
  Date: 2026-10-09


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

The spike is narrowly scoped feasibility evidence for replacement. It does not reopen the proved
in-place node/database upgrade paths. EP-123 may develop its abstract model/store binding independently;
EP-124 is the join that requires both complete and their contracts reconciled. Before selecting GCP
or Pulumi APIs, use Mori to locate dependency source/docs; inspect the repository's actual lock and
verify authoritative registry/tags before changing versions. September's provider version is
historical evidence, not a refreshed pin.

Follow [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md): establish
provider semantics, model interruption/unknown outcomes with injected interpreters, then confirm
with the bounded disposable live run after `docs/runbooks/before-a-native-run.md` and operator approval.
Keep scripts thin transport/fixture wrappers; durable readiness and recovery policy belong in typed
Haskell and the shared inventory driver. The exact run ledger is disposable test-resource evidence,
not a competing production ownership store. Its interruption/cleanup manifest must exclude all
active context resources and bind exact creation identities; a name prefix is never deletion authority.

Amend [ADR 19](../adr/0019-replacement-cutovers-reserve-rollback-before-write-admission.md) with the
measured topology and timing contract. Do not create a duplicate replacement ADR merely because the
original September plan expected one to be absent. Provider-outage observations remain explicit;
a successful sample is not an unconditional downtime bound.

Nagare is a single-node GCP platform. `infra/pulumi/src/components/NagarePerimeter.ts` creates a
regional reserved address and one wildcard Cloud DNS record that points at it.
`infra/pulumi/src/components/NagareInstance.ts` assigns that address to the only VM through the
network interface's `accessConfigs` and attaches one `pd-balanced` data disk read-write. The current
program has no inactive candidate.

An **address handoff** means unassigning the already-reserved IPv4 address from one network
interface and assigning the same address to another. DNS is outside the operation because its A
record continues to contain the same address. A **rollback reserve** is time deliberately withheld
from the forward attempt so Nagare can return the address and restart the old host before the hard
downtime deadline. IAP is Google's identity-aware TCP tunnel; `scripts/iap-ssh.sh` is Nagare's
context-confined wrapper and shows the existing access pattern.

Google's current contract permits a reserved external address to be unassigned and reassigned.
Stopping a VM retains attached persistent disks and configuration, while the existing
`pd-balanced` disk is effectively a single-writer resource for Nagare's ext4 use. The locked Pulumi
provider is `@pulumi/gcp` 8.41.1 in `infra/pulumi/package-lock.json`; Mori had no registered provider
source, so implementation must inspect the declarations under
`infra/pulumi/node_modules/@pulumi/gcp/compute/` and verify the live CLI behavior instead of guessing
from a newer provider release. Do not traverse `/nix/store`.

[ADR 9](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md) requires
every cloud mutation to prove the active context project, including globally named or independently
addressed objects. [ADR 11](../adr/0011-host-activation-is-guarded-and-self-reverting.md) explains
why a rollback path must be mechanically observable rather than prose. [ADR 14](../adr/0014-the-active-context-owns-the-vm-shape.md)
and [ADR 18](../adr/0018-the-upgrade-transaction-is-as-guarded-as-the-recipes-it-replaces.md)
require replacement work to remain explicit and guarded. No relevant cross-repository ADR was found
through Mori.

The current guarded Pulumi boundary is `Nagare.Infra.Plan` plus
`Nagare.Platform.PulumiReceipt`. Although the spike uses explicit `gcloud` for the handoff operation
being measured, any Pulumi setup or convergence step must use a retained reviewed plan and explicit
completion/recovery evidence. The flake's `gcp-bootstrap-rehearsal` is the current hermetic reference
for context-bound provisioning behavior.


## Plan of Work

### Milestone 1 — Make the spike reviewable without cloud access

Add `scripts/spike-replacement-handoff.sh`. It must source `scripts/lib/target.sh`, require a cloud
context, call the project guard before every mutation, derive an alphanumeric resource suffix from a
generated run id, and refuse any resource whose name or self-link is not recorded in the run's JSON
ledger. Support `--dry-run`, `--json-output`, `--downtime-budget-seconds`, and a separate `--apply
--yes`; default to no mutation. The dry run prints the intended project, zone, two instance names,
two boot disks, test address, firewall assumptions, and cleanup order.

Add `scripts/test-spike-replacement-handoff.sh` with fake `gcloud`, clock, and health-check commands.
Cover project mismatch, a name collision, partial creation, failed IAP verification, failed forward
health, deadline exhaustion, successful rollback, and idempotent cleanup. Register the test as a Nix
check in the existing `nix/checks` structure. Acceptance is that every fake-cloud mutation carries
an explicit project and zone and that a failure never addresses the production `instanceName`,
`publicIp`, or `dataDiskName` returned by Pulumi.

### Milestone 2 — Prove and measure the live cloud behavior

With an operator-approved cloud context, have the script create a disposable reserved address and
two inexpensive VMs from an ordinary project-visible image. Both return distinct health bodies over
HTTP. Keep the candidate without the test address initially and prove its health through an IAP TCP
tunnel using the same `Host` header that public verification will use. Assign the test address to the
old VM, observe the old body, then start the downtime clock, unassign it, assign it to the candidate,
and observe the candidate body. Inject a failed acceptance result, reverse the address, and observe
the old body again.

The JSON evidence records monotonic elapsed durations, command exit states, resolved self-links,
address users before and after each move, and final cleanup. It must contain no access tokens,
kubeconfigs, SSH private paths, or unrelated stack output. The live run passes only when forward
handoff plus the measured reverse path and safety margin fit the requested budget. Delete every
disposable resource after evidence has been copied outside the temporary directory.

### Milestone 3 — Fix the architecture contract

Amend ADR 19 with the topology, operations and budget semantics actually established by the spike.
Record no load balancer, unchanged DNS, IAP candidate verification, independent state, exact
address/instance identities, monotonic timing and reverse-handoff reserve. If the proof fails,
record the observed blocker and revise this child and MP-21 before dependent implementation.
Do not publish an assumed topology as measured fact. EP-123 consumes the report and reconciles
its phase/evidence contract before EP-124 begins.



## Concrete Steps

Run from the repository root:

```bash
bash -n scripts/spike-replacement-handoff.sh scripts/test-spike-replacement-handoff.sh
scripts/test-spike-replacement-handoff.sh
nix build .#checks.$(nix eval --impure --raw --expr builtins.currentSystem).replacement-handoff-contract
```

Review the non-mutating plan against the selected cloud context:

```bash
scripts/spike-replacement-handoff.sh \
  --dry-run \
  --downtime-budget-seconds 900 \
  --json-output .tmp/replacement-handoff-plan.json
jq '{project,zone,resources,budgetSeconds,mutations}' .tmp/replacement-handoff-plan.json
```

After explicit operator approval, run the disposable proof:

```bash
scripts/spike-replacement-handoff.sh \
  --apply --yes \
  --downtime-budget-seconds 900 \
  --json-output .tmp/replacement-handoff-live.json
jq '{result,forwardSeconds,rollbackSeconds,safetyMarginSeconds,cleanup}' \
  .tmp/replacement-handoff-live.json
```

Expected result shape:

```json
{
  "result": "proved",
  "forwardSeconds": 0,
  "rollbackSeconds": 0,
  "safetyMarginSeconds": 0,
  "cleanup": "complete"
}
```

The values must be actual positive measurements; zeroes above are placeholders describing the
schema, not acceptable live evidence.


## Validation and Acceptance

Offline acceptance requires the fake-cloud test and its Nix check to pass. Search the captured fake
argv and confirm every mutation contains the active project and zone. Inject failure after each
creation and handoff step; cleanup must delete only ledger-owned disposable objects and succeed when
repeated.

Live acceptance requires all of the following observations in one evidence file: candidate health
was proven through IAP before the address moved; the old response was served before downtime; the
same address served the candidate response after handoff; an injected rejection returned the same
address to the old VM; the combined measured forward/rollback/safety calculation fit 900 seconds;
and no disposable resource remained. The Pulumi outputs for the real VM, data disk, public IP, DNS
zone, and buckets must be identical before and after the run.


## Idempotence and Recovery

Dry-run and fake-cloud tests are repeatable. Live creation resumes from the JSON ledger and verifies
the full self-link before reusing or deleting an object. A missing ledger is a refusal, never an
invitation to discover resources by prefix. If interrupted while the test address is on the
candidate, rerunning with the same ledger first returns it to the old disposable VM and then cleans
up. If cleanup cannot prove ownership, it prints exact manual `gcloud describe` commands and stops
without deletion.

The spike never operates on the active context's production address. Therefore its worst partial
failure is temporary test-resource cost, not service interruption.


## Interfaces and Dependencies

`scripts/spike-replacement-handoff.sh` is the only live entry point. Its JSON schema is version 1
and contains `runId`, `context`, `project`, `zone`, `resources`, `observations`, `forwardSeconds`,
`rollbackSeconds`, `safetyMarginSeconds`, `budgetSeconds`, `result`, and `cleanup`. EP-123 consumes
the phase and timing conclusions, not the spike script itself.

Use the repository's existing Bash target/project guard in `scripts/lib/target.sh`,
`scripts/iap-ssh.sh` for tunnel conventions, Google Cloud CLI for the disposable proof, `jq` for the
ledger, and the repository's Nix shell/check infrastructure. Do not add a long-lived cloud resource
or a runtime Haskell dependency. Inspect the locked `@pulumi/gcp` source declarations before any
later plan chooses a Pulumi resource shape.


Revision note (2026-09-15): Refreshed the feasibility gate against the new hermetic GCP bootstrap
rehearsal and guarded Pulumi evidence boundary while keeping the live forward/reverse address proof
explicitly unimplemented.


Revision note (2026-10-09): Aligned this replacement-specific child with MP-23's accepted upgrade
inputs and single inventory authority, current identity/recovery/validation contracts and the
optional scope in the refreshed MasterPlan. No implementation milestone is newly accepted.
