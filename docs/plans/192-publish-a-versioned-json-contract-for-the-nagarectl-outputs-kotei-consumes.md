---
id: 192
slug: publish-a-versioned-json-contract-for-the-nagarectl-outputs-kotei-consumes
title: "Publish a versioned JSON contract for the nagarectl outputs Kotei consumes"
kind: exec-plan
created_at: 2026-10-13T13:47:33Z
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-10-13T13:47:33Z
---

# Publish a versioned JSON contract for the nagarectl outputs Kotei consumes

This ExecPlan answers the contract request in
`mori://shinzui/kotei/plans/84-deploy-to-nagare-through-its-reviewed-resource-inventory`
(section "Request to Nagare for a stable public contract"). The operator approved the work on
2026-10-13. It is outside the production-readiness checklist and does not block a release.


## Purpose / Big Picture

Kotei (`mori://shinzui/kotei`) deploys applications to Nagare by running `nagarectl` as a
subprocess. Its first integration broke silently. Kotei parsed a dry-run document,
`{app, resources:[…]}`, that `nagarectl` stopped producing when deploys moved to the reviewed
inventory. Kotei's fake `nagarectl` kept emitting the old shape, and nothing compared the two.

After this change, every `nagarectl` output Kotei reads has a published JSON Schema and golden
sample documents, under `cli/nagarectl/contract/v1/` in this repository
(`mori://shinzui/nagare`, path `cli/nagarectl/contract/v1/`; an artifact-level URI is pending).
Each schema is generated from the same Haskell codec that encodes the output, so the two cannot
disagree. Nagare's test suite fails when an output or schema changes without the golden files
being accepted. Kotei copies the schemas at its pinned Nagare revision and tests its fixtures and
its fake `nagarectl` against them. When either side drifts, a test fails on the side that moved.

The outputs are selected with `--contract 1`:

```bash
nagarectl app image-plan --archive app.tar --destination REG/app:v1 --key app-v1 --save-plan DIR --contract 1
nagarectl app deploy --file nagare/Config.hs --tag v1 --image-resource RID --save-plan DIR --contract 1
nagarectl app deploy --file nagare/Config.hs --tag v1 --image-resource RID --dry-run --contract 1
nagarectl inventory apply DIR --yes --contract 1
nagarectl inventory resume TX --yes --contract 1
nagarectl inventory status --contract 1 [--scope application:kizashi]
nagarectl inventory publications --contract 1
nagarectl version --json      # now also lists "contracts": [1]
```

Each prints exactly one JSON document on stdout carrying `"contractVersion": 1`.
`inventory apply` and `inventory resume` exit with a distinct code for each outcome. Without
`--contract`, every command prints exactly what it prints today, so operator runbooks and the
existing `--json` documents do not change.


## Progress

- [ ] M1: Prove that `autodocodec-schema` 0.2.0.1 emits a schema that a standard JSON Schema
  validator accepts. Pass: a probe codec with an enum, a nullable field, an optional field, an
  array and an embedded opaque value renders a schema, and `check-jsonschema --check-metaschema`
  accepts it. A sample document validates both with `check-jsonschema` and with
  `validateAccordingTo`, and a sample with a wrong enum value fails both. The transcript and the
  draft the schema uses are recorded in the Decision Log.
- [ ] M2: The contract module, the seven schemas, the golden samples and the version listing.
  Pass: `Nagare.Test.Contract` checks each schema file against `jsonSchemaViaCodec` with
  tasty-golden, checks each sample document against its golden file, validates every sample
  against its schema, and asserts `contractVersion` is 1. `nagarectl version --json` prints
  `"contracts":[1]`.
- [ ] M3: `inventory apply` and `inventory resume` with `--contract 1`. Pass: tests cover the
  outcome document and exit code for every `TransactionResult` constructor. They show a
  pre-execution refusal printing `refused` with exit 2, and a failure after execution starts
  never printing `refused`. Without `--contract`, the output and exit status are byte-for-byte
  unchanged in the existing suites.
- [ ] M4: `app image-plan`, `app deploy --save-plan` and `app deploy --dry-run` with
  `--contract 1`. Pass: CLI-level tests on the existing app-deploy fixtures emit documents equal
  to the golden samples. The deploy preview has the same top-level keys with and without hooks.
- [ ] M5: `inventory status --contract 1 [--scope SCOPE]` and `inventory publications
  --contract 1`. Pass: tests over the existing status fixtures show findings for the selected
  scope only, and an unknown scope refuses. A publication fixture lists resource ID, key,
  destination, both digests, generation, and the application scopes whose accepted
  `imageResource` names it.
- [ ] M6: Clean up and hand off. Delete `renderPlan`, `AppDeployPlan` and `renderAppObjects`,
  and fix the stale comment in `Options.hs`. Add `cli/nagarectl/contract/README.md` and a
  "Machine-readable contract" section in `docs/user/reference.md`. Pass: `just haskell-style-check`
  and `just gate-fast` are green, then `just land`. The contract path and the landed commit hash
  (copied from `git log`) are sent to the `kotei` session.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision (2026-10-13): Contract output is selected by `--contract 1`, not by `--json`. The
  existing `--json` documents (`inventory status`, `inventory explain`, `app deploy --dry-run`)
  stay operator-facing and unchanged. Runbooks such as `docs/runbooks/inventory-operations.md`
  read fields that are not part of the contract, and the release notes in
  `docs/releases/v0.6.0.md` tell operators to use `inventory status --json`. The flag is also the
  selector Kotei asked for to keep an older major version available, so a future
  `--contract 2` needs no new mechanism.
- Decision (2026-10-13): Generate each schema with `autodocodec-schema` from the codec that
  encodes the output, and make the schema files tasty-golden outputs. A hand-written schema
  could drift from the encoder while every golden test stays green, which is the same failure
  that broke Kotei. Use the versions in the pinned package set (`autodocodec` 0.5.0.0,
  `autodocodec-schema` 0.2.0.1). Hackage has 0.2.0.2, which requires `autodocodec >=0.6`; do not
  override the pin for it.
- Decision (2026-10-13): The contract types live in their own modules, `Nagare.Contract.V1`
  (types and codecs, importing nothing from Nagare) and `Nagare.Contract.Project` (pure
  projections from internal values). Kotei never links them; it stays subprocess-only. Internal
  types keep their aeson instances. Contract types are encode-only inside `nagarectl`: per
  ADR 22, decoding JSON never grants authority, so no command reads a contract document back.
- Decision (2026-10-13): Scopes appear as the `kind:name` text `scopeIdText` produces (for
  example `application:kizashi`, `publication:app-image-v1`). It is the same prefix every
  resource ID already carries, so Kotei uses one representation everywhere.
- Decision (2026-10-13): Distinct exit codes apply only under `--contract 1`. Without it,
  `inventory apply` keeps exiting 0 or 1, so no existing script sees a new code.
- Decision (2026-10-13): `refused` means no provider was touched. A refusal raised before
  admission completes is `refused` (exit 2). A `dieT` or exception after admission, once
  execution may have written intent, is `interrupted` with the transaction ID (exit 7). Kotei
  must then read `inventory status` or run `inventory resume`. A post-admission failure is never
  reported as harmless.
- Decision (2026-10-13): The publication listing has no accepted time and no single owning
  app. Neither is stored: `ScopeRevision` holds only generation and digest
  (`src/Nagare/Inventory/Store.hs:110-113`), and a publication scope is linked to an app only
  through that app's accepted `imageResource` override. The listing reports `generation` and
  `usedBy` (the application scopes whose accepted override names it) instead. Kotei records its
  own times.
- Decision (2026-10-13): Delete `renderPlan`, `AppDeployPlan` and `renderAppObjects` from
  `cli/nagarectl/src/Nagare/App/Deploy.hs`. They were the pre-inventory Kotei contract, and
  only `test/AppDeploySpec.hs` uses them. `RenderedObject` stays only if `stampAppLabel`'s local
  `describe` still needs it after the deletion.
- Decision (2026-10-13): The rule "keep emitting the previous major for one release" is written
  into `cli/nagarectl/contract/README.md`. It is not implemented until a version 2 exists.


## Outcomes & Retrospective

(To be filled at completion.)


## Context and Orientation

All paths are relative to the repository root unless they start with `src/`, `app/` or `test/`,
which are under `cli/nagarectl/`. Build and test from `cli/nagarectl`:
`cabal test nagarectl-test --offline --test-show-details=failures`, focused with
`--test-options='-p /Contract/'`. Golden files are regenerated with tasty-golden's `--accept`
test option.

**How a reviewed deploy works.** The inventory (ADR 22) holds the accepted desired state of
every scope. A scope is an independently revised unit such as one application or one image
publication. A change is first saved as a review bundle, a directory with `review.json`,
`review.sha256` and `scopes/…`. It is then applied with `inventory apply DIR --yes`, which runs a
transaction named `tx-<review digest>`. Kotei's flow is: publish the image (`app image-plan`),
apply, preview (`app deploy --dry-run`), save the deploy review (`app deploy --save-plan`),
apply.

**What each surface prints today** (checked against 0.6.2 at `f684df2e`):

- `app image-plan` (`app/Nagare/Cli/Commands/Image.hs:76-261`, `runAppImagePlan`). With
  `--save-plan`, it goes through `planInventoryCandidateWith`
  (`src/Nagare/Inventory/Command.hs:436-441`). That prints the review digest as bare hex, then
  any `rebind …`/`rebuild …` lines, then `Image resource: <id>`. Without `--save-plan`, it
  converges in-process (`Command.hs:446-473`) and prints `Published review <hex>`, summaries and a
  transaction line. The resource ID is `publication:app-image-<key>/<key>/oci-image`
  (`mintResourceId`, `cli/nagare-dsl/src/Nagare/Resource/Types.hs:107-108`). The review
  directory is never printed, and nothing is JSON.
- `app deploy --save-plan` (`app/Nagare/Cli/Commands/Application.hs:165-555`) ends in the same
  `Command.hs:436-441` output: digest plus lineage lines, with no directory and no scope IDs.
- `app deploy --dry-run --json` (`Application.hs:481-497`) prints the canonical scope
  (`encodeCanonicalScope`, `cli/nagare-dsl/src/Nagare/Resource/Wire.hs:125-131`). With hooks, it
  prints `{"application":…, "hooks":[…]}` instead, so the top-level shape depends on the config.
  The scope's `configDigest` is the SHA-256 of the canonical `applicationJSON` of the typed
  Application (`src/Nagare/Inventory/Application/Policy.hs:57-60`,
  `cli/nagare-dsl/src/Nagare/Dsl/Config.hs:627-638`). It covers the typed config only. Tag,
  image resource, base domain, CDN fields, request-namespace and hook effects travel in the
  scope's `overrides` map (`Application.hs:441-459`, allowed keys at
  `src/Nagare/Inventory/Application/Compile.hs:157`).
- `inventory apply` (`app/Nagare/Cli/Inventory/Workflow.hs:272-275` →
  `applyInventoryWithFactory`, `Command.hs:519-540`). The result type is `TransactionResult`
  (`src/Nagare/Inventory/Execute/Types.hs:127-134`), rendered as one line by
  `renderTransactionResult` (`Command.hs:1013-1019`):

  | Constructor | Line printed today | Exit today |
  |---|---|---|
  | `Converged tx` | `converged <tx>` | 0 |
  | `PausedAtBarrier tx barriers` | `paused <tx> at N review barrier(s)` | 1 |
  | `StoppedFailed tx op cls` | `stopped <tx> at <op>: <show FailureClass>` | 1 |
  | `StoppedAmbiguous tx op` | `ambiguous <tx> at <op>` | 1 |
  | `Closed tx` | `closed <tx>` | 1 |

  `FailureClass` is `KnownNoEffect Text` or `PartialOrUnknown Text`
  (`src/Nagare/Inventory/Execute/Journal.hs:61-64`). Refusals before execution go to stderr
  through `dieText` (`Command.hs:1026-1027`) or `dieT` (`app/Nagare/Cli/Runtime/Error.hs:24-27`,
  which also prefixes `nagarectl:`). Both call `exitFailure`. These refusals include a missing
  `--yes`, a wrong context, a changed bundle, review verification and admission errors
  (`Command.hs:522-536`), and the adapter-registry checks in
  `app/Nagare/Cli/Inventory/Execution.hs`. `inventory resume` has the same shape
  (`Command.hs:567-570`).
- `inventory status --json` (`app/Nagare/Cli/Commands/Inventory/Status.hs:88`, document at
  507-543). Each `DriftFinding` (`src/Nagare/Inventory/Status.hs:735-745`, encoded at 848-860)
  carries `resource`, `owner` (a scope, as `{kind,name}`), `category`, `health` and `reason`.
  The `category` values are `converged`, `configuration-drift`,
  `immutable-replacement-required`, `replaced-incarnation`, `unrecorded`, `stuck-rollout`,
  `missing`, `unowned`, `foreign-owner` and `unknown`. The `health` values are `ready`,
  `not-ready`, `unknown` and `unavailable`. The command cannot filter by scope, and it exits 0
  even when there is drift.
- No command lists accepted image publications. They are scopes of kind `Publication` named
  `app-image-<key>` in `historyAccepted` (`src/Nagare/Inventory/Plan/Types.hs:109-116`), read
  through `loadTargetSnapshotReadOnly` (`Command.hs:940`). Each holds a managed resource whose
  address is `Artifact _ manifestDigest` and whose spec is
  `ArtifactPublication kind destination archiveDigest _`. Existing readers to reuse are
  `artifactExecutionSpecsFromDeclarations` (`src/Nagare/Inventory/Artifact.hs:99-114`) and
  `acceptedApplicationImage` (`src/Nagare/Inventory/Application/Bindings.hs:87-108`).
- `version --json` (`app/Nagare/Cli/Commands/Platform.hs:81-101`, encoders in
  `src/Nagare/Version.hs:153-169`) prints `{"platformVersion","version"}`, plus an optional
  `revision` and, with `--tools`, a `tools` map.

**JSON and tests in this codebase.** Output JSON uses hand-written aeson `ToJSON` instances and
the canonical encoder `canonicalValue` (`cli/nagare-dsl/src/Nagare/Resource/Canonical.hs`). No
package uses autodocodec or any JSON Schema library yet. `tasty-golden` is already a test
dependency of `nagarectl` (`cli/nagarectl/nagarectl.cabal:709`), and its one golden test is
`test/Nagare/Test/Task.hs:174-177`. `nagare-dsl` has many YAML goldens. Test modules are
registered in `test/Nagare/Test/Suite.hs` (see `test/README.md`).

**Dead pre-inventory contract.** `renderPlan`, `AppDeployPlan`, `RenderedObject` and
`renderAppObjects` in `src/Nagare/App/Deploy.hs` (lines 34-36, 345-409) were the old Kotei
contract. Only `test/AppDeploySpec.hs` uses them (lines 92 and 4735-4767). `toRenderedObject` is
also used by `stampAppLabel`'s local `describe` (`Deploy.hs:338`). `app/Nagare/Cli/Options.hs:154-157`
still calls `--json` "the kotei contract".

**ADRs.**
[ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) defines
scopes, reviews and transactions, and says decoding JSON never grants authority. That is why the
contract types are encode-only.
[ADR 16](../adr/0016-adopt-haskell-jitsurei-for-production-haskell.md) sets the Haskell style
the new modules follow: package Prelude, strict record fields, explicit deriving strategies and
generic-lens labels.
[ADR 6](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md)
versions the platform. The contract version is a separate number, deliberately: Kotei gates on
`contracts`, not on the platform version.
[ADR 17](../adr/0017-the-root-flake-follows-the-shared-haskell-nix-dev-toolchain-pin.md) pins
the package set, which is why the plan uses the pinned autodocodec versions.


## Plan of Work

**M1 — prove the schema generator.** In a scratch Cabal project outside the repository, depend
on `autodocodec` and `autodocodec-schema` from the pinned set. Write one probe type covering the
shapes the contract needs: a string enum, a nullable field, an optional field, an array of
objects, and an opaque `Value` field. Render `jsonSchemaViaCodec` with aeson. Run
`check-jsonschema --check-metaschema` on it, from `nixpkgs#check-jsonschema` via
`nix shell --inputs-from .`. Then validate one good and one bad sample with both
`check-jsonschema --schemafile` and `validateAccordingTo`. Record the draft the output declares,
or the absence of `$schema`. If the output needs a wrapper to be standard (for example adding
`$schema` and `$id`), record that in the Decision Log; M2 applies it in one function. If no
wrapper makes it standard, stop and bring it to the operator rather than hand-writing schemas.

**M2 — contract module and schemas.** Add `autodocodec` and `autodocodec-schema` to the
`nagarectl` library, and `aeson-pretty` to the test suite (it is in the pinned set and already
used by `cli/nagare-harness`). Create `src/Nagare/Contract/V1.hs` with one record per document
and a `HasCodec` instance each:

- `TransactionOutcome`
- `SavedReview`
- `ImagePublicationResult`
- `DeployPreview`
- `InventoryStatusReport`
- `PublicationList`
- `VersionInfo`

Every document except `VersionInfo` has a required `contractVersion` field, constant 1 in V1, and
a `document` field naming its kind. `VersionInfo` is the discovery document: it keeps today's
`version`, `platformVersion`, optional `revision` and optional `tools`, and gains
`contracts: [Int]`. Create `src/Nagare/Contract/Project.hs` with pure functions from internal
values to these records. Route `version --json` through `VersionInfo`, so that output's only
change is the new `contracts` field.

Add `test/Nagare/Test/Contract.hs` and register it in `test/Nagare/Test/Suite.hs`. For each
document it has:

- a golden test writing the schema to `cli/nagarectl/contract/v1/<name>.schema.json`;
- a golden test writing a sample built through `Project` from fixed internal values to
  `cli/nagarectl/contract/v1/samples/<name>*.json`;
- a test that every sample satisfies `validateAccordingTo` against its schema.

Both kinds of golden file are pretty-printed with sorted keys and a trailing newline. Samples
cover every enum value of `outcome`, and a deploy preview with and without hooks.

**M3 — apply and resume.** Add `--contract VERSION` to `inventory apply` and
`inventory resume`; it accepts only `1` and otherwise refuses with the supported list. With it,
print one `TransactionOutcome`. Its fields are:

- `outcome`: `converged`, `paused`, `stopped`, `ambiguous`, `closed`, `refused` or `interrupted`
- `transaction` (nullable)
- `operation` (nullable)
- `failureClass`: `known-no-effect`, `partial-or-unknown` or null
- `barriers` (strings)
- `detail` (nullable text)

The exit codes are 0 converged, 2 refused, 3 paused, 4 stopped, 5 ambiguous, 6 closed and
7 interrupted. Code 1 stays for a crash the handler could not classify.

Refusals are captured in `app/Nagare/Cli/Runtime/Error.hs` and `src/Nagare/Inventory/Command.hs`.
A contract sink is set once, when `--contract` is parsed. While the sink is set, `dieT` and
`dieText` print the outcome document instead of the stderr line. The outcome is `refused` until
the sink is switched to the executing phase, then `interrupted` with the transaction ID. The switch
goes in `applyReviewed`'s path at the point where admission has succeeded and before the first
intent is written; find that point in `src/Nagare/Inventory/Execute/`. An unexpected exception
under the sink also yields `interrupted` once executing. Without the sink, `dieT` and `dieText`
behave exactly as now. Keep the human `renderTransactionResult` line unchanged.

**M4 — publication, saved review and preview.** Add `--contract VERSION` to `app image-plan` and
`app deploy`. Give `planInventoryCandidateWith` and its two siblings a way to return the digest,
the bundle directory, the scope IDs (keys of `reviewBundleScopes`) and the lineage lines, instead
of only printing them. With `--contract 1`, print a `SavedReview`:
`{review:{sha256, directory}, scopes:[…], rebinds:[…], rebuilds:[…]}`.

`app image-plan --contract 1` prints an `ImagePublicationResult`:
`{imageResource, review:{sha256, directory|null}, transaction: TransactionOutcome|null}`. The
transaction is filled when it converged in-process; the exit code follows the M3 rules.

`app deploy --dry-run --contract 1` prints a `DeployPreview` with the same keys for every config:

- `application`: `{scope, configDigest, overrides}`
- `hooks`: a list of the same shape
- `scopeDocuments`: the canonical scope values, schema type "any", documented as opaque audit
  data whose `bundles` are outside the contract

The schema description of `configDigest` says what it covers and what it does not, as in Context
above. `app deploy` with `--contract` but neither `--save-plan` nor `--dry-run` refuses, since a
live unreviewed apply has no contract document.

**M5 — status and publications.** Add `--contract VERSION` and `--scope KIND:NAME` to
`inventory status`. `--scope` without `--contract` filters the existing document the same way.
An unknown or unaccepted scope refuses. With `--contract 1`, print an `InventoryStatusReport`:

- `context`, `observedAt`, `observationComplete`
- `activeTransaction` (nullable)
- `scopes`: `[{scope, generation, digest, converged}]`
- `findings`: `[{scope, resource, category, health, reason}]`

The exit code is 0, as today; drift is data, not an error. Add `inventory publications
--contract VERSION`, read-only, using `loadTargetSnapshotReadOnly`. It prints a
`PublicationList`, `{publications:[{resourceId, scope, key, destination, manifestDigest,
archiveDigest, generation, usedBy:[scope]}]}`, sorted by scope. Without `--contract` it prints a
plain table. Register the new subcommand in `scripts/audit-managed-commands.py` as read-only.

**M6 — cleanup and handoff.** Delete the dead pre-inventory contract (see Decision Log) and its
tests in `test/AppDeploySpec.hs`, and fix `app/Nagare/Cli/Options.hs:154-157`. Write
`cli/nagarectl/contract/README.md`. It lists the documents and their commands, and the exit-code
table. It states the versioning rules: additive changes keep major 1 and add only optional fields
or new enum values announced in the README; anything else is version 2, and nagarectl keeps
emitting version 1 for at least one release behind `--contract 1`. It also says how to accept
goldens. Add the "Machine-readable contract" section to `docs/user/reference.md` pointing at it.
Gate, land, and send the path and landed hash to the `kotei` session.


## Concrete Steps

Focused development loop, from `cli/nagarectl`:

```bash
cabal test nagarectl-test --offline --test-show-details=failures --test-options='-p /Contract/'
cabal test nagarectl-test --offline --test-show-details=failures --test-options='-p /Contract/ --accept'
```

The first run after adding a document fails with a missing golden file. `--accept` writes it.
Review the written schema and sample with `git diff` before committing; a changed schema file is
a contract change and needs the README versioning rule applied.

M1 validator check, from the scratch directory:

```bash
nix shell --inputs-from /Users/shinzui/Keikaku/bokuno/nagare nixpkgs#check-jsonschema -c \
  check-jsonschema --check-metaschema probe.schema.json
nix shell --inputs-from /Users/shinzui/Keikaku/bokuno/nagare nixpkgs#check-jsonschema -c \
  check-jsonschema --schemafile probe.schema.json good.json
```

Expected: `ok -- validation done` for both, and a failure naming the enum for `bad.json`.

Per commit, from the repository root:

```bash
just haskell-style-check
just gate-fast
```

At landing, with no uncommitted changes:

```bash
just gate-fast
just land
```

Commit messages follow Conventional Commits, for example
`feat(contract): publish the v1 transaction outcome for inventory apply`.


## Validation and Acceptance

Required acceptance, all offline:

- `nagarectl version --json` contains `"contracts":[1]`, and its other fields are unchanged.
- For each of the seven documents, the schema golden equals `jsonSchemaViaCodec` output, the
  sample goldens equal the projected documents, and every sample passes `validateAccordingTo`.
- Each M3 constructor case prints the expected outcome and exits with the expected code. A
  refusal before admission (for example omitting `--yes`) prints
  `{"contractVersion":1,"document":"transaction-outcome","outcome":"refused",…}` and exits 2.
  A failure injected after admission prints `interrupted` with a non-null `transaction` and
  exits 7.
- Without `--contract`, the existing suites pass unchanged. `inventory apply` still prints
  `converged tx-…` and exits 0 or 1.
- `app deploy --dry-run --contract 1` on `cluster/examples/multi-workload-app` (which has hooks)
  and on an example without hooks produces documents with identical top-level key sets.
- `inventory status --contract 1 --scope application:<name>` lists only that scope's findings,
  and an unknown scope exits non-zero with a refusal.

Kotei's side, not required here: it copies `cli/nagarectl/contract/v1/` at its pinned revision
and validates its fake `nagarectl` against it (Kotei plan 84, Milestone 2).


## Idempotence and Recovery

Every step is a code change under test; nothing touches a context or a cloud project. Rerunning
the tests is safe. `--accept` overwrites golden files, so review `git diff` after it. If a
landed change to a schema turns out to break the version 1 rules, revert that commit; Kotei pins
a revision, so it is not affected until it moves its pin.


## Interfaces and Dependencies

Libraries:

- `autodocodec` 0.5.0.0 and `autodocodec-schema` 0.2.0.1, from the pinned GHC 9.12.4 package
  set, in the `nagarectl` library.
- `aeson-pretty`, in the `nagarectl` test suite.
- `tasty-golden`, already present.
- `check-jsonschema`, used once in M1 and not in the gate.

New modules:

- `cli/nagarectl/src/Nagare/Contract/V1.hs` exports the seven document records, their codecs,
  `contractVersions :: [Int]` (= `[1]`), and `schemaFor`-style functions returning each
  document's schema `Value`.
- `cli/nagarectl/src/Nagare/Contract/Project.hs` exports pure projections:
  - `transactionOutcome :: TransactionResult -> TransactionOutcome`, with constructors for
    `refused` and `interrupted`;
  - `savedReview`;
  - `imagePublicationResult`;
  - `deployPreview :: ScopeDeclaration -> [ScopeDeclaration] -> DeployPreview`;
  - `inventoryStatusReport`;
  - `publicationList`;
  - `versionInfo`.
- `cli/nagarectl/test/Nagare/Test/Contract.hs` holds the goldens and the schema validation.

Published artifacts: `cli/nagarectl/contract/v1/*.schema.json`,
`cli/nagarectl/contract/v1/samples/*.json` and `cli/nagarectl/contract/README.md`, under
`mori://shinzui/nagare` (artifact-level URI pending).

Consumer: `mori://shinzui/kotei/plans/84-deploy-to-nagare-through-its-reviewed-resource-inventory`.
Differences from what Kotei asked for, to relay at handoff:

- The selector is `--contract 1` rather than `--json`.
- Scopes are `kind:name` text.
- The finding "class" is `category`.
- `closed` and `interrupted` are added to the outcomes.
- The publication listing has `generation` and `usedBy` instead of `acceptedAt`.
- The dry-run envelope adds `scopeDocuments`.
