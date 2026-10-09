---
id: 168
slug: script-the-local-acceptance-run-as-one-command
title: "Script the local acceptance run as one command"
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
      at: 2026-10-04T14:16:36Z
      mode: "update"
      note: "Haskell per ADR 24; one evidence directory, runner last, staged records"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-09T22:13:41Z
      mode: "update"
      note: "Cascade 2026-10-09 re-scope of MasterPlans 21/25/26"
---

# Script the local acceptance run as one command

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Today the local release acceptance for a Nagare candidate (called C2 in [MasterPlan 23](../masterplans/23-make-managed-resources-first-class-through-typed-scoped-inventories.md)) is run by a person typing hundreds of commands: bootstrapping a fresh local cluster, deploying a scenario, killing applies at chosen moments, backing up and restoring every database, stopping the cluster for a recovery drill, and finally assembling evidence. The first run took most of a day; a later run with session-local scripts took about fifty minutes of mostly unattended work. After this plan, a maintainer runs one command against a candidate package and gets, without further input, a finalized local health record with every required assertion and an assembled `inventory-evidence.json`, or a clear stop naming the step and the refusal.

You can see it working by running the command on the final MasterPlan 23 candidate `83124396` (v0.4.0) on the `nagare-mp23-cp3` Colima profile (or any profile sized like it) and finding `local-health.json` reporting 16 recorded assertions and `inventory-evidence.json` accepted by the assembler. This run is native run L1 of [MasterPlan 26](../masterplans/26-make-platform-changes-and-releases-routine-after-the-inventory-release.md)'s finish line.


## Progress

- [ ] M1: The tool first runs the environment preflight and refuses unless every human dependency is settled: builder reachable, `gate verify` green for the candidate revision, only the expected Colima profile running, and for cloud contexts gcloud authenticated and the Tailscale key tagged `tag:nagare-test`. It then bootstraps a fresh local context from a candidate package, runs C1 on that payload, deploys the scenario with its interruption points, seeds every store, and leaves a converged, idle context. Acceptance: a run on `83124396` ends with the store idle and accepted equal to converged, and each preflight refusal is covered by a unit test.
- [ ] M2: The tool runs every check in `fixtures/inventory-release/local/scenario.json`, including the source-unavailable drill, and records each assertion. Acceptance: `scripts/scenario-assertions.py finalize` reports all required assertions.
- [ ] M3: After every scenario mutation, the tool runs the runner rehearsal: plan, apply and verify back to back in the evidence directory (one packaged CreateResource, apply, a verified no-op, every provider observable). It then replays the staged records and assembles `inventory-evidence.json`. Acceptance: the assembler accepts that same directory.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision (superseded the same day): Write the runner in bash with small Python helpers, matching the existing `scripts/rehearse-*.sh` and `scripts/scenario-assertions.py`.
  Rationale at the time: The pieces it composes are already bash and Python.
  Date: 2026-10-04
- Decision: Write the acceptance tool in Haskell, per [ADR 24](../adr/0024-release-and-harness-tooling-follows-the-production-haskell-standard.md) (operator decision). It reuses `nagarectl`'s library types for reviews, exports, run records and evidence. It ports the evidence helpers it needs (scenario assertion records, the unchanged runner candidate, managed-resource assembly) instead of calling the frozen Python.
  Rationale: The shell-plus-Python drivers that ran MasterPlan 23's acceptance needed 17 untested inline Python blocks. The assembler's F42 defect, a check correct only against invented fixtures, came from the same style. One standard and shared types make evidence-format drift a compile error.
  Date: 2026-10-04
- Decision: There is one evidence directory, created by the runner's plan. The runner runs last. Checks write to a staging directory, and their records are deferred until the runner's plan exists.
  Rationale: The assembler requires the runner's plan, apply and verify back to back (`final-observation.accepted == review.desiredRevisions`), and the runner's plan refuses an existing directory. The first `7d486457` run broke this and could not be assembled.
  Date: 2026-10-04


- Decision: Port the driver set that passed C2 16/16 on `83124396`, stage for stage, rather than re-deriving the run. The set is archived as a frozen record in `docs/audits/mp23-independent-results-2026-10-07/drivers-83124396/` (`c2/`). Its stages are `setup`, `phase1`, C1, `phase2`, `phase2b`, `rebind-check`, `restores`, `misc`, `su`, `final-a`, `retire-kept`, `final-b` and `assemble`.
  Rationale: It is the only acceptance run known to pass unattended. Porting a passing sequence turns a design problem into a translation with fixture replay.
  Date: 2026-10-09
- Decision: This tool owns the environment preflight, and MasterPlan 25's teardown runner reuses it.
  Rationale: MasterPlan 23's overnight stalls were human dependencies: a Tailscale SSH check waiting for a browser approval for 3 h 40 m, gcloud re-authentication, and a builder that was off. A refusal at start costs seconds.
  Date: 2026-10-09
- Decision: Once [MasterPlan 25](../masterplans/25-reviewed-full-context-teardown-with-vm-workload-collection.md) EP-167 M3 lands reviewed local teardown, the tool runs it as its final stage, and `--replace-cluster` stops being the normal path.
  Rationale: Teardown then runs every release instead of rotting.
  Date: 2026-10-09


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Terms. A candidate is an exact commit whose Nix package `nix build .#nagare` contains the `nagarectl` CLI and the platform payload (the manifests and scripts the CLI installs, see [ADR 4](../adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md)). A local context is a Nagare target in `mode=local` that points every primitive at a k3d cluster named `nagare-local`, the registry `k3d-registry.localhost:5000` and an in-cluster MinIO object store. An operator root is a directory holding isolated `config/`, `state/` and `cache/` directories for one context, used through a wrapper script that runs `nagarectl` under `env -i`. Review, apply, resume and recover are the typed inventory's transaction commands ([ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md)).

The procedure this tool automates is recorded in four places, all checked in. `docs/plans/155-prove-local-application-and-data-recovery-end-to-end.md` (the "Milestone 2 execution plan" and "Phase 3: the checks") lists every check and its expected result. `docs/runbooks/native-verification-harness.md` records the harness facts. Its section 6 is the C2 procedure, with its hard rules, inputs and step table. `docs/audits/mp23-implementer-results-2026-10-03/c2-acceptance-7d486457.json` records the accepted, assembled run for candidate `7d486457`. `docs/audits/mp23-implementer-results-2026-10-03/c2-drivers/` holds the exact drivers that ran it, as a frozen record: reference for exact commands only, not code to build on. The newer set that passed on the final candidate `83124396` is in `docs/audits/mp23-independent-results-2026-10-07/drivers-83124396/c2/`, with its result in `docs/audits/mp23-independent-results-2026-10-07/c2-acceptance-83124396/`. Port that set. The scenario itself is `fixtures/inventory-release/local/scenario.json` with configs under `fixtures/inventory-release/local/apps/`.

Existing building blocks. Call the CLI and the cluster; port the Python helpers instead of shelling out to them: `scripts/run-local-candidate-gate.py` (C1), `scripts/rehearse-local-inventory-release.sh` and `scripts/rehearse-managed-resources.sh` (runner plan, apply, verify; verify is re-runnable until its marker), `scripts/unchanged-inventory-candidate.py` (unchanged runner candidate with retained reservations and `--add-packaged-scope`), `scripts/scenario-assertions.py` (record and finalize), and `scripts/assemble-managed-resource-evidence.sh` (assembly).

Facts learned the hard way that the tool must encode. The wrapper must not forward the caller's `NAGARE_PLATFORM_ROOT`; the repository shell exports it as the source checkout, and the packaged CLI only sets it when unset, so forwarding it selects a development workspace instead of the candidate payload. The local substrate fixes the cluster name, registry and host ports, so only one local cluster can exist per Docker host; a fresh context means deleting the previous cluster, which is destructive and needs the operator's explicit approval. The platform bootstrap may stop ambiguous on readiness waits (a CRD whose create reply was lost, the `routing-serving-certs` certificate, the `nagare-access` service); the supported path is `inventory resume`, and only those readiness stops may be resumed automatically. Any other refusal must stop the tool. `storage snapshot` and `storage restore` reject an Application config and need a projection that calls `emitDeployment` (EP-160 limitation). `cleanup --previews` defaults to namespace `default`; the scenario needs `-n personal`. The en authorization service caches reads for about five seconds, so `access list` must be polled. `inventory status` reports complete observation only when the en endpoint and its read-write key are available (`NAGARE_EN_URL`, `NAGARE_EN_API_KEY`), so every runner phase must run with them. The source-unavailable drill copies the MinIO volume while the node runs, stops the node, serves the copy from a disposable MinIO on a loopback port, and verifies with `db verify-escrowed-backup --offline-object-store --offline-credentials` (F41). After the node restarts, wait until every APIService is Available and namespaced API discovery is stable, before any reviewed collection. A collection review binds the discovery it saw: one planned before metrics-server returned was refused at apply. The packaged runner probe is declared `Retain`, so it can be used once per context. Every `platform bootstrap` plan, including the one inside the C1 gate, needs the pinned images from `images.env` in its environment.


## Plan of Work

M1, bootstrap and scenario. Create a Haskell executable, `nagare-harness`, with a `local-acceptance` command. It lives in its own package in the cabal workspace (proposed `cli/nagare-harness`), outside the platform payload (EP-171), and depends on the `nagarectl` library. Its explicit inputs are the candidate package path, an image source (an OCI layout of the auth and MinIO images, or a build step via `scripts/publish-local-minio-images.sh` and the auth image builders), a new operator root, and an explicit `--replace-cluster` flag without which the tool refuses when a `nagare-local` cluster exists. The tool writes its wrappers into the root (no `NAGARE_PLATFORM_ROOT` passthrough; an access-capable bare wrapper for runner phases), creates the context, runs the two bootstrap stages and the platform bootstrap with the bounded readiness resume, runs the C1 gate on the fresh payload, then executes the scenario steps (data stores, broker and topic, images, secrets, both deploys with their interruption kills and resumes, the site, its environment stores and the preview) and seeds every store with the fixture's known content. Every step logs to a per-step file, and the tool stops on the first unexpected result.

M2, checks. Port each check from the archived drivers into typed functions. Each writes public evidence under the staging directory's `checks/<name>/` and queues its assertion record. Records are written with the ported recorder (same format and rules as `scripts/scenario-assertions.py`). Include the drift check with `--take-over-fields`, both wrong-incarnation cases, the F36 pinned-version deletion, the source-unavailable drill, independent scope preservation, access grant and revoke with polling, retained data with the isolated history restore, preview cleanup, and the secret scan. Run preview cleanup last among the mutations, after the settle wait.

M3, runner and assembly. Run the runner's plan, apply and verify back to back with en forwarded. Between apply and verify, the only steps are copying the staged checks and replaying the queued records. Verify gets the final-marker interruption. Then record the three verify-dependent assertions and finalize. Run the plan and verify using `unchanged-inventory-candidate.py` with `--add-packaged-scope runner-probe=cluster/examples/hello-knative-service/service.yaml` for the plan and the unchanged post-apply candidate for verify, then run the assembler with the release build manifest and the coverage audit result for the candidate revision.


## Concrete Steps

Run from the repository root. The intended interface:

```bash
cabal run nagare-harness -- local-acceptance \
  --candidate /path/to/result-<rev>-nagare \
  --images /path/to/oci-layout \
  --operator-root /private/tmp/nagare-acceptance-<rev>.XXXXXX \
  --replace-cluster   # only with the operator's approval
```

A successful run ends with:

```text
finalize: 16 recorded assertions
assembled: <root>/evidence/c2-<rev>/inventory-evidence.json
```


## Validation and Acceptance

Run the tool on the then-current candidate. Acceptance is the three milestone conditions: an idle converged context after M1, `scenario-assertions.py finalize` accepting all required assertions after M2, and the assembler accepting the runner directory after M3. A deliberate failure (for example, pre-creating an unowned object at a planned address before the adoption step) must stop the tool with that step named, and must not record the assertion. Running the tool twice against the same operator root must refuse rather than mix evidence. The tool's own tests replay real output from the `7d486457` run as fixtures.


## Idempotence and Recovery

The tool refuses an existing operator root and an existing cluster unless `--replace-cluster` is given. Each stage writes a marker; a rerun with `--resume-from <stage>` continues only from a stage whose predecessor marker exists and whose store is idle. The bounded readiness resume uses `inventory resume` only; any other stopped or ambiguous transaction stops the tool for a human, as the repository rules require.


## Interfaces and Dependencies

Output layout (shared with EP-169, EP-170 and EP-172 through the MasterPlan):
- `<root>/evidence/c2-<rev>/` is one self-contained directory, created by the runner's plan: `local-health.json`, `assertions/`, `checks/`, the runner rehearsal and `inventory-evidence.json`. It is what C5 places under `local/`.
- `<root>/evidence/c2-<rev>-staging/` holds checks written before the runner's plan.
- `<root>/evidence-private/` holds exports, escrow and credentials, and is never published.

Depends on [ADR 24](../adr/0024-release-and-harness-tooling-follows-the-production-haskell-standard.md) for language and standards. Depends on the final MasterPlan 23 candidate's command surface and on the F41, F42 and F44 fixes being in that candidate.
