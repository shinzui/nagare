---
id: 192
slug: publish-a-versioned-json-contract-for-the-nagarectl-outputs-kotei-consumes
title: "Publish Nagare's versioned document contract for Kotei and the read-only admin API"
kind: exec-plan
created_at: 2026-10-13T13:47:33Z
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-10-13T13:47:33Z
---

# Publish Nagare's versioned document contract for Kotei and the read-only admin API

This ExecPlan answers the contract request in
`mori://shinzui/kotei/plans/84-deploy-to-nagare-through-its-reviewed-resource-inventory`
(section "Request to Nagare for a stable public contract"). The operator approved the work on
2026-10-13. It is outside the production-readiness checklist and does not block a release.

Rewritten 2026-10-14 (operator): Nagare will also get an admin API, and that API is read-only.
The documents defined here are therefore Nagare's one public contract, not a set of CLI outputs.
The CLI serves them now behind `--contract 1`; the admin API will later serve the read documents
unchanged over HTTP. The API itself is a separate MasterPlan and is not built here.


## Purpose / Big Picture

Kotei (`mori://shinzui/kotei`) deploys applications to Nagare by running `nagarectl` as a
subprocess. Its first integration broke silently. Kotei parsed a dry-run document,
`{app, resources:[…]}`, that `nagarectl` stopped producing when deploys moved to the reviewed
inventory. Kotei's fake `nagarectl` kept emitting the old shape, and nothing compared the two.

After this change, every `nagarectl` output Kotei reads has a published JSON Schema and golden
sample documents, under `cli/nagarectl/contract/v1/` in this repository
(`mori://shinzui/nagare`, path `cli/nagarectl/contract/v1/`; an artifact-level URI is pending).
The schemas are hand-written standard JSON Schema 2020-12. Nagare's test suite validates every
golden sample, produced by the real projection code, against its schema with a small subset
validator. A changed output that the schema does not allow fails a test, and so does a changed
sample that was not accepted. Kotei copies the schemas at its pinned Nagare revision and tests
its fixtures and its fake `nagarectl` against them with any standard validator. When either side
drifts, a test fails on the side that moved.

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

The documents fall into two classes, recorded in `cli/nagarectl/contract/README.md`:

- **Read documents**: `inventory-status`, `publication-list`, `version-info`, `refusal`, and
  `site-list` (added by [EP-193](193-list-recorded-sites-without-live-provider-observation.md)
  under this contract's rules). The admin API serves exactly these, with the same schemas. Each
  separates what the inventory store recorded from what a provider observed, and says when an
  observation is partial, because the API may run with less provider access than an operator.
- **Operation documents**: `transaction-outcome`, `saved-review`, `image-publication-result` and
  `deploy-preview`. They describe a change, so only the CLI emits them; the read-only API never
  will. Kotei deploys through the CLI.

Every refusal is one shape, the `refusal` object `{code, message}`: a read command prints it as
its document, and a `refused` transaction outcome carries it. The admin API will return the same
body. Three deferred findings are fixed here, because each would otherwise be frozen into the
contract with its current wording: F94 (an `ambiguous` stop drops the adapter's reason), F107 (an
expired gcloud login reads as a store I/O error) and F118 (an unprepared workspace reads as a
mismatched one). They are in `docs/audits/mp23-findings.md`.


## Progress

- [ ] M1: The contract types, the eight hand-written schemas (the seven Kotei documents plus
  `refusal`), the class of each document in the README draft, the subset validator, the golden
  samples and the version listing. Pass: `Nagare.Test.Contract` checks each sample document
  against its golden file and validates every sample against its schema. The validator's own
  tests show it rejects each violation it claims to check (wrong type, missing required field,
  extra field, value outside an enum, wrong `const`, null where not allowed, bad array item) and
  refuses a schema keyword it does not implement. Every schema passes
  `check-jsonschema --check-metaschema` once by hand, recorded in this plan.
  `nagarectl version --json` prints `"contracts":[1]`.
- [ ] M2: `inventory apply` and `inventory resume` with `--contract 1`. Pass: tests cover the
  outcome document and exit code for every `TransactionResult` constructor. They show a
  pre-execution refusal printing `refused` with exit 2, and a failure after execution starts
  never printing `refused`, and a refused outcome carrying a `refusal` object. F94: every
  `StoppedAmbiguous` carries its reason, the human line prints it after a colon, and the contract
  `detail` holds it; a test drives a host recovery decision and a fence refusal through resume and
  sees each reason. Apart from that line, output and exit status without `--contract` are
  byte-for-byte unchanged in the existing suites.
- [ ] M3: `app image-plan`, `app deploy --save-plan` and `app deploy --dry-run` with
  `--contract 1`. Pass: CLI-level tests on the existing app-deploy fixtures emit documents equal
  to the golden samples. The deploy preview has the same top-level keys with and without hooks.
- [ ] M4: `inventory status --contract 1 [--scope SCOPE]` and `inventory publications
  --contract 1`. Pass: tests over the existing status fixtures show findings for the selected
  scope only, and an unknown scope refuses. A publication fixture lists resource ID, key,
  destination, both digests, generation, and the application scopes whose accepted
  `imageResource` names it. Read commands under `--contract 1` print a `refusal` document on
  failure. F107: a store read failing on an expired gcloud login refuses with code
  `reauthentication-required` and a message naming `gcloud auth login`, with and without
  `--contract`. F118: status against a context whose workspace directory does not exist refuses
  with `workspace-not-prepared`, not "mismatched manifest". Each has a test that fails before the
  fix.
- [ ] M5: Clean up and hand off. Delete `renderPlan`, `AppDeployPlan` and `renderAppObjects`,
  and fix the stale comment in `Options.hs`. Add `cli/nagarectl/contract/README.md` and a
  "Machine-readable contract" section in `docs/user/reference.md`. The README states the two
  document classes and that the admin API serves the read class only. Pass: `just haskell-style-check`
  and `just gate-fast` are green, then `just land`. The contract path and the landed commit hash
  (copied from `git log`) are sent to the `kotei` session, and the M1 commit hash to whichever
  session implements EP-193.


## Decision Log

- Decision (2026-10-14, operator): Nagare's admin API is read-only. This plan becomes Nagare's
  one public document contract instead of a CLI-output contract for Kotei. The seven document
  shapes Kotei designed against (Kotei plan 84, Milestone 2) are kept exactly, so Kotei has no
  rework; what changes is the framing, the added `refusal` document, and the rules below. The
  admin API is not built here; its MasterPlan serves the read documents from
  `cli/nagarectl/contract/v1/` and adds no second schema set. Its OpenAPI 3.1 description, if it
  has one, references these files, since OpenAPI 3.1 uses the same JSON Schema 2020-12 dialect.
- Decision (2026-10-14): Two document classes. Read documents (`inventory-status`,
  `publication-list`, `version-info`, `refusal`, and EP-193's `site-list`) are served by the CLI
  and the admin API. Operation documents (`transaction-outcome`, `saved-review`,
  `image-publication-result`, `deploy-preview`) are CLI-only, because the API never changes
  anything. A read document keeps recorded facts (from the store) and observed facts (from
  providers) in separate fields and states completeness (`observationComplete`), because the API
  may observe less than an operator's CLI. Nothing in a read document may require operator
  credentials to be meaningful.
- Decision (2026-10-14): One refusal shape, `{code, message}`, with `code` from a closed enum:
  `unknown-scope`, `unsupported-contract-version`, `wrong-context`, `review-changed`,
  `admission-refused`, `store-unavailable`, `reauthentication-required`,
  `workspace-not-prepared` and `other`. Read commands print it as a `refusal` document; a
  `refused` transaction outcome carries it as `refusal`. The CLI exit codes stay as below, and
  the admin API's plan maps codes to HTTP statuses. A new code is an additive enum value under
  the README rule. Classify only the sources this plan names; everything else is `other` with the
  existing message, so no refusal is lost.
- Decision (2026-10-14): Fix F94, F107 and F118 here. Each would otherwise be published in the
  contract with misleading content: F94 as an `ambiguous` outcome with a null `detail`, F107 as a
  `store-unavailable` refusal for what is an expired login, and F118 as a mismatch for a
  workspace that was never prepared. F94 deliberately changes one human line (`ambiguous <tx> at
  <op>` gains `: <reason>`); every other human output stays byte-identical.
- Decision (2026-10-14): EP-193's `site list` JSON is this contract's `site-list` document,
  emitted under `--contract 1` and added to `cli/nagarectl/contract/v1/` with its schema and
  samples by EP-193, after this plan's M1 lands. EP-193 keeps its query and acceptance; only its
  output format follows these rules.

- Decision (2026-10-13): Contract output is selected by `--contract 1`, not by `--json`. The
  existing `--json` documents (`inventory status`, `inventory explain`, `app deploy --dry-run`)
  stay operator-facing and unchanged. Runbooks such as `docs/runbooks/inventory-operations.md`
  read fields that are not part of the contract, and the release notes in
  `docs/releases/v0.6.0.md` tell operators to use `inventory status --json`. The flag is also the
  selector Kotei asked for to keep an older major version available, so a future
  `--contract 2` needs no new mechanism.
- Decision (2026-10-13, operator): Hand-write the schemas and check the outputs with a small
  subset validator in the test suite. Add no JSON Schema library. Haskell has no maintained
  general JSON Schema validator. `autodocodec-schema` (considered first) generates schemas from
  codecs, but it does not document which draft it emits, and it would add a dependency to the
  release closure. The seven documents use only `type`, `properties`, `required`,
  `additionalProperties: false`, `enum`, `const`, nullable types, `items` and `description`,
  which a validator of about 150 lines covers. The schemas declare JSON Schema 2020-12, so Kotei
  can use any standard validator. Encoder and schema are no longer tied by construction. Drift
  is caught because every projected sample is validated, `additionalProperties: false` rejects
  undeclared fields, and samples cover every enum value and both dry-run shapes. The review
  rule in `cli/nagarectl/contract/README.md` is that every new field gets a sample.
- Decision (2026-10-13, amended 2026-10-14): The contract types live in their own module,
  `Nagare.Contract.V1` (plain records with hand-written `ToJSON`, importing nothing from Nagare),
  with `Nagare.Contract.Project` holding the pure projections from internal values. Both are in
  the `nagarectl` library (`src/`), never in `app/`, so the admin API executable can link them as
  `nagared` links the library today. Kotei never links them; it reads the documents, from the CLI
  now and possibly from the admin API for the read class later. Internal types keep their own aeson instances. Contract types
  are encode-only inside `nagarectl`: per ADR 22, decoding JSON never grants authority, so no
  command reads a contract document back.
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
package uses a JSON Schema library, and this plan adds none. `tasty-golden` is already a test
dependency of `nagarectl` (`cli/nagarectl/nagarectl.cabal:709`), and its one golden test is
`test/Nagare/Test/Task.hs:174-177`. `nagare-dsl` has many YAML goldens. Test modules are
registered in `test/Nagare/Test/Suite.hs` (see `test/README.md`).

**Dead pre-inventory contract.** `renderPlan`, `AppDeployPlan`, `RenderedObject` and
`renderAppObjects` in `src/Nagare/App/Deploy.hs` (lines 34-36, 345-409) were the old Kotei
contract. Only `test/AppDeploySpec.hs` uses them (lines 92 and 4735-4767). `toRenderedObject` is
also used by `stampAppLabel`'s local `describe` (`Deploy.hs:338`). `app/Nagare/Cli/Options.hs:154-157`
still calls `--json` "the kotei contract".

**The admin API to come.** The operator decided on 2026-10-14 that Nagare gets a read-only admin
API, built under its own MasterPlan. Nothing here builds it. The relevant precedent is
`nagared` (`cli/nagarectl/nagared/Main.hs`), an HTTP executable in the same Cabal package that
links the `nagarectl` library, so code in `src/` is reachable from a future API executable and
code in `app/` is not. The store-only reads that suit an API already exist:
`loadTargetSnapshotReadOnly` (`Command.hs:940`) and `inventory store status`
([EP-185](185-make-inventory-status-answer-in-seconds.md)). Full `inventory status` builds its
provider observers in `app/Nagare/Cli/Commands/Inventory/Status.hs`; how the API observes is its
own plan's decision, which is why `observationComplete` must stay honest.

**The three findings fixed here** (full text in `docs/audits/mp23-findings.md`):

- F94. `src/Nagare/Inventory/Execute/Driver.hs`, `runOperationsWith` (around lines 168-201),
  returns `StoppedAmbiguous transaction operation` from every recovery stop: a recovery decision naming
  an operation not in the review, `preparedFor` failing, `lookupAdapter` failing, an adapter
  identity or version mismatch, `selectedFence` refusing, a recovery decision for another
  operation, and every non-complete `adapterRecover` decision (`RecoveryUnresolved`,
  `RecoveryLandedUnready`, `RecoveryTargetReplaced`, `RecoveryTerminalFailure`, and a disallowed
  `RecoverySafeToRetry`). Each has a reason in hand (the `Left` value or the decision's text) and
  drops it. Observed on 2026-10-09: a host whose timer reverted the upgrade said only
  `ambiguous tx-… at op-…`, while `Adapters/Host.hs` `recoveryState` had the exit ("close the
  transaction and review the change again").
- F107. `src/Nagare/Inventory/Store/Target.hs` (lines 147, 166, 183) turns every
  `IOException` from the remote store's `gcloud` calls into `StoreIoError (show err)`, so an
  expired login reads as an I/O error (and on a conditional write as `StoreConditionFailed`).
  The fix recognizes gcloud's reauthentication failure in the captured stderr and reports it
  as its own `StoreError` constructor (`StoreAuthRequired`), rendered with a `gcloud auth login`
  instruction.
- F118. `src/Nagare/Platform/Workspace.hs`, `validateExisting` (around line 217), maps a failed
  read of `.nagare-workspace.json` to `ExistingWorkspaceMismatch root`, which renders as
  "existing Nagare platform workspace has a mismatched manifest" even when the directory does not
  exist. The fix returns a new `WorkspaceNotPrepared root` when the file is absent, rendered as
  "the platform workspace for this context is not prepared", naming the commands that prepare
  it (those that call `preparePlatformWorkspace`, in `app/Nagare/Cli/Runtime/Target.hs` and
  `app/Nagare/Cli/Platform/Upgrade.hs`). `inventory status` never prepares a workspace, so the
  refusal itself is correct; only its words change.

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


## Plan of Work

**M1 — contract types, schemas and validator.** Create `src/Nagare/Contract/V1.hs` with one
plain record per document and a hand-written `ToJSON` each:

- `TransactionOutcome`
- `SavedReview`
- `ImagePublicationResult`
- `DeployPreview`
- `InventoryStatusReport`
- `PublicationList`
- `VersionInfo`
- `Refusal`, `{code, message}`, also embedded as `refusal` in `TransactionOutcome`

The first four are operation documents and the rest are read documents (see Decision Log). Draft
`cli/nagarectl/contract/README.md` in M1 with the class of each document, so the classes are fixed
before any command emits one. Every document except `VersionInfo` has a required `contractVersion` field, constant 1 in V1, and
a `document` field naming its kind. `VersionInfo` is the discovery document: it keeps today's
`version`, `platformVersion`, optional `revision` and optional `tools`, and gains
`contracts: [Int]`. Create `src/Nagare/Contract/Project.hs` with pure functions from internal
values to these records. Route `version --json` through `VersionInfo`, so that output's only
change is the new `contracts` field.

Hand-write one schema per document in `cli/nagarectl/contract/v1/<name>.schema.json`. Each
declares `"$schema": "https://json-schema.org/draft/2020-12/schema"`, an `$id` naming the
document and version, and `additionalProperties: false` on every object except the opaque
`scopeDocuments` items. It uses only these keywords: `$schema`, `$id`, `title`, `description`,
`type` (a name or a list including `"null"`), `properties`, `required`,
`additionalProperties`, `enum`, `const` and `items`. Descriptions carry the meaning Kotei relies
on: what `configDigest` covers, that `refused` means no provider was touched, and that
`observationComplete: false` means the findings are partial.

Write the subset validator in `test/Nagare/Test/Contract/Validate.hs`:
`validate :: Value -> Value -> Either [Text] ()`, schema first. Each error names the JSON path.
It implements exactly the keywords above, and it returns an error for any other keyword found
in a schema, so a schema can never use something the validator silently ignores. Its tests use
small inline schemas, one per rule, each with a passing and a failing value.

Add `test/Nagare/Test/Contract.hs` and register it in `test/Nagare/Test/Suite.hs`. For each
document it has:

- a tasty-golden test writing a sample built through `Project`, from fixed internal values, to
  `cli/nagarectl/contract/v1/samples/<name>*.json`, pretty-printed with sorted keys and a
  trailing newline (`aeson-pretty`, added to the test suite; it is in the pinned set and already
  used by `cli/nagare-harness`);
- a test that every sample validates against its schema file;
- a test that every schema file passes the validator's keyword check.

Samples cover every `outcome` value, every `failureClass` value, and a deploy preview with and
without hooks. Run `check-jsonschema --check-metaschema` over the seven schema files once by
hand and record the result in Progress; the gate does not run it.

**M2 — apply and resume.** Add `--contract VERSION` to `inventory apply` and
`inventory resume`; it accepts only `1` and otherwise refuses with the supported list. With it,
print one `TransactionOutcome`. Its fields are:

- `outcome`: `converged`, `paused`, `stopped`, `ambiguous`, `closed`, `refused` or `interrupted`
- `transaction` (nullable)
- `operation` (nullable)
- `failureClass`: `known-no-effect`, `partial-or-unknown` or null
- `barriers` (strings)
- `detail` (nullable text): the stop's reason for `stopped`, `ambiguous` and `interrupted`
- `refusal` (nullable `{code, message}`): set exactly when `outcome` is `refused`

The exit codes are 0 converged, 2 refused, 3 paused, 4 stopped, 5 ambiguous, 6 closed and
7 interrupted. Code 1 stays for a crash the handler could not classify.

Refusals are captured in `app/Nagare/Cli/Runtime/Error.hs` and `src/Nagare/Inventory/Command.hs`.
A contract sink is set once, when `--contract` is parsed. While the sink is set, `dieT` and
`dieText` print the outcome document instead of the stderr line. The outcome is `refused` until
the sink is switched to the executing phase, then `interrupted` with the transaction ID. The switch
goes in `applyReviewed`'s path at the point where admission has succeeded and before the first
intent is written; find that point in `src/Nagare/Inventory/Execute/`. An unexpected exception
under the sink also yields `interrupted` once executing. Without the sink, `dieT` and `dieText`
behave exactly as now. The sink fills `refusal.code` from the refusal's source:
`unsupported-contract-version` for the flag itself, `wrong-context` for the context check,
`review-changed` for a bundle that no longer verifies, `admission-refused` for admission errors
(`Command.hs:522-536`), `store-unavailable` and `reauthentication-required` for store errors,
and `other` for any `dieT`/`dieText` this plan does not classify. Classify at the call sites,
by passing a code to a coded variant of `dieT`, not by matching message text.

F94: give `StoppedAmbiguous` a third field, the reason as `Text`, and fill it at every
construction site in `Driver.hs` from the value already in hand (render the `Left` error, or the
recovery decision's own text). `renderTransactionResult` prints
`ambiguous <tx> at <op>: <reason>`; this is the only human line that changes. The contract
`detail` carries the same reason. Every other `renderTransactionResult` line stays unchanged.

**M3 — publication, saved review and preview.** Add `--contract VERSION` to `app image-plan` and
`app deploy`. Give `planInventoryCandidateWith` and its two siblings a way to return the digest,
the bundle directory, the scope IDs (keys of `reviewBundleScopes`) and the lineage lines, instead
of only printing them. With `--contract 1`, print a `SavedReview`:
`{review:{sha256, directory}, scopes:[…], rebinds:[…], rebuilds:[…]}`.

`app image-plan --contract 1` prints an `ImagePublicationResult`:
`{imageResource, review:{sha256, directory|null}, transaction: TransactionOutcome|null}`. The
transaction is filled when it converged in-process; the exit code follows the M2 rules.

`app deploy --dry-run --contract 1` prints a `DeployPreview` with the same keys for every config:

- `application`: `{scope, configDigest, overrides}`
- `hooks`: a list of the same shape
- `scopeDocuments`: the canonical scope values, schema type "any", documented as opaque audit
  data whose `bundles` are outside the contract

The schema description of `configDigest` says what it covers and what it does not, as in Context
above. `app deploy` with `--contract` but neither `--save-plan` nor `--dry-run` refuses, since a
live unreviewed apply has no contract document.

**M4 — status and publications.** Add `--contract VERSION` and `--scope KIND:NAME` to
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

Under `--contract 1`, a read command that refuses prints a `Refusal` document on stdout and exits
2, through the same coded sink as M2: `unknown-scope` for `--scope`, `unsupported-contract-version`,
`store-unavailable`, `reauthentication-required` and `workspace-not-prepared`, and `other` for the
rest. Without `--contract`, the stderr message is the same text as the `message` field.

F107: add a `StoreAuthRequired` constructor to `StoreError` (`src/Nagare/Inventory/Store.hs:100`).
In `src/Nagare/Inventory/Store/Target.hs`, where a gcloud failure becomes `StoreIoError`, inspect
the failing command's stderr and return `StoreAuthRequired` when it shows a missing or expired
login: gcloud's token-refresh failure ("There was a problem refreshing your current auth tokens",
"Reauthentication failed") or no credentialed account. Capture the no-account text safely with an
isolated, empty gcloud configuration, which never touches the operator's login:
`CLOUDSDK_CONFIG=$(mktemp -d) gcloud storage ls gs://<the context's inventory bucket>`. Never run
`gcloud auth revoke` for this; it revokes the operator's real tokens. Put both texts in test
fixtures. Render the error as "the gcloud login is missing or expired; run `gcloud auth login`
and retry". `Discovery.hs:64` reports `StoreIoError` as unavailable; treat `StoreAuthRequired`
the same way there.

F118: add `WorkspaceNotPrepared` to `WorkspaceError` and return it from `validateExisting` when
`.nagare-workspace.json` does not exist, keeping `ExistingWorkspaceMismatch` for a manifest that
exists and differs. Render it as described in Context.

**M5 — cleanup and handoff.** Delete the dead pre-inventory contract (see Decision Log) and its
tests in `test/AppDeploySpec.hs`, and fix `app/Nagare/Cli/Options.hs:154-157`. Finish
`cli/nagarectl/contract/README.md`. It lists the documents, their class (read or operation) and
their commands, the refusal codes, and the exit-code table. It states that the admin API serves
read documents only, with these schemas, and that a read document never needs operator
credentials to be meaningful (recorded and observed facts are separate fields, and partial
observation is flagged). It states the versioning rules: additive changes keep major 1 and add only optional fields
or new enum values announced in the README; anything else is version 2, and nagarectl keeps
emitting version 1 for at least one release behind `--contract 1`. It also says that every new
field or enum value gets a golden sample in the same change, and how to accept goldens. Add the "Machine-readable contract" section to `docs/user/reference.md` pointing at it.
Gate, land, and send the path and landed hash to the `kotei` session, with the differences
listed under Interfaces. Mark F94, F107 and F118 Verifying in `docs/audits/mp23-findings.md`
with the landed hash.


## Concrete Steps

Focused development loop, from `cli/nagarectl`:

```bash
cabal test nagarectl-test --offline --test-show-details=failures --test-options='-p /Contract/'
cabal test nagarectl-test --offline --test-show-details=failures --test-options='-p /Contract/ --accept'
```

The first run after adding a sample fails with a missing golden file. `--accept` writes it.
Review the written sample with `git diff` before committing. A changed schema file or a changed
sample shape is a contract change, and the README versioning rule applies.

M1 one-time standard-validator check, from the repository root (check-jsonschema 0.38.0 is in
the pinned nixpkgs):

```bash
nix shell --inputs-from . nixpkgs#check-jsonschema -c \
  check-jsonschema --check-metaschema cli/nagarectl/contract/v1/*.schema.json
nix shell --inputs-from . nixpkgs#check-jsonschema -c \
  check-jsonschema --schemafile cli/nagarectl/contract/v1/transaction-outcome.schema.json \
  cli/nagarectl/contract/v1/samples/transaction-outcome-*.json
```

Expected: `ok -- validation done` for each.

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
- For each of the eight documents, the sample goldens equal the projected documents and every
  sample validates against its hand-written schema. The validator rejects each violation in its
  own tests and refuses an unimplemented schema keyword.
- Each M2 constructor case prints the expected outcome and exits with the expected code. A
  refusal before admission (for example omitting `--yes`) prints
  `{"contractVersion":1,"document":"transaction-outcome","outcome":"refused",…,"refusal":{"code":…}}`
  and exits 2.
  A failure injected after admission prints `interrupted` with a non-null `transaction` and
  exits 7.
- Without `--contract`, the existing suites pass unchanged except the F94 line. `inventory apply`
  still prints `converged tx-…` and exits 0 or 1, and an ambiguous stop prints
  `ambiguous tx-… at op-…: <reason>`.
- `app deploy --dry-run --contract 1` on `cluster/examples/multi-workload-app` (which has hooks)
  and on an example without hooks produces documents with identical top-level key sets.
- `inventory status --contract 1 --scope application:<name>` lists only that scope's findings,
  and an unknown scope prints a `refusal` document with code `unknown-scope` and exits 2.
- F107: with a store whose gcloud call fails with either fixture text, `inventory status`
  refuses with code `reauthentication-required` and the `gcloud auth login` instruction.
- F118: `inventory status` against a context with no workspace directory refuses with code
  `workspace-not-prepared`; a workspace whose manifest differs still reports the mismatch.
- The README names each document's class, and every read-document schema separates recorded
  from observed fields.

Kotei's side, not required here: it copies `cli/nagarectl/contract/v1/` at its pinned revision
and validates its fake `nagarectl` against it (Kotei plan 84, Milestone 2).


## Idempotence and Recovery

Every step is a code change under test; nothing touches a context or a cloud project. Rerunning
the tests is safe. `--accept` overwrites golden files, so review `git diff` after it. If a
landed change to a schema turns out to break the version 1 rules, revert that commit; Kotei pins
a revision, so it is not affected until it moves its pin.


## Interfaces and Dependencies

Libraries:

- No new library dependency. No JSON Schema library is added (see Decision Log).
- `aeson-pretty`, added to the `nagarectl` test suite only.
- `tasty-golden`, already present.
- `check-jsonschema`, from the pinned nixpkgs, run once by hand in M1 and not in the gate.

New modules:

- `cli/nagarectl/src/Nagare/Contract/V1.hs` exports the eight document records (`Refusal` among
  them) with their `ToJSON` instances, a `RefusalCode` enum,, and `contractVersions :: [Int]` (= `[1]`).
- `cli/nagarectl/src/Nagare/Contract/Project.hs` exports pure projections:
  - `transactionOutcome :: TransactionResult -> TransactionOutcome`, with constructors for
    `refused` and `interrupted`;
  - `savedReview`;
  - `imagePublicationResult`;
  - `deployPreview :: ScopeDeclaration -> [ScopeDeclaration] -> DeployPreview`;
  - `inventoryStatusReport`;
  - `publicationList`;
  - `versionInfo`;
  - `refusal :: RefusalCode -> Text -> Refusal`.
- Changed internal types: `StoppedAmbiguous` gains a reason (`Text`) (F94); `StoreError` gains
  `StoreAuthRequired` (F107); `WorkspaceError` gains `WorkspaceNotPrepared` (F118).
- `cli/nagarectl/test/Nagare/Test/Contract/Validate.hs` holds the subset validator,
  `validate :: Value -> Value -> Either [Text] ()`.
- `cli/nagarectl/test/Nagare/Test/Contract.hs` holds the sample goldens and the schema checks.

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
- The schemas declare JSON Schema 2020-12 and use a small keyword subset, so any standard
  validator works on Kotei's side.
- (2026-10-14) A `refused` outcome carries `refusal: {code, message}`, and read commands print
  a `refusal` document when they refuse. `detail` of an `ambiguous` outcome now always holds the
  reason.
- (2026-10-14) The contract is also the future read-only admin API's: the read documents will be
  served over HTTP with the same schemas. Kotei may read status and publications from it later;
  deploys stay on the CLI.
