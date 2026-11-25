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

> **Status:** ✅ Exercised on 2026-11-23, when the Labs intranet went from
> `n2-standard-4` to `n2-standard-8` through the two reviewed bootstrap stages
> below. The VM was stopped for about 30 seconds and the intranet was
> unavailable for about 5 minutes.

Nagare runs on a **single** Compute Engine VM (`nagare-01`). When the box runs
out of CPU or RAM, you scale it **vertically** — give the same VM a bigger
machine type — rather than adding nodes. This page is the runbook for that.

There is no zero-downtime path: GCP cannot change a VM's machine type while it
is running, so the resize stops and restarts the VM. A single node has nothing
to drain onto, so a brief outage is inherent to the design, not a bug. Expect
**about 5 minutes** of app unavailability. On Labs the VM itself was stopped for
about 30 seconds; the rest was the cold boot and the k3s, Knative and app cold
start. The reviewed apply that drives it took about 7 minutes in all. Nothing
is lost.

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
node and is unreachable for the same window of about 5 minutes. Unlike a Knative app
(which scales to zero anyway), a database is something you expect to be up, so:

- **Apps will see the connection drop** and must reconnect. Connection pools
  recover on their own; long-lived sessions may error once.
- **Take a restore point first** (step 3). The VM gets a graceful ACPI shutdown, so the
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

Every current cloud context keeps a resource inventory: its Pulumi stack, config
keys included, is the inventory's "cloud foundation", and only a reviewed plan
changes it. The resize is therefore two reviewed `platform bootstrap` stages.
Stage 1 writes the new machine type into the stack config. Stage 2 applies it to
the VM. Stage 2 cannot be planned until stage 1 has converged, because its Pulumi
preview is computed from the config stage 1 writes.

`nagarectl context use` does **not** write the new type on such a context. It
prints `Cloud foundation awaits a reviewed platform bootstrap plan.` and stops,
and `just infra-up` (`nagarectl infra apply`) refuses. For a context without
inventory history, see
[Contexts without inventory history](#contexts-without-inventory-history).

Run every command from the operator repository's root, in its direnv shell, so
`NAGARE_CONTEXT`, `CLOUDSDK_COMPUTE_ZONE` and `NAGARE_INSTANCE_NAME` name the
target.

1. **Confirm the context, and that nothing else is operating it.** Every cloud
   call acts only on the active context's project (see [Contexts](contexts.md)).
   Tell developers the intranet is going down for a few minutes. Then check that
   no transaction is open:

   ```bash
   context="$(nagarectl context current)"
   nagarectl context guard
   nagarectl inventory store status --json | jq -c '{generation, activeTransaction, executorClaim}'
   ```

   ```text
   {"generation":<n>,"activeTransaction":null,"executorClaim":null}
   ```

   Both must be `null`. If either names a transaction, another session holds the
   store: wait for it, or follow
   [Operate and recover a reviewed inventory](../runbooks/inventory-operations.md)
   if it has stopped. Do not start the resize over it. A report with
   `"state": "unsupported-schema"` and no `activeTransaction` key comes from a
   CLI older than the store, and says nothing about transactions. Releases up to
   0.28.2 reported every schema-2 head that way. On such a CLI, read `head.json`
   from the inventory bucket with `jq '{activeTransaction, executorClaim}'`.

2. **Edit the context line.** The context owns the machine type
   ([ADR 14](../adr/0014-the-active-context-owns-the-vm-shape.md)). Edit
   `NAGARE_MACHINE_TYPE` in
   `${XDG_CONFIG_HOME:-$HOME/.config}/nagare/contexts/$context.env`:

   ```diff
   -export NAGARE_MACHINE_TYPE='n2-standard-4'
   +export NAGARE_MACHINE_TYPE='n2-standard-8'
   ```

   Reload the shell (`direnv reload`). When creating a context for the first
   time, pass `nagarectl context create ... --machine-type n2-standard-8 --use`
   instead. Never use `pulumi config set`: the next bootstrap stage writes the
   context value over it.

3. **Take a restore point.** The resize does not touch the data disk, but a
   snapshot taken seconds before the stop is one crash-consistent point for every
   database and volume on it:

   ```bash
   disk="$(gcloud compute instances describe "$NAGARE_INSTANCE_NAME" \
     --format=json | jq -r '.disks[] | select(.boot | not) | .source | split("/") | last')"
   gcloud compute disks snapshot "$disk" --snapshot-names "$disk-pre-resize-$(date -u +%Y%m%d)"
   gcloud compute snapshots describe "$disk-pre-resize-$(date -u +%Y%m%d)" --format='value(status)'
   ```

   ```text
   READY
   ```

   Delete it after a week of healthy running. A logical backup of one managed
   database (`nagarectl db backup … --save-plan`, then `inventory apply`) is an
   alternative when only that database matters.

4. **Stage 1: write the stack config.** Plan a fresh review. A review saved
   before step 1 is stale and is refused at apply.

   ```bash
   R1=~/.local/state/nagare/$context/reviews/resize-stage1-$(date -u +%Y%m%dT%H%M)
   nagarectl platform bootstrap plan --out "$R1"
   jq '.operations | length' "$R1/review.json"
   jq -r '.operations[0].summary' "$R1/review.json" | tr ';' '\n' | grep machineType
   ```

   ```text
   1
    pulumi -C …/infra/pulumi config set --stack <context> nagare:machineType n2-standard-8
   ```

   The review must hold exactly one operation: a `CloudFoundationExecutor`
   `UpdateResource` of `platform:cloud-foundation/pulumi-stack/<context>`, whose
   summary sets `nagare:machineType` to the new type. If it holds anything else,
   stop: something other than the machine type is pending. Otherwise apply it.
   Nothing restarts yet.

   ```bash
   nagarectl platform bootstrap apply "$R1" --yes
   ```

5. **Optional cross-check.** `nagarectl infra preview --save-plan "$P"` is
   read-only and still works. It must show one `update` of
   `gcp:compute/instance:Instance`, `machineType` old → new, and no `replace` or
   `delete`. Its bundle cannot be applied on this context: `infra apply` refuses.

6. **Stage 2: apply the type to the VM.** The outage starts here. The review
   holds one `PulumiExecutor` operation per cloud resource, and only the VM may
   declare a mutation:

   ```bash
   R2=~/.local/state/nagare/$context/reviews/resize-stage2-$(date -u +%Y%m%dT%H%M)
   nagarectl platform bootstrap plan --out "$R2"
   jq -r '.operations[] | (.operation.resources[0]) + "  " + (.summary | capture("; (?<n>[0-9]+) declared").n)' "$R2/review.json" | grep -v '  0$'
   ```

   ```text
   platform:cloud/nagare-instance-vm/<instance>  1
   ```

   Any other line is a change you did not intend: stop. Otherwise apply:

   ```bash
   date -u; nagarectl platform bootstrap apply "$R2" --yes; date -u
   ```

   On Labs this took about 7 minutes and ended with `converged tx-…`. GCE stops
   the VM, changes the type and starts it again. Pulumi can do that only because
   `allowStoppingForUpdate: true` is set on the instance
   (`infra/pulumi/src/components/NagareInstance.ts`).

   **If a plan is refused because another writer manages a field** (`Kubernetes
   object has fields managed by another writer: …`), stop. Nothing was written.
   Follow
   [Repair configuration drift](../runbooks/inventory-operations.md#repair-configuration-drift)
   to decide about that edit, then plan the stage again. Do not add
   `--take-over-fields` as a routine part of a resize.

7. **Check the box came back.**

   ```bash
   gcloud compute instances describe "$NAGARE_INSTANCE_NAME" --format='value(machineType.basename(),status)'
   kubectl get nodes
   kubectl describe node | sed -n '/^Capacity/,/^Allocatable/p'
   kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
   ```

   ```text
   n2-standard-8	RUNNING
   <node>   Ready …
     cpu:                8
     memory:             32864324Ki
   ```

   Expect no failing pod that was not failing before. If the node is not `Ready`
   within 10 minutes, read
   `gcloud compute instances get-serial-port-output "$NAGARE_INSTANCE_NAME" | tail -100`
   and stop. Report rather than act. Then:

   - `nagarectl server status` is `OK` apart from the rows that were not `OK`
     before the resize.
   - Every managed database answers a client query, not only a `Running` pod:
     `pg_isready`, `redis-cli ping`, or a ClickHouse `SELECT 1`.
   - The host booted the configuration it was switched to. Both paths must be the
     same:

     ```bash
     scripts/iap-ssh.sh ssh "$NAGARE_INSTANCE_NAME" -- 'readlink /run/booted-system /run/current-system'
     ```

   - An app responds at its `*.apps.…` URL, and a developer can sign in. No DNS
     changed, so it resolves as soon as the pod is Ready.

8. **Commit the context line** in the operator repository.

---

## Rollback

The resize is fully reversible. Set `NAGARE_MACHINE_TYPE` back to the old type
and run steps 4 to 7 again: stage 1 with the old value, then stage 2. It costs
the same stop/start, and the disks and IP survive. Never roll back with
`pulumi config set`: the next stage writes the context value over it.

If GCE refuses to start the new type (for example
`ZONE_RESOURCE_POOL_EXHAUSTED`), roll back the same way. Never start the VM by
hand with another type, and never use a startup script.

---

## Contexts without inventory history

A context whose inventory store records no history (older contexts that never
ran a reviewed plan) still uses the legacy Pulumi path. You are on the inventory
path above if `just infra-up` refuses with:

```text
this context has resource inventory history or transaction state; legacy infra apply cannot safely mutate it. Use a reviewed inventory command
```

On a context without history, edit the context line as in step 2, then:

```bash
nagarectl context use "$context"   # seeds nagare:machineType into the stack
just infra-preview                 # one ~ machineType update, no +/- replace
just infra-up
```

`infra-up` runs `nagarectl infra guard`, so a replacement is refused rather than
merely warned about. If the preview shows one, back the change out and
investigate. Then check the box as in step 7.

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
fill the new space. The first is the same two reviewed bootstrap stages as a
machine-type change, driven by the context line `NAGARE_DATA_DISK_SIZE_GB`. The
second happens by itself on every boot, because the mount carries `x-systemd.growfs`, and takes
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

2. **Set the new size in the context.** Sizes are in GiB. Edit
   `${XDG_CONFIG_HOME:-$HOME/.config}/nagare/contexts/$context.env`, then reload
   the shell:

   ```diff
   -export NAGARE_DATA_DISK_SIZE_GB='100'
   +export NAGARE_DATA_DISK_SIZE_GB='110'
   ```

   Check that no transaction is open, as in step 1 of
   [Resize, step by step](#resize-step-by-step).

3. **Stage 1: write the stack config.**

   ```bash
   R1=~/.local/state/nagare/$context/reviews/grow-stage1-$(date -u +%Y%m%dT%H%M)
   nagarectl platform bootstrap plan --out "$R1"
   jq '.operations | length' "$R1/review.json"
   jq -r '.operations[0].summary' "$R1/review.json" | tr ';' '\n' | grep dataDiskSizeGb
   ```

   It must hold exactly one operation, whose summary sets
   `nagare:dataDiskSizeGb 110`. Anything else: stop. Then
   `nagarectl platform bootstrap apply "$R1" --yes`.

   `nagarectl infra preview` is a read-only cross-check. It must show exactly one
   in-place **update** (`~`) of the data disk. This is the recorded output of a
   100 → 110 GiB change:

   ```text
       ~ gcp:compute/disk:Disk: (update) 🔒
           [id=projects/<project>/zones/<zone>/disks/nagare-data-8183a3e]
           [urn=urn:pulumi:<context>::nagare::nagare:env:NagarePerimeter$gcp:compute/disk:Disk::nagare-data]
         ~ size: 100 => 110
   Resources:
       ~ 1 to update
       30 unchanged
   ```

   If you see `+-` (replace) or `-` (delete) anywhere, **stop**, set
   `NAGARE_DATA_DISK_SIZE_GB` back to the current size, run stage 1 again, and
   investigate.

4. **Stage 2: resize the disk.** Plan, and check that the data disk is the only
   resource with a declared mutation:

   ```bash
   R2=~/.local/state/nagare/$context/reviews/grow-stage2-$(date -u +%Y%m%dT%H%M)
   nagarectl platform bootstrap plan --out "$R2"
   jq -r '.operations[] | (.operation.resources[0]) + "  " + (.summary | capture("; (?<n>[0-9]+) declared").n)' "$R2/review.json" | grep -v '  0$'
   nagarectl platform bootstrap apply "$R2" --yes
   ```

   The disk resizes online in seconds with no restart. The filesystem does
   **not** grow yet. `lsblk` shows the bigger device while `df` still shows the
   old size:

   ```text
   Filesystem      Size  Used Avail Use% Mounted on
   /dev/sdb         98G  212M   93G   1% /var/lib/nagare
   sdb  110G
   ```

   The grow only runs when the filesystem is mounted, and `/var/lib/nagare` has
   been mounted since boot.

5. **Grow the filesystem now** (or simply reboot later). ext4 grows online, with
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

6. **Confirm the cluster is healthy.**

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
you ever set a smaller size by mistake, set `NAGARE_DATA_DISK_SIZE_GB` back to
the current size and plan stage 1 again before applying anything.
