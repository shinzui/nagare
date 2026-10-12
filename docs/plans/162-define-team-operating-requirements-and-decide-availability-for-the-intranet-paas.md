---
id: 162
slug: define-team-operating-requirements-and-decide-availability-for-the-intranet-paas
title: "Define team operating requirements and decide availability for the intranet PaaS"
kind: exec-plan
created_at: 2026-09-28T14:26:34Z
intention: "intention_01m3m6hh7temkvtd7cgzkb3r15"
master_plan: "docs/masterplans/24-operate-nagare-as-a-team-run-workplace-intranet-paas.md"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-09-28T14:26:34Z
  revisions:
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-10T02:46:57Z
      mode: "update"
      note: "M1 also asks for retention targets and notes EP-183's login scope"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-10T03:24:32Z
      mode: "implement"
      note: "Record operator answers as UC-3, map current behavior, accept ADR 28 (single node, 1h RPO, 4h RTO)"
---

# Define team operating requirements and decide availability for the intranet PaaS

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

Full plan before trimming: [162-define-team-operating-requirements-and-decide-availability-for-the-intranet-paas.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/162-define-team-operating-requirements-and-decide-availability-for-the-intranet-paas.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

Nagare was built as a personal PaaS run by one operator. It will now also serve as a PaaS for an
intranet at the operator's workplace, run by a small team. Nobody has yet written down what that
team needs from the platform, so any design for multi-operator use, change approval, or tooling
would be guessing.

After this plan, the repository holds a validated, reviewable record of the workplace's operating
requirements (who operates the platform, who approves changes, what must be audited, how access
is granted and revoked, how the data is classified, and how quickly the platform must recover
after a failure), plus an accepted Architecture Decision Record stating the availability model.
A reader can open `docs/use-cases/` and the new ADR and know exactly what "team-ready" means for
Nagare. The companion evaluation plan scores tools against this record.

## Progress

- [x] M1 (2026-10-10): The workplace operating requirements are recorded as a use case in `docs/use-cases/`,
  confirmed by the operator, and pass `okf validate`. Each requirement is mapped to Nagare's
  current behavior as supported, partial, or missing, with a file or command as evidence.
  - [x] (2026-10-10) Operator answered the questions (Surprises & Discoveries). UC-3
    (`docs/use-cases/003-operate-nagare-as-a-team-run-intranet-paas.md`) and the `team-operation`
    theme added; `okf validate docs/use-cases --profile docs/use-cases/profile.dhall --log-enforce`
    reports `OK: 5 concepts`. Mapping in "Current behavior mapping" below.
  - [x] (2026-10-10) The operator confirmed UC-3 as written (commit `7812652b`).
- [x] M2 (2026-10-10): [ADR 28](../adr/0028-the-intranet-stays-single-node-with-hourly-recovery-points-and-a-four-hour-rebuild.md)
  is accepted: single node, one-hour recovery point, four-hour rebuild, retention 48 h / 30 days,
  drill-tested restore. `docs/capabilities/managed-databases-and-backups.md` and
  `docs/capabilities/kafka-compatible-brokers.md` cite it; `okf validate docs/capabilities` is OK.

## Surprises & Discoveries

- The operator's answers, 2026-10-09, given as choices in the session that implemented M1:
  - Operators and roles: "Just me for now". One operator; team features are future-proofing.
  - Second-person approval: "None yet".
  - Audit: "Journal is enough". The inventory journal, kept for the life of the installation.
  - Data: "Includes personal data". Employee or customer personal data.
  - User access: "Public HTTPS + Nagare login". This is what EP-183 M1 proves; no company
    identity provider.
  - Compliance or security review: "None".
  - Retention and recovery time: "Accept defaults". Every point for 48 hours, the newest per day
    for 30 days, the newest verified point always; RTO 4 hours. RPO stays the `hourly` preset.
  - Not asked as a separate question, so recorded as open in UC-3: operator succession if the one
    operator is unavailable, and an erasure deadline for personal data in backups.
- The answers remove most of the team-operation scope. With one operator and no second approval,
  MasterPlan 24's multi-operator, named-reviewer and shared-material streams have no stated
  requirement. The binding requirements are data protection, HTTPS login, retention and rebuild,
  all already in EP-183.
- The journal has no operator identity field (`cli/nagarectl/src/Nagare/Inventory/Journal.hs`,
  lines 76–84; only an attested close names an operator, `Plan/CloseRecord.hs`). This is enough for
  one operator and becomes a gap only with a second.

## Decision Log

- Decision: Record requirements as a JTBD use case in the existing `docs/use-cases/` bundle rather
  than as free prose in this plan.
  Rationale: The bundle is profile-validated and registered with Mori, so later plans and other
  repositories can cite each requirement by a stable handle.
  Date: 2026-09-28

- Decision: ADR 28 is accepted on the operator's stated objectives rather than proposed for a
  separate sign-off.
  Rationale: the operator chose the recovery point, retention and four-hour recovery time
  directly, and chose four hours over a one-hour objective that would need a standby. The ADR
  only writes those choices down and the single-node shape they imply.
  Date: 2026-10-10

## Outcomes & Retrospective

2026-10-10: Requirements recorded as UC-3 and the availability decided in ADR 28. The workplace
installation is single-operator with personal data. Its open work is EP-183's, not
multi-operator features. The operator confirmed UC-3 on 2026-10-10, so both milestones are
accepted and EP-163 M3 may score against UC-3's features.

Lesson: asking the requirement questions as concrete choices took one exchange and removed four
planned streams' worth of speculative scope. Requirements should come before any tool scoring.

## Current behavior mapping

Each UC-3 feature against Nagare as of `e2ff1e1d` (2026-10-09).

| UC-3 feature | State | Evidence |
|---|---|---|
| single-operator-administration | supported | One operator's private repository and contexts ([ADR 13](../adr/0013-operator-deployment-material-lives-in-a-private-repository-with-remote-state.md), `docs/user/contexts.md`). |
| self-approved-reviewed-changes | supported | `nagarectl ... --save-plan DIR` then `nagarectl inventory apply DIR --yes` ([ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md)); no approval step exists. |
| journal-is-the-audit-record | supported (one operator) | Hash-chained events with transaction, operation, state, timestamp and detail (`cli/nagarectl/src/Nagare/Inventory/Journal.hs:76-84`); no code under `cli/nagarectl/src/Nagare/Inventory/Store*` prunes or compacts it. No operator identity per event (see Surprises). |
| protect-personal-data | partial | Backup and state buckets enforce public access prevention and uniform access (`infra/pulumi/src/components/NagarePerimeter.ts:142-170`); protected apps refuse anonymous and ungranted users (`docs/user/access.md`, ADR 15). Retention is unenforced: `nagarectl db prune-scheduled-backups` exits "new scheduled pruning is deferred" (`cli/nagarectl/app/Nagare/Cli/Commands/Database.hs:209-211`), so copies do not age out. EP-183 M2. |
| public-https-with-nagare-login | partial | Let's Encrypt issuer (`cluster/bootstrap/cert-manager/letsencrypt-dns.yaml.tmpl`), forward auth (`cluster/bootstrap/nagare-access/`), portal (`cluster/bootstrap/shomei/`) exist; never exercised end to end over trusted HTTPS (`docs/releases/v0.4.0.md`, D3). EP-183 M1. |
| revoke-an-app-user | partial | `nagarectl access revoke --host H --user U --save-plan DIR` (`docs/user/access.md:224`); never proven against a live session over HTTPS. EP-183 M1. |
| hourly-recovery-point | partial | Databases: graded hourly on v0.4.0 (`docs/releases/production-readiness-checklist.md`, section 2). Volumes: outside the objective (D2); the only volume probe grades the legacy `volumes/` prefix (`backupPrefixes`, `cli/nagarectl/src/Nagare/Ops/Probe.hs:267`) and printed `UNKNOWN backup volumes` in the v0.4.0 drills. EP-183 M3. |
| bounded-backup-retention | missing | Receipts carry `keep`, but nothing grades or enforces it (`keep` field, `cli/nagarectl/src/Nagare/Database/Backup.hs:196`). EP-183 M2. |
| four-hour-service-rebuild | missing | Planning refuses a missing accepted durable member (`durable-resource-missing`, `cli/nagarectl/src/Nagare/Inventory/Plan/Changes.hs:766`); `docs/runbooks/disaster-recovery.md` states the same context cannot be brought back. EP-183 M4 and M5. |

