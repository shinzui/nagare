---
id: 223
slug: show-accepted-inventory-history-without-contacting-providers
title: "Show accepted inventory history without contacting providers"
kind: exec-plan
created_at: 2026-10-29T14:22:16Z
intention: "intention_01m640jteee9q9prk3fb3vkk1f"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-10-29T14:22:16Z
---

# Show accepted inventory history without contacting providers

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current during implementation. Follow `agents/skills/exec-plan/FRICTION.md` for implementation friction and `agents/skills/exec-plan/ADR.md` when durable decisions change.


## Purpose / Big Picture

An operator will be able to run `nagarectl inventory show` to list the scopes accepted by the selected context, or `nagarectl inventory show KIND:NAME` to inspect one accepted declaration. This works without a kubeconfig or platform workspace and without observing managed resources, taking an inventory lock, or changing history. For a selected scope, `--json` returns the declaration in the store's existing wire format, suitable for decoding and comparison.

This implements [IR-34](../improvement-requests/inventory-show-accepted-history-offline.md). Local history can be inspected offline. GCS history still requires authentication and network access to its storage service and the existing bucket/project ownership check; it must not contact Kubernetes, Pulumi, hosts, application databases, or other managed-resource providers. Missing or corrupt history is an error, never an empty successful listing.


## Progress

- [ ] M1: A reusable accepted-state query and renderers pass fixture round-trip, read-boundary, and no-write tests for local and object-backed stores.
- [ ] M2: The public CLI lists and shows accepted scopes under the fake-command harness without provider calls; documentation, command audit, and required checks pass.


## Surprises & Discoveries


## Decision Log

- Decision: Create a bounded standalone ExecPlan for IR-34, with no parent MasterPlan and no implementation in this authoring task. Rationale: the user's 2026-10-29 request explicitly asks for a plan, superseding the source request's earlier statement that a plan was unnecessary. Date: 2026-10-29.
- Decision: Use the shared recorded-state reader with `AcceptedOnly`, rather than the planning history loader or export. Rationale: inspection must work during open transactions and must not load journals, retained history, reviews, earlier converged revisions, or private native bytes. Date: 2026-10-29.
- Decision: Selected-scope JSON is exactly one canonical scope document, without a revision wrapper. Human output includes the accepted revision; listing JSON includes revision metadata. Rationale: adding fields to the selected document would violate its strict existing decoder and IR-34's round-trip criterion. Date: 2026-10-29.
- Decision: Disable persistent inventory caching for this command while preserving the existing GCS authentication and ownership checks. Rationale: the current read-only GCS opener can populate its disk cache; the requested command promises to write nothing. This is a command-specific path, not a change to the caching behavior of existing commands. Date: 2026-10-29.


## Outcomes & Retrospective


## Context and Orientation

A context selects a project and inventory store. A scope is an independently accepted group of declarations, identified as a kind and name such as `platform:auth`. The store's mutable `head.json` names each accepted scope's immutable declaration by content digest (a hash of its canonical bytes) and scope revision generation. The global head generation and a scope's revision generation are different counters. Accepted state records what Nagare accepted; it does not assert that the resources are currently healthy or that the revision converged. A retired scope can have historical records without belonging to the accepted map and must not appear here.

The command sum type is in `cli/nagarectl/app/Nagare/Cli/Options.hs`, the inventory parser is in `cli/nagarectl/app/Nagare/Cli/Parser/Inventory.hs`, and routing is in `cli/nagarectl/app/Nagare/Cli/Dispatch.hs`. `cli/nagarectl/app/Nagare/Cli/Commands/Inventory/Status.hs` demonstrates a thin publications command, but its status implementation observes providers and may resolve a workspace. Do not reuse that status path for show. `cli/nagarectl/app/Nagare/Cli/Runtime/Target.hs` resolves the active target.

`cli/nagarectl/src/Nagare/Inventory/Publications.hs` is an example of a read-only command using recorded state. The underlying `cli/nagarectl/src/Nagare/Inventory/Recorded.hs` provides `newRecordedReader`, `readRecordedHead`, and `loadRecordedStateAt`. The checked head verifies the expected context/project binding. Hydration reads and verifies the immutable declarations named by that head. Its `recordedAccepted` map contains `(ScopeRevision, ScopeDeclaration)` pairs. Use `AcceptedOnly`: the convenience `readRecordedState` currently uses `WithConvergedSites`, which unnecessarily loads older revisions for this command. Open transactions, claims, fences, and transitions are recorded facts and must not trigger a planning refusal.

`cli/nagarectl/src/Nagare/Inventory/Store/Target.hs` selects local versus GCS storage. `openTargetStoreReadOnly` avoids initialization but supplies a persistent cache on the GCS path. `cli/nagarectl/src/Nagare/Inventory/Store.hs` writes successfully fetched immutable objects into that cache inside `readObjectUnlocked`. Its `openObjectStoreReadOnlyWithLock` accepts an optional cache directory; passing `Nothing` removes this write. A lock path on a store handle does not itself acquire a lock; show must never call `withProcessLock` or writer operations. Local `openFilesystemStoreReadOnly` does not create directories or change permissions.

`cli/nagare-dsl/src/Nagare/Resource/Inventory.hs` exposes `scopeId`, `scopeBundles`, configuration digest and overrides. Bundles contain declarations and declared operations, plus exports, conditions, contributions and grants. Count members as the total number of stored declarations across bundles, including managed, external and observed-child declarations; do not compose contributed resources into a different membership list. `cli/nagare-dsl/src/Nagare/Resource/Inventory/Types.hs` defines these alternatives and `DesiredSpec`. Native bodies are represented there by digests, not embedded payloads. `cli/nagare-dsl/src/Nagare/Resource/Wire.hs` supplies `scopeValue`, `encodeCanonicalScope`, and `decodeScope`; its scope parser rejects unknown fields. `cli/nagarectl/src/Nagare/Inventory/ScopeMember.hs` checks scope identity and content digests.

The recorded release fixture is `cli/nagarectl/test/fixtures/transition-0.4.0/store`. Its README explains that the journal is sampled, not complete, so it is particularly useful for proving this reader needs only the head and declarations. Read accepted revisions from `head.json`; `revisions.json` also names older revisions and is not the authority for the listing. Reuse `cli/nagarectl/test/RecordedSiteSpec.hs` and `cli/nagarectl/test/Nagare/Test/World/ObjectStore.hs` for checked-reader and fake object-store patterns. `cli/nagarectl/test/Nagare/Test/ContractCommands.hs` demonstrates library-level command tests. `cli/nagarectl/test/Nagare/Test/Suite.hs` assembles tests and fixture generators. The installed CLI fake-command check lives in `nix/checks/scripts/nagare-clone-free-platform.sh`, wired by `nix/checks/platform.nix`.

Relevant ADRs consulted are [ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md), especially its 2026-10-16 recorded-reader and 2026-10-22 pinned-head amendments; [ADR 9](../adr/0009-assert-the-active-context-project-on-every-cloud-mutating-path.md); [ADR 16](../adr/0016-adopt-haskell-jitsurei-for-production-haskell.md); and [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md). Their relevant constraints are: declarations are separate from live observations and private execution payloads; a reader verifies one captured context-bound head and its members; GCS ownership checks remain mandatory; CLI modules only parse, route and render while reusable logic lives in the library; deterministic tests find defects before native runs. No native deployment or release is needed for this read-only feature.


## Plan of Work

### M1: Query and render accepted state with no write effects

Add `cli/nagarectl/src/Nagare/Inventory/Show.hs` for the query, selection, summary projection and rendering. Keep acquisition separate from projection so a test can supply an `InventoryStore` and expected `ContextBinding`. Open once, construct a recorded reader using `readHead store`, capture one checked head, and hydrate with `AcceptedOnly`. Use `recordedAccepted` exclusively, in deterministic scope order. Match a requested `KIND:NAME` against canonical `scopeIdText` values; malformed and unknown selectors fail clearly without partial stdout. Do not infer an accepted declaration from a filename or from the converged/retained maps.

Add an explicitly uncached read-only opener in `cli/nagarectl/src/Nagare/Inventory/Store/Target.hs`, factoring the existing opening logic so the new path passes `Nothing` for the persistent cache and uses `mayInitialize = False`. Preserve current openers' behavior. Reuse remote authentication, persisted-profile checks and bucket ownership validation; do not duplicate a weaker remote transport. No cache directory, client identity, lock file, or store object may be created by show. The recorded reader's in-memory cache is harmless and can remain. Verify this boundary before expanding output variants.

Define the no-argument text output as an aligned table with `KIND`, `NAME`, `GENERATION`, and `MEMBERS`. Its generation is `revisionGeneration`. An initialized store with no accepted scopes succeeds with headers and no rows. Define no-argument `--json` as an array of objects with `kind`, `name`, `generation`, `members`, and `digest`; an empty accepted map produces `[]`. Use the existing canonical kind spelling, not Haskell constructor names.

Selected text output identifies the scope and accepted revision generation/digest, then prints every stored declaration's identity, address, executor and desired spec where applicable, lifecycle, data policy, sensitivity, and dependencies, followed by the declared operations. Preserve external and observed-child distinctions; do not invent managed-only fields for them. Include bundle metadata, configuration digest and overrides when present so the view does not silently hide declared information. Render structured fields deliberately, using their existing public wire representation where practical. Never fetch or expand a content digest into native bytes. For a Secret member, native content remains digest-only while identity, policy and references remain inspectable. This is a declaration viewer, not a secret-material export.

Selected `--json` writes `encodeCanonicalScope declaration` plus a newline and nothing else to stdout. Do not add a revision envelope, redact the wire document into an undecodable shape, or use derived Haskell `Show` as JSON. The existing wire representation keeps native secret bodies out of the declaration. Tests must confirm that property with a secret payload sentinel stored separately from its declaration.

Add `cli/nagarectl/test/InventoryShowSpec.hs`, register it in `cli/nagarectl/test/Nagare/Test/Suite.hs`, and register new modules in `cli/nagarectl/nagarectl.cabal`. M1 is complete when the focused tests described below prove the query and renderers work on the recorded fixture and both store backends without writes or private-object reads.

### M2: Expose the CLI and prove the operator workflow

Add `InventoryShow (Maybe String) Bool` to `cli/nagarectl/app/Nagare/Cli/Options.hs`, parse optional positional `KIND:NAME` and `--json` in `cli/nagarectl/app/Nagare/Cli/Parser/Inventory.hs`, and dispatch through a new thin `cli/nagarectl/app/Nagare/Cli/Commands/Inventory/Show.hs`. Resolve the active target and call the library; do not add context guards, workspace discovery, provider adapters or `--contract` support. Register the executable module in the Cabal file. Existing global context selection must work.

Extend `nix/checks/scripts/nagare-clone-free-platform.sh` with an isolated local context/store fixture before any workspace or kubeconfig setup for that fixture. Reuse the suite's fixture-generator pattern if needed to seed accepted scopes, including a Secret member and an open transaction/claim. Exercise help, listing, selected text and JSON, empty accepted state, unknown and malformed selectors. Clear and compare the fake-tool log around show itself; fixture construction is not part of the command measurement. Verify no workspace appears. Include a JSON round-trip through the production decoder in the Haskell suite, rather than relying solely on `jq` shape assertions.

Add `InventoryShow` to the read routes in `scripts/audit-managed-commands.py` and regenerate the table in `docs/architecture/managed-resource-coverage.md`. Document both forms beside explain in `docs/user/contexts.md` and `docs/user/reference.md`. Explain that show reads accepted intent, explain observes current state, and GCS access is online even though managed-resource observations are absent. Describe empty and unknown scope behavior and the different JSON shapes. M2 is complete when the public command's fake tests, audit and architecture checks, and implementation gate pass. Distill any durable clarification into ADR 22 during implementation, preserving the existing ADR format.


## Concrete Steps

All commands below run from the repository root unless a block changes directory. Implement M1 first, run its focused tests, then expose the CLI and extend the installed check. Heavy test runs use a committed candidate on the remote builder. Commit only this plan's changes on the current branch, using a Conventional Commit and these trailers on implementation commits:

```text
ExecPlan: docs/plans/223-show-accepted-inventory-history-without-contacting-providers.md
Intention: intention_01m640jteee9q9prk3fb3vkk1f
```

Name the new Tasty group `inventory show` so the focused command is stable. Once that implementation is committed, run:

```bash
just test-remote HEAD 'inventory show'
python3 scripts/audit-managed-commands.py --update-catalogue
python3 scripts/audit-managed-commands.py
bash scripts/test-managed-command-audit.sh
python3 scripts/check-cli-architecture.py
python3 scripts/check-haskell-architecture.py
bash scripts/check-haskell-style.sh
```

The remote run must report exit zero for the selected tests. Audit and architecture checks must exit zero, with no unregistered constructor or expanded module allowance. Commit the catalogue/docs and any subsequent fixes before final-candidate checks:

```bash
nix build --no-link --print-build-logs .#checks.x86_64-linux.nagare-clone-free-platform
just gate-fast HEAD
```

The Nix check exercises the working tree, so include all new source files in Git first and keep that tree equal to the committed candidate for final evidence. It must finish successfully with the new show assertions executed. The gate records the exact committed revision; it does not validate uncommitted edits. Record its revision and concise outcome here during implementation. These commands may execute installed build products; do not manually search, read, or traverse `/nix/store`.

For a context that already has accepted history, the operator-visible behavior is:

```bash
nagarectl --context CONTEXT inventory show
nagarectl --context CONTEXT inventory show --json
nagarectl --context CONTEXT inventory show KIND:NAME
nagarectl --context CONTEXT inventory show KIND:NAME --json
```

Replace `CONTEXT` with the fixture context and `KIND:NAME` with a scope from its first listing. The first two commands have identical scope membership and counts. The third includes that accepted revision and declared operations. The fourth decodes as exactly the stored `ScopeDeclaration`. No real context is required for acceptance; the harness supplies these inputs.


## Validation and Acceptance

IR-34 AC-1 is proved by the installed CLI in a local context with no kubeconfig and no prepared workspace. Compare rows with every entry of the captured head's accepted map, checking canonical kind/name, per-scope generation and declaration count. Include an accepted empty scope, multiple scopes, and a retired scope that is absent from the listing. A missing store/head refuses and creates nothing; an initialized empty accepted map succeeds. The fake provider log stays empty on success and failure.

IR-34 AC-2 is proved by reading each accepted revision of `cli/nagarectl/test/fixtures/transition-0.4.0/store/head.json`, loading its digest-named scope with the production member reader, rendering selected JSON, and asserting `decodeScope output == Right storedDeclaration`. Check selected CLI stdout as well so routing cannot substitute a different projection. Verify human output includes operations and applicable resource fields, and listing JSON preserves the same summary values. Unknown or malformed selectors return nonzero, a useful stderr diagnostic, and no successful JSON document.

IR-34 AC-3 is proved by comparing `inventory store status --json` before and after successful and unknown-scope runs, including head digest, generation, active transaction and executor claim. Also compare store files, permissions and directory entries, since unchanged head fields alone would miss a temporary lock or cache write. Run while a separate writer holds the inventory lock and require show to finish within a bounded test timeout. An open transaction and claim must remain inspectable and unchanged; the timeout is a lock-independence check, not a production latency promise.

For the object-backed path, instrument the fake `ObjectOps` and exercise the production query through a read-only, uncached handle. Allow format/head and accepted scope reads only; assert one captured head read, no prefix listing, no put, no journal/review/native/object payload reads, and no prior converged-scope reads. Seed a valid existing disk cache directory and prove its bytes, names and permissions remain unchanged as well as the absent-cache case. Exercise the target opener's GCS selection/authentication/ownership path using the existing fake transport patterns, allowing only authentication, ownership and store requests. Wrong ownership or binding must fail; no test may bypass those checks to claim GCS acceptance.

Inject missing scope objects, digest mismatches and read failures and require refusal without partial output or a fabricated empty listing. Have the mutable head change after it is captured and verify output still represents one coherent captured head's immutable members, rather than mixing revisions. Seed private native bytes with a unique sentinel for a Secret-sensitivity resource; the digest remains visible but the sentinel is absent from stdout and stderr in both formats. The corresponding private object must never be read. All required checks must pass; no cloud mutation, release or deployment belongs to acceptance.


## Idempotence and Recovery

The new command is safe to repeat against the same accepted head; output remains deterministic and no store recovery is necessary after interruption. A later invocation may legitimately observe a newer head. Keep all mutation tests and fixture construction inside temporary directories or in-memory object stores, never the operator's active history. Treat the recorded release fixture as immutable; construct test heads and additional secret fixtures in temporary stores rather than editing it.

If a read fails, fix access or history externally and rerun show; the command must not initialize, migrate, repair, unlock or materialize anything. If a test reveals that a shared opener writes, fix the command-specific acquisition path while preserving existing writer behavior. Do not weaken the no-write assertions. Implementation can be reverted as ordinary source changes because it introduces no persisted format or migration.


## Interfaces and Dependencies

The proposed command boundary is `runInventoryShow :: Maybe String -> Maybe String -> Bool -> IO ()`, for context selector, optional scope and JSON mode. The proposed library separates a query of `InventoryStore` plus `ContextBinding` from selection/rendering of the resulting `Map ScopeId (ScopeRevision, ScopeDeclaration)`. The proposed target helper is `openTargetStoreReadOnlyUncached :: ActiveTarget -> IO (Either StoreError InventoryStore)`; it shares existing transport validation and changes only initialization/cache behavior for show.

Use existing `Nagare.Inventory.Recorded`, `Nagare.Inventory.Store.Target`, `Nagare.Resource.Inventory`, and `Nagare.Resource.Wire` APIs. No new package, version pin, contract schema, HTTP endpoint, provider adapter, history format, or cross-repository change is required. If implementation needs an unfamiliar external API, locate its source/docs with Mori before relying on memory; verify registry/upstream versions before changing any dependency bounds. This standalone plan has no pending parent-plan prerequisite.
