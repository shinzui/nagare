---
id: 68
slug: doctor-diagnostics-correctness
title: "Doctor Diagnostics Correctness"
kind: exec-plan
created_at: 2026-06-11T02:37:50Z
intention: "intention_01ktt8he4vepkb0gbp2k9z5fc3"
master_plan: "docs/masterplans/13-live-audit-hardening-control-plane-abstractions-and-declarative-cluster-configuration.md"
---

# Doctor Diagnostics Correctness

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

Full plan before trimming: [68-doctor-diagnostics-correctness.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/68-doctor-diagnostics-correctness.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

`nagarectl doctor` is the one command an operator runs to ask "is the platform healthy, and
if not, exactly what do I paste to fix it?" It inspects the live cluster through ordinary
command-line tools (`gcloud`, `kubectl`, `pulumi`, `gsutil`), grades roughly nineteen facets
of the system as OK / WARN / FAIL, prints a checklist with a one-line remediation under every
non-OK line, and exits non-zero if and only if at least one facet is a hard FAIL. The whole
value of the command rests on a single property: **it must tell the truth.** A check that
FAILs on a healthy cluster trains operators to ignore red lines, and a missing check hides a
real failure mode behind a green summary.

On 2026-06-10 the `nagare-01` cluster was inspected live for the first time in weeks. Every
application served HTTP 200 through the gateway, every control-plane Deployment was rolled
out, TLS issuance was healthy — and `nagarectl doctor` nonetheless printed exactly one red
line:

```text
  [FAIL]  Kourier ingress          Ingress is not serving on the reserved static IP.
          fix: kubectl get svc -n kourier-system kourier -o wide and compare against: pulumi -C infra/pulumi stack output publicIp
```

This is a **false FAIL**. The check asserts literal equality between the Kourier
LoadBalancer Service's `EXTERNAL-IP` and the Pulumi `publicIp` stack output. On a k3s cluster
using the built-in ServiceLB ("klipper") load balancer, a `LoadBalancer` Service is assigned
the **node's own IP** as its `EXTERNAL-IP` — here the node's *internal* address such as
`10.10.0.4` — while the reserved *public* static IP (such as `34.145.74.203`) fronts that node
through a Google Cloud forwarding rule. The two addresses are different by design, so literal
equality can never hold even though ingress is serving perfectly. (Background: "ServiceLB" is
k3s's bundled load-balancer controller; instead of provisioning a cloud load balancer it
binds the Service's ports on each node and advertises the node IP as the external IP. The real
public IP lives one layer up, in GCP, and routes packets to that node.)

After this change, three things are true that were not before:

1. **The Kourier-ingress check passes on the healthy cluster.** It stops demanding
   `EXTERNAL-IP == publicIp` and instead verifies what an operator actually cares about: that
   the node-IP LoadBalancer is genuinely fronted by the reserved public IP (and, as a final
   tie-breaker, that the gateway answers). Running `nagarectl doctor` on the live
   `nagare-01` cluster reports `[OK] Kourier ingress`, and the summary line shows `0 failed`.

2. **`doctor` reports whether the cluster can pull the project's private images.** A new
   check inspects the Knative `config-deployment` ConfigMap for the registry host under
   `registriesSkippingTagResolving` — the cluster capability that EP-2 (the plan at
   `docs/plans/66-declarative-private-image-pull-and-cluster-capacity-hardening.md`) makes
   declarative. If a build-mode deploy would fail because the cluster is not configured to
   resolve and pull from the project Artifact Registry, the operator sees it as a WARN with a
   pointer to EP-2's mechanism, instead of discovering it only when a Knative Revision sticks
   in `ImagePullBackOff`.

3. **`doctor` warns when the build platform and the node architecture disagree.** A new
   check compares the target platform configured in the target profile (the
   `NAGARE_TARGET_PLATFORM` field that EP-3, the plan at
   `docs/plans/67-cross-architecture-build-in-the-target-profile-and-nagarectl.md`, adds to
   `Nagare.Target`) against the k3s node's reported architecture (`amd64`). When a developer
   on an `arm64` workstation would otherwise build an image the `amd64` node cannot run, the
   operator sees a WARN with a hint to set the platform, instead of an `exec format error`
   crash loop after deploy.

The acceptance you can observe at the end: on the healthy 2026-06-10-style cluster,
`nagarectl doctor` prints `[OK] Kourier ingress`, prints the two new checks with correct
OK/WARN/FAIL grades, and the unit test suite (`cd cli/nagarectl && cabal test nagarectl-test`)
is green, including new tests that pin the corrected Kourier predicate and the two new probe
parsers.

## Scope, Non-Scope, and the Single-Writer Contract

This plan is **EP-4** of MasterPlan 13. Per that master plan's Integration Point #3, EP-4 is
the **single writer** of the `doctor` check set: only this plan edits
`cli/nagarectl/src/Nagare/Ops/Doctor.hs` and `cli/nagarectl/src/Nagare/Ops/Probe.hs` (and the
probe-gathering glue in `cli/nagarectl/src/Nagare/Ops/Status.hs`). EP-2 and EP-3 do **not**
touch those files; they provide the underlying *capability* (EP-2: the cluster's declarative
private-image-pull configuration) and the underlying *field* (EP-3: the `NAGARE_TARGET_PLATFORM`
target-profile field), and EP-4 implements the probes that read them. This keeps one owner on
the check table so two plans cannot make conflicting edits to it.

The dependency on EP-2 and EP-3 is **soft**, not hard, and this matters for ordering:

- **The Kourier fix (Milestone M1) is fully independent.** It depends on nothing from EP-2 or
  EP-3 and can land first. It is the highest-value change because it removes a standing false
  FAIL.

- **The private-image-pull check (Milestone M2)** describes a capability EP-2 establishes. At
  the time of writing, EP-2's plan (`docs/plans/66-...`) is still a skeleton, so its exact
  ConfigMap key layout is not yet finalized in that file. EP-4 therefore authors M2 against the
  **stated contract** in the master plan: the Knative `config-deployment` ConfigMap gains a
  `registriesSkippingTagResolving` entry listing the project Artifact Registry host. The
  implementer of M2 must re-read `docs/plans/66-...` when EP-2 has fleshed it out and reconcile
  the exact key/value shape and any naming, recording any divergence in this plan's Decision
  Log. If EP-2 has not landed when M2 is implemented, the check still compiles and runs: it
  simply reports WARN ("not configured") on a cluster that lacks the capability, which is the
  correct grade.

- **The architecture-mismatch check (Milestone M3)** reads the `NAGARE_TARGET_PLATFORM` field
  EP-3 adds to `Nagare.Target.TargetProfile`. At the time of writing, EP-3's plan
  (`docs/plans/67-...`) is also a skeleton and `Nagare.Target` does **not** yet have that
  field. The implementer of M3 must re-read `docs/plans/67-...` to confirm the final field name
  (the master plan's Integration Point #2 proposes the environment variable `NAGARE_TARGET_PLATFORM`
  and a profile accessor; the likely Haskell accessor is `tpTargetPlatform :: TargetProfile -> Text`
  defaulting to `"linux/amd64"`). M3 must not add that field itself — that is EP-3's job. If
  EP-3 has not landed, M3 is blocked only on the one-line accessor; the plan below specifies a
  fallback so M3 can be authored and even partially landed (the pure parser and grader) ahead of
  EP-3, with the wiring completed once the field exists. Record the confirmed field name in the
  Decision Log.

**Out of scope.** This plan does not change the ServiceLB/forwarding-rule infrastructure, does
not add new Pulumi outputs unless M1 needs the node's external IP (see M1 design below), and
does not alter the exit-code contract (`doctor` still exits 1 on any FAIL, 0 otherwise — WARN
and UNKNOWN never affect the exit code).

## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

Status: **Complete** — M1–M3 done; 285 tests pass; live `doctor` shows all three checks OK, `0 failed`, exit 0.

- [x] M1: Reachability-first Kourier predicate (curl the public IP; node-ExternalIP fronting fallback; WARN — never FAIL — when inconclusive).
- [x] M1: Added pure helpers `parseNodeExternalIp`, `KourierEvidence(..)`, `gradeKourier` in `Nagare.Ops.Probe`, exported.
- [x] M1: Rewrote `probeKourierIp` in `Nagare.Ops.Status` (gathers svc/node JSON + curl) and added `curlHttpCode`.
- [x] M1: Updated the `"Kourier ingress"` `why`/`command` in `Nagare.Ops.Doctor`.
- [x] M1: 7 new Kourier ops tests incl. the WARN-not-FAIL regression guard; live `doctor` → `[OK] Kourier ingress serving on 34.145.74.203 (HTTP 404; LB EXTERNAL-IP 10.10.0.4)`.
- [x] M2: Re-read EP-2 (now landed); confirmed key `registriesSkippingTagResolving` carries `kind.local,ko.local,dev.local,us-west1-docker.pkg.dev` (Decision Log).
- [x] M2: Added `parseSkipTagResolvingHosts` in `Probe.hs`; `probePrivateImagePull tp` in `Status.hs`, wired into `gatherInventory` after `probeRegistryAuth`.
- [x] M2: Catalogued `"private image pull"` remediation; tests; live `[OK] private image pull`.
- [x] M3: Re-read EP-3 (now landed); confirmed accessor `tpTargetPlatform :: TargetProfile -> Text` (default `linux/amd64`).
- [x] M3: Added `parseNodeArch` + `gradeArch` in `Probe.hs`; `probeArch tp` in `Status.hs`, wired into `gatherInventory`.
- [x] M3: Catalogued `"build platform"` remediation; tests; live `[OK] build platform linux/amd64 matches node amd64`.
- [x] Final: live `nagarectl doctor` — 21 checks, `0 failed`, exit 0; full suite green (285 tests).

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- (2026-06-10, recorded from the live audit) The Kourier false-FAIL is caused by k3s
  ServiceLB assigning the **node IP** (e.g. `10.10.0.4`) as the Service `EXTERNAL-IP`, while
  the reserved public IP (e.g. `34.145.74.203`) fronts the node via a GCP forwarding rule.
  Evidence: apps return HTTP 200 through the gateway (ingress serves) yet
  `kubectl get svc -n kourier-system kourier -o wide` shows `EXTERNAL-IP 10.10.0.4`, which never
  equals `pulumi -C infra/pulumi stack output publicIp` (`34.145.74.203`). The existing check at
  `Nagare.Ops.Status.probeKourierIp` requires literal `EXTERNAL-IP == publicIp`, so it FAILs.

- (M1, 2026-06-11) **The reachability-first predicate produces the ideal `[OK]` on the live
  cluster**, not just the WARN fallback: `curl http://34.145.74.203/` returns `404` (Kourier's
  unknown-Host response — the GCP firewall `nagare-network-fw-web` allows `tcp:80,443` from
  `0.0.0.0/0`), so `gradeKourier` reports `[OK] serving on 34.145.74.203 (HTTP 404; LB EXTERNAL-IP
  10.10.0.4)`. The node-ExternalIP fallback would *not* have sufficed — the k3s ServiceLB node
  advertises only an InternalIP in `.status.addresses` (no ExternalIP), so without the curl signal
  the grade is the inconclusive WARN. Reachability was the right primary signal.

- (M1, 2026-06-11) **`doctor` must run from the repo root**, because `gatherInventory` reads
  `publicIp` via `pulumi -C infra/pulumi …` (a path relative to cwd). Running it from
  `cli/nagarectl` makes `publicIp` resolve to `Nothing` → no curl probe → Kourier degrades to the
  WARN fallback. Use `cabal --project-dir=cli/nagarectl run -v0 exe:nagarectl -- doctor` from the
  root (note `exe:nagarectl` — the package has two executables). Recorded for EP-5's smoke harness.

- (M1, 2026-06-11) **EP-1 left a stale reference in `Doctor.hs`.** The backup-freshness remediation
  pointed at `scripts/backup-postgres.sh`, which EP-1 deleted (EP-1's grep scope was
  `scripts/`+`docs/`, not Haskell). Since EP-4 is the single writer of `Doctor.hs`, it was updated
  to `nagarectl db backup <name>` (the managed-DB path), and the corresponding test was updated.

## Decision Log

Record every decision made while working on the plan.

- Decision (2026-06-11): The corrected Kourier predicate is **reachability-first with a
  fronting cross-check fallback**, not literal IP equality. See the Plan of Work for the full
  predicate and the rationale for choosing it over a pure equality/forwarding-rule comparison.
  Rationale: it directly verifies the property an operator cares about (the gateway answers on
  the reserved public IP) and degrades gracefully when any single piece of evidence is
  unavailable, instead of FAILing on a healthy cluster.
  Date: 2026-06-11

- Decision (2026-06-11): EP-4 is authored against the **stated contracts** of EP-2 and EP-3
  because their plan files are still skeletons. M2 reads the Knative `config-deployment`
  `registriesSkippingTagResolving` entry per the master plan's Integration Point #4; M3 reads the
  `NAGARE_TARGET_PLATFORM` profile field per Integration Point #2. The M2/M3 implementer must
  re-read `docs/plans/66-...`/`docs/plans/67-...` and reconcile exact key/field names, recording
  any divergence here.
  Rationale: soft dependency — EP-4 must not be hard-blocked, and the checks have a meaningful
  "not yet configured" grade even before EP-2/EP-3 land.
  Date: 2026-06-11

- Decision (2026-06-11): **Contracts confirmed — EP-2 and EP-3 had both landed by the time EP-4 was
  implemented, so the stated contracts were reconciled against the real code.** (a) M2 reads the
  Knative `config-deployment` `.data.registriesSkippingTagResolving` (a comma-separated string);
  the live value is `kind.local,ko.local,dev.local,us-west1-docker.pkg.dev`, so the parser splits on
  `,` and the probe checks membership of `tpRegistryHost`. (b) M3 reads `tpTargetPlatform ::
  TargetProfile -> Text` (default `linux/amd64`) — the real accessor EP-3 added — directly, with no
  environment-variable fallback needed (the interim fallback the plan allowed was unnecessary).
  No divergence from the stated contracts.
  Date: 2026-06-11

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

`doctor` now tells the truth — verified live on `nagare-01`:

1. **The Kourier false-FAIL is gone.** The reachability-first `gradeKourier` reports `[OK] Kourier
   ingress  serving on 34.145.74.203 (HTTP 404; LB EXTERNAL-IP 10.10.0.4)` — exactly the master
   plan's expected output. The pure grader is total over `KourierEvidence`, so every branch
   (reachable→OK, fronted→OK, mismatch→FAIL, inconclusive→WARN, no-EXTERNAL-IP→FAIL) is unit-pinned,
   including the WARN-not-FAIL regression guard.
2. **`[OK] private image pull  us-west1-docker.pkg.dev in registriesSkippingTagResolving`** — reads
   the capability EP-2 made declarative; WARN (never FAIL) when absent.
3. **`[OK] build platform  linux/amd64 matches node amd64`** — compares EP-3's `tpTargetPlatform`
   against the node arch; WARN (never FAIL) on mismatch.

The live summary is `21 checks, 0 failed, exit 0`. 285 unit tests pass (17 new). As single writer of
the check set, EP-4 also fixed a stale `Doctor.hs` reference EP-1's script deletion left behind.

Gaps: none against scope. The exit-code contract is unchanged — both new checks are advisory
(WARN/UNKNOWN never affect the exit code). Lesson: making the graders pure and total over a small
evidence record (`KourierEvidence`) is what let the trickiest, most failure-prone check be fully
unit-tested without a cluster — and the live run then only had to confirm the happy path.

