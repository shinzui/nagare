---
id: 86
slug: local-smoke-test-parity-and-developer-documentation-for-nagare
title: "Local smoke test parity and developer documentation for nagare"
kind: exec-plan
created_at: 2026-06-30T00:56:39Z
intention: "intention_01kwb012h6ebgs5qjn5r12nyda"
master_plan: "docs/masterplans/16-local-development-and-testing-for-nagare.md"
---

# Local smoke test parity and developer documentation for nagare

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Today the only way to prove that nagare's core end-to-end story still works — deploy an app,
write durable data into a volume, snapshot that volume to object storage, restore it, and confirm
the app serves HTTP 200 — is to run `just smoke` (`scripts/live-smoke.sh`) against the **live
billable cloud**: it starts the `nagare-01` GCE virtual machine, tunnels into the cluster over
Google's Identity-Aware Proxy (IAP), pushes an image to a private Artifact Registry, and snapshots
the volume into a Google Cloud Storage (GCS) bucket. That is slow, costs money, requires a GCP
account and credentials, and cannot run on a laptop or in an offline CI job.

After this ExecPlan, an operator who has only **Docker and the project's Nix dev shell** can run a
single command, `just local-smoke`, and watch the *same* scenario execute entirely on their own
machine with **zero cloud dependencies**: no `gcloud`, no IAP tunnel, no Artifact Registry, no GCS.
The app is the shipped `cluster/examples/uploads-volume` example; it is deployed with `nagarectl
deploy` to a local [k3d](https://k3d.io/) cluster (k3s packaged to run inside Docker, stood up by
sibling plan EP-82); a sentinel file is written into its durable `/uploads` volume; the volume is
snapshotted and then deleted-and-restored through a local [MinIO](https://min.io/) S3-compatible
object store instead of GCS (sibling plan EP-84); and the app is confirmed to answer HTTP 200 at a
loopback-resolving hostname such as `http://uploads-volume.127-0-0-1.sslip.io`. A teardown trap
removes everything on exit. The user-visible win: the platform's most important regression path can
be exercised on any developer machine in minutes, and a new contributor gets a single runbook
(`docs/user/local-development.md`) that walks the whole local workflow from `just local-up` to
`just local-down`.

This plan writes **no Haskell**. It is shell (`scripts/local-smoke.sh`), a `justfile` recipe
(`just local-smoke`), and Markdown (one new runbook plus three small reconciliation edits to
existing docs). Its acceptance is purely behavioral: on a clean machine with only Docker and the
dev shell, `just local-smoke` exits 0, having proven `nagarectl deploy` + volume snapshot/restore +
HTTP 200 locally.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1.1: `scripts/local-smoke.sh` created — sets `NAGARE_MODE=local`, sources
  `scripts/lib/target.sh`, and ensures the EP-82 local cluster is up (via `just local-up` /
  `just local-bootstrap` if `kubectl get nodes` against the local context fails).
- [ ] M1.2: `scripts/local-smoke.sh` resolves a runnable `nagarectl` (PATH or `cabal build`) and
  installs a teardown `trap cleanup EXIT` that deletes the app and the local snapshot object.
- [ ] M1.3: `scripts/local-smoke.sh` deploys `cluster/examples/uploads-volume` with `nagarectl
  deploy`, writes a sentinel into the `/uploads` volume, and reads it back.
- [ ] M1.4: `scripts/local-smoke.sh` runs `nagarectl storage snapshot` then deletes the live data
  and `nagarectl storage restore`, confirming the sentinel round-trips through local MinIO.
- [ ] M1.5: `scripts/local-smoke.sh` verifies HTTP 200 at `http://uploads-volume.${NAGARE_BASE_DOMAIN}`
  and prints `local smoke: OK`; `just local-smoke` recipe added to the `[group('test')]` block of
  `justfile`.
- [ ] M1.6: `just local-smoke` exits 0 end-to-end on a machine with only Docker + the dev shell
  (the acceptance), with no `gcloud`/IAP/GCS calls; transcript captured in Outcomes.
- [ ] M2.1: `docs/user/local-development.md` written — prerequisites, the `local-up` →
  `local-bootstrap` → local mode → `nagarectl deploy` → managed DB → snapshot/restore → optional
  auth plane → `just local-smoke` → `just local-down` workflow, cross-referencing EP-82..EP-85.
- [ ] M2.2: `docs/user/local-development.md` troubleshooting section (image won't pull; app 404;
  WebAuthn blocked) added.
- [ ] M3.1: "Running nagare locally" pointer added to `README.md` and `docs/user/getting-started.md`.
- [ ] M3.2: `CLAUDE.md` note added that `NAGARE_MODE=local` is a supported testing path that bypasses
  the GCP guardrail by design; CI-deferral noted as a future option in the runbook.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Ship a **separate `scripts/local-smoke.sh`** that mirrors `scripts/live-smoke.sh`, rather
  than adding a `--local` flag to `live-smoke.sh` and branching it internally.
  Rationale: the two scripts agree on the *scenario* (deploy → sentinel → snapshot → restore →
  HTTP 200 → teardown) but disagree on **every substrate primitive** — cluster access (IAP tunnel +
  `scripts/live-test.sh` vs. a direct local kubeconfig), the guardrail call (`_require_target_project`
  must fail-closed in cloud and short-circuit in local), the registry (private Artifact Registry vs.
  the local registry), the object store (GCS via `gsutil` vs. MinIO), and the reachability trick
  (`curl --resolve … ${PUBLIC_IP}` vs. a loopback domain that already resolves to `127.0.0.1`). A
  single parameterized script would be a thicket of `if [ "$MODE" = local ]` branches in which a bug
  in the cloud path could be introduced by a local-only edit, and vice versa — exactly the
  "cloud vs. laptop ambiguity" MasterPlan 16 set out to avoid. Two small, each-obviously-correct
  scripts that read as parallel columns make the parity auditable and keep the live (billable) path
  untouched by local work. The shared guardrail library `scripts/lib/target.sh` is the one piece both
  source, and EP-82 already makes it mode-aware (Integration Point 6), so there is no duplicated
  safety logic.
  Date: 2026-06-30

- Decision: Reuse the shipped **`cluster/examples/uploads-volume`** example as the smoke app, exactly
  as `scripts/live-smoke.sh` does (`SMOKE_APP=uploads-volume`, `SMOKE_VOL=uploads`,
  `SMOKE_NS=personal`).
  Rationale: it is purpose-built for a snapshot/restore round-trip — a build-mode app with a durable
  `local-path` PVC mounted at `/uploads` and `POST /upload/<name>` / `GET /files/<name>` endpoints
  (`cluster/examples/uploads-volume/app.py`) — and it is already covered by the offline
  `examples-compile` flake check (EP-69), so its `nagare/Config.hs` cannot silently rot. Using the
  identical app the cloud smoke uses makes the two tests a true parity pair: the only difference is
  the substrate, not the workload. A bespoke local-only app would dilute that parity and add an
  untested example.
  Date: 2026-06-30

- Decision: `just local-smoke` is **not wired into CI** in this plan; it is recorded only as a future
  option in the runbook.
  Rationale: the local smoke needs a real Docker daemon to host the k3d cluster and the local
  registry — i.e. Docker-in-Docker (DinD) or a Docker-enabled runner — which the project's current
  offline CI (the hermetic-ish `nix flake check`, EP-69) deliberately does not provide. Mirroring
  EP-69's decision that the *live* smoke is `workflow_dispatch`-only and never on per-PR CI, the local
  smoke stays an on-demand developer command for now. Wiring it to a DinD job is a clean future
  addition (it has no cloud credentials to manage, unlike the live smoke), but it is out of scope here
  so the plan's acceptance stays "runs green on a developer machine," not "runs green in CI."
  Date: 2026-06-30

- Decision: Verify reachability against the host **printed by `nagarectl deploy`** (falling back to
  `http://uploads-volume.${NAGARE_BASE_DOMAIN}`), not a hand-assembled `<app>.<ns>.<domain>` host.
  Rationale: the exact local route host (whether a namespace segment appears) is EP-82/EP-83's to fix
  via the local `config-domain`; treating the deploy output as the source of truth keeps this plan
  correct regardless of how that detail lands, and the loopback wildcard domain
  (`*.127-0-0-1.sslip.io` → `127.0.0.1`) means no `--resolve`/static-IP trick is needed as it is in
  the cloud script.
  Date: 2026-06-30


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

Read this before touching anything; it assumes no prior knowledge of the repository.

**What this plan delivers.** Two runnable artifacts and four documentation edits. The runnable
artifacts are `scripts/local-smoke.sh` (new) and a `just local-smoke` recipe added to `justfile`.
The documentation is a new runbook `docs/user/local-development.md` plus pointers added to
`README.md`, `docs/user/getting-started.md`, and `CLAUDE.md`. Nothing in this plan is Haskell.

**The cloud smoke this mirrors (`scripts/live-smoke.sh`).** Read it; the local script is its column-
for-column twin. The cloud script (header comment "the live end-to-end smoke test"):

1. Sources the guardrail and calls it — `source "${SCRIPT_DIR}/lib/target.sh"` then
   `_require_target_project` (`scripts/live-smoke.sh:20-21`). `_require_target_project` (defined in
   `scripts/lib/target.sh:45-54`) **refuses to run** unless `gcloud`'s active project equals the
   configured `TARGET_PROJECT`. This is the single-project fail-closed guardrail.
2. Pins the smoke app: `SMOKE_APP="uploads-volume"`, `SMOKE_VOL="uploads"`, `SMOKE_NS="personal"`,
   `APP_DIR="${NAGARE_REPO_ROOT}/cluster/examples/${SMOKE_APP}"`, and a unique
   `SENTINEL="smoke-sentinel-$$.txt"` (`live-smoke.sh:26-30`).
3. Builds/resolves a runnable `nagarectl` (`cabal build -v0 exe:nagarectl`, then locates the binary
   under `dist-newstyle`) and defines a `nagarectl()` shell function (`live-smoke.sh:36-39`).
4. Installs a teardown `trap cleanup EXIT` (`live-smoke.sh:44-57`): deletes the app
   (`nagarectl app delete`), best-effort removes the GCS snapshot object (`gsutil rm`), deletes any
   restore-scratch PVC, and kills the IAP tunnels.
5. Step 1: ensures the VM is `RUNNING` via `gcloud … compute instances describe/start`
   (`live-smoke.sh:59-67`).
6. Step 2: stands up cluster access by running `scripts/live-test.sh`, which opens an IAP port-22
   tunnel and an `ssh -L` forward of the k3s API to `127.0.0.1:16443`, then exports the rewritten
   `KUBECONFIG` (`live-smoke.sh:69-78`; `scripts/live-test.sh` whole file).
7. Step 3: `( cd "${APP_DIR}" && nagarectl deploy --file nagare/Config.hs )`, then builds a `curlapp`
   helper that uses `curl --resolve "${HOST}:80:${PUBLIC_IP}"` against
   `HOST="${SMOKE_APP}.${SMOKE_NS}.${NAGARE_BASE_DOMAIN}"` (`live-smoke.sh:80-84`).
8. Step 4: writes a sentinel via `POST /upload/${SENTINEL}`, reads it back, runs `nagarectl storage
   snapshot "${SMOKE_APP}" "${SMOKE_VOL}"` (snapshot URL is a `gs://…` object), then `nagarectl
   storage restore "${SMOKE_APP}" "${SMOKE_VOL}" "${SNAP_ID}"` and greps the restore output for the
   sentinel (`live-smoke.sh:86-107`).
9. Step 5: `curl -o /dev/null -w '%{http_code}'` the app root and asserts `200`
   (`live-smoke.sh:109-117`); Step 6 is the trap. Final line: `echo "live smoke: OK"`.

**What "local mode" is (EP-82, MasterPlan 16).** Local mode is a *second target* for nagare,
selected by the environment variable `NAGARE_MODE=local` (sourced from a git-ignored
`nagare.local.env`, mirroring the existing cloud `nagare.target.env`). It swaps each GCP-backed
primitive for a local equivalent: Artifact Registry → a local registry (`NAGARE_REGISTRY_HOST`, e.g.
`k3d-registry.localhost:5000`); Cloud DNS + DNS-01 TLS → a wildcard loopback domain
(`NAGARE_BASE_DOMAIN`, e.g. `127-0-0-1.sslip.io`, which resolves `*.127-0-0-1.sslip.io` to
`127.0.0.1` with no DNS setup); GCS backups → a local MinIO object store
(`NAGARE_LOCAL_OBJECT_STORE`, an endpoint + bucket); the GCE-VM-on-NixOS substrate → a k3d cluster
in Docker; the IAP-tunnel cluster access → a direct kubeconfig. These variable names are the
**local-target contract** that EP-82 defines (MasterPlan 16, Integration Point 1) and this plan
consumes. The existing cloud path is byte-for-byte unchanged when `NAGARE_MODE` is unset.

**The dependency that makes the guardrail safe in local mode (Integration Point 6).** EP-82 makes
`scripts/lib/target.sh`'s `_require_target_project` **mode-aware**: when `NAGARE_MODE=local` it
short-circuits to success (it is a *GCP* guardrail and there is no GCP project to protect), while the
cloud branch (`NAGARE_MODE` unset/`cloud`) stays fail-closed exactly as today. `scripts/local-smoke.sh`
sources the same library and relies on this short-circuit. This is a **hard dependency**: until
EP-82 lands the mode-aware guardrail, sourcing `target.sh` and calling `_require_target_project` in a
machine with no `gcloud` project would abort. The plan documents this and, until EP-82 lands, the
script can be exercised by setting `NAGARE_MODE=local` and confirming the guardrail steps aside.

**The soft dependencies (EP-83, EP-84, EP-85).** EP-83 makes `nagarectl deploy` GCP-free in local
mode (skips `gcloud auth configure-docker`, pushes to the local registry, builds for the host
architecture, serves on the loopback base domain) — without it the deploy step cannot run locally.
EP-84 generalizes the one data-movement Job renderer (`cli/nagarectl/src/Nagare/Cluster/GcsJob.hs`)
so `storage snapshot`/`storage restore` target MinIO instead of GCS in local mode (Integration
Point 3) — without it the snapshot/restore step cannot round-trip locally. EP-85 (the auth plane +
local TLS) is referenced only by the runbook's "optional auth plane" section; the smoke test itself
deploys an unauthenticated app over plain HTTP, so EP-85 is not on the smoke's critical path. These
are *soft* dependencies: this plan's prose and harness can be drafted before they land, but the
green end-to-end run requires EP-83 and EP-84.

**The justfile recipes this plan touches and relies on.** `justfile` groups recipes with
`[group('…')]` attributes. The relevant block is `[group('test')]`, currently holding `live-test`
(`scripts/live-test.sh`) and `smoke` (`scripts/live-smoke.sh`) (`justfile:143-155`). This plan adds
`local-smoke:` to that group as a thin wrapper around `scripts/local-smoke.sh`. The recipes
`just local-up`, `just local-down`, and `just local-bootstrap` are **owned by EP-82**; this plan
*calls* them (from the script and the runbook) but does not define them.

**The docs surface.** Operator docs live under `docs/user/` (e.g. `getting-started.md`,
`troubleshooting.md`, `managed-databases.md`, `persistent-storage.md`). The new runbook
`docs/user/local-development.md` joins them. `docs/user/getting-started.md` is the workstation-setup
entry point; `README.md` is the repo front door; `CLAUDE.md` carries the project's operating rules,
including the single-project GCP isolation policy whose text must stay coherent once a deliberate
local bypass exists.


## Plan of Work

Three milestones. **M1** builds the local smoke script and its `just` recipe — the load-bearing
deliverable. **M2** writes the operator runbook. **M3** reconciles the existing docs so the new local
path is discoverable and the isolation policy stays coherent. M1 is independently verifiable (run
`just local-smoke`); M2 and M3 are prose and verified by review plus link-checking.


### Milestone M1 — `scripts/local-smoke.sh` + `just local-smoke`

**Scope.** Create `scripts/local-smoke.sh`, the local analogue of `scripts/live-smoke.sh`, and add a
`local-smoke` recipe to the `[group('test')]` block of `justfile`. At the end, a developer with only
Docker and the dev shell runs `just local-smoke` and watches deploy → sentinel → snapshot → restore →
HTTP 200 → teardown, all locally, exiting 0 with `local smoke: OK`.

**What the script does, contrasted with the cloud script.** Each step names its `live-smoke.sh`
counterpart so the parity is explicit:

1. **Guardrail (vs. `live-smoke.sh:20-21`).** Source `scripts/lib/target.sh`, `export
   NAGARE_MODE=local` *before* the guardrail call, then call `_require_target_project`. In the cloud
   script this asserts the active GCP project; here, EP-82's mode-aware guardrail **short-circuits to
   success** because there is no GCP project. No `gcloud`, ever.
2. **Pin the smoke app (identical to `live-smoke.sh:26-30`).** `SMOKE_APP="uploads-volume"`,
   `SMOKE_VOL="uploads"`, `SMOKE_NS="personal"`,
   `APP_DIR="${NAGARE_REPO_ROOT}/cluster/examples/${SMOKE_APP}"`,
   `SENTINEL="smoke-sentinel-$$.txt"`.
3. **Resolve `nagarectl` (identical to `live-smoke.sh:36-39`).** Prefer one on `PATH`, else
   `cabal build -v0 exe:nagarectl` and locate the binary; define a `nagarectl()` function.
4. **Teardown trap (vs. `live-smoke.sh:44-57`).** `trap cleanup EXIT`, where `cleanup` runs
   `nagarectl app delete "${SMOKE_APP}" --yes` and best-effort removes the **local MinIO** snapshot
   object (via `nagarectl storage` cleanup or `mc rm`, whichever EP-84 exposes) and any
   restore-scratch PVC. It does **not** kill IAP tunnels (there are none).
5. **Ensure the local cluster is up (vs. cloud Step 1+2, `live-smoke.sh:59-78`).** Where the cloud
   script starts the VM and opens an IAP tunnel, the local script checks `kubectl get nodes` against
   the local k3d context and, if it fails, runs `just local-up` then `just local-bootstrap` (EP-82).
   The kubeconfig is the direct k3d one — no `scripts/live-test.sh`, no tunnel, no `ssh -L`.
6. **Deploy (vs. `live-smoke.sh:80-84`).** `( cd "${APP_DIR}" && nagarectl deploy --file
   nagare/Config.hs )`. EP-83 makes this build for the host arch, push to the local registry, and
   serve on the loopback domain. Capture the host from the deploy output; fall back to
   `HOST="uploads-volume.${NAGARE_BASE_DOMAIN}"`. The `curlapp` helper is a plain
   `curl -sS "http://${HOST}…"` — **no `--resolve`/`${PUBLIC_IP}`**, because `*.${NAGARE_BASE_DOMAIN}`
   already resolves to `127.0.0.1`.
7. **Sentinel + snapshot/restore (vs. `live-smoke.sh:86-107`).** `POST /upload/${SENTINEL}` with a
   known body; read it back; `nagarectl storage snapshot "${SMOKE_APP}" "${SMOKE_VOL}"` (the snapshot
   lands in **local MinIO**, not GCS — EP-84). Then, to prove a true round-trip, **delete the live
   data** (re-`POST` an empty body to the sentinel, or delete via the app) and run `nagarectl storage
   restore "${SMOKE_APP}" "${SMOKE_VOL}" "${SNAP_ID}"`; grep the restore output (and/or re-read the
   file through the app) for the sentinel content. Fail loudly if absent.
8. **HTTP 200 (vs. `live-smoke.sh:109-117`).** `curl -o /dev/null -w '%{http_code}' "http://${HOST}/"`,
   assert `200`. Final line `echo "local smoke: OK"`.

**The `just local-smoke` recipe.** Append to the `[group('test')]` block in `justfile`, a thin
wrapper consistent with `live-test` and `smoke`:

```text
# EP-86 (docs/plans/86): LOCAL smoke test — the cloud `smoke`'s zero-cloud twin.
# Assumes the EP-82 local cluster (just local-up + local-bootstrap); sets
# NAGARE_MODE=local so the GCP guardrail steps aside, deploys uploads-volume,
# round-trips a volume snapshot through local MinIO, verifies HTTP 200, and
# tears down. NO gcloud / IAP / GCS. Needs only Docker + the dev shell.
[group('test')]
local-smoke:
    scripts/local-smoke.sh
```

**Acceptance for M1.** On a machine with Docker running and the dev shell entered, `just local-smoke`
exits 0 and prints `local smoke: OK`; `nagarectl app list` (local context) shows no `uploads-volume`
afterward and the MinIO snapshot object is gone (teardown ran). No `gcloud`, `gsutil`, IAP, or GCS
call appears in the run (grep the transcript). Re-running is safe (idempotent; see that section).


### Milestone M2 — `docs/user/local-development.md`

**Scope.** Write the operator runbook for the entire local workflow, the local-mode counterpart to
`docs/user/getting-started.md`. At the end, a contributor can go from a fresh checkout to a green
`just local-smoke` and back down using only this page.

**What it contains (prose-first, with fenced command blocks).**

- **Prerequisites.** Docker (a running daemon — the k3d cluster and local registry are containers);
  the Nix dev shell (`nix develop` / `direnv allow`), which already ships `kubectl`, `just`,
  `nagarectl`'s toolchain, and adds k3d/MinIO client tooling per EP-82; and a note that no GCP account
  or `gcloud` login is needed.
- **Stand up the substrate.** `just local-up` (creates the k3d cluster + local registry, EP-82) →
  `just local-bootstrap` (installs Knative + Kourier HTTP-first, EP-82, Integration Point 4).
- **Enter local mode.** Copy `nagare.local.env.example` → `nagare.local.env` and/or `export
  NAGARE_MODE=local`; explain the local-target contract variables (`NAGARE_REGISTRY_HOST`,
  `NAGARE_BASE_DOMAIN`, `NAGARE_TARGET_PLATFORM`, `NAGARE_LOCAL_OBJECT_STORE`) and the precedence
  (environment > profile > default), cross-referencing EP-82.
- **Deploy an app.** `nagarectl deploy` from an example dir; the image builds for the host arch and
  pushes to the local registry; the app is reachable at `http://<app>.${NAGARE_BASE_DOMAIN}` with no
  DNS setup (EP-83).
- **Managed database.** `nagarectl db create postgres …` runs an in-cluster Postgres StatefulSet on
  the local cluster (EP-84); cross-reference `docs/user/managed-databases.md`.
- **Snapshot / restore.** `nagarectl storage snapshot` / `nagarectl storage restore` round-trip
  through local MinIO instead of GCS (EP-84, Integration Point 3); cross-reference
  `docs/user/persistent-storage.md`.
- **Optional auth plane.** Standing up Shomei + en + nagare-access locally behind locally-trusted TLS
  for "require login" apps, and trusting the local CA (EP-85, Integration Point 5). Mark it optional —
  the smoke test does not need it.
- **Run the smoke test.** `just local-smoke` — what it proves and how to read its transcript.
- **Tear down.** `just local-down` (destroys the k3d cluster, EP-82).
- **Troubleshooting** (a dedicated subsection, mirroring `docs/user/troubleshooting.md`'s style):
  - *Image won't pull* (`ImagePullBackOff`): the local registry hostname must resolve identically from
    the host doing `docker push` and from in-cluster containerd; check the `NAGARE_REGISTRY_HOST`
    value and the `/etc/hosts` / k3d registry-alias setup EP-82 documents.
  - *App returns 404*: the Knative `config-domain` (set from `NAGARE_BASE_DOMAIN` by EP-82's local
    bootstrap) does not match the host you are curling; confirm the deploy-printed URL and that
    `*.${NAGARE_BASE_DOMAIN}` resolves to `127.0.0.1`.
  - *WebAuthn / login blocked*: the local CA is not trusted by your browser/OS, so the secure-context
    requirement fails on the non-`localhost` loopback domain; trust the EP-85 local CA (mkcert/
    self-signed issuer). Applies only to the optional auth plane.

**Acceptance for M2.** The page exists, every internal link resolves, and following it on a clean
machine produces a green `just local-smoke`. Reviewer can navigate fresh-checkout → smoke → teardown
using only this page.


### Milestone M3 — Reconcile existing docs

**Scope.** Make the local path discoverable from the front door and keep the isolation policy text
coherent now that a deliberate local bypass exists. Three small edits.

- **`README.md`.** Add a short "Running nagare locally" pointer (a sentence or two plus a link to
  `docs/user/local-development.md`), near the deploy/usage material, noting that local mode runs the
  full platform with no GCP account for testing.
- **`docs/user/getting-started.md`.** Add a brief "Running nagare locally" note (the cloud setup page
  currently ends at "Provisioning with Pulumi"); point to `docs/user/local-development.md` as the
  no-cloud alternative for testing use cases.
- **`CLAUDE.md`.** Add a note under the GCP-project-isolation section that **`NAGARE_MODE=local` is a
  supported testing path that bypasses the GCP guardrail by design** — local mode points at loopback
  substitutes, has no GCP project to protect, so `_require_target_project` stepping aside in local
  mode does **not** weaken the fail-closed cloud guarantee (which remains in force when `NAGARE_MODE`
  is unset/`cloud`). This keeps the single-project isolation policy internally consistent. Optionally
  note in the runbook that `just local-smoke` *could* later join CI via a Docker-in-Docker job (future
  option; not wired here — see the CI-deferral Decision).

**Acceptance for M3.** `README.md` and `docs/user/getting-started.md` each link to the new runbook;
`CLAUDE.md`'s isolation section explicitly blesses local mode as a guardrail-bypassing-by-design test
path without contradicting the fail-closed cloud policy. A reader who only knew the cloud isolation
rule comes away understanding why local mode is allowed to step aside.


## Concrete Steps

Run everything from the repository root `/Users/shinzui/Keikaku/bokuno/nagare` inside the dev shell
(`nix develop`, or `direnv allow` once). Docker must be running.

**M1 — author the script and recipe.**

```bash
# 1. Create the local smoke script (mirror scripts/live-smoke.sh; see Plan of Work M1).
$EDITOR scripts/local-smoke.sh
chmod +x scripts/local-smoke.sh

# 2. Add the recipe to justfile's [group('test')] block (next to `smoke`).
$EDITOR justfile

# 3. Run it. With the EP-82 cluster down, the script stands it up first.
just local-smoke
```

A representative skeleton for `scripts/local-smoke.sh` (fill in per the milestone; the cloud
`scripts/live-smoke.sh` is the column-for-column reference):

```bash
#!/usr/bin/env bash
# scripts/local-smoke.sh (EP-86, MasterPlan 16) — the LOCAL end-to-end smoke test.
#
# The zero-cloud twin of scripts/live-smoke.sh: same scenario (deploy ->
# sentinel -> snapshot -> restore -> HTTP 200 -> teardown), but against the
# EP-82 k3d cluster + local registry, with snapshots round-tripping through
# the local MinIO object store (EP-84) instead of GCS. NO gcloud, IAP, or GCS.
#
# Local mode (NAGARE_MODE=local) makes scripts/lib/target.sh's GCP guardrail
# short-circuit (Integration Point 6): there is no GCP project to protect.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export NAGARE_MODE=local                 # <-- set BEFORE sourcing the guardrail
# shellcheck source=scripts/lib/target.sh
source "${SCRIPT_DIR}/lib/target.sh"
_require_target_project                  # short-circuits in local mode (EP-82)

SMOKE_APP="uploads-volume"; SMOKE_VOL="uploads"; SMOKE_NS="personal"
APP_DIR="${NAGARE_REPO_ROOT}/cluster/examples/${SMOKE_APP}"
SENTINEL="smoke-sentinel-$$.txt"

echo "== building nagarectl =="
( cd "${NAGARE_REPO_ROOT}/cli/nagarectl" && cabal build -v0 exe:nagarectl )
NAGARECTL_BIN="$(ls "${NAGARE_REPO_ROOT}"/cli/nagarectl/dist-newstyle/build/*/ghc-*/nagarectl-*/x/nagarectl/build/nagarectl/nagarectl | head -1)"
nagarectl() { "${NAGARECTL_BIN}" "$@"; }

SNAP_ID=""
cleanup() {
  echo "== teardown =="
  nagarectl app delete "${SMOKE_APP}" --yes >/dev/null 2>&1 || true
  # Best-effort: drop the local MinIO snapshot + any restore-scratch PVC.
  [ -n "${SNAP_ID}" ] && nagarectl storage delete "${SMOKE_APP}" "${SMOKE_VOL}" "${SNAP_ID}" >/dev/null 2>&1 || true
  kubectl -n "${SMOKE_NS}" delete pvc -l nagare.dev/restore-scratch=true >/dev/null 2>&1 || true
  echo "== teardown done =="
}
trap cleanup EXIT

# Step 1 (vs. cloud Step 1+2): ensure the LOCAL cluster is up — NO VM, NO IAP.
echo "== step 1: ensure the local k3d cluster is up =="
if ! kubectl get nodes >/dev/null 2>&1; then
  ( cd "${NAGARE_REPO_ROOT}" && just local-up && just local-bootstrap )
fi
kubectl get nodes >/dev/null

# Step 2 (vs. cloud Step 3): deploy on the local cluster.
echo "== step 2: nagarectl deploy ${SMOKE_APP} (host-arch build -> local registry) =="
deploy_out="$( cd "${APP_DIR}" && nagarectl deploy --file nagare/Config.hs )"
echo "${deploy_out}"
HOST="$(echo "${deploy_out}" | sed -n 's#^Deployed: https\{0,1\}://##p' | head -1)"
HOST="${HOST:-uploads-volume.${NAGARE_BASE_DOMAIN}}"
# Loopback domain resolves to 127.0.0.1 already: no --resolve / PUBLIC_IP needed.
curlapp() { curl -sS "$@"; }

# Step 3 (vs. cloud Step 4): sentinel + snapshot + delete + restore via MinIO.
echo "== step 3a: write a sentinel into the volume =="
curlapp -X POST --data "smoke ok $$" "http://${HOST}/upload/${SENTINEL}" >/dev/null
echo "  read back: $(curlapp "http://${HOST}/files/${SENTINEL}")"

echo "== step 3b: snapshot the volume to local MinIO =="
snap_out="$(nagarectl storage snapshot "${SMOKE_APP}" "${SMOKE_VOL}" --config "${APP_DIR}/nagare/Config.hs")"
echo "${snap_out}"
SNAP_ID="$(echo "${snap_out}" | sed -n 's/^Snapshot written: //p' | head -1 | xargs basename 2>/dev/null | sed 's/\.tar\.gz$//')"

echo "== step 3c: delete the live data, then restore + confirm the sentinel round-trips =="
curlapp -X POST --data "" "http://${HOST}/upload/${SENTINEL}" >/dev/null   # clobber the live copy
restore_out="$(nagarectl storage restore "${SMOKE_APP}" "${SMOKE_VOL}" "${SNAP_ID}" --config "${APP_DIR}/nagare/Config.hs")"
echo "${restore_out}"
echo "${restore_out}" | grep -q "${SENTINEL}" || { echo "  RESTORE FAILED: ${SENTINEL} absent" >&2; exit 1; }
echo "  RESTORE OK: sentinel ${SENTINEL} present in the restored tree"

# Step 4 (vs. cloud Step 5): verify HTTP 200 — plain loopback, no gateway IP trick.
echo "== step 4: verify HTTP 200 =="
code="$(curlapp -o /dev/null -w '%{http_code}' "http://${HOST}/")"
[ "${code}" = "200" ] || { echo "  expected 200, got ${code}" >&2; exit 1; }
echo "  HTTP ${code} OK"

echo "local smoke: OK"
```

The exact `nagarectl storage` flags follow the cloud script's usage (`deploy` takes the config via
`--file`/`-f`; `storage snapshot`/`storage restore` take it via `--config`/`-f`); EP-84 owns the
final local-mode behavior of those verbs and the snapshot/delete helper names — adapt the helper
calls to whatever EP-84 ships and record any drift in Surprises.

**Expected `just local-smoke` transcript** (illustrative; the host and ids vary):

```text
== building nagarectl ==
== step 1: ensure the local k3d cluster is up ==
== step 2: nagarectl deploy uploads-volume (host-arch build -> local registry) ==
  ... pushed k3d-registry.localhost:5000/uploads-volume:20260630-...
  service.serving.knative.dev/uploads-volume condition met
  Deployed: http://uploads-volume.127-0-0-1.sslip.io
== step 3a: write a sentinel into the volume ==
  read back: smoke ok 48217
== step 3b: snapshot the volume to local MinIO ==
  Snapshot written: s3://nagare-local-backups/volumes/uploads-volume/uploads/20260630T101501Z.tar.gz
== step 3c: delete the live data, then restore + confirm the sentinel round-trips ==
  /restore/smoke-sentinel-48217.txt
  RESTORE OK: sentinel smoke-sentinel-48217.txt present in the restored tree
== step 4: verify HTTP 200 ==
  HTTP 200 OK
== teardown ==
== teardown done ==
local smoke: OK
```

**M2 — write the runbook.**

```bash
$EDITOR docs/user/local-development.md   # per Plan of Work M2 (prerequisites … troubleshooting).
```

**M3 — reconcile the existing docs.**

```bash
$EDITOR README.md                        # add a "Running nagare locally" pointer.
$EDITOR docs/user/getting-started.md     # add a "Running nagare locally" note + link.
$EDITOR CLAUDE.md                        # bless NAGARE_MODE=local as a by-design guardrail bypass.
```

**Commit.** Use Conventional Commit subjects with the standard trailers. Suggested split:

```text
test(smoke): add local-smoke parity test and just recipe

Mirror scripts/live-smoke.sh with a zero-cloud local run: NAGARE_MODE=local,
k3d cluster, local registry, MinIO snapshot/restore, HTTP 200, teardown trap.

MasterPlan: docs/masterplans/16-local-development-and-testing-for-nagare.md
ExecPlan: docs/plans/86-local-smoke-test-parity-and-developer-documentation-for-nagare.md
Intention: intention_01kwb012h6ebgs5qjn5r12nyda
```

```text
docs(local): add local-development runbook and reconcile README/getting-started/CLAUDE

MasterPlan: docs/masterplans/16-local-development-and-testing-for-nagare.md
ExecPlan: docs/plans/86-local-smoke-test-parity-and-developer-documentation-for-nagare.md
Intention: intention_01kwb012h6ebgs5qjn5r12nyda
```


## Validation and Acceptance

The change is effective beyond authoring when all of the following hold:

- **Zero-cloud end-to-end.** On a machine with Docker running and the dev shell entered — and with
  **no** `gcloud` login, no `nagare.target.env`, and `NAGARE_MODE=local` — `just local-smoke` exits 0
  and prints `local smoke: OK`. The transcript shows: deploy to the local registry, a sentinel
  written and read back, a snapshot to local MinIO (an `s3://`/MinIO URL, **not** `gs://`), a restore
  that surfaces the sentinel, and `HTTP 200 OK`.
- **No cloud calls.** Grepping the run's transcript and the script source for `gcloud`, `gsutil`,
  `gs://`, `start-iap-tunnel`, or `scripts/live-test.sh` returns nothing — the local path uses the k3d
  kubeconfig and MinIO only.
- **Guardrail steps aside, safely.** With `NAGARE_MODE=local` the script's `_require_target_project`
  succeeds with no GCP project configured; with `NAGARE_MODE` unset, the same library call still
  fail-closes (run `bash -c 'source scripts/lib/target.sh; _require_target_project'` with no project
  and observe the refusal) — proving local mode did not weaken the cloud guard.
- **Teardown always runs.** After a successful run, `nagarectl app list` (local context) shows no
  `uploads-volume`, no restore-scratch PVC remains, and the MinIO snapshot object is gone. Interrupt
  the script mid-run (Ctrl-C) and confirm the `== teardown ==` block still executes (the `EXIT` trap).
- **Docs are navigable and correct.** `docs/user/local-development.md` exists; `README.md` and
  `docs/user/getting-started.md` link to it; `CLAUDE.md`'s isolation section blesses local mode
  without contradiction. Following the runbook on a clean machine yields a green `just local-smoke`.

There are no unit tests in this plan; acceptance is the behavioral run above. The smoke app's
`cluster/examples/uploads-volume/nagare/Config.hs` continues to be guarded by EP-69's offline
`examples-compile` flake check, so the workload cannot rot independently.


## Idempotence and Recovery

`just local-smoke` is designed to be re-runnable. Re-deploying `uploads-volume` overwrites the prior
Knative Service (deploy is declarative apply); the `SENTINEL` filename embeds the shell PID (`$$`) so
parallel or repeated runs do not collide; and the snapshot/restore verbs operate on named objects, so
a repeat run creates a fresh snapshot id rather than corrupting an old one.

The **teardown `trap cleanup EXIT`** is the primary recovery mechanism and is mandatory (mirroring
`scripts/live-smoke.sh`'s `cleanup`): it deletes the app, best-effort removes the local MinIO snapshot
object, and deletes any restore-scratch PVC — and it runs on *every* exit, including failures and
Ctrl-C. If a run is killed so hard the trap does not fire (`kill -9`), recovery is to re-run
`just local-smoke` (it reaches teardown) or to manually `nagarectl app delete uploads-volume --yes`
and remove the snapshot. Because every side effect is local (containers, a k3d cluster, a MinIO
bucket), the ultimate reset is `just local-down` (destroy the cluster, EP-82) followed by
`just local-up` — nothing billable or cloud-resident is ever touched, so there is no destructive cloud
path to guard against.

The cluster-bring-up step is itself idempotent: the script only runs `just local-up` /
`just local-bootstrap` when `kubectl get nodes` against the local context fails, so a run against an
already-up cluster skips bring-up. The documentation edits (M2/M3) are additive Markdown and carry no
runtime risk.


## Interfaces and Dependencies

**Artifacts created or edited by this plan.**

- `scripts/local-smoke.sh` — new; the local end-to-end smoke orchestration (shell).
- `justfile` — add a `local-smoke:` recipe to the `[group('test')]` block.
- `docs/user/local-development.md` — new; the local-workflow operator runbook.
- `README.md`, `docs/user/getting-started.md` — add a "Running nagare locally" pointer.
- `CLAUDE.md` — note that `NAGARE_MODE=local` bypasses the GCP guardrail by design.

**Tools and services used (and why).**

- **`scripts/lib/target.sh`** — sourced for `NAGARE_REPO_ROOT`, the contract variables, and the
  mode-aware `_require_target_project`. The one shared safety library; EP-82 makes it short-circuit in
  local mode (Integration Point 6).
- **`just`** (`just local-up` / `just local-bootstrap` / `just local-down`) — EP-82's local cluster
  lifecycle recipes that this plan calls but does not define.
- **`nagarectl`** (`deploy`, `app delete`, `storage snapshot`/`restore`/`delete`) — the CLI under
  test; EP-83 makes `deploy` GCP-free in local mode, EP-84 makes `storage` target MinIO.
- **`kubectl`** — to check cluster readiness and clean up restore-scratch PVCs via the local k3d
  kubeconfig (no IAP).
- **`curl`** — to write/read the sentinel and assert HTTP 200 against the loopback domain.
- **Docker + k3d + MinIO** — the local substrate (containers), owned by EP-82/EP-84; this plan
  requires only that they are present and running.

**Contract this plan CONSUMES and does NOT define** (MasterPlan 16 Integration Points):

- **Integration Point 1 (EP-82):** the local-target contract variables `NAGARE_MODE`,
  `NAGARE_REGISTRY_HOST`, `NAGARE_BASE_DOMAIN`, `NAGARE_TARGET_PLATFORM`, `NAGARE_LOCAL_OBJECT_STORE`.
- **Integration Point 6 (EP-82, HARD dep):** the mode-aware `_require_target_project` that
  short-circuits in local mode while staying fail-closed in cloud mode. Without this, the script's
  guardrail call aborts on a GCP-less machine.
- **Integration Point 2 (EP-83, SOFT dep):** local-mode build/push/deploy (no `gcloud auth
  configure-docker`, local registry, host-arch platform, loopback domain). Required for the deploy
  step to run locally.
- **Integration Point 3 (EP-84, SOFT dep):** `Nagare.Cluster.GcsJob` rendering a MinIO Job in local
  mode, so `storage snapshot`/`storage restore` round-trip without GCS. Required for the
  snapshot/restore step.
- **Integration Points 4 & 5 (EP-82/EP-85):** the local Knative/Kourier bootstrap and the local TLS
  issuer — consumed only by the runbook's bootstrap and optional-auth-plane sections, not by the smoke
  test's critical path.

**Outputs that must exist at the end of each milestone.**

- End of **M1**: `scripts/local-smoke.sh` (executable) and a `just local-smoke` recipe; running it on
  a Docker+dev-shell machine performs deploy → snapshot → restore → HTTP 200 → teardown and prints
  `local smoke: OK`, with no cloud calls.
- End of **M2**: `docs/user/local-development.md` documents prerequisites through teardown with a
  troubleshooting section, cross-referencing EP-82..EP-85.
- End of **M3**: `README.md` and `docs/user/getting-started.md` link to the runbook; `CLAUDE.md`'s
  isolation policy explicitly permits the local-mode guardrail bypass without weakening the cloud
  fail-closed guarantee.


## Revision Note

2026-06-30 — Initial authoring (fleshed out from the skeleton). Researched the cloud smoke
(`scripts/live-smoke.sh`) and its harness (`scripts/live-test.sh`), the shared guardrail
(`scripts/lib/target.sh:45-54`), the `[group('test')]` recipes in `justfile`, the smoke app
(`cluster/examples/uploads-volume/`), and the existing operator docs (`docs/user/getting-started.md`,
`README.md`, `CLAUDE.md`). Recorded the four design decisions (separate `local-smoke.sh` vs.
parameterizing `live-smoke.sh`; reuse `uploads-volume`; defer CI to a future DinD job; trust the
deploy-printed host) and mapped each step of the local script to its `live-smoke.sh` counterpart so
the parity is auditable. Embedded the MasterPlan 16 Integration Points this plan consumes — hard on
EP-82's mode-aware guardrail (Integration Point 6), soft on EP-83 (deploy) and EP-84 (MinIO
snapshot/restore). Why: to give a novice a fully self-contained path to a zero-cloud end-to-end
regression test plus the local-development runbook, closing the "can't test nagare on a laptop" gap
MasterPlan 16 set out to close.
