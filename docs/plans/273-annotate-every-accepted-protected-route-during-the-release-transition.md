---
id: 273
slug: annotate-every-accepted-protected-route-during-the-release-transition
title: "Annotate every accepted protected route during the release transition"
kind: exec-plan
created_at: 2026-11-21T05:39:09Z
intention: "intention_01m7y7ytzsethbg8mzt865m4rt"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-11-21T05:39:09Z
---

# Annotate every accepted protected route during the release transition

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture

Nagare v0.24.5 lets WebSocket upgrades reach login-protected (`requireLogin`) sites. It does this by
rendering the annotation `kourier.knative.dev/disable-http2: "true"` on every DomainMapping whose
target is the nagare-access enforcer ("protected route"). The renderer runs only when a site is
deployed, though. A route already accepted in the inventory keeps the bytes the older CLI rendered
until its own site is redeployed with 0.24.5.

That is not enough, because Kourier gives every protected route **one shared Envoy cluster**
(`nagare-system/nagare-access`). If one accepted protected route lacks the annotation, Kourier may
build that cluster as HTTP/2, and every WebSocket upgrade to every protected host fails with 503 UC.
On 2026-11-21 the labs intranet had 11 such routes whose sites could not be redeployed that night:

- five configs no longer compile against the current DSL;
- three would also roll unrelated, undeployed Service changes;
- three belonged to the `kotei-ci` deployer's runner, then still on 0.24.4.

The operator's session added the annotation to those 11 by hand with `kubectl annotate`. They now
differ from Nagare's accepted state, and the field is owned by the `kubectl-annotate` field manager.

After this plan, upgrading a context to the release that contains it (v0.24.6) re-declares every
accepted protected route that lacks the annotation. The bytes are its accepted bytes plus the
annotation; the identity, address, lifecycle and owning scope are unchanged. The re-declaration
goes through a reviewed transition stage, and `platform transition commit` refuses until none is
left. Accepted state then matches the cluster for every protected route without touching any
site's config. On labs, the 11 hand edits become Nagare-owned again: `kubectl-annotate` no longer
appears among the routes' field managers.

Observable result: after `platform transition commit` on a context that has un-annotated protected
routes, this lists zero hosts:

```bash
kubectl -n nagare-system get domainmappings -o json | jq -r '.items[]
  | select(.spec.ref.name == "nagare-access")
  | select(.metadata.annotations["kourier.knative.dev/disable-http2"] != "true")
  | .metadata.name'
```

`inventory status` shows no configuration drift for those routes, and an anonymous HTTP/1.1
WebSocket upgrade to any protected host gets nagare-access's 302 or 401, never a 503.

This is the heavy path in this repository's rules: it rewrites accepted inventory state of scopes
the platform does not own, during a release upgrade. It therefore needs this ExecPlan, a mutation
record for each guard, the EP-172 upgrade rehearsal seeded with an un-annotated route, and a
deferral-ledger entry for any finding it leaves open.


## Progress

- [ ] **M1. The route transform.** A pure function takes an accepted scope declaration and the
  accepted native bytes of its protected routes. It returns the scope re-declared with each
  un-annotated protected route carrying the annotation, everything else byte-identical. Unit tests
  prove: identity, address, lifecycle, dependencies, contributions, scope overrides and config
  digest are unchanged; an already-annotated route and a route to any other target are left alone;
  an existing annotation map is merged, not replaced. Mutation records cover dropping the merge and
  widening the target check.
- [ ] **M2. The transition stage.** `planNextStage` plans, after the platform scopes converge, a
  stage that re-declares every accepted non-platform scope holding an un-annotated protected route
  through the M1 transform. Planning again after it applies gives zero operations.
  `transitionCommitRefusal` refuses while any accepted protected route lacks the annotation.
  Interpreter tests drive the stage through the adversarial provider states, including a live
  route whose field is owned by `kubectl-annotate` (the F37 reviewed field takeover must settle).
  Mutation records cover the commit refusal and the stage selection.
- [ ] **M3. Rehearsal and native confirmation.** The EP-172 transition rehearsal is seeded with a
  protected route rendered without the annotation, plus one annotated by `kubectl annotate`. It
  moves from v0.24.5 to the candidate and reads both back annotated and Nagare-owned, with the
  seeded data row unchanged. On labs, the v0.24.6 transition leaves zero un-annotated protected
  routes and no `kubectl-annotate` field manager on any of them, and an anonymous WebSocket
  upgrade to `kotei-ui.labs` gets a 302.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Fix this in the release transition, not by redeploying each site.
  Rationale: The shared Envoy cluster makes the fix all-or-nothing across protected routes. A
  per-site rollout depends on every site's config compiling and every owner acting. On
  2026-11-21 that blocked 8 of 22 routes on labs and forced hand edits outside the journal.
  Date: 2026-11-21 (operator).
- Decision: Re-declare from accepted bytes, never from a site's config.
  Rationale: The context move already does this (`carryOldRoutesWhere` in
  `cli/nagarectl/src/Nagare/Context/MoveRoutes.hs`): accepted bytes, one inserted annotation,
  identity and address kept, so every grant bound to the route survives (ADR 29). Recompiling a
  site's config would ship unrelated changes, or fail on configs written for an older DSL.
  Date: 2026-11-21.


## Outcomes & Retrospective

(To be filled at completion.)


## Context and Orientation

**Terms.**
- A **protected route** is a Knative `DomainMapping` in namespace `nagare-system` whose
  `spec.ref` is the Knative Service `nagare-access` (the login enforcer). One exists per public
  hostname of every `requireLogin` site, plus the admin API's.
- An **accepted scope** is an inventory scope (`Platform`, `Application`, `Standalone`, …) at the
  revision the inventory head records as desired state. Each Kubernetes member has **native
  bytes**, the exact object Nagare applies, stored content-addressed and named in the declaration
  by a digest (`NativeObject <digest>`).
- A **release transition** moves an installed context to a new release in reviewed stages
  (`nagarectl platform transition plan`, then `inventory apply`, then commit), described in
  `docs/user/upgrades.md`.

**Why the annotation matters.** Knative names a route's placeholder Service port `http2`, so
net-kourier builds the cluster for a DomainMapping's re-entry hop as HTTP/2. Envoy cannot forward
a WebSocket upgrade over that hop (net-kourier #801), and the annotation turns the hop back into
HTTP/1.1. net-kourier keys clusters by target Service (`pkg/generator/ingress_translator.go`) and
sends every cached copy to Envoy (`pkg/generator/cluster_cache.go`, `list()`), so all protected
routes share one cluster. Annotating only some of them therefore leaves that cluster's protocol
undetermined.

**Code to read.**
- `cli/nagarectl/src/Nagare/Access/Resolve.hs`, `renderAccessDomainMapping` and
  `isCentralEnforcer`: the 0.24.5 renderer and the predicate for "targets the enforcer". Reuse
  `isCentralEnforcer`'s definition so the transform and the renderer cannot disagree.
- `cli/nagarectl/src/Nagare/Context/MoveRoutes.hs`, `carryOldRoutesWhere` and
  `withoutOriginTls`: the precedent. It takes accepted native bytes, inserts an annotation into the
  existing map, recomputes the spec digest, and rebuilds the scope with `withScopeOverrides` and
  `withScopeConfigDigest`.
- `cli/nagarectl/src/Nagare/Context/MoveCarry.hs`, `carryWithAcceptedRoutesWhere`: loads the
  accepted native bytes through `loadAcceptedNativeSelected` (`cli/nagarectl/src/Nagare/Inventory/Status.hs`).
- `cli/nagarectl/app/Nagare/Cli/Bootstrap/Sequence.hs`, `planNextStage`: the ordered stage
  selection (local substrate, cloud, images, host, kubeconfig, zone, platform). The new stage goes
  last.
- `cli/nagarectl/app/Nagare/Cli/Commands/Transition.hs`, `runPlatformTransitionPlan` and
  `runPlatformTransitionCommit`. `cli/nagarectl/src/Nagare/Platform/Transition.hs`,
  `transitionCommitRefusal`: today it only checks that platform scopes have converged.
- `cli/nagarectl/src/Nagare/Inventory/KubernetesConfiguration.hs`, `foreignFieldManagers`,
  `confirmReviewedFieldTakeover`, `confirmTakeoverSettled`: the F37 field takeover. A takeover
  settles only if no foreign manager owns an undeclared field afterwards. Because the re-declared
  route declares the annotation, the forced server-side apply moves the field to
  `nagare-inventory` and the `kubectl-annotate` entry empties.
- `cli/nagarectl/src/Nagare/Inventory/DeployerDelegation.hs`, `expectedProtectedMappingDigest`:
  deployer admission compares a deployer's protected route against the applying CLI's renderer.
  Re-declared bytes must equal what `renderAccessDomainMapping` renders, or the next deployer
  review is refused. M1's tests check that equality for routes the access renderer produced.

**ADRs.**
- [ADR 6](../adr/0006-version-platform-state-across-cli-payload-context-host-and-cluster.md):
  the transition's pin is its last write; the commit refusal is where "every protected route is
  annotated" belongs.
- [ADR 20](../adr/0020-domain-routing-and-tls-ownership-are-explicit.md): routes are explicit
  inventory members owned by their site's scope; this plan keeps the owner unchanged.
- [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md): the
  stage is proved by interpreter tests before any native run; the native run only confirms.
- [ADR 29](../adr/0029-site-access-is-a-reviewed-relationship-per-hostname.md): grants bind to
  the route's identity, which this plan must not change.

**Labs state this plan settles.** Created by hand on 2026-11-21 at 04:59Z and owned by
`kubectl-annotate`, in `nagare-system`:

- the operator's sites: `auth`, `keiro-kenshou`, `protected-hello`, `keiro-docs`,
  `okf-profiles`, `platform-hub`, `product-hub` and `qa-hub` (all `.labs.topagentnetwork.net`);
- the `kotei-ci` deployer's: `nagare-deployer-check.kotei-ci-apps`,
  `network.tan-connect-lp.preview` and `tan-connect-lp.kotei-ci-apps`.

The other 11 protected routes were annotated through 0.24.5 deploys or the v0.24.5 transition.


## Plan of Work

**M1.** Add a module `cli/nagarectl/src/Nagare/Access/ProtectedRouteRefresh.hs`, exporting
`refreshProtectedRoutes :: Map ResourceId ByteString -> ScopeDeclaration -> Either Text (Maybe (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString)))`.
It returns `Nothing` when the scope has no un-annotated protected route. A member counts as a
protected route when:

- its address is a `serving.knative.dev` `domainmapping` in `nagare-system`;
- its accepted bytes have `spec.ref` equal to the enforcer target in `isCentralEnforcer`;
- `metadata.annotations["kourier.knative.dev/disable-http2"]` is not `"true"`.

For each such member, insert the annotation into the existing annotations object, keeping every
other key (this includes Nagare's own `nagare.dev/*` stamps if accepted bytes carry them).
Canonicalize with `canonicalValue`, set `spec` to `NativeObject (contentDigest bytes)`, and keep
every other field of the `ManagedResource`. Rebuild the scope the way `carryOldRoutesWhere` does,
keeping its overrides and config digest. Put the shared annotation key in one place used by both
`renderAccessDomainMapping` and this module. Tests go in a new
`cli/nagarectl/test/AccessRouteRefreshSpec.hs`, registered in `cli/nagarectl/nagarectl.cabal`.

**M2.** In `planNextStage`, after the platform candidate yields no operations, load the snapshot
and the accepted native bytes of every protected route in non-platform scopes (one
`loadAcceptedNativeSelected` call). Build a candidate holding only the scopes
`refreshProtectedRoutes` changes, and plan it with the same payload identity as the other stages,
so its review is a transition review. Extend `transitionCommitRefusal`'s callers to refuse while
the M1 predicate finds any accepted protected route without the annotation. The refusal message
names the first such route and says to plan the transition's next stage.

First check that admission accepts a transition review changing `Application` and `Standalone`
scopes. If it refuses, record the refusal under Surprises and decide between widening the
transition's admitted scope set (preferred, with its own mutation record) and a separate reviewed
command run by the intranet step. Record that choice in the Decision Log before continuing.

Interpreter tests go beside the existing transition tests in `cli/nagarectl/test/`. They cover:

- a lost acknowledgement, and landed but unready;
- a replaced route (new UID);
- a route with a `kubectl-annotate` field manager, which must settle under F37;
- a scope accepted again by a site deploy between plan and apply, where the stale review is
  refused and planning again yields zero operations.

**M3.** Extend the EP-172 rehearsal seed (`scripts/transition-rehearsal.sh` through
`nagare-harness transition drill`) with one protected site deployed by the v0.24.5 CLI, whose
route's annotation is then removed with `kubectl annotate …-`, so the route is un-annotated
without being drift. Add one route annotated with `kubectl annotate`. The drill asserts both
routes come back annotated, Nagare-owned, and still bound to their grants. Then ship v0.24.6 by
`docs/runbooks/releases.md` and check labs as in Validation.


## Concrete Steps

From the repository root:

```bash
just gate-commit            # per Haskell commit: style, touched packages, touched test groups
just gate-fast && just land HEAD
```

Release, after M3's rehearsal change lands (see `docs/runbooks/releases.md`):

```bash
scripts/harness.sh release images prepare   # after bumping release.json to 0.24.6
just gate-fast && just land HEAD
CACHIX_AUTH_TOKEN=... just release-candidate 0.24.6 --revision REV
just release-publish 0.24.6
```

The labs check, from the operator repository `mori://tan/tan-ng-labs`:

```bash
direnv exec . kubectl -n nagare-system get domainmappings -o json | jq -r '.items[]
  | select(.spec.ref.name == "nagare-access")
  | [.metadata.name, (.metadata.annotations["kourier.knative.dev/disable-http2"] // "MISSING"),
     ([.metadata.managedFields[].manager] | join(","))] | @tsv'
```

Expected after commit: every row says `true`, and no row lists `kubectl-annotate`.


## Validation and Acceptance

- M1: `just gate-commit` green with `AccessRouteRefreshSpec` selected. Re-declaring a route that
  `renderAccessDomainMapping` produced without the annotation yields exactly the bytes the 0.24.5
  renderer produces, which keeps `expectedProtectedMappingDigest` in agreement.
- M2: the interpreter tests pass. A saved review from `platform transition plan` on a scripted
  head with three un-annotated routes lists three `UpdateResource` operations on DomainMappings and
  nothing else. Planning again after the apply gives `Impact: 0 operations`.
  `platform transition commit` refuses before the apply and succeeds after.
- M3: the rehearsal record shows both seeded routes annotated and the seeded row unchanged. On
  labs, the Concrete Steps listing shows 22 rows of `true` and no `kubectl-annotate`. An anonymous
  HTTP/1.1 upgrade to `https://kotei-ui.labs.topagentnetwork.net/api/kotei/v1/runs/probe/socket`
  gets a 302.


## Idempotence and Recovery

The transform is idempotent: an annotated route is never selected, so a second plan gives zero
operations. Each stage is an ordinary reviewed inventory transaction. A stop mid-apply is resumed
or closed with `nagarectl inventory recover` like any other, and the commit refusal keeps the pin
from moving until the stage converges. Rollback is not claimed (`rollbackSupportedFrom` stays
empty). If the stage must be undone, a site redeploy with an older CLI is refused by F37 rather
than silently reverting, and the annotation can be removed by a reviewed redeploy of that site.


## Interfaces and Dependencies

- New: `Nagare.Access.ProtectedRouteRefresh.refreshProtectedRoutes` (signature in Plan of Work),
  and one exported constant for the annotation key, used by `Nagare.Access.Resolve`.
- Changed: `planNextStage` (one stage appended), the commit refusal's inputs, and the EP-172
  rehearsal seed.
- External: Knative Serving and net-kourier knative-v1.22.0, as vendored in
  `cluster/bootstrap/vendor/`. A net-kourier upgrade must keep honouring
  `kourier.knative.dev/disable-http2`; the route check's WebSocket step
  (`cli/nagare-harness/src/Nagare/Harness/RouteCheck.hs`) catches a regression in the
  site-access drill.
