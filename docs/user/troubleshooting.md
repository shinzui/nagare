---
type: Reference
title: "Troubleshooting"
description: "Diagnose and resolve known Nagare host, cluster, networking, backup, broker, and deployment failures by symptom."
docId: DOC-34
tags: [troubleshooting, failures, diagnostics, operations]
generated:
  by: human:nadeem
  at: 2026-08-23T20:57:05Z
---

# Troubleshooting

> **Status:** ✅ Working — every entry below is a failure actually hit while
> bringing up `nagare-01`, with the fix that's now committed to the repo.

These are the non-obvious failures and their fixes. Many are already encoded in
the NixOS config (with explanatory comments) so they don't recur — they're
documented here so that if you see the *symptom* on a fresh boot or a new host,
you know what's going on and where the fix lives. The source of record is the
EP-3 **Surprises & Discoveries** section in the MasterPlan.

---

## Name resolution fails on the VM

**Symptom.** k3s can't pull images; logs show *"Temporary failure in name
resolution."* Pings/HTTP/DNS to the GCE metadata server time out.

**Cause.** On this VM the GCE metadata server (`169.254.169.254`) — which DHCP
hands out as the resolver — is unreachable, so every DNS lookup breaks.

**Fix (committed, `networking.nix`).** Use public resolvers and stop dhcpcd from
overwriting `resolv.conf` with the broken metadata nameserver:

```nix
networking.nameservers = [ "8.8.8.8" "8.8.4.4" ];
networking.dhcpcd.extraConfig = "nohook resolv.conf";
```

`metadata.google.internal` still resolves via `/etc/hosts` (set by the GCE
config), so the guest agent is unaffected. **Don't "simplify" this away** — it's
load-bearing.

---

## k3s won't start: "Dependency failed for k3s service"

**Symptom.** First boot leaves k3s dead; the data-disk mount failed.

**Cause.** Pulumi attaches a **blank** persistent disk (no filesystem). The
`/var/lib/nagare` mount can't succeed on an unformatted disk, and k3s `requires`
that mount, so it never starts.

**Fix (committed, `storage.nix`).** A `format-nagare-data` oneshot formats the
disk ext4 on first boot **only if it has no filesystem** (`blkid` guard), before
the mount. It's idempotent — once formatted, it skips, so existing data is never
touched.

```nix
if ! blkid /dev/disk/by-id/google-nagare-data >/dev/null 2>&1; then
  mkfs.ext4 -F -L nagare-data /dev/disk/by-id/google-nagare-data
fi
```

This is also why a **VM rebuild keeps your data**: the surviving disk already
has a filesystem, so the format step is skipped (see
[Backups and disaster recovery](backups-and-disaster-recovery.md)).

---

## `/var/lib/nagare` has only `lost+found` — the subdirectories vanished

**Symptom.** After boot, `/var/lib/nagare` is missing its expected subdirs
(`victoria-metrics`, `sqlite`, `local-path`, …) and shows only `lost+found`. k3s
local-path storage has no directory.

**Cause.** Creating the layout with `systemd.tmpfiles.rules` runs at
`systemd-tmpfiles-setup`, which can fire **before** the `nofail` data disk is
mounted. The dirs get created on the **root** filesystem, then the disk mounts
on top and shadows them — leaving only the disk's `lost+found` visible.

**Fix (committed, `storage.nix`).** Create the layout with an explicit oneshot
(`nagare-data-layout`) ordered **after** `var-lib-nagare.mount`
(`RequiresMountsFor`), so the directories land on the mounted data disk. k3s is
in turn ordered after that unit.

---

## SSH: connection closed right after the handshake

**Symptom.** SSH (including over the IAP tunnel) connects, completes the key
exchange, then drops at the start of user authentication — *"Connection closed
… at userauth."* After a couple of attempts the box is effectively unreachable.

**Two causes, both fixed in `security.nix`:**

1. **OpenSSH per-source penalties.** OpenSSH 9.8+/10.x `PerSourcePenalties`
   start dropping connections from a source after a couple of failures — and all
   IAP-tunneled connections share one source. Disabled:

   ```nix
   services.openssh.settings.PerSourcePenalties = "no";
   ```

2. **Google OS Login.** The GCE image module enables OS Login by default, which
   makes sshd authenticate via the OS Login `AuthorizedKeysCommand` helper
   instead of the `deploy` user's declarative `authorized_keys` — a second cause
   of the userauth-time close. Disabled so plain key auth is used:

   ```nix
   security.googleOsLogin.enable = lib.mkForce false;
   ```

We control access via the IAP firewall + key auth as the `deploy` user, so
neither feature is needed. If you re-enable either, expect this symptom back.

---

## `gcloud compute ssh --tunnel-through-iap` hangs / breaks on macOS

**Symptom.** On macOS (OpenSSH 10.x), `gcloud compute ssh --tunnel-through-iap`
fails during the kex handshake.

**Cause.** A known macOS OpenSSH 10.x + IAP interaction.

**Fix.** Use `scripts/iap-ssh.sh`, which opens the tunnel with
`gcloud compute start-iap-tunnel` and routes OpenSSH through `socat` as the
`ProxyCommand`. See [Accessing the host](accessing-the-host.md#path-2-iap-tunnel-break-glass).

---

## A script refuses to run: project mismatch

**Symptom.** A script says either *"effective project '…' does not match the
active context's declared project '…'"* or *"gcloud's configured project is
'…', expected '…'."*

**Cause.** An ambient `CLOUDSDK_CORE_PROJECT` is trying to override a selected
context, or no context declares a project and gcloud's stored configuration
does not match the effective/default target. This is the intended
project-isolation guard, not a bug.

**Fix.** For a selected context, unset the ambient override or select the
context that declares the intended project. Without a declared context/profile,
run `gcloud config set project <expected>` or create one. Re-enter the dev shell
after changing selections (`direnv allow` or `nix develop`). See
[Getting started](getting-started.md#project-isolation-read-this-once-internalize-it).

---

## Local Docker push says "server gave HTTP response to HTTPS client"

**Symptom.** In local mode, `nagarectl deploy` builds an image but Docker fails
when pushing to `k3d-registry.localhost:5000`.

**Cause.** The k3d registry is plain HTTP. Docker automatically trusts bare
`localhost` and `127.0.0.0/8`, but not the named host
`k3d-registry.localhost`, so it tries HTTPS unless the registry is marked
insecure.

**Fix.** Add `k3d-registry.localhost:5000` to your Docker daemon's
`insecure-registries` and restart Docker. If your resolver does not honor
`.localhost`, also add:

```text
127.0.0.1 k3d-registry.localhost
```

See [Local development](local-development.md) and
[`nagare.local.env.example`](../../nagare.local.env.example) for the same schema
used by a local context.

---

## Local backup says `NAGARE_LOCAL_OBJECT_STORE` is unset or malformed

**Symptom.** `nagarectl db backup`, `db restore`, `storage snapshot`, or
`storage restore` fails immediately in local mode with a message about
`NAGARE_LOCAL_OBJECT_STORE`.

**Cause.** Local data-movement Jobs need an S3 endpoint and bucket so they can
target MinIO instead of GCS. The value must have the form
`<endpoint-url>/<bucket>`.

**Fix.**

```bash
nagarectl context create local --mode local \
  --registry-host k3d-registry.localhost:5000 \
  --base-domain 127-0-0-1.sslip.io \
  --local-object-store http://minio.nagare-system.svc.cluster.local:9000/nagare-backups \
  --use
direnv allow
just local-minio
```

The default value is
`http://minio.nagare-system.svc.cluster.local:9000/nagare-backups`.

---

## `kubectl` can't reach the cluster

**Likely causes.**

- Kubeconfig still points at `https://127.0.0.1:6443`. Repoint `server:` at the
  host's tailnet address (`https://nagare-01:6443`) — the firewall trusts
  `tailscale0`, not your workstation's public IP. See
  [Accessing the host](accessing-the-host.md#getting-a-working-kubectl).
- The host isn't on the tailnet (Tailscale didn't get its auth key). Check the
  sops secret and `systemctl status tailscaled`.
- k3s isn't up — work back through the storage/DNS entries above.

---

## Broker pod is not Ready

**Symptom.** `nagarectl broker get events` shows `Ready: False` or health says
`pod/events-0 not Ready`.

**Likely causes.**

- Redpanda startup flags are invalid for the node size.
- The PVC could not mount or the data disk is full.
- The pod is waiting for an image pull.

**Fix.**

```bash
kubectl describe pod/events-0 -n personal
kubectl logs pod/events-0 -n personal --tail=100
kubectl get pvc nagare-broker-events-data -n personal
```

On the small VM, keep Redpanda `--redpanda-smp` and `--redpanda-memory` modest.
For a larger VM, use the sizing flags in
[Messaging brokers](messaging-brokers.md#sizing) instead of editing manifests.

---

## Broker metrics are missing

**Symptom.** `broker get` says `/public_metrics reachable` but
`metrics scrape` is WARN, or the `Nagare Brokers` dashboard is empty.

**Fix.**

```bash
kubectl get vmservicescrape nagare-brokers -n monitoring -o yaml
kubectl get --raw '/api/v1/namespaces/monitoring/services/vmagent-vmks-victoria-metrics-k8s-stack:8429/proxy/targets' | grep nagare-brokers
kubectl get --raw '/api/v1/namespaces/monitoring/services/vmsingle-vmks-victoria-metrics-k8s-stack:8429/proxy/api/v1/query?query=up%7Bjob%3D%22nagare-brokers%22%7D'
```

The VMAgent target should have labels `job="nagare-brokers"`,
`nagare_broker="<name>"`, and `nagare_broker_provider="redpanda"`. Re-run
`just observability` if the scrape object or dashboard ConfigMap is missing.

---

## Worker deploy fails because a broker or topic is missing

**Symptom.** `nagarectl worker deploy` or `nagarectl deploy` fails before
printing a manifest, saying the broker or topic cannot be found.

**Cause.** Workload broker bindings are checked against live broker state during
deploy. The binding does not create the broker or topic.

**Fix.**

```bash
nagarectl broker list --namespace personal
nagarectl broker create redpanda events --namespace personal --topic jobs
```

Then rerun the workload deploy.

---

## Kafka clients cannot connect to the broker

**Symptom.** A workload has `KAFKA_BOOTSTRAP_SERVERS`, but the client times out
or reports an unreachable advertised broker.

**Cause.** Kafka clients use broker metadata after the initial bootstrap. The
advertised listener must be reachable from the client pod, not just from the
broker pod.

**Fix.** Use the generated `KAFKA_BOOTSTRAP_SERVERS` value. Do not hand-write a
different Kubernetes DNS name in app config. Confirm the Service resolves inside
the cluster:

```bash
kubectl exec -n personal deploy/<workload> -- getent hosts events.personal.svc.cluster.local
```

---

## Broker storage pressure

**Symptom.** Broker logs show low disk space, the dashboard storage panel rises,
or pod scheduling fails due to disk pressure.

**Fix.**

- Increase broker storage with a new broker/PVC plan before data grows further.
- Lower topic retention (`--topic-retention-ms`) for disposable streams.
- Delete unused retained PVCs only after confirming you no longer need the data:

```bash
kubectl get pvc -n personal | grep nagare-broker
kubectl delete pvc nagare-broker-events-data -n personal
```

---

## Where the authoritative record lives

If a symptom here doesn't match what you see, or you hit something new, check the
EP-3 **Surprises & Discoveries** and **Decision Log** in
[`docs/masterplans/1-bootstrap-nagare-personal-paas.md`](../masterplans/1-bootstrap-nagare-personal-paas.md)
— that's kept current as the build proceeds, and new findings are recorded there
first.
