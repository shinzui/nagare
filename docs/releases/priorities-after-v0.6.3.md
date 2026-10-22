# Priorities after v0.6.3

Dated 2026-10-14. The [production readiness checklist](production-readiness-checklist.md) is
complete and the intranet runs v0.6.3. This file ranks the unfinished work by what it moves toward
the operator's requirement: developers deploy and log in, and the operator changes and upgrades
Nagare without losing data. It was assembled from `mina docket status`,
`mina master-plan list --incomplete`, the [findings ledger](../audits/mp23-findings.md) and the plans
named below. Refresh it when a tier changes, not per commit.

[MasterPlan 28](../masterplans/28-serve-nagare-s-recorded-state-through-a-read-only-admin-api.md)
(the read-only admin API for the admin UI and Kotei) is the operator's chosen initiative and is not
ranked here; this is the order for everything beside it.

## Rules carried over

- The checklist's scope is fixed. A new finding goes to the ledger unless it risks data loss.
- A release is cut when a fix matters to a developer, not on a schedule. `just release-candidate`
  takes about 15 minutes, `just release-publish` 2, then the intranet upgrade.
- A held plan is not worked on until its trigger fires. Every held item below names its trigger.

## The order

1. [EP-183](../plans/183-close-the-intranet-gaps-left-by-v0-4-0-https-login-volume-backups-retention-and-service-rebuild.md),
   data safety on the intranet.
2. [EP-101](../plans/101-alerting-and-backup-freshness-monitoring.md) M1–M2, alerting.
3. Developer-facing small work and the releases it earns.
4. A bookkeeping sweep so the docket shows only real work.
5. Everything else stays held behind a named trigger.

## 1. Data safety on the intranet: EP-183 (MasterPlan 24)

The only open work that touches data on the real intranet, and already in progress with pieces
landed (`b4950a69`, `e5078cd5`, `05359622`). Volumes are outside the hourly recovery objective by
decision D2, so a developer's volume on the intranet is the one store not yet covered. Order inside
the plan:

- M3, volume backups (the tar fix is landed; the proof on a running context is open);
- M4, a reviewed operation that recreates a missing durable member from its verified backup;
- M2, retention targets, the GCS prune and the warning row;
- M5, the native runs N1 (local) and N2 (fresh cloud context), one bounded sequence with the
  operator's go-ahead.

Done when: a volume on a local context is backed up, pruned by the recorded retention and rebuilt
from its backup with its content intact, and the same on the cloud run.

## 2. Alerting: EP-101 M1–M2 (MasterPlan 19)

Backup freshness grading exists, but someone has to run `nagarectl server status` to see it. The
open work is operator-sized: a Pushover account and application, one sops-encrypted secret in the
active context, vmalert and Alertmanager enabled in the observability values, a synthetic alert
received as a push, and `server status` showing the alert state. It makes "not worrying about data"
true without looking, which matters once a team depends on the intranet.

## 3. Developer-facing small work

- [EP-194](../plans/194-add-bash-zsh-and-fish-shell-completion-to-nagarectl.md), shell completion:
  pure code, no risk, fits any free session.
- The deferred findings F112, F115 and F117–F120 wait for real use by design. When one of them
  bites a developer, fix it and cut the release then.
- F123 (the packaged Helm) is Verifying and closes on the next intranet upgrade run without the
  devShell's Helm; nothing to schedule.

## 4. Bookkeeping: make the docket truthful

Mina lists eleven plans whose MasterPlans declare them Complete while one to three "deferred live
validation" boxes from June 2026 keep them active:
[EP-3](../plans/3-nixos-host-nagare-01-with-k3s.md),
[EP-12](../plans/12-nagarectl-integration-and-full-yaml-cutover.md),
[EP-15](../plans/15-static-release-rollback-and-preview-deployments.md),
[EP-17](../plans/17-static-hosting-docs-and-end-to-end-examples.md),
[EP-36](../plans/36-app-volume-backup-ownership-snapshot-to-gcs-and-retention.md),
[EP-45](../plans/45-nagarectl-db-lifecycle-commands-and-deploy-time-provisioning.md),
[EP-47](../plans/47-scheduled-database-backups-restore-commands-and-retention.md),
[EP-54](../plans/54-cdn-substrate-spike-and-origin-tls-feasibility.md),
[EP-56](../plans/56-gcp-cloud-cdn-load-balancer-provisioning-in-pulumi.md),
[EP-58](../plans/58-deploy-time-cdn-wiring-and-nagarectl-cdn-command-group.md) and
[EP-97](../plans/97-fail-closed-target-guardrail-and-shell-tooling-hardening.md).
[EP-195](../plans/195-keep-site-and-site-preview-scope-identities-disjoint.md) is done but has no
Outcomes line. Each box is either long since proven by the MasterPlan 23 drills (then tick it with
the evidence) or no longer owed (then void it: `- [-]` with a `{disposition=...}`). One docs-only
session; plan edits carry their gate record forward. Afterwards `mina docket next` recommends only
real work.

## 5. Held, with triggers

- **[MasterPlan 21](../masterplans/21-rehearsed-replacement-upgrades-with-bounded-downtime-for-nagare.md),
  replacement upgrades.** `mina docket next` ranks its spike
  [EP-122](../plans/122-prove-isolated-replacement-rehearsal-and-static-ip-handoff.md) first because
  it unlocks four plans, but the node-upgrade drills pass on the in-place route with reboots of a few
  minutes. Trigger: the team cannot tolerate that downtime after some weeks of use.
- **[MasterPlan 25](../masterplans/25-reviewed-full-context-teardown-with-vm-workload-collection.md),
  teardown.** Trigger: a cloud context actually needs disposing (checked 2026-10-21: `tan-ng-labs`
  holds only the intranet). Deletion is where data risk lives, so when it reopens,
  [EP-173](../plans/173-find-recovery-defects-with-adversarial-provider-interpreters.md) M3–M4 go
  first and the plan is re-chartered as one reviewed destroy-to-zero transaction (its Decision Log,
  2026-10-21), run outside the intranet's project. F33 (P1, Verifying: cloud collection rechecks its
  reviewed incarnation before deletion) sits in that path.
- **EP-173 M3–M4, the host-transport world.** Trigger: an intranet upgrade finds a host-stage
  defect. F121–F124 all sat in providers without a world.
- **Improvement requests.** IR-6 (the local cluster on Apple Container instead of k3d on Colima)
  earns a look if the Colima rehearsal environment gives trouble again. IR-1 (diagnostics
  profiles), IR-25 (WAF) and IR-26 (RustFS) do not move the requirement.

## Findings that close on their own

F113, F114, F116, F84 and F88 are Verifying: fixed, awaiting the situation that recurs naturally on
the intranet. Record the closure when it does; schedule nothing. F77 (P1) and F78 (P2) are known
limits with runbooks, both operator-error scenarios outside review.
