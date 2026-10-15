---
id: 171
slug: move-release-tooling-out-of-the-platform-payload
title: "Move release tooling out of the platform payload"
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
      at: 2026-10-09T22:17:13Z
      mode: "update"
      note: "Cascade 2026-10-09 re-scope of MasterPlans 21/25/26"
---

# Move release tooling out of the platform payload

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

Full plan before trimming: [171-move-release-tooling-out-of-the-platform-payload.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/171-move-release-tooling-out-of-the-platform-payload.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

The platform payload is the set of files the `nagarectl` CLI installs into a context and runs from (manifests, Pulumi programs, helper scripts). Today `nix/platform-package.nix` copies the whole `scripts/` directory into it, along with `docs/user` and `docs/runbooks`. So fixing a release-evidence script, a test, or a runbook changes the payload, which by MasterPlan 23's rules makes a new release candidate and a full native verification cycle. During MasterPlan 23 this happened with finding F42: a defect in `scripts/assemble-managed-resource-evidence.sh`, which only assembles evidence and is never run by an installed CLI, could only be fixed by minting a new candidate. After this plan, the payload contains only what an installed CLI actually executes or reads, and release, audit and test tooling lives in a versioned harness outside it. A maintainer can see it by changing a release script and observing that the built payload's asset digest is unchanged.

## Progress

**Cancelled (operator, 2026-10-14; MasterPlan 26 Decision Log).** `just release-candidate VERSION --revision REV` runs the tooling from the working tree, so a tooling fix no longer mints a candidate (`78a79865` landed after candidate `ba6dd7d7`); the Haskell derivations build from their `cli/` subtrees and the sweep skip ignores `scripts/`. The payload keeps shipping the whole `scripts/` directory.

- [ ] M1: An inventory of every file the payload ships, each classified as runtime (read or executed by an installed CLI, a justfile recipe, a manifest or a host flake) or tooling (release, audit, rehearsal, check, test). Acceptance: the classification is checked in with the evidence for each runtime entry (the code path that uses it).
- [ ] M2: The payload ships only runtime files, the harness tooling is versioned separately and recorded in release evidence, and every existing check still passes. Acceptance: `nix flake check` passes; changing a tooling script leaves the payload digest unchanged; the release evidence records the harness revision.

## Surprises & Discoveries

(None yet.)

## Decision Log

- Decision: Classify by observed use (code paths and recipes that reference a file), not by name.
  Rationale: Names such as `rehearse-*` look like tooling, but a recipe or a manifest may reference them; only the referencing code proves a file is runtime.
  Date: 2026-10-04

- Decision (2026-10-09): The harness identity is the `cli/nagare-harness` package that EP-174 created. Tooling moved out of the payload goes there, ported to Haskell when touched ([ADR 24](../adr/0024-release-and-harness-tooling-follows-the-production-haskell-standard.md)), or stays as frozen scripts outside `share/nagare`. EP-172's release compatibility table is a runtime file and ships in the payload.
  Rationale: The harness package now exists, and EP-169's separate checkout premise is gone. The transition table must travel with the release it describes.
  Date: 2026-10-09

## Outcomes & Retrospective

(To be filled during and after implementation.)

