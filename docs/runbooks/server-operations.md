# Nagare server-operations runbook

🟡 **Commands shipped (EP-38..EP-41); live transcripts captured in partial/degraded
form while `nagare-01` is `TERMINATED` — every degraded block below is labelled.**

For the **operator**. Run the whole platform's day-2 operations from `nagarectl` —
check health, diagnose and fix problems, inspect domains, and reclaim disk — without
remembering which of `gcloud` / `kubectl` / `pulumi` / `gsutil` answers which question.

These commands shell out to the same local tooling you would run by hand, against the
**ambient** `kubectl` context and the local `gcloud` / `pulumi` / `gsutil`. They assume
the access prerequisites in [`cluster-access.md`](cluster-access.md): the VM is started,
your `kubectl` points at the k3s cluster (not the default GKE context), and
`SSH_USER=deploy SSH_KEY=~/.ssh/id_ed25519` is exported for the IAP-SSH disk probe. All
cloud work targets project **`tan-nb-exp`**, region **`us-west1`**, zone **`us-west1-a`**
(see `CLAUDE.md` — no other project, even for reads).

Every command here is **read-only** except `nagarectl cleanup`, which is **dry-run by
default** and mutates only with `--confirm`.

## Commands at a glance

```text
nagarectl server status     One-screen inventory: VM, k3s, Knative, Kourier,
                            cert-manager, base domain, ingress IP, disk, registry,
                            backup freshness. Read-only; degrades gracefully.
nagarectl doctor            The same probes re-graded as an OK/WARN/FAIL checklist,
                            each non-OK line carrying a fix command. Exits 1 on any FAIL.
nagarectl domains list      The base domain + every per-app DomainMapping, with the
                            expected DNS record and certificate readiness.
nagarectl cleanup           Reclaim disk: prune unused images, stale previews, old
                            releases. Dry-run by default; --confirm to act.
```

## Is it healthy? — `nagarectl server status`

A one-screen, aligned inventory of the whole platform. Read-only. Every line is tagged
`OK` / `WARN` / `UNKNOWN` / `FAIL`; a probe whose source is unreachable (the VM is off,
no kubeconfig, a tool not on PATH) degrades to `UNKNOWN` with a short hint rather than
crashing — so you always get a full, partial-but-clear report.

```text
$ nagarectl server status --help
Usage: nagarectl server status [--skip-vm]

  One-screen platform health report

Available options:
  --skip-vm                Skip the IAP-SSH disk probe (no SSH setup needed)
  -h,--help                Show this help text
```

With the VM running and `kubectl` pointed at k3s, the report walks down the platform —
VM power, node, the Knative/Kourier/cert-manager rollouts, the ClusterIssuer, the Kourier
`EXTERNAL-IP = publicIp` match, the base-domain comparison, `external-domain-tls`,
Artifact Registry auth, the per-prefix backup ages, and boot+data disk usage:

```text
  STATUS   CHECK                    DETAIL
  OK       VM                       RUNNING
  OK       k3s node                 Ready
  OK       Knative controller       rolled out
  OK       Kourier gateway          rolled out
  OK       cert-manager             rolled out
  OK       ClusterIssuer            letsencrypt-dns Ready
  OK       Kourier ingress          EXTERNAL-IP 34.83.0.1 = publicIp
  WARN     base domain              apps.example.com (= Pulumi baseDomain)
  WARN     external-domain-tls      Disabled (HTTP-first until base domain is real)
  OK       Artifact Registry        us-west1-docker.pkg.dev/tan-nb-exp/nagare reachable
  OK       backup postgres          newest object 6h ago
  OK       boot disk                24% of 100G
  OK       data disk                12% of 100G
```

**Captured with no cluster reachable (`nagare-01` TERMINATED, no tools on PATH) — every
probe degrades and the command still exits 0:**

```text
  STATUS   CHECK                    DETAIL
  UNKNOWN  VM                       gcloud unavailable or no access
  UNKNOWN  k3s node                 no kubeconfig / not reachable
  UNKNOWN  Knative controller       no kubeconfig / not reachable
  UNKNOWN  Kourier gateway          no kubeconfig / not reachable
  UNKNOWN  cert-manager             no kubeconfig / not reachable
  UNKNOWN  ClusterIssuer            letsencrypt-dns not reachable
  UNKNOWN  Kourier ingress          no kubeconfig / not reachable
  UNKNOWN  base domain              config-domain not reachable
  UNKNOWN  external-domain-tls      config-network-tls not reachable
  UNKNOWN  Artifact Registry        gcloud unavailable or no access
  UNKNOWN  backup postgres          gsutil unavailable or prefix empty
  UNKNOWN  disk                     iap-ssh unavailable (VM off? key not set?)
```

Pass `--skip-vm` to skip the IAP-SSH disk probe when SSH is not set up.

## What is wrong and how do I fix it? — `nagarectl doctor`

`doctor` re-runs the same probes and re-grades them into an ordered `OK`/`WARN`/`FAIL`
checklist. **Every non-OK line names the problem in plain language and prints the exact
command to fix it.** `doctor` never executes a fix — it only prints commands you run
yourself. It **exits 1 when any check FAILs** (and 0 otherwise), so it is scriptable:
`nagarectl doctor && nagarectl deploy` only deploys when the platform is healthy.

```text
$ nagarectl doctor --help
Usage: nagarectl doctor [--skip-vm]

  Health-check the platform and print remediation hints (exit 1 on any FAIL)

Available options:
  --skip-vm                Skip the IAP-SSH disk probe (no SSH setup needed)
  -h,--help                Show this help text
```

A `FAIL` line and its remediation — here the VM is powered off (exit code 1):

```text
nagare doctor — 18 checks

  [FAIL]  VM                       The VM nagare-01 is powered off.
          fix: gcloud compute instances start nagare-01 --zone=us-west1-a
  ...
1 failed, 16 warnings, 1 ok.
$ echo $?
1
```

**Captured with no cluster reachable** — every probe degrades to `WARN` ("could not
check; …"), so there is no hard `FAIL` and the command exits 0; each line still carries
the fix you would run once the source is reachable:

```text
nagare doctor — 18 checks

  [WARN]  VM                       could not check; gcloud unavailable or no access
          fix: gcloud compute instances start nagare-01 --zone=us-west1-a
  [WARN]  k3s node                 could not check; no kubeconfig / not reachable
          fix: point kubectl at the k3s cluster — the workstation default context often points at the unrelated GKE cluster tan-cluster; retrieve the k3s kubeconfig per docs/runbooks/cluster-access.md
  [WARN]  Knative controller       could not check; no kubeconfig / not reachable
          fix: kubectl rollout status deploy/controller -n knative-serving; consult cluster/bootstrap/knative-serving/README.md
  ...
0 failed, 18 warnings, 0 ok.
```

## What is my DNS/TLS state? — `nagarectl domains list`

The platform base domain plus every Knative `DomainMapping`, each with its owning
Service, the DNS record it is expected to match (computed from the Pulumi wildcard +
reserved IP — not a live `dig`), and its certificate readiness. Read-only.

```text
$ nagarectl domains list --help
Usage: nagarectl domains list [-n|--namespace NS] [--all-namespaces]
                              [--base-domain DOMAIN]

  List the base domain and per-app DomainMappings with DNS and cert state

Available options:
  -n,--namespace NS        Kubernetes namespace (default: personal)
  --all-namespaces         List domains across all namespaces
  --base-domain DOMAIN     Apps base domain (overrides NAGARE_BASE_DOMAIN,
                           default apps.example.com)
  -h,--help                Show this help text
```

The first row is the base domain (the wildcard apex); each subsequent row is a
`DomainMapping`. **TLS is HTTP-first today** — the placeholder `apps.example.com` cannot
complete an ACME DNS-01 challenge, so no `Certificate` objects exist and the `CERT`
column reads `disabled`. Wildcard Let's Encrypt TLS is opt-in via `just
cluster-enable-tls` once a real `baseDomain` is delegated (see
[`disaster-recovery.md`](disaster-recovery.md) step 4); after that the `CERT` column
reads `Ready` (or `pending` while the challenge is in flight).

```text
  DOMAIN                          SERVICE         DNS                               CERT
  apps.example.com                (base)          *.apps.example.com A -> 34.83.0.1 disabled
  blog.apps.example.com           blog            *.apps.example.com A -> 34.83.0.1 disabled
```

**Captured with no cluster reachable** — the base row still prints with the IP as
`(unknown)`, exit 0:

```text
  DOMAIN                          SERVICE         DNS                               CERT
  apps.example.com                (base)          *.apps.example.com A -> (unknown) disabled
```

## Reclaim disk — `nagarectl cleanup`

Reclaims space across three categories: unused containerd images on the node, stale
static-site previews past their TTL, and release-history entries beyond a retention
count. **This is the only mutating command in this runbook, and it is dry-run by
default**: a plain `nagarectl cleanup` reports what *would* be removed and deletes
nothing. `--confirm` is required to act; the per-category flags scope the run.

```text
$ nagarectl cleanup --help
Usage: nagarectl cleanup [--images] [--previews] [--releases] [--confirm]
                         [--preview-ttl-days N] [--keep-releases N]
                         [-n|--namespace NS]

  Reclaim disk: prune unused images, stale previews, old releases (dry-run by
  default)

Available options:
  --images                 Limit cleanup to the containerd image store
  --previews               Limit cleanup to stale static-site previews
  --releases               Limit cleanup to old release-history entries
  --confirm                REQUIRED to delete; without it cleanup is a dry run
  --preview-ttl-days N     Previews older than N days are stale (default: 7)
  --keep-releases N        Keep the most recent N releases per log (current
                           always kept) (default: 10)
  -n,--namespace NS        Namespace to scan for previews/releases
  -h,--help                Show this help text
```

Dry run first (the default — mutates nothing), then apply:

```bash
nagarectl cleanup                 # dry run: reports what would be removed
nagarectl cleanup --confirm       # actually prune images, delete stale previews, trim logs
nagarectl cleanup --confirm       # re-run is a clean no-op (everything already gone)
```

A dry-run report ends with the dry-run notice; with `--confirm` it ends with `done.`:

```text
cleanup (dry run)

  IMAGES     12 unused images (~3.4 GiB reclaimable)
  PREVIEWS   2 stale:
               notes-pr-fix-typo
               notes-pr-old-experiment
  RELEASES   notes: 4 entries beyond keep would be trimmed (current kept)

(dry run — nothing removed; re-run with --confirm to apply)
```

**Captured with no cluster reachable** — every category reports empty and the command
mutates nothing, exit 0:

```text
cleanup (dry run)

  IMAGES     0 unused images (~0 B reclaimable)
  PREVIEWS   none stale
  RELEASES   none to trim

(dry run — nothing removed; re-run with --confirm to apply)
```

Cleanup never removes a running app's image (`crictl rmi --prune` protects referenced
images), never deletes the `current` release of any log, and keeps the most-recent-N
releases. Pruned images are re-pullable from Artifact Registry on the next deploy; a
trimmed release log only drops history metadata, never a running Service.

## Day-2 recovery scenario: TERMINATED → green

The end-to-end narrative. A newcomer can recover a cold platform to green using only the
commands below and the cross-linked workarounds. Run from the repo root inside the dev
shell (`nix develop` / `direnv allow`), with `kubectl` pointed at k3s per
[`cluster-access.md`](cluster-access.md).

1. **The VM is off.** `nagarectl server status` shows `FAIL VM TERMINATED`; the
   cluster-dependent rows read `UNKNOWN`. `nagarectl doctor` prints the same as the first
   `FAIL` with its fix.

2. **Start the VM** (the exact command `doctor` printed):

   ```bash
   gcloud compute instances start nagare-01 --zone=us-west1-a
   ```

   Allow ~1–2 minutes for sshd and k3s to come up.

3. **Re-apply the post-reboot host workarounds.** A plain `start` boots the existing boot
   disk; the pod→metadata route, the `MASQUERADE` POSTROUTING rule, and the coredns
   upstream are runtime-only and are **lost** on reboot. Until they are re-applied,
   in-cluster ADC and image pulls fail — which `nagarectl doctor` surfaces as the
   downstream symptoms (cert-manager / control-plane not ready, `Artifact Registry`
   unreachable, stale backups). Re-apply them per the **Power management** section of
   [`disaster-recovery.md`](disaster-recovery.md#power-management-stop--start--full-teardown):

   ```bash
   GW=$(... default gw); ip route replace 169.254.169.254/32 via "$GW" dev eth0
   iptables -t nat -A POSTROUTING -d 169.254.169.254/32 -j MASQUERADE
   kubectl -n kube-system rollout restart deploy/coredns
   ```

   (Or replace the VM onto the fixed image for a clean boot with no workarounds — see the
   same section.)

4. **Re-run `nagarectl doctor` and fix each remaining `FAIL`.** Each line names the
   component and prints its remediation command — `kubectl rollout status deploy/<name> -n
   <ns>; consult cluster/bootstrap/<component>/README.md` for a control plane,
   `gcloud auth configure-docker us-west1-docker.pkg.dev` for registry auth,
   `run scripts/backup-postgres.sh` for stale backups, `nagarectl cleanup` for a full
   disk. Copy-paste each fix and re-run until the summary reads `0 failed`.

5. **Confirm domains resolve.** `nagarectl server status` is all `OK` (modulo the expected
   `WARN` on `base domain`/`external-domain-tls` while the placeholder domain stands), and
   `nagarectl domains list` shows the base domain and every per-app `DomainMapping` with
   its DNS expectation. The platform is green.

## How it works / what it reads

Nothing here is a daemon. Each command shells out, once, to the same local tooling an
operator would run by hand — `gcloud` (VM power, Artifact Registry), `pulumi` (the
`publicIp`/`baseDomain`/`backupBucket` stack outputs), `kubectl` (node, deployments,
ConfigMaps, DomainMappings, Certificates), `gsutil` (backup-prefix freshness), and
`scripts/iap-ssh.sh` (boot/data disk usage, and `crictl` for image cleanup). `doctor`
re-grades the exact same probes `server status` gathers — the two never disagree about
whether the VM is up or a deployment is rolled out. Any unreachable source degrades to an
`UNKNOWN`/`WARN` line, never an uncaught exception.

For continuous monitoring and time-series, Grafana / VictoriaMetrics remain the story
(see [`disaster-recovery.md`](disaster-recovery.md) step 5); these commands are
point-in-time, operator-invoked checks.

See also: the initiative MasterPlan
[`docs/masterplans/8-server-inventory-and-operations-ux-for-nagare.md`](../masterplans/8-server-inventory-and-operations-ux-for-nagare.md),
the access prerequisites in [`cluster-access.md`](cluster-access.md), and the full rebuild
sequence in [`disaster-recovery.md`](disaster-recovery.md).
