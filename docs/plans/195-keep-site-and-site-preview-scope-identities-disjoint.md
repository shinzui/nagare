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

No two sites or previews may share an inventory scope. Today four pairs can:

1. **Site and preview.** A site's scope is `standalone:site-<site>` and a preview's is
   `standalone:site-preview-<site>-pr-<preview>`. Site `preview-blog-pr-x` gets the same scope as
   preview `x` of site `blog`.
2. **Previews of different sites.** Preview `c` of site `a-pr-b` and preview `b-pr-c` of site `a` are
   both `a-pr-b-pr-c`.
3. **Previews of one long-named site.** The preview Service name is cut to 63 characters, so for a
   55-character site, previews `feature-login` and `feature-logout` are the same preview.
4. **A site and its own preview.** A 63-character site's previews are all cut back to the site's own
   Service name.

After this change, `nagarectl` refuses three kinds of site name when it loads the site's config:
names that begin with `preview-`, names that contain `-pr-`, and names that end with `-pr`. It also
refuses a preview whose Service name would exceed 63 characters, where it used to cut the name
short. With these rules, every site and preview maps to a distinct scope, Knative Service name and
preview prefix, and both refusals reach the operator as ordinary configuration errors before any
review is saved.


## Progress

- [ ] M1. Severity and real-world exposure are established. Interpreter tests reproduce all four
      collisions and record what the saved review proposes for the first owner's members, especially
      `Retain` volumes. A characterization test shows that preview cleanup refuses, and does not
      select, a scope that a `preview-*` site owns. A read-only check of the intranet context shows
      whether any accepted or retained scope there would be refused by the new rules.
- [ ] M2. `mkSiteName` refuses names that begin with `preview-`, contain `-pr-` or end with `-pr`.
      New `mkSiteName`, `decodeStaticSite` and `decodeServerSite` cases fail before the fix and pass
      after it.
- [ ] M3. `previewServiceName` refuses a Service name over 63 characters instead of cutting it. The
      boundary cases fail before the fix and pass after it. The cleanup characterization test passes
      unchanged. `just haskell-style-check` and `just gate-fast` are green, and M2 and M3 land through
      `just land`.


## Decision Log

2026-10-14: Fix the collisions by refusing names, not by renaming either scope family. Renaming
would change the scope identity of every existing site or preview. Since v0.4.0 that needs a
reviewed release transition (EP-172), which is far more work than a few refusals. The refusals
change no existing identity, provided M1 finds no affected name on the intranet. If M1 finds one,
stop and ask the operator before changing anything.

2026-10-14: Put the site-name refusals in `mkSiteName` (`cli/nagare-dsl/src/Nagare/Dsl/Static/Types.hs`).
Both static and server sites load through it (`Dsl/Load/StaticSite.hs` and
`Dsl/Load/ServerSite.hs`), so a bad name fails at configuration load, before compilation, review
or store access. A check in the scope compiler would come later and in two places.

2026-10-14: Widened by the operator from the site-versus-preview collision to every collision between
site and preview identities (collisions 2–4 in Purpose).

2026-10-14: Make the `-pr-` separator unambiguous by restricting site names, not preview names.
Preview names come from branches and pull requests, and `pr-42` is a natural one. Refusing preview
names that start with `pr-` or contain `-pr-` would hit the common case. Site names are chosen once by
the operator.

2026-10-14: Refuse the overflow inside `previewServiceName`, the single place that derives the name.
Deploy, preview deploy and `site preview delete` all go through it. As a result,
`site preview delete` cannot name an existing cut-short preview. `cleanup --previews` can still
collect one, because it reads Service names from scopes and never calls `previewServiceName`. M1's
exposure check gates this.

2026-10-14: The collision tests are M1 evidence only. After M2 and M3 none of them can be built:
`SiteName` is abstract, and `previewServiceName` refuses the long names. M2 and M3 delete them rather
than keep copies of the refusal tests. The regression is the `mkSiteName`, decoder and
`previewServiceName` cases. The cleanup characterization test builds its scope by hand, needs no
`SiteName`, and stays.


## Context and Orientation

Run commands from the repository root. A *scope* is an independently versioned set of resource
declarations in a context's inventory store, identified by a `ScopeId` made of a kind and a name
(`cli/nagare-dsl/src/Nagare/Resource/Types.hs`). A *resource identity* (`ResourceId`) is minted from
the owning scope, a logical key and a role, and prints as `<kind>:<scope>/<key>/<role>`. Two
compilers build `Standalone` scopes for sites:

- `cli/nagarectl/src/Nagare/Inventory/Site.hs` builds a production site's scope as
  `mkScopeId Standalone ("site-" <> name)`. It holds the Knative Service (key = site name), the
  DomainMappings, a `release-history` ConfigMap and volumes.
- `cli/nagarectl/src/Nagare/Inventory/Site/Preview.hs` builds a preview's scope as
  `mkScopeId Standalone ("site-preview-" <> serviceName)`. It holds the Service (key = preview
  Service name), one DomainMapping and volumes. It has no release history.

Volumes in both are minted by `volumeResourceId` (`cli/nagare-dsl/src/Nagare/Resource/Application.hs`)
from the scope, the volume name and the role `site-pvc`, and claim `nagare-vol-<service>-<volume>`
(`pvcName` in `cli/nagare-dsl/src/Nagare/Dsl/Render.hs`).

`previewServiceName site preview` in `cli/nagarectl/src/Nagare/Static/Preview.hs` is
`site <> "-pr-" <> normalizePreviewName preview`, cut to 63 characters with any trailing hyphen
dropped. `normalizePreviewName` lowercases the name, turns every run of characters outside `a-z0-9`
into one hyphen, and trims hyphens at both ends. `previewDomain` is
`<normalized>.<site>.preview.<base>` and is never cut. `listPreviews` in the same file finds a site's
previews by the Knative Service prefix `<site>-pr-`.

`mkSiteName` currently accepts any 1–63 character DNS label of `a-z`, `0-9` and `-` that does not
start or end with a hyphen.

**What happens on a collision, by deploy order.** The ordinary site deploy reads its accepted release
history first, through `acceptedSiteReleaseLog` in `cli/nagarectl/src/Nagare/Inventory/Site/Release.hs`
(called from `cli/nagarectl/app/Nagare/Cli/Commands/Site.hs`). If the scope exists without a
release history it dies with "accepted site scope lacks release history", so a site deploy onto a
preview's scope is refused. A preview deploy has no such check: it compiles its scope and composes it
with `ReplaceScope`, replacing whatever was accepted there. So each of these deploys reaches the
planner and needs M1's measurement:

- a preview landing on a site's scope (collision 1);
- one preview landing on another's scope (collisions 2 and 3).

In collision 1 the two Services are different identities (keys `preview-blog-pr-x` and `blog-pr-x`).
The volume `data` has the same `ResourceId` but a different claim (`nagare-vol-preview-blog-pr-x-data`
against `nagare-vol-blog-pr-x-data`). In collisions 2 and 3 the volume has the same identity *and*
the same claim when both previews use one namespace: the second preview silently takes over the
first one's volume. Collision 4 is refused at composition because the preview Service has the same
Kubernetes address as the production Service. `validateGraph` in
`cli/nagare-dsl/src/Nagare/Resource/Inventory.hs` reports "claim-conflict", so it fails closed, but no
preview of that site can ever be deployed.

**Why the new rules are enough.** Let `s` be a site name that does not contain `-pr-` and does not end
with `-pr`, let `n` be a normalized preview name, and let `w = s <> "-pr-" <> n` with no cutting.
The first `-pr-` in `w` starts exactly at the end of `s`:

- none lies inside `s`;
- one starting 1, 2 or 3 characters before the end of `s` would need `s` to end with `-`, with `-p`
  followed by `-p` (which is not `r-`), or with `-pr`, and `mkSiteName` refuses each of these.

So `w` determines `s` and `n`, and two different (site, preview) pairs never share a preview Service
name or scope. A site scope `site-<s>` equals a preview scope `site-preview-<w>` only if `s` begins with
`preview-`, which is refused. A site's Service `s` equals a preview's Service `w` only if `s` contains
`-pr-`, which is refused. For the same reason the prefix test `<site>-pr-` in `listPreviews` matches
only that site's previews.

**Misclassification by `previewOwner`.** `previewOwner` in
`cli/nagarectl/src/Nagare/Inventory/PreviewCleanup.hs` is a pure prefix test: `Standalone`, with a
name starting `site-preview-`. For a site named `preview-*` in the cleanup namespace, cleanup fails
closed:

- `previewCleanupServices` selects the site's Service and then fails the exact check in
  `sitePreviewRetirementScope` (`cli/nagarectl/src/Nagare/Inventory/PreviewOwnership.hs`). For a
  site's Service `preview-notes`, that check derives the owner `site-preview-preview-notes`, not the
  actual `site-preview-notes`. `nagarectl cleanup --previews` therefore refuses for the namespace.
- After the site is retired, `eligiblePreviewCollections` also refuses for the namespace. It never
  selects the site's members, because its `validateOriginal` re-runs `previewCleanupServices` on each
  retained owner's original scope, which fails as above. Separately, `supportsRetainedCollection`
  (`cli/nagarectl/src/Nagare/Inventory/CollectionPolicy.hs`) never offers a `Retain`/`Durable` volume.

Misclassification is therefore a refusal, not a deletion path. The command in plan 193 (`site list`)
would also report such a site as a preview.

**Where the rules apply.** `mkSiteName` is called only by the two loaders, `decodeStaticSite` and
`decodeServerSite`, and each wraps a refusal as `MarshalError "name"`. Every `nagarectl site` command
loads the site config first. `previewServiceName` is called by the preview renderers
(`cli/nagarectl/src/Nagare/Static/Deploy.hs` and `cli/nagarectl/src/Nagare/Server/Deploy.hs`) and by
the preview deploy, server preview deploy and preview delete commands in
`cli/nagarectl/app/Nagare/Cli/Commands/Site.hs`.

Relevant ADRs: [ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md)
makes scopes independent, typed ownership boundaries, which these collisions break.
[ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md) requires the
defects to be shown in interpreter tests, not native runs. No ADR change is needed.

Existing tests to extend:

- the `mkSiteName` group in `cli/nagare-dsl/test/StaticSpec.hs`;
- the `decodeStaticSite failure modes` group in the same file, and `decodeServerSite failure modes`
  in `cli/nagare-dsl/test/ServerSpec.hs`;
- the `previewServiceName` cases in `cli/nagarectl/test/Nagare/Test/Static.hs`, including
  "previewServiceName clips to 63 chars without trailing hyphen", which M3 replaces;
- the hand-built preview scopes in `cli/nagarectl/test/InventoryPreviewCleanupSpec.hs`, which
  already test `previewCleanupServices`;
- the preview compile fixture in `cli/nagarectl/test/Nagare/Test/SiteInventory/Preview.hs`. It has
  only a compile test. For deploying against a store, copy the `newMemoryStore`, `initializeStore`,
  `composeInventory … (ReplaceScope …)`, `publishReview` sequence in
  `cli/nagarectl/test/AppDeploySpec.hs`, with observations from the fake adapters in
  `cli/nagarectl/test/Nagare/Test/Effectful/Fixture.hs`.


## Plan of Work

M1. In `cli/nagarectl/test/Nagare/Test/SiteInventory/Preview.hs`, add one interpreter test per
collision, each with a name containing `preview`. In each, both owners declare a `Retain` volume
`data`, the first owner is accepted against a memory store, and the second is planned on top:

1. Preview `x` of site `blog` is accepted. Then site `preview-blog-pr-x` is checked with
   `acceptedSiteReleaseLog`: assert it refuses with "accepted site scope lacks release history".
   Then do the reverse: site `preview-blog-pr-x` is accepted and preview `x` of `blog` is planned.
2. Preview `c` of site `a-pr-b` is accepted, then preview `b-pr-c` of site `a` is planned, both in
   namespace `personal`. First assert that both names give `a-pr-b-pr-c`.
3. For a 55-character site, preview `feature-login` is accepted, then preview `feature-logout` is
   planned. First assert that `previewServiceName` gives both the same name.
4. For a 63-character site, assert that `previewServiceName` gives the site's own name. Composing
   the preview next to the accepted site must fail with `claim-conflict`.

`SiteName` is abstract, so sites are built through `mkSiteName`, which accepts these names until M2.
For each planned case, assert what the saved review proposes for the first owner's Service,
DomainMapping and volume: whether the volume's `ResourceId` is refused, re-bound to another claim or
silently taken over.

In `cli/nagarectl/test/InventoryPreviewCleanupSpec.hs`, add a characterization case. Build by hand a
scope `standalone:site-preview-notes` holding a site-shaped Service `preview-notes` in namespace
`personal`, one DomainMapping and the release-history ConfigMap. Assert that
`previewCleanupServices "personal"` returns `Left`, and that `eligiblePreviewCollections` returns
`Left` when that scope is a retained owner. The case passes before and after the fix, which changes
no cleanup code. It pins the fail-closed behavior that keeps misclassification harmless.

Write the observed behavior in the Decision Log. A durable member that can be deleted, re-bound or
taken over by another owner is data loss, and per the release checklist it is fixed now rather than
deferred. M2 and M3 close these routes to it. If the planner would re-bind or hand over a `Retain`
volume identity by any other route, that is a separate planner defect. Stop and ask the operator
before widening this plan to cover it.

For exposure, run the read-only check in Concrete Steps on the intranet context. It looks for three
things:

- **A preview-family scope that a site compiled.** A scope `site-preview-S` was compiled by a preview
  exactly when it holds the Service identity `standalone:site-preview-S/S/service`. A site named
  `preview-S` mints `standalone:site-preview-S/preview-S/service` instead. Name heuristics cannot
  tell them apart, and neither can `site preview list`, which is itself a prefix filter.
- **A site name that M2 refuses.**
- **A preview Service name of 62 or 63 characters**, which may have been cut short.

M2. In `mkSiteName`, add two guards:

- A name beginning with `preview-` is refused with
  `site name must not begin with "preview-" (reserved for site preview scopes)`.
- A name containing `-pr-` or ending with `-pr` is refused with
  `site name must not contain "-pr-" or end with "-pr" (reserved as the site preview separator)`.

Add cases to the `mkSiteName` group in `StaticSpec.hs`:

- refusing `preview-blog-pr-x`, `a-pr-b` and `blog-pr`;
- still accepting `blog-preview`, `preview`, `pr-tools` and `blog-prod`.

Add a case to each decoder failure group: a site JSON named `preview-x` gives
`Left (MarshalError "name" …)` from `decodeStaticSite` and from `decodeServerSite`. Delete collision
tests 1 and 2, which can no longer build their sites. Document both rules in the `name` row of the
site field table in `docs/user/static-hosting.md` (currently "DNS-label site name (also the Knative
Service name)").

M3. In `previewServiceName`, replace the cut with a refusal when `site <> "-pr-" <> normalized` is
longer than 63 characters. Use the message
`preview name too long: "<site>-pr-<normalized>" is <n> characters, max 63 (at most <63 - length site - 4> characters for site <site>)`.
For a site of 59 or more characters, the bound in parentheses is zero or less, so the message says
instead that the site name leaves no room for a preview. Drop `dropTrailingHyphen`: the uncut name ends with the normalized name, which never ends in a hyphen.
In `cli/nagarectl/test/Nagare/Test/Static.hs`, replace the clip test with two cases. A preview name
that makes the Service exactly 63 characters is accepted, and one that makes it 64 is refused. Delete
collision tests 3 and 4. In `docs/user/static-hosting.md`, where it says a preview becomes a Knative
Service named `<site>-pr-<name>`, add that the whole name must fit in 63 characters, and that a site
of 59 or more characters therefore cannot have previews.


## Concrete Steps

```bash
nix develop -c cabal test nagare-dsl-test --project-dir=cli/nagare-dsl --test-options='-p mkSiteName' --test-show-details=direct
nix develop -c cabal test nagare-dsl-test --project-dir=cli/nagare-dsl --test-options='-p decode' --test-show-details=direct
nix develop -c cabal test nagarectl-test --project-dir=cli/nagarectl --test-options='-p preview' --test-show-details=direct
```

Read-only exposure check on the intranet context, run in a clean environment (`env -i` plus
`nagarectl context env`, from the `mori://tan/tan-ng-labs` checkout that operates it). Nothing here
mutates. `inventory status --json` prints scopes as objects (`{"kind":"Standalone","name":"…"}`),
not as `standalone:…` strings, so read them with `jq`:

```bash
ctx=<intranet-context>
nagarectl --context "$ctx" inventory status --json > status.json
jq -r '[.accepted[].scope, .retained[].owner] | unique | .[] | select(.kind == "Standalone") | .name' status.json > owners.txt
grep '^site-preview-' owners.txt | while read -r scope; do
  key=${scope#site-preview-}
  nagarectl --context "$ctx" inventory explain "standalone:$scope/$key/service" --json > /dev/null \
    || echo "NOT-A-PREVIEW: $scope"
  [ "${#key}" -ge 62 ] && echo "MAYBE-CUT: $scope"
done
grep '^site-' owners.txt | grep -v '^site-preview-' | sed 's/^site-//' \
  | grep -E -e '-pr-' -e '-pr$' | sed 's/^/REFUSED-SITE: /'
```

The check must print nothing. A `NOT-A-PREVIEW:` line for a scope that has only retained members can
be a retired preview whose Service was already collected. Inspect it with
`jq '.retained[] | select(.owner.name == "<scope>")' status.json`. A site-owned scope names a Service
`preview-…` or a claim `nagare-vol-preview-…`. A preview names `<site>-pr-…` and
`nagare-vol-<site>-pr-…`. For a `MAYBE-CUT:` line, compare the Service name with its DomainMapping
host `<preview>.<site>.preview.<base>`, which is never cut.

Per Haskell commit, then land:

```bash
just haskell-style-check
just gate-fast
just land
```


## Validation and Acceptance

- Before the fix:
  - collision test 1 shows the site deploy refused by its release-history check, and the reverse
    order reaching the planner;
  - tests 2 and 3 show two previews deriving one Service name and scope;
  - test 4 shows `claim-conflict`;
  - each planned case records the review's proposal for the first owner's volume.
- The cleanup characterization test shows both cleanup functions returning `Left` for a site-owned
  `site-preview-*` scope, before and after the fix.
- After M2, `mkSiteName` returns `Left` for `preview-blog-pr-x`, `a-pr-b` and `blog-pr` with the
  matching message, and `Right` for `blog-preview`, `preview`, `pr-tools` and `blog-prod`.
  `decodeStaticSite` and `decodeServerSite` of a site named `preview-x` return
  `Left (MarshalError "name" …)`. Every `nagarectl site` command decodes its config before opening
  a store, so no review is saved.
- After M3, `previewServiceName` accepts a 63-character result and refuses a 64-character one with
  the length message. No preview name is ever cut.
- The intranet check prints nothing. If it prints a site-owned scope or a refused site name, stop:
  M2 would make that site's config unloadable, so it could no longer be deployed or rolled back
  through `nagarectl site`. If it prints a cut-short preview, stop: after M3 that preview cannot be
  redeployed or deleted by name. The operator decides first in both cases.
- `just gate-fast` is green before landing, and the full gate started by `just land` is green.


## Idempotence and Recovery

The tests use memory stores and the exposure check only reads. The fix only adds validation.
Reverting the commits restores the old acceptance. No stored data, scope or identity changes.


## Interfaces and Dependencies

`Nagare.Dsl.Static.Types.mkSiteName :: Text -> Either Text SiteName` keeps its type and gains two
refusals. `Nagare.Static.Preview.previewServiceName :: Text -> Text -> Either Text Text` keeps its
type, and its truncation becomes a refusal. There is no new dependency, no store format change and
no release transition. Plan 193 (`site list`) benefits: its `previewOwner`-based classification
becomes exact once this lands, but neither plan blocks the other.
