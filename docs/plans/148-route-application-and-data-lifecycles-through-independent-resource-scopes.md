---
id: 148
slug: route-application-and-data-lifecycles-through-independent-resource-scopes
title: "Route application and data lifecycles through independent resource scopes"
kind: exec-plan
created_at: 2026-09-16T17:23:45Z
intention: "intention_01m2nkkn0deaht66kevpmkjjpp"
master_plan: "docs/masterplans/23-make-managed-resources-first-class-through-typed-scoped-inventories.md"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-09-16T17:23:45Z
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-17T04:04:49Z
      mode: "update"
      note: "Cascaded consequences of MasterPlan 23 API validation"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-24T15:13:26Z
      mode: "implement"
      note: "Begin application and standalone data scope compilation"
---

# Route application and data lifecycles through independent resource scopes

This ExecPlan is a living document. Keep its living sections current and promote durable decisions into docs/adr/.


## Purpose / Big Picture

Application, database, broker, environment, storage, and task commands participate in the same ownership protocol without becoming part of a platform release. Updating one application preserves other applications and platform intent. Review includes all resources that execution will create, including helper-created credentials and backups.

Every supported application-side mutation is either a desired-scope update, a reviewed operational action against owned resources, or an explicitly declared controller delegation. There is no independent imperative path that silently changes ownership.


## Progress

- [x] (2026-09-24) M1 partial: Application, Deployment, Broker, and Volume carry optional validated logical keys through config emission/loading; stable scope/resource-ID helpers and a complete standalone database scope compiler are covered by DSL and operator tests.
- [ ] M1: Compile applications and standalone services into complete scopes.
- [ ] M2: Integrate shared-owner contributions, environment intent, and publication.
- [ ] M3: Route operational and data lifecycle commands through reviewed operations.
- [ ] M4: Remove duplicate render/apply paths and prove scope isolation.


## Surprises & Discoveries

2026-09-24: The existing database builder already binds all five retained-database members, including the credential template and backup CronJob, to canonical native bytes. A standalone database scope can wrap this builder without reconstructing database flags. The current application deploy still renders databases from the old four-object path, so application compilation and command routing remain open. Existing config literals must initialize the new optional keys explicitly because their records have strict fields.


## Decision Log

2026-09-16: Preserve separately submitted environment/secret intent across configuration deploys. Inputs are explicit versioned intent channels composed into one owner declaration, not live cluster data silently copied into desired state.

2026-09-16: App-only deployments can update their authorized contribution to shared routing configuration, but cannot replace the platform-owned resource or advance the platform release.

2026-09-16: Interactive administrative shells cannot be represented as read-only commands. Journal a scoped maintenance session with bounded resource authority and re-observe afterward; arbitrary SQL effects remain explicitly unknown until reconciled.

2026-09-24: Give the Application aggregate an optional logical key as well as its contained resources. The aggregate owns the ScopeId, so a display-name change needs a pinned scope key to retain accepted history; absent a key, the current name remains the backward-compatible default. This is an extension of ADR 22's resource identity rule.


## Outcomes & Retrospective

In progress. Stable identity inputs and a standalone database scope compiler are present; application compilation, command migration, scope-isolation proof, and complete mutation coverage remain open.


## Context and Orientation

Hard dependencies are [cloud/artifact adapters](146-reconcile-cloud-host-and-artifact-resources-through-inventory-adapters.md), [cluster components](147-compile-cluster-bootstrap-into-owned-resource-components.md), and [lifecycle policy](149-explain-drift-and-execute-reviewed-adoption-migration-and-retirement.md), which themselves depend on the typed inventory and durable executor. They provide canonical context/scope/resource identity, opaque review boundaries, typed publication outputs, a complete database declaration builder, guarded Kubernetes execution, owner-composed contributions, and identity-bound adoption/retirement.

cli/nagarectl/src/Nagare/App/Deploy.hs has renderAppObjects, renderPlan, liveDeploy, livePhaseExec, ensureDatabase, and runHooks. Its current database render path omits credentials and backup CronJobs that live creation adds, and reconstructs flags from a richer Database value. Database/Create.hs, Broker/Create.hs, Env/Store.hs, App.hs, Task/Run.hs, Task/Delete.hs, Storage/Snapshot.hs, and Storage/Restore.hs contain independent mutations. Worker/Deploy.hs, Static/Deploy.hs, Server/Deploy.hs, and app/Main.hs supply additional deployment paths.

Access/Resolve.hs writes shared auth backend configuration and shomei settings. Cluster/Namespace.hs applies namespaces from multiple callers. Cdn/Provision.hs and Cdn/Cloudflare.hs mutate DNS/CDN resources, so application scopes are not exclusively Kubernetes scopes. Broker/Topic.hs manages logical Kafka topics through rpk. App/Deployments.hs writes release metadata. These resources all belong in declarations or reviewed operations.

[ADR 20](../adr/0020-domain-routing-and-tls-ownership-are-explicit.md) protects hostname claims and separate TLS readiness. [ADR 4](../adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md) excludes private material from payloads. [ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) establishes independent scopes and delegation. Preserve [ADR 9](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md) for application cloud mutations.


## Plan of Work

### M1 — Application and standalone declarations

Add cli/nagarectl/src/Nagare/Inventory/Application.hs and DataService.hs, backed by pure builders in cli/nagare-dsl/src/Nagare/Resource/Application.hs and Broker.hs. Reuse Resource/Database.hs from EP-147. Feed the full validated application/database/broker values through these builders; eliminate alternate flag reconstruction.

Give each independently deployed application a stable ScopeId. Standalone databases/brokers have their own scopes; application-owned data may be in the application's scope but is retained separately when the application retires. Referencing a platform database does not grant lifecycle ownership. ResourceId is stable across display-name or provider-name changes, with physical replacement recorded separately. That stability has to be built: mint each ResourceId from the scope, a stable logical key, and the builder's role path, following EP-144. Add the optional logical key to the user-facing Deployment, broker, and volume values and their Config/Load wire forms; it defaults to the first declared name and is pinned explicitly to rename. A changed key is a new resource, and only EP-149's reviewed migration turns a rename into anything else.

Compile workload manifests, routes, access contributions, schedules, one-shot Jobs, volumes, backup policy, credentials, image references, logical broker topics, and release metadata. Revisions record immutable compiled declarations plus source/config digest and explicit overrides, so reconstituting context intent does not require every application's source checkout to be available. Compilation cannot infer complete desired state from a partial live resource listing.

Make render/dry-run and live deploy consume the same ResourceBundle. Public rendering shows secret references or redacted placeholders, never reusable passwords. An unsafe low-level rendering API may exist only inside the private execution adapter and cannot feed public review.

### M2 — Contributions, durable input channels, and publication

Model configuration, separately submitted environment variables, secret references, and temporary preview overlays as explicit intent inputs with documented precedence. A deploy omitting an env key from its own input channel does not erase a separately managed env channel. Explicit removal changes that channel's revision. Secret rotations bind opaque version tokens and private access paths; unknown reads refuse instead of regenerating credentials.

Submit namespace/certificate registration and auth backend/domain requests to EP-147's designated owners. The owner validates each contribution and composes the complete shared object. A shared resource's effective digest is the digest of its composed content, as EP-144 and EP-147 define it; an application transaction can execute only the derived change its contribution authorizes, and a redeploy whose contribution is unchanged does not touch the shared object. The platform's base scope revision and release pin do not advance. Reject a forged contribution requesting arbitrary shared-object fields.

Use EP-146 publication adapters for OCI images and assets. Move existing CDN/DNS decisions into Inventory/Adapters/Cdn.hs using explicit provider accounts/zones and canonical address claims. Provider configuration remains context/scope-bound. Where a resource is already owned by Pulumi/platform, applications contribute/reference it rather than mutate it through a second API. Cloudflare-managed application records have explicit separate ownership and observed physical identity.

### M3 — Operational actions and data safety

Route deploy/preview create/delete, restart/stop/delete, worker/server/site variants, database and broker create/delete/restart, topic creation, task run/delete, job submission, env/secret writes, snapshot/backup/restore/pruning, and access/CDN changes through the shared command service. Read-only list/get/log/inspect commands remain read-only and use typed observations.

Operational actions such as restart or backup are journaled against the accepted scope revision; they do not rewrite desired declarations unnecessarily. A manual Job has a stable operation identity and execution incarnation, so retry cannot accidentally submit duplicate work. A backup includes logical backup identity, storage object address, source data identity, expiry policy, verification, and restore dependency. Pruning uses lifecycle proof, not a broad prefix deletion.

Preserve the existing app-stop contract in App.hs explicitly: stop records a desired operational override making the Knative service cluster-local, and ordinary convergence/resume preserves it. An explicit deploy or restart clears that override as today's commands do; review displays that change. When restart clears a stopped override it is therefore a scope intent update as well as an operational action. Test stop followed by reconciliation, interrupted resume, explicit deploy, and explicit restart so the new engine neither unexpectedly exposes a stopped app nor leaves an explicitly restarted app stopped.

A restore is a data-changing operation with write-fencing, backup selection, target identity, verification, and explicit forward-recovery requirements. Ordinary resource update cannot masquerade as restore. Retiring an app preserves durable volumes/databases/brokers and the credentials/keys needed for recovery. Delete interfaces invoke EP-149's retained-resource policy; retained records stay visible after their original scope is retired.

Audit runHooks, interactive database shells, exec-like maintenance, and user-supplied migration commands. Hooks must declare their affected resource set and recovery semantics or refuse in managed execution. Interactive maintenance receives an explicit scoped session receipt, excludes concurrent managed mutation, and triggers re-observation afterward; Nagare must not claim its contents were statically planned or that unknown schema changes can be automatically rolled back. Credential extraction/public diagnostic paths remain redacted.

### M4 — User surface and removal

Keep existing command names where practical, adding review output and saved-plan use behind a shared Inventory.Command service. Application commands observe only what EP-145's observationRequirements names for the selected scope, so a deploy needs cluster access and not cloud or Pulumi credentials. They do need the context's inventory store. With the local store that is one workstation's private directory, so a deploy from any other machine refuses. [EP-151](151-store-inventory-history-in-the-context-state-bucket-with-conditional-writes.md) lets a cloud context keep the store in its state bucket instead. It is a soft dependency of this plan: M1 through M3 do not need it, but do not remove the last legacy deploy path in this milestone until EP-151 is Complete, and state the store requirement plainly in the user documentation either way. Standard non-destructive commands may prepare/display/apply their exact plan in one invocation under existing acknowledgement conventions; adoption, replacement, data restore, and deletion still need their explicit reviewed decisions. A generic --yes must never bypass a refused policy.

Refactor App/Deploy.hs and Nagare.Deploy so there is one declaration path and one internal guarded adapter path. Replace direct kubectl/gcloud/rpk/storage mutations in the command modules with typed operation requests. Do not create a parallel application journal. The developer package must include the pure model and command support it uses, while platform-only tooling remains in the operator package.

Extend docs/architecture/managed-resource-coverage.md and existing user docs for apps, databases, brokers, env/secrets, tasks/jobs, backups, and storage. Follow the repository's user-documentation profile and log requirements when implementation edits those documents. Keep only the provider-boundary scripts that perform unique work; remove shell/pure tests that merely duplicate the new authoritative model after equivalent assertions pass.


## Concrete Steps

Run from the repository root with its development environment. Add InventoryApplicationSpec.hs and InventoryDataServiceSpec.hs to cli/nagarectl/test and ResourceApplicationSpec.hs/ResourceBrokerSpec.hs to cli/nagare-dsl/test.

```bash
(cd cli/nagare-dsl && cabal test nagare-dsl-test --test-show-details=direct)
(cd cli/nagarectl && cabal test nagarectl-test --test-show-details=direct)
bash scripts/check-haskell-style.sh
```

Extend the existing AppDeploySpec.hs, AccessResolveSpec.hs, DomainBindingSpec.hs, and golden fixtures. Test commands must run against isolated temporary state and recording adapters. The separate EP-150 local/cloud scenarios validate actual provider integration.


## Validation and Acceptance

Compose platform plus two applications, then deploy only app A. Platform base revisions, app B declarations, and unrelated resource identities remain unchanged. Authorized shared backend contributions from both apps survive. An app cannot claim the platform's database or another app's Service/hostname, even if the native provider would accept the write.

Review/execution membership matches for a multi-workload application with database, backup, broker topic, schedule, preview, CDN, and secret references. A retained database's full retention/resources values survive compilation. Permission failure reading a password never generates a replacement. Secret canaries do not appear in text/JSON dry-run, errors, or exported evidence.

An interrupted one-shot Job does not submit again without recovery proof. Restore refuses the wrong data incarnation. Removing an application retains its durable data/recovery credentials unless a separately reviewed deletion policy permits retirement. Env updates survive a later config deployment. Commands fail safely when authoritative scope history is absent, rather than adopting by labels.


## Idempotence and Recovery

Every command records a scope replacement or operation against an exact base revision. Retry consumes the same saved review and operation identity. A changed input requires a new review. Legacy objects require EP-149 adoption. Do not erase earlier history when converting release-log ConfigMaps or env stores into the new model; preserve private backups and explicit import provenance.


## Interfaces and Dependencies

```haskell
compileApplication
  :: ApplicationIntent -> DependencyExports
  -> Either (NonEmpty InventoryError) ScopeDeclaration

compileDataService
  :: DataServiceIntent -> DependencyExports
  -> Either (NonEmpty InventoryError) ScopeDeclaration

planOperationalAction
  :: OwnedResourceSet -> OperationalAction -> ObservationSet
  -> Either (NonEmpty PlanError) ChangeProposal
```

DependencyExports contains typed capability witnesses and selected revision/physical bindings; raw names are not ownership authority. Command handlers submit intents through Inventory.Store/Plan/Execute. Resource and executor interfaces are owned by EP-144/145; Kubernetes/shared contributions/database declarations by EP-147; publication by EP-146; lifecycle proof by EP-149. No external library version changes are specified. Use Mori for dependency source discovery and never search/read /nix/store.


## Revision Notes

2026-09-16: Recorded EP-151 as a soft dependency that gates only M4's removal of the last legacy deploy path, after the operator added the shared store as the eighth child.

2026-09-16: Cascaded from the MasterPlan's pre-implementation API validation. ResourceIds are minted from a stable logical key carried in the user-facing values; shared-resource digests follow composed content; application commands use observationRequirements; and the machine-local store's effect on application deploys is stated as a release constraint. The reasons are rename safety, no-op convergence, keeping deploys free of cloud credentials, and ADR 13's new-machine promise.
