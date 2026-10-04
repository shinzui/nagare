---
id: 170
slug: size-the-release-gate-to-the-change
title: "Size the release gate to the change"
kind: exec-plan
created_at: 2026-10-04T04:49:45Z
master_plan: "docs/masterplans/26-make-platform-changes-and-releases-routine-after-the-inventory-release.md"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-10-04T04:49:45Z
---

# Size the release gate to the change

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Under [MasterPlan 23](../masterplans/23-make-managed-resources-first-class-through-typed-scoped-inventories.md) every candidate needs the full native evidence: C1 on an installed platform, C2 on a fresh local context and C3 on a fresh GCP context. That is right for a change to the platform payload, and wasteful for a typo in a user guide. After this plan, the release gate looks at what changed between the last accepted candidate and the new one, assigns a change class, and requires only that class's evidence, carrying earlier evidence forward when the parts it proves are byte-identical. A maintainer can see it by running the classifier on two revisions and seeing the class and the evidence it requires, and by the gate accepting a docs-only candidate with carried-forward evidence while refusing a payload change without fresh native runs.


## Progress

- [ ] M1: A deterministic classifier maps the changes between two revisions to a change class and the required evidence, with tests covering each class. Acceptance: classifier tests pass and its output on real MasterPlan 23 candidate pairs matches a hand-checked expectation.
- [ ] M2: The release gate (`scripts/assemble-inventory-release-index.py` and the release workflow) enforces the class's requirements and accepts carried-forward evidence only when the proved parts are identical. Acceptance: gate tests for each class, including a refused attempt to carry evidence across a payload change.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Bind carried-forward evidence to content digests of what it proves (the CLI source tree, the payload asset digest, the fixture digest), not to the git revision.
  Rationale: The CLI embeds its git revision, so even a docs-only commit changes the binary's reported revision; content digests are the only stable identity for "the same thing was proven".
  Date: 2026-10-04


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Today the payload is everything `nix/platform-package.nix` copies: `infra/pulumi`, `cluster/`, the whole `scripts/` directory, `docs/user`, `docs/runbooks` and two plan documents. The payload's workspace name includes a digest over shipped asset paths and contents ([ADR 4](../adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md)), so editing a runbook or a release script changes the payload digest. Until [EP-171](171-move-release-tooling-out-of-the-platform-payload.md) narrows the payload, most documentation and script edits are therefore payload changes, and this classifier must treat them that way.

The release gate today: [ADR 7](../adr/0007-publish-immutable-nix-releases-from-validated-tags.md) requires the version in `release.json` to match every package, the CLI, the payload, release notes and compatibility fixtures; `docs/plans/157-gate-the-inventory-release-on-complete-immutable-evidence.md` (EP-157) assembles candidate-bound evidence through `scripts/assemble-inventory-release-index.py`, `scripts/assemble-managed-resource-evidence.sh` and `scripts/assemble-release.sh`, and every evidence record binds the candidate's operator revision, payload and fixture digests. [ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) (2026-09-26 amendment) makes command coverage candidate-bound release evidence.

Proposed classes, to be confirmed in M1. Harness-only: only paths outside the CLI sources and the payload changed; no native evidence needed, earlier evidence carries forward. CLI/app: CLI sources changed but the payload asset digest is identical; requires C1 and the local acceptance (C2), with C3 carried forward only when the cloud-facing code paths are unchanged (to be defined precisely in M1, or else C3 is required). Payload/substrate: the payload digest changed; requires the full C1, C2 and C3.


## Plan of Work

M1: add `scripts/classify-candidate-change.py BASE HEAD` that reads `git diff --name-only`, computes the CLI source tree digest and the payload asset digest for both revisions (reusing the payload's own digest computation rather than reimplementing it), and prints a JSON decision: class, changed path groups, required evidence and carry-forward bindings. Add tests with synthetic repositories for each class and a check against two real MasterPlan 23 candidate pairs (for example `44ff0fd7` to `14071e58`, which changed CLI and payload).

M2: extend the release index assembly to read the classifier decision and accept, for each required record, either fresh evidence for the candidate or carried-forward evidence whose bindings equal the candidate's digests. Record the class and the carried-forward provenance in the release index. Update the release workflow to run the classifier and fail when required fresh evidence is missing. Amend ADR 7 with the change classes and the carry-forward rule.


## Concrete Steps

```bash
python3 scripts/classify-candidate-change.py 44ff0fd7 14071e58
```

Expected output shape:

```json
{"class": "payload", "required": ["c1", "c2", "c3"], "carryForward": []}
```


## Validation and Acceptance

Classifier tests pass for each class. Gate tests show a docs-only candidate accepted with carried-forward C1/C2/C3, a CLI-only candidate refused without fresh C1 and C2, and a payload candidate refused when it offers carried-forward evidence bound to a different payload digest.


## Idempotence and Recovery

The classifier is read-only and deterministic for a pair of revisions. Gate changes are additive: the existing full-evidence path remains valid for every class.


## Interfaces and Dependencies

Soft dependencies: [EP-168](168-script-the-local-acceptance-run-as-one-command.md) for the evidence layout the gate consumes, and EP-171 for the narrowed payload boundary that makes the harness-only class common. Produces the change-class decision consumed by [EP-172](172-rehearse-candidate-upgrades-of-an-inventory-context-instead-of-rebuilding-it.md).
