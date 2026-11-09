---
id: 247
slug: review-a-bounded-namespace-delegation-for-a-named-deployer-and-record-who-applied-each-change
title: "Review a bounded namespace delegation for a named deployer and record who applied each change"
kind: exec-plan
created_at: 2026-11-07T16:50:58Z
master_plan: "docs/masterplans/33-delegate-a-bounded-part-of-a-context-to-a-ci-deployer-so-engineers-deploy-by-pushing.md"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-11-07T16:50:58Z
  revisions:
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-07T18:55:03Z
      mode: "update"
      note: "Named operator actor ({kind, name}) for future multi-operator compatibility"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-11-09T04:04:19Z
      mode: "update"
      note: "Bound generated system routes and align rendered-worker permission; repair MP-31 link and cite accepted trust ADR."
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-11-09T03:56:32Z
      verdict: "changes-requested"
      note: "Protected DomainMappings require an explicit nagare-system bounds exception; align standalone worker permission with rendered inputs; repair MP-31 link."
---

# Review a bounded namespace delegation for a named deployer and record who applied each change

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and
Outcomes & Retrospective current.


## Purpose / Big Picture

Today one operator deploys everything on a Nagare context, because only the operator's reviews can create a namespace,
publish an image and deploy an app or site, and nothing records who applied a change. After this plan an operator can
review one **delegation**: a named deployer (a CI/CD program the operator runs, such as Kotei) may admit apps, workers,
scheduled tasks and static or server sites into named namespaces, under hostnames, a quota and an image repository the
operator chose, and every site it creates is protected. A deployer context then plans and applies inside those bounds
without a per-site operator review, a review that reaches outside them is refused before anything changes, and a
revoked delegation refuses every later deployer review. Every accepted review records its actor and, when given, the
repository, commit and CI run it came from, and `nagarectl inventory history` shows them.

This is the first child of
[MasterPlan 33](../masterplans/33-delegate-a-bounded-part-of-a-context-to-a-ci-deployer-so-engineers-deploy-by-pushing.md)
and the source of the delegation record and the actor that EP-248, EP-249 and EP-250 read. It delivers the features
`bounded-namespace-delegation` and `deployer-attribution-in-the-journal` of
[UC-4](../use-cases/004-engineers-deploy-sites-by-pushing-through-a-delegated-deployer.md). It is generic: no installation,
project or domain is named, and every deliverable is proved on a local context.


## Progress

Each deliverable passes on the evidence it names. Interpreter and fake-adapter evidence comes first; the local-context
run only confirms ([ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md)).

- [ ] D1, the delegation scope: `nagarectl delegation create NAME --namespace NS... --host-suffix LABEL... --kinds KIND...
  --image-repository PATH --team TEAM [--build-namespace NS] [--quota-cpu C --quota-memory M --quota-pods N]
  --save-plan DIR` saves a review of a new `platform:delegation-NAME` scope that declares each delegated Namespace (with
  `nagare.dev/app-namespace=true` and `nagare.dev/delegation=NAME`), one ResourceQuota and one LimitRange per namespace,
  the optional build namespace (without the app-namespace label) and its quota, and the delegation record ConfigMap
  `nagare-delegation-NAME` in `nagare-system`. All members are `Retain`. Applying it with `inventory apply DIR --yes`
  converges on a local context. Evidence: compiler unit tests over every flag, a refusal for a namespace that already
  belongs to the foundation or another delegation, for `nagare-system`, `kube-*` and `personal`, and a local-context
  apply whose `kubectl get ns -l nagare.dev/delegation=NAME` lists exactly the declared namespaces.
- [ ] D2, accepted namespaces outside the foundation: app, worker, task, site and storage commands accept a namespace
  owned by an accepted, unrevoked delegation scope exactly as they accept a foundation namespace today, and still refuse
  any other namespace. Evidence: the existing `acceptedFoundationNamespace` callers pass with a delegation fixture, and a
  test that a namespace present in the cluster but absent from any accepted scope is refused.
- [ ] D3, the actor: a context whose resolved profile sets `NAGARE_DEPLOYER=NAME` is a deployer context. In it every
  review is prepared with the actor `deployer:NAME`; without it, with the actor `operator`, named `operator:NAME` when
  the context sets `NAGARE_OPERATOR=NAME`. A context that sets both is refused when the profile resolves. Commands
  outside the deployer's set
  (anything but `app image-plan`, `app check|deploy|delete`, `worker deploy`, `task run|delete`, `site deploy|rollback|
  preview …`, `inventory apply|resume|status|publications|history`, `delegation show` and `version`) refuse before reading
  the store, naming the command. Evidence: a parser-level table test over every top-level command in a deployer
  context.
- [ ] D4, the bounds at planning: in a deployer context, preparing a review refuses, before any store write, a proposal
  whose changed scopes (a) are not `application`, `standalone` or `publication` scopes, (b) place any member in a
  namespace outside the delegation except the generated protected-route members specified below, (c) declare a hostname that is neither the default name of a delegated namespace nor
  one label under the base domain ending in an allowed suffix, (d) declare a host without `access = requireLogin`, (e)
  contain a member kind the delegation does not allow (managed databases, app databases, brokers, volumes, CDN resources,
  supplied TLS, public routes and namespace requests are never allowed), (f) publish an image outside the delegation's
  image repository, or (g) touch a scope another actor created. Each refusal names the delegation, the bound and the
  member. Evidence: a fake-store table test with one passing proposal and one proposal per bound, run through
  `prepareReview`'s caller, with no store object written for a refused one. Include a protected route in `nagare-system`, a foreign hostname,
  an out-of-bound hostname, a route targeting another Service, and an unrelated system-object write.
- [ ] D5, the bounds at admission and revocation: `admit` repeats D4's check against the delegation as recorded in the
  head it admits on, so a review saved before a revocation, or against an older delegation, is refused at apply with
  `delegation-revoked` or `delegation-bounds`. `nagarectl delegation revoke NAME --save-plan DIR` reviews setting the
  record's state to `revoked`; it keeps the namespaces and everything deployed in them. Evidence: an admission test that
  saves a deployer review, applies a revocation, and proves the saved review is refused with no journal event; a test
  that an operator review of a delegated namespace is still admitted after revocation.
- [ ] D6, attribution: `ReviewDocument` gains `actor` and an optional `source` with `repository`, `revision` and `run`,
  filled from the actor and from `--source-repository URL`, `--source REF` (which already exists on `app deploy`) and
  `--source-run URL`. On the wire the actor is `{"kind": "operator" | "deployer", "name": NAME | null}`; `name` is
  required for a deployer and optional for an operator, and readers from this release on accept both forms, so naming
  operators later needs no transition. The fields are part of the review digest, so the transaction id (`tx-<review digest>`, see
  `transactionFor` in `cli/nagarectl/src/Nagare/Inventory/Execute/Types.hs`) binds them. `nagarectl inventory history
  [--limit N] [--contract 1]` lists transactions newest first with their final state, scopes, actor and source, reading
  each transaction's published review from the store's `reviews/` objects. Evidence: a golden `transaction-history`
  sample under `docs/api/samples/`, a fake-store test where a deployer transaction, an unnamed operator transaction and
  a named operator transaction are listed with the right actors, and a decoder test that refuses a deployer actor with
  no name.
- [ ] D7, the read contract: `nagarectl delegation show NAME --contract 1` prints a `delegation` document (name, state,
  namespaces, host suffixes, kinds, image repository, team, build namespace, quotas, accepted revision). It and
  `transaction-history` are added to `docs/api/README.md`, `cli/nagare-contract` and the regenerated
  `docs/api/openapi.json`. Evidence: `nagare-api-server-test` and the `/Contract/` goldens pass.
- [ ] D8, the wire transition: the review document and the delegation record are new or changed wire, so this lands as
  a reviewed release transition under the EP-172 rules. An older CLI refuses a store holding a review with `actor` with
  a message naming the newer release, never by misreading it. Evidence: a transition fixture test like the existing
  ones under `cli/nagarectl/test/fixtures/`, and a check that EP-231's state was read and the version number chosen
  accordingly (Decision Log).
- [ ] D9, the local confirmation: on a local context the operator applies a delegation; a deployer context (made by hand
  for this plan; EP-248 makes it from a bundle) publishes a fixture image and deploys a fixture protected static site
  into the delegated namespace; a second proposal with a hostname outside the suffix is refused; `inventory history`
  shows `deployer:NAME` and the source; after `delegation revoke`, the next deployer review is refused. Evidence: an audit
  file under `docs/audits/` with the transcript.
- [ ] D10, docs and decision: update the accepted trust-model ADR `docs/adr/0035-a-delegated-deployer-is-trusted-and-repository-content-is-not.md`
  with implementation evidence for the trust model of MasterPlan 33 and its limit for several operators (the actor is asserted, and enforcing
  approval against another holder of the store needs a server-side check or signed reviews); ADR 22 is amended with delegation-owned namespaces; `docs/user/` gains a
  "Delegating deployments" guide and reference rows. Evidence: the linked pages.
- [ ] D11, a retryable stale-review refusal: admission refusals caused only by another change landing first
  (`stale-head`, `stale-base` and the head's conditional write failing, in
  `cli/nagarectl/src/Nagare/Inventory/Execute/Admission.hs`) map to a new contract problem `review_stale` (409,
  `retryable: true`) in `cli/nagare-contract/src/Nagare/Contract/Problem.hs`, instead of `admission_refused`. Every other
  admission refusal, including D5's delegation refusals, keeps `admission_refused`. A new problem code is additive under
  `docs/api/README.md`'s rules. Kotei's runner (`mori://shinzui/kotei/plans/138-deploy-rendered-apps-and-static-sites-through-a-delegated-nagare-deployer`)
  re-plans only on this code. Evidence: a problem-catalog test per refusal kind, the README table, and the regenerated
  `docs/api/openapi.json`.


## Surprises & Discoveries

- 2026-11-07, while writing this plan. The name `Delegation` is taken:
  `cli/nagare-dsl/src/Nagare/Resource/Policy.hs` defines `Delegation {controller, fields, operations}` for field
  ownership handed to a controller, and `ManagedResource` has a `delegations` field. The new type is therefore
  `DeployerDelegation` and its module `Nagare.Inventory.DeployerDelegation`; user-facing text still says "delegation".
- 2026-11-07, same reading. The MasterPlan puts `actor` and `source` on `JournalEvent` as well as `ReviewDocument`. The
  journal does not need them: every event names its transaction, the transaction id is `tx-` plus the review digest,
  and the review is published under `reviews/<digest>` (`reviewKey` in `cli/nagarectl/src/Nagare/Inventory/Store.hs`).
  Putting them on the review binds them to every event without changing `JournalEvent`, whose decoder refuses unknown
  fields (`cli/nagarectl/src/Nagare/Inventory/Journal.hs`). This plan does that (Decision Log) and reported it to the
  MasterPlan. D6 must first confirm that published reviews are never collected; if any path prunes `reviews/`, the
  fields move to a transaction-start journal event instead.
- 2026-11-07, same reading. A protected site's deploy already rewrites a resource outside its namespace: the composer
  regenerates the `nagare-access-backends` ConfigMap in `nagare-system` from every `RegisterBackend` contribution
  (`backendMaps` in `cli/nagare-dsl/src/Nagare/Resource/Inventory.hs`). D4 permits the contribution-generated backend map, preserving unrelated entries. It also permits generated
  DomainMappings in `nagare-system` only for owned, in-bound hostnames targeting the accepted `nagare-access`
  enforcer; arbitrary targets, foreign routes and other system objects are refused. Protected-site deployment does
  not change Shomei settings. EP-248 owns the matching RBAC and the credential-backed route proof.


## Decision Log

- Decision: Permit only compiler-generated protected DomainMappings in nagare-system, alongside the composed backend map, as explicit namespace exceptions.
  Rationale: protected origins route through the central enforcer; the exception preserves hostname ownership and target checks rather than allowing arbitrary system resources. See ADR 29's delegation amendment.
  Date: 2026-11-08


- Decision: The delegation is its own platform scope, `platform:delegation-NAME`, that owns its namespaces, quotas and
  record; it is not folded into `platform:foundation`.
  Rationale: the foundation is compiled from packaged inputs at bootstrap (`compileFoundation` in
  `cli/nagarectl/src/Nagare/Inventory/Components/Foundation.hs`) and holds only `personal` and `nagare-system`; putting
  operator-chosen delegations in it would make every delegation change a platform transition. A separate scope gives a
  delegation its own reviewed lifecycle, its own accepted revision for D5 to check against, and a clean retirement.
  Rejected: issuing `NamespaceGrant`s to deployer scopes. A `NamespaceGrant` names one contributing scope id and lets it
  register any namespace on the cluster (`authorized` in `cli/nagare-dsl/src/Nagare/Resource/Inventory.hs`); app
  scopes do not exist when the delegation is reviewed, and the grant has no namespace bound.
  Date: 2026-11-07

- Decision: The delegation record is a ConfigMap in `nagare-system`, managed as a `NativeObject` by the Kubernetes
  executor, holding the canonical JSON of `DeployerDelegation`.
  Rationale: every inventory member needs an executor, and no ledger-only executor exists (`Executor` in
  `cli/nagare-dsl/src/Nagare/Resource/Inventory/Types.hs`). A ConfigMap also gives drift detection and an in-cluster read
  for a deployer that holds `get` on that one object. Rejected: a new `DesiredSpec` alternative and executor for a
  record with no provider effect.
  Date: 2026-11-07

- Decision: Bounds are checked twice: when the review is prepared, for a precise error before any publication, and at
  admission, against the delegation in the admitted head, so revocation and narrowed bounds apply to saved reviews.
  Rationale: a deployer saves and applies in separate steps, and Kotei retries saved reviews; admission is the only
  place that sees the head the change will commit on.
  Date: 2026-11-07

- Decision: The actor is asserted by the client from its context, not proved. `NAGARE_DEPLOYER` comes from the context
  file the deployer runs with; the operator's contexts never set it.
  Rationale: the deployer is trusted software (MasterPlan 33's trust model), and repository content cannot set the
  deployer's environment. Proving identity would need a server-side executor, which ADR 22's single client-side
  executor does not have. The ADR in D10 states this limit.
  Date: 2026-11-07

- Decision: The actor carries an optional operator name (`NAGARE_OPERATOR`) from the start; on the wire it is
  `{kind, name}`.
  Rationale: with an anonymous `operator` actor, adding names when Nagare gets several operators (MasterPlan 24's team
  streams) would change the review wire again and need a second release transition, and every earlier review would stay
  unattributed. An optional field read from this release on costs nothing now.
  Date: 2026-11-07

- Decision: A deployer may retire the apps and sites it created (`app delete`, `site preview delete`) inside its
  delegation, but never a namespace, quota or the delegation itself.
  Rationale: engineers need to remove a site without the operator; namespaces carry other engineers' sites.
  Date: 2026-11-07


## Outcomes & Retrospective

(To be filled at completion.)


## Context and Orientation

**Terms.** A *context* is one Nagare installation's target, a file of `export` lines selected with `--context`. The
*resource inventory* is the reviewed ledger of what each *scope* owns; a scope is named `KIND:NAME`, where the kinds are
`platform`, `application`, `standalone` and `publication` (`ScopeKind` in
`cli/nagare-dsl/src/Nagare/Resource/Types.hs`). A *review* is a saved, digest-identified change plan; applying it runs a
*transaction* whose events append to the *journal*, and the store's *head* (`HeadManifest` in
`cli/nagarectl/src/Nagare/Inventory/Store/Manifest.hs`) records the accepted revision of each scope. A *deployer* is a
CI/CD program the operator runs; a *delegation* is the reviewed permission this plan adds; the *actor* is who a review
says applied it.

**Where namespaces come from today.** The foundation scope `platform:foundation` declares `personal` and
`nagare-system` and a Job quota (`compileFoundation`). An app or site deploy looks its namespace up with
`acceptedFoundationNamespace` in `cli/nagarectl/src/Nagare/Inventory/DataService.hs`, which accepts only a Namespace
member of the foundation scope; callers are in `cli/nagarectl/app/Nagare/Cli/Commands/Application.hs`, `Site.hs` and
`Storage.hs`. `app deploy --request-namespace` emits a `RegisterNamespace` contribution that the composer allows only
when the foundation's bundle lists a `NamespaceGrant` for the requesting scope; in production
`foundationGrantedScopes` (`cli/nagarectl/app/Nagare/Cli/Bootstrap/Platform.hs`) lists only packaged observability
scopes, so in practice user apps go to `personal`.

**Where a review is built and admitted.** `prepareReviewWithPayloadIdentity` in
`cli/nagarectl/src/Nagare/Inventory/Plan/Prepare.hs` turns a `ChangeProposal` into a `ReviewBundle` and sets
`reviewSchemaVersion = 1`. `ReviewDocument` is in `cli/nagarectl/src/Nagare/Inventory/Plan/Types.hs` with its strict
encoder and decoder. Publication of the review object is in `cli/nagarectl/src/Nagare/Inventory/Plan/Publication.hs`.
`admitWithHistory` in `cli/nagarectl/src/Nagare/Inventory/Execute/Admission.hs` checks binding, `stale-head`,
`stale-base` and `active-transaction`, then claims the head; D5's check is added beside those.

**Wire changes.** Store objects are read by older CLIs during a release transition; EP-172 introduced reviewed release
transitions with a `TransitionMarker` in the head. Any new field that an older decoder would refuse must ride such a
transition. [MasterPlan 31](../masterplans/31-publish-durable-nagare-lifecycle-events-and-deliver-webhook-subscriptions.md)'s
EP-231 also plans a journal and head wire change; it was Not Started when this plan was written. If both are in
flight, they share one wire version.

**Decisions this rests on.** [ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md)
composes scopes with owner-authorized contributions and one executor, and says hashes give integrity, not authority, to
an actor that holds the store. [ADR 20](../adr/0020-domain-routing-and-tls-ownership-are-explicit.md) makes hostname
ownership explicit. [ADR 29](../adr/0029-site-access-is-a-reviewed-relationship-per-hostname.md) makes protected hosts
opt-in with `requireLogin`; D4 makes it mandatory for a deployer. [ADR 13](../adr/0013-operator-deployment-material-lives-in-a-private-repository-with-remote-state.md)
keeps operator material private. [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md)
orders the evidence.


## Plan of Work

First add the typed record: a new module `cli/nagarectl/src/Nagare/Inventory/DeployerDelegation.hs` with
`DeployerDelegation` (name, state `active | revoked`, namespaces, host suffixes, allowed kinds, image repository, team,
optional build namespace, quotas), its canonical JSON, and `compileDelegationScope`, modelled on `compileFoundation`:
it mints resource ids under `platform:delegation-NAME`, binds each Namespace, ResourceQuota, LimitRange and the record
ConfigMap with `bindKubernetesObject`, all `Retain`. Add `acceptedDelegations :: ScopeSnapshot -> Map Name
DeployerDelegation` that decodes the record from the accepted native bytes.

Generalize namespace lookup: add `acceptedAppNamespace` in `DataService.hs` that returns the foundation namespace when
present, else the namespace of an active accepted delegation, and switch the callers named above. Keep
`acceptedFoundationNamespace` for the foundation-only uses.

Add the commands in a new `cli/nagarectl/app/Nagare/Cli/Commands/Delegation.hs` and its parser: `create`, `revoke`,
`show`. `create` and `revoke` save reviews through the same path as other platform scopes; `show` reads the accepted
snapshot only.

Add the actor: `TargetProfile` gains an optional deployer name read from `NAGARE_DEPLOYER` and an optional operator
name read from `NAGARE_OPERATOR` (add both to the canonical
variables in `cli/nagarectl/src/Nagare/Target.hs`, to `nagare.target.env.example` and to `.envrc`'s exported list). A
dispatch-level guard refuses commands outside D3's set in a deployer context.

Add the bounds: a pure `checkDelegatedProposal` in `DeployerDelegation.hs` over the delegation, the context's base
domain and the changed scope declarations (`ScopeDeclaration`, as `compileTeamMemberScope` in
`cli/nagarectl/src/Nagare/Inventory/Access.hs` returns), called from the review preparation path when the
profile is a deployer context, and from `admitWithHistory` against `acceptedDelegations` of the admitted head. Hostname
checks include ownership and the fixed enforcer target for generated system routes; worker deploy accepts EP-249's rendered-worker document and otherwise refuses config execution. Hostname rules reuse the host shapes in `cli/nagarectl/src/Nagare/Deploy/Host.hs` so direct and tunnel contexts both work.

Add attribution: extend `ReviewDocument` with `reviewActor` and `reviewSource`, update its encoder, decoder and digest,
thread `--source-repository` and `--source-run` through the app, worker and site deploy parsers next to `--source`, and
add `inventory history` reading journal events and their reviews.

Then the contract documents, the transition fixture, the local confirmation and the docs.


## Validation

From the repository root:

```bash
just haskell-style-check
just gate-fast
cd cli/nagarectl && cabal test nagarectl-test --test-options='-p /Delegation/'
cd cli/nagarectl && cabal test nagarectl-test --test-options='-p /Contract/'
cd cli/nagare-api-server && cabal test nagare-api-server-test
```

D4 and D5 pass when every bound has a refusing case, the passing case writes a review, and no refused case writes any
store object. D9 runs on a local context (see `docs/user/local-development.md`) after
[Before a native run](../runbooks/before-a-native-run.md); its transcript names the refused hostname and the
`deployer:NAME` actor.


## Interfaces

```haskell
-- cli/nagarectl/src/Nagare/Inventory/DeployerDelegation.hs (new)
data DelegationState = DelegationActive | DelegationRevoked
data DelegatedKind = DelegatedWebApp | DelegatedWorker | DelegatedTask | DelegatedStaticSite | DelegatedServerSite
data DeployerDelegation = DeployerDelegation
  { name :: !Name
  , state :: !DelegationState
  , namespaces :: !(NonEmpty Name)
  , hostSuffixes :: ![Text]
  , kinds :: !(NonEmpty DelegatedKind)
  , imageRepository :: !Text
  , team :: !Text
  , buildNamespace :: !(Maybe Name)
  , quota :: !DelegationQuota
  }
data Actor = OperatorActor !(Maybe Name) | DeployerActor !Name
data ReviewSource = ReviewSource {repository :: !(Maybe Text), revision :: !(Maybe Text), run :: !(Maybe Text)}
acceptedDelegations :: ScopeSnapshot -> Map Name DeployerDelegation
checkDelegatedProposal :: DeployerDelegation -> Text -> [ScopeDeclaration] -> Either (NonEmpty DelegationViolation) ()
```

Consumers: EP-248 reads `namespaces`, `buildNamespace` and `imageRepository` through `acceptedDelegations` and writes
`NAGARE_DEPLOYER` into the bundle's context file. EP-249 refuses config programs when the profile's deployer is set.
EP-250 reads `team` and `namespaces`. Kotei's
`mori://shinzui/kotei/plans/138-deploy-rendered-apps-and-static-sites-through-a-delegated-nagare-deployer` reads the
`delegation` document and passes `--source-repository`, `--source` and `--source-run`. A field added later is recorded
in this plan's Decision Log first.

Revision (2026-11-08): applied the MasterPlan 33 review findings to the interfaces, acceptance and ownership described above.
