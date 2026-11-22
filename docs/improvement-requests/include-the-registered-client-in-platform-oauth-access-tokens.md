---
type: Improvement Request
title: Include the registered client in platform OAuth access tokens
description: Give relying applications a verified client_id claim in platform OAuth access tokens for authorization-code and client-credentials grants.
timestamp: "2026-11-22T06:22:00Z"
generated:
  by: process:codex
  at: "2026-11-22T06:22:00Z"
requestId: IR-51
status: proposed
origin: mori://shinzui/kotei/plans/158-serve-permission-aware-kotei-clients-through-the-nagare-auth-plane
originPlan: mori://shinzui/kotei/plans/158-serve-permission-aware-kotei-clients-through-the-nagare-auth-plane
acceptanceCriteria:
  - id: AC-1
    statement: Every platform OAuth access token minted from a registered authorization-code or client-credentials grant carries the authenticated or bound registration identifier as the signed client_id claim.
    verification: Register two public clients and a service account. Exercise both flows through a disposable HTTPS portal, then verify the issuer, signature and exact client_id for every token. Refresh a public client's grant and verify that the refreshed token keeps its client_id.
  - id: AC-2
    statement: The new claim preserves the platform issuer, audience, user subject and current host access behavior, including portal-created sign-in sessions.
    verification: Verify current protected-site access with the existing portal sign-in and a new OAuth token. Confirm a relying application can opt into a client allowlist and refuses a valid token from the other registration without affecting any existing site grants.
---

# Include the registered client in platform OAuth access tokens

Kotei verified two tokens through a disposable Nagare HTTPS portal. A public
client completed authorization code with PKCE, and a service account used
client credentials. The issuer signed both tokens with `nagare-access` and
identified both callers with a `user_…` subject. Neither token contained the
client registration that received it.

Kotei currently accepts any valid platform token as the named principal and
uses its own En tenant for repository permissions. A signed `client_id` claim
would let operators optionally bind accepted tokens to a particular registered
client. Retain the existing platform audience and host grant semantics.

Consumer evidence is recorded in
`mori://shinzui/kotei/plans/158-serve-permission-aware-kotei-clients-through-the-nagare-auth-plane`.
