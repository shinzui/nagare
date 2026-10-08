# Production readiness checklist

This is the single list that says how far Nagare is from the operator's goal. Every plan and session
works toward these boxes. A box is ticked only with linked evidence: a commit, a gate record, or a
drill log. Nothing is ticked on an estimate.

## The goal, in the operator's words (2026-10-07)

> The goal of MP23 is to have Nagare used for production workloads and the ledger reliable for
> day-to-day operation and allow us to continue working on it safely. It doesn't mean we need to have
> 1 million combinations and it has to be fault-free and bug-free. It still means that I can use it
> safely and not worry about losing data, not worry about upgrading a node, or not worry about
> upgrading a database.

## Rules that keep this list finite

- **Fixed scope.** No new MasterPlan or rewrite adds boxes here. A new finding goes to the deferral
  ledger, with the operator's approval, unless it risks losing data; only then is it fixed in place.
- **Drills decide.** Each goal ends in an end-to-end drill the operator can watch pass. It is
  rehearsed locally (k3d) first, then run on the cloud VM.
- **Release gates for every change.** `just land` with a green `just gate` record, a zero-survivor
  `just mutation-sweep`, and the fast tier on the validated world. The deep tier is monitoring; each
  of its classes is triaged into a fix or the ledger (ADR 25, 2026-10-07 amendment).

## 1. The ledger is reliable day to day (MP-23)

- [x] Close stopped transactions by per-operation proof, with attested close as the last resort
      (ADR 26; EP-175).
- [x] Record physical identity at creation (ADR 27; EP-176).
- [x] Kubernetes proof rules derived from validated API semantics (RES-4; EP-180, `c3755ad7`,
      `aaa96eaf`).
- [x] A recovery model on a world derived from validated semantics (EP-182, `356e7f18`).
- [x] Stuck StatefulSet rollouts have a reviewed exit (EP-181, `341b01bc`).
- [x] The step-3d fix batch lands: F79 (close never drops an unconfirmed absence) and the harness
      fixes B1, B2 and B6–B8 (`8824f469`, through `just land`: green `just gate` record, mutation
      sweep 117 of 117 killed).
- [x] Step 5: an independent verification by a session that implemented none of the work
      (nagare-verify; [record](../audits/mp23-independent-results-2026-10-07/README.md); F52, F80, F81 and F83 found and fixed on the way).
- [x] Step 5: a new candidate with a green `just gate` and `just gate-verify` (`3ae20f8c`; gate
      record green on both systems; mutation sweep 132 of 132 killed).
- [x] Step 5: a local rehearsal (C2) on the candidate (`3ae20f8c`: 16/16 assertions, inventory
      evidence assembled; [evidence](../audits/mp23-independent-results-2026-10-07/c2-acceptance-3ae20f8c/)).
- [ ] Step 5: the cloud checks C3–C5 on the candidate, including the `mp23-c3i` teardown. Each
      cloud action needs the operator's approval.
  - C3 passed on fresh context `mp23-c3j` (17/17 assertions, inventory evidence assembled; [evidence](../audits/mp23-independent-results-2026-10-07/c3-acceptance-3ae20f8c/)),
    and the operations runbook was executed end to end there ([record](../audits/mp23-independent-results-2026-10-07/runbook-execution-3ae20f8c/)).
  - `mp23-c3i` and `mp23-c3j` are disposed by exact-name deletes from their own stack exports; the staged
    retirement before them is blocked by F84 (next release) ([c3i](../audits/mp23-independent-results-2026-10-07/c3i-teardown/)).
  - Open: C4 passed on aarch64-darwin but fails on x86_64-linux (F85, next release; [C4](../audits/mp23-independent-results-2026-10-07/c4-3ae20f8c/));
    C5 (release assembly, IR-24 mapping, release notes) has not run.
- Known limits, with runbooks:
  - F77: a PVC deleted outside review while it is mounted;
  - F78: members starved behind a broken StatefulSet.

## 2. Never lose data (MP-23's data-protection gate)

- [x] The context uses the `hourly` recovery-point objective (`mp23-c3j`; `server status` shows
      `objective=hourly`; [drill](../audits/mp23-independent-results-2026-10-07/section2-drill-3ae20f8c/)).
- [x] Every signing key is escrowed (all five accepted databases on `mp23-c3j`: en-db, shomei-db,
      rbk-pg, scenario-ch, scenario-pg).
- [x] Every authoritative store is backed up off-cluster within one hour of the latest usable
      recovery point, measured including upload, verification and retry delays (all five databases
      healthy in `server status`, ages 215–1063 s, backups in GCS; volumes are outside the objective by
      decision D2).
- [ ] Freshness deterioration is visible before a breach, and a breach is reported unhealthy.
      (Healthy grading observed natively on `mp23-c3j`; a breach was not observed on this candidate.)
- [x] Backups and recovery credentials are retrievable with the cluster and the operator root gone
      (the drill recovered from a fresh operator root holding only the context, escrow files and sops
      rules).
- [ ] Corrupt and incomplete uploads are refused. (Verification refuses a bad signature or hash by
      design; not exercised natively on this candidate.)
- [x] **Drill:** real data in an application and a database; destroy the cluster; restore from the
      off-cluster backups by the documented procedure; verify the content matches; record the time
      taken. (`mp23-c3j`, 2026-10-08: VM, data disk and snapshots deleted; newest post-seed backup verified
      with escrow and GCS only, restored into PostgreSQL 18, 4/4 rows matched, recovery 20 s;
      [evidence](../audits/mp23-independent-results-2026-10-07/section2-drill-3ae20f8c/). Rebuild in place with live service is the next MasterPlan.)

## 3. Upgrade a node without worry

- [ ] A fresh backup is taken and proven restorable before any node upgrade.
- [ ] **Drill:** with workloads running, upgrade NixOS and k3s on the node through `just host-switch`
      (self-reverting); the ledger, application data and databases survive; status and doctor are
      clean afterwards.
- [ ] **Drill:** a failed node upgrade reverts, or is recovered from the backup, without data loss.
- Route: the shortest safe one (in-place, self-reverting activation, with the data disk separate).
  MP-21's replacement-upgrade machinery (candidate hosts, IP handoff) is a later improvement, if the
  operator approves that scope.

## 4. Upgrade a database without worry

- [ ] A fresh, verified backup is taken before any database engine upgrade.
- [ ] **Drill:** a PostgreSQL major-version upgrade runs side by side (dump and restore into the new
      version); the data is verified; the switch-over is reviewed; the old instance is kept until the
      new one is proven, and retired only after that (EP-126's core).
- [ ] **Drill:** a failed upgrade returns to the old instance with no data loss.

## 5. Keep developing safely

- [x] Master moves only through `just land` with a green full-gate record for the exact commit.
- [x] Heavy runs go to the remote builder (`just test-remote`, `just mutation-sweep`).
- [x] A mutation sweep proves every recorded guard is observed by a test.
- [x] The deep tier runs per release as monitoring; its classes are triaged.
- [x] The builder probe runs first in the full gate (landed in the step-3d batch, `8824f469`; its
      gate record lists `builder-probe-x86_64-linux` as the first step).
