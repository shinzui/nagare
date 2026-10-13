---
id: 27
slug: protect-every-nagare-site-with-explicit-user-and-team-access
title: "Protect every Nagare site with explicit user and team access"
kind: master-plan
created_at: 2026-10-12T14:58:31Z
intention: "intention_01m4r9rcpfem1997x5e75zc0zb"
provenance:
  created_by:
    model: "gpt-6.1-sol"
    harness: "codex-cli"
    at: 2026-10-12T14:58:31Z
  revisions:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-12T15:08:55Z
      mode: "other"
      note: "Ground user-selected site and team access scope in source research and MasterPlan decomposition"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-12T15:28:33Z
      mode: "update"
      note: "Validate APIs, upgrade latest En/Shomei prerequisite, and limit performance checks to concrete risks"
---

# Protect every Nagare site with explicit user and team access

This MasterPlan coordinates implementation; the registry owns child status. Its living sections must be updated as work proceeds. This update validates the APIs and performance assumptions. The user additionally authorized upgrading Nagare to the latest upstream En and Shomei; site/team implementation remains separate.


## Vision & Scope

An operator can make a Nagare site private, grant an individual or a named team access to that exact hostname, and check whether a particular user has effective access. Signing in establishes identity; it never grants access to a protected site by itself. A grant for site A does not grant site B. Removing the last applicable direct or team relationship removes access within the documented decision-cache interval.

The selected scope, confirmed by the user on 2026-10-12, is site access for users and teams. It covers web-facing Deployment and Application configurations and the dedicated StaticSite and ServerSite kinds, including preview routing and rollback. Existing configurations remain public unless they explicitly opt into protection. The initiative makes protection available to every site kind; it does not silently convert every existing site to private. Each hostname is an independent authorization object, including aliases and preview hosts. Public access is explicit in documentation and review output. A site with protection configured and no grants denies every signed-in user.

The initial protected-site permission remains `access`. Teams are En groups with explicit user membership; they are not global Shomei roles. Team access is one relationship on one site. There is no implicit administrator bypass. Platform operators retain the separate authority to manage reviewed grants; a viewer cannot issue grants through the site. Nested groups, invitations, self-service sharing, delegated site administration, per-path rules, per-method rules, machine access, MFA step-up, expiring shares, and application data permissions are outside this implementation scope.

### Research and options

Research used Mori's registered sources for `mori://shinzui/shomei`, `mori://shinzui/en`, and `mori://shinzui/shomei-docs`. `mori registry docs` currently reports no curated guides for the first two projects; guides were read directly from their registered checkouts. Shomei's project-relative `docs/user/authorization.md` and `docs/user/security.md` explain the two-tier model; those guide artifact URIs are pending. En's project-relative `docs/user/modeling.md`, `docs/user/space-page-sharing.md`, and `docs/user/service-and-operations.md` supply relationship, group, query, and operational examples; those guide artifact URIs are pending. The package sources are `mori://shinzui/shomei/packages/shomei-core`, `mori://shinzui/shomei/packages/shomei-servant`, `mori://shinzui/en/packages/en-core`, `mori://shinzui/en/packages/en-servant`, and `mori://shinzui/en/packages/en-server`.

Option 1 is individual host grants only. This already exists for protected Deployment/Application web services: Nagare asks En whether `user:<verified JWT sub>` has `access` on `app:<host>`, and CLI grant/revoke manage `app:<host>#viewer@user:<id>`. It is suitable for a small number of people but requires repeated grants as teams change. Dedicated StaticSite and ServerSite configurations currently lack the access field. Extending that coverage alone is the smallest viable improvement.

Option 2 is host grants for individuals and teams. An En group stores members, and a site's viewer relationship can reference that group's members. A team can receive access to several selected sites without gaining every site. Removing a membership affects every grant made through that team. This is the selected option: it extends Nagare's existing decision engine and keeps changing site grants out of login tokens. Team membership needs an explicitly owned, reviewed write path; En is an authorization graph, not a complete group-directory product.

Option 3 is Shomei role or permission gates. Shomei has declared roles, role-to-permission mappings, time-bound role grants, and verified token claims. They suit coarse global gates such as support or paid membership. They could gate a small number of named sites, but claims remain frozen until token mint/expiry (default access-token lifetime documented as 15 minutes), and growing per-site claims creates token-size and lifecycle problems. Nagare currently retains only the verified subject, discarding role/permission claims. This option requires new enforcement plumbing and is not selected for resource-scoped site access. Shomei roles are not automatically synchronized into En.

Option 4 is En-backed path and HTTP-method protection. For example, `/admin` could require a stronger permission than `/`. En can evaluate the permission; Nagare must choose it reliably from a request. This requires path normalization, deterministic rule precedence, reserved auth-route treatment, method handling, policy-aware cache keys, and reviewable default-deny behavior. It remains a possible later initiative. A gateway cannot infer record-level authorization from paths alone.

Option 5 is application-level En authorization. An application checks permissions such as edit on a specific document, uses lookup to filter lists, and owns the corresponding relationship writes. This is appropriate for data and actions inside a site, but requires application integration and is additional to host protection. The En sharing guide demonstrates group membership, resource inheritance, and permission checks; it does not make these Nagare features automatic.

En also supports bounded request conditions, called caveats, and optional Biscuit decision tokens. Current source has a generic predicate evaluator, although portions of the modeling guide still describe the older `within_autonomy` evaluator. Caveats need trusted request context and caches that account for time and context; Biscuit tokens need explicit expiry and revocation semantics. Neither is required for selected user/team host grants.

### Version evidence and reproducibility

On 2026-10-12, Nagare HEAD was `9200626d1a3c2b0fa66b7a0f5e3114f89903a811`. `cli/nagare-access/cabal.project` pins Shomei `6a96185f4f809e5e7a99095274caa6bd90e7a8d7` and En `054afaddfc8a1eb631373f6cdd8bfd1f1c8c9634`. The registered checkout heads were Shomei `0eedad1328a910b457f86bc79bc42024aca33a20` and En `c3ee100a0b2cc63a50a9473ef590de7086dca4d0`; checkout HEAD is not proof of the deployed version. En userset subjects, the text-schema parser, bounded caveat types, and schema API were also inspected at Nagare's pinned commit.

The authoritative Hackage preferred-version endpoint returned `{"normal-version":["0.2.0.0"]}` for shomei-core. Upstream GitHub releases and remote tags show the Shomei 2026-08-27 release at the pinned `6a96185...` commit. The en-core Hackage endpoint returned HTTP 404, upstream En releases returned an empty array, and `git ls-remote --tags` returned no En tags. En's local Cabal version `0.1.0.0` therefore must not be represented as a published release. That was the initial research baseline; the subsequent user-authorized upgrade below supersedes the no-upgrade assumption. Recheck registries and upstream tags before any later pin change. Authoritative release listings are https://github.com/shinzui/shomei/releases and https://github.com/shinzui/en/releases, for the canonical projects named above.


### API and performance validation (2026-10-12)

The user requested current upstream En and Shomei after validation found an API-version mismatch. Remote HEAD verification selects En `c3ee100a0b2cc63a50a9473ef590de7086dca4d0` and Shomei `0eedad1328a910b457f86bc79bc42024aca33a20`. Hackage still lists shomei-core 0.2.0.0, matching the older release tag; En has no published release/tag. These are deliberately pinned upstream commits, not claims of newer published package releases. Keep the library and all three auth-image builders on the same revisions.

Nagare's reviewed grant adapter already sends Relay `first=2` and decodes `edges/pageInfo`, while its previous En pin expected a body `limit/cursor` and returned `relationships/state`. Current En supports Relay relationship pagination. Upgrade the dependency and validate that existing transport against the real new handler; do not regress Nagare to the old API. En's new response API also uses Problem Details, adds `EnInternal`, and carries optional `grantGeneration`; every error remains unavailable to the gateway. The upgraded En includes its own grant-generation database migration, applied by Nagare's existing upstream migration Job before the new server. Shomei's update changes migration-library/test-support dependencies without changing the JWT verification interface.

The user explicitly declined a general load-test program. Two concrete cost concerns remain: `DecisionCache.writeCache` scans the full map at each insertion and has no live-entry capacity; En's `Check` can drain attached team memberships for a denied subject. EP-186 adds a focused cache-cost check; EP-187 records tuple reads for representative allowed and denied flat-team checks. Neither page size nor recursion depth bounds total graph breadth. Use those observations to justify a small fix or an upstream issue; do not add speculative throttling, metrics infrastructure, broad benchmarks, or latency SLAs. Existing pooled HTTP and local JWT verification remain appropriate.

Source evidence is in Nagare's `AccessRuntime.hs`, `Access/Grants.hs`, `DecisionCache.hs`, and, in `mori://shinzui/en`, project-relative `en-servant/src/En/Tuple/Api.hs`, `en-servant/src/En/Check/Api.hs`, `en-servant/src/En/Servant/Response.hs`, `en-core/src/En/Check.hs`, and `en-core/src/En/Budget.hs` (file-level URIs pending). All four plans were authored by `gpt-6.1-sol` and had no recorded reviews before this update. API/source validation is not a claim of measured production performance.


## Decomposition Strategy

Three work streams preserve clear outcomes. EP-186 first upgrades the shared auth dependencies (M0), then closes protection coverage and routing holes using existing individual grants. EP-187 adds owned team memberships and team-to-site grants, with exact relationship recovery. EP-188 adds effective-access diagnostics and verifies the combined behavior through public commands and the HTTP enforcer. Separate plans avoid mixing site routing with a new tuple lifecycle and keep integration evidence distinct from implementation progress.

Relevant local architectural context is [ADR 1](../adr/0001-auth-plane-images-mirror-upstream-dependency-plans.md), which requires exact auth dependency pins and image-plan parity; [ADR 2](../adr/0002-auth-service-images-own-and-apply-their-database-schemas.md), which reserves database migrations to the upstream services; [ADR 15](../adr/0015-the-auth-portal-hands-sessions-to-nagare-access-through-response-headers.md), which keeps session authority in the enforcer and the portal distinct from protected content; [ADR 20](../adr/0020-domain-routing-and-tls-ownership-are-explicit.md), which makes hostname claims and routing ownership explicit; [ADR 22](../adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md), whose Decision section requires owned declarations and guarded, journaled effects; and [ADR 25](../adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md), which requires adversarial interpreter verification before native operations. Cross-repository ADR discovery also found and inspected [Shomei ADR-1](mori://shinzui/shomei/okf/adrs/concepts/ADR-1): interactive, machine, and delegated sessions retain provenance, and only a live interactive session may mint an OAuth authorization code. Preserve that authentication boundary; it does not substitute for a site grant. The 2026-10-12 amendment to ADR 22 records the selected user/team and API contracts; implementation adds acceptance evidence there. Do not change upstream-owned database schemas to store Nagare groups.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|---|---|---|---|---|
| 186 | Protect Nagare sites with explicit user and team grants (site protection foundation) | [EP-186](../plans/186-protect-nagare-sites-with-explicit-user-and-team-grants.md) | None | None | Complete |
| 187 | Manage reviewed team membership and site access grants | [EP-187](../plans/187-manage-reviewed-team-membership-and-site-access-grants.md) | EP-186 | None | Complete |
| 188 | Check effective site access and verify user and team isolation | [EP-188](../plans/188-check-effective-site-access-and-verify-user-and-team-isolation.md) | EP-186, EP-187 | None | Not Started |

The numbers identify actual child documents. Whole-child hard dependencies require all milestones and acceptance in the prerequisite to be complete.


## Dependency Graph

Implement EP-186, then EP-187, then EP-188. EP-187 needs accepted private routes for StaticSite and ServerSite and the common host authorization contract. EP-188 needs both private routing and usable team mutations to compare effective checks against HTTP behavior. There is no interleaved milestone sequence or implied permission to skip acceptance. Research and test design may proceed independently, but implementation follows this ordering.


## Integration Points

EP-186 owns the protected-host contract in `cli/nagare-dsl/src/Nagare/Dsl/Access.hs`, access fields in the site types, and shared private route composition in `cli/nagarectl/src/Nagare/Inventory/Site.hs` and `cli/nagarectl/src/Nagare/Inventory/Application/Service.hs`. It keeps the authorization object `app:<normalized hostname>` and permission `access`. EP-187 consumes those route claims rather than inventing a second site identifier. Preview hosts and alternate domains have separate grants.

EP-186 owns the shared En/Shomei pins, image-source parity, and gateway compatibility in M0. EP-187 extends the existing CLI wire boundary and reviewed transport for teams and stored-relationship listing; EP-188 consumes it for checks. All three verify against the same selected En API. EP-187 owns the additive En schema in `cluster/bootstrap/en/configmap.yaml`, typed team subjects and relationship addresses in `cli/nagare-dsl/src/Nagare/Resource/Types.hs`, `Inventory.hs`, and `Wire.hs`, and their guarded transport in `cli/nagarectl/src/Nagare/Inventory/Access.hs` and `AccessRuntime.hs`. Existing direct-user claim encodings and identities remain readable. EP-188 consumes the same exact relationship representation for diagnostics; effective access is an En check, not an inference from a flattened list.

EP-186 owns enforcer decision freshness: query En fully consistently on cache misses, retaining the configurable gateway decision TTL (`NAGARE_ACCESS_DECISION_TTL`, default 30 seconds, zero disables). That bounds revocation staleness to the gateway cache rather than adding an unspecified optimized-revision lag. This is a planned behavior change, not a claim about current behavior. EP-186 tests expiry with a monotonic injected clock, anchored to check start, including delayed completions and concurrent misses. EP-188 proves the bound with a representative native transcript. The bound governs new proxy admissions, not disconnecting established streams. All outcomes other than Allowed refuse proxying; unavailable answers yield 503, are not cached, and never grant access.

EP-187 extends `cli/nagarectl/app/Nagare/Cli/Parser/Access.hs` and `Commands/Access.hs` with team membership and group grants. EP-188 adds the read-only check command there after EP-187. CLI review loading, status, resume, retirement, and collection all recognize the new typed relationship forms. Every relationship write remains under operator credentials; the browser never receives En API keys.

Early integration belongs to EP-186: emit a protected StaticSite configuration, load it, compose the accepted backend map and private route, and issue a signed-in-but-ungranted request through `appWithRuntime`. It must return 403 without contacting the upstream. EP-187 then extends that producer/consumer case with a team member and a team grant before expanding the mutation variants. EP-188 owns the final cross-service check and HTTP equivalence, origin-bypass checks, rollout and revocation transcript, and user documentation. Every child carries its relevant acceptance obligations rather than relying on this paragraph alone.


## Progress

EP-186 is complete: the shared protected-host contract (`Nagare.Inventory.ProtectedRoute`) serves Deployment, Application, StaticSite and ServerSite including previews and rollbacks, the composed backend-map bytes are denied end to end by the enforcer, gateway misses are fully consistent with the TTL as the only freshness bound, and the user documentation describes the supported policy subset, the transition rule, and the bound. EP-187 is complete: the bootstrap En schema carries group membership with a digest-driven En rollout, team membership and team site grants are exact typed relationships with reviewed commands, listing reads stored relationships through Relay pages without flattening teams, and the measured flat-team check cost is recorded. EP-188 (effective-access check, combined verification, documentation and the native transcript) is next. Container builds and deployment were not performed. There is no cloud or local-cluster deployment authorization in this planning turn. Final integration and architectural decision distillation remain part of implementation acceptance.


## Surprises & Discoveries

The existing access policy is exposed on Deployment and Application, but not on StaticSite or ServerSite. Current backend contributions contain upstream and route role only; they do not propagate `AccessPolicy.permission` or `audience`. The current enforcer hardcodes `access` and verifies the cluster audience. EP-186 must refuse unsupported custom values rather than silently claiming they work.

Current host grant CLI writes direct `viewer` tuples only, and its provider address hardcodes that relation. The team extension therefore changes inventory representation as well as En schema. Replacing a CLI subject string alone would lose userset identity and make guarded writes unsafe.


Validation found a Relay-versus-old-pagination mismatch between Nagare's CLI and its old En dependency. The user selected upgrading both auth dependencies, so existing Relay support is retained. Current `access list` recursively expands permissions; EP-187 must use stored relationship queries to avoid flattening teams or traversing their members just to list site grants.


## Decision Log

Decision (2026-10-12): Use a MasterPlan with three child ExecPlans. Site coverage, reviewed team relationships, and effective-access verification are separate deliverables with shared routing and tuple interfaces; the user requested a MasterPlan if scope warrants it.

Decision (2026-10-12): Implement En host grants for users and teams, as selected by the user. Preserve Shomei as the identity source and its own coarse administration tier; do not mirror site grants into JWTs or synchronize roles into groups.

Decision (2026-10-12): Keep hostname-scoped `access` and public defaults, add protection to dedicated site kinds, and refuse unsupported policy/CDN combinations. Changing all existing sites to private or implementing path/data permissions would be a separate scope decision.

Decision (2026-10-12): Use fully consistent En checks on gateway cache misses. Keep the existing configurable short gateway TTL and prove its upper bound. This makes a revocation guarantee observable without pretending MinimizeLatency is immediately fresh.


Decision (2026-10-12, validation update): Upgrade to verified upstream En/Shomei HEAD commits before site/team work, preserving Relay pagination and auth-image parity. Keep the three-child sequence; the dependency upgrade is EP-186 M0. Use narrowly targeted cost checks for identified cache and denied-team risks; no general load-test suite or arbitrary latency targets.

Revision (2026-10-12): Applied API findings, the user's latest-dependency requirement, and the request to avoid overengineering to all children and ADR 22.


## Outcomes & Retrospective

(To be filled during implementation and at completion.)
