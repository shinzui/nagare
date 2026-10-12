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

Full plan before trimming: [33-knative-pvc-enablement-spike-and-cluster-feature-flags.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/33-knative-pvc-enablement-spike-and-cluster-feature-flags.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

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

