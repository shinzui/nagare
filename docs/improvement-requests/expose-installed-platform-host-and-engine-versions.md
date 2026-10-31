---
type: Improvement Request
title: Report every installed and running version through the admin API
description: Add an admin API document that reports the Nagare version a context has installed, the host's NixOS, kernel and Kubernetes versions, each platform component's version, and each managed database server's declared and running engine version, so an operator portal can show what is actually running.
timestamp: "2026-10-31T14:54:53Z"
generated:
  by: process:claude-code
  at: "2026-10-31T14:54:53Z"
requestId: IR-38
status: proposed
origin: mori://tan/tan-ng-labs
acceptanceCriteria:
  - id: AC-1
    statement: The admin API reports the Nagare platform version the context has installed (version, revision, payload id and install time from the platform-version stamp) separately from the version of the admin API build that is serving, and shows when they differ.
    verification: Serve an admin API built from an older release against a context stamped with a newer one and assert the document reports both versions and marks the skew; with matching versions, assert no skew is reported.
  - id: AC-2
    statement: The admin API reports the host's NixOS release and codename, the nixpkgs revision the host was built from, the kernel version, and the Kubernetes (k3s) version.
    verification: On the local harness and on a cloud context, compare the document with the node's status.nodeInfo (osImage, kernelVersion, kubeletVersion) and the host's /etc/os-release.
  - id: AC-3
    statement: For every database server Nagare manages, platform and shared app servers alike, the admin API reports the engine, the declared engine version, the image reference and resolved digest, and the engine version the server reports.
    verification: Declare a PostgreSQL server with engine version "18" (a moving image tag) and a ClickHouse server with an exact version; assert the document shows the declared "18" next to the running minor version, and that each running value matches SELECT version() on that server.
  - id: AC-4
    statement: The admin API reports the version or image digest of each platform component Nagare installs, including en, Shōmei, nagare-access, the admin API, Knative and its ingress, cert-manager and the observability releases.
    verification: Compare the document with the component pins in the installed release payload and the Helm releases and Deployments in the cluster, on the local harness and on a cloud context.
  - id: AC-5
    statement: Each value says whether it is recorded inventory state or a live observation, and gives the observation time; a source that cannot be read yields a null value with a reason while the rest of the document is still served; the document is a versioned contract in docs/api/openapi.json and contains no credentials.
    verification: Make one source unreadable in a test (stop a database server, or deny the observation's permission) and assert a partial document with a reason for that value; check the generated OpenAPI contract and assert no secret material appears in the response.
reviews:
  - kind: model
    reviewer: process:claude-code
    reviewed_at: "2026-10-31T14:54:53Z"
    document_timestamp: "2026-10-31T14:54:53Z"
    scope: content-and-metadata
    outcome: commented
    provider: anthropic
    model: claude-opus-5-5
    effort: unspecified
    context: >-
      Author review against the v0.9.0 and v0.13.0 admin API contracts
      (docs/api/openapi.json at both tags), VersionInfo in
      cli/nagare-contract/src/Nagare/Contract/V1.hs, and live reads of the
      tan-ng-labs intranet on Nagare v0.13.0 on 2026-10-31. No independent
      verification is claimed.
---

# Report every installed and running version through the admin API

**Authored by:** a `claude-code` session operating the `tan-ng-labs` intranet
(`mori://tan/tan-ng-labs`), running Nagare v0.13.0.
**Addressed to:** `shinzui/nagare` agents.
**Created:** 2026-10-31.


## Why

The tan-ng-labs intranet portal (`mori://tan/tan-ng-labs`, `web/apps/portal`; artifact-level
URI pending) is a read-only operator console built on the admin API. Its operators want the
Admin home page to show the Nagare and NixOS versions, and its Databases page to show each
shared server's PostgreSQL or ClickHouse version. The admin API cannot answer any of these
questions today.

- **Installed Nagare version.** `GET /v1/platform/version` returns `VersionInfo`, which by
  design "describes the binary, not what a context has installed"
  (`cli/nagare-contract/src/Nagare/Contract/V1.hs`). On 2026-10-31 the intranet's
  `nagare-platform-version` stamp read version `0.13.0` (revision `208b1f2d…`, installed
  2026-10-30T22:11:11Z), while the admin API image, last rebuilt for v0.9.0, answered
  `0.9.0`. The portal therefore shows "admin API 0.9.0" and has no way to learn that the
  platform is on 0.13.0, or that the two have drifted.
- **Host.** The node reports `NixOS 26.11 (Zokor)`, kernel `6.18.51` and `v1.35.8+k3s1`.
  None of this is in the admin API.
- **Database servers.** `ScopeState` carries only scope, generation, digest and convergence.
  The declared engine version (`mkEngineVersion Postgres "18"`,
  `mkEngineVersion ClickHouse "26.8.28.14"`) is in the reviewed inventory but not exposed,
  and neither is the running version. They can differ: `postgres:18` is a moving tag, and
  `labs-postgres` actually runs PostgreSQL 18.6. Nagare's own `en-db` and `shomei-db` are
  also `postgres:18`.
- **Components.** The versions or digests of en, Shōmei, nagare-access, the admin API,
  Knative, cert-manager and the observability stack are not reported either.

The v0.13.0 contract has the same paths and schemas in this respect, so upgrading does not
help. The alternatives available to a consumer are worse: granting the portal Kubernetes read
access or database credentials only to read version strings, or baking declared values in at
build time, where they go stale.


## Requested change

A read-only admin API document (for example `GET /v1/platform/versions`; the name and shape
are Nagare's call) with four sections:

- **Nagare.** The installed platform version, revision, payload id and install time from the
  platform-version stamp; the serving admin API build (today's `VersionInfo`); and whether
  they differ. If the host module's and the context's pinned versions are recorded, include
  them too.
- **Host.** NixOS release and codename, nixpkgs revision, kernel version, and Kubernetes
  (k3s) version.
- **Platform components.** For each component Nagare installs: its declared version and
  image digest or Helm chart version.
- **Database servers.** For each managed server (platform databases and shared app
  servers): the scope, engine, declared engine version, image reference and resolved digest,
  and the version the server reports (`SELECT version()` or the equivalent).

Constraints:

- The admin API currently describes itself as "recorded inventory state, never live workload
  health". Running versions are observations, so every value should be marked as recorded or
  observed, with the observation time. Recording the observed values during reconciliation or
  host activation, so the API stays a reader of recorded state, is equally acceptable.
- A source that cannot be read gives a null value with a reason; it must not fail the whole
  document.
- No credentials or connection strings in the response.
- The same document from the CLI (for example `nagarectl platform versions`) would help, but
  is optional.

Out of scope: rebuilding a stale admin API image is the operator's job, and the intranet's
runbook already covers it. This request is only about making the versions visible.


## Consumer

When this ships, the tan-ng-labs portal will vendor the new contract, then add the Nagare,
NixOS, kernel and k3s versions to its Admin home "Nagare" card and the engine versions to its
Databases page.
