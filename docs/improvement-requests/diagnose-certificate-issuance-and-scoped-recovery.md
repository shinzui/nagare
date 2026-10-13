---
type: Improvement Request
title: Diagnose terminal certificate issuance failures and expose scoped recovery
description: Surface the certificate request and ACME failure chain with a supported per-host retry path that preserves the reviewed deployment.
generated:
  by: process:openai-codex
  at: "2026-10-13T13:08:02Z"
requestId: IR-28
status: accepted
targetPlan: docs/plans/191-diagnose-certificate-issuance-failures-and-renew-one-owned-host.md
origin: mori://shinzui/keiro-runtime-docs/plans/49-deploy-the-docs-to-the-labs-intranet-with-local-bun-builds
acceptanceCriteria:
  - id: AC-1
    statement: TLS diagnostics identify the affected host, issuer, certificate, request, ACME order failure, and next retry state with bounded redacted evidence.
    verification: Use pending, successful, failed-finalization, and rate-limited issuance fixtures and check human and JSON diagnostics.
  - id: AC-2
    statement: Operators have a documented or command-backed scoped retry for an owned host that preserves the accepted deployment and access policy.
    verification: Recover a failed issuance in a disposable context, prove Ready and trusted HTTPS, and compare accepted routes, auth contribution, and service intent before and after.
  - id: AC-3
    statement: Recovery refuses unrelated certificate ownership and respects issuer backoff without unbounded retries or weaker TLS validation.
    verification: Test foreign ownership, wrong context, repeated failures, and retry timing; assert no certificate key or bearer credential appears in diagnostics.
reviews:
  - kind: model
    reviewer: process:openai-codex
    reviewed_at: "2026-10-13T13:08:02Z"
    document_timestamp: "2026-10-13T13:08:02Z"
    scope: content-and-metadata
    outcome: commented
    provider: openai
    model: gpt-6.1-sol
    effort: unspecified
    context: >-
      Author review of classification, source evidence, reproduction or acceptance,
      and safety boundaries; no independent verification attestation is claimed.
---

# Diagnose terminal certificate issuance failures and expose scoped recovery

During the v0.6.2 protected docs deployment, DNS-01 validation succeeded but the
ACME finalize endpoint returned HTTP 404 with
`urn:ietf:params:acme:error:malformed` and `Certificate not found`. TLS stayed
not Ready, holding up the reviewed deployment. After inspecting the certificate
owner chain, a supported `cmctl renew` on that one host restarted issuance and
produced a valid Ready certificate. The saved deployment transaction then
converged. No accepted route, authentication, or TLS policy was changed.

This is an operator-workflow request. The external ACME failure is not evidence
of an incorrect Nagare issuance algorithm. Nagare already reports certificate
readiness and failures through `cli/nagarectl/src/Nagare/Domain/Tls.hs`;
the missing convenience is a complete, actionable failure chain and a supported
recovery procedure from the normal Nagare operator workflow.

Expose bounded diagnostics linking the hostname to its Knative Certificate,
cert-manager CertificateRequest and ACME Order, with the failed phase, safe
upstream problem details, and retry/backoff state. Provide a documented
single-host renewal procedure or a context- and ownership-checked command
backed by the supported cert-manager renewal mechanism. Explain how to inspect
and resume the existing inventory transaction after issuance succeeds.

The scope excludes reinstalling the platform auth plane, deleting certificate
Secrets to force retries, automatic retry storms, weakening validation, or
changing accepted resource ownership. The operator must be able to distinguish
an expected pending state from a terminal issuance failure and recover without
guessing at cluster objects.

Upstream documents [issuance retries](https://cert-manager.io/docs/faq/#what-happens-if-issuance-fails-will-it-be-retried)
and [the supported renew operation](https://cert-manager.io/docs/reference/cmctl/#renew).
The successful renewal is recorded in the origin deployment plan named above.
