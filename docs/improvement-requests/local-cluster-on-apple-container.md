---
type: Improvement Request
title: Support native Apple container Kubernetes through reviewed local bootstrap
description: Add a native Apple container Kubernetes backend for reviewed substrate, registry, kubeconfig and platform bootstrap while retaining k3d as an explicit alternative.
timestamp: "2026-10-28T12:30:00Z"
generated:
  by: process:claude-code
  at: "2026-09-13T13:45:00Z"
requestId: IR-6
status: accepted
acceptedAt: "2026-10-28T12:30:00Z"
targetPlan: docs/plans/220-run-reviewed-local-bootstrap-on-native-apple-container-kubernetes.md
origin: mori://shinzui/nagare
reviews:
  - kind: model
    reviewer: process:openai-codex
    reviewed_at: "2026-09-14T14:45:36Z"
    document_timestamp: "2026-09-13T13:45:00Z"
    scope: content-and-metadata
    outcome: approved
    provider: openai
    model: gpt-5.6-sol
    effort: high
    context: >-
      Audited the research against Nagare's current k3d, registry, kubeconfig,
      Docker image-build, and local-mode surfaces and the stated portability
      constraints; no implementation decision or target plan exists, so the
      proposed status and local-platform fit remain accurate.
  - kind: model
    reviewer: process:codex-cli
    reviewed_at: "2026-10-28T04:34:17Z"
    document_timestamp: "2026-10-28T04:34:17Z"
    scope: content-and-metadata
    outcome: commented
    provider: openai
    model: gpt-6.1-sol
    effort: unspecified
    context: >-
      Refresh IR-6 with the v0.10.0 bootstrap failure and native Apple Kubernetes
      qualification from Kotei Plan 84. The operator explicitly permits temporary
      k3d qualification without waiting for this request. Historical spike evidence
      is retained; this is an author review, not independent acceptance.
verified:
  by: process:openai-codex
  at: "2026-09-14T14:45:36Z"
---

# Support native Apple container Kubernetes through reviewed local bootstrap

**Status:** accepted on 2026-10-28; implemented by
[ExecPlan 220](../plans/220-run-reviewed-local-bootstrap-on-native-apple-container-kubernetes.md).

## Request and priority

Add a supported Apple container Kubernetes backend to the reviewed local platform
bootstrap. Prefer the native `container k8s` / `container cluster` command group
selected from the installed CLI's help. Retain k3d as an explicit alternative.
The older direct-k3s experiment below is historical evidence, not the required design.

The operator requested this follow-up on 2026-10-28 while implementing
`mori://shinzui/kotei/plans/84-deploy-to-nagare-through-its-reviewed-resource-inventory`.
The same instruction authorizes temporary k3d use to finish that plan. **IR-6 does
not block Kotei's reviewed-inventory acceptance or require Apple bootstrap to ship
first.** Preserve Kotei's Apple backend and qualification evidence in the meantime.

## Concrete released limitation

Kotei pins Nagare v0.10.0, source
`16f0d7be4ab03a44716c81b03c6b433103e32651`. Its native Apple fixture
`kotei-nagare84` is Ready on arm64 Kubernetes v1.35.5. Packaged Kotei execution,
output/replay, normal release, targeted/run stop and cleanup-deadline recovery pass
there with namespace-scoped runtime authority. That proves a usable Kubernetes
substrate; it does not establish Nagare's reviewed foundation.

On that fixture, `nagarectl --context local platform bootstrap plan --out DIR`
fails in artifact observation: `k3d cluster list` cannot contact Docker. Source at
the pin also hardcodes k3d publication, registry naming, runtime labels and
`k3d kubeconfig get` in:

- `cli/nagarectl/app/Nagare/Cli/Bootstrap/Local.hs`
- `cli/nagarectl/app/Nagare/Cli/Bootstrap/Host.hs`
- `scripts/inventory-artifact-transport.sh`
- `cli/nagarectl/src/Nagare/Inventory/Adapters/ArtifactRuntime.hs`
- `cli/nagarectl/src/Nagare/Inventory/Components/LocalObjectStore.hs`
- `cluster/bootstrap/local-substrate.json`

Changing the launcher alone therefore cannot satisfy reviewed bootstrap.

## Requested behavior

1. Make the local substrate specification and context select the backend, named
   cluster, immutable node image and registry settings. Do not identify an Apple
   cluster solely by a reused Kubernetes context name.
2. Implement Apple cluster/registry observation and reviewed provisioning. Preserve
   digest-bound reviews, resource ownership and lifecycle protection, identity and
   drift checks, accepted retry behavior and journal-driven recovery. Existing
   unrelated clusters or registries must not be adopted implicitly.
3. Export a private kubeconfig through the selected native command group, select
   the returned context explicitly, and preserve context/cluster identity guards
   and reviewed credential publication. Do not merge into the ambient kubeconfig.
4. Make registry publication and pulls work from both the workstation and the
   Linux Kubernetes node. Verify TLS/plain-HTTP trust explicitly, ingress reachability,
   Knative/Kourier, local object storage and bootstrap image architecture support.
   Remove k3d-specific host assumptions from the selected Apple path. Verify the
   optional admin API's read-only inventory mount when that feature is selected.
5. Support prebuilt Docker/dockerTools archives without a Docker daemon. Any
   bootstrap images or optional build paths required by Apple bootstrap must also
   work without Colima. Node image loading cannot substitute for the reviewed OCI
   publication contract being qualified.

## Acceptance

- On an authorized Apple silicon Mac with Docker/Colima stopped, plan and apply
  supported reviewed bootstrap through the native Apple Kubernetes backend.
- Record CLI and plugin versions, selected command group, node image digest,
  Kubernetes version, context identity and review/transaction evidence.
- Publish a prebuilt image through the ordinary inventory path, pull it from the
  node and reach a ready application through the installed platform ingress.
- Repeated unchanged bootstrap converges without replacement. Changed identities,
  foreign ownership, changed review inputs and incorrect kubeconfigs refuse before
  unrelated resources are changed. Exercise interrupted apply and supported recovery.
- Keep the k3d local smoke/qualification path passing as an explicit backend.
- Publish a release containing the backend and operator instructions so consumers
  can pin immutable released source and repeat their deployment/rollback/drift tests.

Kotei owns its two-release/rollback/drift acceptance. Passing this upstream request
supplies its future Apple bootstrap prerequisite, not a substitute for that proof.
Cloud substrate changes, broad automatic adoption and a Docker-API compatibility
shim are outside this request.

## Historical research: direct k3s experiment, September 2026

The original IR-6 experiment used Apple container 1.2.2 and a directly launched k3s
image. The following findings describe that earlier spike; commands and alternatives
below are not current implementation or acceptance requirements.

### Original motivation

The local development substrate (MasterPlan 16, ExecPlan 82) is a k3d cluster, and k3d requires a
Docker daemon. On the operator's Mac that daemon comes from Colima: a Linux VM that holds memory
and CPU for as long as it runs, whether or not a cluster is up.

Apple Container is already installed and in daily use on the same machine. The Redpanda setup
moved off Colima onto it
(`mori://shinzui/redpanda-container/masterplans/1-run-redpanda-locally-on-apple-container-via-nix`),
so Colima is kept around mostly for nagare's local mode. Apple Container runs each container as its
own lightweight VM that exists only while the container runs, which is the resource saving that
motivates this request.


### Findings

#### k3d cannot use Apple Container

k3d starts no containers itself. It drives the Docker Engine API over a socket
(`DOCKER_HOST=unix://~/.colima/docker.sock` today). Apple Container 1.2.2 has no Docker-compatible
socket. Third-party shims such as socktainer exist, but k3d depends on many Docker details
(networks, labels, exec, copying files into containers, privileged mode), so a shim is fragile and
was not pursued. The Redpanda setup avoided the same problem by calling `container run` directly.
That is the approach assessed here.

#### k3s runs directly as an Apple Container (spike, 2026-09-13)

k3d is only a launcher for the `rancher/k3s` image, so the spike ran that image directly, using the
pin from the `justfile` (`rancher/k3s:v1.34.6-k3s1`).

1. **Naive run fails.** Apple Container has no `--privileged` flag. With only `--cap-add ALL`:

   ```bash
   container run -d --name k3s-spike --cap-add ALL -m 3g -c 2 \
     --tmpfs /run --tmpfs /var/run rancher/k3s:v1.34.6-k3s1 server --disable=traefik
   ```

   the kubelet exits with
   `Failed to start ContainerManager: open /proc/sys/kernel/panic: read-only file system`, preceded
   by `Failed to set sysctl ... read-only file system` errors.

2. **One remount fixes it.** Remounting `/proc/sys` read-write, then exec'ing k3s:

   ```bash
   container run -d --name k3s-spike --cap-add ALL -m 3g -c 2 \
     --tmpfs /run --tmpfs /var/run --entrypoint /bin/sh rancher/k3s:v1.34.6-k3s1 \
     -c 'mount -o remount,rw /proc/sys; mount --make-rshared /; exec /bin/k3s server --disable=traefik'
   ```

   gave a `Ready` node in about 15 seconds (kernel `6.18.15`, Apple Container's default Kata kernel;
   containerd `2.2.2`). CoreDNS, local-path-provisioner and metrics-server all reached `Running`.

3. **In-cluster networking works at the basic level.** An `nginx:alpine` Deployment rolled out, and a
   busybox pod resolved `web.default.svc.cluster.local` (`DNS-OK`) and fetched
   `<title>Welcome to nginx!</title>` through the ClusterIP Service.

4. **Resource use.** `container stats` showed about 903 MiB memory and about 11% CPU with those pods
   running, inside a 3 GiB / 2-CPU VM that exists only while the cluster does.

5. **Warnings to watch.** k3s could not load `br_netfilter`, `iptable_nat`, `iptable_filter` and
   several `nft` modules with modprobe. DNS and Service routing still worked, so the needed pieces
   appear to be built into the kernel. Nothing heavier was tested (see Open questions).

The spike container was removed afterwards. Nothing in the repository was changed.

#### What nagare uses from k3d today

Most of k3d is unused. `just local-up` creates one server with no agents. Four things are used and
would need a replacement:

| k3d provides | Used at | Replacement |
|---|---|---|
| Managed registry `k3d-registry.localhost:5000`, joined to the cluster network, with `registries.yaml` injected | `justfile` `local-up`; default in `scripts/lib/target.sh:269`; `nagare.local.env.example`; `scripts/local-smoke.sh:25`; `scripts/test-render-context-template.sh`, `scripts/test-image-build-guard.sh`, `scripts/test-bucket-ownership-guard.sh` | A `registry:2` Apple Container on a user-defined `container network`, published on host port 5000, plus a `registries.yaml` mounted into the k3s container. Keeping the hostname `k3d-registry.localhost:5000` means no consumer changes. |
| Host ports 80/443 via the k3d load-balancer container | `justfile` `local-up` (`--port "80:80@loadbalancer"`) | `container run -p 80:80 -p 443:443 -p 6443:6443` on the server container, relying on k3s's built-in servicelb for LoadBalancer Services. **Untested.** |
| Kubeconfig export | `scripts/local-smoke.sh:91,121,124` (`k3d kubeconfig`) | Copy `/etc/rancher/k3s/k3s.yaml` out of the container and point it at `127.0.0.1:6443`. |
| Lifecycle (`k3d cluster create/delete`) | `justfile` `local-up`, `local-down` | `container run` / `container rm -f` for the containers, network and volume. Cluster state survives stop/start if `/var/lib/rancher/k3s` is on a named volume. |

Also k3d-specific: the docs. Roughly ten pages under `docs/user/` and
`docs/capabilities/local-platform-substrate.md` name k3d. `host.k3d.internal` is referenced nowhere.

#### Image builds are the larger dependency on Docker

Even with the cluster moved, these still call the `docker` CLI and need a daemon:

- `cli/nagarectl/src/Nagare/Image.hs:60`: `nagarectl` runs `docker build`, and the build description
  in `cli/nagarectl/test/Spec.hs:2795` asserts the `docker build --platform ...` form.
- `cluster/bootstrap/auth-images/build-local-image.sh:411,425,432`: `docker build` / `docker push`.
- `cluster/bootstrap/nagare-access/build-image.sh:36,48`: `docker build` / `docker push`.

If these are not moved to `container build` / `container image push`, Colima still has to start
for any local deploy, and most of the saving is lost. Pushing to a plain-HTTP local registry with
`container image push` has not been checked.


### What would be lost versus k3d

- **Portability.** k3d runs anywhere Docker runs, including Linux and Intel Macs. Apple Container
  requires Apple silicon, and user-defined networks (needed for the registry) require macOS 26. If
  anyone other than this operator runs local mode, k3d must stay as a supported alternative.
- **One-command multi-node clusters.** Not used today. Extra nodes would be additional k3s containers
  joined with the server token, scripted by hand.
- **A widely used, maintained launcher.** The `/proc/sys` remount and the manual registry wiring
  become nagare-owned workarounds, and an Apple Container or k3s release could break them with less
  community help than k3d has.

Gained: launching plain k3s is arguably closer to production. nagare-01 runs k3s directly on NixOS,
so `registries.yaml` and server flags would be handled the same way locally and in the cloud.


