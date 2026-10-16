---
id: 192
slug: publish-a-versioned-json-contract-for-the-nagarectl-outputs-kotei-consumes
title: "Publish Nagare's versioned document contract for Kotei and the read-only admin API"
kind: exec-plan
created_at: 2026-10-13T13:47:33Z
master_plan: "docs/masterplans/28-serve-nagare-s-recorded-state-through-a-read-only-admin-api.md"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-10-13T13:47:33Z
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-15T00:19:10Z
      mode: "update"
      note: "MasterPlan 28 design review for the admin UI and Kotei: one recorded-state reader, admin.<base> origin, service-account bearer, Deployment+NetworkPolicy, gateway problem documents, ETag/head summary"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-16T22:20:47Z
      mode: "update"
      note: "Source-based API validation: correct shared interfaces, bounded read costs, HTTP behavior and serving acceptance."
---

# Publish Nagare's versioned document contract for Kotei and the read-only admin API

This ExecPlan answers the contract request in
`mori://shinzui/kotei/plans/84-deploy-to-nagare-through-its-reviewed-resource-inventory`
(section "Request to Nagare for a stable public contract"). The operator approved the work on
2026-10-13. It is outside the production-readiness checklist and does not block a release.

Rewritten 2026-10-14 (operator), twice. First: Nagare gets an admin API, and it is read-only, so the
documents here are Nagare's one public contract, served by the CLI now (`--contract 1`) and by the
API later. Second: the contract follows the haskell-jitsurei API standards, so its schemas are
derived from the Haskell types with `openapi-hs` instead of hand-written, and errors are RFC 9457
problem documents. This plan is EP-192 in
[MasterPlan 28](../masterplans/28-serve-nagare-s-recorded-state-through-a-read-only-admin-api.md),
which builds the API.


## Purpose / Big Picture

Kotei (`mori://shinzui/kotei`) deploys applications to Nagare by running `nagarectl` as a
subprocess. Its first integration broke silently. Kotei parsed a dry-run document,
`{app, resources:[…]}`, that `nagarectl` stopped producing when deploys moved to the reviewed
inventory. Kotei's fake `nagarectl` kept emitting the old shape, and nothing compared the two.

After this change, every document Kotei reads, and every document the admin API will serve, is a
Haskell type in a new, dependency-light package, `cli/nagare-contract`, with a `ToSchema` derived
from the same aeson options as its JSON codec. An executable, `nagare-contract-openapi`, writes
their schemas into one OpenAPI 3.1 document, `docs/api/openapi.json` (as `components.schemas`;
the API adds paths later). The file is a generated artifact, never edited by hand, and a test fails
when the checked-in file differs from the generated one. Golden sample documents, produced by the
real projection code, are in `docs/api/samples/`, and a test validates every sample against its
type's schema (`validateToJSON`). Kotei copies `docs/api/` at its pinned Nagare revision and
validates its fixtures and its fake `nagarectl` against `#/components/schemas/<Name>`, with
`openapi-hs`'s `validateJSON` or any JSON Schema 2020-12 validator (OpenAPI 3.1 schemas are that
dialect). When either side drifts, a test fails on the side that moved.

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
`--contract`, every command prints what it prints today (one exception, F94, below), so operator
runbooks and the existing `--json` documents do not change.

The documents fall into two classes, recorded in `docs/api/README.md`:

- **Read documents**: `inventory-status`, `publication-list`, `version-info`, and `site-list`
  (added by [EP-193](193-list-recorded-sites-without-live-provider-observation.md) under this
  contract's rules). Their item types (`ScopeState`, `Finding`, `Publication`, `SiteSummary`) are
  what the admin API returns inside its paginated responses. Each separates what the inventory
  store recorded from what a provider observed, and says when an observation is partial.
- **Operation documents**: `transaction-outcome`, `saved-review`, `image-publication-result` and
  `deploy-preview`. They describe a change, so only the CLI emits them; the read-only API never
  will. Kotei deploys through the CLI.

Every refusal is an RFC 9457 problem document,
`{type, title, status, detail, code, retryable}` (`mori://shinzui/haskell-jitsurei/docs/api-rfc9457-problem-details`):
a read command prints it as its document, a `refused` transaction outcome carries it as
`problem`, and the admin API returns the same body as `application/problem+json`. Three deferred
findings are fixed here, because each would otherwise be frozen into the contract with its current
wording: F94 (an `ambiguous` stop drops the adapter's reason), F107 (an expired gcloud login reads
as a store failure) and F118 (an unprepared workspace reads as a mismatched one). They are in
`docs/audits/mp23-findings.md`.


## Progress

- [ ] M1: The `nagare-contract` package and the generated document. Pass: `cli/nagare-contract`
  holds `Nagare.Contract.V1` (every document and item type, `ToJSON`/`FromJSON`/`ToSchema` from
  one shared `Options` each) and `Nagare.Contract.Problem` (`ProblemDetails`, `ProblemJSON`, the
  problem catalog); `nagare-contract-openapi` writes `docs/api/openapi.json`; tests pass that the
  checked-in document equals the generated one, that every golden sample in `docs/api/samples/`
  equals its projected document and validates (`validateToJSON`), that the base `ProblemDetails` encodes
  with the keys `type`, `title`, `status`, `detail`, `code`, `retryable`, while the shared
  gateway problem encoder permits optional `error` and `login` extension members, and that every
  catalog code has one status and one title. `docs/api/README.md` drafted with each document's
  class. Pure version, scope-state and publication projections in `Nagare.Contract.Project`
  are complete from existing internal head/declaration values, including publication `usedBy`;
  no `RecordedState` import or CLI dispatch is needed for them. Projection goldens for later
  outcome/command changes land with their owning milestone, rather than blocking this foundation.
  `nagarectl version --json` prints `"contracts":[1]`.
- [ ] M2: `inventory apply` and `inventory resume` with `--contract 1`. Pass: tests cover the
  outcome document and exit code for every `TransactionResult` constructor. They show a
  pre-execution refusal printing `refused` with exit 2 and a `problem` whose `code` names its
  source, and a failure after execution starts never printing `refused`. F94: every
  `StoppedAmbiguous` carries its reason, the human line prints it after a colon, and the contract
  `detail` holds it; a test drives a host recovery decision and a fence refusal through resume and
  sees each reason. Apart from that line, output and exit status without `--contract` are
  byte-for-byte unchanged in the existing suites.
- [ ] M3: `app image-plan`, `app deploy --save-plan` and `app deploy --dry-run` with
  `--contract 1`. Pass: CLI-level tests on the existing app-deploy fixtures emit documents equal
  to the golden samples. The deploy preview has the same top-level keys with and without hooks.
- [ ] M4: `inventory status --contract 1 [--scope SCOPE]` and `inventory publications
  --contract 1`. Pass: tests over the existing status fixtures show findings for the selected
  scope only, and an unknown scope prints a problem with code `unknown_scope`. A publication
  fixture lists resource ID, key, destination, both digests, generation, and the application
  scopes whose accepted `imageResource` names it. F107: a gcloud credential failure whose stderr
  shows a missing or expired login refuses with code `reauthentication_required` and a
  `gcloud auth login` instruction, with and without `--contract`. F118: status against a context
  whose workspace manifest does not exist refuses with `workspace_not_prepared`, not "mismatched
  manifest". Each has a test that fails before the fix.
- [ ] M5: Clean up and hand off. Delete `renderPlan`, `AppDeployPlan` and `renderAppObjects`,
  and fix the stale comment in `Options.hs`. Finish `docs/api/README.md` and add a
  "Machine-readable contract" section in `docs/user/reference.md`. Pass: `just haskell-style-check`
  and `just gate-fast` are green, then `just land`. The contract path and the landed commit hash
  (copied from `git log`) are sent to the `kotei` session with the differences under Interfaces,
  and the M1 hash to whichever session implements EP-193. F94, F107 and F118 are marked Verifying
  in `docs/audits/mp23-findings.md` with the landed hash.


## Decision Log

- Decision (2026-10-14, operator): The schemas are derived from the Haskell types with the
  released `openapi-hs` / `servant-openapi-hs` cohort and written to `docs/api/openapi.json` by an
  executable, per `mori://shinzui/haskell-jitsurei/docs/api-openapi-from-types`. This supersedes the
  2026-10-13 decision to hand-write JSON Schemas and check them with a test-local subset validator:
  that decision rested on Haskell having no maintained schema library, and `openapi-hs` (OpenAPI 3.1,
  JSON Schema 2020-12, with `validateToJSON`/`validateJSON`) is the fleet's maintained one. The
  dependency enters the release closure; that is accepted. Encoder and schema are tied by one
  shared aeson `Options` per type, and the conformance test holds them together.
- Decision (2026-10-14, operator): Nagare's admin API is read-only, and this plan is the one
  public contract it serves (MasterPlan 28). The seven document shapes Kotei designed against
  (`mori://shinzui/kotei/plans/84-deploy-to-nagare-through-its-reviewed-resource-inventory`, Milestone 2) are kept field for field, so Kotei's decoding has no rework; what
  moves is where the schemas are published (`docs/api/openapi.json` instead of per-document files)
  and the error shape (a problem document).
- Decision (2026-10-14): The types live in their own package, `cli/nagare-contract`, depending
  on `base`, `text`, `aeson`, `containers`, `openapi-hs` and the small Servant/media-type
  dependencies required by `ProblemJSON` (`Accept`/`MimeRender`), with no Nagare dependency. A client (Kotei, the admin API's
  route package, a UI's generator) can depend on it without `nagarectl`. The projections from
  internal values stay in the `nagarectl` library as `Nagare.Contract.Project` (in `src/`, never
  `app/`), so the API server can link them. Inside `nagarectl` the contract types are only
  encoded: per ADR 22, decoding JSON never grants authority, so no command reads one back.
  `FromJSON` exists for clients and for the conformance tests.
- Decision (2026-10-14): Two document classes. Read documents (`inventory-status`,
  `publication-list`, `version-info`, EP-193's `site-list`) are served by the CLI and the admin
  API; the API returns their item types inside Relay connections, so a list's item shape is
  defined once, here. Operation documents (`transaction-outcome`, `saved-review`,
  `image-publication-result`, `deploy-preview`) are CLI-only. A read document keeps recorded facts
  (from the store) and observed facts (from providers) in separate fields and states completeness
  (`observationComplete`). Nothing in a read document may need operator credentials to be
  meaningful.
- Decision (2026-10-14): Every refusal is a `ProblemDetails` (RFC 9457) with `type` always
  `about:blank`, a `title` equal to the HTTP status phrase (the domain-specific reason is in
  `code` and `detail`, per RFC 9457 section 4.2.1), `status` the HTTP status the API would answer, and a
  `snake_case` `code` from a catalog (`problemCatalog`, shomei's pattern): `unknown_scope` (404),
  `unsupported_contract_version` (400), `wrong_context` (409), `review_changed` (409),
  `admission_refused` (409), `store_unavailable` (503, retryable), `reauthentication_required`
  (503), `workspace_not_prepared` (409) and `unclassified` (500). The CLI keeps its exit codes and
  ignores `status`. `unclassified` carries any `dieT`/`dieText` this plan does not classify, with
  its existing message in `detail`, so no refusal is lost. A new code is an additive catalog entry.
- Decision (2026-10-14): Fix F94, F107 and F118 here. Each would otherwise be published with
  misleading content: F94 as an `ambiguous` outcome with a null `detail`, F107 as a
  `store_unavailable` problem for what is an expired login, and F118 as a mismatch for a workspace
  that was never prepared. F94 deliberately changes one human line (`ambiguous <tx> at <op>` gains
  `: <reason>`); every other human output stays byte-identical.
- Decision (2026-10-14): EP-193's `site list` JSON is this contract's `site-list` document, with
  `SiteSummary` items, added to `nagare-contract` by EP-193 after this plan's M1 lands.
- Decision (2026-10-13): Contract output is selected by `--contract 1`, not by `--json`. The
  existing `--json` documents (`inventory status`, `inventory explain`, `app deploy --dry-run`)
  stay operator-facing and unchanged. Runbooks such as `docs/runbooks/inventory-operations.md`
  read fields that are not part of the contract, and the release notes in
  `docs/releases/v0.6.0.md` tell operators to use `inventory status --json`. The flag is also the
  selector Kotei asked for to keep an older major version available, so a future
  `--contract 2` needs no new mechanism.
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
  into `docs/api/README.md`. It is not implemented until a version 2 exists.
- Decision (2026-10-14, MasterPlan 28 review): `inventory publications` and the recorded half of
  `inventory status` are wired to EP-193 M1's `RecordedState`, so M4 has EP-193 M1 as a hard
  dependency; the rest of this plan has none. Every read document the CLI and the API share is a
  projection of the same checked head/declarations. VersionInfo is build metadata, and HTTP
  head/scope summaries use the checked head without hydrating declarations.


2026-10-16: Validation moves pure API-facing version/scope/publication projections into M1,
leaving their CLI wiring in M4, so HTTP delivery does not wait for transaction CLI work. The
shared problem schema permits the gateway's compatibility extensions, `about:blank` uses HTTP
status titles, and new enum cases require an explicit forward-compatible decoding policy.


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
package uses a schema library yet; this plan adds `openapi-hs`. `tasty-golden` is already a test
dependency of `nagarectl` (`cli/nagarectl/nagarectl.cabal:709`), and its one golden test is
`test/Nagare/Test/Task.hs:174-177`. `nagare-dsl` has many YAML goldens. Test modules are
registered in `test/Nagare/Test/Suite.hs` (see `test/README.md`). Haskell packages are built by
nixpkgs' `haskell.packages.ghc9124` with overrides in `nix/haskell-packages.nix` (line 45); a
package the set lacks is added there. `openapi-hs` 5.0.0 is in neither the set nor the pinned
`all-cabal-hashes` (checked 2026-10-14 against the nixpkgs of 2026-09-10 that `haskell-nix-dev`
pins), so `callHackage` cannot find it: add it with `callHackageDirect` and the Hackage tarball's
`sha256`, not the `generic-lens` pattern. A new Cabal
package is also added to the payload copy in `nix/platform-package.nix`, as `cli/nagare-access` is.

**The standards this follows.** `mori://shinzui/haskell-jitsurei/docs/api-openapi-from-types`
(derive, never hand-write; write the artifact from an executable; sorted keys and a trailing
newline; a test that reads the artifact; the `ToSchema Value` instance that opaque payloads need)
and `mori://shinzui/haskell-jitsurei/docs/api-rfc9457-problem-details` (the problem shape, its
shared `Options` that renames `problemType` to `type`, the catalog pattern, `ProblemJSON`). Use
`openapi-hs >=5.0 && <5.1` (5.0.0 on Hackage, 2026-10-14); re-check Hackage and the upstream tags
before setting bounds.

**Dead pre-inventory contract.** `renderPlan`, `AppDeployPlan`, `RenderedObject` and
`renderAppObjects` in `src/Nagare/App/Deploy.hs` (lines 34-36, 345-409) were the old Kotei
contract. Only `test/AppDeploySpec.hs` uses them (lines 92 and 4735-4767). `toRenderedObject` is
also used by `stampAppLabel`'s local `describe` (`Deploy.hs:338`). `app/Nagare/Cli/Options.hs:154-157`
still calls `--json` "the kotei contract".

**The admin API.** MasterPlan 28 builds it (EP-197); nothing here does. The precedent is
`nagared` (`cli/nagarectl/nagared/Main.hs`), an HTTP executable that links the `nagarectl`
library, so code in `src/` is reachable from the API server and code in `app/` is not. The
store-only read boundary used by inventory documents and state handlers is EP-193 M1's
checked-head/hydration reader (`src/Nagare/Inventory/Recorded.hs`), which reads the head once and returns
whatever is open on it as facts. `loadTargetSnapshotReadOnly` (`Command.hs:892`) is for planning:
it calls `dieText` and refuses an open transaction, so no read document uses it. Full
`inventory status` builds its provider observers in `app/Nagare/Cli/Commands/Inventory/Status.hs`;
the API serves recorded facts only in v1, which is why `observationComplete` must stay honest.

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
- F107. The default GCS transport gets its token through `newGcloudSession`
  (`src/Nagare/Inventory/Store/GcloudAuth.hs`, around lines 38-49). Its runner keeps only stdout:
  every non-zero `gcloud` exit becomes "gcloud credential or ownership command failed or timed
  out", and the stderr that says why is discarded. `openTargetStoreReadOnly`
  (`src/Nagare/Inventory/Store/Target.hs`, around line 93) then reports that text as an invalid
  store. The fix keeps stderr, recognizes a missing or expired login in it, and carries that as
  its own reason through to a new `StoreError` constructor, `StoreAuthRequired`, rendered with a
  `gcloud auth login` instruction. (The `StoreIoError` sites in `Target.hs` at lines 147, 166 and
  183 are the local cache and client-identity files, not gcloud.)
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

**M1 — the contract package and the generated document.** Create `cli/nagare-contract` (library
plus executable `nagare-contract-openapi`), add it to the Cabal project, `nix/haskell-packages.nix`
and `nix/platform-package.nix`. In `Nagare.Contract.V1` write one record per document and item:

- operation documents: `TransactionOutcome`, `SavedReview`, `ImagePublicationResult`,
  `DeployPreview`;
- read documents: `InventoryStatusReport`, `PublicationList`, `VersionInfo`;
- item types used by both the CLI documents and the API: `ScopeState`, `Finding`, `Publication`.

Each type gets one `Options` value used by its `ToJSON`, `FromJSON` and `ToSchema`
(`genericDeclareNamedSchema (fromAesonOptions opts)`), so encoder and schema cannot disagree.
Enumerations (`outcome`, `failureClass`, `category`, `health`) are sum types whose schemas are
`enum`s. `scopeDocuments` in `DeployPreview` is opaque: give `Value` the `ToSchema` instance from
the standards (empty schema, `additionalProperties` allowed), in a shared schema module imported where dependent `ToSchema` instances are compiled; a
generator-only orphan cannot satisfy those library instances.
Field descriptions carry the meaning Kotei relies on: what `configDigest` covers, that `refused`
means no provider was touched, and that `observationComplete: false` means the findings are
partial. Every document except `VersionInfo` has a required `contractVersion` field, constant 1 in
V1, and a `document` field naming its kind. `VersionInfo` is the discovery document: it keeps
today's `version`, `platformVersion`, optional `revision` and optional `tools`, and gains
`contracts: [Int]`.

In `Nagare.Contract.Problem` write `ProblemDetails`, its shared `Options`, `ProblemJSON`, a
`ProblemSpec` per code and `problemCatalog`, exactly as the RFC 9457 standard shows, with the codes
from the Decision Log. In `Nagare.Contract.OpenApi` build a components-only `OpenApi` value that
declares every type above (`declareSchemaRef` into `components.schemas`), with title "Nagare
contract" and version `1`. `nagare-contract-openapi` writes it to `docs/api/openapi.json` with
`encodePretty'` (two-space indent, sorted keys) and a trailing newline. EP-197 later replaces this
generator with the API's `toOpenApi` and keeps these components.

In the `nagarectl` library create `src/Nagare/Contract/Project.hs` with pure functions from
internal values to these records, and route `version --json` through `VersionInfo`, so that
output's only change is the new `contracts` field.

Tests, in `cli/nagare-contract/test` for the package's own properties and in
`cli/nagarectl/test/Nagare/Test/Contract.hs` (registered in `test/Nagare/Test/Suite.hs`) for the
projections:

- the checked-in `docs/api/openapi.json` equals the encoded generated value (the test reads the
  file; it never writes it);
- a tasty-golden test per document writing a sample built through `Project`, from fixed internal
  values, to `docs/api/samples/<name>*.json`, pretty-printed with sorted keys and a trailing
  newline (`aeson-pretty`, added to the test suite; it is in the pinned set and already used by
  `cli/nagare-harness`);
- `validateToJSON` is empty for every sample value, and every sample file decodes with
  `FromJSON` back to the same value;
- the base `ProblemDetails` encodes with the keys `type`, `title`, `status`, `detail`, `code`,
  `retryable`; optional gateway extensions `error` and `login` round-trip without shadowing base
  members; the schema permits these members; every catalog code has one status and title.

M1 supplies type/codec samples for every shape and real version/scope/publication projection
goldens. The later owning milestones add outcome and deploy projection goldens through their
changed production code, covering every `outcome`, `failureClass`, and previews with/without hooks. Draft `docs/api/README.md` with each document's class.

**M2 — apply and resume.** Add `--contract VERSION` to `inventory apply` and
`inventory resume`; it accepts only `1` and otherwise refuses with the supported list. With it,
print one `TransactionOutcome`. Its fields are:

- `outcome`: `converged`, `paused`, `stopped`, `ambiguous`, `closed`, `refused` or `interrupted`
- `transaction` (nullable)
- `operation` (nullable)
- `failureClass`: `known-no-effect`, `partial-or-unknown` or null
- `barriers` (strings)
- `detail` (nullable text): the stop's reason for `stopped`, `ambiguous` and `interrupted`
- `problem` (nullable `ProblemDetails`): set exactly when `outcome` is `refused`

The exit codes are 0 converged, 2 refused, 3 paused, 4 stopped, 5 ambiguous, 6 closed and
7 interrupted. Code 1 stays for a crash the handler could not classify.

Refusals are captured in `app/Nagare/Cli/Runtime/Error.hs` and `src/Nagare/Inventory/Command.hs`.
A contract sink is set once, when `--contract` is parsed. While the sink is set, `dieT` and
`dieText` print the outcome document instead of the stderr line. The outcome is `refused` until
the sink is switched to the executing phase, then `interrupted` with the transaction ID. The switch
goes in `applyReviewed`'s path at the point where admission has succeeded and before the first
intent is written; find that point in `src/Nagare/Inventory/Execute/`. An unexpected exception
under the sink also yields `interrupted` once executing. Without the sink, `dieT` and `dieText`
behave exactly as now. The sink builds the `problem` from the catalog entry for the refusal's
source: `unsupported_contract_version` for the flag itself, `wrong_context` for the context check,
`review_changed` for a bundle that no longer verifies, `admission_refused` for admission errors
(`Command.hs:522-536`), `store_unavailable` and `reauthentication_required` for store errors,
and `unclassified` for any `dieT`/`dieText` this plan does not classify; the existing message is
the `detail`. Classify at the call sites,
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
--contract VERSION`, read-only, projecting from one `RecordedState` read through
`readRecordedState` (`src/Nagare/Inventory/Recorded.hs`, EP-193 M1; MasterPlan 28, 2026-10-14),
never through `loadTargetSnapshotReadOnly`, which exits the process and refuses an open
transaction. It prints a
`PublicationList`, `{publications:[{resourceId, scope, key, destination, manifestDigest,
archiveDigest, generation, usedBy:[scope]}]}`, sorted by scope. Without `--contract` it prints a
plain table. Register the new subcommand in `scripts/audit-managed-commands.py` as read-only.

Under `--contract 1`, a read command that refuses prints a `ProblemDetails` document on stdout
and exits 2, through the same coded sink as M2: `unknown_scope` for `--scope`,
`unsupported_contract_version`, `store_unavailable`, `reauthentication_required` and
`workspace_not_prepared`, and `unclassified` for the rest. Without `--contract`, the stderr message is the same text as the `detail` field.

F107: in `src/Nagare/Inventory/Store/GcloudAuth.hs`, make the runner keep stderr and return a
distinct reason when it shows a missing or expired login: gcloud's token-refresh failure ("There
was a problem refreshing your current auth tokens", "Reauthentication failed") or no credentialed
account. Capture the no-account text safely with an isolated, empty gcloud configuration, which
never touches the operator's login: `CLOUDSDK_CONFIG=$(mktemp -d) gcloud config config-helper
--format=json`. Never run `gcloud auth revoke` for this; it revokes the operator's real tokens. Put
both texts in test fixtures driven through `newGcloudSessionWith`, which already takes an injected
runner. Carry the reason to a new `StoreAuthRequired` constructor of `StoreError`
(`src/Nagare/Inventory/Store.hs:100`) at `openTargetStoreReadOnly`, rendered as "the gcloud login
is missing or expired; run `gcloud auth login` and retry", and map it to
`reauthentication_required`. `Discovery.hs:64` reports `StoreIoError` as unavailable; treat
`StoreAuthRequired` the same way there.

F118: add `WorkspaceNotPrepared` to `WorkspaceError` and return it from `validateExisting` when
`.nagare-workspace.json` does not exist, keeping `ExistingWorkspaceMismatch` for a manifest that
exists and differs. Render it as described in Context.

**M5 — cleanup and handoff.** Delete the dead pre-inventory contract (see Decision Log) and its
tests in `test/AppDeploySpec.hs`, and fix `app/Nagare/Cli/Options.hs:154-157`. Finish
`docs/api/README.md`. It lists the documents, their class (read or operation) and their
commands, the problem catalog, and the exit-code table. It states that the admin API serves
read documents only, with these schemas, and that a read document never needs operator
credentials to be meaningful (recorded and observed facts are separate fields, and partial
observation is flagged). It states the versioning rules: additive changes keep major 1 and add only optional fields. A new enum value is additive only when v1 already defines an unknown-value
decoding rule and both clients prove it; otherwise it is version 2. Other breaking changes are version 2, and nagarectl keeps
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

Regenerate the published document after changing a contract type, from the repository root, and
review the diff:

```bash
cabal run nagare-contract-openapi
git diff docs/api/openapi.json
```

The contract package's test fails until the regenerated file is committed.

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
- `docs/api/openapi.json` equals the generated document, and `validateToJSON` passes for every
  sample; each sample equals its projected document and round-trips through `FromJSON`.
- Each M2 constructor case prints the expected outcome and exits with the expected code. A
  refusal before admission (for example omitting `--yes`) prints
  `{"contractVersion":1,"document":"transaction-outcome","outcome":"refused",…,"problem":{"code":"unclassified",…}}`
  and exits 2.
  A failure injected after admission prints `interrupted` with a non-null `transaction` and
  exits 7.
- Without `--contract`, the existing suites pass unchanged except the F94 line. `inventory apply`
  still prints `converged tx-…` and exits 0 or 1, and an ambiguous stop prints
  `ambiguous tx-… at op-…: <reason>`.
- `app deploy --dry-run --contract 1` on `cluster/examples/multi-workload-app` (which has hooks)
  and on an example without hooks produces documents with identical top-level key sets.
- `inventory status --contract 1 --scope application:<name>` lists only that scope's findings,
  and an unknown scope prints a problem document with code `unknown_scope` and exits 2.
- F107: with a store whose gcloud call fails with either fixture text, `inventory status`
  refuses with code `reauthentication_required` and the `gcloud auth login` instruction.
- F118: `inventory status` against a context with no workspace directory refuses with code
  `workspace_not_prepared`; a workspace whose manifest differs still reports the mismatch.
- `docs/api/README.md` names each document's class, and every read document separates recorded
  from observed fields.

Kotei's side, not required here: it copies `docs/api/` at its pinned revision and validates its
fixtures and fake `nagarectl` against `#/components/schemas/<Name>` (`mori://shinzui/kotei/plans/84-deploy-to-nagare-through-its-reviewed-resource-inventory`, Milestone 2).


## Idempotence and Recovery

Every step is a code change under test; nothing touches a context or a cloud project. Rerunning
the tests is safe. `--accept` overwrites golden files, so review `git diff` after it. If a
landed change to a schema turns out to break the version 1 rules, revert that commit; Kotei pins
a revision, so it is not affected until it moves its pin.


## Interfaces and Dependencies

Libraries:

- `openapi-hs >=5.0 && <5.1`, new, in `nagare-contract` (and through it in `nagarectl`).
- `aeson-pretty`, in `nagare-contract-openapi` and the test suites.
- `tasty-golden`, already present.

New package `cli/nagare-contract`:

- `Nagare.Contract.V1`: the seven documents and the item types `ScopeState`, `Finding`,
  `Publication`, each with `ToJSON`, `FromJSON` and `ToSchema` from one `Options`;
  `contractVersions :: [Int]` (= `[1]`).
- `Nagare.Contract.Problem`: `ProblemDetails`, `ProblemJSON`, `ProblemSpec`, `problemCatalog`,
  and `problemFor :: ProblemSpec -> Text -> ProblemDetails`.
- `Nagare.Contract.OpenApi`: `contractOpenApi :: OpenApi` (components only), with the orphan
  `ToSchema Value` instance in the shared schema module imported by dependent instances.
- Executable `nagare-contract-openapi`, writing `docs/api/openapi.json`.

In the `nagarectl` library, `src/Nagare/Contract/Project.hs` exports the pure projections:

- `transactionOutcome :: TransactionResult -> TransactionOutcome`, with constructors for
  `refused` and `interrupted`;
- `savedReview`, `imagePublicationResult`,
  `deployPreview :: ScopeDeclaration -> [ScopeDeclaration] -> DeployPreview`,
  `inventoryStatusReport`, `publicationList`, `versionInfo`. The M1 API-facing version/scope/
  publication projections accept existing head/declaration values; M4 connects these to the
  shared reader and CLI. Do not defer publication semantics or its golden until M4.

Consumed from EP-193 M1: `RecordedState` and `readRecordedState`
(`src/Nagare/Inventory/Recorded.hs`), the source whose checked head/declarations M4 passes to the pure projections; it is not a
prerequisite of the M1 projection implementations.

Changed internal types: `StoppedAmbiguous` gains a reason (`Text`) (F94); `StoreError` gains
`StoreAuthRequired` (F107); `WorkspaceError` gains `WorkspaceNotPrepared` (F118).

Published artifacts: `docs/api/openapi.json`, `docs/api/samples/*.json` and `docs/api/README.md`,
under `mori://shinzui/nagare` (artifact-level URI pending).

Consumer: `mori://shinzui/kotei/plans/84-deploy-to-nagare-through-its-reviewed-resource-inventory`.
Differences from what Kotei asked for, to relay at handoff:

- The selector is `--contract 1` rather than `--json`.
- Scopes are `kind:name` text.
- The finding "class" is `category`.
- `closed` and `interrupted` are added to the outcomes.
- The publication listing has `generation` and `usedBy` instead of `acceptedAt`.
- The dry-run envelope adds `scopeDocuments`.
- The schemas are published as components of one OpenAPI 3.1 document, `docs/api/openapi.json`,
  generated from the types, instead of per-document hand-written files under
  `cli/nagarectl/contract/v1/`. OpenAPI 3.1 schemas are JSON Schema 2020-12, so Kotei can validate
  with `openapi-hs` (`validateJSON`) or any standard validator.
- (2026-10-14) Every refusal is an RFC 9457 problem document: a `refused` outcome carries it as
  `problem`, and read commands print it when they refuse. `detail` of an `ambiguous` outcome now always holds the
  reason.
- (2026-10-14) The contract is also the future read-only admin API's: the read documents will be
  served over HTTP with the same schemas. Kotei may read status and publications from it later;
  deploys stay on the CLI.
