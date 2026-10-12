---
id: 185
slug: make-inventory-status-answer-in-seconds
title: "Make inventory status answer in seconds"
kind: exec-plan
created_at: 2026-10-12T04:20:40Z
master_plan: "docs/masterplans/26-make-platform-changes-and-releases-routine-after-the-inventory-release.md"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-10-12T04:20:40Z
---

# Make inventory status answer in seconds

## Purpose / Big Picture

Every operator change on the intranet starts with `nagarectl inventory status` to check that no
transaction is open, and that command takes 2–3 minutes (finding F119 in
[the findings register](../audits/mp23-findings.md)). After this plan, the open-transaction check
answers in seconds and a full status of the intranet in well under a minute. The operator sees it
directly: `time nagarectl inventory status --json` from the operator repository
(`mori://tan/tan-ng-labs`) against the intranet.

## Context

Measured on 2026-10-12 with the v0.5.0 CLI against the intranet (248 observed resources, 207 of
them Kubernetes objects, 1,231 store objects, 9.4 MB): 109 s wall, of which observation took
104 s. Reading the store is not the cost.

`cli/nagarectl/app/Nagare/Cli/Commands/Inventory/Status.hs` observes each executor in turn
(Kubernetes, Helm, Pulumi, artifact, host, cache, broker, CDN, foundation, access). The Kubernetes
adapter in `cli/nagarectl/src/Nagare/Inventory/Adapters/KubernetesRuntime.hs` reads each object with
its own `kubectl get` process, and `observeKubernetesHealth` reads it again for readiness. Each call
passes `runtimeGuard` first; process samples during the run showed `kubectl get nodes` and
`kubectl config current-context` repeatedly, so the guard may be re-run per object. M1 confirms
where the time goes before anything changes.

Twelve resources report "provider observation is unavailable" (the access grant, image artifacts
and five observability Helm charts), so `observationComplete` is false on a healthy context. That
is part of this plan only where it is cheap to say why in the output.

## Progress

- [ ] M1. Profile: per-executor and per-process wall time for one intranet status run (read-only),
  with the count of `kubectl` processes and how many are guard calls. Pass: a table in the Decision
  Log that accounts for at least 90% of the 104 s.
- [ ] M2. A store-only answer: `nagarectl inventory status --store-only` (name decided in M1)
  reads the head and journal and prints `activeTransaction` and the accepted scopes without any
  provider observation. Pass: under 10 s against the intranet, and a test that it starts no
  provider process. The operator runbook's "before any change" check switches to it.
- [ ] M3. One guard per status run, and Kubernetes objects read in batches (one `kubectl get` per
  kind and namespace, or one list per kind) that serve both the presence and the readiness
  observation. Pass: identical findings to the v0.5.0 status on the same context, recorded by
  diffing the two JSON outputs, and a full intranet status under 30 s.
- [ ] M4. Independent executors observed concurrently, bounded. Pass: same findings as M3, and the
  wall time reported in the Decision Log.

## Decision Log

- Decision: Track F119 as its own plan under MasterPlan 26 instead of folding it into EP-172 or
  EP-184. Rationale: it is operator command speed, not upgrades or gate time, and it can land
  independently in the next release. Date: 2026-10-12 (operator approved recording F119 and a plan).
