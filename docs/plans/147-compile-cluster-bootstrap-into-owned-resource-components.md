---
id: 147
slug: compile-cluster-bootstrap-into-owned-resource-components
title: "Compile cluster bootstrap into owned resource components"
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
      at: 2026-09-22T18:29:14Z
      mode: "implement"
      note: "Begin typed Kubernetes component declarations"
---

# Compile cluster bootstrap into owned resource components

This ExecPlan is a living document. Keep its living sections current and promote durable decisions into docs/adr/.


## Purpose / Big Picture

An operator can inspect every directly managed cluster bootstrap resource before applying anything, detect two components claiming the same object, and resume from verified components instead of replaying the whole bootstrap. The Attic/database collision becomes a hermetic compiler test. Secret material never appears in public review output.

A component is an independently identified group of resources and operations, such as the cache database or ingress controller. Kubernetes and Helm remain native executors; generated Pods and operator descendants remain delegated children.


## Progress

- [x] (2026-09-22) M1a: Compile structured Kubernetes objects to typed declarations with controller reservations; the database Service/Knative collision and malformed Certificate fixtures pass (426 DSL tests).
- [ ] M1b: Add multi-document/List expansion, canonical native-byte binding, and guarded observation/apply adapters.
- [ ] M2: Compile cache and managed database resources from one declaration path.
- [ ] M3: Compile remaining cloud/local bootstrap and shared-owner contributions.
- [ ] M4: Replace bootstrap orchestration, prove parity, and test component resume.


## Surprises & Discoveries

2026-09-22: EP-144 already implemented the controller reservation rules in `Nagare.Resource.Inventory`, but no compiler consumed structured Kubernetes objects. `Nagare.Resource.Kubernetes.compileKubernetesObject` now derives the correct specialized specification from an object. The existing database renderer golden Service collides with a same-name Knative Service through this compiler, proving the reservation check operates on rendered shapes. The module is pure; native-byte retention, observation, and execution remain M1b.


## Decision Log

2026-09-16: Make namespace and shared configuration owners explicit. Consumers submit typed contributions instead of independently applying the same Namespace or whole ConfigMap.

2026-09-16: Represent credential rotation and operator-generated children as bounded delegated maintenance. Legitimate rotation is not configuration drift to undo.

2026-09-16: Known migration Jobs have durable operation identities bound to inputs. Unconditional delete-and-recreate on every bootstrap is removed.

2026-09-16: Kubernetes claims include derived reservations for controller children, and shared-resource digests follow composed content. Verified in the tree that a database Service is named after the database while applications are Knative Services, so direct claims alone miss a same-name collision.

2026-09-22: Take the content digest as an explicit compiler input and return the structured declaration. Rationale: `nagare-dsl` remains free of hashing and execution dependencies, while a later adapter must retain and verify the native bytes that digest names.


## Outcomes & Retrospective

Not implemented. Record rendered-resource parity, secret handling, and resume evidence at completion.


## Context and Orientation

Hard dependencies are [typed inventory](144-define-typed-resource-scopes-and-validate-composed-inventories.md) and [durable execution](145-persist-reviewed-resource-plans-and-resumable-execution-receipts.md). They define provider addresses, ResourceId independent of owner/name, typed outputs, complete selected scopes, opaque reviewed plans, and the Adapter/Journal interfaces. [Cloud/host/artifact adapters](146-reconcile-cloud-host-and-artifact-resources-through-inventory-adapters.md) are a soft dependency: fixtures provide typed outputs, while integrated cloud execution waits for EP-150. This plan owns the Kubernetes and Helm adapters consumed by application work.

[Lifecycle policy](149-explain-drift-and-execute-reviewed-adoption-migration-and-retirement.md) is also a soft integration dependency. Fresh bootstrap and declared native schema-migration operations can be tested here; generic legacy adoption, cross-owner data migration, and retirement stay gated until lifecycle proof and native preconditions are combined.

justfile cluster-bootstrap/local-bootstrap currently applies external manifests, patches configuration, invokes installers, and stamps completion. cluster/bootstrap/nix-cache/install.sh publishes an image, creates credentials/namespaces/database, runs Jobs, configures an Attic logical cache, and publishes its generated public key. Database/Create.hs adds a Secret and backup CronJob beyond Dsl/Database/Render.hs output. cluster/bootstrap/auth-install.sh and local-auth/install.sh orchestrate auth services. cluster/observability/install.sh manages Helm releases plus credentials/configuration. Cluster/Namespace.hs ensures shared namespaces. nixos/hosts/nagare-01/registries.nix and forge-credentials-refresh.sh rotate cluster credentials.

[ADR 4](../adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md) excludes credentials from payloads. [ADR 18](../adr/0018-the-upgrade-transaction-is-as-guarded-as-the-recipes-it-replaces.md) preserves retained certificate migration evidence. [ADR 20](../adr/0020-domain-routing-and-tls-ownership-are-explicit.md) separates route and certificate owners. [ADR 21](../adr/0021-nagare-owns-an-optional-context-local-nix-cache-provider.md) makes cache disable non-destructive and PostgreSQL the signing-identity recovery boundary. [ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) governs scope composition and delegation.

New modules are cli/nagare-dsl/src/Nagare/Resource/Kubernetes.hs and Database.hs; cli/nagarectl/src/Nagare/Inventory/Bootstrap.hs, Components/{Foundation,Cache,Auth,Observability,Local}.hs, and Adapters/{Kubernetes,Helm,Cache}.hs. EP-147 owns the reusable complete database declaration builder; EP-148 consumes it instead of copying it.


## Plan of Work

### M1 — Cluster adapter and identity

Compile structured Kubernetes objects into declarations and exact canonical manifests together. Treat packaged YAML/chart renderings as versioned inputs parsed into structured objects, not shell text substitutions. Expand multi-document YAML and List objects before validation; preserve source/component provenance for each resource. Include cluster-scoped objects and normalize API-version aliases to the same address. Native manifests must not introduce resources after inventory validation.

Fill in EP-144's per-kind claim function for Kubernetes here. Beside each object's direct claim it must return derived reservations for the deterministically named children a controller will create: a Knative Service reserves the core Service of the same name, a Certificate its target Secret, a StatefulSet its ordinal Pods and template claims, and a Helm release its rendered objects. Children with generated names, such as a CronJob's Jobs or a Revision's Pods, need no reservation and are observed through their parent. The case is live in this repository: Nagare.Dsl.Database.Render sets `dbServiceName n = n` and applications are Knative Services, so an application and a database sharing a name in one namespace contend for one core Service although their declared kinds differ. Add that pair as a failing fixture next to the Attic one.

Observe using explicit cluster identity/credentials and separate confirmed absence, permission/network failure, malformed response, foreign/unowned identity, owned drift, and health. Stamp owner, context, and logical ID in the same guarded write as desired changes. If a desired revision is stamped, use the object's own spec digest computed without the stamps, never the scope revision, which would rewrite every object in the scope on every deploy. Kubernetes UID records physical incarnation; deletion and adoption use UID/resource-version preconditions where supported. Create conflicts re-enter observation instead of overwriting an unexpected object. An ownership check followed by unrestricted apply is not sufficient: select a provider update strategy that preserves preconditions and refuses field-manager conflicts. Do not use force-conflicts as an adoption shortcut.

Native server defaulting/status/generated metadata must be excluded from desired comparison by a typed per-kind projection. Explicitly delegated credential fields and controller-owned fields are compared according to their contract. If a safe mutation precondition is unsupported, refuse the operation rather than pretending a label is a lock. Preserve cluster/context guards at the mutation site.

### M2 — Complete cache/database composition

Extract one pure database builder accepting the full Database value, owner scope, logical identity, namespace reference, credential reference, and backup policy. Return PVC, Service, StatefulSet, optional ConfigMap, credential lifecycle declaration, backup CronJob, required access policy, and output references. Preserve retention/resources rather than reconstructing CLI flags. Rendering and live execution consume this exact bundle.

Compile the cache into database, credential/configuration, schema migration, workload, logical Attic cache, network policy, and client-public-key operations. The PostgreSQL Service and Attic Service receive distinct stable IDs and addresses; reproduce the old equal-address configuration as a failing fixture. The signing public key is a declared output of the logical cache operation and a typed input to the client ConfigMap. It cannot be fabricated during offline rendering.

Bind config-check and schema migration Jobs to immutable image/config/database identities and durable operation IDs. Completed migration proof remains valid even if Kubernetes TTL removes a Job; incomplete/ambiguous migration needs a database-specific recovery check. Do not rerun because a Job object is absent. Mark forward-only migrations accordingly and preserve recovery backups/credential references.

Replace password-read behavior that generates a new value for every failed get. Generate once only after confirmed absence under the reviewed credential-creation operation. Unknown or malformed reads refuse, and generated plaintext is private transient adapter input. Review/dry-run must not print actual Secret.data, tokens, DSNs, or private native bundles.

### M3 — Remaining components and delegation

Compile cloud/local foundations, cert-manager/issuers, Knative, Kourier, net-certmanager, TLS configuration, application namespace policy, job quotas, auth services/migrations, observability Helm releases, and local MinIO/bucket setup. Pin and retain exact external manifest/chart bytes and values in the payload or reviewed private bundle before mutation. A mutable URL fetched again during apply is not acceptable evidence. Include Helm hooks and release metadata in the operation contract; rendered direct objects must match executor membership, while operator-generated descendants are explicitly delegated.

Prove the Helm rendering boundary itself: separate template and upgrade invocations can differ because of live lookup, randomness, or conditional hooks. The adapter must enforce the retained reviewed manifests through a verified native rendering boundary, or reject unsupported nondeterministic charts before mutation. Bind chart, values, capabilities, hook policy, and rendered object digests. A second unverified rendering is not evidence of parity. Add a chart fixture whose lookup/random output differs between review and apply and prove refusal before resource changes.

Create a foundation-owned namespace registration API. The foundation composes requested namespace/certificate labels; consumers cannot overwrite arbitrary labels. Define the shared-owner contribution mechanism for auth backend/routes and shomei settings: application scopes own contributions, platform owners own resulting shared resources. Effective resource digests cover the complete set of contributions, while the platform's base declaration revision remains unchanged. Validate contributor permissions and conflicts before review. Execution locks/revalidates the entire contribution vector to avoid lost entries. The contribution kinds and their pure composers are added to EP-144's closed dispatch in nagare-dsl, because composeInventory must derive contribution-made declarations, such as a registered Namespace, before it validates claims; a composer living only in nagarectl would run after validation. The effective digest of a shared resource is the digest of its composed content. It does not include the revisions of contributing scopes, so an application redeployed with an unchanged contribution leaves the shared object untouched and other reviews valid.

Declare host timer authority over registry/forge credential values and ServiceAccount imagePullSecrets, without granting deletion/adoption. Include the expected namespace set and credential version/freshness evidence. Certificate Secrets, Knative Revisions/Pods, and observability operator children are observed descendants; direct declarations do not compete with their controllers.

Bootstrap's final version stamp becomes a control operation gated by all required component verification. Do not stamp success merely after one installer returned zero. EP-150 integrates context commit.

### M4 — Replacement of orchestration

Expose `nagarectl platform bootstrap plan --out DIRECTORY` and `platform bootstrap apply DIRECTORY --yes` as thin uses of inventory compile/plan/apply. Existing just recipes and installer entry points call those commands and cannot directly mutate around them. Adapters never call those entry points back: the context lock is held while an adapter runs, and EP-145 makes an inventory command refuse when it finds itself inside a transaction. Move decisions from cache/auth/local-auth/observability installers, namespace loops, TLS recipes, and retry/config-patch scripts into typed components/adapters. Retain unique transport/image import/dump operations only with typed inputs/results.

Add a complete fixture for cloud bootstrap with cache/auth/observability enabled and a local-mode counterpart. Maintain docs/architecture/managed-resource-coverage.md with direct resources, delegated outputs, policy owners, retired scripts, and the tests covering each entry point. If this plan runs before EP-146, create the same agreed file with its cluster entries and preserve later additions; its shared format is defined in the MasterPlan.


## Concrete Steps

Run from repository root with the development toolchain. New test modules are ResourceKubernetesSpec.hs in nagare-dsl and InventoryBootstrapSpec.hs/InventoryKubernetesSpec.hs in nagarectl.

```bash
(cd cli/nagare-dsl && cabal test nagare-dsl-test --test-show-details=direct)
(cd cli/nagarectl && cabal test nagarectl-test --test-show-details=direct)
bash scripts/test-knative-bootstrap-readiness.sh
bash scripts/test-cluster-certificate-policy.sh
bash nix/checks/scripts/nix-cache-bootstrap-assets.sh
```

Preserve existing boundary tests while adapting their expected command path. For live Kubernetes acceptance, use a separately created disposable local context; the integrated cloud rehearsal is EP-150. Never run these scenarios against the ambient default context.


## Validation and Acceptance

Recording adapters show every effect is covered by the reviewed resource/operation set, including helper-created Secrets, backup Jobs, Helm hooks, and logical Attic state. The exact cache Service collision fails with zero mutation. Foreign/unowned objects require adoption; unknown reads do not generate secrets. Secret canaries do not appear in public JSON/text or failure logs.

Interrupt after database readiness and after migration success; resume does not recreate credentials or repeat proven migration. Input changes make the review stale. Disabling cache retains database, data volume, signing identity, and protected cloud references according to policy. Generated key resolution only fills its declared output slot. Local-mode bootstrap invokes no cloud tools.

Existing certificate migration evidence, context confinement, readiness ordering, and native controller ownership remain enforced. A failed component leaves the context pin unchanged and exposes precisely which components completed.


## Idempotence and Recovery

Component reruns consume identical reviewed inputs and reconcile through recorded identities. Unknown effects stop for adapter-specific recovery. No generic rollback undoes schema changes. Existing unowned installations remain inspectable but require EP-149 adoption before this protocol manages them. Do not remove old scripts until their replacement preserves the safety tests; keep one supported mutation path at completion.


## Interfaces and Dependencies

The reusable declaration entry points have these responsibilities:

```haskell
compileDatabase
  :: DatabaseDeclarationInputs
  -> Either (NonEmpty InventoryError) ResourceBundle

compileBootstrap
  :: BootstrapInputs
  -> Either (NonEmpty InventoryError) [ScopeDeclaration]

composeOwnerContributions
  :: OwnerPolicy -> [ValidatedContribution]
  -> Either (NonEmpty InventoryError) ResourceBundle
```

ResourceBundle, ScopeDeclaration, and the DeclaredOperation values inside a bundle are defined by EP-144 in nagare-dsl. A bundle carries declarations, typed exports, required conditions, contributions, and declared operations; it is not a list of executable commands. composeOwnerContributions is the pure composer that EP-144's composition phase dispatches to for the kinds this plan adds, which is why it lives in nagare-dsl beside Resource/Kubernetes.hs. compileDatabase takes the database's stable logical key as an input and mints ResourceIds from it rather than from the provider name; add the optional key to Nagare.Dsl.Database's Database so a rename in configuration is not mistaken for a new resource. Kubernetes/Helm/Cache adapters implement EP-145's registry protocol and cannot independently update desired-state heads. Dependency APIs must be located through Mori before use; no version changes are prescribed. Never search/read /nix/store.


## Revision Notes

2026-09-16: Cascaded from the MasterPlan's pre-implementation API validation. This plan now supplies the Kubernetes derived-reservation table for EP-144's claim function, with the application/database same-name fixture; stamps identity and per-object spec digest rather than scope revision; places contribution composers in EP-144's dispatch with content-based effective digests; mints database ResourceIds from a stable logical key; and forbids adapter re-entry. The reasons are a collision class the direct-claim model missed, no-op convergence, composition ordering, rename safety, and lock re-entrancy.
