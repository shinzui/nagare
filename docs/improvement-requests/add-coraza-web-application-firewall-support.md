---
type: Improvement Request
title: Add optional Coraza Web Application Firewall support to Nagare ingress
description: Give Nagare a declarative, testable Coraza and OWASP CRS ingress mode that protects direct HTTP traffic before Kourier without requiring an edge provider.
generated:
  by: process:openai-codex
  at: "2026-09-25T13:14:46Z"
requestId: IR-25
status: proposed
origin: mori://shinzui/nagare/okf/research/concepts/RES-2
acceptanceCriteria:
  - id: AC-1
    statement: An operator can enable, preview, apply, inspect, and disable Coraza for a Nagare context through a declared platform configuration, with rule-set and connector artifacts pinned to verified releases.
    verification: Offline render and reviewed-change tests prove deterministic resources, declared ownership, explicit version/digest changes, and a reversible disable path.
  - id: AC-2
    statement: Every public direct HTTP and HTTPS route selected for protection passes through Coraza before Kourier, while Knative still routes by the original Host header.
    verification: A disposable-cluster request matrix covers ordinary domains, wildcard domains, protected sites, direct-IP requests carrying a protected Host header, and negative bypass attempts.
  - id: AC-3
    statement: Detection mode records rule and host evidence, and enforcement mode blocks a known CRS test payload without blocking the tested legitimate application routes.
    verification: Integration checks exercise detection, blocking, scoped rule exclusions, rollback, and representative app, API, and upload requests.
  - id: AC-4
    statement: TLS, certificate issuance, client-IP attribution, health checks, and forwarded-header trust remain correct through the additional ingress hop.
    verification: Local and cloud-shaped tests inspect TLS and DNS-01 behavior, trusted versus spoofed forwarding headers, health readiness, and logs for the effective client address.
  - id: AC-5
    statement: A failed WAF component does not silently admit protected traffic through an unfiltered listener, and disabling Coraza restores the documented direct-ingress topology.
    verification: Fault-injection tests stop or misconfigure Coraza and inspect external request outcomes, then disable the feature and verify a clean rollback.
  - id: AC-6
    statement: Coraza operates within a measured single-node resource budget and exposes useful rule and error metrics without logging secrets or request bodies by default.
    verification: Load and large-body tests record latency, CPU, memory, and connector stability; log checks reject credentials, cookies, and raw payloads.
reviews:
  - kind: model
    reviewer: openai-codex
    reviewed_at: "2026-09-25T13:17:08Z"
    document_timestamp: "2026-09-25T13:14:46Z"
    scope: content-and-metadata
    outcome: commented
    provider: OpenAI
    model: gpt-6
    effort: medium
    context: >-
      Author self-review of the proposal against RES-2, the current ingress code, and the profile contract; implementation and independent review remain pending.
---

# Add optional Coraza Web Application Firewall support to Nagare ingress

## Why

Nagare's direct path exposes Kourier/Envoy on VM ports 80 and 443. Its optional Cloudflare and Google CDN paths do not cover traffic sent straight to the VM's public IP. The [WAF integration research](../research/web-application-firewall-integration-options.md) records the current routing, edge alternatives, origin bypass, and Coraza connector risks. Operators who want a self-hosted WAF need a supported way to place it on the actual public path, not just a sample deployment beside Kourier.

## Requested change

Add an opt-in Coraza ingress capability with a pinned OWASP Core Rule Set, a safe detection-to-enforcement rollout, scoped rule exclusions, status and observability, and documented rollback. This is platform ingress configuration, independent of whether an app enables CDN caching. Preserve the default direct-ingress behavior when the capability is disabled.

First prove a connector against Nagare's vendored Kourier and Envoy versions. Compare a supported filter insertion with a separate Coraza-capable front proxy. Choose a path that remains in effect after Knative reconciliation and platform upgrades, and document why. If a separate proxy owns the public listener, move Kourier behind it without opening a second public bypass path. If the connector has unresolved stability or resource risks on the single node, do not promote the feature as production-ready.

The configuration should make the following explicit:

- which public hostnames are protected and whether the policy runs in detection or enforcement mode;
- the selected, pinned connector and CRS artifacts, with an upgrade and rollback procedure;
- a reviewed platform default plus narrowly scoped host/path exceptions, without one app silently weakening another;
- TLS termination, the origin hop, DNS-01 challenges, health checks, the trusted proxy boundary, and the client IP recorded in logs;
- fail behavior when Coraza cannot start or evaluate a request, including a clear operator status;
- request-body limits and logging defaults that avoid storing credentials, cookies, and raw payloads.

Coraza at the origin does not inspect CDN cache hits. Documentation and status must say which traffic each configured edge and origin policy actually evaluates. Cloudflare and Cloud Armor provisioning are separate possible follow-ups; this request is specifically for the self-hosted Coraza path.

## Acceptance

The six `acceptanceCriteria` above are the completion contract. In particular, a protected hostname must not be reachable through the old direct VM listener while Coraza is enabled, and an ordinary application must keep its Host-based Knative route, TLS, and availability under both rollout and rollback. Use a disposable context for end-to-end evidence before enabling enforcement on a live host.
