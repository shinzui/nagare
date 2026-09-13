---
type: Improvement Request
title: Run the local cluster on Apple Container instead of k3d on Colima
description: Replace the k3d-on-Colima local substrate with k3s launched directly as an Apple Container, and make local image builds work without a Docker daemon.
timestamp: "2026-09-13T13:45:00Z"
generated:
  by: process:claude-code
  at: "2026-09-13T13:45:00Z"
requestId: IR-6
status: proposed
origin: mori://shinzui/nagare
---

# Improvement Request: run the local cluster on Apple Container instead of k3d on Colima

**Authored by:** a `claude-code` research session on 2026-09-13, including a hands-on spike on the
operator's workstation (macOS 26, Apple silicon, `container` CLI 1.2.2).
**Addressed to:** `shinzui/nagare` agents.
**Status:** proposed. **Undecided**: the operator has not yet decided whether this is worth
implementing. This request exists to keep the research; accepting it means writing an ExecPlan
with the gates under Required verification.
**Created:** 2026-09-13.


## Why

The local development substrate (MasterPlan 16, ExecPlan 82) is a k3d cluster, and k3d requires a
Docker daemon. On the operator's Mac that daemon comes from Colima: a Linux VM that holds memory
and CPU for as long as it runs, whether or not a cluster is up.

Apple Container is already installed and in daily use on the same machine. The Redpanda setup
moved off Colima onto it
(`mori://shinzui/redpanda-container/masterplans/1-run-redpanda-locally-on-apple-container-via-nix`),
so Colima is kept around mostly for nagare's local mode. Apple Container runs each container as its
own lightweight VM that exists only while the container runs, which is the resource saving that
motivates this request.


## Findings

### k3d cannot use Apple Container

k3d starts no containers itself. It drives the Docker Engine API over a socket
(`DOCKER_HOST=unix://~/.colima/docker.sock` today). Apple Container 1.2.2 has no Docker-compatible
socket. Third-party shims such as socktainer exist, but k3d depends on many Docker details
(networks, labels, exec, copying files into containers, privileged mode), so a shim is fragile and
was not pursued. The Redpanda setup avoided the same problem by calling `container run` directly.
That is the approach assessed here.

### k3s runs directly as an Apple Container (spike, 2026-09-13)

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

### What nagare uses from k3d today

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

### Image builds are the larger dependency on Docker

Even with the cluster moved, these still call the `docker` CLI and need a daemon:

- `cli/nagarectl/src/Nagare/Image.hs:60`: `nagarectl` runs `docker build`, and the build description
  in `cli/nagarectl/test/Spec.hs:2795` asserts the `docker build --platform ...` form.
- `cluster/bootstrap/auth-images/build-local-image.sh:411,425,432`: `docker build` / `docker push`.
- `cluster/bootstrap/nagare-access/build-image.sh:36,48`: `docker build` / `docker push`.

If these are not moved to `container build` / `container image push`, Colima still has to start
for any local deploy, and most of the saving is lost. Pushing to a plain-HTTP local registry with
`container image push` has not been checked.


## What would be lost versus k3d

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


## Requested change

If accepted:

- Add an Apple Container launcher for the local cluster (`just local-up` variant or a runtime
  switch): k3s server container with the `/proc/sys` remount, a registry container on a shared
  network, published ports 80/443/6443/5000, a named volume for k3s state, kubeconfig export, and a
  matching teardown.
- Keep k3d on Colima (or any Docker) working as a selectable fallback until the new path passes
  every gate below, and indefinitely if portability matters.
- Let local image builds and pushes run without a Docker daemon: `nagarectl`'s build step and the
  two bootstrap build scripts gain an Apple Container path (`container build`, `container image push`).
- Keep the local-mode guardrail in `scripts/lib/target.sh` intact. The registry host must still pass
  the loopback assertion that lets `_require_target_project` step aside, so a local context can
  never point at a real `*.pkg.dev` registry.
- Update `docs/user/local-development.md`, `docs/capabilities/local-platform-substrate.md` and the
  other k3d mentions to describe both runtimes.


## Required verification

- `just local-smoke` passes end to end on the Apple Container substrate, including Knative Serving
  with Kourier reachable on host ports 80/443 and the local auth plane from ExecPlan 85.
- An image built and pushed with no Docker daemon running (Colima stopped) is pulled by the cluster
  from `k3d-registry.localhost:5000` and serves traffic.
- Cluster state survives `local-down`-style stop followed by start when the named volume is kept, or
  the documentation says plainly that it does not.
- The k3d path still passes `just local-smoke`.
- A before/after measurement of host memory with the cluster running (Colima + k3d vs Apple
  Container), so the decision rests on numbers rather than the expectation that it uses less.


## Open questions

- Does Kourier / Knative's networking work with the missing netfilter modules, and would
  NetworkPolicy enforcement behave the same as on nagare-01 if nagare starts relying on it?
- Does k3s servicelb bind host-published ports correctly inside an Apple Container VM?
- Can `container image push` push to a plain-HTTP registry, or does the local registry need TLS?
- Is `--platform linux/amd64` cross-building (ExecPlan 67) usable through `container build` with
  Rosetta, or must local builds stay native arm64?
- Is a Docker-API shim (for example socktainer) mature enough that k3d and the existing `docker`
  calls could run unchanged? That would be a smaller change than rewriting the launcher, if it holds up.


## Acceptance

An operator on an Apple silicon Mac can bring up the local cluster, build and deploy an app, and
pass `just local-smoke` with Colima stopped. The k3d path remains available and tested, and the
memory difference between the two is recorded.


## Non-goals

This request does not ask to remove k3d, Colima or Docker from the supported toolchain, to support
multi-node local clusters, to change the cloud substrate on nagare-01, or to relax the cloud-mode
guardrail in any way.
