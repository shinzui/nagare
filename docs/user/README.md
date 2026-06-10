# Nagare operator guide

This is the **operator** documentation for Nagare (流れ, "flow") — the person
who *runs* the platform: provisioning the cloud, building and booting the host,
bootstrapping the cluster, installing observability, operating day-2, and
recovering the box from scratch.

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
| Cluster bootstrap (Knative/Kourier/cert-manager) | EP-4 | 🔭 Planned |
| Observability (Victoria stack + Grafana) | EP-5 | 🔭 Planned |
| Deploy CLI (`nagarectl`) + typed config DSL | MP-2 (EP-8–12) | 🟡 Built; live deploy pending |
| Static & full-stack site hosting (`nagarectl site`) | MP-3 (EP-13–18) | 🟡 Built; live deploy pending |
| Backups, secrets, disaster recovery | EP-7 | 🔭 Planned |

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

1. [Getting started](getting-started.md) — prerequisites, the Nix dev shell,
   `direnv`, and the hard rule that every cloud call targets `tan-nb-exp`. ✅
2. [Provisioning with Pulumi](provisioning-with-pulumi.md) — create the cloud
   perimeter: VPC, static IP, DNS, disks, service account, registry, buckets. 🟡
3. [Host image and first boot](host-image-and-boot.md) — build the NixOS GCE
   image on a remote Linux builder, register it, and boot `nagare-01`. 🟡
4. [Accessing the host](accessing-the-host.md) — Tailscale SSH, the IAP tunnel,
   `scripts/iap-ssh.sh`, and getting a working `kubectl`. 🟡
5. [Day-2 host changes](day-2-host-changes.md) — `nixos-rebuild switch` over
   Tailscale and how the host config is laid out. 🟡
6. [Cluster bootstrap](cluster-bootstrap.md) — Knative Serving, Kourier ingress,
   cert-manager, and wildcard DNS/TLS wiring. 🔭
7. [Observability](observability.md) — VictoriaMetrics/Logs/Traces, the OTel
   Collector, and Grafana. 🔭
8. [Deploying apps](deploying-apps.md) — `nagarectl deploy` and the typed
   `nagare/Config.hs`, with the [Config reference](config-reference.md) for the
   full field/constructor catalogue. 🟡
   - [Build modes](build-modes.md) — choose how an app's image is produced:
     prebuilt image, Dockerfile build, or a Dockerfile-free Nixpacks build. 🟡
   - [Static & full-stack site hosting](static-hosting.md) — host a website or a
     full-stack app (TanStack Start) the Cloudflare-Pages way: `nagarectl site
     deploy`, previews, rollbacks, redirects/headers, and Git webhooks. 🟡
9. [Secrets](secrets.md) — `sops-nix` for the host, `sops`+`age` for the
   cluster. 🟡
10. [Backups and disaster recovery](backups-and-disaster-recovery.md) — what to
    back up, and the "rebuild from zero" runbook. 🔭

Plus two references you'll return to:

- [Troubleshooting](troubleshooting.md) — the failures already hit on
  `nagare-01` and their fixes (DNS, the blank data disk, sshd lockouts, the
  macOS IAP bug, …). ✅
- [Reference](reference.md) — Pulumi config keys and stack outputs, `justfile`
  recipes, firewall/ports, the on-disk storage layout, and fixed identifiers. ✅

---

## The one rule that overrides everything

**Every cloud resource and every read targets the `tan-nb-exp` GCP project,
region `us-west1`, zone `us-west1-a`.** No command in this repo may touch
another project — not even a `list` or `describe`. This is enforced by `.envrc`,
a preflight check in each script, and an explicit `--project` flag on every
`gcloud` call. See [`CLAUDE.md`](../../CLAUDE.md) for the full policy and
[Getting started](getting-started.md) for how it's wired.
