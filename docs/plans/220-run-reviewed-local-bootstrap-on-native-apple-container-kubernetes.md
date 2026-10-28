---
id: 220
slug: run-reviewed-local-bootstrap-on-native-apple-container-kubernetes
title: "Run reviewed local bootstrap on native Apple container Kubernetes"
kind: exec-plan
created_at: 2026-10-28T12:06:37Z
intention: "intention_01m616f2qeedz8bf5620wzbz54"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-10-28T12:06:37Z
---

# Run reviewed local bootstrap on native Apple container Kubernetes

This ExecPlan is a living document. Progress holds the deliverables with pass/fail evidence and
the Decision Log holds dated decisions that change scope or design (operator decision,
2026-10-10). It implements
[IR-6](../improvement-requests/local-cluster-on-apple-container.md).


## Purpose / Big Picture

Today a local Nagare context (`mode=local`) can only run on k3d, a launcher that starts k3s
inside Docker. On the operator's Mac that means Colima, a Linux VM that holds memory and CPU
while it runs. Apple's `container` CLI is already installed and in daily use on the same Mac. Its
`container k8s` command group (renamed `container cluster` in Apple container 1.6.1) creates a
single-node Kubernetes cluster from a pinned `kindest/node` image. Each Apple container is its
own small VM that exists only while it runs.

Kotei proved that cluster is a usable Kubernetes substrate (its fixture `kotei-nagare84`, arm64
Kubernetes v1.35.5). It could not install Nagare on it. Nagare v0.10.0's
`nagarectl --context local platform bootstrap plan --out DIR` fails at once: the artifact
observer runs `k3d cluster list`, and Docker is not running. Source:
`mori://shinzui/kotei/plans/84-deploy-to-nagare-through-its-reviewed-resource-inventory`.

After this plan, an operator on an Apple silicon Mac with Docker and Colima stopped can do this:

```bash
nagarectl context create apple --mode local --local-backend apple-container \
  --local-cluster nagare-apple --registry-host nagare-registry.localhost:5001 \
  --base-domain 127-0-0-1.sslip.io --target-platform linux/arm64 \
  --local-object-store http://minio.nagare-system.svc.cluster.local:9000/nagare-backups --use
review="$(mktemp -d)"; nagarectl platform bootstrap plan --out "$review"
nagarectl platform bootstrap apply "$review" --yes   # repeat plan/apply until "no pending stage"
```

The result is a reviewed Nagare platform (Knative, Kourier, cert-manager, MinIO, auth plane,
observability) on a native Apple cluster. A prebuilt image archive deployed with the ordinary
`nagarectl` inventory path then answers at `http://<app>.127-0-0-1.sslip.io`. Re-running
bootstrap with nothing changed does nothing. A foreign cluster with the same name, a changed node
image, an edited review or a wrong kubeconfig is refused before anything else changes. k3d
remains a supported backend, and existing k3d contexts plan exactly as before.


## Progress

- [ ] M1: Prototype on a disposable Apple cluster (labelled prototyping; scripts are not
  committed). Pass: the Decision Log has a dated entry answering each M1 question in Plan of
  Work with a short transcript. These are command group and versions, node identity, API
  endpoint and certificate names, the registry pull path, name resolution, ingress, the storage
  class, restart stability and host mounts. Every answer either confirms the design below or
  records the replacement design.
- [ ] M2: The context and the packaged specification select the backend. Pass: a new
  `cluster/bootstrap/local-substrate-apple.json` pins the node, registry and edge images by
  digest. The context adds `NAGARE_LOCAL_BACKEND` and `NAGARE_LOCAL_CLUSTER`, and the k3d spec
  is byte-identical. Unit tests show a k3d context's substrate scope and review are unchanged
  (golden), an Apple context compiles three resources of the new artifact kinds, and
  mismatched registry host, unknown backend and (if M1 finds no mount) admin API on Apple are
  refused at plan time.
- [ ] M3: The Apple substrate adapter, proved by interpreter. Pass: `AppleSubstrateSpec` in
  `nagarectl-test` drives the real adapter against a fake `AppleContainerOps`. It covers fresh
  create, unchanged convergence with zero mutations, a same-name foreign cluster refused (never
  adopted), a changed node image refused, multiple matches refused, a missing or ambiguous
  command group refused, interruption at every effect step with each case ending in either
  completion or a reviewed refusal (ADR 26), and recorded physical identity read through the
  checked accessor (ADR 27). `just gate-fast` is green.
- [ ] M4: Kubeconfig, registry and ingress on the Apple path. Pass: specs show the kubeconfig is
  exported to a private file only, its sole context is selected explicitly, and the endpoint
  and cluster identity guards hold, with `~/.kube/config` left untouched. OCI observation and
  publication reach the Apple registry over loopback with no `docker` call. The node's
  containerd pull configuration, the Kourier node-port binding and the storage class are
  reviewed resources. `scripts/test-inventory-transport-guards.sh` is extended and green, and
  `git grep -n 'k3d\|docker '` on the Apple code paths lists only k3d-branch lines.
- [ ] M5: Bootstrap images without a Docker daemon. Pass: with Colima stopped, the MinIO
  server and client images and the en, shomei and nagare-access images are built with
  `container build`. Each is saved as an OCI archive and published with `skopeo`, and the
  scripts print exact `@sha256:` references that bootstrap accepts.
- [ ] M6: Native confirmation on an Apple silicon Mac with Docker and Colima stopped (ADR 25:
  confirms only). Pass: the evidence block in Validation and Acceptance is filled in. That means
  versions, command group, node image digest, Kubernetes version, context identity, review and
  transaction IDs, full plan/apply to "no pending stage", a dockerTools archive and a
  `docker save` archive published and pulled from the node, a ready app over the installed
  ingress, an unchanged re-plan, every listed refusal, an interrupted apply with its supported
  recovery, and the admin API mount if M1 supports it.
- [ ] M7: k3d stays a supported, explicit backend, and the docs are current. Pass:
  `just local-smoke` passes on a k3d context. `docs/user/local-development.md`,
  `docs/capabilities/local-platform-substrate.md`, `nagare.local.env.example` and the
  canonical-variable list in `CLAUDE.md` document both backends. IR-6 is `completed`
  with `completedAt` and a `resolution` citing this plan.
- [ ] M8: Released. Pass: a published Nagare release contains M2–M7 and passes the release
  rules in `CLAUDE.md` (full gate, EP-172 rehearsal, intranet upgrade). Its notes name the
  Apple backend and link the operator instructions, so Kotei can pin the immutable released
  source.


## Surprises & Discoveries

(Not used; operator decision 2026-10-10.)


## Decision Log

2026-10-28: k3d keeps `cluster/bootstrap/local-substrate.json` byte-for-byte, and the default
backend is `k3d`. The Apple backend gets its own packaged spec and new artifact kinds
(`AppleClusterArtifact`, `AppleRegistryArtifact`, `AppleEdgeArtifact`, wire tokens
`apple-cluster`, `apple-registry`, `apple-edge`) under the same `local-substrate` scope owner.
An accepted k3d context then composes an identical scope. No release-transition rule or
compatibility shim is needed, which follows the no-speculative-shims rule since v0.4.0.

2026-10-28: Apple observation and publication run in Haskell behind an operations record with an
in-memory interpreter, not in `scripts/inventory-artifact-transport.sh`. The ownership, identity
and recovery rules are where defects would hide. ADR 25 requires that they be found by
interpreters, and ADR 24 holds tooling to the production Haskell standard. Only the
`container` subprocess calls stay at the edge.

2026-10-28: The loopback contract in `scripts/lib/target.sh` `_require_target_project` is not
changed. Apple containers sit on a vmnet subnet (here `192.168.64.0/24` to `192.168.66.0/24`),
which the guardrail would rightly refuse. So everything the workstation reaches is published on
`127.0.0.1` by Nagare-owned containers. The registry container publishes `127.0.0.1:5001`, since
AirPlay owns `:5000` on macOS. A small edge forwarder container publishes `127.0.0.1:80` and
`127.0.0.1:443` to the node's pinned Kourier node ports. The base domain stays
`127-0-0-1.sslip.io`.

2026-10-28: `container k8s create` (plugin 1.2.2) takes only name, CPUs, memory, scheme, node
image and CNI. It has no labels, port mappings or mounts. Ownership therefore cannot be a
creation-time label as on k3d. In the same reviewed operation, right after create, Nagare writes
a marker ConfigMap `kube-system/nagare-local-substrate` carrying the spec digest, cluster name
and context name. It also records the node container's ID and `creationDate` as the physical
identity (ADR 27). A same-name cluster without a matching marker and identity is foreign and is
refused, never adopted. M1 must confirm the plugin exposes no label option before this stands.

2026-10-28: Select the command group from the selected executable's help. Use `k8s` or
`cluster`, and refuse when neither or both are present. Record `container --version` and the
group's own `--version` separately: Kotei found CLI 1.5.0 running a 1.2.2 `k8s` plugin.

2026-10-28: Bootstrap images are built with Apple's builder (`container build`), saved with
`container image save` as OCI archives and published with `skopeo`, so the reviewed
publication contract is unchanged. Node image loading (`container k8s load-image`) is never used
for publication. A Docker-API shim, cloud substrate changes and automatic adoption are out of
scope (IR-6).

2026-10-28: IR-6 does not block Kotei. Kotei may finish its plan 84 on k3d as the operator
authorized. This plan provides Kotei's future Apple prerequisite, not its two-release,
rollback and drift acceptance.


## Outcomes & Retrospective

(Not used; operator decision 2026-10-10.)


## Context and Orientation

**Local mode.** A Nagare *context* is a named bundle of `export VAR=value` lines in
`${XDG_CONFIG_HOME:-$HOME/.config}/nagare/contexts/<name>.env`. `NAGARE_MODE=local` points
every primitive at loopback substitutes: a local cluster, a local registry, MinIO for object
storage. `cli/nagarectl/src/Nagare/Target.hs` parses contexts into `TargetProfile` (fields such
as `registryHost`, `baseDomain`, `adminApiEnabled`) and renders them back with `line "NAGARE_…"`.
`scripts/lib/target.sh` is the shell side. Its `_require_target_project` lets a local context
proceed only when `NAGARE_BASE_DOMAIN` and `NAGARE_REGISTRY_HOST` are provably loopback
(`localhost`, `*.localhost`, `127.x.x.x`, or a `127-…` sslip.io/nip.io name). See
`docs/user/local-development.md` for the current k3d operator flow.

**Reviewed bootstrap and the inventory.** `nagarectl platform bootstrap plan --out DIR` writes a
review: a digest-bound plan of the next pending *stage*. `nagarectl platform bootstrap apply DIR
--yes` executes it as a journaled *transaction*. The journal is a durable log in which intent is
written before each external effect and completion after it, so an interrupted apply can be
recovered. Stages run in the order in `cli/nagarectl/app/Nagare/Cli/Bootstrap/Sequence.hs`
`planNextStage`: local substrate, then cloud (skipped locally), host image and host (cloud only),
kubeconfig, then platform. Each stage compiles a *scope*: an owner (for example
`Platform/local-substrate`) and its declared resources, composed into the context's inventory
(ADR 22).

**The k3d coupling, file by file.**

- `cluster/bootstrap/local-substrate.json` is the packaged k3d spec: cluster `nagare-local`,
  registry `registry.localhost` published as `k3d-registry.localhost:5000`, the
  `rancher/k3s:v1.34.6-k3s1` image, load-balancer ports 80/443, and `--disable=traefik`.
- `cli/nagarectl/app/Nagare/Cli/Bootstrap/Local.hs` decodes that spec into `LocalSubstrateSpec`.
  `buildLocalSubstrateCandidate` declares two artifacts, `LocalRegistryArtifact` (named
  `k3d-registry.localhost`) and `LocalClusterArtifact`, each `Protect`ed. It returns no
  candidate once both observe present. With the admin API enabled, `localSubstrateSpecSource`
  writes a derived spec with `inventoryMount` beside the context's store, so the digest changes.
- `scripts/inventory-artifact-transport.sh` is the subprocess that observes and publishes
  artifacts for `cli/nagarectl/src/Nagare/Inventory/Adapters/ArtifactRuntime.hs`. It speaks one
  canonical JSON request on stdin and one observation (`TransportMissing`, `TransportPresent`,
  `TransportOwnershipMismatch`) on stdout. Its `load_local_substrate` accepts only the exact k3d
  values. `observe_local_registry` and `observe_local_cluster` call `k3d … list -o json` and
  `docker inspect`, and the publish branches call `k3d registry create` and
  `k3d cluster create … --runtime-label nagare.bootstrap.digest=…`. `observe_oci_image` and
  `publish_oci_archive` special-case `k3d-registry.localhost:5000`. `ArtifactRuntime.hs`
  `expectedPhysical` maps the local kinds to `k3d-registry://` and `k3d-cluster://`.
- `cli/nagarectl/app/Nagare/Cli/Bootstrap/Host.hs` `buildKubeconfigStageCandidateWithRecovery`,
  in its `Local` branch, runs `k3d kubeconfig get <cluster>`. It then calls
  `normalizeLocalKubeconfig` (`cli/nagarectl/src/Nagare/Cluster/Kubeconfig.hs`), which demands a
  loopback `https://127.0.0.1:` endpoint.
- `cli/nagarectl/src/Nagare/Inventory/Components/LocalObjectStore.hs` `readLocalRegistryDigest`
  and `scripts/lib/local-registry.sh` read manifests by `docker exec k3d-registry.localhost wget`,
  because AirPlay owns host port 5000. They also hard-code `k3d-registry.localhost:5000` for the
  MinIO images.
- Image publication needs Docker in `scripts/publish-local-minio-images.sh`
  (`docker build`/`push` of the MinIO release binaries), `cluster/bootstrap/auth-images/build-local-image.sh`
  (builders `docker`, `cloud-build`, `k3s-import`) and
  `cluster/bootstrap/nagare-access/build-image.sh`. The platform stage
  (`cli/nagarectl/app/Nagare/Cli/Bootstrap/Platform.hs`) requires `NAGARE_AUTH_EN_IMAGE`,
  `NAGARE_AUTH_SHOMEI_IMAGE` and `NAGARE_AUTH_ACCESS_IMAGE` as immutable references, plus the
  MinIO images for a local object store.
- Ingress. Kourier's Service (`cluster/bootstrap/vendor/kourier-v1.22.0.yaml`, bound by digest in
  `cli/nagarectl/src/Nagare/Inventory/Components/Upstream.hs`) is `type: LoadBalancer`. k3s's
  ServiceLB plus k3d's load balancer map host 80/443 to it. Kind has no load balancer, but the
  Service still gets node ports. Kourier readiness is its Deployments, not a load-balancer
  address.
- Storage. `Nagare.Inventory.VolumeRestore` and `Nagare.Storage.Restore` require
  `storageClassName: local-path`. k3s ships that class; kind nodes ship the same provisioner
  under the class name `standard`. M1 confirms this.

**Apple container on this Mac (observed 2026-10-28).** `container --version` reports CLI 1.5.0
(commit `d265d66`). `container k8s --help` lists `create`, `delete`, `list`, `load-image` and
`write-config`, and `container cluster` is unknown. `k8s create` takes `--name` (default
`k8s-dev`), `--cpus`, `--memory`, `--scheme`, `--node-image` (default
`docker.io/kindest/node:v1.35.5@sha256:ce977ae6d65918d0b58a5f8b5e940429c2ce42fa3a5619ec2bbc60b949c0ac95`)
and `--cni`. `k8s list` has no JSON output. `write-config --name N --kubeconfig FILE` writes or
appends a context, defaulting to `~/.kube/config`. Kotei saw that it does not set the current
context. `container run` supports `--label`, `--publish`, `--network`, `--volume`, `--mount` and
DNS options. `container inspect` prints JSON with `configuration.id`, `labels`, `creationDate`
and the image digest. Containers on one network resolve each other by name, as the Redpanda
setup relies on. `container build`, `container image save -o` and
`container image push --scheme http` exist.

**Relevant ADRs.**
[ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md): every
managed resource has one owner and is declared before external mutation. Intent precedes each
effect, and ambiguous interruption stops automatic replay unless adapter evidence proves a safe
resolution.
[ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md): find
defects with in-memory interpreters of the adapter operations. A native run only confirms.
[ADR 26](../adr/0026-stopped-transactions-close-by-per-operation-proof.md): a stopped
transaction closes by per-operation proof, not by allowlists of shapes.
[ADR 27](../adr/0027-physical-identity-is-recorded-at-creation-and-read-through-one-checked-accessor.md):
record the provider's physical identity at creation and read it through one checked accessor.
That identity tells an owned object from an out-of-band replacement at the same address.
[ADR 4](../adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md): packaged
specs live in the immutable payload, and derived per-context files live in the context
workspace, as the admin API spec already does.
[ADR 24](../adr/0024-release-and-harness-tooling-follows-the-production-haskell-standard.md) and
[ADR 16](../adr/0016-adopt-haskell-jitsurei-for-production-haskell.md): Haskell style.
Background plans: `docs/plans/82-local-cluster-registry-and-local-target-bootstrap-for-nagare.md`
(the k3d substrate) and `docs/masterplans/16-local-development-and-testing-for-nagare.md`.


## Plan of Work

**M1 — prototype (bounded; discard the scripts).** On a disposable cluster named
`nagare-proto`, answer these questions and record each as a dated Decision Log entry:

1. Command group and versions: the output of `container --version`, `container k8s --version`
   and `container --help`.
2. Node identity: `container k8s list` columns. Find the node container's name and run
   `container inspect` on it to get its labels, `creationDate`, network and address. Confirm
   that `k8s create` cannot set a label.
3. API endpoint: the `server:` line of a `write-config` export to a fresh private file. Read the
   apiserver certificate's SANs with `openssl s_client -connect <endpoint> </dev/null |
   openssl x509 -noout -ext subjectAltName`, and note whether `127.0.0.1` is present.
4. Registry: run `docker.io/library/registry:2` pinned by digest as
   `container run -d --name nagare-proto-registry -p 127.0.0.1:5001:5000`. Find whether
   `/etc/containerd/certs.d` is containerd's `config_path` in the node
   (`container exec <node> containerd config dump | grep config_path`). Write
   `/etc/containerd/certs.d/nagare-registry.localhost:5001/hosts.toml` pointing at
   `http://<registry by name or address>:5000`. Push a dockerTools archive from the workstation
   with `skopeo copy docker-archive:… docker://127.0.0.1:5001/…`, and pull it with `crictl pull`
   inside the node.
5. Name resolution: can the node and a second container resolve `nagare-proto-registry` and the
   node by name? Which network did the plugin put the node on?
6. Ingress: run an nginx Deployment with a `LoadBalancer` Service whose `nodePort` is pinned to
   30080. Run an edge forwarder (a digest-pinned `alpine/socat`, or nginx `stream`) on the node's
   network with `-p 127.0.0.1:80:80`, forwarding to `<node>:30080`, then
   `curl -H 'Host: x' http://127.0.0.1/`.
7. Storage: `kubectl get storageclass`.
8. Restart stability: `container stop` and `container start` the node, or reboot. Check whether
   the node's address, name resolution, `hosts.toml` and the marker ConfigMap persist.
9. Host mounts: is there any way to give the node a read-only host directory for the admin API's
   `/var/lib/nagare/inventory`?

Delete everything afterwards with `container k8s delete --name nagare-proto` and
`container rm -f`. Promotion rule: the design below stands for each answer that matches it.
Otherwise the Decision Log entry states the replacement before M2 starts. If question 3 shows no
`127.0.0.1` SAN and the endpoint is the node address, the Apple kubeconfig normalizer accepts
exactly `https://<observed reviewed-node address>:6443`, and an address change surfaces as
kubeconfig drift needing the existing reviewed credential transition. If question 9 finds no
mount, the Apple backend refuses `NAGARE_ADMIN_API_ENABLED=1` at plan time, and that limitation
goes to the deferral ledger with the operator's approval.

**M2 — selection.** Add `cluster/bootstrap/local-substrate-apple.json`:

```json
{
  "version": 1,
  "backend": "apple-container",
  "nodeImage": "docker.io/kindest/node:v1.35.5@sha256:ce977ae6d65918d0b58a5f8b5e940429c2ce42fa3a5619ec2bbc60b949c0ac95",
  "cpus": 4,
  "memory": "8g",
  "registry": { "image": "docker.io/library/registry:2@sha256:<pinned in M1>", "publish": "127.0.0.1:5001", "containerPort": 5000 },
  "edge": { "image": "<pinned in M1>", "publish": ["127.0.0.1:80", "127.0.0.1:443"], "nodePorts": { "http": 30080, "https": 30443 } },
  "storageClass": "local-path"
}
```

In `Nagare.Target`, add `localBackend` (`K3d | AppleContainer`, from `NAGARE_LOCAL_BACKEND`,
default `k3d`) and `localCluster` (from `NAGARE_LOCAL_CLUSTER`, default `nagare-local`) to
`TargetProfile`. Render both, add `--local-backend` and `--local-cluster` to
`nagarectl context create`, and project both through `.envrc` and `scripts/lib/target.sh`. A k3d
context ignores `localCluster` other than its default and refuses a different value, because
its spec fixes the name. In `Bootstrap/Local.hs`, turn `LocalSubstrateSpec` into a sum
`K3dSubstrate K3dSpec | AppleSubstrate AppleSpec`, chosen by the context. Decoding the k3d spec
stays exactly as now. For Apple, write a derived spec beside the context's store, in the same
way `localSubstrateSpecSource` does for the admin API. That derived spec adds `cluster` (the
context's name), `context` and `registryHost` from the context, so the reviewed digest covers
every context selection. Then declare the three Apple artifacts: registry first, the cluster
ordered after it, the edge ordered after the cluster. Add the new `ArtifactKind` constructors
and wire tokens in `cli/nagarectl/src/Nagare/Inventory/Artifact.hs`, with physical prefixes
`apple-registry://`, `apple-cluster://` and `apple-edge://` in `ArtifactRuntime.hs`.

**M3 — adapter.** Create `cli/nagarectl/src/Nagare/Inventory/Adapters/AppleContainer.hs`. It
holds an operations record, `AppleContainerOps`, with one field per subprocess call: help text,
versions, cluster list, container inspect, image pull, `k8s create`, `write-config` to a given
path, `exec` into the node with stdin, `run` and `rm` of a named container, and a kubectl call
against a given kubeconfig. The production interpreter runs the `container` executable
resolved from `PATH`, or from `NAGARE_APPLE_CONTAINER` when set. Pure functions do the work:
`selectCommandGroup`, then `classifyAppleCluster`, `classifyAppleRegistry` and
`classifyAppleEdge`. These map observations plus the reviewed spec to the existing
`TransportObservation`-shaped result.

A cluster is present and owned when exactly one listed cluster has the name and its node
container is running. Its node image digest must equal the spec. The marker ConfigMap must
carry the expected digest, and the node container ID and `creationDate` must equal the
recorded identity. When no identity is recorded yet, the converging transaction records it.
Anything else is an ownership mismatch with a specific reason. The registry and edge containers
are created by Nagare, so they carry `--label nagare.bootstrap.digest=<digest>` and
`--label nagare.context=<context>`, checked like k3d's runtime label.

Publication runs in a fixed order. For the cluster: create, then `write-config` to a private
temporary file, then the marker, then the containerd `hosts.toml`, then observe. For the
registry and edge: pull by digest, run with labels and publish flags, then observe. Recovery
follows ADR 26. An interrupted cluster create observed with no marker is completed (marker
written) only when its node container's `creationDate` is later than the transaction's recorded
intent and it is the only match. Otherwise it refuses with the half-created cluster named for
the operator. In `ArtifactRuntime.mkArtifactRuntimeOps`, dispatch the three Apple kinds to this
module instead of `runTransport`. The k3d kinds keep the shell transport.

**M4 — kubeconfig, registry, ingress, storage.** In `Bootstrap/Host.hs`, the `Local` branch
switches on the backend. The Apple branch calls `write-config` into a fresh `0700` temporary
directory under the context's `prepared-kubeconfig`, selects its sole context explicitly, and
checks that the cluster name equals the reviewed cluster. It then calls a new
`normalizeAppleKubeconfig` in `Nagare.Cluster.Kubeconfig`, which takes the endpoint rule from M1.
Everything after that (digest-named prepared file, `KubeconfigArtifact`, the
`sameKubeconfigProjection` guard, `KubeconfigRecover`) is unchanged, so the existing reviewed
credential publication applies.

Generalize the registry reads. `observe_oci_image` and `publish_oci_archive` gain an Apple
branch that sends wire traffic to `127.0.0.1:<published port>` (generalizing
`NAGARE_LOCAL_REGISTRY_FORWARD`) with explicit `--tls-verify=false` and
`--dest-tls-verify=false` for that loopback endpoint only. `readLocalRegistryDigest` and
`scripts/lib/local-registry.sh` read manifests over the same loopback HTTP endpoint, not through
`docker exec`, and take the registry host from the context instead of the k3d literal.

For the Apple backend, the platform stage adds a reviewed Nagare-authored patch of the
`kourier-system/kourier` Service that pins `nodePort`s to the spec's values. The vendored
Kourier bytes stay as pinned. It also adds a `local-path` StorageClass with the kind node's
provisioner when M1 shows one is missing. The node's containerd `hosts.toml` is part of the
cluster publication in M3, and its content digest is observed with the cluster.

**M5 — daemonless images.** `scripts/publish-local-minio-images.sh` gains a builder switch.
`NAGARE_LOCAL_IMAGE_BUILDER=apple-container` runs `container build --platform linux/arm64`,
then `container image save -o`, then `skopeo copy oci-archive:…` to the loopback registry, and
reads the architecture from `container system status` instead of `docker info`.
`cluster/bootstrap/auth-images/build-local-image.sh` gets `NAGARE_AUTH_BUILDER=apple-container`
with the same three steps. `cluster/bootstrap/nagare-access/build-image.sh` follows. Both print
the exact `<registryHost>/<repo>@sha256:` references that `selectLocalMinioImages` and the
`NAGARE_AUTH_*_IMAGE` checks accept. Docker stays the default builder for k3d contexts.

**M6 — native confirmation.** Run Concrete Steps 4–7 and fill in the evidence block. Any defect
found here goes back into an M3 or M4 interpreter test before it is fixed (ADR 25).

**M7 — k3d parity and documentation.** Run `just local-smoke` on a k3d context, with Colima
started for that step only. Update `docs/user/local-development.md` with an "Apple container
backend" section covering prerequisites, context creation, bring-up, teardown and
troubleshooting (ports 80/443/5001 already held, command group rename). Also update
`docs/capabilities/local-platform-substrate.md`, `nagare.local.env.example`, the `justfile`
`local-up`/`local-down` comments (`local-down` deletes the Apple cluster with the selected command
group when the backend is Apple) and the canonical-variable list in `CLAUDE.md` (add
`NAGARE_LOCAL_BACKEND` and `NAGARE_LOCAL_CLUSTER`). Mark IR-6 `completed` with `completedAt` and a
`resolution`.

**M8 — release.** Ride the next ordinary release (`nagare-release` skill, `just gate-release
REV`, EP-172 rehearsal, intranet upgrade). The release notes name the backend and link
`docs/user/local-development.md`.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/nagare` unless stated.
Per Haskell commit, run `just haskell-style-check` and check its exit code, then `just gate-fast`.
Per landing, run `just gate-fast` with a clean tree, then `just land`. Stage files by explicit
path; never `git add -A`.

1. M1 prototype, with Docker and Colima stopped:

    ```bash
    colima status 2>&1 | head -1            # expect: not running
    container --version; container k8s --version; container --help | grep -E '^\s+(k8s|cluster)\b'
    container k8s create --name nagare-proto --cpus 4 --memory 8g
    proto="$(mktemp -d)"; chmod 700 "$proto"
    container k8s write-config --name nagare-proto --kubeconfig "$proto/kubeconfig"
    grep 'server:' "$proto/kubeconfig"
    container k8s list
    ```

    Continue through the M1 questions, record answers in the Decision Log, then
    `container k8s delete --name nagare-proto` and `container rm -f` the registry and edge.

2. M2–M4 focused tests while developing:

    ```bash
    cabal test nagarectl-test --test-options '-p /AppleSubstrate/'
    cabal test nagarectl-test --test-options '-p /LocalSubstrate/'
    bash scripts/test-inventory-transport-guards.sh
    ```

    Expect every case to pass. The k3d golden case shows the same scope digest as before the
    change.

3. M5, with Colima stopped:

    ```bash
    NAGARE_LOCAL_IMAGE_BUILDER=apple-container scripts/publish-local-minio-images.sh
    NAGARE_AUTH_BUILDER=apple-container cluster/bootstrap/auth-images/build-local-image.sh
    ```

    Expect lines of the form
    `nagare-registry.localhost:5001/nagare-minio@sha256:<64 hex>`.

4. M6 bring-up on a fresh context `apple-ir6`, using a packaged build of the candidate
   (`nix build "git+file://$PWD?rev=<sha>#nagarectl"`; the dev binary lacks the controller image
   archive), in a clean environment (`env -i` plus `nagarectl context env`):

    ```bash
    nagarectl context create apple-ir6 --mode local --local-backend apple-container \
      --local-cluster nagare-apple-ir6 --registry-host nagare-registry.localhost:5001 \
      --base-domain 127-0-0-1.sslip.io --target-platform linux/arm64 \
      --local-object-store http://minio.nagare-system.svc.cluster.local:9000/nagare-backups
    export NAGARE_CONTEXT=apple-ir6
    while :; do
      review="$(mktemp -d)"
      nagarectl platform bootstrap plan --out "$review" || break
      nagarectl platform bootstrap apply "$review" --yes
    done
    ```

    The loop ends when plan reports that no stage is pending. Record each review and transaction
    ID it prints.

5. Prebuilt image path: deploy a fixture app whose image is a dockerTools archive, then one
   produced by `docker save` (that archive is prepared earlier on a k3d machine and copied in;
   Docker stays stopped here). Use the ordinary `nagarectl` app plan/apply, then:

    ```bash
    curl -sS -o /dev/null -w '%{http_code}\n' http://<app>.127-0-0-1.sslip.io/   # expect 200
    ```

6. Negative cases, each on a fresh plan and each expecting a refusal that names the cause before
   any effect:
   - `container k8s create --name nagare-foreign` and a context naming it (foreign cluster);
   - the derived spec's `nodeImage` edited (changed identity);
   - one byte changed in a review file (changed review input);
   - `~/.config/nagare/kubeconfigs/apple-ir6.yaml` replaced with another cluster's export
     (incorrect kubeconfig).

7. Interrupted apply: start the cluster-stage apply, capture its PID, and `kill <pid>` while
   `container k8s create` runs. Then run `nagarectl platform bootstrap plan` and follow the
   recovery it reports. Expect completion or a reviewed refusal, never a silent replay. Stop
   processes only by captured PID.


## Validation and Acceptance

Acceptance is M6's evidence plus M7's k3d smoke test. Fill this block in during M6:

```text
container CLI version / commit:
command group (k8s|cluster) and its version / commit:
node image digest:                      Kubernetes version (kubectl version):
context name / cluster name / kubeconfig context / node UID:
bootstrap reviews and transactions (stage -> review id -> transaction id):
unchanged re-plan output:
dockerTools archive digest -> registry digest -> node pull ok:
docker-save archive digest -> registry digest -> node pull ok:
app URL -> HTTP status:
refusals (foreign / node image / review edit / kubeconfig) -> message:
interrupted apply -> recovery outcome:
admin API mount (supported? verified read-only?):
```

Failure looks like any `k3d` or `docker` invocation on the Apple path, any write to
`~/.kube/config`, a second bootstrap that plans a mutation, or a refusal that happens only after
another resource changed.


## Idempotence and Recovery

Plan/apply is idempotent by construction: an observed-present, owned resource yields no
candidate. M1 uses its own cluster name and containers and deletes them, and it never touches an
existing cluster (here the Redpanda containers and Kotei's fixtures). To remove an Apple context's
substrate deliberately, use `just local-down` on that context, then
`container rm -f nagare-registry-<context> nagare-edge-<context>`; the registry's data is
disposable. If an apply is interrupted, re-run `nagarectl platform bootstrap plan`. The journal
and the M3 recovery rules decide whether to complete or refuse. Never delete a cluster to
"unstick" a transaction without the refusal naming it as this transaction's partial effect.
When any guard refuses, stop and report.


## Interfaces and Dependencies

New in `cli/nagarectl/src/Nagare/Inventory/Adapters/AppleContainer.hs`:

```haskell
data CommandGroup = K8sGroup | ClusterGroup
  deriving stock (Eq, Show)

data AppleContainerOps = AppleContainerOps
  { helpText :: !(IO (Either Text Text))
  , versions :: !(CommandGroup -> IO (Either Text AppleVersions))
  , listClusters :: !(CommandGroup -> IO (Either Text [AppleClusterRow]))
  , inspectContainer :: !(Text -> IO (Either Text (Maybe AppleContainerFacts)))
  , pullImage :: !(Text -> IO (Either Text ()))
  , createCluster :: !(CommandGroup -> AppleClusterRequest -> IO (Either Text ()))
  , writeConfig :: !(CommandGroup -> Text -> FilePath -> IO (Either Text ()))
  , execInNode :: !(Text -> [Text] -> ByteString -> IO (Either Text ByteString))
  , runContainer :: !(AppleRunRequest -> IO (Either Text ()))
  , kubectlAt :: !(FilePath -> [Text] -> ByteString -> IO (Either Text ByteString))
  }

selectCommandGroup :: Text -> Either Text CommandGroup
classifyAppleCluster :: AppleSpec -> Maybe RecordedIdentity -> AppleClusterFacts -> ArtifactObservation
```

Changed: `Nagare.Target.TargetProfile` (`localBackend`, `localCluster`);
`Nagare.Inventory.Artifact.ArtifactKind` (three constructors);
`Nagare.Cli.Bootstrap.Local.LocalSubstrateSpec` (sum type);
`Nagare.Cluster.Kubeconfig` (`normalizeAppleKubeconfig`);
`Nagare.Inventory.Adapters.ArtifactRuntime.mkArtifactRuntimeOps` (Apple dispatch);
`Nagare.Inventory.Components.LocalObjectStore.readLocalRegistryDigest` (registry host and
endpoint from the context). External tools: Apple `container` 1.5.0 or later with the `k8s` or
`cluster` group, `skopeo`, `kubectl` and `jq`. No new Haskell dependencies. This is a standalone
plan with no parent MasterPlan.
