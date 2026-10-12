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
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-26T20:36:32Z
      mode: "update"
      note: "Split remaining integration work into EP-152–157 while preserving delivered evidence and full release acceptance"
---

# Integrate resource inventories into upgrades and release verification

**Status: Cancelled — superseded by EP-152–157 on 2026-09-26.** This is an archive of delivered implementation and its original acceptance contract, not an active implementation queue. The remaining requirements were transferred without reducing release functionality or validation. MasterPlan 23 owns the active registry. Do not mark the original four milestones complete or restart their already-delivered work.

Full plan before trimming: [150-integrate-resource-inventories-into-upgrades-and-release-verification.md](https://github.com/shinzui/nagare/blob/0c00498fcc3a332b724c0d0bb767d86c37ce21be/docs/plans/150-integrate-resource-inventories-into-upgrades-and-release-verification.md). This copy keeps the purpose, progress, discoveries, decisions and outcomes.

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

- [-] M1: Remaining fresh platform bootstrap and legacy-boundary acceptance transferred to [EP-152](152-complete-fresh-platform-bootstrap-through-reviewed-components.md). {disposition=superseded-by, by=EP-152}
- [-] M2: Remaining command coverage and installed-package proof transferred to [EP-153](153-close-managed-command-coverage-for-the-inventory-release.md) and [EP-154](154-validate-installed-inventory-packages-on-every-supported-system.md). {disposition=superseded-by, by=EP-153+EP-154}
- [-] M3: Remaining local and GCP integration/recovery proof transferred to [EP-155](155-prove-local-application-and-data-recovery-end-to-end.md) and [EP-156](156-prove-fresh-gcp-convergence-and-shared-history-recovery.md). {disposition=superseded-by, by=EP-155+EP-156}
- [-] M4: Remaining mandatory evidence and full release acceptance transferred to [EP-157](157-gate-the-inventory-release-on-complete-immutable-evidence.md). {disposition=superseded-by, by=EP-157}

**Delivered baseline, preserved by this split.** Commit `1891b34c` implemented recoverable GitHub publication, real private-provider retry, inventory-history restoration, and deterministic multi-scope recovery. `6b6e22b5` delivered the guarded plan/apply/verify launcher. `432dad9a` and `cbd7c3cf` delivered exact receipt-bound redacted release evidence. `9c308390`, `28e05b72`, and `09d83188` delivered platform-only candidate composition, the fresh-context release boundary, and legacy mutation refusals; earlier commits added schema/packaging and other entrypoint protections. Their tests and provider evidence below remain valid at their recorded revisions. These delivered capabilities are inputs to the successor plans, not erased work or new unimplemented features.

**Remaining-work allocation.** EP-152 owns production bootstrap/marker behavior; EP-153 owns the finite full command audit and platform-side gaps; EP-154 owns installed Darwin/Linux packages; EP-155 owns the common scenario and local proof; EP-156 owns GCP/shared-store proof; EP-157 owns complete candidate evidence and the final gate. EP-148 has also been superseded: EP-158–161 own its remaining feature protocols and EP-153–157 own its remaining cutover, packaging, and proof. Its delivered implementation is preserved. The next implementation outcome is EP-152, with coverage and packaging able to proceed alongside it. No successor can redefine a successful partial run as the requested working release.

**Historical implementation evidence follows.** Dates below may be UTC; the September 25 local work includes entries dated September 26 UTC.

2026-09-26: Closed four more legacy platform entry points after inventory
admission: release adoption, predeployment re-pin, upgrade rollback, and
Pulumi outcome recovery now check inventory history before loading provider
state or transaction evidence. Fresh bootstrap planning checks that the
selected immutable payload version matches the context pin. The public CLI
fixture proves eleven admitted-history refusals and unchanged context/store
bytes; the executable builds and Haskell style passes. M1 still needs complete
component-backed bootstrap and live convergence proof.

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

2026-09-26: The operator requested bounded replacement plans and explicitly rejected a broken or reduced version. Retire this oversized execution umbrella as Cancelled/superseded, preserve its delivered implementations and evidence, and transfer all remaining acceptance to EP-152–157. MasterPlan 23 records owners, integration gates, and a conditional forecast; EP-148 remains mandatory.

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

Substantial implementation was delivered on September 25, including provider-backed recoverable publication, deterministic recovery, store restoration, the rehearsal launcher, compatibility boundaries, and redacted evidence projection. The original four broad acceptance milestones were not closed. This plan is now Cancelled/superseded by EP-152–157; its scope was redistributed, not declared complete or abandoned. The full release still requires complete native local/GCP behavior, command coverage, installed native packages, and immutable candidate evidence.

The Context, Plan of Work, and validation sections below preserve the original contract for traceability. Their present-tense implementation descriptions are historical. In particular, the release workflow already uses the checked publisher; successors must inspect current code instead of repeating that migration.

