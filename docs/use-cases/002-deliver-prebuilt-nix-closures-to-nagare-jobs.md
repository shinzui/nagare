---
title: "Use Case 002 — Deliver Prebuilt Nix Closures to Nagare Jobs"
type: Use Case
description: "A trusted producer delivers an exact signed Nix closure to an opted-in Nagare Job, which starts from a cache hit without building locally."
generated:
  by: openai-codex/gpt-5.6-sol
  at: "2026-09-16T04:30:46Z"
useCaseId: UC-2
status: planned
origin: mori://shinzui/nagare
themes:
  - agent-platform
jobs:
  - name: deliver-prebuilt-closure
    actor: Kotei workflow or Nagare operator
    situation: a workload closure has been built by a trusted producer and must run in a fresh Nagare Job
    motivation: deliver the exact build output without granting the consumer Pod local build capability
    outcome: the opted-in Job verifies and substitutes the signed closure before running its first command
  - name: reuse-closure-across-jobs
    actor: workload operator
    situation: repeated one-shot Jobs share an expensive Nix dependency closure
    motivation: avoid rebuilding or refetching the same dependencies for every Job
    outcome: a warm-cache Job reaches its first command faster than a cold build while preserving signature verification
features:
  - name: context-scoped-binary-cache
    description: Provide an optional binary-cache service whose storage, metadata, trust identity, retention, and lifecycle belong to one Nagare cloud context.
    status: planned
    owners:
      - mori://shinzui/nagare
    acceptance: Enabling a cloud context provisions and reconciles the cache, while a disabled or local context creates no cache resources.
    jobs:
      - deliver-prebuilt-closure
      - reuse-closure-across-jobs
  - name: guarded-narrow-push
    description: Let a trusted producer push a closure through a private operator path using an expiring cache-scoped token.
    status: planned
    owners:
      - mori://shinzui/nagare
      - mori://shinzui/kotei
    acceptance: The producer pushes to the selected cache, anonymous push fails, and the writer cannot create or configure another cache.
    jobs:
      - deliver-prebuilt-closure
      - reuse-closure-across-jobs
  - name: explicit-job-substitution
    description: Publish a context-generated Nix client configuration that a Job must explicitly select through the typed Job contract.
    status: planned
    owners:
      - mori://shinzui/nagare
      - mori://shinzui/kotei
    acceptance: A fresh opted-in Pod with local building and fallback substituters disabled downloads the path from the context cache; a non-opted-in Pod is unchanged.
    jobs:
      - deliver-prebuilt-closure
      - reuse-closure-across-jobs
  - name: signed-context-local-trust
    description: Generate and preserve one signing identity per context so consumers accept only closures signed by that context's cache.
    status: planned
    owners:
      - mori://shinzui/nagare
    acceptance: A correct live public key accepts the closure, a wrong key rejects it, and restoring the cache database preserves the trusted identity.
    jobs:
      - deliver-prebuilt-closure
  - name: cache-hit-performance-evidence
    description: Measure the delivery benefit without conflating Nix substitution with unrelated deployment phases.
    status: planned
    owners:
      - mori://shinzui/nagare
    acceptance: Evidence records producer build-and-push time separately from fresh-Pod cache-hit time-to-first-command and attributes no speedup to scheduling, OCI pulls, migrations, or manifest rollout.
    jobs:
      - reuse-closure-across-jobs
reviews:
  - kind: model
    reviewer: process:openai-codex
    reviewed_at: "2026-09-16T04:30:46Z"
    document_timestamp: "2026-09-16T04:30:46Z"
    scope: content-and-metadata
    outcome: approved
    provider: openai
    model: gpt-5.6-sol
    effort: unspecified
    context: >-
      Checked the JTBD records, feature ownership, observable acceptance, activation
      boundary, and performance claims against the refreshed ExecPlan 96, Nagare's
      implemented one-shot Job cache mount, and the local use-case profile.
verified:
  by: process:openai-codex
  at: "2026-09-16T04:30:46Z"
---

# Use Case 002: deliver prebuilt Nix closures to Nagare Jobs

A Kotei workflow, CI job, or Nagare operator can build a Nix closure before a workload
enters the cluster. The consumer is often a short-lived Job that should run the exact
output, not spend its startup budget rebuilding dependencies or gain the authority and
resources required to build them. This use case is the controlled handoff between those
two actors.

The delivery mechanism is opt-in at both levels. The operator enables a binary cache for
one cloud context. A producer explicitly pushes selected closures. A consuming Job
explicitly selects the context-generated Nix configuration through its `nixConfigMap`
field. Merely deploying to Nagare does not publish artifacts or route every Pod through
the cache.


## Expected flow

1. A trusted workstation, CI job, or Kotei workflow builds the workload closure.
2. The producer obtains a narrow, expiring token and pushes that closure to the enabled
   context cache.
3. Nagare reports the cache's live URL and public key through a generated ConfigMap in
   the consumer namespace.
4. A one-shot Job opts into that ConfigMap and starts with local building and unrelated
   fallback substituters disabled.
5. Nix downloads and verifies the signed closure, after which the Job runs its first
   workload command.

On a cache hit, the speedup is limited to work Nix no longer performs in the Pod. Pod
scheduling, OCI image pulls, Kubernetes rollout, database migration, and other deployment
phases are unchanged. The first use can be neutral or slower because the producer still
has to build and push. Evidence therefore compares producer build-and-push time with
fresh-Pod cache-hit time-to-first-command instead of claiming that every deployment is
faster.


## Trust and ownership boundary

Nagare owns the provider: context opt-in, cloud storage and credential, managed database,
versioned server image, bootstrap, generated client ConfigMap, backup, retention,
observability, and recovery. The current implementation plan selects Attic for that
provider.

Kotei owns producer and consumer behavior: which closures to build and push, when to push
them, and which Jobs opt in. The consumer trusts a context-specific NAR public key, not a
repository-wide literal. The cache is public-read inside its reachable network boundary
because Nix signatures provide artifact integrity; write authority remains narrow and
expiring.


## Non-goals

This is not a general Nagare deployment accelerator. It does not replace the Cachix
substituter used to develop and release Nagare, an OCI registry, source hosting, durable
application storage, or a future cross-context cache federation design. A cache is
reconstructible transport rather than the source of truth for a workload. PostgreSQL
backup is nevertheless important because it preserves the context's signing identity.


## Observable success

- A fresh opted-in Job with local building disabled retrieves the pre-pushed closure and
  reaches its first workload command.
- Logs identify the context cache as the substituter and do not execute the derivation's
  builder.
- The same Job rejects the closure when configured with the wrong public key.
- Anonymous pull succeeds, anonymous push fails, and a cache-scoped writer cannot manage
  a different cache.
- Restarting the provider preserves the artifact and public key; restoring the database
  preserves the signing identity.
- Measurements separate producer build-and-push time from warm consumer startup and make
  no claim about unrelated deployment phases.


## Related

- [ExecPlan 96](../plans/96-an-in-cluster-nix-binary-cache-attic-as-a-cluster-bootstrap-component.md)
  plans the Nagare-owned Attic provider.
- Theme: [agent platform](themes/agent-platform.md).
- The originating downstream requirement is
  `mori://shinzui/kikan/plans/27-author-nagare-s-platform-prerequisites-forge-credentials-a-one-shot-job-kind-and-a-nix-binary-cache`.
- Consumer-side work in
  `mori://shinzui/kotei/masterplans/10-first-class-shared-nix-cache-infrastructure`
  must use this provider contract rather than deploy a competing cache.
