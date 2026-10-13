---
title: "Site access is a reviewed relationship per hostname"
status: accepted
date: 2026-10-13
authors: [shinzui]
related:
  - docs/adr/0015-the-auth-portal-hands-sessions-to-nagare-access-through-response-headers.md
  - docs/adr/0020-domain-routing-and-tls-ownership-are-explicit.md
  - docs/adr/0022-compose-independent-resource-scopes-through-a-typed-inventory.md
  - docs/adr/0025-defects-are-found-by-interpreters-and-native-runs-only-confirm.md
  - docs/masterplans/27-protect-every-nagare-site-with-explicit-user-and-team-access.md
  - docs/plans/186-protect-nagare-sites-with-explicit-user-and-team-grants.md
  - docs/plans/187-manage-reviewed-team-membership-and-site-access-grants.md
  - docs/plans/188-check-effective-site-access-and-verify-user-and-team-isolation.md
---

# ADR 29 — Site access is a reviewed relationship per hostname

## Status

Accepted on 2026-10-13, distilled from MasterPlan 27 and its three ExecPlans.

## Context

Before MasterPlan 27, only a `Deployment` or an `Application` could opt into the
shared Shomei and En enforcer, a grant was one direct `app:<host>#viewer@user:<id>`
relationship, the gateway asked En at its minimize-latency revision, and the decision
cache scanned every entry on every write. The operator asked for every site kind to be
protectable and for teams to hold access, without converting any existing site.

## Decision

1. **One field, every web kind.** `access = Just requireLogin` on a `Deployment`,
   `Application`, `StaticSite` or `ServerSite` means: authenticate with Shomei, then
   require En permission `access` on `app:<hostname>`. Public is the default; nothing
   converts silently. One module, `Nagare.Inventory.ProtectedRoute`, composes the contract
   for every kind: the origin Service becomes cluster-local, each hostname gets a
   DomainMapping in `nagare-system` targeting the enforcer, and each hostname is
   contributed to the auth owner's backend map.
2. **Every hostname is its own authorization object.** Custom domains, the default
   `<name>.<namespace>.<base>` hostname, and every preview hostname need their own
   grants. A preview inherits the production policy, never its grants. Signing in admits
   nobody, and there is no administrator bypass.
3. **The supported policy is exactly `requireLogin`.** Another permission or an explicit
   audience, the portal role on a site, a CDN, or supplied origin TLS refuses at planning
   rather than being accepted and ignored.
4. **A protected route is never rewritten in place.** The planner refuses to move an
   accepted route's address (`migration-review-required`); a public site becomes
   protected by a reviewed retirement and collection of its route, then a protected
   deploy. Rollback changes the image and keeps the current config's protection.
5. **Teams are En groups with flat user membership.** A membership is
   `group:<team>#member@user:<id>`; a team site grant is
   `app:<host>#viewer@group:<team>#member`. Each is an exact typed inventory relationship
   (`TeamMemberTuple`, `TeamAccessTuple`) whose identity includes the subject kind and
   relation, so a user and a userset over that user never collide, and every write pins
   both in its precondition filter. A team exists from its first accepted membership; a
   team grant needs that history; removing every member does not revoke a grant; a direct
   grant and a team grant are independent paths. Team changes are always reviewed. The
   schema that declares groups ships in the packaged auth bootstrap and rolls En through
   a Pod-template digest; a team write first verifies the active schema.
6. **Listing reports stored relationships; effective access is a check.** `access list`
   and `access team list-members` drain En's Relay relationship pages at a fully
   consistent snapshot and refuse to print a partial list. `access check` is one fully
   consistent En check of one user on one host and never infers from a list.
7. **The gateway's freshness bound is its TTL.** A decision-cache miss asks En at a fully
   consistent snapshot. `NAGARE_ACCESS_DECISION_TTL` (default 30 s, zero disables) is
   measured on the monotonic clock from the start of the check, a slower older check never
   replaces a newer entry, live entries are bounded, and an unavailable En is a 503 that is
   never cached. The bound governs new admissions; it does not disconnect streams.

## Consequences

- A packaged auth manifest change is a platform-scope change: this release pins its own
  manifests and refuses an earlier payload's (as for the MinIO manifest, F41), so the
  transition compiles the auth plane from its own tree and the platform stage re-plans the
  auth scope on upgrade.
- At the pinned En, a stranger's denied check against a flat team reads every member of
  each attached team once; a member's check is three point probes. Small teams keep that
  cheap and the caches bound repeats; a point probe of `group#member` for the checked
  subject is the recorded upstream improvement, not a Nagare workaround.
- Excluded, deliberately: nested groups, invitations, self-service sharing, delegated site
  administration, per-path or per-method rules, machine access, MFA step-up, expiring
  shares, and application-data permissions.
