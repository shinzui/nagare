---
id: 80
slug: messaging-broker-docs-examples-and-tansu-migration-readiness
title: "Messaging broker docs examples and Tansu migration readiness"
kind: exec-plan
created_at: 2026-06-21T15:31:24Z
intention: "intention_01kvncmnzweearjz953y6besqc"
master_plan: "docs/masterplans/15-cluster-messaging-broker-for-nagare.md"
---

# Messaging broker docs examples and Tansu migration readiness

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

Full plan before trimming: [80-messaging-broker-docs-examples-and-tansu-migration-readiness.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/80-messaging-broker-docs-examples-and-tansu-migration-readiness.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

## Purpose / Big Picture

This plan finishes the messaging broker initiative by making it usable and maintainable. After it
lands, a developer can read the user docs, provision a Redpanda-backed broker, deploy a worker or app
that uses a topic, produce a test message, watch the worker consume it, and inspect broker health in
Grafana. The docs also explain how the v1 Redpanda provider is intentionally shaped so a future Tansu
provider can replace it without changing application config.

## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1: Add user documentation for broker provisioning, topic binding, and operational commands.
- [x] M2: Add a working broker producer/consumer example under `cluster/examples/`.
- [x] M3: Add observability and troubleshooting docs.
- [x] M4: Add Tansu migration readiness notes and provider contract checklist.
- [x] M5: Run docs/example validation and update reference indexes.

Update 2026-06-21: EP-80 is complete. `docs/user/messaging-brokers.md` now explains broker
provisioning, topic bindings, generated env, sizing, observability, cleanup, and Tansu migration
readiness. It is linked from `docs/user/README.md` and `docs/user/reference.md`.
`docs/user/troubleshooting.md` covers broker readiness, missing metrics, missing topics, advertised
listener mistakes, and storage pressure. `cluster/examples/broker-worker/` now contains a broker
config, a worker config, and a README. The worker uses the Redpanda image's `rpk` as a minimal
consumer, so the example has no custom build step.

Live validation created broker `events` from `cluster/examples/broker-worker/nagare/Broker.hs`,
deployed worker `broker-worker`, produced `hello from nagare` to topic `jobs`, and saw the worker log
the message. Cleanup deleted the worker Deployment, broker StatefulSet/Service, and retained PVC;
`broker list --namespace personal` returned `(no managed brokers)`.

Final validation 2026-06-21:

- `cabal test nagare-dsl-test` from `cli/nagare-dsl` passed: 343 tests.
- `cabal test nagarectl-test` from `cli/nagarectl` passed: 315 tests.
- `cabal run exe:nagarectl -- broker create redpanda events --config ../../cluster/examples/broker-worker/nagare/Broker.hs --dry-run` passed.
- Live `broker create`, `worker deploy --dry-run`, `worker deploy`, produce, log verification, and cleanup passed.
- `nix fmt ...` could not run because the flake does not provide `formatter.aarch64-darwin`.

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-06-21: A broker-bound worker dry-run is not a pure offline render. It resolves live broker and
  topic state before rendering generated env, so the docs now say to create the broker first and then
  use worker `--dry-run`.

- 2026-06-21: `webWorker` validates an untagged image repository and pairs it with `PrebuiltImage
  latest`. The broker-worker example needs Redpanda's pinned tag, so it constructs `Worker` directly
  with `image = docker.redpanda.com/redpandadata/redpanda` and `build = PrebuiltImage v26.1.8`.

## Decision Log

Record every decision made while working on the plan.

- Decision: Document Tansu as a future provider, not an alternative v1 install path.
  Rationale: The user wants to switch to Tansu once it matures. Presenting it as a current supported
  provider would overstate the implementation.
  Date: 2026-06-21

- Decision: Use the Redpanda image's bundled `rpk` CLI for the broker-worker example.
  Rationale: It gives a real Kafka-compatible consumer/producer example without adding a custom image,
  package manager, or client-library dependency to the repo.
  Date: 2026-06-21

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

EP-80 is complete. The messaging broker feature now has user-facing docs, reference links, a working
producer/consumer example, troubleshooting coverage, and a concrete Tansu compatibility checklist. The
example proves the full workflow: provision broker/topic, deploy a worker bound by logical names,
receive generated env, produce a message, observe consumption, and clean up retained storage.

