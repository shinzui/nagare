---
id: 263
slug: print-versioned-preview-and-saved-review-documents-from-site-deploy
title: "Print versioned preview and saved-review documents from site deploy"
kind: exec-plan
created_at: 2026-11-13T00:24:30Z
intention: "intention_01m794n4v3edjsy68csserq06b"
provenance:
  created_by:
    model: "claude-fable-5-2"
    harness: "claude-code"
    at: 2026-11-13T00:24:30Z
---

# Print versioned preview and saved-review documents from site deploy

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log and
Outcomes & Retrospective current. Record implementation friction in the friction log as it
occurs (`agents/skills/exec-plan/FRICTION.md`).


## Purpose / Big Picture

A CI deployer such as Kotei deploys in three steps: it asks Nagare what a deployment would
change, saves that change as a review, and applies the saved review. Between the steps it
compares what Nagare said, so that the thing it applies is the thing it inspected. For an
application Nagare answers the first two steps with versioned JSON documents under
`--contract 1`. For a site it prints an internal scope document on the first step and three
human lines on the second, so a client must parse human output or read Nagare's private review
files to know what it is about to apply.

After this change `nagarectl site deploy` accepts `--contract 1`:

```bash
nagarectl --context CONTEXT site deploy --rendered rendered.json --skip-build \
  --tag TAG --image-resource RESOURCE --dry-run --contract 1

nagarectl --context CONTEXT site deploy --rendered rendered.json --skip-build \
  --tag TAG --image-resource RESOURCE --save-plan REVIEW_DIR --contract 1

nagarectl --context CONTEXT inventory apply REVIEW_DIR --yes --contract 1
```

The first prints one `deploy-preview` document naming the site's scope, its configuration
digest and the reviewed command inputs. The second prints one `saved-review` document with the
review's digest, its absolute directory and the scopes it changes. The third already exists and
prints a `transaction-outcome`. In each case stdout holds exactly that one document, progress
goes to stderr, and a refusal is a `transaction-outcome` whose `outcome` is `refused`, with exit
status 2. Without `--contract` the command behaves as it does today.

This is IR-45
([docs/improvement-requests/expose-versioned-json-for-site-deployment-previews-and-saved-reviews.md](../improvement-requests/expose-versioned-json-for-site-deployment-previews-and-saved-reviews.md)),
raised for
`mori://shinzui/kotei/plans/148-deploy-rendered-apps-and-static-sites-through-a-delegated-nagare-deployer`.


## Progress

- [ ] M1: a site's reviewed scope carries its configuration digest and reviewed inputs, and the
  library produces the `deploy-preview` and `saved-review` documents for it. Accepted when the
  new `nagarectl-test` cases pass: the preview of a static-site scope validates against the
  schema and names the scope, digest and inputs; the saved review of the same candidate applies
  through the existing apply path and the accepted scope agrees with both documents; a planning
  refusal under the contract sink is one `refused` outcome with nothing published; and an
  accepted site scope without a digest is replaced by one with it without any member operation.
- [ ] M2: `site deploy` accepts `--contract`. Accepted when the built executable prints one
  `deploy-preview` for `--dry-run --contract 1` and one `saved-review` for
  `--save-plan DIR --contract 1`, refuses `--contract 2` and a contract run with neither flag
  with a `refused` outcome and exit 2, prints today's output without `--contract`, and
  `site preview deploy` does not accept the flag.
- [ ] M3: the public contract describes the site producers. Accepted when
  `docs/api/openapi.json` and `docs/api/samples/` are regenerated with a site preview sample
  and pass their checks, `docs/api/README.md`, `docs/user/static-hosting.md` and
  `docs/user/reference.md` name the two site commands, and a test decodes both documents with
  the public types and applies the review using only their fields.
- [ ] M4: confirmed on a disposable local context under a bounded deployer. Accepted when the
  three commands above succeed from a rendered document whose config program and build command
  would fail if run, the transaction history shows the supplied source repository, commit and
  run, a site outside the delegation is refused with nothing published, and the transcript is
  linked from IR-45.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: A site's reviewed scope is stamped with a configuration digest and with the
  reviewed inputs `tag`, `imageResource` and, when `--base-domain` was given, `baseDomain`.
  Rationale: IR-45 AC-1 needs a configuration digest in the preview and AC-2 needs the accepted
  state to agree with it. Site scopes carry neither today, so a digest computed only for the
  preview could not be checked against what was accepted. The digest has the meaning the
  contract already publishes for applications: the SHA-256 of the canonical JSON of the typed
  configuration only. The inputs are the set a standalone worker already records
  (`recordReviewedStandaloneOverrides` in
  `cli/nagarectl/src/Nagare/Inventory/Application/Policy.hs`). CDN binding inputs are not
  recorded; no criterion needs them and adding a key later is additive.
  Date: 2026-11-12
- Decision: The digest covers the configuration as decoded, before the image name is qualified
  with the context's registry.
  Rationale: This is what the application path digests, and it makes one rendered document
  yield one digest in every context. The registry prefix is a property of the context.
  Date: 2026-11-12
- Decision: The site's scope is reported in the existing `application` member of
  `DeployPreview`, with `hooks` empty. No field or document is added.
  Rationale: IR-45 asks to reuse the two types. Renaming the member is a version 2 change under
  `docs/api/README.md`'s rules, and a second member holding the same value would give clients
  two places to read. The schema description and the README say that `application` is the
  primary scope of the deployment, which for a site is `standalone:site-NAME`.
  Date: 2026-11-12
- Decision: The stamp is applied by every command that reaches the production site deploy
  driver: `site deploy` for static and server sites, and `site publish`. `site rollback` and
  `site preview deploy` are unchanged, and only `site deploy` gains `--contract`.
  Rationale: The driver is shared, so stamping there keeps a site's accepted scope the same
  whether the operator published it or a deployer deployed it. IR-45 excludes preview
  environments and rollback. A rollback review therefore replaces the scope with an unstamped
  one, which is accurate: the scope then records no deploy inputs instead of stale ones.
  Date: 2026-11-12
- Decision: Under `--contract`, `site deploy` requires `--dry-run` or `--save-plan`.
  Rationale: `app deploy` refuses the same way ("a live deploy has no contract document"), and
  IR-45 AC-4 asks for the application's conventions.
  Date: 2026-11-12
- Decision: Two visible side effects of the stamp are accepted. The first deploy of an existing
  site after this change records a new scope revision even when no member changes. And
  `inventory publications` lists the site under its image's `usedBy`, because that list is
  built from the `imageResource` input (`acceptedPublications` in
  `cli/nagarectl/src/Nagare/Contract/Project.hs`).
  Rationale: Both follow from recording the inputs and both make recorded state more complete.
  M1 proves the first needs no member operation.
  Date: 2026-11-12


## Outcomes & Retrospective

(To be filled at completion.)


## Context and Orientation

Paths are repository-relative. Terms used below:

A *site* is a `StaticSite` (files served by Nginx) or a `ServerSite` (a Node server), declared
by a config program and deployed with `nagarectl site deploy`. A *rendered document* is the
JSON file `nagarectl site render` writes: it carries the config program's exact output, so a
deployer can pass it with `--rendered PATH` and never run the program
([EP-249](249-deploy-apps-and-static-sites-from-a-rendered-configuration-without-running-the-repository-s-program.md)).

A *scope* is a named set of resources that is reviewed and accepted as a unit. A site's scope is
`standalone:site-NAME`. Its declaration type is `ScopeDeclaration` in
`cli/nagare-dsl/src/Nagare/Resource/Inventory.hs`, which holds the scope's resources and two
optional annotations: a *configuration digest* (`scopeConfigDigest`, set with
`withScopeConfigDigest`) and *overrides* (`scopeOverrides`, set with `withScopeOverrides`), a
map of the public command inputs that shaped the scope, such as the tag. Both are part of the
scope's canonical JSON (`cli/nagare-dsl/src/Nagare/Resource/Wire.hs`), so they are part of what
is reviewed and accepted.

A *reviewed deploy* compiles the configuration into a scope, composes it with the accepted
inventory into a *candidate*, and either prints it (`--dry-run`), saves a *review* to a
directory (`--save-plan DIR`) or applies it. `nagarectl inventory apply DIR` applies a saved
review; that is the only step that changes a cluster.

*Contract 1* is Nagare's public document contract, described in `docs/api/README.md`. Its types
are in `cli/nagare-contract/src/Nagare/Contract/V1.hs`, its JSON Schema is the generated
`docs/api/openapi.json`, and one golden sample per shape is in `docs/api/samples/`. The
*contract sink* (`cli/nagarectl/src/Nagare/Contract/Sink.hs`) is the process-wide switch
`--contract 1` sets. `withContract` sets it, refuses any other version with the problem code
`unsupported_contract_version`, and reserves stdout for the document. While it is set, `dieT`
(`cli/nagarectl/app/Nagare/Cli/Runtime/Error.hs`) prints a `refused` `transaction-outcome` and
exits 2 instead of printing a line to stderr.

A *delegated deployer* is a CI identity limited to named namespaces, hostnames and one image
repository. A context run with `NAGARE_DEPLOYER=NAME` plans through
`cli/nagarectl/src/Nagare/Inventory/DelegatedPlanning.hs`, which refuses a scope outside the
delegation and adds the override `delegation.deployer`. The flags `--source-repository`,
`--source` and `--source-run` (`withReviewSource` in
`cli/nagarectl/app/Nagare/Cli/Parser/Delegation.hs`) are recorded with the transaction and read
back with `nagarectl inventory history --contract 1`.

A *local context* is a k3d cluster with loopback substitutes for every cloud service
([docs/user/local-development.md](../user/local-development.md)); the GCP guardrail steps aside
there by design.

What the code does today, checked at commit `11c09286`:

- `siteDeployOptsParser` in `cli/nagarectl/app/Nagare/Cli/Parser/Site.hs` has no `--contract`
  option, and `SiteDeployOpts` in `cli/nagarectl/app/Nagare/Cli/Options/Site.hs` has no field
  for it. The same parser serves `site deploy` and `site preview deploy`, and
  `runSitePublish` in `cli/nagarectl/app/Nagare/Cli/Commands/SitePublish.hs` builds the record
  by hand.
- `dispatch` in `cli/nagarectl/app/Nagare/Cli/Dispatch.hs` runs `SiteDeploy` without
  `withContract`; `AppDeploy` on the line below shows the wrapped form.
- `runReviewedSiteDeployPlan` in `cli/nagarectl/app/Nagare/Cli/Commands/Site.hs` is the one
  driver for production site deploys. `runStaticSiteDeployPlan` and `runServerSiteDeployPlan`
  call it, and `site publish` reaches it through `deployLoadedStaticSite`. On `--dry-run` it
  prints `ResourceWire.encodeCanonicalScope scope`. On `--save-plan` it calls
  `Inventory.planInventoryCandidateWith`.
- `planInventoryCandidateWith` ends in `writePlannedReview` in
  `cli/nagarectl/src/Nagare/Inventory/Command.hs`, which already prints a `saved-review`
  document when the contract sink is set. So the save-plan half of the request needs the sink
  set and nothing else.
- The site compilers in `cli/nagarectl/src/Nagare/Inventory/Site.hs`
  (`compileStaticSiteScopeWith`, `compileServerSiteScopeWith`, both ending in
  `compileSiteRenderedScope`) build the scope with `mkScopeDeclaration` and set no digest and no
  overrides. The application compiler does both
  (`cli/nagarectl/src/Nagare/Inventory/Application/Compile.hs`, around
  `withScopeConfigDigest configDigest`), using `configDigestOf` from
  `cli/nagarectl/src/Nagare/Inventory/Application/Policy.hs` over `encodeApplication`.
  `encodeStaticSite` and `encodeServerSite` in `cli/nagare-dsl/src/Nagare/Dsl/Config.hs` are the
  matching encoders for sites.
- `deployPreview` in `cli/nagarectl/src/Nagare/Contract/Project.hs` builds a `DeployPreview`
  from a scope and a list of hook scopes. It reads only `scopeId`, `scopeConfigDigest` and
  `scopeOverrides`, so it works for a site scope once that scope carries them.
- The modules under `cli/nagarectl/app` belong to the executable. The test suite
  `nagarectl-test` and `just gate-fast` do not compile them. Logic that needs a test therefore
  goes in the library under `cli/nagarectl/src`, and the command wiring is checked with the
  built executable.

IR-45's findings were checked against this code and hold, with two refinements that shape the
plan. The saved-review document already exists behind the sink, so that half is wiring. The
preview half needs more than a flag, because a site scope has no configuration digest to
report.

Relevant ADRs:
[ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md) is the
typed inventory a reviewed deploy compiles into; the digest and overrides are annotations on its
scope declaration.
[ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md) requires
that a code path runs against in-memory provider interpreters before any native run, which is
why M1 comes before M4 and M4 only confirms.
[ADR 32](../adr/0032-static-publication-is-a-local-package-then-two-reviewed-stages.md) fixes
static publication as a local package followed by two reviewed stages; this plan changes
neither stage, only what the second one prints.
[ADR 35](../adr/0035-a-delegated-deployer-is-trusted-and-repository-content-is-not.md) is why a
deployer uses `--rendered` and never runs the repository's program. No ADR is changed or added
by this plan.


## Plan of Work

### M1: the stamp and the documents, in the library

Add one function to `cli/nagarectl/src/Nagare/Inventory/Site.hs` that takes the encoded site
configuration, the reviewed inputs and a compiled site scope, and returns the scope with its
digest and overrides set. Compute the digest with `configDigestOf`, so it is the same
computation as the application's. Refuse inputs outside `tag`, `imageResource` and `baseDomain`,
as `recordReviewedStandaloneOverrides` does for a worker. Keep the compilers themselves
unchanged, so `site rollback`, `site preview deploy` and the existing compile tests are
untouched.

Add tests to `cli/nagarectl/test/Nagare/Test/ContractCommands.hs`, whose fixture already runs
plan, save and apply against an in-memory Kubernetes interpreter. Use a static-site scope
compiled as in `cli/nagarectl/test/Nagare/Test/SiteInventory/Static.hs` and stamped with the
new function. The cases are the ones listed under M1 in Progress. For the agreement case, save
the review with `planInventoryCandidateWith` under the collecting sink, decode the
`SavedReview`, apply its `review.directory` with `applyInventoryWithFactory`, then load the
accepted snapshot and compare its site scope's digest and overrides with `deployPreview` of the
same scope. For the refusal case, plan a site scope outside a deployer's delegation, reusing
the fixture in `cli/nagarectl/test/Nagare/Test/Delegation.hs`, and assert one `refused`
document and an unchanged store head. For the digest-only case, accept the unstamped scope
first, then plan the stamped one and assert the review lists the scope and has no operations.

If the digest-only review cannot be planned or applied, stop and record it under Surprises &
Discoveries before continuing; the stamp decision depends on it.

### M2: the flag and the command

Add `contract :: !(Maybe Int)` to `SiteDeployOpts`. Make `siteDeployOptsParser` take the
contract parser as an argument: `siteDeployCmd` passes `contractOpt` from
`cli/nagarectl/app/Nagare/Cli/Parser/Common.hs`, and `previewDeployCmd` passes `pure Nothing`.
Set the field to `Nothing` where `runSitePublish` builds the record. In `dispatch`, wrap
`SiteDeploy` in `withContract`.

In `runSiteDeploy`, refuse a contract run that has neither `--dry-run` nor `--save-plan`,
before the context is resolved, with the application's wording. In
`runReviewedSiteDeployPlan`, stamp the compiled scope with M1's function before composing the
candidate, and on `--dry-run` print `deployPreview scope []` with `emitDocument` when the
contract was requested and the canonical scope otherwise. The stamp needs the configuration as
decoded, which the driver's callers hold before they qualify the image: pass the encoded bytes
down from `runSiteDeploy`, and from `runSitePublish` (its `site0`) through
`deployLoadedStaticSite`. The save-plan branch needs no change.

Build the executable and check it by hand, as the fast gate does not compile these modules. The
checks that need no context are: `site deploy --help` lists `--contract`,
`site preview deploy --help` does not, `--contract 2` prints a `refused` outcome with code
`unsupported_contract_version` and exits 2, and `--contract 1` with neither flag prints a
`refused` outcome and exits 2. The preview and saved-review output are checked in M4.

### M3: the public contract and the guides

In `cli/nagare-contract/src/Nagare/Contract/V1.hs`, extend the `DeployPreview` schema
description to say that `application` is the deployment's primary scope and is a site's scope
for `site deploy`, and the `PreviewScope` description to name a site's inputs. Regenerate
`docs/api/openapi.json`. Add a site preview sample (`docs/api/samples/deploy-preview-site.json`,
scope `standalone:site-docs`) to the sample list in
`cli/nagarectl/test/Nagare/Test/Contract.hs`, built with `deployPreview` from a stamped scope
so the sample comes from the real projection.

In `docs/api/README.md`, add `nagarectl site deploy --dry-run --contract 1` and
`nagarectl site deploy --save-plan DIR --contract 1` to the producers of `deploy-preview` and
`saved-review`, and say what `application`, `configDigest` and `overrides` mean for a site. In
`docs/user/static-hosting.md`, extend "Deploying a rendered site" with the three commands and
what a client compares between them. Update the `site deploy` rows of `docs/user/reference.md`.

Add the client test IR-45 AC-5 asks for to `ContractCommands.hs`: decode the collected preview
and saved review with the `FromJSON` instances of `Nagare.Contract.V1` only, and apply the
directory the saved review names. It may share M1's agreement case if that case reads nothing
but the decoded documents.

### M4: confirm on a local context

On a disposable local context, repeat the deployer arrangement of
[the MasterPlan 33 confirmation](../audits/mp33-local-confirmation-2026-11-11.md): its scripts
and fixtures are in `docs/audits/mp33-local-confirmation-2026-11-11/`, and its phase 5 deploys a
rendered static site as the deployer `ci`. Render the fixture site, then replace the config
program and the build command in the deployer's checkout with ones that fail when run. As the
deployer, run the three commands from Purpose with `--source-repository`, `--source` and
`--source-run`. Validate each stdout against `docs/api/openapi.json`, compare the preview's
scope with the saved review's `scopes`, and compare the accepted scope's digest after the apply
with the preview's. Read the source attribution back with `inventory history --contract 1`.
Then run the save-plan command for the confirmation's out-of-delegation site and observe a
`refused` outcome, exit 2 and no new review in the store. Run one `site deploy --dry-run`
without `--contract` and confirm it prints the canonical scope as before.

Write the transcript to `docs/audits/` as that confirmation did, link it from IR-45, and set
IR-45's status as its profile (`docs/improvement-requests/profile.dhall`) and IR-44's closing
commit `85b7b492` show. Kotei's adoption is not part of acceptance.


## Concrete Steps

All from the repository root.

```bash
cabal test nagarectl-test --project-dir=cli/nagarectl --test-options='-p /contract/' --test-show-details=direct
cabal build exe:nagarectl --project-dir=cli/nagarectl
cabal run --project-dir=cli/nagarectl nagare-api-openapi
cabal test nagarectl-test --project-dir=cli/nagarectl --test-options='-p /Contract/ --accept'
git diff docs/api
just haskell-style-check
just gate-fast
```

The checks of M2 that need no context, with the built executable:

```bash
nagarectl site deploy --rendered rendered.json --skip-build --tag t1 \
  --image-resource publication:x/y/oci-image --dry-run --contract 2; echo "exit $?"
```

```text
{"barriers":[],"contractVersion":1,"detail":null,"document":"transaction-outcome","failureClass":null,"operation":null,"outcome":"refused","problem":{"code":"unsupported_contract_version",…},"transaction":null}
exit 2
```

A successful preview in M4 has this shape (values differ):

```json
{
  "application": {
    "configDigest": "352033854558033a34dffbf15b1329eeee3f87ee91ca031c2a1800c38bd648a2",
    "overrides": {
      "imageResource": "publication:app-image-docs-d1/docs-d1/oci-image",
      "tag": "d1"
    },
    "scope": "standalone:site-docs"
  },
  "contractVersion": 1,
  "document": "deploy-preview",
  "hooks": [],
  "scopeDocuments": [{"scope": "standalone:site-docs", "…": "…"}]
}
```

Under a deployer the accepted scope's overrides also hold `delegation.deployer`, which planning
adds after the preview; compare the other keys.

Per Haskell commit run `just haskell-style-check` then `just gate-fast`; land with
`just land HEAD` (rules in `CLAUDE.md`). Commits follow Conventional Commits and carry the plan
trailer:

```text
ExecPlan: docs/plans/263-print-versioned-preview-and-saved-review-documents-from-site-deploy.md
```


## Validation and Acceptance

Each milestone's acceptance is its Progress entry. They map to IR-45 as follows. AC-1 (the
preview) is M1's preview case and M4's first command. AC-2 (the saved review and its apply) is
M1's agreement case and M4's second and third commands. AC-3 (no program, no build, delegation
and attribution kept) is M4's failing program and build command, its history read and its
out-of-delegation refusal, with M1's refusal case as the interpreter proof. AC-4 (conventions)
is M1's refusal case, M2's executable checks and M4's run without `--contract`. AC-5 (schemas,
samples, guides, client) is M3.

IR-45 AC-4 names parser tests. The parser is in the executable, which no test suite compiles,
so M2 checks it with the built binary instead; this is the same limit EP-261 met.

The early check of the one uncertain point is M1's digest-only case: it shows that adding the
stamp to an already accepted site is a reviewable change with no member operation, before the
command or any cluster is involved.


## Idempotence and Recovery

Every code step is additive and can be repeated. Regenerating `docs/api/openapi.json` and
accepting golden samples is repeatable; review `git diff docs/api` each time and expect only
the description text and the new sample. `--dry-run` and `--save-plan` change no provider, and
a saved review that is not applied can be deleted. M4 runs on a disposable local context; tear
it down and repeat after a fix. If a guard, check or script refuses, stop and report to the
operator. Nothing in this plan touches a cloud context.


## Interfaces and Dependencies

New command surface: `--contract VERSION` on `nagarectl site deploy`, valid with `--dry-run` or
`--save-plan`. No contract type, field or document is added. The meaning of two existing
members widens and is documented: `DeployPreview.application` is the site's scope for a site,
and `PreviewScope.overrides` holds `tag`, `imageResource` and optionally `baseDomain` for a
site. Recorded state changes in one way: an accepted site scope deployed by `site deploy` or
`site publish` carries `configDigest` and `overrides`.

New library function, in `Nagare.Inventory.Site` (`cli/nagarectl/src/Nagare/Inventory/Site.hs`):

```haskell
-- | Record a site's configuration digest and reviewed inputs on its compiled scope.
recordReviewedSiteInputs ::
  LBS.ByteString ->
  Map Text Text ->
  ScopeDeclaration ->
  Either (NonEmpty InventoryError) ScopeDeclaration
```

It depends on `configDigestOf` (`Nagare.Inventory.Application.Policy`), `withScopeConfigDigest`
and `withScopeOverrides` (`Nagare.Resource.Inventory`), `encodeStaticSite` and
`encodeServerSite` (`Nagare.Dsl.Config`), `deployPreview` (`Nagare.Contract.Project`), and
`withContract`, `emitDocument` (`Nagare.Contract.Sink`).

No dependency on another plan. Consuming the documents in Kotei's site adapter belongs to
`mori://shinzui/kotei/plans/148-deploy-rendered-apps-and-static-sites-through-a-delegated-nagare-deployer`.
