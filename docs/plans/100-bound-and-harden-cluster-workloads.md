---
id: 100
slug: bound-and-harden-cluster-workloads
title: "Bound and harden cluster workloads"
kind: exec-plan
created_at: 2026-07-16T04:25:03Z
intention: intention_01kzakvy1qeasagg3rpbn44749
master_plan: "docs/masterplans/19-platform-review-remediation-guardrails-security-reliability-and-operability.md"
provenance:
  revisions:
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-16T04:51:51Z
      mode: "update"
      note: "Reconcile live rollout with current auth manifests and context-owned secrets"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-16T18:33:59Z
      mode: "implement"
      note: "Record labs baseline, pinned chart rehearsal, auth server dry runs, and fresh bootstrap prerequisites"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-16T19:41:12Z
      mode: "implement"
      note: "Bound chart helpers and operator reloaders; validate pinned renders and labs admission; prepare gated rollout"
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-16T21:22:32Z
      mode: "implement"
      note: "Record guarded live-audit refusal and bounded bash recovery gates"
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-17T14:22:20Z
      mode: "implement"
      note: "Record the clean 40% cache rollout and remaining seven-day/auth gates"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-17T21:10:30Z
      mode: "implement"
      note: "Record completed cloud-auth rollout and narrow EP-4 to seven-day sizing"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-10-03T22:41:09Z
      mode: "implement"
      note: "F41: durable local MinIO and offline escrow verification; 44ff0fd7 C2 checkpoint"
---

# Bound and harden cluster workloads

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

Full plan before trimming: [100-bound-and-harden-cluster-workloads.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/100-bound-and-harden-cluster-workloads.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

Nagare is a personal PaaS running on a single 2-vCPU / 8 GB GCP VM (`nagare-01`,
k3s + Knative). On a box that small, one misbehaving pod can take down everything:
a workload with no memory limit can OOM the node, a log store with time-only
retention can fill the shared data disk that every PVC lives on, and a migration
Job that silently skips its work can leave the auth database behind the code that
talks to it. A July 2026 platform review (MasterPlan 19) found nine such gaps in
the cluster manifests; this plan closes all of them.

The repository now encodes the following target behavior; the remaining work is
to observe it on the live platform. Every auth-plane pod (`en`, `shomei`, `nagared`,
`nagare-access`) and every Victoria observability pod runs with explicit CPU
requests and memory limits, so `kubectl describe node` shows a truthful
reservation picture and a runaway build inside `nagared` gets OOM-killed at 1 GiB
instead of taking the node with it; `en` has readiness and liveness probes on its
real health endpoints; `en`, `shomei`, and the migration Jobs run under the same
hardened securityContext `nagare-access` already has; Grafana's admin password
comes from a sops-encrypted Secret in the active context's operator-owned
`cluster-secrets/<context>/` directory instead of a literal committed to Git or
an immutable release payload, and its datasource list has exactly one source of
truth;
VictoriaLogs and VictoriaTraces carry hard disk-usage caps below their PVC sizes,
so they can never fill the data disk; re-running `cluster/bootstrap/auth-install.sh`
after adding a migration actually applies that migration; and the auth images
deploy by immutable git-SHA tag by default, with mutable `latest` an explicit
opt-in.

## Progress

- [x] Restore the disposable local acceptance path (2026-09-16): started the existing
  Colima profile, corrected the test shell to use a clean environment after a
  fail-closed target refusal, and created an isolated `nagare-local` cluster with
  a temporary kubeconfig. Existing unrelated local clusters were not modified.
- [x] Fix fresh cert-manager admission readiness (2026-09-16): the first local
  bootstrap stopped on a CA-trust race. Added a bounded server-dry-run gate after
  webhook Deployment readiness in both recipes; retry/failure/order tests pass.
  The local recovery completed, including Ready local CA and Knative bootstrap.
  Native `knative-bootstrap-readiness` and `shellcheck-scripts` checks pass.
- [x] Local store diagnostic (2026-09-16): exact release tags, native arm64,
  512Mi memory/no swap/no CPU caps, empty data directories, twelve batches of
  1000 synthetic series/log records. Both stores stayed running with zero OOMs
  and zero restarts; eventual queries returned 12000 series and 12000 log records.
  This limited synthetic workload did not reproduce the labs amd64 startup OOMs.

- [x] M1: add resources, probes, and securityContext to `cluster/bootstrap/en/service.yaml`. (2026-08-24)
- [x] M1: add resources and securityContext to `cluster/bootstrap/shomei/service.yaml`. (2026-08-24)
- [x] M1: add resources to `cluster/bootstrap/nagare-access/service.yaml`. (2026-08-24)
- [x] M1: add resources to `cluster/bootstrap/nagared/service.yaml`. (2026-08-24)
- [x] M1: add resources and securityContext to the Job in `cluster/bootstrap/en/migrations.yaml`. (2026-08-24)
- [x] M1: render all five manifests and assert their resource, probe, and security
  fields with `yq`; all assertions passed. (2026-08-24)
- [x] M1 local validation (2026-09-16): built current En, Shomei and nagare-access
  images at source tag `9577009`, installed the combined manifests on disposable
  k3d, and observed all three services Ready with zero restarts. All five application
  and migration containers have CPU/memory requests, memory limits, UID/GID 10001,
  non-root execution, no privilege escalation, dropped ALL capabilities and
  RuntimeDefault seccomp. En's 62-second database outage returned readiness 503 and
  liveness 200 throughout; Kubernetes readiness failed and recovered, with unchanged
  server UID and zero restarts. The nagared scaffold was not installed.
- [x] M1: commit the bounded auth-plane manifests and plan state. (2026-08-24)
- [x] M2: create sops-encrypted `cluster/secrets/grafana-admin.yaml` without
  exposing the generated password in tool output or plaintext Git state. (2026-08-24;
  this was the checkout-owned source before the packaging reconciliation below)
- [x] M2: switch `grafana.adminPassword` to `grafana.admin.existingSecret` and
  pin the plugin to the current verified release, 0.31.0, in
  `cluster/observability/victoria-metrics/values.yaml`. (2026-08-24)
- [x] M2: remove `grafana.additionalDataSources`; apply
  `cluster/observability/grafana/datasources/*.yaml` as labelled ConfigMaps from
  `cluster/observability/install.sh`; update the datasource file comments. (2026-08-24)
- [x] M2: add `retentionDiskSpaceUsage` and resources to
  `cluster/observability/victoria-logs/values.yaml` and
  `victoria-traces/values.yaml`; add resources to
  `victoria-logs/collector-values.yaml`. (2026-08-24)
- [x] M2: verify the exact pinned charts with `helm template`, assert the Secret and
  datasource ConfigMap shapes, and shellcheck the installer; commit M2. (2026-08-24)
- [x] M3: replace the stale embedded-SQL ConfigMap with the supported
  `en-migrate up` executable from the exact same image as `en-server`, and build both
  binaries into that image. (2026-08-24)
- [x] M3: delete-then-render-and-apply the migration Job in
  `cluster/bootstrap/auth-install.sh` and
  `cluster/bootstrap/local-auth/install.sh`. (2026-08-24)
- [x] M3: default `NAGARE_AUTH_TAG` to the git SHA in `auth-install.sh` and
  `render-context-template.sh`. (2026-08-24)
- [x] M3: pin MinIO images to Docker Hub-verified release tags and document the
  `emptyDir` decision in `cluster/local/minio/minio.yaml`. (2026-08-24)
- [x] M3: update `cluster/bootstrap/en/README.md` to match the pg-migrate-backed
  Job behavior and cite its canonical cross-repository packages. (2026-08-24)
- [x] M3: prove migration rerun behavior against disposable PostgreSQL: the first
  `en-migrate up` reported `applied_now`, the second `already_applied`, and
  `en-migrate verify` reported one applied, zero pending, zero unknown. (2026-08-24)
- [x] M3 local installer validation (2026-09-16): both installer runs completed.
  Both migration Job UIDs changed and each completed once. The first logs report
  `applied_now`, the second `already_applied`; En verifies 2 applied and Shomei 36,
  both with zero pending/unknown. Fresh databases were created solely for this test.
- [x] M3: commit the pg-migrate Job, immutable tag defaults, and MinIO pins. (2026-08-24)
- [x] Packaging reconciliation: `cluster/observability/install.sh` now resolves
  `grafana-admin.yaml` from the active context's operator-owned cluster-secret directory
  via `scripts/lib/cluster-secrets.sh`, fails before mutation when it is absent, and
  keeps checkout `cluster/secrets/` only as a compatibility fallback. Released payloads
  and workspaces exclude encrypted credentials. (2026-08-26, implemented with
  `docs/plans/101-alerting-and-backup-freshness-monitoring.md`)
- [x] Cloud preflight and rehearsal (2026-09-16): verified the `labs` context/project
  guard, inventoried workloads and registry images, rendered all five pinned
  observability charts, and server-dry-ran En, Shomei, nagare-access, and both
  migration Jobs successfully. No live resources were created or changed.
- [x] Observability rollout approval and credential preparation (2026-09-16): operator
  approved the five-release observability sequence only. Created private labs
  Grafana ciphertext with workstation/recovery recipients; isolated workstation
  round-trip and empty-identity rejection passed. Committed in the private operator
  repository as `85826b1` (not yet pushed). No recovery-private-key readback claimed.
- [x] First live attempt and safe stop (2026-09-16 18:54–18:56 UTC): applied the
  monitoring namespace and Grafana Secret, then installed `vmks` revision 1.
  Grafana failed startup on the plugin syntax. Cancelled Helm and confirmed the
  installer exited; release status is `failed`. No later releases were installed.
- [x] Local repair/rehearsal (2026-09-16): corrected the plugin pin to `id@version`,
  added a hermetic regression test and exact-chart render check; both pass.
  Native Nix checks `observability-grafana` and `shellcheck-scripts` also pass.
- [x] Recovery stages 1–2 and Grafana checks (2026-09-16 19:15–19:16 UTC):
  operator approved the repair/resume sequence; existing encrypted/live credentials
  match, node/cache/PVC preflight passed, and `vmks` revision 2 is deployed.
  All monitoring pods are Ready. Grafana 13.0.1+security-01 health reports `ok`,
  login with the encrypted credential returns 200, the old default returns 401,
  and the installed VictoriaLogs plugin reports 0.31.0. Credentials/cookies were
  not printed.
- [x] Recovery stability gate (2026-09-16 19:15:52–19:20:57 UTC): eleven samples
  over 306 seconds kept the same VMSingle pod Ready with restart count 3 unchanged.
  Memory sampled 215468–288128Ki (about 210–281Mi), below the unchanged 512Mi cap.
  Grafana also queried thirteen live `up` series through its metrics datasource.
  This is a short-window recovery proof, not seven-day tuning or a clean-start
  proof; the three original startup OOMs remain recorded. Stage 4 resumed after
  the gate passed.
- [x] Complete the approved observability recovery/install (2026-09-16 19:21–19:25 UTC):
  `vmks` revision 3 and the other four releases at revision 1 are deployed. All
  eleven observability pods are Ready. Grafana has exactly one VictoriaLogs and
  one VictoriaTraces datasource; a logs aggregate returned 104 recent records,
  and a fresh synthetic OTLP trace was retrieved through Grafana's Jaeger proxy.
  Live log/trace args enforce 15GiB/8GiB disk caps and 512Mi memory limits; their
  20Gi/10Gi PVCs are Bound. Node reservations are 2245m CPU and 3098Mi memory,
  leaving 1755m CPU unreserved. No host/auth/public-ingress changes were made.
- [x] Recover the read-only labs follow-up (2026-09-16): the first preflight was
  launched by zsh even though `scripts/lib/target.sh` is a Bash source library.
  Its Bash-only `BASH_SOURCE[0]` root discovery therefore resolved
  `/Users/shinzui/Keikaku`, refused the missing `release.json`/`justfile`, and
  never defined `_require_target_project`. All attempted Kubernetes reads then
  failed against an unrelated ambient kubeconfig; no guarded cloud read or
  mutation succeeded. The bounded Bash recovery subsequently passed for guarded
  project `tan-ng-labs`, kube context `labs`, and sole Ready node `labs-nagare`.
- [x] Diagnose and prepare the startup-memory correction (2026-09-16): read-only
  logs show both stores detected the 512Mi cgroup and assigned the default 60%
  (307.2Mi) to caches immediately before their startup OOMs. Pinned upstream tags
  exist; exact charts support the cache flag. Set both budgets to 40%, added exact
  render assertions, and passed the five-chart regression, hermetic shell lint,
  native `shellcheck-scripts`/`observability-grafana` checks, `just docs-validate`,
  and `git diff --check`.
- [x] Apply the separately approved cache-budget rollout one store at a time and
  prove clean startup without OOM/restart (2026-09-17): `vmks` revision 5 created
  a new VMSingle pod with `-memory.allowedPercent=40`, retained PVC UID
  `71d3ba21-ce2c-472c-bcef-83a640e1a5d6`, and passed 21 Ready/zero-restart samples
  over 613 seconds with 230–401Mi observed memory and 14 live `up` series. Only
  after that gate passed, `victoria-logs` revision 2 created a new store pod with
  `--memory.allowedPercent=40`, retained PVC UID
  `f0b89311-ea63-446b-9c46-25b733271955`, and passed 21 Ready/zero-restart samples
  over 622 seconds with 9–15Mi observed memory. Metrics remained clean throughout;
  a final two-minute LogsQL aggregate returned 127 newly ingested records.
- [ ] Retain seven full days of representative sizing data before adjusting
  requests or declaring long-term sizing complete. History began at 19:00/19:25
  UTC on 2026-09-16, so this gate cannot pass before 2026-09-23/24 UTC.
- [x] Publish private Grafana ciphertext (2026-09-16): operator explicitly approved
  commit `85826b1`; rechecked the clean private repository, exact two-file change
  and unchanged remote, pushed without force, and verified remote master equals
  `85826b1af8f04170a2308d2af44c67f4d1877d62` at `mori://shinzui/nagare-ops`.
  This publication performed no cluster mutation.
- [x] Rehearse the cloud auth rollout after reauthentication (2026-09-17): guarded
  labs inventory confirms Artifact Registry exists with only the Attic image,
  Cloud Build is not enabled, and no auth image, database, credential, migration
  Job, or service exists. Immutable tag `0b8926af4ec6` has no auth-code delta from
  the successful local acceptance. All five rendered workload/Job manifests, both
  config maps, and both managed Postgres stacks pass labs server-side dry run; the
  database render uses the CLI's internal `--system-namespace` flag so
  `nagare-system` retains its platform namespace contract.
- [x] Apply the separately approved cloud auth sequence (2026-09-17): Cloud Build
  published all three amd64 images at tag `0b8926af4ec6`; the rollout created the
  cookie key and fresh `shomei-db`/`en-db`, ran both migrations and all three
  services, and reran the installer without replacing database, PVC, Deployment,
  or Knative Service identities. Shomei verifies 36 applied migrations and En 2,
  both with zero pending/unknown; the rerun logged every migration as
  `already_applied`. All five auth/database pods stayed Ready with zero restarts
  across 21 samples over 610 seconds, scoped usage was about 34m CPU/102Mi, and
  the node retained 1465m unreserved CPU. Exact image digests, health endpoints,
  secrets, resources, and security contexts passed. Nagared was not installed and
  no database was reset.
- [x] Stop the first approved cloud-auth attempt at the build permission boundary
  (2026-09-17): the guarded preflight passed, Cloud Build was enabled in
  `tan-ng-labs`, and the Shomei source archive reached the managed staging bucket.
  `gcloud builds submit` then returned `PERMISSION_DENIED` for active account
  the active operator account before returning a build ID. The exact registry-tag
  query remained empty. No auth image, credential, database, migration, or service
  was created; En and nagare-access builds were not attempted.
- [x] Prepare the broader memory-bound correction (2026-09-16): exact five-chart
  rendering and labs server admission dry runs pass; six direct containers gain
  limits and operator defaults cover both reloaders. Deployment remains pending.
- [x] Apply the approved resource correction (2026-09-16): operator said
  `continue` after the rehearsed rollout request. Guarded labs preflight passed;
  `vmks` revision 4 deployed, affected Deployments/DaemonSet finished rollout,
  and both operator-created reloaders now have 128Mi limits. Every observability
  container has CPU/memory requests and a memory limit. Grafana credential,
  datasource uniqueness, metrics and logs queries pass. Node requests are exactly
  2360m CPU/3674Mi memory, leaving 1640m CPU unreserved.
- [x] Resource-rollout stability (2026-09-16 19:49:05–19:59:32 UTC): 21 samples
  over 628 seconds kept all eleven observability and both cache/database pods
  Ready with unchanged UIDs/restart counts. Every regular/init observability
  container passed the resource assertion. End-of-window Grafana health, fourteen
  `up` series, and 330 log records over five minutes passed; node reservations
  stayed at 2360m CPU/3674Mi memory. No clean restart of either store is claimed.
- [x] Update Outcomes & Retrospective with the bounded rollout and remaining gates. (2026-09-16)

## Surprises & Discoveries

- Enabling the Cloud Build API and submitting a build are separately authorized.
  The active account could enable `cloudbuild.googleapis.com` and upload the
  generated source archive, but the build-create request was refused. Because the
  approved sequence says to stop on any build failure, this is an operator IAM
  prerequisite rather than a reason to try another builder or identity. Cloud
  Build remains enabled; Artifact Registry has no auth image at the intended tag.
- After reauthentication, guarded inventory showed that Artifact Registry is
  enabled and contains only Attic, while `cloudbuild.googleapis.com` is absent
  from the enabled-service list. The Apple Silicon workstation path documented by
  the auth image helpers uses Cloud Build for real linux/amd64 images, so the
  bounded rollout must explicitly enable that API before submitting three builds.
  The alternative k3s-import path would leave images only on the current node and
  would not exercise the registry-backed immutable image contract this acceptance
  is meant to prove.
- Current `nagarectl db create` treats a named namespace as an application
  namespace unless its internal `--system-namespace` switch is present. The
  rehearsed auth database commands include that switch; without it, a create
  could incorrectly label `nagare-system` as an application namespace. Both
  resulting Postgres stacks pass server-side admission. Their containers have no
  resource requests/limits because managed-database sizing is outside M1's
  explicitly scoped five auth application/migration containers; the rollout must
  still measure them and preserve the final 550m CPU headroom gate.
- The 2026-09-17 cloud-auth rehearsal passed the Bash target guard for
  `tan-ng-labs`, then `gcloud services list` refused because the active account's
  refresh token requires interactive reauthentication. Repository and Mori reads
  established the intended source paths first; the refusal happened before Cloud
  Build or Artifact Registry inventory and before any cloud or cluster mutation.
  `CLAUDE.md` requires stopping at this boundary rather than changing accounts,
  bypassing inventory, or starting a build speculatively.
- The clean-start rollout on 2026-09-17 preserved both PVC objects and backing
  volumes while replacing each store pod in sequence. VMSingle started once and
  stayed Ready for 613 seconds at zero restarts; VictoriaLogs then did the same
  for 622 seconds. A rolling five-minute log count is not monotonic because old
  records age out of the window, so the final ingestion proof used the documented
  two-minute LogsQL stats query and observed 127 records rather than comparing two
  rolling totals. Node requests remained 2360m CPU/3674Mi memory, leaving 1640m
  CPU unreserved.
- The 2026-09-16 continuation initially sourced the Bash-only target library from
  zsh. In zsh, `BASH_SOURCE[0]` is empty, so the library derived its physical root
  from the caller's working directory and climbed two directories to
  `/Users/shinzui/Keikaku`. It failed closed before defining the project guard.
  Subsequent `kubectl` reads in that same command inherited an unrelated ambient
  kubeconfig and failed to parse its API response; they are not evidence about
  labs. The recovery must use `bash -lc`, require the guarded labs identity, set
  the labs kubeconfig explicitly, and prove `kubectl config current-context`
  before any workload read. The first recovered identity check then rejected a
  hard-coded `nagare-01` node name. Mori resolved the authoritative labs operator
  documentation at `mori://tan/tan-ng-labs/docs/readme`, which distinguishes the
  GCE instance `nagare-01` from the Kubernetes/Tailscale host `labs-nagare` and
  requires the labs kubeconfig to list exactly the latter.
- The recovered read-only audit found that VMSingle 1.144.0 and VictoriaLogs 1.50.0
  both correctly saw 536870912 bytes of cgroup memory but applied the default 60%
  cache budget (322122547 bytes), leaving 214748365 bytes to the runtime/OS. The
  last VMSingle failure occurred nine seconds after start; VictoriaLogs failed 22
  seconds after start. Both stores were empty, and both later opened successfully
  under the same cap. This supports a smaller cache budget before any limit increase.
  Current metrics retained only 25–30 five-minute samples (19:00/19:25 through
  21:25 UTC), with observed maxima about 411Mi for VMSingle and 28Mi for logs;
  that history is diagnostic only, not the required seven-day sizing evidence.
- This repository has no `just check-adr` recipe, and Mori reports no profile for
  `docs/adr/`. The attempted recipe therefore failed before validation. ADR 23
  remains in the established local filesystem format; `just docs-validate` passed
  the repository's actual profiled documentation bundles. No incidental ADR-profile
  migration or invented validation command was introduced.
- Labs kernel evidence (read-only SSH, 2026-09-16): three metrics cgroup OOMs
  at 18:55:27/35/55 UTC and one logs OOM at 19:21:59 UTC all hit a 524288KiB
  memory limit. The killed processes had about 510MiB/509MiB anonymous RSS.
  `CONSTRAINT_MEMCG` confirms workload limits, not a node-wide OOM; duplicate
  group-kill lines do not represent additional container restarts. This narrows
  the failure but does not identify the allocations or prove a remedy.
- Local auth acceptance (2026-09-16): resource/security assertions passed on the
  actual pods, not only rendered YAML. Application spot usage was En 35Mi,
  Shomei 14Mi and nagare-access 5Mi; this idle arm64 sample does not size cloud
  workloads. The readiness harness initially included the completed migration
  pod sharing En's label; restricting it to ReplicaSet-owned pods fixed the
  pre-mutation test refusal. The outage/recovery then passed.

- Local acceptance restart (2026-09-16): Colima was stopped and is now running
  with its existing 4-CPU/8GiB profile. The cached auth images predate current
  application changes. The first local build preflight refused before building:
  clearing the context-resolution marker while preserving ambient cloud fields
  kept `NAGARE_MODE=cloud` and the labs project above the local context file.
  This is the documented environment-over-context precedence, not a guard defect.
  Do not change gcloud defaults or weaken the assertion; use the clean-environment
  recovery below.

Initial findings date from authoring (2026-07-15); later observations are dated below.

- The resource rollout changed node reservations by exactly the projected
  115m CPU/576Mi memory. Grafana API checks after the rollout returned fourteen
  metrics `up` series and 2803 log records over five minutes. Metrics/logs retained
  their original pod identities and restart counts 3/1; this update did not restart
  either store and therefore does not constitute a clean-start proof.
- A one-hour historical query during the observation found sampled working-set
  peaks of 447.8Mi for metrics and 472.9Mi for logs, near their 512Mi limits.
  Duplicate scrape series were considered by their maximum, not summed. The
  running processes report the correct 512Mi available memory and 307.2Mi cache
  budget; Go has no soft memory limit. These readings support continued startup
  investigation but do not identify which transient allocation caused each OOM.

- Follow-up on 2026-09-16: Mori has no registered Victoria/Helm source, so the
  exact published chart archive was inspected directly. The pinned operator is
  v0.70.1; its running `/app --printDefaults` confirms the three
  `VM_CONFIG_RELOADER_*` resource settings used below. Six directly rendered
  containers lacked memory limits; two operator-created reloaders also lacked them.
  The baseline render reproduces all six direct omissions; the new render has none.
- The labs follow-up sample showed Grafana 172Mi, dashboard/datasource sidecars
  77/74Mi, operator 36Mi, kube-state-metrics 19Mi, node-exporter 10Mi, and reloaders
  7/6Mi. Metrics/logs restart counts remain 3/1. Their previous logs identify the
  correct 512Mi cgroup limit and a 60% cache budget; the cause of the transient
  allocation peak is unresolved. Raising limits or claiming a cgroup-detection bug
  is not justified by this evidence. Retain the store limits pending a separately
  rehearsed startup experiment.
- The local Docker API is unavailable (`.colima/docker.sock` is absent). No local
  auth cluster was created, and no cloud auth bootstrap is implied by the resource
  rehearsal. The current labs CPU request total is 2245m; the proposed change adds
  115m, leaving 1640m of its 4000m allocatable CPU. Memory requests grow by 576Mi
  to 3674Mi. These are projected reservations, not post-rollout measurements.

- Live deployment (2026-09-16) disproved the earlier plugin syntax assumption:
  `GF_PLUGINS_PREINSTALL_SYNC` split `victoriametrics-logs-datasource 0.31.0`
  into two plugin IDs. Grafana exited with `failed to install plugin 0.31.0@:
  404: Plugin not found`. The supported pin is `id@version`, documented by
  [Grafana's Docker installation guide](https://grafana.com/docs/grafana/latest/setup-grafana/installation/docker/#install-plugins).
  A successful Helm render alone did not prove runtime parsing. The new
  `scripts/test-observability-grafana.sh` checks the exact pin and rejects the old
  shape; `--render` also asserts the ConfigMap/environment linkage.
- The live resource inventory after the plugin repair exposed an acceptance gap
  that offline M2 checks had not covered. The chart supplies no memory limits for
  Grafana (including both sidecars), kube-state-metrics, node-exporter, the operator,
  and both config-reloaders. The broad final assertion that every monitoring pod
  is bounded therefore cannot be claimed from the existing values. Keep this
  separate from successful installation and from the explicit store/collector caps.
- After the successful installer exit, the first logs aggregate returned zero.
  The logs server had one startup `OOMKilled` event and its headless Service had
  temporarily lacked a Ready endpoint; the collector reported DNS failures and
  retried. A subsequent read returned 104 recent records without any configuration
  change. The pinned collector is native `vlagent`, not Vector as the old comments
  said; the configured 25m/64Mi request and 256Mi cap apply to that container.
- The OTel chart binds receivers to the pod IP, not loopback. A workstation
  `kubectl port-forward` reached the pod namespace but failed on `127.0.0.1:4318`;
  this was a test transport mismatch, not evidence of a broken receiver. The
  authenticated [Kubernetes Service proxy](https://kubernetes.io/docs/tasks/access-application-cluster/access-cluster-services/)
  reached the unchanged service successfully. One synthetic span from service
  `nagare-ep100-acceptance` was accepted with HTTP 200 and retrieved through the
  Grafana VictoriaTraces datasource. No diagnostic pod, public listener, host
  change, or altered receiver binding was needed.
- During this attempt, VMSingle restarted three times with `OOMKilled`/exit 137
  under its 512Mi cap. It subsequently became Ready, but startup stability and
  sustained resource usage are not proven. No memory limit was changed. The
  recovery must stop if new OOMs occur; a Ready snapshot is not sufficient.
- After cancelling the attempt, metrics components other than Grafana were Ready;
  the 20Gi VMSingle PVC was Bound, all monitoring Services were ClusterIP, the node
  remained Ready, and the existing cache/server database remained Ready without
  restarts. No host/auth/database reset/public-endpoint mutation was performed.

- The 2026-09-16 `labs` inventory is a fresh bootstrap for this plan, not an auth
  upgrade. The node is Ready on k3s v1.35.8+k3s1 with 4 allocatable CPUs and
  16379592Ki memory. Existing workloads reserve 2000m CPU and 2240Mi memory;
  the spot sample was 142m CPU and 1539Mi memory. These are baseline readings,
  not post-rollout acceptance. No auth workloads, auth databases, or Helm releases
  are installed, and the active project's registry contains only Attic images.
  The context-owned cluster-secret directory contains the cache ciphertext but
  no `grafana-admin.yaml`. New ciphertext must use the private labs policy already
  enrolled in EP-3 recovery; public recipients and private credentials stay out
  of this repository.
- Rehearsal on 2026-09-16 rendered charts 0.81.0 (metrics), 0.13.5 (logs), 0.3.4
  (log collector), 0.1.6 (traces), and 0.158.0 (OTel). Logs/traces carry
  `--retention.maxDiskSpaceUsageBytes=15GiB` / `8GiB`, respectively, and each
  has a 512Mi memory limit. Grafana's admin environment references both required
  keys in `grafana-admin`. The live API accepted server-side dry runs of both auth
  Deployments, nagare-access, and both migration Jobs. This proves admission and
  rendering only, not image availability, readiness, migrations, or data ingestion.
- `cluster/bootstrap/nagared/README.md` explicitly calls its manifest a starting
  point: it requires a build runtime and currently carries example domains. The
  cloud auth installer does not install nagared. Do not count the auth installer
  as live nagared evidence or expose its example DomainMapping during this rollout.

- At authoring, en exposed `GET /healthz` and `GET /readyz`.
  `docs/plans/104-upgrade-nagare-to-the-latest-shomei-and-en.md` later upgraded
  en to its servant-health interface, so the current combined manifest correctly uses
  `GET /health/live` (process liveness) and `GET /health/ready` (dependency
  readiness). Remaining validation must exercise those current paths rather than the
  superseded endpoints recorded in the original implementation commit.
- The Job-immutability problem in finding 5 is subtler than "apply fails": when
  only the ConfigMap SQL changes, `kubectl apply` on the Job succeeds (the Job
  spec is byte-identical) — but the completed Job never re-runs, so new
  migrations are silently never applied. Apply only fails when the Job spec
  itself changes. Delete-then-apply fixes both failure shapes at once.
- The chart value keys for disk-based retention exist and render correctly.
  Verified against the pinned chart versions with `helm show values` and
  `helm template`: `vm/victoria-logs-single` 0.13.5 and
  `vm/victoria-traces-single` 0.1.6 both expose `server.retentionDiskSpaceUsage`
  (default unit GiB), which renders as the container flag
  `--retention.maxDiskSpaceUsageBytes=<value>`; both expose `server.resources`;
  `vm/victoria-logs-collector` 0.3.4 exposes top-level `resources`. Evidence:

  ```text
  $ helm template victoria-logs vm/victoria-logs-single --version 0.13.5 \
      --set server.retentionDiskSpaceUsage=15GiB --set server.retentionPeriod=7d \
      | grep retention
              - --retention.maxDiskSpaceUsageBytes=15GiB
              - --retentionPeriod=7d
  ```

- The `victoria-metrics-k8s-stack` 0.81.0 chart already runs the Grafana
  datasource sidecar with label `grafana_datasource` and labelValue `"1"`
  (chart defaults, confirmed in `helm show values`), and delivers its own
  auto-provisioned VictoriaMetrics datasource through that same sidecar — so
  applying our two standalone datasource files as labelled ConfigMaps unifies
  everything onto one mechanism.
- The auth images already run as a non-root `nagare` system user
  (`cluster/bootstrap/auth-images/Dockerfile.local-haskell` lines 46 and 55:
  `useradd --system ... nagare`, `USER nagare`) and install binaries mode 0555
  owned by that user. So forcing `runAsUser: 10001` via the pod securityContext
  is safe: the binaries are world-readable/executable and nothing writes to the
  filesystem.
- Current pinned upstream image tags for MinIO, checked on Docker Hub
  2026-07-15: `minio/minio:RELEASE.2025-09-07T16-13-09Z` and
  `minio/mc:RELEASE.2025-08-13T08-35-41Z`. Current version of the Grafana
  VictoriaLogs datasource plugin from the grafana.com plugin API: 0.29.0.
  Re-check both at implementation time (commands are in Concrete Steps).

- Implementation (2026-08-24): `kubectl apply --dry-run=client` is not actually
  offline with this kubeconfig; it attempts OpenAPI discovery and current-object
  lookup through the GKE credential plugin, which fails while gcloud needs
  interactive reauthentication. The rendered YAML was instead parsed and its exact
  M1 fields asserted with `yq`. Live apply remains an explicit unchecked item.

- Implementation (2026-08-24): the Grafana plugin release recorded during planning
  was stale. Grafana's authoritative plugin catalog now reports
  `victoriametrics-logs-datasource` 0.31.0 (released 2026-08-06), so M2 pins 0.31.0.
  The pinned k8s-stack chart 0.81.0 embeds Grafana chart 12.3.x and renders that pin
  through `GF_PLUGINS_PREINSTALL_SYNC`, not the older `GF_INSTALL_PLUGINS` variable
  named by the plan. The original rendered value was
  `victoriametrics-logs-datasource 0.31.0`; the 2026-09-16 live failure proved this
  was invalid despite rendering. It is now `victoriametrics-logs-datasource@0.31.0`.

- Implementation (2026-08-24): `mori://shinzui/en/packages/en-migrations` changed
  from the two timestamped SQL files assumed during planning to an append-only,
  pg-migrate-managed component with an `en-migrate` executable and a fixed-point
  bootstrap schema. The old Nagare ConfigMap was not merely behind: its live unique
  index still included `caveat_name` and it lacked the datastore identity and GC
  horizon tables. Adding `IF NOT EXISTS` would therefore have preserved an obsolete
  schema while reporting success. M3 now runs the dependency-owned executable from
  the same image as `en-server`. The controlling cross-repository ADR is in
  `mori://shinzui/en` at project-relative path
  `docs/adr/0001-en-s-schema-is-an-append-only-pg-migrate-component.md`; an
  artifact-level Mori URI is pending registry coverage.

- Implementation (2026-08-24): the MinIO release tags named during planning still
  exist in Docker Hub's authoritative registry for amd64 and arm64:
  `minio/minio:RELEASE.2025-09-07T16-13-09Z` and
  `minio/mc:RELEASE.2025-08-13T08-35-41Z`.

- Integration reconciliation (2026-08-26): MasterPlan 20 and
  [ADR 4](../adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md)
  moved encrypted Kubernetes bootstrap credentials out of immutable payloads. The
  installer now resolves
  `${XDG_CONFIG_HOME:-$HOME/.config}/nagare/cluster-secrets/<context>/` or
  `NAGARE_CLUSTER_SECRETS_DIR` before contacting Helm. A source checkout's
  `cluster/secrets/` is only a compatibility fallback, so the remaining rollout must
  not expect `grafana-admin.yaml` inside an installed platform workspace.

## Decision Log

- Decision: stop the approved labs auth rollout at the first Cloud Build
  `PERMISSION_DENIED` response and retain the registry-backed rollout design.
  Rationale: the failure occurred before a build ID or image existed, and the
  rollout gate explicitly forbids speculative retries or advancing to credentials
  and databases. Resume the same immutable-tag sequence only after the active
  operator identity can submit builds in `tan-ng-labs`; do not substitute a
  node-local import merely to bypass the permission boundary.
  Date: 2026-09-17.
- Decision: build and publish the three labs auth images through Cloud Build and
  Artifact Registry at the already rehearsed Nagare tag `0b8926af4ec6`, rather
  than importing node-local `dev.local` images.
  Rationale: the cloud acceptance is intended to prove immutable registry-backed
  deployment and future kubelet pulls. The current workstation is arm64, the
  cluster is amd64, Artifact Registry already exists, and the repository documents
  Cloud Build as the cross-architecture path. En and Shomei source trees are clean;
  Shomei's deployable code matches release 0.2.0.0, and the current En source is the
  same code used by the successful local acceptance. Cloud Build API enablement is
  therefore included in the single operator-approved sequence.
  Date: 2026-09-17.
- Decision: keep both store memory limits at 512Mi and set
  `memory.allowedPercent` to 40 for VMSingle and VictoriaLogs, pending a separately
  approved one-store-at-a-time rollout and clean-start proof.
  Rationale: the official setting controls internal caches rather than total
  process memory. At the default 60%, each store reserved 307.2Mi of its 512Mi
  cgroup for caches and left only 204.8Mi for runtime/startup allocations; kernel
  evidence shows each failure reached the cgroup ceiling. Forty percent leaves
  307.2Mi for non-cache work without weakening the node-protecting hard cap.
  Steady-state recovery under 512Mi makes a limit increase premature, while a
  lower cache budget has an explicit cache-miss/I/O tradeoff that seven-day data
  must validate. ADR 23 records this durable constraint.
  Date: 2026-09-16.
- Decision: execute live target preflights through Bash and treat a successful
  `_require_target_project` plus an explicit labs kubeconfig/current-context check
  as prerequisites even for read-only Kubernetes evidence.
  Rationale: `scripts/lib/target.sh` is declared as a Bash source library and uses
  `BASH_SOURCE[0]` to locate the operational root. The zsh invocation failed closed,
  but allowing later commands to continue produced only ambient-context noise.
  The recovery keeps the guard unchanged, stops on any failed prerequisite, and
  authorizes no mutation.
  Date: 2026-09-16.
- Decision: add a server-side dry-run admission gate after cert-manager webhook
  rollout rather than a fixed sleep or retry of the mutating issuer apply.
  Rationale: actual webhook trust lags Deployment readiness; dry run exercises
  admission without creating resources. Only known cert-manager startup transport
  and trust errors retry; unrelated/authorization failures stay terminal.
  The official installation guide recommends an admission dry run for this reason.
  Date: 2026-09-16.

- Decision: bound chart-created helpers through their chart resources and the
  operator's global reloader defaults; retain EP-5's notifier blocks unchanged.
  Rationale: direct Pod templates alone miss operator-created containers. Initial
  requests/caps use the observed labs footprint with headroom; seven-day tuning
  and live reconciliation remain separate acceptance. This extends EP-4 ownership
  to the operator/exporter resources in the shared values file. ADR 23 records
  the durable coverage and evidence rule. Date: 2026-09-16.

- Decision: stop on the observed Grafana startup failure, retain the new PVC and
  credentials, and prepare an in-place repair rather than uninstalling or resetting
  anything. Apply the local syntax repair only after the recovery approval gate.
  Rationale: `CLAUDE.md` requires stopping after a refusal/failure and a recovery
  ExecPlan with pass/fail gates. The failure is observable, and no speculative
  host recovery or credential rotation is warranted. The VMSingle OOM observation
  adds a separate stability gate before installing more workloads.
  Date: 2026-09-16.
- Decision: stage the fresh labs rollout, beginning with observability; obtain a
  bounded operator approval after the rehearsal as required by `CLAUDE.md`.
  Rationale: existing cluster workloads are healthy, but auth image builds,
  databases, credential provisioning, and the non-turnkey nagared runtime are
  distinct prerequisites. Leave all live acceptance unchecked until observed.
  Alertmanager remains disabled under EP-5; this plan must not replace its
  blackhole notifier without the separate notification credential.
  Date: 2026-09-16.
- Decision: no CPU limits anywhere; CPU requests as a guaranteed floor plus a
  memory limit only.
  Rationale: this is the established pattern of the carefully-trimmed
  observability stack (see the comment block in
  `cluster/observability/victoria-metrics/values.yaml` lines 15-26: "with no CPU
  limit VMSingle still bursts... The memory limit guards the small node against
  OOM"). CPU is compressible (throttling, not death); memory is not. On a
  2000m-CPU node the sum of requests must stay small enough for an app (~250m)
  plus a database (~300m) to co-schedule.
  Date: 2026-07-15.
- Decision: nagared gets the largest bounds (requests 100m/256Mi, memory limit
  1Gi); en gets a 384Mi limit; shomei and nagare-access get 256Mi.
  Rationale: nagared's in-pod work during a deploy is a git checkout, a `runghc`
  evaluation of the app's `nagare/Config.hs` against nagare-dsl (GHC
  interpretation — the dominant in-pod memory cost, easily several hundred MiB),
  and kubectl calls; the `docker build` itself executes in the Docker daemon
  reached over the mounted socket, i.e. outside the pod cgroup. A 1Gi limit lets
  a config evaluation finish while capping a runaway at ~12.5% of the node. en
  holds two 10,000-entry in-memory caches (`EN_DECISION_CACHE_MAX_ENTRIES`,
  `EN_TUPLE_READ_CACHE_MAX_ENTRIES` in its Deployment) — small entries, tens of
  MiB at capacity on top of the GHC RTS baseline, hence 384Mi rather than 256Mi.
  shomei (WebAuthn/JWT signer) and nagare-access (stateless auth proxy with a
  30-second decision cache) have no comparable state.
  Date: 2026-07-15.
- Decision: nagared does NOT get the hardened securityContext block in this
  plan.
  Rationale: finding 8 scopes the copy to en, shomei, and the en-migrate Job.
  nagared's runtime contract (header comment in
  `cluster/bootstrap/nagared/service.yaml`) requires docker (a daemon socket),
  kubectl, and git; `drop: [ALL]` + `runAsNonRoot` would need per-capability
  and socket-permission analysis that belongs with the nagared security work
  (EP-98 territory), not here. Left as a recorded gap.
  Date: 2026-07-15.
- Decision: datasource duplication resolved by keeping the standalone files in
  `cluster/observability/grafana/datasources/` as the single source of truth,
  applying them from `install.sh` as ConfigMaps labelled `grafana_datasource=1`,
  and deleting `grafana.additionalDataSources` from the chart values (option
  (a) of the two allowed by the review).
  Rationale: the stack chart already provisions its own VictoriaMetrics
  datasource through the sidecar with exactly this label (chart defaults
  `sidecar.datasources.label: grafana_datasource`, `labelValue: "1"`), and
  `install.sh` already applies dashboards through the identical
  ConfigMap-plus-label pattern (lines 33-37). One mechanism, one source of
  truth, and the sidecar picks up edits without a `helm upgrade`. The
  alternative — deleting the standalone files — would leave datasources as the
  only provisioned objects not represented as files under
  `cluster/observability/grafana/`.
  Date: 2026-07-15.
- Decision: migration idempotence via per-statement guards (`CREATE TABLE IF
  NOT EXISTS`, `CREATE INDEX IF NOT EXISTS`) plus running every file on every
  Job run, rather than a `schema_migrations` tracking table.
  Rationale: the README in `cluster/bootstrap/en/README.md` already declares
  this psql Job a temporary bootstrap wrapper to be replaced by codd when en
  publishes a migration image; a hand-rolled tracking table would be throwaway
  machinery. With guards, re-running all files is a fast no-op, which also
  makes the delete-then-apply Job strategy cheap.
  Date: 2026-07-15.
  Superseded on 2026-08-24 by the dependency-owned migration decision below.
- Decision: run `en-migrate up` from the same tagged image as `en-server`, and
  treat `mori://shinzui/en/packages/en-migrations` as the sole owner of the en
  schema. Nagare must not copy en SQL into a ConfigMap.
  Rationale: en now publishes an append-only, pg-migrate-backed migration
  component and executable. Its accepted schema includes datastore identity
  and garbage-collection horizon state and changed a live uniqueness contract;
  retaining Nagare's guarded bootstrap SQL would silently preserve the obsolete
  schema. The pg-migrate ledger, checksums, advisory lock, and forward-only
  manifest provide the rerun behavior this plan needs without a second schema
  authority. The dependency is `mori://shinzui/pg-migrate`; release 1.1.0.0 was
  verified against Hackage and upstream tag `v1.1.0.0` on 2026-08-24. The
  controlling cross-repository ADR is in `mori://shinzui/en` at
  `docs/adr/0001-en-s-schema-is-an-append-only-pg-migrate-component.md`;
  an artifact-level URI is pending registry coverage.
  Date: 2026-08-24.
- Decision: Job re-run strategy is `kubectl delete job en-migrate
  --ignore-not-found` followed by `kubectl apply`, in both installers, rather
  than content-hash-suffixed Job names.
  Rationale: hash-suffixed names would force both installers and the `kubectl
  wait` lines to compute and thread a dynamic name, and would accumulate
  completed Jobs to garbage-collect. Deleting first loses the previous run's
  pod logs, which is acceptable for an idempotent bootstrap migration; the
  logs of a failed run are inspected before retrying, per the README runbook.
  `kubectl replace --force -f migrations.yaml` was rejected outright: the file
  also contains the `nagare-system` Namespace, and replace --force would
  delete-and-recreate the namespace, cascading away the whole auth plane.
  Date: 2026-07-15.
- Decision: `NAGARE_AUTH_TAG` defaults to `git rev-parse --short HEAD` of this
  repository in `auth-install.sh` and `render-context-template.sh`; `latest`
  becomes an explicit opt-in (`NAGARE_AUTH_TAG=latest`). The local installer
  `cluster/bootstrap/local-auth/install.sh` keeps its `dev` default.
  Rationale: `cluster/bootstrap/knative-serving/config-deployment.yaml` (line
  30) exempts the registry host from Knative's controller-side tag-to-digest
  resolution, so a `:latest` reference is never pinned to a digest — a node
  restart can silently pull a different image. The image builder
  (`cluster/bootstrap/auth-images/build-local-image.sh` line 50) already
  defaults its tag to the same short SHA, so builder and installer agree by
  default. The local k3d registry is rebuilt per session and its `dev` tag is
  deliberately mutable for the edit-rebuild loop; pinning there would only add
  friction with no durability to protect.
  Date: 2026-07-15.
- Decision: MinIO keeps its `emptyDir` data volume, with a comment making the
  volatility explicit, instead of gaining a PVC.
  Rationale: `cluster/local/minio/minio.yaml` exists only in local mode
  (MasterPlan 16) as a GCS stand-in for smoke tests; `just local-down` wipes
  the whole cluster anyway, and `scripts/local-smoke.sh` deletes its snapshot
  object on exit. A PVC would imply a durability promise local mode does not
  make. The comment prevents anyone from mistaking local "backups" for real
  ones.
  Superseded 2026-10-03 by MP-23 finding F41 (EP-155 Decision Log): local mode
  now carries release evidence for backups and recovery, and a node restart
  deleted every local backup, so MinIO uses a `local-path` PersistentVolumeClaim.
  Date: 2026-07-15.
- Decision: pin the VictoriaLogs Grafana datasource plugin at 0.31.0 rather than
  the 0.29.0 version found during plan authoring.
  Rationale: the authoritative Grafana plugin catalog lists 0.31.0 as the current
  signed release and declares compatibility with Grafana >=10.4. The repository's
  pinned k8s-stack 0.81.0 embeds Grafana chart 12.3.x, and `helm template` proves
  that the versioned value reaches the generated Grafana ConfigMap.
  Date: 2026-08-24.
- Decision: shared-file ownership with sibling plans (integration points from
  MasterPlan 19): `cluster/observability/victoria-metrics/values.yaml` is also
  edited by `docs/plans/101-alerting-and-backup-freshness-monitoring.md`, which
  enables the `vmalert:` and `alertmanager:` sections (currently
  `enabled: false`, lines 66-70). THIS plan owns the `grafana:` block and
  establishes the Kubernetes Secret contract;
  `docs/plans/101-alerting-and-backup-freshness-monitoring.md` consumes that contract for its
  alert-channel secrets and must not touch the `grafana:` block. The image-tag
  defaulting in M3 interacts with
  `docs/plans/103-host-tuning-upgrade-story-and-documentation-reality-sync.md`'s
  registry-credential work only at the documentation level (103 syncs docs; no
  shared code).
  Date: 2026-07-15.
- Decision: store the Grafana ciphertext with context-owned operator configuration,
  not in the released platform payload; preserve `monitoring/grafana-admin` and its
  `admin-user`/`admin-password` keys as the stable Kubernetes interface.
  Rationale: ADR 4 makes platform payloads immutable and credential-free. The
  location changed, but the chart and workload should not care where the operator
  keeps the encrypted source. `scripts/lib/cluster-secrets.sh` centralizes resolution
  and makes a missing file a pre-mutation failure.
  Date: 2026-08-26.

## Outcomes & Retrospective

The 2026-09-16 local acceptance continuation restored Colima and discovered a
separate fresh-bootstrap defect: cert-manager's Ready webhook pod could precede
trusted admission. The new server-dry-run gate handles the narrow startup race
without retrying terminal errors or weakening validation; regression and native
checks pass and the disposable bootstrap recovered. Current auth images then passed
both local installer runs, actual container resource/security assertions, migration
verification, and En's database-outage readiness/liveness/recovery proof.
The two local store probes accepted and eventually returned 12000 synthetic
records/series each under the live limits with no OOM. This is diagnostic evidence
only: architecture, workload and storage differ from labs, whose OOM cause remains
unresolved. No cloud mutation occurred during this continuation.

M1, M2, and the code portion of M3 are complete as of 2026-08-24. Offline
manifest assertions, exact pinned Helm renders, sops shape checks, shell
linting, immutable-tag rendering, Docker Hub tag verification, and a disposable
PostgreSQL `en-migrate up`/rerun/verify proof all passed. The implementation
also eliminated a more serious form of drift than the original finding: Nagare
no longer carries stale en SQL and instead consumes en's accepted migration
interface from the same release image.

The plan remains in progress because cloud auth bootstrap and seven-day sizing
remain. Private Grafana ciphertext is now published and verified.
Local auth resource,
probe and installer-rerun acceptance is now complete. The formerly
unbounded chart-default containers now have verified live limits. Observability installation,
credential checks, datasource queries, store caps, and current node headroom have
now been observed on labs. ExecPlan 104
(`docs/plans/104-upgrade-nagare-to-the-latest-shomei-and-en.md`) later proved the
upgraded auth plane and both dependency-owned migrations on a disposable local
cluster; the additional EP-4-specific resource, probe and rerun evidence is now
recorded below. Cloud auth and nagared deployment are not implied by the local proof.

The 2026-08-26 packaging reconciliation made the remaining rollout usable from an
installed release: Grafana ciphertext is operator-owned, the installer finds it by
active context, and a missing file is a pre-mutation refusal. This changes the source
location, not the `monitoring/grafana-admin` Kubernetes contract.

On 2026-09-16, the labs preflight and rendering/admission rehearsal passed without
live mutation. The operator subsequently approved the first observability install.
Grafana ciphertext was created and applied, but the metrics release could not
finish because Grafana's plugin pin used the wrong runtime syntax. Helm was
cancelled, retaining resources. After the operator approved recovery, the corrected
pin deployed successfully, encrypted login and default-password rejection passed,
and a 306-second VMSingle observation had no new restarts. The installer then
completed all five releases. Grafana datasource API/proxy checks proved metrics,
collected logs, and a synthetic OTel-to-VictoriaTraces round trip without exposing
services publicly; no interactive Explore UI session is claimed. Current caps and
PVCs match the plan, and 1755m CPU remains unreserved. The private credential
commit was initially local-only; it is now published after separate approval.
At this stage, missing chart-default memory limits and
startup OOMs (three metrics, one logs) remain explicit follow-ups; do not claim
all workloads are bounded or clean-start reliability is proven. Auth bootstrap
remains a separate unapproved sequence.

The resource follow-up now has a concrete, locally validated implementation:
Grafana 50m/256Mi request and 512Mi cap; each sidecar 10m/96Mi and 256Mi;
operator 25m/64Mi and 256Mi; each exporter 10m/32Mi and 128Mi; reloaders retain
10m/25Mi and gain a 128Mi cap. No new CPU limits are introduced. The new
`bash scripts/test-observability-resources.sh` renders all five installer-pinned
charts and checks every regular/init container plus the Victoria custom resources
and reloader defaults. Labs admitted the affected objects in server dry run.
The regression check rejects the original chart values for unbounded containers.
Native Nix checks `shellcheck-scripts` and `observability-grafana` pass, as does
`git diff --check`. The rendered Grafana plugin/Secret contract remains valid.
The resource rollout was subsequently approved and applied as revision 4. Live
resource reconciliation and query checks pass. The ten-minute stability gate also
passed with 21 samples over 628 seconds, retaining all thirteen observed pod
identities and restart counts. Local auth proof subsequently passed and private
Grafana publication is verified. The cache correction then deployed as `vmks`
revision 5 and `victoria-logs` revision 2 on 2026-09-17. Both replacement pods
retained their original PVCs, started with the 40% cache argument, and passed
separate ten-minute Ready/zero-restart windows; metrics and fresh log ingestion
also passed. The later cloud-auth rollout passed every live gate; only seven-day
sizing remains open.

The read-only continuation now identifies a concrete startup-memory mechanism:
both stores reserved 60% of their 512Mi cgroups for caches immediately before the
four startup OOMs. The repository sets 40% and tests the exact rendered flags,
leaving the hard caps unchanged. The staged live rollout now proves clean startup
for both stores under that configuration. Representative seven-day history is still
required before request or limit tuning; the earliest completion point is
2026-09-23/24 UTC.

After operator reauthentication on 2026-09-17, the cloud-auth rehearsal completed
without mutation. Labs has the intended Artifact Registry but Cloud Build must be
enabled; all auth objects are absent, confirming a fresh install. The exact current
image tag, all credential references, both managed database stacks, five auth
application/migration manifests, and two config maps now pass render and server
admission checks. The rollout is ready for one bounded approval covering API
enablement, three image builds, fresh credentials/databases, install/rerun proof,
and a ten-minute resource/readiness observation.

The operator approved that bounded sequence. Guarded preflight passed and Cloud
Build was enabled, but the first Shomei submission was refused for the active
account after source staging and before a build ID was returned. The intended
registry tag is still absent. The rollout stopped at that boundary; no later image
build or cluster-auth mutation ran. Completion now requires build-submission
permission for the same operator identity, followed by a fresh guarded preflight.

