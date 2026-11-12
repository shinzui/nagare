---
type: Improvement Request
title: Scope an app's secrets to the workloads that reference them
description: Let a web service, worker or task, including an Application's pre-deploy hook, receive only the managed env and Secret keys it references instead of the app's whole Runtime store through envFrom, so an app can give each role its own credentials and keep a migration credential away from its serving workloads.
timestamp: "2026-11-11T19:20:00Z"
generated:
  by: process:claude-code
  at: "2026-11-11T19:20:00Z"
requestId: IR-44
status: accepted
origin: mori://shinzui/kotei/plans/135-package-and-run-kotei-as-a-nagare-application
dependencies:
  - ref: mori://shinzui/nagare/okf/improvement-requests/concepts/IR-43
    kind: soft
    reason: IR-43 AC-5 gives a pre-deploy hook the database owner credential without adding it to the long-running workloads. This request removes the other path by which one role's credentials reach another, the app-wide envFrom of the managed store, so IR-43's serving logins can live in app Secrets without reaching the hook.
acceptanceCriteria:
  - id: AC-1
    statement: A web service, a worker and a task (including an Application's pre-deploy hook) can each declare that it does not inherit the app's Runtime-scoped managed ConfigMap and Secret. Such a workload renders with no envFrom of the managed store and receives only its inline env, its explicit EnvSecretRef keys and its database or broker bindings.
    verification: Render and apply on a local context an Application whose web service, worker and pre-deploy hook all opt out, with a runtime Secret written by `nagarectl secret sync` holding four keys of which each workload references a different subset. Assert from each live Pod spec that no container has an envFrom of nagare-env-APP-runtime or nagare-secret-APP-runtime, and that each container's env names exactly its declared keys.
  - id: AC-2
    statement: An explicit EnvSecretRef to a key of the app's managed runtime Secret still works for a workload that opted out, and the reviewed deploy keeps binding that Secret through --env-secret-resource as today.
    verification: In AC-1's Application, plan with the one runtime Secret resource, apply, and assert each workload reads its referenced keys and the review records the single Secret dependency.
  - id: AC-3
    statement: The default is unchanged. A workload that does not opt out keeps today's envFrom, so existing apps and their managed env behave as before.
    verification: Redeploy an existing example app with no opt-out and assert its rendered Pod specs and the plan are unchanged.
  - id: AC-4
    statement: The store a workload inherits by default is documented and consistent. Today the web service and an app's tasks inherit nagare-secret-APP-runtime, while a worker's envFrom names a store after the worker itself that `nagarectl secret set` cannot write for an Application, which refuses any APP other than the config's name. Either a worker inherits the app's store or the CLI can write the worker's, and the guide states which.
    verification: Review docs/user/env-and-secrets.md and docs/user/workers.md for the inherited store of each workload kind and the opt-out; write a key for an Application's worker with the documented command and assert the worker receives it.
  - id: AC-5
    statement: Kotei's hosted application is the acceptance case. Its migration hook, server and worker opt out and receive only their own keys, so its migration wrapper, which refuses any ambient KOTEI_DATABASE_URL, completes before promotion.
    verification: Apply mori://shinzui/kotei's nagare/Config.hs (with the opt-out) through Kotei's scripts/kotei-nagare-release.sh on a local context and assert the hook converges and the server and worker become ready, with the maintenance credential absent from both serving Pod specs.
reviews:
  - kind: model
    reviewer: process:claude-code
    reviewed_at: "2026-11-11T19:20:00Z"
    document_timestamp: "2026-11-11T19:20:00Z"
    scope: content-and-metadata
    outcome: commented
    provider: anthropic
    model: claude-opus-5-5
    effort: unspecified
    context: >-
      Author review against Nagare 3bb6c406 (cli/nagare-dsl Render.hs envFromField, Worker/Render.hs
      and Task.hs; nagarectl secret set|sync), the live apply described below on a task-owned local
      context, and Kotei's nagare/Config.hs and scripts/kotei-release-migrate.sh. No independent
      verification attestation is claimed.
---

# Scope an app's secrets to the workloads that reference them

**Authored by:** a `claude-code` session in `mori://shinzui/kotei`, hosting Kotei on a local
Nagare context for `mori://shinzui/kotei/plans/135-package-and-run-kotei-as-a-nagare-application`.
**Addressed to:** `shinzui/nagare` agents.
**Created:** 2026-11-11.


## Why

An app's roles need different credentials. Kotei has three:

| Role | Needs |
| --- | --- |
| web service | the runtime database URL, the API token and the forge webhook secret |
| worker | the runtime database URL |
| pre-deploy migration hook | only the maintenance (owner) database URL |

Kotei keeps these apart on purpose. Serving roles never hold the credential that owns the
schema, and its migration wrapper refuses to start when an ordinary runtime URL is in its
environment, so a misrouted credential fails before any SQL.

Nagare's managed store cannot express this today:

- **One Secret per app.** `nagarectl secret set|sync APP` writes `nagare-secret-APP-runtime`
  and refuses an APP other than the config's name, so there is no second Secret to give one
  role. An EnvSecretRef can name the key a role needs.
- **Every workload gets the whole store anyway.** `envFromField` in
  `cli/nagare-dsl/src/Nagare/Dsl/Render.hs` adds an always-present `envFrom` of the app's
  Runtime ConfigMap and Secret to the web service. A task with `app = Just name` gets the
  same (`cli/nagare-dsl/src/Nagare/Dsl/Task.hs`). A worker gets one named after the worker
  (`cli/nagare-dsl/src/Nagare/Dsl/Worker/Render.hs`), a store the CLI cannot write for an
  Application. Per-key references therefore narrow nothing.

Observed on 2026-11-11 on a task-owned local context (Nagare `3bb6c406`, native ARM64). The
operator wrote Kotei's four keys with a reviewed `secret sync kotei`, and Kotei's reviewed
application referenced only each role's keys. The hook Pod's spec carried `envFrom` of both
`nagare-env-kotei-runtime` and `nagare-secret-kotei-runtime` beside its one reference. Kotei's
wrapper saw the runtime URL and exited ("unset ambient database and Secret-directory
overrides"). The hook Job failed and, correctly, nothing was promoted. Had the hook started,
the web service would have held the maintenance credential.

IR-43 AC-5 moves the owner credential to a hook binding that never reaches the long-running
workloads. That fixes the maintenance URL. The serving logins IR-43 expects in "ordinary app
Secrets" would still reach the hook through `envFrom`, and the worker would still hold the
web service's token and webhook secret.


## What was delivered

ExecPlan 261 ([docs/plans/261-scope-an-app-s-managed-env-and-secrets-to-the-workloads-that-reference-them.md](../plans/261-scope-an-app-s-managed-env-and-secrets-to-the-workloads-that-reference-them.md),
[ADR 38](../adr/0038-a-workload-inherits-its-app-s-managed-store-unless-it-opts-out.md)) delivers
AC-1 to AC-4 at Nagare `a314e7a9`, not yet in a release. A web service, worker or task sets
`managedEnv = NoManagedEnv`. They were confirmed on 2026-11-12 on a local context by
`just local-secret-scope-smoke`. AC-5 is still open: it needs Kotei's release image, which this
repository cannot build.

- **AC-1.** "Exactly its declared keys" is read as the declared names plus Nagare's own
  `NAGARE_*` variables on a task, and Knative's `PORT` and `K_*` on a web container.
- **AC-3.** A web service and a pre-deploy hook that do not opt out, deployed by v0.20.0, replan
  with no operations. An Application's worker is the exception, under AC-4.
- **AC-4.** Inside an Application every workload now inherits the Application's store. That
  changes the `envFrom` name of an Application's worker on its next deploy, and of a web service
  whose name differs from its Application's (both used to name a store no command could write).
  Such a workload then receives every key of the Application's store unless it opts out. A
  worker deployed on its own keeps its own store, and `nagarectl env|secret` now accept its
  configuration.
- **AC-5.** Kotei's `nagare/Config.hs` with the opt-out loads and renders at `a314e7a9`: only
  `migrate` names `KOTEI_RELEASE_MAINTENANCE_DATABASE_URL`, and all three roles carry
  `managedEnv: None`. The run through `scripts/kotei-nagare-release.sh` with Kotei's image belongs
  to `mori://shinzui/kotei/plans/135-package-and-run-kotei-as-a-nagare-application`, starting from
  this diff against Kotei `db21e4bb`. The revision check names `a314e7a9` until a tag carries it.
  Kotei's hook can also take the maintenance URL from an `appDatabases` binding (IR-43 AC-5)
  instead of the Secret.

```diff
--- a/nagare/Config.hs
+++ b/nagare/Config.hs
@@ -46,11 +46,9 @@
   workerCommand <- Worker.mkCommand ["kotei-worker", "--config", "/etc/kotei/application.dhall"]
   hookSchedule <- Task.mkSchedule "0 0 * * *"
   -- Nagare's Secret store holds one runtime Secret per app,
-  -- nagare-secret-kotei-runtime, and Nagare also mounts it whole into every
-  -- workload with envFrom. The per-key references below therefore do not keep
-  -- the maintenance URL from the serving roles: plan 135 records this as an
-  -- open Nagare contract gap, and kotei-release-migrate refuses to run while
-  -- the runtime URL is present.
+  -- nagare-secret-kotei-runtime. Every role sets NoManagedEnv, so none
+  -- inherits that store whole: each receives only the keys referenced below,
+  -- and the maintenance URL reaches the migration hook alone.
   serverEnv <-
     environment
       ["KOTEI_DATABASE_URL", "KOTEI_GITHUB_WEBHOOK_SECRET", "KOTEI_API_TOKEN"]
@@ -74,6 +72,7 @@
             Dsl.scale = Just scale,
             Dsl.probes = Just (Dsl.WebProbes readiness (Just liveness) (Just startup)),
             Dsl.serviceAccount = Nothing,
+            Dsl.managedEnv = Dsl.NoManagedEnv,
             Dsl.volumes = [],
             Dsl.databases = [],
             Dsl.appDatabases = [],
@@ -102,7 +101,8 @@
             Worker.liveness = Nothing,
             Worker.readiness = Just workerReady,
             Worker.shutdown = Just shutdown,
-            Worker.serviceAccount = Nothing
+            Worker.serviceAccount = Nothing,
+            Worker.managedEnv = Dsl.NoManagedEnv
           }
   -- Aggregate tasks are pre-deploy hooks. The web service's scheduled task
   -- list stays empty. The release review must bind migrate to the database ID.
@@ -126,7 +126,9 @@
           Task.successfulJobsHistoryLimit = 1,
           Task.failedJobsHistoryLimit = 1,
           Task.startingDeadlineSeconds = Nothing,
-          Task.serviceAccount = Nothing
+          Task.serviceAccount = Nothing,
+          Task.managedEnv = Dsl.NoManagedEnv,
+          Task.appDatabases = []
         }
   App.mkApplication
     App.Application
--- a/scripts/kotei-nagare-release.sh
+++ b/scripts/kotei-nagare-release.sh
@@ -61,11 +61,10 @@
 [[ $(digest "$KUBECONFIG") == "$(cat "$evidence/kubeconfig.sha256")" ]] || fail "kubeconfig changed"
 [[ $(digest "$evidence/Config.hs") == "$(cat "$evidence/config.sha256")" ]] || fail "application configuration changed"
 "$nagare" version --json > "$evidence/nagare-version.json"
-# Qualified CLIs: the v0.18.0 tag, and the untagged commit at which Nagare
-# completed MasterPlan 33's EP-248 (rendered and delegated deployment), which
-# plan 148's local gate needs. Replace both with the first tag carrying it.
-jq -e '.version == "0.18.0" and (.revision == "a42f8c72c2c98e25e924236730860ac6a2b3fa45" or .revision == "3bb6c406df47def067cb51eac7b82e6c39681a61") and (.contracts | index(1) != null)' "$evidence/nagare-version.json" >/dev/null ||
-  fail "a qualified Nagare 0.18.0 CLI (v0.18.0 or the MasterPlan 33 EP-248 commit) is required"
+# Qualified CLI: the first Nagare revision whose workloads can opt out of the
+# app's managed store (Nagare EP-261, IR-44). Replace with the first tag carrying it.
+jq -e '.version == "0.20.0" and .revision == "a314e7a9f9ca4d74b631601d26a8d6cb1675af00" and (.contracts | index(1) != null)' "$evidence/nagare-version.json" >/dev/null ||
+  fail "a qualified Nagare CLI (0.20.0 at a314e7a9, carrying the managed-store opt-out) is required"
 
 review_digest() {
   jq -er --arg directory "$evidence/$1-review" --arg document "$2" '
```


## Requested change

- **Opt out of the inherited store** (AC-1, AC-3). A web service, worker or task can declare
  that it does not inherit the app's managed Runtime env and Secret. It then renders with no
  managed `envFrom` and receives only what it names. The default stays as today.
- **References keep working** (AC-2). An opted-out workload can still reference keys of the
  app's runtime Secret by EnvSecretRef, bound through `--env-secret-resource` as now.
- **One documented inheritance rule** (AC-4). Make the worker's inherited store either the
  app's or one the CLI can write, and document it per workload kind.


## Not requested

Named Secrets beyond the app's store, per-key Kubernetes RBAC, or changes to Build- and
Preview-scoped env. Several Secrets per app would also solve Kotei's case, and the agents may
choose that design instead if it fits the store better, provided the acceptance case holds.
