---
type: Improvement Request
title: Host multi-role applications with a native ARM64 SDK and explicit workload contracts
description: Provide a qualified ARM64 Linux configuration SDK and reviewed readiness, independent web probes, shutdown and token controls so Kotei can run as an ordinary Nagare application without patching inventory-owned workloads.
timestamp: "2026-11-09T15:52:00Z"
generated:
  by: process:codex
  at: "2026-11-09T15:52:00Z"
requestId: IR-42
status: proposed
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
