---
id: 39
slug: nagarectl-doctor-health-checks-with-remediation-hints
title: "nagarectl doctor health checks with remediation hints"
kind: exec-plan
created_at: 2026-06-10T04:34:52Z
intention: "intention_01ktqwqc61e519h77zqdf3ngs3"
master_plan: "docs/masterplans/8-server-inventory-and-operations-ux-for-nagare.md"
---

# nagarectl doctor health checks with remediation hints

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

Full plan before trimming: [39-nagarectl-doctor-health-checks-with-remediation-hints.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/39-nagarectl-doctor-health-checks-with-remediation-hints.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

`nagarectl server status` (built by the sibling plan
`docs/plans/38-server-inventory-probe-layer-and-nagarectl-server-status.md`) tells an operator
*what* the platform's state is — a one-screen aligned table of `OK`/`WARN`/`UNKNOWN`/`FAIL` lines.
What it does not tell a newcomer is *what a red line means* or *what to type to fix it*. When the VM
line reads `FAIL TERMINATED`, the operator still has to know that the fix is
`gcloud compute instances start nagare-01 --zone=us-west1-a`; when a control-plane line reads `FAIL`,
they still have to know which `kubectl rollout status` to run and which `cluster/bootstrap/<component>/README.md`
to read. That knowledge lives in operators' heads and in scattered runbooks. This plan moves it into
the tool with a single command:

```text
nagarectl doctor
```

After this plan, `nagarectl doctor` re-runs EP-38's probes and renders them as an *ordered checklist*
of `OK` / `WARN` / `FAIL` lines where **every non-OK line carries a plain-language explanation of what
is wrong and the exact command to run to fix it.** A probe whose data source is unreachable
(`StatusUnknown` from EP-38) renders as a `WARN` line with a "could not check; <reason>" hint rather
than a hard `FAIL`. Crucially, `doctor` exits with a **non-zero process exit code when any check
FAILs**, so it is scriptable: an operator can put `nagarectl doctor` in a pre-deploy guard or a cron
health alert and branch on its exit status.

`doctor` is read-only and advisory: it *prints* remediation commands but **never executes them**. The
operator stays in control of every mutation. It is the diagnostic counterpart to `server status`'s
inventory — same probes, re-graded into an actionable triage list.

You can see it working without deploying anything. Power the VM off and run the command:

```text
$ gcloud compute instances stop nagare-01 --zone=us-west1-a
$ nagarectl doctor
nagare doctor — 9 checks

  [FAIL]  vm-power            The VM nagare-01 is powered off.
          fix: gcloud compute instances start nagare-01 --zone=us-west1-a
  [WARN]  k3s-node            could not check; the VM is TERMINATED, so the k3s API is unreachable.
          fix: gcloud compute instances start nagare-01 --zone=us-west1-a, then re-run
  ...
1 failed, 3 warnings, 5 ok.
$ echo $?
1
```

The VM-power line names the problem in one sentence and gives the exact `gcloud` start command; the
checks that depend on the VM degrade to `WARN` ("could not check; …") rather than crashing; and the
process exits `1` because at least one check FAILed. Start the VM, wait for k3s, re-run, and the report
walks back to "0 failed" with exit `0`.

## Progress

- [x] M1 (2026-06-10): pure `Remediation`/`Check` model + `remediationFor` knowledge base + `formatDoctor` renderer +
  `doctorExitOk`, all in `cli/nagarectl/src/Nagare/Ops/Doctor.hs`, with a `testGroup "Nagare.Ops.Doctor"` (15 cases) in
  `cli/nagarectl/test/Spec.hs` covering each failure mode — all green.
- [x] M2 (2026-06-10): `doctor` top-level command wired into `cli/nagarectl/app/Main.hs` — `DoctorOpts` record +
  parser (`--skip-vm`), `Doctor` constructor, `command "doctor"` registered, `runDoctor` handler calling EP-38's
  `gatherInventory` and exiting non-zero on any FAIL.
- [x] M3 (2026-06-10): `nagarectl-test` green (146 tests) + `nagarectl doctor --help` transcript captured below;
  FAIL/exit-1 path proven with a `gcloud` stub (VM `TERMINATED` → `[FAIL]`, exit 1) and degradation proven with an
  empty PATH (all `WARN`, exit 0); live cluster run deferred (no cluster mutated during implementation).

## Surprises & Discoveries

- 2026-06-10 (M1): EP-38 shipped **display-name** probe keys (`"VM"`, `"k3s node"`,
  `"Knative controller"`, `"cert-manager-cainjector"`, `"Kourier ingress"`, `"base domain"`,
  `"external-domain-tls"`, `"Artifact Registry"`, `"backup postgres"`, `"boot disk"`/`"data disk"`/`"disk"`,
  etc.) and **no** separate stable machine-key field — the conceptual keys this plan sketched
  (`vm-power`, `k3s-node`, …) do not exist in EP-38's source. Per IP1's instruction to read the
  committed names, `remediationFor` keys off EP-38's real `probeName` values. The `doctor`
  checklist therefore shows the same labels as `server status` (consistency win), and the
  uncatalogued-probe fallback ("see docs/runbooks/") guarantees no bare red line if EP-38 later
  adds a probe. See the Decision Log entry for the rationale and the safety of this choice.
- 2026-06-10 (M1): EP-38's inventory has 18 probes (the four control planes expand to seven
  Deployments incl. `cert-manager-cainjector`, plus an informational `external-domain-tls` line and
  three backup prefixes), so the live header reads "18 checks", not the plan's illustrative "9".
  `remediationFor` groups the seven Deployment probes via an `isDeploy`/`deployTarget` table so each
  prints its own `kubectl rollout status deploy/<name> -n <ns>` and the right
  `cluster/bootstrap/<component>/README.md`.
- 2026-06-10 (M3): Both control paths were proven without touching real infra — the FAIL/exit-1 path
  with a one-line `gcloud` shell stub that reports the VM `TERMINATED` (→ `[FAIL] VM`, summary
  "1 failed", process exit 1), and the all-`WARN`/exit-0 degradation with `PATH=/var/empty`.

## Decision Log

- Decision: `doctor` prints remediation commands but **never auto-executes** any fix. The output is
  advisory text the operator runs themselves.
  Rationale: The remediation commands mutate infrastructure (start a VM, patch a ConfigMap, push images,
  run a backup). Auto-running them would make a diagnostic command an outward-facing actor, hide which
  mutation happened, and risk acting on a misdiagnosis. Keeping `doctor` read-only matches the
  least-surprise contract of `server status` and keeps `remediationFor`/`formatDoctor` pure and
  trivially testable.
  Date: 2026-06-09

- Decision: The process exit code is non-zero **iff at least one check is `FAIL`**. `WARN`/`UNKNOWN`/`OK`
  do not affect the exit code. Concretely `doctorExitOk checks = not (any isFail checks)`; `runDoctor`
  calls `exitWith (ExitFailure 1)` when `doctorExitOk` is `False`.
  Rationale: A scriptable health gate needs a crisp, stable signal. `FAIL` means "a thing that should be
  up is down" (actionable, blocking); `WARN`/`UNKNOWN` mean "degraded or could-not-check" (worth a human
  glance but not a hard stop). Tying exit `1` strictly to `FAIL` lets `nagarectl doctor && deploy`
  behave sensibly without flapping on transient unknowns.
  Date: 2026-06-09

- Decision: `doctor` **reuses EP-38's probes** (`gatherInventory` returning `[Probe]`) rather than
  re-implementing any health check. EP-39 adds only the pure mapping from a `Probe` to a `Remediation`
  and the checklist renderer.
  Rationale: One source of truth for "is X healthy". `server status` and `doctor` must never disagree
  about whether the VM is up or a deployment is rolled out. EP-38 owns probing; EP-39 owns triage
  presentation. This is Integration Point IP1 with EP-38
  (`docs/plans/38-server-inventory-probe-layer-and-nagarectl-server-status.md`).
  Date: 2026-06-09

- Decision: Key `remediationFor` off EP-38's committed `probeName` **display values** rather than
  adding a separate stable machine-key field to EP-38's `Probe` type.
  Rationale: EP-38 ships display-only probe names and no machine key; adding one would mean editing
  EP-38's type and every probe construction for marginal benefit, since EP-38 and EP-39 are committed
  together and the names are stable. Keying off `probeName` keeps `doctor`'s labels identical to
  `server status`, and the catalogue's `_ -> "see docs/runbooks/"` fallback ensures any future
  uncatalogued probe still gets a hint (the IP1 "renaming silently drops a remediation" risk is
  mitigated by the fallback plus the unit tests, which assert the exact command substrings).
  Date: 2026-06-10

## Outcomes & Retrospective

Delivered `nagarectl doctor`: the pure `Nagare.Ops.Doctor` module (the
`Remediation`/`Check` model, the `remediationFor` knowledge base, the
`formatDoctor` renderer, and the `doctorExitOk` grade) plus the top-level
`doctor` command in `cli/nagarectl/app/Main.hs` (a `Doctor DoctorOpts`
constructor, `doctorOptsParser` with `--skip-vm`, `command "doctor"`, the
`runDoctor` handler, and the `main` dispatch arm). `runDoctor` reuses EP-38's
`gatherInventory` — no probe is re-implemented — re-grades the probes, prints the
checklist, and `exitWith (ExitFailure 1)` iff any check FAILs. All 146 tests pass,
including the new 15-case `testGroup "Nagare.Ops.Doctor"`.

Captured transcripts (2026-06-10):

```text
$ nagarectl doctor --help
Usage: nagarectl doctor [--skip-vm]

  Health-check the platform and print remediation hints (exit 1 on any FAIL)

Available options:
  --skip-vm                Skip the IAP-SSH disk probe (no SSH setup needed)
  -h,--help                Show this help text
```

FAIL / exit-1 path, proven with a `gcloud` stub reporting the VM `TERMINATED`
(no real infra touched):

```text
$ PATH=<stub-with-gcloud-only> nagarectl doctor --skip-vm
nagare doctor — 18 checks

  [FAIL]  VM                       The VM nagare-01 is powered off.
          fix: gcloud compute instances start nagare-01 --zone=us-west1-a
  ...
1 failed, 16 warnings, 1 ok.
$ echo $?
1
```

Degradation / exit-0 path, proven with an empty PATH (every source unreachable →
every probe `UNKNOWN`, rendered `WARN`, exit 0):

```text
$ PATH=/var/empty nagarectl doctor
nagare doctor — 18 checks

  [WARN]  VM                       could not check; gcloud unavailable or no access
          fix: gcloud compute instances start nagare-01 --zone=us-west1-a
  ...
0 failed, 18 warnings, 0 ok.
$ echo $?
0
```

What changed from the plan: the inventory is 18 checks (not the illustrative 9),
and the knowledge base keys off EP-38's real display names. The remediation
commands are all repo-accurate (zone `us-west1-a`, `tan-nb-exp` registry,
`scripts/iap-ssh.sh`, the `cluster/bootstrap/<component>/README.md` paths). The
live cluster two-run is deferred per the plan's M3 convention and the
GCP-isolation rule; the FAIL and degradation behaviors above were proven
deterministically without a cluster.

