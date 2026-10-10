---
title: "Use Case 003 — Operate Nagare as a Workplace Intranet PaaS"
type: Use Case
description: "One operator runs a Nagare installation that serves workplace intranet apps holding personal data to colleagues over HTTPS with Nagare's login, with hourly recovery points, bounded retention and a four-hour rebuild."
generated:
  by: claude-code/claude-opus-5-5
  at: "2026-10-10T03:20:00Z"
useCaseId: UC-3
status: planned
origin: mori://shinzui/nagare
themes:
  - team-operation
jobs:
  - name: operate-the-installation
    actor: Nagare operator (the single administrator, who also deploys applications)
    situation: the workplace intranet runs on one Nagare installation that the operator alone administers
    motivation: change the platform and its applications through reviewed plans without losing work data or another person's approval being needed
    outcome: every change is a reviewed plan recorded in the inventory journal, and the installation can be recovered and rebuilt within the agreed objectives
  - name: use-an-intranet-app
    actor: colleague using an intranet application
    situation: a colleague opens an intranet app from an ordinary browser on the public internet
    motivation: reach the app safely without certificate warnings and without anyone else reading their data
    outcome: the colleague signs in through Nagare's login portal over trusted HTTPS and reaches only the apps they are granted
features:
  - name: single-operator-administration
    description: One operator holds all administrative access; no administrator, deployer, reviewer or auditor role split is required yet.
    status: discovered
    owners:
      - mori://shinzui/nagare
    acceptance: The operator administers and deploys to the installation from their private operator repository and context alone, and no other person's credentials are needed for any reviewed change.
    jobs:
      - operate-the-installation
  - name: self-approved-reviewed-changes
    description: Reviewed plans are approved by the operator who applies them; no change kind requires a second person's approval.
    status: discovered
    owners:
      - mori://shinzui/nagare
    acceptance: A saved review applied with `nagarectl inventory apply DIR --yes` by the operator completes without any second approval, and the plan remains reviewable before apply.
    jobs:
      - operate-the-installation
  - name: journal-is-the-audit-record
    description: The inventory journal is the audit record of platform and application changes, kept for the life of the installation; no separate audit log is required.
    status: discovered
    owners:
      - mori://shinzui/nagare
    acceptance: Every applied change appears in the context's inventory journal with its transaction, operations, states and timestamps, and no journal event is ever removed while the installation exists.
    jobs:
      - operate-the-installation
  - name: protect-personal-data
    description: The intranet holds employee or customer personal data, so application data, backups and recovery material are reachable only by granted users and the operator, and backup copies age out by the retention policy.
    status: discovered
    owners:
      - mori://shinzui/nagare
    acceptance: Backup buckets refuse public access, protected apps refuse anonymous and ungranted users, and no scheduled backup copy of personal data outlives the retention policy after a reviewed prune.
    jobs:
      - operate-the-installation
      - use-an-intranet-app
  - name: public-https-with-nagare-login
    description: Colleagues reach intranet apps over public HTTPS with a publicly trusted certificate, protected by Nagare's own login portal (passwords or passkeys); no company identity provider, VPN or tailnet is required.
    status: planned
    owners:
      - mori://shinzui/nagare
    acceptance: An anonymous request to a protected app gets a redirect to the login portal, a granted user who signs in reaches the app, and the browser shows no certificate warning.
    jobs:
      - use-an-intranet-app
  - name: revoke-an-app-user
    description: The operator can withdraw a colleague's access to an intranet app through a reviewed change.
    status: planned
    owners:
      - mori://shinzui/nagare
    acceptance: After a reviewed `nagarectl access revoke` is applied, the revoked user's existing session gets 403 within the enforcer's decision cache period.
    jobs:
      - operate-the-installation
      - use-an-intranet-app
  - name: hourly-recovery-point
    description: Every authoritative store, databases and backup-included application volumes, has an off-cluster recovery point no older than one hour, graded in `nagarectl server status`.
    status: planned
    owners:
      - mori://shinzui/nagare
    acceptance: With objective `hourly`, `server status` grades each database and each backup-included volume healthy within one hour and reports a breach as unhealthy.
    jobs:
      - operate-the-installation
  - name: bounded-backup-retention
    description: Every scheduled recovery point is kept for 48 hours, the newest point of each day for 30 days, and the newest verified point always; points past policy are reported and removed only by a reviewed prune.
    status: planned
    owners:
      - mori://shinzui/nagare
    acceptance: "`server status` warns when scheduled recovery points are past policy, and applying a reviewed prune removes exactly those points and never the newest verified one."
    jobs:
      - operate-the-installation
  - name: four-hour-service-rebuild
    description: After losing the VM, the operator brings the same installation back into service with its data within four hours of starting the rebuild.
    status: planned
    owners:
      - mori://shinzui/nagare
    acceptance: A timed drill deletes the VM and the documented rebuild restores the applications and their data within four hours from the start of the rebuild to the service answering.
    jobs:
      - operate-the-installation
---

# Use Case 003: operate Nagare as a workplace intranet PaaS

The operator runs Nagare as the platform for an intranet at work, in addition to personal use. The
operator answered the requirement questions of
[EP-162](../plans/162-define-team-operating-requirements-and-decide-availability-for-the-intranet-paas.md)
on 2026-10-09. This use case records those answers. It replaces guesses about what "team-ready"
means.

The answers make the first workplace installation a **single-operator** service with
**work data in it**. Only the operator administers it, and no change needs a second person's
approval. The inventory journal is the audit record. The data, however, belongs to the workplace
and includes personal data, and colleagues reach it from the public internet. The demanding
requirements are therefore about protecting and recovering data and about safe sign-in. Multiple
operators are not required yet.


## Answers recorded

| Question | Answer (2026-10-09) |
|---|---|
| Operators and roles | One operator for now; others only use the intranet apps. |
| Second-person approval | None yet. |
| Audit | The inventory journal is enough, kept for the life of the installation. |
| Data held | Includes personal data (employee or customer). |
| User access | Public HTTPS with Nagare's own login portal. |
| Compliance or security review | None required. |
| Recovery point objective | Hourly, the existing `hourly` preset, for databases and backup-included volumes. |
| Retention | Every point for 48 hours, the newest per day for 30 days, the newest verified point always. |
| Recovery time objective | 4 hours from the start of the rebuild to the service answering. |


## Open questions

- **Operator succession.** With one operator, nobody else can operate the installation if the
  operator is unavailable or leaves. Colleagues hold no deployment material
  ([ADR 13](../adr/0013-operator-deployment-material-lives-in-a-private-repository-with-remote-state.md)).
  The operator did not state a requirement. It is the trigger for MasterPlan 24's team-access stream.
- **Erasure of personal data.** Erasing a person's data from a live application is the
  application's job. Copies in backups disappear when retention removes them, within 30 days. No
  shorter erasure deadline was stated.


## What this excludes

Multi-operator writer exclusion, named-reviewer approval, shared deployment material, a company
identity provider and multi-node availability are not required by these answers. They remain
MasterPlan 24's later streams. Each is planned only when a requirement here changes.
