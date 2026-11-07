---
id: 250
slug: open-a-delegated-namespace-s-sites-to-the-delegation-s-team-without-a-per-site-grant
title: "Open a delegated namespace's sites to the delegation's team without a per-site grant"
kind: exec-plan
created_at: 2026-11-07T16:50:58Z
master_plan: "docs/masterplans/33-delegate-a-bounded-part-of-a-context-to-a-ci-deployer-so-engineers-deploy-by-pushing.md"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-11-07T16:50:58Z
---

# Open a delegated namespace's sites to the delegation's team without a per-site grant

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and
Outcomes & Retrospective current.


## Purpose / Big Picture

On Nagare every protected hostname is its own authorization object: signing in admits nobody, and someone must apply a
reviewed grant for each host before anyone can open it. Grants need the access service's read-write key
(`NAGARE_EN_API_KEY`). A deployer creating sites on behalf of engineers would therefore either leave every new site
unopenable until the operator grants it, or need that key, which lets it grant anyone anything.

After this plan the operator applies one reviewed grant: team T may open every protected site in delegation D. From
then on, every protected site deployed into D's namespaces opens for members of T as soon as it is served, with no
grant of its own and with the deployer holding no access-service key. A signed-in user outside T is still refused, an
anonymous visitor is still sent to sign in, and direct per-host grants keep working beside the inherited one.

This is a child of
[MasterPlan 33](../masterplans/33-delegate-a-bounded-part-of-a-context-to-a-ci-deployer-so-engineers-deploy-by-pushing.md)
and delivers UC-4's `default-access-for-delegated-sites`
([UC-4](../use-cases/004-engineers-deploy-sites-by-pushing-through-a-delegated-deployer.md)). It hard-depends on
[EP-247](247-review-a-bounded-namespace-delegation-for-a-named-deployer-and-record-who-applied-each-change.md) for the
delegation's name, namespaces and team. Kotei's end-to-end acceptance in
`mori://shinzui/kotei/plans/138-deploy-rendered-apps-and-static-sites-through-a-delegated-nagare-deployer` uses it for its
access check.


## Progress

D1 is a bounded prototype that decides the design; the rest implements the chosen design. Interpreter evidence first,
the local-context run confirms ([ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md)).

- [ ] D1, prototype and decision: against the En release Nagare pins, prove on a local context that a schema with a
  second object type, `object delegation { relation viewer: user, group#member  permission access = viewer }`, is
  accepted beside the existing `app` and `group`, that `delegation:D#viewer@group:T#member` plus a membership makes
  `check(user, access, delegation:D)` allowed and a non-member denied, and measure a decision-cache miss that needs a
  second check against one that does not. Accept the enforcer-side design below if all three hold; otherwise record
  why in the Decision Log and choose the alternative listed there before any further deliverable. Evidence: the
  prototype transcript and the two latency figures in this plan's Surprises & Discoveries; the prototype branch is
  discarded.
- [ ] D2, the schema: `cluster/bootstrap/en/configmap.yaml` declares the `delegation` object, and the schema support check
  (`teamSchemaDeclarations` and `activeSchemaSupportsTeams` in `cli/nagarectl/src/Nagare/Inventory/Access.hs`) requires it
  before a delegation grant is planned, refusing with the schema as the reason. Evidence: unit tests of the check over a
  schema with and without the new object.
- [ ] D3, the backend map names the delegation: a `RegisterBackend` contribution for a protected host whose namespace
  belongs to an accepted delegation carries that delegation's name; `BackendMapSpec` entries and the
  `nagare-access-backends` ConfigMap (`renderBackendMapNative` in `cli/nagarectl/src/Nagare/Inventory/BackendMap.hs`)
  carry it as an optional `delegation` member of the entry object (an undelegated protected entry stays the bare
  upstream string `backendEntry` writes today); hosts in other namespaces are unchanged byte for byte. An enforcer that
  predates the member reads the entry as an ordinary protected host, so it fails closed: the site opens only by direct
  grant until the enforcer is upgraded. The name comes from
  the namespace, not from who deploys, so an operator deploying into a delegated namespace gets the same behavior.
  Evidence: composer tests for a delegated and an undelegated host, and a test that existing backend-map native bytes
  are unchanged for an undelegated map.
- [ ] D4, the enforcer: `nagare-access` decodes the optional member into `BackendTarget`
  (`cli/nagare-access/src/Nagare/Access/BackendMap.hs`); on a decision-cache miss it checks `app:HOST#access` first and,
  only when that is denied and the host has a delegation, `delegation:D#access`. Either allowed admits; both denied
  refuses with 403; either check unavailable is a 503, as today (`authorizationFromClientResult` in
  `cli/nagare-access/src/Nagare/Access/En.hs`). The decision cache keeps its key and TTL. Evidence: `nagare-access-test`
  cases for allowed-by-host, allowed-by-delegation, denied-by-both, unavailable-second-check and a host without a
  delegation never making the second call.
- [ ] D5, the grant: `nagarectl access grant --delegation D --team T --save-plan DIR` and the matching `revoke` review the
  En relationship `delegation:D#viewer@group:T#member` as a new access tuple owned by the delegation scope, with the same
  preconditions and recovery as team host grants. EP-247's `delegation create --team T` includes this grant in the
  operator's creation review. `nagarectl access list --host HOST` and `access check` report access inherited through a
  delegation and name it. Evidence: review fixtures for grant and revoke, and `access check` tests for inherited access.
- [ ] D6, the local confirmation: on a local context, with a delegation whose team has one member and a second signed-up
  user outside it, a deployer deploys a new protected site into the delegation; with no grant of its own, an anonymous
  request is redirected to sign in, the member gets 200 and the outsider gets 403; after `access revoke --delegation`,
  the member gets 403 within the decision-cache TTL; a direct `access grant --host` for the outsider admits them.
  Evidence: an audit file under `docs/audits/` with the requests and status codes.
- [ ] D7, docs and decision: ADR 29 is amended: a hostname in a delegated namespace inherits the delegation's grants;
  there is still no bypass and signing in still admits nobody. `docs/user/access.md` gains "Delegation-wide access".
  Evidence: the linked pages.


## Surprises & Discoveries

(None yet; D1 records its figures here.)


## Decision Log

- Decision (subject to D1): inheritance is resolved by the enforcer from the backend map, with one En relationship per
  delegation, not by per-host En relationships.
  Rationale: the deployer already writes the backend map for every protected host it deploys (the composer regenerates
  `nagare-access-backends` from `RegisterBackend` contributions in `cli/nagare-dsl/src/Nagare/Resource/Inventory.hs`), and
  EP-248 grants it exactly that ConfigMap. Carrying the delegation name there needs no En write at deploy time, so the
  deployer never holds `NAGARE_EN_API_KEY`. The one relationship that grants the team is an operator review.
  Rejected: an En arrow such as `permission access = viewer + delegation->viewer` on `app`, which needs a per-host
  relationship `app:HOST#delegation@delegation:D` written when each site is created, so the deployer would need the
  write key or every deploy would wait for the operator. Rejected: a wildcard host grant, which En does not have and
  which would make the bound a string pattern instead of a reviewed object.
  Date: 2026-11-07

- Decision: The delegation name on a backend entry is derived from the host's namespace, not from the actor.
  Rationale: "every site in this delegation opens for the team" must hold whoever deployed it, and a namespace has one
  owner. The actor-based alternative would make an operator's deploy into a delegated namespace behave differently.
  Date: 2026-11-07

- Decision: Revoking a delegation (EP-247) does not revoke its access grant. Sites stay served and stay open to the team
  until the operator revokes the grant with `access revoke --delegation`.
  Rationale: revoking the deployer's right to deploy is not a decision to lock readers out of running sites; access
  changes stay explicit reviews (ADR 29).
  Date: 2026-11-07

- Decision: The direct host check runs first and the delegation check only on its denial.
  Rationale: most hosts outside delegations never pay a second call; inside a delegation the second call happens only on
  a cache miss for a user without a direct grant, and D1 measures its cost.
  Date: 2026-11-07


## Outcomes & Retrospective

(To be filled at completion.)


## Context and Orientation

**Terms.** *En* is the authorization service; it stores *relationships* such as `app:HOST#viewer@user:U` and answers
*checks* such as "may user U `access` `app:HOST`". Its *schema* declares object types, relations and permissions.
*nagare-access* is Nagare's gateway (the *enforcer*) in front of protected sites; it signs users in through Shomei and asks
En on each decision-cache miss. The *backend map* is the `nagare-access-backends` ConfigMap telling the enforcer which
upstream serves each protected host. A *team* is an En group whose members are users.

**How access works today.** The schema is `cluster/bootstrap/en/configmap.yaml`: `object group { relation member: user }`
and `object app { relation viewer: user, group#member  permission access = viewer }`. The enforcer builds its check in
`buildCheckRequest` (`cli/nagare-access/src/Nagare/Access/En.hs`): subject `user`, permission `access`, object
`app:HOST`, fully consistent. Grants are inventory members: `relationshipOf` in `cli/nagarectl/src/Nagare/Inventory/Access.hs`
maps the access provider addresses `AccessTuple`, `TeamMemberTuple` and `TeamAccessTuple` to `DirectViewer`,
`TeamMember` and `TeamViewer`, applied by the access executor with the read-write En key. Team grants were added by
MasterPlan 27 (EP-187) and are described in [Identity-aware access](../user/access.md). The decision cache
(`cli/nagare-access/src/Nagare/Access/DecisionCache.hs`) holds answers for `NAGARE_ACCESS_DECISION_TTL`, 30 seconds by
default.

**How the backend map is built.** A protected site emits a `RegisterBackend` contribution
(`Contribution` in `cli/nagare-dsl/src/Nagare/Resource/Inventory/Types.hs`); the composer groups them per auth owner and
cluster into one `BackendMapSpec` member, rendered by `renderBackendMapNative`; the enforcer decodes it with
`decodeBackendMap` into `BackendTarget` values.

**Decisions this rests on.** [ADR 29](../adr/0029-site-access-is-a-reviewed-relationship-per-hostname.md) makes each
hostname its own authorization object with no bypass and reviewed grants; this plan amends it.
[ADR 15](../adr/0015-the-auth-portal-hands-sessions-to-nagare-access-through-response-headers.md) covers how sessions
reach the enforcer, unchanged here. The backend map and enforcer image are platform state, so D2–D4 ride a reviewed
release transition like any platform change.


## Plan of Work

Run D1 first on a local context with a throwaway schema edit and a hand-made relationship, and record the result. Then
add the `delegation` object to the schema and its support check. Extend `RegisterBackend` and `BackendMapSpec` with an
optional delegation name (updating the canonical wire in `cli/nagare-dsl/src/Nagare/Resource/Wire.hs` so undelegated
entries keep their bytes), set it in the composer from EP-247's accepted delegations by namespace, and render it.
Extend `BackendTarget` and `decodeBackendMap`, then the enforcer's authorization path with the second check. Add a
`DelegationAccessTuple` provider address and `DelegationViewer` relationship, the `--delegation` option on `access grant`
and `access revoke`, and inherited-access reporting in `access list` and `access check`. Then the local confirmation and
docs.


## Validation

```bash
just haskell-style-check
just gate-fast
cd cli/nagare-access && cabal test nagare-access-test
cd cli/nagarectl && cabal test nagarectl-test --test-options='-p /Access/'
cd cli/nagare-dsl && cabal test nagare-dsl-test --test-options='-p /Inventory/'
```

D6 runs on a local context after [Before a native run](../runbooks/before-a-native-run.md). It passes when the three
status codes (redirect, 200, 403) are observed for the anonymous, member and outsider requests before any per-host
grant exists, and the revocation turns the member's 200 into 403 within the configured TTL.


## Interfaces

```text
En schema (cluster/bootstrap/en/configmap.yaml), added:
  object delegation {
    relation viewer: user, group#member
    permission access = viewer
  }

Backend map entry (data."backends.json"): an undelegated protected host stays a bare upstream string;
a delegated one becomes an object, as API backends already are:
  "HOST": { "upstream": "http://...", "role": "protected", "delegation": "D" }
```

```haskell
-- cli/nagare-access/src/Nagare/Access/BackendMap.hs
data BackendTarget = BackendTarget
  { upstreamUrl :: !Text
  , role :: !BackendRole
  , apiPrefix :: !(Maybe Text)
  , timeoutSeconds :: !(Maybe Int)
  , delegation :: !(Maybe Text)   -- new
  }

-- cli/nagarectl/src/Nagare/Inventory/Access.hs
data Relationship = ... | DelegationViewer !Name !TeamKey   -- new
```

```bash
nagarectl access grant  --delegation D --team T --save-plan DIR
nagarectl access revoke --delegation D --team T --save-plan DIR
```

EP-247 owns the delegation's name, namespaces and team; this plan reads them through `acceptedDelegations`.
