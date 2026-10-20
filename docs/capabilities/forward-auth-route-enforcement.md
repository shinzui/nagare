---
title: "Forward-auth route enforcement"
type: Capability
description: "Route protected hostnames through a shared enforcer that challenges unauthenticated requests and checks authorization before proxying to the application."
generated:
  by: process:claude-code
  at: "2026-10-20T13:46:54Z"
reviews:
  - kind: model
    reviewer: process:openai-codex
    reviewed_at: "2026-08-25T20:51:44Z"
    document_timestamp: "2026-08-25T20:51:44Z"
    scope: content-and-metadata
    outcome: approved
    provider: openai
    model: codex/gpt-5
    effort: unspecified
    context: >-
      Reviewed the capability, compatibility promise, and repository evidence for inclusion in
      the version 0.1.0 Nix release.
verified:
  by: process:openai-codex
  at: "2026-08-25T20:51:44Z"
capabilityId: CAP-18
provider: mori://shinzui/nagare
status: shipped
stability: experimental
since: 0.1.0
packages:
  - nagare-access
  - nagarectl
interface:
  - "Nagare.Dsl.Access"
  - "nagarectl access grant|revoke|list|check"
  - "nagarectl access team add-member|remove-member|list-members"
  - "nagare-access"
requires:
  - CAP-6
evidence:
  - kind: test
    resource: cli/nagare-access/test/Spec.hs
    proves: Runtime configuration, safe return destinations, challenge selection, host routing, cookies, credentials, authorization failure behavior, and decision caching are tested.
  - kind: test
    resource: cli/nagarectl/test/AccessResolveSpec.hs
    proves: Protected routes fail closed when the enforcer is absent and otherwise rewrite DomainMappings through the shared backend map.
  - kind: test
    resource: cli/nagarectl/test/AccessGrantsSpec.hs
    proves: Grant tuples, authorization wire encoding, and expanded-subject parsing are tested.
  - kind: test
    resource: cli/nagarectl/test/Nagare/Test/SiteInventory/Access.hs
    proves: A protected StaticSite or ServerSite reviews a cluster-local origin, enforcer routes per hostname including previews, and the backend entry the enforcer denies through; unsupported policies, CDN, supplied TLS, missing auth, and in-place public-to-protected transitions refuse.
  - kind: test
    resource: cli/nagare-access/test/SiteAccessIntegrationSpec.hs
    proves: Through the real En evaluator over the reviewed schema and the gateway, a user reaches exactly the hosts granted to them or their teams, a revoked last path denies within the decision TTL, an En outage is 503 without an upstream call, and a forged identity header admits nobody.
  - kind: test
    resource: cli/nagarectl/test/AccessCheckSpec.hs
    proves: The effective-access diagnostic sends one fully consistent check, reports allowed, denied, conditional and unavailable exactly, and never echoes a body into a diagnostic.
  - kind: test
    resource: cli/nagare-access/test/DecisionCacheSpec.hs
    proves: A grant or revoke is observed after at most the decision TTL on a monotonic clock, a delayed or older check cannot extend an allow, and live entries are bounded.
  - kind: example
    resource: cluster/examples/protected-hello/nagare/Config.hs
    proves: A shipped application opts into required-login access in its typed config.
  - kind: example
    resource: cluster/examples/protected-static-site/nagare/Config.hs
    proves: A shipped static site opts into required-login access with the same field.
  - kind: conformance
    resource: docs/audits/mp27-site-access-drill-2026-10-13/site-access-drill.json
    proves: On a disposable local context the real Shomei login, reviewed user and team grants, the enforcer, the effective-access diagnostic, a protected preview, a rollback and the cluster-local origin behave as the interpreters proved, with the served En schema and exact images recorded.
  - kind: guide
    resource: docs/user/access.md
    proves: Auth-plane installation, protected deployment, grants, revocation, local verification, and failure modes are documented.
---

# Forward-auth route enforcement

An application, Deployment, StaticSite or ServerSite can declare `requireLogin`. Deployment then
fails closed unless the shared enforcer is present, writes the hostname-to-backend mapping, and
points the DomainMapping at `nagare-access`.
The enforcer challenges browser and API clients appropriately, validates session material, checks a
host-scoped authorization tuple, caches bounded decisions, and proxies allowed requests. Grant
commands manage the tuples used for that check: reviewed grants name a user by Shomei email,
resolved to exactly one user id, or a team, and `access check` reports one user's effective access
on one host without writing. Since 0.6.4, requests from API clients (API paths, bearer credentials,
JSON-preferring `Accept`) receive problem documents instead of a login redirect.

Route provisioning builds on [typed application deployment](typed-application-deployment.md)
(CAP-6).

## Limits

- This record covers Nagare's enforcer and route wiring. It does not claim the identity service from
  `mori://shinzui/shomei` or the authorization service from `mori://shinzui/en` as Nagare
  capabilities; a working login flow composes all three projects.
- The enforcer is a shared availability dependency for protected hosts. Authorizer outages return
  503 and evict cached decisions rather than failing open.
- Cloud deployment depends on operator configuration of external URLs, keys, secrets, and TLS.
