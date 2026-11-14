---
id: 262
slug: upgrade-en-and-serve-operator-declared-en-tenants-from-one-server
title: "Upgrade En and serve operator-declared En tenants from one server"
kind: exec-plan
created_at: 2026-11-14T19:41:57Z
intention: "intention_01m7ds94hsecca24xy1ppxyrfn"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-11-14T19:41:57Z
  reviews:
    - model: "claude-fable-5-2"
      harness: "claude-code"
      at: 2026-11-14T20:04:26Z
      verdict: "changes-requested"
      note: "Pins and En tenant facts verified at 5bb3f80d; bind omits secret set's config/version review inputs, schema key collides for tenant 'app', context-parse file check and rollback claim need fixing"
  revisions:
    - model: "claude-fable-5-2"
      harness: "claude-code"
      at: 2026-11-14T20:09:06Z
      mode: "update"
      note: "Applied review findings: per-tenant key probe replaces operator metrics key, tenant-<name>.en schema keys, context parsing, bind review inputs, forward-only upgrade"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-14T21:23:48Z
      mode: "implement"
      note: "M1 pins and M2-M4 code with interpreter tests; native runs and release images pending"
---

# Upgrade En and serve operator-declared En tenants from one server

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture

The shared Mori registry (`mori://shinzui/mori`) is to run on the labs intranet, and it
authorizes registry and project access through En, the relationship-based authorization
service (`mori://shinzui/mori/plans/300-authorize-registry-and-project-access-through-en`).
Mori needs its own En schema, its own relationship store, and its own API keys, and it
must not see or disturb the relationships that gate every intranet sign-in. Nagare already
runs one En in `nagare-system` for its own site access. The latest En
(`mori://shinzui/en`, GitHub `master` at `5bb3f80d2bd54854c2d875bd89183d08d59b2106`) can
serve several isolated **tenants** from one process. A tenant is an independent
authorization owner with its own PostgreSQL database, schema file and API keys. The key
that authenticates a request selects its tenant, so a client cannot reach another tenant.

After this plan:

- Nagare's En runs that release in tenant mode. Its existing data is served unchanged as
  tenant `nagare`.
- An operator names more tenants in the active context. Nagare then provisions each one's
  database, migrations, schema, keys and backups through the reviewed auth component.
- `nagarectl en-tenant bind` copies a tenant's keys into an app's managed runtime Secret.
  The app reaches `http://en.nagare-system.svc.cluster.local` without any key being
  printed.
- Labs runs a release carrying this with a declared `mori` tenant, and intranet sign-in
  still works.

You can see it working when a request with the `mori` tenant's read-only key to
`GET /v1/schema` returns Mori's `registry.en`, the `nagare` tenant's key returns Nagare's
`app.en`, and a developer still signs in to a protected intranet site.

Deploying the Mori server itself belongs to
`mori://shinzui/mori/plans/309-deploy-the-shared-mori-registry-to-the-nagare-intranet-cluster`
and is not part of this plan.


## Progress

- [x] M1: Nagare-access and the En release image build from En `5bb3f80d`, with Nagare's
  source pins mirroring En's `cabal.project`. Acceptance: `nagare-access-test` green,
  `release.json` `releaseImages` regenerated and the release-images check passing,
  `just gate-fast` green, still in legacy mode.
  2026-11-14, partial: pins moved in `cli/nagare-access/cabal.project`,
  `nix/release-images.nix` and `cluster/bootstrap/auth-images/build-local-image.sh`
  (4499b066); the Hackage solve is unchanged, so `hackage-pins.json` is unchanged.
  `nagare-access-test` 228/228; fast gate green at 293c9717. 2026-11-14, done:
  `releaseImages` regenerated from `.#release-images-manifest` (23a36ee1; En
  `sha256:54dc5afc…`, nagare-access and the admin API change, Shōmei and cloudflared
  keep their digests); `release-images-check` passes; full gate green at dd189217 after
  the x86 check learnt the new spec's source tree.
- [x] M2: Nagare's En runs in tenant mode as tenant `nagare` with its data unchanged. Apply
  proves every tenant is available. Acceptance: on a disposable `mode=local` context
  upgraded from current `master`, relationships written before the upgrade are read back
  after it, the `[tenant nagare] Datastore id:` line shows the pre-upgrade id, and a
  protected-site sign-in passes. vmagent scrapes En, and `EnTenantUnavailable` fires while
  `en-db` is stopped.
  2026-11-14, code and interpreter tests done: `service.yaml` in tenant mode with
  `nagare-en-scrape-keys`; the en Deployment's verification and recovery prove every
  declared tenant through `Nagare.Inventory.Adapters.EnTenants` (6 tests in
  `InventoryEnTenantsSpec`); the `en` VMServiceScrape and `EnTenantUnavailable`.
  2026-11-14, confirmed natively on a `nagare-c4-amd64` k3d context bootstrapped from
  9af42782 and moved by `platform transition` to the drill candidate (dc73cf50 + 0.21.0):
  the 2 seeded `app` relationships read back identical, `[tenant nagare] Datastore id:
  a2e4f78b…` is the pre-upgrade id, a signed-in request answers 200 before and after, the
  en Deployment's verification passed through the live tenant proof, the scrape key gets
  200 on `/metrics` and 403 on `/v1/schema`, VictoriaMetrics holds
  `en_tenant_available{tenant="nagare"} 1`, `EnTenantUnavailable` fired 401 s after `en-db`
  went to 0 replicas and cleared 91 s after it returned. Evidence:
  `~/.local/state/nagare/drills/ep262/evidence/`.
- [ ] M3: Operator-declared tenants. `NAGARE_EN_TENANTS` plus a schema path per tenant
  yields a database `en-<name>-db`, a migration Job, a schema, a key Secret, En
  environment, backups, and the F147 restore recovery. Acceptance: inventory interpreter
  tests in `nagarectl-test`, then a local context with tenant `demo`. Its key writes and
  checks its own type, the `nagare` key cannot read it, and a backup-and-restore of
  `en-demo-db` brings its relationships back.
  2026-11-14, code and interpreter tests done (8 tests in `InventoryAuthTenantsSpec`, the
  restore case in `InventoryRebuildRestoreSpec`). Open: the local `demo` run, the backup and
  restore, and the measured memory per tenant.
- [ ] M4: `nagarectl en-tenant bind NAME --app APP -f CONFIG` delivers a tenant's keys into
  the app's managed runtime Secret as one reviewed secret change. Acceptance: on the local context, a deployed app in its
  own namespace makes a successful `POST /v1/check` against tenant `demo`.
  2026-11-14, command and helper tests done (`tenantKeyBinding`). Open: the local probe
  app's `POST /v1/check`.
- [ ] M5: Released and live on labs with tenant `mori`. Acceptance: the release proves the
  three release facts (full gate, EP-172 upgrade rehearsal read-back, intranet upgrade with
  deploy-and-login), then the labs context declares `mori`. The `mori` read-only key's
  `GET /v1/schema` returns Mori's `registry.en`, and intranet sign-in still passes.


## Surprises & Discoveries

- In tenant mode a ready Deployment says nothing about one tenant, and the Kubernetes
  adapter's only readiness seam was a pure function of the object. The tenant proof is a
  new `proveWorkload` probe on the adapter's pod operations, asked by verification and by
  recovery, so a retried apply cannot pass an unavailable tenant either (see the Decision
  Log). En's image has no shell, so the metrics read cannot go through `kubectl exec`.
- En's `ActiveSchema` gained a required `validSchema` field (En ADR 12); two
  nagare-access test servers construct it.
- A VMRule has no proved conditional update form, so the first local transition stopped
  (KnownNoEffect, nothing written) on the edited `nagare-alerts`. The alert moved to its own
  VMRule `nagare-auth-alerts` (206d0fb0). The stopped transition stayed open and only its
  own candidate could end it, so the drill restarted on a fresh cluster; on labs the same
  lock is why the candidate is rehearsed locally first.
- On the live transition the tenant proof failed with "en port-forward failed": apply runs
  the adapter through a phase interpreter, so the proof's interpreted branch sent the
  metrics read to kubectl. The read is now always a kubectl request that the live
  interpreter answers through the forward (dc73cf50). The migration Jobs' pods carry
  `app.kubernetes.io/name=en`, so `logs deploy/en` can pick one; the proof and the alert
  text select the server pod.
- 6b3a7dd3 (another session's commit) left two modules over the 1000-line limit, which
  made every fast gate red; 293c9717 split them without behaviour changes.


## Decision Log

- Decision: Pin En at GitHub `master` `5bb3f80d2bd54854c2d875bd89183d08d59b2106`, not a
  local checkout's head.
  Rationale: the operator's direction (2026-11-14). The local sibling checkout lagged
  GitHub by two commits, and the second of them retires the Biscuit fork.
  Date: 2026-11-14.
- Decision: Run tenant mode always, with Nagare's own data as tenant `nagare`, even when no
  other tenant is declared.
  Rationale: tenant mode and legacy mode are different configuration constructors in En
  (its ADR 9), with different logs, metrics and environment. Running one shape means
  adding a tenant is an ordinary revision rather than a mode switch, and the upgrade
  rehearsal covers the only conversion.
  Date: 2026-11-14.
- Decision: Each declared tenant gets its own direct PostgreSQL database `en-<name>-db` in
  `nagare-system`, declared exactly like `en-db`.
  Rationale: En requires one database per tenant and refuses two tenants on one. A
  direct database reuses the proven `en-db` path: credential Secret, migration Job,
  signed backup schedule and the F147 restore recovery. An app database on a shared
  server (ADR 30, ADR 37) would split one platform service across two ownership models.
  The cost is one small PostgreSQL per tenant, measured in M3.
  Date: 2026-11-14.
- Decision: Tenants are declared by the operator in the active context, never by an app's
  declaration.
  Rationale: a tenant changes the platform En Deployment and restarts it. A delegated
  deployer's repository content is untrusted (ADR 35), so it must not be able to restart
  the service that gates every sign-in or inject a schema into it.
  Date: 2026-11-14.
- Decision: En gets a scrape key for monitoring, in a new generated Secret
  `nagare-en-scrape-keys` (key `metrics`), set as `EN_METRICS_KEYS`. Apply's proof for the
  En Deployment reads `en_tenant_available` for every declared tenant with it.
  Rationale: the operator wants a monitoring credential that reads every tenant's metrics
  and no tenant's data (2026-11-14). In tenant mode `/health/ready` stays 200 while any
  tenant can serve (En ADR 10), so a ready Deployment no longer proves the `nagare` tenant
  opened its database. With the key present, one `GET /metrics` covers all tenants. A new
  Secret is used because credential templates compare only the key set and never rotate.
  Adding a key to the existing `nagare-en-api-keys` would read as drift on every existing
  context.
  Date: 2026-11-14.
- Decision: vmagent scrapes En, and an alert fires when a tenant is unavailable. The scrape
  object lives in `nagare-system`, beside the scrape key.
  Rationale: in tenant mode En stays ready and running while one tenant's database is
  down, so no existing alert sees it, and apply's proof only looks at apply time. A dead
  `nagare` tenant fails every sign-in. A scrape object can only name a bearer-token Secret
  in its own namespace, and vmagent selects scrape objects in every namespace
  (`selectAllByDefault: true` in `cluster/observability/victoria-metrics/values.yaml`).
  Placing the object in `nagare-system` therefore needs no copy of the credential in
  `monitoring`. This replaces the earlier deferral (operator, 2026-11-14).
  Date: 2026-11-14.
- Decision: Keys reach an app through `nagarectl en-tenant bind`, which writes into the
  app's existing managed runtime Secret through the same writer as `nagarectl secret set`.
  Rationale: an app already receives `nagare-secret-<app>-runtime` through `EnvSecretRef`.
  Reusing it adds no cross-namespace Secret owner, and the value is never printed. It is a
  reviewed secret change like any other, so it takes `secret set`'s `-f CONFIG`,
  `--version` and `--save-plan`. Only an operator can run it, because it reads a Secret in
  `nagare-system`.
  Date: 2026-11-14.
- Decision: A tenant's schema is the `en-schema` ConfigMap key `tenant-<name>.en`, and its
  file check happens where the auth scope is compiled, not when the context is parsed.
  Rationale: a key `<name>.en` for a tenant named `app` would overwrite Nagare's own
  `app.en`. Every command parses the context, so a file check there would refuse unrelated
  commands for anyone holding the context without the operator repository.
  Date: 2026-11-14.
- Decision: Apply proves the tenants in the Kubernetes adapter's verification and
  recovery, not in the rollout wait alone, through a `proveWorkload` probe that only the
  en Deployment in `nagare-system` answers. The tenants to prove are the reviewed
  Deployment's own `EN_TENANTS`. A live runtime reads `GET /metrics` through a private
  port-forward (`Nagare.Inventory.EnForward`, shared with the access runtime); an
  interpreted runtime sends the read to its kubectl interpreter.
  Rationale: after a stopped apply, recovery re-observes the object; a check only in the
  rollout wait would let the retry prove the update complete with the tenant still down.
  Date: 2026-11-14.
- Decision: The tenant context variables are read from the context file only, not from
  the environment, and `nagarectl context env` prints them only when declared.
  Rationale: the variable names depend on the tenant names, and `scripts/lib/target.sh`
  exports them by sourcing the file, so both stay in agreement without a fixed list.
  Date: 2026-11-14.
- Decision: `EnTenantUnavailable` lives in a new VMRule `nagare-auth-alerts`, not a new
  group in `nagare-alerts`.
  Rationale: an upgrade then creates an object instead of updating a VMRule in place,
  which no update proof covers.
  Date: 2026-11-14.
- Decision: The local M2–M4 run upgrades from a 0.20.0 context (`master` 9af42782) to a
  drill-only commit that differs from the candidate only by `platformVersion` 0.21.0 and
  `0.20.0` in `transitionsFrom`, through `platform transition plan` and `commit`, on the
  `nagare-c4-amd64` daemon with the x86_64 release images under Rosetta.
  Rationale: a context moves between releases only through the reviewed transition, and
  the next release makes exactly that change.
  Date: 2026-11-14.
- Decision: The move to tenant mode is forward-only.
  Rationale: a release moves a context only from the sources its payload lists
  (`cli/nagarectl/src/Nagare/Platform/Transition.hs`), and the previous release does not
  list this one. A defect is answered with a fixing release. `en-db` is never rewritten,
  so no data depends on going back.
  Date: 2026-11-14.


## Outcomes & Retrospective

(To be filled at completion.)


## Context and Orientation

**En in Nagare today.** En is an authorization server. It stores relationships (tuples
such as "user ann is a viewer of app keiro-docs"), evaluates checks against a schema, and
is reached over HTTP with bearer API keys. Nagare deploys it in the `nagare-system`
namespace as Deployment `en`, with Service `en` on port 80. The manifests are:

- `cluster/bootstrap/en/service.yaml`, the Deployment and Service. Legacy-mode
  environment: `EN_DATABASE_URL` built from Secret `nagare-db-en-db`, `EN_SCHEMA_PATH`,
  `EN_API_KEYS_READ_WRITE=nagarectl:<secret>`, `EN_API_KEYS_READ_ONLY=nagare-access:<secret>`
  from Secret `nagare-en-api-keys`, cache sizes, and a 384Mi memory limit.
- `cluster/bootstrap/en/configmap.yaml`, ConfigMap `en-schema` with key `app.en`. It
  defines the object types `user`, `group`, `app` and `delegation`.
- `cluster/bootstrap/en/migrations.yaml`, Job `en-migrate`, which runs `en-migrate up`
  from the same image against `en-db`.

These files are compiled into the reviewed inventory by
`cli/nagarectl/src/Nagare/Inventory/Components/Auth.hs`. Its `packaged` list pins each
file's SHA-256, so any edit to them must update that digest. `compileAuthComponent`
insists the auth databases are exactly `["shomei", "en"]`. `stampSchemaDigest` annotates
the Deployment with the schema's digest so a schema change rolls En. The dependency
mapping near the bottom of `compileAuth` (`addExternal`) sends every Job or Deployment
whose name starts with `en` to the `en` database prerequisite, and `proofFor` matches
migration proofs by the same prefix. Tenant Jobs named `en-<name>-migrate` would match
that prefix wrongly, so it must change. `internalOrder` lists what the `en` Deployment
waits for, and a check near the end requires exactly the `en` and `shomei` prerequisites. `cli/nagarectl/src/Nagare/Inventory/Bootstrap.hs`
(`compileBootstrapWithAuthAndScopes`) and
`cli/nagarectl/src/Nagare/Inventory/Components/PackagedAuth.hs` call it.
`cli/nagarectl/app/Nagare/Cli/Bootstrap/Platform.hs` builds `AuthInput` from the context.
Generated, never-rotated Secrets come from
`cli/nagarectl/src/Nagare/Inventory/Adapters/CredentialTemplate.hs`, whose
`authCredentialKind` accepts three literal Secret names and refuses any other.

`cli/nagarectl/src/Nagare/Database/Restore.hs` (`enDatastoreRecovery`) handles F147. En
stamps grants with PostgreSQL transaction ids, which a dump does not carry. After a
restore, a Job therefore advances the counter past the restored rows and deletes
`en_datastore_metadata`, so En mints a fresh datastore id. It matches only
`name == "en-db"` in `nagare-system`. Every tenant database needs the same recovery, or a
restored tenant silently hides its grants.

`nagare-access`, the forward-auth enforcer in `cli/nagare-access`, links En's
`en-client` and `en-servant` (`cli/nagare-access/src/Nagare/Access/En.hs`).
A third client lives outside this repository: the labs intranet portal in
`mori://tan/tan-ng-labs` (`web/apps/portal`, artifact-level URI pending). Its admin pages
call En's `/v1/check`, `/v1/lookup`, `/v1/lookup-subjects`, `/v1/expand` and `/v1/schema`
with the `read-only` key of `nagare-en-api-keys`, copied into its runtime Secret as
`EN_API_KEY`. That key stays a key of tenant `nagare`, and En's `docs/api/openapi.json` is
byte-identical between the two pins, so the portal needs no change.

`cli/nagare-access/cabal.project` pins En, Shōmei, webauthn, biscuit-haskell and
hs-opentelemetry-instrumentation-servant by `source-repository-package` tag.
`nix/release-images.nix` builds the release images (En, Shōmei, nagare-access, admin API,
cloudflared) for linux/amd64 from `sourcePins`. These must equal the `cabal.project`
tags; evaluation throws otherwise. `nix/release-images/hackage-pins.json` lists the
Hackage versions where the pinned nixpkgs differs from the cabal solve, and the committed
`release.json` `releaseImages` member must equal the built manifest
(`releaseImages.check`).

**What changes upstream.** The current pin is En `c3ee100a0b2cc63a50a9473ef590de7086dca4d0`.
GitHub `master` is `5bb3f80d2bd54854c2d875bd89183d08d59b2106`, 44 commits later. Verify
it again with `git ls-remote https://github.com/shinzui/en.git refs/heads/master` before
pinning. Relevant upstream changes:

- No new migrations. `en-migrations` changed only its `.cabal` layout, so an existing
  `en-db` keeps its ledger and datastore id.
- Tenant mode (En MasterPlan 12, ADR 9). `EN_TENANTS=a,b` plus `EN_TENANT_<NAME>_*`
  settings (`DATABASE_URL`, `SCHEMA_PATH`, `API_KEYS_READ_WRITE`, `API_KEYS_READ_ONLY`,
  and optionally `POOL_SIZE`, `GC_WINDOW`, `EXPECTED_DATASTORE_ID`, …). `<NAME>` is the
  tenant name upper-cased, with `-` replaced by `_`. Beside `EN_TENANTS`, the legacy
  `EN_DATABASE_URL`, `EN_SCHEMA_PATH` and `EN_API_KEYS_*` are refused. `GET /metrics`
  with a tenant's key returns only that tenant's samples. `EN_METRICS_KEYS` holds
  `name:secret` scrape keys that read every tenant's metrics and get 403 on every other
  route. Other `EN_*` settings are
  process-wide and apply to each tenant, so each tenant gets its own caches of the
  configured sizes and its own pool of 10 PostgreSQL connections, and memory grows per
  tenant. A tenant name is a lower-case letter
  followed by at most 30 lower-case letters, digits or `-`. Adding a tenant needs a
  restart. Subcommands such as `en-server export` take `--tenant NAME`. The operator guide
  is En's `docs/user/service-and-operations.md`, section "Serving several tenants"
  (artifact-level URI pending).
- Readiness (En ADR 10). `/health/ready` is 200 while any tenant serves. Per-tenant state
  is the gauge `en_tenant_available{tenant=…}` and the log lines
  `[tenant NAME] UNAVAILABLE|AVAILABLE`.
- Writes are validated against the active schema (En ADR 12): a tuple the schema cannot
  interpret is refused with `400 schema_violation`, and deletes are never checked. Nagare
  writes only `user`, `group`, `app` and `delegation` tuples, which `app.en` defines. The
  tenant section of En's operator guide still says writes are not validated; the ADR and
  the code are current.
- `X-En-Api-Key` is now accepted beside `Authorization: Bearer` (En IR-1). It unblocks
  held EP-216 but is not used here.
- Pins Nagare must mirror (ADR 1). biscuit-haskell moves from the fork
  `https://github.com/shinzui/biscuit-haskell.git@8c0b3c5a…` to upstream
  `https://github.com/eclipse-biscuit/biscuit-haskell.git@469eaedc66be6e7629954bfd631b1842a968a33a`
  (subdir `biscuit`), which retires the fork. hs-opentelemetry-instrumentation-servant
  moves from `7a6f692e…` to `d79a26337faedc37fd9301e58a207cb5834fc909`. `crypton >= 1.1`
  stays load-bearing. Shōmei's own `cabal.project` does not pin the servant package, so
  Shōmei stays at `6179d567…`.

**Mori's side.** Mori's schema is `mori-api/access/registry.en` in `mori://shinzui/mori`
(artifact-level URI pending; the file exists at Mori `297dcc36`). Mori reads
`MORI_EN_BASE_URL` and separate read-only and grant-write credentials, per Mori plan 300.

**Relevant ADRs.**
[ADR 1](../adr/0001-auth-plane-images-mirror-upstream-dependency-plans.md): Nagare's pins
mirror upstream `cabal.project`. It names "the En Biscuit fork", so amend it when the fork
retires. [ADR 2](../adr/0002-auth-service-images-own-and-apply-their-database-schemas.md):
each service's migration Job runs from the server's own image, and that covers every
tenant database. [ADR 13](../adr/0013-operator-deployment-material-lives-in-a-private-repository-with-remote-state.md):
the labs context and Mori's schema copy live in the operator repository (for labs,
`mori://tan/tan-ng-labs`), never here.
[ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md):
tenant resources stay in the auth owner scope.
[ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md):
defects are found by interpreter tests, and native runs only confirm.
[ADR 29](../adr/0029-site-access-is-a-reviewed-relationship-per-hostname.md): site access
lives in En, so the `nagare` tenant's data is what sign-in depends on.
[ADR 30](../adr/0030-app-databases-are-reviewed-tenants-of-a-shared-server.md) and
[ADR 37](../adr/0037-an-app-may-own-its-database-and-nagare-keeps-apps-apart.md): app
databases, considered and not used for tenant stores.
[ADR 35](../adr/0035-a-delegated-deployer-is-trusted-and-repository-content-is-not.md):
why tenants are operator-declared.

**Terms.** A *context* is the flat `export VAR=value` file selecting a target, parsed by
`cli/nagarectl/src/Nagare/Target.hs` and `cli/nagarectl/app/Nagare/Cli/Runtime/Context.hs`
and documented in `nagare.target.env.example` and `docs/user/contexts.md`. `Target.hs`
reads it into a key-value map (`parseContextEnv`) and then into the fixed fields of
`TargetProfile`. `renderContextShellEnv` prints those fields for `nagarectl context env`,
and `scripts/lib/target.sh` is its shell twin, which sources the file directly. A context
file is usually a symlink from the XDG directory into the operator repository. A *disposable
local context* is a `mode=local` k3d target (`docs/user/local-development.md`).


## Plan of Work

**M1, the pin move.** Change En's tag in `cli/nagare-access/cabal.project` (one
stanza listing seven subdirs) to `5bb3f80d…`. Replace the biscuit-haskell stanza with the
`eclipse-biscuit` location and `469eaedc…`, and set the servant tag to `d79a2633…`. Copy
any constraint or `allow-newer` change from En's `cabal.project` at that commit; its new
`tasty-bench ==0.5` is test-only and is not needed. Mirror
the same pins and hashes in `nix/release-images.nix` `sourcePins`; prefetch the hashes,
since a wrong `hash` fails the fetch. Rebuild the cabal solve and refresh
`nix/release-images/hackage-pins.json` for packages whose solved version differs from
nixpkgs. Fix any `en-client` or `en-servant` API change in
`cli/nagare-access/src/Nagare/Access/En.hs` and its tests. Build the five release images
on an x86_64-linux builder and regenerate `release.json` `releaseImages` from
`.#release-images-manifest`. Amend ADR 1: the Biscuit fork is retired in favour of
upstream main by commit, and Hackage `biscuit-haskell-0.5.0.0` r1 cannot replace it.
`service.yaml` stays in legacy mode in M1.

**M2, tenant mode for Nagare's own data.** Rewrite the `en` container environment in
`cluster/bootstrap/en/service.yaml`:

- `EN_TENANTS=nagare`.
- `EN_TENANT_NAGARE_DATABASE_URL`, the same libpq string from `nagare-db-en-db`.
- `EN_TENANT_NAGARE_SCHEMA_PATH=/etc/en/schema/app.en`.
- `EN_TENANT_NAGARE_API_KEYS_READ_WRITE=nagarectl:$(…)` and
  `EN_TENANT_NAGARE_API_KEYS_READ_ONLY=nagare-access:$(…)` from the unchanged
  `nagare-en-api-keys`.
- `EN_METRICS_KEYS=scrape:$(…)` from a new generated Secret `nagare-en-scrape-keys`, key
  `metrics`.

Keep the process-wide cache settings and update the pinned digest in `Auth.hs`. Add
`nagare-en-scrape-keys` to the generated Secret templates beside `nagare-en-api-keys`
(`secretTemplate` in `Auth.hs` and `authCredentialKind` in `CredentialTemplate.hs`), with
`Protect` lifecycle, and make the Deployment wait for it in `internalOrder`.

Then make apply's success for the `en` Deployment require `en_tenant_available{tenant=X} 1`
for every declared tenant, from one `GET /metrics` with the scrape key. Send it through
the En port-forward
in `cli/nagarectl/src/Nagare/Inventory/AccessRuntime.hs`. Inventory apply already holds
one for the whole command (`withContextEnSession` in
`cli/nagarectl/app/Nagare/Cli/Inventory/Workflow.hs`). Where the platform apply path has
no session, use the sessionless `kubectlTransport` from the same module, which opens the
forward on first use, so a first bootstrap works once En exists. Bound the read by the
existing rollout wait. Report `en tenant X unavailable` with En's last `UNAVAILABLE`
reason on failure. Then add the scrape and the alert. Both belong to the optional observability component,
compiled by `cli/nagarectl/src/Nagare/Inventory/Components/ObservabilityExtras.hs`, whose
`manifestFiles` pins each file's SHA-256 and whose `addresses` lists each object:

- A new file `cluster/observability/en/vmservicescrape.yaml`: a `VMServiceScrape` named
  `en` in namespace `nagare-system`. It selects the `en` Service by
  `app.kubernetes.io/name: en`, scrapes port `http` at `/metrics` every 30s, and sets
  `bearerTokenSecret` to `nagare-en-scrape-keys`, key `metrics`. The Secret holds the bare
  secret, which is what a bearer token needs; only the En variable adds the `scrape:` name.
- Every address in that module is built for namespace `monitoring`. Let the address
  helper take the namespace, give this object the `nagare-system` namespace prerequisite,
  and order it after the auth scope's `nagare-en-scrape-keys` Secret through
  `upstreamExternalAfter`.
- A new VMRule `nagare-auth-alerts` in `cluster/observability/vmrules/nagare-auth-alerts.yaml`,
  group `nagare.auth`, with one rule, `EnTenantUnavailable`: `en_tenant_available == 0`
  for 5 minutes, severity `critical`, naming the tenant label (see the Decision Log).

The VictoriaMetrics operator must be able to read that Secret in `nagare-system`. Confirm
it on the local context; if its role is limited to `monitoring`, grant it `get` on this one
Secret from the observability component. Document the scrape key, the scrape and the alert
in `docs/user/observability.md`.

Do not pin
`EN_TENANT_NAGARE_EXPECTED_DATASTORE_ID`: the F147 restore deliberately rotates the
datastore id, and a pin would need a reviewed re-pin after every restore. Model the
availability proof in the inventory interpreter tests first (ADR 25): an unavailable
tenant must fail apply, never pass it.

**M3, operator-declared tenants.** Add context fields:

- `NAGARE_EN_TENANTS`, a comma-separated list. Each name follows En's grammar, and
  `nagare` is reserved.
- `NAGARE_EN_TENANT_<NAME>_SCHEMA`, a path to the schema file. `<NAME>` is upper-cased
  with `-` replaced by `_`, as En does. A relative path is resolved against the directory
  of the context file after `canonicalizePath`, so a symlinked context resolves inside the
  operator repository.

Read them in `Nagare/Target.hs` from the parsed key-value map into a new `TargetProfile`
field, since the variable names are not fixed. There, refuse an invalid or reserved name,
a tenant with no schema variable, and a schema variable for an undeclared tenant. Do not
touch the file there. `cli/nagarectl/app/Nagare/Cli/Bootstrap/Platform.hs` reads the file
when it builds `AuthInput`, and refuses a path that is missing or not a file.
`renderContextShellEnv` prints both kinds of variable verbatim, so `nagarectl context env`
still agrees with `scripts/lib/target.sh`, which exports them by sourcing the file and
needs no change. Document them in `nagare.target.env.example`, `docs/user/contexts.md` and
`docs/user/config-reference.md`. Carry the tenant list with schema bytes into `AuthInput`
(new field, for example `authEnTenants :: ![EnTenant]`, with
`data EnTenant = EnTenant { name :: !EnTenantName, schema :: !ByteString }` following the
strict, unprefixed record rule).

For each tenant, `compileAuth` generates:

- the key `tenant-<name>.en` in ConfigMap `en-schema`, with the schema digest stamp
  extended over all keys;
- a generated Secret `nagare-en-tenant-<name>-keys` with keys `read-write` and
  `read-only`, `Protect`. `authCredentialKind` in `CredentialTemplate.hs` gains a rule for
  the `nagare-en-tenant-…-keys` name shape;
- a Job `en-<name>-migrate`, the `en-migrate` Job pointed at `en-<name>-db`;
- environment `EN_TENANT_<NAME>_DATABASE_URL`, `_SCHEMA_PATH` and `_API_KEYS_*`, with
  caller names `<name>-write` and `<name>-read`. `EN_TENANTS` lists `nagare` first.

`compileAuthComponent` accepts `["shomei", "en", "en-<name>"...]` in declaration order.
`packagedAuthInputs` in `PackagedAuth.hs` builds a direct database input for each instead
of its fixed two, and `Bootstrap.hs` and `Platform.hs` pass them on. Replace the `en`
prefix tests in `compileAuth` with exact names:

- `en-<name>-migrate` depends on `en-<name>-db` only;
- the `en` Deployment depends on every En database, every En migration proof, every
  tenant key Secret and the `en-schema` ConfigMap (`addExternal`, `proofFor` and
  `internalOrder`);
- the prerequisite check requires `shomei`, `en` and every `en-<name>`.

Generalize `enDatastoreRecovery` to `en-db` and every `en-<name>-db` in `nagare-system`.
Each tenant adds a PostgreSQL StatefulSet with a 5Gi volume and a backup schedule, and
two caches and a connection pool inside En. Measure the node memory one tenant adds, raise
the En memory limit by the measured En share, and record both numbers here.

Removing a tenant from the context is refused at planning in this plan. Its database and
Secret are protected, and a reviewed retirement is out of scope.

**M4, key delivery.** Add `nagarectl en-tenant bind NAME --app APP -f CONFIG
--read-write-as VAR --read-only-as VAR` (either `-as` flag optional, at least one
required) to the parser module that holds `secret set`. It also takes `secret set`'s
`--version TOKEN` and `--save-plan DIR`, with the same meaning. It reads
`nagare-en-tenant-<NAME>-keys` in the active context's cluster and writes the named
variables into the app's managed runtime Secret as one reviewed change, through
`saveReviewedSecretChange` in `cli/nagarectl/app/Nagare/Cli/Commands/Environment.hs`. It
never writes a value to stdout or stderr. It is an operator command: a delegated deployer
cannot read Secrets in `nagare-system`, and the command says so when the read is refused. The
app sets the En base URL itself as a literal, `http://en.nagare-system.svc.cluster.local`.
Document both in `docs/user/env-and-secrets.md` under a new "En tenants" section.

**M5, release and labs.** Cut the release with the `nagare-release` skill. The EP-172
rehearsal must cover the legacy-to-tenant conversion: seed site-access grants on the
previous release, upgrade, read them back, and sign in. After labs upgrades and passes
deploy-and-login, add to the labs context in `mori://tan/tan-ng-labs`
`NAGARE_EN_TENANTS=mori` and `NAGARE_EN_TENANT_MORI_SCHEMA=<copy of Mori's registry.en>`.
Then plan, apply and verify. Binding to the Mori app happens when Mori plan 309 deploys
it. Both labs steps are cloud mutations and need the operator's go-ahead as one bounded
sequence.


## Concrete Steps

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/nagare`, unless
stated.

Confirm the pins (M1):

```bash
git ls-remote https://github.com/shinzui/en.git refs/heads/master
git ls-remote https://github.com/eclipse-biscuit/biscuit-haskell.git | grep 469eaedc
nix run nixpkgs#nix-prefetch-github -- shinzui en --rev 5bb3f80d2bd54854c2d875bd89183d08d59b2106
nix run nixpkgs#nix-prefetch-github -- eclipse-biscuit biscuit-haskell --rev 469eaedc66be6e7629954bfd631b1842a968a33a
nix run nixpkgs#nix-prefetch-github -- shinzui hs-opentelemetry-instrumentation-servant --rev d79a26337faedc37fd9301e58a207cb5834fc909
```

Expected: the first prints `5bb3f80d2bd54854c2d875bd89183d08d59b2106	refs/heads/master`.

Build and test (M1 to M4):

```bash
(cd cli/nagare-access && cabal build all && cabal test nagare-access-test)
(cd cli/nagarectl && cabal test nagarectl-test)
nix build .#release-images-manifest --system x86_64-linux
just haskell-style-check
just gate-fast
```

Expected: tests end with `0 failures`. `just gate-fast` gates the committed revision, so
commit first.

Local confirmation (M2 to M4). Use a disposable `mode=local` context per
`docs/user/local-development.md`, with the packaged `nagarectl` built from the commit
under test:

```bash
nix build "git+file://$PWD?rev=$(git rev-parse HEAD)#nagarectl"
kubectl --context <ctx> -n nagare-system logs -l 'app.kubernetes.io/name=en,app.kubernetes.io/component!=migration' -c en | grep -E '^\[tenant|Tenants:'
```

Expected after M3 with tenant `demo`:

```text
Tenants: nagare, demo
[tenant nagare] Datastore id: <the id logged before the upgrade>
[tenant demo] Datastore id: <new id>
```


## Validation and Acceptance

- **M1.** `nagare-access-test` passes. `nix build .#release-images-manifest` output equals
  `release.json` `.releaseImages`, and the release-images check passes. The En image label
  `io.nagare.source.en` names `@5bb3f80d…`.
- **M2.** In `nagarectl-test`, an inventory case where `en_tenant_available{tenant="nagare"}`
  is 0 fails the apply and a case where it is 1 passes it. Locally, the scrape key gets
  200 from `GET /metrics` and 403 from `GET /v1/schema`. With observability installed on
  the local context, the query `en_tenant_available{tenant="nagare"}` returns 1 in
  VictoriaMetrics. After scaling `en-db` to zero replicas, En's pod stays ready and
  `EnTenantUnavailable` fires; it clears after scaling back. On a local context bootstrapped
  from current `master`:
  - before the upgrade, grant a user on a protected site and record
    `GET /v1/relationships` for `app` objects and the datastore id;
  - upgrade to the commit under test;
  - the same relationships come back and the datastore id is unchanged;
  - the user signs in to the protected site.
- **M3.** In `nagarectl-test`:
  - a context with `NAGARE_EN_TENANTS=demo` yields `en-demo-db`, `en-demo-migrate`,
    `nagare-en-tenant-demo-keys`, an `en-schema` key `tenant-demo.en`, and the tenant
    environment, and the `en` Deployment waits for `en-demo-db` and its migration proof;
  - a tenant named `app` leaves the key `app.en` holding Nagare's schema;
  - an invalid name, the name `nagare`, a missing schema, and a removed tenant are each
    refused at planning, and a context whose schema file is absent still parses;
  - the restore Job for `en-demo-db` carries the F147 recovery.

  Locally with schema `object doc { relation viewer: user }`:
  - the `demo` write key writes `doc:d1#viewer@user:ann`, and its check returns allowed;
  - the `nagare` read-only key's check on `doc` returns 400, and the `nagare` write key
    writing a `doc` tuple gets `400 schema_violation`;
  - `GET /v1/schema` per key returns only that tenant's schema;
  - after backing up `en-demo-db`, deleting its data and restoring through
    `docs/user/backups-and-disaster-recovery.md`'s path, the relationship is back.
- **M4.** `nagarectl en-tenant bind demo --app probe -f CONFIG --read-only-as EN_KEY`,
  with the `--version` a reviewed secret change requires, exits 0 and prints no key. A probe Job in the app's namespace with `EN_KEY` from its runtime Secret
  gets 200 from `POST http://en.nagare-system.svc.cluster.local/v1/check`.
- **M5.** The release record shows its full gate green and the EP-172 rehearsal read-back
  passing. On labs, the developer deploy-and-login check passes after the upgrade, and
  again after the `mori` tenant is added. The portal's admin pages (sites, teams, access)
load after each of the two. En's log shows `Tenants: nagare, mori` with both
  available. `GET /v1/schema` with the `mori` read-only key returns Mori's `registry.en`.


## Idempotence and Recovery

Re-planning and re-applying is safe. Generated key Secrets are create-only and never
rotate, and migration Jobs are revision-named with retained proofs (ADR 2).

The tenant-mode conversion changes only the Deployment's environment and never touches
`en-db`'s ledger or datastore id, so tokens and cursors minted before it stay valid. It is
forward-only: a context does not move back to the previous release, and a defect found
after the upgrade is answered with a fixing release.

A bound key is a copy. Generated keys exist only in Kubernetes, so a cluster rebuild
mints new tenant keys and the copies in app runtime Secrets stop working. After a rebuild,
run `nagarectl en-tenant bind` again for each bound app.

If a tenant's database fails, En keeps serving the others and apply reports the tenant
unavailable. Fix the database and re-apply; do not remove the tenant to make apply pass.
A tenant database restore uses the generalized F147 recovery, after which that tenant's
old consistency tokens fail cleanly. Any guard that refuses on labs stops the work and is
reported to the operator.


## Interfaces and Dependencies

- Upstream: En `mori://shinzui/en` at `5bb3f80d2bd54854c2d875bd89183d08d59b2106`
  (`en-core`, `en-client`, `en-servant`, `en-server`, `en-migrations`, `en-biscuit`).
  biscuit-haskell from `https://github.com/eclipse-biscuit/biscuit-haskell.git` at
  `469eaedc…`. hs-opentelemetry-instrumentation-servant
  `mori://shinzui/hs-opentelemetry-instrumentation-servant` at `d79a2633…`. Shōmei
  `mori://shinzui/shomei` unchanged at `6179d567…`.
- `Nagare.Inventory.Components.Auth.AuthInput` gains the tenant list. `compileAuthComponent`
  accepts the tenant databases after `shomei` and `en`.
- Context fields `NAGARE_EN_TENANTS` and `NAGARE_EN_TENANT_<NAME>_SCHEMA`, read by
  `Nagare.Target`.
- Secrets in `nagare-system`: `nagare-en-scrape-keys` (`metrics`) and
  `nagare-en-tenant-<name>-keys` (`read-write`, `read-only`). Database `en-<name>-db`. ConfigMap `en-schema` key `tenant-<name>.en`.
- Observability: `VMServiceScrape` `en` in `nagare-system`, and the alert
  `EnTenantUnavailable` in `VMRule` `nagare-auth-alerts`.
- CLI: `nagarectl en-tenant bind NAME --app APP -f CONFIG [--read-write-as VAR]
  [--read-only-as VAR] [--version TOKEN] [--save-plan DIR]`.
- Consumer: Mori plans 300 and 309 consume the `mori` tenant's keys and
  `http://en.nagare-system.svc.cluster.local`.
