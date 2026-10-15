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

- [x] M1. Profile: per-executor and per-process wall time for one intranet status run (read-only),
  with the count of `kubectl` processes and how many are guard calls. Pass: a table in the Decision
  Log that accounts for at least 90% of the 104 s. Done 2026-10-12 against v0.6.1: the table below
  accounts for all 143 s of the profiled run (139 s unprofiled).
- [x] M2. A store-only answer: `nagarectl inventory store status --json` (decided in M1)
  reads the head and journal and prints `activeTransaction` and the accepted scopes without any
  provider observation. Pass: under 10 s against the intranet, and a test that it starts no
  provider process. The operator runbook's "before any change" check switches to it. Done
  2026-10-12: 5.6–7.2 s in six of eight intranet runs. Its only processes are the store's three
  ownership reads (`config-helper`, `buckets describe`, `projects describe`); in the other two
  runs `gcloud projects describe` stalled past the 15 s capture timeout and was retried (33.7 s,
  44 s). The command is executable-private, so the "no provider process" proof is the shim log,
  not a suite test. The `mori://tan/tan-ng-labs` runbook is the operator's to switch.
- [x] M3. One guard per status run, and Kubernetes objects read in batches (one `kubectl get` per
  kind and namespace, or one list per kind) that serve both the presence and the readiness
  observation. Pass: identical findings to the v0.5.0 status on the same context, recorded by
  diffing the two JSON outputs, and a full intranet status under 30 s. 2026-10-12: all 248
  findings and every other field identical to the v0.6.1 run; 67 s and 83 processes (from 143 s
  and 475). The 54 batched reads take 25 s in series, so the 30 s needs M4. Landed as
  `894b58b7`; with M4 the full status is under 30 s (below).
- [x] M4. Independent executors observed concurrently, bounded. Pass: same findings as M3, and the
  wall time reported in the Decision Log. 2026-10-12: three intranet runs, 25.4 s, 27.7 s and
  22.7 s, each with all 248 findings and every other field identical to v0.6.1, 83 processes.

## Decision Log

- Decision: Track F119 as its own plan under MasterPlan 26 instead of folding it into EP-172 or
  EP-184. Rationale: it is operator command speed, not upgrades or gate time, and it can land
  independently in the next release. Date: 2026-10-12 (operator approved recording F119 and a plan).

- Decision: M1 profile, 2026-10-12, v0.6.1 CLI (`080ae60a`) from `mori://tan/tan-ng-labs` against
  the intranet after its v0.6.1 upgrade committed, read-only, every child process logged by a PATH
  shim. 139 s unprofiled, 143 s profiled, 475 processes, 248 findings, no active transaction. The
  shim log covers the run end to end (first process at +0.1 s, last ends 0.4 s before exit):

  | Phase (in run order) | Wall | Processes |
  | --- | --- | --- |
  | Store read and project guard | 6.0 s | 3 gcloud |
  | Kubernetes presence | 47.2 s | 206 `kubectl get`, 7 guard |
  | Helm presence | 9.2 s | 5 helm, 5 `kubectl get`, 8 guard |
  | Pulumi, foundation, artifact, host, cache, broker, access | 22.9 s | 9 gcloud, 3 pulumi, 1 nix |
  | Helm health | 9.8 s | 5 helm, 6 `kubectl get`, 12 guard |
  | Kubernetes health | 48.8 s | 68 `kubectl get`, 137 guard |

  162 of 475 processes are guard calls (`kubectl get nodes` at about 0.31 s each,
  `config current-context`), 29 s together. The readiness pass re-reads each of 68 objects with a
  fresh guard, so it costs as much as the presence pass. The 287 object reads fall in 54
  (kind, namespace) pairs over 8 namespaces. Each Helm chart is read twice (`vmks` takes 3–4 s per
  read), and the project guard (`config-helper` plus `projects describe`, 2.8 s) runs three times.
  Consequences: M3 reads Kubernetes objects once per (kind, namespace) into a per-run snapshot that
  answers both passes, and runs the cluster guard once per run plus once before printing; the Helm
  health pass reuses the presence read.
- Decision: M2 uses the existing `inventory store status --json` instead of a new flag. It already
  reads only `head.json` and reports `activeTransaction`, `dataFence` and `executorClaim`, and the
  nagare runbooks already use it for the open-transaction check; it gains `accepted`, `converged`
  and `transition`. Date: 2026-10-12.
- Decision: M4 lanes. Kubernetes (its snapshot reads at most eight at a time), Helm, artifact,
  host, cache, broker, CDN and access each run in their own lane; Pulumi and the cloud foundation
  share one because both drive `pulumi` in the same workspace. Retained members and the health
  passes run after the lanes from the snapshot and the remembered Helm reads. A refusal in any
  lane cancels the others and exits as before. Critical path on the intranet: about 5 s store open,
  then about 13 s for the slowest lane (the `vmks` chart and the CRD read). Date: 2026-10-12.


## Outcomes & Retrospective

Complete 2026-10-12. `inventory status` on the intranet went from 139 s to 23–28 s (`894b58b7`,
`90370d07`), and `inventory store status` answers in 5.6–7.2 s without a provider process.
