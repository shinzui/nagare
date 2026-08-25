---
title: "Forward-auth route enforcement"
type: Capability
description: "Route protected hostnames through a shared enforcer that challenges unauthenticated requests and checks authorization before proxying to the application."
generated:
  by: codex/gpt-5
  at: "2026-08-25T20:51:44Z"
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
  - "nagarectl access grant|revoke|list"
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
  - kind: example
    resource: cluster/examples/protected-hello/nagare/Config.hs
    proves: A shipped application opts into required-login access in its typed config.
  - kind: guide
    resource: docs/user/access.md
    proves: Auth-plane installation, protected deployment, grants, revocation, local verification, and failure modes are documented.
---

# Forward-auth route enforcement

An application can declare `requireLogin`. Deployment then fails closed unless the shared enforcer
is present, writes the hostname-to-backend mapping, and points the DomainMapping at `nagare-access`.
The enforcer challenges browser and API clients appropriately, validates session material, checks a
host-scoped authorization tuple, caches bounded decisions, and proxies allowed requests. Grant
commands manage the tuples used for that check.

Route provisioning builds on [typed application deployment](typed-application-deployment.md)
(CAP-6).

## Limits

- This record covers Nagare's enforcer and route wiring. It does not claim the identity service from
  `mori://shinzui/shomei` or the authorization service from `mori://shinzui/en` as Nagare
  capabilities; a working login flow composes all three projects.
- The enforcer is a shared availability dependency for protected hosts. Authorizer outages return
  503 and evict cached decisions rather than failing open.
- The local auth-plane path has been exercised; current cloud deployment still depends on operator
  configuration of external URLs, keys, secrets, and TLS.
