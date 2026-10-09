# Checklist section 3 on the final candidate `83124396`

nagare-verify ran this on 2026-10-09 on `mp23-c3m` (project `tan-ng-labs`), right after C3 passed
there ([`../c3-acceptance-83124396/`](../c3-acceptance-83124396/README.md)). Workloads were running
throughout: the C3 scenario's PostgreSQL, Redis and ClickHouse databases with seeded rows, plus the
platform. The drills are the ones run on `3b59bcb7`
([`../section3-3b59bcb7/`](../section3-3b59bcb7/README.md)): `s3-drill.sh` drives them, `s3-run.sh`
runs them in order, and the timeline is `timeline.txt` (`logs/run.log` has one line per phase).

Each snapshot (`snap-*/`) records:
- the host system, rollback timer, k3s version, kernel and boot ID (`host.txt`);
- the node state (`nodes.txt`) and the pods not running (`pods-not-running.txt`);
- `inventory status` (`status.json`, `status-summary.json`);
- the three databases' rows and their combined hash (`data.sha256`);
- at the states the checklist names, `doctor` (`doctor.txt`).

| Snapshot | System | Kernel | k3s | Boot | Data | `doctor` |
|---|---|---|---|---|---|---|
| `0` (baseline) | nixpkgs `eaad089` | 6.18.51 | 1.35.8 | `9f8cbbd9` | `24467b7d…` | exit 0, 123 s |
| `fail-a` (after drill A) | `eaad089` | 6.18.51 | 1.35.8 | `9f8cbbd9` | `24467b7d…` | exit 0, 113 s |
| `b` (after B's switch) | `b1b8759` | 6.18.51 | 1.35.8 | `9f8cbbd9` | `24467b7d…` | not run |
| `b-rebooted` | `b1b8759` | 6.18.52 | 1.35.8 | `58aa2f57` | `24467b7d…` | exit 0, 126 s |
| `c` (after C's switch) | `e7439b6` | 6.18.52 | 1.36.4 | `58aa2f57` | `24467b7d…` | not run |
| `c-rebooted` | `e7439b6` | 6.18.55 | 1.36.4 | `ed8f88e8` | `24467b7d…` | exit 0, 123 s |

The rollback timer was inactive at every snapshot. The data hash never changed. No pod was left not
running, with one exception. At `b-rebooted`, six pods were still `Pending`: the scheduled backup and
report jobs of 17:00Z, created while the node was down for the reboot. All five backup jobs then
completed in about a minute, and no job on the cluster failed.

| Step | Result |
|---|---|
| Fresh backup before an upgrade (`s3pre` at 16:29Z, `s3prec` at 17:13Z) | All three databases backed up through reviewed backups. scenario-pg was restored into a scratch database equal to its source (`pg-at-*.txt`, `pg-restored-*.txt`). |
| **A: failed upgrade, induced** (re-pin to nixpkgs `b1b87598`, transport stopped mid-activation) | `close` refused while the timer was armed (`fail-a-close-armed.txt`). The timer reverted the host within the window. `resume` refused and wrote nothing (its message lacks the reason, F94). `close` settled "no effect" (`fail-a-close.txt`), and the lock was restored. |
| **B: NixOS upgrade** (nixpkgs `eaad0890` → `b1b87598`, kernel 6.18.51 → 6.18.52) | The two-operation review converged in one apply in 2 min (16:51:48Z → 16:53:49Z). Then came a cold reboot through a reviewed `host stop` and `host start`. |
| **C: k3s minor upgrade** (nixpkgs `e7439b6b`, k3s 1.35.8 → 1.36.4, kernel 6.18.55 after the reboot) | **Committed on its first apply (F95's fix).** The review converged in 5 min (17:20:14Z → 17:25:24Z). Then came a cold reboot through a reviewed `host stop` and `host start`. |

`apply-c-host-journal.txt` is the host's journal for drill C's activation. It shows F95's situation
recurring and being handled:
- 17:23:48Z: the switch started in its own transient unit, `nagare-switch-activate.service`.
- 17:24:05Z: the new system restarted the network units and `tailscaled`, as it did on `3b59bcb7`.
- 17:24:30Z: k3s 1.36 started, and the unit finished on its own in 42 s.
- 17:24:36Z: the client learned the result over a fresh login and committed, which disarmed the
  rollback timer.

On `3b59bcb7` the same restart cut the activation's own session, and the upgrade could not commit.

`reviews/` holds the digest of every reviewed change set and the plan and apply logs. The full
review bundles stay in the operator root until the context is disposed.
