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
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-24T16:33:40Z
      mode: "implement"
      note: "Guard complete database and broker renderer membership"
---

# Route application and data lifecycles through independent resource scopes

This ExecPlan is a living document. Keep its living sections current and promote durable decisions into docs/adr/.


## Purpose / Big Picture

Application, database, broker, environment, storage, and task commands participate in the same ownership protocol without becoming part of a platform release. Updating one application preserves other applications and platform intent. Review includes all resources that execution will create, including helper-created credentials and backups.

Every supported application-side mutation is either a desired-scope update, a reviewed operational action against owned resources, or an explicitly declared controller delegation. There is no independent imperative path that silently changes ownership.


## Progress

- [x] (2026-09-24) M1 partial: Application, Deployment, Broker, and Volume carry optional validated logical keys through config emission/loading; stable scope/resource-ID helpers and a complete standalone database scope compiler are covered by DSL and operator tests.
- [x] (2026-09-24) M1 partial: App dry-run/JSON rendering includes the database credential template and retained backup CronJob; the Secret contains no password data.
- [x] (2026-09-24) M1 partial: Application-owned databases compile from their full typed values into the application scope with five canonical native members and explicit recovery intent.
- [x] (2026-09-24) M1 partial: A simple application Knative Service compiles from its label-stamped render into one digest-bound native declaration with namespace/image ordering.
- [x] (2026-09-24) M1 partial: Service PVCs compile as separate native members with explicit durable recovery or throwaway policy, and the service waits on them.
- [x] (2026-09-24) M1 partial: Automatic-TLS DomainMappings compile as distinct native members with exact hostname claims and service ordering; supplied TLS refuses pending a typed Secret dependency.
- [x] (2026-09-24) M1 partial: Workers have optional stable logical keys and compile as independently identified Deployment/PVC members in the application scope, with namespace/image/PVC ordering and explicit recovery for retained PVCs.
- [x] (2026-09-24) M1 partial: Application services and workers now order after their declared database StatefulSets; broker bindings refuse until their typed dependencies exist.
- [x] (2026-09-24) M1 partial: Scheduled task CronJobs compile from the same resolved preview bytes and carry optional stable logical keys; invoking a migration hook remains outside this declaration-only step.
- [x] (2026-09-24) M1 partial: The supported multi-workload fixture composes five database members, a service, three workers, and a scheduled CronJob into one scope with ten native members; cross-component ID/address collisions and unsupported fields refuse compilation.
- [x] (2026-09-24) M1 partial: A Redpanda broker without topics compiles its retained PVC, Service, and StatefulSet into an independent scope with exact native bytes; declared topics refuse pending logical operation ownership.
- [x] (2026-09-24) M1 partial: Aggregate compilation refuses rollout environment drift and environment Secret references without typed ownership or external dependency evidence.
- [x] (2026-09-24) M4 partial: Legacy app deploy and broker create refuse inventory transaction re-entry, matching the database create guard, while their public command paths remain active.
- [x] (2026-09-24) M1 partial: Database and broker scope builders refuse renderer membership changes before role-to-object binding; 450 DSL tests, 769 operator tests, and the Haskell style check pass.
- [x] (2026-09-24) M1 partial: Database native binding verifies the complete declaration-ID set and refuses duplicate or missing private members instead of accepting a lossy map.
- [x] (2026-09-24) M2 partial: Application scopes can submit an explicit namespace contribution bound to their namespace dependency ID. Composition accepts a granted custom namespace without advancing the platform scope revision and refuses an ungranted request; operator tests pass.
- [x] (2026-09-24) M1 partial: A standalone web Service now compiles under its own scope through the same native service/PVC/domain binder as an application Service. Unsupported database, broker, hook, access, and CDN inputs still refuse.
- [x] (2026-09-24) M1 partial: DomainMapping declarations accept an optional stable logical key through config emission/loading; a pinned key retains the ResourceId across a hostname change, which still requires EP-149 review before execution.
- [x] (2026-09-24) M1 partial: Supplied-TLS DomainMappings require an exact typed Secret dependency at the same cluster, namespace, and name; missing, extra, wrong-address, and observed-child bindings refuse. The DomainMapping waits on the bound Secret ResourceId.
- [x] (2026-09-24) M1/M2 partial: Runtime Secret-backed application env now requires an exact typed Secret declaration at the same cluster/namespace/name, and service, worker, and task members depend on its ResourceId. Build and preview Secret scopes still refuse pending separate intent channels and publication policy.
- [x] (2026-09-24) M1/M2 partial: Application database credential declarations can satisfy runtime Secret env references inside the same scope without a second external binding. An external binding for the same Secret name refuses, and the consuming workloads depend on the credential ResourceId.
- [x] (2026-09-24) M4 partial: An offline context with platform plus two application scopes preserves the unselected platform/application declarations and generations when replacing one application; a duplicate Knative Service claim across applications refuses composition. This is compiler isolation, not migrated command execution.
- [x] (2026-09-24) M3 partial: `db create --save-plan` compiles the same validated typed database used by direct create into a standalone scope, requires explicit recovery inputs, and saves an opaque inventory review for `inventory apply`; direct create remains a compatibility path.
- [x] (2026-09-24) M3 partial: `broker create --save-plan` compiles a topic-free Redpanda broker into its standalone scope and saves an inventory review. The StatefulSet renderer now includes the discovery metadata previously added by a post-apply `kubectl annotate` call.
- [x] (2026-09-24) M3 partial: `db retire --save-plan` and `broker retire --save-plan` select an accepted standalone scope, verify the named StatefulSet and namespace, and save a retirement review that retains every provider resource. Direct delete remains a compatibility path; reviewed native deletion is still open.
- [x] (2026-09-24) M4 partial: Legacy direct database and broker delete refuse inventory transaction re-entry before observing or mutating the cluster, matching their create guards.
- [x] (2026-09-24) M4 partial: Legacy database and broker delete inspect accepted and retained inventory ownership before provider observation and refuse a directly owned StatefulSet.
- [x] (2026-09-24) M4 partial: Legacy database and broker create also inspect accepted and retained inventory ownership before direct mutation; exact native namespace/name matching has focused tests.
- [x] (2026-09-24) M4 partial: Legacy database backup/restore and application storage snapshot/restore also refuse inventory transaction re-entry before provider observation or mutation; their reviewed operation contracts remain open.
- [x] (2026-09-24) M4 partial: Legacy task run/delete and database/broker restart reject inventory transaction re-entry before direct mutations; reviewed operational actions remain open.
- [x] (2026-09-24) M3 partial: Standalone data planners resolve the accepted foundation Namespace by both ResourceId and native cluster/name address before compiling a create review; absent or unmatched foundation state refuses.
- [x] (2026-09-24) M3 partial: Reviewed database and broker creation require a supplied Config.hs value to match the positional engine/provider and name before scope planning.
- [x] (2026-09-24) M4 partial: Composing a complete application scope against a platform-owned database StatefulSet claim refuses the application, extending the two-application isolation fixture.
- [x] (2026-09-24) M4 partial: Direct `app deploy` checks the loaded aggregate's stable scope and native service, worker, database, and task addresses against accepted and retained inventory history before resolving runtime inputs or mutating a provider. Native Service matching has a focused test; the reviewed application command path remains open.
- [x] (2026-09-24) M4 partial: Direct `app restart`, `app stop`, and `app delete` refuse an accepted or retained Knative Service address before mutation. Legacy ownership checks now share one read-only, context-bound history loader; reviewed operational overrides and retirement still remain open.
- [x] (2026-09-24) M1/M4 partial: `app deploy --save-plan` compiles a Service/worker application from its loaded typed config and the same resolved rollout identity used by direct deploy. It requires an explicit tag and an accepted OCI publication with the exact tagged destination, then saves a revision-bound inventory review for `inventory apply`. Builds, databases, hooks, brokers, access, and inputs lacking reviewed recovery or dependency bindings refuse; direct deploy remains a compatibility path.
- [x] (2026-09-24) M4 partial: Legacy single-Service `deploy` and `worker deploy` now refuse native Knative Service or Deployment addresses held in accepted or retained inventory before image resolution or provider mutation. Reviewed variants of those commands remain open.
- [x] (2026-09-24) M3/M4 partial: Direct database shell, restart, backup, and restore, plus broker restart, now use the accepted/retained StatefulSet ownership guard before effectful work. Reviewed operations and scoped maintenance receipts remain open.
- [x] (2026-09-24) M3/M4 partial: Direct task run and delete refuse accepted or retained CronJob and run-history ConfigMap addresses before Job submission or deletion; the reviewed one-shot operation remains open.
- [ ] M1: Compile applications and standalone services into complete scopes.
- [ ] M2: Integrate shared-owner contributions, environment intent, and publication.
- [ ] M3: Route operational and data lifecycle commands through reviewed operations.
- [ ] M4: Remove duplicate render/apply paths and prove scope isolation.


## Surprises & Discoveries

2026-09-24: The existing database builder already binds all five retained-database members, including the credential template and backup CronJob, to canonical native bytes. Standalone and application database compilation now consume it without reconstructing database flags. The application preview used the old four-object render path; it now displays the data-free credential template and backup. The Knative Service, PVCs, and automatic-TLS domains bind to their rendered native bytes. Remaining workload declarations and command routing are open. Existing config literals must initialize the new optional keys explicitly because their records have strict fields.

2026-09-24: A service volume's existing PVC render stamped `nagare.dev/app` with the service name, which differed from the application aggregate's shared label. The aggregate stamper previously refused any preexisting differing label. It now replaces only the top-level app label before native binding; a retained PVC requires explicit recovery intent. This is why preview labeling and inventory compilation must consume the same rendered object.

2026-09-24: Automatic-TLS DomainMappings can join the same service bundle with a `Hostname` alias claim, so two scopes cannot silently route one hostname. A supplied TLS Secret is supported by the legacy renderer but lacks a typed resource/capability dependency in this component; compilation refuses that case until the dependency is supplied rather than assuming the namespace-local Secret is ready.

2026-09-24: The application loader sorts workers by name, so worker resource identity must derive from each worker's validated name or pinned logical key rather than list position. Each worker PVC uses a role that includes its worker key, preventing two workers' equal volume names from sharing a recovery grant.

2026-09-24: The current Task render describes a CronJob, while running a pre-deploy migration creates a separate Job with unknown data effects. The CronJob can be a native declaration now; managed hook execution still requires a reviewed operation with affected resources and recovery semantics.

2026-09-24: Component builders alone cannot establish a complete application review. `compileApplicationScope` now combines their declarations and retained native bytes, validates identities and provider claims across components, and refuses application broker/access plus service task/access/CDN fields until those ownership paths exist. This is a supported-subset scope builder, not a command cutover.

2026-09-24: The Redpanda renderer's direct Kubernetes membership is three objects. Broker topic creation currently happens later through `rpk`, so a broker with topics cannot be considered fully declared by those three objects; the standalone compiler refuses such input until the topic operation is reviewed.

2026-09-24: A co-located task can carry an `app` association that differs from the containing Application while the aggregate renderer still stamps the containing app's label. Aggregate validation now rejects that mismatch before declaration or preview.

2026-09-24: RolloutEnv is currently assembled outside the typed intent channel. Without a match check, its env map could inject values into native workload bytes that the Application did not declare. The supported-subset compiler now requires equality with the Application's env channel and refuses Secret references until a typed external or owned dependency is provided. Separately managed env inputs remain M2 work.

2026-09-24: The inventory executor marks subprocesses with `NAGARE_INVENTORY_TRANSACTION`; only the old database create command refused re-entry. App deploy and broker create now reject that marker before loading input or provider work, preventing an adapter from indirectly invoking a second imperative mutation path.

2026-09-24: Both the database and standalone broker builders paired roles with rendered objects using `zip`, which silently discards unmatched tail members. They now check the complete renderer cardinality first. This closes one path for a future renderer change to produce an unclaimed native member, but it does not establish command-path parity or finish M1.

2026-09-24: The database adapter bound each native member to a declaration but then built a `Map` without proving equal membership. A duplicate ID could collapse during that conversion. Binding now compares the exact declaration and native ID sets and counts before returning private execution bytes.

2026-09-24: The shared namespace composer already enforced owner grants, but the application scope compiler had no way to submit a request. An optional owner input now emits `RegisterNamespace` only after checking that its generated ID equals the Namespace ID used by application workloads. An offline composed candidate proves that the platform's accepted scope revision remains fixed, and missing grants refuse. Application command construction and other shared contributions remain open.

2026-09-24: The application Service binder already bound exact rendered bytes for Service, PVC, and DomainMapping members, but it minted IDs in an application scope. Extracting its member binder lets a standalone Service use the same declaration path with its own stable scope. The wrapper requires matching rollout identity and no undeclared shared app environment; it still has no public command cutover.

2026-09-24: DomainMapping IDs previously derived only from the hostname, so a hostname change could not preserve logical identity even when the operator intended a reviewed migration. DomainSpec now carries an optional logical key in config JSON. The unpinned path keeps the previous hostname-derived ID; pinning a key retains the ID, while EP-149 must still authorize any changed provider address.

2026-09-24: Composing a platform scope and two simple application scopes confirmed the existing omission rule at the application boundary: replacing one app leaves the other app and platform at their accepted generations. Giving the changed app the other app's Knative Service name fails the shared address claim check. This validates the compiler's isolation behavior but does not exercise legacy deploy command migration.

2026-09-24: The standalone database builder was adapter-ready but had no public reviewed entry point. `db create --save-plan` now shares the typed input resolver with direct create and composes one standalone scope against accepted context history. The command requires explicit recovery policy and credential key version; composition refuses missing platform dependencies. Applying the saved review is a separate `inventory apply --yes` step. This is a first routed path, not full operational-command migration.

2026-09-24: Broker and database renderers omitted discovery annotations and their direct create paths stamped them after applying the StatefulSet. Reviewed execution cannot perform an unreviewed follow-up annotation, so both renderers now include the annotations in the StatefulSet object. Direct create uses those same bytes and no longer issues separate annotations. Topics still refuse reviewed broker planning because they require typed logical operations.

2026-09-24: The generic retirement planner loads immutable accepted native evidence and `RetireScope RetainResources` performs no provider deletion. The domain retire commands use it only after proving that the selected standalone scope contains exactly one matching StatefulSet in the requested namespace. An explicit scope key handles a pinned logical identity after a display-name rename; missing or mismatched accepted scopes refuse before review publication. Reviewed native deletion requires a separate collection capability and remains open.

2026-09-24: The platform-database isolation fixture exposed a generic inventory claim gap: `validateGraph` indexed only managed declarations when checking provider-address collisions. External declarations already had canonical claims but were omitted from this map. Including them makes a platform external database address unavailable to an application-managed StatefulSet. Observed controller children remain excluded because they intentionally inhabit their parent's derived reservation.

2026-09-24: Supplied TLS rendering already carried the Secret name in the DomainMapping but the inventory builder refused the entire case. The builder now takes the exact managed or external Secret declaration, checks its cluster/namespace/name address, and adds its ResourceId as a dependency. It rejects unused bindings and observed children. Command routing still must source that declaration from accepted history; a caller-supplied name alone is not authority.

2026-09-24: Secret-backed runtime env has the same authority gap as supplied TLS. The application compiler now accepts exact typed Secret bindings and adds dependencies to every workload that inherits or declares the reference. It still refuses build and preview Secret scopes because Kubernetes runtime readiness cannot prove build-time secret publication or preview-overlay intent. Command routing must obtain bindings from accepted history, not caller-provided names.

2026-09-24: The application database compiler already supplies a password-free credential Secret in the same candidate. Runtime env references to that Secret now use the owned declaration directly; external Secret bindings are required only for names not owned by the application. This preserves the distinction between application-owned credential lifecycle and an accepted Secret in another scope.

## Decision Log

2026-09-16: Preserve separately submitted environment/secret intent across configuration deploys. Inputs are explicit versioned intent channels composed into one owner declaration, not live cluster data silently copied into desired state.

2026-09-16: App-only deployments can update their authorized contribution to shared routing configuration, but cannot replace the platform-owned resource or advance the platform release.

2026-09-16: Interactive administrative shells cannot be represented as read-only commands. Journal a scoped maintenance session with bounded resource authority and re-observe afterward; arbitrary SQL effects remain explicitly unknown until reconciled.

2026-09-24: Give the Application aggregate an optional logical key as well as its contained resources. The aggregate owns the ScopeId, so a display-name change needs a pinned scope key to retain accepted history; absent a key, the current name remains the backward-compatible default. This is an extension of ADR 22's resource identity rule.

2026-09-24: Require an explicit owner scope for application namespace contributions and bind the request to the exact Namespace ResourceId used by its workloads. Rationale: a custom namespace belongs to the shared owner, while an application may also consume an existing Namespace without requesting a new one; neither case grants the application lifecycle ownership of the Namespace.


## Outcomes & Retrospective

In progress. Stable identity inputs, standalone database and topic-free broker scopes, and a supported-subset application scope compiler are present. Application broker/access/CDN/TLS integration, reviewed operational actions, command migration, scope-isolation proof, and complete mutation coverage remain open.


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
