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
---

# Move release tooling out of the platform payload

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

The platform payload is the set of files the `nagarectl` CLI installs into a context and runs from (manifests, Pulumi programs, helper scripts). Today `nix/platform-package.nix` copies the whole `scripts/` directory into it, along with `docs/user` and `docs/runbooks`. So fixing a release-evidence script, a test, or a runbook changes the payload, which by MasterPlan 23's rules makes a new release candidate and a full native verification cycle. During MasterPlan 23 this happened with finding F42: a defect in `scripts/assemble-managed-resource-evidence.sh`, which only assembles evidence and is never run by an installed CLI, could only be fixed by minting a new candidate. After this plan, the payload contains only what an installed CLI actually executes or reads, and release, audit and test tooling lives in a versioned harness outside it. A maintainer can see it by changing a release script and observing that the built payload's asset digest is unchanged.


## Progress

- [ ] M1: An inventory of every file the payload ships, each classified as runtime (read or executed by an installed CLI, a justfile recipe, a manifest or a host flake) or tooling (release, audit, rehearsal, check, test). Acceptance: the classification is checked in with the evidence for each runtime entry (the code path that uses it).
- [ ] M2: The payload ships only runtime files, the harness tooling is versioned separately and recorded in release evidence, and every existing check still passes. Acceptance: `nix flake check` passes; changing a tooling script leaves the payload digest unchanged; the release evidence records the harness revision.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Classify by observed use (code paths and recipes that reference a file), not by name.
  Rationale: Names such as `rehearse-*` look like tooling, but a recipe or a manifest may reference them; only the referencing code proves a file is runtime.
  Date: 2026-10-04


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

`nix/platform-package.nix` builds the payload: it copies `infra/pulumi`, `cluster/`, `scripts/`, `docs/user`, `docs/runbooks` and two plan documents into `share/nagare`, and `nix/checks/scripts/nagare-platform-assets.sh` checks the result. The CLI resolves the payload root through `cli/nagarectl/src/Nagare/Platform/Paths.hs` (an explicit root, then the packaged `NAGARE_PLATFORM_ROOT`, then a source checkout) and materializes it per context as a workspace ([ADR 4](../adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md)). `cli/nagarectl/src/Nagare/Platform/Workspace.hs` defines `workspaceAssets` (including `scripts`, `docs/user`, `docs/runbooks` and two plan documents) and `payloadDigest`, a SHA-256 over every file under those roots; the workspace directory is named `<payloadId>-<first 16 digest characters>`. Changing any shipped file therefore changes the workspace digest and, under MasterPlan 23's evidence rules, the candidate.

Scripts the CLI runs directly through `#scriptsDir` (found by searching `cli/nagarectl/src` and `cli/nagarectl/app`): `iap-ssh.sh`, `inventory-host-transport.sh`, `inventory-artifact-transport.sh`, `inventory-cache-transport.sh`, `upload-images.sh`, `host-switch.sh` and `enable-apis.sh`. The shipped `justfile` references further scripts. Of the 108 files in `scripts/`, 61 are tests (`test-*`), and about 17 are release, audit, rehearsal or check tooling (`assemble-*`, `audit-managed-commands.py`, `check-*`, `rehearse-*`, `run-local-candidate-gate.py`, `scenario-assertions.py`, `unchanged-inventory-candidate.py`). Runbooks under `docs/runbooks` are operator reading material; whether an installed CLI needs them offline is a decision for M1.

[ADR 7](../adr/0007-publish-immutable-nix-releases-from-validated-tags.md) defines release publishing from validated tags and what the release gate compares; moving tooling must keep that gate meaningful, which is why the harness revision must be recorded in the evidence it produces.


## Plan of Work

M1: write `scripts/payload-assets.json` (or a section in `nix/platform-package.nix`) listing each shipped path with its class and, for runtime entries, the referencing code path. Build it by searching the CLI sources, the shipped `justfile`, `cluster/` manifests and host flake templates for references. Decide explicitly whether `docs/user` and `docs/runbooks` stay (the CLI's `docs` path in `Paths.hs` suggests some user docs are read at runtime).

M2: change `nix/platform-package.nix` to copy only runtime entries, narrow `workspaceAssets` in `Workspace.hs` to match (the two lists must stay identical, or a source-checkout payload and a packaged payload digest differently), update `nix/checks/scripts/nagare-platform-assets.sh` to assert exactly that set, and give the tooling a harness identity (its own revision recorded by the scripts that produce evidence, for example in `local-health.json` and the inventory evidence). Update EP-157's assembly to record the harness revision beside the candidate revision. Amend ADR 4 or ADR 7 with the payload/harness boundary.


## Concrete Steps

```bash
nix build .#nagare --out-link /tmp/payload-before
# change a tooling script only, then:
nix build .#nagare --out-link /tmp/payload-after
# materialize each payload into a scratch context and compare the workspace directory names
```

Expected after M2: both payloads materialize to the same `<payloadId>-<digest prefix>` workspace, because `payloadDigest` no longer covers the changed file. A test in the nagarectl suite asserts that `workspaceAssets` excludes the tooling paths.


## Validation and Acceptance

`nix flake check` passes. An installed CLI completes the local acceptance ([EP-168](168-script-the-local-acceptance-run-as-one-command.md)) with the narrowed payload, proving nothing runtime was removed. A tooling-only change produces an identical payload digest, and a runtime script change produces a different one.


## Idempotence and Recovery

The change is reversible by restoring the broader copy in `nix/platform-package.nix`. A runtime file wrongly classified as tooling shows up as a missing-asset failure in the local acceptance or the platform-assets check, not silently.


## Interfaces and Dependencies

No hard dependencies; it should land before most other streams finish. It defines the payload boundary consumed by [EP-170](170-size-the-release-gate-to-the-change.md) (change classes) and [EP-169](169-run-the-local-acceptance-in-ci.md) (checking out harness tooling separately).
