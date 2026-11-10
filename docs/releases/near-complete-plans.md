# Near-complete plans

Dated 2026-11-10. This is the working list for closing the MasterPlans that are nearly done, in the
order to take them. It was built by checking every open box against the repository's plans, audits
and release evidence. No live cluster was queried. `mina master-plan remaining --all` shows what is
still open.

A plan leaves `mina master-plan list --incomplete` when every box is ticked or marked `[-]` and its
Outcomes section is filled. Steps marked **cloud** need the operator's go-ahead and
[Before a native run](../runbooks/before-a-native-run.md) first.

## 1. MasterPlan 24: volume data safety (EP-183, 4 open boxes)

[EP-183](../plans/183-close-the-intranet-gaps-left-by-v0-4-0-https-login-volume-backups-retention-and-service-rebuild.md)
is the only open work that touches data on the intranet, so it goes first. The code for M2–M4 landed
at `d42913c9`.

Already proven in the
[v0.5.0 evidence](../release-evidence/41df1ba4825fdf912eaed66279d0e3f3c590339b/):
a manual volume snapshot and restore, local and cloud, and a scheduled volume producer graded healthy
in `server status` on the local run. The cloud run covered a deploy and a passkey sign-in. The
[VM-loss drill](../audits/ep245-vm-loss-drill-2026-11-04.txt) rebuilt the platform databases in 85
minutes against the four-hour target, with no volume in it.

- [ ] M2: review the 30-day noncurrent GCS window (operator decision).
- [ ] M2: on a local context, see the retention WARN row and apply a prune. The operator moved this
      to after the v0.5.0 release, and it has not been run.
- [ ] M3: on a local context, ingest a scheduled volume run and restore it into a new PVC, byte
      identical. Also see the status row degrade when the newest upload is deleted.
- [ ] M4: delete a local cluster and rebuild a volume from its recovery point, timed.
- [ ] M5, **cloud**: run a VM-loss rebuild with a volume in it, within the four-hour target.
- [ ] Decide the two items deferred on 2026-10-10: volumes of standalone services and workers, and
      offline verification of volume runs that were never ingested. Either do them or mark them `[-]`.
- [ ] Fill EP-183's Outcomes paragraph.

MasterPlan 24's team streams 1–3 are unplanned and are not boxes in this list.

## 2. MasterPlan 30: one intranet timing sample (EP-224 M3, 1 open box)

[EP-224](../plans/224-make-a-platform-transition-take-minutes-and-keep-its-cost-traced.md) needs one
traced sample from the next intranet upgrade (operator, 2026-11-10; was five). Five warm local
samples already passed.

- [ ] **Cloud**, during the next intranet upgrade: collect the trace with
      `nagare-harness transition-cost collect`, then run `transition-cost check`, and keep the record
      as `docs/release-evidence/<rev>/intranet-cost.json`. The budgets are 60 s per plan excluding
      artifact preparation, and 300 s activation.
- [ ] If activation still misses, start with the host preflight over IAP, which took 86.1 s in
      v0.12.1 against 10.1 s in v0.12.0.
- [ ] Replace the stale Outcomes text in EP-224 and in
      [MasterPlan 30](../masterplans/30-make-nagare-rollouts-fast-incremental-and-recoverable.md).

## 3. MasterPlan 19: alert delivery (EP-101 M1, 5 open boxes)

Nothing notifies anyone today: Alertmanager is off and vmalert uses a blackhole notifier. The first
step is the operator's. See Concrete Steps M1.1 in
[EP-101](../plans/101-alerting-and-backup-freshness-monitoring.md).

- [ ] Create a Pushover account and application (operator).
- [ ] Write and sops-encrypt the context's `alertmanager-config.yaml`.
- [ ] Enable Alertmanager in `cluster/observability/victoria-metrics/values.yaml` and remove the
      blackhole notifier.
- [ ] **Cloud**: run `nagare observability` and confirm the vmalert and Alertmanager pods are Running.
- [ ] **Cloud**: inject a synthetic alert and receive the push on the phone.

## 4. MasterPlan 18: Nix cache proof (EP-96 and EP-230 M4, 2 open boxes)

No context has the cache enabled today (the intranet has it off), so this is one bounded run on a
disposable cloud context. Kotei's cache flavor is
`mori://shinzui/kotei/plans/68-publish-signed-closures-to-a-platform-owned-attic-cache`, so confirm
whether Kotei still needs this before spending the run.

- [ ] **Cloud** (EP-230 M4): on a context with the cache enabled, push the smoke path and see the
      positive smoke Pod substitute it.
- [ ] **Cloud** (EP-96): run the destructive trust rotation in
      [the cache guide](../user/nix-binary-cache.md) and the unrelated-HTTP NetworkPolicy probe.
- [ ] Tick MasterPlan 18's EP-3 proof line and change its EP-3 and EP-4 registry rows, which still
      say Not Started.

## Not on this list

- MasterPlan 32 is 60% done. Next is EP-245 D1–D3, then EP-244 D6, EP-243's move and EP-246.
- MasterPlans 31 and 33 have not started.
- MasterPlans 21 and 25 are held by operator decision.
- MasterPlan 34 is in active work.

Closed by this audit on 2026-11-10: MasterPlans 3, 9, 11, 22, 28 and 29.
