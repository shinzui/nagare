---
id: 76
slug: typed-broker-model-and-provider-neutral-renderer-contract
title: "Typed Broker model and provider-neutral renderer contract"
kind: exec-plan
created_at: 2026-06-21T15:31:05Z
intention: "intention_01kvncmnzweearjz953y6besqc"
master_plan: "docs/masterplans/15-cluster-messaging-broker-for-nagare.md"
---

# Typed Broker model and provider-neutral renderer contract

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

Full plan before trimming: [76-typed-broker-model-and-provider-neutral-renderer-contract.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/76-typed-broker-model-and-provider-neutral-renderer-contract.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

This plan adds the provider-neutral broker model to `nagare-dsl`. After it lands, a typed
`nagare/Config.hs` can describe a broker and its topics without committing user config to Redpanda
forever. Redpanda is the only implemented provider in v1, but the type has an explicit `Tansu`
provider placeholder and keeps provider-specific options isolated.

The observable behavior is offline and deterministic: `cabal test nagare-dsl-test` passes with tests
that construct valid brokers, reject invalid names and unpinned versions, round-trip broker JSON
through `emitBroker`/`loadBroker`, and render provider-neutral Kubernetes manifests or manifest plans
with stable labels and names. Later plans consume these types for lifecycle commands, workload env
injection, observability, and docs.

## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1: Add `BrokerName`, `TopicName`, `BrokerProvider`, `BrokerTopic`, and `Broker` types with smart constructors. Completed 2026-06-21 in `Nagare.Dsl.Broker`; records use strict unprefixed fields and derive `Generic` per the house record-pattern convention.
- [x] M2: Add `emitBroker`, `encodeBroker`, `loadBroker`, and load-error tests. Completed 2026-06-21; broker JSON uses `kind: Broker`, round-trips through `decodeBroker`, rejects wrong-kind deployment JSON, and has a config-as-program fixture at `cli/nagare-dsl/test/fixtures/broker/redpanda/nagare/Config.hs`.
- [x] M3: Add provider-neutral renderer helpers, Redpanda v1 manifest rendering, and golden tests. Completed 2026-06-21; goldens pin PVC, Service, default StatefulSet, and larger sizing StatefulSet outputs under `cli/nagare-dsl/test/golden/broker-redpanda*.yaml`.
- [x] M4: Export the new modules and integrate them into `Nagare.Dsl.Presets` or docs-friendly helper APIs. Completed 2026-06-21; `Nagare.Dsl.Broker` and `Nagare.Dsl.Broker.Render` are exposed from `nagare-dsl.cabal`, while preset helpers were deliberately deferred because existing top-level managed resources use explicit constructors rather than preset overlays.

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-06-21: The repository's `nix fmt cli/nagare-dsl` command is not available on this platform because the flake does not define `formatter.aarch64-darwin`. The touched Haskell files were formatted directly with `fourmolu --mode inplace ...` using `cli/fourmolu.yaml`; `cabal-gild` was checked but would print a whole-file Cabal reformat rather than a scoped edit.

- 2026-06-21: Existing config-as-program fixture tests initially failed under direct `cabal test` because `runghc` did not expose the local `nagare-dsl` package from the Cabal test environment. Passing `--ghc-arg=-package --ghc-arg=nagare-dsl` to `runghc` fixed the existing deployment/static/server/worker/application fixtures and the new broker fixture.

```text
All 339 tests passed (5.53s)
```

## Decision Log

Record every decision made while working on the plan.

- Decision: Put broker types in dedicated `Nagare.Dsl.Broker` modules.
  Rationale: Brokers are top-level resources like databases, not fields on a single deployment. A
  dedicated module keeps provider-specific facts out of `Nagare.Dsl.Types`.
  Date: 2026-06-21

- Decision: Reserve `Tansu` in the provider enum before implementing it.
  Rationale: The user explicitly wants to switch to Tansu once mature. A reserved constructor forces
  every later interface to think about provider neutrality while allowing the renderer to reject Tansu
  provisioning until a future plan implements it.
  Date: 2026-06-21

- Decision: Use unprefixed strict record fields and `Generic` derivations for the new broker records.
  Rationale: The repository follows the `haskell-jitsurei` record-pattern convention at
  `/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/core/record-patterns.md`: do not prefix record
  fields, always mark fields strict, use explicit deriving strategies, and use generic-lens `#field`
  access where fields are read. The broker additions were adjusted to follow that convention.
  Date: 2026-06-21

- Decision: Keep broker preset helpers out of EP-76.
  Rationale: Managed databases, the closest existing top-level resource, use explicit constructors
  rather than `Nagare.Dsl.Presets` overlays. Exporting `Nagare.Dsl.Broker` and
  `Nagare.Dsl.Broker.Render` gives docs and later CLI plans the stable helper API without inventing a
  separate preset style for brokers.
  Date: 2026-06-21

- Decision: Make `runConfig` pass the local `nagare-dsl` package explicitly to `runghc`.
  Rationale: The previous comment assumed `.ghc.environment.*` made `nagare-dsl` visible, but the
  direct `cabal test nagare-dsl-test` validation showed `runghc` treating the package as hidden. Using
  `--ghc-arg=-package --ghc-arg=nagare-dsl` is explicit and keeps every existing config fixture green.
  Date: 2026-06-21

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

EP-76 completed on 2026-06-21. The DSL now has a provider-neutral broker model, Redpanda and reserved
Tansu provider tokens, validated broker/topic/version/sizing constructors, JSON emit/load helpers,
config-as-program loading, and Redpanda v1 Kubernetes rendering with golden coverage. The renderer
uses provider-neutral names and Nagare labels while keeping Redpanda image, ports, health endpoints,
and startup flags inside the Redpanda branch. The full `nagare-dsl` test suite passes:

```text
All 339 tests passed (5.53s)
```

