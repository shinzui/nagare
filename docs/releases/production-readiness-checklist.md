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
- [x] Step 5: a new candidate with a green `just gate` and `just gate-verify` (final candidate
      `83124396`, after the defects found on earlier candidates `3ae20f8c`, `3b78d905` and `3b59bcb7`;
      gate record green on both systems, 36/36 x86_64-linux and 37/37 aarch64-darwin,
      [gate](../audits/mp23-independent-results-2026-10-07/gate-83124396.json); mutation sweep 149 of 149 killed,
      [sweep](../audits/mp23-independent-results-2026-10-07/mutation-sweep-83124396.tsv)).
- [x] Step 5: a local rehearsal (C2) on the candidate (`83124396`: 16/16 assertions, inventory
      evidence assembled; [evidence](../audits/mp23-independent-results-2026-10-07/c2-acceptance-83124396/)).
- [x] Step 5: the cloud checks C3–C5 on the candidate, and disposal of the cloud contexts used.
  - C3 passed on fresh context `mp23-c3m` (17/17 assertions, inventory evidence assembled;
    [evidence](../audits/mp23-independent-results-2026-10-07/c3-acceptance-83124396/)). Earlier candidates passed C3 on `mp23-c3j`
    (`3ae20f8c`, with the operations runbook executed end to end:
    [record](../audits/mp23-independent-results-2026-10-07/runbook-execution-3ae20f8c/)) and `mp23-c3l` (`3b59bcb7`).
  - C4 passed on aarch64-darwin and x86_64-linux, clone-free, 11/11 checks each, and
    `check-release.sh` is consistent on both ([C4](../audits/mp23-independent-results-2026-10-07/c4-83124396/)).
  - C5: the release assembly is reproducible, the IR-24 mapping holds and the notes are
    byte-identical on both systems ([C5](../audits/mp23-independent-results-2026-10-07/c5-83124396/);
    [release evidence](../release-evidence/831243962c6b80f91da1028cdab8238ae6acdabd/)). A second assembly from the
    same inputs is byte-identical, and `SHA256SUMS` verifies.
  - `mp23-c3i`, `mp23-c3j`, `mp23-c3k`, `mp23-c3l` and `mp23-c3m` are disposed by exact-name deletes from their own
    stack exports. Staged retirement is blocked by F84 (next release)
    ([disposals](../audits/mp23-independent-results-2026-10-07/context-disposals/), [c3i](../audits/mp23-independent-results-2026-10-07/c3i-teardown/)).
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
- [x] Freshness deterioration is visible before a breach, and a breach is reported unhealthy.
      (Grading observed natively on `mp23-c3j`; warning and breach grades pinned by tests in candidate
      `3ae20f8c`'s green gate run, [gate](../audits/mp23-independent-results-2026-10-07/gate-3ae20f8c.json), [tests](../audits/mp23-independent-results-2026-10-07/test-evidence-section2-3ae20f8c.txt).)
- [x] Backups and recovery credentials are retrievable with the cluster and the operator root gone
      (the drill recovered from a fresh operator root holding only the context, escrow files and sops
      rules).
- [x] Corrupt and incomplete uploads are refused. (Pinned by tests in candidate `3ae20f8c`'s green
      gate run: corrupt bytes and missing generations rejected, an incomplete backup refused, malformed
      and newer receipts refused, escrow verification refuses another key or source;
      [tests](../audits/mp23-independent-results-2026-10-07/test-evidence-section2-3ae20f8c.txt).)
- [x] **Drill:** real data in an application and a database; destroy the cluster; restore from the
      off-cluster backups by the documented procedure; verify the content matches; record the time
      taken. (`mp23-c3j`, 2026-10-08: VM, data disk and snapshots deleted; newest post-seed backup verified
      with escrow and GCS only, restored into PostgreSQL 18, 4/4 rows matched, recovery 20 s;
      [evidence](../audits/mp23-independent-results-2026-10-07/section2-drill-3ae20f8c/). Rebuild in place with live service is the next MasterPlan.)

## 3. Upgrade a node without worry

- [x] A fresh backup is taken and proven restorable before any node upgrade. (Before each upgrade on
      `mp23-c3m`, all three databases were backed up and scenario-pg was restored into a scratch database
      equal to its source: backups `s3pre` before A and B, and `s3prec` before C; the same on `mp23-c3l` for `3b59bcb7`;
      [drills](../audits/mp23-independent-results-2026-10-07/section3-83124396/), [earlier](../audits/mp23-independent-results-2026-10-07/section3-3b59bcb7/).)
- [x] **Drill:** with workloads running, upgrade NixOS and k3s on the node through the self-reverting
      activation (`just host-switch`'s safe switch, driven by a reviewed `inventory apply`); the
      ledger, application data and databases survive; status and doctor are clean afterwards.
      (`83124396` on `mp23-c3m`: B, NixOS `eaad0890` → `b1b87598` with a cold reboot, and C, k3s
      1.35 → 1.36 through nixpkgs `e7439b6b` with a reboot; data hash unchanged, no pod left not
      running, `doctor` exit 0 in 126 s and 123 s; B's review converged in 2 minutes and C's in 5,
      each on its first apply, and C committed through the same `tailscaled` and network restart
      that had cut the session on `3b59bcb7`;
      [drills](../audits/mp23-independent-results-2026-10-07/section3-83124396/). On `3b59bcb7`, C failed to commit when the new system cut the
      activation's own session, F95; it reverted cleanly, and the fix is the candidate, proven first
      in a NixOS VM test that cuts the network mid-switch, [VM test](../audits/mp23-independent-results-2026-10-07/f95-vm-test-83124396/).)
- [x] **Drill:** a failed node upgrade reverts, or is recovered from the backup, without data loss.
      (A, induced on `83124396`: transport stopped mid-activation, `close` refused while the timer
      was armed, the timer reverted the host, and `close` settled "no effect"; data hash unchanged,
      `doctor` exit 0,
      [drills](../audits/mp23-independent-results-2026-10-07/section3-83124396/). A real one on `3b59bcb7`: k3s 1.36 ran for 8 minutes, then
      the timer reverted the host to 1.35 on the same datastore with every row matching,
      [earlier](../audits/mp23-independent-results-2026-10-07/section3-3b59bcb7/).)
- Route: the shortest safe one (in-place, self-reverting activation, with the data disk separate).
  MP-21's replacement-upgrade machinery (candidate hosts, IP handoff) is a later improvement, if the
  operator approves that scope.

## 4. Upgrade a database without worry

Section 4 ran on candidate `3b59bcb7` (`mp23-c3l`, 2026-10-09) and counts for `83124396`: the final
candidate changes no Haskell, only the host-switch scripts, their tests and docs, and the drill runs
no host activation ([diff stat](../audits/mp23-independent-results-2026-10-07/diffstat-3b59bcb7-83124396.txt)).

- [x] A fresh, verified backup is taken before any database engine upgrade. (Reviewed backup
      `s4pre` of PostgreSQL 17, restored in isolation: 6:6 rows equal to the source;
      [drill](../audits/mp23-independent-results-2026-10-07/section4-3b59bcb7/).)
- [x] **Drill:** a PostgreSQL major-version upgrade runs side by side (dump and restore into the new
      version); the data is verified; the switch-over is reviewed; the old instance is kept until the
      new one is proven, and retired only after that (EP-126's core). (PostgreSQL 17.11 → 18.6 beside
      the old instance, fenced copy with matching fingerprints, reviewed switch-over, `s4post` backup
      restored 11:11, then retain-only retirement of the old instance, 12:12 rows; an in-place major
      change is refused at planning, F86; [drill](../audits/mp23-independent-results-2026-10-07/section4-3b59bcb7/).)
- [x] **Drill:** a failed upgrade returns to the old instance with no data loss. (Fail 1, the copy
      fails: the old instance is unfenced and takes writes again. Fail 2, the new instance is rejected
      after switch-over: a reviewed switch back returns to the old instance, and the new one never
      accepted a write. Every acknowledged row is present; [drill](../audits/mp23-independent-results-2026-10-07/section4-3b59bcb7/).)

## 5. Keep developing safely

- [x] Master moves only through `just land` with a green full-gate record for the exact commit.
- [x] Heavy runs go to the remote builder (`just test-remote`, `just mutation-sweep`).
- [x] A mutation sweep proves every recorded guard is observed by a test.
- [x] The deep tier runs per release as monitoring; its classes are triaged.
- [x] The builder probe runs first in the full gate (landed in the step-3d batch, `8824f469`; its
      gate record lists `builder-probe-x86_64-linux` as the first step).
