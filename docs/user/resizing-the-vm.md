# Resizing the VM (vertical scale)

> **Status:** 🟡 In progress (EP-2)
>
> `allowStoppingForUpdate` is set on the `nagare-01` instance, so a
> `machineType` change applies via `pulumi up`. Not yet exercised on a live
> box — the downtime numbers below are estimates, not measurements.

Nagare runs on a **single** Compute Engine VM (`nagare-01`). When the box runs
out of CPU or RAM, you scale it **vertically** — give the same VM a bigger
machine type — rather than adding nodes. This page is the runbook for that.

There is no zero-downtime path: GCP cannot change a VM's machine type while it
is running, so the resize stops and restarts the VM. A single node has nothing
to drain onto, so a brief outage is inherent to the design, not a bug. Expect
**~1–3 minutes** of app unavailability (VM stop + cold boot + k3s/Knative/app
cold-start). Nothing is lost.

---

## What survives a resize

A resize keeps the same VM identity and the same disks, so almost everything is
preserved automatically:

| Thing | Survives? | Why |
| --- | --- | --- |
| Persistent app data (`/var/lib/nagare`) | ✅ | It's a separate `pd-balanced` disk that outlives the VM and reattaches. Holds VictoriaMetrics/Logs/Traces, Postgres, SQLite, backups, and all local-path PVCs. |
| Static external IP | ✅ | A reserved address resource, not tied to the instance. |
| Wildcard DNS (`*.apps.…`) | ✅ | The A record points at the reserved IP, which doesn't change. No propagation wait. |
| k3s cluster state (`/var/lib/rancher`) | ✅ | Lives on the **boot disk**, which the resize keeps. (A *replacement* VM with a fresh boot disk would lose this — that's a different, harder operation, not covered here.) |
| Running app state in memory | ❌ | The VM stops. Apps cold-start on restart. |

Because the disks and IP are stable, a resize moves **no data** and changes
**no DNS** — it only swaps the underlying hardware shape.

### Managed databases

Managed databases (`nagarectl db`) are **single-replica StatefulSets** with a
`local-path` PVC (`nagare-db-<name>-data`) mounted at the engine's data path.
That PVC lives under `/var/lib/nagare/local-path` on the data disk, so the
**data survives** the resize and the same volume reattaches on restart — no
migration, no dump/restore.

What a resize *does* affect is **availability**. The database pod stops with the
node and is unreachable for the same ~1–3 min window. Unlike a Knative app
(which scales to zero anyway), a database is something you expect to be up, so:

- **Apps will see the connection drop** and must reconnect. Connection pools
  recover on their own; long-lived sessions may error once.
- **Take a backup first** (step 3). The VM gets a graceful ACPI shutdown, so the
  engine normally flushes cleanly — but if shutdown is cut short, restart relies
  on the engine's crash recovery (e.g. Postgres WAL replay). A fresh backup is
  cheap insurance against that.

After the box comes back, confirm the engine is actually serving (not just that
the pod is Running) — `pg_isready` / `redis-cli ping` / a ClickHouse `SELECT 1`.

---

## Choose a machine type

The default is `e2-standard-2` (2 vCPU / 8 GB). Pick a bigger type from the same
or a higher family. Common upgrades:

| Type | vCPU | Memory | Notes |
| --- | --- | --- | --- |
| `e2-standard-2` | 2 | 8 GB | Current default |
| `e2-standard-4` | 4 | 16 GB | Cheapest next step up |
| `n2-standard-4` | 4 | 16 GB | Newer family, more consistent perf |
| `n2-standard-8` | 8 | 32 GB | For a busy box with several apps + databases |

Check current pricing and availability in `us-west1` before committing — `e2`
is the cost-optimized family; `n2`/`n2d` cost more but perform more predictably.

> A machine-type change is **not** the same as a CPU-family change that requires
> a new image. Resizing within or across families that share the boot image
> (the case for `e2`/`n2`/`n2d` on x86_64) is the in-place operation below.

---

## Resize, step by step

1. **Confirm you're targeting `tan-nb-exp`.** Every cloud call in this repo must
   hit that project (see [Getting started](getting-started.md)). The dev shell's
   `.envrc` sets this; `pulumi` reads it from stack config.

2. **Preview the change.** Set the new type and see exactly what Pulumi will do:

   ```bash
   pulumi -C infra/pulumi config set machineType n2-standard-4
   just infra-preview
   ```

   The plan should show a single **update** to `nagare-01`'s `machineType` — an
   `~ machineType` diff, **not** a `+/- replace`. If you see a replacement, stop:
   you've changed something that forces re-creation (e.g. zone or image), which
   would destroy the boot disk and cluster state. Back the change out and
   investigate before proceeding.

3. **(Optional but recommended) quiesce.** A resize is graceful — the VM gets a
   clean ACPI shutdown — but if you run a managed database, take a backup first
   so you have a known-good restore point regardless:

   ```bash
   nagarectl db backup <name>     # see Managed databases
   ```

4. **Apply.** This stops the VM, changes the machine type, and restarts it:

   ```bash
   just infra-up                  # = cd infra/pulumi && pulumi up
   ```

   Pulumi can do this only because `allowStoppingForUpdate: true` is set on the
   instance (`infra/pulumi/src/components/NagareInstance.ts`). Without it the
   update would fail with a "machine type cannot be changed on a running
   instance" error.

5. **Wait for the box to come back.** The VM boots, the data disk remounts at
   `/var/lib/nagare`, k3s starts from its boot-disk state, and Knative restores
   the app pods. Watch readiness:

   ```bash
   ssh deploy@nagare-01 'kubectl get nodes,pods -A'
   ```

   The node should report the new CPU/memory (`kubectl describe node` →
   `Capacity`).

6. **Confirm an app responds** at its `*.apps.…` URL. No DNS change was made, so
   it should resolve immediately once the pod is Ready.

---

## Rollback

If the bigger type misbehaves (or you want the cheaper box back), the resize is
fully reversible — set the type back and re-apply:

```bash
pulumi -C infra/pulumi config set machineType e2-standard-2
just infra-up
```

Same stop/start window, same preserved disks and IP.

---

## What this does *not* cover

- **Adding nodes / horizontal scale.** Out of scope by design — Nagare is a
  single-node PaaS. True zero-downtime would require a second node and a
  fundamental architecture change (record it in the
  [MasterPlan](../masterplans/1-bootstrap-nagare-personal-paas.md) Decision Log
  first).
- **Replacing the VM with a fresh boot disk** (e.g. a from-scratch rebuild or a
  move that re-creates the instance). That loses k3s's on-disk cluster state and
  needs a cluster reconcile — see
  [Backups and disaster recovery](backups-and-disaster-recovery.md), not this
  page.
- **Resizing the disks.** Growing `/var/lib/nagare` is a `dataDiskSizeGb` change
  plus an online filesystem grow — a separate operation from the machine type.
