---
id: 150
slug: integrate-resource-inventories-into-upgrades-and-release-verification
title: "Integrate resource inventories into upgrades and release verification"
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
      at: 2026-09-25T20:16:27Z
      mode: "implement"
      note: "Started integration audit and guarded legacy upgrades for inventoried contexts"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-26T00:11:09Z
      mode: "implement"
      note: "Made future upgrade transactions inspectable and declared supported inventory wire minimums"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-26T00:48:01Z
      mode: "implement"
      note: "Guarded legacy Pulumi mutations and added redacted inventory evidence projection"
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-26T02:49:40Z
      mode: "implement"
      note: "Closed unscoped context profile and cleanup writes after inventory admission"
---

# Integrate resource inventories into upgrades and release verification

This ExecPlan is a living document. Keep its living sections current and promote durable decisions into docs/adr/.


## Purpose / Big Picture

The shipped Nagare operator can create a fresh inventory-backed context,
render its complete inventory, review a change, apply it, recover interruption,
and explain final ownership across cloud, host, cluster, data, credentials,
artifacts, and control metadata. Application and platform scopes have separate
ownership. A disposable-context rehearsal proves convergence, a no-op rerun,
and policy-correct component removal. The first release does not promise an
in-place platform version change for an admitted context.

Release evidence archives the inventory, review, receipts, and final observations under one immutable payload identity. Complete coverage and removal of obsolete policy paths are release acceptance conditions.


## Progress

- [ ] M1: Converge a fresh platform context and confine legacy upgrade paths.
- [ ] M2: Package contracts and audit all supported mutation paths.
- [ ] M3: Run deterministic and disposable-context convergence/recovery scenarios.
- [ ] M4: Archive release evidence, document recovery, and finish ADR distillation.

2026-09-26: The operator confirmed every existing Nagare context and its data
can be discarded and recreated for the first release. M1 no longer requires a
new in-place `platform upgrade` transaction or conversion of old phase
journals. First-release acceptance is a fresh context selected from one
immutable payload, reviewed component bootstrap, receipt-backed recovery,
final marker verification, and refusal of legacy mutation after inventory
admission. The old transaction remains inspectable; the original payload is
the recovery path for a legacy context kept outside this release claim.
In-place platform version changes for an admitted context are deferred and
must be designed before the next version transition. M2-M4 coverage, live
local/GCP evidence, and immutable release evidence remain required.

2026-09-26: Extracted the complete platform bootstrap candidate builder so it
accepts explicit payload paths and a retained workspace. The bootstrap command
uses the selected payload. Final composition
rejects any application, standalone, or publication scope change, preserves
their accepted generations, and uses the shared graph validator to refuse a
target platform that breaks their dependencies. The focused inventory suite
passed 192 tests, including changed-application and broken-platform-dependency
refusals; the CLI built and Haskell style passed. The builder checks payload
and retained workspace identity before compilation. This is preparation for
fresh-context M1, not full bootstrap acceptance: production cloud/host
declarations and live receipt-backed convergence remain open.

2026-09-26: M2 audit found two unscoped mutation families beyond the earlier
Pulumi guard: confirmed `cleanup` could delete stale preview Services and rewrite
release-history ConfigMaps, and context replacement/deletion could change or
remove the profile selecting the inventory store and project. Existing `init
NAME`, `context create --force`, `context delete --yes`, and `cleanup --confirm`
now refuse when the old selected context has substantive inventory history.
Fresh context bootstrap and cleanup dry-run remain available. A public-CLI
regression with a canonical history head proves all four refusals before any
provider process, confirms profile/history retention, and allows deletion when
the head is initialized but untouched. The CLI build, targeted Darwin Nix
entrypoint check, Nix shellcheck gate, Haskell style check, strict user docs,
and diff check pass. The coverage catalogue, user docs, and ADR 22 record the
compatibility boundary.
This does not complete M2: these families are explicitly unavailable after
admission and still need reviewed implementations for full command coverage.

2026-09-26: The same audit found unnamed `init` could still write a checkout
profile and enable project APIs under an explicitly selected admitted context.
It now checks that context's old inventory store before preflight. The public
CLI regression covers this fifth refusal, including retention of the profile
and history; fresh bootstrap remains eligible. The CLI build, targeted Darwin
Nix entrypoint check, Nix shellcheck gate, Haskell style check, strict user
documentation, and diff check pass.

2026-09-26: M2 host credential audit found `host place-age-key` still streamed
private key material to the VM after inventory admission. It now refuses at
the selected context's history boundary before workspace resolution or key-file
read. The public CLI regression covers this sixth refusal and exact unchanged
profile/head bytes. A reviewed host credential operation remains open; the
legacy path is available only before admission. The CLI build, six-refusal
public regression, targeted Darwin Nix entrypoint check, Nix shellcheck gate,
Haskell style check, strict user documentation, and diff check pass.

2026-09-25: M2's compatibility boundary now also refuses legacy `infra apply`
and `infra destroy` after the selected context has substantive inventory
history, an executor claim, or a store migration. The common head predicate
keeps an initialized but untouched store eligible for the old guarded path.
A focused Haskell test and executable build pass. Direct application/data
paths and the full command-registration audit remain open. The full 829-test
`nagarectl` suite, release consistency source Nix check, Haskell style check,
strict user-documentation validation, and diff check pass.

2026-09-25: M4 has a public evidence projector for a verified disposable
rehearsal and a separately held private store export. It checks the original
review and no-op review, accepted/converged vector, committed journal members,
the exact review transaction's completion receipts for every reviewed
operation, matching operator source
revision and payload identity, and a
complete coverage result. Output contains only selected public fields and
digests; the launcher can export private history outside its public evidence
directory. The projector's idempotence, redaction, coverage-refusal, and
tamper tests and the release consistency suite pass. Release assembly and the
checked publisher can include it as an eighth immutable product, but the
workflow does not yet require it. Live provider evidence, full coverage, and
native-system release gates remain open.

2026-09-25: M1 compatibility boundary now reads schema-1 upgrade transactions
as before and exposes a future transaction's context, ID, target, and schema
through `platform upgrade status` without interpreting its phases. Apply,
rollback, and recovery refuse the newer wire. Release payloads declare minimum
inventory and upgrade-transaction schema versions; the current CLI refuses a
target requiring more than version 1. The 34 focused platform tests, CLI build,
release consistency suite, Haskell style check, strict user docs, and diff
check passed. This remains partial M1:
component-backed platform upgrades and legacy transaction recovery compatibility
are not implemented.

2026-09-25: Read-only `inventory store status` now reports a canonical newer
head's schema and digest as `unsupported-schema` without decoding ownership or
executor claims. The full store reader still refuses the newer head for
mutation. A focused store test and CLI build pass. This closes only the
unsupported-schema discovery slice of M1, not platform integration. Haskell
style, strict user docs, and diff checks also pass. The full `nagarectl` suite
passed all 828 tests after these changes.

2026-09-25: Integration audit found that `runPlatformUpgrade` still applies the
coarse Pulumi, host, and whole-cluster phases, while EP-148 still has direct
application/data mutation paths. As an interim M1 safety boundary, the legacy
upgrade command now reads the selected context's inventory history before
planning or applying and refuses if accepted, retained, collected, or active
transaction evidence exists. The `nagarectl` executable builds. This does not
complete M1: a component-backed upgrade path and legacy recovery compatibility
are still required. The 818-test `nagarectl` suite, Haskell style check,
strict user-documentation validation, and diff check passed.

2026-09-25: M4 provider protocol probe used the separately authorized private
repository `shinzui/nagare-release-recovery-probe-01a0da30`, annotated tag
`v0.0.0-ep150-probe` (tag object `9dcaf1e32e079c1f36026e38b65c8745c12aaf13`),
release ID `396903067`, and one 12-byte product asset. The draft listed its
tag, machine-readable body, asset ID `589172376`, `uploaded` state, and
SHA-256; downloading that exact asset ID reproduced the candidate digest.
A digest-addressed pre-publication receipt was uploaded as asset ID
`589176676`, then the same release ID published with `immutable: true`.
An attempted unreviewed upload received HTTP 422. This establishes provider
primitives and limits for the adapter; no Nagare release was published. The
test repository remains private as provider recovery evidence; no cleanup has
been run.

2026-09-25: The new `GitHubRelease` adapter and `release publish` command
replace direct workflow publication. The review binds the annotated tag
object, commit, repository, pre-generated notes, seven EP-146 artifact
declarations, and exact bytes. The draft body establishes an immutable intent;
verified product IDs are recorded in a digest-addressed receipt before
publication. The CLI recovered release ID `396912196` for private tag
`v0.0.1` after an initially invisible draft and a failed first upload,
verified all eight physical assets, then published it. A fresh clone with
only the candidate files repeated the command without writes and returned
the same release and asset IDs. Changed same-tag notes/bytes and a tampered
local checksum set refused. A separate `release cleanup-starter` command
requires the exact draft release and failed placeholder asset IDs; its fake
provider test passed, and the live command refused an attempted cleanup of a
published asset without deleting anything. The six focused fault-injection
tests, full 825-test CLI suite, 458-test DSL suite, Pulumi build/tests,
release consistency tests, Haskell style, strict user docs, and workflow YAML
parse passed. M4 remains open for inventory evidence and full release gates.
The publisher also reconstructs a canonical local completion observation from
the verified provider release and physical asset IDs; the workflow archives
that observation outside the immutable release attachments.
The fresh checkout retried the already published private probe and wrote this
observation with the same release ID `396912196`, eight asset IDs, and review
digest `bae8ae74986811c2ce8bc4297e073d5c2cf9bc29fc433ca49417afdf73f4a6b0`.

2026-09-25: M3 deterministic multi-scope recovery now has a focused test for
platform, two applications, and cache. All four lost-acknowledgement positions
resume without duplicate effects; the unchanged review is a no-op, and retiring
one application retains its resource while other accepted revisions remain
fixed. The provider-backed local and GCP scenarios remain open.

2026-09-25: Added `scripts/rehearse-managed-resources.sh` with separate plan,
apply, and verify phases. It requires exact context/cluster identity, checks
the cloud project through the operator guard in cloud mode, retains the public
candidate and review before `--yes`, and requires a fresh post-apply candidate
whose review has zero operations. Local mode makes no cloud preflight call. Its
fake-CLI test covers successful phases, existing-evidence refusal, missing
confirmation, wrong cluster/project, and non-no-op refusal; shell syntax,
strict user docs, and diff checks pass. An interrupted apply remains marked
`applying` and refuses a blind second apply; the operator must inspect/resume
the transaction. This is launcher preparation, not a
provider-backed disposable rehearsal, so M3 remains open.

2026-09-25: Distilled the durable provider-draft, physical-asset verification,
and completion-observation rules into ADR 7. This records the publication
boundary without treating the pending inventory release evidence as shipped.


## Surprises & Discoveries

2026-09-26: The old `cleanup` runner did not inspect inventory history before
performing confirmed preview deletion and release-log trimming. Context
replacement and deletion also lacked a guard despite the profile selecting the
history store. A canonical fixture head with generation 1 reached the public
CLI and refused all four operations; the first fixture attempt exposed the
store's private-file mode requirement, so the regression sets head mode 0600.

2026-09-25: The current release workflow still creates a published release
through `softprops/action-gh-release` after treating any failed `gh release
view` call as absence. It has no provider-durable draft binding or recovery
from partial asset uploads. The publication adapter must replace that path
before release evidence can be claimed complete.

2026-09-25: EP-148 remains open on full application membership, operational
and data command cutover, and direct-path removal. This is a hard input to M2
coverage completion, not evidence that EP-150 can exclude those commands.

2026-09-25: The operator selected `tan-ng-labs` for later live rehearsal, but
a read-only GCP check found a running `nagare-01` VM there and the saved `labs`
context targets that name. Do not use that existing context or VM as a
disposable fixture. A live scenario needs a separate, uniquely named context
and exact resource identities before any write. The operator clarified that
`tan-ng-labs` is intended for Nagare once stable, so the project itself and
its standing resources must be preserved. No GCP write has been made in this
implementation session.

2026-09-25: Read-only review of the cloud Pulumi topology found that a second
context would still default to the project-wide `nagare-node` service account,
`nagare` Artifact Registry repository, and context-independent backup bucket
name. The current program does not expose a service-account ID override. A
GCP rehearsal cannot safely use those defaults in `tan-ng-labs`; it needs
explicit unique identities, a preview proving no existing resource is
targeted, and a reviewed cleanup set before any apply. An optional
`nagare:serviceAccountId` Pulumi setting now allows the rehearsal stack to
use a separate node account while preserving the original default. Bucket,
registry, VM, and domain overrides are already available; this does not yet
constitute a reviewed, executable GCP rehearsal.

2026-09-25: M2 documentation audit confirmed ADR 13 already has EP-151's
GCS-inventory amendment and records the isolated two-state-root rehearsal.
The disaster-recovery guide still called that rehearsal pending and described
local export without a restore command. Added `inventory restore --from`
with a read-only binding review, explicit `--yes`, empty-local-store refusal,
and a digest-checked restore that rechecks the context/project binding from
the verified backup immediately before writing. Context, reference, and
backup guides now explain export/restore and the GCS evidence accurately.
This does not establish the full M2 mutation-path coverage.

2026-09-25: Read-only `gcloud` listings confirmed the standing physical names
in `tan-ng-labs`: `nagare-01` (running in `us-west1-a`), `nagare-node`, the
`nagare` Artifact Registry repository, `tan-ng-labs-nagare-{backups,images,
nix-cache,pulumi-state}` buckets, and the `labs.topagentnetwork.net.` DNS
zone. The operator offered to delegate `ep150.labs.topagentnetwork.net` for
the separate rehearsal. The fixture still needs distinct resource IDs, a
read-only Pulumi preview, and a reviewed creation/cleanup set. No GCP mutation
or cleanup has occurred.
The Pulumi perimeter creates a new Cloud DNS managed zone for its configured
base domain. A production-shaped test under `labs.topagentnetwork.net` therefore
also needs an exact NS delegation record in the standing parent zone; that
parent-zone change belongs in the reviewed creation and cleanup set.

2026-09-25: Prepared a local-backend, read-only Pulumi preview for stack
`ep150-preview` in `tan-ng-labs`, with domain
`ep150.labs.topagentnetwork.net`, VM and service account `nagare-ep150`,
registry `nagare-ep150`, and buckets
`tan-ng-labs-ep150-pmkjjpp-{backups,images}`. Read-only provider checks found
none of those exact names. The initial preview included seven project API
resources already enabled in the standing project, so a new optional
`nagare:manageProjectApis` config setting now excludes those shared ownership
claims when set to `false` on the second stack; its default remains `true`.
The revised saved preview proposes 27 creates and no update/delete/import,
with SHA-256 plan digest
`2aeb41e0d665f6b558a719fb703dac0af903de475595a0942c3acfaa966f2971`.
It still adds two project IAM members for the new account and requires an
exact parent-zone NS delegation after creation. The saved native plan is
private under `/tmp/nagare-ep150-preview`; no cloud apply or cleanup occurred.
An isolated local `ep150-preview` context names a separate, currently absent
`tan-ng-labs-ep150-pmkjjpp-state` bucket for its future Pulumi and inventory
GCS prefixes. That bootstrap bucket is not part of the 27-create perimeter
preview and needs its own bounded review before any live run. The disabled
Nix cache still has a distinct reserved bucket name in both the context and
Pulumi fixture, avoiding a fallback to the standing cache bucket.

2026-09-25: In the private GitHub draft probe, PATCHing only the body changed
`tag_name` from the reviewed tag to an internal `untagged-*` name while
preserving the release ID and uploaded asset. PATCHing `tag_name` restored the
binding; the final publish PATCH supplied the exact tag, body, target commit,
and title together. Treat any body/tag mismatch as an unknown or foreign
provider state and refuse rather than trying to reconstruct the intent. A
32,775-character draft body round-tripped, so a bounded envelope below 32 KiB
is feasible. GitHub documents at most 1,000 assets per release and less than
2 GiB per asset; actual release assets will be much smaller. GitHub may
normalize unsafe filenames, so the adapter must constrain names before
review. A repeated same-name upload refused, and publication under an enabled
immutable-release policy refused a new asset with HTTP 422.

2026-09-25: The Darwin `nix flake check` first failed a baseline ACME URL
guard because it scanned vendored cert-manager YAML and a test fixture.
Exempted only the guard itself, that fixture, and the upstream vendor directory.
The next run exposed a missing `jq` build input in the inventory transport
guard check; added it to that check's Nix inputs. Full flake validation must
be repeated after these check repairs.

2026-09-25: The repaired flake check then reached `nagare-dsl` and found that
the pinned Nixpkgs GHC 9.12.4 set has
`mori://kazu-yamamoto/crypton/packages/crypton` at 1.0.6 while the package's
original bound was `>=1.1.5 && <1.2`. Mori located the dependency source;
Hackage source manifests and upstream tags for 1.0.6 and 1.1.5 were checked.
The DSL imports only `Crypto.Hash`'s `Digest`, `SHA256`, and `hash`, all present
in 1.0.6, so its minimum bound now admits the pinned version while local Cabal
continues to test 1.1.5. A package-set-wide 1.1.5 override conflicted with
the older `crypton-x509` bound (`<1.1`), and a scoped override caused Cabal's
multiple-version configure refusal through TLS; both overrides were removed.
The isolated DSL check also found a test fixture reading a repository-relative
cache manifest; its Nix `postPatch` now points to the packaged directory.
The Nix CLI check then exposed repository-relative cluster and DSL test fixture
paths, so its checked package now binds those tests to packaged source paths.
The targeted Darwin `nagarectl-build-test` now passes all 825 tests inside Nix
after adding the required Helm and OpenSSL test tools and placing Helm's cache
under the build directory. The full flake check then found four shipped example
configs missing the DSL's required `logicalKey` field; the repaired
`examples-compile` check passes. The next full check reached the Fourmolu gate,
which reports differences in many untouched Haskell files. The local AST style
check, strict user docs, and release consistency checks pass; full flake
validation remains incomplete.

2026-09-25: Added `InventoryIntegrationSpec` with a compiled platform scope,
two application scopes, and a cache scope. A recording adapter injects a lost
acknowledgement after every possible operation position in fresh stores, then
checks exact once recovery, a no-op rerun, and retained removal of one app
without changing the other three scope revisions. The focused test passes.
This is deterministic M3 evidence, not the local/live provider rehearsal or
the remaining upgrade and mutation-path integration.

2026-09-25: A private store export can contain uncommitted journal objects
beyond the head sequence. The public evidence projector includes only events
below the committed head sequence and only completed operations for the
transaction derived from the reviewed document digest. It also requires that
transaction's committed convergence event; merely counting journal files
would overstate the run's receipt evidence.


## Decision Log

2026-09-26: First-release admission starts with fresh inventory-backed
contexts because the operator confirmed all existing context resources and
data are disposable. A dedicated in-place `platform upgrade` command and old
transaction conversion are not acceptance gates for this release. Preserve
read-only historical inspection and the current refusal after inventory
admission. Require a separately reviewed platform transition before any
admitted context changes payload version later. This supersedes the 2026-09-16
context-pin and 2026-09-25 component-upgrade implementation choices below for
the first release, while preserving their historical rationale.

2026-09-26: Treat context profile replacement/removal and confirmed legacy
cleanup as unavailable once inventory work is admitted. They lack the typed
review and exact ownership evidence needed for safe operation; an initialized
but untouched store remains eligible for bootstrap compatibility. Restore their
availability only through reviewed owner-specific commands, not a raw bypass.

2026-09-26: Apply the same boundary to direct host age-key placement. A private
credential stream is a host provider effect, and force/idempotence checks alone
are not a substitute for a reviewed operation and journal receipt.

2026-09-16: Do not advertise a complete authoritative inventory while supported commands or installer scripts bypass its protocol. Partial migration is an explicit development state.

2026-09-16: Preserve the old context version until all required target components verify. An application change never advances that platform pin.

2026-09-16: Validate release integration without publishing a release or upgrading a live operator context as an incidental implementation step.

2026-09-25: Until upgrade phases use reviewed component receipts, refuse the
legacy upgrade command for a context with substantive inventory history. A
guarded refusal preserves the old context pin and prevents the coarse replay
from bypassing accepted scope ownership; it does not migrate an existing
transaction or claim M1 completion.

2026-09-25: The release publication adapter must create the draft with its
complete immutable body, avoid later body edits, and include the reviewed tag
explicitly in the final publish request. This follows the draft PATCH probe,
which showed that an omitted tag can detach the draft from the intended tag.
The pre-publication receipt stays an additional asset rather than a
self-hashing product member.

2026-09-25: Inspect future upgrade transaction schemas only as an identity and
version header; never decode their unknown phases into executable records.
Current payload compatibility minima are both version 1, with an absent field
in older payloads interpreted as 1. A future payload requiring more is refused
before planning or applying the coarse legacy transaction.

2026-09-25: A newer canonical inventory head may reveal only its wire version
and digest through read-only status. The supported full decoder remains the
sole mutation path; status must not infer ownership or executor state from an
unknown schema.

2026-09-25: The live rehearsal has distinct plan, apply, and verify invocations.
The first compiled candidate carries the pre-apply snapshot, so no-op proof
requires recompiling the same desired intent against the accepted post-apply
snapshot. Keep the original evidence directory and reviewed bytes across all
three invocations rather than silently regenerating a changed apply review.

2026-09-25: Once a context admits inventory work, the old coarse Pulumi apply
and destroy paths close alongside the old platform upgrade. A public release
evidence manifest is a strict projection of a verified run and private export;
the export remains outside public artifacts. A complete coverage result is an
input to projection, and the projector is not itself evidence that coverage or
the live rehearsal has been achieved.


## Outcomes & Retrospective

Not implemented. Completion requires recorded disposable-context evidence and no unaccounted supported mutation path; passing mocked tests alone is insufficient.


## Context and Orientation

Hard dependencies are [the shared inventory store](151-store-inventory-history-in-the-context-state-bucket-with-conditional-writes.md), [cloud/host/artifact adapters](146-reconcile-cloud-host-and-artifact-resources-through-inventory-adapters.md), [cluster components](147-compile-cluster-bootstrap-into-owned-resource-components.md), [independent application/data commands](148-route-application-and-data-lifecycles-through-independent-resource-scopes.md), and [lifecycle/status](149-explain-drift-and-execute-reviewed-adoption-migration-and-retirement.md). Their foundation is the shared typed model and immutable store/executor from EP-144/145. Each scope has accepted and converged revisions; resource history survives retirement; a native executor group may cover many declarations.

cli/nagarectl/src/Nagare/Platform/Upgrade.hs and app/Main.hs:upgradeOps currently use fixed Pulumi/host/Kubernetes/stamp/context phases. KubernetesApply replays the whole bootstrap. Platform/Status.hs reports five release identities. Platform/PulumiReceipt.hs skips proven cloud work without provider access. Platform/Paths.hs and Workspace.hs package/materialize payloads. nix/platform-package.nix, nix/nagare-packages.nix, nix/checks/{haskell,infra,platform,scripts}.nix, release.json, scripts/check-release.sh, scripts/test-release.sh, scripts/assemble-release.sh, and scripts/rehearse-clone-free-release.sh own distribution/verification. Inspect the actual release workflow under .github/workflows before editing its artifacts; this plan does not authorize publication.

.github/workflows/release.yml currently assembles deterministic attachments, compares existing complete releases, and publishes through softprops/action-gh-release. Its Actions artifacts expire after 14 days, and its retry path cannot recover a partially uploaded release. This plan owns migration of that actual publisher as well as evidence assembly; merely inventorying its resulting artifacts leaves a mutation bypass.

[ADR 4](../adr/0004-separate-immutable-platform-payloads-from-context-workspaces.md) separates private state and payloads. [ADR 6](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md) governs final context commit. [ADR 7](../adr/0007-publish-immutable-nix-releases-from-validated-tags.md) requires immutable tag/native evidence and separates publication from context mutation. [ADR 18](../adr/0018-the-upgrade-transaction-is-as-guarded-as-the-recipes-it-replaces.md) binds review/receipts. [ADR 19](../adr/0019-replacement-cutovers-reserve-rollback-before-write-admission.md) keeps replacement cutover separately gated. [ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) is the agreed inventory architecture.


## Plan of Work

### M1 — Fresh platform bootstrap and legacy boundary

Create the first inventory-backed context from one selected immutable payload.
The context pin is set during creation and must match that payload. Compile
cloud, host, cluster, cache, credential, artifact, and control declarations
before external mutation. Review and apply through EP-145's component journal
and EP-146/147's production adapters. Apply the cluster version marker only
after required component receipts and readiness checks verify. The marker
binds the accepted inventory digest and revisions to the payload identity;
status must distinguish partial bootstrap from completion. A repeat of the
same declared intent must plan no unintended writes.

The platform candidate composes against the full context snapshot, permits
only platform-owned scope changes, and preserves all application, standalone,
and publication revisions. It validates their dependencies even though the
first release accepts only a fresh platform version. A changed payload or
context pin after inventory admission refuses platform mutation until a
separately reviewed in-place version transition exists. Application-only
changes never advance the platform pin.

Keep old upgrade transaction bundles inspectable without translating their
phase text into component receipts. The coarse `platform upgrade` path and
other legacy platform writers refuse after inventory admission. Untouched
legacy contexts remain an explicit compatibility surface outside the fresh
inventory-backed release claim; recovery of an old transaction uses its
original operator payload. No first-release acceptance test requires an
in-place upgrade of those disposable contexts.

Record minimum supported inventory/wire versions in compatibility metadata.
Unsupported newer schemas refuse mutation but remain discoverable as
unsupported state. Older CLIs and raw provider tools do not honor the new
inventory boundary and are outside supported inventory-backed mutation.
Context creation writes no optimistic bootstrap success marker.

### M2 — Packaging, coverage, and obsolete-path removal

Ship pure models, schemas, component declarations, exact external manifest/chart bytes, and required adapters in the correct existing packages. The app-developer package remains free of unnecessary operator tools; the full operator package supplies native platform tools and clone-free behavior. Extend Nix packaging/checks for any new source/schema paths and negative public-API tests. Test Darwin and Linux filesystem locking/durability where supported.

Finish docs/architecture/managed-resource-coverage.md. Audit every supported mutating command and recipe, including init/context projections, platform/infra/host/builder operations, auth/observability/cache/local bootstrap, app/site/server/worker/preview deploys, env/secrets, storage backups/restores/pruning, database/broker/topics, jobs/tasks, domain/CDN/access, maintenance sessions, image publication, and release/control state. A coverage row names its scope owner, declaration builder, executor, evidence tests, delegated authority, and legacy entry point disposition. Unaccounted behavior must be migrated or explicitly made unavailable; it cannot be silently excluded from the completion claim.

Verify that removed installers/guards have equivalent tests at the new authoritative boundary. Keep narrow native transport and remote safe-switch protocols. Remove wrappers/tests that only reconstruct policy now represented by types and pure validators. Reject new provider writes outside adapter modules in review and add a focused mutation-registration test over the command registry; a grep-only policy check is not sufficient assurance.

Update docs/user/upgrades.md, contexts.md, cluster-bootstrap.md, app-lifecycle.md, managed-databases.md, backups-and-disaster-recovery.md, env-and-secrets.md, nix-binary-cache.md, and reference.md as needed, following their profile/log contract. Explain independent scopes, adoption, partial state, secret-safe evidence, writer limitations, and history restoration. Reconcile the documentation and [ADR 13](../adr/0013-operator-deployment-material-lives-in-a-private-repository-with-remote-state.md) with the inventory store: that ADR says a new machine needs two clones and credentials, which stops being true once ownership history and every application deploy depend on a workstation-local store. The MasterPlan resolved this by adding EP-151, which keeps a cloud context's store in its state bucket and amends ADR 13 itself. Here, confirm that the documents and ADR 13 agree with what EP-151 delivered, that export/restore remains documented for local-store contexts, and run the production-shaped rehearsal of M3 with the GCS store selected. Do not promise distributed exclusion or automatic data rollback.

### M3 — Integrated acceptance

Add cli/nagarectl/test/InventoryIntegrationSpec.hs using recording/fault-injection adapters. Begin with platform plus two applications and a cache. Compile once, plan, apply, verify, rerun as no-op, then remove one component under retention policy. Interrupt after cloud success, host success, database readiness, migration completion, cluster completion, and just before context commit. Verify exact resumed operation counts and unchanged completed receipts.

Add scripts/rehearse-managed-resources.sh as a thin launcher for the real typed commands, with explicit context, expected provider project/cluster, and evidence destination. It contains no separate inventory or lifecycle policy. First run a disposable local context with registry, auth, storage, applications, and database. Then run a production-shaped disposable GCP context including cloud foundation, guarded host, cache, secrets, artifact publication, and recovery evidence. The operator supplies the target and authorizes its bounded creation/cleanup; no production context is inferred from ambient state. Failure to obtain live evidence leaves this milestone incomplete.

The real scenario renders the complete declared inventory before external mutation; apply reaches convergence; an unchanged rerun records zero unintended writes; an intentionally removed component is retained or deleted according to its reviewed policy. Include adoption refusal of an unowned same-name object, a migration/rename preserving database rows and signing identity where relevant, and deletion of an ephemeral owned fixture without touching retained/unmanaged neighbors. Archive backup/restore proof and test restoring the private inventory history into an isolated operator state root. Cleanup itself must use exact reviewed owned resources.

### M4 — Release evidence and completion

Extend clone-free rehearsal and release checks to archive a versioned evidence manifest containing payload/version/source identity, context fixture identity, canonical inventory digest, scope revision vector, reviewed change-set digest, component receipt references/digests, final observed summary, tool identities, and coverage result. Public evidence is structurally redacted. Private native plans/secrets/recovery archives stay private and are referenced only through safe digests/opaque identifiers. No release archive contains live operator credentials or operator-specific ciphertext.

Evidence attachments remain immutable and byte-identical on retry under ADR 7. A release payload identity and per-context run identity are separate; do not claim one context owns the globally shared release artifact. Global publication operations use EP-146's publication owner, while consuming contexts record references.

Implement Nagare.Inventory.Adapters.GitHubRelease in cli/nagarectl/src/Nagare/Inventory/Adapters/GitHubRelease.hs and a checked release-publication command, consuming EP-146 artifact types. The publication owner is bound to repository identity and tag, independent of a deployment context. Replace the direct release-action mutation orchestration in .github/workflows/release.yml; preserve its native build, exact-tag checks, deterministic assembly, minimal permissions, and same-tag writer serialization. This is a narrow provider recovery protocol, not a general remote implementation of the context store.

Compile a deterministic publication declaration/review from repository, tag-object/commit identity, payload identities, exact pre-generated notes, and the complete asset names/digests. A workflow run ID is provenance, not immutable content identity. The first provider write creates a draft with a machine-readable intent/review envelope in its body, atomically establishing the binding needed to recover an ambiguous create response. The envelope includes all upload and eventual publication intents; keep it and the notes unchanged. Prototype and verify provider body/asset limits and immutable-release behavior before finalizing the wire shape. Query errors are unknown, never absence.

Recover by finding exactly one draft/published release with matching repository/tag/transaction binding. Upload only missing declared assets, verify existing assets by physical ID/state and downloaded bytes, and refuse different bytes. A failed upload placeholder needs an explicitly reviewed cleanup of its exact draft asset ID. After all product assets verify, upload an append-only digest-addressed verification receipt containing their provider identities. Classify journal/receipt bookkeeping separately from the product manifest so it does not need to hash itself. Verify the full set again, then publish the same draft ID.

Completion after runner loss is reconstructed from the pre-publication receipt, unchanged envelope/assets, and authoritative published state. Do not append a final receipt to an immutable published release; export the reconstructed completion observation locally. Retry with an empty runner filesystem must work using the provider record and the exact reviewed candidate bytes. Expired Actions artifacts are not recovery authority: missing candidate bytes require reproducible reconstruction or a retained archive, never acceptance of different bytes. Existing published legacy releases may be verified read-only and left unchanged; unbound drafts require explicit adoption/recovery. Same-tag workflow serialization excludes authorized overlapping publishers, not administrators or raw API clients; unexpected changes cause refusal.

Add InventoryPublicationSpec.hs with failures after create, each asset upload, verification receipt upload, and publish, then restart from an empty local state. Verify no duplicate release, changed attachment, unreviewed cleanup, or publication before complete verification. Validate the provider protocol in a separately authorized disposable repository/draft rehearsal before claiming publication recovery support; ordinary plan implementation does not publish a real Nagare release.

Run the existing release validation in rehearsal mode. Do not pick a release version, tag, publish, or upgrade existing live contexts merely to complete this plan. Record results in this plan and the parent registry. Review all child Decision Logs/Surprises/Outcomes and update ADR 22 and the affected existing ADRs with durable lessons. Mark IR-24 addressed only after its full acceptance has evidence.


## Concrete Steps

Run the deterministic checks from repository root in the existing development environment:

```bash
(cd cli/nagare-dsl && cabal test nagare-dsl-test --test-show-details=direct)
(cd cli/nagarectl && cabal test nagarectl-test --test-show-details=direct)
(cd infra/pulumi && npm run build && npm test)
bash scripts/test-release.sh
nix flake check
```

Use the established native-system release checks for each supported system in release.json; a Darwin run does not substitute for Linux host activation. Never manually search/read /nix/store even when Nix reports an output there.

The new live launcher has the following required interface. Set these task-specific variables to a separately authorized disposable context and its expected project; the launcher refuses missing values or mismatch.

```bash
: "${NAGARE_TEST_CONTEXT:?set an explicitly disposable context}"
: "${NAGARE_TEST_PROJECT:?set its exact GCP project}"
bash scripts/rehearse-managed-resources.sh \
  --context "$NAGARE_TEST_CONTEXT" \
  --expected-project "$NAGARE_TEST_PROJECT" \
  --evidence-dir .tmp/managed-resource-rehearsal
```

The launcher must print the reviewed identities and evidence location, fail nonzero on any mismatch, and refuse to overwrite different completed evidence. Define a local-mode variant with explicit expected cluster identity and no GCP calls. Document its exact invocation when implementing the launcher.


## Validation and Acceptance

The seven verification cases in IR-24 are all covered: cross-provider/logical collisions before mutation; reviewed adoption; ordered data-preserving rename; component resume; distinct drift categories; real disposable convergence/no-op/removal; and immutable release evidence. Additionally prove app-only revisions preserve platform/other apps, shared contributions do not clobber peers, unknown secret reads never rotate credentials, and compiled resource membership equals actual executor coverage.

All supported entry points are accounted for and superseded policy scripts are
removed. Both installed clone-free packages and source workflows use the same
model. No schema decoder or public constructor can bypass the reviewed
execution boundary. Inventory store backup/restore, journal corruption,
concurrent writer, stale review, and secret redaction tests pass. Do not
report complete if live rehearsals, native-system evidence, legacy mutation
refusal, or fresh-context component recovery evidence remain missing.


## Idempotence and Recovery

Never mutate immutable release attachments or old transaction evidence. A
failed rehearsal retains its private journal and reviewed resources for resume
or explicit cleanup. Cleanup uses the same inventory policy and cannot target
a context root/provider project broadly. A failed fresh bootstrap retains its
selected context pin and reports truthful partial component progress; the
cluster marker cannot claim completion until all required components verify.


## Interfaces and Dependencies

This plan integrates, rather than redefines, the EP-144 resource schema,
EP-145 journal, EP-146 native adapters, EP-147 cluster declarations, EP-148
scope commands, and EP-149 lifecycle decisions. It owns fresh-context
platform integration, legacy upgrade confinement, coverage completion,
packaged evidence manifests, and final release checks. The shared
review/evidence format includes an explicit schemaVersion and immutable
member digests; release metadata references it without duplicating its fields
as a second authority.

It also owns the GitHubRelease adapter and publication-only durable provider envelope. That envelope consumes the same review/receipt types but has explicit draft-to-published recovery semantics; it is not permission to put ordinary context inventory history in release assets. EP-145 remains the owner of general transaction types.

The older replacement initiative in docs/masterplans/21-rehearsed-replacement-upgrades-with-bounded-downtime-for-nagare.md remains independent and partially implemented. This work preserves its existing safety core and exposes inventory bindings; it does not claim its pending live replacement adapters are delivered. Consult Mori for dependency APIs and authoritative releases before compatibility changes. No library/tool upgrade or external release publication is prescribed by this plan.


## Revision Notes

2026-09-16: EP-151 became a hard dependency and the ADR 13 question in M2 was replaced by a check of what EP-151 delivered, after the operator added the shared store as the eighth child.

2026-09-16: Cascaded from the MasterPlan's pre-implementation API validation. M2 now requires reconciling ADR 13's new-machine consequence with the workstation-local inventory store.
