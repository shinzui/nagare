---
id: 186
slug: protect-nagare-sites-with-explicit-user-and-team-grants
title: "Protect Nagare sites with explicit user and team grants"
kind: exec-plan
created_at: 2026-10-12T14:57:49Z
intention: "intention_01m4r9rcpfem1997x5e75zc0zb"
master_plan: "docs/masterplans/27-protect-every-nagare-site-with-explicit-user-and-team-access.md"
provenance:
  created_by:
    model: "gpt-6.1-sol"
    harness: "codex-cli"
    at: 2026-10-12T14:57:49Z
  revisions:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-12T15:08:55Z
      mode: "other"
      note: "Ground user-selected site and team access scope in source research and MasterPlan decomposition"
---

# Protect Nagare sites with explicit user and team grants

This living ExecPlan is the site-protection foundation. Team relationship mutation is owned by `docs/plans/187-manage-reviewed-team-membership-and-site-access-grants.md`; this child first makes existing individual grants usable across all web workload kinds. This planning session implements no code.


## Purpose / Big Picture

An operator can opt a StaticSite or ServerSite into the same protection already available for Deployment and Application. A signed-in user with no grant receives 403; a user explicitly granted that hostname reaches the site. The origin and preview routes cannot become public alternatives to the protected hostname. Completion gives the following team-grant child one shared protected-host contract.


## Progress

- [ ] M1: Protected-site policy survives typed-config serialization and a representative private-route/enforcer interaction.
- [ ] M2: Production, alias, preview, and rollback routes enforce the selected policy without an origin bypass.
- [ ] M3: Freshness, unsupported-policy refusal, lifecycle recovery, and compatibility are verified through public loaders and focused tests.


## Surprises & Discoveries

(None during implementation yet.)


## Decision Log

Decision (2026-10-12): Use the existing opt-in `access = Just requireLogin` contract on every web workload kind; it means authentication plus an explicit En grant. Team schema and membership writes remain in EP-187.

Decision (2026-10-12): Preserve public defaults, `app:<hostname>#access`, and the existing portal exception. Each alias and preview hostname requires its own grant. No automatic production-to-preview authorization inheritance is introduced.


## Outcomes & Retrospective

(To be filled during implementation and at completion.)


## Context and Orientation

Work from the Nagare repository root. A Deployment is a typed web-service configuration; an Application groups a web service with other components. Their access fields are in `cli/nagare-dsl/src/Nagare/Dsl/Types.hs` and `Application.hs`. Dedicated site kinds use `cli/nagare-dsl/src/Nagare/Dsl/Static/Types.hs` and `Server/Types.hs`, neither of which currently has access. `Config.hs` serializes them; `Load/StaticSite.hs`, `Load/ServerSite.hs`, and `Load/Fields.hs` decode and validate them. A DomainMapping is Knative's hostname-to-service route.

`cli/nagarectl/src/Nagare/Inventory/Application/Service.hs` already composes protected DomainMappings in `nagare-system`, records `RegisterBackend` contributions, and marks the origin Service cluster-local. `cli/nagarectl/src/Nagare/Inventory/BackendMap.hs` combines contributions into `nagare-access-backends`. Dedicated sites instead use `cli/nagarectl/src/Nagare/Inventory/Site.hs` and `cli/nagarectl/app/Nagare/Cli/Commands/Site.hs`, with production, preview, and rollback paths. These must use the same protection path. `cli/nagare-access/src/Nagare/Access/App.hs` authenticates and checks each protected host before proxying; `En.hs` asks permission `access`; `DecisionCache.hs` caches subject/host decisions; `Shomei.hs` retains the verified JWT subject only.

Authentication proves who is calling. Authorization is a separate yes/no check on a particular resource. The baseline tuple, a stored relationship fact, is `app:<host>#viewer@user:<id>`. En grants `access` from viewer. The user ID is the exact TypeID text in verified Shomei `sub`, never an email or bare UUID. Source APIs are in `mori://shinzui/shomei/packages/shomei-core` and `mori://shinzui/en/packages/en-client`; locate them with Mori before coding. Current pins are Shomei `6a96185f4f809e5e7a99095274caa6bd90e7a8d7` and En `054afaddfc8a1eb631373f6cdd8bfd1f1c8c9634` in `cli/nagare-access/cabal.project`; no upgrade is required by this child.

[ADR 15](../adr/0015-the-auth-portal-hands-sessions-to-nagare-access-through-response-headers.md) keeps the portal public enough for login and keeps session authority at the enforcer. [ADR 20](../adr/0020-domain-routing-and-tls-ownership-are-explicit.md) requires explicit domain claims. [ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md), Decision section, requires shared resource owners to compose consumer contributions and forbids unreviewed changes. [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md) requires interpreter failure coverage before native route changes. There is no existing local ADR defining team-based site access. Preserve auth image pins and upstream migration ownership under [ADR 1](../adr/0001-auth-plane-images-mirror-upstream-dependency-plans.md) and [ADR 2](../adr/0002-auth-service-images-own-and-apply-their-database-schemas.md).


## Plan of Work

### M1: One common private-site contract

Add `access :: Maybe AccessPolicy` to StaticSite and ServerSite. Update every record constructor, preset, fixture, and example. Missing JSON access decodes as public for compatibility; protected policies round-trip through `Config.hs` and the site loaders. Reuse the Access policy loader. Dedicated site kinds accept ProtectedSite only; AuthPortal remains an Application/Deployment role. Accept permission `access` and audience `Nothing` only; reject other permissions or explicitly supplied audiences with a precise planning error rather than silently ignoring them. `Nothing` selects the shared cluster audience. Apply the same refusal to service/application deploys. Do not invent a per-site JWT audience or custom permission feature in this work.

Extract the private Service transformation and protected DomainMapping/backend contribution composition from `Inventory/Application/Service.hs` into a shared module, proposed `cli/nagarectl/src/Nagare/Inventory/ProtectedRoute.hs`. It takes validated auth-owner bindings, an origin Service, normalized host declarations, and source location, and returns private origin bytes, protected route declarations, and backend contributions. It does not write Kubernetes or En. Add a representative test spanning config emission, site loading, composition, and `appWithRuntime` with a signed-in subject and a denied authorizer. It returns 403 and records no upstream request. This early interaction must pass before adding all site lifecycle variants.

### M2: Protected production and preview lifecycles

Integrate the shared route builder into `Inventory/Site.hs`, Commands/Site.hs, and the static/server deployment preparation paths they call. Resolve the accepted auth owner before planning. Make every protected origin cluster-local, and route only through the enforcer. Protect default domains and all declared aliases. A generated preview host inherits the production configuration's protected/public policy, but remains an independent `app:<preview-host>` authorization object. Require explicit preview grants; never fall back to a public preview route. Rollback changes the site's image while retaining its currently reviewed protection policy, rather than resurrecting older public routing from release history.

Refuse protection when auth bindings are missing or conflict with a route owner. Refuse protected sites with CDN intent or unsupported supplied origin-TLS modes until those paths can preserve identity checks and prevent shared-cache leaks; do not silently drop CDN settings. A transition from a currently CDN-served public site requires an explicit reviewed CDN retirement/drain procedure and private-route transition, not merely a new protected ConfigMap. Existing direct DomainMappings cannot be overwritten by name: use the repository's explicit reviewed ownership transition, or refuse with the required next action. Preserve old public configs, and ensure retirement/collection cannot leave a publicly reachable protected origin. Complete the production/preview/rollback interpreter tests through public review loaders.

### M3: Bounded revocation and compatibility

Change `Nagare.Access.En.buildCheckRequest` to FullyConsistent on gateway cache misses. Keep subject/host cache keys because this child has one permission and no path/context variants. Keep `NAGARE_ACCESS_DECISION_TTL`: default 30 seconds, zero disables the gateway cache. Denied and Conditional never proxy; unavailable results return 503 and are not cached. Prove grants and revokes become observable after at most that TTL, with an injected clock and no sleeps. Do not promise a fresh answer from a cached Allowed entry during an En outage.

Extend focused tests in `cli/nagare-dsl/test`, `cli/nagarectl/test/Nagare/Test/SiteInventory.hs`, `cli/nagarectl/test/InventoryAccessSpec.hs`, `AccessResolveSpec.hs`, and `cli/nagare-access/test/Spec.hs`. Cover missing auth, conflicting host claims, unrelated accepted contributors, public-to-protected transition refusal/recovery, lost Kubernetes acknowledgement, unready rollout, renamed/replaced origins, private previews, protected rollback, portal behavior, and malformed config. Preserve legacy direct-user wire values. Document the custom-policy refusals and the 30-second bound in `docs/user/access.md`.


## Concrete Steps

All commands start at the Nagare repository root. Discover source files through Mori, then locate all site constructors before changing records:

```bash
mori registry show shinzui/shomei --full
mori registry show shinzui/en --full
mori path mori://shinzui/en/packages/en-client
rg -n 'StaticSite|ServerSite|RegisterBackend|privateService' cli cluster/examples
```

Run the DSL and gateway suites at coherent milestones. Expected result is all selected tests passing, including the new denied-site test; a route-only test is insufficient.

```bash
cabal test --project-dir=cli/nagare-dsl --test-show-details=direct
cabal test nagare-access-test --project-dir=cli/nagare-access --test-show-details=direct
```

Run heavy CLI tests on the repository's remote test runner at a committed revision, as the justfile requires. The following pattern runs the site/access groups whose labels contain either term; inspect Tasty labels and adjust the pattern if necessary, recording the exact selection in Progress.

```bash
just test-remote HEAD '/site/ || /access/' '0/1'
just gate-fast
```

A future implementation commit includes Conventional Commit syntax and trailers for this plan, `docs/masterplans/27-protect-every-nagare-site-with-explicit-user-and-team-access.md`, and the frontmatter intention. Do not deploy in the planning session. Before any implementation native drill, obtain the required green committed-candidate gate record and follow `docs/runbooks/before-a-native-run.md`.


## Validation and Acceptance

Use two protected hosts A and B, two users Alice and Bob, and one explicit direct grant Alice→A. Alice receives 200 from A and 403 from B; Bob receives 403 from both. Anonymous browser requests redirect to login; anonymous API requests return 401. An En error with an empty gateway cache yields 503 and no upstream call. The origin's generated public Knative hostname returns no app content from outside the cluster. Every alternate domain and preview remains denied without its own grant.

A public old-style StaticSite/ServerSite JSON config still loads and plans public routing. A protected config survives JSON emission/loading and reviews a private origin and enforcer route. Configuring unsupported permission/audience, CDN, or portal role fails with no plan write or native mutation. Missing auth fails before route mutation. Repeated deployment composes the same backend map, rollback preserves protection, and retirement has a tested reviewed exit. These are required acceptance, not optional future scope.


## Idempotence and Recovery

Use existing inventory IDs and journaled Kubernetes mutations. Repeated planning must not duplicate routes, contributions, or resource IDs. Update shared ConfigMaps only from the auth owner's complete accepted contributions. Resume the original transaction after an uncertain acknowledgement; do not replay name-based route rewrites. A failed or unready rollout leaves the origin private and the review recoverable. Reverting image changes does not turn a private route public. Public-to-private transitions with existing direct/CDN routes refuse until their ownership and cache exposure are handled by a saved review. No SQL or identity-database reset is part of this child.


## Interfaces and Dependencies

There is no hard child prerequisite. The exported contract is a protected route for each normalized hostname, with a cluster-local origin, accepted auth-owner dependency, and `RegisterBackend` contribution. Policy values are default `access` and cluster audience only. Existing portal semantics and direct-user tuple identity remain unchanged. EP-187 consumes that contract for team grants; EP-188 checks it through public commands and HTTP. Any dependency update must reverify the authoritative registry, upstream tags, and both image dependency plans under ADR 1 before selecting a new pin.
