---
type: Improvement Request
title: Host multi-role applications with a native ARM64 SDK and explicit workload contracts
description: Provide a qualified ARM64 Linux configuration SDK and reviewed readiness, independent web probes, shutdown and token controls so Kotei can run as an ordinary Nagare application without patching inventory-owned workloads.
timestamp: "2026-11-10T05:12:50Z"
generated:
  by: process:codex
  at: "2026-11-09T15:52:00Z"
requestId: IR-42
status: accepted
origin: mori://shinzui/kotei/plans/135-package-and-run-kotei-as-a-nagare-application
reviews:
  - kind: model
    reviewer: process:codex
    reviewed_at: "2026-11-09T15:52:00Z"
    document_timestamp: "2026-11-09T15:52:00Z"
    scope: content-and-metadata
    outcome: commented
    provider: openai
    model: gpt-6.1-sol
    effort: unspecified
    context: "Author check against immutable release exports and Worker sources for 0.10.0 and 0.16.2, existing database privilege requests and Kotei hosting acceptance. No independent review or upstream runtime qualification is claimed."
acceptanceCriteria:
  - id: AC-1
    statement: A public immutable Nagare release supplies a supported native aarch64-linux configuration compiler and SDK suitable for an isolated application runner, independently of whether the entire production platform supports ARM64 hosts.
    verification: Build and execute the packaged CLI on native ARM64 Linux without a source checkout or user Cabal database; app check loads a typed Application containing web, worker and migration task roles, and retained evidence records source revision, platform, SDK and executable identity.
  - id: AC-2
    statement: A typed Worker can declare an independent readiness probe, and reviewed rollout health waits for that probe rather than treating a running process or successful liveness as readiness.
    verification: Through the real loader, renderer and reviewed apply path, run a compiled worker whose readiness file is absent during initialization, present after runtime acquisition, and removed during shutdown or sustained database failure; assert native render, observed Pod and inventory readiness agree.
  - id: AC-3
    statement: A web workload can express distinct startup, readiness and liveness behavior through supported platform probe semantics, including database-dependent readiness and process-only liveness.
    verification: Render and deploy a compiled HTTP service with /health/ready and /health/live; a database outage withdraws readiness while process liveness succeeds, and initialization is bounded by startup behavior. Validate the actual Knative admission and serving-probe behavior, not only generated YAML.
  - id: AC-4
    statement: Workloads have a supported reviewed way to obtain a 60-second termination allowance and tokenless baseline Pods, with any required feature-specific service account and token access explicitly scoped.
    verification: Check both retained native resources and live Pods for the declared lifecycle and token settings; observe readiness withdrawal and graceful shutdown within the allowance, and prove ordinary web/worker Pods receive no Kubernetes API token or runner credential.
  - id: AC-5
    statement: The supported application contract documents configuration, role-specific file-secret delivery and shared retained-content ownership, resolving the current per-workload PVC limitation through an upstream facility or an explicit tested consumer-owned foundation contract.
    verification: Demonstrate immutable configuration and a read-only catalog, private regular credential files suitable for the Kotei runner, and identical worker-published bytes consumed by the runner and server when enabled; preserve one reviewed owner per resource and reject cross-role credential delivery.
  - id: AC-6
    statement: New workload controls survive Application loading, saved review serialization, accepted native rendering, retries and live observation without an untracked patch to a Nagare-owned workload.
    verification: Exercise a representative compiled worker and full migration/provisioning hook through a real saved review; failing SQL or provisioning prevents workload promotion, unchanged retries retain successful hook proof, and operator evidence retains the exact native render and observed image identity.
  - id: AC-7
    statement: Release documentation names the supported native SDK path, new typed contracts or foundation ownership, compatibility consequences and consumer upgrade steps.
    verification: Publish immutable upstream source/release identity and any changed API schemas so Kotei can update its CLI pin, runner build manifest and vendored contract bytes together and rerun its native hosting acceptance.
---

# Host multi-role applications with native ARM64 and explicit workload contracts

Requested while implementing
`mori://shinzui/kotei/plans/135-package-and-run-kotei-as-a-nagare-application`,
the hosting child of
`mori://shinzui/kotei/masterplans/26-let-any-engineer-onboard-a-repository-and-deploy-on-push-through-a-kotei-hosted-on-nagare`.
The operator deploys Kotei using Nagare; this request does not implement Kotei
self-upgrade or the separate delegated-deployer initiative.

## Accepted implementation scope (2026-11-09)

[MasterPlan 34](../masterplans/34-extend-application-workloads-with-independent-health-checks-explicit-pod-policy-and-a-native-arm64-sdk.md) coordinates ExecPlans 253, 254 and 256. Nagare already has the Application aggregate, web/worker/task composition, shared image and environment configuration, rollout hooks, and journaled inventory execution. This request extends those existing capabilities with native ARM64 Linux tooling, independent probes and explicit workload shutdown/token policy. All deployed changes use the existing saved reviews, ownership checks, operation journal and recovery path.

AC-5 receives a bounded audit of existing role-specific delivery and retained-content mechanisms. Any unsupported requirement remains open with a scoped follow-up; the MasterPlan does not presume a new secret or shared-storage subsystem. Acceptance here means the narrowed implementation is planned, not that any criterion has passed.

## Consumer outcome

Kotei needs one image containing compiled server, worker, migration/operations
commands and its separately credentialed deployment runner. Its baseline runs
only server, worker and a pre-deployment provisioning task. All use one durable
PostgreSQL 18 database with separate runtime and maintenance logins. The runner
binary remains in the common image but its workload is omitted when disabled.

The consumer's native acceptance environment is Apple silicon running ARM64
Linux. A Darwin operator CLI cannot supply the Linux SDK inside that runner,
and translated x86 execution cannot establish native ARM64 qualification. A
source checkout on disk that happens to build does not constitute a supported,
released SDK contract.

## Verified gaps

Kotei pins public `v0.10.0`, peeled commit
`16f0d7be4ab03a44716c81b03c6b433103e32651`. At that immutable source:

- `release.json` and `flake.nix` export only `x86_64-linux` and
  `aarch64-darwin`, so the ARM64 Linux runner package is absent.
- `cli/nagare-dsl/src/Nagare/Dsl/Worker/Render.hs` explicitly omits
  `readinessProbe`; its Worker models liveness/startup but no readiness.
- `cli/nagare-dsl/src/Nagare/Dsl/Render.hs` reuses one `HealthCheck` for
  enabled web probe kinds. Kotei already distinguishes `/health/ready` from
  `/health/live`; database availability must not redefine process liveness.
- The worker Pod template exposes neither termination grace nor service-account
  token controls. A non-root image user does not supply those Pod policies.
- PVC names incorporate workload identity, so declaring the same logical volume
  in multiple roles does not share retained bytes. Secret references become
  environment variables; the consumer also needs files for keys and tokens.

Public tags were rechecked on 2026-11-09. The latest observed release was
`v0.16.2`, peeled commit `7224ff43b320204386c33e5ec1654fcca3ef3d9c`.
Its immutable `release.json` still excludes ARM64 Linux and its Worker type still
lacks readiness/grace/token controls. This request is not based on assuming the
registered checkout is the latest release.

Reproduce the release-export check without a cluster:

```bash
git ls-remote --tags https://github.com/shinzui/nagare.git 'refs/tags/v0.16.2*'
git show 16f0d7be4ab03a44716c81b03c6b433103e32651:release.json
git show 16f0d7be4ab03a44716c81b03c6b433103e32651:cli/nagare-dsl/src/Nagare/Dsl/Worker/Render.hs
```

Kotei now makes its common ARM64 image fail explicitly rather than silently
omitting the runner. Its service-only development image and standalone
provisioning wrapper can advance independently. The consumer evidence is
`mori://shinzui/kotei`, project-relative `docs/reviews/kotei-nagare-hosting.md`
(artifact-level review URI pending). The interface cost is recorded in
`mori://shinzui/kotei/okf/friction-log/concepts/FRIC-62`.

## Requested boundary

Nagare owns its typed loader, native workload rendering, reviewed resource
ownership and rollout readiness. Add supported capabilities there, or document
and qualify narrowly owned foundation contracts where that is the intended
platform interface. A manual patch to an inventory-owned Deployment and a
liveness-only worker do not satisfy the consumer's contract.

Configuration and private-file materialization may remain consumer-owned if
Nagare provides a stable role-specific delivery channel. Kotei can materialize
declared environment secrets into private directories before exec. Its runner
requires regular kubeconfig files, a dedicated home containing the named context
and byte equality with the explicitly selected credential. Shared content can
likewise use an owned supported storage reference or a qualified consumer API;
this request does not prescribe a new distributed filesystem.

The database baseline is externally supplied PostgreSQL 18 with explicit
bootstrap authority. Do not grant `CREATEROLE`, superuser or cross-app privileges
to shared app-database runtime users to satisfy it. Existing database privilege
requests keep their boundaries. Kotei will separately qualify migration,
queue provisioning, privilege application/verification and both schema gates.

No implementation is claimed here. Kotei waits for the released upstream
contract before accepting dependent hosting milestones; its unblocked packaging
and private database tests continue meanwhile.

## AC-5 delivery audit (2026-11-09)

Source audit for [ExecPlan 256](../plans/256-qualify-application-workload-controls-through-the-inventory-journal-and-recovery.md)
M1 at commit `faed5e342de52da70622bc9162524b03c0f091be`; nothing was run on a
cluster. EP-254's worker readiness, web probe, worker shutdown and service-account
fields are not delivery mechanisms and are not counted. `DSL/` is
`cli/nagare-dsl/src/Nagare/Dsl/` and `INV/` is
`cli/nagarectl/src/Nagare/Inventory/`.

**AC-5 remains open.**

| Sub-requirement | Disposition | Basis |
| --- | --- | --- |
| Documented configuration, immutable config and read-only catalog | Partly met | Non-secret env reaches roles through Application and workload `env` (`cli/nagarectl/src/Nagare/App/Deploy.hs:221`), documented in `docs/user/env-and-secrets.md`. A catalog can only ship inside the image; read-only mounts exist only for PVCs (`DSL/Render.hs:158-167`). The image route is neither documented as a contract nor demonstrated. |
| Role-specific credential channel | Partly met | A Secret reference in a workload's `env` reaches only that container, as a variable whose Secret key equals its name (`DSL/Render.hs:383-394`), with a reviewed dependency (`INV/Application/Worker.hs:339-353`, `INV/Application/Tasks.hs:303-317`). Build-only references are stripped (`INV/Application/Environment.hs:140-166`). The public review holds names only; channel values stay in private members (`INV/Environment.hs:128-130`, `cli/nagarectl/test/InventoryApplicationSpec.hs:603`). Journal `detail` is fixed text or an adapter reason (`INV/Execute/Driver.hs:539,554`), and no test asserts Secret absence there. An Application has one channel Secret, because `secret sync` is named by the config identity (`cli/nagarectl/app/Nagare/Cli/Application/Config.hs:53-84`). |
| Private regular credential files | Open: AC5-R1 | Application roles have no Secret or ConfigMap volume, emptyDir or init container. Only PVC volumes render (`DSL/Render.hs:171-180`, `DSL/Worker/Render.hs:117-121`), hooks have none (`DSL/Task/Render.hs:104-108`), and `emptyDir` exists only for one-shot Jobs (`DSL/Job/Render.hs:241`). The boundary above allows a consumer materializer over the env channel. It would write to the container's writable layer, must be the image entrypoint on the web role because a `Deployment` has no `command` (`DSL/Types.hs:712-767`), and is unqualified against the runner's regular-file check (`mori://shinzui/kotei`, project-relative `kotei-workers/src/Kotei/Deployment/Runner.hs:130`, artifact-level URI pending). |
| Reject cross-role credential delivery | Open: AC5-R3 | Nothing refuses it. Every role resolves against one binding map (`INV/Application/Compile.hs:397,462,544,553`), and an Application-level reference reaches every role (`INV/Application/Worker.hs:343`, `INV/Application/Tasks.hs:307`). A web Service named like the Application and any image-inheriting hook, which must set `app`, receive the whole channel through `envFrom` (`DSL/Render.hs:345,376`, `DSL/Task/Render.hs:156-159`, `DSL/Task.hs:280`). |
| Identical worker-published bytes for runner and server | Open: AC5-R2 | Claims are per workload, `nagare-vol-<workload>-<volume>` (`DSL/Render.hs:105-110`, `INV/Application/Ownership.hs:66-90`), `ReadWriteOnce` on `local-path` only (`DSL/Types.hs:684`, `DSL/Render.hs:150-151`), and tasks have no volumes. No DSL or Application type declares object storage. An Application-declared database is the only single-owner retained store several roles can bind (`DSL/Application.hs:184-201`, `INV/Application/Compile.hs:412,431`), under one shared credential. It is not a file root and is not qualified for content handoff. Shared-server app databases are refused in an Application (`INV/Application/Compile.hs:147-157`). |
| One reviewed owner per resource | Met | Members claiming the same provider address are refused (`INV/Application/Compile.hs:666-668`), which also rules out duplicate PVC names. This covers existing resource types only. |

Residual requests, each separate from EP-256 and MasterPlan 34:

- **AC5-R1 (private files):** Deliver private regular files to one named Application role from that role's credentials, through an upstream facility or a documented and tested consumer-owned materializer. Proof is a live Pod in which Kotei's runner accepts its kubeconfig as a regular, non-symlink file byte-equal to the selected credential, with no credential bytes in the public review or journal.
- **AC5-R2 (retained content):** Give one Application's writer and reader roles identical retained bytes through one reviewed owner, using an upstream facility or a documented and tested consumer-owned contract that states backup and restore ownership. Per-workload PVCs, duplicate PVC names and untracked patches do not satisfy it.
- **AC5-R3 (role scoping):** Give each Application role a supported Secret identity, and make delivery of a credential to any other role a review-time refusal, covering Application-level references, managed-channel `envFrom` and image-inheriting hooks.
