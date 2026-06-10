---
id: 33
slug: knative-pvc-enablement-spike-and-cluster-feature-flags
title: "Knative PVC enablement spike and cluster feature flags"
kind: exec-plan
created_at: 2026-06-10T00:44:35Z
intention: "intention_01ktqfjpdqewga3t0rm9crehxx"
master_plan: "docs/masterplans/7-persistent-storage-for-nagare.md"
---

# Knative PVC enablement spike and cluster feature flags

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Today, an application running on this cluster as a *Knative Service* has nowhere durable to
keep its data. A **Knative Service** (Kubernetes object kind `Service` in the API group
`serving.knative.dev/v1`, abbreviated `ksvc`) is the thing `nagarectl deploy` produces: it
takes a container image and a small YAML manifest and turns it into an auto-scaling web
service that can scale down to zero pods when idle and back up on demand. When such a pod
restarts or scales to zero, everything written to the container's own filesystem is lost.
The standard Kubernetes way to give a workload a durable disk is a **PersistentVolumeClaim
(PVC)** — an object that requests a chunk of durable storage — and a **volume mount**, which
is the in-container directory (for example `/data`) where that storage appears. On this
single-node k3s cluster, a PVC is satisfied by the built-in **`local-path` StorageClass**:
the k3s `local-path-provisioner` carves a directory out of the host data disk at
`/var/lib/nagare/local-path` and bind-mounts it into the pod.

There are two concrete obstacles, and this plan removes the first and proves we can clear the
second:

1. **Knative refuses PVC volumes by default.** Knative Serving gates the ability to attach a
   PVC to a `ksvc` behind two *feature flags* stored in a Kubernetes **ConfigMap** (a named
   bag of key/value configuration data) called `config-features`, living in the
   `knative-serving` namespace. Until those flags are flipped on, the Knative admission
   webhook (the cluster component that validates `ksvc` manifests before they are accepted)
   rejects any `ksvc` that asks for a PVC. There is no `config-features` configuration in this
   repository today, so that rejection is the current behavior.

2. **It is unproven that a Knative Service can durably mount a single-node PVC across a
   deploy.** Even with the flags on, Knative deploys are *rolling*: when you deploy a new
   version, Knative briefly runs the **old revision** and the **new revision** at the same
   time (a **revision** is one immutable snapshot of a Service's configuration; each deploy
   creates a new one). On a single node, both revisions would try to mount the *same*
   `local-path` PVC at the same time. The `local-path` StorageClass only supports the
   **`ReadWriteOnce` (RWO)** access mode — "mountable read-write by a single node" — and while
   RWO permits multiple pods on the *same* node to mount it, two pods writing the same files
   is still a correctness hazard, and certain rollout shapes can deadlock the new pod waiting
   for the old one. We must determine, by experiment, the exact Knative knob that makes a
   single-node RWO PVC behave correctly through a deploy.

After this plan, two things are true and demonstrable. First, the repository contains a
committed cluster-configuration file,
`cluster/bootstrap/knative-serving/config-features.yaml`, that enables both PVC feature flags,
and applying it makes the cluster accept PVC-bearing Knative Services. Second, this plan
records a verified, hand-applied raw-YAML proof — with a captured terminal transcript — that a
Knative Service mounts a `local-path` RWO PVC, that a file written into the volume **survives
a new revision being deployed** and **survives a scale-to-zero and scale-back**, and the proof
names the exact Service annotation(s) that make this safe on one node. That verified YAML shape
(the `volumes`/`volumeMounts` stanza plus the rollout annotation) is the contract called
**Integration Point IP2** in the parent MasterPlan, and the next plan,
`docs/plans/34-typed-volume-and-mount-model-with-pvc-and-volumemount-renderer.md` (EP-34), must
make its renderer emit exactly this shape.


## Progress

- [x] M1: Hand-write the scratch PVC YAML and the scratch Knative Service YAML (throwaway spike artifacts). (2026-06-09; scratch image revised — see Surprises.)
- [x] M1: Confirm the cluster *rejects* a PVC-bearing `ksvc` while `config-features` flags are off (capture the rejection message as the "before" evidence). (2026-06-09)
- [x] M1: Temporarily enable the two flags by live `kubectl patch`, apply the scratch `ksvc`, write a file into the volume. (2026-06-09)
- [x] M1: Deploy a second revision; confirm the file persists. Capture the transcript. (2026-06-09; new revision Ready in 5s, marker survived, no Multi-Attach.)
- [x] M1: Force scale-to-zero, then scale back; confirm the file persists. Capture the transcript. (2026-06-09; scaled to zero ~50s, request via kourier-internal scaled back, marker intact.)
- [x] M1: Determine and record the rollout-safety annotation that lets a single-node RWO PVC survive a revision roll; capture the failure mode without it. (2026-06-09; min-scale=1/max-scale=1/rollout-duration=0s — no stall observed; see Decision Log.)
- [x] M1: Tear down the scratch namespace; confirm the host directory under `/var/lib/nagare/local-path` is reclaimed. (2026-06-09; done as M2 step 4 — ns deleted in ~85s after explicit ksvc/pvc delete, host dir reclaimed.)
- [x] M2: Create `cluster/bootstrap/knative-serving/config-features.yaml` enabling both flags, matching the patch-body format of the sibling ConfigMap files. (2026-06-09)
- [x] M2: Update `cluster/bootstrap/knative-serving/README.md` so the new file is listed and its apply command documented. (2026-06-09)
- [x] M2: Revert the temporary `kubectl patch` to a clean ConfigMap, then apply `config-features.yaml` the committed way and re-run the M1 proof to confirm the *committed config* enables PVCs. (2026-06-09; flags-off rejected again, committed file → `enabled enabled` → ksvc Ready, marker intact.)
- [x] M2: Record the canonical IP2 YAML stanza (volume, volumeMount, rollout annotation) verbatim in this plan for EP-34 to consume. (2026-06-09; verified shape matches the pre-filled stanza in Interfaces and Dependencies.)
- [x] Commit the config and README change with the `ExecPlan:` trailer. (2026-06-09)


## Surprises & Discoveries

- **The `config-features` ConfigMap already exists, but holds only an `_example` key.** The
  upstream `serving-core.yaml` install creates `config-features` in `knative-serving` containing a
  single `_example` documentation blob and no real overrides, so both PVC flags sit at their coded
  default `disabled`. The repo's `cluster/bootstrap/knative-serving/` had no patch for it. Evidence:
  `kubectl -n knative-serving get configmap config-features -o jsonpath='{.data}'` returned
  `{"_example":"…"}` only.

- **Both flags are load-bearing, and the webhook says so explicitly.** With the flags at default,
  applying the PVC-bearing `ksvc` was denied by `validation.webhook.serving.knative.dev`:
  > Persistent volume claim support is disabled, but found persistent volume claim ep33-data:
  > Persistent volume write support is disabled, but found persistent volume claim ep33-data that
  > is not read-only:
  > must not set the field(s): spec.template.spec.volumes[0].persistentVolumeClaim

  The message names *both* the claim flag and the write flag — confirming the Decision Log choice to
  enable both. The PVC object itself was accepted (plain Kubernetes) and sat `Pending`
  (`WaitForFirstConsumer`) until a pod consumed it.

- **`cgr.dev/chainguard/busybox:latest` is a minimal busybox that lacks `nc` and `httpd`.** The
  scratch `ksvc` command in the original plan (`nc -l -p 8080`) never opened a port (`nc: not
  found`), so the Service never became Ready — the queue-proxy readiness probe to `:8012` failed
  with connection-refused/timeout while the user container looped silently. The PVC still bound and
  mounted read-write (proven by writing `/data/marker` via `kubectl exec`), so this was a
  *spike-app* defect, not a PVC problem. The spike app was switched to **`python:3.12-alpine`**
  running `python3 -m http.server 8080 --directory /data` — a robust persistent HTTP server that
  passes the probe *and* serves the volume over HTTP so the marker is curl-readable. (The repo's
  `cluster/examples/hello-knative-service` uses `gcr.io/knative-samples/helloworld-go`, which also
  becomes Ready but is distroless — no shell/`cat` to read `/data` — so `python:alpine` was the
  better throwaway image.) **Implication for EP-37's examples:** pick a base image that actually
  contains the server you invoke; don't assume `nc`/`httpd` exist.

- **Single-node RWO `local-path` does NOT deadlock across a Knative revision roll — no special
  "anti-Multi-Attach" knob is needed.** Across several rolls the old-revision and new-revision pods
  co-mounted the *same* `ReadWriteOnce` PVC concurrently on the one node, and the new revision
  reached Ready in **5–9s** with **zero** `FailedMount` / `FailedAttachVolume` / `Multi-Attach`
  events (`kubectl get events --field-selector reason=FailedAttachVolume,reason=FailedMount`
  returned nothing). Reason: RWO means "read-write by a single *node*"; multiple pods on the same
  node may co-mount, and Nagare is single-node, so the feared cross-revision mount deadlock cannot
  occur on this topology. This is the decisive feasibility finding the MasterPlan gated on.

- **Caveat that replaces the deadlock risk: a brief concurrent-writer window.** Because Knative
  rolls create-before-delete, during the overlap two pods can both hold the PVC **read-write** and
  write the same files. There is no mount error, but apps that cannot tolerate two writers (classic
  SQLite without WAL/locking) must account for it. `min-scale=1`/`max-scale=1` bounds each revision
  to one pod but does **not** eliminate the cross-revision overlap — that overlap is inherent to
  Knative's zero-downtime rollout. **Implication for EP-37:** the SQLite example must use
  Litestream / WAL (as the existing `cluster/examples/sqlite-litestream` already implies), and the
  user docs should call out the overlap explicitly.

- **Durability is independent of any running pod.** With the `ksvc` deleted entirely (zero pods),
  the PVC stayed `Bound` and the marker file remained on the host. The marker written by the first
  (busybox) pod survived, in sequence: a revision roll, a *full Service delete + recreate with a
  different container image*, and a scale-to-zero → request-triggered scale-from-zero cycle. Direct
  host evidence on `nagare-01`:
  `/var/lib/nagare/local-path/pvc-361b74ea-…_ep33-spike_ep33-data/marker` contained
  `written-by-rev00001`.

- **local-path host-dir naming and node pinning (useful for EP-35 `storage list`/`inspect`).** The
  provisioner names each per-PVC directory `pvc-<uid>_<namespace>_<pvcname>` under
  `/var/lib/nagare/local-path/`, and the auto-created PV carries
  `nodeAffinity … kubernetes.io/hostname In [nagare-01]` with
  `spec.local.path = /var/lib/nagare/local-path/pvc-<uid>_<ns>_<pvc>`. EP-35's "node-path" column
  can read `kubectl get pv <name> -o jsonpath='{.spec.local.path}'`.

- **Scale-from-zero must be triggered through the ingress, not the placeholder domain.** The
  `ksvc` `status.url` is `http://ep33-app.ep33-spike.apps.example.com` — `apps.example.com` is a
  placeholder base domain that does not resolve. To wake a scaled-to-zero Service from inside the
  cluster, send the request to `kourier-internal.kourier-system.svc.cluster.local` with an explicit
  `Host:` header equal to that URL's host. (`kubectl run … -i` to attach also raced; use
  `--restart=Never` + `logs`.)

- **`kubectl delete namespace` alone left the scratch namespace stuck `Terminating` for minutes.**
  Deleting the namespace did remove the pods (the disk was released), but the Knative
  `Service`/`Route`/`Configuration`/`Revision` objects and the `PVC` lingered on their finalizers
  and the namespace would not finalize (`kubectl delete namespace … --timeout` reported "timed out
  waiting for the condition"). Explicitly deleting the `ksvc` and the `pvc` first let the namespace
  finalize in ~85s, after which the per-PVC host directory under `/var/lib/nagare/local-path` was
  reclaimed (confirming the `local-path` `Delete` reclaim policy). **Implication for EP-35/EP-36:**
  app/volume deletion should delete the `ksvc` and the PVCs **explicitly and in order** (and honor
  the `RetentionPolicy` — `Retain` means *don't* delete the PVC), not rely on namespace deletion to
  cascade-clean storage.


## Decision Log

- Decision: Run a throwaway, hand-applied spike (M1) to prove Knative can durably mount a
  `local-path` RWO PVC across a revision roll *before* committing the typed model in EP-34.
  Rationale: the parent MasterPlan
  (`docs/masterplans/7-persistent-storage-for-nagare.md`) identifies this as the gating
  feasibility risk for the whole Persistent Storage initiative — if a Knative Service cannot
  durably hold a `local-path` PVC, EP-34's renderer would emit YAML the cluster rejects and
  the entire model is built on sand. The ExecPlan specification explicitly encourages an
  isolated "prototyping" spike to de-risk significant unknowns. The spike YAML is evidence in
  this plan, not a committed feature.
  Date: 2026-06-09

- Decision: Enable BOTH feature flags — `kubernetes.podspec-persistent-volume-claim` AND
  `kubernetes.podspec-persistent-volume-write` — rather than only the claim flag.
  Rationale: the claim flag (`kubernetes.podspec-persistent-volume-claim`) alone permits a
  `ksvc` to *reference* a PVC, but Knative additionally defaults PVC mounts to read-only and
  rejects a writable mount unless the second flag
  (`kubernetes.podspec-persistent-volume-write`) is also `enabled`. The Persistent Storage
  initiative's core use cases (SQLite databases, uploaded files) require read-write mounts, so
  both flags are mandatory. Enabling write is harmless when an app chooses a read-only mount.
  Date: 2026-06-09

- Decision: The committed `config-features.yaml` is a *patch body* (a file containing only the
  `data:` block), applied with `kubectl patch ... --type merge`, not a standalone full
  ConfigMap manifest applied with `kubectl apply -f`.
  Rationale: every sibling file in `cluster/bootstrap/knative-serving/`
  (`config-network.yaml`, `config-domain.yaml`, `config-certmanager.yaml`,
  `config-network-tls.yaml`) is a merge-patch body layered onto the ConfigMap that the
  upstream Knative install (`serving-core.yaml`) already creates. Following the same pattern
  keeps the bootstrap consistent and avoids clobbering the upstream ConfigMap's
  `serving.knative.dev/release` labels and any default keys. See the directory README.
  Date: 2026-06-09

- Decision: FINALIZED — the rollout-safety annotation set the renderer (EP-34) must stamp on any
  Knative Service that mounts a PVC is:
  `autoscaling.knative.dev/min-scale: "1"`, `autoscaling.knative.dev/max-scale: "1"`, and
  `serving.knative.dev/rollout-duration: "0s"`.
  Rationale: M1 tested exactly this set against the live cluster. The single-node RWO `local-path`
  PVC mounted cleanly across multiple revision rolls — the new revision reached Ready in 5–9s with
  **zero** `Multi-Attach`/`FailedMount`/`FailedAttachVolume` events, and old- and new-revision pods
  co-mounted the PVC concurrently without any stall (see Surprises). The deadlock the MasterPlan
  feared does **not** occur on a single node, because RWO permits multiple same-node pods to mount,
  and Nagare is single-node — so no *additional* anti-Multi-Attach knob (e.g.
  `no-zero-initial-scale`) is required. We still adopt min=max=1 (matching the always-on `nagared`
  Service, `cluster/bootstrap/nagared/service.yaml`) so a storage-backed app stays warm and bounds
  each revision to a single writer, and `rollout-duration: "0s"` for an immediate cut-over. The one
  residual hazard is a brief *concurrent-writer* overlap during the create-before-delete roll (two
  pods writing the same files); that is an application concern (use WAL / Litestream for SQLite),
  documented for EP-37, not a platform blocker, and not fixable by a Knative annotation.
  Date: 2026-06-09


## Outcomes & Retrospective

**Result: both milestones met; the gating feasibility risk for MasterPlan 7 is cleared.**

- **Artifact 1 (committed enablement) delivered.**
  `cluster/bootstrap/knative-serving/config-features.yaml` enables
  `kubernetes.podspec-persistent-volume-claim` and `kubernetes.podspec-persistent-volume-write`,
  documented in the directory README's patches list and apply-order block. The honest re-proof
  (M2 step 3) showed the committed file — not the throwaway M1 patch — is what flips the cluster
  from rejecting to accepting a PVC-bearing `ksvc`. The flags are left `enabled` on the live
  cluster as the durable end state.

- **Artifact 2 (IP2 verified shape) delivered.** The PVC manifest (`storageClassName: local-path`,
  `accessModes: [ReadWriteOnce]`, requested size) plus the `ksvc` `volumes`/`volumeMounts` stanza
  and the rollout annotations (`autoscaling.knative.dev/min-scale: "1"`,
  `autoscaling.knative.dev/max-scale: "1"`, `serving.knative.dev/rollout-duration: "0s"`) are
  recorded verbatim in *Interfaces and Dependencies* for EP-34 to reproduce.

- **The headline finding vs. the original fear.** The MasterPlan worried a single-node RWO
  `local-path` PVC might deadlock a Knative revision roll (old + new revision mounting
  concurrently). It does **not**: RWO is per-*node*, Nagare is single-node, so same-node pods
  co-mount freely; rolls completed in 5–9s with zero mount errors. The real residual risk is a
  brief *concurrent-writer* overlap during the create-before-delete roll — an application concern
  (SQLite needs WAL/Litestream), not a platform blocker. This reframes a risk EP-37's docs must
  carry forward.

- **Gaps / cross-plan notes.** (1) The throwaway scratch image had to change twice
  (`chainguard/busybox` lacks `nc`/`httpd`; `helloworld-go` is distroless) before landing on
  `python:3.12-alpine` — EP-37 examples must choose images that actually contain their server.
  (2) Namespace deletion does not cleanly cascade-delete Knative + PVC resources; EP-35/EP-36
  deletion flows must delete `ksvc` and PVCs explicitly and honor `RetentionPolicy`. (3) local-path
  PV node-path is `kubectl get pv <name> -o jsonpath='{.spec.local.path}'`, dir naming
  `pvc-<uid>_<ns>_<pvc>` — feeds EP-35 `storage list`/`inspect`.

- **No code changed.** Only `config-features.yaml`, the README, and this plan. All M1 artifacts
  were throwaway and have been torn down; the scratch namespace and its host directory are
  reclaimed.


## Context and Orientation

This section assumes you know nothing about this repository. Read it fully before running
anything.

**The cluster and how you reach it.** Nagare is a single-node personal PaaS running on one
Google Cloud Compute Engine virtual machine named `nagare-01`, in GCP project `tan-nb-exp`,
region `us-west1`. The VM runs NixOS, and on top of NixOS runs **k3s**, a lightweight
single-binary Kubernetes distribution. "The cluster" means this one-node k3s. The repository
root has a `CLAUDE.md` that mandates a hard rule: every `gcloud` and `kubectl` operation in
this repo targets project `tan-nb-exp` and region `us-west1` only — never any other project,
not even for read-only listing. `kubectl` is already configured on the machine where you run
these commands to talk to this cluster; you do not need to authenticate or set a context as
part of this plan. If `kubectl get nodes` returns one `Ready` node, you are pointed at the
right cluster.

**Where Knative configuration lives.** Knative Serving was installed onto the cluster from
upstream release manifests (see `cluster/bootstrap/knative-serving/README.md`, pinned to
`knative-v1.22.0`). That install created several ConfigMaps in the `knative-serving`
namespace. The repository does not store the full ConfigMaps; instead, under
`cluster/bootstrap/knative-serving/`, it stores small **patch bodies** — YAML files that
contain only a `data:` block of the keys this project wants to override — and applies them
onto the upstream ConfigMaps with `kubectl patch ... --type merge`. The existing patch-body
files are:

- `config-network.yaml` — selects the Kourier ingress and enables automatic domain claims.
- `config-domain.yaml` — sets the public base domain.
- `config-certmanager.yaml` — points Knative's cert-manager bridge at the cluster issuer.
- `config-network-tls.yaml` — enables automatic per-namespace wildcard TLS (deferred).

Each file's body is just keys under `data:`. For example, `config-network.yaml` is literally
`data:` followed by `ingress-class: kourier.ingress.networking.knative.dev` and
`autocreate-cluster-domain-claims: "true"`. There is **no** `config-features.yaml` today; this
plan creates it. The `config-features` ConfigMap is the one Knative reads to decide which
"opt-in" pod-spec features (PVCs, init containers, host paths, and so on) Services may use.

**The two feature flags.** Knative reads two keys from `config-features` to gate PVC support.
A flag whose value is the string `"enabled"` turns the capability on; the default is
`"disabled"`. The keys are:

- `kubernetes.podspec-persistent-volume-claim` — allows a `ksvc` pod template to declare a
  volume of type `persistentVolumeClaim`. Without it, the admission webhook rejects any such
  Service.
- `kubernetes.podspec-persistent-volume-write` — allows that PVC volume to be mounted
  **read-write**. Without it, Knative forces PVC mounts to read-only and rejects a writable
  mount.

We enable both (see the Decision Log for why both are required).

**Where the storage actually lands.** The PVC's data physically lives on the host. The k3s
service is configured in `nixos/hosts/nagare-01/k3s.nix` with the flag
`--default-local-storage-path=/var/lib/nagare/local-path`, which tells the built-in
`local-path` provisioner to carve per-PVC directories out of `/var/lib/nagare/local-path` on
the node's data disk. That data disk is a separate GCP persistent disk formatted ext4 and
mounted at `/var/lib/nagare`; the subdirectory `local-path` is pre-created by the
`nagare-data-layout` systemd oneshot in `nixos/hosts/nagare-01/storage.nix`. The practical
consequence for this spike: when you create a PVC bound by `local-path`, a new directory
appears under `/var/lib/nagare/local-path/` on `nagare-01`, and when you delete the PVC (and
its StorageClass reclaim policy is `Delete`, which is the `local-path` default), that
directory is removed. This is what "the data is durable on the host disk" means concretely.

**The shape of a Knative Service manifest.** Two committed examples show the exact YAML shape
you will imitate for the spike. `cluster/examples/hello-knative-service/service.yaml` is a
minimal `ksvc`: `apiVersion: serving.knative.dev/v1`, `kind: Service`, with the container
under `spec.template.spec.containers` and the autoscaling annotations under
`spec.template.metadata.annotations`. `cluster/bootstrap/nagared/service.yaml` is the richer
example that already demonstrates `volumes` and `volumeMounts` on a `ksvc` (it mounts a Secret
and an `emptyDir`) and pins `autoscaling.knative.dev/min-scale: "1"` and
`autoscaling.knative.dev/max-scale: "1"` to disable scale-to-zero. The spike's PVC-bearing
Service is structurally the same, with a `persistentVolumeClaim` volume instead of a Secret or
`emptyDir`. Both examples deploy into the namespace `personal`; the spike will use a dedicated
scratch namespace so cleanup is trivial.

**The existing persistence example, for tone.** `cluster/examples/sqlite-litestream/`
demonstrates persistence today but deliberately at the *plain Kubernetes* level — it runs a
`Deployment` (not a `ksvc`) with an `emptyDir` and a Litestream sidecar. Its header comment
notes "a real app would use a PVC on the data disk (local-path)." This spike is precisely the
work that makes "a real app would use a PVC" possible for a Knative Service. Read that
example's `deployment.yaml` and `README.md` for the house style of cluster examples (concise
header comments explaining *why*, copy-pasteable `kubectl` blocks).

**What this plan does NOT change.** No Haskell code (`cli/`), no Pulumi (`infra/`), and no
NixOS (`nixos/`) files are touched. The cluster already has the data disk, the `local-path`
provisioner, and the `/var/lib/nagare/local-path` directory; this plan does not provision
them. The only committed change is the new patch-body file plus a README line. Everything in
M1 is throwaway evidence.


## Plan of Work

The work is two milestones. M1 is a throwaway feasibility spike that answers the open
questions with live evidence. M2 turns the answer into committed configuration and re-proves
the result through that committed configuration rather than through a hand-typed live patch.

### Milestone M1 — Feasibility spike (prototyping; throwaway artifacts)

Scope: prove, by hand, on the live cluster, that a Knative Service can durably mount a
`local-path` RWO PVC and that data survives both a new-revision deploy and a scale-to-zero
cycle, and determine the rollout annotation that makes this safe on a single node. At the end
of M1, nothing is committed to the repository, but this plan contains a captured transcript
proving feasibility and a concrete chosen rollout-safety annotation set. The artifacts (a PVC
YAML and two `ksvc` YAMLs) are written to a scratch directory outside the repo (for example
`/tmp/ep33-spike/`), applied, and then everything is torn down.

This milestone explicitly establishes the "before" state too: with the feature flags off,
applying a PVC-bearing `ksvc` is rejected by the admission webhook. Capturing that rejection
is what proves the flags are load-bearing. The flags are then turned on *temporarily* by a
live `kubectl patch` (this is deliberately the throwaway path; M2 replaces it with the
committed file). The acceptance for M1 is the transcript described in
"Validation and Acceptance" below: a PVC `Bound`, a `ksvc` `Ready`, a file written and read
back, the file still present after a second revision, and still present after scale-to-zero
and scale-back.

### Milestone M2 — Durable, committed configuration (IP2 contract)

Scope: create the committed file `cluster/bootstrap/knative-serving/config-features.yaml` as a
merge-patch body enabling both flags, document it in the directory README, then prove that the
*committed* file (not the temporary M1 `kubectl patch`) is what enables PVC support. To make
that proof honest, first revert the temporary patch so the live ConfigMap shows the flags
`disabled` (or absent), confirm a PVC-bearing `ksvc` is rejected again, then apply
`config-features.yaml` exactly as the README prescribes and re-run the M1 proof. At the end of
M2, the repository carries the durable enablement, the directory README lists and documents the
new file, and this plan records the canonical IP2 YAML stanza (the PVC manifest, the
`volumes` entry, the container `volumeMounts` entry, and the rollout annotation) verbatim for
EP-34 to reproduce. This is also where the M1 throwaway scratch artifacts are finally deleted
and the host directory reclamation is confirmed.

The commands to run and the exact acceptance for each milestone are spelled out in the next
two sections.


## Concrete Steps

All commands below assume your working directory is the repository root,
`/Users/shinzui/Keikaku/bokuno/nagare`, except the scratch-file edits which write to
`/tmp/ep33-spike/`. Every `kubectl` here targets the one cluster described above (project
`tan-nb-exp`); none of these commands take a `--project` flag because `kubectl` is configured
against the cluster directly, but never repoint `kubectl` at any other cluster while following
this plan.

Throughout, the spike uses a dedicated scratch namespace named `ep33-spike` so that a single
`kubectl delete namespace ep33-spike` removes everything.

### M1 step 1 — Create the scratch namespace and the spike manifests

Create the scratch directory and namespace:

```bash
mkdir -p /tmp/ep33-spike
kubectl create namespace ep33-spike
```

Expected:

```text
namespace/ep33-spike created
```

Write the PVC manifest. A **PersistentVolumeClaim** requesting 1 gibibyte of `local-path`
storage in RWO mode:

```bash
cat > /tmp/ep33-spike/pvc.yaml <<'YAML'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ep33-data
  namespace: ep33-spike
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: local-path
  resources:
    requests:
      storage: 1Gi
YAML
```

Write the first revision of the spike Knative Service. It runs a tiny shell that serves the
contents of the volume over HTTP and lets us write into the volume via `kubectl exec`. The PVC
is mounted read-write at `/data`. The autoscaling annotations pin a single always-on replica
(the leading rollout-safety candidate); `rollout-duration: "0s"` asks Knative to cut traffic
to the new revision immediately. A label `revision-marker: v1` and an env var `REV=v1`
distinguish this revision from the next.

```bash
cat > /tmp/ep33-spike/ksvc-v1.yaml <<'YAML'
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: ep33-app
  namespace: ep33-spike
spec:
  template:
    metadata:
      annotations:
        autoscaling.knative.dev/min-scale: "1"
        autoscaling.knative.dev/max-scale: "1"
        serving.knative.dev/rollout-duration: "0s"
    spec:
      containers:
        - image: cgr.dev/chainguard/busybox:latest
          env:
            - name: REV
              value: "v1"
          command:
            - sh
            - -c
            - |
              echo "serving from $REV" > /tmp/banner
              while true; do
                printf 'HTTP/1.1 200 OK\r\nContent-Length: %s\r\n\r\n%s' \
                  "$(wc -c < /data/marker 2>/dev/null || echo 0)" \
                  "$(cat /data/marker 2>/dev/null || echo empty)" | nc -l -p 8080
              done
          ports:
            - containerPort: 8080
          volumeMounts:
            - name: data
              mountPath: /data
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: ep33-data
YAML
```

Write the second revision, identical except `REV=v2` and the env change that forces Knative to
mint a new revision when applied:

```bash
sed 's/value: "v1"/value: "v2"/' /tmp/ep33-spike/ksvc-v1.yaml > /tmp/ep33-spike/ksvc-v2.yaml
```

### M1 step 2 — Capture the "before" rejection (flags off)

First confirm the flags are not yet enabled, then attempt to apply the PVC and the Service.
The PVC alone is plain Kubernetes and will be accepted and bound; the `ksvc` should be rejected
by the Knative admission webhook because the PVC feature flag is off.

```bash
kubectl -n knative-serving get configmap config-features -o jsonpath='{.data}'; echo
kubectl apply -f /tmp/ep33-spike/pvc.yaml
kubectl apply -f /tmp/ep33-spike/ksvc-v1.yaml
```

Expected (the `config-features` data is empty or lacks our keys; the PVC binds; the `ksvc` is
denied). The exact wording comes from the Knative webhook; capture whatever you see:

```text
{}
persistentvolumeclaim/ep33-data created
Error from server (BadRequest): error when creating "/tmp/ep33-spike/ksvc-v1.yaml": admission webhook "validation.webhook.serving.knative.dev" denied the request: validation failed: must not set the field(s): spec.template.spec.volumes[0].persistentVolumeClaim
```

Record the actual rejection text in Surprises & Discoveries; it is the evidence that the flags
are load-bearing. (Note: with `local-path`, a freshly created PVC reports `Pending` until a pod
consumes it, because `local-path` uses `WaitForFirstConsumer` binding. That is expected and not
an error.)

### M1 step 3 — Temporarily enable the flags (throwaway live patch)

Turn both flags on with a live merge patch. This is the throwaway path; M2 replaces it with the
committed file.

```bash
kubectl -n knative-serving patch configmap config-features --type merge --patch \
  '{"data":{"kubernetes.podspec-persistent-volume-claim":"enabled","kubernetes.podspec-persistent-volume-write":"enabled"}}'
kubectl -n knative-serving get configmap config-features -o jsonpath='{.data}'; echo
```

Expected:

```text
configmap/config-features patched
{"kubernetes.podspec-persistent-volume-claim":"enabled","kubernetes.podspec-persistent-volume-write":"enabled"}
```

Knative re-reconciles `config-features` live; no controller restart is needed. The admission
webhook now accepts PVC volumes. Note for later: a *Service* must still be (re)applied to pick
up volume support — an already-rejected Service is not retried automatically.

### M1 step 4 — Apply the Service, write into the volume, read it back

```bash
kubectl apply -f /tmp/ep33-spike/ksvc-v1.yaml
kubectl -n ep33-spike wait --for=condition=Ready ksvc/ep33-app --timeout=180s
kubectl -n ep33-spike get pvc ep33-data
```

Expected (the `ksvc` becomes Ready, the PVC is now `Bound` because the pod consumed it):

```text
service.serving.knative.dev/ep33-app created
service.serving.knative.dev/ep33-app condition met
NAME        STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
ep33-data   Bound    pvc-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx   1Gi        RWO            local-path     30s
```

Write a durable marker file into the volume from inside the running pod, then read it back:

```bash
POD=$(kubectl -n ep33-spike get pod -l serving.knative.dev/service=ep33-app -o name | head -n1)
kubectl -n ep33-spike exec "$POD" -- sh -c 'echo "persisted-by-v1" > /data/marker'
kubectl -n ep33-spike exec "$POD" -- cat /data/marker
```

Expected:

```text
persisted-by-v1
```

### M1 step 5 — Deploy a second revision and prove the file survives

Apply the `v2` manifest. Because the env var changed, Knative mints a new revision and rolls to
it. With min=max=1 plus `rollout-duration: "0s"`, watch how the old and new pods transition.

```bash
kubectl apply -f /tmp/ep33-spike/ksvc-v2.yaml
kubectl -n ep33-spike get pod -l serving.knative.dev/service=ep33-app -w &
WATCH=$!
kubectl -n ep33-spike wait --for=condition=Ready ksvc/ep33-app --timeout=180s
kill $WATCH 2>/dev/null
```

The acceptance question this answers: does the new pod come up, or does it get stuck waiting
for the old pod to release the RWO PVC? Record the observed transition. If the new pod is ever
`Pending`/`ContainerCreating` with a `FailedAttachVolume`/`FailedMount`/`Multi-Attach` event,
that is the failure mode the rollout annotation must prevent — capture it via
`kubectl -n ep33-spike describe pod <newpod>` and note it in Surprises & Discoveries, then try
the alternative annotation candidates from the Decision Log.

Once the new revision is Ready, confirm the new pod sees the file `v1` wrote:

```bash
POD=$(kubectl -n ep33-spike get pod -l serving.knative.dev/service=ep33-app -o name | head -n1)
kubectl -n ep33-spike exec "$POD" -- printenv REV
kubectl -n ep33-spike exec "$POD" -- cat /data/marker
```

Expected — the env confirms we are on the new revision, and the marker written by `v1`
survived the roll:

```text
v2
persisted-by-v1
```

### M1 step 6 — Prove the file survives scale-to-zero and scale-back

Temporarily allow scale-to-zero, force the pod away, then bring it back by hitting the Service,
and confirm the file is still there. (We relax min-scale only to *exercise* zero; the durable
config in M2 keeps min-scale=1.)

```bash
kubectl -n ep33-spike patch ksvc ep33-app --type merge --patch \
  '{"spec":{"template":{"metadata":{"annotations":{"autoscaling.knative.dev/min-scale":"0"}}}}}'
# wait for the autoscaler's scale-to-zero grace period to elapse, then confirm zero pods
until [ "$(kubectl -n ep33-spike get pod -l serving.knative.dev/service=ep33-app --no-headers 2>/dev/null | wc -l | tr -d ' ')" = "0" ]; do sleep 5; done
kubectl -n ep33-spike get pod -l serving.knative.dev/service=ep33-app
```

Expected (no pods — scaled to zero):

```text
No resources found in ep33-spike namespace.
```

Now trigger a scale-back by curling the Service URL from inside the cluster, then read the
marker:

```bash
URL=$(kubectl -n ep33-spike get ksvc ep33-app -o jsonpath='{.status.url}')
kubectl -n ep33-spike run ep33-curl --rm -it --restart=Never --image=cgr.dev/chainguard/curl -- "$URL"
POD=$(kubectl -n ep33-spike get pod -l serving.knative.dev/service=ep33-app -o name | head -n1)
kubectl -n ep33-spike exec "$POD" -- cat /data/marker
```

Expected — the curl returns the marker the server reads from `/data/marker`, and the direct
read confirms it survived scale-to-zero:

```text
persisted-by-v1
persisted-by-v1
```

### M1 step 7 — Finalize the rollout-safety decision

From the observations in steps 5 and 6, finalize the Decision Log entry on the rollout-safety
knob to one concrete annotation set. If min=max=1 plus `rollout-duration: "0s"` produced a
clean roll with no `Multi-Attach` stall, adopt exactly that and record it. If a stall was
observed, record which alternative cleared it (for example dropping `rollout-duration` or
keeping only min=max=1) and adopt that. The chosen annotation set becomes part of the IP2
contract recorded in M2.

### M2 step 1 — Create the committed `config-features.yaml`

Create the new patch-body file, matching the format of the sibling files (a header comment
explaining *why*, then a bare `data:` block):

```bash
cat > cluster/bootstrap/knative-serving/config-features.yaml <<'YAML'
# Patch body for the knative-serving `config-features` ConfigMap.
#
# Enables PersistentVolumeClaim (PVC) volumes on Knative Services so Nagare apps
# can mount durable storage (the `local-path` data disk at
# /var/lib/nagare/local-path). Verified by EP-33's spike: a ksvc mounting a
# local-path ReadWriteOnce PVC keeps its data across a revision roll and a
# scale-to-zero cycle.
#
#   - kubernetes.podspec-persistent-volume-claim: enabled
#       Allow a Service pod template to declare a `persistentVolumeClaim` volume.
#   - kubernetes.podspec-persistent-volume-write: enabled
#       Allow that PVC volume to be mounted READ-WRITE (without this, Knative
#       forces PVC mounts read-only). Both are required for SQLite / uploads.
#
# Applied as a merge patch onto the upstream-installed ConfigMap, like the other
# files here (it does NOT replace the whole ConfigMap or its release labels):
#   kubectl -n knative-serving patch configmap config-features \
#     --type merge --patch "$(cat cluster/bootstrap/knative-serving/config-features.yaml)"
#
# Knative re-reconciles config-features live; no controller restart is needed.
# A Service must be (re)deployed to pick up volume support.
data:
  kubernetes.podspec-persistent-volume-claim: "enabled"
  kubernetes.podspec-persistent-volume-write: "enabled"
YAML
```

### M2 step 2 — Document the new file in the directory README

Add `config-features.yaml` to the "ConfigMap patches" list and the "Apply order" block of
`cluster/bootstrap/knative-serving/README.md`, mirroring the existing entries. In the patches
list, add a bullet describing the file; in the apply-order block, add the patch command. Use the
Edit tool to insert these; the exact strings are:

For the patches list (after the `config-certmanager.yaml` bullet), add:

```text
- `config-features.yaml` — enables PVC volume + read-write mounts (EP-33). **Applied** to allow
  Nagare apps to mount durable `local-path` storage.
```

For the apply-order block (after the cert-manager patch command), add:

```bash
# PVC volume support (EP-33)
kubectl -n knative-serving patch configmap config-features \
  --type merge --patch "$(cat cluster/bootstrap/knative-serving/config-features.yaml)"
```

### M2 step 3 — Honest re-proof through the committed file

Revert the throwaway live patch so the flags are no longer enabled, confirm rejection returns,
then enable via the committed file and confirm acceptance returns. Reverting sets the keys back
to `disabled` (the upstream default) rather than removing them, which is unambiguous:

```bash
kubectl -n knative-serving patch configmap config-features --type merge --patch \
  '{"data":{"kubernetes.podspec-persistent-volume-claim":"disabled","kubernetes.podspec-persistent-volume-write":"disabled"}}'
kubectl delete -f /tmp/ep33-spike/ksvc-v2.yaml --ignore-not-found
kubectl apply -f /tmp/ep33-spike/ksvc-v1.yaml
```

Expected — with the flags back to `disabled`, the webhook rejects the PVC Service again:

```text
configmap/config-features patched
service.serving.knative.dev "ep33-app" deleted
Error from server (BadRequest): ... must not set the field(s): spec.template.spec.volumes[0].persistentVolumeClaim
```

Now enable via the committed file exactly as the README prescribes, then re-apply and re-verify
durability:

```bash
kubectl -n knative-serving patch configmap config-features \
  --type merge --patch "$(cat cluster/bootstrap/knative-serving/config-features.yaml)"
kubectl apply -f /tmp/ep33-spike/ksvc-v1.yaml
kubectl -n ep33-spike wait --for=condition=Ready ksvc/ep33-app --timeout=180s
POD=$(kubectl -n ep33-spike get pod -l serving.knative.dev/service=ep33-app -o name | head -n1)
kubectl -n ep33-spike exec "$POD" -- cat /data/marker
```

Expected — the committed config enables PVCs, and the marker from earlier is still on the disk:

```text
configmap/config-features patched
service.serving.knative.dev/ep33-app configured
service.serving.knative.dev/ep33-app condition met
persisted-by-v1
```

### M2 step 4 — Tear down the scratch spike and reclaim host storage

Delete the scratch namespace (which removes the `ksvc`, pods, and the PVC), and confirm the
`local-path` host directory is reclaimed. Because the `local-path` StorageClass reclaim policy
is `Delete`, deleting the PVC removes its directory under `/var/lib/nagare/local-path` on
`nagare-01`.

```bash
kubectl get pvc -n ep33-spike
kubectl delete namespace ep33-spike
```

Expected:

```text
NAME        STATUS   VOLUME    CAPACITY   ACCESS MODES   STORAGECLASS   AGE
ep33-data   Bound    pvc-...   1Gi        RWO            local-path     10m
namespace "ep33-spike" deleted
```

To confirm reclamation on the host (run on `nagare-01`, or via the project's SSH helper
`scripts/iap-ssh.sh`), the per-PVC directory whose name contains `pvc-...` should be gone:

```bash
ls /var/lib/nagare/local-path/
```

Expected — the spike's `pvc-...ep33-spike-ep33-data...` directory is no longer listed (only
unrelated entries, if any, remain). If you instead want a PVC's data to *survive* deletion, you
would create a StorageClass copy with `reclaimPolicy: Retain`; that retention behavior is the
typed `RetentionPolicy` field EP-34 introduces and is out of scope here — the spike PVC uses the
default `Delete`.

### M2 step 5 — Record the IP2 canonical stanza and commit

Paste the verified canonical YAML into the "Interfaces and Dependencies" section below (it is
pre-filled there with the leading-candidate annotation; correct it if M1 chose differently),
then commit the two repository changes:

```bash
git add cluster/bootstrap/knative-serving/config-features.yaml \
        cluster/bootstrap/knative-serving/README.md \
        docs/plans/33-knative-pvc-enablement-spike-and-cluster-feature-flags.md
git commit
```

Use this commit message (note the mandatory `ExecPlan:` trailer and the `Intention:` trailer
from the plan frontmatter):

```text
feat(cluster): EP-33 enable Knative PVC volumes via config-features

Add cluster/bootstrap/knative-serving/config-features.yaml enabling
kubernetes.podspec-persistent-volume-claim and -persistent-volume-write so
Nagare apps can mount durable local-path storage. Document it in the directory
README and record the verified IP2 volume/volumeMount + rollout annotation
shape proven by the EP-33 spike.

ExecPlan: docs/plans/33-knative-pvc-enablement-spike-and-cluster-feature-flags.md
Intention: intention_01ktqfjpdqewga3t0rm9crehxx
```


## Validation and Acceptance

Acceptance is phrased as observable behavior on the live cluster, captured as transcripts in
the steps above. The plan is complete when all of the following hold:

The cluster *rejects* a PVC-bearing Knative Service while the feature flags are off (M1 step 2
and M2 step 3 both capture the admission-webhook `must not set the field(s):
spec.template.spec.volumes[...].persistentVolumeClaim` rejection). This proves the flags are
load-bearing rather than incidental.

With the flags enabled — and specifically with the *committed*
`cluster/bootstrap/knative-serving/config-features.yaml` applied the way the README prescribes
(M2 step 3) — the Service `ep33-app` reaches `Ready` (`kubectl wait
--for=condition=Ready ksvc/ep33-app` returns "condition met") and its PVC `ep33-data` shows
`Bound` with `ACCESS MODES = RWO` and `STORAGECLASS = local-path` (`kubectl get pvc`).

A file written into the volume from inside the pod (`echo persisted-by-v1 > /data/marker`) is
readable back (`cat /data/marker` prints `persisted-by-v1`), survives deploying a second
revision (M1 step 5: env `REV` reads `v2` while the marker still reads `persisted-by-v1`), and
survives a scale-to-zero followed by a scale-back triggered by a request (M1 step 6: zero pods
observed, then after a curl the marker still reads `persisted-by-v1`).

The rollout-safety annotation set is decided from observed behavior (M1 step 7) and recorded
both in the Decision Log and in the IP2 stanza below; the new revision rolls in without the new
pod stalling on a `Multi-Attach`/`FailedMount` event (or, if such a stall is observed without
the annotation, the chosen annotation set is the one that clears it, with the failing
`kubectl describe pod` output captured as evidence).

The scratch namespace is deleted cleanly and the per-PVC host directory under
`/var/lib/nagare/local-path` is reclaimed (M2 step 4).

The repository carries `cluster/bootstrap/knative-serving/config-features.yaml` and the updated
README, committed with the `ExecPlan:` trailer.

There are no unit tests in this plan — it touches no code — so validation is entirely the live
behavioral evidence above. The next plan
(`docs/plans/34-typed-volume-and-mount-model-with-pvc-and-volumemount-renderer.md`, EP-34) is
where golden/unit tests appear, and its renderer must emit the IP2 stanza recorded below.


## Idempotence and Recovery

Applying the committed configuration is idempotent. `kubectl patch ... --type merge` on
`config-features` is a set-these-keys-to-these-values operation: running M2 step 3's patch
command again yields the same ConfigMap state and the harmless message `configmap/config-features
patched (no change)` or `patched`. Re-running it never accumulates drift.

`kubectl apply -f` on the PVC and the Service manifests is likewise idempotent; re-applying an
unchanged manifest reports `unchanged` or `configured` and leaves the cluster in the same state.
Re-applying the same `ksvc` does not mint a new revision unless the pod template actually
changed.

The scratch spike is fully disposable. Everything M1 creates lives in the `ep33-spike`
namespace and in `/tmp/ep33-spike/`. If anything goes wrong mid-spike, run
`kubectl delete namespace ep33-spike` (removes the `ksvc`, pods, and PVC) and `rm -rf
/tmp/ep33-spike`, then start M1 over. Deleting the namespace is safe and repeatable; it cannot
affect any other workload because nothing else uses that namespace.

Reclamation caveat. Because the `local-path` StorageClass default reclaim policy is `Delete`,
deleting the PVC (directly or by deleting the namespace) removes its host directory under
`/var/lib/nagare/local-path` on `nagare-01`. That is the desired cleanup for a throwaway spike.
If you ever need a PVC's data to outlive deletion, do not delete the PVC; the durable
"keep on delete" behavior is the typed `RetentionPolicy` (Retain vs Delete) that EP-34 adds to
the model and is out of scope here.

Recovering the cluster config. The temporary live patch in M1 step 3 is reverted in M2 step 3,
and then the committed file is applied. If you abandon the spike before M2, leave the flags in a
known state by running M2 step 1 to create the file and M2 step 3's final patch to apply it (the
durable, intended end state is "both flags enabled via the committed file"). To fully back out
all changes, set both keys to `"disabled"` with a merge patch (as in M2 step 3's revert
command) and `git checkout -- cluster/bootstrap/knative-serving/` to drop the new file and
README edit.


## Interfaces and Dependencies

This plan has no code dependencies — it imports no libraries, defines no Haskell types, and is
not imported by anything at build time. It produces two artifacts that downstream plans depend
on:

**Artifact 1 — the committed enablement file.**
`cluster/bootstrap/knative-serving/config-features.yaml`, a merge-patch body that sets
`kubernetes.podspec-persistent-volume-claim: "enabled"` and
`kubernetes.podspec-persistent-volume-write: "enabled"` on the `knative-serving` namespace's
`config-features` ConfigMap. It is applied the same way as its sibling files, via
`kubectl -n knative-serving patch configmap config-features --type merge --patch "$(cat
cluster/bootstrap/knative-serving/config-features.yaml)"`, documented in
`cluster/bootstrap/knative-serving/README.md`. Every later plan in MasterPlan 7 that performs a
*live* deploy of a PVC-bearing app soft-depends on this file having been applied to the cluster.

**Artifact 2 — Integration Point IP2: the verified rendered PVC / volume / volumeMount / rollout
shape.** This is the contract that
`docs/plans/34-typed-volume-and-mount-model-with-pvc-and-volumemount-renderer.md` (EP-34) must
reproduce exactly in its renderer (`cli/nagare-dsl/src/Nagare/Dsl/Render.hs` and
`cli/nagare-dsl/src/Nagare/Dsl/Server/Render.hs`) and golden files. EP-33 owns the *facts* about
what the cluster accepts; EP-34 encodes those facts. The canonical shape below was **VERIFIED by the M1/M2 spike on the live
cluster** (2026-06-09) — the rollout annotation set shown (`min-scale: "1"`, `max-scale: "1"`,
`rollout-duration: "0s"`) is the finalized choice from M1 step 7; the new revision reached Ready in
5–9s across rolls with zero `Multi-Attach`/`FailedMount` events. EP-34's renderer and golden files
must reproduce exactly this shape. (`<app-namespace>` is the app's namespace, e.g. `personal`; the
spike used `ep33-spike`.):

The standalone PVC manifest, one per declared volume:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: <pvc-name>          # EP-34 names this deterministically (IP3); e.g. nagare-vol-<app>-<volume>
  namespace: <app-namespace>
spec:
  accessModes:
    - ReadWriteOnce         # single-node only; the only mode local-path supports
  storageClassName: local-path
  resources:
    requests:
      storage: <size>       # e.g. 1Gi, from the typed Quantity field
```

The Knative Service pod-template additions — the `volumes` entry referencing the PVC, the
container `volumeMounts` entry, and the rollout-safety annotation(s) on
`spec.template.metadata.annotations`:

```yaml
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: <app>
  namespace: <app-namespace>
spec:
  template:
    metadata:
      annotations:
        # Rollout-safety knob for single-node RWO PVCs (finalize from M1 step 7).
        autoscaling.knative.dev/min-scale: "1"
        autoscaling.knative.dev/max-scale: "1"
        serving.knative.dev/rollout-duration: "0s"
    spec:
      containers:
        - image: <image>
          volumeMounts:
            - name: <volume-name>
              mountPath: <mount-path>   # absolute, e.g. /data
              readOnly: <bool>          # from the typed readOnly field
      volumes:
        - name: <volume-name>
          persistentVolumeClaim:
            claimName: <pvc-name>       # same name as the PVC manifest above
```

The required cluster preconditions for the cluster to accept the above are the two feature flags
in Artifact 1. EP-34 does not re-enable them; it assumes EP-33's file has been applied (a soft
dependency expressed in the MasterPlan). The renderer's YAML key-ordering table in `Render.hs`
(`knativeConfig`/`ranks`) must be extended to place `volumeMounts` and `volumes`
deterministically, following the existing `env`/`resources` ordering pattern — but that is
EP-34's work; this plan only fixes the *shape* the renderer must produce.
