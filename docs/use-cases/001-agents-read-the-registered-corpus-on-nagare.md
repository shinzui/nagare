---
title: "Use Case 001 — Agents Running on Nagare Read the Whole Registered Corpus"
type: Use Case
description: "An agent working inside one project on Nagare reads and greps the source and documentation of every other Mori-registered project, so it can understand real APIs and types instead of guessing from memory."
generated:
  by: claude-code/2.1.221
  at: "2026-08-04T14:22:54Z"
useCaseId: UC-1
status: draft
origin: mori://shinzui/nagare
themes:
  - agent-platform
jobs:
  - name: read-across-projects
    actor: coding agent running on Nagare
    situation: a change in one project depends on APIs, types, or conventions owned by other registered projects
    motivation: read the other projects' actual source and docs rather than recalling or inferring their interfaces
    outcome: the agent greps and reads real files at local-disk speed and cites what it read
  - name: keep-the-corpus-current
    actor: Nagare operator
    situation: registered projects move upstream while agents are reading the on-cluster copy
    motivation: have agents read current code without hand-maintaining a copy on the cluster
    outcome: a repeatable sync brings the corpus to a known revision without disturbing readers
features:
  - name: shared-read-only-corpus-mount
    description: One durable corpus volume co-mounted read-only into every agent workload on the single node.
    status: discovered
    owners:
      - mori://shinzui/nagare
    acceptance: Several agent pods read the same corpus mount concurrently and no workload can mutate the corpus through that mount.
    jobs:
      - read-across-projects
  - name: corpus-materialization-from-the-registry
    description: Build the on-cluster corpus from git using the registry as the project list, rather than copying workstation working trees.
    status: discovered
    owners:
      - mori://shinzui/nagare
      - mori://shinzui/mori
    acceptance: The materialized corpus carries every in-scope project's tracked files, carries no build output, and is reproducible from the registry alone.
    jobs:
      - read-across-projects
      - keep-the-corpus-current
  - name: corpus-root-indirection
    description: Resolve registered project paths against a configurable corpus root instead of the absolute path of the authoring workstation.
    status: discovered
    owners:
      - mori://shinzui/mori
    acceptance: Path resolution returns a correct in-container path when the corpus root differs from the machine where the project was registered.
    jobs:
      - read-across-projects
  - name: dedicated-corpus-disk
    description: A second attached disk and its own StorageClass, so corpus bulk and churn stay off the data disk that carries databases, observability, and backups.
    status: discovered
    owners:
      - mori://shinzui/nagare
    acceptance: Exhausting the corpus volume cannot exhaust the data disk, and a corpus sync does not contend with database IO.
    jobs:
      - keep-the-corpus-current
  - name: storage-class-selection-in-the-typed-volume-model
    description: Let a declared Volume name its StorageClass so a corpus volume is expressible in a typed config rather than hand-applied YAML.
    status: discovered
    owners:
      - mori://shinzui/nagare
    acceptance: A config declaring a corpus volume renders a PersistentVolumeClaim bound to the corpus StorageClass.
    jobs:
      - keep-the-corpus-current
  - name: registry-metadata-reachable-from-pods
    description: Serve the Mori registry's own state to agent pods as a cluster-local managed database.
    status: discovered
    owners:
      - mori://shinzui/nagare
      - mori://shinzui/mori
    acceptance: Concurrent agent pods run registry queries against the cluster database with no shared filesystem involved.
    jobs:
      - read-across-projects
---

# Use Case 001: agents running on Nagare read the whole registered corpus

An agent changing one project routinely has to understand others — the exact signature a library
exports, how a sibling service frames a concept, what a dependency actually does rather than what
its README claims. The standing operating rule is to locate that code through Mori and **read it
directly on disk**. On a workstation this is trivial: the registry resolves a local path and the
agent greps a filesystem that is already there.

On Nagare there is no such filesystem inside an agent pod. This use case is about closing that gap
for the **read** direction only. Agents also occasionally write to other projects — to file an
improvement request — but that path is deliberately out of scope here and is handled by the
coordination bundles rather than by shared storage.


## What "read" actually requires

It requires a real POSIX filesystem in the pod, not a service in front of one.

Mori's HTTP API (`mori serve`) exposes **project information** — identity, packages, docs, catalogs,
dependency edges. That is the discovery half of the job and it works well over the network. It is
not a code-content service, and understanding a codebase is not a sequence of metadata lookups: the
agent needs to run ripgrep across a tree, follow an import to the file that defines it, and read
whole modules. Serving that over HTTP replaces a fast local scan with a chatty remote protocol and
loses the tools that make code comprehension tractable.

So the corpus has to be mounted. The question is what to mount, from where, and on what disk.


## Measurements

Taken 2026-08-04 against the live registry on the authoring workstation.

| Measure | Value |
|---|---|
| Registered projects | 161 |
| Working-tree size, all registered paths | **378.2 GB** |
| `.git` across all 463 repositories | **3.1 GB** |
| `dist-newstyle` (71 directories) | 132.4 GB |
| `node_modules` (82 directories) | 7.3 GB |
| Two largest single projects combined | 202 GB |

The shape of this table is the whole finding. Working trees are unshippable to a single-node VM,
but the *tracked* content — what an agent actually greps — is small. The bulk is build output, and
`.direnv` adds a second problem of its own: it is symlinks into `/nix/store`, which resolve to
nothing inside a container.

The conclusion is to **materialize the corpus from git rather than copy working trees**. Cloning
tracked content per registered project excludes every artifact by construction and is reproducible
from the registry, instead of being an rsync someone maintains by hand. An explicit in-scope policy
is still needed for the two outlier projects; their size is not a build-artifact story and a size
heuristic would be the wrong instrument.


## Sharing is the easy half

Read-only sharing needs none of the machinery that shared *mutable* storage would.

Nagare is single-node by design. `ReadWriteOnce` constrains concurrent mounts to one **node**, not
one pod, and co-mounting a single `local-path` PVC across several pods on the one node is an
established, verified property of this cluster — it is how a Knative revision roll preserves data
and how the backup job reads a live volume. Mounting that same volume read-only into many agent
pods is therefore safe today: concurrent readers over an immutable tree need no locking and cannot
corrupt anything. No `ReadWriteMany`, no network filesystem, no new storage primitive.

This matters because the DSL's access mode is a one-constructor sum (`ReadWriteOnce`), the config
loader rejects any other value outright, and MasterPlan 7 records multi-node RWX as explicit
non-scope. None of that has to be relaxed for this use case — which is precisely why the read
direction is worth separating from the write direction.

Two adjacent behaviors are worth knowing, because they bite anything that tries to share a
*writable* volume here. A Knative Service carrying any volume is pinned to a single replica. A
worker, by contrast, carries both a replica count and volumes with no validation between them, so
several worker pods can co-mount one volume read-write and get a shared filesystem with no
coordination at all. For git working trees that is a corruption path, not a feature.


## Where this breaks today

**Registered paths are absolute and workstation-specific.** The registry stores paths like
`/Users/…/<project>`, and there is no corpus-root indirection in Mori's configuration surface. In a
pod that path does not exist, so discovery succeeds and the final hop — actually opening the file —
fails. Either the corpus root becomes configurable, or the pod's filesystem is contorted to
reproduce one machine's home directory. The former is the real fix and benefits every non-workstation
consumer, not just Nagare.

**There is one data disk and everything shares it.** A single attached disk is formatted and mounted
at the Nagare state root, and the host layout puts `local-path`, Postgres, the Victoria stack, and
backups on it. A corpus PVC would land beside the database. That couples a bulk, reconstructible
cache to the durable tier: filling it takes down everything, a sync burst contends with database IO,
and the backup policy has to carve out an exception for data that is reproducible from git.

**The StorageClass is not selectable.** The cluster's provisioner is configured with a single
storage path, and the renderers hardcode `storageClassName: local-path`; the typed `Volume` has no
StorageClass field. So even with a second disk attached, a corpus volume on it is not expressible in
a typed config — it would be YAML applied outside the model.


## Storage direction

A dedicated corpus disk is the right target: separate blast radius, separate IO, separate lifecycle
(a cache, not state), and separate sizing and cost tier from the data disk. Attaching the disk and
mounting it are mechanical repeats of what the host already does for the data disk. The open choice
is how the cluster exposes it — a second provisioner with its own StorageClass, which keeps the
corpus a first-class typed volume, or a read-only host path, which is simpler but introduces a
bypass of the model that Nagare has so far avoided. Adding a StorageClass field to `Volume` is what
makes the first option expressible.

This is an extension of the storage model that assumed one disk and one class, so it belongs in that
MasterPlan's Decision Log rather than being introduced incidentally.

None of it is blocking. If the materialized corpus lands near the size the `.git` figures suggest, it
fits on the existing disk and the read path can be proven end to end before any disk geometry is
committed.

A managed NFS service was considered and rejected: it is the only way to get true `ReadWriteMany`,
but this use case does not need RWX, and its minimum provisioned capacity is disproportionate to a
single-node cluster.


## Registry state is a database concern, not a filesystem one

Mori's own state — its event store and the projections the registry is read from — lives in
PostgreSQL, through the **keiro** event-sourcing framework. (Some architecture prose still describes
the earlier MessageDB-based store; keiro superseded it, and it is likewise PostgreSQL-backed, so the
conclusion here is unchanged.)

That is the correct primitive for the discovery half of the job and it needs no shared filesystem at
all: many agent pods query one cluster-local database concurrently. It cleanly splits the use case in
two — **metadata over the database, bytes over the read-only mount** — and only the second half
requires anything new from Nagare.


## Open questions

- **Corpus scope.** Which registered projects belong on the cluster, and what governs the two
  outliers whose size is not explained by build output.
- **Sync cadence and consistency.** A sync that lands mid-read gives an agent a torn view — not
  corruption, but inconsistency. Whether that is acceptable, or wants a quiesce window or a
  write-new-then-swap.
- **Exposure mechanism.** Second StorageClass versus read-only host path.
- **Shallow versus blobless clones.** Whether any agent workflow needs history, which decides
  whether `--depth=1` is safe or whether `--filter=blob:none` is the floor.


## Related

- [Improvement requests](../improvement-requests/index.md) — the write direction, out of scope here.
- Theme: [agent platform](themes/agent-platform.md).
