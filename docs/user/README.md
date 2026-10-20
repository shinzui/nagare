---
type: Navigation
title: "Nagare operator guide"
description: "Route operators and developers through Nagare setup, deployment, platform operations, and reference documentation."
docId: DOC-1
tags: [nagare, navigation, operator-guide]
generated:
  by: human:nadeem
  at: 2026-08-26T00:31:47Z
---

# Nagare operator guide

This is the **operator** documentation for Nagare (流れ, "flow"): for the people
who *run* the platform, whether for personal projects or a team's workplace
intranet. Nagare's tooling assumes one operator acts at a time
([ADR 28](../adr/0028-the-intranet-stays-single-node-with-hourly-recovery-points-and-a-four-hour-rebuild.md));
team operation is tracked in
[MasterPlan 24](../masterplans/24-operate-nagare-as-a-team-run-workplace-intranet-paas.md).
It covers both supported operating targets:

- **Cloud mode:** one GCP Compute Engine VM running NixOS/k3s, configured by
  the active target context (or, for back compatibility, `nagare.target.env`).
- **Local mode:** a k3d cluster, local registry, loopback app domain, and MinIO
  object store, configured by a `mode=local` context (or, for back
  compatibility, `nagare.local.env`).

> If you are instead a **developer deploying an app onto** an already-running
> Nagare, the page you want is [Deploying apps](deploying-apps.md). Everything
> else here is about standing up and operating the platform itself.

## Where status lives

The current release is [Nagare 0.8.0](../releases/v0.8.0.md); every release has
notes in [`docs/releases/`](../releases/). What ships is cataloged, with
evidence, in the [capability catalog](../capabilities/index.md). The drills that
prove day-to-day operation, data recovery, and upgrades are recorded in the
[production readiness checklist](../releases/production-readiness-checklist.md).
For the original design rationale, see the
[initial spec](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/initial-spec.md).

Pages and sections carry a badge:

| Badge | Meaning |
| --- | --- |
| ✅ **Working** | Implemented and exercised on a real context. |
| 🟢 **Complete** | Implemented and verified on its supported target; no planned work remains. |
| 🟡 **In progress** | Partially implemented or partially verified; caveats are called out inline. |
| 🔭 **Planned** | Not built yet; the page describes intended behavior. |

---

## Read in this order

A first-time bring-up follows these pages top to bottom. Each ends in something
you can observe.

**Before you begin (bring your own GCP project):**

- [Installing Nagare](installation.md) — choose the pinned app-developer or full
  operator package without cloning the repository. ✅
- [Nagare guides](../guides/README.md) — goal-oriented walkthroughs that combine
  the manual's individual features into complete operating patterns.
  [Running multiple clusters](../guides/running-multiple-clusters.md) covers
  `prod`, `labs`, and `local` isolation. ✅
- [GCP prerequisites](gcp-prerequisites.md) — gcloud auth + ADC, operator IAM
  roles, project + billing, service-API enablement, DNS delegation. ✅
- [Bring-your-own-project onboarding](onboarding-bring-your-own-project.md) — the
  single ordered zero-to-running runbook centered on `nagarectl init`. ✅
- [Local development](local-development.md) — run Nagare on your laptop with k3d,
  a local registry, HTTP loopback domains, and MinIO backups. 🟢

1. [Getting started](getting-started.md) — prerequisites, a pinned Nix release,
   active target contexts, and the fail-closed guardrail. ✅
2. [Target contexts](contexts.md) — define `prod`, `labs`, or `local` targets,
   switch with `nagarectl context use`, and select one command with
   `--context` / `NAGARE_CONTEXT`. ✅
   - [Resource inventory and operation ledger](resource-inventory.md) — understand
     ownership scopes, saved reviews, status, interruption recovery, and retained
     resources before changing an inventory-backed context. ✅
3. [Provisioning with Pulumi](provisioning-with-pulumi.md) — create the cloud
   perimeter: VPC, static IP, DNS, disks, service account, registry, buckets. 🟡
4. [Host image and first boot](host-image-and-boot.md) — build the NixOS GCE
   image on a remote Linux builder, register it, and boot `nagare-01`. 🟡
5. [Accessing the host](accessing-the-host.md) — Tailscale SSH, the IAP tunnel,
   `scripts/iap-ssh.sh`, and getting a working `kubectl`. 🟡
6. [Day-2 host changes](day-2-host-changes.md) — reviewed, self-reverting host
   changes through `nagarectl host apply` and `just host-switch`, and how the host
   config is laid out. 🟡
   - [Upgrades](upgrades.md) — move an installed context to a new release through
     a reviewed transition, inspect release identity, and upgrade the node and
     PostgreSQL majors. ✅
   - [Resizing the VM](resizing-the-vm.md) — vertical scale to a bigger machine
     type: bump `machineType`, `pulumi up`, ~1–3 min stop/start. Disks and IP
     persist. 🟡
7. [Cluster bootstrap](cluster-bootstrap.md) — Knative Serving, Kourier ingress,
   cert-manager, and wildcard DNS/TLS wiring. ✅
   - [In-cluster Nix binary cache](nix-binary-cache.md) — optionally transport
     signed Nix closures from trusted producers to build-disabled Jobs. 🟡
8. [Observability](observability.md) — VictoriaMetrics/Logs/Traces, the OTel
   Collector, and Grafana. ✅
   - [Protecting observability UIs](protecting-observability-uis.md) — publish
     Grafana, and optionally VictoriaTraces, through the shared
     Shomei/en-backed `nagare-access` enforcer instead of exposing them
     directly. 🟡
9. [Deploying apps](deploying-apps.md) — `nagarectl deploy` and the typed
   `nagare/Config.hs`, with the [Config reference](config-reference.md) for the
   full field/constructor catalogue. 🟡
   - [Using kubefwd for development](kubefwd-development.md) — run one service
     locally while it calls deployed Nagare databases, brokers, platform
     services, or peer microservices through their normal `*.svc.cluster.local`
     names. 🟡
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
     it up to GCS or local MinIO on a schedule. Many apps can share one PostgreSQL
     or ClickHouse server as app databases, each with its own users, reviewed
     grant exceptions and limits, maintenance window, backups, and read-only
     readers for other apps. 🟡
   - [Scheduled tasks](scheduled-tasks.md) — run work on a cron schedule or once on
     demand: declare a typed `Task` in an app's `tasks` list, provision a CronJob at
     deploy time, and operate it with `nagarectl task list/run/logs/delete`,
     including app↔task image/env inheritance. 🟡
   - [Running workers](workers.md) — run a continuous background process (a queue
     consumer, a stream processor) with a typed `Worker` and `nagarectl worker
     deploy`: it renders an `apps/v1` Deployment with a fixed replica count, never
     scales to zero, needs no HTTP port, and is operated with stock `kubectl`. 🟡
   - [Bounded one-shot jobs](one-shot-jobs.md) — describe one finite execution
     with a typed `Job`, hardened Pod defaults, temporary scratch space, and a
     deadline-based two-slot namespace quota. The DSL and cluster contract are
     complete; a scheduler or platform integration currently owns rendering and
     applying it because `nagarectl job` does not exist yet. 🟢
   - [Messaging brokers](messaging-brokers.md) — provision a Redpanda-backed
     Kafka-compatible broker, create topics, bind workers/apps to topics, inspect
     broker health, and understand the future Tansu provider contract. 🟡
10. [Secrets](secrets.md) — `sops-nix` for the host, `sops`+`age` for the
   cluster. 🟡
   - [Forge credentials](forge-credentials.md) — opt in to rotating, role-named
     GitHub App installation tokens using operator-owned registrations and
     encrypted context inputs. 🟢
11. [Backups and disaster recovery](backups-and-disaster-recovery.md) — what to
    back up, and the "rebuild from zero" runbook. 🟡

Plus two references you'll return to:

- [Troubleshooting](troubleshooting.md) — the failures already hit on
  `nagare-01` and their fixes (DNS, the blank data disk, sshd lockouts, the
  macOS IAP bug, …). ✅
- [Reference](reference.md) — Pulumi config keys and stack outputs, `justfile`
  recipes, firewall/ports, the on-disk storage layout, and fixed identifiers. ✅

---

## One target at a time — and it's yours to choose

In cloud mode, Nagare acts on **one** GCP project per command, but **which**
project is configurable, not hard-coded. The target is the active
[context](contexts.md): a named bundle in
`${XDG_CONFIG_HOME:-$HOME/.config}/nagare/contexts/`, selected by
`nagarectl --context NAME`, `NAGARE_CONTEXT=NAME`, or
`nagarectl context use NAME`. The guardrail still **fail-closes** — cloud
scripts refuse an ambient project override that disagrees with the context's
declared project; without a declared project, they cross-check gcloud's stored
configuration with the effective target.

The old git-ignored target profile, `nagare.target.env`, still works as a
back-compatible fallback when no context is selected. With no context and no
profile, the built-in defaults reproduce the original `tan-nb-exp` /
`us-west1` / `apps.example.com` worked example.

To bring your own project from scratch, start at
**[GCP prerequisites](gcp-prerequisites.md)** and
**[Bring-your-own-project onboarding](onboarding-bring-your-own-project.md)**. See
[`CLAUDE.md`](../../CLAUDE.md) for the full configurable-isolation policy,
[Getting started](getting-started.md) for how it's wired, and
[MasterPlan 17](../masterplans/17-first-class-target-contexts-for-nagare.md)
for the context model.

In local mode, select a `mode=local` context and run the local recipes. The GCP
project guardrail intentionally steps aside only for local contexts after
checking the target is loopback; see [Local development](local-development.md).
