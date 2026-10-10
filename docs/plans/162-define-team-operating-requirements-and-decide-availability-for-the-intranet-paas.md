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
---

# Define team operating requirements and decide availability for the intranet PaaS

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


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

- [ ] M1: The workplace operating requirements are recorded as a use case in `docs/use-cases/`,
  confirmed by the operator, and pass `okf validate`. Each requirement is mapped to Nagare's
  current behavior as supported, partial, or missing, with a file or command as evidence.
- [ ] M2: An accepted ADR states the availability model and recovery objectives, and user-facing
  capability pages that describe availability agree with it.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Record requirements as a JTBD use case in the existing `docs/use-cases/` bundle rather
  than as free prose in this plan.
  Rationale: The bundle is profile-validated and registered with Mori, so later plans and other
  repositories can cite each requirement by a stable handle.
  Date: 2026-09-28


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Nagare is a platform-as-a-service. In cloud mode it runs on one GCP Compute Engine virtual machine
(VM) running NixOS and k3s (a small Kubernetes distribution). In local mode it runs on k3d (k3s in
Docker) for development and testing. Applications are Knative Services deployed with the
`nagarectl` command-line tool (`cli/nagarectl/`). The README (`README.md`) and capability pages
(`docs/capabilities/`) describe what the platform provides.

A *target context* is a named file of settings that selects which installation (GCP project,
region, domain, and so on) a command acts on; see `CLAUDE.md` and
[ADR 13](../adr/0013-operator-deployment-material-lives-in-a-private-repository-with-remote-state.md).
Under ADR 13, each installation's contexts, host configuration, encrypted secrets (managed with
sops, a tool that encrypts files to a list of *age recipients*, meaning public keys allowed to
decrypt), and Pulumi stack configuration live in one operator's private git repository. That is
the main place where Nagare assumes a single operator.

The typed managed-resource inventory
([ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md), MasterPlan
[23](../masterplans/23-make-managed-resources-first-class-through-typed-scoped-inventories.md))
records reviewed changes and their execution history. Its shared store in the context's GCS bucket
([EP-151](151-store-inventory-history-in-the-context-state-bucket-with-conditional-writes.md))
allows one writer at a time, has no lease or liveness detection, and requires an explicit operator
takeover to resume another machine's work. A *saved review* is published by the operator who runs
the command; nothing names who approved it.

Availability today: `docs/capabilities/managed-databases-and-backups.md` and
`docs/capabilities/kafka-compatible-brokers.md` state that databases and the broker are
single-replica and not highly available. The platform is one VM; backups go to GCS (cloud) or
MinIO (local).

The research record
[RES-3](../research/managed-resource-inventory-scope-and-tooling-overlap.md) lists five
team-operation gaps (single writer without lease, local-only review approval, no upgrade path for
contexts holding data, undefined team access, availability not an explicit decision). This plan
turns those into stated requirements; it does not implement them.

Use cases in `docs/use-cases/` follow the `coordination.useCases` OKF profile pinned in
`docs/use-cases/profile.dhall`. Read `docs/use-cases/002-deliver-prebuilt-nix-closures-to-nagare-jobs.md`
for the frontmatter shape: `useCaseId` (`UC-N`), `status`, `themes`, `jobs` (actor, situation,
motivation, outcome), and `features` (description, status, owners, acceptance, jobs). Themes live in
`docs/use-cases/themes/`.

Relevant ADRs: ADR 13 and ADR 22 above;
[ADR 9](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md) (every
cloud-mutating path asserts the active context's project, which team access must preserve);
[ADR 12](../adr/0012-platform-data-disk-capacity-is-forward-only-and-grows-itself.md) and
[ADR 14](../adr/0014-the-active-context-owns-the-vm-shape.md) (the VM and data disk shape, relevant
to availability).


## Plan of Work

Milestone 1 captures the requirements. Only the operator knows the workplace's needs, so the work
begins by asking the operator the questions below, recording their answers verbatim in this plan's
Surprises & Discoveries, and then turning them into a use case. Questions: how many people will
operate the platform, and in which roles (administrator, application deployer, reviewer, auditor);
whether changes need a second person's approval, and for which kinds of change; what must be
audited and for how long; how operator access is granted and revoked, including when someone leaves;
what data the intranet holds and how it is classified; the recovery point objective (how much
recent data may be lost) and recovery time objective (how long the platform may be down) for
platform and application data; how long backups must be retained (for example every point for 48 hours and one a day for 30 days; EP-183 M2 enforces the answer); how users reach the intranet (company network, VPN, identity
provider; EP-183 M1 proves Nagare's own login portal, so a company identity provider is a separate requirement); and any compliance or security-review constraints. Do not invent answers; an unanswered
question is recorded as open.

Create `docs/use-cases/003-operate-nagare-as-a-team-run-intranet-paas.md` with the next `UC-N`
handle (check with `okf id next docs/use-cases --profile docs/use-cases/profile.dhall UC`). Add a
`team-operation` theme under `docs/use-cases/themes/`. Write one job per role and one feature per
requirement, each with an acceptance statement a person can check. Update the bundle's `index.md`
and `log.md`. Then add a short section to this plan mapping every feature to Nagare's current
behavior as supported, partial, or missing, citing a file path or command for each.

Milestone 2 records the availability decision. Using the recovery objectives from M1, write the
next ADR in `docs/adr/` (follow the existing filename and frontmatter convention; `docs/adr` is not
a profiled OKF bundle) stating whether single-node remains the supported shape, the recovery point
and time the platform commits to, and what that means for backups and restore testing. If the
decision requires more than one node or highly available databases, say so as a requirement for a
later stream; do not design it here. Update the availability wording in
`docs/capabilities/managed-databases-and-backups.md` and `docs/capabilities/kafka-compatible-brokers.md`
to cite the ADR.


## Concrete Steps

All commands run from the repository root.

```bash
okf id next docs/use-cases --profile docs/use-cases/profile.dhall UC
okf validate docs/use-cases --profile docs/use-cases/profile.dhall
okf validate docs/capabilities --profile docs/capabilities/profile.dhall
```

Stage only the files this plan changes, by explicit path; other sessions commit concurrently in
this repository.


## Validation and Acceptance

M1 is accepted when `okf validate docs/use-cases --profile docs/use-cases/profile.dhall` reports
`OK` including the new concept, the operator has confirmed the use case's jobs and features match
the workplace, and every feature has a supported/partial/missing mapping with evidence. M2 is
accepted when the ADR is merged with status accepted, it states numeric recovery objectives (or
records them as explicitly undecided with the reason), and the two capability pages cite it.


## Idempotence and Recovery

This plan only adds and edits documentation. Re-running validation is safe. If the operator
revises an answer, update the use case and its log entry rather than creating a new concept.


## Interfaces and Dependencies

This plan has no prerequisites. Its outputs are consumed by
`docs/plans/163-evaluate-established-tooling-against-nagare-s-managed-resource-layers.md`, whose
scored comparison (its M3) cannot begin until M1 here is accepted. The use-case handle created in
M1 is the stable identifier that plan cites for each requirement.
