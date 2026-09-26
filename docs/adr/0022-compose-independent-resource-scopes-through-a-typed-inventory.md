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

Accepted as the architecture for MasterPlan 23 on 2026-09-16 following the operator's design discussion. Implementation is not yet complete; the existing command behavior remains as described in the earlier ADRs until its migration is verified.

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
managed contexts can use that route. The CLI guard alone did not protect it.

The same initialized-store boundary applies to live Task commands. Manual
execution requires an accepted CronJob and a stable `--run-id`, which gives its
Job a reviewed identity and retry receipt. Direct schedule deletion has no
reviewed retirement operation yet, so it refuses. Plan-only and dry-run Task
output remain available; an uninitialized context retains the legacy commands.

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
