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
---

# Prove isolated replacement rehearsal and static-IP handoff

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

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


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Milestone 1: add a fail-closed dry-run model and fake-`gcloud` contract tests for every spike operation.
- [ ] Milestone 2: run the disposable live two-host/IAP/static-IP forward-and-reverse handoff and retain redacted timing evidence.
- [ ] Milestone 3: record the proven topology and budget semantics in a new ADR, or revise the MasterPlan if the proof fails.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


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


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

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

Create a repository-convention ADR under `docs/adr/` after inspecting the next filename and existing
frontmatter shape. Record only behavior established by the spike: no load balancer, no DNS mutation,
IAP-only candidate verification, independent candidate state, explicit address ownership checks,
deadline reserve, and rollback before expiry. Reference this MasterPlan and EP-122. If the provider
or live platform cannot perform the measured reverse handoff safely, do not write the assumed ADR;
instead update this ExecPlan and the MasterPlan with the observed blocker and a revised topology.


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
