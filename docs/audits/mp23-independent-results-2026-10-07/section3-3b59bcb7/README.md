# Checklist section 3 on the final candidate `3b59bcb7`

nagare-verify ran this on 2026-10-09 on `mp23-c3l` (project `tan-ng-labs`), the context where C3
passed. Workloads were running throughout: the C3 scenario's PostgreSQL, Redis and ClickHouse
databases with seeded rows, plus the platform. The driver is `s3-drill.sh`, run by `s3-run.sh`, and
the timeline is `timeline.txt`.

Every snapshot (`snap-*/`) records the following:
- host system, rollback timer, k3s version, kernel and boot ID (`host.txt`);
- node state (`nodes.txt`) and pods not running (`pods-not-running.txt`);
- `inventory status` (`status.json`, `status-summary.json`);
- the three databases' rows and their combined hash (`data.sha256`);
- at the checklist's states, `doctor` (`doctor.txt`).

The data hash was `24467b7d…` at every snapshot. No pod was left not running. `doctor` exited 0 at
the baseline, after drill A, after drill B's reboot, and after drill C's revert, taking 110–119 s
each time (F92's fix; on `3b78d905` it took 16 min).

| Step | Result |
|---|---|
| Fresh backup before an upgrade (`s3pre`, `s3prec`) | All three databases backed up; scenario-pg restored into a scratch database equal to its source |
| **A: failed upgrade, induced** (re-pin to nixpkgs `b1b87598`, transport stopped mid-activation) | `close` refused while the timer was armed. The timer reverted the host. `resume` refused without switching or writing (its message lacks the reason, F94). `close` settled "no effect" (the first attempt hit a transient store read and wrote nothing, F89). The lock was restored. |
| **B: NixOS upgrade** (nixpkgs `eaad0890` → `b1b87598`, kernel 6.18.51 → 6.18.52) | The two-operation review converged in one apply (F93's fix; the operator's own `PATH`, F90's fix). Then a cold reboot through a reviewed `host stop` and `host start`. |
| **C: k3s minor upgrade** (nixpkgs `e7439b6b`, k3s 1.35.8 → 1.36.4) | **Did not commit (F95).** The new system restarted `tailscaled` and the network. That ended the activation's own session while the network was down, and the client hung. k3s 1.36.4 ran for 8 minutes, then the timer reverted the host to drill B's system with k3s 1.35.8. The documented exit (resume refuses, `close` settles "no effect", lock restored) left data, pods and `doctor` clean. |

Drill C is a real failed upgrade. It reverted with no data loss, including a k3s minor downgrade on
the same datastore after the new minor had run. The k3s upgrade itself still has to pass once F95
is fixed.

`apply-c-hung-tree.txt` records the hung process tree. The ssh was ended by its exact PID after
22 minutes, which is what a keepalive would have done; the apply then stopped `ambiguous`.
`fail-a-journal/` holds drill A's store events, showing that resume appended nothing.
