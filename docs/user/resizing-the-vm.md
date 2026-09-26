---
type: Runbook
title: "Resizing the VM (vertical scale)"
description: "Resize the Nagare virtual machine safely, verify retained state, and roll back an unsuitable machine type."
docId: DOC-30
tags: [gcp, vm, scaling, maintenance, rollback]
generated:
  by: human:nadeem
  at: 2026-09-12T21:26:55Z
---

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

1. **Confirm you're targeting the intended context.** Every cloud call acts only
   on the active context's project (see [Contexts](contexts.md)). Check it with
   `nagarectl context current`; the dev shell's `.envrc` exports that context's
   project, and the Pulumi stack name is the context name.

2. **Record and preview the change.** The context is the durable owner of the
   machine type. Edit `NAGARE_MACHINE_TYPE` in
   `${XDG_CONFIG_HOME:-$HOME/.config}/nagare/contexts/<context>.env`, then
   regenerate the Pulumi projection and preview it:

   ```bash
   context="$(nagarectl context current)"
   # Edit .../nagare/contexts/$context.env: export NAGARE_MACHINE_TYPE=n2-standard-4
   nagarectl context use "$context"
   just infra-preview
   ```

   When creating a context for the first time, pass
   `nagarectl context create ... --machine-type n2-standard-4 --use` instead.
   `pulumi -C infra/pulumi config set machineType n2-standard-4` remains a
   one-off override, but it is replaced by the context value on the next
   `nagarectl context use`.

   The plan should show a single **update** to `nagare-01`'s `machineType` — an
   `~ machineType` diff, **not** a `+/- replace`. `infra-up` now runs
   `nagarectl infra guard`, so a replacement is refused rather than merely
   warned about. If the preview shows one, back the change out and investigate.

3. **(Optional but recommended) quiesce.** A resize is graceful — the VM gets a
   clean ACPI shutdown — but if you run a managed database, take a backup first
   so you have a known-good restore point regardless:

   ```bash
   nagarectl db backup <name> --backup-id pre-resize-001 --save-plan ./pre-resize-backup
   nagarectl inventory apply ./pre-resize-backup --yes
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
- **Resizing the disks.** Growing `/var/lib/nagare` is covered below in
  [Growing the data disk](#growing-the-data-disk). Changing the **boot**-disk size replaces the VM
  and its boot-resident k3s state, so size it for the VM lifetime and follow the deliberate rebuild
  procedure if a replacement is unavoidable. Neither disk can shrink.

---

## Growing the data disk

`/var/lib/nagare` is a separate Persistent Disk (`nagare-data`) holding every
app volume, the observability stores, database data, and local backups. Growing
it has two parts: make the **disk** bigger, then make the **filesystem** on it
fill the new space. The first is a Pulumi config change. The second happens by
itself on every boot, because the mount carries `x-systemd.growfs`, and takes
one command on a host you do not want to reboot.

**Before growing, find the consumer.** The observability stores are capped
(logs 15 GiB and 7 days, traces 8 GiB and 3 days, metrics 30 days), so steady
growth is app volumes, database data, or backups:

```bash
scripts/iap-ssh.sh ssh nagare-01 -- 'df -h /var/lib/nagare; sudo du -sh /var/lib/nagare/* | sort -h'
```

**A grow is permanent.** A Persistent Disk can never be shrunk (see
[Shrinking is impossible](#shrinking-is-impossible)).

1. **Confirm the context, and that the host runs a configuration with
   auto-grow.** `nagarectl context current` must name the intended context. The
   host's `/etc/fstab` must carry `x-systemd.growfs` for `/var/lib/nagare`:

   ```bash
   scripts/iap-ssh.sh ssh nagare-01 -- 'grep nagare /etc/fstab'
   ```

   ```text
   /dev/disk/by-id/google-nagare-data /var/lib/nagare ext4 x-systemd.growfs,defaults,nofail 0 2
   ```

   If it does not, apply the current platform configuration first with
   `just host-switch` (see [Day-2 host changes](day-2-host-changes.md)). Never
   switch a host with the in-repo `nixos/` flake: it is an evaluation fixture and
   refuses activation.

2. **Set the new size and preview.** Sizes are in GiB:

   ```bash
   STACK="$(nagarectl context current)"
   pulumi -C infra/pulumi config set nagare:dataDiskSizeGb 110 --stack "$STACK"
   just infra-preview
   ```

   The plan must be exactly one in-place **update** (`~`) of the data disk. This
   is the recorded output of a 100 → 110 GiB change:

   ```text
       ~ gcp:compute/disk:Disk: (update) 🔒
           [id=projects/<project>/zones/<zone>/disks/nagare-data-8183a3e]
           [urn=urn:pulumi:<context>::nagare::nagare:env:NagarePerimeter$gcp:compute/disk:Disk::nagare-data]
         ~ size: 100 => 110
   Resources:
       ~ 1 to update
       30 unchanged
   ```

   If you see `+-` (replace) or `-` (delete) anywhere, **stop**, run
   `pulumi -C infra/pulumi config rm nagare:dataDiskSizeGb --stack "$STACK"`, and
   investigate.

3. **Apply.** `just infra-up`. The disk resizes online in seconds with no
   restart. The filesystem does **not** grow yet. `lsblk` shows the bigger device
   while `df` still shows the old size:

   ```text
   Filesystem      Size  Used Avail Use% Mounted on
   /dev/sdb         98G  212M   93G   1% /var/lib/nagare
   sdb  110G
   ```

   The grow only runs when the filesystem is mounted, and `/var/lib/nagare` has
   been mounted since boot.

4. **Grow the filesystem now** (or simply reboot later). ext4 grows online, with
   no unmount and no downtime:

   ```bash
   scripts/iap-ssh.sh ssh nagare-01 -- 'sudo systemctl restart systemd-growfs@var-lib-nagare.service; df -h /var/lib/nagare'
   ```

   ```text
   Filesystem      Size  Used Avail Use% Mounted on
   /dev/sdb        108G  212M  103G   1% /var/lib/nagare
   ```

   Use **`restart`**, not `start`. The unit already ran at boot and stays
   `active (exited)`, so `systemctl start` silently does nothing and exits 0.
   `df` reports a little less than the disk size because of ext4 metadata.

5. **Confirm the cluster is healthy.**

   ```bash
   scripts/iap-ssh.sh ssh nagare-01 -- 'sudo k3s kubectl get nodes; sudo k3s kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded'
   ```

   Expect the node `Ready` and no pod failing that was not failing before.

### Shrinking is impossible

Google Persistent Disks cannot shrink, so a smaller `dataDiskSizeGb` can only be
satisfied by deleting the disk and creating a new one, which would destroy every
byte on it. The data disk is declared with `protect: true`, and Pulumi refuses:

```text
error: unable to replace resource "urn:pulumi:<context>::nagare::nagare:env:NagarePerimeter$gcp:compute/disk:Disk::nagare-data"
as it is currently marked for protection. To unprotect the resource, remove the `protect` flag from the resource in your Pulumi program and run `pulumi up`
error: preview failed
```

`protect: true` protects a resource only once a `pulumi up` has written the flag
into the stack's **state**. A stack created before the flag existed previews a
decrease as a plain `+-` replace, with no error, until its next `pulumi up`. If
you ever set a smaller size by mistake, run
`pulumi -C infra/pulumi config set nagare:dataDiskSizeGb <current size> --stack "$STACK"`
and preview again.
