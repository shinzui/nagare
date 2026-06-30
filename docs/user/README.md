# Nagare operator guide

This is the **operator** documentation for Nagare (流れ, "flow") — the person
who *runs* the platform. It covers both supported operating targets:

- **Cloud mode:** one GCP Compute Engine VM running NixOS/k3s, configured by
  `nagare.target.env`.
- **Local mode:** a k3d cluster, local registry, loopback app domain, and MinIO
  object store, configured by `nagare.local.env` and `NAGARE_MODE=local`.

> If you are instead a **developer deploying an app onto** an already-running
> Nagare, the page you want is [Deploying apps](deploying-apps.md). Everything
> else here is about standing up and operating the platform itself.

For the design rationale behind any choice documented here, see the
[full spec](../initial-spec.md) and the
[MasterPlan](../masterplans/1-bootstrap-nagare-personal-paas.md). This guide is
the operational "how," not the "why."

---

## Status legend

Nagare is being built in waves. Not every component documented here exists yet,
so every page (and many sections) carries a status badge. Read it before you
follow the steps.

| Badge | Meaning |
| --- | --- |
| ✅ **Working** | Implemented and exercised on `nagare-01`. The commands run today. |
| 🟡 **In progress** | Partially implemented; some steps work, some are unfinished or unverified. Caveats are called out inline. |
| 🔭 **Planned** | Designed in the spec but **not built yet**. The page is a *target* runbook describing the intended behavior. Files, recipes, and manifests it references may not exist on disk. |

The mapping to the implementation plans (`docs/plans/`) and their current state:

| Area | Plan | Status |
| --- | --- | --- |
| Repo scaffolding, dev shell | EP-1 | ✅ Working |
| Cloud provisioning (Pulumi) | EP-2 | 🟡 In progress |
| Host image + k3s (NixOS) | EP-3 | 🟡 In progress |
| Cluster bootstrap (Knative/Kourier/cert-manager) | EP-4 | ✅ Working (verified live) |
| Observability (Victoria stack + Grafana) | EP-5 | ✅ Working (verified live) |
| Deploy CLI (`nagarectl`) + typed config DSL | MP-2 (EP-8–12), MP-16 EP-83 | 🟡 Built; cloud and local targets supported |
| Static & full-stack site hosting (`nagarectl site`) | MP-3 (EP-13–18), MP-16 EP-83 | 🟡 Built; cloud and local targets supported |
| CDN integration (Cloudflare / Google Cloud CDN) | MP-11 (EP-54–59) | 🟡 Built; live edge deploy pending |
| Application build modes (Dockerfile/Nixpacks/prebuilt) | MP-4 (EP-19–22), MP-16 EP-83 | 🟡 Built; target-aware image builds |
| App env & secrets (`nagarectl env`/`secret`) | MP-5 (EP-23–28) | 🟡 Built; applies to any active Kubernetes target |
| Application lifecycle (`nagarectl app`/`deployments`) | MP-6 (EP-29–32) | 🟡 Built; live verbs partially pending |
| Persistent storage (Knative PVC volumes) | MP-7 (EP-33–37), MP-16 EP-84 | 🟡 Built; cloud GCS and local MinIO snapshot paths implemented |
| Managed databases (Postgres/Redis/ClickHouse) | MP-9 (EP-43–48), MP-16 EP-84 | 🟡 Built; cloud GCS and local MinIO backup paths implemented |
| Scheduled tasks (`nagarectl task`) | MP-10 (EP-49–53) | 🟡 Built; live run pending |
| Multi-workload apps (`nagarectl app deploy`) + worker liveness | MP-14 (EP-72–74), MP-16 EP-83 | 🟡 Built; target-aware image builds |
| Local development and testing | MP-16 (EP-82–86) | 🟢 Complete and live-verified — local cluster, deploy path, data services, MinIO backups, auth plane + local TLS, and `just local-smoke` |
| Backups, secrets, disaster recovery | EP-7, MP-16 EP-84 | 🟡 DB/volume backup tooling works; full DR drill and some app-specific backups deferred |

The deploy CLI was superseded by a second initiative — the typed Haskell
deployment DSL ([MasterPlan 2](../masterplans/2-type-safe-haskell-deployment-dsl-for-nagarectl.md))
— which replaces the original `nagare.yaml` contract (EP-6) with a typed
`nagare/Config.hs`. The library and CLI are built and tested; the live
end-to-end deploy is deferred until `nagare-01` is powered back on.

The authoritative, always-current status lives in the MasterPlan's **Progress**
section; if this table and the MasterPlan disagree, the MasterPlan wins.

---

## Read in this order

A first-time bring-up follows these pages top to bottom. Each ends in something
you can observe.

**Before you begin (bring your own GCP project):**

- [GCP prerequisites](gcp-prerequisites.md) — gcloud auth + ADC, operator IAM
  roles, project + billing, service-API enablement, DNS delegation. ✅
- [Bring-your-own-project onboarding](onboarding-bring-your-own-project.md) — the
  single ordered zero-to-running runbook centered on `nagarectl init`. ✅
- [Local development](local-development.md) — run Nagare on your laptop with k3d,
  a local registry, HTTP loopback domains, and MinIO backups. 🟡

1. [Getting started](getting-started.md) — prerequisites, the Nix dev shell,
   `direnv`, and the configurable target profile and fail-closed guardrail. ✅
2. [Provisioning with Pulumi](provisioning-with-pulumi.md) — create the cloud
   perimeter: VPC, static IP, DNS, disks, service account, registry, buckets. 🟡
3. [Host image and first boot](host-image-and-boot.md) — build the NixOS GCE
   image on a remote Linux builder, register it, and boot `nagare-01`. 🟡
4. [Accessing the host](accessing-the-host.md) — Tailscale SSH, the IAP tunnel,
   `scripts/iap-ssh.sh`, and getting a working `kubectl`. 🟡
5. [Day-2 host changes](day-2-host-changes.md) — `nixos-rebuild switch` over
   Tailscale and how the host config is laid out. 🟡
   - [Resizing the VM](resizing-the-vm.md) — vertical scale to a bigger machine
     type: bump `machineType`, `pulumi up`, ~1–3 min stop/start. Disks and IP
     persist. 🟡
6. [Cluster bootstrap](cluster-bootstrap.md) — Knative Serving, Kourier ingress,
   cert-manager, and wildcard DNS/TLS wiring. ✅
7. [Observability](observability.md) — VictoriaMetrics/Logs/Traces, the OTel
   Collector, and Grafana. ✅
8. [Deploying apps](deploying-apps.md) — `nagarectl deploy` and the typed
   `nagare/Config.hs`, with the [Config reference](config-reference.md) for the
   full field/constructor catalogue. 🟡
   - [Build modes](build-modes.md) — choose how an app's image is produced:
     prebuilt image, Dockerfile build, or a Dockerfile-free Nixpacks build. 🟡
   - [App lifecycle](app-lifecycle.md) — operate a deployed app without `kubectl`:
     `nagarectl app list/get/logs/restart/stop/delete` and `deployments
     list/logs` (deployment history). 🟡
   - [Static & full-stack site hosting](static-hosting.md) — host a website or a
     full-stack app (TanStack Start) the Cloudflare-Pages way: `nagarectl site
     deploy`, previews, rollbacks, redirects/headers, and Git webhooks. 🟡
   - [Identity-aware access](access.md) — protect a site with `access =
     requireLogin`, install the optional shomei+en+nagare-access auth plane, and
     manage per-host grants with `nagarectl access grant|revoke|list`. 🟡
   - [CDN (edge caching)](cdn.md) — front a static site, a TanStack Start app, or
     any app with Cloudflare or Google Cloud CDN via a typed `cdn` field:
     `nagarectl cdn list|status|purge|disable`, the cache model, and the DNS /
     origin-TLS runbook. 🟡
   - [Environment and secrets](env-and-secrets.md) — manage an app's env vars and
     secrets as a day-2 operation with `nagarectl env`/`secret`: scopes, the managed
     store, `.env` sync, generated `NAGARE_*` vars, build-time and preview env. 🟡
   - [Persistent storage](persistent-storage.md) — attach a durable disk to an app
     with a typed `volumes` declaration: PVC provisioning, `nagarectl storage
     list/inspect/snapshot/restore`, and the backup-ownership policy. 🟡
   - [Managed databases](managed-databases.md) — run a Postgres, Redis, or
     ClickHouse database with `nagarectl db`, connect an app to it by name
     (`DATABASE_URL`/`REDIS_URL`/`CLICKHOUSE_URL` injected from a Secret), and back
     it up to GCS or local MinIO on a schedule. 🟡
   - [Scheduled tasks](scheduled-tasks.md) — run work on a cron schedule or once on
     demand: declare a typed `Task` in an app's `tasks` list, provision a CronJob at
     deploy time, and operate it with `nagarectl task list/run/logs/delete`,
     including app↔task image/env inheritance. 🟡
   - [Running workers](workers.md) — run a continuous background process (a queue
     consumer, a stream processor) with a typed `Worker` and `nagarectl worker
     deploy`: it renders an `apps/v1` Deployment with a fixed replica count, never
     scales to zero, needs no HTTP port, and is operated with stock `kubectl`. 🟡
   - [Messaging brokers](messaging-brokers.md) — provision a Redpanda-backed
     Kafka-compatible broker, create topics, bind workers/apps to topics, inspect
     broker health, and understand the future Tansu provider contract. 🟡
9. [Secrets](secrets.md) — `sops-nix` for the host, `sops`+`age` for the
   cluster. 🟡
10. [Backups and disaster recovery](backups-and-disaster-recovery.md) — what to
    back up, and the "rebuild from zero" runbook. ✅

Plus two references you'll return to:

- [Troubleshooting](troubleshooting.md) — the failures already hit on
  `nagare-01` and their fixes (DNS, the blank data disk, sshd lockouts, the
  macOS IAP bug, …). ✅
- [Reference](reference.md) — Pulumi config keys and stack outputs, `justfile`
  recipes, firewall/ports, the on-disk storage layout, and fixed identifiers. ✅

---

## One target at a time — and it's yours to choose

In cloud mode, Nagare acts on **one** GCP project at a time, but **which**
project is configurable, not hard-coded. The target lives in a git-ignored **target
profile**, `nagare.target.env` (schema in the tracked `nagare.target.env.example`,
which ships `tan-nb-exp` / `us-west1` / `us-west1-a` / `apps.example.com` as the
worked default example). `.envrc` sources it; every script's preflight and
`nagarectl` read it; the guardrail still **fail-closes** — it refuses to run
unless gcloud's active project equals your *configured* target.

To bring your own project from scratch, start at
**[GCP prerequisites](gcp-prerequisites.md)** and
**[Bring-your-own-project onboarding](onboarding-bring-your-own-project.md)**. See
[`CLAUDE.md`](../../CLAUDE.md) for the full configurable-isolation policy,
[Getting started](getting-started.md) for how it's wired, and
[MasterPlan 12](../masterplans/12-bring-your-own-gcp-project-onboarding-for-nagare.md)
for the decision.

In local mode, copy `nagare.local.env.example` to `nagare.local.env`, set
`NAGARE_MODE=local`, and run the local recipes. The GCP project guardrail
intentionally steps aside only in that mode; see
[Local development](local-development.md).
