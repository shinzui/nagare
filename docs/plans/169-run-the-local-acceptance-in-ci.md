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
---

# Run the local acceptance in CI

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After [EP-168](168-script-the-local-acceptance-run-as-one-command.md), the local release acceptance is one command, but it still needs a maintainer's workstation with a large Colima profile and someone to start it. After this plan, the same command runs in CI for a candidate: a workflow builds the candidate package, starts a k3d cluster inside Docker, runs the acceptance and uploads the public evidence. A maintainer can see it working as a green workflow run whose artifact contains `local-health.json` with all required assertions and an accepted `inventory-evidence.json`.


## Progress

- [ ] M1: A CI job starts a k3d cluster sized for the full local platform inside a Docker-in-Docker environment and completes the platform bootstrap. Acceptance: the job's log ends with a converged platform review.
- [ ] M2: The job runs `scripts/run-local-acceptance.sh` end to end and uploads only public evidence. Acceptance: a green run on the then-current candidate with all required assertions finalized and no private material in the artifact.


## Surprises & Discoveries

- GitHub Actions has been disabled for the repository since 2026-09-22, so this plan's assumption that a workflow can run is false ([retrospective](../audits/mp23-engineering-retrospective-2026-10-04.md)).


## Decision Log

- Decision: This plan must not use GitHub Actions. It is on hold until the operator either re-scopes it to a runner they accept or cancels it.
  Rationale: Operator decision, 2026-10-04: "GitHub Actions is so slow" and "do not use github action". The per-commit and per-candidate gates are local ([EP-174](174-gate-every-commit-before-any-native-run.md)), and EP-168's one-command run already gives a maintainer the acceptance on their own machine.
  Date: 2026-10-04

- Decision: Trigger the job for candidates (manual dispatch with a revision, and candidate tags), not on every push.
  Rationale: A full run takes tens of minutes and needs a large runner; most pushes are covered by EP-170's change classes and by `nix flake check`.
  Date: 2026-10-04


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

CI today is GitHub Actions: `.github/workflows/ci.yml` runs `nix flake check` and a `nagare-access` compatibility check on `ubuntu-latest`; `.github/workflows/live-smoke.yml` runs a cloud smoke test with private dependency access and GCP authentication; `.github/workflows/release.yml` validates release tags ([ADR 7](../adr/0007-publish-immutable-nix-releases-from-validated-tags.md): CI validates an existing tag, never creates one, and never operates a cluster). This plan adds a cluster-operating job, so it must stay within ADR 7's intent: it operates only a disposable cluster inside the job's own Docker and never a real context.

k3d runs Kubernetes (k3s) nodes as Docker containers. Docker-in-Docker means running a Docker daemon inside the CI job so k3d can create those containers. The full local platform did not fit a four-GiB Colima VM; a six-CPU, twelve-GiB profile worked (`docs/plans/155-prove-local-application-and-data-recovery-end-to-end.md`, Surprises). Standard hosted runners for private repositories may be smaller than that, so runner sizing is a real constraint: a larger hosted runner or a self-hosted runner may be required.

The acceptance needs images that are not public: the auth images (`en`, `shomei`, `nagare-access`) come from private repositories, and the local MinIO images are built from upstream release binaries by `scripts/publish-local-minio-images.sh`. `live-smoke.yml` shows how this repository already configures private dependency access in CI. The runner platform is `linux/amd64`, so the local context's target platform must be `linux/amd64` in CI (it is `linux/arm64` on Apple Silicon workstations).

Private evidence (store exports, escrow, credentials) must never be uploaded. EP-168 writes it under `<root>/evidence-private/`; only `<root>/evidence/` is public.


## Plan of Work

M1: add `.github/workflows/local-acceptance.yml` with a manual dispatch input for the candidate revision and a trigger on candidate tags. The job checks out the repository, installs Nix, builds `.#nagare` for the revision, starts Docker-in-Docker or uses the runner's Docker, prepares the images (pulling private images with the existing private-access step, building MinIO images with the existing script), and runs EP-168's bootstrap stage. Measure peak memory and duration and record them here; choose the runner size from that measurement.

M2: run the whole script, then upload `<root>/evidence/` as the workflow artifact after a scan that fails the job if any file contains a private marker (reuse the sensitive-key scan the release gate applies). Make the job fail on any script stop, and keep the cluster logs as a separate artifact for diagnosis.


## Concrete Steps

```bash
gh workflow run local-acceptance.yml -f revision=<candidate-revision>
gh run watch
gh run download <run-id> -n local-acceptance-evidence
```

Expected: the downloaded `local-health.json` reports the required assertions and `inventory-evidence.json` is present.


## Validation and Acceptance

A green run on the then-current candidate whose artifact passes `scripts/scenario-assertions.py finalize --mode local` and the assembler, and contains no private export, escrow or credential file. A run with a deliberately broken candidate (for example, a fixture change that makes the collision check pass incorrectly) must fail the job.


## Idempotence and Recovery

Each run uses a fresh runner and a fresh cluster, so reruns are independent. The job never touches a real context or cloud project.


## Interfaces and Dependencies

Hard dependency: EP-168 complete (`scripts/run-local-acceptance.sh` and its output layout). Soft dependency: [EP-171](171-move-release-tooling-out-of-the-platform-payload.md), so the job can check out harness tooling at the harness revision while building the payload from the candidate revision.
