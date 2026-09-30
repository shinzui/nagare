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

Accepted as the architecture for MasterPlan 23 on 2026-09-16 following the operator's design discussion. Implementation is not yet complete; the existing command behavior remains as described in the earlier ADRs until its migration is verified. The 2026-09-28 amendment below is the current MP-23 release boundary and supersedes earlier blanket full-feature acceptance statements where explicitly narrowed.

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
initialized, including for a new hostname. Their reviewed operations and
recovery policy remain M3 work; read-only inspection and CDN dry-runs remain
available.


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
