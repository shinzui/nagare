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
---

# Script the local acceptance run as one command

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Today the local release acceptance for a Nagare candidate (called C2 in [MasterPlan 23](../masterplans/23-make-managed-resources-first-class-through-typed-scoped-inventories.md)) is run by a person typing hundreds of commands: bootstrapping a fresh local cluster, deploying a scenario, killing applies at chosen moments, backing up and restoring every database, stopping the cluster for a recovery drill, and finally assembling evidence. The first run took most of a day; a later run with session-local scripts took about fifty minutes of mostly unattended work. After this plan, a maintainer runs one command against a candidate package and gets, without further input, a finalized local health record with every required assertion and an assembled `inventory-evidence.json`, or a clear stop naming the step and the refusal.

You can see it working by running the command on the current candidate on the `nagare-mp23-cp3` Colima profile (or any profile sized like it) and finding `local-health.json` reporting 16 recorded assertions and `inventory-evidence.json` accepted by the assembler.


## Progress

- [ ] M1: The script bootstraps a fresh local context from a candidate package, runs C1 on that payload, deploys the scenario with its interruption points, seeds every store, and leaves a converged, idle context. Acceptance: a run on the then-current candidate ends with the store idle and accepted equal to converged.
- [ ] M2: The script runs every check in `fixtures/inventory-release/local/scenario.json`, including the source-unavailable drill, and records each assertion. Acceptance: `scripts/scenario-assertions.py finalize` reports all required assertions.
- [ ] M3: The script runs the runner rehearsal (one packaged CreateResource, apply, verified no-op) with every provider observable and assembles `inventory-evidence.json`. Acceptance: the assembler accepts the runner directory.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Write the runner in bash with small Python helpers, matching the existing `scripts/rehearse-*.sh` and `scripts/scenario-assertions.py`.
  Rationale: The pieces it composes are already bash and Python; a new language would add a dependency without reducing risk.
  Date: 2026-10-04


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Terms. A candidate is an exact commit whose Nix package `nix build .#nagare` contains the `nagarectl` CLI and the platform payload (the manifests and scripts the CLI installs, see [ADR 4](../adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md)). A local context is a Nagare target in `mode=local` that points every primitive at a k3d cluster named `nagare-local`, the registry `k3d-registry.localhost:5000` and an in-cluster MinIO object store. An operator root is a directory holding isolated `config/`, `state/` and `cache/` directories for one context, used through a wrapper script that runs `nagarectl` under `env -i`. Review, apply, resume and recover are the typed inventory's transaction commands ([ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md)).

The procedure this script automates is recorded in four places, all checked in. `docs/plans/155-prove-local-application-and-data-recovery-end-to-end.md` (the "Milestone 2 execution plan" and "Phase 3: the checks") lists every check and its expected result. `docs/runbooks/native-verification-harness.md` records the harness facts: candidate builds, operator roots and wrappers, the cp3 claim protocol, the C1 gate, object-store drills. `docs/audits/mp23-implementer-results-2026-10-03/c2-acceptance-14071e58.json` records the accepted run for candidate `14071e58`, and `docs/audits/mp23-implementer-results-2026-10-03/c2-drivers/` holds the session-local prototype drivers that ran it (reference only: they hard-code one root). The scenario itself is `fixtures/inventory-release/local/scenario.json` with configs under `fixtures/inventory-release/local/apps/`.

Existing building blocks the script must call rather than reimplement: `scripts/run-local-candidate-gate.py` (C1), `scripts/rehearse-local-inventory-release.sh` and `scripts/rehearse-managed-resources.sh` (runner plan, apply, verify; verify is re-runnable until its marker), `scripts/unchanged-inventory-candidate.py` (unchanged runner candidate with retained reservations and `--add-packaged-scope`), `scripts/scenario-assertions.py` (record and finalize), and `scripts/assemble-managed-resource-evidence.sh` (assembly).

Facts learned the hard way that the script must encode. The wrapper must not forward the caller's `NAGARE_PLATFORM_ROOT`; the repository shell exports it as the source checkout, and the packaged CLI only sets it when unset, so forwarding it selects a development workspace instead of the candidate payload. The local substrate fixes the cluster name, registry and host ports, so only one local cluster can exist per Docker host; a fresh context means deleting the previous cluster, which is destructive and needs the operator's explicit approval. The platform bootstrap may stop ambiguous on readiness waits (a CRD whose create reply was lost, the `routing-serving-certs` certificate, the `nagare-access` service); the supported path is `inventory resume`, and only those readiness stops may be resumed automatically. Any other refusal must stop the script. `storage snapshot` and `storage restore` reject an Application config and need a projection that calls `emitDeployment` (EP-160 limitation). `cleanup --previews` defaults to namespace `default`; the scenario needs `-n personal`. The en authorization service caches reads for about five seconds, so `access list` must be polled. `inventory status` reports complete observation only when the en endpoint and its read-write key are available (`NAGARE_EN_URL`, `NAGARE_EN_API_KEY`), so every runner phase must run with them. The source-unavailable drill copies the MinIO volume while the node runs, stops the node, serves the copy from a disposable MinIO on a loopback port, and verifies with `db verify-escrowed-backup --offline-object-store --offline-credentials` (F41).


## Plan of Work

M1, bootstrap and scenario. Create `scripts/run-local-acceptance.sh` with explicit inputs: the candidate package path, an image source (an OCI layout of the auth and MinIO images, or a build step via `scripts/publish-local-minio-images.sh` and the auth image builders), a new operator root, and an explicit `--replace-cluster` flag without which the script refuses when a `nagare-local` cluster exists. The script writes its wrappers into the root (no `NAGARE_PLATFORM_ROOT` passthrough; an access-capable bare wrapper for runner phases), creates the context, runs the two bootstrap stages and the platform bootstrap with the bounded readiness resume, runs the C1 gate on the fresh payload, then executes the scenario steps (data stores, broker and topic, images, secrets, both deploys with their interruption kills and resumes, the site, its environment stores and the preview) and seeds every store with the fixture's known content. Every step logs to a per-step file and the script stops on the first unexpected result.

M2, checks. Port each check from the prototype drivers into functions that write public evidence under `checks/<name>/` and call `scenario-assertions.py record`. Include the drift check with `--take-over-fields`, both wrong-incarnation cases, the F36 pinned-version deletion, the source-unavailable drill, independent scope preservation, access grant and revoke with polling, retained data with the isolated history restore, preview cleanup, and the secret scan. Run `finalize` at the end.

M3, runner and assembly. Run the runner's plan, apply and verify with en forwarded, using `unchanged-inventory-candidate.py` with `--add-packaged-scope runner-probe=cluster/examples/hello-knative-service/service.yaml` for the plan and the unchanged post-apply candidate for verify, then run the assembler with the release build manifest and the coverage audit result for the candidate revision.


## Concrete Steps

Run from the repository root. The intended interface:

```bash
scripts/run-local-acceptance.sh \
  --candidate /path/to/result-<rev>-nagare \
  --images /path/to/oci-layout \
  --operator-root /private/tmp/nagare-acceptance-<rev>.XXXXXX \
  --replace-cluster   # only with the operator's approval
```

A successful run ends with:

```text
finalize: 16 recorded assertions
assembled: <root>/evidence/runner/inventory-evidence.json
```


## Validation and Acceptance

Run the script on the then-current candidate. Acceptance is the three milestone conditions: an idle converged context after M1, `scenario-assertions.py finalize` accepting all required assertions after M2, and the assembler accepting the runner directory after M3. A deliberate failure (for example, pre-creating an unowned object at a planned address before the adoption step) must stop the script with that step named, and must not record the assertion. Running the script twice against the same operator root must refuse rather than mix evidence.


## Idempotence and Recovery

The script refuses an existing operator root and an existing cluster unless `--replace-cluster` is given. Each stage writes a marker; a rerun with `--resume-from <stage>` continues only from a stage whose predecessor marker exists and whose store is idle. The bounded readiness resume uses `inventory resume` only; any other stopped or ambiguous transaction stops the script for a human, as the repository rules require.


## Interfaces and Dependencies

Output layout (shared with EP-169, EP-170 and EP-172 through the MasterPlan): `<root>/evidence/c2/` (assertions, checks, local-health.json), `<root>/evidence/runner/` (runner rehearsal and inventory-evidence.json), `<root>/evidence-private/` (exports, escrow, credentials; never published). Depends on the final MasterPlan 23 candidate's command surface and on the F41, F42 and F44 fixes being in that candidate.
