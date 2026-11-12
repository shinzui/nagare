---
title: "A workload inherits its app's managed store unless it opts out"
status: accepted
date: 2026-11-12
authors: [shinzui]
related:
  - docs/plans/261-scope-an-app-s-managed-env-and-secrets-to-the-workloads-that-reference-them.md
  - docs/improvement-requests/scope-app-secrets-to-the-workloads-that-reference-them.md
  - docs/adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md
  - docs/adr/0036-application-pods-hold-no-kubernetes-api-token-unless-they-name-an-account.md
---

# ADR 38 — A workload inherits its app's managed store unless it opts out

## Status

Accepted and implemented by [EP-261](../plans/261-scope-an-app-s-managed-env-and-secrets-to-the-workloads-that-reference-them.md)
for IR-44.

## Context

An app's managed store is one ConfigMap and one Secret per scope, written by `nagarectl env` and `nagarectl secret`.
Every web service and every task naming an app received the whole Runtime store through `envFrom`, so a reference to one
key narrowed nothing: a pre-deploy migration hook held the serving logins and the serving Pods held the migration
credential. Kotei's migration wrapper refuses to start in that state.

The store a workload inherited was also not one rule. A worker named a store after itself, and so did an Application's
web service when its name differed from the Application's. The store commands accept only the configuration's own name,
so no command could write either store for an Application.

## Decision

A web service, a worker and a task carry `managedEnv`. `InheritManagedEnv`, the default, renders the `envFrom` of the
Runtime store. `NoManagedEnv` renders none, and the workload receives only its inline variables, the Secret keys it
references one by one, its bindings and Nagare's own `NAGARE_*` variables. The serialized key is written only for the
opt-out, so a configuration that inherits keeps its digest.

Inside an Application every workload inherits the Application's store. A web service or worker deployed on its own
inherits the store named after itself, and the store commands accept a standalone worker's configuration.

An opted-out workload reaches a key of the app's runtime Secret by an ordinary Secret reference. The reviewed deploy
already requires each referenced Secret to be an accepted resource, so the Secret is passed with
`--env-secret-resource` and appears in the review as a dependency of the workloads that read it.

Several named Secrets per app were rejected for now. They would add a second channel identity to the store commands,
to channel scopes, to retirement and to delegation, for the same result in the case that asked for this.

## Consequences

A `Deployment`, `Worker` or `Task` record literal must set the new field. An Application's worker, and a web service
named differently from its Application, change the store their `envFrom` names on their next deploy and then receive
every key of the Application's store; the saved review shows the one changed name, and such a workload can opt out.

Values written with `env set` cannot reach an opted-out workload, because the configuration has no per-key ConfigMap
reference; they go in the workload's inline `env` or in the Secret. A referenced key missing from the
Secret stops the Pod at start, since plan time does not read the Secret's keys. An Application's own `env` map still
reaches every workload, and server sites and one-shot jobs keep their `envFrom` with no opt-out.
