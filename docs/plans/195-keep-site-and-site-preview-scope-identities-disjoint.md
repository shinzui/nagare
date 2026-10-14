---
id: 195
slug: keep-site-and-site-preview-scope-identities-disjoint
title: "Keep site and site preview scope identities disjoint"
kind: exec-plan
created_at: 2026-10-14T15:15:38Z
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-10-14T15:15:38Z
---

# Keep site and site preview scope identities disjoint

This ExecPlan is a living document. Keep Progress and the Decision Log current.


## Purpose / Big Picture

A production site and a site preview must never share an inventory scope. Today they can.
Nagare names a production site's scope `standalone:site-<site>` and a preview's scope
`standalone:site-preview-<site>-pr-<preview>`. A site named `preview-blog-pr-x` therefore gets
exactly the same scope as preview `x` of site `blog`. A site named `preview-anything` is also
treated as a preview by everything that recognizes previews by the `site-preview-` prefix.

After this change, `nagarectl` refuses a site name beginning with `preview-` when it loads the
site's configuration. The two scope families can no longer overlap, and the prefix check that
recognizes previews becomes exact. An operator sees the refusal as an ordinary configuration
error naming the rule, before any review is saved.


## Progress

- [ ] M1. Severity and real-world exposure are established. An interpreter test reproduces the
      collision: deploy preview `x` of site `blog`, then deploy site `preview-blog-pr-x`. The test
      records what the saved review proposes for the preview's members, and whether any durable
      (`Retain`) member's identity or data is affected. A read-only check of the intranet context
      shows whether any accepted or retained scope there belongs to a site named `preview-*`.
- [ ] M2. `mkSiteName` refuses names beginning with `preview-`. The M1 reproduction and the
      `cleanup --previews` case below fail before the fix and pass after it. `just haskell-style-check`
      and `just gate-fast` are green, and the change lands through `just land`.


## Decision Log

2026-10-14: Fix the collision by refusing site names that begin with `preview-`, not by renaming
either scope family. Renaming the preview prefix would change the scope identity of every existing
preview. Since v0.4.0 that needs a reviewed release transition (EP-172), which is far more work
than one refusal. The refusal changes no existing identity, provided M1 finds no such site on the
intranet. If M1 finds one, stop and ask the operator before changing anything.

2026-10-14: Put the refusal in `mkSiteName` (`cli/nagare-dsl/src/Nagare/Dsl/Static/Types.hs`).
Both static and server sites load through it (`Dsl/Load/StaticSite.hs` and
`Dsl/Load/ServerSite.hs`), so a bad name fails at configuration load, before compilation, review
or store access. A check in the scope compiler would come later and in two places.


## Context and Orientation

Run commands from the repository root. A *scope* is an independently versioned set of resource
declarations in a context's inventory store, identified by a `ScopeId` made of a kind and a name
(`cli/nagare-dsl/src/Nagare/Resource/Types.hs`). A *resource identity* (`ResourceId`) is minted from
the owning scope, a logical key and a role. Two compilers build `Standalone` scopes for sites:

- `cli/nagarectl/src/Nagare/Inventory/Site.hs` builds a production site's scope as
  `mkScopeId Standalone ("site-" <> name)`, with its Knative Service and DomainMappings, plus
  retained or deletable volumes whose identities use the role `site-pvc`.
- `cli/nagarectl/src/Nagare/Inventory/Site/Preview.hs` builds a preview's scope as
  `mkScopeId Standalone ("site-preview-" <> serviceName)`, with the same `site-pvc` volume role.
  The preview Service name comes from `previewServiceName` in
  `cli/nagarectl/src/Nagare/Static/Preview.hs`: `<site>-pr-<normalized preview>`, truncated to 63
  characters.

`mkSiteName` currently accepts any 1–63 character DNS label of `a-z`, `0-9` and `-` that does not
start or end with a hyphen. Nothing rejects the `preview-` prefix. Two consequences follow:

1. **Identity collision.** Site `preview-blog-pr-x` and preview `x` of site `blog` both own
   `standalone:site-preview-blog-pr-x`. Deploying one replaces the other's accepted declarations in
   that scope. Volumes with the same volume name also mint the same `ResourceId` for two different
   claims (`nagare-vol-preview-blog-pr-x-<vol>` and `nagare-vol-blog-pr-x-<vol>`). M1 measures what
   the planner does with that.
2. **Misclassification.** `previewOwner` in `cli/nagarectl/src/Nagare/Inventory/PreviewCleanup.hs`
   is a pure prefix test (`Standalone` and the name starting with `site-preview-`). For any site named
   `preview-*`:
   - `previewCleanupServices` selects the site and then fails its exact preview check, so
     `nagarectl cleanup --previews` refuses for the whole namespace.
   - After the site is retired, `eligiblePreviewCollections` can select its retained *stateless*
     members for collection. `supportsRetainedCollection` in
     `cli/nagarectl/src/Nagare/Inventory/CollectionPolicy.hs` admits only `DeleteWhenUnreferenced`
     plus `Stateless` members, so a `Retain`/`Durable` site volume is never offered.

   The command in plan 193 (`site list`) would also report such a site as a preview.

Relevant ADRs: [ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md)
makes scopes independent, typed ownership boundaries, which this collision breaks.
[ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md) requires the
defect to be shown in an interpreter test, not a native run. No ADR change is needed.

Existing tests to extend: the `mkSiteName` group in `cli/nagare-dsl/test/StaticSpec.hs`, and the
preview fixtures in `cli/nagarectl/test/Nagare/Test/SiteInventory/Preview.hs`.


## Plan of Work

M1. Add an interpreter test to `cli/nagarectl/test/Nagare/Test/SiteInventory/Preview.hs` that
deploys preview `x` of site `blog`, with one `Retain` volume `data`, against a memory store. The
test then plans site `preview-blog-pr-x`, which also has a `Retain` volume `data`. `SiteName` is
abstract, so the site is built through `mkSiteName`, which accepts the name until M2. Assert what the saved review proposes for the preview's Service, routes
and volume, and whether the shared volume `ResourceId` is refused, renamed or replaced. Add a
second case: a converged site `preview-notes` in namespace `personal` makes `previewCleanupServices`
refuse the namespace.

Write the observed behavior in the Decision Log. If any durable member can be deleted, moved or
re-bound, record that as data loss: per the release checklist this is then fixed in place rather
than deferred. M2's fix still applies either way.

For exposure, run one read-only listing on the intranet context and check its scope names for
`standalone:site-preview-` scopes that a site compiled rather than a preview. A preview's Service
name contains `-pr-`; a misowned site's scope has the site's own Service name.

M2. In `mkSiteName`, add a guard rejecting a name that begins with `preview-`, with the message
`site name must not begin with "preview-" (reserved for site preview scopes)`. Add cases to the
`mkSiteName` group in `StaticSpec.hs`: one refusing `preview-blog`, and one still accepting
`blog-preview`. Once the guard exists, the M1 tests can no longer build a `preview-*` site, so
change each of them to assert that `mkSiteName` refuses its site name. Before the fix they show the
collision; after it they prove the refusal. Document the reserved prefix in `docs/user/static-hosting.md` where site names are
described.


## Concrete Steps

```bash
nix develop -c cabal test nagare-dsl-test --project-dir=cli/nagare-dsl --test-options='-p mkSiteName' --test-show-details=direct
nix develop -c cabal test nagarectl-test --project-dir=cli/nagarectl --test-options='-p preview' --test-show-details=direct
```

Read-only exposure check, in a clean environment for the intranet context (no mutation):

```bash
nagarectl --context <intranet-context> inventory status --json | grep -o 'standalone:site-preview-[a-z0-9.-]*' | sort -u
```

Every name printed must be a preview scope, of the form `site-preview-<site>-pr-<preview>`, and must
match a preview that `site preview list` shows for that site.

Per Haskell commit, then land:

```bash
just haskell-style-check
just gate-fast
just land
```


## Validation and Acceptance

- Before M2, the collision test shows both deployments targeting the same scope, and the
  `cleanup --previews` case refuses the namespace. After M2, `mkSiteName "preview-blog-pr-x"`
  returns `Left` with the reserved-prefix message, and `mkSiteName "blog-preview"` returns `Right`.
- Loading a static or server site config named `preview-x` fails at load with that message; no
  review is saved and no store is opened.
- The intranet check prints only genuine preview scopes. If it shows a site-owned
  `site-preview-*` scope, stop: M2 would make that site undeployable, so the operator decides first.
- `just gate-fast` is green before landing, and the full gate started by `just land` is green.


## Idempotence and Recovery

The tests use memory stores and the exposure check only reads. The fix is a pure validation change.
Reverting the commit restores the old acceptance. No stored data, scope or identity changes.


## Interfaces and Dependencies

`Nagare.Dsl.Static.Types.mkSiteName :: Text -> Either Text SiteName` keeps its type and gains one
refusal. No new dependency, no store format change, no release transition. Plan 193 (`site list`)
benefits: its `previewOwner`-based classification becomes exact once this lands, but neither plan
blocks the other.
