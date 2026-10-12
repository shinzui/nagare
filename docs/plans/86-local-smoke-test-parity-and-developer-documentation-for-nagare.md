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

Full plan before trimming: [86-local-smoke-test-parity-and-developer-documentation-for-nagare.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/86-local-smoke-test-parity-and-developer-documentation-for-nagare.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

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

- [x] M1.1: `scripts/local-smoke.sh` created — exports `NAGARE_MODE=local`, sources
  `scripts/lib/target.sh` (and fills the local-target contract vars from `nagare.local.env`/the
  example when unset), and ensures the EP-82 cluster is up — guarding on `k3d cluster list
  nagare-local` and running `just local-up` + `local-bootstrap` + `local-minio` if absent. (Done
  2026-06-30.)
- [x] M1.2: `scripts/local-smoke.sh` resolves a runnable `nagarectl` (`cabal build` + locate binary)
  and installs a teardown `trap cleanup EXIT` that deletes the app (`app delete NAME -n NS` — there
  is no `--yes` flag), best-effort removes the MinIO snapshot object (a throwaway `minio/mc` pod —
  there is no `storage delete` verb), the restore-scratch PVC, and the Kourier port-forward. (Done
  2026-06-30.)
- [x] M1.3: `scripts/local-smoke.sh` deploys `cluster/examples/uploads-volume` with `nagarectl
  deploy`, writes a sentinel into the `/uploads` volume, and reads it back — through a Kourier
  port-forward + `Host:` header (robust to a host proxy on :80/:443). (Done 2026-06-30.)
- [x] M1.4: `scripts/local-smoke.sh` runs `nagarectl storage snapshot` (asserts an `s3://` MinIO URL),
  clobbers the live data and `nagarectl storage restore`, confirming the sentinel round-trips through
  local MinIO. (Done 2026-06-30.)
- [x] M1.5: `scripts/local-smoke.sh` verifies HTTP 200 via the Kourier port-forward and prints `local
  smoke: OK`; `just local-smoke` recipe added to the `[group('test')]` block of `justfile`. (Done
  2026-06-30.)
- [x] M1.6: `just local-smoke` exits 0 end-to-end on this Docker+dev-shell machine with no
  `gcloud`/IAP/GCS calls (transcript in Outcomes); the cloud guardrail still fail-closes with
  `NAGARE_MODE` unset. (Done 2026-06-30.)
- [x] M2.1: `docs/user/local-development.md` completed — the runbook already covered substrate →
  deploy → data/backups; this plan added the optional-auth-plane and `just local-smoke` sections,
  refreshed the status banner to 🟢, and reconciled the HTTP-vs-HTTPS claim with EP-85's auto-TLS.
  (Done 2026-06-30.)
- [x] M2.2: `docs/user/local-development.md` troubleshooting section added (image won't pull; app 404
  / host-proxy interception + the port-forward recipe; macOS AirPlay :5000; MinIO creds/0-byte;
  WebAuthn blocked). (Done 2026-06-30.)
- [x] M3.1: "Running nagare locally" pointer added to `docs/user/getting-started.md`; `README.md`
  already links the runbook (and documents local mode throughout) from earlier plans. (Done
  2026-06-30.)
- [x] M3.2: `CLAUDE.md` note added that `NAGARE_MODE=local` is a supported testing path that bypasses
  the GCP guardrail by design without weakening the fail-closed cloud guarantee; CI-deferral noted as
  a future DinD option in the runbook. (Done 2026-06-30.)

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **A host reverse proxy (`portless`) shadows the loopback domain on :80/:443 — the smoke MUST go
  through a Kourier port-forward.** The first runs failed at the sentinel write: `curl
  https://uploads-volume.personal.127-0-0-1.sslip.io/...` returned a `portless` 404 page ("No app
  registered for …"), not the app — a host proxy holds 127.0.0.1:80/:443 and shadows the k3d load
  balancer. This is exactly MasterPlan 16's EP-82 Surprise #3, which directed EP-86 to curl through
  `kubectl -n kourier-system port-forward svc/kourier` + a `Host:` header. The script now forwards
  Kourier :80 to `127.0.0.1:18080` and curls with `-H "Host: ${APP_HOST}"`; verified HTTP 200 from
  `server: envoy`. Date: 2026-06-30.

- **EP-85's auto-TLS makes apps serve HTTPS even unauthenticated, so the plan's "plain HTTP" deploy
  assumption was wrong on a full cluster.** With EP-85 installed, `config-network`
  `external-domain-tls: Enabled` repoints Knative at the `nagare-local-ca` issuer, so `nagarectl
  deploy` prints `https://…` for every app. But Kourier still serves the route over **HTTP on :80
  without a forced redirect** (`http-protocol` unset), so the smoke reaches it over plain HTTP via the
  port-forward and needs no CA trust. The runbook's "serves apps over HTTP" line was reconciled to
  note the HTTPS-once-auth-plane-installed behavior. Date: 2026-06-30.

- **The CLI drifted from the cloud script's `nagarectl` surface: no `app delete --yes`, no `storage
  delete`.** `scripts/live-smoke.sh` calls `nagarectl app delete "$APP" --yes` and (in the EP-86
  skeleton) `nagarectl storage delete …`. The current CLI's `app delete` signature is `NAME [-n NS]
  [-f FILE]` with **no `--yes`** and no confirmation prompt (it resolves DomainMappings from the
  cluster when the config file is absent), and there is **no `storage delete` verb** at all (only
  list/inspect/snapshot/restore). The teardown silently no-op'd (`… --yes >/dev/null 2>&1 || true`),
  leaving the app behind. Fixed to `nagarectl app delete "${SMOKE_APP}" -n "${SMOKE_NS}"`, and the
  MinIO snapshot object is removed best-effort by a throwaway `minio/mc` pod (`mc rm`) instead of a
  nonexistent CLI verb. Date: 2026-06-30.

- **Bring-up must also run `just local-minio` — the snapshot/restore step needs MinIO, which
  `local-bootstrap` does not install.** EP-84 ships MinIO as a separate `just local-minio` recipe
  (`cluster/local/minio/minio.yaml`), applied *after* `local-bootstrap`. The smoke's cluster-up path
  runs all three (`local-up` + `local-bootstrap` + `local-minio`) when the cluster is absent, and
  additionally re-applies `local-minio` if `deploy/minio` is missing on an already-up cluster, so a
  cluster brought up by a bare `just local-up` still gets MinIO before the snapshot step. Date:
  2026-06-30.

- **Most of `docs/user/local-development.md` already existed (EP-82–EP-84).** The runbook was not a
  blank-slate M2: prior plans had written prerequisites → profile → bring-up → deploy → data/backups.
  This plan *completed* it (optional-auth-plane + smoke sections, troubleshooting, status banner, the
  HTTP/HTTPS reconciliation) rather than authoring from scratch, and `README.md` already linked it —
  so M3.1's README edit was already in place. Date: 2026-06-30.

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

- Decision (revises the one above): **reach the app through a `kubectl -n kourier-system port-forward
  svc/kourier` + a `Host:` header over plain HTTP, not by curling the loopback domain directly.**
  Rationale: the assumption that `*.127-0-0-1.sslip.io` resolving to `127.0.0.1` is sufficient held
  for DNS but not for the *socket*: a host reverse proxy (`portless` on the dev machine; `Caddy`
  elsewhere) can bind 127.0.0.1:80/:443 and shadow the k3d load balancer, so the literal curl reached
  the proxy's 404, never Knative — exactly the EP-82 Surprise the MasterPlan flagged for EP-86. A
  port-forward owns a fresh 127.0.0.1 port that bypasses any such proxy and hits Kourier directly, and
  Kourier serves the route over HTTP on :80 with no forced redirect even when EP-85's
  `external-domain-tls` is Enabled — so the smoke needs neither `--resolve`, a gateway IP, nor CA
  trust. The deploy-printed host is still the source of truth: it becomes the `Host:` header.
  Date: 2026-06-30

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**Delivered, fully met the purpose.** `just local-smoke` runs the cloud smoke's exact scenario —
deploy → sentinel → snapshot → restore → HTTP 200 → teardown — entirely locally with zero cloud
dependencies, and exits 0. A representative green run (the final acceptance):

```text
== building nagarectl ==
== step 1: ensure the local k3d cluster + registry + MinIO are up ==
== step 2: nagarectl deploy uploads-volume (host-arch build -> local registry) ==
  ... naming to k3d-registry.localhost:5000/tan-nb-exp/nagare/uploads-volume:20260630-225249
  service.serving.knative.dev/uploads-volume condition met
  Deployed: https://uploads-volume.personal.127-0-0-1.sslip.io
== port-forward kourier :80 -> 127.0.0.1:18080 ==
== step 3a: write a sentinel into the volume ==
  read back: smoke ok 85947
== step 3b: snapshot the volume to local MinIO ==
  Snapshot written: s3://nagare-backups/volumes/uploads-volume/uploads/20260630T225452Z.tar.gz
== step 3c: delete the live data, then restore + confirm the sentinel round-trips ==
  RESTORE OK: sentinel smoke-sentinel-85947.txt present in the restored tree
== step 4: verify HTTP 200 ==
  HTTP 200 OK
local smoke: OK
== teardown ==
== teardown done ==
```

**Acceptance evidence.** Exit 0. Grepping the transcript for `gcloud|gsutil|gs://|start-iap-tunnel|
live-test.sh` returns nothing (the only script matches are descriptive comments). The snapshot URL is
`s3://…` MinIO, never `gs://`. After the run, `kubectl -n personal get ksvc uploads-volume` →
`NotFound`, no `nagare.dev/restore-scratch=true` PVC remains, and the run's MinIO object was removed by
teardown. The guardrail still fail-closes: `_require_target_project` with a mismatched cloud project
and `NAGARE_MODE` unset refuses (rc=1); with `NAGARE_MODE=local` + a loopback domain it steps aside
(rc=0).

**Gaps / deferred (as planned).** `just local-smoke` is **not** wired into CI — it needs a real Docker
daemon (DinD); recorded as a future option in the runbook (no cloud credentials to manage, so it is a
clean addition). The WebAuthn passkey *gesture* remains a manual browser step; the headless
302→403→grant→200→revoke→403 progression is what the auth chain is exercised by. The snapshot/restore
round-trip uses default scratch restore + a listing grep (proving the snapshot captured the sentinel),
matching `live-smoke.sh`; `--into-live` recovery is documented but not asserted by the smoke.

**Lessons.** The plan's "column-for-column twin of `live-smoke.sh`" framing was right, but three of the
cloud script's `nagarectl` calls had drifted (`app delete --yes`, `storage delete`, plain-HTTP
reachability) — verifying against the *current* CLI surface and a *real* run, not the reference
script, was essential. The host-proxy-on-:80 hazard the MasterPlan flagged for EP-86 was real on the
dev machine; routing through a Kourier port-forward made the smoke robust regardless of host port
contention or whether EP-85's auto-TLS is installed.

