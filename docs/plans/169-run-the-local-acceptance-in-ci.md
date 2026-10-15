---
id: 169
slug: run-the-local-acceptance-in-ci
title: "Run the local acceptance in CI"
kind: exec-plan
created_at: 2026-10-04T04:49:45Z
master_plan: "docs/masterplans/26-make-platform-changes-and-releases-routine-after-the-inventory-release.md"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-10-04T04:49:45Z
  revisions:
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-05T03:25:17Z
      mode: "update"
      note: "On hold: operator rejects GitHub Actions; re-scope or cancel"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-05T03:50:52Z
      mode: "update"
      note: "Cancelled by operator: no GitHub Actions"
---

# Run the local acceptance in CI

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

Full plan before trimming: [169-run-the-local-acceptance-in-ci.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/169-run-the-local-acceptance-in-ci.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

After [EP-168](168-script-the-local-acceptance-run-as-one-command.md), the local release acceptance is one command, but it still needs a maintainer's workstation with a large Colima profile and someone to start it. After this plan, the same command runs in CI for a candidate: a workflow builds the candidate package, starts a k3d cluster inside Docker, runs the acceptance and uploads the public evidence. A maintainer can see it working as a green workflow run whose artifact contains `local-health.json` with all required assertions and an accepted `inventory-evidence.json`.

## Progress

- [-] M1: A CI job starts a k3d cluster sized for the full local platform inside a Docker-in-Docker environment and completes the platform bootstrap. Acceptance: the job's log ends with a converged platform review. {disposition=declined}
- [-] M2: The job runs `scripts/run-local-acceptance.sh` end to end and uploads only public evidence. Acceptance: a green run on the then-current candidate with all required assertions finalized and no private material in the artifact. {disposition=declined}

## Surprises & Discoveries

- GitHub Actions has been disabled for the repository since 2026-09-22, so this plan's assumption that a workflow can run is false ([retrospective](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/audits/mp23-engineering-retrospective-2026-10-04.md)).

## Decision Log

- Decision: Cancelled (operator, 2026-10-04). This plan must not use GitHub Actions. EP-168's one-command local run and EP-174's local gates cover the need.
  Rationale: Operator decision, 2026-10-04: "GitHub Actions is so slow" and "do not use github action". The per-commit and per-candidate gates are local ([EP-174](174-gate-every-commit-before-any-native-run.md)), and EP-168's one-command run already gives a maintainer the acceptance on their own machine.
  Date: 2026-10-04

- Decision: Trigger the job for candidates (manual dispatch with a revision, and candidate tags), not on every push.
  Rationale: A full run takes tens of minutes and needs a large runner; most pushes are covered by EP-170's change classes and by `nix flake check`.
  Date: 2026-10-04

## Outcomes & Retrospective

Cancelled 2026-10-04 (operator: no GitHub Actions). EP-174's local per-commit gate and EP-172's release rehearsal cover the need.

