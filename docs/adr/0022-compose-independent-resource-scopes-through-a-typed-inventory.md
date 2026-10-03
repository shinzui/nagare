---
title: "Compose independent resource scopes through a typed inventory"
status: accepted
date: 2026-09-16
authors: [shinzui]
related:
  - docs/improvement-requests/make-managed-resources-first-class.md
  - docs/masterplans/23-make-managed-resources-first-class-through-typed-scoped-inventories.md
  - docs/adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md
  - docs/adr/0018-the-upgrade-transaction-is-as-guarded-as-the-recipes-it-replaces.md
  - docs/adr/0021-nagare-owns-an-optional-context-local-nix-cache-provider.md
---

# ADR 22 — Compose independent resource scopes through a typed inventory

## Status

Accepted as the architecture for MasterPlan 23 on 2026-09-16 following the operator's design discussion. Implementation is not yet complete; the existing command behavior remains as described in the earlier ADRs until its migration is verified. The 2026-09-28 amendment defines the supported feature boundary; the 2026-10-02 prerelease-fixture amendment removes obsolete development-transaction compatibility obligations. Both supersede earlier requirements within their stated scope.

## Context

The Attic rehearsal exposed two components claiming the same Kubernetes Service. Independent reconcilers have no common ownership or lifecycle authority. A global inventory alone would not solve the problem if it were a handwritten mirror of scripts, and one global desired-state document could incorrectly couple application deployments to platform upgrades. The operator requires an explicit platform/application boundary and wants types and pure validation to replace duplicated shell policy.

## Decision

Each context has a stable identity and independently revised ownership scopes. Platform components, applications, and standalone data services declare complete desired state only for their own scopes. One composed context inventory checks address claims, resource identities, dependencies, and policy across those declarations. Omission outside the selected scopes never requests deletion. Platform and application releases remain independent. A coordinated migration may explicitly select several scopes.

A managed resource has one lifecycle owner. Consumers hold typed references to exported capabilities, not authority to replace or delete the provider. Shared resources have designated owners. Where consumers contribute routing or policy entries, the owner validates and composes those contributions into its resource. Delegated controllers have explicit field or operation authority; generated children are observed through their controlling resource, not adopted as independently managed declarations.

Desired declarations, live observations, and execution history are separate versioned records. Logical identity survives renames; provider addresses and observed physical incarnations are distinct. Provider address equality follows the provider's collision domain, not the owning context's display name. The local implementation checks its composed inventory and live target, but does not claim distributed exclusion across independent workstations.

Haskell owns the common domain contract. Smart constructors and explicit alternatives rule out structural errors. Pure validation proves graph properties and yields opaque validated values. Review and guarded execution similarly require evidence-bearing values; decoding JSON does not grant authority. Constructors, generic reconstruction, and writable optics must not bypass those boundaries. Raw credentials have no representation in the public review format. Native provider programs consume versioned declaration data and report their actual resource registrations so that tests can establish parity with inventory membership.

Every resource is declared before external mutation. Generated values are typed output references with declared producers, destinations, and constraints. They cannot add resource membership or silently broaden a reviewed operation. If a provider cannot plan until an output exists, a bounded preparation transaction is reviewed first and the dependent operation requires a subsequent review of its resolved native plan. Review is not permission for arbitrary later expansion.

Operations run at native executor boundaries: a Pulumi stack update, a guarded host activation, or a Kubernetes component reconciliation may cover several declared resources. Native saved plans, project and cluster guards, protected data policies, and host self-reversion remain authoritative safety layers. Readiness conditions and migration operations form an explicit execution graph. Intent precedes each external mutation and durable observed completion follows it. Ambiguous interruption stops automatic replay unless adapter evidence proves a safe resolution. Proven Pulumi completion remains skippable without a provider call; current health is reported separately.

For Kubernetes, a read followed by unrestricted apply is not a write precondition. A disposable ConfigMap probe found that server-side apply with `resourceVersion: "0"` can update an existing object, while create-only `kubectl create` records Update field ownership that conflicts with a later server-side apply of changed fields. The adapter must prove create-time absence and use API-server-enforced UID/resource-version conditions for updates while respecting field ownership. The per-kind native strategy remains an implementation decision; the ConfigMap probe does not establish one for all Kubernetes resources.

A second disposable ConfigMap probe confirmed that applying the same value after a create adds Apply co-ownership without releasing the create request's Update ownership; the next changed server-side apply still conflicts. The transport now checks the live managed-field set before allowing a forced transition from its own create manager to Apply ownership. It refuses when any non-status field has a foreign manager or managed fields are missing, and binds the apply to the observed UID/resourceVersion so a concurrent ownership change refuses at the API server. This was exercised for a ConfigMap; other kinds still require specific projection and live proof.

Service ports need a distinct transition. Kubernetes treats the port number as a merge key, so changing an unnamed port through server-side apply can temporarily produce two invalid unnamed entries. The adapter uses a JSON Patch with atomic UID/resourceVersion tests to replace only the reviewed port list and inventory digest, and refuses when other desired fields differ. A disposable Service proved selector and port updates; this does not authorize untested kinds or mixed field changes.

Generated database credentials are represented by a password-free Secret template with a stable logical identity. Its private reviewed bytes bind metadata and a generation marker. The adapter generates plaintext only at a guarded create-only mutation, stores it in Kubernetes, and verifies the expected key set without comparing delegated credential values to a fabricated review value. A credential observation that is absent or malformed never authorizes an overwrite of a present Secret.

The database's scheduled backup is a direct, named CronJob in the same bundle. Its native body depends on the selected storage backend, so the CLI supplies the structured result of the existing renderer to the pure database builder. The builder validates the expected address and orders the CronJob after the credential and StatefulSet before native bytes are retained for review.

Database retention is compiled from the typed `Database` value. A retained database protects its PVC and credential with recovery intent and includes the backup schedule; an explicitly throwaway database produces collectable stateless resources and no backup schedule. The executor cannot infer deletion from a missing scope member.

Resume must ask an adapter to recover an ambiguous effect before comparing that operation with its original preflight observation. A successful create with a lost acknowledgement makes the reviewed absence false, so repeating the old preflight would block proof and safe continuation. Completed and ambiguous operations bypass that comparison; known-no-effect retries still pass ordinary preflight.

The Attic signing public key is a distinct `NixCachePublicKey` capability in the inventory reference model. Client configuration must consume that typed output from the logical cache operation; an image or database connection cannot satisfy the reference merely by sharing a string key. Native output resolution remains to be implemented.

An Attic logical cache has its own provider address and executor. It is not a Kubernetes Service or Deployment claim: its state lives in the Attic database and must be reconciled and verified through the cache API. The command registry refuses this executor until its native adapter is available.

Initially, one operator state directory owns immutable snapshots, reviewed bundles, and an append-only operation journal with a context-wide writer lock and revision checks. State is private, backed up, and independent of release workspaces. A checksummed history provides integrity checks, not authentication against an actor who can rewrite the store. Loss of authoritative history enters recovery; names and labels alone cannot reconstruct deletion authority. Remote writers and continuous reconciliation require a later storage/coordination implementation of the same contract.

Release publication uses a distinct workflow-owned scope. Its ephemeral runner persists the reviewed publication binding atomically with creation of a provider draft release, retains exact asset/verification evidence there before publication, and recovers completion from the unchanged published object. Authorized same-tag workflows are serialized. This narrow provider recovery protocol is not a general remote context store; expiring CI artifacts are not authoritative history, and published legacy releases are not retroactively rewritten.

Adoption, ownership transfer, replacement, and retirement are reviewed transitions bound to observed physical identity. Durable data defaults to retention. Garbage collection requires ownership history, exact identity, resolved dependents, and an explicit deletion policy. Artifact retention considers all known consumers; release publication has its own scope rather than belonging to whichever deployment context first consumed it.

All supported Nagare mutation entry points eventually use this protocol. Pure decisions move from shell into typed modules; transport, host activation, and native provider tools may remain narrow adapters. Migration acceptance includes removal of superseded orchestration and policy implementations. No release claims complete inventory coverage while supported mutation paths remain unaccounted for.

## Consequences

Application deployments and platform upgrades can advance independently while detecting shared-resource conflicts. Existing installations need explicit adoption and old transactions need a versioned compatibility path; neither is inferred from matching names. The model enables deterministic tests for collision, lifecycle, and recovery policy, while real provider observations and integration tests remain necessary.

This does not introduce a daemon, distributed scheduler, generic replacement for Pulumi/NixOS/Kubernetes, automatic data rollback, or a security boundary against administrators using raw provider tools. Types reduce invalid internal states; they do not establish live ownership, permission, freshness, or successful external effects.

## Amendment — 2026-09-16: the shared interface was validated before implementation

The interface proposed by MasterPlan 23 was checked against the working tree and compiled as stubs
before any code was written. The architecture above is unchanged. Six rules came out of that check
that will outlive the plans.

1. **An address claim includes what a controller will create.** A declaration claims its own
   address and reserves the deterministically named children of its controller. Databases here
   name their Service after the database and applications are Knative Services, which create a core
   Service of the same name, so comparing declared addresses alone misses that collision. Claims
   held by retained incarnations and unresolved transactions are part of the validated snapshot.
2. **A validated inventory has one construction route.** Composition returns the desired inventory
   together with the base it was composed against and the explicit replace and retire changes.
   Stored scope documents are decoded and composed again; nothing decodes bytes directly into a
   validated inventory. This is what carries "omission never means deletion" across a file.
3. **Digests identify content and revisions identify history.** No digest is stored beside the
   inline content it digests, no revision enters a desired digest or provider metadata, and a shared
   resource's effective digest follows its composed content. Otherwise an unchanged rerun is not a
   no-op. The pure model stays free of a hashing dependency; one operator-side module derives every
   digest.
4. **Logical identity comes from a stable key, not the provider name.** A changed key is a new
   resource. Only a reviewed migration makes a rename anything else.
   An application scope may pin an explicit logical key before its display name changes;
   without one, its current declared name supplies the scope key. Deployment, worker, task, broker, and
   volume values follow the same optional-key rule for their resource identities.
5. **Authority to cause effects exists only under the writer lock.** A plan verified against a
   snapshot is evidence, not permission. Admission under the lock re-checks the head, reservations,
   and live preconditions, and yields a value that cannot leave that lock's scope. Native evidence
   is produced by an explicit adapter preparation step during planning. Adapters never re-enter a
   command that takes the lock.
6. **The store's correctness rests on conditional writes only.** Publish-if-absent,
   append-at-sequence, and replace-head-if-generation-matches are sufficient, and the transaction
   tests run against a store that has nothing else. The initial implementation was filesystem-only;
   the later object store uses the same contract and adds generation-conditional writes.

No type with a hidden constructor derives `Generic`, identity newtypes included: `GHC.Generics.to`
rebuilds such a value without naming its constructor. This is the narrow exception to
[ADR 16](0016-adopt-haskell-jitsurei-for-production-haskell.md)'s label convention that the
Decision above anticipated.

A cloud context may keep its inventory store in its state bucket, beside its Pulumi state. This
was decided the same day and is delivered by MasterPlan 23's eighth child,
[ExecPlan 151](../plans/151-store-inventory-history-in-the-context-state-bucket-with-conditional-writes.md).
Replicating a local store, or moving it by export and restore, lets two machines restore one history
and both apply, and the state at risk is deletion authority;
[ADR 13](0013-operator-deployment-material-lives-in-a-private-repository-with-remote-state.md) moved
the less critical Pulumi state off the workstation for the same reason. The shared store stays
narrow: one writer, refusal of a second machine through the head's conditional replacement, an
explicit operator takeover instead of a lease, and the filesystem store retained for local mode and
for a new context's first transaction. It does not detect whether another executor is alive.
ExecPlan 151 amends ADR 13 when the store exists.

## Amendment — 2026-09-23: shared-store implementation

The conditional-write contract supported a GCS object implementation without
changing the review or journal protocol. Each context prefix has a binding
object, immutable members, and a generation-guarded head. A local process
lock serializes writers on one workstation; a persistent client identity and
executor claim prevent another workstation from resuming silently. Takeover
is explicit and advances the claim epoch. Migration copies to an inactive
destination head, verifies the copy, tombstones the source head, then
activates the destination. An interrupted handoff can leave both stores
inactive until a verified retry completes it. The context selection changes
only after destination activation, so two histories cannot accept ownership
changes during migration.

## Amendment — 2026-09-22: the read-only foundation

EP-144 implements the pure model and `nagarectl inventory compile`. This does not
claim that existing mutating commands use inventory authority. The compiled bundle
stores each scope once under its SHA-256 identity; a member request retains the
complete base vector, reservation holders, and explicit replacements/retirements.
The manifest binds both this request and the desired content. Reopening verifies
all members and recomposes; JSON decoding never creates a validated inventory.
Generations are absent from desired identity and present in candidate identity.

Version-one canonical bytes are a protocol contract, pinned by scope and candidate
goldens. The encoder sorts object keys itself and normalizes unordered declaration
collections. The decoder rejects duplicate JSON keys before aeson discards them,
non-integer number tokens, unknown fields, and unsupported variants. Future readers
must retain the old canonical encoder for old member versions. Hashes provide
integrity, not authority against an actor who rewrites a complete candidate: EP-145
must bind its base to persisted history under admission.

The first contribution composer is owner-authorized namespace registration.
Requests for one namespace under one owner and cluster compose to one stable
owner-owned declaration. Generated Namespaces participate in ordinary claim
validation, expose the complete set of contributing scopes through
`contributionDependents`, and bind a fixed native Namespace object in the private
review. Contributors cannot request Kubernetes system or platform foundation
namespaces. Directly owned Namespace declarations bind their label content digest.
Controller reservations include Knative core Services, Certificate Secrets,
StatefulSet Pods/PVCs, and declared Helm members. StatefulSet expansion is bounded;
invalid generated names refuse rather than throwing during graph validation.
Native parity, observed ownership, and additional provider semantics remain the
responsibility of the adapter plans. The public declaration operation vocabulary
is closed and contains no shell-text alternative.

See [the compiler contract](../architecture/resource-inventory.md) for wire layout,
scope lifecycle behavior, verification commands, and the boundary with EP-145.

## Amendment — 2026-09-22: reviewed transactions and recovery

EP-145 implements the provider-independent state, review, admission, journal, and
recovery boundary. The filesystem and in-memory stores expose the same conditional
operations. Scope revisions combine generation with content identity; the head
separates accepted and converged vectors and records an active transaction and
executor claim. Journal members are canonical, immutable, sequence-numbered, and
linked by the previous member digest. A private checksummed export excludes process
locks and unpublished temporary files and refuses missing or altered members on
restore.

A public review directory contains the canonical review document and public scope
declarations, but never its retained native provider bytes. Those bytes are
published immutably in the selected context store. Apply resolves the public
document digest there, checks the public scopes byte-for-byte, verifies all native
member digests, and constructs provider adapters from that store-backed bundle,
as resume does. Constructing an apply adapter from the public directory alone
cannot supply immutable native evidence. Apply then rechecks the head and live
preconditions under the process lock. `ReviewedPlan` therefore remains evidence,
while the rank-2 lock callback is
the only place an `ExecutablePlan s` can exist. A negative compiler fixture pins
that boundary.

Execution records intent before effects and completion only after adapter
verification. Resume skips completed operations, asks the adapter to prove or
safely retry interrupted work, and preserves ambiguous transactions for operator
resolution. Adapter children receive the transaction identity and are refused if
they re-enter the inventory lock. Independent-process tests prove concurrent
exclusion and kernel release after process death.

Post-effect verification receives the same immutable retained native bundle as
preflight, execution, and recovery. An adapter must decode that evidence rather
than re-run preparation against mutable source, configuration, or provider state.
This keeps every completion proof bound to the reviewed bytes and makes clean-process
resume sound even when preparation inputs have subsequently changed.

The shipped CLI planner is deliberately manifest-only until EP-146 and EP-147
supply native adapters. It can publish deterministic review evidence, but its
preflight always refuses execution. Thus this amendment records an implemented
authority boundary, not a claim that existing cloud, host, cluster, or application
mutation paths have migrated.

## Amendment — 2026-09-22: cloud declaration and Pulumi registration boundary

EP-146's cloud foundation implements the cross-language authority boundary. Haskell
compiles stable resource identities, policies, provider addresses, Pulumi aliases,
and each resource's own specification digest into a canonical version-one bundle.
The Pulumi program installs a stack transformation when that bundle is supplied.
Every `gcp:` provider registration and `nagare:` component registration must match
one declared type/name pair, and every declaration must be consumed. Component and
provider bookkeeping is represented explicitly rather than ignored by parity.

Pulumi preparation retains the exact opaque saved-plan bytes after a canonical,
redacted header. The header binds context, project, stack, backend, program digest,
configuration digest, Pulumi version, common operation, input digest, native
registration digest, preview digest, and plan digest. Preparation rejects an
unknown mutating URN or a native action that disagrees with the common review;
preflight refuses if any binding changed. Pulumi remains the native stack-wide
executor. The common journal may name several declaration-level operations covered
by one native plan, so later operations verify convergence rather than replaying a
different plan after the first stack apply.

Host configuration is likewise a typed executor boundary rather than a set of
independently deletable Nix derivations. The declaration covers the evaluated
system, durable mounts, identity inputs, credential references, and delegated
services, plus a closed `ActivateHost` operation. Its receipt binds the physical
instance, destination, configuration and lock digests, old and new closures, and
activation identity. Only a fresh-login acknowledgement followed by the existing
self-reverting protocol's committed response proves completion. Current reachability
and health remain observations, not historical completion evidence.

Artifact declarations distinguish content owned in the current scope from immutable
release payloads consumed as external references. Owned OCI images, GCS image
objects, GCE images, build jobs, temporary builders, and control markers carry exact
content and specification digests. A named remote object with a different digest or
owner refuses before mutation. A matching immutable object proves completion without
republishing. Unknown global consumer completeness forbids automatic collection;
lifecycle policy must later supply explicit authority.

Bootstrap helpers do not acquire lifecycle ownership because a prerequisite is
missing. In particular, the image publisher no longer creates the Pulumi-owned image
bucket. Inventory-child publication returns a bounded, digest-bound result and does
not silently rewrite Pulumi configuration; a resolved image self-link requires a new
native plan and review. The necessarily local first context transaction and later
store migration remain the separate EP-151 boundary.

Adapter child processes are confined by two scoped environment values: the durable
transaction identity and a closed executor token. The executor installs and restores
both around execution, verification, and recovery. Host and artifact transports
check the token before context resolution or provider work, so invoking the wrong
transport cannot turn a held inventory lock into an unreviewed nested mutation.
`Inventory.Command` accepts concrete registry injection at its plan/apply/resume
boundary; the default CLI remains deliberately refusing until each production
domain registration is supplied.

The Pulumi domain now has a production subprocess runtime behind that boundary.
It derives registrations from composed declarations, installs the declaration
guard for preview/apply/verification, creates a saved plan only in preparation,
and writes retained bytes to a private temporary file for `pulumi up --plan`.
Physical observation comes from stack export and completion requires a no-change
preview. Its identity binds payload ID/digest as well as context, project, stack,
backend, program, configuration, and Pulumi version.

Cloud inventory reviews are reachable through the established infrastructure
namespace: `infra preview --inventory` invokes the shared planner, `infra apply`
recognizes the inventory review layout, and resume reconstructs the runtime from
the retained private review. The older Pulumi-only review path remains a temporary
compatibility surface while complete production declaration generation and upgrade
callers migrate; it does not accept or execute an inventory review as a native one.

Host and artifact domains now use the same production registry boundary. Host
preparation retains the evaluated closure and current physical instance, then the
self-reverting transport consumes that exact closure and proves committed running
and boot state over a fresh connection. Artifact scopes retain kind, destination,
content/spec digests, and consumer completeness in canonical bytes, allowing apply
and resume to reconstruct OCI/GCE publication without the compiling process.
Provider subprocesses receive canonical typed requests and cannot choose a different
destination or digest.

Pulumi URN comparison uses the leaf provider type because component children carry
parent-qualified type chains. The actual TypeScript program is exercised under
Pulumi mocks for base, image, cache, and every CDN certificate mode; each complete
registration set is replayed through the declaration guard. Remaining upgrade,
Just, and first-context bootstrap compatibility paths belong to EP-150/151 and stay
listed as such rather than being treated as inventory-converged.

## Amendment — 2026-09-23: cluster bootstrap and rotating host credentials

The supported cluster bootstrap now compiles its database, cache, upstream,
certificate, auth, observability, and local object-store components into one
reviewed inventory transaction. The last platform-version marker depends on
component completion; an accepted replay verifies the retained cluster state
without rewriting unchanged resources. The direct standalone database and
application deploy commands remain separate scope owners for EP-148. Their
continued existence does not grant a bootstrap adapter permission to invoke
them inside an inventory transaction.

The host's registry and forge timers have bounded credential-refresh authority.
The registry timer names only `personal` and `nagare-system` pull Secrets and
the default ServiceAccount pull reference in those namespaces. The forge timers
name only their read/write Secrets in the configured namespace. They stamp the
source version and actual credential expiry, refuse foreign or unmarked Secrets,
and use Kubernetes resource versions for updates. These are delegated values:
inventory does not acquire deletion or adoption authority over them. A
preexisting unmarked Secret requires an operator to verify its provenance and
explicitly mark it before activating the guarded timer.

## Amendment — 2026-09-23: retained incarnation authority

A reviewed `RetireScope` with `RetainResources` removes an accepted scope only
after each disappearing managed Kubernetes resource has an ownership record,
an exact observed physical identity, and an immutable scope revision. Admission
reobserves those identities under the writer lock. It atomically records the
retained incarnation in the context head before execution, and the old scope
member remains content-addressed in the store. Retained provider claims remain
reserved when composing later candidates. A candidate that omits these
reservations or reintroduces a retained logical identity is refused.
Observed controller children cannot disappear through this route because their
derived claims and physical identities do not yet have retained child entries.

A selected `ReplaceScope` may also omit one or more members while keeping the
scope and its siblings accepted. Each omitted managed member requires an
explicit `ApproveRetirement` decision in a saved review. Its proof binds the
old accepted scope revision and observed physical identity; admission checks
that the proof set exactly matches the removed members and reobserves them
under the writer lock. The old immutable scope member remains available to
reconstruct retained history even as a newer revision of that scope is active.
An ordinary replacement without those decisions still refuses removal.

Retirement performs no provider deletion. Read-only status recovers native
observation inputs from the retained scope's original immutable review and
reports whether its exact incarnation is present, drifted, replaced, absent,
or unavailable. These observations never grant deletion authority.
Collection still requires separate reviewed deletion authority, dependency and
recovery evidence, exact live identity, and a durable tombstone. Executors whose
retention observation contract has not been proved cannot retire through this
route.
The read-only collection assessment may identify candidates and blockers, but
its output is not a deletion review or a tombstone.

The first reviewed collection route is restricted to retained stateless
namespaced ConfigMaps with `DeleteWhenUnreferenced`, no active or retained
consumers, and an exact present stamped UID. `CollectRetained` leaves desired
scope revisions unchanged while its review binds the old owner, immutable
scope revision, and physical identity. Admission checks the exact current
Kubernetes resourceVersion; the native DELETE uses UID and resourceVersion
preconditions and orphan propagation. Only confirmed absence permits a
review-bound deletion tombstone to replace the retained claim in the head.
The tombstone keeps the old logical ID unavailable for silent reuse. Other
kinds and durable data remain outside this proved route.

## Amendment — 2026-09-24: immutable replacement observations

Provider observations distinguish an in-place configuration drift from a
change requiring physical replacement. The shared typed observation carries
the current physical identity and observed digest for either case. A
replacement-required observation is visible in read-only status but cannot
become an ordinary `UpdateResource` plan. It requires a separate reviewed
replacement or migration contract with recovery evidence. This generic
boundary is implemented; production adapters have not yet been taught to
classify specific immutable changes.

## Amendment — 2026-09-24: reviewed migration incarnations

A rename or executor change keeps one logical ResourceId while temporarily
holding two physical incarnations. The ordinary observation set remains
single-valued and observes the desired address. Migration observes the
historical source through a separate adapter registry and pairs it with the
destination fact only after exact coverage checks. An input file names the
source UID, destination absence proof, and a stateless or durable data
contract, but accepted and composed declarations supply ownership and policy.

The generic planner records a review-bound eight-stage graph covering
destination preparation, source backup, writer fencing, state transfer,
destination verification, consumer switch, write admission, and source
retention. Admission binds the old scope revision and source physical identity
under the writer lock. It advances the accepted destination while retaining
the source claim and its immutable native evidence. An active and retained
record may share a logical ID only when their provider claims are disjoint and
the retained entry points to a canonical immutable migration review with
matching source and destination addresses. Status must observe these two
incarnations independently. Ordinary updates to declared consumers run after
destination verification and before the consumer switch stage, which still
requires provider-specific cutover proof.

This is a provider-independent contract proved with a recording adapter,
including recovery from an ambiguous result at each stage. Production
Kubernetes, Helm, Pulumi, host, artifact, and cache adapters have no native
migration stage contract yet and refuse preparation or execution. Durable
evidence identifiers alone do not prove backup, compatibility, fencing, or
recovery; a provider adapter must verify those facts before issuing a usable
review. A retained migration source is not collectible while its logical ID
remains active under the current collection route.

The current `DeleteWhenUnreferenced` policy has no configured minimum age and
is used only for the proved stateless ConfigMap deletion route. `Retain` and
`Protect` never imply an elapsed-time deletion grant. Durable or timed
retention needs a typed policy and provider backup/recovery evidence before
collection can be reviewed. The head continues to reserve a migrated source
while its logical destination is active; source-specific collection requires
an incarnation-aware tombstone and adapter binding in later work.

## Amendment — 2026-09-24: standalone database consumer bindings

A separately owned workload may consume an accepted standalone database without
acquiring its lifecycle authority. The consumer binds one accepted Service,
StatefulSet, and credential Secret in the same scope and cluster namespace.
The saved private credential template identifies the engine; the saved Service
and StatefulSet labels must agree. The workload depends on the accepted
StatefulSet and receives connection fields plus Secret key references, while
the credential value stays out of compilation and review output. Missing or
inconsistent private native evidence refuses planning. A live object name or
label alone cannot supply this binding.

## Amendment — 2026-09-24: canonical application config evidence

An application, standalone Service, or standalone worker scope records an optional
digest of its validated typed config in the immutable scope document. The digest
is computed from canonical JSON of the loaded value, not from the bytes of one
Haskell source file: imports and formatting cannot by themselves describe the
effective config. It participates in the scope revision alongside declarations,
while each native resource keeps its own independently derived spec digest.
Earlier scope documents omit the optional field and remain valid. Reviewed apply
and resume use the saved scope and private native evidence, so they do not need
the source checkout that produced the accepted config.

The scope document can also retain a canonical map of explicit, public command
overrides alongside that digest. Reviewed application deployment records its
tag, optional base domain, accepted image resource, and optional namespace
request. These are input evidence; provider credentials and secret values do not
belong in this map. Older scope documents decode with an empty override map.

## Amendment — 2026-09-25: shared CDN owners and provider dispatch

Google Cloud DNS records and Cloudflare resources share the inventory's CDN
executor, but each resource ID has exactly one provider binding. A single
registry adapter dispatches observation and mutation to the bound provider;
an operation spanning providers refuses. Google application DNS owns an exact
hostname RRset and uses Cloud DNS's atomic change with the accepted old value.
Cloudflare host DNS records have separate workload owners, while one platform
zone owner composes the complete cache ruleset and origin-TLS setting from
granted host contributions. Applications cannot write partial whole-zone rules.

The Cloudflare review records the provider object ID and observed version in
private evidence and checks the old complete content immediately before an
HTTP mutation. Every read checks the zone ID and account against the active
context's explicit binding. Nagare's context journal serializes its own writes;
the documented Cloudflare DNS overwrite and zone ruleset update requests do
not expose an atomic old-value precondition, so an external writer may still
race that final read. An uncertain response stays unresolved for operator
recovery. Typed application and production-site compilers bind an accepted
platform zone grant and origin IPv4, then submit per-host DNS and cache
contributions. Live Cloudflare validation remains separate from this offline
contract.

## Amendment — 2026-09-26: close unscoped control and cleanup writers after admission

The context profile chooses the inventory store and supplies its project binding.
Rewriting or deleting that profile after inventory admission could strand accepted
history or make subsequent provider work select a different target. Existing
named or unnamed `init`, `context create --force`, and `context delete --yes` therefore refuse
once the selected store has substantive history, an executor claim, or a store
migration. A newly created context may still bootstrap, and `inventory store
migrate` remains the reviewed way to move its history. An initialized but
untouched store does not close the compatibility path.

The old confirmed cleanup command has no exact reviewed ownership proof for its
preview deletions and release-history rewrites. Direct host age-key placement
also changes remote credential state without a reviewed host operation. Both
refuse after the same admission boundary; cleanup dry-run remains available.
This is an explicit unavailable state until each action has a typed owner and
reviewed operation. Raw provider tools and older operator binaries cannot be
assumed to honor this boundary.

## Amendment — 2026-09-26: first release starts from fresh contexts

The operator confirmed that every existing Nagare context and its data can be
recreated for the first inventory-backed release. The release claim therefore
requires complete reviewed bootstrap of a fresh context, not conversion of
historical coarse upgrade transactions or an in-place platform version
change. The initial context pin names the selected immutable payload; the
component journal and final cluster marker distinguish partial work from
completed bootstrap. Old transaction bundles remain inspectable, and their
runner refuses an admitted inventory context.

Independent application and platform scope ownership still requires the
composer to preserve unselected revisions and validate cross-scope
dependencies. A later payload version transition must introduce its own
reviewed component protocol before changing an admitted context's pin. This
scope decision does not relax application command cutover, complete resource
coverage, live local/GCP convergence, or immutable release evidence.

## Amendment — 2026-09-26: live deployment crosses the inventory boundary at initialization

Once a context's inventory history store is initialized, live CLI deploys for
applications, standalone Services and workers, and static/server production
sites and static previews require an accepted image publication and reviewed
scope submission. The direct render/build/apply route refuses even for a new
name: an unclaimed workload name does not authorize its namespace, credentials,
routing, or other shared effects. Image-free, read-only dry-run rendering remains
available. Contexts without initialized history retain the legacy deployment
route while the migration is incomplete. This boundary is deliberately earlier
than the substantive-history admission rule for legacy context control and
cleanup commands above.

The `nagared` webhook executable still invokes direct static deploy functions.
It now resolves the active context and checks that context's inventory store on
each triggered delivery and immediately before deployment. An initialized
store returns HTTP 409, including when admission occurs after the worker
starts. Reviewed context-bound webhook submission remains necessary before
managed contexts can use that route. The runner requires a named context, and
cloud deliveries require its inventory store to be shared through GCS;
otherwise a private local store could falsely appear empty on the webhook
machine. The CLI guard alone did not protect it.

The same initialized-store boundary applies to live Task commands. Manual
execution requires an accepted CronJob and a stable `--run-id`, which gives its
Job a reviewed identity and retry receipt. Direct schedule deletion refuses.
`task delete --save-plan` instead saves successive reviews to suspend the
accepted CronJob, retain that suspended member while preserving its scope's
other members, and conditionally collect the retained incarnation. Each stage
must be applied before planning the next. Plan-only and dry-run Task output
remain available; an uninitialized context retains the legacy commands.

Direct data commands follow the same boundary. Once a context initializes its
inventory store, database and broker create/delete and unclaimed restart refuse
without a reviewed operation. Database shell, manual backup and restore, and
app-volume snapshot and restore also refuse live direct execution. Reviewed
create, restart, and retention-preserving retirement remain available; the
remaining operations need explicit receipts and recovery policy before M3 can
close. Read-only dry-run forms remain available where the command supports them.

Initialized contexts also require reviewed Runtime, Build, or Preview env
channel writes and versioned Secret channel writes. A newly named store cannot
enter through the direct command merely because no accepted native address
exists yet. The old direct forms remain for uninitialized contexts and their
dry-run output remains read-only.

Legacy application stop, restart, and delete also refuse after initialization
when no accepted Service scope selects the action. Accepted stop and restart
already have reviewed scope updates; app deletion needs a saved retirement
review. Static and server site rollback needs a saved reviewed release change,
and static preview deletion needs reviewed retirement. These checks prevent a
new native name from bypassing the context journal.

Direct CDN purge and disable and access grant, revoke, and portal sync are also
legacy operational writes. They refuse once the context inventory is
initialized, including for a new hostname. Saved access grant/revoke and portal
synchronization reviews are now available through the shared journal as defined
in the 2026-10-01 amendment below. CDN review coverage remains open; read-only
inspection and CDN dry-runs remain available.


## Amendment — 2026-09-26: preserve release acceptance across plan decomposition

Splitting integration work into smaller execution plans does not reduce the inventory release contract. Fresh-context bootstrap, promised application/data operations, complete mutation coverage, installed packages on every supported native system, local and GCP recovery evidence, and immutable candidate-bound release evidence remain mandatory together. A guarded refusal of a promised feature or a partial local success does not establish release readiness. The previously accepted fresh-context boundary and offline-only Cloudflare proof remain unchanged.

[MasterPlan 23](../masterplans/23-make-managed-resources-first-class-through-typed-scoped-inventories.md) assigns the remaining former EP-150 work to EP-152–157. Native integration proof may be shared with the feature plan that consumes it; administrative plan completion must not create a circular prerequisite for running that proof. Prior provider evidence remains scoped to its recorded candidate and cannot be relabeled as evidence for changed code.


## Amendment — 2026-09-26: one recovery fence across restore and maintenance

The remaining EP-148 feature work is assigned to EP-158 (access/CDN), EP-159 (scheduled backup receipts and exact retention pruning), EP-160 (database/volume restore and data fencing), and EP-161 (interactive maintenance). EP-153–157 retain command coverage, consumer cutover, packages, native integration, and final release acceptance. The original plan is superseded with its delivered evidence intact, not marked implementation-complete.

EP-160 owns one durable data-fence protocol in the existing inventory store/journal. It binds the accepted target and physical incarnation, affected writers, recovery references, exclusion proof, and recovery/release phases. The CLI writer lock alone is not data-write exclusion. Restore and maintenance must establish and observe appropriate provider controls before changing data. EP-161 owns client/session lifetime and uses that same protocol; it does not add a second maintenance lock, session store, timeout unlock, or automatic replay. A surviving remote client or ambiguous data effect retains its recovery obligation after operator-process death. These are required design contracts, not claims that fencing is already implemented.


## Amendment — 2026-09-26: reviewed fresh bootstrap completion is generation stable

A fresh context's platform prerequisite stages are independently reviewed and accepted before any cluster-dependent review is prepared. The final platform marker waits for every cluster operation and records the selected immutable payload identity plus the accepted platform scope generations and canonical declaration digests. Independently owned application, standalone, and publication revisions do not enter that marker vector.

Recompiling a canonically identical platform scope for bootstrap validation does not select a new scope revision. Bootstrap omits that replacement from its final composition and reuses the accepted generation; otherwise a new planning timestamp could change the marker vector and request a spurious update. The marker's installation time is reused only when the reconstructed marker specification matches its accepted declaration. A proved artifact publication operation remains complete on an unchanged rerun, while a physically missing artifact receives a focused reviewed repair.

After the host scope is accepted, bootstrap continuation validates its exact context-owned configuration and lock before preparing kubeconfig or cluster scopes. It does not reevaluate or rebuild the original installation image: the live host no longer consumes that build source, and changes to a mutable development checkout must not block later cluster work. Accepted image declarations remain in the composed inventory and retain their ownership and cleanup authority. Skipping installation stages does not claim artifact health: composed reviews still observe accepted artifacts, but a build observation checks the exact reviewed output path and path digest without reevaluating source. Missing artifacts follow normal reviewed repair; build execution and interrupted image transactions still validate their original inputs. Changed host inputs still require a separately reviewed host transition.

The focused native marker proof exercises the final operation against a disposable Kubernetes API after recording the other component effects. It does not replace the required native local application/data and GCP convergence evidence for the inventory release.

EP-159 owns a compatible extension of the existing backup receipt contract for delegated scheduled runs and exact retention selection. Restore consumes verified receipts; an object listing alone grants neither restore nor deletion authority. All feature outcomes and native integration gates remain mandatory together under MasterPlan 23.


## Amendment — 2026-09-26: command coverage is candidate-bound release evidence

An executable finite registry classifies the typed CLI constructors, packaged
recipes, and production calls into the inventory command service. Each
effectful command and recipe maps to the detailed managed-resource coverage
catalogue, which names its owner, compiler, executor, proof, and older-route
disposition. Adding an unregistered constructor or recipe fails the audit. This
registry records migration progress; it does not grant an effect or replace the
reviewed inventory, retained native plan, and journal receipt.

The release coverage result is complete only when no promised route, recipe, or
catalogue row remains pending and the audited tree is clean. The release
evidence assembler requires the result's source revision to equal the release
manifest revision. A standalone `complete: true` flag or a passing guard test
cannot establish command coverage. Further operation families must extend the
registry and behavioral proof before a release may claim completion.


## Amendment — 2026-09-27: supported deployment targets and bounded fence acceptance

The operator explicitly prohibits GKE for this initiative. Nagare targets local k3d/k3s and k3s on its NixOS host in GCP Compute Engine. GCP is not permission to provision Google Kubernetes Engine. Do not create, start, use, authenticate to, select, or request a GKE context, or add GKE compatibility/proof requirements. The GKE requirement introduced during EP-160 implementation was a scope error and is withdrawn.

EP-160 M1 establishes the production saved-review fence contract, local native writer exclusion, scoped authority, durable recovery, and a real verification/release gate. Engine-specific restored-content semantics remain M2; live-volume recovery remains M3; full real cloud k3s and GCS-history evidence remains EP-156. Shared-contract completion must not wait on those later outcomes, and full release acceptance still requires all of them. Known unsafe writer paths refuse until their owning implementation is accepted. Trusted cluster administrators are outside the workload fence threat boundary; concrete bypasses by in-scope principals must be fixed without silently expanding into a general Kubernetes security project.


## Amendment — 2026-09-27: share recovery authority, specialize access to fenced data

The durable fence is one reservation/review/recovery lifecycle in the inventory store. Its native access policy depends on the admitted operation. The current Kubernetes provider establishes offline exclusion by shutting down the original database, draining its writers and volume consumers, and retaining admission guards. That proof is useful for physical recovery but does not itself admit a running database for logical restore or an interactive client.

A restore or maintenance implementation must bind the selected authorized recovery process, exact data identity, permitted access, observed exclusion of other writers, content/client verification, and process termination or recovery before release. If that operation needs an engine while normal workloads remain stopped, its engine/client access is explicitly reviewed and observed inside the retained fence; starting it is not equivalent to releasing ordinary writers. Required temporary resources are declared under the existing review contract. Reuse the common durable phases and appropriate native controls; do not introduce a second lock/store or silently weaken an offline exclusion predicate to admit every consumer.

EP-160 M2/M3 own restore-specific access and verification. EP-161 owns maintenance engine/client admission and surviving-process recovery. These consumer obligations do not change the six EP-160 M1 closure criteria. Full release acceptance still requires the usable restore and maintenance paths. Prove the first complete operation through saved review, native execution, interruption, verification, and release before multiplying engine/command variants. Trusted cluster administrators remain outside the workload threat boundary; additional providers or broader security promises need an explicit scope decision.

## Amendment — 2026-09-28: retain cross-tool authority and narrow lifecycle scope

The operator explicitly retains Nagare's typed ownership scopes, reviewed native-operation
boundary, durable cross-tool journal, and filesystem/GCS state. Native tools' state is not a
substitute for the history that coordinates Pulumi, NixOS, Kubernetes, data, and publication.
The single-writer/conditional-store contract and recovery rules remain in force; this decision
does not add a daemon or new coordination service.

MP-23 now requires verified native manual/scheduled backups for the existing PostgreSQL, Redis,
and ClickHouse engines, isolated database restore destinations, and volume restore to a new PVC.
General live database/PVC overwrite and automatic recovery promotion/cutover are deferred.
Custom interactive mutating maintenance and unrestricted exec/migration sessions are deferred;
EP-161 is Cancelled. Existing static reviewed hooks and read-only inspection remain supported.
The bounded PostgreSQL rename/native lifecycle verification in EP-155 remains required; it does
not imply a universal live recovery framework. No new database or messaging engine is added.

Generalized scheduled keep-N/expiry pruning is deferred. Scheduled backup data is retained by
default, and review/status/user documentation must say the configured policy is not enforced
for that path. Operators must account for storage growth. Existing supported exact reviewed
manual pruning retains its evidence and dependency checks; automatic object-store expiry cannot
silently remove referenced recovery data. EP-159 owns truthful retention reporting and receipt
correctness, not a new general retention engine.

A scope decision is not a runtime guard. EP-153 must refuse new deferred operations at command,
library, recipe, and generic saved-review admission, including old reviews that never began.
Already-admitted transactions remain inspectable and recoverable under their original immutable
review, physical identities, and observed-effect checks. Preserve partial-prune, live-fence, and
session recovery code/records; do not clear a writer claim or replay arbitrary effects merely
because its feature is deferred. Recovery cannot become admission for new unreviewed work.

Release coverage continues to enumerate every route, with finite supported/deferred dispositions
bound to this decision and the candidate. Supported operations require working behavior; deferred
routes require refusal and retained-recovery proof. Missing supported behavior cannot be relabelled
as excluded. All native-system packaging, actual local/GCP integration, independent-scope and
IR-24 verification cases, and immutable evidence remain mandatory for the revised contract.
Earlier no-feature-reduction and all-engine maintenance/live-overwrite requirements describe the
previous scope and are superseded only by these explicit exclusions.

MP-24/EP-163 independently evaluate external tools beneath this architecture. No Flux or implicit
substitute GitOps platform is selected. CloudNativePG/Barman is a PostgreSQL candidate; Velero is
a backup/recovery evaluation candidate only. The operator has not selected either, and prototypes
or adoption do not gate MP-23. Any future tool must have one explicit lifecycle owner with bounded
delegation, while Nagare binds its external operation identities/results into the retained journal.
Actual storage support, database consistency, recovery, footprint, and net code/test maintenance
must justify adoption before adding controllers or changing storage. A new database engine later
needs its own bounded declaration/adapter/proof; anticipated growth does not justify a generic
provider or maintenance framework now.

## Amendment — 2026-09-29: command boundaries preserve lifecycle and cost contracts

[Local operational experiments](../audits/mp23-operational-experiments.md) demonstrate that
primitive correctness is insufficient when command orchestration adds historical scans,
duplicate head discovery, or pre-effect predicates before recovery. Store conformance and
executor tests remain valid at their tested boundary; they do not certify a complete command.

Registry construction reconstructs and validates immutable reviewed inputs and selects
adapters. Live conditions whose truth changes through the operation belong to the appropriate
preflight/effect/verification/recovery phase. An already-admitted ambiguous operation must
reach its recovery handler before a pre-effect condition is reconsidered. Moving that check
outward into a command factory violates the existing recovery contract even when the executor
itself is correct. Recovery remains bound to the original evidence and exact physical identity. E10 also demonstrates
that a dependent operation's live precondition can block recovery of its prerequisite
inside the executor. Validate the whole review's structure before effects, but defer
live operation predicates until dependencies permit that operation to execute.
Terminal adapter outcomes must have explicit stopped/recovery behavior; they cannot
fall through an incomplete match or authorize automatic replay.

Resolve a selected resource against accepted/retained declarations before preparing unrelated
workspaces, native inputs, or provider observations. Ordinary native lookup must select the
evidence needed by those bindings; it must not reconstruct every unrelated historical review.
A derived lookup may locate immutable evidence but cannot replace digest, membership, native
reconstruction, or incarnation checks, and cannot become an independent ownership authority.
Explicit integrity/reconstruction work may inspect the wider history. Missing or corrupt
selected evidence remains a refusal; scoped inspection makes no claim that unrelated history
has been globally audited.

The lookup boundary is a selected native member, not an entire private review bundle.
The original immutable document and required declarations remain authenticated; a
selected read does not need unrelated native payloads. Expose this as a distinct
evidence type that cannot be used for admission, preserving full review validation
there. Lookup publication must complete and validate required witnesses before new
admission depends on them; retries and an explicit resumable rebuild handle
interruption, old history, and restored roots. Missing derived state cannot silently
mean absent native evidence. Scope/manifest decoding remains a separately measured
cost under the current immutable format. E6/E7 in the experiment report establish
these design constraints, not a shipped implementation.

Append optimization must preserve the observed provider generation, executor claim, event
identity, and conditional head advancement. Reusing an observed head within one append is a
tested design direction; persistent mutable-head caching and unconditional writes are not
authorized substitutes. EP-156 owns production implementation and adversarial proof, including
lost acknowledgements and takeover. The local counterfactual does not establish cloud latency.

Measure these contracts at the complete command boundary, including setup and finalization,
with independent variation of selected resources, unrelated reviews, and journal length.
The current no-daemon, native-executor, and single-writer architecture remains unchanged.

## Amendment — 2026-09-29: reassessed execution and read responsibilities

The [design reassessment](../audits/mp23-design-reassessment.md) retains this ADR's
ownership, native-tool, immutable-history, and single-writer decisions. It replaces
distributed operation-phase decisions as an implementation strategy. Apply and
resume must share one deterministic serial operation driver. Whole-review
structural/authority validation is distinct from live preconditions for an operation
whose dependencies are ready. Registry construction loads immutable inputs;
operation-time provider checks belong to that driver and its adapters. Every
recovery outcome has explicit behavior, including terminal failure and unknown
legacy resolution states. No historical review or journal rewrite is implied.

Resource inspection consumes selected validated observation evidence and does not
construct mutation execution. Exact original evidence remains authoritative.
The earlier publication/rebuild proposal is one possible acceleration protocol;
mandatory index availability before historical recovery is superseded. Derived
state may assist lookup but cannot revoke an already-admitted review's recovery
authority. Where old formats require extraction, make that explicit, bounded,
restartable, and subordinate to immutable proof. Missing/corrupt required
evidence still refuses. The implementation checkpoint below records the chosen
compatibility path.

This is a bounded implementation direction, not new product scope or a declaration
that the replacement is proven. Preserve existing native safety checks, historical
recovery, and release acceptance. A need for another persistent engine or rewriting
admitted history would require a new explicit design decision rather than silent
expansion of this repair.


Implementation checkpoint (2026-09-29): the shared serial driver and unified
apply/resume registry now have [production consumer proof](../audits/mp23-rescue-proof.md).
Removing general live preflight does not remove admission-time authority checks:
retention re-observes the original physical incarnation, and migration checks the
original source before transferring it into retained history. The existing
`BackUpSource` preflight supplies that source-binding check independently of
future destination readiness. Neither admission check becomes an up-front resume
requirement. The following checkpoint records selected-read and store-cost implementation.

Readiness recovery amendment (2026-09-30): a created Kubernetes Deployment
whose exact reviewed ownership stamp and native digest still match may report
that it is awaiting readiness, rather than unknown effect state. This is not
completion or permission to repeat its create. The shared driver may then create
an untouched, stateless Deployment from the same immutable review whose declared
predecessors have durable completion proofs. Both operations must be unfenced;
another uncertain or blocked operation stops this continuation. Re-enter the
waiting Deployment's guarded recovery after each completed create. Only actual
readiness may append its completion proof, satisfy dependents, or converge the
transaction. Missing or changed scope evidence, foreign ownership, changed native
bytes, failed workloads, data operations and updates remain stopped. This bounded
path repairs already-admitted initial bootstrap ordering omissions without
rewriting reviews, abandoning accepted history, or treating unready objects as
healthy. Future Knative reviews order activator after its autoscaler healthcheck
dependency explicitly.


Observation/store implementation (2026-09-29): resource status/explain now consume
an opaque `ObservationNative` value instead of an execution-review projection.
The validated accepted or retained declaration supplies context/ownership/address
and incarnation authority. Its native digest names canonical unstamped Kubernetes
bytes or the Helm contract directly in the existing private `native/` content
store; these portable bytes do not themselves grant ownership or execution.
Kubernetes binding is recompiled and checked, while closed generated Namespace,
backend-map, and Shomei shapes reconstruct exactly from typed contributions.
Publishing a known native adapter's review also publishes these digest-addressed
bytes without changing the review format or admission hash. Inspection never
lists reviews and a selected miss never starts an implicit historical scan.

For older stores, `inventory store materialize-native --limit N --after DIGEST`
is explicit compatibility extraction. It validates original reviews, reports
progress per review, checks a captured head, and writes only immutable bytes.
Repeating an interrupted batch is idempotent. Full execution/admission/export
validation and historical recovery remain independent of this observation path;
legacy execution helpers still retain their archival lookup compatibility.

`Store.ObservedHead` privately binds a validated head to its store and exact
provider generation. Journal append uses that observation for its conditional
head replacement, so remote head rediscovery is unnecessary. The local backend
rechecks under its guard; the object backend uses the captured provider generation.
A replay reads the committed journal prefix from the head it already observed.
Neither change caches mutable heads across commands or removes writer-claim,
takeover, hash-chain, or lost-acknowledgement checks. See the implementation's
[bounded proof](../audits/mp23-selected-read-proof.md); GCS latency remains a
separate acceptance gate.


Active-startup implementation (2026-09-29): apply/resume/recover and inline
convergence pass their validated store into the execution factory. Source helpers
retain their head/revision checks but do not reopen remote ownership/format state.
Selected accepted or retained native bytes may supply source-adapter inputs;
only the complete original review authorizes execution. A typed absent-byte result
permits compatibility reconstruction from original archived envelopes. Invalid
selected bytes never trigger that fallback, including mixed missing/corrupt sets.
No historical materialization prerequisite is introduced. Workspace resolution is
conditional on the actual executor/cache runtime requirements; immutable bootstrap
payload checks remain mandatory. See [the active-startup proof](../audits/mp23-active-startup-proof.md).


Claim/publication implementation (2026-09-29): each admission, claim update and
collection-finalization CAS consumes the exact opaque head observation used by
its authority checks. It must not rediscover and adopt a newer provider generation
just because the decoded head is equal. Explicit recovery shares that first
observation with journal-prefix validation, then conditionally acquires the claim.
Existing fresh effect-time and release observations remain. Saved-review execution
verifies its exact publication without enumerating unrelated archive keys. This
publication check bypasses the local immutable cache; cached integrity does not
prove publication in the selected store. Complete original bundle validation is
still required. See [the claim/publication proof](../audits/mp23-head-claims-proof.md).


GCS transport direction (2026-09-29): the [bounded Gogol experiment](../audits/mp23-gogol-transport-proof.md)
justifies replacing repeated object-level gcloud processes with a reused SDK
manager within a command. The operator chose a current upstream source pin;
use the exact tested commit from `mori://brendanhay/gogol/repos/gogol`, consistently
across Cabal and Nix. This checkpoint selects the implementation direction,
not the production default. Retain ObjectOps uncertainty/conditional-write
outcomes, exact provider-generation authority, context/bucket/prefix checks,
and complete validated journal replay. SDK project quota attribution does not
prove bucket ownership. Credentials must preserve the selected identity through
refresh; the bounded probe's stdin token is not that production mechanism.
Only adopt the adapter after failure conformance and public-command evidence,
including bounded paginated journal downloads. No state format or provider
mutation policy changes are implied.

GCS library integration (2026-09-29): the [SDK adapter proof](../audits/mp23-gogol-integration-proof.md)
now establishes actual HTTP conformance through the existing ObjectOps/store
protocol, bounded generation downloads, and explicit user-credential refresh.
The public constructor accepts explicit credentials and performs no ambient
credential discovery. Both build systems pin the same upstream commit with the
same scoped bound relaxations. Retain one environment per command. CLI factory
adoption must select the same identity as the context's existing authentication
contract before using this adapter; a quota project or successful ADC exchange
cannot establish that identity. The existing CLI backend remains selected until
that boundary and public-command evidence pass. No state-format migration is
required by the transport itself.

GCS command adoption (2026-09-29): the [public CLI proof](../audits/mp23-gogol-cli-proof.md)
now supports the SDK default. gcloud remains the credential authority: capture
account/configuration/impersonation and real expiry once, pin them for ownership
probes and serialized refresh, and refuse changed identity or unsupported modes.
No ambient ADC substitution or credential-database parsing is permitted. Retain
one HTTP manager and token cache per store. Because the pinned SDK lacks callback
credentials, short-lived request auth environments use immediately removed private
token files under a request bound shorter than their SDK lifetime. This replaces
the earlier one-environment requirement; connection reuse and identity retention
are the durable requirements. Normalize an unset gcloud Storage endpoint to its
explicit default, because an empty endpoint is invalid. The legacy transport is
an explicit compatibility choice, never an automatic retry after uncertainty.
State formats, ownership checks and cloud mutation gates are unchanged.

Bootstrap registry recovery (2026-09-30): an original created private-image
Deployment may remain unready after its accepted host's boot credential expires.
Recovery must not rewrite the Kubernetes review or add unreviewed ServiceAccount
or Secret authority. A separately saved private recovery proof binds the original
review/operation/native digest and Deployment UID to one completed accepted host
activation, its VM and closure, node UID, boot ID and original unit stamps.
The explicit decision journals intent under the original transaction claim before
replaying only `nagare-registries-refresh.service` and restarting `k3s.service`.
Each phase checks the unchanged VM/running/boot closure and rollback state.
Uncertain acknowledgement leaves the saved intent blocked; explicit same-proof
recovery holds a native host lock and requires quiescent unit jobs before
observing stamps or issuing effects. It skips completed phases even if their
credential later expires. A known expired credential is renewed through the
accepted policy only before a still-unperformed restart. A changed node or
unproved restart refuses; a changed boot refuses unit replay. A now-ready
original Deployment permits read-only settlement of an unnecessary prerequisite,
including after reboot, once the same host and quiescent units are proved.
Ordinary workload completion cannot bypass a pending host intent. The host receipt returns
execution to provider observation, never to a fabricated Deployment completion.
Actual Kubernetes readiness remains required. Credential bytes stay in the
root-only host process. This is a bounded replay of accepted policy, not a
payload-version upgrade or a general host maintenance surface. Steady credential
coverage for future private platform workloads remains a separate safe-use proof.

A failed gcloud refresh invalidates the command-local token cache before callers
receive the error. Concurrent waiters must not each retry a failing helper or
reuse the previous token. Recovery starts with a new command under the selected
identity and, for mutations, the original transaction. Provider 401 responses
remain uncertain/refused outcomes; they do not authorize an implicit write retry.

Kubernetes review observation (2026-09-29): a read-only scan may validate the
selected context and expected server node before and after its object reads,
with every read still selecting the explicit context. Either guard refusal
invalidates the entire scan, and an initial refusal performs no object reads.
This reduces the repeated guard processes demonstrated by the 201-resource
native bootstrap plan. It is a scan boundary only: native preparation, preflight,
execution, verification and recovery retain fresh individually guarded reads,
and writes retain their API-server-enforced conditions. The
[native checkpoint](../audits/mp23-native-bootstrap-proof.md) records the measured
source result separately from installed acceptance and cluster convergence.

Incomplete application creation recovery (2026-09-30): an owned, unchanged
Knative Service create can remain unready while resources already created in
its application scope include retained data. An explicit
`stop-incomplete-application` decision may close that active transaction without
provider effects, rollback or convergence. It requires one changed Application
scope, only unfenced Kubernetes creates belonging to that scope, an exact owned
originally absent stateless Knative Service still awaiting readiness, and no
other uncertain operation. Journal the selection before clearing the writer.
Preserve both admitted ownership and the prior converged revisions; do not
restore the old accepted vector, erase created data ownership, or manufacture
workload completion. A new reviewed configuration observes these same members.
Lost acknowledgement after the journal record is settled only by the same stop
decision with immutable review validation, without another provider probe or
effect. Ordinary adapter proof cannot bypass a pending stop selection. This is
an application creation recovery boundary, not a general transaction abort.
Knative Service configuration updates retain exclusive non-status field
ownership checks and API-server UID/resourceVersion write preconditions. Actual
cloud update acceptance remains required before claiming this consumer proved.

The same explicit stopped-configuration decision also accepts a newly created,
unready DomainMapping in an exact typed Standalone site-preview scope. Validate
the complete original preview member/address/policy contract, require all other
unfenced Kubernetes creates to be Completed, and independently prove the owned
originally absent route still has its reviewed digest. Preserve accepted Service,
route and volume ownership without claiming convergence. A new review can correct
the Service visibility label while retaining the route and PVC. Pending companion
creates, incomplete/foreign preview shapes and arbitrary Standalone resources
cannot use this path. The never-started durable-member exception below remains
Application-only. This handles a current preview's configuration failure without
rewriting its original transaction or changing immutable payload bytes.

A stopped application may admit durable members whose original creates never
started. Accepted absence alone cannot distinguish these from lost data. For an
idle unconverged Application revision only, load and validate the committed
journal prefix and original stopped create review. The review must still name
the exact accepted revision and pass the same application-only stop contract.
Only creates with no committed state beyond Pending anywhere in that original
transaction may receive a never-started proof. A corrected plan may create such
a member only when its managed declaration is unchanged and fresh observation
confirms absence. Completed, intent-recorded, ambiguous, foreign, changed, or
superseded members retain normal refusal/recovery requirements. This proof
changes neither accepted ownership nor the wire format and grants no provider
overwrite authority. Only planning that selects the unconverged application loads this exceptional
journal proof. Ordinary status, explain, native inspection and unrelated scope
planning retain selected declaration reads and never trigger this journal scan.

Transaction completion advances convergence only for scope revisions changed
by that immutable review, and removes convergence for its retired scopes.
Unselected accepted scopes may include a previously stopped application whose
resources remain owned but unready; another application's success grants no
convergence evidence for it. Preserve its previous converged revision or its
absence. This is independent from preserving the accepted ownership vector.

When replanning a selected accepted scope without convergence proof, unchanged
managed members still require fresh native verification. Ownership and an
unchanged declaration do not establish readiness. In particular, completing a
never-started durable create must not silently converge its still-unready
Knative Service. Native preparation refuses an unchanged unready workload; a
corrected configuration uses the existing conditional update path instead.
Converged unselected scopes retain their previous receipts.


## Amendment — 2026-09-30: fresh host registry credential delegation

Fresh generated host declarations reserve the three exact `nagare-registry-pull`
Secret addresses in `personal`, `nagare-system` and `knative-serving` as aliases
of the canonical host system resource. Another scope cannot claim one of these
addresses. The Serving controller account keeps its existing direct-object
identity, computed by the same canonical address algorithm as all upstream
objects, and grants that host only `RefreshCredential` for the pull reference
and registry credential metadata roles. Reviewed native account bytes bind the
static grant to the host identity. The same reviewed account bytes contain the
single fixed `nagare-registry-pull` reference before any controller Pod is
admitted. Kubernetes copies ServiceAccount image pull references into new Pods;
a later timer patch alone cannot repair that initial inheritance. Conflicting
preexisting references refuse instead of being overwritten. The timer refreshes
the credential Secret and maintains this exact reference within its bounded
authority. Credential values remain runtime-only.

The host timer can refresh the named `knative-serving/controller` account only
when both its exact resource identity and static host grant match. A present
Secret must carry the host identity and delegated timer marker; unmarked or
foreign Secrets and conflicting pull references refuse rather than being
adopted. Secret replacement and account patching use API-server resource-version
conditions. This authority does not grant deletion, owner replacement, or
arbitrary account changes.

The generated host module binds both exact owner identities. Missing both fields
preserves the existing two-default-account policy; partial, duplicate or changed
bindings refuse during typed host compilation. Accepted legacy hosts and their
original reviews retain that legacy footprint. The implementation does not
activate a new closure or silently broaden an accepted host declaration. An
installed fresh-host expiry and private-image re-pull proof is still required
before safe-use acceptance. Existing-context platform upgrades remain deferred
until the initial feature set is complete and safe to use.


No-operation retirement still requires fresh native observations of its exact
retained identities. The execution registry must keep the immutable review's
retention and collection input keys even when no mutation operation selects
them. An empty mutation list cannot substitute blocked adapters for these
observation duties. Retention does not remove dependency history: a retained
release-history object that still names its Service blocks that Service's
collection. Do not erase the edge or infer deletion authority from retirement
alone; prove eligible collection separately.

The initial cloud foundation transaction owns the state bucket that will hold
the remote inventory. Its original journal therefore remains local until that
transaction converges. Public resume uses the same read-only authority discovery
as bootstrap: remote absence or a proved empty prefix permits local recovery
only for the exact active, published, payload-bound initial foundation review.
The review has an empty base, the sole cloud-foundation scope and only foundation
executor operations. Other local histories, foreign or incomplete remote
histories, and changed bindings refuse. Recovery retains the original review and
journal; migration follows successful convergence, never an active transaction.


## Amendment — 2026-10-01: review direct access relationships and complete portal synchronization

A direct En `app#viewer@user` relationship has a typed `AccessTuple` address and an independent Standalone scope derived from the accepted auth owner, exact hostname, and subject. Grant and revoke change that scope through the existing review and journal; they preserve application and platform-auth revisions. The auth Service and protected DomainMapping supply owner/UID guards. Revocation records desired absence, preserving the relationship's historical ownership rather than assigning authority over neighboring tuples. An existing unowned, caveated, userset, or ambiguous relationship is not implicitly adopted.

Observation uses a complete fully consistent exact-tuple query. The write carries the exact must-exist/must-not-exist precondition in the same atomic request as its insert/delete. This contract follows the registered upstream source at mori://shinzui/en/packages/en-servant. The runtime checks the service's published capability schema before admitting a write, because older request decoders can ignore unknown precondition fields. A lost acknowledgement is completed only by observing the exact desired tuple under the same reviewed owner identities; absence of that proof remains unresolved. Private bearer credentials are supplied at execution, never retained in public reviews or diagnostic bodies.

Portal synchronization composes the complete accepted backend and Shomei settings contributions through the auth owner's existing grants. It requires a converged auth scope, reads its Shomei Deployment from immutable accepted native evidence, and preserves every other auth member and contributing application scope. Only the two shared maps and a Pod-template rollout annotation may be prepared. The rollout depends on both maps and uses the existing conditional Kubernetes adapter, so running Shomei processes reload their ConfigMap-backed environment after synchronization. Replaying the same review preserves its rollout identity; a new explicit synchronization requests a new rollout. Native local/cloud acceptance remains part of EP-155/156, separately from the bounded HTTP and Kubernetes command fixtures.

## Amendment — 2026-10-01: collect retired application release metadata explicitly

A newly compiled application release-history ConfigMap is stateless with
`DeleteWhenUnreferenced` policy. Its ordering dependencies on the complete
workload stay in the accepted and retained declaration. Retiring the
application still retains the ConfigMap and every workload; it performs no
deletion. Once retired, an operator may separately review conditional
collection of the release-history ConfigMap, then collect eligible web
DomainMappings and Services after their remaining consumers are removed.
The immutable review and collection tombstone preserve the historical
identity and native evidence; collection is not a way to rewrite the
application's accepted release log or reuse its logical ID silently.

An already accepted `Retain` release-history declaration, including the
frozen MP-23 cloud fixture, has no retrospective deletion authority. It
requires a new reviewed application revision that changes the declared
policy while preserving the object identity and native bytes, followed by
retirement and distinct collection reviews. Exact UID, resource-version,
consumer and source checks still apply. A memory-store regression proves the
legacy-policy update, zero-effect retirement, premature Service-collection
refusal and ordered history/DomainMapping/Service collection with tombstones.
Installed conditional writes and source-data preservation remain
required native evidence before the safe-use cleanup gate can pass.

## Amendment — 2026-10-01: preserve manual backup evidence after Job collection

A completed manual backup Job may be replaced in its owning scope by a durable
receipt record only through a reviewed same-scope replacement. The record binds
the accepted producer revision and Job UID, exact object and receipt versions,
lengths and hashes, and the original backup identity. The Job is retained by
that replacement and may be collected only through a later conditional review.
An isolated restore can depend on the accepted record and stored bytes after
collection rather than on a Pod that no longer exists. It must verify the
producer incarnation against retained history or the collection tombstone and
read exact provider versions before preparing effects. A source or in-memory
fixture does not establish native deletion or restored-content acceptance.

## Amendment — 2026-10-02: validate real workflows through external-effect interpreters

Adopt Effectful incrementally at external request boundaries while retaining typed
ownership, immutable reviews, journal/history and conditional provider writes.
Production and test interpreters execute the same compiler, planner, adapter
parsing, preconditions and recovery logic. Tests replace external requests, not
successful high-level operation results. Models persist their world independently
of the journal, distinguish write acceptance from readiness, retain unknown
outcomes, and reject unsupported requests. Generated workload commands execute
locally with their declared environment and strict provider fixtures.

The first implementation is a Kubernetes request effect beneath the existing IO
runtime. It validates the boundary; it does not make the entire orchestration
effect-typed. Further effects are introduced only for a demonstrated workflow gap.
A broad conversion or a full provider emulator is not a prerequisite for MP-23.
The effect implementation uses mori://effectful/effectful/packages/effectful-core;
the native executor remains the default and simulation requires explicit injection.

Maintain contract fixtures for real interpreter commands/responses and bounded
native checks when underlying components change. Models cannot prove admission,
controllers, IAM, networking, database execution or future provider outcomes.
Simulation is neither mutation authorization nor native release evidence. Preserve
all current acceptance gates; move inexpensive defect discovery before cloud
iteration. See the [validated pilot](../audits/mp23-effectful-restore-pilot.md).

## Amendment — 2026-10-02: review controller collection as a distinct authority

An explicit `inventory collect --controller-descendants` review may authorize
Background collection of one retained Knative Service and its exclusive controller
descendants, including later-created descendants. It uses a distinct versioned
adapter identity and saves metadata-only graph evidence in the immutable native
member. The ordinary Kubernetes adapter and previously issued Orphan reviews keep
their original behavior. Field-reconciliation `Delegation` is not deletion authority.

Complete namespaced API discovery/listing must succeed before review and execution.
The observed descendant graph must contain only supported exclusive controller
children without independent inventory ownership. Parent UID/resourceVersion,
descendant identities/ownership and independently inventoried neighbors are checked
before the conditional parent DELETE. Descendant/neighbor status version churn is
permitted. Recovery uses the original review and history; parent absence alone
does not prove collection. Recorded descendants and observed new descendants
reachable from saved UIDs must be absent, with protected identities preserved,
before the transaction can record its tombstone. No direct child deletion or
finalizer patch is part of this adapter.

This grant delegates asynchronous GC; it does not promise an atomic exact set of
descendant UIDs. Kubernetes conditions only the parent mutation, namespace lists
are not a cross-resource snapshot, and new ownership edges can arise between
observation and deletion. Completion observation cannot find every unobserved new
chain after its intermediate owner disappears. The contract therefore relies on
trusted supported controllers and namespace writers. Exact-set deletion or hostile
concurrent ownership protection would require a different protocol. The public
summary must disclose the dynamic descendant scope. See the [contract and local
proof](../audits/mp23-reviewed-controller-collection-proof.md) for native acceptance
obligations and compatibility boundaries; local simulation does not close them.


## Amendment — 2026-10-02: disposable prerelease fixtures are not compatibility commitments

Nagare has no deployed users at this boundary. Its first inventory release starts
with fresh contexts, and completing it is required for production provisioning.
Recovery guarantees apply to supported operations on the accepted candidate;
they do not imply indefinite preservation or cross-version migration of every
failed development transaction.

A failed prerelease fixture may be retired from acceptance with its failure,
review, journal and observed identities retained as diagnostic evidence. This
administrative disposition must not rewrite an unresolved transaction as
converged, clear history beneath live partial effects, or count disposal as a
successful managed operation. Retired resources require scoped teardown based
on actual ownership, but their repair and continued live preservation are not
release prerequisites. In particular, MP-23 retires the old F15 Orphan deletion
instead of extending the product to rescue that review; [the disposition](../audits/mp23-prerelease-fixture-disposition.md)
records the exact boundary and cleanup owner.

Keep existing recovery regression coverage and demonstrate interruption,
fresh-process recovery, no duplicate completed effects, exact reviewed authority
and retained-data preservation on the candidate. Do not add compatibility code
or a generalized abandonment mechanism solely to rehabilitate development
fixtures. Candidate-bound native/local/cloud evidence and supported feature
acceptance remain mandatory. This exception for unused prerelease environments
is not a policy for discarding production transactions or user data.


## Amendment — 2026-10-02: critical intranet adoption requires recoverability and an upgrade path

The operator's outcome is a company intranet hosting critical developer tooling,
with maintainable releases and protected production data. The first inventory
release's fresh-context boundary is an implementation scope, not a claim that a
cluster lacking a supported upgrade path is ready for critical adoption. MP-21
owns the existing replacement-upgrade integration; keep the old coarse upgrade
runner blocked until a reviewed inventory-compatible transition is verified.

Before real company data is admitted, establish explicit recovery-point,
recovery-time and retention targets, off-cluster recoverable backups and durable
receipts, visible backup failures/staleness, and content-verified recovery when
the original cluster/operator root is unavailable. Recovery configuration and
credentials must survive independently through a documented secure procedure.
Periodic snapshots cannot guarantee zero loss of subsequently committed writes;
requirements for continuous recovery must be designed and proved explicitly.
The operator selected a recovery-point objective of at most one hour of data loss
after total cluster failure. The timestamp of the latest usable off-cluster backup,
including upload/verification delay, must meet that bound; schedule with retry
margin and expose freshness deterioration before breach. Recovery-time and
retention targets remain unagreed and may not be invented by an agent.
Existing scheduled-retention deferral does not waive protection of backup data.

Before critical adoption, prove the supported release transition and interruption
recovery on representative workloads, with restored-content checks and an explicit
rollback/forward-recovery boundary. Retain the last recoverable state before
irreversible migrations and prevent cleanup from deleting required recovery
material. Report tested compatibility and measured maintenance/recovery limits;
no blanket guarantee covers arbitrary future releases. Production data and
transactions are not disposable under the prerelease fixture policy above.

## Amendment — 2026-10-02: reviewed CDN requests and retained hostname ownership

Cloudflare purge is an immutable typed operation with a caller-selected request
ID. Empty paths select one accepted workload hostname; exact paths become HTTPS
URLs on that hostname. Whole-zone purge requires an explicit `--whole-zone`
review owned by the platform's zone grant, with the full blast radius displayed.
The saved native evidence binds the current provider identity/version and account.
A durable receipt binds provider request acceptance to both intent and native
review digests. Acceptance does not prove worldwide cache eviction. A lost
response without that receipt remains unresolved; redirects cannot automatically
resubmit mutations. This follows the [Cloudflare purge contract](https://developers.cloudflare.com/api/resources/cache/methods/purge/).

Retirement preserves workload DNS records. A separate collection may remove only
an exact retained stateless record whose accepted policy is
`DeleteWhenUnreferenced`, with no remaining consumers. Platform rules, origin
TLS, apex and neighboring hostnames are outside that deletion authority.
Google deletion uses the exact old value/TTL in an [atomic DNS change](https://docs.cloud.google.com/dns/docs/reference/rest/v1/changes/create).
Cloudflare checks the observed ID/version and deletes the [exact record ID](https://developers.cloudflare.com/api/resources/dns/subresources/records/methods/delete/);
its API does not supply a conditional version token. These are provider-specific
preconditions, not a promise of atomic protection from every external writer.
Unknown deletion responses recover only from confirmed absence, never by
resending. Policy-only convergence with an unchanged provider target performs no
provider write. Old `Retain` declarations require a reviewed policy change before
retirement; the collector does not reinterpret their policy.

The legitimate same-owner DNS/DomainMapping hostname pair uses the same exact
pair-validation rule in desired composition and retained history. Either retained
member continues reserving that hostname until separately collected. Withdrawing
the last namespace contribution preserves its exact `Retain` declaration in the
surviving platform owner. A returning contribution replaces only an identical
carried declaration; a changed or independently authored claim still conflicts.
This preserves ownership without fabricating historical scope revisions or
making workload retirement delete platform namespaces.


## Amendment — 2026-10-02: reviewed host inputs and credential replacement

Host configuration and credential commands use the existing host scope and
activation executor. Explicit `host plan` may replace operator inputs, while
bootstrap still requires an identical accepted host. A transition preserves the
accepted dependency lock and Nix preparation refuses lock updates; it is not an
admitted-context payload upgrade. `host apply` accepts only a host-only review.
Compatibility shell switching must pass the same substantive-history refusal as
legacy CLI mutations before it can reach a provider.

A replacement review carries the exact observed previous age-key digest alongside
the desired digest. The optional field is absent from old plan serialization, so
existing saved version-one plan bytes and completion proofs retain their meaning.
Credential receipt authority uses native plan version two so older operators refuse
it rather than silently ignoring the required activation proof. Preparation
requires explicit replacement intent; apply rechecks the prior value in the same
remote invocation that streams the key. This is not atomic CAS against unrelated
root writers. Private key bytes remain operator inputs, never review contents.

Explicit credential reviews, including an already matching new key after an
abandoned failed transaction, require a private remote receipt bound to the
entire native plan, written only after both secret-service activations return successfully.
Inspection requires this receipt as well as the new key and fresh SSH evidence:
an old healthy Tailnet session cannot certify a failed new secret activation.
An interrupted activation can retry with the already written desired key without
rewriting it. Changed keys or failed writes remain unresolved for explicit
recovery. The receipt is an internal host-executor artifact; it grants no new
scope or independent credential owner.

Credential receipt authority is also a transport capability: a credential-required preparation and every v2 native inspection or activation use host transport request protocol v3. This requires both credential receipts and argv-preserving SSH delivery. A retained payload supporting only an older protocol refuses before effects; the operator cannot delegate a stronger saved plan to a shell that silently ignores its authority fields. Historical v1 requests remain unchanged.


### Reviewed Compute Engine power transitions

Power is a one-shot operation on the existing platform-owned Pulumi instance,
not a replacement host or a boot-image change. Its immutable operation ID and
content-bound context address survive ordinary cloud drift repair. The native
review pins the observed numeric instance ID and stable before/after states.
Preparation uses the accepted cloud inventory and Compute API; execution keeps
static release, ADC and project checks without requiring the guest or Kubernetes
to be reachable. Only power operations and cloud verification may use this path.

The name-based provider API has no atomic incarnation precondition: identity is
rechecked before the request and when proving completion, without claiming CAS.
Already-desired state is effect-free. An uncertain request is never automatically
resent; original-transaction resume either proves the desired state on the same
instance or retains an unresolved outcome. This proof does not assert guest or
application health, which the operational runbook verifies separately.

A successful outcome publishes an immutable shared receipt binding the original
native plan and observed incarnation/state. A later plan for the same operation
ID retains that exact plan, and execution verifies the receipt before considering
provider work. This prevents an old stop from running again after a later start
and an unrelated unconverged revision. The receipt proves historical one-shot
completion, never current power readiness; malformed or conflicting receipts
refuse. Receipt-write acknowledgement loss recovers from the retained bytes.


### Reviewed local context control

A per-operator profile is local control metadata, not a new cloud ownership scope.
Its reviewed update/removal binds exact prior bytes, local path, context, selected
history root and idle head. Initial cloud foundation records its proven local
origin separately from the profile’s future GCS locator. Before effect the CLI
rediscovers that authority; restoration requires the recorded original head and
refuses migration markers, without creating missing history or guessing from
remote denial. This initial local authority permits only foundation scopes and
no retained/collected incarnations. Operational input changes leave provider state unchanged until a
subsequent inventory review. Project, store, payload and resource identity changes
refuse; inventory store migration retains its separate authority protocol.

Replacement profiles contain only canonical single-quoted exports. The decoder
rejects extra commands, unrecognized fields and values the profile parser cannot
round-trip safely; shell substitution remains literal data. Historical original
bytes stay exact for restoration.

Local control serializes through a process lock and retains an immutable intent,
completion receipt and original profile. File and directory synchronization order
those records before replacement/removal; interrupted completion is proved from
exact after-state bytes. A completed review never reapplies after a later local
change. Removal publishes a tombstone before unlink and prevents fresh creation
from hiding the old history. Explicit restore checks the original store binding,
refuses migrated authority or conflicting files, and restores the exact profile.
It may restore access to an active transaction without modifying its history.
The protocol claims local process exclusion, not exclusion across workstations;
other operators retain their own profiles and shared inventory transactions.

### Read-only artifact observation across payload versions (2026-10-02)

Host image planning may inspect a named immutable builder output, but that
inspection cannot implicitly start the builder. Unavailable transport is unknown,
not absence. Inspection uses an explicit read-only proxy capability; an older
accepted payload that cannot honor it must refuse before target/provider work.
BuildJob artifact requests require outer transport version 2, including recovery
observations and publication preflight. Other artifact kinds retain version 1.
This capability check belongs at the accepted payload boundary as well as in the
current CLI: updating the operator alone does not update an older payload script.
Image build/publication remain separate reviewed stages, with image-link config
and VM changes owned by subsequent bootstrap reviews. Nix evaluation and builds
cannot update the selected host lock file.

A completed local profile removal retains the validated original profile as a
read-only store-opening capability. Restoration cannot depend on rereading the
removed profile. It still verifies the retained store's project/bucket ownership,
existing format and context-bound head, and refuses migration or missing history;
it never initializes a replacement store. Ordinary store-opening paths continue
to require the persisted profile and agree on both project and remote URL.

Release-history cleanup derives its ownership from accepted application/site
ConfigMaps and their digest-bound private native bytes. It changes only the
release log, retaining both the current entry and the requested recent window.
The review's preparation guard permits only those exact conditional updates and
verification; unrelated drift repair, creates and hook execution require a
separate review. Other cleanup families retain their own lifecycle gates.

SSH file delivery serializes each remote argument as a literal shell word before
passing one command string to OpenSSH. Local argv boundaries alone do not survive
SSH: empty prior-key digests and multiline `bash -c` scripts must remain distinct
arguments. Regression tests execute the joined remote command through a shell,
including real credential retry logic, rather than directly executing an argv
stub. A failed disposable development payload remains immutable diagnostic
evidence; verify the corrected payload on a new disposable fixture instead of
patching the old payload or inventing an in-place upgrade path.

Stale-preview cleanup validates the accepted preview scope's complete shape and
reads its exact Service creation time and UID. Retirement review observes that
same incarnation again, and ordinary admission guards it before recording the
retirement. Retirement retains every member; later cleanup reviews one eligible
retained stateless member at a time, respecting active and retained consumers.
Knative Service collection uses the existing reviewed controller-descendant
protocol. Retained selection also validates the original immutable scope revision and exact member declaration against the complete preview contract; a scope-name prefix is never sufficient authority. Explicitly retired previews need no second TTL delay. Durable volumes
remain retained regardless of preview age. Cleanup preparation cannot repair
unrelated drift or run hooks.

Release-history pruning supplies private native bytes for exactly the unchanged
Kubernetes/Helm members selected by the final planner requirements, alongside its
changed history bytes. Contribution-generated members remain the contribution
compiler's responsibility. A same-scope neighbor is not necessarily backed by a
packaged manifest; its accepted native evidence must be retained for verification.

Host image-cache cleanup records one forward-only declared operation per full CRI
image ID, bound to the accepted platform VM and its numeric Compute incarnation.
The native plan includes every current image alias; changed aliases, pinned
images, running or stopped container references, ambiguous alias ownership and
unreadable CRI evidence refuse removal. The remote request independently checks
the metadata-server instance ID and current references, then removes only that
full ID with transport retries disabled. It never runs a mutable prune selector
or deletes published registry artifacts. CRI offers no atomic unused-image CAS:
a container can start between the last observation and removal, and disk space
reclamation is asynchronous. This is derived-cache cleanup, not a data-retention
guarantee. Durable completion receipts survive store export/restore and prevent
an old request from deleting a later re-pull. An ambiguous still-present removal
remains unresolved and is never automatically resent.

Cloud teardown first reviews an exact metadata-only `Protect` to
`DeleteWhenUnreferenced` transition for the finite supported stateless types.
Only an otherwise identical declaration with a fresh present observation gets
verification-only authority. Ordinary bootstrap never loosens protection.
A separate cloud scope retirement preserves native resources and original private
scope revisions. Collection remains one exact eligible retained leaf at a time;
active and retained consumers retain their full dependency authority. Data,
credential, artifact and provider/store authority are never implicitly collected.
GCE deletion protection remains a separate native guard that this path cannot clear.

Cloud collection uses ordinary saved `pulumi preview`/`up --plan` with a versioned
registration omission set, never raw `destroy` or mutable dependent selectors.
The full registration bundle remains the ownership authority. The omission set
and all earlier cloud tombstones contribute to the program fingerprint; the
selected payload must declare the matching protocol capability. Unselected
children, unknown types and replacement or unrelated mutations refuse. Fresh
exact absence proves collection completion; a no-change preview alone cannot.
An ambiguous still-present delete remains unresolved. Conservative retained
layer dependencies can leave stateless infrastructure blocked; the public report
names that retained outcome and does not claim complete physical teardown.
